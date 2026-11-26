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
import '../common/grassbag_sheets.dart';
import '../common/remote_host_connect_card.dart';
import '../settings/settings_page.dart';
import '../web/deepseek_signin_page.dart';
import '../web/official_web_page.dart';
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
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final PageController _pageCtrl = PageController();
  final ValueNotifier<double> _pageOffsetNotifier = ValueNotifier<double>(0.0);
  late final AnimationController _welcomeEntranceCtrl;

  int _currentPage = 0;
  int _selectedMode = 0; // 0: Local container, 1: Remote PC/Server
  bool _bootstrapping = false;
  bool _finishing = false;
  bool _expandRemoteCardWhenConnected = false;

  bool get _isAndroidDevice =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _welcomeEntranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 920),
    )..forward();
    _pageCtrl.addListener(_onPageScroll);
    if (!_isAndroidDevice) {
      _selectedMode = 1;
    } else {
      _selectedMode = ref.read(appProvider).activeHost.isLocal ? 0 : 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(ref.read(appProvider.notifier).refreshPermissionsOnly());
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isAndroidDevice && mounted) {
      unawaited(ref.read(appProvider.notifier).refreshPermissionsOnly());
    }
  }

  void _onPageScroll() {
    if (!_pageCtrl.hasClients) return;
    final next = _pageCtrl.page ?? _currentPage.toDouble();
    if ((next - _pageOffsetNotifier.value).abs() > 0.002) {
      _pageOffsetNotifier.value = next;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageCtrl.removeListener(_onPageScroll);
    _pageCtrl.dispose();
    _pageOffsetNotifier.dispose();
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
      await triggerLocalRuntimeBootstrapWithGuard(context, ref);
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

  void _openWebUi() {
    Navigator.of(context).push(
      GrassBagPageRoute<void>(builder: (_) => const OfficialWebPage()),
    );
  }

  Future<void> _openModelSettings() async {
    await Navigator.of(context).push(
      GrassBagPageRoute<void>(
        builder: (_) => SettingsPage(
          initialSection: SettingsSection.model,
          onOpenWebUi: _openWebUi,
        ),
      ),
    );
  }

  Future<void> _openPermissionsSettings() async {
    await Navigator.of(context).push(
      GrassBagPageRoute<void>(
        builder: (_) => SettingsPage(
          initialSection: SettingsSection.permissions,
          onOpenWebUi: _openWebUi,
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
          runtimeProgressCanCancel: s.runtimeProgressCanCancel,
          connectionPhase: s.connectionPhase,
          routableCount: s.routableProviders.length,
          selectedModel: s.modelName,
          nativePermissions: s.nativePermissions,
        ),
      ),
    );

    final viewPad = MediaQuery.viewPaddingOf(context);
    final topPad = viewPad.top;
    final botPad = viewPad.bottom;
    final isWide = MediaQuery.sizeOf(context).width >= 760;

    final rt = slice.nativeRuntimeStatus;
    final localReady = _isAndroidDevice
        ? (rt.initialized &&
            rt.engineState != 'error' &&
            (rt.engineRunning || slice.connectionPhase == ConnectionPhase.connected))
        : (slice.activeHost.isLocal && slice.activeHost.isConnectedUsable);
    final remoteConnected = !slice.activeHost.isLocal && slice.activeHost.isConnectedUsable;
    final envReady =
        localReady || remoteConnected || slice.connectionPhase == ConnectionPhase.connected;
    final modelReady = slice.routableCount > 0;
    final isBootstrappingNow = _isAndroidDevice &&
        (slice.connectionPhase == ConnectionPhase.bootstrapping ||
            (slice.runtimeProgressPct > 0 && slice.runtimeProgressPct < 100));

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
          // 1. Living Parallax Liquid Glass Ambient Mesh (pure-Canvas 120fps via CustomPainter.repaint,
          //    ZERO 120Hz AnimatedBuilder widget rebuilds!)
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _OnboardingAmbientPainter(
                  pageOffset: _pageOffsetNotifier,
                  ambient: _welcomeEntranceCtrl,
                  isDark: t.isDark,
                  primary: t.primary,
                  primaryHi: t.primaryHi,
                  bg: t.bgSolid,
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
                        child: GrassBagGlassBarLayer(
                          tier: slice.glassTier,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Left: Back button ONLY mounted on steps 1 & 2 (never leaves a ghost
                              // refractive SDF pill inside GrassBagGlassBarLayer on step 0!)
                              if (_currentPage > 0)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: GrassBagGlassPillButton(
                                    tier: slice.glassTier,
                                    height: 34,
                                    useOwnLayer: false,
                                    padding: const EdgeInsets.symmetric(horizontal: 11),
                                    onTap: () => _goToPage(_currentPage - 1),
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

                              // Center: Morphing 3-pill step indicator
                              ValueListenableBuilder<double>(
                                valueListenable: _pageOffsetNotifier,
                                builder: (_, offset, __) => _MorphingStepIndicator(
                                  pageOffset: offset,
                                  onTapStep: _goToPage,
                                ),
                              ),

                                // Right: Skip (first launch) or Close (replay)
                              Align(
                                alignment: Alignment.centerRight,
                                child: GrassBagGlassPillButton(
                                  tier: slice.glassTier,
                                  height: 34,
                                  useOwnLayer: false,
                                  padding: const EdgeInsets.symmetric(horizontal: 13),
                                  onTap: () async {
                                    if (widget.isFirstLaunch &&
                                        _currentPage < 2 &&
                                        isBootstrappingNow) {
                                      final ok = await showGrassBagConfirmDialog(
                                        context,
                                        title: '本机容器仍在下载部署中',
                                        message: '现在跳过引导后，容器部署将继续在后台运行，你随时可在主界面顶部查看进度。确认现在进入主界面吗？',
                                        confirmLabel: '后台继续并进入',
                                      );
                                      if (!ok || !mounted) return;
                                    }
                                    _finishOnboarding();
                                  },
                                  child: Text(
                                    _currentPage < 2
                                        ? (widget.isFirstLaunch ? '跳过' : '关闭')
                                        : '完成',
                                    textScaler: MediaQuery.textScalerOf(context)
                                        .clamp(maxScaleFactor: 1.2),
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                      color: t.text2,
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
                        slice.runtimeProgressCanCancel,
                        localReady,
                        remoteConnected,
                        slice.activeHost,
                        slice.connectionPhase,
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
                        slice.nativePermissions,
                      ),
                    ],
                  ),
                ),

                // Bottom Pinned Action Bar (isolated leaf listens to viewInsets so IME opening
                // NEVER rebuilds the full OnboardingPage & PageView!)
                Builder(
                  builder: (footerCtx) {
                    if (MediaQuery.viewInsetsOf(footerCtx).bottom > 80) {
                      return const SizedBox.shrink();
                    }
                    return _buildBottomFooter(
                      t,
                      isWide,
                      botPad,
                      slice.glassTier,
                      envReady: envReady,
                      modelReady: modelReady,
                    );
                  },
                ),
              ],
            ),
          ),

          // 3. Toast Feedback Overlay (drops near IME top when keyboard hides bottom footer)
          Builder(
            builder: (toastCtx) => GrassBagToastOverlay(
              bottomOffset: MediaQuery.viewInsetsOf(toastCtx).bottom > 80 ? 16.0 : 88.0,
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
        desc: '按需下载 Ubuntu 与 DeepSeek Harness 核心，部署完成后可离线写代码、跑工具链。',
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
              // Hero Kinetic Mascot (GrassBagAnimatedLogo paints its own radial bloom — no double halo!)
              Center(
                child: GrassBagAnimatedLogo(
                  size: 114,
                  duration: const Duration(milliseconds: 1120),
                  autoPlay: !widget.isFirstLaunch,
                  ambientFloat: false,
                ),
              ),
              const SizedBox(height: 14),
              // Eyebrow glass capsule
              Center(
                child: GrassBagFresnelGlassSurface(
                  isPill: true,
                  innerWell: true,
                  tintColor: t.primarySoft,
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4.5),
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
    bool runtimeProgressCanCancel,
    bool localReady,
    bool remoteConnected,
    ManagedHost activeHost,
    ConnectionPhase connectionPhase,
  ) {
    final progress = (runtimeProgressPct / 100.0).clamp(0.0, 1.0);
    final isBootstrappingNow =
        _bootstrapping || (runtimeProgressPct > 0 && runtimeProgressPct < 100);
    final isRemoteThin = _isAndroidDevice && !rt.hasBundledRuntimePayloads;
    final downloadSizeLabel = rt.formattedDownloadSize;
    final localHasError = rt.engineState == 'error' && (rt.engineError?.isNotEmpty == true);
    final launcherDisplay =
        rt.executorMode.startsWith('proot') ? '标准兼容内核' : '高速原生内核';
    final localInstalled = _isAndroidDevice && rt.initialized;
    final localStopped = localInstalled &&
        !rt.engineRunning &&
        rt.engineState != 'starting' &&
        !localHasError &&
        !isBootstrappingNow;
    final localStarting = localInstalled && rt.engineState == 'starting' && !isBootstrappingNow;
    final desktopLocalConnected = !_isAndroidDevice &&
        activeHost.isLocal &&
        activeHost.isConnectedUsable;

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
                      subtitle: _isAndroidDevice
                          ? (localReady
                              ? '已就绪 · 离线可用'
                              : (isRemoteThin ? '按需下载 · 约 $downloadSizeLabel' : '内置 Ubuntu · 离线可用'))
                          : '本地 DSH 服务',
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
                                    ? (isRemoteThin
                                        ? (rt.hasPartialDownload
                                            ? '检测到上次未完成的下载断点（剩余约 $downloadSizeLabel），点击下方按钮即可断点续传并完成 Ubuntu + DeepSeek Harness 部署。'
                                            : '安装包已瘦身，首次部署将按需在线下载 ARM64 Ubuntu 与官方 DeepSeek Harness（约 $downloadSizeLabel），内置多国内镜像容灾、断点续传与 SHA-256 校验，部署完成后即可离线使用。')
                                        : '首次部署会自动释放 ARM64 Linux 根文件系统与官方 DeepSeek Harness，并支持后续一键安装 Python、Git、Ripgrep 等工具链。')
                                    : '当前非 Android 设备，可直接连接本机运行的 dsh web，或切换至右侧接入局域网/服务器上的远程主机。',
                                style: TextStyle(fontSize: 12.5, height: 1.5, color: t.text2),
                              ),
                              if (isBootstrappingNow) ...[
                                const SizedBox(height: 14),
                                GrassBagProgressBar(
                                  value: progress > 0 ? progress : null,
                                  height: 7,
                                  color: t.primary,
                                  trackColor: t.fill1,
                                ),
                                const SizedBox(height: 7),
                                Row(
                                  children: [
                                    GrassBagActivityIndicator(radius: 7, color: t.primary),
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
                              if (localReady || localInstalled) ...[
                                const SizedBox(height: 12),
                                GrassBagStatusBanner(
                                  tone: localStopped
                                      ? GrassBagBannerTone.warn
                                      : GrassBagBannerTone.ok,
                                  icon: localStopped
                                      ? CupertinoIcons.pause_circle_fill
                                      : CupertinoIcons.checkmark_circle_fill,
                                  title: rt.engineRunning || localReady
                                      ? '本机引擎运行正常'
                                      : (localStopped
                                          ? '本机容器已就绪（引擎未运行）'
                                          : (localStarting ? '正在启动本机引擎…' : '本机容器已部署完成')),
                                  message: rt.engineRunning || localReady
                                      ? 'DeepSeek Harness 已就绪，可以继续下一步配置模型或直接进入对话。'
                                      : (localStopped
                                          ? '容器环境已就绪，点按下方按钮即可立即拉起本机 DSH 引擎。'
                                          : '容器环境已就绪，引擎正在后台自动拉起。'),
                                  padding: const EdgeInsets.all(11),
                                  borderRadius: 14,
                                ),
                              ],
                              if (localStopped) ...[
                                const SizedBox(height: 14),
                                GrassBagPrimaryGlassButton(
                                  label: '启动本机引擎',
                                  icon: CupertinoIcons.play_fill,
                                  height: 44,
                                  tier: tier,
                                  insideGlass: true,
                                  onTap: () => unawaited(
                                    ref.read(appProvider.notifier).restartLocalEngine(),
                                  ),
                                ),
                              ] else if (_isAndroidDevice && !localInstalled && !localReady) ...[
                                const SizedBox(height: 14),
                                if (isBootstrappingNow && runtimeProgressCanCancel)
                                  Row(
                                    children: [
                                      Expanded(
                                        child: GrassBagPrimaryGlassButton(
                                          label: '正在下载环境（$runtimeProgressPct%）…',
                                          icon: CupertinoIcons.cloud_download_fill,
                                          height: 44,
                                          tier: tier,
                                          insideGlass: true,
                                          enabled: false,
                                          onTap: null,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      GrassBagSecondaryGlassButton(
                                        label: '暂停',
                                        icon: CupertinoIcons.pause_fill,
                                        height: 44,
                                        padding: const EdgeInsets.symmetric(horizontal: 14),
                                        tier: tier,
                                        insideGlass: true,
                                        onTap: () => unawaited(
                                          ref.read(appProvider.notifier).cancelLocalRuntimeBootstrap(),
                                        ),
                                      ),
                                    ],
                                  )
                                else
                                  GrassBagPrimaryGlassButton(
                                    label: isBootstrappingNow
                                        ? '正在部署本机环境…'
                                        : (localHasError
                                            ? '重试部署本机环境'
                                            : (isRemoteThin
                                                ? (rt.hasPartialDownload
                                                    ? '继续下载并部署（剩余 $downloadSizeLabel）'
                                                    : '下载并部署（约 $downloadSizeLabel）')
                                                : '一键部署本机容器')),
                                    icon: isRemoteThin
                                        ? CupertinoIcons.cloud_download_fill
                                        : CupertinoIcons.rocket_fill,
                                    height: 44,
                                    tier: tier,
                                    insideGlass: true,
                                    enabled: !isBootstrappingNow,
                                    onTap: isBootstrappingNow ? null : _startLocalBootstrap,
                                  ),
                                if (isRemoteThin && !isBootstrappingNow) ...[
                                  const SizedBox(height: 8),
                                  Center(
                                    child: GrassBagSpringTap(
                                      onTap: () => showRuntimeMirrorSheet(context, ref),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(CupertinoIcons.globe, size: 12.5, color: t.text3),
                                            const SizedBox(width: 5),
                                            Text(
                                              '下载源：${rt.runtimeMirrorDisplayLabel} · 切换镜像',
                                              style: TextStyle(fontSize: 11.5, color: t.text3),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ] else if (!_isAndroidDevice) ...[
                                const SizedBox(height: 14),
                                if (desktopLocalConnected)
                                  GrassBagStatusBanner(
                                    tone: GrassBagBannerTone.ok,
                                    icon: CupertinoIcons.checkmark_circle_fill,
                                    title: '已连接本机 DeepSeek Harness',
                                    message: '${activeHost.address} · ${activeHost.latency}',
                                    padding: const EdgeInsets.all(11),
                                    borderRadius: 14,
                                  )
                                else
                                  GrassBagPrimaryGlassButton(
                                    label: connectionPhase == ConnectionPhase.connecting &&
                                            activeHost.isLocal
                                        ? '正在连接本机服务…'
                                        : '连接本机 127.0.0.1:3080',
                                    icon: CupertinoIcons.link,
                                    height: 44,
                                    tier: tier,
                                    insideGlass: true,
                                    enabled: !(connectionPhase == ConnectionPhase.connecting &&
                                        activeHost.isLocal),
                                    onTap: (connectionPhase == ConnectionPhase.connecting &&
                                            activeHost.isLocal)
                                        ? null
                                        : () => unawaited(
                                              ref.read(appProvider.notifier).switchHost('local'),
                                            ),
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
                                action: GrassBagSecondaryGlassButton(
                                  label: _expandRemoteCardWhenConnected ? '收起主机列表' : '更换远程主机',
                                  icon: _expandRemoteCardWhenConnected
                                      ? CupertinoIcons.chevron_up
                                      : CupertinoIcons.arrow_2_squarepath,
                                  height: 32,
                                  tier: tier,
                                  insideGlass: true,
                                  onTap: () => setState(
                                    () => _expandRemoteCardWhenConnected =
                                        !_expandRemoteCardWhenConnected,
                                  ),
                                ),
                              ),
                              if (_expandRemoteCardWhenConnected) const SizedBox(height: 10),
                            ],
                            if (!remoteConnected || _expandRemoteCardWhenConnected)
                              RemoteHostConnectCard(
                                showHeader: false,
                                connectImmediately: true,
                                initiallyShowGuide: false,
                                autoScanLan: !remoteConnected,
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
    NativePermissionsStatus perms,
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
                child: CustomPaint(
                  foregroundPainter: tier == GrassBagGlassTier.solid
                      ? null
                      : GrassBagFresnelRimPainter(
                          isDark: t.isDark,
                          isCircle: true,
                          tinted: true,
                          accent: allReady ? t.ok : t.primaryHi,
                          frosted: tier == GrassBagGlassTier.frosted,
                          strokeWidth: 1.0,
                        ),
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
                      color: t.onPrimary,
                    ),
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
                padding: const EdgeInsets.all(12),
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
                              ? (_isAndroidDevice
                                  ? '本机独立 Linux 与 DSH 引擎已接入'
                                  : '本机 DeepSeek Harness (${activeHost.address}) 已接入')
                              : '${activeHost.address} · ${activeHost.latency}')
                          : (_isAndroidDevice
                              ? '可返回上一步一键部署本机容器或连接远程电脑'
                              : '可返回上一步连接本机服务或配置远程主机'),
                      trailing: envReady
                          ? null
                          : GrassBagSpringTap(
                              onTap: () {
                                final rtNow = ref.read(appProvider).nativeRuntimeStatus;
                                if (_isAndroidDevice &&
                                    rtNow.initialized &&
                                    !rtNow.engineRunning &&
                                    rtNow.engineState != 'error') {
                                  unawaited(ref.read(appProvider.notifier).restartLocalEngine());
                                } else {
                                  _goToPage(1);
                                }
                              },
                              enablePointerGlow: false,
                              haptic: true,
                              child: GrassBagFresnelGlassSurface(
                                isPill: true,
                                innerWell: true,
                                interactive: true,
                                tintColor: t.primarySoft,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 11, vertical: 5.5),
                                child: Text(
                                  (_isAndroidDevice &&
                                          ref.read(appProvider).nativeRuntimeStatus.initialized &&
                                          !ref.read(appProvider).nativeRuntimeStatus.engineRunning &&
                                          ref.read(appProvider).nativeRuntimeStatus.engineState !=
                                              'error')
                                      ? '启动引擎'
                                      : '去配置',
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
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final loginBtn = GrassBagPrimaryGlassButton(
                            label: '登录 DeepSeek',
                            icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                            height: 38,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
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
                          );
                          final apiBtn = GrassBagSecondaryGlassButton(
                            label: 'API Key / 中转',
                            icon: CupertinoIcons.slider_horizontal_3,
                            height: 38,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            tier: tier,
                            insideGlass: true,
                            accentForeground: true,
                            onTap: envReady
                                ? _openModelSettings
                                : () {
                                    ref.read(appProvider.notifier).showToast(
                                          '请先完成运行环境部署或连接远程主机',
                                          tone: ToastTone.info,
                                        );
                                    _goToPage(1);
                                  },
                          );
                          if (constraints.maxWidth < 316) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                loginBtn,
                                const SizedBox(height: 8),
                                apiBtn,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: loginBtn),
                              const SizedBox(width: 8),
                              Expanded(child: apiBtn),
                            ],
                          );
                        },
                      ),
                    ],

                    // 3. Inline Android System Permissions Setup (Accessibility, Overlay, Battery, Notifications, Storage)
                    if (_isAndroidDevice) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Divider(height: 0.5, color: t.sep),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '手机权限与操控授权（可按需跳过）',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: t.text2,
                              ),
                            ),
                          ),
                          Text(
                            '已授权 ${[
                              perms.accessibilityEnabled,
                              perms.overlayGranted,
                              perms.batteryOptIgnored,
                              perms.notificationsGranted,
                              perms.allFilesGranted,
                            ].where((e) => e).length}/5',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: perms.accessibilityEnabled ? t.ok : t.text3,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      GrassBagSheetSection(
                        borderRadius: 12,
                        dividerIndent: 54,
                        children: [
                          _OnboardingPermissionTile(
                            done: perms.accessibilityEnabled,
                            warn: perms.accessibilityNeedsRetoggle,
                            icon: CupertinoIcons.hand_draw_fill,
                            title: perms.accessibilityEnabled
                                ? '无障碍屏幕操控（已就绪）'
                                : (perms.accessibilityNeedsRetoggle ? '无障碍服务需重开' : '无障碍屏幕操控'),
                            subtitle: perms.accessibilityEnabled
                                ? '支持跨应用悬浮确认卡、读屏与原生自动操控'
                                : (perms.sdkInt >= 33
                                    ? 'Android 13+ 若灰显，先点下方「应用详情」允许受限设置'
                                    : '开启后 AI 可在安全护栏下跨应用操作手机'),
                            actionLabel: perms.accessibilityEnabled ? '已开启' : '去开启',
                            secondaryLabel: (!perms.accessibilityEnabled && perms.sdkInt >= 33) ? '应用详情' : null,
                            onSecondaryTap: () => GrassBagNativeBridge.instance.openPermissionSettings('app_details'),
                            onTap: () => GrassBagNativeBridge.instance.openPermissionSettings('accessibility'),
                          ),
                          _OnboardingPermissionTile(
                            done: perms.overlayGranted,
                            icon: CupertinoIcons.layers_alt_fill,
                            title: '悬浮窗权限',
                            subtitle: '辅助显示液态玻璃悬浮岛与外部确认弹窗',
                            actionLabel: perms.overlayGranted ? '已授权' : '去授权',
                            onTap: () => GrassBagNativeBridge.instance.openPermissionSettings('overlay'),
                          ),
                          _OnboardingPermissionTile(
                            done: perms.batteryOptIgnored,
                            icon: CupertinoIcons.battery_100,
                            title: '忽略电池优化（后台保活）',
                            subtitle: '防止切到其他 App 时系统杀死容器或无障碍服务',
                            actionLabel: perms.batteryOptIgnored ? '已豁免' : '去设置',
                            onTap: () => GrassBagNativeBridge.instance.openPermissionSettings('battery'),
                          ),
                          _OnboardingPermissionTile(
                            done: perms.notificationsGranted,
                            icon: CupertinoIcons.bell_fill,
                            title: '通知提醒权限',
                            subtitle: '任务完成提醒与前台服务常驻保活',
                            actionLabel: perms.notificationsGranted ? '已允许' : '一键授权',
                            onTap: () => unawaited(
                              ref.read(appProvider.notifier).requestRuntimePermission('notifications'),
                            ),
                          ),
                          _OnboardingPermissionTile(
                            done: perms.allFilesGranted,
                            icon: CupertinoIcons.folder_fill,
                            title: '手机公共存储访问',
                            subtitle: '让容器与 AI 直接整理下载目录与手机文档',
                            actionLabel: perms.allFilesGranted ? '已允许' : '去开启',
                            onTap: () {
                              if (perms.sdkInt < 30) {
                                unawaited(ref.read(appProvider.notifier).requestRuntimePermission('storage'));
                              } else {
                                unawaited(GrassBagNativeBridge.instance.openPermissionSettings('storage'));
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerRight,
                        child: GrassBagSpringTap(
                          onTap: _openPermissionsSettings,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                            child: Text(
                              '查看完整权限中心 ›',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: t.primary,
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
              1 => envReady
                  ? GrassBagPrimaryGlassButton(
                      label: '继续下一步',
                      icon: CupertinoIcons.arrow_right_circle_fill,
                      height: 48,
                      tier: tier,
                      onTap: () => _goToPage(2),
                    )
                  : GrassBagSecondaryGlassButton(
                      label: '稍后配置，继续下一步',
                      icon: CupertinoIcons.arrow_right_circle,
                      height: 48,
                      tier: tier,
                      accentForeground: true,
                      onTap: () => _goToPage(2),
                    ),
              _ => modelReady
                  ? GrassBagPrimaryGlassButton(
                      label: _finishing ? '正在进入…' : '开始使用 GrassBag',
                      icon: CupertinoIcons.sparkles,
                      height: 48,
                      tier: tier,
                      enabled: !_finishing,
                      onTap: _finishing ? null : _finishOnboarding,
                    )
                  : GrassBagSecondaryGlassButton(
                      label: _finishing ? '正在进入…' : '稍后配置模型，直接进入',
                      icon: CupertinoIcons.arrow_right_circle,
                      height: 48,
                      tier: tier,
                      accentForeground: true,
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
    return GrassBagFresnelGlassSurface(
      isPill: true,
      innerWell: true,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final dist = (pageOffset - i).abs().clamp(0.0, 1.0);
          final active = 1.0 - dist;
          final width = 7.0 + 21.0 * active;
          final color = Color.lerp(
            t.sepStrong,
            t.primary,
            active,
          )!;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onTapStep(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
              child: Container(
                width: width,
                height: 6.5,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: active > 0.5
                      ? [
                          BoxShadow(
                            color: t.primary.withValues(alpha: 0.36 * active),
                            blurRadius: 6,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          );
        }),
      ),
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
    final ambientTier = resolveAmbientGlassTier(context);
    final isSolid = ambientTier == GrassBagGlassTier.solid;
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(13),
      decoration: ShapeDecoration(
        color: isSolid
            ? (selected ? t.primarySoft : t.cardSolid)
            : null,
        gradient: isSolid
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: selected
                    ? (t.isDark
                        ? [
                            t.primaryHi.withValues(alpha: 0.26),
                            t.primary.withValues(alpha: 0.13),
                          ]
                        : [
                            Color.lerp(Colors.white, t.primaryHi, 0.22)!.withValues(alpha: 0.90),
                            Color.lerp(Colors.white, t.primaryHi, 0.10)!.withValues(alpha: 0.76),
                          ])
                    : (t.isDark
                        ? [
                            Color.lerp(t.cardSolid, Colors.white, 0.09)!.withValues(alpha: 0.78),
                            t.cardSolid.withValues(alpha: 0.64),
                          ]
                        : [
                            Colors.white.withValues(alpha: 0.80),
                            Colors.white.withValues(alpha: 0.56),
                          ]),
              ),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(20),
          side: isSolid
              ? BorderSide(
                  color: selected ? t.primary : t.sep,
                  width: selected ? 1.3 : 0.7,
                )
              : (selected && !t.isDark
                  ? BorderSide(color: t.primaryHi.withValues(alpha: 0.38), width: 0.85)
                  : BorderSide.none),
        ),
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
                filled: selected,
              ),
              const Spacer(),
              if (badge != null)
                GrassBagFresnelGlassSurface(
                  isPill: true,
                  innerWell: true,
                  tintColor: badgeOk
                      ? t.okSoft
                      : (selected ? t.primarySoft : null),
                  padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 2.5),
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
    );
    return GrassBagSpringTap(
      onTap: onTap,
      borderRadius: 20,
      enablePointerGlow: isSolid,
      haptic: true,
      child: isSolid
          ? card
          : GrassBagInteractiveHighlight(
              borderRadius: 20,
              accent: selected ? t.primary : t.primaryHi,
              child: CustomPaint(
                foregroundPainter: GrassBagFresnelRimPainter(
                  isDark: t.isDark,
                  borderRadius: 20,
                  accent: selected ? t.primary : t.primaryHi,
                  tinted: selected,
                  frosted: ambientTier == GrassBagGlassTier.frosted,
                  strokeWidth: selected ? 1.1 : 0.85,
                ),
                child: card,
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
    this.trailing,
  });

  final bool done;
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final badgeColor = done ? t.ok : t.primary;
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
    final interval = Interval(start, end, curve: Curves.easeOutCubic);
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) {
        final v = interval.transform(controller.value);
        if (v >= 0.999) return child!;
        return FadeTransition(
          opacity: AlwaysStoppedAnimation<double>(v),
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
/// Repaints directly via `super(repaint: ...)` with zero 120Hz widget rebuilds or throttle stutter!
class _OnboardingAmbientPainter extends CustomPainter {
  _OnboardingAmbientPainter({
    required this.pageOffset,
    required this.ambient,
    required this.isDark,
    required this.primary,
    required this.primaryHi,
    required this.bg,
  }) : super(repaint: Listenable.merge([ambient, pageOffset]));

  final ValueListenable<double> pageOffset;
  final Animation<double> ambient;
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
          ? [bg, Color.lerp(bg, primary, 0.08)!]
          : [bg, Color.lerp(bg, primary, 0.09)!],
    );
    canvas.drawRect(rect, Paint()..shader = bgGrad.createShader(rect));

    final p = (pageOffset.value / 2.0).clamp(0.0, 1.0);
    final ambientPhase = ambient.value * math.pi * 2.0;
    final driftX = math.sin(ambientPhase) * 18.0;
    final driftY = math.cos(ambientPhase * 0.8) * 14.0;

    // Orb 1: Primary halo shifting smoothly across pages
    _drawOrb(
      canvas,
      Offset(
        size.width * (0.20 + p * 0.58) + driftX,
        size.height * (0.18 + math.sin(p * math.pi) * 0.12) + driftY,
      ),
      size.shortestSide * 0.68,
      primary.withValues(alpha: isDark ? 0.22 : 0.16),
    );

    // Orb 2: Secondary accent counter-drifting on bottom edge
    _drawOrb(
      canvas,
      Offset(
        size.width * (0.84 - p * 0.52) - driftX * 0.8,
        size.height * (0.76 - p * 0.14) - driftY,
      ),
      size.shortestSide * 0.62,
      primaryHi.withValues(alpha: isDark ? 0.16 : 0.13),
    );

    // Orb 3: Soft theme-harmonized frost bloom for depth
    _drawOrb(
      canvas,
      Offset(
        size.width * (0.50 + math.sin(p * math.pi) * 0.22),
        size.height * (0.48 + p * 0.12) + driftY * 0.5,
      ),
      size.shortestSide * 0.55,
      Color.lerp(primary, primaryHi, 0.55)!.withValues(alpha: isDark ? 0.10 : 0.11),
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
      oldDelegate.pageOffset != pageOffset ||
      oldDelegate.ambient != ambient ||
      oldDelegate.isDark != isDark ||
      oldDelegate.primary != primary ||
      oldDelegate.primaryHi != primaryHi ||
      oldDelegate.bg != bg;
}

class _OnboardingPermissionTile extends StatelessWidget {
  const _OnboardingPermissionTile({
    required this.done,
    this.warn = false,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    this.secondaryLabel,
    this.onSecondaryTap,
    required this.onTap,
  });

  final bool done;
  final bool warn;
  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final String? secondaryLabel;
  final VoidCallback? onSecondaryTap;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final accent = done ? t.ok : (warn ? t.err : t.primary);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GrassBagSpringTap(
            onTap: onTap,
            pressedScale: 0.98,
            haptic: true,
            child: Row(
              children: [
                GrassBagSquircleIcon(
                  icon: done ? CupertinoIcons.checkmark_alt : icon,
                  color: accent,
                  size: 32,
                  iconSize: 15,
                  filled: done,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                      const SizedBox(height: 1.5),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.32,
                          color: t.text3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                GrassBagFresnelGlassSurface(
                  isPill: true,
                  innerWell: true,
                  interactive: !done,
                  tintColor: done ? t.okSoft : (warn ? t.errSoft : t.primarySoft),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  child: Text(
                    actionLabel,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (secondaryLabel != null && onSecondaryTap != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: GrassBagSpringTap(
                onTap: onSecondaryTap!,
                enablePointerGlow: false,
                haptic: true,
                child: GrassBagFresnelGlassSurface(
                  isPill: true,
                  innerWell: true,
                  interactive: true,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.info_circle, size: 12, color: t.text2),
                      const SizedBox(width: 4),
                      Text(
                        '打开$secondaryLabel以解除受限设置',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: t.text2,
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
    );
  }
}
