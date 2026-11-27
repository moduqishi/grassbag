import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';

/// Validates a standard 5-field Cron expression (supports named months JAN-DEC,
/// named weekdays SUN-SAT, and ?, #, L, W modifiers).
final RegExp _cronWsRe = RegExp(r'\s+');
final RegExp _cronMinHourRe = RegExp(r'^[0-9*/,\-]+$');
final RegExp _cronDomRe = RegExp(r'^[0-9*/,\-?LWlw]+$');
final RegExp _cronMonthRe = RegExp(
  r'^(?:\*|\d{1,2}|JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)(?:[,\-/](?:\*|\d{1,2}|JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC))*$',
  caseSensitive: false,
);
final RegExp _cronDowRe = RegExp(
  r'^(?:\*|\?|\dL?|(?:SUN|MON|TUE|WED|THU|FRI|SAT)L?|L)(?:[,\-/#](?:\*|\?|\dL?|(?:SUN|MON|TUE|WED|THU|FRI|SAT)L?|L))*$',
  caseSensitive: false,
);

bool _cronFieldNumbersInRange(
  String field,
  int minVal,
  int maxVal, {
  Set<String> allowedNames = const {},
  bool allowQuestion = false,
  bool allowDomModifiers = false,
  bool allowDowModifiers = false,
}) {
  bool isAtomValid(String raw) {
    if (raw.isEmpty) return false;
    final n = int.tryParse(raw);
    if (n != null) return n >= minVal && n <= maxVal;
    final upper = raw.toUpperCase();
    if (allowedNames.contains(upper)) return true;
    if (allowDomModifiers) {
      if (upper == 'L' || upper == 'LW') return true;
      if (upper.endsWith('W') && upper.length >= 2) {
        final d = int.tryParse(upper.substring(0, upper.length - 1));
        return d != null && d >= minVal && d <= maxVal;
      }
    }
    if (allowDowModifiers) {
      if (upper == 'L') return true;
      if (upper.endsWith('L') && upper.length >= 2) {
        final baseDow = upper.substring(0, upper.length - 1);
        final d = int.tryParse(baseDow);
        return (d != null && d >= minVal && d <= maxVal) || allowedNames.contains(baseDow);
      }
      final hashIdx = upper.indexOf('#');
      if (hashIdx > 0 && upper.indexOf('#', hashIdx + 1) < 0) {
        final dowPart = upper.substring(0, hashIdx);
        final dow = int.tryParse(dowPart);
        final dowOk = (dow != null && dow >= minVal && dow <= maxVal) || allowedNames.contains(dowPart);
        final nth = int.tryParse(upper.substring(hashIdx + 1));
        return dowOk && nth != null && nth >= 1 && nth <= 5;
      }
    }
    return false;
  }

  for (final part in field.split(',')) {
    if (part.isEmpty) return false;
    final slashIdx = part.indexOf('/');
    if (slashIdx >= 0 && part.indexOf('/', slashIdx + 1) >= 0) return false;
    final base = slashIdx >= 0 ? part.substring(0, slashIdx) : part;
    if (slashIdx >= 0) {
      final step = int.tryParse(part.substring(slashIdx + 1));
      if (step == null || step <= 0 || step > maxVal) return false;
    }
    if (base.isEmpty) return false;
    if (base == '*') continue;
    if (base == '?') {
      if (!allowQuestion || slashIdx >= 0) return false;
      continue;
    }
    if (base.contains('*')) return false;
    final dashIdx = base.indexOf('-');
    if (dashIdx >= 0) {
      if (base.indexOf('-', dashIdx + 1) >= 0) return false;
      final aStr = base.substring(0, dashIdx);
      final bStr = base.substring(dashIdx + 1);
      if (!isAtomValid(aStr) || !isAtomValid(bStr)) return false;
      final a = int.tryParse(aStr);
      final b = int.tryParse(bStr);
      if (a != null && b != null && a > b) return false;
    } else {
      if (!isAtomValid(base)) return false;
    }
  }
  return true;
}

const Set<String> _cronMonthNames = {
  'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
  'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
};
const Set<String> _cronDowNames = {
  'SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT',
};

