import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';
import 'raw_ws.dart';
import 'vanilla_mux.dart';

/// Browser Fetch + WebSocket transport for Flutter Web (`dart:js_interop`),
/// allowing Flutter Web to connect live to any local/remote DSH + `dsh-gbridge` host.
class GbridgeHttpTransport {
  GbridgeHttpTransport(
    this.endpoint, {
    Duration? timeout,
    bool allowBadCertificates = false,
    this.onCookieUpdated,
  }) : timeout = timeout ?? const Duration(seconds: 25);

  final HostEndpoint endpoint;
  final Duration timeout;
  final void Function(String cookieHeader)? onCookieUpdated;
  Future<bool>? _authExchangeFuture;
  bool _closed = false;

  String? get cookieHeader => null;
  void setCookieHeader(String? cookie) {}
  void evictDshAuthCookies() {}
  void resetConnectionPool() {}

  Future<String?> probeDshSseVersion({Duration timeout = const Duration(seconds: 4)}) async {
    return null;
  }

  Future<GbridgeRawWebSocket> openRawWebSocket(String path) async {
    final token = endpoint.token;
    var cookieReady = false;
    if (token != null && token.isNotEmpty) {
      final exchanged = await exchangeAuthToken();
      final baseOrigin = endpoint.baseUri?.origin;
      final pageOrigin = (() {
        try {
          final loc = globalContext.getProperty<JSObject?>('location'.toJS);
          final orig = loc?.getProperty<JSAny?>('origin'.toJS);
          return (orig != null && orig.isA<JSString>()) ? (orig as JSString).toDart : null;
        } catch (_) {
          return null;
        }
      })();
      cookieReady = exchanged && baseOrigin != null && pageOrigin != null && baseOrigin == pageOrigin;
    }
    var wsUri = endpoint.resolveWsUri(path);
    if (!cookieReady && token != null && token.isNotEmpty) {
      wsUri = wsUri.replace(queryParameters: {...wsUri.queryParameters, 'token': token});
    }
    final ctor = globalContext.getProperty<JSFunction>('WebSocket'.toJS);
    final ws = ctor.callAsConstructor<JSObject>(wsUri.toString().toJS);
    final openCompleter = Completer<void>();
    void clearHandshakeHandlers() {
      try {
        ws.setProperty('onopen'.toJS, null);
        ws.setProperty('onerror'.toJS, null);
        ws.setProperty('onclose'.toJS, null);
      } catch (_) {}
    }
    ws.setProperty(
      'onopen'.toJS,
      ((JSAny? _) {
        if (!openCompleter.isCompleted) openCompleter.complete();
      }).toJS,
    );
    ws.setProperty(
      'onerror'.toJS,
      ((JSAny? _) {
        if (!openCompleter.isCompleted) {
          openCompleter.completeError(const GbridgeException(
            status: 0,
            code: 'gbridge/ws_open_failed',
            message: 'WebSocket connection failed',
          ));
        }
      }).toJS,
    );
    ws.setProperty(
      'onclose'.toJS,
      ((JSObject? ev) {
        if (!openCompleter.isCompleted) {
          final codeAny = ev?.getProperty<JSAny?>('code'.toJS);
          final code = (codeAny != null && codeAny.isA<JSNumber>()) ? (codeAny as JSNumber).toDartInt : null;
          final authErr = code == 4001 || code == 1008;
          openCompleter.completeError(GbridgeException(
            status: authErr ? 401 : 0,
            code: authErr ? 'gbridge/unauthorized' : 'gbridge/ws_closed',
            message: authErr ? 'WebSocket authorization rejected' : 'WebSocket closed during handshake',
          ));
        }
      }).toJS,
    );
    try {
      await openCompleter.future.timeout(timeout);
      clearHandshakeHandlers();
    } catch (err) {
      clearHandshakeHandlers();
      try {
        ws.callMethod('close'.toJS);
      } catch (_) {}
      // Browsers mask HTTP 401/403 WS upgrade rejections behind opaque `onerror`.
      // Probe an authenticated HTTP endpoint so Vanilla Direct Mode surfaces `needsAuth` instead of looping!
      if (err is GbridgeException && err.status == 0) {
        try {
          final probeUri = endpoint.resolveHttpUri('/api/settings/describe');
          final probeInit = JSObject();
          probeInit.setProperty('method'.toJS, 'POST'.toJS);
          probeInit.setProperty('credentials'.toJS, 'include'.toJS);
          final probeHeaders = JSObject();
          probeHeaders.setProperty('Content-Type'.toJS, 'application/json'.toJS);
          for (final e in buildAuthHeaders().entries) {
            probeHeaders.setProperty(e.key.toJS, e.value.toJS);
          }
          probeInit.setProperty('headers'.toJS, probeHeaders);
          probeInit.setProperty('body'.toJS, '{"type":"client-request","method":"settings/describe","payload":{"args":{}}}'.toJS);
          final probeFetched = await _fetchWithAbort(
            probeUri,
            probeInit,
            timeoutOverride: const Duration(seconds: 4),
          );
          final probeStatus = (probeFetched.response.getProperty<JSNumber>('status'.toJS)).toDartInt;
          _abortQuietly(probeFetched.abortCtrl);
          if (probeStatus == 401 || probeStatus == 403) {
            throw GbridgeException(
              status: probeStatus,
              code: 'gbridge/unauthorized',
              message: 'WebSocket authorization rejected (HTTP $probeStatus)',
            );
          }
        } on GbridgeException {
          rethrow;
        } catch (_) {}
      }
      rethrow;
    }
    return _WebRawWebSocket(ws);
  }

