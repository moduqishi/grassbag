import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable, defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart'
    show GestureDisposition, HorizontalDragGestureRecognizer, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart'
    show ActionCardStep, NormalizedTurn, NoticeStep, ReasoningStep, ToolStep;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../chat/chat_empty_state.dart';
import '../chat/composer_bar.dart';
import '../chat/turn_process_widget.dart';
import '../common/grassbag_sheets.dart';
import '../detail/session_detail_page.dart';
import '../drawer/sessions_drawer.dart';
import '../features/all_features_page.dart';
import '../features/jobs_page.dart';
import '../features/plugins_center_page.dart';
import '../features/schedules_page.dart';
import '../features/sdui_extensions_page.dart';
import '../features/subagents_page.dart';
import '../settings/app_update_sheet.dart';
import '../settings/settings_page.dart';
import '../web/remote_web_login_page.dart';
import '../terminal/terminal_page.dart';
import '../web/official_web_page.dart';

/// Adaptive Phone & Tablet main shell strictly honoring every locked GrassBag UX rule:
/// - Genuine iOS 26 Liquid Glass floating chrome via `GlassPage`, `GlassBackdropGroup`,
///   `GlassButton`, `GlassScrollEdgeEffect`, and `GlassPageRoute`
/// - Silky smart auto-scroll on send & streaming + floating Liquid Glass scroll-to-bottom droplet
/// - Frame-accurate IME keyboard coordination (`resizeToAvoidBottomInset: false` + live `viewInsets`)
/// - Spring-physics interactive phone slide-over drawer with parallax depth + edge swipe
/// - Tablet (>= 840dp && height >= 480dp):
///   * Left sidebar open by default with smooth slide-width transition & its own collapse button
///   * Center floating title pill HIDDEN while left sidebar is open (restored smoothly when collapsed)
///   * Right workbench HIDDEN by default, toggled via top-right button (zero duplicate buttons)
class GrassBagShell extends ConsumerStatefulWidget {
  const GrassBagShell({
    super.key,
    this.isSplashCovered = false,
  });

  final bool isSplashCovered;

  @override
  ConsumerState<GrassBagShell> createState() => _GrassBagShellState();
}

