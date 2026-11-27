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

class _FeatureTileSpec {
  const _FeatureTileSpec({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badgeText,
    this.badgeColor,
    this.badgeBg,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? badgeText;
  final Color? badgeColor;
  final Color? badgeBg;
}

class _FeatureSectionSpec {
  const _FeatureSectionSpec({
    required this.title,
    required this.tiles,
  });

  final String title;
  final List<_FeatureTileSpec> tiles;
}

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
          hasLocalUpdates: s.localHost.hasLocalUpdates,
          nativePermissions: s.nativePermissions,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final t = GrassBagTokens.of(context);
    final isWide = MediaQuery.sizeOf(context).width >= 760;
    final navigator = Navigator.of(context);
    final hostNeedsAttention = state.connectionPhase != ConnectionPhase.connected ||
        state.activeHost.needsAuth;
    final hostHasUpdate = !hostNeedsAttention &&
        state.activeHost.isLocal &&
        state.localHost.hasLocalUpdates;
    final phoneReady = state.nativePermissions.accessibilityEnabled &&
        !state.nativePermissions.accessibilityNeedsRetoggle;

    void pushOrCall(VoidCallback? cb, WidgetBuilder builder) {
      if (cb != null) {
        navigator.pop();
        cb();
      } else {
        // Replace cleanly in one route transition (zero overlapping pop + push double-flash!).
        navigator.pushReplacement(GrassBagPageRoute<void>(builder: builder));
      }
    }

    final sections = <_FeatureSectionSpec>[
      _FeatureSectionSpec(
        title: '工作台与会话',
        tiles: [
          _FeatureTileSpec(
            icon: CupertinoIcons.folder_fill,
            color: t.primary,
            title: '对话详情',
            subtitle: '文件、改动、进度与用量',
            badgeText: state.workspaceDiffs.isNotEmpty
                ? '${state.workspaceDiffs.length} 改动'
                : null,
            badgeColor: t.primary,
            badgeBg: t.primarySoft,
            onTap: () {
              navigator.pop();
              onOpenSessionDetail();
            },
          ),
          _FeatureTileSpec(
            icon: CupertinoIcons.chevron_left_slash_chevron_right,
            color: t.isDark ? const Color(0xFF94A3B8) : const Color(0xFF3E5368),
            title: '终端',
            subtitle: '多标签 · 本地与远程命令行',
            onTap: () {
              navigator.pop();
              onOpenTerminal();
            },
          ),
          _FeatureTileSpec(
            icon: CupertinoIcons.arrow_branch,
            color: t.dusk,
            title: '协作子代理',
            subtitle: '并发任务流与实时补充指令',
            badgeText: state.subagents.isNotEmpty ? '${state.subagents.length} 条' : null,
            badgeColor: t.dusk,
            badgeBg: t.dusk.withValues(alpha: t.isDark ? 0.22 : 0.12),
            onTap: () => pushOrCall(onOpenSubagents, (_) => const SubagentsPage()),
          ),
          _FeatureTileSpec(
            icon: CupertinoIcons.globe,
            color: t.isDark ? const Color(0xFF45B9AA) : const Color(0xFF34766F),
            title: '官方网页版',
            subtitle: '一键免密进入完整 Web 端',
            onTap: () {
              navigator.pop();
              onOpenWebUi();
            },
          ),
        ],
      ),
      _FeatureSectionSpec(
        title: '自动化与扩展',
        tiles: [
          _FeatureTileSpec(
            icon: CupertinoIcons.square_stack_3d_up_fill,
            color: t.ok,
            title: '插件与市场',
            subtitle: '市场安装与动态扩展能力',
            badgeText: state.plugins.isNotEmpty ? '${state.plugins.length} 已装' : null,
            badgeColor: t.ok,
            badgeBg: t.okSoft,
            onTap: () => pushOrCall(onOpenPlugins, (_) => const PluginsCenterPage()),
          ),
          _FeatureTileSpec(
            icon: CupertinoIcons.clock_fill,
            color: t.warn,
            title: '定时任务',
            subtitle: '按计划周期自动触发执行',
            badgeText: state.activeScheduleCount > 0
                ? '${state.activeScheduleCount} 启用'
                : null,
            badgeColor: t.warn,
            badgeBg: t.warnSoft,
            onTap: () => pushOrCall(onOpenSchedules, (_) => const SchedulesPage()),
          ),
          _FeatureTileSpec(
            icon: CupertinoIcons.waveform_path_ecg,
            color: t.isDark ? const Color(0xFF34D399) : const Color(0xFF0E9F6E),
            title: '后台任务',
            subtitle: '长耗时命令与实时日志流',
            badgeText: state.runningJobsCount > 0
                ? '${state.runningJobsCount} 运行中'
                : null,
            badgeColor: t.ok,
            badgeBg: t.okSoft,
            onTap: () => pushOrCall(onOpenJobs, (_) => const JobsPage()),
          ),
          _FeatureTileSpec(
            icon: CupertinoIcons.chart_bar_alt_fill,
            color: t.isDark ? const Color(0xFFF472B6) : const Color(0xFFC026D3),
            title: '诊断与扩展',
            subtitle: '动态交互面板与系统诊断',
            badgeText: state.sduiSurfaces.isNotEmpty ? '${state.sduiSurfaces.length} 面板' : null,
            badgeColor: t.isDark ? const Color(0xFFF472B6) : const Color(0xFFC026D3),
            badgeBg: (t.isDark ? const Color(0xFFF472B6) : const Color(0xFFC026D3))
                .withValues(alpha: t.isDark ? 0.20 : 0.11),
            onTap: () => pushOrCall(onOpenSdui, (_) => const SduiExtensionsPage()),
          ),
        ],
      ),
      _FeatureSectionSpec(
        title: '设备与系统',
        tiles: [
          _FeatureTileSpec(
            icon: CupertinoIcons.tray_2_fill,
            color: t.isDark ? const Color(0xFF818CF8) : const Color(0xFF4B67B4),
            title: '主机与环境',
            subtitle: state.activeHost.needsAuth
                ? '待授权 · 点击连接远程设备'
                : (state.connectionPhase != ConnectionPhase.connected
                    ? '未连接 · 检查本机或远程主机'
                    : '本机容器与远程设备管理'),
            badgeText: state.activeHost.needsAuth
                ? '待授权'
                : (hostNeedsAttention
                    ? '未连接'
                    : (hostHasUpdate ? '可更新' : '已连通')),
            badgeColor: hostNeedsAttention
                ? t.warn
                : (hostHasUpdate ? t.primary : t.ok),
            badgeBg: hostNeedsAttention
                ? t.warnSoft
                : (hostHasUpdate ? t.primarySoft : t.okSoft),
            onTap: () {
              navigator.pop();
              onOpenHosts();
            },
          ),
          if (GrassBagNativeBridge.instance.isAndroidNative)
            _FeatureTileSpec(
              icon: CupertinoIcons.device_phone_portrait,
              color: t.isDark ? const Color(0xFF4DA3E8) : const Color(0xFF2B7FC3),
              title: '操控手机',
              subtitle: phoneReady ? '无障碍已就绪 · 安全护栏保护' : '去开启无障碍与安全护栏',
              badgeText: phoneReady ? '已就绪' : '待开启',
              badgeColor: phoneReady ? t.ok : t.warn,
              badgeBg: phoneReady ? t.okSoft : t.warnSoft,
              onTap: () {
                navigator.pop();
                onOpenPhoneControl();
              },
            ),
        ],
      ),
    ];

    final topPad = MediaQuery.viewPaddingOf(context).top;
    final botPad = MediaQuery.viewPaddingOf(context).bottom;
    final textScaleFactor =
        MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.6);
    final cardExtent =
        (isWide ? 124.0 : 122.0) * (1.0 + (textScaleFactor - 1.0) * 0.72);

