import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';
import 'raw_ws.dart';
import 'vanilla_mux.dart';

/// Low-level HTTP transport supporting both TCP HTTP/HTTPS and `0600` Unix Domain Sockets,
/// with automatic DSH session cookie exchange, cookie persistence callback, and Bearer token injection.
class GbridgeHttpTransport {
  GbridgeHttpTransport(
    this.endpoint, {
    Duration? timeout,
    bool allowBadCertificates = false,
    this.onCookieUpdated,
  })  : timeout = timeout ?? const Duration(seconds: 25),
        _allowBadCertificates = allowBadCertificates,
        _cookieHeader = endpoint.cookie {
    _client = _createHttpClient(endpoint, allowBadCertificates: allowBadCertificates);
  }

  final HostEndpoint endpoint;
  final Duration timeout;
  final bool _allowBadCertificates;
  final void Function(String cookieHeader)? onCookieUpdated;
  late HttpClient _client;
  String? _cookieHeader;
  Future<bool>? _authExchangeFuture;
  bool _closed = false;

  String? get cookieHeader => _cookieHeader;

  /// Reset pooled HTTP keep-alive sockets (e.g. after Android Wi-Fi <-> 5G switch)
  /// so subsequent RPCs never hang 25s on dead sockets from a vanished interface.
  void resetConnectionPool() {
    if (_closed) return;
    final old = _client;
    _client = _createHttpClient(endpoint, allowBadCertificates: _allowBadCertificates);
    try {
      old.close(force: true);
    } catch (_) {}
  }

  void setCookieHeader(String? cookie) {
    final trimmed = cookie?.trim();
    _cookieHeader = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    if (_cookieHeader != null) {
      onCookieUpdated?.call(_cookieHeader!);
    }
  }

