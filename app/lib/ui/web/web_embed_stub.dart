import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// Platform stub for non-Web builds (Android / iOS / macOS / VM tests).
bool get supportsWebIframeEmbed => false;

Widget buildWebIframeView({
  required String viewType,
  required String url,
}) {
  return const SizedBox.shrink();
}

void updateWebIframeUrl(String viewType, String url, {bool forceReload = false}) {}

void disposeWebIframe(String viewType) {}

bool openUrlInNewTab(String url) => false;

String? readBrowserQueryParam(String key) => null;

String? readBrowserOrigin() => null;

Future<({String name, String mimeType, Uint8List bytes})?> pickWebFile({
  String accept = '*/*',
}) async =>
    null;

bool downloadWebTextFile(String filename, String content) => false;