  Future<({JSObject response, JSObject? abortCtrl, DateTime deadline})> _fetchWithAbort(
    Uri uri,
    JSObject init, {
    Duration? timeoutOverride,
  }) async {
    final budget = timeoutOverride ?? timeout;
    final deadline = DateTime.now().add(budget);
    JSObject? abortCtrl;
    try {
      final ctor = globalContext.getProperty<JSAny?>('AbortController'.toJS);
      if (ctor != null && ctor.isA<JSFunction>()) {
        abortCtrl = (ctor as JSFunction).callAsConstructor<JSObject>();
        init.setProperty('signal'.toJS, abortCtrl.getProperty<JSAny?>('signal'.toJS));
      }
    } catch (_) {}
    try {
      final response = await globalContext
          .callMethod<JSPromise<JSObject>>('fetch'.toJS, uri.toString().toJS, init)
          .toDart
          .timeout(budget);
      return (response: response, abortCtrl: abortCtrl, deadline: deadline);
    } on TimeoutException {
      try {
        abortCtrl?.callMethod<JSAny?>('abort'.toJS);
      } catch (_) {}
      rethrow;
    }
  }

  static void _abortQuietly(JSObject? abortCtrl) {
    try {
      abortCtrl?.callMethod<JSAny?>('abort'.toJS);
    } catch (_) {}
  }

  static Duration _remainingFor(DateTime deadline) {
    final rem = deadline.difference(DateTime.now());
    return rem > const Duration(milliseconds: 500) ? rem : const Duration(milliseconds: 500);
  }

  static bool _shouldRetry503Text(String text, String method) {
    if (text.contains('gbridge/reloading')) return true;
    final m = method.toUpperCase();
    if (m != 'GET' && m != 'HEAD') return false;
    if (text.contains('gbridge/web_unavailable') ||
        text.contains('gbridge/auth_unconfigured') ||
        text.contains('gbridge/gateway_unavailable')) {
      return false;
    }
    return false;
  }

  Future<bool> exchangeAuthToken([String? tokenOverride]) {
    final token = tokenOverride ?? endpoint.token;
    if (token == null || token.isEmpty || endpoint.isUnixSocket) {
      return Future.value(false);
    }
    if (tokenOverride == null && _authExchangeFuture != null) {
      return _authExchangeFuture!;
    }
    Future<bool> run() async {
      try {
        final uri = endpoint.resolveHttpUri('/', {'token': token});
        final init = JSObject();
        init.setProperty('method'.toJS, 'GET'.toJS);
        init.setProperty('credentials'.toJS, 'include'.toJS);
        final fetched = await _fetchWithAbort(uri, init);
        final status = (fetched.response.getProperty<JSNumber>('status'.toJS)).toDartInt;
        _abortQuietly(fetched.abortCtrl);
        return status >= 200 && status < 400;
      } catch (_) {
        return false;
      }
    }

    final future = run();
    if (tokenOverride == null) {
      _authExchangeFuture = future;
      future.whenComplete(() {
        if (identical(_authExchangeFuture, future)) {
          _authExchangeFuture = null;
        }
      }).ignore();
    }
    return future;
  }

