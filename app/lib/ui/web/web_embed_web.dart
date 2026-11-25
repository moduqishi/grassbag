import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

@JS('document')
external JSObject get _document;

@JS('window')
external JSObject get _window;

final Map<String, JSObject> _iframes = <String, JSObject>{};
final Map<String, String> _iframeUrls = <String, String>{};
final Map<String, String> _appliedIframeUrls = <String, String>{};
final Set<String> _registeredViews = <String>{};

bool get supportsWebIframeEmbed => true;

Widget buildWebIframeView({
  required String viewType,
  required String url,
}) {
  _iframeUrls[viewType] = url;
  if (_registeredViews.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final iframe = _document.callMethod<JSObject>('createElement'.toJS, 'iframe'.toJS);
      final targetUrl = _iframeUrls[viewType] ?? url;
      iframe.setProperty('src'.toJS, targetUrl.toJS);
      _appliedIframeUrls[viewType] = targetUrl;
      iframe.setProperty('allow'.toJS, 'clipboard-read; clipboard-write; fullscreen'.toJS);
      iframe.setProperty('referrerPolicy'.toJS, 'no-referrer'.toJS);
      final style = iframe.getProperty<JSObject>('style'.toJS);
      style.setProperty('border'.toJS, '0'.toJS);
      style.setProperty('width'.toJS, '100%'.toJS);
      style.setProperty('height'.toJS, '100%'.toJS);
      style.setProperty('display'.toJS, 'block'.toJS);
      style.setProperty('background'.toJS, 'transparent'.toJS);
      _iframes[viewType] = iframe;
      return iframe;
    });
  } else {
    updateWebIframeUrl(viewType, url);
  }
  return HtmlElementView(viewType: viewType);
}

void updateWebIframeUrl(String viewType, String url, {bool forceReload = false}) {
  _iframeUrls[viewType] = url;
  final iframe = _iframes[viewType];
  if (iframe == null) return;
  // Compare against our own last-applied URL string instead of DOM `iframe.src` (which
  // browsers normalize by appending a trailing `/`, previously causing infinite iframe reloads!).
  final lastApplied = _appliedIframeUrls[viewType];
  if (forceReload || lastApplied != url) {
    if (forceReload && lastApplied == url) {
      iframe.setProperty('src'.toJS, 'about:blank'.toJS);
    }
    iframe.setProperty('src'.toJS, url.toJS);
    _appliedIframeUrls[viewType] = url;
  }
}

void disposeWebIframe(String viewType) {
  _iframeUrls.remove(viewType);
  _appliedIframeUrls.remove(viewType);
  final iframe = _iframes.remove(viewType);
  if (iframe != null) {
    try {
      iframe.setProperty('src'.toJS, 'about:blank'.toJS);
    } catch (_) {}
  }
}

