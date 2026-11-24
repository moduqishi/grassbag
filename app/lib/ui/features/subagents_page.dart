import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';

class SubagentsPage extends ConsumerStatefulWidget {
  const SubagentsPage({super.key});

  @override
  ConsumerState<SubagentsPage> createState() => _SubagentsPageState();
}

class _SubagentsPageState extends ConsumerState<SubagentsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(appProvider.notifier).refreshSubagentsOnly(silent: true));
    });
  }

  void _openPromptSheet(BuildContext context, SubagentItem sub) {
    showGrassBagSheet<void>(
      context,
      title: '向 ${sub.name} 发送补充指令',
      subtitle: '${sub.role} · ${sub.model}',
      bodyBuilder: (sheetCtx) => _SubagentPromptDialogBody(sub: sub),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(
      appProvider.select((s) => '${s.activeHostId}:${s.activeSessionId}'),
      (prev, next) {
        if (prev != null && prev != next && mounted) {
          unawaited(ref.read(appProvider.notifier).refreshSubagentsOnly(silent: true));
        }
      },
    );
    ref.watch(
      appProvider.select(
        (s) => (
          subagents: s.subagents,
          sessions: s.sessions,
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

    final runningCount = state.subagents
        .where((s) => s.status.toLowerCase() == 'running')
        .length;

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
                          message: '子代理协作任务实时同步自运行中的 DSH 引擎，恢复连接后自动刷新。',
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
                      if (state.subagents.isEmpty)
                        GrassBagCard(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
                          child: Column(
                            children: [
                              Icon(CupertinoIcons.arrow_branch, size: 32, color: t.text3),
                              const SizedBox(height: 10),
                              Text(
                                '当前对话暂无并行子代理',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text2),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '使用多任务拆解或 /teamwork 时会在此显示子代理协作任务与独立分支',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, color: t.text3),
                              ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                alignment: WrapAlignment.center,
                                children: [
                                  GrassBagPrimaryGlassButton(
                                    label: '复制 /teamwork 示例',
                                    icon: CupertinoIcons.doc_on_doc,
                                    tier: state.glassTier,
                                    insideGlass: true,
                                    height: 38,
                                    onTap: () {
                                      Clipboard.setData(
                                        const ClipboardData(
                                          text: '/teamwork 并行分析项目结构、找出关键瓶颈并整理修复方案',
                                        ),
                                      );
                                      ctrl.showToast('已复制 /teamwork 示例，可粘贴到对话框发送', tone: ToastTone.ok);
                                    },
                                  ),
                                  GrassBagSecondaryGlassButton(
                                    label: '刷新状态',
                                    icon: CupertinoIcons.refresh,
                                    tier: state.glassTier,
                                    insideGlass: true,
                                    height: 38,
                                    onTap: () => unawaited(ctrl.refreshSubagentsOnly()),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        )
                      else
                        for (final sub in state.subagents) ...[
                          SubagentLineageCard(
                            item: sub,
                            onPrompt: () => _openPromptSheet(context, sub),
                            onInterrupt: sub.status.toLowerCase() == 'running'
                                ? () async {
                                    final ok = await showGrassBagConfirmDialog(
                                      context,
                                      title: '中断子代理「${sub.name}」？',
                                      message: '确定强制中断该正在执行的子代理任务吗？',
                                      confirmLabel: '确认中断',
                                      isDestructive: true,
                                    );
                                    if (ok) ctrl.interruptSubagent(sub.id);
                                  }
                                : null,
                            onInspect: state.sessions.any((s) => s.id == sub.id)
                                ? () {
                                    ctrl.selectSession(sub.id);
                                    Navigator.of(context).pop();
                                  }
                                : null,
                          ),
                          const SizedBox(height: 12),
                        ],
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
                title: '协作子代理',
                subtitle: runningCount > 0 ? '$runningCount 个运行中' : '${state.subagents.length} 条协作任务',
                tier: state.glassTier,
                onBack: () => Navigator.of(context).pop(),
                trailing: GrassBagGlassCircleButton(
                  icon: CupertinoIcons.refresh,
                  tooltip: '刷新子代理状态',
                  tier: state.glassTier,
                  useOwnLayer: false,
                  onTap: () => unawaited(ctrl.refreshSubagentsOnly()),
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

/// Reusable card also embedded in Session Detail Workbench's「子代理」tab.
class SubagentLineageCard extends StatelessWidget {
  const SubagentLineageCard({
    super.key,
    required this.item,
    required this.onPrompt,
    required this.onInterrupt,
    this.onInspect,
  });

  final SubagentItem item;
  final VoidCallback onPrompt;
  final VoidCallback? onInterrupt;
  final VoidCallback? onInspect;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final st = item.status.toLowerCase();
    final isRunning = st == 'running';
    final isFailed = st == 'failed' || st == 'error';
    final isInterrupted = st == 'interrupted' || st == 'cancelled' || st == 'canceled';
    final statusColor = isRunning
        ? t.primary
        : (isFailed ? t.err : (isInterrupted ? t.warn : t.ok));
    final statusLabel = isRunning
        ? '执行中'
        : (isFailed ? '失败' : (isInterrupted ? '已中断' : '已完成'));
    final metaLine = [
      if (item.role.isNotEmpty) item.role,
      if (item.model.isNotEmpty) item.model,
      if (item.durationLabel.isNotEmpty) item.durationLabel,
    ].join(' · ');

    return GrassBagCard(
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GrassBagSquircleIcon(
                icon: CupertinoIcons.arrow_branch,
                color: statusColor,
                size: 36,
                iconSize: 17,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
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
                        ),
                        const SizedBox(width: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: t.isDark ? 0.22 : 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            statusLabel,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: statusColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      metaLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: t.text3),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            item.taskSummary,
            style: TextStyle(fontSize: 13.5, height: 1.42, color: t.text),
          ),
          if (item.worktreeBranch != null && item.worktreeBranch!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: t.fill1,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.tuningfork, size: 12, color: t.dusk),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      '独立分支：${item.worktreeBranch}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: t.text2),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (item.outputPreview.isNotEmpty) ...[
            const SizedBox(height: 9),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: t.fill1,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                item.outputPreview,
                style: TextStyle(fontSize: 12, height: 1.4, color: t.text2),
              ),
            ),
          ],
          const SizedBox(height: 11),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              GrassBagSpringTap(
                onTap: onPrompt,
                haptic: true,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: t.primarySoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.chat_bubble_text_fill, size: 12, color: t.primary),
                      const SizedBox(width: 5),
                      Text(
                        '补充指令',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.primary),
                      ),
                    ],
                  ),
                ),
              ),
              if (onInspect != null)
                GrassBagSpringTap(
                  onTap: onInspect!,
                  haptic: true,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: t.fill1,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.arrow_up_right_square, size: 12, color: t.text2),
                        const SizedBox(width: 5),
                        Text(
                          '查看会话',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text2),
                        ),
                      ],
                    ),
                  ),
                ),
              if (onInterrupt != null)
                GrassBagSpringTap(
                  onTap: onInterrupt!,
                  haptic: true,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: t.errSoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.stop_circle_fill, size: 12, color: t.err),
                        const SizedBox(width: 5),
                        Text(
                          '中断',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.err),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SubagentPromptDialogBody extends ConsumerStatefulWidget {
  const _SubagentPromptDialogBody({required this.sub});
  final SubagentItem sub;

  @override
  ConsumerState<_SubagentPromptDialogBody> createState() => _SubagentPromptDialogBodyState();
}

class _SubagentPromptDialogBodyState extends ConsumerState<_SubagentPromptDialogBody> {
  final _textCtrl = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final msg = _textCtrl.text.trim();
    if (msg.isEmpty) {
      setState(() => _err = '请输入要发送给子代理的指令');
      return;
    }
    ref.read(appProvider.notifier).promptSubagent(widget.sub.id, msg);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagTextField(
          controller: _textCtrl,
          autofocus: true,
          insideGlass: true,
          minLines: 2,
          maxLines: 4,
          hasError: _err != null,
          onChanged: (_) {
            if (_err != null) setState(() => _err = null);
          },
          placeholder: '例如：顺便检查边界条件并补一条回归单测…',
          fontSize: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        if (_err != null) ...[
          const SizedBox(height: 6),
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
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: '发送指令',
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