  Map<String, String> buildAuthHeaders() {
    final headers = <String, String>{};
    if (endpoint.token != null && endpoint.token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${endpoint.token}';
    }
    return headers;
  }

  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool retryAuth = true,
    int reloadRetryAttempt = 0,
    Duration? timeoutOverride,
  }) async {
    if (_closed) {
      throw const GbridgeException(
        status: 0,
        code: 'gbridge/client_closed',
        message: 'transport is closed',
      );
    }
    if (endpoint.isUnixSocket) {
      throw const GbridgeException(
        status: 503,
        code: 'gbridge/unix_socket_unsupported_on_web',
        message: 'Unix Domain Socket is only available on native Android/Desktop hosts.',
      );
    }

    final uri = endpoint.resolveHttpUri(path, query);
    final headersObj = JSObject();
    headersObj.setProperty('Accept'.toJS, 'application/json'.toJS);
    for (final e in buildAuthHeaders().entries) {
      headersObj.setProperty(e.key.toJS, e.value.toJS);
    }

    final init = JSObject();
    init.setProperty('method'.toJS, method.toJS);
    init.setProperty('credentials'.toJS, 'include'.toJS);
    if (body != null) {
      headersObj.setProperty('Content-Type'.toJS, 'application/json'.toJS);
      init.setProperty('body'.toJS, jsonEncode(body).toJS);
    }
    init.setProperty('headers'.toJS, headersObj);

    final fetched = await _fetchWithAbort(uri, init, timeoutOverride: timeoutOverride);
    final response = fetched.response;
    final status = (response.getProperty<JSNumber>('status'.toJS)).toDartInt;
    if (status == 401 && retryAuth && (endpoint.token?.isNotEmpty ?? false)) {
      String errBody = '';
      try {
        errBody = (await response
                .callMethod<JSPromise<JSString>>('text'.toJS)
                .toDart
                .timeout(const Duration(seconds: 3)))
            .toDart;
      } catch (_) {}
      _abortQuietly(fetched.abortCtrl);
      final exchanged = await exchangeAuthToken();
      if (exchanged) {
        return requestJson(
          method,
          path,
          query: query,
          body: body,
          retryAuth: false,
          reloadRetryAttempt: reloadRetryAttempt,
          timeoutOverride: timeoutOverride,
        );
      }
      _throwTextError(401, errBody);
    }
    String text;
    try {
      text = (await response
              .callMethod<JSPromise<JSString>>('text'.toJS)
              .toDart
              .timeout(_remainingFor(fetched.deadline)))
          .toDart;
    } on TimeoutException {
      _abortQuietly(fetched.abortCtrl);
      rethrow;
    }
    if (status == 503 && reloadRetryAttempt < 4 && _shouldRetry503Text(text, method)) {
      const delaysMs = <int>[220, 420, 700, 1100];
      await Future<void>.delayed(Duration(milliseconds: delaysMs[reloadRetryAttempt]));
      if (!_closed) {
        return requestJson(
          method,
          path,
          query: query,
          body: body,
          retryAuth: retryAuth,
          reloadRetryAttempt: reloadRetryAttempt + 1,
          timeoutOverride: timeoutOverride,
        );
      }
    }

    if (status >= 400) {
      _throwTextError(status, text);
    }
    if (text.trim().isEmpty) return const <String, dynamic>{};
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('<!doctype') ||
        trimmed.startsWith('<!DOCTYPE') ||
        trimmed.startsWith('<html') ||
        trimmed.startsWith('<HTML')) {
      throw GbridgeException(
        status: status,
        code: 'gbridge/html_response',
        message: '目标地址返回了 HTML 网页而非 API JSON（可能为网页登录认证页或反代拦截）',
      );
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'data': decoded};
    } on FormatException catch (e) {
      throw GbridgeException(
        status: status,
        code: 'gbridge/invalid_json',
        message: '响应体不是合法的 JSON 格式: ${e.message}',
      );
    }
  }

  Future<Uint8List> requestBytes(
    String method,
    String path, {
    Map<String, String>? query,
    Uint8List? bodyBytes,
    String? contentType,
    bool retryAuth = true,
    int reloadRetryAttempt = 0,
  }) async {
    if (_closed) {
      throw const GbridgeException(
        status: 0,
        code: 'gbridge/client_closed',
        message: 'transport is closed',
      );
    }
    if (endpoint.isUnixSocket) {
      throw const GbridgeException(
        status: 503,
        code: 'gbridge/unix_socket_unsupported_on_web',
        message: 'Unix Domain Socket is only available on native Android/Desktop hosts.',
      );
    }

    final uri = endpoint.resolveHttpUri(path, query);
    final headersObj = JSObject();
    for (final e in buildAuthHeaders().entries) {
      headersObj.setProperty(e.key.toJS, e.value.toJS);
    }
    final init = JSObject();
    init.setProperty('method'.toJS, method.toJS);
    init.setProperty('credentials'.toJS, 'include'.toJS);
    if (bodyBytes != null) {
      headersObj.setProperty('Content-Type'.toJS, (contentType ?? 'application/octet-stream').toJS);
      init.setProperty('body'.toJS, bodyBytes.toJS);
    }
    init.setProperty('headers'.toJS, headersObj);

    final fetched = await _fetchWithAbort(uri, init);
    final response = fetched.response;
    final status = (response.getProperty<JSNumber>('status'.toJS)).toDartInt;
    if (status == 401 && retryAuth && (endpoint.token?.isNotEmpty ?? false)) {
      String errBody = '';
      try {
        errBody = (await response
                .callMethod<JSPromise<JSString>>('text'.toJS)
                .toDart
                .timeout(const Duration(seconds: 3)))
            .toDart;
      } catch (_) {}
      _abortQuietly(fetched.abortCtrl);
      final exchanged = await exchangeAuthToken();
      if (exchanged) {
        return requestBytes(
          method,
          path,
          query: query,
          bodyBytes: bodyBytes,
          contentType: contentType,
          retryAuth: false,
          reloadRetryAttempt: reloadRetryAttempt,
        );
      }
      _throwTextError(401, errBody);
    }
    if (status >= 400) {
      String text;
      try {
        text = (await response
                .callMethod<JSPromise<JSString>>('text'.toJS)
                .toDart
                .timeout(_remainingFor(fetched.deadline)))
            .toDart;
      } on TimeoutException {
        _abortQuietly(fetched.abortCtrl);
        rethrow;
      }
      if (status == 503 && reloadRetryAttempt < 4 && _shouldRetry503Text(text, method)) {
        const delaysMs = <int>[220, 420, 700, 1100];
        await Future<void>.delayed(Duration(milliseconds: delaysMs[reloadRetryAttempt]));
        if (!_closed) {
          return requestBytes(
            method,
            path,
            query: query,
            bodyBytes: bodyBytes,
            contentType: contentType,
            retryAuth: retryAuth,
            reloadRetryAttempt: reloadRetryAttempt + 1,
          );
        }
      }
      _throwTextError(status, text);
    }
    try {
      final buf = await response
          .callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS)
          .toDart
          .timeout(_remainingFor(fetched.deadline));
      return buf.toDart.asUint8List();
    } on TimeoutException {
      _abortQuietly(fetched.abortCtrl);
      rethrow;
    }
  }

  Never _throwTextError(int status, String text) {
    String code = 'gbridge/http_$status';
    String message = 'HTTP $status';
    Object? details;
    if (text.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) {
          final err = decoded['error'];
          if (err is Map<String, dynamic>) {
            code = err['code']?.toString() ?? code;
            message = err['message']?.toString() ?? message;
            details = err['details'];
          } else {
            code = decoded['code']?.toString() ?? code;
            message = decoded['message']?.toString() ?? message;
          }
        }
      } catch (_) {
        message = text.trim();
      }
    }
    throw GbridgeException(status: status, code: code, message: message, details: details);
  }

  void close({bool force = false}) {
    _closed = true;
  }
}

