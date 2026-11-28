import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/file_preview_sheet.dart';
import '../common/grassbag_sheets.dart';
import '../common/preview_highlight_utils.dart';
import '../features/jobs_page.dart';
import '../features/subagents_page.dart';

export '../common/file_preview_sheet.dart' show showWorkspaceFilePreviewSheet;

/// Session Detail (Phone Full-Screen Page) & Docked Right Workbench (Tablet Inspector)
/// implementing all 6 Workbench tabs from `docs/ia-and-flows.md`:
/// `文件 · 改动 · 终端 · 进度 · 轨迹 · 子代理`.
class SessionDetailContent extends ConsumerStatefulWidget {
  const SessionDetailContent({
    super.key,
    required this.isTabletPane,
    required this.onOpenTerminal,
    required this.onOpenWebUi,
    required this.onOpenHostDetail,
    this.onClose,
    this.initialTab = 0,
  });

  final bool isTabletPane;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenWebUi;
  final ValueChanged<String> onOpenHostDetail;
  final VoidCallback? onClose;
  final int initialTab;

  @override
  ConsumerState<SessionDetailContent> createState() => _SessionDetailContentState();
}

class _SessionDetailContentState extends ConsumerState<SessionDetailContent> {
  late int _tab;
  final ScrollController _scrollCtrl = ScrollController();
  final Map<int, double> _tabScrollOffsets = {};
  final List<WorkspaceFileNode> _dirStack = [];
  final TextEditingController _todoCtrl = TextEditingController();
  final TextEditingController _fileFilterCtrl = TextEditingController();
  final Set<String> _collapsedDiffPaths = <String>{};
  String _fileFilterQuery = '';
  bool _showAllTimelineSteps = false;
  bool _showAllTurnsUsage = false;
  bool _compacting = false;
  bool _forking = false;
  bool _loadingDiffs = false;
  String? _pendingDiffScope;
  bool _loadingTerminals = false;
  int _diffLoadSeq = 0;
  int _termLoadSeq = 0;
  List<Map<String, dynamic>> _liveTerminals = const [];
  bool _loadingFiles = false;

  static const _tabLabels = ['文件', '改动', '终端', '进度', '轨迹', '子代理'];
  late final List<GlobalKey> _tabChipKeys = List.generate(_tabLabels.length, (_) => GlobalKey());

