import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

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
}) async {
  final headers = JSObject();
  headers.setProperty('Accept'.toJS, 'application/vnd.github+json'.toJS);
  final init = JSObject();
  init.setProperty('method'.toJS, 'GET'.toJS);
  init.setProperty('headers'.toJS, headers);
  init.setProperty('cache'.toJS, 'no-store'.toJS);

  final fetchFn = globalContext.getProperty<JSFunction>('fetch'.toJS);
  final promise = fetchFn.callAsFunction(null, uri.toString().toJS, init) as JSPromise<JSObject>;
  final resp = await promise.toDart.timeout(timeout);
  final status = (resp.getProperty<JSNumber>('status'.toJS)).toDartInt;
  final textFn = resp.getProperty<JSFunction>('text'.toJS);
  final textPromise = textFn.callAsFunction(resp) as JSPromise<JSString>;
  final body = (await textPromise.toDart.timeout(timeout)).toDart;
  return AppUpdateHttpResponse(statusCode: status, body: body);
}

Future<String> downloadAppUpdateApk(
  Uri uri,
  String destinationPath, {
  void Function(int receivedBytes, int totalBytes)? onProgress,
  bool Function()? isCancelled,
  int? expectedSizeBytes,
  void Function(void Function() abort)? onAbortReady,
}) async {
  throw UnsupportedError('Web 端请直接通过浏览器下载 APK 安装包');
}
