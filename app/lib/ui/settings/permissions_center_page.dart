import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';

/// Standalone pushable Permissions Center page (can be opened from Phone Control,
/// Local Host storage toggle, or directly inside Settings -> Permissions).
class PermissionsCenterPage extends ConsumerWidget {
  const PermissionsCenterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final topPad = MediaQuery.viewPaddingOf(context).top;
    final botPad = MediaQuery.viewPaddingOf(context).bottom;
    final isWide = MediaQuery.sizeOf(context).width >= 760;

    return GrassBagGlassPage(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(
              child: RefreshIndicator.adaptive(
                edgeOffset: topPad + 86,
                onRefresh: () => ref
                    .read(appProvider.notifier)
                    .refreshNativeStatus(skipAutoConnect: true, forceFresh: true),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                  padding: EdgeInsets.fromLTRB(16, topPad + 86, 16, 40 + botPad),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: isWide ? 720 : double.infinity),
                      child: const PermissionsCenterView(),
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
                title: '权限管理',
                subtitle: '统一管理无障碍、存储、保活与通知授权',
                tier: tier,
                onBack: () => Navigator.of(context).pop(),
                trailing: GrassBagGlassCircleButton(
                  icon: CupertinoIcons.refresh,
                  tooltip: '重新检测所有权限',
                  tier: tier,
                  useOwnLayer: false,
                  onTap: () async {
                    final ctrl = ref.read(appProvider.notifier);
                    await ctrl.refreshNativeStatus(skipAutoConnect: true, forceFresh: true);
                    ctrl.showToast('已刷新系统权限状态', tone: ToastTone.info);
                  },
                ),
              ),
            ),
            const GrassBagToastOverlay(bottomOffset: 24),
          ],
        ),
      ),
    );
  }
}

/// Shared Android 13+ Restricted Settings 3-step unlock guide invoked by both
/// [PermissionsCenterView] and [PhoneControlView].
void showRestrictedSettingsGuideSheet(BuildContext context, GrassBagGlassTier tier) {
  final native = GrassBagNativeBridge.instance;
  showGrassBagSheet<void>(
    context,
    title: 'Android 13+ 开启无障碍分步引导',
    subtitle: '若系统提示「受限设置」或开启开关后服务未生效，按顺序完成以下 3 步即可解锁',
    icon: CupertinoIcons.hand_draw_fill,
    bodyBuilder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final t = GrassBagTokens.of(ctx);
        final perms = ref.watch(appProvider.select((s) => s.nativePermissions));
        final steps = <(String, String, bool)>[
          (
            '1. 打开应用信息 → 允许受限设置',
            '进入系统「应用信息」页，点右上角「⋮」（部分机型在页面底部），选择「允许受限设置」。',
            perms.accessibilityEnabled,
          ),
          (
            '2. 前往无障碍 → 开启 GrassBag 手机操控助手',
            '找到「GrassBag 手机操控助手」并打开开关；若原本已开但失效，请先关闭再重新打开。',
            perms.accessibilityEnabled,
          ),
          (
            '3. 关闭电池优化（防止后台掉线）',
            '将耗电策略设为「无限制」，避免切后台或锁屏后系统自动终止无障碍服务。',
            perms.batteryOptIgnored,
          ),
        ];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GrassBagSheetSection(
              dividerIndent: 14,
              children: [
                for (final s in steps)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                s.$1,
                                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: t.text),
                              ),
                            ),
                            if (s.$3)
                              _PermBadge(label: '已完成', bg: t.okSoft, fg: t.ok),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          s.$2,
                          style: TextStyle(fontSize: 12, height: 1.4, color: t.text3),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: GrassBagSecondaryGlassButton(
                    label: '1. 应用信息',
                    icon: CupertinoIcons.info_circle,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    height: 38,
                    tier: tier,
                    insideGlass: true,
                    onTap: () => native.openPermissionSettings('app_details'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GrassBagPrimaryGlassButton(
                    label: '2. 前往无障碍',
                    icon: CupertinoIcons.hand_draw_fill,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    height: 38,
                    tier: tier,
                    insideGlass: true,
                    onTap: () => native.openPermissionSettings('accessibility'),
                  ),
                ),
              ],
            ),
            if (!perms.batteryOptIgnored) ...[
              const SizedBox(height: 8),
              GrassBagSecondaryGlassButton(
                label: '3. 关闭电池优化（推荐）',
                icon: CupertinoIcons.battery_100,
                height: 38,
                tier: tier,
                insideGlass: true,
                accentForeground: true,
                onTap: () => native.openPermissionSettings('battery'),
              ),
            ],
          ],
        );
      },
    ),
  );
}

