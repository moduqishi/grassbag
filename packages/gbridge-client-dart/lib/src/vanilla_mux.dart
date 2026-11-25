import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'models.dart';
import 'raw_ws.dart';
import 'vanilla_normalizer.dart';

/// Pure-Dart multiplexed WebSocket engine speaking stock `@deepseek-ai/dsh`'s
/// native `WS /api/remote.mux` protocol (ZERO plugins required on the remote host!).
///
/// Translates:
/// - `$events` (`ready`, `emit`, `waterfall` approvals & user-questions, `cancel`)
/// - `session/follow` (`snapshot`, `event`, `assistant-stream` `start|chunk|end`, `projection`)
/// - `terminal/attach` (bidirectional `snapshot|output|state` <-> `write|resize`)
/// - `job/follow` (`output`)
/// - One-shot stream snapshots (`workspace/follow`, `mcpManager/watch`, `job/list`)
/// into the exact same [StreamFrame] / [WelcomeInfo] / [PendingInteraction] contracts
/// used by GrassBag's `/gbridge/v1/stream` client.
class VanillaDshMuxEngine {
  VanillaDshMuxEngine({
    required this.openSocket,
    required this.normalizer,
    this.autoReconnect = true,
    this.coalesceWindow = const Duration(milliseconds: 28),
    this.onAutoApprove,
  });

  final Future<GbridgeRawWebSocket> Function(String path) openSocket;
  final VanillaDshNormalizer normalizer;
  final bool autoReconnect;
  final Duration coalesceWindow;
  final Future<void> Function(String clientId, String eventId)? onAutoApprove;

  final _framesController = StreamController<StreamFrame>.broadcast();
  final _phaseController = StreamController<ConnectionPhase>.broadcast();
  final _welcomeController = StreamController<WelcomeInfo>.broadcast();

  final Set<String> _channels = <String>{'host'};
  final Map<String, _MuxChannelSub> _activeChannelStreams = <String, _MuxChannelSub>{};
  final Map<String, String> _streamIdToChannel = <String, String>{};
  final Map<String, Completer<dynamic>> _oneShotWaiters = <String, Completer<dynamic>>{};
  final Map<String, String> _activeTurns = <String, String>{};
  final Map<String, _PendingVanillaInteraction> _pendingInteractions =
      <String, _PendingVanillaInteraction>{};
  final Map<String, _CoalescedDeltaBatch> _pendingDeltas = <String, _CoalescedDeltaBatch>{};
  static final math.Random _jitterRng = math.Random();

  GbridgeRawWebSocket? _ws;
  StreamSubscription<String>? _wsSub;
  Timer? _reconnectTimer;
  Timer? _handshakeTimer;
  Timer? _eventsReopenTimer;
  Timer? _coalesceTimer;
  Completer<WelcomeInfo>? _pendingWelcome;
  int _lastInboundAtMs = 0;
  int _eventsReopenAttempts = 0;

  ConnectionPhase _phase = ConnectionPhase.disconnected;
  String? _eventsClientId;
  String? _hostHome;
  String _bootId = 'vanilla-${DateTime.now().millisecondsSinceEpoch}';
  int _seq = 0;
  int _streamSeq = 0;
  int _connEpoch = 0;
  int _reconnectAttempt = 0;
  bool _hasConnectedOnce = false;
  bool _disposed = false;
  bool _manualDisconnect = false;
  final Map<String, Set<String>> _sessionAlwaysAllowed = <String, Set<String>>{};
  Timer? _idleWatchdogTimer;

  static String _approvalToolKey(Map<String, dynamic> payload) {
    final raw = (payload['tool'] ??
            payload['toolName'] ??
            payload['name'] ??
            payload['kind'] ??
            '')
        .toString()
        .trim()
        .toLowerCase();
    return raw;
  }

  void rememberSessionAlwaysAllowed(String? sessionId, Map<String, dynamic> payload) {
    final sid = sessionId?.trim() ?? '';
    final key = _approvalToolKey(payload);
    if (sid.isEmpty || key.isEmpty || key.startsWith('phone_')) return;
    final existing = _sessionAlwaysAllowed.remove(sid) ?? <String>{};
    existing.add(key);
    _sessionAlwaysAllowed[sid] = existing;
    while (_sessionAlwaysAllowed.length > 256) {
      _sessionAlwaysAllowed.remove(_sessionAlwaysAllowed.keys.first);
    }
  }

  bool _isSessionAlwaysAllowed(String? sessionId, Map<String, dynamic> payload) {
    final sid = sessionId?.trim() ?? '';
    final key = _approvalToolKey(payload);
    if (sid.isEmpty || key.isEmpty || key.startsWith('phone_')) return false;
    return _sessionAlwaysAllowed[sid]?.contains(key) == true;
  }

  Stream<StreamFrame> get frames => _framesController.stream;
  Stream<ConnectionPhase> get phases => _phaseController.stream;
  Stream<WelcomeInfo> get welcomes => _welcomeController.stream;
  ConnectionPhase get phase => _phase;
  int get lastSeq => _seq;
  String? get eventsClientId => _eventsClientId;
  String? get hostHome => _hostHome;

  List<PendingInteraction> listPendingInteractions() {
    return _pendingInteractions.values
        .map((it) => PendingInteraction.fromJson(it.toJson()))
        .toList(growable: false);
  }

  ({String? clientId, String eventId, String kind, String? sessionId, Map<String, dynamic> payload})?
      takePendingInteraction(String id) {
    final item = _pendingInteractions[id];
    if (item == null) return null;
    return (
      clientId: item.gatewayClientId ?? _eventsClientId,
      eventId: item.eventId,
      kind: item.kind,
      sessionId: item.sessionId,
      payload: item.payload,
    );
  }

