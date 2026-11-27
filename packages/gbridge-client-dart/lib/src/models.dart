import 'package:meta/meta.dart';

/// Connection target for either local Android Unix Domain Socket or a remote HTTP/HTTPS DSH host.
@immutable
class HostEndpoint {
  const HostEndpoint.http({
    required this.baseUri,
    this.token,
    this.cookie,
  }) : unixSocketPath = null;

  const HostEndpoint.unix({
    required String socketPath,
    required String this.token,
  })  : unixSocketPath = socketPath,
        baseUri = null,
        cookie = null;

  final Uri? baseUri;
  final String? unixSocketPath;
  final String? token;
  final String? cookie;

  bool get isUnixSocket => unixSocketPath != null;

  Uri resolveHttpUri(String path, [Map<String, String>? queryParameters]) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    if (isUnixSocket) {
      return Uri(
        scheme: 'http',
        host: 'localhost',
        path: normalizedPath,
        queryParameters:
            (queryParameters == null || queryParameters.isEmpty) ? null : queryParameters,
      );
    }
    final base = baseUri!;
    final mergedPath = _joinPath(base.path, normalizedPath);
    return Uri(
      scheme: base.scheme,
      userInfo: base.userInfo,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: mergedPath,
      queryParameters:
          (queryParameters == null || queryParameters.isEmpty) ? null : queryParameters,
    );
  }

  Uri resolveWsUri(String path) {
    final httpUri = resolveHttpUri(path);
    final wsScheme = httpUri.scheme == 'https' ? 'wss' : 'ws';
    return httpUri.replace(scheme: wsScheme);
  }

  static String _joinPath(String a, String b) {
    final cleanA = a.endsWith('/') ? a.substring(0, a.length - 1) : a;
    final cleanB = b.startsWith('/') ? b : '/$b';
    return '$cleanA$cleanB';
  }
}

/// Structured protocol or transport error returned by `/gbridge/v1`.
class GbridgeException implements Exception {
  const GbridgeException({
    required this.status,
    required this.code,
    required this.message,
    this.details,
  });

  final int status;
  final String code;
  final String message;
  final Object? details;

  bool get isAuthError => status == 401 || status == 403;
  bool get isNotFound => status == 404;
  bool get isUnsupported => status == 501 || code == 'gbridge/endpoint_unsupported';

  @override
  String toString() => 'GbridgeException($status $code: $message)';
}

enum ConnectionPhase {
  disconnected,
  connecting,
  bootstrapping,
  needsAuth,
  connected,
  reconnecting,
  error,
}

@immutable
class DomainCapability {
  const DomainCapability({
    required this.ok,
    this.features = const [],
    this.version,
    this.reason,
  });

