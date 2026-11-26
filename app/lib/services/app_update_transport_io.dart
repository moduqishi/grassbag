import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class AppUpdateHttpResponse {
  const AppUpdateHttpResponse({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

Future<AppUpdateHttpResponse> fetchAppUpdateJson(
  Uri uri, {
  Duration timeout = const Duration(seconds: 12),
  int maxBytes = 2 * 1024 * 1024,
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    final isGitHubTarget = uri.toString().toLowerCase().contains('github.com');
    if (isGitHubTarget) {
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set('X-GitHub-Api-Version', '2022-11-28');
    } else {
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    }
    req.headers.set(HttpHeaders.userAgentHeader, 'GrassBag-App');
    req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    req.headers.set('Pragma', 'no-cache');
    final resp = await req.close().timeout(timeout);
    final builder = BytesBuilder(copy: false);
    final done = Completer<Uint8List>();
    late StreamSubscription<List<int>> sub;
    sub = resp.listen(
      (chunk) {
        if (builder.length + chunk.length > maxBytes) {
          unawaited(sub.cancel());
          if (!done.isCompleted) {
            done.completeError(
              HttpException('更新元数据响应体超过 ${(maxBytes / (1024 * 1024)).toStringAsFixed(0)} MB 安全上限', uri: uri),
            );
          }
          return;
        }
        builder.add(chunk);
      },
      onError: (Object err, StackTrace st) {
        if (!done.isCompleted) done.completeError(err, st);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(builder.takeBytes());
      },
      cancelOnError: true,
    );
    final rawBytes = await done.future.timeout(
      timeout,
      onTimeout: () {
        unawaited(sub.cancel());
        throw TimeoutException('HTTP response timed out', timeout);
      },
    );
    final body = utf8.decode(rawBytes, allowMalformed: true);
    return AppUpdateHttpResponse(statusCode: resp.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}

Future<String> downloadAppUpdateApk(
  Uri uri,
  String destinationPath, {
  void Function(int receivedBytes, int totalBytes)? onProgress,
  bool Function()? isCancelled,
  int? expectedSizeBytes,
  void Function(void Function() abort)? onAbortReady,
}) async {
  final destFile = File(destinationPath);
  await destFile.parent.create(recursive: true);
  final partFile = File('$destinationPath.part');
  if (await partFile.exists()) {
    await partFile.delete();
  }

  // Only append cache-busting query param on direct GitHub URLs; keep mirror paths untouched
  // so reverse-proxy mirrors (e.g. ghfast.top) never treat `_t` as part of the upstream path.
  final hostLower = uri.host.toLowerCase();
  final isDirectGitHub = hostLower == 'github.com' ||
      hostLower.endsWith('.github.com') ||
      hostLower.endsWith('.githubusercontent.com');
  final downloadUri = isDirectGitHub
      ? uri.replace(
          queryParameters: {
            ...uri.queryParameters,
            '_t': '${DateTime.now().millisecondsSinceEpoch}',
          },
        )
      : uri;

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  var aborted = false;
  onAbortReady?.call(() {
    aborted = true;
    try {
      client.close(force: true);
    } catch (_) {}
  });
  IOSink? sink;
  try {
    if (aborted || isCancelled?.call() == true) {
      throw const AppUpdateDownloadCancelledException();
    }
    const maxApkBytes = 512 * 1024 * 1024; // 512 MiB hard safety cap
    var currentUri = downloadUri;
    HttpClientResponse? resp;
    for (var hop = 0; hop <= 8; hop++) {
      if (aborted || isCancelled?.call() == true) {
        throw const AppUpdateDownloadCancelledException();
      }
      final req = await client.getUrl(currentUri).timeout(const Duration(seconds: 25));
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, 'GrassBag-App');
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      req.headers.set('Pragma', 'no-cache');
      final candidateResp = await req.close().timeout(const Duration(seconds: 25));
      if (aborted || isCancelled?.call() == true) {
        unawaited(candidateResp.drain<void>().catchError((_) {}));
        throw const AppUpdateDownloadCancelledException();
      }
      final sc = candidateResp.statusCode;
      if (sc == 301 || sc == 302 || sc == 303 || sc == 307 || sc == 308) {
        final loc = candidateResp.headers.value(HttpHeaders.locationHeader)?.trim() ?? '';
        unawaited(candidateResp.drain<void>().catchError((_) {}));
        if (loc.isEmpty || hop == 8) {
          throw HttpException('APK 下载重定向异常（HTTP $sc）', uri: currentUri);
        }
        final nextUri = currentUri.resolve(loc);
        if (currentUri.scheme == 'https' && nextUri.scheme != 'https') {
          throw HttpException('拒绝不安全的 HTTPS 到 HTTP 下载重定向降级', uri: nextUri);
        }
        currentUri = nextUri;
        continue;
      }
      resp = candidateResp;
      break;
    }
    if (resp == null) {
      throw HttpException('APK 下载重定向次数过多', uri: downloadUri);
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('APK 下载失败（HTTP ${resp.statusCode}）', uri: currentUri);
    }
    final mime = resp.headers.contentType?.mimeType.toLowerCase() ?? '';
    if (mime == 'text/html' || mime == 'application/xhtml+xml') {
      throw HttpException('镜像返回了异常网页，正在切换备用源', uri: currentUri);
    }

    final totalBytes = resp.contentLength; // -1 if unknown
    if (totalBytes > maxApkBytes) {
      throw HttpException('APK 文件超过 512 MB 安全上限', uri: currentUri);
    }
    var receivedBytes = 0;
    var bytesSinceFlush = 0;
    sink = partFile.openWrite();
    onProgress?.call(0, totalBytes);

    await for (final chunk in resp.timeout(const Duration(seconds: 30))) {
      if (aborted || isCancelled?.call() == true) {
        throw const AppUpdateDownloadCancelledException();
      }
      receivedBytes += chunk.length;
      if (receivedBytes > maxApkBytes) {
        throw HttpException('APK 下载体积超过 512 MB 安全上限', uri: currentUri);
      }
      sink.add(chunk);
      bytesSinceFlush += chunk.length;
      if (bytesSinceFlush >= 1024 * 1024) {
        bytesSinceFlush = 0;
        await sink.flush();
      }
      onProgress?.call(receivedBytes, totalBytes);
    }
    await sink.flush();
    await sink.close();
    sink = null;

    if (aborted || isCancelled?.call() == true) {
      throw const AppUpdateDownloadCancelledException();
    }
    if (receivedBytes <= 0) {
      throw const HttpException('下载的 APK 文件为空，请重试');
    }
    if (totalBytes > 0 && receivedBytes != totalBytes) {
      throw HttpException('APK 下载不完整（已接收 $receivedBytes / $totalBytes 字节）', uri: downloadUri);
    }
    if (expectedSizeBytes != null && expectedSizeBytes > 0 && receivedBytes != expectedSizeBytes) {
      throw HttpException(
        'APK 文件大小校验失败（实际 $receivedBytes 字节，预期 $expectedSizeBytes 字节）',
        uri: downloadUri,
      );
    }
    // Verify APK ZIP local file header magic (`PK\x03\x04`) before replacing installed cache!
    final raf = await partFile.open(mode: FileMode.read);
    try {
      final magic = await raf.read(4);
      if (magic.length < 4 ||
          magic[0] != 0x50 ||
          magic[1] != 0x4B ||
          magic[2] != 0x03 ||
          magic[3] != 0x04) {
        throw HttpException('下载的文件不是有效的 APK 安装包，正在切换备用源', uri: downloadUri);
      }
    } finally {
      await raf.close();
    }

    // Prune older cached `grassbag-*.apk` installers to avoid >100MB cache bloat.
    try {
      await for (final entity in destFile.parent.list()) {
        if (entity is File && entity.path != partFile.path) {
          final lower = entity.path.toLowerCase();
          if (lower.endsWith('.apk') || lower.endsWith('.apk.part')) {
            await entity.delete().catchError((_) => entity);
          }
        }
      }
    } catch (_) {}

    if (await destFile.exists()) {
      await destFile.delete();
    }
    await partFile.rename(destinationPath);
    return destinationPath;
  } catch (err) {
    try {
      await sink?.close();
    } catch (_) {}
    try {
      if (await partFile.exists()) {
        await partFile.delete();
      }
    } catch (_) {}
    if (aborted || isCancelled?.call() == true) {
      throw const AppUpdateDownloadCancelledException();
    }
    rethrow;
  } finally {
    client.close(force: true);
  }
}

class AppUpdateDownloadCancelledException implements Exception {
  const AppUpdateDownloadCancelledException();

  @override
  String toString() => '已取消下载';
}