  void markInteractionResolved(String id, {String reason = 'responded'}) {
    final removed = _pendingInteractions.remove(id);
    if (removed != null) {
      _publish('host', 'interaction.resolved', {'id': id, 'kind': removed.kind, 'reason': reason});
    }
  }

  Future<WelcomeInfo> connect() async {
    if (_disposed) {
      throw const GbridgeException(
        status: 0,
        code: 'gbridge/stream_disposed',
        message: 'vanilla mux engine has been disposed',
      );
    }
    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final epoch = ++_connEpoch;
    _closeCurrentSocket();
    _setPhase(_hasConnectedOnce ? ConnectionPhase.reconnecting : ConnectionPhase.connecting);

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

    try {
      final ws = await openSocket('/api/remote.mux');
      if (_disposed || _manualDisconnect || epoch != _connEpoch) {
        unawaited(ws.close().catchError((_) {}));
        throw const GbridgeException(
          status: 0,
          code: 'gbridge/ws_superseded',
          message: 'WebSocket connection superseded',
        );
      }
      _pendingWelcome = welcomeCompleter;
      _eventsReopenAttempts = 0;
      _ws = ws;
      _wsSub = ws.messages.listen(
        (raw) {
          _lastInboundAtMs = DateTime.now().millisecondsSinceEpoch;
          if (epoch == _connEpoch) _onTextMessage(raw, epoch);
        },
        onError: (Object _) => _handleDisconnect(epoch),
        onDone: () => _handleDisconnect(epoch),
        cancelOnError: true,
      );
      unawaited(ws.done.then((_) => _handleDisconnect(epoch), onError: (_) => _handleDisconnect(epoch)));

      // 1) Open `$events` for live host notifications + interactive approvals/questions.
      final eventsId = _nextStreamId('events');
      _streamIdToChannel[eventsId] = '__events__';
      _send({
        'type': 'open',
        'streamId': eventsId,
        'endpoint': r'$events',
        'payload': {'args': const <String, dynamic>{}},
      });

      // 2) Wait briefly for `$events` ready frame, but never block connection if host peer is read-only.
      _handshakeTimer?.cancel();
      _handshakeTimer = Timer(const Duration(milliseconds: 1400), () {
        _handshakeTimer = null;
        if (epoch == _connEpoch && !welcomeCompleter.isCompleted) {
          _finishHandshake(epoch, welcomeCompleter);
        }
      });

      final info = await welcomeCompleter.future.timeout(const Duration(seconds: 12));
      if (epoch != _connEpoch) return info;
      _reconnectAttempt = 0;
      _lastInboundAtMs = DateTime.now().millisecondsSinceEpoch;
      _startIdleWatchdog(epoch);

      // 3) Re-open every subscribed channel not already opened by handshake listeners.
      for (final ch in _channels) {
        if (ch != 'host' && !_activeChannelStreams.containsKey(ch)) {
          _openChannelStream(ch);
        }
      }
      return info;
    } catch (err) {
      if (epoch == _connEpoch) {
        // Advance epoch BEFORE closing the socket so ws.done microtasks cannot clobber phase!
        _connEpoch++;
        _pendingWelcome = null;
        _closeCurrentSocket();
        final errText = err.toString().toLowerCase();
        final isAuthRejected = (err is GbridgeException && (err.status == 401 || err.status == 403)) ||
            errText.contains('http status code: 401') ||
            errText.contains('http status code: 403') ||
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

  void _finishHandshake(int epoch, Completer<WelcomeInfo> completer) {
    if (epoch != _connEpoch || completer.isCompleted) return;
    _hasConnectedOnce = true;
    _setPhase(ConnectionPhase.connected);
    final welcome = WelcomeInfo(
      bootId: _bootId,
      currentSeq: _seq,
      resumed: false,
      replayedCount: 0,
      heartbeatMs: 20000,
      pendingInteractions: listPendingInteractions(),
    );
    completer.complete(welcome);
    if (_pendingWelcome == completer) _pendingWelcome = null;
    if (!_welcomeController.isClosed) _welcomeController.add(welcome);
    if (!_framesController.isClosed) {
      _framesController.add(StreamFrame(
        op: 'welcome',
        seq: _seq,
        channel: 'host',
        type: 'welcome',
        data: {
          'bootId': _bootId,
          'currentSeq': _seq,
          'resumed': false,
          'replayedCount': 0,
          'heartbeatMs': 20000,
          'pendingInteractions': _pendingInteractions.values.map((e) => e.toJson()).toList(),
        },
      ));
    }
  }

  /// Open a temporary logical stream over `/api/remote.mux` (e.g. `workspace/follow`,
  /// `mcpManager/watch`, `job/list`), read its first `item`, cancel immediately, and return it.
  Future<dynamic> readFirstStreamItem(
    String endpoint,
    Map<String, dynamic> args, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (_ws == null || _phase != ConnectionPhase.connected) {
      // Open a short-lived mux connection if the main stream isn't connected yet.
      final deadline = DateTime.now().add(timeout);
      GbridgeRawWebSocket? tempWs;
      var timedOut = false;
      try {
        final openFuture = openSocket('/api/remote.mux');
        unawaited(openFuture.then((ws) {
          if (timedOut) unawaited(ws.close().catchError((_) {}));
        }, onError: (_) {}));
        tempWs = await openFuture.timeout(timeout, onTimeout: () {
          timedOut = true;
          throw TimeoutException('oneshot socket open timed out');
        });
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          throw TimeoutException('oneshot stream timed out before open');
        }
        final sid = 'oneshot-${++_streamSeq}';
        final completer = Completer<dynamic>();
        final sub = tempWs.messages.listen(
          (raw) {
            try {
              final decoded = jsonDecode(raw);
              if (decoded is! Map<String, dynamic>) return;
              if (decoded['streamId'] != sid) return;
              final type = decoded['type'];
              if (type == 'item' && !completer.isCompleted) {
                completer.complete(decoded['value']);
              } else if (type == 'end' && !completer.isCompleted) {
                completer.complete(null);
              } else if (type == 'error' && !completer.isCompleted) {
                completer.completeError(_decodeMuxError(decoded['error']));
              }
            } catch (_) {}
          },
          onError: (Object e) {
            if (!completer.isCompleted) completer.completeError(e);
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete(null);
          },
        );
        tempWs.sendText(jsonEncode({
          'type': 'open',
          'streamId': sid,
          'endpoint': endpoint,
          'payload': {'args': args},
        }));
        try {
          return await completer.future.timeout(remaining);
        } finally {
          try {
            tempWs.sendText(jsonEncode({'type': 'cancel', 'streamId': sid}));
          } catch (_) {}
          await sub.cancel();
        }
      } finally {
        await tempWs?.close().catchError((_) {});
      }
    }

    final sid = _nextStreamId('oneshot');
    final completer = Completer<dynamic>();
    _oneShotWaiters[sid] = completer;
    _send({
      'type': 'open',
      'streamId': sid,
      'endpoint': endpoint,
      'payload': {'args': args},
    });
    try {
      return await completer.future.timeout(timeout);
    } finally {
      _oneShotWaiters.remove(sid);
      _send({'type': 'cancel', 'streamId': sid});
    }
  }

  void subscribe(String channel, {bool force = false}) {
    if (channel.isEmpty) return;
    final added = _channels.add(channel);
    if ((added || force || !_activeChannelStreams.containsKey(channel)) &&
        _ws != null &&
        _phase == ConnectionPhase.connected &&
        channel != 'host') {
      _openChannelStream(channel);
    }
  }

  void unsubscribe(String channel) {
    if (channel == 'host') return;
    _channels.remove(channel);
    final existing = _activeChannelStreams.remove(channel);
    if (existing != null) {
      _streamIdToChannel.remove(existing.streamId);
      _send({'type': 'cancel', 'streamId': existing.streamId});
    }
    if (channel.startsWith('session:')) {
      final sid = channel.substring(8);
      _activeTurns.remove(sid);
      normalizer.clearSessionStat(sid);
    }
  }

  void sendTerminalInput(String terminalId, String data) {
    final entry = _findTerminalSub(terminalId);
    if (entry == null) return;
    entry.uplinkSeq += 1;
    _send({
      'type': 'item',
      'streamId': entry.streamId,
      'value': {
        'type': 'write',
        'sequence': entry.uplinkSeq,
        'data': data,
        'typed': true,
      },
    });
  }

  void sendTerminalResize(String terminalId, int cols, int rows) {
    final entry = _findTerminalSub(terminalId);
    if (entry == null) return;
    entry.uplinkSeq += 1;
    _send({
      'type': 'item',
      'streamId': entry.streamId,
      'value': {
        'type': 'resize',
        'sequence': entry.uplinkSeq,
        'cols': cols,
        'rows': rows,
      },
    });
  }

  void reconnectNow() {
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

  Future<bool> checkLiveness({
    Duration timeout = const Duration(seconds: 3),
    bool force = false,
  }) async {
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
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!force && nowMs - _lastInboundAtMs < 4000) return true;
    final epoch = _connEpoch;
    try {
      await readFirstStreamItem('workspace/follow', const {}, timeout: timeout);
      return true;
    } catch (err) {
      // Only tear down on timeout or dead-socket errors; an RPC-level rejection means WS is alive!
      final isDead = err is TimeoutException ||
          (err is GbridgeException && (err.code == 'gbridge/ws_closed' || err.status == 0));
      if (!isDead) return true;
      if (epoch == _connEpoch && !_disposed && !_manualDisconnect) {
        _handleDisconnect(epoch);
      }
      return false;
    }
  }

  _MuxChannelSub? _findTerminalSub(String terminalId) {
    for (final entry in _activeChannelStreams.values) {
      if (entry.prefix == 'terminal' &&
          (entry.targetId == terminalId || entry.channel.endsWith(':$terminalId'))) {
        return entry;
      }
    }
    return null;
  }

  void _openChannelStream(String channel, {bool useLegacySessionFollow = false}) {
    final prev = _activeChannelStreams.remove(channel);
    if (prev != null) {
      _streamIdToChannel.remove(prev.streamId);
      _send({'type': 'cancel', 'streamId': prev.streamId});
    }
    final colonIdx = channel.indexOf(':');
    if (colonIdx <= 0) return;
    final prefix = channel.substring(0, colonIdx);
    final rawTarget = channel.substring(colonIdx + 1);
    if (rawTarget.isEmpty) return;

    String endpoint;
    Map<String, dynamic> args;
    var targetId = rawTarget;

    if (prefix == 'session') {
      endpoint = 'session/follow';
      args = useLegacySessionFollow
          ? {'request': {'sessionId': rawTarget}}
          : {
              'request': {
                'address': {'kind': 'session', 'sessionId': rawTarget},
                'assistantStream': true,
                'activate': true,
              },
            };
    } else if (prefix == 'terminal') {
      endpoint = 'terminal/attach';
      final sep = rawTarget.indexOf(':');
      final agentId = sep > 0 ? rawTarget.substring(0, sep) : rawTarget;
      targetId = sep > 0 ? rawTarget.substring(sep + 1) : rawTarget;
      args = {'agentId': agentId, 'id': targetId};
    } else if (prefix == 'job') {
      endpoint = 'job/follow';
      final sep = rawTarget.indexOf(':');
      if (sep > 0) {
        final sid = rawTarget.substring(0, sep);
        targetId = rawTarget.substring(sep + 1);
        args = {'request': {'sessionId': sid, 'jobId': targetId}};
      } else {
        args = {'request': {'jobId': rawTarget}};
      }
    } else {
      return;
    }

    final streamId = _nextStreamId(prefix);
    final sub = _MuxChannelSub(
      channel: channel,
      streamId: streamId,
      prefix: prefix,
      targetId: targetId,
      usedLegacyFollow: useLegacySessionFollow,
    );
    _activeChannelStreams[channel] = sub;
    _streamIdToChannel[streamId] = channel;
    _send({
      'type': 'open',
      'streamId': streamId,
      'endpoint': endpoint,
      'payload': {'args': args},
    });
  }

  void _onTextMessage(String raw, int epoch) {
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      msg = decoded;
    } catch (_) {
      return;
    }

    final type = msg['type']?.toString() ?? '';
    final streamId = msg['streamId']?.toString() ?? '';
    if (streamId.isEmpty) return;

    // 1) One-shot stream responses (`workspace/follow`, `mcpManager/watch`, `job/list`).
    final oneShot = _oneShotWaiters[streamId];
    if (oneShot != null) {
      if (type == 'item') {
        _oneShotWaiters.remove(streamId);
        if (!oneShot.isCompleted) oneShot.complete(msg['value']);
        _send({'type': 'cancel', 'streamId': streamId});
      } else if (type == 'end') {
        _oneShotWaiters.remove(streamId);
        if (!oneShot.isCompleted) oneShot.complete(null);
      } else if (type == 'error') {
        _oneShotWaiters.remove(streamId);
        if (!oneShot.isCompleted) oneShot.completeError(_decodeMuxError(msg['error']));
      }
      return;
    }

    final channel = _streamIdToChannel[streamId];
    if (channel == null) return;

    // 2) Host `$events` stream.
    if (channel == '__events__') {
      if (type == 'item' && msg['value'] is Map) {
        _eventsReopenAttempts = 0;
        _handleHostEventFrame(_asStringMap(msg['value'] as Map), epoch);
      } else if (type == 'error' || type == 'end') {
        _streamIdToChannel.remove(streamId);
        final pending = _pendingWelcome;
        if (pending != null && !pending.isCompleted) {
          _finishHandshake(epoch, pending);
        } else if (epoch == _connEpoch && _phase == ConnectionPhase.connected && !_disposed && !_manualDisconnect) {
          // `$events` closed unexpectedly while WS stays alive — reopen so approvals/questions keep arriving.
          _eventsClientId = null;
          _eventsReopenTimer?.cancel();
          if (_eventsReopenAttempts < 4) {
            final delayMs = 600 * (1 << _eventsReopenAttempts);
            _eventsReopenAttempts++;
            _eventsReopenTimer = Timer(Duration(milliseconds: delayMs), () {
              _eventsReopenTimer = null;
              if (_disposed || _manualDisconnect || epoch != _connEpoch || _ws == null) return;
              final nextEventsId = _nextStreamId('events');
              _streamIdToChannel[nextEventsId] = '__events__';
              _send({
                'type': 'open',
                'streamId': nextEventsId,
                'endpoint': r'$events',
                'payload': {'args': const <String, dynamic>{}},
              });
            });
          } else {
            _handleDisconnect(epoch);
          }
        }
      }
      return;
    }

    // 3) Subscribed channel stream (`session:*`, `terminal:*`, `job:*`).
    final sub = _activeChannelStreams[channel];
    if (sub == null || sub.streamId != streamId) return;

    if (type == 'item') {
      _forwardChannelItem(sub, msg['value']);
    } else if (type == 'end') {
      _activeChannelStreams.remove(channel);
      _streamIdToChannel.remove(streamId);
      if (sub.prefix == 'session') {
        _activeTurns.remove(sub.targetId);
        normalizer.clearSessionStat(sub.targetId);
      }
      _publish(channel, '${sub.prefix}.stream_end', {'id': sub.targetId});
    } else if (type == 'error') {
      final err = msg['error'];
      final errCode = (err is Map ? err['code']?.toString() : null) ?? '';
      // Fallback for DSH 0.1.x where `session/follow` took `{ sessionId }` instead of `{ address }`.
      if (sub.prefix == 'session' &&
          !sub.usedLegacyFollow &&
          errCode.contains('arguments-invalid')) {
        _openChannelStream(channel, useLegacySessionFollow: true);
        return;
      }
      _activeChannelStreams.remove(channel);
      _streamIdToChannel.remove(streamId);
      if (sub.prefix == 'session') {
        _activeTurns.remove(sub.targetId);
        normalizer.clearSessionStat(sub.targetId);
      }
      final errMsg = (err is Map ? err['message']?.toString() : err?.toString()) ?? 'stream error';
      _publish(channel, '${sub.prefix}.stream_error', {'id': sub.targetId, 'message': errMsg});
    }
  }

  void _handleHostEventFrame(Map<String, dynamic> frame, int epoch) {
    final type = frame['type']?.toString() ?? '';
    if (type == 'ready') {
      _eventsClientId = frame['clientId']?.toString();
      final hostObj = frame['host'];
      if (hostObj is Map) _hostHome = hostObj['home']?.toString();
      _bootId = 'vanilla-${_eventsClientId ?? DateTime.now().millisecondsSinceEpoch}';
      final pending = _pendingWelcome;
      if (pending != null && !pending.isCompleted) {
        _finishHandshake(epoch, pending);
      }
      _publish('host', 'host.ready', {'home': _hostHome});
      return;
    }
    if (type == 'emit') {
      final ev = frame['event']?.toString() ?? '';
      final args = frame['args'] is List ? frame['args'] as List : const <dynamic>[];
      if (ev == 'cordis/request-run') {
        final req = args.isNotEmpty && args.first is Map
            ? _asStringMap(args.first as Map)
            : const <String, dynamic>{};
        final id = (req['id'] ?? req['requestId'] ?? 'cordis-${DateTime.now().microsecondsSinceEpoch}')
            .toString();
        final item = _PendingVanillaInteraction(
          id: id,
          kind: 'cordis_run',
          event: ev,
          eventId: id,
          gatewayClientId: _eventsClientId,
          sessionId: (req['agentId'] ?? req['sessionId'])?.toString(),
          payload: req,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
        _pendingInteractions[id] = item;
        _publish('host', 'interaction.requested', item.toJson());
        return;
      }
      if (ev == 'cordis/request-run-resolved') {
        final req = args.isNotEmpty && args.first is Map
            ? _asStringMap(args.first as Map)
            : const <String, dynamic>{};
        final id = (req['id'] ?? req['requestId'] ?? '').toString();
        if (id.isNotEmpty && _pendingInteractions.remove(id) != null) {
          _publish('host', 'interaction.resolved', {
            'id': id,
            'kind': 'cordis_run',
            'resolution': req,
          });
        }
        return;
      }
      if (ev == 'api-session/removed' || ev == 'api-session/archived') {
        final raw = args.isNotEmpty ? args.first : null;
        final sid = raw is Map
            ? (raw['id'] ?? raw['sessionId'])?.toString()
            : raw?.toString();
        if (sid != null && sid.isNotEmpty) {
          _sessionAlwaysAllowed.remove(sid);
        }
      }
      final mapped = _mapHostEmitEvent(ev, args);
      _publish(mapped.channel, mapped.type, mapped.data);
      return;
    }
    if (type == 'waterfall' || type == 'request') {
      final ev = frame['event']?.toString() ?? '';
      final eventId =
          (frame['eventId'] ?? 'ev-${DateTime.now().microsecondsSinceEpoch}').toString();
      final kind = ev == 'approval/request'
          ? 'approval'
          : (ev == 'user-questions/request' ? 'user_questions' : 'request');
      final payloadRaw = frame['request'] ?? frame['payload'] ?? frame;
      final payload = payloadRaw is Map ? _asStringMap(payloadRaw) : <String, dynamic>{};
      final sessionId = (frame['agentId'] ?? payload['sessionId'])?.toString();
      if (kind == 'approval' &&
          _eventsClientId != null &&
          onAutoApprove != null &&
          _isSessionAlwaysAllowed(sessionId, payload)) {
        unawaited(
          onAutoApprove!(_eventsClientId!, eventId).catchError((_) {}),
        );
        return;
      }
      final item = _PendingVanillaInteraction(
        id: eventId,
        kind: kind,
        event: ev,
        eventId: eventId,
        gatewayClientId: _eventsClientId,
        sessionId: sessionId,
        payload: payload,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      _pendingInteractions[eventId] = item;
      _publish('host', 'interaction.requested', item.toJson());
      return;
    }
    if (type == 'cancel' || type == 'resolved') {
      final eventId = frame['eventId']?.toString() ?? '';
      if (eventId.isNotEmpty && _pendingInteractions.remove(eventId) != null) {
        _publish('host', 'interaction.resolved', {
          'id': eventId,
          'reason': frame['reason']?.toString() ?? 'settled_elsewhere',
        });
      }
    }
  }

  void _forwardChannelItem(_MuxChannelSub sub, Object? rawItem) {
    final prefix = sub.prefix;
    final targetId = sub.targetId;
    final channel = sub.channel;
    final item = rawItem is Map ? _asStringMap(rawItem) : null;

    if (prefix == 'terminal') {
      if (item != null && item['type'] == 'snapshot' && item['screen'] is String) {
        _publish(channel, 'term.snapshot', {
          'terminalId': targetId,
          'screen': item['screen'],
        });
        return;
      }
      if (item != null && item['type'] == 'output' && item['data'] is String) {
        _publish(channel, 'term.data', {
          'terminalId': targetId,
          'chunk': item['data'],
        }, op: 'delta');
        return;
      }
      if (item != null && item['type'] == 'state' && item['info'] is Map) {
        final info = item['info'] as Map;
        if (info['state'] == 'exited') {
          _publish(channel, 'term.exit', {
            'terminalId': targetId,
            'code': info['exitCode'],
          });
        }
        return;
      }
      final fallbackData = rawItem is String
          ? rawItem
          : (item?['data'] ?? item?['chunk'])?.toString() ?? '';
      if (fallbackData.isNotEmpty) {
        _publish(channel, 'term.data', {'terminalId': targetId, 'chunk': fallbackData}, op: 'delta');
      }
      return;
    }

    if (prefix == 'job') {
      var chunk = '';
      if (item != null && item['type'] == 'output' && item['chunks'] is List) {
        final buf = StringBuffer();
        for (final c in item['chunks'] as List) {
          if (c is Map && c['text'] != null) buf.write(c['text']);
        }
        chunk = buf.toString();
      } else if (rawItem is String) {
        chunk = rawItem;
      } else if (item != null) {
        chunk = (item['chunk'] ?? item['data'] ?? '').toString();
      }
      if (chunk.isNotEmpty) {
        _publish(channel, 'job.output', {'jobId': targetId, 'chunk': chunk}, op: 'delta');
      } else {
        _publish(channel, 'job.event', {'jobId': targetId, 'raw': rawItem});
      }
      return;
    }

    if (item == null) return;
    final kind = item['type']?.toString() ?? '';

    if (kind == 'assistant-stream') {
      final frameRaw = item['frame'] ?? item;
      final frame = frameRaw is Map ? _asStringMap(frameRaw) : item;
      final fType = frame['type']?.toString() ?? '';
      final activeTid = _activeTurns[targetId];
      if (fType == 'chunk' && frame['chunk'] is Map) {
        final inner = _asStringMap(frame['chunk'] as Map);
        final activity = normalizer.observeStreamChunk(targetId, inner);
        if (!_enqueueCoalescedChunk(channel, targetId, activeTid, inner, activity)) {
          _flushCoalescedDelta(channel);
          _publish(channel, 'turn.delta', {
            'sessionId': targetId,
            if (activeTid != null) 'turnId': activeTid,
            'chunk': inner,
            'activity': activity,
          }, op: 'delta');
        }
      } else if (fType == 'start') {
        _flushCoalescedDelta(channel);
        // Preserve an existing canonical/UUID turnId instead of overwriting with synthetic `turn-N`.
        final tid = (activeTid != null && !activeTid.startsWith('turn-'))
            ? activeTid
            : (frame['turn'] != null ? 'turn-${frame['turn']}' : activeTid);
        if (tid != null) _activeTurns[targetId] = tid;
        normalizer.observeStreamChunk(targetId, const {'type': 'step/start'});
        _publish(channel, 'turn.delta', {
          'sessionId': targetId,
          if (tid != null) 'turnId': tid,
          'chunk': {'type': 'turn/start', 'turn': frame['turn'], 'step': frame['step']},
        });
      } else if (fType == 'end' &&
          frame['outcome'] is Map &&
          (frame['outcome'] as Map)['kind'] == 'abandoned') {
        _flushCoalescedDelta(channel);
        _publish(channel, 'turn.delta', {
          'sessionId': targetId,
          if (activeTid != null) 'turnId': activeTid,
          'chunk': {'type': 'assistant-stream/abandoned', 'turn': frame['turn'], 'step': frame['step']},
        });
      }
      return;
    }

    if (kind == 'text-chunks' ||
        kind == 'reasoning-chunks' ||
        kind == 'tool-call-chunks' ||
        kind == 'chunk') {
      final activeTid = _activeTurns[targetId];
      final activity = normalizer.observeStreamChunk(targetId, item);
      if (!_enqueueCoalescedChunk(channel, targetId, activeTid, item, activity)) {
        _flushCoalescedDelta(channel);
        _publish(channel, 'turn.delta', {
          'sessionId': targetId,
          if (activeTid != null) 'turnId': activeTid,
          'chunk': item,
          'activity': activity,
        }, op: 'delta');
      }
      return;
    }

    if (kind == 'snapshot') {
      final rawRecords = (item['records'] ?? item['events'] ?? item['history']) as List? ?? const [];
      final turns = normalizer.normalizeEvents(targetId, rawRecords);
      if (turns.isNotEmpty && turns.last['status'] == 'streaming') {
        final tid = turns.last['turnId']?.toString();
        if (tid != null && tid.isNotEmpty) _activeTurns[targetId] = tid;
      } else {
        _activeTurns.remove(targetId);
      }
      _publish(channel, 'turn.snapshot', {
        'sessionId': targetId,
        'turns': turns,
        'projections': item['projections'] ?? const <String, dynamic>{},
        'rawRevision': item['revision'] ?? item['cursor'],
      });
      return;
    }

    if (kind == 'event' && item['event'] is Map) {
      final ev = _asStringMap(item['event'] as Map);
      final evType = ev['type']?.toString() ?? '';
      final eventSeq = ev['seq'] is num ? (ev['seq'] as num).toInt() : null;
      final evData = ev['data'] is Map ? _asStringMap(ev['data'] as Map) : const <String, dynamic>{};
      if (evType == 'turn/start' || evType == 'turn_start') {
        final turnId = evData['turnId']?.toString() ??
            (evData['turn'] != null
                ? 'turn-${evData['turn']}'
                : (ev['id']?.toString().isNotEmpty == true
                    ? ev['id'].toString()
                    : 'turn-${eventSeq ?? DateTime.now().millisecondsSinceEpoch}'));
        _activeTurns[targetId] = turnId;
        _publish(channel, 'turn.start', {
          'sessionId': targetId,
          'turnId': turnId,
          if (eventSeq != null) 'eventSeq': eventSeq,
          'raw': ev,
        });
        return;
      }
      if (evType == 'turn/end' || evType == 'turn_end') {
        final turnId = evData['turnId']?.toString() ??
            (evData['turn'] != null ? 'turn-${evData['turn']}' : _activeTurns[targetId]);
        _activeTurns.remove(targetId);
        normalizer.clearSessionStat(targetId);
        final fail = VanillaDshNormalizer.extractFailureInfo(evData['reason'], evData);
        _publish(channel, 'turn.completed', {
          'sessionId': targetId,
          if (turnId != null) 'turnId': turnId,
          if (eventSeq != null) 'eventSeq': eventSeq,
          'raw': ev,
          if (fail != null) 'errorMessage': fail.message,
          if (fail?.code != null) 'errorCode': fail!.code,
        });
        return;
      }
      final activeTurnId = _activeTurns[targetId];
      final deltaTurns = normalizer.normalizeEvents(
        targetId,
        [ev],
        incremental: true,
        activeTurnId: activeTurnId,
      );
      _publish(channel, 'session.event', {
        'sessionId': targetId,
        if (eventSeq != null) 'eventSeq': eventSeq,
        'raw': ev,
        if (deltaTurns.isNotEmpty) 'normalizedTurn': deltaTurns.first,
      });
      return;
    }

    if (kind == 'projections' || kind == 'projection') {
      _publish(channel, 'projection.updated', {
        'sessionId': targetId,
        'projections': item['projections'] ?? item['data'] ?? item,
      });
      return;
    }

    _publish(channel, 'session.event', {'sessionId': targetId, 'raw': item});
  }

  static String _extractDeltaText(Map<String, dynamic> chunk) {
    final direct = chunk['text'] ?? chunk['delta'] ?? chunk['chunk'];
    if (direct is String && direct.isNotEmpty) return direct;
    final texts = chunk['texts'];
    if (texts is List && texts.isNotEmpty) {
      final buf = StringBuffer();
      for (final s in texts) {
        if (s != null) buf.write(s.toString());
      }
      return buf.toString();
    }
    return '';
  }

  /// Coalesce high-frequency text / reasoning WS chunks over [coalesceWindow] (28ms)
  /// so stock DSH streams hit ~35 batches/sec instead of 200+ raw token frames/sec.
  bool _enqueueCoalescedChunk(
    String channel,
    String sessionId,
    String? turnId,
    Map<String, dynamic> chunk,
    Map<String, dynamic> activity,
  ) {
    if (coalesceWindow <= Duration.zero) return false;
    final ctype = chunk['type']?.toString() ?? '';
    final ckind = chunk['kind']?.toString() ?? '';
    String? normType;
    if (ctype == 'text-delta' || ctype == 'text-chunks' || ckind == 'text') {
      normType = 'text-delta';
    } else if (ctype == 'reasoning-delta' || ctype == 'reasoning-chunks' || ckind == 'reasoning') {
      normType = 'reasoning-delta';
    }
    if (normType == null) return false;
    final text = _extractDeltaText(chunk);
    if (text.isEmpty) return true;
    final stepId = chunk['id']?.toString();

    final existing = _pendingDeltas[channel];
    if (existing != null &&
        (existing.chunkType != normType ||
            existing.turnId != turnId ||
            existing.stepId != stepId)) {
      _flushCoalescedDelta(channel);
    }
    final batch = _pendingDeltas.putIfAbsent(
      channel,
      () => _CoalescedDeltaBatch(
        channel: channel,
        sessionId: sessionId,
        turnId: turnId,
        chunkType: normType!,
        stepId: stepId,
      ),
    );
    batch.textBuf.write(text);
    batch.lastActivity = activity;
    _coalesceTimer ??= Timer(coalesceWindow, _flushAllCoalescedDeltas);
    return true;
  }

  void _flushCoalescedDelta(String channel) {
    final batch = _pendingDeltas.remove(channel);
    if (batch == null || batch.textBuf.isEmpty) return;
    final merged = batch.textBuf.toString();
    _publishRaw(batch.channel, 'turn.delta', {
      'sessionId': batch.sessionId,
      if (batch.turnId != null) 'turnId': batch.turnId,
      'chunk': {
        'type': batch.chunkType,
        'delta': merged,
        'text': merged,
        if (batch.stepId != null) 'id': batch.stepId,
      },
      if (batch.lastActivity != null) 'activity': batch.lastActivity,
    }, op: 'delta');
  }

  void _flushAllCoalescedDeltas() {
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    if (_pendingDeltas.isEmpty) return;
    final keys = _pendingDeltas.keys.toList(growable: false);
    for (final ch in keys) {
      _flushCoalescedDelta(ch);
    }
  }

  void _publish(
    String channel,
    String type,
    Map<String, dynamic> data, {
    String op = 'event',
  }) {
    if (type != 'turn.delta' && _pendingDeltas.containsKey(channel)) {
      _flushCoalescedDelta(channel);
    }
    _publishRaw(channel, type, data, op: op);
  }

  void _publishRaw(
    String channel,
    String type,
    Map<String, dynamic> data, {
    String op = 'event',
  }) {
    if (_disposed || _framesController.isClosed) return;
    _seq += 1;
    _framesController.add(StreamFrame(
      op: op,
      seq: _seq,
      channel: channel,
      type: type,
      ts: DateTime.now().millisecondsSinceEpoch,
      data: data,
    ));
  }

  void _send(Map<String, dynamic> frame) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.sendText(jsonEncode(frame));
    } catch (_) {}
  }

  void _startIdleWatchdog(int epoch) {
    _idleWatchdogTimer?.cancel();
    _idleWatchdogTimer = Timer.periodic(const Duration(seconds: 28), (_) {
      if (_disposed || _manualDisconnect || epoch != _connEpoch || _phase != ConnectionPhase.connected) {
        _idleWatchdogTimer?.cancel();
        _idleWatchdogTimer = null;
        return;
      }
      final idleMs = DateTime.now().millisecondsSinceEpoch - _lastInboundAtMs;
      if (idleMs >= 25000) {
        unawaited(checkLiveness(force: true));
      }
    });
  }

  void _closeCurrentSocket() {
    _flushAllCoalescedDeltas();
    _idleWatchdogTimer?.cancel();
    _idleWatchdogTimer = null;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _eventsReopenTimer?.cancel();
    _eventsReopenTimer = null;
    _wsSub?.cancel();
    _wsSub = null;
    final old = _ws;
    _ws = null;
    if (old != null) {
      unawaited(old.close().catchError((_) {}));
    }
    for (final sid in _activeTurns.keys.toList(growable: false)) {
      normalizer.clearSessionStat(sid);
    }
    _activeTurns.clear();
    _activeChannelStreams.clear();
    _streamIdToChannel.clear();
    _eventsClientId = null;
    if (_pendingInteractions.isNotEmpty) {
      final staleIds = _pendingInteractions.keys.toList(growable: false);
      for (final id in staleIds) {
        markInteractionResolved(id, reason: 'disconnected');
      }
    }
    for (final w in _oneShotWaiters.values) {
      if (!w.isCompleted) {
        w.completeError(const GbridgeException(
          status: 0,
          code: 'gbridge/ws_closed',
          message: 'WebSocket closed while reading stream',
        ));
      }
    }
    _oneShotWaiters.clear();
  }

  void _handleDisconnect(int epoch) {
    if (epoch != _connEpoch) return;
    // Advance epoch immediately so duplicate onError/onDone/ws.done callbacks are strict no-ops.
    _connEpoch++;
    _closeCurrentSocket();
    final pending = _pendingWelcome;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const GbridgeException(
        status: 0,
        code: 'gbridge/ws_closed',
        message: 'DSH remote.mux WebSocket closed',
      ));
    }
    _pendingWelcome = null;
    if (_disposed || _manualDisconnect) {
      _setPhase(ConnectionPhase.disconnected);
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
    final baseMs = (700 * (1 << _reconnectAttempt.clamp(0, 5))).clamp(700, 15000);
    final jitterFactor = 0.8 + _jitterRng.nextDouble() * 0.4; // +/- 20% jitter
    final delayMs = (baseMs * jitterFactor).round().clamp(500, 18000);
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
    _closeCurrentSocket();
    final pending = _pendingWelcome;
    _pendingWelcome = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const GbridgeException(
        status: 0,
        code: 'gbridge/disconnected',
        message: 'DSH remote.mux manually disconnected',
      ));
    }
    _setPhase(ConnectionPhase.disconnected);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
    _sessionAlwaysAllowed.clear();
    await _framesController.close();
    await _phaseController.close();
    await _welcomeController.close();
  }

  String _nextStreamId(String tag) => '$tag-${++_streamSeq}';

  static GbridgeException _decodeMuxError(Object? err) {
    if (err is Map) {
      return GbridgeException(
        status: 400,
        code: err['code']?.toString() ?? 'dsh/stream_error',
        message: err['message']?.toString() ?? 'DSH stream error',
        details: err['details'],
      );
    }
    return GbridgeException(
      status: 400,
      code: 'dsh/stream_error',
      message: err?.toString() ?? 'DSH stream error',
    );
  }

  static Map<String, dynamic> _asStringMap(Map raw) {
    if (raw is Map<String, dynamic>) return raw;
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }

  static ({String channel, String type, Map<String, dynamic> data}) _mapHostEmitEvent(
    String event,
    List<dynamic> args,
  ) {
    if (event.startsWith('api-session/')) {
      return (
        channel: 'host',
        type: 'session.${event.substring('api-session/'.length)}',
        data: {'args': args},
      );
    }
    if (event.startsWith('plugin-manager/')) {
      final suffix = event.substring('plugin-manager/'.length);
      final first = args.isNotEmpty && args.first is Map ? _asStringMap(args.first as Map) : null;
      final reqId = first?['requestId']?.toString();
      if (reqId != null && reqId.isNotEmpty && (suffix == 'install-log' || suffix == 'install-state')) {
        return (
          channel: 'install:$reqId',
          type: 'install.${suffix.replaceFirst('install-', '')}',
          data: first!,
        );
      }
      return (channel: 'host', type: 'plugins.$suffix', data: {'args': args});
    }
    if (event.startsWith('deepseek-account/')) {
      return (channel: 'host', type: 'auth.notice', data: {'event': event, 'args': args});
    }
    if (event == 'schedule/changed') {
      return (channel: 'host', type: 'schedule.changed', data: {'args': args});
    }
    if (event == 'settings/document-updated' || event == 'web/providers-changed') {
      return (channel: 'host', type: 'settings.updated', data: {'event': event, 'args': args});
    }
    if (event == 'commands/change') {
      return (channel: 'host', type: 'commands.changed', data: {'args': args});
    }
    if (event == 'llm/adapters-updated' || event == 'llm/models-updated') {
      return (channel: 'host', type: 'models.updated', data: {'event': event, 'args': args});
    }
    if (event == 'credentials/reference-updated' || event == 'credentials/record-updated') {
      return (channel: 'host', type: 'credentials.updated', data: {'event': event, 'args': args});
    }
    if (event == 'goal/activation-changed') {
      return (channel: 'host', type: 'goal.changed', data: {'args': args});
    }
    if (event == 'agent-preset/selected' || event == 'permission-presets/catalog-changed') {
      return (channel: 'host', type: 'presets.changed', data: {'event': event, 'args': args});
    }
    return (channel: 'host', type: 'host.event', data: {'event': event, 'args': args});
  }
}

