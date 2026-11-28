import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart';
import 'package:xterm/xterm.dart';

import '../data/grassbag_storage.dart';
import '../services/app_update_service.dart';
import '../services/native_bridge.dart';
import '../theme/grassbag_theme.dart';
import '../ui/web/web_embed.dart';
import 'default_fixtures.dart';
import 'domain_models.dart';
import 'dsh_catalog.dart';

export 'package:gbridge_client/gbridge_client.dart' show ConnectionPhase;
export '../services/app_update_service.dart'
    show
        AppReleaseCheckResult,
        AppReleaseInfo,
        kGrassBagBuildChannel,
        kGrassBagGitHubRepo,
        kGrassBagReleasesWebUrl,
        kGrassBagRepoWebUrl;
export 'domain_models.dart';
export 'dsh_catalog.dart';

enum ToastTone { ok, warn, error, info }

@immutable
class GrassBagToastMessage {
  const GrassBagToastMessage({
    required this.id,
    required this.text,
    this.tone = ToastTone.ok,
    this.detail,
  });
  final int id;
  final String text;
  final ToastTone tone;
  final String? detail;
}

enum SessionGroupMode {
  workspace('按工作区'),
  date('按时间');

  const SessionGroupMode(this.label);
  final String label;
}

enum SessionFilter {
  all('全部'),
  running('运行中'),
  pending('待确认'),
  unread('未读'),
  archived('已归档');

  const SessionFilter(this.label);
  final String label;
}

@immutable
class PresetOption {
  const PresetOption({
    required this.id,
    required this.name,
    required this.desc,
    this.isDefault = false,
  });
  final String id;
  final String name;
  final String desc;
  final bool isDefault;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PresetOption &&
        other.id == id &&
        other.name == name &&
        other.desc == desc &&
        other.isDefault == isDefault;
  }

  @override
  int get hashCode => Object.hash(id, name, desc, isDefault);
}

@immutable
class PermissionTier {
  const PermissionTier({
    required this.id,
    required this.name,
    required this.desc,
    this.risky = false,
    this.isDefault = false,
  });
  final String id;
  final String name;
  final String desc;
  final bool risky;
  final bool isDefault;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PermissionTier &&
        other.id == id &&
        other.name == name &&
        other.desc == desc &&
        other.risky == risky &&
        other.isDefault == isDefault;
  }

  @override
  int get hashCode => Object.hash(id, name, desc, risky, isDefault);
}

@immutable
class WorkspaceItem {
  const WorkspaceItem({
    required this.id,
    required this.name,
    required this.path,
    this.branch = '',
    this.isPhoneStorage = false,
    this.explicit = false,
    this.sessionIds = const [],
    this.sessionCount = 0,
  });
  final String id;
  final String name;
  final String path;
  final String branch;
  final bool isPhoneStorage;
  final bool explicit;
  final List<String> sessionIds;
  final int sessionCount;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WorkspaceItem &&
        other.id == id &&
        other.name == name &&
        other.path == path &&
        other.branch == branch &&
        other.isPhoneStorage == isPhoneStorage &&
        other.explicit == explicit &&
        other.sessionCount == sessionCount &&
        listEquals(other.sessionIds, sessionIds);
  }

  @override
  int get hashCode => Object.hash(
        id,
        name,
        path,
        branch,
        isPhoneStorage,
        explicit,
        sessionCount,
        Object.hashAll(sessionIds),
      );
}

enum PairingStage {
  idle,
  connecting,
  authorizing,
  openingSession,
  ready,
  failed,
}

enum RemoteDiagnosisKind {
  readyGbridge,
  readyDirect,
  needsAuth,
  pairingCodeExpired,
  htmlLoginPage,
  untrustedHost,
  selfSignedTls,
  insecurePublicHttp,
  selfDevice,
  realtimeFailed,
  unreachable,
  invalidAddress,
}

@immutable
class RemoteHostDiagnosis {
  const RemoteHostDiagnosis({
    required this.kind,
    required this.title,
    required this.message,
    this.technicalDetail,
    this.normalizedAddress,
    this.extractedToken,
    this.extractedPairCode,
    this.capturedCookie,
    this.hostName,
    this.dshVersion,
    this.latencyMs,
    this.hostAuthority,
    this.hasGbridge = false,
    this.isLoopbackTarget = false,
    this.suggestedCommand,
  });

  final RemoteDiagnosisKind kind;
  final String title;
  final String message;
  final String? technicalDetail;
  final String? normalizedAddress;
  final String? extractedToken;
  final String? extractedPairCode;
  final String? capturedCookie;
  final String? hostName;
  final String? dshVersion;
  final int? latencyMs;
  final String? hostAuthority;
  final bool hasGbridge;
  final bool isLoopbackTarget;
  final String? suggestedCommand;

  bool get canConnectNow =>
      kind == RemoteDiagnosisKind.readyGbridge || kind == RemoteDiagnosisKind.readyDirect;
  bool get needsWebOrTokenAuth =>
      kind == RemoteDiagnosisKind.needsAuth ||
      kind == RemoteDiagnosisKind.pairingCodeExpired ||
      kind == RemoteDiagnosisKind.htmlLoginPage;
}

@immutable
class RemoteConnectOutcome {
  const RemoteConnectOutcome({
    required this.diagnosis,
    this.host,
    this.connected = false,
    this.cancelled = false,
    this.sessionCount,
  });

  final RemoteHostDiagnosis diagnosis;
  final ManagedHost? host;
  final bool connected;
  final bool cancelled;
  final int? sessionCount;
}

@immutable
class PendingOutboxItem {
  const PendingOutboxItem({
    required this.id,
    required this.hostId,
    required this.sessionId,
    required this.text,
    this.mode = 'auto',
    this.status = 'unsent',
    this.errorMessage,
    this.updatedAtMs = 0,
  });

  factory PendingOutboxItem.fromMap(Map<String, dynamic> map) {
    return PendingOutboxItem(
      id: map['id']?.toString() ?? '',
      hostId: map['hostId']?.toString() ?? '',
      sessionId: map['sessionId']?.toString() ?? '',
      text: map['text']?.toString() ?? '',
      mode: map['mode']?.toString() ?? 'auto',
      status: map['status']?.toString() ?? 'unsent',
      errorMessage: map['errorMessage']?.toString(),
      updatedAtMs: (map['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final String hostId;
  final String sessionId;
  final String text;
  final String mode;
  final String status;
  final String? errorMessage;
  final int updatedAtMs;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PendingOutboxItem &&
        other.id == id &&
        other.hostId == hostId &&
        other.sessionId == sessionId &&
        other.text == text &&
        other.mode == mode &&
        other.status == status &&
        other.errorMessage == errorMessage &&
        other.updatedAtMs == updatedAtMs;
  }

  @override
  int get hashCode =>
      Object.hash(id, hostId, sessionId, text, mode, status, errorMessage, updatedAtMs);
}

@immutable
class ManagedHost {
  const ManagedHost({
    required this.id,
    required this.isLocal,
    required this.name,
    required this.address,
    required this.latency,
    required this.online,
    required this.bridged,
    this.directMode = false,
    this.allowBadCertificates = false,
    this.installing = false,
    this.dshVersion = '0.2.2-rc.5',
    String? dshLatest,
    this.dshPrevVersion = '',
    this.helperVersion,
    this.containerVersion = 'Ubuntu 24.04.5 · Node 24.22.3',
    String? containerLatest,
    this.containerNode = 'Node 24.22',
    this.launcherMode = '高速模式',
    this.sdcardMounted = true,
    this.updatingDsh = false,
    this.updatingContainer = false,
    this.token,
    this.sessionCookie,
    this.lastError,
    this.lastErrorCode,
  })  : dshLatest = dshLatest ?? dshVersion,
        containerLatest = containerLatest ?? containerVersion;

  static int _fallbackRemoteIdSeq = 0;

  factory ManagedHost.fromJson(Map<String, dynamic> m) {
    final isLocal = m['isLocal'] == true;
    final ver = m['dshVersion']?.toString() ?? '0.2.2-rc.5';
    final rawLatest = m['dshLatest']?.toString();
    // Scrub legacy hardcoded fake '0.2.3' / 'Ubuntu 24.04 · r2' / '0.2.2-rc.1' cached values!
    final safeLatest = (rawLatest == null || rawLatest == '0.2.3') ? ver : rawLatest;
    final rawPrev = m['dshPrevVersion']?.toString() ?? '';
    final safePrev = rawPrev == '0.2.2-rc.1' ? '' : rawPrev;
    final cVer = m['containerVersion']?.toString() ?? 'Ubuntu 24.04.5 · Node 24.22.3';
    final rawCLatest = m['containerLatest']?.toString();
    final safeCLatest =
        (rawCLatest == null || rawCLatest == 'Ubuntu 24.04 · r2') ? cVer : rawCLatest;
    final rawId = m['id']?.toString().trim() ?? '';
    final resolvedId = rawId.isNotEmpty
        ? rawId
        : (isLocal ? 'local' : 'rem-imported-${++_fallbackRemoteIdSeq}');
    return ManagedHost(
      id: resolvedId,
      isLocal: isLocal,
      name: m['name']?.toString() ?? '远程主机',
      address: m['address']?.toString() ?? '',
      // Always start offline until freshly probed/connected so stale green dots never mislead.
      latency: isLocal ? '本地' : '--',
      online: false,
      bridged: false,
      directMode: false,
      allowBadCertificates: m['allowBadCertificates'] == true,
      dshVersion: ver,
      dshLatest: safeLatest,
      dshPrevVersion: safePrev,
      helperVersion: m['helperVersion']?.toString(),
      containerVersion: cVer,
      containerLatest: safeCLatest,
      launcherMode: m['launcherMode']?.toString() ?? '高速模式',
      sdcardMounted: m['sdcardMounted'] != false,
    );
  }

  final String id;
  final bool isLocal;
  final String name;
  final String address;
  final String latency;
  final bool online;
  final bool bridged;

  /// True when connected directly to stock `dsh web` with ZERO plugins installed.
  final bool directMode;

  /// Opt-in per-host trust for self-signed HTTPS certificates (LAN / Tailscale / Caddy).
  final bool allowBadCertificates;
  final bool installing;
  final String dshVersion;
  final String dshLatest;
  final String dshPrevVersion;
  final String? helperVersion;
  final String containerVersion;
  final String containerLatest;
  final String containerNode;
  final String launcherMode;
  final bool sdcardMounted;
  final bool updatingDsh;
  final bool updatingContainer;
  final String? token;

  /// Encrypted-vault-backed 30-day DSH / reverse-proxy session cookie (never stored in plaintext JSON).
  final String? sessionCookie;
  final String? lastError;

  /// Structured error classifier: `needs_auth` | `html_proxy` | `untrusted_host` | `tls_cert` | `unreachable`.
  final String? lastErrorCode;

  bool get hasSavedCookie => sessionCookie != null && sessionCookie!.isNotEmpty;
  bool get isConnectedUsable => online && (bridged || directMode);
  bool get needsAuth =>
      !isLocal && !online && (lastErrorCode == 'needs_auth' || lastErrorCode == 'html_proxy');
  bool get isHtmlProxyAuth => !isLocal && !online && lastErrorCode == 'html_proxy';

  /// True when targeting the Desktop GUI's built-in `:3081` API-only LAN bridge.
  bool get isDesktopLanBridge {
    if (isLocal) return false;
    final uri = Uri.tryParse(address);
    return uri != null && uri.port == 3081;
  }

  bool get hasLocalUpdates =>
      isLocal &&
      dshVersion != '检测中' &&
      dshLatest != '检测中' &&
      (dshVersion != dshLatest || containerVersion != containerLatest);

  /// Detect unencrypted non-LAN public `http://` endpoints per architecture §4.2 security rule.
  bool get isInsecurePublicHttp {
    if (isLocal) return false;
    final uri = Uri.tryParse(address);
    if (uri == null || uri.scheme != 'http') return false;
    final h = uri.host.toLowerCase();
    if (h == 'localhost' ||
        h == '127.0.0.1' ||
        h == '10.0.2.2' ||
        h.startsWith('10.') ||
        h.startsWith('192.168.') ||
        h.startsWith('100.') ||
        h.endsWith('.local') ||
        h.endsWith('.lan')) {
      return false;
    }
    if (h.startsWith('172.')) {
      final second = int.tryParse(h.split('.').elementAtOrNull(1) ?? '');
      if (second != null && second >= 16 && second <= 31) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'isLocal': isLocal,
        'name': name,
        'address': address,
        'allowBadCertificates': allowBadCertificates,
        'dshVersion': dshVersion,
        'dshLatest': dshLatest,
        'dshPrevVersion': dshPrevVersion,
        if (helperVersion != null) 'helperVersion': helperVersion,
        'containerVersion': containerVersion,
        'containerLatest': containerLatest,
        'launcherMode': launcherMode,
        'sdcardMounted': sdcardMounted,
      };

  ManagedHost copyWith({
    String? name,
    String? address,
    String? latency,
    bool? online,
    bool? bridged,
    bool? directMode,
    bool? allowBadCertificates,
    bool? installing,
    String? dshVersion,
    String? dshLatest,
    String? dshPrevVersion,
    String? helperVersion,
    String? containerVersion,
    String? containerLatest,
    String? launcherMode,
    bool? sdcardMounted,
    bool? updatingDsh,
    bool? updatingContainer,
    String? token,
    bool clearToken = false,
    String? sessionCookie,
    bool clearSessionCookie = false,
    String? lastError,
    String? lastErrorCode,
    bool clearLastError = false,
  }) {
    return ManagedHost(
      id: id,
      isLocal: isLocal,
      name: name ?? this.name,
      address: address ?? this.address,
      latency: latency ?? this.latency,
      online: online ?? this.online,
      bridged: bridged ?? this.bridged,
      directMode: directMode ?? this.directMode,
      allowBadCertificates: allowBadCertificates ?? this.allowBadCertificates,
      installing: installing ?? this.installing,
      dshVersion: dshVersion ?? this.dshVersion,
      dshLatest: dshLatest ?? this.dshLatest,
      dshPrevVersion: dshPrevVersion ?? this.dshPrevVersion,
      helperVersion: helperVersion ?? this.helperVersion,
      containerVersion: containerVersion ?? this.containerVersion,
      containerLatest: containerLatest ?? this.containerLatest,
      containerNode: containerNode,
      launcherMode: launcherMode ?? this.launcherMode,
      sdcardMounted: sdcardMounted ?? this.sdcardMounted,
      updatingDsh: updatingDsh ?? this.updatingDsh,
      updatingContainer: updatingContainer ?? this.updatingContainer,
      token: clearToken ? null : (token ?? this.token),
      sessionCookie: clearSessionCookie ? null : (sessionCookie ?? this.sessionCookie),
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      lastErrorCode: clearLastError ? null : (lastErrorCode ?? this.lastErrorCode),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ManagedHost &&
        other.id == id &&
        other.isLocal == isLocal &&
        other.name == name &&
        other.address == address &&
        other.latency == latency &&
        other.online == online &&
        other.bridged == bridged &&
        other.directMode == directMode &&
        other.allowBadCertificates == allowBadCertificates &&
        other.installing == installing &&
        other.dshVersion == dshVersion &&
        other.dshLatest == dshLatest &&
        other.dshPrevVersion == dshPrevVersion &&
        other.helperVersion == helperVersion &&
        other.containerVersion == containerVersion &&
        other.containerLatest == containerLatest &&
        other.containerNode == containerNode &&
        other.launcherMode == launcherMode &&
        other.sdcardMounted == sdcardMounted &&
        other.updatingDsh == updatingDsh &&
        other.updatingContainer == updatingContainer &&
        other.token == token &&
        other.sessionCookie == sessionCookie &&
        other.lastError == lastError &&
        other.lastErrorCode == lastErrorCode;
  }

  @override
  int get hashCode => Object.hashAll([
        id,
        isLocal,
        name,
        address,
        latency,
        online,
        bridged,
        directMode,
        allowBadCertificates,
        installing,
        dshVersion,
        dshLatest,
        dshPrevVersion,
        helperVersion,
        containerVersion,
        containerLatest,
        containerNode,
        launcherMode,
        sdcardMounted,
        updatingDsh,
        updatingContainer,
        token,
        sessionCookie,
        lastError,
        lastErrorCode,
      ]);
}

@immutable
class ChatSessionItem {
  const ChatSessionItem({
    required this.id,
    required this.title,
    required this.group,
    this.workspaceId,
    this.workspaceName,
    this.cwd,
    this.updatedAt,
    this.agentPreset,
    this.lastModelId,
    this.running = false,
    this.pendingApproval = false,
    this.unread = false,
    this.pinned = false,
    this.archived = false,
  });

  final String id;
  final String title;
  final String group;
  final String? workspaceId;
  final String? workspaceName;
  final String? cwd;
  final int? updatedAt;
  final String? agentPreset;
  final String? lastModelId;
  final bool running;
  final bool pendingApproval;
  final bool unread;
  final bool pinned;
  final bool archived;

  ChatSessionItem copyWith({
    String? id,
    String? title,
    String? group,
    String? workspaceId,
    String? workspaceName,
    String? cwd,
    int? updatedAt,
    String? agentPreset,
    String? lastModelId,
    bool? running,
    bool? pendingApproval,
    bool? unread,
    bool? pinned,
    bool? archived,
  }) {
    return ChatSessionItem(
      id: id ?? this.id,
      title: title ?? this.title,
      group: group ?? this.group,
      workspaceId: workspaceId ?? this.workspaceId,
      workspaceName: workspaceName ?? this.workspaceName,
      cwd: cwd ?? this.cwd,
      updatedAt: updatedAt ?? this.updatedAt,
      agentPreset: agentPreset ?? this.agentPreset,
      lastModelId: lastModelId ?? this.lastModelId,
      running: running ?? this.running,
      pendingApproval: pendingApproval ?? this.pendingApproval,
      unread: unread ?? this.unread,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChatSessionItem &&
        other.id == id &&
        other.title == title &&
        other.group == group &&
        other.workspaceId == workspaceId &&
        other.workspaceName == workspaceName &&
        other.cwd == cwd &&
        other.updatedAt == updatedAt &&
        other.agentPreset == agentPreset &&
        other.lastModelId == lastModelId &&
        other.running == running &&
        other.pendingApproval == pendingApproval &&
        other.unread == unread &&
        other.pinned == pinned &&
        other.archived == archived;
  }

  @override
  int get hashCode => Object.hash(
        id,
        title,
        group,
        workspaceId,
        workspaceName,
        cwd,
        updatedAt,
        agentPreset,
        lastModelId,
        running,
        pendingApproval,
        unread,
        pinned,
        archived,
      );
}

@immutable
class PluginItem {
  const PluginItem({
    required this.id,
    required this.name,
    required this.desc,
    required this.version,
    required this.enabled,
    this.removable = true,
    this.optional = true,
    this.readOnlyReason,
  });

  final String id;
  final String name;
  final String desc;
  final String version;
  final bool enabled;
  final bool removable;
  final bool optional;
  final String? readOnlyReason;

  PluginItem copyWith({
    bool? enabled,
    bool? removable,
    bool? optional,
    String? readOnlyReason,
  }) =>
      PluginItem(
        id: id,
        name: name,
        desc: desc,
        version: version,
        enabled: enabled ?? this.enabled,
        removable: removable ?? this.removable,
        optional: optional ?? this.optional,
        readOnlyReason: readOnlyReason ?? this.readOnlyReason,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PluginItem &&
        other.id == id &&
        other.name == name &&
        other.desc == desc &&
        other.version == version &&
        other.enabled == enabled &&
        other.removable == removable &&
        other.optional == optional &&
        other.readOnlyReason == readOnlyReason;
  }

  @override
  int get hashCode =>
      Object.hash(id, name, desc, version, enabled, removable, optional, readOnlyReason);
}

class TerminalTabModel {
  TerminalTabModel({
    required this.id,
    required this.title,
    required this.cwd,
    required this.terminal,
  });

  final String id;
  final String title;
  final String cwd;
  final Terminal terminal;
}

const kPresetOptions = <PresetOption>[
  PresetOption(
    id: 'standard',
    name: '标准模式',
    desc: '均衡思考深度与完整工作区工具，适合日常研发与文件任务',
    isDefault: true,
  ),
  PresetOption(
    id: 'ptc',
    name: '代码编排 (PTC)',
    desc: '通过编程式工具调用批量编排步骤，减少长上下文往返',
  ),
  PresetOption(
    id: 'minimal',
    name: '极简轻量',
    desc: '精简工具集与快速响应，适合轻量问答与单步查询',
  ),
  PresetOption(
    id: 'cordis',
    name: 'Cordis 扩展',
    desc: '启用动态 Cordis 运行时与扩展构建能力，支持按需编写插件',
  ),
];

const kPermissionTiers = <PermissionTier>[
  PermissionTier(
    id: 'read-only',
    name: '只读模式',
    desc: '仅查看文件与检索，禁止修改和执行命令',
  ),
  PermissionTier(
    id: 'workspace-write',
    name: '工作区内修改',
    desc: '读写工作区文件，高风险命令前询问确认',
    isDefault: true,
  ),
  PermissionTier(
    id: 'danger-full-access',
    name: '完全权限',
    desc: '不再逐条询问，适合个人受控环境',
    risky: true,
  ),
];

const kDefaultWorkspaces = <WorkspaceItem>[];

const kEmptyTips = <String>[
  '生成中点击「插话 / 排队」，可以引导当前任务、排队或立刻打断',
  '输入 @ 可快速引用工作区文件，输入 / 唤起快捷指令',
  '在对话中点击顶部标题可随时查看 6 栏工作台：文件、改动、终端、进度、轨迹与子代理',
  '在「设置 → 主机与环境」可局域网扫描、直连远程并一键安装助手组件',
  '点击输入框右下角圆环，可随时查看并一键精简上下文',
  '终端支持多标签后台常驻，切回对话继续聊也不会断线',
];

@immutable
class GrassBagAppState {
  const GrassBagAppState({
    this.isDark = false,
    this.accent = GrassBagAccent.teal,
    this.glassTier = GrassBagGlassTier.liquid,
    this.glassOpticalStrength = 0.50,
    this.tabletSidebarOpen = true,
    this.tabletWorkbenchOpen = false,
    this.activeHostId = 'local',
    this.hosts = const [],
    this.workspaces = const [],
    this.activeWorkspace = '',
    this.sidebarWorkspaceFilter,
    this.activePresetId = 'standard',
    this.activePermissionId = 'workspace-write',
    this.permissionTiers = kPermissionTiers,
    this.planMode = false,
    this.activeModelProvider = '',
    this.activeModelId = '',
    this.modelName = '未连接模型',
    this.modelShort = '未连接',
    this.modelEffort = '',
    this.modelEffortId = '',
    this.modelGroups = const [],
    this.routableProviders = const [],
    this.contextPct = 0,
    this.contextUsedK = 0,
    this.contextMaxK = 128,
    this.contextBreakdown = const {},
    this.sessionTelemetry = const SessionTelemetry(),
    this.filter = SessionFilter.all,
    this.sessionGroupMode = SessionGroupMode.workspace,
    this.searchQuery = '',
    this.sessions = const [],
    this.loadingSessions = false,
    this.searchingSessions = false,
    this.hydratingDomains = false,
    this.initialDomainsHydrated = false,
    this.nativeStatusHydrated = false,
    this.activeSessionId,
    this.turns = const [],
    this.loadingSession = false,
    this.isStreaming = false,
    this.sendStage = SendStage.idle,
    this.uploadDoneCount = 0,
    this.uploadTotalCount = 0,
    this.isStopping = false,
    this.isCompactingContext = false,
    this.streamStalled = false,
    this.parentSessionId,
    this.parentSessionTitle,
    this.activeChildTitle,
    this.activeChildWorktree,
    this.pendingApprovalCommand,
    this.pendingApprovalInteractionId,
    this.pendingApprovalToolName,
    this.activePendingInteractionCount = 0,
    this.activePendingInteractionIndex = 0,
    this.activeQuestion,
    this.activeCordisRequest,
    this.pendingAttachments = const [],
    this.slashCommands = kDefaultSlashCommands,
    this.workspaceFiles = const [],
    this.workspaceCurrentPath = '',
    this.workspaceDiffs = const [],
    this.activeDiffScope = 'uncommitted',
    this.todos = const [],
    this.goals = const [],
    this.subagents = const [],
    this.jobs = const [],
    this.schedules = const [],
    this.marketPlugins = const [],
    this.dynamicCordis = const [],
    this.engineSchema = const {},
    this.engineValues = const {},
    this.presets = kPresetOptions,
    this.dshNamespaces = const [],
    this.dshSettingsSections = const [],
    this.dshDynamicOptions = const {},
    this.updateCheck,
    this.checkingUpdate = false,
    this.appVersion = kGrassBagFallbackVersion,
    this.appBuildNumber = kGrassBagFallbackBuildNumber,
    this.appUpdateInfo,
    this.checkingAppUpdate = false,
    this.appUpdateError,
    this.lastAppUpdateCheckedAt,
    this.skippedAppUpdateVersion,
    this.appUpdateBannerDismissed = false,
    this.appUpdateDownloading = false,
    this.appUpdateDownloadProgress,
    this.appUpdateDownloadBytes = 0,
    this.appUpdateTotalBytes = 0,
    this.appUpdateDownloadSource = '',
    this.appUpdateLocalApkPath,
    this.recentErrors = const [],
    this.providerCredentials = const [],
    this.mcpServers = const [],
    this.containerToolkits = kDefaultContainerToolkits,
    this.queuedMessages = const [],
    this.engineLogs = const [],
    this.accountSnapshot,
    this.sduiSurfaces = const [],
    this.sduiViews = const {},
    this.toolOutputCache = const {},
    this.turnFeedback = const {},
    this.stepTranslations = const {},
    this.hasMoreTurns = false,
    this.turnsNextCursor,
    this.loadingOlderTurns = false,
    this.sessionLoadError,
    this.searchingMarket = false,
    this.marketError,
    this.speechConfigured = false,
    this.searchSnippets = const {},
    this.accountSigningIn = false,
    this.secretRevealed = false,
    this.turnProcessOpen = false,
    this.expandedTurnProcessIds = const {},
    this.collapsedTurnProcessIds = const {},
    this.expandedStepIds = const {},
    this.translatedStepIds = const {},
    this.translatingStepIds = const {},
    this.tipIndex = 0,
    this.plugins = const [],
    this.phoneAccessibility = false,
    this.phoneOverlay = false,
    this.phoneShizuku = false,
    this.phoneConfirmHighRisk = true,
    this.phoneAutoReturn = true,
    this.phoneShowEdgeAurora = true,
    this.phoneShowGestureFx = true,
    this.phoneLiveActive = false,
    this.phoneLivePaused = false,
    this.phoneHandoffReason = '',
    this.phoneLiveAction = '',
    this.phoneLiveApp = '',
    this.phoneLiveSteps = 0,
    this.emergencyStopped = false,
    this.safetyPolicy = 'ask',
    this.safetyAudit = const [],
    this.autoFoldSteps = true,
    this.useSystemProxy = false,
    this.onboardingCompleted = true,
    this.nativeRuntimeStatus = const NativeRuntimeStatus(),
    this.nativePermissions = const NativePermissionsStatus(),
    this.runtimeProgressPct = 0,
    this.runtimeProgressMsg = '',
    this.runtimeProgressStage = '',
    this.runtimeProgressCanCancel = false,
    this.connectionPhase = ConnectionPhase.disconnected,
    this.discoveredLanHosts = const [],
    this.scanningLan = false,
    this.toast,
    this.liveCapabilities,
    this.scrollSignal = 0,
    this.sessionJumpSignal = 0,
    this.sessionRenderGen = 0,
    this.streamTick = 0,
    this.newChatSignal = 0,
    this.focusComposerSignal = 0,
    this.draftHydratedSignal = 0,
    this.openJobsSignal = 0,
    this.pendingInteractions = const [],
    this.pendingOutbox = const [],
    this.offlineUnsentNotice,
    this.pendingPairDeepLinkUri,
  });

  final bool isDark;
  final GrassBagAccent accent;
  final GrassBagGlassTier glassTier;
  final double glassOpticalStrength;
  final bool tabletSidebarOpen;
  final bool tabletWorkbenchOpen;
  final String activeHostId;
  final List<ManagedHost> hosts;
  final List<WorkspaceItem> workspaces;
  final String activeWorkspace;
  final String? sidebarWorkspaceFilter;
  final String activePresetId;
  final String activePermissionId;
  final List<PermissionTier> permissionTiers;
  final bool planMode;
  final String activeModelProvider;
  final String activeModelId;
  final String modelName;
  final String modelShort;
  final String modelEffort;
  final String modelEffortId;
  final List<ModelCatalogGroup> modelGroups;
  final List<String> routableProviders;
  final int contextPct;
  final double contextUsedK;
  final int contextMaxK;
  final Map<String, int> contextBreakdown;
  final SessionTelemetry sessionTelemetry;
  final SessionFilter filter;
  final SessionGroupMode sessionGroupMode;
  final String searchQuery;
  final List<ChatSessionItem> sessions;
  final bool loadingSessions;
  final bool searchingSessions;
  final bool hydratingDomains;
  final bool initialDomainsHydrated;
  final bool nativeStatusHydrated;
  final String? activeSessionId;
  final List<NormalizedTurn> turns;
  final bool loadingSession;
  final bool isStreaming;
  final SendStage sendStage;
  final int uploadDoneCount;
  final int uploadTotalCount;
  final bool isStopping;
  final bool isCompactingContext;
  final bool streamStalled;
  final String? parentSessionId;
  final String? parentSessionTitle;
  final String? activeChildTitle;
  final String? activeChildWorktree;
  final String? pendingApprovalCommand;
  final String? pendingApprovalInteractionId;
  final String? pendingApprovalToolName;
  final int activePendingInteractionCount;
  final int activePendingInteractionIndex;
  final ActiveUserQuestion? activeQuestion;
  final ActiveCordisRunRequest? activeCordisRequest;
  final List<ComposerAttachment> pendingAttachments;
  final List<SlashCommandItem> slashCommands;
  final List<WorkspaceFileNode> workspaceFiles;
  final String workspaceCurrentPath;
  final List<WorkspaceDiffRecord> workspaceDiffs;
  final String activeDiffScope;
  final List<SessionTodoRecord> todos;
  final List<SessionGoalRecord> goals;
  final List<SubagentItem> subagents;
  final List<BackgroundJobRecord> jobs;
  final List<ScheduleTaskRecord> schedules;
  final List<PluginMarketEntry> marketPlugins;
  final List<DynamicCordisEntry> dynamicCordis;
  final Map<String, dynamic> engineSchema;
  final Map<String, dynamic> engineValues;
  final List<PresetOption> presets;
  final List<DshSettingsNamespace> dshNamespaces;
  final List<DshSettingsSectionManifest> dshSettingsSections;
  final Map<String, List<DshDynamicOption>> dshDynamicOptions;
  final DshUpdateCheckResult? updateCheck;
  final bool checkingUpdate;
  final String appVersion;
  final int appBuildNumber;
  final AppReleaseInfo? appUpdateInfo;
  final bool checkingAppUpdate;
  final String? appUpdateError;
  final DateTime? lastAppUpdateCheckedAt;
  final String? skippedAppUpdateVersion;
  final bool appUpdateBannerDismissed;
  final bool appUpdateDownloading;
  final double? appUpdateDownloadProgress;
  final int appUpdateDownloadBytes;
  final int appUpdateTotalBytes;
  final String appUpdateDownloadSource;
  final String? appUpdateLocalApkPath;
  final List<AppErrorRecord> recentErrors;
  final List<ProviderCredentialItem> providerCredentials;
  final List<McpServerItem> mcpServers;
  final List<ContainerToolkitItem> containerToolkits;
  final List<QueuedMessageItem> queuedMessages;
  final List<String> engineLogs;
  final Map<String, dynamic>? accountSnapshot;
  final List<SduiSurfaceMeta> sduiSurfaces;
  final Map<String, SduiView> sduiViews;
  final Map<String, String> toolOutputCache;
  final Map<String, String> turnFeedback; // "$sessionId:$turnId" -> 'up' | 'down'
  final Map<String, String> stepTranslations; // stepId -> translated Chinese CoT
  final bool hasMoreTurns;
  final String? turnsNextCursor;
  final bool loadingOlderTurns;
  final String? sessionLoadError;
  final bool searchingMarket;
  final String? marketError;
  final bool speechConfigured;
  final Map<String, String> searchSnippets; // sessionId -> search hit snippet
  final bool accountSigningIn;
  final bool secretRevealed;
  final bool turnProcessOpen;
  final Set<String> expandedTurnProcessIds;
  final Set<String> collapsedTurnProcessIds;
  final Set<String> expandedStepIds;
  final Set<String> translatedStepIds;
  final Set<String> translatingStepIds;
  final int tipIndex;
  final List<PluginItem> plugins;
  final bool phoneAccessibility;
  final bool phoneOverlay;
  final bool phoneShizuku;
  final bool phoneConfirmHighRisk;
  final bool phoneAutoReturn;
  final bool phoneShowEdgeAurora;
  final bool phoneShowGestureFx;
  final bool phoneLiveActive;
  final bool phoneLivePaused;
  final String phoneHandoffReason;
  final String phoneLiveAction;
  final String phoneLiveApp;
  final int phoneLiveSteps;
  final bool emergencyStopped;
  final String safetyPolicy;
  final List<Map<String, dynamic>> safetyAudit;
  final bool autoFoldSteps;
  final bool useSystemProxy;
  final bool onboardingCompleted;
  final NativeRuntimeStatus nativeRuntimeStatus;
  final NativePermissionsStatus nativePermissions;
  final int runtimeProgressPct;
  final String runtimeProgressMsg;
  final String runtimeProgressStage;
  final bool runtimeProgressCanCancel;
  final ConnectionPhase connectionPhase;
  final List<DiscoveredLanHost> discoveredLanHosts;
  final bool scanningLan;
  final GrassBagToastMessage? toast;
  final Capabilities? liveCapabilities;
  final int scrollSignal;
  final int sessionJumpSignal;
  final int sessionRenderGen;
  final int streamTick;
  final int newChatSignal;
  final int focusComposerSignal;
  final int draftHydratedSignal;
  final int openJobsSignal;
  final List<PendingInteraction> pendingInteractions;
  final List<PendingOutboxItem> pendingOutbox;
  final String? offlineUnsentNotice;
  final String? pendingPairDeepLinkUri;

  List<BackgroundJobRecord> get failedJobs => jobs
      .where((j) {
        final st = j.status.toLowerCase();
        return st.contains('fail') || st.contains('error');
      })
      .toList(growable: false);

  List<PendingOutboxItem> get unsentOutboxForActiveHost => pendingOutbox
      .where((o) => o.hostId == activeHostId && o.status != 'sending')
      .toList(growable: false);

  int get pendingInboxCount =>
      pendingInteractions.length + failedJobs.length + unsentOutboxForActiveHost.length;

  String get appVersionLabel => '$appVersion ($appBuildNumber)';

  bool get hasAppUpdate =>
      appUpdateInfo != null &&
      isRemoteReleaseNewer(
        currentVersion: appVersion,
        currentBuild: appBuildNumber,
        remote: appUpdateInfo!,
      );

  bool get hasUnignoredAppUpdate =>
      hasAppUpdate && skippedAppUpdateVersion != appUpdateInfo!.versionKey;

  bool get showAppUpdateBanner => hasUnignoredAppUpdate && !appUpdateBannerDismissed;

  ManagedHost get activeHost => hosts.firstWhere(
        (h) => h.id == activeHostId,
        orElse: () => hosts.first,
      );

  ManagedHost get localHost => hosts.firstWhere(
        (h) => h.isLocal,
        orElse: () => hosts.first,
      );

  PresetOption get activePreset => presets.firstWhere(
        (p) => p.id == activePresetId,
        orElse: () => presets.isNotEmpty ? presets.first : kPresetOptions.first,
      );

  /// DSH is the single source of truth for all DSH configuration namespaces.
  /// Never fabricate offline fallback namespaces when disconnected from DSH.
  List<DshSettingsNamespace> get effectiveDshNamespaces => dshNamespaces;

  bool get isDshConnected =>
      connectionPhase == ConnectionPhase.connected && activeHost.isConnectedUsable;

  List<PermissionTier> get effectivePermissionTiers =>
      permissionTiers.isNotEmpty ? permissionTiers : kPermissionTiers;

  PermissionTier get activePermission => effectivePermissionTiers.firstWhere(
        (p) => p.id == activePermissionId,
        orElse: () => effectivePermissionTiers.first,
      );

  bool get hasAvailableModels => modelGroups.any((g) => g.models.isNotEmpty);

  ModelCatalogEntry? get firstAvailableModel {
    for (final g in modelGroups) {
      if (g.routable && g.models.isNotEmpty) return g.models.first;
    }
    for (final g in modelGroups) {
      if (g.models.isNotEmpty) return g.models.first;
    }
    return null;
  }

  ModelCatalogEntry? get activeModelEntry {
    if (activeModelId.isEmpty) return null;
    for (final g in modelGroups) {
      if (activeModelProvider.isNotEmpty && g.id != activeModelProvider) continue;
      for (final m in g.models) {
        if (m.id == activeModelId) return m;
      }
    }
    if (activeModelProvider.isNotEmpty) {
      for (final g in modelGroups) {
        for (final m in g.models) {
          if (m.id == activeModelId) return m;
        }
      }
    }
    return null;
  }

  /// Guaranteed non-null whenever [modelGroups] has at least one model; null only when empty.
  ModelCatalogEntry? get effectiveActiveModelEntry => activeModelEntry ?? firstAvailableModel;

  WorkspaceItem? get activeWorkspaceItem {
    if (activeWorkspace.isEmpty) {
      return workspaces.isNotEmpty ? workspaces.first : null;
    }
    for (final w in workspaces) {
      if (w.id == activeWorkspace) return w;
    }
    for (final w in workspaces) {
      if (w.path.isNotEmpty && w.path == activeWorkspace) return w;
    }
    for (final w in workspaces) {
      if (w.name == activeWorkspace) return w;
    }
    return workspaces.isNotEmpty ? workspaces.first : null;
  }

  /// Human-readable display name for the active workspace (never leaks a raw workspace UUID!).
  String get activeWorkspaceDisplayName {
    final item = activeWorkspaceItem;
    if (item != null && item.name.isNotEmpty) return item.name;
    return activeWorkspace;
  }

  String get accountStatus {
    final s = accountSnapshot?['state'];
    if (s is Map && s['status'] != null) return s['status'].toString();
    return 'unknown';
  }

  bool get isAccountSignedIn =>
      accountStatus == 'credential-stored' || accountStatus == 'signed-in';

  String get accountDisplayName {
    final rawProf = accountSnapshot?['profile'];
    if (rawProf is Map) {
      final prof = rawProf['value'] is Map ? rawProf['value'] as Map : rawProf;
      final label = prof['name'] ?? prof['contact'] ?? prof['email'] ?? prof['phone'];
      if (label != null && label.toString().trim().isNotEmpty) {
        return label.toString().trim();
      }
    }
    return isAccountSignedIn ? 'DeepSeek 账户' : '未登录';
  }

  static String _formatCurrencyAmount(dynamic raw) {
    if (raw == null) return '';
    if (raw is num) return raw.toDouble().toStringAsFixed(2);
    final str = raw.toString().trim();
    if (str.isEmpty) return '';
    final parsed = double.tryParse(str);
    if (parsed != null) return parsed.toStringAsFixed(2);
    return str;
  }

  String get accountBalanceText {
    final rawBal = accountSnapshot?['balance'];
    if (rawBal is Map) {
      final listVal = rawBal['value'];
      if (listVal is List && listVal.isNotEmpty) {
        final parts = <String>[];
        for (final entry in listVal) {
          if (entry is! Map) continue;
          final amount = entry['balance'] ?? entry['total'] ?? entry['available'];
          if (amount == null) continue;
          final formatted = _formatCurrencyAmount(amount);
          if (formatted.isEmpty) continue;
          final currRaw = entry['currency']?.toString().toUpperCase() ?? 'CNY';
          final sym = currRaw == 'USD' ? '\$' : (currRaw == 'CNY' ? '¥' : '$currRaw ');
          parts.add('$sym$formatted');
        }
        if (parts.isNotEmpty) return parts.join(' · ');
      }
      final total = rawBal['total'] ?? rawBal['balance'] ?? rawBal['available'];
      if (total != null) {
        final formatted = _formatCurrencyAmount(total);
        final currRaw = rawBal['currency']?.toString().toUpperCase() ?? 'CNY';
        final sym = currRaw == 'USD' ? '\$' : (currRaw == 'CNY' || currRaw == '¥' ? '¥' : '$currRaw ');
        return '$sym$formatted';
      }
    }
    return '';
  }

  String get accountSummaryLabel {
    if (accountSnapshot == null) {
      return connectionPhase == ConnectionPhase.connected ? '未登录' : '未连接主机';
    }
    if (!isAccountSignedIn) return '未登录';
    final balText = accountBalanceText;
    if (balText.isNotEmpty) return '余额 $balText';
    final name = accountDisplayName;
    if (name.isNotEmpty && name != '未登录') return name;
    return '已登录';
  }

  ChatSessionItem? get activeSession {
    if (activeSessionId == null) return null;
    for (final s in sessions) {
      if (s.id == activeSessionId) return s;
    }
    return null;
  }

  bool get isEmptyChat => activeSessionId == null && turns.isEmpty;

  bool get isCreatingSession => activeSessionId?.startsWith('pending-session-') == true;

  int get activeScheduleCount => schedules.where((s) => s.enabled).length;
  int get runningJobsCount => jobs.where((j) => j.status == 'running').length;

  bool get isActiveHostDesktop =>
      !activeHost.isLocal ||
      (liveCapabilities != null && !liveCapabilities!.host.isLocalAndroid) ||
      kIsWeb;

  bool hostIsHealthy(ManagedHost host) {
    if (host.isLocal && !kIsWeb && GrassBagNativeBridge.instance.isAndroidNative) {
      return nativeRuntimeStatus.engineRunning && host.bridged;
    }
    return (host.bridged || host.directMode) && host.online;
  }

  bool hostHasError(ManagedHost host) {
    if (host.isLocal && !kIsWeb && GrassBagNativeBridge.instance.isAndroidNative) {
      return nativeRuntimeStatus.engineState == 'error' ||
          (host.lastError != null && host.lastError!.isNotEmpty);
    }
    // Missing token / waiting for one-time auth is a normal guided state, NEVER a red error!
    if (host.needsAuth) return false;
    return host.lastError != null && host.lastError!.isNotEmpty;
  }

  bool hostIsConnecting(ManagedHost host) {
    if (host.id != activeHostId) return false;
    if (connectionPhase == ConnectionPhase.connecting ||
        connectionPhase == ConnectionPhase.reconnecting ||
        connectionPhase == ConnectionPhase.bootstrapping) {
      return true;
    }
    if (host.isLocal &&
        !kIsWeb &&
        GrassBagNativeBridge.instance.isAndroidNative &&
        (!nativeStatusHydrated ||
            nativeRuntimeStatus.engineState == 'starting' ||
            (runtimeProgressPct > 0 && runtimeProgressPct < 100))) {
      return true;
    }
    return false;
  }

  String hostStatusLabel(ManagedHost host) {
    if (host.isLocal && !kIsWeb && GrassBagNativeBridge.instance.isAndroidNative) {
      final rt = nativeRuntimeStatus;
      if (runtimeProgressPct > 0 && runtimeProgressPct < 100) {
        return runtimeProgressCanCancel
            ? '正在下载运行环境 $runtimeProgressPct%…'
            : '正在部署容器 $runtimeProgressPct%…';
      }
      if (!rt.initialized) {
        if (!rt.hasBundledRuntimePayloads) {
          return rt.hasPartialDownload
              ? '待继续下载 · 剩余 ${rt.formattedDownloadSize}'
              : '未下载环境 · 约 ${rt.formattedDownloadSize}';
        }
        return '容器未初始化 · 待部署';
      }
      if (rt.engineState == 'starting') return '正在启动本机 DSH 引擎…';
      if (rt.engineState == 'error') return '启动异常 · 点击查看日志';
      if (rt.engineRunning && host.bridged) return 'DSH ${host.dshVersion} · 运行中';
      if (rt.engineRunning) return '引擎已就绪 · 正在接入…';
      return '容器已就绪 · 待启动';
    }
    if (host.isLocal) {
      if (host.bridged) return 'DSH ${host.dshVersion} · 运行中';
      if (host.id == activeHostId && connectionPhase == ConnectionPhase.reconnecting) {
        return '正在重连本机 DSH…';
      }
      if (host.id == activeHostId && connectionPhase == ConnectionPhase.connecting) {
        return '正在连接本机 DSH…';
      }
      if (host.lastError != null && host.lastError!.isNotEmpty) return '未连接 · 点击检查服务';
      return '等待连接本机 DSH';
    }
    if (host.bridged && host.online) return '${host.latency} · 增强模式';
    if (host.directMode && host.online) return '${host.latency} · 原生直连 (免插件)';
    if (host.id == activeHostId && connectionPhase == ConnectionPhase.reconnecting) {
      return '正在重连…';
    }
    if (host.id == activeHostId &&
        (connectionPhase == ConnectionPhase.connecting ||
            connectionPhase == ConnectionPhase.bootstrapping)) {
      return '正在连接…';
    }
    if (host.lastErrorCode == 'untrusted_host') return '远程 Host 限制 · 需指定局域网 IP';
    if (host.lastErrorCode == 'tls_cert') return 'HTTPS 证书未受信任';
    if (host.isHtmlProxyAuth) return '已连通 · 请通过网页登录完成授权';
    if (host.needsAuth) return '已连通 · 完成一次授权后 30 天免填';
    if (!host.online) return '未连接';
    return '原生直连 · DSH ${host.dshVersion}';
  }

  String hostStatusBadge(ManagedHost host) {
    if (host.isLocal && !kIsWeb && GrassBagNativeBridge.instance.isAndroidNative) {
      final rt = nativeRuntimeStatus;
      if (runtimeProgressPct > 0 && runtimeProgressPct < 100) {
        return runtimeProgressCanCancel ? '下载中 $runtimeProgressPct%' : '部署中 $runtimeProgressPct%';
      }
      if (!rt.initialized) {
        return !rt.hasBundledRuntimePayloads
            ? (rt.hasPartialDownload ? '待续传' : '待下载')
            : '未初始化';
      }
      if (rt.engineState == 'starting') return '启动中';
      if (rt.engineState == 'error') return '启动异常';
      if (rt.engineRunning) return host.bridged ? '运行中' : '接入中';
      return '待启动';
    }
    if (host.isLocal) {
      if (host.bridged) return '运行中';
      if (host.id == activeHostId && connectionPhase == ConnectionPhase.reconnecting) return '重连中';
      if (host.id == activeHostId && connectionPhase == ConnectionPhase.connecting) return '连接中';
      return '未连接';
    }
    if (host.bridged && host.online) return '增强模式';
    if (host.directMode && host.online) return '原生直连';
    if (host.id == activeHostId && connectionPhase == ConnectionPhase.reconnecting) return '重连中';
    if (host.id == activeHostId &&
        (connectionPhase == ConnectionPhase.connecting ||
            connectionPhase == ConnectionPhase.bootstrapping)) {
      return '连接中';
    }
    if (host.lastErrorCode == 'untrusted_host') return 'Host 受限';
    if (host.lastErrorCode == 'tls_cert') return '证书异常';
    if (host.lastErrorCode == 'needs_auth' || host.lastErrorCode == 'html_proxy') {
      return '待鉴权';
    }
    final err = (host.lastError ?? '').toLowerCase();
    if (err.contains('401') || err.contains('403') || err.contains('unauthorized')) {
      return '待鉴权';
    }
    return host.online ? '原生直连' : '离线';
  }

  List<ChatSessionItem> get filteredSessions {
    final q = searchQuery.trim().toLowerCase();
    final wsFilter = sidebarWorkspaceFilter?.trim() ?? '';
    WorkspaceItem? filterWsItem;
    if (wsFilter.isNotEmpty) {
      for (final w in workspaces) {
        if (w.id == wsFilter || w.name == wsFilter || w.path == wsFilter) {
          filterWsItem = w;
          break;
        }
      }
    }
    final matched = sessions.where((s) {
      if (wsFilter.isNotEmpty) {
        final matchWs = (filterWsItem != null &&
                (s.workspaceId == filterWsItem.id ||
                    s.workspaceName == filterWsItem.name ||
                    (filterWsItem.path.isNotEmpty && s.cwd == filterWsItem.path))) ||
            s.workspaceId == wsFilter ||
            s.workspaceName == wsFilter ||
            s.cwd == wsFilter ||
            (s.cwd != null &&
                s.cwd!.isNotEmpty &&
                GrassBagController._basenamePath(s.cwd!) == wsFilter);
        if (!matchWs) return false;
      }
      if (q.isNotEmpty &&
          !s.title.toLowerCase().contains(q) &&
          !(s.workspaceName?.toLowerCase().contains(q) ?? false) &&
          !(s.cwd?.toLowerCase().contains(q) ?? false) &&
          !searchSnippets.containsKey(s.id)) {
        return false;
      }
      return switch (filter) {
        SessionFilter.all => !s.archived,
        SessionFilter.running => !s.archived && s.running,
        SessionFilter.pending => !s.archived && s.pendingApproval,
        SessionFilter.unread => !s.archived && s.unread,
        SessionFilter.archived => s.archived,
      };
    }).toList();
    matched.sort((a, b) {
      final pinCmp = (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0);
      if (pinCmp != 0) return pinCmp;
      final tsCmp = (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0);
      return tsCmp != 0 ? tsCmp : a.id.compareTo(b.id);
    });
    return matched;
  }

  GrassBagAppState copyWith({
    bool? isDark,
    GrassBagAccent? accent,
    GrassBagGlassTier? glassTier,
    double? glassOpticalStrength,
    bool? tabletSidebarOpen,
    bool? tabletWorkbenchOpen,
    String? activeHostId,
    List<ManagedHost>? hosts,
    List<WorkspaceItem>? workspaces,
    String? activeWorkspace,
    String? sidebarWorkspaceFilter,
    bool clearSidebarWorkspaceFilter = false,
    String? activePresetId,
    String? activePermissionId,
    List<PermissionTier>? permissionTiers,
    bool? planMode,
    String? activeModelProvider,
    String? activeModelId,
    String? modelName,
    String? modelShort,
    String? modelEffort,
    String? modelEffortId,
    List<ModelCatalogGroup>? modelGroups,
    List<String>? routableProviders,
    int? contextPct,
    double? contextUsedK,
    int? contextMaxK,
    Map<String, int>? contextBreakdown,
    SessionTelemetry? sessionTelemetry,
    SessionFilter? filter,
    SessionGroupMode? sessionGroupMode,
    String? searchQuery,
    List<ChatSessionItem>? sessions,
    bool? loadingSessions,
    bool? searchingSessions,
    bool? hydratingDomains,
    bool? initialDomainsHydrated,
    bool? nativeStatusHydrated,
    String? activeSessionId,
    bool clearActiveSession = false,
    List<NormalizedTurn>? turns,
    bool? loadingSession,
    bool? isStreaming,
    SendStage? sendStage,
    int? uploadDoneCount,
    int? uploadTotalCount,
    bool? isStopping,
    bool? isCompactingContext,
    bool? streamStalled,
    String? parentSessionId,
    String? parentSessionTitle,
    String? activeChildTitle,
    String? activeChildWorktree,
    bool clearParentSession = false,
    String? pendingApprovalCommand,
    String? pendingApprovalInteractionId,
    String? pendingApprovalToolName,
    int? activePendingInteractionCount,
    int? activePendingInteractionIndex,
    bool clearPendingApproval = false,
    ActiveUserQuestion? activeQuestion,
    bool clearActiveQuestion = false,
    ActiveCordisRunRequest? activeCordisRequest,
    bool clearActiveCordisRequest = false,
    List<ComposerAttachment>? pendingAttachments,
    List<SlashCommandItem>? slashCommands,
    List<WorkspaceFileNode>? workspaceFiles,
    String? workspaceCurrentPath,
    List<WorkspaceDiffRecord>? workspaceDiffs,
    String? activeDiffScope,
    List<SessionTodoRecord>? todos,
    List<SessionGoalRecord>? goals,
    List<SubagentItem>? subagents,
    List<BackgroundJobRecord>? jobs,
    List<ScheduleTaskRecord>? schedules,
    List<PluginMarketEntry>? marketPlugins,
    List<DynamicCordisEntry>? dynamicCordis,
    Map<String, dynamic>? engineSchema,
    Map<String, dynamic>? engineValues,
    List<PresetOption>? presets,
    List<DshSettingsNamespace>? dshNamespaces,
    List<DshSettingsSectionManifest>? dshSettingsSections,
    Map<String, List<DshDynamicOption>>? dshDynamicOptions,
    DshUpdateCheckResult? updateCheck,
    bool? checkingUpdate,
    String? appVersion,
    int? appBuildNumber,
    AppReleaseInfo? appUpdateInfo,
    bool clearAppUpdateInfo = false,
    bool? checkingAppUpdate,
    String? appUpdateError,
    bool clearAppUpdateError = false,
    DateTime? lastAppUpdateCheckedAt,
    String? skippedAppUpdateVersion,
    bool clearSkippedAppUpdateVersion = false,
    bool? appUpdateBannerDismissed,
    bool? appUpdateDownloading,
    double? appUpdateDownloadProgress,
    bool clearAppUpdateDownloadProgress = false,
    int? appUpdateDownloadBytes,
    int? appUpdateTotalBytes,
    String? appUpdateDownloadSource,
    String? appUpdateLocalApkPath,
    bool clearAppUpdateLocalApkPath = false,
    List<AppErrorRecord>? recentErrors,
    List<ProviderCredentialItem>? providerCredentials,
    List<McpServerItem>? mcpServers,
    List<ContainerToolkitItem>? containerToolkits,
    List<QueuedMessageItem>? queuedMessages,
    List<String>? engineLogs,
    Map<String, dynamic>? accountSnapshot,
    bool clearAccountSnapshot = false,
    List<SduiSurfaceMeta>? sduiSurfaces,
    Map<String, SduiView>? sduiViews,
    Map<String, String>? toolOutputCache,
    Map<String, String>? turnFeedback,
    Map<String, String>? stepTranslations,
    bool? hasMoreTurns,
    String? turnsNextCursor,
    bool clearTurnsNextCursor = false,
    bool? loadingOlderTurns,
    String? sessionLoadError,
    bool clearSessionLoadError = false,
    bool? searchingMarket,
    String? marketError,
    bool clearMarketError = false,
    bool? speechConfigured,
    Map<String, String>? searchSnippets,
    bool? accountSigningIn,
    bool clearUpdateCheck = false,
    bool? secretRevealed,
    bool? turnProcessOpen,
    Set<String>? expandedTurnProcessIds,
    Set<String>? collapsedTurnProcessIds,
    Set<String>? expandedStepIds,
    Set<String>? translatedStepIds,
    Set<String>? translatingStepIds,
    int? tipIndex,
    List<PluginItem>? plugins,
    bool? phoneAccessibility,
    bool? phoneOverlay,
    bool? phoneShizuku,
    bool? phoneConfirmHighRisk,
    bool? phoneAutoReturn,
    bool? phoneShowEdgeAurora,
    bool? phoneShowGestureFx,
    bool? phoneLiveActive,
    bool? phoneLivePaused,
    String? phoneHandoffReason,
    String? phoneLiveAction,
    String? phoneLiveApp,
    int? phoneLiveSteps,
    bool? emergencyStopped,
    String? safetyPolicy,
    List<Map<String, dynamic>>? safetyAudit,
    bool? autoFoldSteps,
    bool? useSystemProxy,
    bool? onboardingCompleted,
    NativeRuntimeStatus? nativeRuntimeStatus,
    NativePermissionsStatus? nativePermissions,
    int? runtimeProgressPct,
    String? runtimeProgressMsg,
    String? runtimeProgressStage,
    bool? runtimeProgressCanCancel,
    ConnectionPhase? connectionPhase,
    List<DiscoveredLanHost>? discoveredLanHosts,
    bool? scanningLan,
    GrassBagToastMessage? toast,
    bool clearToast = false,
    Capabilities? liveCapabilities,
    bool clearLiveCapabilities = false,
    int? scrollSignal,
    int? sessionJumpSignal,
    int? sessionRenderGen,
    int? streamTick,
    int? newChatSignal,
    int? focusComposerSignal,
    int? draftHydratedSignal,
    int? openJobsSignal,
    List<PendingInteraction>? pendingInteractions,
    List<PendingOutboxItem>? pendingOutbox,
    String? offlineUnsentNotice,
    bool clearOfflineUnsentNotice = false,
    String? pendingPairDeepLinkUri,
    bool clearPendingPairDeepLinkUri = false,
  }) {
    return GrassBagAppState(
      isDark: isDark ?? this.isDark,
      accent: accent ?? this.accent,
      glassTier: glassTier ?? this.glassTier,
      glassOpticalStrength: glassOpticalStrength ?? this.glassOpticalStrength,
      tabletSidebarOpen: tabletSidebarOpen ?? this.tabletSidebarOpen,
      tabletWorkbenchOpen: tabletWorkbenchOpen ?? this.tabletWorkbenchOpen,
      activeHostId: activeHostId ?? this.activeHostId,
      hosts: hosts ?? this.hosts,
      workspaces: workspaces ?? this.workspaces,
      activeWorkspace: activeWorkspace ?? this.activeWorkspace,
      sidebarWorkspaceFilter: clearSidebarWorkspaceFilter
          ? null
          : (sidebarWorkspaceFilter ?? this.sidebarWorkspaceFilter),
      activePresetId: activePresetId ?? this.activePresetId,
      activePermissionId: activePermissionId ?? this.activePermissionId,
      permissionTiers: permissionTiers ?? this.permissionTiers,
      planMode: planMode ?? this.planMode,
      activeModelProvider: activeModelProvider ?? this.activeModelProvider,
      activeModelId: activeModelId ?? this.activeModelId,
      modelName: modelName ?? this.modelName,
      modelShort: modelShort ?? this.modelShort,
      modelEffort: modelEffort ?? this.modelEffort,
      modelEffortId: modelEffortId ?? this.modelEffortId,
      modelGroups: modelGroups ?? this.modelGroups,
      routableProviders: routableProviders ?? this.routableProviders,
      contextPct: contextPct ?? this.contextPct,
      contextUsedK: contextUsedK ?? this.contextUsedK,
      contextMaxK: contextMaxK ?? this.contextMaxK,
      contextBreakdown: contextBreakdown ?? this.contextBreakdown,
      sessionTelemetry: sessionTelemetry ?? this.sessionTelemetry,
      filter: filter ?? this.filter,
      sessionGroupMode: sessionGroupMode ?? this.sessionGroupMode,
      searchQuery: searchQuery ?? this.searchQuery,
      sessions: sessions ?? this.sessions,
      loadingSessions: loadingSessions ?? this.loadingSessions,
      searchingSessions: searchingSessions ?? this.searchingSessions,
      hydratingDomains: hydratingDomains ?? this.hydratingDomains,
      initialDomainsHydrated: initialDomainsHydrated ?? this.initialDomainsHydrated,
      nativeStatusHydrated: nativeStatusHydrated ?? this.nativeStatusHydrated,
      activeSessionId: clearActiveSession ? null : (activeSessionId ?? this.activeSessionId),
      turns: turns ?? this.turns,
      loadingSession: loadingSession ?? this.loadingSession,
      isStreaming: isStreaming ?? this.isStreaming,
      sendStage: sendStage ?? this.sendStage,
      uploadDoneCount: uploadDoneCount ?? this.uploadDoneCount,
      uploadTotalCount: uploadTotalCount ?? this.uploadTotalCount,
      isStopping: isStopping ?? this.isStopping,
      isCompactingContext: isCompactingContext ?? this.isCompactingContext,
      streamStalled: streamStalled ?? this.streamStalled,
      parentSessionId: clearParentSession ? null : (parentSessionId ?? this.parentSessionId),
      parentSessionTitle: clearParentSession ? null : (parentSessionTitle ?? this.parentSessionTitle),
      activeChildTitle: clearParentSession ? null : (activeChildTitle ?? this.activeChildTitle),
      activeChildWorktree: clearParentSession ? null : (activeChildWorktree ?? this.activeChildWorktree),
      pendingApprovalCommand: clearPendingApproval
          ? null
          : (pendingApprovalCommand ?? this.pendingApprovalCommand),
      pendingApprovalInteractionId: clearPendingApproval
          ? null
          : (pendingApprovalInteractionId ?? this.pendingApprovalInteractionId),
      pendingApprovalToolName: clearPendingApproval
          ? null
          : (pendingApprovalToolName ?? this.pendingApprovalToolName),
      activePendingInteractionCount:
          activePendingInteractionCount ?? this.activePendingInteractionCount,
      activePendingInteractionIndex:
          activePendingInteractionIndex ?? this.activePendingInteractionIndex,
      activeQuestion:
          clearActiveQuestion ? null : (activeQuestion ?? this.activeQuestion),
      activeCordisRequest: clearActiveCordisRequest
          ? null
          : (activeCordisRequest ?? this.activeCordisRequest),
      pendingAttachments: pendingAttachments ?? this.pendingAttachments,
      slashCommands: slashCommands ?? this.slashCommands,
      workspaceFiles: workspaceFiles ?? this.workspaceFiles,
      workspaceCurrentPath: workspaceCurrentPath ?? this.workspaceCurrentPath,
      workspaceDiffs: workspaceDiffs ?? this.workspaceDiffs,
      activeDiffScope: activeDiffScope ?? this.activeDiffScope,
      todos: todos ?? this.todos,
      goals: goals ?? this.goals,
      subagents: subagents ?? this.subagents,
      jobs: jobs ?? this.jobs,
      schedules: schedules ?? this.schedules,
      marketPlugins: marketPlugins ?? this.marketPlugins,
      dynamicCordis: dynamicCordis ?? this.dynamicCordis,
      engineSchema: engineSchema ?? this.engineSchema,
      engineValues: engineValues ?? this.engineValues,
      presets: presets ?? this.presets,
      dshNamespaces: dshNamespaces ?? this.dshNamespaces,
      dshSettingsSections: dshSettingsSections ?? this.dshSettingsSections,
      dshDynamicOptions: dshDynamicOptions ?? this.dshDynamicOptions,
      updateCheck: clearUpdateCheck ? null : (updateCheck ?? this.updateCheck),
      checkingUpdate: checkingUpdate ?? this.checkingUpdate,
      appVersion: appVersion ?? this.appVersion,
      appBuildNumber: appBuildNumber ?? this.appBuildNumber,
      appUpdateInfo: clearAppUpdateInfo ? null : (appUpdateInfo ?? this.appUpdateInfo),
      checkingAppUpdate: checkingAppUpdate ?? this.checkingAppUpdate,
      appUpdateError: clearAppUpdateError ? null : (appUpdateError ?? this.appUpdateError),
      lastAppUpdateCheckedAt: lastAppUpdateCheckedAt ?? this.lastAppUpdateCheckedAt,
      skippedAppUpdateVersion: clearSkippedAppUpdateVersion
          ? null
          : (skippedAppUpdateVersion ?? this.skippedAppUpdateVersion),
      appUpdateBannerDismissed: appUpdateBannerDismissed ?? this.appUpdateBannerDismissed,
      appUpdateDownloading: appUpdateDownloading ?? this.appUpdateDownloading,
      appUpdateDownloadProgress: clearAppUpdateDownloadProgress
          ? null
          : (appUpdateDownloadProgress ?? this.appUpdateDownloadProgress),
      appUpdateDownloadBytes: appUpdateDownloadBytes ?? this.appUpdateDownloadBytes,
      appUpdateTotalBytes: appUpdateTotalBytes ?? this.appUpdateTotalBytes,
      appUpdateDownloadSource: appUpdateDownloadSource ?? this.appUpdateDownloadSource,
      appUpdateLocalApkPath: clearAppUpdateLocalApkPath
          ? null
          : (appUpdateLocalApkPath ?? this.appUpdateLocalApkPath),
      recentErrors: recentErrors ?? this.recentErrors,
      providerCredentials: providerCredentials ?? this.providerCredentials,
      mcpServers: mcpServers ?? this.mcpServers,
      containerToolkits: containerToolkits ?? this.containerToolkits,
      queuedMessages: queuedMessages ?? this.queuedMessages,
      engineLogs: engineLogs ?? this.engineLogs,
      accountSnapshot:
          clearAccountSnapshot ? null : (accountSnapshot ?? this.accountSnapshot),
      sduiSurfaces: sduiSurfaces ?? this.sduiSurfaces,
      sduiViews: sduiViews ?? this.sduiViews,
      toolOutputCache: toolOutputCache ?? this.toolOutputCache,
      turnFeedback: turnFeedback ?? this.turnFeedback,
      stepTranslations: stepTranslations ?? this.stepTranslations,
      hasMoreTurns: hasMoreTurns ?? this.hasMoreTurns,
      turnsNextCursor: clearTurnsNextCursor ? null : (turnsNextCursor ?? this.turnsNextCursor),
      loadingOlderTurns: loadingOlderTurns ?? this.loadingOlderTurns,
      sessionLoadError: clearSessionLoadError ? null : (sessionLoadError ?? this.sessionLoadError),
      searchingMarket: searchingMarket ?? this.searchingMarket,
      marketError: clearMarketError ? null : (marketError ?? this.marketError),
      speechConfigured: speechConfigured ?? this.speechConfigured,
      searchSnippets: searchSnippets ?? this.searchSnippets,
      accountSigningIn: accountSigningIn ?? this.accountSigningIn,
      secretRevealed: secretRevealed ?? this.secretRevealed,
      turnProcessOpen: turnProcessOpen ?? this.turnProcessOpen,
      expandedTurnProcessIds: expandedTurnProcessIds ?? this.expandedTurnProcessIds,
      collapsedTurnProcessIds: collapsedTurnProcessIds ?? this.collapsedTurnProcessIds,
      expandedStepIds: expandedStepIds ?? this.expandedStepIds,
      translatedStepIds: translatedStepIds ?? this.translatedStepIds,
      translatingStepIds: translatingStepIds ?? this.translatingStepIds,
      tipIndex: tipIndex ?? this.tipIndex,
      plugins: plugins ?? this.plugins,
      phoneAccessibility: phoneAccessibility ?? this.phoneAccessibility,
      phoneOverlay: phoneOverlay ?? this.phoneOverlay,
      phoneShizuku: phoneShizuku ?? this.phoneShizuku,
      phoneConfirmHighRisk: phoneConfirmHighRisk ?? this.phoneConfirmHighRisk,
      phoneAutoReturn: phoneAutoReturn ?? this.phoneAutoReturn,
      phoneShowEdgeAurora: phoneShowEdgeAurora ?? this.phoneShowEdgeAurora,
      phoneShowGestureFx: phoneShowGestureFx ?? this.phoneShowGestureFx,
      phoneLiveActive: phoneLiveActive ?? this.phoneLiveActive,
      phoneLivePaused: phoneLivePaused ?? this.phoneLivePaused,
      phoneHandoffReason: phoneHandoffReason ?? this.phoneHandoffReason,
      phoneLiveAction: phoneLiveAction ?? this.phoneLiveAction,
      phoneLiveApp: phoneLiveApp ?? this.phoneLiveApp,
      phoneLiveSteps: phoneLiveSteps ?? this.phoneLiveSteps,
      emergencyStopped: emergencyStopped ?? this.emergencyStopped,
      safetyPolicy: safetyPolicy ?? this.safetyPolicy,
      safetyAudit: safetyAudit ?? this.safetyAudit,
      autoFoldSteps: autoFoldSteps ?? this.autoFoldSteps,
      useSystemProxy: useSystemProxy ?? this.useSystemProxy,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      nativeRuntimeStatus: nativeRuntimeStatus ?? this.nativeRuntimeStatus,
      nativePermissions: nativePermissions ?? this.nativePermissions,
      runtimeProgressPct: runtimeProgressPct ?? this.runtimeProgressPct,
      runtimeProgressMsg: runtimeProgressMsg ?? this.runtimeProgressMsg,
      runtimeProgressStage: runtimeProgressStage ?? this.runtimeProgressStage,
      runtimeProgressCanCancel: runtimeProgressCanCancel ?? this.runtimeProgressCanCancel,
      connectionPhase: connectionPhase ?? this.connectionPhase,
      discoveredLanHosts: discoveredLanHosts ?? this.discoveredLanHosts,
      scanningLan: scanningLan ?? this.scanningLan,
      toast: clearToast ? null : (toast ?? this.toast),
      liveCapabilities:
          clearLiveCapabilities ? null : (liveCapabilities ?? this.liveCapabilities),
      scrollSignal: scrollSignal ?? this.scrollSignal,
      sessionJumpSignal: sessionJumpSignal ?? this.sessionJumpSignal,
      sessionRenderGen: sessionRenderGen ?? this.sessionRenderGen,
      streamTick: streamTick ?? this.streamTick,
      newChatSignal: newChatSignal ?? this.newChatSignal,
      focusComposerSignal: focusComposerSignal ?? this.focusComposerSignal,
      draftHydratedSignal: draftHydratedSignal ?? this.draftHydratedSignal,
      openJobsSignal: openJobsSignal ?? this.openJobsSignal,
      pendingInteractions: pendingInteractions ?? this.pendingInteractions,
      pendingOutbox: pendingOutbox ?? this.pendingOutbox,
      offlineUnsentNotice: clearOfflineUnsentNotice
          ? null
          : (offlineUnsentNotice ?? this.offlineUnsentNotice),
      pendingPairDeepLinkUri: clearPendingPairDeepLinkUri
          ? null
          : (pendingPairDeepLinkUri ?? this.pendingPairDeepLinkUri),
    );
  }
}

class GrassBagController extends StateNotifier<GrassBagAppState> {
  GrassBagController() : super(_initialState()) {
    unawaited(_hydrateFromStorageAndNative());
  }

  /// Lightweight prefs preloaded in `main()` before `runApp()` so Frame 0 renders
  /// immediately in the user's persisted theme/accent/glassTier with zero flicker.
  static Map<String, dynamic>? preloadedInitialPrefs;
  static List<Map<String, dynamic>>? preloadedInitialHosts;

  Timer? _toastTimer;
  Timer? _streamCoalesceTimer;
  Timer? _streamWatchdogTimer;
  Timer? _reconnectStreamCheckTimer;
  Timer? _jobOutputFlushTimer;
  Timer? _engineLogFlushTimer;
  Timer? _hostSessionsRefreshTimer;
  Timer? _domainRefreshTimer;
  Timer? _domainRetryTimer;
  Timer? _reconnectGraceTimer;
  Timer? _drawerSearchTimer;
  Timer? _accountPollTimer;
  Timer? _persistPrefsTimer;
  Timer? _persistHostsTimer;
  Timer? _persistHostContextsTimer;
  Timer? _appUpdateTimer;
  AppUpdateService _appUpdateService = const AppUpdateService();
  bool _appUpdateDownloadCancelled = false;
  DateTime? _lastDownloadProgressEmit;
  static bool disableAutoAppUpdateCheck = false;
  final Map<String, Map<String, dynamic>> _hostContexts = <String, Map<String, dynamic>>{};
  final Map<String, int> _hostProbeGen = <String, int>{};
  final List<String> _pendingEngineLogs = <String>[];
  final Map<String, List<String>> _pendingJobOutputs = <String, List<String>>{};
  final Set<String> _syncingSessionBundleIds = <String>{};
  final Map<String, ({bool jumpToBottom, bool authoritative, bool includeWorkbench})>
      _pendingResyncFlags = {};
  final Map<String, int> _sessionStreamSeq = <String, int>{};
  GbridgeClient? _coalescedClient;
  GbridgeClient? _jobOutputClient;
  SessionTelemetry? _pendingStreamTelemetry;
  double? _pendingCtxUsedK;
  int? _pendingCtxMaxK;
  int? _pendingCtxPct;
  Map<String, int>? _pendingCtxBreakdown;
  bool? _pendingStreamPlanMode;
  List<SessionTodoRecord>? _pendingStreamTodos;
  List<SubagentItem>? _pendingStreamSubagents;
  List<SessionGoalRecord>? _pendingStreamGoals;
  List<QueuedMessageItem>? _pendingStreamQueue;
  String? _pendingStreamTitle;
  bool _pendingStreamReduced = false;
  bool _pendingStreamTelemetryChanged = false;
  DateTime? _lastLiveTpsEmitAt;
  int _toastSeq = 0;
  int _hostIdSeq = 0;
  int _streamRunId = 0;
  int _sendRunSeq = 0;
  final Map<String, int> _activeSendRunIdBySession = <String, int>{};
  final Set<int> _cancelledSendRunIds = <int>{};
  int _hostConnectGen = 0;
  int _hydrationGen = 0;
  int _modelSelectionGen = 0;
  int _presetSelectionGen = 0;
  int _permissionSelectionGen = 0;
  int _inFlightModelSelections = 0;
  String? _lastAutoSyncedDefaultKey;
  int _marketSearchSeq = 0;
  int _wsDirSeq = 0;
  int _wsDiffSeq = 0;
  int _autoStartRequestedGen = -1;
  bool _userStoppedLocalEngine = false;
  bool _pendingAutoConnectRequested = false;
  final Set<String> _inFlightSendKeys = <String>{};
  bool _startingAppUpdateDownload = false;
  bool _compactingContext = false;
  bool _bootstrappingLocal = false;
  bool _connectingLocalAndroid = false;
  bool _hadInitialWelcome = false;
  bool _userNavigatedSinceHostBind = false;
  int? _connectingLocalGen;
  String? _activeSignInAttemptId;
  GbridgeClient? _liveClient;
  GbridgeClient? _bootstrapClient;
  StreamSubscription<StreamFrame>? _streamSub;
  StreamSubscription<WelcomeInfo>? _welcomeSub;
  StreamSubscription<ConnectionPhase>? _phaseSub;
  StreamSubscription<NativeEvent>? _nativeSub;
  final TurnStreamReducer _turnReducer = TurnStreamReducer();
  final Map<String, List<NormalizedTurn>> _sessionTurnsMemory = {};
  final Map<String, ({bool hasMore, String? nextCursor})> _sessionPaginationMemory = {};
  final Map<String, List<ComposerAttachment>> _sessionAttachmentsMemory = {};
  final Map<String, List<QueuedMessageItem>> _sessionQueuedMemory = {};
  final Map<String, Set<String>> _unreadSessionIdsByHost = {};
  final Map<String, Uint8List> _attachmentDownloadCache = {};
  final Map<String, Future<Uint8List?>> _inFlightAttachmentDownloads = {};
  int _attachmentDownloadCacheBytes = 0;
  static const int _maxAttachmentCacheBytes = 24 * 1024 * 1024;
  final Map<String, Future<void>> _inFlightBundleSyncs = {};
  final Map<String, Map<String, dynamic>> _offlineHistoryByHost = {};
  final List<Map<String, dynamic>> _pendingOutbox = [];
  Timer? _offlineHistorySaveTimer;
  final Map<String, int> _sessionStreamRetryCount = {};
  final Map<String, Timer> _sessionStreamRetryTimers = {};
  final Map<String, int> _jobStreamRetryCount = {};
  final Map<String, Timer> _jobStreamRetryTimers = {};
  bool _wasRecentlyBackgrounded = false;
  String? _activePhoneSessionId;

  /// Test-only switch permitting loopback `127.0.0.1` servers in `diagnoseRemoteHost` /
  /// `connectRemoteInput` unit tests (always `false` in production).
  @visibleForTesting
  static bool allowLoopbackRemoteForTest = false;

  void _stashQueuedMessagesForScope(String hostId, String? sessionId) {
    final key = _attachmentsScopeKey(hostId, sessionId);
    if (state.queuedMessages.isEmpty) {
      _sessionQueuedMemory.remove(key);
    } else {
      _sessionQueuedMemory[key] = List<QueuedMessageItem>.unmodifiable(state.queuedMessages);
    }
  }

  List<QueuedMessageItem> _restoreQueuedMessagesForScope(String hostId, String? sessionId) {
    final key = _attachmentsScopeKey(hostId, sessionId);
    return _sessionQueuedMemory[key] ?? const [];
  }

  /// Cached download of historical session attachments (images & files) from DSH / gbridge.
  Future<Uint8List?> downloadSessionAttachment(
    String attachmentId, {
    String? sessionId,
  }) async {
    final cleanId = attachmentId.trim();
    if (cleanId.isEmpty) return null;
    final sid = sessionId ?? state.activeSessionId;
    final hostId = state.activeHostId;
    final cacheKey = '$hostId:${sid ?? ''}:$cleanId';
    final cached = _attachmentDownloadCache.remove(cacheKey);
    if (cached != null) {
      // Refresh LRU recency.
      _attachmentDownloadCache[cacheKey] = cached;
      return cached;
    }
    final inFlight = _inFlightAttachmentDownloads[cacheKey];
    if (inFlight != null) return inFlight;
    final client = _liveClient;
    if (client == null) return null;
    final future = () async {
      try {
        final bytes = await client.downloadAttachment(cleanId, sessionId: sid);
        if (bytes.isEmpty || !_isStillLive(client)) return null;
        if (bytes.length <= _maxAttachmentCacheBytes) {
          final prev = _attachmentDownloadCache.remove(cacheKey);
          if (prev != null) _attachmentDownloadCacheBytes -= prev.length;
          while ((_attachmentDownloadCache.length >= 24 ||
                  _attachmentDownloadCacheBytes + bytes.length > _maxAttachmentCacheBytes) &&
              _attachmentDownloadCache.isNotEmpty) {
            final oldestKey = _attachmentDownloadCache.keys.first;
            final oldest = _attachmentDownloadCache.remove(oldestKey);
            if (oldest != null) _attachmentDownloadCacheBytes -= oldest.length;
          }
          _attachmentDownloadCache[cacheKey] = bytes;
          _attachmentDownloadCacheBytes += bytes.length;
        }
        return bytes;
      } catch (_) {
        return null;
      }
    }();
    _inFlightAttachmentDownloads[cacheKey] = future;
    future.whenComplete(() {
      if (identical(_inFlightAttachmentDownloads[cacheKey], future)) {
        _inFlightAttachmentDownloads.remove(cacheKey);
      }
    }).ignore();
    return future;
  }

  /// Directly selects a specific thinking effort level for the active reasoning model
  /// (e.g. from the iOS Liquid Glass long-press effort menu on the composer model pill).
  Future<void> setReasoningEffort(String effortId) async {
    final m = state.effectiveActiveModelEntry;
    if (m == null || m.efforts.isEmpty) return;
    final clean = effortId.trim().toLowerCase();
    final target = m.efforts
        .where((e) => e.id.trim().toLowerCase() == clean)
        .firstOrNull;
    if (target == null) return;
    final curId = (state.modelEffortId.isNotEmpty ? state.modelEffortId : m.defaultEffort)
        .trim()
        .toLowerCase();
    if (curId == target.id.trim().toLowerCase() && state.modelEffort == target.zhLabel) {
      return;
    }
    await setModel(
      m.name,
      m.shortLabel,
      provider: m.providerId,
      modelId: m.id,
      effortId: target.id,
      effort: target.zhLabel,
      silent: true,
    );
    showToast('思考深度：${target.zhLabel}', tone: ToastTone.info);
  }

  /// One-tap cycling of thinking effort for the active reasoning model from the composer pill.
  Future<void> cycleReasoningEffort() async {
    final m = state.effectiveActiveModelEntry;
    if (m == null || m.efforts.length < 2) return;
    final curId = (state.modelEffortId.isNotEmpty ? state.modelEffortId : m.defaultEffort)
        .trim()
        .toLowerCase();
    final idx = m.efforts.indexWhere((e) => e.id.trim().toLowerCase() == curId);
    final nextOpt = m.efforts[(idx + 1) % m.efforts.length];
    await setModel(
      m.name,
      m.shortLabel,
      provider: m.providerId,
      modelId: m.id,
      effortId: nextOpt.id,
      effort: nextOpt.zhLabel,
      silent: true,
    );
    showToast('思考深度：${nextOpt.zhLabel}', tone: ToastTone.info);
  }

  void bumpDraftHydratedSignal() {
    state = state.copyWith(draftHydratedSignal: state.draftHydratedSignal + 1);
  }

  /// Jump into a child subagent transcript while keeping a one-tap return breadcrumb to the parent chat.
  void openSubagentSession(String childSessionId, {String? childTitle, String? worktree}) {
    final cleanId = childSessionId.trim();
    if (cleanId.isEmpty || cleanId == state.activeSessionId) return;
    final parentId = state.parentSessionId ?? state.activeSessionId;
    final parentTitle = state.parentSessionTitle ??
        state.activeSession?.title ??
        state.activeChildTitle ??
        '主对话';
    final matchedSub = state.subagents.where((s) => s.id == cleanId).firstOrNull;
    final resolvedChildTitle = (childTitle != null && childTitle.trim().isNotEmpty)
        ? childTitle.trim()
        : (matchedSub?.name.trim().isNotEmpty == true ? matchedSub!.name.trim() : '子代理会话');
    final resolvedWorktree = (worktree != null && worktree.trim().isNotEmpty)
        ? worktree.trim()
        : null;
    selectSession(
      cleanId,
      preserveParentStack: true,
      nextParentId: parentId,
      nextParentTitle: parentTitle,
      nextChildTitle: resolvedChildTitle,
      nextChildWorktree: resolvedWorktree,
    );
  }

  /// Pop back from a child subagent transcript to its parent conversation.
  void returnToParentSession() {
    final pid = state.parentSessionId;
    if (pid == null || pid.isEmpty) return;
    selectSession(pid);
  }
  DateTime? _lastWarnToastAt;
  final Map<String, Map<String, dynamic>> _toolDetailCache = {};
  final Map<String, PendingInteraction> _pendingInteractionsById = {};
  String? _preferredInteractionId;
  int _interactionMutationSeq = 0;
  void Function()? _appUpdateDownloadAbort;
  final Map<String, Future<void>> _nsWriteTails = {};
  final Set<String> _locallyCancelledTurnIds = {};
  final Map<String, Future<void>> _inFlightCancelBySession = {};
  int _cancelSuppressUntilMs = 0;
  int _cancelledOptimisticUntilMs = 0;
  String? _cancelledOptimisticSessionId;
  bool _isForking = false;
  int _lastStreamActivityMs = 0;
  int _lastStage0HydrateMs = 0;
  ({String wsId, int fetchedAtMs, List<String> files})? _refWorkspaceFilesCache;
  int _stallProbeCount = 0;
  int _lastStallProbeMs = 0;
  Set<String> _deviceLocalIps = const {'127.0.0.1', '::1', '0.0.0.0'};

  void _armStreamWatchdog() {
    _lastStreamActivityMs = DateTime.now().millisecondsSinceEpoch;
    _stallProbeCount = 0;
    _lastStallProbeMs = 0;
    _streamWatchdogTimer?.cancel();
    _streamWatchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !state.isStreaming) {
        _disarmStreamWatchdog();
        return;
      }
      // Never treat an active approval/question prompt or long-running tool call as a stream stall!
      if (state.activePendingInteractionCount > 0) {
        _lastStreamActivityMs = DateTime.now().millisecondsSinceEpoch;
        return;
      }
      if (state.sendStage == SendStage.uploadingAttachments) {
        return;
      }
      final tail = state.turns.isNotEmpty ? state.turns.last : null;
      final hasRunningTool =
          tail != null && tail.steps.any((s) => s is ToolStep && s.status == 'running');
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final idleMs = nowMs - _lastStreamActivityMs;
      final probeThresholdMs = hasRunningTool ? 45000 : 15000;
      final stallThresholdMs = hasRunningTool ? 60000 : 25000;
      final probeCooldownMs = _stallProbeCount == 0
          ? 0
          : (_stallProbeCount == 1 ? 20000 : 30000);
      final sid = state.activeSessionId;
      final client = _liveClient;
      if (idleMs >= probeThresholdMs &&
          _stallProbeCount < 4 &&
          (nowMs - _lastStallProbeMs) >= probeCooldownMs &&
          client != null &&
          sid != null &&
          !sid.startsWith('pending-session-')) {
        _stallProbeCount++;
        _lastStallProbeMs = nowMs;
        unawaited(client.stream.checkLiveness(force: true));
        unawaited(() async {
          await refreshSessionsList(silent: true);
          if (!mounted || state.activeSessionId != sid) return;
          await _syncLiveSessionBundle(
            sid,
            jumpToBottomOnLoad: false,
            authoritativeSync: true,
          );
        }());
      }
      if (idleMs >= stallThresholdMs && !state.streamStalled) {
        state = state.copyWith(streamStalled: true);
      }
    });
  }

  void _disarmStreamWatchdog() {
    _streamWatchdogTimer?.cancel();
    _streamWatchdogTimer = null;
    _stallProbeCount = 0;
    _lastStallProbeMs = 0;
  }

  /// Manual 1-tap resync triggered from the calm inline "响应较慢 · 同步状态" badge.
  Future<void> syncStalledStream() async {
    final client = _liveClient;
    final sid = state.activeSessionId;
    _lastStreamActivityMs = DateTime.now().millisecondsSinceEpoch;
    _stallProbeCount = 0;
    _lastStallProbeMs = 0;
    if (state.streamStalled) {
      state = state.copyWith(streamStalled: false);
    }
    if (client == null || sid == null || sid.startsWith('pending-session-')) return;
    unawaited(client.stream.checkLiveness(force: true));
    client.stream.subscribe('session:$sid', force: true);
    await refreshSessionsList(silent: true);
    if (!mounted || state.activeSessionId != sid) return;
    await _syncLiveSessionBundle(
      sid,
      jumpToBottomOnLoad: false,
      authoritativeSync: true,
    );
  }

  static final RegExp _trailingAttachmentTagRe = RegExp(
    r'(?:\s*\[(?:附件|Attachment|附件已上传)\s*[:：][^\]]*\])+\s*$',
    caseSensitive: false,
  );

  static String _stripTrailingAttachmentTags(String s) =>
      s.replaceFirst(_trailingAttachmentTagRe, '').trim();

  static bool _userTextsMatch(String optTrim, String freshTrim) {
    if (optTrim == freshTrim) return true;
    if (optTrim.isEmpty || freshTrim.isEmpty) return false;
    final cleanOpt = _stripTrailingAttachmentTags(optTrim);
    final cleanFresh = _stripTrailingAttachmentTags(freshTrim);
    if (cleanOpt.isEmpty || cleanFresh.isEmpty) return false;
    if (cleanOpt == cleanFresh) return true;
    if (cleanFresh.endsWith(cleanOpt) || cleanOpt.endsWith(cleanFresh)) return true;
    final normOpt = cleanOpt.replaceAll(RegExp(r'\s+'), ' ');
    final normFresh = cleanFresh.replaceAll(RegExp(r'\s+'), ' ');
    return normFresh == normOpt ||
        normFresh.endsWith(normOpt) ||
        normOpt.endsWith(normFresh);
  }
  DateTime? _lastBackgroundedAt;
  Timer? _keepaliveRenewTimer;
  String _lastKeepaliveSig = '';
  bool _keepaliveServiceStarted = false;
  int _cachedRunningSessionsCount = 0;
  Future<bool>? _inFlightPermissionsRefresh;
  bool _lastPermissionsRefreshSucceeded = true;
  bool get lastPermissionsRefreshSucceeded => _lastPermissionsRefreshSucceeded;
  Future<void>? _inFlightNativeStatus;
  int _nativeStatusSeq = 0;
  int _dshUpdateCheckSeq = 0;
  static const String _disconnectedSaveError = '主机连接已断开或切换，本次保存未完成，请重连后重试';

  static const int _maxCachedSessionsTurns = 10;
  static const int _maxToolCacheEntries = 50;

  @override
  set state(GrassBagAppState value) {
    final prev = super.state;
    super.state = value;
    if (!identical(prev.sessions, value.sessions)) {
      var running = 0;
      for (final s in value.sessions) {
        if (s.running && !s.archived) running++;
      }
      _cachedRunningSessionsCount = running;
    }
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      _syncAndroidKeepaliveIfNeeded(prev, value);
    }
  }

  /// Computes the Android foreground-service & WakeLock/WifiLock keepalive plan for the given state.
  /// Returns `null` when native bootstrapper owns the notification, or `(shouldRun: false)` when idle.
  static ({
    bool managedByBootstrap,
    bool shouldRun,
    bool needsWakeLock,
    String title,
    String detail,
  }) computeAndroidKeepalivePlan(
    GrassBagAppState s, {
    required int runningSessionsCount,
  }) {
    if (s.nativeRuntimeStatus.bootstrapActive ||
        s.nativeRuntimeStatus.engineState == 'starting') {
      return (
        managedByBootstrap: true,
        shouldRun: true,
        needsWakeLock: true,
        title: '',
        detail: '',
      );
    }
    final hasPendingInteraction = s.pendingApprovalInteractionId != null ||
        s.activeQuestion != null ||
        s.activeCordisRequest != null;
    final activeTasks = s.runningJobsCount + runningSessionsCount;
    final activeHost = s.hosts.where((h) => h.id == s.activeHostId).firstOrNull ??
        (s.hosts.isNotEmpty ? s.hosts.first : null);
    final hostLabel =
        (activeHost?.name.trim().isNotEmpty ?? false) ? activeHost!.name.trim() : '当前主机';

    if (s.phoneLiveActive) {
      final stepPart = s.phoneLiveSteps > 0 ? '第 ${s.phoneLiveSteps} 步 · ' : '';
      final appPart = s.phoneLiveApp.trim().isNotEmpty ? '${s.phoneLiveApp.trim()} · ' : '';
      return (
        managedByBootstrap: false,
        shouldRun: true,
        needsWakeLock: true,
        title: 'GrassBag 正在操控手机',
        detail: '$stepPart$appPart后台保活与连接守护中',
      );
    }
    if (s.isStreaming) {
      return (
        managedByBootstrap: false,
        shouldRun: true,
        needsWakeLock: true,
        title: 'GrassBag 正在生成回复',
        detail: '$hostLabel · 保持后台连接与流式输出',
      );
    }
    if (hasPendingInteraction) {
      return (
        managedByBootstrap: false,
        shouldRun: true,
        needsWakeLock: true,
        title: 'GrassBag 等待你的授权确认',
        detail: '$hostLabel · 连接保活中，点击返回确认',
      );
    }
    if (activeTasks > 0) {
      return (
        managedByBootstrap: false,
        shouldRun: true,
        needsWakeLock: true,
        title: 'GrassBag 后台任务运行中',
        detail: '共 $activeTasks 个任务运行中 · 持续保活',
      );
    }
    if (s.appUpdateDownloading) {
      return (
        managedByBootstrap: false,
        shouldRun: true,
        needsWakeLock: true,
        title: 'GrassBag 正在下载应用更新',
        detail: '后台高速下载保活中',
      );
    }
    if (s.nativeRuntimeStatus.engineRunning) {
      final ver = s.nativeRuntimeStatus.dshVersion.trim();
      return (
        managedByBootstrap: false,
        shouldRun: true,
        needsWakeLock: false,
        title: 'GrassBag 本机引擎运行中',
        detail: ver.isNotEmpty ? 'DSH $ver · 后台待命保活' : '后台待命保活',
      );
    }
    return (
      managedByBootstrap: false,
      shouldRun: false,
      needsWakeLock: false,
      title: '',
      detail: '',
    );
  }

  void _syncAndroidKeepaliveIfNeeded(GrassBagAppState prev, GrassBagAppState next) {
    final relevantChanged = prev.isStreaming != next.isStreaming ||
        prev.phoneLiveActive != next.phoneLiveActive ||
        prev.phoneLiveSteps != next.phoneLiveSteps ||
        prev.phoneLiveApp != next.phoneLiveApp ||
        !identical(prev.jobs, next.jobs) ||
        prev.pendingApprovalInteractionId != next.pendingApprovalInteractionId ||
        prev.activeQuestion != next.activeQuestion ||
        prev.activeCordisRequest != next.activeCordisRequest ||
        prev.appUpdateDownloading != next.appUpdateDownloading ||
        prev.nativeRuntimeStatus.engineState != next.nativeRuntimeStatus.engineState ||
        prev.nativeRuntimeStatus.engineRunning != next.nativeRuntimeStatus.engineRunning ||
        prev.nativeRuntimeStatus.bootstrapActive != next.nativeRuntimeStatus.bootstrapActive ||
        prev.activeHostId != next.activeHostId ||
        !identical(prev.sessions, next.sessions);
    if (!relevantChanged) return;
    _syncAndroidKeepalive();
  }

  void _syncAndroidKeepalive({bool force = false}) {
    final native = GrassBagNativeBridge.instance;
    if (!native.isAndroidNative || !mounted) return;
    final plan = computeAndroidKeepalivePlan(
      state,
      runningSessionsCount: _cachedRunningSessionsCount,
    );
    if (plan.managedByBootstrap) {
      _keepaliveRenewTimer?.cancel();
      _keepaliveRenewTimer = null;
      _lastKeepaliveSig = 'bootstrap';
      _keepaliveServiceStarted = true;
      return;
    }
    if (!plan.shouldRun) {
      _keepaliveRenewTimer?.cancel();
      _keepaliveRenewTimer = null;
      _lastKeepaliveSig = '';
      if (_keepaliveServiceStarted) {
        _keepaliveServiceStarted = false;
        unawaited(native.stopKeepaliveService());
      }
      return;
    }
    final sig = '${plan.needsWakeLock}|${plan.title}|${plan.detail}';
    if (!plan.needsWakeLock) {
      _keepaliveRenewTimer?.cancel();
      _keepaliveRenewTimer = null;
    }
    if (!force && sig == _lastKeepaliveSig) return;
    _lastKeepaliveSig = sig;
    _keepaliveServiceStarted = true;
    unawaited(
      native
          .startKeepaliveService(
            title: plan.title,
            text: plan.detail,
            wakeLockMs: plan.needsWakeLock ? 10 * 60 * 1000 : 0,
            holdWifiLock: plan.needsWakeLock,
            releaseWakeLock: !plan.needsWakeLock,
          )
          .then((ok) {
            if (!mounted || !ok) return;
            final latestPlan = computeAndroidKeepalivePlan(
              state,
              runningSessionsCount: _cachedRunningSessionsCount,
            );
            if (latestPlan.shouldRun && latestPlan.needsWakeLock && !latestPlan.managedByBootstrap) {
              _keepaliveRenewTimer ??= Timer.periodic(const Duration(minutes: 4), (_) {
                if (!mounted) {
                  _keepaliveRenewTimer?.cancel();
                  _keepaliveRenewTimer = null;
                  return;
                }
                _syncAndroidKeepalive(force: true);
              });
            }
          }),
    );
  }

  void _cacheSessionTurns(String sessionId, List<NormalizedTurn> turns) {
    if (sessionId.isEmpty) return;
    // Touch key so LinkedHashMap maintains true LRU eviction order.
    _sessionTurnsMemory.remove(sessionId);
    _sessionTurnsMemory[sessionId] = turns;
    while (_sessionTurnsMemory.length > _maxCachedSessionsTurns) {
      final oldest = _sessionTurnsMemory.keys.first;
      _sessionTurnsMemory.remove(oldest);
      _sessionPaginationMemory.remove(oldest);
    }
    if (!sessionId.startsWith('pending-session-') && turns.isNotEmpty) {
      _recordOfflineSessionSnapshot(state.activeHostId, sessionId, turns);
    }
  }

  static const int _maxOfflineHosts = 4;
  static const int _maxOfflineSessionsPerHost = 8;
  static const int _maxOfflineTurnsPerSession = 24;

  static Map<String, dynamic> _encodeOfflineTurn(NormalizedTurn t) {
    String clip(String s, int maxLen) =>
        s.length <= maxLen ? s : '${s.substring(0, maxLen)}…';
    return {
      'turnId': t.turnId,
      'stableKey': t.stableKey,
      'status': t.status,
      'seqStart': t.seqStart,
      'seqEnd': t.seqEnd,
      if (t.userMessage != null)
        'userText': clip(t.userMessage!.text, 4000),
      if (t.userMessage?.createdAt != null)
        'userCreatedAt': t.userMessage!.createdAt,
      'assistantText': clip(t.combinedAssistantProse, 6000),
      if (t.errorMessage != null && t.errorMessage!.isNotEmpty)
        'errorMessage': clip(t.errorMessage!, 600),
    };
  }

  static NormalizedTurn? _decodeOfflineTurn(Map<String, dynamic> m) {
    final turnId = m['turnId']?.toString() ?? '';
    if (turnId.isEmpty) return null;
    final userText = m['userText']?.toString();
    final createdAt = (m['userCreatedAt'] as num?)?.toInt();
    final status = m['status']?.toString() ?? 'completed';
    final safeStatus = status == 'streaming' ? 'completed' : status;
    return NormalizedTurn(
      turnId: turnId,
      stableKey: m['stableKey']?.toString(),
      seqStart: (m['seqStart'] as num?)?.toInt() ?? 0,
      seqEnd: (m['seqEnd'] as num?)?.toInt() ?? 0,
      userMessage: userText != null
          ? NormalizedUserMessage(id: 'u-$turnId', text: userText, createdAt: createdAt)
          : null,
      assistantText: m['assistantText']?.toString() ?? '',
      status: safeStatus,
      errorMessage: m['errorMessage']?.toString(),
    );
  }

  void _recordOfflineSessionSnapshot(
    String hostId,
    String sessionId,
    List<NormalizedTurn> turns,
  ) {
    if (hostId.isEmpty || sessionId.isEmpty || turns.isEmpty) return;
    final hostBucket = _offlineHistoryByHost.remove(hostId) ?? <String, dynamic>{};
    _offlineHistoryByHost[hostId] = hostBucket;
    while (_offlineHistoryByHost.length > _maxOfflineHosts) {
      _offlineHistoryByHost.remove(_offlineHistoryByHost.keys.first);
    }
    final sessionsMap = hostBucket['sessions'] is Map
        ? Map<String, dynamic>.from(hostBucket['sessions'] as Map)
        : <String, dynamic>{};
    final sessMeta = state.sessions.where((s) => s.id == sessionId).firstOrNull;
    final trimmedTurns = turns.length > _maxOfflineTurnsPerSession
        ? turns.sublist(turns.length - _maxOfflineTurnsPerSession)
        : turns;
    sessionsMap.remove(sessionId);
    sessionsMap[sessionId] = {
      'id': sessionId,
      'title': sessMeta?.title ?? '未命名对话',
      'group': sessMeta?.group ?? '离线缓存',
      if (sessMeta?.workspaceId != null) 'workspaceId': sessMeta!.workspaceId,
      if (sessMeta?.workspaceName != null) 'workspaceName': sessMeta!.workspaceName,
      if (sessMeta?.cwd != null) 'cwd': sessMeta!.cwd,
      'updatedAt': sessMeta?.updatedAt ?? DateTime.now().millisecondsSinceEpoch,
      'turns': [for (final t in trimmedTurns) _encodeOfflineTurn(t)],
    };
    while (sessionsMap.length > _maxOfflineSessionsPerHost) {
      sessionsMap.remove(sessionsMap.keys.first);
    }
    hostBucket['sessions'] = sessionsMap;
    hostBucket['savedAt'] = DateTime.now().millisecondsSinceEpoch;
    _scheduleSaveOfflineHistory();
  }

  void _scheduleSaveOfflineHistory({bool immediate = false}) {
    _offlineHistorySaveTimer?.cancel();
    void flush() {
      _offlineHistorySaveTimer = null;
      if (!mounted) return;
      unawaited(GrassBagStorage.instance.saveOfflineHistory(Map<String, dynamic>.from(_offlineHistoryByHost)));
    }
    if (immediate) {
      flush();
    } else {
      _offlineHistorySaveTimer = Timer(const Duration(milliseconds: 500), flush);
    }
  }

  /// Hydrates read-only cached sessions & turns for [hostId] into memory so switching hosts
  /// or launching offline preserves recent conversation history for browsing.
  List<ChatSessionItem> _hydrateOfflineCacheForHost(String hostId) {
    final bucket = _offlineHistoryByHost[hostId];
    final rawSessions = bucket?['sessions'];
    if (rawSessions is! Map || rawSessions.isEmpty) return const [];
    final items = <ChatSessionItem>[];
    for (final entry in rawSessions.entries) {
      if (entry.value is! Map) continue;
      final m = Map<String, dynamic>.from(entry.value as Map);
      final sid = m['id']?.toString() ?? entry.key.toString();
      if (sid.isEmpty) continue;
      final rawTurns = m['turns'];
      if (rawTurns is List) {
        final decoded = <NormalizedTurn>[];
        for (final rt in rawTurns) {
          if (rt is Map) {
            final parsed = _decodeOfflineTurn(Map<String, dynamic>.from(rt));
            if (parsed != null) decoded.add(parsed);
          }
        }
        if (decoded.isNotEmpty) {
          _sessionTurnsMemory.putIfAbsent(sid, () => decoded);
        }
      }
      items.add(
        ChatSessionItem(
          id: sid,
          title: m['title']?.toString() ?? '未命名对话',
          group: m['group']?.toString() ?? '离线缓存',
          workspaceId: m['workspaceId']?.toString(),
          workspaceName: m['workspaceName']?.toString(),
          cwd: m['cwd']?.toString(),
          updatedAt: (m['updatedAt'] as num?)?.toInt(),
        ),
      );
    }
    items.sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));
    return items;
  }

  List<Map<String, dynamic>> get pendingOutboxEntries =>
      List<Map<String, dynamic>>.unmodifiable(_pendingOutbox);

  void _syncOutboxState() {
    if (!mounted) return;
    final items = _pendingOutbox
        .map(PendingOutboxItem.fromMap)
        .where((i) => i.id.isNotEmpty && i.text.trim().isNotEmpty)
        .toList(growable: false);
    if (!listEquals(items, state.pendingOutbox)) {
      state = state.copyWith(pendingOutbox: items);
    }
  }

  void dismissOfflineUnsentNotice() {
    if (state.offlineUnsentNotice != null) {
      state = state.copyWith(clearOfflineUnsentNotice: true);
    }
  }

  void dismissOutboxEntry(String id) {
    _clearOutboxEntry(id);
    if (state.unsentOutboxForActiveHost.isEmpty && state.offlineUnsentNotice != null) {
      state = state.copyWith(clearOfflineUnsentNotice: true);
    }
  }

  void restoreOutboxEntryToDraft(PendingOutboxItem item) {
    final targetSid = item.sessionId.isEmpty ? null : item.sessionId;
    if (item.hostId.isNotEmpty &&
        item.hostId != state.activeHostId &&
        state.hosts.any((h) => h.id == item.hostId)) {
      unawaited(switchHost(item.hostId));
    }
    if (targetSid != null && targetSid != state.activeSessionId) {
      selectSession(targetSid);
    }
    setComposerDraftForScope(item.hostId.isNotEmpty ? item.hostId : state.activeHostId, targetSid, item.text);
    bumpDraftHydratedSignal();
    showToast('已将未发送消息恢复到输入框', tone: ToastTone.info);
  }

  void _recordOutboxEntry({
    required String id,
    required String hostId,
    required String sessionId,
    required String text,
    required String mode,
    String status = 'sending',
    String? errorMessage,
  }) {
    if (id.isEmpty || text.trim().isEmpty) return;
    _pendingOutbox.removeWhere((e) => e['id'] == id);
    _pendingOutbox.add({
      'id': id,
      'hostId': hostId,
      'sessionId': sessionId,
      'text': text,
      'mode': mode,
      'status': status,
      if (errorMessage != null && errorMessage.isNotEmpty) 'errorMessage': errorMessage,
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
    });
    while (_pendingOutbox.length > 30) {
      _pendingOutbox.removeAt(0);
    }
    _syncOutboxState();
    unawaited(GrassBagStorage.instance.savePendingOutbox(List<Map<String, dynamic>>.from(_pendingOutbox)));
  }

  void _clearOutboxEntry(String id) {
    final before = _pendingOutbox.length;
    _pendingOutbox.removeWhere((e) => e['id'] == id);
    if (_pendingOutbox.length != before) {
      _syncOutboxState();
      unawaited(GrassBagStorage.instance.savePendingOutbox(List<Map<String, dynamic>>.from(_pendingOutbox)));
    }
  }

  /// Reconciles persisted unconfirmed outbox entries against authoritative server turns
  /// after reconnect/sync: clears entries the server already received, or restores unsent
  /// entries into the session draft so the user can review and retry without double-sending.
  void _reconcileOutboxForSession(
    String hostId,
    String sessionId,
    List<NormalizedTurn> serverTurns,
  ) {
    if (_pendingOutbox.isEmpty || hostId.isEmpty || sessionId.isEmpty) return;
    final matching = _pendingOutbox
        .where((e) => e['hostId'] == hostId && e['sessionId'] == sessionId)
        .toList(growable: false);
    if (matching.isEmpty) return;
    var dirty = false;
    var restoredAny = false;
    for (final entry in matching) {
      final entryId = entry['id']?.toString() ?? '';
      final entryText = entry['text']?.toString().trim() ?? '';
      final alreadyReceived = serverTurns.any((t) {
        if (entryId.isNotEmpty && t.turnId == entryId) return true;
        final uText = t.userMessage?.text.trim() ?? '';
        return entryText.isNotEmpty && uText.isNotEmpty && _userTextsMatch(entryText, uText);
      });
      if (alreadyReceived) {
        _pendingOutbox.removeWhere((e) => e['id'] == entryId);
        dirty = true;
      } else if (entry['status'] != 'restored' && entryText.isNotEmpty) {
        final curDraft = getComposerDraftForScope(hostId, sessionId);
        if (curDraft.trim().isEmpty) {
          setComposerDraftForScope(hostId, sessionId, entryText);
          if (state.activeHostId == hostId && state.activeSessionId == sessionId) {
            bumpDraftHydratedSignal();
          }
        }
        entry['status'] = 'restored';
        dirty = true;
        restoredAny = true;
      }
    }
    if (dirty) {
      _syncOutboxState();
      unawaited(GrassBagStorage.instance.savePendingOutbox(List<Map<String, dynamic>>.from(_pendingOutbox)));
    }
    if (restoredAny && state.activeHostId == hostId && state.activeSessionId == sessionId) {
      showToast('检测到重连前未确认的消息，已为你恢复至草稿，请核对后重试', tone: ToastTone.info);
    }
  }

  void _scheduleSessionStreamResubscribe(
    GbridgeClient client,
    String sessionId, {
    required String reason,
  }) {
    if (sessionId.isEmpty || sessionId.startsWith('pending-session-')) return;
    const maxRetries = 5;
    final attempt = (_sessionStreamRetryCount[sessionId] ?? 0) + 1;
    if (attempt > maxRetries) {
      showToast('对话实时流多次断开，已切换为状态校准，可下拉刷新重试', tone: ToastTone.warn);
      unawaited(_syncLiveSessionBundle(sessionId, jumpToBottomOnLoad: false));
      return;
    }
    _sessionStreamRetryCount[sessionId] = attempt;
    final delayMs = (400 * (1 << (attempt - 1))).clamp(400, 5000);
    _sessionStreamRetryTimers[sessionId]?.cancel();
    _sessionStreamRetryTimers[sessionId] = Timer(Duration(milliseconds: delayMs), () {
      _sessionStreamRetryTimers.remove(sessionId);
      if (!_isStillLive(client) || state.activeSessionId != sessionId) return;
      client.stream.subscribe('session:$sessionId', force: true);
      unawaited(_syncLiveSessionBundle(sessionId, jumpToBottomOnLoad: false));
    });
  }

  void _scheduleJobStreamResubscribe(GbridgeClient client, String jobId) {
    if (jobId.isEmpty) return;
    const maxRetries = 4;
    final attempt = (_jobStreamRetryCount[jobId] ?? 0) + 1;
    if (attempt > maxRetries) {
      unawaited(refreshJobs(silent: true));
      return;
    }
    _jobStreamRetryCount[jobId] = attempt;
    final delayMs = (500 * (1 << (attempt - 1))).clamp(500, 5000);
    _jobStreamRetryTimers[jobId]?.cancel();
    _jobStreamRetryTimers[jobId] = Timer(Duration(milliseconds: delayMs), () {
      _jobStreamRetryTimers.remove(jobId);
      if (!_isStillLive(client)) return;
      client.stream.subscribe('job:$jobId', force: true);
      unawaited(refreshJobs(silent: true));
    });
  }

  static bool _deepEquals(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final entry in a.entries) {
        if (!b.containsKey(entry.key)) return false;
        if (!_deepEquals(entry.value, b[entry.key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  /// True only when the user explicitly tapped "停止本机引擎" in this session.
  bool get userStoppedLocalEngine => _userStoppedLocalEngine;

  /// Live `/gbridge/v1` client when connected to a bridged or zero-plugin direct host.
  GbridgeClient? get liveClient => _liveClient;

  Future<Set<String>> _refreshDeviceLocalIps() async {
    if (!GrassBagNativeBridge.instance.isAndroidNative) return _deviceLocalIps;
    final ips = await GrassBagNativeBridge.instance.getLocalDeviceIps();
    if (mounted) _deviceLocalIps = ips;
    return ips;
  }

  /// Returns a clear user-facing guidance message if [uri] points to the current device itself
  /// (and therefore must not be added as a remote host), or `null` when it is a valid remote target.
  String? selfDeviceGuidanceForUri(
    Uri uri, {
    bool? isAndroidOverride,
    Set<String>? deviceIpsOverride,
  }) {
    if (allowLoopbackRemoteForTest && isLoopbackHost(uri.host)) {
      return null;
    }
    final isAndroid = isAndroidOverride ?? GrassBagNativeBridge.instance.isAndroidNative;
    final ips = deviceIpsOverride ?? _deviceLocalIps;
    final localUri = Uri.tryParse(state.localHost.address);
    if (!isSelfDeviceUri(
      uri,
      ips,
      isAndroidNative: isAndroid,
      localHostUri: localUri,
    )) {
      return null;
    }
    final hostLower = uri.host.toLowerCase();
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    if (isAndroid && isLoopbackHost(hostLower) && port != 13080) {
      return '$hostLower 指的是这台手机自己，不是你的电脑。请换成电脑上显示的局域网连接链接，或直接扫描电脑上的二维码。';
    }
    return '该地址指向当前设备本机，无需作为远程电脑添加。若要连接另一台电脑，请换成那台电脑上的连接链接。';
  }

  /// True only while the given [client] is still the currently bound live host client.
  bool _isStillLive(GbridgeClient client, {int? gen}) =>
      mounted && identical(_liveClient, client) && (gen == null || gen == _hostConnectGen);

  String _draftScopeKey([String? sessionId]) =>
      (sessionId != null && sessionId.isNotEmpty) ? sessionId : '__new__';

  String _hostOriginKey(String hostId) {
    final host = state.hosts.where((h) => h.id == hostId).firstOrNull;
    if (host == null) return '';
    if (host.isLocal) return 'local';
    return _normalizeHttpAddress(host).trim().toLowerCase();
  }

  /// Retrieve persisted composer draft text scoped to an explicit `(hostId, sessionId)` pair.
  String getComposerDraftForScope(String hostId, String? sessionId) {
    final hostEntry = _hostContexts[hostId];
    if (hostEntry == null) return '';
    final scope = _draftScopeKey(sessionId);
    final map = hostEntry['sessionDrafts'];
    if (map is Map && map.containsKey(scope)) {
      return map[scope]?.toString() ?? '';
    }
    if (scope == '__new__') {
      return hostEntry['composerDraft']?.toString() ?? '';
    }
    return '';
  }

  /// Retrieve persisted composer draft text scoped to the active host AND active session.
  String getComposerDraftForActiveHost() =>
      getComposerDraftForScope(state.activeHostId, state.activeSessionId);

  /// Update persisted composer draft text scoped strictly to an explicit `(hostId, sessionId)` pair.
  /// Used both during normal typing and when flushing an outgoing draft right before switching hosts/sessions.
  void setComposerDraftForScope(
    String hostId,
    String? sessionId,
    String text, {
    bool markUserNavigated = false,
  }) {
    final scope = _draftScopeKey(sessionId);
    final existingEntry = _hostContexts[hostId];
    final existingDrafts = existingEntry?['sessionDrafts'];
    final currentVal = existingDrafts is Map
        ? (existingDrafts[scope]?.toString() ?? '')
        : (scope == '__new__' ? (existingEntry?['composerDraft']?.toString() ?? '') : '');
    if (currentVal == text) return;
    final entry = existingEntry ?? _hostContexts.putIfAbsent(hostId, () => <String, dynamic>{});
    final Map<String, dynamic> drafts;
    if (existingDrafts is Map<String, dynamic>) {
      drafts = existingDrafts;
    } else if (existingDrafts is Map) {
      drafts = Map<String, dynamic>.from(existingDrafts);
      entry['sessionDrafts'] = drafts;
    } else {
      drafts = <String, dynamic>{};
    }
    if (text.isEmpty) {
      drafts.remove(scope);
      if (scope == '__new__') entry.remove('composerDraft');
    } else {
      if (markUserNavigated && hostId == state.activeHostId) {
        _userNavigatedSinceHostBind = true;
      }
      drafts[scope] = text;
      if (drafts.length > 30) {
        drafts.remove(drafts.keys.first);
      }
      if (scope == '__new__') entry['composerDraft'] = text;
    }
    if (drafts.isEmpty) {
      entry.remove('sessionDrafts');
    } else {
      entry['sessionDrafts'] = drafts;
    }
    // Debounce draft persistence even when clearing on Send so Frame 0 of the
    // send animation never blocks on synchronous SharedPreferences write.
    // App lifecycle pause/background already flushes immediately.
    _persistHostContexts(immediate: false);
  }

  /// Update persisted composer draft text scoped strictly to the active host AND active session.
  /// Mutates host context maps in-place to avoid deep-cloning Maps during typing.
  void setComposerDraftForActiveHost(String text) {
    setComposerDraftForScope(
      state.activeHostId,
      state.activeSessionId,
      text,
      markUserNavigated: true,
    );
  }

  void _saveCurrentHostContext({
    String? hostIdOverride,
    bool immediate = false,
    bool allowClearSession = false,
  }) {
    final hostId = hostIdOverride ?? state.activeHostId;
    final entry = _hostContexts.putIfAbsent(hostId, () => <String, dynamic>{});
    final origin = _hostOriginKey(hostId);
    if (origin.isNotEmpty) {
      entry['lastHostOrigin'] = origin;
    }
    final sid = state.activeSessionId;
    if (sid != null && sid.isNotEmpty && !sid.startsWith('pending-session-')) {
      entry['lastSessionId'] = sid;
    } else if (sid == null &&
        (allowClearSession ||
            (!state.loadingSessions &&
                !state.hydratingDomains &&
                state.connectionPhase == ConnectionPhase.connected))) {
      // NEVER wipe a host's remembered `lastSessionId` when switching away while that host
      // was still connecting, offline, or awaiting auth (where `activeSessionId` is temporarily null)!
      entry.remove('lastSessionId');
    }
    if (state.activeWorkspace.isNotEmpty) {
      entry['lastWorkspace'] = state.activeWorkspace;
    }
    final wsFilter = state.sidebarWorkspaceFilter;
    if (wsFilter != null && wsFilter.isNotEmpty) {
      entry['sidebarWorkspaceFilter'] = wsFilter;
    } else if (allowClearSession ||
        (!state.loadingSessions &&
            !state.hydratingDomains &&
            state.connectionPhase == ConnectionPhase.connected)) {
      entry.remove('sidebarWorkspaceFilter');
    }
    _persistHostContexts(immediate: immediate);
  }

  void _flushHostContextsNow() {
    if (_persistHostContextsTimer == null) return;
    _persistHostContextsTimer?.cancel();
    _persistHostContextsTimer = null;
    if (!mounted) return;
    unawaited(GrassBagStorage.instance.saveHostContexts(_hostContexts));
  }

  void _persistHostContexts({bool immediate = false}) {
    _persistHostContextsTimer?.cancel();
    if (immediate) {
      _persistHostContextsTimer = null;
      if (!mounted) return;
      unawaited(GrassBagStorage.instance.saveHostContexts(_hostContexts));
      return;
    }
    _persistHostContextsTimer = Timer(const Duration(milliseconds: 1200), () {
      _persistHostContextsTimer = null;
      if (!mounted) return;
      unawaited(GrassBagStorage.instance.saveHostContexts(_hostContexts));
    });
  }

  static GrassBagAppState _initialState() {
    final defaultWebHostUrl = kIsWeb
        ? (readBrowserQueryParam('host')?.trim().isNotEmpty == true
            ? readBrowserQueryParam('host')!.trim()
            : 'http://127.0.0.1:3080')
        : '本机内置运行环境';
    final defaultWebToken = kIsWeb
        ? (readBrowserQueryParam('token')?.trim().isNotEmpty == true
            ? readBrowserQueryParam('token')!.trim()
            : 'grassbag-dev-2026')
        : null;

    final p = preloadedInitialPrefs;
    final platformDark =
        ui.PlatformDispatcher.instance.platformBrightness == Brightness.dark;
    final initialDark = p?['isDark'] is bool ? p!['isDark'] as bool : platformDark;
    final initialAccent = GrassBagAccent.values.firstWhere(
      (a) => a.name == p?['accent']?.toString(),
      orElse: () => GrassBagAccent.teal,
    );
    final initialTier = GrassBagGlassTier.values.firstWhere(
      (g) => g.name == p?['glassTier']?.toString(),
      orElse: () => GrassBagGlassTier.liquid,
    );
    final rawOpticalStrength = p?['glassOpticalStrength'];
    final initialOpticalStrength = rawOpticalStrength is num
        ? rawOpticalStrength.toDouble().clamp(0.0, 1.0)
        : 0.50;
    final initialOnboarding =
        p?['onboardingCompleted'] is bool ? p!['onboardingCompleted'] as bool : false;
    final initialAutoFold =
        p?['autoFoldSteps'] is bool ? p!['autoFoldSteps'] as bool : true;
    final initialGroupMode = SessionGroupMode.values.firstWhere(
      (m) => m.name == p?['sessionGroupMode']?.toString(),
      orElse: () => SessionGroupMode.workspace,
    );
    final initialSkippedVer = p?['skippedAppUpdateVersion']?.toString().trim() ?? '';

    final initialHosts = <ManagedHost>[
      ManagedHost(
        id: 'local',
        isLocal: true,
        name: kIsWeb ? '本机 DSH' : '本机',
        address: defaultWebHostUrl,
        latency: '本地',
        online: false,
        bridged: false,
        dshVersion: '检测中',
        token: defaultWebToken,
      ),
    ];
    final preHosts = preloadedInitialHosts;
    if (preHosts != null) {
      for (final raw in preHosts) {
        try {
          final h = ManagedHost.fromJson(raw);
          if (!h.isLocal && initialHosts.every((e) => e.id != h.id)) {
            initialHosts.add(h);
          }
        } catch (_) {}
      }
    }
    final savedActiveHostId = p?['activeHostId']?.toString();
    final initialActiveHostId = (savedActiveHostId != null &&
            initialHosts.any((h) => h.id == savedActiveHostId))
        ? savedActiveHostId
        : 'local';

    return GrassBagAppState(
      isDark: initialDark,
      accent: initialAccent,
      glassTier: initialTier,
      glassOpticalStrength: initialOpticalStrength,
      autoFoldSteps: initialAutoFold,
      sessionGroupMode: initialGroupMode,
      skippedAppUpdateVersion: initialSkippedVer,
      onboardingCompleted: initialOnboarding,
      activeHostId: initialActiveHostId,
      nativeStatusHydrated: !GrassBagNativeBridge.instance.isAndroidNative,
      hosts: initialHosts,
      sessions: const [],
      turns: const [],
      plugins: const [],
    );
  }

  // ---------------------------------------------------------------------------
  // Persistence & Native Runtime Hydration (App-Only Prefs; DSH Owns All Core Config)
  // ---------------------------------------------------------------------------
  Future<void> _hydrateFromStorageAndNative() async {
    final initialGen = _hostConnectGen;
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      // Kick off lightweight read-only native status hydration immediately in parallel with
      // SharedPreferences so `nativeStatusHydrated` and `nativeRuntimeStatus.initialized` land
      // within ~20ms (and resolve immediately in headless tests without SharedPreferences mocks).
      unawaited(refreshNativeStatus(skipAutoConnect: true));
    }
    final storage = GrassBagStorage.instance;
    final loaded = await Future.wait<Object?>([
      preloadedInitialPrefs != null ? Future.value(preloadedInitialPrefs) : storage.loadPrefs(),
      preloadedInitialHosts != null
          ? Future.value(preloadedInitialHosts)
          : storage.loadSavedHosts(),
      storage.loadHostContexts(),
      storage.loadOfflineHistory(),
      storage.loadPendingOutbox(),
    ]);
    final prefs = loaded[0] as Map<String, dynamic>?;
    final savedHosts = loaded[1] as List<Map<String, dynamic>>?;
    final savedContexts = loaded[2] as Map<String, Map<String, dynamic>>?;
    final savedOfflineHistory = loaded[3] as Map<String, dynamic>?;
    final savedOutbox = loaded[4] as List<Map<String, dynamic>>?;
    if (!mounted) return;
    if (savedOfflineHistory != null && savedOfflineHistory.isNotEmpty) {
      for (final entry in savedOfflineHistory.entries) {
        if (entry.value is Map) {
          _offlineHistoryByHost.putIfAbsent(
            entry.key,
            () => Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
    }
    if (savedOutbox != null && savedOutbox.isNotEmpty) {
      final existingIds = _pendingOutbox.map((e) => e['id']?.toString()).toSet();
      for (final item in savedOutbox) {
        final id = item['id']?.toString() ?? '';
        if (id.isNotEmpty && existingIds.add(id)) {
          _pendingOutbox.add(Map<String, dynamic>.from(item));
        }
      }
      _syncOutboxState();
    }
    if (savedContexts != null && savedContexts.isNotEmpty) {
      for (final entry in savedContexts.entries) {
        final existing = _hostContexts[entry.key];
        if (existing == null) {
          _hostContexts[entry.key] = Map<String, dynamic>.from(entry.value);
        } else {
          // Deep-merge persisted context under any in-memory cold-start edits so
          // early typing never wipes remembered `lastSessionId` / `lastWorkspace` / sibling drafts.
          for (final kv in entry.value.entries) {
            if (kv.key == 'sessionDrafts' && kv.value is Map) {
              final memDrafts = existing['sessionDrafts'] is Map
                  ? Map<String, dynamic>.from(existing['sessionDrafts'] as Map)
                  : <String, dynamic>{};
              for (final d in (kv.value as Map).entries) {
                memDrafts.putIfAbsent(d.key.toString(), () => d.value);
              }
              if (memDrafts.isNotEmpty) {
                existing['sessionDrafts'] = memDrafts;
              }
            } else {
              existing.putIfAbsent(kv.key, () => kv.value);
            }
          }
        }
      }
    }

    List<ManagedHost>? restoredHosts;
    String? restoredActiveHostId;
    final hasRemoteSavedHosts = savedHosts != null && savedHosts.any((raw) => raw['isLocal'] != true);
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      if (hasRemoteSavedHosts) {
        await _refreshDeviceLocalIps();
      } else {
        // Never block local cold-start connection behind enumerating Android network interfaces!
        unawaited(_refreshDeviceLocalIps());
      }
    }
    if (savedHosts != null && savedHosts.isNotEmpty) {
      const legacyDemoAddresses = {'https://dsh.myhost.dev', 'http://192.168.1.24:3080'};
      final localUri = Uri.tryParse(state.localHost.address);
      final isAndroid = GrassBagNativeBridge.instance.isAndroidNative;
      final candidates = <ManagedHost>[];
      for (final raw in savedHosts) {
        final h = ManagedHost.fromJson(raw);
        if (!h.isLocal && legacyDemoAddresses.contains(h.address)) continue;
        if (!h.isLocal) {
          final hUri = Uri.tryParse(h.address);
          if (hUri != null &&
              isSelfDeviceUri(
                hUri,
                _deviceLocalIps,
                isAndroidNative: isAndroid,
                localHostUri: localUri,
              )) {
            continue;
          }
        }
        if (h.isLocal && kIsWeb && !h.address.startsWith('http')) {
          candidates.add(state.localHost);
          continue;
        }
        candidates.add(h);
      }
      // Hydrate Keystore secrets in parallel across all hosts instead of serial IPC roundtrips!
      final parsed = await Future.wait<ManagedHost>(
        candidates.map((h) async {
          if (identical(h, state.localHost)) return h;
          final secrets = await Future.wait<String?>([
            GrassBagNativeBridge.instance.getSecret('host_token_${h.id}'),
            GrassBagNativeBridge.instance.getSecret('host_cookie_${h.id}'),
          ]);
          final tok = secrets[0];
          final ck = secrets[1];
          return (tok != null || ck != null)
              ? h.copyWith(token: tok, sessionCookie: ck)
              : h;
        }),
      );
      if (parsed.any((h) => h.isLocal)) {
        restoredHosts = parsed;
        final savedActiveHostId = prefs?['activeHostId']?.toString();
        if (savedActiveHostId != null && parsed.any((h) => h.id == savedActiveHostId)) {
          restoredActiveHostId = savedActiveHostId;
        }
      }
    }
    if (!mounted) return;

    final userSwitchedDuringHydrate = _hostConnectGen != initialGen;
    final hasSavedContexts = savedContexts != null && savedContexts.isNotEmpty;
    if (prefs != null || restoredHosts != null || hasSavedContexts) {
      final accentName = prefs?['accent']?.toString();
      final tierName = prefs?['glassTier']?.toString();
      final skippedUpdateVer = prefs?['skippedAppUpdateVersion']?.toString().trim();
      final lastCheckedMs = (prefs?['lastAppUpdateCheckedAtMs'] as num?)?.toInt();
      final lastCheckedAt = (lastCheckedMs != null && lastCheckedMs > 0)
          ? DateTime.fromMillisecondsSinceEpoch(lastCheckedMs)
          : null;
      // Never clobber a host the user already switched to (or newly added), nor wipe
      // live runtime status / tokens hydrated in parallel while storage was loading!
      final currentById = {for (final cur in state.hosts) cur.id: cur};
      final mergedHosts = restoredHosts == null
          ? state.hosts
          : [
              for (final r in restoredHosts)
                if (currentById.containsKey(r.id))
                  (() {
                    final cur = currentById[r.id]!;
                    if (userSwitchedDuringHydrate) return cur;
                    final liveOnline = cur.online || r.online;
                    final liveLatency = cur.online || (cur.latency != '--' && cur.latency != '本地')
                        ? cur.latency
                        : r.latency;
                    return r.copyWith(
                      online: liveOnline,
                      bridged: cur.bridged || r.bridged,
                      directMode: cur.directMode || r.directMode,
                      latency: liveLatency,
                      dshVersion: cur.online ? cur.dshVersion : r.dshVersion,
                      launcherMode: (cur.isLocal && state.nativeStatusHydrated)
                          ? cur.launcherMode
                          : r.launcherMode,
                      token: (cur.token != null && cur.token!.isNotEmpty) ? cur.token : r.token,
                      sessionCookie: (cur.sessionCookie != null && cur.sessionCookie!.isNotEmpty)
                          ? cur.sessionCookie
                          : r.sessionCookie,
                      lastError: liveOnline ? null : (cur.lastError ?? r.lastError),
                      lastErrorCode: liveOnline ? null : (cur.lastErrorCode ?? r.lastErrorCode),
                      clearLastError: liveOnline,
                    );
                  }())
                else
                  r,
              for (final cur in state.hosts)
                if (!restoredHosts.any((r) => r.id == cur.id)) cur,
            ];
      state = state.copyWith(
        isDark: prefs?['isDark'] is bool ? prefs!['isDark'] as bool : state.isDark,
        accent: accentName != null
            ? GrassBagAccent.values.firstWhere(
                (a) => a.name == accentName,
                orElse: () => state.accent,
              )
            : state.accent,
        glassTier: tierName != null
            ? GrassBagGlassTier.values.firstWhere(
                (g) => g.name == tierName,
                orElse: () => state.glassTier,
              )
            : state.glassTier,
        glassOpticalStrength: (!_userEditedGlassOpticalStrength &&
                prefs?['glassOpticalStrength'] is num)
            ? (prefs!['glassOpticalStrength'] as num).toDouble().clamp(0.0, 1.0)
            : state.glassOpticalStrength,
        autoFoldSteps: prefs?['autoFoldSteps'] is bool
            ? prefs!['autoFoldSteps'] as bool
            : state.autoFoldSteps,
        useSystemProxy: prefs?['useSystemProxy'] is bool
            ? prefs!['useSystemProxy'] as bool
            : state.useSystemProxy,
        safetyPolicy: prefs?['safetyPolicy']?.toString() ?? state.safetyPolicy,
        phoneConfirmHighRisk: prefs?['phoneConfirmHighRisk'] is bool
            ? prefs!['phoneConfirmHighRisk'] as bool
            : state.phoneConfirmHighRisk,
        phoneAutoReturn: prefs?['phoneAutoReturn'] is bool
            ? prefs!['phoneAutoReturn'] as bool
            : state.phoneAutoReturn,
        phoneShowEdgeAurora: prefs?['phoneShowEdgeAurora'] is bool
            ? prefs!['phoneShowEdgeAurora'] as bool
            : state.phoneShowEdgeAurora,
        phoneShowGestureFx: prefs?['phoneShowGestureFx'] is bool
            ? prefs!['phoneShowGestureFx'] as bool
            : state.phoneShowGestureFx,
        onboardingCompleted: prefs?['onboardingCompleted'] is bool
            ? prefs!['onboardingCompleted'] as bool
            : state.onboardingCompleted,
        skippedAppUpdateVersion: (skippedUpdateVer != null && skippedUpdateVer.isNotEmpty)
            ? skippedUpdateVer
            : state.skippedAppUpdateVersion,
        lastAppUpdateCheckedAt: lastCheckedAt ?? state.lastAppUpdateCheckedAt,
        sessionGroupMode: SessionGroupMode.values.firstWhere(
          (m) => m.name == prefs?['sessionGroupMode']?.toString(),
          orElse: () => state.sessionGroupMode,
        ),
        hosts: mergedHosts,
        activeHostId: userSwitchedDuringHydrate
            ? state.activeHostId
            : (restoredActiveHostId ?? state.activeHostId),
        draftHydratedSignal:
            hasSavedContexts ? state.draftHydratedSignal + 1 : state.draftHydratedSignal,
      );
    }

    if (!mounted) return;
    // Listen to Android Kotlin native runtime events (progress, engine_ready, logs, a11y, phone handoff).
    final native = GrassBagNativeBridge.instance;
    if (native.isAndroidNative) {
      unawaited(_loadInstalledAppVersion());
      unawaited(native.setSystemProxy(state.useSystemProxy));
      _syncNativeThemePalette();
      try {
        _nativeSub = native.events.listen((evt) {
          if (!mounted) return;
          if (evt.type == 'runtime_progress') {
            final nextPct = (evt.data['percent'] as num?)?.toInt() ?? 0;
            final nextMsg = evt.data['message']?.toString() ?? '';
            final nextStage = evt.data['stage']?.toString() ?? '';
            final nextCanCancel =
                nextPct > 0 && nextPct < 100 && evt.data['canCancel'] == true;
            if (nextPct != state.runtimeProgressPct ||
                nextMsg != state.runtimeProgressMsg ||
                nextStage != state.runtimeProgressStage ||
                nextCanCancel != state.runtimeProgressCanCancel) {
              state = state.copyWith(
                runtimeProgressPct: nextPct,
                runtimeProgressMsg: nextMsg,
                runtimeProgressStage: nextPct <= 0 || nextPct >= 100 ? '' : nextStage,
                runtimeProgressCanCancel: nextCanCancel,
              );
            }
          } else if (evt.type == 'engine_log') {
            // Strictly scope local Android container logs to the local host so remote hosts never bleed local logs.
            if (!state.activeHost.isLocal) return;
            final batchLines = evt.data['lines'];
            final addedLines = <String>[];
            if (batchLines is List && batchLines.isNotEmpty) {
              for (final item in batchLines) {
                final s = item?.toString() ?? '';
                if (s.isNotEmpty) addedLines.add(s);
              }
            } else {
              final line = evt.data['line']?.toString() ?? '';
              if (line.isNotEmpty) addedLines.add(line);
            }
            if (addedLines.isNotEmpty) {
              _pendingEngineLogs.addAll(addedLines);
              _engineLogFlushTimer ??= Timer(const Duration(milliseconds: 200), () {
                _engineLogFlushTimer = null;
                if (!mounted || !state.activeHost.isLocal || _pendingEngineLogs.isEmpty) {
                  _pendingEngineLogs.clear();
                  return;
                }
                final next = [...state.engineLogs, ..._pendingEngineLogs];
                _pendingEngineLogs.clear();
                state = state.copyWith(
                  engineLogs: next.length > 240 ? next.sublist(next.length - 240) : next,
                );
              });
            }
          } else if (evt.type == 'engine_state') {
            unawaited(refreshNativeStatus(connectGen: _hostConnectGen));
          } else if (evt.type == 'accessibility_state') {
            unawaited(refreshPermissionsOnly());
          } else if (evt.type == 'network_changed') {
            unawaited(_refreshDeviceLocalIps());
            final live = _liveClient;
            if (!state.activeHost.isLocal) {
              if (live != null) {
                live.resetConnectionPool();
                if (!state.activeHost.needsAuth) {
                  if (live.stream.phase == ConnectionPhase.connected) {
                    unawaited(live.stream.checkLiveness(force: true));
                  } else {
                    live.stream.reconnectNow();
                  }
                }
              } else if (!state.activeHost.needsAuth &&
                  state.connectionPhase != ConnectionPhase.connecting &&
                  state.connectionPhase != ConnectionPhase.needsAuth) {
                // Network just returned while an offline remote host is active — auto-reconnect!
                final gen = ++_hostConnectGen;
                state = state.copyWith(
                  connectionPhase: ConnectionPhase.connecting,
                  loadingSessions: true,
                );
                unawaited(_tryConnectLiveHost(state.activeHost, gen: gen, restoreLastSession: false));
              }
            }
          } else if (evt.type == 'engine_web_url') {
            unawaited(refreshNativeStatus(skipAutoConnect: true, forceFresh: true));
          } else if (evt.type == 'engine_ready') {
            final sock = evt.data['bridgeSocketPath']?.toString() ?? '';
            final httpUrl = evt.data['bridgeHttpUrl']?.toString() ?? 'http://127.0.0.1:13080';
            final token = evt.data['bridgeToken']?.toString() ?? '';
            unawaited(refreshNativeStatus(skipAutoConnect: true, forceFresh: true));
            if (state.activeHost.isLocal && token.isNotEmpty) {
              unawaited(_connectLocalAndroidEngine(sock, httpUrl, token, gen: _hostConnectGen));
            }
          } else if (evt.type == 'phone_handoff') {
            final reason = (evt.data['message']?.toString() ?? '').trim();
            final displayReason = reason.isNotEmpty ? reason : '需要你在屏幕上完成当前步骤，完成后点击继续';
            state = state.copyWith(
              phoneLiveActive: true,
              phoneLivePaused: true,
              phoneHandoffReason: displayReason,
            );
            showToast(displayReason, tone: ToastTone.warn);
          } else if (evt.type == 'phone_step_event') {
            final stepSid = evt.data['sessionId']?.toString().trim() ?? '';
            if (stepSid.isNotEmpty) _activePhoneSessionId = stepSid;
            final isPaused = evt.data['paused'] == true;
            state = state.copyWith(
              phoneLiveActive: evt.data['active'] != false,
              phoneLivePaused: isPaused,
              phoneHandoffReason: isPaused ? state.phoneHandoffReason : '',
              phoneLiveAction: evt.data['action']?.toString() ?? state.phoneLiveAction,
              phoneLiveApp: evt.data['appLabel']?.toString() ?? state.phoneLiveApp,
              phoneLiveSteps: (evt.data['stepCount'] as num?)?.toInt() ?? state.phoneLiveSteps,
            );
          } else if (evt.type == 'phone_pause_changed') {
            final isPaused = evt.data['paused'] == true;
            state = state.copyWith(
              phoneLivePaused: isPaused,
              phoneHandoffReason: isPaused ? state.phoneHandoffReason : '',
            );
          } else if (evt.type == 'phone_turn_end') {
            final endedSid = evt.data['sessionId']?.toString().trim() ?? '';
            if (endedSid.isEmpty || endedSid == _activePhoneSessionId) {
              _activePhoneSessionId = null;
            }
            final steps = (evt.data['stepsCount'] as num?)?.toInt() ?? state.phoneLiveSteps;
            final autoReturned = evt.data['autoReturn'] == true;
            state = state.copyWith(
              phoneLiveActive: false,
              phoneLivePaused: false,
              phoneHandoffReason: '',
              phoneLiveAction: '',
              phoneLiveApp: '',
              phoneLiveSteps: 0,
            );
            unawaited(refreshPermissionsOnly());
            if (steps > 0 && evt.data['reason']?.toString() != 'stopped') {
              showToast(
                autoReturned
                    ? '手机操控已完成（共 $steps 步），已自动返回 GrassBag'
                    : '手机操控已完成（共 $steps 步）',
                tone: ToastTone.ok,
              );
            }
          } else if (evt.type == 'phone_emergency_stop') {
            final targetSids = _extractEmergencyStopSessionIds(evt.data);
            _activePhoneSessionId = null;
            state = state.copyWith(
              emergencyStopped: true,
              phoneLiveActive: false,
              phoneLivePaused: false,
              phoneHandoffReason: '',
            );
            _cancelSpecificLocalSessions(targetSids, announce: false);
            unawaited(refreshNativeStatus(skipAutoConnect: true));
            showToast('已急停手机操控并终止对应操控任务', tone: ToastTone.warn);
          } else if (evt.type == 'notification.opened') {
            unawaited(handleNotificationOpened(evt.data));
          } else if (evt.type == 'pairing.deeplink') {
            final uri = evt.data['uri']?.toString().trim() ?? '';
            if (uri.isNotEmpty) {
              enqueuePairDeepLink(uri);
            }
          } else if (evt.type == 'network.changed') {
            clearDiscoveredLanHosts();
          }
        });
        unawaited(() async {
          final launchPayload = await GrassBagNativeBridge.instance.takePendingNotification();
          if (launchPayload != null && launchPayload.isNotEmpty && mounted) {
            await handleNotificationOpened(launchPayload);
          }
          final launchPairLink = await GrassBagNativeBridge.instance.takePendingPairLink();
          if (launchPairLink != null && launchPairLink.isNotEmpty && mounted) {
            enqueuePairDeepLink(launchPairLink);
          }
        }());
      } catch (_) {
        // Headless unit test without initialized ServicesBinding
      }
      if (userSwitchedDuringHydrate) {
        unawaited(refreshNativeStatus(skipAutoConnect: true));
        return;
      }
      final bootGen = _hostConnectGen;
      if (state.activeHost.isLocal &&
          (_liveClient == null || state.connectionPhase != ConnectionPhase.connected)) {
        state = state.copyWith(loadingSessions: true);
      }
      await refreshNativeStatus(connectGen: bootGen);
      if (!mounted) return;
      if (!state.activeHost.isLocal && bootGen == _hostConnectGen) {
        state = state.copyWith(
          connectionPhase: ConnectionPhase.connecting,
          loadingSessions: true,
        );
        unawaited(_tryConnectLiveHost(state.activeHost, gen: bootGen));
      }
    } else if (kIsWeb) {
      _scheduleSilentAppUpdateCheck();
      if (userSwitchedDuringHydrate) return;
      // Auto-connect Flutter Web directly to active host (or local DSH + dsh-gbridge)!
      final bootGen = _hostConnectGen;
      if (!state.activeHost.isLocal) {
        state = state.copyWith(
          connectionPhase: ConnectionPhase.connecting,
          loadingSessions: true,
        );
        unawaited(_tryConnectLiveHost(state.activeHost, gen: bootGen));
      } else {
        final local = state.localHost;
        final webAddr = local.address.startsWith('http')
            ? local.address
            : 'http://127.0.0.1:3080';
        final webTok = local.token ?? 'grassbag-dev-2026';
        final updatedLocal = local.copyWith(address: webAddr, token: webTok);
        state = state.copyWith(
          hosts: [for (final h in state.hosts) h.isLocal ? updatedLocal : h],
          connectionPhase: ConnectionPhase.connecting,
          loadingSessions: true,
        );
        unawaited(_tryConnectLiveHost(updatedLocal, gen: bootGen));
      }
    }
  }

  void _applyPermissionsAndSafetySnapshot(
    NativePermissionsStatus? perms,
    Map<String, dynamic>? safety,
  ) {
    if (!mounted || (perms == null && safety == null)) return;
    final nextPerms = perms ?? state.nativePermissions;
    final nextAccess = perms?.accessibilityEnabled ?? state.phoneAccessibility;
    final nextOverlay = perms?.overlayGranted ?? state.phoneOverlay;
    final nextShizuku = perms?.shizukuInstalled ?? state.phoneShizuku;
    final nextConfirmRisk = safety?['confirmHighRisk'] is bool
        ? safety!['confirmHighRisk'] as bool
        : state.phoneConfirmHighRisk;
    final nextAutoReturn = safety?['autoReturnOnComplete'] is bool
        ? safety!['autoReturnOnComplete'] as bool
        : state.phoneAutoReturn;
    final nextEdgeAurora = safety?['showEdgeAurora'] is bool
        ? safety!['showEdgeAurora'] as bool
        : state.phoneShowEdgeAurora;
    final nextGestureFx = safety?['showGestureFx'] is bool
        ? safety!['showGestureFx'] as bool
        : state.phoneShowGestureFx;
    final nextPaused = safety?['paused'] is bool ? safety!['paused'] as bool : state.phoneLivePaused;
    final nextEmergency = safety?['emergencyStopped'] is bool
        ? safety!['emergencyStopped'] as bool
        : state.emergencyStopped;
    final nextPolicy = safety?['policy']?.toString() ?? state.safetyPolicy;
    final rawAudit = safety?['audit'];
    final auditList = rawAudit is List
        ? rawAudit
            .whereType<Map<Object?, Object?>>()
            .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
            .toList(growable: false)
        : state.safetyAudit;
    final auditChanged = !_deepEquals(auditList, state.safetyAudit);
    final nativePhoneBusy =
        safety?['activeTurnLocked'] == true || safety?['hudVisible'] == true;
    final shouldClearStalePhoneLive =
        safety != null && !nativePhoneBusy && state.phoneLiveActive && !state.isStreaming;
    if (nextPerms != state.nativePermissions ||
        nextAccess != state.phoneAccessibility ||
        nextOverlay != state.phoneOverlay ||
        nextShizuku != state.phoneShizuku ||
        nextConfirmRisk != state.phoneConfirmHighRisk ||
        nextAutoReturn != state.phoneAutoReturn ||
        nextEdgeAurora != state.phoneShowEdgeAurora ||
        nextGestureFx != state.phoneShowGestureFx ||
        nextPaused != state.phoneLivePaused ||
        nextEmergency != state.emergencyStopped ||
        nextPolicy != state.safetyPolicy ||
        shouldClearStalePhoneLive ||
        auditChanged) {
      state = state.copyWith(
        nativePermissions: nextPerms,
        phoneAccessibility: nextAccess,
        phoneOverlay: nextOverlay,
        phoneShizuku: nextShizuku,
        phoneConfirmHighRisk: nextConfirmRisk,
        phoneAutoReturn: nextAutoReturn,
        phoneShowEdgeAurora: nextEdgeAurora,
        phoneShowGestureFx: nextGestureFx,
        phoneLiveActive: shouldClearStalePhoneLive ? false : state.phoneLiveActive,
        phoneLivePaused: shouldClearStalePhoneLive ? false : nextPaused,
        phoneLiveAction: shouldClearStalePhoneLive ? '' : state.phoneLiveAction,
        phoneLiveApp: shouldClearStalePhoneLive ? '' : state.phoneLiveApp,
        phoneLiveSteps: shouldClearStalePhoneLive ? 0 : state.phoneLiveSteps,
        emergencyStopped: nextEmergency,
        safetyPolicy: nextPolicy,
        safetyAudit: auditChanged ? auditList : state.safetyAudit,
      );
    }
  }

  @visibleForTesting
  void applyPermissionsAndSafetySnapshotForTest(
    NativePermissionsStatus? perms,
    Map<String, dynamic>? safety,
  ) =>
      _applyPermissionsAndSafetySnapshot(perms, safety);

  /// Fast, non-blocking refresh of Android permission & SafetyGate status ONLY.
  /// Never waits for container/runtime I/O and is never cancelled by host-switch generations,
  /// guaranteeing Accessibility / Overlay / Storage toggles reflect instantaneously on return!
  Future<bool> refreshPermissionsOnly() {
    final native = GrassBagNativeBridge.instance;
    if (!native.isAndroidNative) {
      _lastPermissionsRefreshSucceeded = true;
      return Future<bool>.value(true);
    }
    final existing = _inFlightPermissionsRefresh;
    if (existing != null) return existing;
    final fut = () async {
      final res = await Future.wait<Object?>([
        native.getPermissionsStatus(),
        native.getSafetyStatus(),
      ]);
      final perms = res[0] as NativePermissionsStatus?;
      final safety = res[1] as Map<String, dynamic>?;
      final ok = perms != null && safety != null;
      _lastPermissionsRefreshSucceeded = ok;
      if (!mounted) return ok;
      _applyPermissionsAndSafetySnapshot(perms, safety);
      return ok;
    }();
    _inFlightPermissionsRefresh = fut;
    fut.whenComplete(() {
      if (identical(_inFlightPermissionsRefresh, fut)) {
        _inFlightPermissionsRefresh = null;
      }
    });
    return fut;
  }

  /// Called on `AppLifecycleState.inactive` while the Activity is STILL foreground-eligible on
  /// Android 12–16, ensuring `GrassBagEngineService` and CPU/Wi-Fi locks are promoted BEFORE
  /// Android drops process importance on app switch.
  void handleAppInactivating() {
    _flushHostContextsNow();
    if (_persistPrefsTimer != null) _persistPrefs(immediate: true);
    if (_persistHostsTimer != null) _persistHosts(immediate: true);
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      _syncAndroidKeepalive(force: true);
    }
  }

  /// Records background entry timestamp, flushes pending drafts/prefs, and immediately reinforces
  /// Android foreground service + CPU/Wi-Fi keepalive when replies, phone control, or jobs are active.
  void handleAppPaused() {
    _lastBackgroundedAt = DateTime.now();
    _flushHostContextsNow();
    if (_persistPrefsTimer != null) _persistPrefs(immediate: true);
    if (_persistHostsTimer != null) _persistHosts(immediate: true);
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      _syncAndroidKeepalive(force: true);
    }
  }

  /// Single app-wide foreground resume handler called from `GrassBagShell`.
  /// Re-reads Android runtime/permissions (e.g. returning from Accessibility/Battery/Overlay
  /// settings), probes WS liveness so frozen mobile sockets reconnect immediately, and
  /// skips redundant 10-RPC resyncs on brief (< 3s) pauses when the WS is still connected!
  Future<void> handleAppResumed() async {
    if (!mounted) return;
    // `_lastBackgroundedAt == null` means a transient OS overlay (`resumed -> inactive -> resumed`,
    // such as notification shade, Control Center, permission prompt, or FaceID) rather than a real
    // background suspension — NEVER treat it as 999999ms or kill in-flight HTTP RPCs!
    final wasActuallyBackgrounded = _lastBackgroundedAt != null;
    final bgMs = wasActuallyBackgrounded
        ? DateTime.now().difference(_lastBackgroundedAt!).inMilliseconds
        : 0;
    _lastBackgroundedAt = null;
    if (wasActuallyBackgrounded && bgMs >= 1500) {
      _wasRecentlyBackgrounded = true;
    }
    // Allow automatic local-engine recovery if Android OOM-killed the container while backgrounded,
    // while strictly respecting an explicit user Stop action (`_userStoppedLocalEngine`).
    if (!_userStoppedLocalEngine) {
      _autoStartRequestedGen = -1;
    }
    unawaited(_refreshDeviceLocalIps());
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      _syncAndroidKeepalive(force: true);
      // refreshNativeStatus already fetches runtime + permissions + safety in a single parallel batch!
      unawaited(refreshNativeStatus(connectGen: _hostConnectGen));
    }
    final client = _liveClient;
    if (client != null) {
      // Avoid forcibly closing in-flight remote HTTP sockets during transient overlays or brief switches!
      final activeTaskRunning = state.isStreaming || state.phoneLiveActive;
      final shouldResetRemotePool = wasActuallyBackgrounded &&
          !state.activeHost.isLocal &&
          (activeTaskRunning ? bgMs >= 15000 : bgMs >= 3000);
      if (shouldResetRemotePool) {
        client.resetConnectionPool();
      }
      if (client.stream.phase != ConnectionPhase.connected) {
        client.stream.reconnectNow();
        return;
      }
      // On pure transient overlays (`!wasActuallyBackgrounded`), skip redundant liveness/10-RPC churn!
      if (!wasActuallyBackgrounded) return;
      final alive = await client.stream.checkLiveness(
        timeout: const Duration(milliseconds: 2500),
      );
      if (!mounted || !_isStillLive(client)) return;
      if (!alive) {
        // Bypass the 4s silent reconnect grace window when resume explicitly detected a dead socket!
        _reconnectGraceTimer?.cancel();
        _reconnectGraceTimer = null;
        if (state.connectionPhase == ConnectionPhase.connected) {
          state = state.copyWith(
            connectionPhase: ConnectionPhase.reconnecting,
            streamStalled: state.isStreaming ? true : state.streamStalled,
          );
        }
        if (!state.activeHost.isLocal) {
          client.resetConnectionPool();
        }
        return;
      }
      // Serialize resume catch-up (`refreshSessionsList` BEFORE authoritative `_syncLiveSessionBundle`)
      // so a turn that finished while backgrounded is never rejected by stale `running: true`!
      final shouldResync =
          state.connectionPhase == ConnectionPhase.connected &&
          (bgMs >= 3000 || (state.isStreaming && bgMs >= 1500));
      if (shouldResync) {
        _wasRecentlyBackgrounded = false;
        await refreshSessionsList(silent: true);
        if (!mounted || !_isStillLive(client)) return;
        final sid = state.activeSessionId;
        if (sid != null && !sid.startsWith('pending-session-')) {
          await _syncLiveSessionBundle(
            sid,
            jumpToBottomOnLoad: false,
            authoritativeSync: true,
          );
        }
      }
    } else if (!state.activeHost.isLocal &&
        !state.activeHost.needsAuth &&
        state.connectionPhase != ConnectionPhase.connecting &&
        state.connectionPhase != ConnectionPhase.needsAuth) {
      // Auto-reconnect remote host after returning from background or network handoff
      // (skip when calmly waiting for user to paste token / authorize!).
      final gen = ++_hostConnectGen;
      state = state.copyWith(
        connectionPhase: ConnectionPhase.connecting,
        loadingSessions: true,
      );
      unawaited(_tryConnectLiveHost(state.activeHost, gen: gen));
    }
  }

  Future<bool> requestRuntimePermission(String target) async {
    final native = GrassBagNativeBridge.instance;
    if (!native.isAndroidNative) {
      showToast('仅 Android 设备支持系统运行时权限授权', tone: ToastTone.info);
      return false;
    }
    final res = await native.requestRuntimePermission(target);
    await refreshNativeStatus(skipAutoConnect: true, forceFresh: true);
    if (!mounted) return false;
    final granted = res['granted'] == true;
    if (granted) {
      showToast('已获取权限');
    } else if (res['permanentlyDenied'] == true) {
      showToast('请在系统应用信息中手动开启该权限', tone: ToastTone.warn);
      await native.openPermissionSettings('app_details');
    } else if (res['error'] != null) {
      showToast(res['error'].toString(), tone: ToastTone.warn);
    }
    return granted;
  }

  void completeOnboarding() {
    if (state.onboardingCompleted) return;
    state = state.copyWith(onboardingCompleted: true);
    _persistPrefs(immediate: true);
  }

  /// Persist ONLY GrassBag app-level preferences.
  /// All DSH core settings (models, providers, presets, permissions, workspaces,
  /// schedules, goals, MCP, plugins) live exclusively in DSH and are never persisted here.
  void _persistPrefs({bool immediate = false}) {
    _persistPrefsTimer?.cancel();
    void flush() {
      _persistPrefsTimer = null;
      if (!mounted) return;
      unawaited(
        GrassBagStorage.instance.savePrefs({
          'isDark': state.isDark,
          'accent': state.accent.name,
          'glassTier': state.glassTier.name,
          'glassOpticalStrength': state.glassOpticalStrength,
          'autoFoldSteps': state.autoFoldSteps,
          'useSystemProxy': state.useSystemProxy,
          'safetyPolicy': state.safetyPolicy,
          'phoneConfirmHighRisk': state.phoneConfirmHighRisk,
          'phoneAutoReturn': state.phoneAutoReturn,
          'phoneShowEdgeAurora': state.phoneShowEdgeAurora,
          'phoneShowGestureFx': state.phoneShowGestureFx,
          'onboardingCompleted': state.onboardingCompleted,
          'sessionGroupMode': state.sessionGroupMode.name,
          'activeHostId': state.activeHostId,
          if (state.skippedAppUpdateVersion != null && state.skippedAppUpdateVersion!.isNotEmpty)
            'skippedAppUpdateVersion': state.skippedAppUpdateVersion,
          if (state.lastAppUpdateCheckedAt != null)
            'lastAppUpdateCheckedAtMs': state.lastAppUpdateCheckedAt!.millisecondsSinceEpoch,
        }),
      );
    }
    if (immediate) {
      flush();
    } else {
      _persistPrefsTimer = Timer(const Duration(milliseconds: 180), flush);
    }
  }

  void _persistHosts({bool immediate = false}) {
    _persistHostsTimer?.cancel();
    void flush() {
      _persistHostsTimer = null;
      if (!mounted) return;
      unawaited(
        GrassBagStorage.instance.saveHosts(
          state.hosts.map((h) => h.toJson()).toList(growable: false),
        ),
      );
    }
    if (immediate) {
      flush();
    } else {
      _persistHostsTimer = Timer(const Duration(milliseconds: 180), flush);
    }
  }

  void _clearPendingStreamCoalesce() {
    _streamCoalesceTimer?.cancel();
    _streamCoalesceTimer = null;
    _pendingStreamTelemetry = null;
    _pendingCtxUsedK = null;
    _pendingCtxMaxK = null;
    _pendingCtxPct = null;
    _pendingCtxBreakdown = null;
    _pendingStreamPlanMode = null;
    _pendingStreamTodos = null;
    _pendingStreamSubagents = null;
    _pendingStreamGoals = null;
    _pendingStreamQueue = null;
    _pendingStreamTitle = null;
    _pendingStreamReduced = false;
    _pendingStreamTelemetryChanged = false;
    _lastLiveTpsEmitAt = null;
  }

  Future<void> refreshNativeStatus({
    int? connectGen,
    bool skipAutoConnect = false,
    bool forceFresh = false,
    bool awaitPermissions = false,
  }) {
    if (!skipAutoConnect) {
      _pendingAutoConnectRequested = true;
    }
    if (_inFlightNativeStatus != null && skipAutoConnect && !forceFresh && !awaitPermissions) {
      return _inFlightNativeStatus!;
    }
    final fut = _refreshNativeStatusImpl(
      connectGen: connectGen,
      skipAutoConnect: skipAutoConnect,
      awaitPermissions: awaitPermissions,
    );
    _inFlightNativeStatus = fut;
    fut.whenComplete(() {
      if (identical(_inFlightNativeStatus, fut)) {
        _inFlightNativeStatus = null;
      }
    });
    return fut;
  }

  Future<void> _refreshNativeStatusImpl({
    int? connectGen,
    bool skipAutoConnect = false,
    bool awaitPermissions = false,
  }) async {
    final seq = ++_nativeStatusSeq;
    final native = GrassBagNativeBridge.instance;
    // Kick off permissions + safety in parallel off the critical local-engine connect path so
    // cold-start local UDS connection never waits behind 6+ Android Binder permission IPCs!
    final permsAndSafetyFuture = Future.wait<Object?>([
      native.getPermissionsStatus(),
      native.getSafetyStatus(),
    ]);
    final rt = await native.getRuntimeStatus();
    if (!mounted || seq != _nativeStatusSeq) return;
    if (awaitPermissions) {
      final extraRes = await permsAndSafetyFuture;
      final perms = extraRes[0] as NativePermissionsStatus?;
      final safety = extraRes[1] as Map<String, dynamic>?;
      _lastPermissionsRefreshSucceeded =
          !native.isAndroidNative || (perms != null && safety != null);
      if (!mounted || seq != _nativeStatusSeq) return;
      _applyPermissionsAndSafetySnapshot(perms, safety);
    } else {
      // Apply permissions & safety asynchronously as soon as their IPCs settle (or immediately if already done).
      unawaited(
        permsAndSafetyFuture.then((extraRes) {
          final perms = extraRes[0] as NativePermissionsStatus?;
          final safety = extraRes[1] as Map<String, dynamic>?;
          _lastPermissionsRefreshSucceeded =
              !native.isAndroidNative || (perms != null && safety != null);
          if (!mounted || seq != _nativeStatusSeq) return;
          _applyPermissionsAndSafetySnapshot(perms, safety);
        }),
      );
    }
    if (connectGen != null && connectGen != _hostConnectGen) return;
    final shouldAutoConnect = !skipAutoConnect || _pendingAutoConnectRequested;
    if (shouldAutoConnect) {
      _pendingAutoConnectRequested = false;
    }

    var nextHosts = state.hosts;
    var nextToolkits = state.containerToolkits;
    if (rt != null) {
      final installedSet = rt.installedToolkits.toSet();
      nextToolkits = [
        for (final tk in state.containerToolkits)
          tk.copyWith(
            installed: installedSet.contains(tk.id) || (tk.id == 'core-node' && rt.containerExtracted),
          ),
      ];
      nextHosts = [
        for (final h in state.hosts)
          h.isLocal
              ? h.copyWith(
                  dshVersion: rt.dshVersion,
                  dshLatest: (state.activeHost.isLocal && state.updateCheck?.hasUpdate == true)
                      ? state.updateCheck!.recommendedVersion
                      : rt.dshVersion,
                  dshPrevVersion: rt.canRollback ? rt.dshPrevVersion : '',
                  helperVersion: rt.bridgeVersion,
                  containerVersion: rt.containerVersion,
                  containerLatest: rt.containerVersion,
                  sdcardMounted: rt.sdcardMounted,
                  online: rt.engineRunning,
                  bridged: rt.engineRunning && (state.activeHost.isLocal ? _liveClient != null : h.bridged),
                  lastError: rt.engineState == 'error' ? rt.engineError : null,
                  clearLastError: rt.engineState != 'error',
                  launcherMode: switch (rt.configuredExecutorMode) {
                    'tawcroot' => '高速模式',
                    'proot' || 'proot-legacy' => '兼容模式',
                    _ => h.launcherMode,
                  },
                )
              : h,
      ];
    }

    final nextRt = rt ?? state.nativeRuntimeStatus;
    final hostsChanged = !listEquals(nextHosts, state.hosts);
    final toolkitsChanged = nextToolkits.length != state.containerToolkits.length ||
        Iterable<int>.generate(nextToolkits.length).any(
          (i) => nextToolkits[i].installed != state.containerToolkits[i].installed,
        );
    final nativeChanged = !state.nativeStatusHydrated ||
        hostsChanged ||
        toolkitsChanged ||
        nextRt != state.nativeRuntimeStatus;

    if (nativeChanged) {
      state = state.copyWith(
        nativeStatusHydrated: true,
        hosts: hostsChanged ? nextHosts : state.hosts,
        containerToolkits: toolkitsChanged ? nextToolkits : state.containerToolkits,
        nativeRuntimeStatus: nextRt,
      );
    }

    if (!shouldAutoConnect) return;

    // Auto-start or bind the REAL on-device Android Ubuntu + Node 24 + DSH 0.2.2-rc.5 engine!
    if (state.activeHost.isLocal && !kIsWeb) {
      if (rt == null) {
        if (state.loadingSessions || state.hydratingDomains) {
          state = state.copyWith(
            loadingSessions: false,
            hydratingDomains: false,
            connectionPhase: _liveClient != null
                ? state.connectionPhase
                : ConnectionPhase.disconnected,
          );
        }
        return;
      }
      final gen = connectGen ?? _hostConnectGen;
      if (rt.engineRunning && _liveClient == null) {
        if (rt.bridgeToken.isEmpty) {
          state = state.copyWith(
            loadingSessions: false,
            hydratingDomains: false,
            connectionPhase: ConnectionPhase.error,
          );
        } else {
          state = state.copyWith(
            connectionPhase: ConnectionPhase.connecting,
            loadingSessions: true,
          );
          unawaited(
            _connectLocalAndroidEngine(
              rt.bridgeSocketPath,
              rt.bridgeHttpUrl,
              rt.bridgeToken,
              gen: gen,
            ),
          );
        }
      } else if (rt.engineRunning && _liveClient != null) {
        if (state.loadingSessions &&
            state.connectionPhase == ConnectionPhase.connected &&
            !state.hydratingDomains) {
          state = state.copyWith(loadingSessions: false);
        }
      } else if (rt.initialized && !rt.engineRunning && rt.engineState == 'stopped') {
        if (_liveClient != null) {
          _detachLiveClientsSync();
        }
        if (_autoStartRequestedGen != gen && !_userStoppedLocalEngine) {
          _autoStartRequestedGen = gen;
          state = state.copyWith(
            connectionPhase: ConnectionPhase.connecting,
            loadingSessions: true,
          );
          unawaited(() async {
            try {
              final res = await native.startLocalEngine();
              if (!mounted || gen != _hostConnectGen || !state.activeHost.isLocal) return;
              if (res['ok'] != true && _liveClient == null) {
                final errStr = res['error']?.toString().trim() ?? '';
                state = state.copyWith(
                  loadingSessions: false,
                  hydratingDomains: false,
                  connectionPhase: errStr.isNotEmpty
                      ? ConnectionPhase.error
                      : ConnectionPhase.disconnected,
                );
              }
            } catch (_) {
              if (!mounted || gen != _hostConnectGen || !state.activeHost.isLocal) return;
              if (_liveClient == null) {
                state = state.copyWith(
                  loadingSessions: false,
                  hydratingDomains: false,
                  connectionPhase: ConnectionPhase.error,
                );
              }
            }
          }());
        } else if (state.loadingSessions ||
            state.hydratingDomains ||
            state.connectionPhase != ConnectionPhase.disconnected) {
          state = state.copyWith(
            loadingSessions: false,
            hydratingDomains: false,
            connectionPhase: ConnectionPhase.disconnected,
          );
        }
      } else if (rt.engineState == 'starting') {
        state = state.copyWith(
          connectionPhase: ConnectionPhase.connecting,
          loadingSessions: true,
        );
      } else if (!rt.engineRunning) {
        if (_liveClient != null) {
          _detachLiveClientsSync();
        }
        state = state.copyWith(
          loadingSessions: false,
          hydratingDomains: false,
          connectionPhase: rt.engineState == 'error'
              ? ConnectionPhase.error
              : ConnectionPhase.disconnected,
        );
      }
    }
  }

  Future<void> _connectLocalAndroidEngine(
    String socketPath,
    String httpUrl,
    String token, {
    int? gen,
  }) async {
    final targetGen = gen ?? _hostConnectGen;
    // Deduplicate strictly by host generation so `engine_ready` and `refreshNativeStatus`
    // can never race each other even if one carries an empty socketPath!
    if (_connectingLocalAndroid && _connectingLocalGen == targetGen) return;
    if (_liveClient != null && state.activeHost.isLocal && state.connectionPhase == ConnectionPhase.connected) {
      return;
    }
    _connectingLocalAndroid = true;
    _connectingLocalGen = targetGen;

    Object? lastError;
    const retryDelaysMs = [0, 450, 1000];
    try {
      for (var attempt = 0; attempt < retryDelaysMs.length; attempt++) {
        if (retryDelaysMs[attempt] > 0) {
          await Future<void>.delayed(Duration(milliseconds: retryDelaysMs[attempt]));
        }
        if (!mounted || targetGen != _hostConnectGen || !state.activeHost.isLocal) return;

        // Prefer 0600 UDS across retries (giving Cordis reload brief grace) before TCP loopback fallback.
        if (socketPath.isNotEmpty) {
          final ok = await _connectUnixBridge(socketPath, token, gen: targetGen);
          if (ok || targetGen != _hostConnectGen) return;
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 280));
            if (!mounted || targetGen != _hostConnectGen || !state.activeHost.isLocal) return;
            final okRetry = await _connectUnixBridge(socketPath, token, gen: targetGen);
            if (okRetry || targetGen != _hostConnectGen) return;
          }
        }

        GbridgeClient? client;
        try {
          _detachLiveClientsSync(preserveLocalConnectLock: true);
          if (!mounted || targetGen != _hostConnectGen || !state.activeHost.isLocal) return;
          client = GbridgeClient(
            HostEndpoint.http(baseUri: Uri.parse(httpUrl), token: token),
            timeout: const Duration(seconds: 20),
          );
          final caps = await client.getCapabilities();
          if (!mounted || targetGen != _hostConnectGen || !state.activeHost.isLocal) {
            await client.dispose();
            return;
          }
          await _bindFullLiveClient(client, 'local', caps, gen: targetGen);
          return;
        } catch (e) {
          lastError = e;
          await client?.dispose();
        }
      }

      if (!mounted || targetGen != _hostConnectGen || !state.activeHost.isLocal) return;
      state = state.copyWith(
        loadingSessions: false,
        hydratingDomains: false,
        connectionPhase: ConnectionPhase.error,
        hosts: [
          for (final h in state.hosts)
            h.isLocal
                ? h.copyWith(online: false, bridged: false, lastError: formatReadableError(lastError))
                : h,
        ],
      );
    } finally {
      if (_connectingLocalGen == targetGen) {
        _connectingLocalAndroid = false;
        _connectingLocalGen = null;
      }
    }
  }

  Future<void> bootstrapLocalRuntime() async {
    final native = GrassBagNativeBridge.instance;
    if (!native.isAndroidNative) {
      showToast('本机内置 Linux 运行环境仅支持 Android 设备；桌面与 Web 请直接连接本机或远程 DSH', tone: ToastTone.info);
      return;
    }
    if (_bootstrappingLocal) {
      showToast('本机运行环境正在准备中，请稍候…', tone: ToastTone.info);
      return;
    }
    _bootstrappingLocal = true;
    _userStoppedLocalEngine = false;
    final isRemote = !state.nativeRuntimeStatus.hasBundledRuntimePayloads;
    try {
      state = state.copyWith(
        runtimeProgressPct: 2,
        runtimeProgressMsg: isRemote ? '准备下载并部署本机运行环境…' : '准备初始化本机运行环境…',
        runtimeProgressStage: 'layout',
        runtimeProgressCanCancel: isRemote,
      );
      final res = await native.bootstrapRuntime();
      if (!mounted) return;
      if (res['cancelled'] == true) {
        state = state.copyWith(
          runtimeProgressPct: 0,
          runtimeProgressMsg: '',
          runtimeProgressStage: '',
          runtimeProgressCanCancel: false,
        );
        await refreshNativeStatus(skipAutoConnect: true, forceFresh: true);
        if (!mounted) return;
        showToast('已暂停下载，下次点击可断点续传', tone: ToastTone.info);
        return;
      }
      await refreshNativeStatus(forceFresh: true);
      if (!mounted) return;
      if (res['ok'] == true) {
        state = state.copyWith(
          runtimeProgressStage: '',
          runtimeProgressCanCancel: false,
        );
        _syncAndroidKeepalive(force: true);
        showToast('本机 Linux 容器与零侵入桥已就绪');
      } else {
        state = state.copyWith(
          runtimeProgressPct: 0,
          runtimeProgressMsg: '',
          runtimeProgressStage: '',
          runtimeProgressCanCancel: false,
        );
        showError('初始化本机运行环境失败', error: res['error'] ?? '容器部署未完成，请检查网络或存储空间后重试');
      }
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          runtimeProgressPct: 0,
          runtimeProgressMsg: '',
          runtimeProgressStage: '',
          runtimeProgressCanCancel: false,
        );
        showError('初始化本机运行环境失败', error: e);
      }
    } finally {
      _bootstrappingLocal = false;
    }
  }

  Future<void> cancelLocalRuntimeBootstrap() async {
    final native = GrassBagNativeBridge.instance;
    if (!native.isAndroidNative) return;
    await native.cancelRuntimeBootstrap();
    if (!mounted) return;
    showToast('正在暂停下载，将保留断点进度…', tone: ToastTone.info);
  }

  Future<String?> setLocalRuntimeMirrorUrl(String url) async {
    final native = GrassBagNativeBridge.instance;
    if (!native.isAndroidNative) return '仅 Android 本机环境支持配置下载源';
    final res = await native.setRuntimeMirrorUrl(url);
    await refreshNativeStatus(skipAutoConnect: true, forceFresh: true);
    if (!mounted) return null;
    if (res['ok'] == true) {
      final cleaned = res['customRuntimeMirrorUrl']?.toString().trim() ?? '';
      showToast(cleaned.isEmpty ? '已恢复自动择优下载源' : '已保存自定义运行环境下载源');
      return null;
    }
    return res['error']?.toString() ?? '保存下载源失败，请检查地址格式';
  }

  Future<void> stopLocalEngine() async {
    final native = GrassBagNativeBridge.instance;
    if (!native.isAndroidNative) {
      showToast('仅 Android 本机内置引擎支持直接启停', tone: ToastTone.info);
      return;
    }
    _userStoppedLocalEngine = true;
    final isLocalActive = state.activeHost.isLocal;
    if (isLocalActive) {
      final gen = ++_hostConnectGen;
      _autoStartRequestedGen = gen;
      _detachLiveClientsSync();
      state = state.copyWith(
        connectionPhase: ConnectionPhase.disconnected,
        loadingSessions: false,
        hydratingDomains: false,
        isStreaming: false,
      );
    }
    await native.stopLocalEngine();
    await refreshNativeStatus(skipAutoConnect: true);
    if (!mounted) return;
    showToast('本机 DSH 引擎已停止', tone: ToastTone.info);
  }

  Future<Map<String, dynamic>> exportEncryptedBackup(String passphrase) async {
    final res = await GrassBagNativeBridge.instance.exportEncryptedBackup(passphrase);
    if (!mounted) return res;
    if (res['ok'] == true) {
      final included = (res['includedCount'] as num?)?.toInt() ?? 0;
      final skipped = (res['skippedCount'] as num?)?.toInt() ?? 0;
      final kb = (((res['bytes'] as num?)?.toInt() ?? 0) / 1024).toStringAsFixed(1);
      if (skipped > 0) {
        showToast(
          '已加密归档 $included 项（$kb KB），跳过 $skipped 项超限或特殊文件，请查看清单',
          tone: ToastTone.warn,
        );
      } else {
        showToast('已加密归档 $included 项（$kb KB），可点击分享另存至系统目录', tone: ToastTone.ok);
      }
    } else {
      showToast(res['error']?.toString() ?? '导出加密备份失败', tone: ToastTone.warn);
    }
    return res;
  }

  Future<Map<String, dynamic>> listEncryptedBackups() =>
      GrassBagNativeBridge.instance.listEncryptedBackups();

  Future<Map<String, dynamic>> previewEncryptedBackup(String path, String passphrase) =>
      GrassBagNativeBridge.instance.previewEncryptedBackup(path, passphrase);

  Future<Map<String, dynamic>> restoreEncryptedBackup(String path, String passphrase) async {
    final res = await GrassBagNativeBridge.instance.restoreEncryptedBackup(path, passphrase);
    if (!mounted) return res;
    if (res['ok'] == true) {
      final restoredCount = (res['restoredCount'] as num?)?.toInt() ?? 0;
      showToast('完整性校验通过，已恢复 $restoredCount 个文件', tone: ToastTone.ok);
      unawaited(refreshNativeStatus(skipAutoConnect: false));
    } else {
      showToast(res['error']?.toString() ?? '恢复加密备份失败', tone: ToastTone.warn);
    }
    return res;
  }

  /// Clears cached nearby LAN hosts (e.g. immediately after Wi-Fi / network switch).
  void clearDiscoveredLanHosts() {
    if (!mounted || state.discoveredLanHosts.isEmpty) return;
    state = state.copyWith(discoveredLanHosts: const []);
  }

  /// Queues an incoming `grassbag://pair?...` deep link so the UI opens the unified
  /// Connect Computer pairing sheet showing target computer details BEFORE connecting.
  void enqueuePairDeepLink(String rawUri) {
    final trimmed = rawUri.trim();
    if (!mounted || trimmed.isEmpty) return;
    state = state.copyWith(pendingPairDeepLinkUri: trimmed);
  }

  /// Consumes and clears any queued `grassbag://pair?...` deep link.
  String? consumePendingPairDeepLink() {
    final cur = state.pendingPairDeepLinkUri;
    if (cur == null || cur.isEmpty) return null;
    if (mounted) {
      state = state.copyWith(clearPendingPairDeepLinkUri: true);
    }
    return cur;
  }

  Future<void> scanLanForHosts({int port = 3080, bool silent = false}) async {
    if (state.scanningLan) return;
    if (kIsWeb) {
      if (!silent) {
        showToast('浏览器环境无法扫描局域网端口，请直接粘贴远程地址或启动链接', tone: ToastTone.info);
      }
      return;
    }
    state = state.copyWith(scanningLan: true);
    final ips = await _refreshDeviceLocalIps();
    final rawFound = await GrassBagNativeBridge.instance.scanLanHosts(port: port);
    if (!mounted) return;
    final isAndroid = GrassBagNativeBridge.instance.isAndroidNative;
    final localUri = Uri.tryParse(state.localHost.address);
    // Double-filter against self device IPs & loopback so the phone itself never shows up as remote.
    final found = rawFound.where((item) {
      final uri = Uri.tryParse(item.address);
      if (uri == null) return false;
      return !isSelfDeviceUri(
        uri,
        ips,
        isAndroidNative: isAndroid,
        localHostUri: localUri,
      );
    }).toList(growable: false);
    state = state.copyWith(scanningLan: false, discoveredLanHosts: found);
    final dshCount = found.where((h) => h.isDsh).length;
    if (!silent) {
      showToast(
        found.isEmpty
            ? '未发现局域网 DSH 服务（电脑端默认仅监听本机回环，可展开「如何获取电脑链接」开启共享）'
            : (dshCount > 0
                ? '发现 $dshCount 台局域网 DSH 服务（共 ${found.length} 台主机），免插件可直接连接'
                : '发现 ${found.length} 台局域网主机'),
        tone: found.isEmpty ? ToastTone.info : ToastTone.ok,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Toast, Error Reporting & Theme
  // ---------------------------------------------------------------------------
  int _errorSeq = 0;

  static String formatReadableError(Object? err) {
    if (err == null) return '未知错误';
    if (err is GbridgeException) {
      final buf = StringBuffer(err.message);
      final meta = <String>[
        if (err.code.isNotEmpty) err.code,
        if (err.status > 0) 'HTTP ${err.status}',
      ];
      if (meta.isNotEmpty) buf.write(' (${meta.join(', ')})');
      if (err.details != null) {
        buf.write('\n详情: ${err.details}');
      }
      return buf.toString();
    }
    final s = err.toString().trim();
    return s.startsWith('Exception: ') ? s.substring(11) : s;
  }

  /// Classifies raw DSH / LLM transport errors into friendly Chinese titles,
  /// clear recovery guidance, and an optional contextual action shortcut.
  static ({
    String title,
    String guidance,
    String? actionKind,
    String rawDetail,
  }) classifyReadableError(String rawDetail, {String? code}) {
    final trimmed = rawDetail.trim();
    final combined = '${code ?? ''} $trimmed'.toLowerCase();
    if (combined.contains('account_signed_out') ||
        combined.contains('signed-out') ||
        combined.contains('登录过期') ||
        combined.contains('重新登录')) {
      return (
        title: 'DeepSeek 账号会话已失效',
        guidance: '账号登录状态已过期或已登出，重新登录 DeepSeek 账号后即可继续使用。',
        actionKind: 'signin',
        rawDetail: trimmed,
      );
    }
    if (combined.contains('尚未连接') ||
        combined.contains('未连接') ||
        combined.contains('offline') ||
        combined.contains('host_offline') ||
        combined.contains('transport') ||
        combined.contains('fetch failed') ||
        combined.contains('econnrefused') ||
        combined.contains('econnreset') ||
        combined.contains('etimedout') ||
        combined.contains('timed out') ||
        combined.contains('socket') ||
        combined.contains('network') ||
        combined.contains('dns') ||
        combined.contains('enotfound')) {
      return (
        title: '连接中断或主机不可达',
        guidance: '当前无法连接到 DSH 主机或模型接口，请检查主机状态、网络或代理后重试。',
        actionKind: 'host',
        rawDetail: trimmed,
      );
    }
    if (RegExp(r'(?:http\s*|status[:=\s]*)?\b(?:401|403)\b').hasMatch(combined) ||
        combined.contains('unauthorized') ||
        combined.contains('invalid_api_key') ||
        combined.contains('invalid api key') ||
        combined.contains('authentication') ||
        combined.contains('密钥无效') ||
        combined.contains('鉴权失败')) {
      return (
        title: '身份验证失效',
        guidance: 'API Key 无效、权限不足或账号会话已失效，请检查渠道密钥或切换可用模型。',
        actionKind: 'model',
        rawDetail: trimmed,
      );
    }
    if (RegExp(r'(?:http\s*|status[:=\s]*)?\b402\b').hasMatch(combined) ||
        combined.contains('insufficient') ||
        combined.contains('balance') ||
        combined.contains('quota') ||
        combined.contains('余额不足') ||
        combined.contains('欠费')) {
      return (
        title: '账户余额或额度不足',
        guidance: '当前模型渠道余额或配额已耗尽，请充值或切换其他可用模型渠道。',
        actionKind: 'model',
        rawDetail: trimmed,
      );
    }
    if (RegExp(r'(?:http\s*|status[:=\s]*)?\b429\b').hasMatch(combined) ||
        combined.contains('rate limit') ||
        combined.contains('too many requests') ||
        combined.contains('频率超限') ||
        combined.contains('请求过于频繁') ||
        combined.contains('限流')) {
      return (
        title: '请求过于频繁（限流）',
        guidance: '上游接口触发速率限制，稍候几秒重新发送，或临时切换其他渠道。',
        actionKind: 'retry',
        rawDetail: trimmed,
      );
    }
    if (combined.contains('context_length') ||
        combined.contains('context window') ||
        combined.contains('maximum context') ||
        combined.contains('maximum token') ||
        combined.contains('prompt is too long') ||
        combined.contains('input is too long') ||
        combined.contains('too many tokens') ||
        combined.contains('token limit') ||
        combined.contains('上下文超长') ||
        combined.contains('上下文长度')) {
      return (
        title: '上下文长度已达上限',
        guidance: '当前对话历史较长，建议一键精简上下文或开启新对话后再继续。',
        actionKind: 'compact',
        rawDetail: trimmed,
      );
    }
    if (combined.contains('model_not_found') ||
        combined.contains('model not found') ||
        combined.contains('no routable') ||
        combined.contains('does not exist') ||
        combined.contains('模型不可用')) {
      return (
        title: '所选模型不可用',
        guidance: '当前模型未就绪或渠道不支持该模型 ID，请切换其他可用模型后重试。',
        actionKind: 'model',
        rawDetail: trimmed,
      );
    }
    if (RegExp(r'(?:http\s*|status[:=\s]*|error\s*)?\b(?:500|502|503|504)\b(?!\s*ms)').hasMatch(combined) ||
        combined.contains('overloaded') ||
        combined.contains('bad gateway') ||
        combined.contains('service unavailable')) {
      return (
        title: '模型服务暂时繁忙',
        guidance: '上游模型接口负载较高或暂时不可用，稍候几秒后重新发送即可。',
        actionKind: 'retry',
        rawDetail: trimmed,
      );
    }
    if (combined.contains('attachmentid') ||
        combined.contains('未入库的图像块') ||
        combined.contains('异常内容块') ||
        combined.contains('inline_provider_image_block')) {
      return (
        title: '工具返回了不兼容的图片块',
        guidance: '会话历史或工具结果包含未按 DSH 规范入库的图片块（缺少 attachmentId）。重启本地引擎后会自动修复旧会话，或开启新对话继续。',
        actionKind: 'retry',
        rawDetail: trimmed,
      );
    }
    if (combined.contains('interrupted')) {
      return (
        title: '引擎意外中断',
        guidance: 'DSH 引擎在本轮完成前意外退出，请稍等自动恢复后重新发送。',
        actionKind: 'retry',
        rawDetail: trimmed,
      );
    }
    return (
      title: '本次执行未能完成',
      guidance: '请展开技术详情查看具体原因，或稍后重新发送。',
      actionKind: null,
      rawDetail: trimmed,
    );
  }

  void showToast(String text, {ToastTone tone = ToastTone.ok, String? detail}) {
    if (!mounted) return;
    final isUrgentCurrent =
        state.toast?.tone == ToastTone.error || state.toast?.tone == ToastTone.warn;
    final isUrgentIncoming = tone == ToastTone.error || tone == ToastTone.warn;
    // Never let a lower-priority informational or background success toast wipe a fresh error/warning toast!
    if (!isUrgentIncoming &&
        isUrgentCurrent &&
        _lastWarnToastAt != null &&
        DateTime.now().difference(_lastWarnToastAt!) < const Duration(milliseconds: 2200)) {
      return;
    }
    if (isUrgentIncoming) {
      _lastWarnToastAt = DateTime.now();
    } else if (!isUrgentCurrent) {
      _lastWarnToastAt = null;
    }
    _toastTimer?.cancel();
    final id = ++_toastSeq;
    state = state.copyWith(
      toast: GrassBagToastMessage(id: id, text: text, tone: tone, detail: detail),
    );
    final duration = (isUrgentIncoming || (detail != null && detail.isNotEmpty))
        ? const Duration(milliseconds: 4600)
        : const Duration(milliseconds: 2400);
    _toastTimer = Timer(duration, () {
      if (mounted && state.toast?.id == id) {
        state = state.copyWith(clearToast: true);
      }
    });
  }

  void dismissToast() {
    if (!mounted) return;
    _toastTimer?.cancel();
    if (state.toast == null) return;
    state = state.copyWith(clearToast: true);
  }

  void showError(String summary, {Object? error}) {
    if (!mounted) return;
    final detail = error != null ? formatReadableError(error) : summary;
    final rec = AppErrorRecord(
      id: ++_errorSeq,
      summary: summary,
      detail: detail,
      timestamp: DateTime.now(),
    );
    final nextErrors = [rec, ...state.recentErrors];
    state = state.copyWith(
      recentErrors: nextErrors.length > 30 ? nextErrors.sublist(0, 30) : nextErrors,
    );
    final shortToast = error != null ? '$summary：${detail.split('\n').first}' : summary;
    showToast(shortToast, tone: ToastTone.error, detail: detail);
  }

  void clearRecentErrors() {
    if (state.recentErrors.isEmpty) return;
    state = state.copyWith(recentErrors: const []);
  }

  void setSessionGroupMode(SessionGroupMode mode) {
    if (state.sessionGroupMode == mode) return;
    state = state.copyWith(sessionGroupMode: mode);
    _persistPrefs();
  }

  void _syncNativeThemePalette({bool? isDark, GrassBagAccent? accent}) {
    final dark = isDark ?? state.isDark;
    final acc = accent ?? state.accent;
    final tokens = GrassBagTokens.resolve(acc, dark ? Brightness.dark : Brightness.light);
    unawaited(
      GrassBagNativeBridge.instance.syncThemeMode(
        dark,
        accentPrimary: tokens.primary.toARGB32(),
        accentHi: tokens.primaryHi.toARGB32(),
        bgSolid: tokens.bgSolid.toARGB32(),
      ),
    );
  }

  void setDark(bool dark) {
    if (state.isDark == dark) return;
    state = state.copyWith(isDark: dark);
    _persistPrefs();
    _syncNativeThemePalette(isDark: dark);
  }

  void setAccent(GrassBagAccent accent) {
    if (state.accent == accent) return;
    state = state.copyWith(accent: accent);
    _persistPrefs();
    _syncNativeThemePalette(accent: accent);
  }

  bool _userEditedGlassOpticalStrength = false;

  void setGlassTier(GrassBagGlassTier tier) {
    if (state.glassTier == tier) return;
    state = state.copyWith(glassTier: tier);
    _persistPrefs();
  }

  void setGlassOpticalStrength(double strength, {bool persistImmediately = false}) {
    final normalized = (strength.clamp(0.0, 1.0) * 100.0).round() / 100.0;
    _userEditedGlassOpticalStrength = true;
    final changed = (state.glassOpticalStrength - normalized).abs() >= 0.0005;
    if (changed) {
      state = state.copyWith(glassOpticalStrength: normalized);
    }
    if (changed || persistImmediately) {
      _persistPrefs(immediate: persistImmediately);
    }
  }

  void setTabletSidebarOpen(bool open) {
    if (state.tabletSidebarOpen == open) return;
    state = state.copyWith(tabletSidebarOpen: open);
  }

  void setTabletWorkbenchOpen(bool open) {
    if (state.tabletWorkbenchOpen == open) return;
    state = state.copyWith(tabletWorkbenchOpen: open);
  }

  void setFilter(SessionFilter filter) {
    if (state.filter == filter) return;
    state = state.copyWith(filter: filter);
    if (filter == SessionFilter.archived && _liveClient != null) {
      unawaited(refreshSessionsList(silent: true));
    }
  }

  void setSearchQuery(String query) {
    final trimmed = query.trim();
    final hasCjk = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]').hasMatch(trimmed);
    final willSearchBackend =
        trimmed.isNotEmpty && (hasCjk || trimmed.length >= 2) && _liveClient != null;
    state = state.copyWith(
      searchQuery: query,
      // Always clear stale snippets on query change so previous matches never flash during 280ms debounce.
      searchSnippets: const {},
      searchingSessions: willSearchBackend,
    );
    _drawerSearchTimer?.cancel();
    if (!willSearchBackend) return;
    _drawerSearchTimer = Timer(const Duration(milliseconds: 280), () {
      if (!mounted || _liveClient == null || state.searchQuery.trim() != trimmed) return;
      unawaited(_runBackendSessionSearch(trimmed));
    });
  }

  Future<void> _runBackendSessionSearch(String query) async {
    final client = _liveClient;
    if (client == null) {
      if (mounted && state.searchingSessions) {
        state = state.copyWith(searchingSessions: false);
      }
      return;
    }
    try {
      final results = await client.searchSessions(query, limit: 30);
      if (!mounted || !identical(_liveClient, client) || state.searchQuery.trim() != query) return;
      final snippets = <String, String>{};
      for (final item in results) {
        final sid = (item['sessionId'] ?? item['id'])?.toString() ?? '';
        if (sid.isEmpty) continue;
        snippets[sid] = (item['snippet'] ?? item['title'] ?? '').toString();
      }
      state = state.copyWith(searchSnippets: snippets, searchingSessions: false);
    } catch (_) {
      if (mounted && state.searchQuery.trim() == query && state.searchingSessions) {
        state = state.copyWith(searchingSessions: false);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Sessions, Turns, Feedback, Fork, Export & Lazy Tool Output
  // ---------------------------------------------------------------------------
  void setSidebarWorkspaceFilter(String? workspace) {
    final clean = workspace?.trim() ?? '';
    if (clean.isEmpty) {
      state = state.copyWith(clearSidebarWorkspaceFilter: true);
    } else {
      state = state.copyWith(sidebarWorkspaceFilter: clean);
    }
    _saveCurrentHostContext();
  }

  String _attachmentsScopeKey(String hostId, String? sessionId, {String? originOverride}) {
    final origin = (originOverride ?? _hostOriginKey(hostId)).trim().toLowerCase();
    final scope = (sessionId == null || sessionId.isEmpty) ? '__new__' : sessionId;
    return '$hostId::$origin::$scope';
  }

  void _purgeHostAttachmentCaches(String hostId, {String? onlyOrigin}) {
    final prefix = (onlyOrigin != null && onlyOrigin.isNotEmpty)
        ? '$hostId::${onlyOrigin.trim().toLowerCase()}::'
        : '$hostId::';
    _sessionAttachmentsMemory.removeWhere((k, _) => k.startsWith(prefix));
    _sessionQueuedMemory.removeWhere((k, _) => k.startsWith(prefix));
  }

  static const int _maxPendingAttachmentsCount = 10;
  static const int _maxSingleAttachmentBytes = 8 * 1024 * 1024;
  static const int _maxPendingAttachmentsTotalBytes = 16 * 1024 * 1024;
  static const int _maxAttachmentMemoryCacheBytes = 24 * 1024 * 1024;

  static int _attachmentListBytes(Iterable<ComposerAttachment> items) {
    var total = 0;
    for (final a in items) {
      total += a.bytes?.length ?? a.sizeBytes;
    }
    return total;
  }

  void _enforceAttachmentMemoryBudget() {
    var total = 0;
    for (final list in _sessionAttachmentsMemory.values) {
      total += _attachmentListBytes(list);
    }
    while ((_sessionAttachmentsMemory.length > 16 || total > _maxAttachmentMemoryCacheBytes) &&
        _sessionAttachmentsMemory.isNotEmpty) {
      final firstKey = _sessionAttachmentsMemory.keys.first;
      final removed = _sessionAttachmentsMemory.remove(firstKey);
      if (removed != null) {
        total -= _attachmentListBytes(removed);
      }
    }
  }

  void _stashPendingAttachmentsForScope(String hostId, String? sessionId) {
    final key = _attachmentsScopeKey(hostId, sessionId);
    if (state.pendingAttachments.isEmpty) {
      _sessionAttachmentsMemory.remove(key);
      return;
    }
    _sessionAttachmentsMemory.remove(key);
    _sessionAttachmentsMemory[key] = List<ComposerAttachment>.unmodifiable(state.pendingAttachments);
    _enforceAttachmentMemoryBudget();
  }

  List<ComposerAttachment> _restorePendingAttachmentsForScope(String hostId, String? sessionId) {
    final key = _attachmentsScopeKey(hostId, sessionId);
    final saved = _sessionAttachmentsMemory[key];
    return saved == null ? const [] : List<ComposerAttachment>.of(saved);
  }

  void startNewChat({String? workspace}) {
    final wasAlreadyEmpty =
        state.activeSessionId == null && state.turns.isEmpty && !state.isStreaming;
    _clearPendingStreamCoalesce();
    _disarmStreamWatchdog();
    _locallyCancelledTurnIds.clear();
    _cancelSuppressUntilMs = 0;
    _streamRunId++;
    final prevSid = state.activeSessionId;
    if (prevSid != null) {
      _stashPendingAttachmentsForScope(state.activeHostId, prevSid);
      final livePrevTurns = _turnReducer.turns.isNotEmpty ? _turnReducer.turns : state.turns;
      if (livePrevTurns.isNotEmpty) {
        _cacheSessionTurns(prevSid, livePrevTurns);
      }
      _liveClient?.stream.unsubscribe('session:$prevSid');
    } else if (state.pendingAttachments.isNotEmpty) {
      _stashPendingAttachmentsForScope(state.activeHostId, null);
    }
    _turnReducer.replaceAll(const []);
    final explicitWs = workspace?.trim() ?? '';
    var resolvedWorkspace = explicitWs.isNotEmpty ? explicitWs : state.activeWorkspace;
    if (explicitWs.isNotEmpty) {
      final matched = state.workspaces
          .where((w) => w.id == explicitWs || w.path == explicitWs || w.name == explicitWs)
          .firstOrNull;
      if (matched != null) {
        resolvedWorkspace = matched.id.isNotEmpty ? matched.id : matched.name;
      }
    }
    if (explicitWs.isEmpty &&
        state.workspaces.isNotEmpty &&
        !state.workspaces.any(
          (w) =>
              w.name == resolvedWorkspace ||
              w.path == resolvedWorkspace ||
              w.id == resolvedWorkspace,
        )) {
      final firstWs = state.workspaces.first;
      resolvedWorkspace = firstWs.id.isNotEmpty ? firstWs.id : firstWs.name;
    }
    if (wasAlreadyEmpty && workspace == null) {
      // Already on a fresh New Chat stage: mark explicit navigation and clear any stale
      // lastSessionId so async domain hydration NEVER yanks the user into an old session!
      _userNavigatedSinceHostBind = true;
      _saveCurrentHostContext(immediate: true, allowClearSession: true);
      state = state.copyWith(
        activeWorkspace: resolvedWorkspace,
        focusComposerSignal: state.focusComposerSignal + 1,
      );
      return;
    }
    _stashPendingAttachmentsForScope(state.activeHostId, state.activeSessionId);
    _stashQueuedMessagesForScope(state.activeHostId, state.activeSessionId);
    _userNavigatedSinceHostBind = true;
    state = state.copyWith(
      clearActiveSession: true,
      clearParentSession: true,
      planMode: false,
      activeWorkspace: resolvedWorkspace,
      turns: const [],
      turnFeedback: const {},
      toolOutputCache: const {},
      stepTranslations: const {},
      translatedStepIds: const {},
      translatingStepIds: const {},
      expandedTurnProcessIds: const {},
      collapsedTurnProcessIds: const {},
      expandedStepIds: const {},
      hasMoreTurns: false,
      clearTurnsNextCursor: true,
      loadingOlderTurns: false,
      clearSessionLoadError: true,
      loadingSession: false,
      isStreaming: false,
      sendStage: SendStage.idle,
      uploadDoneCount: 0,
      uploadTotalCount: 0,
      isStopping: false,
      isCompactingContext: false,
      streamStalled: false,
      clearPendingApproval: true,
      clearActiveQuestion: true,
      clearActiveCordisRequest: true,
      clearOfflineUnsentNotice: true,
      pendingAttachments: _restorePendingAttachmentsForScope(state.activeHostId, null),
      queuedMessages: const [],
      workspaceFiles: const [],
      workspaceCurrentPath: '',
      workspaceDiffs: const [],
      todos: const [],
      goals: const [],
      subagents: const [],
      contextPct: 0,
      contextUsedK: 0,
      contextBreakdown: const {},
      sessionTelemetry: const SessionTelemetry(),
      sessionRenderGen: state.sessionRenderGen + 1,
      newChatSignal: state.newChatSignal + 1,
    );
    _recomputeVisibleInteractions();
    _saveCurrentHostContext(immediate: true, allowClearSession: true);
  }

  String _resolveCanonicalWorkspace(ChatSessionItem? target, String fallback) {
    if (target == null) return fallback;
    WorkspaceItem? matchedWs;
    if (target.workspaceId != null && target.workspaceId!.isNotEmpty) {
      matchedWs = state.workspaces.where((w) => w.id == target.workspaceId).firstOrNull;
    }
    if (matchedWs == null && target.cwd != null && target.cwd!.isNotEmpty) {
      final normCwd = target.cwd!.trim().replaceFirst(RegExp(r'/+$'), '');
      matchedWs = state.workspaces
          .where((w) => w.path.trim().replaceFirst(RegExp(r'/+$'), '') == normCwd)
          .firstOrNull;
    }
    if (matchedWs != null) return matchedWs.id;
    if (target.cwd != null && target.cwd!.isNotEmpty) return _basenamePath(target.cwd!);
    return fallback;
  }

  static String _sessionDateGroup(int? updatedAtMs) {
    if (updatedAtMs == null || updatedAtMs <= 0) return '更早';
    final now = DateTime.now();
    final dt = DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
    final todayStart = DateTime(now.year, now.month, now.day);
    final diffDays = todayStart.difference(DateTime(dt.year, dt.month, dt.day)).inDays;
    if (diffDays <= 0) return '今天';
    if (diffDays == 1) return '昨天';
    if (diffDays <= 7) return '本周';
    return '更早';
  }

  void selectSession(
    String sessionId, {
    bool preserveParentStack = false,
    String? nextParentId,
    String? nextParentTitle,
    String? nextChildTitle,
    String? nextChildWorktree,
  }) {
    _userNavigatedSinceHostBind = true;
    _unreadSessionIdsByHost[state.activeHostId]?.remove(sessionId);
    final prevSid = state.activeSessionId;
    // Re-tapping the already-active session must NEVER wipe live turns, queued messages,
    // pending attachments, or workspace state!
    if (prevSid == sessionId && state.sessionLoadError == null) {
      final needsUnreadClear = state.sessions.any((s) => s.id == sessionId && s.unread);
      if (needsUnreadClear) {
        state = state.copyWith(
          sessions: [
            for (final s in state.sessions)
              s.id == sessionId ? s.copyWith(unread: false) : s,
          ],
        );
      }
      if (_liveClient != null && state.turns.isEmpty && !state.loadingSession) {
        _liveClient!.stream.subscribe('session:$sessionId');
        unawaited(_syncLiveSessionBundle(sessionId, jumpToBottomOnLoad: true));
      }
      return;
    }
    // Snapshot reducer's latest buffered streaming turns BEFORE clearing coalesce timer!
    final livePrevTurns = _turnReducer.turns.isNotEmpty ? _turnReducer.turns : state.turns;
    _clearPendingStreamCoalesce();
    _disarmStreamWatchdog();
    _locallyCancelledTurnIds.clear();
    _cancelSuppressUntilMs = 0;
    _streamRunId++;
    if (prevSid != sessionId) {
      _stashPendingAttachmentsForScope(state.activeHostId, prevSid);
      _stashQueuedMessagesForScope(state.activeHostId, prevSid);
    }
    if (prevSid != null && prevSid != sessionId) {
      if (livePrevTurns.isNotEmpty) {
        _cacheSessionTurns(prevSid, livePrevTurns);
      }
      _liveClient?.stream.unsubscribe('session:$prevSid');
    }
    ChatSessionItem? target;
    bool needsUnreadClear = false;
    for (final s in state.sessions) {
      if (s.id == sessionId) {
        target = s;
        needsUnreadClear = s.unread;
        break;
      }
    }
    final updatedSessions = needsUnreadClear
        ? [
            for (final s in state.sessions)
              s.id == sessionId ? s.copyWith(unread: false) : s,
          ]
        : state.sessions;
    if (needsUnreadClear && target != null) {
      target = target.copyWith(unread: false);
    }
    final rawCachedTurns = _sessionTurnsMemory[sessionId] ?? const <NormalizedTurn>[];
    // If a cached session finished in the background (`target?.running == false`), don't render
    // a stale live streaming cursor while the fresh authoritative bundle loads!
    final cachedTurns = (target?.running == false &&
            rawCachedTurns.isNotEmpty &&
            rawCachedTurns.last.isStreaming)
        ? [
            ...rawCachedTurns.sublist(0, rawCachedTurns.length - 1),
            rawCachedTurns.last.copyWith(status: 'completed'),
          ]
        : rawCachedTurns;
    final cachedPage = cachedTurns.isNotEmpty ? _sessionPaginationMemory[sessionId] : null;
    _turnReducer.replaceAll(cachedTurns);
    final isChangingSession = prevSid != sessionId;
    final nextWs = _resolveCanonicalWorkspace(target, state.activeWorkspace);
    state = state.copyWith(
      sessions: updatedSessions,
      activeSessionId: sessionId,
      clearParentSession: !preserveParentStack,
      parentSessionId: preserveParentStack ? nextParentId : null,
      parentSessionTitle: preserveParentStack ? nextParentTitle : null,
      activeChildTitle: preserveParentStack ? nextChildTitle : null,
      activeChildWorktree: preserveParentStack ? nextChildWorktree : null,
      planMode: isChangingSession ? false : state.planMode,
      activeWorkspace: nextWs,
      turns: cachedTurns,
      turnFeedback: isChangingSession ? const {} : state.turnFeedback,
      toolOutputCache: isChangingSession ? const {} : state.toolOutputCache,
      stepTranslations: isChangingSession ? const {} : state.stepTranslations,
      translatedStepIds: isChangingSession ? const {} : state.translatedStepIds,
      translatingStepIds: isChangingSession ? const {} : state.translatingStepIds,
      expandedTurnProcessIds: isChangingSession ? const {} : state.expandedTurnProcessIds,
      collapsedTurnProcessIds: isChangingSession ? const {} : state.collapsedTurnProcessIds,
      expandedStepIds: isChangingSession ? const {} : state.expandedStepIds,
      hasMoreTurns: cachedPage?.hasMore ?? false,
      turnsNextCursor: cachedPage?.nextCursor,
      clearTurnsNextCursor: cachedPage?.nextCursor == null,
      loadingOlderTurns: false,
      clearSessionLoadError: true,
      loadingSession: _liveClient != null && cachedTurns.isEmpty && !sessionId.startsWith('pending-session-'),
      clearPendingApproval: true,
      clearActiveQuestion: true,
      clearActiveCordisRequest: true,
      clearOfflineUnsentNotice: true,
      pendingAttachments: isChangingSession
          ? _restorePendingAttachmentsForScope(state.activeHostId, sessionId)
          : state.pendingAttachments,
      queuedMessages: isChangingSession
          ? _restoreQueuedMessagesForScope(state.activeHostId, sessionId)
          : state.queuedMessages,
      workspaceFiles: const [],
      workspaceCurrentPath: '',
      workspaceDiffs: const [],
      todos: const [],
      goals: const [],
      subagents: const [],
      contextPct: 0,
      contextUsedK: 0,
      contextBreakdown: const {},
      sessionTelemetry: const SessionTelemetry(),
      isStreaming: target?.running == true,
      sendStage: SendStage.idle,
      uploadDoneCount: 0,
      uploadTotalCount: 0,
      isStopping: false,
      isCompactingContext: false,
      streamStalled: false,
      sessionRenderGen: isChangingSession ? state.sessionRenderGen + 1 : state.sessionRenderGen,
      sessionJumpSignal: cachedTurns.isNotEmpty ? state.sessionJumpSignal + 1 : state.sessionJumpSignal,
    );
    if (target?.running == true) {
      _armStreamWatchdog();
    } else {
      _disarmStreamWatchdog();
    }
    _recomputeVisibleInteractions();
    _saveCurrentHostContext(immediate: true);

    if (_liveClient != null) {
      _liveClient!.stream.subscribe('session:$sessionId', force: true);
      unawaited(_syncLiveSessionBundle(sessionId, jumpToBottomOnLoad: cachedTurns.isEmpty));
    }
  }

  Future<void> retryLoadActiveSession() async {
    final sid = state.activeSessionId;
    if (sid == null || _liveClient == null) return;
    state = state.copyWith(loadingSession: true, clearSessionLoadError: true);
    await _syncLiveSessionBundle(sid, jumpToBottomOnLoad: true);
  }

  Future<void> loadOlderTurns() async {
    final client = _liveClient;
    final sid = state.activeSessionId;
    final cursor = state.turnsNextCursor;
    if (client == null || sid == null || cursor == null || cursor.isEmpty) return;
    if (state.loadingOlderTurns || !state.hasMoreTurns) return;
    state = state.copyWith(loadingOlderTurns: true);
    try {
      final page = await client.getSessionTurns(
        sid,
        limit: 80,
        before: cursor,
        withProjections: false,
      );
      if (!_isStillLive(client) || state.activeSessionId != sid) return;
      final currentTurns = _turnReducer.turns.isNotEmpty ? _turnReducer.turns : state.turns;
      final existingIds = currentTurns.map((t) => t.turnId).toSet();
      final older = page.turns.where((t) => !existingIds.contains(t.turnId)).toList(growable: false);
      final merged = [...older, ...currentTurns];
      final nextHasMore = page.hasMore && older.isNotEmpty;
      final nextCursor = nextHasMore ? page.nextCursor : null;
      _cacheSessionTurns(sid, merged);
      _sessionPaginationMemory[sid] = (hasMore: nextHasMore, nextCursor: nextCursor);
      _turnReducer.replaceAll(merged);
      state = state.copyWith(
        turns: merged,
        hasMoreTurns: nextHasMore,
        turnsNextCursor: nextCursor,
        clearTurnsNextCursor: nextCursor == null,
        loadingOlderTurns: false,
      );
    } catch (e) {
      if (!_isStillLive(client) || state.activeSessionId != sid) return;
      state = state.copyWith(loadingOlderTurns: false);
      showError('加载更早对话记录失败', error: e);
    }
  }

  static bool _workspaceFilesEqual(List<WorkspaceFileNode> a, List<WorkspaceFileNode> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].path != b[i].path ||
          a[i].name != b[i].name ||
          a[i].isDir != b[i].isDir ||
          a[i].subtitle != b[i].subtitle) {
        return false;
      }
    }
    return true;
  }

  static bool _slashCommandsEqual(List<SlashCommandItem> a, List<SlashCommandItem> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].command != b[i].command ||
          a[i].title != b[i].title ||
          a[i].desc != b[i].desc ||
          a[i].category != b[i].category) {
        return false;
      }
    }
    return true;
  }

  Future<void> _syncLiveSessionBundle(
    String sessionId, {
    bool jumpToBottomOnLoad = false,
    bool includeWorkbench = true,
    bool authoritativeSync = false,
  }) async {
    final client = _liveClient;
    if (client == null || sessionId.startsWith('pending-session-')) return;
    final existing = _inFlightBundleSyncs[sessionId];
    if (existing != null) {
      final prevFlags = _pendingResyncFlags[sessionId];
      _pendingResyncFlags[sessionId] = (
        jumpToBottom: (prevFlags?.jumpToBottom ?? false) || jumpToBottomOnLoad,
        authoritative: (prevFlags?.authoritative ?? false) || authoritativeSync,
        includeWorkbench: (prevFlags?.includeWorkbench ?? false) || includeWorkbench,
      );
      await existing;
      return;
    }
    if (!_syncingSessionBundleIds.add(sessionId)) {
      final prevFlags = _pendingResyncFlags[sessionId];
      _pendingResyncFlags[sessionId] = (
        jumpToBottom: (prevFlags?.jumpToBottom ?? false) || jumpToBottomOnLoad,
        authoritative: (prevFlags?.authoritative ?? false) || authoritativeSync,
        includeWorkbench: (prevFlags?.includeWorkbench ?? false) || includeWorkbench,
      );
      return;
    }
    final completer = Completer<void>();
    _inFlightBundleSyncs[sessionId] = completer.future;
    final startStreamSeq = _sessionStreamSeq[sessionId] ?? 0;
    final targetSession = state.sessions.where((s) => s.id == sessionId).firstOrNull;
    final fileScopeId = sessionId;
    final currentRelPath = state.workspaceCurrentPath;
    final currentDiffScope = state.activeDiffScope;
    try {
      final results = includeWorkbench
          ? await Future.wait([
              client.getSessionTurns(sessionId, limit: 40),
              client
                  .getWorkspaceFileTree(
                    fileScopeId,
                    path: currentRelPath.isEmpty ? '.' : currentRelPath,
                  )
                  .catchError((_) => const <String, dynamic>{}),
              client
                  .getWorkspaceFileChanges(
                    fileScopeId,
                    sessionId: sessionId,
                    scope: currentDiffScope,
                  )
                  .catchError((_) => const <String, dynamic>{}),
              client
                  .getSessionGoals(sessionId)
                  .catchError((_) => const <String, dynamic>{}),
              client
                  .listCommands(sessionId: sessionId)
                  .catchError((_) => const <String, dynamic>{}),
              client
                  .listJobs(sessionId: sessionId)
                  .catchError((_) => const <String, dynamic>{}),
            ])
          : <dynamic>[
              await client.getSessionTurns(sessionId, limit: 40),
              const <String, dynamic>{},
              const <String, dynamic>{},
              const <String, dynamic>{},
              const <String, dynamic>{},
              const <String, dynamic>{},
            ];
      if (!mounted || !identical(_liveClient, client) || state.activeSessionId != sessionId) {
        return;
      }

      final page = results[0] as TurnsPage;
      final treeResp = results[1] as Map<String, dynamic>;
      final diffResp = results[2] as Map<String, dynamic>;
      final goalResp = results[3] as Map<String, dynamic>;
      final cmdResp = results[4] as Map<String, dynamic>;
      final jobsResp = results[5] as Map<String, dynamic>;

      // Preserve `stableKey` (and unchanged historical turn object identity!) from `_turnReducer.turns`
      // so optimistic -> server turn reconciliation & post-turn bundle sync NEVER unmount/remount
      // `TurnView` / `_AssistantBody`, wipe user text selection, or replay the typewriter!
      final prevTurns = _turnReducer.turns;
      final prevByTurnId = <String, NormalizedTurn>{
        for (final pt in prevTurns) pt.turnId: pt,
      };
      final effectiveTurns = <NormalizedTurn>[];
      for (final fresh in page.turns) {
        final prev = prevByTurnId[fresh.turnId];
        if (prev != null) {
          if (prev.isStreaming) {
            // Never let a stale HTTP turn snapshot roll back live WebSocket
            // streaming progress (which could wipe tokens/steps mid-turn).
            final freshIsStrictlyAhead = fresh.seqEnd > prev.seqEnd ||
                fresh.steps.length > prev.steps.length ||
                fresh.assistantText.length > prev.assistantText.length;
            if (fresh.isStreaming) {
              effectiveTurns.add(
                freshIsStrictlyAhead ? fresh.copyWith(stableKey: prev.stableKey) : prev,
              );
            } else {
              // Stock DSH `session/page` defaults a persisted `user/message` (whose `assistant/message`
              // & `turn/end` haven't been persisted yet) to `status: 'completed'`. Never let an empty
              // or regressive HTTP snapshot wipe live WebSocket streaming progress!
              final sessionStillRunning = targetSession?.running == true ||
                  state.sessions.any((s) => s.id == sessionId && s.running);
              final freshSubstantive = fresh.assistantText.length >= prev.assistantText.length &&
                  fresh.steps.length >= prev.steps.length &&
                  (fresh.assistantText.isNotEmpty ||
                      fresh.steps.isNotEmpty ||
                      prev.assistantText.isEmpty && prev.steps.isEmpty);
              final freshHasSubstantiveCompletion = fresh.status == 'completed' &&
                  (fresh.usage != null ||
                      fresh.deliverables.isNotEmpty ||
                      (!sessionStillRunning && freshSubstantive) ||
                      (authoritativeSync &&
                          freshSubstantive &&
                          !fresh.steps.any((s) => s is ToolStep && s.status == 'running')));
              final freshTerminalAuthoritative = fresh.status == 'error' ||
                  fresh.status == 'cancelled' ||
                  fresh.status == 'interrupted' ||
                  freshHasSubstantiveCompletion;
              effectiveTurns.add(
                freshTerminalAuthoritative ? fresh.copyWith(stableKey: prev.stableKey) : prev,
              );
            }
          } else {
            final unchangedCompleted = !fresh.isStreaming &&
                prev.status == fresh.status &&
                prev.assistantText == fresh.assistantText &&
                prev.steps.length == fresh.steps.length &&
                prev.errorMessage == fresh.errorMessage &&
                prev.usage?.outputTokens == fresh.usage?.outputTokens &&
                prev.usage?.inputTokens == fresh.usage?.inputTokens &&
                prev.deliverables.length == fresh.deliverables.length;
            effectiveTurns.add(
              unchangedCompleted ? prev : fresh.copyWith(stableKey: prev.stableKey),
            );
          }
        } else {
          effectiveTurns.add(fresh);
        }
      }
      // Also match a trailing optimistic `client-turn-*` turn whose server ID wasn't yet in `prevByTurnId`
      var reconciledNewServerTurn = false;
      if (prevTurns.isNotEmpty &&
          effectiveTurns.isNotEmpty &&
          prevTurns.last.stableKey.startsWith('client-turn-') &&
          effectiveTurns.last.stableKey == effectiveTurns.last.turnId &&
          !prevByTurnId.containsKey(effectiveTurns.last.turnId)) {
        final optPrev = prevTurns.last;
        final optUser = optPrev.userMessage?.text.trim() ?? '';
        final freshUser = effectiveTurns.last.userMessage?.text.trim() ?? '';
        if (optPrev.turnId == effectiveTurns.last.turnId ||
            (optUser.isNotEmpty && _userTextsMatch(optUser, freshUser)) ||
            (optUser.isEmpty &&
                (optPrev.userMessage?.attachments.isNotEmpty ?? false) &&
                (effectiveTurns.last.userMessage?.attachments.isNotEmpty ?? false))) {
          effectiveTurns[effectiveTurns.length - 1] =
              effectiveTurns.last.copyWith(stableKey: optPrev.stableKey);
          reconciledNewServerTurn = true;
        }
      }

      // Preserve older paginated turns prepended by `loadOlderTurns()` ahead of the newest page
      // so background bundle sync never silently truncates history the user scrolled up to load!
      var preservedOlderPrefix = false;
      if (prevTurns.length > effectiveTurns.length && effectiveTurns.isNotEmpty) {
        final anchorIdx = prevTurns.indexWhere((pt) => pt.turnId == effectiveTurns.first.turnId);
        if (anchorIdx > 0) {
          effectiveTurns.insertAll(0, prevTurns.sublist(0, anchorIdx));
          preservedOlderPrefix = true;
        }
      }

      // If live stream frames arrived while `getSessionTurns` was in flight, never let a stale HTTP
      // snapshot erase newer trailing turns that haven't appeared in `page.turns` yet.
      if ((_sessionStreamSeq[sessionId] ?? 0) != startStreamSeq && prevTurns.isNotEmpty) {
        final effectiveTurnIds = effectiveTurns.map((t) => t.turnId).toSet();
        final effectiveStableKeys = effectiveTurns.map((t) => t.stableKey).toSet();
        var lastMatchedIdx = -1;
        for (var i = prevTurns.length - 1; i >= 0; i--) {
          if (effectiveTurnIds.contains(prevTurns[i].turnId) ||
              effectiveStableKeys.contains(prevTurns[i].stableKey)) {
            lastMatchedIdx = i;
            break;
          }
        }
        final tailStart = lastMatchedIdx + 1;
        if (tailStart < prevTurns.length) {
          for (var i = tailStart; i < prevTurns.length; i++) {
            final pt = prevTurns[i];
            if (!effectiveTurnIds.contains(pt.turnId) &&
                !effectiveStableKeys.contains(pt.stableKey) &&
                !(reconciledNewServerTurn && i == prevTurns.length - 1)) {
              effectiveTurns.add(pt);
              effectiveTurnIds.add(pt.turnId);
              effectiveStableKeys.add(pt.stableKey);
            }
          }
        }
      }

      final liveTail = prevTurns.isNotEmpty && prevTurns.last.isStreaming
          ? prevTurns.last
          : null;
      if (liveTail != null && !reconciledNewServerTurn) {
        final isOptimisticUnmatched = liveTail.turnId.startsWith('client-turn-');
        final matchedByIdOrKey = effectiveTurns.any(
          (t) => t.turnId == liveTail.turnId || t.stableKey == liveTail.stableKey,
        );
        final tailUser = liveTail.userMessage?.text.trim() ?? '';
        final lastIsExistingCompleted = effectiveTurns.isNotEmpty &&
            prevByTurnId.containsKey(effectiveTurns.last.turnId) &&
            effectiveTurns.last.status != 'streaming';
        final alreadyInPage = matchedByIdOrKey ||
            (isOptimisticUnmatched &&
                effectiveTurns.isNotEmpty &&
                !lastIsExistingCompleted &&
                tailUser.isNotEmpty &&
                _userTextsMatch(tailUser, effectiveTurns.last.userMessage?.text.trim() ?? ''));
        if (!alreadyInPage) {
          final targetSess = state.sessions.where((s) => s.id == sessionId).firstOrNull;
          final serverRunning = targetSess?.running == true;
          final liveCreatedMs = liveTail.userMessage?.createdAt ??
              int.tryParse(liveTail.turnId.replaceFirst('client-turn-', ''));
          final liveAgeMs = liveCreatedMs != null
              ? (DateTime.now().millisecondsSinceEpoch - liveCreatedMs)
              : 0;
          final isActivelyPreparing = state.sendStage == SendStage.uploadingAttachments ||
              state.sendStage == SendStage.creatingSession;
          if (!serverRunning && !isActivelyPreparing && isOptimisticUnmatched && liveAgeMs > 12000) {
            effectiveTurns.add(
              liveTail.copyWith(
                status: 'error',
                errorMessage: '连接中断，未能收到模型响应，请重新发送。',
              ),
            );
          } else {
            effectiveTurns.add(liveTail);
          }
        } else if (isOptimisticUnmatched &&
            effectiveTurns.isNotEmpty &&
            effectiveTurns.last.stableKey != liveTail.stableKey) {
          effectiveTurns[effectiveTurns.length - 1] =
              effectiveTurns.last.copyWith(stableKey: liveTail.stableKey);
        }
      } else if (prevTurns.isNotEmpty &&
          !reconciledNewServerTurn &&
          prevTurns.last.turnId.startsWith('client-turn-') &&
          (prevTurns.last.status == 'error' || prevTurns.last.status == 'cancelled')) {
        // Preserve local unsent failed/cancelled `client-turn-*` cards across background bundle syncs
        // so the user can always see the error and tap "重新发送" or "编辑修改".
        final localTail = prevTurns.last;
        final exists = effectiveTurns.any(
          (t) => t.turnId == localTail.turnId || t.stableKey == localTail.stableKey,
        );
        if (!exists) {
          effectiveTurns.add(localTail);
        }
      }
      final effectiveIsStreaming = effectiveTurns.isNotEmpty && effectiveTurns.last.isStreaming;
      if (!effectiveIsStreaming) {
        _disarmStreamWatchdog();
      }

      _cacheSessionTurns(sessionId, effectiveTurns);
      _reconcileOutboxForSession(state.activeHostId, sessionId, effectiveTurns);
      _clearPendingStreamCoalesce();
      _turnReducer.replaceAll(effectiveTurns);

      var ctxUsedK = 0.0;
      final modelCtxWin = state.effectiveActiveModelEntry?.contextWindow;
      var ctxMaxK = (modelCtxWin != null && modelCtxWin >= 4096)
          ? (modelCtxWin / 1000).round()
          : 128;
      var ctxPct = 0;
      final ctxBreakdown = <String, int>{};
      bool? syncedPlanMode;
      final liveTodos = <SessionTodoRecord>[];
      final liveSubagents = <SubagentItem>[];
      String? syncedTitle;
      String? syncedPreset;
      String? syncedPerm;

      final rawProj = page.projections;
      final projValues = rawProj?['values'] is Map<String, dynamic>
          ? rawProj!['values'] as Map<String, dynamic>
          : rawProj;
      if (projValues is Map<String, dynamic>) {
        final pt = projValues['title'];
        if (pt is String && pt.trim().isNotEmpty && !pt.startsWith('[object Object]')) {
          syncedTitle = pt.trim();
        }
        final pp = projValues['agentPreset'];
        if (pp is String && pp.trim().isNotEmpty) syncedPreset = pp.trim();
        final permObj = projValues['permissions'];
        if (permObj is Map && permObj['currentValue'] is String) {
          syncedPerm = permObj['currentValue'].toString();
        }
        final planObj = projValues['plan'];
        if (planObj is Map && planObj['active'] is bool) {
          syncedPlanMode = planObj['active'] as bool;
        }
        // 1) Authoritative DSH 0.2.x `contextPressure` projection (exact pressureTokens & contextWindow!)
        final cp = projValues['contextPressure'];
        if (cp is Map) {
          if (cp['contextWindow'] is num && (cp['contextWindow'] as num) > 0) {
            ctxMaxK = ((cp['contextWindow'] as num).toInt() ~/ 1000).clamp(32, 4000);
          }
          final pressTok = (cp['pressureTokens'] as num?)?.toInt() ??
              (cp['projectedTokens'] as num?)?.toInt();
          if (pressTok != null && pressTok > 0) {
            ctxUsedK = double.parse((pressTok / 1000.0).toStringAsFixed(1));
          }
        }
        // 2) Authoritative DSH `contextBreakdown` projection (`systemTokens` / `toolsTokens` / `messageTokens`)
        final cb = projValues['contextBreakdown'];
        if (cb is Map) {
          final sysTok = (cb['systemTokens'] as num?)?.toInt() ?? 0;
          final toolTok = (cb['toolsTokens'] as num?)?.toInt() ?? 0;
          final msgTok = (cb['messageTokens'] as num?)?.toInt() ?? 0;
          if (sysTok + toolTok + msgTok > 0) {
            ctxBreakdown['system'] = sysTok;
            ctxBreakdown['tools'] = toolTok;
            ctxBreakdown['messages'] = msgTok;
            if (ctxUsedK <= 0) {
              ctxUsedK = double.parse(((sysTok + toolTok + msgTok) / 1000.0).toStringAsFixed(1));
            }
          }
        }
        // 3) Fallback to `tokenUsage` explicit context window / current context tokens
        final tok = projValues['tokenUsage'];
        if (tok is Map) {
          if (ctxMaxK == 128 && tok['contextWindow'] is num && (tok['contextWindow'] as num) > 0) {
            ctxMaxK = ((tok['contextWindow'] as num).toInt() ~/ 1000).clamp(32, 4000);
          }
          if (ctxUsedK <= 0) {
            final curCtx = (tok['currentContextTokens'] as num?)?.toInt() ??
                (tok['lastContextTokens'] as num?)?.toInt() ??
                (tok['lastInputTokens'] as num?)?.toInt();
            if (curCtx != null && curCtx > 0) {
              ctxUsedK = double.parse((curCtx / 1000.0).toStringAsFixed(1));
            }
          }
        }
      }
      // Fallback: estimate conservatively from visible turn text when DSH omits contextPressure
      if (ctxUsedK <= 0 && page.turns.isNotEmpty) {
        final estChars = page.turns.fold<int>(
          0,
          (acc, t) =>
              acc +
              (t.userMessage?.text.length ?? 0) +
              t.assistantText.length +
              t.steps.fold<int>(0, (sAcc, s) => sAcc + (s is ReasoningStep ? s.text.length : 120)),
        );
        if (estChars > 0) {
          ctxUsedK = double.parse(((estChars / 3.2) / 1000.0).toStringAsFixed(1));
        }
      }
      if (ctxMaxK == 128 && ctxUsedK > 128) {
        ctxMaxK = ctxUsedK > 200 ? 1000 : 200;
      }
      ctxPct = ctxMaxK > 0 ? ((ctxUsedK / ctxMaxK) * 100).round().clamp(0, 100) : 0;

      if (projValues is Map<String, dynamic>) {
        final rawTodos = projValues['todos'] ?? projValues['todoList'];
        if (rawTodos is List) {
          for (var i = 0; i < rawTodos.length; i++) {
            final item = rawTodos[i];
            if (item is! Map) continue;
            final st = item['status']?.toString() ?? '';
            liveTodos.add(
              SessionTodoRecord(
                id: item['id']?.toString() ?? 'td-$i',
                title: item['title']?.toString() ?? item['content']?.toString() ?? item['text']?.toString() ?? '',
                done: item['done'] == true || st == 'completed' || st == 'done',
                active: st == 'in_progress' || st == 'active',
              ),
            );
          }
        }
        final rawSubs = projValues['subagents'] ?? projValues['subagentCatalog'] ?? projValues['children'];
        if (rawSubs is List) {
          for (var i = 0; i < rawSubs.length; i++) {
            final item = rawSubs[i];
            if (item is! Map) continue;
            liveSubagents.add(
              SubagentItem(
                id: item['sessionId']?.toString() ?? item['id']?.toString() ?? 'sub-$i',
                name: item['name']?.toString() ?? item['title']?.toString() ?? '子代理 ${i + 1}',
                role: item['role']?.toString() ?? item['mode']?.toString() ?? item['agentPreset']?.toString() ?? 'subagent',
                status: item['status']?.toString() ?? (item['running'] == true ? 'running' : 'completed'),
                taskSummary: item['label']?.toString() ?? item['task']?.toString() ?? item['summary']?.toString() ?? '',
                model: item['model']?.toString() ?? state.modelName,
                durationLabel: item['durationLabel']?.toString() ??
                    (item['durationMs'] is num
                        ? '${((item['durationMs'] as num) / 1000).toStringAsFixed(1)}s'
                        : ''),
                outputPreview: item['outputPreview']?.toString() ?? '',
                worktreeBranch: item['worktreeBranch']?.toString() ?? item['branch']?.toString(),
              ),
            );
          }
        }
      }

      // Full real-time DSH telemetry (tokens, cache hit rate, TTFT, decode tok/s, model groups)
      final parsedTelemetry = rawProj != null
          ? SessionTelemetry.fromProjections(
              rawProj,
              fallbackTurns: page.turns,
            )
          : SessionTelemetry.fromProjections(
              const <String, dynamic>{},
              fallbackTurns: page.turns,
            );

      // Parse real workspace files (preserve user's current directory inside Workbench!)
      final parsedFiles = includeWorkbench
          ? _parseFileTreeResponse(treeResp, basePath: currentRelPath)
          : state.workspaceFiles;
      // Parse real diffs
      final parsedDiffs = includeWorkbench
          ? _parseDiffsResponse(diffResp)
          : state.workspaceDiffs;
      // Parse real goals (prefer goals/get, fall back to durable `projections.values.goal` on cold sessions!)
      final parsedGoalsFromApi = includeWorkbench ? _parseGoalsResponse(goalResp) : const <SessionGoalRecord>[];
      final parsedGoals = parsedGoalsFromApi.isNotEmpty
          ? parsedGoalsFromApi
          : (projValues is Map<String, dynamic> && projValues.containsKey('goal')
              ? _parseGoalProjection(projValues['goal'])
              : (includeWorkbench ? const <SessionGoalRecord>[] : state.goals));
      // Sync authoritative DSH server inbox queue IDs when present in `projections.values.inbox`
      final parsedInbox = projValues is Map<String, dynamic>
          ? _parseInboxProjection(projValues['inbox'])
          : null;
      // Parse real slash commands if returned
      final parsedCommands = includeWorkbench
          ? _parseSlashCommandsResponse(cmdResp)
          : const <SlashCommandItem>[];
      // Parse real session background jobs
      final parsedJobs = includeWorkbench
          ? _parseJobsResponse(jobsResp, fallbackSessionId: sessionId)
          : const <BackgroundJobRecord>[];

      var sessionEntryChanged = false;
      for (final s in state.sessions) {
        if (s.id == sessionId) {
          if ((syncedTitle != null && s.title != syncedTitle) ||
              s.running != effectiveIsStreaming) {
            sessionEntryChanged = true;
          }
          break;
        }
      }
      final syncedSessions = sessionEntryChanged
          ? [
              for (final s in state.sessions)
                s.id == sessionId
                    ? s.copyWith(
                        title: syncedTitle ?? s.title,
                        running: effectiveIsStreaming,
                      )
                    : s,
            ]
          : state.sessions;

      final nextHasMore = preservedOlderPrefix ? state.hasMoreTurns : page.hasMore;
      final nextCursor = preservedOlderPrefix ? state.turnsNextCursor : page.nextCursor;
      _sessionPaginationMemory[sessionId] = (hasMore: nextHasMore, nextCursor: nextCursor);
      final nextWorkspaceFiles = _workspaceFilesEqual(parsedFiles, state.workspaceFiles)
          ? state.workspaceFiles
          : parsedFiles;
      final mergedCommands = parsedCommands.isEmpty
          ? state.slashCommands
          : [
              ...parsedCommands,
              for (final existing in state.slashCommands)
                if (existing.command.startsWith('/skill:') &&
                    !parsedCommands.any((c) => c.command == existing.command))
                  existing,
            ];
      final nextSlashCommands = parsedCommands.isNotEmpty &&
              !_slashCommandsEqual(mergedCommands, state.slashCommands)
          ? mergedCommands
          : state.slashCommands;
      final nextCtxBreakdown =
          mapEquals(ctxBreakdown, state.contextBreakdown) ? state.contextBreakdown : ctxBreakdown;
      final nextDiffs =
          listEquals(parsedDiffs, state.workspaceDiffs) ? state.workspaceDiffs : parsedDiffs;
      final nextTodos = listEquals(liveTodos, state.todos) ? state.todos : liveTodos;
      final nextSubs = listEquals(liveSubagents, state.subagents) ? state.subagents : liveSubagents;
      final nextGoals = listEquals(parsedGoals, state.goals) ? state.goals : parsedGoals;
      final nextJobs = (parsedJobs.isNotEmpty || jobsResp.containsKey('jobs'))
          ? (listEquals(parsedJobs, state.jobs) ? state.jobs : parsedJobs)
          : state.jobs;

      final turnsGrewOnSync = prevTurns.isNotEmpty &&
          effectiveTurns.isNotEmpty &&
          (effectiveTurns.length > prevTurns.length ||
              (effectiveTurns.last.turnId == prevTurns.last.turnId &&
                  (effectiveTurns.last.assistantText.length > prevTurns.last.assistantText.length ||
                      effectiveTurns.last.steps.length > prevTurns.last.steps.length)));

      state = state.copyWith(
        sessions: syncedSessions,
        turns: effectiveTurns,
        hasMoreTurns: nextHasMore,
        turnsNextCursor: nextCursor,
        clearTurnsNextCursor: nextCursor == null,
        clearSessionLoadError: true,
        loadingSession: false,
        isStreaming: effectiveIsStreaming,
        isStopping: effectiveIsStreaming ? state.isStopping : false,
        streamStalled: effectiveIsStreaming ? state.streamStalled : false,
        sendStage: effectiveIsStreaming ? state.sendStage : SendStage.idle,
        contextUsedK: ctxUsedK,
        contextMaxK: ctxMaxK,
        contextPct: ctxPct,
        contextBreakdown: nextCtxBreakdown,
        sessionTelemetry: parsedTelemetry.copyWith(
          liveTps: effectiveIsStreaming ? state.sessionTelemetry.liveTps : null,
          livePhase: effectiveIsStreaming ? state.sessionTelemetry.livePhase : null,
          liveElapsedMs: effectiveIsStreaming ? state.sessionTelemetry.liveElapsedMs : null,
          clearLive: !effectiveIsStreaming,
        ),
        planMode: syncedPlanMode ?? state.planMode,
        workspaceFiles: nextWorkspaceFiles,
        workspaceCurrentPath: currentRelPath,
        workspaceDiffs: nextDiffs,
        todos: nextTodos,
        subagents: nextSubs,
        goals: nextGoals,
        queuedMessages: parsedInbox ?? state.queuedMessages,
        jobs: nextJobs,
        slashCommands: nextSlashCommands,
        activePresetId: syncedPreset ?? state.activePresetId,
        activePermissionId: syncedPerm ?? state.activePermissionId,
        activeWorkspace: _resolveCanonicalWorkspace(targetSession, state.activeWorkspace),
        streamTick: turnsGrewOnSync ? state.streamTick + 1 : state.streamTick,
        sessionJumpSignal: jumpToBottomOnLoad ? state.sessionJumpSignal + 1 : state.sessionJumpSignal,
      );
      if (syncedPerm != null && syncedPerm.isNotEmpty) {
        _syncNativeChatPermissionPreset(syncedPerm);
      }
      unawaited(_syncSessionSkillsAndFeedback(client, sessionId));
    } catch (e) {
      if (_isStillLive(client) && state.activeSessionId == sessionId) {
        state = state.copyWith(
          loadingSession: false,
          sessionLoadError: state.turns.isEmpty ? formatReadableError(e) : null,
        );
      }
    } finally {
      final isOwner = identical(_inFlightBundleSyncs[sessionId], completer.future);
      if (isOwner) {
        _syncingSessionBundleIds.remove(sessionId);
        _inFlightBundleSyncs.remove(sessionId);
      }
      if (!completer.isCompleted) completer.complete();
      final pendingFlags = isOwner ? _pendingResyncFlags.remove(sessionId) : null;
      if (pendingFlags != null &&
          mounted &&
          _liveClient != null &&
          state.activeSessionId == sessionId) {
        unawaited(_syncLiveSessionBundle(
          sessionId,
          jumpToBottomOnLoad: pendingFlags.jumpToBottom,
          authoritativeSync: pendingFlags.authoritative,
          includeWorkbench: pendingFlags.includeWorkbench,
        ));
      }
    }
  }

  Future<void> _syncSessionSkillsAndFeedback(GbridgeClient client, String sessionId) async {
    try {
      final results = await Future.wait([
        client.listSkills(sessionId: sessionId).catchError((_) => const <String, dynamic>{}),
        client.listMessageFeedback(sessionId).catchError((_) => const <String, dynamic>{}),
      ]);
      if (!mounted || !identical(_liveClient, client) || state.activeSessionId != sessionId) return;
      final skillsResp = results[0];
      final fbResp = results[1];
      // Merge live skills into slashCommands
      final rawSkillsWrap = skillsResp['skills'];
      final rawSkills = rawSkillsWrap is List
          ? rawSkillsWrap
          : (rawSkillsWrap is Map && rawSkillsWrap['skills'] is List
              ? rawSkillsWrap['skills'] as List<dynamic>
              : const <dynamic>[]);
      var nextCommands = state.slashCommands;
      if (rawSkills.isNotEmpty) {
        final byCmd = <String, SlashCommandItem>{
          for (final c in state.slashCommands) c.command.toLowerCase(): c,
        };
        for (final s in rawSkills) {
          if (s is! Map) continue;
          final name = s['name']?.toString().trim() ?? '';
          if (name.isEmpty) continue;
          final cmd = '/skill:$name';
          byCmd[cmd.toLowerCase()] = SlashCommandItem(
            command: cmd,
            title: name,
            desc: s['description']?.toString() ?? 'DSH Skill',
            category: '技能',
          );
        }
        nextCommands = byCmd.values.toList(growable: false);
      }
      // Hydrate persisted feedback keyed by "$sessionId:$messageId"
      final rawFb = fbResp['items'];
      final nextFb = Map<String, String>.of(state.turnFeedback);
      if (rawFb is List) {
        for (final f in rawFb) {
          if (f is! Map) continue;
          final mid = f['messageId']?.toString() ?? '';
          final r = f['rating']?.toString().toLowerCase() ?? '';
          if (mid.isEmpty || r.isEmpty) continue;
          nextFb['$sessionId:$mid'] = (r == 'positive' || r == 'up') ? 'up' : 'down';
        }
      }
      final commandsChanged = !identical(nextCommands, state.slashCommands) &&
          (nextCommands.length != state.slashCommands.length ||
              Iterable<int>.generate(nextCommands.length).any(
                (i) =>
                    nextCommands[i].command != state.slashCommands[i].command ||
                    nextCommands[i].desc != state.slashCommands[i].desc,
              ));
      final fbChanged = !mapEquals(nextFb, state.turnFeedback);
      if (commandsChanged || fbChanged) {
        state = state.copyWith(
          slashCommands: commandsChanged ? nextCommands : state.slashCommands,
          turnFeedback: fbChanged ? nextFb : state.turnFeedback,
        );
      }
    } catch (_) {}
  }

  ({String scopeId, String? sessionId}) _resolveWorkspaceFileScope() {
    final activeWs = state.activeWorkspaceItem;
    final activeSid = state.activeSessionId;
    bool sessionMatchesWorkspace = false;
    if (activeSid != null && !activeSid.startsWith('pending-session-')) {
      if (activeWs == null) {
        sessionMatchesWorkspace = true;
      } else {
        final sess = state.sessions.where((s) => s.id == activeSid).firstOrNull;
        if (sess == null) {
          // Child subagent session not listed in top-level sessions still owns its own scope/worktree!
          sessionMatchesWorkspace =
              state.parentSessionId != null ||
              (state.activeChildWorktree != null && state.activeChildWorktree!.isNotEmpty) ||
              state.subagents.any((sub) => sub.id == activeSid);
        } else if (sess.workspaceId != null && sess.workspaceId!.isNotEmpty) {
          sessionMatchesWorkspace = sess.workspaceId == activeWs.id;
        } else if (sess.cwd != null && sess.cwd!.isNotEmpty && activeWs.path.isNotEmpty) {
          final normSess = sess.cwd!.trim().replaceFirst(RegExp(r'/+$'), '');
          final normWs = activeWs.path.trim().replaceFirst(RegExp(r'/+$'), '');
          sessionMatchesWorkspace = normSess == normWs;
        }
      }
    }
    if (sessionMatchesWorkspace && activeSid != null) {
      return (scopeId: activeSid, sessionId: activeSid);
    }
    final wsScope = (activeWs != null && activeWs.path.isNotEmpty)
        ? activeWs.path
        : (activeWs?.id ?? activeSid ?? '');
    return (scopeId: wsScope, sessionId: null);
  }

  Future<Map<String, dynamic>> readWorkspaceFilePage(
    String filePath, {
    int offset = 1,
    int limit = 400,
  }) async {
    final client = _liveClient;
    if (client == null) {
      return {'text': '未连接 DSH 主机', 'eof': true, 'lines': 0, 'error': true};
    }
    final scope = _resolveWorkspaceFileScope();
    if (scope.scopeId.isEmpty) {
      return {'text': '未选择工作区', 'eof': true, 'lines': 0, 'error': true};
    }
    try {
      final resp = await client.readWorkspaceFile(
        scope.scopeId,
        filePath,
        offset: offset,
        limit: limit,
        sessionId: scope.sessionId,
      );
      final fileObj = resp['file'];
      if (fileObj is Map) {
        final txt = (fileObj['text'] ?? fileObj['content'] ?? '').toString();
        final eof = fileObj['eof'] != false;
        final lines = (fileObj['lines'] as num?)?.toInt() ??
            (txt.isEmpty ? 0 : txt.split('\n').length);
        final totalLines = (fileObj['totalLines'] as num?)?.toInt();
        final binary = fileObj['binary'] == true;
        return {
          'text': txt,
          'eof': eof,
          'lines': lines,
          if (totalLines != null) 'totalLines': totalLines,
          'binary': binary,
          'offset': offset,
        };
      }
      return {'text': const JsonEncoder.withIndent('  ').convert(resp), 'eof': true, 'lines': 0};
    } catch (e) {
      return {'text': '读取文件失败：${formatReadableError(e)}', 'eof': true, 'lines': 0, 'error': true};
    }
  }

  Future<Uint8List?> readWorkspaceFileBytes(String filePath) async {
    final client = _liveClient;
    if (client == null) return null;
    final scope = _resolveWorkspaceFileScope();
    if (scope.scopeId.isEmpty) return null;
    try {
      return await client.readWorkspaceFileBytes(
        scope.scopeId,
        filePath,
        sessionId: scope.sessionId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, String>>> fetchSessionReferences(String query) async {
    final client = _liveClient;
    final sid = state.activeSessionId;
    if (client != null && sid != null && !sid.startsWith('pending-session-')) {
      try {
        final resp = await client.getSessionReferences(sid, query: query);
        final out = <Map<String, String>>[];
        final files = resp['files'];
        if (files is List) {
          for (final f in files) {
            if (f is! Map) continue;
            final p = (f['path'] ?? f['name'])?.toString() ?? '';
            if (p.isEmpty) continue;
            out.add({'path': p, 'kind': (f['kind'] ?? 'file').toString()});
          }
        }
        final sess = resp['sessions'];
        var hasSessions = false;
        if (sess is List) {
          for (final s in sess) {
            if (s is! Map) continue;
            final id = (s['sessionId'] ?? s['id'])?.toString() ?? '';
            final title = (s['title'] ?? id).toString();
            if (id.isEmpty) continue;
            out.add({'path': 'session:$id', 'label': title, 'kind': 'session'});
            hasSessions = true;
          }
        }
        // In Direct Mode (stock DSH), `sessions` is empty; merge matching local non-archived
        // sessions so `@` session references work seamlessly in every connection mode.
        if (!hasSessions && state.sessions.isNotEmpty) {
          final qLow = query.trim().toLowerCase();
          var added = 0;
          for (final s in state.sessions) {
            if (s.archived) continue;
            if (qLow.isEmpty ||
                s.title.toLowerCase().contains(qLow) ||
                s.id.toLowerCase().contains(qLow)) {
              out.add({'path': 'session:${s.id}', 'label': s.title, 'kind': 'session'});
              added++;
              if (added >= 8) break;
            }
          }
        }
        if (out.isNotEmpty) return out;
      } catch (_) {}
    }

    // Fallback for New Chat (no active session yet) or offline workspace file lookup:
    // fetch top-level workspace tree + match known non-archived sessions so `@` works everywhere!
    final out = <Map<String, String>>[];
    final q = query.trim().toLowerCase();
    if (client != null) {
      try {
        String? wsId;
        final activeWs = state.activeWorkspace.trim();
        for (final w in state.workspaces) {
          if (w.id == activeWs || w.name == activeWs || w.path == activeWs) {
            wsId = w.id.isNotEmpty ? w.id : w.path;
            break;
          }
        }
        wsId ??= state.workspaces.isNotEmpty
            ? (state.workspaces.first.id.isNotEmpty
                ? state.workspaces.first.id
                : state.workspaces.first.path)
            : (activeWs.startsWith('/') ? activeWs : null);
        if (wsId != null && wsId.isNotEmpty) {
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          List<String>? cachedPaths;
          final cache = _refWorkspaceFilesCache;
          if (cache != null && cache.wsId == wsId && (nowMs - cache.fetchedAtMs) < 30000) {
            cachedPaths = cache.files;
          } else {
            final tree = await client.getWorkspaceFileTree(wsId);
            final allFiles = <String>[];
            void collectAll(dynamic node) {
              if (allFiles.length >= 200) return;
              if (node is List) {
                for (final item in node) {
                  collectAll(item);
                }
              } else if (node is Map) {
                final kind = (node['kind'] ?? node['type'] ?? '').toString();
                final p = (node['path'] ?? node['relativePath'] ?? node['name'])?.toString() ?? '';
                final isDir = kind == 'directory' || kind == 'dir' || node['isDir'] == true;
                if (!isDir && p.isNotEmpty) {
                  allFiles.add(p);
                }
                if (node['children'] is List) collectAll(node['children']);
                if (node['entries'] is List) collectAll(node['entries']);
                if (node['files'] is List) collectAll(node['files']);
              }
            }
            collectAll(tree['entries'] ?? tree['children'] ?? tree['files'] ?? tree['tree']);
            _refWorkspaceFilesCache = (wsId: wsId, fetchedAtMs: nowMs, files: allFiles);
            cachedPaths = allFiles;
          }
          for (final p in cachedPaths) {
            if (q.isEmpty || p.toLowerCase().contains(q)) {
              out.add({'path': p, 'kind': 'file'});
              if (out.length >= 20) break;
            }
          }
        }
      } catch (_) {}
    }
    for (final s in state.sessions) {
      if (s.archived) continue;
      if (q.isEmpty ||
          s.title.toLowerCase().contains(q) ||
          s.id.toLowerCase().contains(q)) {
        out.add({'path': 'session:${s.id}', 'label': s.title, 'kind': 'session'});
        if (out.length >= 24) break;
      }
    }
    return out;
  }

  Future<void> translateReasoningStep(String stepId, String text) async {
    if (state.translatingStepIds.contains(stepId)) return;
    if (state.translatedStepIds.contains(stepId)) {
      final nextSet = Set<String>.of(state.translatedStepIds)..remove(stepId);
      state = state.copyWith(translatedStepIds: nextSet);
      return;
    }
    if (state.stepTranslations.containsKey(stepId)) {
      final nextSet = Set<String>.of(state.translatedStepIds)..add(stepId);
      state = state.copyWith(translatedStepIds: nextSet);
      return;
    }
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    state = state.copyWith(translatingStepIds: {...state.translatingStepIds, stepId});
    try {
      final resp = await client.translateCot(text);
      if (!_isStillLive(client)) return;
      final res = resp['result'];
      final translated = res is Map
          ? (res['text'] ?? res['translatedText'] ?? res['translation'] ?? '').toString()
          : (res?.toString() ?? '');
      final nextInFlight = Set<String>.of(state.translatingStepIds)..remove(stepId);
      if (translated.trim().isEmpty) {
        state = state.copyWith(translatingStepIds: nextInFlight);
        showToast('当前主机暂未启用思考翻译服务', tone: ToastTone.info);
        return;
      }
      state = state.copyWith(
        translatingStepIds: nextInFlight,
        stepTranslations: {...state.stepTranslations, stepId: translated.trim()},
        translatedStepIds: {...state.translatedStepIds, stepId},
      );
    } catch (e) {
      if (!_isStillLive(client)) return;
      final nextInFlight = Set<String>.of(state.translatingStepIds)..remove(stepId);
      state = state.copyWith(translatingStepIds: nextInFlight);
      showToast('翻译不可用：${formatReadableError(e)}', tone: ToastTone.warn);
    }
  }

  static String _normalizeRelWorkspacePath(String raw) {
    var s = raw.trim().replaceAll('\\', '/');
    while (s.startsWith('./')) {
      s = s.substring(2);
    }
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s == '.' ? '' : s;
  }

  Future<bool> loadWorkspaceDirectory({String path = '.', bool silent = false}) async {
    final client = _liveClient;
    if (client == null) return false;
    final scope = _resolveWorkspaceFileScope();
    if (scope.scopeId.isEmpty) return false;
    final cleanRel = _normalizeRelWorkspacePath(path);
    final seq = ++_wsDirSeq;
    try {
      final resp = await client.getWorkspaceFileTree(
        scope.scopeId,
        path: cleanRel.isEmpty ? '.' : cleanRel,
        sessionId: scope.sessionId,
      );
      if (!mounted || !identical(_liveClient, client) || seq != _wsDirSeq) return false;
      final parsed = _parseFileTreeResponse(resp, basePath: cleanRel);
      state = state.copyWith(
        workspaceFiles: parsed,
        workspaceCurrentPath: cleanRel,
      );
      return true;
    } catch (e) {
      if (!mounted || !identical(_liveClient, client) || seq != _wsDirSeq) return false;
      if (!silent) {
        showToast('读取目录失败：${formatReadableError(e)}', tone: ToastTone.warn);
      }
      return false;
    }
  }

  Future<String> readWorkspaceFileContent(String filePath) async {
    final client = _liveClient;
    if (client == null) return '未连接 DSH 主机';
    final scope = _resolveWorkspaceFileScope();
    if (scope.scopeId.isEmpty) return '未选择工作区';
    try {
      final resp = await client.readWorkspaceFile(
        scope.scopeId,
        filePath,
        sessionId: scope.sessionId,
      );
      final fileObj = resp['file'];
      if (fileObj is Map) {
        final txt = fileObj['text'] ?? fileObj['content'];
        if (txt != null) return txt.toString();
      }
      return const JsonEncoder.withIndent('  ').convert(resp);
    } catch (e) {
      return '读取文件失败：$e';
    }
  }

  static List<WorkspaceFileNode> _parseFileTreeResponse(
    Map<String, dynamic> resp, {
    required String basePath,
  }) {
    final raw = resp['entries'];
    final List<dynamic> list;
    if (raw is List) {
      list = raw;
    } else if (raw is Map && raw['entries'] is List) {
      list = raw['entries'] as List<dynamic>;
    } else {
      return const [];
    }
    final out = <WorkspaceFileNode>[];
    for (final item in list) {
      if (item is! Map) continue;
      final name = item['name']?.toString() ?? '';
      if (name.isEmpty || name == '.DS_Store') continue;
      final kind = (item['type'] ?? item['kind'] ?? 'file').toString();
      final isDir = kind == 'directory' || kind == 'dir';
      final itemPath = item['path']?.toString().isNotEmpty == true
          ? item['path'].toString()
          : (basePath.isEmpty ? name : '$basePath/$name');
      final sizeNum = (item['size'] as num?)?.toInt();
      final subtitle = isDir
          ? '目录'
          : (sizeNum != null ? _formatByteSize(sizeNum) : '文件');
      out.add(
        WorkspaceFileNode(
          name: name,
          path: itemPath,
          isDir: isDir,
          subtitle: subtitle,
        ),
      );
    }
    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  Future<void> refreshWorkspaceDiffs({bool silent = false, String? scope}) async {
    final effectiveScope = scope ?? state.activeDiffScope;
    if (effectiveScope != state.activeDiffScope) {
      state = state.copyWith(activeDiffScope: effectiveScope);
    }
    final client = _liveClient;
    if (client == null) {
      if (!silent) showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    final targetSid = state.activeSessionId;
    final targetWs = state.activeWorkspace;
    final wsScope = _resolveWorkspaceFileScope();
    if (wsScope.scopeId.isEmpty) return;
    final seq = ++_wsDiffSeq;
    try {
      final resp = await client.getWorkspaceFileChanges(
        wsScope.scopeId,
        sessionId: wsScope.sessionId,
        scope: effectiveScope,
      );
      if (!_isStillLive(client) ||
          seq != _wsDiffSeq ||
          state.activeDiffScope != effectiveScope ||
          state.activeSessionId != targetSid ||
          state.activeWorkspace != targetWs) {
        return;
      }
      final parsed = _parseDiffsResponse(resp);
      state = state.copyWith(workspaceDiffs: parsed, activeDiffScope: effectiveScope);
      if (!silent) {
        showToast(
          parsed.isEmpty ? '当前工作区暂无改动' : '已刷新改动（${parsed.length} 个文件）',
          tone: ToastTone.info,
        );
      }
    } catch (e) {
      if (!_isStillLive(client) ||
          seq != _wsDiffSeq ||
          state.activeDiffScope != effectiveScope ||
          state.activeSessionId != targetSid ||
          state.activeWorkspace != targetWs) {
        return;
      }
      if (!silent) showToast('刷新改动失败：${formatReadableError(e)}', tone: ToastTone.warn);
    }
  }

  static String _formatStartedAt(dynamic raw) {
    if (raw == null) return '';
    DateTime? dt;
    if (raw is num) {
      final v = raw.toInt();
      dt = DateTime.fromMillisecondsSinceEpoch(v > 100000000000 ? v : v * 1000);
    } else if (raw is String && raw.trim().isNotEmpty) {
      final numParsed = num.tryParse(raw.trim());
      if (numParsed != null) {
        final v = numParsed.toInt();
        dt = DateTime.fromMillisecondsSinceEpoch(v > 100000000000 ? v : v * 1000);
      } else {
        dt = DateTime.tryParse(raw.trim())?.toLocal();
      }
    }
    if (dt == null) return raw.toString();
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  static List<BackgroundJobRecord> _parseJobsResponse(
    Map<String, dynamic> resp, {
    String? fallbackSessionId,
  }) {
    final rawJobs = resp['jobs'];
    final mappedJobs = <BackgroundJobRecord>[];
    if (rawJobs is List) {
      for (final j in rawJobs) {
        if (j is! Map) continue;
        final id = j['jobId']?.toString() ?? j['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        mappedJobs.add(
          BackgroundJobRecord(
            id: id,
            command: j['label']?.toString() ?? j['command']?.toString() ?? 'job',
            cwd: j['cwd']?.toString() ?? '',
            status: j['status']?.toString() ?? 'running',
            startedAtLabel: _formatStartedAt(j['startedAt'] ?? j['createdAt']),
            outputLines: (j['outputLines'] as List<dynamic>?)
                    ?.map((e) => e.toString())
                    .toList(growable: false) ??
                const [],
            sessionId: j['sessionId']?.toString() ?? fallbackSessionId,
          ),
        );
      }
    }
    return mappedJobs;
  }

  static List<WorkspaceDiffRecord> _parseDiffsResponse(Map<String, dynamic> resp) {
    final raw = resp['changes'];
    final List<dynamic> list;
    if (raw is List) {
      list = raw;
    } else if (raw is Map && raw['files'] is List) {
      list = raw['files'] as List<dynamic>;
    } else if (raw is Map && raw['diffs'] is List) {
      list = raw['diffs'] as List<dynamic>;
    } else {
      return const [];
    }
    final out = <WorkspaceDiffRecord>[];
    for (final item in list) {
      if (item is! Map) continue;
      final path = (item['path'] ?? item['filePath'] ?? item['newPath'] ?? '').toString();
      if (path.isEmpty) continue;
      var unified = (item['patch'] ?? item['diff'] ?? item['unifiedDiff'] ?? '').toString();
      if (unified.isEmpty && item['hunks'] is List) {
        final buf = StringBuffer();
        for (final h in item['hunks'] as List) {
          if (h is! Map) continue;
          buf.writeln('@@ -${h['oldStart'] ?? 1},${h['oldLines'] ?? 0} +${h['newStart'] ?? 1},${h['newLines'] ?? 0} @@');
          if (h['lines'] is List) {
            for (final line in h['lines'] as List) {
              buf.writeln(line.toString());
            }
          }
        }
        unified = buf.toString().trimRight();
      }
      final rawStatus = (item['status'] ?? item['summary'] ?? 'modified').toString();
      final lowerStatus = rawStatus.toLowerCase();
      final zhStatus = switch (lowerStatus) {
        'added' => '新增',
        'deleted' => '已删除',
        'renamed' => '重命名',
        'untracked' => '未跟踪',
        'modified' => '已修改',
        _ => rawStatus,
      };
      final prevPath = (item['previousPath'] ?? item['oldPath'])?.toString().trim();
      final isBinary = item['binary'] == true ||
          unified.contains('Binary files ') ||
          unified.contains('GIT binary patch');
      final isOversized = item['oversized'] == true || item['truncated'] == true;
      final isUntracked = item['untracked'] == true || lowerStatus == 'untracked';
      out.add(
        WorkspaceDiffRecord(
          path: path,
          summary: zhStatus,
          added: (item['additions'] as num?)?.toInt() ?? (item['added'] as num?)?.toInt() ?? 0,
          removed: (item['deletions'] as num?)?.toInt() ?? (item['removed'] as num?)?.toInt() ?? 0,
          unifiedDiff: unified,
          previousPath: (prevPath != null && prevPath.isNotEmpty) ? prevPath : null,
          binary: isBinary,
          oversized: isOversized,
          untracked: isUntracked,
        ),
      );
    }
    return out;
  }

  static List<SessionGoalRecord> _parseGoalProjection(dynamic raw) {
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      final rec = SessionGoalRecord.fromJson(map);
      if (rec.title.isNotEmpty) return [rec];
    }
    if (raw is List) {
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => SessionGoalRecord.fromJson(Map<String, dynamic>.from(e)))
          .where((g) => g.title.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  static List<QueuedMessageItem>? _parseInboxProjection(dynamic rawInbox) {
    if (rawInbox is! Map) return null;
    final out = <QueuedMessageItem>[];
    void collect(dynamic rawList, String mode) {
      if (rawList is! List) return;
      for (final item in rawList) {
        if (item is! Map) continue;
        final msg = item['message'] is Map ? Map<String, dynamic>.from(item['message'] as Map) : item;
        final id = (item['id'] ?? msg['id'] ?? item['itemId'] ?? '').toString().trim();
        String text = (msg['text'] ?? item['text'] ?? '').toString().trim();
        if (text.isEmpty && msg['content'] is List) {
          text = (msg['content'] as List)
              .whereType<Map>()
              .map((p) => p['text']?.toString() ?? '')
              .where((s) => s.trim().isNotEmpty)
              .join('\n')
              .trim();
        } else if (text.isEmpty && msg['content'] is String) {
          text = (msg['content'] as String).trim();
        }
        if (id.isNotEmpty) {
          if (text.isEmpty && msg['content'] is List) {
            final attCount = (msg['content'] as List)
                .whereType<Map>()
                .where((p) => p['type'] == 'image' || p['type'] == 'file')
                .length;
            if (attCount > 0) {
              text = attCount == 1 ? '[附带 1 个附件]' : '[附带 $attCount 个附件]';
            }
          }
          if (text.isNotEmpty) {
            out.add(QueuedMessageItem(id: id, text: text, mode: mode, serverAcked: true));
          }
        }
      }
    }

    collect(rawInbox['nextStep'], 'steer');
    collect(rawInbox['nextTurn'], 'queue');
    return out;
  }

  static List<SessionGoalRecord> _parseGoalsResponse(Map<String, dynamic> resp) {
    final fromGoal = _parseGoalProjection(resp['goal']);
    if (fromGoal.isNotEmpty) return fromGoal;
    return _parseGoalProjection(resp['goals']);
  }

  static List<SlashCommandItem> _parseSlashCommandsResponse(Map<String, dynamic> resp) {
    final raw = resp['commands'];
    final List<dynamic> list;
    if (raw is List) {
      list = raw;
    } else if (raw is Map && raw['commands'] is List) {
      list = raw['commands'] as List<dynamic>;
    } else {
      return const [];
    }
    final byCommand = <String, SlashCommandItem>{
      for (final def in kDefaultSlashCommands) def.command.toLowerCase(): def,
    };
    for (final item in list) {
      if (item is! Map) continue;
      final name = (item['command'] ?? item['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final cmd = name.startsWith('/') ? name : '/$name';
      final key = cmd.toLowerCase();
      if (byCommand.containsKey(key)) continue; // Keep rich localized built-in metadata without duplicates!
      byCommand[key] = SlashCommandItem(
        command: cmd,
        title: (item['title'] ?? name).toString(),
        desc: (item['description'] ?? item['desc'] ?? '').toString(),
        category: (item['category'] ?? 'DSH 指令').toString(),
      );
    }
    return byCommand.values.toList(growable: false);
  }

  static String _formatByteSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _basenamePath(String p) {
    final clean = p.endsWith('/') && p.length > 1 ? p.substring(0, p.length - 1) : p;
    final idx = clean.lastIndexOf('/');
    return idx >= 0 && idx < clean.length - 1 ? clean.substring(idx + 1) : clean;
  }

  Future<void> renameSession(String sessionId, String newTitle) async {
    final clean = newTitle.trim();
    if (clean.isEmpty) return;
    final target = state.sessions.where((s) => s.id == sessionId).firstOrNull;
    if (target == null) return;
    final client = _liveClient;
    if (client == null && !sessionId.startsWith('pending-session-')) {
      showToast('当前未连接 DSH 主机，无法重命名对话', tone: ToastTone.warn);
      return;
    }
    final prevTitle = target.title;
    state = state.copyWith(
      sessions: [
        for (final s in state.sessions) s.id == sessionId ? s.copyWith(title: clean) : s,
      ],
    );
    if (client != null && !sessionId.startsWith('pending-session-')) {
      try {
        await client.patchSession(sessionId, title: clean);
        if (!_isStillLive(client)) return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        state = state.copyWith(
          sessions: [
            for (final s in state.sessions)
              s.id == sessionId ? s.copyWith(title: prevTitle) : s,
          ],
        );
        showError('重命名对话失败', error: e);
        return;
      }
    }
    if (mounted) showToast('已重命名对话');
  }

  Future<void> togglePinSession(String sessionId) async {
    final target = state.sessions.where((s) => s.id == sessionId).firstOrNull;
    if (target == null) return;
    final client = _liveClient;
    if (client == null && !sessionId.startsWith('pending-session-')) {
      showToast('当前未连接 DSH 主机，无法修改置顶状态', tone: ToastTone.warn);
      return;
    }
    final prevPinned = target.pinned;
    final nextPinned = !prevPinned;
    state = state.copyWith(
      sessions: [
        for (final s in state.sessions)
          s.id == sessionId ? s.copyWith(pinned: nextPinned) : s,
      ],
    );
    if (client != null && !sessionId.startsWith('pending-session-')) {
      try {
        await client.patchSession(sessionId, pinned: nextPinned);
        if (!_isStillLive(client)) return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        state = state.copyWith(
          sessions: [
            for (final s in state.sessions)
              s.id == sessionId ? s.copyWith(pinned: prevPinned) : s,
          ],
        );
        showError('更新置顶状态失败', error: e);
        return;
      }
    }
    if (mounted) showToast(nextPinned ? '已置顶对话' : '已取消置顶', tone: ToastTone.info);
  }

  Future<void> toggleArchiveSession(String sessionId) async {
    final target = state.sessions.where((s) => s.id == sessionId).firstOrNull;
    if (target == null) return;
    final client = _liveClient;
    if (client == null && !sessionId.startsWith('pending-session-')) {
      showToast('当前未连接 DSH 主机，无法归档对话', tone: ToastTone.warn);
      return;
    }
    final prevArchived = target.archived;
    final nextArchived = !prevArchived;
    state = state.copyWith(
      sessions: [
        for (final s in state.sessions)
          s.id == sessionId ? s.copyWith(archived: nextArchived) : s,
      ],
    );
    if (client != null && !sessionId.startsWith('pending-session-')) {
      try {
        await client.patchSession(sessionId, archived: nextArchived);
        if (!_isStillLive(client)) return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        state = state.copyWith(
          sessions: [
            for (final s in state.sessions)
              s.id == sessionId ? s.copyWith(archived: prevArchived) : s,
          ],
        );
        showError('更新归档状态失败', error: e);
        return;
      }
    }
    if (mounted) {
      if (nextArchived && state.activeSessionId == sessionId) {
        startNewChat();
      }
      showToast(nextArchived ? '已归档对话' : '已恢复到活跃列表', tone: ToastTone.info);
    }
  }

  Future<void> archiveSessionsBatch(Set<String> ids, {required bool archived}) async {
    if (ids.isEmpty) return;
    final client = _liveClient;
    final realIds = ids.where((id) => !id.startsWith('pending-session-')).toSet();
    if (client == null && realIds.isNotEmpty) {
      showToast('当前未连接 DSH 主机，无法批量归档对话', tone: ToastTone.warn);
      return;
    }
    final prev = state.sessions;
    state = state.copyWith(
      sessions: [
        for (final s in state.sessions)
          ids.contains(s.id) ? s.copyWith(archived: archived) : s,
      ],
    );
    if (client != null && realIds.isNotEmpty) {
      final failed = <String>{};
      Object? firstError;
      await Future.wait(
        realIds.map((id) async {
          try {
            await client.patchSession(id, archived: archived);
          } catch (e) {
            failed.add(id);
            firstError ??= e;
          }
        }),
      );
      if (!_isStillLive(client)) return;
      if (failed.isNotEmpty) {
        final prevById = {for (final s in prev) s.id: s};
        state = state.copyWith(
          sessions: [
            for (final s in state.sessions)
              failed.contains(s.id) ? (prevById[s.id] ?? s) : s,
          ],
        );
        final archivedIds = ids.difference(failed);
        if (archived && state.activeSessionId != null && archivedIds.contains(state.activeSessionId)) {
          startNewChat();
        }
        showError('部分对话归档失败（${failed.length} 条）', error: firstError);
        return;
      }
    }
    if (mounted) {
      if (archived && state.activeSessionId != null && ids.contains(state.activeSessionId)) {
        startNewChat();
      }
      showToast(
        archived ? '已归档 ${ids.length} 个对话' : '已恢复 ${ids.length} 个对话',
        tone: ToastTone.info,
      );
    }
  }

  Future<void> deleteSessionsBatch(Set<String> ids) async {
    if (ids.isEmpty) return;
    final client = _liveClient;
    final realIds = ids.where((id) => !id.startsWith('pending-session-')).toSet();
    if (client == null && realIds.isNotEmpty) {
      showToast('当前未连接 DSH 主机，无法删除对话', tone: ToastTone.warn);
      return;
    }
    final prevSessions = state.sessions;
    final failed = <String>{};
    Object? firstError;
    if (client != null && realIds.isNotEmpty) {
      await Future.wait(
        realIds.map((id) async {
          try {
            await client.deleteSession(id);
          } catch (e) {
            failed.add(id);
            firstError ??= e;
          }
        }),
      );
      if (!_isStillLive(client)) return;
    }

    final deletedIds = ids.difference(failed);
    if (deletedIds.isEmpty) {
      showError('删除对话失败（${failed.length} 条）', error: firstError);
      return;
    }

    final remaining = state.sessions.where((s) => !deletedIds.contains(s.id)).toList(growable: false);
    // Re-check the CURRENT active session ID at commit time (not pre-request `prevActiveId`)
    // so switching to another session while batch deletion is in flight NEVER wipes the new session!
    final currentActiveId = state.activeSessionId;
    final clearCur = currentActiveId != null && deletedIds.contains(currentActiveId);
    for (final delId in deletedIds) {
      final inFlight = _activeSendRunIdBySession.remove(delId);
      if (inFlight != null) _cancelledSendRunIds.add(inFlight);
    }
    if (clearCur) {
      _clearPendingStreamCoalesce();
      _disarmStreamWatchdog();
      _locallyCancelledTurnIds.clear();
      _cancelSuppressUntilMs = 0;
      _streamRunId++;
      if (client != null && !currentActiveId.startsWith('pending-session-')) {
        client.stream.unsubscribe('session:$currentActiveId');
      }
      _turnReducer.replaceAll(const []);
    }
    _pendingInteractionsById.removeWhere((_, item) {
      final sid = item.sessionId ?? item.payload['sessionId']?.toString();
      return sid != null && deletedIds.contains(sid);
    });
    final hostCtxEntry = _hostContexts[state.activeHostId];
    final draftsMap = hostCtxEntry?['sessionDrafts'];
    var draftsChanged = false;
    for (final id in deletedIds) {
      _sessionTurnsMemory.remove(id);
      _sessionPaginationMemory.remove(id);
      _sessionStreamSeq.remove(id);
      _sessionAttachmentsMemory.remove(_attachmentsScopeKey(state.activeHostId, id));
      if (draftsMap is Map && draftsMap.remove(id) != null) {
        draftsChanged = true;
      }
    }
    if (draftsChanged) {
      if (draftsMap is Map && draftsMap.isEmpty) {
        hostCtxEntry?.remove('sessionDrafts');
      }
      _persistHostContexts(immediate: false);
    }
    state = state.copyWith(
      sessions: remaining,
      clearActiveSession: clearCur,
      turns: clearCur ? const [] : state.turns,
      turnFeedback: clearCur ? const {} : state.turnFeedback,
      toolOutputCache: clearCur ? const {} : state.toolOutputCache,
      stepTranslations: clearCur ? const {} : state.stepTranslations,
      translatedStepIds: clearCur ? const {} : state.translatedStepIds,
      translatingStepIds: clearCur ? const {} : state.translatingStepIds,
      expandedTurnProcessIds: clearCur ? const {} : state.expandedTurnProcessIds,
      collapsedTurnProcessIds: clearCur ? const {} : state.collapsedTurnProcessIds,
      expandedStepIds: clearCur ? const {} : state.expandedStepIds,
      hasMoreTurns: clearCur ? false : state.hasMoreTurns,
      clearTurnsNextCursor: clearCur,
      loadingOlderTurns: clearCur ? false : state.loadingOlderTurns,
      clearSessionLoadError: clearCur,
      clearPendingApproval: clearCur,
      clearActiveQuestion: clearCur,
      clearActiveCordisRequest: clearCur,
      pendingAttachments: clearCur
          ? _restorePendingAttachmentsForScope(state.activeHostId, null)
          : state.pendingAttachments,
      queuedMessages: clearCur ? const [] : state.queuedMessages,
      workspaceFiles: clearCur ? const [] : state.workspaceFiles,
      workspaceCurrentPath: clearCur ? '' : state.workspaceCurrentPath,
      workspaceDiffs: clearCur ? const [] : state.workspaceDiffs,
      todos: clearCur ? const [] : state.todos,
      goals: clearCur ? const [] : state.goals,
      subagents: clearCur ? const [] : state.subagents,
      contextPct: clearCur ? 0 : state.contextPct,
      contextUsedK: clearCur ? 0 : state.contextUsedK,
      contextBreakdown: clearCur ? const {} : state.contextBreakdown,
      sessionTelemetry: clearCur ? const SessionTelemetry() : state.sessionTelemetry,
      isStreaming: clearCur ? false : state.isStreaming,
      sendStage: clearCur ? SendStage.idle : state.sendStage,
      uploadDoneCount: clearCur ? 0 : state.uploadDoneCount,
      uploadTotalCount: clearCur ? 0 : state.uploadTotalCount,
      isStopping: clearCur ? false : state.isStopping,
      streamStalled: clearCur ? false : state.streamStalled,
      sessionRenderGen: clearCur ? state.sessionRenderGen + 1 : state.sessionRenderGen,
    );
    _recomputeVisibleInteractions();
    if (clearCur) _saveCurrentHostContext(allowClearSession: true);

    if (failed.isNotEmpty) {
      final restored = prevSessions.where((s) => failed.contains(s.id)).toList(growable: false);
      final existingIds = state.sessions.map((s) => s.id).toSet();
      final missing = restored.where((s) => !existingIds.contains(s.id)).toList(growable: false);
      if (missing.isNotEmpty) {
        state = state.copyWith(sessions: [...missing, ...state.sessions]);
      }
      showError('部分对话删除失败（${failed.length} 条）', error: firstError);
      return;
    }
    if (mounted) showToast('已移除 ${deletedIds.length} 个对话', tone: ToastTone.info);
  }

  Future<bool> forkActiveSession({String? turnId, bool syncAfter = true}) async {
    if (_isForking) return false;
    final cur = state.activeSession;
    if (cur == null) return false;
    final client = _liveClient;
    if (client == null || cur.id.startsWith('pending-session-')) {
      showToast('当前未连接 DSH 主机，无法创建分支对话', tone: ToastTone.warn);
      return false;
    }
    _isForking = true;
    try {
      return await _forkActiveSessionInner(cur, client, turnId: turnId, syncAfter: syncAfter);
    } finally {
      _isForking = false;
    }
  }

  Future<bool> _forkActiveSessionInner(
    ChatSessionItem cur,
    GbridgeClient client, {
    String? turnId,
    bool syncAfter = true,
  }) async {
    var forkId = 'fork-${DateTime.now().millisecondsSinceEpoch}';
    final forkTitle = '${cur.title} (分支)';
    final cutIndex = turnId == null
        ? -1
        : state.turns.indexWhere((t) => t.turnId == turnId);
    final targetTurn = cutIndex >= 0 ? state.turns[cutIndex] : null;
    final copiedTurns = cutIndex >= 0
        ? state.turns.sublist(0, cutIndex + 1)
        : List<NormalizedTurn>.of(state.turns);

    try {
      final resp = await client.forkSession(
        cur.id,
        turnId: turnId,
        atSeq: (targetTurn != null && targetTurn.seqEnd > 0) ? targetTurn.seqEnd : null,
        title: forkTitle,
      );
      if (!_isStillLive(client) || state.activeSessionId != cur.id) return false;
      final res = resp['result'];
      final realId = (res is Map ? (res['sessionId'] ?? res['id']) : null)?.toString() ??
          (resp['sessionId'] ?? resp['id'])?.toString();
      if (realId == null || realId.isEmpty) {
        showError('创建分支对话失败', error: '主机未返回新分支会话 ID');
        return false;
      }
      forkId = realId;
      client.stream.unsubscribe('session:${cur.id}');
      client.stream.subscribe('session:$forkId', force: true);
    } catch (e) {
      if (!_isStillLive(client)) return false;
      showError('创建分支对话失败', error: e);
      return false;
    }
    _clearPendingStreamCoalesce();
    _disarmStreamWatchdog();
    _locallyCancelledTurnIds.clear();
    _cancelSuppressUntilMs = 0;
    _streamRunId++;
    _cacheSessionTurns(forkId, copiedTurns);
    final preservedHasMore = !syncAfter && state.hasMoreTurns;
    final preservedCursor = preservedHasMore ? state.turnsNextCursor : null;
    if (preservedHasMore) {
      _sessionPaginationMemory[forkId] = (hasMore: true, nextCursor: preservedCursor);
    }
    _stashPendingAttachmentsForScope(state.activeHostId, cur.id);
    _turnReducer.replaceAll(copiedTurns);

    final forkedItem = ChatSessionItem(
      id: forkId,
      title: forkTitle,
      group: '今天',
      workspaceId: cur.workspaceId,
      workspaceName: cur.workspaceName,
      cwd: cur.cwd,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    state = state.copyWith(
      sessions: [
        forkedItem,
        for (final s in state.sessions)
          if (s.id != forkId) s,
      ],
      activeSessionId: forkId,
      turns: copiedTurns,
      turnFeedback: const {},
      toolOutputCache: const {},
      stepTranslations: const {},
      translatedStepIds: const {},
      translatingStepIds: const {},
      expandedTurnProcessIds: const {},
      collapsedTurnProcessIds: const {},
      expandedStepIds: const {},
      hasMoreTurns: preservedHasMore,
      turnsNextCursor: preservedCursor,
      clearTurnsNextCursor: !preservedHasMore,
      loadingOlderTurns: false,
      sessionTelemetry: state.sessionTelemetry.copyWith(clearLive: true),
      isStreaming: false,
      sendStage: SendStage.idle,
      isStopping: false,
      streamStalled: false,
      clearPendingApproval: true,
      clearActiveQuestion: true,
      clearActiveCordisRequest: true,
      clearOfflineUnsentNotice: true,
      pendingAttachments: const [],
      queuedMessages: const [],
      sessionRenderGen: state.sessionRenderGen + 1,
      sessionJumpSignal: state.sessionJumpSignal + 1,
    );
    _recomputeVisibleInteractions();
    _saveCurrentHostContext();
    if (syncAfter) {
      unawaited(_syncLiveSessionBundle(forkId, jumpToBottomOnLoad: false));
    }
    showToast('已创建分支对话：$forkTitle');
    return true;
  }

  Future<void> exportActiveSession() async {
    final cur = state.activeSession;
    if (cur == null) return;
    // Bind host, session, turns, pagination state & client upfront so switching sessions
    // or hosts while awaiting server export can NEVER mix another session's turns into this file!
    final boundSessionId = cur.id;
    final boundTitle = cur.title;
    final boundTurns = List<NormalizedTurn>.of(state.turns);
    final boundHasMore = state.hasMoreTurns;
    final boundClient = _liveClient;

    String content = '';
    var usedPartialFallback = false;
    if (boundClient != null && !boundSessionId.startsWith('pending-session-')) {
      try {
        final resp = await boundClient.exportSessionMarkdown(boundSessionId);
        final mdFromServer = resp['markdown']?.toString();
        if (mdFromServer != null && mdFromServer.trim().isNotEmpty) {
          content = mdFromServer;
        }
      } catch (_) {}
    }
    if (content.isEmpty) {
      usedPartialFallback = boundHasMore;
      final md = StringBuffer()
        ..writeln('# $boundTitle')
        ..writeln('');
      if (boundHasMore) {
        md.writeln('> 注：服务端导出不可用，以下为客户端已加载的最近 ${boundTurns.length} 轮对话快照（更早历史未完全加载）。\n');
      }
      for (final t in boundTurns) {
        if (t.userMessage != null) {
          md.writeln('## 用户\n${t.userMessage!.text}\n');
        }
        final fullProse = t.combinedAssistantProse;
        if (fullProse.isNotEmpty) {
          md.writeln('## 助手\n$fullProse\n');
        }
      }
      content = md.toString();
    }
    final safeBase = boundTitle.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5-]+'), '_');
    final fileName = usedPartialFallback
        ? '${safeBase.isEmpty ? 'session' : safeBase}_recent_${boundTurns.length}turns.md'
        : '${safeBase.isEmpty ? 'session' : safeBase}.md';
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      final shared = await GrassBagNativeBridge.instance.shareTextFile(
        text: content,
        filename: fileName,
        mimeType: 'text/markdown',
      );
      if (!shared) {
        await GrassBagNativeBridge.instance.shareText(content);
      }
      showToast(
        usedPartialFallback
            ? '已导出「$boundTitle」最近 ${boundTurns.length} 轮（服务端整包导出失败）'
            : '已打开系统分享导出「$boundTitle」',
        tone: usedPartialFallback ? ToastTone.warn : ToastTone.ok,
      );
      return;
    }
    if (downloadWebTextFile(fileName, content)) {
      await Clipboard.setData(ClipboardData(text: content));
      showToast(
        usedPartialFallback
            ? '已下载 $fileName（仅含最近 ${boundTurns.length} 轮）并复制到剪贴板'
            : '已下载 $fileName 并复制到剪贴板',
        tone: usedPartialFallback ? ToastTone.warn : ToastTone.ok,
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: content));
    showToast(
      usedPartialFallback
          ? '已复制最近 ${boundTurns.length} 轮 Markdown 到剪贴板（部分历史）'
          : '已将完整 Markdown 内容复制到剪贴板',
      tone: usedPartialFallback ? ToastTone.warn : ToastTone.ok,
    );
  }

  /// Downloads & shares the full session archive (`.zip`, including turns/attachments/descendants)
  /// via `dsh-gbridge`'s `/sessions/:id/export` endpoint, bound to the host/session at start.
  Future<bool> exportActiveSessionZip({bool includeDescendants = true}) async {
    final cur = state.activeSession;
    final boundClient = _liveClient;
    if (cur == null || cur.id.startsWith('pending-session-')) {
      showToast('当前会话尚未保存到主机，无法导出 ZIP 归档', tone: ToastTone.warn);
      return false;
    }
    if (boundClient == null) {
      showToast('当前未连接 DSH 主机，无法导出会话 ZIP', tone: ToastTone.warn);
      return false;
    }
    if (boundClient.isVanillaDirect) {
      showToast('完整 ZIP 导出需要连接助手插件（dsh-gbridge），直连模式可使用 Markdown 导出', tone: ToastTone.info);
      return false;
    }
    final boundSessionId = cur.id;
    final boundTitle = cur.title;
    showToast('正在打包会话 ZIP 归档…', tone: ToastTone.info);
    try {
      final zipBytes = await boundClient.exportSessionZip(
        boundSessionId,
        includeDescendants: includeDescendants,
      );
      if (zipBytes.isEmpty) {
        showToast('主机返回的会话 ZIP 为空', tone: ToastTone.warn);
        return false;
      }
      final safeBase = boundTitle.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5-]+'), '_');
      final fileName = '${safeBase.isEmpty ? 'session' : safeBase}.zip';
      if (GrassBagNativeBridge.instance.isAndroidNative) {
        final ok = await GrassBagNativeBridge.instance.shareFileBytes(
          bytes: zipBytes,
          filename: fileName,
          mimeType: 'application/zip',
        );
        if (ok) {
          showToast('已生成并分享完整会话归档 $fileName', tone: ToastTone.ok);
        } else {
          showToast('调用系统分享 ZIP 失败', tone: ToastTone.warn);
        }
        return ok;
      }
      if (downloadWebBytes(fileName, zipBytes, mimeType: 'application/zip')) {
        showToast(
          kIsWeb ? '已下载完整会话归档 $fileName' : '已保存至下载目录 · $fileName',
          tone: ToastTone.ok,
        );
        return true;
      }
      showToast('当前平台暂不支持直接保存二进制 ZIP 文件', tone: ToastTone.warn);
      return false;
    } catch (e) {
      showError('导出会话 ZIP 失败', error: e);
      return false;
    }
  }

  /// Renders a workspace Office document (`.docx`/`.xlsx`/`.pptx`, etc.) to PDF bytes via
  /// `dsh-gbridge`'s `/workspaces/:id/files/office-preview` endpoint.
  Future<Uint8List?> renderWorkspaceOfficeToPdf(String path) async {
    final client = _liveClient;
    if (client == null || client.isVanillaDirect) return null;
    final scope = _resolveWorkspaceFileScope();
    if (scope.scopeId.isEmpty) return null;
    try {
      final bytes = await client.renderOfficePreview(scope.scopeId, path: path);
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  String? feedbackForTurn(NormalizedTurn turn) {
    final hostId = state.activeHostId;
    final sid = state.activeSessionId;
    if (sid == null || sid.isEmpty) return null;
    final msgId = turn.assistantMessageId ?? turn.turnId;
    return state.turnFeedback['$hostId:$sid:$msgId'] ??
        state.turnFeedback['$hostId:$sid:${turn.turnId}'] ??
        state.turnFeedback['$sid:$msgId'] ??
        state.turnFeedback['$sid:${turn.turnId}'];
  }

  Future<void> putTurnFeedback(String turnId, String rating) async {
    final hostId = state.activeHostId;
    final sid = state.activeSessionId;
    final turn = state.turns.where((t) => t.turnId == turnId).firstOrNull;
    final messageId = turn?.assistantMessageId ?? turnId;
    final key = (sid != null && sid.isNotEmpty) ? '$hostId:$sid:$messageId' : '$hostId:__new__:$turnId';
    final turnKey = (sid != null && sid.isNotEmpty) ? '$hostId:$sid:$turnId' : null;
    final legacyKey = (sid != null && sid.isNotEmpty) ? '$sid:$messageId' : null;
    final legacyTurnKey = (sid != null && sid.isNotEmpty) ? '$sid:$turnId' : null;
    final prev = Map<String, String>.of(state.turnFeedback);
    final next = Map<String, String>.of(state.turnFeedback);
    final removing = next[key] == rating ||
        (turnKey != null && next[turnKey] == rating) ||
        (legacyKey != null && next[legacyKey] == rating) ||
        (legacyTurnKey != null && next[legacyTurnKey] == rating);
    if (removing) {
      next.remove(key);
      if (turnKey != null) next.remove(turnKey);
      if (legacyKey != null) next.remove(legacyKey);
      if (legacyTurnKey != null) next.remove(legacyTurnKey);
    } else {
      next[key] = rating;
    }
    final client = _liveClient;
    state = state.copyWith(turnFeedback: next);
    if (client != null && sid != null && !sid.startsWith('pending-session-')) {
      try {
        if (removing) {
          await client.deleteMessageFeedback(sid, messageId: messageId);
        } else {
          await client.putMessageFeedback(sid, messageId: messageId, rating: rating);
        }
        if (!_isStillLive(client)) return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        if (state.activeSessionId == sid) {
          final rolledBack = Map<String, String>.of(state.turnFeedback);
          void restoreKey(String? k) {
            if (k == null) return;
            if (prev.containsKey(k)) {
              rolledBack[k] = prev[k]!;
            } else {
              rolledBack.remove(k);
            }
          }
          restoreKey(key);
          restoreKey(turnKey);
          restoreKey(legacyKey);
          restoreKey(legacyTurnKey);
          state = state.copyWith(turnFeedback: rolledBack);
        }
        showError('提交反馈失败', error: e);
        return;
      }
    }
    showToast(
      removing ? '已取消反馈' : (rating == 'up' ? '已记录正向反馈' : '已记录改进反馈'),
      tone: ToastTone.info,
    );
  }

  Future<Map<String, dynamic>> loadToolDetail(
    String callId, {
    bool forceRefresh = false,
  }) async {
    final client = _liveClient;
    final hostId = state.activeHostId;
    final sid = state.activeSessionId;
    final cacheKey = (sid != null && sid.isNotEmpty) ? '$hostId:$sid:$callId' : '$hostId:__new__:$callId';
    if (!forceRefresh) {
      final existing = _toolDetailCache[cacheKey];
      if (existing != null && existing['status'] != 'running') return existing;
    }

    if (client != null && sid != null && !sid.startsWith('pending-session-')) {
      try {
        final res = await client.getToolOutput(sid, callId);
        if (!_isStillLive(client) || state.activeSessionId != sid) {
          return const <String, dynamic>{};
        }
        final rawTool = res['tool'];
        if (rawTool is Map) {
          final map = Map<String, dynamic>.from(rawTool);
          final outVal = map['output'] ?? map['stdout'];
          String formatJsonLike(Object? v) {
            if (v == null) return '';
            if (v is String) {
              if (v.length > 96 * 1024) return v;
              final trimmed = v.trim();
              if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
                  (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
                try {
                  return const JsonEncoder.withIndent('  ').convert(jsonDecode(trimmed));
                } catch (_) {}
              }
              return v;
            }
            try {
              final compact = jsonEncode(v);
              if (compact.length > 96 * 1024) return compact;
              return const JsonEncoder.withIndent('  ').convert(v);
            } catch (_) {
              return v.toString();
            }
          }
          final outStr = formatJsonLike(outVal);
          final argsVal = map['args'];
          final argsStr = argsVal == null || (argsVal is Map && argsVal.isEmpty)
              ? ''
              : formatJsonLike(argsVal);
          final status = map['status']?.toString() ?? 'ok';
          final detail = <String, dynamic>{
            'name': map['name']?.toString() ?? '',
            'status': status,
            'args': argsVal is Map ? Map<String, dynamic>.from(argsVal) : const <String, dynamic>{},
            'argsText': argsStr,
            'outputText': outStr,
          };
          if (status != 'running') {
            _toolDetailCache.remove(cacheKey);
            _toolDetailCache[cacheKey] = detail;
            while (_toolDetailCache.length > _maxToolCacheEntries) {
              _toolDetailCache.remove(_toolDetailCache.keys.first);
            }
          }
          return detail;
        }
      } catch (_) {
        // Fall back gracefully to step summary below.
      }
    }
    return const <String, dynamic>{};
  }

  Future<String> loadToolFullOutput(String callId) async {
    final hostId = state.activeHostId;
    final sid = state.activeSessionId;
    final cacheKey = (sid != null && sid.isNotEmpty) ? '$hostId:$sid:$callId' : '$hostId:__new__:$callId';
    final cachedDetail = _toolDetailCache[cacheKey];
    final cachedOut = cachedDetail?['outputText']?.toString();
    if (cachedOut != null && cachedOut.isNotEmpty && cachedDetail?['status'] != 'running') {
      return cachedOut;
    }
    final detail = await loadToolDetail(callId);
    final out = detail['outputText']?.toString() ?? '';
    if (out.isNotEmpty) return out;
    if (_liveClient == null) {
      return '当前未连接到 DSH 主机，无法加载历史工具输出。';
    }
    return '';
  }

  void toggleTurnProcess() => state = state.copyWith(turnProcessOpen: !state.turnProcessOpen);

  void toggleTurnProcessFor(String turnId, {required bool currentlyOpen}) {
    final nextExpanded = Set<String>.of(state.expandedTurnProcessIds);
    final nextCollapsed = Set<String>.of(state.collapsedTurnProcessIds);
    if (currentlyOpen) {
      nextExpanded.remove(turnId);
      nextCollapsed.add(turnId);
    } else {
      nextCollapsed.remove(turnId);
      nextExpanded.add(turnId);
    }
    state = state.copyWith(
      expandedTurnProcessIds: nextExpanded,
      collapsedTurnProcessIds: nextCollapsed,
    );
  }

  void toggleStepExpanded(String stepId) {
    final next = Set<String>.of(state.expandedStepIds);
    if (!next.add(stepId)) next.remove(stepId);
    state = state.copyWith(expandedStepIds: next);
  }

  void toggleStepTranslated(String stepId) {
    final next = Set<String>.of(state.translatedStepIds);
    if (!next.add(stepId)) next.remove(stepId);
    state = state.copyWith(translatedStepIds: next);
  }

  void toggleSecretRevealed() => state = state.copyWith(secretRevealed: !state.secretRevealed);
  void nextEmptyTip() => state = state.copyWith(tipIndex: (state.tipIndex + 1) % kEmptyTips.length);

  // ---------------------------------------------------------------------------
  // Composer Attachments & Slash Commands
  // ---------------------------------------------------------------------------
  Future<void> pickComposerAttachment({required String source}) async {
    final native = GrassBagNativeBridge.instance;
    if (native.isAndroidNative) {
      final picked = source == 'camera'
          ? await native.takePhotoAttachment()
          : await native.pickAttachment(mime: source == 'gallery' ? 'image/*' : '*/*');
      if (picked != null && mounted) {
        if (picked.error != null && picked.error!.isNotEmpty) {
          showToast(picked.error!, tone: ToastTone.warn);
          return;
        }
        addPendingAttachment(
          ComposerAttachment(
            id: 'att-${DateTime.now().millisecondsSinceEpoch}',
            name: picked.name,
            mimeType: picked.mimeType,
            sizeBytes: picked.size,
            bytes: picked.bytes,
          ),
        );
      }
      return;
    }
    if (kIsWeb) {
      final picked = await pickWebFile(
        accept: source == 'gallery' || source == 'camera' ? 'image/*' : '*/*',
      );
      if (picked != null && mounted) {
        if (picked.bytes.length > 4 * 1024 * 1024) {
          showToast('文件超过 4 MB 大小上限', tone: ToastTone.warn);
          return;
        }
        addPendingAttachment(
          ComposerAttachment(
            id: 'att-${DateTime.now().millisecondsSinceEpoch}',
            name: picked.name,
            mimeType: picked.mimeType,
            sizeBytes: picked.bytes.length,
            bytes: picked.bytes,
          ),
        );
      }
      return;
    }
    showToast('当前平台请使用剪贴板粘贴或在移动端选择本地文件', tone: ToastTone.info);
  }

  void addPendingAttachment(ComposerAttachment att) {
    final attBytes = att.bytes?.length ?? att.sizeBytes;
    if (attBytes > _maxSingleAttachmentBytes) {
      showToast('单个附件不能超过 8 MB', tone: ToastTone.warn);
      return;
    }
    if (state.pendingAttachments.length >= _maxPendingAttachmentsCount) {
      showToast('单条消息最多附加 $_maxPendingAttachmentsCount 个附件', tone: ToastTone.warn);
      return;
    }
    final curBytes = _attachmentListBytes(state.pendingAttachments);
    if (curBytes + attBytes > _maxPendingAttachmentsTotalBytes) {
      showToast('待发送附件总大小超过 16 MB 上限', tone: ToastTone.warn);
      return;
    }
    state = state.copyWith(pendingAttachments: [...state.pendingAttachments, att]);
    showToast('已附加 ${att.name}', tone: ToastTone.info);
  }

  void removePendingAttachment(String id) {
    state = state.copyWith(
      pendingAttachments: state.pendingAttachments.where((a) => a.id != id).toList(growable: false),
    );
  }

  // ---------------------------------------------------------------------------
  // Workspaces, Presets, Permissions, Models, Goals, Todos
  // ---------------------------------------------------------------------------
  void setWorkspace(String name) {
    final client = _liveClient;
    final ws = state.workspaces.where((w) => w.id == name).firstOrNull ??
        state.workspaces.where((w) => w.path.isNotEmpty && w.path == name).firstOrNull ??
        state.workspaces.where((w) => w.name == name).firstOrNull;
    final resolvedKey = ws?.id ?? name;
    final displayName = ws?.name ?? name;
    state = state.copyWith(
      activeWorkspace: resolvedKey,
      workspaceFiles: const [],
      workspaceCurrentPath: '',
      workspaceDiffs: const [],
    );
    _saveCurrentHostContext();
    if (client != null) {
      unawaited(loadWorkspaceDirectory(path: '.', silent: true));
      unawaited(refreshWorkspaceDiffs(silent: true));
    }
    showToast('已切换工作区：$displayName');
  }

  Future<bool> addWorkspace(String name, String path) async {
    final cleanPath = path.trim();
    if (cleanPath.isEmpty) return false;
    final cleanName = name.trim().isEmpty ? _basenamePath(cleanPath) : name.trim();
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机后再挂载工作区', tone: ToastTone.warn);
      return false;
    }
    try {
      final resp = await client.createWorkspace(path: cleanPath, name: cleanName);
      if (!_isStillLive(client)) return false;
      final attached = (resp['attachedCount'] as num?)?.toInt() ?? 0;
      final createdId = (resp['workspace'] is Map
              ? (resp['workspace'] as Map)['id']?.toString()
              : null) ??
          resp['id']?.toString();
      await _hydrateLiveDomains(client);
      if (!_isStillLive(client)) return false;
      String? canonicalId = (createdId != null && createdId.isNotEmpty) ? createdId : null;
      if (canonicalId == null) {
        for (final w in state.workspaces) {
          if (w.path == cleanPath || w.name == cleanName) {
            canonicalId = w.id;
            break;
          }
        }
      }
      state = state.copyWith(
        activeWorkspace: canonicalId ?? cleanName,
        workspaceFiles: const [],
        workspaceCurrentPath: '',
        workspaceDiffs: const [],
      );
      _saveCurrentHostContext();
      unawaited(loadWorkspaceDirectory(path: '.', silent: true));
      unawaited(refreshWorkspaceDiffs(silent: true));
      showToast(
        attached > 0
            ? '已创建工作区「$cleanName」并归组 $attached 条历史对话'
            : '已创建并切换工作区：$cleanName',
      );
      return true;
    } catch (e) {
      if (!_isStillLive(client)) return false;
      showError('创建工作区失败', error: e);
      return false;
    }
  }

  Future<void> organizeWorkspacesByCwd() async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到 DSH 主机', tone: ToastTone.warn);
      return;
    }
    try {
      final resp = await client.organizeWorkspacesByCwd();
      if (!_isStillLive(client)) return;
      final wsCount = (resp['workspacesCount'] as num?)?.toInt() ?? 0;
      final attached = (resp['attachedCount'] as num?)?.toInt() ?? 0;
      await _hydrateLiveDomains(client);
      if (!_isStillLive(client)) return;
      showToast('已按目录同步 $wsCount 个工作区，归组 $attached 条对话（官方网页端已同步）');
    } catch (e) {
      if (!_isStillLive(client)) return;
      showError('按目录归组失败', error: e);
    }
  }

  Future<Map<String, dynamic>> browseRemoteFs({String? path}) async {
    if (_liveClient != null) {
      try {
        return await _liveClient!.browseFs(path: path);
      } catch (e) {
        return {'path': path ?? '', 'parent': null, 'entries': const [], 'error': formatReadableError(e)};
      }
    }
    return {'path': path ?? '', 'parent': null, 'entries': const [], 'error': '当前未连接到 DSH 主机'};
  }

  Future<String?> createRemoteDirectory(String parentPath, String folderName) async {
    final cleanName = folderName.trim();
    if (cleanName.isEmpty) return null;
    if (_liveClient == null) {
      showToast('当前未连接 DSH 主机，无法新建目录', tone: ToastTone.warn);
      return null;
    }
    try {
      final res = await _liveClient!.mkdirFs(path: parentPath, name: cleanName);
      final nextPath = res['path']?.toString() ?? '$parentPath/$cleanName';
      showToast('已创建文件夹：$cleanName');
      return nextPath;
    } catch (e) {
      showError('创建文件夹失败', error: e);
      return null;
    }
  }

  Future<void> deleteWorkspaceItem(WorkspaceItem ws) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    if (!ws.explicit) {
      showToast('该工作区由历史对话目录自动推导，无需手动移除', tone: ToastTone.info);
      return;
    }
    try {
      await client.deleteWorkspace(ws.id);
      if (!_isStillLive(client)) return;
      final filterMatched = state.sidebarWorkspaceFilter == ws.id ||
          state.sidebarWorkspaceFilter == ws.name ||
          state.sidebarWorkspaceFilter == ws.path;
      final activeMatched = state.activeWorkspace == ws.id ||
          state.activeWorkspace == ws.name ||
          state.activeWorkspace == ws.path;
      if (filterMatched || activeMatched) {
        final remaining = state.workspaces.where((w) => w.id != ws.id).toList(growable: false);
        state = state.copyWith(
          clearSidebarWorkspaceFilter: filterMatched,
          activeWorkspace: activeMatched
              ? (remaining.isNotEmpty
                  ? (remaining.first.id.isNotEmpty ? remaining.first.id : remaining.first.name)
                  : '')
              : state.activeWorkspace,
        );
        _saveCurrentHostContext();
      }
      await _hydrateLiveDomains(client);
      if (!_isStillLive(client)) return;
      showToast('已移除工作区「${ws.name}」（目录文件不会被删除）', tone: ToastTone.info);
    } catch (e) {
      if (!_isStillLive(client)) return;
      showError('移除工作区失败', error: e);
    }
  }

  Future<bool> renameWorkspaceItem(WorkspaceItem ws, String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty) return false;
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return false;
    }
    if (!ws.explicit) {
      showToast('仅支持重命名已显式挂载的工作区', tone: ToastTone.info);
      return false;
    }
    try {
      await client.patchWorkspace(ws.id, name: clean);
      if (!_isStillLive(client)) return false;
      if (state.activeWorkspace == ws.name ||
          state.activeWorkspace == ws.id ||
          state.sidebarWorkspaceFilter == ws.name ||
          state.sidebarWorkspaceFilter == ws.id) {
        state = state.copyWith(
          activeWorkspace: (state.activeWorkspace == ws.name || state.activeWorkspace == ws.id)
              ? ws.id
              : state.activeWorkspace,
          sidebarWorkspaceFilter:
              (state.sidebarWorkspaceFilter == ws.name || state.sidebarWorkspaceFilter == ws.id)
                  ? ws.id
                  : state.sidebarWorkspaceFilter,
        );
        _saveCurrentHostContext();
      }
      await _hydrateLiveDomains(client);
      if (!_isStillLive(client)) return false;
      showToast('已重命名工作区为「$clean」');
      return true;
    } catch (e) {
      if (!_isStillLive(client)) return false;
      showError('重命名工作区失败', error: e);
      return false;
    }
  }

  Future<void> setPreset(String presetId) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机后再切换角色预设', tone: ToastTone.warn);
      return;
    }
    final preset = state.presets.firstWhere(
      (p) => p.id == presetId,
      orElse: () => PresetOption(id: presetId, name: presetId, desc: ''),
    );
    final myPresetGen = ++_presetSelectionGen;
    final prev = state.activePresetId;
    state = state.copyWith(activePresetId: presetId);
    try {
      await client.selectPreset({
        'agentPreset': presetId,
        'preset': presetId,
        'id': presetId,
        if (state.activeSessionId != null && !state.activeSessionId!.startsWith('pending-session-'))
          'sessionId': state.activeSessionId,
      });
      if (!_isStillLive(client) || myPresetGen != _presetSelectionGen) return;
      await patchDshNamespace('agent-preset-registry', {'selectedDefault': presetId}, silent: true, clientOverride: client);
      if (_isStillLive(client) && myPresetGen == _presetSelectionGen) {
        showToast('已切换预设：${preset.name}');
      }
    } catch (e) {
      if (!_isStillLive(client) || myPresetGen != _presetSelectionGen) return;
      state = state.copyWith(activePresetId: prev);
      showError('切换角色预设失败', error: e);
    }
  }

  void _syncNativeChatPermissionPreset(String permId) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    unawaited(GrassBagNativeBridge.instance.setSafetyChatPermissionPreset(permId));
  }

  Future<void> setPermission(String permId) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机后再修改权限策略', tone: ToastTone.warn);
      return;
    }
    final perm = state.effectivePermissionTiers.firstWhere(
      (p) => p.id == permId,
      orElse: () => PermissionTier(id: permId, name: permId, desc: ''),
    );
    final myPermGen = ++_permissionSelectionGen;
    final prev = state.activePermissionId;
    state = state.copyWith(activePermissionId: permId);
    final err = await patchDshNamespace('permission', {'defaultPreset': permId}, silent: true, clientOverride: client);
    if (!_isStillLive(client) || myPermGen != _permissionSelectionGen) return;
    if (err != null) {
      state = state.copyWith(activePermissionId: prev);
      _syncNativeChatPermissionPreset(prev);
      return;
    }
    final sid = state.activeSessionId;
    if (sid != null && !sid.startsWith('pending-session-')) {
      try {
        await client.setSessionPermission(sid, permId);
        if (!_isStillLive(client) || myPermGen != _permissionSelectionGen) return;
      } catch (e) {
        if (_isStillLive(client) && myPermGen == _permissionSelectionGen) {
          state = state.copyWith(activePermissionId: prev);
          _syncNativeChatPermissionPreset(prev);
          showError('同步当前会话权限失败', error: e);
        }
        return;
      }
    }
    if (_isStillLive(client) && myPermGen == _permissionSelectionGen) {
      _syncNativeChatPermissionPreset(permId);
      showToast('操作权限：${perm.name}', tone: perm.risky ? ToastTone.warn : ToastTone.ok);
    }
  }

  Future<bool> setPlanMode(bool enabled) async {
    final client = _liveClient;
    final prev = state.planMode;
    state = state.copyWith(planMode: enabled);
    final sid = state.activeSessionId;
    if (client != null && sid != null && !sid.startsWith('pending-session-')) {
      try {
        await client.executeSlashCommand(
          sid,
          command: enabled ? '/plan on' : '/plan off',
        );
        if (!_isStillLive(client)) return false;
      } catch (e) {
        if (!_isStillLive(client)) return false;
        state = state.copyWith(planMode: prev);
        showError('切换计划模式失败', error: e);
        return false;
      }
    }
    showToast(enabled ? '已开启计划模式' : '已关闭计划模式', tone: ToastTone.info);
    return true;
  }

  ModelCatalogEntry? _findModelEntry(String providerId, String modelId) {
    for (final g in state.modelGroups) {
      if (providerId.isNotEmpty && g.id != providerId) continue;
      for (final m in g.models) {
        if (m.id == modelId) return m;
      }
    }
    if (providerId.isNotEmpty) {
      for (final g in state.modelGroups) {
        for (final m in g.models) {
          if (m.id == modelId) return m;
        }
      }
    }
    return null;
  }

  static bool _isRevisionConflictError(Object err) {
    if (err is GbridgeException && err.status == 409) {
      final code = err.code.toLowerCase();
      if (code.contains('conflict')) return true;
      final d = err.details;
      if (d is Map) {
        final up = d['upstreamCode']?.toString().toLowerCase() ?? '';
        if (up.contains('settings/conflict') || up.contains('settings_conflict')) {
          return true;
        }
      }
    }
    final lower = err.toString().toLowerCase();
    return lower.contains('settings/conflict') ||
        lower.contains('settings_conflict') ||
        lower.contains('changed since it was read') ||
        lower.contains('expected revision') ||
        lower.contains('revision conflict');
  }

  static int? _extractActualRevisionFromConflict(Object err) {
    if (err is GbridgeException && err.details is Map) {
      final d = err.details as Map;
      final direct = d['actual'];
      if (direct is num) return direct.toInt();
      final up = d['upstreamDetails'];
      if (up is Map && up['actual'] is num) {
        return (up['actual'] as num).toInt();
      }
    }
    final m = RegExp(r'expected revision\s+\d+,\s*now\s+(\d+)', caseSensitive: false)
        .firstMatch(err.toString());
    if (m != null) return int.tryParse(m.group(1) ?? '');
    return null;
  }

  Future<T> _serializeNamespaceWrite<T>(
    String queueKey,
    Future<T> Function() action,
  ) {
    final prev = _nsWriteTails[queueKey] ?? Future<void>.value();
    final completer = Completer<void>();
    final nextTail = prev.catchError((_) {}).whenComplete(() => completer.future);
    _nsWriteTails[queueKey] = nextTail;

    return prev.catchError((_) {}).then((_) async {
      try {
        return await action();
      } finally {
        if (!completer.isCompleted) completer.complete();
        if (identical(_nsWriteTails[queueKey], nextTail)) {
          _nsWriteTails.remove(queueKey);
        }
      }
    });
  }

  Future<int?> _fetchFreshNamespaceRevision(
    GbridgeClient client,
    String ns, {
    bool forceFresh = true,
  }) async {
    try {
      final schemaResp = await client.getSettingsSchema(forceFresh: forceFresh);
      if (!_isStillLive(client)) return null;
      final desc = schemaResp['description'];
      if (desc is Map<String, dynamic>) {
        final parsed = parseDshSettingsNamespaces(desc);
        if (parsed.isNotEmpty) {
          state = state.copyWith(dshNamespaces: parsed);
          final matched = parsed.where((e) => e.ns == ns).firstOrNull;
          if (matched != null && matched.revision >= 0) return matched.revision;
        }
      }
    } catch (_) {}
    return null;
  }

  void _updateCachedDefaultModelNamespace({
    required String provider,
    required String modelId,
    required String effortId,
  }) {
    final currentList = List<DshSettingsNamespace>.of(state.dshNamespaces);
    final idx = currentList.indexWhere((e) => e.ns == 'agent-default-model');
    if (idx < 0) return;
    final nextVal = Map<String, dynamic>.from(currentList[idx].value);
    if (provider.isNotEmpty) nextVal['provider'] = provider;
    nextVal['model'] = modelId;
    if (effortId.isNotEmpty) {
      nextVal['reasoningEffort'] = effortId;
    } else {
      nextVal.remove('reasoningEffort');
    }
    // Keep server-authoritative revision untouched; DSH only bumps revision when raw
    // profile config actually changes, and the follow-up fresh schema sync updates it.
    currentList[idx] = currentList[idx].copyWith(value: nextVal);
    state = state.copyWith(dshNamespaces: currentList);
  }

  Future<void> _persistDefaultModelQuietly(
    GbridgeClient client, {
    required String provider,
    required String modelId,
    required String effortId,
  }) async {
    if (!_isStillLive(client) || modelId.isEmpty) return;
    final ops = <Map<String, dynamic>>[
      if (provider.isNotEmpty) {'op': 'set', 'path': ['provider'], 'value': provider},
      {'op': 'set', 'path': ['model'], 'value': modelId},
      if (effortId.isNotEmpty)
        {'op': 'set', 'path': ['reasoningEffort'], 'value': effortId}
      else
        {'op': 'unset', 'path': ['reasoningEffort']},
    ];
    await mutateDshNamespace(
      'agent-default-model',
      ops,
      silent: true,
      skipHydrate: true,
      suppressErrorToast: true,
      clientOverride: client,
    );
  }

  Future<void> setModel(
    String name,
    String short, {
    String? provider,
    String? modelId,
    String? effort,
    String? effortId,
    bool silent = false,
  }) async {
    final client = _liveClient;
    if (client == null) {
      if (!silent) showToast('请先连接到运行中的 DSH 主机后再切换模型', tone: ToastTone.warn);
      return;
    }
    var nextProvider = (provider ?? state.activeModelProvider).trim();
    var nextModelId = (modelId ?? state.activeModelId).trim();
    var resolvedName = name;
    var resolvedShort = short;
    if (nextModelId.isEmpty) {
      final fallback = state.firstAvailableModel;
      if (fallback != null) {
        nextProvider = fallback.providerId;
        nextModelId = fallback.id;
        resolvedName = fallback.name;
        resolvedShort = fallback.shortLabel;
      } else {
        if (!silent) showToast('请先在模型配置中添加并选择一个可用模型', tone: ToastTone.warn);
        return;
      }
    }

    final targetEntry = _findModelEntry(nextProvider, nextModelId);
    if (nextProvider.isEmpty && targetEntry != null) {
      nextProvider = targetEntry.providerId;
    }
    if (resolvedName.trim().isEmpty && targetEntry != null) {
      resolvedName = targetEntry.name;
    }
    if (resolvedShort.trim().isEmpty && targetEntry != null) {
      resolvedShort = targetEntry.shortLabel;
    }
    final supportsReasoning = targetEntry != null && targetEntry.efforts.isNotEmpty;
    String nextEffortId = '';
    String nextEffortLabel = '';
    if (supportsReasoning) {
      final candidate = (effortId != null && effortId.trim().isNotEmpty)
          ? effortId.trim()
          : (effort != null && effort.trim().isNotEmpty
              ? _effortLabelToId(effort)
              : (state.modelEffortId.isNotEmpty ? state.modelEffortId : targetEntry.defaultEffort));
      final matchedOpt = targetEntry.efforts
          .where((e) => e.id.toLowerCase() == candidate.toLowerCase())
          .firstOrNull;
      if (matchedOpt != null) {
        nextEffortId = matchedOpt.id;
        nextEffortLabel = matchedOpt.zhLabel;
      } else {
        final defOpt = targetEntry.efforts
            .where((e) => e.id.toLowerCase() == targetEntry.defaultEffort.toLowerCase())
            .firstOrNull;
        final fallback = defOpt ?? targetEntry.efforts.first;
        nextEffortId = fallback.id;
        nextEffortLabel = fallback.zhLabel;
      }
    }

    final myGen = ++_modelSelectionGen;
    final prevProvider = state.activeModelProvider;
    final prevModelId = state.activeModelId;
    final prevModelName = state.modelName;
    final prevModelShort = state.modelShort;
    final prevEffort = state.modelEffort;
    final prevEffortId = state.modelEffortId;

    state = state.copyWith(
      activeModelProvider: nextProvider,
      activeModelId: nextModelId,
      modelName: resolvedName,
      modelShort: resolvedShort,
      modelEffort: nextEffortLabel,
      modelEffortId: nextEffortId,
    );
    final selectionPayload = <String, dynamic>{
      if (nextProvider.isNotEmpty) 'provider': nextProvider,
      'model': nextModelId,
      if (nextEffortId.isNotEmpty) 'reasoningEffort': nextEffortId,
    };
    _inFlightModelSelections++;
    try {
      final sid = state.activeSessionId;
      if (sid != null && !sid.startsWith('pending-session-')) {
        // DSH `session/selectModel` atomically updates both the live session and
        // `agentDefaultModel.saveSelection(...)` on the server. Do NOT fire a redundant
        // `settings/mutate` on `agent-default-model` immediately after, which would
        // collide with the bumped revision (`SettingsConflictError`)!
        await client.selectModel(sid, selectionPayload);
        if (!_isStillLive(client) || myGen != _modelSelectionGen) return;
        _updateCachedDefaultModelNamespace(
          provider: nextProvider,
          modelId: nextModelId,
          effortId: nextEffortId,
        );
        // Refresh cached namespace revision quietly after DSH's async saveSelection settles.
        Future<void>.delayed(const Duration(milliseconds: 350), () {
          if (mounted && identical(_liveClient, client) && myGen == _modelSelectionGen) {
            unawaited(_fetchFreshNamespaceRevision(client, 'agent-default-model', forceFresh: true));
          }
        });
      } else {
        final ops = <Map<String, dynamic>>[
          if (nextProvider.isNotEmpty) {'op': 'set', 'path': ['provider'], 'value': nextProvider},
          {'op': 'set', 'path': ['model'], 'value': nextModelId},
          if (nextEffortId.isNotEmpty)
            {'op': 'set', 'path': ['reasoningEffort'], 'value': nextEffortId}
          else
            {'op': 'unset', 'path': ['reasoningEffort']},
        ];
        final err = await mutateDshNamespace(
          'agent-default-model',
          ops,
          silent: true,
          skipHydrate: true,
          clientOverride: client,
          shouldProceed: () => myGen == _modelSelectionGen,
        );
        if (!_isStillLive(client) || myGen != _modelSelectionGen) return;
        if (err != null) {
          state = state.copyWith(
            activeModelProvider: prevProvider,
            activeModelId: prevModelId,
            modelName: prevModelName,
            modelShort: prevModelShort,
            modelEffort: prevEffort,
            modelEffortId: prevEffortId,
          );
          return;
        }
      }
      // Re-assert user's confirmed choice in case any background hydrate finished during await.
      if (state.activeModelId != nextModelId ||
          state.activeModelProvider != nextProvider ||
          state.modelEffortId != nextEffortId) {
        state = state.copyWith(
          activeModelProvider: nextProvider,
          activeModelId: nextModelId,
          modelName: resolvedName,
          modelShort: resolvedShort,
          modelEffort: nextEffortLabel,
          modelEffortId: nextEffortId,
        );
      }
      _lastAutoSyncedDefaultKey = '${state.activeHostId}|$nextProvider|$nextModelId|$nextEffortId';
      if (!silent) {
        showToast(
          nextEffortLabel.isNotEmpty ? '已切换到 $resolvedName · 思考$nextEffortLabel' : '已切换到 $resolvedName',
        );
      }
    } catch (e) {
      if (!_isStillLive(client) || myGen != _modelSelectionGen) return;
      state = state.copyWith(
        activeModelProvider: prevProvider,
        activeModelId: prevModelId,
        modelName: prevModelName,
        modelShort: prevModelShort,
        modelEffort: prevEffort,
        modelEffortId: prevEffortId,
      );
      showError('切换模型失败', error: e);
    } finally {
      _inFlightModelSelections = (_inFlightModelSelections - 1).clamp(0, 9999);
    }
  }

  static String _effortIdToZhLabel(String id) {
    final clean = id.trim().toLowerCase();
    if (clean.isEmpty) return '';
    return switch (clean) {
      'auto' => '自动',
      'minimal' => '极速',
      'off' || 'none' => '关闭',
      'low' => '低',
      'medium' || 'mid' => '中',
      'high' => '高',
      'xhigh' || 'very_high' || 'very-high' => '超高',
      'max' => '极高',
      _ => id,
    };
  }

  static String _effortLabelToId(String label) {
    final clean = label.trim().toLowerCase();
    if (clean.isEmpty) return '';
    return switch (clean) {
      '自动' || 'auto' => 'auto',
      '极速' || 'minimal' => 'minimal',
      '关闭' || 'off' || 'none' => 'off',
      '低' || 'low' => 'low',
      '中' || 'medium' || 'mid' => 'medium',
      '高' || 'high' => 'high',
      '超高' || 'xhigh' || 'very_high' || 'very-high' => 'xhigh',
      '极高' || 'max' => 'max',
      _ => clean,
    };
  }

  Future<void> compactContext({String? focus}) async {
    final client = _liveClient;
    final sid = state.activeSessionId;
    if (client == null || sid == null || sid.startsWith('pending-session-')) {
      showToast('当前对话尚未开始或未连接主机', tone: ToastTone.warn);
      return;
    }
    if (state.isStreaming) {
      showToast('正在生成回复，请等待本轮完成后再精简上下文', tone: ToastTone.warn);
      return;
    }
    if (_compactingContext) return;
    _compactingContext = true;
    state = state.copyWith(isCompactingContext: true);
    final beforePct = state.contextPct;
    showToast('正在精简上下文…', tone: ToastTone.info);
    try {
      final cmd = (focus != null && focus.trim().isNotEmpty)
          ? '/compact ${focus.trim()}'
          : '/compact';
      final resp = await client.executeSlashCommand(sid, command: cmd);
      if (!_isStillLive(client) || state.activeSessionId != sid) return;
      if (resp['ok'] == false) {
        final msg = (resp['text'] ?? resp['error'] ?? '主机未能执行上下文精简').toString().trim();
        showError('精简上下文失败', error: msg);
        return;
      }
      // Wait for any stale in-flight sync to settle, then force a fresh post-compaction sync!
      final inflight = _inFlightBundleSyncs[sid];
      if (inflight != null) {
        await inflight;
      }
      if (!_isStillLive(client) || state.activeSessionId != sid) return;
      await _syncLiveSessionBundle(sid, jumpToBottomOnLoad: false, authoritativeSync: true);
      if (!_isStillLive(client) || state.activeSessionId != sid) return;
      final afterPct = state.contextPct;
      if (beforePct > 0 && afterPct < beforePct) {
        showToast('上下文已精简：$beforePct% → $afterPct%');
      } else {
        showToast('上下文精简已完成（当前占用 $afterPct%）');
      }
    } catch (e) {
      if (!_isStillLive(client)) return;
      showError('精简上下文失败', error: e);
    } finally {
      _compactingContext = false;
      if (mounted && state.isCompactingContext) {
        state = state.copyWith(isCompactingContext: false);
      }
    }
  }

  void toggleTodo(String id) {
    state = state.copyWith(
      todos: [
        for (final t in state.todos) t.id == id ? t.copyWith(done: !t.done, active: false) : t,
      ],
    );
  }

  void addTodo(String title) {
    final clean = title.trim();
    if (clean.isEmpty) return;
    state = state.copyWith(
      todos: [
        ...state.todos,
        SessionTodoRecord(
          id: 'td-${DateTime.now().millisecondsSinceEpoch}',
          title: clean,
          done: false,
        ),
      ],
    );
    showToast('已添加待办项');
  }

  Future<void> _refreshSessionGoalsOnly(String sessionId) async {
    final client = _liveClient;
    if (client == null || state.activeSessionId != sessionId) return;
    try {
      final resp = await client.getSessionGoals(sessionId);
      if (!mounted || !identical(_liveClient, client) || state.activeSessionId != sessionId) return;
      state = state.copyWith(goals: _parseGoalsResponse(resp));
    } catch (_) {}
  }

  Future<String?> addGoal(String title, String criteria) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) return '请输入目标名称';
    final cleanCriteria = criteria.trim().isEmpty ? '持续执行直至全部验收标准达成' : criteria.trim();
    final client = _liveClient;
    final sid = state.activeSessionId;
    if (client != null && sid != null && !sid.startsWith('pending-session-')) {
      try {
        await client.mutateSessionGoal(
          sid,
          action: 'create',
          payload: {
            'objective': cleanTitle,
            'title': cleanTitle,
            'criteria': cleanCriteria,
          },
        );
        if (!_isStillLive(client)) return null;
        await _refreshSessionGoalsOnly(sid);
        if (!_isStillLive(client)) return null;
        showToast('已设定长期目标：$cleanTitle');
        return null;
      } catch (e) {
        if (!_isStillLive(client)) return null;
        showError('设定长期目标失败', error: e);
        return formatReadableError(e);
      }
    }
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机后再设定长期目标', tone: ToastTone.warn);
      return '请先连接到运行中的 DSH 主机';
    }
    final goal = SessionGoalRecord(
      id: 'goal-${DateTime.now().millisecondsSinceEpoch}',
      title: cleanTitle,
      criteria: cleanCriteria,
      status: 'active',
    );
    state = state.copyWith(goals: [goal, ...state.goals]);
    showToast('已暂存长期目标（发送首条消息后同步至 DSH）');
    return null;
  }

  Future<String?> editGoal(String id, String title, String criteria) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) return '请输入目标名称';
    final cleanCriteria = criteria.trim();
    final client = _liveClient;
    final target = state.goals.where((g) => g.id == id).firstOrNull;
    final prevGoals = state.goals;
    state = state.copyWith(
      goals: [
        for (final g in state.goals)
          g.id == id ? g.copyWith(title: cleanTitle, criteria: cleanCriteria) : g,
      ],
    );
    final sid = state.activeSessionId;
    if (client != null && sid != null && !sid.startsWith('pending-session-')) {
      try {
        await client.mutateSessionGoal(
          sid,
          action: 'edit',
          payload: {
            'objective': cleanCriteria.isNotEmpty ? '$cleanTitle\n验收标准：$cleanCriteria' : cleanTitle,
            if (target != null && target.revision > 0)
              'ref': {'id': target.id, 'revision': target.revision},
          },
        );
        if (!_isStillLive(client)) return null;
        await _refreshSessionGoalsOnly(sid);
        if (!_isStillLive(client)) return null;
        showToast('已更新长期目标');
        return null;
      } catch (e) {
        if (!_isStillLive(client)) return null;
        if (state.activeSessionId == sid) {
          state = state.copyWith(goals: prevGoals);
        }
        showError('编辑长期目标失败', error: e);
        return formatReadableError(e);
      }
    }
    return null;
  }

  Future<void> updateGoalStatus(String id, String status) async {
    final client = _liveClient;
    final target = state.goals.where((g) => g.id == id).firstOrNull;
    final prevGoals = state.goals;
    state = state.copyWith(
      goals: [
        for (final g in state.goals)
          g.id == id
              ? g.copyWith(status: status, progressPct: status == 'completed' ? 100 : g.progressPct)
              : g,
      ],
    );
    final sid = state.activeSessionId;
    if (client != null && sid != null && !sid.startsWith('pending-session-')) {
      final act = status == 'paused' ? 'pause' : (status == 'completed' ? 'complete' : 'resume');
      try {
        await client.mutateSessionGoal(
          sid,
          action: act,
          payload: {
            'goalId': id,
            if (target != null && target.revision > 0)
              'ref': {'id': target.id, 'revision': target.revision},
          },
        );
        if (!_isStillLive(client)) return;
        await _refreshSessionGoalsOnly(sid);
      } catch (e) {
        if (!_isStillLive(client)) return;
        if (state.activeSessionId == sid) {
          state = state.copyWith(goals: prevGoals);
        }
        showError('更新目标状态失败', error: e);
      }
    }
  }

  Future<void> deleteGoal(String id) async {
    final client = _liveClient;
    final target = state.goals.where((g) => g.id == id).firstOrNull;
    final prevGoals = state.goals;
    state = state.copyWith(goals: state.goals.where((g) => g.id != id).toList(growable: false));
    final sid = state.activeSessionId;
    if (client != null && sid != null && !sid.startsWith('pending-session-')) {
      try {
        await client.mutateSessionGoal(
          sid,
          action: 'clear',
          payload: {
            if (target != null && target.revision > 0)
              'ref': {'id': target.id, 'revision': target.revision},
          },
        );
        if (!_isStillLive(client)) return;
        await _refreshSessionGoalsOnly(sid);
        if (!_isStillLive(client)) return;
        showToast('已清除长期目标', tone: ToastTone.info);
      } catch (e) {
        if (!_isStillLive(client)) return;
        if (state.activeSessionId == sid) {
          state = state.copyWith(goals: prevGoals);
        }
        showError('清除长期目标失败', error: e);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Schedules, Background Jobs, Subagents, Plugins, Dynamic Cordis & SDUI
  // ---------------------------------------------------------------------------
  Future<String?> createSchedule({
    required String name,
    required String cronExpr,
    required String humanSchedule,
    required String prompt,
    String timezone = 'Asia/Shanghai',
  }) async {
    final cleanName = name.trim();
    final cleanCron = cronExpr.trim();
    final cleanPrompt = prompt.trim();
    if (cleanName.isEmpty || cleanCron.isEmpty || cleanPrompt.isEmpty) {
      return '请完整填写任务名称、Cron 表达式和执行指令';
    }
    final client = _liveClient;
    if (client == null) {
      const msg = '请先连接到运行中的 DSH 主机后再创建定时任务';
      showToast(msg, tone: ToastTone.warn);
      return msg;
    }
    try {
      await client.createSchedule({
        'title': cleanName,
        'name': cleanName,
        'cronExpr': cleanCron,
        'timeZone': timezone,
        'prompt': cleanPrompt,
        if (state.activeWorkspaceItem?.path.isNotEmpty == true)
          'cwd': state.activeWorkspaceItem!.path,
      });
      if (!_isStillLive(client)) return null;
      await _refreshSchedulesOnly();
      if (!_isStillLive(client)) return null;
      showToast('已创建定时任务：$cleanName');
      return null;
    } catch (e) {
      if (!_isStillLive(client)) return _disconnectedSaveError;
      showError('创建定时任务失败', error: e);
      return '创建定时任务失败：$e';
    }
  }

  Future<String?> updateSchedule({
    required String id,
    required String name,
    String? cronExpr,
    required String prompt,
    String? timezone,
  }) async {
    final cleanName = name.trim();
    final cleanCron = cronExpr?.trim() ?? '';
    final cleanPrompt = prompt.trim();
    if (cleanName.isEmpty || cleanPrompt.isEmpty) {
      return '请完整填写任务名称和执行指令';
    }
    final client = _liveClient;
    if (client == null) {
      const msg = '请先连接到运行中的 DSH 主机后再修改定时任务';
      showToast(msg, tone: ToastTone.warn);
      return msg;
    }
    try {
      await client.patchSchedule(id, {
        'title': cleanName,
        'name': cleanName,
        if (cleanCron.isNotEmpty) 'cronExpr': cleanCron,
        'prompt': cleanPrompt,
        if (cleanCron.isNotEmpty && timezone != null && timezone.trim().isNotEmpty)
          'timeZone': timezone.trim(),
      });
      if (!_isStillLive(client)) return null;
      await _refreshSchedulesOnly();
      if (!_isStillLive(client)) return null;
      showToast('已更新定时任务：$cleanName');
      return null;
    } catch (e) {
      if (!_isStillLive(client)) return _disconnectedSaveError;
      showError('更新定时任务失败', error: e);
      return '更新定时任务失败：$e';
    }
  }

  Future<void> pruneInactiveSchedules() async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    try {
      await client.pruneInactiveSchedules();
      if (!_isStillLive(client)) return;
      await _refreshSchedulesOnly();
      if (!_isStillLive(client)) return;
      showToast('已清理全部已结束的定时任务', tone: ToastTone.ok);
    } catch (e) {
      if (!_isStillLive(client)) return;
      showError('清理已结束任务失败', error: e);
    }
  }

  Future<void> refreshSchedules({bool silent = false}) async {
    if (_liveClient == null) {
      if (!silent) showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    await _refreshSchedulesOnly();
    if (!silent && mounted) {
      showToast('已刷新定时任务（${state.schedules.length} 个）', tone: ToastTone.info);
    }
  }

  Future<void> _refreshSchedulesOnly() async {
    final client = _liveClient;
    if (client == null) return;
    try {
      final resp = await client.listSchedules();
      if (!mounted || !identical(_liveClient, client)) return;
      final raw = resp['schedules'];
      if (raw is List) {
        final prevHistoryById = {for (final s in state.schedules) s.id: s.history};
        final list = raw
            .whereType<Map<dynamic, dynamic>>()
            .map((e) {
              final rec = ScheduleTaskRecord.fromJson(Map<String, dynamic>.from(e));
              final cachedHist = prevHistoryById[rec.id];
              return rec.history.isEmpty && cachedHist != null && cachedHist.isNotEmpty
                  ? rec.copyWith(history: cachedHist)
                  : rec;
            })
            .toList(growable: false);
        state = state.copyWith(schedules: list);
      }
    } catch (_) {}
  }

  Future<void> loadScheduleHistory(String id) async {
    final client = _liveClient;
    if (client == null) return;
    try {
      final resp = await client.getScheduleHistory(id);
      if (!mounted || !identical(_liveClient, client)) return;
      final rawHist = resp['history'];
      final List<dynamic> rawEntries;
      if (rawHist is List) {
        rawEntries = rawHist;
      } else if (rawHist is Map) {
        final candidate = rawHist['deliveries'] ?? rawHist['entries'] ?? rawHist['items'] ?? rawHist['records'];
        rawEntries = candidate is List ? candidate : const [];
      } else {
        rawEntries = const [];
      }
      final lines = <String>[];
      for (final entry in rawEntries) {
        if (entry is String) {
          lines.add(entry);
        } else if (entry is Map) {
          final ts = (entry['deliveredAt'] ?? entry['scheduledAt'] ?? entry['createdAt'] ?? '').toString();
          String shortTs = '未知时间';
          if (ts.isNotEmpty) {
            final dt = DateTime.tryParse(ts);
            if (dt != null) {
              final loc = dt.toLocal();
              String p2(int n) => n.toString().padLeft(2, '0');
              shortTs = '${loc.year}-${p2(loc.month)}-${p2(loc.day)} ${p2(loc.hour)}:${p2(loc.minute)}';
            } else {
              shortTs = ts.replaceFirst('T', ' ').split('.').first;
            }
          }
          final outcome = (entry['outcome'] ?? entry['status'] ?? '已投递').toString();
          final targetSid = (entry['targetSessionId'] ?? entry['sessionId'] ?? '').toString();
          lines.add(targetSid.isNotEmpty ? '$shortTs · $outcome · 会话 ${targetSid.length > 12 ? targetSid.substring(0, 12) : targetSid}' : '$shortTs · $outcome');
        }
      }
      state = state.copyWith(
        schedules: [
          for (final s in state.schedules) s.id == id ? s.copyWith(history: lines) : s,
        ],
      );
    } catch (_) {}
  }

  Future<void> toggleSchedule(String id) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    final target = state.schedules.where((s) => s.id == id).firstOrNull;
    if (target == null) return;
    final next = !target.enabled;
    final prev = state.schedules;
    state = state.copyWith(
      schedules: [for (final s in state.schedules) s.id == id ? s.copyWith(enabled: next) : s],
    );
    try {
      await client.patchSchedule(id, {'active': next, 'enabled': next});
      if (!_isStillLive(client)) return;
      await _refreshSchedulesOnly();
      if (!_isStillLive(client)) return;
      showToast('${target.name}已${next ? '开启' : '暂停'}', tone: ToastTone.info);
    } catch (e) {
      if (!_isStillLive(client)) return;
      state = state.copyWith(schedules: prev);
      showError('更新定时任务状态失败', error: e);
    }
  }

  Future<void> runScheduleNow(String id) async {
    final client = _liveClient;
    final target = state.schedules.where((s) => s.id == id).firstOrNull;
    if (target == null) return;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    showToast('正在触发定时任务「${target.name}」…', tone: ToastTone.info);
    try {
      await client.runScheduleNow(id);
      if (!_isStillLive(client)) return;
      await _refreshSchedulesOnly();
      if (!_isStillLive(client)) return;
      await loadScheduleHistory(id);
      if (!_isStillLive(client)) return;
      showToast('已触发定时任务：${target.name}');
    } catch (e) {
      if (!_isStillLive(client)) return;
      showError('触发定时任务失败', error: e);
    }
  }

  Future<void> deleteSchedule(String id) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    final prev = state.schedules;
    state = state.copyWith(
      schedules: state.schedules.where((s) => s.id != id).toList(growable: false),
    );
    try {
      await client.deleteSchedule(id);
      if (_isStillLive(client)) showToast('已删除定时任务', tone: ToastTone.info);
    } catch (e) {
      if (!_isStillLive(client)) return;
      state = state.copyWith(schedules: prev);
      showError('删除定时任务失败', error: e);
    }
  }

  void subscribeJobStream(String jobId, {String? sessionId}) {
    final client = _liveClient;
    if (client == null) return;
    final sid = sessionId ?? state.activeSessionId ?? '';
    final ch = sid.isNotEmpty ? 'job:$sid:$jobId' : 'job:$jobId';
    client.stream.subscribe(ch);
  }

  void unsubscribeJobStream(String jobId, {String? sessionId}) {
    final client = _liveClient;
    if (client == null) return;
    final sid = sessionId ?? state.activeSessionId ?? '';
    final ch = sid.isNotEmpty ? 'job:$sid:$jobId' : 'job:$jobId';
    client.stream.unsubscribe(ch);
  }

  Future<void> refreshJobs({bool silent = false}) async {
    final client = _liveClient;
    if (client == null) {
      if (!silent) showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    try {
      final resp = await client.listJobs(sessionId: state.activeSessionId);
      if (!mounted || !identical(_liveClient, client)) return;
      final parsed = _parseJobsResponse(resp, fallbackSessionId: state.activeSessionId);
      state = state.copyWith(jobs: parsed);
      if (!silent) {
        showToast(parsed.isEmpty ? '当前暂无运行中的后台任务' : '已刷新后台任务（${parsed.length} 个）', tone: ToastTone.info);
      }
    } catch (e) {
      if (!mounted || !identical(_liveClient, client)) return;
      if (!silent) showError('刷新后台任务失败', error: e);
    }
  }

  Future<void> killJob(String jobId) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    final target = state.jobs.where((j) => j.id == jobId).firstOrNull;
    final prev = state.jobs;
    state = state.copyWith(
      jobs: [
        for (final j in state.jobs)
          j.id == jobId
              ? j.copyWith(
                  status: 'killed',
                  outputLines: [...j.outputLines, '[GrassBag] 已发送终止请求'],
                )
              : j,
      ],
    );
    try {
      await client.killJob(
        jobId,
        sessionId: target?.sessionId ?? state.activeSessionId,
      );
      if (!_isStillLive(client)) return;
      await refreshJobs(silent: true);
      if (_isStillLive(client)) showToast('已终止后台任务', tone: ToastTone.warn);
    } catch (e) {
      if (!_isStillLive(client)) return;
      state = state.copyWith(jobs: prev);
      showError('终止后台任务失败', error: e);
    }
  }

  Future<String?> launchQuickJob(String command) async {
    final clean = command.trim();
    if (clean.isEmpty) return '请输入要在后台运行的命令';
    if (_liveClient == null) {
      const msg = '请先连接到运行中的 DSH 主机后再启动后台任务';
      showToast(msg, tone: ToastTone.warn);
      return msg;
    }
    if (!state.hasAvailableModels) {
      const msg = '请先在设置中配置可用模型后再启动后台任务';
      showToast(msg, tone: ToastTone.warn);
      return msg;
    }
    final ok = await sendPrompt(
      '请在后台启动并运行以下命令，并汇报任务状态：\n```bash\n$clean\n```',
      includePendingAttachments: false,
    );
    if (!mounted) return null;
    if (!ok) return '未能提交后台命令，请检查当前对话与主机连接状态';
    showToast('已通过当前对话委派后台命令，可返回对话查看或稍后刷新', tone: ToastTone.info);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted && _liveClient != null) {
        unawaited(refreshJobs(silent: true));
      }
    });
    return null;
  }

  Future<void> refreshSubagentsOnly({bool silent = false}) async {
    final client = _liveClient;
    final sid = state.activeSessionId;
    if (client == null || sid == null || sid.startsWith('pending-session-')) {
      if (!silent) {
        showToast(client == null ? '请先连接到运行中的 DSH 主机' : '请先进入一个对话会话', tone: ToastTone.warn);
      }
      return;
    }
    try {
      final page = await client.getSessionTurns(sid, limit: 1);
      if (!mounted || !identical(_liveClient, client) || state.activeSessionId != sid) return;
      final rawProj = page.projections;
      final projValues = rawProj?['values'] is Map<String, dynamic>
          ? rawProj!['values'] as Map<String, dynamic>
          : rawProj;
      final liveSubagents = <SubagentItem>[];
      if (projValues is Map<String, dynamic>) {
        final rawSubs = projValues['subagents'] ?? projValues['subagentCatalog'] ?? projValues['children'];
        if (rawSubs is List) {
          for (var i = 0; i < rawSubs.length; i++) {
            final item = rawSubs[i];
            if (item is! Map) continue;
            liveSubagents.add(
              SubagentItem(
                id: item['sessionId']?.toString() ?? item['id']?.toString() ?? 'sub-$i',
                name: item['name']?.toString() ?? item['title']?.toString() ?? '子代理 ${i + 1}',
                role: item['role']?.toString() ?? item['mode']?.toString() ?? item['agentPreset']?.toString() ?? 'subagent',
                status: item['status']?.toString() ?? (item['running'] == true ? 'running' : 'completed'),
                taskSummary: item['label']?.toString() ?? item['task']?.toString() ?? item['summary']?.toString() ?? '',
                model: item['model']?.toString() ?? state.modelName,
                durationLabel: item['durationLabel']?.toString() ??
                    (item['durationMs'] is num
                        ? '${((item['durationMs'] as num) / 1000).toStringAsFixed(1)}s'
                        : ''),
                outputPreview: item['outputPreview']?.toString() ?? '',
                worktreeBranch: item['worktreeBranch']?.toString() ?? item['branch']?.toString(),
              ),
            );
          }
        }
      }
      state = state.copyWith(subagents: liveSubagents);
      if (!silent) {
        showToast(
          liveSubagents.isEmpty ? '当前会话暂无活跃子代理' : '已刷新子代理状态（${liveSubagents.length} 个）',
          tone: ToastTone.info,
        );
      }
    } catch (e) {
      if (!silent && _isStillLive(client)) showError('刷新子代理状态失败', error: e);
    }
  }

  Future<bool> promptSubagent(String subagentId, String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return false;
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return false;
    }
    final prev = state.subagents;
    state = state.copyWith(
      subagents: [
        for (final s in state.subagents)
          s.id == subagentId ? s.copyWith(status: 'running') : s,
      ],
    );
    try {
      await client.promptSubagent(
        subagentId,
        text: clean,
        parentSessionId: state.activeSessionId,
      );
      if (!_isStillLive(client)) return false;
      showToast('已向子代理发送指令');
      return true;
    } catch (e) {
      if (!_isStillLive(client)) return false;
      state = state.copyWith(subagents: prev);
      showError('向子代理发送指令失败', error: e);
      return false;
    }
  }

  Future<void> interruptSubagent(String subagentId) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    final prev = state.subagents;
    state = state.copyWith(
      subagents: [
        for (final s in state.subagents)
          s.id == subagentId ? s.copyWith(status: 'interrupted') : s,
      ],
    );
    try {
      await client.interruptSubagent(
        subagentId,
        parentSessionId: state.activeSessionId,
      );
      if (!_isStillLive(client)) return;
      showToast('已中断该子代理任务', tone: ToastTone.warn);
    } catch (e) {
      if (!_isStillLive(client)) return;
      state = state.copyWith(subagents: prev);
      showError('中断子代理失败', error: e);
    }
  }

  List<PluginItem> _parsePluginBundlesResp(Map<String, dynamic> bundlesResp) {
    final rawBundles = bundlesResp['bundles'];
    final mappedPlugins = <PluginItem>[];
    if (rawBundles is List) {
      for (final b in rawBundles) {
        if (b is! Map) continue;
        final id = b['name']?.toString() ?? b['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final removable = b['removable'] != false &&
            b['core'] != true &&
            b['builtin'] != true &&
            b['readOnly'] != true;
        final optional = b['optional'] != false && b['required'] != true;
        final reason = b['readOnlyReason']?.toString() ??
            (!removable ? '核心内置插件不可卸载' : null);
        mappedPlugins.add(
          PluginItem(
            id: id,
            name: b['title']?.toString() ?? id.replaceFirst('@deepseek-ai/', ''),
            desc: b['description']?.toString() ?? 'DSH 插件包',
            version: b['version']?.toString() ?? '0.2.2',
            enabled: b['enabled'] != false,
            removable: removable,
            optional: optional,
            readOnlyReason: reason,
          ),
        );
      }
    }
    return mappedPlugins;
  }

  List<DynamicCordisEntry> _parseDynamicCordisResp(Map<String, dynamic> cordisResp) {
    final rawCordis = cordisResp['inventory'] ??
        cordisResp['plugins'] ??
        cordisResp['items'] ??
        cordisResp['entries'];
    final mapped = <DynamicCordisEntry>[];
    if (rawCordis is List) {
      for (final c in rawCordis) {
        if (c is! Map) continue;
        final pkgs = c['packages'];
        final firstPkg = (pkgs is List && pkgs.isNotEmpty && pkgs.first is Map)
            ? Map<String, dynamic>.from(pkgs.first as Map)
            : null;
        final id = (c['pluginId'] ?? c['id'] ?? firstPkg?['id'] ?? c['name'] ?? '').toString();
        if (id.isEmpty) continue;
        final activeRun = c['activeRun'] ?? firstPkg?['activeRun'];
        final latestRun = c['latestRun'] ?? firstPkg?['latestRun'];
        final runStatus = (activeRun is Map ? activeRun['status'] : null)?.toString() ??
            (latestRun is Map ? latestRun['status'] : null)?.toString() ??
            c['status']?.toString() ??
            ((activeRun != null || c['running'] == true) ? 'running' : 'stopped');
        mapped.add(
          DynamicCordisEntry(
            id: id,
            name: (c['name'] ?? firstPkg?['name'] ?? id).toString(),
            status: runStatus,
            description: (c['description'] ?? firstPkg?['description'] ?? '').toString(),
            agentId: (c['agentId'] ?? firstPkg?['agentId'])?.toString() ?? '',
          ),
        );
      }
    }
    return mapped;
  }

  Future<void> _refreshInstalledPluginsOnly() async {
    final client = _liveClient;
    if (client == null) return;
    try {
      final resp = await client.listPluginBundles();
      if (!mounted || !identical(_liveClient, client)) return;
      final parsed = _parsePluginBundlesResp(resp);
      state = state.copyWith(
        plugins: parsed,
        marketPlugins: [
          for (final m in state.marketPlugins)
            m.copyWith(installed: parsed.any((p) => p.id == m.name)),
        ],
      );
    } catch (_) {}
  }

  Future<void> _refreshDynamicCordisOnly() async {
    final client = _liveClient;
    if (client == null) return;
    try {
      final resp = await client.listDynamicCordis();
      if (!mounted || !identical(_liveClient, client)) return;
      state = state.copyWith(dynamicCordis: _parseDynamicCordisResp(resp));
    } catch (_) {}
  }

  Future<void> installMarketPlugin(String packageName) async {
    final client = _liveClient;
    final existsInMarket = state.marketPlugins.any((p) => p.name == packageName);
    final initialLog = '> 正在解析 $packageName 清单与依赖…';
    state = state.copyWith(
      marketPlugins: existsInMarket
          ? [
              for (final p in state.marketPlugins)
                p.name == packageName
                    ? p.copyWith(
                        installing: true,
                        installLogs: [initialLog],
                      )
                    : p,
            ]
          : [
              PluginMarketEntry(
                name: packageName,
                displayName: packageName,
                version: 'custom',
                desc: '自定义插件包安装源',
                author: '自定义源',
                installing: true,
                installLogs: [initialLog],
              ),
              ...state.marketPlugins,
            ],
    );
    if (client == null) {
      showError('当前未连接 DSH 主机，无法安装插件 $packageName');
      state = state.copyWith(
        marketPlugins: [
          for (final p in state.marketPlugins)
            p.name == packageName ? p.copyWith(installing: false) : p,
        ],
      );
      return;
    }
    String? appNote;
    try {
      final resp = await client.installPlugin({
        'spec': packageName,
        'options': {'enabled': true},
      });
      if (!_isStillLive(client)) return;
      final inner = resp['result'] is Map ? resp['result'] as Map : resp;
      final appState = inner['application']?.toString();
      if (appState != null && appState.isNotEmpty && appState != 'applied' && appState != 'live') {
        appNote = '（状态：$appState，可能需要重启主机生效）';
      }
    } catch (e) {
      if (!_isStillLive(client)) return;
      final errStr = formatReadableError(e);
      state = state.copyWith(
        marketPlugins: [
          for (final p in state.marketPlugins)
            p.name == packageName
                ? p.copyWith(
                    installing: false,
                    installLogs: [...p.installLogs, '> 安装失败：$errStr'],
                  )
                : p,
        ],
      );
      showError('安装插件 $packageName 失败', error: e);
      return;
    }
    if (!_isStillLive(client)) return;
    final target = state.marketPlugins.where((p) => p.name == packageName).firstOrNull;
    state = state.copyWith(
      marketPlugins: [
        for (final p in state.marketPlugins)
          p.name == packageName
              ? p.copyWith(
                  installing: false,
                  installed: true,
                  installLogs: [
                    ...p.installLogs,
                    '> 已下载并安装 $packageName${appNote ?? ''}',
                  ],
                )
              : p,
      ],
    );
    await _refreshInstalledPluginsOnly();
    if (!_isStillLive(client)) return;
    showToast('已安装 ${target?.displayName ?? packageName}${appNote ?? ''}');
  }

  Future<void> refreshPluginsAndCordis({bool silent = false}) async {
    final client = _liveClient;
    if (client == null) {
      if (!silent) showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    await Future.wait([
      _refreshInstalledPluginsOnly(),
      _refreshDynamicCordisOnly(),
    ]);
    if (!silent && _isStillLive(client)) {
      showToast('已刷新插件与动态模块状态', tone: ToastTone.info);
    }
  }

  Future<void> removePluginBundle(String id) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    final target = state.plugins.where((p) => p.id == id).firstOrNull;
    if (target != null && !target.removable) {
      showToast(target.readOnlyReason ?? '该插件为核心内置组件，无法卸载', tone: ToastTone.warn);
      return;
    }
    final prevPlugins = state.plugins;
    final prevMarket = state.marketPlugins;
    state = state.copyWith(
      plugins: state.plugins.where((p) => p.id != id).toList(growable: false),
      marketPlugins: [
        for (final m in state.marketPlugins) m.name == id ? m.copyWith(installed: false) : m,
      ],
    );
    try {
      await client.removePluginBundle(id);
      if (!_isStillLive(client)) return;
      await _refreshInstalledPluginsOnly();
      if (_isStillLive(client)) showToast('已卸载插件', tone: ToastTone.info);
    } catch (e) {
      if (!_isStillLive(client)) return;
      state = state.copyWith(plugins: prevPlugins, marketPlugins: prevMarket);
      showError('卸载插件失败', error: e);
    }
  }

  Future<void> cordisAction(String id, String action) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    final target = state.dynamicCordis.where((c) => c.id == id).firstOrNull;
    final prev = state.dynamicCordis;
    if (action == 'undefine') {
      state = state.copyWith(
        dynamicCordis: state.dynamicCordis.where((c) => c.id != id).toList(growable: false),
      );
    } else if (action == 'stop') {
      state = state.copyWith(
        dynamicCordis: [
          for (final c in state.dynamicCordis)
            c.id == id ? c.copyWith(status: 'stopped') : c,
        ],
      );
    }
    try {
      await client.dynamicCordisAction(
        id,
        action,
        agentId: (target?.agentId ?? '').isNotEmpty ? target!.agentId : null,
      );
      if (!_isStillLive(client)) return;
      await _refreshDynamicCordisOnly();
      if (!_isStillLive(client)) return;
      showToast(
        action == 'undefine' ? '已卸载动态 Cordis 模块' : '已更新动态模块运行状态',
        tone: action == 'undefine' ? ToastTone.warn : ToastTone.info,
      );
    } catch (e) {
      if (!_isStillLive(client)) return;
      state = state.copyWith(dynamicCordis: prev);
      showError('执行动态模块操作失败', error: e);
    }
  }

  Future<String?> mutateDshNamespace(
    String ns,
    List<Map<String, dynamic>> ops, {
    bool silent = false,
    bool skipHydrate = false,
    bool suppressErrorToast = false,
    GbridgeClient? clientOverride,
    bool Function()? shouldProceed,
  }) async {
    final client = clientOverride ?? _liveClient;
    if (client == null || !identical(_liveClient, client)) {
      const msg = '请先连接到运行中的 DSH 主机后再修改 DSH 配置';
      if (!silent) showToast(msg, tone: ToastTone.warn);
      return msg;
    }
    if (ops.isEmpty) return null;
    final queueKey = '${state.activeHostId}:$ns';
    return _serializeNamespaceWrite<String?>(queueKey, () async {
      if (!_isStillLive(client)) return _disconnectedSaveError;
      if (shouldProceed != null && !shouldProceed()) return null;

      var currentList = List<DshSettingsNamespace>.of(state.dshNamespaces);
      var idx = currentList.indexWhere((e) => e.ns == ns);
      var existing = idx >= 0 ? currentList[idx] : null;
      final nextVal = Map<String, dynamic>.from(existing?.value ?? const <String, dynamic>{});
      var nextRev = (existing?.revision ?? 0) + 1;

      // DSH `settings/mutate` applies path-addressed edits against the live stored section
      // inside `configEditor.edit`; passing `expectedRevision = undefined` writes atomically
      // without spurious HTTP 409 conflicts when `session/selectModel` or another peer bumps
      // the namespace revision concurrently.
      Future<Map<String, dynamic>> sendMutate([int? expectedRev]) {
        final body = <String, dynamic>{
          'ns': ns,
          'ops': ops,
          if (expectedRev != null && expectedRev > 0) 'expectedRevision': expectedRev,
        };
        return client.patchSettings(body);
      }

      try {
        Map<String, dynamic>? res;
        int? retryExpectedRev;
        const maxAttempts = 4;
        for (var attempt = 0; attempt < maxAttempts; attempt++) {
          if (!_isStillLive(client)) return _disconnectedSaveError;
          if (shouldProceed != null && !shouldProceed()) return null;
          try {
            res = await sendMutate(retryExpectedRev);
            break;
          } catch (err) {
            if (!_isStillLive(client)) return _disconnectedSaveError;
            if (shouldProceed != null && !shouldProceed()) return null;
            if (!_isRevisionConflictError(err) || attempt == maxAttempts - 1) {
              rethrow;
            }
            // Refresh live revision (bypassing any read cache) and recover cleanly.
            final actualFromErr = _extractActualRevisionFromConflict(err);
            final freshRev = await _fetchFreshNamespaceRevision(client, ns, forceFresh: true);
            if (!_isStillLive(client)) return _disconnectedSaveError;
            if (shouldProceed != null && !shouldProceed()) return null;
            // On retry for path-addressed mutate, omit expectedRevision when possible so
            // back-to-back async saves (e.g. DSH `saveSelection`) cannot re-trigger 409;
            // keep the server's latest revision cached in state.
            retryExpectedRev = null;
            if (freshRev == null && actualFromErr != null) {
              final cur = List<DshSettingsNamespace>.of(state.dshNamespaces);
              final ci = cur.indexWhere((e) => e.ns == ns);
              if (ci >= 0) {
                cur[ci] = cur[ci].copyWith(revision: actualFromErr);
                state = state.copyWith(dshNamespaces: cur);
              }
            }
            if (attempt >= 1) {
              await Future<void>.delayed(Duration(milliseconds: 60 * attempt));
            }
          }
        }
        if (res == null || !_isStillLive(client)) return _disconnectedSaveError;
        final resultObj = res['result'];
        if (resultObj is Map && resultObj['revision'] is num) {
          nextRev = (resultObj['revision'] as num).toInt();
        }
        if (resultObj is Map && resultObj['value'] is Map) {
          nextVal
            ..clear()
            ..addAll(Map<String, dynamic>.from(resultObj['value'] as Map));
        }
      } catch (err) {
        if (!_isStillLive(client)) return _disconnectedSaveError;
        if (shouldProceed != null && !shouldProceed()) return null;
        final readable = formatReadableError(err);
        if (_isRevisionConflictError(err)) {
          unawaited(_hydrateLiveDomains(client));
        }
        if (!suppressErrorToast) {
          showError('写入 DSH 配置失败 ($ns)', error: err);
        }
        return readable;
      }

      if (!_isStillLive(client)) return null;
      currentList = List<DshSettingsNamespace>.of(state.dshNamespaces);
      idx = currentList.indexWhere((e) => e.ns == ns);
      if (idx >= 0) {
        currentList[idx] = currentList[idx].copyWith(value: nextVal, revision: nextRev);
      } else {
        final meta = kDshNamespaceMeta[ns];
        currentList.add(
          DshSettingsNamespace(
            ns: ns,
            title: meta?.$1 ?? ns,
            group: meta?.$2 ?? '模型与推理',
            subtitle: meta?.$3 ?? '',
            schema: const <String, dynamic>{},
            value: nextVal,
            revision: nextRev,
          ),
        );
      }
      var nextPreset = state.activePresetId;
      var nextPerm = state.activePermissionId;
      if (ns == 'agent-preset-registry' && nextVal['selectedDefault'] is String) {
        nextPreset = nextVal['selectedDefault'].toString();
      }
      if (ns == 'permission' && nextVal['defaultPreset'] is String) {
        nextPerm = nextVal['defaultPreset'].toString();
      }
      state = state.copyWith(
        dshNamespaces: currentList,
        activePresetId: nextPreset,
        activePermissionId: nextPerm,
      );
      if (ns == 'permission' && nextVal['defaultPreset'] is String) {
        _syncNativeChatPermissionPreset(nextPerm);
      }
      if (!skipHydrate &&
          (ns == 'mcp-manager' ||
              ns.startsWith('llm-') ||
              ns == 'agent-default-model' ||
              ns == 'agent-preset-registry' ||
              ns == 'permission')) {
        unawaited(_hydrateLiveDomains(client));
      }
      if (!silent) {
        showToast('已写入 DSH 配置：$ns');
      }
      return null;
    });
  }

  Future<String?> patchDshNamespace(
    String ns,
    Map<String, dynamic> patch, {
    bool replace = false,
    bool silent = false,
    bool skipHydrate = false,
    bool suppressErrorToast = false,
    GbridgeClient? clientOverride,
  }) async {
    final client = clientOverride ?? _liveClient;
    if (client == null || !identical(_liveClient, client)) {
      const msg = '请先连接到运行中的 DSH 主机后再修改 DSH 配置';
      if (!silent) showToast(msg, tone: ToastTone.warn);
      return msg;
    }
    final queueKey = '${state.activeHostId}:$ns';
    return _serializeNamespaceWrite<String?>(
      queueKey,
      () => _patchDshNamespaceLocked(
        client,
        ns,
        patch,
        replace: replace,
        silent: silent,
        skipHydrate: skipHydrate,
        suppressErrorToast: suppressErrorToast,
      ),
    );
  }

  Future<String?> _patchDshNamespaceLocked(
    GbridgeClient client,
    String ns,
    Map<String, dynamic> patch, {
    bool replace = false,
    bool silent = false,
    bool skipHydrate = false,
    bool suppressErrorToast = false,
    Map<String, dynamic> Function(Map<String, dynamic> freshSection)? mergeOnConflict,
  }) async {
      if (!_isStillLive(client)) return _disconnectedSaveError;
      var currentList = List<DshSettingsNamespace>.of(state.dshNamespaces);
      var idx = currentList.indexWhere((e) => e.ns == ns);
      final existing = idx >= 0 ? currentList[idx] : null;
      final nextVal = replace || existing == null
          ? Map<String, dynamic>.from(patch)
          : {...existing.value, ...patch};
      var nextRev = (existing?.revision ?? 0) + 1;

      // Frame-0 optimistic update for instant tactile switch/form responsiveness (rolled back on error).
      if (!replace && existing != null) {
        final optimisticList = List<DshSettingsNamespace>.of(state.dshNamespaces);
        final optIdx = optimisticList.indexWhere((e) => e.ns == ns);
        if (optIdx >= 0) {
          optimisticList[optIdx] = existing.copyWith(value: Map<String, dynamic>.from(nextVal));
          state = state.copyWith(dshNamespaces: optimisticList);
        }
      }

      Future<Map<String, dynamic>> sendPatch(int? expectedRev) {
        final body = <String, dynamic>{
          'ns': ns,
          if (replace) 'section': nextVal else 'patch': patch,
          if (expectedRev != null && expectedRev > 0) 'expectedRevision': expectedRev,
        };
        return client.patchSettings(body);
      }

      try {
        Map<String, dynamic>? res;
        // Partial `settings/update` merges only supplied keys into live stored state inside
        // DSH's lock, so omitting `expectedRevision` avoids spurious 409 conflicts.
        // Full `settings/replace` sends the cached revision and automatically recovers on 409
        // by re-applying the caller's delta onto the freshly fetched server section.
        int? expectedRev = replace ? existing?.revision : null;
        const maxAttempts = 4;
        for (var attempt = 0; attempt < maxAttempts; attempt++) {
          if (!_isStillLive(client)) return _disconnectedSaveError;
          try {
            res = await sendPatch(expectedRev);
            break;
          } catch (err) {
            if (!_isStillLive(client)) return _disconnectedSaveError;
            if (!_isRevisionConflictError(err) || attempt == maxAttempts - 1) {
              rethrow;
            }
            final actualFromErr = _extractActualRevisionFromConflict(err);
            final freshRev = await _fetchFreshNamespaceRevision(client, ns, forceFresh: true);
            if (!_isStillLive(client)) return _disconnectedSaveError;
            if (replace && mergeOnConflict != null) {
              final freshNs = state.dshNamespaces.where((e) => e.ns == ns).firstOrNull;
              if (freshNs != null) {
                final merged = mergeOnConflict(Map<String, dynamic>.from(freshNs.value));
                nextVal
                  ..clear()
                  ..addAll(merged);
              }
            }
            expectedRev = replace ? (freshRev ?? actualFromErr) : null;
            if (attempt >= 1) {
              await Future<void>.delayed(Duration(milliseconds: 60 * attempt));
            }
          }
        }
        if (res == null || !_isStillLive(client)) return _disconnectedSaveError;
        final resultObj = res['result'];
        if (resultObj is Map && resultObj['revision'] is num) {
          nextRev = (resultObj['revision'] as num).toInt();
        }
        if (resultObj is Map && resultObj['value'] is Map) {
          nextVal
            ..clear()
            ..addAll(Map<String, dynamic>.from(resultObj['value'] as Map));
        }
      } catch (err) {
        if (!_isStillLive(client)) return _disconnectedSaveError;
        // Roll back ONLY the failed `ns` entry so concurrent writes to sibling namespaces are preserved!
        if (!replace && existing != null) {
          final rolledBack = List<DshSettingsNamespace>.of(state.dshNamespaces);
          final rbIdx = rolledBack.indexWhere((e) => e.ns == ns);
          if (rbIdx >= 0) {
            rolledBack[rbIdx] = existing;
            state = state.copyWith(dshNamespaces: rolledBack);
          }
        }
        final readable = formatReadableError(err);
        if (_isRevisionConflictError(err)) {
          unawaited(_hydrateLiveDomains(client));
        }
        if (!suppressErrorToast) {
          showError('写入 DSH 配置失败 ($ns)', error: err);
        }
        return readable;
      }

      if (!_isStillLive(client)) return null;
      currentList = List<DshSettingsNamespace>.of(state.dshNamespaces);
      idx = currentList.indexWhere((e) => e.ns == ns);
      if (idx >= 0) {
        currentList[idx] = currentList[idx].copyWith(value: nextVal, revision: nextRev);
      } else {
        final meta = kDshNamespaceMeta[ns];
        currentList.add(
          DshSettingsNamespace(
            ns: ns,
            title: meta?.$1 ?? ns,
            group: meta?.$2 ?? '模型与推理',
            subtitle: meta?.$3 ?? '',
            schema: const <String, dynamic>{},
            value: nextVal,
            revision: nextRev,
          ),
        );
      }
      var nextPreset = state.activePresetId;
      var nextPerm = state.activePermissionId;
      if (ns == 'agent-preset-registry' && nextVal['selectedDefault'] is String) {
        nextPreset = nextVal['selectedDefault'].toString();
      }
      if (ns == 'permission' && nextVal['defaultPreset'] is String) {
        nextPerm = nextVal['defaultPreset'].toString();
      }
      state = state.copyWith(
        dshNamespaces: currentList,
        activePresetId: nextPreset,
        activePermissionId: nextPerm,
      );
      if (ns == 'permission' && nextVal['defaultPreset'] is String) {
        _syncNativeChatPermissionPreset(nextPerm);
      }
      if (!skipHydrate &&
          (ns == 'mcp-manager' ||
              ns.startsWith('llm-') ||
              ns == 'agent-default-model' ||
              ns == 'agent-preset-registry' ||
              ns == 'permission')) {
        unawaited(_hydrateLiveDomains(client));
      }
      if (!silent) {
        showToast('已写入 DSH 配置：$ns');
      }
      return null;
  }

  Future<void> refreshModelCatalog() async {
    final client = _liveClient;
    if (client == null) return;
    await _hydrateLiveDomains(client);
  }

  static String _normalizeProviderBaseUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Atomically save a provider's connection settings (`llm-pi-ai` / `llm-deepseek`),
  /// its custom model list (for `llm-pi-ai`), and its API key (`/credentials`), then
  /// immediately refresh the live DSH model catalog so changes appear everywhere at once.
  Future<String?> saveProviderConfig({
    required String providerId,
    required String settingsNs,
    required String displayName,
    required String apiProtocol,
    required String baseUrl,
    required String envRef,
    required String apiKeyValue,
    List<Map<String, dynamic>>? customModels,
    bool isCustomProvider = false,
  }) async {
    final client = _liveClient;
    if (client == null) {
      const msg = '当前未连接到 DSH 核心，无法保存模型渠道配置';
      showToast(msg, tone: ToastTone.warn);
      return msg;
    }
    final cleanId = providerId.trim();
    final cleanEnv = envRef.trim();
    final cleanSecret = apiKeyValue.trim();
    final cleanUrl = _normalizeProviderBaseUrl(baseUrl);
    final cleanName = displayName.trim().isEmpty ? cleanId : displayName.trim();
    final hadNoValidModel = state.activeModelEntry == null || !state.hasAvailableModels;

    if (cleanUrl.isNotEmpty) {
      final parsed = Uri.tryParse(cleanUrl);
      if (parsed == null || (parsed.scheme != 'http' && parsed.scheme != 'https') || parsed.host.isEmpty) {
        const msg = '接口地址格式无效，请以 http:// 或 https:// 开头';
        showToast(msg, tone: ToastTone.warn);
        return msg;
      }
    }

    // 1. Store secret directly in DSH encrypted credential vault (DSH is single source of truth!)
    if (cleanSecret.isNotEmpty && cleanEnv.isNotEmpty) {
      try {
        await client.setCredential({'ref': cleanEnv, 'value': cleanSecret});
        if (!_isStillLive(client)) return _disconnectedSaveError;
      } catch (e) {
        if (!_isStillLive(client)) return _disconnectedSaveError;
        final readable = formatReadableError(e);
        showError('保存密钥 $cleanEnv 失败', error: e);
        return readable;
      }
    }

    // 2. Patch provider settings in the right DSH namespace while preserving any advanced fields
    if (settingsNs == 'llm-deepseek') {
      final ops = <Map<String, dynamic>>[
        if (cleanUrl.isNotEmpty)
          {'op': 'set', 'path': ['baseURL'], 'value': cleanUrl}
        else
          {'op': 'unset', 'path': ['baseURL']},
        if (cleanEnv.isNotEmpty) {'op': 'set', 'path': ['apiKeyEnv'], 'value': cleanEnv},
      ];
      final err = await mutateDshNamespace('llm-deepseek', ops, silent: true, skipHydrate: true, clientOverride: client);
      if (err != null) return err;
      if (!_isStillLive(client)) return _disconnectedSaveError;
    } else if (settingsNs == 'llm-commandcode') {
      final ops = <Map<String, dynamic>>[
        if (cleanUrl.isNotEmpty)
          {'op': 'set', 'path': ['apiBase'], 'value': cleanUrl}
        else
          {'op': 'unset', 'path': ['apiBase']},
        if (cleanEnv.isNotEmpty) {'op': 'set', 'path': ['apiKeyEnv'], 'value': cleanEnv},
      ];
      final err = await mutateDshNamespace('llm-commandcode', ops, silent: true, skipHydrate: true, clientOverride: client);
      if (err != null) return err;
      if (!_isStillLive(client)) return _disconnectedSaveError;
    } else if (settingsNs == 'llm-pi-ai' && cleanId.isNotEmpty) {
      final queueKey = '${state.activeHostId}:llm-pi-ai';
      Map<String, dynamic> applyProviderDelta(Map<String, dynamic> baseSection) {
        final rootCopy = Map<String, dynamic>.from(baseSection);
        final rawProviders = rootCopy['providers'];
        final providersMap = rawProviders is Map
            ? Map<String, dynamic>.from(rawProviders)
            : <String, dynamic>{};
        final existingEntry = providersMap[cleanId] is Map
            ? Map<String, dynamic>.from(providersMap[cleanId] as Map)
            : <String, dynamic>{};

        existingEntry['displayName'] = cleanName;
        if (apiProtocol.trim().isNotEmpty) {
          existingEntry['api'] = apiProtocol.trim();
        }
        if (cleanUrl.isNotEmpty) {
          existingEntry['baseURL'] = cleanUrl;
        } else {
          existingEntry.remove('baseURL');
        }
        if (cleanEnv.isNotEmpty) {
          existingEntry['apiKeyEnv'] = cleanEnv;
        }
        if (customModels != null) {
          if (customModels.isNotEmpty) {
            existingEntry['models'] = customModels;
          } else {
            existingEntry.remove('models');
          }
        }
        providersMap[cleanId] = existingEntry;
        rootCopy['providers'] = providersMap;
        return rootCopy;
      }

      final err = await _serializeNamespaceWrite<String?>(queueKey, () async {
        if (!_isStillLive(client)) return _disconnectedSaveError;
        final ns = state.dshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
        final rootCopy = applyProviderDelta(ns?.value ?? const <String, dynamic>{});

        return _patchDshNamespaceLocked(
          client,
          'llm-pi-ai',
          rootCopy,
          replace: true,
          silent: true,
          skipHydrate: true,
          mergeOnConflict: applyProviderDelta,
        );
      });
      if (err != null) return err;
      if (!_isStillLive(client)) return _disconnectedSaveError;
    }

    // 3. Immediately refresh authoritative models, providers & credentials from DSH!
    await _hydrateLiveDomains(client, skipAutoDefaultSync: true);
    if (!_isStillLive(client)) return null;
    // 4. Auto-select the first available model when adding the first model/provider or
    //    when the active selection became invalid after removing models from this provider.
    final savedGroup = state.modelGroups
        .where((g) => g.id == cleanId && g.models.isNotEmpty)
        .firstOrNull;
    if (hadNoValidModel && savedGroup != null) {
      final first = savedGroup.models.first;
      await setModel(
        first.name,
        first.shortLabel,
        provider: savedGroup.id,
        modelId: first.id,
        effortId: first.defaultEffort,
        silent: true,
      );
    } else if (state.activeModelEntry == null && state.firstAvailableModel != null) {
      final fallback = state.firstAvailableModel!;
      await setModel(
        fallback.name,
        fallback.shortLabel,
        provider: fallback.providerId,
        modelId: fallback.id,
        effortId: fallback.defaultEffort,
        silent: true,
      );
    }
    if (_isStillLive(client)) {
      showToast('已写入 DSH 渠道「$cleanName」并同步可用模型');
    }
    return null;
  }

  /// Create or update a single model's parameter definition (`name`, `contextWindow`,
  /// `maxTokens`, `reasoning`, `input`) directly inside DSH `llm-pi-ai.providers[providerId].models`.
  Future<String?> saveModelParams({
    required String providerId,
    required String modelId,
    String? previousModelId,
    required String displayName,
    int? contextWindow,
    int? maxTokens,
    required bool reasoning,
    List<String>? reasoningEfforts,
    Map<String, String?>? reasoningEffortMap,
    required bool supportsImage,
    bool setAsDefault = false,
  }) async {
    final client = _liveClient;
    if (client == null) {
      const msg = '当前未连接到 DSH 核心，无法保存模型参数';
      showToast(msg, tone: ToastTone.warn);
      return msg;
    }
    final cleanProv = providerId.trim();
    final cleanId = modelId.trim();
    if (cleanProv.isEmpty || cleanId.isEmpty) {
      const msg = '渠道标识与模型 ID 不能为空';
      showToast(msg, tone: ToastTone.warn);
      return msg;
    }
    if (contextWindow != null &&
        contextWindow > 0 &&
        maxTokens != null &&
        maxTokens > 0 &&
        maxTokens > contextWindow) {
      const msg = '最大输出 Token 不能大于上下文窗口大小';
      showToast(msg, tone: ToastTone.warn);
      return msg;
    }
    final matchId = (previousModelId != null && previousModelId.trim().isNotEmpty)
        ? previousModelId.trim()
        : cleanId;
    final hadNoValidModel = state.activeModelEntry == null || !state.hasAvailableModels;
    final wasActiveModel = state.activeModelProvider == cleanProv && state.activeModelId == matchId;
    final resolvedDisplayName = displayName.trim().isEmpty ? cleanId : displayName.trim();

    final queueKey = '${state.activeHostId}:llm-pi-ai';
    final err = await _serializeNamespaceWrite<String?>(queueKey, () async {
      if (!_isStillLive(client)) return _disconnectedSaveError;
      final ns = state.dshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
      final rootCopy = Map<String, dynamic>.from(ns?.value ?? const <String, dynamic>{});
      final rawProviders = rootCopy['providers'];
      final providersMap = rawProviders is Map
          ? Map<String, dynamic>.from(rawProviders)
          : <String, dynamic>{};
      final entry = providersMap[cleanProv] is Map
          ? Map<String, dynamic>.from(providersMap[cleanProv] as Map)
          : <String, dynamic>{};
      final rawModels = entry['models'];
      final modelsList = <Map<String, dynamic>>[
        if (rawModels is List)
          for (final m in rawModels)
            if (m is Map) Map<String, dynamic>.from(m),
      ];

      final existingIdx = modelsList.indexWhere((m) => m['id']?.toString() == matchId);
      final duplicateIdx = modelsList.indexWhere((m) => m['id']?.toString() == cleanId);
      if (duplicateIdx >= 0 && duplicateIdx != existingIdx) {
        const dupMsg = '该渠道下已存在同名的模型 ID，请修改后再保存';
        showToast(dupMsg, tone: ToastTone.warn);
        return dupMsg;
      }

      final updatedModel = existingIdx >= 0
          ? Map<String, dynamic>.from(modelsList[existingIdx])
          : <String, dynamic>{};
      updatedModel['id'] = cleanId;
      updatedModel['name'] = resolvedDisplayName;
      if (contextWindow != null && contextWindow > 0) {
        updatedModel['contextWindow'] = contextWindow;
      } else {
        updatedModel.remove('contextWindow');
      }
      if (maxTokens != null && maxTokens > 0) {
        updatedModel['maxTokens'] = maxTokens;
      } else {
        updatedModel.remove('maxTokens');
      }
      // Conform strictly to DSH `llm-pi-ai` modelProfile schema:
      // `reasoningEfforts` is either `false` (disable reasoning) or a Map<Effort, string|null>
      // (never a List, and never omit to disable since omission inherits catalog defaults).
      updatedModel.remove('reasoning');
      if (reasoning) {
        final existingRaw = updatedModel['reasoningEfforts'];
        final existingMap = existingRaw is Map
            ? Map<String, dynamic>.from(existingRaw)
            : const <String, dynamic>{};
        if (reasoningEffortMap != null && reasoningEffortMap.isNotEmpty) {
          final cleaned = <String, dynamic>{};
          for (final kv in reasoningEffortMap.entries) {
            final k = kv.key.trim().toLowerCase();
            if (k.isEmpty) continue;
            final rawVal = kv.value?.trim();
            if (k == 'off') {
              cleaned['off'] = (rawVal == null || rawVal.isEmpty) ? null : rawVal;
            } else {
              cleaned[k] = (rawVal == null || rawVal.isEmpty) ? k : rawVal;
            }
          }
          updatedModel['reasoningEfforts'] = cleaned.isNotEmpty
              ? cleaned
              : const <String, dynamic>{'off': null, 'low': 'low', 'medium': 'medium', 'high': 'high'};
        } else {
          final efforts = (reasoningEfforts != null && reasoningEfforts.isNotEmpty)
              ? reasoningEfforts
              : (existingMap.isNotEmpty
                  ? existingMap.keys.map((e) => e.toString()).toList(growable: false)
                  : const ['off', 'low', 'medium', 'high']);
          updatedModel['reasoningEfforts'] = <String, dynamic>{
            for (final e in efforts)
              e: existingMap.containsKey(e)
                  ? existingMap[e]
                  : (e == 'off' ? null : e),
          };
        }
      } else {
        updatedModel['reasoningEfforts'] = false;
      }
      updatedModel['input'] = supportsImage ? const ['text', 'image'] : const ['text'];

      if (existingIdx >= 0) {
        modelsList[existingIdx] = updatedModel;
      } else {
        modelsList.add(updatedModel);
      }
      entry['models'] = modelsList;
      providersMap[cleanProv] = entry;
      rootCopy['providers'] = providersMap;

      return _patchDshNamespaceLocked(
        client,
        'llm-pi-ai',
        rootCopy,
        replace: true,
        silent: true,
        skipHydrate: true,
        mergeOnConflict: (freshSection) {
          final mergedRoot = Map<String, dynamic>.from(freshSection);
          final freshProviders = mergedRoot['providers'] is Map
              ? Map<String, dynamic>.from(mergedRoot['providers'] as Map)
              : <String, dynamic>{};
          final freshEntry = freshProviders[cleanProv] is Map
              ? Map<String, dynamic>.from(freshProviders[cleanProv] as Map)
              : <String, dynamic>{};
          final freshModels = <Map<String, dynamic>>[
            if (freshEntry['models'] is List)
              for (final m in freshEntry['models'] as List)
                if (m is Map) Map<String, dynamic>.from(m),
          ];
          final idx = freshModels.indexWhere((m) => m['id']?.toString() == matchId);
          if (idx >= 0) {
            freshModels[idx] = Map<String, dynamic>.from(updatedModel);
          } else {
            freshModels.add(Map<String, dynamic>.from(updatedModel));
          }
          freshEntry['models'] = freshModels;
          freshProviders[cleanProv] = freshEntry;
          mergedRoot['providers'] = freshProviders;
          return mergedRoot;
        },
      );
    });
    if (err != null) return err;
    if (!_isStillLive(client)) return _disconnectedSaveError;

    await _hydrateLiveDomains(client, skipAutoDefaultSync: true);
    if (!_isStillLive(client)) return null;
    if (setAsDefault ||
        hadNoValidModel ||
        state.activeModelEntry == null ||
        (wasActiveModel && matchId != cleanId)) {
      final liveEntry = _findModelEntry(cleanProv, cleanId) ?? state.firstAvailableModel;
      final targetProv = liveEntry?.providerId ?? cleanProv;
      final targetId = liveEntry?.id ?? cleanId;
      final targetName = liveEntry?.name ?? resolvedDisplayName;
      final targetShort = liveEntry?.shortLabel ?? resolvedDisplayName;
      await setModel(
        targetName,
        targetShort,
        provider: targetProv,
        modelId: targetId,
        effortId: liveEntry?.defaultEffort,
        silent: true,
      );
    }
    if (_isStillLive(client)) {
      showToast('已更新模型「$resolvedDisplayName」参数并同步到 DSH');
    }
    return null;
  }

  Future<String?> deleteCustomProvider(String providerId, {bool isCustom = true}) async {
    final client = _liveClient;
    if (client == null) {
      const msg = '请先连接到运行中的 DSH 主机';
      showToast(msg, tone: ToastTone.warn);
      return msg;
    }
    final cleanId = providerId.trim();
    if (cleanId.isEmpty) return null;
    var removedEnv = '';
    final queueKey = '${state.activeHostId}:llm-pi-ai';
    final err = await _serializeNamespaceWrite<String?>(queueKey, () async {
      if (!_isStillLive(client)) return _disconnectedSaveError;
      final ns = state.dshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
      if (ns == null) return null;
      final rootCopy = Map<String, dynamic>.from(ns.value);
      final rawProviders = rootCopy['providers'];
      if (rawProviders is! Map || !rawProviders.containsKey(cleanId)) return null;
      final removedEntry = rawProviders[cleanId] is Map
          ? Map<String, dynamic>.from(rawProviders[cleanId] as Map)
          : const <String, dynamic>{};
      removedEnv = removedEntry['apiKeyEnv']?.toString().trim() ?? '';
      final providersMap = Map<String, dynamic>.from(rawProviders)..remove(cleanId);
      rootCopy['providers'] = providersMap;
      return _patchDshNamespaceLocked(
        client,
        'llm-pi-ai',
        rootCopy,
        replace: true,
        silent: true,
        skipHydrate: true,
        mergeOnConflict: (freshSection) {
          final mergedRoot = Map<String, dynamic>.from(freshSection);
          final freshProviders = mergedRoot['providers'] is Map
              ? Map<String, dynamic>.from(mergedRoot['providers'] as Map)
              : <String, dynamic>{};
          freshProviders.remove(cleanId);
          mergedRoot['providers'] = freshProviders;
          return mergedRoot;
        },
      );
    });
    if (err != null) return err;
    if (!_isStillLive(client)) return _disconnectedSaveError;
    if (isCustom && removedEnv.isNotEmpty) {
      final piNs = state.dshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
      final remainingProviders = piNs?.value['providers'];
      var envStillReferenced = false;
      if (remainingProviders is Map) {
        for (final entry in remainingProviders.entries) {
          if (entry.key.toString() == cleanId) continue;
          final v = entry.value;
          if (v is Map && v['apiKeyEnv']?.toString().trim() == removedEnv) {
            envStillReferenced = true;
            break;
          }
        }
      }
      if (!envStillReferenced) {
        envStillReferenced = state.providerCredentials.any(
          (c) => c.envRef.trim() == removedEnv && c.id != cleanId,
        );
      }
      if (!envStillReferenced) {
        await client.unsetCredential({'ref': removedEnv}).catchError((_) => <String, dynamic>{});
        if (!_isStillLive(client)) return null;
      }
    }
    final clearedActive = state.activeModelProvider == cleanId;
    ModelCatalogEntry? fallbackModel;
    if (clearedActive) {
      final fallbackGroup = state.modelGroups
              .where((g) => g.id != cleanId && g.routable && g.models.isNotEmpty)
              .firstOrNull ??
          state.modelGroups.where((g) => g.id != cleanId && g.models.isNotEmpty).firstOrNull;
      if (fallbackGroup != null) {
        final m = fallbackGroup.models.first;
        fallbackModel = m;
        await mutateDshNamespace(
          'agent-default-model',
          [
            {'op': 'set', 'path': ['provider'], 'value': fallbackGroup.id},
            {'op': 'set', 'path': ['model'], 'value': m.id},
            if (m.efforts.isNotEmpty && m.defaultEffort.isNotEmpty)
              {'op': 'set', 'path': ['reasoningEffort'], 'value': m.defaultEffort}
            else
              {'op': 'unset', 'path': ['reasoningEffort']},
          ],
          silent: true,
          skipHydrate: true,
          suppressErrorToast: true,
          clientOverride: client,
        );
      } else {
        await mutateDshNamespace(
          'agent-default-model',
          [
            {'op': 'unset', 'path': ['provider']},
            {'op': 'unset', 'path': ['model']},
            {'op': 'unset', 'path': ['reasoningEffort']},
          ],
          silent: true,
          skipHydrate: true,
          suppressErrorToast: true,
          clientOverride: client,
        );
      }
      if (!_isStillLive(client)) return null;
    }
    state = state.copyWith(
      providerCredentials: state.providerCredentials.where((p) => p.id != cleanId).toList(growable: false),
      activeModelProvider: clearedActive ? (fallbackModel?.providerId ?? '') : state.activeModelProvider,
      activeModelId: clearedActive ? (fallbackModel?.id ?? '') : state.activeModelId,
      modelName: clearedActive ? (fallbackModel?.name ?? '未配置模型') : state.modelName,
      modelShort: clearedActive ? (fallbackModel?.shortLabel ?? '未配置') : state.modelShort,
      modelEffort: clearedActive
          ? _effortIdToZhLabel(fallbackModel?.defaultEffort ?? '')
          : state.modelEffort,
      modelEffortId: clearedActive ? (fallbackModel?.defaultEffort ?? '') : state.modelEffortId,
    );
    await _hydrateLiveDomains(client);
    if (_isStillLive(client)) {
      showToast(
        isCustom ? '已移除自定义渠道「$cleanId」' : '已重置渠道「$cleanId」为 DSH 默认配置',
        tone: ToastTone.info,
      );
    }
    return null;
  }

  Future<({List<Map<String, dynamic>> models, String? error, bool reachable})>
      discoverProviderModels({
    required String providerId,
    required String apiProtocol,
    required String baseUrl,
    String? apiKeyValue,
    String? envRef,
    bool testOnly = false,
  }) async {
    final client = _liveClient;
    if (client == null) {
      final msg =
          testOnly ? '请先连接到运行中的 DSH 主机后再测试连通性' : '请先连接到运行中的 DSH 主机后再拉取模型列表';
      showToast(msg, tone: ToastTone.warn);
      return (models: const <Map<String, dynamic>>[], error: msg, reachable: false);
    }
    try {
      final cleanUrl = _normalizeProviderBaseUrl(baseUrl);
      final resp = await client.discoverProviderModels({
        if (providerId.trim().isNotEmpty) 'provider': providerId.trim(),
        if (apiProtocol.trim().isNotEmpty) 'api': apiProtocol.trim(),
        if (cleanUrl.isNotEmpty) 'baseURL': cleanUrl,
        if (apiKeyValue != null && apiKeyValue.trim().isNotEmpty) 'apiKey': apiKeyValue.trim(),
        if (envRef != null && envRef.trim().isNotEmpty) 'apiKeyEnv': envRef.trim(),
      });
      final inner = resp['result'] is Map ? resp['result'] as Map : resp;
      final rawModels = inner['models'] ?? resp['models'];
      final out = <Map<String, dynamic>>[];
      if (rawModels is List) {
        for (final item in rawModels) {
          if (item is String && item.trim().isNotEmpty) {
            out.add({'id': item.trim(), 'name': item.trim()});
          } else if (item is Map) {
            final id = (item['id'] ?? item['model'] ?? '').toString().trim();
            if (id.isEmpty) continue;
            final rawInput = item['input'] ?? item['inputModalities'];
            out.add({
              'id': id,
              'name': (item['name'] ?? id).toString(),
              if (item['contextWindow'] is num) 'contextWindow': item['contextWindow'],
              if (item['maxTokens'] is num) 'maxTokens': item['maxTokens'],
              if (item['reasoning'] is bool) 'reasoning': item['reasoning'],
              if (rawInput is List && rawInput.isNotEmpty)
                'input': rawInput.map((e) => e.toString()).toList(growable: false),
            });
          }
        }
      }
      if (mounted) {
        final msg = testOnly
            ? (out.isEmpty ? '连通正常，但接口未返回可用模型' : '测试连通成功，发现 ${out.length} 个模型')
            : (out.isEmpty ? '接口连通正常但未返回模型，可手动填写模型 ID' : '已自动拉取 ${out.length} 个模型');
        showToast(msg, tone: out.isEmpty ? ToastTone.info : ToastTone.ok);
      }
      return (models: out, error: null, reachable: true);
    } catch (e) {
      final errStr = formatReadableError(e);
      if (mounted) showError(testOnly ? '测试连通失败' : '自动拉取模型列表失败', error: e);
      return (models: const <Map<String, dynamic>>[], error: errStr, reachable: false);
    }
  }

  Future<void> upsertProviderCredential(
    String envRef,
    String secretValue, {
    String? baseUrl,
    String? settingsNs,
    String? providerId,
  }) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机后再保存凭据', tone: ToastTone.warn);
      return;
    }
    final cleanSecret = secretValue.trim();
    if (cleanSecret.isNotEmpty) {
      try {
        await client.setCredential({'ref': envRef, 'value': cleanSecret});
        if (!_isStillLive(client)) return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        showError('保存凭据 $envRef 失败', error: e);
        return;
      }
    }
    final cleanUrl = _normalizeProviderBaseUrl(baseUrl ?? '');
    if (cleanUrl.isNotEmpty) {
      if (settingsNs == 'llm-deepseek') {
        final err = await patchDshNamespace('llm-deepseek', {'baseURL': cleanUrl}, silent: true, clientOverride: client);
        if (err != null || !_isStillLive(client)) return;
      } else if (settingsNs == 'llm-pi-ai' && providerId != null && providerId.trim().isNotEmpty) {
        final cleanProvId = providerId.trim();
        Map<String, dynamic> applyCredDelta(Map<String, dynamic> baseSection) {
          final rootCopy = Map<String, dynamic>.from(baseSection);
          final providersMap = rootCopy['providers'] is Map
              ? Map<String, dynamic>.from(rootCopy['providers'] as Map)
              : <String, dynamic>{};
          final entry = providersMap[cleanProvId] is Map
              ? Map<String, dynamic>.from(providersMap[cleanProvId] as Map)
              : <String, dynamic>{};
          entry['baseURL'] = cleanUrl;
          entry['apiKeyEnv'] = envRef;
          providersMap[cleanProvId] = entry;
          rootCopy['providers'] = providersMap;
          return rootCopy;
        }

        final queueKey = '${state.activeHostId}:llm-pi-ai';
        final err = await _serializeNamespaceWrite<String?>(queueKey, () async {
          if (!_isStillLive(client)) return null;
          final ns = state.dshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
          final rootCopy = applyCredDelta(ns?.value ?? const <String, dynamic>{});
          return _patchDshNamespaceLocked(
            client,
            'llm-pi-ai',
            rootCopy,
            replace: true,
            silent: true,
            skipHydrate: true,
            mergeOnConflict: applyCredDelta,
          );
        });
        if (err != null || !_isStillLive(client)) return;
      }
    }
    await _hydrateLiveDomains(client);
    if (_isStillLive(client)) showToast('已保存 $envRef 凭据至 DSH 核心');
  }

  Future<void> removeProviderCredential(String envRef) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    try {
      await client.unsetCredential({'ref': envRef});
      if (!_isStillLive(client)) return;
    } catch (e) {
      if (!_isStillLive(client)) return;
      showError('清除凭据 $envRef 失败', error: e);
      return;
    }
    await _hydrateLiveDomains(client);
    if (_isStillLive(client)) showToast('已从 DSH 清除 $envRef 凭据', tone: ToastTone.info);
  }

  Future<void> probeMcpServer(String name) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机后再探测 MCP 服务', tone: ToastTone.warn);
      return;
    }
    state = state.copyWith(
      mcpServers: [
        for (final s in state.mcpServers) s.name == name ? s.copyWith(status: 'probing') : s,
      ],
    );
    final t0 = DateTime.now();
    bool ok = true;
    int? toolsCount;
    String? probeErr;
    try {
      final res = await client.mcpAction(name, 'probe');
      if (!_isStillLive(client)) return;
      final r = res['result'];
      if (r is Map && r['tools'] is List) {
        toolsCount = (r['tools'] as List).length;
      }
    } catch (e) {
      if (!_isStillLive(client)) return;
      ok = false;
      probeErr = formatReadableError(e);
    }
    if (!_isStillLive(client)) return;
    final ms = DateTime.now().difference(t0).inMilliseconds.clamp(1, 9999);
    state = state.copyWith(
      mcpServers: [
        for (final s in state.mcpServers)
          s.name == name
              ? s.copyWith(
                  status: ok ? 'connected' : 'error',
                  toolsCount: toolsCount ?? s.toolsCount,
                  lastLatencyMs: ms,
                )
              : s,
      ],
    );
    if (ok) {
      showToast('MCP 服务 $name 探测正常 (${ms}ms)');
    } else {
      showError('MCP 服务 $name 探测失败', error: probeErr ?? '连接异常');
    }
  }

  Future<void> restartMcpServer(String name) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机后再重启 MCP 服务', tone: ToastTone.warn);
      return;
    }
    state = state.copyWith(
      mcpServers: [
        for (final s in state.mcpServers)
          s.name == name ? s.copyWith(status: 'probing') : s,
      ],
    );
    try {
      await client.mcpAction(name, 'restart');
      if (!_isStillLive(client)) return;
    } catch (e) {
      if (!_isStillLive(client)) return;
      state = state.copyWith(
        mcpServers: [
          for (final s in state.mcpServers)
            s.name == name ? s.copyWith(status: 'error') : s,
        ],
      );
      showError('重启 MCP 服务 $name 失败', error: e);
      return;
    }
    await probeMcpServer(name);
  }

  void addCustomPreset(String id, String name, String desc) {
    if (_liveClient == null) {
      showToast('角色预设由已连接的 DSH 核心统一管理，请先连接 DSH 主机', tone: ToastTone.warn);
      return;
    }
    showToast('DSH 角色预设请在「DSH 完整配置 → agent-preset-registry」中管理', tone: ToastTone.info);
  }

  Future<void> restartLocalEngine() async {
    final native = GrassBagNativeBridge.instance;
    showToast('正在重启本机 DSH 引擎…', tone: ToastTone.info);
    if (native.isAndroidNative) {
      final isLocalActive = state.activeHost.isLocal;
      final gen = isLocalActive ? ++_hostConnectGen : null;
      _userStoppedLocalEngine = false;
      _autoStartRequestedGen = -1;
      if (isLocalActive) {
        _detachLiveClientsSync();
        if (mounted) {
          state = state.copyWith(connectionPhase: ConnectionPhase.connecting);
        }
      }
      final res = await native.restartLocalEngine();
      await refreshNativeStatus(connectGen: gen);
      final logs = await native.getEngineLogs();
      if (!mounted) return;
      if (state.activeHost.isLocal) {
        state = state.copyWith(engineLogs: logs);
      }
      showToast(
        res['ok'] == true ? '本机 Ubuntu + DSH 引擎已重启并就绪' : '重启失败：${res['error'] ?? '请检查容器状态'}',
        tone: res['ok'] == true ? ToastTone.ok : ToastTone.warn,
      );
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    showToast('本机引擎已重启完成');
  }

  Future<void> cleanLocalCache() async {
    final native = GrassBagNativeBridge.instance;
    if (native.isAndroidNative) {
      final res = await native.cleanRuntimeCache();
      await refreshNativeStatus();
      final kb = (res['freedKb'] as num?)?.toInt() ?? 0;
      showToast('已清理容器临时缓存，释放 ${kb >= 1024 ? '${(kb / 1024).toStringAsFixed(1)} MB' : '$kb KB'}');
      return;
    }
    showToast('已清理临时缓存与过期快照');
  }

  Future<void> rebuildLocalContainer() async {
    final native = GrassBagNativeBridge.instance;
    if (native.isAndroidNative) {
      showToast('正在保留 /root 重建 Ubuntu 容器…', tone: ToastTone.info);
      final isLocalActive = state.activeHost.isLocal;
      final gen = isLocalActive ? ++_hostConnectGen : null;
      _userStoppedLocalEngine = false;
      _autoStartRequestedGen = -1;
      if (isLocalActive) {
        _detachLiveClientsSync();
        if (mounted) {
          state = state.copyWith(connectionPhase: ConnectionPhase.connecting);
        }
      }
      final res = await native.rebuildContainer();
      if (!mounted) return;
      if (res['cancelled'] == true) {
        state = state.copyWith(
          runtimeProgressPct: 0,
          runtimeProgressMsg: '',
          runtimeProgressStage: '',
          runtimeProgressCanCancel: false,
        );
        await refreshNativeStatus(skipAutoConnect: true, forceFresh: true);
        if (!mounted) return;
        showToast('已暂停容器重建下载，下次可断点续传', tone: ToastTone.info);
        return;
      }
      await refreshNativeStatus(connectGen: gen, forceFresh: true);
      if (!mounted) return;
      if (res['ok'] != true) {
        state = state.copyWith(
          runtimeProgressPct: 0,
          runtimeProgressMsg: '',
          runtimeProgressStage: '',
          runtimeProgressCanCancel: false,
        );
      } else {
        state = state.copyWith(
          runtimeProgressStage: '',
          runtimeProgressCanCancel: false,
        );
      }
      showToast(
        res['ok'] == true ? '容器已重建并重启引擎，/root 资料零丢失' : '容器重建失败：${res['error']}',
        tone: res['ok'] == true ? ToastTone.ok : ToastTone.warn,
      );
      return;
    }
    await upgradeLocalContainer();
  }

  Future<void> refreshEngineLogs({bool forceLocal = false}) async {
    // Only populate Android native engine logs when viewing the local Android host (or Local Host Detail).
    if (!forceLocal && !state.activeHost.isLocal) return;
    final logs = await GrassBagNativeBridge.instance.getEngineLogs();
    if (mounted && (forceLocal || state.activeHost.isLocal) && logs.isNotEmpty) {
      state = state.copyWith(engineLogs: logs);
    }
  }

  Future<void> installContainerToolkit(String toolkitId) async {
    final idx = state.containerToolkits.indexWhere((t) => t.id == toolkitId);
    if (idx < 0 || state.containerToolkits[idx].installed || state.containerToolkits[idx].installing) return;
    final item = state.containerToolkits[idx];
    final native = GrassBagNativeBridge.instance;
    if (!native.isAndroidNative) {
      showToast('容器工具链扩展仅适用于 Android 本机内置 Ubuntu 容器', tone: ToastTone.info);
      return;
    }
    if (!state.nativeRuntimeStatus.containerExtracted) {
      showToast('请先初始化本机 Ubuntu 容器后再安装工具链', tone: ToastTone.warn);
      return;
    }
    final anyOtherInstalling = state.containerToolkits.any((t) => t.installing && t.id != toolkitId);
    state = state.copyWith(
      containerToolkits: [
        for (final t in state.containerToolkits) t.id == toolkitId ? t.copyWith(installing: true) : t,
      ],
    );
    showToast(
      anyOtherInstalling
          ? '已加入安装队列，前一项完成后自动部署「${item.name}」…'
          : '正在通过 apt 安装「${item.name}」…',
      tone: ToastTone.info,
    );
    final res = await native.installToolkit(item.id, item.packages);
    await refreshNativeStatus();
    if (!mounted) return;
    final ok = res['ok'] == true;
    state = state.copyWith(
      containerToolkits: [
        for (final t in state.containerToolkits)
          t.id == toolkitId ? t.copyWith(installing: false, installed: ok || t.installed) : t,
      ],
    );
    if (ok) {
      showToast('已真实部署「${item.name}」到本机 Ubuntu 容器');
    } else {
      showError('安装工具链「${item.name}」失败', error: res['error'] ?? '请检查容器网络后重试');
    }
  }

  Future<void> probeAndRefreshHost(String hostId) async {
    final target = state.hosts.firstWhere((h) => h.id == hostId, orElse: () => state.activeHost);
    final isActive = target.id == state.activeHostId;
    showToast('正在探测 ${target.name}…', tone: ToastTone.info);
    if (target.isLocal && !target.address.startsWith('http') && !kIsWeb) {
      if (isActive && _liveClient == null) {
        state = state.copyWith(
          connectionPhase: ConnectionPhase.connecting,
          loadingSessions: true,
        );
      }
      await refreshNativeStatus(connectGen: isActive ? ++_hostConnectGen : null);
      if (!mounted) return;
      final rt = state.nativeRuntimeStatus;
      if (!rt.initialized) {
        showToast('本机 Linux 容器尚未初始化，请点击一键部署容器', tone: ToastTone.warn);
        return;
      }
      if (rt.engineState == 'error') {
        final errDetail = rt.engineError;
        showError(
          '本机 DSH 启动异常',
          error: (errDetail != null && errDetail.isNotEmpty) ? errDetail : '请查看容器诊断日志',
        );
        return;
      }
      if (!rt.engineRunning) {
        showToast('正在启动本机 DSH 引擎，请稍候…', tone: ToastTone.info);
        return;
      }
      if (isActive && _liveClient != null) {
        await refreshSessionsList(silent: true);
      }
      showToast('本机 DSH v${state.localHost.dshVersion} · 连接助手 v${state.localHost.helperVersion ?? '0.1.0'} 运行正常');
      return;
    }
    final t0 = DateTime.now();
    if (isActive) {
      final existingClient = _liveClient;
      if (existingClient != null &&
          state.connectionPhase == ConnectionPhase.connected &&
          target.online) {
        // Non-destructive liveness check first so probing a healthy active host never tears down
        // an active WebSocket or ongoing reply stream!
        final alive = await existingClient.stream.checkLiveness().catchError((_) => false);
        if (!mounted) return;
        if (alive) {
          final ms = DateTime.now().difference(t0).inMilliseconds.clamp(1, 9999);
          state = state.copyWith(
            hosts: [
              for (final h in state.hosts) h.id == hostId ? h.copyWith(latency: '$ms ms') : h,
            ],
          );
          unawaited(refreshSessionsList(silent: true));
          showToast(
            target.bridged
                ? '${target.name} 运行正常（增强模式 · ${ms}ms）'
                : '${target.name} 运行正常（原生直连 · ${ms}ms）',
          );
          return;
        }
      }
      final gen = ++_hostConnectGen;
      state = state.copyWith(
        connectionPhase: ConnectionPhase.connecting,
        loadingSessions: true,
      );
      await _tryConnectLiveHost(target, gen: gen, restoreLastSession: false);
      if (!mounted || gen != _hostConnectGen) return;
    } else {
      await _probeHostOnly(target);
    }
    if (!mounted) return;
    final ms = DateTime.now().difference(t0).inMilliseconds.clamp(1, 9999);
    final updated = state.hosts.firstWhere((h) => h.id == hostId, orElse: () => target);
    if (updated.online || updated.needsAuth) {
      state = state.copyWith(
        hosts: [
          for (final h in state.hosts) h.id == hostId ? h.copyWith(latency: '$ms ms') : h,
        ],
      );
    } else {
      state = state.copyWith(
        hosts: [
          for (final h in state.hosts) h.id == hostId ? h.copyWith(latency: '离线') : h,
        ],
      );
    }
    if (updated.needsAuth) {
      showToast(
        updated.isHtmlProxyAuth
            ? '已连通「${updated.name}」，请点击「网页登录」完成一次授权（30 天免填）'
            : '已连通「${updated.name}」，粘贴一次启动链接或 Token 后即可 30 天免填',
        tone: ToastTone.info,
      );
      return;
    }
    if (!updated.online) {
      showError(
        '${updated.name} 连接失败',
        error: updated.lastError ?? '无法访问主机地址，请检查网络或访问令牌',
      );
      return;
    }
    showToast(
      updated.bridged
          ? '${updated.name} 在线 · DSH v${updated.dshVersion} · 助手 v${updated.helperVersion ?? '0.1.0'} ($ms ms)'
          : (updated.directMode
              ? '${updated.name} 原生直连就绪 · DSH v${updated.dshVersion} ($ms ms)'
              : '已探测 ${updated.name}，可一键安装连接助手解锁完整功能'),
      tone: ToastTone.ok,
    );
  }

  static Uri _stripUriQuery(Uri uri) => Uri(
        scheme: uri.scheme,
        userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
        fragment: uri.hasFragment ? uri.fragment : null,
      );

  static String _stripQueryToken(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme || !uri.queryParameters.containsKey('token')) {
      return rawUrl;
    }
    final nextParams = Map<String, String>.of(uri.queryParameters)..remove('token');
    if (nextParams.isEmpty) return _stripUriQuery(uri).toString();
    return uri.replace(queryParameters: nextParams).toString();
  }

  String exportConfigJson() {
    final sanitizedHosts = state.hosts
        .map((h) {
          final m = h.toJson();
          if (m['address'] is String) {
            m['address'] = _stripQueryToken(m['address'] as String);
          }
          m.remove('token');
          return m;
        })
        .toList(growable: false);
    final payload = {
      'schema': 'grassbag-app-config-v3',
      'exportedAt': DateTime.now().toIso8601String(),
      'note': '仅包含 GrassBag 客户端偏好与主机清单；模型、渠道与引擎配置均保存在各 DSH 核心中',
      'prefs': {
        'isDark': state.isDark,
        'accent': state.accent.name,
        'glassTier': state.glassTier.name,
        'glassOpticalStrength': state.glassOpticalStrength,
        'autoFoldSteps': state.autoFoldSteps,
        'useSystemProxy': state.useSystemProxy,
        'safetyPolicy': state.safetyPolicy,
        'phoneConfirmHighRisk': state.phoneConfirmHighRisk,
        'sessionGroupMode': state.sessionGroupMode.name,
      },
      'hosts': sanitizedHosts,
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Non-destructive preview of importing a GrassBag client config JSON snapshot.
  Map<String, dynamic>? previewImportConfigJson(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map<String, dynamic>) return null;
      final prefs = decoded['prefs'];
      final rawHosts = decoded['hosts'];
      final hasPrefs = prefs is Map<String, dynamic> && prefs.isNotEmpty;
      final hasHosts = rawHosts is List && rawHosts.isNotEmpty;
      if (!hasPrefs && !hasHosts) return null;
      final existingById = {for (final h in state.hosts) h.id: h};
      String normAddr(String raw) => _stripQueryToken(raw).trim().toLowerCase().replaceFirst(RegExp(r'/+$'), '');
      var addedHosts = 0;
      var updatedHosts = 0;
      var originChangedHosts = 0;
      final importedIds = <String>{};
      if (hasHosts) {
        for (final m in rawHosts.whereType<Map<String, dynamic>>()) {
          final h = ManagedHost.fromJson(m);
          importedIds.add(h.id);
          final prev = existingById[h.id];
          if (prev == null) {
            addedHosts++;
          } else {
            updatedHosts++;
            if (normAddr(prev.address) != normAddr(_stripQueryToken(h.address))) {
              originChangedHosts++;
            }
          }
        }
      }
      final preservedExistingHosts = existingById.values
          .where((h) => !h.isLocal && !importedIds.contains(h.id))
          .length;
      return {
        'ok': true,
        'hasPrefs': hasPrefs,
        'addedHosts': addedHosts,
        'updatedHosts': updatedHosts,
        'originChangedHosts': originChangedHosts,
        'preservedExistingHosts': preservedExistingHosts,
      };
    } catch (_) {
      return null;
    }
  }

  bool importConfigJson(String rawJson, {bool replaceHosts = false}) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map<String, dynamic>) return false;
      final prefs = decoded['prefs'];
      final rawHosts = decoded['hosts'];
      final hasPrefs = prefs is Map<String, dynamic> && prefs.isNotEmpty;
      final hasHosts = rawHosts is List && rawHosts.isNotEmpty;
      if (!hasPrefs && !hasHosts) {
        showToast('未在 JSON 中找到可导入的偏好或主机配置', tone: ToastTone.warn);
        return false;
      }
      if (hasPrefs) {
        final accentName = prefs['accent']?.toString();
        final tierName = prefs['glassTier']?.toString();
        final nextIsDark = prefs['isDark'] is bool ? prefs['isDark'] as bool : state.isDark;
        final nextAccent = accentName != null
            ? GrassBagAccent.values.firstWhere(
                (a) => a.name == accentName,
                orElse: () => state.accent,
              )
            : state.accent;
        final nextUseProxy = prefs['useSystemProxy'] is bool
            ? prefs['useSystemProxy'] as bool
            : state.useSystemProxy;
        final nextSafetyPolicy = prefs['safetyPolicy']?.toString() ?? state.safetyPolicy;
        final nextConfirmHighRisk = prefs['phoneConfirmHighRisk'] is bool
            ? prefs['phoneConfirmHighRisk'] as bool
            : state.phoneConfirmHighRisk;
        state = state.copyWith(
          isDark: nextIsDark,
          accent: nextAccent,
          glassTier: tierName != null
              ? GrassBagGlassTier.values.firstWhere(
                  (g) => g.name == tierName,
                  orElse: () => state.glassTier,
                )
              : state.glassTier,
          glassOpticalStrength: prefs['glassOpticalStrength'] is num
              ? (prefs['glassOpticalStrength'] as num).toDouble().clamp(0.0, 1.0)
              : state.glassOpticalStrength,
          autoFoldSteps: prefs['autoFoldSteps'] is bool
              ? prefs['autoFoldSteps'] as bool
              : state.autoFoldSteps,
          useSystemProxy: nextUseProxy,
          safetyPolicy: nextSafetyPolicy,
          phoneConfirmHighRisk: nextConfirmHighRisk,
          sessionGroupMode: SessionGroupMode.values.firstWhere(
            (m) => m.name == prefs['sessionGroupMode']?.toString(),
            orElse: () => state.sessionGroupMode,
          ),
        );
        final native = GrassBagNativeBridge.instance;
        final tok = GrassBagTokens.resolve(
          nextAccent,
          nextIsDark ? Brightness.dark : Brightness.light,
        );
        unawaited(
          native.syncThemeMode(
            nextIsDark,
            accentPrimary: tok.primary.toARGB32(),
            accentHi: tok.primaryHi.toARGB32(),
          ),
        );
        unawaited(native.setSystemProxy(nextUseProxy));
        unawaited(native.setSafetyPolicy(nextSafetyPolicy));
        unawaited(native.setSafetyConfirmHighRisk(nextConfirmHighRisk));
      }
      if (hasHosts) {
        final existingById = {for (final h in state.hosts) h.id: h};
        final isAndroid = GrassBagNativeBridge.instance.isAndroidNative;
        final localUri = Uri.tryParse(state.localHost.address);
        String normAddr(String raw) => _stripQueryToken(raw).trim().toLowerCase().replaceFirst(RegExp(r'/+$'), '');
        final imported = rawHosts
            .whereType<Map<String, dynamic>>()
            .map((m) {
              final h = ManagedHost.fromJson(m);
              final cleanAddr = _stripQueryToken(h.address);
              final prev = existingById[h.id];
              final sameOrigin = prev != null && normAddr(prev.address) == normAddr(cleanAddr);
              return h.copyWith(
                address: cleanAddr,
                // Preserve credentials & live runtime status ONLY when host origin is unchanged!
                token: sameOrigin ? prev.token : null,
                clearToken: !sameOrigin,
                sessionCookie: sameOrigin ? prev.sessionCookie : null,
                clearSessionCookie: !sameOrigin,
                online: sameOrigin ? prev.online : false,
                bridged: sameOrigin ? prev.bridged : false,
                directMode: sameOrigin ? prev.directMode : false,
                latency: sameOrigin ? prev.latency : h.latency,
                dshVersion: sameOrigin ? prev.dshVersion : h.dshVersion,
                dshLatest: sameOrigin ? prev.dshLatest : h.dshLatest,
                helperVersion: sameOrigin ? prev.helperVersion : h.helperVersion,
                containerVersion: sameOrigin ? prev.containerVersion : h.containerVersion,
                containerLatest: sameOrigin ? prev.containerLatest : h.containerLatest,
              );
            })
            .where((h) {
              if (h.isLocal || !isAndroid) return true;
              final hUri = Uri.tryParse(h.address);
              if (hUri == null) return true;
              return !isSelfDeviceUri(
                hUri,
                _deviceLocalIps,
                isAndroidNative: true,
                localHostUri: localUri,
              );
            })
            .toList(growable: false);
        if (imported.isNotEmpty) {
          final importedById = {for (final h in imported) h.id: h};
          var contextsDirty = false;
          // Merge hosts by default (preserving existing remote hosts & their Keystore credentials
          // not listed in the snapshot); only remove unlisted hosts when `replaceHosts: true`.
          final List<ManagedHost> mergedHosts;
          if (replaceHosts && imported.any((h) => h.isLocal)) {
            for (final prevEntry in existingById.entries) {
              if (!importedById.containsKey(prevEntry.key) && !prevEntry.value.isLocal) {
                if (_hostContexts.remove(prevEntry.key) != null) contextsDirty = true;
                _sessionAttachmentsMemory.removeWhere((k, _) => k.startsWith('${prevEntry.key}::'));
                unawaited(GrassBagNativeBridge.instance.deleteSecret('host_token_${prevEntry.key}'));
                unawaited(GrassBagNativeBridge.instance.deleteSecret('host_cookie_${prevEntry.key}'));
              }
            }
            mergedHosts = imported;
          } else {
            mergedHosts = <ManagedHost>[
              for (final existing in state.hosts)
                importedById[existing.id] ?? existing,
              for (final h in imported)
                if (!existingById.containsKey(h.id) && !h.isLocal) h,
            ];
          }
          for (final h in imported) {
            final prevHost = existingById[h.id];
            if (prevHost != null && normAddr(prevHost.address) != normAddr(h.address)) {
              if (_hostContexts.remove(h.id) != null) contextsDirty = true;
              if (!h.isLocal) {
                unawaited(GrassBagNativeBridge.instance.deleteSecret('host_token_${h.id}'));
                unawaited(GrassBagNativeBridge.instance.deleteSecret('host_cookie_${h.id}'));
              }
            }
          }
          if (contextsDirty) _persistHostContexts(immediate: true);
          final prevActive = state.activeHostId;
          final fallbackLocal = mergedHosts.firstWhere(
            (h) => h.isLocal,
            orElse: () => mergedHosts.first,
          );
          final nextActiveHost =
              mergedHosts.where((h) => h.id == prevActive).firstOrNull ?? fallbackLocal;
          final nextActiveId = nextActiveHost.id;
          state = state.copyWith(hosts: mergedHosts);
          _persistHosts();
          final prevActiveHost = existingById[nextActiveId];
          if (nextActiveId != prevActive ||
              prevActiveHost == null ||
              normAddr(prevActiveHost.address) != normAddr(nextActiveHost.address)) {
            unawaited(switchHost(nextActiveId));
          }
        }
      }
      _persistPrefs();
      showToast('已成功导入客户端偏好与主机清单（DSH 配置将随主机连接自动同步）');
      return true;
    } catch (_) {
      showToast('配置 JSON 格式无效，请检查后重试', tone: ToastTone.warn);
      return false;
    }
  }

  int _enqueueSeq = 0;

  Future<bool> enqueueMessage(
    String text, {
    String mode = 'queue',
    List<Map<String, dynamic>>? references,
  }) async {
    final trimmed = text.trim();
    final attached = List<ComposerAttachment>.of(state.pendingAttachments);
    if (trimmed.isEmpty && attached.isEmpty) return false;
    final client = _liveClient;
    final sid = state.activeSessionId;
    if (sid != null && sid.startsWith('pending-session-')) {
      showToast('对话正在创建中，请稍候 1 秒后再发送补充消息', tone: ToastTone.info);
      return false;
    }
    if (client == null || sid == null) {
      showToast('请先连接到运行中的 DSH 会话', tone: ToastTone.warn);
      return false;
    }
    final enqueueGen = _hostConnectGen;
    final uploadedRefs = await _prepareAttachmentsForUpload(
      client,
      sid,
      attached,
      gen: enqueueGen,
      updateSendStage: false,
    );
    if (uploadedRefs == null) return false;
    if (!_isStillLive(client, gen: enqueueGen) || state.activeSessionId != sid) return false;

    final tempId = 'q-${DateTime.now().millisecondsSinceEpoch}-${++_enqueueSeq}';
    final label = trimmed.isNotEmpty ? trimmed : '[附带 ${attached.length} 个附件]';
    final item = QueuedMessageItem(id: tempId, text: label, mode: mode);
    final sentIds = attached.map((a) => a.id).toSet();
    state = state.copyWith(
      queuedMessages: [...state.queuedMessages, item],
      pendingAttachments: state.pendingAttachments
          .where((a) => !sentIds.contains(a.id))
          .toList(growable: false),
    );
    if (sentIds.isNotEmpty) {
      for (final scopeKey in _sessionAttachmentsMemory.keys.toList(growable: false)) {
        final existingList = _sessionAttachmentsMemory[scopeKey];
        if (existingList == null) continue;
        final remaining = existingList
            .where((a) => !sentIds.contains(a.id))
            .toList(growable: false);
        if (remaining.isEmpty) {
          _sessionAttachmentsMemory.remove(scopeKey);
        } else if (remaining.length != existingList.length) {
          _sessionAttachmentsMemory[scopeKey] = List<ComposerAttachment>.unmodifiable(remaining);
        }
      }
    }
    try {
      final resp = await client.sendMessage(
        sid,
        text: trimmed,
        mode: mode,
        clientRequestId: tempId,
        attachments: uploadedRefs.isEmpty ? null : uploadedRefs,
        references: references != null && references.isNotEmpty ? references : null,
      );
      if (!_isStillLive(client)) return true;
      final res = resp['result'];
      // Only accept genuine server queue item IDs — never treat echoed `requestId` (`q-...`) as serverAcked!
      final rawServerId = (res is Map
              ? (res['itemId'] ?? res['queueItemId'] ?? res['id'])
              : (resp['itemId'] ?? resp['queueItemId'] ?? resp['id']))
          ?.toString();
      final hasRealServerId =
          rawServerId != null && rawServerId.isNotEmpty && rawServerId != tempId;
      final resolvedId = hasRealServerId ? rawServerId : tempId;
      if (state.activeSessionId == sid) {
        state = state.copyWith(
          queuedMessages: [
            for (final q in state.queuedMessages)
              q.id == tempId
                  ? q.copyWith(id: resolvedId, serverAcked: hasRealServerId)
                  : q,
          ],
        );
        if (!hasRealServerId) {
          // Reconcile authoritative inbox itemId from DSH projections immediately.
          unawaited(_syncLiveSessionBundle(sid, jumpToBottomOnLoad: false));
        }
        showToast(
          mode == 'steer' ? '已作为插话指令加入队列' : '已加入待发队列（${state.queuedMessages.length} 条）',
          tone: ToastTone.info,
        );
      } else if (mounted) {
        showToast(mode == 'steer' ? '已作为插话指令加入原对话队列' : '已加入原对话待发队列', tone: ToastTone.info);
      }
      return true;
    } catch (e) {
      if (!_isStillLive(client)) return false;
      if (state.activeSessionId == sid) {
        final existingIds = state.pendingAttachments.map((a) => a.id).toSet();
        state = state.copyWith(
          queuedMessages: state.queuedMessages.where((q) => q.id != tempId).toList(growable: false),
          pendingAttachments: [
            ...attached.where((a) => !existingIds.contains(a.id)),
            ...state.pendingAttachments,
          ],
        );
      } else if (attached.isNotEmpty) {
        final scopeKey = _attachmentsScopeKey(state.activeHostId, sid);
        final prevStashed = _sessionAttachmentsMemory[scopeKey] ?? const <ComposerAttachment>[];
        final prevIds = prevStashed.map((a) => a.id).toSet();
        _sessionAttachmentsMemory[scopeKey] = List<ComposerAttachment>.unmodifiable([
          ...attached.where((a) => !prevIds.contains(a.id)),
          ...prevStashed,
        ]);
      }
      showError('加入待发队列失败', error: e);
      return false;
    }
  }

  Future<void> removeQueuedMessage(String id) async {
    final target = state.queuedMessages.where((q) => q.id == id).firstOrNull;
    if (target == null) return;
    final client = _liveClient;
    state = state.copyWith(
      queuedMessages: state.queuedMessages.where((q) => q.id != id).toList(growable: false),
    );
    final sid = state.activeSessionId;
    final isServerKnown = target.serverAcked || !id.startsWith('q-');
    if (sid != null && !sid.startsWith('pending-session-') && client != null && isServerKnown) {
      try {
        await client.updateQueue(sid, {'itemId': id, 'action': 'remove'});
      } catch (e) {
        if (!_isStillLive(client)) return;
        if (state.activeSessionId == sid && !state.queuedMessages.any((q) => q.id == id)) {
          state = state.copyWith(queuedMessages: [...state.queuedMessages, target]);
        }
        showError('移除队列消息失败', error: e);
      }
    }
  }

  Future<bool> editQueuedMessage(String id, String nextText) async {
    final trimmed = nextText.trim();
    if (trimmed.isEmpty) return false;
    final target = state.queuedMessages.where((q) => q.id == id).firstOrNull;
    if (target == null) {
      showToast('该消息已开始发送，无法修改', tone: ToastTone.info);
      return false;
    }
    final isAttachmentPlaceholder =
        target.text.startsWith('[附带 ') && target.text.endsWith(' 个附件]');
    if (isAttachmentPlaceholder && trimmed == target.text) {
      return false;
    }
    if (target.text == trimmed) return true;
    final client = _liveClient;
    state = state.copyWith(
      queuedMessages: [
        for (final q in state.queuedMessages) q.id == id ? q.copyWith(text: trimmed) : q,
      ],
    );
    final sid = state.activeSessionId;
    final isServerKnown = target.serverAcked || !id.startsWith('q-');
    if (sid != null && !sid.startsWith('pending-session-') && client != null && isServerKnown) {
      try {
        await client.updateQueue(sid, {'itemId': id, 'action': 'edit', 'text': trimmed});
        if (!_isStillLive(client)) return true;
        showToast('已更新排队内容', tone: ToastTone.info);
        return true;
      } catch (e) {
        if (!_isStillLive(client)) return false;
        if (state.activeSessionId == sid) {
          state = state.copyWith(
            queuedMessages: [
              for (final q in state.queuedMessages) q.id == id ? target : q,
            ],
          );
        }
        showError('修改队列消息失败', error: e);
        return false;
      }
    }
    return true;
  }

  Future<void> promoteQueuedMessage(String id) async {
    final target = state.queuedMessages.where((q) => q.id == id).firstOrNull;
    if (target == null) return;
    if (target.mode == 'steer') {
      showToast('该消息已是插话优先级', tone: ToastTone.info);
      return;
    }
    final client = _liveClient;
    state = state.copyWith(
      queuedMessages: [
        for (final q in state.queuedMessages) q.id == id ? q.copyWith(mode: 'steer') : q,
      ],
    );
    final sid = state.activeSessionId;
    final isServerKnown = target.serverAcked || !id.startsWith('q-');
    if (sid != null && !sid.startsWith('pending-session-') && client != null && isServerKnown) {
      try {
        await client.updateQueue(sid, {'itemId': id, 'action': 'promote'});
        if (!_isStillLive(client)) return;
        showToast('已改为插话，将在当前步骤间隙执行', tone: ToastTone.info);
        return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        if (state.activeSessionId == sid) {
          state = state.copyWith(
            queuedMessages: [
              for (final q in state.queuedMessages) q.id == id ? target : q,
            ],
          );
        }
        showError('提升队列优先级失败', error: e);
        return;
      }
    }
    if (sid != null && !sid.startsWith('pending-session-') && client != null) {
      unawaited(_syncLiveSessionBundle(sid, jumpToBottomOnLoad: false));
    }
    showToast('该消息已提交至队列，将在当前回复间隙执行', tone: ToastTone.info);
  }

  Future<void> patchEngineSettings(Map<String, dynamic> patch) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机后再修改引擎配置', tone: ToastTone.warn);
      return;
    }
    final prev = state.engineValues;
    final merged = Map<String, dynamic>.from(prev);
    for (final entry in patch.entries) {
      if (entry.value is Map<String, dynamic> && merged[entry.key] is Map<String, dynamic>) {
        merged[entry.key] = {
          ...(merged[entry.key] as Map<String, dynamic>),
          ...(entry.value as Map<String, dynamic>),
        };
      } else {
        merged[entry.key] = entry.value;
      }
    }
    state = state.copyWith(engineValues: merged);
    try {
      await client.patchSettings(patch);
      if (_isStillLive(client)) showToast('引擎配置已写入 DSH 并生效');
    } catch (e) {
      if (!_isStillLive(client)) return;
      state = state.copyWith(engineValues: prev);
      showError('保存引擎配置失败', error: e);
    }
  }

  Future<SduiView> loadSduiView(String viewId) async {
    final client = _liveClient;
    if (client != null) {
      try {
        final view = await client.getSduiView(viewId, sessionId: state.activeSessionId);
        if (_isStillLive(client)) {
          state = state.copyWith(sduiViews: {...state.sduiViews, viewId: view});
        }
        return view;
      } catch (e) {
        if (_isStillLive(client)) {
          showError('加载扩展面板失败 ($viewId)', error: e);
        }
        final errView = SduiView(
          viewId: viewId,
          title: viewId,
          root: {
            'type': 'column',
            'gap': 10,
            'children': [
              {
                'type': 'alert',
                'tone': 'error',
                'title': '加载主机面板失败',
                'message': formatReadableError(e),
              },
              {
                'type': 'actions',
                'items': [
                  {'id': 'refresh', 'label': '重新加载', 'style': 'primary'},
                ],
              },
            ],
          },
        );
        if (_isStillLive(client)) {
          state = state.copyWith(sduiViews: {...state.sduiViews, viewId: errView});
        }
        return errView;
      }
    }
    final fallback = buildFallbackSduiView(
      viewId,
      hostName: state.activeHost.name,
      dshVersion: state.activeHost.dshVersion,
      bridgeVersion: state.activeHost.helperVersion ?? '0.1.0',
      activeSlot: state.nativeRuntimeStatus.activeSlot,
      executorMode: state.activeHost.launcherMode,
      endpointsCount: state.liveCapabilities?.endpointsCount ?? 0,
      sessionsCount: state.sessions.length,
    );
    state = state.copyWith(sduiViews: {...state.sduiViews, viewId: fallback});
    return fallback;
  }

  Future<void> refreshSduiSurfaces({bool silent = false}) async {
    final client = _liveClient;
    if (client == null) {
      if (!silent) showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    try {
      final liveSurfaces = await client.listSduiSurfaces();
      if (!_isStillLive(client)) return;
      state = state.copyWith(sduiSurfaces: liveSurfaces);
      if (!silent) showToast('已刷新扩展面板列表', tone: ToastTone.info);
    } catch (e) {
      if (!_isStillLive(client)) return;
      if (!silent) showError('刷新扩展面板失败', error: e);
    }
  }

  Future<String?> invokeSduiAction(
    String viewId,
    String actionId, [
    Map<String, dynamic>? payload,
  ]) async {
    if (actionId == 'refresh') {
      await loadSduiView(viewId);
      if (mounted) showToast('扩展面板已刷新', tone: ToastTone.info);
      return null;
    }
    final client = _liveClient;
    if (client != null) {
      try {
        final res = await client.invokeSduiAction(viewId, actionId, payload);
        if (!_isStillLive(client)) return null;
        if (res['toast'] != null) {
          showToast(res['toast'].toString());
        } else {
          showToast('操作已执行');
        }
        if (res['patchView'] is Map<String, dynamic>) {
          final patched = SduiView.fromJson(res['patchView'] as Map<String, dynamic>);
          state = state.copyWith(sduiViews: {...state.sduiViews, viewId: patched});
        }
        if (res['navigateToSessionId'] is String) {
          final sid = res['navigateToSessionId'] as String;
          if (state.sessions.any((s) => s.id == sid)) {
            selectSession(sid);
          }
        }
        return null;
      } catch (e) {
        if (!_isStillLive(client)) return null;
        showError('执行扩展操作失败 ($actionId)', error: e);
        return formatReadableError(e);
      }
    }
    const msg = '当前未连接 DSH 主机，无法执行扩展操作';
    showToast('$msg：$actionId', tone: ToastTone.warn);
    return msg;
  }

  Future<List<Map<String, dynamic>>?> _prepareAttachmentsForUpload(
    GbridgeClient client,
    String sessionId,
    List<ComposerAttachment> attached, {
    required int gen,
    bool updateSendStage = true,
  }) async {
    const inlineImageMimes = {'image/png', 'image/jpeg', 'image/webp', 'image/gif'};
    final validAttached = attached.where((a) => a.bytes != null && a.bytes!.isNotEmpty).toList(growable: false);
    if (validAttached.isEmpty) return const <Map<String, dynamic>>[];

    final total = validAttached.length;
    var done = 0;
    if (updateSendStage && _isStillLive(client, gen: gen) && state.activeSessionId == sessionId) {
      state = state.copyWith(
        sendStage: SendStage.uploadingAttachments,
        uploadDoneCount: 0,
        uploadTotalCount: total,
      );
    }

    String? failedName;
    Object? failedErr;
    final results = await Future.wait<Map<String, dynamic>?>(
      validAttached.map((a) async {
        var normMime = a.mimeType.trim().toLowerCase();
        if (normMime == 'image/jpg') normMime = 'image/jpeg';
        final rawBytes = a.bytes!;
        if (inlineImageMimes.contains(normMime)) {
          final encoded = rawBytes.length > 64 * 1024
              ? await compute(_encodeBase64Isolate, rawBytes)
              : base64Encode(rawBytes);
          done += 1;
          if (updateSendStage && _isStillLive(client, gen: gen) && state.activeSessionId == sessionId) {
            state = state.copyWith(uploadDoneCount: done, uploadTotalCount: total);
          }
          return {
            'type': 'image',
            'mediaType': normMime,
            'mimeType': normMime,
            'data': encoded,
            'name': a.name,
            'size': a.sizeBytes,
          };
        }
        try {
          final resBytes = await client.uploadBinary(
            rawBytes,
            filename: a.name,
            sessionId: sessionId,
            contentType: normMime.isNotEmpty ? normMime : 'application/octet-stream',
          );
          String? receiptId;
          final decoded = jsonDecode(utf8.decode(resBytes));
          if (decoded is Map) {
            final up = decoded['upload'] ?? decoded['value'] ?? decoded;
            if (up is Map) {
              receiptId =
                  (up['receiptId'] ?? up['attachmentId'] ?? up['id'] ?? up['fileId'])?.toString();
            }
          }
          if (receiptId == null || receiptId.isEmpty) {
            throw StateError('主机未返回文件凭证 (receiptId)');
          }
          done += 1;
          if (updateSendStage && _isStillLive(client, gen: gen) && state.activeSessionId == sessionId) {
            state = state.copyWith(uploadDoneCount: done, uploadTotalCount: total);
          }
          return {
            'type': 'file',
            'name': a.name,
            'mimeType': normMime.isNotEmpty ? normMime : a.mimeType,
            'size': a.sizeBytes,
            'receiptId': receiptId,
          };
        } catch (e) {
          failedName ??= a.name;
          failedErr ??= e;
          return null;
        }
      }),
    );

    if (failedErr != null || results.any((r) => r == null)) {
      if (_isStillLive(client, gen: gen)) {
        if (updateSendStage && state.activeSessionId == sessionId) {
          state = state.copyWith(
            sendStage: SendStage.idle,
            uploadDoneCount: 0,
            uploadTotalCount: 0,
          );
        }
        showError('上传附件 ${failedName ?? ''} 失败，已保留待发附件', error: failedErr);
      }
      return null;
    }
    return results.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Messaging, Slash Execution & Interactions
  // ---------------------------------------------------------------------------
  Future<bool> sendPrompt(
    String text, {
    String mode = 'auto',
    List<Map<String, dynamic>>? references,
    bool includePendingAttachments = true,
    List<ComposerAttachment>? explicitAttachments,
  }) async {
    final trimmed = text.trim();
    final hasExplicitAttachments = explicitAttachments != null && explicitAttachments.isNotEmpty;
    final hasAttachments =
        hasExplicitAttachments || (includePendingAttachments && state.pendingAttachments.isNotEmpty);
    if (trimmed.isEmpty && !hasAttachments) return false;

    // Built-in instant slash commands handled seamlessly on mobile
    if (trimmed == '/stop' || trimmed == '/cancel') {
      if (state.isStreaming) {
        cancelStreaming();
      } else {
        showToast('当前没有正在生成的回复', tone: ToastTone.info);
      }
      return true;
    }
    if (trimmed == '/compact' || trimmed.startsWith('/compact ')) {
      final focus = trimmed.length > 8 ? trimmed.substring(8).trim() : null;
      await compactContext(focus: focus);
      return true;
    }
    if (state.isCompactingContext) {
      showToast('正在精简上下文，请稍候片刻再发送', tone: ToastTone.info);
      return false;
    }
    if (trimmed == '/new') {
      startNewChat();
      return true;
    }
    if (trimmed == '/plan') {
      await setPlanMode(!state.planMode);
      return true;
    }
    if (trimmed == '/plan on') {
      await setPlanMode(true);
      return true;
    }
    if (trimmed == '/plan off') {
      await setPlanMode(false);
      return true;
    }
    if (trimmed == '/fork') {
      if (state.activeSession == null) {
        showToast('当前尚无对话可分叉，请先发送一条消息', tone: ToastTone.info);
        return true;
      }
      await forkActiveSession();
      return true;
    }
    if (trimmed == '/export') {
      if (state.activeSession == null) {
        showToast('当前尚无对话可导出', tone: ToastTone.info);
        return true;
      }
      await exportActiveSession();
      return true;
    }
    if (trimmed == '/status') {
      final h = state.activeHost;
      final nsCount = state.effectiveDshNamespaces.length;
      final epCount = state.liveCapabilities?.endpointsCount ?? 0;
      showToast('${h.name} · DSH v${h.dshVersion} · $nsCount 组配置 · $epCount RPC', tone: ToastTone.info);
      return true;
    }
    // When offline, gracefully handle `/goal` locally; when connected, let DSH's native
    // `/goal [pause|resume|clear|edit ...|<objective>]` slash command run directly below!
    if ((trimmed == '/goal' || trimmed.startsWith('/goal ')) && _liveClient == null) {
      final goalText = trimmed.length > 5 ? trimmed.substring(5).trim() : '';
      if (goalText.isNotEmpty) {
        await addGoal(goalText, '完成后逐项自测并输出验证结果');
      } else {
        showToast('请输入目标内容，例如 /goal 优化启动速度', tone: ToastTone.info);
      }
      return true;
    }
    // Route known `/...` slash commands & `/skill:...` directly through DSH `commands/execute`
    // when connected, without hijacking Unix paths like `/README.md please review`.
    final slashClient = _liveClient;
    final slashToken = RegExp(r'^(/[a-zA-Z0-9_:.-]+)(?:\s|$)').firstMatch(trimmed)?.group(1)?.toLowerCase();
    const knownBuiltInSlash = <String>{
      '/new',
      '/clear',
      '/compact',
      '/fork',
      '/export',
      '/help',
      '/goal',
      '/status',
      '/plan',
      '/model',
      '/reset',
      '/stop',
      '/cancel',
      '/review',
      '/doctor',
      '/init',
      '/memory',
      '/mcp',
      '/skills',
    };
    final looksLikeSlashCommand = slashToken != null &&
        (slashToken.startsWith('/skill:') ||
            knownBuiltInSlash.contains(slashToken) ||
            state.slashCommands.any((c) => c.command.toLowerCase() == slashToken));
    if (looksLikeSlashCommand && !trimmed.contains('\n') && slashClient != null) {
      final slashGen = _hostConnectGen;
      final slashSessionKey = _attachmentsScopeKey(state.activeHostId, state.activeSessionId);
      final slashLockKey = '$slashGen::$slashSessionKey';
      if (!_inFlightSendKeys.add(slashLockKey)) {
        return false;
      }
      try {
        var sid = state.activeSessionId;
        if (sid == null) {
          try {
            final activeWsItem = state.activeWorkspaceItem;
            final rawCwd = activeWsItem?.path;
            final activeCwd = (rawCwd != null &&
                    rawCwd.isNotEmpty &&
                    !(rawCwd == '/root' && state.isActiveHostDesktop))
                ? rawCwd
                : null;
            final effModel = state.effectiveActiveModelEntry;
            final effProvider = state.activeModelProvider.isNotEmpty
                ? state.activeModelProvider
                : (effModel?.providerId ?? '');
            final effModelId = state.activeModelId.isNotEmpty
                ? state.activeModelId
                : (effModel?.id ?? '');
            final effEffortId = state.modelEffortId.isNotEmpty
                ? state.modelEffortId
                : (effModel?.defaultEffort ?? '');
            final created = await slashClient.createSession(
              workspaceId: activeWsItem?.explicit == true ? activeWsItem!.id : null,
              cwd: activeWsItem?.explicit == true ? null : activeCwd,
              title: trimmed,
              presetId: state.activePresetId,
              permission: state.activePermissionId,
              provider: effProvider.isEmpty ? null : effProvider,
              model: effModelId.isEmpty ? null : effModelId,
              reasoningEffort: effEffortId.isEmpty ? null : effEffortId,
            );
            if (!_isStillLive(slashClient, gen: slashGen)) return false;
            sid = created.id;
            state = state.copyWith(
              activeSessionId: sid,
              sessions: [
                ChatSessionItem(
                  id: sid,
                  title: trimmed,
                  group: '今天',
                  workspaceId: created.workspaceId,
                  workspaceName: activeWsItem?.name,
                  cwd: created.cwd ?? activeCwd,
                  updatedAt: DateTime.now().millisecondsSinceEpoch,
                ),
                for (final s in state.sessions)
                  if (s.id != sid) s,
              ],
            );
            _saveCurrentHostContext();
            slashClient.stream.subscribe('session:$sid');
          } catch (e) {
            if (_isStillLive(slashClient, gen: slashGen)) showError('执行斜杠指令 $trimmed 失败', error: e);
            return false;
          }
        }
        if (!sid.startsWith('pending-session-')) {
          try {
            final resp = await slashClient.executeSlashCommand(sid, command: trimmed);
            if (!_isStillLive(slashClient, gen: slashGen)) return true;
            final res = resp['result'];
            final msg = (resp['text'] ??
                    (res is Map
                        ? (res['text'] ?? res['message'] ?? res['output'] ?? res['summary'])
                        : res) ??
                    '')
                .toString()
                .trim();
            if (resp['ok'] == false) {
              showError('斜杠指令 $trimmed 未执行', error: msg.isNotEmpty ? msg : '主机返回错误');
              return false;
            }
            showToast(msg.isNotEmpty ? msg : '已执行指令 $trimmed', tone: ToastTone.info);
            unawaited(_syncLiveSessionBundle(sid, jumpToBottomOnLoad: false));
            return true;
          } catch (e) {
            if (!_isStillLive(slashClient, gen: slashGen)) return false;
            showError('执行斜杠指令 $trimmed 失败', error: e);
            return false;
          }
        }
      } finally {
        _inFlightSendKeys.remove(slashLockKey);
      }
    }

    if (state.isStreaming && (mode == 'queue' || mode == 'steer')) {
      return enqueueMessage(trimmed, mode: mode, references: references);
    }
    if (state.isStreaming && mode == 'auto') {
      final convNs = state.dshNamespaces.where((n) => n.ns == 'ui-conversation').firstOrNull;
      final busyEnter = convNs?.value['busyEnter']?.toString().trim().toLowerCase();
      final effectiveBusyMode = (busyEnter == 'queue' || busyEnter == 'steer') ? busyEnter! : 'queue';
      return enqueueMessage(trimmed, mode: effectiveBusyMode, references: references);
    }
    final sendGen = _hostConnectGen;
    final sendSessionKey = _attachmentsScopeKey(state.activeHostId, state.activeSessionId);
    final sendLockKey = '$sendGen::$sendSessionKey';
    final sendClient = _liveClient;
    final sendBootstrap = _bootstrapClient;
    if (!_inFlightSendKeys.add(sendLockKey)) {
      return false;
    }
    final sendRunId = ++_sendRunSeq;
    var trackedSessionId = '';

    try {
      final liveTurnsBeforeSend = _turnReducer.turns.isNotEmpty ? _turnReducer.turns : state.turns;
      final initialPlanMode = state.planMode;
      _clearPendingStreamCoalesce();
      _cancelSuppressUntilMs = 0;
      _lastLiveTpsEmitAt = null;
      final runId = ++_streamRunId;
      final attached = hasExplicitAttachments
          ? List<ComposerAttachment>.of(explicitAttachments)
          : (includePendingAttachments
              ? List<ComposerAttachment>.of(state.pendingAttachments)
              : const <ComposerAttachment>[]);
      final stagedGoals = state.activeSessionId == null
          ? List<SessionGoalRecord>.of(state.goals)
          : const <SessionGoalRecord>[];

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final turnId = 'client-turn-$nowMs';
      final previewRefs = [
        for (final a in attached)
          {
            'name': a.name,
            'mimeType': a.mimeType,
            'size': a.sizeBytes,
            if (a.bytes != null && a.bytes!.isNotEmpty) 'bytes': a.bytes,
          },
      ];
      final initialTurn = NormalizedTurn(
        turnId: turnId,
        status: 'streaming',
        userMessage: NormalizedUserMessage(
          id: 'u-$turnId',
          text: trimmed,
          attachments: previewRefs,
          references: references ?? const [],
          maskedRanges: VanillaDshNormalizer.detectSecretRanges(trimmed)
              .map(MaskedRange.fromJson)
              .toList(growable: false),
          createdAt: nowMs,
        ),
        steps: const [],
      );

      // Vanilla Direct Mode does not expose `/gbridge/v1/uploads`; never silently drop user files!
      if (sendClient == null && sendBootstrap != null && attached.isNotEmpty) {
        showToast('官方直连模式暂不支持发送附件，请先安装连接助手插件或移除附件后重试', tone: ToastTone.warn);
        return false;
      }

      // Disconnected offline honest notice: keep ONLY ONE editable draft in the composer
      // (zero duplicate user bubble / competing 5-button error card!), persist the unsent outbox
      // entry, and display a persistent "未发送" status strip whose primary CTA opens Host Connect!
      if (sendClient == null && sendBootstrap == null) {
        _recordOutboxEntry(
          id: turnId,
          hostId: state.activeHostId,
          sessionId: state.activeSessionId ?? '',
          text: trimmed,
          mode: mode,
          status: 'unsent',
          errorMessage: 'host_offline',
        );
        state = state.copyWith(
          offlineUnsentNotice: '未发送 · 尚未连接到运行中的 DSH 引擎，已保留草稿',
          clearSessionLoadError: true,
          isStreaming: false,
          sendStage: SendStage.idle,
        );
        return false;
      }
      if (state.offlineUnsentNotice != null) {
        state = state.copyWith(clearOfflineUnsentNotice: true);
      }

      final isBrandNewSession = state.activeSessionId == null;
      var sessionId = state.activeSessionId ?? 'pending-session-$nowMs';
      final activeWsItem = state.activeWorkspaceItem;
      final rawCwd = activeWsItem?.path ??
          (state.activeWorkspace.startsWith('/') ? state.activeWorkspace : null);
      // Never pass a stale mobile '/root' fixture path to a macOS/desktop host!
      final activeCwd = (rawCwd != null &&
              rawCwd.isNotEmpty &&
              !(rawCwd == '/root' && state.isActiveHostDesktop))
          ? rawCwd
          : null;
      String? createdWorkspaceId = activeWsItem?.explicit == true ? activeWsItem!.id : null;
      final titleSource = trimmed.isNotEmpty ? trimmed : (attached.isNotEmpty ? attached.first.name : '新对话');
      final newTitle = titleSource.length > 24 ? '${titleSource.substring(0, 24)}…' : titleSource;

      // FRAME-1 INSTANT OPTIMISTIC UI: Immediately leave Empty State and show the user's bubble!
      // Keep `pendingAttachments` until uploads succeed so failures never lose user files.
      final prevTurnsSnapshot = liveTurnsBeforeSend;
      final settledPrevTurns = mode == 'interrupt'
          ? [
              for (final t in liveTurnsBeforeSend)
                if (t.status == 'streaming')
                  (() {
                    _locallyCancelledTurnIds.add(t.turnId);
                    if (_locallyCancelledTurnIds.length > 32) {
                      _locallyCancelledTurnIds.remove(_locallyCancelledTurnIds.first);
                    }
                    return t.copyWith(
                      status: 'cancelled',
                      steps: [
                        for (final s in t.steps)
                          (s is ToolStep && s.status == 'running') ? s.copyWith(status: 'cancelled') : s,
                      ],
                    );
                  })()
                else
                  t,
            ]
          : liveTurnsBeforeSend;
      final optimisticSessions = isBrandNewSession
          ? [
              ChatSessionItem(
                id: sessionId,
                title: newTitle,
                group: '今天',
                workspaceId: createdWorkspaceId,
                workspaceName: activeWsItem?.name ?? (activeCwd != null ? _basenamePath(activeCwd) : null),
                cwd: activeCwd,
                updatedAt: nowMs,
                running: true,
              ),
              ...state.sessions,
            ]
          : [
              for (final s in state.sessions) s.id == sessionId ? s.copyWith(running: true) : s,
            ];

      final nextTurns = [...settledPrevTurns, initialTurn];
      trackedSessionId = sessionId;
      _activeSendRunIdBySession[trackedSessionId] = sendRunId;
      _turnReducer.replaceAll(nextTurns);
      final initialSendStage = isBrandNewSession
          ? SendStage.creatingSession
          : (attached.isNotEmpty ? SendStage.uploadingAttachments : SendStage.sending);
      state = state.copyWith(
        sessions: optimisticSessions,
        activeSessionId: sessionId,
        turns: nextTurns,
        queuedMessages: mode == 'interrupt' ? const [] : state.queuedMessages,
        clearSessionLoadError: true,
        sessionTelemetry: state.sessionTelemetry.copyWith(clearLive: true),
        isStreaming: true,
        sendStage: initialSendStage,
        uploadDoneCount: 0,
        uploadTotalCount: attached.length,
        isStopping: false,
        streamStalled: false,
        scrollSignal: state.scrollSignal + 1,
      );
      _armStreamWatchdog();

      // 1. Create the live session FIRST so file uploads have a real `sessionId`!
      if (isBrandNewSession) {
        if (sendClient != null) {
          final prevTempId = sessionId;
          try {
            final effModel = state.effectiveActiveModelEntry;
            final effProvider = state.activeModelProvider.isNotEmpty
                ? state.activeModelProvider
                : (effModel?.providerId ?? '');
            final effModelId = state.activeModelId.isNotEmpty
                ? state.activeModelId
                : (effModel?.id ?? '');
            final effEffortId = state.modelEffortId.isNotEmpty
                ? state.modelEffortId
                : (effModel?.defaultEffort ?? '');
            final created = await sendClient.createSession(
              workspaceId: createdWorkspaceId,
              cwd: createdWorkspaceId == null ? activeCwd : null,
              // Omit eager title so DSH avoids a blocking pre-send `session/rename` RPC
              // and lets AI auto-titling replace the local optimistic snippet after Turn 1.
              presetId: state.activePresetId,
              permission: state.activePermissionId,
              provider: effProvider.isEmpty ? null : effProvider,
              model: effModelId.isEmpty ? null : effModelId,
              reasoningEffort: effEffortId.isEmpty ? null : effEffortId,
            );
            if (!_isStillLive(sendClient, gen: sendGen)) return false;
            if (created.setupWarnings.isNotEmpty) {
              final stepLabels = created.setupWarnings
                  .map((w) => switch (w['step']) {
                        'permission' => '权限档位',
                        'model' => '模型选择',
                        'title' => '会话标题',
                        _ => w['step'] ?? '配置',
                      })
                  .toSet()
                  .join('、');
              showToast(
                '会话已创建，但 $stepLabels 未成功应用，请在会话内重新确认',
                tone: ToastTone.warn,
              );
            }
            final stillOnTemp = state.activeSessionId == prevTempId;
            if (created.id.isNotEmpty) sessionId = created.id;
            if (trackedSessionId != sessionId) {
              if (_activeSendRunIdBySession[trackedSessionId] == sendRunId) {
                _activeSendRunIdBySession.remove(trackedSessionId);
              }
              trackedSessionId = sessionId;
              _activeSendRunIdBySession[trackedSessionId] = sendRunId;
            }
            // Migrate any draft typed during session creation from temp ID -> real UUID!
            final tempDraft = getComposerDraftForScope(state.activeHostId, prevTempId);
            if (tempDraft.isNotEmpty && sessionId != prevTempId) {
              setComposerDraftForScope(state.activeHostId, sessionId, tempDraft);
              setComposerDraftForScope(state.activeHostId, prevTempId, '');
            }
            if (created.workspaceId != null && created.workspaceId!.isNotEmpty) {
              createdWorkspaceId = created.workspaceId;
            }
            // Only abort if the user explicitly cancelled or deleted this session; switching
            // to another session in the sidebar must let this background send finish cleanly!
            final wasAborted = _cancelledSendRunIds.contains(sendRunId);
            // ALWAYS reconcile `prevTempId -> realUuid` even if aborted/cancelled mid-flight,
            // so `activeSessionId` / `sessions` NEVER stay wedged on a 404 `pending-session-*`!
            final seenIds = <String>{};
            final updatedSessions = <ChatSessionItem>[];
            var replaced = false;
            for (final s in state.sessions) {
              if (s.id == prevTempId || s.id == sessionId) {
                if (!replaced) {
                  replaced = true;
                  seenIds.add(sessionId);
                  updatedSessions.add(
                    s.copyWith(
                      id: sessionId,
                      title: s.title.isNotEmpty ? s.title : newTitle,
                      workspaceId: createdWorkspaceId ?? s.workspaceId,
                      cwd: created.cwd ?? s.cwd,
                      running: wasAborted ? false : true,
                    ),
                  );
                }
              } else if (seenIds.add(s.id)) {
                updatedSessions.add(s);
              }
            }
            if (!replaced) {
              updatedSessions.insert(
                0,
                ChatSessionItem(
                  id: sessionId,
                  title: newTitle,
                  group: '今天',
                  workspaceId: createdWorkspaceId,
                  workspaceName: activeWsItem?.name,
                  cwd: created.cwd ?? activeCwd,
                  updatedAt: DateTime.now().millisecondsSinceEpoch,
                  running: !wasAborted,
                ),
              );
            }
            state = state.copyWith(
              activeSessionId: stillOnTemp ? sessionId : state.activeSessionId,
              sessions: updatedSessions,
              sendStage: stillOnTemp
                  ? (wasAborted
                      ? SendStage.idle
                      : (attached.isNotEmpty ? SendStage.uploadingAttachments : SendStage.sending))
                  : state.sendStage,
            );
            _sessionTurnsMemory.remove(prevTempId);
            if (stillOnTemp) {
              _saveCurrentHostContext();
            }
            if (wasAborted) {
              if (stillOnTemp) {
                _cacheSessionTurns(sessionId, state.turns);
              }
              return stillOnTemp && state.turns.any((t) => t.stableKey == initialTurn.stableKey);
            }
            if (stillOnTemp) {
              sendClient.stream.subscribe('session:$sessionId', force: true);
            } else {
              _cacheSessionTurns(sessionId, nextTurns);
            }
            final postCreateTasks = <Future<Object?>>[];
            if (initialPlanMode) {
              postCreateTasks.add(
                sendClient
                    .executeSlashCommand(sessionId, command: '/plan on')
                    .catchError((_) => <String, dynamic>{}),
              );
            }
            for (final g in stagedGoals) {
              postCreateTasks.add(
                sendClient
                    .mutateSessionGoal(
                      sessionId,
                      action: 'create',
                      payload: {
                        'objective': g.title,
                        'title': g.title,
                        'criteria': g.criteria,
                      },
                    )
                    .catchError((_) => <String, dynamic>{}),
              );
            }
            if (postCreateTasks.isNotEmpty) {
              await Future.wait<Object?>(postCreateTasks);
              if (!_isStillLive(sendClient, gen: sendGen)) return false;
              if (_cancelledSendRunIds.contains(sendRunId)) {
                return state.activeSessionId == sessionId &&
                    state.turns.any((t) => t.stableKey == initialTurn.stableKey);
              }
            }
          } catch (e) {
            if (!_isStillLive(sendClient, gen: sendGen)) return false;
            _sessionTurnsMemory.remove(prevTempId);
            final stillOnTempErr = state.activeSessionId == prevTempId;
            final cleanedSessions = state.sessions
                .where((s) => s.id != prevTempId)
                .toList(growable: false);
            if (stillOnTempErr) {
              _turnReducer.replaceAll(prevTurnsSnapshot);
              _disarmStreamWatchdog();
            }
            state = state.copyWith(
              sessions: cleanedSessions,
              clearActiveSession: stillOnTempErr,
              turns: stillOnTempErr ? prevTurnsSnapshot : state.turns,
              isStreaming: stillOnTempErr ? false : state.isStreaming,
              sendStage: stillOnTempErr ? SendStage.idle : state.sendStage,
              uploadDoneCount: stillOnTempErr ? 0 : state.uploadDoneCount,
              uploadTotalCount: stillOnTempErr ? 0 : state.uploadTotalCount,
              streamTick: stillOnTempErr ? state.streamTick + 1 : state.streamTick,
            );
            showError('创建 DSH 会话失败', error: e);
            return false;
          }
        } else if (sendBootstrap != null) {
          final prevTempId = sessionId;
          try {
            final created = await sendBootstrap.bootstrap.createVanillaSession(title: newTitle);
            if (!mounted || sendGen != _hostConnectGen || !identical(_bootstrapClient, sendBootstrap)) {
              return false;
            }
            if (created.id.isNotEmpty) sessionId = created.id;
            final stillOnTemp = state.activeSessionId == prevTempId;
            _sessionTurnsMemory.remove(prevTempId);
            if (!stillOnTemp) {
              _cacheSessionTurns(sessionId, nextTurns);
            }
            state = state.copyWith(
              activeSessionId: stillOnTemp ? sessionId : state.activeSessionId,
              sessions: [
                for (final s in state.sessions)
                  s.id == prevTempId ? s.copyWith(id: sessionId) : s,
              ],
            );
          } catch (e) {
            if (!mounted || sendGen != _hostConnectGen || !identical(_bootstrapClient, sendBootstrap)) {
              return false;
            }
            _sessionTurnsMemory.remove(prevTempId);
            final stillOnTempErr = state.activeSessionId == prevTempId;
            final cleanedSessions = state.sessions
                .where((s) => s.id != prevTempId)
                .toList(growable: false);
            if (stillOnTempErr) {
              _turnReducer.replaceAll(prevTurnsSnapshot);
            }
            state = state.copyWith(
              sessions: cleanedSessions,
              clearActiveSession: stillOnTempErr,
              turns: stillOnTempErr ? prevTurnsSnapshot : state.turns,
              isStreaming: stillOnTempErr ? false : state.isStreaming,
            );
            showError('创建基础模式会话失败', error: e);
            return false;
          }
        }
      }

      // 2. Prepare DSH V4 multimodal image payloads & upload binary files with real `sessionId`
      List<Map<String, dynamic>> uploadedRefs;
      if (sendClient != null && attached.isNotEmpty) {
        final prepared = await _prepareAttachmentsForUpload(
          sendClient,
          sessionId,
          attached,
          gen: sendGen,
        );
        if (!_isStillLive(sendClient, gen: sendGen)) return false;
        if (_cancelledSendRunIds.contains(sendRunId)) {
          return state.activeSessionId == sessionId &&
              state.turns.any((t) => t.stableKey == initialTurn.stableKey);
        }
        if (prepared == null) {
          final onTarget = state.activeSessionId == sessionId;
          if (onTarget) {
            _turnReducer.replaceAll(prevTurnsSnapshot);
            _disarmStreamWatchdog();
          } else {
            _cacheSessionTurns(sessionId, prevTurnsSnapshot);
          }
          state = state.copyWith(
            sessions: [
              for (final s in state.sessions)
                s.id == sessionId ? s.copyWith(running: false) : s,
            ],
            turns: onTarget ? prevTurnsSnapshot : state.turns,
            isStreaming: onTarget ? false : state.isStreaming,
            sendStage: onTarget ? SendStage.idle : state.sendStage,
            uploadDoneCount: onTarget ? 0 : state.uploadDoneCount,
            uploadTotalCount: onTarget ? 0 : state.uploadTotalCount,
          );
          return false;
        }
        uploadedRefs = prepared;
      } else {
        uploadedRefs = previewRefs;
      }

      if (mounted &&
          sendGen == _hostConnectGen &&
          attached.isNotEmpty &&
          !hasExplicitAttachments &&
          (sendClient != null || sendBootstrap != null)) {
        final sentIds = attached.map((a) => a.id).toSet();
        state = state.copyWith(
          pendingAttachments: state.pendingAttachments
              .where((a) => !sentIds.contains(a.id))
              .toList(growable: false),
        );
        // Strip already-sent attachments from stashed scope memory so returning to the session
        // never resurrects stale attachment bytes!
        for (final scopeKey in _sessionAttachmentsMemory.keys.toList(growable: false)) {
          final existingList = _sessionAttachmentsMemory[scopeKey];
          if (existingList == null) continue;
          final remaining = existingList
              .where((a) => !sentIds.contains(a.id))
              .toList(growable: false);
          if (remaining.isEmpty) {
            _sessionAttachmentsMemory.remove(scopeKey);
          } else if (remaining.length != existingList.length) {
            _sessionAttachmentsMemory[scopeKey] = List<ComposerAttachment>.unmodifiable(remaining);
          }
        }
      }

      if (sendClient != null) {
        if (!_isStillLive(sendClient, gen: sendGen)) return false;
        if (_cancelledSendRunIds.contains(sendRunId)) {
          return state.activeSessionId == sessionId &&
              state.turns.any((t) => t.stableKey == initialTurn.stableKey);
        }
        try {
          // Wait briefly for any in-flight remote cancel on this session so a delayed cancel
          // RPC can never land after this new prompt and kill it on the server.
          final pendingCancel = _inFlightCancelBySession[sessionId];
          if (pendingCancel != null) {
            await pendingCancel.timeout(const Duration(milliseconds: 1800), onTimeout: () {});
            if (!_isStillLive(sendClient, gen: sendGen) || _cancelledSendRunIds.contains(sendRunId)) {
              return false;
            }
          }
          _cancelledOptimisticUntilMs = 0;
          _cancelledOptimisticSessionId = null;
          if (state.activeSessionId == sessionId) {
            state = state.copyWith(
              sendStage: SendStage.sending,
              uploadDoneCount: 0,
              uploadTotalCount: 0,
            );
            if (!isBrandNewSession) {
              sendClient.stream.subscribe('session:$sessionId', force: true);
            }
          }
          _recordOutboxEntry(
            id: turnId,
            hostId: state.activeHostId,
            sessionId: sessionId,
            text: trimmed,
            mode: mode,
            status: 'sending',
          );
          await sendClient.sendMessage(
            sessionId,
            text: trimmed,
            mode: mode,
            attachments: uploadedRefs.isEmpty ? null : uploadedRefs,
            references: references != null && references.isNotEmpty ? references : null,
            clientRequestId: turnId,
          );
          _clearOutboxEntry(turnId);
          if (_isStillLive(sendClient, gen: sendGen) &&
              runId == _streamRunId &&
              state.activeSessionId == sessionId &&
              state.isStreaming &&
              state.sendStage == SendStage.sending) {
            state = state.copyWith(sendStage: SendStage.awaitingFirstToken);
          }
          return true;
        } catch (e) {
          if (!_isStillLive(sendClient, gen: sendGen)) return false;
          final errDetail = formatReadableError(e);
          _recordOutboxEntry(
            id: turnId,
            hostId: state.activeHostId,
            sessionId: sessionId,
            text: trimmed,
            mode: mode,
            status: 'failed',
            errorMessage: errDetail,
          );
          final failedTurn = initialTurn.copyWith(
            status: 'error',
            errorMessage: errDetail,
            steps: const [],
            assistantText: '',
          );
          final onTarget = state.activeSessionId == sessionId;
          if (onTarget) {
            _disarmStreamWatchdog();
            final currentTurns = _turnReducer.turns.isNotEmpty ? _turnReducer.turns : state.turns;
            final errTurns = [
              for (final t in currentTurns)
                (t.turnId == turnId || t.stableKey == initialTurn.stableKey) ? failedTurn : t,
            ];
            _turnReducer.replaceAll(errTurns);
            state = state.copyWith(
              sessions: [
                for (final s in state.sessions) s.id == sessionId ? s.copyWith(running: false) : s,
              ],
              turns: errTurns,
              isStreaming: false,
              sendStage: SendStage.idle,
              uploadDoneCount: 0,
              uploadTotalCount: 0,
              streamTick: state.streamTick + 1,
            );
          } else {
            final cached = _sessionTurnsMemory[sessionId];
            if (cached != null) {
              _cacheSessionTurns(sessionId, [
                for (final t in cached)
                  (t.turnId == turnId || t.stableKey == initialTurn.stableKey) ? failedTurn : t,
              ]);
            }
            state = state.copyWith(
              sessions: [
                for (final s in state.sessions) s.id == sessionId ? s.copyWith(running: false) : s,
              ],
            );
          }
          showError('发送消息失败（已保留草稿）', error: e);
          return false;
        }
      } else if (sendBootstrap != null) {
        if (!mounted || sendGen != _hostConnectGen || !identical(_bootstrapClient, sendBootstrap)) {
          return false;
        }
        try {
          _recordOutboxEntry(
            id: turnId,
            hostId: state.activeHostId,
            sessionId: sessionId,
            text: trimmed,
            mode: mode,
            status: 'sending',
          );
          await sendBootstrap.bootstrap.sendVanillaPrompt(sessionId, trimmed);
          _clearOutboxEntry(turnId);
          if (mounted &&
              sendGen == _hostConnectGen &&
              state.activeSessionId == sessionId &&
              state.isStreaming) {
            state = state.copyWith(sendStage: SendStage.awaitingFirstToken);
          }
          return true;
        } catch (e) {
          if (!mounted || sendGen != _hostConnectGen || !identical(_bootstrapClient, sendBootstrap)) {
            return false;
          }
          _recordOutboxEntry(
            id: turnId,
            hostId: state.activeHostId,
            sessionId: sessionId,
            text: trimmed,
            mode: mode,
            status: 'failed',
            errorMessage: formatReadableError(e),
          );
          final onTarget = state.activeSessionId == sessionId;
          showError('发送消息失败（已保留草稿）', error: e);
          if (onTarget) {
            _disarmStreamWatchdog();
            _turnReducer.replaceAll(prevTurnsSnapshot);
            state = state.copyWith(
              sessions: [
                for (final s in state.sessions) s.id == sessionId ? s.copyWith(running: false) : s,
              ],
              turns: prevTurnsSnapshot,
              isStreaming: false,
              sendStage: SendStage.idle,
              uploadDoneCount: 0,
              uploadTotalCount: 0,
              streamTick: state.streamTick + 1,
            );
          }
          return false;
        }
      }

      // Disconnected offline honest notice (never pretend an LLM replied when no DSH host is connected!)
      if (!mounted || sendGen != _hostConnectGen) return false;
      _recordOutboxEntry(
        id: turnId,
        hostId: state.activeHostId,
        sessionId: sessionId,
        text: trimmed,
        mode: mode,
        status: 'failed',
        errorMessage: 'host_offline',
      );
      final offlineTurn = initialTurn.copyWith(
        status: 'error',
        errorCode: 'host_offline',
        errorMessage: '当前尚未连接到运行中的 DSH 引擎，请先在「主机与环境」连接本机或远程主机后重试。',
        steps: const [],
        assistantText: '',
      );
      final offlineTurns = [
        for (final t in state.turns) t.turnId == turnId ? offlineTurn : t,
      ];
      _turnReducer.replaceAll(offlineTurns);
      state = state.copyWith(
        sessions: [
          for (final s in state.sessions) s.id == sessionId ? s.copyWith(running: false) : s,
        ],
        turns: offlineTurns,
        isStreaming: false,
        streamTick: state.streamTick + 1,
      );
      showToast('尚未连接 DSH 主机，已保留草稿并等待重连', tone: ToastTone.warn);
      return false;
    } finally {
      if (trackedSessionId.isNotEmpty &&
          _activeSendRunIdBySession[trackedSessionId] == sendRunId) {
        _activeSendRunIdBySession.remove(trackedSessionId);
      }
      _cancelledSendRunIds.remove(sendRunId);
      _inFlightSendKeys.remove(sendLockKey);
    }
  }

  /// Centralized Retry / Regenerate flow that preserves attachments & `@file` references,
  /// removes stale local failed `client-turn-*` shells instead of piling up duplicates,
  /// enforces pre-flight host/auth/model checks, and optionally forks before an earlier turn.
  Future<bool> regenerateOrRetryTurn(
    NormalizedTurn turn, {
    bool forkBefore = false,
  }) async {
    final activeSendKey = _attachmentsScopeKey(state.activeHostId, state.activeSessionId);
    if (_inFlightSendKeys.contains('$_hostConnectGen::$activeSendKey')) {
      return false;
    }
    if (state.isStreaming) {
      showToast('正在生成回复，请先停止后再重试', tone: ToastTone.warn);
      return false;
    }
    if (_liveClient == null && _bootstrapClient == null) {
      showToast('当前尚未连接 DSH 主机，请先检查连接后再重试', tone: ToastTone.warn);
      return false;
    }
    if (state.activeHost.needsAuth || state.connectionPhase == ConnectionPhase.needsAuth) {
      showToast('当前主机需要身份验证，请先完成授权后再重试', tone: ToastTone.warn);
      return false;
    }
    if (!state.hasAvailableModels && _liveClient != null) {
      showToast('尚未配置可用模型渠道，请先配置模型后再重试', tone: ToastTone.warn);
      return false;
    }

    final userMsg = turn.userMessage;
    final prompt = userMsg?.text.trim() ?? '';
    final refs = userMsg?.references ?? const <Map<String, dynamic>>[];

    // Reconstruct attachments from in-memory bytes if this turn carried local attachments.
    final reconstructed = <ComposerAttachment>[];
    if (userMsg != null && userMsg.attachments.isNotEmpty) {
      for (var i = 0; i < userMsg.attachments.length; i++) {
        final raw = userMsg.attachments[i];
        final rawBytes = raw['bytes'] ?? raw['previewBytes'];
        Uint8List? bytes;
        if (rawBytes is Uint8List) {
          bytes = rawBytes;
        } else if (rawBytes is List<int>) {
          bytes = Uint8List.fromList(rawBytes);
        } else if (raw['data'] is String && (raw['data'] as String).isNotEmpty) {
          try {
            final b64 = raw['data'] as String;
            bytes = b64.length > 65536
                ? await compute(_decodeBase64Isolate, b64)
                : base64Decode(base64.normalize(b64));
          } catch (_) {}
        }
        if (bytes != null && bytes.isNotEmpty) {
          reconstructed.add(
            ComposerAttachment(
              id: 'retry-att-${DateTime.now().millisecondsSinceEpoch}-$i',
              name: (raw['name'] ?? 'attachment_$i').toString(),
              mimeType: (raw['mimeType'] ?? 'application/octet-stream').toString(),
              sizeBytes: (raw['size'] as num?)?.toInt() ?? bytes.length,
              bytes: bytes,
            ),
          );
        }
      }
    }

    if (prompt.isEmpty && reconstructed.isEmpty) {
      showToast('该消息仅含历史附件，无法自动重发，请重新选择附件发送', tone: ToastTone.warn);
      return false;
    }

    // Optional fork-before-turn so regenerating an earlier or tail turn branches cleanly without duplicates.
    if (forkBefore && state.activeSessionId != null) {
      final idx = state.turns.indexWhere(
        (t) => t.turnId == turn.turnId || t.stableKey == turn.stableKey,
      );
      if (idx > 0) {
        final forked = await forkActiveSession(
          turnId: state.turns[idx - 1].turnId,
          syncAfter: false,
        );
        if (!forked) return false;
      } else if (idx == 0 && !turn.turnId.startsWith('client-turn-')) {
        // Regenerating Turn 0 cleanly starts a fresh sibling session preserving workspace/model/preset
        // so the bad first reply is never left in LLM context.
        startNewChat();
      }
    }

    // Remove unsent local failed `client-turn-*` shell so retries never stack duplicate error cards,
    // keeping a snapshot so we restore it cleanly if `sendPrompt` fails before mounting the new turn.
    List<NormalizedTurn>? removedShellSnapshot;
    if (turn.turnId.startsWith('client-turn-') &&
        (turn.status == 'error' || turn.status == 'cancelled')) {
      removedShellSnapshot = List<NormalizedTurn>.of(state.turns);
      final cleaned = state.turns
          .where((t) => t.turnId != turn.turnId && t.stableKey != turn.stableKey)
          .toList(growable: false);
      _turnReducer.replaceAll(cleaned);
      state = state.copyWith(turns: cleaned);
    }

    final ok = await sendPrompt(
      prompt,
      references: refs.isNotEmpty ? refs : null,
      includePendingAttachments: false,
      explicitAttachments: reconstructed.isNotEmpty ? reconstructed : null,
    );
    if (!ok && removedShellSnapshot != null && mounted && !state.turns.any((t) => t.turnId == turn.turnId)) {
      _turnReducer.replaceAll(removedShellSnapshot);
      state = state.copyWith(turns: removedShellSnapshot);
    }
    return ok;
  }

  /// Continue generating from a stopped partial reply without discarding what was already produced.
  Future<bool> continueTurn(NormalizedTurn turn) async {
    final activeSendKey = _attachmentsScopeKey(state.activeHostId, state.activeSessionId);
    if (state.isStreaming ||
        state.isStopping ||
        _inFlightSendKeys.contains('$_hostConnectGen::$activeSendKey')) {
      return false;
    }
    final sample = turn.assistantText.trim().isNotEmpty
        ? turn.assistantText
        : (turn.userMessage?.text ?? '');
    final hasCjk = RegExp(r'[\u4E00-\u9FFF]').hasMatch(sample);
    return sendPrompt(
      hasCjk
          ? '请接着刚才中断的地方继续输出，不要重复前面已经生成的内容。'
          : 'Please continue from where you stopped without repeating what was already generated.',
      includePendingAttachments: false,
    );
  }

  /// Dismiss an unsent local failed/cancelled `client-turn-*` card from the transcript.
  void dismissLocalFailedTurn(String turnId) {
    if (!turnId.startsWith('client-turn-')) return;
    final nextTurns = state.turns
        .where((t) =>
            !(t.turnId == turnId && (t.status == 'error' || t.status == 'cancelled')))
        .toList(growable: false);
    if (nextTurns.length == state.turns.length) return;
    final sid = state.activeSessionId;
    if (sid != null) {
      _cacheSessionTurns(sid, nextTurns);
    }
    _turnReducer.replaceAll(nextTurns);
    state = state.copyWith(turns: nextTurns);
  }

  void cancelStreaming({bool announce = true}) {
    // Capture reducer's latest buffered streaming turns BEFORE clearing coalesce timer!
    final liveTurns = _turnReducer.turns.isNotEmpty ? _turnReducer.turns : state.turns;
    final queuedToClear = List<QueuedMessageItem>.of(state.queuedMessages);
    _clearPendingStreamCoalesce();
    _disarmStreamWatchdog();
    _lastLiveTpsEmitAt = null;
    final cancelRunId = ++_streamRunId;
    final sid = state.activeSessionId;
    if (sid != null) {
      final inFlight = _activeSendRunIdBySession[sid];
      if (inFlight != null) {
        _cancelledSendRunIds.add(inFlight);
      }
    }
    final client = _liveClient;
    final hasLiveRemoteCancel =
        sid != null && !sid.startsWith('pending-session-') && (client != null || _bootstrapClient != null);
    if (sid != null && !sid.startsWith('pending-session-')) {
      if (client != null) {
        final cancelFuture = () async {
          var cancelledOk = false;
          for (var attempt = 0; attempt < 2 && !cancelledOk; attempt++) {
            if (!mounted || !_isStillLive(client) || cancelRunId != _streamRunId) {
              break;
            }
            try {
              await client.cancelSession(sid).timeout(const Duration(seconds: 3));
              cancelledOk = true;
            } catch (_) {
              if (attempt == 0 && cancelRunId == _streamRunId) {
                await Future<void>.delayed(const Duration(milliseconds: 220));
              }
            }
          }
          if (mounted && _isStillLive(client) && cancelRunId == _streamRunId) {
            if (state.isStopping) {
              state = state.copyWith(isStopping: false);
            }
            if (!cancelledOk && announce) {
              showToast('主机停止指令未响应，请检查网络连接', tone: ToastTone.warn);
            }
          }
        }();
        _inFlightCancelBySession[sid] = cancelFuture;
        unawaited(
          cancelFuture.whenComplete(() {
            if (identical(_inFlightCancelBySession[sid], cancelFuture)) {
              _inFlightCancelBySession.remove(sid);
            }
          }),
        );
        for (final q in queuedToClear) {
          if (q.serverAcked || !q.id.startsWith('q-')) {
            unawaited(
              client
                  .updateQueue(sid, {'itemId': q.id, 'action': 'remove'})
                  .catchError((_) => <String, dynamic>{}),
            );
          }
        }
      } else if (_bootstrapClient != null) {
        final boot = _bootstrapClient!;
        final cancelFuture = boot.bootstrap
            .cancelVanillaSession(sid)
            .timeout(const Duration(seconds: 3))
            .then<void>((_) {}, onError: (_) {})
            .whenComplete(() {
          if (mounted && cancelRunId == _streamRunId && state.isStopping) {
            state = state.copyWith(isStopping: false);
          }
        });
        _inFlightCancelBySession[sid] = cancelFuture;
        unawaited(
          cancelFuture.whenComplete(() {
            if (identical(_inFlightCancelBySession[sid], cancelFuture)) {
              _inFlightCancelBySession.remove(sid);
            }
          }),
        );
      }
    }
    // Dismiss & best-effort cancel ONLY pending interactions belonging to the active session
    // (never wipe host-global Cordis requests belonging to another session!).
    final cancelledIds = <String>[];
    _pendingInteractionsById.removeWhere((id, item) {
      final itemSid = item.sessionId ?? item.payload['sessionId']?.toString();
      final matches = sid == null
          ? (itemSid == null || itemSid.isEmpty)
          : (itemSid == sid);
      if (matches) cancelledIds.add(id);
      return matches;
    });
    if (cancelledIds.isNotEmpty) {
      _interactionMutationSeq++;
    }
    if (client != null) {
      for (final id in cancelledIds) {
        unawaited(client.respondInteraction(id, decision: 'cancelled').catchError((_) => <String, dynamic>{}));
      }
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _cancelSuppressUntilMs = nowMs + 3000;
    var cancelledOptimistic = false;
    final updatedTurns = <NormalizedTurn>[];
    for (final t in liveTurns) {
      if (t.status == 'streaming') {
        if (t.turnId.startsWith('client-turn-')) {
          cancelledOptimistic = true;
        }
        _locallyCancelledTurnIds.add(t.turnId);
        if (_locallyCancelledTurnIds.length > 32) {
          _locallyCancelledTurnIds.remove(_locallyCancelledTurnIds.first);
        }
        updatedTurns.add(
          t.copyWith(
            status: 'cancelled',
            steps: [
              for (final s in t.steps)
                (s is ToolStep && s.status == 'running') ? s.copyWith(status: 'cancelled') : s,
            ],
          ),
        );
      } else {
        updatedTurns.add(t);
      }
    }
    if (cancelledOptimistic && sid != null) {
      _cancelledOptimisticUntilMs = nowMs + 2000;
      _cancelledOptimisticSessionId = sid;
    }
    _turnReducer.replaceAll(updatedTurns);
    final updatedSessions = [
      for (final s in state.sessions) s.id == sid ? s.copyWith(running: false) : s,
    ];

    // Preserve carefully typed queued follow-up prompts by restoring them into the composer draft
    // (appending cleanly if the composer already holds a draft so Stop NEVER loses user text!).
    var restoredQueueToDraft = false;
    if (queuedToClear.isNotEmpty) {
      final existingDraft = getComposerDraftForScope(state.activeHostId, sid).trim();
      final combinedQueued = queuedToClear
          .map((q) => q.text.trim())
          .where((t) => t.isNotEmpty && !t.startsWith('[附带'))
          .join('\n');
      if (combinedQueued.isNotEmpty) {
        final mergedDraft = existingDraft.isEmpty
            ? combinedQueued
            : '$existingDraft\n$combinedQueued';
        setComposerDraftForScope(state.activeHostId, sid, mergedDraft);
        restoredQueueToDraft = true;
      }
    }

    state = state.copyWith(
      sessions: updatedSessions,
      turns: updatedTurns,
      queuedMessages: const [],
      sessionTelemetry: state.sessionTelemetry.copyWith(clearLive: true),
      isStreaming: false,
      sendStage: SendStage.idle,
      uploadDoneCount: 0,
      uploadTotalCount: 0,
      isStopping: hasLiveRemoteCancel,
      streamStalled: false,
      clearPendingApproval: true,
      clearActiveQuestion: true,
      clearActiveCordisRequest: true,
      clearOfflineUnsentNotice: true,
      draftHydratedSignal: restoredQueueToDraft ? state.draftHydratedSignal + 1 : state.draftHydratedSignal,
    );
    _recomputeVisibleInteractions();
    if (announce) {
      showToast(
        restoredQueueToDraft ? '已停止生成，排队内容已放回输入框' : '已停止生成',
        tone: ToastTone.info,
      );
    }
  }

  static bool _isInteractionAlreadySettledError(Object error) {
    return error is GbridgeException &&
        (error.status == 404 || error.status == 409 || error.status == 410);
  }

  Future<bool> resolveApproval(String action) async {
    final interactionId = state.pendingApprovalInteractionId;
    if (interactionId == null) return false;
    final client = _liveClient;
    final backup = _pendingInteractionsById[interactionId];
    final mutSeq = ++_interactionMutationSeq;
    _pendingInteractionsById.remove(interactionId);
    _recomputeVisibleInteractions();
    if (client != null) {
      try {
        await client.respondInteraction(interactionId, decision: action);
        if (!_isStillLive(client)) return false;
      } catch (e) {
        if (!_isStillLive(client)) return false;
        if (_isInteractionAlreadySettledError(e)) {
          unawaited(
            GrassBagNativeBridge.instance.cancelAlertNotification('interaction:$interactionId'),
          );
          showToast('该审批请求已在其他端处理或已过期', tone: ToastTone.info);
          return true;
        }
        if (backup != null &&
            _interactionMutationSeq == mutSeq &&
            !_pendingInteractionsById.containsKey(interactionId)) {
          _interactionMutationSeq++;
          _pendingInteractionsById[interactionId] = backup;
          _recomputeVisibleInteractions();
        }
        showError('提交审批决定失败', error: e);
        return false;
      }
    }
    unawaited(
      GrassBagNativeBridge.instance.cancelAlertNotification('interaction:$interactionId'),
    );
    if (!mounted) return true;
    showToast(
      action == 'deny' ? '已拒绝该操作' : (action == 'always' ? '本对话已自动允许同类操作' : '已允许并执行该操作'),
      tone: action == 'deny' ? ToastTone.warn : ToastTone.ok,
    );
    return true;
  }

  Future<bool> skipUserQuestion() async {
    final q = state.activeQuestion;
    if (q == null) return false;
    final client = _liveClient;
    final backup = _pendingInteractionsById[q.interactionId];
    final mutSeq = ++_interactionMutationSeq;
    _pendingInteractionsById.remove(q.interactionId);
    _recomputeVisibleInteractions();
    if (client != null) {
      try {
        await client.respondInteraction(q.interactionId, decision: 'skip');
        if (!_isStillLive(client)) return false;
      } catch (e) {
        if (!_isStillLive(client)) return false;
        if (_isInteractionAlreadySettledError(e)) {
          unawaited(
            GrassBagNativeBridge.instance.cancelAlertNotification('interaction:${q.interactionId}'),
          );
          showToast('该提问已在其他端处理或已关闭', tone: ToastTone.info);
          return true;
        }
        if (backup != null &&
            _interactionMutationSeq == mutSeq &&
            !_pendingInteractionsById.containsKey(q.interactionId)) {
          _interactionMutationSeq++;
          _pendingInteractionsById[q.interactionId] = backup;
          _recomputeVisibleInteractions();
        }
        showError('跳过提问失败', error: e);
        return false;
      }
    }
    unawaited(
      GrassBagNativeBridge.instance.cancelAlertNotification('interaction:${q.interactionId}'),
    );
    if (!mounted) return true;
    showToast('已跳过当前提问', tone: ToastTone.info);
    return true;
  }

  Future<bool> resolveUserQuestion(Object answers) async {
    final q = state.activeQuestion;
    if (q == null) return false;
    final client = _liveClient;
    if (client != null) {
      try {
        await client.respondInteraction(q.interactionId, answers: answers);
        if (!_isStillLive(client)) return false;
      } catch (e) {
        if (!_isStillLive(client)) return false;
        if (_isInteractionAlreadySettledError(e)) {
          _interactionMutationSeq++;
          _pendingInteractionsById.remove(q.interactionId);
          _recomputeVisibleInteractions();
          unawaited(
            GrassBagNativeBridge.instance.cancelAlertNotification('interaction:${q.interactionId}'),
          );
          showToast('该提问已在其他端处理或已关闭', tone: ToastTone.info);
          return true;
        }
        showError('提交回答失败', error: e);
        return false;
      }
    }
    _interactionMutationSeq++;
    _pendingInteractionsById.remove(q.interactionId);
    _recomputeVisibleInteractions();
    unawaited(
      GrassBagNativeBridge.instance.cancelAlertNotification('interaction:${q.interactionId}'),
    );
    if (!mounted) return true;
    showToast('已提交你的选择');
    return true;
  }

  Future<bool> resolveCordisRun(bool allow) async {
    final req = state.activeCordisRequest;
    if (req == null) return false;
    final client = _liveClient;
    final backup = _pendingInteractionsById[req.interactionId];
    final mutSeq = ++_interactionMutationSeq;
    _pendingInteractionsById.remove(req.interactionId);
    _recomputeVisibleInteractions();
    if (client != null) {
      try {
        await client.respondInteraction(req.interactionId, decision: allow ? 'allow' : 'deny');
        if (!_isStillLive(client)) return false;
      } catch (e) {
        if (!_isStillLive(client)) return false;
        if (_isInteractionAlreadySettledError(e)) {
          unawaited(
            GrassBagNativeBridge.instance.cancelAlertNotification('interaction:${req.interactionId}'),
          );
          showToast('该动态插件授权已在其他端处理或已过期', tone: ToastTone.info);
          return true;
        }
        if (backup != null &&
            _interactionMutationSeq == mutSeq &&
            !_pendingInteractionsById.containsKey(req.interactionId)) {
          _interactionMutationSeq++;
          _pendingInteractionsById[req.interactionId] = backup;
          _recomputeVisibleInteractions();
        }
        showError('提交动态插件授权失败', error: e);
        return false;
      }
    }
    unawaited(
      GrassBagNativeBridge.instance.cancelAlertNotification('interaction:${req.interactionId}'),
    );
    if (!mounted) return true;
    showToast(allow ? '已允许动态插件运行' : '已拒绝动态插件运行', tone: allow ? ToastTone.ok : ToastTone.warn);
    return true;
  }

  /// Switch the focused takeover card when multiple pending approvals/questions exist on this session.
  void cyclePendingInteraction(int delta) {
    final activeSid = state.activeSessionId;
    final activeItems = <PendingInteraction>[];
    for (final item in _pendingInteractionsById.values) {
      final itemSid = item.sessionId ?? item.payload['sessionId']?.toString();
      final isHostGlobal = item.kind == 'cordis_run';
      final matchesActive = (itemSid != null && itemSid.isNotEmpty)
          ? itemSid == activeSid
          : (isHostGlobal || activeSid == null);
      if (matchesActive) activeItems.add(item);
    }
    if (activeItems.length <= 1) return;
    var curIdx = activeItems.indexWhere((i) => i.id == _preferredInteractionId);
    if (curIdx < 0) {
      final currentShownId = state.activeCordisRequest?.interactionId ??
          state.activeQuestion?.interactionId ??
          state.pendingApprovalInteractionId;
      curIdx = activeItems.indexWhere((i) => i.id == currentShownId);
      if (curIdx < 0) curIdx = 0;
    }
    final nextIdx = (curIdx + delta) % activeItems.length;
    final normalizedIdx = nextIdx < 0 ? nextIdx + activeItems.length : nextIdx;
    _preferredInteractionId = activeItems[normalizedIdx].id;
    _recomputeVisibleInteractions();
  }

  void _recomputeVisibleInteractions() {
    final activeSid = state.activeSessionId;
    String? approvalId;
    String? approvalCmd;
    String? approvalToolName;
    ActiveUserQuestion? question;
    ActiveCordisRunRequest? cordisReq;
    final pendingSessionIds = <String>{};
    final activeItems = <PendingInteraction>[];

    for (final item in _pendingInteractionsById.values) {
      final itemSid = item.sessionId ?? item.payload['sessionId']?.toString();
      if (itemSid != null && itemSid.isNotEmpty) {
        pendingSessionIds.add(itemSid);
      }
      final isHostGlobal = item.kind == 'cordis_run';
      final matchesActive = (itemSid != null && itemSid.isNotEmpty)
          ? itemSid == activeSid
          : (isHostGlobal || activeSid == null);
      if (!matchesActive) continue;
      activeItems.add(item);
    }

    final activePendingCount = activeItems.length;
    var activePendingIdx = 0;
    if (activeItems.isEmpty) {
      _preferredInteractionId = null;
    } else {
      final prefIdx = _preferredInteractionId != null
          ? activeItems.indexWhere((i) => i.id == _preferredInteractionId)
          : -1;
      if (prefIdx >= 0) {
        activePendingIdx = prefIdx;
        final focused = activeItems[prefIdx];
        final itemSid = focused.sessionId ?? focused.payload['sessionId']?.toString();
        if (focused.kind == 'user_questions') {
          question = _parseUserQuestionInteraction(focused);
        } else if (focused.kind == 'cordis_run') {
          cordisReq = ActiveCordisRunRequest(
            interactionId: focused.id,
            pluginName:
                (focused.payload['pluginName'] ?? focused.payload['name'] ?? 'dynamic-plugin')
                    .toString(),
            summary: (focused.payload['summary'] ?? focused.payload['reason'] ?? '请求加载动态 Cordis 模块')
                .toString(),
            codePreview: (focused.payload['code'] ?? focused.payload['source'] ?? '').toString(),
            sessionId: itemSid,
          );
        } else {
          approvalId = focused.id;
          approvalCmd = _formatApprovalPrompt(focused.payload);
          final rawTool =
              focused.payload['tool'] ?? focused.payload['toolName'] ?? focused.payload['name'];
          approvalToolName = rawTool?.toString().trim();
        }
      } else {
        _preferredInteractionId = null;
        for (final item in activeItems) {
          final itemSid = item.sessionId ?? item.payload['sessionId']?.toString();
          if (item.kind == 'user_questions') {
            question ??= _parseUserQuestionInteraction(item);
          } else if (item.kind == 'cordis_run') {
            cordisReq ??= ActiveCordisRunRequest(
              interactionId: item.id,
              pluginName:
                  (item.payload['pluginName'] ?? item.payload['name'] ?? 'dynamic-plugin')
                      .toString(),
              summary: (item.payload['summary'] ?? item.payload['reason'] ?? '请求加载动态 Cordis 模块')
                  .toString(),
              codePreview: (item.payload['code'] ?? item.payload['source'] ?? '').toString(),
              sessionId: itemSid,
            );
          } else {
            if (approvalId == null) {
              approvalId = item.id;
              approvalCmd = _formatApprovalPrompt(item.payload);
              final rawTool =
                  item.payload['tool'] ?? item.payload['toolName'] ?? item.payload['name'];
              approvalToolName = rawTool?.toString().trim();
            }
          }
        }
        final topId = cordisReq?.interactionId ?? question?.interactionId ?? approvalId;
        final topIdx = activeItems.indexWhere((i) => i.id == topId);
        activePendingIdx = topIdx >= 0 ? topIdx : 0;
      }
    }

    bool sessionsPendingChanged = false;
    for (final s in state.sessions) {
      if (s.pendingApproval != pendingSessionIds.contains(s.id)) {
        sessionsPendingChanged = true;
        break;
      }
    }
    final allPendingList = List<PendingInteraction>.unmodifiable(_pendingInteractionsById.values);
    final pendingListChanged = allPendingList.length != state.pendingInteractions.length ||
        [for (final i in allPendingList) i.id].join(',') !=
            [for (final i in state.pendingInteractions) i.id].join(',');

    if (!sessionsPendingChanged &&
        !pendingListChanged &&
        state.pendingApprovalInteractionId == approvalId &&
        state.pendingApprovalCommand == approvalCmd &&
        state.pendingApprovalToolName == approvalToolName &&
        state.activePendingInteractionCount == activePendingCount &&
        state.activePendingInteractionIndex == activePendingIdx &&
        state.activeQuestion == question &&
        state.activeCordisRequest == cordisReq) {
      return;
    }

    final updatedSessions = sessionsPendingChanged
        ? [
            for (final s in state.sessions)
              s.pendingApproval == pendingSessionIds.contains(s.id)
                  ? s
                  : s.copyWith(pendingApproval: pendingSessionIds.contains(s.id)),
          ]
        : state.sessions;

    state = state.copyWith(
      sessions: updatedSessions,
      pendingInteractions: allPendingList,
      pendingApprovalInteractionId: approvalId,
      pendingApprovalCommand: approvalCmd,
      pendingApprovalToolName: approvalToolName,
      activePendingInteractionCount: activePendingCount,
      activePendingInteractionIndex: activePendingIdx,
      clearPendingApproval: approvalId == null,
      activeQuestion: question,
      clearActiveQuestion: question == null,
      activeCordisRequest: cordisReq,
      clearActiveCordisRequest: cordisReq == null,
    );
  }

  /// Resolves a specific pending approval interaction directly (e.g. from the Pending Inbox sheet).
  Future<bool> resolveInteractionById(String interactionId, String action) async {
    final backup = _pendingInteractionsById[interactionId];
    if (backup == null) return false;
    final client = _liveClient;
    final mutSeq = ++_interactionMutationSeq;
    _pendingInteractionsById.remove(interactionId);
    _recomputeVisibleInteractions();
    if (client != null) {
      try {
        await client.respondInteraction(interactionId, decision: action);
        if (!_isStillLive(client)) return false;
      } catch (e) {
        if (!_isStillLive(client)) return false;
        if (_isInteractionAlreadySettledError(e)) {
          unawaited(
            GrassBagNativeBridge.instance.cancelAlertNotification('interaction:$interactionId'),
          );
          showToast('该审批请求已在其他端处理或已过期', tone: ToastTone.info);
          return true;
        }
        if (_interactionMutationSeq == mutSeq &&
            !_pendingInteractionsById.containsKey(interactionId)) {
          _interactionMutationSeq++;
          _pendingInteractionsById[interactionId] = backup;
          _recomputeVisibleInteractions();
        }
        showError('提交审批决定失败', error: e);
        return false;
      }
    }
    unawaited(
      GrassBagNativeBridge.instance.cancelAlertNotification('interaction:$interactionId'),
    );
    if (!mounted) return true;
    showToast(
      action == 'deny' ? '已拒绝该操作' : (action == 'always' ? '本对话已自动允许同类操作' : '已允许并执行该操作'),
      tone: action == 'deny' ? ToastTone.warn : ToastTone.ok,
    );
    return true;
  }

  /// Jumps directly from the Pending Inbox to the session hosting [item] and focuses it.
  void openInboxInteraction(PendingInteraction item) {
    _preferredInteractionId = item.id;
    final sid = item.sessionId ?? item.payload['sessionId']?.toString();
    if (sid != null && sid.isNotEmpty && sid != state.activeSessionId) {
      selectSession(sid);
    } else {
      _recomputeVisibleInteractions();
    }
  }

  static String _formatApprovalPrompt(Map<String, dynamic> payload) {
    final args = payload['args'] is Map
        ? Map<String, dynamic>.from(payload['args'] as Map)
        : (payload['input'] is Map ? Map<String, dynamic>.from(payload['input'] as Map) : null);
    final cmd = (payload['command'] ?? args?['command'] ?? args?['cmd'])?.toString().trim();
    if (cmd != null && cmd.isNotEmpty) return cmd;
    final toolName = (payload['toolName'] ?? payload['tool'] ?? payload['name'])?.toString().trim();
    final targetPath = (payload['file_path'] ??
            payload['filePath'] ??
            payload['path'] ??
            args?['file_path'] ??
            args?['filePath'] ??
            args?['path'] ??
            args?['target_file'] ??
            args?['url'] ??
            payload['url'])
        ?.toString()
        .trim();
    final reason = (payload['displayReason'] ?? payload['reason'])?.toString().trim();
    final lines = <String>[];
    if (reason != null && reason.isNotEmpty) {
      lines.add(reason);
    }
    if (targetPath != null && targetPath.isNotEmpty) {
      lines.add('目标：$targetPath');
    }
    if (args != null && args.isNotEmpty) {
      String clipBlock(String text, {int maxChars = 900, int maxLines = 18}) {
        final rawLines = text.replaceAll('\r\n', '\n').split('\n');
        var out = rawLines.take(maxLines).join('\n');
        final cutByLines = rawLines.length > maxLines;
        if (out.length > maxChars) {
          out = '${out.substring(0, maxChars)}…';
        } else if (cutByLines) {
          out = '$out\n…（共 ${rawLines.length} 行）';
        }
        return out;
      }

      // Structured multiline diff preview for file-edit / patch / write tools!
      final patchText = (args['patch'] ?? args['diff'])?.toString().trim() ?? '';
      final oldStr = (args['old_string'] ?? args['oldText'] ?? args['target'] ?? args['search'])?.toString() ?? '';
      final newStr = (args['new_string'] ?? args['newText'] ?? args['replacement'] ?? args['replace'])?.toString() ?? '';
      final fileContent = (args['content'] ?? args['code'] ?? args['text'])?.toString() ?? '';

      if (patchText.isNotEmpty) {
        lines.add(clipBlock(patchText, maxChars: 1200, maxLines: 22));
      } else if (oldStr.isNotEmpty || newStr.isNotEmpty) {
        final diffBuf = <String>[];
        if (oldStr.isNotEmpty) {
          for (final l in oldStr.replaceAll('\r\n', '\n').split('\n').take(10)) {
            diffBuf.add('- $l');
          }
        }
        if (newStr.isNotEmpty) {
          for (final l in newStr.replaceAll('\r\n', '\n').split('\n').take(12)) {
            diffBuf.add('+ $l');
          }
        }
        lines.add(clipBlock(diffBuf.join('\n'), maxChars: 1200, maxLines: 22));
      } else if (fileContent.isNotEmpty &&
          (toolName?.toLowerCase().contains('write') == true ||
              toolName?.toLowerCase().contains('create') == true ||
              targetPath != null)) {
        lines.add(clipBlock(fileContent, maxChars: 900, maxLines: 16));
      } else {
        final compactArgs = <String>[];
        for (final entry in args.entries) {
          if (entry.key == 'command' ||
              entry.key == 'cmd' ||
              entry.key == 'path' ||
              entry.key == 'file_path' ||
              entry.key == 'filePath' ||
              entry.key == 'url') {
            continue;
          }
          final val = entry.value?.toString().trim() ?? '';
          if (val.isEmpty) continue;
          final clipped = val.length > 260 ? '${val.substring(0, 260)}…' : val;
          compactArgs.add('${entry.key}: $clipped');
          if (compactArgs.length >= 4) break;
        }
        if (compactArgs.isNotEmpty) {
          lines.add(compactArgs.join('\n'));
        }
      }
    }
    if (lines.isNotEmpty) {
      return lines.join('\n');
    }
    final title = payload['title']?.toString().trim();
    if (title != null && title.isNotEmpty) return title;
    return toolName != null && toolName.isNotEmpty ? '执行工具：$toolName' : '执行工作区敏感操作';
  }

  static UserQuestionItem _parseSingleQuestion(
    Map<String, dynamic> qMap,
    Map<String, dynamic> rootPayload,
    int index,
  ) {
    final qId = (qMap['id'] ?? rootPayload['questionId'] ?? 'q-$index').toString();
    final title = (qMap['header'] ?? qMap['title'] ?? rootPayload['title'] ?? '需要你的确认').toString();
    final prompt = (qMap['question'] ?? qMap['prompt'] ?? rootPayload['question'] ?? '请选择或填写回复').toString();
    final rawOpts = qMap['options'] ?? (index == 0 ? rootPayload['options'] : null);
    final opts = <String>[];
    final descs = <String>[];
    if (rawOpts is List) {
      for (final o in rawOpts) {
        if (o is String && o.trim().isNotEmpty) {
          opts.add(o.trim());
          descs.add('');
        } else if (o is Map) {
          final label = (o['label'] ?? o['value'] ?? o['title'] ?? '').toString().trim();
          if (label.isEmpty) continue;
          opts.add(label);
          descs.add(o['description']?.toString().trim() ?? '');
        }
      }
    }
    final allowFreeText = qMap['allowFreeText'] is bool
        ? qMap['allowFreeText'] as bool
        : (rootPayload['allowFreeText'] is bool
            ? rootPayload['allowFreeText'] as bool
            : true);
    return UserQuestionItem(
      id: qId,
      title: title,
      prompt: prompt,
      options: opts,
      optionDescriptions: descs,
      multiSelect: qMap['multiSelect'] == true || rootPayload['multiSelect'] == true,
      allowFreeText: opts.isEmpty ? true : allowFreeText,
    );
  }

  static ActiveUserQuestion _parseUserQuestionInteraction(PendingInteraction item) {
    final p = item.payload;
    final rawQuestions = p['questions'];
    final parsedList = <UserQuestionItem>[];
    if (rawQuestions is List && rawQuestions.isNotEmpty) {
      for (var i = 0; i < rawQuestions.length; i++) {
        final rawQ = rawQuestions[i];
        if (rawQ is Map) {
          parsedList.add(_parseSingleQuestion(Map<String, dynamic>.from(rawQ), p, i));
        }
      }
    }
    if (parsedList.isEmpty) {
      parsedList.add(_parseSingleQuestion(p, p, 0));
    }
    final first = parsedList.first;
    return ActiveUserQuestion(
      interactionId: item.id,
      questionId: first.id,
      sessionId: item.sessionId ?? p['sessionId']?.toString(),
      title: first.title,
      prompt: first.prompt,
      options: first.options,
      optionDescriptions: first.optionDescriptions,
      multiSelect: first.multiSelect,
      allowFreeText: first.allowFreeText,
      questions: parsedList,
    );
  }

  // ---------------------------------------------------------------------------
  // Live Host Connection (TCP HTTP/HTTPS + Local Android 0600 UDS + Bootstrap)
  // ---------------------------------------------------------------------------
  String _normalizeHttpAddress(ManagedHost host) {
    final trimmed = host.address.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    if (host.isLocal && kIsWeb) {
      return 'http://127.0.0.1:3080';
    }
    if (!host.isLocal && trimmed.isNotEmpty && !trimmed.contains('://')) {
      return 'http://$trimmed';
    }
    return trimmed;
  }

  /// Synchronously detach the active live client & cancel EVERY host-scoped timer/buffer
  /// BEFORE committing a host switch so zero stale frames or delayed flushes can cross-contaminate.
  void _detachLiveClientsSync({bool preserveLocalConnectLock = false}) {
    _clearPendingStreamCoalesce();
    _disarmStreamWatchdog();
    _hostSessionsRefreshTimer?.cancel();
    _hostSessionsRefreshTimer = null;
    _domainRefreshTimer?.cancel();
    _domainRefreshTimer = null;
    _domainRetryTimer?.cancel();
    _domainRetryTimer = null;
    _reconnectGraceTimer?.cancel();
    _reconnectGraceTimer = null;
    _reconnectStreamCheckTimer?.cancel();
    _reconnectStreamCheckTimer = null;
    _hydrationGen++;
    _drawerSearchTimer?.cancel();
    _drawerSearchTimer = null;
    _accountPollTimer?.cancel();
    _accountPollTimer = null;
    _jobOutputFlushTimer?.cancel();
    _jobOutputFlushTimer = null;
    _engineLogFlushTimer?.cancel();
    _engineLogFlushTimer = null;
    for (final t in _sessionStreamRetryTimers.values) {
      t.cancel();
    }
    _sessionStreamRetryTimers.clear();
    _sessionStreamRetryCount.clear();
    for (final t in _jobStreamRetryTimers.values) {
      t.cancel();
    }
    _jobStreamRetryTimers.clear();
    _jobStreamRetryCount.clear();
    _pendingEngineLogs.clear();
    _pendingJobOutputs.clear();
    _coalescedClient = null;
    _jobOutputClient = null;
    _activeSignInAttemptId = null;
    _hadInitialWelcome = false;
    _inFlightSendKeys.clear();
    if (_activeSendRunIdBySession.isNotEmpty) {
      _cancelledSendRunIds.addAll(_activeSendRunIdBySession.values);
      _activeSendRunIdBySession.clear();
    }
    if (!preserveLocalConnectLock) {
      _connectingLocalAndroid = false;
      _connectingLocalGen = null;
    }
    _sessionTurnsMemory.clear();
    _sessionPaginationMemory.clear();
    _toolDetailCache.clear();
    _pendingInteractionsById.clear();
    _syncingSessionBundleIds.clear();
    _inFlightBundleSyncs.clear();
    _pendingResyncFlags.clear();
    _inFlightCancelBySession.clear();
    _attachmentDownloadCache.clear();
    _attachmentDownloadCacheBytes = 0;
    _inFlightAttachmentDownloads.clear();
    _sessionStreamSeq.clear();
    _locallyCancelledTurnIds.clear();
    _cancelSuppressUntilMs = 0;
    _turnReducer.replaceAll(const []);

    final streamSub = _streamSub;
    final welcomeSub = _welcomeSub;
    final phaseSub = _phaseSub;
    final live = _liveClient;
    final bootstrap = _bootstrapClient;
    _streamSub = null;
    _welcomeSub = null;
    _phaseSub = null;
    _liveClient = null;
    _bootstrapClient = null;

    if (streamSub != null) unawaited(streamSub.cancel().catchError((_) {}));
    if (welcomeSub != null) unawaited(welcomeSub.cancel().catchError((_) {}));
    if (phaseSub != null) unawaited(phaseSub.cancel().catchError((_) {}));
    if (live != null) unawaited(live.dispose().catchError((_) {}));
    if (bootstrap != null) unawaited(bootstrap.dispose().catchError((_) {}));
  }

  Future<void> switchHost(
    String hostId, {
    bool awaitConnect = false,
    bool savePreviousContext = true,
    bool preserveActiveDrafts = true,
    bool announce = true,
  }) async {
    final target = state.hosts.where((h) => h.id == hostId).firstOrNull;
    if (target == null) return;
    final isSameHostReconnect = state.activeHostId == hostId;
    final prevActiveSessionId = state.activeSessionId;
    // Save outgoing host's session/workspace/filter context & attachments BEFORE wiping state,
    // including same-host reconnects (e.g. token refresh / config tweak) when origin stayed intact!
    if (preserveActiveDrafts && (!isSameHostReconnect || state.pendingAttachments.isNotEmpty || prevActiveSessionId != null)) {
      _stashPendingAttachmentsForScope(state.activeHostId, prevActiveSessionId);
      _stashQueuedMessagesForScope(state.activeHostId, prevActiveSessionId);
      if (savePreviousContext) {
        _saveCurrentHostContext(hostIdOverride: state.activeHostId);
      }
    }
    final gen = ++_hostConnectGen;
    _modelSelectionGen++;
    _lastAutoSyncedDefaultKey = null;
    _hostProbeGen[hostId] = (_hostProbeGen[hostId] ?? 0) + 1;
    _streamRunId++;
    _userNavigatedSinceHostBind = false;
    // CRITICAL: Synchronously detach old client, cancel subscriptions & clear ALL timers/caches
    // BEFORE committing `activeHostId = hostId`, preventing any in-flight event cross-talk!
    _detachLiveClientsSync();

    final normalizedAddr = _normalizeHttpAddress(target);
    final shouldUseHttp = normalizedAddr.startsWith('http://') || normalizedAddr.startsWith('https://');
    final effectiveTarget = (shouldUseHttp && normalizedAddr != target.address)
        ? target.copyWith(
            address: normalizedAddr,
            token: target.isLocal && kIsWeb ? (target.token ?? 'grassbag-dev-2026') : target.token,
          )
        : target;

    final incomingCtx = _hostContexts[hostId];
    final incomingOrigin = _hostOriginKey(hostId);
    final savedIncomingOrigin =
        incomingCtx?['lastHostOrigin']?.toString().trim().toLowerCase() ?? '';
    final incomingOriginOk = savedIncomingOrigin.isEmpty ||
        incomingOrigin.isEmpty ||
        savedIncomingOrigin == incomingOrigin;
    final restoredFilterRaw =
        incomingOriginOk ? (incomingCtx?['sidebarWorkspaceFilter'] as String?) : null;
    final restoredFilter =
        (restoredFilterRaw != null && restoredFilterRaw.isNotEmpty) ? restoredFilterRaw : null;
    final offlineCachedSessions =
        incomingOriginOk ? _hydrateOfflineCacheForHost(hostId) : const <ChatSessionItem>[];

    state = state.copyWith(
      activeHostId: hostId,
      hosts: effectiveTarget == target
          ? state.hosts
          : [for (final h in state.hosts) h.id == hostId ? effectiveTarget : h],
      clearActiveSession: true,
      clearParentSession: true,
      sidebarWorkspaceFilter: restoredFilter,
      clearSidebarWorkspaceFilter: restoredFilter == null,
      clearPendingApproval: true,
      clearActiveQuestion: true,
      clearActiveCordisRequest: true,
      clearOfflineUnsentNotice: true,
      pendingInteractions: const [],
      clearLiveCapabilities: true,
      clearAccountSnapshot: true,
      clearUpdateCheck: true,
      clearTurnsNextCursor: true,
      clearSessionLoadError: true,
      clearMarketError: true,
      checkingUpdate: false,
      hasMoreTurns: false,
      loadingOlderTurns: false,
      searchingMarket: false,
      speechConfigured: false,
      accountSigningIn: false,
      turnProcessOpen: !state.autoFoldSteps,
      activeWorkspace: '',
      activePresetId: 'standard',
      activePermissionId: 'workspace-write',
      planMode: false,
      slashCommands: kDefaultSlashCommands,
      activeModelProvider: '',
      activeModelId: '',
      modelName: '未连接模型',
      modelShort: '未连接',
      modelEffort: '',
      modelEffortId: '',
      presets: kPresetOptions,
      permissionTiers: kPermissionTiers,
      searchQuery: '',
      searchSnippets: const {},
      filter: SessionFilter.all,
      sessions: offlineCachedSessions,
      loadingSessions: offlineCachedSessions.isEmpty,
      hydratingDomains: true,
      initialDomainsHydrated: false,
      workspaces: const [],
      turns: const [],
      turnFeedback: const {},
      stepTranslations: const {},
      translatedStepIds: const {},
      translatingStepIds: const {},
      expandedTurnProcessIds: const {},
      collapsedTurnProcessIds: const {},
      expandedStepIds: const {},
      pendingAttachments: _restorePendingAttachmentsForScope(
        hostId,
        (isSameHostReconnect && preserveActiveDrafts) ? prevActiveSessionId : null,
      ),
      workspaceFiles: const [],
      workspaceCurrentPath: '',
      workspaceDiffs: const [],
      activeDiffScope: 'uncommitted',
      todos: const [],
      goals: const [],
      subagents: const [],
      jobs: const [],
      schedules: const [],
      marketPlugins: const [],
      dynamicCordis: const [],
      modelGroups: const [],
      routableProviders: const [],
      providerCredentials: const [],
      dshNamespaces: const [],
      dshSettingsSections: const [],
      dshDynamicOptions: const {},
      engineSchema: const {},
      engineValues: const {},
      mcpServers: const [],
      plugins: const [],
      sduiSurfaces: const [],
      sduiViews: const {},
      queuedMessages: const [],
      toolOutputCache: const {},
      engineLogs: const [],
      sessionTelemetry: const SessionTelemetry(),
      loadingSession: false,
      isStreaming: false,
      isStopping: false,
      streamStalled: false,
      sendStage: SendStage.idle,
      uploadDoneCount: 0,
      uploadTotalCount: 0,
      activePendingInteractionCount: 0,
      contextPct: 0,
      contextUsedK: 0,
      contextMaxK: 128,
      contextBreakdown: const {},
      connectionPhase: ConnectionPhase.connecting,
      sessionRenderGen: state.sessionRenderGen + 1,
      newChatSignal: state.newChatSignal + 1,
    );
    _persistPrefs();
    if (announce) {
      showToast(
        '已切换到「${effectiveTarget.name}」，正在刷新对话列表…',
        tone: ToastTone.info,
      );
    }

    if (!mounted || gen != _hostConnectGen) return;

    if (shouldUseHttp) {
      if (awaitConnect) {
        await _tryConnectLiveHost(effectiveTarget, gen: gen);
      } else {
        unawaited(_tryConnectLiveHost(effectiveTarget, gen: gen));
      }
    } else if (effectiveTarget.isLocal) {
      if (GrassBagNativeBridge.instance.isAndroidNative) {
        unawaited(refreshEngineLogs());
      }
      if (awaitConnect) {
        await refreshNativeStatus(connectGen: gen);
      } else {
        unawaited(refreshNativeStatus(connectGen: gen));
      }
    } else {
      state = state.copyWith(
        loadingSessions: false,
        hydratingDomains: false,
        connectionPhase: ConnectionPhase.error,
        hosts: [
          for (final h in state.hosts)
            h.id == hostId ? h.copyWith(online: false, lastError: '主机地址格式无效') : h,
        ],
      );
    }
  }

  Future<void> _disconnectLiveClients() async {
    _detachLiveClientsSync();
  }

  Future<bool> _connectUnixBridge(String socketPath, String token, {int? gen}) async {
    GbridgeClient? client;
    try {
      _detachLiveClientsSync(preserveLocalConnectLock: true);
      if (!mounted || (gen != null && gen != _hostConnectGen)) return false;
      client = GbridgeClient(
        HostEndpoint.unix(socketPath: socketPath, token: token),
        timeout: const Duration(seconds: 25),
      );
      final caps = await client.getCapabilities();
      if (!mounted || (gen != null && gen != _hostConnectGen) || !state.activeHost.isLocal) {
        await client.dispose();
        return false;
      }
      await _bindFullLiveClient(client, 'local', caps, gen: gen);
      return true;
    } catch (_) {
      await client?.dispose();
      return false;
    }
  }

  void _persistHostCookie(String hostId, String cookieHeader) {
    final clean = cookieHeader.trim();
    if (clean.isEmpty) {
      unawaited(GrassBagNativeBridge.instance.deleteSecret('host_cookie_$hostId'));
      if (!mounted) return;
      final idx = state.hosts.indexWhere((h) => h.id == hostId);
      if (idx < 0 || !state.hosts[idx].hasSavedCookie) return;
      state = state.copyWith(
        hosts: [
          for (final h in state.hosts) h.id == hostId ? h.copyWith(clearSessionCookie: true) : h,
        ],
      );
      return;
    }
    unawaited(GrassBagNativeBridge.instance.putSecret('host_cookie_$hostId', clean));
    if (!mounted) return;
    final idx = state.hosts.indexWhere((h) => h.id == hostId);
    if (idx < 0 || state.hosts[idx].sessionCookie == clean) return;
    state = state.copyWith(
      hosts: [
        for (final h in state.hosts) h.id == hostId ? h.copyWith(sessionCookie: clean) : h,
      ],
    );
  }

  static ({String code, String message, String? technicalDetail}) _classifyConnectionError(
    Object err, {
    required String address,
  }) {
    final rawDetail = err.toString().trim();
    final lower = rawDetail.toLowerCase();
    final uri = Uri.tryParse(address);
    final hostLabel = uri?.host.isNotEmpty == true ? uri!.host : address;
    final portSuffix = (uri != null && uri.hasPort && uri.port != 80 && uri.port != 443)
        ? ' --port ${uri.port}'
        : '';
    if (lower.contains('handshakeexception') ||
        lower.contains('certificate_verify_failed') ||
        lower.contains('tlsexception') ||
        lower.contains('bad certificate')) {
      return (
        code: 'tls_cert',
        message: 'HTTPS 证书未受系统信任（可能为自签名证书）。可开启「信任自签名证书」后重试。',
        technicalDetail: rawDetail,
      );
    }
    if (err is GbridgeException) {
      if (err.code == 'gbridge/html_response') {
        return (
          code: 'html_proxy',
          message: '目标返回了网页登录认证页（如反向代理或 SSO 网关），可直接在 App 内网页登录同步凭证。',
          technicalDetail: rawDetail,
        );
      }
      if (err.code == 'gbridge/pairing_code_expired') {
        return (
          code: 'pairing_code_expired',
          message: '电脑可以连通，但当前配对码已过期或已刷新。请在电脑端重新显示二维码后再扫描。',
          technicalDetail: rawDetail,
        );
      }
      if (err.status == 401) {
        return (
          code: 'needs_auth',
          message: '远程 DSH 需要一次鉴权（完成后自动保存 30 天免密凭证，重启远程 DSH 亦无需重填）。',
          technicalDetail: rawDetail,
        );
      }
      if (err.status == 403) {
        return (
          code: 'untrusted_host',
          message: '远程 DSH 拒绝了 Host 请求头（HTTP 403）。请在远程主机使用 `dsh web --host $hostLabel$portSuffix` 或 `--trusted-host $hostLabel` 启动。',
          technicalDetail: rawDetail,
        );
      }
    }
    final isBrowserFetchFail = lower.contains('failed to fetch') ||
        lower.contains('load failed') ||
        lower.contains('networkerror') ||
        lower.contains('xmlhttprequest') ||
        lower.contains('clientexception');
    final isSocketUnreach = lower.contains('connection refused') ||
        lower.contains('failed host lookup') ||
        lower.contains('network is unreachable') ||
        lower.contains('no route to host') ||
        lower.contains('timed out') ||
        lower.contains('timeoutexception') ||
        lower.contains('socketexception') ||
        isBrowserFetchFail;
    if (isSocketUnreach) {
      final isLoopbackTarget = isLoopbackHost(hostLabel);
      if (isLoopbackTarget) {
        final msg = kIsWeb
            ? '$address 指向当前打开浏览器的这台设备本身，且未收到响应。如果你要连接另一台电脑，请换成那台电脑上的局域网连接链接；如果就在同一台电脑上使用，请确认本机已运行 dsh web 且端口一致。'
            : '$address 指向当前设备自身，而不是你的电脑。请换成电脑上的局域网连接链接，或直接扫描电脑上的二维码。';
        return (
          code: 'loopback_unreachable',
          message: msg,
          technicalDetail: rawDetail,
        );
      }
      return (
        code: 'unreachable',
        message: '暂时无法连上 $address。请确认目标电脑已开启连接服务、地址与端口填写无误，且两台设备网络互通。',
        technicalDetail: rawDetail,
      );
    }
    return (
      code: 'error',
      message: formatReadableError(err),
      technicalDetail: rawDetail,
    );
  }

  /// Returns true when [uri] uses cleartext `http://` targeting a public (non-loopback,
  /// non-RFC1918/LAN, non-Tailscale/CGNAT, non-link-local) host where sending bearer tokens
  /// or session cookies risks interception.
  static bool isPublicCleartextHttpUri(Uri uri) {
    if (uri.scheme.toLowerCase() != 'http') return false;
    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty) return false;
    if (isLoopbackHost(host)) return false;
    if (host.endsWith('.local') ||
        host.endsWith('.lan') ||
        host.endsWith('.internal') ||
        host.endsWith('.home.arpa') ||
        host.endsWith('.ts.net')) {
      return false;
    }
    if (host.startsWith('fe80:') || host.startsWith('fc') || host.startsWith('fd')) {
      return false;
    }
    final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(host);
    if (ipv4 != null) {
      final a = int.tryParse(ipv4.group(1)!) ?? -1;
      final b = int.tryParse(ipv4.group(2)!) ?? -1;
      if (a == 10 || a == 127) return false;
      if (a == 192 && b == 168) return false;
      if (a == 172 && b >= 16 && b <= 31) return false;
      if (a == 100 && b >= 64 && b <= 127) return false; // CGNAT / Tailscale
      if (a == 169 && b == 254) return false; // Link-local
      return true;
    }
    // Single-label local hostname without dot (e.g. `mac-studio`) is LAN-scoped.
    if (!host.contains('.')) return false;
    return true;
  }

  /// Live non-destructive diagnosis of any remote DSH input BEFORE or AFTER saving,
  /// detecting stock DSH (zero-plugin direct), `dsh-gbridge`, auth needs, 403 Host fence,
  /// HTML login proxies, self-signed TLS certs, public cleartext HTTP, and unreachable hosts.
  Future<RemoteHostDiagnosis> diagnoseRemoteHost(
    String rawInput, {
    String? token,
    String? pairCode,
    String? cookie,
    bool allowBadCertificates = false,
    bool allowInsecurePublicHttp = false,
  }) async {
    final parsed = parseRemoteHostInput(rawInput, explicitToken: token);
    if (parsed == null) {
      return const RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.invalidAddress,
        title: '链接或地址格式无效',
        message: '请粘贴电脑上的配对链接、`dsh web` 启动链接，或输入 `IP:端口`。',
      );
    }

    final uri = Uri.parse(parsed.address);
    final isLoopback = isLoopbackHost(uri.host);
    await _refreshDeviceLocalIps();
    final selfGuidance = selfDeviceGuidanceForUri(uri);
    if (selfGuidance != null) {
      return RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.selfDevice,
        title: isLoopback ? '这个地址指向当前设备自己' : '这个地址指向当前设备自己',
        message: selfGuidance,
        normalizedAddress: parsed.address,
        hostName: parsed.suggestedName,
        isLoopbackTarget: isLoopback,
      );
    }
    final effectiveToken = parsed.token;
    final effectivePairCode =
        (pairCode != null && pairCode.trim().isNotEmpty) ? pairCode.trim() : parsed.pairCode;
    String? mintedCookie = (cookie != null && cookie.trim().isNotEmpty) ? cookie.trim() : null;
    // Security boundary: NEVER transmit credentials (token or cookie) over public cleartext HTTP
    // before the user explicitly confirms or switches to HTTPS!
    if (!allowInsecurePublicHttp && isPublicCleartextHttpUri(uri)) {
      return RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.insecurePublicHttp,
        title: '公网明文 HTTP 风险拦截',
        message: '检测到公网地址 ${uri.host} 使用未加密的 http://，已阻止在首次诊断时明文发送 Token 或 Cookie。建议改用 https://（或 Tailscale / 局域网），如确需明文测试请点击确认后继续。',
        normalizedAddress: parsed.address,
        extractedToken: effectiveToken,
        extractedPairCode: effectivePairCode,
        capturedCookie: mintedCookie,
        hostName: parsed.suggestedName,
      );
    }
    final sw = Stopwatch()..start();
    GbridgeClient? client;
    try {
      client = GbridgeClient(
        HostEndpoint.http(
          baseUri: uri,
          token: effectiveToken,
          cookie: mintedCookie,
          pairCode: effectivePairCode,
        ),
        timeout: const Duration(seconds: 10),
        allowBadCertificates: allowBadCertificates,
        autoReconnect: false,
        onCookieUpdated: (c) {
          final clean = c.trim();
          if (clean.isNotEmpty) mintedCookie = clean;
        },
      );
      var exchangedTokenThisAttempt = false;
      if ((mintedCookie == null || mintedCookie!.isEmpty) &&
          effectiveToken != null &&
          effectiveToken.isNotEmpty) {
        exchangedTokenThisAttempt = true;
        try {
          await client.exchangeAuthToken(effectiveToken);
        } catch (_) {}
      }
      var probe = await client.probeHost();
      // If a stale DSH cookie failed auth while we have a fresh token, evict only DSH auth cookies
      // (preserving reverse-proxy SSO cookies) and retry token exchange once!
      if (probe is HostProbeNeedsAuth &&
          !probe.isPairingCodeExpired &&
          !exchangedTokenThisAttempt &&
          effectiveToken != null &&
          effectiveToken.isNotEmpty) {
        client.transport.evictDshAuthCookies();
        mintedCookie = client.transport.cookieHeader;
        try {
          await client.exchangeAuthToken(effectiveToken);
        } catch (_) {}
        probe = await client.probeHost();
      }
      final liveCookie = client.transport.cookieHeader?.trim();
      if (liveCookie != null && liveCookie.isNotEmpty) {
        mintedCookie = liveCookie;
      }
      sw.stop();
      final ms = sw.elapsedMilliseconds.clamp(1, 99999);
      return _diagnosisFromProbe(
        probe,
        parsed: parsed,
        uri: uri,
        effectiveToken: effectiveToken,
        effectivePairCode: effectivePairCode,
        mintedCookie: mintedCookie,
        latencyMs: ms,
      );
    } catch (e) {
      sw.stop();
      return _diagnosisFromError(
        e,
        parsed: parsed,
        uri: uri,
        effectiveToken: effectiveToken,
        effectivePairCode: effectivePairCode,
      );
    } finally {
      await client?.dispose();
    }
  }

  RemoteHostDiagnosis _diagnosisFromProbe(
    HostProbeResult probe, {
    required ParsedRemoteHostInput parsed,
    required Uri uri,
    required String? effectiveToken,
    required String? effectivePairCode,
    required String? mintedCookie,
    required int latencyMs,
  }) {
    final isLoopback = isLoopbackHost(uri.host);
    if (probe is HostProbeFull) {
      final hostName = probe.capabilities.host.name.trim().isNotEmpty
          ? probe.capabilities.host.name.trim()
          : parsed.suggestedName;
      return RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.readyGbridge,
        title: '已连接到「${hostName ?? parsed.address}」',
        message: 'DSH ${probe.capabilities.dshVersion} · 增强连接助手 v${probe.capabilities.bridgeVersion}（${latencyMs}ms）',
        normalizedAddress: parsed.address,
        extractedToken: effectiveToken,
        extractedPairCode: effectivePairCode,
        capturedCookie: mintedCookie,
        hostName: hostName,
        dshVersion: probe.capabilities.dshVersion,
        latencyMs: latencyMs,
        hasGbridge: true,
        isLoopbackTarget: isLoopback,
      );
    }
    if (probe is HostProbeVanillaDirect) {
      return RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.readyDirect,
        title: '已连接到「${parsed.suggestedName ?? parsed.address}」',
        message: '原版 DSH ${probe.dshVersion}（${latencyMs}ms）· 免插件直连',
        normalizedAddress: parsed.address,
        extractedToken: effectiveToken,
        extractedPairCode: effectivePairCode,
        capturedCookie: mintedCookie,
        hostName: parsed.suggestedName,
        dshVersion: probe.dshVersion,
        latencyMs: latencyMs,
        hasGbridge: false,
        isLoopbackTarget: isLoopback,
      );
    }
    if (probe is HostProbeNeedsAuth) {
      final verLabel = probe.dshVersion != null ? 'DSH ${probe.dshVersion}' : '电脑端服务';
      if (probe.isPairingCodeExpired) {
        return RemoteHostDiagnosis(
          kind: RemoteDiagnosisKind.pairingCodeExpired,
          title: '配对二维码已失效',
          message: '电脑可以连通，但这个配对码已过期或被刷新。请在电脑端重新显示二维码后扫描。',
          normalizedAddress: parsed.address,
          extractedToken: effectiveToken,
          extractedPairCode: effectivePairCode,
          capturedCookie: mintedCookie,
          hostName: parsed.suggestedName,
          dshVersion: probe.dshVersion,
          latencyMs: latencyMs,
          hasGbridge: true,
          isLoopbackTarget: isLoopback,
        );
      }
      if (probe.isHtmlLoginPage) {
        return RemoteHostDiagnosis(
          kind: RemoteDiagnosisKind.htmlLoginPage,
          title: '需要完成网页登录认证',
          message: '$verLabel 位于登录网关或反向代理后方，请先完成网页登录后再继续连接。',
          normalizedAddress: parsed.address,
          extractedToken: effectiveToken,
          extractedPairCode: effectivePairCode,
          capturedCookie: mintedCookie,
          hostName: parsed.suggestedName,
          dshVersion: probe.dshVersion,
          latencyMs: latencyMs,
          hasGbridge: probe.hasGbridge,
          isLoopbackTarget: isLoopback,
        );
      }
      final hasPairCode = effectivePairCode != null && effectivePairCode.isNotEmpty;
      final hadCredentials = (effectiveToken != null && effectiveToken.isNotEmpty) || hasPairCode;
      return RemoteHostDiagnosis(
        kind: hasPairCode
            ? RemoteDiagnosisKind.pairingCodeExpired
            : RemoteDiagnosisKind.needsAuth,
        title: hadCredentials ? '配对码或令牌已失效' : '已找到 $verLabel，需要授权',
        message: hadCredentials
            ? '电脑可以连通，但当前链接里的配对码或令牌未被接受。请从电脑端重新扫码，或粘贴最新的连接链接。'
            : '电脑端服务在线（${latencyMs}ms）。请扫描电脑上的二维码，或粘贴包含授权信息的完整启动链接。',
        normalizedAddress: parsed.address,
        extractedToken: effectiveToken,
        extractedPairCode: effectivePairCode,
        capturedCookie: mintedCookie,
        hostName: parsed.suggestedName,
        dshVersion: probe.dshVersion,
        latencyMs: latencyMs,
        hasGbridge: probe.hasGbridge,
        isLoopbackTarget: isLoopback,
      );
    }
    if (probe is HostProbeUntrustedHost) {
      final isIp = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(uri.host);
      final portFlag = uri.hasPort && uri.port != 3080 ? ' --port ${uri.port}' : '';
      final cmd = isLoopback
          ? null
          : (isIp
              ? 'dsh web --host ${uri.host}$portFlag'
              : 'dsh web --trusted-host ${probe.hostAuthority}$portFlag');
      return RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.untrustedHost,
        title: '电脑端拒绝了当前访问地址 (HTTP 403)',
        message: '原版 DSH 未放行访问主机名 `${probe.hostAuthority}`。请在电脑上用局域网 IP 启动 `dsh web` 后重试。',
        normalizedAddress: parsed.address,
        extractedToken: effectiveToken,
        extractedPairCode: effectivePairCode,
        capturedCookie: mintedCookie,
        hostName: parsed.suggestedName,
        dshVersion: probe.dshVersion,
        latencyMs: latencyMs,
        hostAuthority: probe.hostAuthority,
        isLoopbackTarget: isLoopback,
        suggestedCommand: cmd,
      );
    }
    return RemoteHostDiagnosis(
      kind: RemoteDiagnosisKind.readyDirect,
      title: '检测到电脑端 DSH 服务',
      message: '已探测到目标电脑（${latencyMs}ms），可继续建立会话连接。',
      normalizedAddress: parsed.address,
      extractedToken: effectiveToken,
      extractedPairCode: effectivePairCode,
      capturedCookie: mintedCookie,
      hostName: parsed.suggestedName,
      latencyMs: latencyMs,
      isLoopbackTarget: isLoopback,
    );
  }

  RemoteHostDiagnosis _diagnosisFromError(
    Object err, {
    required ParsedRemoteHostInput parsed,
    required Uri uri,
    required String? effectiveToken,
    required String? effectivePairCode,
  }) {
    final isLoopback = isLoopbackHost(uri.host);
    final classified = _classifyConnectionError(err, address: parsed.address);
    final isIp = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(uri.host);
    final portFlag = uri.hasPort && uri.port != 3080 ? ' --port ${uri.port}' : '';
    final cmd = (!isLoopback && classified.code == 'untrusted_host')
        ? (isIp
            ? 'dsh web --host ${uri.host}$portFlag'
            : 'dsh web --host <局域网IP>$portFlag')
        : null;
    final kind = switch (classified.code) {
      'tls_cert' => RemoteDiagnosisKind.selfSignedTls,
      'html_proxy' => RemoteDiagnosisKind.htmlLoginPage,
      'pairing_code_expired' => RemoteDiagnosisKind.pairingCodeExpired,
      'needs_auth' => RemoteDiagnosisKind.needsAuth,
      'untrusted_host' => RemoteDiagnosisKind.untrustedHost,
      'loopback_unreachable' => RemoteDiagnosisKind.selfDevice,
      _ => RemoteDiagnosisKind.unreachable,
    };
    return RemoteHostDiagnosis(
      kind: kind,
      title: switch (classified.code) {
        'tls_cert' => 'HTTPS 证书未受信任',
        'html_proxy' => '需要完成网页登录认证',
        'pairing_code_expired' => '配对二维码已失效',
        'needs_auth' => '需要授权连接',
        'untrusted_host' => '电脑端拒绝了当前访问地址 (HTTP 403)',
        'loopback_unreachable' => kIsWeb ? '这个地址指向当前浏览器所在设备' : '这个地址指向当前设备自己',
        _ => '暂时连不上目标电脑',
      },
      message: classified.message,
      technicalDetail: classified.technicalDetail,
      normalizedAddress: parsed.address,
      extractedToken: effectiveToken,
      extractedPairCode: effectivePairCode,
      hostName: parsed.suggestedName,
      isLoopbackTarget: isLoopback,
      suggestedCommand: cmd,
    );
  }

  /// Atomic staged pairing & connection orchestrator:
  /// 1. Parses input and validates self-device / cleartext-HTTP guards WITHOUT touching the user's
  ///    current host, active session, or composer drafts.
  /// 2. Creates an isolated staging [GbridgeClient], exchanges token / pairCode once (preserving
  ///    any freshly minted 30-day session cookie), and probes host capabilities (`authorizing`).
  /// 3. Verifies BOTH real-time WebSocket handshake (`stream.connect()`) AND sessions API
  ///    (`listSessions()`) on the staging client (`openingSession`) BEFORE ever saving or
  ///    switching `activeHostId`.
  /// 4. If real-time handshake, sessions verification, or user cancellation fails at any stage,
  ///    disposes the staging client and leaves the original host, session, and drafts 100% intact!
  Future<RemoteConnectOutcome> connectRemoteInput(
    String rawInput, {
    String? name,
    String? token,
    String? pairCode,
    String? cookie,
    bool allowBadCertificates = false,
    bool allowInsecurePublicHttp = false,
    bool saveIfNeedsAuth = false,
    bool switchOnSuccess = true,
    void Function(PairingStage stage, {String? computerName})? onStageChanged,
    bool Function()? isCancelled,
  }) async {
    bool cancelled() => !mounted || (isCancelled?.call() == true);

    final parsed = parseRemoteHostInput(rawInput, explicitToken: token);
    if (parsed == null) {
      const diag = RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.invalidAddress,
        title: '链接或地址格式无效',
        message: '请粘贴电脑上的配对链接、`dsh web` 启动链接，或输入 `IP:端口`。',
      );
      onStageChanged?.call(PairingStage.failed);
      return const RemoteConnectOutcome(diagnosis: diag, connected: false);
    }

    final initialName = (name != null && name.trim().isNotEmpty)
        ? name.trim()
        : (parsed.suggestedName ?? parsed.address);
    onStageChanged?.call(PairingStage.connecting, computerName: initialName);

    final uri = Uri.parse(parsed.address);
    final isLoopback = isLoopbackHost(uri.host);
    await _refreshDeviceLocalIps();
    if (cancelled()) {
      return RemoteConnectOutcome(
        diagnosis: RemoteHostDiagnosis(
          kind: RemoteDiagnosisKind.unreachable,
          title: '已取消连接',
          message: '已取消本次连接，原对话未受影响。',
          normalizedAddress: parsed.address,
          hostName: initialName,
        ),
        connected: false,
        cancelled: true,
      );
    }
    final selfGuidance = selfDeviceGuidanceForUri(uri);
    if (selfGuidance != null) {
      final diag = RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.selfDevice,
        title: '这个地址指向当前设备自己',
        message: selfGuidance,
        normalizedAddress: parsed.address,
        hostName: initialName,
        isLoopbackTarget: isLoopback,
      );
      onStageChanged?.call(PairingStage.failed, computerName: initialName);
      return RemoteConnectOutcome(diagnosis: diag, connected: false);
    }

    final effectiveToken = parsed.token;
    final effectivePairCode =
        (pairCode != null && pairCode.trim().isNotEmpty) ? pairCode.trim() : parsed.pairCode;
    String? mintedCookie = (cookie != null && cookie.trim().isNotEmpty) ? cookie.trim() : null;

    if (!allowInsecurePublicHttp && isPublicCleartextHttpUri(uri)) {
      final diag = RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.insecurePublicHttp,
        title: '公网明文 HTTP 风险拦截',
        message: '检测到公网地址 ${uri.host} 使用未加密的 http://，已阻止在首次连接时明文发送 Token 或 Cookie。建议改用 https://（或 Tailscale / 局域网），如确需明文测试请确认后继续。',
        normalizedAddress: parsed.address,
        extractedToken: effectiveToken,
        extractedPairCode: effectivePairCode,
        capturedCookie: mintedCookie,
        hostName: initialName,
      );
      onStageChanged?.call(PairingStage.failed, computerName: initialName);
      return RemoteConnectOutcome(diagnosis: diag, connected: false);
    }

    final sw = Stopwatch()..start();
    GbridgeClient? stagingClient;
    var handedOff = false;
    var passedPreflight = false;
    String resolvedName = initialName;

    try {
      stagingClient = GbridgeClient(
        HostEndpoint.http(
          baseUri: uri,
          token: effectiveToken,
          cookie: mintedCookie,
          pairCode: effectivePairCode,
        ),
        timeout: const Duration(seconds: 12),
        allowBadCertificates: allowBadCertificates,
        autoReconnect: true,
        onCookieUpdated: (c) {
          final clean = c.trim();
          if (clean.isNotEmpty) mintedCookie = clean;
        },
      );

      onStageChanged?.call(PairingStage.authorizing, computerName: resolvedName);
      var exchangedTokenThisAttempt = false;
      if ((mintedCookie == null || mintedCookie!.isEmpty) &&
          effectiveToken != null &&
          effectiveToken.isNotEmpty) {
        exchangedTokenThisAttempt = true;
        try {
          await stagingClient.exchangeAuthToken(effectiveToken);
        } catch (_) {}
      }
      if (cancelled()) {
        return RemoteConnectOutcome(
          diagnosis: RemoteHostDiagnosis(
            kind: RemoteDiagnosisKind.unreachable,
            title: '已取消连接',
            message: '已取消本次连接，原对话未受影响。',
            normalizedAddress: parsed.address,
            hostName: resolvedName,
          ),
          connected: false,
          cancelled: true,
        );
      }

      var probe = await stagingClient.probeHost();
      if (probe is HostProbeNeedsAuth &&
          !probe.isPairingCodeExpired &&
          !exchangedTokenThisAttempt &&
          effectiveToken != null &&
          effectiveToken.isNotEmpty) {
        stagingClient.transport.evictDshAuthCookies();
        mintedCookie = stagingClient.transport.cookieHeader;
        try {
          await stagingClient.exchangeAuthToken(effectiveToken);
        } catch (_) {}
        if (cancelled()) {
          return RemoteConnectOutcome(
            diagnosis: RemoteHostDiagnosis(
              kind: RemoteDiagnosisKind.unreachable,
              title: '已取消连接',
              message: '已取消本次连接，原对话未受影响。',
              normalizedAddress: parsed.address,
              hostName: resolvedName,
            ),
            connected: false,
            cancelled: true,
          );
        }
        probe = await stagingClient.probeHost();
      }
      final liveCookie = stagingClient.transport.cookieHeader?.trim();
      if (liveCookie != null && liveCookie.isNotEmpty) {
        mintedCookie = liveCookie;
      }
      sw.stop();
      final ms = sw.elapsedMilliseconds.clamp(1, 99999);

      final probeDiag = _diagnosisFromProbe(
        probe,
        parsed: parsed,
        uri: uri,
        effectiveToken: effectiveToken,
        effectivePairCode: effectivePairCode,
        mintedCookie: mintedCookie,
        latencyMs: ms,
      );
      if (probeDiag.hostName != null && probeDiag.hostName!.trim().isNotEmpty) {
        resolvedName = (name != null && name.trim().isNotEmpty)
            ? name.trim()
            : probeDiag.hostName!.trim();
      }

      if (probe is! HostProbeFull && probe is! HostProbeVanillaDirect) {
        if (saveIfNeedsAuth && probeDiag.needsWebOrTokenAuth) {
          final saved = addRemoteHost(
            parsed.address,
            name: resolvedName,
            token: probeDiag.extractedToken ?? token,
            cookie: probeDiag.capturedCookie ?? cookie,
            allowBadCertificates: allowBadCertificates,
            autoProbe: false,
            silent: true,
          );
          onStageChanged?.call(PairingStage.failed, computerName: resolvedName);
          return RemoteConnectOutcome(diagnosis: probeDiag, host: saved, connected: false);
        }
        onStageChanged?.call(PairingStage.failed, computerName: resolvedName);
        return RemoteConnectOutcome(diagnosis: probeDiag, connected: false);
      }

      passedPreflight = true;
      final isDirect = probe is HostProbeVanillaDirect;
      final Capabilities caps;
      if (probe is HostProbeFull) {
        caps = probe.capabilities;
      } else {
        caps = stagingClient.enableVanillaDirectMode(
          dshVersion: (probe as HostProbeVanillaDirect).dshVersion,
          hostName: resolvedName,
        );
      }

      // Stage 3: Verify BOTH real-time WebSocket handshake AND sessions list BEFORE
      // ever saving or switching activeHostId!
      onStageChanged?.call(PairingStage.openingSession, computerName: resolvedName);
      final welcome = await stagingClient.stream.connect().timeout(const Duration(seconds: 12));
      if (cancelled()) {
        return RemoteConnectOutcome(
          diagnosis: RemoteHostDiagnosis(
            kind: RemoteDiagnosisKind.unreachable,
            title: '已取消连接',
            message: '已取消本次连接，原对话未受影响。',
            normalizedAddress: parsed.address,
            hostName: resolvedName,
          ),
          connected: false,
          cancelled: true,
        );
      }

      final liveSessions = await stagingClient.listSessions().timeout(const Duration(seconds: 12));
      if (cancelled()) {
        return RemoteConnectOutcome(
          diagnosis: RemoteHostDiagnosis(
            kind: RemoteDiagnosisKind.unreachable,
            title: '已取消连接',
            message: '已取消本次连接，原对话未受影响。',
            normalizedAddress: parsed.address,
            hostName: resolvedName,
          ),
          connected: false,
          cancelled: true,
        );
      }

      // BOTH real-time handshake AND sessions API succeeded! Now atomically save & commit.
      final saved = addRemoteHost(
        parsed.address,
        name: resolvedName,
        token: probeDiag.extractedToken ?? token,
        cookie: probeDiag.capturedCookie ?? cookie,
        allowBadCertificates: allowBadCertificates,
        autoProbe: false,
        silent: true,
      );
      if (saved == null) {
        onStageChanged?.call(PairingStage.failed, computerName: resolvedName);
        return RemoteConnectOutcome(diagnosis: probeDiag, connected: false);
      }
      final latLabel = '${ms}ms';
      if (switchOnSuccess) {
        handedOff = true;
        await _commitVerifiedRemoteHost(
          saved,
          stagingClient,
          caps,
          isDirect: isDirect,
          latencyLabel: latLabel,
          initialWelcome: welcome,
          preloadedSessions: liveSessions,
        );
      } else {
        // Saved without switching: mark host metadata verified and dispose staging client.
        state = state.copyWith(
          hosts: [
            for (final h in state.hosts)
              h.id == saved.id
                  ? h.copyWith(
                      bridged: !isDirect,
                      directMode: isDirect,
                      online: true,
                      latency: latLabel,
                      dshVersion: caps.dshVersion,
                      helperVersion: isDirect ? null : caps.bridgeVersion,
                      clearLastError: true,
                    )
                  : h,
          ],
        );
      }
      final latest = state.hosts.firstWhere((h) => h.id == saved.id, orElse: () => saved);
      final readyDiag = RemoteHostDiagnosis(
        kind: probeDiag.kind,
        title: '已连接到「${latest.name}」',
        message: liveSessions.isNotEmpty
            ? '已建立实时连接，可立即打开 ${liveSessions.length} 条会话或开始新对话（$latLabel）。'
            : '已建立实时连接，可以开始在这台电脑上对话（$latLabel）。',
        normalizedAddress: parsed.address,
        extractedToken: probeDiag.extractedToken,
        extractedPairCode: effectivePairCode,
        capturedCookie: mintedCookie,
        hostName: latest.name,
        dshVersion: caps.dshVersion,
        latencyMs: ms,
        hasGbridge: !isDirect,
        isLoopbackTarget: isLoopback,
      );
      onStageChanged?.call(PairingStage.ready, computerName: latest.name);
      return RemoteConnectOutcome(
        diagnosis: readyDiag,
        host: latest,
        connected: true,
        sessionCount: liveSessions.length,
      );
    } catch (e) {
      sw.stop();
      if (cancelled()) {
        return RemoteConnectOutcome(
          diagnosis: RemoteHostDiagnosis(
            kind: RemoteDiagnosisKind.unreachable,
            title: '已取消连接',
            message: '已取消本次连接，原对话未受影响。',
            normalizedAddress: parsed.address,
            hostName: resolvedName,
          ),
          connected: false,
          cancelled: true,
        );
      }
      final RemoteHostDiagnosis failDiag;
      if (passedPreflight) {
        final lower = e.toString().toLowerCase();
        final isAuthErr = (e is GbridgeException && (e.status == 401 || e.status == 403)) ||
            lower.contains('401') ||
            lower.contains('unauthorized');
        if (isAuthErr) {
          failDiag = RemoteHostDiagnosis(
            kind: effectivePairCode != null && effectivePairCode.isNotEmpty
                ? RemoteDiagnosisKind.pairingCodeExpired
                : RemoteDiagnosisKind.needsAuth,
            title: '授权校验未通过',
            message: '电脑可以连通，但实时连接阶段授权被拒绝。原对话和当前输入均已保留，请重新扫码或更新链接。',
            technicalDetail: e.toString().trim(),
            normalizedAddress: parsed.address,
            extractedToken: effectiveToken,
            extractedPairCode: effectivePairCode,
            capturedCookie: mintedCookie,
            hostName: resolvedName,
            isLoopbackTarget: isLoopback,
          );
        } else {
          failDiag = RemoteHostDiagnosis(
            kind: RemoteDiagnosisKind.realtimeFailed,
            title: '实时连接未能建立',
            message: '已连通「$resolvedName」，但实时通道或会话接口未能正常打开。你原来的对话与草稿都已保留，可直接重试。',
            technicalDetail: e.toString().trim(),
            normalizedAddress: parsed.address,
            extractedToken: effectiveToken,
            extractedPairCode: effectivePairCode,
            capturedCookie: mintedCookie,
            hostName: resolvedName,
            isLoopbackTarget: isLoopback,
          );
        }
      } else {
        failDiag = _diagnosisFromError(
          e,
          parsed: parsed,
          uri: uri,
          effectiveToken: effectiveToken,
          effectivePairCode: effectivePairCode,
        );
      }
      onStageChanged?.call(PairingStage.failed, computerName: resolvedName);
      return RemoteConnectOutcome(diagnosis: failDiag, connected: false);
    } finally {
      if (!handedOff && stagingClient != null) {
        unawaited(stagingClient.dispose().catchError((_) {}));
      }
    }
  }

  /// Atomically transitions from the previous host to an already-verified [stagingClient]
  /// whose WebSocket handshake AND sessions list have already succeeded.
  Future<void> _commitVerifiedRemoteHost(
    ManagedHost target,
    GbridgeClient stagingClient,
    Capabilities caps, {
    required bool isDirect,
    required String latencyLabel,
    required WelcomeInfo initialWelcome,
    required List<SessionSummary> preloadedSessions,
  }) async {
    final hostId = target.id;
    final isSameHostReconnect = state.activeHostId == hostId;
    final prevActiveSessionId = state.activeSessionId;
    if (!isSameHostReconnect || state.pendingAttachments.isNotEmpty || prevActiveSessionId != null) {
      _stashPendingAttachmentsForScope(state.activeHostId, prevActiveSessionId);
      _stashQueuedMessagesForScope(state.activeHostId, prevActiveSessionId);
      _saveCurrentHostContext(hostIdOverride: state.activeHostId);
    }
    final gen = ++_hostConnectGen;
    _modelSelectionGen++;
    _lastAutoSyncedDefaultKey = null;
    _hostProbeGen[hostId] = (_hostProbeGen[hostId] ?? 0) + 1;
    _streamRunId++;
    _userNavigatedSinceHostBind = false;
    _detachLiveClientsSync();

    final mappedSessions = _mapSessionSummaries(preloadedSessions);
    state = state.copyWith(
      activeHostId: hostId,
      clearActiveSession: true,
      clearParentSession: true,
      clearSidebarWorkspaceFilter: true,
      clearPendingApproval: true,
      clearActiveQuestion: true,
      clearActiveCordisRequest: true,
      clearOfflineUnsentNotice: true,
      pendingInteractions: const [],
      clearAccountSnapshot: true,
      clearUpdateCheck: true,
      clearTurnsNextCursor: true,
      clearSessionLoadError: true,
      clearMarketError: true,
      checkingUpdate: false,
      hasMoreTurns: false,
      loadingOlderTurns: false,
      searchingMarket: false,
      speechConfigured: false,
      accountSigningIn: false,
      turnProcessOpen: !state.autoFoldSteps,
      activeWorkspace: '',
      activePresetId: 'standard',
      activePermissionId: 'workspace-write',
      planMode: false,
      slashCommands: kDefaultSlashCommands,
      activeModelProvider: '',
      activeModelId: '',
      modelName: '未连接模型',
      modelShort: '未连接',
      modelEffort: '',
      modelEffortId: '',
      presets: kPresetOptions,
      permissionTiers: kPermissionTiers,
      searchQuery: '',
      searchSnippets: const {},
      filter: SessionFilter.all,
      sessions: mappedSessions,
      loadingSessions: false,
      hydratingDomains: true,
      initialDomainsHydrated: false,
      workspaces: const [],
      turns: const [],
      turnFeedback: const {},
      stepTranslations: const {},
      translatedStepIds: const {},
      translatingStepIds: const {},
      expandedTurnProcessIds: const {},
      collapsedTurnProcessIds: const {},
      expandedStepIds: const {},
      pendingAttachments: _restorePendingAttachmentsForScope(
        hostId,
        isSameHostReconnect ? prevActiveSessionId : null,
      ),
      workspaceFiles: const [],
      workspaceCurrentPath: '',
      workspaceDiffs: const [],
      activeDiffScope: 'uncommitted',
      todos: const [],
      goals: const [],
      subagents: const [],
      jobs: const [],
      schedules: const [],
      marketPlugins: const [],
      dynamicCordis: const [],
      modelGroups: const [],
      routableProviders: const [],
      providerCredentials: const [],
      dshNamespaces: const [],
      dshSettingsSections: const [],
      dshDynamicOptions: const {},
      engineSchema: const {},
      engineValues: const {},
      mcpServers: const [],
      plugins: const [],
      sduiSurfaces: const [],
      sduiViews: const {},
      queuedMessages: const [],
      toolOutputCache: const {},
      engineLogs: const [],
      sessionTelemetry: const SessionTelemetry(),
      loadingSession: false,
      isStreaming: false,
      isStopping: false,
      streamStalled: false,
      sendStage: SendStage.idle,
      uploadDoneCount: 0,
      uploadTotalCount: 0,
      activePendingInteractionCount: 0,
      contextPct: 0,
      contextUsedK: 0,
      contextMaxK: 128,
      contextBreakdown: const {},
      connectionPhase: ConnectionPhase.connected,
      sessionRenderGen: state.sessionRenderGen + 1,
      newChatSignal: state.newChatSignal + 1,
    );
    _persistPrefs();

    await _bindFullLiveClient(
      stagingClient,
      hostId,
      caps,
      gen: gen,
      isDirect: isDirect,
      latencyLabel: latencyLabel,
      restoreLastSession: true,
      alreadyConnected: true,
      initialWelcome: initialWelcome,
      hasPreloadedSessions: true,
    );
  }

  /// Probe a non-active host without touching `_liveClient` or the active host's sessions.
  Future<void> _probeHostOnly(ManagedHost host) async {
    final probeGen = (_hostProbeGen[host.id] ?? 0) + 1;
    _hostProbeGen[host.id] = probeGen;
    bool isStaleProbe() =>
        !mounted ||
        _hostProbeGen[host.id] != probeGen ||
        (state.activeHostId == host.id && _liveClient != null);
    GbridgeClient? client;
    try {
      final addr = _normalizeHttpAddress(host);
      final uri = Uri.tryParse(addr);
      if (uri == null || !uri.hasScheme) return;
      final token = host.token ?? uri.queryParameters['token'];
      final cleanUri = _stripUriQuery(uri);
      final sw = Stopwatch()..start();
      client = GbridgeClient(
        HostEndpoint.http(
          baseUri: cleanUri,
          token: token,
          cookie: host.sessionCookie,
        ),
        timeout: const Duration(seconds: 12),
        allowBadCertificates: host.allowBadCertificates,
        autoReconnect: false,
        onCookieUpdated: (c) => _persistHostCookie(host.id, c),
      );
      var exchangedTokenThisAttempt = false;
      if (!host.hasSavedCookie && token != null && token.isNotEmpty) {
        exchangedTokenThisAttempt = true;
        try {
          await client.exchangeAuthToken(token);
        } catch (_) {}
      }
      var probe = await client.probeHost();
      // If a cached DSH cookie went stale while we still hold a token, evict only stale DSH cookies
      // (preserving reverse-proxy SSO cookies) and re-exchange the token once before concluding auth is required!
      if (probe is HostProbeNeedsAuth &&
          !exchangedTokenThisAttempt &&
          token != null &&
          token.isNotEmpty) {
        if (isStaleProbe()) return;
        client.transport.evictDshAuthCookies();
        try {
          await client.exchangeAuthToken(token);
        } catch (_) {}
        if (isStaleProbe()) return;
        probe = await client.probeHost();
      }
      sw.stop();
      final latLabel = '${sw.elapsedMilliseconds.clamp(1, 99999)}ms';
      if (isStaleProbe()) return;
      if (probe is HostProbeFull) {
        final caps = probe.capabilities;
        final hostEnvLabel = caps.host.isLocalAndroid
            ? null
            : switch (caps.host.platform.toLowerCase()) {
                'darwin' => 'macOS · ${caps.host.arch}',
                'win32' => 'Windows · ${caps.host.arch}',
                'linux' => 'Linux · ${caps.host.arch}',
                _ => '${caps.host.platform} · ${caps.host.arch}',
              };
        state = state.copyWith(
          hosts: [
            for (final h in state.hosts)
              h.id == host.id
                  ? h.copyWith(
                      bridged: true,
                      directMode: false,
                      online: true,
                      latency: latLabel,
                      clearLastError: true,
                      dshVersion: caps.dshVersion,
                      helperVersion: caps.bridgeVersion,
                      containerVersion: hostEnvLabel ?? h.containerVersion,
                      containerLatest: hostEnvLabel ?? h.containerVersion,
                    )
                  : h,
          ],
        );
      } else if (probe is HostProbeVanillaDirect) {
        state = state.copyWith(
          hosts: [
            for (final h in state.hosts)
              h.id == host.id
                  ? h.copyWith(
                      bridged: false,
                      directMode: true,
                      online: true,
                      latency: latLabel,
                      clearLastError: true,
                      dshVersion: probe.dshVersion,
                      containerVersion: '原生直连 · 免插件',
                      containerLatest: '原生直连 · 免插件',
                    )
                  : h,
          ],
        );
      } else if (probe is HostProbeNeedsAuth) {
        final errCode = probe.isHtmlLoginPage ? 'html_proxy' : 'needs_auth';
        final verText = probe.dshVersion != null ? 'DSH ${probe.dshVersion}' : '远程主机';
        state = state.copyWith(
          hosts: [
            for (final h in state.hosts)
              h.id == host.id
                  ? h.copyWith(
                      bridged: false,
                      directMode: false,
                      online: false,
                      latency: latLabel,
                      dshVersion: probe.dshVersion ?? h.dshVersion,
                      lastErrorCode: errCode,
                      lastError: probe.isHtmlLoginPage
                          ? '$verText 需先完成网页登录认证，请点击「App 内网页登录」自动同步凭证'
                          : '已发现 $verText，需要一次鉴权（网页登录或粘贴一次启动链接后即可 30 天免密）',
                    )
                  : h,
          ],
        );
      } else if (probe is HostProbeUntrustedHost) {
        state = state.copyWith(
          hosts: [
            for (final h in state.hosts)
              h.id == host.id
                  ? h.copyWith(
                      bridged: false,
                      directMode: false,
                      online: false,
                      latency: latLabel,
                      dshVersion: probe.dshVersion ?? h.dshVersion,
                      lastErrorCode: 'untrusted_host',
                      lastError:
                          '远程 DSH 拒绝了 Host `${probe.hostAuthority}` (HTTP 403)，请在远程主机使用 `dsh web --host ${cleanUri.host}` 或 `--trusted-host ${probe.hostAuthority}` 启动',
                    )
                  : h,
          ],
        );
      } else if (probe is HostProbeBootstrapOnly) {
        state = state.copyWith(
          hosts: [
            for (final h in state.hosts)
              h.id == host.id
                  ? h.copyWith(
                      bridged: false,
                      directMode: false,
                      online: true,
                      latency: latLabel,
                      clearLastError: true,
                      dshVersion: probe.dshVersion ?? h.dshVersion,
                    )
                  : h,
          ],
        );
      }
    } catch (e) {
      if (isStaleProbe()) return;
      final classified = _classifyConnectionError(e, address: host.address);
      state = state.copyWith(
        hosts: [
          for (final h in state.hosts)
            h.id == host.id
                ? h.copyWith(
                    online: false,
                    lastErrorCode: classified.code,
                    lastError: classified.message,
                  )
                : h,
        ],
      );
    } finally {
      await client?.dispose();
    }
  }

  Future<void> _tryConnectLiveHost(
    ManagedHost host, {
    int? gen,
    bool restoreLastSession = true,
  }) async {
    final targetGen = gen ?? _hostConnectGen;
    GbridgeClient? client;
    var handedOff = false;
    try {
      await _disconnectLiveClients();
      if (!mounted || targetGen != _hostConnectGen) return;
      final addr = _normalizeHttpAddress(host);
      final uri = Uri.tryParse(addr);
      if (uri == null || !uri.hasScheme) {
        state = state.copyWith(
          loadingSessions: false,
          hydratingDomains: false,
          connectionPhase: ConnectionPhase.error,
          hosts: [
            for (final h in state.hosts)
              h.id == host.id
                  ? h.copyWith(
                      online: false,
                      lastErrorCode: 'invalid',
                      lastError: '无效的主机地址',
                    )
                  : h,
          ],
        );
        return;
      }
      final token = host.token ?? uri.queryParameters['token'];
      final cleanUri = _stripUriQuery(uri);
      final sw = Stopwatch()..start();
      client = GbridgeClient(
        HostEndpoint.http(
          baseUri: cleanUri,
          token: token,
          cookie: host.sessionCookie,
        ),
        timeout: const Duration(seconds: 15),
        allowBadCertificates: host.allowBadCertificates,
        onCookieUpdated: (c) => _persistHostCookie(host.id, c),
      );
      var exchangedTokenThisAttempt = false;
      if (!host.hasSavedCookie && token != null && token.isNotEmpty) {
        exchangedTokenThisAttempt = true;
        try {
          await client.exchangeAuthToken(token);
        } catch (_) {}
      }
      var probe = await client.probeHost();
      // If a stale DSH cookie failed auth while we hold a token, evict only stale DSH auth cookies
      // (preserving reverse-proxy SSO cookies) and retry token exchange once!
      if (probe is HostProbeNeedsAuth &&
          !exchangedTokenThisAttempt &&
          token != null &&
          token.isNotEmpty) {
        if (!mounted || targetGen != _hostConnectGen) return;
        client.transport.evictDshAuthCookies();
        try {
          await client.exchangeAuthToken(token);
        } catch (_) {}
        if (!mounted || targetGen != _hostConnectGen) return;
        probe = await client.probeHost();
      }
      sw.stop();
      final latLabel = '${sw.elapsedMilliseconds.clamp(1, 99999)}ms';
      if (!mounted || targetGen != _hostConnectGen) {
        return;
      }
      if (probe is HostProbeFull) {
        handedOff = true;
        await _bindFullLiveClient(
          client,
          host.id,
          probe.capabilities,
          gen: targetGen,
          isDirect: false,
          latencyLabel: latLabel,
          restoreLastSession: restoreLastSession,
        );
      } else if (probe is HostProbeVanillaDirect) {
        // ZERO-PLUGIN FULL DIRECT MODE against stock `dsh web`!
        final directCaps = client.enableVanillaDirectMode(
          dshVersion: probe.dshVersion,
          hostName: host.name,
        );
        handedOff = true;
        await _bindFullLiveClient(
          client,
          host.id,
          directCaps,
          gen: targetGen,
          isDirect: true,
          latencyLabel: latLabel,
          restoreLastSession: restoreLastSession,
        );
      } else if (probe is HostProbeNeedsAuth) {
        final errCode = probe.isHtmlLoginPage ? 'html_proxy' : 'needs_auth';
        final verText = probe.dshVersion != null ? 'DSH ${probe.dshVersion}' : host.name;
        state = state.copyWith(
          loadingSessions: false,
          hydratingDomains: false,
          connectionPhase: ConnectionPhase.needsAuth,
          clearLiveCapabilities: true,
          hosts: [
            for (final h in state.hosts)
              h.id == host.id
                  ? h.copyWith(
                      bridged: false,
                      directMode: false,
                      online: false,
                      latency: latLabel,
                      dshVersion: probe.dshVersion ?? h.dshVersion,
                      lastErrorCode: errCode,
                      lastError: probe.isHtmlLoginPage
                          ? '已连通 $verText，请点击「App 内网页登录」完成网关认证（认证后 30 天免填）'
                          : '已连通 $verText，粘贴一次启动链接或输入 Token 完成授权后即可 30 天免密直连',
                    )
                  : h,
          ],
        );
      } else if (probe is HostProbeUntrustedHost) {
        state = state.copyWith(
          loadingSessions: false,
          hydratingDomains: false,
          connectionPhase: ConnectionPhase.error,
          clearLiveCapabilities: true,
          hosts: [
            for (final h in state.hosts)
              h.id == host.id
                  ? h.copyWith(
                      bridged: false,
                      directMode: false,
                      online: false,
                      latency: latLabel,
                      dshVersion: probe.dshVersion ?? h.dshVersion,
                      lastErrorCode: 'untrusted_host',
                      lastError:
                          '远程 DSH 拒绝了访问主机名 `${probe.hostAuthority}` (HTTP 403)。请在远程主机用 `dsh web --host ${cleanUri.host}` 或 `--trusted-host ${probe.hostAuthority}` 启动。',
                    )
                  : h,
          ],
        );
      } else if (probe is HostProbeBootstrapOnly) {
        handedOff = true;
        _bootstrapClient = client;
        state = state.copyWith(
          loadingSessions: false,
          hydratingDomains: false,
          connectionPhase: ConnectionPhase.bootstrapping,
          clearLiveCapabilities: true,
          hosts: [
            for (final h in state.hosts)
              h.id == host.id
                  ? h.copyWith(
                      bridged: false,
                      directMode: false,
                      online: true,
                      latency: latLabel,
                      clearLastError: true,
                      dshVersion: probe.dshVersion ?? h.dshVersion,
                    )
                  : h,
          ],
        );
      }
    } catch (e) {
      if (!mounted || targetGen != _hostConnectGen) return;
      final classified = _classifyConnectionError(e, address: host.address);
      final isAuthPending =
          classified.code == 'needs_auth' || classified.code == 'html_proxy';
      state = state.copyWith(
        loadingSessions: false,
        hydratingDomains: false,
        connectionPhase: isAuthPending ? ConnectionPhase.needsAuth : ConnectionPhase.error,
        hosts: [
          for (final h in state.hosts)
            h.id == host.id
                ? h.copyWith(
                    online: false,
                    lastErrorCode: classified.code,
                    lastError: classified.message,
                  )
                : h,
        ],
      );
    } finally {
      if (!handedOff && client != null) {
        unawaited(client.dispose());
      }
    }
  }

  Future<void> _bindFullLiveClient(
    GbridgeClient client,
    String hostId,
    Capabilities caps, {
    int? gen,
    bool isDirect = false,
    String? latencyLabel,
    bool restoreLastSession = true,
    bool alreadyConnected = false,
    WelcomeInfo? initialWelcome,
    bool hasPreloadedSessions = false,
  }) async {
    if (!mounted || (gen != null && gen != _hostConnectGen)) {
      await client.dispose();
      return;
    }
    if (_liveClient != null && !identical(_liveClient, client)) {
      await _disconnectLiveClients();
      if (!mounted || (gen != null && gen != _hostConnectGen)) {
        await client.dispose();
        return;
      }
    }
    _liveClient = client;
    _hadInitialWelcome = alreadyConnected && initialWelcome != null;
    if (alreadyConnected && initialWelcome != null) {
      _interactionMutationSeq++;
      _pendingInteractionsById
        ..clear()
        ..addEntries(initialWelcome.pendingInteractions.map((item) => MapEntry(item.id, item)));
      _recomputeVisibleInteractions();
    }
    final hostEnvLabel = caps.host.isLocalAndroid
        ? null
        : (isDirect
            ? '原生直连 · 免插件'
            : switch (caps.host.platform.toLowerCase()) {
                'darwin' => 'macOS · ${caps.host.arch}',
                'win32' => 'Windows · ${caps.host.arch}',
                'linux' => 'Linux · ${caps.host.arch}',
                _ => '${caps.host.platform} · ${caps.host.arch}',
              });

    state = state.copyWith(
      activeHostId: hostId,
      liveCapabilities: caps,
      connectionPhase: alreadyConnected ? ConnectionPhase.connected : ConnectionPhase.connecting,
      loadingSessions: !hasPreloadedSessions,
      hydratingDomains: true,
      initialDomainsHydrated: false,
      hosts: [
        for (final h in state.hosts)
          h.id == hostId
              ? h.copyWith(
                  bridged: !isDirect,
                  directMode: isDirect,
                  online: true,
                  latency: latencyLabel ?? h.latency,
                  clearLastError: true,
                  dshVersion: caps.dshVersion,
                  dshLatest: state.updateCheck?.hasUpdate == true
                      ? state.updateCheck!.recommendedVersion
                      : caps.dshVersion,
                  helperVersion: isDirect ? null : caps.bridgeVersion,
                  containerVersion: hostEnvLabel ?? h.containerVersion,
                  containerLatest: hostEnvLabel ?? h.containerVersion,
                )
              : h,
      ],
    );

    // Stage-0 fast-path hydration starts IMMEDIATELY in parallel with WebSocket handshake
    // so the sidebar chat list refreshes within tens of milliseconds of switching hosts!
    // Never reset `_userNavigatedSinceHostBind` here: if the user already tapped New Chat or
    // started typing while `probeHost()` was in flight, their explicit intent MUST win!
    unawaited(
      _hydrateLiveDomains(
        client,
        restoreLastSession: restoreLastSession,
        allowEmptyModels: false,
      ),
    );

    _phaseSub = client.stream.phases.listen((phase) {
      if (!mounted || !identical(_liveClient, client)) return;
      final prev = state.connectionPhase;
      if (phase == ConnectionPhase.needsAuth) {
        _reconnectGraceTimer?.cancel();
        _reconnectGraceTimer = null;
        state = state.copyWith(
          connectionPhase: phase,
          loadingSessions: false,
          hydratingDomains: false,
          hosts: [
            for (final h in state.hosts)
              h.id == hostId
                  ? h.copyWith(
                      online: false,
                      bridged: false,
                      directMode: false,
                      lastErrorCode: 'needs_auth',
                      lastError: '远程会话认证已失效，请重新输入 Token 或网页登录',
                    )
                  : h,
          ],
        );
        return;
      }
      if (phase == ConnectionPhase.connected) {
        _reconnectGraceTimer?.cancel();
        _reconnectGraceTimer = null;
        final curHost = state.hosts.where((h) => h.id == hostId).firstOrNull;
        final needsOnlineRestore = curHost != null && !curHost.online;
        state = state.copyWith(
          connectionPhase: phase,
          hosts: needsOnlineRestore
              ? [
                  for (final h in state.hosts)
                    h.id == hostId
                        ? h.copyWith(
                            online: true,
                            bridged: !isDirect,
                            directMode: isDirect,
                            clearLastError: true,
                          )
                        : h,
                ]
              : state.hosts,
        );
      } else if (phase == ConnectionPhase.reconnecting && prev == ConnectionPhase.connected) {
        // Absorb brief WS blips (e.g. post-boot Cordis profile hot-reload, phone-control app switch,
        // or Android foreground resume) so the top status dot and chat stream NEVER flash offline!
        _reconnectGraceTimer?.cancel();
        final graceMs = (state.phoneLiveActive || state.isStreaming) ? 4000 : 2200;
        _reconnectGraceTimer = Timer(Duration(milliseconds: graceMs), () {
          if (!mounted || !identical(_liveClient, client)) return;
          if (client.stream.phase == ConnectionPhase.reconnecting &&
              state.connectionPhase == ConnectionPhase.connected) {
            state = state.copyWith(
              connectionPhase: ConnectionPhase.reconnecting,
              hosts: [
                for (final h in state.hosts)
                  h.id == hostId ? h.copyWith(online: false) : h,
              ],
            );
          }
        });
        return;
      } else {
        _reconnectGraceTimer?.cancel();
        _reconnectGraceTimer = null;
        final isLost = phase == ConnectionPhase.disconnected || phase == ConnectionPhase.error;
        state = state.copyWith(
          connectionPhase: phase,
          streamStalled: (isLost && state.isStreaming) ? true : state.streamStalled,
          loadingSessions: isLost ? false : state.loadingSessions,
          hydratingDomains: isLost ? false : state.hydratingDomains,
          hosts: isLost
              ? [
                  for (final h in state.hosts)
                    h.id == hostId ? h.copyWith(online: false) : h,
                ]
              : state.hosts,
        );
      }
    });
    _welcomeSub = client.stream.welcomes.listen((welcome) {
      if (!mounted || !identical(_liveClient, client)) return;
      final isReconnect = _hadInitialWelcome;
      _hadInitialWelcome = true;
      _interactionMutationSeq++;
      _pendingInteractionsById
        ..clear()
        ..addEntries(welcome.pendingInteractions.map((item) => MapEntry(item.id, item)));
      _recomputeVisibleInteractions();
      if (!welcome.resumed && isReconnect) {
        if (!state.hasAvailableModels && !state.hydratingDomains) {
          state = state.copyWith(hydratingDomains: true);
        }
        unawaited(
          client.getCapabilities().then((nextCaps) {
            if (!mounted || !identical(_liveClient, client)) return;
            state = state.copyWith(liveCapabilities: nextCaps);
          }).catchError((_) {}),
        );
        // `_hydrateLiveDomains` Stage 0 already refreshes sessions/workspaces AND syncs `activeSessionId`.
        unawaited(_hydrateLiveDomains(client, allowEmptyModels: false));
      } else if (isReconnect) {
        final wasBg = _wasRecentlyBackgrounded;
        _wasRecentlyBackgrounded = false;
        final checkSid = state.activeSessionId;
        if (wasBg || DateTime.now().millisecondsSinceEpoch - _lastStage0HydrateMs > 2500) {
          unawaited(() async {
            await refreshSessionsList(silent: true);
            if (!mounted || !identical(_liveClient, client)) return;
            if (wasBg && checkSid != null && !checkSid.startsWith('pending-session-')) {
              await _syncLiveSessionBundle(
                checkSid,
                jumpToBottomOnLoad: false,
                authoritativeSync: true,
              );
            }
          }());
        }
        if (!wasBg &&
            state.isStreaming &&
            checkSid != null &&
            !checkSid.startsWith('pending-session-')) {
          // Even when `resumed == true`, schedule a lightweight safety check 1.5s later
          // in case `turn.completed` arrived while upstream was briefly interrupted.
          final activityBefore = _lastStreamActivityMs;
          _reconnectStreamCheckTimer?.cancel();
          _reconnectStreamCheckTimer = Timer(const Duration(milliseconds: 1500), () {
            if (!mounted || !identical(_liveClient, client)) return;
            if (state.isStreaming &&
                state.activeSessionId == checkSid &&
                _lastStreamActivityMs == activityBefore) {
              unawaited(_syncLiveSessionBundle(
                checkSid,
                jumpToBottomOnLoad: false,
                authoritativeSync: true,
              ));
            }
          });
        }
      }
    });
    _streamSub = client.stream.frames.listen((frame) {
      if (!mounted || !identical(_liveClient, client)) return;
      _handleLiveStreamFrame(client, frame);
    });
    if (alreadyConnected) {
      client.stream.subscribe('host');
      final activeSid = state.activeSessionId;
      if (activeSid != null && !activeSid.startsWith('pending-session-')) {
        client.stream.subscribe('session:$activeSid');
      }
    } else {
      unawaited(
        client.stream.connect().then((_) {
          if (!mounted || !identical(_liveClient, client)) return;
          client.stream.subscribe('host');
          final activeSid = state.activeSessionId;
          if (activeSid != null && !activeSid.startsWith('pending-session-')) {
            client.stream.subscribe('session:$activeSid');
          }
        }).catchError((_) {}),
      );
    }
  }

  List<ChatSessionItem> _mapSessionSummaries(List<SessionSummary> liveSessions) {
    final sortedSessions = List<SessionSummary>.of(liveSessions)
      ..sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));
    final hostUnread = _unreadSessionIdsByHost[state.activeHostId];
    return sortedSessions
        .where((s) =>
            s.id.isNotEmpty &&
            (!s.blank || s.running || s.id == state.activeSessionId))
        .map(
          (s) => ChatSessionItem(
            id: s.id,
            title: s.title,
            group: _sessionDateGroup(s.updatedAt),
            workspaceId: s.workspaceId,
            workspaceName: s.workspaceName,
            cwd: s.cwd,
            updatedAt: s.updatedAt,
            agentPreset: s.agentPreset,
            lastModelId: s.lastModelId,
            running: s.running,
            pendingApproval: s.pendingApproval,
            unread: s.id == state.activeSessionId
                ? false
                : (s.unread || (hostUnread?.contains(s.id) ?? false)),
            pinned: s.pinned,
            archived: s.archived,
          ),
        )
        .toList(growable: false);
  }

  List<WorkspaceItem> _mapWorkspacesResp(Map<String, dynamic> workspacesResp) {
    final rawWs = workspacesResp['workspaces'];
    final mappedWs = <WorkspaceItem>[];
    if (rawWs is List) {
      for (final w in rawWs) {
        if (w is! Map) continue;
        final id = (w['workspaceId'] ?? w['id'] ?? '').toString();
        final path = w['rootPath']?.toString() ?? w['path']?.toString() ?? w['cwd']?.toString() ?? '';
        if (id.isEmpty && path.isEmpty) continue;
        final sids = (w['sessionIds'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList(growable: false) ??
            const <String>[];
        mappedWs.add(
          WorkspaceItem(
            id: id.isEmpty ? path : id,
            name: (w['title'] ?? w['name'])?.toString() ?? _basenamePath(path),
            path: path,
            branch: w['branch']?.toString() ?? '',
            explicit: w['explicit'] == true,
            sessionIds: sids,
            sessionCount: (w['sessionCount'] as num?)?.toInt() ?? sids.length,
          ),
        );
      }
    }
    return mappedWs;
  }

  Future<void> refreshSessionsList({bool silent = false}) async {
    final client = _liveClient;
    if (client == null) {
      if (!silent) {
        await probeAndRefreshHost(state.activeHostId);
      }
      return;
    }
    if (!silent) {
      state = state.copyWith(loadingSessions: true);
    }
    try {
      final results = await Future.wait([
        client.listSessions(includeArchived: true),
        client.listWorkspaces().catchError((_) => const <String, dynamic>{}),
      ]);
      if (!mounted || !identical(_liveClient, client)) return;
      final liveSessions = results[0] as List<SessionSummary>;
      final workspacesResp = results[1] as Map<String, dynamic>;
      final mappedSessions = _mapSessionSummaries(liveSessions);
      // Preserve any optimistic `pending-session-...` item currently being created so
      // background refreshes never wipe it out or flicker the top title pill back to "新对话"!
      final pendingSid = state.activeSessionId;
      final pendingItem = (pendingSid != null && pendingSid.startsWith('pending-session-'))
          ? state.sessions.where((s) => s.id == pendingSid).firstOrNull
          : null;
      final effectiveSessions = (pendingItem != null && !mappedSessions.any((s) => s.id == pendingSid))
          ? [pendingItem, ...mappedSessions]
          : mappedSessions;
      final mappedWs = _mapWorkspacesResp(workspacesResp);
      final nextWsList = mappedWs.isNotEmpty || workspacesResp.containsKey('workspaces')
          ? mappedWs
          : state.workspaces;
      final nextActiveWs = nextWsList.isNotEmpty
          ? (nextWsList.any((w) =>
                  w.id == state.activeWorkspace ||
                  w.path == state.activeWorkspace ||
                  w.name == state.activeWorkspace)
              ? state.activeWorkspace
              : nextWsList.first.id)
          : state.activeWorkspace;
      final sessionsChanged = !listEquals(effectiveSessions, state.sessions);
      final wsChanged = !listEquals(nextWsList, state.workspaces);
      if (sessionsChanged ||
          wsChanged ||
          nextActiveWs != state.activeWorkspace ||
          state.loadingSessions) {
        state = state.copyWith(
          sessions: sessionsChanged ? effectiveSessions : state.sessions,
          workspaces: wsChanged ? nextWsList : state.workspaces,
          activeWorkspace: nextActiveWs,
          loadingSessions: false,
        );
      }
      _recomputeVisibleInteractions();
      if (!silent) {
        showToast(
          '已刷新「${state.activeHost.name}」的对话列表（${mappedSessions.length} 条）',
          tone: ToastTone.info,
        );
      }
    } catch (e) {
      if (!mounted || !identical(_liveClient, client)) return;
      state = state.copyWith(loadingSessions: false);
      if (!silent) {
        showToast('刷新对话列表失败：${formatReadableError(e)}', tone: ToastTone.warn);
      }
    }
  }

  Future<void> _hydrateLiveDomains(
    GbridgeClient client, {
    int attempt = 0,
    bool skipAutoDefaultSync = false,
    bool restoreLastSession = false,
    bool allowEmptyModels = true,
  }) async {
    final myHydrateGen = ++_hydrationGen;
    _lastStage0HydrateMs = DateTime.now().millisecondsSinceEpoch;
    _refWorkspaceFilesCache = null;
    _domainRetryTimer?.cancel();
    _domainRetryTimer = null;
    try {
      // Launch Stage 0 (sessions + workspaces) AND Stage 1 (models, schema, presets, permissions, account)
      // CONCURRENTLY so startup cuts a full serial round-trip while Stage 0 still commits first!
      var sessionsFailed = false;
      var workspacesFailed = false;
      final hydrateModelGen = _modelSelectionGen;
      final hydratePresetGen = _presetSelectionGen;
      final hydratePermissionGen = _permissionSelectionGen;
      var modelsFailed = false;
      final stage1Future = Future.wait([
        client.getSettingsSchema().catchError((_) => const <String, dynamic>{}),
        client.getSettingsManifest().catchError((_) => const <String, dynamic>{}),
        client.listPresets().catchError((_) => const <String, dynamic>{}),
        client.getModels().catchError((_) {
          modelsFailed = true;
          return const <String, dynamic>{};
        }),
        client.getPermissionsCatalog().catchError((_) => const <String, dynamic>{}),
        client.getAccount().catchError((_) => const <String, dynamic>{}),
      ]);
      final fastResults = await Future.wait([
        client.listSessions(includeArchived: true).catchError((_) {
          sessionsFailed = true;
          return const <SessionSummary>[];
        }),
        client.listWorkspaces().catchError((_) {
          workspacesFailed = true;
          return const <String, dynamic>{};
        }),
      ]);
      if (!mounted || !identical(_liveClient, client) || myHydrateGen != _hydrationGen) return;

      final liveSessions = fastResults[0] as List<SessionSummary>;
      final workspacesResp = fastResults[1] as Map<String, dynamic>;
      final hasValidWorkspaces = !workspacesFailed && workspacesResp.containsKey('workspaces');
      final mappedSessions = _mapSessionSummaries(liveSessions);
      final mappedWs = hasValidWorkspaces ? _mapWorkspacesResp(workspacesResp) : state.workspaces;

      // Restore per-host view context (last workspace, sidebar filter, and last active session)
      // strictly scoped to `state.activeHostId` AND verified against this host's origin —
      // NEVER matching sessions by title or across different hosts!
      final savedCtx = _hostContexts[state.activeHostId];
      final currentOrigin = _hostOriginKey(state.activeHostId);
      final savedOrigin = savedCtx?['lastHostOrigin']?.toString().trim().toLowerCase() ?? '';
      final originMatches =
          savedOrigin.isEmpty || currentOrigin.isEmpty || savedOrigin == currentOrigin;
      final savedWs = originMatches ? (savedCtx?['lastWorkspace']?.toString() ?? '') : '';
      final savedFilter =
          originMatches ? (savedCtx?['sidebarWorkspaceFilter']?.toString() ?? '') : '';
      final savedSid = originMatches ? (savedCtx?['lastSessionId']?.toString() ?? '') : '';

      WorkspaceItem? findWorkspace(String key) {
        if (key.isEmpty) return null;
        return mappedWs.where((w) => w.id == key).firstOrNull ??
            mappedWs.where((w) => w.path.isNotEmpty && w.path == key).firstOrNull ??
            mappedWs.where((w) => w.name == key).firstOrNull;
      }

      String resolvedWorkspace = state.activeWorkspace;
      if (hasValidWorkspaces && mappedWs.isNotEmpty) {
        final matchedCur = findWorkspace(state.activeWorkspace);
        final matchedSaved = matchedCur ?? findWorkspace(savedWs);
        resolvedWorkspace = (matchedSaved ?? mappedWs.first).id;
      }

      final effectiveSessions = sessionsFailed && state.sessions.isNotEmpty
          ? state.sessions
          : () {
              final pendingSid = state.activeSessionId;
              final pendingItem = (pendingSid != null && pendingSid.startsWith('pending-session-'))
                  ? state.sessions.where((s) => s.id == pendingSid).firstOrNull
                  : null;
              return (pendingItem != null && !mappedSessions.any((s) => s.id == pendingSid))
                  ? [pendingItem, ...mappedSessions]
                  : mappedSessions;
            }();

      final candidateFilter = state.sidebarWorkspaceFilter ?? (savedFilter.isNotEmpty ? savedFilter : null);
      String? resolvedFilter;
      if (candidateFilter != null && candidateFilter.isNotEmpty) {
        final matchedFilterWs = findWorkspace(candidateFilter);
        if (matchedFilterWs != null) {
          resolvedFilter = matchedFilterWs.id;
        } else if (effectiveSessions.any(
          (s) => s.workspaceId == candidateFilter || s.cwd == candidateFilter,
        )) {
          resolvedFilter = candidateFilter;
        }
      }

      state = state.copyWith(
        sessions: effectiveSessions,
        workspaces: mappedWs,
        activeWorkspace: resolvedWorkspace,
        sidebarWorkspaceFilter: resolvedFilter,
        clearSidebarWorkspaceFilter: resolvedFilter == null,
        loadingSessions: false,
      );
      _recomputeVisibleInteractions();

      // Restore this host's last open session ONLY on initial host bind when:
      // 1. User hasn't tapped New Chat / switched session / typed a draft during connect;
      // 2. Saved session belongs strictly to THIS host's origin and matches by exact UUID `id`;
      // Otherwise stay cleanly on the New Chat empty stage (NEVER open a same-title or first session!).
      if (state.activeSessionId != null) {
        if (!state.activeSessionId!.startsWith('pending-session-')) {
          unawaited(_syncLiveSessionBundle(
            state.activeSessionId!,
            authoritativeSync: true,
          ));
        }
      } else if (restoreLastSession &&
          !_userNavigatedSinceHostBind &&
          attempt == 0 &&
          getComposerDraftForActiveHost().trim().isEmpty &&
          savedSid.isNotEmpty &&
          effectiveSessions.any((s) => s.id == savedSid)) {
        selectSession(savedSid);
      } else if (mappedWs.isNotEmpty) {
        unawaited(loadWorkspaceDirectory(path: '.'));
        unawaited(refreshWorkspaceDiffs(silent: true));
      }

      if (sessionsFailed && attempt == 0 && identical(_liveClient, client)) {
        Future<void>.delayed(const Duration(milliseconds: 1200), () {
          if (mounted && identical(_liveClient, client) && state.sessions.isEmpty) {
            unawaited(refreshSessionsList(silent: true));
          }
        });
      }

      // Stage 1 (Core engine config, models, presets, permissions, account — already running in parallel!)
      final coreResults = await stage1Future;
      if (!mounted || !identical(_liveClient, client) || myHydrateGen != _hydrationGen) return;

      final schemaResp = coreResults[0];
      final manifestResp = coreResults[1];
      final presetsResp = coreResults[2];
      final modelsResp = coreResults[3];
      final permsResp = coreResults[4];
      final accountResp = coreResults[5];

      var next = state;

      // 0. Dynamic Settings Manifest directly from connected DSH host!
      final rawManifestSections = manifestResp['sections'];
      if (rawManifestSections is List && rawManifestSections.isNotEmpty) {
        final parsedSections = rawManifestSections
            .whereType<Map<dynamic, dynamic>>()
            .map((e) => DshSettingsSectionManifest.fromJson(Map<String, dynamic>.from(e)))
            .where((s) => s.id.isNotEmpty)
            .toList(growable: false)
          ..sort((a, b) => a.order.compareTo(b.order));
        final rawDynOpts = manifestResp['dynamicOptions'];
        final parsedDynOpts = <String, List<DshDynamicOption>>{};
        if (rawDynOpts is Map) {
          for (final entry in rawDynOpts.entries) {
            if (entry.value is List) {
              parsedDynOpts[entry.key.toString()] = (entry.value as List)
                  .whereType<Map<dynamic, dynamic>>()
                  .map((e) => DshDynamicOption.fromJson(Map<String, dynamic>.from(e)))
                  .where((o) => o.value.isNotEmpty)
                  .toList(growable: false);
            }
          }
        }
        next = next.copyWith(
          dshSettingsSections: parsedSections,
          dshDynamicOptions: parsedDynOpts,
        );
      }

      // 3. REAL Model Catalog (`catalog.groups`, `catalog.default`, `catalog.routableProviders`)
      ModelCatalogEntry? autoFallbackModel;
      String autoFallbackEffort = '';
      final rawCatalog = modelsResp['catalog'];
      if (rawCatalog is Map<String, dynamic>) {
        final routable = (rawCatalog['routableProviders'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList(growable: false) ??
            const <String>[];
        final routableSet = routable.toSet();
        final groups = <ModelCatalogGroup>[];
        final rawGroups = rawCatalog['groups'];
        if (rawGroups is List) {
          for (final g in rawGroups) {
            if (g is! Map) continue;
            final gid = g['id']?.toString() ?? '';
            final gname = g['name']?.toString() ?? gid;
            final rawModels = g['models'];
            final entries = <ModelCatalogEntry>[];
            if (rawModels is List) {
              for (final m in rawModels) {
                if (m is! Map) continue;
                final mid = m['id']?.toString() ?? '';
                if (mid.isEmpty) continue;
                final mname = m['name']?.toString() ?? mid;
                final reasoning = m['reasoning'];
                final efforts = <ModelEffortOption>[];
                var defEffort = '';
                if (reasoning is Map) {
                  if (reasoning['efforts'] is List) {
                    for (final ef in reasoning['efforts'] as List) {
                      if (ef is Map) {
                        efforts.add(ModelEffortOption.fromJson(Map<String, dynamic>.from(ef)));
                      }
                    }
                  }
                  final rawDef = reasoning['defaultEffort']?.toString().trim() ?? '';
                  if (efforts.isNotEmpty) {
                    defEffort = rawDef.isNotEmpty ? rawDef : efforts.first.id;
                  }
                }
                final rawInput = m['input'] ?? m['inputModalities'];
                final modalities = rawInput is List && rawInput.isNotEmpty
                    ? rawInput.map((e) => e.toString()).toList(growable: false)
                    : const <String>['text'];
                entries.add(
                  ModelCatalogEntry(
                    id: mid,
                    name: mname,
                    providerId: gid,
                    providerName: gname,
                    description: m['description']?.toString() ?? '',
                    efforts: efforts,
                    defaultEffort: defEffort,
                    contextWindow: (m['contextWindow'] as num?)?.toInt(),
                    maxTokens: (m['maxTokens'] as num?)?.toInt(),
                    inputModalities: modalities,
                  ),
                );
              }
            }
            if (entries.isNotEmpty) {
              groups.add(
                ModelCatalogGroup(
                  id: gid,
                  name: gname,
                  models: entries,
                  routable: routableSet.isEmpty || routableSet.contains(gid),
                ),
              );
            }
          }
        }
        final preserveWarmupModels =
            !allowEmptyModels && groups.isEmpty && attempt == 0 && state.modelGroups.isNotEmpty;
        if (!preserveWarmupModels) {
          next = next.copyWith(
            modelGroups: groups,
            routableProviders: routable,
          );
        }

        final defObj = rawCatalog['default'];
        final defProv = defObj is Map ? (defObj['provider']?.toString().trim() ?? '') : '';
        final defModelId = defObj is Map ? (defObj['model']?.toString().trim() ?? '') : '';
        final rawDefEff = defObj is Map ? (defObj['reasoningEffort']?.toString().trim() ?? '') : '';

        if (groups.isEmpty) {
          if (!preserveWarmupModels) {
            // Model list is genuinely empty -> model selector MUST be empty (never display stale phantom default).
            next = next.copyWith(
              activeModelProvider: '',
              activeModelId: '',
              modelName: '未配置模型',
              modelShort: '未配置',
              modelEffortId: '',
              modelEffort: '',
            );
          }
        } else {
          // Model list is non-empty -> selector MUST resolve to a real available model in `groups`.
          final userUpdatedInFlight =
              _modelSelectionGen != hydrateModelGen || _inFlightModelSelections > 0;
          final candProv = userUpdatedInFlight
              ? state.activeModelProvider
              : (defProv.isNotEmpty ? defProv : state.activeModelProvider);
          final candModelId = userUpdatedInFlight
              ? state.activeModelId
              : (defModelId.isNotEmpty ? defModelId : state.activeModelId);
          final candEff = userUpdatedInFlight ? state.modelEffortId : rawDefEff;

          ModelCatalogEntry? findInGroups(String prov, String mid) {
            if (mid.isEmpty) return null;
            for (final g in groups) {
              if (prov.isNotEmpty && g.id != prov) continue;
              for (final m in g.models) {
                if (m.id == mid) return m;
              }
            }
            if (prov.isNotEmpty) {
              for (final g in groups) {
                for (final m in g.models) {
                  if (m.id == mid) return m;
                }
              }
            }
            return null;
          }

          ModelCatalogEntry? matched = findInGroups(candProv, candModelId);
          bool usedAutoFallback = false;
          if (matched == null) {
            final preferredGroup =
                groups.where((g) => g.routable && g.models.isNotEmpty).firstOrNull ?? groups.first;
            matched = preferredGroup.models.first;
            usedAutoFallback = true;
          }

          String resolvedEff = '';
          if (matched.efforts.isNotEmpty) {
            if (candEff.isNotEmpty) {
              final opt = matched.efforts
                  .where((e) => e.id.toLowerCase() == candEff.toLowerCase())
                  .firstOrNull;
              if (opt != null) {
                resolvedEff = opt.id;
              }
            }
            if (resolvedEff.isEmpty) {
              resolvedEff = matched.defaultEffort.isNotEmpty
                  ? matched.defaultEffort
                  : matched.efforts.first.id;
            }
          }

          next = next.copyWith(
            activeModelProvider: matched.providerId,
            activeModelId: matched.id,
            modelName: matched.name,
            modelShort: matched.shortLabel,
            modelEffortId: resolvedEff,
            modelEffort: _effortIdToZhLabel(resolvedEff),
          );

          // If DSH's stored default was empty or pointed to a missing/deleted model, persist the
          // auto-selected valid model back to DSH once so server & client stay aligned.
          final dshDefaultMissingOrInvalid =
              defModelId.isEmpty || findInGroups(defProv, defModelId) == null;
          if (!userUpdatedInFlight && (usedAutoFallback || dshDefaultMissingOrInvalid)) {
            autoFallbackModel = matched;
            autoFallbackEffort = resolvedEff;
          }
        }
      }

      // 4. REAL Permissions Catalog
      final rawPermCat = permsResp['catalog'];
      if (rawPermCat is Map) {
        final rawOpts = rawPermCat['options'];
        final tiers = <PermissionTier>[];
        if (rawOpts is List) {
          for (final o in rawOpts) {
            if (o is! Map) continue;
            final val = o['value']?.toString() ?? '';
            if (val.isEmpty) continue;
            final known = kPermissionTiers.where((k) => k.id == val).firstOrNull;
            tiers.add(
              PermissionTier(
                id: val,
                name: known?.name ?? o['name']?.toString() ?? val,
                desc: known?.desc ?? 'DSH 权限预设 ($val)',
                risky: val.contains('danger') || val.contains('full'),
                isDefault: val == rawPermCat['defaultPreset']?.toString(),
              ),
            );
          }
        }
        final defPreset = rawPermCat['defaultPreset']?.toString();
        next = next.copyWith(
          permissionTiers: tiers.isNotEmpty ? tiers : next.permissionTiers,
          activePermissionId: (_permissionSelectionGen == hydratePermissionGen &&
                  defPreset != null &&
                  defPreset.isNotEmpty)
              ? defPreset
              : next.activePermissionId,
        );
      }

      // 5. REAL 22+ DSH Schemastery Settings Namespaces
      final desc = schemaResp['description'];
      if (desc is Map<String, dynamic>) {
        final parsedNamespaces = parseDshSettingsNamespaces(desc);
        if (parsedNamespaces.isNotEmpty) {
          next = next.copyWith(dshNamespaces: parsedNamespaces);
          for (final ns in parsedNamespaces) {
            if (ns.ns == 'agent-preset-registry' &&
                ns.value['selectedDefault'] is String &&
                _presetSelectionGen == hydratePresetGen) {
              next = next.copyWith(activePresetId: ns.value['selectedDefault'].toString());
            } else if (ns.ns == 'permission' &&
                ns.value['defaultPreset'] is String &&
                _permissionSelectionGen == hydratePermissionGen) {
              next = next.copyWith(activePermissionId: ns.value['defaultPreset'].toString());
            }
          }
          _syncNativeChatPermissionPreset(next.activePermissionId);
        } else if (desc['schema'] is Map<String, dynamic>) {
          next = next.copyWith(
            engineSchema: desc['schema'] as Map<String, dynamic>,
            engineValues: desc['values'] is Map<String, dynamic>
                ? desc['values'] as Map<String, dynamic>
                : next.engineValues,
          );
        }
      }

      // 6. REAL Presets
      final rawPresetWrap = presetsResp['presets'];
      final rawPresetList = rawPresetWrap is List
          ? rawPresetWrap
          : (rawPresetWrap is Map ? rawPresetWrap['presets'] : null);
      if (rawPresetList is List && rawPresetList.isNotEmpty) {
        final mappedPresets = <PresetOption>[];
        for (final item in rawPresetList) {
          if (item is! Map) continue;
          final id = item['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          final fallbackMeta = kPresetOptions.where((p) => p.id == id).firstOrNull;
          mappedPresets.add(
            PresetOption(
              id: id,
              name: item['title']?.toString() ?? item['name']?.toString() ?? fallbackMeta?.name ?? id,
              desc: item['description']?.toString() ?? fallbackMeta?.desc ?? 'DSH Agent 预设 ($id)',
              isDefault: item['isDefault'] == true || id == 'standard',
            ),
          );
        }
        if (mappedPresets.isNotEmpty) {
          next = next.copyWith(presets: mappedPresets);
        }
      }

      // 12. REAL DeepSeek Account State
      if (accountResp.isNotEmpty) {
        next = next.copyWith(accountSnapshot: accountResp);
      }

      // Hold `hydratingDomains: true` across the brief warmup retry when `getModels()` failed
      // (e.g. mid-Cordis-reload) OR returned empty during first boot while providers are still
      // mounting, so the UI NEVER flashes "尚未配置可用模型渠道" / "配置模型" prematurely!
      final needsModelWarmupRetry = attempt == 0 &&
          (modelsFailed || (!allowEmptyModels && next.modelGroups.isEmpty)) &&
          identical(_liveClient, client);
      final needsManifestWarmupRetry =
          attempt == 0 && next.dshSettingsSections.isEmpty && identical(_liveClient, client);
      final keepHydratingUntilRetry = needsModelWarmupRetry && !skipAutoDefaultSync;

      // Commit Stage 1 immediately (models, permissions, namespaces, account ready!)
      state = next.copyWith(
        hydratingDomains: keepHydratingUntilRetry,
        initialDomainsHydrated: !keepHydratingUntilRetry,
      );

      // Stage 2 (extensions, plugins, providers, automation, speech)
      final stage2InteractionSeq = _interactionMutationSeq;
      var sduiFailed = false;
      var pendingFailed = false;
      var bundlesFailed = false;
      var providersFailed = false;
      var credsFailed = false;
      var mcpFailed = false;
      var schedulesFailed = false;
      var jobsFailed = false;
      var cordisFailed = false;
      var speechFailed = false;
      final extResults = await Future.wait([
        client.listSduiSurfaces().catchError((_) {
          sduiFailed = true;
          return const <SduiSurfaceMeta>[];
        }),
        client.listPendingInteractions().catchError((_) {
          pendingFailed = true;
          return const <PendingInteraction>[];
        }),
        client.listPluginBundles().catchError((_) {
          bundlesFailed = true;
          return const <String, dynamic>{};
        }),
        client.listProviders().catchError((_) {
          providersFailed = true;
          return const <String, dynamic>{};
        }),
        client.getCredentials().catchError((_) {
          credsFailed = true;
          return const <String, dynamic>{};
        }),
        client.listMcpServers().catchError((_) {
          mcpFailed = true;
          return const <String, dynamic>{};
        }),
        client.listSchedules().catchError((_) {
          schedulesFailed = true;
          return const <String, dynamic>{};
        }),
        client.listJobs().catchError((_) {
          jobsFailed = true;
          return const <String, dynamic>{};
        }),
        client.listDynamicCordis().catchError((_) {
          cordisFailed = true;
          return const <String, dynamic>{};
        }),
        client.getSpeechConfig().catchError((_) {
          speechFailed = true;
          return const <String, dynamic>{};
        }),
      ]);
      if (!mounted || !identical(_liveClient, client) || myHydrateGen != _hydrationGen) return;

      final liveSurfaces = extResults[0] as List<SduiSurfaceMeta>;
      final pending = extResults[1] as List<PendingInteraction>;
      final bundlesResp = extResults[2] as Map<String, dynamic>;
      final providersResp = extResults[3] as Map<String, dynamic>;
      final credsResp = extResults[4] as Map<String, dynamic>;
      final mcpResp = extResults[5] as Map<String, dynamic>;
      final schedulesResp = extResults[6] as Map<String, dynamic>;
      final jobsResp = extResults[7] as Map<String, dynamic>;
      final cordisResp = extResults[8] as Map<String, dynamic>;
      final speechResp = extResults[9] as Map<String, dynamic>;

      // Re-anchor `next` to latest `state` so concurrent session/turn actions are never overwritten.
      next = state;

      // 2. REAL SDUI Surfaces & Speech (preserve prior values on transient single-endpoint errors)
      next = next.copyWith(
        sduiSurfaces: sduiFailed ? next.sduiSurfaces : liveSurfaces,
        speechConfigured: speechFailed ? next.speechConfigured : (speechResp['configured'] == true),
      );

      // 7. REAL Plugin Bundles
      if (!bundlesFailed) {
        final mappedPlugins = _parsePluginBundlesResp(bundlesResp);
        next = next.copyWith(plugins: mappedPlugins);
      }

      // 8. REAL Providers & Credentials (merging DSH `configurable` + user custom `llm-pi-ai.providers`)
      final rawCreds = credsResp['credentials'];
      final credMap = <String, dynamic>{};
      if (rawCreds is Map) {
        final entries = rawCreds['entries'] ?? rawCreds['credentials'] ?? rawCreds['items'];
        if (entries is List) {
          for (final item in entries.whereType<Map>()) {
            final k = (item['ref'] ?? item['name'] ?? item['key'])?.toString();
            if (k != null && k.isNotEmpty) credMap[k] = Map<String, dynamic>.from(item);
          }
        } else {
          for (final e in rawCreds.entries) {
            if (e.key != 'v') credMap[e.key.toString()] = e.value;
          }
        }
      } else if (rawCreds is List) {
        for (final item in rawCreds.whereType<Map>()) {
          final k = (item['ref'] ?? item['name'] ?? item['key'])?.toString();
          if (k != null && k.isNotEmpty) credMap[k] = Map<String, dynamic>.from(item);
        }
      }
      final piAiNs = next.dshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
      final piAiProviders = piAiNs != null && piAiNs.value['providers'] is Map
          ? Map<String, dynamic>.from(piAiNs.value['providers'] as Map)
          : const <String, dynamic>{};
      final deepSeekNs = next.dshNamespaces.where((n) => n.ns == 'llm-deepseek').firstOrNull;
      final deepSeekBaseUrl = deepSeekNs?.value['baseURL']?.toString() ?? '';
      final commandCodeNs = next.dshNamespaces.where((n) => n.ns == 'llm-commandcode').firstOrNull;
      final commandCodeBaseUrl = commandCodeNs?.value['apiBase']?.toString() ?? '';
      final commandCodeEnv = commandCodeNs?.value['apiKeyEnv']?.toString().trim() ?? '';

      final rawConfigProviders = providersResp['configurable'];
      final mappedCreds = <ProviderCredentialItem>[];
      final seenProviderIds = <String>{};
      if (rawConfigProviders is List && rawConfigProviders.isNotEmpty) {
        for (final p in rawConfigProviders) {
          if (p is! Map) continue;
          final pid = p['provider']?.toString() ?? p['id']?.toString() ?? '';
          if (pid.isEmpty || !seenProviderIds.add(pid)) continue;
          final ns = p['settingsNs']?.toString() ?? 'llm-pi-ai';
          final piCfg = piAiProviders[pid] is Map
              ? Map<String, dynamic>.from(piAiProviders[pid] as Map)
              : null;
          final nativeAuth = p['nativeAuth'];
          String envRef = piCfg?['apiKeyEnv']?.toString().trim() ?? '';
          if (envRef.isEmpty) {
            if (nativeAuth is Map && nativeAuth['env'] is List && (nativeAuth['env'] as List).isNotEmpty) {
              envRef = (nativeAuth['env'] as List).first.toString();
            } else if (pid == 'deepseek-official') {
              envRef = 'DEEPSEEK_API_KEY';
            } else if (pid == 'commandcode') {
              envRef = commandCodeEnv.isNotEmpty ? commandCodeEnv : 'COMMANDCODE_API_KEY';
            } else if (pid == 'openai') {
              envRef = 'OPENAI_API_KEY';
            } else if (pid == 'anthropic') {
              envRef = 'ANTHROPIC_API_KEY';
            } else {
              envRef = '${pid.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_')}_API_KEY';
            }
          }
          final cinfo = credMap[envRef];
          final credPresent = cinfo is Map &&
              (cinfo['present'] == true || cinfo['configured'] == true || cinfo['set'] == true);
          final present = credPresent ||
              next.routableProviders.contains(pid) ||
              (piCfg?['apiKey']?.toString().trim().isNotEmpty == true);
          final modelCount = next.modelGroups
              .where((g) => g.id == pid)
              .fold<int>(0, (acc, g) => acc + g.models.length);
          final resolvedBaseUrl = (piCfg?['baseURL']?.toString().trim().isNotEmpty == true)
              ? piCfg!['baseURL'].toString().trim()
              : (pid == 'deepseek-official' && deepSeekBaseUrl.isNotEmpty
                  ? deepSeekBaseUrl
                  : (pid == 'commandcode' && commandCodeBaseUrl.isNotEmpty
                      ? commandCodeBaseUrl
                      : (p['baseURL']?.toString() ?? p['defaultBaseURL']?.toString() ?? '')));
          final resolvedName = (piCfg?['displayName']?.toString().trim().isNotEmpty == true)
              ? piCfg!['displayName'].toString().trim()
              : (p['displayName']?.toString() ?? pid);
          mappedCreds.add(
            ProviderCredentialItem(
              id: pid,
              name: resolvedName,
              settingsNs: ns,
              envRef: envRef,
              baseUrl: resolvedBaseUrl,
              configured: present,
              maskedKey: present
                  ? (cinfo is Map && (cinfo['masked'] ?? cinfo['preview']) != null
                      ? (cinfo['masked'] ?? cinfo['preview']).toString()
                      : '已就绪')
                  : '',
              modelsCount: modelCount,
              description: piCfg?['api']?.toString() ?? ns,
              isBuiltin: true,
            ),
          );
        }
      }
      // Also include any user-defined custom providers declared in `llm-pi-ai.providers`
      for (final entry in piAiProviders.entries) {
        final pid = entry.key;
        if (pid.isEmpty || !seenProviderIds.add(pid)) continue;
        final cfg = entry.value is Map ? Map<String, dynamic>.from(entry.value as Map) : const <String, dynamic>{};
        final envRef = cfg['apiKeyEnv']?.toString().trim().isNotEmpty == true
            ? cfg['apiKeyEnv'].toString().trim()
            : '${pid.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_')}_API_KEY';
        final cinfo = credMap[envRef];
        final credPresent = cinfo is Map &&
            (cinfo['present'] == true || cinfo['configured'] == true || cinfo['set'] == true);
        final declaredModels = cfg['models'] is List ? (cfg['models'] as List).length : 0;
        final hasLocalRoute = (cfg['baseURL']?.toString().trim().isNotEmpty == true) &&
            declaredModels > 0;
        final isConfigured = credPresent ||
            next.routableProviders.contains(pid) ||
            (cfg['apiKey']?.toString().trim().isNotEmpty == true) ||
            hasLocalRoute;
        final modelCount = next.modelGroups
            .where((g) => g.id == pid)
            .fold<int>(0, (acc, g) => acc + g.models.length);
        mappedCreds.add(
          ProviderCredentialItem(
            id: pid,
            name: cfg['displayName']?.toString().trim().isNotEmpty == true
                ? cfg['displayName'].toString().trim()
                : pid,
            settingsNs: 'llm-pi-ai',
            envRef: envRef,
            baseUrl: cfg['baseURL']?.toString() ?? '',
            configured: isConfigured,
            maskedKey: isConfigured
                ? (cinfo is Map && (cinfo['masked'] ?? cinfo['preview']) != null
                    ? (cinfo['masked'] ?? cinfo['preview']).toString()
                    : (hasLocalRoute && !credPresent ? '免密钥端点' : '已配置'))
                : '',
            modelsCount: modelCount > 0 ? modelCount : declaredModels,
            description: cfg['api']?.toString() ?? 'openai-completions',
          ),
        );
      }
      if (!providersFailed && !credsFailed) {
        next = next.copyWith(providerCredentials: mappedCreds);
      }

      // 9. REAL MCP Servers (preserve prior list on transient endpoint error)
      if (!mcpFailed) {
        final rawMcp = mcpResp['servers'];
        final mappedMcp = <McpServerItem>[];
        if (rawMcp is List) {
          for (final s in rawMcp) {
            if (s is! Map) continue;
            mappedMcp.add(
              McpServerItem(
                name: s['name']?.toString() ?? 'mcp',
                transport: s['transport']?.toString() ?? 'stdio',
                status: s['status']?.toString() ?? 'connected',
                endpoint: s['command']?.toString() ?? s['url']?.toString() ?? '',
                toolsCount: (s['toolsCount'] as num?)?.toInt() ??
                    (s['tools'] is List ? (s['tools'] as List).length : 0),
              ),
            );
          }
        }
        next = next.copyWith(mcpServers: mappedMcp);
      }

      // 11. REAL Schedules, Jobs & Dynamic Cordis (preserve prior lists on transient errors!)
      if (!schedulesFailed) {
        final rawSched = schedulesResp['schedules'];
        final mappedSched = <ScheduleTaskRecord>[];
        if (rawSched is List) {
          for (final s in rawSched) {
            if (s is! Map) continue;
            mappedSched.add(ScheduleTaskRecord.fromJson(Map<String, dynamic>.from(s)));
          }
        }
        next = next.copyWith(schedules: mappedSched);
      }
      next = next.copyWith(
        jobs: jobsFailed ? next.jobs : _parseJobsResponse(jobsResp),
        dynamicCordis: cordisFailed ? next.dynamicCordis : _parseDynamicCordisResp(cordisResp),
      );

      state = next;
      // Preserve live interactions in Direct Mode (mux `$events` is authoritative) and
      // never wipe interactions that arrived over WS while Stage 2 was in flight!
      final isDirectClient = client.isVanillaDirect;
      if (!isDirectClient && !pendingFailed) {
        // Only apply Stage-2 HTTP interaction snapshot if no local resolve/WS interaction
        // mutation happened while Stage 2 was in flight — otherwise the stale HTTP snapshot
        // would resurrect an approval/question the user already resolved!
        if (_interactionMutationSeq == stage2InteractionSeq) {
          _pendingInteractionsById.clear();
          for (final item in pending) {
            _pendingInteractionsById[item.id] = item;
          }
          _recomputeVisibleInteractions();
        }
      } else if (isDirectClient && pending.isNotEmpty) {
        if (_interactionMutationSeq == stage2InteractionSeq) {
          for (final item in pending) {
            _pendingInteractionsById.putIfAbsent(item.id, () => item);
          }
          _recomputeVisibleInteractions();
        }
      }

      if (!skipAutoDefaultSync &&
          autoFallbackModel != null &&
          identical(_liveClient, client) &&
          _modelSelectionGen == hydrateModelGen &&
          _inFlightModelSelections == 0) {
        final syncKey =
            '${state.activeHostId}|${autoFallbackModel.providerId}|${autoFallbackModel.id}|$autoFallbackEffort';
        if (_lastAutoSyncedDefaultKey != syncKey) {
          _lastAutoSyncedDefaultKey = syncKey;
          unawaited(
            _persistDefaultModelQuietly(
              client,
              provider: autoFallbackModel.providerId,
              modelId: autoFallbackModel.id,
              effortId: autoFallbackEffort,
            ),
          );
        }
      }

      // If DSH was still warming up its Cordis plugins right after container boot and returned
      // empty settings manifest or empty/failed model catalog on the first pass, auto-retry once.
      if ((needsModelWarmupRetry || needsManifestWarmupRetry) &&
          identical(_liveClient, client) &&
          myHydrateGen == _hydrationGen) {
        _domainRetryTimer?.cancel();
        _domainRetryTimer = Timer(const Duration(milliseconds: 950), () {
          if (mounted &&
              identical(_liveClient, client) &&
              myHydrateGen == _hydrationGen &&
              (state.dshSettingsSections.isEmpty || state.modelGroups.isEmpty || state.hydratingDomains)) {
            unawaited(_hydrateLiveDomains(client, attempt: 1));
          }
        });
      }
    } catch (_) {
      if (mounted &&
          identical(_liveClient, client) &&
          myHydrateGen == _hydrationGen &&
          (state.loadingSessions || state.hydratingDomains)) {
        state = state.copyWith(loadingSessions: false, hydratingDomains: false);
      }
    }
  }

  Future<void> refreshAccount({bool silent = false}) async {
    final client = _liveClient;
    if (client == null) return;
    try {
      final acct = await client.getAccount();
      if (!mounted || !identical(_liveClient, client)) return;
      final wasSignedIn = state.isAccountSignedIn;
      final acctChanged = !_deepEquals(acct, state.accountSnapshot);
      if (acctChanged) {
        state = state.copyWith(accountSnapshot: acct);
      }
      if (state.isAccountSignedIn && state.accountSigningIn) {
        _accountPollTimer?.cancel();
        _accountPollTimer = null;
        state = state.copyWith(accountSigningIn: false);
        showToast('DeepSeek 账号登录成功，正在同步可用模型…');
        if (!wasSignedIn) {
          unawaited(refreshModelCatalog());
        }
        return;
      }
      if (!silent) {
        showToast('已刷新 DeepSeek 账号状态', tone: ToastTone.info);
      }
    } catch (e) {
      if (!silent && _isStillLive(client)) {
        showToast('刷新账号失败：${formatReadableError(e)}', tone: ToastTone.warn);
      }
    }
  }

  Future<void> cancelDeepSeekSignIn() async {
    _accountPollTimer?.cancel();
    _accountPollTimer = null;
    final attemptId = _activeSignInAttemptId;
    _activeSignInAttemptId = null;
    state = state.copyWith(accountSigningIn: false);
    final client = _liveClient;
    if (client != null) {
      await client
          .accountAction(
            'cancelSignIn',
            attemptId != null && attemptId.isNotEmpty ? {'attemptId': attemptId} : const {},
          )
          .catchError((_) => <String, dynamic>{});
    }
    if (mounted) {
      showToast('已取消 DeepSeek 登录授权', tone: ToastTone.info);
    }
  }

  static String? _extractAuthorizeUrl(Map<dynamic, dynamic>? root) {
    if (root == null) return null;
    final res = root['result'];
    final stateObj = root['state'];
    final candidates = <Map<dynamic, dynamic>?>[
      if (res is Map && res['attempt'] is Map) res['attempt'] as Map,
      if (root['attempt'] is Map) root['attempt'] as Map,
      if (stateObj is Map && stateObj['attempt'] is Map) stateObj['attempt'] as Map,
      if (res is Map) res,
      if (stateObj is Map) stateObj,
      root,
    ];
    for (final c in candidates) {
      if (c == null) continue;
      final u = (c['authorizeUrl'] ?? c['verificationUrl'] ?? c['signInUrl'] ?? c['url'])
          ?.toString()
          .trim();
      if (u != null && (u.startsWith('http://') || u.startsWith('https://'))) {
        return u;
      }
    }
    return null;
  }

  void _startAccountSignInPolling(GbridgeClient client) {
    _accountPollTimer?.cancel();
    state = state.copyWith(accountSigningIn: true);
    var ticks = 0;
    _accountPollTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      ticks++;
      if (!mounted || !identical(_liveClient, client) || ticks > 90) {
        timer.cancel();
        _accountPollTimer = null;
        if (mounted && state.accountSigningIn) {
          state = state.copyWith(accountSigningIn: false);
        }
        return;
      }
      unawaited(refreshAccount(silent: true));
    });
  }

  Future<String?> startDeepSeekSignIn({bool openExternally = true}) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到 DSH 主机', tone: ToastTone.warn);
      return null;
    }
    try {
      final resp = await client.accountAction('startSignIn');
      if (!_isStillLive(client)) return null;
      final res = resp['result'];
      Map<dynamic, dynamic>? attempt;
      if (res is Map && res['attempt'] is Map) {
        attempt = res['attempt'] as Map<dynamic, dynamic>;
      } else if (resp['attempt'] is Map) {
        attempt = resp['attempt'] as Map<dynamic, dynamic>;
      }
      _activeSignInAttemptId = (attempt?['attemptId'] ??
              attempt?['id'] ??
              (res is Map ? res['attemptId'] : null))
          ?.toString();
      var url = _extractAuthorizeUrl(resp);

      // Client-side fallback poll if DSH is still finishing OAuth `auth_init` (~200-1500ms).
      if (url == null || url.isEmpty) {
        final deadline = DateTime.now().add(const Duration(seconds: 6));
        while (DateTime.now().isBefore(deadline) && mounted && identical(_liveClient, client)) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          final acct = await client.getAccount().catchError((_) => const <String, dynamic>{});
          if (!mounted || !identical(_liveClient, client)) return null;
          if (!_deepEquals(acct, state.accountSnapshot)) {
            state = state.copyWith(accountSnapshot: acct);
          }
          url = _extractAuthorizeUrl(acct);
          if (url != null && url.isNotEmpty) break;
          final st = acct['state'];
          final att = st is Map ? st['attempt'] : null;
          final phase = att is Map ? att['phase']?.toString() : null;
          if (phase != null && phase != 'initializing' && phase != 'pending') break;
        }
      } else {
        await refreshAccount(silent: true);
      }

      if (!mounted || !identical(_liveClient, client)) return null;

      if (url != null && url.isNotEmpty) {
        _startAccountSignInPolling(client);
        if (openExternally) {
          var openedExternally = false;
          if (kIsWeb) {
            openedExternally = openUrlInNewTab(url);
          } else if (GrassBagNativeBridge.instance.isAndroidNative) {
            await GrassBagNativeBridge.instance.openExternalUrl(url);
            openedExternally = true;
          }
          if (!openedExternally) {
            await Clipboard.setData(ClipboardData(text: url));
          }
          showToast(
            openedExternally
                ? '已在浏览器打开 DeepSeek 授权页面，完成后自动同步'
                : '已复制 DeepSeek 授权链接到剪贴板，请在浏览器打开完成登录',
          );
        }
        return url;
      }
      _accountPollTimer?.cancel();
      _accountPollTimer = null;
      state = state.copyWith(accountSigningIn: false);
      showToast('正在初始化 DeepSeek 登录会话，请稍候片刻重试', tone: ToastTone.warn);
      return null;
    } catch (e) {
      if (!_isStillLive(client)) return null;
      _accountPollTimer?.cancel();
      _accountPollTimer = null;
      if (mounted) {
        state = state.copyWith(accountSigningIn: false);
      }
      showError('发起 DeepSeek 登录失败', error: e);
      return null;
    }
  }

  Future<void> signOutDeepSeekAccount() async {
    final client = _liveClient;
    if (client == null) return;
    _accountPollTimer?.cancel();
    _accountPollTimer = null;
    try {
      await client.accountAction('signOut');
      if (!_isStillLive(client)) return;
      state = state.copyWith(accountSigningIn: false);
      await refreshAccount(silent: true);
      if (!_isStillLive(client)) return;
      await refreshModelCatalog();
      if (!_isStillLive(client)) return;
      showToast('已退出 DeepSeek 账号', tone: ToastTone.info);
    } catch (e) {
      if (!_isStillLive(client)) return;
      showError('退出登录失败', error: e);
    }
  }

  Future<void> searchPluginMarket(String query) async {
    final client = _liveClient;
    if (client == null) {
      state = state.copyWith(
        searchingMarket: false,
        marketError: '请先连接到运行中的 DSH 主机后再搜索插件市场',
      );
      return;
    }
    final seq = ++_marketSearchSeq;
    state = state.copyWith(searchingMarket: true, clearMarketError: true);
    try {
      final resp = await client.searchPluginMarket({'query': query.trim(), 'limit': 30});
      if (!mounted || !identical(_liveClient, client) || seq != _marketSearchSeq) return;
      final inner = resp['result'] is Map ? Map<String, dynamic>.from(resp['result'] as Map) : resp;
      final innerErr = inner['error'] ?? resp['error'];
      if (innerErr != null && innerErr.toString().trim().isNotEmpty) {
        final msg = innerErr is Map
            ? (innerErr['message'] ?? innerErr['error'] ?? innerErr.toString()).toString()
            : innerErr.toString();
        state = state.copyWith(searchingMarket: false, marketError: msg);
        return;
      }
      final raw = inner['items'] ??
          inner['results'] ??
          inner['plugins'] ??
          resp['results'] ??
          resp['plugins'] ??
          resp['items'];
      final list = <PluginMarketEntry>[];
      if (raw is List) {
        for (final m in raw) {
          if (m is! Map) continue;
          final pkg = m['name']?.toString() ?? m['packageName']?.toString() ?? '';
          if (pkg.isEmpty) continue;
          list.add(
            PluginMarketEntry(
              name: pkg,
              displayName: m['title']?.toString() ?? pkg,
              version: m['version']?.toString() ?? 'latest',
              desc: m['description']?.toString() ?? '',
              author: m['author']?.toString() ?? 'DSH',
              installed: state.plugins.any((p) => p.id == pkg),
            ),
          );
        }
      }
      state = state.copyWith(
        marketPlugins: list,
        searchingMarket: false,
        clearMarketError: true,
      );
    } catch (e) {
      if (!_isStillLive(client) || seq != _marketSearchSeq) return;
      final readable = formatReadableError(e);
      state = state.copyWith(searchingMarket: false, marketError: readable);
    }
  }

  void _flushCoalescedStreamFrame({bool isTurnDone = false, GbridgeClient? ownerClient}) {
    _streamCoalesceTimer?.cancel();
    _streamCoalesceTimer = null;
    final expectedClient = ownerClient ?? _coalescedClient;
    if (!mounted || (expectedClient != null && !identical(_liveClient, expectedClient))) {
      _clearPendingStreamCoalesce();
      return;
    }
    final hasPendingProjection = _pendingStreamPlanMode != null ||
        _pendingStreamTodos != null ||
        _pendingStreamSubagents != null ||
        _pendingStreamGoals != null ||
        _pendingStreamQueue != null ||
        _pendingStreamTitle != null;
    if (!_pendingStreamReduced &&
        !_pendingStreamTelemetryChanged &&
        !hasPendingProjection &&
        !isTurnDone) {
      return;
    }

    final reduced = _pendingStreamReduced;
    final nextTelemetryBase = _pendingStreamTelemetry ?? state.sessionTelemetry;
    final nextTelemetry =
        isTurnDone ? nextTelemetryBase.copyWith(clearLive: true) : nextTelemetryBase;
    final nextCtxUsedK = _pendingCtxUsedK ?? state.contextUsedK;
    final nextCtxMaxK = _pendingCtxMaxK ?? state.contextMaxK;
    final nextCtxPct = _pendingCtxPct ?? state.contextPct;
    final nextCtxBreakdown = _pendingCtxBreakdown ?? state.contextBreakdown;
    final nextPlanMode = _pendingStreamPlanMode ?? state.planMode;
    final nextTodos = _pendingStreamTodos ?? state.todos;
    final nextSubagents = _pendingStreamSubagents ?? state.subagents;
    final nextGoals = _pendingStreamGoals ?? state.goals;
    final pendingQueue = _pendingStreamQueue;
    final pendingTitle = _pendingStreamTitle;

    _pendingStreamTelemetry = null;
    _pendingCtxUsedK = null;
    _pendingCtxMaxK = null;
    _pendingCtxPct = null;
    _pendingCtxBreakdown = null;
    _pendingStreamPlanMode = null;
    _pendingStreamTodos = null;
    _pendingStreamSubagents = null;
    _pendingStreamGoals = null;
    _pendingStreamQueue = null;
    _pendingStreamTitle = null;
    _pendingStreamReduced = false;
    _pendingStreamTelemetryChanged = false;
    if (isTurnDone) _lastLiveTpsEmitAt = null;

    final updated = reduced ? _turnReducer.turns : state.turns;
    final streaming = updated.isNotEmpty && updated.last.isStreaming;
    final endedStreaming = !streaming && (isTurnDone || state.isStreaming);
    final finalTelemetry =
        endedStreaming ? nextTelemetry.copyWith(clearLive: true) : nextTelemetry;
    if (endedStreaming) {
      _lastLiveTpsEmitAt = null;
      _disarmStreamWatchdog();
    } else if (streaming && _streamWatchdogTimer == null) {
      _armStreamWatchdog();
    }
    final hasAnyLiveOutput = streaming &&
        updated.isNotEmpty &&
        (updated.last.assistantText.isNotEmpty || updated.last.steps.isNotEmpty);
    final nextSendStage = (endedStreaming || hasAnyLiveOutput) ? SendStage.idle : state.sendStage;
    final sid = state.activeSessionId;
    bool needsSessionUpdate = false;
    if (sid != null) {
      for (final s in state.sessions) {
        if (s.id == sid &&
            ((endedStreaming && s.running) ||
                (pendingTitle != null && pendingTitle.isNotEmpty && s.title != pendingTitle))) {
          needsSessionUpdate = true;
          break;
        }
      }
    }

    final turnCompletedCleanly =
        endedStreaming && updated.isNotEmpty && updated.last.status == 'completed';
    List<QueuedMessageItem> nextQueued = pendingQueue ?? state.queuedMessages;
    if (pendingQueue == null && turnCompletedCleanly && state.queuedMessages.isNotEmpty) {
      // Steer instructions belong to the completed turn and are consumed before turn end;
      // among queued follow-up messages, pop at most the first `queue` item that DSH runs next.
      final remaining = <QueuedMessageItem>[];
      var poppedOneQueue = false;
      for (final q in state.queuedMessages) {
        if (q.mode == 'steer') continue;
        if (!poppedOneQueue) {
          poppedOneQueue = true;
          continue;
        }
        remaining.add(q);
      }
      nextQueued = remaining;
    }
    state = state.copyWith(
      turns: updated,
      isStreaming: streaming,
      sendStage: nextSendStage,
      isStopping: endedStreaming ? false : state.isStopping,
      streamStalled: false,
      contextUsedK: nextCtxUsedK,
      contextMaxK: nextCtxMaxK,
      contextPct: nextCtxPct,
      contextBreakdown: nextCtxBreakdown,
      sessionTelemetry: finalTelemetry,
      planMode: nextPlanMode,
      todos: nextTodos,
      subagents: nextSubagents,
      goals: nextGoals,
      queuedMessages: nextQueued,
      sessions: needsSessionUpdate
          ? [
              for (final s in state.sessions)
                s.id == sid
                    ? s.copyWith(
                        running: endedStreaming ? false : s.running,
                        title: (pendingTitle != null && pendingTitle.isNotEmpty)
                            ? pendingTitle
                            : s.title,
                      )
                    : s,
            ]
          : state.sessions,
      streamTick: (reduced && streaming) ? state.streamTick + 1 : state.streamTick,
    );
    if (endedStreaming && sid != null && _liveClient != null) {
      // Sync updated auto-generated session title & real context usage WITHOUT forcing a scroll jump;
      // only fetch workspace file tree/diffs/jobs/commands/goals when the turn actually executed tools!
      final completedTurn = updated.isNotEmpty ? updated.last : null;
      final ranAnyTool = completedTurn != null &&
          completedTurn.steps.any((s) => s is ToolStep);
      unawaited(
        _syncLiveSessionBundle(
          sid,
          jumpToBottomOnLoad: false,
          includeWorkbench: ranAnyTool,
        ),
      );
    }
    if (endedStreaming &&
        state.activeHost.isLocal &&
        GrassBagNativeBridge.instance.isAndroidNative) {
      final lastTurn = updated.isNotEmpty ? updated.last : null;
      final ranPhoneTool = state.phoneLiveActive ||
          (lastTurn != null &&
              lastTurn.steps.any((s) => s is ToolStep && s.name.toLowerCase().startsWith('phone_')));
      if (ranPhoneTool) {
        final summarySnippet = (lastTurn?.assistantText ?? '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final trimmed = summarySnippet.length > 48
            ? '${summarySnippet.substring(0, 48)}…'
            : summarySnippet;
        final reason = lastTurn?.status == 'error'
            ? 'error'
            : (lastTurn?.status == 'cancelled' ? 'stopped' : 'completed');
        if (state.phoneLiveActive) {
          state = state.copyWith(
            phoneLiveActive: false,
            phoneLivePaused: false,
            phoneLiveAction: '',
            phoneLiveApp: '',
            phoneLiveSteps: 0,
          );
        }
        unawaited(
          GrassBagNativeBridge.instance.notifyPhoneTurnDone(
            sessionId: sid,
            reason: reason,
            summary: trimmed,
          ),
        );
      }
    }
  }

  void _flushPendingJobOutputs() {
    _jobOutputFlushTimer?.cancel();
    _jobOutputFlushTimer = null;
    if (!mounted ||
        _pendingJobOutputs.isEmpty ||
        (_jobOutputClient != null && !identical(_liveClient, _jobOutputClient))) {
      _pendingJobOutputs.clear();
      _jobOutputClient = null;
      return;
    }
    final batch = Map<String, List<String>>.from(_pendingJobOutputs);
    _pendingJobOutputs.clear();
    const maxJobLines = 500;
    bool changed = false;
    final nextJobs = [
      for (final j in state.jobs)
        if (batch.containsKey(j.id))
          () {
            changed = true;
            final appended = [...j.outputLines, ...batch[j.id]!];
            final capped = appended.length > maxJobLines
                ? appended.sublist(appended.length - maxJobLines)
                : appended;
            return j.copyWith(outputLines: capped);
          }()
        else
          j,
    ];
    if (changed) {
      state = state.copyWith(jobs: nextJobs);
    }
  }

  void _handleLiveStreamFrame(GbridgeClient client, StreamFrame frame) {
    if (!mounted || !identical(_liveClient, client)) return;
    _coalescedClient = client;
    final ch = frame.channel ?? '';
    final type = frame.type ?? '';
    final data = frame.dataMap ?? const <String, dynamic>{};

    final activeSid = state.activeSessionId;
    if (activeSid != null && ch == 'session:$activeSid') {
      _sessionStreamSeq[activeSid] = (_sessionStreamSeq[activeSid] ?? 0) + 1;
      // Live streaming speed / phase activity from dsh-gbridge `observeStreamChunk`
      SessionTelemetry nextTelemetry = _pendingStreamTelemetry ?? state.sessionTelemetry;
      bool telemetryChanged = false;
      final activity = data['activity'];
      if (activity is Map) {
        final tps = (activity['tps'] as num?)?.toDouble();
        final phase = activity['phase']?.toString();
        final elapsedMs = (activity['elapsedMs'] as num?)?.toInt();
        final now = DateTime.now();
        final phaseChanged = phase != null && phase != nextTelemetry.livePhase;
        final tpsDue = _lastLiveTpsEmitAt == null ||
            now.difference(_lastLiveTpsEmitAt!).inMilliseconds >= 250 ||
            nextTelemetry.liveTps == null;
        if (phaseChanged || tpsDue) {
          _lastLiveTpsEmitAt = now;
          nextTelemetry = nextTelemetry.copyWith(
            liveTps: tps,
            livePhase: phase,
            liveElapsedMs: elapsedMs,
          );
          telemetryChanged = true;
        }
      }

      // Live projections updates (`projection.updated` or `turn.snapshot`)
      final frameProj = data['projections'];
      var nextCtxUsedK = _pendingCtxUsedK ?? state.contextUsedK;
      var nextCtxMaxK = _pendingCtxMaxK ?? state.contextMaxK;
      var nextCtxPct = _pendingCtxPct ?? state.contextPct;
      var nextCtxBreakdown = _pendingCtxBreakdown ?? state.contextBreakdown;
      if (frameProj is Map && frameProj.isNotEmpty) {
        final projMap = frameProj is Map<String, dynamic>
            ? frameProj
            : Map<String, dynamic>.from(frameProj);
        final parsedTelemetry = SessionTelemetry.fromProjections(
          projMap,
          base: nextTelemetry,
          fallbackTurns: state.turns,
        );
        if (parsedTelemetry != nextTelemetry) {
          nextTelemetry = parsedTelemetry;
          telemetryChanged = true;
        }
        if (nextTelemetry.contextWindow > 0) {
          final candMaxK = (nextTelemetry.contextWindow ~/ 1000).clamp(32, 4000);
          if (candMaxK != nextCtxMaxK) {
            nextCtxMaxK = candMaxK;
            telemetryChanged = true;
          }
        }
        if (nextTelemetry.pressureTokens > 0) {
          final candUsedK = (nextTelemetry.pressureTokens / 100.0).round() / 10.0;
          if (candUsedK != nextCtxUsedK) {
            nextCtxUsedK = candUsedK;
            telemetryChanged = true;
          }
        }
        if (nextTelemetry.systemTokens + nextTelemetry.toolsTokens + nextTelemetry.messageTokens > 0) {
          final candBreakdown = {
            'system': nextTelemetry.systemTokens,
            'tools': nextTelemetry.toolsTokens,
            'messages': nextTelemetry.messageTokens,
          };
          if (!mapEquals(candBreakdown, nextCtxBreakdown)) {
            nextCtxBreakdown = candBreakdown;
            telemetryChanged = true;
          }
        }
        if (nextCtxMaxK > 0) {
          final candPct = ((nextCtxUsedK / nextCtxMaxK) * 100).round().clamp(0, 100);
          if (candPct != nextCtxPct) {
            nextCtxPct = candPct;
            telemetryChanged = true;
          }
        }
        final projVals = projMap['values'] is Map
            ? Map<String, dynamic>.from(projMap['values'] as Map)
            : projMap;
        bool? nextPlan;
        List<SessionTodoRecord>? nextTodos;
        List<SubagentItem>? nextSubs;
        final planObj = projVals['plan'];
        if (planObj is Map && planObj['active'] is bool) {
          nextPlan = planObj['active'] as bool;
        }
        final rawTodos = projVals['todos'] ?? projVals['todoList'];
        if (rawTodos is List) {
          nextTodos = [
            for (var i = 0; i < rawTodos.length; i++)
              if (rawTodos[i] is Map)
                SessionTodoRecord(
                  id: (rawTodos[i] as Map)['id']?.toString() ?? 'td-$i',
                  title: ((rawTodos[i] as Map)['title'] ??
                          (rawTodos[i] as Map)['content'] ??
                          (rawTodos[i] as Map)['text'] ??
                          '')
                      .toString(),
                  done: (rawTodos[i] as Map)['done'] == true ||
                      (rawTodos[i] as Map)['status']?.toString() == 'completed' ||
                      (rawTodos[i] as Map)['status']?.toString() == 'done',
                  active: (rawTodos[i] as Map)['status']?.toString() == 'in_progress' ||
                      (rawTodos[i] as Map)['status']?.toString() == 'active',
                ),
          ];
        }
        final rawSubs = projVals['subagents'] ?? projVals['subagentCatalog'] ?? projVals['children'];
        if (rawSubs is List) {
          nextSubs = [
            for (var i = 0; i < rawSubs.length; i++)
              if (rawSubs[i] is Map)
                SubagentItem(
                  id: ((rawSubs[i] as Map)['sessionId'] ?? (rawSubs[i] as Map)['id'] ?? 'sub-$i').toString(),
                  name: ((rawSubs[i] as Map)['name'] ?? (rawSubs[i] as Map)['title'] ?? '子代理 ${i + 1}').toString(),
                  role: ((rawSubs[i] as Map)['role'] ?? (rawSubs[i] as Map)['mode'] ?? (rawSubs[i] as Map)['agentPreset'] ?? 'subagent').toString(),
                  status: (rawSubs[i] as Map)['status']?.toString() ?? ((rawSubs[i] as Map)['running'] == true ? 'running' : 'completed'),
                  taskSummary: ((rawSubs[i] as Map)['label'] ?? (rawSubs[i] as Map)['task'] ?? (rawSubs[i] as Map)['summary'] ?? '').toString(),
                  model: (rawSubs[i] as Map)['model']?.toString() ?? state.modelName,
                  durationLabel: (rawSubs[i] as Map)['durationLabel']?.toString() ??
                      ((rawSubs[i] as Map)['durationMs'] is num
                          ? '${(((rawSubs[i] as Map)['durationMs'] as num) / 1000).toStringAsFixed(1)}s'
                          : ''),
                  outputPreview: (rawSubs[i] as Map)['outputPreview']?.toString() ?? '',
                  worktreeBranch: (rawSubs[i] as Map)['worktreeBranch']?.toString() ?? (rawSubs[i] as Map)['branch']?.toString(),
                ),
          ];
        }
        if (nextPlan != null && nextPlan != (_pendingStreamPlanMode ?? state.planMode)) {
          _pendingStreamPlanMode = nextPlan;
          telemetryChanged = true;
        }
        if (nextTodos != null && !listEquals(nextTodos, _pendingStreamTodos ?? state.todos)) {
          _pendingStreamTodos = nextTodos;
          telemetryChanged = true;
        }
        if (nextSubs != null && !listEquals(nextSubs, _pendingStreamSubagents ?? state.subagents)) {
          _pendingStreamSubagents = nextSubs;
          telemetryChanged = true;
        }
        if (projVals.containsKey('goal')) {
          final nextGoals = _parseGoalProjection(projVals['goal']);
          if (!listEquals(nextGoals, _pendingStreamGoals ?? state.goals)) {
            _pendingStreamGoals = nextGoals;
            telemetryChanged = true;
          }
        }
        if (projVals.containsKey('inbox')) {
          final nextQueue = _parseInboxProjection(projVals['inbox']);
          if (nextQueue != null && !listEquals(nextQueue, _pendingStreamQueue ?? state.queuedMessages)) {
            _pendingStreamQueue = nextQueue;
            telemetryChanged = true;
          }
        }
        final rawLiveTitle = projVals['title'];
        if (rawLiveTitle is String) {
          final cleanTitle = rawLiveTitle.trim();
          if (cleanTitle.isNotEmpty &&
              !cleanTitle.startsWith('[object Object]') &&
              cleanTitle != (_pendingStreamTitle ?? state.activeSession?.title)) {
            _pendingStreamTitle = cleanTitle;
            telemetryChanged = true;
          }
        }
      }

      // Live DSH `todo/write` events arrive inside `session.event` `data.raw`; apply immediately!
      bool liveTodoOrGoalEvent = false;
      final rawEvt = data['raw'];
      if (rawEvt is Map) {
        final rawType = rawEvt['type']?.toString() ?? '';
        if (rawType == 'todo/write') {
          final evtData = rawEvt['data'];
          final rawList = evtData is Map ? evtData['todos'] : null;
          if (rawList is List) {
            final parsedTodos = [
              for (var i = 0; i < rawList.length; i++)
                if (rawList[i] is Map)
                  SessionTodoRecord(
                    id: (rawList[i] as Map)['id']?.toString() ?? 'td-$i',
                    title: ((rawList[i] as Map)['title'] ??
                            (rawList[i] as Map)['content'] ??
                            (rawList[i] as Map)['text'] ??
                            '')
                        .toString(),
                    done: (rawList[i] as Map)['done'] == true ||
                        (rawList[i] as Map)['status']?.toString() == 'completed' ||
                        (rawList[i] as Map)['status']?.toString() == 'done',
                    active: (rawList[i] as Map)['status']?.toString() == 'in_progress' ||
                        (rawList[i] as Map)['status']?.toString() == 'active',
                  ),
            ];
            if (!listEquals(parsedTodos, _pendingStreamTodos ?? state.todos)) {
              _pendingStreamTodos = parsedTodos;
              telemetryChanged = true;
              liveTodoOrGoalEvent = true;
            }
          }
        } else if (rawType.startsWith('goal/')) {
          liveTodoOrGoalEvent = true;
          unawaited(_refreshSessionGoalsOnly(activeSid));
        }
      }

      // Ignore stale in-flight streaming deltas for locally cancelled turns BEFORE clearing stall watchdog!
      final frameTurnId = data['turnId']?.toString();
      final isFreshTurnStart = type == 'turn.start' ||
          type == 'session.turn_start' ||
          type == 'user.message';
      if (isFreshTurnStart) {
        final nowFrameMs = DateTime.now().millisecondsSinceEpoch;
        if (!state.isStreaming &&
            _cancelledOptimisticSessionId == activeSid &&
            nowFrameMs < _cancelledOptimisticUntilMs) {
          // Suppress late `turn.start` from an optimistic prompt the user just cancelled before
          // server acknowledgement arrived, preventing a zombie duplicate streaming turn!
          if (frameTurnId != null && frameTurnId.isNotEmpty) {
            _locallyCancelledTurnIds.add(frameTurnId);
          }
          return;
        }
        _cancelSuppressUntilMs = 0;
        _cancelledOptimisticUntilMs = 0;
        _cancelledOptimisticSessionId = null;
        if (frameTurnId != null && frameTurnId.isNotEmpty) {
          _locallyCancelledTurnIds.remove(frameTurnId);
        }
        // DSH `turn/start` resets per-turn todos projection to empty.
        if ((type == 'turn.start' || type == 'session.turn_start') && state.todos.isNotEmpty) {
          _pendingStreamTodos = const [];
          telemetryChanged = true;
        }
      } else {
        final isCancelledTurnFrame =
            frameTurnId != null && frameTurnId.isNotEmpty && _locallyCancelledTurnIds.contains(frameTurnId);
        final isStreamMutatingFrame = type == 'turn.delta' ||
            type == 'text.delta' ||
            type == 'reasoning.delta' ||
            type == 'tool.call' ||
            type == 'tool.result' ||
            type == 'session.event';
        if (isCancelledTurnFrame &&
            (isStreamMutatingFrame ||
                type == 'turn.completed' ||
                type == 'turn.end' ||
                type == 'session.turn_end')) {
          if ((type == 'turn.completed' ||
                  type == 'turn.end' ||
                  type == 'session.turn_end') &&
              state.isStopping) {
            state = state.copyWith(isStopping: false);
          }
          return;
        }
        if (!state.isStreaming &&
            isStreamMutatingFrame &&
            DateTime.now().millisecondsSinceEpoch < _cancelSuppressUntilMs) {
          return;
        }
      }

      // Record live stream activity for stall watchdog after stale-turn filtering.
      _lastStreamActivityMs = DateTime.now().millisecondsSinceEpoch;
      _stallProbeCount = 0;
      _lastStallProbeMs = 0;

      // Independent per-channel recovery: both `session.stream_end` and `session.stream_error`
      // trigger bounded re-subscription + authoritative HTTP state calibration instead of
      // falsely terminating an active turn or leaving the channel deaf!
      final isSubStreamDisruption =
          type == 'session.stream_end' || type == 'session.stream_error';
      if (isSubStreamDisruption) {
        _scheduleSessionStreamResubscribe(client, activeSid, reason: type);
        unawaited(_syncLiveSessionBundle(activeSid, jumpToBottomOnLoad: false));
        if (type == 'session.stream_error') {
          return;
        }
      } else {
        if (_sessionStreamRetryCount.containsKey(activeSid)) {
          _sessionStreamRetryCount.remove(activeSid);
          _sessionStreamRetryTimers.remove(activeSid)?.cancel();
        }
      }

      final hadNoOutputBefore = state.sendStage != SendStage.idle || _turnReducer.isActiveTurnEmpty;
      final reduced = _turnReducer.apply(frame);
      final isTurnDone = (type == 'turn.completed' ||
              type == 'turn.end' ||
              type == 'session.turn_end') &&
          reduced;

      if (reduced || telemetryChanged || isTurnDone) {
        if (reduced) _pendingStreamReduced = true;
        if (telemetryChanged) {
          _pendingStreamTelemetryChanged = true;
          _pendingStreamTelemetry = nextTelemetry;
          _pendingCtxUsedK = nextCtxUsedK;
          _pendingCtxMaxK = nextCtxMaxK;
          _pendingCtxPct = nextCtxPct;
          _pendingCtxBreakdown = nextCtxBreakdown;
        }

        // Leading-edge flush on structural/terminal events AND the actual first visible token/step
        // of a turn (eliminating extra 42ms app coalesce delay on TTFT without flushing empty heartbeats!).
        final firstVisibleArrived = hadNoOutputBefore && reduced && !_turnReducer.isActiveTurnEmpty;
        final isStructuralToolEvent = type == 'tool.call' ||
            type == 'tool.result' ||
            type == 'session.tool_call' ||
            type == 'session.tool_result';
        final isImmediate = isTurnDone ||
            firstVisibleArrived ||
            liveTodoOrGoalEvent ||
            !state.isStreaming ||
            type == 'turn.start' ||
            type == 'session.turn_start' ||
            type == 'turn.snapshot' ||
            isStructuralToolEvent ||
            type.contains('action_card') ||
            type.contains('sdui') ||
            type.contains('error');

        if (isImmediate) {
          _flushCoalescedStreamFrame(isTurnDone: isTurnDone);
        } else {
          if (state.streamStalled) {
            state = state.copyWith(streamStalled: false);
          }
          _streamCoalesceTimer ??= Timer(
            const Duration(milliseconds: 16),
            _flushCoalescedStreamFrame,
          );
        }
      } else if (state.streamStalled) {
        state = state.copyWith(streamStalled: false);
      }
    } else if (type == 'interaction.requested') {
      final parsed = PendingInteraction.fromJson(data);
      _applyPendingInteraction(parsed);
      // Only fire a system alert notification when backgrounded OR the prompt belongs to
      // another (non-active) session — never spam notification shade in foreground!
      final isBackgrounded = _lastBackgroundedAt != null;
      final isOtherSession = parsed.sessionId != null &&
          parsed.sessionId!.isNotEmpty &&
          parsed.sessionId != state.activeSessionId;
      if (isBackgrounded || isOtherSession) {
        final payloadCmd = (data['payload'] is Map
                ? (data['payload'] as Map)['command'] ?? (data['payload'] as Map)['title']
                : null) ??
            data['command'];
        unawaited(
          GrassBagNativeBridge.instance.postAlertNotification(
            'GrassBag 等待你的确认',
            payloadCmd?.toString().trim().isNotEmpty == true
                ? payloadCmd.toString().trim()
                : _formatApprovalPrompt(parsed.payload),
            tag: 'interaction:${parsed.id}',
            kind: 'interaction',
            hostId: state.activeHostId,
            sessionId: parsed.sessionId ?? state.activeSessionId,
            interactionId: parsed.id,
          ),
        );
      }
    } else if (type == 'interaction.resolved') {
      _interactionMutationSeq++;
      final id = data['id']?.toString();
      if (id == null) {
        final toCancel = _pendingInteractionsById.keys.toList(growable: false);
        _pendingInteractionsById.clear();
        for (final key in toCancel) {
          unawaited(GrassBagNativeBridge.instance.cancelAlertNotification('interaction:$key'));
        }
      } else {
        _pendingInteractionsById.remove(id);
        unawaited(GrassBagNativeBridge.instance.cancelAlertNotification('interaction:$id'));
      }
      _recomputeVisibleInteractions();
    } else if (ch == 'host') {
      if (type == 'session.status') {
        final args = data['args'];
        if (args is List && args.length >= 2) {
          final targetSid = args[0]?.toString() ?? '';
          final isRunning = args[1] == true;
          if (targetSid.isNotEmpty &&
              state.sessions.any((s) => s.id == targetSid && s.running != isRunning)) {
            final becameUnread = !isRunning &&
                targetSid != state.activeSessionId &&
                state.sessions.any((s) => s.id == targetSid && s.running);
            if (becameUnread) {
              (_unreadSessionIdsByHost[state.activeHostId] ??= <String>{}).add(targetSid);
            }
            state = state.copyWith(
              sessions: [
                for (final s in state.sessions)
                  s.id == targetSid
                      ? s.copyWith(
                          running: isRunning,
                          unread: (!isRunning && s.running && targetSid != state.activeSessionId)
                              ? true
                              : s.unread,
                        )
                      : s,
              ],
            );
          }
        }
      } else if (type == 'schedule.changed' || type == 'schedules.changed') {
        unawaited(_refreshSchedulesOnly());
      } else if (type.startsWith('plugins.')) {
        unawaited(_refreshInstalledPluginsOnly());
      } else if (type == 'settings.updated' ||
          type == 'models.updated' ||
          type == 'credentials.updated' ||
          type == 'auth.notice' ||
          type == 'presets.changed' ||
          type == 'commands.changed') {
        _scheduleLiveDomainsRefresh();
      } else if (type == 'goal.changed') {
        final sid = state.activeSessionId;
        if (sid != null && !sid.startsWith('pending-session-')) {
          unawaited(_syncLiveSessionBundle(sid, jumpToBottomOnLoad: false));
        }
      } else if (type == 'host.ready') {
        if (DateTime.now().millisecondsSinceEpoch - _lastStage0HydrateMs > 2500) {
          _scheduleHostSessionsRefresh();
        }
      } else if (type == 'session.added' ||
          type == 'session.created' ||
          type == 'session.updated' ||
          type == 'session.archived' ||
          type == 'session.pinned' ||
          type == 'session.removed' ||
          type == 'session.deleted' ||
          type == 'session.renamed' ||
          type.startsWith('workspace.')) {
        _scheduleHostSessionsRefresh();
      }
    } else if (ch.startsWith('job:')) {
      final parts = ch.split(':');
      final jobId = parts.length >= 3 ? parts.sublist(2).join(':') : ch.substring(4);
      if (type == 'job.output') {
        final rawChunk = data['line']?.toString() ?? data['chunk']?.toString() ?? data['data']?.toString() ?? '';
        if (rawChunk.isNotEmpty) {
          final splitLines = rawChunk
              .split(RegExp(r'\r?\n'))
              .where((l) => l.isNotEmpty)
              .toList(growable: false);
          if (splitLines.isNotEmpty) {
            _jobOutputClient = client;
            _pendingJobOutputs.putIfAbsent(jobId, () => <String>[]).addAll(splitLines);
            _jobOutputFlushTimer ??= Timer(
              const Duration(milliseconds: 100),
              _flushPendingJobOutputs,
            );
          }
        }
      } else if (type == 'job.stream_error' || type == 'job.stream_end') {
        _scheduleJobStreamResubscribe(client, jobId);
      } else if (type == 'job.event') {
        if (_jobStreamRetryCount.containsKey(jobId)) {
          _jobStreamRetryCount.remove(jobId);
          _jobStreamRetryTimers.remove(jobId)?.cancel();
        }
        final prevJob = state.jobs.where((j) => j.id == jobId).firstOrNull;
        final status = extractJobEventStatus(data);
        if (status != null && status.isNotEmpty) {
          state = state.copyWith(
            jobs: [
              for (final j in state.jobs)
                j.id == jobId ? j.copyWith(status: status) : j,
            ],
          );
        }
        if (isTerminalJobStatus(status)) {
          final wasAlreadyTerminal = prevJob != null && isTerminalJobStatus(prevJob.status);
          if (!wasAlreadyTerminal && _lastBackgroundedAt != null) {
            final lower = (status ?? '').toLowerCase();
            final failed = lower.contains('fail') || lower.contains('error');
            final label = prevJob?.command.trim().isNotEmpty == true
                ? prevJob!.command.trim()
                : jobId;
            unawaited(
              GrassBagNativeBridge.instance.postAlertNotification(
                failed ? 'GrassBag 后台任务失败' : 'GrassBag 后台任务已完成',
                label,
                tag: 'job:$jobId',
                kind: 'job',
                hostId: state.activeHostId,
                jobId: jobId,
              ),
            );
          }
          unawaited(refreshJobs(silent: true));
        }
      }
    }
  }

  /// Routes a tapped Android notification directly to the originating host, session/approval, or Jobs page.
  Future<void> handleNotificationOpened(Map<String, dynamic> payload) async {
    if (!mounted) return;
    final kind = payload['kind']?.toString().trim() ?? '';
    final hostId = payload['hostId']?.toString().trim() ?? '';
    final sessionId = payload['sessionId']?.toString().trim() ?? '';
    final interactionId = payload['interactionId']?.toString().trim() ?? '';
    final jobId = payload['jobId']?.toString().trim() ?? '';

    final switchingHost = hostId.isNotEmpty &&
        hostId != state.activeHostId &&
        state.hosts.any((h) => h.id == hostId);
    if (switchingHost) {
      if (sessionId.isNotEmpty) {
        final ctx = Map<String, dynamic>.from(_hostContexts[hostId] ?? const <String, dynamic>{});
        ctx['lastSessionId'] = sessionId;
        final originKey = _hostOriginKey(hostId);
        if (originKey.isNotEmpty) ctx['lastHostOrigin'] = originKey;
        _hostContexts[hostId] = ctx;
      }
      await switchHost(hostId);
    }
    if (!mounted) return;
    if (interactionId.isNotEmpty) {
      _preferredInteractionId = interactionId;
      _recomputeVisibleInteractions();
    }
    if (kind == 'job' || (jobId.isNotEmpty && sessionId.isEmpty)) {
      if (jobId.isNotEmpty) {
        unawaited(GrassBagNativeBridge.instance.cancelAlertNotification('job:$jobId'));
      }
      unawaited(refreshJobs(silent: true));
      state = state.copyWith(openJobsSignal: state.openJobsSignal + 1);
      return;
    }
    if (sessionId.isNotEmpty &&
        sessionId != state.activeSessionId &&
        (!switchingHost || state.sessions.any((s) => s.id == sessionId))) {
      selectSession(sessionId);
    } else if (interactionId.isNotEmpty) {
      _recomputeVisibleInteractions();
    }
  }

  void _applyPendingInteraction(PendingInteraction item) {
    _interactionMutationSeq++;
    _pendingInteractionsById[item.id] = item;
    _recomputeVisibleInteractions();
  }

  Future<String?> createWebUiTicketUrl({ManagedHost? host}) async {
    final targetHost = host ?? state.activeHost;
    final activeSid = state.activeSessionId;
    final realSid = (activeSid != null && !activeSid.startsWith('pending-session-'))
        ? activeSid
        : null;

    if (!targetHost.isLocal && targetHost.hasSavedCookie && targetHost.address.startsWith('http')) {
      await GrassBagNativeBridge.instance.setWebViewCookies(
        targetHost.address,
        targetHost.sessionCookie!,
      );
    }

    if (host != null && host.id != state.activeHostId && !host.isLocal) {
      final addr = _normalizeHttpAddress(host);
      final uri = Uri.tryParse(addr);
      if (uri != null && uri.hasScheme) {
        final cleanUri = _stripUriQuery(uri);
        final tok = host.token ?? uri.queryParameters['token'];
        final tempClient = GbridgeClient(
          HostEndpoint.http(
            baseUri: cleanUri,
            token: tok,
            cookie: host.sessionCookie,
          ),
          timeout: const Duration(seconds: 12),
          allowBadCertificates: host.allowBadCertificates,
        );
        try {
          if (!host.hasSavedCookie && tok != null && tok.isNotEmpty) {
            try {
              await tempClient.exchangeAuthToken(tok);
            } catch (_) {}
          }
          final ticket = await tempClient.createWebTicket();
          final authUrl = ticket.authenticatedUrl.trim();
          if (authUrl.isNotEmpty) {
            final parsed = Uri.tryParse(authUrl);
            if (parsed != null && parsed.hasScheme) {
              final isLoopback = parsed.host == '127.0.0.1' || parsed.host == 'localhost' || parsed.host == '::1';
              if (isLoopback && cleanUri.host != '127.0.0.1' && cleanUri.host != 'localhost') {
                return parsed
                    .replace(scheme: cleanUri.scheme, host: cleanUri.host, port: cleanUri.hasPort ? cleanUri.port : null)
                    .toString();
              }
              return authUrl;
            }
            return tempClient.endpoint.resolveHttpUri(authUrl).toString();
          }
        } catch (_) {
          // Fallback to direct host URL below
        } finally {
          await tempClient.dispose();
        }
        return tok != null && tok.isNotEmpty
            ? cleanUri.replace(queryParameters: {'token': tok}).toString()
            : cleanUri.toString();
      }
    }

    final client = _liveClient;
    if (client != null && targetHost.id == state.activeHostId) {
      try {
        final ticket = await client.createWebTicket(sessionId: realSid);
        final authUrl = ticket.authenticatedUrl.trim();
        if (authUrl.isNotEmpty) {
          if (targetHost.isLocal && GrassBagNativeBridge.instance.isAndroidNative) {
            final base = Uri.parse(state.nativeRuntimeStatus.bridgeHttpUrl);
            final parsed = Uri.tryParse(authUrl);
            if (parsed != null && parsed.hasScheme) {
              return parsed
                  .replace(scheme: base.scheme, host: base.host, port: base.port)
                  .toString();
            }
            return base.resolve(authUrl).toString();
          }
          final parsed = Uri.tryParse(authUrl);
          if (parsed != null && parsed.hasScheme) {
            final isLoopback = parsed.host == '127.0.0.1' || parsed.host == 'localhost' || parsed.host == '::1';
            final epUri = client.endpoint.baseUri;
            if (isLoopback && epUri != null && epUri.host.isNotEmpty &&
                epUri.host != '127.0.0.1' && epUri.host != 'localhost' && epUri.host != '::1') {
              return parsed
                  .replace(
                    scheme: epUri.scheme,
                    host: epUri.host,
                    port: epUri.hasPort ? epUri.port : null,
                  )
                  .toString();
            }
            return authUrl;
          }
          return client.endpoint.resolveHttpUri(authUrl).toString();
        }
      } catch (_) {}
    }
    if (targetHost.isLocal && GrassBagNativeBridge.instance.isAndroidNative) {
      final direct = state.nativeRuntimeStatus.dshWebUrl.trim();
      if (direct.startsWith('http://') || direct.startsWith('https://')) {
        return direct;
      }
    }
    return null;
  }

  Future<void> installHelperOnHost(
    String hostId, {
    String packageSpec = kOfficialGbridgeAcceleratedUrl,
    String? registryUrl,
  }) async {
    final host = state.hosts.where((h) => h.id == hostId).firstOrNull;
    if (host == null || host.bridged || host.installing) return;
    state = state.copyWith(
      hosts: [
        for (final h in state.hosts) h.id == hostId ? h.copyWith(installing: true) : h,
      ],
    );

    final uri = Uri.tryParse(host.address);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      state = state.copyWith(
        hosts: [
          for (final h in state.hosts)
            h.id == hostId ? h.copyWith(installing: false, lastError: '无效的主机地址') : h,
        ],
      );
      showError('无法安装连接助手', error: '主机地址格式无效：${host.address}');
      return;
    }

    final cleanUri = _stripUriQuery(uri);
    final token = host.token ?? uri.queryParameters['token'];
    final client = GbridgeClient(
      HostEndpoint.http(
        baseUri: cleanUri,
        token: token,
        cookie: host.sessionCookie,
      ),
      timeout: const Duration(seconds: 90),
      allowBadCertificates: host.allowBadCertificates,
      onCookieUpdated: (c) => _persistHostCookie(host.id, c),
    );
    try {
      if (!host.hasSavedCookie && token != null && token.isNotEmpty) {
        try {
          await client.exchangeAuthToken(token);
        } catch (_) {}
      }
      const pinnedGbridgeSha = String.fromEnvironment('GRASSBAG_GBRIDGE_SHA256');
      final result = await client.bootstrap.installHelperBundleDetailed(
        packageSpec: packageSpec.trim().isEmpty ? kOfficialGbridgeAcceleratedUrl : packageSpec.trim(),
        registryUrl: registryUrl,
        expectedSha256: pinnedGbridgeSha.isEmpty ? null : pinnedGbridgeSha,
        fetchRemoteBytes: (remoteUri) async {
          final origin = Uri(
            scheme: remoteUri.scheme,
            host: remoteUri.host,
            port: remoteUri.hasPort ? remoteUri.port : null,
          );
          final t = GbridgeHttpTransport(
            HostEndpoint.http(baseUri: origin),
            timeout: const Duration(seconds: 25),
          );
          try {
            return await t.requestBytes(
              'GET',
              remoteUri.path,
              query: remoteUri.queryParameters.isEmpty ? null : remoteUri.queryParameters,
            );
          } finally {
            t.close();
          }
        },
        pollTimeout: const Duration(seconds: 35),
        onProgress: (stage) {
          if (mounted) showToast(stage, tone: ToastTone.info);
        },
      );
      if (!mounted) {
        await client.dispose();
        return;
      }
      if (result.restartRequired || result.capabilities == null) {
        await client.dispose();
        state = state.copyWith(
          hosts: [
            for (final h in state.hosts)
              h.id == hostId ? h.copyWith(installing: false, clearLastError: true) : h,
          ],
        );
        showToast(
          result.message ?? '${host.name} 已安装连接助手，重启电脑端 DeepSeek Harness 后立即生效',
          tone: ToastTone.ok,
        );
        return;
      }
      final caps = result.capabilities!;
      state = state.copyWith(
        hosts: [
          for (final h in state.hosts)
            h.id == hostId
                ? h.copyWith(
                    installing: false,
                    bridged: true,
                    directMode: false,
                    online: true,
                    dshVersion: caps.dshVersion,
                    helperVersion: caps.bridgeVersion,
                    clearLastError: true,
                  )
                : h,
        ],
      );
      _persistHosts();
      if (hostId == state.activeHostId) {
        final gen = ++_hostConnectGen;
        await _bindFullLiveClient(
          client,
          hostId,
          caps,
          gen: gen,
          isDirect: false,
          restoreLastSession: false,
        );
      } else {
        // Never hijack activeHostId or wipe the user's current conversation when upgrading a background host!
        await client.dispose();
      }
      showToast('${host.name} 已升级为增强模式（助手 v${caps.bridgeVersion} 已就绪）');
    } catch (e) {
      await client.dispose();
      if (!mounted) return;
      final readable = formatReadableError(e);
      state = state.copyWith(
        hosts: [
          for (final h in state.hosts)
            h.id == hostId
                ? (h.online && h.directMode
                    // Never clobber an already-working zero-plugin direct connection with a helper error!
                    ? h.copyWith(installing: false, bridged: false)
                    : h.copyWith(installing: false, bridged: false, lastError: readable))
                : h,
        ],
      );
      showError('安装连接助手失败（不影响免插件原生直连）', error: e);
    }
  }

  ManagedHost? addRemoteHost(
    String address, {
    String? name,
    String? token,
    String? cookie,
    bool allowBadCertificates = false,
    bool autoProbe = true,
    bool silent = false,
  }) {
    final parsed = parseRemoteHostInput(address, explicitToken: token);
    if (parsed == null) {
      if (!silent) {
        showToast('请输入有效地址，或直接粘贴 `dsh web: http://...` 链接', tone: ToastTone.warn);
      }
      return null;
    }
    final parsedUri = Uri.tryParse(parsed.address);
    if (parsedUri != null) {
      final selfMsg = selfDeviceGuidanceForUri(parsedUri);
      if (selfMsg != null) {
        if (!silent) {
          showToast(selfMsg, tone: ToastTone.info);
        }
        return null;
      }
    }
    final cleanCookie = (cookie != null && cookie.trim().isNotEmpty) ? cookie.trim() : null;
    // Deduplicate if a remote host with the exact same normalized address already exists.
    final existing = state.hosts
        .where((h) => !h.isLocal && h.address.toLowerCase() == parsed.address.toLowerCase())
        .firstOrNull;
    if (existing != null) {
      final hasNewToken =
          parsed.token != null && parsed.token!.isNotEmpty && parsed.token != existing.token;
      final dropStaleCookie = cleanCookie == null && hasNewToken;
      final merged = existing.copyWith(
        name: (name != null && name.trim().isNotEmpty) ? name.trim() : existing.name,
        allowBadCertificates: allowBadCertificates || existing.allowBadCertificates,
        token: (parsed.token != null && parsed.token!.isNotEmpty) ? parsed.token : existing.token,
        sessionCookie: cleanCookie ?? (dropStaleCookie ? null : existing.sessionCookie),
        clearSessionCookie: dropStaleCookie,
        clearLastError: true,
      );
      state = state.copyWith(
        hosts: [for (final h in state.hosts) h.id == existing.id ? merged : h],
      );
      _persistHosts();
      if (parsed.token != null && parsed.token!.isNotEmpty) {
        unawaited(GrassBagNativeBridge.instance.putSecret('host_token_${existing.id}', parsed.token!));
      }
      if (cleanCookie != null) {
        unawaited(GrassBagNativeBridge.instance.putSecret('host_cookie_${existing.id}', cleanCookie));
      } else if (dropStaleCookie) {
        unawaited(GrassBagNativeBridge.instance.deleteSecret('host_cookie_${existing.id}'));
      }
      if (!silent) {
        showToast('已更新已有远程主机「${merged.name}」', tone: ToastTone.info);
      }
      if (autoProbe) {
        unawaited(_probeHostOnly(merged));
      }
      return merged;
    }
    final id = 'rem-${DateTime.now().millisecondsSinceEpoch}-${++_hostIdSeq}';
    final created = ManagedHost(
      id: id,
      isLocal: false,
      name: (name == null || name.trim().isEmpty)
          ? (parsed.suggestedName ?? parsed.address)
          : name.trim(),
      address: parsed.address,
      latency: '探测中',
      online: false,
      bridged: false,
      directMode: false,
      allowBadCertificates: allowBadCertificates,
      token: parsed.token,
      sessionCookie: cleanCookie,
    );
    state = state.copyWith(hosts: [...state.hosts, created]);
    _persistHosts();
    if (parsed.token != null && parsed.token!.isNotEmpty) {
      unawaited(GrassBagNativeBridge.instance.putSecret('host_token_$id', parsed.token!));
    }
    if (cleanCookie != null) {
      unawaited(GrassBagNativeBridge.instance.putSecret('host_cookie_$id', cleanCookie));
    }
    if (!silent) {
      showToast(
        created.isInsecurePublicHttp
            ? '已添加公网明文 HTTP 主机，建议升级为 HTTPS 以保护会话凭证'
            : (parsed.wasAutoPorted
                ? '已自动补全 :3080 端口，正在免插件探测连接…'
                : '已添加远程主机，正在探测连接…'),
        tone: created.isInsecurePublicHttp ? ToastTone.warn : ToastTone.ok,
      );
    }
    if (autoProbe) {
      unawaited(_probeHostOnly(created));
    }
    return created;
  }

  Future<void> updateHostDetails(
    String hostId, {
    String? name,
    String? address,
    bool? allowBadCertificates,
  }) async {
    final target = state.hosts.where((h) => h.id == hostId).firstOrNull;
    if (target == null || target.isLocal) return;
    final nextName = name != null && name.trim().isNotEmpty ? name.trim() : target.name;
    var nextAddr = target.address;
    String? extractedToken;
    if (address != null && address.trim().isNotEmpty) {
      final parsed = parseRemoteHostInput(address);
      if (parsed == null) {
        showToast('主机地址格式无效', tone: ToastTone.warn);
        return;
      }
      final parsedUri = Uri.tryParse(parsed.address);
      if (parsedUri != null) {
        final selfMsg = selfDeviceGuidanceForUri(parsedUri);
        if (selfMsg != null) {
          showToast(selfMsg, tone: ToastTone.info);
          return;
        }
      }
      extractedToken = parsed.token;
      nextAddr = parsed.address;
    }
    final oldOrigin = _hostOriginKey(hostId);
    final originChanged = nextAddr.toLowerCase() != target.address.toLowerCase();
    if (originChanged) {
      if (_hostContexts.remove(hostId) != null) {
        _persistHostContexts(immediate: true);
      }
      _purgeHostAttachmentCaches(hostId, onlyOrigin: oldOrigin);
    } else if (state.activeHostId == hostId && state.pendingAttachments.isNotEmpty) {
      _stashPendingAttachmentsForScope(hostId, state.activeSessionId);
      _stashQueuedMessagesForScope(hostId, state.activeSessionId);
    }
    final hasExtractedToken = extractedToken != null && extractedToken.isNotEmpty;
    final shouldClearToken = originChanged && !hasExtractedToken;
    final shouldClearCookie = originChanged || hasExtractedToken;
    final updated = target.copyWith(
      name: nextName,
      address: nextAddr,
      allowBadCertificates: allowBadCertificates ?? target.allowBadCertificates,
      token: hasExtractedToken ? extractedToken : (shouldClearToken ? null : target.token),
      clearToken: shouldClearToken,
      clearSessionCookie: shouldClearCookie,
      clearLastError: true,
    );
    state = state.copyWith(
      hosts: [for (final h in state.hosts) h.id == hostId ? updated : h],
    );
    _persistHosts();
    if (hasExtractedToken) {
      unawaited(GrassBagNativeBridge.instance.putSecret('host_token_$hostId', extractedToken));
    } else if (shouldClearToken) {
      unawaited(GrassBagNativeBridge.instance.deleteSecret('host_token_$hostId'));
    }
    if (shouldClearCookie) {
      unawaited(GrassBagNativeBridge.instance.deleteSecret('host_cookie_$hostId'));
      if (state.activeHostId == hostId) {
        _liveClient?.transport.setCookieHeader(null);
      }
    }
    showToast('已更新主机「${updated.name}」配置');
    if (state.activeHostId == hostId) {
      await switchHost(
        hostId,
        savePreviousContext: !originChanged,
        preserveActiveDrafts: !originChanged,
      );
    } else {
      unawaited(_probeHostOnly(updated));
    }
  }

  Future<void> updateHostToken(
    String hostId,
    String token, {
    bool awaitConnect = false,
  }) async {
    final raw = token.trim();
    // Allow pasting an entire `dsh web: http://.../?token=...` line OR QR JSON directly into the token sheet!
    final looksStructured = raw.contains('://') ||
        raw.contains('token=') ||
        raw.startsWith('{') ||
        RegExp(r'^\s*(?:dsh\s+web|url|host|address)\s*[:：]', caseSensitive: false).hasMatch(raw);
    final parsedFromLine = looksStructured ? parseRemoteHostInput(raw) : null;
    if (looksStructured && (parsedFromLine?.token == null || parsedFromLine!.token!.trim().isEmpty)) {
      showToast('粘贴的地址或二维码未包含 ?token= 访问令牌，请粘贴完整链接或纯 Token', tone: ToastTone.warn);
      return;
    }
    final cleanToken = parsedFromLine?.token?.trim() ?? raw;
    final target = state.hosts.where((h) => h.id == hostId).firstOrNull;
    if (target == null) return;
    // If user pasted a full `http://192.168.x.x:3080/?token=...` link after a DHCP IP change,
    // seamlessly update the host address too (as long as it's not a loopback/self address)!
    var nextAddr = target.address;
    if (!target.isLocal && parsedFromLine != null) {
      final parsedUri = Uri.tryParse(parsedFromLine.address);
      if (parsedUri != null && selfDeviceGuidanceForUri(parsedUri) == null) {
        nextAddr = parsedFromLine.address;
      }
    }
    final oldOrigin = _hostOriginKey(hostId);
    final originChanged = nextAddr.toLowerCase() != target.address.toLowerCase();
    if (originChanged) {
      if (_hostContexts.remove(hostId) != null) {
        _persistHostContexts(immediate: true);
      }
      _purgeHostAttachmentCaches(hostId, onlyOrigin: oldOrigin);
    } else if (state.activeHostId == hostId && state.pendingAttachments.isNotEmpty) {
      _stashPendingAttachmentsForScope(hostId, state.activeSessionId);
      _stashQueuedMessagesForScope(hostId, state.activeSessionId);
    }
    final updated = target.copyWith(
      address: nextAddr,
      token: cleanToken.isEmpty ? null : cleanToken,
      clearToken: cleanToken.isEmpty,
      clearSessionCookie: true,
      clearLastError: true,
    );
    state = state.copyWith(
      hosts: [
        for (final h in state.hosts) h.id == hostId ? updated : h,
      ],
    );
    _persistHosts();
    if (cleanToken.isNotEmpty) {
      unawaited(GrassBagNativeBridge.instance.putSecret('host_token_$hostId', cleanToken));
    } else {
      unawaited(GrassBagNativeBridge.instance.deleteSecret('host_token_$hostId'));
    }
    unawaited(GrassBagNativeBridge.instance.deleteSecret('host_cookie_$hostId'));
    if (state.activeHostId == hostId) {
      _liveClient?.transport.setCookieHeader(null);
      showToast('已更新访问令牌，正在重新连接 ${updated.name}…', tone: ToastTone.info);
      await switchHost(
        hostId,
        awaitConnect: awaitConnect,
        savePreviousContext: !originChanged,
        preserveActiveDrafts: !originChanged,
      );
    } else if (awaitConnect) {
      showToast('已更新 ${updated.name} 的访问令牌，正在验证…', tone: ToastTone.info);
      await _probeHostOnly(updated);
    } else {
      showToast('已更新 ${updated.name} 的访问令牌，正在探测…', tone: ToastTone.info);
      unawaited(_probeHostOnly(updated));
    }
  }

  Future<void> updateHostCookie(
    String hostId,
    String cookieHeader, {
    bool switchAndConnect = true,
  }) async {
    final clean = cookieHeader.trim();
    final target = state.hosts.where((h) => h.id == hostId).firstOrNull;
    if (target == null || clean.isEmpty) return;
    final unchanged = target.sessionCookie == clean;
    if (unchanged && !switchAndConnect) return;
    final updated = target.copyWith(
      sessionCookie: clean,
      clearLastError: true,
    );
    state = state.copyWith(
      hosts: [
        for (final h in state.hosts) h.id == hostId ? updated : h,
      ],
    );
    unawaited(GrassBagNativeBridge.instance.putSecret('host_cookie_$hostId', clean));
    final isAlreadyConnectedActive = state.activeHostId == hostId &&
        state.connectionPhase == ConnectionPhase.connected &&
        _liveClient != null;
    if (switchAndConnect || (state.activeHostId == hostId && !isAlreadyConnectedActive)) {
      showToast('已同步网页登录凭证（30 天免 Token），正在接入 ${updated.name}…', tone: ToastTone.ok);
      await switchHost(hostId);
    } else if (!isAlreadyConnectedActive) {
      showToast('已保存 ${updated.name} 的 30 天登录凭证', tone: ToastTone.ok);
      unawaited(_probeHostOnly(updated));
    }
  }

  Future<void> clearHostCookie(String hostId) async {
    final target = state.hosts.where((h) => h.id == hostId).firstOrNull;
    if (target == null) return;
    final hasFallbackToken = (target.token ?? '').trim().isNotEmpty;
    final updated = target.copyWith(
      clearSessionCookie: true,
      online: hasFallbackToken ? target.online : false,
    );
    state = state.copyWith(
      hosts: [
        for (final h in state.hosts) h.id == hostId ? updated : h,
      ],
    );
    unawaited(GrassBagNativeBridge.instance.deleteSecret('host_cookie_$hostId'));
    unawaited(GrassBagNativeBridge.instance.clearWebViewCookies());
    if (state.activeHostId == hostId) {
      _liveClient?.transport.setCookieHeader(null);
      if (!hasFallbackToken) {
        unawaited(switchHost(hostId));
      }
    } else if (!hasFallbackToken) {
      unawaited(_probeHostOnly(updated));
    }
    showToast('已清除「${target.name}」的缓存登录凭证（含网页 Cookie）', tone: ToastTone.info);
  }

  Future<void> setHostAllowBadCertificates(String hostId, bool allow) async {
    final target = state.hosts.where((h) => h.id == hostId).firstOrNull;
    if (target == null || target.isLocal || target.allowBadCertificates == allow) return;
    final updated = target.copyWith(allowBadCertificates: allow, clearLastError: true);
    state = state.copyWith(
      hosts: [
        for (final h in state.hosts) h.id == hostId ? updated : h,
      ],
    );
    _persistHosts();
    showToast(allow ? '已信任该主机的自签名 HTTPS 证书，正在重连…' : '已恢复严格 HTTPS 证书校验', tone: ToastTone.info);
    if (state.activeHostId == hostId) {
      await switchHost(hostId);
    } else {
      unawaited(_probeHostOnly(updated));
    }
  }

  void removeRemoteHost(String hostId) {
    if (hostId == 'local') return;
    final wasActive = state.activeHostId == hostId;
    _hostContexts.remove(hostId);
    _sessionAttachmentsMemory.removeWhere((k, _) => k.startsWith('$hostId::'));
    _hostProbeGen.remove(hostId);
    _persistHostContexts();
    final nextHosts = state.hosts.where((h) => h.id != hostId).toList(growable: false);
    state = state.copyWith(
      hosts: nextHosts,
    );
    _persistHosts();
    unawaited(GrassBagNativeBridge.instance.deleteSecret('host_token_$hostId'));
    unawaited(GrassBagNativeBridge.instance.deleteSecret('host_cookie_$hostId'));
    showToast('已移除远程主机', tone: ToastTone.info);
    if (wasActive) {
      unawaited(switchHost('local', savePreviousContext: false));
    }
  }

  // ---------------------------------------------------------------------------
  // Real Version Check & Local A/B Dual-Slot Online Updates + Rollback
  // ---------------------------------------------------------------------------
  Future<void> checkForDshUpdates({bool silent = false}) async {
    if (state.checkingUpdate) return;
    final client = _liveClient;
    if (client == null) {
      if (!silent) showToast('请先连接到 DSH 主机后再检查更新', tone: ToastTone.warn);
      return;
    }
    final targetHostId = state.activeHostId;
    final checkSeq = ++_dshUpdateCheckSeq;
    state = state.copyWith(checkingUpdate: true);
    try {
      final resp = await client.checkSystemUpdate();
      if (!mounted || !identical(_liveClient, client)) return;
      final parsed = DshUpdateCheckResult.fromJson(resp);
      final targetHost = state.hosts.firstWhere(
        (h) => h.id == targetHostId,
        orElse: () => state.activeHost,
      );
      final nextLatest = parsed.hasUpdate ? parsed.recommendedVersion : targetHost.dshVersion;
      state = state.copyWith(
        checkingUpdate: false,
        updateCheck: parsed,
        hosts: [
          for (final h in state.hosts)
            h.id == targetHostId
                ? h.copyWith(
                    dshVersion: parsed.currentVersion.isNotEmpty && parsed.currentVersion != 'unknown'
                        ? parsed.currentVersion
                        : h.dshVersion,
                    dshLatest: nextLatest,
                  )
                : h,
        ],
      );
      if (!silent) {
        if (parsed.error != null && parsed.error!.isNotEmpty) {
          showError('检查更新失败', error: parsed.error);
        } else if (parsed.hasUpdate) {
          showToast('发现 DSH 新版本 v${parsed.recommendedVersion}（当前 v${parsed.currentVersion}）', tone: ToastTone.info);
        } else {
          showToast('当前 DSH v${parsed.currentVersion} 已是最新版本');
        }
      }
    } catch (e) {
      if (!_isStillLive(client)) return;
      state = state.copyWith(checkingUpdate: false);
      if (!silent) showError('检查更新失败', error: e);
    } finally {
      if (mounted && checkSeq == _dshUpdateCheckSeq && state.checkingUpdate) {
        state = state.copyWith(checkingUpdate: false);
      }
    }
  }

  Future<void> upgradeLocalDsh() async {
    final local = state.localHost;
    if (local.updatingDsh) return;
    if (local.dshVersion == local.dshLatest) {
      showToast('当前 DSH v${local.dshVersion} 已是最新版本', tone: ToastTone.info);
      return;
    }
    state = state.copyWith(
      hosts: [for (final h in state.hosts) h.isLocal ? h.copyWith(updatingDsh: true) : h],
    );

    final native = GrassBagNativeBridge.instance;
    if (native.isAndroidNative) {
      final isLocalActive = state.activeHost.isLocal;
      final gen = isLocalActive ? ++_hostConnectGen : null;
      if (isLocalActive) {
        await _disconnectLiveClients();
      }
      final res = await native.upgradeAbSlot(version: local.dshLatest);
      await refreshNativeStatus(connectGen: gen);
      if (!mounted) return;
      final ok = res['ok'] == true;
      if (!ok) {
        state = state.copyWith(
          runtimeProgressPct: 0,
          runtimeProgressMsg: '',
          hosts: [for (final h in state.hosts) h.isLocal ? h.copyWith(updatingDsh: false) : h],
        );
        showError('本机 DSH 更新失败', error: res['error'] ?? 'A/B 槽位安装未通过，已保留原版本');
        return;
      }
      final newVer = state.nativeRuntimeStatus.dshVersion;
      state = state.copyWith(
        hosts: [
          for (final h in state.hosts)
            h.isLocal
                ? h.copyWith(
                    updatingDsh: false,
                    dshPrevVersion: local.dshVersion,
                    dshVersion: newVer,
                    dshLatest: newVer,
                  )
                : h,
        ],
      );
      _persistHosts();
      showToast('本机 DSH 已在 A/B 槽位更新至 v$newVer');
      return;
    }

    // Desktop / Web host: DSH is managed on the host shell, guide honestly instead of faking!
    state = state.copyWith(
      hosts: [for (final h in state.hosts) h.isLocal ? h.copyWith(updatingDsh: false) : h],
    );
    showToast(
      '当前为宿主机直连模式，请在宿主机终端执行 npm i -g @deepseek-ai/dsh@${local.dshLatest}',
      tone: ToastTone.info,
      detail: '宿主机运行在 ${local.containerVersion}，请在终端运行：\nnpm install -g @deepseek-ai/dsh@${local.dshLatest}',
    );
  }

  Future<void> revertLocalDsh() async {
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      final isLocalActive = state.activeHost.isLocal;
      final gen = isLocalActive ? ++_hostConnectGen : null;
      if (isLocalActive) {
        await _disconnectLiveClients();
      }
      final res = await GrassBagNativeBridge.instance.rollbackLkg();
      await refreshNativeStatus(connectGen: gen);
      if (!mounted) return;
      if (res['ok'] != true) {
        showError('回滚上一版本失败', error: res['error'] ?? '备用 LKG 槽位未初始化');
        return;
      }
      final restored = state.nativeRuntimeStatus.dshVersion;
      state = state.copyWith(
        hosts: [
          for (final h in state.hosts)
            h.isLocal
                ? h.copyWith(dshPrevVersion: h.dshVersion, dshVersion: restored, dshLatest: restored)
                : h,
        ],
      );
      _persistHosts();
      showToast('已原子回滚到 LKG 槽位 v$restored', tone: ToastTone.info);
      return;
    }
    showToast('仅本机 Android 双槽位运行时支持原子版本回滚', tone: ToastTone.info);
  }

  Future<void> upgradeLocalContainer() async {
    showToast('当前 Linux 容器镜像已是最新版本', tone: ToastTone.info);
  }

  void setLauncherMode(String modeOrKey) {
    final useProot = modeOrKey == '兼容模式' || modeOrKey.startsWith('proot');
    final nextLabel = useProot ? '兼容模式' : '高速模式';
    final nativeKey = useProot ? 'proot' : 'tawcroot';
    state = state.copyWith(
      hosts: [for (final h in state.hosts) h.isLocal ? h.copyWith(launcherMode: nextLabel) : h],
      nativeRuntimeStatus: state.nativeRuntimeStatus.copyWith(configuredExecutorMode: nativeKey),
    );
    unawaited(
      GrassBagNativeBridge.instance.setExecutorMode(nativeKey).then((updatedStatus) {
        if (mounted && updatedStatus != null) {
          state = state.copyWith(nativeRuntimeStatus: updatedStatus);
        }
      }),
    );
    _persistHosts();
    showToast('已切换到$nextLabel（$nativeKey），重启本机引擎后生效', tone: ToastTone.info);
  }

  void cycleLauncherMode() {
    final cur = state.localHost.launcherMode;
    setLauncherMode(cur == '兼容模式' ? '高速模式' : '兼容模式');
  }

  void toggleSdcardMounted() {
    final next = !state.localHost.sdcardMounted;
    state = state.copyWith(
      hosts: [for (final h in state.hosts) h.isLocal ? h.copyWith(sdcardMounted: next) : h],
    );
    unawaited(GrassBagNativeBridge.instance.setSdcardMounted(next));
    _persistHosts();
    showToast(
      next ? '已开启访问手机存储 (/sdcard)，重启引擎或新开终端后生效' : '已关闭访问手机存储',
      tone: ToastTone.info,
    );
  }

  Future<void> togglePlugin(String id) async {
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    final target = state.plugins.where((p) => p.id == id).firstOrNull;
    if (target == null) return;
    if (!target.optional && target.enabled) {
      showToast(target.readOnlyReason ?? '该插件为核心必选插件，不可关闭', tone: ToastTone.warn);
      return;
    }
    final nextEnabled = !target.enabled;
    final prev = state.plugins;
    state = state.copyWith(
      plugins: [
        for (final p in state.plugins) p.id == id ? p.copyWith(enabled: nextEnabled) : p,
      ],
    );
    try {
      await client.setPluginBundleEnabled(id, nextEnabled);
      if (!_isStillLive(client)) return;
      unawaited(_hydrateLiveDomains(client));
      showToast('${target.name}已${nextEnabled ? '开启' : '关闭'}', tone: ToastTone.info);
    } catch (e) {
      if (!_isStillLive(client)) return;
      state = state.copyWith(plugins: prev);
      showError('切换插件状态失败', error: e);
    }
  }

  void setPhoneSetting({
    bool? accessibility,
    bool? overlay,
    bool? shizuku,
    bool? confirmHighRisk,
    bool? autoReturn,
    bool? showEdgeAurora,
    bool? showGestureFx,
  }) {
    state = state.copyWith(
      phoneAccessibility: accessibility,
      phoneOverlay: overlay,
      phoneShizuku: shizuku,
      phoneConfirmHighRisk: confirmHighRisk,
      phoneAutoReturn: autoReturn,
      phoneShowEdgeAurora: showEdgeAurora,
      phoneShowGestureFx: showGestureFx,
    );
    if (confirmHighRisk != null ||
        autoReturn != null ||
        showEdgeAurora != null ||
        showGestureFx != null) {
      _persistPrefs();
      if (GrassBagNativeBridge.instance.isAndroidNative) {
        if (confirmHighRisk != null) {
          unawaited(GrassBagNativeBridge.instance.setSafetyConfirmHighRisk(confirmHighRisk));
        }
        if (autoReturn != null) {
          unawaited(GrassBagNativeBridge.instance.setSafetyAutoReturn(autoReturn));
        }
        if (showEdgeAurora != null) {
          unawaited(GrassBagNativeBridge.instance.setSafetyShowEdgeAurora(showEdgeAurora));
        }
        if (showGestureFx != null) {
          unawaited(GrassBagNativeBridge.instance.setSafetyShowGestureFx(showGestureFx));
        }
      }
    }
  }

  Future<void> setPhonePaused(bool paused) async {
    state = state.copyWith(
      phoneLivePaused: paused,
      phoneHandoffReason: paused ? state.phoneHandoffReason : '',
    );
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      await GrassBagNativeBridge.instance.setPhonePaused(paused);
    }
    showToast(paused ? '已暂停手机操控，可手动接管或随时继续' : '已恢复手机操控');
  }

  Future<void> previewPhoneOverlay({String mode = 'interactive'}) async {
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      _syncNativeThemePalette();
      await GrassBagNativeBridge.instance.previewPhoneOverlay(mode: mode);
    }
  }

  Future<void> setSafetyPolicy(String policy) async {
    final native = GrassBagNativeBridge.instance;
    if (native.isAndroidNative) {
      final ok = await native.setSafetyPolicy(policy);
      if (!ok && mounted) {
        showToast('任务执行期间禁止放宽 SafetyGate 硬安全级别', tone: ToastTone.warn);
        return;
      }
      await refreshNativeStatus();
    }
    state = state.copyWith(safetyPolicy: policy);
    _persistPrefs();
    final label = switch (policy) {
      'always' => '始终免确认（保留硬拦截）',
      'allow_turn' => '本轮允许',
      _ => '每次询问',
    };
    showToast('SafetyGate 策略：$label');
  }

  @visibleForTesting
  static String? extractJobEventStatus(Map<String, dynamic> data) {
    String? pick(Object? raw) {
      if (raw is! String) return null;
      final t = raw.trim();
      return t.isEmpty ? null : t;
    }

    String? fromMap(Object? obj) {
      if (obj is! Map) return null;
      return pick(obj['status']) ??
          pick(obj['state']) ??
          fromMap(obj['job']) ??
          fromMap(obj['info']) ??
          fromMap(obj['data']);
    }

    return pick(data['status']) ??
        pick(data['state']) ??
        fromMap(data['job']) ??
        fromMap(data['raw']) ??
        fromMap(data['info']);
  }

  @visibleForTesting
  static bool isTerminalJobStatus(String? status) {
    final s = status?.trim().toLowerCase() ?? '';
    return s == 'completed' ||
        s == 'done' ||
        s == 'finished' ||
        s == 'success' ||
        s == 'succeeded' ||
        s == 'failed' ||
        s == 'error' ||
        s == 'killed' ||
        s == 'exited' ||
        s == 'stopped' ||
        s == 'cancelled' ||
        s == 'canceled' ||
        s == 'aborted';
  }

  static List<String> _extractEmergencyStopSessionIds(Map<String, dynamic> data) {
    final out = <String>{};
    final list = data['sessionIds'];
    if (list is List) {
      for (final item in list) {
        final s = item?.toString().trim() ?? '';
        if (s.isNotEmpty) out.add(s);
      }
    }
    final single = data['sessionId']?.toString().trim() ?? '';
    if (single.isNotEmpty) out.add(single);
    return out.toList(growable: false);
  }

  /// Cancels ONLY the exact local session(s) that were controlling the phone when emergency stop
  /// fired, never cancelling an unrelated session or remote host the user switched to mid-run.
  void _cancelSpecificLocalSessions(
    List<String> targetSessionIds, {
    required bool announce,
    bool allowActiveLocalFallback = false,
  }) {
    final unique = <String>{
      for (final s in targetSessionIds)
        if (s.trim().isNotEmpty) s.trim(),
    };
    if (!state.activeHost.isLocal) {
      // Native RuntimeController already cancels local DSH sessions directly over UDS;
      // NEVER touch the currently selected remote host's active chat!
      return;
    }
    final activeSid = state.activeSessionId;
    if (unique.isEmpty) {
      if (allowActiveLocalFallback && activeSid != null) {
        cancelStreaming(announce: announce);
      }
      return;
    }
    if (activeSid != null && unique.contains(activeSid)) {
      cancelStreaming(announce: announce);
    }
    final client = _liveClient;
    if (client != null) {
      for (final sid in unique) {
        if (sid == activeSid || sid.startsWith('pending-session-')) continue;
        unawaited(
          client.cancelSession(sid).timeout(const Duration(seconds: 3)).catchError((_) => <String, dynamic>{}),
        );
      }
    }
  }

  Future<void> triggerEmergencyStop({bool cancelChatIfIdle = false}) async {
    final wasPhoneActive = state.phoneLiveActive;
    final trackedPhoneSid = _activePhoneSessionId;
    final nativeStoppedIds = await GrassBagNativeBridge.instance.triggerEmergencyStop();
    _activePhoneSessionId = null;
    state = state.copyWith(
      emergencyStopped: true,
      phoneLiveActive: false,
      phoneLivePaused: false,
      phoneHandoffReason: '',
      phoneLiveAction: '',
      phoneLiveApp: '',
      phoneLiveSteps: 0,
    );
    final combinedTargetIds = <String>[
      ...nativeStoppedIds,
      if (nativeStoppedIds.isEmpty && trackedPhoneSid != null && trackedPhoneSid.isNotEmpty)
        trackedPhoneSid,
    ];
    if (combinedTargetIds.isNotEmpty) {
      _cancelSpecificLocalSessions(combinedTargetIds, announce: false);
    } else if (cancelChatIfIdle && state.activeHost.isLocal) {
      cancelStreaming(announce: false);
    } else if (wasPhoneActive && state.activeHost.isLocal && !GrassBagNativeBridge.instance.isAndroidNative) {
      cancelStreaming(announce: false);
    }
    await refreshNativeStatus();
    showToast(
      wasPhoneActive || combinedTargetIds.isNotEmpty
          ? '已触发紧急急停，对应手机操控任务已立即中止'
          : '已开启手机操控急停锁定（所有屏幕自动化已拦截）',
      tone: ToastTone.warn,
    );
  }

  Future<void> resetEmergencyStop() async {
    await GrassBagNativeBridge.instance.resetEmergencyStop();
    state = state.copyWith(emergencyStopped: false);
    await refreshNativeStatus();
    showToast('已解除急停锁，恢复正常控制能力');
  }

  void setEngineFlags({bool? autoFold, bool? proxy}) {
    state = state.copyWith(autoFoldSteps: autoFold, useSystemProxy: proxy);
    _persistPrefs();
    if (proxy != null && GrassBagNativeBridge.instance.isAndroidNative) {
      unawaited(GrassBagNativeBridge.instance.setSystemProxy(proxy));
      showToast(
        proxy ? '已开启本机容器系统代理转发，重启引擎或新开终端后生效' : '已关闭系统代理转发',
        tone: ToastTone.info,
      );
    }
  }

  void _scheduleLiveDomainsRefresh() {
    _domainRefreshTimer?.cancel();
    _domainRefreshTimer = Timer(const Duration(milliseconds: 500), () {
      _domainRefreshTimer = null;
      final client = _liveClient;
      if (!mounted || client == null) return;
      unawaited(_hydrateLiveDomains(client));
    });
  }

  void _scheduleHostSessionsRefresh() {
    _hostSessionsRefreshTimer?.cancel();
    _hostSessionsRefreshTimer = Timer(const Duration(milliseconds: 650), () {
      _hostSessionsRefreshTimer = null;
      if (!mounted || _liveClient == null) return;
      // Avoid racing with an active `POST /sessions` call; retry once it settles.
      if (state.isCreatingSession) {
        _scheduleHostSessionsRefresh();
        return;
      }
      unawaited(refreshSessionsList(silent: true));
    });
  }

  /// Allows unit/widget tests to inject a deterministic GitHub Releases fetcher.
  void configureAppUpdateServiceForTest(AppUpdateService service) {
    _appUpdateService = service;
  }

  Future<void> _loadInstalledAppVersion() async {
    final pkg = await GrassBagNativeBridge.instance.getAppVersion();
    if (!mounted) return;
    if (pkg != null) {
      state = state.copyWith(
        appVersion: pkg.versionName,
        appBuildNumber: pkg.buildNumber,
      );
    }
    _scheduleSilentAppUpdateCheck();
  }

  void _scheduleSilentAppUpdateCheck() {
    if (disableAutoAppUpdateCheck) return;
    // In headless Flutter tests (`!kIsWeb` without Android native), avoid firing live GitHub API calls.
    if (!GrassBagNativeBridge.instance.isAndroidNative && !kIsWeb) return;
    final last = state.lastAppUpdateCheckedAt;
    if (last != null && DateTime.now().difference(last) < kAppUpdateAutoCheckCooldown) {
      return;
    }
    _appUpdateTimer?.cancel();
    _appUpdateTimer = Timer(const Duration(milliseconds: 3600), () {
      _appUpdateTimer = null;
      if (!mounted) return;
      unawaited(checkForAppUpdate(manual: false));
    });
  }

  Future<AppReleaseCheckResult> checkForAppUpdate({bool manual = true}) async {
    if (state.checkingAppUpdate) {
      return AppReleaseCheckResult(release: state.appUpdateInfo, error: state.appUpdateError);
    }
    state = state.copyWith(
      checkingAppUpdate: true,
      clearAppUpdateError: true,
    );
    final customMirror = state.nativeRuntimeStatus.customRuntimeMirrorUrl;
    final res = await _appUpdateService.fetchLatestRelease(
      customMirrorUrl: customMirror.isNotEmpty ? customMirror : null,
    );
    if (!mounted) return res;

    final now = DateTime.now();
    if (!res.ok) {
      state = state.copyWith(
        checkingAppUpdate: false,
        appUpdateError: res.error,
        lastAppUpdateCheckedAt: now,
      );
      if (manual) {
        showToast(res.error ?? '检查更新失败', tone: ToastTone.warn);
      }
      return res;
    }

    if (res.noReleasePublished || res.release == null) {
      state = state.copyWith(
        checkingAppUpdate: false,
        clearAppUpdateInfo: true,
        clearAppUpdateError: true,
        lastAppUpdateCheckedAt: now,
      );
      _persistPrefs();
      if (manual) {
        showToast('当前已是最新版本（v${state.appVersionLabel}）', tone: ToastTone.info);
      }
      return res;
    }

    final release = res.release!;
    final isNewer = isRemoteReleaseNewer(
      currentVersion: state.appVersion,
      currentBuild: state.appBuildNumber,
      remote: release,
    );
    final versionChanged = state.appUpdateInfo?.versionKey != release.versionKey;
    state = state.copyWith(
      checkingAppUpdate: false,
      appUpdateInfo: release,
      clearAppUpdateError: true,
      lastAppUpdateCheckedAt: now,
      appUpdateBannerDismissed: versionChanged ? false : state.appUpdateBannerDismissed,
      clearAppUpdateLocalApkPath: versionChanged,
    );
    _persistPrefs();

    if (manual) {
      if (isNewer) {
        showToast('发现新版本 v${release.versionLabel}', tone: ToastTone.ok);
      } else {
        showToast('当前已是最新版本（v${state.appVersionLabel}）', tone: ToastTone.ok);
      }
    }
    return res;
  }

  void skipAppUpdateVersion(String versionKey) {
    final clean = versionKey.trim();
    if (clean.isEmpty) return;
    state = state.copyWith(
      skippedAppUpdateVersion: clean,
      appUpdateBannerDismissed: true,
    );
    _persistPrefs();
    showToast('已跳过版本 $clean，后续有更高版本时会再次提醒', tone: ToastTone.info);
  }

  void dismissAppUpdateBanner() {
    if (!state.appUpdateBannerDismissed) {
      state = state.copyWith(appUpdateBannerDismissed: true);
    }
  }

  void cancelAppUpdateDownload() {
    if (state.appUpdateDownloading) {
      _appUpdateDownloadCancelled = true;
      final abort = _appUpdateDownloadAbort;
      _appUpdateDownloadAbort = null;
      abort?.call();
    }
  }

  Future<void> openAppReleasePage() async {
    final url = state.appUpdateInfo?.htmlUrl ?? kGrassBagReleasesWebUrl;
    await _openExternalLink(url);
  }

  Future<void> openGitHubRepoPage() async {
    await _openExternalLink(kGrassBagRepoWebUrl);
  }

  Future<void> _openExternalLink(String url) async {
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      final ok = await GrassBagNativeBridge.instance.openExternalUrl(url);
      if (!ok) {
        showToast('无法拉起外部浏览器，请手动访问 $url', tone: ToastTone.warn);
      }
    } else {
      openUrlInNewTab(url);
    }
  }

  Future<void> downloadAndInstallAppUpdate({bool forceRedownload = false}) async {
    final release = state.appUpdateInfo;
    if (release == null) {
      showToast('请先检查新版本', tone: ToastTone.info);
      return;
    }
    final downloadUrl = release.apkDownloadUrl;
    if (downloadUrl == null || downloadUrl.isEmpty) {
      await openAppReleasePage();
      return;
    }

    final customMirror = state.nativeRuntimeStatus.customRuntimeMirrorUrl;
    final candidates = buildAppUpdateDownloadCandidateUris(
      downloadUrl,
      customMirrorUrl: customMirror.isNotEmpty ? customMirror : null,
    );
    if (candidates.isEmpty) {
      await openAppReleasePage();
      return;
    }
    final preferredBrowserUrl = candidates.first.toString();
    final safeKey = release.versionKey.replaceAll(RegExp(r'[^0-9A-Za-z._-]+'), '_');

    // Web or non-Android hosts open the China-mirror accelerated APK download in browser.
    if (!GrassBagNativeBridge.instance.isAndroidNative) {
      await _openExternalLink(preferredBrowserUrl);
      return;
    }

    String? expectedSha256;
    try {
      expectedSha256 = await _appUpdateService.resolveExpectedApkSha256(
        release,
        customMirrorUrl: customMirror.isNotEmpty ? customMirror : null,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(appUpdateError: '获取发布校验信息失败：$e');
      showToast('无法校验安装包 SHA-256 摘要，已中止自动安装', tone: ToastTone.warn);
      return;
    }
    if (!mounted) return;

    if (state.appUpdateDownloading || _startingAppUpdateDownload) return;
    _startingAppUpdateDownload = true;
    String? updatesDir;
    try {
      // Reuse already-downloaded APK ONLY when it matches the exact target release versionKey
      // AND passes native SHA-256 + packageName + signing certificate verification!
      if (forceRedownload && state.appUpdateLocalApkPath != null) {
        state = state.copyWith(clearAppUpdateLocalApkPath: true);
      }
      final existingPath = state.appUpdateLocalApkPath;
      if (!forceRedownload &&
          existingPath != null &&
          existingPath.isNotEmpty &&
          existingPath.endsWith('grassbag-$safeKey.apk')) {
        final installRes = await GrassBagNativeBridge.instance.installApk(
          existingPath,
          expectedSha256: expectedSha256,
        );
        if (!mounted) return;
        if (installRes == 'started') {
          showToast('已通过完整性与签名校验，正在拉起系统安装器', tone: ToastTone.ok);
          return;
        }
        if (installRes == 'permission_required') {
          showToast('请先开启「允许安装未知来源应用」，返回后点击立即安装', tone: ToastTone.warn);
          return;
        }
        // File evicted or failed integrity/signature check: clear cache and re-download cleanly.
        state = state.copyWith(clearAppUpdateLocalApkPath: true);
      }
      updatesDir = await GrassBagNativeBridge.instance.getUpdatesCacheDir();
      if (!mounted) return;
      if (updatesDir == null || updatesDir.isEmpty) {
        await _openExternalLink(preferredBrowserUrl);
        return;
      }
    } finally {
      _startingAppUpdateDownload = false;
    }

    final destPath = '$updatesDir/grassbag-$safeKey.apk';
    _appUpdateDownloadCancelled = false;
    _appUpdateDownloadAbort = null;
    _lastDownloadProgressEmit = null;
    state = state.copyWith(
      appUpdateDownloading: true,
      appUpdateDownloadProgress: 0.0,
      appUpdateDownloadBytes: 0,
      appUpdateTotalBytes: release.apkSizeBytes ?? 0,
      appUpdateDownloadSource: '国内镜像 1',
      clearAppUpdateError: true,
    );

    try {
      final savedPath = await _appUpdateService.downloadApk(
        downloadUrl: downloadUrl,
        destinationPath: destPath,
        expectedSizeBytes: release.apkSizeBytes,
        expectedSha256: expectedSha256,
        customMirrorUrl: customMirror.isNotEmpty ? customMirror : null,
        onSourceChanged: (sourceLabel) {
          if (!mounted) return;
          if (state.appUpdateDownloadSource != sourceLabel) {
            state = state.copyWith(appUpdateDownloadSource: sourceLabel);
          }
        },
        onAbortReady: (abort) => _appUpdateDownloadAbort = abort,
        isCancelled: () => _appUpdateDownloadCancelled || !mounted,
        onProgress: (received, total) {
          if (!mounted) return;
          final now = DateTime.now();
          final last = _lastDownloadProgressEmit;
          if (last != null &&
              now.difference(last) < const Duration(milliseconds: 120) &&
              (total <= 0 || received < total)) {
            return;
          }
          _lastDownloadProgressEmit = now;
          final effectiveTotal = total > 0 ? total : (release.apkSizeBytes ?? -1);
          final progress = effectiveTotal > 0
              ? (received / effectiveTotal).clamp(0.0, 1.0)
              : -1.0;
          state = state.copyWith(
            appUpdateDownloadProgress: progress,
            appUpdateDownloadBytes: received,
            appUpdateTotalBytes: effectiveTotal > 0 ? effectiveTotal : 0,
          );
        },
      );
      _appUpdateDownloadAbort = null;
      if (!mounted) return;
      final stillMatchesLatest = state.appUpdateInfo == null ||
          state.appUpdateInfo!.versionKey == release.versionKey;
      state = state.copyWith(
        appUpdateDownloading: false,
        appUpdateDownloadProgress: 1.0,
        appUpdateDownloadSource: '',
        appUpdateLocalApkPath: stillMatchesLatest ? savedPath : null,
        clearAppUpdateLocalApkPath: !stillMatchesLatest,
      );
      final installRes = await GrassBagNativeBridge.instance.installApk(
        savedPath,
        expectedSha256: expectedSha256,
      );
      if (!mounted) return;
      if (installRes == 'started') {
        showToast('安装包已通过校验，正在拉起系统安装器', tone: ToastTone.ok);
      } else if (installRes == 'permission_required') {
        showToast('已跳转系统授权页：请允许 GrassBag 安装应用后返回继续安装', tone: ToastTone.warn);
      } else if (installRes == 'error:sha256_mismatch' ||
          installRes == 'error:package_name_mismatch' ||
          installRes == 'error:signature_mismatch' ||
          installRes == 'error:invalid_apk_archive') {
        state = state.copyWith(
          clearAppUpdateLocalApkPath: true,
          appUpdateError: '安装包安全校验失败（$installRes），已拒绝安装并删除异常文件',
        );
        final msg = switch (installRes) {
          'error:sha256_mismatch' => '安装包 SHA-256 校验失败，已删除异常文件',
          'error:package_name_mismatch' => '安装包应用包名不匹配，已拒绝安装',
          'error:signature_mismatch' => '安装包签名与当前正式版不一致，无法安全覆盖升级',
          _ => '安装包结构损坏，已删除，请重新下载',
        };
        showToast(msg, tone: ToastTone.warn);
      } else {
        showToast('拉起安装器失败，已为你保留安装包，可尝试重新下载或前往 Release 页面安装', tone: ToastTone.warn);
      }
    } on AppUpdateDownloadCancelledException {
      _appUpdateDownloadAbort = null;
      if (!mounted) return;
      state = state.copyWith(
        appUpdateDownloading: false,
        appUpdateDownloadSource: '',
        clearAppUpdateDownloadProgress: true,
      );
      showToast('已取消安装包下载', tone: ToastTone.info);
    } catch (e) {
      _appUpdateDownloadAbort = null;
      if (!mounted) return;
      state = state.copyWith(
        appUpdateDownloading: false,
        appUpdateDownloadSource: '',
        clearAppUpdateDownloadProgress: true,
        appUpdateError: 'APK 下载失败：$e',
      );
      showToast('下载失败，可点击「前往 Release」改用浏览器下载', tone: ToastTone.warn);
    }
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _streamCoalesceTimer?.cancel();
    _streamWatchdogTimer?.cancel();
    _reconnectStreamCheckTimer?.cancel();
    _jobOutputFlushTimer?.cancel();
    _engineLogFlushTimer?.cancel();
    _hostSessionsRefreshTimer?.cancel();
    _domainRefreshTimer?.cancel();
    _domainRetryTimer?.cancel();
    _reconnectGraceTimer?.cancel();
    _drawerSearchTimer?.cancel();
    _accountPollTimer?.cancel();
    // Flush pending debounced persistence writes BEFORE cancelling timers on dispose!
    if (_persistPrefsTimer != null) _persistPrefs(immediate: true);
    if (_persistHostsTimer != null) _persistHosts(immediate: true);
    if (_persistHostContextsTimer != null) _persistHostContexts(immediate: true);
    _persistPrefsTimer?.cancel();
    _persistHostsTimer?.cancel();
    _persistHostContextsTimer?.cancel();
    _offlineHistorySaveTimer?.cancel();
    for (final t in _sessionStreamRetryTimers.values) {
      t.cancel();
    }
    _sessionStreamRetryTimers.clear();
    for (final t in _jobStreamRetryTimers.values) {
      t.cancel();
    }
    _jobStreamRetryTimers.clear();
    _sessionAttachmentsMemory.clear();
    _attachmentDownloadCache.clear();
    _attachmentDownloadCacheBytes = 0;
    _inFlightAttachmentDownloads.clear();
    _appUpdateTimer?.cancel();
    _keepaliveRenewTimer?.cancel();
    _keepaliveRenewTimer = null;
    _appUpdateDownloadCancelled = true;
    _appUpdateDownloadAbort?.call();
    _appUpdateDownloadAbort = null;
    final nativeSub = _nativeSub;
    _nativeSub = null;
    if (nativeSub != null) {
      unawaited(nativeSub.cancel().catchError((_) {}));
    }
    unawaited(_disconnectLiveClients());
    super.dispose();
  }
}

String _encodeBase64Isolate(Uint8List bytes) => base64Encode(bytes);
Uint8List _decodeBase64Isolate(String raw) => base64Decode(base64.normalize(raw));

final appProvider = StateNotifierProvider<GrassBagController, GrassBagAppState>(
  (ref) => GrassBagController(),
);
