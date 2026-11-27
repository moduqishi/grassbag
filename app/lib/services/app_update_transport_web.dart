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
  int maxBytes = 2 * 1024 * 1024,
}) async {
  final headers = JSObject();
  final isGitHubTarget = uri.toString().toLowerCase().contains('github.com');
  headers.setProperty(
    'Accept'.toJS,
    (isGitHubTarget ? 'application/vnd.github+json' : 'application/json').toJS,
  );
  final init = JSObject();
  init.setProperty('method'.toJS, 'GET'.toJS);
  init.setProperty('headers'.toJS, headers);
  init.setProperty('cache'.toJS, 'no-store'.toJS);

  JSObject? abortCtrl;
  try {
    final ctor = globalContext.getProperty<JSAny?>('AbortController'.toJS);
    if (ctor != null && ctor.isA<JSFunction>()) {
      abortCtrl = (ctor as JSFunction).callAsConstructor<JSObject>();
      init.setProperty('signal'.toJS, abortCtrl.getProperty<JSAny?>('signal'.toJS));
    }
  } catch (_) {}

  void abortQuietly() {
    try {
      abortCtrl?.callMethod<JSAny?>('abort'.toJS);
    } catch (_) {}
  }

  final deadline = DateTime.now().add(timeout);
  final fetchFn = globalContext.getProperty<JSFunction>('fetch'.toJS);
  final promise = fetchFn.callAsFunction(null, uri.toString().toJS, init) as JSPromise<JSObject>;
  final JSObject resp;
  try {
    resp = await promise.toDart.timeout(timeout);
  } on TimeoutException {
    abortQuietly();
    rethrow;
  }
  final status = (resp.getProperty<JSNumber>('status'.toJS)).toDartInt;
  final rem = deadline.difference(DateTime.now());
  final readBudget = rem > const Duration(milliseconds: 500) ? rem : const Duration(milliseconds: 500);
  final textFn = resp.getProperty<JSFunction>('text'.toJS);
  final textPromise = textFn.callAsFunction(resp) as JSPromise<JSString>;
  final String body;
  try {
    body = (await textPromise.toDart.timeout(readBudget)).toDart;
  } on TimeoutException {
    abortQuietly();
    rethrow;
  }
  if (body.length > maxBytes) {
    throw StateError('响应体超过 ${(maxBytes / (1024 * 1024)).toStringAsFixed(0)} MB 安全上限');
  }
  return AppUpdateHttpResponse(statusCode: status, body: body);
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
  throw UnsupportedError('Web 端请直接通过浏览器下载 APK 安装包');
}