bool openUrlInNewTab(String url) {
  try {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    // Do NOT pass 'noopener' in windowFeatures because HTML spec mandates returning `null`
    // even when the popup succeeds; instead clear `win.opener = null` after opening.
    final win = _window.callMethod<JSObject?>('open'.toJS, uri.toString().toJS, '_blank'.toJS);
    if (win != null) {
      try {
        win.setProperty('opener'.toJS, null);
      } catch (_) {}
      return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

String? readBrowserQueryParam(String key) {
  try {
    final loc = _window.getProperty<JSObject>('location'.toJS);
    final href = loc.getProperty<JSAny?>('href'.toJS)?.dartify()?.toString();
    if (href == null || href.isEmpty) return null;
    final uri = Uri.tryParse(href);
    return uri?.queryParameters[key];
  } catch (_) {
    return null;
  }
}

String? readBrowserOrigin() {
  try {
    final loc = _window.getProperty<JSObject>('location'.toJS);
    return loc.getProperty<JSAny?>('origin'.toJS)?.dartify()?.toString();
  } catch (_) {
    return null;
  }
}

/// Real browser file picker (`<input type="file">`) returning actual file bytes.
Future<({String name, String mimeType, Uint8List bytes})?> pickWebFile({
  String accept = '*/*',
}) async {
  final completer = Completer<({String name, String mimeType, Uint8List bytes})?>();
  JSObject? inputEl;
  JSFunction? onWindowFocus;
  void cleanup() {
    try {
      if (onWindowFocus != null) {
        _window.callMethod<JSAny?>('removeEventListener'.toJS, 'focus'.toJS, onWindowFocus);
        onWindowFocus = null;
      }
      if (inputEl != null) {
        inputEl!.callMethod<JSAny?>('remove'.toJS);
        inputEl = null;
      }
    } catch (_) {}
  }

  try {
    final input = _document.callMethod<JSObject>('createElement'.toJS, 'input'.toJS);
    inputEl = input;
    input.setProperty('type'.toJS, 'file'.toJS);
    input.setProperty('accept'.toJS, accept.toJS);
    final style = input.getProperty<JSObject>('style'.toJS);
    style.setProperty('display'.toJS, 'none'.toJS);
    final body = _document.getProperty<JSObject?>('body'.toJS);
    body?.callMethod<JSAny?>('appendChild'.toJS, input);

    final onChange = ((JSAny? _) {
      final files = input.getProperty<JSObject?>('files'.toJS);
      final len = (files?.getProperty<JSNumber?>('length'.toJS)?.toDartInt) ?? 0;
      if (files == null || len <= 0) {
        cleanup();
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      final file = files.callMethod<JSObject>('item'.toJS, 0.toJS);
      final name = file.getProperty<JSAny?>('name'.toJS)?.dartify()?.toString() ?? 'file';
      final mime = file.getProperty<JSAny?>('type'.toJS)?.dartify()?.toString() ??
          'application/octet-stream';
      final reader = _window.getProperty<JSFunction>('FileReader'.toJS).callAsConstructor<JSObject>();
      reader.setProperty(
        'onload'.toJS,
        ((JSAny? _) {
          cleanup();
          try {
            final res = reader.getProperty<JSArrayBuffer?>('result'.toJS);
            final bytes = res != null ? res.toDart.asUint8List() : Uint8List(0);
            if (!completer.isCompleted) {
              completer.complete((
                name: name,
                mimeType: mime.isEmpty ? 'application/octet-stream' : mime,
                bytes: bytes,
              ));
            }
          } catch (_) {
            if (!completer.isCompleted) completer.complete(null);
          }
        }).toJS,
      );
      reader.setProperty(
        'onerror'.toJS,
        ((JSAny? _) {
          cleanup();
          if (!completer.isCompleted) completer.complete(null);
        }).toJS,
      );
      reader.callMethod<JSAny?>('readAsArrayBuffer'.toJS, file);
    }).toJS;

    final onCancel = ((JSAny? _) {
      cleanup();
      if (!completer.isCompleted) completer.complete(null);
    }).toJS;

    onWindowFocus = ((JSAny? _) {
      // Safari fallback: if user dismissed file picker without firing `cancel`.
      Timer(const Duration(milliseconds: 350), () {
        final files = inputEl?.getProperty<JSObject?>('files'.toJS);
        final len = (files?.getProperty<JSNumber?>('length'.toJS)?.toDartInt) ?? 0;
        if (len <= 0 && !completer.isCompleted) {
          cleanup();
          completer.complete(null);
        }
      });
    }).toJS;

    input.callMethod<JSAny?>('addEventListener'.toJS, 'change'.toJS, onChange);
    input.callMethod<JSAny?>('addEventListener'.toJS, 'cancel'.toJS, onCancel);
    _window.callMethod<JSAny?>('addEventListener'.toJS, 'focus'.toJS, onWindowFocus!);
    input.callMethod<JSAny?>('click'.toJS);
  } catch (_) {
    cleanup();
    if (!completer.isCompleted) completer.complete(null);
  }
  return completer.future;
}

/// Real browser file download for Markdown/JSON exports.
bool downloadWebTextFile(String filename, String content) {
  try {
    final blobCtor = _window.getProperty<JSFunction>('Blob'.toJS);
    final parts = <JSAny>[content.toJS].toJS;
    final opts = JSObject()..setProperty('type'.toJS, 'text/markdown;charset=utf-8'.toJS);
    final blob = blobCtor.callAsConstructor<JSObject>(parts, opts);
    final urlApi = _window.getProperty<JSObject>('URL'.toJS);
    final href = urlApi.callMethod<JSString>('createObjectURL'.toJS, blob);
    final a = _document.callMethod<JSObject>('createElement'.toJS, 'a'.toJS);
    a.setProperty('href'.toJS, href);
    a.setProperty('download'.toJS, filename.toJS);
    a.callMethod<JSAny?>('click'.toJS);
    Timer(const Duration(seconds: 5), () {
      try {
        urlApi.callMethod<JSAny?>('revokeObjectURL'.toJS, href);
      } catch (_) {}
    });
    return true;
  } catch (_) {
    return false;
  }
}
