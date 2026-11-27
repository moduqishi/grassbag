import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// Platform IO implementation (Android / iOS / macOS / Linux / Windows / VM).
bool get supportsWebIframeEmbed => false;

Widget buildWebIframeView({
  required String viewType,
  required String url,
}) {
  return const SizedBox.shrink();
}

void updateWebIframeUrl(String viewType, String url, {bool forceReload = false}) {}

void disposeWebIframe(String viewType) {}

/// Launches `http://` or `https://` URLs in the system browser on desktop platforms.
/// Returns `false` on mobile (Android/iOS handled via [GrassBagNativeBridge.openExternalUrl])
/// or when the URL scheme is unsupported.
bool openUrlInNewTab(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return false;
  }
  try {
    if (Platform.isMacOS) {
      unawaited(
        Process.start('open', [uri.toString()], mode: ProcessStartMode.detached)
            .then<void>((_) {}, onError: (_) {}),
      );
      return true;
    }
    if (Platform.isLinux) {
      unawaited(
        Process.start('xdg-open', [uri.toString()], mode: ProcessStartMode.detached)
            .then<void>((_) {}, onError: (_) {}),
      );
      return true;
    }
    if (Platform.isWindows) {
      unawaited(
        Process.start(
          'rundll32',
          ['url.dll,FileProtocolHandler', uri.toString()],
          mode: ProcessStartMode.detached,
        ).then<void>((_) {}, onError: (_) {}),
      );
      return true;
    }
  } catch (_) {}
  return false;
}

String? readBrowserQueryParam(String key) => null;

String? readBrowserOrigin() => null;

Future<({String name, String mimeType, Uint8List bytes})?> pickWebFile({
  String accept = '*/*',
}) async =>
    null;

bool downloadWebTextFile(String filename, String content) {
  return downloadWebBytes(
    filename,
    Uint8List.fromList(utf8.encode(content)),
    mimeType: 'text/plain',
  );
}

/// Downloads raw bytes from an `http://` or `https://` URL (e.g. for saving/sharing
/// remote Markdown images in the lightbox), capped at [maxBytes].
Future<Uint8List?> fetchRemoteBytes(
  String url, {
  int maxBytes = 24 * 1024 * 1024,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return null;
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    final res = await req.close().timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in res.timeout(timeout)) {
      total += chunk.length;
      if (total > maxBytes) return null;
      builder.add(chunk);
    }
    return builder.takeBytes();
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Saves bytes to `~/Downloads` on desktop platforms (macOS / Linux / Windows).
/// Returns `false` on mobile (Android/iOS handled via [GrassBagNativeBridge]).
bool downloadWebBytes(
  String filename,
  Uint8List bytes, {
  String mimeType = 'application/octet-stream',
}) {
  if (bytes.isEmpty || Platform.isAndroid || Platform.isIOS) return false;
  try {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) return false;
    final downloads = Directory('$home${Platform.pathSeparator}Downloads');
    if (!downloads.existsSync()) downloads.createSync(recursive: true);
    final safeName = filename
        .replaceAll(RegExp(r'[/\\:*?"<>|\r\n]+'), '_')
        .trim();
    final base = safeName.isEmpty ? 'grassbag-file' : safeName;
    var target = File('${downloads.path}${Platform.pathSeparator}$base');
    if (target.existsSync()) {
      final dot = base.lastIndexOf('.');
      final stem = dot > 0 ? base.substring(0, dot) : base;
      final ext = dot > 0 ? base.substring(dot) : '';
      for (var i = 1; i < 100; i++) {
        final cand = File('${downloads.path}${Platform.pathSeparator}$stem ($i)$ext');
        if (!cand.existsSync()) {
          target = cand;
          break;
        }
      }
    }
    target.writeAsBytesSync(bytes, flush: true);
    return true;
  } catch (_) {
    return false;
  }
}
