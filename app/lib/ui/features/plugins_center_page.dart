import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import '../settings/dsh_settings_sheets.dart';
import 'sdui_extensions_page.dart';

class PluginsCenterPage extends ConsumerStatefulWidget {
  const PluginsCenterPage({super.key});

  @override
  ConsumerState<PluginsCenterPage> createState() => _PluginsCenterPageState();
}

class _PluginsCenterPageState extends ConsumerState<PluginsCenterPage> {
  int _tab = 0; // 0: 已安装, 1: 插件市场, 2: 动态 Cordis
  String _marketQuery = '';
  String _installedQuery = '';
  final TextEditingController _marketSearchCtrl = TextEditingController();
  final TextEditingController _installedSearchCtrl = TextEditingController();
  final Set<String> _busyPluginIds = <String>{};
  Timer? _filterTimer;
  Timer? _searchTimer;
  bool _initialMarketLoaded = false;
  String? _lastServerQuery;
  int _marketReqSeq = 0;

  Future<void> _runMarketSearch(String query) async {
    final normalized = query.trim();
    final seq = ++_marketReqSeq;
    await ref.read(appProvider.notifier).searchPluginMarket(normalized);
    if (!mounted || seq != _marketReqSeq) return;
    final lower = normalized.toLowerCase();
    if (_lastServerQuery != lower) {
      setState(() => _lastServerQuery = lower);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(appProvider.notifier).refreshPluginsAndCordis(silent: true));
    });
  }

  @override
  void dispose() {
    _filterTimer?.cancel();
    _searchTimer?.cancel();
    _marketSearchCtrl.dispose();
    _installedSearchCtrl.dispose();
    super.dispose();
  }

  void _openCustomInstallSheet(BuildContext context) {
    showGrassBagSheet<void>(
      context,
      title: '从包名或 Git 安装插件',
      subtitle: '支持 npm 包名、Git 仓库地址或本地 .tgz 路径',
      bodyBuilder: (sheetCtx) => const _CustomInstallPluginBody(),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(appProvider.select((s) => s.activeHostId), (prev, next) {
      if (prev != null && prev != next && mounted) {
        _filterTimer?.cancel();
        _searchTimer?.cancel();
        _marketSearchCtrl.clear();
        _installedSearchCtrl.clear();
        final connected = ref.read(appProvider).connectionPhase == ConnectionPhase.connected;
        setState(() {
          _marketQuery = '';
          _installedQuery = '';
          _lastServerQuery = null;
          _initialMarketLoaded = _tab == 1 && connected;
        });
        unawaited(ref.read(appProvider.notifier).refreshPluginsAndCordis(silent: true));
        if (_tab == 1 && connected) {
          unawaited(_runMarketSearch(''));
        }
      }
    });
    ref.listen<ConnectionPhase>(appProvider.select((s) => s.connectionPhase), (prev, next) {
      if (next == ConnectionPhase.connected && mounted) {
        final s = ref.read(appProvider);
        if (_tab == 1 && (s.marketError != null || (s.marketPlugins.isEmpty && !s.searchingMarket))) {
          _initialMarketLoaded = true;
          unawaited(_runMarketSearch(_marketQuery));
        } else if (s.plugins.isEmpty) {
          unawaited(ref.read(appProvider.notifier).refreshPluginsAndCordis(silent: true));
        }
      }
    });
    // Tab-scoped Riverpod subscription: market queries never rebuild Installed tab and vice versa!
    ref.watch(
      appProvider.select(
        (s) => (
          installedCount: s.plugins.length,
          enabledCount: s.plugins.where((p) => p.enabled).length,
          dynamicCount: s.dynamicCordis.length,
          tabPayload: switch (_tab) {
            0 => s.plugins,
            1 => (s.marketPlugins, s.searchingMarket, s.marketError),
            _ => s.dynamicCordis,
          },
          glassTier: s.glassTier,
          connectionPhase: s.connectionPhase,
          activeHostBridged: s.activeHost.bridged,
          activeHostDirectMode: s.activeHost.directMode,
          dshNamespaces: s.dshNamespaces,
          sduiSurfaces: s.sduiSurfaces,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final topPad = MediaQuery.viewPaddingOf(context).top;
    final botPad = MediaQuery.viewPaddingOf(context).bottom;
    final isWide = MediaQuery.sizeOf(context).width >= 760;

    return GrassBagGlassPage(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: isWide ? 720 : double.infinity),
                  child: RefreshIndicator.adaptive(
                    edgeOffset: topPad + 74,
                    onRefresh: () async {
                      if (_tab == 1) {
                        await _runMarketSearch(_marketQuery);
                      } else {
                        await ctrl.refreshPluginsAndCordis(silent: true);
                      }
                    },
                    child: CustomScrollView(
                      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                      slivers: [
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(16, topPad + 76, 16, 40 + botPad),
                          sliver: SliverMainAxisGroup(
                            slivers: [
                              SliverToBoxAdapter(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    if (state.connectionPhase != ConnectionPhase.connected) ...[
                                      GrassBagStatusBanner(
                                        tone: GrassBagBannerTone.warn,
                                        icon: CupertinoIcons.wifi_exclamationmark,
                                        title: '未连接到 DSH 主机',
                                        message: '插件管理、市场搜索与动态扩展模块均运行在已连接的 DSH 主机上。',
                                        borderRadius: 18,
                                        padding: const EdgeInsets.all(12),
                                        trailing: GrassBagSecondaryGlassButton(
                                          label: '重试连接',
                                          height: 30,
                                          padding: const EdgeInsets.symmetric(horizontal: 10),
                                          tier: state.glassTier,
                                          insideGlass: true,
                                          accentForeground: true,
                                          onTap: () => unawaited(ctrl.probeAndRefreshHost(state.activeHostId)),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                    ],
                                    GrassBagSegmentedControl(
                                      labels: [
                                        '已安装 (${state.plugins.length})',
                                        '市场',
                                        '动态模块 (${state.dynamicCordis.length})',
                                      ],
                                      selectedIndex: _tab,
                                      tier: state.glassTier,
                                      onSelected: (i) {
                                        setState(() => _tab = i);
                                        if (i == 1 &&
                                            !_initialMarketLoaded &&
                                            state.connectionPhase == ConnectionPhase.connected &&
                                            state.marketPlugins.isEmpty &&
                                            !state.searchingMarket) {
                                          _initialMarketLoaded = true;
                                          unawaited(_runMarketSearch(_marketQuery));
                                        }
                                      },
                                    ),
                                    const SizedBox(height: 14),
                                  ],
                                ),
                              ),
                              if (_tab == 0)
                                SliverToBoxAdapter(
                                  child: _buildInstalled(context, state, ctrl, t),
                                )
                              else if (_tab == 1)
                                ..._buildMarketSlivers(context, state, ctrl, t)
                              else
                                ..._buildDynamicCordisSlivers(context, state, ctrl, t),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GrassBagUnifiedHeader(
                title: '插件与市场',
                subtitle: '${state.plugins.where((p) => p.enabled).length} 个已启用',
                tier: state.glassTier,
                onBack: () => Navigator.of(context).pop(),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GrassBagGlassCircleButton(
                      icon: CupertinoIcons.refresh,
                      tooltip: _tab == 1 ? '刷新插件市场' : '刷新插件列表',
                      tier: state.glassTier,
                      useOwnLayer: false,
                      onTap: () {
                        if (_tab == 1) {
                          unawaited(_runMarketSearch(_marketQuery));
                        } else {
                          unawaited(ctrl.refreshPluginsAndCordis());
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    GrassBagGlassCircleButton(
                      icon: CupertinoIcons.add,
                      tooltip: '安装自定义插件',
                      tier: state.glassTier,
                      useOwnLayer: false,
                      onTap: () {
                        if (!state.isDshConnected) {
                          ctrl.showToast('当前未连接到 DSH 主机，请先恢复连接后再安装插件', tone: ToastTone.warn);
                          return;
                        }
                        _openCustomInstallSheet(context);
                      },
                    ),
                  ],
                ),
              ),
            ),
            const GrassBagToastOverlay(bottomOffset: 28),
          ],
        ),
      ),
    );
  }

  Widget _buildInstalled(
    BuildContext context,
    GrassBagAppState state,
    GrassBagController ctrl,
    GrassBagTokens t,
  ) {
    if (state.plugins.isEmpty) {
      return GrassBagCard(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
        child: Column(
          children: [
            Icon(CupertinoIcons.square_stack_3d_up, size: 30, color: t.text3),
            const SizedBox(height: 10),
            Text('当前主机暂无插件记录', style: TextStyle(fontSize: 14, color: t.text2)),
            const SizedBox(height: 4),
            Text(
              '连接在线 DSH 主机后将自动同步内置与已安装插件',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: t.text3),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                GrassBagPrimaryGlassButton(
                  label: '浏览插件市场',
                  icon: CupertinoIcons.search,
                  tier: state.glassTier,
                  insideGlass: true,
                  height: 36,
                  onTap: () {
                    setState(() => _tab = 1);
                    if (!_initialMarketLoaded &&
                        !state.searchingMarket &&
                        state.connectionPhase == ConnectionPhase.connected) {
                      _initialMarketLoaded = true;
                      unawaited(_runMarketSearch(_marketQuery));
                    }
                  },
                ),
                GrassBagSecondaryGlassButton(
                  label: '刷新插件列表',
                  icon: CupertinoIcons.refresh,
                  tier: state.glassTier,
                  insideGlass: true,
                  height: 36,
                  onTap: () => unawaited(ctrl.refreshPluginsAndCordis()),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final iq = _installedQuery.trim().toLowerCase();
    final visiblePlugins = iq.isEmpty
        ? state.plugins
        : state.plugins
            .where((p) =>
                '${p.name} ${p.id} ${p.desc}'.toLowerCase().contains(iq))
            .toList(growable: false);
    final namespaces = state.effectiveDshNamespaces;
    final hasSdui = state.sduiSurfaces.isNotEmpty;

    DshSettingsNamespace? matchNamespace(PluginItem p) {
      final tail = p.id.split('/').last.toLowerCase();
      final short = tail.startsWith('dsh-') ? tail.substring(4) : tail;
      for (final ns in namespaces) {
        final n = ns.ns.toLowerCase();
        if (n.length < 3) continue;
        if (n == p.id.toLowerCase() || n == tail || n == short) {
          return ns;
        }
      }
      return null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.plugins.length > 5) ...[
          GrassBagGlassSearchBar(
            controller: _installedSearchCtrl,
            placeholder: '筛选已安装插件…',
            tier: state.glassTier,
            insideGlass: true,
            onChanged: (v) => setState(() => _installedQuery = v),
            onSubmitted: (v) => setState(() => _installedQuery = v),
          ),
          const SizedBox(height: 10),
        ],
        if (hasSdui) ...[
          GrassBagCard(
            borderRadius: 20,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: [
                GrassBagSquircleIcon(
                  icon: CupertinoIcons.square_grid_2x2_fill,
                  color: t.dusk,
                  size: 30,
                  iconSize: 15,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '已注册 ${state.sduiSurfaces.length} 个插件动态扩展面板',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: t.text),
                  ),
                ),
                const SizedBox(width: 8),
                GrassBagSecondaryGlassButton(
                  label: '打开面板',
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  tier: state.glassTier,
                  insideGlass: true,
                  accentForeground: true,
                  onTap: () => Navigator.of(context).push(
                    GrassBagPageRoute<void>(builder: (_) => const SduiExtensionsPage()),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        GrassBagGroupedSection(
          header: '当前主机已安装的插件与能力 (${visiblePlugins.length})',
          footer: '内置核心模块常驻运行；可选模块可随时启停，支持配置的插件可直接点按「配置」调整参数。',
          children: visiblePlugins.isEmpty
              ? [
                  GrassBagListTile(
                    title: Text('未找到匹配「$_installedQuery」的插件',
                        style: TextStyle(color: t.text2)),
                    trailing: Text('清空', style: TextStyle(fontSize: 12, color: t.primary)),
                    onTap: () {
                      _installedSearchCtrl.clear();
                      setState(() => _installedQuery = '');
                    },
                  ),
                ]
              : [
                  for (final p in visiblePlugins)
                    () {
                      final busy = _busyPluginIds.contains(p.id);
                      final matchedNs = matchNamespace(p);
                      return GrassBagListTile(
                        leading: GrassBagSquircleIcon(
                          icon: CupertinoIcons.square_stack_3d_up_fill,
                          color: p.enabled ? t.ok : t.text3,
                          size: 34,
                          iconSize: 17,
                        ),
                        title: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (p.version.trim().isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: Text(
                                  p.version.trim().startsWith('v')
                                      ? p.version.trim()
                                      : 'v${p.version.trim()}',
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: t.text3,
                                  ),
                                ),
                              ),
                            Text(
                              p.readOnlyReason != null && p.readOnlyReason!.isNotEmpty
                                  ? '${p.desc} · ${p.readOnlyReason}'
                                  : p.desc,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (matchedNs != null)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: GrassBagSpringTap(
                                  enablePointerGlow: false,
                                  haptic: true,
                                  onTap: () => showDshNamespaceEditorSheet(context, ref, matchedNs),
                                  child: GrassBagFresnelGlassSurface(
                                    isPill: true,
                                    innerWell: true,
                                    interactive: true,
                                    tintColor: t.primarySoft,
                                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                                    child: Text(
                                      '配置',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                        color: t.primary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (p.removable)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Tooltip(
                                  message: '卸载插件',
                                  child: GrassBagSpringTap(
                                    enabled: !busy,
                                    pressedScale: 0.88,
                                    enablePointerGlow: false,
                                    haptic: true,
                                    onTap: () async {
                                      final ok = await showGrassBagConfirmDialog(
                                        context,
                                        title: '卸载插件',
                                        message: '确认从当前主机卸载「${p.name}」吗？',
                                        confirmLabel: '确认卸载',
                                        isDestructive: true,
                                      );
                                      if (!ok || !mounted) return;
                                      setState(() => _busyPluginIds.add(p.id));
                                      try {
                                        await ctrl.removePluginBundle(p.id);
                                      } finally {
                                        if (mounted) {
                                          setState(() => _busyPluginIds.remove(p.id));
                                        }
                                      }
                                    },
                                    child: GrassBagFresnelGlassSurface(
                                      isCircle: true,
                                      innerWell: true,
                                      interactive: !busy,
                                      tintColor: t.errSoft,
                                      width: 38,
                                      height: 38,
                                      alignment: Alignment.center,
                                      child: busy
                                          ? GrassBagActivityIndicator(radius: 6.5, color: t.err)
                                          : Icon(CupertinoIcons.trash, size: 15.5, color: t.err),
                                    ),
                                  ),
                                ),
                              ),
                            if (!p.optional ||
                                p.id.toLowerCase().endsWith('dsh-base') ||
                                p.id.toLowerCase().endsWith('dsh-web-app') ||
                                p.id.toLowerCase().endsWith('dsh-headless') ||
                                p.id.toLowerCase().endsWith('dsh-gbridge') ||
                                p.id.toLowerCase() == 'base')
                              GrassBagFresnelGlassSurface(
                                isPill: true,
                                innerWell: true,
                                padding: const EdgeInsets.symmetric(horizontal: 9.5, vertical: 4),
                                child: Text(
                                  '内置核心',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: t.text3),
                                ),
                              )
                            else if (busy)
                              SizedBox(
                                width: 60,
                                child: Center(
                                  child: GrassBagActivityIndicator(radius: 7.5, color: t.primary),
                                ),
                              )
                            else
                              GrassBagGlassSwitch(
                                value: p.enabled,
                                tier: state.glassTier,
                                onChanged: !state.isDshConnected
                                    ? null
                                    : (_) async {
                                        setState(() => _busyPluginIds.add(p.id));
                                        try {
                                          await ctrl.togglePlugin(p.id);
                                        } finally {
                                          if (mounted) {
                                            setState(() => _busyPluginIds.remove(p.id));
                                          }
                                        }
                                      },
                              ),
                          ],
                        ),
                      );
                    }(),
                ],
        ),
      ],
    );
  }

  List<Widget> _buildMarketSlivers(
    BuildContext context,
    GrassBagAppState state,
    GrassBagController ctrl,
    GrassBagTokens t,
  ) {
    final q = _marketQuery.trim().toLowerCase();
    final serverAuthoritative = !state.searchingMarket && _lastServerQuery == q;
    final tokens = q.isEmpty
        ? const <String>[]
        : q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList(growable: false);
    final filtered = (q.isEmpty || serverAuthoritative)
        ? state.marketPlugins
        : state.marketPlugins.where((p) {
            final hay =
                '${p.displayName} ${p.name} ${p.author} ${p.desc}'.toLowerCase();
            return tokens.every(hay.contains);
          }).toList(growable: false);

    final isDirectNoBridge = !state.activeHost.bridged && state.activeHost.directMode;

    return [
      SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isDirectNoBridge) ...[
              GrassBagStatusBanner(
                tone: GrassBagBannerTone.info,
                icon: CupertinoIcons.sparkles,
                title: '当前为原版 DSH 免插件直连模式',
                message: '在线市场检索需要远程主机启用插件市场接口；如需安装特定包，也可点击右上角「+」输入 npm 包名或 Git 地址直接安装。',
                borderRadius: 16,
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              ),
              const SizedBox(height: 10),
            ],
            GrassBagGlassSearchBar(
              controller: _marketSearchCtrl,
              placeholder: '搜索 DSH 插件市场（支持包名与关键词）…',
              tier: state.glassTier,
              insideGlass: true,
              onSubmitted: (v) {
                _filterTimer?.cancel();
                _searchTimer?.cancel();
                final trimmed = v.trim();
                setState(() => _marketQuery = trimmed);
                unawaited(_runMarketSearch(trimmed));
              },
              onChanged: (v) {
                _filterTimer?.cancel();
                if (v.isEmpty) {
                  if (_marketQuery.isNotEmpty) setState(() => _marketQuery = '');
                } else {
                  _filterTimer = Timer(const Duration(milliseconds: 120), () {
                    if (mounted && _marketQuery != v) {
                      setState(() => _marketQuery = v);
                    }
                  });
                }
                _searchTimer?.cancel();
                final trimmed = v.trim();
                _searchTimer = Timer(const Duration(milliseconds: 350), () {
                  if (!mounted) return;
                  unawaited(_runMarketSearch(trimmed));
                });
              },
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final kw in const ['git', 'web', 'mcp'])
                  GrassBagFilterChip(
                    label: kw,
                    selected: _marketQuery.trim().toLowerCase() == kw,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    fontSize: 11.5,
                    onTap: () {
                      _filterTimer?.cancel();
                      _searchTimer?.cancel();
                      final nextKw = _marketQuery.trim().toLowerCase() == kw ? '' : kw;
                      _marketSearchCtrl.value = TextEditingValue(
                        text: nextKw,
                        selection: TextSelection.collapsed(offset: nextKw.length),
                      );
                      setState(() => _marketQuery = nextKw);
                      unawaited(_runMarketSearch(nextKw));
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (state.searchingMarket)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GrassBagActivityIndicator(radius: 8, color: t.primary),
                    const SizedBox(width: 8),
                    Text('正在检索插件市场…', style: TextStyle(fontSize: 12, color: t.text3)),
                  ],
                ),
              ),
            if (state.marketError != null && state.marketError!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GrassBagStatusBanner(
                  tone: GrassBagBannerTone.error,
                  message: state.marketError!,
                  borderRadius: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                  trailing: GrassBagSecondaryGlassButton(
                    label: '重试',
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    tier: state.glassTier,
                    insideGlass: true,
                    destructive: true,
                    onTap: () => unawaited(_runMarketSearch(_marketQuery)),
                  ),
                ),
              ),
            if (filtered.isEmpty &&
                !state.searchingMarket &&
                (state.marketError == null || state.marketError!.isEmpty))
              GrassBagCard(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
                child: Column(
                  children: [
                    Icon(CupertinoIcons.search, size: 28, color: t.text3),
                    const SizedBox(height: 8),
                    Text(
                      _marketQuery.trim().isEmpty
                          ? '输入关键词实时搜索 DSH 插件注册表，或点击下方直接从包名 / Git 安装'
                          : '未找到与「$_marketQuery」匹配的插件',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: t.text2),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        if (_marketQuery.trim().isNotEmpty)
                          GrassBagSecondaryGlassButton(
                            label: '清除搜索',
                            icon: CupertinoIcons.clear_circled,
                            height: 36,
                            tier: state.glassTier,
                            insideGlass: true,
                            onTap: () {
                              _filterTimer?.cancel();
                              _searchTimer?.cancel();
                              _marketSearchCtrl.clear();
                              setState(() => _marketQuery = '');
                              unawaited(_runMarketSearch(''));
                            },
                          ),
                        GrassBagPrimaryGlassButton(
                          label: '从包名 / Git 安装',
                          icon: CupertinoIcons.add,
                          height: 36,
                          tier: state.glassTier,
                          insideGlass: true,
                          onTap: () => _openCustomInstallSheet(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      if (filtered.isNotEmpty)
        SliverList.builder(
          itemCount: filtered.length,
          itemBuilder: (_, idx) {
            final m = filtered[idx];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: RepaintBoundary(
                child: GrassBagCard(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          GrassBagSquircleIcon(
                            icon: CupertinoIcons.sparkles,
                            color: m.installed ? t.ok : t.primary,
                            size: 36,
                            iconSize: 17,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  m.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.text),
                                ),
                                Text(
                                  () {
                                    final rawVer = m.version.trim();
                                    final verLabel = rawVer.isEmpty
                                        ? ''
                                        : (rawVer.toLowerCase() == 'latest' || rawVer.startsWith('v')
                                            ? rawVer
                                            : 'v$rawVer');
                                    return [
                                      m.name,
                                      if (verLabel.isNotEmpty) verLabel,
                                      if (m.author.trim().isNotEmpty) m.author.trim(),
                                    ].join(' · ');
                                  }(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11.5, color: t.text3),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (m.installed)
                            Tooltip(
                              message: '切换到已安装列表',
                              child: GrassBagSpringTap(
                                enablePointerGlow: false,
                                haptic: true,
                                onTap: () => setState(() => _tab = 0),
                                child: GrassBagFresnelGlassSurface(
                                  isPill: true,
                                  innerWell: true,
                                  interactive: true,
                                  tintColor: t.okSoft,
                                  padding: const EdgeInsets.symmetric(horizontal: 10.5, vertical: 5),
                                  child: Text(
                                    '已安装',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.ok),
                                  ),
                                ),
                              ),
                            )
                          else
                            GrassBagPrimaryGlassButton(
                              label: m.installing ? '安装中…' : '获取',
                              icon: m.installing ? CupertinoIcons.hourglass : null,
                              height: 32,
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                              tier: state.glassTier,
                              insideGlass: true,
                              enabled: !m.installing && state.isDshConnected,
                              onTap: (m.installing || !state.isDshConnected)
                                  ? null
                                  : () => ctrl.installMarketPlugin(m.name),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        m.desc,
                        style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text2),
                      ),
                      GrassBagSmoothDisclosure(
                        expanded: m.installLogs.isNotEmpty,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 9),
                          child: GrassBagFresnelGlassSurface(
                            borderRadius: 12,
                            innerWell: true,
                            paintTopSheen: false,
                            tintColor: t.codeBg,
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      '安装日志 (${m.installLogs.length} 行)',
                                      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: t.text3),
                                    ),
                                    const Spacer(),
                                    GrassBagSpringTap(
                                      enablePointerGlow: false,
                                      haptic: true,
                                      onTap: () {
                                        Clipboard.setData(ClipboardData(text: m.installLogs.join('\n')));
                                        ctrl.showToast('已复制安装日志', tone: ToastTone.ok);
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        child: Text(
                                          '复制',
                                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: t.primary),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxHeight: 160),
                                  child: SingleChildScrollView(
                                    physics: const BouncingScrollPhysics(),
                                    child: SelectableText(
                                      m.installLogs.join('\n'),
                                      contextMenuBuilder: buildGrassBagEditableContextMenu,
                                      style: TextStyle(
                                        fontSize: 11,
                                        height: 1.45,
                                        fontFamily: 'monospace',
                                        color: t.codeFg,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
    ];
  }

  List<Widget> _buildDynamicCordisSlivers(
    BuildContext context,
    GrassBagAppState state,
    GrassBagController ctrl,
    GrassBagTokens t,
  ) {
    if (state.dynamicCordis.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: GrassBagCard(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: Column(
              children: [
                Icon(CupertinoIcons.cube_box, size: 32, color: t.text3),
                const SizedBox(height: 10),
                Text('当前没有运行中的动态扩展模块', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text2)),
                const SizedBox(height: 4),
                Text(
                  '由助手在对话中按需生成的临时工具或服务模块会在此统一管理与启停',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: t.text3),
                ),
                const SizedBox(height: 14),
                GrassBagSecondaryGlassButton(
                  label: '刷新动态模块',
                  icon: CupertinoIcons.refresh,
                  tier: state.glassTier,
                  insideGlass: true,
                  height: 36,
                  onTap: () => unawaited(ctrl.refreshPluginsAndCordis()),
                ),
              ],
            ),
          ),
        ),
      ];
    }

    return [
      SliverList.builder(
        itemCount: state.dynamicCordis.length,
        itemBuilder: (_, idx) {
          final c = state.dynamicCordis[idx];
          final st = c.status.toLowerCase();
          final isRun = st == 'running' || st == 'active';
          final isErr = st == 'error' || st == 'failed';
          final col = isRun ? t.dusk : (isErr ? t.err : t.text3);
          final stLabel = isRun ? '运行中' : (isErr ? '异常' : '已暂停');
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: RepaintBoundary(
              child: GrassBagCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        GrassBagSquircleIcon(
                          icon: CupertinoIcons.cube_box_fill,
                          color: col,
                          size: 36,
                          iconSize: 17,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                c.name,
                                style: TextStyle(
                                  fontSize: 14.5,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w600,
                                  color: t.text,
                                ),
                              ),
                              Text(
                                '$stLabel${c.capabilities.isNotEmpty ? ' · ${c.capabilities.join(' / ')}' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: isErr ? t.err : t.text3,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(c.description, style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text2)),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (isRun)
                          GrassBagSecondaryGlassButton(
                            label: '暂停模块',
                            icon: CupertinoIcons.pause_fill,
                            height: 34,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            tier: state.glassTier,
                            insideGlass: true,
                            enabled: state.isDshConnected,
                            onTap: !state.isDshConnected
                                ? null
                                : () => ctrl.cordisAction(c.id, 'stop'),
                          )
                        else
                          GrassBagSecondaryGlassButton(
                            label: '启动模块',
                            icon: CupertinoIcons.play_fill,
                            height: 34,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            tier: state.glassTier,
                            insideGlass: true,
                            accentForeground: true,
                            enabled: state.isDshConnected,
                            onTap: !state.isDshConnected
                                ? null
                                : () => ctrl.cordisAction(c.id, 'start'),
                          ),
                        GrassBagSecondaryGlassButton(
                          label: '卸载定义',
                          icon: CupertinoIcons.trash,
                          height: 34,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          tier: state.glassTier,
                          insideGlass: true,
                          destructive: true,
                          enabled: state.isDshConnected,
                          onTap: !state.isDshConnected
                              ? null
                              : () async {
                                  final ok = await showGrassBagConfirmDialog(
                                    context,
                                    title: '卸载动态模块',
                                    message: '确认卸载动态扩展模块「${c.name}」吗？',
                                    confirmLabel: '确认卸载',
                                    isDestructive: true,
                                  );
                                  if (ok) {
                                    unawaited(ctrl.cordisAction(c.id, 'undefine'));
                                  }
                                },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ];
  }
}

class _CustomInstallPluginBody extends ConsumerStatefulWidget {
  const _CustomInstallPluginBody();

  @override
  ConsumerState<_CustomInstallPluginBody> createState() => _CustomInstallPluginBodyState();
}

class _CustomInstallPluginBodyState extends ConsumerState<_CustomInstallPluginBody> {
  final TextEditingController _specCtrl = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _specCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final spec = _specCtrl.text.trim();
    if (spec.isEmpty) {
      setState(() => _err = '请输入插件包名、Git 地址或本地路径');
      return;
    }
    if (ref.read(appProvider).connectionPhase != ConnectionPhase.connected) {
      setState(() => _err = '当前未连接到 DSH 主机，请先恢复连接后再安装');
      return;
    }
    ref.read(appProvider.notifier).showToast('正在安装 $spec…', tone: ToastTone.info);
    unawaited(ref.read(appProvider.notifier).installMarketPlugin(spec));
    Navigator.of(context).pop();
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
          controller: _specCtrl,
          autofocus: true,
          insideGlass: true,
          monospace: true,
          textInputAction: TextInputAction.done,
          hasError: _err != null,
          onChanged: (_) {
            if (_err != null) setState(() => _err = null);
          },
          placeholder: '例如 @dsh-plugin/git-lens 或 github:org/repo',
          fontSize: 13.5,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          onSubmitted: (_) => _submit(),
        ),
        if (_err != null) ...[
          const SizedBox(height: 6),
          Text(_err!, style: TextStyle(fontSize: 12, color: t.err)),
        ],
        const SizedBox(height: 16),
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
                label: '立即安装',
                tier: tier,
                insideGlass: true,
                onTap: _submit,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