  factory DomainCapability.fromJson(Map<String, dynamic> json) {
    return DomainCapability(
      ok: json['ok'] == true,
      features: (json['features'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList(growable: false) ??
          const [],
      version: (json['version'] as num?)?.toInt(),
      reason: json['reason']?.toString(),
    );
  }

  final bool ok;
  final List<String> features;
  final int? version;
  final String? reason;

  bool hasFeature(String name) => features.contains(name);
}

@immutable
class HostInfo {
  const HostInfo({
    required this.name,
    required this.platform,
    required this.arch,
    required this.isLocalAndroid,
    this.homeDir,
  });

  factory HostInfo.fromJson(Map<String, dynamic> json) {
    return HostInfo(
      name: json['name']?.toString() ?? 'unknown',
      platform: json['platform']?.toString() ?? 'unknown',
      arch: json['arch']?.toString() ?? 'unknown',
      isLocalAndroid: json['isLocalAndroid'] == true,
      homeDir: json['homeDir']?.toString(),
    );
  }

  final String name;
  final String platform;
  final String arch;
  final bool isLocalAndroid;
  final String? homeDir;
}

@immutable
class TransportCapabilities {
  const TransportCapabilities({
    required this.wsPath,
    required this.coalesceMs,
    required this.replayCapacity,
  });

  factory TransportCapabilities.fromJson(Map<String, dynamic> json) {
    return TransportCapabilities(
      wsPath: json['wsPath']?.toString() ?? '/gbridge/v1/stream',
      coalesceMs: (json['coalesceMs'] as num?)?.toInt() ?? 35,
      replayCapacity: (json['replayCapacity'] as num?)?.toInt() ?? 2000,
    );
  }

  final String wsPath;
  final int coalesceMs;
  final int replayCapacity;
}

@immutable
class Capabilities {
  const Capabilities({
    required this.v,
    required this.bridgeVersion,
    required this.dshVersion,
    required this.bootId,
    required this.host,
    required this.transport,
    required this.domains,
    required this.endpointsCount,
  });

  factory Capabilities.fromJson(Map<String, dynamic> json) {
    final rawDomains = (json['domains'] as Map<String, dynamic>?) ?? const {};
    final domains = <String, DomainCapability>{};
    for (final entry in rawDomains.entries) {
      if (entry.value is Map<String, dynamic>) {
        domains[entry.key] = DomainCapability.fromJson(entry.value as Map<String, dynamic>);
      }
    }
    return Capabilities(
      v: (json['v'] as num?)?.toInt() ?? 1,
      bridgeVersion: json['bridgeVersion']?.toString() ?? '0.0.0',
      dshVersion: json['dshVersion']?.toString() ?? 'unknown',
      bootId: json['bootId']?.toString() ?? '',
      host: HostInfo.fromJson((json['host'] as Map<String, dynamic>?) ?? const {}),
      transport: TransportCapabilities.fromJson(
        (json['transport'] as Map<String, dynamic>?) ?? const {},
      ),
      domains: Map.unmodifiable(domains),
      endpointsCount: (json['endpointsCount'] as num?)?.toInt() ?? 0,
    );
  }

  final int v;
  final String bridgeVersion;
  final String dshVersion;
  final String bootId;
  final HostInfo host;
  final TransportCapabilities transport;
  final Map<String, DomainCapability> domains;
  final int endpointsCount;

  bool hasDomain(String domain) => domains[domain]?.ok == true;
  bool hasFeature(String domain, String feature) =>
      domains[domain]?.hasFeature(feature) == true;
}

@immutable
class OverviewSnapshot {
  const OverviewSnapshot({
    required this.v,
    required this.bootId,
    required this.bridgeVersion,
    required this.dshVersion,
    required this.host,
    required this.pendingInteractionsCount,
    required this.activeStreamsCount,
    this.account,
    this.sessionsCount,
  });

  factory OverviewSnapshot.fromJson(Map<String, dynamic> json) {
    return OverviewSnapshot(
      v: (json['v'] as num?)?.toInt() ?? 1,
      bootId: json['bootId']?.toString() ?? '',
      bridgeVersion: json['bridgeVersion']?.toString() ?? '0.0.0',
      dshVersion: json['dshVersion']?.toString() ?? 'unknown',
      host: HostInfo.fromJson((json['host'] as Map<String, dynamic>?) ?? const {}),
      pendingInteractionsCount: (json['pendingInteractionsCount'] as num?)?.toInt() ?? 0,
      activeStreamsCount: (json['activeStreamsCount'] as num?)?.toInt() ?? 0,
      account: json['account'] is Map<String, dynamic>
          ? json['account'] as Map<String, dynamic>
          : null,
      sessionsCount: (json['sessionsCount'] as num?)?.toInt(),
    );
  }

  final int v;
  final String bootId;
  final String bridgeVersion;
  final String dshVersion;
  final HostInfo host;
  final int pendingInteractionsCount;
  final int activeStreamsCount;
  final Map<String, dynamic>? account;
  final int? sessionsCount;
}

@immutable
class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.title,
    this.workspaceId,
    this.workspaceName,
    this.cwd,
    this.agentPreset,
    this.lastModelProvider,
    this.lastModelId,
    this.lastReasoningEffort,
    this.totalInputTokens,
    this.totalOutputTokens,
    this.updatedAt,
    this.blank = false,
    this.archived = false,
    this.pinned = false,
    this.running = false,
    this.pendingApproval = false,
    this.unread = false,
    this.raw = const {},
  });

  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    final projections = json['projections'] is Map<String, dynamic>
        ? json['projections'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final projValues = projections['values'] is Map<String, dynamic>
        ? projections['values'] as Map<String, dynamic>
        : projections;

    final cwdVal = (json['cwd'] ?? projValues['workingDirectory'])?.toString();
    final rawTitle = json['title'] ?? projValues['title'] ?? json['name'];
    final titleStr = _sanitizeSessionTitle(rawTitle, cwd: cwdVal);
    final rawWsId = json['workspaceId']?.toString();
    final wsId = (rawWsId != null && rawWsId.isNotEmpty) ? rawWsId : null;
    final wsName = json['workspaceName']?.toString();
    final preset = (projValues['agentPreset'] ?? json['agentPreset'])?.toString();

    final modelSel = projValues['modelSelection'];
    final lastUsed = modelSel is Map<String, dynamic>
        ? (modelSel['lastUsed'] is Map<String, dynamic>
            ? modelSel['lastUsed'] as Map<String, dynamic>
            : modelSel)
        : null;

    final tokenUsage = projValues['tokenUsage'] is Map<String, dynamic>
        ? projValues['tokenUsage'] as Map<String, dynamic>
        : null;
    final inTok = tokenUsage == null
        ? null
        : (((tokenUsage['uncachedInputTokens'] as num?)?.toInt() ??
                (tokenUsage['inputTokens'] as num?)?.toInt() ??
                0) +
            ((tokenUsage['cacheReadTokens'] as num?)?.toInt() ?? 0));
    final outTok = tokenUsage == null
        ? null
        : (tokenUsage['outputTokens'] as num?)?.toInt();

    return SessionSummary(
      id: (json['sessionId'] ?? json['id'] ?? '').toString(),
      title: titleStr,
      workspaceId: wsId,
      workspaceName: wsName,
      cwd: cwdVal,
      agentPreset: preset,
      lastModelProvider: lastUsed?['provider']?.toString(),
      lastModelId: lastUsed?['model']?.toString(),
      lastReasoningEffort: lastUsed?['reasoningEffort']?.toString(),
      totalInputTokens: inTok,
      totalOutputTokens: outTok,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ??
          (json['lastActivityAt'] as num?)?.toInt(),
      blank: json['blank'] == true,
      archived: json['archived'] == true,
      pinned: json['pinned'] == true,
      running: json['running'] == true || json['status'] == 'running',
      pendingApproval: json['pendingApproval'] == true || json['hasPendingApproval'] == true,
      unread: json['unread'] == true,
      raw: Map<String, dynamic>.unmodifiable(json),
    );
  }

  final String id;
  final String title;
  final String? workspaceId;
  final String? workspaceName;
  final String? cwd;
  final String? agentPreset;
  final String? lastModelProvider;
  final String? lastModelId;
  final String? lastReasoningEffort;
  final int? totalInputTokens;
  final int? totalOutputTokens;
  final int? updatedAt;
  final bool blank;
  final bool archived;
  final bool pinned;
  final bool running;
  final bool pendingApproval;
  final bool unread;
  final Map<String, dynamic> raw;

  static final RegExp _trailingSlashesRe = RegExp(r'/+$');
  static final RegExp _corruptObjRe = RegExp(r'\[object Object\]', caseSensitive: false);
  static final RegExp _leadingPunctRe = RegExp(r'^[\s,，:：\-·]+');
  static final RegExp _multiWhitespaceRe = RegExp(r'\s+');
  static final RegExp _weNeedAnswerRe = RegExp(r'^We need answer\b', caseSensitive: false);
  static final RegExp _quotedSnippetRe = RegExp(r'"([^"]{2,48})"');
  static final RegExp _homeDirPathRe = RegExp(r'/(?:Users|home)/[^/\s]+/(?:[^/\s]+/)*([^/\s]+)');

  static String? _basenameFromCwd(String? cwd) {
    if (cwd == null) return null;
    final trimmed = cwd.trim().replaceAll(_trailingSlashesRe, '');
    if (trimmed.isEmpty || trimmed == '/') return null;
    final parts = trimmed.split('/').where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? null : parts.last;
  }

  static String _sanitizeSessionTitle(Object? rawTitle, {String? cwd}) {
    var str = '';
    var hadCorruptObject = false;
    if (rawTitle is String) {
      str = rawTitle;
    } else if (rawTitle is List) {
      str = rawTitle
          .map((e) => e is String ? e : (e is Map ? (e['text']?.toString() ?? '') : ''))
          .join(' ');
    } else if (rawTitle is Map) {
      hadCorruptObject = true;
      if (rawTitle['text'] != null) str = rawTitle['text'].toString();
    }
    if (_corruptObjRe.hasMatch(str)) {
      hadCorruptObject = true;
      str = str
          .replaceAll(_corruptObjRe, ' ')
          .replaceFirst(_leadingPunctRe, '');
    }
    str = str.replaceAll(_multiWhitespaceRe, ' ').trim();
    if (str.isEmpty) {
      if (hadCorruptObject) return _basenameFromCwd(cwd) ?? '历史对话';
      return '新对话';
    }
    if (_weNeedAnswerRe.hasMatch(str)) {
      final m = _quotedSnippetRe.firstMatch(str);
      if (m != null && m.group(1) != null) return m.group(1)!.trim();
      return _basenameFromCwd(cwd) ?? '历史对话';
    }
    str = str.replaceAllMapped(
      _homeDirPathRe,
      (m) => m.group(1) ?? m.group(0)!,
    );
    return str.length > 72 ? '${str.substring(0, 71)}…' : str;
  }
}

