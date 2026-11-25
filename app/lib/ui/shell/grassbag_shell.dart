import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart' show NormalizedTurn;
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
  final _plusOpenNotifier = ValueNotifier<bool>(false);
  final _suggestionsOpenNotifier = ValueNotifier<bool>(false);
  final _editingContextNotifier = ValueNotifier<EditingMessageContext?>(null);
  final _drawerBackHandler = ValueNotifier<bool Function()?>(null);
  final _showScrollToBottomNotifier = ValueNotifier<bool>(false);
  final _hasNewBelowNotifier = ValueNotifier<bool>(false);
  final _prependedOlderCountNotifier = ValueNotifier<int>(0);
  final _composerHeightNotifier = ValueNotifier<double>(108.0);
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
  bool _isProgrammaticScroll = false;
  int _programmaticScrollGen = 0;
  double _lastMaxScrollExtent = 0.0;
  double _lastListTopPad = 0.0;
  double _upwardScrollAccum = 0.0;
  final Map<String, ({double pixels, bool scrolledAway, int prependedCount})>
      _savedScrollOffsetBySession =
      <String, ({double pixels, bool scrolledAway, int prependedCount})>{};
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
      if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
        ref.read(appProvider.notifier).handleAppPaused();
      }
    } else if (state == AppLifecycleState.resumed) {
      ref.read(appProvider.notifier).handleAppResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    // Never fight the user while they are actively touching, dragging, or flinging the list,
    // and never fight an active programmatic `animateTo()` glide!
    if (_userDraggingList || _scrollCtrl.isUserDrivenScroll || _isProgrammaticScroll) {
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
              // Re-check true maxScrollExtent once lazy ListView/SliverList items materialize
              // during the scroll animation so tapping scroll-to-bottom NEVER undershoots!
              if (mounted &&
                  !_userScrolledAway &&
                  _scrollCtrl.hasClients &&
                  _scrollCtrl.positions.length == 1) {
                final pos = _scrollCtrl.position;
                if (pos.maxScrollExtent - pos.pixels > 4.0) {
                  _isProgrammaticScroll = true;
                  try {
                    _scrollCtrl.jumpTo(pos.maxScrollExtent);
                  } finally {
                    if (_programmaticScrollGen == gen) _isProgrammaticScroll = false;
                  }
                }
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
      // Bounded multi-pass post-frame re-anchor (up to 3 frames) even if Frame 1 measured
      // maxScrollExtent == 0, so tall lazy Markdown/code blocks settle cleanly at true bottom.
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
      _prependedOlderCountNotifier.value = prevPrepended + added;
      if (topPadShift > 0.0 && prevPixels != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollCtrl.hasClients || _scrollCtrl.positions.length != 1) return;
          final pos = _scrollCtrl.position;
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
      }
      if (notification.dragDetails != null && (delta < -0.5 || _upwardScrollAccum >= 2.5)) {
        _isProgrammaticScroll = false;
        _userScrolledAway = true;
      } else if (!_isProgrammaticScroll &&
          (delta < -0.5 || _upwardScrollAccum >= 3.0) &&
          maxExtent >= _lastMaxScrollExtent - 1.0 &&
          pixels <= maxExtent + 0.5 &&
          distFromBottom > 4.0) {
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
    final shouldShowBtn = distFromBottom > 120 && !_isProgrammaticScroll && !isActivelyAutoFollowing;
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
    final shouldShowBtn = distFromBottom > 120 && !_isProgrammaticScroll && !isActivelyAutoFollowing;
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
        if (remaining > 1 && pos.maxScrollExtent < targetPixels - 4.0) {
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
    if (!s.isDshConnected && s.connectionPhase != ConnectionPhase.connecting) {
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
    if (s.isDshConnected &&
        s.connectionPhase == ConnectionPhase.connected &&
        !s.hasAvailableModels &&
        s.routableProviders.isEmpty) {
      ctrl.showToast('请先登录 DeepSeek 或添加 API Key 模型渠道', tone: ToastTone.info);
      _openSettings(initialSection: SettingsSection.model);
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
      ref.read(appProvider.notifier).setTabletWorkbenchOpen(true);
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

  void _openSessionTitleAction() {
    final active = ref.read(appProvider).activeSession;
    if (!_isTablet(context) || active == null) {
      _openSessionDetail();
      return;
    }
    final ctrl = ref.read(appProvider.notifier);
    final wbOpen = ref.read(appProvider).tabletWorkbenchOpen;
    final tier = ref.read(appProvider).glassTier;
    final media = MediaQuery.of(context);
    unawaited(
      showGrassBagGlassContextMenu(
        context,
        tier: tier,
        globalAnchor: Offset(media.size.width * 0.5, media.viewPadding.top + 64),
        headerTitle: active.title,
        items: [
          GrassBagContextMenuItem(
            label: wbOpen ? '收起右侧工作台' : '展开右侧工作台',
            subtitle: '文件、Git 改动、终端与轨迹',
            icon: CupertinoIcons.sidebar_right,
            selected: wbOpen,
            onTap: () => ctrl.setTabletWorkbenchOpen(!wbOpen),
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
    ref.listen<int>(appProvider.select((s) => s.focusComposerSignal), (prev, next) {
      if (prev != null && next != prev) {
        if (_plusOpenNotifier.value) _plusOpenNotifier.value = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _composerFocus.requestFocus();
        });
      }
    });

    void resetScrollAnchoring() {
      _stopStreamScrollFollower();
      _lastMaxScrollExtent = 0.0;
      _upwardScrollAccum = 0.0;
      _animatedTurnIds.clear();
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
    ref.listen<(String, String?)>(
      appProvider.select((s) => (s.activeHostId, s.activeSessionId)),
      (prev, next) {
        if (prev != null && prev != next) {
          if (prev.$2 != null && _scrollCtrl.hasClients && _scrollCtrl.positions.length == 1) {
            final pos = _scrollCtrl.position;
            final dist = (pos.maxScrollExtent - pos.pixels).clamp(0.0, double.infinity);
            final key = '${prev.$1}::${prev.$2}';
            if (_userScrolledAway && dist > 36.0 && pos.pixels > pos.minScrollExtent) {
              if (_savedScrollOffsetBySession.length >= 30 &&
                  !_savedScrollOffsetBySession.containsKey(key)) {
                _savedScrollOffsetBySession.remove(_savedScrollOffsetBySession.keys.first);
              }
              _savedScrollOffsetBySession[key] = (
                pixels: pos.pixels,
                scrolledAway: true,
                prependedCount: _prependedOlderCountNotifier.value,
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
        resetScrollAnchoring();
        clearTurnProcessCaches();
        if (_plusOpenNotifier.value) _plusOpenNotifier.value = false;
        if (_editingContextNotifier.value != null) _editingContextNotifier.value = null;
      }
    });

    // Switching to another historical session -> restore saved reading spot if previously
    // scrolled up, otherwise silently anchor at the latest message via instant jumpTo.
    ref.listen<int>(appProvider.select((s) => s.sessionJumpSignal), (prev, next) {
      if (prev != null && next != prev) {
        resetScrollAnchoring();
        final s = ref.read(appProvider);
        final saved = s.activeSessionId == null
            ? null
            : _savedScrollOffsetBySession['${s.activeHostId}::${s.activeSessionId}'];
        if (saved != null && saved.scrolledAway) {
          _userScrolledAway = true;
          _scrollCtrl.allowImeAnchor = false;
          if (saved.prependedCount > 0) {
            _prependedOlderCountNotifier.value = saved.prependedCount.clamp(0, s.turns.length);
          }
          _scheduleRestoreScrollOffset(saved.pixels);
        } else {
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
      }
    });

    // React ONLY to real live streaming chunks -> keep 120Hz smooth chase alive (zero cancelled animateTo!),
    // or flag `_hasNewBelowNotifier` when the user scrolled up to read earlier messages!
    ref.listen<int>(appProvider.select((s) => s.streamTick), (prev, next) {
      if (prev != null && next != prev && ref.read(appProvider).isStreaming) {
        if (!_userScrolledAway && !_isProgrammaticScroll) {
          _ensureStreamScrollFollower(settleTailMs: 280.0);
        } else if (_userScrolledAway &&
            _showScrollToBottomNotifier.value &&
            !_hasNewBelowNotifier.value) {
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
        } else if (_userScrolledAway &&
            _showScrollToBottomNotifier.value &&
            !_hasNewBelowNotifier.value) {
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
            activeSessionTitle: sess?.title ?? '新对话',
            hasActiveSession: sess != null,
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
      children: [
        // Isolated Chat Canvas wrapped in dismiss-keyboard GestureDetector so tapping the
        // message list or empty stage dismisses IME, while tapping composer dock padding NEVER does!
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _dismissKeyboardAndPopovers,
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
              onOpenTerminal: _openTerminal,
              onPrefillPrompt: _prefillComposer,
              onEditTurn: _startEditingTurn,
            ),
          ),
        ),

        // Left-edge swipe gesture zone on Phone placed BELOW floating Liquid Glass chrome
        // so it never intercepts taps on header pills or composer buttons, while cleanly
        // dismissing open `+` deck / `/` `@` popovers as soon as the user pulls the drawer!
        if (!isTab)
          Positioned(
            top: topPad + 72,
            bottom: baseComposerBottom + 110,
            left: 0,
            width: 18,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (d) {
                final drawerW =
                    math.min(_phoneDrawerWidth, math.max(220.0, screenSize.width - 48.0));
                final next = (_drawerCtrl.value + d.delta.dx / drawerW).clamp(0.0, 1.0);
                if (d.delta.dx > 0 && next > 0.02) {
                  _dismissKeyboardAndPopovers();
                }
                _drawerCtrl.value = next;
              },
              onHorizontalDragEnd: (d) {
                final drawerW =
                    math.min(_phoneDrawerWidth, math.max(220.0, screenSize.width - 48.0));
                final v = d.velocity.pixelsPerSecond.dx / drawerW;
                if (v > 0.6 || (_drawerCtrl.value > 0.35 && v > -0.4)) {
                  _animateDrawerTo(1.0, velocity: v);
                } else {
                  _animateDrawerTo(0.0, velocity: v);
                }
              },
              onHorizontalDragCancel: () =>
                  _animateDrawerTo(_drawerCtrl.value > 0.5 ? 1.0 : 0.0),
            ),
          ),

          // Floating Liquid Glass Chrome Layer wrapped in ONE GlassBackdropGroup
          Positioned.fill(
            child: GlassBackdropGroup(
              child: Stack(
                children: [
                  // Silky progressive top feather dynamically covering BOTH the floating header
                  // AND any mounted top status/phone-control banner stack so scrolled chat text
                  // never clashes visually behind translucent floating chrome!
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: ValueListenableBuilder<double>(
                        valueListenable: _topBannerStackHeight,
                        builder: (_, bannerH, __) {
                          final capH = topPad + 86.0 + (bannerH > 0.5 ? bannerH + 14.0 : 0.0);
                          final solidStop = topPad > 0
                              ? ((topPad + 10.0) / capH).clamp(0.18, 0.56)
                              : 0.14;
                          final midStop = ((topPad + 48.0 + (bannerH > 0.5 ? bannerH : 0.0)) / capH)
                              .clamp(solidStop + 0.16, 0.86);
                          return SizedBox(
                            height: capH,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    t.bgTop,
                                    t.bgTop,
                                    t.bgTop.withValues(alpha: t.isDark ? 0.80 : 0.82),
                                    t.bgTop.withValues(alpha: 0.0),
                                  ],
                                  stops: [0.0, solidStop, midStop, 1.0],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  // Smooth bottom progressive feather behind the composer that tracks real
                  // composer height AND lifts smoothly with soft keyboard insets!
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: _KeyboardAwareBottomScrim(
                      baseComposerBottom: baseComposerBottom,
                      composerHeightNotifier: _composerHeightNotifier,
                    ),
                  ),
                  // Symmetrical 44px | Dead-Center Title | 44px Floating Liquid Glass Top Chrome
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
                        child: Row(
                          children: [
                            if (showTopLeftBtn) ...[
                              SizedBox(
                                width: 44,
                                height: 44,
                                child: GrassBagGlassCircleButton(
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
                              ),
                              const SizedBox(width: 10),
                            ],
                            Expanded(
                              child: hideCenterTitle
                                  ? const SizedBox.shrink()
                                  : Center(
                                      child: GrassBagGlassPillButton(
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
                                        child: AnimatedSwitcher(
                                          duration: const Duration(milliseconds: 180),
                                          child: Row(
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
                                                  style: TextStyle(
                                                    fontSize: 14.5,
                                                    fontWeight: FontWeight.w600,
                                                    letterSpacing: -0.25,
                                                    color: t.text,
                                                  ),
                                                ),
                                              ),
                                              if (shellSlice.isEmptyChat) ...[
                                                const SizedBox(width: 5),
                                                Icon(
                                                  CupertinoIcons.chevron_down,
                                                  size: 11,
                                                  color: t.text3,
                                                ),
                                              ] else if (!shellSlice.hostIsLocal ||
                                                  shellSlice.hostsCount > 1) ...[
                                                const SizedBox(width: 7),
                                                Flexible(
                                                  flex: 0,
                                                  child: GestureDetector(
                                                    behavior: HitTestBehavior.opaque,
                                                    onTap: () {
                                                      _dismissKeyboardAndPopovers();
                                                      showHostQuickSheet(
                                                        context,
                                                        ref,
                                                        onOpenHostSettings: () => _openSettings(
                                                          initialSection: SettingsSection.hosts,
                                                        ),
                                                      );
                                                    },
                                                    child: ConstrainedBox(
                                                      constraints: const BoxConstraints(maxWidth: 96),
                                                      child: Container(
                                                        padding: const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 4.5,
                                                        ),
                                                        decoration: BoxDecoration(
                                                          color: shellSlice.hostIsLocal
                                                              ? t.fill1
                                                              : t.primarySoft,
                                                          borderRadius: BorderRadius.circular(999),
                                                        ),
                                                        child: Row(
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            Flexible(
                                                              child: Text(
                                                                shellSlice.hostName,
                                                                maxLines: 1,
                                                                overflow: TextOverflow.ellipsis,
                                                                style: TextStyle(
                                                                  fontSize: 10.5,
                                                                  fontWeight: FontWeight.w600,
                                                                  color: shellSlice.hostIsLocal
                                                                      ? t.text2
                                                                      : t.primary,
                                                                ),
                                                              ),
                                                            ),
                                                            const SizedBox(width: 2),
                                                            Icon(
                                                              CupertinoIcons.chevron_down,
                                                              size: 9,
                                                              color: shellSlice.hostIsLocal
                                                                  ? t.text3
                                                                  : t.primary,
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ] else if (shellSlice.hasActiveSession && isTab) ...[
                                                const SizedBox(width: 5),
                                                Icon(
                                                  CupertinoIcons.chevron_down,
                                                  size: 11,
                                                  color: t.text3,
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                            ),
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
                        if (showAppUpdatePill)
                          Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 440),
                              child: GlassBackdropGroup(
                                enabled: false,
                                child: GrassBagGlass(
                                  tier: shellSlice.glassTier,
                                  borderRadius: 999,
                                  elevated: true,
                                  padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () => unawaited(showAppUpdateSheet(context, ref)),
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
                                      const SizedBox(width: 4),
                                      GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: ctrl.dismissAppUpdateBanner,
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
                              ),
                            ),
                          ),

                        // Android Local Container & DSH Boot Banner (physical-phone first-run & error recovery!)
                        if (showLocalAndroidBanner)
                          Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 680),
                              child: GlassBackdropGroup(
                                enabled: false,
                                child: GrassBagGlass(
                                  tier: shellSlice.glassTier,
                                  borderRadius: 22,
                                  elevated: true,
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
                                        ? '本机 DSH 引擎启动失败'
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
                                    child: CupertinoActivityIndicator(radius: 9, color: t.primary),
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
                  ),

                if (showLocalDesktopErrorBanner)
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: GlassBackdropGroup(
                        enabled: false,
                        child: GrassBagGlass(
                          tier: shellSlice.glassTier,
                          borderRadius: 22,
                          elevated: true,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                                      '确认本机服务运行后点击重试，或前往主机设置切换设备',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 11.5, color: t.text2),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              GrassBagPrimaryGlassButton(
                                label: '重试',
                                height: 34,
                                padding: const EdgeInsets.symmetric(horizontal: 13),
                                tier: shellSlice.glassTier,
                                insideGlass: true,
                                onTap: () => ctrl.probeAndRefreshHost(shellSlice.hostId),
                              ),
                            ],
                          ),
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
                      child: GlassBackdropGroup(
                        enabled: false,
                        child: GrassBagGlass(
                          tier: shellSlice.glassTier,
                          borderRadius: 22,
                          elevated: true,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: () {
                            final errCode = shellSlice.hostLastErrorCode ?? '';
                            final isHtmlProxy = errCode == 'html_proxy';
                            final isAuth = errCode == 'needs_auth' ||
                                isHtmlProxy ||
                                shellSlice.connectionPhase == ConnectionPhase.needsAuth;
                            final isTls = errCode == 'tls_cert';
                            final canWebLogin = !kIsWeb &&
                                (defaultTargetPlatform == TargetPlatform.android ||
                                    defaultTargetPlatform == TargetPlatform.iOS);
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
                  ),

                // In-App Live Phone-Control Floating Pill stacked cleanly inside the same
                // measured Column so it NEVER overlaps another top status banner at any font scale!
                _LivePhoneControlOverlayPill(hasSiblingBannerAbove: hasNonPhoneTopBanner),
                      ],
                    ),
                  ),
                ),

                // Transparent outside-tap barrier ONLY when '+' deck is open (dismisses immediately!)
                ValueListenableBuilder<bool>(
                  valueListenable: _plusOpenNotifier,
                  builder: (_, isOpen, __) {
                    if (!isOpen) return const SizedBox.shrink();
                    return Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _plusOpenNotifier.value = false,
                        onPanStart: (_) => _plusOpenNotifier.value = false,
                        child: const SizedBox.expand(),
                      ),
                    );
                  },
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
                      onMessageSent: () {
                        _scrollCtrl.cancelMomentumAndHold();
                        _userScrolledAway = false;
                        _scrollCtrl.allowImeAnchor = true;
                        if (_showScrollToBottomNotifier.value) {
                          _showScrollToBottomNotifier.value = false;
                        }
                        if (_hasNewBelowNotifier.value) {
                          _hasNewBelowNotifier.value = false;
                        }
                        if (!_isProgrammaticScroll) {
                          _ensureStreamScrollFollower(settleTailMs: 360.0);
                        }
                      },
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
      _drawerCtrl.value = 0.0;
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
                  final drawerActive = v > 0.001;

                  // Keep stageChild stationary and at a fixed tree depth across v == 0 <-> v > 0
                  // so RepaintBoundary(child: chatStage) stays cached in GPU VRAM during the entire
                  // drawer slide (ZERO full-screen glass backdrop re-rasterization per drag frame!)
                  // and ListView scroll position / TextField focus NEVER remount!
                  // Gate chat IgnorePointer on `v > 0.06` so the final spring settle tail never
                  // swallows the user's immediate tap on chat or composer!
                  return Stack(
                    children: [
                      IgnorePointer(
                        ignoring: v > 0.06,
                        child: stageChild,
                      ),

                      if (drawerActive)
                        // Interactive Backdrop Scrim
                        Positioned.fill(
                          child: GestureDetector(
                            onTap: _closePhoneDrawer,
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
                              color: Colors.black.withValues(alpha: (t.isDark ? 0.44 : 0.28) * v),
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
        final hasOpenOverlay = (!isTab && _drawerOpenForBackNotifier.value) ||
            _plusOpenNotifier.value ||
            _suggestionsOpenNotifier.value ||
            _editingContextNotifier.value != null ||
            (isTab && shellSlice.tabletWorkbenchOpen) ||
            _composerFocus.hasFocus;
        final guardAndroidRootExit =
            !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
        return PopScope(
          canPop: !widget.isSplashCovered && !hasOpenOverlay && !guardAndroidRootExit,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || widget.isSplashCovered) return;
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
            if (!isTab && _drawerCtrl.value > 0.05) {
              final handledInsideDrawer = _drawerBackHandler.value?.call() ?? false;
              if (!handledInsideDrawer) {
                _closePhoneDrawer();
              }
              return;
            }
            if (isTab && shellSlice.tabletWorkbenchOpen) {
              ctrl.setTabletWorkbenchOpen(false);
              return;
            }
            if (_composerFocus.hasFocus) {
              _composerFocus.unfocus();
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
        const SingleActivator(LogicalKeyboardKey.escape): () {
          // CRITICAL CJK IME guard: let Escape dismiss Pinyin/Kana candidate popups without
          // cancelling streaming or closing composer overlays!
          final composing = _composerCtrl.value.composing;
          if (_composerFocus.hasFocus && composing.isValid && !composing.isCollapsed) {
            return;
          }
          final drawerVisible = isTab ? shellSlice.tabletSidebarOpen : _drawerCtrl.value > 0.05;
          if (drawerVisible && _drawerBackHandler.value?.call() == true) {
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
          } else {
            final cur = ref.read(appProvider);
            final hasTakeover = cur.pendingApprovalCommand != null ||
                cur.activeQuestion != null ||
                cur.activeCordisRequest != null;
            if (cur.isStreaming && !hasTakeover) {
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
    if (delta <= 0.05 || !allowImeAnchor) return;
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
    if (_pendingImeAnchorDelta > 0.05) {
      final delta = _pendingImeAnchorDelta;
      _pendingImeAnchorDelta = 0.0;
      if (controller.allowImeAnchor &&
          oldPosition.hasContentDimensions &&
          oldPosition.hasPixels &&
          newPosition.maxScrollExtent > oldPosition.maxScrollExtent + 0.1) {
        final prevMax = oldPosition.maxScrollExtent;
        final distFromPrevBottom =
            (prevMax - oldPosition.pixels).clamp(0.0, double.infinity);
        final wasBottomAnchored = prevMax <= 12.0 || distFromPrevBottom <= 76.0;
        if (wasBottomAnchored) {
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
class _KeyboardBottomInsetLift extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final ime = _ImeMotionScope.of(context);
    final screenH = MediaQuery.sizeOf(context).height;
    final hasTakeover = ref.watch(
      appProvider.select(
        (s) =>
            s.pendingApprovalCommand != null ||
            s.activeQuestion != null ||
            s.activeCordisRequest != null,
      ),
    );

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
      } else if (!hasTakeover) {
        final effectiveBottom = kbInset > 24.0
            ? math.max(baseBottom, settledKbHeight + 8.0)
            : baseBottom;
        maxDockHeight = (screenH - effectiveBottom - effectiveTopClearance).clamp(160.0, screenH);
      } else {
        final raw = (screenH - targetBottom - effectiveTopClearance).clamp(160.0, screenH);
        maxDockHeight = kbInset > 0 ? ((raw / 64.0).floor() * 64.0).clamp(160.0, screenH) : raw;
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
        return ValueListenableBuilder<double>(
          valueListenable: ime.insetNotifier,
          builder: (_, kbInset, __) =>
              buildLift(kbInset, ime.knownKeyboardHeightNotifier.value, bannerH),
        );
      },
    );
  }
}

/// Isolated bottom scrim that tracks real live composer height AND lifts above the soft IME
/// via pure GPU `Transform.translate` in exact lock-step with [_KeyboardBottomInsetLift]!
class _KeyboardAwareBottomScrim extends StatelessWidget {
  const _KeyboardAwareBottomScrim({
    required this.baseComposerBottom,
    required this.composerHeightNotifier,
  });

  final double baseComposerBottom;
  final ValueNotifier<double> composerHeightNotifier;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final ime = _ImeMotionScope.of(context);
    final scrimDecoration = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          t.bgSolid.withValues(alpha: t.isDark ? 0.95 : 0.94),
          t.bgSolid.withValues(alpha: t.isDark ? 0.78 : 0.74),
          t.bgSolid.withValues(alpha: t.isDark ? 0.28 : 0.24),
          t.bgSolid.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.36, 0.72, 1.0],
      ),
    );

    Widget buildWithInset(double kbInset) {
      final targetBottom = math.max(baseComposerBottom, kbInset + 8.0);
      final lift = (targetBottom - baseComposerBottom).clamp(0.0, double.infinity);
      return ValueListenableBuilder<double>(
        valueListenable: composerHeightNotifier,
        builder: (_, compH, __) {
          final restingH = baseComposerBottom + compH + 34.0;
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
      if (delta > 0.1) {
        final ctrl = widget.scrollCtrl;
        if (ctrl is _ImeLockStepScrollController) {
          ctrl.queueImeAnchorDelta(delta);
        }
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
    required this.onOpenTerminal,
    required this.onPrefillPrompt,
    required this.onEditTurn,
  });

  static const ValueKey<String> _centerSliverKey = ValueKey<String>('chat-center-sliver');

  final ScrollController scrollCtrl;
  final double baseListTopPad;
  final ValueListenable<double> topBannerHeightNotifier;
  final ValueChanged<double> onEffectiveTopPadChanged;
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
  final VoidCallback onOpenTerminal;
  final ValueChanged<String> onPrefillPrompt;
  final ValueChanged<NormalizedTurn> onEditTurn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          turnsCount: s.turns.length,
          hasMoreTurns: s.hasMoreTurns,
          loadingOlderTurns: s.loadingOlderTurns,
          sessionLoadError: s.sessionLoadError,
          isEmptyChat: s.isEmptyChat,
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
    final showActiveList = !showLoading && !showError && !showEmpty;

    Widget buildLoadOlderHeader() {
      return SizedBox(
        key: const ValueKey('load-older-header'),
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
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: t.fill1,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: t.sep, width: 0.6),
              ),
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
      );
    }

    Widget buildTurnItem(int index) {
      final turns = ref.read(appProvider).turns;
      final turnKey = index < turns.length ? turns[index].stableKey : 'turn-idx-$index';
      final scopedKey = '${slice.activeHostId}:${slice.sessionRenderGen}:$turnKey';
      return _TurnListItem(
        key: ValueKey(scopedKey),
        index: index,
        scopePrefix: '${slice.activeHostId}:${slice.sessionRenderGen}',
        activeSessionId: slice.activeSessionId,
        animatedTurnIds: animatedTurnIds,
        onOpenTerminal: onOpenTerminal,
        onPrefillPrompt: onPrefillPrompt,
        onEditTurn: onEditTurn,
        onOpenModelSettings: onOpenModelSettings,
        onOpenHostSettings: onOpenHostSettings,
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
          NotificationListener<ScrollNotification>(
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

                  return CustomScrollView(
                    controller: scrollCtrl,
                    center: _centerSliverKey,
                    cacheExtent: 1400,
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    slivers: [
                      // Upward-growing negative sliver for turns prepended via `loadOlderTurns()`.
                      // Empty on initial loads (`minScrollExtent == 0.0`), and mathematically
                      // zero-jump (zero height-estimation drift!) whenever older turns prepend!
                      if (prepended > 0)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(20, listTopPad, 20, 0),
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
                        padding: EdgeInsets.fromLTRB(20, prepended == 0 ? listTopPad : 0, 20, 0),
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
                              return SizedBox(
                                key: const ValueKey('older-history-divider'),
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
                  );
                },
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
              ? Center(
                  key: const ValueKey('loading-chat-stage'),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CupertinoActivityIndicator(radius: 13, color: t.primary),
                      const SizedBox(height: 10),
                      Text(
                        '正在加载对话历史…',
                        style: TextStyle(fontSize: 13, color: t.text3),
                      ),
                    ],
                  ),
                )
              : showError
                  ? Center(
                      key: const ValueKey('error-chat-stage'),
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          28,
                          listTopPad + 8,
                          28,
                          baseComposerBottom + 104,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 380),
                          child: GrassBagCard(
                            borderRadius: 22,
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
                          onOpenModelSettings: onOpenModelSettings,
                          onOpenHostSettings: onOpenHostSettings,
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
    super.key,
    required this.index,
    required this.scopePrefix,
    required this.activeSessionId,
    required this.animatedTurnIds,
    required this.onOpenTerminal,
    required this.onPrefillPrompt,
    required this.onEditTurn,
    required this.onOpenModelSettings,
    required this.onOpenHostSettings,
  });

  final int index;
  final String scopePrefix;
  final String? activeSessionId;
  final Set<String> animatedTurnIds;
  final VoidCallback onOpenTerminal;
  final ValueChanged<String> onPrefillPrompt;
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
        child: TurnView(
          key: ValueKey(scopedTurnKey),
          turn: turn,
          animateEntrance: shouldAnimate,
          onOpenTerminal: onOpenTerminal,
          onPrefillPrompt: onPrefillPrompt,
          onEditTurn: onEditTurn,
          onOpenModelSettings: onOpenModelSettings,
          onOpenHostSettings: onOpenHostSettings,
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
    required this.onOpenModelSettings,
    required this.onOpenHostSettings,
  });

  final double screenH;
  final double topPad;
  final double baseComposerBottom;
  final ValueNotifier<double> composerHeightNotifier;
  final bool hideCenterTitle;
  final ValueChanged<String> onSuggestionTap;
  final VoidCallback onOpenModelSettings;
  final VoidCallback onOpenHostSettings;

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
        onOpenModelSettings: widget.onOpenModelSettings,
        onOpenHostSettings: widget.onOpenHostSettings,
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

        final screenH = widget.screenH;
        final closedVisibleH =
            (screenH - widget.topPad - closedBottomReserve).clamp(120.0, math.max(120.0, screenH));
        final openVisibleH =
            (screenH - widget.topPad - openBottomReserve).clamp(100.0, math.max(100.0, screenH));

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
            widget.topPad,
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
  });

  final double baseComposerBottom;
  final ValueNotifier<bool> plusOpenNotifier;
  final ValueNotifier<bool> suggestionsOpenNotifier;
  final ValueNotifier<double> composerHeightNotifier;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([plusOpenNotifier, suggestionsOpenNotifier, composerHeightNotifier]),
      builder: (_, __) {
        final extraLift = plusOpenNotifier.value
            ? 308.0
            : (suggestionsOpenNotifier.value ? 264.0 : 16.0);
        return GrassBagToastOverlay(
          bottomOffset: baseComposerBottom + composerHeightNotifier.value + extraLift,
          includeKeyboardInset: true,
        );
      },
    );
  }
}

/// Smooth animated width pane for Tablet left sidebar & right workbench.
/// - When `keepAlive == false` (right Workbench), completely unmounts while collapsed
///   so hidden inspector panels hold ZERO provider subscriptions & ZERO rebuild cost!
/// - Zero full-height `Opacity` `saveLayer` during slide (pure `ClipRect` + `OverflowBox`).
class _AnimatedTabletPane extends StatelessWidget {
  const _AnimatedTabletPane({
    required this.open,
    required this.width,
    required this.alignment,
    required this.child,
    this.keepAlive = true,
  });

  final bool open;
  final double width;
  final Alignment alignment;
  final Widget child;
  final bool keepAlive;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: open ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, v, content) {
        final hidden = v <= 0.005;
        if (hidden && !open && !keepAlive) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          width: hidden ? 0.0 : width * v,
          child: Offstage(
            offstage: hidden,
            child: TickerMode(
              enabled: !hidden,
              child: ClipRect(
                child: OverflowBox(
                  alignment: alignment,
                  minWidth: width,
                  maxWidth: width,
                  child: IgnorePointer(
                    ignoring: !open,
                    child: content,
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }
}

/// Floating Apple iOS 26 Liquid Glass pill displayed inside GrassBag whenever a native
/// Android phone-control task is actively running or paused, keeping pause/resume & emergency
/// stop within 1 thumb tap even after returning to chat.
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
          action: s.phoneLiveAction,
          app: s.phoneLiveApp,
          steps: s.phoneLiveSteps,
          tier: s.glassTier,
        ),
      ),
    );
    if (!slice.active) return const SizedBox.shrink();

    final t = GrassBagTokens.of(context);
    final ctrl = ref.read(appProvider.notifier);
    final statusColor = slice.paused ? t.warn : t.primary;
    final title = slice.paused
        ? '手机操控已暂停'
        : (slice.action.isNotEmpty ? slice.action : '正在操控手机…');
    final subParts = <String>[
      if (slice.steps > 0) '第 ${slice.steps} 步',
      if (slice.app.isNotEmpty) slice.app,
    ];

    return Padding(
      padding: EdgeInsets.only(top: hasSiblingBannerAbove ? 8.0 : 0.0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: GlassBackdropGroup(
            enabled: false,
            child: GrassBagGlass(
              tier: slice.tier,
              borderRadius: 999,
              elevated: true,
              padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: statusColor.withValues(alpha: 0.45),
                          blurRadius: 6,
                        ),
                      ],
                    ),
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
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10.5, color: t.text3),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GrassBagSpringTap(
                    pressedScale: 0.92,
                    haptic: true,
                    onTap: () => unawaited(ctrl.setPhonePaused(!slice.paused)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: t.fill1,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: t.isDark
                              ? Colors.white.withValues(alpha: 0.14)
                              : const Color(0x1A132C44),
                          width: 0.6,
                        ),
                      ),
                      child: Text(
                        slice.paused ? '继续' : '暂停',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GrassBagSpringTap(
                    pressedScale: 0.92,
                    haptic: true,
                    onTap: ctrl.triggerEmergencyStop,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: t.isDark ? const Color(0xFFD94444) : t.err,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        '急停',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
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