/// Unified Android Permissions Center View embedded in Settings (`SettingsSection.permissions`)
/// and wrapped by [PermissionsCenterPage].
class PermissionsCenterView extends ConsumerStatefulWidget {
  const PermissionsCenterView({super.key});

  @override
  ConsumerState<PermissionsCenterView> createState() => _PermissionsCenterViewState();
}

class _PermissionsCenterViewState extends ConsumerState<PermissionsCenterView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(appProvider.notifier).refreshPermissionsOnly());
      }
    });
  }

  void _showRestrictedSettingsGuide(BuildContext context, GrassBagGlassTier tier) =>
      showRestrictedSettingsGuideSheet(context, tier);

  void _showShizukuInfoSheet(BuildContext context, GrassBagGlassTier tier) {
    showGrassBagSheet<void>(
      context,
      title: '关于 Shizuku 增强通道',
      subtitle: '后续版本预留能力，当前版本暂未集成',
      bodyBuilder: (ctx) {
        final t = GrassBagTokens.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'GrassBag 当前完全通过内置标准无障碍通道完成屏幕识别、点击、滑动与输入操作，暂未集成 Shizuku 调用能力，日常操控手机无需安装或启动 Shizuku。',
              style: TextStyle(fontSize: 13, height: 1.5, color: t.text2),
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
    final watched = ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          perms: s.nativePermissions,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final perms = watched.perms;
    final tier = watched.glassTier;
    final native = GrassBagNativeBridge.instance;

    if (!native.isAndroidNative) {
      return GrassBagCard(
        borderRadius: 24,
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            GrassBagSquircleIcon(
              icon: CupertinoIcons.checkmark_shield_fill,
              color: t.primary,
              size: 40,
              iconSize: 18,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前非 Android 移动设备', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.text)),
                  const SizedBox(height: 3),
                  Text(
                    '系统无障碍、悬浮窗、电池白名单与存储授权仅在 Android 客户端生效。',
                    style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text3),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final grantedCount = perms.grantedCoreCount;
    final needsRetoggle = perms.accessibilityNeedsRetoggle;
    final coreReady = perms.accessibilityEnabled && perms.batteryOptIgnored && !needsRetoggle;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Summary Hero Card with visual readiness progress bar
        GrassBagCard(
          borderRadius: 24,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  GrassBagSquircleIcon(
                    icon: needsRetoggle
                        ? CupertinoIcons.exclamationmark_shield_fill
                        : (coreReady
                            ? CupertinoIcons.checkmark_shield_fill
                            : CupertinoIcons.shield_lefthalf_fill),
                    color: needsRetoggle
                        ? t.err
                        : (coreReady ? t.ok : t.primary),
                    size: 44,
                    iconSize: 21,
                    filled: true,
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '已开启 $grantedCount / 6 项系统权限',
                          style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: t.text),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          needsRetoggle
                              ? '检测到无障碍开关已开但系统未绑定服务，请点击下方修复'
                              : '集中管理操控手机、后台保活、文件挂载与语音所需权限',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: needsRetoggle ? t.err : t.text3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (coreReady && !needsRetoggle && perms.batteryOptIgnored) ...[
                    const SizedBox(width: 8),
                    _PermBadge(label: '核心就绪', bg: t.okSoft, fg: t.ok),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              GrassBagProgressBar(
                value: (grantedCount / 6.0).clamp(0.0, 1.0),
                height: 5,
                color: needsRetoggle ? t.err : (coreReady ? t.ok : t.primary),
                trackColor: t.fill1,
              ),
              GrassBagSmoothDisclosure(
                expanded: needsRetoggle || !perms.accessibilityEnabled || !perms.batteryOptIgnored,
                duration: const Duration(milliseconds: 220),
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: AnimatedSwitcher(
                    duration: GrassBagMotion.duration(context, const Duration(milliseconds: 180)),
                    child: needsRetoggle
                        ? GrassBagPrimaryGlassButton(
                            key: const ValueKey('perm-cta-retoggle'),
                            label: '前往修复无障碍服务',
                            icon: CupertinoIcons.wrench_fill,
                            height: 38,
                            tier: tier,
                            insideGlass: true,
                            onTap: () => native.openPermissionSettings('accessibility'),
                          )
                        : !perms.accessibilityEnabled
                            ? GrassBagPrimaryGlassButton(
                                key: const ValueKey('perm-cta-a11y'),
                                label: perms.sdkInt >= 33 ? '开启无障碍（含解锁指南）' : '开启无障碍服务',
                                icon: CupertinoIcons.hand_draw_fill,
                                height: 38,
                                tier: tier,
                                insideGlass: true,
                                onTap: () {
                                  if (perms.sdkInt >= 33) {
                                    _showRestrictedSettingsGuide(context, tier);
                                  } else {
                                    native.openPermissionSettings('accessibility');
                                  }
                                },
                              )
                            : GrassBagSecondaryGlassButton(
                                key: const ValueKey('perm-cta-battery'),
                                label: '开启后台保活（忽略电池优化）',
                                icon: CupertinoIcons.battery_100,
                                height: 38,
                                tier: tier,
                                insideGlass: true,
                                accentForeground: true,
                                onTap: () => native.openPermissionSettings('battery'),
                              ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // 2. Special Diagnostic Card when Android Settings says ON but service is NOT bound!
        GrassBagSmoothDisclosure(
          expanded: needsRetoggle,
          duration: const Duration(milliseconds: 240),
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: GrassBagStatusBanner(
              tone: GrassBagBannerTone.error,
              title: '无障碍服务未绑定 / 系统提示「服务出现故障」',
              message: '覆盖安装更新、应用被后台强杀或 Android 13+ 受限设置会导致系统开关虽开但底层服务连接已断开（设置中常显示「服务出现故障」）。请进入系统无障碍设置先关闭再重新开启「GrassBag 手机操控助手」，并将电池策略设为无限制。',
              padding: const EdgeInsets.all(14),
              borderRadius: 20,
              action: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  GrassBagPrimaryGlassButton(
                    label: '重新开关无障碍',
                    icon: CupertinoIcons.hand_draw_fill,
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tier: tier,
                    insideGlass: true,
                    onTap: () => native.openPermissionSettings('accessibility'),
                  ),
                  GrassBagSecondaryGlassButton(
                    label: '允许受限设置',
                    icon: CupertinoIcons.info_circle,
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tier: tier,
                    insideGlass: true,
                    onTap: () => _showRestrictedSettingsGuide(context, tier),
                  ),
                  if (!perms.batteryOptIgnored)
                    GrassBagSecondaryGlassButton(
                      label: '关闭电池优化',
                      icon: CupertinoIcons.battery_100,
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tier: tier,
                      insideGlass: true,
                      onTap: () => native.openPermissionSettings('battery'),
                    ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 16),

        // 3. Automation & Phone Control Permissions
        GrassBagGroupedSection(
          header: '操控手机与屏幕自动化（核心必需）',
          footer: '开启无障碍服务后，助手可在手机操控安全护栏保护下执行屏幕识别、点击、滑动、输入与打开应用操作。',
          dividerIndent: 58,
          children: [
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.hand_draw_fill,
                color: perms.accessibilityEnabled
                    ? t.ok
                    : (needsRetoggle ? t.err : t.warn),
                size: 34,
                iconSize: 16,
                filled: perms.accessibilityEnabled,
              ),
              title: const Text('无障碍屏幕操控'),
              subtitle: Text(
                perms.accessibilityEnabled
                    ? '服务运行正常 · 可识别屏幕内容并执行点击/滑动/输入'
                    : (needsRetoggle
                        ? '系统开关已开但未绑定，请点此关闭后重新开启'
                        : '核心必需 · 开启后即可让助手代劳操作手机'),
              ),
              trailing: _PermBadge(
                label: perms.accessibilityEnabled
                    ? '运行中'
                    : (needsRetoggle ? '需重开' : '去开启'),
                bg: perms.accessibilityEnabled
                    ? t.okSoft
                    : (needsRetoggle ? t.errSoft : t.warnSoft),
                fg: perms.accessibilityEnabled
                    ? t.ok
                    : (needsRetoggle ? t.err : t.warn),
                actionable: !perms.accessibilityEnabled,
              ),
              onTap: () {
                if (!perms.accessibilityEnabled && !needsRetoggle && perms.sdkInt >= 33) {
                  _showRestrictedSettingsGuide(context, tier);
                } else {
                  native.openPermissionSettings('accessibility');
                }
              },
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.layers_alt_fill,
                color: perms.overlayGranted ? t.ok : t.primary,
                size: 34,
                iconSize: 16,
                filled: perms.overlayGranted,
              ),
              title: const Text('悬浮窗权限（急停浮球）'),
              subtitle: const Text('推荐开启 · 跨应用自动操作时显示悬浮状态与一键急停按钮'),
              trailing: _PermBadge(
                label: perms.overlayGranted ? '已授权' : '去开启',
                bg: perms.overlayGranted ? t.okSoft : t.warnSoft,
                fg: perms.overlayGranted ? t.ok : t.warn,
                actionable: !perms.overlayGranted,
              ),
              onTap: () => native.openPermissionSettings('overlay'),
            ),
            if (perms.sdkInt >= 33 || perms.sdkInt == 0)
              GrassBagListTile(
                leading: GrassBagSquircleIcon(
                  icon: CupertinoIcons.question_circle_fill,
                  color: t.text2,
                  size: 34,
                  iconSize: 16,
                ),
                title: const Text('Android 13+ 受限设置解锁指南'),
                subtitle: const Text('解决无障碍灰显、无法开启或开启后不生效问题'),
                showChevron: true,
                onTap: () => _showRestrictedSettingsGuide(context, tier),
              ),
          ],
        ),

        const SizedBox(height: 16),

        // 4. Background Keepalive & Notifications
        GrassBagGroupedSection(
          header: '后台运行与通知（推荐开启）',
          footer: '忽略电池优化可显著降低切后台或锁屏时 Ubuntu 容器、DSH 引擎与无障碍服务被系统回收的概率。',
          dividerIndent: 58,
          children: [
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.battery_100,
                color: perms.batteryOptIgnored ? t.ok : t.warn,
                size: 34,
                iconSize: 16,
                filled: perms.batteryOptIgnored,
              ),
              title: const Text('忽略电池优化（后台保活）'),
              subtitle: const Text('保持本机 DSH 引擎、长对话与无障碍服务稳定在线'),
              trailing: _PermBadge(
                label: perms.batteryOptIgnored ? '已允许' : '去设置',
                bg: perms.batteryOptIgnored ? t.okSoft : t.warnSoft,
                fg: perms.batteryOptIgnored ? t.ok : t.warn,
                actionable: !perms.batteryOptIgnored,
              ),
              onTap: () => native.openPermissionSettings('battery'),
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.bell_fill,
                color: perms.notificationsGranted ? t.ok : t.primary,
                size: 34,
                iconSize: 16,
                filled: perms.notificationsGranted,
              ),
              title: const Text('通知权限'),
              subtitle: const Text('展示引擎前台保活通知与操作确认提醒'),
              trailing: _PermBadge(
                label: perms.notificationsGranted ? '已授权' : '点击申请',
                bg: perms.notificationsGranted ? t.okSoft : t.primarySoft,
                fg: perms.notificationsGranted ? t.ok : t.primary,
                actionable: !perms.notificationsGranted,
              ),
              onTap: () {
                if (perms.notificationsGranted) {
                  native.openPermissionSettings('notifications');
                } else {
                  unawaited(ctrl.requestRuntimePermission('notifications'));
                }
              },
            ),
          ],
        ),

        const SizedBox(height: 16),

        // 5. Storage & Media Permissions
        GrassBagGroupedSection(
          header: '存储与多媒体（按需开启）',
          dividerIndent: 58,
          children: [
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.folder_fill,
                color: perms.allFilesGranted ? t.ok : t.primary,
                size: 34,
                iconSize: 16,
                filled: perms.allFilesGranted,
              ),
              title: const Text('手机公共存储（下载、文档等）'),
              subtitle: Text(
                perms.sdkInt >= 30
                    ? '允许容器读写手机下载、文档目录及导出加密备份'
                    : '允许访问手机存储空间与读写文件',
              ),
              trailing: _PermBadge(
                label: perms.allFilesGranted ? '已授权' : '去开启',
                bg: perms.allFilesGranted ? t.okSoft : t.fill1,
                fg: perms.allFilesGranted ? t.ok : t.text2,
                actionable: !perms.allFilesGranted,
              ),
              onTap: () {
                if (perms.sdkInt < 30 && !perms.allFilesGranted) {
                  unawaited(ctrl.requestRuntimePermission('storage'));
                } else {
                  native.openPermissionSettings('storage');
                }
              },
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.mic_fill,
                color: perms.microphoneGranted ? t.ok : t.primary,
                size: 34,
                iconSize: 16,
                filled: perms.microphoneGranted,
              ),
              title: const Text('麦克风权限'),
              subtitle: const Text('用于语音输入与语音转写功能'),
              trailing: _PermBadge(
                label: perms.microphoneGranted ? '已授权' : '点击申请',
                bg: perms.microphoneGranted ? t.okSoft : t.fill1,
                fg: perms.microphoneGranted ? t.ok : t.text2,
                actionable: !perms.microphoneGranted,
              ),
              onTap: () {
                if (perms.microphoneGranted) {
                  native.openPermissionSettings('app_details');
                } else {
                  unawaited(ctrl.requestRuntimePermission('microphone'));
                }
              },
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.gear_alt_fill,
                color: t.text2,
                size: 34,
                iconSize: 16,
              ),
              title: const Text('系统应用信息页'),
              subtitle: const Text('进入系统设置管理自启动、省电策略与所有权限'),
              showChevron: true,
              onTap: () => native.openPermissionSettings('app_details'),
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.bolt_circle_fill,
                color: perms.shizukuInstalled ? t.ok : t.text3,
                size: 34,
                iconSize: 16,
              ),
              title: const Text('Shizuku 增强通道（可选）'),
              subtitle: Text(
                perms.shizukuInstalled
                    ? '已检测到 Shizuku（当前版本暂未集成，默认使用无障碍通道）'
                    : '暂未集成 · 当前版本仅需开启无障碍服务即可操控手机',
              ),
              trailing: _PermBadge(
                label: '暂未集成',
                bg: t.fill1,
                fg: t.text3,
              ),
              onTap: () => _showShizukuInfoSheet(context, tier),
            ),
          ],
        ),
      ],
    );
  }
}

class _PermBadge extends StatelessWidget {
  const _PermBadge({
    required this.label,
    required this.bg,
    required this.fg,
    this.actionable = false,
  });

  final String label;
  final Color bg;
  final Color fg;
  final bool actionable;

  @override
  Widget build(BuildContext context) {
    return GrassBagFresnelGlassSurface(
      isPill: true,
      innerWell: true,
      interactive: false,
      tintColor: bg,
      padding: EdgeInsets.only(
        left: 9.5,
        right: actionable ? 7.5 : 9.5,
        top: 4,
        bottom: 4,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg),
          ),
          if (actionable) ...[
            const SizedBox(width: 2),
            Icon(CupertinoIcons.chevron_right, size: 10.5, color: fg.withValues(alpha: 0.85)),
          ],
        ],
      ),
    );
  }
}
