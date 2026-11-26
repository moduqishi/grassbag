import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import '../web/official_web_page.dart';
import 'permissions_center_page.dart';
import 'settings_page.dart';

/// Flagship Apple iOS 26/27 Liquid Glass Phone Control Center:
/// - Live status & readiness hero card with 1-tap safe demo & interactive overlay previews
/// - Automated completion auto-return, Edge Aurora glow, and live touch/swipe gesture FX switches
/// - SafetyGate policy control, hard-protected app rules sheet, and 1-tap Emergency Stop
/// - Human-readable Chinese audit timeline
class PhoneControlView extends ConsumerStatefulWidget {
  const PhoneControlView({
    super.key,
    this.onOpenModelSettings,
  });

  final VoidCallback? onOpenModelSettings;

  @override
  ConsumerState<PhoneControlView> createState() => _PhoneControlViewState();
}

class _PhoneControlViewState extends ConsumerState<PhoneControlView> {
  bool _showAllAudit = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && GrassBagNativeBridge.instance.isAndroidNative) {
        unawaited(ref.read(appProvider.notifier).refreshPermissionsOnly());
      }
    });
  }

  void _showProtectedRulesSheet(BuildContext context, GrassBagGlassTier tier) {
    showGrassBagSheet<void>(
      context,
      title: 'SafetyGate 硬安全隔离规则',
      subtitle: '以下防护由 Android 原生层强制执行，不受任何提示词或免确认策略影响',
      bodyBuilder: (ctx) {
        final t = GrassBagTokens.of(ctx);
        const rules = <(IconData, String, String)>[
          (
            CupertinoIcons.creditcard_fill,
            '银行、支付宝与数字钱包硬拦截',
            '所有银行客户端、支付钱包、云闪付与数字人民币界面始终禁止自动读取与代操作，仅可触发「安全接管」由你本人完成。',
          ),
          (
            CupertinoIcons.lock_shield_fill,
            '密码、验证码与支付输入框零触碰',
            '无障碍树识别到密码框、OTP 验证码或支付密码输入域时自动脱敏并硬阻断点击与输入。',
          ),
          (
            CupertinoIcons.gear_alt_fill,
            '系统设置与安装授权页只读不代点',
            '系统设置、权限弹窗、应用安装器仅允许诊断读取，严禁 AI 自行修改系统安全开关或静默安装应用。',
          ),
          (
            CupertinoIcons.chat_bubble_2_fill,
            '微信等高频关键应用写操作二次确认',
            '在微信及包含「发送 / 删除 / 支付 / 下单 / 卸载」等高风险按钮处自动弹出跨应用防劫持确认卡（360ms 武装防误触 + 遮挡拒触）。',
          ),
        ];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GrassBagSheetSection(
              dividerIndent: 52,
              children: [
                for (final r in rules)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GrassBagSquircleIcon(
                          icon: r.$1,
                          color: t.primary,
                          size: 30,
                          iconSize: 15,
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r.$2,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: t.text,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                r.$3,
                                style: TextStyle(fontSize: 12, height: 1.4, color: t.text3),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            GrassBagPrimaryGlassButton(
              label: '知道了',
              tier: tier,
              insideGlass: true,
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          isLocalHost: s.activeHost.isLocal,
          isDshConnected: s.isDshConnected,
          hasModels: s.routableProviders.isNotEmpty || s.hasAvailableModels,
          perms: s.nativePermissions,
          phoneConfirmHighRisk: s.phoneConfirmHighRisk,
          phoneAutoReturn: s.phoneAutoReturn,
          phoneShowEdgeAurora: s.phoneShowEdgeAurora,
          phoneShowGestureFx: s.phoneShowGestureFx,
          phoneLiveActive: s.phoneLiveActive,
          phoneLivePaused: s.phoneLivePaused,
          phoneLiveAction: s.phoneLiveAction,
          phoneLiveApp: s.phoneLiveApp,
          phoneLiveSteps: s.phoneLiveSteps,
          emergencyStopped: s.emergencyStopped,
          safetyPolicy: s.safetyPolicy,
          safetyAudit: s.safetyAudit,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final native = GrassBagNativeBridge.instance;
    final isAndroid = native.isAndroidNative;
    final perms = slice.perms;
    final needsRetoggle = perms.accessibilityNeedsRetoggle;
    final isReady = isAndroid && perms.accessibilityEnabled && !slice.emergencyStopped;
    final canRunDemo = isReady && slice.isLocalHost && slice.isDshConnected && slice.hasModels;
    const policies = ['ask', 'allow_turn', 'always'];
    final polIdx = policies.indexOf(slice.safetyPolicy).clamp(0, 2);

    if (!isAndroid) {
      return GrassBagCard(
        borderRadius: 24,
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            GrassBagSquircleIcon(
              icon: CupertinoIcons.device_phone_portrait,
              color: t.primary,
              size: 42,
              iconSize: 20,
              filled: true,
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '仅 Android 设备支持本机屏幕操控',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.text),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '在 Android 客户端开启无障碍服务后，可通过自然语言跨应用操控手机并自动返回 GrassBag。',
                    style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text3),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final heroColor = slice.emergencyStopped
        ? t.err
        : (slice.phoneLiveActive
            ? (slice.phoneLivePaused ? t.warn : t.primary)
            : (needsRetoggle ? t.err : (perms.accessibilityEnabled ? t.ok : t.warn)));

    final heroTitle = slice.emergencyStopped
        ? '手机操控已急停锁定'
        : (slice.phoneLiveActive
            ? (slice.phoneLivePaused
                ? '手机操控已暂停（第 ${slice.phoneLiveSteps} 步）'
                : '正在操控手机 · 第 ${slice.phoneLiveSteps} 步')
            : (needsRetoggle
                ? '无障碍服务未绑定'
                : (perms.accessibilityEnabled ? '手机操控已就绪' : '需要开启无障碍权限')));

    final heroSub = slice.emergencyStopped
        ? '所有屏幕自动化与跨应用操作已中止，点击下方恢复保护开关'
        : (slice.phoneLiveActive
            ? [
                if (slice.phoneLiveApp.isNotEmpty) slice.phoneLiveApp,
                if (slice.phoneLiveAction.isNotEmpty) slice.phoneLiveAction,
              ].join(' · ')
            : (needsRetoggle
                ? '系统开关已开但底层连接中断，请关闭后重新开启无障碍服务'
                : (perms.accessibilityEnabled
                    ? '支持跨应用灵动浮岛、实时触控轨迹，操作完成后自动返回 GrassBag'
                    : '开启无障碍屏幕操控后，即可用自然语言让助手代劳操作手机')));

    final visibleAudit = _showAllAudit ? slice.safetyAudit : slice.safetyAudit.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Flagship Live Hero Card
        GrassBagCard(
          borderRadius: 24,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  GrassBagSquircleIcon(
                    icon: slice.emergencyStopped
                        ? CupertinoIcons.exclamationmark_octagon_fill
                        : (slice.phoneLiveActive
                            ? CupertinoIcons.hand_draw_fill
                            : (perms.accessibilityEnabled
                                ? CupertinoIcons.sparkles
                                : CupertinoIcons.hand_raised_fill)),
                    color: heroColor,
                    size: 46,
                    iconSize: 22,
                    filled: true,
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                heroTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.2,
                                  color: t.text,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            _StatusChip(
                              label: slice.emergencyStopped
                                  ? '已锁定'
                                  : (slice.phoneLiveActive
                                      ? (slice.phoneLivePaused ? '暂停中' : '运行中')
                                      : (perms.accessibilityEnabled
                                          ? '就绪'
                                          : (needsRetoggle ? '需重开' : '待开启'))),
                              fg: heroColor,
                              bg: heroColor.withValues(alpha: t.isDark ? 0.22 : 0.12),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          heroSub.isEmpty ? '通过原生 SafetyGate 与无障碍通道安全操控设备' : heroSub,
                          style: TextStyle(fontSize: 12, height: 1.38, color: t.text3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (slice.phoneLiveActive)
                Row(
                  children: [
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: slice.phoneLivePaused ? '继续操控' : '暂停操控',
                        icon: slice.phoneLivePaused
                            ? CupertinoIcons.play_fill
                            : CupertinoIcons.pause_fill,
                        height: 38,
                        tier: slice.glassTier,
                        insideGlass: true,
                        onTap: () => unawaited(ctrl.setPhonePaused(!slice.phoneLivePaused)),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: '紧急急停',
                        icon: CupertinoIcons.stop_fill,
                        height: 38,
                        tier: slice.glassTier,
                        insideGlass: true,
                        destructive: true,
                        onTap: ctrl.triggerEmergencyStop,
                      ),
                    ),
                  ],
                )
              else if (slice.emergencyStopped)
                GrassBagPrimaryGlassButton(
                  label: '解除急停锁（恢复手机操控）',
                  icon: CupertinoIcons.play_circle_fill,
                  height: 40,
                  tier: slice.glassTier,
                  insideGlass: true,
                  onTap: ctrl.resetEmergencyStop,
                )
              else if (!perms.accessibilityEnabled)
                Row(
                  children: [
                    Expanded(
                      child: GrassBagPrimaryGlassButton(
                        label: needsRetoggle ? '重开无障碍开关' : '去开启无障碍',
                        icon: CupertinoIcons.hand_draw_fill,
                        height: 38,
                        tier: slice.glassTier,
                        insideGlass: true,
                        onTap: () => native.openPermissionSettings('accessibility'),
                      ),
                    ),
                    const SizedBox(width: 9),
                    GrassBagSecondaryGlassButton(
                      label: perms.sdkInt >= 33 ? '解锁指南' : '权限管理',
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      tier: slice.glassTier,
                      insideGlass: true,
                      onTap: () {
                        if (perms.sdkInt >= 33) {
                          showRestrictedSettingsGuideSheet(context, slice.glassTier);
                        } else {
                          Navigator.of(context).push(
                            GrassBagPageRoute<void>(builder: (_) => const PermissionsCenterPage()),
                          );
                        }
                      },
                    ),
                  ],
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: GrassBagPrimaryGlassButton(
                            label: canRunDemo
                                ? '实操试一试'
                                : (!slice.isLocalHost
                                    ? '切回本机'
                                    : (!slice.isDshConnected ? '本机连接中…' : '去配置模型')),
                            icon: canRunDemo
                                ? CupertinoIcons.play_fill
                                : (!slice.isLocalHost
                                    ? CupertinoIcons.arrow_2_circlepath
                                    : CupertinoIcons.slider_horizontal_3),
                            height: 38,
                            tier: slice.glassTier,
                            insideGlass: true,
                            enabled: canRunDemo || !slice.isLocalHost || slice.isDshConnected,
                            onTap: canRunDemo
                                ? () {
                                    Navigator.of(context).popUntil((route) => route.isFirst);
                                    unawaited(
                                      ctrl.sendPrompt(
                                        '请用手机操控打开计算器或时钟确认屏幕画面，操作完成后告诉我结果',
                                      ),
                                    );
                                  }
                                : (!slice.isLocalHost
                                    ? () => unawaited(ctrl.switchHost('local'))
                                    : (slice.isDshConnected
                                        ? () {
                                            if (widget.onOpenModelSettings != null) {
                                              widget.onOpenModelSettings!();
                                              return;
                                            }
                                            Navigator.of(context).push(
                                              GrassBagPageRoute<void>(
                                                builder: (routeCtx) => SettingsPage(
                                                  initialSection: SettingsSection.model,
                                                  onOpenWebUi: () => Navigator.of(routeCtx).push(
                                                    GrassBagPageRoute<void>(
                                                      builder: (_) => const OfficialWebPage(),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          }
                                        : null)),
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: GrassBagSecondaryGlassButton(
                            label: '预览悬浮岛',
                            icon: CupertinoIcons.sparkles,
                            height: 38,
                            tier: slice.glassTier,
                            insideGlass: true,
                            accentForeground: true,
                            onTap: () => unawaited(ctrl.previewPhoneOverlay(mode: 'interactive')),
                          ),
                        ),
                      ],
                    ),
                    if (!canRunDemo) ...[
                      const SizedBox(height: 8),
                      Text(
                        !slice.isLocalHost
                            ? '提示：当前为远程主机，切回「本机引擎」即可直接体验自然语言实操。'
                            : (!slice.isDshConnected
                                ? '提示：等待本机 DSH 引擎连接就绪后即可直接发起实操。'
                                : '提示：配置可用模型后即可发起自然语言手机实操。'),
                        style: TextStyle(fontSize: 11.5, height: 1.35, color: t.text3),
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // 2. Experience, Overlay & Motion Preferences (Auto-Return + Edge Aurora + Gesture FX)
        GrassBagGroupedSection(
          header: '操控体验与悬浮岛动效',
          footer: '操控期间轻点顶部灵动悬浮岛可展开实时步骤控制卡，拖到屏幕左右边缘可磁吸贴边收起，不遮挡第三方应用按钮。',
          dividerIndent: 56,
          children: [
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.arrow_uturn_left_circle_fill,
                color: t.primary,
                size: 32,
                iconSize: 16,
                filled: slice.phoneAutoReturn,
              ),
              title: const Text('操作完成后自动返回 GrassBag'),
              subtitle: const Text('任务结束播放完成光效，自动切回对话查看结果'),
              trailing: GrassBagGlassSwitch(
                value: slice.phoneAutoReturn,
                tier: slice.glassTier,
                onChanged: (v) => ctrl.setPhoneSetting(autoReturn: v),
              ),
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.rays,
                color: t.isDark ? const Color(0xFF4EC5F1) : const Color(0xFF1F87C4),
                size: 32,
                iconSize: 16,
                filled: slice.phoneShowEdgeAurora,
              ),
              title: const Text('屏幕边缘流光氛围边框'),
              subtitle: const Text('AI 接管期间在屏幕四周展示液态光晕，状态变化实时变色'),
              trailing: GrassBagGlassSwitch(
                value: slice.phoneShowEdgeAurora,
                tier: slice.glassTier,
                onChanged: (v) => ctrl.setPhoneSetting(showEdgeAurora: v),
              ),
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.hand_point_right_fill,
                color: t.isDark ? const Color(0xFF43C996) : const Color(0xFF199567),
                size: 32,
                iconSize: 16,
                filled: slice.phoneShowGestureFx,
              ),
              title: const Text('触控点击与滑动轨迹反馈'),
              subtitle: const Text('实时显示点击水波纹、长按蓄力环、滑动彗尾与输入提示'),
              trailing: GrassBagGlassSwitch(
                value: slice.phoneShowGestureFx,
                tier: slice.glassTier,
                onChanged: (v) => ctrl.setPhoneSetting(showGestureFx: v),
              ),
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.wand_stars,
                color: t.dusk,
                size: 32,
                iconSize: 15,
              ),
              title: const Text('演示触控轨迹与悬浮岛动效'),
              subtitle: const Text('立刻在当前屏幕上体验点击波纹、滑动彗尾、贴边收起与完成光效'),
              showChevron: true,
              onTap: () {
                if (!perms.accessibilityEnabled && !perms.overlayGranted) {
                  ctrl.showToast('请先开启无障碍服务或悬浮窗权限以演示动效', tone: ToastTone.warn);
                  return;
                }
                unawaited(ctrl.previewPhoneOverlay(mode: 'gestures'));
              },
            ),
          ],
        ),

        const SizedBox(height: 14),

        // 3. SafetyGate Policy & Emergency Stop
        GrassBagCard(
          borderRadius: 24,
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
                          'SafetyGate 安全护栏',
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.text),
                        ),
                        Text(
                          '银行、支付、系统设置与密码框始终硬拦截',
                          style: TextStyle(fontSize: 11.5, color: t.text3),
                        ),
                      ],
                    ),
                  ),
                  GrassBagSpringTap(
                    enablePointerGlow: false,
                    haptic: true,
                    onTap: () => _showProtectedRulesSheet(context, slice.glassTier),
                    child: GrassBagFresnelGlassSurface(
                      isPill: true,
                      innerWell: true,
                      interactive: true,
                      tintColor: t.primarySoft,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      child: Text(
                        '规则详情',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: t.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              GrassBagSegmentedControl(
                labels: const ['每次询问', '本轮允许', '免确认'],
                selectedIndex: polIdx,
                tier: slice.glassTier,
                onSelected: (i) async {
                  final next = policies[i];
                  if (next == 'always' && slice.safetyPolicy != 'always') {
                    final ok = await showGrassBagConfirmDialog(
                      context,
                      title: '切换为「免确认」模式？',
                      message: '开启后日常应用内的点击、滑动与输入将不再逐次弹出确认卡（银行、支付、系统设置与密码框仍受底层硬安全隔离）。',
                      confirmLabel: '确认开启',
                      isDestructive: true,
                    );
                    if (!ok || !context.mounted) return;
                  }
                  ctrl.setSafetyPolicy(next);
                },
              ),
              const SizedBox(height: 8),
              if (polIdx == 2) ...[
                GrassBagFresnelGlassSurface(
                  borderRadius: 12,
                  innerWell: true,
                  tintColor: t.warnSoft,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1.5),
                        child: Icon(
                          CupertinoIcons.exclamationmark_triangle_fill,
                          size: 13.5,
                          color: t.warn,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '高自动化模式：日常应用将免弹窗直接执行；银行、支付、系统设置与密码框仍永久受硬安全隔离保护。',
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.38,
                            fontWeight: FontWeight.w500,
                            color: t.warn,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else
                Text(
                  switch (polIdx) {
                    0 => '每次点击或打开应用前在屏幕下方弹出液态玻璃确认卡，可单步放行或升级为「本轮允许」。',
                    _ => '确认一次后本轮对话内流畅连续执行，但银行/支付/密码框与微信敏感操作仍强制拦截确认。',
                  },
                  style: TextStyle(fontSize: 11.5, height: 1.4, color: t.text3),
                ),
              const SizedBox(height: 10),
              GrassBagListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('跨应用高风险确认卡'),
                subtitle: const Text('触发发送、删除、支付、卸载等高风险操作前弹出防劫持悬浮确认卡'),
                trailing: GrassBagGlassSwitch(
                  value: slice.phoneConfirmHighRisk,
                  tier: slice.glassTier,
                  onChanged: (v) async {
                    if (!v && slice.phoneConfirmHighRisk) {
                      final ok = await showGrassBagConfirmDialog(
                        context,
                        title: '关闭跨应用高风险确认卡？',
                        message: '关闭后发送消息、删除内容或卸载应用等跨应用高风险操作将不再二次弹窗确认，仅保留银行/支付/系统设置/密码框底层拦截。',
                        confirmLabel: '确认关闭',
                        isDestructive: true,
                      );
                      if (!ok || !context.mounted) return;
                    }
                    ctrl.setPhoneSetting(confirmHighRisk: v);
                  },
                ),
              ),
              if (!slice.emergencyStopped && !slice.phoneLiveActive) ...[
                const SizedBox(height: 8),
                GrassBagSecondaryGlassButton(
                  label: '紧急急停锁定',
                  icon: CupertinoIcons.stop_circle_fill,
                  tier: slice.glassTier,
                  insideGlass: true,
                  destructive: true,
                  onTap: () async {
                    final ok = await showGrassBagConfirmDialog(
                      context,
                      title: '锁定手机操控（紧急急停）？',
                      message: '锁定后所有跨应用自动点击、滑动与输入操作都会被底层拦截，直到你手动解除锁定。不会中断当前普通对话生成。',
                      confirmLabel: '确认锁定',
                      isDestructive: true,
                    );
                    if (ok) {
                      unawaited(ctrl.triggerEmergencyStop());
                    }
                  },
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 14),

        // 4. Readiness & System Permissions Checklist
        GrassBagGroupedSection(
          header: '系统权限与保活检查',
          dividerIndent: 58,
          children: [
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.hand_draw_fill,
                color: perms.accessibilityEnabled
                    ? t.ok
                    : (needsRetoggle ? t.err : t.warn),
                size: 30,
                iconSize: 15,
                filled: perms.accessibilityEnabled,
              ),
              title: const Text('必需：无障碍屏幕操控'),
              subtitle: Text(
                perms.accessibilityEnabled
                    ? '服务运行正常 · 支持自动返回 GrassBag 与原生浮岛'
                    : (needsRetoggle ? '系统开关已开但未绑定，请先关闭再重开' : '未开启 · 点击前往系统无障碍设置'),
              ),
              trailing: _StatusChip(
                label: perms.accessibilityEnabled
                    ? '运行中'
                    : (needsRetoggle ? '需重开' : '去开启'),
                fg: perms.accessibilityEnabled ? t.ok : (needsRetoggle ? t.err : t.warn),
                bg: perms.accessibilityEnabled ? t.okSoft : (needsRetoggle ? t.errSoft : t.warnSoft),
              ),
              onTap: () {
                if (!perms.accessibilityEnabled && !needsRetoggle && perms.sdkInt >= 33) {
                  showRestrictedSettingsGuideSheet(context, slice.glassTier);
                } else {
                  native.openPermissionSettings('accessibility');
                }
              },
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.layers_alt_fill,
                color: perms.overlayGranted ? t.ok : t.primary,
                size: 30,
                iconSize: 15,
                filled: perms.overlayGranted,
              ),
              title: const Text('推荐：悬浮窗权限'),
              subtitle: Text(
                perms.overlayGranted ? '已授权 · 无障碍异常时可无缝兜底显示浮岛' : '建议开启作为跨应用悬浮岛兜底通道',
              ),
              trailing: _StatusChip(
                label: perms.overlayGranted ? '已授权' : '去开启',
                fg: perms.overlayGranted ? t.ok : t.text2,
                bg: perms.overlayGranted ? t.okSoft : t.fill1,
              ),
              onTap: () => native.openPermissionSettings('overlay'),
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.battery_100,
                color: perms.batteryOptIgnored ? t.ok : t.warn,
                size: 30,
                iconSize: 15,
                filled: perms.batteryOptIgnored,
              ),
              title: const Text('稳定：忽略电池优化'),
              subtitle: Text(
                perms.batteryOptIgnored ? '已允许后台保活' : '防止切换第三方 App 时后台断联或无法自动返回',
              ),
              trailing: _StatusChip(
                label: perms.batteryOptIgnored ? '已允许' : '去设置',
                fg: perms.batteryOptIgnored ? t.ok : t.text2,
                bg: perms.batteryOptIgnored ? t.okSoft : t.fill1,
              ),
              onTap: () => native.openPermissionSettings('battery'),
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.checkmark_shield_fill,
                color: t.primary,
                size: 30,
                iconSize: 15,
              ),
              title: const Text('打开统一权限管理中心'),
              subtitle: Text('已授权 ${perms.grantedCoreCount}/6 项 · 含 Android 13+ 受限设置指南'),
              showChevron: true,
              onTap: () => Navigator.of(context).push(
                GrassBagPageRoute<void>(builder: (_) => const PermissionsCenterPage()),
              ),
            ),
          ],
        ),

        // 5. Readable Audit Timeline (always visible with clear empty state when no logs yet)
        const SizedBox(height: 14),
        GrassBagGroupedSection(
          header: slice.safetyAudit.isEmpty
              ? '最近安全审计记录'
              : '最近安全审计记录 (${slice.safetyAudit.length})',
          dividerIndent: 52,
          children: [
            if (slice.safetyAudit.isEmpty)
              GrassBagListTile(
                leading: GrassBagSquircleIcon(
                  icon: CupertinoIcons.doc_text_search,
                  color: t.text3,
                  size: 30,
                  iconSize: 14,
                ),
                title: const Text('暂无安全审计记录'),
                subtitle: const Text('助手执行屏幕读取、点击或触发安全拦截后会在此自动留痕'),
              )
            else ...[
              for (final entry in visibleAudit) _AuditRowTile(entry: entry),
              if (slice.safetyAudit.length > 5)
                GrassBagListTile(
                  title: SizedBox(
                    width: double.infinity,
                    child: Text(
                      _showAllAudit ? '收起审计记录' : '展开全部 ${slice.safetyAudit.length} 条记录',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.primary),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  onTap: () => setState(() => _showAllAudit = !_showAllAudit),
                ),
            ],
          ],
        ),
      ],
    );
  }
}

class _AuditRowTile extends StatelessWidget {
  const _AuditRowTile({required this.entry});

  final Map<String, dynamic> entry;

  static (IconData, String) _describeTool(String tool) {
    return switch (tool) {
      'phone_tap' => (CupertinoIcons.hand_point_right_fill, '点击屏幕元素'),
      'phone_long_press' => (CupertinoIcons.hand_draw_fill, '长按屏幕元素'),
      'phone_swipe' => (CupertinoIcons.arrow_up_arrow_down, '滑动屏幕'),
      'phone_type' => (CupertinoIcons.keyboard, '输入文本'),
      'phone_open' => (CupertinoIcons.app_badge, '打开应用或链接'),
      'phone_screen' => (CupertinoIcons.viewfinder, '读取屏幕界面'),
      'phone_screenshot' => (CupertinoIcons.camera_viewfinder, '截取当前屏幕'),
      'phone_apps' => (CupertinoIcons.square_grid_2x2, '查询已安装应用'),
      'phone_key' => (CupertinoIcons.return_icon, '执行系统导航键'),
      'phone_intent' => (CupertinoIcons.bolt_fill, '调用系统快捷动作'),
      'phone_wait' => (CupertinoIcons.clock, '等待界面稳定'),
      'phone_handoff' => (CupertinoIcons.person_crop_circle_badge_checkmark, '安全交由人工操作'),
      'phone_return_app' => (CupertinoIcons.arrow_uturn_left_circle, '返回 GrassBag'),
      'emergency_stop' => (CupertinoIcons.stop_circle_fill, '触发紧急急停'),
      'confirm' => (CupertinoIcons.checkmark_shield, '本轮操作授权'),
      'policy' => (CupertinoIcons.slider_horizontal_3, '更新安全策略'),
      _ => (CupertinoIcons.device_phone_portrait, tool),
    };
  }

  static String _formatReason(String reason) {
    if (reason.startsWith('allowed:safe_tool')) return '安全只读/导航动作';
    if (reason.startsWith('allowed:full_access')) return '完全权限模式放行';
    if (reason.startsWith('allowed:turn_granted')) return '本轮允许放行';
    if (reason.startsWith('allowed:native_overlay_once')) return '悬浮确认卡单次允许';
    if (reason.startsWith('allowed:policy_always')) return '免确认策略放行';
    if (reason.startsWith('allowed:scroll')) return '常规滑动放行';
    if (reason.contains('blocked_sensitive_package')) return '硬安全拦截：金融/受保护应用';
    if (reason.contains('blocked_sensitive_input_field')) return '硬安全拦截：密码/验证码框';
    if (reason.contains('blocked_system_settings_write')) return '硬安全拦截：系统设置只读';
    if (reason.contains('user_cancelled')) return '用户手动取消';
    if (reason.contains('emergency_stop')) return '急停保护阻断';
    if (reason.contains('confirm_timeout')) return '确认卡片超时未响应';
    if (reason.contains('policy_updated')) return '策略已更新';
    if (reason.contains('user_granted_turn_allow')) return '用户授予本轮允许';
    return reason;
  }

  static String _formatTime(dynamic rawTs) {
    final ms = (rawTs as num?)?.toInt();
    if (ms == null || ms <= 0) return '';
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inSeconds < 60) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    return '${diff.inDays}天前';
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tool = entry['tool']?.toString() ?? 'tool';
    final target = entry['target']?.toString() ?? '';
    final reason = entry['reason']?.toString() ?? '';
    final allowed = entry['allowed'] == true;
    final (icon, label) = _describeTool(tool);
    final timeStr = _formatTime(entry['ts']);
    final subParts = <String>[
      _formatReason(reason),
      if (target.isNotEmpty && target != 'screen' && target != '-' && target != 'all') target,
      if (timeStr.isNotEmpty) timeStr,
    ];

    return GrassBagListTile(
      leading: GrassBagSquircleIcon(
        icon: icon,
        color: allowed ? t.primary : t.err,
        size: 30,
        iconSize: 14,
      ),
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subParts.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _StatusChip(
        label: allowed ? '放行' : '拦截',
        fg: allowed ? t.ok : t.err,
        bg: allowed ? t.okSoft : t.errSoft,
      ),
      showChevron: true,
      onTap: () {
        showGrassBagSheet<void>(
          context,
          title: label,
          subtitle: [allowed ? '已放行' : '已拦截', if (timeStr.isNotEmpty) timeStr].join(' · '),
          icon: icon,
          iconColor: allowed ? t.primary : t.err,
          bodyBuilder: (sheetCtx) {
            final st = GrassBagTokens.of(sheetCtx);
            return GrassBagFresnelGlassSurface(
              borderRadius: 16,
              innerWell: true,
              padding: const EdgeInsets.all(14),
              child: SelectableText(
                [
                  '工具：$tool',
                  '决策：${_formatReason(reason)}',
                  if (target.isNotEmpty && target != '-') '目标：$target',
                  if (reason.isNotEmpty) '原始标记：$reason',
                ].join('\n'),
                contextMenuBuilder: buildGrassBagEditableContextMenu,
                style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.55, color: st.text),
              ),
            );
          },
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.fg,
    required this.bg,
  });

  final String label;
  final Color fg;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return GrassBagFresnelGlassSurface(
      isPill: true,
      innerWell: true,
      tintColor: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 3),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}
