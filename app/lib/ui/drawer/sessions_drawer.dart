import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final ScrollController _listScrollCtrl = ScrollController();
  final ValueNotifier<bool> _searchFocused = ValueNotifier<bool>(false);
  bool _multiSelectMode = false;
  final Set<String> _selectedIds = {};
  final Set<String> _collapsedGroups = {};
  Set<String>? _collapsedBeforeMultiSelect;
  String? _lastAutoExpandedSessionId;
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
  String? _cacheActiveSessionId;
  int _cacheCollapsedVer = -1;
  List<Object> _cachedFlatItems = const [];
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

  static bool _sessionMatchesWorkspaceFilter(
    ChatSessionItem s,
    String wsFilter,
    String normWsFilter,
    WorkspaceItem? filterWsItem,
    String normFilterItemPath,
  ) {
    if (wsFilter.isEmpty) return true;
    final normCwd = (s.cwd != null && s.cwd!.isNotEmpty) ? _normalizeDirPath(s.cwd!) : '';
    return (filterWsItem != null &&
            (s.workspaceId == filterWsItem.id ||
                s.workspaceName == filterWsItem.name ||
                (normFilterItemPath.isNotEmpty && normCwd == normFilterItemPath))) ||
        s.workspaceId == wsFilter ||
        s.workspaceName == wsFilter ||
        (normCwd.isNotEmpty && normCwd == normWsFilter) ||
        (normCwd.isNotEmpty && _basenamePath(normCwd) == wsFilter);
  }

  void _ensureFlatItems({
    required List<ChatSessionItem> sessions,
    required List<WorkspaceItem> workspaces,
    required String? sidebarWorkspaceFilter,
    required String searchQuery,
    required Map<String, String> searchSnippets,
    required SessionFilter filter,
    required SessionGroupMode groupMode,
    required String? activeSessionId,
  }) {
    if (identical(_cacheSessions, sessions) &&
        identical(_cacheWorkspaces, workspaces) &&
        _cacheWsFilter == sidebarWorkspaceFilter &&
        _cacheSearchQuery == searchQuery &&
        identical(_cacheSearchSnippets, searchSnippets) &&
        _cacheFilter == filter &&
        _cacheGroupMode == groupMode &&
        _cacheActiveSessionId == activeSessionId &&
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
    _cacheActiveSessionId = activeSessionId;
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
      if (!_sessionMatchesWorkspaceFilter(
        s,
        wsFilter,
        normWsFilter,
        filterWsItem,
        normFilterItemPath,
      )) {
        return false;
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
        final containsActive =
            activeSessionId != null && list.any((s) => s.id == activeSessionId);
        if (containsActive &&
            activeSessionId != _lastAutoExpandedSessionId &&
            _collapsedGroups.remove(k)) {
          _lastAutoExpandedSessionId = activeSessionId;
          final hostKey = _lastHostId;
          if (hostKey != null) {
            _persistedCollapsedByHost[hostKey] = Set<String>.of(_collapsedGroups);
          }
        }
        final collapsed = q.isEmpty && _collapsedGroups.contains(k);
        var pendingCnt = 0;
        var runningCnt = 0;
        var unreadCnt = 0;
        for (final s in list) {
          if (s.pendingApproval) pendingCnt++;
          if (s.running) runningCnt++;
          if (s.unread) unreadCnt++;
        }
        flatItems.add(_SidebarGroupHeader(
          groupKey: k,
          title: meta.$1,
          count: list.length,
          isWorkspace: true,
          isExplicitWorkspace: meta.$2,
          dirPath: meta.$3,
          collapsed: collapsed,
          pendingCount: pendingCnt,
          runningCount: runningCnt,
          unreadCount: unreadCnt,
          hasActiveSession: containsActive,
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
      void emitDateGroup(String title, List<ChatSessionItem> list) {
        final key = 'date:$title';
        final containsActive =
            activeSessionId != null && list.any((s) => s.id == activeSessionId);
        if (containsActive &&
            activeSessionId != _lastAutoExpandedSessionId &&
            _collapsedGroups.remove(key)) {
          _lastAutoExpandedSessionId = activeSessionId;
        }
        final collapsed = q.isEmpty && _collapsedGroups.contains(key);
        var pendingCnt = 0;
        var runningCnt = 0;
        var unreadCnt = 0;
        for (final s in list) {
          if (s.pendingApproval) pendingCnt++;
          if (s.running) runningCnt++;
          if (s.unread) unreadCnt++;
        }
        flatItems.add(_SidebarGroupHeader(
          groupKey: key,
          title: title,
          count: list.length,
          isWorkspace: false,
          isExplicitWorkspace: false,
          collapsed: collapsed,
          pendingCount: pendingCnt,
          runningCount: runningCnt,
          unreadCount: unreadCnt,
          hasActiveSession: containsActive,
        ));
        if (!collapsed) {
          flatItems.addAll(list);
        }
      }
      for (final g in groupOrder) {
        final list = grouped[g];
        if (list != null && list.isNotEmpty) {
          emitDateGroup(g, list);
        }
      }
      for (final entry in grouped.entries) {
        if (!groupOrder.contains(entry.key) && entry.value.isNotEmpty) {
          emitDateGroup(entry.key, entry.value);
        }
      }
    }

    _cachedFlatItems = flatItems;
    _cachedUngroupedWithCwdCount = ungroupedWithCwdCount;
  }

  void _exitMultiSelectRestoringCollapsed() {
    _multiSelectMode = false;
    _selectedIds.clear();
    if (_collapsedBeforeMultiSelect != null) {
      _collapsedGroups
        ..clear()
        ..addAll(_collapsedBeforeMultiSelect!);
      _collapsedBeforeMultiSelect = null;
      _collapsedGroupsVersion++;
    }
  }

  bool _handleDrawerBack() {
    if (!mounted) return false;
    if (_multiSelectMode) {
      setState(_exitMultiSelectRestoringCollapsed);
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
    _listScrollCtrl.dispose();
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
          loadingSession: s.loadingSession,
          activeSessionId: s.activeSessionId,
          activeWorkspace: s.activeWorkspace,
          sidebarWorkspaceFilter: s.sidebarWorkspaceFilter,
          sessionGroupMode: s.sessionGroupMode,
          searchQuery: s.searchQuery,
          searchingSessions: s.searchingSessions,
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
      _collapsedBeforeMultiSelect = null;
      _lastAutoExpandedSessionId = null;
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
      _exitMultiSelectRestoringCollapsed();
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
      activeSessionId: state.activeSessionId,
    );
    final flatItems = _cachedFlatItems;
    final ungroupedWithCwdCount = _cachedUngroupedWithCwdCount;
    final allVisibleSessionIds = <String>{
      for (final item in flatItems)
        if (item is ChatSessionItem) item.id,
    };

    if (_selectedIds.isNotEmpty) {
      _selectedIds.removeWhere((id) => !allVisibleSessionIds.contains(id));
    }

    final host = state.activeHost;
    final wsFilterTrim = state.sidebarWorkspaceFilter?.trim() ?? '';
    final normWsFilterChip = wsFilterTrim.isNotEmpty ? _normalizeDirPath(wsFilterTrim) : '';
    WorkspaceItem? chipWsItem;
    if (wsFilterTrim.isNotEmpty) {
      for (final w in state.workspaces) {
        if (w.id == wsFilterTrim ||
            w.name == wsFilterTrim ||
            w.path == wsFilterTrim ||
            (w.path.isNotEmpty && _normalizeDirPath(w.path) == normWsFilterChip)) {
          chipWsItem = w;
          break;
        }
      }
    }
    final normChipItemPath = (chipWsItem != null && chipWsItem.path.isNotEmpty)
        ? _normalizeDirPath(chipWsItem.path)
        : '';
    final scopedNonArchived = state.sessions.where((s) =>
        !s.archived &&
        _sessionMatchesWorkspaceFilter(
          s,
          wsFilterTrim,
          normWsFilterChip,
          chipWsItem,
          normChipItemPath,
        ));
    final hasPending = scopedNonArchived.any((s) => s.pendingApproval);

    final content = Column(
      children: [
        // Brand Header: Cute GrassBag Mascot directly beside wordmark (non-destructive tap:
        // scrolls session list to top & dismisses search focus without wiping current chat!)
        Padding(
          padding: EdgeInsets.fromLTRB(16, topPad + 8, 12, 8),
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      FocusScope.of(context).unfocus();
                      if (_listScrollCtrl.hasClients && _listScrollCtrl.offset > 2.0) {
                        HapticFeedback.selectionClick();
                        unawaited(
                          _listScrollCtrl.animateTo(
                            0.0,
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOutCubic,
                          ),
                        );
                      }
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
                  child: CustomPaint(
                    foregroundPainter: state.glassTier == GrassBagGlassTier.solid
                        ? null
                        : GrassBagFresnelRimPainter(
                            isDark: t.isDark,
                            isPill: true,
                            tinted: true,
                            accent: t.primaryHi,
                            frosted: state.glassTier == GrassBagGlassTier.frosted,
                            strokeWidth: 0.85,
                          ),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 32),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color.lerp(t.primaryHi, Colors.white, t.isDark ? 0.14 : 0.16)!,
                            t.primary,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: [
                          BoxShadow(
                            color: t.primary.withValues(alpha: t.isDark ? 0.36 : 0.28),
                            blurRadius: 10,
                            offset: const Offset(0, 2.5),
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
                ),
                if (widget.isTabletDocked) ...[
                  const SizedBox(width: 6),
                  Tooltip(
                    message: '收起侧边栏',
                    child: GrassBagSpringTap(
                      onTap: () => ctrl.setTabletSidebarOpen(false),
                      pressedScale: 0.88,
                      haptic: true,
                      child: GrassBagFresnelGlassSurface(
                        isCircle: true,
                        innerWell: true,
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        child: Icon(CupertinoIcons.sidebar_left, size: 15.5, color: t.text2),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // Unified Liquid Glass Pill Search Bar with inline searching indicator
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
          child: Focus(
            onFocusChange: (focused) => _searchFocused.value = focused,
            child: Stack(
              alignment: Alignment.centerRight,
              children: [
                GrassBagGlassSearchBar(
                  controller: _searchCtrl,
                  placeholder: '搜索对话',
                  tier: state.glassTier,
                  insideGlass: true,
                  onChanged: ctrl.setSearchQuery,
                  onSubmitted: (val) {
                    FocusScope.of(context).unfocus();
                    ctrl.setSearchQuery(val);
                  },
                ),
                if (state.searchingSessions && state.searchQuery.trim().isNotEmpty)
                  Positioned(
                    right: 34,
                    child: IgnorePointer(
                      child: GrassBagActivityIndicator(radius: 6, color: t.primary),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // Horizontal Editorial Filter Pills with workspace-scoped live counts & right-edge fade cue
        Builder(
          builder: (_) {
            final runningCnt = scopedNonArchived.where((s) => s.running).length;
            final pendingCnt = scopedNonArchived.where((s) => s.pendingApproval).length;
            final unreadCnt = scopedNonArchived.where((s) => s.unread).length;
            String chipLabel(SessionFilter f) {
              return switch (f) {
                SessionFilter.running when runningCnt > 0 => '${f.label} $runningCnt',
                SessionFilter.pending when pendingCnt > 0 => '${f.label} $pendingCnt',
                SessionFilter.unread when unreadCnt > 0 => '${f.label} $unreadCnt',
                _ => f.label,
              };
            }
            return LayoutBuilder(
              builder: (_, box) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  child: Row(
                    children: [
                      for (final f in SessionFilter.values) ...[
                        _FilterChipPill(
                          label: chipLabel(f),
                          active: state.filter == f,
                          showWarnDot: f == SessionFilter.pending && hasPending && state.filter != f,
                          onTap: () => ctrl.setFilter(f),
                        ),
                        if (f != SessionFilter.values.last) const SizedBox(width: 4.5),
                      ],
                    ],
                  ),
                );
              },
            );
          },
        ),

        // Subtle Workspace Filter + Compact Action Cluster (leaves ≥145dp for workspace label!)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: GrassBagSpringTap(
                    enablePointerGlow: false,
                    haptic: true,
                    onTap: () => showWorkspaceSheet(context, ref, forSidebarFilter: true),
                    child: GrassBagFresnelGlassSurface(
                      isPill: true,
                      innerWell: true,
                      interactive: true,
                      tintColor: state.sidebarWorkspaceFilter != null ? t.primarySoft : null,
                      padding: EdgeInsets.fromLTRB(
                        10,
                        4.5,
                        state.sidebarWorkspaceFilter != null ? 4 : 9,
                        4.5,
                      ),
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
                            const SizedBox(width: 4),
                            Tooltip(
                              message: '清除工作区筛选',
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  ctrl.setSidebarWorkspaceFilter(null);
                                },
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: Center(
                                    child: Container(
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        color: t.primary.withValues(alpha: t.isDark ? 0.24 : 0.16),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(CupertinoIcons.xmark, size: 10, color: t.primary),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ] else ...[
                            const SizedBox(width: 3),
                            Icon(CupertinoIcons.chevron_down, size: 10.5, color: t.text3),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 2),
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
                        width: 34,
                        height: 38,
                        child: Center(
                          child: Icon(
                            state.sessionGroupMode == SessionGroupMode.workspace
                                ? CupertinoIcons.folder
                                : CupertinoIcons.clock,
                            size: 15,
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
                        if (!_multiSelectMode) {
                          _multiSelectMode = true;
                          _selectedIds.clear();
                          // Temporarily expand collapsed groups for multi-select, preserving the
                          // user's saved fold layout to restore cleanly on exit!
                          if (_collapsedGroups.isNotEmpty) {
                            _collapsedBeforeMultiSelect = Set<String>.of(_collapsedGroups);
                            _collapsedGroups.clear();
                            _collapsedGroupsVersion++;
                          }
                        } else {
                          _exitMultiSelectRestoringCollapsed();
                        }
                      }),
                      child: SizedBox(
                        width: 34,
                        height: 38,
                        child: Center(
                          child: Icon(
                            _multiSelectMode
                                ? CupertinoIcons.checkmark_circle_fill
                                : CupertinoIcons.checkmark_circle,
                            size: 15,
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
                        width: 34,
                        height: 38,
                        child: Center(
                          child: state.loadingSessions
                              ? GrassBagActivityIndicator(radius: 6.5, color: t.primary)
                              : Icon(CupertinoIcons.refresh, size: 14.5, color: t.text2),
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
                        width: 34,
                        height: 38,
                        child: Center(
                          child: Icon(
                            CupertinoIcons.chevron_left_slash_chevron_right,
                            size: 14.5,
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
        GrassBagSmoothDisclosure(
          expanded: state.sessionGroupMode == SessionGroupMode.workspace &&
              ungroupedWithCwdCount > 0 &&
              state.connectionPhase == ConnectionPhase.connected,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
            child: GrassBagSpringTap(
              onTap: () => ctrl.organizeWorkspacesByCwd(),
              pressedScale: 0.98,
              haptic: true,
              child: GrassBagFresnelGlassSurface(
                borderRadius: 13,
                innerWell: true,
                tintColor: t.primarySoft,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
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
        ),
        GrassBagSmoothDisclosure(
          expanded: _multiSelectMode,
          child: Builder(
            builder: (_) {
              final allVisibleIds = allVisibleSessionIds;
              final allSelected =
                  allVisibleIds.isNotEmpty && allVisibleIds.every(_selectedIds.contains);
              return Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
                child: GrassBagFresnelGlassSurface(
                  borderRadius: 16,
                  innerWell: true,
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
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
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (allVisibleIds.isNotEmpty)
                          GrassBagSpringTap(
                            enablePointerGlow: false,
                            haptic: true,
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
                            child: GrassBagFresnelGlassSurface(
                              isPill: true,
                              innerWell: true,
                              interactive: false,
                              tintColor: t.primarySoft,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                        if (_selectedIds.isNotEmpty) ...[
                          GrassBagSpringTap(
                            enablePointerGlow: false,
                            haptic: true,
                            onTap: () {
                              final ids = Set<String>.of(_selectedIds);
                              final targetArchived = state.filter != SessionFilter.archived;
                              ctrl.archiveSessionsBatch(ids, archived: targetArchived);
                              setState(() {
                                _selectedIds.clear();
                                _multiSelectMode = false;
                              });
                            },
                            child: GrassBagFresnelGlassSurface(
                              isPill: true,
                              innerWell: true,
                              interactive: false,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              child: Text(
                                state.filter == SessionFilter.archived ? '还原' : '归档',
                                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.text),
                              ),
                            ),
                          ),
                          GrassBagSpringTap(
                            enablePointerGlow: false,
                            haptic: true,
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
                            child: GrassBagFresnelGlassSurface(
                              isPill: true,
                              innerWell: true,
                              interactive: false,
                              tintColor: t.errSoft,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
        ),

        // Compact offline / auth banner when cached sessions are still displayed
        GrassBagSmoothDisclosure(
          expanded: flatItems.isNotEmpty &&
              (state.connectionPhase == ConnectionPhase.needsAuth ||
                  host.needsAuth ||
                  state.connectionPhase == ConnectionPhase.error ||
                  state.connectionPhase == ConnectionPhase.disconnected),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
            child: GrassBagSpringTap(
              pressedScale: 0.985,
              haptic: true,
              onTap: () {
                if (state.connectionPhase == ConnectionPhase.needsAuth || host.needsAuth) {
                  showRemoteHostAuthSheet(context, ref, host);
                } else {
                  ctrl.probeAndRefreshHost(state.activeHostId);
                }
              },
              child: GrassBagFresnelGlassSurface(
                borderRadius: 13,
                innerWell: true,
                tintColor: (state.connectionPhase == ConnectionPhase.needsAuth || host.needsAuth)
                    ? t.primarySoft
                    : t.warnSoft,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Row(
                  children: [
                    Icon(
                      (state.connectionPhase == ConnectionPhase.needsAuth || host.needsAuth)
                          ? CupertinoIcons.lock_shield_fill
                          : CupertinoIcons.wifi_exclamationmark,
                      size: 13.5,
                      color: (state.connectionPhase == ConnectionPhase.needsAuth || host.needsAuth)
                          ? t.primary
                          : t.warn,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        (state.connectionPhase == ConnectionPhase.needsAuth || host.needsAuth)
                            ? '当前展示缓存会话 · 点击完成授权'
                            : '当前处于离线缓存视图 · 点击重试连接',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: (state.connectionPhase == ConnectionPhase.needsAuth || host.needsAuth)
                              ? t.primary
                              : t.warn,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Grouped Sessions List (always keeps CustomScrollView + pull-to-refresh + keyboard dismiss;
        // zero ShaderMask saveLayer and zero opaque top band over translucent Liquid Glass!)
        Expanded(
          child: CustomScrollView(
                controller: _listScrollCtrl,
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
                              state.connectionPhase == ConnectionPhase.reconnecting ||
                              state.connectionPhase == ConnectionPhase.bootstrapping);
                      final isSearching = !isSyncingSessions &&
                          state.searchingSessions &&
                          state.searchQuery.trim().isNotEmpty;
                      final isNeedsAuth = state.sessions.isEmpty &&
                          (state.connectionPhase == ConnectionPhase.needsAuth || host.needsAuth);
                      final isConnectError = !isNeedsAuth &&
                          state.sessions.isEmpty &&
                          (state.connectionPhase == ConnectionPhase.error ||
                              state.connectionPhase == ConnectionPhase.disconnected);
                      final isAllArchived = !isSyncingSessions &&
                          !isSearching &&
                          state.sessions.isNotEmpty &&
                          state.sessions.every((s) => s.archived) &&
                          state.filter == SessionFilter.all &&
                          state.searchQuery.trim().isEmpty &&
                          state.sidebarWorkspaceFilter == null;
                      return ValueListenableBuilder<bool>(
                        valueListenable: _searchFocused,
                        builder: (_, focused, emptyChild) => focused
                            ? _FocusedSearchInsetPadding(child: emptyChild!)
                            : emptyChild!,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                            child: Builder(
                              builder: (_) {
                                Widget buildEmptyPill({
                                  required String label,
                                  required VoidCallback onTap,
                                  bool primary = false,
                                }) {
                                  if (primary) {
                                    return GrassBagPrimaryGlassButton(
                                      label: label,
                                      height: 34,
                                      padding: const EdgeInsets.symmetric(horizontal: 15),
                                      tier: state.glassTier,
                                      insideGlass: true,
                                      onTap: onTap,
                                    );
                                  }
                                  return GrassBagSecondaryGlassButton(
                                    label: label,
                                    height: 34,
                                    padding: const EdgeInsets.symmetric(horizontal: 14),
                                    tier: state.glassTier,
                                    insideGlass: true,
                                    onTap: onTap,
                                  );
                                }
                                return Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      height: 38,
                                      child: Center(
                                        child: (isSyncingSessions || isSearching)
                                            ? GrassBagActivityIndicator(radius: 11, color: t.primary)
                                            : Icon(
                                                isNeedsAuth
                                                    ? CupertinoIcons.lock_shield_fill
                                                    : isConnectError
                                                        ? CupertinoIcons.wifi_exclamationmark
                                                        : (state.sessions.isEmpty
                                                            ? CupertinoIcons.sparkles
                                                            : CupertinoIcons.chat_bubble_2),
                                                size: 30,
                                                color: isNeedsAuth
                                                    ? (t.isDark ? t.primaryHi : t.primary)
                                                    : isConnectError
                                                        ? t.err
                                                        : t.text3.withValues(alpha: 0.78),
                                              ),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      isSyncingSessions
                                          ? '正在同步「${host.name}」的对话…'
                                          : isSearching
                                              ? '正在全文检索对话…'
                                              : isNeedsAuth
                                                  ? '「${host.name}」等待一次授权'
                                                  : isConnectError
                                                      ? '无法连接到「${host.name}」'
                                                      : isAllArchived
                                                          ? '全部对话均已归档'
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
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -0.2,
                                        color: t.text,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      isSyncingSessions
                                          ? '正在拉取最新会话列表与工作区目录'
                                          : isSearching
                                              ? '正在匹配标题与历史消息内容'
                                              : isNeedsAuth
                                                  ? '主机已连通，粘贴启动链接或完成网页登录后 30 天内免填 Token'
                                                  : isConnectError
                                                      ? (host.lastError?.isNotEmpty == true
                                                          ? host.lastError!
                                                          : '请检查主机地址、网络连通性或电脑端是否已开启局域网访问')
                                                      : isAllArchived
                                                          ? '可切换到「已归档」查看历史会话，或直接开始新对话'
                                                          : (state.sessions.isEmpty
                                                              ? '发送首条消息，自动创建并按工作区归类'
                                                              : (state.searchQuery.trim().isNotEmpty ||
                                                                      state.sidebarWorkspaceFilter != null
                                                                  ? '尝试更改搜索关键词或切换到其他筛选分类'
                                                                  : switch (state.filter) {
                                                                      SessionFilter.pending =>
                                                                        '当助手请求执行命令或修改文件时会在此提醒',
                                                                      SessionFilter.running =>
                                                                        '正在后台生成或执行任务的对话会自动出现在此处',
                                                                      SessionFilter.unread => '所有历史对话均已查看完毕',
                                                                      SessionFilter.archived =>
                                                                        '可在对话「···」菜单中归档不再常用的会话',
                                                                      SessionFilter.all =>
                                                                        '尝试更改搜索关键词或切换到其他筛选分类',
                                                                    })),
                                      textAlign: TextAlign.center,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 12, height: 1.45, color: t.text3),
                                    ),
                                    const SizedBox(height: 16),
                                    if (isNeedsAuth)
                                      buildEmptyPill(
                                        label: '立即授权',
                                        primary: true,
                                        onTap: () => showRemoteHostAuthSheet(context, ref, host),
                                      )
                                    else if (isConnectError)
                                      Wrap(
                                        alignment: WrapAlignment.center,
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          buildEmptyPill(
                                            label: '重新连接',
                                            primary: true,
                                            onTap: () => ctrl.probeAndRefreshHost(state.activeHostId),
                                          ),
                                          buildEmptyPill(
                                            label: '主机设置',
                                            onTap: () {
                                              widget.onCloseDrawer?.call();
                                              widget.onOpenHostsSettings();
                                            },
                                          ),
                                        ],
                                      )
                                    else if (isAllArchived)
                                      Wrap(
                                        alignment: WrapAlignment.center,
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          buildEmptyPill(
                                            label: '查看已归档',
                                            primary: true,
                                            onTap: () => ctrl.setFilter(SessionFilter.archived),
                                          ),
                                          buildEmptyPill(
                                            label: '开始新对话',
                                            onTap: () {
                                              ctrl.startNewChat();
                                              widget.onCloseDrawer?.call();
                                            },
                                          ),
                                        ],
                                      )
                                    else if (!isSyncingSessions &&
                                        !isSearching &&
                                        (state.searchQuery.isNotEmpty ||
                                            state.filter != SessionFilter.all ||
                                            state.sidebarWorkspaceFilter != null))
                                      buildEmptyPill(
                                        label: '重置筛选',
                                        primary: true,
                                        onTap: () {
                                          _searchCtrl.clear();
                                          ctrl.setSearchQuery('');
                                          ctrl.setFilter(SessionFilter.all);
                                          ctrl.setSidebarWorkspaceFilter(null);
                                        },
                                      )
                                    else if (!isSyncingSessions && state.sessions.isEmpty)
                                      Wrap(
                                        alignment: WrapAlignment.center,
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          buildEmptyPill(
                                            label: '开始新对话',
                                            primary: true,
                                            onTap: () {
                                              ctrl.startNewChat();
                                              widget.onCloseDrawer?.call();
                                            },
                                          ),
                                          buildEmptyPill(
                                            label: '刷新',
                                            onTap: () => ctrl.refreshSessionsList(),
                                          ),
                                        ],
                                      ),
                                  ],
                                );
                              },
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
                      return GrassBagSpringTap(
                        pressedScale: 0.985,
                        enablePointerGlow: false,
                        haptic: true,
                        onTap: () => setState(() {
                          if (!_collapsedGroups.add(item.groupKey)) {
                            _collapsedGroups.remove(item.groupKey);
                          }
                          final hostKey = _lastHostId ?? state.activeHostId;
                          _persistedCollapsedByHost[hostKey] = Set<String>.of(_collapsedGroups);
                          _collapsedGroupsVersion++;
                        }),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 12, 6, 4),
                          child: Row(
                            children: [
                              AnimatedRotation(
                                turns: item.collapsed ? 0.0 : 0.25,
                                duration: GrassBagMotion.duration(
                                  context,
                                  const Duration(milliseconds: 210),
                                ),
                                curve: Curves.easeOutCubic,
                                child: Icon(
                                  CupertinoIcons.chevron_right,
                                  size: 11,
                                  color: t.text3,
                                ),
                              ),
                              const SizedBox(width: 5),
                              if (item.isWorkspace) ...[
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
                              AnimatedOpacity(
                                opacity: item.collapsed ? 1.0 : 0.0,
                                duration: GrassBagMotion.duration(
                                  context,
                                  const Duration(milliseconds: 160),
                                ),
                                curve: Curves.easeOutCubic,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (item.pendingCount > 0) ...[
                                      GrassBagStatusDot(size: 6.5, color: t.warn, pulsing: true),
                                      const SizedBox(width: 5),
                                    ],
                                    if (item.runningCount > 0) ...[
                                      GrassBagStatusDot(size: 6.5, color: t.ok, pulsing: true),
                                      const SizedBox(width: 5),
                                    ],
                                    if (item.unreadCount > 0 &&
                                        item.pendingCount == 0 &&
                                        item.runningCount == 0) ...[
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          color: t.primary,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 5),
                                    ],
                                  ],
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
                                      width: 38,
                                      height: 36,
                                      child: Center(
                                        child: Icon(
                                          CupertinoIcons.plus,
                                          size: 14,
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
                    final rowWsLabel = state.sessionGroupMode == SessionGroupMode.date
                        ? ((s.workspaceName != null && s.workspaceName!.trim().isNotEmpty)
                            ? s.workspaceName!.trim()
                            : (s.cwd != null && s.cwd!.trim().isNotEmpty
                                ? _basenamePath(s.cwd!)
                                : ''))
                        : '';
                    return _SessionListRow(
                      key: ValueKey('row-${s.id}'),
                      session: s,
                      snippet: snippet,
                      searchQuery: state.searchQuery,
                      workspaceLabel: rowWsLabel,
                      isLoadingActive: widget.isTabletDocked &&
                          s.id == state.activeSessionId &&
                          state.loadingSession,
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
                            GrassBagFresnelGlassSurface(
                              isCircle: true,
                              innerWell: true,
                              tintColor: t.primarySoft,
                              width: 36,
                              height: 36,
                              alignment: Alignment.center,
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
                                      : (t.isDark
                                          ? const Color(0xCC161F2C)
                                          : Colors.white.withValues(alpha: 0.90)),
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
                isTabletDocked: widget.isTabletDocked,
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
                isTabletDocked: widget.isTabletDocked,
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
        interactiveGlow: false,
        useSheetSettings: true,
        clipBehavior: Clip.antiAlias,
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
      padding: const EdgeInsets.symmetric(horizontal: 9.5, vertical: 6.5),
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
    this.searchQuery = '',
    this.workspaceLabel = '',
    this.isLoadingActive = false,
    this.multiSelectMode = false,
    this.selected = false,
  });

  final ChatSessionItem session;
  final String? snippet;
  final String searchQuery;
  final String workspaceLabel;
  final bool isLoadingActive;
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
  final ValueNotifier<bool> _pressed = ValueNotifier<bool>(false);
  Timer? _pressDelay;
  Timer? _quickFlash;
  bool _didShowPress = false;
  bool _hovered = false;

  void _schedulePress() {
    _pressDelay?.cancel();
    _quickFlash?.cancel();
    _didShowPress = false;
    _pressDelay = Timer(const Duration(milliseconds: 50), () {
      if (mounted && !_pressed.value) {
        _didShowPress = true;
        _pressed.value = true;
      }
    });
  }

  void _clearPress() {
    _pressDelay?.cancel();
    _pressDelay = null;
    if (_pressed.value) _pressed.value = false;
  }

  void _flashOnQuickTap() {
    if (_didShowPress) return;
    _pressDelay?.cancel();
    _quickFlash?.cancel();
    _pressed.value = true;
    _quickFlash = Timer(const Duration(milliseconds: 90), () {
      if (mounted) _pressed.value = false;
    });
  }

  @override
  void dispose() {
    _pressDelay?.cancel();
    _quickFlash?.cancel();
    _pressed.dispose();
    super.dispose();
  }

  static String _formatRelativeUpdatedAt(int? rawMs) {
    if (rawMs == null || rawMs <= 0) return '';
    final ms = rawMs < 100000000000 ? rawMs * 1000 : rawMs;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 45) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays == 1) return '昨天';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day}';
  }

  static List<InlineSpan> _highlightQuerySpans(
    String text,
    String rawQuery,
    TextStyle baseStyle,
    Color highlightColor,
  ) {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return [TextSpan(text: text, style: baseStyle)];
    final low = text.toLowerCase();
    final spans = <InlineSpan>[];
    var start = 0;
    while (start < text.length) {
      final hit = low.indexOf(q, start);
      if (hit < 0) {
        spans.add(TextSpan(text: text.substring(start), style: baseStyle));
        break;
      }
      if (hit > start) {
        spans.add(TextSpan(text: text.substring(start, hit), style: baseStyle));
      }
      spans.add(
        TextSpan(
          text: text.substring(hit, hit + q.length),
          style: baseStyle.copyWith(
            color: highlightColor,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      start = hit + q.length;
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final s = widget.session;
    final highlighted = widget.multiSelectMode ? widget.selected : widget.active;
    final cleanSnippet = widget.snippet?.trim() ?? '';
    final showSnippet = cleanSnippet.isNotEmpty && cleanSnippet != s.title.trim();
    final relTime = _formatRelativeUpdatedAt(s.updatedAt);
    final wsLabel = widget.workspaceLabel.trim();
    final showMetaLine = !showSnippet && (relTime.isNotEmpty || wsLabel.isNotEmpty);

    Widget? buildStatusBadge() {
      if (widget.isLoadingActive) {
        return GrassBagActivityIndicator(radius: 5.5, color: t.primary);
      }
      if (s.pendingApproval) {
        return GrassBagFresnelGlassSurface(
          isPill: true,
          innerWell: true,
          tintColor: t.warnSoft,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
          child: Text(
            '待确认',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: t.warn),
          ),
        );
      }
      if (s.running) {
        return GrassBagStatusDot(size: 8, color: t.ok, pulsing: true);
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

    final rowAnimDur = GrassBagMotion.duration(context, const Duration(milliseconds: 180));
    final rowContent = Row(
      children: [
        AnimatedSize(
          duration: rowAnimDur,
          curve: Curves.easeOutCubic,
          alignment: Alignment.centerLeft,
          child: widget.multiSelectMode
              ? Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: AnimatedSwitcher(
                    duration: GrassBagMotion.duration(
                      context,
                      const Duration(milliseconds: 160),
                    ),
                    switchInCurve: Curves.easeOutBack,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.72, end: 1.0).animate(anim),
                        child: child,
                      ),
                    ),
                    child: Icon(
                      widget.selected
                          ? CupertinoIcons.checkmark_circle_fill
                          : CupertinoIcons.circle,
                      key: ValueKey(widget.selected),
                      size: 18,
                      color: widget.selected ? t.primary : t.text3,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        if (s.pinned) ...[
          Icon(CupertinoIcons.pin_fill, size: 11.5, color: t.primary),
          const SizedBox(width: 5),
        ],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: _highlightQuerySpans(
                    s.title,
                    widget.searchQuery,
                    TextStyle(
                      fontSize: 13.5,
                      fontWeight: widget.active ? FontWeight.w600 : FontWeight.w400,
                      color: (widget.active || _hovered) ? t.text : t.text2,
                    ),
                    t.primary,
                  ),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (showSnippet) ...[
                const SizedBox(height: 2),
                Text.rich(
                  TextSpan(
                    children: _highlightQuerySpans(
                      cleanSnippet,
                      widget.searchQuery,
                      TextStyle(fontSize: 11, color: t.text3),
                      t.primary,
                    ),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ] else if (showMetaLine) ...[
                const SizedBox(height: 1.5),
                Row(
                  children: [
                    if (wsLabel.isNotEmpty) ...[
                      Flexible(
                        child: Text(
                          wsLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w500,
                            color: t.text3.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                      if (relTime.isNotEmpty)
                        Text(
                          ' · ',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: t.text3.withValues(alpha: 0.65),
                          ),
                        ),
                    ],
                    if (relTime.isNotEmpty)
                      Text(
                        relTime,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: t.text3.withValues(alpha: 0.78),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (statusBadge != null) ...[
          const SizedBox(width: 6),
          statusBadge,
        ],
        AnimatedSize(
          duration: rowAnimDur,
          curve: Curves.easeOutCubic,
          alignment: Alignment.centerRight,
          child: !widget.multiSelectMode
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 2),
                    AnimatedSize(
                      duration: GrassBagMotion.duration(
                        context,
                        const Duration(milliseconds: 140),
                      ),
                      curve: Curves.easeOutCubic,
                      child: _hovered
                          ? Tooltip(
                              message: s.pinned ? '取消置顶' : '置顶对话',
                              child: GrassBagSpringTap(
                                onTap: widget.onTogglePin,
                                pressedScale: 0.88,
                                borderRadius: 999,
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
                            )
                          : const SizedBox.shrink(),
                    ),
                    Builder(
                      builder: (btnCtx) => Tooltip(
                        message: '更多操作',
                        excludeFromSemantics: true,
                        child: Semantics(
                          button: true,
                          label: '更多操作',
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                HapticFeedback.selectionClick();
                                final box = btnCtx.findRenderObject() as RenderBox?;
                                final anchor = box?.localToGlobal(box.size.center(Offset.zero));
                                widget.onMoreActions(anchor);
                              },
                              child: SizedBox(
                                width: 34,
                                height: 38,
                                child: Center(
                                  child: Icon(
                                    CupertinoIcons.ellipsis,
                                    size: 15,
                                    color: (widget.active || _hovered)
                                        ? t.text2
                                        : t.text3.withValues(alpha: 0.52),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _schedulePress(),
          onTapUp: (_) => _clearPress(),
          onTapCancel: _clearPress,
          onTap: () {
            _flashOnQuickTap();
            widget.onTap();
          },
          onLongPressStart: widget.multiSelectMode
              ? null
              : (d) {
                  _clearPress();
                  HapticFeedback.mediumImpact();
                  widget.onMoreActions(d.globalPosition);
                },
          onSecondaryTapDown: widget.multiSelectMode
              ? null
              : (d) => widget.onMoreActions(d.globalPosition),
          child: ValueListenableBuilder<bool>(
            valueListenable: _pressed,
            child: rowContent,
            builder: (_, pressed, child) => AnimatedScale(
              scale: pressed && !MediaQuery.disableAnimationsOf(context) ? 0.985 : 1.0,
              duration: GrassBagMotion.duration(context, const Duration(milliseconds: 110)),
              curve: Curves.easeOutCubic,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  AnimatedContainer(
                    duration: GrassBagMotion.duration(context, const Duration(milliseconds: 120)),
                    curve: Curves.easeOutCubic,
                    constraints: BoxConstraints(minHeight: showSnippet ? 54 : 44),
                    padding: EdgeInsets.fromLTRB(
                      13,
                      showSnippet ? 7 : 0,
                      11,
                      showSnippet ? 7 : 0,
                    ),
                    decoration: ShapeDecoration(
                      // Always provide a 2-stop LinearGradient so AnimatedContainer -> ShapeDecoration.lerp
                      // never trips `!(color != null && gradient != null)` when switching active sessions.
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: highlighted
                            ? [
                                t.primary.withValues(alpha: t.isDark ? 0.25 : 0.16),
                                t.primary.withValues(alpha: t.isDark ? 0.11 : 0.07),
                              ]
                            : [
                                pressed ? t.fill2 : (_hovered ? t.fill1 : Colors.transparent),
                                pressed ? t.fill2 : (_hovered ? t.fill1 : Colors.transparent),
                              ],
                      ),
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.circular(18),
                        side: BorderSide(
                          color: highlighted
                              ? t.primary.withValues(alpha: t.isDark ? 0.40 : 0.28)
                              : Colors.transparent,
                          width: 0.75,
                        ),
                      ),
                    ),
                    child: child,
                  ),
                  // Overlay animated active indicator pill on left edge -> ZERO horizontal title shift!
                  Positioned(
                    left: 4,
                    child: AnimatedScale(
                      scale: (!widget.multiSelectMode && widget.active) ? 1.0 : 0.0,
                      duration: GrassBagMotion.duration(
                        context,
                        const Duration(milliseconds: 180),
                      ),
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: (!widget.multiSelectMode && widget.active) ? 1.0 : 0.0,
                        duration: GrassBagMotion.duration(
                          context,
                          const Duration(milliseconds: 160),
                        ),
                        child: Container(
                          width: 3,
                          height: 16,
                          decoration: BoxDecoration(
                            color: t.primary,
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
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
    this.isTabletDocked = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool showBadge;
  final bool isTabletDocked;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final ambientTier = resolveAmbientGlassTier(context);
    final isSolid = ambientTier == GrassBagGlassTier.solid;
    final Widget orb = GrassBagSpringTap(
      onTap: onTap,
      pressedScale: 0.90,
      enablePointerGlow: false,
      haptic: true,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: t.isDark
              ? Colors.white.withValues(alpha: isSolid ? 0.10 : 0.10)
              : (isSolid ? const Color(0x11162E42) : Colors.black.withValues(alpha: 0.055)),
          shape: CircleBorder(
            side: isSolid ? BorderSide(color: t.sep, width: 0.65) : BorderSide.none,
          ),
        ),
        child: Icon(icon, size: 18, color: t.text2),
      ),
    );
    return Tooltip(
      message: tooltip,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          orb,
          if (showBadge)
            Positioned(
              top: -1,
              right: -1,
              child: IgnorePointer(
                child: Container(
                  width: 9.5,
                  height: 9.5,
                  decoration: BoxDecoration(
                    color: t.warn,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isTabletDocked
                          ? t.sidebarDocked
                          : (t.isDark
                              ? const Color(0xCC161F2C)
                              : Colors.white.withValues(alpha: 0.90)),
                      width: 1.5,
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
    this.pendingCount = 0,
    this.runningCount = 0,
    this.unreadCount = 0,
    this.hasActiveSession = false,
  });

  final String groupKey;
  final String title;
  final int count;
  final bool isWorkspace;
  final bool isExplicitWorkspace;
  final String? dirPath;
  final bool collapsed;
  final int pendingCount;
  final int runningCount;
  final int unreadCount;
  final bool hasActiveSession;
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
