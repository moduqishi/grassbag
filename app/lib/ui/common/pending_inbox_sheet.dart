import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import 'grassbag_sheets.dart';

/// Opens the consolidated Pending Inbox modal sheet gathering all actionable items:
/// - Pending approvals & dynamic plugin authorizations (across all sessions on the host)
/// - Pending user questions
/// - Failed background jobs
/// - Unsent / offline outbox messages
Future<void> showPendingInboxSheet(
  BuildContext context,
  WidgetRef ref, {
  VoidCallback? onOpenJobs,
  VoidCallback? onOpenHosts,
}) {
  return showGrassBagSheet<void>(
    context,
    title: '待处理收件箱',
    subtitle: '集中处理当前主机的待审批、待回答、失败任务与未发送消息',
    icon: CupertinoIcons.tray_fill,
    expandable: true,
    bodyBuilder: (_) => _PendingInboxSheetBody(
      onOpenJobs: onOpenJobs,
      onOpenHosts: onOpenHosts,
    ),
  );
}

class _PendingInboxSheetBody extends ConsumerWidget {
  const _PendingInboxSheetBody({
    this.onOpenJobs,
    this.onOpenHosts,
  });

  final VoidCallback? onOpenJobs;
  final VoidCallback? onOpenHosts;

  String _sessionTitle(GrassBagAppState state, String? sid) {
    if (sid == null || sid.isEmpty) return '当前主机';
    final matched = state.sessions.where((s) => s.id == sid).firstOrNull;
    if (matched != null && matched.title.trim().isNotEmpty) {
      return matched.title.trim();
    }
    return sid.length > 16 ? '${sid.substring(0, 14)}…' : sid;
  }

