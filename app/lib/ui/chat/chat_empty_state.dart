import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' show Colors, Tooltip;
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_mascot.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import '../web/deepseek_signin_page.dart';

/// Flagship Apple iOS 26 Empty New Chat Screen:
/// - Floating cute GrassBag mascot silhouette (zero clunky box!)
/// - Light-weight 28pt time greeting + quiet subtitle (fixed typography; pure-GPU scale on IME!)
/// - Crystal Liquid Glass floating Workspace capsule
/// - Whisper-light borderless SetupItem row (Preset + 4-Tier Permission)
/// - 2×2 continuous superellipse frosted Suggestion cards with staggered GPU exit/bloom choreography
/// - Interactive rotating tip line (exits first on keyboard rise, blooms last on dismiss)
class ChatEmptyState extends ConsumerWidget {
  const ChatEmptyState({
    super.key,
    required this.onSuggestionTap,
    this.onOpenModelSettings,
    this.onOpenHostSettings,
    this.onOpenDiagnostics,
    this.keyboardOpen = false,
    this.keyboardProgress = 0.0,
    this.keyboardProgressListenable,
    this.onHeroHeightChanged,
    this.onDeckHeightChanged,
  });

  final ValueChanged<String> onSuggestionTap;
  final VoidCallback? onOpenModelSettings;
  final VoidCallback? onOpenHostSettings;
  final VoidCallback? onOpenDiagnostics;
  final bool keyboardOpen;

  /// Smooth continuous keyboard-elevation progress `0.0` (closed) → `1.0` (open).
  /// Used when [keyboardProgressListenable] is not supplied (e.g., standalone / tests).
  final double keyboardProgress;

  /// Optional 120Hz spring-driven progress listenable so IME choreography updates
  /// pure GPU transforms & opacities with ZERO full-widget rebuilds or layout jitter!
  final ValueListenable<double>? keyboardProgressListenable;

  /// Reports resting hero section height (above suggestion deck) to the parent stage
  /// for mathematically monotonic vertical centering with zero down-then-up bounce.
  final ValueChanged<double>? onHeroHeightChanged;

  /// Reports resting suggestion deck + tip height to the parent stage.
  final ValueChanged<double>? onDeckHeightChanged;