@immutable
class MaskedRange {
  const MaskedRange({
    required this.start,
    required this.end,
    required this.visiblePrefix,
  });

  factory MaskedRange.fromJson(Map<String, dynamic> json) {
    return MaskedRange(
      start: (json['start'] as num?)?.toInt() ?? 0,
      end: (json['end'] as num?)?.toInt() ?? 0,
      visiblePrefix: (json['visiblePrefix'] as num?)?.toInt() ?? 0,
    );
  }

  final int start;
  final int end;
  final int visiblePrefix;

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'visiblePrefix': visiblePrefix,
      };
}

@immutable
class NormalizedUserMessage {
  const NormalizedUserMessage({
    required this.id,
    required this.text,
    this.attachments = const [],
    this.references = const [],
    this.maskedRanges = const [],
    this.createdAt,
  });

  factory NormalizedUserMessage.fromJson(Map<String, dynamic> json) {
    return NormalizedUserMessage(
      id: json['id']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      attachments: (json['attachments'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .toList(growable: false) ??
          const [],
      references: (json['references'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .toList(growable: false) ??
          const [],
      maskedRanges: (json['maskedRanges'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .map(MaskedRange.fromJson)
              .toList(growable: false) ??
          const [],
      createdAt: (json['createdAt'] as num?)?.toInt(),
    );
  }

  final String id;
  final String text;
  final List<Map<String, dynamic>> attachments;
  final List<Map<String, dynamic>> references;
  final List<MaskedRange> maskedRanges;
  final int? createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        if (attachments.isNotEmpty) 'attachments': attachments,
        if (references.isNotEmpty) 'references': references,
        if (maskedRanges.isNotEmpty)
          'maskedRanges': maskedRanges.map((r) => r.toJson()).toList(growable: false),
        if (createdAt != null) 'createdAt': createdAt,
      };
}

sealed class NormalizedStep {
  const NormalizedStep();

  factory NormalizedStep.fromJson(Map<String, dynamic> json) {
    final kind = json['kind']?.toString();
    if (kind == 'reasoning') {
      return ReasoningStep.fromJson(json);
    }
    if (kind == 'action_card') {
      return ActionCardStep.fromJson(json);
    }
    if (kind == 'notice') {
      return NoticeStep.fromJson(json);
    }
    return ToolStep.fromJson(json);
  }

  Map<String, dynamic> toJson();
}

@immutable
class ReasoningStep extends NormalizedStep {
  const ReasoningStep({
    required this.id,
    required this.text,
    required this.collapsedPreview,
    this.role,
    this.translatedText,
    this.durationMs,
  });

  factory ReasoningStep.fromJson(Map<String, dynamic> json) {
    final text = json['text']?.toString() ?? '';
    return ReasoningStep(
      id: json['id']?.toString() ?? '',
      text: text,
      collapsedPreview: json['collapsedPreview']?.toString() ??
          (text.isEmpty ? '' : text.split('\n').first),
      role: json['role']?.toString(),
      translatedText: json['translatedText']?.toString(),
      durationMs: (json['durationMs'] as num?)?.toInt(),
    );
  }

  final String id;
  final String text;
  final String collapsedPreview;
  final String? role;
  final String? translatedText;
  final int? durationMs;

  /// Whether this step is an intermediate assistant prose message emitted between
  /// thinking/tool steps rather than internal chain-of-thought reasoning.
  bool get isIntermediateProse => role == 'prose' || id.startsWith('narration-');

  ReasoningStep copyWith({
    String? text,
    String? collapsedPreview,
    String? role,
    String? translatedText,
    int? durationMs,
  }) {
    return ReasoningStep(
      id: id,
      text: text ?? this.text,
      collapsedPreview: collapsedPreview ?? this.collapsedPreview,
      role: role ?? this.role,
      translatedText: translatedText ?? this.translatedText,
      durationMs: durationMs ?? this.durationMs,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'reasoning',
        'id': id,
        'text': text,
        'collapsedPreview': collapsedPreview,
        if (role != null) 'role': role,
        if (translatedText != null) 'translatedText': translatedText,
        if (durationMs != null) 'durationMs': durationMs,
      };
}

@immutable
class ToolStep extends NormalizedStep {
  const ToolStep({
    required this.callId,
    required this.name,
    required this.title,
    required this.status,
    this.summary = '',
    this.hasFullOutput = false,
    this.durationMs,
    this.subagentSessionId,
  });

  factory ToolStep.fromJson(Map<String, dynamic> json) {
    return ToolStep(
      callId: json['callId']?.toString() ?? '',
      name: json['name']?.toString() ?? 'tool',
      title: json['title']?.toString() ?? json['name']?.toString() ?? 'tool',
      status: json['status']?.toString() ?? 'ok',
      summary: json['summary']?.toString() ?? '',
      hasFullOutput: json['hasFullOutput'] == true,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      subagentSessionId: json['subagentSessionId']?.toString(),
    );
  }

  final String callId;
  final String name;
  final String title;
  final String status; // running | ok | error
  final String summary;
  final bool hasFullOutput;
  final int? durationMs;
  final String? subagentSessionId;

  ToolStep copyWith({
    String? title,
    String? status,
    String? summary,
    bool? hasFullOutput,
    int? durationMs,
    String? subagentSessionId,
  }) {
    return ToolStep(
      callId: callId,
      name: name,
      title: title ?? this.title,
      status: status ?? this.status,
      summary: summary ?? this.summary,
      hasFullOutput: hasFullOutput ?? this.hasFullOutput,
      durationMs: durationMs ?? this.durationMs,
      subagentSessionId: subagentSessionId ?? this.subagentSessionId,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'tool',
        'callId': callId,
        'name': name,
        'title': title,
        'status': status,
        'summary': summary,
        'hasFullOutput': hasFullOutput,
        if (durationMs != null) 'durationMs': durationMs,
        if (subagentSessionId != null) 'subagentSessionId': subagentSessionId,
      };
}

@immutable
class ActionCardStep extends NormalizedStep {
  const ActionCardStep({
    required this.id,
    required this.sdui,
    this.viewId,
  });

  factory ActionCardStep.fromJson(Map<String, dynamic> json) {
    return ActionCardStep(
      id: json['id']?.toString() ?? '',
      viewId: json['viewId']?.toString(),
      sdui: json['sdui'] is Map<String, dynamic>
          ? Map<String, dynamic>.unmodifiable(json['sdui'] as Map<String, dynamic>)
          : const {},
    );
  }

  final String id;
  final String? viewId;
  final Map<String, dynamic> sdui;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'action_card',
        'id': id,
        if (viewId != null) 'viewId': viewId,
        'sdui': sdui,
      };
}

@immutable
class NoticeStep extends NormalizedStep {
  const NoticeStep({
    required this.level,
    required this.text,
  });

  factory NoticeStep.fromJson(Map<String, dynamic> json) {
    return NoticeStep(
      level: json['level']?.toString() ?? 'info',
      text: json['text']?.toString() ?? '',
    );
  }

  final String level; // info | warn | error
  final String text;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'notice',
        'level': level,
        'text': text,
      };
}

@immutable
class TurnUsage {
  const TurnUsage({
    required this.inputTokens,
    required this.outputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.cost,
    this.durationMs,
  });

  factory TurnUsage.fromJson(Map<String, dynamic> json) {
    return TurnUsage(
      inputTokens: (json['inputTokens'] as num?)?.toInt() ?? 0,
      outputTokens: (json['outputTokens'] as num?)?.toInt() ?? 0,
      cacheReadTokens: (json['cacheReadTokens'] as num?)?.toInt(),
      cacheWriteTokens: (json['cacheWriteTokens'] as num?)?.toInt(),
      cost: (json['cost'] as num?)?.toDouble(),
      durationMs: (json['durationMs'] as num?)?.toInt(),
    );
  }

  final int inputTokens;
  final int outputTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final double? cost;
  final int? durationMs;

  Map<String, dynamic> toJson() => {
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        if (cacheReadTokens != null) 'cacheReadTokens': cacheReadTokens,
        if (cacheWriteTokens != null) 'cacheWriteTokens': cacheWriteTokens,
        if (cost != null) 'cost': cost,
        if (durationMs != null) 'durationMs': durationMs,
      };
}

@immutable
class NormalizedTurn {
  const NormalizedTurn({
    required this.turnId,
    String? stableKey,
    this.seqStart = 0,
    this.seqEnd = 0,
    this.status = 'completed',
    this.userMessage,
    this.steps = const [],
    this.assistantText = '',
    this.assistantMessageId,
    this.usage,
    this.deliverables = const [],
    this.errorCode,
    this.errorMessage,
  }) : _stableKey = stableKey;

  factory NormalizedTurn.fromJson(Map<String, dynamic> json) {
    return NormalizedTurn(
      turnId: json['turnId']?.toString() ?? '',
      stableKey: json['stableKey']?.toString(),
      seqStart: (json['seqStart'] as num?)?.toInt() ?? 0,
      seqEnd: (json['seqEnd'] as num?)?.toInt() ?? 0,
      status: json['status']?.toString() ?? 'completed',
      userMessage: json['userMessage'] is Map<String, dynamic>
          ? NormalizedUserMessage.fromJson(json['userMessage'] as Map<String, dynamic>)
          : null,
      steps: (json['steps'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .map(NormalizedStep.fromJson)
              .toList(growable: false) ??
          const [],
      assistantText: json['assistantText']?.toString() ?? '',
      assistantMessageId: json['assistantMessageId']?.toString(),
      usage: json['usage'] is Map<String, dynamic>
          ? TurnUsage.fromJson(json['usage'] as Map<String, dynamic>)
          : null,
      deliverables: (json['deliverables'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .toList(growable: false) ??
          const [],
      errorCode: json['errorCode']?.toString(),
      errorMessage: json['errorMessage']?.toString(),
    );
  }

  final String turnId;
  final String? _stableKey;
  /// Stable client-side widget identity preserved across `pending-session` promotion
  /// and optimistic `client-turn-*` -> server `turnId` reconciliation (zero remount flash!).
  String get stableKey => (_stableKey != null && _stableKey.isNotEmpty) ? _stableKey : turnId;
  final int seqStart;
  final int seqEnd;
  final String status; // streaming | completed | cancelled | error
  final NormalizedUserMessage? userMessage;
  final List<NormalizedStep> steps;
  final String assistantText;
  final String? assistantMessageId;
  final TurnUsage? usage;
  final List<Map<String, dynamic>> deliverables;
  final String? errorCode;
  final String? errorMessage;

  bool get isStreaming => status == 'streaming';
  bool get hasError =>
      status == 'error' ||
      (errorMessage != null && errorMessage!.isNotEmpty) ||
      steps.any((s) => s is NoticeStep && s.level == 'error');

  /// All visible assistant prose across the turn in chronological order
  /// (intermediate prose segments emitted between tool/thinking steps + final `assistantText`).
  String get combinedAssistantProse {
    final parts = <String>[];
    for (final s in steps) {
      if (s is ReasoningStep && s.isIntermediateProse && s.text.trim().isNotEmpty) {
        parts.add(s.text.trim());
      }
    }
    if (assistantText.trim().isNotEmpty) {
      parts.add(assistantText.trim());
    }
    return parts.join('\n\n');
  }

  NormalizedTurn copyWith({
    String? stableKey,
    int? seqStart,
    int? seqEnd,
    String? status,
    NormalizedUserMessage? userMessage,
    List<NormalizedStep>? steps,
    String? assistantText,
    String? assistantMessageId,
    TurnUsage? usage,
    List<Map<String, dynamic>>? deliverables,
    String? errorCode,
    String? errorMessage,
  }) {
    return NormalizedTurn(
      turnId: turnId,
      stableKey: stableKey ?? _stableKey,
      seqStart: seqStart ?? this.seqStart,
      seqEnd: seqEnd ?? this.seqEnd,
      status: status ?? this.status,
      userMessage: userMessage ?? this.userMessage,
      steps: steps ?? this.steps,
      assistantText: assistantText ?? this.assistantText,
      assistantMessageId: assistantMessageId ?? this.assistantMessageId,
      usage: usage ?? this.usage,
      deliverables: deliverables ?? this.deliverables,
      errorCode: errorCode ?? this.errorCode,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  Map<String, dynamic> toJson() => {
        'turnId': turnId,
        'seqStart': seqStart,
        'seqEnd': seqEnd,
        'status': status,
        if (userMessage != null) 'userMessage': userMessage!.toJson(),
        'steps': steps.map((s) => s.toJson()).toList(growable: false),
        'assistantText': assistantText,
        if (assistantMessageId != null) 'assistantMessageId': assistantMessageId,
        if (usage != null) 'usage': usage!.toJson(),
        if (deliverables.isNotEmpty) 'deliverables': deliverables,
        if (errorCode != null) 'errorCode': errorCode,
        if (errorMessage != null) 'errorMessage': errorMessage,
      };
}

@immutable
class TurnsPage {
  const TurnsPage({
    required this.sessionId,
    required this.turns,
    required this.hasMore,
    this.nextCursor,
    this.projections,
  });

  factory TurnsPage.fromJson(Map<String, dynamic> json) {
    return TurnsPage(
      sessionId: json['sessionId']?.toString() ?? '',
      turns: (json['turns'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .map(NormalizedTurn.fromJson)
              .toList(growable: false) ??
          const [],
      hasMore: json['hasMore'] == true,
      nextCursor: json['nextCursor']?.toString(),
      projections: json['projections'] is Map<String, dynamic>
          ? json['projections'] as Map<String, dynamic>
          : null,
    );
  }

  final String sessionId;
  final List<NormalizedTurn> turns;
  final bool hasMore;
  final String? nextCursor;
  final Map<String, dynamic>? projections;
}

@immutable
class PendingInteraction {
  const PendingInteraction({
    required this.id,
    required this.kind,
    this.event,
    this.sessionId,
    this.payload = const {},
    this.createdAt,
  });

  factory PendingInteraction.fromJson(Map<String, dynamic> json) {
    return PendingInteraction(
      id: json['id']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'request',
      event: json['event']?.toString(),
      sessionId: json['sessionId']?.toString(),
      payload: json['payload'] is Map<String, dynamic>
          ? Map<String, dynamic>.unmodifiable(json['payload'] as Map<String, dynamic>)
          : const {},
      createdAt: (json['createdAt'] as num?)?.toInt(),
    );
  }

  final String id;
  final String kind; // approval | user_questions | cordis_run | request
  final String? event;
  final String? sessionId;
  final Map<String, dynamic> payload;
  final int? createdAt;
}

@immutable
class WebTicket {
  const WebTicket({
    required this.ticket,
    required this.expiresAt,
    required this.authenticatedUrl,
    this.sessionId,
  });

  factory WebTicket.fromJson(Map<String, dynamic> json) {
    return WebTicket(
      ticket: json['ticket']?.toString() ?? '',
      expiresAt: (json['expiresAt'] as num?)?.toInt() ?? 0,
      authenticatedUrl: json['authenticatedUrl']?.toString() ?? '',
      sessionId: json['sessionId']?.toString(),
    );
  }

  final String ticket;
  final int expiresAt;
  final String authenticatedUrl;
  final String? sessionId;
}

@immutable
class SduiSurfaceMeta {
  const SduiSurfaceMeta({
    required this.id,
    required this.title,
    this.subtitle,
    this.icon,
    this.placement = 'settings',
    this.order = 100,
  });

  factory SduiSurfaceMeta.fromJson(Map<String, dynamic> json) {
    return SduiSurfaceMeta(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      subtitle: json['subtitle']?.toString(),
      icon: json['icon']?.toString(),
      placement: json['placement']?.toString() ?? 'settings',
      order: (json['order'] as num?)?.toInt() ?? 100,
    );
  }

  final String id;
  final String title;
  final String? subtitle;
  final String? icon;
  final String placement;
  final int order;
}

@immutable
class SduiView {
  const SduiView({
    required this.viewId,
    required this.title,
    required this.root,
    this.subtitle,
  });

  factory SduiView.fromJson(Map<String, dynamic> json) {
    return SduiView(
      viewId: (json['viewId'] ?? json['id'] ?? '').toString(),
      title: json['title']?.toString() ?? '',
      subtitle: json['subtitle']?.toString(),
      root: (json['root'] is Map<String, dynamic>)
          ? Map<String, dynamic>.unmodifiable(json['root'] as Map<String, dynamic>)
          : const {},
    );
  }

  final String viewId;
  final String title;
  final String? subtitle;
  final Map<String, dynamic> root;
}

/// Multiplexed WebSocket frame received on `/gbridge/v1/stream`.
@immutable
class StreamFrame {
  const StreamFrame({
    required this.op,
    this.seq,
    this.channel,
    this.type,
    this.ts,
    this.data,
    this.raw = const {},
  });

  factory StreamFrame.fromJson(Map<String, dynamic> json) {
    return StreamFrame(
      op: json['op']?.toString() ?? 'unknown',
      seq: (json['seq'] as num?)?.toInt(),
      channel: json['channel']?.toString(),
      type: json['type']?.toString(),
      ts: (json['ts'] as num?)?.toInt(),
      data: json['data'],
      raw: Map<String, dynamic>.unmodifiable(json),
    );
  }

  final String op; // welcome | event | delta | pong | error
  final int? seq;
  final String? channel;
  final String? type;
  final int? ts;
  final Object? data;
  final Map<String, dynamic> raw;

  Map<String, dynamic>? get dataMap =>
      data is Map<String, dynamic> ? data as Map<String, dynamic> : null;
}

@immutable
class WelcomeInfo {
  const WelcomeInfo({
    required this.bootId,
    required this.currentSeq,
    required this.resumed,
    required this.replayedCount,
    required this.heartbeatMs,
    required this.pendingInteractions,
  });

  factory WelcomeInfo.fromJson(Map<String, dynamic> json) {
    return WelcomeInfo(
      bootId: json['bootId']?.toString() ?? '',
      currentSeq: (json['currentSeq'] as num?)?.toInt() ?? 0,
      resumed: json['resumed'] == true,
      replayedCount: (json['replayedCount'] as num?)?.toInt() ?? 0,
      heartbeatMs: (json['heartbeatMs'] as num?)?.toInt() ?? 20000,
      pendingInteractions: (json['pendingInteractions'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .map(PendingInteraction.fromJson)
              .toList(growable: false) ??
          const [],
    );
  }

  final String bootId;
  final int currentSeq;
  final bool resumed;
  final int replayedCount;
  final int heartbeatMs;
  final List<PendingInteraction> pendingInteractions;
}
