import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  const GrassBagShell({super.key});

  @override
  ConsumerState<GrassBagShell> createState() => _GrassBagShellState();
}

class _GrassBagShellState extends ConsumerState<GrassBagShell>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const double _phoneDrawerWidth = 304.0;

  final _composerCtrl = TextEditingController();
  final _composerFocus = FocusNode();
  final _scrollCtrl = ScrollController();
  final _plusOpenNotifier = ValueNotifier<bool>(false);
  final _showScrollToBottomNotifier = ValueNotifier<bool>(false);
  final _composerHeightNotifier = ValueNotifier<double>(108.0);

  late final AnimationController _drawerCtrl;
  Ticker? _streamScrollTicker;
  Duration? _lastScrollTick;
  double _streamSettleRemainingMs = 0.0;

  bool _userScrolledAway = false;
  bool _userDraggingList = false;
  bool _isProgrammaticScroll = false;
  int _programmaticScrollGen = 0;
  double _lastMaxScrollExtent = 0.0;
  final Set<String> _animatedTurnIds = <String>{};

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
    _composerFocus.addListener(_onComposerFocusChanged);
    final initialDraft = ref.read(appProvider.notifier).getComposerDraftForActiveHost();
    if (initialDraft.isNotEmpty) {
      _composerCtrl.text = initialDraft;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      ref.read(appProvider.notifier).handleAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      ref.read(appProvider.notifier).handleAppResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _streamScrollTicker?.dispose();
    _composerFocus.removeListener(_onComposerFocusChanged);
    _composerFocus.dispose();
    _composerCtrl.dispose();
    _scrollCtrl.dispose();
    _plusOpenNotifier.dispose();
    _showScrollToBottomNotifier.dispose();
    _composerHeightNotifier.dispose();
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
    // Never fight the user while they are actively touching/dragging the list!
    if (_userDraggingList) {
      return;
    }
    final gap = pos.maxScrollExtent - pos.pixels;
    if (gap > 0.5) {
      final step = gap <= 2.0 ? gap : gap * (1.0 - math.exp(-16.0 * dtSec));
      final next = (pos.pixels + step).clamp(0.0, pos.maxScrollExtent);
      _isProgrammaticScroll = true;
      try {
        _scrollCtrl.jumpTo(next);
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
      if (!_userScrolledAway) {
        // ONLY settle scroll when a real mobile soft keyboard actually opens
        // (viewInsets.bottom > 80). On Desktop/Web (viewInsets == 0), restoring focus
        // after closing a popup/sheet must NEVER jolt the message list!
        Future<void>.delayed(const Duration(milliseconds: 220), () {
          if (!mounted || !_composerFocus.hasFocus || _userScrolledAway) return;
          // Non-subscribing read so GrassBagShell NEVER leaks a permanent MediaQuery.viewInsets dependency!
          final kbInset =
              context.getInheritedWidgetOfExactType<MediaQuery>()?.data.viewInsets.bottom ?? 0.0;
          if (kbInset > 80.0) {
            _ensureStreamScrollFollower(settleTailMs: 320.0);
          }
        });
      }
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
      velocity.clamp(-3.5, 3.5),
    );
    _drawerCtrl.animateWith(sim);
  }

  void _openPhoneDrawer() {
    HapticFeedback.selectionClick();
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

      reanchor(3);
    }
  }

  Future<void> _handleLoadOlderTurns() async {
    final targetSid = ref.read(appProvider).activeSessionId;
    final hadClients = _scrollCtrl.hasClients && _scrollCtrl.positions.length == 1;
    final oldPixels = hadClients ? _scrollCtrl.position.pixels : 0.0;
    final oldMax = hadClients ? _scrollCtrl.position.maxScrollExtent : 0.0;
    await ref.read(appProvider.notifier).loadOlderTurns();
    if (!mounted || !hadClients) return;
    if (ref.read(appProvider).activeSessionId != targetSid) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          ref.read(appProvider).activeSessionId != targetSid ||
          !_scrollCtrl.hasClients ||
          _scrollCtrl.positions.length != 1) {
        return;
      }
      final newMax = _scrollCtrl.position.maxScrollExtent;
      final delta = newMax - oldMax;
      if (delta > 1.0) {
        _isProgrammaticScroll = true;
        try {
          _scrollCtrl.jumpTo((oldPixels + delta).clamp(0.0, newMax));
        } finally {
          _isProgrammaticScroll = false;
        }
      }
    });
  }

  void _prefillComposer(String text) {
    HapticFeedback.selectionClick();
    _composerCtrl.text = text;
    _composerCtrl.selection = TextSelection.collapsed(offset: text.length);
    _composerFocus.requestFocus();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) return false;
    final maxExtent = notification.metrics.maxScrollExtent;
    final pixels = notification.metrics.pixels;
    final distFromBottom = (maxExtent - pixels).clamp(0.0, double.infinity);

    // Detect ONLY genuine user-initiated upward scroll across touch drag, mouse wheel,
    // trackpad, and keyboard — NEVER trip `_userScrolledAway` when `maxScrollExtent`
    // grows dynamically from streaming text, expanded tool cards, or IME opening!
    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null) {
        _userDraggingList = true;
      }
    } else if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.forward && distFromBottom > 28) {
        _isProgrammaticScroll = false;
        _userScrolledAway = true;
      } else if (distFromBottom <= 24) {
        _userScrolledAway = false;
      }
    } else if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0.0;
      if (notification.dragDetails != null) {
        _userDraggingList = true;
      }
      if (notification.dragDetails != null && delta < -1.0) {
        _isProgrammaticScroll = false;
        _userScrolledAway = true;
      } else if (!_isProgrammaticScroll &&
          delta < -1.0 &&
          maxExtent >= _lastMaxScrollExtent - 1.0 &&
          pixels <= maxExtent + 0.5 &&
          distFromBottom > 4.0) {
        // Catches desktop mouse wheel, pointerScroll, trackpad & keyboard upward scrolls immediately
        // while ignoring overscroll bounce-back or shrinking maxScrollExtent from collapsing content/IME!
        _userScrolledAway = true;
      } else if (delta > 0.5 && distFromBottom <= 24) {
        _userScrolledAway = false;
      }
    } else if (notification is ScrollEndNotification) {
      _userDraggingList = false;
      if (distFromBottom <= 24) {
        _userScrolledAway = false;
      }
    }

    _lastMaxScrollExtent = maxExtent;

    final shouldShowBtn = _userScrolledAway && distFromBottom > 120;
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

    final shouldShowBtn = _userScrolledAway && distFromBottom > 120;
    if (shouldShowBtn != _showScrollToBottomNotifier.value) {
      _showScrollToBottomNotifier.value = shouldShowBtn;
    }

    if (grew &&
        distFromBottom > 1.5 &&
        !_userScrolledAway &&
        !_userDraggingList &&
        (wasNearBottom || _streamSettleRemainingMs > 0 || ref.read(appProvider).isStreaming)) {
      _ensureStreamScrollFollower(settleTailMs: 260.0);
    }
    return false;
  }

  void _jumpBackToBottom() {
    HapticFeedback.selectionClick();
    _userScrolledAway = false;
    if (_showScrollToBottomNotifier.value) {
      _showScrollToBottomNotifier.value = false;
    }
    if (ref.read(appProvider).isStreaming) {
      // Cooperate cleanly with the 120Hz follower instead of fighting animateTo vs jumpTo!
      _ensureStreamScrollFollower(settleTailMs: 360.0);
    } else {
      _stopStreamScrollFollower();
      _performScrollToBottom(animated: true);
    }
  }

  void _onEmptySuggestionTap(String prompt) {
    HapticFeedback.lightImpact();
    _composerFocus.unfocus();
    final s = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    if (GrassBagNativeBridge.instance.isAndroidNative &&
        s.activeHost.isLocal &&
        !s.nativeRuntimeStatus.engineRunning) {
      if (!s.nativeRuntimeStatus.initialized) {
        ctrl.showToast('正在一键部署本机运行环境…', tone: ToastTone.info);
        ctrl.bootstrapLocalRuntime();
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
      if (!s.activeHost.isLocal) {
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
    _composerFocus.unfocus();
    if (_isTablet(context)) {
      HapticFeedback.selectionClick();
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
    showGrassBagSheet<void>(
      context,
      title: active.title,
      subtitle: active.cwd != null && active.cwd!.isNotEmpty ? active.cwd : '当前对话操作',
      bodyBuilder: (ctx) {
        final t = GrassBagTokens.of(ctx);
        return GrassBagSheetSection(
          dividerIndent: 52,
          children: [
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.sidebar_right,
                color: t.primary,
                size: 32,
                iconSize: 16,
              ),
              title: Text(wbOpen ? '收起右侧工作台' : '展开右侧工作台'),
              subtitle: const Text('查看工作区文件、Git 改动、终端与执行轨迹'),
              onTap: () {
                Navigator.of(ctx).pop();
                ctrl.setTabletWorkbenchOpen(!wbOpen);
              },
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.pencil,
                color: t.primaryHi,
                size: 32,
                iconSize: 16,
              ),
              title: const Text('重命名对话'),
              onTap: () {
                Navigator.of(ctx).pop();
                showRenameSessionSheet(context, ref, active);
              },
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.arrow_branch,
                color: t.dusk,
                size: 32,
                iconSize: 16,
              ),
              title: const Text('创建分支对话 (Fork)'),
              subtitle: const Text('保留当前上下文分叉探索新思路'),
              onTap: () {
                Navigator.of(ctx).pop();
                ctrl.forkActiveSession();
              },
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.share,
                color: t.ok,
                size: 32,
                iconSize: 16,
              ),
              title: const Text('导出为 Markdown'),
              onTap: () {
                Navigator.of(ctx).pop();
                ctrl.exportActiveSession();
              },
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.chevron_left_slash_chevron_right,
                color: t.warn,
                size: 32,
                iconSize: 16,
              ),
              title: const Text('打开交互终端'),
              onTap: () {
                Navigator.of(ctx).pop();
                _openTerminal();
              },
            ),
          ],
        );
      },
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

    // React to New Chat trigger -> reset scroll state & focus composer on desktop!
    // ChatComposerDock is the single owner of `_composerCtrl` draft sync (never clear saved drafts here!).
    ref.listen<int>(appProvider.select((s) => s.newChatSignal), (prev, next) {
      if (prev != null && next != prev) {
        _stopStreamScrollFollower();
        _lastMaxScrollExtent = 0.0;
        _animatedTurnIds.clear();
        if (_plusOpenNotifier.value) _plusOpenNotifier.value = false;
        _userScrolledAway = false;
        if (_showScrollToBottomNotifier.value) {
          _showScrollToBottomNotifier.value = false;
        }
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
        _stopStreamScrollFollower();
        _lastMaxScrollExtent = 0.0;
        _animatedTurnIds.clear();
        clearTurnProcessCaches();
        if (_plusOpenNotifier.value) _plusOpenNotifier.value = false;
        _userScrolledAway = false;
        if (_showScrollToBottomNotifier.value) {
          _showScrollToBottomNotifier.value = false;
        }
      }
    });

    // Switching to another historical session -> silently anchor at the latest message
    // via instant jumpTo (zero jarring upward whip from offset 0!).
    ref.listen<int>(appProvider.select((s) => s.sessionJumpSignal), (prev, next) {
      if (prev != null && next != prev) {
        _stopStreamScrollFollower();
        _lastMaxScrollExtent = 0.0;
        _animatedTurnIds.clear();
        _userScrolledAway = false;
        if (_showScrollToBottomNotifier.value) {
          _showScrollToBottomNotifier.value = false;
        }
        _scheduleScrollToBottom(animated: false, settle: false);
      }
    });

    // React to every newly sent prompt -> start silky 120Hz scroll follower cleanly!
    ref.listen<int>(appProvider.select((s) => s.scrollSignal), (prev, next) {
      if (prev != null && next != prev) {
        _userScrolledAway = false;
        if (_showScrollToBottomNotifier.value) {
          _showScrollToBottomNotifier.value = false;
        }
        _ensureStreamScrollFollower(settleTailMs: 360.0);
      }
    });

    // React ONLY to real live streaming chunks -> keep 120Hz smooth chase alive (zero cancelled animateTo!).
    ref.listen<int>(appProvider.select((s) => s.streamTick), (prev, next) {
      if (prev != null &&
          next != prev &&
          !_userScrolledAway &&
          ref.read(appProvider).isStreaming) {
        // Settle tail covers typewriter reveal frames between coalesced WS flushes.
        _ensureStreamScrollFollower(settleTailMs: 280.0);
      }
    });

    // When streaming starts/completes -> glide smoothly through the typewriter's short
    // completion tail and action strip mount, then stop the ticker automatically!
    ref.listen<bool>(appProvider.select((s) => s.isStreaming), (prev, next) {
      if (next == true && !_userScrolledAway) {
        _ensureStreamScrollFollower(settleTailMs: 320.0);
      } else if (prev == true && next == false && !_userScrolledAway) {
        _ensureStreamScrollFollower(settleTailMs: 380.0);
      }
    });

    // ULTRA-NARROW SHELL SELECTOR: GrassBagShell NEVER watches `s.turns` or `s.isStreaming`!
    // During an entire 2,000-token stream, GrassBagShell, Top Liquid Glass chrome,
    // ChatComposerDock, Sidebar, and collapsed Workbench experience ZERO rebuilds!
    final shellSlice = ref.watch(
      appProvider.select(
        (s) => (
          isEmptyChat: s.isEmptyChat,
          activeSessionTitle: s.activeSession?.title ?? '新对话',
          hasActiveSession: s.activeSession != null,
          hostId: s.activeHost.id,
          hostName: s.activeHost.name,
          hostAddress: s.activeHost.address,
          hostIsLocal: s.activeHost.isLocal,
          hostBridged: s.activeHost.bridged,
          hostDirectMode: s.activeHost.directMode,
          hostOnline: s.activeHost.online,
          hostAllowBadCerts: s.activeHost.allowBadCertificates,
          hostLastErrorCode: s.activeHost.lastErrorCode,
          hostInstalling: s.activeHost.installing,
          hostsCount: s.hosts.length,
          connectionPhase: s.connectionPhase,
          glassTier: s.glassTier,
          tabletSidebarOpen: s.tabletSidebarOpen,
          tabletWorkbenchOpen: s.tabletWorkbenchOpen,
          nativeInitialized: s.nativeRuntimeStatus.initialized,
          nativeEngineState: s.nativeRuntimeStatus.engineState,
          nativeEngineError: s.nativeRuntimeStatus.engineError,
          runtimeProgressPct: s.runtimeProgressPct,
          runtimeProgressMsg: s.runtimeProgressMsg,
          showAppUpdateBanner: s.showAppUpdateBanner,
          appUpdateVersionName: s.appUpdateInfo?.versionName ?? '',
        ),
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
    final hideCenterTitle = isTab && shellSlice.tabletSidebarOpen && shellSlice.isEmptyChat;
    final showTopLeftBtn = !isTab || !shellSlice.tabletSidebarOpen;
    final showTopRightBtn = !isTab || !shellSlice.tabletWorkbenchOpen;

    final remoteUsable = shellSlice.hostBridged || (shellSlice.hostDirectMode && shellSlice.hostOnline);
    // Empty chat renders `_RemoteEmptyStatusBanner` inline inside `ChatEmptyState` — avoid duplicate banners!
    final showRemoteBasicBanner = !shellSlice.isEmptyChat &&
        !shellSlice.hostIsLocal &&
        !remoteUsable &&
        shellSlice.connectionPhase != ConnectionPhase.connecting;
    final showLocalDesktopErrorBanner = !shellSlice.isEmptyChat &&
        !GrassBagNativeBridge.instance.isAndroidNative &&
        shellSlice.hostIsLocal &&
        shellSlice.connectionPhase == ConnectionPhase.error;
    // Empty chat already renders `_LocalRuntimeBanner` inside `ChatEmptyState` — avoid duplicate banners!
    final showLocalAndroidBanner = !shellSlice.isEmptyChat &&
        GrassBagNativeBridge.instance.isAndroidNative &&
        shellSlice.hostIsLocal &&
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
    final hostDotColor = hostHealthy
        ? t.ok
        : (hostNeedsAuth ? t.primary : (hostHasErr ? t.err : t.warn));
    final showAppUpdatePill = shellSlice.showAppUpdateBanner &&
        shellSlice.appUpdateVersionName.isNotEmpty &&
        !showRemoteBasicBanner &&
        !showLocalAndroidBanner &&
        !showLocalDesktopErrorBanner;
    // Active chat list always reserves consistent top clearance below the floating title pill
    // (never jumping from 18px -> 76px mid-transition when leaving Empty State!).
    final listTopPad = topPad +
        76.0 +
        ((showRemoteBasicBanner || showLocalAndroidBanner || showLocalDesktopErrorBanner)
            ? 70.0
            : (showAppUpdatePill ? 46.0 : 0.0));

    final chatStage = Stack(
      children: [
        // Isolated Chat Canvas wrapped in dismiss-keyboard GestureDetector so tapping the
        // message list or empty stage dismisses IME, while tapping composer dock padding NEVER does!
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              if (_plusOpenNotifier.value) _plusOpenNotifier.value = false;
              if (_composerFocus.hasFocus) _composerFocus.unfocus();
            },
            child: _ChatCanvasArea(
              scrollCtrl: _scrollCtrl,
              listTopPad: listTopPad,
              screenH: screenH,
              topPad: topPad,
              baseComposerBottom: baseComposerBottom,
              composerHeightNotifier: _composerHeightNotifier,
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
            ),
          ),
        ),

          // Floating Liquid Glass Chrome Layer wrapped in ONE GlassBackdropGroup
          Positioned.fill(
            child: GlassBackdropGroup(
              child: Stack(
                children: [
                  // Crisp status-bar-only cap (`topPad + 14dp`):
                  // 100% solid `t.bgTop` across the OS status bar (zero text ghosting under clock/battery)
                  // while ending right above the floating Liquid Glass header pills (`topPad + 12..56`)
                  // so scrolled chat messages glide underneath at full contrast for true live refraction!
                  if (topPad > 4.0)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: topPad + 14.0,
                      child: IgnorePointer(
                        child: Builder(
                          builder: (_) {
                            final capH = topPad + 14.0;
                            final solidStop = ((topPad - 2.0) / capH).clamp(0.45, 0.85);
                            final midStop = ((topPad + 5.0) / capH).clamp(solidStop + 0.05, 0.94);
                            return DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    t.bgTop,
                                    t.bgTop,
                                    t.bgTop.withValues(alpha: 0.45),
                                    t.bgTop.withValues(alpha: 0.0),
                                  ],
                                  stops: [0.0, solidStop, midStop, 1.0],
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
                            SizedBox(
                              width: 44,
                              height: 44,
                              child: showTopLeftBtn
                                  ? GrassBagGlassCircleButton(
                                      key: ValueKey('top-left-$isTab'),
                                      icon: isTab
                                          ? CupertinoIcons.sidebar_left
                                          : CupertinoIcons.line_horizontal_3,
                                      iconSize: 19,
                                      useOwnLayer: false,
                                      tooltip: isTab ? '展开侧边栏' : '打开侧边栏',
                                      tier: shellSlice.glassTier,
                                      onTap: () {
                                        if (isTab) {
                                          ctrl.setTabletSidebarOpen(true);
                                        } else {
                                          _openPhoneDrawer();
                                        }
                                      },
                                    )
                                  : const SizedBox.shrink(),
                            ),
                            const SizedBox(width: 10),
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
                                            ? () => showHostQuickSheet(
                                                  context,
                                                  ref,
                                                  onOpenHostSettings: () => _openSettings(
                                                    initialSection: SettingsSection.hosts,
                                                  ),
                                                )
                                            : _openSessionTitleAction,
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
                                              Container(
                                                width: 7,
                                                height: 7,
                                                decoration: BoxDecoration(
                                                  color: hostDotColor,
                                                  shape: BoxShape.circle,
                                                ),
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
                                                GestureDetector(
                                                  behavior: HitTestBehavior.opaque,
                                                  onTap: () => showHostQuickSheet(
                                                    context,
                                                    ref,
                                                    onOpenHostSettings: () => _openSettings(
                                                      initialSection: SettingsSection.hosts,
                                                    ),
                                                  ),
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
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 44,
                              height: 44,
                              child: showTopRightBtn
                                  ? GrassBagGlassCircleButton(
                                      key: ValueKey('top-right-$isTab'),
                                      icon: isTab
                                          ? CupertinoIcons.sidebar_right
                                          : CupertinoIcons.square_pencil,
                                      iconSize: 19,
                                      useOwnLayer: false,
                                      tooltip: isTab ? '展开工作台' : '新对话',
                                      tier: shellSlice.glassTier,
                                      onTap: () {
                                        if (isTab) {
                                          ctrl.setTabletWorkbenchOpen(true);
                                        } else {
                                          ctrl.startNewChat();
                                        }
                                      },
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                if (showAppUpdatePill)
                  Positioned(
                    top: topPad + 64,
                    left: 12,
                    right: 12,
                    child: Center(
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
                                Expanded(
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
                  ),

                // Android Local Container & DSH Boot Banner (physical-phone first-run & error recovery!)
                if (showLocalAndroidBanner)
                  Positioned(
                    top: topPad + 64,
                    left: 12,
                    right: 12,
                    child: Center(
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
                            final isErr = shellSlice.nativeEngineState == 'error' ||
                                shellSlice.connectionPhase == ConnectionPhase.error;
                            final isStopped = shellSlice.nativeInitialized &&
                                shellSlice.nativeEngineState == 'stopped' &&
                                !isErr;
                            final title = isExtracting
                                ? '正在部署本机容器 (${shellSlice.runtimeProgressPct}%)'
                                : isBooting
                                    ? '正在启动本机 DSH 核心…'
                                    : isErr
                                        ? '本机 DSH 引擎启动失败'
                                        : isStopped
                                            ? '本机 DSH 引擎已停止'
                                            : '本机 Linux 容器尚未初始化';
                            final sub = isExtracting
                                ? (shellSlice.runtimeProgressMsg.isNotEmpty
                                    ? shellSlice.runtimeProgressMsg
                                    : '首次解压仅需一次，完成后即可离线使用')
                                : isBooting
                                    ? '高速模式加速冷启，通常仅需数秒'
                                    : isErr
                                        ? ((shellSlice.nativeEngineError?.isNotEmpty == true)
                                            ? shellSlice.nativeEngineError!
                                            : '请重试启动或查看容器运行诊断日志')
                                        : isStopped
                                            ? '点击启动引擎即可继续在本机容器内对话'
                                            : '点击一键部署内置 Ubuntu + Node + DSH 引擎';
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
                                        : CupertinoIcons.cube_box_fill,
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
                                if (isExtracting || isBooting)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 6),
                                    child: CupertinoActivityIndicator(radius: 9, color: t.primary),
                                  )
                                else
                                  GrassBagPrimaryGlassButton(
                                    label: !shellSlice.nativeInitialized
                                        ? '一键部署'
                                        : (isErr ? '重试启动' : '启动引擎'),
                                    height: 34,
                                    padding: const EdgeInsets.symmetric(horizontal: 13),
                                    tier: shellSlice.glassTier,
                                    insideGlass: true,
                                    onTap: () => !shellSlice.nativeInitialized
                                        ? ctrl.bootstrapLocalRuntime()
                                        : ctrl.restartLocalEngine(),
                                  ),
                              ],
                            );
                          }(),
                        ),
                      ),
                    ),
                  ),
                ),

                if (showLocalDesktopErrorBanner)
                  Positioned(
                    top: topPad + 64,
                    left: 12,
                    right: 12,
                    child: Center(
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
                  ),

                // Actionable Remote Host Issue Banner (ONLY shown when auth/TLS/network blocks connection;
                // never shown when connected via zero-plugin Vanilla Direct Mode!)
                if (showRemoteBasicBanner)
                  Positioned(
                    top: topPad + 64,
                    left: 12,
                    right: 12,
                    child: Center(
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
                      showScrollToBottomListenable: _showScrollToBottomNotifier,
                      composerHeightNotifier: _composerHeightNotifier,
                      onScrollToBottom: _jumpBackToBottom,
                      onMessageSent: () {
                        _userScrolledAway = false;
                        if (_showScrollToBottomNotifier.value) {
                          _showScrollToBottomNotifier.value = false;
                        }
                        _ensureStreamScrollFollower(settleTailMs: 360.0);
                      },
                    ),
                  ),
                ),
              ],
            ),
            ),
          ),

          // Left-edge swipe gesture zone on Phone to pull the drawer interactively
          if (!isTab)
            Positioned(
              top: topPad + 56,
              bottom: baseComposerBottom + 96,
              left: 0,
              width: 24,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: (d) {
                  final next = (_drawerCtrl.value + d.delta.dx / _phoneDrawerWidth).clamp(0.0, 1.0);
                  if (d.delta.dx > 0 && next > 0.02 && _composerFocus.hasFocus) {
                    _composerFocus.unfocus();
                  }
                  _drawerCtrl.value = next;
                },
                onHorizontalDragEnd: (d) {
                  final v = d.velocity.pixelsPerSecond.dx / _phoneDrawerWidth;
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
                open: shellSlice.tabletWorkbenchOpen,
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
              // Hoist the floating drawer subtree outside AnimatedBuilder so sliding the drawer
              // triggers ZERO widget rebuilds & ZERO layout passes on every 120fps animation tick!
              final cachedDrawer = RepaintBoundary(
                child: GestureDetector(
                  onHorizontalDragUpdate: (d) {
                    _drawerCtrl.value =
                        (_drawerCtrl.value + d.delta.dx / _phoneDrawerWidth).clamp(0.0, 1.0);
                  },
                  onHorizontalDragEnd: (d) {
                    final vel = d.velocity.pixelsPerSecond.dx / _phoneDrawerWidth;
                    if (vel < -0.5 || _drawerCtrl.value < 0.65) {
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
                  return Stack(
                    children: [
                      IgnorePointer(
                        ignoring: drawerActive,
                        child: stageChild,
                      ),

                      if (drawerActive)
                        // Interactive Backdrop Scrim
                        Positioned.fill(
                          child: GestureDetector(
                            onTap: _closePhoneDrawer,
                            onHorizontalDragUpdate: (d) {
                              _drawerCtrl.value =
                                  (_drawerCtrl.value + d.delta.dx / _phoneDrawerWidth)
                                      .clamp(0.0, 1.0);
                            },
                            onHorizontalDragEnd: (d) {
                              final vel = d.velocity.pixelsPerSecond.dx / _phoneDrawerWidth;
                              if (vel < -0.5 || _drawerCtrl.value < 0.65) {
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

                      // Conditionally mounted slide-over drawer so the full-height Liquid Glass
                      // sheet frees its Impeller GPU geometry matte textures whenever closed!
                      if (drawerActive)
                        Positioned(
                          top: 0,
                          bottom: 0,
                          left: 0,
                          width: _phoneDrawerWidth,
                          child: Transform.translate(
                            offset: Offset(-_phoneDrawerWidth * (1.0 - v), 0),
                            child: cachedDrawer,
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          );

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () => ctrl.startNewChat(),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => ctrl.startNewChat(),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!isTab && _drawerCtrl.value > 0.05) {
            _closePhoneDrawer();
          } else if (_plusOpenNotifier.value) {
            _plusOpenNotifier.value = false;
          } else if (ref.read(appProvider).isStreaming) {
            ctrl.cancelStreaming();
          }
        },
      },
      child: GrassBagGlassPage(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: false,
          body: Stack(
            children: [
              mainBody,
              // Bottom-Centered Liquid Glass Toast isolated from GrassBagShell viewInsets rebuilds!
              _KeyboardAwareToastSlot(
                baseComposerBottom: baseComposerBottom,
                plusOpenNotifier: _plusOpenNotifier,
                composerHeightNotifier: _composerHeightNotifier,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tiny leaf widget that isolates `MediaQuery.viewInsetsOf(context).bottom` for the
/// floating composer dock using pure GPU `Transform.translate` so keyboard open/close
/// runs at silky 120fps with ZERO layout passes and ZERO `RenderLiquidGlassLayer.layout()`
/// (`toImageSync`) re-captures on normal chat frames!
class _KeyboardBottomInsetLift extends ConsumerWidget {
  const _KeyboardBottomInsetLift({
    required this.baseBottom,
    required this.topClearance,
    required this.child,
  });

  final double baseBottom;
  final double topClearance;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kbInset = MediaQuery.viewInsetsOf(context).bottom;
    final screenH = MediaQuery.sizeOf(context).height;
    final hasTakeover = ref.watch(
      appProvider.select(
        (s) =>
            s.pendingApprovalCommand != null ||
            s.activeQuestion != null ||
            s.activeCordisRequest != null,
      ),
    );
    // Continuous max(...) avoids any 32px discontinuity snap when kbInset crosses 0 <-> 1px!
    final targetBottom = math.max(baseBottom, kbInset + 8.0);
    final lift = (targetBottom - baseBottom).clamp(0.0, double.infinity);
    // For normal composer (99% of frames), keep maxDockHeight CONSTANT across the entire IME
    // slide so ConstrainedBox NEVER dirties RenderLiquidGlassLayer.layout() -> 0 toImageSync!
    // Only bound tightly against the top bar when a tall Approval/Question/Cordis takeover card
    // is active, quantized to 64px buckets so layout churn drops by ~85%.
    final double maxDockHeight;
    if (screenH <= 160.0) {
      maxDockHeight = double.infinity;
    } else if (!hasTakeover) {
      maxDockHeight = (screenH - baseBottom - topClearance).clamp(160.0, screenH);
    } else {
      final raw = (screenH - targetBottom - topClearance).clamp(160.0, screenH);
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
}

/// Isolated bottom scrim that tracks real live composer height AND lifts above the soft IME
/// via pure GPU `Transform.translate` (zero Stack layout pass on 120Hz IME animation frames!).
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
    final kbInset = MediaQuery.viewInsetsOf(context).bottom;
    final targetBottom = math.max(baseComposerBottom, kbInset + 8.0);
    final lift = (targetBottom - baseComposerBottom).clamp(0.0, double.infinity);
    return ValueListenableBuilder<double>(
      valueListenable: composerHeightNotifier,
      builder: (_, compH, __) {
        final restingH = baseComposerBottom + compH + 22.0;
        return Transform.translate(
          offset: Offset(0, -lift),
          child: IgnorePointer(
            child: SizedBox(
              height: restingH,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      t.bgSolid.withValues(alpha: t.isDark ? 0.18 : 0.10),
                      t.bgSolid.withValues(alpha: t.isDark ? 0.04 : 0.02),
                      t.bgSolid.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.56, 1.0],
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

/// Trailing empty spacer inside chat `ListView.builder` tracking live composer height + IME
/// so the latest message is NEVER obscured by multi-line drafts, attachments, or queue cards!
/// Quantizes IME inset to 64px ceiling steps so `ListView.builder` relayouts drop from ~36 to ~5.
class _KeyboardScrollTail extends StatelessWidget {
  const _KeyboardScrollTail({
    super.key,
    required this.baseComposerBottom,
    required this.composerHeightNotifier,
  });

  final double baseComposerBottom;
  final ValueNotifier<double> composerHeightNotifier;

  @override
  Widget build(BuildContext context) {
    final kbInset = MediaQuery.viewInsetsOf(context).bottom;
    final quantizedKb = kbInset > 0 ? ((kbInset / 64.0).ceil() * 64.0) : 0.0;
    return ValueListenableBuilder<double>(
      valueListenable: composerHeightNotifier,
      builder: (_, compH, __) {
        final bottomGap = math.max(baseComposerBottom, quantizedKb + 8.0);
        return SizedBox(height: bottomGap + compH + 26.0);
      },
    );
  }
}

/// Isolated Chat Canvas Area watching ONLY `turns.length` (NEVER `s.turns`!).
/// Inside `ListView.builder`, each slot is a `_TurnListItem` watching ONLY `s.turns[index]`:
/// completed turns hold identical object references -> ZERO rebuilds during live streaming!
class _ChatCanvasArea extends ConsumerWidget {
  const _ChatCanvasArea({
    required this.scrollCtrl,
    required this.listTopPad,
    required this.screenH,
    required this.topPad,
    required this.baseComposerBottom,
    required this.composerHeightNotifier,
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
  });

  final ScrollController scrollCtrl;
  final double listTopPad;
  final double screenH;
  final double topPad;
  final double baseComposerBottom;
  final ValueNotifier<double> composerHeightNotifier;
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
          activeSessionId: s.activeSessionId,
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

    // Never place `ListView.builder(controller: scrollCtrl)` inside `AnimatedSwitcher`!
    // Otherwise fast session switches (< 140ms) keep an outgoing ScrollPosition attached
    // while mounting the incoming one -> `StateError: Too many elements`!
    return Stack(
      fit: StackFit.expand,
      children: [
        if (showActiveList)
          NotificationListener<ScrollNotification>(
            key: const ValueKey('active-chat-stage'),
            onNotification: onScrollNotification,
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: onScrollMetricsNotification,
              child: ListView.builder(
                controller: scrollCtrl,
                cacheExtent: 1200,
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: true,
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                padding: EdgeInsets.fromLTRB(20, listTopPad, 20, 0),
                itemCount: slice.turnsCount + 1 + (slice.hasMoreTurns ? 1 : 0),
                findChildIndexCallback: (Key key) {
                  if (key is! ValueKey<String>) return null;
                  final value = key.value;
                  if (value == 'load-older-header') return slice.hasMoreTurns ? 0 : null;
                  final offset = slice.hasMoreTurns ? 1 : 0;
                  if (value == 'chat-scroll-tail') return offset + slice.turnsCount;
                  final liveTurns = ref.read(appProvider).turns;
                  for (var i = 0; i < liveTurns.length; i++) {
                    if (liveTurns[i].stableKey == value) {
                      return offset + i;
                    }
                  }
                  return null;
                },
                itemBuilder: (ctx, rawIndex) {
                  final hasHeader = slice.hasMoreTurns;
                  if (hasHeader && rawIndex == 0) {
                    return Center(
                      key: const ValueKey('load-older-header'),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 16),
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
                                  CupertinoActivityIndicator(radius: 6.5, color: t.primary),
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
                  final index = hasHeader ? rawIndex - 1 : rawIndex;
                  if (index == slice.turnsCount) {
                    return _KeyboardScrollTail(
                      key: const ValueKey('chat-scroll-tail'),
                      baseComposerBottom: baseComposerBottom,
                      composerHeightNotifier: composerHeightNotifier,
                    );
                  }
                  final turns = ref.read(appProvider).turns;
                  final turnKey = index < turns.length ? turns[index].stableKey : 'turn-idx-$index';
                  return _TurnListItem(
                    key: ValueKey(turnKey),
                    index: index,
                    activeSessionId: slice.activeSessionId,
                    animatedTurnIds: animatedTurnIds,
                    onOpenTerminal: onOpenTerminal,
                    onPrefillPrompt: onPrefillPrompt,
                  );
                },
              ),
            ),
          ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 190),
          reverseDuration: const Duration(milliseconds: 120),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOut,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          ),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: child,
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
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
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
                                SelectableText(
                                  slice.sessionLoadError!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 12.5, height: 1.45, color: t.text3),
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
                          child: RepaintBoundary(
                            child: ChatEmptyState(
                              onSuggestionTap: onEmptySuggestionTap,
                              onOpenModelSettings: onOpenModelSettings,
                              onOpenHostSettings: onOpenHostSettings,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('stage-overlay-none')),
        ),
      ],
    );
  }
}

/// Per-index turn slot selecting ONLY `s.turns[index]`:
/// completed turns keep the exact same object identity -> ZERO rebuilds during live streaming!
class _TurnListItem extends ConsumerWidget {
  const _TurnListItem({
    super.key,
    required this.index,
    required this.activeSessionId,
    required this.animatedTurnIds,
    required this.onOpenTerminal,
    required this.onPrefillPrompt,
  });

  final int index;
  final String? activeSessionId;
  final Set<String> animatedTurnIds;
  final VoidCallback onOpenTerminal;
  final ValueChanged<String> onPrefillPrompt;

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
    // Use `turn.stableKey` (preserved across optimistic `pending-session-*` / `client-turn-*`
    // -> real server `sessionId` / `turnId` reconciliation!) so TurnView NEVER unmounts & flickers!
    final turnKeyStr = turn.stableKey;
    final shouldAnimate = turn.isStreaming &&
        slice.isLast &&
        animatedTurnIds.add(turnKeyStr);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: TurnView(
          key: ValueKey(turnKeyStr),
          turn: turn,
          animateEntrance: shouldAnimate,
          onOpenTerminal: onOpenTerminal,
          onPrefillPrompt: onPrefillPrompt,
        ),
      ),
    );
  }
}

/// Isolated empty-state scroll canvas that lifts cleanly on GPU (`Transform.translate`)
/// during IME animation with ZERO rebuilds of hoisted [child] (`ChatEmptyState`)!
class _KeyboardAwareEmptyStage extends StatelessWidget {
  const _KeyboardAwareEmptyStage({
    super.key,
    required this.screenH,
    required this.topPad,
    required this.baseComposerBottom,
    required this.composerHeightNotifier,
    required this.hideCenterTitle,
    required this.child,
  });

  final double screenH;
  final double topPad;
  final double baseComposerBottom;
  final ValueNotifier<double> composerHeightNotifier;
  final bool hideCenterTitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final kbInset = MediaQuery.viewInsetsOf(context).bottom;
    return ValueListenableBuilder<double>(
      valueListenable: composerHeightNotifier,
      builder: (_, compH, __) {
        // Keep SingleChildScrollView padding and ConstrainedBox minHeight CONSTANT across
        // 120Hz IME animation frames, moving the empty stage purely via GPU Transform.translate!
        final restingBottomReserve = baseComposerBottom + compH + 24.0;
        final maxAvailableH = screenH < 180.0 ? 180.0 : screenH;
        final restingAvailableHeight =
            (screenH - topPad - restingBottomReserve).clamp(180.0, maxAvailableH);
        final kbAvailableHeight = (screenH - topPad - (math.max(baseComposerBottom, kbInset + 8.0) + compH + 24.0))
            .clamp(180.0, maxAvailableH);
        // Clamp upward shift to available vertical slack so the greeting never slips into the status bar.
        final maxSafeLift = ((kbAvailableHeight - 250.0) * 0.5).clamp(0.0, 48.0);
        final liftY = (kbInset * 0.18).clamp(0.0, maxSafeLift);

        return SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            20,
            topPad,
            20,
            restingBottomReserve,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: screenH > 0 ? (restingAvailableHeight - 28).clamp(0.0, screenH) : 0.0,
            ),
            child: Center(
              child: Transform.translate(
                offset: Offset(0, -liftY),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Isolated bottom Toast anchor reacting cleanly to both keyboard inset and '+' deck height.
class _KeyboardAwareToastSlot extends StatelessWidget {
  const _KeyboardAwareToastSlot({
    required this.baseComposerBottom,
    required this.plusOpenNotifier,
    required this.composerHeightNotifier,
  });

  final double baseComposerBottom;
  final ValueNotifier<bool> plusOpenNotifier;
  final ValueNotifier<double> composerHeightNotifier;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: plusOpenNotifier,
      builder: (_, plusOpen, __) => ValueListenableBuilder<double>(
        valueListenable: composerHeightNotifier,
        builder: (_, compH, __) => GrassBagToastOverlay(
          bottomOffset: baseComposerBottom + compH + (plusOpen ? 268.0 : 16.0),
          includeKeyboardInset: true,
        ),
      ),
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