  String _timeGreeting() {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 11) return '上午好';
    if (h >= 11 && h < 13) return '中午好';
    if (h >= 13 && h < 18) return '下午好';
    if (h >= 18 && h < 23) return '晚上好';
    return '夜深了';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Narrow selector prevents engine_log / toast / background updates from rebuilding
    // the empty-state canvas or interrupting IME animations.
    final state = ref.watch(
      appProvider.select(
        (s) => (
          hostId: s.activeHostId,
          hostIsLocal: s.activeHost.isLocal,
          hostName: s.activeHost.name,
          hostNeedsAuth: s.activeHost.needsAuth,
          hostLastErrorCode: s.activeHost.lastErrorCode,
          activePermission: s.activePermission,
          activePreset: s.activePreset,
          activeWorkspace: s.activeWorkspaceDisplayName,
          connectionPhase: s.connectionPhase,
          isDshConnected: s.isDshConnected,
          hydratingDomains: s.hydratingDomains,
          hasAvailableModels: s.hasAvailableModels,
          routableProvidersCount: s.routableProviders.length,
          glassTier: s.glassTier,
          isActiveHostDesktop: s.isActiveHostDesktop,
          tipIndex: s.tipIndex,
          nativeRuntimeStatus: s.nativeRuntimeStatus,
          nativeStatusHydrated: s.nativeStatusHydrated,
          runtimeProgressPct: s.runtimeProgressPct,
          runtimeProgressMsg: s.runtimeProgressMsg,
          runtimeProgressCanCancel: s.runtimeProgressCanCancel,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final perm = state.activePermission;
    final tip = kEmptyTips[state.tipIndex % kEmptyTips.length];
    final rt = state.nativeRuntimeStatus;
    final isAndroidNative = GrassBagNativeBridge.instance.isAndroidNative;
    final isHostTransientConnecting = state.connectionPhase == ConnectionPhase.connecting ||
        state.connectionPhase == ConnectionPhase.reconnecting ||
        state.connectionPhase == ConnectionPhase.bootstrapping;
    final showLocalContainerBanner = isAndroidNative &&
        state.hostIsLocal &&
        state.nativeStatusHydrated &&
        (!rt.engineRunning ||
            (state.runtimeProgressPct > 0 && state.runtimeProgressPct < 100) ||
            state.connectionPhase == ConnectionPhase.error);
    final showRemoteStatusBanner = !state.hostIsLocal &&
        !state.isDshConnected &&
        !isHostTransientConnecting;
    final showLocalDesktopErrorBanner = !isAndroidNative &&
        state.hostIsLocal &&
        !state.isDshConnected &&
        state.connectionPhase == ConnectionPhase.error;
    final showNoModelOnboarding = !showLocalContainerBanner &&
        !showRemoteStatusBanner &&
        !showLocalDesktopErrorBanner &&
        state.isDshConnected &&
        state.connectionPhase == ConnectionPhase.connected &&
        !state.hydratingDomains &&
        !state.hasAvailableModels &&
        state.routableProvidersCount == 0;

    final isDesktopHost = state.isActiveHostDesktop;
    final suggestions = [
      (
        CupertinoIcons.folder_fill,
        '看看工作区',
        '查看目录结构与改动',
        t.ok,
        '帮我查看当前工作区的目录结构与最近文件改动概览',
      ),
      (
        CupertinoIcons.chevron_left_slash_chevron_right,
        '跑一遍测试',
        '定位并修复失败项',
        t.dusk,
        '运行当前项目的测试或静态检查，定位问题并给出修复方案',
      ),
      if (isDesktopHost || !isAndroidNative)
        (
          CupertinoIcons.arrow_branch,
          '梳理 Git 改动',
          '总结未提交变更风险',
          t.warn,
          '检查当前工作区的 git 状态与最近提交，总结核心变更与潜在风险',
        )
      else
        (
          CupertinoIcons.tray_full_fill,
          '整理手机文件',
          '归类或清理下载目录',
          t.warn,
          '帮我查看手机下载目录的大文件，并按类型给出清理或压缩建议',
        ),
      if (isAndroidNative && state.hostIsLocal)
        (
          CupertinoIcons.device_phone_portrait,
          '操控手机',
          '自然语言操控应用',
          t.isDark ? const Color(0xFF56B0EE) : const Color(0xFF1F5F87),
          '帮我打开系统设置，查看当前网络与电量状态后返回 GrassBag',
        )
      else
        (
          CupertinoIcons.doc_text_fill,
          '整理项目文档',
          '梳理架构与接口说明',
          t.primary,
          '阅读当前项目核心模块并整理一份清晰的架构与使用说明文档',
        ),
    ];

    final fallbackProgress =
        (keyboardOpen ? 1.0 : keyboardProgress).clamp(0.0, 1.0);
    final listenable = keyboardProgressListenable;

    Widget buildHeroHeader() {
      const mascot = RepaintBoundary(child: _FloatingMascot(size: 48));
      final greetingBlock = RepaintBoundary(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _timeGreeting(),
              style: TextStyle(
                fontSize: 28.0,
                fontWeight: FontWeight.w300,
                letterSpacing: -0.5,
                color: t.text,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 5.0, bottom: 16.0),
              child: Text(
                '今天想做点什么？',
                style: TextStyle(fontSize: 14, color: t.text2),
              ),
            ),
          ],
        ),
      );
      return _KbProgressBuilder(
        listenable: listenable,
        fallback: fallbackProgress,
        builder: (_, p, __) {
          // Pure GPU scale & parallax tuck phase-locked 1:1 to `_openProgressNotifier`
          // (no double-easing over OS/spring curve -> symmetric open & dismiss!).
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.translate(
                offset: Offset(0, 4.0 * p),
                child: Transform.scale(
                  scale: 1.0 - 0.14 * p,
                  alignment: Alignment.bottomCenter,
                  child: mascot,
                ),
              ),
              const SizedBox(height: 10.0),
              Transform.translate(
                offset: Offset(0, -2.0 * p),
                child: Transform.scale(
                  scale: 1.0 - 0.08 * p,
                  alignment: Alignment.topCenter,
                  child: greetingBlock,
                ),
              ),
            ],
          );
        },
      );
    }

    // Hoist static workspace capsule + setup row OUTSIDE _KbProgressBuilder so 120Hz
    // IME spring ticks only translate a cached layer instead of rebuilding widgets!
    final staticWorkspaceAndSetup = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GrassBagSpringTap(
          pressedScale: 0.96,
          enablePointerGlow: false,
          haptic: true,
          onTap: () => (state.activeWorkspace.isEmpty &&
                  (isHostTransientConnecting || state.hydratingDomains))
              ? showHostQuickSheet(context, ref)
              : showWorkspaceSheet(context, ref),
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 15),
            decoration: ShapeDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: t.isDark
                    ? [
                        Colors.white.withValues(alpha: 0.12),
                        Colors.white.withValues(alpha: 0.06),
                      ]
                    : [
                        Colors.white.withValues(alpha: 0.72),
                        Colors.white.withValues(alpha: 0.52),
                      ],
              ),
              shape: StadiumBorder(
                side: BorderSide(
                  color: t.isDark
                      ? Colors.white.withValues(alpha: 0.20)
                      : Colors.white.withValues(alpha: 0.92),
                  width: 0.8,
                ),
              ),
              shadows: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: t.isDark ? 0.22 : 0.055),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isHostTransientConnecting && state.activeWorkspace.isNotEmpty) ...[
                  GrassBagStatusDot(color: t.primary, pulsing: true, size: 7),
                  const SizedBox(width: 7),
                ] else ...[
                  Icon(CupertinoIcons.folder_fill, size: 15, color: t.primary),
                  const SizedBox(width: 7),
                ],
                Flexible(
                  child: Text(
                    state.activeWorkspace.isEmpty
                        ? ((isHostTransientConnecting || state.hydratingDomains)
                            ? (state.hostIsLocal ? '正在连接本机 DSH…' : '正在连接「${state.hostName}」…')
                            : '选择工作区')
                        : '在「${state.activeWorkspace}」中${state.hostIsLocal ? '' : ' · ${state.hostName}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.1,
                      color: t.text,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(CupertinoIcons.chevron_down, size: 11.5, color: t.text3),
              ],
            ),
          ),
        ),
        const SizedBox(height: 9),

        // Whisper-light borderless SetupItem row (Preset & 4-Tier Permission)
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 4,
          runSpacing: 4,
          children: [
            _SetupItem(
              icon: CupertinoIcons.compass,
              label: state.activePreset.name,
              onTap: () => showPresetSheet(context, ref),
            ),
            _SetupItem(
              icon: perm.risky
                  ? CupertinoIcons.exclamationmark_shield_fill
                  : CupertinoIcons.shield,
              label: perm.name,
              warnTone: perm.risky,
              onTap: () => showPermissionSheet(context, ref),
            ),
          ],
        ),
      ],
    );

    final heroControls = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        buildHeroHeader(),

        // Luminous translucent workspace capsule (vector-composited so scrolling inside
        // _KeyboardAwareEmptyStage stays 100% 120fps with zero scrolling Impeller shaders!)
        _KbProgressBuilder(
          listenable: listenable,
          fallback: fallbackProgress,
          child: RepaintBoundary(child: staticWorkspaceAndSetup),
          builder: (_, p, child) {
            return Transform.translate(
              offset: Offset(0, -7.0 * p),
              child: child,
            );
          },
        ),
      ],
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MeasureBoxHeight(
              onHeightChanged: onHeroHeightChanged,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  heroControls,
            if (showLocalContainerBanner) ...[
              const SizedBox(height: 14),
              _LocalRuntimeBanner(
                rt: rt,
                progressPct: state.runtimeProgressPct,
                progressMsg: state.runtimeProgressMsg,
                canCancel: state.runtimeProgressCanCancel,
                hasConnectionError: state.connectionPhase == ConnectionPhase.error,
                tier: state.glassTier,
                onBootstrap: () => triggerLocalRuntimeBootstrapWithGuard(context, ref),
                onCancelBootstrap: () => ctrl.cancelLocalRuntimeBootstrap(),
                onStartEngine: () => ctrl.restartLocalEngine(),
                onOpenDiagnostics: onOpenDiagnostics,
              ),
            ] else if (showRemoteStatusBanner) ...[
              const SizedBox(height: 14),
              _RemoteEmptyStatusBanner(
                hostName: state.hostName,
                needsAuth: state.hostNeedsAuth || state.connectionPhase == ConnectionPhase.needsAuth,
                isTls: state.hostLastErrorCode == 'tls_cert',
                tier: state.glassTier,
                onPrimaryTap: () {
                  final activeHost = ref.read(appProvider).activeHost;
                  if (state.hostNeedsAuth || state.connectionPhase == ConnectionPhase.needsAuth) {
                    showRemoteHostAuthSheet(context, ref, activeHost);
                  } else if (state.hostLastErrorCode == 'tls_cert') {
                    ctrl.setHostAllowBadCertificates(state.hostId, true);
                  } else {
                    ctrl.probeAndRefreshHost(state.hostId);
                  }
                },
                onSecondaryTap: () {
                  final isNeedsAuth =
                      state.hostNeedsAuth || state.connectionPhase == ConnectionPhase.needsAuth;
                  if (isNeedsAuth) {
                    showHostQuickSheet(
                      context,
                      ref,
                      onOpenHostSettings: onOpenHostSettings,
                    );
                  } else if (onOpenHostSettings != null) {
                    onOpenHostSettings!();
                  } else {
                    showHostQuickSheet(context, ref);
                  }
                },
              ),
            ] else if (showLocalDesktopErrorBanner) ...[
              const SizedBox(height: 14),
              GrassBagCard(
                borderRadius: 20,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    GrassBagSquircleIcon(
                      icon: CupertinoIcons.wifi_exclamationmark,
                      color: t.warn,
                      size: 34,
                      iconSize: 16,
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '未连接到本机 DSH 服务',
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: t.text),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '请确认本机 DSH 已启动，或切换至其他远程主机',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, height: 1.35, color: t.text3),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    GrassBagPrimaryGlassButton(
                      label: '重试连接',
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tier: state.glassTier,
                      insideGlass: true,
                      onTap: () => ctrl.probeAndRefreshHost(state.hostId),
                    ),
                  ],
                ),
              ),
            ] else if (showNoModelOnboarding) ...[
              const SizedBox(height: 14),
              GrassBagCard(
                borderRadius: 22,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        GrassBagSquircleIcon(
                          icon: CupertinoIcons.sparkles,
                          color: t.primary,
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
                                '尚未配置可用模型渠道',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: t.text,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '一键登录 DeepSeek 账号，或添加常用 API Key / 中转站即可开始对话',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11.5, height: 1.35, color: t.text3),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 11),
                    Row(
                      children: [
                        Expanded(
                          child: GrassBagPrimaryGlassButton(
                            label: '登录 DeepSeek',
                            icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                            height: 34,
                            tier: state.glassTier,
                            insideGlass: true,
                            onTap: () => launchDeepSeekSignInFlow(context, ref),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: GrassBagSecondaryGlassButton(
                            label: 'API Key / 中转',
                            icon: CupertinoIcons.slider_horizontal_3,
                            height: 34,
                            tier: state.glassTier,
                            insideGlass: true,
                            onTap: onOpenModelSettings ??
                                () => showModelSheet(
                                      context,
                                      ref,
                                      onOpenModelSettings: onOpenModelSettings,
                                    ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
                ],
              ),
            ),
            // Build only the active suggestion layout branch inside LayoutBuilder and isolate
            // each staggered slice in a RepaintBoundary so 120Hz IME springs composite cached layers!
            () {
              final tipRowContent = RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Tooltip(
                    message: '轻点切换使用提示',
                    child: GrassBagSpringTap(
                      onTap: ctrl.nextEmptyTip,
                      pressedScale: 0.98,
                      enablePointerGlow: false,
                      haptic: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Row(
                          children: [
                            Icon(CupertinoIcons.lightbulb, size: 14.5, color: t.warn),
                            const SizedBox(width: 8),
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                switchInCurve: Curves.linear,
                                switchOutCurve: Curves.linear,
                                transitionBuilder: (child, anim) => _TipSlideFadeTransition(
                                  animation: anim,
                                  child: child,
                                ),
                                child: Align(
                                  key: ValueKey(tip),
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    tip,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 12, height: 1.38, color: t.text3),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(CupertinoIcons.chevron_right, size: 12, color: t.text3),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );

              return _MeasureBoxHeight(
                onHeightChanged: onDeckHeightChanged,
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final twoCol = constraints.maxWidth >= 300;
                    final List<Widget>? singleColTiles = twoCol
                        ? null
                        : [
                            for (var i = 0; i < suggestions.length; i++)
                              RepaintBoundary(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: _SuggestionTile(
                                    icon: suggestions[i].$1,
                                    title: suggestions[i].$2,
                                    subtitle: suggestions[i].$3,
                                    accent: suggestions[i].$4,
                                    onTap: () => onSuggestionTap(suggestions[i].$5),
                                  ),
                                ),
                              ),
                          ];
                    final Widget? twoColRow1 = twoCol
                        ? RepaintBoundary(
                            child: Row(
                              children: [
                                Expanded(
                                  child: _SuggestionTile(
                                    icon: suggestions[0].$1,
                                    title: suggestions[0].$2,
                                    subtitle: suggestions[0].$3,
                                    accent: suggestions[0].$4,
                                    onTap: () => onSuggestionTap(suggestions[0].$5),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _SuggestionTile(
                                    icon: suggestions[1].$1,
                                    title: suggestions[1].$2,
                                    subtitle: suggestions[1].$3,
                                    accent: suggestions[1].$4,
                                    onTap: () => onSuggestionTap(suggestions[1].$5),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : null;
                    final Widget? twoColRow2 = twoCol
                        ? RepaintBoundary(
                            child: Row(
                              children: [
                                Expanded(
                                  child: _SuggestionTile(
                                    icon: suggestions[2].$1,
                                    title: suggestions[2].$2,
                                    subtitle: suggestions[2].$3,
                                    accent: suggestions[2].$4,
                                    onTap: () => onSuggestionTap(suggestions[2].$5),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _SuggestionTile(
                                    icon: suggestions[3].$1,
                                    title: suggestions[3].$2,
                                    subtitle: suggestions[3].$3,
                                    accent: suggestions[3].$4,
                                    onTap: () => onSuggestionTap(suggestions[3].$5),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : null;
                    return _KbProgressBuilder(
                      listenable: listenable,
                      fallback: fallbackProgress,
                      builder: (_, p, __) {
                        return IgnorePointer(
                          ignoring: p > 0.08,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(height: 22),
                              if (!twoCol)
                                Column(
                                  children: [
                                    for (var i = 0; i < singleColTiles!.length; i++)
                                      _StaggeredDeckSlice(
                                        progress: p,
                                        start: 0.02 + 0.03 * (singleColTiles.length - 1 - i),
                                        end: 0.54 + 0.06 * (singleColTiles.length - 1 - i),
                                        dy: 14.0 + 3.0 * i,
                                        minScale: 0.93,
                                        child: singleColTiles[i],
                                      ),
                                  ],
                                )
                              else
                                Column(
                                  children: [
                                    _StaggeredDeckSlice(
                                      progress: p,
                                      start: 0.08,
                                      end: 0.72,
                                      dy: 16.0,
                                      minScale: 0.94,
                                      child: twoColRow1!,
                                    ),
                                    const SizedBox(height: 10),
                                    _StaggeredDeckSlice(
                                      progress: p,
                                      start: 0.02,
                                      end: 0.58,
                                      dy: 22.0,
                                      minScale: 0.92,
                                      child: twoColRow2!,
                                    ),
                                  ],
                                ),
                              _StaggeredDeckSlice(
                                progress: p,
                                start: 0.0,
                                end: 0.42,
                                dy: 12.0,
                                minScale: 0.96,
                                child: tipRowContent,
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              );
            }(),
          ],
        ),
      ),
    );
  }
}

/// Subscribes to a 120Hz [ValueListenable] when provided (avoiding full-widget rebuilds
/// during IME spring ticks), or falls back to a static [fallback] progress value.
class _KbProgressBuilder extends StatelessWidget {
  const _KbProgressBuilder({
    required this.listenable,
    required this.fallback,
    required this.builder,
    this.child,
  });

  final ValueListenable<double>? listenable;
  final double fallback;
  final Widget Function(BuildContext context, double progress, Widget? child) builder;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final l = listenable;
    if (l == null) {
      return builder(context, fallback.clamp(0.0, 1.0), child);
    }
    return ValueListenableBuilder<double>(
      valueListenable: l,
      child: child,
      builder: (ctx, value, cachedChild) =>
          builder(ctx, value.clamp(0.0, 1.0), cachedChild),
    );
  }
}

/// Pure-GPU staggered exit & bloom-in slice for suggestion rows and rotating tip.
/// Phase-locked linearly to `_openProgressNotifier` (symmetric open & dismiss!) and
/// skips painting completely once faded out while maintaining exact layout height.
class _StaggeredDeckSlice extends StatelessWidget {
  const _StaggeredDeckSlice({
    required this.progress,
    required this.start,
    required this.end,
    required this.dy,
    required this.minScale,
    required this.child,
  });

  final double progress;
  final double start;
  final double end;
  final double dy;
  final double minScale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final span = (end - start).clamp(0.01, 1.0);
    final local = ((progress - start) / span).clamp(0.0, 1.0);
    final opacity = (1.0 - local).clamp(0.0, 1.0);
    final scale = 1.0 - (1.0 - minScale) * local;
    return Visibility(
      visible: opacity > 0.005,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: GrassBagControlledOpacity(
        opacity: opacity,
        child: Transform.translate(
          offset: Offset(0, dy * local),
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topCenter,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Directional tip ticker transition: incoming tips glide up from below while outgoing
/// tips glide cleanly upward out of sight (owns & disposes its CurvedAnimations).
class _TipSlideFadeTransition extends StatefulWidget {
  const _TipSlideFadeTransition({
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;

  @override
  State<_TipSlideFadeTransition> createState() => _TipSlideFadeTransitionState();
}

class _TipSlideFadeTransitionState extends State<_TipSlideFadeTransition> {
  late CurvedAnimation _fadeCurve;
  late CurvedAnimation _slideCurve;

  void _init() {
    _fadeCurve = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );
    _slideCurve = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant _TipSlideFadeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _fadeCurve.dispose();
      _slideCurve.dispose();
      _init();
    }
  }

  @override
  void dispose() {
    _fadeCurve.dispose();
    _slideCurve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animation,
      child: widget.child,
      builder: (context, child) {
        final isReverse = widget.animation.status == AnimationStatus.reverse;
        final dy = (isReverse ? -0.32 : 0.32) * (1.0 - _slideCurve.value);
        return GrassBagControlledOpacity(
          opacity: _fadeCurve.value.clamp(0.0, 1.0),
          child: FractionalTranslation(
            translation: Offset(0, dy),
            child: child,
          ),
        );
      },
    );
  }
}

/// Lightweight layout height observer reporting resting section height only when it
/// actually changes by > 0.5px (zero layout loops, zero frame churn).
class _MeasureBoxHeight extends SingleChildRenderObjectWidget {
  const _MeasureBoxHeight({
    required this.onHeightChanged,
    required super.child,
  });

  final ValueChanged<double>? onHeightChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureBoxHeight(onHeightChanged);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasureBoxHeight renderObject) {
    renderObject.onHeightChanged = onHeightChanged;
  }
}

class _RenderMeasureBoxHeight extends RenderProxyBox {
  _RenderMeasureBoxHeight(this.onHeightChanged);

  ValueChanged<double>? onHeightChanged;
  double _lastReported = -1.0;

  @override
  void performLayout() {
    super.performLayout();
    final cb = onHeightChanged;
    if (cb == null || !hasSize) return;
    final h = size.height;
    if (h > 0 && (h - _lastReported).abs() > 0.5) {
      _lastReported = h;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        cb(h);
      });
    }
  }
}

class _RemoteEmptyStatusBanner extends StatelessWidget {
  const _RemoteEmptyStatusBanner({
    required this.hostName,
    required this.needsAuth,
    required this.isTls,
    required this.tier,
    required this.onPrimaryTap,
    required this.onSecondaryTap,
  });

  final String hostName;
  final bool needsAuth;
  final bool isTls;
  final GrassBagGlassTier tier;
  final VoidCallback onPrimaryTap;
  final VoidCallback onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final title = needsAuth
        ? '「$hostName」需要完成一次授权'
        : (isTls ? '「$hostName」证书未受信任' : '远程主机「$hostName」暂未连接');
    final sub = needsAuth
        ? '已连通目标设备，粘贴一次启动链接或网页登录后 30 天免填'
        : (isTls ? '检测到自签名 HTTPS 证书，信任后可立即恢复连接' : '可点击重试连接，或查看桌面端免命令引导 / 切换主机');
    final primaryLabel = needsAuth ? '去授权' : (isTls ? '信任证书' : '重试连接');
    return GrassBagCard(
      borderRadius: 20,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GrassBagSquircleIcon(
                icon: needsAuth
                    ? CupertinoIcons.lock_shield_fill
                    : CupertinoIcons.wifi_exclamationmark,
                color: needsAuth ? t.primary : t.warn,
                size: 34,
                iconSize: 16,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: t.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, height: 1.35, color: t.text3),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          Row(
            children: [
              Expanded(
                child: GrassBagPrimaryGlassButton(
                  label: primaryLabel,
                  height: 34,
                  tier: tier,
                  insideGlass: true,
                  onTap: onPrimaryTap,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GrassBagSecondaryGlassButton(
                  label: needsAuth ? '切换主机' : '连接引导',
                  height: 34,
                  tier: tier,
                  insideGlass: true,
                  onTap: onSecondaryTap,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LocalRuntimeBanner extends StatelessWidget {
  const _LocalRuntimeBanner({
    required this.rt,
    required this.progressPct,
    required this.progressMsg,
    this.canCancel = false,
    this.hasConnectionError = false,
    required this.tier,
    required this.onBootstrap,
    this.onCancelBootstrap,
    required this.onStartEngine,
    this.onOpenDiagnostics,
  });

  final NativeRuntimeStatus rt;
  final int progressPct;
  final String progressMsg;
  final bool canCancel;
  final bool hasConnectionError;
  final GrassBagGlassTier tier;
  final VoidCallback onBootstrap;
  final VoidCallback? onCancelBootstrap;
  final VoidCallback onStartEngine;
  final VoidCallback? onOpenDiagnostics;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final deploying = progressPct > 0 && progressPct < 100;
    final starting = rt.engineState == 'starting';
    final hasErr = rt.engineState == 'error' || hasConnectionError;
    final isRemoteThin = !rt.hasBundledRuntimePayloads;
    final sizeLabel = rt.formattedDownloadSize;

    final title = deploying
        ? (canCancel
            ? '正在下载本机运行环境 ($progressPct%)'
            : '正在部署本机 Ubuntu + DSH 容器 ($progressPct%)')
        : (!rt.initialized
            ? (isRemoteThin ? '按需下载本机 Ubuntu + DSH 环境' : '本机 Linux + DSH 容器尚未部署')
            : (starting
                ? '正在启动本机 Ubuntu + DSH 引擎…'
                : (hasErr ? '本机 DSH 引擎启动异常' : '本机容器已就绪，引擎未启动')));

    final subtitle = deploying
        ? (progressMsg.isNotEmpty
            ? progressMsg
            : (isRemoteThin ? '正在拉取运行环境组件并校验完整性…' : '正在解压内置运行时与桥接组件…'))
        : (!rt.initialized
            ? (isRemoteThin
                ? (rt.hasPartialDownload
                    ? '已保留上次下载断点（剩余约 $sizeLabel），点击可断点续传并自动部署'
                    : '首次使用需按需下载 Ubuntu 24.04 + Node 24 + DSH（约 $sizeLabel），支持镜像加速与断点续传')
                : '内置 Ubuntu 24.04 + Node 24 + DSH，一键解压后即可离线对话与运行命令')
            : (starting
                ? '首次启动约需数秒，完成后将自动接入本机工作区'
                : (hasErr
                    ? (rt.engineError ?? '请点击重试启动或在设置中查看引擎日志')
                    : '点击右侧按钮即可启动本机 DSH 引擎')));

    return GrassBagCard(
      borderRadius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GrassBagSquircleIcon(
                icon: hasErr
                    ? CupertinoIcons.exclamationmark_triangle_fill
                    : (isRemoteThin && !rt.initialized
                        ? CupertinoIcons.cloud_download_fill
                        : CupertinoIcons.cube_box_fill),
                color: hasErr ? t.err : t.primary,
                size: 34,
                iconSize: 16,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: hasErr ? onOpenDiagnostics : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: hasErr ? t.err : t.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, height: 1.35, color: t.text3),
                      ),
                      if (hasErr && onOpenDiagnostics != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '查看日志',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: t.primary,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(
                              CupertinoIcons.chevron_right,
                              size: 11,
                              color: t.primary,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (deploying && canCancel && onCancelBootstrap != null)
                GrassBagSecondaryGlassButton(
                  label: '暂停',
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                  tier: tier,
                  insideGlass: true,
                  onTap: onCancelBootstrap,
                )
              else if (starting || deploying)
                GrassBagActivityIndicator(radius: 9, color: t.primary)
              else
                GrassBagPrimaryGlassButton(
                  label: !rt.initialized
                      ? (isRemoteThin ? (rt.hasPartialDownload ? '继续下载' : '下载部署') : '一键部署')
                      : (hasErr ? '重试' : '启动'),
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  tier: tier,
                  insideGlass: true,
                  onTap: !rt.initialized ? onBootstrap : onStartEngine,
                ),
            ],
          ),
          if (deploying) ...[
            const SizedBox(height: 10),
            GrassBagProgressBar(
              value: (progressPct / 100.0).clamp(0.0, 1.0),
              height: 5,
            ),
          ],
        ],
      ),
    );
  }
}

class _SetupItem extends StatelessWidget {
  const _SetupItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.warnTone = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool warnTone;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13.5, color: warnTone ? t.warn : t.text2),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: warnTone ? FontWeight.w600 : FontWeight.w500,
              color: warnTone ? t.warn : t.text2,
            ),
          ),
        ),
        const SizedBox(width: 3),
        Icon(
          CupertinoIcons.chevron_down,
          size: 10.5,
          color: warnTone ? t.warn : t.text3,
        ),
      ],
    );
    return GrassBagSpringTap(
      onTap: onTap,
      pressedScale: 0.94,
      enablePointerGlow: false,
      haptic: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 34),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: warnTone ? t.warnSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: row,
        ),
      ),
    );
  }
}

class _SuggestionTile extends StatefulWidget {
  const _SuggestionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_SuggestionTile> createState() => _SuggestionTileState();
}

class _SuggestionTileState extends State<_SuggestionTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: GrassBagSpringTap(
        onTap: widget.onTap,
        pressedScale: 0.96,
        enablePointerGlow: false,
        haptic: true,
        child: AnimatedScale(
          scale: _hovered ? 1.012 : 1.0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: GrassBagCard(
            borderRadius: 20,
            interactive: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                GrassBagSquircleIcon(
                  icon: widget.icon,
                  color: widget.accent,
                  size: 36,
                  iconSize: 16.5,
                ),
                const SizedBox(width: 9.5),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                          color: t.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.25,
                          color: t.text3,
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
    );
  }
}

/// Tactile spring-in mascot entrance (`GlassSpring.bouncy`) — playful lift on New Chat
/// mount with zero idle battery drain.
class _FloatingMascot extends StatefulWidget {
  const _FloatingMascot({required this.size});
  final double size;

  @override
  State<_FloatingMascot> createState() => _FloatingMascotState();
}

class _FloatingMascotState extends State<_FloatingMascot>
    with SingleTickerProviderStateMixin {
  late final SingleSpringController _spring;

  @override
  void initState() {
    super.initState();
    _spring = SingleSpringController(
      vsync: this,
      spring: GlassSpring.bouncy(duration: const Duration(milliseconds: 520)),
      initialValue: 0.0,
    )..animateTo(1.0);
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _spring,
      child: GrassBagMascot(size: widget.size, withShadow: true),
      builder: (_, child) {
        final v = _spring.value;
        final clamped = v.clamp(0.0, 1.0);
        // Keep FadeTransition permanently mounted so tree depth NEVER changes mid-spring;
        // RenderAnimatedOpacity automatically skips OpacityLayer when opacity == 1.0!
        return FadeTransition(
          opacity: AlwaysStoppedAnimation<double>(clamped >= 0.995 ? 1.0 : clamped),
          child: Transform.translate(
            offset: Offset(0, (1.0 - v) * 10.0),
            child: Transform.scale(
              scale: (0.86 + 0.14 * v).clamp(0.80, 1.08),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