  static HttpClient _createHttpClient(
    HostEndpoint endpoint, {
    bool allowBadCertificates = false,
  }) {
    final client = HttpClient();
    client.idleTimeout = const Duration(seconds: 30);
    final baseUri = endpoint.baseUri;
    if (allowBadCertificates && !endpoint.isUnixSocket && baseUri != null) {
      final targetHost = baseUri.host.toLowerCase();
      final targetPort = baseUri.hasPort
          ? baseUri.port
          : (baseUri.scheme == 'https' ? 443 : 80);
      client.badCertificateCallback = (_, host, port) =>
          host.toLowerCase() == targetHost && port == targetPort;
    }
    if (endpoint.isUnixSocket) {
      final addr = InternetAddress(
        endpoint.unixSocketPath!,
        type: InternetAddressType.unix,
      );
      client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
        return Socket.startConnect(addr, 0);
      };
    }
    return client;
  }

  /// Build headers required for both HTTP requests and WebSocket upgrades.
  Map<String, String> buildAuthHeaders() {
    final headers = <String, String>{};
    if (_cookieHeader != null && _cookieHeader!.isNotEmpty) {
      headers[HttpHeaders.cookieHeader] = _cookieHeader!;
    }
    // Always include Bearer token when configured so unrelated reverse-proxy Set-Cookie headers
    // never suppress token auth (and UDS/gbridge Bearer auth always succeeds).
    if (endpoint.token != null && endpoint.token!.isNotEmpty) {
      headers[HttpHeaders.authorizationHeader] = 'Bearer ${endpoint.token}';
    }
    return headers;
  }

  /// Exchange a DSH web query token (`?token=...`) for the host's 30-day `dsh-auth-*` cookie.
  /// Tries `GET /?token=...` first (mints persistent `v1` browser cookie that survives `dsh web`
  /// restarts for 30 days), falling back to `GET /connect?token=...&interactions=answer`.
  /// No-op on Unix Domain Socket endpoints which authenticate directly via Bearer token.
  Future<bool> exchangeAuthToken([String? tokenOverride]) {
    if (endpoint.isUnixSocket) return Future.value(true);
    final token = tokenOverride ?? endpoint.token;
    if (token == null || token.isEmpty) return Future.value(false);

    // Single-flight deduplication prevents parallel 401 retries from racing & clobbering fresh cookies.
    if (tokenOverride == null && _authExchangeFuture != null) {
      return _authExchangeFuture!;
    }

    Future<bool> run() async {
      final prevCookie = _cookieHeader;
      final deadline = DateTime.now().add(timeout);
      var sawAuthRejection = false;

      Duration remaining() {
        final rem = deadline.difference(DateTime.now());
        return rem > const Duration(milliseconds: 250) ? rem : const Duration(milliseconds: 250);
      }

      Future<bool> attempt(String path, Map<String, String> query) async {
        final uri = endpoint.resolveHttpUri(path, query);
        HttpClientRequest? req;
        try {
          req = await _openUrlWithTimeout('GET', uri, remaining());
          req.followRedirects = false;
          // Preserve any reverse-proxy / SSO cookies (e.g. Cloudflare Access, Authelia) during DSH token exchange.
          if (_cookieHeader != null && _cookieHeader!.isNotEmpty) {
            req.headers.set(HttpHeaders.cookieHeader, _cookieHeader!);
          }
          final res = await req.close().timeout(remaining());
          await _drainResponseWithTimeout(res, remaining());
          if (res.statusCode == 401 || res.statusCode == 403) {
            sawAuthRejection = true;
            return false;
          }
          if (res.statusCode < 200 || res.statusCode >= 400) return false;
          final gotSetCookie = _captureCookies(_safeCookies(res), res.headers[HttpHeaders.setCookieHeader]);
          return _cookieHeader != null && _cookieHeader!.isNotEmpty && gotSetCookie;
        } catch (_) {
          try {
            req?.abort();
          } catch (_) {}
          return false;
        }
      }

      if (await attempt('/', {'token': token})) {
        _lastAuthExchangeRejected = false;
        return true;
      }
      if (_cookieHeader != null && _cookieHeader!.isNotEmpty && _cookieHeader != prevCookie) {
        _lastAuthExchangeRejected = false;
        return true;
      }
      if (DateTime.now().isBefore(deadline)) {
        if (await attempt('/connect', {'token': token, 'interactions': 'answer'})) {
          _lastAuthExchangeRejected = false;
          return true;
        }
      }
      final changed = _cookieHeader != null && _cookieHeader!.isNotEmpty && _cookieHeader != prevCookie;
      _lastAuthExchangeRejected = !changed && sawAuthRejection;
      return changed;
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

  bool _lastAuthExchangeRejected = false;

  void _evictDshAuthCookies() {
    final cur = _cookieHeader;
    if (cur == null || cur.isEmpty) return;
    final kept = <String>[];
    for (final part in cur.split(';')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final eq = trimmed.indexOf('=');
      final name = (eq > 0 ? trimmed.substring(0, eq) : trimmed).trim().toLowerCase();
      if (name.startsWith('dsh-auth') || name.startsWith('gbridge-lan-auth')) {
        continue;
      }
      kept.add(trimmed);
    }
    final next = kept.join('; ');
    _cookieHeader = next.isEmpty ? null : next;
    onCookieUpdated?.call(next);
  }

  static bool _shouldRetry503(_RawHttpResponse res, String method) {
    if (res.statusCode != 503) return false;
    final bodyPreview = res.bytes.isEmpty
        ? ''
        : utf8.decode(res.bytes.length > 512 ? res.bytes.sublist(0, 512) : res.bytes, allowMalformed: true);
    if (bodyPreview.contains('gbridge/reloading')) return true;
    final m = method.toUpperCase();
    final isIdempotent = m == 'GET' || m == 'HEAD';
    if (!isIdempotent) return false;
    if (bodyPreview.contains('gbridge/web_unavailable') ||
        bodyPreview.contains('gbridge/auth_unconfigured') ||
        bodyPreview.contains('gbridge/gateway_unavailable')) {
      return false;
    }
    return res.retryAfter != null;
  }

  Future<HttpClientRequest> _openUrlWithTimeout(String method, Uri uri, Duration budget) {
    final completer = Completer<HttpClientRequest>();
    var timedOut = false;
    final timer = Timer(budget, () {
      timedOut = true;
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('HTTP openUrl timed out', budget));
      }
    });
    _client.openUrl(method, uri).then(
      (req) {
        timer.cancel();
        if (timedOut || _closed) {
          try {
            req.abort();
          } catch (_) {}
          return;
        }
        if (!completer.isCompleted) completer.complete(req);
      },
      onError: (Object err, StackTrace st) {
        timer.cancel();
        if (!completer.isCompleted) completer.completeError(err, st);
      },
    );
    return completer.future;
  }

  Future<void> _drainResponseWithTimeout(HttpClientResponse res, Duration budget) {
    final completer = Completer<void>();
    late StreamSubscription<List<int>> sub;
    final timer = Timer(budget, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('HTTP drain timed out', budget));
      }
      unawaited(sub.cancel().catchError((_) {}));
    });
    sub = res.listen(
      (_) {},
      onError: (Object err, StackTrace st) {
        timer.cancel();
        if (!completer.isCompleted) completer.completeError(err, st);
      },
      onDone: () {
        timer.cancel();
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  Future<WebSocket> _connectWsWithTimeout(Uri wsUri, Map<String, String> headers, Duration budget) {
    final completer = Completer<WebSocket>();
    var timedOut = false;
    final timer = Timer(budget, () {
      timedOut = true;
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('WebSocket connect timed out', budget));
      }
    });
    WebSocket.connect(wsUri.toString(), headers: headers, customClient: _client).then(
      (ws) {
        timer.cancel();
        if (timedOut || _closed) {
          unawaited(ws.close().catchError((_) {}));
          return;
        }
        if (!completer.isCompleted) completer.complete(ws);
      },
      onError: (Object err, StackTrace st) {
        timer.cancel();
        if (!completer.isCompleted) completer.completeError(err, st);
      },
    );
    return completer.future;
  }

  /// Probe stock DSH's public unauthenticated SSE endpoint (`GET /plugins/events`)
  /// to reliably detect a genuine DSH server and read its exact `release.version`
  /// even BEFORE authentication (returns `null` if not DSH or unreachable).
  Future<String?> probeDshSseVersion({Duration timeout = const Duration(seconds: 4)}) async {
    if (_closed || endpoint.isUnixSocket) return null;
    HttpClientRequest? req;
    try {
      final uri = endpoint.resolveHttpUri('/plugins/events');
      req = await _openUrlWithTimeout('GET', uri, timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        unawaited(res.drain<void>().catchError((_) {}));
        return null;
      }
      final ct = (res.headers.contentType?.mimeType ?? '').toLowerCase();
      if (!ct.contains('event-stream')) {
        unawaited(res.drain<void>().catchError((_) {}));
        return null;
      }
      final completer = Completer<String?>();
      final buf = StringBuffer();
      late StreamSubscription<String> sub;
      final timer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete('dsh');
        unawaited(sub.cancel().catchError((_) {}));
      });
      sub = res.transform(const Utf8Decoder(allowMalformed: true)).listen(
        (chunkText) {
          buf.write(chunkText);
          final text = buf.toString();
          final version = _extractDshVersionFromSse(text);
          if (version != null) {
            if (!completer.isCompleted) completer.complete(version);
            timer.cancel();
            unawaited(sub.cancel().catchError((_) {}));
          } else if (text.length > 131072 || (text.contains('data:') && text.contains('\n\n'))) {
            if (!completer.isCompleted) completer.complete('dsh');
            timer.cancel();
            unawaited(sub.cancel().catchError((_) {}));
          }
        },
        onError: (_) {
          timer.cancel();
          if (!completer.isCompleted) completer.complete(null);
        },
        onDone: () {
          timer.cancel();
          if (!completer.isCompleted) {
            completer.complete(_extractDshVersionFromSse(buf.toString()) ?? 'dsh');
          }
        },
        cancelOnError: true,
      );
      return await completer.future;
    } catch (_) {
      try {
        req?.abort();
      } catch (_) {}
      return null;
    }
  }

  static final RegExp _sseReleaseVerRe = RegExp(
    r'"release"\s*:\s*\{[^{}]*"version"\s*:\s*"([^"]+)"',
  );

  static String? _extractDshVersionFromSse(String text) {
    final fastMatch = _sseReleaseVerRe.firstMatch(text);
    if (fastMatch != null) {
      final v = fastMatch.group(1)?.trim();
      if (v != null && v.isNotEmpty) return v;
    }
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      final payload = trimmed.substring(5).trim();
      if (payload.isEmpty) continue;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map) {
          final graph = decoded['graph'];
          if (graph is Map) {
            final rel = graph['release'];
            if (rel is Map && rel['version'] is String && (rel['version'] as String).isNotEmpty) {
              return rel['version'] as String;
            }
          }
          if (decoded['type'] == 'graph') return 'dsh';
        }
      } catch (_) {}
    }
    return null;
  }

  static List<Cookie> _safeCookies(HttpClientResponse res) {
    try {
      return res.cookies;
    } catch (_) {
      return const <Cookie>[];
    }
  }

  bool _captureCookies(List<Cookie> parsedCookies, List<String>? rawSetCookie) {
    final hadHeader = parsedCookies.isNotEmpty || (rawSetCookie != null && rawSetCookie.isNotEmpty);
    final pairs = <String, String>{};
    if (_cookieHeader != null && _cookieHeader!.isNotEmpty) {
      for (final part in _cookieHeader!.split(';')) {
        final idx = part.indexOf('=');
        if (idx > 0) {
          pairs[part.substring(0, idx).trim()] = part.substring(idx + 1).trim();
        }
      }
    }
    final handledNames = <String>{};
    final nowUtc = DateTime.now().toUtc();
    for (final c in parsedCookies) {
      handledNames.add(c.name);
      final isExpiredByDate = c.expires != null && !c.expires!.toUtc().isAfter(nowUtc);
      if ((c.maxAge != null && c.maxAge! <= 0) || isExpiredByDate || c.value.isEmpty) {
        pairs.remove(c.name);
      } else {
        pairs[c.name] = c.value;
      }
    }
    if (rawSetCookie != null) {
      for (final raw in rawSetCookie) {
        final parts = raw.split(';');
        final first = parts.first;
        final idx = first.indexOf('=');
        if (idx <= 0) continue;
        final name = first.substring(0, idx).trim();
        if (handledNames.contains(name)) continue;
        final value = first.substring(idx + 1).trim();
        var expired = value.isEmpty;
        if (!expired) {
          for (final attr in parts.skip(1)) {
            final eq = attr.indexOf('=');
            if (eq <= 0) continue;
            final k = attr.substring(0, eq).trim().toLowerCase();
            final v = attr.substring(eq + 1).trim();
            if (k == 'max-age') {
              final secs = int.tryParse(v);
              if (secs != null && secs <= 0) {
                expired = true;
                break;
              }
            } else if (k == 'expires') {
              try {
                final dt = HttpDate.parse(v).toUtc();
                if (!dt.isAfter(nowUtc)) {
                  expired = true;
                  break;
                }
              } catch (_) {}
            }
          }
        }
        if (expired) {
          pairs.remove(name);
        } else {
          pairs[name] = value;
        }
      }
    }
    final next = pairs.isEmpty
        ? null
        : pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
    if (next != _cookieHeader) {
      _cookieHeader = next;
      onCookieUpdated?.call(next ?? '');
    }
    return hadHeader;
  }

  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool retryAuth = true,
    int reloadRetryAttempt = 0,
  }) async {
    final usedCookie = _cookieHeader;
    final res = await _send(method, path, query: query, jsonBody: body);
    if (_shouldRetry503(res, method) && reloadRetryAttempt < 4) {
      // Absorb transient post-boot Cordis profile hot-reloads (`503 gbridge/reloading`)
      // without failing initial model/session/workspace hydration!
      final retryAfterSec = int.tryParse(res.retryAfter ?? '');
      const delaysMs = <int>[220, 420, 700, 1100];
      final waitMs = retryAfterSec != null && retryAfterSec > 0
          ? (retryAfterSec * 1000).clamp(200, 1500)
          : delaysMs[reloadRetryAttempt];
      await Future<void>.delayed(Duration(milliseconds: waitMs));
      if (!_closed) {
        return requestJson(
          method,
          path,
          query: query,
          body: body,
          retryAuth: retryAuth,
          reloadRetryAttempt: reloadRetryAttempt + 1,
        );
      }
    }
    if (res.statusCode == 401 && retryAuth && !endpoint.isUnixSocket && (endpoint.token?.isNotEmpty ?? false)) {
      // Do NOT wipe `_cookieHeader` before `exchangeAuthToken()` so reverse-proxy / SSO cookies
      // (Cloudflare Access, Authelia, etc.) stay attached to the token-exchange request!
      final exchanged = await exchangeAuthToken();
      if (exchanged) {
        return requestJson(
          method,
          path,
          query: query,
          body: body,
          retryAuth: false,
          reloadRetryAttempt: reloadRetryAttempt,
        );
      }
      if (_lastAuthExchangeRejected && _cookieHeader == usedCookie && _cookieHeader != null) {
        _evictDshAuthCookies();
      }
    }
    return _decodeJsonResponse(res);
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
    final usedCookie = _cookieHeader;
    final res = await _send(
      method,
      path,
      query: query,
      rawBody: bodyBytes,
      contentType: contentType,
    );
    if (_shouldRetry503(res, method) && reloadRetryAttempt < 4) {
      final retryAfterSec = int.tryParse(res.retryAfter ?? '');
      const delaysMs = <int>[220, 420, 700, 1100];
      final waitMs = retryAfterSec != null && retryAfterSec > 0
          ? (retryAfterSec * 1000).clamp(200, 1500)
          : delaysMs[reloadRetryAttempt];
      await Future<void>.delayed(Duration(milliseconds: waitMs));
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
    if (res.statusCode == 401 && retryAuth && !endpoint.isUnixSocket && (endpoint.token?.isNotEmpty ?? false)) {
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
      if (_lastAuthExchangeRejected && _cookieHeader == usedCookie && _cookieHeader != null) {
        _evictDshAuthCookies();
      }
    }
    if (res.statusCode >= 400) {
      _throwResponseError(res);
    }
    return res.bytes;
  }

  Future<WebSocket> openWebSocket(String path) async {
    if (!endpoint.isUnixSocket && (_cookieHeader == null || _cookieHeader!.isEmpty) && (endpoint.token?.isNotEmpty ?? false)) {
      await exchangeAuthToken();
    }
    final wsUri = endpoint.resolveWsUri(path);
    try {
      return await _connectWsWithTimeout(wsUri, buildAuthHeaders(), timeout);
    } on WebSocketException {
      if (!endpoint.isUnixSocket && (endpoint.token?.isNotEmpty ?? false)) {
        final exchanged = await exchangeAuthToken();
        if (exchanged) {
          return _connectWsWithTimeout(wsUri, buildAuthHeaders(), timeout);
        }
      }
      rethrow;
    }
  }

  Future<GbridgeRawWebSocket> openRawWebSocket(String path) async {
    final ws = await openWebSocket(path);
    ws.pingInterval = const Duration(seconds: 15);
    return _IoRawWebSocket(ws);
  }

  static const int _maxResponseBytes = 64 * 1024 * 1024; // 64 MiB hard cap

  Future<Uint8List> _readResponseBytes(HttpClientResponse res, Duration budget) {
    final completer = Completer<Uint8List>();
    final builder = BytesBuilder(copy: false);
    var total = 0;
    late StreamSubscription<List<int>> sub;
    final timer = Timer(budget, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('HTTP response read timed out', budget));
      }
      unawaited(sub.cancel().catchError((_) {}));
    });
    sub = res.listen(
      (chunk) {
        total += chunk.length;
        if (total > _maxResponseBytes) {
          timer.cancel();
          unawaited(sub.cancel().catchError((_) {}));
          if (!completer.isCompleted) {
            completer.completeError(const GbridgeException(
              status: 413,
              code: 'gbridge/response_too_large',
              message: 'HTTP response exceeds 64 MiB safety limit',
            ));
          }
          return;
        }
        builder.add(chunk);
      },
      onError: (Object err, StackTrace st) {
        timer.cancel();
        if (!completer.isCompleted) completer.completeError(err, st);
      },
      onDone: () {
        timer.cancel();
        if (!completer.isCompleted) completer.complete(builder.takeBytes());
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  Future<_RawHttpResponse> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? jsonBody,
    Uint8List? rawBody,
    String? contentType,
  }) async {
    if (_closed) {
      throw const GbridgeException(
        status: 0,
        code: 'gbridge/client_closed',
        message: 'transport is closed',
      );
    }
    final uri = endpoint.resolveHttpUri(path, query);
    final deadline = DateTime.now().add(timeout);
    final req = await _openUrlWithTimeout(method, uri, timeout);
    try {
      req.headers.set(HttpHeaders.acceptHeader, 'application/json, application/octet-stream');
      for (final entry in buildAuthHeaders().entries) {
        req.headers.set(entry.key, entry.value);
      }

      if (jsonBody != null) {
        final encoded = utf8.encode(jsonEncode(jsonBody));
        req.headers.contentType = ContentType.json;
        req.contentLength = encoded.length;
        req.add(encoded);
      } else if (rawBody != null) {
        req.headers.set(
          HttpHeaders.contentTypeHeader,
          contentType ?? 'application/octet-stream',
        );
        req.contentLength = rawBody.length;
        req.add(rawBody);
      }

      final remClose = deadline.difference(DateTime.now());
      final res = await req.close().timeout(remClose > Duration.zero ? remClose : const Duration(milliseconds: 500));
      _captureCookies(_safeCookies(res), res.headers[HttpHeaders.setCookieHeader]);
      final remRead = deadline.difference(DateTime.now());
      final bytes = await _readResponseBytes(
        res,
        remRead > const Duration(seconds: 2) ? remRead : const Duration(seconds: 2),
      );
      return _RawHttpResponse(
        statusCode: res.statusCode,
        contentType: res.headers.contentType?.mimeType ?? '',
        bytes: bytes,
        retryAfter: res.headers.value(HttpHeaders.retryAfterHeader),
      );
    } catch (_) {
      try {
        req.abort();
      } catch (_) {}
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _decodeJsonResponse(_RawHttpResponse res) async {
    if (res.statusCode >= 300 && res.statusCode < 400) {
      throw GbridgeException(
        status: res.statusCode,
        code: 'gbridge/html_response',
        message: '目标重定向至登录认证页 (HTTP ${res.statusCode})',
      );
    }
    if (res.statusCode >= 400) {
      _throwResponseError(res);
    }
    if (res.bytes.isEmpty) return const <String, dynamic>{};
    // Offload large JSON payloads (> 64KB, e.g. session history / diffs / files) to a worker isolate
    // so UTF-8 decoding and JSON parsing never drop UI frames on mobile!
    if (res.bytes.length > 64 * 1024) {
      final bytes = res.bytes;
      final statusCode = res.statusCode;
      final contentType = res.contentType;
      return Isolate.run(() => _decodeJsonBytesSync(bytes, statusCode, contentType));
    }
    return _decodeJsonBytesSync(res.bytes, res.statusCode, res.contentType);
  }

  static Map<String, dynamic> _decodeJsonBytesSync(
    Uint8List bytes,
    int statusCode,
    String contentType,
  ) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final trimmed = text.trimLeft();
    if (contentType.toLowerCase().contains('text/html') ||
        trimmed.startsWith('<!doctype') ||
        trimmed.startsWith('<!DOCTYPE') ||
        trimmed.startsWith('<html') ||
        trimmed.startsWith('<HTML')) {
      throw GbridgeException(
        status: statusCode,
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
        status: statusCode,
        code: 'gbridge/invalid_json',
        message: '响应体不是合法的 JSON 格式: ${e.message}',
      );
    }
  }

  Never _throwResponseError(_RawHttpResponse res) {
    String code = 'gbridge/http_${res.statusCode}';
    String message = 'HTTP ${res.statusCode}';
    Object? details;
    if (res.bytes.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(res.bytes));
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
        message = utf8.decode(res.bytes, allowMalformed: true).trim();
        if (message.isEmpty) message = 'HTTP ${res.statusCode}';
      }
    }
    throw GbridgeException(
      status: res.statusCode,
      code: code,
      message: message,
      details: details,
    );
  }

  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    _client.close(force: force);
  }
}

