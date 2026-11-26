import 'dart:convert';
import 'dart:typed_data';

import 'bootstrap.dart';
import 'models.dart';
import 'transport.dart';
import 'vanilla_adapter.dart';
import 'vanilla_mux.dart';
import 'vanilla_normalizer.dart';

/// High-level typed client supporting BOTH:
/// 1) GrassBag's enhanced `/gbridge/v1` HTTP + WebSocket API (`dsh-gbridge` installed)
/// 2) Zero-plugin Direct Native Stock DSH (`POST /api/*` + `WS /api/remote.mux`) via
///    [enableVanillaDirectMode], so any remote machine running vanilla `dsh web`
///    works out of the box with full streaming chat, models, settings, workspaces & terminal!
class GbridgeClient {
  GbridgeClient(
    this.endpoint, {
    Duration? timeout,
    bool allowBadCertificates = false,
    String clientId = 'grassbag-flutter',
    int coalesceMs = 35,
    bool autoReconnect = true,
    void Function(String cookieHeader)? onCookieUpdated,
  })  : _autoReconnect = autoReconnect,
        _transport = GbridgeHttpTransport(
          endpoint,
          timeout: timeout,
          allowBadCertificates: allowBadCertificates,
          onCookieUpdated: onCookieUpdated,
        ) {
    _stream = GbridgeStreamClient(
      _transport,
      clientId: clientId,
      coalesceMs: coalesceMs,
      autoReconnect: autoReconnect,
    );
    _bootstrap = RemoteBootstrapClient(_transport);
  }

  static const String prefix = '/gbridge/v1';

  final HostEndpoint endpoint;
  final bool _autoReconnect;
  final GbridgeHttpTransport _transport;
  late final GbridgeStreamClient _stream;
  late final RemoteBootstrapClient _bootstrap;
  VanillaDshAdapter? _vanilla;
  VanillaDshMuxEngine? _vanillaMux;

  GbridgeHttpTransport get transport => _transport;
  GbridgeStreamClient get stream => _stream;
  RemoteBootstrapClient get bootstrap => _bootstrap;

  /// Whether this client is currently operating in zero-plugin direct stock DSH mode.
  bool get isVanillaDirect => _vanilla != null;

  /// Reset pooled HTTP keep-alive sockets (e.g. after Wi-Fi <-> cellular network transitions).
  void resetConnectionPool() => _transport.resetConnectionPool();

  /// Switch this client into zero-plugin direct stock DSH mode (`POST /api/*` + `WS /api/remote.mux`).
  Capabilities enableVanillaDirectMode({
    required String dshVersion,
    String? hostName,
  }) {
    if (_vanilla != null) return _vanilla!.buildCapabilities();
    final normalizer = VanillaDshNormalizer();
    late final VanillaDshAdapter adapter;
    final mux = VanillaDshMuxEngine(
      openSocket: _transport.openRawWebSocket,
      normalizer: normalizer,
      autoReconnect: _autoReconnect,
      onAutoApprove: (clientId, eventId) async {
        await adapter.rpc(r'$events/result', {
          'clientId': clientId,
          'eventId': eventId,
          'outcome': const {'kind': 'result', 'value': 'allowed-once'},
        });
      },
    );
    adapter = VanillaDshAdapter(
      transport: _transport,
      mux: mux,
      normalizer: normalizer,
      dshVersion: dshVersion,
      hostName: hostName,
    );
    _vanillaMux = mux;
    _vanilla = adapter;
    _stream.attachVanillaMux(mux);
    return adapter.buildCapabilities();
  }

  // ---------------------------------------------------------------------------
  // Discovery, Auth & Bootstrap
  // ---------------------------------------------------------------------------
  Future<bool> exchangeAuthToken([String? token]) => _transport.exchangeAuthToken(token);

  Future<HostProbeResult> probeHost() => _bootstrap.probeHost();

  Future<Capabilities> getCapabilities() async {
    final v = _vanilla;
    if (v != null) return v.buildCapabilities();
    final json = await _transport.requestJson('GET', '$prefix/capabilities');
    return Capabilities.fromJson(json);
  }

  Future<OverviewSnapshot> getOverview() async {
    final v = _vanilla;
    if (v != null) return v.getOverview();
    final json = await _transport.requestJson('GET', '$prefix/overview');
    return OverviewSnapshot.fromJson(json);
  }

  Future<WebTicket> createWebTicket({String? sessionId}) async {
    final v = _vanilla;
    if (v != null) return v.createWebTicket(sessionId: sessionId);
    final json = await _transport.requestJson(
      'POST',
      '$prefix/web-ticket',
      body: {if (sessionId != null) 'sessionId': sessionId},
    );
    return WebTicket.fromJson(json);
  }

