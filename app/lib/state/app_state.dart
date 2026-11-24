import 'dart:async';
import 'dart:convert';

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

enum ToastTone { ok, warn, info }

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

enum RemoteDiagnosisKind {
  readyGbridge,
  readyDirect,
  needsAuth,
  htmlLoginPage,
  untrustedHost,
  selfSignedTls,
  selfDevice,
  unreachable,
  invalidAddress,
}

@immutable
class RemoteHostDiagnosis {
  const RemoteHostDiagnosis({
    required this.kind,
    required this.title,
    required this.message,
    this.normalizedAddress,
    this.extractedToken,
    this.dshVersion,
    this.latencyMs,
    this.hostAuthority,
    this.hasGbridge = false,
    this.suggestedCommand,
  });

  final RemoteDiagnosisKind kind;
  final String title;
  final String message;
  final String? normalizedAddress;
  final String? extractedToken;
  final String? dshVersion;
  final int? latencyMs;
  final String? hostAuthority;
  final bool hasGbridge;
  final String? suggestedCommand;

  bool get canConnectNow =>
      kind == RemoteDiagnosisKind.readyGbridge || kind == RemoteDiagnosisKind.readyDirect;
  bool get needsWebOrTokenAuth =>
      kind == RemoteDiagnosisKind.needsAuth || kind == RemoteDiagnosisKind.htmlLoginPage;
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
    return ManagedHost(
      id: m['id']?.toString() ?? 'rem',
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
  '生成中点击「补充」，可以插话、排队或立刻打断',
  '输入 @ 可快速引用工作区文件，输入 / 唤起快捷指令',
  '点击顶部标题可随时查看 6 栏工作台：文件、改动、终端、进度、轨迹与子代理',
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
    this.activeSessionId,
    this.turns = const [],
    this.loadingSession = false,
    this.isStreaming = false,
    this.pendingApprovalCommand,
    this.pendingApprovalInteractionId,
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
    this.connectionPhase = ConnectionPhase.disconnected,
    this.discoveredLanHosts = const [],
    this.scanningLan = false,
    this.toast,
    this.liveCapabilities,
    this.scrollSignal = 0,
    this.sessionJumpSignal = 0,
    this.streamTick = 0,
    this.newChatSignal = 0,
    this.focusComposerSignal = 0,
    this.draftHydratedSignal = 0,
  });

  final bool isDark;
  final GrassBagAccent accent;
  final GrassBagGlassTier glassTier;
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
  final String? activeSessionId;
  final List<NormalizedTurn> turns;
  final bool loadingSession;
  final bool isStreaming;
  final String? pendingApprovalCommand;
  final String? pendingApprovalInteractionId;
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
  final ConnectionPhase connectionPhase;
  final List<DiscoveredLanHost> discoveredLanHosts;
  final bool scanningLan;
  final GrassBagToastMessage? toast;
  final Capabilities? liveCapabilities;
  final int scrollSignal;
  final int sessionJumpSignal;
  final int streamTick;
  final int newChatSignal;
  final int focusComposerSignal;
  final int draftHydratedSignal;

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
    for (final w in workspaces) {
      if (w.name == activeWorkspace || w.path == activeWorkspace || w.id == activeWorkspace) {
        return w;
      }
    }
    return workspaces.isNotEmpty ? workspaces.first : null;
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

  bool get isEmptyChat =>
      activeSessionId == null || (turns.isEmpty && !loadingSession && sessionLoadError == null);

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

  String hostStatusLabel(ManagedHost host) {
    if (host.isLocal && !kIsWeb && GrassBagNativeBridge.instance.isAndroidNative) {
      final rt = nativeRuntimeStatus;
      if (runtimeProgressPct > 0 && runtimeProgressPct < 100) {
        return '正在部署容器 $runtimeProgressPct%…';
      }
      if (!rt.initialized) return '容器未初始化 · 待部署';
      if (rt.engineState == 'starting') return '正在启动本机 DSH 引擎…';
      if (rt.engineState == 'error') return '启动异常 · 点击查看日志';
      if (rt.engineRunning && host.bridged) return 'DSH ${host.dshVersion} · 运行中';
      if (rt.engineRunning) return '引擎已就绪 · 正在接入…';
      return '容器已就绪 · 待启动';
    }
    if (host.isLocal) {
      if (host.bridged) return 'DSH ${host.dshVersion} · 运行中';
      if (connectionPhase == ConnectionPhase.connecting) return '正在连接本机 DSH…';
      if (host.lastError != null && host.lastError!.isNotEmpty) return '未连接 · 点击检查服务';
      return '等待连接本机 DSH';
    }
    if (host.bridged) return '${host.latency} · 增强模式';
    if (host.directMode && host.online) return '${host.latency} · 原生直连 (免插件)';
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
      if (runtimeProgressPct > 0 && runtimeProgressPct < 100) return '部署中 $runtimeProgressPct%';
      if (!rt.initialized) return '未初始化';
      if (rt.engineState == 'starting') return '启动中';
      if (rt.engineState == 'error') return '启动异常';
      if (rt.engineRunning) return host.bridged ? '运行中' : '接入中';
      return '待启动';
    }
    if (host.isLocal) {
      return host.bridged ? '运行中' : (connectionPhase == ConnectionPhase.connecting ? '连接中' : '未连接');
    }
    if (host.bridged) return '增强模式';
    if (host.directMode && host.online) return '原生直连';
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
    String? activeSessionId,
    bool clearActiveSession = false,
    List<NormalizedTurn>? turns,
    bool? loadingSession,
    bool? isStreaming,
    String? pendingApprovalCommand,
    String? pendingApprovalInteractionId,
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
    ConnectionPhase? connectionPhase,
    List<DiscoveredLanHost>? discoveredLanHosts,
    bool? scanningLan,
    GrassBagToastMessage? toast,
    bool clearToast = false,
    Capabilities? liveCapabilities,
    bool clearLiveCapabilities = false,
    int? scrollSignal,
    int? sessionJumpSignal,
    int? streamTick,
    int? newChatSignal,
    int? focusComposerSignal,
    int? draftHydratedSignal,
  }) {
    return GrassBagAppState(
      isDark: isDark ?? this.isDark,
      accent: accent ?? this.accent,
      glassTier: glassTier ?? this.glassTier,
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
      activeSessionId: clearActiveSession ? null : (activeSessionId ?? this.activeSessionId),
      turns: turns ?? this.turns,
      loadingSession: loadingSession ?? this.loadingSession,
      isStreaming: isStreaming ?? this.isStreaming,
      pendingApprovalCommand: clearPendingApproval
          ? null
          : (pendingApprovalCommand ?? this.pendingApprovalCommand),
      pendingApprovalInteractionId: clearPendingApproval
          ? null
          : (pendingApprovalInteractionId ?? this.pendingApprovalInteractionId),
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
      connectionPhase: connectionPhase ?? this.connectionPhase,
      discoveredLanHosts: discoveredLanHosts ?? this.discoveredLanHosts,
      scanningLan: scanningLan ?? this.scanningLan,
      toast: clearToast ? null : (toast ?? this.toast),
      liveCapabilities:
          clearLiveCapabilities ? null : (liveCapabilities ?? this.liveCapabilities),
      scrollSignal: scrollSignal ?? this.scrollSignal,
      sessionJumpSignal: sessionJumpSignal ?? this.sessionJumpSignal,
      streamTick: streamTick ?? this.streamTick,
      newChatSignal: newChatSignal ?? this.newChatSignal,
      focusComposerSignal: focusComposerSignal ?? this.focusComposerSignal,
      draftHydratedSignal: draftHydratedSignal ?? this.draftHydratedSignal,
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

  Timer? _toastTimer;
  Timer? _streamCoalesceTimer;
  Timer? _jobOutputFlushTimer;
  Timer? _engineLogFlushTimer;
  Timer? _hostSessionsRefreshTimer;
  Timer? _domainRefreshTimer;
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
  final Set<String> _pendingResyncSessionIds = <String>{};
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
  bool _pendingStreamReduced = false;
  bool _pendingStreamTelemetryChanged = false;
  DateTime? _lastLiveTpsEmitAt;
  int _toastSeq = 0;
  int _streamRunId = 0;
  int _hostConnectGen = 0;
  int _modelSelectionGen = 0;
  String? _lastAutoSyncedDefaultKey;
  int _marketSearchSeq = 0;
  int _wsDirSeq = 0;
  int _autoStartRequestedGen = -1;
  bool _isSendingPrompt = false;
  int _sendingPromptGen = -1;
  bool _bootstrappingLocal = false;
  bool _connectingLocalAndroid = false;
  bool _hadInitialWelcome = false;
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
  final Map<String, Map<String, dynamic>> _toolDetailCache = {};
  final Map<String, PendingInteraction> _pendingInteractionsById = {};
  final Set<String> _locallyCancelledTurnIds = {};
  int _cancelSuppressUntilMs = 0;
  Set<String> _deviceLocalIps = const {'127.0.0.1', '::1', '0.0.0.0'};
  DateTime? _lastBackgroundedAt;
  Future<void>? _inFlightPermissionsRefresh;
  Future<void>? _inFlightNativeStatus;

  static const int _maxCachedSessionsTurns = 10;
  static const int _maxToolCacheEntries = 50;

  void _cacheSessionTurns(String sessionId, List<NormalizedTurn> turns) {
    if (sessionId.isEmpty) return;
    // Touch key so LinkedHashMap maintains true LRU eviction order.
    _sessionTurnsMemory.remove(sessionId);
    _sessionTurnsMemory[sessionId] = turns;
    while (_sessionTurnsMemory.length > _maxCachedSessionsTurns) {
      _sessionTurnsMemory.remove(_sessionTurnsMemory.keys.first);
    }
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
      return '127.0.0.1 / localhost 仅代表设备自身，手机无法通过回环地址访问电脑；请改填电脑的局域网 IP（如 192.168.x.x）或按下方桌面端引导开启远程连接。';
    }
    return '该地址指向当前设备本机，无需添加为远程主机；请直接切换到「本机」使用内置环境。';
  }

  /// True only while the given [client] is still the currently bound live host client.
  bool _isStillLive(GbridgeClient client, {int? gen}) =>
      mounted && identical(_liveClient, client) && (gen == null || gen == _hostConnectGen);

  String _draftScopeKey() => state.activeSessionId ?? '__new__';

  /// Retrieve persisted composer draft text scoped to the active host AND active session.
  String getComposerDraftForActiveHost() {
    final hostEntry = _hostContexts[state.activeHostId];
    if (hostEntry == null) return '';
    final scope = _draftScopeKey();
    final map = hostEntry['sessionDrafts'];
    if (map is Map && map.containsKey(scope)) {
      return map[scope]?.toString() ?? '';
    }
    if (scope == '__new__') {
      return hostEntry['composerDraft']?.toString() ?? '';
    }
    return '';
  }

  /// Update persisted composer draft text scoped strictly to the active host AND active session.
  /// Mutates host context maps in-place to avoid deep-cloning Maps during typing.
  void setComposerDraftForActiveHost(String text) {
    final hostId = state.activeHostId;
    final scope = _draftScopeKey();
    final entry = _hostContexts.putIfAbsent(hostId, () => <String, dynamic>{});
    final existingDrafts = entry['sessionDrafts'];
    final Map<String, dynamic> drafts;
    if (existingDrafts is Map<String, dynamic>) {
      drafts = existingDrafts;
    } else if (existingDrafts is Map) {
      drafts = Map<String, dynamic>.from(existingDrafts);
      entry['sessionDrafts'] = drafts;
    } else {
      drafts = <String, dynamic>{};
    }
    if ((drafts[scope]?.toString() ?? '') == text) return;
    if (text.isEmpty) {
      drafts.remove(scope);
      if (scope == '__new__') entry.remove('composerDraft');
    } else {
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
    _persistHostContexts();
  }

  void _saveCurrentHostContext({String? hostIdOverride}) {
    final hostId = hostIdOverride ?? state.activeHostId;
    final entry = _hostContexts.putIfAbsent(hostId, () => <String, dynamic>{});
    final sid = state.activeSessionId;
    if (sid != null && sid.isNotEmpty && !sid.startsWith('pending-session-')) {
      entry['lastSessionId'] = sid;
    } else if (sid == null) {
      entry.remove('lastSessionId');
    }
    if (state.activeWorkspace.isNotEmpty) {
      entry['lastWorkspace'] = state.activeWorkspace;
    }
    final wsFilter = state.sidebarWorkspaceFilter;
    if (wsFilter != null && wsFilter.isNotEmpty) {
      entry['sidebarWorkspaceFilter'] = wsFilter;
    } else {
      entry.remove('sidebarWorkspaceFilter');
    }
    _persistHostContexts();
  }

  void _flushHostContextsNow() {
    if (_persistHostContextsTimer == null) return;
    _persistHostContextsTimer?.cancel();
    _persistHostContextsTimer = null;
    if (!mounted) return;
    unawaited(GrassBagStorage.instance.saveHostContexts(_hostContexts));
  }

  void _persistHostContexts() {
    _persistHostContextsTimer?.cancel();
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
    final initialDark = p?['isDark'] is bool ? p!['isDark'] as bool : false;
    final initialAccent = GrassBagAccent.values.firstWhere(
      (a) => a.name == p?['accent']?.toString(),
      orElse: () => GrassBagAccent.moss,
    );
    final initialTier = GrassBagGlassTier.values.firstWhere(
      (g) => g.name == p?['glassTier']?.toString(),
      orElse: () => GrassBagGlassTier.liquid,
    );
    final initialOnboarding =
        p?['onboardingCompleted'] is bool ? p!['onboardingCompleted'] as bool : false;

    return GrassBagAppState(
      isDark: initialDark,
      accent: initialAccent,
      glassTier: initialTier,
      onboardingCompleted: initialOnboarding,
      hosts: [
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
      ],
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
    final storage = GrassBagStorage.instance;
    final loaded = await Future.wait<Object?>([
      preloadedInitialPrefs != null ? Future.value(preloadedInitialPrefs) : storage.loadPrefs(),
      storage.loadSavedHosts(),
      storage.loadHostContexts(),
    ]);
    final prefs = loaded[0] as Map<String, dynamic>?;
    final savedHosts = loaded[1] as List<Map<String, dynamic>>?;
    final savedContexts = loaded[2] as Map<String, Map<String, dynamic>>?;
    if (!mounted) return;
    if (savedContexts != null && savedContexts.isNotEmpty) {
      for (final entry in savedContexts.entries) {
        _hostContexts.putIfAbsent(entry.key, () => Map<String, dynamic>.from(entry.value));
      }
    }

    List<ManagedHost>? restoredHosts;
    String? restoredActiveHostId;
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      await _refreshDeviceLocalIps();
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
      // Never clobber a host the user already switched to (or newly added) while storage was loading!
      final mergedHosts = restoredHosts == null
          ? state.hosts
          : [
              ...restoredHosts,
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
      try {
        _nativeSub = native.events.listen((evt) {
          if (!mounted) return;
          if (evt.type == 'runtime_progress') {
            final nextPct = (evt.data['percent'] as num?)?.toInt() ?? 0;
            final nextMsg = evt.data['message']?.toString() ?? '';
            if (nextPct != state.runtimeProgressPct || nextMsg != state.runtimeProgressMsg) {
              state = state.copyWith(
                runtimeProgressPct: nextPct,
                runtimeProgressMsg: nextMsg,
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
            if (live != null && !state.activeHost.isLocal) {
              live.resetConnectionPool();
              if (!state.activeHost.needsAuth) {
                unawaited(live.stream.checkLiveness().catchError((_) => false));
              }
            }
          } else if (evt.type == 'engine_web_url') {
            unawaited(refreshNativeStatus(skipAutoConnect: true));
          } else if (evt.type == 'engine_ready') {
            final sock = evt.data['bridgeSocketPath']?.toString() ?? '';
            final httpUrl = evt.data['bridgeHttpUrl']?.toString() ?? 'http://127.0.0.1:13080';
            final token = evt.data['bridgeToken']?.toString() ?? '';
            unawaited(refreshNativeStatus(skipAutoConnect: true));
            if (state.activeHost.isLocal && token.isNotEmpty) {
              unawaited(_connectLocalAndroidEngine(sock, httpUrl, token, gen: _hostConnectGen));
            }
          } else if (evt.type == 'phone_handoff') {
            showToast(evt.data['message']?.toString() ?? '已交还人工操作', tone: ToastTone.warn);
          }
        });
      } catch (_) {
        // Headless unit test without initialized ServicesBinding
      }
      if (userSwitchedDuringHydrate) {
        unawaited(refreshNativeStatus(skipAutoConnect: true));
        return;
      }
      final bootGen = _hostConnectGen;
      if (state.activeHost.isLocal) {
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

  /// Fast, non-blocking refresh of Android permission & SafetyGate status ONLY.
  /// Never waits for container/runtime I/O and is never cancelled by host-switch generations,
  /// guaranteeing Accessibility / Overlay / Storage toggles reflect instantaneously on return!
  Future<void> refreshPermissionsOnly() {
    final native = GrassBagNativeBridge.instance;
    if (!native.isAndroidNative) return Future<void>.value();
    final existing = _inFlightPermissionsRefresh;
    if (existing != null) return existing;
    final fut = () async {
      final res = await Future.wait<Object?>([
        native.getPermissionsStatus(),
        native.getSafetyStatus(),
      ]);
      if (!mounted) return;
      final perms = res[0] as NativePermissionsStatus?;
      final safety = res[1] as Map<String, dynamic>?;
      if (perms == null && safety == null) return;
      final nextPerms = perms ?? state.nativePermissions;
      final nextAccess = perms?.accessibilityEnabled ?? state.phoneAccessibility;
      final nextOverlay = perms?.overlayGranted ?? state.phoneOverlay;
      final nextShizuku = perms?.shizukuInstalled ?? state.phoneShizuku;
      final nextConfirmRisk = safety?['confirmHighRisk'] is bool
          ? safety!['confirmHighRisk'] as bool
          : state.phoneConfirmHighRisk;
      final nextEmergency = safety?['emergencyStopped'] == true;
      final nextPolicy = safety?['policy']?.toString() ?? state.safetyPolicy;
      if (nextPerms != state.nativePermissions ||
          nextAccess != state.phoneAccessibility ||
          nextOverlay != state.phoneOverlay ||
          nextShizuku != state.phoneShizuku ||
          nextConfirmRisk != state.phoneConfirmHighRisk ||
          nextEmergency != state.emergencyStopped ||
          nextPolicy != state.safetyPolicy) {
        state = state.copyWith(
          nativePermissions: nextPerms,
          phoneAccessibility: nextAccess,
          phoneOverlay: nextOverlay,
          phoneShizuku: nextShizuku,
          phoneConfirmHighRisk: nextConfirmRisk,
          emergencyStopped: nextEmergency,
          safetyPolicy: nextPolicy,
        );
      }
    }();
    _inFlightPermissionsRefresh = fut;
    fut.whenComplete(() {
      if (identical(_inFlightPermissionsRefresh, fut)) {
        _inFlightPermissionsRefresh = null;
      }
    });
    return fut;
  }

  /// Records background entry timestamp and flushes any debounced host drafts before OS suspend.
  void handleAppPaused() {
    _lastBackgroundedAt = DateTime.now();
    _flushHostContextsNow();
  }

  /// Single app-wide foreground resume handler called from `GrassBagShell`.
  /// Re-reads Android runtime/permissions (e.g. returning from Accessibility/Battery/Overlay
  /// settings), probes WS liveness so frozen mobile sockets reconnect immediately, and
  /// skips redundant 10-RPC resyncs on brief (< 3s) pauses when the WS is still connected!
  Future<void> handleAppResumed() async {
    if (!mounted) return;
    final bgMs = _lastBackgroundedAt == null
        ? 999999
        : DateTime.now().difference(_lastBackgroundedAt!).inMilliseconds;
    _lastBackgroundedAt = null;
    // Allow automatic local-engine recovery if Android OOM-killed the container while backgrounded.
    _autoStartRequestedGen = -1;
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      // refreshNativeStatus already fetches runtime + permissions + safety in a single parallel batch!
      unawaited(refreshNativeStatus(connectGen: _hostConnectGen));
    }
    final client = _liveClient;
    if (client != null) {
      client.stream.checkLiveness();
      // Skip full 10-RPC session+bundle resync on short transient pauses (< 3s, e.g. notification
      // shade or quick system dialog) while WebSocket is live and connected!
      if (state.connectionPhase == ConnectionPhase.connected && bgMs >= 3000) {
        unawaited(refreshSessionsList(silent: true));
        final sid = state.activeSessionId;
        if (sid != null && !sid.startsWith('pending-session-')) {
          unawaited(_syncLiveSessionBundle(sid, jumpToBottomOnLoad: false));
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
    await refreshNativeStatus(skipAutoConnect: true);
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
    _persistPrefs();
  }

  /// Persist ONLY GrassBag app-level preferences.
  /// All DSH core settings (models, providers, presets, permissions, workspaces,
  /// schedules, goals, MCP, plugins) live exclusively in DSH and are never persisted here.
  void _persistPrefs() {
    _persistPrefsTimer?.cancel();
    _persistPrefsTimer = Timer(const Duration(milliseconds: 180), () {
      _persistPrefsTimer = null;
      if (!mounted) return;
      unawaited(
        GrassBagStorage.instance.savePrefs({
          'isDark': state.isDark,
          'accent': state.accent.name,
          'glassTier': state.glassTier.name,
          'autoFoldSteps': state.autoFoldSteps,
          'useSystemProxy': state.useSystemProxy,
          'safetyPolicy': state.safetyPolicy,
          'phoneConfirmHighRisk': state.phoneConfirmHighRisk,
          'onboardingCompleted': state.onboardingCompleted,
          'sessionGroupMode': state.sessionGroupMode.name,
          'activeHostId': state.activeHostId,
          if (state.skippedAppUpdateVersion != null && state.skippedAppUpdateVersion!.isNotEmpty)
            'skippedAppUpdateVersion': state.skippedAppUpdateVersion,
          if (state.lastAppUpdateCheckedAt != null)
            'lastAppUpdateCheckedAtMs': state.lastAppUpdateCheckedAt!.millisecondsSinceEpoch,
        }),
      );
    });
  }

  void _persistHosts() {
    _persistHostsTimer?.cancel();
    _persistHostsTimer = Timer(const Duration(milliseconds: 180), () {
      _persistHostsTimer = null;
      if (!mounted) return;
      unawaited(
        GrassBagStorage.instance.saveHosts(
          state.hosts.map((h) => h.toJson()).toList(growable: false),
        ),
      );
    });
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
    _pendingStreamReduced = false;
    _pendingStreamTelemetryChanged = false;
    _lastLiveTpsEmitAt = null;
  }

  Future<void> refreshNativeStatus({int? connectGen, bool skipAutoConnect = false}) {
    if (_inFlightNativeStatus != null && skipAutoConnect) {
      return _inFlightNativeStatus!;
    }
    final fut = _refreshNativeStatusImpl(
      connectGen: connectGen,
      skipAutoConnect: skipAutoConnect,
    );
    _inFlightNativeStatus = fut;
    fut.whenComplete(() {
      if (identical(_inFlightNativeStatus, fut)) {
        _inFlightNativeStatus = null;
      }
    });
    return fut;
  }

  Future<void> _refreshNativeStatusImpl({int? connectGen, bool skipAutoConnect = false}) async {
    final native = GrassBagNativeBridge.instance;
    final nativeRes = await Future.wait<Object?>([
      native.getRuntimeStatus(),
      native.getPermissionsStatus(),
      native.getSafetyStatus(),
    ]);
    final rt = nativeRes[0] as NativeRuntimeStatus?;
    final perms = nativeRes[1] as NativePermissionsStatus?;
    final safety = nativeRes[2] as Map<String, dynamic>?;
    if (!mounted) return;
    if (connectGen != null && connectGen != _hostConnectGen) return;

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

    final rawAudit = safety?['audit'];
    final auditList = rawAudit is List
        ? rawAudit
            .whereType<Map<Object?, Object?>>()
            .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
            .toList(growable: false)
        : state.safetyAudit;

    final nextRt = rt ?? state.nativeRuntimeStatus;
    final nextPerms = perms ?? state.nativePermissions;
    final nextAccess = perms?.accessibilityEnabled ?? state.phoneAccessibility;
    final nextOverlay = perms?.overlayGranted ?? state.phoneOverlay;
    final nextShizuku = perms?.shizukuInstalled ?? state.phoneShizuku;
    final nextConfirmRisk = safety?['confirmHighRisk'] is bool
        ? safety!['confirmHighRisk'] as bool
        : state.phoneConfirmHighRisk;
    final nextEmergency = safety?['emergencyStopped'] == true;
    final nextPolicy = safety?['policy']?.toString() ?? state.safetyPolicy;

    final hostsChanged = !listEquals(nextHosts, state.hosts);
    final toolkitsChanged = nextToolkits.length != state.containerToolkits.length ||
        Iterable<int>.generate(nextToolkits.length).any(
          (i) => nextToolkits[i].installed != state.containerToolkits[i].installed,
        );
    final auditChanged = !_deepEquals(auditList, state.safetyAudit);
    final nativeChanged = hostsChanged ||
        toolkitsChanged ||
        nextRt != state.nativeRuntimeStatus ||
        nextPerms != state.nativePermissions ||
        nextAccess != state.phoneAccessibility ||
        nextOverlay != state.phoneOverlay ||
        nextShizuku != state.phoneShizuku ||
        nextConfirmRisk != state.phoneConfirmHighRisk ||
        nextEmergency != state.emergencyStopped ||
        nextPolicy != state.safetyPolicy ||
        auditChanged;

    if (nativeChanged) {
      state = state.copyWith(
        hosts: hostsChanged ? nextHosts : state.hosts,
        containerToolkits: toolkitsChanged ? nextToolkits : state.containerToolkits,
        nativeRuntimeStatus: nextRt,
        nativePermissions: nextPerms,
        phoneAccessibility: nextAccess,
        phoneOverlay: nextOverlay,
        phoneShizuku: nextShizuku,
        phoneConfirmHighRisk: nextConfirmRisk,
        emergencyStopped: nextEmergency,
        safetyPolicy: nextPolicy,
        safetyAudit: auditChanged ? auditList : state.safetyAudit,
      );
    }

    if (skipAutoConnect) return;

    // Auto-start or bind the REAL on-device Android Ubuntu + Node 24 + DSH 0.2.2-rc.5 engine!
    if (state.activeHost.isLocal && !kIsWeb) {
      if (rt == null) {
        if (state.loadingSessions) {
          state = state.copyWith(
            loadingSessions: false,
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
      } else if (rt.initialized && !rt.engineRunning && rt.engineState == 'stopped') {
        if (_liveClient != null) {
          _detachLiveClientsSync();
        }
        if (_autoStartRequestedGen != gen) {
          _autoStartRequestedGen = gen;
          state = state.copyWith(
            connectionPhase: ConnectionPhase.connecting,
            loadingSessions: true,
          );
          unawaited(native.startLocalEngine());
        } else if (state.loadingSessions || state.connectionPhase != ConnectionPhase.disconnected) {
          state = state.copyWith(
            loadingSessions: false,
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
          _detachLiveClientsSync();
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
      showToast('本机容器正在部署中，请稍候…', tone: ToastTone.info);
      return;
    }
    _bootstrappingLocal = true;
    try {
      state = state.copyWith(runtimeProgressPct: 8, runtimeProgressMsg: '准备初始化本机运行环境…');
      final res = await native.bootstrapRuntime();
      await refreshNativeStatus();
      if (!mounted) return;
      if (res['ok'] == true) {
        await native.startKeepaliveService();
        showToast('本机 Linux 容器与零侵入桥已就绪');
      } else {
        state = state.copyWith(runtimeProgressPct: 0, runtimeProgressMsg: '');
        showError('初始化本机运行环境失败', error: res['error'] ?? '容器部署未完成，请检查存储空间后重试');
      }
    } catch (e) {
      if (mounted) {
        state = state.copyWith(runtimeProgressPct: 0, runtimeProgressMsg: '');
        showError('初始化本机运行环境失败', error: e);
      }
    } finally {
      _bootstrappingLocal = false;
    }
  }

  Future<void> stopLocalEngine() async {
    final native = GrassBagNativeBridge.instance;
    if (!native.isAndroidNative) {
      showToast('仅 Android 本机内置引擎支持直接启停', tone: ToastTone.info);
      return;
    }
    final isLocalActive = state.activeHost.isLocal;
    if (isLocalActive) {
      final gen = ++_hostConnectGen;
      _autoStartRequestedGen = gen;
      _detachLiveClientsSync();
      state = state.copyWith(
        connectionPhase: ConnectionPhase.disconnected,
        loadingSessions: false,
        isStreaming: false,
      );
    }
    await native.stopLocalEngine();
    await refreshNativeStatus(skipAutoConnect: true);
    if (!mounted) return;
    showToast('本机 DSH 引擎已停止', tone: ToastTone.info);
  }

  Future<void> exportEncryptedBackup(String passphrase) async {
    final res = await GrassBagNativeBridge.instance.exportEncryptedBackup(passphrase);
    if (!mounted) return;
    if (res['ok'] == true) {
      final path = res['path']?.toString() ?? 'Download/';
      final kb = (((res['bytes'] as num?)?.toInt() ?? 0) / 1024).toStringAsFixed(1);
      showToast('已加密导出 ($kb KB) 至 $path');
    } else {
      showToast(res['error']?.toString() ?? '已生成本地加密备份摘要', tone: ToastTone.info);
    }
  }

  Future<void> scanLanForHosts({int port = 3080}) async {
    if (state.scanningLan) return;
    if (kIsWeb) {
      showToast('浏览器环境无法扫描局域网端口，请直接粘贴远程地址或启动链接', tone: ToastTone.info);
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
    showToast(
      found.isEmpty
          ? '未发现局域网 DSH 服务（桌面端默认仅监听本机随机端口，请查看下方「桌面端引导」开启远程访问）'
          : (dshCount > 0
              ? '发现 $dshCount 台局域网 DSH 服务（共 ${found.length} 台主机），免插件可直接连接'
              : '发现 ${found.length} 台局域网主机'),
      tone: found.isEmpty ? ToastTone.info : ToastTone.ok,
    );
  }

  // ---------------------------------------------------------------------------
  // Toast, Error Reporting & Theme
  // ---------------------------------------------------------------------------
  int _errorSeq = 0;

  static String formatReadableError(Object? err) {
    if (err == null) return '未知错误';
    if (err is GbridgeException) {
      final buf = StringBuffer(err.message);
      if (err.code.isNotEmpty) buf.write(' (${err.code}');
      if (err.status > 0) buf.write(', HTTP ${err.status}');
      if (err.code.isNotEmpty) buf.write(')');
      if (err.details != null) {
        buf.write('\n详情: ${err.details}');
      }
      return buf.toString();
    }
    final s = err.toString().trim();
    return s.startsWith('Exception: ') ? s.substring(11) : s;
  }

  void showToast(String text, {ToastTone tone = ToastTone.ok, String? detail}) {
    if (!mounted) return;
    _toastTimer?.cancel();
    final id = ++_toastSeq;
    state = state.copyWith(
      toast: GrassBagToastMessage(id: id, text: text, tone: tone, detail: detail),
    );
    final duration = (tone == ToastTone.warn || (detail != null && detail.isNotEmpty))
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
    showToast(shortToast, tone: ToastTone.warn, detail: detail);
  }

  void setSessionGroupMode(SessionGroupMode mode) {
    if (state.sessionGroupMode == mode) return;
    state = state.copyWith(sessionGroupMode: mode);
    _persistPrefs();
  }

  void setDark(bool dark) {
    if (state.isDark == dark) return;
    state = state.copyWith(isDark: dark);
    _persistPrefs();
  }

  void setAccent(GrassBagAccent accent) {
    if (state.accent == accent) return;
    state = state.copyWith(accent: accent);
    _persistPrefs();
  }

  void setGlassTier(GrassBagGlassTier tier) {
    if (state.glassTier == tier) return;
    state = state.copyWith(glassTier: tier);
    _persistPrefs();
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
    state = state.copyWith(
      searchQuery: query,
      // Always clear stale snippets on query change so previous matches never flash during 280ms debounce.
      searchSnippets: const {},
    );
    _drawerSearchTimer?.cancel();
    final hasCjk = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]').hasMatch(trimmed);
    if (trimmed.isEmpty || (!hasCjk && trimmed.length < 2) || _liveClient == null) return;
    _drawerSearchTimer = Timer(const Duration(milliseconds: 280), () {
      if (!mounted || _liveClient == null || state.searchQuery.trim() != trimmed) return;
      unawaited(_runBackendSessionSearch(trimmed));
    });
  }

  Future<void> _runBackendSessionSearch(String query) async {
    final client = _liveClient;
    if (client == null) return;
    try {
      final results = await client.searchSessions(query, limit: 30);
      if (!mounted || !identical(_liveClient, client) || state.searchQuery.trim() != query) return;
      final snippets = <String, String>{};
      for (final item in results) {
        final sid = (item['sessionId'] ?? item['id'])?.toString() ?? '';
        if (sid.isEmpty) continue;
        snippets[sid] = (item['snippet'] ?? item['title'] ?? '').toString();
      }
      state = state.copyWith(searchSnippets: snippets);
    } catch (_) {}
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

  void startNewChat({String? workspace}) {
    final wasAlreadyEmpty =
        state.activeSessionId == null && state.turns.isEmpty && !state.isStreaming;
    _clearPendingStreamCoalesce();
    _locallyCancelledTurnIds.clear();
    _cancelSuppressUntilMs = 0;
    _streamRunId++;
    final prevSid = state.activeSessionId;
    if (prevSid != null) {
      if (state.turns.isNotEmpty) {
        _cacheSessionTurns(prevSid, state.turns);
      }
      _liveClient?.stream.unsubscribe('session:$prevSid');
    }
    _turnReducer.replaceAll(const []);
    final explicitWs = workspace?.trim() ?? '';
    var resolvedWorkspace = explicitWs.isNotEmpty ? explicitWs : state.activeWorkspace;
    if (explicitWs.isNotEmpty) {
      final matched = state.workspaces
          .where((w) => w.id == explicitWs || w.path == explicitWs || w.name == explicitWs)
          .firstOrNull;
      if (matched != null) {
        resolvedWorkspace = matched.name;
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
      resolvedWorkspace = state.workspaces.first.name;
    }
    if (wasAlreadyEmpty && workspace == null) {
      // Already on a fresh New Chat stage: focus composer without wiping the user's draft!
      state = state.copyWith(
        activeWorkspace: resolvedWorkspace,
        focusComposerSignal: state.focusComposerSignal + 1,
      );
      return;
    }
    state = state.copyWith(
      clearActiveSession: true,
      activeWorkspace: resolvedWorkspace,
      turns: const [],
      hasMoreTurns: false,
      clearTurnsNextCursor: true,
      loadingOlderTurns: false,
      clearSessionLoadError: true,
      loadingSession: false,
      clearPendingApproval: true,
      clearActiveQuestion: true,
      clearActiveCordisRequest: true,
      pendingAttachments: const [],
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
      isStreaming: false,
      newChatSignal: state.newChatSignal + 1,
    );
    _recomputeVisibleInteractions();
    _saveCurrentHostContext();
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

  void selectSession(String sessionId) {
    _clearPendingStreamCoalesce();
    _locallyCancelledTurnIds.clear();
    _cancelSuppressUntilMs = 0;
    _streamRunId++;
    final prevSid = state.activeSessionId;
    if (prevSid != null && prevSid != sessionId) {
      if (state.turns.isNotEmpty) {
        _cacheSessionTurns(prevSid, state.turns);
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
    final cachedTurns = _sessionTurnsMemory[sessionId] ?? const <NormalizedTurn>[];
    _turnReducer.replaceAll(cachedTurns);
    final nextWs = target?.cwd != null && target!.cwd!.isNotEmpty
        ? _basenamePath(target.cwd!)
        : state.activeWorkspace;
    state = state.copyWith(
      sessions: updatedSessions,
      activeSessionId: sessionId,
      activeWorkspace: nextWs,
      turns: cachedTurns,
      hasMoreTurns: false,
      clearTurnsNextCursor: true,
      loadingOlderTurns: false,
      clearSessionLoadError: true,
      loadingSession: _liveClient != null && cachedTurns.isEmpty,
      clearPendingApproval: true,
      clearActiveQuestion: true,
      clearActiveCordisRequest: true,
      pendingAttachments: const [],
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
      isStreaming: target?.running == true,
      sessionJumpSignal: cachedTurns.isNotEmpty ? state.sessionJumpSignal + 1 : state.sessionJumpSignal,
    );
    _recomputeVisibleInteractions();
    _saveCurrentHostContext();

    if (_liveClient != null) {
      _liveClient!.stream.subscribe('session:$sessionId');
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
      final page = await client.getSessionTurns(sid, limit: 80, before: cursor);
      if (!_isStillLive(client) || state.activeSessionId != sid) return;
      final existingIds = state.turns.map((t) => t.turnId).toSet();
      final older = page.turns.where((t) => !existingIds.contains(t.turnId)).toList(growable: false);
      final merged = [...older, ...state.turns];
      _cacheSessionTurns(sid, merged);
      _turnReducer.replaceAll(merged);
      state = state.copyWith(
        turns: merged,
        hasMoreTurns: page.hasMore && older.isNotEmpty,
        turnsNextCursor: page.nextCursor,
        clearTurnsNextCursor: page.nextCursor == null || older.isEmpty,
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
  }) async {
    final client = _liveClient;
    if (client == null || sessionId.startsWith('pending-session-')) return;
    if (!_syncingSessionBundleIds.add(sessionId)) {
      _pendingResyncSessionIds.add(sessionId);
      return;
    }
    final startStreamSeq = _sessionStreamSeq[sessionId] ?? 0;
    final targetSession = state.sessions.where((s) => s.id == sessionId).firstOrNull;
    final fileScopeId = sessionId;
    final currentRelPath = state.workspaceCurrentPath;
    final currentDiffScope = state.activeDiffScope;
    try {
      final results = await Future.wait([
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
      ]);
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
          final unchangedCompleted = !prev.isStreaming &&
              !fresh.isStreaming &&
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
            (optUser.isNotEmpty && optUser == freshUser) ||
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
        final tailUser = liveTail.userMessage?.text.trim() ?? '';
        final lastIsExistingCompleted = effectiveTurns.isNotEmpty &&
            prevByTurnId.containsKey(effectiveTurns.last.turnId) &&
            effectiveTurns.last.status != 'streaming';
        final alreadyInPage = effectiveTurns.isNotEmpty &&
            !lastIsExistingCompleted &&
            (effectiveTurns.last.turnId == liveTail.turnId ||
                effectiveTurns.last.stableKey == liveTail.stableKey ||
                (tailUser.isNotEmpty &&
                    (effectiveTurns.last.userMessage?.text.trim() ?? '') == tailUser));
        if (!alreadyInPage) {
          effectiveTurns.add(liveTail);
        } else if (effectiveTurns.isNotEmpty &&
            effectiveTurns.last.stableKey != liveTail.stableKey) {
          effectiveTurns[effectiveTurns.length - 1] =
              effectiveTurns.last.copyWith(stableKey: liveTail.stableKey);
        }
      }
      final effectiveIsStreaming = effectiveTurns.isNotEmpty && effectiveTurns.last.isStreaming;

      _cacheSessionTurns(sessionId, effectiveTurns);
      _turnReducer.replaceAll(effectiveTurns);

      var ctxUsedK = 0.0;
      var ctxMaxK = 128;
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
      final parsedFiles = _parseFileTreeResponse(treeResp, basePath: currentRelPath);
      // Parse real diffs
      final parsedDiffs = _parseDiffsResponse(diffResp);
      // Parse real goals
      final parsedGoals = _parseGoalsResponse(goalResp);
      // Parse real slash commands if returned
      final parsedCommands = _parseSlashCommandsResponse(cmdResp);
      // Parse real session background jobs
      final parsedJobs = _parseJobsResponse(jobsResp, fallbackSessionId: sessionId);

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
      final nextWorkspaceFiles = _workspaceFilesEqual(parsedFiles, state.workspaceFiles)
          ? state.workspaceFiles
          : parsedFiles;
      final nextSlashCommands = parsedCommands.isNotEmpty &&
              !_slashCommandsEqual(parsedCommands, state.slashCommands)
          ? parsedCommands
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

      state = state.copyWith(
        sessions: syncedSessions,
        turns: effectiveTurns,
        hasMoreTurns: nextHasMore,
        turnsNextCursor: nextCursor,
        clearTurnsNextCursor: nextCursor == null,
        clearSessionLoadError: true,
        loadingSession: false,
        isStreaming: effectiveIsStreaming,
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
        jobs: nextJobs,
        slashCommands: nextSlashCommands,
        activePresetId: syncedPreset ?? state.activePresetId,
        activePermissionId: syncedPerm ?? state.activePermissionId,
        activeWorkspace: targetSession?.cwd != null && targetSession!.cwd!.isNotEmpty
            ? _basenamePath(targetSession.cwd!)
            : state.activeWorkspace,
        sessionJumpSignal: jumpToBottomOnLoad ? state.sessionJumpSignal + 1 : state.sessionJumpSignal,
      );
      unawaited(_syncSessionSkillsAndFeedback(client, sessionId));
    } catch (e) {
      if (_isStillLive(client) && state.activeSessionId == sessionId) {
        state = state.copyWith(
          loadingSession: false,
          sessionLoadError: state.turns.isEmpty ? formatReadableError(e) : null,
        );
      }
    } finally {
      _syncingSessionBundleIds.remove(sessionId);
      if (_pendingResyncSessionIds.remove(sessionId) &&
          mounted &&
          identical(_liveClient, client) &&
          state.activeSessionId == sessionId) {
        unawaited(_syncLiveSessionBundle(sessionId, jumpToBottomOnLoad: false));
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

  Future<Map<String, dynamic>> readWorkspaceFilePage(
    String filePath, {
    int offset = 1,
    int limit = 400,
  }) async {
    final client = _liveClient;
    if (client == null) {
      return {'text': '未连接 DSH 主机', 'eof': true, 'lines': 0};
    }
    final scopeId = state.activeSessionId ?? state.activeWorkspaceItem?.path ?? state.activeWorkspaceItem?.id ?? '';
    if (scopeId.isEmpty) {
      return {'text': '未选择工作区', 'eof': true, 'lines': 0};
    }
    try {
      final resp = await client.readWorkspaceFile(
        scopeId,
        filePath,
        offset: offset,
        limit: limit,
        sessionId: state.activeSessionId,
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
    final scopeId = state.activeSessionId ?? state.activeWorkspaceItem?.path ?? state.activeWorkspaceItem?.id ?? '';
    if (scopeId.isEmpty) return null;
    try {
      return await client.readWorkspaceFileBytes(
        scopeId,
        filePath,
        sessionId: state.activeSessionId,
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
        if (sess is List) {
          for (final s in sess) {
            if (s is! Map) continue;
            final id = (s['sessionId'] ?? s['id'])?.toString() ?? '';
            final title = (s['title'] ?? id).toString();
            if (id.isEmpty) continue;
            out.add({'path': 'session:$id', 'label': title, 'kind': 'session'});
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
          final tree = await client.getWorkspaceFileTree(wsId);
          void collect(dynamic node) {
            if (out.length >= 20) return;
            if (node is List) {
              for (final item in node) {
                collect(item);
              }
            } else if (node is Map) {
              final kind = (node['kind'] ?? node['type'] ?? '').toString();
              final p = (node['path'] ?? node['relativePath'] ?? node['name'])?.toString() ?? '';
              final isDir = kind == 'directory' || kind == 'dir' || node['isDir'] == true;
              if (!isDir && p.isNotEmpty && (q.isEmpty || p.toLowerCase().contains(q))) {
                out.add({'path': p, 'kind': 'file'});
              }
              if (node['children'] is List) collect(node['children']);
              if (node['entries'] is List) collect(node['entries']);
              if (node['files'] is List) collect(node['files']);
            }
          }
          collect(tree['entries'] ?? tree['children'] ?? tree['files'] ?? tree['tree']);
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

  Future<void> loadWorkspaceDirectory({String path = '.'}) async {
    final client = _liveClient;
    if (client == null) return;
    final scopeId = state.activeSessionId ?? state.activeWorkspaceItem?.path ?? '';
    if (scopeId.isEmpty) return;
    final cleanRel = _normalizeRelWorkspacePath(path);
    final seq = ++_wsDirSeq;
    try {
      final resp = await client.getWorkspaceFileTree(
        scopeId,
        path: cleanRel.isEmpty ? '.' : cleanRel,
      );
      if (!mounted || !identical(_liveClient, client) || seq != _wsDirSeq) return;
      final parsed = _parseFileTreeResponse(resp, basePath: cleanRel);
      state = state.copyWith(
        workspaceFiles: parsed,
        workspaceCurrentPath: cleanRel,
      );
    } catch (e) {
      if (!mounted || !identical(_liveClient, client) || seq != _wsDirSeq) return;
      showToast('读取目录失败：${formatReadableError(e)}', tone: ToastTone.warn);
    }
  }

  Future<String> readWorkspaceFileContent(String filePath) async {
    final client = _liveClient;
    if (client == null) return '未连接 DSH 主机';
    final scopeId = state.activeSessionId ?? state.activeWorkspaceItem?.path ?? '';
    if (scopeId.isEmpty) return '未选择工作区';
    try {
      final resp = await client.readWorkspaceFile(scopeId, filePath);
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
    final scopeId = targetSid ?? state.activeWorkspaceItem?.path ?? state.activeWorkspaceItem?.id ?? '';
    if (scopeId.isEmpty) return;
    try {
      final resp = await client.getWorkspaceFileChanges(
        scopeId,
        sessionId: targetSid,
        scope: effectiveScope,
      );
      if (!_isStillLive(client) || state.activeSessionId != targetSid) return;
      final parsed = _parseDiffsResponse(resp);
      state = state.copyWith(workspaceDiffs: parsed, activeDiffScope: effectiveScope);
      if (!silent) {
        showToast(
          parsed.isEmpty ? '当前工作区暂无改动' : '已刷新改动（${parsed.length} 个文件）',
          tone: ToastTone.info,
        );
      }
    } catch (e) {
      if (!_isStillLive(client) || state.activeSessionId != targetSid) return;
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
      final zhStatus = switch (rawStatus.toLowerCase()) {
        'added' => '新增',
        'deleted' => '已删除',
        'renamed' => '重命名',
        'modified' => '已修改',
        _ => rawStatus,
      };
      out.add(
        WorkspaceDiffRecord(
          path: path,
          summary: zhStatus,
          added: (item['additions'] as num?)?.toInt() ?? (item['added'] as num?)?.toInt() ?? 0,
          removed: (item['deletions'] as num?)?.toInt() ?? (item['removed'] as num?)?.toInt() ?? 0,
          unifiedDiff: unified,
        ),
      );
    }
    return out;
  }

  static List<SessionGoalRecord> _parseGoalsResponse(Map<String, dynamic> resp) {
    final raw = resp['goal'];
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      if (map['objective'] != null || map['title'] != null || map['goal'] != null || map['text'] != null) {
        return [SessionGoalRecord.fromJson(map)];
      }
    }
    if (raw is List) {
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => SessionGoalRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const [];
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
    final client = _liveClient;
    final prev = state.sessions;
    state = state.copyWith(
      sessions: [
        for (final s in state.sessions) s.id == sessionId ? s.copyWith(title: clean) : s,
      ],
    );
    if (client != null) {
      try {
        await client.patchSession(sessionId, title: clean);
        if (!_isStillLive(client)) return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        state = state.copyWith(sessions: prev);
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
    final nextPinned = !target.pinned;
    final prev = state.sessions;
    state = state.copyWith(
      sessions: [
        for (final s in state.sessions)
          s.id == sessionId ? s.copyWith(pinned: nextPinned) : s,
      ],
    );
    if (client != null) {
      try {
        await client.patchSession(sessionId, pinned: nextPinned);
        if (!_isStillLive(client)) return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        state = state.copyWith(sessions: prev);
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
    final nextArchived = !target.archived;
    final prev = state.sessions;
    state = state.copyWith(
      sessions: [
        for (final s in state.sessions)
          s.id == sessionId ? s.copyWith(archived: nextArchived) : s,
      ],
    );
    if (client != null) {
      try {
        await client.patchSession(sessionId, archived: nextArchived);
        if (!_isStillLive(client)) return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        state = state.copyWith(sessions: prev);
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
    final prev = state.sessions;
    state = state.copyWith(
      sessions: [
        for (final s in state.sessions)
          ids.contains(s.id) ? s.copyWith(archived: archived) : s,
      ],
    );
    if (client != null) {
      final failed = <String>{};
      for (final id in ids) {
        if (!_isStillLive(client)) return;
        try {
          await client.patchSession(id, archived: archived);
        } catch (_) {
          failed.add(id);
        }
      }
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
        showError('部分对话归档失败（${failed.length} 条）');
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
    final prevSessions = state.sessions;
    final prevActiveId = state.activeSessionId;
    final remaining = state.sessions.where((s) => !ids.contains(s.id)).toList(growable: false);
    final clearCur = prevActiveId != null && ids.contains(prevActiveId);
    if (clearCur) {
      _clearPendingStreamCoalesce();
      _streamRunId++;
      if (client != null) {
        client.stream.unsubscribe('session:$prevActiveId');
      }
      _turnReducer.replaceAll(const []);
    }
    _pendingInteractionsById.removeWhere((_, item) {
      final sid = item.sessionId ?? item.payload['sessionId']?.toString();
      return sid != null && ids.contains(sid);
    });
    for (final id in ids) {
      _sessionTurnsMemory.remove(id);
    }
    state = state.copyWith(
      sessions: remaining,
      clearActiveSession: clearCur,
      turns: clearCur ? const [] : state.turns,
      hasMoreTurns: clearCur ? false : state.hasMoreTurns,
      clearTurnsNextCursor: clearCur,
      clearSessionLoadError: clearCur,
      clearPendingApproval: clearCur,
      clearActiveQuestion: clearCur,
      clearActiveCordisRequest: clearCur,
      queuedMessages: clearCur ? const [] : state.queuedMessages,
      workspaceDiffs: clearCur ? const [] : state.workspaceDiffs,
      todos: clearCur ? const [] : state.todos,
      goals: clearCur ? const [] : state.goals,
      subagents: clearCur ? const [] : state.subagents,
      contextPct: clearCur ? 0 : state.contextPct,
      contextUsedK: clearCur ? 0 : state.contextUsedK,
      contextBreakdown: clearCur ? const {} : state.contextBreakdown,
      sessionTelemetry: clearCur ? const SessionTelemetry() : state.sessionTelemetry,
      isStreaming: clearCur ? false : state.isStreaming,
    );
    _recomputeVisibleInteractions();
    if (clearCur) _saveCurrentHostContext();

    if (client != null) {
      final failed = <String>{};
      for (final id in ids) {
        if (!_isStillLive(client)) return;
        try {
          await client.deleteSession(id);
        } catch (_) {
          failed.add(id);
        }
      }
      if (!_isStillLive(client)) return;
      if (failed.isNotEmpty) {
        final restored = prevSessions.where((s) => failed.contains(s.id)).toList(growable: false);
        state = state.copyWith(sessions: [...restored, ...state.sessions]);
        showError('部分对话删除失败（${failed.length} 条）');
        return;
      }
    }
    if (mounted) showToast('已移除 ${ids.length} 个对话', tone: ToastTone.info);
  }

  Future<void> forkActiveSession({String? turnId}) async {
    final cur = state.activeSession;
    if (cur == null) return;
    final client = _liveClient;
    var forkId = 'fork-${DateTime.now().millisecondsSinceEpoch}';
    final forkTitle = '${cur.title} (分支)';
    final cutIndex = turnId == null
        ? -1
        : state.turns.indexWhere((t) => t.turnId == turnId);
    final targetTurn = cutIndex >= 0 ? state.turns[cutIndex] : null;
    final copiedTurns = cutIndex >= 0
        ? state.turns.sublist(0, cutIndex + 1)
        : List<NormalizedTurn>.of(state.turns);

    if (client != null) {
      try {
        final resp = await client.forkSession(
          cur.id,
          turnId: turnId,
          atSeq: (targetTurn != null && targetTurn.seqEnd > 0) ? targetTurn.seqEnd : null,
          title: forkTitle,
        );
        if (!_isStillLive(client)) return;
        final res = resp['result'];
        final realId = (res is Map ? (res['sessionId'] ?? res['id']) : null)?.toString() ??
            (resp['sessionId'] ?? resp['id'])?.toString();
        if (realId == null || realId.isEmpty) {
          showError('创建分支对话失败', error: '主机未返回新分支会话 ID');
          return;
        }
        forkId = realId;
        client.stream.unsubscribe('session:${cur.id}');
        client.stream.subscribe('session:$forkId');
      } catch (e) {
        if (!_isStillLive(client)) return;
        showError('创建分支对话失败', error: e);
        return;
      }
    }
    _clearPendingStreamCoalesce();
    _locallyCancelledTurnIds.clear();
    _cancelSuppressUntilMs = 0;
    _streamRunId++;
    _cacheSessionTurns(forkId, copiedTurns);
    _turnReducer.replaceAll(copiedTurns);

    state = state.copyWith(
      sessions: [
        ChatSessionItem(
          id: forkId,
          title: forkTitle,
          group: '今天',
          workspaceId: cur.workspaceId,
          workspaceName: cur.workspaceName,
          cwd: cur.cwd,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        ...state.sessions,
      ],
      activeSessionId: forkId,
      turns: copiedTurns,
      hasMoreTurns: false,
      clearTurnsNextCursor: true,
      loadingOlderTurns: false,
      sessionTelemetry: state.sessionTelemetry.copyWith(clearLive: true),
      isStreaming: false,
      clearPendingApproval: true,
      clearActiveQuestion: true,
      clearActiveCordisRequest: true,
      pendingAttachments: const [],
      queuedMessages: const [],
      sessionJumpSignal: state.sessionJumpSignal + 1,
    );
    _saveCurrentHostContext();
    if (client != null) {
      unawaited(_syncLiveSessionBundle(forkId, jumpToBottomOnLoad: false));
    }
    showToast('已创建分支对话：$forkTitle');
  }

  Future<void> exportActiveSession() async {
    final cur = state.activeSession;
    if (cur == null) return;
    String content = '';
    if (_liveClient != null && !cur.id.startsWith('pending-session-')) {
      try {
        final resp = await _liveClient!.exportSessionMarkdown(cur.id);
        final mdFromServer = resp['markdown']?.toString();
        if (mdFromServer != null && mdFromServer.trim().isNotEmpty) {
          content = mdFromServer;
        }
      } catch (_) {}
    }
    if (content.isEmpty) {
      final md = StringBuffer()
        ..writeln('# ${cur.title}')
        ..writeln('');
      for (final t in state.turns) {
        if (t.userMessage != null) {
          md.writeln('## 用户\n${t.userMessage!.text}\n');
        }
        if (t.assistantText.isNotEmpty) {
          md.writeln('## 助手\n${t.assistantText}\n');
        }
      }
      content = md.toString();
    }
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      await GrassBagNativeBridge.instance.shareText(content);
      showToast('已打开系统分享导出「${cur.title}」');
      return;
    }
    final safeName = cur.title.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5-]+'), '_');
    if (kIsWeb && downloadWebTextFile('$safeName.md', content)) {
      await Clipboard.setData(ClipboardData(text: content));
      showToast('已下载 $safeName.md 并复制到剪贴板');
      return;
    }
    await Clipboard.setData(ClipboardData(text: content));
    showToast('已将完整 Markdown 内容复制到剪贴板');
  }

  String? feedbackForTurn(NormalizedTurn turn) {
    final sid = state.activeSessionId ?? '';
    final msgId = turn.assistantMessageId ?? turn.turnId;
    return state.turnFeedback['$sid:$msgId'] ?? state.turnFeedback['$sid:${turn.turnId}'] ?? state.turnFeedback[turn.turnId];
  }

  Future<void> putTurnFeedback(String turnId, String rating) async {
    final sid = state.activeSessionId;
    final turn = state.turns.where((t) => t.turnId == turnId).firstOrNull;
    final messageId = turn?.assistantMessageId ?? turnId;
    final key = sid != null ? '$sid:$messageId' : turnId;
    final prev = Map<String, String>.of(state.turnFeedback);
    final next = Map<String, String>.of(state.turnFeedback);
    final removing = next[key] == rating || next[turnId] == rating;
    if (removing) {
      next.remove(key);
      next.remove(turnId);
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
        state = state.copyWith(turnFeedback: prev);
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
    final sid = state.activeSessionId;
    final cacheKey = sid != null && sid.isNotEmpty ? '$sid:$callId' : callId;
    if (!forceRefresh) {
      final existing = _toolDetailCache[cacheKey];
      if (existing != null && existing['status'] != 'running') return existing;
    }

    if (client != null && sid != null) {
      try {
        final res = await client.getToolOutput(sid, callId);
        if (!_isStillLive(client)) return const <String, dynamic>{};
        final rawTool = res['tool'];
        if (rawTool is Map) {
          final map = Map<String, dynamic>.from(rawTool);
          final outVal = map['output'] ?? map['stdout'];
          final outStr = outVal == null
              ? ''
              : (outVal is String ? outVal : const JsonEncoder.withIndent('  ').convert(outVal));
          final argsVal = map['args'];
          final argsStr = argsVal == null || (argsVal is Map && argsVal.isEmpty)
              ? ''
              : (argsVal is String
                  ? argsVal
                  : const JsonEncoder.withIndent('  ').convert(argsVal));
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
          if (outStr.isNotEmpty && _isStillLive(client) && state.activeSessionId == sid) {
            final updated = Map<String, String>.of(state.toolOutputCache)
              ..remove(cacheKey)
              ..[cacheKey] = outStr
              ..remove(callId)
              ..[callId] = outStr;
            while (updated.length > _maxToolCacheEntries * 2) {
              updated.remove(updated.keys.first);
            }
            state = state.copyWith(toolOutputCache: updated);
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
    final sid = state.activeSessionId;
    final cacheKey = sid != null && sid.isNotEmpty ? '$sid:$callId' : callId;
    final existing = state.toolOutputCache[cacheKey] ?? state.toolOutputCache[callId];
    if (existing != null) return existing;
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
    final ws = state.workspaces
        .where((w) => w.id == name || w.name == name || w.path == name)
        .firstOrNull;
    final resolvedName = ws?.name ?? name;
    state = state.copyWith(activeWorkspace: resolvedName);
    _saveCurrentHostContext();
    if (client != null && ws != null && ws.path.isNotEmpty) {
      unawaited(
        client
            .getWorkspaceFileTree(ws.path, path: '.')
            .then((resp) {
              if (!_isStillLive(client) || state.activeWorkspace != resolvedName) return;
              state = state.copyWith(
                workspaceFiles: _parseFileTreeResponse(resp, basePath: ''),
                workspaceCurrentPath: '',
              );
            })
            .catchError((_) {}),
      );
      unawaited(refreshWorkspaceDiffs(silent: true));
    }
    showToast('已切换工作区：$resolvedName');
  }

  Future<void> addWorkspace(String name, String path) async {
    final cleanPath = path.trim();
    if (cleanPath.isEmpty) return;
    final cleanName = name.trim().isEmpty ? _basenamePath(cleanPath) : name.trim();
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机后再挂载工作区', tone: ToastTone.warn);
      return;
    }
    try {
      final resp = await client.createWorkspace(path: cleanPath, name: cleanName);
      if (!_isStillLive(client)) return;
      final attached = (resp['attachedCount'] as num?)?.toInt() ?? 0;
      await _hydrateLiveDomains(client);
      if (!_isStillLive(client)) return;
      state = state.copyWith(activeWorkspace: cleanName);
      _saveCurrentHostContext();
      showToast(
        attached > 0
            ? '已创建工作区「$cleanName」并归组 $attached 条历史对话'
            : '已创建并切换工作区：$cleanName',
      );
    } catch (e) {
      if (!_isStillLive(client)) return;
      showError('创建工作区失败', error: e);
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
              ? (remaining.isNotEmpty ? remaining.first.name : '')
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

  Future<void> renameWorkspaceItem(WorkspaceItem ws, String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty) return;
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
    }
    if (!ws.explicit) {
      showToast('仅支持重命名已显式挂载的工作区', tone: ToastTone.info);
      return;
    }
    try {
      await client.patchWorkspace(ws.id, name: clean);
      if (!_isStillLive(client)) return;
      await _hydrateLiveDomains(client);
      if (!_isStillLive(client)) return;
      if (state.activeWorkspace == ws.name || state.sidebarWorkspaceFilter == ws.name) {
        state = state.copyWith(
          activeWorkspace: state.activeWorkspace == ws.name ? clean : state.activeWorkspace,
          sidebarWorkspaceFilter:
              state.sidebarWorkspaceFilter == ws.name ? clean : state.sidebarWorkspaceFilter,
        );
        _saveCurrentHostContext();
      }
      showToast('已重命名工作区为「$clean」');
    } catch (e) {
      if (!_isStillLive(client)) return;
      showError('重命名工作区失败', error: e);
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
      if (!_isStillLive(client)) return;
      await patchDshNamespace('agent-preset-registry', {'selectedDefault': presetId}, silent: true, clientOverride: client);
      if (_isStillLive(client)) showToast('已切换预设：${preset.name}');
    } catch (e) {
      if (!_isStillLive(client)) return;
      state = state.copyWith(activePresetId: prev);
      showError('切换角色预设失败', error: e);
    }
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
    final prev = state.activePermissionId;
    state = state.copyWith(activePermissionId: permId);
    final err = await patchDshNamespace('permission', {'defaultPreset': permId}, silent: true, clientOverride: client);
    if (!_isStillLive(client)) return;
    if (err != null) {
      state = state.copyWith(activePermissionId: prev);
      return;
    }
    final sid = state.activeSessionId;
    if (sid != null && !sid.startsWith('pending-session-')) {
      try {
        await client.setSessionPermission(sid, permId);
        if (!_isStillLive(client)) return;
      } catch (e) {
        if (_isStillLive(client)) showError('同步当前会话权限失败', error: e);
        return;
      }
    }
    if (_isStillLive(client)) {
      showToast('操作权限：${perm.name}', tone: perm.risky ? ToastTone.warn : ToastTone.ok);
    }
  }

  Future<void> setPlanMode(bool enabled) async {
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
        if (!_isStillLive(client)) return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        state = state.copyWith(planMode: prev);
        showError('切换计划模式失败', error: e);
        return;
      }
    }
    showToast(enabled ? '已开启计划模式' : '已关闭计划模式', tone: ToastTone.info);
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
    final lower = err.toString().toLowerCase();
    return lower.contains('settings_conflict') ||
        lower.contains('changed since it was read') ||
        lower.contains('expected revision') ||
        lower.contains('revision conflict');
  }

  Future<int?> _fetchFreshNamespaceRevision(GbridgeClient client, String ns) async {
    try {
      final schemaResp = await client.getSettingsSchema();
      if (!_isStillLive(client)) return null;
      final desc = schemaResp['description'];
      if (desc is Map<String, dynamic>) {
        final parsed = parseDshSettingsNamespaces(desc);
        if (parsed.isNotEmpty) {
          state = state.copyWith(dshNamespaces: parsed);
          final matched = parsed.where((e) => e.ns == ns).firstOrNull;
          if (matched != null && matched.revision > 0) return matched.revision;
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
    currentList[idx] = currentList[idx].copyWith(
      value: nextVal,
      revision: currentList[idx].revision + 1,
    );
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
            unawaited(_fetchFreshNamespaceRevision(client, 'agent-default-model'));
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
    }
  }

  static String _effortIdToZhLabel(String id) {
    final clean = id.trim().toLowerCase();
    if (clean.isEmpty) return '';
    return switch (clean) {
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
      '关闭' || 'off' || 'none' => 'off',
      '低' || 'low' => 'low',
      '中' || 'medium' || 'mid' => 'medium',
      '高' || 'high' => 'high',
      '超高' || 'xhigh' || 'very_high' || 'very-high' => 'xhigh',
      '极高' || 'max' => 'max',
      _ => clean,
    };
  }

  Future<void> compactContext() async {
    final client = _liveClient;
    final sid = state.activeSessionId;
    if (client == null || sid == null) {
      showToast('当前对话尚未开始或未连接主机', tone: ToastTone.warn);
      return;
    }
    showToast('正在向 DSH 请求精简上下文…', tone: ToastTone.info);
    try {
      await client.executeSlashCommand(sid, command: '/compact');
      if (!_isStillLive(client) || state.activeSessionId != sid) return;
      await _syncLiveSessionBundle(sid);
      if (!_isStillLive(client) || state.activeSessionId != sid) return;
      showToast('上下文精简指令已执行（当前占用 ${state.contextPct}%）');
    } catch (e) {
      if (!_isStillLive(client)) return;
      showError('精简上下文失败', error: e);
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

  Future<void> addGoal(String title, String criteria) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) return;
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
        if (!_isStillLive(client)) return;
        await _refreshSessionGoalsOnly(sid);
        if (!_isStillLive(client)) return;
        showToast('已设定长期目标：$cleanTitle');
        return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        showError('设定长期目标失败', error: e);
        return;
      }
    }
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机后再设定长期目标', tone: ToastTone.warn);
      return;
    }
    final goal = SessionGoalRecord(
      id: 'goal-${DateTime.now().millisecondsSinceEpoch}',
      title: cleanTitle,
      criteria: cleanCriteria,
      status: 'active',
      progressPct: 10,
    );
    state = state.copyWith(goals: [goal, ...state.goals]);
    showToast('已暂存长期目标（发送首条消息后同步至 DSH）');
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
        state = state.copyWith(goals: prevGoals);
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
        state = state.copyWith(goals: prevGoals);
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
      if (!_isStillLive(client)) return null;
      showError('创建定时任务失败', error: e);
      return '创建定时任务失败：$e';
    }
  }

  Future<String?> updateSchedule({
    required String id,
    required String name,
    required String cronExpr,
    required String prompt,
    String? timezone,
  }) async {
    final cleanName = name.trim();
    final cleanCron = cronExpr.trim();
    final cleanPrompt = prompt.trim();
    if (cleanName.isEmpty || cleanCron.isEmpty || cleanPrompt.isEmpty) {
      return '请完整填写任务名称、Cron 表达式和执行指令';
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
        'cronExpr': cleanCron,
        'prompt': cleanPrompt,
        if (timezone != null && timezone.trim().isNotEmpty) 'timeZone': timezone.trim(),
      });
      if (!_isStillLive(client)) return null;
      await _refreshSchedulesOnly();
      if (!_isStillLive(client)) return null;
      showToast('已更新定时任务：$cleanName');
      return null;
    } catch (e) {
      if (!_isStillLive(client)) return null;
      showError('更新定时任务失败', error: e);
      return '更新定时任务失败：$e';
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
          final shortTs = ts.isNotEmpty ? ts.replaceFirst('T', ' ').split('.').first : '未知时间';
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

  Future<void> launchQuickJob(String command) async {
    final clean = command.trim();
    if (clean.isEmpty) return;
    if (_liveClient == null) {
      showToast('请先连接到运行中的 DSH 主机后再启动后台任务', tone: ToastTone.warn);
      return;
    }
    showToast('正在委派 DSH 在后台运行命令…', tone: ToastTone.info);
    await sendPrompt(
      '请在后台启动并运行以下命令，并汇报任务状态：\n```bash\n$clean\n```',
      includePendingAttachments: false,
    );
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

  Future<void> promptSubagent(String subagentId, String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    final client = _liveClient;
    if (client == null) {
      showToast('请先连接到运行中的 DSH 主机', tone: ToastTone.warn);
      return;
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
      if (!_isStillLive(client)) return;
      showToast('已向子代理发送指令');
    } catch (e) {
      if (!_isStillLive(client)) return;
      state = state.copyWith(subagents: prev);
      showError('向子代理发送指令失败', error: e);
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
    state = state.copyWith(
      marketPlugins: [
        for (final p in state.marketPlugins)
          p.name == packageName
              ? p.copyWith(
                  installing: true,
                  installLogs: ['> 正在解析 $packageName 清单与依赖…'],
                )
              : p,
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
  }) async {
    final client = clientOverride ?? _liveClient;
    if (client == null || !identical(_liveClient, client)) {
      const msg = '请先连接到运行中的 DSH 主机后再修改 DSH 配置';
      if (!silent) showToast(msg, tone: ToastTone.warn);
      return msg;
    }
    if (ops.isEmpty) return null;
    var currentList = List<DshSettingsNamespace>.of(state.dshNamespaces);
    var idx = currentList.indexWhere((e) => e.ns == ns);
    var existing = idx >= 0 ? currentList[idx] : null;
    final nextVal = Map<String, dynamic>.from(existing?.value ?? const <String, dynamic>{});
    var nextRev = (existing?.revision ?? 0) + 1;

    Future<Map<String, dynamic>> sendMutate(int? expectedRev) {
      final body = <String, dynamic>{
        'ns': ns,
        'ops': ops,
        if (expectedRev != null && expectedRev > 0) 'expectedRevision': expectedRev,
      };
      return client.patchSettings(body);
    }

    try {
      Map<String, dynamic> res;
      try {
        res = await sendMutate(existing?.revision);
      } catch (firstErr) {
        if (!_isStillLive(client)) return null;
        if (!_isRevisionConflictError(firstErr)) rethrow;
        // Automatically recover from stale cached revision (e.g. DSH background update or rapid toggle).
        final freshRev = await _fetchFreshNamespaceRevision(client, ns);
        if (!_isStillLive(client)) return null;
        currentList = List<DshSettingsNamespace>.of(state.dshNamespaces);
        idx = currentList.indexWhere((e) => e.ns == ns);
        existing = idx >= 0 ? currentList[idx] : existing;
        res = await sendMutate(freshRev);
      }
      if (!_isStillLive(client)) return null;
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
      if (!_isStillLive(client)) return null;
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
    var currentList = List<DshSettingsNamespace>.of(state.dshNamespaces);
    var idx = currentList.indexWhere((e) => e.ns == ns);
    var existing = idx >= 0 ? currentList[idx] : null;
    final nextVal = replace || existing == null
        ? Map<String, dynamic>.from(patch)
        : {...existing.value, ...patch};
    var nextRev = (existing?.revision ?? 0) + 1;

    Future<Map<String, dynamic>> sendPatch(int? expectedRev) {
      final body = <String, dynamic>{
        'ns': ns,
        if (replace) 'section': nextVal else 'patch': patch,
        if (expectedRev != null && expectedRev > 0) 'expectedRevision': expectedRev,
      };
      return client.patchSettings(body);
    }

    try {
      Map<String, dynamic> res;
      try {
        res = await sendPatch(existing?.revision);
      } catch (firstErr) {
        if (!_isStillLive(client)) return null;
        if (!_isRevisionConflictError(firstErr)) rethrow;
        final freshRev = await _fetchFreshNamespaceRevision(client, ns);
        if (!_isStillLive(client)) return null;
        currentList = List<DshSettingsNamespace>.of(state.dshNamespaces);
        idx = currentList.indexWhere((e) => e.ns == ns);
        existing = idx >= 0 ? currentList[idx] : existing;
        res = await sendPatch(freshRev);
      }
      if (!_isStillLive(client)) return null;
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
      if (!_isStillLive(client)) return null;
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
        if (!_isStillLive(client)) return null;
      } catch (e) {
        if (!_isStillLive(client)) return null;
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
      if (err != null || !_isStillLive(client)) return err;
    } else if (settingsNs == 'llm-commandcode') {
      final ops = <Map<String, dynamic>>[
        if (cleanUrl.isNotEmpty)
          {'op': 'set', 'path': ['apiBase'], 'value': cleanUrl}
        else
          {'op': 'unset', 'path': ['apiBase']},
        if (cleanEnv.isNotEmpty) {'op': 'set', 'path': ['apiKeyEnv'], 'value': cleanEnv},
      ];
      final err = await mutateDshNamespace('llm-commandcode', ops, silent: true, skipHydrate: true, clientOverride: client);
      if (err != null || !_isStillLive(client)) return err;
    } else if (settingsNs == 'llm-pi-ai' && cleanId.isNotEmpty) {
      final ns = state.dshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
      final rootCopy = Map<String, dynamic>.from(ns?.value ?? const <String, dynamic>{});
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

      final err = await patchDshNamespace(
        'llm-pi-ai',
        rootCopy,
        replace: true,
        silent: true,
        skipHydrate: true,
        clientOverride: client,
      );
      if (err != null || !_isStillLive(client)) return err;
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

    final matchId = (previousModelId != null && previousModelId.trim().isNotEmpty)
        ? previousModelId.trim()
        : cleanId;
    final hadNoValidModel = state.activeModelEntry == null || !state.hasAvailableModels;
    final wasActiveModel = state.activeModelProvider == cleanProv && state.activeModelId == matchId;
    final existingIdx = modelsList.indexWhere((m) => m['id']?.toString() == matchId);
    final updatedModel = existingIdx >= 0
        ? Map<String, dynamic>.from(modelsList[existingIdx])
        : <String, dynamic>{};
    updatedModel['id'] = cleanId;
    updatedModel['name'] = displayName.trim().isEmpty ? cleanId : displayName.trim();
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
      final efforts = (reasoningEfforts != null && reasoningEfforts.isNotEmpty)
          ? reasoningEfforts
          : (existingMap.isNotEmpty
              ? existingMap.keys.map((e) => e.toString()).toList(growable: false)
              : const ['low', 'medium', 'high']);
      updatedModel['reasoningEfforts'] = <String, dynamic>{
        for (final e in efforts) e: existingMap.containsKey(e) ? existingMap[e] : e,
      };
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

    final err = await patchDshNamespace(
      'llm-pi-ai',
      rootCopy,
      replace: true,
      silent: true,
      skipHydrate: true,
      clientOverride: client,
    );
    if (err != null || !_isStillLive(client)) return err;

    await _hydrateLiveDomains(client, skipAutoDefaultSync: true);
    if (!_isStillLive(client)) return null;
    if (setAsDefault ||
        hadNoValidModel ||
        state.activeModelEntry == null ||
        (wasActiveModel && matchId != cleanId)) {
      final liveEntry = _findModelEntry(cleanProv, cleanId) ?? state.firstAvailableModel;
      final targetProv = liveEntry?.providerId ?? cleanProv;
      final targetId = liveEntry?.id ?? cleanId;
      final targetName = liveEntry?.name ?? updatedModel['name'].toString();
      final targetShort = liveEntry?.shortLabel ?? updatedModel['name'].toString();
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
      showToast('已更新模型「${updatedModel['name']}」参数并同步到 DSH');
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
    final ns = state.dshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
    if (ns == null) return null;
    final rootCopy = Map<String, dynamic>.from(ns.value);
    final rawProviders = rootCopy['providers'];
    if (rawProviders is! Map || !rawProviders.containsKey(cleanId)) return null;
    final removedEntry = rawProviders[cleanId] is Map
        ? Map<String, dynamic>.from(rawProviders[cleanId] as Map)
        : const <String, dynamic>{};
    final removedEnv = removedEntry['apiKeyEnv']?.toString().trim() ?? '';
    final providersMap = Map<String, dynamic>.from(rawProviders)..remove(cleanId);
    rootCopy['providers'] = providersMap;
    final err = await patchDshNamespace(
      'llm-pi-ai',
      rootCopy,
      replace: true,
      silent: true,
      skipHydrate: true,
      clientOverride: client,
    );
    if (err != null || !_isStillLive(client)) return err;
    if (isCustom && removedEnv.isNotEmpty) {
      await client.unsetCredential({'ref': removedEnv}).catchError((_) => <String, dynamic>{});
      if (!_isStillLive(client)) return null;
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

  Future<List<Map<String, dynamic>>> discoverProviderModels({
    required String providerId,
    required String apiProtocol,
    required String baseUrl,
    String? apiKeyValue,
    String? envRef,
    bool testOnly = false,
  }) async {
    final client = _liveClient;
    if (client == null) {
      showToast(
        testOnly ? '请先连接到运行中的 DSH 主机后再测试连通性' : '请先连接到运行中的 DSH 主机后再拉取模型列表',
        tone: ToastTone.warn,
      );
      return const [];
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
            : (out.isEmpty ? '接口未返回可用模型，可手动填写模型 ID' : '已自动拉取 ${out.length} 个模型');
        showToast(msg, tone: out.isEmpty ? ToastTone.info : ToastTone.ok);
      }
      return out;
    } catch (e) {
      if (mounted) showError(testOnly ? '测试连通失败' : '自动拉取模型列表失败', error: e);
      return const [];
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
        final ns = state.dshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
        final rootCopy = Map<String, dynamic>.from(ns?.value ?? const <String, dynamic>{});
        final providersMap = rootCopy['providers'] is Map
            ? Map<String, dynamic>.from(rootCopy['providers'] as Map)
            : <String, dynamic>{};
        final entry = providersMap[providerId] is Map
            ? Map<String, dynamic>.from(providersMap[providerId] as Map)
            : <String, dynamic>{};
        entry['baseURL'] = cleanUrl;
        entry['apiKeyEnv'] = envRef;
        providersMap[providerId] = entry;
        rootCopy['providers'] = providersMap;
        final err = await patchDshNamespace('llm-pi-ai', rootCopy, replace: true, silent: true, clientOverride: client);
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
      _autoStartRequestedGen = -1;
      if (isLocalActive) {
        _detachLiveClientsSync();
        if (mounted) {
          state = state.copyWith(connectionPhase: ConnectionPhase.connecting);
        }
      }
      final res = await native.rebuildContainer();
      await refreshNativeStatus(connectGen: gen);
      if (!mounted) return;
      if (res['ok'] != true) {
        state = state.copyWith(runtimeProgressPct: 0, runtimeProgressMsg: '');
      }
      showToast(
        res['ok'] == true ? '容器已重建并重启引擎，/root 资料零丢失' : '容器重建失败：${res['error']}',
        tone: res['ok'] == true ? ToastTone.ok : ToastTone.warn,
      );
      return;
    }
    await upgradeLocalContainer();
  }

  Future<void> refreshEngineLogs() async {
    // Only populate Android native engine logs when viewing the local Android host.
    if (!state.activeHost.isLocal) return;
    final logs = await GrassBagNativeBridge.instance.getEngineLogs();
    if (mounted && state.activeHost.isLocal && logs.isNotEmpty) {
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
      final gen = ++_hostConnectGen;
      state = state.copyWith(
        connectionPhase: ConnectionPhase.connecting,
        loadingSessions: true,
      );
      await _tryConnectLiveHost(target, gen: gen);
    } else {
      await _probeHostOnly(target);
    }
    if (!mounted) return;
    final ms = DateTime.now().difference(t0).inMilliseconds.clamp(1, 9999);
    final updated = state.hosts.firstWhere((h) => h.id == hostId, orElse: () => target);
    state = state.copyWith(
      hosts: [
        for (final h in state.hosts) h.id == hostId ? h.copyWith(latency: '$ms ms') : h,
      ],
    );
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

  static String _stripQueryToken(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme || !uri.queryParameters.containsKey('token')) {
      return rawUrl;
    }
    final nextParams = Map<String, String>.of(uri.queryParameters)..remove('token');
    return uri.replace(queryParameters: nextParams.isEmpty ? null : nextParams).toString();
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

  bool importConfigJson(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map<String, dynamic>) return false;
      final prefs = decoded['prefs'];
      if (prefs is Map<String, dynamic>) {
        final accentName = prefs['accent']?.toString();
        final tierName = prefs['glassTier']?.toString();
        state = state.copyWith(
          isDark: prefs['isDark'] is bool ? prefs['isDark'] as bool : state.isDark,
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
          autoFoldSteps: prefs['autoFoldSteps'] is bool
              ? prefs['autoFoldSteps'] as bool
              : state.autoFoldSteps,
          useSystemProxy: prefs['useSystemProxy'] is bool
              ? prefs['useSystemProxy'] as bool
              : state.useSystemProxy,
          safetyPolicy: prefs['safetyPolicy']?.toString() ?? state.safetyPolicy,
          phoneConfirmHighRisk: prefs['phoneConfirmHighRisk'] is bool
              ? prefs['phoneConfirmHighRisk'] as bool
              : state.phoneConfirmHighRisk,
          sessionGroupMode: SessionGroupMode.values.firstWhere(
            (m) => m.name == prefs['sessionGroupMode']?.toString(),
            orElse: () => state.sessionGroupMode,
          ),
        );
      }
      final rawHosts = decoded['hosts'];
      if (rawHosts is List && rawHosts.isNotEmpty) {
        final existingById = {for (final h in state.hosts) h.id: h};
        final imported = rawHosts
            .whereType<Map<String, dynamic>>()
            .map((m) {
              final h = ManagedHost.fromJson(m);
              final prevTok = existingById[h.id]?.token;
              return h.copyWith(
                address: _stripQueryToken(h.address),
                token: prevTok,
              );
            })
            .toList(growable: false);
        if (imported.any((h) => h.isLocal)) {
          final prevActive = state.activeHostId;
          final nextActiveId = imported.any((h) => h.id == prevActive) ? prevActive : 'local';
          state = state.copyWith(hosts: imported);
          _persistHosts();
          if (nextActiveId != prevActive ||
              existingById[nextActiveId]?.address !=
                  imported.firstWhere((h) => h.id == nextActiveId).address) {
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
    if (client == null || sid == null || sid.startsWith('pending-session-')) {
      showToast('请先连接到运行中的 DSH 会话', tone: ToastTone.warn);
      return false;
    }
    final uploadedRefs = await _prepareAttachmentsForUpload(client, sid, attached);
    if (uploadedRefs == null) return false;
    if (!_isStillLive(client) || state.activeSessionId != sid) return false;

    final tempId = 'q-${DateTime.now().millisecondsSinceEpoch}';
    final label = trimmed.isNotEmpty ? trimmed : '[附带 ${attached.length} 个附件]';
    final item = QueuedMessageItem(id: tempId, text: label, mode: mode);
    final prev = state.queuedMessages;
    final sentIds = attached.map((a) => a.id).toSet();
    state = state.copyWith(
      queuedMessages: [...prev, item],
      pendingAttachments: state.pendingAttachments
          .where((a) => !sentIds.contains(a.id))
          .toList(growable: false),
    );
    try {
      final resp = await client.sendMessage(
        sid,
        text: trimmed,
        mode: mode,
        attachments: uploadedRefs.isEmpty ? null : uploadedRefs,
        references: references != null && references.isNotEmpty ? references : null,
      );
      if (!_isStillLive(client)) return true;
      final res = resp['result'];
      final serverId = (res is Map
              ? (res['itemId'] ?? res['queueItemId'] ?? res['id'] ?? res['requestId'])
              : (resp['itemId'] ?? resp['queueItemId'] ?? resp['id'] ?? resp['requestId']))
          ?.toString();
      if (serverId != null && serverId.isNotEmpty && serverId != tempId) {
        state = state.copyWith(
          queuedMessages: [
            for (final q in state.queuedMessages)
              q.id == tempId ? QueuedMessageItem(id: serverId, text: q.text, mode: q.mode) : q,
          ],
        );
      }
      showToast(mode == 'steer' ? '已作为插话指令加入队列' : '已加入待发队列（${state.queuedMessages.length} 条）', tone: ToastTone.info);
      return true;
    } catch (e) {
      if (!_isStillLive(client)) return false;
      final existingIds = state.pendingAttachments.map((a) => a.id).toSet();
      state = state.copyWith(
        queuedMessages: prev,
        pendingAttachments: [
          ...attached.where((a) => !existingIds.contains(a.id)),
          ...state.pendingAttachments,
        ],
      );
      showError('加入待发队列失败', error: e);
      return false;
    }
  }

  Future<void> removeQueuedMessage(String id) async {
    final client = _liveClient;
    final prev = state.queuedMessages;
    state = state.copyWith(
      queuedMessages: prev.where((q) => q.id != id).toList(growable: false),
    );
    final sid = state.activeSessionId;
    if (sid != null && !sid.startsWith('pending-session-') && client != null && !id.startsWith('q-')) {
      try {
        await client.updateQueue(sid, {'itemId': id, 'action': 'remove'});
      } catch (e) {
        if (!_isStillLive(client)) return;
        state = state.copyWith(queuedMessages: prev);
        showError('移除队列消息失败', error: e);
      }
    }
  }

  Future<void> promoteQueuedMessage(String id) async {
    final target = state.queuedMessages.where((q) => q.id == id).firstOrNull;
    if (target == null) return;
    final client = _liveClient;
    final prev = state.queuedMessages;
    state = state.copyWith(
      queuedMessages: prev.where((q) => q.id != id).toList(growable: false),
    );
    final sid = state.activeSessionId;
    if (sid != null && !sid.startsWith('pending-session-') && client != null && !id.startsWith('q-')) {
      try {
        await client.updateQueue(sid, {'itemId': id, 'action': 'promote'});
        if (!_isStillLive(client)) return;
        showToast('已优先插入当前回合执行', tone: ToastTone.info);
        return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        state = state.copyWith(queuedMessages: prev);
        showError('提升队列优先级失败', error: e);
        return;
      }
    }
    if (!state.isStreaming) {
      await sendPrompt(target.text, mode: 'interrupt');
    } else {
      showToast('该消息已提交至队列，将在当前回复间隙执行', tone: ToastTone.info);
    }
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
    List<ComposerAttachment> attached,
  ) async {
    const inlineImageMimes = {'image/png', 'image/jpeg', 'image/webp', 'image/gif'};
    final uploadedRefs = <Map<String, dynamic>>[];
    for (final a in attached) {
      var normMime = a.mimeType.trim().toLowerCase();
      if (normMime == 'image/jpg') normMime = 'image/jpeg';
      if (inlineImageMimes.contains(normMime) && a.bytes != null && a.bytes!.isNotEmpty) {
        uploadedRefs.add({
          'type': 'image',
          'mediaType': normMime,
          'mimeType': normMime,
          'data': base64Encode(a.bytes!),
          'name': a.name,
          'size': a.sizeBytes,
        });
        continue;
      }
      String? receiptId;
      if (a.bytes != null && a.bytes!.isNotEmpty) {
        try {
          final resBytes = await client.uploadBinary(
            a.bytes!,
            filename: a.name,
            sessionId: sessionId,
            contentType: normMime.isNotEmpty ? normMime : 'application/octet-stream',
          );
          final decoded = jsonDecode(utf8.decode(resBytes));
          if (decoded is Map) {
            final up = decoded['upload'] ?? decoded['value'] ?? decoded;
            if (up is Map) {
              receiptId = (up['receiptId'] ?? up['attachmentId'] ?? up['id'] ?? up['fileId'])?.toString();
            }
          }
          if (receiptId == null || receiptId.isEmpty) {
            throw StateError('主机未返回文件凭证 (receiptId)');
          }
        } catch (e) {
          showError('上传附件 ${a.name} 失败，已保留待发附件', error: e);
          return null;
        }
      }
      uploadedRefs.add({
        'type': 'file',
        'name': a.name,
        'mimeType': normMime.isNotEmpty ? normMime : a.mimeType,
        'size': a.sizeBytes,
        if (receiptId != null && receiptId.isNotEmpty) 'receiptId': receiptId,
      });
    }
    return uploadedRefs;
  }

  // ---------------------------------------------------------------------------
  // Messaging, Slash Execution & Interactions
  // ---------------------------------------------------------------------------
  Future<bool> sendPrompt(
    String text, {
    String mode = 'auto',
    List<Map<String, dynamic>>? references,
    bool includePendingAttachments = true,
  }) async {
    final trimmed = text.trim();
    final hasAttachments = includePendingAttachments && state.pendingAttachments.isNotEmpty;
    if (trimmed.isEmpty && !hasAttachments) return false;

    // Built-in instant slash commands handled seamlessly on mobile
    if (trimmed == '/compact') {
      await compactContext();
      return true;
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
    if (trimmed == '/goal' || trimmed.startsWith('/goal ')) {
      final goalText = trimmed.length > 5 ? trimmed.substring(5).trim() : '';
      if (goalText.isNotEmpty) {
        await addGoal(goalText, '完成后逐项自测并输出验证结果');
      } else {
        showToast('请输入目标内容，例如 /goal 优化启动速度', tone: ToastTone.info);
      }
      return true;
    }
    // Route any other `/...` slash command (including `/compact <instructions>`, `/skill:...`, `/help`, etc.)
    // directly through DSH `commands/execute` when connected.
    final slashClient = _liveClient;
    if (trimmed.startsWith('/') && !trimmed.contains('\n') && slashClient != null) {
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
          if (!_isStillLive(slashClient)) return false;
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
              ...state.sessions,
            ],
          );
          _saveCurrentHostContext();
          slashClient.stream.subscribe('session:$sid');
        } catch (e) {
          if (_isStillLive(slashClient)) showError('执行斜杠指令 $trimmed 失败', error: e);
          return false;
        }
      }
      if (!sid.startsWith('pending-session-')) {
        try {
          final resp = await slashClient.executeSlashCommand(sid, command: trimmed);
          if (!_isStillLive(slashClient)) return true;
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
          if (!_isStillLive(slashClient)) return false;
          showError('执行斜杠指令 $trimmed 失败', error: e);
          return false;
        }
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
    final sendClient = _liveClient;
    final sendBootstrap = _bootstrapClient;
    if (_isSendingPrompt && _sendingPromptGen == sendGen) return false;
    _isSendingPrompt = true;
    _sendingPromptGen = sendGen;

    try {
      _clearPendingStreamCoalesce();
      _cancelSuppressUntilMs = 0;
      final runId = ++_streamRunId;
      final attached = includePendingAttachments
          ? List<ComposerAttachment>.of(state.pendingAttachments)
          : const <ComposerAttachment>[];
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
          createdAt: nowMs,
        ),
        steps: const [],
      );

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
      final prevTurnsSnapshot = state.turns;
      final prevSessionsSnapshot = state.sessions;
      final settledPrevTurns = mode == 'interrupt'
          ? [
              for (final t in state.turns)
                if (t.status == 'streaming')
                  t.copyWith(
                    status: 'cancelled',
                    steps: [
                      for (final s in t.steps)
                        (s is ToolStep && s.status == 'running') ? s.copyWith(status: 'error') : s,
                    ],
                  )
                else
                  t,
            ]
          : state.turns;
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
      _turnReducer.replaceAll(nextTurns);
      state = state.copyWith(
        sessions: optimisticSessions,
        activeSessionId: sessionId,
        turns: nextTurns,
        clearSessionLoadError: true,
        isStreaming: true,
        scrollSignal: state.scrollSignal + 1,
      );

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
              title: newTitle,
              presetId: state.activePresetId,
              permission: state.activePermissionId,
              provider: effProvider.isEmpty ? null : effProvider,
              model: effModelId.isEmpty ? null : effModelId,
              reasoningEffort: effEffortId.isEmpty ? null : effEffortId,
            );
            if (!_isStillLive(sendClient, gen: sendGen)) return false;
            final stillOnTemp = state.activeSessionId == prevTempId;
            if (created.id.isNotEmpty) sessionId = created.id;
            if (created.workspaceId != null && created.workspaceId!.isNotEmpty) {
              createdWorkspaceId = created.workspaceId;
            }
            final hasEntry = state.sessions.any((s) => s.id == prevTempId || s.id == sessionId);
            final updatedSessions = hasEntry
                ? [
                    for (final s in state.sessions)
                      (s.id == prevTempId || s.id == sessionId)
                          ? s.copyWith(
                              id: sessionId,
                              title: s.title.isNotEmpty ? s.title : newTitle,
                              workspaceId: createdWorkspaceId ?? s.workspaceId,
                              cwd: created.cwd ?? s.cwd,
                              running: stillOnTemp,
                            )
                          : s,
                  ]
                : [
                    ChatSessionItem(
                      id: sessionId,
                      title: newTitle,
                      group: '今天',
                      workspaceId: createdWorkspaceId,
                      workspaceName: activeWsItem?.name,
                      cwd: created.cwd ?? activeCwd,
                      updatedAt: DateTime.now().millisecondsSinceEpoch,
                      running: stillOnTemp,
                    ),
                    ...state.sessions,
                  ];
            state = state.copyWith(
              activeSessionId: stillOnTemp ? sessionId : state.activeSessionId,
              sessions: [
                for (final s in updatedSessions)
                  s.id == sessionId ? s.copyWith(running: true) : s,
              ],
            );
            _sessionTurnsMemory.remove(prevTempId);
            if (stillOnTemp) {
              _saveCurrentHostContext();
              sendClient.stream.subscribe('session:$sessionId');
            } else {
              _cacheSessionTurns(sessionId, nextTurns);
            }
            if (state.planMode) {
              await sendClient
                  .executeSlashCommand(sessionId, command: '/plan on')
                  .catchError((_) => <String, dynamic>{});
              if (!_isStillLive(sendClient, gen: sendGen)) return false;
            }
            for (final g in stagedGoals) {
              if (!_isStillLive(sendClient, gen: sendGen)) return false;
              await sendClient
                  .mutateSessionGoal(
                    sessionId,
                    action: 'create',
                    payload: {
                      'objective': g.title,
                      'title': g.title,
                      'criteria': g.criteria,
                    },
                  )
                  .catchError((_) => <String, dynamic>{});
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
            }
            state = state.copyWith(
              sessions: cleanedSessions,
              clearActiveSession: stillOnTempErr,
              turns: stillOnTempErr ? prevTurnsSnapshot : state.turns,
              isStreaming: stillOnTempErr ? false : state.isStreaming,
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
        final prepared = await _prepareAttachmentsForUpload(sendClient, sessionId, attached);
        if (!_isStillLive(sendClient, gen: sendGen)) return false;
        if (prepared == null) {
          final onTarget = state.activeSessionId == sessionId;
          if (onTarget) {
            _turnReducer.replaceAll(prevTurnsSnapshot);
          } else {
            _cacheSessionTurns(sessionId, prevTurnsSnapshot);
          }
          state = state.copyWith(
            sessions: isBrandNewSession
                ? [
                    for (final s in state.sessions)
                      s.id == sessionId ? s.copyWith(running: false) : s,
                  ]
                : prevSessionsSnapshot,
            turns: onTarget ? prevTurnsSnapshot : state.turns,
            isStreaming: onTarget ? false : state.isStreaming,
          );
          return false;
        }
        uploadedRefs = prepared;
      } else {
        uploadedRefs = previewRefs;
      }

      if (mounted && sendGen == _hostConnectGen && attached.isNotEmpty) {
        final sentIds = attached.map((a) => a.id).toSet();
        state = state.copyWith(
          pendingAttachments: state.pendingAttachments
              .where((a) => !sentIds.contains(a.id))
              .toList(growable: false),
        );
      }

      if (sendClient != null) {
        if (!_isStillLive(sendClient, gen: sendGen)) return false;
        try {
          if (state.activeSessionId == sessionId) {
            sendClient.stream.subscribe('session:$sessionId');
          }
          await sendClient.sendMessage(
            sessionId,
            text: trimmed,
            mode: mode,
            attachments: uploadedRefs.isEmpty ? null : uploadedRefs,
            references: references != null && references.isNotEmpty ? references : null,
            clientRequestId: turnId,
          );
          return true;
        } catch (e) {
          if (!_isStillLive(sendClient, gen: sendGen)) return false;
          final errDetail = formatReadableError(e);
          final failedTurn = initialTurn.copyWith(
            status: 'error',
            errorMessage: errDetail,
            steps: [
              NoticeStep(
                level: 'error',
                text: '发送失败：$errDetail',
              ),
            ],
            assistantText: '',
          );
          final onTarget = state.activeSessionId == sessionId;
          if (onTarget) {
            final errTurns = [
              for (final t in state.turns) t.turnId == turnId ? failedTurn : t,
            ];
            _turnReducer.replaceAll(errTurns);
            final existingAttIds = state.pendingAttachments.map((a) => a.id).toSet();
            state = state.copyWith(
              sessions: [
                for (final s in state.sessions) s.id == sessionId ? s.copyWith(running: false) : s,
              ],
              turns: errTurns,
              pendingAttachments: attached.isNotEmpty
                  ? [
                      ...attached.where((a) => !existingAttIds.contains(a.id)),
                      ...state.pendingAttachments,
                    ]
                  : state.pendingAttachments,
              isStreaming: false,
              streamTick: state.streamTick + 1,
            );
          } else {
            final cached = _sessionTurnsMemory[sessionId];
            if (cached != null) {
              _cacheSessionTurns(sessionId, [
                for (final t in cached) t.turnId == turnId ? failedTurn : t,
              ]);
            }
            state = state.copyWith(
              sessions: [
                for (final s in state.sessions) s.id == sessionId ? s.copyWith(running: false) : s,
              ],
            );
          }
          showError('发送消息失败', error: e);
          return true;
        }
      } else if (sendBootstrap != null) {
        if (!mounted || sendGen != _hostConnectGen || !identical(_bootstrapClient, sendBootstrap)) {
          return false;
        }
        try {
          await sendBootstrap.bootstrap.sendVanillaPrompt(sessionId, trimmed);
          return true;
        } catch (e) {
          if (!mounted || sendGen != _hostConnectGen || !identical(_bootstrapClient, sendBootstrap)) {
            return false;
          }
          final onTarget = state.activeSessionId == sessionId;
          showToast('发送失败：$e', tone: ToastTone.warn);
          if (onTarget) {
            state = state.copyWith(isStreaming: false);
          }
          return false;
        }
      }

      // Disconnected offline honest notice (never pretend an LLM replied when no DSH host is connected!)
      if (!mounted || sendGen != _hostConnectGen) return false;
      final offlineTurn = initialTurn.copyWith(
        status: 'error',
        steps: const [
          NoticeStep(level: 'warn', text: '当前未连接到运行中的 DSH 主机'),
        ],
        assistantText: '当前尚未连接到运行中的 DSH 引擎，无法执行「$trimmed」。请先在「设置 → 主机与环境」连接本机或远程 DSH 服务。',
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
      showToast('尚未连接 DSH 主机，请先在主机与环境中连接', tone: ToastTone.warn);
      if (runId < 0) return false;
      return true;
    } finally {
      if (_sendingPromptGen == sendGen) {
        _isSendingPrompt = false;
        _sendingPromptGen = -1;
      }
    }
  }

  void cancelStreaming() {
    _clearPendingStreamCoalesce();
    _streamRunId++;
    final sid = state.activeSessionId;
    if (sid != null) {
      if (_liveClient != null) {
        unawaited(_liveClient!.cancelSession(sid).catchError((_) => <String, dynamic>{}));
      } else if (_bootstrapClient != null) {
        unawaited(_bootstrapClient!.bootstrap.cancelVanillaSession(sid).catchError((_) => <String, dynamic>{}));
      }
    }
    _cancelSuppressUntilMs = DateTime.now().millisecondsSinceEpoch + 2500;
    final updatedTurns = <NormalizedTurn>[];
    for (final t in state.turns) {
      if (t.status == 'streaming') {
        _locallyCancelledTurnIds.add(t.turnId);
        if (_locallyCancelledTurnIds.length > 32) {
          _locallyCancelledTurnIds.remove(_locallyCancelledTurnIds.first);
        }
        updatedTurns.add(
          t.copyWith(
            status: 'cancelled',
            steps: [
              for (final s in t.steps)
                (s is ToolStep && s.status == 'running') ? s.copyWith(status: 'error') : s,
            ],
          ),
        );
      } else {
        updatedTurns.add(t);
      }
    }
    _turnReducer.replaceAll(updatedTurns);
    final updatedSessions = [
      for (final s in state.sessions) s.id == sid ? s.copyWith(running: false) : s,
    ];
    state = state.copyWith(
      sessions: updatedSessions,
      turns: updatedTurns,
      queuedMessages: const [],
      isStreaming: false,
    );
    showToast('已停止生成', tone: ToastTone.info);
  }

  Future<void> resolveApproval(String action) async {
    final interactionId = state.pendingApprovalInteractionId;
    if (interactionId == null) return;
    final client = _liveClient;
    final backup = _pendingInteractionsById[interactionId];
    _pendingInteractionsById.remove(interactionId);
    _recomputeVisibleInteractions();
    if (client != null) {
      try {
        await client.respondInteraction(interactionId, decision: action);
        if (!_isStillLive(client)) return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        if (backup != null) {
          _pendingInteractionsById[interactionId] = backup;
          _recomputeVisibleInteractions();
        }
        showError('提交审批决定失败', error: e);
        return;
      }
    }
    if (!mounted) return;
    showToast(
      action == 'deny' ? '已拒绝该命令' : (action == 'always' ? '本对话已自动允许同类命令' : '已允许并执行该命令'),
      tone: action == 'deny' ? ToastTone.warn : ToastTone.ok,
    );
  }

  Future<void> resolveUserQuestion(Object answers) async {
    final q = state.activeQuestion;
    if (q == null) return;
    final client = _liveClient;
    final backup = _pendingInteractionsById[q.interactionId];
    _pendingInteractionsById.remove(q.interactionId);
    _recomputeVisibleInteractions();
    if (client != null) {
      try {
        await client.respondInteraction(q.interactionId, answers: answers);
        if (!_isStillLive(client)) return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        if (backup != null) {
          _pendingInteractionsById[q.interactionId] = backup;
          _recomputeVisibleInteractions();
        }
        showError('提交回答失败', error: e);
        return;
      }
    }
    if (!mounted) return;
    showToast('已提交你的选择');
  }

  Future<void> resolveCordisRun(bool allow) async {
    final req = state.activeCordisRequest;
    if (req == null) return;
    final client = _liveClient;
    final backup = _pendingInteractionsById[req.interactionId];
    _pendingInteractionsById.remove(req.interactionId);
    _recomputeVisibleInteractions();
    if (client != null) {
      try {
        await client.respondInteraction(req.interactionId, decision: allow ? 'allow' : 'deny');
        if (!_isStillLive(client)) return;
      } catch (e) {
        if (!_isStillLive(client)) return;
        if (backup != null) {
          _pendingInteractionsById[req.interactionId] = backup;
          _recomputeVisibleInteractions();
        }
        showError('提交动态插件授权失败', error: e);
        return;
      }
    }
    if (!mounted) return;
    showToast(allow ? '已允许动态插件运行' : '已拒绝动态插件运行', tone: allow ? ToastTone.ok : ToastTone.warn);
  }

  void _recomputeVisibleInteractions() {
    final activeSid = state.activeSessionId;
    String? approvalId;
    String? approvalCmd;
    ActiveUserQuestion? question;
    ActiveCordisRunRequest? cordisReq;
    final pendingSessionIds = <String>{};

    for (final item in _pendingInteractionsById.values) {
      final itemSid = item.sessionId ?? item.payload['sessionId']?.toString();
      if (itemSid != null && itemSid.isNotEmpty) {
        pendingSessionIds.add(itemSid);
      }
      final matchesActive = itemSid == null || itemSid.isEmpty || itemSid == activeSid;
      if (!matchesActive) continue;
      if (item.kind == 'user_questions') {
        question ??= _parseUserQuestionInteraction(item);
      } else if (item.kind == 'cordis_run') {
        cordisReq ??= ActiveCordisRunRequest(
          interactionId: item.id,
          pluginName: (item.payload['pluginName'] ?? item.payload['name'] ?? 'dynamic-plugin').toString(),
          summary: (item.payload['summary'] ?? item.payload['reason'] ?? '请求加载动态 Cordis 模块').toString(),
          codePreview: (item.payload['code'] ?? item.payload['source'] ?? '').toString(),
          sessionId: itemSid,
        );
      } else {
        approvalId ??= item.id;
        approvalCmd ??= _formatApprovalPrompt(item.payload);
      }
    }

    bool sessionsPendingChanged = false;
    for (final s in state.sessions) {
      if (s.pendingApproval != pendingSessionIds.contains(s.id)) {
        sessionsPendingChanged = true;
        break;
      }
    }
    if (!sessionsPendingChanged &&
        state.pendingApprovalInteractionId == approvalId &&
        state.pendingApprovalCommand == approvalCmd &&
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
      pendingApprovalInteractionId: approvalId,
      pendingApprovalCommand: approvalCmd,
      clearPendingApproval: approvalId == null,
      activeQuestion: question,
      clearActiveQuestion: question == null,
      activeCordisRequest: cordisReq,
      clearActiveCordisRequest: cordisReq == null,
    );
  }

  static String _formatApprovalPrompt(Map<String, dynamic> payload) {
    final cmd = payload['command']?.toString().trim();
    if (cmd != null && cmd.isNotEmpty) return cmd;
    final reason = (payload['displayReason'] ?? payload['reason'])?.toString().trim();
    final toolName = (payload['toolName'] ?? payload['tool'])?.toString().trim();
    if (reason != null && reason.isNotEmpty) {
      return toolName != null && toolName.isNotEmpty ? '[$toolName] $reason' : reason;
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
  void _detachLiveClientsSync() {
    _clearPendingStreamCoalesce();
    _hostSessionsRefreshTimer?.cancel();
    _hostSessionsRefreshTimer = null;
    _domainRefreshTimer?.cancel();
    _domainRefreshTimer = null;
    _drawerSearchTimer?.cancel();
    _drawerSearchTimer = null;
    _accountPollTimer?.cancel();
    _accountPollTimer = null;
    _jobOutputFlushTimer?.cancel();
    _jobOutputFlushTimer = null;
    _engineLogFlushTimer?.cancel();
    _engineLogFlushTimer = null;
    _pendingEngineLogs.clear();
    _pendingJobOutputs.clear();
    _coalescedClient = null;
    _jobOutputClient = null;
    _activeSignInAttemptId = null;
    _hadInitialWelcome = false;
    _isSendingPrompt = false;
    _sendingPromptGen = -1;
    _connectingLocalAndroid = false;
    _connectingLocalGen = null;
    _sessionTurnsMemory.clear();
    _toolDetailCache.clear();
    _pendingInteractionsById.clear();
    _syncingSessionBundleIds.clear();
    _pendingResyncSessionIds.clear();
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
  }) async {
    final target = state.hosts.where((h) => h.id == hostId).firstOrNull;
    if (target == null) return;
    // Save outgoing host's session/workspace/filter context BEFORE wiping state.
    if (savePreviousContext && state.activeHostId != hostId) {
      _saveCurrentHostContext(hostIdOverride: state.activeHostId);
    }
    final gen = ++_hostConnectGen;
    _modelSelectionGen++;
    _lastAutoSyncedDefaultKey = null;
    _hostProbeGen[hostId] = (_hostProbeGen[hostId] ?? 0) + 1;
    _streamRunId++;
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
    final restoredFilterRaw = incomingCtx?['sidebarWorkspaceFilter'] as String?;
    final restoredFilter =
        (restoredFilterRaw != null && restoredFilterRaw.isNotEmpty) ? restoredFilterRaw : null;
    state = state.copyWith(
      activeHostId: hostId,
      hosts: effectiveTarget == target
          ? state.hosts
          : [for (final h in state.hosts) h.id == hostId ? effectiveTarget : h],
      clearActiveSession: true,
      sidebarWorkspaceFilter: restoredFilter,
      clearSidebarWorkspaceFilter: restoredFilter == null,
      clearPendingApproval: true,
      clearActiveQuestion: true,
      clearActiveCordisRequest: true,
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
      turnProcessOpen: true,
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
      sessions: const [],
      loadingSessions: true,
      workspaces: const [],
      turns: const [],
      turnFeedback: const {},
      stepTranslations: const {},
      translatedStepIds: const {},
      translatingStepIds: const {},
      expandedTurnProcessIds: const {},
      collapsedTurnProcessIds: const {},
      expandedStepIds: const {},
      pendingAttachments: const [],
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
      contextPct: 0,
      contextUsedK: 0,
      contextMaxK: 128,
      contextBreakdown: const {},
      connectionPhase: ConnectionPhase.connecting,
      newChatSignal: state.newChatSignal + 1,
    );
    _persistPrefs();
    showToast(
      '已切换到「${effectiveTarget.name}」，正在刷新对话列表…',
      tone: ToastTone.info,
    );

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
      _detachLiveClientsSync();
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
    if (clean.isEmpty) return;
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

  static ({String code, String message}) _classifyConnectionError(
    Object err, {
    required String address,
  }) {
    final lower = err.toString().toLowerCase();
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
      );
    }
    if (err is GbridgeException) {
      if (err.code == 'gbridge/html_response') {
        return (
          code: 'html_proxy',
          message: '目标返回了网页登录认证页（如反向代理或 SSO 网关），可直接在 App 内网页登录同步凭证。',
        );
      }
      if (err.status == 401) {
        return (
          code: 'needs_auth',
          message: '远程 DSH 需要一次鉴权（完成后自动保存 30 天免密凭证，重启远程 DSH 亦无需重填）。',
        );
      }
      if (err.status == 403) {
        return (
          code: 'untrusted_host',
          message: '远程 DSH 拒绝了 Host 请求头（HTTP 403）。请在远程主机使用 `dsh web --host $hostLabel$portSuffix` 或 `--trusted-host $hostLabel` 启动。',
        );
      }
    }
    if (lower.contains('connection refused') ||
        lower.contains('failed host lookup') ||
        lower.contains('network is unreachable') ||
        lower.contains('no route to host') ||
        lower.contains('timed out') ||
        lower.contains('timeoutexception') ||
        lower.contains('socketexception')) {
      return (
        code: 'unreachable',
        message: '无法连通 $address。原版 `dsh web` 默认仅监听本机 127.0.0.1，请在远程电脑改用 `dsh web --host <局域网IP>` 启动。',
      );
    }
    return (code: 'error', message: formatReadableError(err));
  }

  /// Live non-destructive diagnosis of any remote DSH input BEFORE or AFTER saving,
  /// detecting stock DSH (zero-plugin direct), `dsh-gbridge`, auth needs, 403 Host fence,
  /// HTML login proxies, self-signed TLS certs, and unreachable hosts.
  Future<RemoteHostDiagnosis> diagnoseRemoteHost(
    String rawInput, {
    String? token,
    String? cookie,
    bool allowBadCertificates = false,
  }) async {
    final parsed = parseRemoteHostInput(rawInput, explicitToken: token);
    if (parsed == null) {
      return const RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.invalidAddress,
        title: '地址格式无效',
        message: '请输入 IP、域名，或直接粘贴远程电脑终端打印的 `dsh web: http://...` 整行链接。',
      );
    }

    final uri = Uri.parse(parsed.address);
    await _refreshDeviceLocalIps();
    final selfGuidance = selfDeviceGuidanceForUri(uri);
    if (selfGuidance != null) {
      return RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.selfDevice,
        title: isLoopbackHost(uri.host) ? '不能使用回环地址连接远程电脑' : '这是当前设备本机地址',
        message: selfGuidance,
        normalizedAddress: parsed.address,
      );
    }
    final effectiveToken = parsed.token;
    final sw = Stopwatch()..start();
    GbridgeClient? client;
    try {
      client = GbridgeClient(
        HostEndpoint.http(baseUri: uri, token: effectiveToken, cookie: cookie),
        timeout: const Duration(seconds: 10),
        allowBadCertificates: allowBadCertificates,
        autoReconnect: false,
      );
      if ((cookie == null || cookie.isEmpty) &&
          effectiveToken != null &&
          effectiveToken.isNotEmpty) {
        try {
          await client.exchangeAuthToken(effectiveToken);
        } catch (_) {}
      }
      final probe = await client.probeHost();
      sw.stop();
      final ms = sw.elapsedMilliseconds.clamp(1, 99999);
      if (probe is HostProbeFull) {
        return RemoteHostDiagnosis(
          kind: RemoteDiagnosisKind.readyGbridge,
          title: '连接就绪 · 增强模式',
          message: '检测到 DSH ${probe.capabilities.dshVersion} 与连接助手 v${probe.capabilities.bridgeVersion}（${ms}ms），可立即使用全部功能。',
          normalizedAddress: parsed.address,
          extractedToken: effectiveToken,
          dshVersion: probe.capabilities.dshVersion,
          latencyMs: ms,
          hasGbridge: true,
        );
      }
      if (probe is HostProbeVanillaDirect) {
        return RemoteHostDiagnosis(
          kind: RemoteDiagnosisKind.readyDirect,
          title: '连接就绪 · 原生免插件直连',
          message: '检测到原版 DSH ${probe.dshVersion}（${ms}ms），无需安装任何插件即可直接对话、管理模型、工作区与终端。',
          normalizedAddress: parsed.address,
          extractedToken: effectiveToken,
          dshVersion: probe.dshVersion,
          latencyMs: ms,
          hasGbridge: false,
        );
      }
      if (probe is HostProbeNeedsAuth) {
        final verLabel = probe.dshVersion != null ? 'DSH ${probe.dshVersion}' : '远程服务';
        if (probe.isHtmlLoginPage) {
          return RemoteHostDiagnosis(
            kind: RemoteDiagnosisKind.htmlLoginPage,
            title: '检测到网页登录认证',
            message: '$verLabel 位于登录网关或反向代理后方，点击下方「App 内网页登录」即可自动同步凭证，无需手动填 Token。',
            normalizedAddress: parsed.address,
            extractedToken: effectiveToken,
            dshVersion: probe.dshVersion,
            latencyMs: ms,
            hasGbridge: probe.hasGbridge,
          );
        }
        return RemoteHostDiagnosis(
          kind: RemoteDiagnosisKind.needsAuth,
          title: '已发现 $verLabel · 请完成一次授权',
          message: '远程服务在线（${ms}ms），免装插件即可使用。请粘贴一次电脑端生成的启动链接（含 ?token=）或输入 Token，授权成功后 30 天内自动免填连接。',
          normalizedAddress: parsed.address,
          extractedToken: effectiveToken,
          dshVersion: probe.dshVersion,
          latencyMs: ms,
          hasGbridge: probe.hasGbridge,
        );
      }
      if (probe is HostProbeUntrustedHost) {
        final isIp = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(uri.host);
        final portFlag = uri.hasPort && uri.port != 3080 ? ' --port ${uri.port}' : '';
        final cmd = isIp
            ? 'dsh web --host ${uri.host}$portFlag'
            : 'dsh web --trusted-host ${probe.hostAuthority}$portFlag';
        return RemoteHostDiagnosis(
          kind: RemoteDiagnosisKind.untrustedHost,
          title: '远程 DSH 拒绝了访问主机名 (HTTP 403)',
          message: '原版 DSH 的安全校验未放行 `${probe.hostAuthority}`。请在远程主机使用下方命令启动即可直连：',
          normalizedAddress: parsed.address,
          extractedToken: effectiveToken,
          dshVersion: probe.dshVersion,
          latencyMs: ms,
          hostAuthority: probe.hostAuthority,
          suggestedCommand: cmd,
        );
      }
      return RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.readyDirect,
        title: '检测到远程 DSH 服务',
        message: '已探测到目标主机（${ms}ms），可直接添加并连接。',
        normalizedAddress: parsed.address,
        extractedToken: effectiveToken,
        latencyMs: ms,
      );
    } catch (e) {
      sw.stop();
      final classified = _classifyConnectionError(e, address: parsed.address);
      final isIp = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(uri.host);
      final portFlag = uri.hasPort && uri.port != 3080 ? ' --port ${uri.port}' : '';
      final cmd = isIp
          ? 'dsh web --host ${uri.host}$portFlag'
          : 'dsh web --host <局域网IP>$portFlag';
      return RemoteHostDiagnosis(
        kind: switch (classified.code) {
          'tls_cert' => RemoteDiagnosisKind.selfSignedTls,
          'html_proxy' => RemoteDiagnosisKind.htmlLoginPage,
          'needs_auth' => RemoteDiagnosisKind.needsAuth,
          'untrusted_host' => RemoteDiagnosisKind.untrustedHost,
          _ => RemoteDiagnosisKind.unreachable,
        },
        title: switch (classified.code) {
          'tls_cert' => 'HTTPS 自签名证书拦截',
          'html_proxy' => '检测到网页登录认证页',
          'needs_auth' => '需要一次鉴权',
          'untrusted_host' => '远程 DSH Host 校验拒绝 (403)',
          _ => '无法连通目标主机',
        },
        message: classified.message,
        normalizedAddress: parsed.address,
        extractedToken: effectiveToken,
        suggestedCommand: classified.code == 'unreachable' || classified.code == 'untrusted_host'
            ? cmd
            : null,
      );
    } finally {
      await client?.dispose();
    }
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
      final cleanUri = uri.replace(queryParameters: null);
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
      if (!host.hasSavedCookie && token != null && token.isNotEmpty) {
        try {
          await client.exchangeAuthToken(token);
        } catch (_) {}
      }
      final probe = await client.probeHost();
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
                      bridged: probe.hasGbridge,
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

  Future<void> _tryConnectLiveHost(ManagedHost host, {int? gen}) async {
    final targetGen = gen ?? _hostConnectGen;
    try {
      await _disconnectLiveClients();
      if (!mounted || targetGen != _hostConnectGen) return;
      final addr = _normalizeHttpAddress(host);
      final uri = Uri.tryParse(addr);
      if (uri == null || !uri.hasScheme) {
        state = state.copyWith(
          loadingSessions: false,
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
      final cleanUri = uri.replace(queryParameters: null);
      final sw = Stopwatch()..start();
      final client = GbridgeClient(
        HostEndpoint.http(
          baseUri: cleanUri,
          token: token,
          cookie: host.sessionCookie,
        ),
        timeout: const Duration(seconds: 15),
        allowBadCertificates: host.allowBadCertificates,
        onCookieUpdated: (c) => _persistHostCookie(host.id, c),
      );
      if (!host.hasSavedCookie && token != null && token.isNotEmpty) {
        try {
          await client.exchangeAuthToken(token);
        } catch (_) {}
      }
      final probe = await client.probeHost();
      sw.stop();
      final latLabel = '${sw.elapsedMilliseconds.clamp(1, 99999)}ms';
      if (!mounted || targetGen != _hostConnectGen) {
        await client.dispose();
        return;
      }
      if (probe is HostProbeFull) {
        await _bindFullLiveClient(
          client,
          host.id,
          probe.capabilities,
          gen: targetGen,
          isDirect: false,
          latencyLabel: latLabel,
        );
      } else if (probe is HostProbeVanillaDirect) {
        // ZERO-PLUGIN FULL DIRECT MODE against stock `dsh web`!
        final directCaps = client.enableVanillaDirectMode(
          dshVersion: probe.dshVersion,
          hostName: host.name,
        );
        await _bindFullLiveClient(
          client,
          host.id,
          directCaps,
          gen: targetGen,
          isDirect: true,
          latencyLabel: latLabel,
        );
      } else if (probe is HostProbeNeedsAuth) {
        await client.dispose();
        final errCode = probe.isHtmlLoginPage ? 'html_proxy' : 'needs_auth';
        final verText = probe.dshVersion != null ? 'DSH ${probe.dshVersion}' : host.name;
        state = state.copyWith(
          loadingSessions: false,
          connectionPhase: ConnectionPhase.needsAuth,
          clearLiveCapabilities: true,
          hosts: [
            for (final h in state.hosts)
              h.id == host.id
                  ? h.copyWith(
                      bridged: probe.hasGbridge,
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
        await client.dispose();
        state = state.copyWith(
          loadingSessions: false,
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
        _bootstrapClient = client;
        state = state.copyWith(
          loadingSessions: false,
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
    }
  }

  Future<void> _bindFullLiveClient(
    GbridgeClient client,
    String hostId,
    Capabilities caps, {
    int? gen,
    bool isDirect = false,
    String? latencyLabel,
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
    _hadInitialWelcome = false;
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
      connectionPhase: ConnectionPhase.connecting,
      loadingSessions: true,
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
    unawaited(_hydrateLiveDomains(client));

    _phaseSub = client.stream.phases.listen((phase) {
      if (!mounted || !identical(_liveClient, client)) return;
      final prev = state.connectionPhase;
      state = state.copyWith(connectionPhase: phase);
      if (phase == ConnectionPhase.connected &&
          (prev == ConnectionPhase.reconnecting ||
              prev == ConnectionPhase.disconnected ||
              prev == ConnectionPhase.error)) {
        unawaited(refreshSessionsList(silent: true));
      }
    });
    _welcomeSub = client.stream.welcomes.listen((welcome) {
      if (!mounted || !identical(_liveClient, client)) return;
      final isReconnect = _hadInitialWelcome;
      _hadInitialWelcome = true;
      _pendingInteractionsById
        ..clear()
        ..addEntries(welcome.pendingInteractions.map((item) => MapEntry(item.id, item)));
      _recomputeVisibleInteractions();
      if (!welcome.resumed) {
        if (isReconnect) {
          unawaited(
            client.getCapabilities().then((nextCaps) {
              if (!mounted || !identical(_liveClient, client)) return;
              state = state.copyWith(liveCapabilities: nextCaps);
            }).catchError((_) {}),
          );
          unawaited(_hydrateLiveDomains(client));
        }
        if (state.activeSessionId != null && !state.activeSessionId!.startsWith('pending-session-')) {
          unawaited(_syncLiveSessionBundle(state.activeSessionId!, jumpToBottomOnLoad: false));
        }
      }
    });
    _streamSub = client.stream.frames.listen((frame) {
      if (!mounted || !identical(_liveClient, client)) return;
      _handleLiveStreamFrame(client, frame);
    });
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

  List<ChatSessionItem> _mapSessionSummaries(List<SessionSummary> liveSessions) {
    final sortedSessions = List<SessionSummary>.of(liveSessions)
      ..sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));
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
            unread: s.id == state.activeSessionId ? false : s.unread,
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
          ? (nextWsList.any((w) => w.name == state.activeWorkspace)
              ? state.activeWorkspace
              : nextWsList.first.name)
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
  }) async {
    try {
      // Stage 0 (Instant Fast Path): ONLY fetch sessions + workspaces first and commit immediately!
      // Never block the sidebar chat list behind slow model/schema/plugin/market endpoints.
      var sessionsFailed = false;
      final fastResults = await Future.wait([
        client.listSessions(includeArchived: true).catchError((_) {
          sessionsFailed = true;
          return const <SessionSummary>[];
        }),
        client.listWorkspaces().catchError((_) => const <String, dynamic>{}),
      ]);
      if (!mounted || !identical(_liveClient, client)) return;

      final liveSessions = fastResults[0] as List<SessionSummary>;
      final workspacesResp = fastResults[1] as Map<String, dynamic>;
      final mappedSessions = _mapSessionSummaries(liveSessions);
      final mappedWs = _mapWorkspacesResp(workspacesResp);

      // Restore per-host view context (last workspace, sidebar filter, and last active session)
      // strictly scoped to `state.activeHostId` so switching Host A <-> Host B feels effortless.
      final savedCtx = _hostContexts[state.activeHostId];
      final savedWs = savedCtx?['lastWorkspace']?.toString() ?? '';
      final savedFilter = savedCtx?['sidebarWorkspaceFilter']?.toString() ?? '';
      final savedSid = savedCtx?['lastSessionId']?.toString() ?? '';

      String resolvedWorkspace = state.activeWorkspace;
      if (mappedWs.isNotEmpty) {
        if (mappedWs.any((w) => w.name == state.activeWorkspace)) {
          resolvedWorkspace = state.activeWorkspace;
        } else if (savedWs.isNotEmpty && mappedWs.any((w) => w.name == savedWs)) {
          resolvedWorkspace = savedWs;
        } else {
          resolvedWorkspace = mappedWs.first.name;
        }
      }
      final resolvedFilter = state.sidebarWorkspaceFilter ??
          (savedFilter.isNotEmpty && mappedWs.any((w) => w.name == savedFilter)
              ? savedFilter
              : null);

      final pendingSid = state.activeSessionId;
      final pendingItem = (pendingSid != null && pendingSid.startsWith('pending-session-'))
          ? state.sessions.where((s) => s.id == pendingSid).firstOrNull
          : null;
      final effectiveSessions =
          (pendingItem != null && !mappedSessions.any((s) => s.id == pendingSid))
              ? [pendingItem, ...mappedSessions]
              : mappedSessions;

      state = state.copyWith(
        sessions: effectiveSessions,
        workspaces: mappedWs,
        activeWorkspace: resolvedWorkspace,
        sidebarWorkspaceFilter: resolvedFilter,
        loadingSessions: false,
      );

      // Restore this host's last open session if it still exists on the host (only when
      // currently on an empty stage after switching hosts, never overriding user navigation).
      if (state.activeSessionId != null) {
        if (!state.activeSessionId!.startsWith('pending-session-')) {
          unawaited(_syncLiveSessionBundle(state.activeSessionId!));
        }
      } else if (attempt == 0 &&
          savedSid.isNotEmpty &&
          mappedSessions.any((s) => s.id == savedSid)) {
        selectSession(savedSid);
      } else if (mappedWs.isNotEmpty) {
        unawaited(loadWorkspaceDirectory(path: '.'));
        unawaited(refreshWorkspaceDiffs(silent: true));
      }

      if (sessionsFailed && attempt == 0 && identical(_liveClient, client)) {
        Future<void>.delayed(const Duration(milliseconds: 1500), () {
          if (mounted && identical(_liveClient, client) && state.sessions.isEmpty) {
            unawaited(refreshSessionsList(silent: true));
          }
        });
      }

      // Stage 1 (Core engine config, models, presets, permissions, account)
      final hydrateModelGen = _modelSelectionGen;
      final coreResults = await Future.wait([
        client.getSettingsSchema().catchError((_) => const <String, dynamic>{}),
        client.getSettingsManifest().catchError((_) => const <String, dynamic>{}),
        client.listPresets().catchError((_) => const <String, dynamic>{}),
        client.getModels().catchError((_) => const <String, dynamic>{}),
        client.getPermissionsCatalog().catchError((_) => const <String, dynamic>{}),
        client.getAccount().catchError((_) => const <String, dynamic>{}),
      ]);
      if (!mounted || !identical(_liveClient, client)) return;

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
        next = next.copyWith(
          modelGroups: groups,
          routableProviders: routable,
        );

        final defObj = rawCatalog['default'];
        final defProv = defObj is Map ? (defObj['provider']?.toString().trim() ?? '') : '';
        final defModelId = defObj is Map ? (defObj['model']?.toString().trim() ?? '') : '';
        final rawDefEff = defObj is Map ? (defObj['reasoningEffort']?.toString().trim() ?? '') : '';

        if (groups.isEmpty) {
          // Model list is genuinely empty -> model selector MUST be empty (never display stale phantom default).
          next = next.copyWith(
            activeModelProvider: '',
            activeModelId: '',
            modelName: '未配置模型',
            modelShort: '未配置',
            modelEffortId: '',
            modelEffort: '',
          );
        } else {
          // Model list is non-empty -> selector MUST resolve to a real available model in `groups`.
          final userUpdatedInFlight = _modelSelectionGen != hydrateModelGen;
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
          activePermissionId:
              (defPreset != null && defPreset.isNotEmpty) ? defPreset : next.activePermissionId,
        );
      }

      // 5. REAL 22+ DSH Schemastery Settings Namespaces
      final desc = schemaResp['description'];
      if (desc is Map<String, dynamic>) {
        final parsedNamespaces = parseDshSettingsNamespaces(desc);
        if (parsedNamespaces.isNotEmpty) {
          next = next.copyWith(dshNamespaces: parsedNamespaces);
          for (final ns in parsedNamespaces) {
            if (ns.ns == 'agent-preset-registry' && ns.value['selectedDefault'] is String) {
              next = next.copyWith(activePresetId: ns.value['selectedDefault'].toString());
            } else if (ns.ns == 'permission' && ns.value['defaultPreset'] is String) {
              next = next.copyWith(activePermissionId: ns.value['defaultPreset'].toString());
            }
          }
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

      // Commit Stage 1 immediately (models, permissions, namespaces, account ready!)
      state = next;

      // Stage 2 (extensions, plugins, providers, automation, speech)
      final extResults = await Future.wait([
        client.listSduiSurfaces().catchError((_) => const <SduiSurfaceMeta>[]),
        client.listPendingInteractions().catchError((_) => const <PendingInteraction>[]),
        client.listPluginBundles().catchError((_) => const <String, dynamic>{}),
        client.listProviders().catchError((_) => const <String, dynamic>{}),
        client.getCredentials().catchError((_) => const <String, dynamic>{}),
        client.listMcpServers().catchError((_) => const <String, dynamic>{}),
        client.listSchedules().catchError((_) => const <String, dynamic>{}),
        client.listJobs().catchError((_) => const <String, dynamic>{}),
        client.listDynamicCordis().catchError((_) => const <String, dynamic>{}),
        client.getSpeechConfig().catchError((_) => const <String, dynamic>{}),
      ]);
      if (!mounted || !identical(_liveClient, client)) return;

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

      // 2. REAL SDUI Surfaces
      next = next.copyWith(
        sduiSurfaces: liveSurfaces,
        speechConfigured: speechResp['configured'] == true,
      );

      // 7. REAL Plugin Bundles
      final mappedPlugins = _parsePluginBundlesResp(bundlesResp);
      next = next.copyWith(plugins: mappedPlugins);

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
      next = next.copyWith(providerCredentials: mappedCreds);

      // 9. REAL MCP Servers (always overwrite — empty means 0 real MCP servers!)
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

      // 11. REAL Schedules, Jobs & Dynamic Cordis (do NOT overwrite marketPlugins with registry index metadata!)
      final rawSched = schedulesResp['schedules'];
      final mappedSched = <ScheduleTaskRecord>[];
      if (rawSched is List) {
        for (final s in rawSched) {
          if (s is! Map) continue;
          mappedSched.add(ScheduleTaskRecord.fromJson(Map<String, dynamic>.from(s)));
        }
      }
      next = next.copyWith(
        schedules: mappedSched,
        jobs: _parseJobsResponse(jobsResp),
        dynamicCordis: _parseDynamicCordisResp(cordisResp),
      );

      state = next;
      _pendingInteractionsById.clear();
      for (final item in pending) {
        _pendingInteractionsById[item.id] = item;
      }
      _recomputeVisibleInteractions();

      if (!skipAutoDefaultSync &&
          autoFallbackModel != null &&
          identical(_liveClient, client) &&
          _modelSelectionGen == hydrateModelGen) {
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
      // empty settings manifest or empty model catalog on the first pass, auto-retry once.
      if (attempt == 0 &&
          (next.dshSettingsSections.isEmpty || next.modelGroups.isEmpty) &&
          identical(_liveClient, client)) {
        Future<void>.delayed(const Duration(milliseconds: 1600), () {
          if (mounted &&
              identical(_liveClient, client) &&
              (state.dshSettingsSections.isEmpty || state.modelGroups.isEmpty)) {
            unawaited(_hydrateLiveDomains(client, attempt: 1));
          }
        });
      }
    } catch (_) {
      if (mounted && identical(_liveClient, client) && state.loadingSessions) {
        state = state.copyWith(loadingSessions: false);
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
      _startAccountSignInPolling(client);

      if (url != null && url.isNotEmpty) {
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
      showToast('正在初始化 DeepSeek 登录会话，请稍候片刻重试', tone: ToastTone.warn);
      return null;
    } catch (e) {
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
        _pendingStreamSubagents != null;
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

    _pendingStreamTelemetry = null;
    _pendingCtxUsedK = null;
    _pendingCtxMaxK = null;
    _pendingCtxPct = null;
    _pendingCtxBreakdown = null;
    _pendingStreamPlanMode = null;
    _pendingStreamTodos = null;
    _pendingStreamSubagents = null;
    _pendingStreamReduced = false;
    _pendingStreamTelemetryChanged = false;
    if (isTurnDone) _lastLiveTpsEmitAt = null;

    final updated = reduced ? _turnReducer.turns : state.turns;
    final streaming = updated.isNotEmpty && updated.last.isStreaming;
    final endedStreaming = isTurnDone || (state.isStreaming && !streaming);
    final finalTelemetry =
        endedStreaming ? nextTelemetry.copyWith(clearLive: true) : nextTelemetry;
    if (endedStreaming) _lastLiveTpsEmitAt = null;
    final sid = state.activeSessionId;
    bool needsRunningClear = false;
    if (endedStreaming && sid != null) {
      for (final s in state.sessions) {
        if (s.id == sid && s.running) {
          needsRunningClear = true;
          break;
        }
      }
    }

    final turnCompletedCleanly =
        endedStreaming && updated.isNotEmpty && updated.last.status == 'completed';
    List<QueuedMessageItem> nextQueued = state.queuedMessages;
    if (turnCompletedCleanly && state.queuedMessages.isNotEmpty) {
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
      contextUsedK: nextCtxUsedK,
      contextMaxK: nextCtxMaxK,
      contextPct: nextCtxPct,
      contextBreakdown: nextCtxBreakdown,
      sessionTelemetry: finalTelemetry,
      planMode: nextPlanMode,
      todos: nextTodos,
      subagents: nextSubagents,
      queuedMessages: nextQueued,
      sessions: needsRunningClear
          ? [
              for (final s in state.sessions)
                s.id == sid ? s.copyWith(running: false) : s,
            ]
          : state.sessions,
      streamTick: (reduced && streaming) ? state.streamTick + 1 : state.streamTick,
    );
    if (endedStreaming && sid != null && _liveClient != null) {
      // Sync updated auto-generated session title, real context usage & workspace diffs
      // WITHOUT forcing a scroll jump if the user scrolled up to read earlier messages!
      unawaited(_syncLiveSessionBundle(sid, jumpToBottomOnLoad: false));
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
          fallbackTurns: _turnReducer.turns,
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
      }

      // Ignore stale in-flight streaming deltas for locally cancelled turns so Stop never resurrects a ghost turn!
      final frameTurnId = data['turnId']?.toString();
      final isFreshTurnStart = type == 'turn.start' ||
          type == 'session.turn_start' ||
          type == 'user.message';
      if (isFreshTurnStart) {
        _cancelSuppressUntilMs = 0;
        if (frameTurnId != null && frameTurnId.isNotEmpty) {
          _locallyCancelledTurnIds.remove(frameTurnId);
        }
      } else if (!state.isStreaming &&
          (type == 'turn.delta' ||
              type == 'text.delta' ||
              type == 'reasoning.delta' ||
              type == 'session.event') &&
          ((frameTurnId != null && _locallyCancelledTurnIds.contains(frameTurnId)) ||
              DateTime.now().millisecondsSinceEpoch < _cancelSuppressUntilMs)) {
        return;
      }

      final reduced = _turnReducer.apply(frame);
      final isTurnDone = type == 'turn.completed' ||
          type == 'turn.end' ||
          type == 'session.turn_end' ||
          type == 'session.stream_end' ||
          type == 'session.stream_error';

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

        // Flush immediately on structural/terminal events or first frame of a stream;
        // coalesce high-frequency text/reasoning/activity/projection deltas into a 24ms (~42Hz)
        // window so bursts of 100+ WS frames/sec never trigger rebuild storms while staying silky!
        final isImmediate = isTurnDone ||
            !state.isStreaming ||
            type == 'turn.start' ||
            type == 'session.turn_start' ||
            type == 'turn.snapshot' ||
            type.contains('tool') ||
            type.contains('action_card') ||
            type.contains('sdui') ||
            type.contains('error');

        if (isImmediate) {
          _flushCoalescedStreamFrame(isTurnDone: isTurnDone);
        } else {
          _streamCoalesceTimer ??= Timer(
            const Duration(milliseconds: 24),
            _flushCoalescedStreamFrame,
          );
        }
      }
    } else if (type == 'interaction.requested') {
      final parsed = PendingInteraction.fromJson(data);
      _applyPendingInteraction(parsed);
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
        ),
      );
    } else if (type == 'interaction.resolved') {
      final id = data['id']?.toString();
      if (id == null) {
        _pendingInteractionsById.clear();
      } else {
        _pendingInteractionsById.remove(id);
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
            state = state.copyWith(
              sessions: [
                for (final s in state.sessions)
                  s.id == targetSid ? s.copyWith(running: isRunning) : s,
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
      } else if (type == 'host.ready' ||
          type == 'session.added' ||
          type == 'session.removed' ||
          type == 'session.deleted' ||
          type == 'session.renamed') {
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
      } else if (type == 'job.event') {
        final status = (data['status'] ?? data['state'])?.toString();
        if (status != null && status.isNotEmpty) {
          state = state.copyWith(
            jobs: [
              for (final j in state.jobs)
                j.id == jobId ? j.copyWith(status: status) : j,
            ],
          );
        }
        if (status == 'completed' || status == 'failed' || status == 'killed' || status == 'exited') {
          unawaited(refreshJobs(silent: true));
        }
      }
    }
  }

  void _applyPendingInteraction(PendingInteraction item) {
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
        final cleanUri = uri.replace(queryParameters: null);
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
    String packageSpec = 'dsh-gbridge',
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

    final cleanUri = uri.replace(queryParameters: null);
    final token = host.token ?? uri.queryParameters['token'];
    final client = GbridgeClient(
      HostEndpoint.http(
        baseUri: cleanUri,
        token: token,
        cookie: host.sessionCookie,
      ),
      timeout: const Duration(seconds: 20),
      allowBadCertificates: host.allowBadCertificates,
      onCookieUpdated: (c) => _persistHostCookie(host.id, c),
    );
    try {
      if (!host.hasSavedCookie && token != null && token.isNotEmpty) {
        try {
          await client.exchangeAuthToken(token);
        } catch (_) {}
      }
      final caps = await client.bootstrap.installHelperBundle(
        packageSpec: packageSpec.trim().isEmpty ? 'dsh-gbridge' : packageSpec.trim(),
        registryUrl: registryUrl,
        pollTimeout: const Duration(seconds: 35),
      );
      if (!mounted) {
        await client.dispose();
        return;
      }
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
        await _bindFullLiveClient(client, hostId, caps, gen: gen, isDirect: false);
      } else {
        // Never hijack activeHostId or wipe the user's current conversation when upgrading a background host!
        await client.dispose();
      }
      showToast('${host.name} 已升级为增强模式（助手已就绪）');
    } catch (e) {
      await client.dispose();
      if (!mounted) return;
      final readable = formatReadableError(e);
      state = state.copyWith(
        hosts: [
          for (final h in state.hosts)
            h.id == hostId ? h.copyWith(installing: false, bridged: false, lastError: readable) : h,
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
  }) {
    final parsed = parseRemoteHostInput(address, explicitToken: token);
    if (parsed == null) {
      showToast('请输入有效地址，或直接粘贴 `dsh web: http://...` 链接', tone: ToastTone.warn);
      return null;
    }
    final parsedUri = Uri.tryParse(parsed.address);
    if (parsedUri != null) {
      final selfMsg = selfDeviceGuidanceForUri(parsedUri);
      if (selfMsg != null) {
        showToast(selfMsg, tone: ToastTone.info);
        return null;
      }
    }
    final cleanCookie = (cookie != null && cookie.trim().isNotEmpty) ? cookie.trim() : null;
    // Deduplicate if a remote host with the exact same normalized address already exists.
    final existing = state.hosts
        .where((h) => !h.isLocal && h.address.toLowerCase() == parsed.address.toLowerCase())
        .firstOrNull;
    if (existing != null) {
      final merged = existing.copyWith(
        name: (name != null && name.trim().isNotEmpty) ? name.trim() : existing.name,
        allowBadCertificates: allowBadCertificates || existing.allowBadCertificates,
        token: (parsed.token != null && parsed.token!.isNotEmpty) ? parsed.token : existing.token,
        sessionCookie: cleanCookie ?? existing.sessionCookie,
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
      }
      showToast('已更新已有远程主机「${merged.name}」', tone: ToastTone.info);
      if (autoProbe) {
        unawaited(_probeHostOnly(merged));
      }
      return merged;
    }
    final id = 'rem-${DateTime.now().millisecondsSinceEpoch}';
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
    showToast(
      created.isInsecurePublicHttp
          ? '已添加公网明文 HTTP 主机，建议升级为 HTTPS 以保护会话凭证'
          : (parsed.wasAutoPorted
              ? '已自动补全 :3080 端口，正在免插件探测连接…'
              : '已添加远程主机，正在探测连接…'),
      tone: created.isInsecurePublicHttp ? ToastTone.warn : ToastTone.ok,
    );
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
    final updated = target.copyWith(
      name: nextName,
      address: nextAddr,
      allowBadCertificates: allowBadCertificates ?? target.allowBadCertificates,
      token: extractedToken != null && extractedToken.isNotEmpty ? extractedToken : target.token,
      clearLastError: true,
    );
    state = state.copyWith(
      hosts: [for (final h in state.hosts) h.id == hostId ? updated : h],
    );
    _persistHosts();
    if (extractedToken != null && extractedToken.isNotEmpty) {
      unawaited(GrassBagNativeBridge.instance.putSecret('host_token_$hostId', extractedToken));
    }
    showToast('已更新主机「${updated.name}」配置');
    if (state.activeHostId == hostId) {
      await switchHost(hostId);
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
    // Allow pasting an entire `dsh web: http://.../?token=...` line directly into the token sheet!
    final parsedFromLine = raw.contains('://') || raw.contains('token=')
        ? parseRemoteHostInput(raw)
        : null;
    final cleanToken = parsedFromLine?.token ?? raw;
    final target = state.hosts.where((h) => h.id == hostId).firstOrNull;
    if (target == null) return;
    final updated = target.copyWith(
      token: cleanToken.isEmpty ? null : cleanToken,
      clearToken: cleanToken.isEmpty,
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
    if (state.activeHostId == hostId) {
      showToast('已更新访问令牌，正在重新连接 ${updated.name}…', tone: ToastTone.info);
      await switchHost(hostId, awaitConnect: awaitConnect);
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
    final updated = target.copyWith(clearSessionCookie: true);
    state = state.copyWith(
      hosts: [
        for (final h in state.hosts) h.id == hostId ? updated : h,
      ],
    );
    unawaited(GrassBagNativeBridge.instance.deleteSecret('host_cookie_$hostId'));
    showToast('已清除「${target.name}」的缓存登录凭证', tone: ToastTone.info);
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
    );
    unawaited(GrassBagNativeBridge.instance.setExecutorMode(nativeKey));
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
  }) {
    state = state.copyWith(
      phoneAccessibility: accessibility,
      phoneOverlay: overlay,
      phoneShizuku: shizuku,
      phoneConfirmHighRisk: confirmHighRisk,
    );
    if (confirmHighRisk != null) {
      _persistPrefs();
      if (GrassBagNativeBridge.instance.isAndroidNative) {
        unawaited(GrassBagNativeBridge.instance.setSafetyConfirmHighRisk(confirmHighRisk));
      }
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

  Future<void> triggerEmergencyStop() async {
    await GrassBagNativeBridge.instance.triggerEmergencyStop();
    state = state.copyWith(emergencyStopped: true);
    cancelStreaming();
    await refreshNativeStatus();
    showToast('已触发紧急急停，所有操控与生成已立即中止', tone: ToastTone.warn);
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
    final res = await _appUpdateService.fetchLatestRelease();
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

  Future<void> downloadAndInstallAppUpdate() async {
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

    // Web or non-Android hosts open the direct APK download in browser.
    if (!GrassBagNativeBridge.instance.isAndroidNative) {
      await _openExternalLink(downloadUrl);
      return;
    }

    // Reuse already-downloaded APK if user just returned from granting "Install unknown apps".
    final existingPath = state.appUpdateLocalApkPath;
    if (existingPath != null && existingPath.isNotEmpty) {
      final installRes = await GrassBagNativeBridge.instance.installApk(existingPath);
      if (!mounted) return;
      if (installRes == 'started') {
        showToast('已拉起系统安装器', tone: ToastTone.ok);
        return;
      }
      if (installRes == 'permission_required') {
        showToast('请先开启「允许安装未知来源应用」，返回后点击立即安装', tone: ToastTone.warn);
        return;
      }
      // File may have been evicted from cache: fall through to fresh download.
      state = state.copyWith(clearAppUpdateLocalApkPath: true);
    }

    if (state.appUpdateDownloading) return;
    final updatesDir = await GrassBagNativeBridge.instance.getUpdatesCacheDir();
    if (!mounted) return;
    if (updatesDir == null || updatesDir.isEmpty) {
      await _openExternalLink(downloadUrl);
      return;
    }

    final safeKey = release.versionKey.replaceAll(RegExp(r'[^0-9A-Za-z._-]+'), '_');
    final destPath = '$updatesDir/grassbag-$safeKey.apk';
    _appUpdateDownloadCancelled = false;
    _lastDownloadProgressEmit = null;
    state = state.copyWith(
      appUpdateDownloading: true,
      appUpdateDownloadProgress: 0.0,
      appUpdateDownloadBytes: 0,
      appUpdateTotalBytes: release.apkSizeBytes ?? 0,
      clearAppUpdateError: true,
    );

    try {
      final savedPath = await _appUpdateService.downloadApk(
        downloadUrl: downloadUrl,
        destinationPath: destPath,
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
      if (!mounted) return;
      state = state.copyWith(
        appUpdateDownloading: false,
        appUpdateDownloadProgress: 1.0,
        appUpdateLocalApkPath: savedPath,
      );
      final installRes = await GrassBagNativeBridge.instance.installApk(savedPath);
      if (!mounted) return;
      if (installRes == 'started') {
        showToast('安装包已就绪，正在拉起系统安装器', tone: ToastTone.ok);
      } else if (installRes == 'permission_required') {
        showToast('已跳转系统授权页：请允许 GrassBag 安装应用后返回继续安装', tone: ToastTone.warn);
      } else {
        showToast('拉起安装器失败，已为你保留安装包，可尝试从 Release 页面安装', tone: ToastTone.warn);
      }
    } on AppUpdateDownloadCancelledException {
      if (!mounted) return;
      state = state.copyWith(
        appUpdateDownloading: false,
        clearAppUpdateDownloadProgress: true,
      );
      showToast('已取消安装包下载', tone: ToastTone.info);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        appUpdateDownloading: false,
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
    _jobOutputFlushTimer?.cancel();
    _engineLogFlushTimer?.cancel();
    _hostSessionsRefreshTimer?.cancel();
    _domainRefreshTimer?.cancel();
    _drawerSearchTimer?.cancel();
    _accountPollTimer?.cancel();
    _persistPrefsTimer?.cancel();
    _persistHostsTimer?.cancel();
    _persistHostContextsTimer?.cancel();
    _appUpdateTimer?.cancel();
    _appUpdateDownloadCancelled = true;
    final nativeSub = _nativeSub;
    _nativeSub = null;
    if (nativeSub != null) {
      unawaited(nativeSub.cancel().catchError((_) {}));
    }
    unawaited(_disconnectLiveClients());
    super.dispose();
  }
}

final appProvider = StateNotifierProvider<GrassBagController, GrassBagAppState>(
  (ref) => GrassBagController(),
);
