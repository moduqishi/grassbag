import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';

class PluginsCenterPage extends ConsumerStatefulWidget {
  const PluginsCenterPage({super.key});

  @override
  ConsumerState<PluginsCenterPage> createState() => _PluginsCenterPageState();
}

class _PluginsCenterPageState extends ConsumerState<PluginsCenterPage> {
  int _tab = 0; // 0: 已安装, 1: 插件市场, 2: 动态 Cordis
  String _marketQuery = '';
  final TextEditingController _marketSearchCtrl = TextEditingController();
  Timer? _searchTimer;
  bool _initialMarketLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(appProvider.notifier).refreshPluginsAndCordis(silent: true));
    });
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _marketSearchCtrl.dispose();
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
        _searchTimer?.cancel();
        _marketSearchCtrl.clear();
        setState(() {
          _marketQuery = '';
          _initialMarketLoaded = false;
        });
        unawaited(ref.read(appProvider.notifier).refreshPluginsAndCordis(silent: true));
      }
    });
    ref.watch(
      appProvider.select(
        (s) => (
          plugins: s.plugins,
          marketPlugins: s.marketPlugins,
          searchingMarket: s.searchingMarket,
          marketError: s.marketError,
          dynamicCordis: s.dynamicCordis,
          glassTier: s.glassTier,
          connectionPhase: s.connectionPhase,
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
                  child: ListView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                    padding: EdgeInsets.fromLTRB(16, topPad + 72, 16, 40 + botPad),
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
                              state.marketPlugins.isEmpty &&
                              !state.searchingMarket) {
                            _initialMarketLoaded = true;
                            unawaited(ctrl.searchPluginMarket(_marketQuery.trim()));
                          }
                        },
                      ),
                      const SizedBox(height: 14),
                      if (_tab == 0) _buildInstalled(context, state, ctrl, t),
                      if (_tab == 1) _buildMarket(context, state, ctrl, t),
                      if (_tab == 2) _buildDynamicCordis(context, state, ctrl, t),
                    ],
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
                      tooltip: '刷新插件列表',
                      tier: state.glassTier,
                      useOwnLayer: false,
                      onTap: () => unawaited(ctrl.refreshPluginsAndCordis()),
                    ),
                    const SizedBox(width: 8),
                    GrassBagGlassCircleButton(
                      icon: CupertinoIcons.add,
                      tooltip: '安装自定义插件',
                      tier: state.glassTier,
                      useOwnLayer: false,
                      onTap: () => _openCustomInstallSheet(context),
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
                    if (!_initialMarketLoaded && !state.searchingMarket) {
                      _initialMarketLoaded = true;
                      unawaited(ctrl.searchPluginMarket(_marketQuery.trim()));
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

    return GrassBagGroupedSection(
      header: '当前主机已安装的插件与能力',
      footer: '内置核心模块常驻运行；可选模块可随时启停，已安装的外部插件支持卸载。',
      children: [
        for (final p in state.plugins)
          GrassBagListTile(
            leading: GrassBagSquircleIcon(
              icon: CupertinoIcons.square_stack_3d_up_fill,
              color: p.enabled ? t.ok : t.text3,
              size: 34,
              iconSize: 17,
            ),
            title: Row(
              children: [
                Flexible(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 6),
                Text(
                  p.version,
                  style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: t.text3),
                ),
              ],
            ),
            subtitle: Text(
              p.readOnlyReason != null && p.readOnlyReason!.isNotEmpty
                  ? '${p.desc} · ${p.readOnlyReason}'
                  : p.desc,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (p.removable)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GrassBagSpringTap(
                      pressedScale: 0.88,
                      haptic: true,
                      onTap: () async {
                        final ok = await showGrassBagConfirmDialog(
                          context,
                          title: '卸载插件',
                          message: '确认从当前主机卸载「${p.name}」吗？',
                          confirmLabel: '确认卸载',
                          isDestructive: true,
                        );
                        if (ok) {
                          unawaited(ctrl.removePluginBundle(p.id));
                        }
                      },
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: t.errSoft,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(CupertinoIcons.trash, size: 15, color: t.err),
                      ),
                    ),
                  ),
                if (!p.optional ||
                    p.id.toLowerCase().endsWith('dsh-base') ||
                    p.id.toLowerCase().endsWith('dsh-web-app') ||
                    p.id.toLowerCase().endsWith('dsh-headless') ||
                    p.id.toLowerCase().endsWith('dsh-gbridge') ||
                    p.id.toLowerCase() == 'base')
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: t.fill1,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '内置核心',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: t.text3),
                    ),
                  )
                else
                  GrassBagGlassSwitch(
                    value: p.enabled,
                    tier: state.glassTier,
                    onChanged: (_) => ctrl.togglePlugin(p.id),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildMarket(
    BuildContext context,
    GrassBagAppState state,
    GrassBagController ctrl,
    GrassBagTokens t,
  ) {
    final q = _marketQuery.trim().toLowerCase();
    final filtered = state.marketPlugins.where((p) {
      if (q.isEmpty) return true;
      return p.displayName.toLowerCase().contains(q) ||
          p.name.toLowerCase().contains(q) ||
          p.desc.toLowerCase().contains(q);
    }).toList(growable: false);

    final isDirectNoBridge = !state.activeHost.bridged && state.activeHost.directMode;

    return Column(
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
          onChanged: (v) {
            setState(() => _marketQuery = v);
            _searchTimer?.cancel();
            final trimmed = v.trim();
            _searchTimer = Timer(const Duration(milliseconds: 350), () {
              if (!mounted) return;
              ctrl.searchPluginMarket(trimmed);
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
                  _searchTimer?.cancel();
                  _marketSearchCtrl.text = kw;
                  setState(() => _marketQuery = kw);
                  unawaited(ctrl.searchPluginMarket(kw));
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
                CupertinoActivityIndicator(radius: 8, color: t.primary),
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
              trailing: GrassBagSpringTap(
                onTap: () => ctrl.searchPluginMarket(_marketQuery.trim()),
                pressedScale: 0.92,
                haptic: true,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: t.err.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '重试',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.err),
                  ),
                ),
              ),
            ),
          ),
        if (filtered.isEmpty && !state.searchingMarket)
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
                          _searchTimer?.cancel();
                          _marketSearchCtrl.clear();
                          setState(() => _marketQuery = '');
                          unawaited(ctrl.searchPluginMarket(''));
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
        for (final m in filtered) ...[
          GrassBagCard(
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
                            '${m.name} · v${m.version} · ${m.author}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: t.text3),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (m.installed)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: t.okSoft,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '已安装',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.ok),
                        ),
                      )
                    else
                      GrassBagPrimaryGlassButton(
                        label: m.installing ? '安装中…' : '获取',
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        tier: state.glassTier,
                        insideGlass: true,
                        enabled: !m.installing,
                        onTap: m.installing ? null : () => ctrl.installMarketPlugin(m.name),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  m.desc,
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text2),
                ),
                if (m.installLogs.isNotEmpty) ...[
                  const SizedBox(height: 9),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: ShapeDecoration(
                      color: t.codeBg,
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.08), width: 0.6),
                      ),
                    ),
                    child: Text(
                      m.installLogs.join('\n'),
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.45,
                        fontFamily: 'monospace',
                        color: Color(0xFFDDE3EA),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildDynamicCordis(
    BuildContext context,
    GrassBagAppState state,
    GrassBagController ctrl,
    GrassBagTokens t,
  ) {
    if (state.dynamicCordis.isEmpty) {
      return GrassBagCard(
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
      );
    }

    return Column(
      children: [
        for (final c in state.dynamicCordis) ...[
          GrassBagCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    GrassBagSquircleIcon(
                      icon: CupertinoIcons.cube_box_fill,
                      color: c.status == 'running' ? t.dusk : t.text3,
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
                            '${c.status == 'running' ? '运行中' : '已暂停'}${c.capabilities.isNotEmpty ? ' · ${c.capabilities.join(' / ')}' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: t.text3),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(c.description, style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text2)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (c.status == 'running') ...[
                      GrassBagSpringTap(
                        onTap: () => ctrl.cordisAction(c.id, 'stop'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                          decoration: BoxDecoration(
                            color: t.fill1,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '暂停模块',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    GrassBagSpringTap(
                      onTap: () async {
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
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                        decoration: BoxDecoration(
                          color: t.errSoft,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '卸载定义',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.err),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
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
