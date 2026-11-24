import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_mascot.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import '../common/remote_host_connect_card.dart';

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  bool _bootstrapping = false;
  bool _enteringLocal = false;

  Future<void> _startLocalBootstrap() async {
    if (_bootstrapping) return;
    setState(() => _bootstrapping = true);
    await ref.read(appProvider.notifier).bootstrapLocalRuntime();
    if (mounted) setState(() => _bootstrapping = false);
  }

  Future<void> _enterLocalHost() async {
    if (_enteringLocal) return;
    setState(() => _enteringLocal = true);
    try {
      final ctrl = ref.read(appProvider.notifier);
      ctrl.completeOnboarding();
      await ctrl.switchHost('local');
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _enteringLocal = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          hosts: s.hosts,
          nativeRuntimeStatus: s.nativeRuntimeStatus,
          runtimeProgressPct: s.runtimeProgressPct,
          runtimeProgressMsg: s.runtimeProgressMsg,
          connectionPhase: s.connectionPhase,
          routableProvidersCount: s.routableProviders.length,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final t = GrassBagTokens.of(context);
    final topPad = MediaQuery.viewPaddingOf(context).top;
    final botPad = MediaQuery.viewPaddingOf(context).bottom;
    final isWide = MediaQuery.sizeOf(context).width >= 760;

    final rt = state.nativeRuntimeStatus;
    final progress = (state.runtimeProgressPct / 100.0).clamp(0.0, 1.0);
    final isAndroidDevice = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final isBootstrappingNow =
        _bootstrapping || (state.runtimeProgressPct > 0 && state.runtimeProgressPct < 100);
    final localHasError = rt.engineState == 'error' && (rt.engineError?.isNotEmpty == true);
    final localReady = rt.initialized && rt.engineState != 'error';
    final launcherDisplay =
        (rt.executorMode.startsWith('proot') || state.localHost.launcherMode == '兼容模式')
            ? 'PRoot 兼容模式'
            : 'tawcroot 高速模式';

    return GrassBagGlassPage(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: isWide ? 640 : double.infinity),
                  child: ListView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                    padding: EdgeInsets.fromLTRB(16, topPad + 76, 16, 40 + botPad),
                      children: [
                        // Cute vector GrassBag mascot with NO box behind it
                        const Center(child: GrassBagMascot(size: 74)),
                        const SizedBox(height: 14),
                        Text(
                          '环境初始化向导',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: t.text,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '在手机本机运行完整开发代理环境，或直接连接电脑与服务器上的 DSH',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13.5, height: 1.45, color: t.text2),
                        ),
                        const SizedBox(height: 16),
                        _OnboardingStepRibbon(
                          envDone: localReady || state.connectionPhase == ConnectionPhase.connected,
                          modelDone: state.routableProviders.isNotEmpty,
                        ),
                        const SizedBox(height: 18),

                        // Card 1: Local Android Container & A/B Runtime Bootstrap
                        if (isAndroidDevice) ...[
                          GrassBagCard(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    GrassBagSquircleIcon(
                                      icon: CupertinoIcons.cube_fill,
                                      color: t.primary,
                                      size: 38,
                                      iconSize: 18,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '本机内置 Linux 运行环境',
                                            style: TextStyle(
                                              fontSize: 15.5,
                                              fontWeight: FontWeight.w600,
                                              color: t.text,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '$launcherDisplay · 离线可用 · 本地持久化',
                                            style: TextStyle(fontSize: 12, color: t.text3),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: localHasError
                                            ? t.errSoft
                                            : (localReady ? t.okSoft : t.primarySoft),
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        localHasError
                                            ? '异常'
                                            : (localReady ? '已就绪' : (isBootstrappingNow ? '部署中' : '待部署')),
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: localHasError
                                              ? t.err
                                              : (localReady ? t.ok : t.primary),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  localHasError
                                      ? '启动报错：${rt.engineError}'
                                      : '自动部署内置 Ubuntu + Node.js + DSH 引擎，后续更新系统环境时你的代码、密钥与历史对话均自动保留。',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    height: 1.45,
                                    color: localHasError ? t.err : t.text2,
                                  ),
                                ),
                                if (state.runtimeProgressPct > 0) ...[
                                  const SizedBox(height: 12),
                                  GrassBagProgressBar(
                                    value: progress,
                                    height: 7,
                                    trackColor: t.fill2,
                                    color: state.runtimeProgressPct == 100 ? t.ok : t.primary,
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          state.runtimeProgressMsg,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 11.5, color: t.text3),
                                        ),
                                      ),
                                      Text(
                                        '${state.runtimeProgressPct}%',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                          color: t.text2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                                const SizedBox(height: 14),
                                if (localReady && !isBootstrappingNow) ...[
                                  SizedBox(
                                    width: double.infinity,
                                    child: GrassBagPrimaryGlassButton(
                                      label: _enteringLocal ? '正在进入本机环境…' : '开始使用本机环境',
                                      icon: CupertinoIcons.checkmark_circle_fill,
                                      tier: state.glassTier,
                                      insideGlass: true,
                                      enabled: !_enteringLocal,
                                      onTap: _enteringLocal ? null : _enterLocalHost,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    width: double.infinity,
                                    child: GrassBagSecondaryGlassButton(
                                      label: '重新校验本机环境',
                                      icon: CupertinoIcons.arrow_2_circlepath,
                                      tier: state.glassTier,
                                      insideGlass: true,
                                      onTap: _startLocalBootstrap,
                                    ),
                                  ),
                                ] else
                                  SizedBox(
                                    width: double.infinity,
                                    child: GrassBagPrimaryGlassButton(
                                      label: isBootstrappingNow
                                          ? '正在初始化本机环境 ${state.runtimeProgressPct}%…'
                                          : (localHasError ? '重试初始化本机环境' : '一键初始化本机环境'),
                                      icon: CupertinoIcons.bolt_fill,
                                      tier: state.glassTier,
                                      insideGlass: true,
                                      enabled: !isBootstrappingNow,
                                      onTap: _startLocalBootstrap,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                        ] else ...[
                          GrassBagCard(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              children: [
                                GrassBagSquircleIcon(
                                  icon: CupertinoIcons.desktopcomputer,
                                  color: t.primary,
                                  size: 36,
                                  iconSize: 17,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '当前为网页 / 桌面端控制面板',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: t.text,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '内置 Linux 容器仅在 Android 客户端提供；请直接在下方连接本机或远程 DSH 服务。',
                                        style: TextStyle(fontSize: 12, height: 1.4, color: t.text2),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],

                        // Card 2: Frictionless Zero-Plugin Remote Host Connect + LAN Discovery + WebView Login
                        RemoteHostConnectCard(
                          connectImmediately: true,
                          showHeader: true,
                          onConnectedHost: (host) {
                            if (host.isConnectedUsable && mounted) {
                              ref.read(appProvider.notifier).completeOnboarding();
                              Navigator.of(context).pop();
                            }
                          },
                        ),
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
                title: '初始化向导',
                tier: state.glassTier,
                onBack: () => Navigator.of(context).pop(),
                trailing: GrassBagGlassPillButton(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  tier: state.glassTier,
                  useOwnLayer: false,
                  onTap: () {
                    ref.read(appProvider.notifier).completeOnboarding();
                    Navigator.of(context).pop();
                  },
                  child: Text(
                    '稍后再说',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text2),
                  ),
                ),
              ),
            ),
            const GrassBagToastOverlay(bottomOffset: 28),
          ],
        ),
      ),
    );
  }
}

class _OnboardingStepRibbon extends StatelessWidget {
  const _OnboardingStepRibbon({
    required this.envDone,
    required this.modelDone,
  });

  final bool envDone;
  final bool modelDone;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    Widget step(int num, String label, bool done, bool active) {
      final fg = done ? t.ok : (active ? t.primary : t.text3);
      final bg = done ? t.okSoft : (active ? t.primarySoft : t.fill1);
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? t.primary.withValues(alpha: 0.35) : t.sep,
              width: 0.6,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                done ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle_fill,
                size: done ? 13 : 6,
                color: fg,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  '$num. $label',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        step(1, '准备环境', envDone, !envDone),
        const SizedBox(width: 6),
        step(2, '配置模型', modelDone, envDone && !modelDone),
        const SizedBox(width: 6),
        step(3, '开始对话', false, envDone && modelDone),
      ],
    );
  }
}