  // ---------------------------------------------------------------------------
  // SDUI v1
  // ---------------------------------------------------------------------------
  Future<List<SduiSurfaceMeta>> listSduiSurfaces() async {
    if (_vanilla != null) return const [];
    final json = await _transport.requestJson('GET', '$prefix/sdui/surfaces');
    return (json['surfaces'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .map(SduiSurfaceMeta.fromJson)
            .toList(growable: false) ??
        const [];
  }

  Future<SduiView> getSduiView(String viewId, {String? sessionId}) async {
    if (_vanilla != null) {
      throw const GbridgeException(
        status: 501,
        code: 'gbridge/endpoint_unsupported',
        message: 'SDUI views require dsh-gbridge on the remote host',
      );
    }
    final json = await _transport.requestJson(
      'GET',
      '$prefix/sdui/views/${Uri.encodeComponent(viewId)}',
      query: {if (sessionId != null) 'sessionId': sessionId},
    );
    return SduiView.fromJson(json);
  }

  Future<Map<String, dynamic>> invokeSduiAction(
    String viewId,
    String actionId, [
    Map<String, dynamic>? payload,
  ]) {
    if (_vanilla != null) {
      return Future.error(const GbridgeException(
        status: 501,
        code: 'gbridge/endpoint_unsupported',
        message: 'SDUI actions require dsh-gbridge on the remote host',
      ));
    }
    return _transport.requestJson(
      'POST',
      '$prefix/sdui/action',
      body: {
        'viewId': viewId,
        'actionId': actionId,
        if (payload != null) 'payload': payload,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Chat, Sessions & Interactions
  // ---------------------------------------------------------------------------
  Future<List<SessionSummary>> listSessions({
    String? workspaceId,
    bool includeArchived = false,
  }) async {
    final v = _vanilla;
    if (v != null) {
      return v.listSessions(workspaceId: workspaceId, includeArchived: includeArchived);
    }
    final json = await _transport.requestJson(
      'GET',
      '$prefix/sessions',
      query: {
        if (workspaceId != null) 'workspaceId': workspaceId,
        if (includeArchived) 'includeArchived': 'true',
      },
    );
    return (json['sessions'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .map(SessionSummary.fromJson)
            .toList(growable: false) ??
        const [];
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
    final v = _vanilla;
    if (v != null) {
      return v.createSession(
        workspaceId: workspaceId,
        cwd: cwd,
        title: title,
        presetId: presetId,
        permission: permission,
        provider: provider,
        model: model,
        reasoningEffort: reasoningEffort,
      );
    }
    final json = await _transport.requestJson(
      'POST',
      '$prefix/sessions',
      body: {
        if (workspaceId != null) 'workspaceId': workspaceId,
        if (cwd != null) 'cwd': cwd,
        if (title != null) 'title': title,
        if (presetId != null) 'presetId': presetId,
        if (permission != null) 'permission': permission,
        if (provider != null && provider.isNotEmpty) 'provider': provider,
        if (model != null && model.isNotEmpty) 'model': model,
        if (reasoningEffort != null && reasoningEffort.isNotEmpty)
          'reasoningEffort': reasoningEffort,
      },
    );
    final raw = json['session'];
    return SessionSummary.fromJson(
      raw is Map<String, dynamic> ? raw : json,
    );
  }

  Future<List<Map<String, dynamic>>> searchSessions(String query, {int? limit}) async {
    final v = _vanilla;
    if (v != null) return v.searchSessions(query, limit: limit);
    final json = await _transport.requestJson(
      'GET',
      '$prefix/sessions/search',
      query: {
        'q': query,
        if (limit != null) 'limit': '$limit',
      },
    );
    return (json['results'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList(growable: false) ??
        const [];
  }

  Future<Map<String, dynamic>> patchSession(
    String sessionId, {
    String? title,
    bool? archived,
    bool? pinned,
  }) {
    final v = _vanilla;
    if (v != null) {
      return v.patchSession(sessionId, title: title, archived: archived, pinned: pinned);
    }
    return _transport.requestJson(
      'PATCH',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}',
      body: {
        if (title != null) 'title': title,
        if (archived != null) 'archived': archived,
        if (pinned != null) 'pinned': pinned,
      },
    );
  }

  Future<Map<String, dynamic>> deleteSession(String sessionId) {
    final v = _vanilla;
    if (v != null) return v.deleteSession(sessionId);
    return _transport.requestJson(
      'DELETE',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}',
    );
  }

  Future<TurnsPage> getSessionTurns(
    String sessionId, {
    int limit = 40,
    String? before,
    bool withProjections = true,
  }) async {
    final v = _vanilla;
    if (v != null) {
      return v.getSessionTurns(
        sessionId,
        limit: limit,
        before: before,
        withProjections: withProjections,
      );
    }
    final json = await _transport.requestJson(
      'GET',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/turns',
      query: {
        'limit': '$limit',
        if (before != null) 'before': before,
        if (!withProjections) 'withProjections': 'false',
      },
    );
    return TurnsPage.fromJson(json);
  }

  Future<Map<String, dynamic>> getToolOutput(String sessionId, String callId) {
    final v = _vanilla;
    if (v != null) return v.getToolOutput(sessionId, callId);
    return _transport.requestJson(
      'GET',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/tools/${Uri.encodeComponent(callId)}',
    );
  }

  /// Send a user prompt with delivery mode: `auto` | `steer` | `queue` | `interrupt`.
  Future<Map<String, dynamic>> sendMessage(
    String sessionId, {
    required String text,
    String mode = 'auto',
    List<Map<String, dynamic>>? attachments,
    List<Map<String, dynamic>>? references,
    String? clientRequestId,
  }) {
    final v = _vanilla;
    if (v != null) {
      return v.sendMessage(
        sessionId,
        text: text,
        mode: mode,
        attachments: attachments,
        references: references,
        clientRequestId: clientRequestId,
      );
    }
    return _transport.requestJson(
      'POST',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/messages',
      body: {
        'text': text,
        'mode': mode,
        if (attachments != null) 'attachments': attachments,
        if (references != null) 'references': references,
        if (clientRequestId != null) 'clientRequestId': clientRequestId,
      },
    );
  }

  Future<Map<String, dynamic>> cancelSession(String sessionId) {
    final v = _vanilla;
    if (v != null) return v.cancelSession(sessionId);
    return _transport.requestJson(
      'POST',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/cancel',
      body: const {},
    );
  }

  Future<Map<String, dynamic>> updateQueue(String sessionId, Map<String, dynamic> body) {
    final v = _vanilla;
    if (v != null) return v.updateQueue(sessionId, body);
    return _transport.requestJson(
      'PATCH',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/queue',
      body: body,
    );
  }

  Future<Map<String, dynamic>> forkSession(
    String sessionId, {
    String? turnId,
    int? atSeq,
    String? title,
  }) {
    final v = _vanilla;
    if (v != null) {
      return v.forkSession(sessionId, turnId: turnId, atSeq: atSeq, title: title);
    }
    return _transport.requestJson(
      'POST',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/fork',
      body: {
        if (turnId != null) 'turnId': turnId,
        if (atSeq != null) 'atSeq': atSeq,
        if (title != null) 'title': title,
      },
    );
  }

  Future<Map<String, dynamic>> exportSessionMarkdown(String sessionId) {
    final v = _vanilla;
    if (v != null) return v.exportSessionMarkdown(sessionId);
    return _transport.requestJson(
      'GET',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/export',
      query: const {'format': 'markdown'},
    );
  }

  Future<Uint8List> exportSessionZip(String sessionId, {bool includeDescendants = true}) {
    if (_vanilla != null) {
      return Future.error(const GbridgeException(
        status: 501,
        code: 'gbridge/endpoint_unsupported',
        message: 'ZIP export requires dsh-gbridge; use Markdown export in direct mode',
      ));
    }
    return _transport.requestBytes(
      'GET',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/export',
      query: {if (!includeDescendants) 'includeDescendants': 'false'},
    );
  }

  Future<Map<String, dynamic>> listMessageFeedback(String sessionId) {
    final v = _vanilla;
    if (v != null) return v.listMessageFeedback(sessionId);
    return _transport.requestJson(
      'GET',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/feedback',
    );
  }

  Future<Map<String, dynamic>> putMessageFeedback(
    String sessionId, {
    required String messageId,
    required String rating, // up | down | positive | negative
    String? comment,
    String? ifVersion,
  }) {
    final v = _vanilla;
    if (v != null) {
      return v.putMessageFeedback(
        sessionId,
        messageId: messageId,
        rating: rating,
        comment: comment,
        ifVersion: ifVersion,
      );
    }
    return _transport.requestJson(
      'PUT',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/feedback',
      body: {
        'messageId': messageId,
        'rating': rating,
        if (comment != null) 'note': comment,
        if (ifVersion != null) 'ifVersion': ifVersion,
      },
    );
  }

  Future<Map<String, dynamic>> deleteMessageFeedback(
    String sessionId, {
    required String messageId,
    String? ifVersion,
  }) {
    final v = _vanilla;
    if (v != null) {
      return v.deleteMessageFeedback(sessionId, messageId: messageId, ifVersion: ifVersion);
    }
    return _transport.requestJson(
      'DELETE',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/feedback',
      body: {
        'messageId': messageId,
        if (ifVersion != null) 'ifVersion': ifVersion,
      },
    );
  }

  Future<Map<String, dynamic>> getSessionReferences(String sessionId, {String query = ''}) {
    final v = _vanilla;
    if (v != null) return v.getSessionReferences(sessionId, query: query);
    return _transport.requestJson(
      'GET',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/references',
      query: {if (query.isNotEmpty) 'q': query},
    );
  }

  Future<Map<String, dynamic>> listCommands({String? sessionId}) {
    final v = _vanilla;
    if (v != null) return v.listCommands(sessionId: sessionId);
    return _transport.requestJson(
      'GET',
      '$prefix/commands',
      query: {if (sessionId != null) 'sessionId': sessionId},
    );
  }

  Future<Map<String, dynamic>> listSkills({String? sessionId}) {
    final v = _vanilla;
    if (v != null) return v.listSkills(sessionId: sessionId);
    return _transport.requestJson(
      'GET',
      '$prefix/skills',
      query: {if (sessionId != null) 'sessionId': sessionId},
    );
  }

  Future<Uint8List> downloadAttachment(String attachmentId, {String? sessionId}) {
    final v = _vanilla;
    if (v != null) return v.downloadAttachment(attachmentId, sessionId: sessionId);
    return _transport.requestBytes(
      'GET',
      '$prefix/attachments/${Uri.encodeComponent(attachmentId)}',
      query: {if (sessionId != null) 'sessionId': sessionId},
    );
  }

  Future<Map<String, dynamic>> getSessionGoals(String sessionId) {
    final v = _vanilla;
    if (v != null) return v.getSessionGoals(sessionId);
    return _transport.requestJson(
      'GET',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/goals',
    );
  }

  Future<Map<String, dynamic>> mutateSessionGoal(
    String sessionId, {
    required String action, // create | edit | pause | resume | complete | clear
    Map<String, dynamic> payload = const {},
  }) {
    final v = _vanilla;
    if (v != null) return v.mutateSessionGoal(sessionId, action: action, payload: payload);
    return _transport.requestJson(
      'POST',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/goals',
      body: {'action': action, ...payload},
    );
  }

  Future<Map<String, dynamic>> executeSlashCommand(
    String sessionId, {
    required String command,
    Map<String, dynamic>? args,
  }) {
    final v = _vanilla;
    if (v != null) return v.executeSlashCommand(sessionId, command: command, args: args);
    return _transport.requestJson(
      'POST',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/commands',
      body: {
        'command': command,
        if (args != null) ...args,
      },
    );
  }

  Future<List<PendingInteraction>> listPendingInteractions() async {
    final v = _vanilla;
    if (v != null) return v.listPendingInteractions();
    final json = await _transport.requestJson('GET', '$prefix/interactions/pending');
    return (json['items'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .map(PendingInteraction.fromJson)
            .toList(growable: false) ??
        const [];
  }

  Future<Map<String, dynamic>> respondInteraction(
    String interactionId, {
    Object? decision,
    Object? answers,
    Map<String, dynamic>? outcome,
  }) {
    final v = _vanilla;
    if (v != null) {
      return v.respondInteraction(
        interactionId,
        decision: decision,
        answers: answers,
        outcome: outcome,
      );
    }
    return _transport.requestJson(
      'POST',
      '$prefix/interactions/${Uri.encodeComponent(interactionId)}/respond',
      body: {
        if (decision != null) 'decision': decision,
        if (answers != null) 'answers': answers,
        if (outcome != null) 'outcome': outcome,
      },
    );
  }

  Future<Map<String, dynamic>> getPermissionsCatalog() {
    final v = _vanilla;
    if (v != null) return v.getPermissionsCatalog();
    return _transport.requestJson('GET', '$prefix/permissions/catalog');
  }

  // ---------------------------------------------------------------------------
  // Workspaces, Files, Terminals, Subagents, Jobs & Schedules
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>> listWorkspaces() {
    final v = _vanilla;
    if (v != null) return v.listWorkspaces();
    return _transport.requestJson('GET', '$prefix/workspaces');
  }

  Future<Map<String, dynamic>> createWorkspace({required String path, String? name}) {
    final v = _vanilla;
    if (v != null) return v.createWorkspace(path: path, name: name);
    return _transport.requestJson(
      'POST',
      '$prefix/workspaces',
      body: {'path': path, if (name != null) 'name': name},
    );
  }

  Future<Map<String, dynamic>> patchWorkspace(
    String workspaceId, {
    String? name,
    String? beforeId,
  }) {
    final v = _vanilla;
    if (v != null) return v.patchWorkspace(workspaceId, name: name, beforeId: beforeId);
    return _transport.requestJson(
      'PATCH',
      '$prefix/workspaces/${Uri.encodeComponent(workspaceId)}',
      body: {
        if (name != null) 'name': name,
        if (beforeId != null) 'beforeId': beforeId,
      },
    );
  }

  Future<Map<String, dynamic>> deleteWorkspace(String workspaceId) {
    final v = _vanilla;
    if (v != null) return v.deleteWorkspace(workspaceId);
    return _transport.requestJson(
      'DELETE',
      '$prefix/workspaces/${Uri.encodeComponent(workspaceId)}',
    );
  }

  Future<Map<String, dynamic>> browseFs({String? path}) {
    final v = _vanilla;
    if (v != null) return v.browseFs(path: path);
    return _transport.requestJson(
      'GET',
      '$prefix/fs/browse',
      query: {if (path != null) 'path': path},
    );
  }

  Future<Map<String, dynamic>> mkdirFs({required String path, String? name}) {
    final v = _vanilla;
    if (v != null) return v.mkdirFs(path: path, name: name);
    return _transport.requestJson(
      'POST',
      '$prefix/fs/mkdir',
      body: {'path': path, if (name != null) 'name': name},
    );
  }

  Future<Uint8List> renderOfficePreview(String workspaceId, {required String path}) {
    if (_vanilla != null) {
      return Future.error(const GbridgeException(
        status: 501,
        code: 'gbridge/endpoint_unsupported',
        message: 'Office preview requires dsh-gbridge',
      ));
    }
    return _transport.requestBytes(
      'POST',
      '$prefix/workspaces/${Uri.encodeComponent(workspaceId)}/files/office-preview',
      query: {'path': path},
      bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode({'path': path}))),
      contentType: 'application/json',
    );
  }

  Future<Map<String, dynamic>> listTerminalShells({String? sessionId}) {
    final v = _vanilla;
    if (v != null) return v.listTerminalShells(sessionId: sessionId);
    return _transport.requestJson(
      'GET',
      '$prefix/terminals/shells',
      query: {if (sessionId != null) 'sessionId': sessionId},
    );
  }

  Future<Map<String, dynamic>> patchTerminal(
    String terminalId, {
    String? sessionId,
    String? title,
    int? cols,
    int? rows,
    bool? retain,
  }) {
    final v = _vanilla;
    if (v != null) {
      return v.patchTerminal(
        terminalId,
        sessionId: sessionId,
        title: title,
        cols: cols,
        rows: rows,
        retain: retain,
      );
    }
    return _transport.requestJson(
      'PATCH',
      '$prefix/terminals/${Uri.encodeComponent(terminalId)}',
      body: {
        if (sessionId != null) 'sessionId': sessionId,
        if (title != null) 'title': title,
        if (cols != null) 'cols': cols,
        if (rows != null) 'rows': rows,
        if (retain != null) 'retain': retain,
      },
    );
  }

  Future<Map<String, dynamic>> getSessionProjections(String sessionId) {
    final v = _vanilla;
    if (v != null) return v.getSessionProjections(sessionId);
    return _transport.requestJson(
      'GET',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/projections',
    );
  }

  Future<Map<String, dynamic>> promptSubagent(
    String subagentId, {
    required String text,
    String? parentSessionId,
    String delivery = 'steer',
  }) {
    final v = _vanilla;
    if (v != null) {
      return v.promptSubagent(
        subagentId,
        text: text,
        parentSessionId: parentSessionId,
        delivery: delivery,
      );
    }
    return _transport.requestJson(
      'POST',
      '$prefix/subagents/${Uri.encodeComponent(subagentId)}/prompt',
      body: {
        'text': text,
        'delivery': delivery,
        if (parentSessionId != null) 'parentSessionId': parentSessionId,
      },
    );
  }

  Future<Map<String, dynamic>> interruptSubagent(String subagentId, {String? parentSessionId}) {
    final v = _vanilla;
    if (v != null) return v.interruptSubagent(subagentId, parentSessionId: parentSessionId);
    return _transport.requestJson(
      'POST',
      '$prefix/subagents/${Uri.encodeComponent(subagentId)}/interrupt',
      body: {if (parentSessionId != null) 'parentSessionId': parentSessionId},
    );
  }

  Future<Map<String, dynamic>> listJobs({String? sessionId}) {
    final v = _vanilla;
    if (v != null) return v.listJobs(sessionId: sessionId);
    return _transport.requestJson(
      'GET',
      '$prefix/jobs',
      query: {if (sessionId != null) 'sessionId': sessionId},
    );
  }

  Future<Map<String, dynamic>> killJob(String jobId, {String? sessionId}) {
    final v = _vanilla;
    if (v != null) return v.killJob(jobId, sessionId: sessionId);
    return _transport.requestJson(
      'POST',
      '$prefix/jobs/${Uri.encodeComponent(jobId)}/kill',
      body: {if (sessionId != null) 'sessionId': sessionId},
    );
  }

  Future<Map<String, dynamic>> listSchedules() {
    final v = _vanilla;
    if (v != null) return v.listSchedules();
    return _transport.requestJson('GET', '$prefix/schedules');
  }

  Future<Map<String, dynamic>> createSchedule(Map<String, dynamic> body) {
    final v = _vanilla;
    if (v != null) return v.createSchedule(body);
    return _transport.requestJson('POST', '$prefix/schedules', body: body);
  }

  Future<Map<String, dynamic>> pruneInactiveSchedules() {
    final v = _vanilla;
    if (v != null) return v.pruneInactiveSchedules();
    return _transport.requestJson('POST', '$prefix/schedules/prune', body: const {});
  }

  Future<Map<String, dynamic>> getScheduleHistory(String scheduleId) {
    final v = _vanilla;
    if (v != null) return v.getScheduleHistory(scheduleId);
    return _transport.requestJson(
      'GET',
      '$prefix/schedules/${Uri.encodeComponent(scheduleId)}/history',
    );
  }

  Future<Map<String, dynamic>> patchSchedule(String scheduleId, Map<String, dynamic> body) {
    final v = _vanilla;
    if (v != null) return v.patchSchedule(scheduleId, body);
    return _transport.requestJson(
      'PATCH',
      '$prefix/schedules/${Uri.encodeComponent(scheduleId)}',
      body: body,
    );
  }

  Future<Map<String, dynamic>> deleteSchedule(String scheduleId) {
    if (_vanilla != null) {
      return _vanilla!.deleteSchedule(scheduleId);
    }
    return _transport.requestJson(
      'DELETE',
      '$prefix/schedules/${Uri.encodeComponent(scheduleId)}',
    );
  }

  Future<Map<String, dynamic>> runScheduleNow(String scheduleId) {
    final v = _vanilla;
    if (v != null) return v.runScheduleNow(scheduleId);
    return _transport.requestJson(
      'POST',
      '$prefix/schedules/${Uri.encodeComponent(scheduleId)}/run',
      body: const {},
    );
  }

  Future<Map<String, dynamic>> getWorkspaceFileTree(
    String workspaceId, {
    String? path,
    String? sessionId,
  }) {
    final v = _vanilla;
    if (v != null) return v.getWorkspaceFileTree(workspaceId, path: path, sessionId: sessionId);
    return _transport.requestJson(
      'GET',
      '$prefix/workspaces/${Uri.encodeComponent(workspaceId)}/files/tree',
      query: {
        if (path != null) 'path': path,
        if (sessionId != null) 'sessionId': sessionId,
      },
    );
  }

  Future<Map<String, dynamic>> readWorkspaceFile(
    String workspaceId,
    String path, {
    int? offset,
    int? limit,
    String? sessionId,
  }) {
    final v = _vanilla;
    if (v != null) {
      return v.readWorkspaceFile(
        workspaceId,
        path,
        offset: offset,
        limit: limit,
        sessionId: sessionId,
      );
    }
    return _transport.requestJson(
      'GET',
      '$prefix/workspaces/${Uri.encodeComponent(workspaceId)}/files/read',
      query: {
        'path': path,
        if (offset != null) 'offset': '$offset',
        if (limit != null) 'limit': '$limit',
        if (sessionId != null) 'sessionId': sessionId,
      },
    );
  }

  Future<Uint8List> readWorkspaceFileBytes(
    String workspaceId,
    String path, {
    String? sessionId,
  }) {
    final v = _vanilla;
    if (v != null) return v.readWorkspaceFileBytes(workspaceId, path, sessionId: sessionId);
    return _transport.requestBytes(
      'GET',
      '$prefix/workspaces/${Uri.encodeComponent(workspaceId)}/files/read',
      query: {
        'path': path,
        'binary': 'true',
        if (sessionId != null) 'sessionId': sessionId,
      },
    );
  }

  Future<Map<String, dynamic>> getWorkspaceFileChanges(
    String workspaceId, {
    String? sessionId,
    String? scope,
  }) {
    final v = _vanilla;
    if (v != null) {
      return v.getWorkspaceFileChanges(workspaceId, sessionId: sessionId, scope: scope);
    }
    return _transport.requestJson(
      'GET',
      '$prefix/workspaces/${Uri.encodeComponent(workspaceId)}/files/changes',
      query: {
        if (sessionId != null) 'sessionId': sessionId,
        if (scope != null) 'scope': scope,
      },
    );
  }

  Future<Uint8List> uploadBinary(
    Uint8List bytes, {
    required String filename,
    String? sessionId,
    String contentType = 'application/octet-stream',
  }) {
    final v = _vanilla;
    if (v != null) {
      return v.uploadBinary(
        bytes,
        filename: filename,
        sessionId: sessionId,
        contentType: contentType,
      );
    }
    return _transport.requestBytes(
      'POST',
      '$prefix/uploads',
      query: {
        'filename': filename,
        if (sessionId != null) 'sessionId': sessionId,
      },
      bodyBytes: bytes,
      contentType: contentType,
    );
  }

  Future<Map<String, dynamic>> listTerminals({String? sessionId}) {
    final v = _vanilla;
    if (v != null) return v.listTerminals(sessionId: sessionId);
    return _transport.requestJson(
      'GET',
      '$prefix/terminals',
      query: {if (sessionId != null) 'sessionId': sessionId},
    );
  }

  Future<Map<String, dynamic>> createTerminal({
    String? cwd,
    String? shell,
    String? sessionId,
    int? cols,
    int? rows,
  }) {
    final v = _vanilla;
    if (v != null) {
      return v.createTerminal(
        cwd: cwd,
        shell: shell,
        sessionId: sessionId,
        cols: cols,
        rows: rows,
      );
    }
    return _transport.requestJson(
      'POST',
      '$prefix/terminals',
      body: {
        if (cwd != null) 'cwd': cwd,
        if (shell != null) 'shell': shell,
        if (sessionId != null) 'sessionId': sessionId,
        if (cols != null) 'cols': cols,
        if (rows != null) 'rows': rows,
      },
    );
  }

  Future<Map<String, dynamic>> closeTerminal(String terminalId, {String? sessionId}) {
    final v = _vanilla;
    if (v != null) return v.closeTerminal(terminalId, sessionId: sessionId);
    return _transport.requestJson(
      'DELETE',
      '$prefix/terminals/${Uri.encodeComponent(terminalId)}',
      query: {if (sessionId != null) 'sessionId': sessionId},
    );
  }

  Future<Map<String, dynamic>> setSessionPermission(String sessionId, String preset) {
    if (_vanilla != null) {
      return _vanilla!.executeSlashCommand(sessionId, command: '/permission $preset');
    }
    return _transport.requestJson(
      'PUT',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/permission',
      body: {'preset': preset},
    );
  }

  // ---------------------------------------------------------------------------
  // Models, Presets, Settings, Plugins & CoT Translation
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>> getModels({String? sessionId}) {
    final v = _vanilla;
    if (v != null) return v.getModels(sessionId: sessionId);
    return _transport.requestJson(
      'GET',
      '$prefix/models',
      query: {if (sessionId != null) 'sessionId': sessionId},
    );
  }

  Future<Map<String, dynamic>> selectModel(String sessionId, Map<String, dynamic> body) {
    final v = _vanilla;
    if (v != null) return v.selectModel(sessionId, body);
    return _transport.requestJson(
      'PUT',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/model',
      body: body,
    );
  }

  Future<Map<String, dynamic>> listPresets() {
    final v = _vanilla;
    if (v != null) return v.listPresets();
    return _transport.requestJson('GET', '$prefix/presets');
  }

  Future<Map<String, dynamic>> selectPreset(Map<String, dynamic> body) {
    final v = _vanilla;
    if (v != null) return v.selectPreset(body);
    return _transport.requestJson('POST', '$prefix/presets/select', body: body);
  }

  Future<Map<String, dynamic>> getSettingsSchema({bool forceFresh = false}) {
    final v = _vanilla;
    if (v != null) return v.getSettingsSchema(forceFresh: forceFresh);
    return _transport.requestJson('GET', '$prefix/settings/schema');
  }

  Future<Map<String, dynamic>> getSettingsManifest() {
    final v = _vanilla;
    if (v != null) return v.getSettingsManifest();
    return _transport.requestJson('GET', '$prefix/settings/manifest');
  }

  Future<Map<String, dynamic>> checkSystemUpdate() {
    if (_vanilla != null) {
      return Future.value(const {'v': 1, 'hasUpdate': false, 'directMode': true});
    }
    return _transport.requestJson('GET', '$prefix/system/check-update');
  }

  Future<Map<String, dynamic>> organizeWorkspacesByCwd() {
    if (_vanilla != null) {
      return Future.value(const {'v': 1, 'ok': true, 'created': 0});
    }
    return _transport.requestJson('POST', '$prefix/workspaces/organize-by-cwd', body: const {});
  }

  Future<Map<String, dynamic>> attachSessionToWorkspace(String workspaceId, String sessionId) {
    final v = _vanilla;
    if (v != null) return v.attachSessionToWorkspace(workspaceId, sessionId);
    return _transport.requestJson(
      'POST',
      '$prefix/workspaces/${Uri.encodeComponent(workspaceId)}/attach-session',
      body: {'sessionId': sessionId},
    );
  }

  Future<Map<String, dynamic>> patchSettings(Map<String, dynamic> patch) {
    final v = _vanilla;
    if (v != null) return v.patchSettings(patch);
    return _transport.requestJson('PATCH', '$prefix/settings', body: patch);
  }

  Future<Map<String, dynamic>> listPluginBundles() {
    final v = _vanilla;
    if (v != null) return v.listPluginBundles();
    return _transport.requestJson('GET', '$prefix/plugins/bundles');
  }

  Future<Map<String, dynamic>> listPluginEntries() {
    final v = _vanilla;
    if (v != null) return v.listPluginEntries();
    return _transport.requestJson('GET', '$prefix/plugins/entries');
  }

  Future<Map<String, dynamic>> listPluginInventory() {
    final v = _vanilla;
    if (v != null) return v.listPluginInventory();
    return _transport.requestJson('GET', '$prefix/plugins/inventory');
  }

  Future<Map<String, dynamic>> listPluginRegistries() {
    final v = _vanilla;
    if (v != null) return v.listPluginRegistries();
    return _transport.requestJson('GET', '$prefix/plugins/registries');
  }

  Future<Map<String, dynamic>> inspectPlugin(Map<String, dynamic> body) {
    final v = _vanilla;
    if (v != null) return v.inspectPlugin(body);
    return _transport.requestJson('POST', '$prefix/plugins/inspect', body: body);
  }

  Future<Map<String, dynamic>> installPlugin(Map<String, dynamic> body) {
    final v = _vanilla;
    if (v != null) return v.installPlugin(body);
    return _transport.requestJson('POST', '$prefix/plugins/install', body: body);
  }

  Future<Map<String, dynamic>> cancelPluginInstall(String requestId) {
    final v = _vanilla;
    if (v != null) return v.cancelPluginInstall(requestId);
    return _transport.requestJson(
      'POST',
      '$prefix/plugins/install/${Uri.encodeComponent(requestId)}/cancel',
      body: const {},
    );
  }

  Future<Map<String, dynamic>> setPluginBundleEnabled(String name, bool enabled) {
    final v = _vanilla;
    if (v != null) return v.setPluginBundleEnabled(name, enabled);
    return _transport.requestJson(
      'PATCH',
      '$prefix/plugins/bundles/${Uri.encodeComponent(name)}',
      body: {'enabled': enabled},
    );
  }

  Future<Map<String, dynamic>> setPluginEntryEnabled(String id, bool enabled) {
    final v = _vanilla;
    if (v != null) return v.setPluginEntryEnabled(id, enabled);
    return _transport.requestJson(
      'PATCH',
      '$prefix/plugins/entries/${Uri.encodeComponent(id)}',
      body: {'enabled': enabled},
    );
  }

  Future<Map<String, dynamic>> removePluginBundle(String name) {
    final v = _vanilla;
    if (v != null) return v.removePluginBundle(name);
    return _transport.requestJson(
      'DELETE',
      '$prefix/plugins/bundles/${Uri.encodeComponent(name)}',
    );
  }

  Future<Map<String, dynamic>> listDynamicCordis() {
    final v = _vanilla;
    if (v != null) return v.listDynamicCordis();
    return _transport.requestJson('GET', '$prefix/cordis/dynamic');
  }

  Future<Map<String, dynamic>> dynamicCordisAction(String id, String action, {String? agentId}) {
    final v = _vanilla;
    if (v != null) return v.dynamicCordisAction(id, action, agentId: agentId);
    return _transport.requestJson(
      'POST',
      '$prefix/cordis/dynamic/${Uri.encodeComponent(id)}/${Uri.encodeComponent(action)}',
      body: {if (agentId != null && agentId.isNotEmpty) 'agentId': agentId},
    );
  }

  Future<Map<String, dynamic>> listProviders() {
    final v = _vanilla;
    if (v != null) return v.listProviders();
    return _transport.requestJson('GET', '$prefix/providers');
  }

  Future<Map<String, dynamic>> discoverProviderModels(Map<String, dynamic> body) {
    final v = _vanilla;
    if (v != null) return v.discoverProviderModels(body);
    return _transport.requestJson('POST', '$prefix/providers/discover', body: body);
  }

  Future<Map<String, dynamic>> getAccount() {
    final v = _vanilla;
    if (v != null) return v.getAccount();
    return _transport.requestJson('GET', '$prefix/account');
  }

  Future<Map<String, dynamic>> accountAction(String action, [Map<String, dynamic> body = const {}]) {
    final v = _vanilla;
    if (v != null) return v.accountAction(action, body);
    return _transport.requestJson(
      'POST',
      '$prefix/account/${Uri.encodeComponent(action)}',
      body: body,
    );
  }

  Future<Map<String, dynamic>> listMcpServers() {
    final v = _vanilla;
    if (v != null) return v.listMcpServers();
    return _transport.requestJson('GET', '$prefix/mcp');
  }

  Future<Map<String, dynamic>> mcpAction(String name, String action) {
    final v = _vanilla;
    if (v != null) return v.mcpAction(name, action);
    return _transport.requestJson(
      'POST',
      '$prefix/mcp/${Uri.encodeComponent(name)}/${Uri.encodeComponent(action)}',
      body: const {},
    );
  }

  Future<Map<String, dynamic>> listWebProviders() {
    final v = _vanilla;
    if (v != null) return v.listWebProviders();
    return _transport.requestJson('GET', '$prefix/web/providers');
  }

  Future<Map<String, dynamic>> listPluginMarketIndexes() {
    if (_vanilla != null) return Future.value(const {'v': 1, 'indexes': []});
    return _transport.requestJson('GET', '$prefix/plugins/market/indexes');
  }

  Future<Map<String, dynamic>> searchPluginMarket(Map<String, dynamic> body) {
    if (_vanilla != null) {
      return Future.value(const {'v': 1, 'result': {'items': []}});
    }
    return _transport.requestJson('POST', '$prefix/plugins/market/search', body: body);
  }

  Future<Map<String, dynamic>> updatePluginBundle(String name, {String version = 'latest'}) {
    final v = _vanilla;
    if (v != null) return v.updatePluginBundle(name, version: version);
    return _transport.requestJson(
      'POST',
      '$prefix/plugins/bundles/${Uri.encodeComponent(name)}/update',
      body: {'version': version},
    );
  }

  Future<Map<String, dynamic>> setTeamMode(String sessionId, bool enabled) {
    final v = _vanilla;
    if (v != null) return v.setTeamMode(sessionId, enabled);
    return _transport.requestJson(
      'POST',
      '$prefix/sessions/${Uri.encodeComponent(sessionId)}/team',
      body: {'enabled': enabled},
    );
  }

  Future<Map<String, dynamic>> getCredentials({List<String>? refs}) {
    final v = _vanilla;
    if (v != null) return v.getCredentials(refs: refs);
    return _transport.requestJson(
      'GET',
      '$prefix/credentials',
      query: {if (refs != null && refs.isNotEmpty) 'refs': refs.join(',')},
    );
  }

  Future<Map<String, dynamic>> setCredential(Map<String, dynamic> body) {
    final v = _vanilla;
    if (v != null) return v.setCredential(body);
    return _transport.requestJson('PUT', '$prefix/credentials', body: body);
  }

  Future<Map<String, dynamic>> unsetCredential(Map<String, dynamic> body) {
    final v = _vanilla;
    if (v != null) return v.unsetCredential(body);
    return _transport.requestJson('DELETE', '$prefix/credentials', body: body);
  }

  Future<Map<String, dynamic>> listSubscriptions() {
    if (_vanilla != null) return Future.value(const {'v': 1, 'subscriptions': []});
    return _transport.requestJson('GET', '$prefix/auth/subscriptions');
  }

  Future<Map<String, dynamic>> subscriptionAction(String action, Map<String, dynamic> body) {
    if (_vanilla != null) {
      return Future.error(const GbridgeException(
        status: 501,
        code: 'gbridge/endpoint_unsupported',
        message: 'Subscription auth requires dsh-gbridge',
      ));
    }
    return _transport.requestJson(
      'POST',
      '$prefix/auth/subscriptions/${Uri.encodeComponent(action)}',
      body: body,
    );
  }

  Future<Map<String, dynamic>> getAuthUsage() {
    if (_vanilla != null) return _vanilla!.getAccount();
    return _transport.requestJson('GET', '$prefix/auth/usage');
  }

  Future<Map<String, dynamic>> getSpeechConfig() {
    if (_vanilla != null) return Future.value(const {'v': 1, 'configured': false});
    return _transport.requestJson('GET', '$prefix/speech/config');
  }

  Future<Map<String, dynamic>> updateSpeechConfig(Map<String, dynamic> body) {
    if (_vanilla != null) {
      return Future.error(const GbridgeException(
        status: 501,
        code: 'gbridge/endpoint_unsupported',
        message: 'Speech config requires dsh-gbridge',
      ));
    }
    return _transport.requestJson('PUT', '$prefix/speech/config', body: body);
  }

  Future<Map<String, dynamic>> transcribeSpeech(Map<String, dynamic> body) {
    if (_vanilla != null) {
      return Future.error(const GbridgeException(
        status: 501,
        code: 'gbridge/endpoint_unsupported',
        message: 'Speech transcription requires dsh-gbridge',
      ));
    }
    return _transport.requestJson('POST', '$prefix/speech/transcribe', body: body);
  }

  Future<Map<String, dynamic>> translateCot(String text, {String targetLang = 'zh-CN'}) {
    if (_vanilla != null) {
      return Future.error(const GbridgeException(
        status: 501,
        code: 'gbridge/endpoint_unsupported',
        message: 'CoT translation requires dsh-gbridge',
      ));
    }
    return _transport.requestJson(
      'POST',
      '$prefix/tools/translate-cot',
      body: {'text': text, 'targetLanguage': targetLang, 'targetLang': targetLang},
    );
  }

  Future<void> dispose() async {
    // Close HTTP transport immediately so in-flight RPCs abort cleanly on host switch.
    _transport.close(force: true);
    await _stream.dispose().timeout(
      const Duration(milliseconds: 500),
      onTimeout: () {},
    );
    if (_vanillaMux != null) {
      await _vanillaMux!.dispose().timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
      _vanillaMux = null;
    }
    _vanilla = null;
  }
}