class _GrassBagShellState extends ConsumerState<GrassBagShell>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const double _phoneDrawerWidth = 304.0;

  final _composerCtrl = TextEditingController();
  final _composerFocus = FocusNode();
  final _scrollCtrl = _ImeLockStepScrollController();
  final _chatStageKey = GlobalKey(debugLabel: 'grassbag-chat-stage');
  final _titlePillKey = GlobalKey(debugLabel: 'grassbag-title-pill');
  final _plusOpenNotifier = ValueNotifier<bool>(false);
  final _suggestionsOpenNotifier = ValueNotifier<bool>(false);
  final _editingContextNotifier = ValueNotifier<EditingMessageContext?>(null);
  final _drawerBackHandler = ValueNotifier<bool Function()?>(null);
  final _showScrollToBottomNotifier = ValueNotifier<bool>(false);
  final _hasNewBelowNotifier = ValueNotifier<bool>(false);
  final _prependedOlderCountNotifier = ValueNotifier<int>(0);
  final _composerHeightNotifier = ValueNotifier<double>(108.0);
  final _inChatSearchCtrl = TextEditingController();
  final _inChatSearchFocus = FocusNode();
  bool _inChatSearchOpen = false;
  String _inChatSearchQuery = '';
  int _inChatSearchCursor = 0;
  final Map<String, GlobalKey> _turnItemKeys = <String, GlobalKey>{};
  String? _highlightedTurnId;
  Timer? _highlightClearTimer;
  String? _centerAnchorTurnId;
  DateTime? _lastBackPressedAt;

  late final AnimationController _drawerCtrl;
  final ValueNotifier<double> _topBannerStackHeight = ValueNotifier<double>(0.0);
  final ValueNotifier<bool> _drawerOpenForBackNotifier = ValueNotifier<bool>(false);
  late final Listenable _backScopeListenable;
  Ticker? _streamScrollTicker;
  Duration? _lastScrollTick;
  double _streamSettleRemainingMs = 0.0;

  bool _userScrolledAway = false;
  bool _userDraggingList = false;
  bool _selectionAutoScrolling = false;
  String _chatSelectedPlainText = '';
  final ValueNotifier<bool> _hasActiveChatSelectionNotifier = ValueNotifier<bool>(false);
  bool _isProgrammaticScroll = false;
  bool _drawerEdgeDragDismissed = false;
  int _programmaticScrollGen = 0;
  double _lastMaxScrollExtent = 0.0;
  double _lastListTopPad = 0.0;
  double _upwardScrollAccum = 0.0;
  final Map<
      String,
      ({double pixels, bool scrolledAway, int prependedCount, String? anchorTurnId})>
      _savedScrollOffsetBySession = <String,
          ({double pixels, bool scrolledAway, int prependedCount, String? anchorTurnId})>{};
  final Set<String> _animatedTurnIds = <String>{};

  void _syncDrawerBackState() {
    final open = _drawerCtrl.value > 0.05;
    if (_drawerOpenForBackNotifier.value != open) {
      _drawerOpenForBackNotifier.value = open;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _drawerCtrl = AnimationController(
      vsync: this,
      value: 0.0,
      lowerBound: 0.0,
      upperBound: 1.0,
    );
    _drawerCtrl.addListener(_syncDrawerBackState);
    _backScopeListenable = Listenable.merge([
      _drawerOpenForBackNotifier,
      _plusOpenNotifier,
      _suggestionsOpenNotifier,
      _editingContextNotifier,
      _composerFocus,
      FocusManager.instance,
    ]);
    _composerFocus.addListener(_onComposerFocusChanged);
    final initialDraft = ref.read(appProvider.notifier).getComposerDraftForActiveHost();
    if (initialDraft.isNotEmpty) {
      _composerCtrl.text = initialDraft;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Flush composer text immediately before persisting host contexts so rapid backgrounding
      // within the 400ms typing debounce window NEVER loses an unsent draft (and when editing an
      // earlier turn, preserve the user's stashed draft instead of overwriting it with turn text!).
      final draftToFlush = _editingContextNotifier.value?.stashedDraft ?? _composerCtrl.text;
      ref.read(appProvider.notifier).setComposerDraftForActiveHost(draftToFlush);
      if (state == AppLifecycleState.inactive) {
        // Reinforce Android FGS + CPU/Wi-Fi keepalive while Activity is STILL foreground-eligible!
        ref.read(appProvider.notifier).handleAppInactivating();
      } else {
        ref.read(appProvider.notifier).handleAppPaused();
      }
    } else if (state == AppLifecycleState.resumed) {
      ref.read(appProvider.notifier).handleAppResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _highlightClearTimer?.cancel();
    _inChatSearchCtrl.dispose();
    _inChatSearchFocus.dispose();
    _streamScrollTicker?.dispose();
    _composerFocus.removeListener(_onComposerFocusChanged);
    _drawerCtrl.removeListener(_syncDrawerBackState);
    _composerFocus.dispose();
    _composerCtrl.dispose();
    _scrollCtrl.dispose();
    _plusOpenNotifier.dispose();
    _suggestionsOpenNotifier.dispose();
    _editingContextNotifier.dispose();
    _drawerBackHandler.dispose();
    _showScrollToBottomNotifier.dispose();
    _hasNewBelowNotifier.dispose();
    _prependedOlderCountNotifier.dispose();
    _composerHeightNotifier.dispose();
    _topBannerStackHeight.dispose();
    _drawerOpenForBackNotifier.dispose();
    _hasActiveChatSelectionNotifier.dispose();
    _drawerCtrl.dispose();
    super.dispose();
  }

  /// Starts a single silky 60/120Hz critically-damped scroll chase during live streaming,
  /// replacing repeated cancelled `animateTo(110ms)` calls that caused vertical twitching!
  void _ensureStreamScrollFollower({double settleTailMs = 0.0}) {
    if (_userScrolledAway) return;
    if (settleTailMs > _streamSettleRemainingMs) {
      _streamSettleRemainingMs = settleTailMs;
    }
    _streamScrollTicker ??= createTicker(_onStreamScrollTick);
    if (!_streamScrollTicker!.isActive) {
      _lastScrollTick = null;
      _streamScrollTicker!.start();
    }
  }

  void _stopStreamScrollFollower() {
    if (_streamScrollTicker != null && _streamScrollTicker!.isActive) {
      _streamScrollTicker!.stop();
    }
    _lastScrollTick = null;
    _streamSettleRemainingMs = 0.0;
  }

  void _onStreamScrollTick(Duration elapsed) {
    if (!mounted || _userScrolledAway) {
      _stopStreamScrollFollower();
      return;
    }
    final prev = _lastScrollTick;
    _lastScrollTick = elapsed;
    final dtSec = prev == null
        ? 0.016
        : ((elapsed - prev).inMicroseconds / 1000000.0).clamp(0.004, 0.05);

    if (_streamSettleRemainingMs > 0) {
      _streamSettleRemainingMs = (_streamSettleRemainingMs - dtSec * 1000.0).clamp(0.0, 2000.0);
    }
    final inSettleTail = _streamSettleRemainingMs > 0.0;
    if (!_scrollCtrl.hasClients || _scrollCtrl.positions.length != 1) {
      if (!inSettleTail) _stopStreamScrollFollower();
      return;
    }

    final pos = _scrollCtrl.position;
    // Never fight the user while they are actively touching, dragging, flinging, or
    // edge-selecting the list, and never fight an active programmatic `animateTo()` glide!
    if (_userDraggingList ||
        _selectionAutoScrolling ||
        _scrollCtrl.isUserDrivenScroll ||
        _isProgrammaticScroll) {
      return;
    }
    final gap = pos.maxScrollExtent - pos.pixels;
    if (gap <= 24.0) {
      if (_showScrollToBottomNotifier.value) {
        _showScrollToBottomNotifier.value = false;
      }
      if (_hasNewBelowNotifier.value) {
        _hasNewBelowNotifier.value = false;
      }
    }
    if (gap > 0.5) {
      final rawStep = gap <= 2.0 ? gap : gap * (1.0 - math.exp(-16.0 * dtSec));
      // Cap per-frame jump when catching up over a large distance so scroll stays graceful.
      final maxFrameStep = math.max(96.0, pos.viewportDimension * 0.42) * (dtSec / 0.016);
      final step = math.min(rawStep, maxFrameStep);
      final next = (pos.pixels + step).clamp(pos.minScrollExtent, pos.maxScrollExtent);
      _isProgrammaticScroll = true;
      try {
        _scrollCtrl.chaseTo(next);
      } finally {
        _isProgrammaticScroll = false;
      }
    } else if (!inSettleTail) {
      // Stop spinning immediately once caught up at bottom; woken automatically on next streamTick!
      _stopStreamScrollFollower();
    }
  }

  bool _isTablet(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width >= 840 && size.height >= 480;
  }

  void _onComposerFocusChanged() {
    if (_composerFocus.hasFocus) {
      if (_plusOpenNotifier.value) {
        _plusOpenNotifier.value = false;
      }
      // Keyboard inset sync is now handled smoothly frame-by-frame inside `_KeyboardScrollTail`
      // without any delayed 220ms jolt!
    }
  }

  void _animateDrawerTo(double target, {double velocity = 0.0}) {
    final clamped = target.clamp(0.0, 1.0);
    if (clamped > 0.5 && _composerFocus.hasFocus) {
      _composerFocus.unfocus();
    } else if (clamped < 0.5) {
      // Release focus from any hidden offstage TextField inside the drawer (e.g. search box)
      // so keystrokes never route into an invisible drawer input after closing.
      final primary = FocusManager.instance.primaryFocus;
      if (primary != null && primary != _composerFocus) {
        primary.unfocus();
      }
    }
    if (mounted && MediaQuery.disableAnimationsOf(context)) {
      _drawerCtrl.value = clamped;
      return;
    }
    // Critically damped (`bounce: 0.0`) so fast swipe-close NEVER rebounds past 0.0 and
    // flashes the drawer + backdrop scrim back on screen!
    final spring = GlassSpring.smooth(
      duration: const Duration(milliseconds: 260),
    );
    final sim = SpringSimulation(
      spring,
      _drawerCtrl.value,
      clamped,
      velocity.clamp(-7.5, 7.5),
      tolerance: const Tolerance(distance: 0.005, velocity: 0.02),
    );
    _drawerCtrl.animateWith(sim);
  }

  void _dismissKeyboardAndPopovers() {
    if (_plusOpenNotifier.value) _plusOpenNotifier.value = false;
    if (_suggestionsOpenNotifier.value) _suggestionsOpenNotifier.value = false;
    if (_composerFocus.hasFocus) _composerFocus.unfocus();
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary.hasFocus) {
      primary.unfocus();
    }
  }

  /// Soft outside tap on the chat canvas: if `/` or `@` suggestion picker is open,
  /// dismiss ONLY the popover first while keeping IME focus so the user can keep typing!
  void _handleCanvasTap() {
    if (_suggestionsOpenNotifier.value) {
      _suggestionsOpenNotifier.value = false;
      return;
    }
    _dismissKeyboardAndPopovers();
  }

  void _openPhoneDrawer() {
    _dismissKeyboardAndPopovers();
    _animateDrawerTo(1.0);
  }

  void _closePhoneDrawer() {
    _animateDrawerTo(0.0);
  }

  void _scheduleScrollToBottom({
    bool animated = true,
    bool settle = false,
    int durationMs = 320,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _performScrollToBottom(animated: animated, durationMs: durationMs);
      if (settle) {
        // Secondary pass after tall newly-inserted bubbles & process blocks finish measuring.
        Future<void>.delayed(const Duration(milliseconds: 70), () {
          if (mounted && !_userScrolledAway) {
            _performScrollToBottom(animated: animated, durationMs: durationMs);
          }
        });
      }
    });
  }

  void _performScrollToBottom({required bool animated, int durationMs = 320}) {
    if (!mounted || !_scrollCtrl.hasClients || _scrollCtrl.positions.length != 1) return;
    final pos = _scrollCtrl.position;
    final target = pos.maxScrollExtent;
    final needsImmediate = (target - pos.pixels).abs() >= 1.5;
    if (animated && !needsImmediate) return;

    final gen = ++_programmaticScrollGen;
    void reanchor(int remaining) {
      if (remaining <= 0) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_scrollCtrl.hasClients ||
            _scrollCtrl.positions.length != 1 ||
            _userScrolledAway ||
            _programmaticScrollGen != gen) {
          if (_programmaticScrollGen == gen) _isProgrammaticScroll = false;
          return;
        }
        final nextTarget = _scrollCtrl.position.maxScrollExtent;
        if ((nextTarget - _scrollCtrl.position.pixels).abs() > 2.0) {
          _isProgrammaticScroll = true;
          try {
            _scrollCtrl.jumpTo(nextTarget);
          } finally {
            if (_programmaticScrollGen == gen) _isProgrammaticScroll = false;
          }
          reanchor(remaining - 1);
        }
      });
    }

    if (animated) {
      _isProgrammaticScroll = true;
      _scrollCtrl
          .animateTo(
            target,
            duration: Duration(milliseconds: durationMs),
            curve: durationMs <= 140 ? Curves.easeOut : Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (_programmaticScrollGen == gen) {
              _isProgrammaticScroll = false;
              // Bounded multi-pass post-frame re-anchor so tall lazy Markdown/code blocks
              // materialized near bottom NEVER leave scroll-to-bottom stranded above bottom!
              if (mounted &&
                  !_userScrolledAway &&
                  _scrollCtrl.hasClients &&
                  _scrollCtrl.positions.length == 1) {
                reanchor(4);
              }
            }
          });
    } else {
      if (needsImmediate) {
        _isProgrammaticScroll = true;
        try {
          _scrollCtrl.jumpTo(target);
        } finally {
          if (_programmaticScrollGen == gen) {
            _isProgrammaticScroll = false;
          }
        }
      }
      reanchor(6);
    }
  }

  Future<void> _handleLoadOlderTurns() async {
    final startState = ref.read(appProvider);
    final targetSid = startState.activeSessionId;
    final prevLen = startState.turns.length;
    final prevPrepended = _prependedOlderCountNotifier.value;
    final prevPixels = (_scrollCtrl.hasClients && _scrollCtrl.positions.length == 1)
        ? _scrollCtrl.position.pixels
        : null;
    // Pause streaming auto-follow so loading older history NEVER yanks the user back to bottom!
    _userScrolledAway = true;
    _scrollCtrl.allowImeAnchor = false;
    _stopStreamScrollFollower();
    await ref.read(appProvider.notifier).loadOlderTurns();
    if (!mounted) return;
    final afterState = ref.read(appProvider);
    if (afterState.activeSessionId != targetSid) return;
    final added = afterState.turns.length - prevLen;
    if (added > 0) {
      // Shift newly prepended older turns into the upward-growing sliver above `_centerSliverKey`.
      // On the very first `0 -> N` transition, `listTopPad` moves from `_centerSliverKey` to the
      // negative sliver; compensate scroll offset by exact `-_lastListTopPad` so the visible
      // reading anchor stays invariant to the sub-pixel (zero ~130px jump!).
      final topPadShift = prevPrepended == 0 ? _lastListTopPad : 0.0;
      final nextPrepended = prevPrepended + added;
      _centerAnchorTurnId = (nextPrepended >= 0 && nextPrepended < afterState.turns.length)
          ? afterState.turns[nextPrepended].turnId
          : null;
      _prependedOlderCountNotifier.value = nextPrepended;
      if (topPadShift > 0.0 && prevPixels != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollCtrl.hasClients || _scrollCtrl.positions.length != 1) return;
          final pos = _scrollCtrl.position;
          // Respect manual scrolling performed while older turns were loading over network.
          if (_userDraggingList || (pos.pixels - prevPixels).abs() > 24.0) return;
          final target = (prevPixels - topPadShift).clamp(pos.minScrollExtent, pos.maxScrollExtent);
          if ((pos.pixels - target).abs() > 0.5) {
            _isProgrammaticScroll = true;
            try {
              _scrollCtrl.jumpTo(target);
            } finally {
              _isProgrammaticScroll = false;
            }
          }
        });
      }
    }
  }

  void _prefillComposer(String text) {
    HapticFeedback.selectionClick();
    final existing = _composerCtrl.text.trim();
    final incoming = text.trim();
    if (existing.isNotEmpty && existing != incoming) {
      showGrassBagSheet(
        context,
        title: '输入框已有草稿',
        subtitle: '避免覆盖你正在编辑的内容',
        preferredHeight: 200,
        bodyBuilder: (sheetCtx) => Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '追加到末尾',
                height: 40,
                tier: ref.read(appProvider).glassTier,
                insideGlass: true,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  final merged = '${_composerCtrl.text}\n$text';
                  _composerCtrl.value = TextEditingValue(
                    text: merged,
                    selection: TextSelection.collapsed(offset: merged.length),
                  );
                  _composerFocus.requestFocus();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: '替换草稿',
                height: 40,
                tier: ref.read(appProvider).glassTier,
                insideGlass: true,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _editingContextNotifier.value = null;
                  _composerCtrl.value = TextEditingValue(
                    text: text,
                    selection: TextSelection.collapsed(offset: text.length),
                  );
                  _composerFocus.requestFocus();
                },
              ),
            ),
          ],
        ),
      );
      return;
    }
    _editingContextNotifier.value = null;
    _composerCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _composerFocus.requestFocus();
  }

  /// Zero-clipboard direct excerpt quotation: appends a clean blockquote straight into
  /// `_composerCtrl` without touching system clipboard or triggering draft overwrite prompts.
  void _quoteIntoComposer(String rawExcerpt) {
    final trimmed = rawExcerpt.trim();
    if (trimmed.isEmpty) return;
    HapticFeedback.selectionClick();
    final runes = trimmed.runes.toList(growable: false);
    final clipped = runes.length > 240
        ? '${String.fromCharCodes(runes.take(240))}…'
        : trimmed;
    final quotedLines = clipped
        .split('\n')
        .map((line) => '> $line')
        .join('\n');
    final quoteBlock = '$quotedLines\n\n';
    final cur = _composerCtrl.text;
    final nextText = cur.trim().isEmpty
        ? quoteBlock
        : (cur.endsWith('\n') ? '$cur\n$quoteBlock' : '$cur\n\n$quoteBlock');
    _composerCtrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    _composerFocus.requestFocus();
  }

  List<String> _computeInChatSearchMatchTurnIds(List<NormalizedTurn> turns, String rawQuery) {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final hits = <String>[];
    for (final turn in turns) {
      final userText = turn.userMessage?.text.toLowerCase() ?? '';
      if (userText.contains(q) || turn.assistantText.toLowerCase().contains(q)) {
        hits.add(turn.turnId);
        continue;
      }
      final stepHit = turn.steps.any((step) {
        return switch (step) {
          ReasoningStep s => s.text.toLowerCase().contains(q) ||
              (s.translatedText?.toLowerCase().contains(q) ?? false),
          ToolStep s => s.name.toLowerCase().contains(q) ||
              s.title.toLowerCase().contains(q) ||
              s.summary.toLowerCase().contains(q),
          NoticeStep s => s.text.toLowerCase().contains(q),
          ActionCardStep s =>
              (s.sdui['title']?.toString().toLowerCase().contains(q) ?? false) ||
                  (s.sdui['text']?.toString().toLowerCase().contains(q) ?? false) ||
                  (s.sdui['summary']?.toString().toLowerCase().contains(q) ?? false),
        };
      });
      if (stepHit) hits.add(turn.turnId);
    }
    return hits;
  }

  void _openInChatSearch() {
    if (ref.read(appProvider).isEmptyChat) return;
    _dismissKeyboardAndPopovers();
    setState(() {
      _inChatSearchOpen = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inChatSearchFocus.requestFocus();
    });
  }

  void _closeInChatSearch() {
    if (!_inChatSearchOpen) return;
    _inChatSearchFocus.unfocus();
    setState(() {
      _inChatSearchOpen = false;
      _inChatSearchQuery = '';
      _inChatSearchCursor = 0;
      _highlightedTurnId = null;
    });
    _inChatSearchCtrl.clear();
  }

  void _jumpToTurnById(String turnId) {
    final turns = ref.read(appProvider).turns;
    final idx = turns.indexWhere((t) => t.turnId == turnId);
    if (idx < 0) return;
    _userScrolledAway = true;
    _scrollCtrl.allowImeAnchor = false;
    _stopStreamScrollFollower();
    setState(() => _highlightedTurnId = turnId);
    _highlightClearTimer?.cancel();
    _highlightClearTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted && _highlightedTurnId == turnId) {
        setState(() => _highlightedTurnId = null);
      }
    });
    final existingCtx = _turnItemKeys[turnId]?.currentContext;
    if (existingCtx != null && existingCtx.mounted) {
      unawaited(
        Scrollable.ensureVisible(
          existingCtx,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: 0.18,
        ),
      );
      return;
    }
    if (!_scrollCtrl.hasClients || _scrollCtrl.positions.length != 1) return;
    final pos = _scrollCtrl.position;
    final ratio = turns.length <= 1 ? 1.0 : (idx / (turns.length - 1)).clamp(0.0, 1.0);
    final est = pos.minScrollExtent + (pos.maxScrollExtent - pos.minScrollExtent) * ratio;
    final gen = ++_programmaticScrollGen;
    _isProgrammaticScroll = true;
    unawaited(
      _scrollCtrl
          .animateTo(
            est.clamp(pos.minScrollExtent, pos.maxScrollExtent),
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (gen != _programmaticScrollGen) return;
            _isProgrammaticScroll = false;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || gen != _programmaticScrollGen) return;
              final mountedCtx = _turnItemKeys[turnId]?.currentContext;
              if (mountedCtx != null && mountedCtx.mounted) {
                unawaited(
                  Scrollable.ensureVisible(
                    mountedCtx,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    alignment: 0.18,
                  ),
                );
              }
            });
          }),
    );
  }

  void _stepInChatSearchMatch(int delta) {
    final turns = ref.read(appProvider).turns;
    final matches = _computeInChatSearchMatchTurnIds(turns, _inChatSearchQuery);
    if (matches.isEmpty) return;
    final next = (_inChatSearchCursor + delta) % matches.length;
    final normalized = next < 0 ? next + matches.length : next;
    setState(() => _inChatSearchCursor = normalized);
    _jumpToTurnById(matches[normalized]);
  }

  void _showTurnOutlineSheet() {
    final turns = ref.read(appProvider).turns;
    final entries = <({int index, NormalizedTurn turn, String prompt})>[];
    for (var i = 0; i < turns.length; i++) {
      final t = turns[i];
      final prompt = t.userMessage?.text.trim() ?? '';
      if (prompt.isNotEmpty) {
        entries.add((index: i, turn: t, prompt: prompt));
      }
    }
    if (entries.isEmpty) {
      ref.read(appProvider.notifier).showToast('当前对话暂无可跳转的提问记录', tone: ToastTone.info);
      return;
    }
    showGrassBagSheet(
      context,
      title: '提问大纲',
      subtitle: '共 ${entries.length} 轮提问 · 轻点快速定位',
      preferredHeight: math.min(460.0, 140.0 + entries.length * 58.0),
      bodyBuilder: (sheetCtx) {
        final t = GrassBagTokens.of(sheetCtx);
        return ListView.separated(
          shrinkWrap: true,
          itemCount: entries.length,
          separatorBuilder: (_, __) => Divider(height: 0.5, color: t.sep),
          itemBuilder: (_, i) {
            final item = entries[i];
            final hasErr = item.turn.status == 'error';
            final isLive = item.turn.isStreaming;
            return GrassBagSpringTap(
              onTap: () {
                Navigator.of(sheetCtx).pop();
                _jumpToTurnById(item.turn.turnId);
              },
              pressedScale: 0.98,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                child: Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: hasErr ? t.errSoft : t.primarySoft,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: hasErr ? t.err : t.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        item.prompt.replaceAll('\n', ' '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, height: 1.32, color: t.text),
                      ),
                    ),
                    if (isLive) ...[
                      const SizedBox(width: 8),
                      GrassBagStatusDot(color: t.primary, pulsing: true, size: 7),
                    ] else if (hasErr) ...[
                      const SizedBox(width: 8),
                      Icon(CupertinoIcons.exclamationmark_circle_fill, size: 14, color: t.err),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _startEditingTurn(NormalizedTurn turn) {
    final txt = turn.userMessage?.text ?? '';
    if (txt.trim().isEmpty) return;
    HapticFeedback.selectionClick();
    final turns = ref.read(appProvider).turns;
    final idx = turns.indexWhere(
      (item) => item.turnId == turn.turnId || item.stableKey == turn.stableKey,
    );
    final forkBeforeTurnId = idx > 0 ? turns[idx - 1].turnId : null;
    final existingEdit = _editingContextNotifier.value;
    final stashedDraft = existingEdit != null ? existingEdit.stashedDraft : _composerCtrl.text;
    _editingContextNotifier.value = EditingMessageContext(
      turnId: turn.turnId,
      originalText: txt,
      stashedDraft: stashedDraft,
      forkBeforeTurnId: forkBeforeTurnId,
      references: turn.userMessage?.references ?? const [],
    );
    _composerCtrl.value = TextEditingValue(
      text: txt,
      selection: TextSelection.collapsed(offset: txt.length),
    );
    if (_plusOpenNotifier.value) _plusOpenNotifier.value = false;
    _composerFocus.requestFocus();
  }

  void _cancelEditingTurn() {
    final editCtx = _editingContextNotifier.value;
    if (editCtx == null) return;
    HapticFeedback.selectionClick();
    _editingContextNotifier.value = null;
    final restore = editCtx.stashedDraft;
    _composerCtrl.value = TextEditingValue(
      text: restore,
      selection: TextSelection.collapsed(offset: restore.length),
    );
    ref.read(appProvider.notifier).setComposerDraftForActiveHost(restore);
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) return false;
    final maxExtent = notification.metrics.maxScrollExtent;
    final pixels = notification.metrics.pixels;
    final distFromBottom = (maxExtent - pixels).clamp(0.0, double.infinity);
    final wasScrolledAway = _userScrolledAway;

    // Detect ONLY genuine user-initiated upward scroll across touch drag, mouse wheel,
    // trackpad, and keyboard — NEVER trip `_userScrolledAway` when `maxScrollExtent`
    // grows dynamically from streaming text, expanded tool cards, or IME opening!
    if (notification is ScrollStartNotification) {
      if (!_isProgrammaticScroll) {
        _upwardScrollAccum = 0.0;
      }
      if (notification.dragDetails != null) {
        _userDraggingList = true;
        _scrollCtrl.clearPendingImeAnchor();
        if (_suggestionsOpenNotifier.value) {
          _suggestionsOpenNotifier.value = false;
        }
      }
    } else if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.forward && distFromBottom > 28) {
        _isProgrammaticScroll = false;
        _userScrolledAway = true;
      } else if (notification.direction == ScrollDirection.reverse && distFromBottom <= 24) {
        _userScrolledAway = false;
        _upwardScrollAccum = 0.0;
      }
    } else if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0.0;
      if (!_isProgrammaticScroll) {
        if (delta < 0) {
          _upwardScrollAccum += -delta;
        } else if (delta > 0) {
          _upwardScrollAccum = 0.0;
        }
      }
      if (notification.dragDetails != null) {
        _userDraggingList = true;
        _scrollCtrl.clearPendingImeAnchor();
        if (_suggestionsOpenNotifier.value) {
          _suggestionsOpenNotifier.value = false;
        }
      }
      if (notification.dragDetails != null && (delta < -0.5 || _upwardScrollAccum >= 2.5)) {
        _isProgrammaticScroll = false;
        _userScrolledAway = true;
      } else if (!_isProgrammaticScroll &&
          (delta < -0.5 || _upwardScrollAccum >= 2.0) &&
          maxExtent >= _lastMaxScrollExtent - 1.0 &&
          pixels <= maxExtent - 1.0 &&
          distFromBottom > 16.0) {
        // Require `distFromBottom > 16` AND `pixels <= maxExtent - 1` so BouncingScrollPhysics
        // shrink/clamp rebound (e.g. process-block fold or IME dismiss) never falsely detaches!
        _userScrolledAway = true;
      } else if (!_isProgrammaticScroll && delta > 0.5 && distFromBottom <= 24) {
        _userScrolledAway = false;
        _upwardScrollAccum = 0.0;
      }
    } else if (notification is ScrollEndNotification) {
      // ALWAYS clear `_userDraggingList` on ScrollEndNotification so touching the list
      // during a programmatic animation can NEVER permanently lock auto-follow!
      _userDraggingList = false;
      if (!_isProgrammaticScroll) {
        _upwardScrollAccum = 0.0;
        if (distFromBottom <= 24) {
          _userScrolledAway = false;
        }
      }
    }

    if (wasScrolledAway && !_userScrolledAway && !_isProgrammaticScroll && ref.read(appProvider).isStreaming) {
      _ensureStreamScrollFollower(settleTailMs: 260.0);
    }

    if (distFromBottom <= 24 && _hasNewBelowNotifier.value) {
      _hasNewBelowNotifier.value = false;
    }

    _scrollCtrl.allowImeAnchor = !_userScrolledAway && !_userDraggingList;
    _lastMaxScrollExtent = maxExtent;

    final isActivelyAutoFollowing = !_userScrolledAway && (_streamScrollTicker?.isActive ?? false);
    final hasLiveOrNewBelow = _hasNewBelowNotifier.value || ref.read(appProvider).isStreaming;
    final showThreshold = (hasLiveOrNewBelow && _userScrolledAway) ? 36.0 : 120.0;
    final shouldShowBtn =
        distFromBottom > showThreshold && !_isProgrammaticScroll && !isActivelyAutoFollowing;
    if (shouldShowBtn != _showScrollToBottomNotifier.value) {
      _showScrollToBottomNotifier.value = shouldShowBtn;
    }
    return false;
  }

  /// Reacts immediately whenever chat content height grows (typewriter lines, markdown tables,
  /// expanded tool rows, composer height, or soft keyboard tail) while anchored at bottom!
  bool _handleScrollMetricsNotification(ScrollMetricsNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) return false;
    final maxExtent = notification.metrics.maxScrollExtent;
    final pixels = notification.metrics.pixels;
    final prevMax = _lastMaxScrollExtent;
    final grew = maxExtent > prevMax + 1.0;
    final distFromBottom = (maxExtent - pixels).clamp(0.0, double.infinity);
    final wasNearBottom = (prevMax - pixels).clamp(0.0, double.infinity) <= 48.0;
    _lastMaxScrollExtent = maxExtent;

    // ONLY auto-follow growth while actively streaming or during the explicit send/stream settle tail!
    // Run BEFORE evaluating `shouldShowBtn` so large markdown tables/code blocks never flash the
    // scroll-to-bottom pill for 1 frame before the 120Hz follower engages!
    final streamingOrSettling =
        _streamSettleRemainingMs > 0 || ref.read(appProvider).isStreaming;
    if (grew &&
        streamingOrSettling &&
        distFromBottom > 1.5 &&
        !_isProgrammaticScroll &&
        !_userScrolledAway &&
        !_userDraggingList &&
        (wasNearBottom || _streamSettleRemainingMs > 0)) {
      _ensureStreamScrollFollower(settleTailMs: 260.0);
    }

    final isActivelyAutoFollowing = !_userScrolledAway && (_streamScrollTicker?.isActive ?? false);
    final hasLiveOrNewBelow = _hasNewBelowNotifier.value || ref.read(appProvider).isStreaming;
    final showThreshold = (hasLiveOrNewBelow && _userScrolledAway) ? 36.0 : 120.0;
    final shouldShowBtn =
        distFromBottom > showThreshold && !_isProgrammaticScroll && !isActivelyAutoFollowing;
    if (shouldShowBtn != _showScrollToBottomNotifier.value) {
      _showScrollToBottomNotifier.value = shouldShowBtn;
    }
    return false;
  }

  void _jumpBackToBottom() {
    HapticFeedback.selectionClick();
    _scrollCtrl.cancelMomentumAndHold();
    _userScrolledAway = false;
    _upwardScrollAccum = 0.0;
    final s = ref.read(appProvider);
    if (s.activeSessionId != null) {
      _savedScrollOffsetBySession.remove('${s.activeHostId}::${s.activeSessionId}');
    }
    _scrollCtrl.allowImeAnchor = true;
    if (_showScrollToBottomNotifier.value) {
      _showScrollToBottomNotifier.value = false;
    }
    if (_hasNewBelowNotifier.value) {
      _hasNewBelowNotifier.value = false;
    }
    if (s.isStreaming) {
      final hasLargeGap = _scrollCtrl.hasClients &&
          _scrollCtrl.positions.length == 1 &&
          (_scrollCtrl.position.maxScrollExtent - _scrollCtrl.position.pixels) >
              _scrollCtrl.position.viewportDimension;
      if (hasLargeGap) {
        // Glide gracefully across long history with easeOutCubic first, then hand off to
        // the 120Hz critically-damped follower for live streaming tail lock!
        _stopStreamScrollFollower();
        final gen = ++_programmaticScrollGen;
        _isProgrammaticScroll = true;
        _scrollCtrl
            .animateTo(
              _scrollCtrl.position.maxScrollExtent,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
            )
            .whenComplete(() {
              if (_programmaticScrollGen == gen) {
                _isProgrammaticScroll = false;
                if (mounted && !_userScrolledAway) {
                  _ensureStreamScrollFollower(settleTailMs: 360.0);
                }
              }
            });
      } else {
        // Cooperate cleanly with the 120Hz follower instead of fighting animateTo vs jumpTo!
        _ensureStreamScrollFollower(settleTailMs: 360.0);
      }
    } else {
      _stopStreamScrollFollower();
      _performScrollToBottom(animated: true);
    }
  }

  void _scheduleRestoreScrollOffset(double targetPixels) {
    final gen = ++_programmaticScrollGen;
    void applyPass(int remaining) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_scrollCtrl.hasClients ||
            _scrollCtrl.positions.length != 1 ||
            _programmaticScrollGen != gen) {
          return;
        }
        final pos = _scrollCtrl.position;
        final clamped = targetPixels.clamp(pos.minScrollExtent, pos.maxScrollExtent);
        if ((clamped - pos.pixels).abs() > 1.5) {
          _isProgrammaticScroll = true;
          try {
            _scrollCtrl.jumpTo(clamped);
          } finally {
            if (_programmaticScrollGen == gen) _isProgrammaticScroll = false;
          }
        }
        final dist = (pos.maxScrollExtent - pos.pixels).clamp(0.0, double.infinity);
        _userScrolledAway = dist > 24.0;
        _scrollCtrl.allowImeAnchor = !_userScrolledAway;
        final showBtn = dist > 120.0;
        if (showBtn != _showScrollToBottomNotifier.value) {
          _showScrollToBottomNotifier.value = showBtn;
        }
        if (remaining > 1 &&
            (targetPixels > pos.maxScrollExtent + 4.0 ||
                targetPixels < pos.minScrollExtent - 4.0)) {
          applyPass(remaining - 1);
        }
      });
    }

    applyPass(3);
  }

  void _onEmptySuggestionTap(String prompt) {
    final s = ref.read(appProvider);
    // Double-tap guard: ignore second tap once the first prompt has already transitioned off empty state.
    if (!s.isEmptyChat || s.isStreaming) return;
    HapticFeedback.lightImpact();
    _composerFocus.unfocus();
    final ctrl = ref.read(appProvider.notifier);
    if (GrassBagNativeBridge.instance.isAndroidNative &&
        s.activeHost.isLocal &&
        !s.nativeRuntimeStatus.engineRunning) {
      if (!s.nativeStatusHydrated ||
          s.nativeRuntimeStatus.engineState == 'starting' ||
          (s.runtimeProgressPct > 0 && s.runtimeProgressPct < 100)) {
        ctrl.showToast('本机 DSH 引擎正在启动中，请稍候片刻…', tone: ToastTone.info);
        return;
      }
      if (!s.nativeRuntimeStatus.initialized) {
        if (s.nativeRuntimeStatus.hasBundledRuntimePayloads) {
          ctrl.showToast('正在一键部署本机运行环境…', tone: ToastTone.info);
        }
        unawaited(
          triggerLocalRuntimeBootstrapWithGuard(
            context,
            ref,
            requireConfirmForRemote: true,
          ),
        );
      } else {
        ctrl.showToast('正在启动本机 DSH 引擎，请稍候片刻…', tone: ToastTone.info);
        ctrl.restartLocalEngine();
      }
      return;
    }
    if (!s.activeHost.isLocal &&
        (s.activeHost.needsAuth || s.connectionPhase == ConnectionPhase.needsAuth)) {
      showRemoteHostAuthSheet(context, ref, s.activeHost);
      return;
    }
    if (s.connectionPhase == ConnectionPhase.connecting ||
        s.connectionPhase == ConnectionPhase.reconnecting ||
        s.connectionPhase == ConnectionPhase.bootstrapping) {
      _prefillComposer(prompt);
      ctrl.showToast('正在连接主机，已为你填入输入框，连接就绪后直接发送即可', tone: ToastTone.info);
      return;
    }
    if (!s.isDshConnected) {
      showHostQuickSheet(
        context,
        ref,
        onOpenHostSettings: () => _openSettings(
          initialSection: SettingsSection.hosts,
          hostDetailId: s.activeHostId,
        ),
      );
      ctrl.showToast('当前主机尚未连接，请先重连或切换主机', tone: ToastTone.warn);
      return;
    }
    if (s.hydratingDomains) {
      _prefillComposer(prompt);
      ctrl.showToast('正在同步模型与工作区列表，请稍候片刻…', tone: ToastTone.info);
      return;
    }
    if (s.isDshConnected &&
        s.connectionPhase == ConnectionPhase.connected &&
        !s.hasAvailableModels &&
        !s.hydratingDomains) {
      // Preserve the tapped suggestion in the composer so the user does not lose it after configuring a model!
      if (_composerCtrl.text.trim().isEmpty) {
        _composerCtrl.value = TextEditingValue(
          text: prompt,
          selection: TextSelection.collapsed(offset: prompt.length),
        );
      }
      ctrl.showToast('请先登录 DeepSeek 或添加 API Key 模型渠道', tone: ToastTone.info);
      _openSettings(initialSection: SettingsSection.model);
      return;
    }
    if (_composerCtrl.text.trim().isNotEmpty || s.pendingAttachments.isNotEmpty) {
      _prefillComposer(prompt);
      return;
    }
    ctrl.sendPrompt(prompt, includePendingAttachments: false);
  }

  void _openTerminal() {
    _composerFocus.unfocus();
    Navigator.of(context).push(GrassBagPageRoute<void>(builder: (_) => const TerminalPage()));
  }

  void _openWebUi() {
    _composerFocus.unfocus();
    Navigator.of(context).push(GrassBagPageRoute<void>(builder: (_) => const OfficialWebPage()));
  }

  void _openSettings({
    SettingsSection? initialSection,
    String? hostDetailId,
  }) {
    _composerFocus.unfocus();
    Navigator.of(context).push(
      GrassBagPageRoute<void>(
        builder: (_) => SettingsPage(
          initialSection: initialSection,
          initialHostDetailId: hostDetailId,
          onOpenWebUi: _openWebUi,
        ),
      ),
    );
  }

  void _openSessionDetail() {
    _dismissKeyboardAndPopovers();
    if (_isTablet(context)) {
      final ctrl = ref.read(appProvider.notifier);
      final canDualPane = MediaQuery.sizeOf(context).width >= 1080;
      if (!canDualPane && ref.read(appProvider).tabletSidebarOpen) {
        ctrl.setTabletSidebarOpen(false);
      }
      ctrl.setTabletWorkbenchOpen(true);
      return;
    }
    Navigator.of(context).push(
      GrassBagPageRoute<void>(
        builder: (_) => SessionDetailContent(
          isTabletPane: false,
          onOpenTerminal: _openTerminal,
          onOpenWebUi: _openWebUi,
          onOpenHostDetail: (id) {
            Navigator.of(context).pop();
            _openSettings(initialSection: SettingsSection.hosts, hostDetailId: id);
          },
        ),
      ),
    );
  }

  void _openAllFeatures() {
    _composerFocus.unfocus();
    Navigator.of(context).push(
      GrassBagPageRoute<void>(
        builder: (_) => AllFeaturesPage(
          onOpenTerminal: _openTerminal,
          onOpenSessionDetail: _openSessionDetail,
          onOpenHosts: () => _openSettings(initialSection: SettingsSection.hosts),
          onOpenPlugins: () => Navigator.of(context).push(
            GrassBagPageRoute<void>(builder: (_) => const PluginsCenterPage()),
          ),
          onOpenPhoneControl: () => _openSettings(initialSection: SettingsSection.phone),
          onOpenWebUi: _openWebUi,
          onOpenSubagents: () => Navigator.of(context).push(
            GrassBagPageRoute<void>(builder: (_) => const SubagentsPage()),
          ),
          onOpenSchedules: () => Navigator.of(context).push(
            GrassBagPageRoute<void>(builder: (_) => const SchedulesPage()),
          ),
          onOpenJobs: () => Navigator.of(context).push(
            GrassBagPageRoute<void>(builder: (_) => const JobsPage()),
          ),
          onOpenSdui: () => Navigator.of(context).push(
            GrassBagPageRoute<void>(builder: (_) => const SduiExtensionsPage()),
          ),
        ),
      ),
    );
  }

  void _openSessionTitleAction({bool forceMenu = false}) {
    final active = ref.read(appProvider).activeSession;
    if ((!_isTablet(context) && !forceMenu) || active == null) {
      _openSessionDetail();
      return;
    }
    final isTab = _isTablet(context);
    final ctrl = ref.read(appProvider.notifier);
    final appState = ref.read(appProvider);
    final media = MediaQuery.of(context);
    final canDualPane = media.size.width >= 1080;
    final wbOpen =
        appState.tabletWorkbenchOpen && (canDualPane || !appState.tabletSidebarOpen);
    final tier = appState.glassTier;
    final host = appState.activeHost;
    final multiHost = !host.isLocal || appState.hosts.length > 1;
    var anchor = Offset(media.size.width * 0.5, media.viewPadding.top + 64);
    final pillRender = _titlePillKey.currentContext?.findRenderObject();
    if (pillRender is RenderBox && pillRender.hasSize && pillRender.attached) {
      final topLeft = pillRender.localToGlobal(Offset.zero);
      anchor = Offset(
        topLeft.dx + pillRender.size.width * 0.5,
        topLeft.dy + pillRender.size.height + 8.0,
      );
    }
    unawaited(
      showGrassBagGlassContextMenu(
        context,
        tier: tier,
        globalAnchor: anchor,
        headerTitle: active.title,
        items: [
          if (multiHost)
            GrassBagContextMenuItem(
              label: '切换主机 · ${host.name}',
              subtitle: host.isLocal ? '本机运行环境' : host.address,
              icon: CupertinoIcons.desktopcomputer,
              onTap: () => showHostQuickSheet(
                context,
                ref,
                onOpenHostSettings: () => _openSettings(
                  initialSection: SettingsSection.hosts,
                ),
              ),
            ),
          GrassBagContextMenuItem(
            label: '搜索当前对话',
            subtitle: '快速检索消息与工具记录',
            icon: CupertinoIcons.search,
            dividerBefore: multiHost,
            onTap: _openInChatSearch,
          ),
          GrassBagContextMenuItem(
            label: '提问大纲',
            subtitle: '按轮次跳转历史提问',
            icon: CupertinoIcons.list_number,
            onTap: _showTurnOutlineSheet,
          ),
          if (isTab)
            GrassBagContextMenuItem(
              label: wbOpen ? '收起右侧工作台' : '展开右侧工作台',
              subtitle: '文件、Git 改动、终端与轨迹',
              icon: CupertinoIcons.sidebar_right,
              selected: wbOpen,
              dividerBefore: true,
              onTap: () {
                final nextOpen = !wbOpen;
                if (nextOpen && !canDualPane && ref.read(appProvider).tabletSidebarOpen) {
                  ctrl.setTabletSidebarOpen(false);
                }
                ctrl.setTabletWorkbenchOpen(nextOpen);
              },
            )
          else
            GrassBagContextMenuItem(
              label: '对话详情与工作台',
              subtitle: '文件、Git 改动、上下文与终端',
              icon: CupertinoIcons.sidebar_right,
              dividerBefore: true,
              onTap: _openSessionDetail,
            ),
          GrassBagContextMenuItem(
            label: '重命名对话',
            icon: CupertinoIcons.pencil,
            onTap: () => showRenameSessionSheet(context, ref, active),
          ),
          GrassBagContextMenuItem(
            label: '创建分支对话 (Fork)',
            subtitle: '保留上下文分叉探索',
            icon: CupertinoIcons.arrow_branch,
            onTap: () => ctrl.forkActiveSession(),
          ),
          GrassBagContextMenuItem(
            label: '导出为 Markdown',
            icon: CupertinoIcons.share,
            onTap: () => ctrl.exportActiveSession(),
          ),
          GrassBagContextMenuItem(
            label: '打开交互终端',
            icon: CupertinoIcons.chevron_left_slash_chevron_right,
            dividerBefore: true,
            onTap: _openTerminal,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Already on a fresh New Chat stage -> gently focus composer without erasing user's draft.
    // Wait until a closing phone drawer settles so IME never races the slide-out spring!
    ref.listen<int>(appProvider.select((s) => s.focusComposerSignal), (prev, next) {
      if (prev != null && next != prev) {
        if (_plusOpenNotifier.value) _plusOpenNotifier.value = false;
        void requestWhenDrawerClosed() {
          if (!mounted) return;
          if (_drawerCtrl.value <= 0.06) {
            _composerFocus.requestFocus();
          } else {
            late VoidCallback listener;
            listener = () {
              if (!mounted) {
                _drawerCtrl.removeListener(listener);
                return;
              }
              if (_drawerCtrl.value <= 0.06) {
                _drawerCtrl.removeListener(listener);
                _composerFocus.requestFocus();
              }
            };
            _drawerCtrl.addListener(listener);
          }
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => requestWhenDrawerClosed());
      }
    });

    void resetScrollAnchoring() {
      _stopStreamScrollFollower();
      _lastMaxScrollExtent = 0.0;
      _upwardScrollAccum = 0.0;
      _animatedTurnIds.clear();
      _turnItemKeys.clear();
      _centerAnchorTurnId = null;
      _userScrolledAway = false;
      _userDraggingList = false;
      _scrollCtrl.allowImeAnchor = true;
      _scrollCtrl.clearPendingImeAnchor();
      if (_showScrollToBottomNotifier.value) {
        _showScrollToBottomNotifier.value = false;
      }
      if (_hasNewBelowNotifier.value) {
        _hasNewBelowNotifier.value = false;
      }
      if (_prependedOlderCountNotifier.value != 0) {
        _prependedOlderCountNotifier.value = 0;
      }
    }

    // Remember per-session reading scroll offset before switching away AND immediately
    // clear stale floating scroll-to-bottom pills so they never float over loading/error stages!
    // Uses explicit `_centerAnchorTurnId` (updated synchronously in `_handleLoadOlderTurns`)
    // so saved reading positions ALWAYS survive `loadOlderTurns()` without anchor drift!
    ref.listen<(String, String?, String?)>(
      appProvider.select((s) {
        final fallbackAnchorId = s.turns.isNotEmpty ? s.turns.first.turnId : null;
        return (s.activeHostId, s.activeSessionId, fallbackAnchorId);
      }),
      (prev, next) {
        if (prev != null && (prev.$1 != next.$1 || prev.$2 != next.$2)) {
          if (prev.$2 != null && _scrollCtrl.hasClients && _scrollCtrl.positions.length == 1) {
            final pos = _scrollCtrl.position;
            final dist = (pos.maxScrollExtent - pos.pixels).clamp(0.0, double.infinity);
            final key = '${prev.$1}::${prev.$2}';
            if (_userScrolledAway && dist > 36.0) {
              if (_savedScrollOffsetBySession.length >= 30 &&
                  !_savedScrollOffsetBySession.containsKey(key)) {
                _savedScrollOffsetBySession.remove(_savedScrollOffsetBySession.keys.first);
              }
              final prepended = _prependedOlderCountNotifier.value;
              _savedScrollOffsetBySession[key] = (
                pixels: pos.pixels,
                scrolledAway: true,
                prependedCount: prepended,
                anchorTurnId: _centerAnchorTurnId ?? prev.$3,
              );
            } else {
              _savedScrollOffsetBySession.remove(key);
            }
          }
          final isPendingPromotion = prev.$1 == next.$1 &&
              ((prev.$2 == null && next.$2 != null && next.$2!.startsWith('pending-session-')) ||
                  (prev.$2 != null &&
                      prev.$2!.startsWith('pending-session-') &&
                      next.$2 != null &&
                      !next.$2!.startsWith('pending-session-')));
          if (!isPendingPromotion && _editingContextNotifier.value != null) {
            _editingContextNotifier.value = null;
          }
          if (!isPendingPromotion && _inChatSearchOpen) {
            _closeInChatSearch();
          }
          _centerAnchorTurnId = null;
          if (_showScrollToBottomNotifier.value) {
            _showScrollToBottomNotifier.value = false;
          }
          if (_hasNewBelowNotifier.value) {
            _hasNewBelowNotifier.value = false;
          }
          if (_prependedOlderCountNotifier.value != 0) {
            _prependedOlderCountNotifier.value = 0;
          }
        }
      },
    );

    // React to New Chat trigger -> reset scroll state & focus composer on desktop!
    // ChatComposerDock is the single owner of `_composerCtrl` draft sync (never clear saved drafts here!).
    ref.listen<int>(appProvider.select((s) => s.newChatSignal), (prev, next) {
      if (prev != null && next != prev) {
        resetScrollAnchoring();
        if (_plusOpenNotifier.value) _plusOpenNotifier.value = false;
        if (_editingContextNotifier.value != null) _editingContextNotifier.value = null;
        final isDesktop = kIsWeb ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux;
        if (isDesktop) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _composerFocus.requestFocus();
          });
        }
      }
    });

    // React to active host switch -> purge cross-host turn/image caches & reset scroll state!
    ref.listen<String>(appProvider.select((s) => s.activeHostId), (prev, next) {
      if (prev != null && prev != next) {
        _savedScrollOffsetBySession.clear();
        resetScrollAnchoring();
        clearTurnProcessCaches();
        if (_plusOpenNotifier.value) _plusOpenNotifier.value = false;
        if (_editingContextNotifier.value != null) _editingContextNotifier.value = null;
      }
    });

    // Clear stale saved scroll anchors when reconnecting so freshly fetched pages never corrupt prependedCount.
    ref.listen<ConnectionPhase>(appProvider.select((s) => s.connectionPhase), (prev, next) {
      if (prev != null &&
          prev != ConnectionPhase.connected &&
          next == ConnectionPhase.connected) {
        _savedScrollOffsetBySession.clear();
      }
    });

    // Switching to another historical session -> restore saved reading spot if previously
    // scrolled up AND the anchor turn matches (guards against cache eviction / reconnect shifts),
    // otherwise silently anchor at the latest message via instant jumpTo.
    ref.listen<int>(appProvider.select((s) => s.sessionJumpSignal), (prev, next) {
      if (prev != null && next != prev) {
        resetScrollAnchoring();
        final s = ref.read(appProvider);
        final key = s.activeSessionId == null ? null : '${s.activeHostId}::${s.activeSessionId}';
        final saved = key == null ? null : _savedScrollOffsetBySession[key];
        final anchorMatches = saved != null &&
            saved.scrolledAway &&
            (saved.anchorTurnId == null ||
                (saved.prependedCount >= 0 &&
                    saved.prependedCount < s.turns.length &&
                    s.turns[saved.prependedCount].turnId == saved.anchorTurnId));
        if (anchorMatches) {
          _userScrolledAway = true;
          _scrollCtrl.allowImeAnchor = false;
          if (saved.prependedCount > 0) {
            _centerAnchorTurnId = saved.anchorTurnId;
            _prependedOlderCountNotifier.value = saved.prependedCount;
          }
          _scheduleRestoreScrollOffset(saved.pixels);
        } else {
          if (key != null && saved != null) {
            _savedScrollOffsetBySession.remove(key);
          }
          _scheduleScrollToBottom(animated: false, settle: false);
        }
      }
    });

    // React to every newly sent prompt -> halt any upward fling inertia, glide smoothly if
    // far above bottom, and hand off cleanly to the 120Hz critically-damped scroll follower!
    ref.listen<int>(appProvider.select((s) => s.scrollSignal), (prev, next) {
      if (prev != null && next != prev) {
        _scrollCtrl.cancelMomentumAndHold();
        _userScrolledAway = false;
        _upwardScrollAccum = 0.0;
        final s = ref.read(appProvider);
        if (s.activeSessionId != null) {
          _savedScrollOffsetBySession.remove('${s.activeHostId}::${s.activeSessionId}');
        }
        _scrollCtrl.allowImeAnchor = true;
        if (_showScrollToBottomNotifier.value) {
          _showScrollToBottomNotifier.value = false;
        }
        if (_hasNewBelowNotifier.value) {
          _hasNewBelowNotifier.value = false;
        }
        // Defer scroll chase into post-frame so `maxScrollExtent` reflects the newly mounted
        // optimistic turn instead of animating to the pre-send bottom and double-hopping!
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _userScrolledAway) return;
          final hasLargeGap = _scrollCtrl.hasClients &&
              _scrollCtrl.positions.length == 1 &&
              (_scrollCtrl.position.maxScrollExtent - _scrollCtrl.position.pixels) >
                  _scrollCtrl.position.viewportDimension;
          if (hasLargeGap) {
            _stopStreamScrollFollower();
            final gen = ++_programmaticScrollGen;
            _isProgrammaticScroll = true;
            _scrollCtrl
                .animateTo(
                  _scrollCtrl.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                )
                .whenComplete(() {
                  if (_programmaticScrollGen == gen) {
                    _isProgrammaticScroll = false;
                    if (mounted && !_userScrolledAway) {
                      _ensureStreamScrollFollower(settleTailMs: 360.0);
                    }
                  }
                });
          } else {
            _ensureStreamScrollFollower(settleTailMs: 360.0);
          }
        });
      }
    });

    // React to live streaming chunks AND background-completed cached-session updates ->
    // keep 120Hz smooth chase alive, or raise `_hasNewBelowNotifier` ("有新回复") when scrolled up!
    ref.listen<int>(appProvider.select((s) => s.streamTick), (prev, next) {
      if (prev != null && next != prev && ref.read(appProvider).turns.isNotEmpty) {
        if (!_userScrolledAway && !_isProgrammaticScroll) {
          _ensureStreamScrollFollower(settleTailMs: 280.0);
        } else if (_userScrolledAway && !_hasNewBelowNotifier.value) {
          _hasNewBelowNotifier.value = true;
        }
      }
    });

    // When streaming starts/completes -> glide smoothly through the typewriter's completion
    // tail, action strip SizeTransition, and post-turn deliverables sync, then stop automatically!
    ref.listen<bool>(appProvider.select((s) => s.isStreaming), (prev, next) {
      if (next == true && !_userScrolledAway && !_isProgrammaticScroll) {
        _ensureStreamScrollFollower(settleTailMs: 320.0);
      } else if (prev == true && next == false) {
        if (!_userScrolledAway && !_isProgrammaticScroll) {
          _ensureStreamScrollFollower(settleTailMs: 850.0);
        } else if (_userScrolledAway && !_hasNewBelowNotifier.value) {
          _hasNewBelowNotifier.value = true;
        }
      }
    });

    // ULTRA-NARROW SHELL SELECTOR: GrassBagShell NEVER watches `s.turns` or `s.isStreaming`!
    // During an entire 2,000-token stream, GrassBagShell, Top Liquid Glass chrome,
    // ChatComposerDock, Sidebar, and collapsed Workbench experience ZERO rebuilds!
    final shellSlice = ref.watch(
      appProvider.select(
        (s) {
          final host = s.activeHost;
          final sess = s.activeSession;
          return (
            isEmptyChat: s.isEmptyChat,
            activeSessionId: s.activeSessionId,
            activeSessionTitle: sess?.title ?? s.activeChildTitle ?? '新对话',
            activeWorkspaceName: s.activeWorkspaceDisplayName,
            hasActiveSession: sess != null || s.activeSessionId != null,
            parentSessionId: s.parentSessionId,
            parentSessionTitle: s.parentSessionTitle,
            hostId: host.id,
            hostName: host.name,
            hostAddress: host.address,
            hostIsLocal: host.isLocal,
            hostBridged: host.bridged,
            hostDirectMode: host.directMode,
            hostOnline: host.online,
            hostAllowBadCerts: host.allowBadCertificates,
            hostLastErrorCode: host.lastErrorCode,
            hostInstalling: host.installing,
            hostsCount: s.hosts.length,
            connectionPhase: s.connectionPhase,
            glassTier: s.glassTier,
            tabletSidebarOpen: s.tabletSidebarOpen,
            tabletWorkbenchOpen: s.tabletWorkbenchOpen,
            nativeInitialized: s.nativeRuntimeStatus.initialized,
            nativeHasBundledPayloads: s.nativeRuntimeStatus.hasBundledRuntimePayloads,
            nativeHasPartialDownload: s.nativeRuntimeStatus.hasPartialDownload,
            nativeDownloadSize: s.nativeRuntimeStatus.formattedDownloadSize,
            nativeStatusHydrated: s.nativeStatusHydrated,
            nativeEngineState: s.nativeRuntimeStatus.engineState,
            nativeEngineError: s.nativeRuntimeStatus.engineError,
            runtimeProgressPct: s.runtimeProgressPct,
            runtimeProgressMsg: s.runtimeProgressMsg,
            runtimeProgressCanCancel: s.runtimeProgressCanCancel,
            showAppUpdateBanner: s.showAppUpdateBanner,
            appUpdateVersionName: s.appUpdateInfo?.versionName ?? '',
            phoneLiveActive: s.phoneLiveActive,
            hasActiveTakeover: s.pendingApprovalCommand != null ||
                s.activeQuestion != null ||
                s.activeCordisRequest != null,
          );
        },
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final isTab = _isTablet(context);
    // CRITICAL 120FPS OPTIMIZATION: Never subscribe GrassBagShell to viewInsets OR paddingOf!
    // `viewPaddingOf` stays constant while the soft keyboard animates, preventing full-screen
    // rebuilds AND eliminating the 14-32px downward dip on gesture-nav phones!
    final screenSize = MediaQuery.sizeOf(context);
    final screenH = screenSize.height;
    final viewPad = MediaQuery.viewPaddingOf(context);
    final topPad = viewPad.top;
    final botPad = viewPad.bottom;
    final baseComposerBottom = botPad > 0 ? botPad + 8.0 : 14.0;

    // On tablet with left sidebar expanded: hide center title pill ONLY on empty New Chat;
    // on active conversations, show the clean floating conversation title pill so desktop
    // chats stay clearly anchored like Claude Desktop & Cursor!
    final canDualPane = screenSize.width >= 1080;
    final effectiveTabWorkbenchOpen =
        shellSlice.tabletWorkbenchOpen && (canDualPane || !shellSlice.tabletSidebarOpen);
    if (isTab && !canDualPane && shellSlice.tabletSidebarOpen && shellSlice.tabletWorkbenchOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(appProvider).tabletWorkbenchOpen) {
          ref.read(appProvider.notifier).setTabletWorkbenchOpen(false);
        }
      });
    }
    final hideCenterTitle = isTab && shellSlice.tabletSidebarOpen && shellSlice.isEmptyChat;
    final showTopLeftBtn = !isTab || !shellSlice.tabletSidebarOpen;
    final showTopRightBtn = !isTab || !effectiveTabWorkbenchOpen;

    final remoteUsable = shellSlice.hostOnline && (shellSlice.hostBridged || shellSlice.hostDirectMode);
    final isHostTransientConnecting = shellSlice.connectionPhase == ConnectionPhase.connecting ||
        shellSlice.connectionPhase == ConnectionPhase.reconnecting ||
        shellSlice.connectionPhase == ConnectionPhase.bootstrapping;
    // Empty chat renders `_RemoteEmptyStatusBanner` inline inside `ChatEmptyState` — avoid duplicate banners!
    final showRemoteBasicBanner = !shellSlice.isEmptyChat &&
        !shellSlice.hostIsLocal &&
        !remoteUsable &&
        !isHostTransientConnecting;
    final showLocalDesktopErrorBanner = !shellSlice.isEmptyChat &&
        !GrassBagNativeBridge.instance.isAndroidNative &&
        shellSlice.hostIsLocal &&
        shellSlice.connectionPhase == ConnectionPhase.error;
    // Empty chat already renders `_LocalRuntimeBanner` inside `ChatEmptyState` — avoid duplicate banners!
    final showLocalAndroidBanner = !shellSlice.isEmptyChat &&
        GrassBagNativeBridge.instance.isAndroidNative &&
        shellSlice.hostIsLocal &&
        shellSlice.nativeStatusHydrated &&
        (!shellSlice.nativeInitialized ||
            shellSlice.nativeEngineState == 'starting' ||
            shellSlice.nativeEngineState == 'stopped' ||
            shellSlice.nativeEngineState == 'error' ||
            shellSlice.connectionPhase == ConnectionPhase.error ||
            (shellSlice.runtimeProgressPct > 0 && shellSlice.runtimeProgressPct < 100));
    final hostHealthy = shellSlice.hostIsLocal
        ? (GrassBagNativeBridge.instance.isAndroidNative
            ? (shellSlice.nativeEngineState == 'running' &&
                shellSlice.connectionPhase == ConnectionPhase.connected)
            : shellSlice.connectionPhase == ConnectionPhase.connected)
        : (remoteUsable && shellSlice.connectionPhase == ConnectionPhase.connected);
    final hostHasErr = shellSlice.connectionPhase == ConnectionPhase.error ||
        (shellSlice.hostIsLocal &&
            GrassBagNativeBridge.instance.isAndroidNative &&
            shellSlice.nativeEngineState == 'error');
    final hostNeedsAuth = shellSlice.connectionPhase == ConnectionPhase.needsAuth ||
        shellSlice.hostLastErrorCode == 'needs_auth' ||
        shellSlice.hostLastErrorCode == 'html_proxy';
    final hostIsConnecting = isHostTransientConnecting ||
        (shellSlice.hostIsLocal &&
            GrassBagNativeBridge.instance.isAndroidNative &&
            (!shellSlice.nativeStatusHydrated ||
                shellSlice.nativeEngineState == 'starting' ||
                (shellSlice.runtimeProgressPct > 0 && shellSlice.runtimeProgressPct < 100)));
    final hostDotColor = hostHealthy
        ? t.ok
        : (hostHasErr
            ? t.err
            : ((hostNeedsAuth || hostIsConnecting) ? t.primary : t.text3));
    // Show the low-priority floating app-update pill ONLY on the Empty Chat home stage so it
    // never clutters or overlaps user bubbles inside an active conversation (Settings badge &
    // sidebar still surface available updates cleanly).
    final showAppUpdatePill = shellSlice.isEmptyChat &&
        shellSlice.showAppUpdateBanner &&
        shellSlice.appUpdateVersionName.isNotEmpty &&
        !shellSlice.phoneLiveActive &&
        !showRemoteBasicBanner &&
        !showLocalAndroidBanner &&
        !showLocalDesktopErrorBanner;
    final hasNonPhoneTopBanner = showAppUpdatePill ||
        showRemoteBasicBanner ||
        showLocalAndroidBanner ||
        showLocalDesktopErrorBanner;
    final baseListTopPad = topPad + 76.0;
    final currentBannerH = _topBannerStackHeight.value;
    _lastListTopPad = baseListTopPad + (currentBannerH > 0.5 ? currentBannerH + 12.0 : 0.0);

    final chatStage = Stack(
      key: _chatStageKey,
      children: [
        // Isolated Chat Canvas wrapped in dismiss-keyboard GestureDetector so tapping the
        // message list or empty stage dismisses IME, while tapping composer dock padding NEVER does!
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _handleCanvasTap,
            child: _ChatCanvasArea(
              scrollCtrl: _scrollCtrl,
              baseListTopPad: baseListTopPad,
              topBannerHeightNotifier: _topBannerStackHeight,
              onEffectiveTopPadChanged: (nextTopPad) {
                final delta = nextTopPad - _lastListTopPad;
                _lastListTopPad = nextTopPad;
                if (delta > 0.5) {
                  _lastMaxScrollExtent += delta;
                }
              },
              onUserUpwardWheel: () {
                if (!_userScrolledAway) {
                  _userScrolledAway = true;
                  _stopStreamScrollFollower();
                }
              },
              onSelectionChanged: (plainText) {
                _chatSelectedPlainText = plainText;
                final hasSel = plainText.isNotEmpty;
                if (_hasActiveChatSelectionNotifier.value != hasSel) {
                  _hasActiveChatSelectionNotifier.value = hasSel;
                }
              },
              hasActiveSelectionNotifier: _hasActiveChatSelectionNotifier,
              getSelectedPlainText: () => _chatSelectedPlainText,
              onSelectionAutoScrollActiveChanged: (active) {
                _selectionAutoScrolling = active;
              },
              onSelectionAutoScrollStep: (deltaPx) {
                if (deltaPx < -0.5) {
                  _userScrolledAway = true;
                  _stopStreamScrollFollower();
                }
              },
              screenH: screenH,
              topPad: topPad,
              baseComposerBottom: baseComposerBottom,
              composerHeightNotifier: _composerHeightNotifier,
              prependedOlderCountNotifier: _prependedOlderCountNotifier,
              hideCenterTitle: hideCenterTitle,
              animatedTurnIds: _animatedTurnIds,
              onScrollNotification: _handleScrollNotification,
              onScrollMetricsNotification: _handleScrollMetricsNotification,
              onLoadOlderTurns: _handleLoadOlderTurns,
              onEmptySuggestionTap: _onEmptySuggestionTap,
              onOpenModelSettings: () => _openSettings(initialSection: SettingsSection.model),
              onOpenHostSettings: () => _openSettings(
                initialSection: SettingsSection.hosts,
                hostDetailId: shellSlice.hostId,
              ),
              onOpenDiagnostics: () => _openSettings(initialSection: SettingsSection.diagnostics),
              onOpenTerminal: _openTerminal,
              onPrefillPrompt: _prefillComposer,
              onQuoteExcerpt: _quoteIntoComposer,
              onEditTurn: _startEditingTurn,
              turnItemKeys: _turnItemKeys,
              highlightedTurnId: _highlightedTurnId,
            ),
          ),
        ),

        // Left-edge swipe gesture zone on Phone placed BELOW floating Liquid Glass chrome:
        // uses a narrow right-only drag recognizer (`18dp` strip) that stays clear of the live
        // composer dock and disables cleanly while approval/question takeover cards are shown.
        if (!isTab && !shellSlice.hasActiveTakeover)
          ValueListenableBuilder<double>(
            valueListenable: _composerHeightNotifier,
            builder: (_, compH, edgeChild) => Positioned(
              top: topPad + 72,
              bottom: baseComposerBottom + compH + 16.0,
              left: 0,
              width: 26,
              child: edgeChild!,
            ),
            child: RawGestureDetector(
              behavior: HitTestBehavior.translucent,
              gestures: <Type, GestureRecognizerFactory>{
                _RightOnlyHorizontalDragGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                        _RightOnlyHorizontalDragGestureRecognizer>(
                  () => _RightOnlyHorizontalDragGestureRecognizer(),
                  (_RightOnlyHorizontalDragGestureRecognizer instance) {
                    instance
                      ..onStart = (_) {
                        _drawerCtrl.stop();
                        _drawerEdgeDragDismissed = false;
                      }
                      ..onUpdate = (d) {
                        final drawerW = math.min(
                          _phoneDrawerWidth,
                          math.max(220.0, screenSize.width - 48.0),
                        );
                        final next = (_drawerCtrl.value + d.delta.dx / drawerW).clamp(0.0, 1.0);
                        if (!_drawerEdgeDragDismissed && d.delta.dx > 0 && next > 0.02) {
                          _drawerEdgeDragDismissed = true;
                          _dismissKeyboardAndPopovers();
                        }
                        _drawerCtrl.value = next;
                      }
                      ..onEnd = (d) {
                        _drawerEdgeDragDismissed = false;
                        final drawerW = math.min(
                          _phoneDrawerWidth,
                          math.max(220.0, screenSize.width - 48.0),
                        );
                        final v = d.velocity.pixelsPerSecond.dx / drawerW;
                        if (v > 0.6 || (_drawerCtrl.value > 0.35 && v > -0.4)) {
                          _animateDrawerTo(1.0, velocity: v);
                        } else {
                          _animateDrawerTo(0.0, velocity: v);
                        }
                      }
                      ..onCancel = () {
                        _drawerEdgeDragDismissed = false;
                        _animateDrawerTo(_drawerCtrl.value > 0.5 ? 1.0 : 0.0);
                      };
                  },
                ),
              },
            ),
          ),

          // Floating Liquid Glass Chrome Layer wrapped in ONE GlassBackdropGroup
          Positioned.fill(
            child: GlassBackdropGroup(
              child: Stack(
                children: [
                  // Shared Kyant0 / iOS 26–27 graduated top edge dissolve behind floating pills
                  // AND any active top status banners so scrolled messages melt cleanly beneath!
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: ValueListenableBuilder<double>(
                      valueListenable: _topBannerStackHeight,
                      builder: (_, bannerH, __) => GrassBagScrollEdgeMist(
                        tier: shellSlice.glassTier,
                        topPad: topPad,
                        extraHeight: bannerH > 0.5 ? bannerH + 10.0 : 0.0,
                      ),
                    ),
                  ),
                  // Smooth bottom progressive blur & feather behind the composer that tracks
                  // real composer height AND lifts smoothly with soft keyboard insets!
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: _KeyboardAwareBottomScrim(
                      tier: shellSlice.glassTier,
                      baseComposerBottom: baseComposerBottom,
                      composerHeightNotifier: _composerHeightNotifier,
                    ),
                  ),
                  // Transparent outside-tap barrier positioned BELOW floating top chrome & Phone-Control
                  // "急停" banner so tapping header buttons or emergency stop ALWAYS works on 1st tap,
                  // while tapping the chat canvas dismisses '+' deck or '/'/'@'/Steer-Queue cleanly!
                  ValueListenableBuilder<bool>(
                    valueListenable: _plusOpenNotifier,
                    builder: (_, isPlusOpen, __) {
                      return ValueListenableBuilder<bool>(
                        valueListenable: _suggestionsOpenNotifier,
                        builder: (_, isSuggOpen, __) {
                          if (!isPlusOpen && !isSuggOpen) return const SizedBox.shrink();
                          return Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                if (isPlusOpen) _plusOpenNotifier.value = false;
                                if (isSuggOpen) _suggestionsOpenNotifier.value = false;
                              },
                              onPanStart: (_) {
                                if (isPlusOpen) _plusOpenNotifier.value = false;
                                if (isSuggOpen) _suggestionsOpenNotifier.value = false;
                              },
                              child: const SizedBox.expand(),
                            ),
                          );
                        },
                      );
                    },
                  ),
                  // Symmetrical Floating Liquid Glass Top Chrome
                  // Batched into ONE AdaptiveLiquidGlassLayer (useOwnLayer: false -> 1 GPU pass!)
                  // with ZERO FadeTransition wrappers so GlassBackdropGroup sharing stays 100% active!
                  Positioned(
                    top: topPad + 12,
                    left: 12,
                    right: 12,
                    child: SizedBox(
                      height: 44,
                      child: GrassBagGlassBarLayer(
                        tier: shellSlice.glassTier,
                        child: Builder(
                          builder: (_) {
                            final leftChromeW = showTopLeftBtn
                                ? ((isTab && !shellSlice.tabletSidebarOpen) ? 108.0 : 54.0)
                                : 0.0;
                            final rightChromeW = showTopRightBtn ? 54.0 : 0.0;
                            final showStackedHeader = !shellSlice.isEmptyChat &&
                                (shellSlice.activeWorkspaceName.isNotEmpty ||
                                    !shellSlice.hostIsLocal ||
                                    shellSlice.hostsCount > 1);
                            final showHostInSub =
                                !shellSlice.hostIsLocal || shellSlice.hostsCount > 1;
                            return Row(
                              children: [
                                if (showTopLeftBtn) ...[
                                  SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        GrassBagGlassCircleButton(
                                          key: ValueKey('top-left-$isTab'),
                                          icon: isTab
                                              ? CupertinoIcons.sidebar_left
                                              : CupertinoIcons.line_horizontal_3,
                                          iconSize: 19,
                                          useOwnLayer: false,
                                          tooltip: isTab ? '展开侧边栏' : '打开侧边栏',
                                          tier: shellSlice.glassTier,
                                          onTap: () {
                                            _dismissKeyboardAndPopovers();
                                            if (isTab) {
                                              if (!canDualPane && shellSlice.tabletWorkbenchOpen) {
                                                ctrl.setTabletWorkbenchOpen(false);
                                              }
                                              ctrl.setTabletSidebarOpen(true);
                                            } else {
                                              _openPhoneDrawer();
                                            }
                                          },
                                        ),
                                        const Positioned(
                                          top: -1,
                                          right: -1,
                                          child: IgnorePointer(
                                            child: _DrawerButtonStatusBadge(),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  if (isTab && !shellSlice.tabletSidebarOpen) ...[
                                    SizedBox(
                                      width: 44,
                                      height: 44,
                                      child: GrassBagGlassCircleButton(
                                        key: const ValueKey('top-left-tab-new-chat'),
                                        icon: CupertinoIcons.square_pencil,
                                        iconSize: 18,
                                        useOwnLayer: false,
                                        tooltip: '新对话',
                                        tier: shellSlice.glassTier,
                                        onTap: () {
                                          _dismissKeyboardAndPopovers();
                                          ctrl.startNewChat();
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                  ],
                                ],
                                if (!hideCenterTitle && leftChromeW < rightChromeW)
                                  SizedBox(width: rightChromeW - leftChromeW),
                                Expanded(
                                  child: hideCenterTitle
                                      ? const SizedBox.shrink()
                                      : Center(
                                          child: Builder(
                                            builder: (pillCtx) {
                                              final clampedTitleScaler =
                                                  MediaQuery.textScalerOf(pillCtx)
                                                      .clamp(maxScaleFactor: 1.15);
                                              final pillButton = Tooltip(
                                                message: shellSlice.isEmptyChat
                                                    ? '切换主机'
                                                    : (isTab ? '对话操作与详情' : '点击打开工作台 · 长按更多操作'),
                                                child: GrassBagGlassPillButton(
                                                  key: _titlePillKey,
                                                  tier: shellSlice.glassTier,
                                                  height: 44,
                                                  useOwnLayer: false,
                                                  padding: const EdgeInsets.symmetric(horizontal: 14),
                                                  onTap: shellSlice.isEmptyChat
                                                      ? () {
                                                          _dismissKeyboardAndPopovers();
                                                          showHostQuickSheet(
                                                            context,
                                                            ref,
                                                            onOpenHostSettings: () => _openSettings(
                                                              initialSection: SettingsSection.hosts,
                                                            ),
                                                          );
                                                        }
                                                      : () {
                                                          _dismissKeyboardAndPopovers();
                                                          _openSessionTitleAction();
                                                        },
                                                  child: AnimatedSize(
                                                    duration: GrassBagMotion.duration(
                                                      context,
                                                      const Duration(milliseconds: 220),
                                                    ),
                                                    curve: Curves.easeOutCubic,
                                                    alignment: Alignment.center,
                                                    child: AnimatedSwitcher(
                                                      duration: GrassBagMotion.duration(
                                                        context,
                                                        const Duration(milliseconds: 180),
                                                      ),
                                                      switchInCurve: Curves.easeOutCubic,
                                                      switchOutCurve: Curves.easeInCubic,
                                                      child: showStackedHeader
                                                        ? Column(
                                                            key: ValueKey(
                                                              'stacked:${shellSlice.hostId}:${shellSlice.activeWorkspaceName}:${shellSlice.activeSessionTitle}',
                                                            ),
                                                            mainAxisSize: MainAxisSize.min,
                                                            mainAxisAlignment: MainAxisAlignment.center,
                                                            children: [
                                                              Row(
                                                                mainAxisSize: MainAxisSize.min,
                                                                children: [
                                                                  GrassBagStatusDot(
                                                                    size: 6.5,
                                                                    color: hostDotColor,
                                                                    pulsing: !hostHealthy &&
                                                                        !hostHasErr &&
                                                                        hostIsConnecting,
                                                                  ),
                                                                  const SizedBox(width: 6),
                                                                  Flexible(
                                                                    child: Text(
                                                                      shellSlice.activeSessionTitle,
                                                                      maxLines: 1,
                                                                      overflow: TextOverflow.ellipsis,
                                                                      textScaler: clampedTitleScaler,
                                                                      style: TextStyle(
                                                                        fontSize: 13.5,
                                                                        fontWeight: FontWeight.w600,
                                                                        height: 1.12,
                                                                        letterSpacing: -0.25,
                                                                        color: t.text,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  if (isTab &&
                                                                      shellSlice.hasActiveSession) ...[
                                                                    const SizedBox(width: 3),
                                                                    Icon(
                                                                      CupertinoIcons.chevron_down,
                                                                      size: 10,
                                                                      color: t.text3,
                                                                    ),
                                                                  ] else if (!isTab &&
                                                                      shellSlice.hasActiveSession) ...[
                                                                    const SizedBox(width: 3),
                                                                    Icon(
                                                                      CupertinoIcons.chevron_right,
                                                                      size: 10,
                                                                      color: t.text3,
                                                                    ),
                                                                  ],
                                                                ],
                                                              ),
                                                              const SizedBox(height: 1.5),
                                                              Row(
                                                                mainAxisSize: MainAxisSize.min,
                                                                children: [
                                                                  Flexible(
                                                                    child: _HeaderLiveSubtitle(
                                                                      workspaceName: shellSlice.activeWorkspaceName,
                                                                      fallbackHostName: shellSlice.hostName,
                                                                      showHostName: showHostInSub,
                                                                      hostIsLocal: shellSlice.hostIsLocal,
                                                                      textScaler: clampedTitleScaler,
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ],
                                                          )
                                                        : Row(
                                                            key: ValueKey(
                                                              shellSlice.isEmptyChat
                                                                  ? 'host:${shellSlice.hostId}:${shellSlice.hostName}'
                                                                  : '${shellSlice.hostId}:${shellSlice.activeSessionTitle}',
                                                            ),
                                                            mainAxisSize: MainAxisSize.min,
                                                            children: [
                                                              GrassBagStatusDot(
                                                                size: 7,
                                                                color: hostDotColor,
                                                                pulsing: !hostHealthy &&
                                                                    !hostHasErr &&
                                                                    hostIsConnecting,
                                                              ),
                                                              const SizedBox(width: 7),
                                                              Flexible(
                                                                child: Text(
                                                                  shellSlice.isEmptyChat
                                                                      ? shellSlice.hostName
                                                                      : shellSlice.activeSessionTitle,
                                                                  maxLines: 1,
                                                                  overflow: TextOverflow.ellipsis,
                                                                  textScaler: clampedTitleScaler,
                                                                  style: TextStyle(
                                                                    fontSize: 14.5,
                                                                    fontWeight: FontWeight.w600,
                                                                    letterSpacing: -0.25,
                                                                    color: t.text,
                                                                  ),
                                                                ),
                                                              ),
                                                              if (!shellSlice.isEmptyChat)
                                                                _HeaderLiveStatusChip(
                                                                  textScaler: clampedTitleScaler,
                                                                ),
                                                              if (shellSlice.isEmptyChat ||
                                                                  (shellSlice.hasActiveSession && isTab)) ...[
                                                                const SizedBox(width: 5),
                                                                Icon(
                                                                  CupertinoIcons.chevron_down,
                                                                  size: 11,
                                                                  color: t.text3,
                                                                ),
                                                              ] else if (!isTab &&
                                                                  shellSlice.hasActiveSession) ...[
                                                                const SizedBox(width: 4),
                                                                Icon(
                                                                  CupertinoIcons.chevron_right,
                                                                  size: 10.5,
                                                                  color: t.text3,
                                                                ),
                                                              ],
                                                              ],
                                                            ),
                                                    ),
                                                  ),
                                                ),
                                              );
                                              if (!isTab && !shellSlice.isEmptyChat) {
                                                return GestureDetector(
                                                  onLongPress: () {
                                                    HapticFeedback.mediumImpact();
                                                    _dismissKeyboardAndPopovers();
                                                    _openSessionTitleAction(forceMenu: true);
                                                  },
                                                  child: pillButton,
                                                );
                                              }
                                              return pillButton;
                                            },
                                          ),
                                        ),
                                ),
                                if (!hideCenterTitle && rightChromeW < leftChromeW)
                                  SizedBox(width: leftChromeW - rightChromeW),
                                if (showTopRightBtn) ...[
                                  const SizedBox(width: 10),
                                  SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: GrassBagGlassCircleButton(
                                      key: ValueKey('top-right-$isTab'),
                                      icon: isTab
                                          ? CupertinoIcons.sidebar_right
                                          : CupertinoIcons.square_pencil,
                                      iconSize: 19,
                                      useOwnLayer: false,
                                      tooltip: isTab ? '展开工作台' : '新对话',
                                      tier: shellSlice.glassTier,
                                      onTap: () {
                                        _dismissKeyboardAndPopovers();
                                        if (isTab) {
                                          if (!canDualPane && shellSlice.tabletSidebarOpen) {
                                            ctrl.setTabletSidebarOpen(false);
                                          }
                                          ctrl.setTabletWorkbenchOpen(true);
                                        } else {
                                          ctrl.startNewChat();
                                        }
                                      },
                                    ),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),

                // Unified measured top banner stack: guarantees zero banner-on-banner overlap
                // across any font scale and feeds exact real pixel height to the top feather
                // scrim, chat ListView top padding, and composer max-height clearance!
                Positioned(
                  top: topPad + 64,
                  left: 12,
                  right: 12,
                  child: _ReportedHeightBox(
                    onHeightChanged: (h) {
                      if (mounted && (_topBannerStackHeight.value - h).abs() > 0.5) {
                        _topBannerStackHeight.value = h;
                      }
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        GrassBagSmoothDisclosure(
                          expanded: _inChatSearchOpen && !shellSlice.isEmptyChat,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 520),
                                child: _InChatSearchBar(
                                  controller: _inChatSearchCtrl,
                                  focusNode: _inChatSearchFocus,
                                  query: _inChatSearchQuery,
                                  cursor: _inChatSearchCursor,
                                  tier: shellSlice.glassTier,
                                  computeMatches: _computeInChatSearchMatchTurnIds,
                                  onChanged: (q) {
                                    final turns = ref.read(appProvider).turns;
                                    final matches = _computeInChatSearchMatchTurnIds(turns, q);
                                    setState(() {
                                      _inChatSearchQuery = q;
                                      _inChatSearchCursor = 0;
                                    });
                                    if (matches.isNotEmpty) {
                                      _jumpToTurnById(matches.first);
                                    }
                                  },
                                  onStep: _stepInChatSearchMatch,
                                  onClose: _closeInChatSearch,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (showAppUpdatePill)
                          Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 440),
                              child: GrassBagGlass(
                                tier: shellSlice.glassTier,
                                borderRadius: 999,
                                elevated: true,
                                interactiveGlow: false,
                                padding: const EdgeInsets.fromLTRB(12, 3, 4, 3),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () => unawaited(showAppUpdateSheet(context, ref)),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 5),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                CupertinoIcons.arrow_down_circle_fill,
                                                size: 16,
                                                color: t.primary,
                                              ),
                                              const SizedBox(width: 7),
                                              Flexible(
                                                child: Text(
                                                  '发现 GrassBag v${shellSlice.appUpdateVersionName} · 点击更新',
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 12.5,
                                                    fontWeight: FontWeight.w600,
                                                    color: t.text,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    Tooltip(
                                      message: '暂不提示更新',
                                      excludeFromSemantics: true,
                                      child: Semantics(
                                        button: true,
                                        label: '暂不提示更新',
                                        child: GrassBagSpringTap(
                                          pressedScale: 0.86,
                                          enablePointerGlow: false,
                                          haptic: true,
                                          onTap: ctrl.dismissAppUpdateBanner,
                                          child: SizedBox(
                                            width: 36,
                                            height: 36,
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
                            ),
                          ),

                        // Android Local Container & DSH Boot Banner (physical-phone first-run & error recovery!)
                        if (showLocalAndroidBanner)
                          Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 680),
                              child: GrassBagGlass(
                                tier: shellSlice.glassTier,
                                borderRadius: 22,
                                elevated: true,
                                interactiveGlow: false,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                child: () {
                            final isBooting = shellSlice.nativeEngineState == 'starting';
                            final isExtracting = shellSlice.runtimeProgressPct > 0 &&
                                shellSlice.runtimeProgressPct < 100;
                            final isRemoteThin = !shellSlice.nativeHasBundledPayloads;
                            final isErr = shellSlice.nativeEngineState == 'error' ||
                                shellSlice.connectionPhase == ConnectionPhase.error;
                            final isStopped = shellSlice.nativeInitialized &&
                                shellSlice.nativeEngineState == 'stopped' &&
                                !isErr;
                            final title = isExtracting
                                ? (shellSlice.runtimeProgressCanCancel
                                    ? '正在下载本机环境 (${shellSlice.runtimeProgressPct}%)'
                                    : '正在部署本机容器 (${shellSlice.runtimeProgressPct}%)')
                                : isBooting
                                    ? '正在启动本机 DSH 核心…'
                                    : isErr
                                        ? '本机 DSH 引擎启动异常'
                                        : isStopped
                                            ? '本机 DSH 引擎已停止'
                                            : (isRemoteThin
                                                ? '本机运行环境尚未下载'
                                                : '本机 Linux 容器尚未初始化');
                            final sub = isExtracting
                                ? (shellSlice.runtimeProgressMsg.isNotEmpty
                                    ? shellSlice.runtimeProgressMsg
                                    : (isRemoteThin
                                        ? '支持镜像加速与断点续传，部署完成后可离线使用'
                                        : '首次解压仅需一次，完成后即可离线使用'))
                                : isBooting
                                    ? '高速模式加速冷启，通常仅需数秒'
                                    : isErr
                                        ? ((shellSlice.nativeEngineError?.isNotEmpty == true)
                                            ? shellSlice.nativeEngineError!
                                            : '请重试启动或查看容器运行诊断日志')
                                        : isStopped
                                            ? '点击启动引擎即可继续在本机容器内对话'
                                            : (isRemoteThin
                                                ? (shellSlice.nativeHasPartialDownload
                                                    ? '上次下载已保留断点，点击可继续下载（剩余 ${shellSlice.nativeDownloadSize}）'
                                                    : '按需下载 Ubuntu + Node + DSH（约 ${shellSlice.nativeDownloadSize}）')
                                                : '点击一键部署内置 Ubuntu + Node + DSH 引擎');
                            return Row(
                              children: [
                                GestureDetector(
                                  onTap: () => _openSettings(
                                    initialSection: isErr
                                        ? SettingsSection.diagnostics
                                        : SettingsSection.hosts,
                                    hostDetailId: isErr ? null : 'local',
                                  ),
                                  child: GrassBagSquircleIcon(
                                    icon: isErr
                                        ? CupertinoIcons.exclamationmark_triangle_fill
                                        : (isRemoteThin && !shellSlice.nativeInitialized
                                            ? CupertinoIcons.cloud_download_fill
                                            : CupertinoIcons.cube_box_fill),
                                    color: isErr ? t.err : t.primary,
                                    size: 36,
                                    iconSize: 17,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () => _openSettings(
                                      initialSection: isErr
                                          ? SettingsSection.diagnostics
                                          : SettingsSection.hosts,
                                      hostDetailId: isErr ? null : 'local',
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: isErr ? t.err : t.text,
                                          ),
                                        ),
                                        Text(
                                          sub,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 11.5, color: t.text2),
                                        ),
                                        if (isErr)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 2),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  '查看日志',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                    color: t.primary,
                                                  ),
                                                ),
                                                const SizedBox(width: 2),
                                                Icon(
                                                  CupertinoIcons.chevron_right,
                                                  size: 10.5,
                                                  color: t.primary,
                                                ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (isExtracting && shellSlice.runtimeProgressCanCancel)
                                  GrassBagSecondaryGlassButton(
                                    label: '暂停',
                                    height: 32,
                                    padding: const EdgeInsets.symmetric(horizontal: 11),
                                    tier: shellSlice.glassTier,
                                    insideGlass: true,
                                    onTap: () => ctrl.cancelLocalRuntimeBootstrap(),
                                  )
                                else if (isExtracting || isBooting)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 6),
                                    child: GrassBagActivityIndicator(radius: 9, color: t.primary),
                                  )
                                else
                                  GrassBagPrimaryGlassButton(
                                    label: !shellSlice.nativeInitialized
                                        ? (isRemoteThin
                                            ? (shellSlice.nativeHasPartialDownload ? '继续下载' : '下载部署')
                                            : '一键部署')
                                        : (isErr ? '重试启动' : '启动引擎'),
                                    height: 34,
                                    padding: const EdgeInsets.symmetric(horizontal: 13),
                                    tier: shellSlice.glassTier,
                                    insideGlass: true,
                                    onTap: () => !shellSlice.nativeInitialized
                                        ? triggerLocalRuntimeBootstrapWithGuard(context, ref)
                                        : ctrl.restartLocalEngine(),
                                  ),
                              ],
                            );
                          }(),
                        ),
                      ),
                    ),

                if (showLocalDesktopErrorBanner)
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: GrassBagGlass(
                        tier: shellSlice.glassTier,
                        borderRadius: 22,
                        elevated: true,
                        interactiveGlow: false,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _openSettings(
                                  initialSection: SettingsSection.hosts,
                                  hostDetailId: shellSlice.hostId,
                                ),
                                child: Row(
                                  children: [
                                    GrassBagSquircleIcon(
                                      icon: CupertinoIcons.wifi_exclamationmark,
                                      color: t.warn,
                                      size: 36,
                                      iconSize: 17,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '本机 DSH 服务暂未连通',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: t.text,
                                            ),
                                          ),
                                          Text(
                                            '确认本机服务运行后点击重试，或点此前往主机设置切换设备',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(fontSize: 11.5, color: t.text2),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GrassBagPrimaryGlassButton(
                              label: '重试',
                              height: 36,
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                              tier: shellSlice.glassTier,
                              insideGlass: true,
                              onTap: () => ctrl.probeAndRefreshHost(shellSlice.hostId),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Actionable Remote Host Issue Banner (ONLY shown when auth/TLS/network blocks connection;
                // never shown when connected via zero-plugin Vanilla Direct Mode!)
                if (showRemoteBasicBanner)
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: GrassBagGlass(
                        tier: shellSlice.glassTier,
                        borderRadius: 22,
                        elevated: true,
                        interactiveGlow: false,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: () {
                            final errCode = shellSlice.hostLastErrorCode ?? '';
                            final isHtmlProxy = errCode == 'html_proxy';
                            final isAuth = errCode == 'needs_auth' ||
                                isHtmlProxy ||
                                shellSlice.connectionPhase == ConnectionPhase.needsAuth;
                            final isTls = errCode == 'tls_cert';
                            final canWebLogin = !kIsWeb &&
                                defaultTargetPlatform == TargetPlatform.android;
                            final title = isAuth
                                ? '${shellSlice.hostName} · 请完成一次授权'
                                : (isTls
                                    ? '${shellSlice.hostName} · 证书未受信任'
                                    : '${shellSlice.hostName} · 连接未就绪');
                            final subtitle = isHtmlProxy
                                ? '点击通过网页登录网关认证，之后 30 天自动免密'
                                : (isAuth
                                    ? '已连通远程主机，粘贴一次启动链接或 Token 后 30 天免填'
                                    : (isTls
                                        ? '检测到自签名 HTTPS 证书，信任后立即连接'
                                        : '查看连通性诊断、桌面端免命令引导与启动命令'));
                            final btnLabel = isHtmlProxy && canWebLogin
                                ? '网页登录'
                                : (isAuth ? '去授权' : (isTls ? '信任证书' : '去修复'));
                            return Row(
                              children: [
                                GestureDetector(
                                  onTap: () => isAuth
                                      ? showRemoteHostAuthSheet(
                                          context,
                                          ref,
                                          ref.read(appProvider).activeHost,
                                        )
                                      : _openSettings(
                                          initialSection: SettingsSection.hosts,
                                          hostDetailId: shellSlice.hostId,
                                        ),
                                  child: GrassBagSquircleIcon(
                                    icon: isAuth
                                        ? CupertinoIcons.lock_shield_fill
                                        : CupertinoIcons.exclamationmark_triangle_fill,
                                    color: isAuth ? t.primary : (isTls ? t.warn : t.err),
                                    size: 36,
                                    iconSize: 17,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () => isAuth
                                        ? showRemoteHostAuthSheet(
                                            context,
                                            ref,
                                            ref.read(appProvider).activeHost,
                                          )
                                        : _openSettings(
                                            initialSection: SettingsSection.hosts,
                                            hostDetailId: shellSlice.hostId,
                                          ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            letterSpacing: -0.15,
                                            color: t.text,
                                          ),
                                        ),
                                        Text(
                                          subtitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 11.5, color: t.text2),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (!isAuth && !isTls) ...[
                                  GrassBagSecondaryGlassButton(
                                    label: '重试',
                                    height: 34,
                                    padding: const EdgeInsets.symmetric(horizontal: 11),
                                    tier: shellSlice.glassTier,
                                    insideGlass: true,
                                    onTap: () => ctrl.probeAndRefreshHost(shellSlice.hostId),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                GrassBagPrimaryGlassButton(
                                  label: btnLabel,
                                  height: 34,
                                  padding: const EdgeInsets.symmetric(horizontal: 13),
                                  tier: shellSlice.glassTier,
                                  insideGlass: true,
                                  onTap: () async {
                                    if (isHtmlProxy && canWebLogin) {
                                      final cookie = await Navigator.of(context).push<String>(
                                        GrassBagPageRoute<String>(
                                          builder: (_) => RemoteWebLoginPage(
                                            hostName: shellSlice.hostName,
                                            baseAddress: shellSlice.hostAddress,
                                            allowBadCertificates: shellSlice.hostAllowBadCerts,
                                          ),
                                        ),
                                      );
                                      if (cookie != null && cookie.trim().isNotEmpty) {
                                        await ctrl.updateHostCookie(
                                          shellSlice.hostId,
                                          cookie,
                                          switchAndConnect: true,
                                        );
                                      }
                                    } else if (isAuth) {
                                      showRemoteHostAuthSheet(
                                        context,
                                        ref,
                                        ref.read(appProvider).activeHost,
                                      );
                                    } else if (isTls) {
                                      await ctrl.setHostAllowBadCertificates(shellSlice.hostId, true);
                                    } else {
                                      _openSettings(
                                        initialSection: SettingsSection.hosts,
                                        hostDetailId: shellSlice.hostId,
                                      );
                                    }
                                  },
                                ),
                              ],
                            );
                          }(),
                        ),
                      ),
                    ),

                // Subagent back-stack breadcrumb: 1-tap return to parent chat!
                GrassBagSmoothDisclosure(
                  expanded: shellSlice.parentSessionId != null,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Center(
                      child: GrassBagGlassPillButton(
                        tier: shellSlice.glassTier,
                        height: 36,
                        padding: const EdgeInsets.symmetric(horizontal: 13),
                        onTap: ctrl.returnToParentSession,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(CupertinoIcons.chevron_left, size: 13, color: t.primary),
                            const SizedBox(width: 4),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 240),
                              child: Text(
                                '返回主对话「${shellSlice.parentSessionTitle ?? '主对话'}」',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: t.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Compact background-session approval alert pill (isolated ConsumerWidget!)
                _BackgroundApprovalBannerPill(tier: shellSlice.glassTier),

                // In-App Live Phone-Control Floating Pill stacked cleanly inside the same
                // measured Column so it NEVER overlaps another top status banner at any font scale!
                _LivePhoneControlOverlayPill(hasSiblingBannerAbove: hasNonPhoneTopBanner),
                      ],
                    ),
                  ),
                ),

                // Isolated 120fps IME-Synced Floating Composer Anchor (pure GPU Transform.translate:
                // ZERO layout passes and ZERO top-bar/ListView rebuilds as keyboard slides up/down!)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: baseComposerBottom,
                  child: _KeyboardBottomInsetLift(
                    baseBottom: baseComposerBottom,
                    topClearance: topPad + 66.0,
                    topBannerHeightNotifier: _topBannerStackHeight,
                    child: ChatComposerDock(
                      controller: _composerCtrl,
                      focusNode: _composerFocus,
                      onOpenTerminal: _openTerminal,
                      onOpenModelSettings: () => _openSettings(initialSection: SettingsSection.model),
                      onOpenHostSettings: () => _openSettings(
                        initialSection: SettingsSection.hosts,
                        hostDetailId: shellSlice.hostId,
                      ),
                      plusOpenNotifier: _plusOpenNotifier,
                      suggestionsOpenNotifier: _suggestionsOpenNotifier,
                      editingContextNotifier: _editingContextNotifier,
                      showScrollToBottomListenable: _showScrollToBottomNotifier,
                      hasNewBelowListenable: _hasNewBelowNotifier,
                      composerHeightNotifier: _composerHeightNotifier,
                      onScrollToBottom: _jumpBackToBottom,
                      // Scroll-to-bottom on send is driven deterministically by `scrollSignal`
                      // right when the optimistic bubble mounts, so post-network `onMessageSent`
                      // never yanks a user who deliberately scrolled up while waiting.
                    ),
                  ),
                ),
              ],
            ),
            ),
          ),
        ],
    );

    if (isTab && _drawerCtrl.value > 0.0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _drawerCtrl.value > 0.0) {
          _drawerCtrl.value = 0.0;
        }
      });
    }

    final mainBody = isTab
        ? Row(
            children: [
              // Smoothly animated docked Tablet Left Sidebar (isolated in RepaintBoundary!)
              _AnimatedTabletPane(
                open: shellSlice.tabletSidebarOpen,
                width: 288,
                alignment: Alignment.centerRight,
                child: RepaintBoundary(
                  child: SessionsSidebar(
                    isTabletDocked: true,
                    backHandlerNotifier: _drawerBackHandler,
                    onOpenTerminal: _openTerminal,
                    onOpenFeatures: _openAllFeatures,
                    onOpenSettings: () => _openSettings(),
                    onOpenHostsSettings: () =>
                        _openSettings(initialSection: SettingsSection.hosts),
                  ),
                ),
              ),
              Expanded(child: chatStage),
              // Smoothly animated docked Tablet Right Workbench (unmounted when collapsed -> 0 rebuilds!)
              _AnimatedTabletPane(
                open: effectiveTabWorkbenchOpen,
                snapClose: false,
                width: 348,
                alignment: Alignment.centerLeft,
                keepAlive: false,
                child: RepaintBoundary(
                  child: SessionDetailContent(
                    isTabletPane: true,
                    onClose: () => ctrl.setTabletWorkbenchOpen(false),
                    onOpenTerminal: _openTerminal,
                    onOpenWebUi: _openWebUi,
                    onOpenHostDetail: (id) => _openSettings(
                      initialSection: SettingsSection.hosts,
                      hostDetailId: id,
                    ),
                  ),
                ),
              ),
            ],
          )
        : Builder(
            builder: (context) {
              final effectiveDrawerW = math.min(_phoneDrawerWidth, math.max(220.0, screenSize.width - 48.0));
              // Hoist the floating drawer subtree outside AnimatedBuilder so sliding the drawer
              // triggers ZERO widget rebuilds & ZERO layout passes on every 120fps animation tick!
              final cachedDrawer = RepaintBoundary(
                child: GestureDetector(
                  onHorizontalDragStart: (_) => _drawerCtrl.stop(),
                  onHorizontalDragUpdate: (d) {
                    _drawerCtrl.value =
                        (_drawerCtrl.value + d.delta.dx / effectiveDrawerW).clamp(0.0, 1.0);
                  },
                  onHorizontalDragEnd: (d) {
                    final vel = d.velocity.pixelsPerSecond.dx / effectiveDrawerW;
                    if (vel > 0.5) {
                      _animateDrawerTo(1.0, velocity: vel);
                    } else if (vel < -0.5 || _drawerCtrl.value < 0.65) {
                      _animateDrawerTo(0.0, velocity: vel);
                    } else {
                      _animateDrawerTo(1.0, velocity: vel);
                    }
                  },
                  onHorizontalDragCancel: () =>
                      _animateDrawerTo(_drawerCtrl.value > 0.5 ? 1.0 : 0.0),
                  child: SessionsSidebar(
                    isTabletDocked: false,
                    onCloseDrawer: _closePhoneDrawer,
                    backHandlerNotifier: _drawerBackHandler,
                    onOpenTerminal: _openTerminal,
                    onOpenFeatures: _openAllFeatures,
                    onOpenSettings: () => _openSettings(),
                    onOpenHostsSettings: () =>
                        _openSettings(initialSection: SettingsSection.hosts),
                  ),
                ),
              );

              return AnimatedBuilder(
                animation: _drawerCtrl,
                child: RepaintBoundary(child: chatStage),
                builder: (context, stageChild) {
                  final v = _drawerCtrl.value.clamp(0.0, 1.0);
                  final easedV = Curves.easeOutCubic.transform(v);
                  final drawerActive = v > 0.001;
                  final reduceMotion = MediaQuery.disableAnimationsOf(context);
                  final parallaxX = reduceMotion ? 0.0 : (14.0 * easedV);

                  // Apply compositor-only GPU parallax Transform OUTSIDE `RepaintBoundary(child: chatStage)`
                  // so the chat stage shifts gently for depth while keeping 100% cached VRAM layers
                  // (ZERO full-screen glass re-rasterization, ZERO ListView/TextField remounts!).
                  return Stack(
                    children: [
                      Transform.translate(
                        offset: Offset(parallaxX, 0),
                        child: ExcludeSemantics(
                          excluding: v > 0.06,
                          child: FocusScope(
                            canRequestFocus: v <= 0.06,
                            child: IgnorePointer(
                              ignoring: v > 0.06,
                              child: stageChild,
                            ),
                          ),
                        ),
                      ),

                      if (drawerActive)
                        // Interactive Backdrop Scrim with eased alpha curve
                        Positioned.fill(
                          child: GestureDetector(
                            onTap: _closePhoneDrawer,
                            onHorizontalDragStart: (_) => _drawerCtrl.stop(),
                            onHorizontalDragUpdate: (d) {
                              _drawerCtrl.value =
                                  (_drawerCtrl.value + d.delta.dx / effectiveDrawerW)
                                      .clamp(0.0, 1.0);
                            },
                            onHorizontalDragEnd: (d) {
                              final vel = d.velocity.pixelsPerSecond.dx / effectiveDrawerW;
                              if (vel > 0.5) {
                                _animateDrawerTo(1.0, velocity: vel);
                              } else if (vel < -0.5 || _drawerCtrl.value < 0.65) {
                                _animateDrawerTo(0.0, velocity: vel);
                              } else {
                                _animateDrawerTo(1.0, velocity: vel);
                              }
                            },
                            onHorizontalDragCancel: () =>
                                _animateDrawerTo(_drawerCtrl.value > 0.5 ? 1.0 : 0.0),
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: (t.isDark ? 0.44 : 0.28) * easedV),
                            ),
                          ),
                        ),

                      // Keep phone drawer warm via Offstage + TickerMode so Frame 1 of swipe-open
                      // has ZERO cold-mount hitch while painting ZERO shaders & running ZERO tickers
                      // whenever closed!
                      Positioned(
                        top: 0,
                        bottom: 0,
                        left: 0,
                        width: effectiveDrawerW,
                        child: Offstage(
                          offstage: !drawerActive,
                          child: TickerMode(
                            enabled: drawerActive,
                            child: Transform.translate(
                              offset: Offset(-effectiveDrawerW * (1.0 - v), 0),
                              child: cachedDrawer,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          );

    return ListenableBuilder(
      listenable: _backScopeListenable,
      builder: (context, child) {
        final drawerVisible =
            isTab ? shellSlice.tabletSidebarOpen : _drawerOpenForBackNotifier.value;
        // Only treat composer focus or an active EditableText as focused — passive taps on
        // read-only SelectionArea bubbles must NEVER silently swallow Android Back!
        final primaryFocusCtx = FocusManager.instance.primaryFocus?.context;
        final isEditableFocused = primaryFocusCtx != null &&
            (primaryFocusCtx.widget is EditableText ||
                primaryFocusCtx.findAncestorWidgetOfExactType<EditableText>() != null);
        final anyFocused = _composerFocus.hasFocus || isEditableFocused;
        final hasParentSession = ref.read(appProvider).parentSessionId != null;
        final hasOpenOverlay = (!isTab && _drawerOpenForBackNotifier.value) ||
            _inChatSearchOpen ||
            _plusOpenNotifier.value ||
            _suggestionsOpenNotifier.value ||
            _editingContextNotifier.value != null ||
            (isTab && effectiveTabWorkbenchOpen) ||
            hasParentSession ||
            anyFocused;
        final guardAndroidRootExit =
            !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
        return PopScope(
          canPop: !widget.isSplashCovered && !hasOpenOverlay && !guardAndroidRootExit,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || widget.isSplashCovered) return;
            // On Phone, the drawer is a top-most modal slide-over so Back closes it first.
            if (!isTab && drawerVisible) {
              final handledInsideDrawer = _drawerBackHandler.value?.call() ?? false;
              if (handledInsideDrawer) return;
              _closePhoneDrawer();
              return;
            }
            if (_inChatSearchOpen) {
              _closeInChatSearch();
              return;
            }
            if (_plusOpenNotifier.value) {
              _plusOpenNotifier.value = false;
              return;
            }
            if (_suggestionsOpenNotifier.value) {
              _suggestionsOpenNotifier.value = false;
              return;
            }
            if (_editingContextNotifier.value != null) {
              _cancelEditingTurn();
              return;
            }
            if (isTab && effectiveTabWorkbenchOpen) {
              ctrl.setTabletWorkbenchOpen(false);
              return;
            }
            if (isTab && drawerVisible) {
              final handledInsideDrawer = _drawerBackHandler.value?.call() ?? false;
              if (handledInsideDrawer) return;
            }
            if (anyFocused) {
              _dismissKeyboardAndPopovers();
              return;
            }
            if (ref.read(appProvider).parentSessionId != null) {
              ctrl.returnToParentSession();
              return;
            }
            if (guardAndroidRootExit) {
              final now = DateTime.now();
              if (_lastBackPressedAt == null ||
                  now.difference(_lastBackPressedAt!) > const Duration(seconds: 2)) {
                _lastBackPressedAt = now;
                ctrl.showToast('再按一次返回退出 GrassBag', tone: ToastTone.info);
              } else {
                _lastBackPressedAt = null;
                SystemNavigator.pop();
              }
            }
          },
          child: child!,
        );
      },
      child: CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () => ctrl.startNewChat(),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => ctrl.startNewChat(),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _openInChatSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _openInChatSearch,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          // CRITICAL CJK IME guard: let Escape dismiss Pinyin/Kana candidate popups in ANY
          // focused text field (composer, drawer search, or in-chat search) before app actions!
          final primaryCtx = FocusManager.instance.primaryFocus?.context;
          final activeEditable = primaryCtx?.findAncestorStateOfType<EditableTextState>();
          final activeComposing = activeEditable?.currentTextEditingValue.composing ??
              (_composerFocus.hasFocus ? _composerCtrl.value.composing : TextRange.empty);
          if (activeComposing.isValid && !activeComposing.isCollapsed) {
            return;
          }
          if (_inChatSearchOpen) {
            _closeInChatSearch();
            return;
          }
          final drawerVisible = isTab ? shellSlice.tabletSidebarOpen : _drawerCtrl.value > 0.05;
          if (!isTab && drawerVisible && _drawerBackHandler.value?.call() == true) {
            return;
          }
          if (!isTab && _drawerCtrl.value > 0.05) {
            _closePhoneDrawer();
          } else if (_suggestionsOpenNotifier.value) {
            _suggestionsOpenNotifier.value = false;
          } else if (_plusOpenNotifier.value) {
            _plusOpenNotifier.value = false;
          } else if (_editingContextNotifier.value != null) {
            _cancelEditingTurn();
          } else if (isTab && drawerVisible && _drawerBackHandler.value?.call() == true) {
            return;
          } else {
            final cur = ref.read(appProvider);
            final hasTakeover = cur.pendingApprovalCommand != null ||
                cur.activeQuestion != null ||
                cur.activeCordisRequest != null;
            if (cur.isStreaming && !cur.isStopping && !hasTakeover) {
              // Flush latest composer text immediately so Stop restoring queued messages
              // merges cleanly with typing done within the 400ms debounce window!
              final draftToFlush = _editingContextNotifier.value?.stashedDraft ?? _composerCtrl.text;
              ctrl.setComposerDraftForActiveHost(draftToFlush);
              ctrl.cancelStreaming();
            }
          }
        },
      },
      child: GrassBagGlassPage(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: false,
          body: _ImeMotionCoordinator(
            child: Stack(
              children: [
                mainBody,
                // Bottom-Centered Liquid Glass Toast isolated from GrassBagShell viewInsets rebuilds!
                _KeyboardAwareToastSlot(
                  baseComposerBottom: baseComposerBottom,
                  plusOpenNotifier: _plusOpenNotifier,
                  suggestionsOpenNotifier: _suggestionsOpenNotifier,
                  composerHeightNotifier: _composerHeightNotifier,
                  drawerOpenNotifier: _drawerOpenForBackNotifier,
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

/// Custom [ScrollController] whose [ScrollPosition] consumes queued IME tail-growth deltas
/// synchronously inside `applyContentDimensions` — BEFORE the frame paints — completely
/// eliminating the 1-frame sawtooth vibration between rising Composer and chat bubbles!
class _ImeLockStepScrollController extends ScrollController {
  bool allowImeAnchor = true;

  void queueImeAnchorDelta(double delta) {
    if (delta.abs() <= 0.05 || !allowImeAnchor) return;
    if (!hasClients || positions.length != 1) return;
    final pos = position;
    if (pos is _ImeLockStepScrollPosition) {
      pos.queueImeAnchorDelta(delta);
    }
  }

  void clearPendingImeAnchor() {
    if (!hasClients) return;
    for (final pos in positions) {
      if (pos is _ImeLockStepScrollPosition) {
        pos.clearPendingImeAnchor();
      }
    }
  }

  bool get isUserDrivenScroll {
    if (!hasClients || positions.length != 1) return false;
    final pos = position;
    return pos is _ImeLockStepScrollPosition && pos.isUserDrivenActivity;
  }

  /// Immediately stops residual upward ballistic fling momentum when the user sends a message
  /// or taps Scroll-to-Bottom, so auto-follow re-engages without waiting for fling decay.
  void cancelMomentumAndHold() {
    if (!hasClients || positions.length != 1) return;
    final pos = position;
    if (pos is _ImeLockStepScrollPosition) {
      pos.cancelMomentumAndHold();
    }
  }

  /// Advances scroll offset smoothly during 60/120Hz stream auto-follow without tearing down
  /// ScrollActivity or blasting 360 Start/Update/End notifications per second via `jumpTo`.
  void chaseTo(double targetPixels) {
    if (!hasClients || positions.length != 1) return;
    final pos = position;
    if (pos is _ImeLockStepScrollPosition) {
      pos.chaseTo(targetPixels);
    } else {
      jumpTo(targetPixels);
    }
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _ImeLockStepScrollPosition(
      controller: this,
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

class _ImeLockStepScrollPosition extends ScrollPositionWithSingleContext {
  _ImeLockStepScrollPosition({
    required this.controller,
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final _ImeLockStepScrollController controller;
  double _pendingImeAnchorDelta = 0.0;

  void queueImeAnchorDelta(double delta) {
    _pendingImeAnchorDelta += delta;
  }

  void clearPendingImeAnchor() {
    _pendingImeAnchorDelta = 0.0;
  }

  bool get isUserDrivenActivity =>
      activity is DragScrollActivity || activity is BallisticScrollActivity;

  void cancelMomentumAndHold() {
    if (activity is BallisticScrollActivity) {
      goIdle();
    }
  }

  void chaseTo(double targetPixels) {
    if (!hasPixels ||
        !hasContentDimensions ||
        isUserDrivenActivity ||
        activity is DrivenScrollActivity) {
      return;
    }
    final clamped = targetPixels.clamp(minScrollExtent, maxScrollExtent);
    if ((clamped - pixels).abs() <= 0.01) return;
    forcePixels(clamped);
  }

  @override
  double applyBoundaryConditions(double value) => super.applyBoundaryConditions(value);

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    if (_pendingImeAnchorDelta.abs() > 0.05) {
      final delta = _pendingImeAnchorDelta;
      _pendingImeAnchorDelta = 0.0;
      if (controller.allowImeAnchor &&
          oldPosition.hasContentDimensions &&
          oldPosition.hasPixels) {
        final prevMax = oldPosition.maxScrollExtent;
        final distFromPrevBottom =
            (prevMax - oldPosition.pixels).clamp(0.0, double.infinity);
        final wasBottomAnchored = prevMax <= 12.0 || distFromPrevBottom <= 76.0;
        if (wasBottomAnchored) {
          if (delta > 0.05 && newPosition.maxScrollExtent > prevMax + 0.1) {
            final growth = newPosition.maxScrollExtent - prevMax;
            final shift = math.min(delta, growth);
            final nextPixels = (oldPosition.pixels + shift).clamp(
              newPosition.minScrollExtent,
              newPosition.maxScrollExtent,
            );
            if ((nextPixels - pixels).abs() > 0.1) {
              correctPixels(nextPixels);
              // Returning `false` tells `RenderViewport.performLayout()` to re-run
              // layout immediately at `nextPixels` on this exact frame (zero 1-frame lag!).
              return false;
            }
          } else if (delta < -0.05 && newPosition.maxScrollExtent < prevMax - 0.1) {
            final shrink = prevMax - newPosition.maxScrollExtent;
            final shift = math.min(-delta, shrink);
            final nextPixels = (oldPosition.pixels - shift).clamp(
              newPosition.minScrollExtent,
              newPosition.maxScrollExtent,
            );
            if ((nextPixels - pixels).abs() > 0.1) {
              correctPixels(nextPixels);
              return false;
            }
          }
        }
      }
    }
    return super.correctForNewDimensions(oldPosition, newPosition);
  }
}

/// Immutable handle of 120Hz IME spring listenables shared via [_ImeMotionScope]
/// (`updateShouldNotify => false` so zero shell/chat widgets rebuild on keyboard ticks!).
class _ImeMotionData {
  _ImeMotionData({
    required this.insetNotifier,
    required this.openProgressNotifier,
    required this.knownKeyboardHeightNotifier,
  });

  /// Smooth logical-pixel keyboard inset: locks 1:1 to continuous OS animations and
  /// glides via critically-damped iOS 26 spring whenever Android OEM IMEs jump or resize!
  final ValueListenable<double> insetNotifier;

  /// Independent 0.0 (closed) → 1.0 (open) critically-damped choreography spring driving
  /// the Empty Stage monotonic hero glide & staggered 4-card cascade with zero twitching.
  final ValueListenable<double> openProgressNotifier;

  /// Remembered full open keyboard height (default 300px) so Empty Stage centering stays
  /// rock-steady even if OEM suggestion bars nudge inset height mid-session.
  final ValueListenable<double> knownKeyboardHeightNotifier;
}

class _ImeMotionScope extends InheritedWidget {
  const _ImeMotionScope({
    required this.data,
    required super.child,
  });

  final _ImeMotionData data;

  static _ImeMotionData? of(BuildContext context) {
    return context.getInheritedWidgetOfExactType<_ImeMotionScope>()?.data;
  }

  @override
  bool updateShouldNotify(covariant _ImeMotionScope oldWidget) => false;
}

/// Single isolated subscriber to `MediaQuery.viewInsetsOf(context).bottom` for the main
/// stage. Translates noisy/snap Android IME transitions into silky 120Hz critically-damped
/// springs while locking 1:1 onto native OS frame-by-frame IME animations with zero gap!
class _ImeMotionCoordinator extends StatefulWidget {
  const _ImeMotionCoordinator({required this.child});

  final Widget child;

  @override
  State<_ImeMotionCoordinator> createState() => _ImeMotionCoordinatorState();
}

class _ImeMotionCoordinatorState extends State<_ImeMotionCoordinator>
    with TickerProviderStateMixin {
  static final SpringDescription _insetSpring = SpringDescription.withDampingRatio(
    mass: 1.0,
    stiffness: 380.0,
    ratio: 1.0,
  );
  static final SpringDescription _toolbarSpring = SpringDescription.withDampingRatio(
    mass: 1.0,
    stiffness: 480.0,
    ratio: 1.0,
  );
  static final SpringDescription _choreographySpring = SpringDescription.withDampingRatio(
    mass: 1.0,
    stiffness: 260.0,
    ratio: 1.0,
  );

  late final AnimationController _insetCtrl;
  late final AnimationController _openCtrl;
  final ValueNotifier<double> _insetNotifier = ValueNotifier<double>(0.0);
  final ValueNotifier<double> _openProgressNotifier = ValueNotifier<double>(0.0);
  final ValueNotifier<double> _knownKbHeightNotifier = ValueNotifier<double>(300.0);
  late final _ImeMotionData _data;

  bool _initialized = false;
  double _lastRawKb = 0.0;
  double _lastRawDeltaSign = 0.0;
  int _lastRawChangeUs = 0;
  int _consecutiveStreamFrames = 0;
  double _openTarget = 0.0;
  Timer? _knownKbSettleTimer;

  @override
  void initState() {
    super.initState();
    _insetCtrl = AnimationController.unbounded(vsync: this, value: 0.0)
      ..addListener(() {
        final v = _insetCtrl.value.clamp(0.0, 2000.0);
        if ((v - _insetNotifier.value).abs() > 0.05) {
          _insetNotifier.value = v;
        }
      });
    _openCtrl = AnimationController.unbounded(vsync: this, value: 0.0)
      ..addListener(() {
        final v = _openCtrl.value.clamp(0.0, 1.0);
        if ((v - _openProgressNotifier.value).abs() > 0.0005) {
          _openProgressNotifier.value = v;
        }
      });
    _data = _ImeMotionData(
      insetNotifier: _insetNotifier,
      openProgressNotifier: _openProgressNotifier,
      knownKeyboardHeightNotifier: _knownKbHeightNotifier,
    );
  }

  @override
  void dispose() {
    _knownKbSettleTimer?.cancel();
    _insetCtrl.dispose();
    _openCtrl.dispose();
    _insetNotifier.dispose();
    _openProgressNotifier.dispose();
    _knownKbHeightNotifier.dispose();
    super.dispose();
  }

  void _syncRawInset(double rawKb) {
    if (!_initialized) {
      _initialized = true;
      _lastRawKb = rawKb;
      _insetCtrl.value = rawKb;
      _insetNotifier.value = rawKb;
      final initOpen = rawKb > 24.0 ? 1.0 : 0.0;
      _openTarget = initOpen;
      _openCtrl.value = initOpen;
      _openProgressNotifier.value = initOpen;
      if (rawKb >= 140.0) _knownKbHeightNotifier.value = rawKb;
      return;
    }

    final delta = rawKb - _lastRawKb;
    if (delta.abs() < 0.5) return;

    final nowUs = SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle
        ? SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds
        : DateTime.now().microsecondsSinceEpoch;
    final dtMs = (_lastRawChangeUs == 0 || nowUs < _lastRawChangeUs)
        ? 999.0
        : (nowUs - _lastRawChangeUs) / 1000.0;
    final sign = delta > 0 ? 1.0 : -1.0;
    final sameDir = _lastRawDeltaSign == sign;

    if (dtMs <= 48.0 && sameDir) {
      _consecutiveStreamFrames++;
    } else {
      _consecutiveStreamFrames = 0;
    }

    final prevRaw = _lastRawKb;
    _lastRawKb = rawKb;
    _lastRawDeltaSign = sign;
    _lastRawChangeUs = nowUs;

    if (rawKb >= 140.0) {
      if (rawKb > _knownKbHeightNotifier.value + 2.0) {
        _knownKbSettleTimer?.cancel();
        _knownKbHeightNotifier.value = rawKb;
      } else if ((rawKb - _knownKbHeightNotifier.value).abs() > 4.0) {
        // Wait briefly before shrinking knownKeyboardHeight so mid-stream OS frames
        // (e.g. 140 → 200 → 310) never pull `openTop` downward and then snap back up!
        _knownKbSettleTimer?.cancel();
        _knownKbSettleTimer = Timer(const Duration(milliseconds: 140), () {
          if (mounted && _lastRawKb >= 140.0 && (_lastRawKb - _knownKbHeightNotifier.value).abs() > 4.0) {
            _knownKbHeightNotifier.value = _lastRawKb;
          }
        });
      }
    } else {
      _knownKbSettleTimer?.cancel();
    }

    // 1. Update smooth inset tracker:
    //    - Continuous OS 60/120Hz IME animation -> lock 1:1 synchronously (zero gap!)
    //    - Once 2+ consecutive native stream frames arrive, hand back to 1:1 tracking even if
    //      a spring was running (prevents spring-lag lockout on fast Android 120Hz IME frames!)
    //    - Single-frame OEM jump (> 180px) or post-settle toolbar resize -> smooth spring!
    final isNativeStream = _consecutiveStreamFrames >= 1 ||
        (delta.abs() <= 180.0 && !(prevRaw > 100.0 && rawKb > 100.0 && dtMs > 70.0));
    final hasLargeSpringGap = _consecutiveStreamFrames < 2 &&
        _insetCtrl.isAnimating &&
        (rawKb - _insetNotifier.value).abs() > 16.0;
    if (isNativeStream && !hasLargeSpringGap) {
      if (_insetCtrl.isAnimating) {
        _insetCtrl.stop();
      }
      _insetCtrl.value = rawKb;
      _insetNotifier.value = rawKb;
    } else {
      final spring = (prevRaw > 100.0 && rawKb > 100.0) || hasLargeSpringGap
          ? _toolbarSpring
          : _insetSpring;
      final sim = SpringSimulation(
        spring,
        _insetNotifier.value,
        rawKb,
        _insetCtrl.velocity.clamp(-2400.0, 2400.0),
        tolerance: const Tolerance(distance: 0.4, velocity: 1.0),
      );
      _insetCtrl.animateWith(sim);
    }

    // 2. Drive independent choreography spring with hysteresis (24px open / 12px close)
    //    so Empty Stage ALWAYS plays a silky, jitter-free 300ms spring morph!
    final nextOpenTarget = rawKb > 24.0
        ? 1.0
        : (rawKb <= 12.0 ? 0.0 : _openTarget);
    if ((nextOpenTarget - _openTarget).abs() > 0.01) {
      _openTarget = nextOpenTarget;
      final sim = SpringSimulation(
        _choreographySpring,
        _openProgressNotifier.value,
        nextOpenTarget,
        _openCtrl.velocity.clamp(-6.0, 6.0),
        tolerance: const Tolerance(distance: 0.002, velocity: 0.01),
      );
      _openCtrl.animateWith(sim);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Every subscriber to `_ImeMotionScope` is strictly a descendant of this coordinator,
    // so Flutter's BuildOwner permits marking those descendants dirty synchronously here
    // and rebuilds them in the exact same frame (zero 1-frame IME lag!).
    _syncRawInset(MediaQuery.viewInsetsOf(context).bottom);
  }

  @override
  Widget build(BuildContext context) {
    return _ImeMotionScope(
      data: _data,
      child: widget.child,
    );
  }
}

/// Tiny leaf widget that isolates smooth IME bottom lift for the floating composer dock
/// using pure GPU `Transform.translate` so keyboard open/close runs at silky 120fps with
/// ZERO layout passes and ZERO `RenderLiquidGlassLayer.layout()` (`toImageSync`) re-captures!
class _KeyboardBottomInsetLift extends StatelessWidget {
  const _KeyboardBottomInsetLift({
    required this.baseBottom,
    required this.topClearance,
    required this.topBannerHeightNotifier,
    required this.child,
  });

  final double baseBottom;
  final double topClearance;
  final ValueListenable<double> topBannerHeightNotifier;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ime = _ImeMotionScope.of(context);
    final screenH = MediaQuery.sizeOf(context).height;

    Widget buildLift(double kbInset, double settledKbHeight, double bannerH) {
      final effectiveTopClearance = topClearance + (bannerH > 0.5 ? bannerH + 10.0 : 0.0);
      // Continuous max(...) avoids any 32px discontinuity snap when kbInset crosses 0 <-> 1px!
      final targetBottom = math.max(baseBottom, kbInset + 8.0);
      final lift = (targetBottom - baseBottom).clamp(0.0, double.infinity);
      // Subtract settled open keyboard height (not animated per-frame `kbInset`) when the keyboard
      // is open so `/` & `@` popovers NEVER fly behind the top bar while keeping `maxDockHeight`
      // steady across 120Hz IME flight frames (zero `toImageSync` glass rebakes!).
      final double maxDockHeight;
      if (screenH <= 160.0) {
        maxDockHeight = double.infinity;
      } else {
        final effectiveBottom = kbInset > 24.0
            ? math.max(baseBottom, math.max(settledKbHeight, kbInset) + 8.0)
            : baseBottom;
        maxDockHeight = (screenH - effectiveBottom - effectiveTopClearance).clamp(160.0, screenH);
      }
      // Always keep Transform.translate mounted (Offset.zero at rest is a zero-cost
      // identity transform) so child TextField NEVER remounts & drops IME connection!
      return Transform.translate(
        offset: Offset(0, -lift),
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1.0,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxDockHeight),
            child: child,
          ),
        ),
      );
    }

    return ValueListenableBuilder<double>(
      valueListenable: topBannerHeightNotifier,
      builder: (_, bannerH, __) {
        if (ime == null) {
          final raw = MediaQuery.viewInsetsOf(context).bottom;
          return buildLift(raw, raw, bannerH);
        }
        return ListenableBuilder(
          listenable: Listenable.merge([ime.insetNotifier, ime.knownKeyboardHeightNotifier]),
          builder: (_, __) => buildLift(
            ime.insetNotifier.value,
            ime.knownKeyboardHeightNotifier.value,
            bannerH,
          ),
        );
      },
    );
  }
}

/// Isolated bottom scrim that tracks real live composer height AND lifts above the soft IME
/// via pure GPU `Transform.translate` in exact lock-step with [_KeyboardBottomInsetLift]!
class _KeyboardAwareBottomScrim extends StatelessWidget {
  const _KeyboardAwareBottomScrim({
    required this.tier,
    required this.baseComposerBottom,
    required this.composerHeightNotifier,
  });

  final GrassBagGlassTier tier;
  final double baseComposerBottom;
  final ValueNotifier<double> composerHeightNotifier;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final effectiveTier = resolveEffectiveGlassTier(context, tier);
    final ime = _ImeMotionScope.of(context);
    final isSolid = effectiveTier == GrassBagGlassTier.solid;
    // Whisper-light pure-gradient bottom edge feather (zero extra full-width BackdropFilter!)
    // so scrolled chat messages remain crystal clear & visibly refract through the floating composer!
    final scrimDecoration = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          t.bgSolid.withValues(
            alpha: isSolid
                ? (t.isDark ? 0.56 : 0.44)
                : (t.isDark ? 0.24 : 0.18),
          ),
          t.bgSolid.withValues(alpha: isSolid ? (t.isDark ? 0.18 : 0.14) : (t.isDark ? 0.06 : 0.04)),
          t.bgSolid.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.46, 1.0],
      ),
    );

    Widget buildWithInset(double kbInset) {
      final targetBottom = math.max(baseComposerBottom, kbInset + 8.0);
      final lift = (targetBottom - baseComposerBottom).clamp(0.0, double.infinity);
      return ValueListenableBuilder<double>(
        valueListenable: composerHeightNotifier,
        builder: (_, compH, __) {
          final restingH = baseComposerBottom + math.min(compH + 10.0, 220.0);
          return Transform.translate(
            offset: Offset(0, -lift),
            child: IgnorePointer(
              child: SizedBox(
                height: restingH,
                child: DecoratedBox(decoration: scrimDecoration),
              ),
            ),
          );
        },
      );
    }

    if (ime == null) {
      return buildWithInset(MediaQuery.viewInsetsOf(context).bottom);
    }
    return ValueListenableBuilder<double>(
      valueListenable: ime.insetNotifier,
      builder: (_, kbInset, __) => buildWithInset(kbInset),
    );
  }
}

/// Zero-frame-lag trailing spacer inside chat `ListView.builder` tracking live composer
/// height + smooth IME inset. Queues upward deltas into [_ImeLockStepScrollController] so
/// `applyContentDimensions` updates scroll offset BEFORE painting the same frame!
class _KeyboardScrollTail extends StatefulWidget {
  const _KeyboardScrollTail({
    super.key,
    required this.baseComposerBottom,
    required this.composerHeightNotifier,
    required this.scrollCtrl,
  });

  final double baseComposerBottom;
  final ValueNotifier<double> composerHeightNotifier;
  final ScrollController scrollCtrl;

  @override
  State<_KeyboardScrollTail> createState() => _KeyboardScrollTailState();
}

class _KeyboardScrollTailState extends State<_KeyboardScrollTail> {
  double _lastBottomGap = 0.0;
  bool _initialized = false;

  void _syncGapDelta(double bottomGap) {
    if (!_initialized) {
      _initialized = true;
      _lastBottomGap = bottomGap;
      return;
    }
    final delta = bottomGap - _lastBottomGap;
    if (delta.abs() > 0.1) {
      _lastBottomGap = bottomGap;
      final ctrl = widget.scrollCtrl;
      if (ctrl is _ImeLockStepScrollController) {
        ctrl.queueImeAnchorDelta(delta);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ime = _ImeMotionScope.of(context);

    Widget buildSpacer(double kbInset) {
      final bottomGap = math.max(widget.baseComposerBottom, kbInset + 8.0);
      return ValueListenableBuilder<double>(
        valueListenable: widget.composerHeightNotifier,
        builder: (_, compH, __) {
          final totalTail = bottomGap + compH;
          _syncGapDelta(totalTail);
          return SizedBox(height: totalTail + 24.0);
        },
      );
    }

    if (ime == null) {
      return buildSpacer(MediaQuery.viewInsetsOf(context).bottom);
    }
    return ValueListenableBuilder<double>(
      valueListenable: ime.insetNotifier,
      builder: (_, kbInset, __) => buildSpacer(kbInset),
    );
  }
}

/// Isolated Chat Canvas Area watching ONLY `turns.length` (NEVER `s.turns`!).
/// Inside `ListView.builder`, each slot is a `_TurnListItem` watching ONLY `s.turns[index]`:
/// completed turns hold identical object references -> ZERO rebuilds during live streaming!
class _ChatCanvasArea extends ConsumerWidget {
  const _ChatCanvasArea({
    required this.scrollCtrl,
    required this.baseListTopPad,
    required this.topBannerHeightNotifier,
    required this.onEffectiveTopPadChanged,
    required this.onUserUpwardWheel,
    required this.onSelectionChanged,
    required this.hasActiveSelectionNotifier,
    required this.getSelectedPlainText,
    required this.onSelectionAutoScrollActiveChanged,
    required this.onSelectionAutoScrollStep,
    required this.screenH,
    required this.topPad,
    required this.baseComposerBottom,
    required this.composerHeightNotifier,
    required this.prependedOlderCountNotifier,
    required this.hideCenterTitle,
    required this.animatedTurnIds,
    required this.onScrollNotification,
    required this.onScrollMetricsNotification,
    required this.onLoadOlderTurns,
    required this.onEmptySuggestionTap,
    required this.onOpenModelSettings,
    required this.onOpenHostSettings,
    required this.onOpenDiagnostics,
    required this.onOpenTerminal,
    required this.onPrefillPrompt,
    required this.onQuoteExcerpt,
    required this.onEditTurn,
    required this.turnItemKeys,
    this.highlightedTurnId,
  });

  static const ValueKey<String> _centerSliverKey = ValueKey<String>('chat-center-sliver');

  final ScrollController scrollCtrl;
  final double baseListTopPad;
  final ValueListenable<double> topBannerHeightNotifier;
  final ValueChanged<double> onEffectiveTopPadChanged;
  final VoidCallback onUserUpwardWheel;
  final ValueChanged<String> onSelectionChanged;
  final ValueListenable<bool> hasActiveSelectionNotifier;
  final String Function() getSelectedPlainText;
  final ValueChanged<bool> onSelectionAutoScrollActiveChanged;
  final ValueChanged<double> onSelectionAutoScrollStep;
  final double screenH;
  final double topPad;
  final double baseComposerBottom;
  final ValueNotifier<double> composerHeightNotifier;
  final ValueNotifier<int> prependedOlderCountNotifier;
  final bool hideCenterTitle;
  final Set<String> animatedTurnIds;
  final bool Function(ScrollNotification) onScrollNotification;
  final bool Function(ScrollMetricsNotification) onScrollMetricsNotification;
  final Future<void> Function() onLoadOlderTurns;
  final ValueChanged<String> onEmptySuggestionTap;
  final VoidCallback onOpenModelSettings;
  final VoidCallback onOpenHostSettings;
  final VoidCallback onOpenDiagnostics;
  final VoidCallback onOpenTerminal;
  final ValueChanged<String> onPrefillPrompt;
  final ValueChanged<String> onQuoteExcerpt;
  final ValueChanged<NormalizedTurn> onEditTurn;
  final Map<String, GlobalKey> turnItemKeys;
  final String? highlightedTurnId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          turnsCount: s.turns.length,
          lastTurnKey: s.turns.isEmpty ? '' : s.turns.last.stableKey,
          hasMoreTurns: s.hasMoreTurns,
          loadingOlderTurns: s.loadingOlderTurns,
          sessionLoadError: s.sessionLoadError,
          isEmptyChat: s.isEmptyChat,
          isDshConnected: s.isDshConnected,
          loadingSession: s.loadingSession,
          activeHostId: s.activeHostId,
          activeSessionId: s.activeSessionId,
          sessionRenderGen: s.sessionRenderGen,
          glassTier: s.glassTier,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);

    final showLoading = slice.loadingSession && slice.turnsCount == 0;
    final showError = !showLoading && slice.sessionLoadError != null && slice.turnsCount == 0;
    final showEmpty = !showLoading && !showError && slice.isEmptyChat;
    final showEmptySelectedSession =
        !showLoading && !showError && !showEmpty && slice.turnsCount == 0 && slice.activeSessionId != null;
    final showActiveList = !showLoading && !showError && !showEmpty && !showEmptySelectedSession;

    Widget buildLoadOlderHeader() {
      return SelectionContainer.disabled(
        key: const ValueKey('load-older-header'),
        child: SizedBox(
          height: 44,
          child: Align(
            alignment: Alignment.topCenter,
            child: GrassBagSpringTap(
              onTap: () {
                if (!slice.loadingOlderTurns) {
                  onLoadOlderTurns();
                }
              },
              pressedScale: 0.95,
              haptic: true,
              child: GrassBagFresnelGlassSurface(
                isPill: true,
                elevated: true,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (slice.loadingOlderTurns) ...[
                      GrassBagActivityIndicator(radius: 6.5, color: t.primary),
                      const SizedBox(width: 7),
                      Text(
                        '正在加载更早消息…',
                        style: TextStyle(fontSize: 12, color: t.text2),
                      ),
                    ] else ...[
                      Icon(CupertinoIcons.clock, size: 13, color: t.primary),
                      const SizedBox(width: 6),
                      Text(
                        '加载更早消息',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: t.primary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget buildTurnItem(int index) {
      final turns = ref.read(appProvider).turns;
      final turn = index < turns.length ? turns[index] : null;
      final turnKey = turn?.stableKey ?? 'turn-idx-$index';
      final scopedKey = '${slice.activeHostId}:${slice.sessionRenderGen}:$turnKey';
      final anchorKey = turn != null
          ? turnItemKeys.putIfAbsent(turn.turnId, () => GlobalKey(debugLabel: 'turn-${turn.turnId}'))
          : null;
      return GrassBagSelectionKeepAlive(
        key: ValueKey(scopedKey),
        keepAliveListenable: hasActiveSelectionNotifier,
        child: _TurnListItem(
          index: index,
          scopePrefix: '${slice.activeHostId}:${slice.sessionRenderGen}',
          activeSessionId: slice.activeSessionId,
          animatedTurnIds: animatedTurnIds,
          anchorKey: anchorKey,
          highlighted: turn != null && turn.turnId == highlightedTurnId,
          onOpenTerminal: onOpenTerminal,
          onPrefillPrompt: onPrefillPrompt,
          onQuoteExcerpt: onQuoteExcerpt,
          onEditTurn: onEditTurn,
          onOpenModelSettings: onOpenModelSettings,
          onOpenHostSettings: onOpenHostSettings,
        ),
      );
    }

    // Never place `CustomScrollView(controller: scrollCtrl)` inside `AnimatedSwitcher`!
    // Otherwise fast session switches (< 140ms) keep an outgoing ScrollPosition attached
    // while mounting the incoming one -> `StateError: Too many elements`!
    return ValueListenableBuilder<double>(
      valueListenable: topBannerHeightNotifier,
      builder: (context, bannerH, _) {
        final listTopPad = baseListTopPad + (bannerH > 0.5 ? bannerH + 12.0 : 0.0);
        onEffectiveTopPadChanged(listTopPad);
        return Stack(
      fit: StackFit.expand,
      children: [
        if (showActiveList)
          _ActiveChatStageReveal(
            sessionGen: slice.sessionRenderGen,
            child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent && event.scrollDelta.dy < -0.5) {
                onUserUpwardWheel();
              }
            },
            child: NotificationListener<ScrollNotification>(
              key: const ValueKey('active-chat-stage'),
              onNotification: onScrollNotification,
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: onScrollMetricsNotification,
              child: ValueListenableBuilder<int>(
                valueListenable: prependedOlderCountNotifier,
                builder: (ctx, rawPrepended, _) {
                  final prepended = rawPrepended.clamp(0, slice.turnsCount);
                  final forwardCount = slice.turnsCount - prepended;
                  final liveTurns = ref.read(appProvider).turns;
                  final scopePrefix = '${slice.activeHostId}:${slice.sessionRenderGen}:';
                  final olderIndexByKey = prepended > 0
                      ? <String, int>{
                          for (var i = 0; i < prepended && i < liveTurns.length; i++)
                            '$scopePrefix${liveTurns[i].stableKey}': (prepended - 1 - i),
                        }
                      : const <String, int>{};
                  final forwardHeaderSlot = (prepended == 0 && slice.hasMoreTurns) || prepended > 0;
                  final forwardOffset = forwardHeaderSlot ? 1 : 0;
                  final forwardIndexByKey = <String, int>{
                    for (var i = prepended; i < liveTurns.length; i++)
                      '$scopePrefix${liveTurns[i].stableKey}': forwardOffset + (i - prepended),
                  };

                  final chatHorizPad = MediaQuery.sizeOf(ctx).width < 420 ? 16.0 : 20.0;
                  final isDesktop = kIsWeb ||
                      defaultTargetPlatform == TargetPlatform.macOS ||
                      defaultTargetPlatform == TargetPlatform.windows ||
                      defaultTargetPlatform == TargetPlatform.linux;
                  // Single unified SelectionArea OUTSIDE CustomScrollView so Flutter mounts
                  // `_ScrollableSelectionHandler` + our edge-inset auto-scroller: dragging
                  // handles (or long-press-dragging) toward the floating header or composer
                  // smoothly auto-scrolls the conversation and selects beyond the viewport!
                  final viewRef = View.maybeOf(ctx);
                  return SelectionArea(
                    onSelectionChanged: (content) {
                      onSelectionChanged(content?.plainText ?? '');
                    },
                    contextMenuBuilder: buildGrassBagSelectableContextMenuWithQuote(
                      onQuoteSelectedText: onQuoteExcerpt,
                      getSelectedText: getSelectedPlainText,
                    ),
                    child: GrassBagSelectionAutoScrollScope(
                      scrollController: scrollCtrl,
                      topEdgeInset: listTopPad,
                      resolveBottomEdgeInset: () {
                        final kbInset = viewRef != null && viewRef.devicePixelRatio > 0
                            ? viewRef.viewInsets.bottom / viewRef.devicePixelRatio
                            : 0.0;
                        final bottomGap = math.max(baseComposerBottom, kbInset + 8.0);
                        return bottomGap + composerHeightNotifier.value;
                      },
                      onAutoScrollActiveChanged: onSelectionAutoScrollActiveChanged,
                      onAutoScrollStep: onSelectionAutoScrollStep,
                      child: CupertinoScrollbar(
                        controller: scrollCtrl,
                        child: CustomScrollView(
                    controller: scrollCtrl,
                    center: _centerSliverKey,
                    cacheExtent: 1400,
                    keyboardDismissBehavior: isDesktop
                        ? ScrollViewKeyboardDismissBehavior.manual
                        : ScrollViewKeyboardDismissBehavior.onDrag,
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    slivers: [
                      // Upward-growing negative sliver for turns prepended via `loadOlderTurns()`.
                      // Empty on initial loads (`minScrollExtent == 0.0`), and mathematically
                      // zero-jump (zero height-estimation drift!) whenever older turns prepend!
                      if (prepended > 0)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(chatHorizPad, listTopPad, chatHorizPad, 0),
                          sliver: SliverList.builder(
                            addAutomaticKeepAlives: true,
                            addRepaintBoundaries: true,
                            itemCount: prepended + (slice.hasMoreTurns ? 1 : 0),
                            findChildIndexCallback: (Key key) {
                              if (key is! ValueKey<String>) return null;
                              if (key.value == 'load-older-header') {
                                return slice.hasMoreTurns ? prepended : null;
                              }
                              return olderIndexByKey[key.value];
                            },
                            itemBuilder: (_, revIdx) {
                              if (revIdx == prepended) {
                                return buildLoadOlderHeader();
                              }
                              final actualIdx = prepended - 1 - revIdx;
                              return buildTurnItem(actualIdx);
                            },
                          ),
                        ),
                      // Center forward sliver anchored at `pixels == 0.0`:
                      SliverPadding(
                        key: _centerSliverKey,
                        padding: EdgeInsets.fromLTRB(
                          chatHorizPad,
                          prepended == 0 ? listTopPad : 0,
                          chatHorizPad,
                          0,
                        ),
                        sliver: SliverList.builder(
                          addAutomaticKeepAlives: true,
                          addRepaintBoundaries: true,
                          itemCount: forwardOffset + forwardCount + 1,
                          findChildIndexCallback: (Key key) {
                            if (key is! ValueKey<String>) return null;
                            final v = key.value;
                            if (v == 'load-older-header' || v == 'older-history-divider') {
                              return forwardHeaderSlot ? 0 : null;
                            }
                            if (v == 'chat-scroll-tail') {
                              return forwardOffset + forwardCount;
                            }
                            return forwardIndexByKey[v];
                          },
                          itemBuilder: (_, rawIdx) {
                            if (forwardHeaderSlot && rawIdx == 0) {
                              if (prepended == 0) {
                                return buildLoadOlderHeader();
                              }
                              return SelectionContainer.disabled(
                                key: const ValueKey('older-history-divider'),
                                child: SizedBox(
                                  height: 44,
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.only(bottom: 10),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(width: 24, child: Divider(height: 0.6, color: t.sep)),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 8),
                                            child: Text(
                                              '以上为更早消息',
                                              style: TextStyle(fontSize: 11, color: t.text3),
                                            ),
                                          ),
                                          SizedBox(width: 24, child: Divider(height: 0.6, color: t.sep)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }
                            final relIdx = rawIdx - forwardOffset;
                            if (relIdx == forwardCount) {
                              return _KeyboardScrollTail(
                                key: const ValueKey('chat-scroll-tail'),
                                scrollCtrl: scrollCtrl,
                                baseComposerBottom: baseComposerBottom,
                                composerHeightNotifier: composerHeightNotifier,
                              );
                            }
                            return buildTurnItem(prepended + relIdx);
                          },
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
            ),
          ),
          ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          reverseDuration: const Duration(milliseconds: 80),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOut,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          ),
          transitionBuilder: (child, anim) => IgnorePointer(
            ignoring: anim.status == AnimationStatus.reverse,
            child: FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.975, end: 1.0).animate(anim),
                child: child,
              ),
            ),
          ),
          child: showLoading
              ? _ChatLoadingSkeleton(
                  key: const ValueKey('loading-chat-stage'),
                  topPad: listTopPad,
                  bottomPad: baseComposerBottom + composerHeightNotifier.value,
                )
              : showError
                  ? Builder(
                      key: const ValueKey('error-chat-stage'),
                      builder: (errCtx) => Center(
                        child: SingleChildScrollView(
                          padding: EdgeInsets.fromLTRB(
                            28,
                            listTopPad + 8,
                            28,
                            baseComposerBottom + 104 + MediaQuery.viewInsetsOf(errCtx).bottom,
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 380),
                            child: GrassBagCard(
                              borderRadius: 24,
                              padding: const EdgeInsets.all(20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GrassBagSquircleIcon(
                                  icon: CupertinoIcons.exclamationmark_triangle_fill,
                                  color: t.err,
                                  size: 42,
                                  iconSize: 20,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '加载对话历史失败',
                                  style: TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w600,
                                    color: t.text,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxHeight: 160),
                                  child: SingleChildScrollView(
                                    child: SelectableText(
                                      slice.sessionLoadError!,
                                      contextMenuBuilder: buildGrassBagEditableContextMenu,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(fontSize: 12.5, height: 1.45, color: t.text3),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                GrassBagPrimaryGlassButton(
                                  label: '重新加载对话',
                                  icon: CupertinoIcons.arrow_clockwise,
                                  tier: slice.glassTier,
                                  insideGlass: true,
                                  onTap: ctrl.retryLoadActiveSession,
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: GrassBagSecondaryGlassButton(
                                        label: '开始新对话',
                                        height: 36,
                                        tier: slice.glassTier,
                                        insideGlass: true,
                                        onTap: () => ctrl.startNewChat(),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: GrassBagSecondaryGlassButton(
                                        label: '检查主机',
                                        height: 36,
                                        tier: slice.glassTier,
                                        insideGlass: true,
                                        onTap: onOpenHostSettings,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            ),
                          ),
                        ),
                      ),
                    )
                  : showEmpty
                      ? _KeyboardAwareEmptyStage(
                          key: const ValueKey('empty-chat-stage'),
                          screenH: screenH,
                          topPad: listTopPad,
                          baseComposerBottom: baseComposerBottom,
                          composerHeightNotifier: composerHeightNotifier,
                          hideCenterTitle: hideCenterTitle,
                          onSuggestionTap: onEmptySuggestionTap,
                          onPrefillSuggestion: onPrefillPrompt,
                          onOpenModelSettings: onOpenModelSettings,
                          onOpenHostSettings: onOpenHostSettings,
                          onOpenDiagnostics: onOpenDiagnostics,
                        )
                      : showEmptySelectedSession
                          ? Center(
                              key: const ValueKey('empty-selected-session-stage'),
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  28,
                                  listTopPad + 8,
                                  28,
                                  baseComposerBottom + 104,
                                ),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 360),
                                  child: GrassBagCard(
                                    borderRadius: 22,
                                    padding: const EdgeInsets.all(20),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        GrassBagSquircleIcon(
                                          icon: slice.isDshConnected
                                              ? CupertinoIcons.chat_bubble_2_fill
                                              : CupertinoIcons.wifi_slash,
                                          color: slice.isDshConnected ? t.primary : t.text3,
                                          size: 42,
                                          iconSize: 20,
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          slice.isDshConnected ? '该对话尚无消息记录' : '离线未缓存此对话',
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            color: t.text,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          slice.isDshConnected
                                              ? '直接发送消息即可继续此会话，或点击下方重新同步。'
                                              : '重新连接主机后将自动加载完整对话历史。',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(fontSize: 12.5, height: 1.45, color: t.text3),
                                        ),
                                        const SizedBox(height: 14),
                                        GrassBagSecondaryGlassButton(
                                          label: slice.isDshConnected ? '重新同步' : '检查主机连接',
                                          icon: slice.isDshConnected
                                              ? CupertinoIcons.refresh
                                              : CupertinoIcons.wifi,
                                          height: 36,
                                          tier: slice.glassTier,
                                          insideGlass: true,
                                          onTap: slice.isDshConnected
                                              ? ctrl.retryLoadActiveSession
                                              : onOpenHostSettings,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(key: ValueKey('stage-overlay-none')),
        ),
      ],
    );
      },
    );
  }
}

/// Per-index turn slot selecting ONLY `s.turns[index]`:
/// completed turns keep the exact same object identity -> ZERO rebuilds during live streaming!
class _TurnListItem extends ConsumerWidget {
  const _TurnListItem({
    required this.index,
    required this.scopePrefix,
    required this.activeSessionId,
    required this.animatedTurnIds,
    this.anchorKey,
    this.highlighted = false,
    required this.onOpenTerminal,
    required this.onPrefillPrompt,
    required this.onQuoteExcerpt,
    required this.onEditTurn,
    required this.onOpenModelSettings,
    required this.onOpenHostSettings,
  });

  final int index;
  final String scopePrefix;
  final String? activeSessionId;
  final Set<String> animatedTurnIds;
  final GlobalKey? anchorKey;
  final bool highlighted;
  final VoidCallback onOpenTerminal;
  final ValueChanged<String> onPrefillPrompt;
  final ValueChanged<String> onQuoteExcerpt;
  final ValueChanged<NormalizedTurn> onEditTurn;
  final VoidCallback onOpenModelSettings;
  final VoidCallback onOpenHostSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          turn: index < s.turns.length ? s.turns[index] : null,
          isLast: s.turns.isNotEmpty && index == s.turns.length - 1,
        ),
      ),
    );
    final turn = slice.turn;
    if (turn == null) return const SizedBox.shrink();
    final t = GrassBagTokens.of(context);
    // Scope by `(activeHostId, sessionRenderGen, turn.stableKey)` so optimistic
    // `pending-session-*` -> real server `sessionId` promotion keeps the exact TurnView
    // mounted (zero flicker!), while switching hosts or sessions ALWAYS remounts fresh!
    final scopedTurnKey = '$scopePrefix:${turn.stableKey}';
    final shouldAnimate = turn.isStreaming &&
        slice.isLast &&
        animatedTurnIds.add(scopedTurnKey);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: AnimatedContainer(
          key: anchorKey,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: highlighted
                ? t.primary.withValues(alpha: t.isDark ? 0.14 : 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: TurnView(
            key: ValueKey(scopedTurnKey),
            turn: turn,
            isLastTurn: slice.isLast,
            animateEntrance: shouldAnimate,
            onOpenTerminal: onOpenTerminal,
            onPrefillPrompt: onPrefillPrompt,
            onQuoteExcerpt: onQuoteExcerpt,
            onEditTurn: onEditTurn,
            onOpenModelSettings: onOpenModelSettings,
            onOpenHostSettings: onOpenHostSettings,
          ),
        ),
      ),
    );
  }
}

/// Isolated empty-state scroll canvas with mathematically monotonic GPU hero glide and
/// staggered suggestion-deck choreography. Because the hero's Y coordinate is computed directly
/// as `lerp(closedTop, openTop, openProgress)` instead of fighting `Center` against a
/// collapsing `Align(heightFactor)`, it NEVER reverses direction or jitters while the IME moves!
class _KeyboardAwareEmptyStage extends StatefulWidget {
  const _KeyboardAwareEmptyStage({
    super.key,
    required this.screenH,
    required this.topPad,
    required this.baseComposerBottom,
    required this.composerHeightNotifier,
    required this.hideCenterTitle,
    required this.onSuggestionTap,
    this.onPrefillSuggestion,
    required this.onOpenModelSettings,
    required this.onOpenHostSettings,
    required this.onOpenDiagnostics,
  });

  final double screenH;
  final double topPad;
  final double baseComposerBottom;
  final ValueNotifier<double> composerHeightNotifier;
  final bool hideCenterTitle;
  final ValueChanged<String> onSuggestionTap;
  final ValueChanged<String>? onPrefillSuggestion;
  final VoidCallback onOpenModelSettings;
  final VoidCallback onOpenHostSettings;
  final VoidCallback onOpenDiagnostics;

  @override
  State<_KeyboardAwareEmptyStage> createState() => _KeyboardAwareEmptyStageState();
}

class _KeyboardAwareEmptyStageState extends State<_KeyboardAwareEmptyStage> {
  final ScrollController _emptyScrollCtrl = ScrollController();
  double _heroHeight = 216.0;
  double _deckHeight = 224.0;
  ValueListenable<double>? _openListen;
  bool _wasKeyboardOpening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextOpen = _ImeMotionScope.of(context)?.openProgressNotifier;
    if (!identical(nextOpen, _openListen)) {
      _openListen?.removeListener(_onOpenProgressTick);
      _openListen = nextOpen;
      _openListen?.addListener(_onOpenProgressTick);
    }
  }

  void _onOpenProgressTick() {
    final p = _openListen?.value ?? 0.0;
    final opening = p > 0.05;
    if (opening && !_wasKeyboardOpening) {
      // If user scrolled down on a compact screen before opening IME, glide gently back
      // to top so the hero always frames cleanly above the rising keyboard!
      if (_emptyScrollCtrl.hasClients && _emptyScrollCtrl.offset > 2.0) {
        unawaited(
          _emptyScrollCtrl.animateTo(
            0.0,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    }
    _wasKeyboardOpening = opening;
  }

  @override
  void dispose() {
    _openListen?.removeListener(_onOpenProgressTick);
    _emptyScrollCtrl.dispose();
    super.dispose();
  }

  void _onHeroHeightChanged(double h) {
    if (!mounted || (h - _heroHeight).abs() <= 1.0) return;
    setState(() => _heroHeight = h);
  }

  void _onDeckHeightChanged(double h) {
    if (!mounted || (h - _deckHeight).abs() <= 1.0) return;
    setState(() => _deckHeight = h);
  }

  @override
  Widget build(BuildContext context) {
    final ime = _ImeMotionScope.of(context);
    final emptyStateWidget = RepaintBoundary(
      child: ChatEmptyState(
        keyboardProgressListenable: ime?.openProgressNotifier,
        keyboardProgress: ime == null
            ? ((MediaQuery.viewInsetsOf(context).bottom - 12.0) / 140.0).clamp(0.0, 1.0)
            : 0.0,
        onHeroHeightChanged: _onHeroHeightChanged,
        onDeckHeightChanged: _onDeckHeightChanged,
        onSuggestionTap: widget.onSuggestionTap,
        onPrefillSuggestion: widget.onPrefillSuggestion,
        onOpenModelSettings: widget.onOpenModelSettings,
        onOpenHostSettings: widget.onOpenHostSettings,
        onOpenDiagnostics: widget.onOpenDiagnostics,
      ),
    );

    // Listen ONLY to composerHeight, openProgress, and settled knownKeyboardHeight
    // (NOT raw 120Hz insetNotifier!) so empty-state IME flight runs purely on GPU Transform.translate
    // with ZERO SingleChildScrollView padding/height relayouts per frame!
    final listenable = ime == null
        ? widget.composerHeightNotifier
        : Listenable.merge([
            widget.composerHeightNotifier,
            ime.openProgressNotifier,
            ime.knownKeyboardHeightNotifier,
          ]);

    return AnimatedBuilder(
      animation: listenable,
      child: emptyStateWidget,
      builder: (context, cachedEmptyChild) {
        final compH = widget.composerHeightNotifier.value;
        final openProgress = (ime?.openProgressNotifier.value ??
                ((MediaQuery.viewInsetsOf(context).bottom - 12.0) / 140.0))
            .clamp(0.0, 1.0);
        final knownKbHeight = ime?.knownKeyboardHeightNotifier.value ?? 300.0;

        final closedBottomReserve = widget.baseComposerBottom + compH + 18.0;

        // Always anchor `openTop` to the settled/peak keyboard height so `openTop` stays
        // rock-steady across every frame of the spring (ZERO mid-flight dip or wobble!).
        final openBottomReserve =
            math.max(widget.baseComposerBottom, knownKbHeight + 8.0) + compH + 18.0;

        final effectiveTopPad = widget.hideCenterTitle
            ? math.max(16.0, widget.topPad - 44.0)
            : widget.topPad;
        final screenH = widget.screenH;
        final closedVisibleH = (screenH - effectiveTopPad - closedBottomReserve)
            .clamp(120.0, math.max(120.0, screenH));
        final openVisibleH = (screenH - effectiveTopPad - openBottomReserve)
            .clamp(100.0, math.max(100.0, screenH));

        final totalRestingH = _heroHeight + _deckHeight;
        final heroOpenVisualH = _heroHeight;
        // Slight optical upward balance (0.44 / 0.42) feels crisper than raw 0.50 on mobile.
        final closedTop = math.max(4.0, (closedVisibleH - totalRestingH) * 0.44);
        final openTop = math.max(4.0, (openVisibleH - heroOpenVisualH) * 0.42);

        // Single monotonic curve — hero ALWAYS glides smoothly in one direction, NEVER down-then-up!
        final heroY = closedTop + (openTop - closedTop) * openProgress;

        // Keep SingleChildScrollView padding & stageH CONSTANT during flight (0.01..0.99),
        // switching cleanly only when settled open vs closed -> 0 layout thrash at 120Hz!
        final isSettledOpen = openProgress >= 0.99;
        final scrollBottomPad = isSettledOpen ? openBottomReserve : closedBottomReserve;
        final settledContentH =
            isSettledOpen ? (openTop + heroOpenVisualH) : (closedTop + totalRestingH);
        final settledVisibleH = isSettledOpen ? openVisibleH : closedVisibleH;
        final stageH = screenH > 0
            ? math.max(settledContentH, (settledVisibleH - 8.0).clamp(0.0, screenH))
            : settledContentH;

        return SingleChildScrollView(
          controller: _emptyScrollCtrl,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            20,
            effectiveTopPad,
            20,
            scrollBottomPad,
          ),
          child: SizedBox(
            height: stageH,
            width: double.infinity,
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: 0.0,
              maxHeight: double.infinity,
              child: Transform.translate(
                offset: Offset(0, heroY),
                child: cachedEmptyChild,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Isolated bottom Toast anchor reacting cleanly to keyboard inset, '+' deck, and '/'/'@' popover!
class _KeyboardAwareToastSlot extends StatelessWidget {
  const _KeyboardAwareToastSlot({
    required this.baseComposerBottom,
    required this.plusOpenNotifier,
    required this.suggestionsOpenNotifier,
    required this.composerHeightNotifier,
    required this.drawerOpenNotifier,
  });

  final double baseComposerBottom;
  final ValueNotifier<bool> plusOpenNotifier;
  final ValueNotifier<bool> suggestionsOpenNotifier;
  final ValueNotifier<double> composerHeightNotifier;
  final ValueNotifier<bool> drawerOpenNotifier;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        plusOpenNotifier,
        suggestionsOpenNotifier,
        composerHeightNotifier,
        drawerOpenNotifier,
      ]),
      builder: (_, __) {
        final screenH = MediaQuery.sizeOf(context).height;
        final topPad = MediaQuery.viewPaddingOf(context).top;
        final maxSafeBottom = math.max(24.0, screenH - topPad - 124.0);
        if (drawerOpenNotifier.value) {
          return GrassBagToastOverlay(
            bottomOffset: (baseComposerBottom + 16.0).clamp(24.0, maxSafeBottom),
            includeKeyboardInset: true,
          );
        }
        final extraLift = plusOpenNotifier.value
            ? 308.0
            : (suggestionsOpenNotifier.value ? 264.0 : 16.0);
        return GrassBagToastOverlay(
          bottomOffset: (baseComposerBottom + composerHeightNotifier.value + extraLift)
              .clamp(24.0, maxSafeBottom),
          includeKeyboardInset: true,
        );
      },
    );
  }
}

/// Smooth fade + micro-scale entrance for Active Chat outside `AnimatedSwitcher`
/// (preserving single `ScrollPosition` attachment while eliminating 1-frame hard pops!).
class _ActiveChatStageReveal extends StatefulWidget {
  const _ActiveChatStageReveal({
    required this.sessionGen,
    required this.child,
  });

  final int sessionGen;
  final Widget child;

  @override
  State<_ActiveChatStageReveal> createState() => _ActiveChatStageRevealState();
}

class _ActiveChatStageRevealState extends State<_ActiveChatStageReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final CurvedAnimation _curve;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 210),
    );
    _curve = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.forward(from: 0.0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _ctrl.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant _ActiveChatStageReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionGen != widget.sessionGen) {
      if (mounted && MediaQuery.disableAnimationsOf(context)) {
        _ctrl.value = 1.0;
      } else {
        _ctrl.forward(from: 0.0);
      }
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (_, child) {
        final v = _curve.value;
        if (v >= 0.999) return child!;
        return GrassBagControlledOpacity(
          opacity: v,
          child: reduceMotion
              ? child!
              : Transform.scale(
                  scale: 0.988 + 0.012 * v,
                  child: child,
                ),
        );
      },
    );
  }
}

/// Velocity-preserving spring width pane for Tablet left sidebar & right workbench.
/// - Driven by `SpringSimulation(GlassSpring.smooth(280ms))` so mid-flight toggle
///   reversals carry smooth momentum with zero curve discontinuity.
/// - When `keepAlive == false` (right Workbench), completely unmounts while collapsed
///   so hidden inspector panels hold ZERO provider subscriptions & ZERO rebuild cost!
/// - Zero full-height `Opacity` `saveLayer` during slide (pure `ClipRect` + `OverflowBox`).
class _AnimatedTabletPane extends StatefulWidget {
  const _AnimatedTabletPane({
    required this.open,
    required this.width,
    required this.alignment,
    required this.child,
    this.keepAlive = true,
    this.snapClose = false,
  });

  final bool open;
  final double width;
  final Alignment alignment;
  final Widget child;
  final bool keepAlive;
  final bool snapClose;

  @override
  State<_AnimatedTabletPane> createState() => _AnimatedTabletPaneState();
}

class _AnimatedTabletPaneState extends State<_AnimatedTabletPane>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      value: widget.open ? 1.0 : 0.0,
      lowerBound: 0.0,
      upperBound: 1.0,
    );
  }

  @override
  void didUpdateWidget(covariant _AnimatedTabletPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open != widget.open) {
      final target = widget.open ? 1.0 : 0.0;
      final reduceMotion = mounted && MediaQuery.disableAnimationsOf(context);
      if (reduceMotion || (widget.snapClose && !widget.open)) {
        _ctrl.value = target;
      } else {
        final spring = GlassSpring.smooth(duration: const Duration(milliseconds: 280));
        _ctrl.animateWith(
          SpringSimulation(
            spring,
            _ctrl.value,
            target,
            _ctrl.velocity.clamp(-6.0, 6.0),
            tolerance: const Tolerance(distance: 0.004, velocity: 0.015),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      child: widget.child,
      builder: (context, content) {
        final v = _ctrl.value.clamp(0.0, 1.0);
        final hidden = v <= 0.005;
        if (hidden && !widget.open && !widget.keepAlive) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          width: hidden ? 0.0 : widget.width * v,
          child: Offstage(
            offstage: hidden,
            child: TickerMode(
              enabled: !hidden,
              child: ClipRect(
                child: OverflowBox(
                  alignment: widget.alignment,
                  minWidth: widget.width,
                  maxWidth: widget.width,
                  child: IgnorePointer(
                    ignoring: !widget.open,
                    child: content,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Floating Apple iOS 26 Liquid Glass pill displayed inside GrassBag whenever a native
/// Android phone-control task is actively running or paused, keeping pause/resume & emergency
/// stop within 1 thumb tap even after returning to chat.
/// Isolated leaf subtitle for unified 2-line stacked header pill (workspace + optional host + live status).
class _HeaderLiveSubtitle extends ConsumerWidget {
  const _HeaderLiveSubtitle({
    this.workspaceName = '',
    required this.fallbackHostName,
    this.showHostName = true,
    required this.hostIsLocal,
    required this.textScaler,
  });

  final String workspaceName;
  final String fallbackHostName;
  final bool showHostName;
  final bool hostIsLocal;
  final TextScaler textScaler;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          isStreaming: s.isStreaming,
          isStopping: s.isStopping,
          hasTakeover: s.pendingApprovalInteractionId != null ||
              s.activeQuestion != null ||
              s.activeCordisRequest != null,
          phase: s.connectionPhase,
        ),
      ),
    );
    final t = GrassBagTokens.of(context);
    final baseParts = <String>[
      if (workspaceName.trim().isNotEmpty) workspaceName.trim(),
      if (showHostName && fallbackHostName.trim().isNotEmpty) fallbackHostName.trim(),
    ];
    final baseLabel = baseParts.isNotEmpty ? baseParts.join(' · ') : fallbackHostName;
    final String label;
    final Color color;
    if (slice.phase == ConnectionPhase.reconnecting) {
      label = '$baseLabel · 重连中…';
      color = t.warn;
    } else if (slice.hasTakeover) {
      label = '$baseLabel · 等待确认';
      color = t.warn;
    } else if (slice.isStopping) {
      label = '$baseLabel · 停止中…';
      color = t.text3;
    } else if (slice.isStreaming) {
      label = '$baseLabel · 生成中…';
      color = t.primary;
    } else {
      label = baseLabel;
      color = hostIsLocal ? t.text3 : t.primary;
    }
    return AnimatedSwitcher(
      duration: GrassBagMotion.duration(context, const Duration(milliseconds: 180)),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: Text(
        label,
        key: ValueKey('$label|${color.toARGB32()}'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textScaler: textScaler,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
          height: 1.1,
          color: color,
        ),
      ),
    );
  }
}

/// Isolated leaf micro-status tag for single-line header pill (default single local host).
/// Zero parent `GrassBagShell` rebuilds while streaming/reconnecting/awaiting approval!
class _HeaderLiveStatusChip extends ConsumerWidget {
  const _HeaderLiveStatusChip({required this.textScaler});

  final TextScaler textScaler;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          isStreaming: s.isStreaming,
          isStopping: s.isStopping,
          hasTakeover: s.pendingApprovalInteractionId != null ||
              s.activeQuestion != null ||
              s.activeCordisRequest != null,
          phase: s.connectionPhase,
        ),
      ),
    );
    final t = GrassBagTokens.of(context);
    final String? label;
    final Color color;
    if (slice.phase == ConnectionPhase.reconnecting) {
      label = '重连中';
      color = t.warn;
    } else if (slice.hasTakeover) {
      label = '待确认';
      color = t.warn;
    } else if (slice.isStopping) {
      label = '停止中';
      color = t.text3;
    } else if (slice.isStreaming) {
      label = '生成中';
      color = t.primary;
    } else {
      label = null;
      color = t.text3;
    }
    final dur = GrassBagMotion.duration(context, const Duration(milliseconds: 180));
    return AnimatedSize(
      duration: dur,
      curve: Curves.easeOutCubic,
      alignment: Alignment.centerLeft,
      child: AnimatedSwitcher(
        duration: dur,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.82, end: 1.0).animate(anim),
            child: child,
          ),
        ),
        child: label == null
            ? const SizedBox.shrink(key: ValueKey('hdr-chip-empty'))
            : Padding(
                key: ValueKey('hdr-chip-$label'),
                padding: const EdgeInsets.only(left: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: t.isDark ? 0.22 : 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    textScaler: textScaler,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                      color: color,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _LivePhoneControlOverlayPill extends ConsumerWidget {
  const _LivePhoneControlOverlayPill({this.hasSiblingBannerAbove = false});

  final bool hasSiblingBannerAbove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          active: s.phoneLiveActive,
          paused: s.phoneLivePaused,
          handoffReason: s.phoneHandoffReason,
          action: s.phoneLiveAction,
          app: s.phoneLiveApp,
          steps: s.phoneLiveSteps,
          tier: s.glassTier,
        ),
      ),
    );
    if (!slice.active && slice.handoffReason.isEmpty) return const SizedBox.shrink();

    final t = GrassBagTokens.of(context);
    final ctrl = ref.read(appProvider.notifier);
    final hasHandoff = slice.handoffReason.isNotEmpty;
    final statusColor = (slice.paused || hasHandoff) ? t.warn : t.primary;
    final title = hasHandoff
        ? '等待你手动完成操作'
        : (slice.paused
            ? '手机操控已暂停'
            : (slice.action.isNotEmpty ? slice.action : '正在操控手机…'));
    final subParts = <String>[
      if (hasHandoff) slice.handoffReason,
      if (!hasHandoff && slice.steps > 0) '第 ${slice.steps} 步',
      if (!hasHandoff && slice.app.isNotEmpty) slice.app,
    ];

    return Padding(
      padding: EdgeInsets.only(top: hasSiblingBannerAbove ? 8.0 : 0.0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: GrassBagGlass(
            tier: slice.tier,
            borderRadius: hasHandoff ? 22 : 999,
            elevated: true,
            interactiveGlow: false,
            padding: const EdgeInsets.fromLTRB(13, 6, 6, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GrassBagStatusDot(
                  size: 8.5,
                  color: statusColor,
                  pulsing: !slice.paused || hasHandoff,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                      if (subParts.isNotEmpty)
                        Text(
                          subParts.join(' · '),
                          maxLines: hasHandoff ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: hasHandoff ? t.text2 : t.text3),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: hasHandoff
                      ? '我已完成手动操作，继续执行'
                      : (slice.paused ? '继续手机操控' : '暂停手机操控'),
                  excludeFromSemantics: true,
                  child: Semantics(
                    button: true,
                    label: hasHandoff
                        ? '我已完成，继续执行'
                        : (slice.paused ? '继续手机操控' : '暂停手机操控'),
                    child: GrassBagSpringTap(
                      pressedScale: 0.92,
                      enablePointerGlow: false,
                      haptic: true,
                      onTap: () => unawaited(ctrl.setPhonePaused(hasHandoff ? false : !slice.paused)),
                      child: GrassBagFresnelGlassSurface(
                        isPill: true,
                        innerWell: !hasHandoff,
                        elevated: hasHandoff,
                        interactive: true,
                        tintColor: hasHandoff ? t.primary : null,
                        height: 40,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 13),
                        child: Text(
                          hasHandoff ? '已完成，继续' : (slice.paused ? '继续' : '暂停'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: hasHandoff ? Colors.white : t.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Tooltip(
                  message: '立即紧急停止操控',
                  excludeFromSemantics: true,
                  child: Semantics(
                    button: true,
                    label: '立即紧急停止操控',
                    child: GrassBagSpringTap(
                      pressedScale: 0.92,
                      enablePointerGlow: false,
                      haptic: true,
                      onTap: ctrl.triggerEmergencyStop,
                      child: GrassBagFresnelGlassSurface(
                        isPill: true,
                        elevated: true,
                        interactive: true,
                        height: 40,
                        alignment: Alignment.center,
                        tintColor: t.isDark ? const Color(0xFFD93835) : t.err,
                        padding: const EdgeInsets.symmetric(horizontal: 13),
                        child: const Text(
                          '急停',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
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
      ),
    );
  }
}

/// Horizontal drag recognizer for the left screen edge that ONLY claims rightward drags
/// (`dx > 0`) BEFORE arena acceptance, yielding initial leftward drags cleanly to horizontally
/// scrollable code blocks / tables while STILL allowing smooth leftward drag-back once accepted!
class _RightOnlyHorizontalDragGestureRecognizer extends HorizontalDragGestureRecognizer {
  bool _accepted = false;

  @override
  void acceptGesture(int pointer) {
    _accepted = true;
    super.acceptGesture(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    _accepted = false;
    super.rejectGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _accepted = false;
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (!_accepted && event is PointerMoveEvent && event.delta.dx < -1.5) {
      resolve(GestureDisposition.rejected);
      return;
    }
    super.handleEvent(event);
  }
}

/// Zero-overhead RenderProxyBox height reporter for the unified floating top banner stack
/// so the progressive feather scrim, chat ListView top inset, and composer clearance always
/// match exact measured banner height across any font scale or stacked banner combo.
class _ReportedHeightBox extends SingleChildRenderObjectWidget {
  const _ReportedHeightBox({
    required this.onHeightChanged,
    required super.child,
  });

  final ValueChanged<double> onHeightChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReportedHeightBox(onHeightChanged);

  @override
  void updateRenderObject(BuildContext context, _RenderReportedHeightBox renderObject) {
    renderObject.onHeightChanged = onHeightChanged;
  }
}

class _RenderReportedHeightBox extends RenderProxyBox {
  _RenderReportedHeightBox(this.onHeightChanged);

  ValueChanged<double> onHeightChanged;
  double _lastHeight = -1.0;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if ((h - _lastHeight).abs() > 0.5) {
      _lastHeight = h;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onHeightChanged(h);
      });
    }
  }
}

/// Isolated tiny top-left drawer button badge for background pending approvals, unread, or running chats.
class _DrawerButtonStatusBadge extends ConsumerWidget {
  const _DrawerButtonStatusBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(
      appProvider.select((s) {
        final curId = s.activeSessionId;
        var pending = 0;
        var unread = 0;
        var running = 0;
        for (final sess in s.sessions) {
          if (sess.archived || sess.id == curId) continue;
          if (sess.pendingApproval) pending++;
          if (sess.unread) unread++;
          if (sess.running) running++;
        }
        return (pending: pending, unread: unread, running: running);
      }),
    );
    final t = GrassBagTokens.of(context);
    final Widget badgeChild;
    if (counts.pending == 0 && counts.unread == 0 && counts.running == 0) {
      badgeChild = const SizedBox.shrink(key: ValueKey('drawer-badge-none'));
    } else if (counts.pending > 0) {
      badgeChild = Container(
        key: ValueKey('drawer-badge-p-${counts.pending}'),
        constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: t.warn,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: t.bgSolid, width: 1.5),
        ),
        alignment: Alignment.center,
        child: Text(
          counts.pending > 9 ? '9+' : '${counts.pending}',
          style: const TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            height: 1.0,
          ),
        ),
      );
    } else {
      final dotColor = counts.unread > 0 ? t.primary : t.ok;
      badgeChild = Container(
        key: ValueKey('drawer-badge-dot-${dotColor.toARGB32()}'),
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: dotColor,
          shape: BoxShape.circle,
          border: Border.all(color: t.bgSolid, width: 1.5),
        ),
      );
    }
    return AnimatedSwitcher(
      duration: GrassBagMotion.duration(context, const Duration(milliseconds: 180)),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.65, end: 1.0).animate(anim),
          child: child,
        ),
      ),
      child: badgeChild,
    );
  }
}

/// Compact dismissible top pill when a background session is blocked awaiting user approval.
class _BackgroundApprovalBannerPill extends ConsumerStatefulWidget {
  const _BackgroundApprovalBannerPill({required this.tier});

  final GrassBagGlassTier tier;

  @override
  ConsumerState<_BackgroundApprovalBannerPill> createState() =>
      _BackgroundApprovalBannerPillState();
}

class _BackgroundApprovalBannerPillState
    extends ConsumerState<_BackgroundApprovalBannerPill> {
  final Set<String> _dismissedIds = <String>{};

  @override
  Widget build(BuildContext context) {
    final bgSig = ref.watch(
      appProvider.select((s) {
        final curId = s.activeSessionId;
        StringBuffer? buf;
        for (final sess in s.sessions) {
          if (!sess.archived && sess.pendingApproval && sess.id != curId) {
            (buf ??= StringBuffer())
              ..write(sess.id)
              ..write('\u001F')
              ..write(sess.title)
              ..write('\u001E');
          }
        }
        return buf?.toString() ?? '';
      }),
    );
    final allBgPending = bgSig.isEmpty
        ? const <({String id, String title})>[]
        : () {
            final s = ref.read(appProvider);
            final curId = s.activeSessionId;
            return [
              for (final sess in s.sessions)
                if (!sess.archived && sess.pendingApproval && sess.id != curId)
                  (id: sess.id, title: sess.title),
            ];
          }();
    final activePendingIds = {for (final x in allBgPending) x.id};
    _dismissedIds.removeWhere((id) => !activePendingIds.contains(id));
    final bgPending = allBgPending.where((x) => !_dismissedIds.contains(x.id)).firstOrNull;
    final t = GrassBagTokens.of(context);
    return GrassBagSmoothDisclosure(
      expanded: bgPending != null,
      child: bgPending == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GrassBagGlassPillButton(
                      tier: widget.tier,
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      onTap: () => ref.read(appProvider.notifier).selectSession(bgPending.id),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GrassBagStatusDot(color: t.warn, pulsing: true, size: 7),
                          const SizedBox(width: 7),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 210),
                            child: Text(
                              '「${bgPending.title}」待确认 · 前往处理',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: t.warn,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(CupertinoIcons.chevron_right, size: 11.5, color: t.warn),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    GrassBagGlassCircleButton(
                      tier: widget.tier,
                      size: 34,
                      iconSize: 12,
                      icon: CupertinoIcons.xmark,
                      iconColor: t.text2,
                      tooltip: '暂不提示',
                      onTap: () => setState(() => _dismissedIds.add(bgPending.id)),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Compact floating Liquid Glass In-Chat Search bar (`Cmd/Ctrl+F` or header menu).
class _InChatSearchBar extends ConsumerWidget {
  const _InChatSearchBar({
    required this.controller,
    required this.focusNode,
    required this.query,
    required this.cursor,
    required this.tier,
    required this.computeMatches,
    required this.onChanged,
    required this.onStep,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String query;
  final int cursor;
  final GrassBagGlassTier tier;
  final List<String> Function(List<NormalizedTurn>, String) computeMatches;
  final ValueChanged<String> onChanged;
  final ValueChanged<int> onStep;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final turns = ref.watch(appProvider.select((s) => s.turns));
    final matches = computeMatches(turns, query);
    final t = GrassBagTokens.of(context);
    final hasQuery = query.trim().isNotEmpty;
    final countLabel = !hasQuery
        ? ''
        : (matches.isEmpty
            ? '0 / 0'
            : '${(cursor % matches.length) + 1} / ${matches.length}');
    return GrassBagGlass(
      tier: tier,
      borderRadius: 20,
      elevated: true,
      interactiveGlow: false,
      padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
      child: Row(
        children: [
          Icon(CupertinoIcons.search, size: 15, color: t.text3),
          const SizedBox(width: 8),
          Expanded(
            child: CupertinoTextField(
              controller: controller,
              focusNode: focusNode,
              placeholder: '搜索本对话内容…',
              placeholderStyle: TextStyle(fontSize: 13, color: t.text3),
              style: TextStyle(fontSize: 13.5, color: t.text),
              decoration: const BoxDecoration(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              textInputAction: TextInputAction.search,
              onChanged: onChanged,
              onSubmitted: (_) => onStep(1),
            ),
          ),
          AnimatedSize(
            duration: GrassBagMotion.duration(context, const Duration(milliseconds: 160)),
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerRight,
            child: hasQuery
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: 6),
                      Text(
                        countLabel,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: matches.isEmpty ? t.err : t.text3,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Tooltip(
                        message: '上一条匹配',
                        child: GrassBagSpringTap(
                          enabled: matches.isNotEmpty,
                          onTap: () => onStep(-1),
                          child: SizedBox(
                            width: 30,
                            height: 30,
                            child: Center(
                              child: Icon(
                                CupertinoIcons.chevron_up,
                                size: 14,
                                color: matches.isEmpty ? t.text3.withValues(alpha: 0.4) : t.text2,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Tooltip(
                        message: '下一条匹配',
                        child: GrassBagSpringTap(
                          enabled: matches.isNotEmpty,
                          onTap: () => onStep(1),
                          child: SizedBox(
                            width: 30,
                            height: 30,
                            child: Center(
                              child: Icon(
                                CupertinoIcons.chevron_down,
                                size: 14,
                                color: matches.isEmpty ? t.text3.withValues(alpha: 0.4) : t.text2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          Tooltip(
            message: '关闭搜索',
            child: GrassBagSpringTap(
              onTap: onClose,
              child: SizedBox(
                width: 32,
                height: 32,
                child: Center(
                  child: Icon(CupertinoIcons.xmark, size: 13.5, color: t.text2),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Calm 3-bubble pulsing glass skeleton while cold-loading a conversation's turn history.
class _ChatLoadingSkeleton extends StatefulWidget {
  const _ChatLoadingSkeleton({
    super.key,
    required this.topPad,
    required this.bottomPad,
  });

  final double topPad;
  final double bottomPad;

  @override
  State<_ChatLoadingSkeleton> createState() => _ChatLoadingSkeletonState();
}

class _ChatLoadingSkeletonState extends State<_ChatLoadingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1250),
  );
  bool _running = false;

  void _syncAnim() {
    final shouldRun = WidgetsBinding.instance is WidgetsFlutterBinding &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        !MediaQuery.disableAnimationsOf(context);
    if (shouldRun && !_running) {
      _running = true;
      _ctrl.repeat(reverse: true);
    } else if (!shouldRun && _running) {
      _running = false;
      _ctrl.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnim();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final staticFooter = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GrassBagActivityIndicator(radius: 7.5, color: t.primary),
        const SizedBox(width: 8),
        Text(
          '正在加载对话历史…',
          style: TextStyle(fontSize: 12.5, color: t.text3),
        ),
      ],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(20, widget.topPad + 16, 20, widget.bottomPad + 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _ctrl,
              child: staticFooter,
              builder: (_, footer) {
                final v = _running ? Curves.easeInOutSine.transform(_ctrl.value) : 0.45;
                final alpha = (t.isDark ? 0.06 : 0.05) + v * (t.isDark ? 0.07 : 0.06);
                final fill = (t.isDark ? Colors.white : Colors.black).withValues(alpha: alpha);
                Widget bar(double widthFactor, double height, {double radius = 8}) => FractionallySizedBox(
                      widthFactor: widthFactor,
                      child: Container(
                        height: height,
                        decoration: BoxDecoration(
                          color: fill,
                          borderRadius: BorderRadius.circular(radius),
                        ),
                      ),
                    );
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        width: 210,
                        height: 40,
                        decoration: BoxDecoration(
                          color: t.primary.withValues(alpha: (t.isDark ? 0.14 : 0.09) + v * 0.06),
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Align(alignment: Alignment.centerLeft, child: bar(0.78, 13)),
                    const SizedBox(height: 9),
                    Align(alignment: Alignment.centerLeft, child: bar(0.92, 13)),
                    const SizedBox(height: 9),
                    Align(alignment: Alignment.centerLeft, child: bar(0.56, 13)),
                    const SizedBox(height: 22),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        width: 156,
                        height: 36,
                        decoration: BoxDecoration(
                          color: t.primary.withValues(alpha: (t.isDark ? 0.12 : 0.08) + v * 0.05),
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Align(alignment: Alignment.centerLeft, child: bar(0.84, 13)),
                    const SizedBox(height: 9),
                    Align(alignment: Alignment.centerLeft, child: bar(0.66, 13)),
                    const SizedBox(height: 24),
                    footer!,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