class _WebRawWebSocket implements GbridgeRawWebSocket {
  _WebRawWebSocket(this._ws) {
    _ws.setProperty(
      'onmessage'.toJS,
      ((JSObject event) {
        final data = event.getProperty<JSAny?>('data'.toJS);
        if (data != null && data.isA<JSString>() && !_messages.isClosed) {
          _messages.add((data as JSString).toDart);
        }
      }).toJS,
    );
    _ws.setProperty(
      'onerror'.toJS,
      ((JSAny? _) {
        if (!_done.isCompleted) _done.complete();
      }).toJS,
    );
    _ws.setProperty(
      'onclose'.toJS,
      ((JSAny? _) {
        if (!_messages.isClosed) unawaited(_messages.close());
        if (!_done.isCompleted) _done.complete();
      }).toJS,
    );
  }

  final JSObject _ws;
  final _messages = StreamController<String>.broadcast();
  final _done = Completer<void>();

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void sendText(String text) {
    try {
      _ws.callMethod<JSAny?>('send'.toJS, text.toJS);
    } catch (_) {}
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    try {
      _ws.callMethod<JSAny?>('close'.toJS, (code ?? 1000).toJS, (reason ?? 'closed').toJS);
    } catch (_) {}
    if (!_messages.isClosed) await _messages.close();
    if (!_done.isCompleted) _done.complete();
  }
}

class GbridgeStreamClient {
  GbridgeStreamClient(
    this._transport, {
    this.wsPath = '/gbridge/v1/stream',
    this.clientId = 'grassbag-web',
    this.coalesceMs = 35,
    this.autoReconnect = true,
  });

  final GbridgeHttpTransport _transport;
  final String wsPath;
  final String clientId;
  final int coalesceMs;
  final bool autoReconnect;

  final _framesController = StreamController<StreamFrame>.broadcast();
  final _phaseController = StreamController<ConnectionPhase>.broadcast();
  final _welcomeController = StreamController<WelcomeInfo>.broadcast();
  final Set<String> _channels = <String>{'host'};
  Set<String> _sentHelloChannels = const <String>{};

  JSObject? _ws;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;

  ConnectionPhase _phase = ConnectionPhase.disconnected;
  String? _lastBootId;
  int _lastSeq = 0;
  int _reconnectAttempt = 0;
  int _connEpoch = 0;
  int _lastAckedSeq = 0;
  Timer? _pongTimeoutTimer;
  Completer<bool>? _livenessProbe;
  bool _disposed = false;
  bool _manualDisconnect = false;
  Completer<WelcomeInfo>? _pendingWelcome;

  VanillaDshMuxEngine? _vanillaMux;
  StreamSubscription<StreamFrame>? _muxFramesSub;
  StreamSubscription<ConnectionPhase>? _muxPhasesSub;
  StreamSubscription<WelcomeInfo>? _muxWelcomesSub;

