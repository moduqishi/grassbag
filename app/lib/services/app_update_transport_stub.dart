class AppUpdateHttpResponse {
  const AppUpdateHttpResponse({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

class AppUpdateDownloadCancelledException implements Exception {
  const AppUpdateDownloadCancelledException();

  @override
  String toString() => '已取消下载';
}

Future<AppUpdateHttpResponse> fetchAppUpdateJson(
  Uri uri, {
  Duration timeout = const Duration(seconds: 12),
  int maxBytes = 2 * 1024 * 1024,
}) async {
  throw UnsupportedError('HTTP transport unavailable on this platform');
}

Future<String> downloadAppUpdateApk(
  Uri uri,
  String destinationPath, {
  void Function(int receivedBytes, int totalBytes)? onProgress,
  bool Function()? isCancelled,
  int? expectedSizeBytes,
  String? expectedSha256,
  void Function(void Function() abort)? onAbortReady,
}) async {
  throw UnsupportedError('APK file download unavailable on this platform');
}
