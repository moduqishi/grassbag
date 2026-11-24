import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import 'jobs_page.dart';
import 'plugins_center_page.dart';
import 'schedules_page.dart';
import 'sdui_extensions_page.dart';
import 'subagents_page.dart';

class AllFeaturesPage extends ConsumerWidget {
  const AllFeaturesPage({
    super.key,
    required this.onOpenTerminal,
    required this.onOpenSessionDetail,
    required this.onOpenHosts,
    required this.onOpenPlugins,
    required this.onOpenPhoneControl,
    required this.onOpenWebUi,
    this.onOpenSubagents,
    this.onOpenSchedules,
    this.onOpenJobs,
    this.onOpenSdui,
  });

  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenSessionDetail;
  final VoidCallback onOpenHosts;
  final VoidCallback onOpenPlugins;
  final VoidCallback onOpenPhoneControl;
  final VoidCallback onOpenWebUi;
  final VoidCallback? onOpenSubagents;
  final VoidCallback? onOpenSchedules;
  final VoidCallback? onOpenJobs;
  final VoidCallback? onOpenSdui;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          hostsCount: s.hosts.length,
          pluginsCount: s.plugins.length,
          subagentsCount: s.subagents.length,
          schedulesCount: s.schedules.length,
          activeScheduleCount: s.activeScheduleCount,
          jobsCount: s.jobs.length,
          runningJobsCount: s.runningJobsCount,
          sduiCount: s.sduiSurfaces.length,
          workspaceDiffsCount: s.workspaceDiffs.length,
          connectionPhase: s.connectionPhase,
          activeHost: s.activeHost,
          nativePermissions: s.nativePermissions,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final t = GrassBagTokens.of(context);
    final isWide = MediaQuery.sizeOf(context).width >= 760;
    final navigator = Navigator.of(context);
    final hostNeedsAttention = state.connectionPhase != ConnectionPhase.connected ||
        state.activeHost.needsAuth ||
        state.localHost.hasLocalUpdates;
    final phoneNeedsAttention = GrassBagNativeBridge.instance.isAndroidNative &&
        (!state.nativePermissions.accessibilityEnabled ||
            state.nativePermissions.accessibilityNeedsRetoggle);

    void pushOrCall(VoidCallback? cb, WidgetBuilder builder) {
      navigator.pop();
      if (cb != null) {
        cb();
      } else {
        navigator.push(GrassBagPageRoute<void>(builder: builder));
      }
    }

    final tiles = [
      (
        CupertinoIcons.chevron_left_slash_chevron_right,
        t.isDark ? const Color(0xFF94A3B8) : const Color(0xFF3E5368),
        '终端',
        '多标签 · 本地与远程命令行',
        () {
          navigator.pop();
          onOpenTerminal();
        },
        false,
      ),
      (
        CupertinoIcons.folder_fill,
        t.primary,
        '对话详情',
        '文件、改动、进度与用量',
        () {
          navigator.pop();
          onOpenSessionDetail();
        },
        false,
      ),
      (
        CupertinoIcons.tray_2_fill,
        t.isDark ? const Color(0xFF818CF8) : const Color(0xFF4B67B4),
        '主机与环境',
        state.activeHost.needsAuth
            ? '待授权 · 点击连接远程设备'
            : (state.connectionPhase != ConnectionPhase.connected
                ? '未连接 · 检查本机或远程主机'
                : '本机容器与远程设备管理'),
        () {
          navigator.pop();
          onOpenHosts();
        },
        hostNeedsAttention,
      ),
      (
        CupertinoIcons.arrow_branch,
        t.dusk,
        '协作子代理',
        '${state.subagents.length} 条协作任务 · 补充指令',
        () => pushOrCall(onOpenSubagents, (_) => const SubagentsPage()),
        false,
      ),
      (
        CupertinoIcons.square_stack_3d_up_fill,
        t.ok,
        '插件与市场',
        '${state.plugins.length} 已装 · 市场与动态扩展',
        () => pushOrCall(onOpenPlugins, (_) => const PluginsCenterPage()),
        false,
      ),
      (
        CupertinoIcons.clock_fill,
        t.warn,
        '定时任务',
        '${state.activeScheduleCount} 项启用 · 按计划自动执行',
        () => pushOrCall(onOpenSchedules, (_) => const SchedulesPage()),
        false,
      ),
      (
        CupertinoIcons.waveform_path_ecg,
        t.isDark ? const Color(0xFF34D399) : const Color(0xFF0E9F6E),
        '后台任务',
        '${state.runningJobsCount} 项运行中 · 实时日志',
        () => pushOrCall(onOpenJobs, (_) => const JobsPage()),
        false,
      ),
      (
        CupertinoIcons.chart_bar_alt_fill,
        t.isDark ? const Color(0xFFF472B6) : const Color(0xFFC026D3),
        '诊断与扩展',
        '${state.sduiSurfaces.length} 个动态扩展面板',
        () => pushOrCall(onOpenSdui, (_) => const SduiExtensionsPage()),
        false,
      ),
      if (GrassBagNativeBridge.instance.isAndroidNative)
        (
          CupertinoIcons.device_phone_portrait,
          t.isDark ? const Color(0xFF4DA3E8) : const Color(0xFF2B7FC3),
          '操控手机',
          state.nativePermissions.accessibilityEnabled
              ? '无障碍可用 · 安全护栏保护'
              : '去开启无障碍与安全护栏',
          () {
            navigator.pop();
            onOpenPhoneControl();
          },
          phoneNeedsAttention,
        ),
      (
        CupertinoIcons.globe,
        t.isDark ? const Color(0xFF45B9AA) : const Color(0xFF34766F),
        '官方网页版',
        '一键免密进入完整 Web 端',
        () {
          navigator.pop();
          onOpenWebUi();
        },
        false,
      ),
    ];

    final topPad = MediaQuery.viewPaddingOf(context).top;
    final botPad = MediaQuery.viewPaddingOf(context).bottom;
    return GrassBagGlassPage(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: isWide ? 780 : double.infinity),
                  child: GridView.builder(
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    padding: EdgeInsets.fromLTRB(16, topPad + 72, 16, botPad + 28),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: isWide ? 4 : 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      mainAxisExtent: isWide ? 132 : 128,
                    ),
                    itemCount: tiles.length,
                    itemBuilder: (_, i) {
                      final item = tiles[i];
                      final showDot = item.$6;
                      return GrassBagSpringTap(
                        pressedScale: 0.955,
                        haptic: true,
                        onTap: item.$5,
                        child: GrassBagCard(
                          borderRadius: 24,
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  GrassBagSquircleIcon(
                                    icon: item.$1,
                                    color: item.$2,
                                    size: 38,
                                    iconSize: 18,
                                  ),
                                  if (showDot)
                                    Container(
                                      width: 8,
                                      height: 8,
                                      margin: const EdgeInsets.only(top: 2, right: 2),
                                      decoration: BoxDecoration(
                                        color: t.warn,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                ],
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.$3,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: -0.2,
                                      color: t.text,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    item.$4,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 11.5, color: t.text3),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GrassBagUnifiedHeader(
                title: '全部功能',
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