  void attachVanillaMux(VanillaDshMuxEngine? engine) {
    _muxFramesSub?.cancel();
    _muxPhasesSub?.cancel();
    _muxWelcomesSub?.cancel();
    _muxFramesSub = null;
    _muxPhasesSub = null;
    _muxWelcomesSub = null;
    _vanillaMux = engine;
    if (engine != null) {
      for (final ch in _channels) {
        engine.subscribe(ch);
      }
      _muxFramesSub = engine.frames.listen((f) {
        if (f.seq != null && f.seq! > _lastSeq) _lastSeq = f.seq!;
        if (!_framesController.isClosed) _framesController.add(f);
      });
      _muxPhasesSub = engine.phases.listen(_setPhase);
      _muxWelcomesSub = engine.welcomes.listen((w) {
        if (!_welcomeController.isClosed) _welcomeController.add(w);
      });
    }
  }

  Stream<StreamFrame> get frames => _framesController.stream;
  Stream<ConnectionPhase> get phases => _phaseController.stream;
  Stream<WelcomeInfo> get welcomes => _welcomeController.stream;
  ConnectionPhase get phase => _phase;
  String? get lastBootId => _lastBootId;
  int get lastSeq => _lastSeq;
  Set<String> get subscribedChannels => Set.unmodifiable(_channels);