    return GrassBagGlassPage(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: isWide ? 780 : double.infinity),
                  child: CustomScrollView(
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    slivers: [
                      SliverPadding(padding: EdgeInsets.only(top: topPad + 70)),
                      for (var si = 0; si < sections.length; si++) ...[
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(20, si == 0 ? 4 : 18, 20, 8),
                          sliver: SliverToBoxAdapter(
                            child: Text(
                              sections[si].title,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.1,
                                color: t.text2,
                              ),
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverGrid(
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: isWide ? 4 : 2,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                              mainAxisExtent: cardExtent,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (_, i) => _FeatureGridCard(spec: sections[si].tiles[i]),
                              childCount: sections[si].tiles.length,
                            ),
                          ),
                        ),
                      ],
                      SliverPadding(padding: EdgeInsets.only(bottom: botPad + 28)),
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

class _FeatureGridCard extends StatelessWidget {
  const _FeatureGridCard({required this.spec});

  final _FeatureTileSpec spec;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.6,
      child: GrassBagSpringTap(
        pressedScale: 0.96,
        borderRadius: 23,
        haptic: true,
        onTap: spec.onTap,
        child: GrassBagCard(
        borderRadius: 23,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GrassBagSquircleIcon(
                  icon: spec.icon,
                  color: spec.color,
                  size: 36,
                  iconSize: 17,
                ),
                if (spec.badgeText != null && spec.badgeText!.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: GrassBagFresnelGlassSurface(
                      isPill: true,
                      innerWell: true,
                      tintColor: spec.badgeBg ?? t.fill1,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
                      child: Text(
                        spec.badgeText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: spec.badgeColor ?? t.text2,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  spec.title,
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
                  spec.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, height: 1.28, color: t.text3),
                ),
              ],
            ),
          ],
        ),
      ),
      ),
    );
  }
}
