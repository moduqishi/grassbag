import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';

class _JobListSig {
  const _JobListSig(this.jobs);
  final List<BackgroundJobRecord> jobs;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _JobListSig || other.jobs.length != jobs.length) return false;
    for (var i = 0; i < jobs.length; i++) {
      if (jobs[i].id != other.jobs[i].id || jobs[i].status != other.jobs[i].status) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => jobs.length;
}

class JobsPage extends ConsumerStatefulWidget {
  const JobsPage({super.key});

  @override
  ConsumerState<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends ConsumerState<JobsPage> {
  final Set<String> _expandedIds = {};
  final Set<String> _collapsedIds = {};
  final Map<String, String?> _subscribedJobs = {};
  late final GrassBagController _ctrl;
  bool _initialLoading = false;

  @override
  void initState() {
    super.initState();
    _ctrl = ref.read(appProvider.notifier);
    if (ref.read(appProvider).jobs.isEmpty &&
        ref.read(appProvider).connectionPhase == ConnectionPhase.connected) {
      _initialLoading = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await _ctrl.refreshJobs(silent: true);
      } finally {
        if (mounted && _initialLoading) setState(() => _initialLoading = false);
      }
      if (mounted) _reconcileRunningSubscriptions(ref.read(appProvider).jobs);
    });
  }

  @override
  void dispose() {
    for (final entry in _subscribedJobs.entries) {
      _ctrl.unsubscribeJobStream(entry.key, sessionId: entry.value);
    }
    _subscribedJobs.clear();
    super.dispose();
  }

  void _reconcileRunningSubscriptions(List<BackgroundJobRecord> jobs) {
    final running = jobs
        .where((j) => j.status.toLowerCase() == 'running')
        .toList(growable: false);
    final runningIds = <String>{};
    for (final job in running) {
      runningIds.add(job.id);
      final isExp = _expandedIds.contains(job.id) ||
          (running.length == 1 && !_collapsedIds.contains(job.id));
      _syncJobSubscription(job, isExp);
    }
    final staleIds = _subscribedJobs.keys.where((id) => !runningIds.contains(id)).toList();
    for (final id in staleIds) {
      final sid = _subscribedJobs.remove(id);
      _ctrl.unsubscribeJobStream(id, sessionId: sid);
    }
  }

  void _syncJobSubscription(BackgroundJobRecord job, bool expanded) {
    if (expanded && job.status.toLowerCase() == 'running') {
      if (!_subscribedJobs.containsKey(job.id)) {
        _subscribedJobs[job.id] = job.sessionId;
        _ctrl.subscribeJobStream(job.id, sessionId: job.sessionId);
      }
    } else if (_subscribedJobs.containsKey(job.id)) {
      final sid = _subscribedJobs.remove(job.id);
      _ctrl.unsubscribeJobStream(job.id, sessionId: sid);
    }
  }

  void _openLaunchSheet(BuildContext context) {
    var hasDraft = false;
    showGrassBagSheet<void>(
      context,
      title: '启动后台命令',
      subtitle: '在当前工作区常驻执行并实时收集标准输出',
      onWillDismiss: () async {
        if (!hasDraft || !context.mounted) return true;
        return showGrassBagConfirmDialog(
          context,
          title: '放弃已输入的命令？',
          message: '关闭后当前命令行输入内容将不会保留。',
          confirmLabel: '放弃并关闭',
          isDestructive: true,
        );
      },
      bodyBuilder: (sheetCtx) => _LaunchJobSheetBody(
        onDraftChanged: (dirty) => hasDraft = dirty,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(appProvider.select((s) => s.activeHostId), (prev, next) {
      if (prev != null && prev != next && mounted) {
        for (final entry in _subscribedJobs.entries) {
          _ctrl.unsubscribeJobStream(entry.key, sessionId: entry.value);
        }
        _subscribedJobs.clear();
        _expandedIds.clear();
        _collapsedIds.clear();
        unawaited(_ctrl.refreshJobs(silent: true));
      }
    });
    ref.listen<ConnectionPhase>(appProvider.select((s) => s.connectionPhase), (prev, next) {
      if (prev != ConnectionPhase.connected && next == ConnectionPhase.connected && mounted) {
        // After a reconnect the underlying client changed, so clear stale subscription
        // tracking and re-subscribe all visible running jobs on the new connection.
        _subscribedJobs.clear();
        unawaited(_ctrl.refreshJobs(silent: true).then((_) {
          if (mounted) _reconcileRunningSubscriptions(ref.read(appProvider).jobs);
        }));
      }
    });
    ref.listen<List<BackgroundJobRecord>>(appProvider.select((s) => s.jobs), (prev, next) {
      if (mounted) _reconcileRunningSubscriptions(next);
    });
    // Watch ONLY job IDs & statuses via zero-allocation value equality so high-frequency
    // `outputLines` appends NEVER allocate strings or rebuild sibling job cards!
    ref.watch(
      appProvider.select(
        (s) => (
          jobSig: _JobListSig(s.jobs),
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

    final running = state.jobs
        .where((j) => j.status.toLowerCase() == 'running')
        .toList(growable: false);
    final finished = state.jobs
        .where((j) => j.status.toLowerCase() != 'running')
        .toList(growable: false);

    return GrassBagGlassPage(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: isWide ? 720 : double.infinity),
                  child: RefreshIndicator.adaptive(
                    edgeOffset: topPad + 74,
                    onRefresh: () => ctrl.refreshJobs(
                      silent: state.connectionPhase == ConnectionPhase.connected,
                    ),
                    child: CustomScrollView(
                      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                      slivers: [
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(16, topPad + 76, 16, 40 + botPad),
                          sliver: SliverMainAxisGroup(
                            slivers: [
                              if (state.connectionPhase != ConnectionPhase.connected)
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: GrassBagStatusBanner(
                                      tone: GrassBagBannerTone.warn,
                                      icon: CupertinoIcons.wifi_exclamationmark,
                                      title: '未连接到 DSH 主机',
                                      message: '后台任务运行在已连接的 DSH 主机上，恢复连接后自动同步日志与进程状态。',
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
                                  ),
                                ),
                              if (running.isNotEmpty) ...[
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: _SectionLabel('运行中 (${running.length})'),
                                  ),
                                ),
                                SliverList.builder(
                                  itemCount: running.length,
                                  itemBuilder: (_, idx) {
                                    final job = running[idx];
                                    final isExp = _expandedIds.contains(job.id) ||
                                        (running.length == 1 && !_collapsedIds.contains(job.id));
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 12),
                                      child: _IsolatedJobCard(
                                        key: ValueKey('job-${job.id}'),
                                        jobId: job.id,
                                        expanded: isExp,
                                        onToggle: () {
                                          final nextExp = !isExp;
                                          setState(() {
                                            if (nextExp) {
                                              _expandedIds.add(job.id);
                                              _collapsedIds.remove(job.id);
                                            } else {
                                              _expandedIds.remove(job.id);
                                              _collapsedIds.add(job.id);
                                            }
                                          });
                                          _syncJobSubscription(job, nextExp);
                                        },
                                        onKill: (liveJob) async {
                                          final ok = await showGrassBagConfirmDialog(
                                            context,
                                            title: '终止后台任务',
                                            message: '确定强制终止「${liveJob.command}」吗？',
                                            confirmLabel: '确认终止',
                                            isDestructive: true,
                                          );
                                          if (ok) {
                                            unawaited(ctrl.killJob(liveJob.id));
                                          }
                                        },
                                      ),
                                    );
                                  },
                                ),
                              ],
                              if (finished.isNotEmpty) ...[
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                                    child: _SectionLabel('已完成 / 已终止 (${finished.length})'),
                                  ),
                                ),
                                SliverList.builder(
                                  itemCount: finished.length,
                                  itemBuilder: (_, idx) {
                                    final job = finished[idx];
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 12),
                                      child: _IsolatedJobCard(
                                        key: ValueKey('job-${job.id}'),
                                        jobId: job.id,
                                        expanded: _expandedIds.contains(job.id),
                                        onToggle: () => setState(() {
                                          if (!_expandedIds.add(job.id)) _expandedIds.remove(job.id);
                                        }),
                                        onKill: null,
                                      ),
                                    );
                                  },
                                ),
                              ],
                              if (state.jobs.isEmpty && _initialLoading)
                                SliverToBoxAdapter(
                                  child: GrassBagCard(
                                    padding: const EdgeInsets.symmetric(vertical: 34),
                                    child: Center(
                                      child: GrassBagActivityIndicator(radius: 11, color: t.primary),
                                    ),
                                  ),
                                )
                              else if (state.jobs.isEmpty)
                                SliverToBoxAdapter(
                                  child: GrassBagCard(
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
                                    child: Column(
                                      children: [
                                        Icon(CupertinoIcons.bolt_horizontal_circle, size: 32, color: t.text3),
                                        const SizedBox(height: 10),
                                        Text('暂无后台任务', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text2)),
                                        const SizedBox(height: 4),
                                        Text(
                                          '适合持续监听日志、运行开发服务器或长耗时测试任务',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(fontSize: 12, color: t.text3),
                                        ),
                                        const SizedBox(height: 14),
                                        Wrap(
                                          spacing: 10,
                                          runSpacing: 8,
                                          alignment: WrapAlignment.center,
                                          children: [
                                            GrassBagPrimaryGlassButton(
                                              label: '启动一条后台命令',
                                              icon: CupertinoIcons.play_fill,
                                              tier: state.glassTier,
                                              insideGlass: true,
                                              height: 38,
                                              onTap: () => _openLaunchSheet(context),
                                            ),
                                            GrassBagSecondaryGlassButton(
                                              label: '刷新任务',
                                              icon: CupertinoIcons.refresh,
                                              tier: state.glassTier,
                                              insideGlass: true,
                                              height: 38,
                                              onTap: () => unawaited(ctrl.refreshJobs()),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
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
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GrassBagUnifiedHeader(
                title: '后台任务',
                subtitle: '${running.length} 项运行中',
                tier: state.glassTier,
                onBack: () => Navigator.of(context).pop(),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GrassBagGlassCircleButton(
                      icon: CupertinoIcons.refresh,
                      tooltip: '刷新后台任务',
                      tier: state.glassTier,
                      useOwnLayer: false,
                      onTap: () => unawaited(ctrl.refreshJobs()),
                    ),
                    const SizedBox(width: 8),
                    GrassBagGlassCircleButton(
                      icon: CupertinoIcons.add,
                      tooltip: '启动后台命令',
                      tier: state.glassTier,
                      useOwnLayer: false,
                      onTap: () => _openLaunchSheet(context),
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
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text3),
      ),
    );
  }
}

class _IsolatedJobCard extends ConsumerWidget {
  const _IsolatedJobCard({
    super.key,
    required this.jobId,
    required this.expanded,
    required this.onToggle,
    required this.onKill,
  });

  final String jobId;
  final bool expanded;
  final VoidCallback onToggle;
  final Future<void> Function(BackgroundJobRecord job)? onKill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = ref.watch(
      appProvider.select(
        (s) => s.jobs.where((j) => j.id == jobId).firstOrNull,
      ),
    );
    if (job == null) return const SizedBox.shrink();
    return RepaintBoundary(
      child: _JobCard(
        job: job,
        expanded: expanded,
        onToggle: onToggle,
        onKill: onKill == null ? null : () => onKill!(job),
      ),
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({
    required this.job,
    required this.expanded,
    required this.onToggle,
    required this.onKill,
  });

  final BackgroundJobRecord job;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback? onKill;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final st = job.status.toLowerCase();
    final isRunning = st == 'running';
    final isFailed = st == 'failed' || st == 'error';
    final isKilled = st == 'killed' || st == 'cancelled' || st == 'terminated';
    final badgeColor = isRunning
        ? t.ok
        : (isFailed || isKilled ? t.err : t.text3);
    final badgeLabel = isRunning
        ? '运行中'
        : (isFailed ? '失败' : (isKilled ? '已终止' : '已完成'));
    final metaLine = [
      if (job.cwd.isNotEmpty) job.cwd,
      if (job.startedAtLabel.isNotEmpty) job.startedAtLabel,
    ].join(' · ');

    return GrassBagCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GrassBagSquircleIcon(
                icon: isRunning
                    ? CupertinoIcons.waveform_path_ecg
                    : (isFailed || isKilled
                        ? CupertinoIcons.exclamationmark_triangle_fill
                        : CupertinoIcons.checkmark_alt),
                color: badgeColor,
                size: 34,
                iconSize: 16,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.command,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        color: t.text,
                      ),
                    ),
                    if (metaLine.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        metaLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: t.text3),
                      ),
                    ],
                  ],
                ),
              ),
              GrassBagFresnelGlassSurface(
                isPill: true,
                innerWell: true,
                tintColor: badgeColor.withValues(alpha: t.isDark ? 0.22 : 0.12),
                padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 3),
                child: Text(
                  badgeLabel,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: badgeColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              GrassBagSpringTap(
                onTap: onToggle,
                enablePointerGlow: false,
                haptic: true,
                child: GrassBagFresnelGlassSurface(
                  isPill: true,
                  innerWell: true,
                  interactive: true,
                  padding: const EdgeInsets.symmetric(horizontal: 10.5, vertical: 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        expanded ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down,
                        size: 12,
                        color: t.text2,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        expanded
                            ? '收起日志'
                            : (isRunning
                                ? '实时输出 (${job.outputLines.length} 行)'
                                : '查看日志 (${job.outputLines.length} 行)'),
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.text2),
                      ),
                    ],
                  ),
                ),
              ),
              if (expanded && job.outputLines.isNotEmpty)
                GrassBagSpringTap(
                  enablePointerGlow: false,
                  haptic: true,
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: job.outputLines.join('\n')));
                    ProviderScope.containerOf(context, listen: false)
                        .read(appProvider.notifier)
                        .showToast('已复制任务日志到剪贴板', tone: ToastTone.ok);
                  },
                  child: GrassBagFresnelGlassSurface(
                    isPill: true,
                    innerWell: true,
                    interactive: true,
                    tintColor: t.primarySoft,
                    padding: const EdgeInsets.symmetric(horizontal: 10.5, vertical: 5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.doc_on_doc, size: 11.5, color: t.primary),
                        const SizedBox(width: 4),
                        Text(
                          '复制日志',
                          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.primary),
                        ),
                      ],
                    ),
                  ),
                ),
              if (onKill != null)
                GrassBagSpringTap(
                  onTap: onKill!,
                  enablePointerGlow: false,
                  haptic: true,
                  child: GrassBagFresnelGlassSurface(
                    isPill: true,
                    innerWell: true,
                    interactive: true,
                    tintColor: t.errSoft,
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.stop_fill, size: 11, color: t.err),
                        const SizedBox(width: 4),
                        Text(
                          '终止进程',
                          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.err),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          GrassBagSmoothDisclosure(
            expanded: expanded,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _JobLogConsole(lines: job.outputLines),
            ),
          ),
        ],
      ),
    );
  }
}

