import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_mascot.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';

/// Refined `dsh-Go × macOS` Left Sidebar (Phone: rounded frosted drawer · Tablet: docked sidebar).
class SessionsSidebar extends ConsumerStatefulWidget {
  const SessionsSidebar({
    super.key,
    required this.isTabletDocked,
    this.onCloseDrawer,
    this.backHandlerNotifier,
    required this.onOpenTerminal,
    required this.onOpenFeatures,
    required this.onOpenSettings,
    required this.onOpenHostsSettings,
  });

  final bool isTabletDocked;
  final VoidCallback? onCloseDrawer;
  final ValueNotifier<bool Function()?>? backHandlerNotifier;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenFeatures;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenHostsSettings;

  @override
  ConsumerState<SessionsSidebar> createState() => _SessionsSidebarState();
}

class _SessionsSidebarState extends ConsumerState<SessionsSidebar> {
  static final Map<String, Set<String>> _persistedCollapsedByHost = <String, Set<String>>{};

  late final TextEditingController _searchCtrl;
  final ValueNotifier<bool> _searchFocused = ValueNotifier<bool>(false);
  bool _multiSelectMode = false;
  final Set<String> _selectedIds = {};
  final Set<String> _collapsedGroups = {};
  int _collapsedGroupsVersion = 0;
  String? _lastHostId;

  // Memoized sidebar list cache so streaming tokens or session clicks do ZERO O(N log N) regrouping!
  List<ChatSessionItem>? _cacheSessions;
  List<WorkspaceItem>? _cacheWorkspaces;
  String? _cacheWsFilter;
  String? _cacheSearchQuery;
  Map<String, String>? _cacheSearchSnippets;
  SessionFilter? _cacheFilter;
  SessionGroupMode? _cacheGroupMode;
  int _cacheCollapsedVer = -1;
  List<Object> _cachedFlatItems = const [];
  Set<String> _cachedMatchedSessionIds = const {};
  int _cachedUngroupedWithCwdCount = 0;