class _IoRawWebSocket implements GbridgeRawWebSocket {
  _IoRawWebSocket(this._ws) {
    _sub = _ws.listen(
      (event) {
        if (event is String && !_messages.isClosed) {
          _messages.add(event);
        }
      },
      onError: (Object e, StackTrace st) {
        if (!_messages.isClosed) _messages.addError(e, st);
        if (!_done.isCompleted) _done.complete();
      },
      onDone: () {
        if (!_messages.isClosed) unawaited(_messages.close());
        if (!_done.isCompleted) _done.complete();
      },
      cancelOnError: false,
    );
  }

  final WebSocket _ws;
  final _messages = StreamController<String>.broadcast();
  final _done = Completer<void>();
  StreamSubscription<dynamic>? _sub;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void sendText(String text) {
    try {
      _ws.add(text);
    } catch (_) {}
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _ws.close(code ?? WebSocketStatus.normalClosure, reason ?? 'closed');
    } catch (_) {}
    if (!_messages.isClosed) await _messages.close();
    if (!_done.isCompleted) _done.complete();
  }
}

class _RawHttpResponse {
  const _RawHttpResponse({
    required this.statusCode,
    required this.contentType,
    required this.bytes,
    this.retryAfter,
  });

  final int statusCode;
  final String contentType;
  final Uint8List bytes;
  final String? retryAfter;
}