class _MuxChannelSub {
  _MuxChannelSub({
    required this.channel,
    required this.streamId,
    required this.prefix,
    required this.targetId,
    this.usedLegacyFollow = false,
  });

  final String channel;
  final String streamId;
  final String prefix;
  final String targetId;
  final bool usedLegacyFollow;
  int uplinkSeq = 0;
}

class _PendingVanillaInteraction {
  const _PendingVanillaInteraction({
    required this.id,
    required this.kind,
    required this.event,
    required this.eventId,
    required this.gatewayClientId,
    required this.sessionId,
    required this.payload,
    required this.createdAt,
  });

  final String id;
  final String kind;
  final String event;
  final String eventId;
  final String? gatewayClientId;
  final String? sessionId;
  final Map<String, dynamic> payload;
  final int createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'event': event,
        'sessionId': sessionId,
        'payload': payload,
        'createdAt': createdAt,
      };
}

class _CoalescedDeltaBatch {
  _CoalescedDeltaBatch({
    required this.channel,
    required this.sessionId,
    required this.turnId,
    required this.chunkType,
    required this.stepId,
  });

  final String channel;
  final String sessionId;
  final String? turnId;
  final String chunkType;
  final String? stepId;
  final StringBuffer textBuf = StringBuffer();
  Map<String, dynamic>? lastActivity;
}