  static String _normalizeDirPath(String path) {
    final trimmed = path.trim();
    if (trimmed.length > 1 && trimmed.endsWith('/')) {
      return trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  static String _basenamePath(String path) {
    final clean = _normalizeDirPath(path);
    final idx = clean.lastIndexOf('/');
    return idx >= 0 && idx < clean.length - 1 ? clean.substring(idx + 1) : clean;
  }

  void _ensureFlatItems({
    required List<ChatSessionItem> sessions,
    required List<WorkspaceItem> workspaces,
    required String? sidebarWorkspaceFilter,
    required String searchQuery,
    required Map<String, String> searchSnippets,
    required SessionFilter filter,
    required SessionGroupMode groupMode,
  }) {
    if (identical(_cacheSessions, sessions) &&
        identical(_cacheWorkspaces, workspaces) &&
        _cacheWsFilter == sidebarWorkspaceFilter &&
        _cacheSearchQuery == searchQuery &&
        identical(_cacheSearchSnippets, searchSnippets) &&
        _cacheFilter == filter &&
        _cacheGroupMode == groupMode &&
        _cacheCollapsedVer == _collapsedGroupsVersion) {
      return;
    }

    _cacheSessions = sessions;
    _cacheWorkspaces = workspaces;
    _cacheWsFilter = sidebarWorkspaceFilter;
    _cacheSearchQuery = searchQuery;
    _cacheSearchSnippets = searchSnippets;
    _cacheFilter = filter;
    _cacheGroupMode = groupMode;
    _cacheCollapsedVer = _collapsedGroupsVersion;

    final q = searchQuery.trim().toLowerCase();
    final wsFilter = sidebarWorkspaceFilter?.trim() ?? '';
    final normWsFilter = wsFilter.isNotEmpty ? _normalizeDirPath(wsFilter) : '';
    WorkspaceItem? filterWsItem;
    if (wsFilter.isNotEmpty) {
      for (final w in workspaces) {
        if (w.id == wsFilter ||
            w.name == wsFilter ||
            w.path == wsFilter ||
            (w.path.isNotEmpty && _normalizeDirPath(w.path) == normWsFilter)) {
          filterWsItem = w;
          break;
        }
      }
    }
    final normFilterItemPath =
        (filterWsItem != null && filterWsItem.path.isNotEmpty)
            ? _normalizeDirPath(filterWsItem.path)
            : '';

    final matched = sessions.where((s) {
      if (wsFilter.isNotEmpty) {
        final normCwd = (s.cwd != null && s.cwd!.isNotEmpty) ? _normalizeDirPath(s.cwd!) : '';
        final matchWs = (filterWsItem != null &&
                (s.workspaceId == filterWsItem.id ||
                    s.workspaceName == filterWsItem.name ||
                    (normFilterItemPath.isNotEmpty && normCwd == normFilterItemPath))) ||
            s.workspaceId == wsFilter ||
            s.workspaceName == wsFilter ||
            (normCwd.isNotEmpty && normCwd == normWsFilter) ||
            (normCwd.isNotEmpty && _basenamePath(normCwd) == wsFilter);
        if (!matchWs) return false;
      }
      if (q.isNotEmpty &&
          !s.title.toLowerCase().contains(q) &&
          !(s.workspaceName?.toLowerCase().contains(q) ?? false) &&
          !(s.cwd?.toLowerCase().contains(q) ?? false) &&
          !searchSnippets.containsKey(s.id)) {
        return false;
      }
      return switch (filter) {
        SessionFilter.all => !s.archived,
        SessionFilter.running => !s.archived && s.running,
        SessionFilter.pending => !s.archived && s.pendingApproval,
        SessionFilter.unread => !s.archived && s.unread,
        SessionFilter.archived => s.archived,
      };
    }).toList();
    matched.sort((a, b) {
      final pinCmp = (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0);
      if (pinCmp != 0) return pinCmp;
      final tsCmp = (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0);
      return tsCmp != 0 ? tsCmp : a.id.compareTo(b.id);
    });
    _cachedMatchedSessionIds = {for (final s in matched) s.id};

    final wsById = {for (final w in workspaces) w.id: w};
    final wsByPath = {
      for (final w in workspaces)
        if (w.path.isNotEmpty) _normalizeDirPath(w.path): w,
    };
    final flatItems = <Object>[];
    final grouped = <String, List<ChatSessionItem>>{};
    int ungroupedWithCwdCount = 0;

    if (groupMode == SessionGroupMode.workspace) {
      final groupLabels = <String, (String, bool, String?)>{};
      for (final s in matched) {
        String key;
        String label;
        bool explicit = false;
        String? dirPath = s.cwd;
        if (s.workspaceId != null && s.workspaceId!.isNotEmpty) {
          final w = wsById[s.workspaceId!];
          key = 'ws:${s.workspaceId}';
          label = (w != null && w.name.isNotEmpty)
              ? w.name
              : (s.workspaceName?.isNotEmpty == true ? s.workspaceName! : s.workspaceId!);
          explicit = true;
          dirPath = w?.path ?? s.cwd;
        } else if (s.cwd != null && s.cwd!.isNotEmpty) {
          final clean = _normalizeDirPath(s.cwd!);
          final w = wsByPath[clean];
          if (w != null && w.explicit) {
            key = 'ws:${w.id}';
            label = w.name;
            explicit = true;
            dirPath = w.path;
          } else {
            ungroupedWithCwdCount++;
            final idx = clean.lastIndexOf('/');
            final folder = idx >= 0 && idx < clean.length - 1 ? clean.substring(idx + 1) : clean;
            key = 'dir:$clean';
            label = folder;
            explicit = false;
            dirPath = clean;
          }
        } else {
          key = 'ungrouped';
          label = '未分组';
        }
        groupLabels[key] = (label, explicit, dirPath);
        grouped.putIfAbsent(key, () => []).add(s);
      }

      int maxUpdated(List<ChatSessionItem> list) {
        var best = 0;
        for (final s in list) {
          final ts = s.updatedAt ?? 0;
          if (ts > best) best = ts;
        }
        return best;
      }

      final orderedKeys = grouped.keys.toList()
        ..sort((a, b) {
          if (a == 'ungrouped') return 1;
          if (b == 'ungrouped') return -1;
          final ea = groupLabels[a]!.$2 ? 0 : 1;
          final eb = groupLabels[b]!.$2 ? 0 : 1;
          if (ea != eb) return ea.compareTo(eb);
          return maxUpdated(grouped[b]!).compareTo(maxUpdated(grouped[a]!));
        });

      for (final k in orderedKeys) {
        final list = grouped[k]!;
        final meta = groupLabels[k]!;
        final collapsed = _collapsedGroups.contains(k);
        flatItems.add(_SidebarGroupHeader(
          groupKey: k,
          title: meta.$1,
          count: list.length,
          isWorkspace: true,
          isExplicitWorkspace: meta.$2,
          dirPath: meta.$3,
          collapsed: collapsed,
        ));
        if (!collapsed) {
          flatItems.addAll(list);
        }
      }
    } else {
      for (final s in matched) {
        grouped.putIfAbsent(s.group, () => []).add(s);
      }
      const groupOrder = ['今天', '昨天', '本周', '更早'];
      for (final g in groupOrder) {
        final list = grouped[g];
        if (list != null && list.isNotEmpty) {
          flatItems.add(_SidebarGroupHeader(
            groupKey: 'date:$g',
            title: g,
            count: list.length,
            isWorkspace: false,
            isExplicitWorkspace: false,
            collapsed: false,
          ));
          flatItems.addAll(list);
        }
      }
      for (final entry in grouped.entries) {
        if (!groupOrder.contains(entry.key) && entry.value.isNotEmpty) {
          flatItems.add(_SidebarGroupHeader(
            groupKey: 'date:${entry.key}',
            title: entry.key,
            count: entry.value.length,
            isWorkspace: false,
            isExplicitWorkspace: false,
            collapsed: false,
          ));
          flatItems.addAll(entry.value);
        }
      }
    }

    _cachedFlatItems = flatItems;
    _cachedUngroupedWithCwdCount = ungroupedWithCwdCount;
  }

  bool _handleDrawerBack() {
    if (!mounted) return false;
    if (_multiSelectMode) {
      setState(() {
        _multiSelectMode = false;
        _selectedIds.clear();
      });
      return true;
    }
    if (_searchCtrl.text.isNotEmpty || ref.read(appProvider).searchQuery.isNotEmpty) {
      _searchCtrl.clear();
      ref.read(appProvider.notifier).setSearchQuery('');
      FocusScope.of(context).unfocus();
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    final init = ref.read(appProvider);
    _searchCtrl = TextEditingController(text: init.searchQuery);
    _lastHostId = init.activeHostId;
    final savedCollapsed = _persistedCollapsedByHost[_lastHostId];
    if (savedCollapsed != null && savedCollapsed.isNotEmpty) {
      _collapsedGroups.addAll(savedCollapsed);
    }
    widget.backHandlerNotifier?.value = _handleDrawerBack;
  }

  @override
  void didUpdateWidget(covariant SessionsSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backHandlerNotifier != widget.backHandlerNotifier) {
      if (oldWidget.backHandlerNotifier?.value == _handleDrawerBack) {
        oldWidget.backHandlerNotifier?.value = null;
      }
      widget.backHandlerNotifier?.value = _handleDrawerBack;
    }
  }

  @override
  void dispose() {
    if (widget.backHandlerNotifier?.value == _handleDrawerBack) {
      widget.backHandlerNotifier?.value = null;
    }
    _searchCtrl.dispose();
    _searchFocused.dispose();
    super.dispose();
  }

  void _openRenameSheet(BuildContext context, ChatSessionItem s) {
    showRenameSessionSheet(context, ref, s);
  }

  void _openSessionActionsSheet(BuildContext context, ChatSessionItem s, {Offset? anchor}) {
    final ctrl = ref.read(appProvider.notifier);
    final tier = ref.read(appProvider).glassTier;
    unawaited(
      showGrassBagGlassContextMenu(
        context,
        tier: tier,
        globalAnchor: anchor,
        headerTitle: s.title,
        items: [
          GrassBagContextMenuItem(
            label: s.pinned ? '取消置顶' : '置顶对话',
            icon: s.pinned ? CupertinoIcons.pin_slash_fill : CupertinoIcons.pin_fill,
            selected: s.pinned,
            onTap: () => ctrl.togglePinSession(s.id),
          ),
          GrassBagContextMenuItem(
            label: '重命名',
            icon: CupertinoIcons.pencil,
            onTap: () async {
              await Future<void>.delayed(const Duration(milliseconds: 90));
              if (!mounted || !context.mounted) return;
              _openRenameSheet(context, s);
            },
          ),
          GrassBagContextMenuItem(
            label: s.archived ? '取消归档' : '归档对话',
            icon: CupertinoIcons.archivebox_fill,
            onTap: () => ctrl.toggleArchiveSession(s.id),
          ),
          GrassBagContextMenuItem(
            label: '删除对话',
            icon: CupertinoIcons.trash_fill,
            destructive: true,
            dividerBefore: true,
            onTap: () async {
              await Future<void>.delayed(const Duration(milliseconds: 90));
              if (!mounted || !context.mounted) return;
              final ok = await showGrassBagConfirmDialog(
                context,
                title: '删除「${s.title}」？',
                message: '删除后该对话历史将从当前 DSH 主机移除，不可恢复。',
                confirmLabel: '删除',
                isDestructive: true,
              );
              if (ok) ctrl.deleteSessionsBatch({s.id});
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Narrow rebuild scope: NEVER select computed list getters like `s.filteredSessions`!
    // Streaming token deltas, chat turns, step toggles, and toasts trigger ZERO rebuilds!
    final state = ref.watch(
      appProvider.select(
        (s) => (
          workspaces: s.workspaces,
          sessions: s.sessions,
          loadingSessions: s.loadingSessions,
          activeSessionId: s.activeSessionId,
          activeWorkspace: s.activeWorkspace,
          sidebarWorkspaceFilter: s.sidebarWorkspaceFilter,
          sessionGroupMode: s.sessionGroupMode,
          searchQuery: s.searchQuery,
          searchSnippets: s.searchSnippets,
          filter: s.filter,
          activeHostId: s.activeHostId,
          activeHost: s.activeHost,
          localHost: s.localHost,
          hasUnignoredAppUpdate: s.hasUnignoredAppUpdate,
          isActiveHostDesktop: s.isActiveHostDesktop,
          hostStatusLabel: s.hostStatusLabel(s.activeHost),
          hostIsHealthy: s.hostIsHealthy(s.activeHost),
          hostIsConnecting: s.hostIsConnecting(s.activeHost),
          hostHasError: s.hostHasError(s.activeHost),
          connectionPhase: s.connectionPhase,
          glassTier: s.glassTier,
        ),
      ),
    );
    if (_lastHostId != state.activeHostId) {
      _lastHostId = state.activeHostId;
      _multiSelectMode = false;
      _selectedIds.clear();
      _collapsedGroups
        ..clear()
        ..addAll(_persistedCollapsedByHost[state.activeHostId] ?? const <String>{});
      _collapsedGroupsVersion++;
    }
    if (_multiSelectMode &&
        (_cacheFilter != state.filter ||
            _cacheWsFilter != state.sidebarWorkspaceFilter ||
            _cacheSearchQuery != state.searchQuery)) {
      _multiSelectMode = false;
      _selectedIds.clear();
    }
    if (state.searchQuery.isEmpty && _searchCtrl.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(appProvider).searchQuery.isEmpty && _searchCtrl.text.isNotEmpty) {
          _searchCtrl.clear();
        }
      });
    }
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final topInset = MediaQuery.viewPaddingOf(context).top;
    final botInset = MediaQuery.viewPaddingOf(context).bottom;
    final topPad = widget.isTabletDocked ? topInset : 4.0;
    final botPad = widget.isTabletDocked ? botInset : 4.0;

    _ensureFlatItems(
      sessions: state.sessions,
      workspaces: state.workspaces,
      sidebarWorkspaceFilter: state.sidebarWorkspaceFilter,
      searchQuery: state.searchQuery,
      searchSnippets: state.searchSnippets,
      filter: state.filter,
      groupMode: state.sessionGroupMode,
    );
    final flatItems = _cachedFlatItems;
    final ungroupedWithCwdCount = _cachedUngroupedWithCwdCount;

    if (_selectedIds.isNotEmpty) {
      _selectedIds.removeWhere((id) => !_cachedMatchedSessionIds.contains(id));
    }

    final host = state.activeHost;
    final hasPending = state.sessions.any((s) => !s.archived && s.pendingApproval);

    final content = Column(
      children: [
        // Brand Header: Cute GrassBag Mascot directly beside wordmark (no bulky box!)
        Padding(
          padding: EdgeInsets.fromLTRB(16, topPad + 8, 12, 8),
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      ctrl.startNewChat();
                      widget.onCloseDrawer?.call();
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: [
                        const GrassBagMascot(size: 27),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'GrassBag',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.3,
                              color: t.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                GrassBagSpringTap(
                  pressedScale: 0.94,
                  haptic: true,
                  onTap: () {
                    ctrl.startNewChat();
                    widget.onCloseDrawer?.call();
                  },
                  child: Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [t.primaryHi, t.primary],
                      ),
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: t.primary.withValues(alpha: 0.30),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.square_pencil, size: 14.5, color: t.onPrimary),
                        const SizedBox(width: 5),
                        Text(
                          '新对话',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: t.onPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.isTabletDocked) ...[
                  const SizedBox(width: 6),
                  Tooltip(
                    message: '收起侧边栏',
                    child: GrassBagSpringTap(
                      onTap: () => ctrl.setTabletSidebarOpen(false),
                      pressedScale: 0.88,
                      haptic: true,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(color: t.fill1, shape: BoxShape.circle),
                        child: Icon(CupertinoIcons.sidebar_left, size: 15.5, color: t.text2),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // Unified Liquid Glass Pill Search Bar
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
          child: Focus(
            onFocusChange: (focused) => _searchFocused.value = focused,
            child: GrassBagGlassSearchBar(
              controller: _searchCtrl,
              placeholder: '搜索对话',
              tier: state.glassTier,
              insideGlass: true,
              onChanged: ctrl.setSearchQuery,
            ),
          ),
        ),

        // Horizontal Editorial Filter Pills (edge-to-edge scroll padding so last pill never clips!)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Row(
            children: [
              for (final f in SessionFilter.values) ...[
                _FilterChipPill(
                  label: f.label,
                  active: state.filter == f,
                  showWarnDot: f == SessionFilter.pending && hasPending && state.filter != f,
                  onTap: () => ctrl.setFilter(f),
                ),
                if (f != SessionFilter.values.last) const SizedBox(width: 4.5),
              ],
            ],
          ),
        ),

        // Subtle Workspace Filter + Compact Action Cluster (leaves ≥145dp for workspace label!)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showWorkspaceSheet(context, ref, forSidebarFilter: true),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          state.sidebarWorkspaceFilter != null
                              ? CupertinoIcons.folder_fill
                              : CupertinoIcons.square_stack_3d_down_right,
                          size: 13.5,
                          color: state.sidebarWorkspaceFilter != null ? t.primary : t.text2,
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            () {
                              final f = state.sidebarWorkspaceFilter;
                              if (f == null) return '全部工作区';
                              final normF = _normalizeDirPath(f);
                              final matchedWs = state.workspaces
                                  .where(
                                    (w) =>
                                        w.id == f ||
                                        w.path == f ||
                                        w.name == f ||
                                        (w.path.isNotEmpty && _normalizeDirPath(w.path) == normF),
                                  )
                                  .firstOrNull;
                              return matchedWs?.name ?? f;
                            }(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.2,
                              fontWeight: state.sidebarWorkspaceFilter != null
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: state.sidebarWorkspaceFilter != null ? t.primary : t.text2,
                            ),
                          ),
                        ),
                        if (state.sidebarWorkspaceFilter != null) ...[
                          const SizedBox(width: 2),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => ctrl.setSidebarWorkspaceFilter(null),
                            child: SizedBox(
                              width: 26,
                              height: 26,
                              child: Center(
                                child: Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: t.primarySoft,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(CupertinoIcons.xmark, size: 9.5, color: t.primary),
                                ),
                              ),
                            ),
                          ),
                        ] else ...[
                          const SizedBox(width: 2),
                          Icon(CupertinoIcons.chevron_down, size: 10.5, color: t.text3),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: state.sessionGroupMode == SessionGroupMode.workspace
                        ? '当前按目录分组，点击切换按时间'
                        : '当前按时间分组，点击切换按目录',
                    child: GrassBagSpringTap(
                      pressedScale: 0.9,
                      haptic: true,
                      onTap: () => ctrl.setSessionGroupMode(
                        state.sessionGroupMode == SessionGroupMode.workspace
                            ? SessionGroupMode.date
                            : SessionGroupMode.workspace,
                      ),
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: Center(
                          child: Icon(
                            state.sessionGroupMode == SessionGroupMode.workspace
                                ? CupertinoIcons.folder
                                : CupertinoIcons.clock,
                            size: 14.5,
                            color: t.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Tooltip(
                    message: _multiSelectMode ? '退出多选' : '批量多选',
                    child: GrassBagSpringTap(
                      pressedScale: 0.9,
                      haptic: true,
                      onTap: () => setState(() {
                        _multiSelectMode = !_multiSelectMode;
                        _selectedIds.clear();
                      }),
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: Center(
                          child: Icon(
                            _multiSelectMode
                                ? CupertinoIcons.checkmark_circle_fill
                                : CupertinoIcons.checkmark_circle,
                            size: 14.5,
                            color: _multiSelectMode ? t.primary : t.text2,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Tooltip(
                    message: '刷新当前主机对话列表',
                    child: GrassBagSpringTap(
                      pressedScale: 0.9,
                      haptic: true,
                      onTap: () {
                        if (!state.loadingSessions) ctrl.refreshSessionsList();
                      },
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: Center(
                          child: state.loadingSessions
                              ? CupertinoActivityIndicator(radius: 6.5, color: t.primary)
                              : Icon(CupertinoIcons.refresh, size: 14, color: t.text2),
                        ),
                      ),
                    ),
                  ),
                  Tooltip(
                    message: '打开终端',
                    child: GrassBagSpringTap(
                      pressedScale: 0.9,
                      haptic: true,
                      onTap: () {
                        widget.onCloseDrawer?.call();
                        widget.onOpenTerminal();
                      },
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: Center(
                          child: Icon(
                            CupertinoIcons.chevron_left_slash_chevron_right,
                            size: 14,
                            color: t.text2,
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
        if (state.sessionGroupMode == SessionGroupMode.workspace &&
            ungroupedWithCwdCount > 0 &&
            state.connectionPhase == ConnectionPhase.connected)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
            child: GrassBagSpringTap(
              onTap: () => ctrl.organizeWorkspacesByCwd(),
              pressedScale: 0.98,
              haptic: true,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: t.primarySoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.folder_badge_plus, size: 13.5, color: t.primary),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '将 $ungroupedWithCwdCount 条对话按文件夹归组为工作区',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: t.primary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_multiSelectMode)
          Builder(
            builder: (_) {
              final allVisibleIds = <String>{
                for (final item in flatItems)
                  if (item is ChatSessionItem) item.id,
              };
              final allSelected =
                  allVisibleIds.isNotEmpty && _selectedIds.length == allVisibleIds.length;
              return Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
                child: SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    alignment: WrapAlignment.spaceBetween,
                    children: [
                    Text(
                      _selectedIds.isEmpty ? '请选择要操作的对话' : '已选 ${_selectedIds.length} 项',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text2),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (allVisibleIds.isNotEmpty) ...[
                          GrassBagSpringTap(
                            onTap: () {
                              setState(() {
                                if (allSelected) {
                                  _selectedIds.clear();
                                } else {
                                  _selectedIds
                                    ..clear()
                                    ..addAll(allVisibleIds);
                                }
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                              decoration: BoxDecoration(
                                color: t.primarySoft,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                allSelected ? '全不选' : '全选',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: t.primary,
                                ),
                              ),
                            ),
                          ),
                        ],
                        if (_selectedIds.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          GrassBagSpringTap(
                            onTap: () {
                              final ids = Set<String>.of(_selectedIds);
                              final targetArchived = state.filter != SessionFilter.archived;
                              ctrl.archiveSessionsBatch(ids, archived: targetArchived);
                              setState(() {
                                _selectedIds.clear();
                                _multiSelectMode = false;
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                              decoration: BoxDecoration(
                                color: t.fill1,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                state.filter == SessionFilter.archived ? '还原' : '归档',
                                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.text),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          GrassBagSpringTap(
                            onTap: () async {
                              final ids = Set<String>.of(_selectedIds);
                              final ok = await showGrassBagConfirmDialog(
                                context,
                                title: '删除已选 ${ids.length} 条对话？',
                                message: '删除后所选对话历史将从当前 DSH 主机永久移除，不可恢复。',
                                confirmLabel: '删除 (${ids.length})',
                                isDestructive: true,
                              );
                              if (!ok || !mounted) return;
                              ctrl.deleteSessionsBatch(ids);
                              setState(() {
                                _selectedIds.clear();
                                _multiSelectMode = false;
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                              decoration: BoxDecoration(
                                color: t.errSoft,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text('删除', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.err)),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
                ),
              );
            },
          ),

        // Grouped Sessions List (always keeps CustomScrollView + pull-to-refresh + keyboard dismiss;
        // zero ShaderMask saveLayer and zero opaque top band over translucent Liquid Glass!)
        Expanded(
          child: CustomScrollView(
                key: PageStorageKey<String>(
                  'sessions-drawer-${state.activeHostId}-${state.sessionGroupMode.name}',
                ),
                cacheExtent: 700,
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
              CupertinoSliverRefreshControl(
                onRefresh: () => ctrl.refreshSessionsList(silent: true),
              ),
              if (flatItems.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Builder(
                    builder: (_) {
                      final isSyncingSessions = state.sessions.isEmpty &&
                          (state.loadingSessions ||
                              state.connectionPhase == ConnectionPhase.connecting ||
                              state.connectionPhase == ConnectionPhase.reconnecting);
                      final isNeedsAuth = state.sessions.isEmpty &&
                          (state.connectionPhase == ConnectionPhase.needsAuth || host.needsAuth);
                      final isConnectError = !isNeedsAuth &&
                          state.sessions.isEmpty &&
                          state.connectionPhase == ConnectionPhase.error;
                      return ValueListenableBuilder<bool>(
                        valueListenable: _searchFocused,
                        builder: (_, focused, emptyChild) => focused
                            ? _FocusedSearchInsetPadding(child: emptyChild!)
                            : emptyChild!,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                            child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isSyncingSessions)
                                CupertinoActivityIndicator(radius: 12, color: t.primary)
                              else
                                Icon(
                                  isNeedsAuth
                                      ? CupertinoIcons.lock_shield_fill
                                      : isConnectError
                                          ? CupertinoIcons.wifi_exclamationmark
                                          : (state.sessions.isEmpty
                                              ? CupertinoIcons.sparkles
                                              : CupertinoIcons.chat_bubble_2),
                                  size: 28,
                                  color: isNeedsAuth
                                      ? t.primary.withValues(alpha: 0.85)
                                      : isConnectError
                                          ? t.err.withValues(alpha: 0.8)
                                          : t.text3.withValues(alpha: 0.65),
                                ),
                              const SizedBox(height: 8),
                              Text(
                                isSyncingSessions
                                    ? '正在同步「${host.name}」的对话…'
                                    : isNeedsAuth
                                        ? '「${host.name}」等待一次授权'
                                        : isConnectError
                                            ? '无法连接到「${host.name}」'
                                            : (state.sessions.isEmpty
                                                ? '还没有历史对话'
                                                : (state.searchQuery.trim().isNotEmpty ||
                                                        state.sidebarWorkspaceFilter != null
                                                    ? '没有找到匹配对话'
                                                    : switch (state.filter) {
                                                        SessionFilter.pending => '暂无待确认审批',
                                                        SessionFilter.running => '暂无运行中对话',
                                                        SessionFilter.unread => '暂无未读对话',
                                                        SessionFilter.archived => '暂无归档对话',
                                                        SessionFilter.all => '没有找到匹配对话',
                                                      })),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w500,
                                  color: t.text2,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                isSyncingSessions
                                    ? '正在拉取最新会话列表与工作区目录'
                                    : isNeedsAuth
                                        ? '主机已连通，粘贴启动链接或完成网页登录后 30 天内免填 Token'
                                        : isConnectError
                                            ? (host.lastError?.isNotEmpty == true
                                                ? host.lastError!
                                                : '请检查主机地址、网络连通性或电脑端是否已开启局域网访问')
                                            : (state.sessions.isEmpty
                                                ? '发送第一条消息即可自动创建并按工作区归组'
                                                : (state.searchQuery.trim().isNotEmpty ||
                                                        state.sidebarWorkspaceFilter != null
                                                    ? '尝试更改搜索关键词或切换到其他筛选分类'
                                                    : switch (state.filter) {
                                                        SessionFilter.pending => '当助手请求执行命令或修改文件时会在此提醒',
                                                        SessionFilter.running => '正在后台生成或执行任务的对话会自动出现在此处',
                                                        SessionFilter.unread => '所有历史对话均已查看完毕',
                                                        SessionFilter.archived => '可在对话「···」菜单中归档不再常用的会话',
                                                        SessionFilter.all => '尝试更改搜索关键词或切换到其他筛选分类',
                                                      })),
                                textAlign: TextAlign.center,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11.5, color: t.text3),
                              ),
                              const SizedBox(height: 12),
                              if (isNeedsAuth)
                                GrassBagSpringTap(
                                  onTap: () => showRemoteHostAuthSheet(context, ref, host),
                                  pressedScale: 0.94,
                                  haptic: true,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: t.primarySoft,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      '立即授权',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: t.primary,
                                      ),
                                    ),
                                  ),
                                )
                              else if (isConnectError)
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    GrassBagSpringTap(
                                      onTap: () => ctrl.probeAndRefreshHost(state.activeHostId),
                                      pressedScale: 0.94,
                                      haptic: true,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: t.primarySoft,
                                          borderRadius: BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          '重新连接',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: t.primary,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    GrassBagSpringTap(
                                      onTap: () {
                                        widget.onCloseDrawer?.call();
                                        widget.onOpenHostsSettings();
                                      },
                                      pressedScale: 0.94,
                                      haptic: true,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: t.fill1,
                                          borderRadius: BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          '主机设置',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: t.text2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              else if (!isSyncingSessions &&
                                  (state.searchQuery.isNotEmpty ||
                                      state.filter != SessionFilter.all ||
                                      state.sidebarWorkspaceFilter != null))
                                GrassBagSpringTap(
                                  onTap: () {
                                    _searchCtrl.clear();
                                    ctrl.setSearchQuery('');
                                    ctrl.setFilter(SessionFilter.all);
                                    ctrl.setSidebarWorkspaceFilter(null);
                                  },
                                  pressedScale: 0.94,
                                  haptic: true,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: t.primarySoft,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      '重置筛选',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: t.primary,
                                      ),
                                    ),
                                  ),
                                )
                              else if (!isSyncingSessions && state.sessions.isEmpty)
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    GrassBagSpringTap(
                                      onTap: () {
                                        ctrl.startNewChat();
                                        widget.onCloseDrawer?.call();
                                      },
                                      pressedScale: 0.94,
                                      haptic: true,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: t.primarySoft,
                                          borderRadius: BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          '开始新对话',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: t.primary,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    GrassBagSpringTap(
                                      onTap: () => ctrl.refreshSessionsList(),
                                      pressedScale: 0.94,
                                      haptic: true,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: t.fill1,
                                          borderRadius: BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          '刷新',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: t.text2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  sliver: SliverList.builder(
                    itemCount: flatItems.length,
                    itemBuilder: (ctx, idx) {
                    final item = flatItems[idx];
                    if (item is _SidebarGroupHeader) {
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: item.isWorkspace
                            ? () => setState(() {
                                  if (!_collapsedGroups.add(item.groupKey)) {
                                    _collapsedGroups.remove(item.groupKey);
                                  }
                                  final hostKey = _lastHostId ?? state.activeHostId;
                                  _persistedCollapsedByHost[hostKey] =
                                      Set<String>.of(_collapsedGroups);
                                  _collapsedGroupsVersion++;
                                })
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 12, 6, 4),
                          child: Row(
                            children: [
                              if (item.isWorkspace) ...[
                                Icon(
                                  item.collapsed
                                      ? CupertinoIcons.chevron_right
                                      : CupertinoIcons.chevron_down,
                                  size: 11,
                                  color: t.text3,
                                ),
                                const SizedBox(width: 5),
                                Icon(
                                  item.isExplicitWorkspace
                                      ? CupertinoIcons.folder_fill
                                      : CupertinoIcons.folder,
                                  size: 12.5,
                                  color: item.isExplicitWorkspace ? t.primary : t.text3,
                                ),
                                const SizedBox(width: 5),
                              ],
                              Expanded(
                                child: Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: item.isExplicitWorkspace ? t.text2 : t.text3,
                                  ),
                                ),
                              ),
                              Text(
                                '${item.count}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                  color: t.text3,
                                ),
                              ),
                              if (item.isWorkspace && item.groupKey != 'ungrouped') ...[
                                const SizedBox(width: 6),
                                Tooltip(
                                  message: '在「${item.title}」新建对话',
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      ctrl.startNewChat(
                                        workspace: (item.dirPath != null && item.dirPath!.isNotEmpty)
                                            ? item.dirPath
                                            : item.title,
                                      );
                                      widget.onCloseDrawer?.call();
                                    },
                                    child: SizedBox(
                                      width: 32,
                                      height: 28,
                                      child: Center(
                                        child: Icon(
                                          CupertinoIcons.plus,
                                          size: 13.5,
                                          color: t.text3,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    }
                    final s = item as ChatSessionItem;
                    final snippet = state.searchQuery.trim().isNotEmpty
                        ? state.searchSnippets[s.id]
                        : null;
                    return _SessionListRow(
                      key: ValueKey('row-${s.id}'),
                      session: s,
                      snippet: snippet,
                      active: s.id == state.activeSessionId,
                      multiSelectMode: _multiSelectMode,
                      selected: _selectedIds.contains(s.id),
                      onTap: () {
                        if (_multiSelectMode) {
                          setState(() {
                            if (!_selectedIds.add(s.id)) _selectedIds.remove(s.id);
                          });
                        } else {
                          ctrl.selectSession(s.id);
                          widget.onCloseDrawer?.call();
                        }
                      },
                      onTogglePin: () => ctrl.togglePinSession(s.id),
                      onMoreActions: (anchor) => _openSessionActionsSheet(context, s, anchor: anchor),
                    );
                      },
                    ),
                  ),
                  // Mount a dedicated leaf ONLY while the drawer search box is focused so
                  // unmounting drops the MediaQuery.viewInsetsOf InheritedElement subscription!
                  SliverToBoxAdapter(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _searchFocused,
                      builder: (_, focused, __) => focused
                          ? const _FocusedSearchInsetSpacer()
                          : const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
        ),

        // Airy De-Boxed Borderless Footer Tray (dsh-Go × macOS craft!)
        Container(
          padding: EdgeInsets.fromLTRB(12, 10, 12, botPad > 0 ? botPad + 6 : 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: t.sep, width: 0.5)),
          ),
          child: Row(
            children: [
              Expanded(
                child: GrassBagSpringTap(
                  pressedScale: 0.97,
                  haptic: true,
                  onTap: () => showHostQuickSheet(
                    context,
                    ref,
                    onConnected: widget.onCloseDrawer,
                    onOpenHostSettings: () {
                      widget.onCloseDrawer?.call();
                      widget.onOpenHostsSettings();
                    },
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: t.primarySoft,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                state.isActiveHostDesktop
                                    ? CupertinoIcons.desktopcomputer
                                    : CupertinoIcons.device_phone_portrait,
                                size: 17,
                                color: t.primary,
                              ),
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: GrassBagStatusDot(
                                size: 10,
                                pulsing: state.hostIsConnecting,
                                color: state.hostIsHealthy
                                    ? t.ok
                                    : (host.needsAuth || state.hostIsConnecting
                                        ? t.primary
                                        : (state.hostHasError ? t.err : t.text3)),
                                border: Border.all(
                                  color: widget.isTabletDocked
                                      ? t.sidebarDocked
                                      : t.sheetTop,
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      host.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: t.text,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  Icon(CupertinoIcons.chevron_up_chevron_down,
                                      size: 11, color: t.text3),
                                ],
                              ),
                              Text(
                                state.hostStatusLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: state.hostHasError ? t.err : t.text3,
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
              const SizedBox(width: 6),
              _FooterIconButton(
                icon: CupertinoIcons.square_grid_2x2_fill,
                tooltip: '全部功能',
                onTap: () {
                  widget.onCloseDrawer?.call();
                  widget.onOpenFeatures();
                },
              ),
              const SizedBox(width: 6),
              _FooterIconButton(
                icon: CupertinoIcons.gear_solid,
                tooltip: '设置',
                showBadge: state.localHost.hasLocalUpdates || state.hasUnignoredAppUpdate,
                onTap: () {
                  widget.onCloseDrawer?.call();
                  widget.onOpenSettings();
                },
              ),
            ],
          ),
        ),
      ],
    );

    if (widget.isTabletDocked) {
      return Container(
        width: 288,
        decoration: BoxDecoration(
          color: t.sidebarDocked,
          border: Border(right: BorderSide(color: t.sep, width: 0.5)),
        ),
        child: content,
      );
    }

    // Phone floating iOS 26 Liquid Glass Drawer (genuine refractive GlassContainer!)
    return Padding(
      padding: EdgeInsets.fromLTRB(
        8,
        topInset > 0 ? topInset + 4 : 10,
        0,
        botInset > 0 ? botInset + 4 : 10,
      ),
      child: GrassBagGlass(
        tier: state.glassTier,
        borderRadius: 32,
        elevated: true,
        useSheetSettings: true,
        // Isolate drawer scroll repaints from the outer RenderLiquidGlassLayer!
        child: RepaintBoundary(child: content),
      ),
    );
  }
}

class _FilterChipPill extends StatelessWidget {
  const _FilterChipPill({
    required this.label,
    required this.active,
    required this.showWarnDot,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool showWarnDot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GrassBagFilterChip(
      label: label,
      selected: active,
      showDot: showWarnDot,
      padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 5),
      fontSize: 11.5,
      onTap: onTap,
    );
  }
}

class _SessionListRow extends StatefulWidget {
  const _SessionListRow({
    super.key,
    required this.session,
    required this.active,
    required this.onTap,
    required this.onTogglePin,
    required this.onMoreActions,
    this.snippet,
    this.multiSelectMode = false,
    this.selected = false,
  });

  final ChatSessionItem session;
  final String? snippet;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onTogglePin;
  final ValueChanged<Offset?> onMoreActions;
  final bool multiSelectMode;
  final bool selected;

  @override
  State<_SessionListRow> createState() => _SessionListRowState();
}

class _SessionListRowState extends State<_SessionListRow> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final s = widget.session;
    final highlighted = widget.multiSelectMode ? widget.selected : widget.active;
    final cleanSnippet = widget.snippet?.trim() ?? '';
    final showSnippet = cleanSnippet.isNotEmpty && cleanSnippet != s.title.trim();

    Widget? buildStatusBadge() {
      if (s.pendingApproval) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
          decoration: BoxDecoration(
            color: t.warnSoft,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '待确认',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: t.warn),
          ),
        );
      }
      if (s.running) {
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: t.ok, shape: BoxShape.circle),
        );
      }
      if (s.unread) {
        return Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: t.primary, shape: BoxShape.circle),
        );
      }
      return null;
    }

    final statusBadge = buildStatusBadge();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) {
            if (!_pressed) setState(() => _pressed = true);
          },
          onTapUp: (_) {
            if (_pressed) setState(() => _pressed = false);
          },
          onTapCancel: () {
            if (_pressed) setState(() => _pressed = false);
          },
          onTap: widget.onTap,
          onLongPressStart: widget.multiSelectMode
              ? null
              : (d) {
                  if (_pressed) setState(() => _pressed = false);
                  widget.onMoreActions(d.globalPosition);
                },
          onSecondaryTapDown: widget.multiSelectMode
              ? null
              : (d) => widget.onMoreActions(d.globalPosition),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            constraints: BoxConstraints(minHeight: showSnippet ? 54 : 44),
            padding: EdgeInsets.symmetric(
              horizontal: 11,
              vertical: showSnippet ? 7 : 0,
            ),
            decoration: BoxDecoration(
              color: highlighted
                  ? t.primarySoft
                  : (_pressed ? t.fill2 : (_hovered ? t.fill1 : Colors.transparent)),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: highlighted ? t.primary.withValues(alpha: 0.26) : Colors.transparent,
                width: 0.6,
              ),
            ),
            child: Row(
              children: [
                if (widget.multiSelectMode) ...[
                  Icon(
                    widget.selected ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                    size: 18,
                    color: widget.selected ? t.primary : t.text3,
                  ),
                  const SizedBox(width: 8),
                ] else if (widget.active) ...[
                  Container(
                    width: 3,
                    height: 16,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: t.primary,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ],
                if (s.pinned) ...[
                  Icon(CupertinoIcons.pin_fill, size: 11.5, color: t.primary),
                  const SizedBox(width: 5),
                ],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: widget.active ? FontWeight.w600 : FontWeight.w400,
                          color: (widget.active || _hovered) ? t.text : t.text2,
                        ),
                      ),
                      if (showSnippet) ...[
                        const SizedBox(height: 2),
                        Text(
                          cleanSnippet,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: t.text3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (statusBadge != null) ...[
                  const SizedBox(width: 6),
                  statusBadge,
                ],
                if (!widget.multiSelectMode) ...[
                  const SizedBox(width: 2),
                  if (_hovered)
                    GrassBagSpringTap(
                      onTap: widget.onTogglePin,
                      pressedScale: 0.88,
                      haptic: true,
                      child: SizedBox(
                        width: 32,
                        height: 34,
                        child: Center(
                          child: Icon(
                            s.pinned ? CupertinoIcons.pin_slash : CupertinoIcons.pin,
                            size: 13.5,
                            color: t.text3,
                          ),
                        ),
                      ),
                    ),
                  Builder(
                    builder: (btnCtx) => GrassBagSpringTap(
                      onTap: () {
                        final box = btnCtx.findRenderObject() as RenderBox?;
                        final anchor = box?.localToGlobal(box.size.center(Offset.zero));
                        widget.onMoreActions(anchor);
                      },
                      pressedScale: 0.88,
                      haptic: true,
                      child: SizedBox(
                        width: 38,
                        height: 40,
                        child: Center(
                          child: Icon(
                            CupertinoIcons.ellipsis,
                            size: 15,
                            color: (_hovered || widget.active)
                                ? t.text2
                                : t.text2.withValues(alpha: 0.72),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FooterIconButton extends StatelessWidget {
  const _FooterIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.showBadge = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: GrassBagSpringTap(
        onTap: onTap,
        pressedScale: 0.90,
        haptic: true,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: t.fill1, shape: BoxShape.circle),
              child: Icon(icon, size: 18, color: t.text2),
            ),
              if (showBadge)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: t.warn, shape: BoxShape.circle),
                  ),
                ),
            ],
          ),
        ),
      );
    }
  }

@immutable
class _SidebarGroupHeader {
  const _SidebarGroupHeader({
    required this.groupKey,
    required this.title,
    required this.count,
    required this.isWorkspace,
    required this.isExplicitWorkspace,
    this.dirPath,
    required this.collapsed,
  });

  final String groupKey;
  final String title;
  final int count;
  final bool isWorkspace;
  final bool isExplicitWorkspace;
  final String? dirPath;
  final bool collapsed;
}

/// Mounts ONLY while the drawer search box has focus so `SessionsSidebar` holds
/// zero `MediaQuery.viewInsetsOf` InheritedElement subscription at rest or on Tablet.
class _FocusedSearchInsetSpacer extends StatelessWidget {
  const _FocusedSearchInsetSpacer();

  @override
  Widget build(BuildContext context) {
    final kb = MediaQuery.viewInsetsOf(context).bottom;
    return SizedBox(height: kb > 0 ? kb : 0);
  }
}

class _FocusedSearchInsetPadding extends StatelessWidget {
  const _FocusedSearchInsetPadding({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final kb = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: kb > 0 ? kb : 0),
      child: child,
    );
  }
}