  Future<bool> _refreshFiles({String? path}) async {
    final s = ref.read(appProvider);
    final targetPath = path ??
        (_dirStack.isNotEmpty
            ? _dirStack.last.path
            : (s.workspaceCurrentPath.isEmpty ? '.' : s.workspaceCurrentPath));
    if (mounted) setState(() => _loadingFiles = true);
    try {
      final ok = await ref.read(appProvider.notifier).loadWorkspaceDirectory(path: targetPath);
      if (ok && mounted && _dirStack.isNotEmpty) {
        setState(() => _dirStack.clear());
      }
      return ok;
    } finally {
      if (mounted) setState(() => _loadingFiles = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab.clamp(0, _tabLabels.length - 1);
    if (_tab == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final s = ref.read(appProvider);
        if (s.workspaceFiles.isEmpty && s.connectionPhase == ConnectionPhase.connected) {
          unawaited(_refreshFiles());
        }
      });
    } else if (_tab == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_refreshDiffs(ref.read(appProvider).activeDiffScope, silent: true));
      });
    } else if (_tab == 2) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_refreshTerminals());
      });
    }
  }

  Future<void> _refreshTerminals() async {
    final client = ref.read(appProvider.notifier).liveClient;
    final reqHostId = ref.read(appProvider).activeHostId;
    final reqSid = ref.read(appProvider).activeSessionId;
    final seq = ++_termLoadSeq;
    if (client == null) {
      if (mounted && (_liveTerminals.isNotEmpty || _loadingTerminals)) {
        setState(() {
          _liveTerminals = const [];
          _loadingTerminals = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _loadingTerminals = true);
    try {
      final resp = await client.listTerminals(
        sessionId: (reqSid != null && !reqSid.startsWith('pending-session-')) ? reqSid : null,
      );
      if (!mounted ||
          seq != _termLoadSeq ||
          !identical(ref.read(appProvider.notifier).liveClient, client) ||
          ref.read(appProvider).activeHostId != reqHostId ||
          ref.read(appProvider).activeSessionId != reqSid) {
        return;
      }
      final raw = resp['terminals'] ?? resp['items'] ?? resp['list'];
      final list = raw is List
          ? raw
              .whereType<Map<Object?, Object?>>()
              .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
              .toList(growable: false)
          : const <Map<String, dynamic>>[];
      setState(() => _liveTerminals = list);
    } catch (_) {
      // Keep existing list on transient error
    } finally {
      if (mounted && seq == _termLoadSeq) setState(() => _loadingTerminals = false);
    }
  }

  Future<void> _closeRemoteTerminal(String termId) async {
    final client = ref.read(appProvider.notifier).liveClient;
    if (client == null || termId.isEmpty) return;
    final reqHostId = ref.read(appProvider).activeHostId;
    final reqSid = ref.read(appProvider).activeSessionId;
    try {
      await client.closeTerminal(
        termId,
        sessionId: (reqSid != null && !reqSid.startsWith('pending-session-')) ? reqSid : null,
      );
      if (!mounted ||
          !identical(ref.read(appProvider.notifier).liveClient, client) ||
          ref.read(appProvider).activeHostId != reqHostId) {
        return;
      }
      ref.read(appProvider.notifier).showToast('已关闭终端 $termId');
      await _refreshTerminals();
    } catch (_) {
      if (mounted) {
        ref.read(appProvider.notifier).showToast('关闭终端失败', tone: ToastTone.warn);
      }
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _todoCtrl.dispose();
    _fileFilterCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshDiffs(String scope, {bool silent = false}) async {
    final seq = ++_diffLoadSeq;
    if (mounted) {
      setState(() {
        _loadingDiffs = true;
        _pendingDiffScope = scope;
      });
    }
    try {
      await ref.read(appProvider.notifier).refreshWorkspaceDiffs(silent: silent, scope: scope);
    } finally {
      if (mounted && seq == _diffLoadSeq) {
        setState(() {
          _loadingDiffs = false;
          _pendingDiffScope = null;
        });
      }
    }
  }

  int _prevTab = 0;

  void _selectTab(int i) {
    if (_tab == i) return;
    if (_scrollCtrl.hasClients) {
      _tabScrollOffsets[_tab] = _scrollCtrl.offset;
    }
    setState(() {
      _prevTab = _tab;
      _tab = i;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final chipCtx = _tabChipKeys[i].currentContext;
      if (chipCtx != null) {
        Scrollable.ensureVisible(
          chipCtx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      }
      if (_scrollCtrl.hasClients) {
        final target = (_tabScrollOffsets[i] ?? 0.0).clamp(
          0.0,
          _scrollCtrl.position.maxScrollExtent,
        );
        if ((_scrollCtrl.offset - target).abs() > 1.0) {
          if (MediaQuery.disableAnimationsOf(context)) {
            _scrollCtrl.jumpTo(target);
          } else {
            _scrollCtrl.animateTo(
              target,
              duration: const Duration(milliseconds: 170),
              curve: Curves.easeOutCubic,
            );
          }
        }
      }
    });
    if (i == 0) {
      final s = ref.read(appProvider);
      if (s.workspaceFiles.isEmpty && s.connectionPhase == ConnectionPhase.connected) {
        unawaited(_refreshFiles());
      }
    } else if (i == 1) {
      unawaited(_refreshDiffs(ref.read(appProvider).activeDiffScope, silent: true));
    } else if (i == 2) {
      unawaited(_refreshTerminals());
    }
  }

  void _openFilePreview(BuildContext context, WorkspaceFileNode node) {
    showWorkspaceFilePreviewSheet(
      context,
      path: node.path,
      title: node.name,
      inlineContent: node.content,
    );
  }

  void _openDiffRecordSheet(BuildContext context, WorkspaceDiffRecord diff) {
    showDiffSheet(context, diff.path, record: diff);
  }

  void _openAddGoalSheet(BuildContext context, {SessionGoalRecord? existing}) {
    showGrassBagSheet<void>(
      context,
      title: existing != null ? '编辑长期自主目标' : '设定长期自主目标',
      subtitle: '助手将围绕验收标准持续迭代直至全部通过',
      bodyBuilder: (ctx) => _AddGoalSheetBody(existing: existing),
    );
  }

  void _openSubagentPromptSheet(BuildContext context, SubagentItem sub) {
    showGrassBagSheet<void>(
      context,
      title: '向 ${sub.name} 发送补充指令',
      subtitle: '${sub.role} · ${sub.model}',
      bodyBuilder: (ctx) => _SubagentPromptSheetBody(sub: sub),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ConnectionPhase>(
      appProvider.select((s) => s.connectionPhase),
      (prev, next) {
        if (prev != ConnectionPhase.connected && next == ConnectionPhase.connected && mounted) {
          final cur = ref.read(appProvider);
          if (_tab == 0 && cur.workspaceFiles.isEmpty) {
            unawaited(_refreshFiles());
          } else if (_tab == 1 && cur.workspaceDiffs.isEmpty) {
            unawaited(_refreshDiffs(cur.activeDiffScope, silent: true));
          } else if (_tab == 2 && _liveTerminals.isEmpty) {
            unawaited(_refreshTerminals());
          }
        }
      },
    );
    ref.listen<String>(
      appProvider.select((s) => '${s.activeHostId}:${s.activeSessionId}:${s.activeWorkspace}'),
      (prev, next) {
        if (prev != null && prev != next && mounted) {
          setState(() {
            _dirStack.clear();
            _tabScrollOffsets.clear();
            _liveTerminals = const [];
            _showAllTimelineSteps = false;
            _showAllTurnsUsage = false;
          });
          if (_tab == 2) {
            unawaited(_refreshTerminals());
          } else {
            final cur = ref.read(appProvider);
            if (cur.connectionPhase == ConnectionPhase.connected) {
              if (_tab == 0 && cur.workspaceFiles.isEmpty) {
                unawaited(ref.read(appProvider.notifier).loadWorkspaceDirectory(path: '.', silent: true));
              } else if (_tab == 1 && cur.workspaceDiffs.isEmpty) {
                unawaited(ref.read(appProvider.notifier).refreshWorkspaceDiffs(scope: cur.activeDiffScope));
              }
            }
          }
        }
      },
    );
    // Narrow tab-aware subscription: 4Hz `sessionTelemetry` is isolated inside
    // `_WorkbenchTelemetryCard` & Tab 4 (`轨迹`) so Files / Diffs / Terminal / Progress / Subagents
    // NEVER rebuild 4x/sec or re-parse diffs while the assistant is streaming!
    ref.watch(
      appProvider.select(
        (s) {
          final host = s.activeHost;
          final activeSess = s.activeSession;
          return (
            glassTier: s.glassTier,
            activeHostId: s.activeHostId,
            hostName: host.name,
            activeSessionId: s.activeSessionId,
            hasActiveSession: activeSess != null,
            activeSessionTitle: activeSess?.title,
            isStreaming: s.isStreaming,
            activeWorkspace: s.activeWorkspaceDisplayName,
            tabPayload: switch (_tab) {
              0 => (
                  s.workspaceFiles,
                  s.workspaceCurrentPath,
                  s.turns.length,
                  s.isStreaming
                      ? -1
                      : s.turns.fold<int>(0, (acc, turn) => acc + turn.deliverables.length),
                  s.connectionPhase,
                ),
              1 => (s.workspaceDiffs, s.activeDiffScope, s.connectionPhase),
              2 => (s.jobs, s.connectionPhase),
              3 => (s.todos, s.goals, s.connectionPhase),
              // Tab 4 (`轨迹`) isolates `s.turns` & `sessionTelemetry` inside a dedicated leaf
              // Consumer below so streaming tokens NEVER rebuild the whole Workbench page!
              4 => s.connectionPhase,
              _ => (s.subagents, s.connectionPhase),
            },
          );
        },
      ),
    );
    final state = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final host = state.activeHost;
    final topPad = MediaQuery.viewPaddingOf(context).top;
    final botPad = MediaQuery.viewPaddingOf(context).bottom;
    final tabletImeBot = widget.isTabletPane ? MediaQuery.viewInsetsOf(context).bottom : 0.0;
    final body = ListView(
      controller: _scrollCtrl,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: EdgeInsets.fromLTRB(
        16,
        widget.isTabletPane ? 4 : topPad + 76,
        16,
        36 + botPad + tabletImeBot,
      ),
      children: [
        RepaintBoundary(
          child: _WorkbenchTelemetryCard(
            isTimelineTab: _tab == 4,
            onOpenTimeline: () => _selectTab(4),
          ),
        ),
        if (state.activeSession != null) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: GrassBagSecondaryGlassButton(
                  label: '重命名对话',
                  icon: CupertinoIcons.pencil,
                  height: 34,
                  tier: state.glassTier,
                  insideGlass: true,
                  onTap: () {
                    final active = ref.read(appProvider).activeSession;
                    if (active != null) {
                      showRenameSessionSheet(context, ref, active);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GrassBagSecondaryGlassButton(
                  label: _forking ? '分支中…' : '分支副本',
                  icon: CupertinoIcons.arrow_branch,
                  height: 34,
                  tier: state.glassTier,
                  insideGlass: true,
                  enabled: !state.isStreaming && !_forking,
                  onTap: (state.isStreaming || _forking)
                      ? null
                      : () async {
                          final navigator = Navigator.of(context);
                          setState(() => _forking = true);
                          try {
                            final ok = await ctrl.forkActiveSession();
                            if (ok && mounted && !widget.isTabletPane) {
                              navigator.pop();
                            }
                          } finally {
                            if (mounted) setState(() => _forking = false);
                          }
                        },
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),

        // Real Kyant0 Liquid Glass scrollable segmented tab bar!
        GrassBagSegmentedControl(
          labels: _tabLabels,
          selectedIndex: _tab,
          tier: state.glassTier,
          height: 38,
          onSelected: _selectTab,
        ),
        const SizedBox(height: 8),

        GrassBagDirectionalTabSwitcher(
          direction: _tab >= _prevTab ? 1 : -1,
          duration: const Duration(milliseconds: 175),
          child: KeyedSubtree(
            key: ValueKey('workbench-tab-$_tab'),
            child: switch (_tab) {
              0 => _buildFilesTab(context, state, ctrl, t),
              1 => _buildDiffsTab(context, state, t),
              2 => _buildTerminalTab(context, state, ctrl, t),
              3 => _buildProgressTab(context, state, ctrl, t),
              4 => RepaintBoundary(
                  child: Consumer(
                    builder: (ctx, tabRef, _) {
                      tabRef.watch(
                        appProvider.select(
                          (s) {
                            final lastTurn = s.turns.isEmpty ? null : s.turns.last;
                            return (
                              turnsLen: s.turns.length,
                              lastTurnId: lastTurn?.turnId,
                              lastTurnStatus: lastTurn?.status,
                              lastTurnStepCount: lastTurn?.steps.length ?? 0,
                              lastTurnTokens: (lastTurn?.usage?.inputTokens ?? 0) +
                                  (lastTurn?.usage?.outputTokens ?? 0),
                              contextBreakdown: s.contextBreakdown,
                              sessionTelemetry: s.sessionTelemetry,
                              contextPct: s.contextPct,
                              contextUsedK: s.contextUsedK,
                              contextMaxK: s.contextMaxK,
                              isStreaming: s.isStreaming,
                              modelName: s.modelName,
                              modelEffort: s.modelEffort,
                            );
                          },
                        ),
                      );
                      return _buildTimelineTab(ctx, tabRef.read(appProvider), ctrl, t);
                    },
                  ),
                ),
              _ => _buildSubagentsTab(context, state, ctrl, t),
            },
          ),
        ),
      ],
    );

    if (widget.isTabletPane) {
      return Container(
        width: 348,
        decoration: BoxDecoration(
          color: t.sidebarDocked,
          border: Border(left: BorderSide(color: t.sep, width: 0.5)),
        ),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, topPad + 8, 12, 8),
              child: SizedBox(
                height: 44,
                child: Row(
                  children: [
                    Text(
                      '工作台',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        color: t.text,
                      ),
                    ),
                    const Spacer(),
                    GrassBagSpringTap(
                      onTap: widget.onOpenTerminal,
                      pressedScale: 0.94,
                      enablePointerGlow: false,
                      haptic: true,
                      child: GrassBagFresnelGlassSurface(
                        isPill: true,
                        innerWell: true,
                        interactive: true,
                        tintColor: t.primarySoft,
                        height: 34,
                        padding: const EdgeInsets.symmetric(horizontal: 11),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.chevron_left_slash_chevron_right,
                              size: 14,
                              color: t.primary,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '终端',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: t.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: '收起工作台',
                      child: GrassBagSpringTap(
                        onTap: () => widget.onClose?.call(),
                        pressedScale: 0.88,
                        haptic: true,
                        child: GrassBagFresnelGlassSurface(
                          isCircle: true,
                          innerWell: true,
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
                          child: Icon(CupertinoIcons.sidebar_right, size: 17, color: t.primary),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: body,
            ),
          ],
        ),
      );
    }

    return GrassBagGlassPage(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(
              child: body,
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GrassBagUnifiedHeader(
                title: '对话详情',
                subtitle: state.activeWorkspaceDisplayName.isNotEmpty
                    ? '${host.name} · ${state.activeWorkspaceDisplayName}'
                    : host.name,
                tier: state.glassTier,
                onBack: () => Navigator.of(context).pop(),
                trailing: GrassBagGlassCircleButton(
                  icon: CupertinoIcons.chevron_left_slash_chevron_right,
                  tooltip: '打开终端',
                  iconSize: 18,
                  iconColor: t.primary,
                  tier: state.glassTier,
                  useOwnLayer: false,
                  onTap: widget.onOpenTerminal,
                ),
              ),
            ),
            GrassBagToastOverlay(bottomOffset: 28 + MediaQuery.paddingOf(context).bottom),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 0: 文件 (Navigable Directory Tree + Deliverables)
  // ---------------------------------------------------------------------------
  Widget _buildFilesTab(
    BuildContext context,
    GrassBagAppState state,
    GrassBagController ctrl,
    GrassBagTokens t,
  ) {
    final currentNodes = _dirStack.isEmpty ? state.workspaceFiles : _dirStack.last.children;
    final rawRoot = state.activeSession?.cwd ??
        state.activeWorkspaceItem?.path ??
        (state.activeWorkspaceDisplayName.isEmpty ? '当前工作区' : state.activeWorkspaceDisplayName);
    final shortRoot = rawRoot.replaceFirst(RegExp(r'^/(?:Users|home)/[^/]+/'), '~/');
    final relPath = state.workspaceCurrentPath;
    final stackSubPath = _dirStack.map((d) => d.name).join('/');
    final combinedRel = [
      if (relPath.isNotEmpty) relPath,
      if (stackSubPath.isNotEmpty) stackSubPath,
    ].join('/');
    final currentBreadcrumb = combinedRel.isEmpty ? shortRoot : '$shortRoot/$combinedRel';

    final liveDeliverables = [
      for (final turn in state.turns) ...turn.deliverables,
    ];

    void goParent() {
      if (_dirStack.isNotEmpty) {
        setState(() => _dirStack.removeLast());
        return;
      }
      if (relPath.isNotEmpty) {
        final idx = relPath.lastIndexOf('/');
        final parent = idx > 0 ? relPath.substring(0, idx) : '.';
        unawaited(_refreshFiles(path: parent));
      }
    }

    final filterQ = _fileFilterQuery.trim().toLowerCase();
    final filteredNodes = filterQ.isEmpty
        ? currentNodes
        : currentNodes
            .where((n) =>
                n.name.toLowerCase().contains(filterQ) ||
                n.path.toLowerCase().contains(filterQ))
            .toList(growable: false);

    // Cross-reference Git modified files so the Files tab highlights modified items!
    final diffByNormPath = <String, WorkspaceDiffRecord>{};
    for (final d in state.workspaceDiffs) {
      final norm = d.path
          .trim()
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'^\./+'), '')
          .replaceFirst(RegExp(r'^/+'), '');
      diffByNormPath[norm] = d;
    }
    WorkspaceDiffRecord? diffForNode(WorkspaceFileNode node) {
      if (node.isDir || diffByNormPath.isEmpty) return null;
      final norm = node.path
          .trim()
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'^\./+'), '')
          .replaceFirst(RegExp(r'^/+'), '');
      final exact = diffByNormPath[norm];
      if (exact != null) return exact;
      for (final entry in diffByNormPath.entries) {
        if (norm.endsWith('/${entry.key}') || entry.key.endsWith('/$norm')) {
          return entry.value;
        }
      }
      return null;
    }

    final relSegs = relPath.split('/').where((s) => s.isNotEmpty).toList();
    final stackSegs = _dirStack.map((d) => d.name).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Clickable multi-segment path breadcrumbs
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GrassBagSpringTap(
                        pressedScale: 0.95,
                        onTap: () {
                          if (_dirStack.isNotEmpty) setState(() => _dirStack.clear());
                          if (relPath.isNotEmpty) unawaited(_refreshFiles(path: '.'));
                        },
                        child: GrassBagFresnelGlassSurface(
                          isPill: true,
                          innerWell: true,
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(CupertinoIcons.folder_fill, size: 11.5, color: t.primary),
                              const SizedBox(width: 4),
                              Text(
                                shortRoot,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11.2,
                                  fontWeight: FontWeight.w600,
                                  color: t.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      for (var i = 0; i < relSegs.length; i++) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Icon(CupertinoIcons.chevron_right, size: 10, color: t.text3),
                        ),
                        GrassBagSpringTap(
                          pressedScale: 0.95,
                          onTap: () {
                            if (_dirStack.isNotEmpty) setState(() => _dirStack.clear());
                            final target = relSegs.sublist(0, i + 1).join('/');
                            if (target != relPath) unawaited(_refreshFiles(path: target));
                          },
                          child: GrassBagFresnelGlassSurface(
                            isPill: true,
                            innerWell: true,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5),
                            child: Text(
                              relSegs[i],
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.2,
                                fontWeight: (i == relSegs.length - 1 && stackSegs.isEmpty)
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: (i == relSegs.length - 1 && stackSegs.isEmpty)
                                    ? t.text
                                    : t.text2,
                              ),
                            ),
                          ),
                        ),
                      ],
                      for (var i = 0; i < stackSegs.length; i++) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Icon(CupertinoIcons.chevron_right, size: 10, color: t.text3),
                        ),
                        GrassBagSpringTap(
                          pressedScale: 0.95,
                          onTap: () {
                            if (i < _dirStack.length - 1) {
                              setState(() => _dirStack.removeRange(i + 1, _dirStack.length));
                            }
                          },
                          child: GrassBagFresnelGlassSurface(
                            isPill: true,
                            innerWell: true,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5),
                            child: Text(
                              stackSegs[i],
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.2,
                                fontWeight: i == stackSegs.length - 1
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: i == stackSegs.length - 1 ? t.text : t.text2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GrassBagSpringTap(
                enabled: !_loadingFiles,
                enablePointerGlow: false,
                haptic: true,
                onTap: () => unawaited(_refreshFiles()),
                child: GrassBagFresnelGlassSurface(
                  isPill: true,
                  innerWell: true,
                  interactive: !_loadingFiles,
                  tintColor: t.primarySoft,
                  padding: const EdgeInsets.symmetric(horizontal: 10.5, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_loadingFiles)
                        GrassBagActivityIndicator(radius: 6, color: t.primary)
                      else
                        Icon(CupertinoIcons.refresh, size: 12.5, color: t.primary),
                      const SizedBox(width: 4),
                      Text(
                        '刷新',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_dirStack.isNotEmpty || relPath.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GrassBagSpringTap(
              onTap: goParent,
              child: GrassBagFresnelGlassSurface(
                borderRadius: 14,
                innerWell: true,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7.5),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.chevron_back, size: 13.5, color: t.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '返回上一级 · $currentBreadcrumb',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.8, fontWeight: FontWeight.w600, color: t.primary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        if (currentNodes.length > 3 || _fileFilterQuery.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GrassBagTextField(
              controller: _fileFilterCtrl,
              placeholder: '筛选当前目录文件 (${currentNodes.length})…',
              insideGlass: false,
              fontSize: 12.5,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              prefix: Padding(
                padding: const EdgeInsets.only(left: 2, right: 6),
                child: Icon(CupertinoIcons.search, size: 13.5, color: t.text3),
              ),
              suffix: _fileFilterQuery.isEmpty
                  ? null
                  : GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        _fileFilterCtrl.clear();
                        setState(() => _fileFilterQuery = '');
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(CupertinoIcons.xmark_circle_fill, size: 14, color: t.text3),
                      ),
                    ),
              onChanged: (v) => setState(() => _fileFilterQuery = v),
            ),
          ),
        GrassBagGroupedSection(
          dividerIndent: 58,
          children: filteredNodes.isEmpty
              ? [
                  if (_loadingFiles)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: GrassBagActivityIndicator(color: t.primary)),
                    )
                  else if (currentNodes.isNotEmpty && filterQ.isNotEmpty)
                    GrassBagListTile(
                      leading: GrassBagSquircleIcon(
                        icon: CupertinoIcons.search,
                        color: t.text3,
                        size: 34,
                        iconSize: 16,
                      ),
                      title: Text('未找到包含「$_fileFilterQuery」的文件'),
                      subtitle: const Text('轻点清除筛选条件'),
                      onTap: () {
                        _fileFilterCtrl.clear();
                        setState(() => _fileFilterQuery = '');
                      },
                    )
                  else if (state.connectionPhase != ConnectionPhase.connected)
                    GrassBagListTile(
                      leading: GrassBagSquircleIcon(
                        icon: CupertinoIcons.wifi_exclamationmark,
                        color: t.warn,
                        size: 34,
                        iconSize: 16,
                      ),
                      title: const Text('尚未连接到 DSH 主机'),
                      subtitle: const Text('连接在线主机后即可浏览工作区文件与代码改动'),
                      trailing: Text('重试', style: TextStyle(fontSize: 12, color: t.primary)),
                      onTap: () => ctrl.probeAndRefreshHost(state.activeHostId),
                    )
                  else ...[
                    GrassBagListTile(
                      leading: GrassBagSquircleIcon(
                        icon: CupertinoIcons.folder,
                        color: t.text3,
                        size: 34,
                        iconSize: 16,
                      ),
                      title: const Text('当前目录为空或尚未加载'),
                      subtitle: const Text('点按刷新从 DSH 工作区读取文件列表'),
                      trailing: Text('刷新', style: TextStyle(fontSize: 12, color: t.primary)),
                      onTap: () => unawaited(_refreshFiles(path: relPath.isEmpty ? '.' : relPath)),
                    ),
                    GrassBagListTile(
                      leading: GrassBagSquircleIcon(
                        icon: CupertinoIcons.folder_badge_plus,
                        color: t.primary,
                        size: 34,
                        iconSize: 16,
                      ),
                      title: const Text('切换或挂载其他工作区'),
                      subtitle: const Text('选择任意本地或远程项目文件夹'),
                      showChevron: true,
                      onTap: () => showWorkspaceSheet(context, ref),
                    ),
                  ],
                ]
              : [
                  for (final node in filteredNodes)
                    () {
                      final nodeDiff = diffForNode(node);
                      final fKind = node.isDir ? null : classifyPreviewFile(node.path);
                      final iconColor = node.isDir
                          ? t.primary
                          : switch (fKind) {
                              PreviewFileKind.rasterImage || PreviewFileKind.svg => t.ok,
                              PreviewFileKind.markdown => t.primary,
                              PreviewFileKind.json || PreviewFileKind.csv => t.warn,
                              PreviewFileKind.binary => t.text3,
                              _ => t.dusk,
                            };
                      return GrassBagListTile(
                        leading: GrassBagSquircleIcon(
                          icon: node.isDir
                              ? CupertinoIcons.folder_fill
                              : previewFileIcon(node.path),
                          color: iconColor,
                          size: 34,
                          iconSize: 16,
                        ),
                        title: Text(
                          node.isDir ? '${node.name}/' : node.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace'),
                        ),
                        subtitle: Text(
                          node.subtitle.isEmpty ? node.path : node.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: nodeDiff != null
                            ? GrassBagFresnelGlassSurface(
                                isPill: true,
                                innerWell: true,
                                tintColor: nodeDiff.summary == '新增'
                                    ? t.okSoft
                                    : (nodeDiff.summary == '已删除' ? t.errSoft : t.warnSoft),
                                padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2),
                                child: Text(
                                  nodeDiff.summary == '新增'
                                      ? 'A +${nodeDiff.added}'
                                      : (nodeDiff.summary == '已删除'
                                          ? 'D -${nodeDiff.removed}'
                                          : 'M +${nodeDiff.added}'),
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: nodeDiff.summary == '新增'
                                        ? t.ok
                                        : (nodeDiff.summary == '已删除' ? t.err : t.warn),
                                  ),
                                ),
                              )
                            : null,
                        showChevron: true,
                        onTap: () {
                          if (node.isDir) {
                            if (_fileFilterQuery.isNotEmpty) {
                              _fileFilterCtrl.clear();
                              _fileFilterQuery = '';
                            }
                            if (node.children.isNotEmpty) {
                              setState(() => _dirStack.add(node));
                            } else {
                              unawaited(_refreshFiles(path: node.path));
                            }
                          } else {
                            _openFilePreview(context, node);
                          }
                        },
                      );
                    }(),
                ],
        ),
        if (liveDeliverables.isNotEmpty) ...[
          const SizedBox(height: 14),
          GrassBagGroupedSection(
            header: '本轮生成产物 (${liveDeliverables.length})',
            dividerIndent: 58,
            children: [
              for (final d in liveDeliverables)
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.doc_richtext,
                    color: t.ok,
                    size: 34,
                    iconSize: 16,
                  ),
                  title: Text(
                    (d['name'] ?? d['path'] ?? '产物').toString(),
                    style: const TextStyle(fontSize: 13.5),
                  ),
                  subtitle: Text(
                    '${d['note'] ?? ''} ${d['size'] ?? ''}'.trim(),
                  ),
                  trailing: Text(
                    '预览 ›',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.primary),
                  ),
                  onTap: () => showDeliverablePreviewSheet(
                    context,
                    ref,
                    name: (d['name'] ?? d['path'] ?? '产物').toString(),
                    path: d['path']?.toString(),
                    subtitle: (d['note'] ?? '工作区文件').toString(),
                    sizeLabel: (d['size'] ?? '').toString(),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 1: 改动 (Full Unified Syntax-Colored Diff Viewer + Scope Filter)
  // ---------------------------------------------------------------------------
  Widget _buildDiffsTab(BuildContext context, GrassBagAppState state, GrassBagTokens t) {
    final diffScope = state.activeDiffScope;
    const scopes = [
      ('uncommitted', '全部未提交'),
      ('unstaged', '未暂存'),
      ('staged', '已暂存'),
    ];
    final scopeBar = Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
              child: Row(
                children: [
                  for (final item in scopes) ...[
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: GrassBagFilterChip(
                        label: item.$2,
                        selected: (_pendingDiffScope ?? diffScope) == item.$1,
                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5.5),
                        fontSize: 11.5,
                        onTap: () {
                          if ((_pendingDiffScope ?? diffScope) == item.$1 && !_loadingDiffs) return;
                          unawaited(_refreshDiffs(item.$1));
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          GrassBagSpringTap(
            enabled: !_loadingDiffs,
            enablePointerGlow: false,
            haptic: true,
            onTap: () => unawaited(_refreshDiffs(diffScope)),
            child: GrassBagFresnelGlassSurface(
              isPill: true,
              innerWell: true,
              interactive: !_loadingDiffs,
              tintColor: t.primarySoft,
              padding: const EdgeInsets.symmetric(horizontal: 10.5, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_loadingDiffs)
                    GrassBagActivityIndicator(radius: 6, color: t.primary)
                  else
                    Icon(CupertinoIcons.refresh, size: 12.5, color: t.primary),
                  const SizedBox(width: 4),
                  Text('刷新', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.primary)),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    if (state.workspaceDiffs.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          scopeBar,
          if (_loadingDiffs)
            GrassBagCard(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
              child: Center(child: GrassBagActivityIndicator(color: t.primary)),
            )
          else if (state.connectionPhase != ConnectionPhase.connected)
            GrassBagCard(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              child: Column(
                children: [
                  Icon(CupertinoIcons.wifi_exclamationmark, size: 30, color: t.warn),
                  const SizedBox(height: 8),
                  Text(
                    '尚未连接到 DSH 主机',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: t.text2),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '连接在线主机后即可扫描当前工作区 Git 改动',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: t.text3),
                  ),
                  const SizedBox(height: 12),
                  GrassBagSecondaryGlassButton(
                    label: '重试连接',
                    icon: CupertinoIcons.refresh,
                    tier: state.glassTier,
                    insideGlass: true,
                    height: 36,
                    onTap: () => ref.read(appProvider.notifier).probeAndRefreshHost(state.activeHostId),
                  ),
                ],
              ),
            )
          else
            GrassBagCard(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              child: Column(
                children: [
                  Icon(CupertinoIcons.checkmark_seal, size: 30, color: t.text3),
                  const SizedBox(height: 8),
                  Text(
                    diffScope == 'staged'
                        ? '当前暂存区没有改动文件'
                        : (diffScope == 'unstaged' ? '当前工作树没有未暂存改动' : '当前工作区没有未提交的文件改动'),
                    style: TextStyle(fontSize: 13.5, color: t.text2),
                  ),
                  const SizedBox(height: 12),
                  GrassBagSecondaryGlassButton(
                    label: '重新扫描 Git 改动',
                    icon: CupertinoIcons.refresh,
                    tier: state.glassTier,
                    insideGlass: true,
                    height: 36,
                    onTap: () => unawaited(_refreshDiffs(diffScope)),
                  ),
                ],
              ),
            ),
        ],
      );
    }
    final totalAdded = state.workspaceDiffs.fold<int>(0, (sum, d) => sum + d.added);
    final totalRemoved = state.workspaceDiffs.fold<int>(0, (sum, d) => sum + d.removed);
    final allCollapsed = state.workspaceDiffs.isNotEmpty &&
        state.workspaceDiffs.every((d) => _collapsedDiffPaths.contains(d.path));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        scopeBar,
        if (_loadingDiffs)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GrassBagProgressBar(
              height: 3.5,
              color: t.primary,
              trackColor: t.fill1,
            ),
          ),
        // Aggregate Diff stats + expand/collapse all toggle
        Padding(
          padding: const EdgeInsets.only(left: 2, right: 2, bottom: 10),
          child: Row(
            children: [
              Text(
                '${state.workspaceDiffs.length} 个改动文件',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text3),
              ),
              const SizedBox(width: 8),
              GrassBagFresnelGlassSurface(
                isPill: true,
                innerWell: true,
                tintColor: t.okSoft,
                padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2),
                child: Text(
                  '+$totalAdded',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10.8,
                    fontWeight: FontWeight.w700,
                    color: t.ok,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              GrassBagFresnelGlassSurface(
                isPill: true,
                innerWell: true,
                tintColor: t.errSoft,
                padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2),
                child: Text(
                  '-$totalRemoved',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10.8,
                    fontWeight: FontWeight.w700,
                    color: t.err,
                  ),
                ),
              ),
              const Spacer(),
              if (state.workspaceDiffs.length > 1)
                GrassBagSpringTap(
                  pressedScale: 0.94,
                  haptic: true,
                  onTap: () {
                    setState(() {
                      if (allCollapsed) {
                        _collapsedDiffPaths.clear();
                      } else {
                        _collapsedDiffPaths.addAll(state.workspaceDiffs.map((d) => d.path));
                      }
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      allCollapsed ? '全部展开' : '全部收起',
                      style: TextStyle(fontSize: 11.8, fontWeight: FontWeight.w600, color: t.primary),
                    ),
                  ),
                ),
            ],
          ),
        ),
        for (final diff in state.workspaceDiffs) ...[
          () {
            final collapsed = _collapsedDiffPaths.contains(diff.path);
            final statusColor = switch (diff.summary) {
              '新增' || '未跟踪' => t.ok,
              '已删除' => t.err,
              '重命名' => t.warn,
              _ => t.primary,
            };
            final statusSoft = switch (diff.summary) {
              '新增' || '未跟踪' => t.okSoft,
              '已删除' => t.errSoft,
              '重命名' => t.warnSoft,
              _ => t.primarySoft,
            };
            return RepaintBoundary(
              child: GrassBagCard(
                padding: const EdgeInsets.all(13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        GrassBagSpringTap(
                          pressedScale: 0.88,
                          enablePointerGlow: false,
                          haptic: true,
                          onTap: () {
                            setState(() {
                              if (collapsed) {
                                _collapsedDiffPaths.remove(diff.path);
                              } else {
                                _collapsedDiffPaths.add(diff.path);
                              }
                            });
                          },
                          child: SizedBox(
                            width: 34,
                            height: 36,
                            child: Center(
                              child: AnimatedRotation(
                                turns: collapsed ? 0.0 : 0.25,
                                duration: GrassBagMotion.duration(
                                  context,
                                  const Duration(milliseconds: 210),
                                ),
                                curve: Curves.easeOutCubic,
                                child: Icon(
                                  CupertinoIcons.chevron_right,
                                  size: 13.5,
                                  color: t.text3,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GrassBagSpringTap(
                            pressedScale: 0.985,
                            haptic: true,
                            onTap: () => _openDiffRecordSheet(context, diff),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  () {
                                    final p = diff.path;
                                    if (p.length <= 36 || !p.contains('/')) return p;
                                    final segs = p.split('/').where((s) => s.isNotEmpty).toList();
                                    if (segs.length < 3) return p;
                                    return '${segs.first}/…/${segs[segs.length - 2]}/${segs.last}';
                                  }(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: t.text,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 5,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    GrassBagFresnelGlassSurface(
                                      isPill: true,
                                      innerWell: true,
                                      tintColor: statusSoft,
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                      child: Text(
                                        diff.summary,
                                        style: TextStyle(
                                          fontSize: 10.2,
                                          fontWeight: FontWeight.w700,
                                          color: statusColor,
                                        ),
                                      ),
                                    ),
                                    if (diff.binary)
                                      GrassBagFresnelGlassSurface(
                                        isPill: true,
                                        innerWell: true,
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                        child: Text(
                                          '二进制',
                                          style: TextStyle(
                                            fontSize: 10.2,
                                            fontWeight: FontWeight.w600,
                                            color: t.text3,
                                          ),
                                        ),
                                      ),
                                    if (diff.previousPath != null &&
                                        diff.previousPath != diff.path)
                                      Text(
                                        '原路径：${diff.previousPath}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 10.5,
                                          color: t.text3,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GrassBagFresnelGlassSurface(
                              isPill: true,
                              innerWell: true,
                              tintColor: t.okSoft,
                              padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2),
                              child: Text(
                                '+${diff.added}',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: t.ok,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            GrassBagFresnelGlassSurface(
                              isPill: true,
                              innerWell: true,
                              tintColor: t.errSoft,
                              padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2),
                              child: Text(
                                '-${diff.removed}',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: t.err,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    GrassBagSmoothDisclosure(
                      expanded: !collapsed,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 9),
                          if (diff.binary || diff.unifiedDiff.trim().isEmpty)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                              decoration: BoxDecoration(
                                color: t.fill1,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: t.sep, width: 0.6),
                              ),
                              child: Text(
                                diff.binary
                                    ? '二进制文件变更，不支持行级 Diff 预览'
                                    : (diff.oversized
                                        ? '补丁体积过大，点击下方全屏或打开完整文件查看'
                                        : '暂无详细文本补丁'),
                                style: TextStyle(fontSize: 11.8, color: t.text3),
                              ),
                            )
                          else
                            _UnifiedDiffCodeBox(diffText: diff.unifiedDiff, maxPreviewLines: 12),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              GrassBagSpringTap(
                                pressedScale: 0.95,
                                haptic: true,
                                onTap: () => showWorkspaceFilePreviewSheet(context, path: diff.path),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                  child: Text(
                                    '完整文件',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: t.text2,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              GrassBagSpringTap(
                                pressedScale: 0.95,
                                haptic: true,
                                onTap: () => _openDiffRecordSheet(context, diff),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                  child: Text(
                                    '全屏查看补丁 ›',
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
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }(),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 2: 终端 (PTY Launch + Active Background Jobs)
  // ---------------------------------------------------------------------------
  Widget _buildTerminalTab(
    BuildContext context,
    GrassBagAppState state,
    GrassBagController ctrl,
    GrassBagTokens t,
  ) {
    final rawCwd = state.activeSession?.cwd ??
        state.activeWorkspaceItem?.path ??
        (state.activeWorkspaceDisplayName.isEmpty ? '~' : state.activeWorkspaceDisplayName);
    final displayCwd = rawCwd.replaceFirst(RegExp(r'^/(?:Users|home)/[^/]+/'), '~/');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagCard(
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  GrassBagSquircleIcon(
                    icon: CupertinoIcons.chevron_left_slash_chevron_right,
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
                          '交互式多标签终端',
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.text),
                        ),
                        Text(
                          '工作目录：$displayCwd',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: t.text3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: GrassBagPrimaryGlassButton(
                  label: '进入全屏终端',
                  icon: CupertinoIcons.play_fill,
                  tier: state.glassTier,
                  insideGlass: true,
                  onTap: widget.onOpenTerminal,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 4, bottom: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '活跃 DSH 终端 (${_liveTerminals.length})',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text3),
                ),
              ),
              GrassBagSpringTap(
                enabled: !_loadingTerminals,
                enablePointerGlow: false,
                haptic: true,
                onTap: () => unawaited(_refreshTerminals()),
                child: GrassBagFresnelGlassSurface(
                  isPill: true,
                  innerWell: true,
                  interactive: !_loadingTerminals,
                  tintColor: t.primarySoft,
                  padding: const EdgeInsets.symmetric(horizontal: 10.5, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_loadingTerminals)
                        GrassBagActivityIndicator(radius: 6.5, color: t.primary)
                      else
                        Icon(CupertinoIcons.refresh, size: 12.5, color: t.primary),
                      const SizedBox(width: 4),
                      Text(
                        '刷新',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        GrassBagGroupedSection(
          children: _liveTerminals.isEmpty
              ? [
                  GrassBagListTile(
                    leading: GrassBagSquircleIcon(
                      icon: CupertinoIcons.chevron_left_slash_chevron_right,
                      color: t.text3,
                      size: 32,
                      iconSize: 15,
                    ),
                    title: const Text('暂无活跃的终端会话'),
                    subtitle: const Text('点此或上方「进入全屏终端」立即新建会话'),
                    showChevron: true,
                    onTap: widget.onOpenTerminal,
                  ),
                ]
              : [
                  for (final term in _liveTerminals)
                    () {
                      final termId = (term['terminalId'] ?? term['id'] ?? '').toString();
                      final title = (term['title'] ?? term['command'] ?? term['shell'] ?? termId).toString();
                      final cwd = (term['cwd'] ?? '').toString();
                      final status = (term['status'] ?? (term['alive'] == false ? 'exited' : 'running')).toString();
                      final statusZh = status == 'exited' ? '已结束' : '运行中';
                      return GrassBagListTile(
                        leading: GrassBagSquircleIcon(
                          icon: CupertinoIcons.chevron_left_slash_chevron_right,
                          color: status == 'exited' ? t.text3 : t.ok,
                          size: 32,
                          iconSize: 15,
                        ),
                        title: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                        ),
                        subtitle: Text(cwd.isNotEmpty ? '$cwd · $statusZh' : '$termId · $statusZh'),
                        onTap: widget.onOpenTerminal,
                        trailing: termId.isNotEmpty
                            ? GrassBagSpringTap(
                                enablePointerGlow: false,
                                haptic: true,
                                onTap: () async {
                                  final ok = await showGrassBagConfirmDialog(
                                    context,
                                    title: '关闭远程终端？',
                                    message: '将终止终端「$title」的 PTY 会话，正在运行的进程可能会退出。',
                                    confirmLabel: '关闭终端',
                                    isDestructive: true,
                                  );
                                  if (ok && mounted) unawaited(_closeRemoteTerminal(termId));
                                },
                                child: GrassBagFresnelGlassSurface(
                                  isPill: true,
                                  innerWell: true,
                                  interactive: true,
                                  tintColor: t.errSoft,
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7.5),
                                  child: Text(
                                    '关闭',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: t.err,
                                    ),
                                  ),
                                ),
                              )
                            : null,
                      );
                    }(),
                ],
        ),
        const SizedBox(height: 14),
        GrassBagGroupedSection(
          header: '关联后台任务 (${state.jobs.length})',
          children: [
            for (final j in state.jobs.take(3))
              () {
                final isRunning = j.status.toLowerCase() == 'running';
                return GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: isRunning
                        ? CupertinoIcons.waveform_path_ecg
                        : CupertinoIcons.checkmark_alt,
                    color: isRunning ? t.ok : t.text3,
                    size: 32,
                    iconSize: 15,
                  ),
                  title: Text(
                    j.command,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                  ),
                  subtitle: Text('${j.cwd} · ${j.startedAtLabel}'),
                  onTap: () => Navigator.of(context).push(
                    GrassBagPageRoute<void>(builder: (_) => const JobsPage()),
                  ),
                  trailing: isRunning
                      ? GrassBagSpringTap(
                          enablePointerGlow: false,
                          haptic: true,
                          onTap: () async {
                            final ok = await showGrassBagConfirmDialog(
                              context,
                              title: '终止后台任务？',
                              message: '确定强制终止正在运行的「${j.command}」吗？',
                              confirmLabel: '确认终止',
                              isDestructive: true,
                            );
                            if (ok) ctrl.killJob(j.id);
                          },
                          child: GrassBagFresnelGlassSurface(
                            isPill: true,
                            innerWell: true,
                            interactive: true,
                            tintColor: t.errSoft,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7.5),
                            child: Text(
                              '终止',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.err),
                            ),
                          ),
                        )
                      : Text('完成', style: TextStyle(fontSize: 11.5, color: t.text3)),
                );
              }(),
            GrassBagListTile(
              title: Text('管理全部后台任务', style: TextStyle(color: t.primary, fontWeight: FontWeight.w600)),
              showChevron: true,
              onTap: () => Navigator.of(context).push(
                GrassBagPageRoute<void>(builder: (_) => const JobsPage()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 3: 进度 (Interactive Todos + Long-Term Autonomous Goals CRUD)
  // ---------------------------------------------------------------------------
  Widget _buildProgressTab(
    BuildContext context,
    GrassBagAppState state,
    GrassBagController ctrl,
    GrassBagTokens t,
  ) {
    final doneCount = state.todos.where((e) => e.done).length;
    final ratio = state.todos.isEmpty ? 0.0 : doneCount / state.todos.length;
    final isLiveAgentSynced = state.connectionPhase == ConnectionPhase.connected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagCard(
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('当前任务清单', style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
                  if (isLiveAgentSynced) ...[
                    const SizedBox(width: 7),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: t.okSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'Agent 实时同步',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: t.ok),
                      ),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    '$doneCount / ${state.todos.length}',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.primary),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              GrassBagProgressBar(
                value: ratio,
                height: 6,
                trackColor: t.fill2,
                color: t.primary,
              ),
              const SizedBox(height: 10),
              if (state.todos.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    isLiveAgentSynced
                        ? '助手在执行多步骤任务时会自动同步拆解步骤到此处。'
                        : '暂无待办项，可在下方手动添加或等待助手在执行中自动拆解步骤。',
                    style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text3),
                  ),
                ),
              for (final item in state.todos)
                () {
                  final rowInner = Row(
                    children: [
                      if (item.active && !item.done)
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: Center(
                            child: GrassBagActivityIndicator(radius: 7, color: t.primary),
                          ),
                        )
                      else
                        Icon(
                          item.done
                              ? CupertinoIcons.checkmark_circle_fill
                              : CupertinoIcons.circle,
                          size: 18,
                          color: item.done ? t.ok : t.text3,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            item.title,
                            style: TextStyle(
                              fontSize: 13.5,
                              decoration: item.done ? TextDecoration.lineThrough : null,
                              color: item.done
                                  ? t.text3
                                  : (item.active ? t.primary : t.text),
                              fontWeight: item.active
                                  ? FontWeight.w600
                                  : (item.done ? FontWeight.w400 : FontWeight.w500),
                            ),
                          ),
                        ),
                        if (item.active && !item.done) ...[
                          const SizedBox(width: 6),
                          GrassBagFresnelGlassSurface(
                            isPill: true,
                            innerWell: true,
                            tintColor: t.primary.withValues(alpha: t.isDark ? 0.28 : 0.14),
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            child: Text(
                              '进行中',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: t.primary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  final Widget rowBody = Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: item.active
                        ? GrassBagFresnelGlassSurface(
                            borderRadius: 13,
                            innerWell: true,
                            tintColor: t.primarySoft,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            child: rowInner,
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                            child: rowInner,
                          ),
                  );
                  if (isLiveAgentSynced) return rowBody;
                  return GrassBagSpringTap(
                    onTap: () => ctrl.toggleTodo(item.id),
                    haptic: true,
                    child: rowBody,
                  );
                }(),
              if (!isLiveAgentSynced) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: GrassBagTextField(
                        controller: _todoCtrl,
                        insideGlass: true,
                        placeholder: '添加新待办项…',
                        fontSize: 13,
                        borderRadius: 12,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                        onSubmitted: (v) {
                          ctrl.addTodo(v);
                          _todoCtrl.clear();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    GrassBagPrimaryGlassButton(
                      label: '添加',
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 15),
                      tier: state.glassTier,
                      insideGlass: true,
                      onTap: () {
                        ctrl.addTodo(_todoCtrl.text);
                        _todoCtrl.clear();
                      },
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Long-term autonomous Goals section (DSH allows 1 active goal per session)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                '长期自主目标 (/goal)',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text3),
              ),
            ),
            if (!state.goals.any((g) => !g.isCompleted))
              GrassBagSpringTap(
                onTap: () => _openAddGoalSheet(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    '+ 新建目标',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.primary),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (state.goals.isEmpty)
          GrassBagCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
            child: Column(
              children: [
                Icon(CupertinoIcons.flag, size: 26, color: t.text3),
                const SizedBox(height: 8),
                Text(
                  '尚未设定长期自主目标',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: t.text2),
                ),
                const SizedBox(height: 4),
                Text(
                  '设定阶段验收标准后，助手会在长任务中持续核对目标达成情况',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: t.text3),
                ),
                const SizedBox(height: 12),
                GrassBagSecondaryGlassButton(
                  label: '新建目标',
                  icon: CupertinoIcons.add,
                  height: 36,
                  tier: state.glassTier,
                  insideGlass: true,
                  accentForeground: true,
                  onTap: () => _openAddGoalSheet(context),
                ),
              ],
            ),
          ),
        for (final g in state.goals) ...[
          GrassBagCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        g.title,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 2.5),
                      decoration: BoxDecoration(
                        color: g.isCompleted
                            ? t.okSoft
                            : (g.isBlocked
                                ? t.errSoft
                                : (g.isPaused || g.isDisarmed ? t.warnSoft : t.primarySoft)),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        g.statusLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: g.isCompleted
                              ? t.ok
                              : (g.isBlocked
                                  ? t.err
                                  : (g.isPaused || g.isDisarmed ? t.warn : t.primary)),
                        ),
                      ),
                    ),
                  ],
                ),
                if (g.criteria.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(g.criteria, style: TextStyle(fontSize: 12, height: 1.4, color: t.text2)),
                ],
                if (g.isBlocked && (g.blockedReasonMessage?.isNotEmpty == true || g.blockedReasonCode?.isNotEmpty == true)) ...[
                  const SizedBox(height: 8),
                  GrassBagStatusBanner(
                    tone: GrassBagBannerTone.warn,
                    borderRadius: 12,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    message: g.blockedReasonMessage?.isNotEmpty == true
                        ? g.blockedReasonMessage!
                        : '目标已阻塞（${g.blockedReasonCode}），需人工确认或调整后恢复。',
                  ),
                ] else if (g.isDisarmed) ...[
                  const SizedBox(height: 7),
                  Text(
                    '会话重载后默认处于待恢复状态，点击「恢复执行」继续自动推进。',
                    style: TextStyle(fontSize: 11.5, color: t.warn),
                  ),
                ],
                const SizedBox(height: 9),
                GrassBagProgressBar(
                  value: g.isCompleted
                      ? 1.0
                      : (g.maxGoalRounds != null && g.maxGoalRounds! > 0
                          ? (g.progressPct / 100.0).clamp(0.04, 0.96)
                          : (g.isArmed ? null : 0.0)),
                  height: 5,
                  trackColor: t.fill2,
                  color: g.isCompleted
                      ? t.ok
                      : (g.isBlocked ? t.err : (g.isPaused || g.isDisarmed ? t.warn : t.primary)),
                ),
                const SizedBox(height: 9),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (!g.isCompleted) ...[
                            GrassBagSpringTap(
                              onTap: () => ctrl.updateGoalStatus(
                                g.id,
                                g.isArmed ? 'paused' : 'active',
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                child: Text(
                                  g.isArmed ? '暂停' : '恢复执行',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: g.isArmed ? t.text2 : t.primary,
                                  ),
                                ),
                              ),
                            ),
                            GrassBagSpringTap(
                              onTap: () => _openAddGoalSheet(context, existing: g),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                child: Text(
                                  '编辑',
                                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text2),
                                ),
                              ),
                            ),
                            GrassBagSpringTap(
                              onTap: () => ctrl.updateGoalStatus(g.id, 'completed'),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                child: Text(
                                  '标记达成',
                                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.ok),
                                ),
                              ),
                            ),
                          ] else
                            Text(
                              '已完成目标',
                              style: TextStyle(fontSize: 11.5, color: t.ok),
                            ),
                        ],
                      ),
                    ),
                    GrassBagSpringTap(
                      onTap: () async {
                        final ok = await showGrassBagConfirmDialog(
                          context,
                          title: '清除目标「${g.title}」？',
                          message: '清除后该长期目标将被移除。',
                          confirmLabel: '清除',
                          isDestructive: true,
                        );
                        if (ok) ctrl.deleteGoal(g.id);
                      },
                      child: SizedBox(
                        width: 34,
                        height: 34,
                        child: Center(child: Icon(CupertinoIcons.trash, size: 15, color: t.text3)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 4: 轨迹 (Full Token / Speed / Cache Telemetry + Context + Step Timeline)
  // ---------------------------------------------------------------------------
  Widget _buildTimelineTab(
    BuildContext context,
    GrassBagAppState state,
    GrassBagController ctrl,
    GrassBagTokens t,
  ) {
    final host = state.activeHost;
    final tel = state.sessionTelemetry;
    final steps = <NormalizedStep>[for (final turn in state.turns) ...turn.steps];
    final turnsWithUsage = [
      for (int i = 0; i < state.turns.length; i++)
        if (state.turns[i].usage != null) (i + 1, state.turns[i]),
    ];
    final tps = tel.effectiveTps;
    final avgTtft = tel.avgTtftMs;
    final hitRate = tel.cacheHitRate;
    final totalActiveMs = tel.totalActiveMs;
    final llmShare = totalActiveMs > 0 ? (tel.llmMs / totalActiveMs).clamp(0.0, 1.0) : 0.0;
    final ctxColor = state.contextPct >= 85
        ? t.err
        : (state.contextPct >= 65 ? t.warn : t.ok);
    final ctxStatusText = state.contextPct >= 85
        ? '接近上限'
        : (state.contextPct >= 65 ? '注意占用' : '状态充裕');
    final visibleSteps = _showAllTimelineSteps || steps.length <= 12
        ? steps
        : steps.sublist(steps.length - 12);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Speed, TTFT & Latency Distribution Card
        GrassBagCard(
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(CupertinoIcons.speedometer, size: 15.5, color: t.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '生成速度与耗时',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w600, color: t.text),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (state.isStreaming && tel.liveTps != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: t.okSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '实时 ${tel.liveTps!.toStringAsFixed(1)} tok/s',
                        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: t.ok),
                      ),
                    )
                  else if (tel.stepsCount > 0)
                    Text(
                      '${tel.turnsCount} 轮 · ${tel.stepsCount} 步',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: t.text3,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 11),
              Row(
                children: [
                  Expanded(
                    child: _MetricTile(
                      value: tps != null ? '${tps.toStringAsFixed(tps >= 100 ? 0 : 1)} t/s' : '--',
                      label: state.isStreaming && tel.liveTps != null ? '实时速率' : '平均解码速度',
                      accentColor: tps != null ? t.primary : null,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: _MetricTile(
                      value: avgTtft != null ? formatDurationMs(avgTtft) : '--',
                      label: '平均首字 (TTFT)',
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: _MetricTile(
                      value: tel.decodeMs > 0 ? formatDurationMs(tel.decodeMs) : '--',
                      label: '纯解码耗时',
                    ),
                  ),
                ],
              ),
              if (totalActiveMs > 0) ...[
                const SizedBox(height: 11),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: SizedBox(
                    height: 7,
                    child: Row(
                      children: [
                        if (llmShare > 0)
                          Expanded(
                            flex: (llmShare * 1000).round().clamp(1, 1000),
                            child: Container(color: t.primary),
                          ),
                        if (1.0 - llmShare > 0.001)
                          Expanded(
                            flex: ((1.0 - llmShare) * 1000).round().clamp(1, 1000),
                            child: Container(color: t.ok),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _TelemetryKvRow(
                  dotColor: t.primary,
                  label: 'LLM 推理总耗时（含首字等待）',
                  value: formatDurationMs(tel.llmMs),
                  subValue: '${(llmShare * 100).toStringAsFixed(0)}%',
                ),
                _TelemetryKvRow(
                  dotColor: t.ok,
                  label: '工具执行总耗时',
                  value: formatDurationMs(tel.toolMs),
                  subValue: '${((1 - llmShare) * 100).toStringAsFixed(0)}%',
                ),
                if (tel.decodeTokens > 0)
                  _TelemetryKvRow(
                    label: '累计解码输出',
                    value: '${formatCompactTokens(tel.decodeTokens)} tok',
                    subValue: formatExactInt(tel.decodeTokens),
                  ),
                if (tel.subagentSettledMs > 0)
                  _TelemetryKvRow(
                    label: '子代理累计耗时',
                    value: formatDurationMs(tel.subagentSettledMs),
                  ),
              ] else ...[
                const SizedBox(height: 8),
                Text(
                  '发送对话后将实时采集首字延迟 (TTFT)、解码速率 (tok/s) 与工具耗时。',
                  style: TextStyle(fontSize: 11.5, color: t.text3),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 2. Token & Prompt Cache Detail Card
        GrassBagCard(
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(CupertinoIcons.bolt_fill, size: 15, color: t.ok),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Token 与 Prompt 缓存',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w600, color: t.text),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
                    decoration: BoxDecoration(
                      color: hitRate != null && hitRate >= 0.5 ? t.okSoft : t.fill1,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      hitRate != null
                          ? '命中率 ${(hitRate * 100).toStringAsFixed(1)}%'
                          : '暂无缓存数据',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: hitRate != null && hitRate >= 0.5 ? t.ok : t.text3,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '缓存命中越高，回复越快、Token 消耗越低',
                style: TextStyle(fontSize: 11, color: t.text3),
              ),
              if (tel.totalInputTokens > 0) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: SizedBox(
                    height: 8,
                    child: Row(
                      children: [
                        if (tel.cacheReadTokens > 0)
                          Expanded(
                            flex: tel.cacheReadTokens.clamp(1, 1000000000),
                            child: Container(color: t.ok),
                          ),
                        if (tel.cacheWriteTokens > 0)
                          Expanded(
                            flex: tel.cacheWriteTokens.clamp(1, 1000000000),
                            child: Container(color: t.warn),
                          ),
                        if (tel.uncachedInputTokens > 0)
                          Expanded(
                            flex: tel.uncachedInputTokens.clamp(1, 1000000000),
                            child: Container(color: t.primary),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              _TelemetryKvRow(
                dotColor: t.ok,
                label: '缓存命中读取 (Cache Read)',
                value: formatCompactTokens(tel.cacheReadTokens),
                subValue: formatExactInt(tel.cacheReadTokens),
              ),
              _TelemetryKvRow(
                dotColor: t.warn,
                label: '缓存新建写入 (Cache Write)',
                value: formatCompactTokens(tel.cacheWriteTokens),
                subValue: formatExactInt(tel.cacheWriteTokens),
              ),
              _TelemetryKvRow(
                dotColor: t.primary,
                label: '未命中新输入 (Uncached In)',
                value: formatCompactTokens(tel.uncachedInputTokens),
                subValue: formatExactInt(tel.uncachedInputTokens),
              ),
              _TelemetryKvRow(
                dotColor: t.dusk,
                label: '模型生成输出 (Output)',
                value: formatCompactTokens(tel.outputTokens),
                subValue: formatExactInt(tel.outputTokens),
              ),
              Divider(height: 14, color: t.sep),
              _TelemetryKvRow(
                label: '会话累计总 Token',
                value: formatCompactTokens(tel.totalTokens),
                subValue: formatExactInt(tel.totalTokens),
                emphasize: true,
              ),
              if (tel.summaryInputTokens + tel.summaryOutputTokens + tel.summaryCacheReadTokens > 0)
                _TelemetryKvRow(
                  label: '压缩摘要消耗',
                  value: formatCompactTokens(
                    tel.summaryInputTokens + tel.summaryOutputTokens + tel.summaryCacheReadTokens,
                  ),
                  subValue: '输出 ${formatCompactTokens(tel.summaryOutputTokens)}',
                ),
              if (tel.modelGroups.isNotEmpty) ...[
                Divider(height: 16, color: t.sep),
                Text(
                  '按模型分组消耗 (${tel.modelGroups.length})',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.text3),
                ),
                const SizedBox(height: 7),
                for (final g in tel.modelGroups) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: GrassBagFresnelGlassSurface(
                      borderRadius: 13,
                      innerWell: true,
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  g.provider.isNotEmpty ? '${g.provider} / ${g.model}' : g.model,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: t.text,
                                  ),
                                ),
                              ),
                              if (g.cacheHitRate != null)
                                GrassBagFresnelGlassSurface(
                                  isPill: true,
                                  innerWell: true,
                                  tintColor: t.okSoft,
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                                  child: Text(
                                    '缓存 ${(g.cacheHitRate! * 100).toStringAsFixed(1)}%',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                      color: t.ok,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '输入 ${formatCompactTokens(g.uncachedInputTokens)} · '
                            '缓存读 ${formatCompactTokens(g.cacheReadTokens)}'
                            '${g.cacheWriteTokens > 0 ? ' · 缓存写 ${formatCompactTokens(g.cacheWriteTokens)}' : ''}'
                            ' · 输出 ${formatCompactTokens(g.outputTokens)}'
                            '${g.contextTokens > 0 ? ' · 窗口 ${formatCompactTokens(g.contextTokens)}' : ''}',
                            style: TextStyle(
                              fontSize: 11,
                              fontFeatures: const [FontFeature.tabularFigures()],
                              color: t.text2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 3. Context Window Composition & Pressure Card
        GrassBagCard(
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(CupertinoIcons.chart_pie_fill, size: 15, color: t.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '上下文窗口构成',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w600, color: t.text),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 2),
                    decoration: BoxDecoration(
                      color: ctxColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$ctxStatusText · ${state.contextPct}%',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ctxColor),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                tel.pressureTokens > 0
                    ? '当前压力 ${formatCompactTokens(tel.pressureTokens)} / ${formatCompactTokens(tel.contextWindow > 0 ? tel.contextWindow : state.contextMaxK * 1000)}'
                        '${tel.projectedTokens > 0 ? ' · 下轮预估 ${formatCompactTokens(tel.projectedTokens)}' : ''}'
                    : '已用 ${state.contextUsedK}k / ${state.contextMaxK}k tokens',
                style: TextStyle(
                  fontSize: 11.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: t.text2,
                ),
              ),
              const SizedBox(height: 9),
              _StackedContextBar(
                telemetry: tel,
                contextPct: state.contextPct,
                height: 9,
              ),
              const SizedBox(height: 10),
              if (tel.systemTokens + tel.toolsTokens + tel.messageTokens > 0) ...[
                _TelemetryKvRow(
                  dotColor: const Color(0xFF6366F1),
                  label: '系统提示词 (System)',
                  value: formatCompactTokens(tel.systemTokens),
                  subValue: formatExactInt(tel.systemTokens),
                ),
                _TelemetryKvRow(
                  dotColor: const Color(0xFFA855F7),
                  label: '工具与 Schema 定义 (Tools)',
                  value: formatCompactTokens(tel.toolsTokens),
                  subValue: formatExactInt(tel.toolsTokens),
                ),
                _TelemetryKvRow(
                  dotColor: t.primary,
                  label: '历史对话消息 (Messages)',
                  value: formatCompactTokens(tel.messageTokens),
                  subValue: formatExactInt(tel.messageTokens),
                ),
                if (tel.otherContextTokens > 0)
                  _TelemetryKvRow(
                    dotColor: t.text3,
                    label: '附件 / 缓冲与开销',
                    value: formatCompactTokens(tel.otherContextTokens),
                    subValue: formatExactInt(tel.otherContextTokens),
                  ),
                if (tel.contextWindow > 0)
                  _TelemetryKvRow(
                    label: '剩余可用空间',
                    value: formatCompactTokens(tel.remainingContextTokens),
                    subValue: '${(100 - state.contextPct).clamp(0, 100)}%',
                  ),
              ],
              const SizedBox(height: 11),
              GrassBagPrimaryGlassButton(
                label: _compacting
                    ? '正在精简上下文…'
                    : (state.turns.isEmpty ? '暂无历史消息可精简' : '一键精简上下文 (/compact)'),
                icon: _compacting ? CupertinoIcons.hourglass : CupertinoIcons.wand_stars,
                height: 40,
                tier: state.glassTier,
                insideGlass: true,
                enabled: !_compacting && state.turns.isNotEmpty,
                onTap: (_compacting || state.turns.isEmpty)
                    ? null
                    : () async {
                        setState(() => _compacting = true);
                        try {
                          await ctrl.compactContext();
                        } finally {
                          if (mounted) setState(() => _compacting = false);
                        }
                      },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 4. Per-Turn Token & Cache Breakdown
        if (turnsWithUsage.isNotEmpty) ...[
          GrassBagGroupedSection(
            header: '各轮次用量明细 (${turnsWithUsage.length} 轮)',
            children: [
              for (final item in (_showAllTurnsUsage
                  ? turnsWithUsage.reversed
                  : turnsWithUsage.reversed.take(8)))
                Builder(
                  builder: (_) {
                    final turnIdx = item.$1;
                    final turn = item.$2;
                    final u = turn.usage!;
                    final cr = u.cacheReadTokens ?? 0;
                    final cw = u.cacheWriteTokens ?? 0;
                    final totalIn = u.inputTokens + cr + cw;
                    final turnHit = totalIn > 0 ? ((cr / totalIn) * 100).toStringAsFixed(0) : null;
                    final promptPreview = turn.userMessage?.text.trim().isNotEmpty == true
                        ? turn.userMessage!.text.trim().split('\n').first
                        : '第 $turnIdx 轮回复';
                    return GrassBagListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      leading: Container(
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 24),
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: t.fill1,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '#$turnIdx',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: t.text2,
                          ),
                        ),
                      ),
                      title: Text(
                        promptPreview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: t.text),
                      ),
                      subtitle: Text(
                        '输入 ${formatCompactTokens(u.inputTokens)} · '
                        '输出 ${formatCompactTokens(u.outputTokens)}'
                        '${cr > 0 ? ' · 缓存读 ${formatCompactTokens(cr)}' : ''}'
                        '${cw > 0 ? ' · 缓存写 ${formatCompactTokens(cw)}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: t.text3,
                        ),
                      ),
                      trailing: turnHit != null
                          ? Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2),
                              decoration: BoxDecoration(
                                color: cr > 0 ? t.okSoft : t.fill1,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '$turnHit%',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: cr > 0 ? t.ok : t.text3,
                                ),
                              ),
                            )
                          : null,
                    );
                  },
                ),
              if (turnsWithUsage.length > 8)
                GrassBagListTile(
                  title: Text(
                    _showAllTurnsUsage ? '仅显示最近 8 轮' : '展开全部 ${turnsWithUsage.length} 轮',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.primary),
                  ),
                  trailing: Icon(
                    _showAllTurnsUsage ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down,
                    size: 14,
                    color: t.primary,
                  ),
                  onTap: () => setState(() => _showAllTurnsUsage = !_showAllTurnsUsage),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],

        // 5. Execution Steps Timeline (capped for huge 200+ step sessions with 1-tap expand)
        if (steps.isNotEmpty) ...[
          GrassBagGroupedSection(
            header: '本对话执行轨迹 (${steps.length} 步)',
            children: [
              if (steps.length > 12 && !_showAllTimelineSteps)
                GrassBagListTile(
                  title: Text(
                    '展开更早的 ${steps.length - 12} 条步骤',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.primary),
                  ),
                  trailing: Icon(CupertinoIcons.chevron_down, size: 14, color: t.primary),
                  onTap: () => setState(() => _showAllTimelineSteps = true),
                ),
              for (final step in visibleSteps)
                if (step is ReasoningStep)
                  GrassBagListTile(
                    leading: GrassBagSquircleIcon(
                      icon: CupertinoIcons.sparkles,
                      color: t.dusk,
                      size: 30,
                      iconSize: 14,
                    ),
                    title: Text(
                      step.collapsedPreview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      step.durationMs != null
                          ? '思考 ${(step.durationMs! / 1000).toStringAsFixed(1)}s'
                          : (state.isStreaming ? '思考中' : '已完成思考'),
                    ),
                    showChevron: true,
                    onTap: () {
                      final fullText = step.text.trim().isNotEmpty
                          ? step.text.trim()
                          : step.collapsedPreview;
                      showGrassBagSheet<void>(
                        context,
                        title: '思考过程详情',
                        subtitle: step.durationMs != null
                            ? '耗时 ${(step.durationMs! / 1000).toStringAsFixed(1)}s'
                            : '推理轨迹',
                        icon: CupertinoIcons.sparkles,
                        iconColor: t.dusk,
                        expandable: true,
                        bodyBuilder: (sheetCtx) {
                          final st = GrassBagTokens.of(sheetCtx);
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              GrassBagFresnelGlassSurface(
                                borderRadius: 16,
                                innerWell: true,
                                padding: const EdgeInsets.all(14),
                                child: SelectableText(
                                  fullText,
                                  contextMenuBuilder: buildGrassBagEditableContextMenu,
                                  style: TextStyle(fontSize: 13, height: 1.55, color: st.text),
                                ),
                              ),
                              const SizedBox(height: 12),
                              GrassBagSecondaryGlassButton(
                                label: '复制思考全文',
                                icon: CupertinoIcons.doc_on_doc,
                                tier: state.glassTier,
                                insideGlass: true,
                                onTap: () {
                                  Clipboard.setData(ClipboardData(text: fullText));
                                  ref.read(appProvider.notifier).showToast('已复制思考内容', tone: ToastTone.ok);
                                  Navigator.of(sheetCtx).pop();
                                },
                              ),
                            ],
                          );
                        },
                      );
                    },
                  )
                else if (step is ToolStep)
                  GrassBagListTile(
                    leading: GrassBagSquircleIcon(
                      icon: step.status == 'error'
                          ? CupertinoIcons.exclamationmark_triangle_fill
                          : CupertinoIcons.wrench_fill,
                      color: step.status == 'error' ? t.err : t.ok,
                      size: 30,
                      iconSize: 14,
                    ),
                    title: Text(
                      step.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                    ),
                    subtitle: Text(
                      step.durationMs != null
                          ? '${formatDurationMs(step.durationMs!)} · ${step.summary}'
                          : step.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    showChevron: true,
                    onTap: () {
                      final fallbackDetail = step.summary.trim();
                      final detailFuture = step.callId.trim().isNotEmpty
                          ? ctrl.loadToolDetail(step.callId)
                          : Future<Map<String, dynamic>?>.value(null);
                      showGrassBagSheet<void>(
                        context,
                        title: step.title,
                        subtitle: [
                          step.name,
                          if (step.durationMs != null) formatDurationMs(step.durationMs!),
                          step.status,
                        ].join(' · '),
                        icon: step.status == 'error'
                            ? CupertinoIcons.exclamationmark_triangle_fill
                            : CupertinoIcons.wrench_fill,
                        iconColor: step.status == 'error' ? t.err : t.ok,
                        expandable: true,
                        bodyBuilder: (sheetCtx) {
                          final st = GrassBagTokens.of(sheetCtx);
                          return FutureBuilder<Map<String, dynamic>?>(
                            future: detailFuture,
                            builder: (ctx, snap) {
                              final loading = snap.connectionState == ConnectionState.waiting;
                              final data = snap.data;
                              final argsText = (data?['argsText']?.toString() ?? '').trim();
                              final outText = (data?['outputText']?.toString() ?? '').trim();
                              final effectiveText = outText.isNotEmpty
                                  ? outText
                                  : fallbackDetail;
                              final combinedCopy = [
                                if (argsText.isNotEmpty) '参数:\n$argsText',
                                if (effectiveText.isNotEmpty) '输出:\n$effectiveText',
                              ].join('\n\n');
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (loading)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 10),
                                      child: Row(
                                        children: [
                                          GrassBagActivityIndicator(
                                            radius: 7,
                                            color: st.primary,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            '正在加载完整参数与输出…',
                                            style: TextStyle(fontSize: 12, color: st.text3),
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (argsText.isNotEmpty) ...[
                                    Padding(
                                      padding: const EdgeInsets.only(left: 4, bottom: 5),
                                      child: Text(
                                        '调用参数',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                          color: st.text3,
                                        ),
                                      ),
                                    ),
                                    GrassBagFresnelGlassSurface(
                                      borderRadius: 16,
                                      innerWell: true,
                                      padding: const EdgeInsets.all(12),
                                      child: SelectableText(
                                        argsText,
                                        contextMenuBuilder: buildGrassBagEditableContextMenu,
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11.5,
                                          height: 1.48,
                                          color: st.text2,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                  ],
                                  if (argsText.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 4, bottom: 5),
                                      child: Text(
                                        '执行结果',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                          color: st.text3,
                                        ),
                                      ),
                                    ),
                                  GrassBagFresnelGlassSurface(
                                    borderRadius: 16,
                                    innerWell: true,
                                    padding: const EdgeInsets.all(14),
                                    child: SelectableText(
                                      effectiveText.isNotEmpty ? effectiveText : '（无详细输出）',
                                      contextMenuBuilder: buildGrassBagEditableContextMenu,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                        height: 1.5,
                                        color: st.text,
                                      ),
                                    ),
                                  ),
                                  if (combinedCopy.isNotEmpty) ...[
                                    const SizedBox(height: 12),
                                    GrassBagSecondaryGlassButton(
                                      label: '复制执行详情',
                                      icon: CupertinoIcons.doc_on_doc,
                                      tier: state.glassTier,
                                      insideGlass: true,
                                      onTap: () {
                                        Clipboard.setData(ClipboardData(text: combinedCopy));
                                        ref.read(appProvider.notifier).showToast(
                                              '已复制步骤详情',
                                              tone: ToastTone.ok,
                                            );
                                        Navigator.of(sheetCtx).pop();
                                      },
                                    ),
                                  ],
                                ],
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
            ],
          ),
          const SizedBox(height: 12),
        ],

        // 6. Session Environment & Quick Actions
        GrassBagGroupedSection(
          header: '会话环境与快捷入口',
          children: [
            GrassBagListTile(
              title: const Text('模型与思考强度', style: TextStyle(fontSize: 14)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 165),
                    child: Text(
                      state.modelEffort.trim().isNotEmpty
                          ? '${state.modelName} · ${state.modelEffort}'
                          : state.modelName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: t.text3),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(CupertinoIcons.chevron_right, size: 14, color: t.text3),
                ],
              ),
              onTap: () => showModelSheet(context, ref),
            ),
            if (tel.workingDirectory.isNotEmpty)
              GrassBagListTile(
                title: const Text('工作目录', style: TextStyle(fontSize: 14)),
                subtitle: Text(
                  tel.workingDirectory,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: t.text3),
                ),
                trailing: Icon(CupertinoIcons.doc_on_doc, size: 14, color: t.text3),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: tel.workingDirectory));
                  ctrl.showToast('已复制工作目录路径', tone: ToastTone.info);
                },
              ),
            GrassBagListTile(
              title: const Text('所在主机', style: TextStyle(fontSize: 14)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      host.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: t.text3),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(CupertinoIcons.chevron_right, size: 14, color: t.text3),
                ],
              ),
              onTap: () => widget.onOpenHostDetail(host.id),
            ),
            GrassBagListTile(
              title: const Text('导出对话 Markdown', style: TextStyle(fontSize: 14)),
              showChevron: true,
              onTap: () => ctrl.exportActiveSession(),
            ),
            GrassBagListTile(
              title: const Text('导出完整会话归档 (ZIP)', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                host.directMode
                    ? '直连模式暂不支持 ZIP，请安装连接助手或使用 Markdown 导出'
                    : '打包完整对话、附件与分支记录',
                style: TextStyle(fontSize: 11.5, color: t.text3),
              ),
              showChevron: !host.directMode,
              onTap: () => unawaited(ctrl.exportActiveSessionZip()),
            ),
            GrassBagListTile(
              title: const Text('在官方网页版中打开', style: TextStyle(fontSize: 14)),
              showChevron: true,
              onTap: widget.onOpenWebUi,
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 5: 子代理 (Subagent Lineage & Prompt / Interrupt)
  // ---------------------------------------------------------------------------
  Widget _buildSubagentsTab(
    BuildContext context,
    GrassBagAppState state,
    GrassBagController ctrl,
    GrassBagTokens t,
  ) {
    if (state.subagents.isEmpty) {
      final isOffline = state.connectionPhase != ConnectionPhase.connected;
      return GrassBagCard(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isOffline ? CupertinoIcons.wifi_exclamationmark : CupertinoIcons.arrow_branch,
              size: 30,
              color: isOffline ? t.warn : t.text3,
            ),
            const SizedBox(height: 10),
            Text(
              isOffline ? '尚未连接到 DSH 主机' : '当前会话暂无并行子代理',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text2),
            ),
            const SizedBox(height: 4),
            Text(
              isOffline
                  ? '连接在线主机后即可实时查看与操控并行子代理任务'
                  : '在对话中使用 /teamwork 或拆解复杂任务时，可在此实时查看子代理进度并追加指令',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, height: 1.4, color: t.text3),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (isOffline)
                  GrassBagSecondaryGlassButton(
                    label: '重试连接',
                    icon: CupertinoIcons.refresh,
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tier: state.glassTier,
                    insideGlass: true,
                    accentForeground: true,
                    onTap: () => ctrl.probeAndRefreshHost(state.activeHostId),
                  )
                else ...[
                  GrassBagSecondaryGlassButton(
                    label: '复制 /teamwork 示例',
                    icon: CupertinoIcons.doc_on_doc,
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tier: state.glassTier,
                    insideGlass: true,
                    accentForeground: true,
                    onTap: () {
                      Clipboard.setData(
                        const ClipboardData(text: '/teamwork 并行分析项目结构、找出关键瓶颈并整理修复方案'),
                      );
                      ctrl.showToast('已复制 /teamwork 示例指令，可粘贴到输入框使用', tone: ToastTone.ok);
                    },
                  ),
                  GrassBagSecondaryGlassButton(
                    label: '刷新',
                    icon: CupertinoIcons.refresh,
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tier: state.glassTier,
                    insideGlass: true,
                    onTap: () => unawaited(ctrl.refreshSubagentsOnly()),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${state.subagents.length} 个子代理任务',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text3),
                ),
              ),
              GrassBagSpringTap(
                enablePointerGlow: false,
                haptic: true,
                onTap: () => unawaited(ctrl.refreshSubagentsOnly()),
                child: GrassBagFresnelGlassSurface(
                  isPill: true,
                  innerWell: true,
                  interactive: true,
                  tintColor: t.primarySoft,
                  padding: const EdgeInsets.symmetric(horizontal: 10.5, vertical: 5.5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.refresh, size: 12, color: t.primary),
                      const SizedBox(width: 4),
                      Text(
                        '刷新',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: t.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        for (final sub in state.subagents) ...[
          SubagentLineageCard(
            item: sub,
            onPrompt: () => _openSubagentPromptSheet(context, sub),
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
            onInspect: sub.id.trim().isNotEmpty
                ? () {
                    ctrl.openSubagentSession(
                      sub.id,
                      childTitle: sub.name,
                    );
                    if (!widget.isTabletPane) Navigator.of(context).pop();
                  }
                : null,
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// Isolated 4Hz telemetry header card so streaming speed/token updates NEVER rebuild
/// the active Files / Diffs / Terminal / Progress / Subagents workbench tabs below.
class _WorkbenchTelemetryCard extends ConsumerWidget {
  const _WorkbenchTelemetryCard({
    required this.isTimelineTab,
    required this.onOpenTimeline,
  });

  final bool isTimelineTab;
  final VoidCallback onOpenTimeline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          sessionTitle: s.activeSession?.title ?? '新对话',
          modelShort: s.modelShort,
          tel: s.sessionTelemetry,
          contextPct: s.contextPct,
          contextUsedK: s.contextUsedK,
          contextMaxK: s.contextMaxK,
          isStreaming: s.isStreaming,
          diffsLen: s.workspaceDiffs.length,
          turnsLen: s.turns.length,
        ),
      ),
    );
    final t = GrassBagTokens.of(context);
    final tel = slice.tel;
    final totalSteps = tel.stepsCount > 0
        ? tel.stepsCount
        : ref.read(appProvider).turns.fold<int>(0, (acc, turn) => acc + turn.steps.length);
    final tps = tel.effectiveTps;
    final speedLabel = tps != null ? '${tps.toStringAsFixed(tps >= 100 ? 0 : 1)} t/s' : '--';
    final avgTtft = tel.avgTtftMs;
    final speedSub = slice.isStreaming && tel.liveTps != null
        ? '实时生成中'
        : (avgTtft != null ? '首字 ${formatDurationMs(avgTtft)}' : '首字延迟 --');
    final hitRate = tel.cacheHitRate;
    final cacheLabel = hitRate != null ? '${(hitRate * 100).toStringAsFixed(1)}%' : '--';
    final cacheSub = tel.cacheReadTokens > 0
        ? '读取 ${formatCompactTokens(tel.cacheReadTokens)}'
        : '暂无缓存';
    final totalTokLabel = tel.totalTokens > 0 ? formatCompactTokens(tel.totalTokens) : '--';
    final totalTokSub = tel.outputTokens > 0
        ? '输出 ${formatCompactTokens(tel.outputTokens)}'
        : '等待首轮';
    final ctxColor = slice.contextPct >= 85
        ? t.err
        : (slice.contextPct >= 65 ? t.warn : t.primary);

    return GrassBagSpringTap(
      enabled: !isTimelineTab,
      enablePointerGlow: false,
      haptic: true,
      pressedScale: 0.99,
      onTap: onOpenTimeline,
      child: GrassBagCard(
        borderRadius: 24,
        interactive: !isTimelineTab,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    slice.sessionTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.text),
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 132),
                  child: GrassBagFresnelGlassSurface(
                    isPill: true,
                    innerWell: true,
                    tintColor: t.primarySoft,
                    padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 2.5),
                    child: Text(
                      tel.lastModel.isNotEmpty ? tel.lastModel : slice.modelShort,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: t.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.25,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _MetricTile(
                          title: '生成速度',
                          value: speedLabel,
                          label: speedSub,
                          accentColor: (slice.isStreaming && tel.liveTps != null) ? t.ok : null,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: _MetricTile(
                          title: '缓存命中',
                          value: cacheLabel,
                          label: cacheSub,
                          accentColor: hitRate != null && hitRate >= 0.6 ? t.ok : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      Expanded(
                        child: _MetricTile(
                          title: '累计用量',
                          value: totalTokLabel,
                          label: totalTokSub,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: _MetricTile(
                          title: '上下文',
                          value: '${slice.contextPct}%',
                          label: '${slice.contextUsedK}k / ${slice.contextMaxK}k',
                          accentColor: slice.contextPct >= 65 ? ctxColor : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 9),
            _StackedContextBar(
              telemetry: tel,
              contextPct: slice.contextPct,
              height: 5,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '改动 ${slice.diffsLen} · 步骤 $totalSteps · 轮次 ${tel.turnsCount > 0 ? tel.turnsCount : slice.turnsLen}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: t.text3,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  isTimelineTab ? '详细统计' : '详细统计 ›',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: isTimelineTab ? t.text3 : t.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    this.title,
    required this.value,
    required this.label,
    this.accentColor,
  });
  final String? title;
  final String value;
  final String label;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final ambientTier = resolveAmbientGlassTier(context);
    final isSolid = ambientTier == GrassBagGlassTier.solid;
    final tile = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: ShapeDecoration(
        color: isSolid ? t.fill1 : null,
        gradient: isSolid
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: accentColor != null
                    ? [
                        accentColor!.withValues(alpha: t.isDark ? 0.16 : 0.11),
                        accentColor!.withValues(alpha: t.isDark ? 0.06 : 0.04),
                      ]
                    : (t.isDark
                        ? [
                            Colors.white.withValues(alpha: 0.095),
                            Colors.white.withValues(alpha: 0.035),
                          ]
                        : [
                            Colors.white.withValues(alpha: 0.68),
                            Colors.white.withValues(alpha: 0.42),
                          ]),
              ),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(14),
          side: isSolid ? BorderSide(color: t.sep, width: 0.6) : BorderSide.none,
        ),
      ),
      child: Column(
        children: [
          if (title != null) ...[
            Text(
              title!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w500, color: t.text3),
            ),
            const SizedBox(height: 2),
          ],
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: accentColor ?? t.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: t.text3),
          ),
        ],
      ),
    );
    if (isSolid) return tile;
    return CustomPaint(
      foregroundPainter: GrassBagFresnelRimPainter(
        isDark: t.isDark,
        borderRadius: 14,
        accent: accentColor,
        innerWell: true,
        frosted: ambientTier == GrassBagGlassTier.frosted,
        paintTopSheen: false,
        strokeWidth: 0.78,
      ),
      child: tile,
    );
  }
}

class _TelemetryKvRow extends StatelessWidget {
  const _TelemetryKvRow({
    required this.label,
    required this.value,
    this.subValue,
    this.dotColor,
    this.emphasize = false,
  });

  final String label;
  final String value;
  final String? subValue;
  final Color? dotColor;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        children: [
          if (dotColor != null) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
          ],
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: emphasize ? 12.5 : 12,
                fontWeight: emphasize ? FontWeight.w600 : FontWeight.w400,
                color: emphasize ? t.text : t.text2,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: emphasize ? 13 : 12.2,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: emphasize ? t.primary : t.text,
            ),
          ),
          if (subValue != null && subValue!.isNotEmpty && subValue != value) ...[
            const SizedBox(width: 5),
            Text(
              '($subValue)',
              style: TextStyle(
                fontSize: 10.5,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: t.text3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StackedContextBar extends StatelessWidget {
  const _StackedContextBar({
    required this.telemetry,
    required this.contextPct,
    this.height = 8,
  });

  final SessionTelemetry telemetry;
  final int contextPct;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final win = telemetry.contextWindow;
    final hasBreakdown = win > 0 &&
        (telemetry.systemTokens + telemetry.toolsTokens + telemetry.messageTokens) > 0;
    if (!hasBreakdown) {
      final fillColor = contextPct >= 85
          ? t.err
          : (contextPct >= 65 ? t.warn : t.primary);
      return GrassBagProgressBar(
        value: (contextPct / 100.0).clamp(0.0, 1.0),
        height: height,
        color: fillColor,
      );
    }

    final sys = telemetry.systemTokens.clamp(0, win);
    final tools = telemetry.toolsTokens.clamp(0, win);
    final msgs = telemetry.messageTokens.clamp(0, win);
    final other = telemetry.otherContextTokens.clamp(0, win);
    final used = (sys + tools + msgs + other).clamp(0, win);
    final rem = (win - used).clamp(0, win);

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: t.fill2,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.white.withValues(alpha: t.isDark ? 0.12 : 0.76),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Row(
            children: [
              if (sys > 0)
                Expanded(flex: sys, child: Container(color: const Color(0xFF6366F1))),
              if (tools > 0)
                Expanded(flex: tools, child: Container(color: const Color(0xFFA855F7))),
              if (msgs > 0)
                Expanded(flex: msgs, child: Container(color: t.primary)),
              if (other > 0)
                Expanded(
                  flex: other,
                  child: Container(color: t.text3.withValues(alpha: 0.45)),
                ),
              if (rem > 0)
                Expanded(flex: rem, child: const SizedBox.shrink()),
            ],
          ),
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: t.isDark ? 0.24 : 0.36),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnifiedDiffCodeBox extends StatefulWidget {
  const _UnifiedDiffCodeBox({
    required this.diffText,
    this.maxPreviewLines,
  });
  final String diffText;
  final int? maxPreviewLines;

  @override
  State<_UnifiedDiffCodeBox> createState() => _UnifiedDiffCodeBoxState();
}

class _UnifiedDiffCodeBoxState extends State<_UnifiedDiffCodeBox> {
  List<String> _lines = const [];
  bool _clipped = false;
  int _hiddenCount = 0;
  double _contentWidth = 280.0;

  void _rebuildCache() {
    final allLines = widget.diffText.split('\n');
    final maxLines = widget.maxPreviewLines;
    _clipped = maxLines != null && allLines.length > maxLines;
    _lines = _clipped ? allLines.sublist(0, maxLines) : allLines;
    _hiddenCount = _clipped ? allLines.length - _lines.length : 0;
    var maxPx = 280.0;
    for (final l in _lines) {
      final px = estimateMonospaceLinePx(l, fontSize: 11.5) + 28.0;
      if (px > maxPx) maxPx = px;
    }
    _contentWidth = maxPx.clamp(280.0, 3200.0);
  }

  @override
  void initState() {
    super.initState();
    _rebuildCache();
  }

  @override
  void didUpdateWidget(covariant _UnifiedDiffCodeBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diffText != widget.diffText ||
        oldWidget.maxPreviewLines != widget.maxPreviewLines) {
      _rebuildCache();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final lines = _lines;
    final clipped = _clipped;
    final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 2.0);
    final contentWidth = (_contentWidth * textScale).clamp(280.0, 4800.0);

    final horizontalView = LayoutBuilder(
      builder: (_, box) {
        final effectiveWidth = math.max(box.maxWidth, contentWidth);
        // SelectionArea strictly OUTSIDE horizontal scroller so Android horizontal drag never stalls!
        return SelectionArea(
          contextMenuBuilder: buildGrassBagSelectableContextMenu,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: SizedBox(
              width: effectiveWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final rawLine in lines)
                    () {
                      final line = expandTabs(rawLine);
                      final isAdd = line.startsWith('+') && !line.startsWith('+++');
                      final isDel = line.startsWith('-') && !line.startsWith('---');
                      final isHunk = line.startsWith('@@');
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                        color: isAdd
                            ? (t.isDark ? const Color(0x2834D399) : const Color(0x1D117A4B))
                            : (isDel
                                ? (t.isDark ? const Color(0x28F87171) : const Color(0x1DA6302C))
                                : (isHunk
                                    ? (t.isDark ? const Color(0x203B82F6) : const Color(0x142563EB))
                                    : Colors.transparent)),
                        child: Text(
                          line,
                          softWrap: false,
                          overflow: TextOverflow.visible,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            height: 1.42,
                            fontWeight: isHunk ? FontWeight.w600 : FontWeight.w400,
                            color: isHunk
                                ? (t.isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB))
                                : (isAdd
                                    ? (t.isDark ? const Color(0xFF6EE7B7) : const Color(0xFF0D7A4F))
                                    : (isDel
                                        ? (t.isDark ? const Color(0xFFFCA5A5) : const Color(0xFFA6302C))
                                        : t.codeFg)),
                          ),
                        ),
                      );
                    }(),
                  if (clipped)
                    Padding(
                      padding: const EdgeInsets.only(left: 5, top: 4),
                      child: Text(
                        '… 还有 $_hiddenCount 行，点击下方全屏查看',
                        style: TextStyle(
                          fontSize: 11,
                          color: t.isDark ? const Color(0xFF8294AC) : t.text3,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );

    final diffTier = resolveAmbientGlassTier(context);
    final diffSolid = diffTier == GrassBagGlassTier.solid;
    final diffBox = ClipRSuperellipse(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: ShapeDecoration(
          color: t.codeBg,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(14),
            side: diffSolid
                ? BorderSide(
                    color: t.isDark ? Colors.white.withValues(alpha: 0.09) : t.sep,
                    width: 0.65,
                  )
                : BorderSide.none,
          ),
        ),
        child: horizontalView,
      ),
    );

    return RepaintBoundary(
      child: diffSolid
          ? diffBox
          : CustomPaint(
              foregroundPainter: GrassBagFresnelRimPainter(
                isDark: t.isDark,
                borderRadius: 14,
                accent: t.isDark ? t.primaryHi : null,
                innerWell: true,
                frosted: diffTier == GrassBagGlassTier.frosted,
                paintTopSheen: false,
                strokeWidth: 0.8,
              ),
              child: diffBox,
            ),
    );
  }
}

class _AddGoalSheetBody extends ConsumerStatefulWidget {
  const _AddGoalSheetBody({this.existing});

  final SessionGoalRecord? existing;

  @override
  ConsumerState<_AddGoalSheetBody> createState() => _AddGoalSheetBodyState();
}

class _AddGoalSheetBodyState extends ConsumerState<_AddGoalSheetBody> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _criteriaCtrl;
  final FocusNode _criteriaFocus = FocusNode();
  bool _saving = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.existing?.title ?? '');
    _criteriaCtrl = TextEditingController(text: widget.existing?.criteria ?? '');
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _criteriaCtrl.dispose();
    _criteriaFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _err = '请输入目标名称');
      return;
    }
    setState(() {
      _saving = true;
      _err = null;
    });
    final ctrl = ref.read(appProvider.notifier);
    final err = widget.existing != null
        ? await ctrl.editGoal(widget.existing!.id, title, _criteriaCtrl.text)
        : await ctrl.addGoal(title, _criteriaCtrl.text);
    if (!mounted) return;
    if (err != null && err.isNotEmpty) {
      setState(() {
        _saving = false;
        _err = err;
      });
      return;
    }
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
          controller: _titleCtrl,
          autofocus: true,
          insideGlass: true,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _criteriaFocus.requestFocus(),
          hasError: _err != null,
          onChanged: (_) {
            if (_err != null) setState(() => _err = null);
          },
          placeholder: '目标名称，例如：完成 PDF 导出全链路验证',
          fontSize: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        if (_err != null) ...[
          const SizedBox(height: 6),
          Text(_err!, style: TextStyle(fontSize: 12, color: t.err)),
        ],
        const SizedBox(height: 10),
        GrassBagTextField(
          controller: _criteriaCtrl,
          focusNode: _criteriaFocus,
          insideGlass: true,
          minLines: 2,
          maxLines: 3,
          placeholder: '验收标准（例如：全部单测通过、无警告、已出高清样张）',
          fontSize: 13.5,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        const SizedBox(height: 14),
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
                label: _saving
                    ? '保存中…'
                    : (widget.existing != null ? '保存目标' : '创建目标'),
                tier: tier,
                insideGlass: true,
                enabled: !_saving,
                onTap: () => unawaited(_submit()),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SubagentPromptSheetBody extends ConsumerStatefulWidget {
  const _SubagentPromptSheetBody({required this.sub});

  final SubagentItem sub;

  @override
  ConsumerState<_SubagentPromptSheetBody> createState() => _SubagentPromptSheetBodyState();
}

class _SubagentPromptSheetBodyState extends ConsumerState<_SubagentPromptSheetBody> {
  final TextEditingController _textCtrl = TextEditingController();
  bool _sending = false;
  String? _err;

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending) return;
    final msg = _textCtrl.text.trim();
    if (msg.isEmpty) {
      setState(() => _err = '请输入要发送给子代理的指令');
      return;
    }
    setState(() {
      _sending = true;
      _err = null;
    });
    final ok = await ref.read(appProvider.notifier).promptSubagent(widget.sub.id, msg);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _sending = false;
        _err = '发送失败，请检查主机连接状态后重试';
      });
    }
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
          maxLines: 3,
          hasError: _err != null,
          onChanged: (_) {
            if (_err != null) setState(() => _err = null);
          },
          placeholder: '输入要追加给该子代理的指令…',
          fontSize: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        if (_err != null) ...[
          const SizedBox(height: 6),
          Text(_err!, style: TextStyle(fontSize: 12, color: t.err)),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '取消',
                tier: tier,
                insideGlass: true,
                onTap: _sending ? null : () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: _sending ? '发送中…' : '发送',
                tier: tier,
                insideGlass: true,
                enabled: !_sending,
                onTap: _sending ? null : _submit,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
