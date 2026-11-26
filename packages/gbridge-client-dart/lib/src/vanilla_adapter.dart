import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';
import 'transport.dart';
import 'vanilla_mux.dart';
import 'vanilla_normalizer.dart';

/// Direct adapter translating GrassBag's high-level [GbridgeClient] operations
/// directly onto stock `@deepseek-ai/dsh` (`dsh web`) native `POST /api/<ns>/<method>`
/// + `WS /api/remote.mux` endpoints — ZERO plugins required on the remote host!
class VanillaDshAdapter {
  VanillaDshAdapter({
    required this.transport,
    required this.mux,
    required this.normalizer,
    required this.dshVersion,
    this.hostName,
  });

  final GbridgeHttpTransport transport;
  final VanillaDshMuxEngine mux;
  final VanillaDshNormalizer normalizer;
  final String dshVersion;
  final String? hostName;

  int _rpcSeq = 0;

  // 2.5s single-flight + TTL micro-cache for bursty read-only discovery RPCs on connect/refresh
  // (avoids 3x settings/describe & duplicate throwaway WS workspace/follow streams!).
  static const Duration _microCacheTtl = Duration(milliseconds: 2500);
  final Map<String, ({DateTime expiresAt, dynamic value})> _readCache = {};
  final Map<String, Future<dynamic>> _inFlightReads = {};
  final Map<String, int> _cacheGen = {};

  void _invalidateCacheKey(String key) {
    _cacheGen[key] = (_cacheGen[key] ?? 0) + 1;
    _readCache.remove(key);
    _inFlightReads.remove(key);
  }

  Future<T> _cachedRead<T>(String key, Future<T> Function() loader) {
    final now = DateTime.now();
    final cached = _readCache[key];
    if (cached != null && now.isBefore(cached.expiresAt)) {
      return Future<T>.value(cached.value as T);
    }
    final existing = _inFlightReads[key];
    if (existing != null) {
      return existing.then((v) => v as T);
    }
    final gen = _cacheGen[key] ?? 0;
    final future = loader().then<dynamic>((val) {
      if ((_cacheGen[key] ?? 0) == gen) {
        _readCache[key] = (expiresAt: DateTime.now().add(_microCacheTtl), value: val);
      }
      return val;
    });
    _inFlightReads[key] = future;
    future.whenComplete(() {
      if (identical(_inFlightReads[key], future)) {
        _inFlightReads.remove(key);
      }
    }).ignore();
    return future.then((v) => v as T);
  }

  void _invalidateCachesForMutation(String method) {
    if (method.startsWith('workspace/') ||
        method == 'session/create' ||
        method == 'session/rename' ||
        method == 'session/delete') {
      _invalidateCacheKey('workspace/follow');
    }
    if (method.startsWith('settings/') && method != 'settings/describe') {
      _invalidateCacheKey('settings/describe');
      _invalidateCacheKey('llm/listProviders');
      _invalidateCacheKey('llm/listConfigurableProviders');
    }
    if (method == 'session/selectModel' || method == 'session/create') {
      _invalidateCacheKey('settings/describe');
    }
    if ((method.startsWith('llm/') &&
            method != 'llm/listProviders' &&
            method != 'llm/listConfigurableProviders') ||
        method.startsWith('credentials/') ||
        method.startsWith('deepseek') ||
        method.startsWith('plugin') ||
        method == 'agentPresets/select') {
      _invalidateCacheKey('settings/describe');
      _invalidateCacheKey('llm/listProviders');
      _invalidateCacheKey('llm/listConfigurableProviders');
      _invalidateCacheKey('agentPresets/list');
      _invalidateCacheKey('permissionPresets/catalog');
    }
  }

  /// Build synthetic [Capabilities] accurately reflecting direct native stock DSH support.
  Capabilities buildCapabilities() {
    final hostLabel = (hostName != null && hostName!.isNotEmpty)
        ? hostName!
        : (transport.endpoint.baseUri?.host ?? 'remote-dsh');
    return Capabilities(
      v: 1,
      bridgeVersion: 'direct',
      dshVersion: dshVersion,
      bootId: 'vanilla-$hostLabel',
      host: HostInfo(
        name: hostLabel,
        platform: 'remote',
        arch: 'direct',
        isLocalAndroid: false,
        homeDir: mux.hostHome,
      ),
      transport: const TransportCapabilities(
        wsPath: '/api/remote.mux',
        coalesceMs: 35,
        replayCapacity: 0,
      ),
      domains: const {
        'chat': DomainCapability(ok: true, features: ['streaming', 'turns', 'search', 'fork', 'queue', 'attachments']),
        'interactions': DomainCapability(ok: true, features: ['approval', 'user_questions']),
        'workspaces': DomainCapability(ok: true, features: ['list', 'create', 'rename', 'delete', 'browse']),
        'files': DomainCapability(ok: true, features: ['tree', 'read', 'changes', 'upload']),
        'terminal': DomainCapability(ok: true, features: ['pty', 'shells', 'multi_tab']),
        'settings': DomainCapability(ok: true, features: ['schema', 'manifest', 'models', 'credentials', 'account', 'presets']),
        'plugins': DomainCapability(ok: true, features: ['bundles', 'entries', 'install', 'mcp']),
        'schedule': DomainCapability(ok: true, features: ['list', 'create', 'edit', 'run', 'history']),
        'jobs': DomainCapability(ok: true, features: ['list', 'follow', 'kill']),
        'goals': DomainCapability(ok: true, features: ['get', 'mutate']),
        'subagents': DomainCapability(ok: true, features: ['prompt', 'interrupt']),
        'sdui': DomainCapability(ok: false, reason: 'direct_mode'),
      },
      endpointsCount: 60,
    );
  }

  /// Invoke a stock DSH unary Typert RPC (`POST /api/<namespace>/<method>`).
  Future<dynamic> rpc(String method, [Map<String, dynamic> args = const {}]) async {
    _invalidateCachesForMutation(method);
    final res = await transport.requestJson(
      'POST',
      '/api/$method',
      body: {
        'type': 'client-request',
        'rpcId': 'gb-dir-${DateTime.now().microsecondsSinceEpoch}-${++_rpcSeq}',
        'method': method,
        'payload': {'args': args},
      },
    );
    final result = res['result'];
    if (result is Map<String, dynamic>) {
      if (result['ok'] == false) {
        final err = result['error'];
        final code = (err is Map ? err['code']?.toString() : null) ?? 'dsh/rpc_error';
        final msg = (err is Map ? err['message']?.toString() : err?.toString()) ?? 'RPC $method failed';
        final details = err is Map ? err['details'] : null;
        throw GbridgeException(
          status: _mapCodeToStatus(code),
          code: code,
          message: msg,
          details: details,
        );
      }
      return result['value'];
    }
    return res;
  }

  static int _mapCodeToStatus(String code) {
    final lower = code.toLowerCase();
    if (lower.contains('not-found') || lower.contains('not_found')) return 404;
    if (lower.contains('invalid') || lower.contains('arguments')) return 400;
    if (lower.contains('unauthorized') || lower.contains('auth')) return 401;
    if (lower.contains('forbidden') || lower.contains('denied')) return 403;
    if (lower.contains('conflict') || lower.contains('busy')) return 409;
    return 502;
  }

