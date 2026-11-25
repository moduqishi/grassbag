import 'dart:async';
import 'dart:convert';
import 'dart:io';

class AppUpdateHttpResponse {
  const AppUpdateHttpResponse({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

Future<AppUpdateHttpResponse> fetchAppUpdateJson(
  Uri uri, {
  Duration timeout = const Duration(seconds: 12),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    req.headers.set('X-GitHub-Api-Version', '2022-11-28');
    req.headers.set(HttpHeaders.userAgentHeader, 'GrassBag-App');
    req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    req.headers.set('Pragma', 'no-cache');
    final resp = await req.close().timeout(timeout);
    final body = await resp.transform(utf8.decoder).join().timeout(timeout);
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

  // Append cache-busting query param to bypass transparent HTTP proxy caches.
  final downloadUri = uri.replace(
    queryParameters: {
      ...uri.queryParameters,
      '_t': '${DateTime.now().millisecondsSinceEpoch}',
    },
  );

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
    final req = await client.getUrl(downloadUri).timeout(const Duration(seconds: 25));
    req.followRedirects = true;
    req.maxRedirects = 8;
    req.headers.set(HttpHeaders.userAgentHeader, 'GrassBag-App');
    req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    req.headers.set('Pragma', 'no-cache');
    final resp = await req.close().timeout(const Duration(seconds: 25));
    if (aborted || isCancelled?.call() == true) {
      throw const AppUpdateDownloadCancelledException();
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('APK 下载失败（HTTP ${resp.statusCode}）', uri: downloadUri);
    }

    final totalBytes = resp.contentLength; // -1 if unknown
    var receivedBytes = 0;
    sink = partFile.openWrite();
    onProgress?.call(0, totalBytes);

    await for (final chunk in resp.timeout(const Duration(seconds: 30))) {
      if (aborted || isCancelled?.call() == true) {
        throw const AppUpdateDownloadCancelledException();
      }
      sink.add(chunk);
      receivedBytes += chunk.length;
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
