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
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  try {
    if (Platform.isMacOS) {
      Process.start('open', [uri.toString()], mode: ProcessStartMode.detached);
      return true;
    }
    if (Platform.isLinux) {
      Process.start('xdg-open', [uri.toString()], mode: ProcessStartMode.detached);
      return true;
    }
    if (Platform.isWindows) {
      Process.start('cmd', ['/c', 'start', '', uri.toString()], mode: ProcessStartMode.detached);
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

bool downloadWebTextFile(String filename, String content) => false;
