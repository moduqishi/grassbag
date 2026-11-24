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
  SettingsSection.general: '通用 对话 权限 审批 预设 角色 折叠 代理 proxy preset permission language locale',
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
  return title.toLowerCase().contains(q) ||
      summary.toLowerCase().contains(q) ||
      groupTitle.toLowerCase().contains(q) ||
      aliases.contains(q);
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
  bool _didAutoPushInitial = false;
  final ValueNotifier<String> _queryNotifier = ValueNotifier<String>('');
  final _searchCtrl = TextEditingController();
  final _detailScrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _selected = widget.initialSection ?? SettingsSection.account;
    _hostDetailId = widget.initialHostDetailId ??
        (widget.initialSection == SettingsSection.local ? 'local' : null);
    if (widget.initialSection != null || widget.initialHostDetailId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _didAutoPushInitial || _isTablet(context)) return;
        _didAutoPushInitial = true;
        final targetSection = widget.initialSection ?? SettingsSection.hosts;
        if (targetSection == SettingsSection.webui) {
          widget.onOpenWebUi();
          return;
        }
        Navigator.of(context).push(
          GrassBagPageRoute<void>(
            builder: (_) => _PhoneSettingsSubpage(
              section: targetSection,
              initialHostDetailId: widget.initialHostDetailId ??
                  (targetSection == SettingsSection.local ? 'local' : null),
              onOpenWebUi: widget.onOpenWebUi,
            ),
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _queryNotifier.dispose();
    _searchCtrl.dispose();
    _detailScrollCtrl.dispose();
    super.dispose();
  }

  void _resetDetailScroll() {
    if (_detailScrollCtrl.hasClients && _detailScrollCtrl.offset > 0) {
      _detailScrollCtrl.jumpTo(0);
    }
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
      _resetDetailScroll();
      setState(() {
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
                                      _resetDetailScroll();
                                      setState(() => _hostDetailId = null);
                                    },
                                  ),
                                  const SizedBox(width: 10),
                                ],
                                Expanded(
                                  child: Text(
                                    rightTitle,
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: -0.3,
                                      color: t.text,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: SingleChildScrollView(
                                  controller: _detailScrollCtrl,
                                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                                  padding: EdgeInsets.fromLTRB(
                                    24,
                                    4,
                                    24,
                                    40 + MediaQuery.viewPaddingOf(context).bottom,
                                  ),
                                  child: Center(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 620),
                                      child: AnimatedSwitcher(
                                        duration: const Duration(milliseconds: 180),
                                        switchInCurve: Curves.easeOutCubic,
                                        switchOutCurve: Curves.easeInCubic,
                                        layoutBuilder: (currentChild, previousChildren) => Stack(
                                          alignment: Alignment.topCenter,
                                          children: [
                                            ...previousChildren,
                                            if (currentChild != null) currentChild,
                                          ],
                                        ),
                                        child: KeyedSubtree(
                                          key: ValueKey('${_selected.name}-${_hostDetailId ?? ''}'),
                                          child: _SettingsDetailBody(
                                            section: _selected,
                                            hostDetailId: _hostDetailId,
                                            onSelectHostDetail: (id) {
                                              _resetDetailScroll();
                                              setState(() => _hostDetailId = id);
                                            },
                                            onHostRemoved: () {
                                              _resetDetailScroll();
                                              setState(() => _hostDetailId = null);
                                            },
                                            onOpenSection: _selectSection,
                                            onOpenWebUi: widget.onOpenWebUi,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                height: 16,
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          t.feather,
                                          t.feather.withValues(alpha: 0.0),
                                        ],
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
                  topInsetPadding: topPad + 70,
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

  @override
  void initState() {
    super.initState();
    _hostDetailId = widget.initialHostDetailId;
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
          setState(() => _hostDetailId = null);
        }
      },
      child: GrassBagGlassPage(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              Positioned.fill(
                child: SingleChildScrollView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  padding: EdgeInsets.fromLTRB(16, topPad + 70, 16, 44 + botPad),
                  child: _SettingsDetailBody(
                    section: widget.section,
                    hostDetailId: _hostDetailId,
                    onSelectHostDetail: (id) => setState(() => _hostDetailId = id),
                    onHostRemoved: () => setState(() => _hostDetailId = null),
                    onOpenSection: (sec) {
                      Navigator.of(context).push(
                        GrassBagPageRoute<void>(
                          builder: (_) => _PhoneSettingsSubpage(
                            section: sec,
                            onOpenWebUi: widget.onOpenWebUi,
                          ),
                        ),
                      );
                    },
                    onOpenWebUi: widget.onOpenWebUi,
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
                      setState(() => _hostDetailId = null);
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
          dshNamespaces: s.dshNamespaces,
          dshSettingsSections: s.dshSettingsSections,
          presets: s.presets,
          permissionTiers: s.permissionTiers,
          activePresetId: s.activePresetId,
          activePermissionId: s.activePermissionId,
          modelName: s.modelName,
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
        SettingsSection.model => (state.isDshConnected && state.routableProviders.isEmpty)
            ? '去配置'
            : (state.modelName.isEmpty ? '未配置' : state.modelName),
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
    final accountMatchesSearch = q.isEmpty || accountSearchHaystack.contains(q);

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

    final isAndroidNative = GrassBagNativeBridge.instance.isAndroidNative;
    final envReady = state.connectionPhase == ConnectionPhase.connected;
    final modelReady = state.routableProviders.isNotEmpty;
    final phoneReady = perms.accessibilityEnabled;
    final showReadinessChecklist = q.isEmpty && (!envReady || !modelReady);

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

        if (showReadinessChecklist) ...[
          _SettingsReadinessChecklistCard(
            envReady: envReady,
            envHint: curHost.needsAuth
                ? '主机待授权'
                : (envReady ? '已就绪' : '点击初始化或连接主机'),
            modelReady: modelReady,
            modelHint: modelReady ? '已就绪' : '登录 DeepSeek 或填 API Key',
            showPhoneStep: isAndroidNative,
            phoneReady: phoneReady,
            phoneHint: phoneReady ? '已开启' : '可选 · 开启无障碍即可操控手机',
            onTapEnv: () => onSelect(SettingsSection.hosts),
            onTapModel: () => onSelect(SettingsSection.model),
            onTapPhone: () => onSelect(SettingsSection.permissions),
          ),
          SizedBox(height: isSplit ? 10 : 16),
        ],

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
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: state.hostIsHealthy(curHost)
                                ? t.ok
                                : (curHost.needsAuth
                                    ? t.primary
                                    : (state.hostHasError(curHost) ? t.err : t.warn)),
                            shape: BoxShape.circle,
                          ),
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
                              constraints: BoxConstraints(maxWidth: isSplit ? 108 : 136),
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
                              constraints: BoxConstraints(maxWidth: isSplit ? 108 : 136),
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

class _SettingsReadinessChecklistCard extends StatelessWidget {
  const _SettingsReadinessChecklistCard({
    required this.envReady,
    required this.envHint,
    required this.modelReady,
    required this.modelHint,
    required this.showPhoneStep,
    required this.phoneReady,
    required this.phoneHint,
    required this.onTapEnv,
    required this.onTapModel,
    required this.onTapPhone,
  });

  final bool envReady;
  final String envHint;
  final bool modelReady;
  final String modelHint;
  final bool showPhoneStep;
  final bool phoneReady;
  final String phoneHint;
  final VoidCallback onTapEnv;
  final VoidCallback onTapModel;
  final VoidCallback onTapPhone;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final total = showPhoneStep ? 3 : 2;
    final done = (envReady ? 1 : 0) + (modelReady ? 1 : 0) + (showPhoneStep && phoneReady ? 1 : 0);

    Widget stepPill({
      required String index,
      required String title,
      required bool completed,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: GrassBagSpringTap(
          onTap: onTap,
          pressedScale: 0.96,
          haptic: true,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            decoration: BoxDecoration(
              color: completed ? t.okSoft : t.fill1,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: completed ? t.ok.withValues(alpha: 0.25) : t.sep,
                width: 0.6,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  completed ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                  size: 13.5,
                  color: completed ? t.ok : t.primary,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    '$index.$title',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: completed ? t.ok : t.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final nextHint = !envReady
        ? envHint
        : (!modelReady ? modelHint : phoneHint);

    return GrassBagCard(
      borderRadius: 20,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(CupertinoIcons.sparkles, size: 13.5, color: t.primary),
              const SizedBox(width: 5),
              Text(
                '快速就绪',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  nextHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: t.text3),
                ),
              ),
              const SizedBox(width: 6),
              _SmallPill(
                label: '$done/$total',
                bg: t.primarySoft,
                fg: t.primary,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              stepPill(
                index: '1',
                title: '环境',
                completed: envReady,
                onTap: onTapEnv,
              ),
              const SizedBox(width: 6),
              stepPill(
                index: '2',
                title: '模型',
                completed: modelReady,
                onTap: onTapModel,
              ),
              if (showPhoneStep) ...[
                const SizedBox(width: 6),
                stepPill(
                  index: '3',
                  title: '手机',
                  completed: phoneReady,
                  onTap: onTapPhone,
                ),
              ],
            ],
          ),
        ],
      ),
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
    // Narrow section-aware watch: background chat streaming, turns, toasts, and
    // sidebar search NEVER rebuild Settings detail panels!
    ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          isDark: s.isDark,
          accent: s.accent,
          hosts: s.hosts,
          activeHostId: s.activeHostId,
          connectionPhase: s.connectionPhase,
          dshSettingsSections: s.dshSettingsSections,
          sectionPayload: switch (section) {
            SettingsSection.account => (
                s.accountSnapshot,
                s.accountSigningIn,
                s.providerCredentials,
                s.routableProviders,
              ),
            SettingsSection.general => (
                s.activePresetId,
                s.activePermissionId,
                s.autoFoldSteps,
                s.useSystemProxy,
                s.dshNamespaces,
                s.dshDynamicOptions,
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
            SettingsSection.permissions => (s.nativePermissions,),
            SettingsSection.phone => (
                s.phoneAccessibility,
                s.phoneOverlay,
                s.phoneShizuku,
                s.phoneConfirmHighRisk,
                s.emergencyStopped,
                s.safetyPolicy,
                s.safetyAudit,
                s.nativePermissions,
              ),
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
            _ => (s.dshNamespaces, s.plugins, s.mcpServers),
          },
        ),
      ),
    );
    final state = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);

    if (hostDetailId != null &&
        (section == SettingsSection.hosts || section == SettingsSection.local)) {
      final host = state.hosts.firstWhere(
        (h) => h.id == hostDetailId,
        orElse: () => state.localHost,
      );
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
                                Text(
                                  'DeepSeek 账号',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: -0.3,
                                    color: t.text,
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
                          Flexible(
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
                      final u = links['usageUrl'].toString();
                      if (kIsWeb) {
                        openUrlInNewTab(u);
                      } else if (GrassBagNativeBridge.instance.isAndroidNative) {
                        final ok = await GrassBagNativeBridge.instance.openExternalUrl(u);
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
                                  .copyWith(blur: 4.0, shadow: const []),
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
                    activeColor: t.ok,
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
                                      color: acc.swatchFor(t.isDark).computeLuminance() > 0.50
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
              padding: const EdgeInsets.only(left: 6, bottom: 6),
              child: Text('添加远程主机', style: TextStyle(fontSize: 12, color: t.text3)),
            ),
            RemoteHostConnectCard(
              connectImmediately: true,
              showHeader: true,
              initiallyShowGuide: remotes.isEmpty,
              onConnectedHost: (added) => onSelectHostDetail(added.id),
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
        final perms = state.nativePermissions;
        final needsRetoggle = perms.accessibilityNeedsRetoggle;
        final isAndroid = GrassBagNativeBridge.instance.isAndroidNative;
        final canRunSafeDemo = isAndroid &&
            perms.accessibilityEnabled &&
            !state.emergencyStopped &&
            state.isDshConnected &&
            state.routableProviders.isNotEmpty;
        const policies = ['ask', 'allow_turn', 'always'];
        final polIdx = policies.indexOf(state.safetyPolicy).clamp(0, 2);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (needsRetoggle || !perms.accessibilityEnabled) ...[
              GrassBagStatusBanner(
                tone: needsRetoggle ? GrassBagBannerTone.error : GrassBagBannerTone.warn,
                icon: needsRetoggle
                    ? CupertinoIcons.exclamationmark_triangle_fill
                    : CupertinoIcons.hand_draw_fill,
                title: needsRetoggle
                    ? '无障碍开关已开，但系统未绑定服务'
                    : '尚未开启无障碍屏幕操控权限',
                message: needsRetoggle
                    ? '请前往无障碍设置先关闭再重新开启「GrassBag」，并在权限管理中关闭电池优化与解锁受限设置。'
                    : '完成下方 3 项权限准备后，即可直接用自然语言让助手帮你操作手机。',
                padding: const EdgeInsets.all(14),
                borderRadius: 20,
                action: Row(
                  children: [
                    Expanded(
                      child: GrassBagPrimaryGlassButton(
                        label: needsRetoggle ? '重开无障碍开关' : '去开启无障碍',
                        height: 34,
                        tier: state.glassTier,
                        insideGlass: true,
                        onTap: () => GrassBagNativeBridge.instance
                            .openPermissionSettings('accessibility'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GrassBagSecondaryGlassButton(
                      label: perms.sdkInt >= 33 ? '解锁指南' : '权限管理',
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tier: state.glassTier,
                      insideGlass: true,
                      onTap: () => Navigator.of(context).push(
                        GrassBagPageRoute<void>(builder: (_) => const PermissionsCenterPage()),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
            if (isAndroid) ...[
              GrassBagGroupedSection(
                header: '手机操控就绪检查',
                dividerIndent: 54,
                children: [
                  GrassBagListTile(
                    leading: Icon(
                      perms.accessibilityEnabled
                          ? CupertinoIcons.checkmark_circle_fill
                          : CupertinoIcons.circle,
                      size: 19,
                      color: perms.accessibilityEnabled ? t.ok : t.warn,
                    ),
                    title: const Text('必需：无障碍屏幕操控'),
                    subtitle: Text(
                      perms.accessibilityEnabled ? '运行正常 · 可识别屏幕并执行操控' : '未开启 · 点击前往系统无障碍',
                    ),
                    trailing: _SmallPill(
                      label: perms.accessibilityEnabled ? '已就绪' : '去开启',
                      bg: perms.accessibilityEnabled ? t.okSoft : t.warnSoft,
                      fg: perms.accessibilityEnabled ? t.ok : t.warn,
                    ),
                    onTap: () => GrassBagNativeBridge.instance
                        .openPermissionSettings('accessibility'),
                  ),
                  GrassBagListTile(
                    leading: Icon(
                      perms.overlayGranted
                          ? CupertinoIcons.checkmark_circle_fill
                          : CupertinoIcons.circle,
                      size: 19,
                      color: perms.overlayGranted ? t.ok : t.text3,
                    ),
                    title: const Text('推荐：悬浮急停球'),
                    subtitle: Text(
                      perms.overlayGranted ? '已授权 · 自动化时随时一键暂停' : '跨应用执行时展示悬浮急停按钮',
                    ),
                    trailing: _SmallPill(
                      label: perms.overlayGranted ? '已授权' : '去开启',
                      bg: perms.overlayGranted ? t.okSoft : t.fill1,
                      fg: perms.overlayGranted ? t.ok : t.text2,
                    ),
                    onTap: () => GrassBagNativeBridge.instance
                        .openPermissionSettings('overlay'),
                  ),
                  GrassBagListTile(
                    leading: Icon(
                      perms.batteryOptIgnored
                          ? CupertinoIcons.checkmark_circle_fill
                          : CupertinoIcons.circle,
                      size: 19,
                      color: perms.batteryOptIgnored ? t.ok : t.text3,
                    ),
                    title: const Text('稳定：忽略电池优化'),
                    subtitle: Text(
                      perms.batteryOptIgnored ? '已允许后台保活' : '防止锁屏或切后台时断开无障碍连接',
                    ),
                    trailing: _SmallPill(
                      label: perms.batteryOptIgnored ? '已允许' : '去设置',
                      bg: perms.batteryOptIgnored ? t.okSoft : t.fill1,
                      fg: perms.batteryOptIgnored ? t.ok : t.text2,
                    ),
                    onTap: () => GrassBagNativeBridge.instance
                        .openPermissionSettings('battery'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            if (canRunSafeDemo) ...[
              GrassBagCard(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    GrassBagSquircleIcon(
                      icon: CupertinoIcons.sparkles,
                      color: t.ok,
                      size: 36,
                      iconSize: 17,
                      filled: true,
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '手机操控已就绪',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '发送一条安全指令验证屏幕自动化通路',
                            style: TextStyle(fontSize: 11.5, color: t.text3),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    GrassBagPrimaryGlassButton(
                      label: '试一试',
                      icon: CupertinoIcons.play_fill,
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tier: state.glassTier,
                      insideGlass: true,
                      onTap: () {
                        Navigator.of(context).popUntil((route) => route.isFirst);
                        unawaited(ctrl.sendPrompt('请帮我打开手机的系统设置页面'));
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
            GrassBagCard(
              padding: const EdgeInsets.all(15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      GrassBagSquircleIcon(
                        icon: CupertinoIcons.shield_lefthalf_fill,
                        color: t.primary,
                        size: 36,
                        iconSize: 17,
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '手机操控安全护栏',
                              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.text),
                            ),
                            Text(
                              '银行/支付/系统设置/密码框始终硬拦截，不可绕过',
                              style: TextStyle(fontSize: 11.5, color: t.text3),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  GrassBagSegmentedControl(
                    labels: const ['每次询问', '本轮允许', '免确认'],
                    selectedIndex: polIdx,
                    tier: state.glassTier,
                    onSelected: (i) => ctrl.setSafetyPolicy(policies[i]),
                  ),
                  const SizedBox(height: 10),
                  if (state.emergencyStopped) ...[
                    GrassBagStatusBanner(
                      tone: GrassBagBannerTone.error,
                      icon: CupertinoIcons.exclamationmark_octagon_fill,
                      message: '当前已处于急停锁定状态，所有操控与自动化调用均被阻断。',
                      borderRadius: 14,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    ),
                    const SizedBox(height: 8),
                    GrassBagPrimaryGlassButton(
                      label: '解除急停锁（恢复手机操控）',
                      icon: CupertinoIcons.play_circle_fill,
                      tier: state.glassTier,
                      insideGlass: true,
                      onTap: ctrl.resetEmergencyStop,
                    ),
                  ] else
                    GrassBagSecondaryGlassButton(
                      label: '紧急急停（立刻终止一切操控与生成）',
                      icon: CupertinoIcons.stop_circle_fill,
                      tier: state.glassTier,
                      insideGlass: true,
                      destructive: true,
                      onTap: ctrl.triggerEmergencyStop,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GrassBagGroupedSection(
              header: '操控安全与系统授权',
              children: [
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.checkmark_shield_fill,
                    color: needsRetoggle ? t.err : (perms.accessibilityEnabled ? t.ok : t.primary),
                    size: 32,
                    iconSize: 15,
                  ),
                  title: const Text('打开统一权限管理中心'),
                  subtitle: Text(
                    '已授权 ${perms.grantedCoreCount}/6 项 · 管理无障碍、悬浮窗、保活与存储',
                  ),
                  showChevron: true,
                  onTap: () => Navigator.of(context).push(
                    GrassBagPageRoute<void>(builder: (_) => const PermissionsCenterPage()),
                  ),
                ),
                GrassBagListTile(
                  title: const Text('高风险操作前二次确认'),
                  subtitle: const Text('涉及敏感文本与删除动作前强制弹窗询问'),
                  trailing: GrassBagGlassSwitch(
                    value: state.phoneConfirmHighRisk,
                    tier: state.glassTier,
                    activeColor: t.ok,
                    onChanged: (v) => ctrl.setPhoneSetting(confirmHighRisk: v),
                  ),
                ),
              ],
            ),
            if (state.safetyAudit.isNotEmpty) ...[
              const SizedBox(height: 14),
              GrassBagGroupedSection(
                header: '最近安全审计记录 (${state.safetyAudit.length})',
                children: [
                  for (final entry in state.safetyAudit.take(5))
                    GrassBagListTile(
                      title: Text(
                        entry['tool']?.toString() ?? 'tool',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                      ),
                      subtitle: Text(entry['reason']?.toString() ?? ''),
                      trailing: _SmallPill(
                        label: entry['allowed'] == true ? '放行' : '拦截',
                        bg: entry['allowed'] == true ? t.okSoft : t.errSoft,
                        fg: entry['allowed'] == true ? t.ok : t.err,
                      ),
                    ),
                ],
              ),
            ],
          ],
        );

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
            Row(
              children: [
                Expanded(
                  child: GrassBagCard(
                    borderRadius: 22,
                    padding: const EdgeInsets.all(14),
                    child: Column(
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

class _HostDetailSection extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
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
                          onTap: () => unawaited(ctrl.stopLocalEngine()),
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
                        label: appState.checkingUpdate
                            ? '检测中…'
                            : (updateCheck != null && !updateCheck.hasUpdate && updateCheck.error == null
                                ? '已是最新'
                                : '检查更新'),
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 11),
                        tier: tier,
                        insideGlass: true,
                        enabled: !appState.checkingUpdate,
                        accentForeground: updateCheck == null || updateCheck.error != null,
                        onTap: appState.checkingUpdate ? null : () => ctrl.checkForDshUpdates(),
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
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        () {
                          final configuredProot =
                              rt.configuredExecutorMode.startsWith('proot');
                          final fellBackToProot = !configuredProot &&
                              rt.engineRunning &&
                              rt.executorMode.startsWith('proot');
                          if (configuredProot) return '兼容 (PRoot)';
                          if (fellBackToProot) return '高速 (当前回退 PRoot)';
                          return '高速 (tawcroot)';
                        }(),
                        style: TextStyle(fontSize: 12.5, color: t.text3),
                      ),
                      const SizedBox(width: 4),
                      Icon(CupertinoIcons.chevron_right, size: 13.5, color: t.text3),
                    ],
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
                    activeColor: t.ok,
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
                    activeColor: t.primary,
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
                  subtitle: const Text('清理 proot-tmp、npm 缓存与过期快照，保留 /root 资料'),
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
            ),
            const SizedBox(height: 16),
            GrassBagGroupedSection(
              header: '容器工具链扩展市场',
              dividerIndent: 56,
              children: [
                for (final tk in appState.containerToolkits)
                  GrassBagListTile(
                    leading: GrassBagSquircleIcon(
                      icon: tk.installed ? CupertinoIcons.checkmark_alt_circle_fill : CupertinoIcons.cube_box,
                      color: tk.installed ? t.ok : t.primary,
                      size: 32,
                      iconSize: 15,
                    ),
                    title: Text(tk.name, style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
                    subtitle: Text('${tk.desc} · ${tk.sizeLabel}'),
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
    final isUntrustedHost = errCode == 'untrusted_host' || errLower.contains('403');
    final isTlsError = errCode == 'tls_cert' || errLower.contains('handshake');
    final isDirectReady = host.directMode && host.online;
    final canWebViewLogin = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final parsedUri = Uri.tryParse(host.address);
    final hostLiteral = parsedUri?.host ?? host.address;
    final portFlag = (parsedUri != null && parsedUri.hasPort && parsedUri.port != 3080)
        ? ' --port ${parsedUri.port}'
        : '';
    final isIpHost = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(hostLiteral);
    final suggestedStartCmd = isUntrustedHost
        ? (isIpHost
            ? 'dsh web --host $hostLiteral$portFlag --no-open'
            : 'dsh web --trusted-host ${parsedUri?.hasPort == true ? '$hostLiteral:${parsedUri!.port}' : hostLiteral}$portFlag --no-open')
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
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              if (isAuthError) ...[
                Row(
                  children: [
                    if (host.isHtmlProxyAuth && canWebViewLogin) ...[
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
                      if (canWebViewLogin) ...[
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
              ] else if (isTlsError) ...[
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
                    icon: host.bridged
                        ? CupertinoIcons.bolt_circle_fill
                        : (isDirectReady
                            ? CupertinoIcons.checkmark_seal_fill
                            : CupertinoIcons.lock_shield_fill),
                    color: host.bridged ? t.primary : (isDirectReady ? t.ok : t.warn),
                    size: 36,
                    iconSize: 17,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          host.bridged
                              ? '增强模式 · 已装连接助手'
                              : (isDirectReady
                                  ? '原生直连 · 免插件可用'
                                  : (isAuthError ? '等待一次鉴权' : '免插件直连通道')),
                          style: TextStyle(fontWeight: FontWeight.w600, color: t.text),
                        ),
                        Text(
                          host.bridged
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
                host.bridged
                    ? '已启用全部原生能力与连接助手，支持断线增量续传、多步轨迹、终端、文件对比与 SDUI 扩展。'
                    : (isDirectReady
                        ? '当前直接通过 DSH 原生协议连接，已完整支持流式对话、思考与工具步骤、模型与渠道配置、工作区文件与实时多标签终端。'
                        : 'GrassBag 支持免插件直连任何原版 dsh web；仅在需要断线增量续传或 SDUI 扩展时才可选安装助手组件。'),
                style: TextStyle(fontSize: 12.5, height: 1.5, color: t.text2),
              ),
              const SizedBox(height: 14),
              if (host.bridged)
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
            if (canWebViewLogin)
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
                activeColor: t.primary,
                onChanged: (v) => ctrl.setHostAllowBadCertificates(host.id, v),
              ),
            ),
            GrassBagListTile(
              title: const Text('在官方网页版中打开'),
              showChevron: true,
              onTap: () async {
                if (isCurrent) {
                  onOpenWebUi();
                  return;
                }
                final ticketUrl = await ctrl.createWebUiTicketUrl(host: host);
                if (!context.mounted) return;
                Navigator.of(context).push(
                  GrassBagPageRoute<void>(
                    builder: (_) => OfficialWebPage(
                      initialUrl: ticketUrl ?? host.address,
                    ),
                  ),
                );
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
  String? _err;

  @override
  void dispose() {
    _passCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final p = _passCtrl.text.trim();
    if (p.length < 6) {
      setState(() => _err = '请输入至少 6 位加密口令，避免使用弱口令');
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
          obscureText: true,
          autofocus: true,
          insideGlass: true,
          placeholder: '输入至少 6 位加密口令…',
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
    final lower = value.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('ws://') ||
        lower.startsWith('wss://');
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
        _tokenCtrl.text = parsed.token!;
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
        ref.read(appProvider.notifier).updateHostToken(widget.host.id, parsed.token!);
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
          hasError: _err != null,
          placeholder: '粘贴 dsh web: http://.../?token=... 或纯 Token（留空清空）',
          fontSize: 13.5,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
  final TextEditingController _specCtrl = TextEditingController(text: 'dsh-gbridge');

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
          packageSpec: spec.isEmpty ? 'dsh-gbridge' : spec,
        );
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '可填 npm 包名、Git 仓库地址或远程电脑本地路径（如 /path/to/packages/dsh-gbridge）。安装失败不会影响当前免插件直连。',
          style: TextStyle(fontSize: 12, height: 1.45, color: t.text2),
        ),
        const SizedBox(height: 10),
        GrassBagTextField(
          controller: _specCtrl,
          insideGlass: true,
          monospace: true,
          placeholder: 'dsh-gbridge 或远程本地路径 / git URL',
          fontSize: 13,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
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
                label: '开始远程安装',
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
  });

  final bool showSummaryWhenEmpty;
  final int maxLines;
  final double topSpacing;
  final String headerPrefix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(appProvider.select((s) => s.engineLogs));
    if (logs.isEmpty && !showSummaryWhenEmpty) return const SizedBox.shrink();
    final state = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final visible = logs.length > maxLines ? logs.sublist(logs.length - maxLines) : logs;

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
                        ? '[engine] ${state.activeHost.name} · DSH ${state.activeHost.dshVersion} (${state.nativeRuntimeStatus.activeSlot})\n'
                            '[bridge] 通道状态：${state.connectionPhase.name} · ${state.effectiveDshNamespaces.length} 组配置模块\n'
                            '[runtime] 环境：${state.activeHost.containerVersion}'
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
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: ctrl.refreshEngineLogs,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      '刷新',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.primary),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (logs.isEmpty) ...[
              Text(
                '[engine] ${state.activeHost.name} · DSH ${state.activeHost.dshVersion} (${state.nativeRuntimeStatus.activeSlot})',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: Color(0xFF5DD199)),
              ),
              const SizedBox(height: 4),
              Text(
                '[bridge] 通道状态：${state.connectionPhase.name} · ${state.effectiveDshNamespaces.length} 组配置命名空间',
                style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: t.codeFg),
              ),
              const SizedBox(height: 4),
              Text(
                '[runtime] 环境：${state.activeHost.containerVersion}',
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