  static Map<String, dynamic> _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
    return const <String, dynamic>{};
  }

  static List<dynamic> _asList(Object? v) => v is List ? v : const <dynamic>[];

  // ---------------------------------------------------------------------------
  // Overview & Web Ticket
  // ---------------------------------------------------------------------------
  Future<OverviewSnapshot> getOverview() async {
    final caps = buildCapabilities();
    final results = await Future.wait([
      listSessions().catchError((_) => const <SessionSummary>[]),
      getAccount().catchError((_) => const <String, dynamic>{}),
    ]);
    final sessions = results[0] as List<SessionSummary>;
    final account = results[1] as Map<String, dynamic>;
    return OverviewSnapshot(
      v: 1,
      bootId: caps.bootId,
      bridgeVersion: caps.bridgeVersion,
      dshVersion: caps.dshVersion,
      host: caps.host,
      pendingInteractionsCount: mux.listPendingInteractions().length,
      activeStreamsCount: 1,
      account: account.isEmpty ? null : account,
      sessionsCount: sessions.length,
    );
  }

  Future<WebTicket> createWebTicket({String? sessionId}) async {
    final base = transport.endpoint.baseUri;
    final token = transport.endpoint.token;
    final sid = sessionId?.trim();
    final url = base == null
        ? '/'
        : base
            .replace(
              queryParameters: (token != null && token.isNotEmpty)
                  ? {'token': token}
                  : null,
              fragment: (sid != null && sid.isNotEmpty)
                  ? '/sessions/${Uri.encodeComponent(sid)}'
                  : null,
            )
            .toString();
    return WebTicket(
      ticket: token ?? '',
      authenticatedUrl: url,
      expiresAt: DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
      sessionId: sessionId,
    );
  }

  // ---------------------------------------------------------------------------
  // Sessions & Chat
  // ---------------------------------------------------------------------------
  Future<List<SessionSummary>> listSessions({
    String? workspaceId,
    bool includeArchived = false,
  }) async {
    final raw = await rpc('session/list', const {'_request': <String, dynamic>{}}).catchError(
      (_) => rpc('session/list', const <String, dynamic>{}),
    );
    final map = _asMap(raw);
    final rawItems = _asList(map['items'] ?? map['sessions'] ?? raw);

    // Enrich pinned/archived/workspace mapping from `workspace/follow` when available.
    final wsSnap = await _readWorkspaceSnapshot();
    final archivedSet = wsSnap.archivedIds;
    final pinnedSet = wsSnap.pinnedIds;
    final sessionToWs = <String, ({String id, String name})>{};
    for (final ws in wsSnap.workspaces) {
      final wid = ws['id']?.toString() ?? '';
      final wname = ws['name']?.toString() ?? '';
      for (final sid in _asList(ws['sessionIds'])) {
        sessionToWs[sid.toString()] = (id: wid, name: wname);
      }
    }

    final out = <SessionSummary>[];
    for (final item in rawItems) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(_asMap(item));
      final sid = (m['sessionId'] ?? m['id'] ?? '').toString();
      if (sid.isEmpty) continue;
      final isArchived = m['archived'] == true || archivedSet.contains(sid);
      if (!includeArchived && isArchived) continue;
      final mappedWs = sessionToWs[sid];
      if (mappedWs != null) {
        m['workspaceId'] ??= mappedWs.id;
        m['workspaceName'] ??= mappedWs.name;
      }
      if (workspaceId != null &&
          workspaceId.isNotEmpty &&
          m['workspaceId']?.toString() != workspaceId) {
        continue;
      }
      if (pinnedSet.contains(sid)) m['pinned'] = true;
      if (isArchived) m['archived'] = true;
      out.add(SessionSummary.fromJson(m));
    }
    return out;
  }

  Future<SessionSummary> createSession({
    String? workspaceId,
    String? cwd,
    String? title,
    String? presetId,
    String? permission,
    String? provider,
    String? model,
    String? reasoningEffort,
  }) async {
    // DSH session/create rejects passing BOTH workspaceId and cwd simultaneously.
    final useWorkspaceId = workspaceId != null && workspaceId.isNotEmpty;
    final req = <String, dynamic>{
      if (useWorkspaceId) 'workspaceId': workspaceId,
      if (!useWorkspaceId && cwd != null && cwd.isNotEmpty) 'cwd': cwd,
      if (presetId != null && presetId.isNotEmpty && presetId != 'default') 'agentPreset': presetId,
    };
    final raw = await rpc('session/create', {'request': req});
    final m = _asMap(raw);
    final sid = (m['sessionId'] ?? m['id'] ?? '').toString();
    if (sid.isNotEmpty) {
      final setupFutures = <Future<Object?>>[];
      if (title != null && title.trim().isNotEmpty) {
        setupFutures.add(
          rpc('session/rename', {
            'request': {'sessionId': sid, 'title': title.trim()},
          }).catchError((_) => null),
        );
      }
      if (permission != null && permission.trim().isNotEmpty) {
        setupFutures.add(
          executeSlashCommand(sid, command: '/permission ${permission.trim()}')
              .catchError((_) => const <String, dynamic>{}),
        );
      }
      if (provider != null && provider.isNotEmpty && model != null && model.isNotEmpty) {
        setupFutures.add(
          selectModel(sid, {
            'provider': provider,
            'model': model,
            if (reasoningEffort != null && reasoningEffort.isNotEmpty)
              'reasoningEffort': reasoningEffort,
          }).catchError((_) => const <String, dynamic>{}),
        );
      }
      if (setupFutures.isNotEmpty) {
        await Future.wait<Object?>(setupFutures);
      }
    }
    return SessionSummary.fromJson({
      ...m,
      'sessionId': sid,
      if (title != null && title.isNotEmpty) 'title': title,
      if (workspaceId != null) 'workspaceId': workspaceId,
      if (cwd != null) 'cwd': cwd,
    });
  }

  Future<List<Map<String, dynamic>>> searchSessions(String query, {int? limit}) async {
    final raw = await rpc('session/search', {
      'request': {
        'query': query,
        if (limit != null) 'limit': limit,
      },
    });
    final m = _asMap(raw);
    final items = _asList(m['items'] ?? m['results'] ?? raw);
    return items.whereType<Map>().map(_asMap).toList(growable: false);
  }

  Future<Map<String, dynamic>> patchSession(
    String sessionId, {
    String? title,
    bool? archived,
    bool? pinned,
  }) async {
    final results = <String, dynamic>{'v': 1, 'ok': true};
    if (title != null) {
      results['rename'] = await rpc('session/rename', {
        'request': {'sessionId': sessionId, 'title': title},
      });
    }
    if (pinned != null) {
      results['pin'] = await rpc(
        pinned ? 'workspace/pinSession' : 'workspace/unpinSession',
        {'request': {'sessionId': sessionId}},
      );
    }
    if (archived != null) {
      results['archive'] = await rpc(
        archived ? 'workspace/archiveSession' : 'workspace/unarchiveSession',
        {'request': {'sessionId': sessionId}},
      );
    }
    return results;
  }

  Future<Map<String, dynamic>> deleteSession(String sessionId) async {
    // Stock DSH uses archive for session removal in workspace controller; never swallow errors!
    final res = await rpc('workspace/archiveSession', {
      'request': {'sessionId': sessionId},
    });
    return {'v': 1, 'ok': true, 'archived': true, if (res != null) 'result': res};
  }

  Future<TurnsPage> getSessionTurns(
    String sessionId, {
    int limit = 40,
    String? before,
    bool withProjections = true,
  }) async {
    final beforeSeq = before != null ? int.tryParse(before) : null;
    final req = <String, dynamic>{
      'address': {'kind': 'session', 'sessionId': sessionId},
      'maxMessages': limit,
      if (beforeSeq != null)
        'beforeSeq': beforeSeq
      else if (before != null && before.isNotEmpty)
        'cursor': before,
    };
    dynamic pageRaw;
    try {
      pageRaw = await rpc('session/page', {'request': req});
    } on GbridgeException catch (e) {
      if (e.status == 404 || e.code.contains('arguments-invalid')) {
        pageRaw = await rpc('session/events', {
          'request': {
            'address': {'kind': 'session', 'sessionId': sessionId},
            if (beforeSeq != null)
              'beforeSeq': beforeSeq
            else if (before != null && before.isNotEmpty)
              'cursor': before,
          },
        });
      } else {
        rethrow;
      }
    }
    final pageMap = _asMap(pageRaw);
    final rawRecords = _asList(pageMap['records'] ?? pageMap['events'] ?? pageMap['items']);
    final normalizedJson = normalizer.normalizeEvents(sessionId, rawRecords);
    final turns = normalizedJson.map(NormalizedTurn.fromJson).toList(growable: false);

    Map<String, dynamic> projections = const {};
    if (withProjections) {
      try {
        final projRaw = await rpc('session/projections', {
          'request': {'sessionId': sessionId},
        });
        projections = _asMap(projRaw);
      } catch (_) {}
    }

    int? oldestSeq;
    if (turns.isNotEmpty && turns.first.seqStart > 0) {
      oldestSeq = turns.first.seqStart;
    } else {
      for (final rec in rawRecords) {
        if (rec is Map) {
          final ev = rec['type'] == 'event' && rec['event'] is Map ? rec['event'] as Map : rec;
          final s = ev['seq'];
          if (s is num) {
            oldestSeq = s.toInt();
            break;
          }
        }
      }
    }
    final hasMore = pageMap['hasMore'] == true;
    final cursor = pageMap['cursor']?.toString() ??
        pageMap['nextCursor']?.toString() ??
        (hasMore && oldestSeq != null ? '$oldestSeq' : null);
    return TurnsPage(
      sessionId: sessionId,
      turns: turns,
      hasMore: hasMore,
      nextCursor: cursor,
      projections: projections,
    );
  }

  Future<Map<String, dynamic>> getToolOutput(String sessionId, String callId) async {
    var cached = normalizer.getToolOutput(sessionId, callId);
    if (cached == null) {
      try {
        await getSessionTurns(sessionId, limit: 80, withProjections: false);
        cached = normalizer.getToolOutput(sessionId, callId);
      } catch (_) {}
    }
    if (cached != null) return {'v': 1, 'tool': cached, ...cached};
    return {'v': 1, 'callId': callId, 'output': null};
  }

  static Map<String, dynamic> _cleanAttachmentForWire(Map<String, dynamic> att) {
    final cleaned = <String, dynamic>{};
    for (final entry in att.entries) {
      if (entry.key == 'localBytes' ||
          entry.key == 'localPath' ||
          entry.key == 'preview' ||
          entry.key == 'bytes') {
        continue;
      }
      if (entry.value is Map) {
        cleaned[entry.key] = _cleanAttachmentForWire(Map<String, dynamic>.from(entry.value as Map));
      } else {
        cleaned[entry.key] = entry.value;
      }
    }
    return cleaned;
  }

  Future<Map<String, dynamic>> sendMessage(
    String sessionId, {
    required String text,
    String mode = 'auto',
    List<Map<String, dynamic>>? attachments,
    List<Map<String, dynamic>>? references,
    String? clientRequestId,
  }) async {
    final content = <Map<String, dynamic>>[];
    const allowedImageMimes = {'image/png', 'image/jpeg', 'image/webp', 'image/gif'};
    final attachmentNotes = <String>[];
    if (attachments != null) {
      for (final rawAtt in attachments) {
        final att = _cleanAttachmentForWire(rawAtt);
        var mime = (att['mediaType'] ?? att['mimeType'] ?? '').toString().toLowerCase();
        if (mime == 'image/jpg') mime = 'image/jpeg';
        final name = (att['name'] ?? att['filename'] ?? 'attachment').toString();
        final inlineData = att['data'] is String && (att['data'] as String).isNotEmpty
            ? att['data'] as String
            : null;
        final rawReceipt = att['receiptId']?.toString();
        final rawAttId = att['attachmentId']?.toString();
        final receiptId = (rawReceipt != null && rawReceipt.isNotEmpty)
            ? rawReceipt
            : (rawAttId != null && rawAttId.isNotEmpty && !rawAttId.startsWith('att-')
                ? rawAttId
                : null);
        if (inlineData != null && allowedImageMimes.contains(mime)) {
          content.add({
            'type': 'image',
            'mediaType': mime,
            'data': inlineData,
            'name': name,
          });
        } else if (receiptId != null) {
          content.add({
            'type': 'file',
            'receiptId': receiptId,
          });
        } else if (rawAttId != null && rawAttId.isNotEmpty) {
          content.add({'type': 'image', 'attachment': {'attachmentId': rawAttId, 'name': name}});
        } else if (name.isNotEmpty) {
          attachmentNotes.add('[附件: $name${mime.isNotEmpty ? ' ($mime)' : ''}]');
        }
      }
    }
    final refLines = <String>[];
    if (references != null && references.isNotEmpty) {
      for (final ref in references) {
        final kind = (ref['kind'] ?? ref['type'] ?? 'file').toString();
        final rawPath = (ref['path'] ?? ref['relativePath'] ?? ref['sessionId'] ?? ref['id'] ?? '').toString().trim();
        if (rawPath.isEmpty) continue;
        final cleanRef = kind == 'session' ? rawPath.replaceFirst(RegExp(r'^session:'), '') : rawPath;
        final token = kind == 'session' ? '@session:$cleanRef' : '@$cleanRef';
        if (!text.contains(token) && !text.contains('@file:$cleanRef')) {
          refLines.add(kind == 'session' ? '@session:$cleanRef' : '@file:$cleanRef');
        }
      }
    }
    final parts = <String>[
      if (refLines.isNotEmpty) refLines.join('\n'),
      if (text.isNotEmpty) text,
      if (attachmentNotes.isNotEmpty) attachmentNotes.join('\n'),
    ];
    final combinedText = parts.join('\n\n');
    if (combinedText.isNotEmpty) {
      content.add({'type': 'text', 'text': combinedText});
    }
    if (mode == 'interrupt') {
      await cancelSession(sessionId).catchError((_) => const <String, dynamic>{});
    }
    final deliveryMode = (mode == 'steer' || mode == 'interrupt') ? 'steer' : 'queue';
    final res = await rpc('session/prompt', {
      'request': {
        'requestId': clientRequestId ?? 'gb-${DateTime.now().microsecondsSinceEpoch}',
        'sessionId': sessionId,
        'mode': deliveryMode,
        'content': content,
      },
    });
    return {'v': 1, 'ok': true, 'result': res};
  }

  Future<Map<String, dynamic>> cancelSession(String sessionId) async {
    final res = await rpc('session/cancel', {
      'request': {'sessionId': sessionId},
    });
    return {'v': 1, 'ok': true, 'result': res};
  }

  Future<Map<String, dynamic>> updateQueue(String sessionId, Map<String, dynamic> body) async {
    final normalized = Map<String, dynamic>.from(body);
    final rawAction = normalized['action'];
    if (rawAction is String) {
      final kind = switch (rawAction) {
        'promote' => 'steer',
        'delete' => 'remove',
        _ => rawAction,
      };
      if (kind == 'edit') {
        final rawText = (normalized.remove('text') ?? normalized['content'])?.toString();
        final rawContent = normalized.remove('content');
        final contentList = rawContent is List
            ? rawContent
            : (rawText != null ? <Map<String, dynamic>>[{'type': 'text', 'text': rawText}] : const <dynamic>[]);
        normalized['action'] = {'kind': 'edit', 'content': contentList};
      } else {
        normalized['action'] = {'kind': kind};
      }
    }
    final res = await rpc('session/updateQueue', {
      'request': {'sessionId': sessionId, ...normalized},
    });
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> forkSession(
    String sessionId, {
    String? turnId,
    int? atSeq,
    String? title,
  }) async {
    final res = await rpc('session/fork', {
      'request': {
        'sessionId': sessionId,
        if (atSeq != null) 'atSeq': atSeq,
        if (title != null) 'title': title,
      },
    });
    return {'v': 1, 'session': res, ..._asMap(res)};
  }

  Future<Map<String, dynamic>> getSessionProjections(String sessionId) async {
    final res = await rpc('session/projections', {
      'request': {'sessionId': sessionId},
    });
    return {'v': 1, 'projections': res, ..._asMap(res)};
  }

  Future<Map<String, dynamic>> getSessionReferences(String sessionId, {String query = ''}) async {
    final res = await rpc('fileReferences/list', {
      'agentId': sessionId,
      'query': query,
    }).catchError((_) => const <dynamic>[]);
    final list = _asList(res);
    return {'v': 1, 'files': list, 'sessions': const <dynamic>[], 'items': list, 'candidates': list};
  }

  Future<Map<String, dynamic>> listCommands({String? sessionId}) async {
    if (sessionId == null || sessionId.isEmpty) return const {'v': 1, 'commands': []};
    final res = await rpc('commands/list', {'agentId': sessionId}).catchError((_) => const <dynamic>[]);
    return {'v': 1, 'commands': _asList(res)};
  }

  Future<Map<String, dynamic>> executeSlashCommand(
    String sessionId, {
    required String command,
    Map<String, dynamic>? args,
  }) async {
    final line = command.startsWith('/') ? command : '/$command';
    final res = await rpc('commands/execute', {
      'agentId': sessionId,
      'line': line,
      'submittedAttachments': const <dynamic>[],
    });
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> listSkills({String? sessionId}) async {
    if (sessionId == null || sessionId.isEmpty) return const {'v': 1, 'skills': []};
    final res = await rpc('skills/list', {
      'request': {'sessionId': sessionId},
    }).catchError((_) => const <String, dynamic>{});
    final m = _asMap(res);
    return {'v': 1, 'skills': _asList(m['skills'] ?? m['items'] ?? res)};
  }

  Future<Map<String, dynamic>> getSessionGoals(String sessionId) async {
    dynamic res;
    try {
      res = await rpc('goals/get', {'agentId': sessionId});
    } catch (_) {
      // Cold sessions reject `goals/get` with GOAL_AGENT_NOT_LIVE; read durable `values.goal` projection!
      final proj = await rpc('session/projections', {
        'request': {'sessionId': sessionId},
      }).catchError((_) => rpc('session/projections', {'sessionId': sessionId}).catchError((_) => null));
      final projMap = _asMap(proj);
      final vals = projMap['values'] is Map ? _asMap(projMap['values']) : projMap;
      res = vals['goal'];
    }
    return {'v': 1, 'goal': res, 'goals': res == null ? const [] : [res]};
  }

  Future<Map<String, dynamic>> mutateSessionGoal(
    String sessionId, {
    required String action,
    Map<String, dynamic> payload = const {},
  }) async {
    Future<Map<String, dynamic>> resolveGoalRef() async {
      final raw = payload['ref'];
      if (raw is Map && raw['id'] != null && raw['revision'] is num && (raw['revision'] as num) > 0) {
        return {'id': raw['id'].toString(), 'revision': (raw['revision'] as num).toInt()};
      }
      final current = await rpc('goals/get', {'agentId': sessionId}).catchError((_) => null);
      final cm = _asMap(current);
      final cid = cm['id']?.toString() ?? '';
      final crev = cm['revision'];
      if (cid.isNotEmpty && crev is num) {
        return {'id': cid, 'revision': crev.toInt()};
      }
      return {
        'id': (payload['goalId'] ?? payload['id'] ?? '').toString(),
        if (payload['revision'] is num) 'revision': (payload['revision'] as num).toInt(),
      };
    }

    final ep = 'goals/$action';
    Map<String, dynamic> args;
    if (action == 'create') {
      final reqMap = payload['request'] is Map ? _asMap(payload['request']) : payload;
      final rawObj = (reqMap['objective'] ?? payload['objective'] ?? payload['title'] ?? '').toString().trim();
      final rawCriteria = (payload['criteria'] ?? '').toString().trim();
      final objective = rawCriteria.isNotEmpty && !rawObj.contains(rawCriteria)
          ? '$rawObj\n验收标准：$rawCriteria'
          : rawObj;
      final maxRoundsRaw = reqMap['maxGoalRounds'] ?? payload['maxGoalRounds'];
      final maxRounds = maxRoundsRaw is num && maxRoundsRaw > 0 ? maxRoundsRaw.toInt() : null;
      args = {
        'agentId': sessionId,
        'request': {
          'objective': objective,
          if (maxRounds != null) 'maxGoalRounds': maxRounds,
        },
      };
    } else if (action == 'edit') {
      final ref = await resolveGoalRef();
      final reqMap = payload['request'] is Map ? _asMap(payload['request']) : payload;
      final nextObj = (reqMap['objective'] ?? payload['objective'] ?? payload['title'] ?? '').toString().trim();
      final rawCriteria = (payload['criteria'] ?? '').toString().trim();
      final objective = rawCriteria.isNotEmpty && nextObj.isNotEmpty && !nextObj.contains(rawCriteria)
          ? '$nextObj\n验收标准：$rawCriteria'
          : nextObj;
      final maxRoundsRaw = reqMap['maxGoalRounds'] ?? payload['maxGoalRounds'];
      final maxRounds = maxRoundsRaw is num && maxRoundsRaw > 0 ? maxRoundsRaw.toInt() : null;
      args = {
        'agentId': sessionId,
        'ref': ref,
        'request': {
          if (objective.isNotEmpty) 'objective': objective,
          if (maxRounds != null) 'maxGoalRounds': maxRounds,
        },
      };
    } else {
      final ref = await resolveGoalRef();
      args = {
        'agentId': sessionId,
        'ref': ref,
      };
    }
    final res = await rpc(ep, args);
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> listMessageFeedback(String sessionId) async {
    final res = await rpc('messageFeedback/list', {
      'request': {'sessionId': sessionId},
    }).catchError((_) => const <String, dynamic>{});
    return {'v': 1, ..._asMap(res)};
  }

  Future<Map<String, dynamic>> putMessageFeedback(
    String sessionId, {
    required String messageId,
    required String rating,
    String? comment,
    String? ifVersion,
  }) async {
    String? resolvedVersion = ifVersion;
    if (resolvedVersion == null) {
      final list = await listMessageFeedback(sessionId);
      final items = _asList(list['items'] ?? list['records']);
      for (final it in items.whereType<Map>()) {
        if (it['messageId']?.toString() == messageId && it['version'] != null) {
          resolvedVersion = it['version'].toString();
          break;
        }
      }
    }
    final res = await rpc('messageFeedback/put', {
      'request': {
        'sessionId': sessionId,
        'messageId': messageId,
        'rating': rating == 'up' ? 'positive' : (rating == 'down' ? 'negative' : rating),
        if (comment != null) 'note': comment,
        'ifVersion': resolvedVersion,
      },
    });
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> deleteMessageFeedback(
    String sessionId, {
    required String messageId,
    String? ifVersion,
  }) async {
    String? resolvedVersion = ifVersion;
    if (resolvedVersion == null) {
      final list = await listMessageFeedback(sessionId);
      final items = _asList(list['items'] ?? list['records']);
      for (final it in items.whereType<Map>()) {
        if (it['messageId']?.toString() == messageId && it['version'] != null) {
          resolvedVersion = it['version'].toString();
          break;
        }
      }
      if (resolvedVersion == null) {
        return const {'v': 1, 'absent': true};
      }
    }
    final res = await rpc('messageFeedback/delete', {
      'request': {
        'sessionId': sessionId,
        'messageId': messageId,
        'ifVersion': resolvedVersion,
      },
    });
    return {'v': 1, 'result': res};
  }

  // ---------------------------------------------------------------------------
  // Interactions (`$events/result`)
  // ---------------------------------------------------------------------------
  List<PendingInteraction> listPendingInteractions() => mux.listPendingInteractions();

  Future<Map<String, dynamic>> respondInteraction(
    String interactionId, {
    Object? decision,
    Object? answers,
    Map<String, dynamic>? outcome,
  }) async {
    final pending = mux.takePendingInteraction(interactionId);
    if (pending == null) return const {'v': 1, 'ok': false};

    if (pending.kind == 'cordis_run') {
      final d = decision?.toString().toLowerCase() ?? 'deny';
      final isAllow = d == 'allow' || d == 'approve' || d == 'allowed-once' || d == 'always';
      Map<String, dynamic> resolution;
      if (isAllow) {
        String? pluginRunId;
        final p = pending.payload;
        if (p['pluginId'] != null && p['packageId'] != null) {
          final runRes = _asMap(await rpc('dynamicCordisRunner/runHostHalf', {
            'agentId': pending.sessionId ?? p['agentId'],
            'pluginId': p['pluginId'],
            'packageId': p['packageId'],
            'mode': p['mode'] ?? 'host',
            'requestId': interactionId,
            'approveFutureVersions': d == 'always',
          }));
          pluginRunId = (runRes['pluginRunId'] ?? runRes['id'])?.toString();
        }
        resolution = pluginRunId != null && pluginRunId.isNotEmpty
            ? {'ok': true, 'pluginRunId': pluginRunId}
            : {'ok': true, 'approved': true};
      } else {
        resolution = {'ok': false, 'reason': 'rejected'};
      }
      await rpc('dynamicCordisRunner/resolveRequestRun', {
        'requestId': interactionId,
        'resolution': resolution,
      });
      mux.markInteractionResolved(interactionId);
      return {'v': 1, 'ok': true};
    }

    final clientId = pending.clientId ?? mux.eventsClientId;
    if (clientId == null || clientId.isEmpty) {
      throw const GbridgeException(
        status: 409,
        code: 'dsh/events_not_ready',
        message: 'DSH host event stream clientId unavailable',
      );
    }

    var rememberAlways = false;
    Map<String, dynamic> effectiveOutcome;
    if (outcome != null) {
      effectiveOutcome = outcome;
    } else if (pending.kind == 'user_questions') {
      final dLow = decision?.toString().trim().toLowerCase() ?? '';
      if (answers == null &&
          (dLow == 'cancel' || dLow == 'cancelled' || dLow == 'dismiss' || dLow == 'skip')) {
        effectiveOutcome = const {'kind': 'next'};
      } else {
        final rawVal = answers ?? decision;
        final qs = pending.payload['questions'] is List
            ? pending.payload['questions'] as List
            : const <dynamic>[];
        final firstQId = qs.isNotEmpty && qs.first is Map && (qs.first as Map)['id'] != null
            ? (qs.first as Map)['id'].toString()
            : 'q-0';
        Object? formattedVal = rawVal;
        if (rawVal is List) {
          final structured = rawVal.every((a) => a is Map && a['id'] is String);
          formattedVal = {
            'answers': structured
                ? rawVal
                : [
                    {'id': firstQId, 'selected': rawVal.map((e) => e.toString()).toList()},
                  ],
          };
        } else if (rawVal is String) {
          formattedVal = {
            'answers': [
              {'id': firstQId, 'selected': [rawVal], 'custom': rawVal},
            ],
          };
        } else if (rawVal is Map && !rawVal.containsKey('answers')) {
          formattedVal = {
            'answers': [
              for (final entry in rawVal.entries)
                {
                  'id': entry.key.toString(),
                  'selected': entry.value is List
                      ? (entry.value as List).map((e) => e.toString()).toList()
                      : [entry.value.toString()],
                },
            ],
          };
        }
        effectiveOutcome = {'kind': 'result', 'value': formattedVal};
      }
    } else if (pending.kind == 'approval') {
      final d = decision?.toString().toLowerCase() ?? 'deny';
      final mapped = (d == 'allow' || d == 'approve' || d == 'allowed-once' || d == 'always')
          ? 'allowed-once'
          : (d == 'cancel' || d == 'cancelled')
              ? 'cancelled'
              : 'rejected';
      rememberAlways = d == 'always';
      effectiveOutcome = {'kind': 'result', 'value': mapped};
    } else {
      effectiveOutcome = {'kind': 'result', 'value': decision ?? answers};
    }

    await rpc(r'$events/result', {
      'clientId': clientId,
      'eventId': pending.eventId,
      'outcome': effectiveOutcome,
    });
    if (rememberAlways) {
      mux.rememberSessionAlwaysAllowed(pending.sessionId, pending.payload);
    }
    mux.markInteractionResolved(interactionId);
    return {'v': 1, 'ok': true};
  }

  Future<Map<String, dynamic>> getPermissionsCatalog() async {
    final res = await _cachedRead<dynamic>(
      'permissionPresets/catalog',
      () => rpc('permissionPresets/catalog', const {}),
    ).catchError((_) => const <String, dynamic>{});
    return {'v': 1, 'catalog': res, ..._asMap(res)};
  }

  // ---------------------------------------------------------------------------
  // Workspaces, FS, Files, Diffs, Uploads
  // ---------------------------------------------------------------------------
  Future<({List<Map<String, dynamic>> workspaces, Set<String> archivedIds, Set<String> pinnedIds})>
      _readWorkspaceSnapshot() {
    return _cachedRead(
      'workspace/follow',
      () async {
        try {
          final frame = await mux.readFirstStreamItem('workspace/follow', const {});
          final m = _asMap(frame);
          final val = m['value'] is Map ? _asMap(m['value']) : m;
          final rawList = _asList(val['items'] ?? val['workspaces'] ?? m['items'] ?? frame);
          final workspaces = <Map<String, dynamic>>[];
          for (final raw in rawList) {
            if (raw is! Map) continue;
            final w = _asMap(raw);
            final id = (w['workspaceId'] ?? w['id'] ?? '').toString();
            final path = (w['path'] ?? w['rootPath'] ?? w['cwd'] ?? '').toString();
            if (id.isEmpty && path.isEmpty) continue;
            final sids = _asList(w['sessionIds']).map((e) => e.toString()).toList(growable: false);
            final leaf = path.replaceAll(RegExp(r'/+$'), '').split('/').last;
            final name = (w['title'] ?? w['name'] ?? (leaf.isNotEmpty ? leaf : id)).toString();
            workspaces.add({
              'id': id.isNotEmpty ? id : path,
              if (id.isNotEmpty) 'workspaceId': id,
              'name': name,
              'title': name,
              'path': path,
              'rootPath': path,
              'sessionIds': sids,
              'sessionCount': sids.length,
              'explicit': true,
            });
          }
          final archived = _asList(val['archivedSessionIds']).map((e) => e.toString()).toSet();
          final pinned = _asList(val['pinnedSessionIds']).map((e) => e.toString()).toSet();
          return (workspaces: workspaces, archivedIds: archived, pinnedIds: pinned);
        } catch (_) {
          return (workspaces: const <Map<String, dynamic>>[], archivedIds: const <String>{}, pinnedIds: const <String>{});
        }
      },
    );
  }

  Future<Map<String, dynamic>> listWorkspaces() async {
    final snap = await _readWorkspaceSnapshot();
    return {
      'v': 1,
      'workspaces': snap.workspaces,
      'archivedSessionIds': snap.archivedIds.toList(growable: false),
      'pinnedSessionIds': snap.pinnedIds.toList(growable: false),
    };
  }

  Future<Map<String, dynamic>> createWorkspace({required String path, String? name}) async {
    final res = await rpc('workspace/create', {
      'request': {'path': path, if (name != null && name.isNotEmpty) 'title': name},
    });
    return {'v': 1, 'workspace': res, ..._asMap(res)};
  }

  Future<Map<String, dynamic>> patchWorkspace(
    String workspaceId, {
    String? name,
    String? beforeId,
  }) async {
    dynamic res;
    if (name != null) {
      res = await rpc('workspace/rename', {
        'request': {'workspaceId': workspaceId, 'title': name},
      });
    }
    if (beforeId != null) {
      res = await rpc('workspace/insertBefore', {
        'request': {'workspaceId': workspaceId, 'beforeWorkspaceId': beforeId},
      });
    }
    return {'v': 1, 'workspace': res, ..._asMap(res)};
  }

  Future<Map<String, dynamic>> deleteWorkspace(String workspaceId) async {
    final res = await rpc('workspace/delete', {
      'request': {'workspaceId': workspaceId},
    });
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> attachSessionToWorkspace(String workspaceId, String sessionId) async {
    final res = await rpc('workspace/insertSessionBefore', {
      'request': {'workspaceId': workspaceId, 'sessionId': sessionId},
    });
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> browseFs({String? path}) async {
    final res = await rpc('directoryPicker/list', {
      if (path != null && path.isNotEmpty) 'path': path,
    });
    final m = _asMap(res);
    return {'v': 1, ...m};
  }

  Future<Map<String, dynamic>> mkdirFs({required String path, String? name}) async {
    final res = await rpc('directoryPicker/createDirectory', {
      'path': path,
      'name': name ?? 'new-folder',
    });
    return {'v': 1, 'path': res?.toString() ?? path};
  }

  Future<Map<String, dynamic>> getWorkspaceFileTree(
    String workspaceId, {
    String? path,
    String? sessionId,
  }) async {
    final res = await rpc('workspaceFiles/list', {
      'workspaceFileScopeId': (sessionId != null && sessionId.isNotEmpty) ? sessionId : workspaceId,
      'path': path ?? '',
    });
    if (res is List) {
      return {'v': 1, 'entries': res, 'files': res};
    }
    return {'v': 1, ..._asMap(res)};
  }

  Future<Map<String, dynamic>> readWorkspaceFile(
    String workspaceId,
    String path, {
    int? offset,
    int? limit,
    String? sessionId,
  }) async {
    final res = await rpc('workspaceFiles/read', {
      'workspaceFileScopeId': sessionId ?? workspaceId,
      'path': path,
      'range': {
        'offset': offset ?? 1,
        'limit': limit ?? 400,
      },
      'options': const <String, dynamic>{},
    });
    return {'v': 1, 'file': res, ..._asMap(res)};
  }

  Future<Uint8List> readWorkspaceFileBytes(
    String workspaceId,
    String path, {
    String? sessionId,
  }) async {
    final scopeId = (sessionId != null && sessionId.isNotEmpty)
        ? sessionId
        : (workspaceId.isNotEmpty && !workspaceId.startsWith('/') ? workspaceId : null);
    if (scopeId != null) {
      try {
        final raw = await rpc('workspaceFiles/readBytes', {
          'workspaceFileScopeId': scopeId,
          'path': path,
          'options': const <String, dynamic>{},
        });
        if (raw is Uint8List) return raw;
        if (raw is List) return Uint8List.fromList(raw.whereType<int>().toList(growable: false));
        final m = _asMap(raw);
        final data = m['data'] ?? m['bytes'] ?? m['base64'];
        if (data is Uint8List) return data;
        if (data is List) return Uint8List.fromList(data.whereType<int>().toList(growable: false));
        if (data is String && data.isNotEmpty) {
          return base64Decode(data);
        }
      } catch (_) {}
    }
    var resolvedPath = path;
    if (!path.startsWith('/') && workspaceId.startsWith('/')) {
      final base = workspaceId.endsWith('/') ? workspaceId.substring(0, workspaceId.length - 1) : workspaceId;
      resolvedPath = '$base/$path';
    }
    return transport.requestBytes('GET', '/api/file', query: {'path': resolvedPath});
  }

  Future<Map<String, dynamic>> getWorkspaceFileChanges(
    String workspaceId, {
    String? sessionId,
    String? scope,
  }) async {
    final validScope = const {'uncommitted', 'unstaged', 'staged'}.contains(scope)
        ? scope!
        : 'uncommitted';
    if (sessionId != null && sessionId.isNotEmpty) {
      try {
        final diff = await rpc('forgePanel/localDiff', {
          'sessionId': sessionId,
          'scope': {'kind': validScope},
        });
        final m = _asMap(diff);
        if (m['files'] is List) {
          return {'v': 1, 'changes': m, ...m};
        }
      } catch (_) {}
    }
    return const {'v': 1, 'files': []};
  }

  Future<Uint8List> uploadBinary(
    Uint8List bytes, {
    required String filename,
    String? sessionId,
    String contentType = 'application/octet-stream',
  }) async {
    const inlineImageMimes = {'image/png', 'image/jpeg', 'image/webp', 'image/gif'};
    final normMime = contentType.toLowerCase() == 'image/jpg' ? 'image/jpeg' : contentType.toLowerCase();
    final isUploadableImage = inlineImageMimes.contains(normMime);
    return transport.requestBytes(
      'POST',
      '/api/session/uploadFileBinary',
      query: {
        if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
        'name': filename,
        // Stock DSH routes requests WITH `mediaType` exclusively to `uploadImageStream()` (which expects PNG/JPEG/WebP/GIF).
        if (isUploadableImage) 'mediaType': normMime,
      },
      bodyBytes: bytes,
      contentType: 'application/octet-stream',
    );
  }

  // ---------------------------------------------------------------------------
  // Terminals
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>> listTerminals({String? sessionId}) async {
    if (sessionId == null || sessionId.isEmpty) return const {'v': 1, 'terminals': []};
    final res = await rpc('terminal/list', {'sessionId': sessionId}).catchError((_) => const <dynamic>[]);
    return {'v': 1, 'terminals': _asList(res)};
  }

  Future<Map<String, dynamic>> createTerminal({
    String? cwd,
    String? shell,
    String? sessionId,
    int? cols,
    int? rows,
  }) async {
    String? agentId = (sessionId != null && sessionId.isNotEmpty) ? sessionId : null;
    if (agentId == null) {
      final sessions = await listSessions().catchError((_) => const <SessionSummary>[]);
      if (sessions.isNotEmpty) agentId = sessions.first.id;
    }
    if (agentId == null || agentId.isEmpty) {
      throw const GbridgeException(
        status: 400,
        code: 'gbridge/validation_error',
        message: 'sessionId is required to create a terminal when no session exists',
      );
    }
    final id = 'term-${DateTime.now().millisecondsSinceEpoch}';
    final res = await rpc('terminal/create', {
      'agentId': agentId,
      'request': {
        'id': id,
        'cols': cols ?? 80,
        'rows': rows ?? 24,
        if (shell != null && shell.isNotEmpty) 'shellPath': shell,
      },
    });
    final m = _asMap(res);
    return {
      'v': 1,
      'terminal': {
        ...m,
        'id': m['id'] ?? id,
        'agentId': agentId,
        'sessionId': agentId,
      },
      'id': m['id'] ?? id,
    };
  }

  Future<Map<String, dynamic>> closeTerminal(String terminalId, {String? sessionId}) async {
    await rpc('terminal/close', {
      if (sessionId != null && sessionId.isNotEmpty) 'agentId': sessionId,
      'id': terminalId,
    });
    return const {'v': 1, 'ok': true};
  }

  Future<Map<String, dynamic>> patchTerminal(
    String terminalId, {
    String? sessionId,
    String? title,
    int? cols,
    int? rows,
    bool? retain,
  }) async {
    final hasSid = sessionId != null && sessionId.isNotEmpty;
    if (title != null && title.isNotEmpty) {
      await rpc('terminal/rename', {
        if (hasSid) 'agentId': sessionId,
        'id': terminalId,
        'title': title,
      }).catchError((_) => null);
    }
    if (cols != null && rows != null && cols > 0 && rows > 0) {
      await rpc('terminal/resize', {
        if (hasSid) 'agentId': sessionId,
        'id': terminalId,
        'terminalId': terminalId,
        'cols': cols,
        'rows': rows,
      }).catchError((_) => null);
    }
    return const {'v': 1, 'ok': true};
  }

  Future<Map<String, dynamic>> listTerminalShells({String? sessionId}) async {
    if (sessionId == null || sessionId.isEmpty) return const {'v': 1, 'shells': []};
    final res = await rpc('terminal/shells', {'agentId': sessionId}).catchError((_) => const <dynamic>[]);
    return {'v': 1, 'shells': _asList(res)};
  }

  // ---------------------------------------------------------------------------
  // Models, Providers, Presets, Settings, Credentials, Account
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>> getModels({String? sessionId}) async {
    final results = await Future.wait<dynamic>([
      rpc('session/modelCatalog', const {}),
      _cachedRead<dynamic>('llm/listProviders', () => rpc('llm/listProviders', const {}))
          .catchError((_) => const <dynamic>[]),
      _cachedRead<dynamic>(
        'llm/listConfigurableProviders',
        () => rpc('llm/listConfigurableProviders', const {}),
      ).catchError((_) => const <dynamic>[]),
    ]);
    return {
      'v': 1,
      'catalog': results[0],
      'providers': _asList(results[1]),
      'configurable': _asList(results[2]),
    };
  }

  Future<Map<String, dynamic>> selectModel(String sessionId, Map<String, dynamic> body) async {
    final res = await rpc('session/selectModel', {
      'request': {'sessionId': sessionId, ...body},
    });
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> listProviders() async {
    final results = await Future.wait<dynamic>([
      _cachedRead<dynamic>('llm/listProviders', () => rpc('llm/listProviders', const {}))
          .catchError((_) => const <dynamic>[]),
      _cachedRead<dynamic>(
        'llm/listConfigurableProviders',
        () => rpc('llm/listConfigurableProviders', const {}),
      ).catchError((_) => const <dynamic>[]),
    ]);
    return {
      'v': 1,
      'providers': _asList(results[0]),
      'configurable': _asList(results[1]),
    };
  }

  Future<Map<String, dynamic>> discoverProviderModels(Map<String, dynamic> body) async {
    final settingsNs = (body['settingsNs'] ?? body['ns'] ?? 'llm-pi-ai').toString();
    final req = body['request'] is Map
        ? _asMap(body['request'])
        : <String, dynamic>{
            for (final k in const ['provider', 'baseURL', 'api', 'apiKey', 'apiKeyEnv'])
              if (body[k] != null && body[k].toString().isNotEmpty) k: body[k],
          };
    final res = await rpc('llm/discoverModels', {
      'settingsNs': settingsNs,
      'request': req,
    });
    return {'v': 1, 'models': _asList(res)};
  }

  Future<Map<String, dynamic>> listPresets() async {
    final res = await _cachedRead<dynamic>(
      'agentPresets/list',
      () => rpc('agentPresets/list', const {}),
    ).catchError((_) => const <dynamic>[]);
    return {'v': 1, 'presets': res};
  }

  Future<Map<String, dynamic>> selectPreset(Map<String, dynamic> body) async {
    final presetId = (body['agentPreset'] ?? body['presetId'] ?? body['id'] ?? '').toString().trim();
    final sid = (body['agentId'] ?? body['sessionId'] ?? '').toString().trim();
    if (sid.isEmpty) {
      final res = await patchSettings({
        'ns': 'agent-preset-registry',
        'patch': {'selectedDefault': presetId},
      });
      return {'v': 1, 'scope': 'global', 'result': res};
    }
    try {
      final res = await rpc('agentPresets/select', {
        'agentId': sid,
        'agentPreset': presetId,
      });
      return {'v': 1, 'scope': 'session', 'result': res};
    } on GbridgeException catch (e) {
      if (e.code.contains('locked') || e.message.toLowerCase().contains('locked')) {
        final res = await patchSettings({
          'ns': 'agent-preset-registry',
          'patch': {'selectedDefault': presetId},
        });
        return {'v': 1, 'scope': 'global', 'lockedSession': true, 'result': res};
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> getSettingsSchema({bool forceFresh = false}) async {
    if (forceFresh) {
      _invalidateCacheKey('settings/describe');
      final gen = _cacheGen['settings/describe'] ?? 0;
      final desc = await rpc('settings/describe', const {});
      if ((_cacheGen['settings/describe'] ?? 0) == gen) {
        _readCache['settings/describe'] = (
          expiresAt: DateTime.now().add(_microCacheTtl),
          value: desc,
        );
      }
      return {'v': 1, 'description': desc};
    }
    final desc = await _cachedRead<dynamic>(
      'settings/describe',
      () => rpc('settings/describe', const {}),
    );
    return {'v': 1, 'description': desc};
  }

  Future<Map<String, dynamic>> getSettingsManifest() async {
    final results = await Future.wait<dynamic>([
      _cachedRead<dynamic>('settings/describe', () => rpc('settings/describe', const {}))
          .catchError((_) => null),
      rpc('web/listProviders', const {}).catchError((_) => null),
      _cachedRead<dynamic>('agentPresets/list', () => rpc('agentPresets/list', const {}))
          .catchError((_) => null),
      _cachedRead<dynamic>(
        'permissionPresets/catalog',
        () => rpc('permissionPresets/catalog', const {}),
      ).catchError((_) => null),
    ]);
    final desc = _asMap(results[0]);
    final namespaces = _asList(desc['namespaces']);
    final nsSet = <String>{
      for (final n in namespaces)
        if (n is Map && n['ns'] != null) n['ns'].toString(),
    };
    const generalKnown = [
      'ui-chat', 'ui-conversation', 'ui-theme', 'locale',
      'session-log-deepseek', 'permission', 'agent-preset-registry', 'ui-settings-account',
    ];
    const modelKnown = ['agent-default-model', 'llm-deepseek', 'llm-deepseek-account', 'llm-pi-ai'];
    const webKnown = ['web', 'web-deepseek-api', 'web-search-deepseek'];
    const agentKnown = ['subagent', 'subagent-model-selection-settings', 'agent-loop', 'bash-sandbox'];
    const mcpKnown = ['mcp-manager'];
    const knownAll = {...generalKnown, ...modelKnown, ...webKnown, ...agentKnown, ...mcpKnown, 'ui-settings', 'ui-settings-general'};

    final sections = <Map<String, dynamic>>[
      {
        'id': 'account',
        'group': 'dsh',
        'title': '账号与余额',
        'subtitle': 'DeepSeek 官方登录、额度与 API 凭据',
        'icon': 'person',
        'order': 10,
        'namespaces': [if (nsSet.contains('ui-settings-account')) 'ui-settings-account'],
      },
      {
        'id': 'general',
        'group': 'dsh',
        'title': '通用与对话',
        'subtitle': '对话展示密度、权限预设、角色与日志设置',
        'icon': 'chat',
        'order': 20,
        'namespaces': generalKnown.where(nsSet.contains).toList(),
      },
      {
        'id': 'models',
        'group': 'dsh',
        'title': '模型与渠道',
        'subtitle': '默认模型、推理深度、官方与自定义渠道配置',
        'icon': 'sparkles',
        'order': 30,
        'namespaces': [
          ...modelKnown.where(nsSet.contains),
          ...nsSet.where((n) => !knownAll.contains(n) && n.startsWith('llm-')),
        ],
      },
      if (webKnown.any(nsSet.contains) || results[1] != null)
        {
          'id': 'web-search',
          'group': 'dsh-capabilities',
          'title': '联网搜索与抓取',
          'subtitle': '搜索与网页抓取提供方设置',
          'icon': 'globe',
          'order': 40,
          'namespaces': [
            ...webKnown.where(nsSet.contains),
            ...nsSet.where((n) => !knownAll.contains(n) && n.startsWith('web-')),
          ],
        },
      if (agentKnown.any(nsSet.contains))
        {
          'id': 'agent-runtime',
          'group': 'dsh-capabilities',
          'title': '代理与沙箱运行',
          'subtitle': '子代理、执行循环与命令沙箱',
          'icon': 'cpu',
          'order': 50,
          'namespaces': agentKnown.where(nsSet.contains).toList(),
        },
      if (mcpKnown.any(nsSet.contains))
        {
          'id': 'mcp',
          'group': 'dsh-capabilities',
          'title': 'MCP 工具服务',
          'subtitle': '外部工具服务探测与管理',
          'icon': 'link',
          'order': 60,
          'namespaces': mcpKnown.where(nsSet.contains).toList(),
        },
    ];
    final extraNs = nsSet
        .where((n) => !knownAll.contains(n) && !n.startsWith('llm-') && !n.startsWith('web-'))
        .toList();
    if (extraNs.isNotEmpty) {
      sections.add({
        'id': 'plugins',
        'group': 'dsh-extensions',
        'title': '插件与扩展',
        'subtitle': '远程主机已加载扩展的动态参数',
        'icon': 'puzzle',
        'order': 70,
        'namespaces': extraNs,
      });
    }

    final webProv = _asMap(results[1]);
    final perms = _asMap(results[3]);
    final rawPresets = results[2] is List ? results[2] as List : _asList(_asMap(results[2])['presets']);

    final searchOpts = _normalizeWebOptions(_asList(webProv['search']));
    final fetchOpts = _normalizeWebOptions(_asList(webProv['fetch']));
    final permOpts = _asList(perms['options'])
        .whereType<Map>()
        .map((o) => {'value': '${o['value'] ?? ''}', 'label': '${o['name'] ?? o['value'] ?? ''}'})
        .where((o) => (o['value'] ?? '').isNotEmpty)
        .toList();
    final presetOpts = rawPresets
        .whereType<Map>()
        .map((p) => {
              'value': '${p['id'] ?? ''}',
              'label': '${p['title'] ?? p['name'] ?? p['id'] ?? ''}',
              'description': '${p['description'] ?? ''}',
            })
        .where((o) => (o['value'] ?? '').isNotEmpty)
        .toList();

    return {
      'v': 1,
      'sections': sections,
      'dynamicOptions': {
        'web.searchProvider': searchOpts,
        'web.fetchProvider': fetchOpts,
        'permission.defaultPreset': permOpts,
        'agent-preset-registry.selectedDefault': presetOpts,
        'searchProviders': searchOpts,
        'fetchProviders': fetchOpts,
        'permissionPresets': permOpts,
        'agentPresets': presetOpts,
      },
    };
  }

  static List<Map<String, String>> _normalizeWebOptions(List<dynamic> list) {
    return list
        .whereType<Map>()
        .map((p) {
          final id = (p['id'] ?? p['name'] ?? '').toString();
          final rawTitle = p['title'] ?? p['name'];
          final title = rawTitle is Map
              ? (rawTitle['zh'] ?? rawTitle['zh-CN'] ?? rawTitle['en'] ?? id).toString()
              : (rawTitle?.toString() ?? id);
          final rawDesc = p['description'];
          final desc = rawDesc is Map
              ? (rawDesc['zh'] ?? rawDesc['zh-CN'] ?? rawDesc['en'] ?? '').toString()
              : (rawDesc?.toString() ?? '');
          return {'value': id, 'label': title, 'description': desc};
        })
        .where((m) => (m['value'] ?? '').isNotEmpty)
        .toList();
  }

  Future<Map<String, dynamic>> patchSettings(Map<String, dynamic> patch) async {
    final ns = patch['ns']?.toString();
    if (ns != null && ns.isNotEmpty) {
      Future<Map<String, dynamic>> runOnce(Object? expectedRev) async {
        if (patch['section'] is Map) {
          final res = await rpc('settings/replace', {
            'ns': ns,
            'section': _asMap(patch['section']),
            if (expectedRev != null) 'expectedRevision': expectedRev,
          });
          return {'v': 1, 'result': res};
        }
        if (patch['ops'] is List) {
          final res = await rpc('settings/mutate', {
            'ns': ns,
            'ops': patch['ops'],
            if (expectedRev != null) 'expectedRevision': expectedRev,
          });
          return {'v': 1, 'result': res};
        }
        final res = await rpc('settings/update', {
          'ns': ns,
          'patch': _asMap(patch['patch'] ?? patch['value']),
          if (expectedRev != null) 'expectedRevision': expectedRev,
        });
        return {'v': 1, 'result': res};
      }

      try {
        return await runOnce(patch['expectedRevision']);
      } on GbridgeException catch (e) {
        final isConflict = e.status == 409 ||
            e.code.contains('conflict') ||
            e.message.toLowerCase().contains('changed since it was read');
        // Never silently clobber full-section `settings/replace` 409 conflicts with a stale payload;
        // only auto-retry partial `settings/mutate` and `settings/update` operations.
        if (!isConflict || patch['expectedRevision'] == null || patch['section'] is Map) rethrow;
        _invalidateCacheKey('settings/describe');
        int? latestRev;
        try {
          final desc = _asMap(await rpc('settings/describe', const {}));
          for (final item in _asList(desc['namespaces'])) {
            if (item is Map && item['ns']?.toString() == ns && item['revision'] is num) {
              latestRev = (item['revision'] as num).toInt();
              break;
            }
          }
        } catch (_) {}
        return await runOnce(latestRev);
      }
    }
    // Flat `{ namespace: patchMap }` map.
    final results = <String, dynamic>{};
    for (final entry in patch.entries) {
      if (entry.value is Map) {
        results[entry.key] = await rpc('settings/update', {
          'ns': entry.key,
          'patch': _asMap(entry.value),
        });
      }
    }
    return {'v': 1, 'results': results};
  }

  Future<Map<String, dynamic>> getCredentials({List<String>? refs}) async {
    final refSet = <String>{
      'DEEPSEEK_API_KEY',
      'OPENAI_API_KEY',
      'ANTHROPIC_API_KEY',
      'GEMINI_API_KEY',
      'OPENROUTER_API_KEY',
      'GOOGLE_API_KEY',
      if (refs != null) ...refs,
    };
    final validRe = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
    try {
      final desc = _asMap(
        await _cachedRead<dynamic>(
          'settings/describe',
          () => rpc('settings/describe', const {}),
        ),
      );
      for (final ns in _asList(desc['namespaces'])) {
        if (ns is! Map) continue;
        for (final sec in _asList(ns['secrets'])) {
          final r = sec is String ? sec : (sec is Map ? (sec['ref'] ?? sec['name'])?.toString() : null);
          if (r != null && validRe.hasMatch(r.trim())) refSet.add(r.trim());
        }
        final val = ns['value'];
        if (ns['ns'] == 'llm-pi-ai' && val is Map && val['providers'] is Map) {
          for (final cfg in (val['providers'] as Map).values) {
            final r = cfg is Map ? cfg['apiKeyEnv']?.toString().trim() : null;
            if (r != null && validRe.hasMatch(r)) refSet.add(r);
          }
        }
      }
    } catch (_) {}
    final allRefs = refSet.where(validRe.hasMatch).toList();
    if (allRefs.length <= 64) {
      final creds = await rpc('credentials/describe', {'refs': allRefs});
      return {'v': 1, 'credentials': creds};
    }
    final merged = <String, dynamic>{};
    for (var i = 0; i < allRefs.length; i += 64) {
      final chunk = allRefs.sublist(i, (i + 64) > allRefs.length ? allRefs.length : (i + 64));
      final batch = await rpc('credentials/describe', {'refs': chunk});
      if (batch is Map) {
        final entries = batch['entries'] ?? batch['credentials'] ?? batch['items'];
        if (entries is List) {
          for (final item in entries.whereType<Map>()) {
            final k = (item['ref'] ?? item['name'] ?? item['key'])?.toString();
            if (k != null && k.isNotEmpty) merged[k] = _asMap(item);
          }
        } else {
          for (final e in batch.entries) {
            if (e.key != 'v') merged[e.key.toString()] = e.value;
          }
        }
      } else if (batch is List) {
        for (final item in batch.whereType<Map>()) {
          final k = (item['ref'] ?? item['name'] ?? item['key'])?.toString();
          if (k != null && k.isNotEmpty) merged[k] = _asMap(item);
        }
      }
    }
    return {'v': 1, 'credentials': merged};
  }

  Future<Map<String, dynamic>> setCredential(Map<String, dynamic> body) async {
    final res = await rpc('credentials/set', {
      'ref': (body['ref'] ?? body['name'] ?? '').toString(),
      'value': (body['value'] ?? '').toString(),
    });
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> unsetCredential(Map<String, dynamic> body) async {
    final res = await rpc('credentials/unset', {
      'ref': (body['ref'] ?? body['name'] ?? '').toString(),
    });
    return {'v': 1, 'result': res};
  }

  static Map<String, dynamic> _accountClientMeta([Map<String, dynamic>? input]) => {
        'version': (input?['version'] ?? '0.1.0').toString(),
        'locale': (input?['locale'] ?? 'zh-CN').toString(),
        'timezoneOffsetSeconds': input?['timezoneOffsetSeconds'] ??
            DateTime.now().timeZoneOffset.inSeconds,
      };

  Future<Map<String, dynamic>> getAccount() async {
    final meta = _accountClientMeta();
    final results = await Future.wait<dynamic>([
      rpc('account/getState', const {}).catchError((_) => null),
      rpc('account/getProfile', {'client': meta}).catchError((_) => null),
      rpc('account/getBalance', {'client': meta}).catchError((_) => null),
    ]);
    return {
      'v': 1,
      'state': results[0],
      'profile': results[1],
      'balance': results[2],
    };
  }

  Future<Map<String, dynamic>> accountAction(String action, [Map<String, dynamic> body = const {}]) async {
    final meta = _accountClientMeta(body['client'] is Map ? _asMap(body['client']) : null);
    Map<String, dynamic> payload;
    if (action == 'cancelSignIn') {
      payload = {'attemptId': body['attemptId']};
    } else if (action == 'startSignIn') {
      final base = transport.endpoint.baseUri;
      final isLoopback = base != null &&
          (base.host == '127.0.0.1' || base.host == 'localhost' || base.host == '::1');
      final port = base != null && base.hasPort ? base.port : 3080;
      // DSH's dsh-deepseek-account strictly requires an HTTP loopback callbackOrigin.
      final defaultOrigin = isLoopback
          ? 'http://${base.host == '::1' ? '[::1]' : base.host}:$port'
          : 'http://127.0.0.1:$port';
      payload = {
        'client': meta,
        'callbackOrigin': body['callbackOrigin']?.toString() ?? defaultOrigin,
        'loginSource': body['loginSource'] == 'desktop' ? 'desktop' : 'web',
      };
    } else {
      payload = {'client': meta};
    }
    final res = await rpc('account/$action', payload);
    if (action == 'startSignIn') {
      var resMap = _asMap(res);
      var authorizeUrl = resMap['authorizeUrl']?.toString();
      if (authorizeUrl == null || authorizeUrl.isEmpty) {
        // Poll account/getState briefly until authorizeUrl is ready (mirrors dsh-gbridge system.js).
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 220));
          final st = _asMap(await rpc('account/getState', const {}).catchError((_) => null));
          final pending = _asMap(st['attempt'] ?? st['pendingSignIn'] ?? st['signIn'] ?? st);
          final phase = pending['phase']?.toString().toLowerCase() ?? '';
          final url = pending['authorizeUrl']?.toString();
          if (url != null && url.isNotEmpty) {
            authorizeUrl = url;
            resMap = {...resMap, ...pending, 'authorizeUrl': url};
            break;
          }
          if (phase == 'failed' || phase == 'error' || phase == 'cancelled' || phase == 'expired') {
            resMap = {...resMap, ...pending};
            break;
          }
        }
      }
      return {'v': 1, 'result': resMap.isEmpty ? res : resMap};
    }
    return {'v': 1, 'result': res};
  }

  // ---------------------------------------------------------------------------
  // Plugins, MCP, Jobs, Schedules, Subagents
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>> listPluginBundles() async {
    final res = await rpc('pluginManager/listBundles', const {}).catchError((_) => const <dynamic>[]);
    return {'v': 1, 'bundles': _asList(res)};
  }

  Future<Map<String, dynamic>> listPluginEntries() async {
    final res = await rpc('pluginManager/listPlugins', const {}).catchError((_) => const <dynamic>[]);
    return {'v': 1, 'entries': _asList(res)};
  }

  Future<Map<String, dynamic>> listPluginInventory() async {
    final res = await rpc('pluginInventory/list', const {}).catchError((_) => const <String, dynamic>{});
    return {'v': 1, 'inventory': res};
  }

  Future<Map<String, dynamic>> listPluginRegistries() async {
    final res = await rpc('pluginManager/registries', const {}).catchError((_) => const <String, dynamic>{});
    return {'v': 1, 'registries': res};
  }

  Future<Map<String, dynamic>> inspectPlugin(Map<String, dynamic> body) async {
    final res = await rpc('pluginManager/inspect', body);
    return {'v': 1, 'inspection': res};
  }

  Future<Map<String, dynamic>> installPlugin(Map<String, dynamic> body) async {
    final res = await rpc('pluginManager/installBundle', body);
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> cancelPluginInstall(String requestId) async {
    final res = await rpc('pluginManager/cancelInstall', {'requestId': requestId});
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> setPluginBundleEnabled(String name, bool enabled) async {
    final res = await rpc('pluginManager/setBundleEnabled', {'name': name, 'enabled': enabled});
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> setPluginEntryEnabled(String id, bool enabled) async {
    final res = await rpc('pluginManager/setPluginEnabled', {'id': id, 'enabled': enabled});
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> removePluginBundle(String name) async {
    final res = await rpc('pluginManager/removeBundle', {'name': name});
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> updatePluginBundle(String name, {String version = 'latest'}) async {
    var targetVersion = version;
    if (targetVersion == 'latest' || targetVersion.isEmpty) {
      try {
        final versions = _asList(await rpc('pluginManager/listVersions', {'name': name}));
        for (final v in versions) {
          final vs = v is String ? v : (v is Map ? v['version']?.toString() : null);
          if (vs != null && vs.isNotEmpty) {
            targetVersion = vs;
            break;
          }
        }
      } catch (_) {}
    }
    final res = await rpc('pluginManager/updateBundle', {'name': name, 'version': targetVersion});
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> listMcpServers() async {
    try {
      final res = await mux.readFirstStreamItem('mcpManager/watch', const {});
      return {'v': 1, 'servers': _asList(res)};
    } catch (_) {
      return const {'v': 1, 'servers': []};
    }
  }

  Future<Map<String, dynamic>> mcpAction(String name, String action) async {
    final res = await rpc('mcpManager/$action', {'name': name});
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> listWebProviders() async {
    final res = await rpc('web/listProviders', const {}).catchError((_) => const <String, dynamic>{});
    return {'v': 1, 'providers': res};
  }

  Future<Map<String, dynamic>> listJobs({String? sessionId}) async {
    try {
      final res = await mux.readFirstStreamItem('job/list', {
        'request': {if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId},
      });
      final m = _asMap(res);
      return {'v': 1, 'jobs': _asList(m['jobs'] ?? m['items'] ?? res)};
    } catch (_) {
      return const {'v': 1, 'jobs': []};
    }
  }

  Future<Map<String, dynamic>> killJob(String jobId, {String? sessionId}) async {
    final res = await rpc('job/kill', {
      'request': {
        'jobId': jobId,
        if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
      },
    });
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> listSchedules() async {
    final res = await rpc('schedule/catalog', const {}).catchError(
      (_) => rpc('schedule/list', const {'request': <String, dynamic>{}}).catchError((_) => const <dynamic>[]),
    );
    final list = res is List ? res : _asList(_asMap(res)['items'] ?? _asMap(res)['schedules']);
    return {'v': 1, 'schedules': list};
  }

  Map<String, dynamic>? _resolveScheduleTiming(Map<String, dynamic> body) {
    if (body['timing'] is Map) {
      return Map<String, dynamic>.from(body['timing'] as Map);
    }
    final tz = (body['timeZone'] ?? body['timezone'] ?? 'Asia/Shanghai').toString().trim();
    final effectiveTz = tz.isEmpty ? 'Asia/Shanghai' : tz;
    final everySec = body['everySeconds'] ?? body['every_seconds'];
    if (everySec is num && everySec > 0) {
      final clamped = everySec.toInt() < 60 ? 60 : everySec.toInt();
      return {'kind': 'every', 'every_seconds': clamped};
    }
    final afterSec = body['afterSeconds'] ?? body['after_seconds'];
    if (afterSec is num && afterSec > 0) {
      final clamped = afterSec.toInt() < 10 ? 10 : afterSec.toInt();
      return {'kind': 'after', 'after_seconds': clamped};
    }
    final dailyTime = body['dailyTime']?.toString().trim();
    if (dailyTime != null && dailyTime.isNotEmpty) {
      return {
        'kind': 'daily',
        'daily': {'time': dailyTime, 'time_zone': effectiveTz},
      };
    }
    final cron = (body['cronExpr'] ?? body['cron'] ?? body['expression'])?.toString().trim();
    if (cron != null && cron.isNotEmpty) {
      return {
        'kind': 'cron',
        'cron': {'expression': cron, 'time_zone': effectiveTz},
      };
    }
    return null;
  }

  Map<String, dynamic> _resolveScheduleTarget(Map<String, dynamic> body) {
    if (body['target'] is Map) {
      return Map<String, dynamic>.from(body['target'] as Map);
    }
    final sid = body['sessionId']?.toString().trim();
    if (sid != null && sid.isNotEmpty) {
      return {'kind': 'session', 'sessionId': sid};
    }
    final cwd = body['cwd']?.toString().trim();
    return {
      'kind': 'new_once',
      'create': {
        if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
      },
    };
  }

  Future<Map<String, dynamic>> createSchedule(Map<String, dynamic> body) async {
    final title = (body['title'] ?? body['name'] ?? '').toString().trim();
    final prompt = (body['prompt'] ?? body['command'] ?? '').toString().trim();
    final timing = _resolveScheduleTiming(body);
    final req = <String, dynamic>{
      'title': title.length > 120 ? title.substring(0, 120) : title,
      'prompt': prompt,
      if (timing != null) 'timing': timing,
      'target': _resolveScheduleTarget(body),
    };
    final res = await rpc('schedule/create', {'request': req});
    return {'v': 1, 'schedule': res, ..._asMap(res)};
  }

  Future<Map<String, dynamic>> patchSchedule(String scheduleId, Map<String, dynamic> body) async {
    if (body['action'] == 'delete') {
      final res = await rpc('schedule/edit', {
        'request': {'id': scheduleId, 'action': 'delete'},
      });
      return {'v': 1, 'result': res};
    }
    final src = body['patch'] is Map ? _asMap(body['patch']) : body;
    final patch = <String, dynamic>{};
    final title = (src['title'] ?? src['name'])?.toString().trim();
    if (title != null && title.isNotEmpty) {
      patch['title'] = title.length > 120 ? title.substring(0, 120) : title;
    }
    final prompt = (src['prompt'] ?? src['command'])?.toString().trim();
    if (prompt != null && prompt.isNotEmpty) {
      patch['prompt'] = prompt;
    }
    final timing = _resolveScheduleTiming(src);
    if (timing != null) {
      patch['timing'] = timing;
    }
    if (src['target'] is Map) {
      patch['target'] = Map<String, dynamic>.from(src['target'] as Map);
    }
    if (src.containsKey('active') && src['active'] is bool) {
      patch['active'] = src['active'];
    } else if (src.containsKey('enabled') && src['enabled'] is bool) {
      patch['active'] = src['enabled'];
    }
    final res = await rpc('schedule/edit', {
      'request': {
        'id': scheduleId,
        'action': 'update',
        'patch': patch,
      },
    });
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> deleteSchedule(String scheduleId) async {
    try {
      final res = await rpc('schedule/delete', {
        'request': {'id': scheduleId},
      });
      return {'v': 1, 'ok': true, 'result': res};
    } catch (_) {
      final res = await rpc('schedule/edit', {
        'request': {'id': scheduleId, 'action': 'delete'},
      });
      return {'v': 1, 'ok': true, 'result': res};
    }
  }

  Future<Map<String, dynamic>> runScheduleNow(String scheduleId) async {
    final res = await rpc('schedule/run', {
      'request': {'id': scheduleId},
    });
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> getScheduleHistory(String scheduleId, {int limit = 20}) async {
    final res = await rpc('schedule/history', {
      'request': {'id': scheduleId, 'limit': limit},
    });
    return {'v': 1, 'history': res};
  }

  Future<Map<String, dynamic>> pruneInactiveSchedules() async {
    final res = await rpc('schedule/deleteInactive', const {});
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> promptSubagent(
    String subagentId, {
    required String text,
    String? parentSessionId,
    String delivery = 'steer',
  }) async {
    final res = await rpc('subagents/prompt', {
      'request': {
        'requestId': 'gb-sub-${DateTime.now().microsecondsSinceEpoch}',
        'childSessionId': subagentId,
        'content': [
          {'type': 'text', 'text': text},
        ],
        'delivery': delivery,
        if (parentSessionId != null) 'parentSessionId': parentSessionId,
      },
    });
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> interruptSubagent(String subagentId, {String? parentSessionId}) async {
    final res = await rpc('subagents/interruptByUser', {
      'childSessionId': subagentId,
      if (parentSessionId != null && parentSessionId.isNotEmpty) 'parentSessionId': parentSessionId,
    });
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> setTeamMode(String sessionId, bool enabled) async {
    final res = await rpc('agentTeams/setEnabled', {'agentId': sessionId, 'enabled': enabled});
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> listDynamicCordis() async {
    final res = await rpc('dynamicCordisRunner/inventory', const {}).catchError((_) => const <dynamic>[]);
    return {'v': 1, 'inventory': _asList(res)};
  }

  Future<Map<String, dynamic>> dynamicCordisAction(String id, String action, {String? agentId}) async {
    final ep = action == 'stop'
        ? 'dynamicCordisRunner/stopFromPanel'
        : 'dynamicCordisRunner/undefineFromPanel';
    final res = await rpc(ep, {'pluginId': id, if (agentId != null) 'agentId': agentId});
    return {'v': 1, 'result': res};
  }

  Future<Map<String, dynamic>> exportSessionMarkdown(String sessionId) async {
    final page = await getSessionTurns(sessionId, limit: 200, withProjections: false);
    final buf = StringBuffer('# Session $sessionId\n\n');
    for (final turn in page.turns) {
      if (turn.userMessage != null && turn.userMessage!.text.isNotEmpty) {
        buf.writeln('## User\n\n${turn.userMessage!.text}\n');
      }
      if (turn.assistantText.isNotEmpty) {
        buf.writeln('## Assistant\n\n${turn.assistantText}\n');
      }
    }
    return {'v': 1, 'markdown': buf.toString()};
  }

  Future<Uint8List> downloadAttachment(String attachmentId, {String? sessionId}) async {
    var attachmentObj = <String, dynamic>{'attachmentId': attachmentId};
    if (sessionId != null && sessionId.isNotEmpty) {
      try {
        final page = await rpc('session/page', {
          'request': {
            'address': {'kind': 'session', 'sessionId': sessionId},
            'maxMessages': 120,
          },
        });
        final records = page is List ? page : _asList(_asMap(page)['records'] ?? _asMap(page)['events']);
        for (final raw in records) {
          final rec = _asMap(raw);
          final ev = rec['type'] == 'event' && rec['event'] is Map ? _asMap(rec['event']) : rec;
          final data = _asMap(ev['data']);
          final content = data['content'] ?? _asMap(data['message'])['content'] ?? ev['content'];
          if (content is! List) continue;
          for (final p in content) {
            final pm = _asMap(p);
            final att = pm['attachment'] is Map ? _asMap(pm['attachment']) : (pm['attachmentId'] != null ? pm : null);
            if (att != null && att['attachmentId']?.toString() == attachmentId) {
              attachmentObj = {...attachmentObj, ...att};
              break;
            }
          }
        }
      } catch (_) {}
    }
    final res = await rpc('session/attachment', {
      'request': {
        if (sessionId != null) 'sessionId': sessionId,
        'attachment': attachmentObj,
      },
    });
    final m = _asMap(res);
    final data = m['data'];
    if (data is String && data.isNotEmpty) {
      var clean = data.trim();
      final commaIdx = clean.indexOf(',');
      if (clean.startsWith('data:') && commaIdx > 0) {
        clean = clean.substring(commaIdx + 1);
      }
      clean = clean.replaceAll(RegExp(r'\s+'), '');
      if (clean.isNotEmpty) return base64Decode(clean);
    }
    return Uint8List(0);
  }
}
