import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';

/// Floating bottom thumb-zone Apple iOS 26 Liquid Glass Composer:
/// - Rock-solid spring-animated Floating Liquid Glass '+' Deck directly above composer (NO WebUI, zero mobile clipping!)
/// - True liquid-morphing [GlassMenu] for Steer / Queue / Interrupt while streaming
/// - Concentric geometry (`28pt` outer superellipse, `10pt` inset, `36pt`/`18pt`-radius inner controls)
/// - Animated ghost Context Ring (`TweenAnimationBuilder` sweep)
/// - [GlassMaterializeTransition] on floating scroll-to-bottom droplet
/// - Keyboard <-> '+' deck mutual exclusion & zero keystroke rebuild storm
/// - NO Terminal button in composer bar!
class ChatComposerDock extends ConsumerStatefulWidget {
  const ChatComposerDock({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onOpenTerminal,
    this.onOpenModelSettings,
    this.onOpenHostSettings,
    this.onMessageSent,
    this.plusOpenNotifier,
    this.onPlusOpenChanged,
    this.showScrollToBottom = false,
    this.showScrollToBottomListenable,
    this.onScrollToBottom,
    this.composerHeightNotifier,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onOpenTerminal;
  final VoidCallback? onOpenModelSettings;
  final VoidCallback? onOpenHostSettings;
  final VoidCallback? onMessageSent;
  final ValueNotifier<bool>? plusOpenNotifier;
  final ValueChanged<bool>? onPlusOpenChanged;
  final bool showScrollToBottom;
  final ValueListenable<bool>? showScrollToBottomListenable;
  final VoidCallback? onScrollToBottom;
  final ValueNotifier<double>? composerHeightNotifier;

  @override
  ConsumerState<ChatComposerDock> createState() => _ChatComposerDockState();
}

class _ChatComposerDockState extends ConsumerState<ChatComposerDock>
    with SingleTickerProviderStateMixin {
  static final RegExp _slashTriggerRe = RegExp(r'^/(\S*)$');
  static final RegExp _atTriggerRe = RegExp(r'(?:^|\s)(@([^\s]*))$');

  late final SingleSpringController _plusSpring;
  bool _plusOpen = false;
  bool _hasText = false;
  String? _mentionTrigger; // '/' or '@'
  String _mentionQuery = '';
  int _mentionStartOffset = -1;
  int _activeSuggestionIdx = 0;
  bool _submitting = false;
  Timer? _refDebounceTimer;
  Timer? _draftSyncTimer;
  int _refReqSeq = 0;
  bool _loadingRefs = false;
  List<Map<String, String>> _remoteRefs = const [];
  final List<Map<String, dynamic>> _pickedReferences = [];
  List<SlashCommandItem> _latestCommands = const [];
  List<Map<String, String>> _latestRefs = const [];
  List<WorkspaceFileNode>? _cachedWorkspaceFilesRef;
  List<String> _cachedFlatFilePaths = const [];

  bool get _isDesktopPlatform =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  void _insertNewlineAtCursor() {
    final val = widget.controller.value;
    final sel = val.selection;
    final start = sel.isValid ? sel.start : val.text.length;
    final end = sel.isValid ? sel.end : val.text.length;
    final nextText = val.text.replaceRange(start, end, '\n');
    widget.controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  KeyEventResult _handleComposerKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_mentionTrigger != null) {
      final count = _mentionTrigger == '/' ? _latestCommands.length : _latestRefs.length;
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() {
          _mentionTrigger = null;
          _mentionQuery = '';
          _activeSuggestionIdx = 0;
        });
        return KeyEventResult.handled;
      }
      if (count > 0 && event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() => _activeSuggestionIdx = (_activeSuggestionIdx + 1) % count);
        return KeyEventResult.handled;
      }
      if (count > 0 && event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() => _activeSuggestionIdx = (_activeSuggestionIdx - 1 + count) % count);
        return KeyEventResult.handled;
      }
      if (count > 0 &&
          event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.tab ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
        final composing = widget.controller.value.composing;
        if (composing.isValid && !composing.isCollapsed) {
          return KeyEventResult.ignored;
        }
        final idx = _activeSuggestionIdx.clamp(0, count - 1);
        final isTab = event.logicalKey == LogicalKeyboardKey.tab;
        if (_mentionTrigger == '/') {
          final cmd = _latestCommands[idx];
          _applySuggestion(
            cmd.command,
            executeImmediately: !isTab &&
                const {'/compact', '/new', '/plan', '/fork', '/export', '/status'}
                    .contains(cmd.command),
          );
        } else {
          final refItem = _latestRefs[idx];
          _applySuggestion(refItem['path'] ?? '', refItem: refItem);
        }
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final composing = widget.controller.value.composing;
      final isImeComposing = composing.isValid && !composing.isCollapsed;
      if (isImeComposing) return KeyEventResult.ignored;

      final keys = HardwareKeyboard.instance.logicalKeysPressed;
      final shiftPressed = HardwareKeyboard.instance.isShiftPressed ||
          keys.contains(LogicalKeyboardKey.shiftLeft) ||
          keys.contains(LogicalKeyboardKey.shiftRight) ||
          keys.contains(LogicalKeyboardKey.shift);
      final altPressed = HardwareKeyboard.instance.isAltPressed ||
          keys.contains(LogicalKeyboardKey.altLeft) ||
          keys.contains(LogicalKeyboardKey.altRight);
      final cmdOrCtrlPressed = HardwareKeyboard.instance.isMetaPressed ||
          HardwareKeyboard.instance.isControlPressed ||
          keys.contains(LogicalKeyboardKey.metaLeft) ||
          keys.contains(LogicalKeyboardKey.metaRight) ||
          keys.contains(LogicalKeyboardKey.controlLeft) ||
          keys.contains(LogicalKeyboardKey.controlRight);

      if (_isDesktopPlatform) {
        if (shiftPressed || altPressed) {
          _insertNewlineAtCursor();
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent) {
          unawaited(_submit());
          return KeyEventResult.handled;
        }
        return KeyEventResult.handled;
      }
      // On mobile / iPad / Android tablet with external hardware keyboard:
      // Cmd/Ctrl+Enter sends immediately while Shift+Enter inserts a newline.
      if (cmdOrCtrlPressed) {
        if (event is KeyDownEvent) {
          unawaited(_submit());
        }
        return KeyEventResult.handled;
      }
      if (shiftPressed) {
        _insertNewlineAtCursor();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    _plusOpen = widget.plusOpenNotifier?.value ?? false;
    _plusSpring = SingleSpringController(
      vsync: this,
      spring: GlassSpring.snappy(duration: const Duration(milliseconds: 280)),
      initialValue: _plusOpen ? 1.0 : 0.0,
    );
    _hasText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onTextChanged);
    widget.focusNode.addListener(_onFocusChanged);
    widget.focusNode.onKeyEvent = _handleComposerKeyEvent;
    widget.plusOpenNotifier?.addListener(_onExternalPlusChanged);
  }

  @override
  void didUpdateWidget(covariant ChatComposerDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
      _hasText = widget.controller.text.trim().isNotEmpty;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      if (oldWidget.focusNode.onKeyEvent == _handleComposerKeyEvent) {
        oldWidget.focusNode.onKeyEvent = null;
      }
      widget.focusNode.addListener(_onFocusChanged);
      widget.focusNode.onKeyEvent = _handleComposerKeyEvent;
    }
    if (oldWidget.plusOpenNotifier != widget.plusOpenNotifier) {
      oldWidget.plusOpenNotifier?.removeListener(_onExternalPlusChanged);
      widget.plusOpenNotifier?.addListener(_onExternalPlusChanged);
    }
  }

  @override
  void dispose() {
    _refDebounceTimer?.cancel();
    _draftSyncTimer?.cancel();
    widget.controller.removeListener(_onTextChanged);
    widget.focusNode.removeListener(_onFocusChanged);
    if (widget.focusNode.onKeyEvent == _handleComposerKeyEvent) {
      widget.focusNode.onKeyEvent = null;
    }
    widget.plusOpenNotifier?.removeListener(_onExternalPlusChanged);
    _plusSpring.dispose();
    super.dispose();
  }

  void _onExternalPlusChanged() {
    final next = widget.plusOpenNotifier?.value ?? false;
    if (next != _plusOpen) {
      _setPlusOpen(next, fromExternal: true);
    }
  }

  void _setPlusOpen(bool open, {bool fromExternal = false}) {
    if (open && widget.focusNode.hasFocus) {
      widget.focusNode.unfocus();
    }
    if (_plusOpen == open) return;
    setState(() => _plusOpen = open);
    _plusSpring.spring = open
        ? GlassSpring.snappy(duration: const Duration(milliseconds: 280))
        : GlassSpring.smooth(duration: const Duration(milliseconds: 200));
    _plusSpring.animateTo(open ? 1.0 : 0.0);
    if (!fromExternal && widget.plusOpenNotifier != null) {
      widget.plusOpenNotifier!.value = open;
    }
    widget.onPlusOpenChanged?.call(open);
  }

  void _togglePlus() {
    HapticFeedback.selectionClick();
    _setPlusOpen(!_plusOpen);
  }

  bool _suppressDraftSync = false;

  void _setControllerDraftSafely(String draft) {
    _draftSyncTimer?.cancel();
    if (widget.controller.text == draft) return;
    _suppressDraftSync = true;
    try {
      widget.controller.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
    } finally {
      _suppressDraftSync = false;
    }
    final nextHasText = draft.trim().isNotEmpty;
    if (nextHasText != _hasText) {
      setState(() => _hasText = nextHasText);
    }
  }

  void _flushDraftSync() {
    _draftSyncTimer?.cancel();
    if (!mounted) return;
    final raw = widget.controller.text;
    final ctrl = ref.read(appProvider.notifier);
    if (ctrl.getComposerDraftForActiveHost() != raw) {
      ctrl.setComposerDraftForActiveHost(raw);
    }
  }

  /// Only rebuilds when empty <-> non-empty OR `/` / `@` trigger state changes,
  /// keeping normal typing at zero unnecessary glass rebuilds or map clones!
  void _onTextChanged() {
    if (_suppressDraftSync) return;
    final val = widget.controller.value;
    final raw = val.text;
    // Debounce draft persistence sync (400ms) so fast typing never clones host draft maps
    // or churns persistence timers on every single keystroke.
    _draftSyncTimer?.cancel();
    final snap = ref.read(appProvider);
    final draftHostId = snap.activeHostId;
    final draftSessionId = snap.activeSessionId;
    _draftSyncTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final cur = ref.read(appProvider);
      if (cur.activeHostId != draftHostId || cur.activeSessionId != draftSessionId) {
        return;
      }
      final ctrl = ref.read(appProvider.notifier);
      final latest = widget.controller.text;
      if (ctrl.getComposerDraftForActiveHost() != latest) {
        ctrl.setComposerDraftForActiveHost(latest);
      }
    });
    final nextHasText = raw.trim().isNotEmpty;
    final cursor = val.selection.isValid
        ? val.selection.baseOffset.clamp(0, raw.length)
        : raw.length;
    final beforeCursor = cursor == raw.length ? raw : raw.substring(0, cursor);
    String? nextTrigger;
    var nextQuery = '';
    var nextStart = -1;
    // Fast-path: skip RegExp matching entirely on normal prose keystrokes!
    RegExpMatch? slashMatch;
    var slashLeadingOffset = 0;
    if (beforeCursor.isNotEmpty) {
      var firstNonWs = 0;
      while (firstNonWs < beforeCursor.length && beforeCursor.codeUnitAt(firstNonWs) <= 32) {
        firstNonWs++;
      }
      if (firstNonWs < beforeCursor.length && beforeCursor.codeUnitAt(firstNonWs) == 47 /* '/' */) {
        slashLeadingOffset = firstNonWs;
        final trimmedBefore = firstNonWs == 0 ? beforeCursor : beforeCursor.substring(firstNonWs);
        slashMatch = _slashTriggerRe.firstMatch(trimmedBefore);
      }
    }
    final atMatch = slashMatch == null && beforeCursor.contains('@')
        ? _atTriggerRe.firstMatch(beforeCursor)
        : null;
    if (slashMatch != null) {
      nextTrigger = '/';
      nextQuery = (slashMatch.group(1) ?? '').toLowerCase();
      nextStart = slashLeadingOffset;
    } else if (atMatch != null) {
      nextTrigger = '@';
      nextQuery = (atMatch.group(2) ?? '').toLowerCase();
      nextStart = atMatch.end - (atMatch.group(1)?.length ?? 0);
    }

    if (nextTrigger != '@') {
      _refDebounceTimer?.cancel();
      _loadingRefs = false;
      if (_remoteRefs.isNotEmpty) {
        _remoteRefs = const [];
      }
    } else if (nextQuery != _mentionQuery || _mentionTrigger != '@') {
      _refDebounceTimer?.cancel();
      final q = nextQuery;
      final seq = ++_refReqSeq;
      final reqHostId = ref.read(appProvider).activeHostId;
      _loadingRefs = true;
      _refDebounceTimer = Timer(const Duration(milliseconds: 180), () async {
        final refs = await ref.read(appProvider.notifier).fetchSessionReferences(q);
        if (!mounted ||
            seq != _refReqSeq ||
            _mentionTrigger != '@' ||
            ref.read(appProvider).activeHostId != reqHostId) {
          return;
        }
        setState(() {
          _loadingRefs = false;
          _remoteRefs = refs;
        });
      });
    }

    if (nextHasText != _hasText ||
        nextTrigger != _mentionTrigger ||
        nextQuery != _mentionQuery ||
        nextStart != _mentionStartOffset) {
      setState(() {
        _hasText = nextHasText;
        if (nextTrigger != _mentionTrigger || nextQuery != _mentionQuery) {
          _activeSuggestionIdx = 0;
        }
        _mentionTrigger = nextTrigger;
        _mentionQuery = nextQuery;
        _mentionStartOffset = nextStart;
      });
    }
  }

  void _applySuggestion(
    String replacement, {
    bool executeImmediately = false,
    Map<String, String>? refItem,
  }) {
    HapticFeedback.selectionClick();
    if (_mentionTrigger == '/') {
      final val = widget.controller.value;
      final raw = val.text;
      final cursor = val.selection.isValid
          ? val.selection.baseOffset.clamp(0, raw.length)
          : raw.length;
      final start = (_mentionStartOffset >= 0 && _mentionStartOffset <= cursor)
          ? _mentionStartOffset
          : 0;
      final afterCursor = raw.substring(cursor);
      final insert = afterCursor.startsWith(' ') ? replacement : '$replacement ';
      final updated = raw.replaceRange(start, cursor, insert);
      widget.controller.value = TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: start + insert.length),
      );
      if (executeImmediately && afterCursor.trim().isEmpty) {
        unawaited(_submit());
      }
    } else if (_mentionTrigger == '@') {
      final val = widget.controller.value;
      final raw = val.text;
      final cursor = val.selection.isValid
          ? val.selection.baseOffset.clamp(0, raw.length)
          : raw.length;
      final start = (_mentionStartOffset >= 0 && _mentionStartOffset <= cursor)
          ? _mentionStartOffset
          : raw.lastIndexOf('@', cursor > 0 ? cursor - 1 : 0);
      if (start >= 0 && start <= cursor) {
        final insert = '@$replacement ';
        final updated = raw.replaceRange(start, cursor, insert);
        widget.controller.value = TextEditingValue(
          text: updated,
          selection: TextSelection.collapsed(offset: start + insert.length),
        );
      }
      if (refItem != null && (refItem['path'] ?? '').isNotEmpty) {
        final path = refItem['path']!;
        if (!_pickedReferences.any((r) => r['path'] == path)) {
          _pickedReferences.add({
            'kind': refItem['kind'] ?? 'file',
            'path': path,
            if (refItem['label']?.isNotEmpty == true) 'label': refItem['label'],
          });
        }
      }
    }
    _refDebounceTimer?.cancel();
    setState(() {
      _mentionTrigger = null;
      _mentionQuery = '';
      _mentionStartOffset = -1;
      _activeSuggestionIdx = 0;
      _remoteRefs = const [];
    });
  }

  List<String> _getFlattenedFilePaths(List<WorkspaceFileNode> nodes) {
    if (identical(_cachedWorkspaceFilesRef, nodes)) {
      return _cachedFlatFilePaths;
    }
    final out = <String>[];
    void walk(List<WorkspaceFileNode> list) {
      for (final n in list) {
        if (!n.isDir) out.add(n.path);
        if (n.children.isNotEmpty) walk(n.children);
      }
    }
    walk(nodes);
    _cachedWorkspaceFilesRef = nodes;
    _cachedFlatFilePaths = out;
    return out;
  }

  void _onFocusChanged() {
    if (widget.focusNode.hasFocus) {
      if (_plusOpen) _setPlusOpen(false);
    } else {
      _flushDraftSync();
    }
  }

  void _resetTransientComposerUi() {
    _refDebounceTimer?.cancel();
    _refReqSeq++;
    _pickedReferences.clear();
    _cachedWorkspaceFilesRef = null;
    _cachedFlatFilePaths = const [];
    if (mounted) {
      setState(() {
        _submitting = false;
        _hasText = widget.controller.text.trim().isNotEmpty;
        _mentionTrigger = null;
        _mentionQuery = '';
        _mentionStartOffset = -1;
        _activeSuggestionIdx = 0;
        _remoteRefs = const [];
      });
    }
  }

  Future<void> _submit({String mode = 'auto'}) async {
    if (_submitting) return;
    final rawText = widget.controller.text;
    final text = rawText.trim();
    final appSnapshot = ref.read(appProvider);
    final hasAtt = appSnapshot.pendingAttachments.isNotEmpty;
    if (text.isEmpty && !hasAtt) return;
    final ctrl = ref.read(appProvider.notifier);

    // Pre-flight guard: preserve user's draft and guide directly to 1-tap resolution
    // when remote host awaits auth or connected DSH has 0 configured model providers!
    if (!appSnapshot.activeHost.isLocal &&
        (appSnapshot.activeHost.needsAuth ||
            appSnapshot.connectionPhase == ConnectionPhase.needsAuth)) {
      ctrl.showToast('请先完成远程主机授权，已保留当前输入内容', tone: ToastTone.info);
      showRemoteHostAuthSheet(context, ref, appSnapshot.activeHost);
      return;
    }
    if (!text.startsWith('/') &&
        appSnapshot.isDshConnected &&
        appSnapshot.connectionPhase == ConnectionPhase.connected &&
        appSnapshot.routableProviders.isEmpty) {
      ctrl.showToast('请先登录 DeepSeek 或配置 API Key，已保留当前输入内容', tone: ToastTone.info);
      if (widget.onOpenModelSettings != null) {
        widget.onOpenModelSettings!();
      } else {
        showModelSheet(context, ref, onOpenModelSettings: widget.onOpenModelSettings);
      }
      return;
    }

    final startHostId = appSnapshot.activeHostId;
    // Preserve soft-keyboard focus across keyboard Send and Send-orb tap so users
    // never get their IME collapsed on every message!
    final hadFocus = widget.focusNode.hasFocus;
    HapticFeedback.lightImpact();
    if (_plusOpen) {
      _setPlusOpen(false);
    }
    final activeRefs = _pickedReferences
        .where((r) => text.contains('@${r['path']}'))
        .toList(growable: false);
    // Clear input optimistically BEFORE awaiting async send so typing stays instant
    // and Android IME composing state resets cleanly without dismissing the keyboard.
    widget.controller.clear();
    _flushDraftSync();
    if (hadFocus && !widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
    }
    setState(() {
      _submitting = true;
      _hasText = false;
      _mentionTrigger = null;
      _mentionQuery = '';
      _activeSuggestionIdx = 0;
    });
    final sent = await ref.read(appProvider.notifier).sendPrompt(
          text.isEmpty ? '请帮我分析这些附件' : text,
          mode: mode,
          references: activeRefs.isEmpty ? null : activeRefs,
        );
    if (!mounted) return;
    final sameHost = ref.read(appProvider).activeHostId == startHostId;
    setState(() => _submitting = false);
    if (!sameHost) {
      // User switched hosts while sending; never overwrite the new host's composer or refs!
      return;
    }
    if (sent) {
      _pickedReferences.clear();
      widget.onMessageSent?.call();
    } else if (widget.controller.text.isEmpty && rawText.isNotEmpty) {
      widget.controller.text = rawText;
      widget.controller.selection = TextSelection.collapsed(offset: rawText.length);
    }
    if (hadFocus && mounted && !widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(appProvider.select((s) => s.activeHostId), (prev, next) {
      if (prev != null && prev != next) {
        _setControllerDraftSafely(ref.read(appProvider.notifier).getComposerDraftForActiveHost());
        _resetTransientComposerUi();
      }
    });
    ref.listen<String?>(appProvider.select((s) => s.activeSessionId), (prev, next) {
      if (prev != next) {
        final isNewChatPromotion = (prev == null &&
                next != null &&
                next.startsWith('pending-session-')) ||
            (prev != null &&
                prev.startsWith('pending-session-') &&
                next != null &&
                !next.startsWith('pending-session-'));
        if (!isNewChatPromotion) {
          _setControllerDraftSafely(ref.read(appProvider.notifier).getComposerDraftForActiveHost());
          _resetTransientComposerUi();
        }
      }
    });
    ref.listen<int>(appProvider.select((s) => s.newChatSignal), (prev, next) {
      if (prev != null && prev != next) {
        _setControllerDraftSafely(ref.read(appProvider.notifier).getComposerDraftForActiveHost());
        _resetTransientComposerUi();
      }
    });
    ref.listen<int>(appProvider.select((s) => s.draftHydratedSignal), (prev, next) {
      if (prev != null && prev != next && widget.controller.text.isEmpty) {
        final draft = ref.read(appProvider.notifier).getComposerDraftForActiveHost();
        if (draft.isNotEmpty) {
          _setControllerDraftSafely(draft);
        }
      }
    });
    final state = ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          activePermission: s.activePermission,
          planMode: s.planMode,
          speechConfigured: s.speechConfigured,
          pendingApprovalCommand: s.pendingApprovalCommand,
          activeQuestion: s.activeQuestion,
          activeCordisRequest: s.activeCordisRequest,
          pendingAttachments: s.pendingAttachments,
          queuedMessages: s.queuedMessages,
          slashCommands: s.slashCommands,
          workspaceFiles: s.workspaceFiles,
          activeWorkspace: s.activeWorkspace,
          isEmptyChat: s.isEmptyChat,
          isStreaming: s.isStreaming,
          activeModelId: s.activeModelId,
          modelShort: s.modelShort,
          modelEffort: s.modelEffort,
          connectionPhase: s.connectionPhase,
          isDshConnected: s.isDshConnected,
          hostIsLocal: s.activeHost.isLocal,
          hostNeedsAuth: s.activeHost.needsAuth,
          routableProvidersCount: s.routableProviders.length,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final perm = state.activePermission;
    final hasText = _hasText || state.pendingAttachments.isNotEmpty;
    final showApproval = state.pendingApprovalCommand != null;
    final showQuestion = !showApproval && state.activeQuestion != null;
    final showCordis = !showApproval && !showQuestion && state.activeCordisRequest != null;
    final hasTakeover = showApproval || showQuestion || showCordis;
    final showRiskPill = perm.risky && !hasTakeover && !state.isEmptyChat && !_plusOpen;
    final showPlanPill = state.planMode && !hasTakeover && !_plusOpen;
    final screenW = MediaQuery.sizeOf(context).width;
    final isWide = screenW >= 540;

    final filteredCommands = _mentionTrigger == '/'
        ? state.slashCommands
            .where((c) =>
                c.command.toLowerCase().contains(_mentionQuery) ||
                c.title.toLowerCase().contains(_mentionQuery))
            .take(5)
            .toList(growable: false)
        : const <SlashCommandItem>[];
    final filteredRefs = _mentionTrigger == '@'
        ? () {
            final seen = <String>{};
            final list = <Map<String, String>>[];
            for (final r in _remoteRefs) {
              final p = r['path'] ?? '';
              if (p.isNotEmpty && seen.add(p)) {
                list.add(r);
                if (list.length >= 6) break;
              }
            }
            if (list.length < 6) {
              for (final p in _getFlattenedFilePaths(state.workspaceFiles)) {
                if (p.toLowerCase().contains(_mentionQuery) && seen.add(p)) {
                  list.add({'path': p, 'kind': 'file'});
                  if (list.length >= 6) break;
                }
              }
            }
            return list;
          }()
        : const <Map<String, String>>[];
    _latestCommands = filteredCommands;
    _latestRefs = filteredRefs;
    final showSuggestions = !hasTakeover &&
        !_plusOpen &&
        (_mentionTrigger == '/' || _mentionTrigger == '@');
    final isHostNeedsAuth = !state.hostIsLocal &&
        (state.hostNeedsAuth || state.connectionPhase == ConnectionPhase.needsAuth);
    final isHostConnecting = state.connectionPhase == ConnectionPhase.connecting;
    final isHostConnected = state.isDshConnected &&
        state.connectionPhase == ConnectionPhase.connected;
    final needsModelConfig = isHostConnected && state.routableProvidersCount == 0;

    final isDesktopPlatform = _isDesktopPlatform;

    Widget buildScrollDroplet(bool showDroplet) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        reverseDuration: const Duration(milliseconds: 140),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, anim) {
          if (state.glassTier == GrassBagGlassTier.solid || kIsWeb) {
            return FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.80, end: 1.0).animate(anim),
                alignment: Alignment.bottomRight,
                child: child,
              ),
            );
          }
          return GlassMaterializeTransition(
            animation: anim,
            alignment: Alignment.bottomRight,
            scaleFrom: 1.10,
            contentSigma: 0.0,
            child: child,
          );
        },
        child: showDroplet && !state.isEmptyChat && !_plusOpen && !hasTakeover
            ? Padding(
                key: const ValueKey('scroll-down-pill'),
                padding: const EdgeInsets.only(bottom: 10),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: GrassBagGlassCircleButton(
                    icon: CupertinoIcons.chevron_down,
                    size: 40,
                    iconSize: 19,
                    tooltip: '回到底部',
                    tier: state.glassTier,
                    onTap: () => widget.onScrollToBottom?.call(),
                  ),
                ),
              )
            : const SizedBox.shrink(key: ValueKey('scroll-down-empty')),
      );
    }

    return Center(
      heightFactor: 1.0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Floating Liquid Glass "Scroll to latest" droplet (pure GPU Scale+Fade, zero blur stall!)
            if (widget.showScrollToBottomListenable != null)
              ValueListenableBuilder<bool>(
                valueListenable: widget.showScrollToBottomListenable!,
                builder: (_, visible, __) => buildScrollDroplet(visible),
              )
            else
              buildScrollDroplet(widget.showScrollToBottom),

            // Active Status Pills above Composer — batched in ONE GrassBagGlassBarLayer (zero extra GPU passes!)
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              clipBehavior: Clip.none,
              child: (showRiskPill || showPlanPill)
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: GrassBagGlassBarLayer(
                          tier: state.glassTier,
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              if (showPlanPill)
                                GrassBagGlassPillButton(
                                  tier: state.glassTier,
                                  height: 34,
                                  useOwnLayer: false,
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  onTap: () => ctrl.setPlanMode(false),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(CupertinoIcons.list_bullet_indent,
                                          size: 13.5, color: t.dusk),
                                      const SizedBox(width: 6),
                                      Text(
                                        '计划模式',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: t.dusk,
                                        ),
                                      ),
                                      const SizedBox(width: 5),
                                      Icon(CupertinoIcons.xmark, size: 11, color: t.dusk),
                                    ],
                                  ),
                                ),
                              if (showRiskPill)
                                GrassBagGlassPillButton(
                                  tier: state.glassTier,
                                  height: 34,
                                  useOwnLayer: false,
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  onTap: () => showPermissionSheet(context, ref),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(CupertinoIcons.exclamationmark_shield_fill,
                                          size: 14, color: t.warn),
                                      const SizedBox(width: 6),
                                      Text(
                                        perm.name,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: t.warn,
                                        ),
                                      ),
                                      const SizedBox(width: 2),
                                      Icon(CupertinoIcons.chevron_right, size: 12, color: t.warn),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),

            // Floating Liquid Glass `/` Slash Command & `@` File Reference suggestion strip
            // Smoothly animates height + opacity/slide in and out without hard pop-in/out.
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                reverseDuration: const Duration(milliseconds: 130),
                switchInCurve: Curves.linear,
                switchOutCurve: Curves.linear,
                transitionBuilder: (child, anim) {
                  final curved = CurvedAnimation(
                    parent: anim,
                    curve: const Cubic(0.22, 1.0, 0.36, 1.0),
                    reverseCurve: Curves.easeInCubic,
                  );
                  return FadeTransition(
                    opacity: curved,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.08),
                        end: Offset.zero,
                      ).animate(curved),
                      child: ScaleTransition(
                        alignment: Alignment.bottomCenter,
                        scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
                        child: child,
                      ),
                    ),
                  );
                },
                child: showSuggestions
                    ? Padding(
                        key: ValueKey('suggestions-$_mentionTrigger'),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: GlassBackdropGroup(
                          enabled: false,
                          child: GrassBagGlass(
                            tier: state.glassTier,
                            borderRadius: 22,
                            elevated: true,
                            useSheetSettings: true,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_mentionTrigger == '/' && filteredCommands.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                  child: Text(
                                    '未匹配到内置快捷指令，直接发送将交给 DSH 执行',
                                    style: TextStyle(fontSize: 12, color: t.text3),
                                  ),
                                )
                              else if (_mentionTrigger == '/')
                                for (var ci = 0; ci < filteredCommands.length; ci++)
                                  () {
                                    final cmd = filteredCommands[ci];
                                    final active = ci ==
                                        _activeSuggestionIdx.clamp(0, filteredCommands.length - 1);
                                    final isInstant = const {
                                      '/compact',
                                      '/new',
                                      '/plan',
                                      '/fork',
                                      '/export',
                                      '/status',
                                    }.contains(cmd.command);
                                    return GrassBagSpringTap(
                                      onTap: () => _applySuggestion(
                                        cmd.command,
                                        executeImmediately: isInstant,
                                      ),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: active ? t.fill1 : Colors.transparent,
                                          borderRadius: BorderRadius.circular(11),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 7,
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 7,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: t.primarySoft,
                                                borderRadius: BorderRadius.circular(7),
                                              ),
                                              child: Text(
                                                cmd.command,
                                                style: TextStyle(
                                                  fontFamily: 'monospace',
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                  color: t.primary,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 9),
                                            Expanded(
                                              child: Text(
                                                '${cmd.title} · ${cmd.desc}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(fontSize: 12.5, color: t.text2),
                                              ),
                                            ),
                                            if (isInstant) ...[
                                              const SizedBox(width: 6),
                                              Container(
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 6,
                                                  vertical: 2,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: t.fill2,
                                                  borderRadius: BorderRadius.circular(999),
                                                ),
                                                child: Text(
                                                  '直达',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w600,
                                                    color: t.text3,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    );
                                  }()
                              else if (filteredRefs.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                  child: Row(
                                    children: [
                                      if (_loadingRefs) ...[
                                        CupertinoActivityIndicator(radius: 6.5, color: t.primary),
                                        const SizedBox(width: 8),
                                        Text(
                                          '正在搜索工作区文件与引用…',
                                          style: TextStyle(fontSize: 12, color: t.text3),
                                        ),
                                      ] else
                                        Expanded(
                                          child: Text(
                                            state.activeWorkspace.isEmpty
                                                ? '暂未选择工作区，先在顶部选择文件夹后可用 @ 引用文件'
                                                : '未找到匹配文件，可继续输入路径关键词',
                                            style: TextStyle(fontSize: 12, color: t.text3),
                                          ),
                                        ),
                                    ],
                                  ),
                                )
                              else
                                for (var ri = 0; ri < filteredRefs.length; ri++)
                                  () {
                                    final refItem = filteredRefs[ri];
                                    final active = ri ==
                                        _activeSuggestionIdx.clamp(0, filteredRefs.length - 1);
                                    return GrassBagSpringTap(
                                      onTap: () => _applySuggestion(
                                        refItem['path'] ?? '',
                                        refItem: refItem,
                                      ),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: active ? t.fill1 : Colors.transparent,
                                          borderRadius: BorderRadius.circular(11),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 7,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              refItem['kind'] == 'session'
                                                  ? CupertinoIcons.chat_bubble_text_fill
                                                  : CupertinoIcons.doc_text_fill,
                                              size: 14,
                                              color: refItem['kind'] == 'session'
                                                  ? t.dusk
                                                  : t.primary,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                refItem['label']?.isNotEmpty == true
                                                    ? '${refItem['label']} (${refItem['path']})'
                                                    : (refItem['path'] ?? ''),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontFamily: refItem['kind'] == 'session'
                                                      ? null
                                                      : 'monospace',
                                                  fontSize: 12.5,
                                                  color: t.text,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }(),
                            ],
                          ),
                        ),
                      ),
                    )
                    : const SizedBox.shrink(key: ValueKey('suggestions-empty')),
              ),
            ),

            // Spring-Animated Floating Liquid Glass '+' Deck directly above composer
            // Hoisted static child inside ListenableBuilder -> ZERO rebuilds of _PlusDeckContent at 120Hz!
            if (!hasTakeover)
              ListenableBuilder(
                listenable: _plusSpring,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isWide ? 344.0 : double.infinity,
                  ),
                  child: RepaintBoundary(
                    child: GlassBackdropGroup(
                      enabled: false,
                      child: GrassBagGlass(
                        tier: state.glassTier,
                        borderRadius: 26,
                        elevated: true,
                        useSheetSettings: true,
                        child: _PlusDeckContent(
                          onClose: () => _setPlusOpen(false),
                          onOpenTerminal: widget.onOpenTerminal,
                        ),
                      ),
                    ),
                  ),
                ),
                builder: (ctx, staticDeck) {
                  final raw = _plusSpring.value;
                  if (raw <= 0.005 && !_plusOpen) return const SizedBox.shrink();
                  final v = raw.clamp(0.0, 1.0);
                  final scale = 0.94 + 0.06 * raw;
                  final deckCard = Transform.translate(
                    offset: Offset(0, (1.0 - v) * 12.0),
                    child: Transform.scale(
                      scale: scale.clamp(0.90, 1.02),
                      alignment: Alignment.bottomLeft,
                      child: staticDeck,
                    ),
                  );
                  final aligned = Align(
                    alignment: Alignment.bottomLeft,
                    heightFactor: v,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: deckCard,
                    ),
                  );
                  // Keep ClipRect mounted at fixed tree depth across the spring so _PlusDeckContent
                  // never remounts mid-flight, disabling clip at rest so elevated drop shadows show cleanly.
                  return ClipRect(
                    clipBehavior: v < 0.999 ? Clip.hardEdge : Clip.none,
                    child: aligned,
                  );
                },
              ),

            // Smooth Transition between Elevated Liquid Glass Approval Card & Floating Composer.
            // Deliberately avoid wrapping `composer-pill` in `AnimatedSize` so multi-line text
            // wrapping performs ONE layout pass instead of 24 consecutive `toImageSync` frames!
            _ComposerHeightReporter(
              onHeightChanged: (h) {
                final n = widget.composerHeightNotifier;
                if (n != null && (n.value - h).abs() > 1.0) {
                  n.value = h;
                }
              },
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                ),
                transitionBuilder: (child, anim) {
                  return FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.06),
                        end: Offset.zero,
                      ).animate(anim),
                      child: ScaleTransition(
                        alignment: Alignment.bottomCenter,
                        scale: Tween<double>(begin: 0.97, end: 1.0).animate(anim),
                        child: child,
                      ),
                    ),
                  );
                },
                child: showApproval
                  ? GlassBackdropGroup(
                      key: const ValueKey('approval-card'),
                      enabled: false,
                      child: GrassBagGlass(
                      tier: state.glassTier,
                      borderRadius: 28,
                      elevated: true,
                      useSheetSettings: true,
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              GrassBagSquircleIcon(
                                icon: CupertinoIcons.shield_lefthalf_fill,
                                color: t.warn,
                                size: 36,
                                iconSize: 18,
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '请求执行命令',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -0.2,
                                        color: t.text,
                                      ),
                                    ),
                                    Text(
                                      '工作区：${state.activeWorkspace}',
                                      style: TextStyle(fontSize: 12, color: t.text3),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Container(
                            constraints: const BoxConstraints(maxHeight: 160),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: t.codeBg,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.09),
                                width: 0.6,
                              ),
                            ),
                            child: SingleChildScrollView(
                              child: SelectableText(
                                state.pendingApprovalCommand!,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  height: 1.45,
                                  color: t.codeFg,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: GrassBagSecondaryGlassButton(
                                  label: '拒绝',
                                  height: 40,
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  tier: state.glassTier,
                                  insideGlass: true,
                                  destructive: true,
                                  onTap: () => ctrl.resolveApproval('deny'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: GrassBagSecondaryGlassButton(
                                  label: '本会话均允许',
                                  height: 40,
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  tier: state.glassTier,
                                  insideGlass: true,
                                  onTap: () => ctrl.resolveApproval('always'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: GrassBagPrimaryGlassButton(
                                  label: '允许一次',
                                  height: 40,
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  tier: state.glassTier,
                                  insideGlass: true,
                                  onTap: () => ctrl.resolveApproval('allow'),
                                ),
                              ),
                            ],
                          ),
                          ],
                        ),
                      ),
                    )
                  : showQuestion
                      ? _UserQuestionTakeoverCard(
                          key: ValueKey('question-${state.activeQuestion!.interactionId}'),
                          question: state.activeQuestion!,
                          tier: state.glassTier,
                          onSubmit: ctrl.resolveUserQuestion,
                          onCancel: () => ctrl.cancelStreaming(),
                        )
                      : showCordis
                          ? _CordisRunTakeoverCard(
                              key: ValueKey('cordis-${state.activeCordisRequest!.interactionId}'),
                              request: state.activeCordisRequest!,
                              tier: state.glassTier,
                              onDecision: ctrl.resolveCordisRun,
                            )
                          : GrassBagGlass(
                              key: const ValueKey('composer-pill'),
                              tier: state.glassTier,
                              borderRadius: 28,
                              elevated: true,
                              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AnimatedSize(
                                    duration: const Duration(milliseconds: 160),
                                    curve: Curves.easeOutCubic,
                                    alignment: Alignment.bottomCenter,
                                    child: state.pendingAttachments.isEmpty
                                        ? const SizedBox.shrink()
                                        : SizedBox(
                                            height: state.pendingAttachments.any(
                                              (a) => a.isImage && a.bytes != null && a.bytes!.isNotEmpty,
                                            )
                                                ? 58
                                                : 38,
                                            child: ListView.separated(
                                              scrollDirection: Axis.horizontal,
                                              padding: const EdgeInsets.fromLTRB(6, 6, 10, 4),
                                              itemCount: state.pendingAttachments.length,
                                              separatorBuilder: (_, __) => const SizedBox(width: 8),
                                              itemBuilder: (_, idx) {
                                                final att = state.pendingAttachments[idx];
                                                final hasImgBytes =
                                                    att.isImage && att.bytes != null && att.bytes!.isNotEmpty;
                                                if (hasImgBytes) {
                                                  return Stack(
                                                    clipBehavior: Clip.none,
                                                    children: [
                                                      GestureDetector(
                                                        onTap: () => showImagePreviewDialog(
                                                          context,
                                                          bytes: att.bytes,
                                                          title: att.name,
                                                        ),
                                                        child: Container(
                                                          width: 44,
                                                          height: 44,
                                                          decoration: BoxDecoration(
                                                            borderRadius: BorderRadius.circular(11),
                                                            border: Border.all(
                                                              color: t.primary.withValues(alpha: 0.35),
                                                              width: 0.8,
                                                            ),
                                                          ),
                                                          clipBehavior: Clip.antiAlias,
                                                          child: Image.memory(
                                                            att.bytes!,
                                                            cacheWidth: 132,
                                                            fit: BoxFit.cover,
                                                            gaplessPlayback: true,
                                                            errorBuilder: (_, __, ___) => Center(
                                                              child: Icon(
                                                                CupertinoIcons.photo_fill,
                                                                size: 16,
                                                                color: t.primary,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                      Positioned(
                                                        top: -7,
                                                        right: -7,
                                                        child: GestureDetector(
                                                          behavior: HitTestBehavior.opaque,
                                                          onTap: () => ctrl.removePendingAttachment(att.id),
                                                          child: SizedBox(
                                                            width: 24,
                                                            height: 24,
                                                            child: Center(
                                                              child: Container(
                                                                width: 18,
                                                                height: 18,
                                                                decoration: BoxDecoration(
                                                                  color: t.isDark
                                                                      ? const Color(0xFF1F232B)
                                                                      : Colors.white,
                                                                  shape: BoxShape.circle,
                                                                  border: Border.all(
                                                                    color: t.sepStrong,
                                                                    width: 0.6,
                                                                  ),
                                                                ),
                                                                child: Icon(
                                                                  CupertinoIcons.xmark,
                                                                  size: 10,
                                                                  color: t.text,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  );
                                                }
                                                return Container(
                                                  padding: const EdgeInsets.only(left: 9, right: 2),
                                                  decoration: BoxDecoration(
                                                    color: t.primarySoft,
                                                    borderRadius: BorderRadius.circular(999),
                                                    border: Border.all(
                                                      color: t.primary.withValues(alpha: 0.25),
                                                      width: 0.6,
                                                    ),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        att.isImage
                                                            ? CupertinoIcons.photo_fill
                                                            : CupertinoIcons.doc_fill,
                                                        size: 13,
                                                        color: t.primary,
                                                      ),
                                                      const SizedBox(width: 5),
                                                      ConstrainedBox(
                                                        constraints: const BoxConstraints(maxWidth: 120),
                                                        child: Text(
                                                          att.name,
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                          style: TextStyle(
                                                            fontSize: 11.5,
                                                            fontWeight: FontWeight.w600,
                                                            color: t.primary,
                                                          ),
                                                        ),
                                                      ),
                                                      GestureDetector(
                                                        behavior: HitTestBehavior.opaque,
                                                        onTap: () => ctrl.removePendingAttachment(att.id),
                                                        child: SizedBox(
                                                          width: 26,
                                                          height: 26,
                                                          child: Center(
                                                            child: Icon(
                                                              CupertinoIcons.xmark_circle_fill,
                                                              size: 15,
                                                              color: t.primary.withValues(alpha: 0.75),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                  ),
                                  AnimatedSize(
                                    duration: const Duration(milliseconds: 160),
                                    curve: Curves.easeOutCubic,
                                    alignment: Alignment.bottomCenter,
                                    child: state.queuedMessages.isEmpty
                                        ? const SizedBox.shrink()
                                        : Padding(
                                            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                              decoration: BoxDecoration(
                                                color: t.fill1,
                                                borderRadius: BorderRadius.circular(14),
                                                border: Border.all(color: t.sep, width: 0.5),
                                              ),
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                                children: [
                                                  Text(
                                                    '待发送队列 (${state.queuedMessages.length})',
                                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: t.text3),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  for (final q in state.queuedMessages)
                                                    Padding(
                                                      padding: const EdgeInsets.only(top: 3),
                                                      child: Row(
                                                        children: [
                                                          Container(
                                                            padding: const EdgeInsets.symmetric(
                                                              horizontal: 6,
                                                              vertical: 2,
                                                            ),
                                                            decoration: BoxDecoration(
                                                              color: q.mode == 'steer'
                                                                  ? t.primarySoft
                                                                  : t.fill2,
                                                              borderRadius: BorderRadius.circular(6),
                                                            ),
                                                            child: Text(
                                                              q.mode == 'steer' ? '插话' : '排队',
                                                              style: TextStyle(
                                                                fontSize: 10,
                                                                fontWeight: FontWeight.w600,
                                                                color: q.mode == 'steer'
                                                                    ? t.primary
                                                                    : t.text2,
                                                              ),
                                                            ),
                                                          ),
                                                          const SizedBox(width: 6),
                                                          Expanded(
                                                            child: Text(
                                                              q.text,
                                                              maxLines: 1,
                                                              overflow: TextOverflow.ellipsis,
                                                              style: TextStyle(fontSize: 12.5, color: t.text),
                                                            ),
                                                          ),
                                                          GestureDetector(
                                                            behavior: HitTestBehavior.opaque,
                                                            onTap: () => ctrl.promoteQueuedMessage(q.id),
                                                            child: Padding(
                                                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                                                              child: Text(
                                                                '立即发',
                                                                style: TextStyle(
                                                                  fontSize: 11.5,
                                                                  fontWeight: FontWeight.w600,
                                                                  color: t.primary,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                          GestureDetector(
                                                            behavior: HitTestBehavior.opaque,
                                                            onTap: () => ctrl.removeQueuedMessage(q.id),
                                                            child: SizedBox(
                                                              width: 26,
                                                              height: 26,
                                                              child: Center(
                                                                child: Icon(CupertinoIcons.xmark, size: 13, color: t.text3),
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
                                  RepaintBoundary(
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                                      child: TextField(
                              controller: widget.controller,
                              focusNode: widget.focusNode,
                              minLines: 1,
                              maxLines: 5,
                              keyboardType: TextInputType.multiline,
                              // Mobile uses TextInputAction.newline (matching ChatGPT/Claude) so users
                              // can freely compose multi-line prompts without dismissing the soft IME;
                              // desktop/hardware keyboards send on Enter / Cmd+Enter.
                              textInputAction: TextInputAction.newline,
                              // Empty onEditingComplete prevents Flutter's default unfocus() on IME actions,
                              // keeping the Android/iOS soft keyboard smoothly open across messages!
                              onEditingComplete: () {},
                              onSubmitted: null,
                              style: TextStyle(
                                fontSize: 15,
                                height: 1.4,
                                letterSpacing: -0.15,
                                color: t.text,
                              ),
                              decoration: InputDecoration(
                                hintText: isHostNeedsAuth
                                    ? '远程主机待授权，点击完成授权后即可对话…'
                                    : (needsModelConfig
                                        ? '先登录 DeepSeek 或添加 API Key 后即可开始对话…'
                                        : (state.planMode
                                            ? '计划模式：先出执行方案，确认后再动手…'
                                            : (isDesktopPlatform
                                                ? '给 GrassBag 发消息…（Enter 发送 · Shift+Enter 换行）'
                                                : '给 GrassBag 发消息…'))),
                                hintStyle: TextStyle(
                                  fontSize: 15,
                                  letterSpacing: -0.15,
                                  color: t.isDark
                                      ? t.text2.withValues(alpha: 0.68)
                                      : t.text3,
                                ),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(vertical: 3),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          ),
                          LayoutBuilder(
                            builder: (ctx, rowBox) {
                              final tightRow = rowBox.maxWidth < 316;
                              final showInlineRing = !(tightRow && state.isStreaming && hasText);
                              return Row(
                            children: [
                              // Crisp spring-animated '+' toggle button (rotates 45° into '×')
                              GrassBagSpringTap(
                                key: const ValueKey('composer-plus-btn'),
                                onTap: _togglePlus,
                                pressedScale: 0.88,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOutCubic,
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: _plusOpen
                                        ? (t.isDark
                                            ? t.primary.withValues(alpha: 0.28)
                                            : Color.lerp(Colors.white, t.primary, 0.18)!
                                                .withValues(alpha: 0.80))
                                        : Colors.white.withValues(alpha: t.isDark ? 0.11 : 0.62),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: _plusOpen
                                          ? t.primary.withValues(alpha: t.isDark ? 0.42 : 0.30)
                                          : Colors.white.withValues(alpha: t.isDark ? 0.18 : 0.90),
                                      width: 0.65,
                                    ),
                                    boxShadow: t.isDark
                                        ? null
                                        : const [
                                            BoxShadow(
                                              color: Color(0x0D000000),
                                              blurRadius: 6,
                                              offset: Offset(0, 2),
                                            ),
                                          ],
                                  ),
                                  child: AnimatedRotation(
                                    turns: _plusOpen ? 0.125 : 0.0,
                                    duration: const Duration(milliseconds: 260),
                                    curve: Curves.easeOutCubic,
                                    child: Icon(
                                      CupertinoIcons.plus,
                                      size: 19,
                                      color: _plusOpen ? t.primary : t.text2,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 7),

                              // Concentric Model & Effort Pill (`height: 36`, `radius: 18 = 28 - 10`)
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: () {
                                      final IconData pillIcon;
                                      final Color pillIconColor;
                                      final String pillLabel;
                                      final String? effortBadge;
                                      final Color pillTextColor;
                                      final VoidCallback pillTap;
                                      if (isHostNeedsAuth) {
                                        pillIcon = CupertinoIcons.lock_shield_fill;
                                        pillIconColor = t.primary;
                                        pillLabel = '待授权';
                                        effortBadge = null;
                                        pillTextColor = t.primary;
                                        pillTap = () => showRemoteHostAuthSheet(
                                              context,
                                              ref,
                                              ref.read(appProvider).activeHost,
                                            );
                                      } else if (isHostConnecting) {
                                        pillIcon = CupertinoIcons.sparkles;
                                        pillIconColor = t.text3;
                                        pillLabel = '连接中…';
                                        effortBadge = null;
                                        pillTextColor = t.text3;
                                        pillTap = () => showHostQuickSheet(
                                              context,
                                              ref,
                                              onOpenHostSettings: widget.onOpenHostSettings,
                                            );
                                      } else if (!isHostConnected) {
                                        pillIcon = CupertinoIcons.wifi_exclamationmark;
                                        pillIconColor = t.warn;
                                        pillLabel = '未连接';
                                        effortBadge = null;
                                        pillTextColor = t.warn;
                                        pillTap = () => showHostQuickSheet(
                                              context,
                                              ref,
                                              onOpenHostSettings: widget.onOpenHostSettings,
                                            );
                                      } else if (needsModelConfig || state.activeModelId.isEmpty) {
                                        pillIcon = CupertinoIcons.sparkles;
                                        pillIconColor = t.warn;
                                        pillLabel = '配置模型';
                                        effortBadge = null;
                                        pillTextColor = t.warn;
                                        pillTap = () {
                                          if (widget.onOpenModelSettings != null) {
                                            widget.onOpenModelSettings!();
                                          } else {
                                            showModelSheet(
                                              context,
                                              ref,
                                              onOpenModelSettings: widget.onOpenModelSettings,
                                            );
                                          }
                                        };
                                      } else {
                                        pillIcon = CupertinoIcons.sparkles;
                                        pillIconColor = t.primary;
                                        pillLabel = state.modelShort;
                                        effortBadge = state.modelEffort.isNotEmpty
                                            ? state.modelEffort
                                            : null;
                                        pillTextColor = t.text;
                                        pillTap = () => showModelSheet(
                                              context,
                                              ref,
                                              onOpenModelSettings: widget.onOpenModelSettings,
                                            );
                                      }
                                      return GrassBagSpringTap(
                                        onTap: pillTap,
                                        pressedScale: 0.94,
                                        haptic: true,
                                        child: Container(
                                          height: 36,
                                          padding: EdgeInsets.symmetric(horizontal: tightRow ? 9 : 11),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(alpha: t.isDark ? 0.10 : 0.60),
                                            borderRadius: BorderRadius.circular(999),
                                            border: Border.all(
                                              color: Colors.white.withValues(
                                                alpha: t.isDark ? 0.18 : 0.90,
                                              ),
                                              width: 0.65,
                                            ),
                                            boxShadow: t.isDark
                                                ? null
                                                : const [
                                                    BoxShadow(
                                                      color: Color(0x0C000000),
                                                      blurRadius: 6,
                                                      offset: Offset(0, 2),
                                                    ),
                                                  ],
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(pillIcon, size: 13.5, color: pillIconColor),
                                              const SizedBox(width: 5),
                                              Flexible(
                                                child: Text(
                                                  pillLabel,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 12.5,
                                                    fontWeight: FontWeight.w500,
                                                    letterSpacing: -0.1,
                                                    color: pillTextColor,
                                                  ),
                                                ),
                                              ),
                                              if (effortBadge != null) ...[
                                                const SizedBox(width: 5),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(
                                                    horizontal: 5.5,
                                                    vertical: 1.5,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: t.primary.withValues(
                                                      alpha: t.isDark ? 0.22 : 0.12,
                                                    ),
                                                    borderRadius: BorderRadius.circular(999),
                                                  ),
                                                  child: Text(
                                                    effortBadge,
                                                    style: TextStyle(
                                                      fontSize: 10.5,
                                                      fontWeight: FontWeight.w600,
                                                      color: t.primary,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                              const SizedBox(width: 3),
                                              Icon(CupertinoIcons.chevron_down, size: 11, color: t.text3),
                                            ],
                                          ),
                                        ),
                                      );
                                  }(),
                                ),
                              ),
                              const SizedBox(width: 6),

                              // Liquid-morphing Apple GlassMenu for Steer / Queue / Interrupt while streaming!
                              if (state.isStreaming && hasText) ...[
                                GlassMenu(
                                  menuWidth: 214,
                                  menuBorderRadius: 24,
                                  menuAlignment: GlassMenuAlignment.bottomRight,
                                  settings: GrassBagGlassConfig.sheetSettings(t, state.glassTier),
                                  quality: GrassBagGlassConfig.chromeQualityFor(state.glassTier),
                                  triggerBuilder: (ctx, toggleMenu) => GrassBagSpringTap(
                                    onTap: toggleMenu,
                                    pressedScale: 0.94,
                                    haptic: true,
                                    child: Container(
                                      height: 36,
                                      padding: EdgeInsets.symmetric(horizontal: tightRow ? 9 : 11),
                                      decoration: BoxDecoration(
                                        color: t.primarySoft,
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '补充',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: t.primary,
                                            ),
                                          ),
                                          const SizedBox(width: 3),
                                          Icon(CupertinoIcons.chevron_down,
                                              size: 10.5, color: t.primary),
                                        ],
                                      ),
                                    ),
                                  ),
                                  items: [
                                    GlassMenuItem(
                                      title: '插话 · 引导当前任务',
                                      icon: const Icon(CupertinoIcons.arrow_turn_down_right),
                                      onTap: () => _submit(mode: 'steer'),
                                    ),
                                    GlassMenuItem(
                                      title: '排队 · 本轮结束后发',
                                      icon: const Icon(CupertinoIcons.clock),
                                      onTap: () => _submit(mode: 'queue'),
                                    ),
                                    const GlassMenuDivider(),
                                    GlassMenuItem(
                                      title: '打断 · 立刻停止改问',
                                      icon: const Icon(CupertinoIcons.stop_circle),
                                      isDestructive: true,
                                      onTap: () => _submit(mode: 'interrupt'),
                                    ),
                                  ],
                                ),
                                const SizedBox(width: 4),
                              ],

                              // Isolated RepaintBoundary Context Ring (updates NEVER rebuild composer pill or TextField!)
                              if (showInlineRing) const _ComposerContextRingButton(),

                              // Compact Stop orb remains accessible when streaming AND drafting follow-up text!
                              if (state.isStreaming && hasText) ...[
                                Tooltip(
                                  message: '停止当前生成',
                                  child: GrassBagSpringTap(
                                    onTap: () {
                                      HapticFeedback.lightImpact();
                                      ctrl.cancelStreaming();
                                    },
                                    pressedScale: 0.88,
                                    child: Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        color: t.errSoft,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: t.err.withValues(alpha: 0.32),
                                          width: 0.6,
                                        ),
                                      ),
                                      child: Icon(
                                        CupertinoIcons.stop_fill,
                                        size: 13.5,
                                        color: t.err,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],

                              // Concentric Action Orb (Send / Stop / Mic when speech is configured)
                              GrassBagSpringTap(
                                key: const ValueKey('composer-action-btn'),
                                enabled: !_submitting,
                                pressedScale: (hasText || state.isStreaming || state.speechConfigured) ? 0.86 : 1.0,
                                onTap: () {
                                  if (_submitting) return;
                                  if (state.isStreaming && !hasText) {
                                    HapticFeedback.lightImpact();
                                    ctrl.cancelStreaming();
                                  } else if (hasText) {
                                    _submit();
                                  } else if (state.speechConfigured) {
                                    HapticFeedback.selectionClick();
                                    showVoiceInputSheet(
                                      context,
                                      ref,
                                      onTranscriptConfirmed: (text) {
                                        final cur = widget.controller.text;
                                        widget.controller.text = cur.isEmpty ? text : '$cur $text';
                                        widget.controller.selection = TextSelection.collapsed(
                                          offset: widget.controller.text.length,
                                        );
                                        setState(() {});
                                      },
                                    );
                                  }
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOutCubic,
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    gradient: (hasText || _submitting)
                                        ? LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [t.primaryHi, t.primary],
                                          )
                                        : null,
                                    color: (hasText || _submitting)
                                        ? null
                                        : state.isStreaming
                                            ? t.errSoft
                                            : Colors.white.withValues(
                                                alpha: t.isDark ? 0.11 : 0.62,
                                              ),
                                    shape: BoxShape.circle,
                                    border: (hasText || _submitting)
                                        ? Border.all(
                                            color: Colors.white.withValues(alpha: 0.28),
                                            width: 0.6,
                                          )
                                        : Border.all(
                                            color: state.isStreaming
                                                ? t.err.withValues(alpha: 0.30)
                                                : Colors.white.withValues(
                                                    alpha: t.isDark ? 0.18 : 0.90,
                                                  ),
                                            width: 0.65,
                                          ),
                                    boxShadow: (hasText || _submitting)
                                        ? [
                                            BoxShadow(
                                              color: t.primary.withValues(alpha: 0.36),
                                              blurRadius: 10,
                                              offset: const Offset(0, 3),
                                            ),
                                          ]
                                        : (t.isDark
                                            ? null
                                            : const [
                                                BoxShadow(
                                                  color: Color(0x0D000000),
                                                  blurRadius: 6,
                                                  offset: Offset(0, 2),
                                                ),
                                              ]),
                                  ),
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 200),
                                    switchInCurve: Curves.easeOutCubic,
                                    switchOutCurve: Curves.easeInCubic,
                                    transitionBuilder: (child, anim) => FadeTransition(
                                      opacity: anim,
                                      child: ScaleTransition(
                                        scale: Tween<double>(begin: 0.72, end: 1.0).animate(anim),
                                        child: child,
                                      ),
                                    ),
                                    child: _submitting
                                        ? CupertinoActivityIndicator(
                                            key: const ValueKey('sending'),
                                            radius: 7.5,
                                            color: t.onPrimary,
                                          )
                                        : Icon(
                                            hasText
                                                ? CupertinoIcons.arrow_up
                                                : state.isStreaming
                                                    ? CupertinoIcons.stop_fill
                                                    : (state.speechConfigured
                                                        ? CupertinoIcons.mic_fill
                                                        : CupertinoIcons.arrow_up),
                                            key: ValueKey(
                                              hasText
                                                  ? 'send'
                                                  : (state.isStreaming
                                                      ? 'stop'
                                                      : (state.speechConfigured ? 'mic' : 'send')),
                                            ),
                                            size: hasText ? 17 : (state.isStreaming ? 14 : 16.5),
                                            color: hasText
                                                ? t.onPrimary
                                                : state.isStreaming
                                                    ? t.err
                                                    : (state.speechConfigured ? t.text : t.text3),
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          );
                            },
                          ),
                        ],
                      ),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Zero-overhead RenderProxyBox height reporter so the chat ListView tail spacer and bottom
/// scrim always track the real live composer height (1 line -> 5 lines + attachments + queue).
class _ComposerHeightReporter extends SingleChildRenderObjectWidget {
  const _ComposerHeightReporter({
    required this.onHeightChanged,
    required super.child,
  });

  final ValueChanged<double> onHeightChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderComposerHeightReporter(onHeightChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderComposerHeightReporter renderObject,
  ) {
    renderObject.onHeightChanged = onHeightChanged;
  }
}

class _RenderComposerHeightReporter extends RenderProxyBox {
  _RenderComposerHeightReporter(this.onHeightChanged);

  ValueChanged<double> onHeightChanged;
  double? _lastReported;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h > 0 && (_lastReported == null || (h - _lastReported!).abs() > 1.0)) {
      _lastReported = h;
      WidgetsBinding.instance.addPostFrameCallback((_) => onHeightChanged(h));
    }
  }
}

class _ContextRingPainter extends CustomPainter {
  const _ContextRingPainter({
    required this.percent,
    required this.trackColor,
    required this.arcColor,
  });

  final double percent;
  final Color trackColor;
  final Color arcColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1.6;
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.1;
    canvas.drawCircle(center, radius, trackPaint);

    final arcPaint = Paint()
      ..color = arcColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.1
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * percent.clamp(0.03, 1.0),
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ContextRingPainter old) =>
      old.percent != percent || old.arcColor != arcColor || old.trackColor != trackColor;
}

class _PlusQuickAction extends StatelessWidget {
  const _PlusQuickAction({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagSpringTap(
      onTap: onTap,
      pressedScale: 0.91,
      haptic: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GrassBagSquircleIcon(
              icon: icon,
              color: color,
              size: 50,
              iconSize: 22,
              filled: true,
            ),
            const SizedBox(height: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: t.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PopoverActionRow extends StatelessWidget {
  const _PopoverActionRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.trailingText,
    required this.onTap,
    this.warnTrailing = false,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String trailingText;
  final VoidCallback onTap;
  final bool warnTrailing;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagSpringTap(
      onTap: onTap,
      pressedScale: 0.98,
      haptic: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        child: Row(
          children: [
            GrassBagSquircleIcon(
              icon: icon,
              color: iconColor,
              size: 30,
              iconSize: 15,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: t.text,
                ),
              ),
            ),
            Flexible(
              child: Text(
                trailingText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: warnTrailing ? FontWeight.w600 : FontWeight.w400,
                  color: warnTrailing ? t.warn : t.text3,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              CupertinoIcons.chevron_right,
              size: 13,
              color: warnTrailing ? t.warn : t.text3,
            ),
          ],
        ),
      ),
    );
  }
}

/// Clean Apple iOS 26 floating '+' action deck positioned directly above the composer
/// (4 luminous translucent quick actions + Preset + Permission + Plan Mode switch — NO WebUI!).
class _PlusDeckContent extends ConsumerWidget {
  const _PlusDeckContent({
    required this.onClose,
    required this.onOpenTerminal,
  });

  final VoidCallback onClose;
  final VoidCallback onOpenTerminal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          activePreset: s.activePreset,
          activePermission: s.activePermission,
          planMode: s.planMode,
          glassTier: s.glassTier,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final perm = slice.activePermission;
    final isMobileCameraCapable = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _PlusQuickAction(
                  icon: CupertinoIcons.photo_fill,
                  color: t.isDark ? const Color(0xFF4DA3E8) : const Color(0xFF2B7FC3),
                  label: isMobileCameraCapable ? '相册' : '图片',
                  onTap: () {
                    onClose();
                    ctrl.pickComposerAttachment(source: 'gallery');
                  },
                ),
              ),
              if (isMobileCameraCapable) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: _PlusQuickAction(
                    icon: CupertinoIcons.camera_fill,
                    color: t.isDark ? const Color(0xFF818CF8) : const Color(0xFF535EC0),
                    label: '拍照',
                    onTap: () {
                      onClose();
                      ctrl.pickComposerAttachment(source: 'camera');
                    },
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: _PlusQuickAction(
                  icon: CupertinoIcons.doc_fill,
                  color: t.isDark ? const Color(0xFF34D399) : const Color(0xFF2D8A7B),
                  label: '文件',
                  onTap: () {
                    onClose();
                    ctrl.pickComposerAttachment(source: 'file');
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _PlusQuickAction(
                  icon: CupertinoIcons.chevron_left_slash_chevron_right,
                  color: t.isDark ? const Color(0xFF64748B) : const Color(0xFF3E5368),
                  label: '终端',
                  onTap: () {
                    onClose();
                    onOpenTerminal();
                  },
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Divider(height: 0.5, indent: 4, endIndent: 4, color: t.sep),
          ),
          _PopoverActionRow(
            icon: CupertinoIcons.compass_fill,
            iconColor: t.primary,
            title: '角色预设',
            trailingText: slice.activePreset.name,
            onTap: () {
              onClose();
              showPresetSheet(context, ref);
            },
          ),
          Divider(height: 0.5, indent: 42, color: t.sep),
          _PopoverActionRow(
            icon: perm.risky
                ? CupertinoIcons.exclamationmark_shield_fill
                : CupertinoIcons.checkmark_shield_fill,
            iconColor: perm.risky ? t.warn : t.ok,
            title: '操作权限',
            trailingText: perm.name,
            warnTrailing: perm.risky,
            onTap: () {
              onClose();
              showPermissionSheet(context, ref);
            },
          ),
          Divider(height: 0.5, indent: 42, color: t.sep),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
            child: Row(
              children: [
                GrassBagSquircleIcon(
                  icon: CupertinoIcons.list_bullet_indent,
                  color: t.dusk,
                  size: 30,
                  iconSize: 15,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '计划模式',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: t.text,
                        ),
                      ),
                      Text(
                        '先规划步骤再动手执行',
                        style: TextStyle(fontSize: 11.5, color: t.text3),
                      ),
                    ],
                  ),
                ),
                GrassBagGlassSwitch(
                  value: slice.planMode,
                  tier: slice.glassTier,
                  activeColor: t.ok,
                  onChanged: ctrl.setPlanMode,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UserQuestionTakeoverCard extends StatefulWidget {
  const _UserQuestionTakeoverCard({
    super.key,
    required this.question,
    required this.tier,
    required this.onSubmit,
    required this.onCancel,
  });

  final ActiveUserQuestion question;
  final GrassBagGlassTier tier;
  final ValueChanged<Object> onSubmit;
  final VoidCallback onCancel;

  @override
  State<_UserQuestionTakeoverCard> createState() => _UserQuestionTakeoverCardState();
}

class _UserQuestionTakeoverCardState extends State<_UserQuestionTakeoverCard> {
  final Map<String, Set<String>> _selectedById = {};
  final Map<String, TextEditingController> _customCtrls = {};
  final ValueNotifier<int> _answerVersion = ValueNotifier<int>(0);

  List<UserQuestionItem> get _items => widget.question.allQuestions;

  TextEditingController _ctrlFor(String id) =>
      _customCtrls.putIfAbsent(id, () => TextEditingController());

  @override
  void dispose() {
    _answerVersion.dispose();
    for (final c in _customCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  int get _unansweredCount {
    var missing = 0;
    for (final q in _items) {
      final sel = _selectedById[q.id];
      final free = _customCtrls[q.id]?.text.trim() ?? '';
      if ((sel == null || sel.isEmpty) && free.isEmpty) {
        missing++;
      }
    }
    return missing;
  }

  bool get _canSubmit => _items.isNotEmpty && _unansweredCount == 0;

  void _confirm() {
    if (!_canSubmit) return;
    final answers = <Map<String, dynamic>>[];
    for (final q in _items) {
      final sel = _selectedById[q.id]?.toList(growable: false) ?? const <String>[];
      final free = _customCtrls[q.id]?.text.trim() ?? '';
      answers.add({
        'id': q.id,
        'selected': sel,
        if (free.isNotEmpty) 'custom': free,
      });
    }
    widget.onSubmit({'answers': answers});
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final items = _items;
    final multiQ = items.length > 1;
    return GlassBackdropGroup(
      enabled: false,
      child: GrassBagGlass(
        tier: widget.tier,
        borderRadius: 28,
        elevated: true,
        useSheetSettings: true,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                GrassBagSquircleIcon(
                  icon: CupertinoIcons.question_circle_fill,
                  color: t.primary,
                  size: 34,
                  iconSize: 17,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        multiQ ? '${widget.question.title}（共 ${items.length} 题）' : widget.question.title,
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.text),
                      ),
                      if (!multiQ && (widget.question.prompt.isNotEmpty || (items.isNotEmpty && items.first.multiSelect)))
                        Text(
                          '${widget.question.prompt}${items.isNotEmpty && items.first.multiSelect ? (widget.question.prompt.isNotEmpty ? '（可多选）' : '可多选') : ''}',
                          style: TextStyle(fontSize: 12, color: t.text2),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 11),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: (MediaQuery.sizeOf(context).height * 0.36).clamp(130.0, 280.0),
              ),
              child: RepaintBoundary(
                child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var qi = 0; qi < items.length; qi++) ...[
                    if (qi > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Divider(height: 0.6, color: t.sep),
                      ),
                    () {
                      final q = items[qi];
                      final pickedSet = _selectedById.putIfAbsent(q.id, () => <String>{});
                      final ctrl = _ctrlFor(q.id);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (multiQ) ...[
                            Text(
                              '${qi + 1}. ${q.prompt.isNotEmpty ? q.prompt : q.title}${q.multiSelect ? '（可多选）' : ''}',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: t.text,
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          if (q.options.isNotEmpty)
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (var i = 0; i < q.options.length; i++)
                                  () {
                                    final opt = q.options[i];
                                    final desc = i < q.optionDescriptions.length
                                        ? q.optionDescriptions[i]
                                        : '';
                                    final picked = pickedSet.contains(opt);
                                    return GrassBagSpringTap(
                                      onTap: () {
                                        setState(() {
                                          if (q.multiSelect) {
                                            if (!pickedSet.add(opt)) pickedSet.remove(opt);
                                          } else if (pickedSet.contains(opt)) {
                                            pickedSet.remove(opt);
                                          } else {
                                            pickedSet
                                              ..clear()
                                              ..add(opt);
                                          }
                                        });
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 7,
                                        ),
                                        decoration: BoxDecoration(
                                          color: picked ? t.primarySoft : t.fill1,
                                          borderRadius: BorderRadius.circular(desc.isEmpty ? 999 : 14),
                                          border: Border.all(
                                            color: picked ? t.primary : t.sep,
                                            width: 0.8,
                                          ),
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              opt,
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w600,
                                                color: picked ? t.primary : t.text,
                                              ),
                                            ),
                                            if (desc.isNotEmpty) ...[
                                              const SizedBox(height: 2),
                                              Text(
                                                desc,
                                                style: TextStyle(fontSize: 11, color: t.text3),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    );
                                  }(),
                              ],
                            ),
                          if (q.allowFreeText || q.options.isEmpty) ...[
                            if (q.options.isNotEmpty) const SizedBox(height: 9),
                            GrassBagTextField(
                              controller: ctrl,
                              placeholder: q.options.isEmpty ? '请输入你的回答…' : '或输入其他补充说明…',
                              fontSize: 13,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              insideGlass: true,
                              onChanged: (_) => _answerVersion.value++,
                            ),
                          ],
                        ],
                      );
                    }(),
                  ],
                ],
              ),
            ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              GrassBagSecondaryGlassButton(
                label: '停止',
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                tier: widget.tier,
                insideGlass: true,
                destructive: true,
                onTap: widget.onCancel,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ValueListenableBuilder<int>(
                  valueListenable: _answerVersion,
                  builder: (_, __, ___) => GrassBagPrimaryGlassButton(
                    label: _canSubmit
                        ? '提交选择'
                        : (multiQ ? '还有 $_unansweredCount 题未完成' : '请先完成以上选择或输入'),
                    height: 40,
                    tier: widget.tier,
                    insideGlass: true,
                    enabled: _canSubmit,
                    onTap: _canSubmit ? _confirm : null,
                  ),
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

class _CordisRunTakeoverCard extends StatelessWidget {
  const _CordisRunTakeoverCard({
    super.key,
    required this.request,
    required this.tier,
    required this.onDecision,
  });

  final ActiveCordisRunRequest request;
  final GrassBagGlassTier tier;
  final ValueChanged<bool> onDecision;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GlassBackdropGroup(
      enabled: false,
      child: GrassBagGlass(
      tier: tier,
      borderRadius: 28,
      elevated: true,
      useSheetSettings: true,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GrassBagSquircleIcon(
                icon: CupertinoIcons.cube_box_fill,
                color: t.dusk,
                size: 34,
                iconSize: 17,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '请求运行动态扩展模块',
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.text),
                    ),
                    Text(
                      '${request.pluginName} · ${request.summary.isNotEmpty ? request.summary : '助手按需加载扩展能力以完成任务'}',
                      style: TextStyle(fontSize: 12, color: t.text3),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (request.codePreview.isNotEmpty) ...[
            const SizedBox(height: 10),
            ClipRSuperellipse(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 110),
                padding: const EdgeInsets.all(10),
                color: t.codeBg,
                child: SingleChildScrollView(
                  child: Text(
                    request.codePreview,
                    style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: t.codeFg),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GrassBagSecondaryGlassButton(
                  label: '拒绝加载',
                  height: 40,
                  tier: tier,
                  insideGlass: true,
                  destructive: true,
                  onTap: () => onDecision(false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GrassBagPrimaryGlassButton(
                  label: '允许运行',
                  height: 40,
                  tier: tier,
                  insideGlass: true,
                  onTap: () => onDecision(true),
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

/// Isolated context-pressure ring button so `contextPct` ticks during streaming
/// repaint ONLY this 19×19 ring inside a `RepaintBoundary` and NEVER rebuild `ChatComposerDock`!
class _ComposerContextRingButton extends ConsumerWidget {
  const _ComposerContextRingButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (isEmptyChat: s.isEmptyChat, contextPct: s.contextPct),
      ),
    );
    if (slice.contextPct <= 0) {
      return const SizedBox.shrink();
    }
    final t = GrassBagTokens.of(context);
    final pctInt = slice.contextPct;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: '上下文占用 $pctInt%（点击查看与精简）',
          child: GrassBagSpringTap(
            onTap: () => showContextSheet(context, ref),
            pressedScale: 0.88,
            haptic: true,
            child: Container(
              height: 36,
              padding: EdgeInsets.symmetric(horizontal: pctInt >= 65 ? 9 : 8.5),
              decoration: BoxDecoration(
                color: pctInt >= 85
                    ? t.errSoft
                    : pctInt >= 65
                        ? t.warnSoft
                        : Colors.white.withValues(alpha: t.isDark ? 0.10 : 0.60),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: pctInt >= 85
                      ? t.err.withValues(alpha: 0.28)
                      : pctInt >= 65
                          ? t.warn.withValues(alpha: 0.28)
                          : Colors.white.withValues(alpha: t.isDark ? 0.18 : 0.90),
                  width: 0.65,
                ),
                boxShadow: t.isDark
                    ? null
                    : const [
                        BoxShadow(
                          color: Color(0x0C000000),
                          blurRadius: 6,
                          offset: Offset(0, 2),
                        ),
                      ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RepaintBoundary(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: pctInt / 100.0),
                      duration: const Duration(milliseconds: 420),
                      curve: Curves.easeOutCubic,
                      builder: (context, pct, _) => SizedBox(
                        width: 19,
                        height: 19,
                        child: CustomPaint(
                          painter: _ContextRingPainter(
                            percent: pct,
                            trackColor: t.text3.withValues(alpha: 0.24),
                            arcColor: pctInt >= 85
                                ? t.err
                                : pctInt >= 65
                                    ? t.warn
                                    : t.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (pctInt >= 65) ...[
                    const SizedBox(width: 4),
                    Text(
                      '$pctInt%',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: pctInt >= 85 ? t.err : t.warn,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}
