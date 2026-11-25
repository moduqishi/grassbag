import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';

/// Active contextual edit-message session shown above the composer pill.
@immutable
class EditingMessageContext {
  const EditingMessageContext({
    required this.turnId,
    required this.originalText,
    required this.stashedDraft,
    this.forkBeforeTurnId,
    this.references = const [],
  });

  final String turnId;
  final String originalText;
  final String stashedDraft;
  final String? forkBeforeTurnId;
  final List<Map<String, dynamic>> references;

  bool get canForkBefore => forkBeforeTurnId != null && forkBeforeTurnId!.isNotEmpty;
}

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
    this.hasNewBelowListenable,
    this.onScrollToBottom,
    this.composerHeightNotifier,
    this.suggestionsOpenNotifier,
    this.editingContextNotifier,
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
  final ValueListenable<bool>? hasNewBelowListenable;
  final VoidCallback? onScrollToBottom;
  final ValueNotifier<double>? composerHeightNotifier;
  final ValueNotifier<bool>? suggestionsOpenNotifier;
  final ValueNotifier<EditingMessageContext?>? editingContextNotifier;

  @override
  ConsumerState<ChatComposerDock> createState() => _ChatComposerDockState();
}

class _ChatComposerDockState extends ConsumerState<ChatComposerDock>
    with SingleTickerProviderStateMixin {
  static final RegExp _slashTriggerRe = RegExp(r'^/([a-zA-Z0-9_:.-]*)$');
  // Allow Chinese prose or punctuation immediately before `@` (e.g. `看看@composer`),
  // while ignoring email addresses (`foo@bar.com`).
  static final RegExp _atTriggerRe = RegExp(r'(?:^|[^a-zA-Z0-9._+-])(@([^\s]*))$');

  late final SingleSpringController _plusSpring;
  final ValueNotifier<int> _suggestionTickNotifier = ValueNotifier<int>(0);
  final ScrollController _suggestionScrollCtrl = ScrollController();
  bool _plusOpen = false;
  bool _hasText = false;
  bool _compactNudgeDismissed = false;
  bool _wasImeComposing = false;
  int _lastImeComposingEndMs = 0;
  bool _editBranchResend = true;
  String? _mentionTrigger; // '/' or '@'
  String _mentionQuery = '';
  int _mentionStartOffset = -1;
  String? _dismissedMentionText;
  final ValueNotifier<int> _activeSuggestionIdxNotifier = ValueNotifier<int>(0);
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

  void _showEditQueuedDialog(BuildContext context, QueuedMessageItem item) {
    showGrassBagSheet(
      context,
      title: item.mode == 'steer' ? '编辑插话内容' : '编辑排队消息',
      subtitle: '修改后将同步更新待发送队列',
      preferredHeight: 240,
      bodyBuilder: (sheetCtx) => _EditQueuedMessageSheetBody(item: item),
    );
  }

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

  void _cancelEditingMessage() {
    final editCtx = widget.editingContextNotifier?.value;
    if (editCtx == null) return;
    HapticFeedback.selectionClick();
    widget.editingContextNotifier!.value = null;
    final restore = editCtx.stashedDraft;
    widget.controller.value = TextEditingValue(
      text: restore,
      selection: TextSelection.collapsed(offset: restore.length),
    );
    _flushDraftSync();
  }

  KeyEventResult _handleComposerKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // CRITICAL CJK IME guard: NEVER steal ArrowUp/ArrowDown/Escape/Enter while Pinyin/Kana/Hangul
    // composition is active (or within the 60ms post-commit window on macOS/Web Chrome/Safari)!
    final composing = widget.controller.value.composing;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final isImeComposing = (composing.isValid && !composing.isCollapsed) ||
        event.logicalKey == LogicalKeyboardKey.process ||
        (event.logicalKey == LogicalKeyboardKey.enter && (nowMs - _lastImeComposingEndMs) < 60);
    if (isImeComposing) {
      return KeyEventResult.ignored;
    }

    if (_mentionTrigger != null) {
      final count = _mentionTrigger == '/' ? _latestCommands.length : _latestRefs.length;
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _dismissSuggestions();
        return KeyEventResult.handled;
      }
      if (count > 0 && event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _activeSuggestionIdxNotifier.value = (_activeSuggestionIdxNotifier.value + 1) % count;
        _scrollActiveSuggestionIntoView();
        return KeyEventResult.handled;
      }
      if (count > 0 && event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _activeSuggestionIdxNotifier.value =
            (_activeSuggestionIdxNotifier.value - 1 + count) % count;
        _scrollActiveSuggestionIntoView();
        return KeyEventResult.handled;
      }
      if (count > 0 &&
          event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.tab ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
        final keys = HardwareKeyboard.instance.logicalKeysPressed;
        final shiftPressed = HardwareKeyboard.instance.isShiftPressed ||
            keys.contains(LogicalKeyboardKey.shiftLeft) ||
            keys.contains(LogicalKeyboardKey.shiftRight) ||
            keys.contains(LogicalKeyboardKey.shift);
        if (shiftPressed && event.logicalKey != LogicalKeyboardKey.tab) {
          _insertNewlineAtCursor();
          return KeyEventResult.handled;
        }
        final idx = _activeSuggestionIdxNotifier.value.clamp(0, count - 1);
        final isTab = event.logicalKey == LogicalKeyboardKey.tab;
        if (_mentionTrigger == '/') {
          final cmd = _latestCommands[idx];
          final isEmptyChat = ref.read(appProvider).isEmptyChat;
          final canInstant = const {'/new', '/plan', '/status'}.contains(cmd.command) ||
              (!isEmptyChat && const {'/fork', '/export'}.contains(cmd.command));
          _applySuggestion(
            cmd.command,
            executeImmediately: !isTab && canInstant,
          );
        } else {
          final refItem = _latestRefs[idx];
          _applySuggestion(refItem['path'] ?? '', refItem: refItem);
        }
        return KeyEventResult.handled;
      }
    }

    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        widget.editingContextNotifier?.value != null) {
      _cancelEditingMessage();
      return KeyEventResult.handled;
    }

    // Desktop power-user shortcut: press ArrowUp in an empty composer to quickly edit the last prompt!
    if (_isDesktopPlatform &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowUp &&
        widget.controller.text.isEmpty &&
        widget.editingContextNotifier != null) {
      final snap = ref.read(appProvider);
      if (!snap.isStreaming && snap.turns.isNotEmpty) {
        for (var i = snap.turns.length - 1; i >= 0; i--) {
          final turn = snap.turns[i];
          final txt = turn.userMessage?.text.trim() ?? '';
          if (txt.isNotEmpty) {
            final forkBeforeId = i > 0 ? snap.turns[i - 1].turnId : null;
            widget.editingContextNotifier!.value = EditingMessageContext(
              turnId: turn.turnId,
              originalText: txt,
              stashedDraft: '',
              forkBeforeTurnId: forkBeforeId,
              references: turn.userMessage?.references ?? const [],
            );
            widget.controller.value = TextEditingValue(
              text: txt,
              selection: TextSelection.collapsed(offset: txt.length),
            );
            return KeyEventResult.handled;
          }
        }
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
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
        if (shiftPressed && cmdOrCtrlPressed && ref.read(appProvider).isStreaming) {
          if (event is KeyDownEvent) {
            unawaited(_submit(mode: 'steer'));
          }
          return KeyEventResult.handled;
        }
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
    widget.suggestionsOpenNotifier?.addListener(_onExternalSuggestionsChanged);
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
    if (oldWidget.suggestionsOpenNotifier != widget.suggestionsOpenNotifier) {
      oldWidget.suggestionsOpenNotifier?.removeListener(_onExternalSuggestionsChanged);
      widget.suggestionsOpenNotifier?.addListener(_onExternalSuggestionsChanged);
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
    widget.suggestionsOpenNotifier?.removeListener(_onExternalSuggestionsChanged);
    _plusSpring.dispose();
    _suggestionTickNotifier.dispose();
    _activeSuggestionIdxNotifier.dispose();
    _suggestionScrollCtrl.dispose();
    super.dispose();
  }

  void _scrollActiveSuggestionIntoView() {
    if (!_suggestionScrollCtrl.hasClients) return;
    const itemExtent = 38.0;
    final targetTop = _activeSuggestionIdxNotifier.value * itemExtent;
    final targetBottom = targetTop + itemExtent;
    final pos = _suggestionScrollCtrl.position;
    if (targetTop < pos.pixels) {
      _suggestionScrollCtrl.animateTo(
        targetTop.clamp(0.0, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
      );
    } else if (targetBottom > pos.pixels + pos.viewportDimension) {
      _suggestionScrollCtrl.animateTo(
        (targetBottom - pos.viewportDimension).clamp(0.0, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onExternalSuggestionsChanged() {
    final open = widget.suggestionsOpenNotifier?.value ?? false;
    if (!open && _mentionTrigger != null) {
      _dismissSuggestions();
    }
  }

  void _syncSuggestionsNotifier(bool open) {
    final n = widget.suggestionsOpenNotifier;
    if (n != null && n.value != open) {
      n.value = open;
    }
  }

  void _dismissSuggestions() {
    _refDebounceTimer?.cancel();
    setState(() {
      _dismissedMentionText = widget.controller.text;
      _mentionTrigger = null;
      _mentionQuery = '';
      _mentionStartOffset = -1;
      _loadingRefs = false;
      _remoteRefs = const [];
    });
    _activeSuggestionIdxNotifier.value = 0;
    _syncSuggestionsNotifier(false);
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
  String? _draftScopeHostId;
  String? _draftScopeSessionId;
  bool _hasUnsyncedDraftEdit = false;

  void _flushPendingDraftToOutgoingScope(String? outgoingHostId, String? outgoingSessionId) {
    _draftSyncTimer?.cancel();
    _draftSyncTimer = null;
    if (!_hasUnsyncedDraftEdit || outgoingHostId == null || outgoingHostId.isEmpty) return;
    _hasUnsyncedDraftEdit = false;
    ref.read(appProvider.notifier).setComposerDraftForScope(
          outgoingHostId,
          outgoingSessionId,
          widget.controller.text,
        );
  }

  void _setControllerDraftSafely(String draft) {
    _draftSyncTimer?.cancel();
    _draftSyncTimer = null;
    _hasUnsyncedDraftEdit = false;
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
    _draftSyncTimer = null;
    _hasUnsyncedDraftEdit = false;
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
    final nowComposing = val.composing.isValid && !val.composing.isCollapsed;
    if (_wasImeComposing && !nowComposing) {
      _lastImeComposingEndMs = DateTime.now().millisecondsSinceEpoch;
    }
    _wasImeComposing = nowComposing;
    final raw = val.text;
    // Debounce draft persistence sync (400ms) so fast typing never clones host draft maps
    // or churns persistence timers on every single keystroke. Skip while editing an earlier
    // turn so the user's stashed unsent draft is NEVER overwritten by the edited message!
    _draftSyncTimer?.cancel();
    if (widget.editingContextNotifier?.value == null) {
      final snap = ref.read(appProvider);
      final draftHostId = snap.activeHostId;
      final draftSessionId = snap.activeSessionId;
      final draftRenderGen = snap.sessionRenderGen;
      _draftScopeHostId = draftHostId;
      _draftScopeSessionId = draftSessionId;
      _hasUnsyncedDraftEdit = true;
      _draftSyncTimer = Timer(const Duration(milliseconds: 400), () {
        if (!mounted || widget.editingContextNotifier?.value != null) return;
        final cur = ref.read(appProvider);
        if (cur.activeHostId != draftHostId || cur.sessionRenderGen != draftRenderGen) {
          return;
        }
        _hasUnsyncedDraftEdit = false;
        final ctrl = ref.read(appProvider.notifier);
        final latest = widget.controller.text;
        if (ctrl.getComposerDraftForActiveHost() != latest) {
          ctrl.setComposerDraftForActiveHost(latest);
        }
      });
    }
    final nextHasText = raw.trim().isNotEmpty;
    if (_dismissedMentionText != null && _dismissedMentionText != raw) {
      _dismissedMentionText = null;
    }
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
    if (_dismissedMentionText == null && beforeCursor.isNotEmpty) {
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
    final atMatch = _dismissedMentionText == null &&
            slashMatch == null &&
            beforeCursor.contains('@')
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
        _loadingRefs = false;
        _remoteRefs = refs;
        _suggestionTickNotifier.value++;
      });
    }

    final triggerVisibilityOrKindChanged = nextTrigger != _mentionTrigger;
    final queryChanged = nextQuery != _mentionQuery;
    final startChanged = nextStart != _mentionStartOffset;
    if (nextHasText != _hasText || triggerVisibilityOrKindChanged) {
      if (triggerVisibilityOrKindChanged || queryChanged) {
        _activeSuggestionIdxNotifier.value = 0;
      }
      setState(() {
        _hasText = nextHasText;
        _mentionTrigger = nextTrigger;
        _mentionQuery = nextQuery;
        _mentionStartOffset = nextStart;
      });
      _suggestionTickNotifier.value++;
      _syncSuggestionsNotifier(nextTrigger != null);
    } else if (queryChanged || startChanged) {
      // Filtering inside an already-open `/` or `@` popover updates ONLY the popover leaf —
      // ZERO rebuilds of ChatComposerDock, TextField, or Liquid Glass composer chrome!
      if (queryChanged) {
        _activeSuggestionIdxNotifier.value = 0;
      }
      _mentionQuery = nextQuery;
      _mentionStartOffset = nextStart;
      _suggestionTickNotifier.value++;
    }
  }

  static int _findTokenEnd(String raw, int cursor) {
    var end = cursor;
    while (end < raw.length) {
      final cu = raw.codeUnitAt(end);
      if (cu == 0x20 || cu == 0x0A || cu == 0x0D || cu == 0x09) break;
      end++;
    }
    return end;
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
      final tokenEnd = _findTokenEnd(raw, cursor);
      final afterToken = raw.substring(tokenEnd);
      final insert = afterToken.startsWith(' ') ? replacement : '$replacement ';
      final updated = raw.replaceRange(start, tokenEnd, insert);
      widget.controller.value = TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: start + insert.length),
      );
      if (executeImmediately && afterToken.trim().isEmpty) {
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
        final tokenEnd = _findTokenEnd(raw, cursor);
        final afterToken = raw.substring(tokenEnd);
        final insert = afterToken.startsWith(' ') ? '@$replacement' : '@$replacement ';
        final updated = raw.replaceRange(start, tokenEnd, insert);
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
      _dismissedMentionText = null;
      _mentionTrigger = null;
      _mentionQuery = '';
      _mentionStartOffset = -1;
      _remoteRefs = const [];
    });
    _activeSuggestionIdxNotifier.value = 0;
    _syncSuggestionsNotifier(false);
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
    if (widget.editingContextNotifier?.value != null) {
      widget.editingContextNotifier!.value = null;
    }
    if (mounted) {
      setState(() {
        _submitting = false;
        _hasText = widget.controller.text.trim().isNotEmpty;
        _mentionTrigger = null;
        _mentionQuery = '';
        _mentionStartOffset = -1;
        _remoteRefs = const [];
      });
      _activeSuggestionIdxNotifier.value = 0;
    }
    _syncSuggestionsNotifier(false);
  }

  Future<void> _submit({String mode = 'auto'}) async {
    if (_submitting) return;
    final rawText = widget.controller.text;
    final text = rawText.trim();
    final appSnapshot = ref.read(appProvider);
    final hasAtt = appSnapshot.pendingAttachments.isNotEmpty;
    if (text.isEmpty && !hasAtt) return;
    final ctrl = ref.read(appProvider.notifier);

    // Pre-flight guard: preserve user's draft when hydrated local Android engine is still booting
    // or not deployed, host is mid-reconnect/bootstrap, remote host awaits auth, or connected DSH has 0 models!
    if (GrassBagNativeBridge.instance.isAndroidNative &&
        appSnapshot.activeHost.isLocal &&
        appSnapshot.nativeStatusHydrated &&
        !appSnapshot.nativeRuntimeStatus.engineRunning) {
      if (appSnapshot.nativeRuntimeStatus.engineState == 'starting' ||
          (appSnapshot.runtimeProgressPct > 0 && appSnapshot.runtimeProgressPct < 100)) {
        ctrl.showToast('本机 DSH 引擎正在启动中，已保留输入内容…', tone: ToastTone.info);
        return;
      }
      if (!appSnapshot.nativeRuntimeStatus.initialized) {
        if (appSnapshot.nativeRuntimeStatus.hasBundledRuntimePayloads) {
          ctrl.showToast('正在部署本机运行环境，已保留输入内容…', tone: ToastTone.info);
        }
        unawaited(
          triggerLocalRuntimeBootstrapWithGuard(
            context,
            ref,
            requireConfirmForRemote: true,
            implicitContextHint: '已保留你的输入内容',
          ),
        );
        return;
      }
      ctrl.showToast('正在启动本机 DSH 引擎，已保留输入内容…', tone: ToastTone.info);
      unawaited(ctrl.restartLocalEngine());
      return;
    }
    if (!appSnapshot.isDshConnected &&
        (appSnapshot.connectionPhase == ConnectionPhase.reconnecting ||
            appSnapshot.connectionPhase == ConnectionPhase.bootstrapping)) {
      ctrl.showToast('正在连接主机，连接成功后可立即发送（已保留输入内容）', tone: ToastTone.info);
      return;
    }
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
        !appSnapshot.hasAvailableModels &&
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
    var expectedRenderGen = appSnapshot.sessionRenderGen;
    final editCtx = widget.editingContextNotifier?.value;
    final shouldForkBefore = editCtx != null && _editBranchResend && editCtx.canForkBefore && !appSnapshot.isStreaming;
    // Preserve soft-keyboard focus across keyboard Send and Send-orb tap so users
    // never get their IME collapsed on every message!
    final hadFocus = widget.focusNode.hasFocus;
    HapticFeedback.lightImpact();
    if (_plusOpen) {
      _setPlusOpen(false);
    }
    final activeRefs = <Map<String, dynamic>>[
      ..._pickedReferences.where((r) => text.contains('@${r['path']}')),
      if (editCtx != null)
        ...editCtx.references.where(
          (r) =>
              !_pickedReferences.any((p) => p['path'] == r['path']) &&
              (r['path'] == null || text.contains('@${r['path']}')),
        ),
    ];
    // Clear input optimistically BEFORE awaiting async send so typing stays instant
    // and Android IME composing state resets cleanly without dismissing the keyboard.
    widget.controller.clear();
    _flushDraftSync();
    if (widget.editingContextNotifier?.value != null) {
      widget.editingContextNotifier!.value = null;
    }
    if (hadFocus && !widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
    }
    setState(() {
      _submitting = true;
      _hasText = false;
      _mentionTrigger = null;
      _mentionQuery = '';
    });
    _activeSuggestionIdxNotifier.value = 0;
    _syncSuggestionsNotifier(false);
    if (shouldForkBefore && editCtx.forkBeforeTurnId != null) {
      final forked = await ctrl.forkActiveSession(
        turnId: editCtx.forkBeforeTurnId,
        syncAfter: false,
      );
      if (!mounted) return;
      if (!forked) {
        setState(() => _submitting = false);
        widget.editingContextNotifier?.value = editCtx;
        widget.controller.value = TextEditingValue(
          text: rawText,
          selection: TextSelection.collapsed(offset: rawText.length),
        );
        return;
      }
      expectedRenderGen = ref.read(appProvider).sessionRenderGen;
    }
    final sent = await ref.read(appProvider.notifier).sendPrompt(
          text,
          mode: mode,
          references: activeRefs.isEmpty ? null : activeRefs,
        );
    if (!mounted) return;
    final curState = ref.read(appProvider);
    // `sessionRenderGen` stays invariant across Empty Chat -> `pending-session-*` -> real UUID promotion,
    // while switching sessions or hosts ALWAYS increments `sessionRenderGen` — fixing first-turn `sameScope`!
    final sameScope =
        curState.activeHostId == startHostId && curState.sessionRenderGen == expectedRenderGen;
    setState(() => _submitting = false);
    if (!sameScope) {
      // User switched hosts or sessions while sending; never overwrite the new composer or refs!
      return;
    }
    if (sent) {
      _pickedReferences.clear();
      widget.onMessageSent?.call();
    } else if (rawText.isNotEmpty) {
      // Never drop user's failed prompt even if they started typing while the send was in flight!
      final curText = widget.controller.text;
      final restored = curText.isEmpty ? rawText : '$rawText\n\n$curText';
      widget.controller.value = TextEditingValue(
        text: restored,
        selection: TextSelection.collapsed(offset: restored.length),
      );
    }
    if (hadFocus && mounted && !widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(appProvider.select((s) => s.activeHostId), (prev, next) {
      if (prev != null && prev != next) {
        _flushPendingDraftToOutgoingScope(_draftScopeHostId ?? prev, _draftScopeSessionId);
        _draftScopeHostId = next;
        _draftScopeSessionId = ref.read(appProvider).activeSessionId;
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
          final curHostId = ref.read(appProvider).activeHostId;
          _flushPendingDraftToOutgoingScope(_draftScopeHostId ?? curHostId, prev);
          _draftScopeHostId = curHostId;
          _draftScopeSessionId = next;
          _setControllerDraftSafely(ref.read(appProvider.notifier).getComposerDraftForActiveHost());
          _resetTransientComposerUi();
        } else {
          _draftScopeSessionId = next;
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
        (s) {
          final host = s.activeHost;
          final model = s.effectiveActiveModelEntry;
          return (
            glassTier: s.glassTier,
            activePermission: s.activePermission,
            planMode: s.planMode,
            speechConfigured: s.speechConfigured,
            pendingApprovalCommand: s.pendingApprovalCommand,
            pendingApprovalInteractionId: s.pendingApprovalInteractionId,
            pendingApprovalToolName: s.pendingApprovalToolName,
            activePendingInteractionCount: s.activePendingInteractionCount,
            activeQuestion: s.activeQuestion,
            activeCordisRequest: s.activeCordisRequest,
            contextPctHigh: s.contextPct >= 80 ? s.contextPct : 0,
            pendingAttachments: s.pendingAttachments,
            queuedMessages: s.queuedMessages,
            activeWorkspace: s.activeWorkspaceDisplayName,
            isEmptyChat: s.isEmptyChat,
            isStreaming: s.isStreaming,
            isStopping: s.isStopping,
            sendStage: s.sendStage,
            busyEnterMode: () {
              final conv = s.dshNamespaces.where((n) => n.ns == 'ui-conversation').firstOrNull;
              final raw = conv?.value['busyEnter']?.toString().trim().toLowerCase();
              return raw == 'steer' ? 'steer' : 'queue';
            }(),
            activeModelId: s.activeModelId,
            modelShort: s.modelShort,
            modelEffort: s.modelEffort,
            hasAvailableModels: s.hasAvailableModels,
            fallbackModelShort: model?.shortLabel ?? '',
            fallbackModelEffort: model != null
                ? (s.modelEffort.isNotEmpty
                    ? s.modelEffort
                    : (model.efforts
                            .where((e) => e.id == model.defaultEffort)
                            .firstOrNull
                            ?.zhLabel ??
                        ''))
                : '',
            connectionPhase: s.connectionPhase,
            isDshConnected: s.isDshConnected,
            hydratingDomains: s.hydratingDomains,
            hostIsLocal: host.isLocal,
            hostDirectMode: host.directMode,
            hostNeedsAuth: host.needsAuth,
            routableProvidersCount: s.routableProviders.length,
          );
        },
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
    final showReadOnlyPill =
        perm.id == 'read-only' && !hasTakeover && !state.isEmptyChat && !_plusOpen;
    final showPlanPill = state.planMode && !hasTakeover && !_plusOpen;
    final showCompactNudgePill = state.contextPctHigh >= 80 &&
        !_compactNudgeDismissed &&
        !state.isStreaming &&
        !state.isEmptyChat &&
        !hasTakeover &&
        !_plusOpen;
    if (state.contextPctHigh < 80 && _compactNudgeDismissed) {
      _compactNudgeDismissed = false;
    }
    final hasStatusPills = showRiskPill || showReadOnlyPill || showPlanPill || showCompactNudgePill;
    final screenW = MediaQuery.sizeOf(context).width;
    final isWide = screenW >= 540;

    if (hasTakeover && (_plusOpen || _mentionTrigger != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_plusOpen) _setPlusOpen(false);
        if (_mentionTrigger != null) {
          setState(() {
            _mentionTrigger = null;
            _mentionQuery = '';
          });
          _activeSuggestionIdxNotifier.value = 0;
          _syncSuggestionsNotifier(false);
        }
      });
    }
    final showSuggestions = !hasTakeover &&
        !_plusOpen &&
        (_mentionTrigger == '/' || _mentionTrigger == '@');
    if (!showSuggestions) {
      _latestCommands = const [];
      _latestRefs = const [];
      if (widget.suggestionsOpenNotifier?.value == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncSuggestionsNotifier(false);
        });
      }
    }
    final isHostNeedsAuth = !state.hostIsLocal &&
        (state.hostNeedsAuth || state.connectionPhase == ConnectionPhase.needsAuth);
    final isHostConnecting = state.connectionPhase == ConnectionPhase.connecting ||
        state.connectionPhase == ConnectionPhase.reconnecting ||
        state.connectionPhase == ConnectionPhase.bootstrapping;
    final isHostConnected = state.isDshConnected &&
        state.connectionPhase == ConnectionPhase.connected;
    final hasCachedModelWhileReconnecting =
        state.connectionPhase == ConnectionPhase.reconnecting && state.hasAvailableModels;
    final isHydratingModels =
        isHostConnected && state.hydratingDomains && !state.hasAvailableModels;
    final needsModelConfig = isHostConnected &&
        !state.hydratingDomains &&
        !state.hasAvailableModels &&
        state.routableProvidersCount == 0;

    final isDesktopPlatform = _isDesktopPlatform;

    Widget buildScrollDroplet(
      bool showDroplet, {
      bool hasNewBelow = false,
      bool inlineWithPills = false,
    }) {
      final visible = showDroplet &&
          !state.isEmptyChat &&
          !_plusOpen &&
          !hasTakeover &&
          !showSuggestions;
      final size = inlineWithPills ? 34.0 : 40.0;
      final showActivityPill = state.isStreaming || hasNewBelow;
      final pillLabel = state.isStreaming ? '正在回复' : '有新回复';
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 210),
        reverseDuration: const Duration(milliseconds: 160),
        switchInCurve: Curves.linear,
        switchOutCurve: Curves.linear,
        transitionBuilder: (child, anim) {
          return GrassBagMaterializeTransition(
            animation: anim,
            tier: state.glassTier,
            alignment: Alignment.bottomRight,
            scaleFrom: 0.86,
            contentSigma: 3.5,
            child: child,
          );
        },
        child: visible
            ? Padding(
                key: ValueKey('scroll-down-${showActivityPill ? pillLabel : 'circle'}'),
                padding: inlineWithPills
                    ? const EdgeInsets.only(left: 8)
                    : const EdgeInsets.only(bottom: 10),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: showActivityPill
                      ? GrassBagGlassPillButton(
                          tier: state.glassTier,
                          height: inlineWithPills ? 34 : 38,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          onTap: () => widget.onScrollToBottom?.call(),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              GrassBagStatusDot(
                                color: t.primary,
                                pulsing: state.isStreaming,
                                size: 7,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                pillLabel,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: t.primary,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                CupertinoIcons.chevron_down,
                                size: 13.5,
                                color: t.primary,
                              ),
                            ],
                          ),
                        )
                      : GrassBagGlassCircleButton(
                          icon: CupertinoIcons.chevron_down,
                          size: size,
                          iconSize: inlineWithPills ? 17 : 19,
                          tooltip: '回到底部',
                          tier: state.glassTier,
                          onTap: () => widget.onScrollToBottom?.call(),
                        ),
                ),
              )
            : const SizedBox.shrink(key: ValueKey('scroll-down-empty')),
      );
    }

    Widget scrollDropletWidget({bool inlineWithPills = false}) {
      final showListen = widget.showScrollToBottomListenable;
      final newListen = widget.hasNewBelowListenable;
      if (showListen != null && newListen != null) {
        return ListenableBuilder(
          listenable: Listenable.merge([showListen, newListen]),
          builder: (_, __) => buildScrollDroplet(
            showListen.value,
            hasNewBelow: newListen.value,
            inlineWithPills: inlineWithPills,
          ),
        );
      }
      if (showListen != null) {
        return ValueListenableBuilder<bool>(
          valueListenable: showListen,
          builder: (_, visible, __) =>
              buildScrollDroplet(visible, inlineWithPills: inlineWithPills),
        );
      }
      return buildScrollDroplet(
        widget.showScrollToBottom,
        hasNewBelow: newListen?.value ?? false,
        inlineWithPills: inlineWithPills,
      );
    }

    return Center(
      heightFactor: 1.0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: LayoutBuilder(
          builder: (context, dockBox) {
            final maxDockH = dockBox.maxHeight.isFinite ? dockBox.maxHeight : 560.0;
            final isTightDock = dockBox.maxHeight.isFinite && dockBox.maxHeight < 290.0;
            final effectiveTextMaxLines =
                maxDockH < 210.0 ? 2 : (maxDockH < 270.0 ? 3 : 5);
            final takeoverMaxH = math.min(
              560.0,
              math.max(140.0, maxDockH - (hasStatusPills ? 48.0 : 0.0)),
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Standalone floating "Scroll to latest" droplet when no status pill row is present.
                // Kept OUTSIDE _ComposerHeightReporter so scrolling up never alters ListView tail height.
                if (!hasStatusPills && maxDockH >= 210.0) scrollDropletWidget(),

                // Single Flexible slot shared by `/` & `@` suggestions and the `+` Deck (mutually exclusive)
                // so the active overlay receives 100% of available height above the composer pill without
                // RenderFlex dividing free space across multiple Flexible siblings.
                Flexible(
                  fit: FlexFit.loose,
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    clipBehavior: Clip.none,
                    children: [
                      AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              reverseDuration: const Duration(milliseconds: 130),
              switchInCurve: Curves.linear,
              switchOutCurve: Curves.linear,
              transitionBuilder: (child, anim) => _ComposerSlideMaterialize(
                animation: anim,
                tier: state.glassTier,
                beginOffset: const Offset(0, 0.06),
                scaleFrom: 0.95,
                contentSigma: 4.0,
                child: child,
              ),
              child: showSuggestions
                  ? Consumer(
                      key: ValueKey('suggestions-$_mentionTrigger'),
                      builder: (context, leafRef, _) {
                        final leafSlashCommands = _mentionTrigger == '/'
                            ? leafRef.watch(appProvider.select((s) => s.slashCommands))
                            : const <SlashCommandItem>[];
                        final leafWorkspaceFiles = _mentionTrigger == '@'
                            ? leafRef.watch(appProvider.select((s) => s.workspaceFiles))
                            : const <WorkspaceFileNode>[];
                        return ValueListenableBuilder<int>(
                          valueListenable: _suggestionTickNotifier,
                          builder: (context, _, __) {
                            final filteredCommands = _mentionTrigger == '/'
                                ? leafSlashCommands
                                    .where((c) =>
                                        _mentionQuery.isEmpty ||
                                        c.command.toLowerCase().contains(_mentionQuery) ||
                                        c.title.toLowerCase().contains(_mentionQuery) ||
                                        c.desc.toLowerCase().contains(_mentionQuery) ||
                                        c.category.toLowerCase().contains(_mentionQuery))
                                    .take(24)
                                    .toList(growable: false)
                                : const <SlashCommandItem>[];
                            final filteredRefs = _mentionTrigger == '@'
                                ? () {
                                    final seen = <String>{};
                                    final candidates = <({Map<String, String> item, int rank})>[];
                                    int rankFor(String path, String label) {
                                      if (_mentionQuery.isEmpty) return 0;
                                      final pLow = path.toLowerCase();
                                      final lLow = label.toLowerCase();
                                      final slash = pLow.lastIndexOf('/');
                                      final base = slash >= 0 ? pLow.substring(slash + 1) : pLow;
                                      if (base.startsWith(_mentionQuery) || lLow.startsWith(_mentionQuery)) {
                                        return 0;
                                      }
                                      if (base.contains(_mentionQuery) || lLow.contains(_mentionQuery)) {
                                        return 1;
                                      }
                                      return 2;
                                    }
                                    for (final r in _remoteRefs) {
                                      final p = r['path'] ?? '';
                                      final lbl = r['label'] ?? '';
                                      final matchesQ = _mentionQuery.isEmpty ||
                                          p.toLowerCase().contains(_mentionQuery) ||
                                          lbl.toLowerCase().contains(_mentionQuery);
                                      if (p.isNotEmpty && matchesQ && seen.add(p)) {
                                        candidates.add((item: r, rank: rankFor(p, lbl)));
                                      }
                                    }
                                    for (final p in _getFlattenedFilePaths(leafWorkspaceFiles)) {
                                      if ((_mentionQuery.isEmpty || p.toLowerCase().contains(_mentionQuery)) &&
                                          seen.add(p)) {
                                        candidates.add((item: {'path': p, 'kind': 'file'}, rank: rankFor(p, '')));
                                      }
                                    }
                                    if (_mentionQuery.isNotEmpty && candidates.length > 1) {
                                      candidates.sort((a, b) => a.rank.compareTo(b.rank));
                                    }
                                    return [
                                      for (var i = 0; i < candidates.length && i < 24; i++)
                                        candidates[i].item,
                                    ];
                                  }()
                                : const <Map<String, String>>[];
                            _latestCommands = filteredCommands;
                            _latestRefs = filteredRefs;
                            return Padding(
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
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(8, 0, 2, 4),
                                        child: Row(
                                          children: [
                                            Text(
                                              _mentionTrigger == '/'
                                                  ? '快捷指令${filteredCommands.isNotEmpty ? ' (${filteredCommands.length})' : ''}'
                                                  : '引用文件与会话${filteredRefs.isNotEmpty ? ' (${filteredRefs.length})' : ''}',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: t.text3,
                                              ),
                                            ),
                                            if (_mentionTrigger == '@' && _loadingRefs) ...[
                                              const SizedBox(width: 7),
                                              GrassBagActivityIndicator(radius: 5.5, color: t.primary),
                                            ],
                                            const Spacer(),
                                            GestureDetector(
                                              behavior: HitTestBehavior.opaque,
                                              onTap: _dismissSuggestions,
                                              child: Padding(
                                                padding: const EdgeInsets.all(4),
                                                child: Icon(
                                                  CupertinoIcons.xmark,
                                                  size: 13,
                                                  color: t.text3,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Flexible(
                                        fit: FlexFit.loose,
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(maxHeight: 220),
                                          child: SingleChildScrollView(
                                            controller: _suggestionScrollCtrl,
                                            physics: const BouncingScrollPhysics(),
                                            child: ValueListenableBuilder<int>(
                                              valueListenable: _activeSuggestionIdxNotifier,
                                              builder: (_, activeSuggestionIdx, __) => Column(
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
                                                            activeSuggestionIdx.clamp(0, filteredCommands.length - 1);
                                                        final isInstant = const {'/new', '/plan', '/status'}.contains(cmd.command) ||
                                                            (!state.isEmptyChat &&
                                                                const {'/fork', '/export'}.contains(cmd.command));
                                                        final isSkill = cmd.command.startsWith('/skill:');
                                                        final subtitle = cmd.desc.trim().isEmpty
                                                            ? cmd.title
                                                            : (cmd.title.trim().isEmpty
                                                                ? cmd.desc
                                                                : '${cmd.title} · ${cmd.desc}');
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
                                                                    color: isSkill ? t.okSoft : t.primarySoft,
                                                                    borderRadius: BorderRadius.circular(7),
                                                                  ),
                                                                  child: Text(
                                                                    cmd.command,
                                                                    style: TextStyle(
                                                                      fontFamily: 'monospace',
                                                                      fontSize: 12,
                                                                      fontWeight: FontWeight.w600,
                                                                      color: isSkill ? t.ok : t.primary,
                                                                    ),
                                                                  ),
                                                                ),
                                                                const SizedBox(width: 9),
                                                                Expanded(
                                                                  child: Text(
                                                                    subtitle,
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
                                                            GrassBagActivityIndicator(radius: 6.5, color: t.primary),
                                                            const SizedBox(width: 8),
                                                            Text(
                                                              '正在搜索工作区文件与引用…',
                                                              style: TextStyle(fontSize: 12, color: t.text3),
                                                            ),
                                                          ] else ...[
                                                            Expanded(
                                                              child: Text(
                                                                state.activeWorkspace.isEmpty
                                                                    ? '暂未选择工作区，选择后可用 @ 引用文件'
                                                                    : '未找到匹配文件，可继续输入路径关键词',
                                                                style: TextStyle(fontSize: 12, color: t.text3),
                                                              ),
                                                            ),
                                                            if (state.activeWorkspace.isEmpty) ...[
                                                              const SizedBox(width: 8),
                                                              GrassBagSpringTap(
                                                                onTap: () {
                                                                  _dismissSuggestions();
                                                                  showWorkspaceSheet(context, ref);
                                                                },
                                                                child: Container(
                                                                  padding: const EdgeInsets.symmetric(
                                                                    horizontal: 9,
                                                                    vertical: 4,
                                                                  ),
                                                                  decoration: BoxDecoration(
                                                                    color: t.primarySoft,
                                                                    borderRadius: BorderRadius.circular(999),
                                                                  ),
                                                                  child: Text(
                                                                    '选择工作区',
                                                                    style: TextStyle(
                                                                      fontSize: 11.5,
                                                                      fontWeight: FontWeight.w600,
                                                                      color: t.primary,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ],
                                                          ],
                                                        ],
                                                      ),
                                                    )
                                                  else
                                                    for (var ri = 0; ri < filteredRefs.length; ri++)
                                                      () {
                                                        final refItem = filteredRefs[ri];
                                                        final active = ri ==
                                                            activeSuggestionIdx.clamp(0, filteredRefs.length - 1);
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
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    )
                  : const SizedBox.shrink(key: ValueKey('suggestions-empty')),
            ),

            // Spring-Animated Floating Liquid Glass '+' Deck directly above composer.
            // Pure GPU scale+translate+fade at fixed layout bounds (NO Align heightFactor thrash
            // and NO ClipRRect shearing outer glass shadows mid-flight!).
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
                          child: SingleChildScrollView(
                            primary: false,
                            child: _PlusDeckContent(
                              onClose: () => _setPlusOpen(false),
                              onOpenTerminal: widget.onOpenTerminal,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  builder: (ctx, staticDeck) {
                    final raw = _plusSpring.value;
                    if (raw <= 0.005 && !_plusOpen) return const SizedBox.shrink();
                    final v = raw.clamp(0.0, 1.0);
                    final scale = (0.92 + 0.08 * raw).clamp(0.88, 1.02);
                    return IgnorePointer(
                      ignoring: !_plusOpen,
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        heightFactor: 1.0,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: FadeTransition(
                            opacity: AlwaysStoppedAnimation<double>(v),
                            child: Transform.translate(
                              offset: Offset(0, (1.0 - v) * 16.0),
                              child: Transform.scale(
                                scale: scale,
                                alignment: Alignment.bottomLeft,
                                child: GrassBagMaterializeScope(
                                  progress: v,
                                  child: staticDeck!,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

            // Persistent Bottom Dock measured as ONE unit (Goal/Todo strip + active mode pills + composer/takeover)
            // so ListView tail spacer, bottom progressive scrim, and toast anchor NEVER overlap chat text!
            _ComposerHeightReporter(
              onHeightChanged: (h) {
                final n = widget.composerHeightNotifier;
                if (n != null && (n.value - h).abs() > 1.0) {
                  n.value = h;
                }
              },
              child: () {
                final dockBody = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Docked live Goal & Todo status strip (isolated leaf Consumer: zero composer churn!)
                  if (!_plusOpen && !hasTakeover) const _LiveGoalTodoStrip(),

                  // Active Status Pills row (shares horizontal row with scroll-to-bottom droplet!)
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.bottomCenter,
                    clipBehavior: Clip.none,
                    child: hasStatusPills
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: GrassBagGlassBarLayer(
                                      tier: state.glassTier,
                                      child: Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        children: [
                                          if (showCompactNudgePill)
                                            GrassBagGlassPillButton(
                                              tier: state.glassTier,
                                              height: 34,
                                              useOwnLayer: false,
                                              padding: const EdgeInsets.only(left: 11, right: 6),
                                              onTap: () => unawaited(ctrl.compactContext()),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    CupertinoIcons.arrow_down_right_arrow_up_left,
                                                    size: 13,
                                                    color: state.contextPctHigh >= 90 ? t.err : t.warn,
                                                  ),
                                                  const SizedBox(width: 5),
                                                  Text(
                                                    '上下文 ${state.contextPctHigh}% · 精简',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w600,
                                                      fontFeatures: const [FontFeature.tabularFigures()],
                                                      color: state.contextPctHigh >= 90 ? t.err : t.warn,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 4),
                                                  GestureDetector(
                                                    behavior: HitTestBehavior.opaque,
                                                    onTap: () => setState(() => _compactNudgeDismissed = true),
                                                    child: Padding(
                                                      padding: const EdgeInsets.all(4),
                                                      child: Icon(CupertinoIcons.xmark, size: 11, color: t.text3),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
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
                                          if (showReadOnlyPill)
                                            GrassBagGlassPillButton(
                                              tier: state.glassTier,
                                              height: 34,
                                              useOwnLayer: false,
                                              padding: const EdgeInsets.symmetric(horizontal: 12),
                                              onTap: () => showPermissionSheet(context, ref),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(CupertinoIcons.lock_shield_fill,
                                                      size: 13.5, color: t.text2),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    perm.name,
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w600,
                                                      color: t.text2,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 2),
                                                  Icon(CupertinoIcons.chevron_right, size: 12, color: t.text3),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                scrollDropletWidget(inlineWithPills: true),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),

                  // Smooth Transition between Elevated Liquid Glass Approval Card & Floating Composer.
                  // Deliberately avoid wrapping `composer-pill` in `AnimatedSize` so multi-line text
                  // wrapping performs ONE layout pass instead of 24 consecutive `toImageSync` frames!
                  AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.linear,
                switchOutCurve: Curves.linear,
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                ),
                transitionBuilder: (child, anim) => _ComposerSlideMaterialize(
                  animation: anim,
                  tier: state.glassTier,
                  beginOffset: const Offset(0, 0.05),
                  scaleFrom: 0.96,
                  contentSigma: 4.5,
                  child: child,
                ),
                child: showApproval
                  ? _ApprovalTakeoverCard(
                      key: ValueKey('approval-${state.pendingApprovalInteractionId ?? 'none'}'),
                      command: state.pendingApprovalCommand!,
                      toolName: state.pendingApprovalToolName,
                      workspaceName: state.activeWorkspace,
                      isDirectMode: state.hostDirectMode,
                      pendingCount: state.activePendingInteractionCount,
                      maxHeight: takeoverMaxH,
                      tier: state.glassTier,
                      onDecision: ctrl.resolveApproval,
                    )
                  : showQuestion
                      ? _UserQuestionTakeoverCard(
                          key: ValueKey('question-${state.activeQuestion!.interactionId}'),
                          question: state.activeQuestion!,
                          pendingCount: state.activePendingInteractionCount,
                          maxHeight: takeoverMaxH,
                          tier: state.glassTier,
                          onSubmit: ctrl.resolveUserQuestion,
                          onCancel: () => unawaited(ctrl.skipUserQuestion()),
                        )
                      : showCordis
                          ? _CordisRunTakeoverCard(
                              key: ValueKey('cordis-${state.activeCordisRequest!.interactionId}'),
                              request: state.activeCordisRequest!,
                              pendingCount: state.activePendingInteractionCount,
                              maxHeight: takeoverMaxH,
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
                                  if (widget.editingContextNotifier != null)
                                    ValueListenableBuilder<EditingMessageContext?>(
                                      valueListenable: widget.editingContextNotifier!,
                                      builder: (_, editCtx, __) {
                                        if (editCtx == null) return const SizedBox.shrink();
                                        return Padding(
                                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 6,
                                            ),
                                            decoration: BoxDecoration(
                                              color: t.primarySoft,
                                              borderRadius: BorderRadius.circular(12),
                                              border: Border.all(
                                                color: t.primary.withValues(alpha: 0.25),
                                                width: 0.6,
                                              ),
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  CupertinoIcons.pencil,
                                                  size: 13,
                                                  color: t.primary,
                                                ),
                                                const SizedBox(width: 6),
                                                Expanded(
                                                  child: Text(
                                                    '正在编辑：${editCtx.originalText.replaceAll('\n', ' ')}',
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 11.5,
                                                      fontWeight: FontWeight.w500,
                                                      color: t.primary,
                                                    ),
                                                  ),
                                                ),
                                                if (editCtx.canForkBefore) ...[
                                                  const SizedBox(width: 6),
                                                  GestureDetector(
                                                    behavior: HitTestBehavior.opaque,
                                                    onTap: () {
                                                      HapticFeedback.selectionClick();
                                                      setState(() => _editBranchResend = !_editBranchResend);
                                                    },
                                                    child: Container(
                                                      padding: const EdgeInsets.symmetric(
                                                        horizontal: 7,
                                                        vertical: 2.5,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: _editBranchResend
                                                            ? t.primary.withValues(alpha: 0.16)
                                                            : t.fill1,
                                                        borderRadius: BorderRadius.circular(999),
                                                      ),
                                                      child: Text(
                                                        _editBranchResend ? '分支重发' : '末尾重发',
                                                        style: TextStyle(
                                                          fontSize: 10.5,
                                                          fontWeight: FontWeight.w600,
                                                          color: _editBranchResend ? t.primary : t.text3,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                                const SizedBox(width: 4),
                                                GestureDetector(
                                                  behavior: HitTestBehavior.opaque,
                                                  onTap: _cancelEditingMessage,
                                                  child: SizedBox(
                                                    width: 24,
                                                    height: 24,
                                                    child: Center(
                                                      child: Icon(
                                                        CupertinoIcons.xmark,
                                                        size: 13,
                                                        color: t.primary,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  // Avoid inner AnimatedSize inside `composer-pill` GrassBagGlass so attaching/removing
                                  // files or popping queued messages never triggers 20 consecutive toImageSync GPU stalls!
                                  if (state.pendingAttachments.isNotEmpty)
                                    SizedBox(
                                            height: state.pendingAttachments.any(
                                              (a) => a.isImage && a.bytes != null && a.bytes!.isNotEmpty,
                                            )
                                                ? 62
                                                : 38,
                                            child: ListView.separated(
                                              scrollDirection: Axis.horizontal,
                                              padding: const EdgeInsets.fromLTRB(6, 9, 10, 4),
                                              itemCount: state.pendingAttachments.length,
                                              separatorBuilder: (_, __) => const SizedBox(width: 8),
                                              itemBuilder: (_, idx) {
                                                final att = state.pendingAttachments[idx];
                                                final hasImgBytes =
                                                    att.isImage && att.bytes != null && att.bytes!.isNotEmpty;
                                                if (hasImgBytes) {
                                                  // Keep the 28x28 remove badge 100% INSIDE the 52x52
                                                  // Stack hit-test bounds so the entire badge is tappable!
                                                  return SizedBox(
                                                    width: 52,
                                                    height: 52,
                                                    child: Stack(
                                                      children: [
                                                        Positioned(
                                                          left: 0,
                                                          bottom: 0,
                                                          child: GestureDetector(
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
                                                        ),
                                                        Positioned(
                                                          top: 0,
                                                          right: 0,
                                                          child: GestureDetector(
                                                            behavior: HitTestBehavior.opaque,
                                                            onTap: () {
                                                              HapticFeedback.selectionClick();
                                                              ctrl.removePendingAttachment(att.id);
                                                            },
                                                            child: SizedBox(
                                                              width: 28,
                                                              height: 28,
                                                              child: Align(
                                                                alignment: Alignment.topRight,
                                                                child: Container(
                                                                  width: 19,
                                                                  height: 19,
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
                                                                    size: 10.5,
                                                                    color: t.text,
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                }
                                                return Center(
                                                  child: GestureDetector(
                                                    onTap: () {
                                                      HapticFeedback.selectionClick();
                                                      ctrl.showToast(
                                                        att.sizeBytes > 0
                                                            ? '${att.name} (${att.humanSize})'
                                                            : att.name,
                                                        tone: ToastTone.info,
                                                      );
                                                    },
                                                    child: Container(
                                                      height: 28,
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
                                                            constraints: const BoxConstraints(maxWidth: 132),
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
                                                          if (att.sizeBytes > 0) ...[
                                                            const SizedBox(width: 4),
                                                            Text(
                                                              att.humanSize,
                                                              style: TextStyle(
                                                                fontSize: 10,
                                                                fontFeatures: const [FontFeature.tabularFigures()],
                                                                color: t.primary.withValues(alpha: 0.72),
                                                              ),
                                                            ),
                                                          ],
                                                          GestureDetector(
                                                            behavior: HitTestBehavior.opaque,
                                                            onTap: () {
                                                              HapticFeedback.selectionClick();
                                                              ctrl.removePendingAttachment(att.id);
                                                            },
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
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                  if (state.queuedMessages.isNotEmpty)
                                    Padding(
                                            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                              decoration: BoxDecoration(
                                                color: t.fill1,
                                                borderRadius: BorderRadius.circular(14),
                                                border: Border.all(color: t.sep, width: 0.5),
                                              ),
                                              child: ConstrainedBox(
                                                constraints: const BoxConstraints(maxHeight: 112),
                                                child: SingleChildScrollView(
                                                  physics: const BouncingScrollPhysics(),
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                                    mainAxisSize: MainAxisSize.min,
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
                                                                child: GestureDetector(
                                                                  behavior: HitTestBehavior.opaque,
                                                                  onTap: () {
                                                                    HapticFeedback.selectionClick();
                                                                    _showEditQueuedDialog(context, q);
                                                                  },
                                                                  child: Text(
                                                                    q.text,
                                                                    maxLines: 1,
                                                                    overflow: TextOverflow.ellipsis,
                                                                    style: TextStyle(fontSize: 12.5, color: t.text),
                                                                  ),
                                                                ),
                                                              ),
                                                              GestureDetector(
                                                                behavior: HitTestBehavior.opaque,
                                                                onTap: () {
                                                                  HapticFeedback.selectionClick();
                                                                  _showEditQueuedDialog(context, q);
                                                                },
                                                                child: SizedBox(
                                                                  width: 30,
                                                                  height: 30,
                                                                  child: Center(
                                                                    child: Icon(CupertinoIcons.pencil, size: 13, color: t.text3),
                                                                  ),
                                                                ),
                                                              ),
                                                              if (q.mode != 'steer')
                                                                GestureDetector(
                                                                  behavior: HitTestBehavior.opaque,
                                                                  onTap: () {
                                                                    HapticFeedback.selectionClick();
                                                                    ctrl.promoteQueuedMessage(q.id);
                                                                  },
                                                                  child: Padding(
                                                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                                                    child: Text(
                                                                      '改插话',
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
                                                                onTap: () {
                                                                  HapticFeedback.selectionClick();
                                                                  ctrl.removeQueuedMessage(q.id);
                                                                },
                                                                child: SizedBox(
                                                                  width: 30,
                                                                  height: 30,
                                                                  child: Center(
                                                                    child: Icon(CupertinoIcons.xmark, size: 13.5, color: t.text3),
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
                                  RepaintBoundary(
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.translucent,
                                      onTap: () {
                                        if (!widget.focusNode.hasFocus) {
                                          widget.focusNode.requestFocus();
                                        }
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment: CrossAxisAlignment.stretch,
                                          children: [
                                            TextField(
                                              controller: widget.controller,
                                              focusNode: widget.focusNode,
                                              minLines: 1,
                                              maxLines: effectiveTextMaxLines,
                                              keyboardType: TextInputType.multiline,
                                              // Mobile uses TextInputAction.newline (matching ChatGPT/Claude) so users
                                              // can freely compose multi-line prompts without dismissing the soft IME;
                                              // desktop/hardware keyboards send on Enter / Cmd+Enter.
                                              textInputAction: TextInputAction.newline,
                                              // Empty onEditingComplete prevents Flutter's default unfocus() on IME actions,
                                              // keeping the Android/iOS soft keyboard smoothly open across messages!
                                              onEditingComplete: () {},
                                              onSubmitted: null,
                                              contextMenuBuilder: buildGrassBagEditableContextMenu,
                                              contentInsertionConfiguration:
                                                  ContentInsertionConfiguration(
                                                allowedMimeTypes: const <String>[
                                                  'image/png',
                                                  'image/jpeg',
                                                  'image/webp',
                                                  'image/gif',
                                                ],
                                                onContentInserted: (KeyboardInsertedContent data) {
                                                  final bytes = data.data;
                                                  if (bytes == null || bytes.isEmpty) return;
                                                  final mime = data.mimeType.isNotEmpty
                                                      ? data.mimeType
                                                      : 'image/png';
                                                  final ext = switch (mime.toLowerCase()) {
                                                    'image/jpeg' => 'jpg',
                                                    'image/webp' => 'webp',
                                                    'image/gif' => 'gif',
                                                    _ => 'png',
                                                  };
                                                  final ts =
                                                      DateTime.now().millisecondsSinceEpoch;
                                                  HapticFeedback.selectionClick();
                                                  ctrl.addPendingAttachment(
                                                    ComposerAttachment(
                                                      id: 'paste-$ts',
                                                      name: 'pasted_$ts.$ext',
                                                      mimeType: mime,
                                                      sizeBytes: bytes.length,
                                                      bytes: bytes,
                                                    ),
                                                  );
                                                  ctrl.showToast('已粘贴图片附件',
                                                      tone: ToastTone.info);
                                                },
                                              ),
                                              style: TextStyle(
                                                fontSize: 15,
                                                height: 1.4,
                                                letterSpacing: -0.15,
                                                color: t.text,
                                              ),
                                              decoration: InputDecoration(
                                                hintText: state.isStopping
                                                    ? '正在停止当前生成…'
                                                    : (isHostNeedsAuth
                                                        ? '远程主机待授权，点击完成授权后即可对话…'
                                                        : (needsModelConfig
                                                            ? '先登录 DeepSeek 或添加 API Key 后即可开始对话…'
                                                            : (state.pendingAttachments.isNotEmpty
                                                                ? '添加说明，或直接发送附件…'
                                                                : (state.isStreaming
                                                                    ? (state.busyEnterMode == 'steer'
                                                                        ? '正在生成中，输入内容可直接插话…'
                                                                        : '正在生成中，输入内容可排队发送…')
                                                                    : (state.planMode
                                                                        ? '计划模式：先出执行方案，确认后再动手…'
                                                                        : (isDesktopPlatform
                                                                            ? '给 GrassBag 发消息…（Enter 发送 · Shift+Enter 换行）'
                                                                            : '给 GrassBag 发消息…')))))),
                                                hintStyle: TextStyle(
                                                  fontSize: 15,
                                                  letterSpacing: -0.15,
                                                  color: t.isDark
                                                      ? t.text2.withValues(alpha: 0.68)
                                                      : t.text3,
                                                ),
                                                isDense: true,
                                                contentPadding:
                                                    const EdgeInsets.symmetric(vertical: 6),
                                                border: InputBorder.none,
                                              ),
                                            ),
                                            ValueListenableBuilder<TextEditingValue>(
                                              valueListenable: widget.controller,
                                              builder: (ctx, val, _) {
                                                final len = val.text.length;
                                                if (len < 2000) return const SizedBox.shrink();
                                                final warn = len >= 8000;
                                                return Padding(
                                                  padding: const EdgeInsets.only(top: 2),
                                                  child: Align(
                                                    alignment: Alignment.centerRight,
                                                    child: Text(
                                                      '$len 字',
                                                      style: TextStyle(
                                                        fontSize: 10.5,
                                                        fontWeight: FontWeight.w500,
                                                        fontFeatures: const [
                                                          FontFeature.tabularFigures(),
                                                        ],
                                                        color: warn ? t.warn : t.text3,
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                          LayoutBuilder(
                            builder: (ctx, rowBox) {
                              final hasExtraStreamActions = state.isStreaming && hasText;
                              final veryTightRow = rowBox.maxWidth < 240;
                              final tightRow = rowBox.maxWidth < (hasExtraStreamActions ? 364 : 316);
                              final showInlineRing =
                                  !veryTightRow && !(tightRow && hasExtraStreamActions);
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
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: _plusOpen
                                          ? (t.isDark
                                              ? [
                                                  t.primary.withValues(alpha: 0.34),
                                                  t.primary.withValues(alpha: 0.20),
                                                ]
                                              : [
                                                  Color.lerp(Colors.white, t.primary, 0.14)!
                                                      .withValues(alpha: 0.88),
                                                  Color.lerp(Colors.white, t.primary, 0.22)!
                                                      .withValues(alpha: 0.72),
                                                ])
                                          : (t.isDark
                                              ? [
                                                  Colors.white.withValues(alpha: 0.16),
                                                  Colors.white.withValues(alpha: 0.08),
                                                ]
                                              : [
                                                  Colors.white.withValues(alpha: 0.80),
                                                  Colors.white.withValues(alpha: 0.54),
                                                ]),
                                    ),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: _plusOpen
                                          ? t.primary.withValues(alpha: t.isDark ? 0.42 : 0.28)
                                          : (t.isDark
                                              ? Colors.white.withValues(alpha: 0.14)
                                              : const Color(0x16162E42)),
                                      width: 0.6,
                                    ),
                                    boxShadow: t.isDark
                                        ? null
                                        : const [
                                            BoxShadow(
                                              color: Color(0x0B000000),
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
                                      } else if (!hasCachedModelWhileReconnecting &&
                                          (isHostConnecting || isHydratingModels)) {
                                        pillIcon = CupertinoIcons.sparkles;
                                        pillIconColor = t.text3;
                                        pillLabel = isHydratingModels
                                            ? '同步中…'
                                            : (state.connectionPhase == ConnectionPhase.reconnecting
                                                ? '重连中…'
                                                : '连接中…');
                                        effortBadge = null;
                                        pillTextColor = t.text3;
                                        pillTap = () => showHostQuickSheet(
                                              context,
                                              ref,
                                              onOpenHostSettings: widget.onOpenHostSettings,
                                            );
                                      } else if (!isHostConnected && !hasCachedModelWhileReconnecting) {
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
                                      } else if (needsModelConfig ||
                                          (!state.hasAvailableModels && state.activeModelId.isEmpty)) {
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
                                        pillLabel = state.activeModelId.isNotEmpty
                                            ? state.modelShort
                                            : (state.fallbackModelShort.isNotEmpty
                                                ? state.fallbackModelShort
                                                : state.modelShort);
                                        final resolvedEffort = state.modelEffort.isNotEmpty
                                            ? state.modelEffort
                                            : state.fallbackModelEffort;
                                        effortBadge = resolvedEffort.isNotEmpty
                                            ? resolvedEffort
                                            : null;
                                        pillTextColor = t.text;
                                        pillTap = () => showModelSheet(
                                              context,
                                              ref,
                                              onOpenModelSettings: widget.onOpenModelSettings,
                                            );
                                      }
                                      return GrassBagSpringTap(
                                        onTap: () {
                                          if (_plusOpen) _setPlusOpen(false);
                                          pillTap();
                                        },
                                        pressedScale: 0.94,
                                        haptic: true,
                                        child: Container(
                                          height: 36,
                                          padding: EdgeInsets.symmetric(horizontal: tightRow ? 9 : 11),
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: t.isDark
                                                  ? [
                                                      Colors.white.withValues(alpha: 0.15),
                                                      Colors.white.withValues(alpha: 0.08),
                                                    ]
                                                  : [
                                                      Colors.white.withValues(alpha: 0.80),
                                                      Colors.white.withValues(alpha: 0.54),
                                                    ],
                                            ),
                                            borderRadius: BorderRadius.circular(999),
                                            border: Border.all(
                                              color: t.isDark
                                                  ? Colors.white.withValues(alpha: 0.14)
                                                  : const Color(0x16162E42),
                                              width: 0.6,
                                            ),
                                            boxShadow: t.isDark
                                                ? null
                                                : const [
                                                    BoxShadow(
                                                      color: Color(0x0B000000),
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
                                              if (effortBadge != null &&
                                                  !veryTightRow &&
                                                  !(tightRow && hasExtraStreamActions)) ...[
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
                                  autoAdjustToScreen: true,
                                  opaqueColor: state.glassTier == GrassBagGlassTier.solid
                                      ? t.cardSolid
                                      : null,
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
                                            state.busyEnterMode == 'steer' ? '插话' : '排队',
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
                                      title: state.busyEnterMode == 'steer'
                                          ? '插话 · 引导当前任务（默认）'
                                          : '插话 · 引导当前任务',
                                      icon: const Icon(CupertinoIcons.arrow_turn_down_right),
                                      onTap: () => _submit(mode: 'steer'),
                                    ),
                                    GlassMenuItem(
                                      title: state.busyEnterMode != 'steer'
                                          ? '排队 · 本轮结束后发（默认）'
                                          : '排队 · 本轮结束后发',
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
                              if (showInlineRing)
                                _ComposerContextRingButton(
                                  onBeforeOpen: () {
                                    if (_plusOpen) _setPlusOpen(false);
                                  },
                                ),

                              // Compact Stop orb remains accessible when streaming AND drafting follow-up text!
                              if (state.isStreaming && hasText) ...[
                                Tooltip(
                                  message: state.isStopping ? '正在停止生成…' : '停止当前生成',
                                  child: GrassBagSpringTap(
                                    enabled: !state.isStopping,
                                    onTap: () {
                                      if (state.isStopping) return;
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
                                      child: state.isStopping
                                          ? Center(
                                              child: CupertinoActivityIndicator(
                                                radius: 6.5,
                                                color: t.err,
                                              ),
                                            )
                                          : Icon(
                                              CupertinoIcons.stop_fill,
                                              size: 13.5,
                                              color: t.err,
                                            ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],

                              // Concentric Action Orb (Send / Steer / Queue / Stop / Mic when speech is configured)
                              () {
                                final isStopOrb = state.isStreaming && !hasText;
                                final isFollowUpSend = state.isStreaming && hasText;
                                final showPrimarySpinner = _submitting && !isStopOrb;
                                final orbEnabled = isStopOrb ? !state.isStopping : !_submitting;
                                final primaryActive = hasText || showPrimarySpinner;
                                final sendIcon = isFollowUpSend
                                    ? (state.busyEnterMode == 'steer'
                                        ? CupertinoIcons.arrow_turn_down_right
                                        : CupertinoIcons.clock_fill)
                                    : CupertinoIcons.arrow_up;
                                final orbTooltip = isStopOrb
                                    ? (state.isStopping ? '正在停止生成…' : '停止生成')
                                    : (isFollowUpSend
                                        ? (state.busyEnterMode == 'steer' ? '插话发送' : '排队发送')
                                        : (hasText
                                            ? '发送消息'
                                            : (state.speechConfigured ? '语音输入' : '发送消息')));
                                return Tooltip(
                                  message: orbTooltip,
                                  child: GrassBagSpringTap(
                                    key: const ValueKey('composer-action-btn'),
                                    enabled: orbEnabled,
                                    pressedScale:
                                        (hasText || state.isStreaming || state.speechConfigured)
                                            ? 0.86
                                            : 1.0,
                                    onTap: () {
                                      if (isStopOrb) {
                                        if (state.isStopping) return;
                                        HapticFeedback.lightImpact();
                                        ctrl.cancelStreaming();
                                      } else if (_submitting) {
                                        return;
                                      } else if (hasText) {
                                        _submit();
                                      } else if (state.speechConfigured) {
                                        HapticFeedback.selectionClick();
                                        showVoiceInputSheet(
                                          context,
                                          ref,
                                          onTranscriptConfirmed: (text) {
                                            final val = widget.controller.value;
                                            final cur = val.text;
                                            final sel = val.selection;
                                            final start = sel.isValid
                                                ? sel.start.clamp(0, cur.length)
                                                : cur.length;
                                            final end = sel.isValid
                                                ? sel.end.clamp(start, cur.length)
                                                : cur.length;
                                            final needsLeadSpace = start > 0 &&
                                                cur.codeUnitAt(start - 1) != 0x20 &&
                                                cur.codeUnitAt(start - 1) != 0x0A;
                                            final insert = needsLeadSpace ? ' $text' : text;
                                            final updated = cur.replaceRange(start, end, insert);
                                            widget.controller.value = TextEditingValue(
                                              text: updated,
                                              selection: TextSelection.collapsed(
                                                offset: start + insert.length,
                                              ),
                                            );
                                            WidgetsBinding.instance.addPostFrameCallback((_) {
                                              if (mounted) widget.focusNode.requestFocus();
                                            });
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
                                        // Always provide a 2-stop LinearGradient so BoxDecoration.lerp
                                        // interpolates Send <-> Stop <-> Mic smoothly instead of snapping at t=0.5!
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: primaryActive
                                              ? [t.primaryHi, t.primary]
                                              : () {
                                                  final flat = isStopOrb
                                                      ? t.errSoft
                                                      : Colors.white.withValues(
                                                          alpha: t.isDark ? 0.11 : 0.62,
                                                        );
                                                  return [flat, flat];
                                                }(),
                                        ),
                                        shape: BoxShape.circle,
                                        border: primaryActive
                                            ? Border.all(
                                                color: Colors.white.withValues(alpha: 0.28),
                                                width: 0.6,
                                              )
                                            : Border.all(
                                                color: isStopOrb
                                                    ? t.err.withValues(alpha: 0.30)
                                                    : Colors.white.withValues(
                                                        alpha: t.isDark ? 0.18 : 0.90,
                                                      ),
                                                width: 0.65,
                                              ),
                                        boxShadow: primaryActive
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
                                            scale: Tween<double>(begin: 0.72, end: 1.0)
                                                .animate(anim),
                                            child: child,
                                          ),
                                        ),
                                        child: showPrimarySpinner
                                            ? CupertinoActivityIndicator(
                                                key: const ValueKey('sending'),
                                                radius: 7.5,
                                                color: t.onPrimary,
                                              )
                                            : (isStopOrb && state.isStopping)
                                                ? CupertinoActivityIndicator(
                                                    key: const ValueKey('stopping'),
                                                    radius: 7.0,
                                                    color: t.err,
                                                  )
                                                : Icon(
                                                    hasText
                                                        ? sendIcon
                                                        : isStopOrb
                                                            ? CupertinoIcons.stop_fill
                                                            : (state.speechConfigured
                                                                ? CupertinoIcons.mic_fill
                                                                : CupertinoIcons.arrow_up),
                                                    key: ValueKey(
                                                      hasText
                                                          ? (isFollowUpSend
                                                              ? 'send-${state.busyEnterMode}'
                                                              : 'send')
                                                          : (isStopOrb
                                                              ? 'stop'
                                                              : (state.speechConfigured
                                                                  ? 'mic'
                                                                  : 'send')),
                                                    ),
                                                    size: hasText
                                                        ? (isFollowUpSend ? 15.5 : 17)
                                                        : (isStopOrb ? 14 : 16.5),
                                                    color: hasText
                                                        ? t.onPrimary
                                                        : isStopOrb
                                                            ? t.err
                                                            : (state.speechConfigured
                                                                ? t.text
                                                                : t.text3),
                                                  ),
                                      ),
                                    ),
                                  ),
                                );
                              }(),
                            ],
                          );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
                if (isTightDock) {
                  return ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: math.max(80.0, maxDockH)),
                    child: SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      child: dockBody,
                    ),
                  );
                }
                return dockBody;
              }(),
            ),
          ],
        );
          },
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
            Text(
              title,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: t.text,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                trailingText,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: warnTrailing ? FontWeight.w600 : FontWeight.w400,
                  color: warnTrailing ? t.warn : t.text3,
                ),
              ),
            ),
            const SizedBox(width: 5),
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
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.lightImpact();
              ctrl.setPlanMode(!slice.planMode);
            },
            child: Padding(
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
                    onChanged: ctrl.setPlanMode,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalTakeoverCard extends StatefulWidget {
  const _ApprovalTakeoverCard({
    super.key,
    required this.command,
    required this.toolName,
    required this.workspaceName,
    required this.isDirectMode,
    this.pendingCount = 1,
    this.maxHeight = 560.0,
    required this.tier,
    required this.onDecision,
  });

  final String command;
  final String? toolName;
  final String workspaceName;
  final bool isDirectMode;
  final int pendingCount;
  final double maxHeight;
  final GrassBagGlassTier tier;
  final Future<bool> Function(String) onDecision;

  @override
  State<_ApprovalTakeoverCard> createState() => _ApprovalTakeoverCardState();
}

class _ApprovalTakeoverCardState extends State<_ApprovalTakeoverCard> {
  late final DateTime _mountedAt = DateTime.now();
  bool _decided = false;

  Future<void> _handleTap(String action) async {
    if (_decided) return;
    // Brief 260ms arming window on ALL actions (including deny!) prevents accidental taps
    // when an approval card slides up over the bottom composer buttons!
    if (DateTime.now().difference(_mountedAt).inMilliseconds < 260) {
      return;
    }
    setState(() => _decided = true);
    final ok = await widget.onDecision(action);
    if (!ok && mounted) {
      setState(() => _decided = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final rawTool = (widget.toolName ?? '').trim();
    final lowerTool = rawTool.toLowerCase();
    final isPhoneTool = lowerTool.startsWith('phone_') ||
        widget.command.trimLeft().toLowerCase().startsWith('phone_');
    final isFileTool = lowerTool.contains('file') ||
        lowerTool.contains('write') ||
        lowerTool.contains('edit') ||
        lowerTool.contains('patch') ||
        lowerTool.contains('delete');
    final isCmdTool = lowerTool.isEmpty ||
        lowerTool.contains('bash') ||
        lowerTool.contains('shell') ||
        lowerTool.contains('cmd') ||
        lowerTool.contains('exec') ||
        lowerTool.contains('terminal');
    final headerTitle = isPhoneTool
        ? '请求操控手机'
        : (isFileTool
            ? '请求修改文件'
            : (isCmdTool ? '请求执行命令' : '请求调用工具'));
    final showAllowSession = !isPhoneTool && !widget.isDirectMode;
    final maxCardH = widget.maxHeight;

    return GlassBackdropGroup(
      enabled: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxCardH),
        child: GrassBagGlass(
          tier: widget.tier,
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
                    icon: isPhoneTool
                        ? CupertinoIcons.device_phone_portrait
                        : (isFileTool
                            ? CupertinoIcons.doc_text_fill
                            : CupertinoIcons.shield_lefthalf_fill),
                    color: isPhoneTool ? t.primary : t.warn,
                    size: 36,
                    iconSize: 18,
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
                                headerTitle,
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
                            if (rawTool.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: t.fill1,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  rawTool,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: t.text2,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        Text(
                          isPhoneTool
                              ? '无障碍操控确认 · 可在手机操控设置中调整策略'
                              : '工作区：${widget.workspaceName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: t.text3),
                        ),
                      ],
                    ),
                  ),
                  if (widget.pendingCount > 1) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 3),
                      decoration: BoxDecoration(
                        color: t.warnSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '待确认 1/${widget.pendingCount}',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: t.warn,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: Container(
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
                      widget.command,
                      contextMenuBuilder: buildGrassBagEditableContextMenu,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.45,
                        color: t.codeFg,
                      ),
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
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tier: widget.tier,
                      insideGlass: true,
                      destructive: true,
                      enabled: !_decided,
                      onTap: () => unawaited(_handleTap('deny')),
                    ),
                  ),
                  if (showAllowSession) ...[
                    const SizedBox(width: 6),
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: '本会话允许',
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        tier: widget.tier,
                        insideGlass: true,
                        enabled: !_decided,
                        onTap: () => unawaited(_handleTap('always')),
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  Expanded(
                    child: GrassBagPrimaryGlassButton(
                      label: _decided ? '处理中…' : '允许一次',
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tier: widget.tier,
                      insideGlass: true,
                      enabled: !_decided,
                      onTap: () => unawaited(_handleTap('allow')),
                    ),
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

class _UserQuestionTakeoverCard extends StatefulWidget {
  const _UserQuestionTakeoverCard({
    super.key,
    required this.question,
    this.pendingCount = 1,
    this.maxHeight = 560.0,
    required this.tier,
    required this.onSubmit,
    required this.onCancel,
  });

  final ActiveUserQuestion question;
  final int pendingCount;
  final double maxHeight;
  final GrassBagGlassTier tier;
  final Future<bool> Function(Object) onSubmit;
  final VoidCallback onCancel;

  @override
  State<_UserQuestionTakeoverCard> createState() => _UserQuestionTakeoverCardState();
}

class _UserQuestionTakeoverCardState extends State<_UserQuestionTakeoverCard> {
  final Map<String, Set<String>> _selectedById = {};
  final Map<String, TextEditingController> _customCtrls = {};
  final ValueNotifier<int> _answerVersion = ValueNotifier<int>(0);
  late final DateTime _mountedAt = DateTime.now();
  bool _submitting = false;

  void _handleSkip() {
    if (_submitting) return;
    if (DateTime.now().difference(_mountedAt).inMilliseconds < 260) {
      return;
    }
    setState(() => _submitting = true);
    widget.onCancel();
  }

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

  bool get _canSubmit => _items.isNotEmpty && _unansweredCount == 0 && !_submitting;

  Future<void> _confirm() async {
    if (!_canSubmit) return;
    setState(() => _submitting = true);
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
    final ok = await widget.onSubmit({'answers': answers});
    if (mounted && !ok) {
      setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final items = _items;
    final multiQ = items.length > 1;
    return GlassBackdropGroup(
      enabled: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
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
                    child: Text(
                      multiQ ? '${widget.question.title}（共 ${items.length} 题）' : widget.question.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.text),
                    ),
                  ),
                  if (widget.pendingCount > 1) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 3),
                      decoration: BoxDecoration(
                        color: t.primarySoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '待确认 1/${widget.pendingCount}',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: t.primary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 11),
              Flexible(
                child: RepaintBoundary(
                  child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!multiQ && (widget.question.prompt.isNotEmpty || (items.isNotEmpty && items.first.multiSelect))) ...[
                    Text(
                      '${widget.question.prompt}${items.isNotEmpty && items.first.multiSelect ? (widget.question.prompt.isNotEmpty ? '（可多选）' : '可多选') : ''}',
                      style: TextStyle(fontSize: 13, height: 1.48, color: t.text2),
                    ),
                    const SizedBox(height: 10),
                  ],
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
                              textInputAction: TextInputAction.done,
                              onChanged: (_) => _answerVersion.value++,
                              onSubmitted: (_) {
                                if (_canSubmit) _confirm();
                              },
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
                label: '跳过',
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                tier: widget.tier,
                insideGlass: true,
                enabled: !_submitting,
                onTap: _handleSkip,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ValueListenableBuilder<int>(
                  valueListenable: _answerVersion,
                  builder: (_, __, ___) => GrassBagPrimaryGlassButton(
                    label: _submitting
                        ? '正在提交…'
                        : (_canSubmit
                            ? '提交选择'
                            : (multiQ ? '还有 $_unansweredCount 题未完成' : '请先完成以上选择或输入')),
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
    ),
    );
  }
}

class _CordisRunTakeoverCard extends StatefulWidget {
  const _CordisRunTakeoverCard({
    super.key,
    required this.request,
    this.pendingCount = 1,
    this.maxHeight = 560.0,
    required this.tier,
    required this.onDecision,
  });

  final ActiveCordisRunRequest request;
  final int pendingCount;
  final double maxHeight;
  final GrassBagGlassTier tier;
  final Future<bool> Function(bool) onDecision;

  @override
  State<_CordisRunTakeoverCard> createState() => _CordisRunTakeoverCardState();
}

class _CordisRunTakeoverCardState extends State<_CordisRunTakeoverCard> {
  late final DateTime _mountedAt = DateTime.now();
  bool _decided = false;

  Future<void> _handleTap(bool allow) async {
    if (_decided) return;
    if (DateTime.now().difference(_mountedAt).inMilliseconds < 260) {
      return;
    }
    setState(() => _decided = true);
    final ok = await widget.onDecision(allow);
    if (!ok && mounted) {
      setState(() => _decided = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final request = widget.request;
    return GlassBackdropGroup(
      enabled: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
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
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: t.text3),
                        ),
                      ],
                    ),
                  ),
                  if (widget.pendingCount > 1) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 3),
                      decoration: BoxDecoration(
                        color: t.fill1,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '待确认 1/${widget.pendingCount}',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: t.dusk,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (request.codePreview.isNotEmpty) ...[
                const SizedBox(height: 10),
                Flexible(
                  child: ClipRSuperellipse(
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
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: GrassBagSecondaryGlassButton(
                      label: '拒绝加载',
                      height: 40,
                      tier: widget.tier,
                      insideGlass: true,
                      destructive: true,
                      enabled: !_decided,
                      onTap: () => unawaited(_handleTap(false)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GrassBagPrimaryGlassButton(
                      label: _decided ? '处理中…' : '允许运行',
                      height: 40,
                      tier: widget.tier,
                      insideGlass: true,
                      enabled: !_decided,
                      onTap: () => unawaited(_handleTap(true)),
                    ),
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

/// Isolated context-pressure ring button so `contextPct` ticks during streaming
/// repaint ONLY this 19×19 ring inside a `RepaintBoundary` and NEVER rebuild `ChatComposerDock`!
class _ComposerContextRingButton extends ConsumerWidget {
  const _ComposerContextRingButton({this.onBeforeOpen});

  final VoidCallback? onBeforeOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          isEmptyChat: s.isEmptyChat,
          contextPct: s.contextPct,
          hasAnyData: s.sessionTelemetry.hasAnyData,
        ),
      ),
    );
    if (slice.isEmptyChat || (slice.contextPct <= 0 && !slice.hasAnyData)) {
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
            onTap: () {
              onBeforeOpen?.call();
              showContextSheet(context, ref);
            },
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
                  if (pctInt <= 0)
                    Icon(
                      CupertinoIcons.chart_pie,
                      size: 15,
                      color: t.primary.withValues(alpha: 0.85),
                    )
                  else
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

/// Isolated compact Liquid Glass Goal / Live Todo status banner docked cleanly
/// above the composer whenever the active session has an active Goal or live Todos.
class _LiveGoalTodoStrip extends ConsumerWidget {
  const _LiveGoalTodoStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          isEmptyChat: s.isEmptyChat,
          goals: s.goals,
          todos: s.todos,
          glassTier: s.glassTier,
        ),
      ),
    );
    if (slice.isEmptyChat) return const SizedBox.shrink();
    final activeGoal = slice.goals.where((g) => !g.isCompleted).firstOrNull;
    final todos = slice.todos;
    if (activeGoal == null && todos.isEmpty) return const SizedBox.shrink();

    final t = GrassBagTokens.of(context);
    final ctrl = ref.read(appProvider.notifier);
    final doneCount = todos.where((e) => e.done).length;
    final activeTodo = todos.where((e) => e.active && !e.done).firstOrNull;

    void openQuickSheet() {
      showGrassBagSheet<void>(
        context,
        title: activeGoal != null ? '长期目标与待办' : '当前任务待办',
        subtitle: activeGoal != null
            ? activeGoal.statusLabel
            : '已完成 $doneCount / ${todos.length}',
        bodyBuilder: (ctx) => Consumer(
          builder: (ctx, sheetRef, _) {
            final st = GrassBagTokens.of(ctx);
            final s = sheetRef.watch(
              appProvider.select(
                (st) => (
                  goals: st.goals,
                  todos: st.todos,
                  glassTier: st.glassTier,
                ),
              ),
            );
            final c = sheetRef.read(appProvider.notifier);
            final curGoal = s.goals.where((g) => !g.isCompleted).firstOrNull;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (curGoal != null) ...[
                  GrassBagSheetSection(
                    padding: const EdgeInsets.all(13),
                    children: [
                      Row(
                        children: [
                          Icon(
                            CupertinoIcons.flag_fill,
                            size: 16,
                            color: curGoal.isBlocked
                                ? st.err
                                : (curGoal.isPaused || curGoal.isDisarmed ? st.warn : st.primary),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              curGoal.title,
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: st.text),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            curGoal.statusLabel,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: curGoal.isBlocked
                                  ? st.err
                                  : (curGoal.isPaused || curGoal.isDisarmed ? st.warn : st.primary),
                            ),
                          ),
                        ],
                      ),
                      if (curGoal.criteria.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(curGoal.criteria, style: TextStyle(fontSize: 12, color: st.text2)),
                      ],
                      if (curGoal.isBlocked && curGoal.blockedReasonMessage?.isNotEmpty == true) ...[
                        const SizedBox(height: 8),
                        GrassBagStatusBanner(
                          tone: GrassBagBannerTone.warn,
                          borderRadius: 12,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          message: curGoal.blockedReasonMessage!,
                        ),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: GrassBagSecondaryGlassButton(
                              label: curGoal.isArmed ? '暂停目标' : '恢复执行',
                              height: 36,
                              tier: s.glassTier,
                              insideGlass: true,
                              accentForeground: !curGoal.isArmed,
                              onTap: () => c.updateGoalStatus(
                                curGoal.id,
                                curGoal.isArmed ? 'paused' : 'active',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: GrassBagPrimaryGlassButton(
                              label: '标记达成',
                              height: 36,
                              tier: s.glassTier,
                              insideGlass: true,
                              onTap: () {
                                c.updateGoalStatus(curGoal.id, 'completed');
                                Navigator.of(ctx).pop();
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (s.todos.isNotEmpty) const SizedBox(height: 12),
                ],
                if (s.todos.isNotEmpty)
                  GrassBagSheetSection(
                    header: '执行待办（${s.todos.where((e) => e.done).length}/${s.todos.length}）',
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    children: [
                      for (final td in s.todos)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.5),
                          child: Row(
                            children: [
                              if (td.active && !td.done)
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: Center(child: CupertinoActivityIndicator(radius: 6, color: st.primary)),
                                )
                              else
                                Icon(
                                  td.done ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                                  size: 16,
                                  color: td.done ? st.ok : st.text3,
                                ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  td.title,
                                  style: TextStyle(
                                    fontSize: 13,
                                    decoration: td.done ? TextDecoration.lineThrough : null,
                                    color: td.done ? st.text3 : (td.active ? st.primary : st.text),
                                    fontWeight: td.active ? FontWeight.w600 : FontWeight.w400,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
              ],
            );
          },
        ),
      );
    }

    final Color accentCol;
    if (activeGoal != null) {
      accentCol = activeGoal.isBlocked
          ? t.err
          : (activeGoal.isPaused || activeGoal.isDisarmed ? t.warn : t.primary);
    } else {
      accentCol = activeTodo != null ? t.primary : t.ok;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
      child: GrassBagSpringTap(
        onTap: openQuickSheet,
        pressedScale: 0.985,
        haptic: true,
        child: GrassBagGlass(
          tier: slice.glassTier,
          borderRadius: 18,
          useCardQuality: true,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8.5),
          child: Row(
            children: [
              if (activeGoal != null)
                Icon(CupertinoIcons.flag_fill, size: 14, color: accentCol)
              else if (activeTodo != null)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: Center(child: CupertinoActivityIndicator(radius: 6, color: accentCol)),
                )
              else
                Icon(CupertinoIcons.checkmark_circle_fill, size: 14, color: accentCol),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  activeGoal != null
                      ? activeGoal.title
                      : (activeTodo != null
                          ? activeTodo.title
                          : '待办清单 · 已完成 $doneCount/${todos.length}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 2),
                decoration: BoxDecoration(
                  color: accentCol.withValues(alpha: t.isDark ? 0.22 : 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  activeGoal != null
                      ? activeGoal.statusLabel
                      : '$doneCount/${todos.length}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: accentCol,
                  ),
                ),
              ),
              if (activeGoal != null) ...[
                const SizedBox(width: 2),
                GrassBagSpringTap(
                  onTap: () => ctrl.updateGoalStatus(
                    activeGoal.id,
                    activeGoal.isArmed ? 'paused' : 'active',
                  ),
                  pressedScale: 0.90,
                  haptic: true,
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: Center(
                      child: Icon(
                        activeGoal.isArmed ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
                        size: 14,
                        color: accentCol,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Stateful slide + Liquid Glass materialize transition owning & disposing its [CurvedAnimation]
/// cleanly so AnimatedSwitcher popovers never double-curve or leak listeners.
class _ComposerSlideMaterialize extends StatefulWidget {
  const _ComposerSlideMaterialize({
    required this.animation,
    required this.tier,
    required this.beginOffset,
    required this.scaleFrom,
    required this.contentSigma,
    required this.child,
  });

  final Animation<double> animation;
  final GrassBagGlassTier tier;
  final Offset beginOffset;
  final double scaleFrom;
  final double contentSigma;
  final Widget child;

  @override
  State<_ComposerSlideMaterialize> createState() =>
      _ComposerSlideMaterializeState();
}

class _ComposerSlideMaterializeState extends State<_ComposerSlideMaterialize> {
  late CurvedAnimation _slideCurve;
  late Animation<Offset> _slideAnim;

  void _initCurve() {
    _slideCurve = CurvedAnimation(
      parent: widget.animation,
      curve: const Cubic(0.22, 1.0, 0.36, 1.0),
      reverseCurve: Curves.easeInCubic,
    );
    _slideAnim = Tween<Offset>(
      begin: widget.beginOffset,
      end: Offset.zero,
    ).animate(_slideCurve);
  }

  @override
  void initState() {
    super.initState();
    _initCurve();
  }

  @override
  void didUpdateWidget(covariant _ComposerSlideMaterialize oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _slideCurve.dispose();
      _initCurve();
    } else if (oldWidget.beginOffset != widget.beginOffset) {
      _slideAnim = Tween<Offset>(
        begin: widget.beginOffset,
        end: Offset.zero,
      ).animate(_slideCurve);
    }
  }

  @override
  void dispose() {
    _slideCurve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnim,
      child: GrassBagMaterializeTransition(
        animation: widget.animation,
        tier: widget.tier,
        alignment: Alignment.bottomCenter,
        scaleFrom: widget.scaleFrom,
        contentSigma: widget.contentSigma,
        child: widget.child,
      ),
    );
  }
}

class _EditQueuedMessageSheetBody extends ConsumerStatefulWidget {
  const _EditQueuedMessageSheetBody({required this.item});

  final QueuedMessageItem item;

  @override
  ConsumerState<_EditQueuedMessageSheetBody> createState() => _EditQueuedMessageSheetBodyState();
}

class _EditQueuedMessageSheetBodyState extends ConsumerState<_EditQueuedMessageSheetBody> {
  late final TextEditingController _editCtrl = TextEditingController(text: widget.item.text);

  @override
  void dispose() {
    _editCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        GrassBagTextField(
          controller: _editCtrl,
          placeholder: '输入新的消息内容…',
          maxLines: 4,
          minLines: 2,
          insideGlass: true,
          autofocus: true,
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '取消',
                height: 40,
                tier: tier,
                insideGlass: true,
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: '保存修改',
                height: 40,
                tier: tier,
                insideGlass: true,
                onTap: () {
                  final next = _editCtrl.text.trim();
                  if (next.isEmpty) {
                    ref.read(appProvider.notifier).showToast('内容不能为空', tone: ToastTone.warn);
                    return;
                  }
                  Navigator.of(context).pop();
                  unawaited(ref.read(appProvider.notifier).editQueuedMessage(widget.item.id, next));
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}