bool isValidCron5Field(String cron) {
  final fields = cron.trim().split(_cronWsRe);
  if (fields.length != 5) return false;
  if (!_cronMinHourRe.hasMatch(fields[0]) ||
      !_cronMinHourRe.hasMatch(fields[1]) ||
      !_cronDomRe.hasMatch(fields[2]) ||
      !_cronMonthRe.hasMatch(fields[3]) ||
      !_cronDowRe.hasMatch(fields[4])) {
    return false;
  }
  return _cronFieldNumbersInRange(fields[0], 0, 59) &&
      _cronFieldNumbersInRange(fields[1], 0, 23) &&
      _cronFieldNumbersInRange(fields[2], 1, 31, allowQuestion: true, allowDomModifiers: true) &&
      _cronFieldNumbersInRange(fields[3], 1, 12, allowedNames: _cronMonthNames) &&
      _cronFieldNumbersInRange(
        fields[4],
        0,
        7,
        allowedNames: _cronDowNames,
        allowQuestion: true,
        allowDowModifiers: true,
      );
}

String _localizeScheduleKind(String kind) {
  switch (kind.toLowerCase()) {
    case 'cron':
      return 'Cron 计划';
    case 'interval':
    case 'every':
      return '固定间隔';
    case 'once':
    case 'at':
    case 'one-shot':
      return '单次计划';
    default:
      return kind.isEmpty ? '自定义计划' : kind;
  }
}

String _localizeHistoryLine(String raw) {
  return raw
      .replaceAll(RegExp(r'\b(succeeded|success|ok)\b', caseSensitive: false), '成功')
      .replaceAll(RegExp(r'\b(failed|error)\b', caseSensitive: false), '失败')
      .replaceAll(RegExp(r'\b(skipped)\b', caseSensitive: false), '已跳过')
      .replaceAll(RegExp(r'\b(running)\b', caseSensitive: false), '执行中');
}

/// Translates a standard 5-field Cron expression into a readable Chinese schedule preview.
String describeCronZh(String cron) {
  final trimmed = cron.trim();
  if (trimmed.isEmpty) return '请输入 5 段 Cron 表达式（分 时 日 月 周）';
  if (!isValidCron5Field(trimmed)) {
    return '格式有误 · 需为 5 段（分 时 日 月 周），例如 0 9 * * *';
  }
  final f = trimmed.split(_cronWsRe);
  final min = f[0], hour = f[1], dom = f[2], mon = f[3], dow = f[4];
  String pad2(int n) => n.toString().padLeft(2, '0');
  final minInt = int.tryParse(min);
  final hourInt = int.tryParse(hour);
  final timeStr = (hourInt != null && minInt != null && hourInt >= 0 && hourInt <= 23 && minInt >= 0 && minInt <= 59)
      ? '${pad2(hourInt)}:${pad2(minInt)}'
      : null;

  if (min == '*' && hour == '*' && dom == '*' && mon == '*' && dow == '*') {
    return '每分钟执行';
  }
  if (min.startsWith('*/') && hour == '*' && dom == '*' && mon == '*' && dow == '*') {
    final step = int.tryParse(min.substring(2));
    if (step != null && step > 0) return '每 $step 分钟执行';
  }
  if (hour.startsWith('*/') && dom == '*' && mon == '*' && dow == '*') {
    final step = int.tryParse(hour.substring(2));
    if (step != null && step > 0) {
      if (minInt == 0) return '每 $step 小时整点执行';
      if (minInt != null) return '每 $step 小时的第 $minInt 分执行';
    }
  }
  if (timeStr != null && dom == '*' && mon == '*') {
    if (dow == '*' || dow == '?') return '每天 $timeStr';
    final dowUpper = dow.toUpperCase();
    if (dowUpper == '1-5' || dowUpper == 'MON-FRI') return '工作日 $timeStr';
    if (dowUpper == '0,6' || dowUpper == '6,0' || dowUpper == 'SAT,SUN' || dowUpper == 'SUN,SAT') {
      return '周末 $timeStr';
    }
    const dowMap = {
      '0': '日',
      '7': '日',
      'SUN': '日',
      '1': '一',
      'MON': '一',
      '2': '二',
      'TUE': '二',
      '3': '三',
      'WED': '三',
      '4': '四',
      'THU': '四',
      '5': '五',
      'FRI': '五',
      '6': '六',
      'SAT': '六',
    };
    if (dowMap.containsKey(dowUpper)) {
      return '每周${dowMap[dowUpper]} $timeStr';
    }
  }
  final domInt = int.tryParse(dom);
  if (timeStr != null && domInt != null && domInt >= 1 && domInt <= 31 && mon == '*' && (dow == '*' || dow == '?')) {
    return '每月 $domInt 日 $timeStr';
  }
  return '自定义计划（$trimmed）';
}

