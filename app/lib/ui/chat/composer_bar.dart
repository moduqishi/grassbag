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
import '../common/file_preview_sheet.dart';
import '../common/grassbag_sheets.dart';
import '../common/preview_highlight_utils.dart';

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
  static final RegExp _slashTriggerRe = RegExp(r'^/([^\s/]*)$');
  // Allow Chinese prose or punctuation immediately before `@` (e.g. `看看@composer`),
  // while ignoring email addresses (`foo@bar.com`).
  static final RegExp _atTriggerRe = RegExp(r'(?:^|[^a-zA-Z0-9._+-])(@([^\s]*))$');

  final ValueNotifier<int> _suggestionTickNotifier = ValueNotifier<int>(0);
  final ScrollController _suggestionScrollCtrl = ScrollController();
  bool _plusOpen = false;
  bool _streamModeDeckOpen = false;
  bool _takeoverCollapsed = false;
  int _pendingSlideDir = 0;
  String? _lastTakeoverKey;
  bool _hasText = false;
  bool _compactNudgeDismissed = false;
  bool _wasImeComposing = false;
  int _lastImeComposingEndMs = 0;
  bool _editBranchResend = true;
  String? _mentionTrigger; // '/' or '@'
  String _mentionQuery = '';
  int _mentionStartOffset = -1;
  int? _dismissedTokenStart;
  String? _dismissedTrigger;
  final ValueNotifier<int> _activeSuggestionIdxNotifier = ValueNotifier<int>(0);
  final ScrollController _inputScrollCtrl = ScrollController();
  bool _submitting = false;
  Timer? _refDebounceTimer;
  Timer? _draftSyncTimer;
  int _refReqSeq = 0;
  bool _loadingRefs = false;
  List<Map<String, String>> _remoteRefs = const [];
  final List<Map<String, dynamic>> _pickedReferences = [];
  final Map<String, ({Map<String, Set<String>> selected, Map<String, String> custom})>
      _questionDraftsByInteractionId = {};
  bool _keyboardNavigatingSuggestions = false;
  List<SlashCommandItem> _latestCommands = const [];
  List<Map<String, String>> _latestRefs = const [];
  List<WorkspaceFileNode>? _cachedWorkspaceFilesRef;
  List<String> _cachedFlatFilePaths = const [];

  bool get _isDesktopPlatform =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  static bool _isInstantSlashCommand(String command, {required bool isEmptyChat}) {
    return const {'/new', '/plan', '/status'}.contains(command) ||
        (!isEmptyChat &&
            const {'/fork', '/export', '/compact', '/stop'}.contains(command));
  }

  void _setStreamModeDeckOpen(bool open) {
    if (_streamModeDeckOpen == open) return;
    if (open && _plusOpen) _setPlusOpen(false);
    setState(() => _streamModeDeckOpen = open);
    _syncSuggestionsNotifier(_mentionTrigger != null || open);
  }

  void _removePickedReference(String path) {
    HapticFeedback.selectionClick();
    setState(() {
      _pickedReferences.removeWhere((r) => r['path'] == path);
    });
    final cur = widget.controller.text;
    final tokenWithSpace = '@$path ';
    final tokenBare = '@$path';
    String next = cur;
    if (next.contains(tokenWithSpace)) {
      next = next.replaceFirst(tokenWithSpace, '');
    } else if (next.contains(tokenBare)) {
      next = next.replaceFirst(tokenBare, '');
    }
    if (next != cur) {
      widget.controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }
  }

  void _showEditQueuedDialog(BuildContext context, QueuedMessageItem item) {
    if (item.text.startsWith('[附带 ') && item.text.endsWith(' 个附件]')) {
      ref.read(appProvider.notifier).showToast('纯附件排队消息暂不支持修改文字', tone: ToastTone.info);
      return;
    }
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
    // composition is active (or within the 110ms post-commit window on macOS/Web/Android IMEs)!
    final composing = widget.controller.value.composing;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final isEnterKey = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    final isImeComposing = (composing.isValid && !composing.isCollapsed) ||
        event.logicalKey == LogicalKeyboardKey.process ||
        (isEnterKey && (nowMs - _lastImeComposingEndMs) < 110);
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
        if (!_keyboardNavigatingSuggestions) {
          setState(() => _keyboardNavigatingSuggestions = true);
        }
        _activeSuggestionIdxNotifier.value = (_activeSuggestionIdxNotifier.value + 1) % count;
        _scrollActiveSuggestionIntoView();
        return KeyEventResult.handled;
      }
      if (count > 0 && event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (!_keyboardNavigatingSuggestions) {
          setState(() => _keyboardNavigatingSuggestions = true);
        }
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
          final canInstant = _isInstantSlashCommand(cmd.command, isEmptyChat: isEmptyChat);
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
      // Cmd/Ctrl+Shift+Enter steers while streaming; Cmd/Ctrl+Enter sends; Shift+Enter inserts newline.
      if (shiftPressed && cmdOrCtrlPressed && ref.read(appProvider).isStreaming) {
        if (event is KeyDownEvent) {
          unawaited(_submit(mode: 'steer'));
        }
        return KeyEventResult.handled;
      }
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
    _suggestionTickNotifier.dispose();
    _activeSuggestionIdxNotifier.dispose();
    _suggestionScrollCtrl.dispose();
    _inputScrollCtrl.dispose();
    super.dispose();
  }

  void _scrollActiveSuggestionIntoView() {
    if (!_suggestionScrollCtrl.hasClients || _suggestionScrollCtrl.positions.length != 1) return;
    final scale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 2.0);
    final itemExtent = 44.0 * scale;
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
    if (!open) {
      if (_mentionTrigger != null) _dismissSuggestions();
      if (_streamModeDeckOpen) setState(() => _streamModeDeckOpen = false);
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
    _refReqSeq++;
    setState(() {
      if (_mentionStartOffset >= 0 && _mentionTrigger != null) {
        _dismissedTokenStart = _mentionStartOffset;
        _dismissedTrigger = _mentionTrigger;
      }
      _mentionTrigger = null;
      _mentionQuery = '';
      _mentionStartOffset = -1;
      _loadingRefs = false;
      _remoteRefs = const [];
      _keyboardNavigatingSuggestions = false;
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
    if (open && _streamModeDeckOpen) {
      setState(() => _streamModeDeckOpen = false);
    }
    if (open && widget.focusNode.hasFocus) {
      widget.focusNode.unfocus();
    }
    if (_plusOpen == open) return;
    setState(() => _plusOpen = open);
    if (!fromExternal && widget.plusOpenNotifier != null) {
      widget.plusOpenNotifier!.value = open;
    }
    widget.onPlusOpenChanged?.call(open);
  }

  void _togglePlus() {
    HapticFeedback.selectionClick();
    _setPlusOpen(!_plusOpen);
  }

  void _openVoiceInput() {
    if (_plusOpen) _setPlusOpen(false);
    HapticFeedback.selectionClick();
    showVoiceInputSheet(
      context,
      ref,
      onTranscriptConfirmed: (text) {
        final val = widget.controller.value;
        final cur = val.text;
        final sel = val.selection;
        final start = sel.isValid ? sel.start.clamp(0, cur.length) : cur.length;
        final end = sel.isValid ? sel.end.clamp(start, cur.length) : cur.length;
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

  bool _suppressDraftSync = false;
  String? _draftScopeHostId;
  String? _draftScopeSessionId;
  bool _hasUnsyncedDraftEdit = false;

  void _flushPendingDraftToOutgoingScope(String? outgoingHostId, String? outgoingSessionId) {
    _draftSyncTimer?.cancel();
    _draftSyncTimer = null;
    if (!_hasUnsyncedDraftEdit || outgoingHostId == null || outgoingHostId.isEmpty) return;
    _hasUnsyncedDraftEdit = false;
    // Never overwrite the outgoing session's saved draft with an edited turn's text!
    final editCtx = widget.editingContextNotifier?.value;
    final draftText = editCtx != null ? editCtx.stashedDraft : widget.controller.text;
    ref.read(appProvider.notifier).setComposerDraftForScope(
          outgoingHostId,
          outgoingSessionId,
          draftText,
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
    var refsPruned = false;
    if (_pickedReferences.isNotEmpty) {
      final beforeLen = _pickedReferences.length;
      _pickedReferences.removeWhere((r) {
        final p = (r['path'] ?? '').toString();
        return p.isEmpty || !draft.contains('@$p');
      });
      refsPruned = _pickedReferences.length != beforeLen;
    }
    if (nextHasText != _hasText || refsPruned) {
      setState(() => _hasText = nextHasText);
    }
  }

  void _flushDraftSync() {
    _draftSyncTimer?.cancel();
    _draftSyncTimer = null;
    _hasUnsyncedDraftEdit = false;
    if (!mounted || widget.editingContextNotifier?.value != null) return;
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
    if (_dismissedTokenStart != null) {
      if (cursor < _dismissedTokenStart! || _dismissedTokenStart! >= raw.length) {
        _dismissedTokenStart = null;
        _dismissedTrigger = null;
      } else if (nextTrigger == _dismissedTrigger && nextStart == _dismissedTokenStart) {
        nextTrigger = null;
        nextQuery = '';
        nextStart = -1;
      } else {
        _dismissedTokenStart = null;
        _dismissedTrigger = null;
      }
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
        List<Map<String, String>> refs = const [];
        try {
          refs = await ref.read(appProvider.notifier).fetchSessionReferences(q);
        } catch (_) {
          refs = const [];
        } finally {
          if (mounted &&
              seq == _refReqSeq &&
              _mentionTrigger == '@' &&
              ref.read(appProvider).activeHostId == reqHostId) {
            _loadingRefs = false;
            _remoteRefs = refs;
            _suggestionTickNotifier.value++;
          }
        }
      });
    }

    var refsPruned = false;
    if (_pickedReferences.isNotEmpty) {
      final beforeLen = _pickedReferences.length;
      _pickedReferences.removeWhere((r) {
        final p = (r['path'] ?? '').toString();
        return p.isEmpty || !raw.contains('@$p');
      });
      refsPruned = _pickedReferences.length != beforeLen;
    }

    final triggerVisibilityOrKindChanged = nextTrigger != _mentionTrigger;
    final queryChanged = nextQuery != _mentionQuery;
    final startChanged = nextStart != _mentionStartOffset;
    if (nextHasText != _hasText || triggerVisibilityOrKindChanged || refsPruned) {
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
      _dismissedTokenStart = null;
      _dismissedTrigger = null;
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
    _dismissedTokenStart = null;
    _dismissedTrigger = null;
    _loadingRefs = false;
    _compactNudgeDismissed = false;
    _streamModeDeckOpen = false;
    _takeoverCollapsed = false;
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

    if (appSnapshot.isStopping) {
      ctrl.showToast('正在停止上一轮生成，请稍候片刻再发送…', tone: ToastTone.info);
      return;
    }

    // Pre-flight guard: preserve user's draft when local Android engine is still booting
    // or not deployed, host is connecting/reconnecting, remote host awaits auth, or connected DSH has 0 models!
    if (GrassBagNativeBridge.instance.isAndroidNative &&
        appSnapshot.activeHost.isLocal &&
        (appSnapshot.nativeStatusHydrated || appSnapshot.loadingSessions) &&
        !appSnapshot.nativeRuntimeStatus.engineRunning) {
      if (!appSnapshot.nativeStatusHydrated ||
          appSnapshot.nativeRuntimeStatus.engineState == 'starting' ||
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
        (appSnapshot.connectionPhase == ConnectionPhase.connecting ||
            appSnapshot.connectionPhase == ConnectionPhase.reconnecting ||
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
        appSnapshot.hydratingDomains &&
        !appSnapshot.hasAvailableModels) {
      ctrl.showToast('正在同步可用模型列表，请稍候片刻（已保留输入内容）', tone: ToastTone.info);
      return;
    }
    if (!text.startsWith('/') &&
        appSnapshot.isDshConnected &&
        appSnapshot.connectionPhase == ConnectionPhase.connected &&
        !appSnapshot.hasAvailableModels &&
        !appSnapshot.hydratingDomains &&
        appSnapshot.routableProviders.isEmpty) {
      ctrl.showToast('请先登录或配置模型渠道，草稿已保留', tone: ToastTone.info);
      if (widget.onOpenModelSettings != null) {
        widget.onOpenModelSettings!();
      } else {
        showModelSheet(context, ref, onOpenModelSettings: widget.onOpenModelSettings);
      }
      return;
    }

    final startHostId = appSnapshot.activeHostId;
    final startSessionId = appSnapshot.activeSessionId;
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
    // Snapshot picked references BEFORE `widget.controller.clear()` triggers `_onTextChanged`
    // (which synchronously prunes `_pickedReferences` when `raw == ""`).
    final savedRefs = List<Map<String, dynamic>>.of(_pickedReferences);
    final activeRefs = <Map<String, dynamic>>[
      ...savedRefs.where((r) => text.contains('@${r['path']}')),
      if (editCtx != null)
        ...editCtx.references.where(
          (r) =>
              !savedRefs.any((p) => p['path'] == r['path']) &&
              (r['path'] == null || text.contains('@${r['path']}')),
        ),
    ];
    // Clear input optimistically BEFORE awaiting async send so typing stays instant
    // and Android IME composing state resets cleanly without dismissing the keyboard.
    // When editing a previous turn, NEVER flush `""` over the stashed draft before fork/send!
    widget.controller.clear();
    if (editCtx == null) {
      _flushDraftSync();
    }
    if (widget.editingContextNotifier?.value != null) {
      widget.editingContextNotifier!.value = null;
    }
    if (hadFocus && !widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
    }
    setState(() {
      _submitting = true;
      _hasText = false;
      _streamModeDeckOpen = false;
      _dismissedTokenStart = null;
      _dismissedTrigger = null;
      _mentionTrigger = null;
      _mentionQuery = '';
      _mentionStartOffset = -1;
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
        _pickedReferences
          ..clear()
          ..addAll(savedRefs);
        setState(() => _submitting = false);
        widget.editingContextNotifier?.value = editCtx;
        widget.controller.value = TextEditingValue(
          text: rawText,
          selection: TextSelection.collapsed(offset: rawText.length),
        );
        return;
      }
      expectedRenderGen = ref.read(appProvider).sessionRenderGen;
      // Fork succeeded: leave stashedDraft intact on the original session and clear only the new branch!
      _flushDraftSync();
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
      // User switched hosts or sessions while sending; never overwrite the new composer,
      // but if the send failed, save the prompt back into the original session's draft!
      if (!sent && rawText.isNotEmpty) {
        final prevDraft = ctrl.getComposerDraftForScope(startHostId, startSessionId);
        final saved = prevDraft.trim().isEmpty ? rawText : '$rawText\n\n$prevDraft';
        ctrl.setComposerDraftForScope(startHostId, startSessionId, saved);
        ctrl.showToast('原消息未发送，已保留在原会话草稿中', tone: ToastTone.info);
      }
      return;
    }
    if (sent) {
      _pickedReferences.clear();
      // If the user edited-and-resent in place (without forking), restore any stashed unsent draft!
      if (editCtx != null && !shouldForkBefore && editCtx.stashedDraft.isNotEmpty) {
        if (widget.controller.text.isEmpty) {
          widget.controller.value = TextEditingValue(
            text: editCtx.stashedDraft,
            selection: TextSelection.collapsed(offset: editCtx.stashedDraft.length),
          );
          _flushDraftSync();
        }
      } else if (editCtx != null && !shouldForkBefore) {
        _flushDraftSync();
      }
      widget.onMessageSent?.call();
    } else if (rawText.isNotEmpty) {
      // Never drop user's failed prompt or `@` refs even if they started typing while in flight!
      _pickedReferences
        ..clear()
        ..addAll(savedRefs);
      if (editCtx != null && !shouldForkBefore) {
        widget.editingContextNotifier?.value = editCtx;
      }
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
      if (prev != null && prev != next && widget.editingContextNotifier?.value == null) {
        final draft = ref.read(appProvider.notifier).getComposerDraftForActiveHost();
        if (draft.isNotEmpty && draft != widget.controller.text) {
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
            activePendingInteractionIndex: s.activePendingInteractionIndex,
            activeQuestion: s.activeQuestion,
            activeCordisRequest: s.activeCordisRequest,
            contextPctHigh: s.contextPct >= 80 ? s.contextPct : 0,
            pendingAttachments: s.pendingAttachments,
            queuedMessages: s.queuedMessages,
            activeWorkspace: s.activeWorkspaceDisplayName,
            isEmptyChat: s.isEmptyChat,
            isStreaming: s.isStreaming,
            isStopping: s.isStopping,
            isCompactingContext: s.isCompactingContext,
            canCycleEffort: model != null && model.efforts.length >= 2,
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
    final activeTakeoverKey = showApproval
        ? 'a:${state.pendingApprovalInteractionId ?? state.pendingApprovalCommand.hashCode}'
        : (showQuestion
            ? 'q:${state.activeQuestion!.interactionId}'
            : (showCordis ? 'c:${state.activeCordisRequest!.interactionId}' : null));
    if (activeTakeoverKey != _lastTakeoverKey) {
      _lastTakeoverKey = activeTakeoverKey;
      _takeoverCollapsed = false;
    }
    if (state.activePendingInteractionCount == 0 && _questionDraftsByInteractionId.isNotEmpty) {
      _questionDraftsByInteractionId.clear();
    }
    final showExpandedTakeover = hasTakeover && !_takeoverCollapsed;
    if (_streamModeDeckOpen && (!state.isStreaming || !hasText || showExpandedTakeover || _plusOpen)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _streamModeDeckOpen) {
          setState(() => _streamModeDeckOpen = false);
          if (_mentionTrigger == null) _syncSuggestionsNotifier(false);
        }
      });
    }
    final showRiskPill = perm.risky && !showExpandedTakeover && !state.isEmptyChat && !_plusOpen;
    final showReadOnlyPill =
        perm.id == 'read-only' && !showExpandedTakeover && !state.isEmptyChat && !_plusOpen;
    final showPlanPill = state.planMode && !showExpandedTakeover && !_plusOpen;
    final showCompactNudgePill = state.contextPctHigh >= 80 &&
        !_compactNudgeDismissed &&
        !state.isStreaming &&
        !state.isEmptyChat &&
        !showExpandedTakeover &&
        !_plusOpen;
    if (state.contextPctHigh < 80 && _compactNudgeDismissed) {
      _compactNudgeDismissed = false;
    }
    final hasStatusPills =
        showRiskPill || showReadOnlyPill || showPlanPill || showCompactNudgePill || state.isCompactingContext;
    final screenW = MediaQuery.sizeOf(context).width;
    final isWide = screenW >= 540;

    if (showExpandedTakeover &&
        (_plusOpen || _streamModeDeckOpen || _mentionTrigger != null || widget.focusNode.hasFocus)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.focusNode.hasFocus) {
          widget.focusNode.unfocus();
        }
        if (_plusOpen) _setPlusOpen(false);
        if (_streamModeDeckOpen) {
          setState(() => _streamModeDeckOpen = false);
        }
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
    final showSuggestions = !showExpandedTakeover &&
        !_plusOpen &&
        !_streamModeDeckOpen &&
        (_mentionTrigger == '/' || _mentionTrigger == '@');
    if (!showSuggestions) {
      _latestCommands = const [];
      _latestRefs = const [];
      if (!_streamModeDeckOpen && widget.suggestionsOpenNotifier?.value == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_streamModeDeckOpen) _syncSuggestionsNotifier(false);
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
          !_streamModeDeckOpen &&
          !showExpandedTakeover &&
          !showSuggestions;
      final size = inlineWithPills ? 34.0 : 40.0;
      final showActivityPill = state.isStreaming || hasNewBelow;
      final pillLabel = state.isStreaming ? '正在回复' : '有新回复';
      final morphDur = GrassBagMotion.duration(context, const Duration(milliseconds: 220));
      return AnimatedSwitcher(
        duration: GrassBagMotion.duration(context, const Duration(milliseconds: 210)),
        reverseDuration: GrassBagMotion.duration(context, const Duration(milliseconds: 160)),
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
                key: const ValueKey('scroll-down-droplet'),
                padding: inlineWithPills
                    ? const EdgeInsets.only(left: 8)
                    : const EdgeInsets.only(bottom: 10),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Tooltip(
                    message: showActivityPill ? '回到底部查看最新回复' : '回到底部',
                    child: GrassBagGlassPillButton(
                      tier: state.glassTier,
                      height: showActivityPill ? (inlineWithPills ? 34 : 38) : size,
                      padding: EdgeInsets.symmetric(
                        horizontal: showActivityPill ? 12 : (inlineWithPills ? 8.5 : 10.5),
                      ),
                      onTap: () => widget.onScrollToBottom?.call(),
                      child: AnimatedSize(
                        duration: morphDur,
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (showActivityPill) ...[
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
                            ],
                            Icon(
                              CupertinoIcons.chevron_down,
                              size: showActivityPill
                                  ? 13.5
                                  : (inlineWithPills ? 17 : 19),
                              color: showActivityPill ? t.primary : t.text,
                            ),
                          ],
                        ),
                      ),
                    ),
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
            final hasComposerAccessories = state.pendingAttachments.isNotEmpty ||
                _pickedReferences.isNotEmpty ||
                state.queuedMessages.isNotEmpty ||
                widget.editingContextNotifier?.value != null;
            final isTightDock = dockBox.maxHeight.isFinite &&
                (maxDockH < 290.0 || (maxDockH < 430.0 && hasComposerAccessories));
            final overlayOpen = showSuggestions || _plusOpen || _streamModeDeckOpen;
            final effectiveTextMaxLines = (overlayOpen && maxDockH < 260.0)
                ? 1
                : (maxDockH < 210.0
                    ? 2
                    : (maxDockH < 270.0 || (hasComposerAccessories && maxDockH < 420.0) ? 3 : 5));
            final suggestionListMaxH =
                math.min(220.0, math.max(84.0, maxDockH - (hasStatusPills ? 196.0 : 156.0)));
            // On compact phones with IME open (< 300dp dock height), fold "收起查看对话" inside
            // the takeover header so the card gains +44dp for options & input instead of crushing!
            final compactTakeover = showExpandedTakeover && maxDockH < 300.0;
            final collapseBarH = (showExpandedTakeover && !compactTakeover) ? 44.0 : 0.0;
            final takeoverMaxH = math.min(
              560.0,
              math.max(140.0, maxDockH - (hasStatusPills ? 48.0 : 0.0) - collapseBarH),
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Keep floating "Scroll to latest" droplet OUTSIDE _ComposerHeightReporter when no
                // status pills row is active; when status pills ARE active it shares their row inline!
                if (!hasStatusPills && maxDockH >= 140.0) scrollDropletWidget(),

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
                      key: const ValueKey('suggestions-box'),
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
                                    bool isSubsequence(String needle, String haystack) {
                                      var ni = 0;
                                      for (var hi = 0; hi < haystack.length && ni < needle.length; hi++) {
                                        if (haystack.codeUnitAt(hi) == needle.codeUnitAt(ni)) {
                                          ni++;
                                        }
                                      }
                                      return ni == needle.length;
                                    }
                                    int rankFor(String path, String label) {
                                      final q = _mentionQuery.trim();
                                      if (q.isEmpty) return 0;
                                      final pLow = path.toLowerCase();
                                      final lLow = label.toLowerCase();
                                      final slash = pLow.lastIndexOf('/');
                                      final base = slash >= 0 ? pLow.substring(slash + 1) : pLow;
                                      if (base.startsWith(q) || lLow.startsWith(q)) return 0;
                                      if (base.contains(q) || lLow.contains(q)) return 1;
                                      if (pLow.contains(q)) return 2;
                                      final tokens = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
                                      if (tokens.length > 1) {
                                        final combined = '$pLow $lLow';
                                        if (tokens.every(combined.contains)) return 3;
                                      }
                                      if (q.length >= 2 &&
                                          (isSubsequence(q, base) ||
                                              isSubsequence(q, lLow) ||
                                              isSubsequence(q, pLow))) {
                                        return 4;
                                      }
                                      return -1;
                                    }
                                    for (final r in _remoteRefs) {
                                      final p = r['path'] ?? '';
                                      final lbl = r['label'] ?? '';
                                      if (p.isEmpty) continue;
                                      final rank = rankFor(p, lbl);
                                      if (rank >= 0 && seen.add(p)) {
                                        candidates.add((item: r, rank: rank));
                                      }
                                    }
                                    for (final p in _getFlattenedFilePaths(leafWorkspaceFiles)) {
                                      final rank = rankFor(p, '');
                                      if (rank >= 0 && seen.add(p)) {
                                        candidates.add((item: {'path': p, 'kind': 'file'}, rank: rank));
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
                                  interactiveGlow: false,
                                  useSheetSettings: true,
                                  clipBehavior: Clip.antiAlias,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(8, 0, 2, 4),
                                        child: Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                _mentionTrigger == '/'
                                                    ? '快捷指令${filteredCommands.isNotEmpty ? ' (${filteredCommands.length})' : ''}'
                                                    : '引用文件与会话${filteredRefs.isNotEmpty ? ' (${filteredRefs.length})' : ''}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w600,
                                                  color: t.text3,
                                                ),
                                              ),
                                            ),
                                            if (_mentionTrigger == '@' && _loadingRefs) ...[
                                              const SizedBox(width: 7),
                                              GrassBagActivityIndicator(radius: 5.5, color: t.primary),
                                            ],
                                            const SizedBox(width: 8),
                                            Tooltip(
                                              message: '关闭提示',
                                              excludeFromSemantics: true,
                                              child: Semantics(
                                                button: true,
                                                label: '关闭提示',
                                                child: GrassBagSpringTap(
                                                  onTap: _dismissSuggestions,
                                                  pressedScale: 0.88,
                                                  haptic: true,
                                                  child: SizedBox(
                                                    width: 40,
                                                    height: 40,
                                                    child: Center(
                                                      child: Icon(
                                                        CupertinoIcons.xmark,
                                                        size: 13.5,
                                                        color: t.text3,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Flexible(
                                        fit: FlexFit.loose,
                                        child: AnimatedSize(
                                          duration: GrassBagMotion.duration(
                                            context,
                                            const Duration(milliseconds: 150),
                                          ),
                                          curve: Curves.easeOutCubic,
                                          alignment: Alignment.bottomCenter,
                                          child: ConstrainedBox(
                                            constraints: BoxConstraints(maxHeight: suggestionListMaxH),
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
                                                          final active = (isDesktopPlatform || _keyboardNavigatingSuggestions) &&
                                                              ci ==
                                                                  activeSuggestionIdx.clamp(
                                                                    0,
                                                                    filteredCommands.length - 1,
                                                                  );
                                                          final isInstant = _isInstantSlashCommand(
                                                            cmd.command,
                                                            isEmptyChat: state.isEmptyChat,
                                                          );
                                                          final isSkill = cmd.command.startsWith('/skill:');
                                                          final subtitle = cmd.desc.trim().isEmpty
                                                              ? cmd.title
                                                              : (cmd.title.trim().isEmpty
                                                                  ? cmd.desc
                                                                  : '${cmd.title} · ${cmd.desc}');
                                                          return MouseRegion(
                                                            onEnter: (_) {
                                                              if (_activeSuggestionIdxNotifier.value != ci) {
                                                                _keyboardNavigatingSuggestions = true;
                                                                _activeSuggestionIdxNotifier.value = ci;
                                                              }
                                                            },
                                                            child: GrassBagSpringTap(
                                                              onTap: () => _applySuggestion(
                                                                cmd.command,
                                                                executeImmediately: isInstant,
                                                              ),
                                                              child: AnimatedContainer(
                                                                duration: GrassBagMotion.duration(
                                                                  context,
                                                                  const Duration(milliseconds: 110),
                                                                ),
                                                                curve: Curves.easeOutCubic,
                                                                constraints: const BoxConstraints(minHeight: 44),
                                                                alignment: Alignment.centerLeft,
                                                                decoration: ShapeDecoration(
                                                                  gradient: LinearGradient(
                                                                    begin: Alignment.topLeft,
                                                                    end: Alignment.bottomRight,
                                                                    colors: active
                                                                        ? [
                                                                            t.primary.withValues(alpha: t.isDark ? 0.24 : 0.14),
                                                                            t.primary.withValues(alpha: t.isDark ? 0.12 : 0.07),
                                                                          ]
                                                                        : const [Colors.transparent, Colors.transparent],
                                                                  ),
                                                                  shape: RoundedSuperellipseBorder(
                                                                    borderRadius: BorderRadius.circular(13),
                                                                    side: BorderSide(
                                                                      color: active
                                                                          ? t.primary.withValues(
                                                                              alpha: t.isDark ? 0.34 : 0.24)
                                                                          : Colors.transparent,
                                                                      width: 0.65,
                                                                    ),
                                                                  ),
                                                                ),
                                                                padding: const EdgeInsets.symmetric(
                                                                  horizontal: 8,
                                                                  vertical: 8,
                                                                ),
                                                                child: Row(
                                                                  children: [
                                                                    ConstrainedBox(
                                                                      constraints: const BoxConstraints(maxWidth: 168),
                                                                      child: Container(
                                                                        padding: const EdgeInsets.symmetric(
                                                                          horizontal: 7,
                                                                          vertical: 2,
                                                                        ),
                                                                        decoration: ShapeDecoration(
                                                                          color: isSkill ? t.okSoft : t.primarySoft,
                                                                          shape: RoundedSuperellipseBorder(
                                                                            borderRadius: BorderRadius.circular(8),
                                                                            side: BorderSide(
                                                                              color: (isSkill ? t.ok : t.primary)
                                                                                  .withValues(alpha: t.isDark ? 0.30 : 0.20),
                                                                              width: 0.55,
                                                                            ),
                                                                          ),
                                                                        ),
                                                                        child: Text(
                                                                          cmd.command,
                                                                          maxLines: 1,
                                                                          overflow: TextOverflow.ellipsis,
                                                                          style: TextStyle(
                                                                            fontFamily: 'monospace',
                                                                            fontSize: 12,
                                                                            fontWeight: FontWeight.w600,
                                                                            color: isSkill ? t.ok : t.primary,
                                                                          ),
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
                                                                      GrassBagFresnelGlassSurface(
                                                                        isPill: true,
                                                                        innerWell: true,
                                                                        padding: const EdgeInsets.symmetric(
                                                                          horizontal: 6.5,
                                                                          vertical: 2,
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
                                                                  !isHostConnected
                                                                      ? '当前未连接到主机，连接后可用 @ 引用工作区文件'
                                                                      : (state.activeWorkspace.isEmpty
                                                                          ? '暂未选择工作区，选择后可用 @ 引用文件'
                                                                          : '未找到匹配文件，可继续输入路径关键词'),
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
                                                                  child: GrassBagFresnelGlassSurface(
                                                                    isPill: true,
                                                                    innerWell: true,
                                                                    tintColor: t.primarySoft,
                                                                    padding: const EdgeInsets.symmetric(
                                                                      horizontal: 9,
                                                                      vertical: 4,
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
                                                          final active = (isDesktopPlatform || _keyboardNavigatingSuggestions) &&
                                                              ri ==
                                                                  activeSuggestionIdx.clamp(
                                                                    0,
                                                                    filteredRefs.length - 1,
                                                                  );
                                                          final isSess = refItem['kind'] == 'session';
                                                          final rawPath = refItem['path'] ?? '';
                                                          final rawLabel = refItem['label'] ?? '';
                                                          final lastSlash = rawPath.lastIndexOf('/');
                                                          final primaryText = isSess
                                                              ? (rawLabel.isNotEmpty ? rawLabel : rawPath)
                                                              : (lastSlash >= 0
                                                                  ? rawPath.substring(lastSlash + 1)
                                                                  : rawPath);
                                                          final secondaryText = isSess
                                                              ? (rawLabel.isNotEmpty ? rawPath : '')
                                                              : (lastSlash > 0
                                                                  ? rawPath.substring(0, lastSlash)
                                                                  : '');
                                                          return MouseRegion(
                                                            onEnter: (_) {
                                                              if (_activeSuggestionIdxNotifier.value != ri) {
                                                                _keyboardNavigatingSuggestions = true;
                                                                _activeSuggestionIdxNotifier.value = ri;
                                                              }
                                                            },
                                                            child: GrassBagSpringTap(
                                                              onTap: () => _applySuggestion(
                                                                rawPath,
                                                                refItem: refItem,
                                                              ),
                                                              child: AnimatedContainer(
                                                                duration: GrassBagMotion.duration(
                                                                  context,
                                                                  const Duration(milliseconds: 110),
                                                                ),
                                                                curve: Curves.easeOutCubic,
                                                                constraints: const BoxConstraints(minHeight: 44),
                                                                alignment: Alignment.centerLeft,
                                                                decoration: ShapeDecoration(
                                                                  gradient: LinearGradient(
                                                                    begin: Alignment.topLeft,
                                                                    end: Alignment.bottomRight,
                                                                    colors: active
                                                                        ? [
                                                                            t.primary.withValues(alpha: t.isDark ? 0.24 : 0.14),
                                                                            t.primary.withValues(alpha: t.isDark ? 0.12 : 0.07),
                                                                          ]
                                                                        : const [Colors.transparent, Colors.transparent],
                                                                  ),
                                                                  shape: RoundedSuperellipseBorder(
                                                                    borderRadius: BorderRadius.circular(13),
                                                                    side: BorderSide(
                                                                      color: active
                                                                          ? t.primary.withValues(
                                                                              alpha: t.isDark ? 0.34 : 0.24)
                                                                          : Colors.transparent,
                                                                      width: 0.65,
                                                                    ),
                                                                  ),
                                                                ),
                                                                padding: const EdgeInsets.symmetric(
                                                                  horizontal: 8,
                                                                  vertical: 7,
                                                                ),
                                                                child: Row(
                                                                  children: [
                                                                    Icon(
                                                                      isSess
                                                                          ? CupertinoIcons.chat_bubble_text_fill
                                                                          : CupertinoIcons.doc_text_fill,
                                                                      size: 14.5,
                                                                      color: isSess ? t.dusk : t.primary,
                                                                    ),
                                                                    const SizedBox(width: 9),
                                                                    Expanded(
                                                                      child: Column(
                                                                        mainAxisSize: MainAxisSize.min,
                                                                        crossAxisAlignment: CrossAxisAlignment.start,
                                                                        children: [
                                                                          Text(
                                                                            primaryText,
                                                                            maxLines: 1,
                                                                            overflow: TextOverflow.ellipsis,
                                                                            style: TextStyle(
                                                                              fontFamily: isSess ? null : 'monospace',
                                                                              fontSize: 12.5,
                                                                              fontWeight: FontWeight.w600,
                                                                              color: t.text,
                                                                            ),
                                                                          ),
                                                                          if (secondaryText.isNotEmpty)
                                                                            Text(
                                                                              secondaryText,
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
                                                                    ),
                                                                  ],
                                                                ),
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

            // Materialized Floating Liquid Glass '+' Deck directly above composer:
            // Keep `!showExpandedTakeover` inside child so takeover arrival dismisses smoothly!
            AnimatedSwitcher(
              duration: GrassBagMotion.duration(context, const Duration(milliseconds: 220)),
              reverseDuration: GrassBagMotion.duration(context, const Duration(milliseconds: 160)),
              switchInCurve: Curves.linear,
              switchOutCurve: Curves.linear,
              transitionBuilder: (child, anim) => _ComposerSlideMaterialize(
                animation: anim,
                tier: state.glassTier,
                alignment: Alignment.bottomLeft,
                beginOffset: const Offset(0, 0.06),
                scaleFrom: 0.92,
                contentSigma: 4.0,
                child: child,
              ),
              child: (_plusOpen && !showExpandedTakeover)
                  ? Align(
                      key: const ValueKey('plus-deck-open'),
                      alignment: Alignment.bottomLeft,
                      heightFactor: 1.0,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: isWide ? 344.0 : double.infinity,
                          ),
                          child: GlassBackdropGroup(
                            enabled: false,
                            child: GrassBagGlass(
                              tier: state.glassTier,
                              borderRadius: 30,
                              elevated: true,
                              useSheetSettings: true,
                              interactiveGlow: false,
                              clipBehavior: Clip.antiAlias,
                              child: SingleChildScrollView(
                                primary: false,
                                child: _PlusDeckContent(
                                  onClose: () => _setPlusOpen(false),
                                  onOpenTerminal: widget.onOpenTerminal,
                                  onOpenVoice: state.speechConfigured ? _openVoiceInput : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(key: ValueKey('plus-deck-closed')),
            ),

            // Native Kyant0 Liquid Glass Steer / Queue / Interrupt deck anchored inside the composer's
            // own overlay stack so it moves in lockstep with the IME keyboard, dismisses cleanly on Back,
            // and never unmounts mid-morph or strands in mid-air!
            AnimatedSwitcher(
              duration: GrassBagMotion.duration(context, const Duration(milliseconds: 185)),
              reverseDuration: GrassBagMotion.duration(context, const Duration(milliseconds: 140)),
              switchInCurve: Curves.linear,
              switchOutCurve: Curves.linear,
              transitionBuilder: (child, anim) => _ComposerSlideMaterialize(
                animation: anim,
                tier: state.glassTier,
                alignment: Alignment.bottomRight,
                beginOffset: const Offset(0, 0.06),
                scaleFrom: 0.92,
                contentSigma: 4.0,
                child: child,
              ),
              child: (!showExpandedTakeover && _streamModeDeckOpen && state.isStreaming && hasText)
                    ? Align(
                        key: const ValueKey('stream-mode-deck-open'),
                        alignment: Alignment.bottomRight,
                        heightFactor: 1.0,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 288),
                            child: GrassBagGlass(
                              tier: state.glassTier,
                              borderRadius: 24,
                              elevated: true,
                              useSheetSettings: true,
                              interactiveGlow: false,
                              clipBehavior: Clip.antiAlias,
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _StreamSendModeRow(
                                    icon: CupertinoIcons.arrow_turn_down_right,
                                    iconColor: t.primary,
                                    title: '插话引导',
                                    subtitle: '立即注入当前正在执行的任务',
                                    isDefault: state.busyEnterMode == 'steer',
                                    onTap: () {
                                      _setStreamModeDeckOpen(false);
                                      unawaited(_submit(mode: 'steer'));
                                    },
                                  ),
                                  Divider(height: 0.5, indent: 44, endIndent: 8, color: t.sep),
                                  _StreamSendModeRow(
                                    icon: CupertinoIcons.text_append,
                                    iconColor: t.primary,
                                    title: '本轮后排队',
                                    subtitle: '等待当前回复结束后自动发送',
                                    isDefault: state.busyEnterMode != 'steer',
                                    onTap: () {
                                      _setStreamModeDeckOpen(false);
                                      unawaited(_submit(mode: 'queue'));
                                    },
                                  ),
                                  Divider(height: 0.5, indent: 44, endIndent: 8, color: t.sep),
                                  _StreamSendModeRow(
                                    icon: CupertinoIcons.stop_circle_fill,
                                    iconColor: t.err,
                                    title: '打断并改问',
                                    subtitle: '立即停止当前回复并发送本条',
                                    destructive: true,
                                    onTap: () {
                                      _setStreamModeDeckOpen(false);
                                      unawaited(_submit(mode: 'interrupt'));
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('stream-mode-deck-closed')),
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
                  // Collapsible takeover bar: smoothly materializes & folds between expanded
                  // collapse action and minimized reminder pill!
                  AnimatedSize(
                    duration: GrassBagMotion.duration(context, const Duration(milliseconds: 210)),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.bottomCenter,
                    child: AnimatedSwitcher(
                      duration: GrassBagMotion.duration(context, const Duration(milliseconds: 190)),
                      reverseDuration:
                          GrassBagMotion.duration(context, const Duration(milliseconds: 140)),
                      switchInCurve: Curves.linear,
                      switchOutCurve: Curves.linear,
                      transitionBuilder: (child, anim) => GrassBagMaterializeTransition(
                        animation: anim,
                        tier: state.glassTier,
                        alignment: Alignment.bottomCenter,
                        scaleFrom: 0.92,
                        contentSigma: 3.5,
                        child: child,
                      ),
                      child: (hasTakeover && !_takeoverCollapsed && !compactTakeover)
                          ? Padding(
                              key: const ValueKey('takeover-collapse-bar'),
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: GrassBagGlassPillButton(
                                  tier: state.glassTier,
                                  height: 34,
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  onTap: () => setState(() {
                                    _pendingSlideDir = 0;
                                    _takeoverCollapsed = true;
                                  }),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(CupertinoIcons.chevron_down, size: 12.5, color: t.text2),
                                      const SizedBox(width: 5),
                                      Text(
                                        '收起查看对话',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: t.text2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          : (hasTakeover && _takeoverCollapsed)
                              ? Padding(
                                  key: const ValueKey('takeover-expand-pill'),
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Center(
                                    child: GrassBagGlassPillButton(
                                      tier: state.glassTier,
                                      height: 40,
                                      prominent: false,
                                      padding: const EdgeInsets.symmetric(horizontal: 14),
                                      onTap: () => setState(() {
                                        _pendingSlideDir = 0;
                                        _takeoverCollapsed = false;
                                      }),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          GrassBagStatusDot(color: t.warn, pulsing: true, size: 7.5),
                                          const SizedBox(width: 7),
                                          Text(
                                            showApproval
                                                ? '待确认执行 · 点击展开处理'
                                                : (showQuestion
                                                    ? '助手在等待你回答 · 点击展开'
                                                    : '待确认扩展运行 · 点击展开'),
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w600,
                                              color: t.warn,
                                            ),
                                          ),
                                          const SizedBox(width: 5),
                                          Icon(CupertinoIcons.chevron_up, size: 13, color: t.warn),
                                        ],
                                      ),
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(key: ValueKey('takeover-bar-empty')),
                    ),
                  ),

                  // Docked live Goal & Todo status strip (smooth disclosure, isolated leaf Consumer!)
                  GrassBagSmoothDisclosure(
                    expanded: !_plusOpen && !showExpandedTakeover,
                    child: const _LiveGoalTodoStrip(),
                  ),

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
                                      child: MediaQuery.withClampedTextScaling(
                                        maxScaleFactor: 1.2,
                                        child: Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        children: [
                                          if (showCompactNudgePill || state.isCompactingContext) ...[
                                            GrassBagGlassPillButton(
                                              tier: state.glassTier,
                                              height: 34,
                                              useOwnLayer: false,
                                              padding: const EdgeInsets.symmetric(horizontal: 11),
                                              onTap: () {
                                                if (!state.isCompactingContext) {
                                                  unawaited(ctrl.compactContext());
                                                }
                                              },
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  if (state.isCompactingContext)
                                                    const CupertinoActivityIndicator(radius: 6.5)
                                                  else
                                                    Icon(
                                                      CupertinoIcons.arrow_down_right_arrow_up_left,
                                                      size: 13,
                                                      color: state.contextPctHigh >= 90 ? t.err : t.warn,
                                                    ),
                                                  const SizedBox(width: 5),
                                                  Text(
                                                    state.isCompactingContext
                                                        ? '正在精简上下文…'
                                                        : '上下文 ${state.contextPctHigh}% · 精简',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w600,
                                                      fontFeatures: const [FontFeature.tabularFigures()],
                                                      color: state.isCompactingContext
                                                          ? t.primary
                                                          : (state.contextPctHigh >= 90 ? t.err : t.warn),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            // Separate sibling dismiss orb so closing the nudge NEVER
                                            // accidentally triggers context compaction!
                                            if (!state.isCompactingContext)
                                              GrassBagGlassCircleButton(
                                                tier: state.glassTier,
                                                size: 34,
                                                iconSize: 12.5,
                                                icon: CupertinoIcons.xmark,
                                                iconColor: t.text2,
                                                tooltip: '忽略精简提醒',
                                                useOwnLayer: false,
                                                onTap: () => setState(() => _compactNudgeDismissed = true),
                                              ),
                                          ],
                                          if (showPlanPill) ...[
                                            GrassBagGlassPillButton(
                                              tier: state.glassTier,
                                              height: 34,
                                              useOwnLayer: false,
                                              padding: const EdgeInsets.symmetric(horizontal: 12),
                                              onTap: () {
                                                if (!state.isEmptyChat && !state.isStreaming) {
                                                  HapticFeedback.mediumImpact();
                                                  unawaited(() async {
                                                    await ctrl.setPlanMode(false);
                                                    await ctrl.sendPrompt('请按上述方案开始执行。');
                                                  }());
                                                }
                                              },
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(CupertinoIcons.list_bullet_indent,
                                                      size: 13.5, color: t.dusk),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    (!state.isEmptyChat && !state.isStreaming)
                                                        ? '计划模式 · 批准并执行'
                                                        : '计划模式',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w600,
                                                      color: t.dusk,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            GrassBagGlassCircleButton(
                                              tier: state.glassTier,
                                              size: 34,
                                              iconSize: 12,
                                              icon: CupertinoIcons.xmark,
                                              iconColor: t.dusk,
                                              tooltip: '退出计划模式',
                                              useOwnLayer: false,
                                              onTap: () => ctrl.setPlanMode(false),
                                            ),
                                          ],
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
                                ),
                                if (maxDockH >= 140.0) scrollDropletWidget(inlineWithPills: true),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),

                  // Smooth height + Liquid Glass transition between Approval/Question/Cordis
                  // Takeover Cards & Floating Composer (genuine liquid_glass_widgets iOS 27 glass).
                  AnimatedSize(
                    duration: GrassBagMotion.duration(context, const Duration(milliseconds: 230)),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.bottomCenter,
                    child: AnimatedSwitcher(
                duration: GrassBagMotion.duration(context, const Duration(milliseconds: 210)),
                switchInCurve: Curves.linear,
                switchOutCurve: Curves.linear,
                layoutBuilder: (currentChild, previousChildren) {
                  final curKey = currentChild?.key;
                  return Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      for (final prev in previousChildren)
                        if (prev.key != curKey) prev,
                      if (currentChild != null) currentChild,
                    ],
                  );
                },
                transitionBuilder: (child, anim) => _ComposerSlideMaterialize(
                  animation: anim,
                  tier: state.glassTier,
                  beginOffset: _pendingSlideDir != 0
                      ? Offset(_pendingSlideDir > 0 ? 0.08 : -0.08, 0.0)
                      : const Offset(0, 0.05),
                  scaleFrom: _pendingSlideDir != 0 ? 0.98 : 0.96,
                  contentSigma: 4.5,
                  child: child,
                ),
                child: (showApproval && !_takeoverCollapsed)
                  ? _ApprovalTakeoverCard(
                      key: ValueKey(
                        'approval-${state.pendingApprovalInteractionId ?? 'none'}-${state.pendingApprovalCommand.hashCode}',
                      ),
                      command: state.pendingApprovalCommand!,
                      toolName: state.pendingApprovalToolName,
                      workspaceName: state.activeWorkspace,
                      isDirectMode: state.hostDirectMode,
                      pendingCount: state.activePendingInteractionCount,
                      pendingIndex: state.activePendingInteractionIndex,
                      onCyclePending: state.activePendingInteractionCount > 1
                          ? (delta) {
                              _pendingSlideDir = delta;
                              ctrl.cyclePendingInteraction(delta);
                            }
                          : null,
                      onCollapse: compactTakeover
                          ? () => setState(() {
                                _pendingSlideDir = 0;
                                _takeoverCollapsed = true;
                              })
                          : null,
                      maxHeight: takeoverMaxH,
                      tier: state.glassTier,
                      onDecision: ctrl.resolveApproval,
                    )
                  : (showQuestion && !_takeoverCollapsed)
                      ? _UserQuestionTakeoverCard(
                          key: ValueKey('question-${state.activeQuestion!.interactionId}'),
                          question: state.activeQuestion!,
                          pendingCount: state.activePendingInteractionCount,
                          pendingIndex: state.activePendingInteractionIndex,
                          onCyclePending: state.activePendingInteractionCount > 1
                              ? (delta) {
                                  _pendingSlideDir = delta;
                                  ctrl.cyclePendingInteraction(delta);
                                }
                              : null,
                          onCollapse: compactTakeover
                              ? () => setState(() {
                                    _pendingSlideDir = 0;
                                    _takeoverCollapsed = true;
                                  })
                              : null,
                          initialDraft:
                              _questionDraftsByInteractionId[state.activeQuestion!.interactionId],
                          onDraftChanged: (draft) {
                            _questionDraftsByInteractionId[state.activeQuestion!.interactionId] =
                                draft;
                          },
                          maxHeight: takeoverMaxH,
                          tier: state.glassTier,
                          onSubmit: (payload) async {
                            final qId = state.activeQuestion!.interactionId;
                            final ok = await ctrl.resolveUserQuestion(payload);
                            if (ok) _questionDraftsByInteractionId.remove(qId);
                            return ok;
                          },
                          onCancel: () async {
                            final qId = state.activeQuestion!.interactionId;
                            final ok = await ctrl.skipUserQuestion();
                            if (ok) _questionDraftsByInteractionId.remove(qId);
                            return ok;
                          },
                        )
                      : (showCordis && !_takeoverCollapsed)
                          ? _CordisRunTakeoverCard(
                              key: ValueKey('cordis-${state.activeCordisRequest!.interactionId}'),
                              request: state.activeCordisRequest!,
                              pendingCount: state.activePendingInteractionCount,
                              pendingIndex: state.activePendingInteractionIndex,
                              onCyclePending: state.activePendingInteractionCount > 1
                                  ? (delta) {
                                      _pendingSlideDir = delta;
                                      ctrl.cyclePendingInteraction(delta);
                                    }
                                  : null,
                              onCollapse: compactTakeover
                                  ? () => setState(() {
                                        _pendingSlideDir = 0;
                                        _takeoverCollapsed = true;
                                      })
                                  : null,
                              maxHeight: takeoverMaxH,
                              tier: state.glassTier,
                              onDecision: ctrl.resolveCordisRun,
                            )
                          : GrassBagGlass(
                              key: const ValueKey('composer-pill'),
                              tier: state.glassTier,
                              borderRadius: 28,
                              elevated: true,
                              interactiveGlow: false,
                              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                              child: AnimatedSize(
                                duration: GrassBagMotion.duration(
                                  context,
                                  const Duration(milliseconds: 180),
                                ),
                                curve: Curves.easeOutCubic,
                                alignment: Alignment.bottomCenter,
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
                                          child: GrassBagFresnelGlassSurface(
                                            borderRadius: 14,
                                            innerWell: true,
                                            tintColor: t.primarySoft,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 6,
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
                                                if (state.isStreaming) ...[
                                                  const SizedBox(width: 6),
                                                  GrassBagFresnelGlassSurface(
                                                    isPill: true,
                                                    innerWell: true,
                                                    padding: const EdgeInsets.symmetric(
                                                      horizontal: 8.5,
                                                      vertical: 4,
                                                    ),
                                                    child: Text(
                                                      state.busyEnterMode == 'steer'
                                                          ? '生成中·插话'
                                                          : '生成中·排队',
                                                      style: TextStyle(
                                                        fontSize: 10.5,
                                                        fontWeight: FontWeight.w500,
                                                        color: t.text3,
                                                      ),
                                                    ),
                                                  ),
                                                ] else if (editCtx.canForkBefore) ...[
                                                  const SizedBox(width: 6),
                                                  Tooltip(
                                                    message: _editBranchResend
                                                        ? '点击切换为在对话末尾重发'
                                                        : '点击切换为从此处分叉新分支重发',
                                                    child: GrassBagSpringTap(
                                                      enablePointerGlow: false,
                                                      haptic: true,
                                                      onTap: () => setState(
                                                        () => _editBranchResend = !_editBranchResend,
                                                      ),
                                                      child: GrassBagFresnelGlassSurface(
                                                        isPill: true,
                                                        innerWell: true,
                                                        interactive: true,
                                                        tintColor: _editBranchResend
                                                            ? t.primarySoft
                                                            : null,
                                                        padding: const EdgeInsets.symmetric(
                                                          horizontal: 8.5,
                                                          vertical: 4,
                                                        ),
                                                        child: Row(
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            Icon(
                                                              _editBranchResend
                                                                  ? CupertinoIcons.arrow_branch
                                                                  : CupertinoIcons.arrow_down_to_line,
                                                              size: 10.5,
                                                              color: _editBranchResend
                                                                  ? t.primary
                                                                  : t.text2,
                                                            ),
                                                            const SizedBox(width: 3.5),
                                                            Text(
                                                              _editBranchResend ? '分支重发' : '末尾重发',
                                                              style: TextStyle(
                                                                fontSize: 10.5,
                                                                fontWeight: FontWeight.w600,
                                                                color: _editBranchResend
                                                                    ? t.primary
                                                                    : t.text2,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ] else ...[
                                                  const SizedBox(width: 6),
                                                  GrassBagFresnelGlassSurface(
                                                    isPill: true,
                                                    innerWell: true,
                                                    padding: const EdgeInsets.symmetric(
                                                      horizontal: 8.5,
                                                      vertical: 4,
                                                    ),
                                                    child: Text(
                                                      '末尾重发',
                                                      style: TextStyle(
                                                        fontSize: 10.5,
                                                        fontWeight: FontWeight.w500,
                                                        color: t.text3,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                                const SizedBox(width: 4),
                                                Tooltip(
                                                  message: '取消编辑',
                                                  excludeFromSemantics: true,
                                                  child: Semantics(
                                                    button: true,
                                                    label: '取消编辑',
                                                    child: GrassBagSpringTap(
                                                      onTap: _cancelEditingMessage,
                                                      pressedScale: 0.88,
                                                      haptic: true,
                                                      child: SizedBox(
                                                        width: 36,
                                                        height: 36,
                                                        child: Center(
                                                          child: Icon(
                                                            CupertinoIcons.xmark,
                                                            size: 13.5,
                                                            color: t.primary,
                                                          ),
                                                        ),
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
                                  if (_pickedReferences.isNotEmpty)
                                    SizedBox(
                                      height: 36,
                                      child: ListView.separated(
                                        scrollDirection: Axis.horizontal,
                                        physics: const BouncingScrollPhysics(),
                                        padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
                                        itemCount: _pickedReferences.length,
                                        separatorBuilder: (_, __) => const SizedBox(width: 6),
                                        itemBuilder: (_, idx) {
                                          final refItem = _pickedReferences[idx];
                                          final path = (refItem['path'] ?? '').toString();
                                          final label = (refItem['label'] ?? '').toString();
                                          final isSess = refItem['kind'] == 'session';
                                          final slash = path.lastIndexOf('/');
                                          final display = label.isNotEmpty
                                              ? label
                                              : (slash >= 0 ? path.substring(slash + 1) : path);
                                          return GrassBagFresnelGlassSurface(
                                            isPill: true,
                                            innerWell: true,
                                            tintColor: isSess
                                                ? t.dusk.withValues(alpha: t.isDark ? 0.22 : 0.12)
                                                : t.primarySoft,
                                            height: 28,
                                            padding: const EdgeInsets.only(left: 8, right: 2),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  isSess
                                                      ? CupertinoIcons.chat_bubble_text_fill
                                                      : CupertinoIcons.doc_text_fill,
                                                  size: 12,
                                                  color: isSess ? t.dusk : t.primary,
                                                ),
                                                const SizedBox(width: 4.5),
                                                ConstrainedBox(
                                                  constraints: const BoxConstraints(maxWidth: 160),
                                                  child: Text(
                                                    display,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontFamily: isSess ? null : 'monospace',
                                                      fontSize: 11.5,
                                                      fontWeight: FontWeight.w600,
                                                      color: isSess ? t.dusk : t.primary,
                                                    ),
                                                  ),
                                                ),
                                                GrassBagSpringTap(
                                                  pressedScale: 0.86,
                                                  enablePointerGlow: false,
                                                  haptic: true,
                                                  onTap: () => _removePickedReference(path),
                                                  child: SizedBox(
                                                    width: 26,
                                                    height: 28,
                                                    child: Center(
                                                      child: Icon(
                                                        CupertinoIcons.xmark,
                                                        size: 11,
                                                        color: isSess ? t.dusk : t.primary,
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
                                  if (state.pendingAttachments.isNotEmpty)
                                    AnimatedContainer(
                                      duration: GrassBagMotion.duration(
                                        context,
                                        const Duration(milliseconds: 180),
                                      ),
                                      curve: Curves.easeOutCubic,
                                      height: state.pendingAttachments.any(
                                        (a) => a.isImage && a.bytes != null && a.bytes!.isNotEmpty,
                                      )
                                          ? 70
                                          : 46,
                                      child: ShaderMask(
                                        blendMode: BlendMode.dstIn,
                                        shaderCallback: (bounds) => const LinearGradient(
                                          begin: Alignment.centerLeft,
                                          end: Alignment.centerRight,
                                          colors: [Colors.white, Colors.white, Colors.transparent],
                                          stops: [0.0, 0.90, 1.0],
                                        ).createShader(bounds),
                                        child: ListView.separated(
                                          scrollDirection: Axis.horizontal,
                                          physics: const BouncingScrollPhysics(),
                                          padding: const EdgeInsets.fromLTRB(6, 5, 18, 5),
                                              itemCount: state.pendingAttachments.length,
                                              separatorBuilder: (_, __) => const SizedBox(width: 8),
                                              itemBuilder: (_, idx) {
                                                final att = state.pendingAttachments[idx];
                                                final fileKind = classifyPreviewFile(
                                                  att.name,
                                                  mimeType: att.mimeType,
                                                );
                                                final hasImgBytes = fileKind == PreviewFileKind.rasterImage &&
                                                    att.bytes != null &&
                                                    att.bytes!.isNotEmpty;
                                                if (hasImgBytes) {
                                                  // Keep the 22x22 corner remove button outside the
                                                  // 48x48 thumbnail center so tapping the photo opens
                                                  // the multi-image lightbox without accidental delete!
                                                  final galleryItems = <GrassBagImagePreviewItem>[];
                                                  var galleryStartIdx = 0;
                                                  for (final p in state.pendingAttachments) {
                                                    final pk = classifyPreviewFile(
                                                      p.name,
                                                      mimeType: p.mimeType,
                                                    );
                                                    if (pk == PreviewFileKind.rasterImage &&
                                                        p.bytes != null &&
                                                        p.bytes!.isNotEmpty) {
                                                      if (p.id == att.id) {
                                                        galleryStartIdx = galleryItems.length;
                                                      }
                                                      galleryItems.add(
                                                        GrassBagImagePreviewItem(
                                                          bytes: p.bytes,
                                                          title: p.name,
                                                          mimeType: p.mimeType,
                                                        ),
                                                      );
                                                    }
                                                  }
                                                  return SizedBox(
                                                    width: 60,
                                                    height: 60,
                                                    child: Stack(
                                                      children: [
                                                        Positioned(
                                                          left: 0,
                                                          bottom: 0,
                                                          child: GestureDetector(
                                                            onTap: () => showImagePreviewDialog(
                                                              context,
                                                              items: galleryItems,
                                                              initialIndex: galleryStartIdx,
                                                            ),
                                                            child: Container(
                                                              width: 48,
                                                              height: 48,
                                                              decoration: ShapeDecoration(
                                                                shape: RoundedSuperellipseBorder(
                                                                  borderRadius: BorderRadius.circular(12),
                                                                  side: BorderSide(
                                                                    color: t.primary.withValues(alpha: 0.35),
                                                                    width: 0.8,
                                                                  ),
                                                                ),
                                                              ),
                                                              clipBehavior: Clip.antiAlias,
                                                              child: Image.memory(
                                                                att.bytes!,
                                                                cacheWidth: 144,
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
                                                          child: Semantics(
                                                            button: true,
                                                            label: '移除附件',
                                                            child: Tooltip(
                                                              message: '移除附件',
                                                              excludeFromSemantics: true,
                                                              child: GestureDetector(
                                                                behavior: HitTestBehavior.opaque,
                                                                onTap: () {
                                                                  HapticFeedback.selectionClick();
                                                                  ctrl.removePendingAttachment(att.id);
                                                                },
                                                                child: SizedBox(
                                                                  width: 24,
                                                                  height: 24,
                                                                  child: Align(
                                                                    alignment: Alignment.topRight,
                                                                    child: GrassBagFresnelGlassSurface(
                                                                      isCircle: true,
                                                                      elevated: true,
                                                                      width: 20,
                                                                      height: 20,
                                                                      alignment: Alignment.center,
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
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                }
                                                final canPreviewBytes =
                                                    att.bytes != null && att.bytes!.isNotEmpty;
                                                return Center(
                                                  child: GrassBagFresnelGlassSurface(
                                                    isPill: true,
                                                    innerWell: true,
                                                    tintColor: t.primarySoft,
                                                    height: 34,
                                                    padding: const EdgeInsets.only(left: 10, right: 0),
                                                    child: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        GestureDetector(
                                                          behavior: HitTestBehavior.opaque,
                                                          onTap: canPreviewBytes
                                                              ? () {
                                                                  HapticFeedback.selectionClick();
                                                                  showMemoryFilePreviewSheet(
                                                                    context,
                                                                    name: att.name,
                                                                    bytes: att.bytes!,
                                                                    mimeType: att.mimeType,
                                                                  );
                                                                }
                                                              : null,
                                                          child: Row(
                                                            mainAxisSize: MainAxisSize.min,
                                                            children: [
                                                              Icon(
                                                                previewFileIcon(
                                                                  att.name,
                                                                  mimeType: att.mimeType,
                                                                ),
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
                                                                    fontFeatures: const [
                                                                      FontFeature.tabularFigures(),
                                                                    ],
                                                                    color: t.primary.withValues(alpha: 0.72),
                                                                  ),
                                                                ),
                                                              ],
                                                            ],
                                                          ),
                                                        ),
                                                        Tooltip(
                                                          message: '移除附件',
                                                          child: GestureDetector(
                                                            behavior: HitTestBehavior.opaque,
                                                            onTap: () {
                                                              HapticFeedback.selectionClick();
                                                              ctrl.removePendingAttachment(att.id);
                                                            },
                                                            child: SizedBox(
                                                              width: 34,
                                                              height: 34,
                                                              child: Center(
                                                                child: Icon(
                                                                  CupertinoIcons.xmark_circle_fill,
                                                                  size: 15.5,
                                                                  color: t.primary.withValues(alpha: 0.78),
                                                                ),
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
                                      ),
                                    ),
                                  if (state.queuedMessages.isNotEmpty)
                                    Padding(
                                            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                                            child: GrassBagFresnelGlassSurface(
                                              borderRadius: 15,
                                              innerWell: true,
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
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
                                                                decoration: ShapeDecoration(
                                                                  color: q.mode == 'steer'
                                                                      ? t.primarySoft
                                                                      : t.fill2,
                                                                  shape: RoundedSuperellipseBorder(
                                                                    borderRadius: BorderRadius.circular(7),
                                                                    side: BorderSide(
                                                                      color: q.mode == 'steer'
                                                                          ? t.primary.withValues(alpha: 0.28)
                                                                          : t.sep,
                                                                      width: 0.55,
                                                                    ),
                                                                  ),
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
                                                                    q.text.replaceAll('\n', ' '),
                                                                    maxLines: 1,
                                                                    overflow: TextOverflow.ellipsis,
                                                                    style: TextStyle(fontSize: 12.5, color: t.text),
                                                                  ),
                                                                ),
                                                              ),
                                                              Tooltip(
                                                                message: '编辑待发消息',
                                                                child: GrassBagSpringTap(
                                                                  pressedScale: 0.88,
                                                                  haptic: true,
                                                                  onTap: () => _showEditQueuedDialog(context, q),
                                                                  child: SizedBox(
                                                                    width: 36,
                                                                    height: 36,
                                                                    child: Center(
                                                                      child: Icon(CupertinoIcons.pencil, size: 13.5, color: t.text3),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                              if (q.mode != 'steer') ...[
                                                                const SizedBox(width: 4),
                                                                GrassBagSpringTap(
                                                                  enablePointerGlow: false,
                                                                  haptic: true,
                                                                  onTap: () => ctrl.promoteQueuedMessage(q.id),
                                                                  child: GrassBagFresnelGlassSurface(
                                                                    isPill: true,
                                                                    innerWell: true,
                                                                    interactive: true,
                                                                    tintColor: t.primarySoft,
                                                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                                                    child: Text(
                                                                      '改插话',
                                                                      style: TextStyle(
                                                                        fontSize: 11,
                                                                        fontWeight: FontWeight.w600,
                                                                        color: t.primary,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ],
                                                              const SizedBox(width: 6),
                                                              Tooltip(
                                                                message: '移出队列',
                                                                child: GrassBagSpringTap(
                                                                  pressedScale: 0.88,
                                                                  haptic: true,
                                                                  onTap: () => ctrl.removeQueuedMessage(q.id),
                                                                  child: SizedBox(
                                                                    width: 36,
                                                                    height: 36,
                                                                    child: Center(
                                                                      child: Icon(CupertinoIcons.xmark, size: 13.5, color: t.text3),
                                                                    ),
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
                                        if (_streamModeDeckOpen) {
                                          _setStreamModeDeckOpen(false);
                                        }
                                        if (!widget.focusNode.hasFocus) {
                                          widget.focusNode.requestFocus();
                                        }
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment: CrossAxisAlignment.stretch,
                                          children: [
                                            Scrollbar(
                                              controller: _inputScrollCtrl,
                                              radius: const Radius.circular(3),
                                              thickness: 2.5,
                                              child: TextField(
                                                scrollController: _inputScrollCtrl,
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
                                                },
                                              ),
                                              style: TextStyle(
                                                fontSize: 15,
                                                height: 1.4,
                                                letterSpacing: -0.15,
                                                color: t.text,
                                              ),
                                              decoration: InputDecoration(
                                                hintMaxLines: 1,
                                                hintText: state.isStopping
                                                    ? '正在停止当前生成…'
                                                    : (isHostNeedsAuth
                                                        ? '请点击下方「待授权」完成授权…'
                                                        : (needsModelConfig
                                                            ? '登录 DeepSeek 或添加 API Key 后即可对话…'
                                                            : (state.pendingAttachments.isNotEmpty
                                                                ? '添加说明，或直接发送附件…'
                                                                : (state.isStreaming
                                                                    ? (state.busyEnterMode == 'steer'
                                                                        ? '生成中，输入内容可直接插话…'
                                                                        : '生成中，输入内容可排队发送…')
                                                                    : (state.planMode
                                                                        ? '计划模式：先出方案，确认后执行…'
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
                                                      const EdgeInsets.symmetric(vertical: 4),
                                                  border: InputBorder.none,
                                                ),
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
                          MediaQuery.withClampedTextScaling(
                            maxScaleFactor: 1.25,
                            child: LayoutBuilder(
                            builder: (ctx, rowBox) {
                              final hasExtraStreamActions =
                                  (state.isStreaming || state.isStopping) && hasText;
                              final veryTightRow = rowBox.maxWidth < 240;
                              final tightRow = rowBox.maxWidth < (hasExtraStreamActions ? 416 : 316);
                              final showInlineRing =
                                  !veryTightRow && !(tightRow && hasExtraStreamActions);
                              return Row(
                            children: [
                              // Clean borderless Apple iOS 27 concentric '+' orb inside the floating glass composer
                              // (ZERO nested wireframe rings — rotates 45° into accented '×' when open!)
                              () {
                                final effectiveTier =
                                    resolveEffectiveGlassTier(context, state.glassTier);
                                final isSolid = effectiveTier == GrassBagGlassTier.solid;
                                final plusIcon = AnimatedRotation(
                                  turns: _plusOpen ? 0.125 : 0.0,
                                  duration: GrassBagMotion.duration(
                                    context,
                                    const Duration(milliseconds: 260),
                                  ),
                                  curve: Curves.easeOutBack,
                                  child: Icon(
                                    CupertinoIcons.plus,
                                    size: 19,
                                    color: _plusOpen ? t.primary : t.text2,
                                  ),
                                );
                                final plusBtn = GrassBagSpringTap(
                                  key: const ValueKey('composer-plus-btn'),
                                  onTap: _togglePlus,
                                  pressedScale: 0.88,
                                  enablePointerGlow: false,
                                  haptic: true,
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 220),
                                    curve: Curves.easeOutCubic,
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: _plusOpen
                                          ? t.primary.withValues(alpha: t.isDark ? 0.26 : 0.16)
                                          : (t.isDark
                                              ? Colors.white.withValues(alpha: 0.10)
                                              : Colors.black.withValues(alpha: 0.055)),
                                      shape: BoxShape.circle,
                                      border: isSolid
                                          ? Border.all(
                                              color: _plusOpen
                                                  ? t.primary.withValues(alpha: t.isDark ? 0.42 : 0.28)
                                                  : t.sep,
                                              width: 0.65,
                                            )
                                          : null,
                                    ),
                                    child: plusIcon,
                                  ),
                                );
                                return Tooltip(
                                  message: _plusOpen ? '收起快捷面板' : '添加附件与快捷选项',
                                  excludeFromSemantics: true,
                                  child: Semantics(
                                    button: true,
                                    label: _plusOpen ? '收起快捷面板' : '添加附件与快捷选项',
                                    child: plusBtn,
                                  ),
                                );
                              }(),
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
                                      final effectiveTier =
                                          resolveEffectiveGlassTier(context, state.glassTier);
                                      final modelRow = Row(
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
                                            Tooltip(
                                              message: state.canCycleEffort
                                                  ? '点击快速切换思考深度'
                                                  : '当前思考深度',
                                              child: GestureDetector(
                                                behavior: HitTestBehavior.opaque,
                                                onTap: state.canCycleEffort
                                                    ? () {
                                                        HapticFeedback.selectionClick();
                                                        if (_plusOpen) _setPlusOpen(false);
                                                        unawaited(ctrl.cycleReasoningEffort());
                                                      }
                                                    : null,
                                                child: GrassBagFresnelGlassSurface(
                                                  isPill: true,
                                                  innerWell: true,
                                                  tintColor: t.primarySoft,
                                                  padding: const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 2,
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
                                              ),
                                            ),
                                          ],
                                          const SizedBox(width: 3),
                                          Icon(CupertinoIcons.chevron_down, size: 11, color: t.text3),
                                        ],
                                      );
                                      final isSolid = effectiveTier == GrassBagGlassTier.solid;
                                      return GrassBagSpringTap(
                                        onTap: () {
                                          if (_plusOpen) _setPlusOpen(false);
                                          pillTap();
                                        },
                                        pressedScale: 0.94,
                                        enablePointerGlow: false,
                                        haptic: true,
                                        child: Container(
                                          height: 36,
                                          padding: EdgeInsets.symmetric(horizontal: tightRow ? 9 : 11),
                                          decoration: ShapeDecoration(
                                            color: t.isDark
                                                ? Colors.white.withValues(alpha: 0.09)
                                                : Colors.black.withValues(alpha: 0.055),
                                            shape: StadiumBorder(
                                              side: isSolid
                                                  ? BorderSide(color: t.sep, width: 0.65)
                                                  : BorderSide.none,
                                            ),
                                          ),
                                          child: modelRow,
                                        ),
                                      );
                                  }(),
                                ),
                              ),
                              const SizedBox(width: 6),

                              // Isolated RepaintBoundary Context Ring (smooth horizontal slot morph!)
                              _AnimatedToolbarSlot(
                                visible: showInlineRing,
                                child: _ComposerContextRingButton(
                                  onBeforeOpen: () {
                                    if (_plusOpen) _setPlusOpen(false);
                                    if (_streamModeDeckOpen) _setStreamModeDeckOpen(false);
                                  },
                                ),
                              ),

                              // Compact Stop orb cleanly separated to the LEFT of the Send+Mode group
                              // so tapping Send/Mode NEVER risks an accidental destructive Stop!
                              _AnimatedToolbarSlot(
                                visible: (state.isStreaming || state.isStopping) && hasText,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Tooltip(
                                    message: state.isStopping ? '正在停止生成…' : '停止当前生成',
                                    child: GrassBagSpringTap(
                                      enabled: !state.isStopping,
                                      enablePointerGlow: false,
                                      onTap: () {
                                        if (state.isStopping) return;
                                        HapticFeedback.lightImpact();
                                        _setStreamModeDeckOpen(false);
                                        _flushDraftSync();
                                        ctrl.cancelStreaming();
                                      },
                                      pressedScale: 0.88,
                                      child: GrassBagFresnelGlassSurface(
                                        isCircle: true,
                                        innerWell: true,
                                        interactive: false,
                                        tintColor: t.errSoft,
                                        width: 36,
                                        height: 36,
                                        alignment: Alignment.center,
                                        child: state.isStopping
                                            ? Center(
                                                child: GrassBagActivityIndicator(
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
                                ),
                              ),

                              // Attached Steer / Queue / Interrupt mode trigger grouped directly beside Send!
                              _AnimatedToolbarSlot(
                                visible: state.isStreaming && hasText,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Tooltip(
                                    message: '选择发送方式：插话、排队或打断',
                                    child: GrassBagSpringTap(
                                      onTap: () {
                                        HapticFeedback.selectionClick();
                                        _setStreamModeDeckOpen(!_streamModeDeckOpen);
                                      },
                                      pressedScale: 0.94,
                                      enablePointerGlow: false,
                                      haptic: true,
                                      child: GrassBagFresnelGlassSurface(
                                        isPill: true,
                                        innerWell: true,
                                        interactive: false,
                                        tintColor: _streamModeDeckOpen
                                            ? t.primary.withValues(alpha: t.isDark ? 0.28 : 0.18)
                                            : t.primarySoft,
                                        height: 36,
                                        padding: EdgeInsets.symmetric(horizontal: tightRow ? 9 : 11),
                                        alignment: Alignment.center,
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
                                            AnimatedRotation(
                                              turns: _streamModeDeckOpen ? 0.5 : 0.0,
                                              duration: GrassBagMotion.duration(
                                                context,
                                                const Duration(milliseconds: 180),
                                              ),
                                              curve: Curves.easeOutCubic,
                                              child: Icon(
                                                CupertinoIcons.chevron_up,
                                                size: 10.5,
                                                color: t.primary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                              // Concentric Action Orb (Send / Steer / Queue / Stop / Mic when speech is configured)
                              () {
                                final isStopOrb = (state.isStreaming || state.isStopping) && !hasText;
                                final isFollowUpSend = state.isStreaming && hasText;
                                final showPrimarySpinner = _submitting && !isStopOrb;
                                final orbInteractive = !state.isStopping &&
                                    (hasText || state.isStreaming || state.speechConfigured);
                                final orbEnabled = isStopOrb
                                    ? !state.isStopping
                                    : (!state.isStopping &&
                                        !_submitting &&
                                        (hasText || state.speechConfigured));
                                final primaryActive = (hasText && !state.isStopping) || showPrimarySpinner;
                                final sendIcon = (isFollowUpSend && state.busyEnterMode == 'steer')
                                    ? CupertinoIcons.arrow_turn_down_right
                                    : CupertinoIcons.arrow_up;
                                final orbTooltip = isStopOrb
                                    ? (state.isStopping ? '正在停止生成…' : '停止生成')
                                    : (state.isStopping
                                        ? '正在停止上一轮生成…'
                                        : (isFollowUpSend
                                            ? (state.busyEnterMode == 'steer' ? '插话发送' : '排队发送')
                                            : (hasText
                                                ? '发送消息'
                                                : (state.speechConfigured ? '语音输入' : '发送消息'))));
                                final effectiveTier =
                                    resolveEffectiveGlassTier(context, state.glassTier);
                                final orbChild = AnimatedSwitcher(
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
                                      ? GrassBagActivityIndicator(
                                          key: const ValueKey('sending'),
                                          radius: 7.5,
                                          color: t.onPrimary,
                                        )
                                      : (isStopOrb && state.isStopping)
                                          ? GrassBagActivityIndicator(
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
                                );
                                void handleOrbTap() {
                                  if (isStopOrb) {
                                    if (state.isStopping) return;
                                    HapticFeedback.lightImpact();
                                    _flushDraftSync();
                                    ctrl.cancelStreaming();
                                  } else if (_submitting || state.isStopping) {
                                    return;
                                  } else if (hasText) {
                                    _submit();
                                  } else if (state.speechConfigured) {
                                    _openVoiceInput();
                                  }
                                }
                                final isSolid = effectiveTier == GrassBagGlassTier.solid;
                                return Tooltip(
                                  message: orbTooltip,
                                  child: GrassBagSpringTap(
                                    key: const ValueKey('composer-action-btn'),
                                    enabled: orbEnabled,
                                    enablePointerGlow: false,
                                    pressedScale: orbInteractive ? 0.88 : 1.0,
                                    onTap: handleOrbTap,
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 220),
                                      curve: Curves.easeOutCubic,
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: primaryActive
                                              ? [
                                                  Color.lerp(t.primaryHi, Colors.white, t.isDark ? 0.10 : 0.14)!,
                                                  t.primary,
                                                ]
                                              : (isStopOrb
                                                  ? [t.errSoft, t.errSoft]
                                                  : (t.isDark
                                                      ? [
                                                          Colors.white.withValues(alpha: 0.11),
                                                          Colors.white.withValues(alpha: 0.09),
                                                        ]
                                                      : [
                                                          Colors.black.withValues(alpha: 0.06),
                                                          Colors.black.withValues(alpha: 0.05),
                                                        ])),
                                        ),
                                        shape: BoxShape.circle,
                                        border: isSolid && !primaryActive
                                            ? Border.all(
                                                color: isStopOrb
                                                    ? t.err.withValues(alpha: 0.30)
                                                    : t.sep,
                                                width: 0.65,
                                              )
                                            : null,
                                        boxShadow: primaryActive
                                            ? [
                                                BoxShadow(
                                                  color: t.primary.withValues(alpha: t.isDark ? 0.34 : 0.26),
                                                  blurRadius: 10,
                                                  offset: const Offset(0, 3),
                                                ),
                                              ]
                                            : null,
                                      ),
                                      child: orbChild,
                                    ),
                                  ),
                                );
                            }(),
                            ],
                          );
                            },
                          ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
                ],
              );
                if (isTightDock && !showExpandedTakeover) {
                  return ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: math.max(80.0, maxDockH)),
                    child: SingleChildScrollView(
                      clipBehavior: Clip.hardEdge,
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
      pressedScale: 0.92,
      enablePointerGlow: false,
      haptic: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GrassBagSquircleIcon(
              icon: icon,
              color: color,
              size: 48,
              iconSize: 22,
              filled: true,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9.5),
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
    this.onOpenVoice,
  });

  final VoidCallback onClose;
  final VoidCallback onOpenTerminal;
  final VoidCallback? onOpenVoice;

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
      // Concentric geometry: outer 30pt − 12px padding = 18pt inner bento & section radius!
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _PlusQuickAction(
                  icon: CupertinoIcons.photo_fill,
                  color: t.isDark ? const Color(0xFF2578C8) : const Color(0xFF2B7FC3),
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
                    color: t.isDark ? const Color(0xFF5865DF) : const Color(0xFF535EC0),
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
                  color: t.isDark ? const Color(0xFF178E68) : const Color(0xFF2D8A7B),
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
                  color: t.isDark ? const Color(0xFF475D75) : const Color(0xFF3E5368),
                  label: '终端',
                  onTap: () {
                    onClose();
                    onOpenTerminal();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Concentric luminous well keeps rows crystal-legible over busy Home cards
          GrassBagSheetSection(
            borderRadius: 18,
            padding: const EdgeInsets.symmetric(vertical: 3),
            children: [
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
              Divider(height: 0.5, indent: 52, endIndent: 12, color: t.sep),
              _PopoverActionRow(
                icon: perm.risky
                    ? CupertinoIcons.exclamationmark_shield_fill
                    : (perm.id == 'read-only'
                        ? CupertinoIcons.lock_shield_fill
                        : CupertinoIcons.checkmark_shield_fill),
                iconColor: perm.risky
                    ? t.warn
                    : (perm.id == 'read-only' ? t.text2 : t.ok),
                title: '操作权限',
                trailingText: perm.name,
                warnTrailing: perm.risky,
                onTap: () {
                  onClose();
                  showPermissionSheet(context, ref);
                },
              ),
              if (onOpenVoice != null) ...[
                Divider(height: 0.5, indent: 52, endIndent: 12, color: t.sep),
                _PopoverActionRow(
                  icon: CupertinoIcons.mic_fill,
                  iconColor: t.primary,
                  title: '语音输入',
                  trailingText: '听写插入',
                  onTap: () {
                    onClose();
                    onOpenVoice!();
                  },
                ),
              ],
              Divider(height: 0.5, indent: 52, endIndent: 12, color: t.sep),
              Semantics(
                toggled: slice.planMode,
                label: '计划模式',
                hint: '先规划步骤再动手执行',
                child: GrassBagSpringTap(
                  pressedScale: 0.985,
                  enablePointerGlow: false,
                  haptic: true,
                  borderRadius: 12,
                  onTap: () {
                    ctrl.setPlanMode(!slice.planMode);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TakeoverPendingSwitcher extends StatelessWidget {
  const _TakeoverPendingSwitcher({
    required this.index,
    required this.count,
    required this.color,
    required this.tintColor,
    this.onCycle,
  });

  final int index;
  final int count;
  final Color color;
  final Color tintColor;
  final void Function(int delta)? onCycle;

  @override
  Widget build(BuildContext context) {
    final safeIdx = index.clamp(0, math.max(0, count - 1));
    final pill = GrassBagFresnelGlassSurface(
      isPill: true,
      innerWell: true,
      tintColor: tintColor,
      padding: EdgeInsets.symmetric(horizontal: onCycle != null ? 5 : 8.5, vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onCycle != null)
            GrassBagSpringTap(
              pressedScale: 0.85,
              enablePointerGlow: false,
              haptic: true,
              onTap: () => onCycle!(-1),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                child: Icon(CupertinoIcons.chevron_left, size: 11, color: color),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: AnimatedSwitcher(
              duration: GrassBagMotion.duration(context, const Duration(milliseconds: 160)),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: Text(
                '${safeIdx + 1} / $count',
                key: ValueKey('$safeIdx-$count'),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: color,
                ),
              ),
            ),
          ),
          if (onCycle != null)
            GrassBagSpringTap(
              pressedScale: 0.85,
              enablePointerGlow: false,
              haptic: true,
              onTap: () => onCycle!(1),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                child: Icon(CupertinoIcons.chevron_right, size: 11, color: color),
              ),
            ),
        ],
      ),
    );
    return Tooltip(
      message: onCycle != null ? '切换待确认事项' : '共 $count 项待确认',
      child: pill,
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
    this.pendingIndex = 0,
    this.onCyclePending,
    this.onCollapse,
    this.maxHeight = 560.0,
    required this.tier,
    required this.onDecision,
  });

  final String command;
  final String? toolName;
  final String workspaceName;
  final bool isDirectMode;
  final int pendingCount;
  final int pendingIndex;
  final void Function(int delta)? onCyclePending;
  final VoidCallback? onCollapse;
  final double maxHeight;
  final GrassBagGlassTier tier;
  final Future<bool> Function(String) onDecision;

  @override
  State<_ApprovalTakeoverCard> createState() => _ApprovalTakeoverCardState();
}

class _ApprovalTakeoverCardState extends State<_ApprovalTakeoverCard> {
  DateTime _mountedAt = DateTime.now();
  bool _decided = false;
  bool _copied = false;
  Timer? _copiedResetTimer;

  static final RegExp _dangerCmdPattern = RegExp(
    r'(^|\s)(rm\s+-[a-zA-Z]*[rf]|sudo\s|mkfs|dd\s+if=|shutdown|reboot|chmod\s+777|drop\s+table|truncate\s+table|git\s+reset\s+--hard|git\s+push\s+.*(?:-f|--force)\b)|(?:curl|wget)\s+[^|\n]*\|\s*(?:ba)?sh\b',
    caseSensitive: false,
  );

  @override
  void didUpdateWidget(covariant _ApprovalTakeoverCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.command != widget.command || oldWidget.toolName != widget.toolName) {
      _decided = false;
      _copied = false;
      _mountedAt = DateTime.now();
    }
  }

  @override
  void dispose() {
    _copiedResetTimer?.cancel();
    super.dispose();
  }

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

  void _copyCommand() {
    unawaited(Clipboard.setData(ClipboardData(text: widget.command)));
    HapticFeedback.selectionClick();
    _copiedResetTimer?.cancel();
    setState(() => _copied = true);
    _copiedResetTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  static TextSpan _buildApprovalPreviewSpan(
    String raw, {
    required bool isFileTool,
    required Color baseColor,
    required GrassBagTokens t,
  }) {
    final hasDiffLines = isFileTool ||
        raw.contains('\n+ ') ||
        raw.contains('\n- ') ||
        raw.startsWith('+ ') ||
        raw.startsWith('- ');
    if (!hasDiffLines) {
      return TextSpan(text: raw);
    }
    final lines = raw.split('\n');
    final spans = <InlineSpan>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final suffix = i < lines.length - 1 ? '\n' : '';
      if (line.startsWith('@@')) {
        spans.add(TextSpan(
          text: '$line$suffix',
          style: TextStyle(color: t.primary, fontWeight: FontWeight.w600),
        ));
      } else if (line.startsWith('+') && !line.startsWith('+++')) {
        spans.add(TextSpan(
          text: '$line$suffix',
          style: TextStyle(
            color: t.ok,
            backgroundColor: t.okSoft.withValues(alpha: t.isDark ? 0.34 : 0.48),
          ),
        ));
      } else if (line.startsWith('-') && !line.startsWith('---')) {
        spans.add(TextSpan(
          text: '$line$suffix',
          style: TextStyle(
            color: t.err,
            backgroundColor: t.errSoft.withValues(alpha: t.isDark ? 0.34 : 0.48),
          ),
        ));
      } else if (line.startsWith('目标：')) {
        spans.add(TextSpan(
          text: '$line$suffix',
          style: TextStyle(color: t.text, fontWeight: FontWeight.w600),
        ));
      } else {
        spans.add(TextSpan(text: '$line$suffix', style: TextStyle(color: baseColor)));
      }
    }
    return TextSpan(children: spans);
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
    final isDangerCmd = !isPhoneTool && _dangerCmdPattern.hasMatch(widget.command);

    final headerTitle = isDangerCmd
        ? '高风险操作授权'
        : (isPhoneTool
            ? '请求操控手机'
            : (isFileTool
                ? '请求修改文件'
                : (isCmdTool ? '请求执行命令' : '请求调用工具')));
    final badgeColor = isDangerCmd
        ? t.err
        : (isPhoneTool
            ? t.primary
            : (isFileTool ? t.dusk : (isCmdTool ? t.warn : t.primary)));
    final badgeIcon = isDangerCmd
        ? CupertinoIcons.exclamationmark_shield_fill
        : (isPhoneTool
            ? CupertinoIcons.device_phone_portrait
            : (isFileTool
                ? CupertinoIcons.doc_text_fill
                : (isCmdTool
                    ? CupertinoIcons.chevron_left_slash_chevron_right
                    : CupertinoIcons.shield_lefthalf_fill)));
    final wellEyebrow = isDangerCmd
        ? '敏感指令 · 请仔细核对'
        : (isPhoneTool
            ? '操控指令预览'
            : (isFileTool ? '文件变更内容' : '即将执行的命令'));

    final showAllowSession = !isPhoneTool && !isDangerCmd;
    final maxCardH = widget.maxHeight;
    final compactCard = maxCardH < 280.0;

    final wellBg = t.isDark
        ? Colors.black.withValues(alpha: 0.34)
        : Colors.white.withValues(alpha: 0.78);
    final wellBorder = isDangerCmd
        ? t.err.withValues(alpha: t.isDark ? 0.34 : 0.28)
        : (t.isDark
            ? Colors.white.withValues(alpha: 0.14)
            : Colors.white.withValues(alpha: 0.94));
    final wellCodeColor = t.codeFg;

    return GlassBackdropGroup(
      enabled: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxCardH),
        child: GrassBagGlass(
          tier: widget.tier,
          borderRadius: 30,
          elevated: true,
          interactiveGlow: false,
          useSheetSettings: true,
          // Concentric geometry: 30pt outer − 14px horizontal padding = 16pt inner command well!
          padding: EdgeInsets.fromLTRB(14, compactCard ? 12 : 16, 14, compactCard ? 12 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  GrassBagSquircleIcon(
                    icon: badgeIcon,
                    color: badgeColor,
                    size: 40,
                    iconSize: 19,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          headerTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.25,
                            color: t.text,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                isPhoneTool
                                    ? '无障碍安全确认'
                                    : (widget.workspaceName.trim().isEmpty
                                        ? '当前工作区'
                                        : '工作区：${widget.workspaceName}'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: t.text3,
                                ),
                              ),
                            ),
                            if (rawTool.isNotEmpty) ...[
                              const SizedBox(width: 7),
                              Flexible(
                                flex: 0,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 150),
                                  child: GrassBagFresnelGlassSurface(
                                    isPill: true,
                                    innerWell: true,
                                    tintColor: badgeColor.withValues(alpha: t.isDark ? 0.18 : 0.11),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7.5,
                                      vertical: 2,
                                    ),
                                    child: Text(
                                      rawTool,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        color: badgeColor,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (widget.pendingCount > 1) ...[
                    const SizedBox(width: 8),
                    _TakeoverPendingSwitcher(
                      index: widget.pendingIndex,
                      count: widget.pendingCount,
                      color: badgeColor,
                      tintColor: badgeColor.withValues(alpha: t.isDark ? 0.20 : 0.12),
                      onCycle: widget.onCyclePending,
                    ),
                  ],
                  if (widget.onCollapse != null) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: '收起查看对话',
                      child: GrassBagSpringTap(
                        onTap: widget.onCollapse!,
                        pressedScale: 0.90,
                        child: GrassBagFresnelGlassSurface(
                          isPill: true,
                          innerWell: true,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(CupertinoIcons.chevron_down, size: 11.5, color: t.text2),
                              const SizedBox(width: 3),
                              Text(
                                '收起',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: t.text2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              // Adaptive crystal command/action preview well (luminous pearl in Light, smoked obsidian in Dark)
              Flexible(
                child: CustomPaint(
                  foregroundPainter: widget.tier == GrassBagGlassTier.solid
                      ? null
                      : GrassBagFresnelRimPainter(
                          isDark: t.isDark,
                          borderRadius: 16,
                          accent: badgeColor,
                          innerWell: true,
                          frosted: widget.tier == GrassBagGlassTier.frosted,
                          paintTopSheen: false,
                          strokeWidth: 0.8,
                        ),
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 184),
                    decoration: ShapeDecoration(
                      color: wellBg,
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: widget.tier == GrassBagGlassTier.solid
                            ? BorderSide(color: wellBorder, width: 0.8)
                            : BorderSide.none,
                      ),
                      shadows: t.isDark
                          ? null
                          : const [
                              BoxShadow(
                                color: Color(0x0A0E2235),
                                blurRadius: 10,
                                offset: Offset(0, 2),
                              ),
                            ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 8, 7),
                          child: Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: badgeColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  wellEyebrow,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: isDangerCmd ? t.err : t.text3,
                                  ),
                                ),
                              ),
                              GrassBagSpringTap(
                                onTap: _copyCommand,
                                pressedScale: 0.92,
                                enablePointerGlow: false,
                                haptic: true,
                                child: GrassBagFresnelGlassSurface(
                                  isPill: true,
                                  innerWell: true,
                                  interactive: true,
                                  tintColor: _copied ? t.okSoft : null,
                                  padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 3.5),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _copied
                                            ? CupertinoIcons.checkmark_alt
                                            : CupertinoIcons.doc_on_doc,
                                        size: 11,
                                        color: _copied ? t.ok : t.text2,
                                      ),
                                      const SizedBox(width: 3.5),
                                      Text(
                                        _copied ? '已复制' : '复制',
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w600,
                                          color: _copied ? t.ok : t.text2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(
                          height: 0.6,
                          thickness: 0.6,
                          color: t.isDark
                              ? Colors.white.withValues(alpha: 0.09)
                              : const Color(0x14132C44),
                        ),
                        Flexible(
                          child: _ScrollableCommandWell(
                            fadeColor: wellBg,
                            child: SelectableText.rich(
                              _buildApprovalPreviewSpan(
                                widget.command,
                                isFileTool: isFileTool,
                                baseColor: wellCodeColor,
                                t: t,
                              ),
                              contextMenuBuilder: buildGrassBagEditableContextMenu,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12.4,
                                height: 1.5,
                                color: wellCodeColor,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(height: compactCard ? 10 : 15),
              if (showAllowSession && compactCard)
                Row(
                  children: [
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: '拒绝',
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tier: widget.tier,
                        insideGlass: true,
                        destructive: true,
                        enabled: !_decided,
                        onTap: () => unawaited(_handleTap('deny')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: '本会话',
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tier: widget.tier,
                        insideGlass: true,
                        accentForeground: true,
                        enabled: !_decided,
                        onTap: () => unawaited(_handleTap('always')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GrassBagPrimaryGlassButton(
                        label: _decided ? '处理中…' : '允许',
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        tier: widget.tier,
                        insideGlass: true,
                        enabled: !_decided,
                        onTap: () => unawaited(_handleTap('allow')),
                      ),
                    ),
                  ],
                )
              else if (showAllowSession) ...[
                // Tier 1: Unmistakable Full-Width Hero Primary Pill (danger tint on high-risk cmds)
                GrassBagPrimaryGlassButton(
                  label: _decided ? '处理中…' : (isDangerCmd ? '确认执行高风险操作' : '允许本次'),
                  icon: _decided
                      ? null
                      : (isDangerCmd
                          ? CupertinoIcons.exclamationmark_shield_fill
                          : CupertinoIcons.checkmark_shield_fill),
                  color: isDangerCmd ? t.err : null,
                  foregroundColor: isDangerCmd ? Colors.white : null,
                  height: 46,
                  tier: widget.tier,
                  insideGlass: true,
                  enabled: !_decided,
                  onTap: () => unawaited(_handleTap('allow')),
                ),
                const SizedBox(height: 9),
                // Tier 2: Balanced Frosted Secondary Pills (Zero cramped 3-in-a-row!)
                Row(
                  children: [
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: '本会话允许',
                        height: 42,
                        tier: widget.tier,
                        insideGlass: true,
                        accentForeground: true,
                        enabled: !_decided,
                        onTap: () => unawaited(_handleTap('always')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: '拒绝',
                        height: 42,
                        tier: widget.tier,
                        insideGlass: true,
                        destructive: true,
                        enabled: !_decided,
                        onTap: () => unawaited(_handleTap('deny')),
                      ),
                    ),
                  ],
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      flex: isDangerCmd ? 3 : 2,
                      child: GrassBagSecondaryGlassButton(
                        label: isDangerCmd ? '取消 / 拒绝' : '拒绝',
                        height: 46,
                        tier: widget.tier,
                        insideGlass: true,
                        destructive: !isDangerCmd,
                        enabled: !_decided,
                        onTap: () => unawaited(_handleTap('deny')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: isDangerCmd ? 2 : 3,
                      child: GrassBagPrimaryGlassButton(
                        label: _decided ? '处理中…' : (isDangerCmd ? '确认执行' : '允许本次'),
                        icon: _decided
                            ? null
                            : (isDangerCmd
                                ? CupertinoIcons.exclamationmark_shield_fill
                                : CupertinoIcons.checkmark_shield_fill),
                        color: isDangerCmd ? t.err : null,
                        foregroundColor: isDangerCmd ? Colors.white : null,
                        height: 46,
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
    this.pendingIndex = 0,
    this.onCyclePending,
    this.onCollapse,
    this.initialDraft,
    this.onDraftChanged,
    this.maxHeight = 560.0,
    required this.tier,
    required this.onSubmit,
    required this.onCancel,
  });

  final ActiveUserQuestion question;
  final int pendingCount;
  final int pendingIndex;
  final void Function(int delta)? onCyclePending;
  final VoidCallback? onCollapse;
  final ({Map<String, Set<String>> selected, Map<String, String> custom})? initialDraft;
  final ValueChanged<({Map<String, Set<String>> selected, Map<String, String> custom})>?
      onDraftChanged;
  final double maxHeight;
  final GrassBagGlassTier tier;
  final Future<bool> Function(Object) onSubmit;
  final Future<bool> Function() onCancel;

  @override
  State<_UserQuestionTakeoverCard> createState() => _UserQuestionTakeoverCardState();
}

class _UserQuestionTakeoverCardState extends State<_UserQuestionTakeoverCard> {
  final Map<String, Set<String>> _selectedById = {};
  final Map<String, TextEditingController> _customCtrls = {};
  final Map<String, FocusNode> _focusNodes = {};
  final ScrollController _scrollCtrl = ScrollController();
  final ValueNotifier<int> _answerVersion = ValueNotifier<int>(0);
  late final DateTime _mountedAt = DateTime.now();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final draft = widget.initialDraft;
    if (draft != null) {
      for (final entry in draft.selected.entries) {
        _selectedById[entry.key] = Set<String>.of(entry.value);
      }
      for (final entry in draft.custom.entries) {
        if (entry.value.isNotEmpty) {
          _customCtrls[entry.key] = TextEditingController(text: entry.value);
        }
      }
    }
  }

  void _emitDraft() {
    final cb = widget.onDraftChanged;
    if (cb == null) return;
    cb((
      selected: {
        for (final entry in _selectedById.entries)
          if (entry.value.isNotEmpty) entry.key: Set<String>.of(entry.value),
      },
      custom: {
        for (final entry in _customCtrls.entries)
          if (entry.value.text.isNotEmpty) entry.key: entry.value.text,
      },
    ));
  }

  Future<void> _handleSkip() async {
    if (_submitting) return;
    if (DateTime.now().difference(_mountedAt).inMilliseconds < 260) {
      return;
    }
    setState(() => _submitting = true);
    final ok = await widget.onCancel();
    if (mounted && !ok) {
      setState(() => _submitting = false);
    }
  }

  List<UserQuestionItem> get _items => widget.question.allQuestions;

  TextEditingController _ctrlFor(String id) =>
      _customCtrls.putIfAbsent(id, () => TextEditingController());

  FocusNode _focusFor(String id) => _focusNodes.putIfAbsent(id, () {
        final node = FocusNode();
        node.addListener(() {
          if (node.hasFocus && mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final ctx = node.context;
              if (ctx != null && ctx.mounted) {
                Scrollable.ensureVisible(
                  ctx,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: 0.72,
                );
              }
            });
          }
        });
        return node;
      });

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _answerVersion.dispose();
    for (final c in _customCtrls.values) {
      c.dispose();
    }
    for (final f in _focusNodes.values) {
      f.dispose();
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
    final compactCard = widget.maxHeight < 260.0;
    return GlassBackdropGroup(
      enabled: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: GrassBagGlass(
          tier: widget.tier,
          borderRadius: 30,
          elevated: true,
          useSheetSettings: true,
          padding: EdgeInsets.fromLTRB(
            compactCard ? 14 : 18,
            compactCard ? 10 : 16,
            compactCard ? 14 : 18,
            compactCard ? 10 : 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  GrassBagSquircleIcon(
                    icon: CupertinoIcons.question_circle_fill,
                    color: t.primary,
                    size: compactCard ? 32 : 38,
                    iconSize: compactCard ? 15.5 : 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      multiQ ? '${widget.question.title}（共 ${items.length} 题）' : widget.question.title,
                      maxLines: compactCard ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compactCard ? 14.5 : 15.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: t.text,
                      ),
                    ),
                  ),
                  if (widget.pendingCount > 1) ...[
                    const SizedBox(width: 8),
                    _TakeoverPendingSwitcher(
                      index: widget.pendingIndex,
                      count: widget.pendingCount,
                      color: t.primary,
                      tintColor: t.primarySoft,
                      onCycle: widget.onCyclePending,
                    ),
                  ],
                  if (widget.onCollapse != null) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: '收起查看对话',
                      child: GrassBagSpringTap(
                        onTap: widget.onCollapse!,
                        pressedScale: 0.90,
                        child: GrassBagFresnelGlassSurface(
                          isPill: true,
                          innerWell: true,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(CupertinoIcons.chevron_down, size: 11.5, color: t.text2),
                              const SizedBox(width: 3),
                              Text(
                                '收起',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: t.text2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              SizedBox(height: compactCard ? 7 : 11),
              Flexible(
                child: RepaintBoundary(
                  child: SingleChildScrollView(
                    controller: _scrollCtrl,
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                                      enablePointerGlow: false,
                                      haptic: true,
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
                                            // Symmetric exclusivity: picking a single-select option
                                            // clears stale custom text just as typing clears options.
                                            if (ctrl.text.isNotEmpty) {
                                              ctrl.clear();
                                            }
                                          }
                                        });
                                        _answerVersion.value++;
                                        _emitDraft();
                                      },
                                      child: GrassBagFresnelGlassSurface(
                                        isPill: desc.isEmpty,
                                        borderRadius: 14,
                                        innerWell: !picked,
                                        elevated: picked,
                                        interactive: true,
                                        tintColor: picked ? t.primarySoft : null,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 8.5,
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (picked) ...[
                                                  Icon(
                                                    CupertinoIcons.checkmark_alt,
                                                    size: 13,
                                                    color: t.primary,
                                                  ),
                                                  const SizedBox(width: 4),
                                                ],
                                                Flexible(
                                                  child: Text(
                                                    opt,
                                                    style: TextStyle(
                                                      fontSize: 12.5,
                                                      fontWeight: FontWeight.w600,
                                                      color: picked ? t.primary : t.text,
                                                    ),
                                                  ),
                                                ),
                                              ],
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
                              focusNode: _focusFor(q.id),
                              placeholder: q.options.isEmpty ? '请输入你的回答…' : '或输入其他补充说明…',
                              fontSize: 13,
                              minLines: 1,
                              maxLines: 3,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              insideGlass: true,
                              textInputAction: qi < items.length - 1
                                  ? TextInputAction.next
                                  : TextInputAction.done,
                              onChanged: (val) {
                                if (!q.multiSelect && val.trim().isNotEmpty && pickedSet.isNotEmpty) {
                                  setState(() => pickedSet.clear());
                                }
                                _answerVersion.value++;
                                _emitDraft();
                              },
                              onSubmitted: (_) {
                                if (qi < items.length - 1) {
                                  final nextQ = items[qi + 1];
                                  if (nextQ.allowFreeText || nextQ.options.isEmpty) {
                                    _focusFor(nextQ.id).requestFocus();
                                  }
                                } else if (_canSubmit) {
                                  _confirm();
                                }
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
          SizedBox(height: compactCard ? 8 : 12),
          Row(
            children: [
              GrassBagSecondaryGlassButton(
                label: '跳过',
                height: compactCard ? 38 : 44,
                padding: const EdgeInsets.symmetric(horizontal: 16),
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
                    height: compactCard ? 38 : 44,
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
    this.pendingIndex = 0,
    this.onCyclePending,
    this.onCollapse,
    this.maxHeight = 560.0,
    required this.tier,
    required this.onDecision,
  });

  final ActiveCordisRunRequest request;
  final int pendingCount;
  final int pendingIndex;
  final void Function(int delta)? onCyclePending;
  final VoidCallback? onCollapse;
  final double maxHeight;
  final GrassBagGlassTier tier;
  final Future<bool> Function(bool) onDecision;

  @override
  State<_CordisRunTakeoverCard> createState() => _CordisRunTakeoverCardState();
}

class _CordisRunTakeoverCardState extends State<_CordisRunTakeoverCard> {
  late final DateTime _mountedAt = DateTime.now();
  bool _decided = false;
  bool _copied = false;

  void _copyPreview() {
    Clipboard.setData(ClipboardData(text: widget.request.codePreview));
    HapticFeedback.selectionClick();
    if (!_copied) {
      setState(() => _copied = true);
      Future<void>.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _copied = false);
      });
    }
  }

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
    final wellBg = t.isDark
        ? Colors.black.withValues(alpha: 0.34)
        : Colors.white.withValues(alpha: 0.78);
    final wellCodeColor = t.codeFg;

    return GlassBackdropGroup(
      enabled: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: GrassBagGlass(
          tier: widget.tier,
          borderRadius: 30,
          elevated: true,
          useSheetSettings: true,
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  GrassBagSquircleIcon(
                    icon: CupertinoIcons.cube_box_fill,
                    color: t.dusk,
                    size: 40,
                    iconSize: 19,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '请求运行动态扩展模块',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.25,
                            color: t.text,
                          ),
                        ),
                        const SizedBox(height: 3),
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
                    const SizedBox(width: 8),
                    _TakeoverPendingSwitcher(
                      index: widget.pendingIndex,
                      count: widget.pendingCount,
                      color: t.dusk,
                      tintColor: t.duskSoft,
                      onCycle: widget.onCyclePending,
                    ),
                  ],
                  if (widget.onCollapse != null) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: '收起查看对话',
                      child: GrassBagSpringTap(
                        onTap: widget.onCollapse!,
                        pressedScale: 0.90,
                        child: GrassBagFresnelGlassSurface(
                          isPill: true,
                          innerWell: true,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(CupertinoIcons.chevron_down, size: 11.5, color: t.text2),
                              const SizedBox(width: 3),
                              Text(
                                '收起',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: t.text2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (request.codePreview.isNotEmpty) ...[
                const SizedBox(height: 14),
                Flexible(
                  child: CustomPaint(
                    foregroundPainter: widget.tier == GrassBagGlassTier.solid
                        ? null
                        : GrassBagFresnelRimPainter(
                            isDark: t.isDark,
                            borderRadius: 16,
                            accent: t.dusk,
                            innerWell: true,
                            frosted: widget.tier == GrassBagGlassTier.frosted,
                            paintTopSheen: false,
                            strokeWidth: 0.8,
                          ),
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 164),
                      decoration: ShapeDecoration(
                        color: wellBg,
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: widget.tier == GrassBagGlassTier.solid
                              ? BorderSide(
                                  color: t.isDark
                                      ? Colors.white.withValues(alpha: 0.14)
                                      : Colors.white.withValues(alpha: 0.94),
                                  width: 0.8,
                                )
                              : BorderSide.none,
                        ),
                        shadows: t.isDark
                            ? null
                            : const [
                                BoxShadow(
                                  color: Color(0x0A0E2235),
                                  blurRadius: 10,
                                  offset: Offset(0, 2),
                                ),
                              ],
                      ),
                      child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 8, 7),
                          child: Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(color: t.dusk, shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '待执行动态扩展代码',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: t.text3,
                                  ),
                                ),
                              ),
                              GrassBagSpringTap(
                                onTap: _copyPreview,
                                pressedScale: 0.92,
                                enablePointerGlow: false,
                                haptic: true,
                                child: GrassBagFresnelGlassSurface(
                                  isPill: true,
                                  innerWell: true,
                                  interactive: true,
                                  padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 3.5),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _copied
                                            ? CupertinoIcons.checkmark_alt
                                            : CupertinoIcons.doc_on_doc,
                                        size: 11,
                                        color: _copied ? t.ok : t.text2,
                                      ),
                                      const SizedBox(width: 3.5),
                                      Text(
                                        _copied ? '已复制' : '复制',
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w600,
                                          color: _copied ? t.ok : t.text2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(
                          height: 0.6,
                          thickness: 0.6,
                          color: t.isDark
                              ? Colors.white.withValues(alpha: 0.09)
                              : const Color(0x14132C44),
                        ),
                        Flexible(
                          child: _ScrollableCommandWell(
                            fadeColor: wellBg,
                            child: SelectableText(
                              request.codePreview,
                              contextMenuBuilder: buildGrassBagEditableContextMenu,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.48,
                                color: wellCodeColor,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 15),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: GrassBagSecondaryGlassButton(
                      label: '拒绝加载',
                      height: 46,
                      tier: widget.tier,
                      insideGlass: true,
                      destructive: true,
                      enabled: !_decided,
                      onTap: () => unawaited(_handleTap(false)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 3,
                    child: GrassBagPrimaryGlassButton(
                      label: _decided ? '处理中…' : '允许运行',
                      icon: _decided ? null : CupertinoIcons.checkmark_shield_fill,
                      height: 46,
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
          isCompactingContext: s.isCompactingContext,
        ),
      ),
    );
    if (slice.isEmptyChat ||
        (!slice.isCompactingContext && slice.contextPct <= 0 && !slice.hasAnyData)) {
      return const SizedBox.shrink();
    }
    final t = GrassBagTokens.of(context);
    final pctInt = slice.contextPct;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: slice.isCompactingContext
              ? '正在精简上下文…'
              : '上下文占用 $pctInt%（点击查看与精简）',
          child: GrassBagSpringTap(
            onTap: () {
              onBeforeOpen?.call();
              showContextSheet(context, ref);
            },
            pressedScale: 0.88,
            enablePointerGlow: false,
            haptic: true,
            child: GrassBagFresnelGlassSurface(
              isPill: true,
              innerWell: true,
              interactive: true,
              height: 36,
              padding: EdgeInsets.symmetric(horizontal: pctInt >= 65 ? 9 : 8.5),
              tintColor: slice.isCompactingContext
                  ? t.primarySoft
                  : (pctInt >= 85
                      ? t.errSoft
                      : (pctInt >= 65 ? t.warnSoft : null)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (slice.isCompactingContext)
                    const CupertinoActivityIndicator(radius: 7)
                  else if (pctInt <= 0)
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
                        fontFeatures: const [FontFeature.tabularFigures()],
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
        icon: CupertinoIcons.flag_fill,
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
                                  child: Center(child: GrassBagActivityIndicator(radius: 6, color: st.primary)),
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
      child: GrassBagGlass(
        tier: slice.glassTier,
        borderRadius: 18,
        useCardQuality: true,
        interactiveGlow: false,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: GrassBagSpringTap(
                onTap: openQuickSheet,
                pressedScale: 0.985,
                borderRadius: 14,
                haptic: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2.5),
                  child: Row(
                    children: [
                      if (activeGoal != null)
                        Icon(CupertinoIcons.flag_fill, size: 14, color: accentCol)
                      else if (activeTodo != null)
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: Center(child: GrassBagActivityIndicator(radius: 6, color: accentCol)),
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
                      GrassBagFresnelGlassSurface(
                        isPill: true,
                        innerWell: true,
                        tintColor: accentCol.withValues(alpha: t.isDark ? 0.22 : 0.12),
                        padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 2),
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
                    ],
                  ),
                ),
              ),
            ),
            if (activeGoal != null) ...[
              const SizedBox(width: 2),
              Tooltip(
                message: activeGoal.isArmed ? '暂停目标' : '继续目标',
                excludeFromSemantics: true,
                child: Semantics(
                  button: true,
                  label: activeGoal.isArmed ? '暂停目标' : '继续目标',
                  child: GrassBagSpringTap(
                    onTap: () => ctrl.updateGoalStatus(
                      activeGoal.id,
                      activeGoal.isArmed ? 'paused' : 'active',
                    ),
                    pressedScale: 0.90,
                    haptic: true,
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: Center(
                        child: Icon(
                          activeGoal.isArmed ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
                          size: 14,
                          color: accentCol,
                        ),
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
}

/// Smooth horizontal spring/ease slot for transient composer toolbar controls
/// (Context Ring, companion Stop orb, Steer/Queue trigger).
class _AnimatedToolbarSlot extends StatelessWidget {
  const _AnimatedToolbarSlot({
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dur = GrassBagMotion.duration(context, const Duration(milliseconds: 190));
    return AnimatedSize(
      duration: dur,
      curve: Curves.easeOutCubic,
      alignment: Alignment.centerRight,
      child: AnimatedSwitcher(
        duration: dur,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (w, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.80, end: 1.0).animate(anim),
            child: w,
          ),
        ),
        child: visible
            ? KeyedSubtree(key: const ValueKey('toolbar-slot-on'), child: child)
            : const SizedBox.shrink(key: ValueKey('toolbar-slot-off')),
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
    this.alignment = Alignment.bottomCenter,
  });

  final Animation<double> animation;
  final GrassBagGlassTier tier;
  final Offset beginOffset;
  final double scaleFrom;
  final double contentSigma;
  final Widget child;
  final Alignment alignment;

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
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final materialized = GrassBagMaterializeTransition(
      animation: widget.animation,
      tier: widget.tier,
      alignment: widget.alignment,
      scaleFrom: reduceMotion ? 1.0 : widget.scaleFrom,
      contentSigma: reduceMotion ? 0.0 : widget.contentSigma,
      child: widget.child,
    );
    if (reduceMotion) return materialized;
    return SlideTransition(
      position: _slideAnim,
      child: materialized,
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

  void _save() {
    final next = _editCtrl.text.trim();
    if (next.isEmpty) {
      ref.read(appProvider.notifier).showToast('内容不能为空', tone: ToastTone.warn);
      return;
    }
    Navigator.of(context).pop();
    unawaited(ref.read(appProvider.notifier).editQueuedMessage(widget.item.id, next));
  }

  @override
  void dispose() {
    _editCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
            (HardwareKeyboard.instance.isMetaPressed ||
                HardwareKeyboard.instance.isControlPressed)) {
          _save();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
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
                  onTap: _save,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// Scrollable approval command well that renders a soft bottom fade gradient whenever
/// command arguments extend below the fold so users never miss truncated tail parameters.
class _ScrollableCommandWell extends StatefulWidget {
  const _ScrollableCommandWell({
    required this.fadeColor,
    required this.child,
  });

  final Color fadeColor;
  final Widget child;

  @override
  State<_ScrollableCommandWell> createState() => _ScrollableCommandWellState();
}

class _ScrollableCommandWellState extends State<_ScrollableCommandWell> {
  final ValueNotifier<bool> _hasMoreBelow = ValueNotifier<bool>(false);

  void _sync(ScrollMetrics m) {
    final next = m.maxScrollExtent > 2.0 && m.pixels < m.maxScrollExtent - 2.0;
    if (_hasMoreBelow.value != next) _hasMoreBelow.value = next;
  }

  @override
  void dispose() {
    _hasMoreBelow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (n) {
            _sync(n.metrics);
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              _sync(n.metrics);
              return false;
            },
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(13, 10, 13, 11),
              child: widget.child,
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 22,
          child: IgnorePointer(
            child: ValueListenableBuilder<bool>(
              valueListenable: _hasMoreBelow,
              builder: (_, show, __) {
                if (!show) return const SizedBox.shrink();
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        widget.fadeColor.withValues(alpha: 0.0),
                        widget.fadeColor.withValues(alpha: 0.92),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Interactive row inside the Kyant0 Liquid Glass Steer / Queue / Interrupt deck.
class _StreamSendModeRow extends StatelessWidget {
  const _StreamSendModeRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.isDefault = false,
    this.destructive = false,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool isDefault;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagSpringTap(
      onTap: onTap,
      pressedScale: 0.975,
      enablePointerGlow: false,
      haptic: true,
      borderRadius: 14,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: destructive ? t.err : t.text,
                        ),
                      ),
                      if (isDefault) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: t.primarySoft,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '默认',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: t.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 1.5),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: destructive ? t.err.withValues(alpha: 0.80) : t.text3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
