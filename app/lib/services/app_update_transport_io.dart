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
  IOSink? sink;
  try {
    final req = await client.getUrl(downloadUri);
    req.followRedirects = true;
    req.maxRedirects = 8;
    req.headers.set(HttpHeaders.userAgentHeader, 'GrassBag-App');
    req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    req.headers.set('Pragma', 'no-cache');
    final resp = await req.close();
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('APK 下载失败（HTTP ${resp.statusCode}）', uri: downloadUri);
    }

    final totalBytes = resp.contentLength; // -1 if unknown
    var receivedBytes = 0;
    sink = partFile.openWrite();
    onProgress?.call(0, totalBytes);

    await for (final chunk in resp) {
      if (isCancelled?.call() == true) {
        throw const AppUpdateDownloadCancelledException();
      }
      sink.add(chunk);
      receivedBytes += chunk.length;
      onProgress?.call(receivedBytes, totalBytes);
    }
    await sink.flush();
    await sink.close();
    sink = null;

    if (await destFile.exists()) {
      await destFile.delete();
    }
    await partFile.rename(destinationPath);
    return destinationPath;
  } catch (_) {
    try {
      await sink?.close();
    } catch (_) {}
    try {
      if (await partFile.exists()) {
        await partFile.delete();
      }
    } catch (_) {}
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
