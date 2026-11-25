import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import '../common/remote_host_connect_card.dart';
import '../features/sdui_extensions_page.dart';
import '../web/deepseek_signin_page.dart';
import '../web/official_web_page.dart';
import '../web/remote_web_login_page.dart';
import '../web/web_embed.dart';
import 'app_update_sheet.dart';
import 'dsh_dynamic_sections.dart';
import 'dsh_settings_sheets.dart';
import 'model_config_view.dart';
import 'permissions_center_page.dart';
import 'phone_control_view.dart';

enum SettingsSection {
  account('账号与余额', 'account'),
  general('通用与对话', 'general'),
  model('模型与渠道', 'models'),
  webSearch('联网搜索与抓取', 'web-search'),
  agentRuntime('智能体与终端', 'agent-runtime'),
  mcp('MCP 工具服务', 'mcp'),
  plugins('插件与扩展', 'plugins'),
  hosts('本机与远程主机', 'hosts'),
  local('本机环境与更新', 'local'),
  appearance('外观与主题', 'appearance'),
  permissions('权限管理', 'permissions'),
  phone('操控手机', 'phone'),
  diagnostics('运行诊断', 'diagnostics'),
  about('关于与更新', 'about'),
  webui('官方网页版', 'webui');

  const SettingsSection(this.title, this.manifestId);
  final String title;
  final String manifestId;

  static SettingsSection? fromManifestId(String id) {
    for (final v in SettingsSection.values) {
      if (v.manifestId == id) return v;
    }
    return null;
  }
}

/// Natural Chinese & English keyword alias map so searching e.g. "无障碍", "代理", "中转",
/// "Base URL", "备份", "电池", "Token" or "深色" always locates the right Settings section.
const Map<SettingsSection, String> kSettingsSearchAliases = {
  SettingsSection.account: 'deepseek 账号 登录 余额 充值 account balance sign in',
  SettingsSection.general: '通用 对话 权限 审批 预设 角色 折叠 preset permission language locale',
  SettingsSection.model: '模型 渠道 中转 聚合 base url api key 密钥 openai claude gemini deepseek 思考深度 model provider',
  SettingsSection.webSearch: '联网 搜索 抓取 网页 web search fetch tavily brave exa',
  SettingsSection.agentRuntime: '子代理 子智能体 并发 循环 终端 沙箱 subagent sandbox bash loop',
  SettingsSection.mcp: 'mcp 工具 服务器 协议 stdio sse http server',
  SettingsSection.plugins: '插件 市场 扩展 模块 cordis plugin market',
  SettingsSection.hosts: '主机 远程 本机 容器 引擎 局域网 代理 proxy 备份 backup token 证书 桌面端 ubuntu dsh proot tawcroot',
  SettingsSection.local: '本机 容器 更新 备份 代理 缓存 槽位 分区 ubuntu dsh proot tawcroot backup proxy',
  SettingsSection.appearance: '外观 主题 深色 浅色 夜间 液态 玻璃 配色 字体 dark light glass theme accent',
  SettingsSection.permissions: '权限 无障碍 受限设置 电池 保活 悬浮窗 存储 sdcard 麦克风 通知 shizuku accessibility battery overlay storage',
  SettingsSection.phone: '操控 手机 自动化 安全护栏 急停 无障碍 safetygate phone control accessibility',
  SettingsSection.diagnostics: '诊断 日志 报错 告警 接口 模块 源码 log error diagnostics schema sdui',
  SettingsSection.about: '关于 更新 新版本 检查更新 版本号 apk release github changelog update version about',
  SettingsSection.webui: '官方 网页 web 浏览器',
};

/// Returns whether [section] matches a user search query by title, live summary,
/// group heading, or natural Chinese/English keyword aliases.
bool settingsSectionMatchesQuery(
  SettingsSection section, {
  required String title,
  required String summary,
  required String groupTitle,
  required String rawQuery,
}) {
  final q = rawQuery.trim().toLowerCase();
  if (q.isEmpty) return true;
  final aliases = kSettingsSearchAliases[section] ?? '';
  final haystack = '${title.toLowerCase()} ${summary.toLowerCase()} ${groupTitle.toLowerCase()} $aliases';
  final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
  return tokens.every(haystack.contains);
}