/// Resilient WebSocket stream client for `/gbridge/v1/stream`:
/// - `hello` handshake with `lastBootId` & `resumeFromSeq` replay
/// - Automatic channel re-subscription & exponential backoff reconnect
/// - Heartbeat `ping`/`pong` + `ack` watermarks + `term.input`/`term.resize`
class GbridgeStreamClient {
  GbridgeStreamClient(
    this._transport, {
    this.wsPath = '/gbridge/v1/stream',
    this.clientId = 'grassbag-dart',
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

  WebSocket? _ws;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _pongTimeoutTimer;
  Completer<bool>? _livenessProbe;

  ConnectionPhase _phase = ConnectionPhase.disconnected;
  String? _lastBootId;
  int _lastSeq = 0;
  int _lastAckedSeq = 0;
  int _reconnectAttempt = 0;
  int _connEpoch = 0;
  bool _disposed = false;
  bool _manualDisconnect = false;
  Completer<WelcomeInfo>? _pendingWelcome;

  VanillaDshMuxEngine? _vanillaMux;
  StreamSubscription<StreamFrame>? _muxFramesSub;
  StreamSubscription<ConnectionPhase>? _muxPhasesSub;
  StreamSubscription<WelcomeInfo>? _muxWelcomesSub;

  /// Attach a [VanillaDshMuxEngine] so this stream client transparently drives
  /// stock DSH's `/api/remote.mux` WebSocket when connecting without `dsh-gbridge`.
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
    _wsSub?.cancel();
    _wsSub = null;
    final old = _ws;
    _ws = null;
    if (old != null) {
      unawaited(old.close().catchError((_) {}));
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
    // Guard against uncaught Zone errors if disconnect()/superseded fires before awaiting `.future`.
    welcomeCompleter.future.ignore();

    try {
      final ws = await _transport.openWebSocket(wsPath);
      if (_disposed || _manualDisconnect || epoch != _connEpoch) {
        unawaited(ws.close().catchError((_) {}));
        throw const GbridgeException(
          status: 0,
          code: 'gbridge/ws_superseded',
          message: 'WebSocket connection superseded',
        );
      }
      _pendingWelcome = welcomeCompleter;
      ws.pingInterval = const Duration(seconds: 20);
      _ws = ws;
      _wsSub = ws.listen(
        (raw) {
          if (epoch == _connEpoch) _onRawMessage(raw);
        },
        onError: (Object _) => _handleDisconnect(epoch, closeCode: ws.closeCode),
        onDone: () => _handleDisconnect(epoch, closeCode: ws.closeCode),
        cancelOnError: true,
      );

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

      final info = await welcomeCompleter.future.timeout(const Duration(seconds: 12));
      if (epoch != _connEpoch) return info;
      _reconnectAttempt = 0;
      _startHeartbeat(info.heartbeatMs);
      return info;
    } catch (err) {
      if (epoch == _connEpoch) {
        // Advance epoch BEFORE closing the socket so async ws.done / onDone callbacks
        // cannot clobber ConnectionPhase.needsAuth or ConnectionPhase.error!
        _connEpoch++;
        _pendingWelcome = null;
        _closeCurrentSocket();
        final errText = err.toString().toLowerCase();
        final isAuthRejected = (err is GbridgeException && (err.status == 401 || err.status == 403)) ||
            errText.contains('http status code: 401') ||
            errText.contains('http status code: 403') ||
            errText.contains('401') && errText.contains('websocket') ||
            errText.contains('403') && errText.contains('websocket') ||
            errText.contains('unauthorized') ||
            errText.contains('forbidden');
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
    }
  }

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

  /// Immediately wakes up a sleeping backoff reconnect (e.g. on network change or app resume)
  /// or checks liveness if currently connected.
  void reconnectNow() {
    if (_vanillaMux != null) {
      _vanillaMux!.reconnectNow();
      return;
    }
    if (_disposed || _manualDisconnect) return;
    if (_phase == ConnectionPhase.connected && _ws != null) {
      unawaited(checkLiveness());
      return;
    }
    if (_reconnectTimer != null ||
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

  /// Probe the live WebSocket for half-open / blackholed connections (e.g. after Android resume).
  /// Triggers immediate reconnect if no pong arrives within [timeout].
  Future<bool> checkLiveness({
    Duration timeout = const Duration(seconds: 3),
    bool force = false,
  }) async {
    if (_vanillaMux != null) {
      return _vanillaMux!.checkLiveness(timeout: timeout, force: force);
    }
    if (_disposed || _manualDisconnect) return false;
    // Never abort an in-flight handshake/reconnect!
    if (_phase == ConnectionPhase.connecting || _phase == ConnectionPhase.reconnecting) {
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
    // Coalesce concurrent probes so a second caller never orphans & times out an active probe!
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

  void _onRawMessage(dynamic raw) {
    if (raw is! String) return;
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
      // Re-send any channels subscribed or unsubscribed during the in-flight `hello -> welcome` window!
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
    final period = Duration(milliseconds: heartbeatMs.clamp(5000, 60000));
    _heartbeatTimer = Timer.periodic(period, (_) {
      if (_phase == ConnectionPhase.connected && epoch == _connEpoch) {
        sendPing();
        _pongTimeoutTimer?.cancel();
        _pongTimeoutTimer = Timer(const Duration(seconds: 10), () {
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
    final effectiveCloseCode = closeCode ?? _ws?.closeCode;
    _connEpoch++;
    _closeCurrentSocket();
    final isRevoked = effectiveCloseCode == 4001 || effectiveCloseCode == 1008;
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
      _setPhase(ConnectionPhase.reconnecting);
      if (_reconnectTimer == null) _scheduleReconnect();
    } else {
      _setPhase(ConnectionPhase.disconnected);
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
      ws.add(jsonEncode(payload));
    } catch (_) {}
  }

  void _setPhase(ConnectionPhase next) {
    if (_phase == next) return;
    _phase = next;
    if (!_phaseController.isClosed) {
      _phaseController.add(next);
    }
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
    final oldSub = _wsSub;
    _wsSub = null;
    final oldWs = _ws;
    _ws = null;
    try {
      await oldSub?.cancel().timeout(
        const Duration(milliseconds: 150),
        onTimeout: () {},
      );
    } catch (_) {}
    if (oldWs != null) {
      try {
        await oldWs
            .close(WebSocketStatus.normalClosure, 'client disconnect')
            .timeout(const Duration(milliseconds: 300), onTimeout: () => null);
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