class _JobLogConsole extends StatefulWidget {
  const _JobLogConsole({required this.lines});
  final List<String> lines;

  @override
  State<_JobLogConsole> createState() => _JobLogConsoleState();
}

class _JobLogConsoleState extends State<_JobLogConsole> {
  final ScrollController _ctrl = ScrollController();
  bool _scrolledUp = false;
  bool _programmaticJump = false;
  double _lastObservedPixels = 0.0;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToTailIfNearBottom(force: true));
  }

  void _onScroll() {
    if (!mounted || !_ctrl.hasClients || _programmaticJump) return;
    final pos = _ctrl.position;
    if ((pos.pixels - _lastObservedPixels).abs() < 0.5) return;
    _lastObservedPixels = pos.pixels;
    final away = (pos.maxScrollExtent - pos.pixels) > 56.0;
    if (away != _scrolledUp) setState(() => _scrolledUp = away);
  }

  @override
  void didUpdateWidget(covariant _JobLogConsole oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToTailIfNearBottom(force: false));
    }
  }

  void _jumpToTailIfNearBottom({required bool force}) {
    if (!mounted || !_ctrl.hasClients) return;
    final pos = _ctrl.position;
    if (force || !_scrolledUp) {
      _programmaticJump = true;
      try {
        _ctrl.jumpTo(pos.maxScrollExtent);
        _lastObservedPixels = _ctrl.position.pixels;
      } finally {
        _programmaticJump = false;
      }
      if (_scrolledUp) setState(() => _scrolledUp = false);
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onScroll);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    const maxTailLines = 500;
    final total = widget.lines.length;
    final tailOffset = total > maxTailLines ? total - maxTailLines : 0;
    final visibleCount = total - tailOffset;
    final viewportHeight =
        visibleCount == 0 ? 44.0 : (visibleCount * 17.5 + 24.0 + (tailOffset > 0 ? 22.0 : 0.0)).clamp(64.0, 260.0);
    final logTier = resolveAmbientGlassTier(context);
    final logSolid = logTier == GrassBagGlassTier.solid;
    final logBox = ClipRSuperellipse(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        height: viewportHeight,
        padding: const EdgeInsets.all(11),
        decoration: ShapeDecoration(
          color: t.codeBg,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(14),
            side: logSolid
                ? BorderSide(
                    color: t.isDark ? Colors.white.withValues(alpha: 0.08) : t.sep,
                    width: 0.65,
                  )
                : BorderSide.none,
          ),
        ),
        child: visibleCount == 0
            ? Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '（等待输出…）',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.48,
                    fontFamily: 'monospace',
                    color: t.text3,
                  ),
                ),
              )
            : Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (tailOffset > 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            '… 已省略早期 $tailOffset 行，仅展示最新 $maxTailLines 行（复制可获取完整日志）',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: t.text3,
                            ),
                          ),
                        ),
                      Expanded(
                        child: RepaintBoundary(
                          child: SelectionArea(
                            contextMenuBuilder: buildGrassBagSelectableContextMenu,
                            child: ListView.builder(
                              controller: _ctrl,
                              addAutomaticKeepAlives: false,
                              itemCount: visibleCount,
                              itemBuilder: (_, idx) => Text(
                                widget.lines[tailOffset + idx],
                                style: TextStyle(
                                  fontSize: 11.5,
                                  height: 1.48,
                                  fontFamily: 'monospace',
                                  color: t.codeFg,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    right: 2,
                    bottom: 2,
                    child: AnimatedScale(
                      scale: _scrolledUp ? 1.0 : 0.85,
                      duration: GrassBagMotion.duration(context, const Duration(milliseconds: 170)),
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: _scrolledUp ? 1.0 : 0.0,
                        duration: GrassBagMotion.duration(context, const Duration(milliseconds: 160)),
                        child: IgnorePointer(
                          ignoring: !_scrolledUp,
                          child: GrassBagPrimaryGlassButton(
                            label: '最新输出',
                            icon: CupertinoIcons.arrow_down,
                            height: 36,
                            padding: const EdgeInsets.symmetric(horizontal: 11),
                            tier: logTier,
                            insideGlass: true,
                            onTap: () {
                              if (!_ctrl.hasClients) return;
                              if (MediaQuery.disableAnimationsOf(context)) {
                                _jumpToTailIfNearBottom(force: true);
                              } else {
                                if (_scrolledUp) setState(() => _scrolledUp = false);
                                _ctrl.animateTo(
                                  _ctrl.position.maxScrollExtent,
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOutCubic,
                                );
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
    if (logSolid) return logBox;
    return CustomPaint(
      foregroundPainter: GrassBagFresnelRimPainter(
        isDark: t.isDark,
        borderRadius: 14,
        accent: t.isDark ? t.primaryHi : null,
        innerWell: true,
        frosted: logTier == GrassBagGlassTier.frosted,
        paintTopSheen: false,
        strokeWidth: 0.8,
      ),
      child: logBox,
    );
  }
}

class _LaunchJobSheetBody extends ConsumerStatefulWidget {
  const _LaunchJobSheetBody({this.onDraftChanged});
  final ValueChanged<bool>? onDraftChanged;

  @override
  ConsumerState<_LaunchJobSheetBody> createState() => _LaunchJobSheetBodyState();
}

class _LaunchJobSheetBodyState extends ConsumerState<_LaunchJobSheetBody> {
  static const _quickCmds = <(String, String)>[
    ('持续运行测试', 'npm run test -- --watch'),
    ('代码静态检查', 'flutter analyze'),
    ('查看 Git 状态', 'git status -sb'),
    ('跟踪服务日志', 'tail -f logs/server.log'),
  ];

  final _cmdCtrl = TextEditingController();
  String? _err;
  bool _submitting = false;

  void _syncDraft() {
    widget.onDraftChanged?.call(_cmdCtrl.text.trim().isNotEmpty);
  }

  @override
  void dispose() {
    _cmdCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final text = _cmdCtrl.text.trim();
    if (text.isEmpty) {
      setState(() => _err = '请输入要在后台运行的命令');
      return;
    }
    if (ref.read(appProvider).connectionPhase != ConnectionPhase.connected) {
      setState(() => _err = '当前未连接到 DSH 主机，请先恢复连接后再启动');
      return;
    }
    setState(() {
      _submitting = true;
      _err = null;
    });
    try {
      final err = await ref.read(appProvider.notifier).launchQuickJob(text);
      if (!mounted) return;
      if (err == null) {
        widget.onDraftChanged?.call(false);
        Navigator.of(context).pop();
      } else {
        setState(() => _err = err);
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final watched = ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          activeWorkspace: s.activeWorkspace,
          activeWorkspaceDisplayName: s.activeWorkspaceDisplayName,
          workspaces: s.workspaces,
        ),
      ),
    );
    final tier = watched.glassTier;
    final matchedWs = watched.workspaces
        .where((w) => w.id == watched.activeWorkspace || w.path == watched.activeWorkspace || w.name == watched.activeWorkspace)
        .firstOrNull;
    final displayCwd = matchedWs?.path.isNotEmpty == true
        ? matchedWs!.path
        : (watched.activeWorkspaceDisplayName.isNotEmpty
            ? watched.activeWorkspaceDisplayName
            : '默认工作目录');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagFresnelGlassSurface(
          borderRadius: 12,
          innerWell: true,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Row(
            children: [
              Icon(CupertinoIcons.folder, size: 13, color: t.text3),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '执行目录：$displayCwd',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: t.text2),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GrassBagTextField(
          controller: _cmdCtrl,
          autofocus: true,
          insideGlass: true,
          monospace: true,
          textInputAction: TextInputAction.done,
          hasError: _err != null,
          onChanged: (_) {
            _syncDraft();
            if (_err != null) setState(() => _err = null);
          },
          onSubmitted: (_) => _submit(),
          placeholder: '输入要在后台运行的命令行…',
          fontSize: 13.5,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        if (_err != null) ...[
          const SizedBox(height: 6),
          Text(_err!, style: TextStyle(fontSize: 12, color: t.err)),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final pair in _quickCmds)
              GrassBagSpringTap(
                enablePointerGlow: false,
                haptic: true,
                onTap: () {
                  _cmdCtrl.text = pair.$2;
                  _syncDraft();
                  if (_err != null) setState(() => _err = null);
                },
                child: GrassBagFresnelGlassSurface(
                  isPill: true,
                  innerWell: true,
                  interactive: true,
                  padding: const EdgeInsets.symmetric(horizontal: 10.5, vertical: 6),
                  child: Text(
                    '${pair.$1} · ${pair.$2}',
                    style: TextStyle(fontSize: 11.5, color: t.text2),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '取消',
                tier: tier,
                insideGlass: true,
                enabled: !_submitting,
                onTap: _submitting ? null : () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: _submitting ? '正在启动…' : '后台启动',
                tier: tier,
                insideGlass: true,
                enabled: !_submitting,
                onTap: _submitting ? null : _submit,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
