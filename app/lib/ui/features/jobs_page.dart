import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';

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

  @override
  void initState() {
    super.initState();
    _ctrl = ref.read(appProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_ctrl.refreshJobs(silent: true));
      _reconcileRunningSubscriptions(ref.read(appProvider).jobs);
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
    final running = jobs.where((j) => j.status == 'running').toList(growable: false);
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
    if (expanded && job.status == 'running') {
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
    showGrassBagSheet<void>(
      context,
      title: '启动后台命令',
      subtitle: '在当前工作区常驻执行并实时收集标准输出',
      bodyBuilder: (sheetCtx) => const _LaunchJobSheetBody(),
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
    ref.listen<List<BackgroundJobRecord>>(appProvider.select((s) => s.jobs), (prev, next) {
      if (mounted) _reconcileRunningSubscriptions(next);
    });
    // Watch ONLY job IDs & statuses at page root so high-frequency `outputLines` appends
    // in one running job NEVER rebuild sibling job cards or the page header!
    ref.watch(
      appProvider.select(
        (s) => (
          jobSig: s.jobs.map((j) => '${j.id}:${j.status}').join('|'),
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
                  child: ListView(
                    physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                    padding: EdgeInsets.fromLTRB(16, topPad + 72, 16, 40 + botPad),
                    children: [
                      if (state.connectionPhase != ConnectionPhase.connected) ...[
                        GrassBagStatusBanner(
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
                        const SizedBox(height: 12),
                      ],
                      if (running.isNotEmpty) ...[
                        _SectionLabel('运行中 (${running.length})'),
                        const SizedBox(height: 8),
                        for (final job in running) ...[
                          Builder(
                            builder: (_) {
                              final isExp = _expandedIds.contains(job.id) ||
                                  (running.length == 1 && !_collapsedIds.contains(job.id));
                              return _IsolatedJobCard(
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
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                        ],
                      ],
                      if (finished.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        _SectionLabel('已完成 / 已终止 (${finished.length})'),
                        const SizedBox(height: 8),
                        for (final job in finished) ...[
                          _IsolatedJobCard(
                            key: ValueKey('job-${job.id}'),
                            jobId: job.id,
                            expanded: _expandedIds.contains(job.id),
                            onToggle: () => setState(() {
                              if (!_expandedIds.add(job.id)) _expandedIds.remove(job.id);
                            }),
                            onKill: null,
                          ),
                          const SizedBox(height: 12),
                        ],
                      ],
                      if (state.jobs.isEmpty)
                        GrassBagCard(
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: t.isDark ? 0.22 : 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badgeLabel,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: badgeColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              GrassBagSpringTap(
                onTap: onToggle,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: t.fill1,
                    borderRadius: BorderRadius.circular(999),
                  ),
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
                        expanded ? '收起日志' : '实时输出 (${job.outputLines.length} 行)',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.text2),
                      ),
                    ],
                  ),
                ),
              ),
              if (expanded && job.outputLines.isNotEmpty) ...[
                const SizedBox(width: 6),
                GrassBagSpringTap(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: job.outputLines.join('\n')));
                    ProviderScope.containerOf(context, listen: false)
                        .read(appProvider.notifier)
                        .showToast('已复制任务日志到剪贴板', tone: ToastTone.ok);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: t.primarySoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
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
              ],
              const Spacer(),
              if (onKill != null)
                GrassBagSpringTap(
                  onTap: onKill!,
                  haptic: true,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                    decoration: BoxDecoration(
                      color: t.errSoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
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
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _JobLogConsole(lines: job.outputLines),
                  )
                : const SizedBox.shrink(),
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToTailIfNearBottom(force: true));
  }

  @override
  void didUpdateWidget(covariant _JobLogConsole oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lines.length != widget.lines.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToTailIfNearBottom(force: false));
    }
  }

  void _jumpToTailIfNearBottom({required bool force}) {
    if (!mounted || !_ctrl.hasClients) return;
    final pos = _ctrl.position;
    if (force || (pos.maxScrollExtent - pos.pixels) <= 48.0) {
      _ctrl.jumpTo(pos.maxScrollExtent);
    }
  }

  @override
  void dispose() {
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
        visibleCount == 0 ? 44.0 : (visibleCount * 17.5 + 24.0).clamp(64.0, 260.0);
    return ClipRSuperellipse(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        height: viewportHeight,
        padding: const EdgeInsets.all(11),
        decoration: ShapeDecoration(
          color: t.codeBg,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08), width: 0.65),
          ),
        ),
        child: visibleCount == 0
            ? const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '（等待输出…）',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.48,
                    fontFamily: 'monospace',
                    color: Color(0xFFDDE3EA),
                  ),
                ),
              )
            : RepaintBoundary(
                child: SelectionArea(
                  child: ListView.builder(
                    controller: _ctrl,
                    addAutomaticKeepAlives: false,
                    itemCount: visibleCount,
                    itemBuilder: (_, idx) => Text(
                      widget.lines[tailOffset + idx],
                      style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.48,
                        fontFamily: 'monospace',
                        color: Color(0xFFDDE3EA),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _LaunchJobSheetBody extends ConsumerStatefulWidget {
  const _LaunchJobSheetBody();

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

  @override
  void dispose() {
    _cmdCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _cmdCtrl.text.trim();
    if (text.isEmpty) {
      setState(() => _err = '请输入要在后台运行的命令');
      return;
    }
    ref.read(appProvider.notifier).launchQuickJob(text);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final watched = ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          activeWorkspace: s.activeWorkspace,
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
        : (watched.activeWorkspace.isNotEmpty ? watched.activeWorkspace : '默认工作目录');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: t.fill1,
            borderRadius: BorderRadius.circular(11),
          ),
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
                onTap: () {
                  _cmdCtrl.text = pair.$2;
                  if (_err != null) setState(() => _err = null);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: t.fill1,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: t.sep, width: 0.6),
                  ),
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
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: '后台启动',
                tier: tier,
                insideGlass: true,
                onTap: _submit,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
