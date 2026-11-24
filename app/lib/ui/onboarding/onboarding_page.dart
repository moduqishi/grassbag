import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/remote_host_connect_card.dart';
import '../settings/settings_page.dart';
import '../web/deepseek_signin_page.dart';
import 'launch_splash_overlay.dart';

/// Luxury 3-step Liquid Glass first-launch & replayable onboarding flow:
/// - Page 0: Kinetic GrassBag logo welcome + 3 staggered frosted value cards
/// - Page 1: Interactive mode chooser — Local Offline Container vs Remote PC/Server (embeds redesigned `RemoteHostConnectCard`)
/// - Page 2: Final readiness hub — Live engine status, 1-tap DeepSeek / API Key model setup, optional Android Accessibility, and grand entry CTA
class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({
    super.key,
    this.isFirstLaunch = false,
    this.onFinished,
  });

  /// True when displayed automatically on the very first app launch via [GrassBagAppGate].
  final bool isFirstLaunch;

  /// Optional completion callback used when hosted inline by [GrassBagAppGate] instead of a pushed route.
  final VoidCallback? onFinished;

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage>
    with TickerProviderStateMixin {
  final PageController _pageCtrl = PageController();
  late final AnimationController _ambientCtrl;
  late final AnimationController _welcomeEntranceCtrl;

  double _pageOffset = 0.0;
  int _currentPage = 0;
  int _selectedMode = 0; // 0: Local container, 1: Remote PC/Server
  bool _bootstrapping = false;
  bool _finishing = false;

  bool get _isAndroidDevice =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _ambientCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
    _welcomeEntranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 920),
    )..forward();
    _pageCtrl.addListener(_onPageScroll);
    // Default to remote mode on non-Android platforms where local container doesn't exist.
    if (!_isAndroidDevice) {
      _selectedMode = 1;
    }
  }

  void _onPageScroll() {
    if (!_pageCtrl.hasClients) return;
    final next = _pageCtrl.page ?? _currentPage.toDouble();
    if ((next - _pageOffset).abs() > 0.002) {
      setState(() => _pageOffset = next);
    }
  }

  @override
  void dispose() {
    _pageCtrl.removeListener(_onPageScroll);
    _pageCtrl.dispose();
    _ambientCtrl.dispose();
    _welcomeEntranceCtrl.dispose();
    super.dispose();
  }

  void _goToPage(int index) {
    final target = index.clamp(0, 2);
    HapticFeedback.selectionClick();
    FocusManager.instance.primaryFocus?.unfocus();
    _pageCtrl.animateToPage(
      target,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _startLocalBootstrap() async {
    if (_bootstrapping) return;
    HapticFeedback.lightImpact();
    setState(() => _bootstrapping = true);
    try {
      await ref.read(appProvider.notifier).bootstrapLocalRuntime();
    } finally {
      if (mounted) setState(() => _bootstrapping = false);
    }
  }

  Future<void> _finishOnboarding() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    HapticFeedback.mediumImpact();
    try {
      final ctrl = ref.read(appProvider.notifier);
      ctrl.completeOnboarding();
      if (widget.onFinished != null) {
        widget.onFinished!();
      } else if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _finishing = false);
    }
  }

  Future<void> _openModelSettings() async {
    await Navigator.of(context).push(
      GrassBagPageRoute<void>(
        builder: (_) => SettingsPage(
          initialSection: SettingsSection.model,
          onOpenWebUi: () {},
        ),
      ),
    );
  }

  Future<void> _openPermissionsSettings() async {
    await Navigator.of(context).push(
      GrassBagPageRoute<void>(
        builder: (_) => SettingsPage(
          initialSection: SettingsSection.permissions,
          onOpenWebUi: () {},
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          activeHost: s.activeHost,
          hostsCount: s.hosts.length,
          nativeRuntimeStatus: s.nativeRuntimeStatus,
          runtimeProgressPct: s.runtimeProgressPct,
          runtimeProgressMsg: s.runtimeProgressMsg,
          connectionPhase: s.connectionPhase,
          routableCount: s.routableProviders.length,
          selectedModel: s.modelName,
          accessibilityEnabled: s.nativePermissions.accessibilityEnabled,
        ),
      ),
    );

    final media = MediaQuery.of(context);
    final topPad = media.viewPadding.top;
    final botPad = media.viewPadding.bottom;
    final isWide = media.size.width >= 760;

    final rt = slice.nativeRuntimeStatus;
    final localReady = rt.initialized && rt.engineState != 'error';
    final remoteConnected = !slice.activeHost.isLocal && slice.activeHost.isConnectedUsable;
    final envReady =
        localReady || remoteConnected || slice.connectionPhase == ConnectionPhase.connected;
    final modelReady = slice.routableCount > 0;

    return PopScope(
      canPop: _currentPage == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _currentPage > 0) {
          _goToPage(_currentPage - 1);
        }
      },
      child: Scaffold(
      backgroundColor: t.bgSolid,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          // 1. Living Parallax Liquid Glass Ambient Mesh (pure-Canvas 120fps)
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _ambientCtrl,
                builder: (context, _) => CustomPaint(
                  painter: _OnboardingAmbientPainter(
                    pageProgress: _pageOffset / 2.0,
                    ambientPhase: _ambientCtrl.value * math.pi * 2.0,
                    isDark: t.isDark,
                    primary: t.primary,
                    primaryHi: t.primaryHi,
                    bg: t.bgSolid,
                  ),
                ),
              ),
            ),
          ),

          // 2. Main 3-step PageView
          Positioned.fill(
            child: Column(
              children: [
                // Top Floating Glass Header (Back + Morphing 3-Pill Stepper + Skip/Close)
                Padding(
                  padding: EdgeInsets.fromLTRB(16, topPad + 10, 16, 6),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: isWide ? 620 : double.infinity),
                      child: SizedBox(
                        height: 40,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Left: Back button on steps 1 & 2
                            Align(
                              alignment: Alignment.centerLeft,
                              child: AnimatedOpacity(
                                opacity: _currentPage > 0 ? 1.0 : 0.0,
                                duration: const Duration(milliseconds: 200),
                                child: IgnorePointer(
                                  ignoring: _currentPage == 0,
                                  child: GrassBagSpringTap(
                                    onTap: () => _goToPage(_currentPage - 1),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 11, vertical: 7),
                                      decoration: BoxDecoration(
                                        color: t.isDark
                                            ? const Color(0x28FFFFFF)
                                            : const Color(0x99FFFFFF),
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: t.isDark
                                              ? const Color(0x26FFFFFF)
                                              : const Color(0xCCFFFFFF),
                                          width: 0.7,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(CupertinoIcons.chevron_back,
                                              size: 14, color: t.text),
                                          const SizedBox(width: 2),
                                          Text(
                                            '上一步',
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w500,
                                              color: t.text,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            // Center: Morphing 3-pill step indicator
                            _MorphingStepIndicator(
                              pageOffset: _pageOffset,
                              onTapStep: _goToPage,
                            ),

                            // Right: Skip (first launch) or Close (replay)
                            Align(
                              alignment: Alignment.centerRight,
                              child: GrassBagSpringTap(
                                onTap: _finishOnboarding,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: t.isDark
                                        ? const Color(0x20FFFFFF)
                                        : const Color(0x88FFFFFF),
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: t.isDark
                                          ? const Color(0x22FFFFFF)
                                          : const Color(0xCCFFFFFF),
                                      width: 0.7,
                                    ),
                                  ),
                                  child: Text(
                                    widget.isFirstLaunch ? '跳过' : '完成',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                      color: t.text2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Swipeable 3-Page Body
                Expanded(
                  child: PageView(
                    controller: _pageCtrl,
                    physics: const BouncingScrollPhysics(),
                    onPageChanged: (idx) {
                      FocusManager.instance.primaryFocus?.unfocus();
                      setState(() => _currentPage = idx);
                    },
                    children: [
                      _buildWelcomeStep(t, isWide, slice.glassTier),
                      _buildModeStep(
                        t,
                        isWide,
                        slice.glassTier,
                        rt,
                        slice.runtimeProgressPct,
                        slice.runtimeProgressMsg,
                        localReady,
                        remoteConnected,
                        slice.activeHost,
                      ),
                      _buildReadyStep(
                        t,
                        isWide,
                        slice.glassTier,
                        envReady,
                        modelReady,
                        slice.activeHost,
                        slice.routableCount,
                        slice.selectedModel,
                        slice.accessibilityEnabled,
                      ),
                    ],
                  ),
                ),

                // Bottom Pinned Action Bar
                _buildBottomFooter(
                  t,
                  isWide,
                  botPad,
                  slice.glassTier,
                  envReady: envReady,
                  modelReady: modelReady,
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // STEP 0 — Welcome Hero
  // ---------------------------------------------------------------------------
  Widget _buildWelcomeStep(
    GrassBagTokens t,
    bool isWide,
    GrassBagGlassTier tier,
  ) {
    final features = [
      (
        icon: CupertinoIcons.cube_box_fill,
        color: t.primary,
        title: '本机独立 Linux 运行环境',
        desc: '内置 Ubuntu 与 DeepSeek Harness 核心，随时离线写代码、跑工具链。',
      ),
      (
        icon: CupertinoIcons.desktopcomputer,
        color: t.ok,
        title: '免插件直连电脑与服务器',
        desc: '自动发现同局域网 Mac / PC，一条链接 30 天免密同步全部会话。',
      ),
      (
        icon: CupertinoIcons.hand_draw_fill,
        color: t.warn,
        title: '原生终端与手机安全操控',
        desc: '融合多标签终端、文件对比与安全护栏，让 AI 真正替你落地执行。',
      ),
    ];

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWide ? 560 : double.infinity),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),
              // Hero Kinetic Mascot inside a delicate translucent radial halo
              Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 148,
                      height: 148,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            t.primary.withValues(alpha: t.isDark ? 0.24 : 0.16),
                            t.primaryHi.withValues(alpha: t.isDark ? 0.08 : 0.05),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.56, 1.0],
                        ),
                      ),
                    ),
                    const GrassBagAnimatedLogo(
                      size: 108,
                      duration: Duration(milliseconds: 1120),
                      autoPlay: true,
                      ambientFloat: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // Eyebrow glass capsule
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
                  decoration: BoxDecoration(
                    color: t.primarySoft,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: t.primary.withValues(alpha: 0.28),
                      width: 0.65,
                    ),
                  ),
                  child: Text(
                    'DEEPSEEK HARNESS · LIQUID GLASS',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                      color: t.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '欢迎使用 GrassBag',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 29,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.7,
                  height: 1.16,
                  color: t.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '装进口袋里的全能开发与执行代理\n三步完成配置，立即开启原生液态玻璃体验',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.48,
                  color: t.text2,
                ),
              ),
              const SizedBox(height: 24),
              // 3 Staggered Frosted Value Cards
              for (int i = 0; i < features.length; i++) ...[
                _StaggeredEntrance(
                  controller: _welcomeEntranceCtrl,
                  start: 0.16 + i * 0.16,
                  end: (0.64 + i * 0.16).clamp(0.0, 1.0),
                  child: Padding(
                    padding: EdgeInsets.only(bottom: i == features.length - 1 ? 0 : 10),
                    child: GrassBagCard(
                      borderRadius: 22,
                      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
                      child: Row(
                        children: [
                          GrassBagSquircleIcon(
                            icon: features[i].icon,
                            color: features[i].color,
                            size: 42,
                            iconSize: 20,
                          ),
                          const SizedBox(width: 13),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  features[i].title,
                                  style: TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w600,
                                    color: t.text,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  features[i].desc,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.42,
                                    color: t.text2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // STEP 1 — Choose Mode (Local Container vs Remote PC/Server)
  // ---------------------------------------------------------------------------
  Widget _buildModeStep(
    GrassBagTokens t,
    bool isWide,
    GrassBagGlassTier tier,
    NativeRuntimeStatus rt,
    int runtimeProgressPct,
    String runtimeProgressMsg,
    bool localReady,
    bool remoteConnected,
    ManagedHost activeHost,
  ) {
    final progress = (runtimeProgressPct / 100.0).clamp(0.0, 1.0);
    final isBootstrappingNow =
        _bootstrapping || (runtimeProgressPct > 0 && runtimeProgressPct < 100);
    final localHasError = rt.engineState == 'error' && (rt.engineError?.isNotEmpty == true);
    final launcherDisplay =
        rt.executorMode.startsWith('proot') ? 'PRoot 兼容模式' : 'tawcroot 高速模式';

    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWide ? 580 : double.infinity),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '选择你的运行方式',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: t.text,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '可在手机本机独立部署，也可随时直连电脑上的 DeepSeek Harness',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.42, color: t.text2),
              ),
              const SizedBox(height: 16),

              // 2-Card Interactive Mode Selector
              Row(
                children: [
                  Expanded(
                    child: _ModeChoiceCard(
                      icon: CupertinoIcons.device_phone_portrait,
                      title: '本机独立运行',
                      subtitle: _isAndroidDevice ? '内置 Ubuntu · 离线可用' : '本地 DSH 服务',
                      badge: localReady ? '已就绪' : (_isAndroidDevice ? '推荐' : null),
                      badgeOk: localReady,
                      selected: _selectedMode == 0,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _selectedMode = 0);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ModeChoiceCard(
                      icon: CupertinoIcons.desktopcomputer,
                      title: '连接远程电脑',
                      subtitle: 'Mac / PC / 服务器',
                      badge: remoteConnected ? '已接入' : '免装插件',
                      badgeOk: remoteConnected,
                      selected: _selectedMode == 1,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _selectedMode = 1);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: _selectedMode == 0
                    ? KeyedSubtree(
                        key: const ValueKey('mode-local'),
                        child: GrassBagCard(
                          borderRadius: 24,
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  GrassBagSquircleIcon(
                                    icon: localReady
                                        ? CupertinoIcons.checkmark_seal_fill
                                        : CupertinoIcons.cube_box_fill,
                                    color: localReady
                                        ? t.ok
                                        : (localHasError ? t.err : t.primary),
                                    size: 40,
                                    iconSize: 19,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _isAndroidDevice
                                              ? '本机 Ubuntu + DSH 运行时'
                                              : '本地 DeepSeek Harness',
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            color: t.text,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _isAndroidDevice
                                              ? 'Ubuntu 24.04.5 · Node 24.22.3 · $launcherDisplay'
                                              : '自动连接本机 127.0.0.1:3080',
                                          style: TextStyle(fontSize: 11.5, color: t.text3),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _isAndroidDevice
                                    ? '首次部署会自动释放 ARM64 Linux 根文件系统与官方 DeepSeek Harness，并支持后续一键安装 Python、Git、Ripgrep 等工具链。'
                                    : '当前非 Android 设备，可直接连接本机运行的 `dsh web`，或切换至右侧接入局域网/服务器上的远程主机。',
                                style: TextStyle(fontSize: 12.5, height: 1.5, color: t.text2),
                              ),
                              if (isBootstrappingNow) ...[
                                const SizedBox(height: 14),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: LinearProgressIndicator(
                                    value: progress > 0 ? progress : null,
                                    minHeight: 7,
                                    backgroundColor: t.fill1,
                                    valueColor: AlwaysStoppedAnimation<Color>(t.primary),
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Row(
                                  children: [
                                    const CupertinoActivityIndicator(radius: 7),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        runtimeProgressMsg.isNotEmpty
                                            ? '$runtimeProgressMsg（$runtimeProgressPct%）'
                                            : '正在初始化本机 Linux 容器（$runtimeProgressPct%）…',
                                        style: TextStyle(fontSize: 12, color: t.text2),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              if (localHasError) ...[
                                const SizedBox(height: 12),
                                GrassBagStatusBanner(
                                  tone: GrassBagBannerTone.error,
                                  icon: CupertinoIcons.exclamationmark_triangle_fill,
                                  title: '本机容器启动遇到异常',
                                  message: rt.engineError ?? '请检查剩余存储空间后重试',
                                  padding: const EdgeInsets.all(11),
                                  borderRadius: 14,
                                ),
                              ],
                              if (localReady) ...[
                                const SizedBox(height: 12),
                                GrassBagStatusBanner(
                                  tone: GrassBagBannerTone.ok,
                                  icon: CupertinoIcons.checkmark_circle_fill,
                                  title: rt.engineRunning ? '本机引擎运行正常' : '本机容器已部署完成',
                                  message: rt.engineRunning
                                      ? 'DeepSeek Harness 已就绪，可以继续下一步配置模型或直接进入对话。'
                                      : '容器环境已就绪，引擎正在后台自动拉起。',
                                  padding: const EdgeInsets.all(11),
                                  borderRadius: 14,
                                ),
                              ],
                              if (_isAndroidDevice && !localReady) ...[
                                const SizedBox(height: 14),
                                GrassBagPrimaryGlassButton(
                                  label: isBootstrappingNow
                                      ? '正在部署本机环境…'
                                      : (localHasError ? '重试部署本机环境' : '一键部署本机容器'),
                                  icon: CupertinoIcons.rocket_fill,
                                  height: 44,
                                  tier: tier,
                                  insideGlass: true,
                                  enabled: !isBootstrappingNow,
                                  onTap: isBootstrappingNow ? null : _startLocalBootstrap,
                                ),
                              ],
                            ],
                          ),
                        ),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('mode-remote'),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (remoteConnected) ...[
                              GrassBagStatusBanner(
                                tone: GrassBagBannerTone.ok,
                                icon: CupertinoIcons.checkmark_circle_fill,
                                title: '已接入远程主机「${activeHost.name}」',
                                message: '${activeHost.address} · ${activeHost.latency}',
                                padding: const EdgeInsets.all(12),
                                borderRadius: 16,
                              ),
                              const SizedBox(height: 10),
                            ],
                            RemoteHostConnectCard(
                              showHeader: false,
                              connectImmediately: true,
                              initiallyShowGuide: false,
                              autoScanLan: true,
                              onConnectedHost: (_) => _goToPage(2),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // STEP 2 — Ready & Quick Model / Permissions Setup
  // ---------------------------------------------------------------------------
  Widget _buildReadyStep(
    GrassBagTokens t,
    bool isWide,
    GrassBagGlassTier tier,
    bool envReady,
    bool modelReady,
    ManagedHost activeHost,
    int routableCount,
    String selectedModel,
    bool accessibilityEnabled,
  ) {
    final allReady = envReady && modelReady;
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWide ? 560 : double.infinity),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 6),
              // Celebration Emblem
              Center(
                child: Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: allReady
                          ? [t.ok, t.primary]
                          : [t.primaryHi, t.primary],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (allReady ? t.ok : t.primary)
                            .withValues(alpha: t.isDark ? 0.34 : 0.24),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Icon(
                    allReady ? CupertinoIcons.checkmark_alt : CupertinoIcons.sparkles,
                    size: 36,
                    color: allReady ? Colors.white : t.onPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                allReady ? '一切准备就绪' : '最后一步：接入 AI 模型',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: t.text,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                allReady
                    ? '运行环境与模型均已就绪，现在就可以开始高效对话与执行任务。'
                    : '登录 DeepSeek 官方账号或填入任意兼容 API Key，也可稍后在设置中补充。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.45, color: t.text2),
              ),
              const SizedBox(height: 20),

              // Checklist Status Card
              GrassBagCard(
                borderRadius: 24,
                padding: const EdgeInsets.all(15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1. Runtime / Host Row
                    _ReadyStatusRow(
                      done: envReady,
                      icon: activeHost.isLocal
                          ? CupertinoIcons.device_phone_portrait
                          : CupertinoIcons.desktopcomputer,
                      title: envReady
                          ? '运行环境已就绪 · ${activeHost.name}'
                          : '运行环境待配置',
                      subtitle: envReady
                          ? (activeHost.isLocal
                              ? '本机独立 Linux 与 DSH 引擎已接入'
                              : '${activeHost.address} · ${activeHost.latency}')
                          : '可返回上一步一键部署本机容器或连接远程电脑',
                      trailing: envReady
                          ? null
                          : GrassBagSpringTap(
                              onTap: () => _goToPage(1),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: t.primarySoft,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '去配置',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: t.primary,
                                  ),
                                ),
                              ),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      child: Divider(height: 0.5, color: t.sep),
                    ),

                    // 2. Model Provider Row + 1-Tap Quick Actions
                    _ReadyStatusRow(
                      done: modelReady,
                      icon: CupertinoIcons.sparkles,
                      title: modelReady
                          ? 'AI 模型已就绪（$routableCount 个渠道）'
                          : '配置 AI 模型凭证',
                      subtitle: modelReady
                          ? (selectedModel.isNotEmpty
                              ? '默认模型：$selectedModel'
                              : '支持随时在对话底部切换模型与思考深度')
                          : '支持 DeepSeek 官方一键登录、OpenAI / Anthropic / 自定义中转站',
                    ),
                    if (!modelReady) ...[
                      const SizedBox(height: 11),
                      Row(
                        children: [
                          Expanded(
                            child: GrassBagPrimaryGlassButton(
                              label: '登录 DeepSeek',
                              icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                              height: 38,
                              tier: tier,
                              insideGlass: true,
                              onTap: envReady
                                  ? () => launchDeepSeekSignInFlow(context, ref)
                                  : () {
                                      ref.read(appProvider.notifier).showToast(
                                            '请先完成运行环境部署或连接远程主机',
                                            tone: ToastTone.info,
                                          );
                                      _goToPage(1);
                                    },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: GrassBagSecondaryGlassButton(
                              label: 'API Key / 中转',
                              icon: CupertinoIcons.slider_horizontal_3,
                              height: 38,
                              tier: tier,
                              insideGlass: true,
                              accentForeground: true,
                              onTap: _openModelSettings,
                            ),
                          ),
                        ],
                      ),
                    ],

                    // 3. Optional Android Accessibility Row
                    if (_isAndroidDevice) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Divider(height: 0.5, color: t.sep),
                      ),
                      _ReadyStatusRow(
                        done: accessibilityEnabled,
                        optional: true,
                        icon: CupertinoIcons.hand_draw_fill,
                        title: accessibilityEnabled
                            ? '手机操控权限已开启'
                            : '手机操控权限（可选）',
                        subtitle: accessibilityEnabled
                            ? '无障碍服务运行中，支持安全护栏下的原生界面操控'
                            : '如需让 AI 自动点击或操作其他 App，可按需授权无障碍服务',
                        trailing: accessibilityEnabled
                            ? null
                            : GrassBagSpringTap(
                                onTap: _openPermissionsSettings,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: t.fill1,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: t.sep, width: 0.6),
                                  ),
                                  child: Text(
                                    '按需开启',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: t.text2,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomFooter(
    GrassBagTokens t,
    bool isWide,
    double botPad,
    GrassBagGlassTier tier, {
    required bool envReady,
    required bool modelReady,
  }) {
    final bottomInset = botPad > 0 ? botPad + 12.0 : 18.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, bottomInset),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWide ? 560 : double.infinity),
          child: SizedBox(
            width: double.infinity,
            child: switch (_currentPage) {
              0 => GrassBagPrimaryGlassButton(
                  label: '开始配置',
                  icon: CupertinoIcons.arrow_right_circle_fill,
                  height: 48,
                  tier: tier,
                  onTap: () => _goToPage(1),
                ),
              1 => GrassBagPrimaryGlassButton(
                  label: envReady ? '继续下一步' : '稍后配置，继续下一步',
                  icon: CupertinoIcons.arrow_right_circle_fill,
                  height: 48,
                  tier: tier,
                  onTap: () => _goToPage(2),
                ),
              _ => GrassBagPrimaryGlassButton(
                  label: _finishing
                      ? '正在进入…'
                      : (modelReady ? '开始使用 GrassBag' : '进入 GrassBag'),
                  icon: CupertinoIcons.sparkles,
                  height: 48,
                  tier: tier,
                  enabled: !_finishing,
                  onTap: _finishing ? null : _finishOnboarding,
                ),
            },
          ),
        ),
      ),
    );
  }
}

/// Morphing 3-pill indicator synced continuously with [PageController.page].
class _MorphingStepIndicator extends StatelessWidget {
  const _MorphingStepIndicator({
    required this.pageOffset,
    required this.onTapStep,
  });

  final double pageOffset;
  final ValueChanged<int> onTapStep;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        final dist = (pageOffset - i).abs().clamp(0.0, 1.0);
        final active = 1.0 - dist;
        final width = 7.0 + 21.0 * active;
        final color = Color.lerp(
          t.isDark ? const Color(0x38FFFFFF) : const Color(0x2E0F172A),
          t.primary,
          active,
        )!;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTapStep(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Container(
              width: width,
              height: 6.5,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _ModeChoiceCard extends StatelessWidget {
  const _ModeChoiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.badge,
    this.badgeOk = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? badge;
  final bool badgeOk;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagSpringTap(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: selected
              ? (t.isDark
                  ? t.primary.withValues(alpha: 0.22)
                  : t.primary.withValues(alpha: 0.11))
              : (t.isDark
                  ? const Color(0xB818222C)
                  : const Color(0xCCFFFFFF)),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? t.primary.withValues(alpha: 0.72)
                : (t.isDark ? const Color(0x24FFFFFF) : const Color(0xD8FFFFFF)),
            width: selected ? 1.35 : 0.8,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: t.primary.withValues(alpha: t.isDark ? 0.20 : 0.12),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GrassBagSquircleIcon(
                  icon: icon,
                  color: selected ? t.primary : t.text2,
                  size: 32,
                  iconSize: 16,
                ),
                const Spacer(),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                    decoration: BoxDecoration(
                      color: badgeOk
                          ? t.okSoft
                          : (selected ? t.primarySoft : t.fill1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      badge!,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: badgeOk ? t.ok : (selected ? t.primary : t.text3),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: t.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.text3),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReadyStatusRow extends StatelessWidget {
  const _ReadyStatusRow({
    required this.done,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.optional = false,
    this.trailing,
  });

  final bool done;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool optional;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final badgeColor = done ? t.ok : (optional ? t.text3 : t.primary);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        GrassBagSquircleIcon(
          icon: done ? CupertinoIcons.checkmark_alt : icon,
          color: badgeColor,
          size: 36,
          iconSize: 17,
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 11.5, height: 1.38, color: t.text3),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing!,
        ],
      ],
    );
  }
}

class _StaggeredEntrance extends StatelessWidget {
  const _StaggeredEntrance({
    required this.controller,
    required this.start,
    required this.end,
    required this.child,
  });

  final AnimationController controller;
  final double start;
  final double end;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(
      parent: controller,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: curve,
      child: child,
      builder: (context, child) {
        final v = curve.value;
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, (1.0 - v) * 18.0),
            child: child,
          ),
        );
      },
    );
  }
}

/// Pure-Canvas ambient Liquid Glass mesh that drifts smoothly with PageView scroll + slow breath.
class _OnboardingAmbientPainter extends CustomPainter {
  const _OnboardingAmbientPainter({
    required this.pageProgress,
    required this.ambientPhase,
    required this.isDark,
    required this.primary,
    required this.primaryHi,
    required this.bg,
  });

  final double pageProgress;
  final double ambientPhase;
  final bool isDark;
  final Color primary;
  final Color primaryHi;
  final Color bg;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bgGrad = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? [bg, Color.lerp(bg, const Color(0xFF0A141D), 0.7)!]
          : [bg, const Color(0xFFE5EFF7)],
    );
    canvas.drawRect(rect, Paint()..shader = bgGrad.createShader(rect));

    final p = pageProgress.clamp(0.0, 1.0);
    final driftX = math.sin(ambientPhase) * 18.0;
    final driftY = math.cos(ambientPhase * 0.8) * 14.0;

    // Orb 1: Primary cyan-teal halo shifting smoothly across pages
    _drawOrb(
      canvas,
      Offset(
        size.width * (0.20 + p * 0.58) + driftX,
        size.height * (0.18 + math.sin(p * math.pi) * 0.12) + driftY,
      ),
      size.shortestSide * 0.68,
      primary.withValues(alpha: isDark ? 0.22 : 0.17),
    );

    // Orb 2: Mint-emerald accent counter-drifting on bottom edge
    _drawOrb(
      canvas,
      Offset(
        size.width * (0.84 - p * 0.52) - driftX * 0.8,
        size.height * (0.76 - p * 0.14) - driftY,
      ),
      size.shortestSide * 0.62,
      primaryHi.withValues(alpha: isDark ? 0.16 : 0.14),
    );

    // Orb 3: Soft sapphire-frost bloom for depth
    _drawOrb(
      canvas,
      Offset(
        size.width * (0.50 + math.sin(p * math.pi) * 0.22),
        size.height * (0.48 + p * 0.12) + driftY * 0.5,
      ),
      size.shortestSide * 0.55,
      (isDark ? const Color(0xFF38BDF8) : const Color(0xFF7DD3FC))
          .withValues(alpha: isDark ? 0.10 : 0.13),
    );
  }

  void _drawOrb(Canvas canvas, Offset center, double radius, Color color) {
    final shader = RadialGradient(
      colors: [color, color.withValues(alpha: 0.0)],
      stops: const [0.0, 1.0],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _OnboardingAmbientPainter oldDelegate) =>
      (oldDelegate.pageProgress - pageProgress).abs() > 0.002 ||
      (oldDelegate.ambientPhase - ambientPhase).abs() > 0.015 ||
      oldDelegate.isDark != isDark ||
      oldDelegate.primary != primary;
}