/// Unified Settings Page:
/// - Phone (`< 840dp`): clean single-column list drilling into unified-header subpages
/// - Tablet (`>= 840dp`): authentic iPadOS/macOS two-pane Split-View!
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({
    super.key,
    this.initialSection,
    this.initialHostDetailId,
    required this.onOpenWebUi,
  });

  final SettingsSection? initialSection;
  final String? initialHostDetailId;
  final VoidCallback onOpenWebUi;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late SettingsSection _selected;
  String? _hostDetailId;
  int _paneDirection = 0;
  final ValueNotifier<String> _queryNotifier = ValueNotifier<String>('');
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selected = widget.initialSection ?? SettingsSection.account;
    _hostDetailId = widget.initialHostDetailId ??
        (widget.initialSection == SettingsSection.local ? 'local' : null);
    if (widget.initialSection == SettingsSection.webui) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isTablet(context)) return;
        widget.onOpenWebUi();
      });
    }
  }

  @override
  void dispose() {
    _queryNotifier.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _isTablet(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width >= 840 && size.height >= 480;
  }

  void _selectSection(SettingsSection section) {
    if (_isTablet(context)) {
      if (section == SettingsSection.webui) {
        widget.onOpenWebUi();
        return;
      }
      setState(() {
        _paneDirection = 0;
        _selected = section;
        _hostDetailId = section == SettingsSection.local ? 'local' : null;
      });
    } else {
      if (section == SettingsSection.webui) {
        widget.onOpenWebUi();
        return;
      }
      Navigator.of(context).push(
        GrassBagPageRoute<void>(
          builder: (_) => _PhoneSettingsSubpage(
            section: section,
            initialHostDetailId: section == SettingsSection.local ? 'local' : null,
            onOpenWebUi: widget.onOpenWebUi,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          hosts: s.hosts,
          activeHostId: s.activeHostId,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final t = GrassBagTokens.of(context);
    final isTab = _isTablet(context);

    // On Phone, render deep-linked subpages directly on Frame 0 instead of pushing a second
    // route in a post-frame callback (eliminates the jarring root-Settings list flash!).
    if (!isTab &&
        (widget.initialSection != null || widget.initialHostDetailId != null) &&
        widget.initialSection != SettingsSection.webui) {
      final targetSection = widget.initialSection ?? SettingsSection.hosts;
      return _PhoneSettingsSubpage(
        section: targetSection,
        initialHostDetailId: widget.initialHostDetailId ??
            (targetSection == SettingsSection.local ? 'local' : null),
        onOpenWebUi: widget.onOpenWebUi,
      );
    }

    if (isTab) {
      final detailHost = _hostDetailId != null
          ? state.hosts.where((h) => h.id == _hostDetailId).firstOrNull
          : null;
      final rightTitle = (_selected == SettingsSection.hosts && detailHost != null)
          ? (detailHost.isLocal ? '本机环境' : detailHost.name)
          : _selected.title;

      return GrassBagGlassPage(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              Row(
                children: [
                  // Left Settings Navigation Column — grounded Graphite-Slate / Porcelain veil
                  Container(
                    width: 324,
                    decoration: BoxDecoration(
                      color: t.sidebarDocked,
                      border: Border(right: BorderSide(color: t.sep, width: 0.5)),
                    ),
                    child: Column(
                      children: [
                        GrassBagUnifiedHeader(
                          title: '设置',
                          tier: state.glassTier,
                          floating: false,
                          onBack: () => Navigator.of(context).pop(),
                        ),
                        Expanded(
                          child: ValueListenableBuilder<String>(
                            valueListenable: _queryNotifier,
                            builder: (_, query, __) => _SettingsNavList(
                              isSplit: true,
                              selected: _selected,
                              query: query,
                              searchCtrl: _searchCtrl,
                              onQueryChanged: (q) => _queryNotifier.value = q,
                              onSelect: _selectSection,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Right Live Secondary Detail View
                  Expanded(
                    child: Column(
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            24,
                            MediaQuery.viewPaddingOf(context).top + 12,
                            24,
                            12,
                          ),
                          child: SizedBox(
                            height: 44,
                            child: Row(
                              children: [
                                if (detailHost != null && _selected == SettingsSection.hosts) ...[
                                  GrassBagGlassCircleButton(
                                    icon: CupertinoIcons.chevron_back,
                                    size: 36,
                                    iconSize: 17,
                                    tier: state.glassTier,
                                    onTap: () {
                                      setState(() {
                                        _paneDirection = -1;
                                        _hostDetailId = null;
                                      });
                                    },
                                  ),
                                  const SizedBox(width: 10),
                                ],
                                Expanded(
                                  child: GrassBagDirectionalTabSwitcher(
                                    direction: _paneDirection,
                                    duration: const Duration(milliseconds: 160),
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      rightTitle,
                                      key: ValueKey('settings-title-$rightTitle'),
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -0.3,
                                        color: t.text,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          // Per-pane SingleChildScrollView inside the switcher prevents outgoing
                          // content from jumping to scroll offset 0 mid-fade!
                          child: GrassBagDirectionalTabSwitcher(
                            direction: _paneDirection,
                            duration: const Duration(milliseconds: 180),
                            child: SingleChildScrollView(
                              key: PageStorageKey('settings-pane-${_selected.name}-${_hostDetailId ?? ''}'),
                              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                              padding: EdgeInsets.fromLTRB(
                                24,
                                8,
                                24,
                                40 + MediaQuery.viewPaddingOf(context).bottom,
                              ),
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 620),
                                  child: _SettingsDetailBody(
                                    section: _selected,
                                    hostDetailId: _hostDetailId,
                                    onSelectHostDetail: (id) {
                                      setState(() {
                                        _paneDirection = 1;
                                        _hostDetailId = id;
                                      });
                                    },
                                    onHostRemoved: () {
                                      setState(() {
                                        _paneDirection = -1;
                                        _hostDetailId = null;
                                      });
                                    },
                                    onOpenSection: _selectSection,
                                    onOpenWebUi: widget.onOpenWebUi,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const GrassBagToastOverlay(bottomOffset: 28),
            ],
          ),
        ),
      );
    }

    // Phone Single-Column Settings: scrolled content passes directly beneath the floating
    // Liquid Glass header pills for live refraction, while GrassBagUnifiedHeader caps the status bar.
    final topPad = MediaQuery.viewPaddingOf(context).top;
    return GrassBagGlassPage(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(
              child: ValueListenableBuilder<String>(
                valueListenable: _queryNotifier,
                builder: (_, query, __) => _SettingsNavList(
                  isSplit: false,
                  selected: _selected,
                  query: query,
                  searchCtrl: _searchCtrl,
                  topInsetPadding: topPad + 78,
                  onQueryChanged: (q) => _queryNotifier.value = q,
                  onSelect: _selectSection,
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GrassBagUnifiedHeader(
                title: '设置',
                tier: state.glassTier,
                onBack: () => Navigator.of(context).pop(),
              ),
            ),
            const GrassBagToastOverlay(bottomOffset: 28),
          ],
        ),
      ),
    );
  }
}

class _PhoneSettingsSubpage extends ConsumerStatefulWidget {
  const _PhoneSettingsSubpage({
    required this.section,
    this.initialHostDetailId,
    required this.onOpenWebUi,
  });

  final SettingsSection section;
  final String? initialHostDetailId;
  final VoidCallback onOpenWebUi;

  @override
  ConsumerState<_PhoneSettingsSubpage> createState() => _PhoneSettingsSubpageState();
}

class _PhoneSettingsSubpageState extends ConsumerState<_PhoneSettingsSubpage> {
  String? _hostDetailId;
  int _drillDir = 1;

  @override
  void initState() {
    super.initState();
    _hostDetailId = widget.initialHostDetailId;
  }

  void _setHostDetailId(String? id) {
    if (_hostDetailId == id) return;
    setState(() {
      _drillDir = id != null ? 1 : -1;
      _hostDetailId = id;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          hosts: s.hosts,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final topPad = MediaQuery.viewPaddingOf(context).top;
    final botPad = MediaQuery.viewPaddingOf(context).bottom;
    final host = _hostDetailId != null
        ? state.hosts.where((h) => h.id == _hostDetailId).firstOrNull
        : null;
    final title = (widget.section == SettingsSection.hosts && host != null)
        ? (host.isLocal ? '本机环境' : host.name)
        : widget.section.title;

    final canPopDirect = _hostDetailId == null || widget.section != SettingsSection.hosts;
    return PopScope(
      canPop: canPopDirect,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _hostDetailId != null && widget.section == SettingsSection.hosts) {
          _setHostDetailId(null);
        }
      },
      child: GrassBagGlassPage(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              Positioned.fill(
                child: GrassBagDirectionalTabSwitcher(
                  direction: _drillDir,
                  duration: const Duration(milliseconds: 180),
                  child: SingleChildScrollView(
                    key: PageStorageKey('phone-settings-${widget.section.name}-${_hostDetailId ?? ''}'),
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    padding: EdgeInsets.fromLTRB(16, topPad + 78, 16, 44 + botPad),
                    child: _SettingsDetailBody(
                      section: widget.section,
                      hostDetailId: _hostDetailId,
                      onSelectHostDetail: _setHostDetailId,
                      onHostRemoved: () => _setHostDetailId(null),
                      onOpenSection: (sec) {
                        if (sec == SettingsSection.webui) {
                          widget.onOpenWebUi();
                          return;
                        }
                        Navigator.of(context).push(
                          GrassBagPageRoute<void>(
                            builder: (_) => _PhoneSettingsSubpage(
                              section: sec,
                              initialHostDetailId: sec == SettingsSection.local ? 'local' : null,
                              onOpenWebUi: widget.onOpenWebUi,
                            ),
                          ),
                        );
                      },
                      onOpenWebUi: widget.onOpenWebUi,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GrassBagUnifiedHeader(
                  title: title,
                  tier: state.glassTier,
                  onBack: () {
                    if (_hostDetailId != null && widget.section == SettingsSection.hosts) {
                      _setHostDetailId(null);
                    } else {
                      Navigator.of(context).pop();
                    }
                  },
                ),
              ),
              const GrassBagToastOverlay(bottomOffset: 28),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsNavList extends ConsumerWidget {
  const _SettingsNavList({
    required this.isSplit,
    required this.selected,
    required this.query,
    required this.searchCtrl,
    this.topInsetPadding = 6,
    required this.onQueryChanged,
    required this.onSelect,
  });

  final bool isSplit;
  final SettingsSection selected;
  final String query;
  final TextEditingController searchCtrl;
  final double topInsetPadding;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<SettingsSection> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          isDark: s.isDark,
          accent: s.accent,
          hosts: s.hosts,
          activeHostId: s.activeHostId,
          connectionPhase: s.connectionPhase,
          hydratingDomains: s.hydratingDomains,
          dshNamespaces: s.dshNamespaces,
          dshSettingsSections: s.dshSettingsSections,
          presets: s.presets,
          permissionTiers: s.permissionTiers,
          activePresetId: s.activePresetId,
          activePermissionId: s.activePermissionId,
          modelName: s.modelName,
          activeModelId: s.activeModelId,
          hasAvailableModels: s.hasAvailableModels,
          plugins: s.plugins,
          mcpServers: s.mcpServers,
          recentErrors: s.recentErrors,
          liveCapabilities: s.liveCapabilities,
          accountSnapshot: s.accountSnapshot,
          providerCredentials: s.providerCredentials,
          routableProvidersCount: s.routableProviders.length,
          nativeRuntimeStatus: s.nativeRuntimeStatus,
          nativePermissions: s.nativePermissions,
          phoneAccessibility: s.phoneAccessibility,
          phoneOverlay: s.phoneOverlay,
          phoneShizuku: s.phoneShizuku,
          appVersionLabel: s.appVersionLabel,
          hasAppUpdate: s.hasAppUpdate,
          hasUnignoredAppUpdate: s.hasUnignoredAppUpdate,
          appUpdateVersion: s.appUpdateInfo?.versionName,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final t = GrassBagTokens.of(context);
    final local = state.localHost;
    final curHost = state.activeHost;
    final q = query.trim().toLowerCase();
    final nsMap = {for (final n in state.effectiveDshNamespaces) n.ns: n};

    // Build dynamic DSH menu items directly from `GET /gbridge/v1/settings/manifest`!
    final manifestSections = state.dshSettingsSections;
    final dynamicDshCore = <(SettingsSection, IconData, Color, String, String, bool)>[];
    final dynamicDshCaps = <(SettingsSection, IconData, Color, String, String, bool)>[];

    String liveSummaryFor(SettingsSection sec) {
      return switch (sec) {
        SettingsSection.general => '${state.activePreset.name} · ${state.activePermission.name}',
        SettingsSection.model => (state.isDshConnected &&
                !state.hydratingDomains &&
                !state.hasAvailableModels &&
                state.routableProviders.isEmpty)
            ? '去配置'
            : (state.hydratingDomains && !state.hasAvailableModels
                ? '同步中…'
                : (state.effectiveActiveModelEntry?.name ??
                    (state.modelName.isEmpty ? '未配置' : state.modelName))),
        SettingsSection.webSearch => () {
            final sp = nsMap['web']?.value['searchProvider']?.toString() ?? '';
            return sp.isNotEmpty ? sp : '按需配置';
          }(),
        SettingsSection.agentRuntime => () {
            final depth = nsMap['subagent']?.value['maxDepth'];
            final par = nsMap['agent-loop']?.value['maxParallelToolCalls'];
            if (depth != null || par != null) {
              return '深度 ${depth ?? '-'} · 并发 ${par ?? '-'}';
            }
            return '子代理与终端';
          }(),
        SettingsSection.mcp => () {
            final cfgCount = (nsMap['mcp-manager']?.value['servers'] as Map?)?.length ?? 0;
            final liveCount = state.mcpServers.length;
            final total = liveCount > cfgCount ? liveCount : cfgCount;
            return total > 0 ? '$total 个服务' : '未配置';
          }(),
        SettingsSection.plugins => state.plugins.isEmpty
            ? '插件市场'
            : '已启用 ${state.plugins.where((p) => p.enabled).length} 个',
        _ => '',
      };
    }

    (IconData, Color) visualFor(SettingsSection sec) => switch (sec) {
          SettingsSection.general => (
              CupertinoIcons.chat_bubble_2_fill,
              t.isDark ? const Color(0xFF7FA3F2) : const Color(0xFF425EA8),
            ),
          SettingsSection.model => (
              CupertinoIcons.sparkles,
              t.primary,
            ),
          SettingsSection.webSearch => (
              CupertinoIcons.globe,
              t.isDark ? const Color(0xFF56C2B2) : const Color(0xFF2D746D),
            ),
          SettingsSection.agentRuntime => (
              CupertinoIcons.person_2_fill,
              t.isDark ? const Color(0xFF4AC885) : const Color(0xFF1F9D63),
            ),
          SettingsSection.mcp => (
              CupertinoIcons.antenna_radiowaves_left_right,
              t.isDark ? const Color(0xFFF0B24C) : const Color(0xFFB86C11),
            ),
          SettingsSection.plugins => (
              CupertinoIcons.square_stack_3d_up_fill,
              t.isDark ? const Color(0xFFA993DE) : const Color(0xFF6B5B8E),
            ),
          _ => (CupertinoIcons.slider_horizontal_3, t.text2),
        };

    bool needsBadgeFor(SettingsSection sec) =>
        sec == SettingsSection.model &&
        state.isDshConnected &&
        !state.hydratingDomains &&
        !state.hasAvailableModels &&
        state.routableProviders.isEmpty;

    if (manifestSections.isNotEmpty) {
      for (final ms in manifestSections) {
        if (ms.id == 'account') continue; // Represented by top Hero Card
        final sec = SettingsSection.fromManifestId(ms.id);
        if (sec == null) continue;
        final vis = visualFor(sec);
        final item = (sec, vis.$1, vis.$2, ms.title, liveSummaryFor(sec), needsBadgeFor(sec));
        if (ms.group == 'dsh') {
          dynamicDshCore.add(item);
        } else {
          dynamicDshCaps.add(item);
        }
      }
    } else {
      // Offline / pre-hydration defaults matching DSH WebUI sections
      for (final sec in const [SettingsSection.general, SettingsSection.model]) {
        final vis = visualFor(sec);
        dynamicDshCore.add((sec, vis.$1, vis.$2, sec.title, liveSummaryFor(sec), needsBadgeFor(sec)));
      }
      for (final sec in const [
        SettingsSection.webSearch,
        SettingsSection.agentRuntime,
        SettingsSection.mcp,
        SettingsSection.plugins,
      ]) {
        final vis = visualFor(sec);
        dynamicDshCaps.add((sec, vis.$1, vis.$2, sec.title, liveSummaryFor(sec), false));
      }
    }

    final perms = state.nativePermissions;
    final deviceItems = <(SettingsSection, IconData, Color, String, String, bool)>[
      (
        SettingsSection.hosts,
        CupertinoIcons.tray_2_fill,
        local.hasLocalUpdates
            ? (t.isDark ? const Color(0xFFF0B24C) : const Color(0xFFB86C11))
            : (t.isDark ? const Color(0xFF63B4E4) : const Color(0xFF236185)),
        '本机与远程主机',
        curHost.needsAuth
            ? '待授权'
            : (curHost.lastError != null
                ? '连接异常'
                : (local.hasLocalUpdates
                    ? '本机可更新 v${local.dshLatest}'
                    : (curHost.isLocal && GrassBagNativeBridge.instance.isAndroidNative
                        ? state.hostStatusBadge(local)
                        : '${curHost.name} · ${state.hosts.length} 台'))),
        (!curHost.isConnectedUsable && !curHost.needsAuth) ||
            state.hostHasError(curHost) ||
            local.hasLocalUpdates ||
            (GrassBagNativeBridge.instance.isAndroidNative && !state.nativeRuntimeStatus.initialized),
      ),
      (
        SettingsSection.appearance,
        CupertinoIcons.paintbrush_fill,
        t.isDark ? const Color(0xFF8C98F2) : const Color(0xFF535EC0),
        '外观与主题',
        '${state.accent.label} · ${state.glassTier.label}',
        false,
      ),
      if (GrassBagNativeBridge.instance.isAndroidNative) ...[
        (
          SettingsSection.permissions,
          CupertinoIcons.checkmark_shield_fill,
          perms.accessibilityNeedsRetoggle
              ? t.err
              : (t.isDark ? const Color(0xFF4AC885) : const Color(0xFF1F9D63)),
          '权限管理',
          perms.accessibilityNeedsRetoggle
              ? '无障碍未绑定'
              : '${perms.grantedCoreCount}/6 已授权',
          perms.accessibilityNeedsRetoggle || !perms.accessibilityEnabled,
        ),
        (
          SettingsSection.phone,
          CupertinoIcons.device_phone_portrait,
          t.isDark ? const Color(0xFF56C2B2) : const Color(0xFF2D746D),
          '操控手机',
          perms.accessibilityEnabled
              ? '无障碍可用'
              : (perms.accessibilityNeedsRetoggle ? '需重开无障碍' : '未授权'),
          perms.accessibilityNeedsRetoggle,
        ),
      ],
      (
        SettingsSection.diagnostics,
        CupertinoIcons.waveform_path_ecg,
        t.isDark ? const Color(0xFF64B0EB) : const Color(0xFF2B7FC3),
        '运行诊断',
        state.recentErrors.isNotEmpty
            ? '${state.recentErrors.length} 条告警'
            : (state.liveCapabilities != null
                ? '${state.liveCapabilities!.endpointsCount} 项接口正常'
                : '未连接'),
        state.recentErrors.isNotEmpty || state.liveCapabilities == null,
      ),
      (
        SettingsSection.about,
        CupertinoIcons.arrow_down_circle_fill,
        t.primary,
        '关于与更新',
        state.hasAppUpdate && state.appUpdateInfo != null
            ? '发现 v${state.appUpdateInfo!.versionName}'
            : 'v${state.appVersionLabel}',
        state.hasUnignoredAppUpdate,
      ),
      (
        SettingsSection.webui,
        CupertinoIcons.macwindow,
        t.isDark ? const Color(0xFF56C2B2) : const Color(0xFF2D746D),
        '官方网页版',
        '完整 Web 界面',
        false,
      ),
    ];

    final groups = [
      if (dynamicDshCore.isNotEmpty) ('DSH 核心设置', dynamicDshCore),
      if (dynamicDshCaps.isNotEmpty) ('DSH 能力与扩展', dynamicDshCaps),
      ('连接与本机', deviceItems),
    ];

    final accountSearchHaystack =
        '${kSettingsSearchAliases[SettingsSection.account]} ${state.accountSummaryLabel}'.toLowerCase();
    final accountTokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    final accountMatchesSearch = q.isEmpty || accountTokens.every(accountSearchHaystack.contains);

    final hasAnySearchHit = q.isEmpty ||
        accountMatchesSearch ||
        groups.any(
          (g) => g.$2.any(
            (it) => settingsSectionMatchesQuery(
              it.$1,
              title: it.$4,
              summary: it.$5,
              groupTitle: g.$1,
              rawQuery: q,
            ),
          ),
        );

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        topInsetPadding,
        16,
        40 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      children: [
        // Native iOS 26 Search Bar (solid fill inside scrollable list -> zero live BackdropFilter readback!)
        GrassBagGlassSearchBar(
          controller: searchCtrl,
          placeholder: '搜索设置（如 无障碍、代理、中转、深色）',
          tier: state.glassTier,
          insideGlass: true,
          onChanged: onQueryChanged,
        ),
        const SizedBox(height: 16),

        // Translucent iOS 26/27 Account & Host Overview Hero Card (zero scroll BackdropFilter!)
        if (accountMatchesSearch) ...[
          GrassBagSpringTap(
            onTap: () => onSelect(SettingsSection.account),
            pressedScale: 0.98,
            haptic: true,
            child: GrassBagCard(
              borderRadius: 26,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: t.isDark
                                ? [t.primaryHi, t.primary]
                                : [t.primaryHi, t.primary],
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: t.primary.withValues(alpha: 0.30),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'DS',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                            color: t.onPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'DeepSeek 账号',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.25,
                                color: t.text,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${state.accountSummaryLabel} · ${state.providerCredentials.where((p) => p.configured).length} 个渠道已就绪',
                              style: TextStyle(
                                fontSize: 12,
                                fontFeatures: const [FontFeature.tabularFigures()],
                                color: t.text2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!isSplit)
                        Icon(CupertinoIcons.chevron_right, size: 15, color: t.text3),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: t.fill1,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        GrassBagStatusDot(
                          size: 8,
                          pulsing: state.hostIsConnecting(curHost),
                          color: state.hostIsHealthy(curHost)
                              ? t.ok
                              : (curHost.needsAuth || state.hostIsConnecting(curHost)
                                  ? t.primary
                                  : (state.hostHasError(curHost) ? t.err : t.text3)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            curHost.isLocal
                                ? (state.hostIsHealthy(local)
                                    ? (isSplit
                                        ? '本机 · v${local.dshVersion} 运行中'
                                        : '本机 · DSH v${local.dshVersion} 运行中')
                                    : '本机 · ${state.hostStatusBadge(local)}')
                                : '${curHost.name} · ${curHost.bridged ? '增强模式' : (curHost.directMode && curHost.online ? '原生直连' : (curHost.needsAuth ? '待授权' : (curHost.online ? '基础模式' : '未连接')))}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: t.text2,
                            ),
                          ),
                        ),
                        if (!isSplit) ...[
                          const SizedBox(width: 8),
                          Text(
                            '${state.accent.label} · ${state.glassTier.label}',
                            style: TextStyle(fontSize: 11.5, color: t.text3),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: isSplit ? 10 : 18),
        ],

        for (final g in groups) ...[
          Builder(builder: (_) {
            final items = g.$2
                .where(
                  (it) => settingsSectionMatchesQuery(
                    it.$1,
                    title: it.$4,
                    summary: it.$5,
                    groupTitle: g.$1,
                    rawQuery: q,
                  ),
                )
                .toList();
            if (items.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: EdgeInsets.only(bottom: isSplit ? 10 : 18),
              child: GrassBagGroupedSection(
                header: g.$1,
                dividerIndent: 58,
                children: [
                  for (final item in items)
                    GrassBagListTile(
                      selected: isSplit && selected == item.$1,
                      contentPadding: isSplit
                          ? const EdgeInsets.symmetric(horizontal: 13, vertical: 7.5)
                          : const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                      leading: GrassBagSquircleIcon(
                        icon: item.$2,
                        color: (isSplit && selected == item.$1) ? t.primary : item.$3,
                        size: 32,
                        iconSize: 16,
                        filled: isSplit && selected == item.$1,
                      ),
                      title: Text(
                        item.$4,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (item.$6)
                            ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: isSplit ? 88 : 104),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
                                decoration: BoxDecoration(
                                  color: t.warnSoft,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  item.$5,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: t.warn,
                                  ),
                                ),
                              ),
                            )
                          else
                            ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: isSplit ? 88 : 104),
                              child: Text(
                                item.$5,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w400,
                                  color: t.text3,
                                ),
                              ),
                            ),
                          if (!isSplit) ...[
                            const SizedBox(width: 6),
                            Icon(
                              CupertinoIcons.chevron_right,
                              size: 13,
                              color: t.text3.withValues(alpha: 0.7),
                            ),
                          ],
                        ],
                      ),
                      onTap: () => onSelect(item.$1),
                    ),
                ],
              ),
            );
          }),
        ],
        if (!hasAnySearchHit)
          GrassBagEmptyStateCard(
            icon: CupertinoIcons.search,
            title: '没有找到与「$query」匹配的设置项',
            subtitle: '可尝试搜索模型、联网搜索、子智能体、MCP、主机或外观',
            actionLabel: '清除搜索',
            actionIcon: CupertinoIcons.xmark_circle,
            tier: state.glassTier,
            onAction: () {
              searchCtrl.clear();
              onQueryChanged('');
            },
          ),
      ],
    );
  }
}

class _SettingsDetailBody extends ConsumerWidget {
  const _SettingsDetailBody({
    required this.section,
    required this.hostDetailId,
    required this.onSelectHostDetail,
    required this.onHostRemoved,
    this.onOpenSection,
    required this.onOpenWebUi,
  });

  final SettingsSection section;
  final String? hostDetailId;
  final ValueChanged<String> onSelectHostDetail;
  final VoidCallback onHostRemoved;
  final ValueChanged<SettingsSection>? onOpenSection;
  final VoidCallback onOpenWebUi;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Narrow section-aware watch: self-contained ConsumerWidget sections return `null`
    // for `sectionPayload` so parent `_SettingsDetailBody` skips redundant outer rebuilds!
    ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          isDark: s.isDark,
          accent: s.accent,
          hosts: hostDetailId != null ||
                  section == SettingsSection.hosts ||
                  section == SettingsSection.local
              ? s.hosts
              : null,
          activeHostId: s.activeHostId,
          connectionPhase: s.connectionPhase,
          dshSettingsSections: section == SettingsSection.webSearch ||
                  section == SettingsSection.agentRuntime ||
                  section == SettingsSection.plugins
              ? s.dshSettingsSections
              : null,
          sectionPayload: switch (section) {
            SettingsSection.general ||
            SettingsSection.model ||
            SettingsSection.webSearch ||
            SettingsSection.agentRuntime ||
            SettingsSection.mcp ||
            SettingsSection.permissions ||
            SettingsSection.phone ||
            SettingsSection.plugins =>
              null,
            SettingsSection.account => (
                s.accountSnapshot,
                s.accountSigningIn,
                s.providerCredentials,
                s.routableProviders,
              ),
            SettingsSection.hosts || SettingsSection.local => (
                s.nativeRuntimeStatus,
                s.runtimeProgressPct,
                s.runtimeProgressMsg,
                s.updateCheck,
                s.checkingUpdate,
                s.discoveredLanHosts,
                s.scanningLan,
                s.containerToolkits,
                s.useSystemProxy,
              ),
            SettingsSection.appearance => (s.isDark, s.accent, s.glassTier),
            SettingsSection.diagnostics => (
                s.liveCapabilities,
                s.dshNamespaces,
                s.recentErrors,
                s.nativeRuntimeStatus,
              ),
            SettingsSection.about => (
                s.appVersion,
                s.appBuildNumber,
                s.appUpdateInfo,
                s.checkingAppUpdate,
                s.appUpdateError,
                s.appUpdateDownloading,
                s.appUpdateDownloadProgress,
              ),
            _ => null,
          },
        ),
      ),
    );
    final state = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);

    if (hostDetailId != null &&
        (section == SettingsSection.hosts || section == SettingsSection.local)) {
      final host = state.hosts.where((h) => h.id == hostDetailId).firstOrNull;
      if (host != null) {
        return _HostDetailSection(
          host: host,
          isCurrent: host.id == state.activeHostId,
          onOpenWebUi: onOpenWebUi,
          onRemove: () {
            ctrl.removeRemoteHost(host.id);
            onHostRemoved();
          },
        );
      }
    }

    switch (section) {
      case SettingsSection.account:
        final signedIn = state.isAccountSignedIn;
        final acctState = state.accountSnapshot?['state'];
        final links = acctState is Map && acctState['links'] is Map
            ? acctState['links'] as Map
            : const <dynamic, dynamic>{};
        final profileLabel = state.accountDisplayName;
        final balanceDisplay = state.accountBalanceText;
        final configuredCreds = state.providerCredentials.where((p) => p.configured).length;
        final routableCount = state.routableProviders.length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GrassBagCard(
              borderRadius: 26,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [t.primaryHi, t.primary],
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: t.primary.withValues(alpha: 0.30),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'DS',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 17,
                            color: t.onPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    'DeepSeek 账号',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: -0.3,
                                      color: t.text,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 7),
                                _SmallPill(
                                  label: signedIn ? '已登录' : '未登录',
                                  bg: signedIn ? t.okSoft : t.fill1,
                                  fg: signedIn ? t.ok : t.text2,
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              profileLabel,
                              style: TextStyle(fontSize: 12, color: t.text2),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ClipRSuperellipse(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      color: t.fill1,
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('官方账号余额', style: TextStyle(fontSize: 11.5, color: t.text3)),
                                const SizedBox(height: 2),
                                Text(
                                  balanceDisplay.isNotEmpty
                                      ? balanceDisplay
                                      : (signedIn ? '--' : '未登录'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.4,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                    color: t.text,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text('可用模型渠道', style: TextStyle(fontSize: 11.5, color: t.text3)),
                                const SizedBox(height: 2),
                                Text(
                                  '$routableCount 个可用渠道 · $configuredCreds 个密钥',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                    color: routableCount > 0 ? t.ok : t.text2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (state.accountSigningIn && !signedIn) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      decoration: BoxDecoration(
                        color: t.primarySoft,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          CupertinoActivityIndicator(radius: 7, color: t.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '正在等待 DeepSeek 授权完成，授权后自动同步余额与模型…',
                              style: TextStyle(fontSize: 12, color: t.primary, fontWeight: FontWeight.w500),
                            ),
                          ),
                          GestureDetector(
                            onTap: ctrl.cancelDeepSeekSignIn,
                            child: Text(
                              '取消',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.err),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: signedIn
                            ? GrassBagSecondaryGlassButton(
                                label: '退出官方账号',
                                icon: CupertinoIcons.square_arrow_right,
                                tier: state.glassTier,
                                insideGlass: true,
                                destructive: true,
                                onTap: () async {
                                  final ok = await showGrassBagConfirmDialog(
                                    context,
                                    title: '退出 DeepSeek 官方账号？',
                                    message: '退出后当前主机的官方模型渠道将暂时不可用，需重新授权登录。',
                                    confirmLabel: '确认退出',
                                    isDestructive: true,
                                  );
                                  if (ok) unawaited(ctrl.signOutDeepSeekAccount());
                                },
                              )
                            : GrassBagPrimaryGlassButton(
                                label: state.accountSigningIn ? '重新打开授权页' : '登录 DeepSeek 账号',
                                icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                                tier: state.glassTier,
                                insideGlass: true,
                                onTap: () => unawaited(launchDeepSeekSignInFlow(context, ref)),
                              ),
                      ),
                      const SizedBox(width: 8),
                      GrassBagSecondaryGlassButton(
                        label: '刷新',
                        icon: CupertinoIcons.refresh,
                        tier: state.glassTier,
                        insideGlass: true,
                        onTap: ctrl.refreshAccount,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            GrassBagGroupedSection(
              header: '渠道与同步',
              dividerIndent: 58,
              children: [
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.lock_fill,
                    color: t.isDark ? const Color(0xFF63B4E4) : const Color(0xFF236185),
                    size: 32,
                    iconSize: 15,
                  ),
                  title: const Text('外部渠道与 API 密钥'),
                  trailing: Text(
                    '$configuredCreds / ${state.providerCredentials.length} 已配置',
                    style: TextStyle(fontSize: 12.5, color: t.text3),
                  ),
                  showChevron: true,
                  onTap: () => showProviderCredentialsSheet(context, ref),
                ),
                if (links['usageUrl'] is String)
                  GrassBagListTile(
                    leading: GrassBagSquircleIcon(
                      icon: CupertinoIcons.chart_bar_fill,
                      color: t.isDark ? const Color(0xFF4AC885) : t.ok,
                      size: 32,
                      iconSize: 15,
                    ),
                    title: const Text('DeepSeek 平台用量与充值'),
                    trailing: Text(
                      '打开平台',
                      style: TextStyle(fontSize: 12.5, color: t.text3),
                    ),
                    showChevron: true,
                    onTap: () async {
                      final u = links['usageUrl'].toString().trim();
                      final parsed = Uri.tryParse(u);
                      if (parsed == null || (parsed.scheme != 'http' && parsed.scheme != 'https')) {
                        ctrl.showToast('平台地址格式无效', tone: ToastTone.warn);
                        return;
                      }
                      if (kIsWeb) {
                        openUrlInNewTab(parsed.toString());
                      } else if (GrassBagNativeBridge.instance.isAndroidNative) {
                        final ok = await GrassBagNativeBridge.instance.openExternalUrl(parsed.toString());
                        if (!ok) ctrl.showToast('平台地址：$u', tone: ToastTone.info);
                      } else {
                        ctrl.showToast('平台地址：$u', tone: ToastTone.info);
                      }
                    },
                  ),
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.cloud_fill,
                    color: t.isDark ? const Color(0xFF7FA3F2) : const Color(0xFF425EA8),
                    size: 32,
                    iconSize: 15,
                  ),
                  title: const Text('客户端偏好与主机清单同步'),
                  trailing: Text('导出 / 导入', style: TextStyle(fontSize: 12.5, color: t.text3)),
                  showChevron: true,
                  onTap: () => showConfigSyncSheet(context, ref),
                ),
              ],
            ),
          ],
        );

      case SettingsSection.general:
        return const DshGeneralSettingsView();

      case SettingsSection.model:
        return DshModelConfigView(
          onOpenHostSettings:
              onOpenSection != null ? () => onOpenSection!(SettingsSection.hosts) : null,
        );

      case SettingsSection.webSearch:
        final webManifest = state.dshSettingsSections
            .where((s) => s.id == 'web-search')
            .firstOrNull;
        return DshWebSearchSettingsView(namespaces: webManifest?.namespaces ?? const []);

      case SettingsSection.agentRuntime:
        final rtManifest = state.dshSettingsSections
            .where((s) => s.id == 'agent-runtime')
            .firstOrNull;
        return DshAgentRuntimeSettingsView(namespaces: rtManifest?.namespaces ?? const []);

      case SettingsSection.mcp:
        return const DshMcpSettingsView();

      case SettingsSection.appearance:
        final tierHint = switch (state.glassTier) {
          GrassBagGlassTier.liquid => '动态光学折射与高光边缘',
          GrassBagGlassTier.frosted => '经典轻量毛玻璃模糊，兼顾流畅与通透',
          GrassBagGlassTier.solid => '纯色实底卡片，零着色器极致省电',
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Interactive Live Liquid Glass Studio Diorama:
            // Wrapped in RepaintBoundary with all 3 preview pills batched into ONE GPU glass pass!
            RepaintBoundary(
              child: ClipRSuperellipse(
              borderRadius: BorderRadius.circular(26),
              child: Container(
                height: 152,
                decoration: ShapeDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: state.isDark
                        ? [
                            Color.lerp(t.bgTop, t.primary, 0.24)!,
                            t.bgSolid,
                            Color.lerp(t.bgBottom, t.dusk, 0.22)!,
                          ]
                        : [
                            Color.lerp(t.bgTop, Colors.white, 0.35)!,
                            Color.lerp(t.bgSolid, t.primaryHi, 0.16)!,
                            Color.lerp(t.bgBottom, t.dusk, 0.12)!,
                          ],
                  ),
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(26),
                    side: BorderSide(
                      color: t.isDark
                          ? Colors.white.withValues(alpha: 0.12)
                          : Colors.white.withValues(alpha: 0.90),
                      width: 0.8,
                    ),
                  ),
                ),
                child: Stack(
                  children: [
                    // Crisp diagonal accent prism ribbons behind the glass pills so refraction & frost are unmistakable
                    Positioned(
                      top: -34,
                      left: -24,
                      right: -24,
                      child: Transform.rotate(
                        angle: -0.18,
                        child: Container(
                          height: 68,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                t.primaryHi.withValues(alpha: state.isDark ? 0.34 : 0.32),
                                t.primary.withValues(alpha: state.isDark ? 0.14 : 0.18),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: -24,
                      left: -20,
                      right: -20,
                      child: Transform.rotate(
                        angle: -0.14,
                        child: Container(
                          height: 62,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerRight,
                              end: Alignment.centerLeft,
                              colors: [
                                t.ok.withValues(alpha: state.isDark ? 0.24 : 0.22),
                                t.dusk.withValues(alpha: state.isDark ? 0.22 : 0.18),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 26,
                      top: 18,
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              t.primaryHi.withValues(alpha: state.isDark ? 0.60 : 0.48),
                              t.primaryHi.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // All 3 floating preview pills batched in ONE GPU glass layer (zero shadow re-bake)!
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: state.glassTier == GrassBagGlassTier.solid
                          ? _buildDioramaPills(t, state, tierHint)
                          : AdaptiveLiquidGlassLayer(
                              settings: GrassBagGlassConfig.surfaceSettings(t, state.glassTier)
                                  .copyWith(shadow: const []),
                              quality: GrassBagGlassConfig.chromeQualityFor(state.glassTier),
                              blendAmount: 0.0,
                              child: _buildDioramaPills(t, state, tierHint),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            ),
            const SizedBox(height: 18),
            GrassBagGroupedSection(
              header: '色彩模式',
              children: [
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: state.isDark
                        ? CupertinoIcons.moon_stars_fill
                        : CupertinoIcons.sun_max_fill,
                    color: state.isDark ? const Color(0xFF8A97EE) : const Color(0xFFD98618),
                    size: 32,
                    iconSize: 16,
                  ),
                  title: const Text('深色模式'),
                  subtitle: Text(state.isDark ? '深岩低眩光底面，夜间阅读舒适' : '清透浅色底面，日间通透明亮'),
                  trailing: GrassBagGlassSwitch(
                    value: state.isDark,
                    tier: state.glassTier,
                    onChanged: ctrl.setDark,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 8),
              child: Text('主题色（6 套护眼均衡配色）', style: TextStyle(fontSize: 12, color: t.text3)),
            ),
            GrassBagCard(
              borderRadius: 24,
              padding: const EdgeInsets.all(14),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final acc in GrassBagAccent.values)
                    GrassBagSpringTap(
                      onTap: () => ctrl.setAccent(acc),
                      pressedScale: 0.93,
                      haptic: true,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: state.accent == acc ? t.primarySoft : t.fill1,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: state.accent == acc ? t.primary : Colors.transparent,
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 15,
                              height: 15,
                              decoration: BoxDecoration(
                                color: acc.swatchFor(t.isDark),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: t.isDark
                                      ? Colors.white.withValues(alpha: 0.28)
                                      : Colors.black.withValues(alpha: 0.12),
                                  width: 0.8,
                                ),
                              ),
                              child: state.accent == acc
                                  ? Icon(
                                      CupertinoIcons.checkmark_alt,
                                      size: 10,
                                      color: acc.swatchFor(t.isDark).computeLuminance() > 0.38
                                          ? const Color(0xFF0E1117)
                                          : Colors.white,
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 7),
                            Text(
                              acc.label,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: state.accent == acc ? FontWeight.w600 : FontWeight.w500,
                                color: t.text,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 6),
              child: Text('玻璃质感档位', style: TextStyle(fontSize: 12, color: t.text3)),
            ),
            GrassBagSegmentedControl(
              labels: [for (final tier in GrassBagGlassTier.values) tier.label],
              selectedIndex: GrassBagGlassTier.values.indexOf(state.glassTier),
              tier: state.glassTier,
              height: 40,
              onSelected: (idx) => ctrl.setGlassTier(GrassBagGlassTier.values[idx]),
            ),
          ],
        );

      case SettingsSection.hosts:
        final local = state.localHost;
        final rt = state.nativeRuntimeStatus;
        final isAndroidLocal = !kIsWeb && GrassBagNativeBridge.instance.isAndroidNative;
        final isDeploying = isAndroidLocal &&
            state.runtimeProgressPct > 0 &&
            state.runtimeProgressPct < 100;
        final remotes = state.hosts.where((h) => !h.isLocal).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GrassBagGroupedSection(
              header: '本机环境（容器与 DSH 引擎）',
              footer: isAndroidLocal
                  ? '本机内置 Ubuntu 容器初始化、启动器模式、A/B 更新、备份与运行日志已统一收敛到此处管理。'
                  : null,
              dividerIndent: 62,
              children: [
                GrassBagListTile(
                  onTap: () => onSelectHostDetail(local.id),
                  leading: GrassBagSquircleIcon(
                    icon: isAndroidLocal
                        ? CupertinoIcons.device_phone_portrait
                        : CupertinoIcons.desktopcomputer,
                    color: state.hostIsHealthy(local)
                        ? t.ok
                        : (state.hostHasError(local) ? t.err : t.primary),
                    size: 36,
                    iconSize: 18,
                    filled: state.hostIsHealthy(local),
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          local.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w600, color: t.text),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _SmallPill(
                        label: state.hostStatusBadge(local),
                        bg: state.hostIsHealthy(local)
                            ? t.okSoft
                            : (state.hostHasError(local) ? t.errSoft : t.primarySoft),
                        fg: state.hostIsHealthy(local)
                            ? t.ok
                            : (state.hostHasError(local) ? t.err : t.primary),
                      ),
                      if (state.activeHostId == local.id) ...[
                        const SizedBox(width: 5),
                        _SmallPill(label: '当前', bg: t.fill1, fg: t.text2),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    isAndroidLocal
                        ? state.hostStatusLabel(local)
                        : 'DSH v${local.dshVersion} · ${local.containerVersion}',
                  ),
                  showChevron: true,
                ),
                if (isAndroidLocal && (!rt.initialized || !rt.engineRunning))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (isDeploying) ...[
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  state.runtimeProgressMsg.isNotEmpty
                                      ? state.runtimeProgressMsg
                                      : '正在初始化本机 Linux 容器…',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, color: t.text2),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${state.runtimeProgressPct}%',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.primary),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          GrassBagProgressBar(
                            value: (state.runtimeProgressPct / 100.0).clamp(0.0, 1.0),
                            height: 5,
                            trackColor: t.fill2,
                            color: t.primary,
                          ),
                          const SizedBox(height: 8),
                        ],
                        Row(
                          children: [
                            Expanded(
                              child: GrassBagPrimaryGlassButton(
                                label: !rt.initialized
                                    ? (isDeploying ? '正在初始化 ${state.runtimeProgressPct}%…' : '一键初始化并启动本机容器')
                                    : (rt.engineState == 'starting' ? '正在启动引擎…' : '启动本机 DSH 引擎'),
                                icon: CupertinoIcons.bolt_fill,
                                height: 38,
                                tier: state.glassTier,
                                insideGlass: true,
                                enabled: !isDeploying && rt.engineState != 'starting',
                                onTap: (isDeploying || rt.engineState == 'starting')
                                    ? null
                                    : () => !rt.initialized
                                        ? ctrl.bootstrapLocalRuntime()
                                        : ctrl.restartLocalEngine(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GrassBagSecondaryGlassButton(
                              label: '详细管理',
                              height: 38,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              tier: state.glassTier,
                              insideGlass: true,
                              onTap: () => onSelectHostDetail(local.id),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            if (remotes.isNotEmpty) ...[
              GrassBagGroupedSection(
                header: '远程主机（免插件直连或管理凭证）',
                dividerIndent: 62,
                children: [
                  for (final remote in remotes)
                    GrassBagListTile(
                      onTap: () => onSelectHostDetail(remote.id),
                      leading: GrassBagSquircleIcon(
                        icon: CupertinoIcons.desktopcomputer,
                        color: remote.isConnectedUsable
                            ? t.ok
                            : (remote.lastErrorCode == 'needs_auth' ||
                                    remote.lastErrorCode == 'html_proxy'
                                ? t.warn
                                : t.err),
                        size: 36,
                        iconSize: 18,
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              remote.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontWeight: FontWeight.w600, color: t.text),
                            ),
                          ),
                          const SizedBox(width: 6),
                          _SmallPill(
                            label: state.hostStatusBadge(remote),
                            bg: remote.isConnectedUsable
                                ? t.okSoft
                                : (remote.lastErrorCode == 'needs_auth' ||
                                        remote.lastErrorCode == 'html_proxy'
                                    ? t.warnSoft
                                    : t.errSoft),
                            fg: remote.isConnectedUsable
                                ? t.ok
                                : (remote.lastErrorCode == 'needs_auth' ||
                                        remote.lastErrorCode == 'html_proxy'
                                    ? t.warn
                                    : t.err),
                          ),
                          if (remote.isInsecurePublicHttp) ...[
                            const SizedBox(width: 5),
                            _SmallPill(label: '明文HTTP', bg: t.errSoft, fg: t.err),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        '${remote.address} · ${state.hostStatusLabel(remote)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: t.text3),
                      ),
                      showChevron: true,
                    ),
                ],
              ),
              const SizedBox(height: 18),
            ],
            Padding(
              padding: const EdgeInsets.only(left: 14, bottom: 8),
              child: Text('添加远程主机', style: TextStyle(fontSize: 12, color: t.text3)),
            ),
            RemoteHostConnectCard(
              connectImmediately: true,
              showHeader: true,
              initiallyShowGuide: remotes.isEmpty,
              onConnectedHost: (added) {
                if (added.isConnectedUsable && Navigator.of(context).canPop()) {
                  Navigator.of(context).popUntil((r) => r.isFirst);
                  return;
                }
                onSelectHostDetail(added.id);
              },
            ),
          ],
        );

      case SettingsSection.local:
        return _HostDetailSection(
          host: state.localHost,
          isCurrent: state.activeHostId == 'local',
          onOpenWebUi: onOpenWebUi,
          onRemove: () {},
        );

      case SettingsSection.permissions:
        return const PermissionsCenterView();

      case SettingsSection.phone:
        return const PhoneControlView();

      case SettingsSection.plugins:
        final plugManifest = state.dshSettingsSections
            .where((s) => s.id == 'plugins')
            .firstOrNull;
        return DshPluginsSettingsView(
          thirdPartyNamespaces: plugManifest?.namespaces ?? const [],
        );

      case SettingsSection.diagnostics:
        final caps = state.liveCapabilities;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: GrassBagCard(
                      borderRadius: 22,
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            caps != null ? '已连接' : '未连接',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: caps != null ? t.ok : t.warn,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text('引擎状态', style: TextStyle(fontSize: 11.5, color: t.text3)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GrassBagCard(
                      borderRadius: 22,
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            caps != null ? '${caps.endpointsCount}' : '0',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [FontFeature.tabularFigures()],
                              color: t.text,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text('已发现接口', style: TextStyle(fontSize: 11.5, color: t.text3)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GrassBagCard(
                      borderRadius: 22,
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '${state.effectiveDshNamespaces.length}',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [FontFeature.tabularFigures()],
                              color: t.text,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text('配置模块', style: TextStyle(fontSize: 11.5, color: t.text3)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (caps == null) ...[
              const SizedBox(height: 12),
              GrassBagSecondaryGlassButton(
                label: '重新连接并刷新诊断',
                icon: CupertinoIcons.refresh,
                tier: state.glassTier,
                insideGlass: true,
                accentForeground: true,
                onTap: () => unawaited(ctrl.probeAndRefreshHost(state.activeHostId)),
              ),
            ],
            if (state.recentErrors.isNotEmpty) ...[
              const SizedBox(height: 14),
              RecentErrorsDiagnosticsCard(errors: state.recentErrors),
            ],
            const SizedBox(height: 14),
            GrassBagGroupedSection(
              header: '高级诊断工具',
              dividerIndent: 56,
              children: [
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.chart_bar_alt_fill,
                    color: t.primary,
                    size: 32,
                    iconSize: 15,
                  ),
                  title: const Text('SDUI 诊断与扩展面板'),
                  subtitle: const Text('查看桥服务探针与宿主机注册的动态扩展视图'),
                  showChevron: true,
                  onTap: () => Navigator.of(context).push(
                    GrassBagPageRoute<void>(
                      builder: (_) => const SduiExtensionsPage(initialViewId: 'host-diagnostics'),
                    ),
                  ),
                ),
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.slider_horizontal_3,
                    color: t.text2,
                    size: 32,
                    iconSize: 15,
                  ),
                  title: const Text('开发者：全部 DSH 原始命名空间'),
                  subtitle: Text('直接检视与编辑 ${state.effectiveDshNamespaces.length} 组底层 Schemastery 配置'),
                  showChevron: true,
                  onTap: () => showAllRawNamespacesSheet(context, ref),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const _EngineLogsConsole(showSummaryWhenEmpty: true, maxLines: 12),
          ],
        );

      case SettingsSection.about:
        return const AppAboutAndUpdateView();

      case SettingsSection.webui:
        return Center(
          child: GrassBagPrimaryGlassButton(
            label: '打开官方网页版',
            icon: CupertinoIcons.globe,
            tier: state.glassTier,
            insideGlass: true,
            onTap: onOpenWebUi,
          ),
        );
    }
  }

  Widget _buildDioramaPills(
    GrassBagTokens t,
    GrassBagAppState state,
    String tierHint,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            GrassBagGlass(
              tier: state.glassTier,
              borderRadius: 999,
              height: 36,
              useOwnLayer: false,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.sparkles, size: 14, color: t.primary),
                  const SizedBox(width: 6),
                  Text(
                    '${state.accent.label} · ${state.glassTier.label}玻璃',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.15,
                      color: t.text,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            GrassBagGlass(
              tier: state.glassTier,
              isOval: true,
              width: 36,
              height: 36,
              useOwnLayer: false,
              alignment: Alignment.center,
              child: Icon(
                state.isDark
                    ? CupertinoIcons.moon_stars_fill
                    : CupertinoIcons.sun_max_fill,
                size: 16,
                color: t.primary,
              ),
            ),
          ],
        ),
        GrassBagGlass(
          tier: state.glassTier,
          borderRadius: 18,
          useOwnLayer: false,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: t.ok, shape: BoxShape.circle),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  tierHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: t.text2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HostDetailSection extends ConsumerStatefulWidget {
  const _HostDetailSection({
    required this.host,
    required this.isCurrent,
    required this.onOpenWebUi,
    required this.onRemove,
  });

  final ManagedHost host;
  final bool isCurrent;
  final VoidCallback onOpenWebUi;
  final VoidCallback onRemove;

  @override
  ConsumerState<_HostDetailSection> createState() => _HostDetailSectionState();
}

class _HostDetailSectionState extends ConsumerState<_HostDetailSection> {
  bool _openingWebUi = false;

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final isCurrent = widget.isCurrent;
    final onOpenWebUi = widget.onOpenWebUi;
    final onRemove = widget.onRemove;
    final ctrl = ref.read(appProvider.notifier);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final t = GrassBagTokens.of(context);

    if (host.isLocal) {
      ref.watch(
        appProvider.select(
          (s) => (
            nativeRuntimeStatus: s.nativeRuntimeStatus,
            updateCheck: s.updateCheck,
            checkingUpdate: s.checkingUpdate,
            connectionPhase: s.connectionPhase,
            dshNamespaces: s.dshNamespaces,
            runtimeProgressPct: s.runtimeProgressPct,
            runtimeProgressMsg: s.runtimeProgressMsg,
            containerToolkits: s.containerToolkits,
            useSystemProxy: s.useSystemProxy,
          ),
        ),
      );
      final appState = ref.read(appProvider);
      final rt = appState.nativeRuntimeStatus;
      final isAndroidLocal = !kIsWeb && GrassBagNativeBridge.instance.isAndroidNative;
      final dshHasNew = host.dshVersion.isNotEmpty &&
          host.dshVersion != '检测中' &&
          host.dshLatest.isNotEmpty &&
          host.dshLatest != '检测中' &&
          host.dshVersion != host.dshLatest;
      final updateCheck = isCurrent ? appState.updateCheck : null;
      final isConnected = isCurrent && appState.connectionPhase == ConnectionPhase.connected;
      final engineLabel = isAndroidLocal
          ? switch (rt.engineState) {
              'running' => '本机 DSH 引擎运行中',
              'starting' => '本机 DSH 引擎启动中…',
              'error' => '本机引擎启动异常',
              _ => rt.initialized ? '本机容器已就绪（点击启动）' : '本机引擎未初始化',
            }
          : (isConnected ? '已连接到本机 DSH 主机' : '等待连接本机 DSH');
      final engineSub = host.lastError != null && host.lastError!.isNotEmpty
          ? host.lastError!
          : (rt.engineError != null && rt.engineError!.isNotEmpty
              ? rt.engineError!
              : (isConnected || rt.engineRunning
                  ? 'DSH v${host.dshVersion} · ${appState.effectiveDshNamespaces.length} 组配置已同步'
                  : host.address));
      final containerDisplay = host.containerVersion.contains('Node') || !isAndroidLocal
          ? host.containerVersion
          : '${host.containerVersion} · ${host.containerNode}';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GrassBagCard(
            borderRadius: 24,
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: (rt.engineRunning || (!isAndroidLocal && isConnected))
                        ? t.ok
                        : (rt.engineState == 'error' || host.lastError != null ? t.err : t.warn),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(engineLabel, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: t.text)),
                      Text(
                        engineSub,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: (host.lastError != null || rt.engineError != null) ? t.err : t.text3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                () {
                  final isBusy = isAndroidLocal &&
                      (rt.engineState == 'starting' ||
                          (appState.runtimeProgressPct > 0 && appState.runtimeProgressPct < 100));
                  final primaryBtn = GrassBagSecondaryGlassButton(
                    label: isAndroidLocal
                        ? (!rt.initialized
                            ? (appState.runtimeProgressPct > 0 && appState.runtimeProgressPct < 100
                                ? '${appState.runtimeProgressPct}%'
                                : '一键部署')
                            : (rt.engineRunning
                                ? '重启'
                                : (rt.engineState == 'starting' ? '启动中…' : '启动')))
                        : '重连',
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    tier: tier,
                    insideGlass: true,
                    enabled: !isBusy,
                    onTap: isBusy
                        ? null
                        : () => isAndroidLocal
                            ? (!rt.initialized
                                ? ctrl.bootstrapLocalRuntime()
                                : ctrl.restartLocalEngine())
                            : ctrl.probeAndRefreshHost(host.id),
                  );
                  if (isAndroidLocal && rt.engineRunning && !isBusy) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GrassBagSecondaryGlassButton(
                          label: '停止',
                          height: 34,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          tier: tier,
                          insideGlass: true,
                          destructive: true,
                          onTap: () async {
                            final ok = await showGrassBagConfirmDialog(
                              context,
                              title: '停止本机 DSH 引擎？',
                              message: '停止后当前本机对话、终端会话与后台任务将中断，需要时可一键重新启动。',
                              confirmLabel: '停止引擎',
                              isDestructive: true,
                            );
                            if (ok) unawaited(ctrl.stopLocalEngine());
                          },
                        ),
                        const SizedBox(width: 6),
                        primaryBtn,
                      ],
                    );
                  }
                  return primaryBtn;
                }(),
              ],
            ),
          ),
          if (isAndroidLocal &&
              appState.runtimeProgressPct > 0 &&
              appState.runtimeProgressPct < 100) ...[
            const SizedBox(height: 10),
            GrassBagCard(
              borderRadius: 16,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          appState.runtimeProgressMsg.isNotEmpty
                              ? appState.runtimeProgressMsg
                              : '正在部署本机容器…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: t.text2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${appState.runtimeProgressPct}%',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.primary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  GrassBagProgressBar(
                    value: (appState.runtimeProgressPct / 100.0).clamp(0.0, 1.0),
                    height: 5,
                    trackColor: t.fill2,
                    color: t.primary,
                  ),
                ],
              ),
            ),
          ],
          if (!isCurrent) ...[
            const SizedBox(height: 12),
            GrassBagPrimaryGlassButton(
              label: '切换到本机对话',
              tier: tier,
              insideGlass: true,
              onTap: () => ctrl.switchHost('local'),
            ),
          ],
          const SizedBox(height: 18),
          GrassBagGroupedSection(
            header: 'DSH 引擎版本与在线检测',
            footer: updateCheck?.error != null && updateCheck!.error!.isNotEmpty
                ? '上次检测失败：${updateCheck.error}'
                : (updateCheck != null
                    ? 'npm 最新稳定版：v${updateCheck.latestVersion}${updateCheck.nextVersion != null ? ' · 预览版：v${updateCheck.nextVersion}' : ''}'
                    : '点击右侧按钮向 npm 注册表实时检测 @deepseek-ai/dsh 是否有更新。'),
            dividerIndent: 62,
            children: [
              GrassBagListTile(
                leading: GrassBagSquircleIcon(
                  icon: CupertinoIcons.sparkles,
                  color: dshHasNew ? t.warn : t.primary,
                  size: 34,
                  iconSize: 16,
                ),
                title: Text('DSH 引擎版本', style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
                subtitle: Text(
                  dshHasNew
                      ? '当前 v${host.dshVersion} → 可更新至 v${host.dshLatest}'
                      : '当前 v${host.dshVersion} · 连接助手 v${host.helperVersion ?? '0.1.0'}',
                ),
                trailing: dshHasNew
                    ? GrassBagPrimaryGlassButton(
                        label: host.updatingDsh ? '更新中…' : '更新 v${host.dshLatest}',
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        tier: tier,
                        insideGlass: true,
                        enabled: !host.updatingDsh,
                        onTap: host.updatingDsh ? null : ctrl.upgradeLocalDsh,
                      )
                    : GrassBagSecondaryGlassButton(
                        label: !isCurrent
                            ? '切换后检测'
                            : (appState.checkingUpdate
                                ? '检测中…'
                                : (updateCheck != null && !updateCheck.hasUpdate && updateCheck.error == null
                                    ? '已是最新'
                                    : '检查更新')),
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 11),
                        tier: tier,
                        insideGlass: true,
                        enabled: !isCurrent || !appState.checkingUpdate,
                        accentForeground: isCurrent && (updateCheck == null || updateCheck.error != null),
                        onTap: !isCurrent
                            ? () => ctrl.showToast('请先切换到本机后再检查本机 DSH 更新', tone: ToastTone.info)
                            : (appState.checkingUpdate ? null : () => ctrl.checkForDshUpdates()),
                      ),
              ),
              if (isAndroidLocal && rt.canRollback && rt.dshPrevVersion.isNotEmpty)
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.arrow_counterclockwise,
                    color: t.text2,
                    size: 34,
                    iconSize: 16,
                  ),
                  title: Text('恢复到上一版本（v${rt.dshPrevVersion}）'),
                  subtitle: const Text('新版异常时可原子切回 LKG 槽位，不影响对话资料'),
                  onTap: () async {
                    final ok = await showGrassBagConfirmDialog(
                      context,
                      title: '恢复到上一版本（v${rt.dshPrevVersion}）？',
                      message: '将停止当前引擎并原子切回上一个稳定槽位，/root 资料与历史对话不会丢失。',
                      confirmLabel: '确认恢复',
                      isDestructive: true,
                    );
                    if (ok) unawaited(ctrl.revertLocalDsh());
                  },
                ),
              GrassBagListTile(
                leading: GrassBagSquircleIcon(
                  icon: CupertinoIcons.cube_box_fill,
                  color: t.isDark ? const Color(0xFF7FA3F2) : const Color(0xFF425EA8),
                  size: 34,
                  iconSize: 16,
                ),
                title: Text(
                  isAndroidLocal ? 'Linux 容器环境' : '宿主机运行环境',
                  style: TextStyle(fontWeight: FontWeight.w600, color: t.text),
                ),
                subtitle: Text(containerDisplay),
                trailing: () {
                  final isBusy = isAndroidLocal &&
                      (rt.engineState == 'starting' ||
                          (appState.runtimeProgressPct > 0 && appState.runtimeProgressPct < 100));
                  final isOk = isAndroidLocal ? rt.engineRunning : isConnected;
                  final isErr =
                      (isAndroidLocal && rt.engineState == 'error') || host.lastError != null;
                  final label = isBusy
                      ? '初始化中'
                      : isOk
                          ? '运行中'
                          : isErr
                              ? '异常'
                              : (isAndroidLocal
                                  ? (rt.initialized ? '已就绪' : '未部署')
                                  : '未连接');
                  final color = isBusy
                      ? t.primary
                      : isOk
                          ? t.ok
                          : isErr
                              ? t.err
                              : t.warn;
                  return Text(label, style: TextStyle(fontSize: 12, color: color));
                }(),
              ),
            ],
          ),
          if (isAndroidLocal) ...[
            const SizedBox(height: 16),
            GrassBagGroupedSection(
              header: '本机容器初始化与维护',
              dividerIndent: 62,
              children: [
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.bolt_fill,
                    color: t.primary,
                    size: 34,
                    iconSize: 16,
                  ),
                  title: const Text('容器启动器模式'),
                  subtitle: const Text('高速模式启动快 8 倍；如真机受内核限制可切换 PRoot 兼容模式'),
                  trailing: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 148),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            () {
                              final configuredProot =
                                  rt.configuredExecutorMode.startsWith('proot');
                              final fellBackToProot = !configuredProot &&
                                  rt.engineRunning &&
                                  rt.executorMode.startsWith('proot');
                              if (configuredProot) return '兼容 (PRoot)';
                              if (fellBackToProot) return '高速 (回退 PRoot)';
                              return '高速 (tawcroot)';
                            }(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12.5, color: t.text3),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(CupertinoIcons.chevron_right, size: 13.5, color: t.text3),
                      ],
                    ),
                  ),
                  onTap: () {
                    final isProot = rt.configuredExecutorMode.startsWith('proot');
                    showGrassBagSheet<void>(
                      context,
                      title: '选择容器启动器模式',
                      subtitle: '切换后需重启本机 DSH 引擎生效',
                      bodyBuilder: (sheetCtx) {
                        final st = GrassBagTokens.of(sheetCtx);
                        return GrassBagSheetSection(
                          dividerIndent: 52,
                          children: [
                            GrassBagListTile(
                              leading: GrassBagSquircleIcon(
                                icon: CupertinoIcons.bolt_fill,
                                color: st.primary,
                                size: 32,
                                iconSize: 15,
                                filled: !isProot,
                              ),
                              title: const Text('高速模式（推荐 · tawcroot）'),
                              subtitle: const Text('启动速度提升约 8 倍，绝大多数 Android 机型首选'),
                              trailing: !isProot
                                  ? Icon(CupertinoIcons.checkmark_circle_fill, size: 18, color: st.primary)
                                  : null,
                              onTap: () {
                                ctrl.setLauncherMode('高速模式');
                                Navigator.of(sheetCtx).pop();
                              },
                            ),
                            GrassBagListTile(
                              leading: GrassBagSquircleIcon(
                                icon: CupertinoIcons.shield_lefthalf_fill,
                                color: st.warn,
                                size: 32,
                                iconSize: 15,
                                filled: isProot,
                              ),
                              title: const Text('兼容模式（PRoot）'),
                              subtitle: const Text('如高速模式在特定机型内核受限无法启动，可切回此模式'),
                              trailing: isProot
                                  ? Icon(CupertinoIcons.checkmark_circle_fill, size: 18, color: st.primary)
                                  : null,
                              onTap: () {
                                ctrl.setLauncherMode('兼容模式');
                                Navigator.of(sheetCtx).pop();
                              },
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.folder_fill,
                    color: t.ok,
                    size: 34,
                    iconSize: 16,
                  ),
                  title: const Text('访问手机存储 (/sdcard)'),
                  subtitle: const Text('允许读写手机下载与文档目录'),
                  trailing: GrassBagGlassSwitch(
                    value: host.sdcardMounted,
                    tier: tier,
                    onChanged: (_) => ctrl.toggleSdcardMounted(),
                  ),
                ),
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.globe,
                    color: t.primaryHi,
                    size: 34,
                    iconSize: 16,
                  ),
                  title: const Text('继承手机系统代理'),
                  subtitle: const Text('容器内网络请求与 npm 自动同步当前 Wi-Fi HTTP 代理'),
                  trailing: GrassBagGlassSwitch(
                    value: appState.useSystemProxy,
                    tier: tier,
                    onChanged: (v) => ctrl.setEngineFlags(proxy: v),
                  ),
                ),
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: rt.initialized
                        ? CupertinoIcons.checkmark_shield_fill
                        : CupertinoIcons.arrow_down_circle_fill,
                    color: rt.initialized ? t.ok : t.primary,
                    size: 34,
                    iconSize: 16,
                  ),
                  title: Text(rt.initialized ? '校验 / 修复本机容器' : '一键初始化本机容器'),
                  subtitle: Text(
                    '系统分区 ${rt.activeSlot} · ${rt.initialized ? '容器已解压，点击可原地校验完整性' : '离线解压 Ubuntu 24.04.5 + Node 24 + DSH'}',
                  ),
                  trailing: _SmallPill(
                    label: rt.initialized ? '已就绪' : '待部署',
                    bg: rt.initialized ? t.okSoft : t.primarySoft,
                    fg: rt.initialized ? t.ok : t.primary,
                  ),
                  onTap: () => unawaited(ctrl.bootstrapLocalRuntime()),
                ),
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.trash_fill,
                    color: t.warn,
                    size: 34,
                    iconSize: 15,
                  ),
                  title: const Text('清理容器临时缓存'),
                  subtitle: const Text('清理 /tmp、apt/npm 缓存与过期快照，保留 /root 资料'),
                  showChevron: true,
                  onTap: ctrl.cleanLocalCache,
                ),
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.arrow_2_circlepath,
                    color: t.dusk,
                    size: 34,
                    iconSize: 16,
                  ),
                  title: const Text('保留 /root 重建容器'),
                  subtitle: const Text('重新解压干净 Ubuntu + Node 24 镜像，代码与对话零丢失'),
                  showChevron: true,
                  onTap: () async {
                    final ok = await showGrassBagConfirmDialog(
                      context,
                      title: '保留 /root 重建容器？',
                      message: '将停止当前引擎并重新部署干净 Linux 根文件系统，/root 中的项目、密钥与历史对话均完好保留。',
                      confirmLabel: '开始重建',
                    );
                    if (ok) unawaited(ctrl.rebuildLocalContainer());
                  },
                ),
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.lock_shield_fill,
                    color: t.primary,
                    size: 34,
                    iconSize: 16,
                  ),
                  title: const Text('加密导出本机备份到 Download/'),
                  subtitle: const Text('使用 AES-256-GCM 口令加密归档对话与配置'),
                  showChevron: true,
                  onTap: () {
                    showGrassBagSheet<void>(
                      context,
                      title: '设置备份加密口令',
                      subtitle: '导出前对 /root 与密钥摘要进行本地 AES-GCM 加密（至少 6 位）',
                      bodyBuilder: (_) => const _BackupPassphraseSheetBody(),
                    );
                  },
                ),
              ],
            ),
            const _EngineLogsConsole(
              showSummaryWhenEmpty: false,
              maxLines: 10,
              topSpacing: 16,
              headerPrefix: '本机容器启动日志',
              forceLocal: true,
            ),
            const SizedBox(height: 16),
            GrassBagGroupedSection(
              header: '容器工具链扩展市场',
              dividerIndent: 56,
              children: [
                for (final tk in appState.containerToolkits)
                  GrassBagListTile(
                    leading: tk.installing
                        ? Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: t.primary.withValues(alpha: t.isDark ? 0.22 : 0.14),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            alignment: Alignment.center,
                            child: CupertinoActivityIndicator(radius: 7.5, color: t.primary),
                          )
                        : GrassBagSquircleIcon(
                            icon: tk.installed ? CupertinoIcons.checkmark_alt_circle_fill : CupertinoIcons.cube_box,
                            color: tk.installed ? t.ok : t.primary,
                            size: 32,
                            iconSize: 15,
                          ),
                    title: Text(tk.name, style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
                    subtitle: Text(
                      tk.installing ? '正在部署中（可在上方容器日志查看实时进度）…' : '${tk.desc} · ${tk.sizeLabel}',
                    ),
                    trailing: tk.installed
                        ? Text('已安装', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.ok))
                        : GrassBagSecondaryGlassButton(
                            label: tk.installing ? '部署中…' : '安装',
                            height: 28,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            tier: tier,
                            insideGlass: true,
                            onTap: () {
                              if (!tk.installing) ctrl.installContainerToolkit(tk.id);
                            },
                          ),
                  ),
              ],
            ),
          ],
        ],
      );
    }

    // Remote Host Detail: Zero-Plugin Direct Mode + In-App WebView Login + 30-Day Cookie + Optional Helper!
    final errCode = host.lastErrorCode ?? '';
    final errLower = (host.lastError ?? '').toLowerCase();
    final isAuthError = errCode == 'needs_auth' ||
        errCode == 'html_proxy' ||
        errLower.contains('401') ||
        errLower.contains('unauthorized') ||
        errLower.contains('authentication');
    final isUntrustedHost = errCode == 'untrusted_host' ||
        (errLower.contains('403') &&
            (errLower.contains('trusted') ||
                errLower.contains('untrusted') ||
                errLower.contains('白名单') ||
                errLower.contains('主机名')));
    final isTlsError = errCode == 'tls_cert' || errLower.contains('handshake');
    final isBridgedReady = host.bridged && host.online;
    final isDirectReady = host.directMode && host.online;
    final canWebViewLogin = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final parsedUri = Uri.tryParse(host.address);
    final hostLiteral = parsedUri?.host ?? host.address;
    final portFlag = (parsedUri != null && parsedUri.hasPort && parsedUri.port != 3080)
        ? ' --port ${parsedUri.port}'
        : '';
    final isIpv6Host = hostLiteral.contains(':') && !hostLiteral.startsWith('[');
    final formattedHost = isIpv6Host ? '[$hostLiteral]' : hostLiteral;
    final isIpHost = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(hostLiteral) || isIpv6Host;
    final suggestedStartCmd = isUntrustedHost
        ? (isIpHost
            ? 'dsh web --host $hostLiteral$portFlag --no-open'
            : 'dsh web --trusted-host ${parsedUri?.hasPort == true ? '$formattedHost:${parsedUri!.port}' : formattedHost}$portFlag --no-open')
        : 'dsh web --host ${isIpHost ? hostLiteral : '<局域网IP>'}$portFlag --no-open';

    void openTokenEditorSheet() {
      showGrassBagSheet<void>(
        context,
        title: '配置访问令牌 / 粘贴启动链接',
        subtitle: '支持粘贴完整 dsh web: http://.../?token=... 或纯 Token（留空可清空）',
        bodyBuilder: (_) => _HostTokenSheetBody(host: host),
      );
    }

    Future<void> openWebLoginPage() async {
      final cookie = await Navigator.of(context).push<String>(
        GrassBagPageRoute<String>(
          builder: (_) => RemoteWebLoginPage(
            hostName: host.name,
            baseAddress: host.address,
            allowBadCertificates: host.allowBadCertificates,
          ),
        ),
      );
      if (cookie != null && cookie.trim().isNotEmpty) {
        await ctrl.updateHostCookie(host.id, cookie, switchAndConnect: true);
      }
    }

    void openOptionalHelperSheet() {
      showGrassBagSheet<void>(
        context,
        title: '可选：安装连接助手 (dsh-gbridge)',
        subtitle: '当前免插件直连已可完整使用；安装助手可额外启用断线增量续传与 SDUI 扩展',
        bodyBuilder: (_) => _InstallHelperSheetBody(host: host),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagCard(
          borderRadius: 24,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  GrassBagSquircleIcon(
                    icon: isAuthError
                        ? CupertinoIcons.lock_shield_fill
                        : CupertinoIcons.desktopcomputer,
                    color: host.isConnectedUsable
                        ? t.ok
                        : (isAuthError ? t.primary : (isTlsError ? t.warn : t.err)),
                    size: 38,
                    iconSize: 19,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(host.name, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: t.text)),
                        Text(host.address, style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: t.text3)),
                      ],
                    ),
                  ),
                  _SmallPill(
                    label: host.isConnectedUsable
                        ? '${host.bridged ? '增强' : '直连'} · ${host.latency}'
                        : (isAuthError
                            ? '待授权'
                            : (isUntrustedHost ? '地址未在白名单' : (isTlsError ? '证书异常' : '未连接'))),
                    bg: host.isConnectedUsable
                        ? t.okSoft
                        : (isAuthError ? t.primarySoft : (isTlsError ? t.warnSoft : t.errSoft)),
                    fg: host.isConnectedUsable
                        ? t.ok
                        : (isAuthError ? t.primary : (isTlsError ? t.warn : t.err)),
                  ),
                ],
              ),
              if (host.lastError != null && host.lastError!.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                  decoration: BoxDecoration(
                    color: (isAuthError ? t.primarySoft : (isTlsError ? t.warnSoft : t.errSoft)),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: (isAuthError ? t.primary : (isTlsError ? t.warn : t.err)).withValues(alpha: 0.35),
                      width: 0.7,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SelectableText(
                        host.lastError!,
contextMenuBuilder: buildGrassBagEditableContextMenu,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.45,
                          color: isAuthError ? t.primary : (isTlsError ? t.warn : t.err),
                        ),
                      ),
                      if (isUntrustedHost || errCode == 'unreachable') ...[
                        const SizedBox(height: 8),
                        GrassBagSpringTap(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: suggestedStartCmd));
                            ctrl.showToast('已复制远程启动命令', tone: ToastTone.ok);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: t.bgSolid.withValues(alpha: t.isDark ? 0.58 : 0.88),
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(color: t.sep, width: 0.6),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    suggestedStartCmd,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11.5,
                                      color: t.text,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(CupertinoIcons.doc_on_doc, size: 14, color: t.primary),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        GrassBagSecondaryGlassButton(
                          label: '复制桌面端一键指令（免命令）',
                          icon: CupertinoIcons.sparkles,
                          height: 32,
                          tier: tier,
                          insideGlass: true,
                          accentForeground: true,
                          onTap: () {
                            Clipboard.setData(
                              const ClipboardData(text: RemoteHostConnectCard.desktopGuiPrompt),
                            );
                            ctrl.showToast(
                              '已复制一键指令，粘贴发给电脑端 DeepSeek Harness 即可开启共享',
                              tone: ToastTone.ok,
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              if (isAuthError) ...[
                Row(
                  children: [
                    if (host.isHtmlProxyAuth && canWebViewLogin && !host.isDesktopLanBridge) ...[
                      Expanded(
                        child: GrassBagPrimaryGlassButton(
                          label: 'App 内网页登录',
                          icon: CupertinoIcons.globe,
                          tier: tier,
                          insideGlass: true,
                          onTap: openWebLoginPage,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GrassBagSecondaryGlassButton(
                          label: '粘贴链接 / Token',
                          icon: CupertinoIcons.lock_open_fill,
                          tier: tier,
                          insideGlass: true,
                          onTap: () => showRemoteHostAuthSheet(context, ref, host),
                        ),
                      ),
                    ] else ...[
                      Expanded(
                        child: GrassBagPrimaryGlassButton(
                          label: '粘贴链接 / Token 并授权',
                          icon: CupertinoIcons.lock_open_fill,
                          tier: tier,
                          insideGlass: true,
                          onTap: () => showRemoteHostAuthSheet(context, ref, host),
                        ),
                      ),
                      if (canWebViewLogin && !host.isDesktopLanBridge) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: GrassBagSecondaryGlassButton(
                            label: '网页登录',
                            icon: CupertinoIcons.globe,
                            tier: tier,
                            insideGlass: true,
                            onTap: openWebLoginPage,
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
                const SizedBox(height: 8),
              ] else if (isTlsError && !host.allowBadCertificates) ...[
                GrassBagPrimaryGlassButton(
                  label: '信任自签名证书并重连',
                  icon: CupertinoIcons.checkmark_shield_fill,
                  tier: tier,
                  insideGlass: true,
                  onTap: () => ctrl.setHostAllowBadCertificates(host.id, true),
                ),
                const SizedBox(height: 8),
              ],
              if (!isCurrent)
                GrassBagPrimaryGlassButton(
                  label: '切换到此主机',
                  tier: tier,
                  insideGlass: true,
                  onTap: () => ctrl.switchHost(host.id),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: t.primarySoft,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '当前正在使用此主机',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.primary),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GrassBagSecondaryGlassButton(
                      label: '重新检测',
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tier: tier,
                      insideGlass: true,
                      onTap: () => ctrl.probeAndRefreshHost(host.id),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 6),
          child: Text('连接模式与能力', style: TextStyle(fontSize: 12, color: t.text3)),
        ),
        GrassBagCard(
          borderRadius: 24,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  GrassBagSquircleIcon(
                    icon: isBridgedReady
                        ? CupertinoIcons.bolt_circle_fill
                        : (isDirectReady
                            ? CupertinoIcons.checkmark_seal_fill
                            : CupertinoIcons.lock_shield_fill),
                    color: isBridgedReady ? t.primary : (isDirectReady ? t.ok : t.warn),
                    size: 36,
                    iconSize: 17,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isBridgedReady
                              ? '增强模式 · 已装连接助手'
                              : (isDirectReady
                                  ? '原生直连 · 免插件可用'
                                  : (isAuthError ? '等待一次鉴权' : '免插件直连通道')),
                          style: TextStyle(fontWeight: FontWeight.w600, color: t.text),
                        ),
                        Text(
                          isBridgedReady
                              ? '助手 v${host.helperVersion ?? '0.1.0'} · DSH ${host.dshVersion}'
                              : (isDirectReady
                                  ? '直连原版 DSH ${host.dshVersion} · 无需在远程安装插件'
                                  : '兼容原版 dsh web（无需安装任何插件）'),
                          style: TextStyle(fontSize: 12, color: t.text3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                isBridgedReady
                    ? '已启用全部原生能力与连接助手，支持断线增量续传、多步轨迹、终端、文件对比与 SDUI 扩展。'
                    : (isDirectReady
                        ? '当前直接通过 DSH 原生协议连接，已完整支持流式对话、思考与工具步骤、模型与渠道配置、工作区文件与实时多标签终端。'
                        : 'GrassBag 支持免插件直连任何原版 dsh web；仅在需要断线增量续传或 SDUI 扩展时才可选安装助手组件。'),
                style: TextStyle(fontSize: 12.5, height: 1.5, color: t.text2),
              ),
              const SizedBox(height: 14),
              if (isBridgedReady)
                GrassBagSecondaryGlassButton(
                  label: '检查连通性与助手状态',
                  tier: tier,
                  insideGlass: true,
                  onTap: () => ctrl.probeAndRefreshHost(host.id),
                )
              else if (isDirectReady)
                Row(
                  children: [
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: '检查连通性',
                        tier: tier,
                        insideGlass: true,
                        onTap: () => ctrl.probeAndRefreshHost(host.id),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: host.installing ? '安装中…' : '可选：安装助手',
                        tier: tier,
                        insideGlass: true,
                        enabled: !host.installing,
                        onTap: host.installing ? null : openOptionalHelperSheet,
                      ),
                    ),
                  ],
                )
              else
                GrassBagSecondaryGlassButton(
                  label: '立即探测并连接',
                  tier: tier,
                  insideGlass: true,
                  onTap: () => ctrl.probeAndRefreshHost(host.id),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        GrassBagGroupedSection(
          children: [
            if (canWebViewLogin && !host.isDesktopLanBridge)
              GrassBagListTile(
                title: const Text('App 内网页登录 / 同步凭证'),
                subtitle: Text(
                  host.hasSavedCookie
                      ? '已缓存 30 天免 Token 凭证（点击可刷新登录）'
                      : '免手动填 Token，支持反向代理 / SSO / 一次性链接',
                ),
                showChevron: true,
                onTap: openWebLoginPage,
              ),
            GrassBagListTile(
              title: const Text('编辑主机名称与地址'),
              subtitle: Text('${host.name} · ${host.address}'),
              showChevron: true,
              onTap: () {
                showGrassBagSheet<void>(
                  context,
                  title: '编辑远程主机',
                  subtitle: '修改显示名称或服务地址（支持直接粘贴 dsh web: http://...）',
                  bodyBuilder: (_) => _HostEditSheetBody(host: host),
                );
              },
            ),
            GrassBagListTile(
              title: const Text('访问令牌 Token（选填）'),
              subtitle: Text(
                (host.token != null && host.token!.isNotEmpty)
                    ? '已配置（点击修改或清空）'
                    : (host.hasSavedCookie ? '留空 · 当前使用 30 天免密 Cookie' : '未配置（选填）'),
              ),
              showChevron: true,
              onTap: openTokenEditorSheet,
            ),
            if (host.hasSavedCookie)
              GrassBagListTile(
                title: const Text('清除已缓存的 30 天登录凭证'),
                subtitle: const Text('下次连接需重新粘贴启动链接或网页登录'),
                onTap: () async {
                  final ok = await showGrassBagConfirmDialog(
                    context,
                    title: '清除「${host.name}」的登录凭证？',
                    message: '清除后下次接入该主机需重新粘贴启动链接或完成网页登录。',
                    confirmLabel: '确认清除',
                    isDestructive: true,
                  );
                  if (ok) ctrl.clearHostCookie(host.id);
                },
              ),
            GrassBagListTile(
              title: const Text('信任自签名 HTTPS 证书'),
              subtitle: const Text('用于局域网 / Tailscale / Caddy 自签证书'),
              trailing: GrassBagGlassSwitch(
                value: host.allowBadCertificates,
                tier: tier,
                onChanged: (v) => ctrl.setHostAllowBadCertificates(host.id, v),
              ),
            ),
            if (!host.isDesktopLanBridge)
              GrassBagListTile(
                title: const Text('在官方网页版中打开'),
                showChevron: true,
                onTap: () async {
                  if (isCurrent) {
                    onOpenWebUi();
                    return;
                  }
                  if (_openingWebUi) return;
                  _openingWebUi = true;
                  try {
                    final ticketUrl = await ctrl.createWebUiTicketUrl(host: host);
                    if (!context.mounted) return;
                    Navigator.of(context).push(
                      GrassBagPageRoute<void>(
                        builder: (_) => OfficialWebPage(
                          initialUrl: ticketUrl ?? host.address,
                          hostName: host.name,
                          allowBadCertificates: host.allowBadCertificates,
                        ),
                      ),
                    );
                  } finally {
                    _openingWebUi = false;
                  }
                },
              ),
            GrassBagListTile(
              title: Text('移除此远程主机', style: TextStyle(color: t.err)),
              onTap: () async {
                final ok = await showGrassBagConfirmDialog(
                  context,
                  title: '移除「${host.name}」？',
                  message: '移除后仅断开本机记录，不会影响远程电脑上的数据与服务。',
                  confirmLabel: '移除',
                  isDestructive: true,
                );
                if (ok) onRemove();
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _BackupPassphraseSheetBody extends ConsumerStatefulWidget {
  const _BackupPassphraseSheetBody();

  @override
  ConsumerState<_BackupPassphraseSheetBody> createState() => _BackupPassphraseSheetBodyState();
}

class _BackupPassphraseSheetBodyState extends ConsumerState<_BackupPassphraseSheetBody> {
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _confirmFocus = FocusNode();
  bool _obscure = true;
  String? _err;

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final p = _passCtrl.text.trim();
    final c = _confirmCtrl.text.trim();
    if (p.length < 6) {
      setState(() => _err = '请输入至少 6 位加密口令，避免使用弱口令');
      return;
    }
    if (p != c) {
      setState(() => _err = '两次输入的加密口令不一致，请核对后再导出');
      return;
    }
    Navigator.of(context).pop();
    ref.read(appProvider.notifier).exportEncryptedBackup(p);
  }

  @override
  Widget build(BuildContext context) {
    final st = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagTextField(
          controller: _passCtrl,
          obscureText: _obscure,
          autofocus: true,
          insideGlass: true,
          textInputAction: TextInputAction.next,
          placeholder: '输入至少 6 位加密口令…',
          fontSize: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          hasError: _err != null,
          suffix: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _obscure = !_obscure),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Icon(
                _obscure ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                size: 17,
                color: st.text3,
              ),
            ),
          ),
          onChanged: (_) {
            if (_err != null) setState(() => _err = null);
          },
          onSubmitted: (_) => _confirmFocus.requestFocus(),
        ),
        const SizedBox(height: 10),
        GrassBagTextField(
          controller: _confirmCtrl,
          focusNode: _confirmFocus,
          obscureText: _obscure,
          insideGlass: true,
          textInputAction: TextInputAction.done,
          placeholder: '再次输入口令以防输错…',
          fontSize: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          hasError: _err != null,
          onChanged: (_) {
            if (_err != null) setState(() => _err = null);
          },
          onSubmitted: (_) => _submit(),
        ),
        if (_err != null) ...[
          const SizedBox(height: 6),
          Text(_err!, style: TextStyle(fontSize: 12, color: st.err)),
        ],
        const SizedBox(height: 12),
        GrassBagPrimaryGlassButton(
          label: '立即加密导出',
          tier: tier,
          insideGlass: true,
          onTap: _submit,
        ),
      ],
    );
  }
}

class _HostTokenSheetBody extends ConsumerStatefulWidget {
  const _HostTokenSheetBody({required this.host});
  final ManagedHost host;

  @override
  ConsumerState<_HostTokenSheetBody> createState() => _HostTokenSheetBodyState();
}

class _HostTokenSheetBodyState extends ConsumerState<_HostTokenSheetBody> {
  late final TextEditingController _tokenCtrl;
  bool _obscureToken = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _tokenCtrl = TextEditingController(text: widget.host.token ?? '');
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    super.dispose();
  }

  static bool _looksLikePlainUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    return RegExp(r'(?:https?|wss?)://', caseSensitive: false).hasMatch(trimmed);
  }

  Future<void> _pasteToken() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty) return;
    final parsed = parseRemoteHostInput(raw);
    if (parsed?.token != null && parsed!.token!.isNotEmpty) {
      setState(() {
        _err = null;
        _tokenCtrl.text = raw;
      });
      return;
    }
    if (_looksLikePlainUrl(raw)) {
      setState(() {
        _err = '该链接未包含 ?token=... 令牌，请复制带完整 token 的启动链接或直接粘贴纯 Token';
      });
      return;
    }
    setState(() {
      _err = null;
      _tokenCtrl.text = raw;
    });
  }

  void _save() {
    final raw = _tokenCtrl.text.trim();
    if (raw.isNotEmpty) {
      final parsed = parseRemoteHostInput(raw);
      if (parsed?.token != null && parsed!.token!.isNotEmpty) {
        Navigator.of(context).pop();
        ref.read(appProvider.notifier).updateHostToken(widget.host.id, raw);
        return;
      }
      if (_looksLikePlainUrl(raw)) {
        setState(() {
          _err = '检测到普通网址（缺少 ?token=... 参数），请粘贴包含 token 的启动链接或纯令牌字符串';
        });
        return;
      }
    }
    Navigator.of(context).pop();
    ref.read(appProvider.notifier).updateHostToken(widget.host.id, raw);
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagTextField(
          controller: _tokenCtrl,
          autofocus: true,
          insideGlass: true,
          monospace: true,
          obscureText: _obscureToken,
          hasError: _err != null,
          placeholder: '粘贴 dsh web: http://.../?token=... 或纯 Token（留空清空）',
          fontSize: 13.5,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          suffix: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _obscureToken = !_obscureToken),
            child: SizedBox(
              width: 34,
              height: 34,
              child: Center(
                child: Icon(
                  _obscureToken ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
                  size: 15,
                  color: t.text3,
                ),
              ),
            ),
          ),
          onChanged: (_) {
            if (_err != null) setState(() => _err = null);
          },
          onSubmitted: (_) => _save(),
        ),
        if (_err != null) ...[
          const SizedBox(height: 6),
          Text(_err!, style: TextStyle(fontSize: 12, color: t.err)),
        ],
        const SizedBox(height: 10),
        GrassBagSecondaryGlassButton(
          label: '从剪贴板智能粘贴并提取 Token',
          icon: CupertinoIcons.doc_on_clipboard,
          height: 36,
          tier: tier,
          insideGlass: true,
          accentForeground: true,
          onTap: _pasteToken,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '取消',
                tier: tier,
                insideGlass: true,
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: '保存并连接',
                icon: CupertinoIcons.checkmark_alt,
                tier: tier,
                insideGlass: true,
                onTap: _save,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _InstallHelperSheetBody extends ConsumerStatefulWidget {
  const _InstallHelperSheetBody({required this.host});
  final ManagedHost host;

  @override
  ConsumerState<_InstallHelperSheetBody> createState() => _InstallHelperSheetBodyState();
}

class _InstallHelperSheetBodyState extends ConsumerState<_InstallHelperSheetBody> {
  final TextEditingController _specCtrl =
      TextEditingController(text: kOfficialGbridgeAcceleratedUrl);

  @override
  void dispose() {
    _specCtrl.dispose();
    super.dispose();
  }

  void _install() {
    final spec = _specCtrl.text.trim();
    Navigator.of(context).pop();
    ref.read(appProvider.notifier).installHelperOnHost(
          widget.host.id,
          packageSpec: spec.isEmpty ? kOfficialGbridgeAcceleratedUrl : spec,
        );
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final curSpec = _specCtrl.text.trim();
    final presets = <(String, String)>[
      ('国内加速源（推荐）', kOfficialGbridgeInstallSpecs[0]),
      ('备用加速源', kOfficialGbridgeInstallSpecs[1]),
      ('GitHub 直连', kOfficialGbridgeDirectUrl),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '通过官方预打包 .tgz（零运行时依赖、~91KB）直接挂载到当前 DSH：零冲突端口、内置桌面端扫码配对面板与断线续传。失败不影响当前免插件直连。',
          style: TextStyle(fontSize: 12, height: 1.45, color: t.text2),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (label, url) in presets)
              GrassBagSpringTap(
                onTap: () => setState(() => _specCtrl.text = url),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: curSpec == url ? t.primarySoft : t.fill1,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: curSpec == url ? t.primary : t.sep,
                      width: curSpec == url ? 0.9 : 0.6,
                    ),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: curSpec == url ? t.primary : t.text2,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        GrassBagTextField(
          controller: _specCtrl,
          insideGlass: true,
          monospace: true,
          placeholder: '官方 .tgz 加速地址或远程本地路径',
          fontSize: 12.5,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _install(),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '取消',
                tier: tier,
                insideGlass: true,
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: '加速远程安装',
                icon: CupertinoIcons.arrow_down_circle_fill,
                tier: tier,
                insideGlass: true,
                onTap: _install,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _HostEditSheetBody extends ConsumerStatefulWidget {
  const _HostEditSheetBody({required this.host});
  final ManagedHost host;

  @override
  ConsumerState<_HostEditSheetBody> createState() => _HostEditSheetBodyState();
}

class _HostEditSheetBodyState extends ConsumerState<_HostEditSheetBody> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _addrCtrl;
  final _addrFocus = FocusNode();
  String? _err;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.host.name);
    _addrCtrl = TextEditingController(text: widget.host.address);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addrCtrl.dispose();
    _addrFocus.dispose();
    super.dispose();
  }

  void _save() {
    final addr = _addrCtrl.text.trim();
    if (addr.isEmpty) {
      setState(() => _err = '请输入有效的主机地址');
      return;
    }
    final parsed = parseRemoteHostInput(addr);
    if (parsed == null) {
      setState(() => _err = '主机地址格式无效，请输入 IP、域名或 http(s)://主机:端口');
      return;
    }
    final parsedUri = Uri.tryParse(parsed.address);
    if (parsedUri != null) {
      final selfMsg = ref.read(appProvider.notifier).selfDeviceGuidanceForUri(parsedUri);
      if (selfMsg != null) {
        setState(() => _err = selfMsg);
        return;
      }
    }
    Navigator.of(context).pop();
    ref.read(appProvider.notifier).updateHostDetails(
          widget.host.id,
          name: _nameCtrl.text.trim(),
          address: addr,
        );
  }

  @override
  Widget build(BuildContext context) {
    final st = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagTextField(
          controller: _nameCtrl,
          insideGlass: true,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _addrFocus.requestFocus(),
          placeholder: '主机显示名称',
          fontSize: 13.5,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        const SizedBox(height: 10),
        GrassBagTextField(
          controller: _addrCtrl,
          focusNode: _addrFocus,
          insideGlass: true,
          monospace: true,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          placeholder: 'http://192.168.x.x:3080 或 https://dsh.example.com',
          fontSize: 13,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          hasError: _err != null,
          onChanged: (_) {
            if (_err != null) setState(() => _err = null);
          },
          onSubmitted: (_) => _save(),
        ),
        if (_err != null) ...[
          const SizedBox(height: 6),
          Text(_err!, style: TextStyle(fontSize: 12, color: st.err)),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '取消',
                tier: tier,
                insideGlass: true,
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: '保存修改',
                icon: CupertinoIcons.checkmark_alt,
                tier: tier,
                insideGlass: true,
                onTap: _save,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Isolated leaf consumer for 200ms-flushed engine logs so streaming logs NEVER
/// rebuild the entire Hosts, Local Detail, or Diagnostics settings screens.
class _EngineLogsConsole extends ConsumerWidget {
  const _EngineLogsConsole({
    required this.showSummaryWhenEmpty,
    this.maxLines = 12,
    this.topSpacing = 0,
    this.headerPrefix = '引擎实时日志',
    this.forceLocal = false,
  });

  final bool showSummaryWhenEmpty;
  final int maxLines;
  final double topSpacing;
  final String headerPrefix;
  final bool forceLocal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          logs: s.engineLogs,
          activeHostId: s.activeHostId,
          activeHostName: s.activeHost.name,
          activeHostIsLocal: s.activeHost.isLocal,
          activeHostDshVersion: s.activeHost.dshVersion,
          activeHostContainerVersion: s.activeHost.containerVersion,
          connectionPhase: s.connectionPhase,
          namespacesCount: s.effectiveDshNamespaces.length,
          activeSlot: s.nativeRuntimeStatus.activeSlot,
        ),
      ),
    );
    final logs = slice.logs;
    if (logs.isEmpty && !showSummaryWhenEmpty) return const SizedBox.shrink();
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final visible = logs.length > maxLines ? logs.sublist(logs.length - maxLines) : logs;
    final showLocalSlot = forceLocal || slice.activeHostIsLocal;
    final slotTag = showLocalSlot && slice.activeSlot.isNotEmpty ? ' (${slice.activeSlot})' : '';
    final canRefresh = forceLocal || slice.activeHostIsLocal;

    final card = RepaintBoundary(
      child: ClipRSuperellipse(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: ShapeDecoration(
          color: t.codeBg,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08), width: 0.6),
          ),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    logs.isEmpty
                        ? '引擎与通道状态摘要'
                        : '$headerPrefix (${logs.length})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    final content = logs.isEmpty
                        ? '[engine] ${slice.activeHostName} · DSH ${slice.activeHostDshVersion}$slotTag\n'
                            '[bridge] 通道状态：${slice.connectionPhase.name} · ${slice.namespacesCount} 组配置模块\n'
                            '[runtime] 环境：${slice.activeHostContainerVersion}'
                        : logs.join('\n');
                    Clipboard.setData(ClipboardData(text: content));
                    ctrl.showToast('已复制引擎日志到剪贴板', tone: ToastTone.ok);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      '复制',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: const Color(0xFF94A3B8)),
                    ),
                  ),
                ),
                if (canRefresh)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => ctrl.refreshEngineLogs(forceLocal: forceLocal),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Text(
                        '刷新',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: GrassBagTokens.resolve(t.accent, Brightness.dark).primaryHi,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (logs.isEmpty) ...[
              Text(
                '[engine] ${slice.activeHostName} · DSH ${slice.activeHostDshVersion}$slotTag',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: Color(0xFF5DD199)),
              ),
              const SizedBox(height: 4),
              Text(
                '[bridge] 通道状态：${slice.connectionPhase.name} · ${slice.namespacesCount} 组配置命名空间',
                style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: t.codeFg),
              ),
              const SizedBox(height: 4),
              Text(
                '[runtime] 环境：${slice.activeHostContainerVersion}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: Color(0xFF94A3B8)),
              ),
            ] else
              for (final line in visible)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2.5),
                  child: Text(
                    line,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: line.contains('READY') || line.contains('200')
                          ? const Color(0xFF5DD199)
                          : (line.contains('ERROR') || line.contains('exited')
                              ? const Color(0xFFF87171)
                              : t.codeFg),
                    ),
                  ),
                ),
          ],
        ),
      ),
      ),
    );
    return topSpacing > 0
        ? Padding(padding: EdgeInsets.only(top: topSpacing), child: card)
        : card;
  }
}

class _SmallPill extends StatelessWidget {
  const _SmallPill({required this.label, required this.bg, required this.fg});
  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}