  String _interactionSummary(PendingInteraction item) {
    final p = item.payload;
    if (item.kind == 'user_questions') {
      final qs = p['questions'];
      if (qs is List && qs.isNotEmpty && qs.first is Map) {
        final qMap = qs.first as Map;
        final text = (qMap['question'] ?? qMap['title'] ?? qMap['text'] ?? '').toString().trim();
        if (text.isNotEmpty) return text;
      }
      return (p['title'] ?? p['prompt'] ?? '助手正在等待你的回答').toString();
    }
    if (item.kind == 'cordis_run') {
      final name = (p['pluginName'] ?? p['name'] ?? '动态插件').toString();
      final reason = (p['summary'] ?? p['reason'] ?? '请求运行动态插件').toString();
      return '$name · $reason';
    }
    final args = p['args'] is Map ? p['args'] as Map : (p['input'] is Map ? p['input'] as Map : null);
    final cmd = (p['command'] ?? args?['command'] ?? args?['cmd'])?.toString().trim();
    if (cmd != null && cmd.isNotEmpty) return cmd;
    final tool = (p['tool'] ?? p['toolName'] ?? p['name'] ?? '').toString().trim();
    final desc = (p['description'] ?? p['reason'] ?? p['title'] ?? '').toString().trim();
    if (tool.isNotEmpty && desc.isNotEmpty) return '$tool · $desc';
    if (tool.isNotEmpty) return '请求执行 $tool';
    if (desc.isNotEmpty) return desc;
    return '等待确认的高危操作';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final tier = state.glassTier;

    final approvals = state.pendingInteractions
        .where((i) => i.kind != 'user_questions')
        .toList(growable: false);
    final questions = state.pendingInteractions
        .where((i) => i.kind == 'user_questions')
        .toList(growable: false);
    final failedJobs = state.failedJobs;
    final unsentItems = state.unsentOutboxForActiveHost;
    final total = approvals.length + questions.length + failedJobs.length + unsentItems.length;

    if (total == 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GrassBagSquircleIcon(
              icon: CupertinoIcons.checkmark_seal_fill,
              color: t.ok,
              size: 48,
              iconSize: 24,
            ),
            const SizedBox(height: 12),
            Text(
              '全部已处理',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.text),
            ),
            const SizedBox(height: 5),
            Text(
              '当前主机暂无待审批操作、待回答提问、失败任务或未发送草稿。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: t.text2),
            ),
          ],
        ),
      );
    }

    Widget sectionHeader(String title, int count, Color color) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(
          children: [
            Text(
              title,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: t.text2),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 1.5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: t.isDark ? 0.22 : 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: color,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Pending Approvals & Dynamic Plugin Authorizations
        if (approvals.isNotEmpty) ...[
          sectionHeader('待审批操作', approvals.length, t.warn),
          for (final item in approvals) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GrassBagFresnelGlassSurface(
                borderRadius: 16,
                innerWell: true,
                tintColor: t.warnSoft,
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          item.kind == 'cordis_run'
                              ? CupertinoIcons.cube_fill
                              : CupertinoIcons.shield_lefthalf_fill,
                          size: 14,
                          color: t.warn,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _sessionTitle(state, item.sessionId ?? item.payload['sessionId']?.toString()),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text2),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _interactionSummary(item),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: item.kind == 'cordis_run' ? null : 'monospace',
                        fontSize: 12,
                        height: 1.38,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Row(
                      children: [
                        Expanded(
                          child: GrassBagPrimaryGlassButton(
                            label: '允许',
                            icon: CupertinoIcons.checkmark_alt,
                            height: 32,
                            tier: tier,
                            insideGlass: true,
                            onTap: () => unawaited(ctrl.resolveInteractionById(item.id, 'allow')),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: GrassBagSecondaryGlassButton(
                            label: '拒绝',
                            icon: CupertinoIcons.xmark,
                            height: 32,
                            tier: tier,
                            insideGlass: true,
                            destructive: true,
                            onTap: () => unawaited(ctrl.resolveInteractionById(item.id, 'deny')),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GrassBagSecondaryGlassButton(
                          label: '查看',
                          height: 32,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          tier: tier,
                          insideGlass: true,
                          onTap: () {
                            Navigator.of(context).pop();
                            ctrl.openInboxInteraction(item);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
        ],

        // 2. Pending User Questions
        if (questions.isNotEmpty) ...[
          sectionHeader('待回答提问', questions.length, t.primary),
          for (final item in questions) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GrassBagFresnelGlassSurface(
                borderRadius: 16,
                innerWell: true,
                tintColor: t.primarySoft,
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(CupertinoIcons.question_circle_fill, size: 14, color: t.primary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _sessionTitle(state, item.sessionId ?? item.payload['sessionId']?.toString()),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text2),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _interactionSummary(item),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text),
                    ),
                    const SizedBox(height: 9),
                    GrassBagPrimaryGlassButton(
                      label: '前往回答',
                      icon: CupertinoIcons.arrow_right_circle_fill,
                      height: 34,
                      tier: tier,
                      insideGlass: true,
                      onTap: () {
                        Navigator.of(context).pop();
                        ctrl.openInboxInteraction(item);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
        ],

        // 3. Failed Background Jobs
        if (failedJobs.isNotEmpty) ...[
          sectionHeader('失败的后台任务', failedJobs.length, t.err),
          for (final job in failedJobs) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GrassBagFresnelGlassSurface(
                borderRadius: 16,
                innerWell: true,
                tintColor: t.errSoft,
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 16, color: t.err),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            job.command.trim().isNotEmpty ? job.command.trim() : job.id,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: t.text,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '状态：${job.status}${job.startedAtLabel.isNotEmpty ? ' · ${job.startedAtLabel}' : ''}',
                            style: TextStyle(fontSize: 11, color: t.err),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    GrassBagSecondaryGlassButton(
                      label: '查看任务',
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tier: tier,
                      insideGlass: true,
                      onTap: () {
                        Navigator.of(context).pop();
                        if (onOpenJobs != null) {
                          onOpenJobs!();
                        } else {
                          ctrl.handleNotificationOpened({'kind': 'job', 'jobId': job.id});
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
        ],

        // 4. Unsent Offline / Failed Outbox Messages
        if (unsentItems.isNotEmpty) ...[
          sectionHeader('未发送消息', unsentItems.length, t.warn),
          for (final item in unsentItems) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GrassBagFresnelGlassSurface(
                borderRadius: 16,
                innerWell: true,
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      item.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      state.isDshConnected
                          ? '已重连主机，可将此消息恢复到输入框确认后发送'
                          : '主机尚未连接，请先连接主机后再发送',
                      style: TextStyle(fontSize: 11, color: t.text3),
                    ),
                    const SizedBox(height: 9),
                    Row(
                      children: [
                        Expanded(
                          child: state.isDshConnected
                              ? GrassBagPrimaryGlassButton(
                                  label: '恢复到输入框',
                                  icon: CupertinoIcons.arrow_uturn_left,
                                  height: 32,
                                  tier: tier,
                                  insideGlass: true,
                                  onTap: () {
                                    Navigator.of(context).pop();
                                    ctrl.restoreOutboxEntryToDraft(item);
                                  },
                                )
                              : GrassBagPrimaryGlassButton(
                                  label: '连接主机',
                                  icon: CupertinoIcons.link,
                                  height: 32,
                                  tier: tier,
                                  insideGlass: true,
                                  onTap: () {
                                    Navigator.of(context).pop();
                                    if (onOpenHosts != null) {
                                      onOpenHosts!();
                                    } else {
                                      showHostQuickSheet(context, ref);
                                    }
                                  },
                                ),
                        ),
                        const SizedBox(width: 8),
                        GrassBagSecondaryGlassButton(
                          label: '移除',
                          height: 32,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          tier: tier,
                          insideGlass: true,
                          destructive: true,
                          onTap: () => ctrl.dismissOutboxEntry(item.id),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }
}
