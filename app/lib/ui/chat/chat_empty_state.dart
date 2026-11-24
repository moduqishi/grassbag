import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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
/// - Light-weight 28pt time greeting + quiet subtitle
/// - Crystal Liquid Glass floating Workspace capsule ([GrassBagGlassPillButton])
/// - Whisper-light borderless SetupItem row (Preset + 4-Tier Permission)
/// - 2×2 continuous superellipse frosted Suggestion cards with Apple squircle icons
/// - Interactive rotating tip line (smoothly tucks away when keyboard is open)
class ChatEmptyState extends ConsumerWidget {
  const ChatEmptyState({
    super.key,
    required this.onSuggestionTap,
    this.onOpenModelSettings,
    this.onOpenHostSettings,
    this.keyboardOpen = false,
  });

  final ValueChanged<String> onSuggestionTap;
  final VoidCallback? onOpenModelSettings;
  final VoidCallback? onOpenHostSettings;
  final bool keyboardOpen;

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
          activeWorkspace: s.activeWorkspace,
          connectionPhase: s.connectionPhase,
          isDshConnected: s.isDshConnected,
          hasAvailableModels: s.hasAvailableModels,
          routableProvidersCount: s.routableProviders.length,
          glassTier: s.glassTier,
          isActiveHostDesktop: s.isActiveHostDesktop,
          tipIndex: s.tipIndex,
          nativeRuntimeStatus: s.nativeRuntimeStatus,
          runtimeProgressPct: s.runtimeProgressPct,
          runtimeProgressMsg: s.runtimeProgressMsg,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final perm = state.activePermission;
    final tip = kEmptyTips[state.tipIndex % kEmptyTips.length];
    final rt = state.nativeRuntimeStatus;
    final isAndroidNative = GrassBagNativeBridge.instance.isAndroidNative;
    final showLocalContainerBanner = isAndroidNative &&
        state.hostIsLocal &&
        (!rt.engineRunning || (state.runtimeProgressPct > 0 && state.runtimeProgressPct < 100));
    final showRemoteStatusBanner = !state.hostIsLocal &&
        !state.isDshConnected &&
        state.connectionPhase != ConnectionPhase.connecting;
    final showLocalDesktopErrorBanner = !isAndroidNative &&
        state.hostIsLocal &&
        !state.isDshConnected &&
        state.connectionPhase == ConnectionPhase.error;
    final showNoModelOnboarding = !showLocalContainerBanner &&
        !showRemoteStatusBanner &&
        !showLocalDesktopErrorBanner &&
        state.isDshConnected &&
        state.connectionPhase == ConnectionPhase.connected &&
        !state.hasAvailableModels &&
        state.routableProvidersCount == 0;

    final isDesktopHost = state.isActiveHostDesktop;
    final suggestions = [
      (
        CupertinoIcons.folder_fill,
        '看看工作区',
        '列出文件结构与近期改动',
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
      if (isDesktopHost)
        (
          CupertinoIcons.arrow_branch,
          '梳理 Git 改动',
          '总结未提交变更与风险',
          t.warn,
          '检查当前工作区的 git 状态与最近提交，总结核心变更与潜在风险',
        )
      else
        (
          CupertinoIcons.film_fill,
          '整理手机文件',
          '归类或压缩下载目录文件',
          t.warn,
          '帮我查看手机下载目录的大文件，并按类型给出清理或压缩建议',
        ),
      (
        CupertinoIcons.doc_text_fill,
        '整理项目文档',
        '生成清晰结构与接口说明',
        t.primary,
        '阅读当前项目核心模块并整理一份清晰的架构与使用说明文档',
      ),
    ];

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const RepaintBoundary(
              child: _FloatingMascot(size: 48),
            ),
            const SizedBox(height: 10),
            Text(
              _timeGreeting(),
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w300,
                letterSpacing: -0.5,
                color: t.text,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 5, bottom: 16),
              child: Text(
                '今天想做点什么？',
                style: TextStyle(fontSize: 14, color: t.text2),
              ),
            ),