  void _closeCurrentSocket() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _pongTimeoutTimer?.cancel();
    _pongTimeoutTimer = null;
    final probe = _livenessProbe;
    _livenessProbe = null;
    if (probe != null && !probe.isCompleted) probe.complete(false);
    final old = _ws;
    _ws = null;
    if (old != null) {
      try {
        old.setProperty('onopen'.toJS, null);
        old.setProperty('onmessage'.toJS, null);
        old.setProperty('onerror'.toJS, null);
        old.setProperty('onclose'.toJS, null);
      } catch (_) {}
      try {
        old.callMethod<JSAny?>('close'.toJS);
      } catch (_) {}
    }
  }

  Future<WelcomeInfo> connect() async {
    if (_vanillaMux != null) {
      return _vanillaMux!.connect();
    }
    if (_disposed) {
      throw const GbridgeException(
        status: 0,
        code: 'gbridge/stream_disposed',
        message: 'stream client has been disposed',
      );
    }
    if (_transport.endpoint.isUnixSocket) {
      throw const GbridgeException(
        status: 503,
        code: 'gbridge/unix_socket_unsupported_on_web',
        message: 'Unix socket streaming is unavailable in browser mode.',
      );
    }

    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final epoch = ++_connEpoch;
    _closeCurrentSocket();
    _setPhase(_lastBootId == null ? ConnectionPhase.connecting : ConnectionPhase.reconnecting);

    final prevPending = _pendingWelcome;
    _pendingWelcome = null;
    if (prevPending != null && !prevPending.isCompleted) {
      prevPending.completeError(const GbridgeException(
        status: 0,
        code: 'gbridge/ws_superseded',
        message: 'WebSocket connection superseded',
      ));
    }

    final welcomeCompleter = Completer<WelcomeInfo>();
    welcomeCompleter.future.ignore();

    _activeConnects++;
    try {
      final token = _transport.endpoint.token;
      var cookieReady = false;
      if (token != null && token.isNotEmpty) {
        final exchanged = await _transport.exchangeAuthToken();
        if (_disposed || _manualDisconnect || epoch != _connEpoch) {
          throw const GbridgeException(
            status: 0,
            code: 'gbridge/ws_superseded',
            message: 'WebSocket connection superseded',
          );
        }
        // Only rely on cookie-only WS upgrade for exact same-origin hosts; cross-origin/SameSite/ITP
        // browsers may silently discard Set-Cookie even on 200 OK, so keep `?token=` attached there.
        final baseOrigin = _transport.endpoint.baseUri?.origin;
        final pageOrigin = (() {
          try {
            final loc = globalContext.getProperty<JSObject?>('location'.toJS);
            final orig = loc?.getProperty<JSAny?>('origin'.toJS);
            return (orig != null && orig.isA<JSString>()) ? (orig as JSString).toDart : null;
          } catch (_) {
            return null;
          }
        })();
        cookieReady = exchanged && baseOrigin != null && pageOrigin != null && baseOrigin == pageOrigin;
      }
      var wsUri = _transport.endpoint.resolveWsUri(wsPath);
      if (!cookieReady && token != null && token.isNotEmpty) {
        wsUri = wsUri.replace(queryParameters: {...wsUri.queryParameters, 'token': token});
      }

      _pendingWelcome = welcomeCompleter;
      final ctor = globalContext.getProperty<JSFunction>('WebSocket'.toJS);
      final ws = ctor.callAsConstructor<JSObject>(wsUri.toString().toJS);
      _ws = ws;

      ws.setProperty(
        'onopen'.toJS,
        ((JSAny? _) {
          if (epoch != _connEpoch) return;
          _sentHelloChannels = Set<String>.of(_channels);
          _sendJson({
            'op': 'hello',
            'v': 1,
            'clientId': clientId,
            'coalesceMs': coalesceMs,
            'channels': _sentHelloChannels.toList(growable: false),
            if (_lastBootId != null) 'lastBootId': _lastBootId,
            if (_lastBootId != null) 'resumeFromSeq': _lastSeq,
          });
        }).toJS,
      );

      ws.setProperty(
        'onmessage'.toJS,
        ((JSObject event) {
          if (epoch != _connEpoch) return;
          final data = event.getProperty<JSAny?>('data'.toJS);
          if (data != null && data.isA<JSString>()) {
            _onRawMessage((data as JSString).toDart);
          }
        }).toJS,
      );

      ws.setProperty(
        'onerror'.toJS,
        ((JSAny? _) {
          // Browsers fire `onerror` right BEFORE `onclose`; let `onclose` drive `_handleDisconnect`
          // so close codes `4001` / `1008` are never dropped by an earlier `_connEpoch++`!
          final rsAny = ws.getProperty<JSAny?>('readyState'.toJS);
          final readyState = (rsAny != null && rsAny.isA<JSNumber>()) ? (rsAny as JSNumber).toDartInt : 3;
          if (readyState != 2 && readyState != 3) {
            _handleDisconnect(epoch);
          }
        }).toJS,
      );

      ws.setProperty(
        'onclose'.toJS,
        ((JSObject? ev) {
          final codeAny = ev?.getProperty<JSAny?>('code'.toJS);
          final closeCode = (codeAny != null && codeAny.isA<JSNumber>())
              ? (codeAny as JSNumber).toDartInt
              : null;
          _handleDisconnect(epoch, closeCode: closeCode);
        }).toJS,
      );

      final info = await welcomeCompleter.future.timeout(const Duration(seconds: 12));
      if (epoch != _connEpoch) return info;
      _reconnectAttempt = 0;
      _startHeartbeat(info.heartbeatMs);
      return info;
    } catch (err) {
      if (epoch == _connEpoch) {
        _connEpoch++;
        _pendingWelcome = null;
        _closeCurrentSocket();
        final isAuthRejected = err is GbridgeException &&
            (err.status == 401 || err.status == 403 || err.code == 'gbridge/unauthorized');
        if (isAuthRejected) {
          _setPhase(ConnectionPhase.needsAuth);
        } else {
          final willReconnect = autoReconnect && !_manualDisconnect && !_disposed;
          if (willReconnect) {
            _setPhase(ConnectionPhase.reconnecting);
            if (_reconnectTimer == null) _scheduleReconnect();
          } else {
            _setPhase(ConnectionPhase.error);
          }
        }
      }
      rethrow;
    } finally {
      _activeConnects = _activeConnects > 0 ? _activeConnects - 1 : 0;
    }
  }

  int _activeConnects = 0;

  void subscribe(String channel, {bool force = false}) {
    if (channel.isEmpty) return;
    final added = _channels.add(channel);
    if (_vanillaMux != null) {
      _vanillaMux!.subscribe(channel, force: force);
      return;
    }
    if ((added || force) && _ws != null && _phase == ConnectionPhase.connected) {
      _sendJson({'op': 'sub', 'channel': channel});
    }
  }

  void unsubscribe(String channel) {
    if (channel == 'host') return;
    final removed = _channels.remove(channel);
    if (_vanillaMux != null) {
      _vanillaMux!.unsubscribe(channel);
      return;
    }
    if (removed && _ws != null && _phase == ConnectionPhase.connected) {
      _sendJson({'op': 'unsub', 'channel': channel});
    }
  }

  void sendTerminalInput(String terminalId, String data) {
    if (_vanillaMux != null) {
      _vanillaMux!.sendTerminalInput(terminalId, data);
      return;
    }
    _sendJson({'op': 'term.input', 'terminalId': terminalId, 'data': data});
  }

  void sendTerminalResize(String terminalId, int cols, int rows) {
    if (_vanillaMux != null) {
      _vanillaMux!.sendTerminalResize(terminalId, cols, rows);
      return;
    }
    _sendJson({
      'op': 'term.resize',
      'terminalId': terminalId,
      'cols': cols,
      'rows': rows,
    });
  }

  void sendPing([String? id]) {
    if (_vanillaMux != null) return;
    _sendJson({'op': 'ping', if (id != null) 'id': id});
  }

  void reconnectNow() {
    if (_vanillaMux != null) {
      _vanillaMux!.reconnectNow();
      return;
    }
    if (_disposed || _manualDisconnect) return;
    if (_activeConnects > 0) return;
    if (_phase == ConnectionPhase.connected && _ws != null) {
      unawaited(checkLiveness());
      return;
    }
    if (_reconnectTimer != null ||
        _phase == ConnectionPhase.reconnecting ||
        _phase == ConnectionPhase.disconnected ||
        _phase == ConnectionPhase.error) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _reconnectAttempt = 0;
      unawaited(connect().catchError((_) => const WelcomeInfo(
            bootId: '',
            currentSeq: 0,
            resumed: false,
            replayedCount: 0,
            heartbeatMs: 20000,
            pendingInteractions: [],
          )));
    }
  }

  Future<bool> checkLiveness({
    Duration timeout = const Duration(seconds: 3),
    bool force = false,
  }) async {
    if (_vanillaMux != null) {
      return _vanillaMux!.checkLiveness(timeout: timeout, force: force);
    }
    if (_disposed || _manualDisconnect) return false;
    // Never abort an in-flight handshake/reconnect or override an auth-rejected state!
    if (_phase == ConnectionPhase.connecting ||
        _phase == ConnectionPhase.reconnecting ||
        _phase == ConnectionPhase.needsAuth) {
      return false;
    }
    if (_ws == null || _phase != ConnectionPhase.connected) {
      unawaited(connect().catchError((_) => const WelcomeInfo(
            bootId: '',
            currentSeq: 0,
            resumed: false,
            replayedCount: 0,
            heartbeatMs: 20000,
            pendingInteractions: [],
          )));
      return false;
    }
    final existingProbe = _livenessProbe;
    if (existingProbe != null && !existingProbe.isCompleted) {
      return existingProbe.future.timeout(timeout, onTimeout: () => false);
    }
    final epoch = _connEpoch;
    final completer = Completer<bool>();
    _livenessProbe = completer;
    sendPing('liveness-${DateTime.now().millisecondsSinceEpoch}');
    try {
      final ok = await completer.future.timeout(timeout, onTimeout: () => false);
      if (identical(_livenessProbe, completer)) _livenessProbe = null;
      if (!ok && epoch == _connEpoch && !_disposed && !_manualDisconnect) {
        _handleDisconnect(epoch);
      }
      return ok;
    } catch (_) {
      if (identical(_livenessProbe, completer)) _livenessProbe = null;
      return false;
    }
  }

  void _onRawMessage(String raw) {
    _pongTimeoutTimer?.cancel();
    _pongTimeoutTimer = null;
    final probe = _livenessProbe;
    if (probe != null && !probe.isCompleted) {
      _livenessProbe = null;
      probe.complete(true);
    }
    Map<String, dynamic> parsed;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      parsed = decoded;
    } catch (_) {
      return;
    }
    final frame = StreamFrame.fromJson(parsed);
    if (frame.op == 'welcome') {
      final welcome = WelcomeInfo.fromJson(parsed);
      final isSameBoot = _lastBootId != null && _lastBootId == welcome.bootId;
      _lastBootId = welcome.bootId;
      if (!isSameBoot || !welcome.resumed) {
        _lastSeq = welcome.currentSeq;
        _lastAckedSeq = _lastSeq;
      } else if (welcome.replayedCount == 0 && welcome.currentSeq > _lastSeq) {
        _lastSeq = welcome.currentSeq;
      }
      _setPhase(ConnectionPhase.connected);
      for (final ch in _channels) {
        if (!_sentHelloChannels.contains(ch)) {
          _sendJson({'op': 'sub', 'channel': ch});
        }
      }
      for (final ch in _sentHelloChannels) {
        if (!_channels.contains(ch)) {
          _sendJson({'op': 'unsub', 'channel': ch});
        }
      }
      _sentHelloChannels = Set<String>.of(_channels);
      if (!_welcomeController.isClosed) _welcomeController.add(welcome);
      final pending = _pendingWelcome;
      if (pending != null && !pending.isCompleted) {
        pending.complete(welcome);
      }
      _pendingWelcome = null;
      if (!_framesController.isClosed) _framesController.add(frame);
      return;
    }
    if (frame.seq != null && frame.seq! > _lastSeq) {
      _lastSeq = frame.seq!;
      if (_lastSeq - _lastAckedSeq >= 20) {
        _lastAckedSeq = _lastSeq;
        _sendJson({'op': 'ack', 'seq': _lastSeq});
      }
    }
    if (!_framesController.isClosed) {
      _framesController.add(frame);
    }
  }

  void _startHeartbeat(int heartbeatMs) {
    _heartbeatTimer?.cancel();
    _pongTimeoutTimer?.cancel();
    final epoch = _connEpoch;
    final periodMs = heartbeatMs.clamp(5000, 60000);
    final period = Duration(milliseconds: periodMs);
    final pongTimeoutMs = (periodMs * 0.6).round().clamp(3000, 10000);
    _heartbeatTimer = Timer.periodic(period, (_) {
      if (_phase == ConnectionPhase.connected && epoch == _connEpoch) {
        sendPing();
        _pongTimeoutTimer?.cancel();
        _pongTimeoutTimer = Timer(Duration(milliseconds: pongTimeoutMs), () {
          if (epoch == _connEpoch && _phase == ConnectionPhase.connected) {
            _handleDisconnect(epoch);
          }
        });
      }
    });
  }

  static final math.Random _jitterRng = math.Random();

  void _handleDisconnect(int epoch, {int? closeCode}) {
    if (epoch != _connEpoch) return;
    _connEpoch++;
    _closeCurrentSocket();
    final isRevoked = closeCode == 4001 || closeCode == 1008;
    final pending = _pendingWelcome;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(GbridgeException(
        status: isRevoked ? 401 : 0,
        code: isRevoked ? 'gbridge/unauthorized' : 'gbridge/ws_closed',
        message: isRevoked ? 'WebSocket authorization rejected' : 'WebSocket closed before welcome',
      ));
    }
    _pendingWelcome = null;
    if (_disposed || _manualDisconnect) {
      _setPhase(ConnectionPhase.disconnected);
      return;
    }
    if (isRevoked) {
      _setPhase(ConnectionPhase.needsAuth);
      return;
    }
    if (autoReconnect) {
      // If WS closed before welcome (browser hides HTTP 401/403 status), probe HTTP capabilities once
      // so invalid/expired credentials stop reconnecting and surface `needsAuth`.
      if (pending != null) {
        _setPhase(ConnectionPhase.reconnecting);
        final probeEpoch = _connEpoch;
        unawaited(_probeAuthAfterPreWelcomeClose(probeEpoch));
        return;
      }
      _setPhase(ConnectionPhase.reconnecting);
      if (_reconnectTimer == null) _scheduleReconnect();
    } else {
      _setPhase(ConnectionPhase.disconnected);
    }
  }

  Future<void> _probeAuthAfterPreWelcomeClose(int probeEpoch) async {
    try {
      await _transport.requestJson(
        'GET',
        '/gbridge/v1/capabilities',
        retryAuth: false,
        reloadRetryAttempt: 4,
        timeoutOverride: const Duration(seconds: 4),
      );
    } on GbridgeException catch (e) {
      if (probeEpoch != _connEpoch) return;
      if (e.status == 401 || e.status == 403) {
        if (!_disposed && !_manualDisconnect) {
          _setPhase(ConnectionPhase.needsAuth);
        }
        return;
      }
    } catch (_) {}
    if (probeEpoch != _connEpoch) return;
    if (!_disposed && !_manualDisconnect && autoReconnect) {
      _setPhase(ConnectionPhase.reconnecting);
      if (_reconnectTimer == null) _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final baseMs = (600 * (1 << _reconnectAttempt.clamp(0, 5))).clamp(600, 15000);
    final jitterFactor = 0.8 + _jitterRng.nextDouble() * 0.4; // +/- 20% jitter
    final delayMs = (baseMs * jitterFactor).round().clamp(450, 18000);
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      if (_disposed || _manualDisconnect) return;
      connect().catchError((_) => const WelcomeInfo(
            bootId: '',
            currentSeq: 0,
            resumed: false,
            replayedCount: 0,
            heartbeatMs: 20000,
            pendingInteractions: [],
          ));
    });
  }

  void _sendJson(Map<String, dynamic> payload) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.callMethod<JSAny?>('send'.toJS, jsonEncode(payload).toJS);
    } catch (_) {}
  }

  void _setPhase(ConnectionPhase next) {
    if (_phase == next) return;
    _phase = next;
    if (!_phaseController.isClosed) _phaseController.add(next);
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _connEpoch++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _pongTimeoutTimer?.cancel();
    _pongTimeoutTimer = null;
    final probe = _livenessProbe;
    _livenessProbe = null;
    if (probe != null && !probe.isCompleted) probe.complete(false);
    final pending = _pendingWelcome;
    _pendingWelcome = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const GbridgeException(
        status: 0,
        code: 'gbridge/ws_closed',
        message: 'client disconnected',
      ));
    }
    if (_vanillaMux != null) {
      await _vanillaMux!.disconnect().timeout(
        const Duration(milliseconds: 300),
        onTimeout: () {},
      );
    }
    final oldWs = _ws;
    _ws = null;
    if (oldWs != null) {
      try {
        oldWs.setProperty('onopen'.toJS, null);
        oldWs.setProperty('onmessage'.toJS, null);
        oldWs.setProperty('onerror'.toJS, null);
        oldWs.setProperty('onclose'.toJS, null);
      } catch (_) {}
      try {
        oldWs.callMethod<JSAny?>('close'.toJS, 1000.toJS, 'client disconnect'.toJS);
      } catch (_) {}
    }
    _setPhase(ConnectionPhase.disconnected);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _muxFramesSub?.cancel();
    await _muxPhasesSub?.cancel();
    await _muxWelcomesSub?.cancel();
    if (_vanillaMux != null) {
      await _vanillaMux!.dispose();
      _vanillaMux = null;
    }
    await disconnect();
    await _framesController.close();
    await _phaseController.close();
    await _welcomeController.close();
  }
}
