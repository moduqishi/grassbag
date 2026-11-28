import 'dart:async';
import 'dart:typed_data';

import 'models.dart';
import 'raw_ws.dart';
import 'vanilla_mux.dart';

/// Web/non-IO stub transport so GrassBag Flutter Web preview compiles seamlessly.
class GbridgeHttpTransport {
  GbridgeHttpTransport(
    this.endpoint, {
    Duration? timeout,
    bool allowBadCertificates = false,
    this.onCookieUpdated,
  });

  final HostEndpoint endpoint;
  final void Function(String cookieHeader)? onCookieUpdated;

  String? get cookieHeader => null;
  String? get lastAuthErrorCode => null;
  void setCookieHeader(String? cookie) {}
  void evictDshAuthCookies() {}
  void resetConnectionPool() {}

  Future<bool> exchangeAuthToken([String? tokenOverride]) async => false;

  Future<String?> probeDshSseVersion({Duration timeout = const Duration(seconds: 4)}) async => null;

  Future<GbridgeRawWebSocket> openRawWebSocket(String path) async {
    throw const GbridgeException(
      status: 503,
      code: 'gbridge/web_preview_only',
      message: 'WebSocket transport is disabled in stub mode.',
    );
  }

  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool retryAuth = true,
  }) async {
    throw const GbridgeException(
      status: 503,
      code: 'gbridge/web_preview_only',
      message: 'Direct socket transport is disabled in Flutter Web preview mode.',
    );
  }

  Future<Uint8List> requestBytes(
    String method,
    String path, {
    Map<String, String>? query,
    Uint8List? bodyBytes,
    String? contentType,
  }) async {
    throw const GbridgeException(
      status: 503,
      code: 'gbridge/web_preview_only',
      message: 'Direct socket transport is disabled in Flutter Web preview mode.',
    );
  }

  void close({bool force = false}) {}
}

class GbridgeStreamClient {
  GbridgeStreamClient(
    this.transport, {
    this.wsPath = '/gbridge/v1/stream',
    this.clientId = 'grassbag-web',
    this.coalesceMs = 35,
    this.autoReconnect = true,
  });

  final GbridgeHttpTransport transport;
  final String wsPath;
  final String clientId;
  final int coalesceMs;
  final bool autoReconnect;

  final _framesController = StreamController<StreamFrame>.broadcast();
  final _phaseController = StreamController<ConnectionPhase>.broadcast();
  final _welcomeController = StreamController<WelcomeInfo>.broadcast();

  Stream<StreamFrame> get frames => _framesController.stream;
  Stream<ConnectionPhase> get phases => _phaseController.stream;
  Stream<WelcomeInfo> get welcomes => _welcomeController.stream;
  ConnectionPhase get phase => ConnectionPhase.disconnected;
  int get lastSeq => 0;

  void attachVanillaMux(VanillaDshMuxEngine? engine) {}

  Future<WelcomeInfo> connect() async {
    throw const GbridgeException(
      status: 503,
      code: 'gbridge/web_preview_only',
      message: 'WebSocket transport is disabled in Flutter Web preview mode.',
    );
  }

  void subscribe(String channel, {bool force = false}) {}
  void unsubscribe(String channel) {}
  void sendTerminalInput(String terminalId, String data) {}
  void sendTerminalResize(String terminalId, int cols, int rows) {}
  void sendPing([String? id]) {}
  void reconnectNow() {}
  Future<bool> checkLiveness({
    Duration timeout = const Duration(seconds: 3),
    bool force = false,
  }) async =>
      false;
  Future<void> disconnect() async {}

  Future<void> dispose() async {
    await _framesController.close();
    await _phaseController.close();
    await _welcomeController.close();
  }
}