            // Luminous translucent workspace capsule (vector-composited so scrolling inside
            // _KeyboardAwareEmptyStage stays 100% 120fps with zero scrolling Impeller shaders!)
            GrassBagSpringTap(
              pressedScale: 0.96,
              haptic: true,
              onTap: () => showWorkspaceSheet(context, ref),
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
                            Colors.white.withValues(alpha: 0.88),
                            Colors.white.withValues(alpha: 0.72),
                          ],
                  ),
                  shape: StadiumBorder(
                    side: BorderSide(
                      color: t.isDark
                          ? Colors.white.withValues(alpha: 0.20)
                          : Colors.white.withValues(alpha: 0.94),
                      width: 0.75,
                    ),
                  ),
                  shadows: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: t.isDark ? 0.24 : 0.07),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.folder_fill, size: 15, color: t.primary),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        state.activeWorkspace.isEmpty
                            ? (state.connectionPhase == ConnectionPhase.connecting
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
            if (showLocalContainerBanner) ...[
              const SizedBox(height: 14),
              _LocalRuntimeBanner(
                rt: rt,
                progressPct: state.runtimeProgressPct,
                progressMsg: state.runtimeProgressMsg,
                tier: state.glassTier,
                onBootstrap: () => ctrl.bootstrapLocalRuntime(),
                onStartEngine: () => ctrl.restartLocalEngine(),
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
                  if (onOpenHostSettings != null) {
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
                borderRadius: 20,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        GrassBagSquircleIcon(
                          icon: CupertinoIcons.sparkles,
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
            const SizedBox(height: 22),

            // Continuous Superellipse Luminous 2×2 Suggestion Cards
            LayoutBuilder(
              builder: (ctx, constraints) {
                final twoCol = constraints.maxWidth >= 340;
                if (!twoCol) {
                  return Column(
                    children: [
                      for (final s in suggestions)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _SuggestionTile(
                            icon: s.$1,
                            title: s.$2,
                            subtitle: s.$3,
                            accent: s.$4,
                            onTap: () => onSuggestionTap(s.$5),
                          ),
                        ),
                    ],
                  );
                }
                return Column(
                  children: [
                    Row(
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
                    const SizedBox(height: 10),
                    Row(
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
                  ],
                );
              },
            ),
            // Interactive Rotating Tip Row (static height avoids IME layout thrash)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: GrassBagSpringTap(
                onTap: ctrl.nextEmptyTip,
                pressedScale: 0.98,
                haptic: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.lightbulb, size: 15, color: t.warn),
                      const SizedBox(width: 8),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.linear,
                          switchOutCurve: Curves.linear,
                          transitionBuilder: (child, anim) => FadeTransition(
                            opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0, 0.25),
                                end: Offset.zero,
                              ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
                              child: child,
                            ),
                          ),
                          child: Align(
                            key: ValueKey(tip),
                            alignment: Alignment.centerLeft,
                            child: Text(
                              tip,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: t.text3),
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
          ],
        ),
      ),
    );
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
    required this.tier,
    required this.onBootstrap,
    required this.onStartEngine,
  });

  final NativeRuntimeStatus rt;
  final int progressPct;
  final String progressMsg;
  final GrassBagGlassTier tier;
  final VoidCallback onBootstrap;
  final VoidCallback onStartEngine;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final deploying = progressPct > 0 && progressPct < 100;
    final starting = rt.engineState == 'starting';
    final hasErr = rt.engineState == 'error';

    final title = deploying
        ? '正在部署本机 Ubuntu + DSH 容器 ($progressPct%)'
        : (!rt.initialized
            ? '本机 Linux + DSH 容器尚未部署'
            : (starting
                ? '正在启动本机 Ubuntu + DSH 引擎…'
                : (hasErr ? '本机 DSH 引擎启动异常' : '本机容器已就绪，引擎未启动')));

    final subtitle = deploying
        ? (progressMsg.isNotEmpty ? progressMsg : '正在解压内置运行时与桥接组件…')
        : (!rt.initialized
            ? '内置 Ubuntu 24.04 + Node 24 + DSH，一键解压后即可离线对话与运行命令'
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
                    : CupertinoIcons.cube_box_fill,
                color: hasErr ? t.err : t.primary,
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
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (starting || deploying)
                CupertinoActivityIndicator(radius: 9, color: t.primary)
              else
                GrassBagPrimaryGlassButton(
                  label: !rt.initialized ? '一键部署' : (hasErr ? '重试' : '启动'),
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
    return GrassBagSpringTap(
      onTap: onTap,
      pressedScale: 0.94,
      haptic: true,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: warnTone ? t.warnSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13.5, color: warnTone ? t.warn : t.text2),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: warnTone ? FontWeight.w600 : FontWeight.w500,
                color: warnTone ? t.warn : t.text2,
              ),
            ),
            const SizedBox(width: 3),
            Icon(
              CupertinoIcons.chevron_down,
              size: 10.5,
              color: warnTone ? t.warn : t.text3,
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagSpringTap(
      onTap: onTap,
      pressedScale: 0.96,
      haptic: true,
      child: GrassBagCard(
        borderRadius: 20,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 12),
        child: Row(
          children: [
            GrassBagSquircleIcon(
              icon: icon,
              color: accent,
              size: 36,
              iconSize: 16.5,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
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
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: t.text3),
                  ),
                ],
              ),
            ),
          ],
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