class SchedulesPage extends ConsumerStatefulWidget {
  const SchedulesPage({super.key});

  @override
  ConsumerState<SchedulesPage> createState() => _SchedulesPageState();
}

class _SchedulesPageState extends ConsumerState<SchedulesPage> {
  int _filterIdx = 0; // 0: 全部, 1: 运行中, 2: 已暂停
  final Set<String> _expandedHistory = {};
  final Set<String> _runningIds = {};
  final Set<String> _loadingHistoryIds = {};
  bool _initialLoading = false;

  @override
  void initState() {
    super.initState();
    if (ref.read(appProvider).schedules.isEmpty &&
        ref.read(appProvider).connectionPhase == ConnectionPhase.connected) {
      _initialLoading = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await ref.read(appProvider.notifier).refreshSchedules(silent: true);
      } finally {
        if (mounted && _initialLoading) setState(() => _initialLoading = false);
      }
    });
  }

  void _openCreateSheet(BuildContext context, {ScheduleTaskRecord? existing}) {
    if (!ref.read(appProvider).isDshConnected) {
      ref.read(appProvider.notifier).showToast(
            '当前未连接到 DSH 主机，请先恢复连接后再管理定时任务',
            tone: ToastTone.warn,
          );
      return;
    }
    var isDirty = false;
    showGrassBagSheet<void>(
      context,
      title: existing == null ? '新建定时任务' : '编辑定时任务',
      subtitle: existing == null
          ? '按计划自动唤醒助手执行并记录结果'
          : '修改任务名称、触发 Cron 计划或执行指令',
      onWillDismiss: () async {
        if (!isDirty || !context.mounted) return true;
        return showGrassBagConfirmDialog(
          context,
          title: '放弃未保存的定时任务内容？',
          message: '关闭后当前已填写的计划与执行指令将不会保留。',
          confirmLabel: '放弃并关闭',
          isDestructive: true,
        );
      },
      bodyBuilder: (sheetCtx) => _CreateScheduleSheetBody(
        existing: existing,
        onDirtyChanged: (dirty) => isDirty = dirty,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(appProvider.select((s) => s.activeHostId), (prev, next) {
      if (prev != null && prev != next && mounted) {
        setState(() {
          _expandedHistory.clear();
          _runningIds.clear();
          _loadingHistoryIds.clear();
        });
        unawaited(ref.read(appProvider.notifier).refreshSchedules(silent: true));
      }
    });
    ref.listen<ConnectionPhase>(appProvider.select((s) => s.connectionPhase), (prev, next) {
      if (prev != ConnectionPhase.connected && next == ConnectionPhase.connected && mounted) {
        unawaited(ref.read(appProvider.notifier).refreshSchedules(silent: true));
      }
    });
    ref.watch(
      appProvider.select(
        (s) => (
          schedules: s.schedules,
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

    final endedCount = state.schedules.where((s) => s.isEnded).length;
    final pausedCount = state.schedules.where((s) => !s.enabled && !s.isEnded).length;
    final safeFilterIdx = endedCount == 0 && _filterIdx == 3 ? 0 : _filterIdx;

    final items = state.schedules.where((s) {
      if (safeFilterIdx == 1) return s.enabled && !s.isEnded;
      if (safeFilterIdx == 2) return !s.enabled && !s.isEnded;
      if (safeFilterIdx == 3) return s.isEnded;
      return true;
    }).toList(growable: false);

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
                    onRefresh: () => ctrl.refreshSchedules(
                      silent: state.connectionPhase == ConnectionPhase.connected,
                    ),
                    child: CustomScrollView(
                      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                      slivers: [
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(16, topPad + 76, 16, 40 + botPad),
                          sliver: SliverMainAxisGroup(
                            slivers: [
                              SliverToBoxAdapter(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    if (state.connectionPhase != ConnectionPhase.connected) ...[
                                      GrassBagStatusBanner(
                                        tone: GrassBagBannerTone.warn,
                                        icon: CupertinoIcons.wifi_exclamationmark,
                                        title: '未连接到 DSH 主机',
                                        message: '定时任务由已连接的 DSH 引擎持久化与调度，恢复连接后自动同步。',
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
                                    GrassBagSegmentedControl(
                                      labels: endedCount > 0
                                          ? [
                                              '全部 ${state.schedules.length}',
                                              '运行 ${state.activeScheduleCount}',
                                              '暂停 $pausedCount',
                                              '结束 $endedCount',
                                            ]
                                          : [
                                              '全部 (${state.schedules.length})',
                                              '运行中 (${state.activeScheduleCount})',
                                              '已暂停 ($pausedCount)',
                                            ],
                                      selectedIndex: safeFilterIdx,
                                      tier: state.glassTier,
                                      onSelected: (i) => setState(() => _filterIdx = i),
                                    ),
                                    if (endedCount > 0) ...[
                                      const SizedBox(height: 10),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: GrassBagSecondaryGlassButton(
                                          label: '清理 $endedCount 条已结束任务',
                                          icon: CupertinoIcons.trash,
                                          height: 32,
                                          padding: const EdgeInsets.symmetric(horizontal: 12),
                                          tier: state.glassTier,
                                          insideGlass: true,
                                          destructive: true,
                                          enabled: state.isDshConnected,
                                          onTap: !state.isDshConnected
                                              ? null
                                              : () async {
                                                  final ok = await showGrassBagConfirmDialog(
                                                    context,
                                                    title: '清理已结束任务',
                                                    message: '确定移除全部 $endedCount 条已结束的一次性/过期定时任务吗？',
                                                    confirmLabel: '清理',
                                                    isDestructive: true,
                                                  );
                                                  if (ok) unawaited(ctrl.pruneInactiveSchedules());
                                                },
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 14),
                                  ],
                                ),
                              ),
                              if (items.isEmpty && _initialLoading)
                                SliverToBoxAdapter(
                                  child: GrassBagCard(
                                    padding: const EdgeInsets.symmetric(vertical: 34),
                                    child: Center(
                                      child: GrassBagActivityIndicator(radius: 11, color: t.primary),
                                    ),
                                  ),
                                )
                              else if (items.isEmpty)
                                SliverToBoxAdapter(
                                  child: GrassBagCard(
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
                                    child: Column(
                                      children: [
                                        Icon(CupertinoIcons.clock, size: 32, color: t.text3),
                                        const SizedBox(height: 10),
                                        Text(
                                          safeFilterIdx == 0 ? '暂无定时任务' : '当前筛选下暂无定时任务',
                                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text2),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '创建按 Cron 计划唤醒助手的自动巡检或汇报任务',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(fontSize: 12, color: t.text3),
                                        ),
                                        const SizedBox(height: 14),
                                        GrassBagSecondaryGlassButton(
                                          label: safeFilterIdx == 0 ? '新建定时任务' : '显示全部任务',
                                          icon: safeFilterIdx == 0 ? CupertinoIcons.add : CupertinoIcons.list_bullet,
                                          tier: state.glassTier,
                                          insideGlass: true,
                                          accentForeground: true,
                                          onTap: () {
                                            if (safeFilterIdx != 0) {
                                              setState(() => _filterIdx = 0);
                                            } else {
                                              _openCreateSheet(context);
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              else
                                SliverList.builder(
                                  itemCount: items.length,
                                  itemBuilder: (_, idx) {
                                    final item = items[idx];
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 12),
                                      child: RepaintBoundary(
                                        child: _ScheduleCard(
                                          item: item,
                                          tier: state.glassTier,
                                          connected: state.isDshConnected,
                                          historyExpanded: _expandedHistory.contains(item.id),
                                          runningNow: _runningIds.contains(item.id),
                                          loadingHistory: _loadingHistoryIds.contains(item.id),
                                          onToggleEnabled: () => ctrl.toggleSchedule(item.id),
                                          onEdit: () => _openCreateSheet(context, existing: item),
                                          onRunNow: () async {
                                            if (_runningIds.contains(item.id)) return;
                                            setState(() => _runningIds.add(item.id));
                                            try {
                                              await ctrl.runScheduleNow(item.id);
                                            } finally {
                                              if (mounted) setState(() => _runningIds.remove(item.id));
                                            }
                                          },
                                          onToggleHistory: () async {
                                            var expanding = false;
                                            setState(() {
                                              if (_expandedHistory.add(item.id)) {
                                                expanding = true;
                                                _loadingHistoryIds.add(item.id);
                                              } else {
                                                _expandedHistory.remove(item.id);
                                                _loadingHistoryIds.remove(item.id);
                                              }
                                            });
                                            if (expanding) {
                                              try {
                                                await ctrl.loadScheduleHistory(item.id);
                                              } finally {
                                                if (mounted) setState(() => _loadingHistoryIds.remove(item.id));
                                              }
                                            }
                                          },
                                          onDelete: () async {
                                            final ok = await showGrassBagConfirmDialog(
                                              context,
                                              title: '删除定时任务',
                                              message: '确定移除「${item.name}」吗？该计划将不再自动执行。',
                                              confirmLabel: '删除',
                                              isDestructive: true,
                                            );
                                            if (ok) ctrl.deleteSchedule(item.id);
                                          },
                                        ),
                                      ),
                                    );
                                  },
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
                title: '定时任务',
                subtitle: '${state.activeScheduleCount} 项计划启用中',
                tier: state.glassTier,
                onBack: () => Navigator.of(context).pop(),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GrassBagGlassCircleButton(
                      icon: CupertinoIcons.refresh,
                      tooltip: '刷新定时任务',
                      tier: state.glassTier,
                      useOwnLayer: false,
                      onTap: () => unawaited(ctrl.refreshSchedules()),
                    ),
                    const SizedBox(width: 8),
                    GrassBagGlassCircleButton(
                      icon: CupertinoIcons.add,
                      tooltip: '新建定时任务',
                      tier: state.glassTier,
                      useOwnLayer: false,
                      onTap: () => _openCreateSheet(context),
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

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({
    required this.item,
    required this.tier,
    required this.connected,
    required this.historyExpanded,
    required this.runningNow,
    required this.loadingHistory,
    required this.onToggleEnabled,
    required this.onEdit,
    required this.onRunNow,
    required this.onToggleHistory,
    required this.onDelete,
  });

  final ScheduleTaskRecord item;
  final GrassBagGlassTier tier;
  final bool connected;
  final bool historyExpanded;
  final bool runningNow;
  final bool loadingHistory;
  final VoidCallback onToggleEnabled;
  final VoidCallback onEdit;
  final VoidCallback onRunNow;
  final VoidCallback onToggleHistory;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final statusColor = item.enabled ? t.ok : t.text3;

    return GrassBagCard(
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GrassBagSquircleIcon(
                icon: CupertinoIcons.clock_fill,
                color: item.enabled ? t.warn : t.text3,
                size: 36,
                iconSize: 17,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          [
                            item.humanSchedule.trim().isNotEmpty
                                ? item.humanSchedule.trim()
                                : describeCronZh(item.cronExpr),
                            if (item.timezone.trim().isNotEmpty) item.timezone.trim(),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: t.text2),
                        ),
                        if (item.cronExpr.trim().isNotEmpty)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 132),
                            child: GrassBagFresnelGlassSurface(
                              isPill: true,
                              innerWell: true,
                              padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 2),
                              child: Text(
                                item.cronExpr,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w500,
                                  color: t.text3,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (item.isEnded)
                GrassBagFresnelGlassSurface(
                  isPill: true,
                  innerWell: true,
                  padding: const EdgeInsets.symmetric(horizontal: 9.5, vertical: 4),
                  child: Text(
                    '已结束',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.text3),
                  ),
                )
              else
                GrassBagGlassSwitch(
                  value: item.enabled,
                  tier: tier,
                  onChanged: connected ? (_) => onToggleEnabled() : null,
                ),
            ],
          ),
          const SizedBox(height: 10),
          GrassBagFresnelGlassSurface(
            borderRadius: 13,
            innerWell: true,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            child: Text(
              item.prompt,
              style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text2),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GrassBagStatusDot(
                    size: 7,
                    color: statusColor,
                    pulsing: runningNow,
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      () {
                        final hasNext = item.nextRunAt.trim().isNotEmpty &&
                            item.enabled &&
                            !item.isEnded;
                        final hasLast = item.lastRunAt.trim().isNotEmpty;
                        if (hasNext && hasLast) {
                          return '下次：${item.nextRunAt.trim()} · 最近：${item.lastRunAt.trim()}';
                        }
                        if (hasNext) return '下次：${item.nextRunAt.trim()}';
                        if (hasLast) return '最近运行：${item.lastRunAt.trim()}';
                        return '尚未运行';
                      }(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: t.text3),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 4,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  GrassBagSpringTap(
                    onTap: onToggleHistory,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            historyExpanded
                                ? '收起记录'
                                : (item.history.isEmpty ? '运行记录' : '记录 (${item.history.length})'),
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text2),
                          ),
                          const SizedBox(width: 3),
                          AnimatedRotation(
                            turns: historyExpanded ? 0.25 : 0.0,
                            duration: GrassBagMotion.duration(context, const Duration(milliseconds: 200)),
                            curve: Curves.easeOutCubic,
                            child: Icon(
                              CupertinoIcons.chevron_right,
                              size: 11,
                              color: t.text3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  GrassBagSpringTap(
                    enabled: connected && !runningNow,
                    onTap: onRunNow,
                    enablePointerGlow: false,
                    haptic: true,
                    child: GrassBagFresnelGlassSurface(
                      isPill: true,
                      innerWell: true,
                      interactive: connected && !runningNow,
                      tintColor: t.primarySoft,
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (runningNow)
                            GrassBagActivityIndicator(radius: 6, color: t.primary)
                          else
                            Icon(CupertinoIcons.play_fill, size: 11, color: connected ? t.primary : t.text3),
                          const SizedBox(width: 4),
                          Text(
                            runningNow ? '执行中…' : '立即执行',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: connected ? t.primary : t.text3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Tooltip(
                    message: '编辑定时任务',
                    child: GrassBagSpringTap(
                      enabled: connected,
                      onTap: onEdit,
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: Center(
                          child: Icon(
                            CupertinoIcons.pencil,
                            size: 15.5,
                            color: connected ? t.text2 : t.text3.withValues(alpha: 0.45),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Tooltip(
                    message: '删除定时任务',
                    child: GrassBagSpringTap(
                      enabled: connected,
                      onTap: onDelete,
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: Center(
                          child: Icon(
                            CupertinoIcons.trash,
                            size: 15.5,
                            color: connected ? t.err : t.text3.withValues(alpha: 0.45),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          ),
          GrassBagSmoothDisclosure(
            expanded: historyExpanded,
            duration: const Duration(milliseconds: 220),
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: GrassBagFresnelGlassSurface(
                borderRadius: 12,
                innerWell: true,
                paintTopSheen: !t.isDark,
                width: double.infinity,
                tintColor: t.isDark ? t.codeBg : null,
                padding: const EdgeInsets.all(10),
                child: AnimatedSwitcher(
                  duration: GrassBagMotion.duration(context, const Duration(milliseconds: 160)),
                  child: loadingHistory && item.history.isEmpty
                      ? Padding(
                          key: const ValueKey('sched-hist-loading'),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Center(child: GrassBagActivityIndicator(radius: 8, color: t.primary)),
                        )
                      : item.history.isEmpty
                          ? Text(
                              '暂无执行历史',
                              key: const ValueKey('sched-hist-empty'),
                              style: TextStyle(fontSize: 12, color: t.text3),
                            )
                          : Column(
                              key: ValueKey('sched-hist-${item.history.length}'),
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final h in item.history)
                                  Builder(
                                    builder: (_) {
                                      final lower = h.toLowerCase();
                                      final isErr = lower.contains('error') ||
                                          lower.contains('failed') ||
                                          lower.contains('失败');
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 3),
                                        child: Row(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Icon(
                                              isErr
                                                  ? CupertinoIcons.xmark_circle_fill
                                                  : CupertinoIcons.checkmark_alt_circle_fill,
                                              size: 13,
                                              color: isErr ? t.err : t.ok,
                                            ),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                _localizeHistoryLine(h),
                                                style: TextStyle(fontSize: 12, color: t.text2),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                              ],
                            ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CreateScheduleSheetBody extends ConsumerStatefulWidget {
  const _CreateScheduleSheetBody({this.existing, this.onDirtyChanged});
  final ScheduleTaskRecord? existing;
  final ValueChanged<bool>? onDirtyChanged;

  @override
  ConsumerState<_CreateScheduleSheetBody> createState() => _CreateScheduleSheetBodyState();
}

class _CreateScheduleSheetBodyState extends ConsumerState<_CreateScheduleSheetBody> {
  static const _presets = [
    ('每天 09:00', '0 9 * * *'),
    ('工作日 18:30', '30 18 * * 1-5'),
    ('每 6 小时', '0 */6 * * *'),
    ('每周一 08:00', '0 8 * * 1'),
  ];

  static const _starterTemplates = [
    (
      label: '每日工作区巡检',
      name: '每日工作区巡检',
      cron: '0 9 * * *',
      prompt: '检查当前工作区的 git 状态、未提交改动和待办事项，输出简明晨报。',
    ),
    (
      label: '每周日志与改动汇总',
      name: '每周日志与改动汇总',
      cron: '30 18 * * 5',
      prompt: '汇总本周的 git 提交记录、关键变更与未完成任务，生成一份结构化周报。',
    ),
  ];

  late final TextEditingController _nameCtrl;
  late final TextEditingController _promptCtrl;
  late final TextEditingController _cronCtrl;
  final _cronFocus = FocusNode();
  final _promptFocus = FocusNode();
  int _selectedPreset = 0;
  bool _keepExistingNonCronTiming = false;
  bool _submitting = false;
  String? _err;

  late final String _initialName;
  late final String _initialPrompt;
  late final String _initialCron;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    _initialName = ex?.name ?? '';
    _initialPrompt = ex?.prompt ?? '';
    _nameCtrl = TextEditingController(text: _initialName);
    _promptCtrl = TextEditingController(text: _initialPrompt);
    final isNonCronExisting = ex != null && ex.kind != 'cron' && !isValidCron5Field(ex.cronExpr);
    _keepExistingNonCronTiming = isNonCronExisting;
    final initCron = (ex != null && isValidCron5Field(ex.cronExpr))
        ? ex.cronExpr.trim()
        : '0 9 * * *';
    _initialCron = initCron;
    _cronCtrl = TextEditingController(text: initCron);
    _selectedPreset = _presets.indexWhere((p) => p.$2 == initCron);
  }

  void _syncDirty() {
    final dirty = _nameCtrl.text.trim() != _initialName.trim() ||
        _promptCtrl.text.trim() != _initialPrompt.trim() ||
        (!_keepExistingNonCronTiming && _cronCtrl.text.trim() != _initialCron);
    widget.onDirtyChanged?.call(dirty);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _promptCtrl.dispose();
    _cronCtrl.dispose();
    _cronFocus.dispose();
    _promptFocus.dispose();
    super.dispose();
  }

  static bool _isValidCron5Field(String cron) => isValidCron5Field(cron);

  Future<void> _submit() async {
    if (_submitting) return;
    final name = _nameCtrl.text.trim();
    final prompt = _promptCtrl.text.trim();
    final cron = _cronCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _err = '请填写任务名称');
      return;
    }
    if (!_keepExistingNonCronTiming) {
      if (cron.isEmpty) {
        setState(() => _err = '请填写 Cron 表达式');
        return;
      }
      if (!_isValidCron5Field(cron)) {
        setState(() => _err = 'Cron 表达式需为标准 5 段格式（分 时 日 月 周），例如 0 9 * * *');
        return;
      }
    }
    if (prompt.isEmpty) {
      setState(() => _err = '请填写定时执行指令');
      return;
    }
    final human = _presets.any((p) => p.$2 == cron)
        ? _presets.firstWhere((p) => p.$2 == cron).$1
        : describeCronZh(cron);
    setState(() {
      _submitting = true;
      _err = null;
    });
    final ctrl = ref.read(appProvider.notifier);
    final err = widget.existing != null
        ? await ctrl.updateSchedule(
            id: widget.existing!.id,
            name: name,
            cronExpr: _keepExistingNonCronTiming ? null : cron,
            prompt: prompt,
            timezone: widget.existing!.timezone,
          )
        : await ctrl.createSchedule(
            name: name,
            cronExpr: cron,
            humanSchedule: human,
            prompt: prompt,
          );
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _submitting = false;
        _err = err;
      });
      return;
    }
    widget.onDirtyChanged?.call(false);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final cronText = _cronCtrl.text.trim();
    final cronValid = isValidCron5Field(cronText);
    final cronPreview = describeCronZh(cronText);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.existing == null) ...[
          Text('快捷模板（一键填充）', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text2)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tpl in _starterTemplates)
                GrassBagSpringTap(
                  enablePointerGlow: false,
                  haptic: true,
                  onTap: () {
                    setState(() {
                      _nameCtrl.text = tpl.name;
                      _cronCtrl.text = tpl.cron;
                      _promptCtrl.text = tpl.prompt;
                      _selectedPreset = _presets.indexWhere((p) => p.$2 == tpl.cron);
                      _err = null;
                    });
                    _syncDirty();
                  },
                  child: GrassBagFresnelGlassSurface(
                    isPill: true,
                    innerWell: true,
                    interactive: true,
                    tintColor: t.primarySoft,
                    padding: const EdgeInsets.symmetric(horizontal: 10.5, vertical: 6),
                    child: Text(
                      tpl.label,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.primary),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        Text('任务名称', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text2)),
        const SizedBox(height: 6),
        GrassBagTextField(
          controller: _nameCtrl,
          insideGlass: true,
          hasError: _err != null && _nameCtrl.text.trim().isEmpty,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _keepExistingNonCronTiming
              ? _promptFocus.requestFocus()
              : _cronFocus.requestFocus(),
          onChanged: (_) {
            _syncDirty();
            if (_err != null) setState(() => _err = null);
          },
          placeholder: '例如：每日依赖安全巡检',
          fontSize: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        const SizedBox(height: 14),
        Text('触发周期', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text2)),
        const SizedBox(height: 8),
        if (_keepExistingNonCronTiming && widget.existing != null) ...[
          GrassBagStatusBanner(
            tone: GrassBagBannerTone.info,
            borderRadius: 14,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            message:
                '当前保留原计划：${widget.existing!.humanSchedule}（${_localizeScheduleKind(widget.existing!.kind)}）',
            trailing: GrassBagSecondaryGlassButton(
              label: '改为 Cron',
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tier: tier,
              insideGlass: true,
              accentForeground: true,
              onTap: () => setState(() => _keepExistingNonCronTiming = false),
            ),
          ),
        ] else ...[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < _presets.length; i++)
              GrassBagFilterChip(
                label: _presets[i].$1,
                selected: _selectedPreset == i,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                fontSize: 12.5,
                onTap: () {
                  setState(() {
                    _selectedPreset = i;
                    _cronCtrl.text = _presets[i].$2;
                    _err = null;
                  });
                  _syncDirty();
                },
              ),
          ],
        ),
        const SizedBox(height: 10),
        GrassBagTextField(
          controller: _cronCtrl,
          focusNode: _cronFocus,
          insideGlass: true,
          monospace: true,
          hasError: !cronValid || (_err != null && cronText.isEmpty),
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _promptFocus.requestFocus(),
          onChanged: (v) {
            final matchIdx = _presets.indexWhere((p) => p.$2 == v.trim());
            setState(() {
              _selectedPreset = matchIdx;
              _err = null;
            });
            _syncDirty();
          },
          placeholder: 'Cron 表达式，例如 0 9 * * *',
          fontSize: 13,
          borderRadius: 12,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(
              cronValid ? CupertinoIcons.clock : CupertinoIcons.exclamationmark_circle,
              size: 12.5,
              color: cronValid ? t.primary : t.warn,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Builder(
                builder: (_) {
                  final rawTz = widget.existing?.timezone.trim() ?? '';
                  final tzLabel = rawTz.isNotEmpty ? rawTz : DateTime.now().timeZoneName;
                  final tzPart = tzLabel.isNotEmpty ? ' · 时区：$tzLabel' : '';
                  return Text(
                    cronPreview.contains('分 时 日 月 周')
                        ? cronPreview
                        : '$cronPreview$tzPart · 分 时 日 月 周',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: cronValid ? t.text2 : t.warn),
                  );
                },
              ),
            ),
          ],
        ),
        ],
        const SizedBox(height: 14),
        Text('执行指令', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text2)),
        const SizedBox(height: 6),
        GrassBagTextField(
          controller: _promptCtrl,
          focusNode: _promptFocus,
          insideGlass: true,
          hasError: _err != null && _promptCtrl.text.trim().isEmpty,
          maxLines: 3,
          minLines: 2,
          onChanged: (_) {
            _syncDirty();
            if (_err != null) setState(() => _err = null);
          },
          placeholder: '输入到达时间后交给助手执行的任务描述…',
          fontSize: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        if (_err != null) ...[
          const SizedBox(height: 8),
          Text(_err!, style: TextStyle(fontSize: 12, color: t.err)),
        ],
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
                label: _submitting
                    ? '保存中…'
                    : (widget.existing == null ? '创建任务' : '保存修改'),
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
