import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, ValueListenable, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../web/deepseek_signin_page.dart';
import '../web/remote_web_login_page.dart';
import '../web/web_embed.dart';
import 'file_preview_sheet.dart';
import 'preview_highlight_utils.dart';
import 'qr_pair_scanner_page.dart';
import 'remote_host_connect_card.dart';

/// Root navigator key used by [GrassBagGlobalToastHost] so toasts tapped above
/// root-navigator modal sheets can still open error detail sheets safely.
final GlobalKey<NavigatorState> grassBagNavigatorKey = GlobalKey<NavigatorState>();

/// Tracks active modal sheet depth so global toasts always render ABOVE open sheets
/// at a clean bottom offset without being obscured by route dialog barriers.
final ValueNotifier<int> _grassBagOpenSheetDepth = ValueNotifier<int>(0);

class _GlobalToastScope extends InheritedWidget {
  const _GlobalToastScope({
    required this.bottomOffsetNotifier,
    required this.registerOffset,
    required this.unregisterOffset,
    required super.child,
  });

  final ValueNotifier<double> bottomOffsetNotifier;
  final void Function(Object token, double offset) registerOffset;
  final void Function(Object token) unregisterOffset;

  static _GlobalToastScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GlobalToastScope>();

  @override
  bool updateShouldNotify(_GlobalToastScope oldWidget) =>
      bottomOffsetNotifier != oldWidget.bottomOffsetNotifier;
}

/// Mounted once in [MaterialApp.builder] so every [GrassBagToastOverlay] across
/// pages and modal sheets coalesces into a single top-most Liquid Glass toast layer.
class GrassBagGlobalToastHost extends StatefulWidget {
  const GrassBagGlobalToastHost({super.key, required this.child});
  final Widget child;

  @override
  State<GrassBagGlobalToastHost> createState() => _GrassBagGlobalToastHostState();
}

class _GrassBagGlobalToastHostState extends State<GrassBagGlobalToastHost> {
  final ValueNotifier<double> _bottomOffset = ValueNotifier<double>(28.0);
  final List<({Object token, double offset})> _offsetStack = [];

  void _syncTopOffset() {
    final next = _offsetStack.isEmpty ? 28.0 : _offsetStack.last.offset;
    if ((_bottomOffset.value - next).abs() > 0.5) {
      _bottomOffset.value = next;
    }
  }

  void _registerOffset(Object token, double offset) {
    final idx = _offsetStack.indexWhere((e) => identical(e.token, token));
    if (idx >= 0) {
      _offsetStack[idx] = (token: token, offset: offset);
    } else {
      _offsetStack.add((token: token, offset: offset));
    }
    _syncTopOffset();
  }

  void _unregisterOffset(Object token) {
    final before = _offsetStack.length;
    _offsetStack.removeWhere((e) => identical(e.token, token));
    if (_offsetStack.length != before) {
      _syncTopOffset();
    }
  }

  @override
  void dispose() {
    _offsetStack.clear();
    _bottomOffset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _GlobalToastScope(
      bottomOffsetNotifier: _bottomOffset,
      registerOffset: _registerOffset,
      unregisterOffset: _unregisterOffset,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          ValueListenableBuilder<int>(
            valueListenable: _grassBagOpenSheetDepth,
            builder: (_, sheetDepth, __) => ValueListenableBuilder<double>(
              valueListenable: _bottomOffset,
              builder: (_, pageBottom, __) => GrassBagToastOverlay(
                bottomOffset: sheetDepth > 0 ? 24.0 : pageBottom,
                includeKeyboardInset: true,
                isGlobalHost: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mathematically bottom-centered Liquid Glass Toast using authentic iOS 26
/// smooth appear/disappear curves. Warning/error toasts stay tappable so users
/// can inspect and copy the full error detail instead of losing clipped errors.
class GrassBagToastOverlay extends ConsumerStatefulWidget {
  const GrassBagToastOverlay({
    super.key,
    required this.bottomOffset,
    this.includeKeyboardInset = true,
    this.isGlobalHost = false,
  });
  final double bottomOffset;
  final bool includeKeyboardInset;
  final bool isGlobalHost;

  @override
  ConsumerState<GrassBagToastOverlay> createState() => _GrassBagToastOverlayState();
}

class _GrassBagToastOverlayState extends ConsumerState<GrassBagToastOverlay> {
  GrassBagToastMessage? _retainedToast;
  final Object _offsetToken = Object();
  _GlobalToastScope? _registeredScope;
  double? _lastRegisteredBottomOffset;
  bool? _lastRegisteredCurrent;

  @override
  void dispose() {
    final scope = _registeredScope;
    if (scope != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        scope.unregisterOffset(_offsetToken);
      });
    }
    super.dispose();
  }

  void _openErrorDetail(
    BuildContext context,
    WidgetRef ref,
    GrassBagToastMessage toast,
  ) {
    final trimmedDetail = toast.detail?.trim() ?? '';
    final trimmedText = toast.text.trim();
    final fullText = (trimmedDetail.isNotEmpty &&
            trimmedText != trimmedDetail &&
            !trimmedText.endsWith(trimmedDetail))
        ? '${toast.text}\n\n$trimmedDetail'
        : toast.text;
    final ctrl = ref.read(appProvider.notifier);
    ctrl.dismissToast();
    final navCtx = grassBagNavigatorKey.currentContext ?? context;
    final navT = GrassBagTokens.of(navCtx);
    final isErr = toast.tone == ToastTone.error;
    final isWarn = toast.tone == ToastTone.warn;
    showGrassBagSheet<void>(
      navCtx,
      title: isErr ? '异常详情' : (isWarn ? '警告详情' : '提示详情'),
      subtitle: '可长按选取或一键复制完整信息用于排查',
      icon: isErr
          ? CupertinoIcons.exclamationmark_triangle_fill
          : (isWarn
              ? CupertinoIcons.exclamationmark_circle_fill
              : CupertinoIcons.info_circle_fill),
      iconColor: isErr ? navT.err : (isWarn ? navT.warn : navT.primary),
      expandable: true,
      bodyBuilder: (ctx) {
        final t = GrassBagTokens.of(ctx);
        final container = ProviderScope.containerOf(ctx, listen: false);
        final tier = container.read(appProvider).glassTier;
        final safeCtrl = container.read(appProvider.notifier);
        final metrics = GrassBagSheetMetrics.maybeOf(ctx);
        final maxDetailH = (metrics != null && metrics.expanded)
            ? math.max(280.0, metrics.maxBodyHeight - 92.0)
            : 280.0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GrassBagFresnelGlassSurface(
              borderRadius: 16,
              innerWell: true,
              tintColor: isErr ? t.errSoft : (isWarn ? t.warnSoft : null),
              padding: const EdgeInsets.all(14),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxDetailH),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: SelectableText(
                    fullText,
                    contextMenuBuilder: buildGrassBagEditableContextMenu,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.2,
                      height: 1.52,
                      color: t.text,
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
                    label: '关闭',
                    tier: tier,
                    insideGlass: true,
                    onTap: () => Navigator.of(ctx).pop(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GrassBagPrimaryGlassButton(
                    label: '复制详情',
                    icon: CupertinoIcons.doc_on_doc,
                    tier: tier,
                    insideGlass: true,
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: fullText));
                      Navigator.of(ctx).pop();
                      safeCtrl.showToast(
                        isErr ? '已复制异常详情' : '已复制提示详情',
                        tone: ToastTone.ok,
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final globalScope = _GlobalToastScope.maybeOf(context);
    if (!widget.isGlobalHost && globalScope != null) {
      _registeredScope = globalScope;
      final isCurrentRoute = ModalRoute.of(context)?.isCurrent ?? true;
      if (isCurrentRoute) {
        if (_lastRegisteredCurrent != true ||
            _lastRegisteredBottomOffset != widget.bottomOffset) {
          _lastRegisteredCurrent = true;
          _lastRegisteredBottomOffset = widget.bottomOffset;
          final offset = widget.bottomOffset;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
              globalScope.registerOffset(_offsetToken, offset);
            }
          });
        }
      } else {
        _lastRegisteredCurrent = false;
      }
      // Must return Positioned (never a non-positioned SizedBox.shrink()) so pages whose
      // Stack contains only Positioned children + GrassBagToastOverlay don't collapse to 0x0!
      return const Positioned(
        left: 0,
        bottom: 0,
        child: SizedBox.shrink(),
      );
    }

    final toast = ref.watch(appProvider.select((s) => s.toast));
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final t = GrassBagTokens.of(context);
    if (toast != null) {
      _retainedToast = toast;
    }
    final displayToast = toast ?? _retainedToast;
    final isVisible = toast != null;

    // When no toast is visible AND its reverse exit animation has finished, unmount the
    // viewInsets-subscribing host completely so the root overlay leaks ZERO 120Hz rebuilds!
    if (displayToast == null) {
      return const Positioned(
        left: 0,
        bottom: 0,
        child: SizedBox.shrink(),
      );
    }

    final isAlertTone =
        displayToast.tone == ToastTone.error || displayToast.tone == ToastTone.warn;
    final toneColor = switch (displayToast.tone) {
      ToastTone.ok => t.ok,
      ToastTone.warn => t.warn,
      ToastTone.error => t.err,
      ToastTone.info => t.primary,
    };
    final isInspectable =
        (displayToast.detail != null && displayToast.detail!.trim().isNotEmpty) ||
            (isAlertTone && displayToast.text.trim().length > 48);
    final isCurrentRoute = widget.isGlobalHost || (ModalRoute.of(context)?.isCurrent ?? true);
    return _ToastPositionedHost(
      visible: isVisible,
      tier: tier,
      bottomOffset: widget.bottomOffset,
      includeKeyboardInset: widget.includeKeyboardInset && isCurrentRoute,
      onExited: () {
        if (mounted && ref.read(appProvider).toast == null && _retainedToast != null) {
          setState(() => _retainedToast = null);
        }
      },
      child: Semantics(
        key: ValueKey('toast-${displayToast.id}'),
        liveRegion: true,
        label: displayToast.text,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Material(
              type: MaterialType.transparency,
              child: GrassBagSpringTap(
                pressedScale: 0.96,
                enablePointerGlow: false,
                haptic: true,
                onTap: isInspectable
                    ? () => _openErrorDetail(context, ref, displayToast)
                    : () => ref.read(appProvider.notifier).dismissToast(),
                child: _ToastSwipeDismissHost(
                  onDismiss: () => ref.read(appProvider.notifier).dismissToast(),
                  child: GrassBagGlass(
                    tier: tier,
                    borderRadius: isAlertTone ? 20 : 999,
                    elevated: true,
                    interactiveGlow: true,
                    useSheetSettings: true,
                    padding: EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: isAlertTone ? 10 : 9,
                    ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            toneColor.withValues(alpha: t.isDark ? 0.34 : 0.22),
                            toneColor.withValues(alpha: t.isDark ? 0.16 : 0.10),
                          ],
                        ),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: toneColor.withValues(alpha: t.isDark ? 0.42 : 0.28),
                          width: 0.65,
                        ),
                      ),
                      child: Icon(
                        switch (displayToast.tone) {
                          ToastTone.ok => CupertinoIcons.checkmark_alt,
                          ToastTone.warn => CupertinoIcons.exclamationmark,
                          ToastTone.error => CupertinoIcons.exclamationmark_triangle_fill,
                          ToastTone.info => CupertinoIcons.sparkles,
                        },
                        size: displayToast.tone == ToastTone.error ? 12 : 13,
                        color: toneColor,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Flexible(
                      child: Text(
                        displayToast.text,
                        maxLines: isAlertTone ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.15,
                          color: t.text,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                    if (isInspectable) ...[
                      const SizedBox(width: 8),
                      Text(
                        '详情',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: toneColor,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        CupertinoIcons.chevron_right,
                        size: 11,
                        color: toneColor,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// Live spring vertical swipe-to-dismiss wrapper for toasts (subtle upward rubber-band,
/// 1:1 downward tracking, velocity-preserving spring-back or dismiss).
class _ToastSwipeDismissHost extends StatefulWidget {
  const _ToastSwipeDismissHost({
    required this.onDismiss,
    required this.child,
  });

  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<_ToastSwipeDismissHost> createState() => _ToastSwipeDismissHostState();
}

class _ToastSwipeDismissHostState extends State<_ToastSwipeDismissHost>
    with SingleTickerProviderStateMixin {
  late final SingleSpringController _dragSpring = SingleSpringController(
    vsync: this,
    spring: GlassSpring.snappy(duration: const Duration(milliseconds: 240)),
    initialValue: 0.0,
  );
  bool _dismissed = false;

  @override
  void dispose() {
    _dragSpring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (d) {
        if (_dismissed) return;
        final cur = _dragSpring.value;
        final dy = d.delta.dy;
        final next = (cur < 0 || (cur == 0 && dy < 0))
            ? (cur + dy * 0.18).clamp(-16.0, 0.0)
            : (cur + dy).clamp(0.0, 120.0);
        _dragSpring.setValue(next);
      },
      onVerticalDragEnd: (d) {
        if (_dismissed) return;
        final vel = d.primaryVelocity ?? 0.0;
        if (_dragSpring.value > 28.0 || vel > 220.0) {
          _dismissed = true;
          HapticFeedback.selectionClick();
          widget.onDismiss();
        } else {
          _dragSpring.animateTo(0.0, fromVelocity: vel);
        }
      },
      onVerticalDragCancel: () {
        if (!_dismissed) _dragSpring.animateTo(0.0);
      },
      child: ListenableBuilder(
        listenable: _dragSpring,
        child: widget.child,
        builder: (_, child) => Transform.translate(
          offset: Offset(0, _dragSpring.value),
          child: child,
        ),
      ),
    );
  }
}

/// Isolated leaf widget mounted ONLY while a toast is visible (or finishing its 160ms reverse
/// exit animation). Unmounting it on exit removes its `MediaQuery.viewInsetsOf` dependency via
/// `Element.deactivate()`, eliminating permanent 120Hz root-overlay rebuilds during keyboard motion!
class _ToastPositionedHost extends StatefulWidget {
  const _ToastPositionedHost({
    required this.visible,
    required this.tier,
    required this.bottomOffset,
    required this.includeKeyboardInset,
    required this.onExited,
    required this.child,
  });

  final bool visible;
  final GrassBagGlassTier tier;
  final double bottomOffset;
  final bool includeKeyboardInset;
  final VoidCallback onExited;
  final Widget child;

  @override
  State<_ToastPositionedHost> createState() => _ToastPositionedHostState();
}

class _ToastPositionedHostState extends State<_ToastPositionedHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enterCtrl;
  late final CurvedAnimation _curved;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _enterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 160),
    )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed && !widget.visible) {
          widget.onExited();
        }
      });
    if (widget.visible) {
      _enterCtrl.forward();
    }
    _curved = CurvedAnimation(
      parent: _enterCtrl,
      curve: const Cubic(0.22, 1.0, 0.36, 1.0),
      reverseCurve: Curves.easeInCubic,
    );
    _slide = Tween<Offset>(begin: const Offset(0, 0.24), end: Offset.zero).animate(_curved);
  }

  @override
  void didUpdateWidget(covariant _ToastPositionedHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reduceMotion = mounted && MediaQuery.disableAnimationsOf(context);
    if (widget.visible && !oldWidget.visible) {
      if (reduceMotion) {
        _enterCtrl.value = 1.0;
      } else {
        _enterCtrl.forward();
      }
    } else if (!widget.visible && oldWidget.visible) {
      if (reduceMotion) {
        _enterCtrl.value = 0.0;
        widget.onExited();
      } else {
        _enterCtrl.reverse();
      }
    }
    // Replacement toasts crossfade smoothly in-place via AnimatedSwitcher below
    // (no 1-frame `_enterCtrl.value = 0.0` blink!).
  }

  @override
  void dispose() {
    _curved.dispose();
    _enterCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kbInset = widget.includeKeyboardInset
        ? MediaQuery.viewInsetsOf(context).bottom
        : 0.0;
    final viewPad = MediaQuery.viewPaddingOf(context);
    final viewBot = viewPad.bottom;
    final effectiveKb = kbInset > viewBot ? (kbInset - viewBot) : 0.0;
    final safeBottom = math.max(widget.bottomOffset, viewBot + 12.0);
    final screenH = MediaQuery.sizeOf(context).height;
    final maxLift = math.max(0.0, screenH - viewPad.top - 124.0 - safeBottom);
    final clampedKb = effectiveKb.clamp(0.0, maxLift);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final swappedChild = AnimatedSwitcher(
      duration: GrassBagMotion.duration(context, const Duration(milliseconds: 160)),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: widget.child,
    );
    final motionChild = reduceMotion
        ? GrassBagMaterializeTransition(
            animation: _enterCtrl,
            tier: widget.tier,
            alignment: Alignment.bottomCenter,
            scaleFrom: 1.0,
            contentSigma: 0.0,
            child: swappedChild,
          )
        : SlideTransition(
            position: _slide,
            child: GrassBagMaterializeTransition(
              animation: _enterCtrl,
              tier: widget.tier,
              alignment: Alignment.bottomCenter,
              scaleFrom: 0.94,
              contentSigma: 3.5,
              child: swappedChild,
            ),
          );
    return AnimatedPositioned(
      duration: GrassBagMotion.duration(context, const Duration(milliseconds: 220)),
      curve: Curves.easeOutCubic,
      left: 16,
      right: 16,
      bottom: safeBottom,
      child: Transform.translate(
        offset: Offset(0, -clampedKb),
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: motionChild,
        ),
      ),
    );
  }
}

/// Sculpted Apple iOS 26 centered Liquid Glass confirmation dialog with crystal readability
/// and unmistakable button visual hierarchy (subtle secondary Cancel vs accented/destructive Confirm).
Future<bool> showGrassBagConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String cancelLabel = '取消',
  required String confirmLabel,
  bool isDestructive = false,
  IconData? icon,
}) async {
  final t = GrassBagTokens.of(context);
  GrassBagGlassTier tier;
  try {
    tier = ProviderScope.containerOf(context, listen: false).read(appProvider).glassTier;
  } catch (_) {
    tier = resolveAmbientGlassTier(context);
  }
  final badgeIcon = icon ??
      (isDestructive
          ? CupertinoIcons.exclamationmark_shield_fill
          : CupertinoIcons.shield_lefthalf_fill);
  HapticFeedback.mediumImpact();
  _grassBagOpenSheetDepth.value++;
  try {
    final result = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: cancelLabel,
      barrierColor: t.isDark ? const Color(0x88080C12) : const Color(0x3D142233),
      transitionDuration: GrassBagMotion.duration(
        context,
        const Duration(milliseconds: 220),
        reduced: const Duration(milliseconds: 80),
      ),
      pageBuilder: (dialogCtx, animation, secondaryAnimation) {
        final dt = GrassBagTokens.of(dialogCtx);
        final dialogBadgeColor = isDestructive ? dt.err : dt.primary;
        final kbBottom = MediaQuery.viewInsetsOf(dialogCtx).bottom;
        final availH = math.max(200.0, MediaQuery.sizeOf(dialogCtx).height - kbBottom);
        final maxDialogH = (availH * 0.78).clamp(200.0, 560.0);
        final reduceMotion = MediaQuery.disableAnimationsOf(dialogCtx);
        return Padding(
          padding: EdgeInsets.only(bottom: kbBottom),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 344, maxHeight: maxDialogH),
                child: AnimatedBuilder(
                  animation: animation,
                  builder: (_, child) {
                    if (reduceMotion) return child!;
                    final isReversing = animation.status == AnimationStatus.reverse;
                    final curved = (isReversing
                            ? Curves.easeInCubic
                            : Curves.easeOutCubic)
                        .transform(animation.value);
                    // Asymmetric iOS 26 UIAlertController scale: settles in 1.07 -> 1.0,
                    // recedes gracefully 1.0 -> 0.94 on dismiss (never looms outward!).
                    final scale = isReversing
                        ? (0.94 + 0.06 * curved)
                        : (tier == GrassBagGlassTier.solid
                            ? (0.92 + 0.08 * curved)
                            : (1.07 - 0.07 * curved));
                    return Transform.scale(scale: scale, child: child);
                  },
                  child: GrassBagMaterializeTransition(
                    animation: animation,
                    tier: tier,
                    scaleFrom: 1.0,
                    contentSigma: 6.0,
                    child: Material(
                  type: MaterialType.transparency,
                  child: GrassBagGlass(
                    tier: tier,
                    borderRadius: 34,
                    elevated: true,
                    interactiveGlow: false,
                    useSheetSettings: true,
                    isDialog: true,
                    clipBehavior: Clip.antiAlias,
                    padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            GrassBagSquircleIcon(
                              icon: badgeIcon,
                              color: dialogBadgeColor,
                              size: 38,
                              iconSize: 18,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                title,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.35,
                                  color: dt.text,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (message.trim().isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Flexible(
                            child: SingleChildScrollView(
                              physics: const BouncingScrollPhysics(),
                              child: Text(
                                message,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.54,
                                  color: dt.text2,
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: GrassBagSecondaryGlassButton(
                                label: cancelLabel,
                                height: 48,
                                tier: tier,
                                insideGlass: true,
                                onTap: () => Navigator.of(dialogCtx).pop(false),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: GrassBagPrimaryGlassButton(
                                label: confirmLabel,
                                height: 48,
                                tier: tier,
                                insideGlass: true,
                                // Deep crimson glass in Dark mode keeps WCAG AA (>5.2:1) contrast with crisp white label!
                                color: isDestructive
                                    ? (dt.isDark ? const Color(0xFFD93835) : dt.err)
                                    : dt.primary,
                                foregroundColor: isDestructive ? Colors.white : dt.onPrimary,
                                onTap: () => Navigator.of(dialogCtx).pop(true),
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
          ),
        ),
        ),
        );
      },
      transitionBuilder: (_, __, ___, child) => child,
    );
    return result == true;
  } finally {
    _grassBagOpenSheetDepth.value = math.max(0, _grassBagOpenSheetDepth.value - 1);
  }
}

/// Presents a true pixel-accurate intrinsic content-height Apple iOS 26 floating Liquid Glass
/// Sheet with EXACT concentric `16px` left / right / bottom inset (`32pt` outer radius ->
/// `16pt` inner radius) — ZERO wasted empty bottom whitespace on Phone, Tablet, and Desktop!
/// Automatically caps width to `440dp` centered on wide screens, supports smooth spring
/// swipe-down-to-dismiss, and scrolls cleanly only when content exceeds 82% of viewport height.
Future<T?> showGrassBagSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  IconData? icon,
  Color? iconColor,
  required WidgetBuilder bodyBuilder,
  double? preferredHeight,
  bool expandable = false,
  bool initialExpanded = false,
  bool wideLayout = false,
  bool scrollableBody = true,
  GlassMorphAnchor? morphFrom,
  Future<bool> Function()? onWillDismiss,
}) async {
  final t = GrassBagTokens.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final tier = resolveEffectiveGlassTier(context, container.read(appProvider).glassTier);
  final reduceMotion = MediaQuery.disableAnimationsOf(context);

  HapticFeedback.selectionClick();
  _grassBagOpenSheetDepth.value++;
  try {
    return await showGeneralDialog<T>(
      context: context,
      barrierDismissible: onWillDismiss == null,
      barrierLabel: '关闭',
      barrierColor: t.isDark ? const Color(0x82080C14) : const Color(0x46121E2D),
      transitionDuration:
          reduceMotion ? const Duration(milliseconds: 110) : const Duration(milliseconds: 260),
      transitionBuilder: (ctx, anim, _, child) {
        final sz = MediaQuery.sizeOf(ctx);
        final isDesktopDialog = sz.width >= 840 && sz.height >= 520;
        return _GrassBagSheetRouteTransition(
          animation: anim,
          isDesktopDialog: isDesktopDialog,
          tier: tier,
          child: child,
        );
      },
      pageBuilder: (dialogCtx, _, __) {
        return _IntrinsicLiquidGlassSheet(
          title: title,
          subtitle: subtitle,
          icon: icon,
          iconColor: iconColor,
          tier: tier,
          preferredHeight: preferredHeight,
          expandable: expandable,
          initialExpanded: initialExpanded,
          wideLayout: wideLayout,
          scrollableBody: scrollableBody,
          onWillDismiss: onWillDismiss,
          bodyBuilder: bodyBuilder,
        );
      },
    );
  } finally {
    final nextDepth = _grassBagOpenSheetDepth.value - 1;
    _grassBagOpenSheetDepth.value = nextDepth < 0 ? 0 : nextDepth;
  }
}

class _IntrinsicLiquidGlassSheet extends StatefulWidget {
  const _IntrinsicLiquidGlassSheet({
    required this.title,
    required this.subtitle,
    this.icon,
    this.iconColor,
    required this.tier,
    required this.bodyBuilder,
    this.preferredHeight,
    this.expandable = false,
    this.initialExpanded = false,
    this.wideLayout = false,
    this.scrollableBody = true,
    this.onWillDismiss,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final GrassBagGlassTier tier;
  final WidgetBuilder bodyBuilder;
  final double? preferredHeight;
  final bool expandable;
  final bool initialExpanded;
  final bool wideLayout;
  final bool scrollableBody;
  final Future<bool> Function()? onWillDismiss;

  @override
  State<_IntrinsicLiquidGlassSheet> createState() => _IntrinsicLiquidGlassSheetState();
}

class _IntrinsicLiquidGlassSheetState extends State<_IntrinsicLiquidGlassSheet>
    with SingleTickerProviderStateMixin {
  late final SingleSpringController _dragSpring;
  final ScrollController _bodyScrollCtrl = ScrollController();
  final ValueNotifier<double> _topFadeNotifier = ValueNotifier<double>(0.0);
  final ValueNotifier<bool> _draggingNotifier = ValueNotifier<bool>(false);
  bool _dragging = false;
  bool _dismissing = false;
  late bool _expanded;
  bool _confirmingDismiss = false;

  Future<void> _requestDismiss({double flingVelocity = 0.0, bool fromDrag = false}) async {
    if (_dismissing || _confirmingDismiss) return;
    final guard = widget.onWillDismiss;
    if (guard != null) {
      _confirmingDismiss = true;
      bool allowed = true;
      try {
        allowed = await guard();
      } finally {
        _confirmingDismiss = false;
      }
      if (!mounted) return;
      if (!allowed) {
        // Never replay a stale downward fling velocity after an async dialog rejects dismiss!
        _dragSpring.animateTo(0.0, fromVelocity: 0.0);
        return;
      }
    }
    _dismissing = true;
    // Continue moving smoothly along finger fling momentum while route pops instead of braking dead!
    if (fromDrag && mounted && !MediaQuery.disableAnimationsOf(context)) {
      final targetOffscreen = math.max(_dragSpring.value + 160.0, 260.0);
      _dragSpring.animateTo(
        targetOffscreen,
        fromVelocity: math.max(flingVelocity, 360.0),
      );
    }
    Navigator.of(context).pop();
  }

  @override
  void initState() {
    super.initState();
    _expanded = widget.initialExpanded && widget.expandable;
    _dragSpring = SingleSpringController(
      vsync: this,
      spring: GlassSpring.snappy(duration: const Duration(milliseconds: 300)),
      initialValue: 0.0,
    );
    _bodyScrollCtrl.addListener(_onBodyScroll);
  }

  void _onBodyScroll() {
    if (!_bodyScrollCtrl.hasClients) return;
    final next = (_bodyScrollCtrl.offset / 14.0).clamp(0.0, 1.0);
    final prev = _topFadeNotifier.value;
    if ((next - prev).abs() > 0.03 || (next == 0.0 && prev != 0.0) || (next == 1.0 && prev != 1.0)) {
      _topFadeNotifier.value = next;
    }
  }

  @override
  void dispose() {
    _bodyScrollCtrl.removeListener(_onBodyScroll);
    _bodyScrollCtrl.dispose();
    _topFadeNotifier.dispose();
    _draggingNotifier.dispose();
    _dragSpring.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    if (!widget.expandable) return;
    HapticFeedback.selectionClick();
    setState(() => _expanded = !_expanded);
  }

  void _onDragStart(DragStartDetails _) {
    if (_dismissing) return;
    _dragging = true;
    _draggingNotifier.value = true;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging || _dismissing) return;
    final cur = _dragSpring.value;
    final delta = d.delta.dy;
    // Rubber-band resistance on incremental upward delta only (never multiply accumulated
    // position by 0.18 on every frame, which caused rapid upward jitter).
    final next = (cur < 0 || (cur == 0 && delta < 0))
        ? (cur + delta * 0.18).clamp(-26.0, 0.0)
        : math.max(0.0, cur + delta);
    _dragSpring.setValue(next);
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_dragging || _dismissing) return;
    _dragging = false;
    _draggingNotifier.value = false;
    final vel = d.primaryVelocity ?? 0.0;
    if (widget.expandable && !_expanded && (_dragSpring.value < -14.0 || vel < -420.0)) {
      _dragSpring.animateTo(0.0, fromVelocity: vel);
      _toggleExpanded();
      return;
    }
    if (widget.expandable && _expanded && (_dragSpring.value > 56.0 || vel > 460.0)) {
      _dragSpring.animateTo(0.0, fromVelocity: vel);
      _toggleExpanded();
      return;
    }
    if (_dragSpring.value > 72.0 || vel > 520.0) {
      unawaited(_requestDismiss(flingVelocity: vel, fromDrag: true));
    } else {
      _dragSpring.animateTo(0.0, fromVelocity: vel);
    }
  }

  void _onDragCancel() {
    if (_dismissing) return;
    _dragging = false;
    _draggingNotifier.value = false;
    _dragSpring.animateTo(0.0);
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final size = MediaQuery.sizeOf(context);
    final viewPad = MediaQuery.viewPaddingOf(context);
    final isDesktopDialog = size.width >= 840 && size.height >= 520;

    // Hoist heavy bodyBuilder OUTSIDE MediaQuery.viewInsetsOf so 120Hz keyboard frames
    // NEVER rebuild SchemasteryForm, ModelConfig, or long option lists inside the sheet!
    final sheetCard = GrassBagGlass(
      tier: widget.tier,
      borderRadius: 32,
      elevated: true,
      interactiveGlow: false,
      useSheetSettings: true,
      clipBehavior: Clip.antiAlias,
      padding: EdgeInsets.fromLTRB(16, isDesktopDialog ? 16 : 10, 16, 16),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: widget.scrollableBody ? MainAxisSize.min : MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: isDesktopDialog ? null : _onDragStart,
              onVerticalDragUpdate: isDesktopDialog ? null : _onDragUpdate,
              onVerticalDragEnd: isDesktopDialog ? null : _onDragEnd,
              onVerticalDragCancel: isDesktopDialog ? null : _onDragCancel,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!isDesktopDialog) ...[
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onDoubleTap: widget.expandable ? _toggleExpanded : null,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 11),
                        child: Center(
                          child: ValueListenableBuilder<bool>(
                            valueListenable: _draggingNotifier,
                            builder: (_, dragging, __) => AnimatedContainer(
                              duration: GrassBagMotion.duration(
                                context,
                                const Duration(milliseconds: 140),
                              ),
                              curve: Curves.easeOutCubic,
                              width: dragging ? 48 : 38,
                              height: 4,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: t.isDark
                                      ? [
                                          Colors.white.withValues(alpha: dragging ? 0.62 : 0.36),
                                          Colors.white.withValues(alpha: dragging ? 0.34 : 0.18),
                                        ]
                                      : [
                                          Colors.black.withValues(alpha: dragging ? 0.34 : 0.21),
                                          Colors.black.withValues(alpha: dragging ? 0.20 : 0.12),
                                        ],
                                ),
                                borderRadius: BorderRadius.circular(99),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (widget.icon != null) ...[
                          GrassBagSquircleIcon(
                            icon: widget.icon!,
                            color: widget.iconColor ?? t.primary,
                            size: 36,
                            iconSize: 17.5,
                          ),
                          const SizedBox(width: 11),
                        ],
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onDoubleTap: widget.expandable ? _toggleExpanded : null,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 17.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.35,
                                    color: t.text,
                                  ),
                                ),
                                if (widget.subtitle != null && widget.subtitle!.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2.5),
                                    child: Text(
                                      widget.subtitle!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12.2,
                                        height: 1.35,
                                        color: t.text3,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                          const SizedBox(width: 4),
                          if (widget.expandable)
                            Tooltip(
                              message: _expanded ? '还原大小' : '展开全屏',
                              excludeFromSemantics: true,
                              child: Semantics(
                                button: true,
                                label: _expanded ? '还原大小' : '展开全屏',
                                child: GrassBagSpringTap(
                                  onTap: _toggleExpanded,
                                  pressedScale: 0.88,
                                  enablePointerGlow: false,
                                  haptic: true,
                                  child: SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: Center(
                                      child: GrassBagFresnelGlassSurface(
                                        isCircle: true,
                                        innerWell: true,
                                        interactive: false,
                                        width: 30,
                                        height: 30,
                                        alignment: Alignment.center,
                                        child: AnimatedSwitcher(
                                          duration: GrassBagMotion.duration(
                                            context,
                                            const Duration(milliseconds: 170),
                                          ),
                                          switchInCurve: Curves.easeOutCubic,
                                          switchOutCurve: Curves.easeInCubic,
                                          transitionBuilder: (c, a) => FadeTransition(
                                            opacity: a,
                                            child: ScaleTransition(
                                              scale: Tween<double>(begin: 0.78, end: 1.0)
                                                  .animate(a),
                                              child: c,
                                            ),
                                          ),
                                          child: Icon(
                                            _expanded
                                                ? CupertinoIcons.arrow_down_right_arrow_up_left
                                                : CupertinoIcons.arrow_up_left_arrow_down_right,
                                            key: ValueKey(_expanded),
                                            size: 13,
                                            color: t.text2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Tooltip(
                            message: '关闭',
                            excludeFromSemantics: true,
                            child: Semantics(
                              button: true,
                              label: '关闭',
                              child: GrassBagSpringTap(
                                onTap: () => unawaited(_requestDismiss()),
                                pressedScale: 0.88,
                                enablePointerGlow: false,
                                haptic: true,
                                child: SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: Center(
                                    child: GrassBagFresnelGlassSurface(
                                      isCircle: true,
                                      innerWell: true,
                                      interactive: false,
                                      width: 30,
                                      height: 30,
                                      alignment: Alignment.center,
                                      child: Icon(
                                        CupertinoIcons.xmark,
                                        size: 13.5,
                                        color: t.text2,
                                      ),
                                    ),
                                  ),
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
              if (widget.scrollableBody)
                Flexible(
                  child: RepaintBoundary(
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (isDesktopDialog || _dismissing) return false;
                        // Allow natural pull-down-from-top sheet drag when body is at scroll 0!
                        if (n is OverscrollNotification && n.overscroll < 0) {
                          if (!_dragging) {
                            _dragging = true;
                            _draggingNotifier.value = true;
                          }
                          _dragSpring.setValue(math.max(0.0, _dragSpring.value - n.overscroll));
                        } else if (n is ScrollUpdateNotification &&
                            n.dragDetails != null &&
                            n.metrics.pixels <= 0.0 &&
                            (n.dragDetails!.delta.dy > 0 || _dragging)) {
                          if (!_dragging && n.dragDetails!.delta.dy > 0) {
                            _dragging = true;
                            _draggingNotifier.value = true;
                          }
                          if (_dragging) {
                            final next = math.max(0.0, _dragSpring.value + n.dragDetails!.delta.dy);
                            _dragSpring.setValue(next);
                          }
                        } else if (n is ScrollEndNotification && _dragging) {
                          final vel = n.dragDetails?.primaryVelocity ?? 0.0;
                          _onDragEnd(DragEndDetails(
                            velocity: Velocity(pixelsPerSecond: Offset(0, vel)),
                            primaryVelocity: vel,
                          ));
                        }
                        return false;
                      },
                      child: _ConditionalTopFadeMask(
                        fadeListenable: _topFadeNotifier,
                        child: SingleChildScrollView(
                          controller: _bodyScrollCtrl,
                          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                          physics: const BouncingScrollPhysics(),
                          child: Builder(builder: widget.bodyBuilder),
                        ),
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: RepaintBoundary(
                    child: Builder(builder: widget.bodyBuilder),
                  ),
                ),
            ],
          ),
        ),
    );

    final framed = _SheetKeyboardFrame(
      size: size,
      viewPad: viewPad,
      isDesktopDialog: isDesktopDialog,
      expanded: _expanded,
      wideLayout: widget.wideLayout,
      preferredHeight: widget.preferredHeight,
      child: ListenableBuilder(
        listenable: _dragSpring,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, _dragSpring.value),
          child: child,
        ),
        child: sheetCard,
      ),
    );
    if (widget.onWillDismiss == null) return framed;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestDismiss());
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => unawaited(_requestDismiss()),
            ),
          ),
          framed,
        ],
      ),
    );
  }
}

/// Constant-depth top-edge feather mask for scrollable modal sheets:
/// - NEVER changes widget tree depth across scroll offsets (zero form state loss / remounts!)
/// - Pushes zero `ShaderMaskLayer` / `saveLayer` when resting at `offset == 0`
/// - Listens directly to `fadeListenable` inside RenderObject (`markNeedsPaint` only, zero rebuilds)
class _ConditionalTopFadeMask extends SingleChildRenderObjectWidget {
  const _ConditionalTopFadeMask({
    required this.fadeListenable,
    required super.child,
  });

  final ValueListenable<double> fadeListenable;

  @override
  _RenderConditionalTopFadeMask createRenderObject(BuildContext context) =>
      _RenderConditionalTopFadeMask(fadeListenable);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderConditionalTopFadeMask renderObject,
  ) {
    renderObject.fadeListenable = fadeListenable;
  }
}

class _RenderConditionalTopFadeMask extends RenderProxyBox {
  _RenderConditionalTopFadeMask(this._fadeListenable)
      : _needsMask = _fadeListenable.value > 0.01;

  ValueListenable<double> _fadeListenable;
  bool _needsMask;
  Shader? _cachedShader;
  Size? _cachedShaderSize;
  int _cachedFadeBucket = -1;

  set fadeListenable(ValueListenable<double> value) {
    if (identical(_fadeListenable, value)) return;
    if (attached) _fadeListenable.removeListener(_onFadeChanged);
    _fadeListenable = value;
    if (attached) _fadeListenable.addListener(_onFadeChanged);
    _onFadeChanged();
  }

  void _onFadeChanged() {
    final nextMask = _fadeListenable.value > 0.01;
    if (nextMask != _needsMask) {
      _needsMask = nextMask;
      markNeedsCompositingBitsUpdate();
    }
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _fadeListenable.addListener(_onFadeChanged);
  }

  @override
  void detach() {
    _fadeListenable.removeListener(_onFadeChanged);
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => _needsMask;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    final fade = _fadeListenable.value;
    if (!_needsMask || fade <= 0.01 || size.isEmpty) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    final h = math.max(size.height, 18.0);
    final fadeBucket = (fade * 32.0).round().clamp(0, 32);
    Shader shader;
    if (_cachedShader != null &&
        _cachedShaderSize == size &&
        _cachedFadeBucket == fadeBucket) {
      shader = _cachedShader!;
    } else {
      final stop = (18.0 / h).clamp(0.02, 0.16);
      final quantizedFade = fadeBucket / 32.0;
      shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: (1.0 - quantizedFade * 0.96).clamp(0.04, 1.0)),
          Colors.white,
        ],
        stops: [0.0, stop],
      ).createShader(Offset.zero & size);
      _cachedShader = shader;
      _cachedShaderSize = size;
      _cachedFadeBucket = fadeBucket;
    }
    layer ??= ShaderMaskLayer();
    (layer! as ShaderMaskLayer)
      ..shader = shader
      ..maskRect = offset & size
      ..blendMode = BlendMode.dstIn;
    context.pushLayer(layer!, super.paint, offset);
  }
}

/// Stateful route transition for [showGrassBagSheet] owning & disposing its [CurvedAnimation]s
/// cleanly (zero listener leaks!) and giving desktop glass dialogs smooth optical materialization.
class _GrassBagSheetRouteTransition extends StatefulWidget {
  const _GrassBagSheetRouteTransition({
    required this.animation,
    required this.isDesktopDialog,
    required this.tier,
    required this.child,
  });

  final Animation<double> animation;
  final bool isDesktopDialog;
  final GrassBagGlassTier tier;
  final Widget child;

  @override
  State<_GrassBagSheetRouteTransition> createState() =>
      _GrassBagSheetRouteTransitionState();
}

class _GrassBagSheetRouteTransitionState
    extends State<_GrassBagSheetRouteTransition> {
  late CurvedAnimation _curve;
  late Animation<Offset> _sheetSlide;
  late Animation<Offset> _dialogSlide;
  late Animation<double> _dialogScale;

  void _initAnimations() {
    _curve = CurvedAnimation(
      parent: widget.animation,
      curve: const Cubic(0.22, 1.0, 0.36, 1.0),
      reverseCurve: Curves.easeInCubic,
    );
    _sheetSlide = Tween<Offset>(
      begin: const Offset(0, 1.0),
      end: Offset.zero,
    ).animate(_curve);
    _dialogSlide = Tween<Offset>(
      begin: const Offset(0, 0.03),
      end: Offset.zero,
    ).animate(_curve);
    _dialogScale = Tween<double>(begin: 0.96, end: 1.0).animate(_curve);
  }

  @override
  void initState() {
    super.initState();
    _initAnimations();
  }

  @override
  void didUpdateWidget(covariant _GrassBagSheetRouteTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _curve.dispose();
      _initAnimations();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      return FadeTransition(opacity: _curve, child: widget.child);
    }
    if (!widget.isDesktopDialog) {
      return SlideTransition(
        position: _sheetSlide,
        child: widget.child,
      );
    }
    if (widget.tier == GrassBagGlassTier.solid || kIsWeb) {
      return FadeTransition(
        opacity: _curve,
        child: ScaleTransition(
          scale: _dialogScale,
          alignment: Alignment.center,
          child: widget.child,
        ),
      );
    }
    return SlideTransition(
      position: _dialogSlide,
      child: GrassBagMaterializeTransition(
        animation: widget.animation,
        tier: widget.tier,
        alignment: Alignment.center,
        scaleFrom: 0.95,
        contentSigma: 4.5,
        child: widget.child,
      ),
    );
  }
}

/// Exposes active sheet expansion detent and available body height to expandable
/// sheet bodies (diff viewers, error detail, command output) without forcing
/// non-subscribing sheets to rebuild during IME transitions.
class GrassBagSheetMetrics extends InheritedWidget {
  const GrassBagSheetMetrics({
    super.key,
    required this.expanded,
    required this.maxBodyHeight,
    required super.child,
  });

  final bool expanded;
  final double maxBodyHeight;

  static GrassBagSheetMetrics? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GrassBagSheetMetrics>();

  @override
  bool updateShouldNotify(GrassBagSheetMetrics oldWidget) =>
      expanded != oldWidget.expanded ||
      (maxBodyHeight - oldWidget.maxBodyHeight).abs() > 1.0;
}

class _SheetKeyboardFrame extends StatefulWidget {
  const _SheetKeyboardFrame({
    required this.size,
    required this.viewPad,
    required this.isDesktopDialog,
    required this.child,
    this.expanded = false,
    this.wideLayout = false,
    this.preferredHeight,
  });

  final Size size;
  final EdgeInsets viewPad;
  final bool isDesktopDialog;
  final bool expanded;
  final bool wideLayout;
  final double? preferredHeight;
  final Widget child;

  @override
  State<_SheetKeyboardFrame> createState() => _SheetKeyboardFrameState();
}

class _SheetKeyboardFrameState extends State<_SheetKeyboardFrame>
    with SingleTickerProviderStateMixin {
  Timer? _settleTimer;
  double? _settledMaxH;
  double _lastKbInset = -1.0;
  double _lastViewportH = -1.0;
  bool _lastExpanded = false;
  bool _ensureVisibleScheduled = false;
  late final SingleSpringController _expandSpring;

  @override
  void initState() {
    super.initState();
    _lastExpanded = widget.expanded;
    _expandSpring = SingleSpringController(
      vsync: this,
      spring: GrassBagMotion.sheetSpring,
      initialValue: widget.expanded ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(covariant _SheetKeyboardFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded != widget.expanded) {
      final target = widget.expanded ? 1.0 : 0.0;
      if (mounted && MediaQuery.disableAnimationsOf(context)) {
        _expandSpring.setValue(target);
      } else {
        _expandSpring.animateTo(target);
      }
    }
  }

  void _scheduleEnsureFocusedVisible() {
    if (_ensureVisibleScheduled) return;
    _ensureVisibleScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureVisibleScheduled = false;
      if (!mounted) return;
      final focusedCtx = FocusManager.instance.primaryFocus?.context;
      if (focusedCtx != null && focusedCtx.mounted) {
        Scrollable.ensureVisible(
          focusedCtx,
          duration: GrassBagMotion.duration(context, const Duration(milliseconds: 160)),
          curve: Curves.easeOutCubic,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    });
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _expandSpring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kbInset = MediaQuery.viewInsetsOf(context).bottom;
    final baseMargin = widget.isDesktopDialog
        ? 24.0
        : (widget.viewPad.bottom > 0 ? widget.viewPad.bottom + 8.0 : 12.0);
    final targetBottom = math.max(
      baseMargin,
      kbInset + (widget.isDesktopDialog ? 16.0 : 10.0),
    );
    final liftY = (targetBottom - baseMargin).clamp(0.0, widget.size.height);
    final topMargin = widget.viewPad.top + 16.0;
    final rawAvailableH = widget.size.height > 88.0
        ? (widget.size.height - topMargin - targetBottom).clamp(88.0, widget.size.height)
        : 88.0;
    final defaultCapH = widget.isDesktopDialog ? 700.0 : 660.0;
    final hintedCapH = widget.preferredHeight != null
        ? math.max(defaultCapH, widget.preferredHeight!)
        : defaultCapH;
    final expandedCapH = math.max(hintedCapH, widget.size.height - topMargin - baseMargin);
    final capH = widget.expanded ? expandedCapH : hintedCapH;
    final unclampedMaxH = math.min(capH, rawAvailableH).clamp(88.0, capH);
    final viewportResized =
        _lastViewportH > 0 && (widget.size.height - _lastViewportH).abs() > 1.0;
    final expandedChanged = _lastExpanded != widget.expanded;

    // Shrink promptly whenever the rising keyboard impinges on a tall sheet (never let the
    // bottom action bar or focused input sink behind the keyboard for 90ms!), while keeping
    // upward expansion settled cleanly once the keyboard finishes dismissing.
    final prevSettled = _settledMaxH;
    final shrinkingForKeyboard = prevSettled != null && unclampedMaxH < prevSettled - 1.0;
    if (prevSettled == null || kbInset <= 0.5 || viewportResized || expandedChanged) {
      _settleTimer?.cancel();
      _settledMaxH = unclampedMaxH;
    } else if (shrinkingForKeyboard) {
      _settleTimer?.cancel();
      _settledMaxH = unclampedMaxH;
      _scheduleEnsureFocusedVisible();
    } else if ((kbInset - _lastKbInset).abs() > 0.5) {
      _settleTimer?.cancel();
      final targetMaxH = unclampedMaxH;
      _settleTimer = Timer(const Duration(milliseconds: 90), () {
        if (mounted && _settledMaxH != targetMaxH) {
          setState(() => _settledMaxH = targetMaxH);
        }
      });
    }
    _lastKbInset = kbInset;
    _lastViewportH = widget.size.height;
    _lastExpanded = widget.expanded;

    final collapsedMaxH = math.min(hintedCapH, rawAvailableH).clamp(88.0, hintedCapH);
    final expandedMaxH = math.min(expandedCapH, rawAvailableH).clamp(88.0, expandedCapH);
    final baseMaxW = widget.isDesktopDialog
        ? (widget.wideLayout ? 860.0 : 500.0)
        : (widget.wideLayout ? 680.0 : 448.0);
    final expandedMaxW = widget.isDesktopDialog
        ? (widget.wideLayout ? 1080.0 : 640.0)
        : (widget.wideLayout ? 680.0 : 448.0);

    // CustomSingleChildLayout smoothly interpolates expand/collapse detents via spring
    // while clamping short/tall sheets cleanly above the IME!
    return MediaQuery.removeViewInsets(
      context: context,
      removeBottom: true,
      child: ListenableBuilder(
        listenable: _expandSpring,
        child: widget.child,
        builder: (_, child) {
          final e = _expandSpring.value.clamp(0.0, 1.0);
          final springMaxH = kbInset > 0.5
              ? math.min(_settledMaxH ?? unclampedMaxH, capH)
              : (collapsedMaxH + (expandedMaxH - collapsedMaxH) * e);
          final horizontalMargin = (!widget.isDesktopDialog && widget.wideLayout)
              ? (16.0 - 8.0 * e)
              : 16.0;
          final maxW = baseMaxW + (expandedMaxW - baseMaxW) * e;
          return GrassBagSheetMetrics(
            expanded: widget.expanded,
            maxBodyHeight: math.max(180.0, springMaxH - 120.0),
            child: CustomSingleChildLayout(
              delegate: _SafeSheetKeyboardLayoutDelegate(
                isDesktopDialog: widget.isDesktopDialog,
                topMargin: topMargin,
                baseMargin: baseMargin,
                horizontalMargin: horizontalMargin,
                targetBottom: targetBottom,
                liftY: liftY,
                maxWidth: maxW,
                maxHeight: springMaxH,
              ),
              child: child!,
            ),
          );
        },
      ),
    );
  }
}

class _SafeSheetKeyboardLayoutDelegate extends SingleChildLayoutDelegate {
  const _SafeSheetKeyboardLayoutDelegate({
    required this.isDesktopDialog,
    required this.topMargin,
    required this.baseMargin,
    required this.horizontalMargin,
    required this.targetBottom,
    required this.liftY,
    required this.maxWidth,
    required this.maxHeight,
  });

  final bool isDesktopDialog;
  final double topMargin;
  final double baseMargin;
  final double horizontalMargin;
  final double targetBottom;
  final double liftY;
  final double maxWidth;
  final double maxHeight;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final availW = math.max(0.0, constraints.maxWidth - horizontalMargin * 2.0);
    final availH = math.max(88.0, constraints.maxHeight - topMargin - baseMargin);
    return BoxConstraints(
      maxWidth: math.min(availW, maxWidth),
      maxHeight: math.min(availH, maxHeight),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final dx = ((size.width - childSize.width) / 2.0)
        .clamp(horizontalMargin, math.max(horizontalMargin, size.width - horizontalMargin))
        .toDouble();
    final double dy;
    if (isDesktopDialog) {
      final centered = (size.height - childSize.height) / 2.0 - liftY * 0.5;
      final maxTop = math.max(topMargin, size.height - baseMargin - childSize.height);
      dy = centered.clamp(topMargin, maxTop).toDouble();
    } else {
      final desired = size.height - targetBottom - childSize.height;
      dy = math.max(topMargin, desired);
    }
    return Offset(dx, dy);
  }

  @override
  bool shouldRelayout(_SafeSheetKeyboardLayoutDelegate old) =>
      isDesktopDialog != old.isDesktopDialog ||
      topMargin != old.topMargin ||
      baseMargin != old.baseMargin ||
      horizontalMargin != old.horizontalMargin ||
      targetBottom != old.targetBottom ||
      liftY != old.liftY ||
      maxWidth != old.maxWidth ||
      maxHeight != old.maxHeight;
}

/// Concentric `16pt` carved crystal glass well nested inside a floating sheet/dialog (`32pt` - `16px`).
class _SheetSectionCard extends StatelessWidget {
  const _SheetSectionCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GrassBagSheetSection(
      padding: const EdgeInsets.symmetric(vertical: 3),
      showDividers: false,
      children: children,
    );
  }
}

void showWorkspaceSheet(
  BuildContext context,
  WidgetRef ref, {
  GlassMorphAnchor? morphFrom,
  bool forSidebarFilter = false,
}) {
  showGrassBagSheet(
    context,
    title: forSidebarFilter ? '按工作区筛选对话' : '选择工作区',
    subtitle: forSidebarFilter
        ? '筛选左侧历史对话列表，或切换到指定目录开启新对话'
        : '新对话将在所选目录下读写文件与执行命令',
    icon: CupertinoIcons.folder_fill,
    preferredHeight: 480,
    morphFrom: morphFrom,
    bodyBuilder: (ctx) => _WorkspacePickerSheetBody(
      hostContext: context,
      forSidebarFilter: forSidebarFilter,
    ),
  );
}

class _WorkspacePickerSheetBody extends ConsumerStatefulWidget {
  const _WorkspacePickerSheetBody({
    required this.hostContext,
    required this.forSidebarFilter,
  });

  final BuildContext hostContext;
  final bool forSidebarFilter;

  @override
  ConsumerState<_WorkspacePickerSheetBody> createState() => _WorkspacePickerSheetBodyState();
}

class _WorkspacePickerSheetBodyState extends ConsumerState<_WorkspacePickerSheetBody> {
  static final RegExp _homePrefixRe = RegExp(r'^/(?:Users|home)/[^/]+/');
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(
      appProvider.select(
        (s) => (
          workspaces: s.workspaces,
          sessions: s.sessions,
          sidebarWorkspaceFilter: s.sidebarWorkspaceFilter,
          activeWorkspace: s.activeWorkspace,
          connectionPhase: s.connectionPhase,
          activeHost: s.activeHost,
          activeHostNeedsAuth: s.activeHost.needsAuth,
          glassTier: s.glassTier,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final wsList = state.workspaces;
    final q = _query.trim().toLowerCase();
    final filteredWs = q.isEmpty
        ? wsList
        : wsList
            .where((w) =>
                w.name.toLowerCase().contains(q) ||
                w.path.toLowerCase().contains(q))
            .toList(growable: false);

    String normPath(String p) {
      var s = p.trim();
      while (s.length > 1 && (s.endsWith('/') || s.endsWith('\\'))) {
        s = s.substring(0, s.length - 1);
      }
      return s;
    }

    // Single O(S) pass for workspace session counts & ungrouped cwd count (replaces O(W × S)!)
    final wsByPath = {
      for (final w in wsList)
        if (w.explicit && w.path.isNotEmpty) normPath(w.path): w,
    };
    final countByWsId = <String, int>{};
    final countByWsName = <String, int>{};
    final countByCwd = <String, int>{};
    var ungroupedWithCwd = 0;
    var totalActiveSessions = 0;
    for (final s in state.sessions) {
      if (s.archived) continue;
      totalActiveSessions++;
      final wsId = s.workspaceId;
      final wsName = s.workspaceName;
      final cwd = s.cwd;
      final normCwd = (cwd != null && cwd.trim().isNotEmpty) ? normPath(cwd) : '';
      if (wsId != null && wsId.isNotEmpty) {
        countByWsId[wsId] = (countByWsId[wsId] ?? 0) + 1;
      } else if (normCwd.isNotEmpty && !wsByPath.containsKey(normCwd)) {
        ungroupedWithCwd++;
      }
      if (wsName != null && wsName.isNotEmpty) {
        countByWsName[wsName] = (countByWsName[wsName] ?? 0) + 1;
      }
      if (normCwd.isNotEmpty) {
        countByCwd[normCwd] = (countByCwd[normCwd] ?? 0) + 1;
      }
    }
    final activeKey = widget.forSidebarFilter
        ? (state.sidebarWorkspaceFilter ?? '')
        : state.activeWorkspace;
    final normActiveKey = activeKey.isNotEmpty ? normPath(activeKey) : '';
    final hasExactIdOrPathMatch = activeKey.isNotEmpty &&
        wsList.any((w) =>
            (w.id.isNotEmpty && w.id == activeKey) ||
            (w.path.isNotEmpty && normPath(w.path) == normActiveKey));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (wsList.length > 5) ...[
          GrassBagGlassSearchBar(
            controller: _searchCtrl,
            placeholder: '搜索 ${wsList.length} 个工作区名称或路径…',
            tier: state.glassTier,
            insideGlass: true,
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 10),
        ],
        if (widget.forSidebarFilter && q.isEmpty) ...[
          _SheetSectionCard(
            children: [
              _SheetOptionRow(
                icon: CupertinoIcons.square_stack_3d_down_right_fill,
                iconColor: t.primary,
                title: '全部工作区',
                badge: '$totalActiveSessions 条对话',
                subtitle: '在侧边栏展示所有目录与未归组历史对话',
                selected: state.sidebarWorkspaceFilter == null,
                onTap: () {
                  ctrl.setSidebarWorkspaceFilter(null);
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: wsList.length > 5 ? 200 : 0),
          child: wsList.isEmpty
              ? _SheetSectionCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            state.activeHostNeedsAuth
                                ? '当前主机「${state.activeHost.name}」需要先完成一次性授权，才能读取工作区目录。'
                                : (state.connectionPhase != ConnectionPhase.connected
                                    ? '尚未连接到 DSH 主机，连接就绪后即可同步并浏览工作区目录。'
                                    : '暂无已记录的工作区，点击下方「浏览与挂载新工作区目录」选择任意项目文件夹。'),
                            style: TextStyle(fontSize: 13, height: 1.45, color: t.text3),
                          ),
                          if (state.activeHostNeedsAuth) ...[
                            const SizedBox(height: 10),
                            GrassBagPrimaryGlassButton(
                              label: '立即授权',
                              icon: CupertinoIcons.lock_shield_fill,
                              height: 36,
                              tier: state.glassTier,
                              insideGlass: true,
                              onTap: () {
                                final hostCtx = widget.hostContext;
                                final host = state.activeHost;
                                Navigator.of(context).pop();
                                Future<void>.delayed(const Duration(milliseconds: 180), () {
                                  if (hostCtx.mounted) showRemoteHostAuthSheet(hostCtx, ref, host);
                                });
                              },
                            ),
                          ] else if (state.connectionPhase != ConnectionPhase.connected) ...[
                            const SizedBox(height: 10),
                            GrassBagSecondaryGlassButton(
                              label: '重试连接',
                              icon: CupertinoIcons.refresh,
                              height: 36,
                              tier: state.glassTier,
                              insideGlass: true,
                              accentForeground: true,
                              onTap: () => ctrl.probeAndRefreshHost(state.activeHost.id),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                )
              : filteredWs.isEmpty
                  ? _SheetSectionCard(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '未找到匹配「$_query」的工作区',
                                style: TextStyle(fontSize: 13, color: t.text3),
                              ),
                              const SizedBox(height: 10),
                              GrassBagSecondaryGlassButton(
                                label: '清除搜索',
                                icon: CupertinoIcons.clear_circled,
                                height: 34,
                                padding: const EdgeInsets.symmetric(horizontal: 14),
                                tier: state.glassTier,
                                insideGlass: true,
                                accentForeground: true,
                                onTap: () {
                                  _searchCtrl.clear();
                                  setState(() => _query = '');
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : _SheetSectionCard(
                      children: [
                        for (int i = 0; i < filteredWs.length; i++) ...[
                          () {
                            final w = filteredWs[i];
                            final normWPath = w.path.isNotEmpty ? normPath(w.path) : '';
                            final count = countByWsId[w.id] ??
                                (normWPath.isNotEmpty ? countByCwd[normWPath] : null) ??
                                countByWsName[w.name] ??
                                0;
                            final selected = activeKey.isNotEmpty &&
                                ((w.id.isNotEmpty && activeKey == w.id) ||
                                    (normWPath.isNotEmpty && normActiveKey == normWPath) ||
                                    (!hasExactIdOrPathMatch && activeKey == w.name));
                            final shortPath = w.path.replaceFirst(_homePrefixRe, '~/');
                            return _SheetOptionRow(
                              icon: w.isPhoneStorage
                                  ? CupertinoIcons.device_phone_portrait
                                  : (w.explicit ? CupertinoIcons.folder_fill : CupertinoIcons.folder),
                              iconColor: w.isPhoneStorage
                                  ? t.dusk
                                  : (w.explicit ? t.primary : t.text2),
                              title: w.name,
                              badge: count > 0
                                  ? '$count 条'
                                  : (w.explicit ? '已归组' : '目录'),
                              subtitle: shortPath,
                              monoSubtitle: true,
                              selected: selected,
                              trailingExtra: w.explicit
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Tooltip(
                                          message: '重命名工作区',
                                          child: Semantics(
                                            button: true,
                                            label: '重命名工作区 ${w.name}',
                                            child: GrassBagSpringTap(
                                              pressedScale: 0.88,
                                              enablePointerGlow: false,
                                              haptic: true,
                                              onTap: () => _openRenameWorkspaceSheet(context, w),
                                              child: SizedBox(
                                                width: 40,
                                                height: 40,
                                                child: Center(
                                                  child: Icon(CupertinoIcons.pencil, size: 15.5, color: t.text3),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Tooltip(
                                          message: '移除工作区',
                                          child: Semantics(
                                            button: true,
                                            label: '移除工作区 ${w.name}',
                                            child: GrassBagSpringTap(
                                              pressedScale: 0.88,
                                              enablePointerGlow: false,
                                              haptic: true,
                                              onTap: () async {
                                                final ok = await showGrassBagConfirmDialog(
                                                  context,
                                                  title: '移除工作区「${w.name}」？',
                                                  message: '仅从工作区列表中移除映射，不会删除磁盘目录或任何代码文件。',
                                                  confirmLabel: '移除',
                                                  isDestructive: true,
                                                );
                                                if (ok) await ctrl.deleteWorkspaceItem(w);
                                              },
                                              child: SizedBox(
                                                width: 40,
                                                height: 40,
                                                child: Center(
                                                  child: Icon(CupertinoIcons.trash, size: 15.5, color: t.err),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : null,
                              onTap: () {
                                final uniqueKey = w.id.isNotEmpty
                                    ? w.id
                                    : (w.path.isNotEmpty ? w.path : w.name);
                                if (widget.forSidebarFilter) {
                                  ctrl.setSidebarWorkspaceFilter(uniqueKey);
                                } else {
                                  ctrl.setWorkspace(uniqueKey);
                                }
                                Navigator.of(context).pop();
                              },
                            );
                          }(),
                          if (i < filteredWs.length - 1)
                            Divider(height: 0.5, indent: 60, endIndent: 14, color: t.sep),
                        ],
                      ],
                    ),
        ),
        if (ungroupedWithCwd > 0 && state.connectionPhase == ConnectionPhase.connected) ...[
          const SizedBox(height: 10),
          GrassBagSecondaryGlassButton(
            label: '将 $ungroupedWithCwd 条对话按文件夹归组为工作区',
            icon: CupertinoIcons.folder_badge_plus,
            tier: state.glassTier,
            insideGlass: true,
            onTap: () {
              Navigator.of(context).pop();
              ctrl.organizeWorkspacesByCwd();
            },
          ),
        ],
        const SizedBox(height: 10),
        GrassBagSecondaryGlassButton(
          label: '浏览与挂载新工作区目录',
          icon: CupertinoIcons.plus_circle,
          tier: state.glassTier,
          insideGlass: true,
          accentForeground: true,
          onTap: () {
            final hostCtx = widget.hostContext;
            Navigator.of(context).pop();
            // Defer chained sheet opening until the outgoing barrier fades cleanly.
            Future<void>.delayed(const Duration(milliseconds: 180), () {
              if (hostCtx.mounted) showWorkspaceDirectoryBrowserSheet(hostCtx);
            });
          },
        ),
      ],
    );
  }
}

void _openRenameWorkspaceSheet(BuildContext context, WorkspaceItem ws) {
  showGrassBagSheet<void>(
    context,
    title: '重命名工作区',
    subtitle: ws.path,
    bodyBuilder: (_) => _RenameWorkspaceSheetBody(ws: ws),
  );
}

class _RenameWorkspaceSheetBody extends ConsumerStatefulWidget {
  const _RenameWorkspaceSheetBody({required this.ws});
  final WorkspaceItem ws;

  @override
  ConsumerState<_RenameWorkspaceSheetBody> createState() => _RenameWorkspaceSheetBodyState();
}

class _RenameWorkspaceSheetBodyState extends ConsumerState<_RenameWorkspaceSheetBody> {
  late final TextEditingController _ctrl;
  String? _err;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.ws.name);
    if (_ctrl.text.isNotEmpty) {
      _ctrl.selection = TextSelection(baseOffset: 0, extentOffset: _ctrl.text.length);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final clean = _ctrl.text.trim();
    if (clean.isEmpty) {
      setState(() => _err = '工作区名称不能为空');
      return;
    }
    setState(() => _saving = true);
    try {
      final ok = await ref.read(appProvider.notifier).renameWorkspaceItem(widget.ws, clean);
      if (ok && mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
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
          controller: _ctrl,
          autofocus: true,
          placeholder: '输入新的工作区名称…',
          insideGlass: true,
          hasError: _err != null,
          suffix: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _ctrl,
            builder: (_, val, __) => val.text.isEmpty
                ? const SizedBox.shrink()
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _ctrl.clear();
                      if (_err != null) setState(() => _err = null);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(CupertinoIcons.xmark_circle_fill, size: 16, color: t.text3),
                    ),
                  ),
          ),
          onChanged: (_) {
            if (_err != null) setState(() => _err = null);
          },
          onSubmitted: (_) => _save(),
        ),
        if (_err != null) ...[
          const SizedBox(height: 6),
          Text(_err!, style: TextStyle(fontSize: 12, color: t.err)),
        ],
        const SizedBox(height: 12),
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
                label: _saving ? '保存中…' : '保存',
                tier: tier,
                insideGlass: true,
                enabled: !_saving,
                onTap: _saving ? null : _save,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Interactive native directory browser backed by `/gbridge/v1/fs/browse` (`ctrl.browseRemoteFs`)
/// with clickable path breadcrumbs, home/quick jumps, inline `mkdir`, and safe error display.
/// Owns its own [ConsumerState] `ref` & text controllers so popping an upstream sheet never
/// causes a disposed-ref crash.
void showWorkspaceDirectoryBrowserSheet(BuildContext context, [WidgetRef? unusedRef]) {
  showGrassBagSheet<void>(
    context,
    title: '浏览与挂载工作区',
    subtitle: '点击文件夹进入子目录，选好目标目录后点击「挂载当前目录」',
    bodyBuilder: (_) => const _WorkspaceDirectoryBrowserBody(),
  );
}

class _WorkspaceDirectoryBrowserBody extends ConsumerStatefulWidget {
  const _WorkspaceDirectoryBrowserBody();

  @override
  ConsumerState<_WorkspaceDirectoryBrowserBody> createState() =>
      _WorkspaceDirectoryBrowserBodyState();
}

class _WorkspaceDirectoryBrowserBodyState extends ConsumerState<_WorkspaceDirectoryBrowserBody> {
  late final TextEditingController _pathCtrl;
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _newFolderCtrl = TextEditingController();

  String _currentPath = '';
  String? _parentPath;
  String? _homePath;
  String? _browseError;
  bool _showNewFolderInput = false;
  bool _creatingFolder = false;
  String? _newFolderErr;
  List<Map<String, dynamic>> _entries = const [];
  bool _loading = true;
  bool _mounting = false;
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    final app = ref.read(appProvider);
    final rawInitial = app.activeWorkspaceItem?.path ?? '';
    final initialPath = rawInitial == '/root' && app.isActiveHostDesktop ? '' : rawInitial;
    _currentPath = initialPath;
    _pathCtrl = TextEditingController(text: initialPath);
    unawaited(_loadDir(_currentPath.isEmpty ? null : _currentPath));
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    _nameCtrl.dispose();
    _newFolderCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDir(String? dir) async {
    final seq = ++_loadSeq;
    if (mounted) {
      setState(() {
        _loading = true;
        _browseError = null;
      });
    }
    try {
      final res = await ref.read(appProvider.notifier).browseRemoteFs(path: dir);
      if (!mounted || seq != _loadSeq) return;
      final errStr = res['error']?.toString();
      final rawEnt = res['entries'];
      List<dynamic> rawList = const [];
      String? nestedPath;
      String? nestedParent;
      if (rawEnt is List) {
        rawList = rawEnt;
      } else if (rawEnt is Map) {
        nestedPath = rawEnt['path']?.toString();
        nestedParent = rawEnt['parent']?.toString();
        if (rawEnt['entries'] is List) rawList = rawEnt['entries'] as List<dynamic>;
      }
      final nextPath = res['path']?.toString().isNotEmpty == true
          ? res['path'].toString()
          : (nestedPath ?? dir ?? '~');
      final nextParent = res['parent']?.toString() ?? nestedParent;
      final nextHome = res['home']?.toString() ?? _homePath;
      final parsedEntries = rawList
          .whereType<Map<Object?, Object?>>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .where((m) => m['kind'] == 'directory' || m['isDir'] == true || m['type'] == 'directory')
          .toList(growable: false);
      setState(() {
        _currentPath = nextPath;
        _parentPath = nextParent;
        _homePath = nextHome;
        _browseError = (errStr != null && errStr.isNotEmpty) ? errStr : null;
        _entries = parsedEntries;
        _pathCtrl.text = nextPath;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _browseError = GrassBagController.formatReadableError(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final isWinPath = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(_currentPath) ||
        RegExp(r'^[A-Za-z]:$').hasMatch(_currentPath);
    final winSep = _currentPath.contains('\\') ? '\\' : '/';
    final segments = _currentPath
        .split(RegExp(r'[/\\]'))
        .where((s) => s.isNotEmpty)
        .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagTextField(
          controller: _pathCtrl,
          placeholder: '输入目录路径（支持 ~/projects）并按回车跳转',
          monospace: true,
          fontSize: 12.5,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9.5),
          insideGlass: true,
          onSubmitted: (v) => _loadDir(v.trim()),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '主目录 ~',
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tier: tier,
                insideGlass: true,
                accentForeground: true,
                onTap: () => _loadDir('~'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '新建',
                icon: CupertinoIcons.folder_badge_plus,
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tier: tier,
                insideGlass: true,
                accentForeground: true,
                enabled: !_loading && _browseError == null,
                onTap: (_loading || _browseError != null)
                    ? null
                    : () => setState(() {
                          _showNewFolderInput = !_showNewFolderInput;
                          _newFolderErr = null;
                        }),
              ),
            ),
          ],
        ),
        if (segments.isNotEmpty) ...[
          const SizedBox(height: 6),
          GrassBagFresnelGlassSurface(
            borderRadius: 11,
            innerWell: true,
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (!isWinPath && _currentPath.startsWith('/'))
                    GestureDetector(
                      onTap: () => _loadDir('/'),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Text(
                          '/',
                          style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: t.primary),
                        ),
                      ),
                    ),
                  for (var i = 0; i < segments.length; i++) ...[
                    if (i > 0)
                      Text(isWinPath ? ' \\ ' : ' / ', style: TextStyle(fontSize: 11, color: t.text3)),
                    GestureDetector(
                      onTap: () {
                        final String sub;
                        if (isWinPath) {
                          final joined = segments.take(i + 1).join(winSep);
                          sub = i == 0 ? '$joined$winSep' : joined;
                        } else if (segments.first == '~') {
                          sub = segments.take(i + 1).join('/');
                        } else {
                          sub = '/${segments.take(i + 1).join('/')}';
                        }
                        _loadDir(sub);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
                        child: Text(
                          segments[i],
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            fontWeight: i == segments.length - 1 ? FontWeight.w600 : FontWeight.w400,
                            color: i == segments.length - 1 ? t.text : t.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        if (_showNewFolderInput) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: GrassBagTextField(
                  controller: _newFolderCtrl,
                  autofocus: true,
                  placeholder: '输入新子文件夹名称…',
                  fontSize: 12.5,
                  hasError: _newFolderErr != null,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  insideGlass: true,
                  onChanged: (_) {
                    if (_newFolderErr != null) setState(() => _newFolderErr = null);
                  },
                ),
              ),
              const SizedBox(width: 8),
              GrassBagPrimaryGlassButton(
                label: _creatingFolder ? '创建中…' : '创建并进入',
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                tier: tier,
                insideGlass: true,
                enabled: !_creatingFolder,
                onTap: _creatingFolder
                    ? null
                    : () async {
                        final folderName = _newFolderCtrl.text.trim();
                        if (folderName.isEmpty) {
                          setState(() => _newFolderErr = '请输入文件夹名称');
                          return;
                        }
                        if (folderName == '.' ||
                            folderName == '..' ||
                            folderName.contains('/') ||
                            folderName.contains('\\')) {
                          setState(() => _newFolderErr = '文件夹名称不能包含路径分隔符或 ..');
                          return;
                        }
                        setState(() {
                          _creatingFolder = true;
                          _newFolderErr = null;
                        });
                        try {
                          final createdPath = await ref
                              .read(appProvider.notifier)
                              .createRemoteDirectory(_currentPath, folderName);
                          if (!mounted) return;
                          if (createdPath != null) {
                            _newFolderCtrl.clear();
                            setState(() => _showNewFolderInput = false);
                            await _loadDir(createdPath);
                          } else {
                            setState(() => _newFolderErr = '创建目录失败，请检查目录权限或名称是否已存在');
                          }
                        } finally {
                          if (mounted) setState(() => _creatingFolder = false);
                        }
                      },
              ),
            ],
          ),
          if (_newFolderErr != null) ...[
            const SizedBox(height: 5),
            Text(_newFolderErr!, style: TextStyle(fontSize: 11.5, color: t.err)),
          ],
        ],
        const SizedBox(height: 8),
        GrassBagTextField(
          controller: _nameCtrl,
          placeholder: '工作区显示名称（选填，默认取末级目录名）',
          fontSize: 13,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          insideGlass: true,
        ),
        const SizedBox(height: 10),
        if (_browseError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GrassBagFresnelGlassSurface(
              borderRadius: 12,
              innerWell: true,
              tintColor: t.errSoft,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(_browseError!, style: TextStyle(fontSize: 12, color: t.err)),
            ),
          ),
        GrassBagFresnelGlassSurface(
          borderRadius: 15,
          innerWell: true,
          height: 240,
          clipBehavior: Clip.antiAlias,
          child: _loading
              ? Center(child: GrassBagActivityIndicator(color: t.primary))
              : _browseError != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(CupertinoIcons.exclamationmark_circle, size: 22, color: t.err),
                            const SizedBox(height: 8),
                            Text(
                              '无法读取当前目录，请检查主机连接或路径权限后重试',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12.5, color: t.text2),
                            ),
                            const SizedBox(height: 10),
                            GrassBagSecondaryGlassButton(
                              label: '重新加载',
                              icon: CupertinoIcons.refresh,
                              height: 34,
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                              tier: tier,
                              insideGlass: true,
                              accentForeground: true,
                              onTap: () => _loadDir(_currentPath),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: (_parentPath != null ? 1 : 0) +
                          (_entries.isEmpty ? 1 : _entries.length),
                      itemBuilder: (_, idx) {
                        var cursor = idx;
                        if (_parentPath != null) {
                          if (cursor == 0) {
                            return GrassBagListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              leading: Icon(CupertinoIcons.arrow_turn_up_left, size: 15, color: t.primary),
                              title: Text('.. (返回上级目录)', style: TextStyle(fontSize: 13, color: t.primary)),
                              onTap: () => _loadDir(_parentPath),
                            );
                          }
                          cursor -= 1;
                        }
                        if (_entries.isEmpty) {
                          return Padding(
                            padding: const EdgeInsets.all(18),
                            child: Center(
                              child: Text(
                                '此目录下没有子文件夹，可直接点击下方「挂载当前目录」',
                                style: TextStyle(fontSize: 12.5, color: t.text3),
                              ),
                            ),
                          );
                        }
                        final e = _entries[cursor];
                        return GrassBagListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          leading: Icon(CupertinoIcons.folder_fill, size: 16, color: t.primary),
                          title: Text(
                            e['name']?.toString() ?? '',
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                          ),
                          showChevron: true,
                          onTap: () => _loadDir(e['path']?.toString()),
                        );
                      },
                    ),
        ),
        const SizedBox(height: 12),
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
                label: _mounting ? '挂载中…' : '挂载当前目录',
                tier: tier,
                insideGlass: true,
                enabled: !_loading && !_mounting && _browseError == null,
                onTap: (_loading || _mounting || _browseError != null)
                    ? null
                    : () async {
                        final rawPath =
                            _pathCtrl.text.trim().isEmpty ? _currentPath : _pathCtrl.text.trim();
                        final resolved = (rawPath == '~' && _homePath != null && _homePath!.isNotEmpty)
                            ? _homePath!
                            : rawPath;
                        setState(() => _mounting = true);
                        try {
                          final ok = await ref
                              .read(appProvider.notifier)
                              .addWorkspace(_nameCtrl.text, resolved);
                          if (ok && context.mounted) Navigator.of(context).pop();
                        } finally {
                          if (mounted) setState(() => _mounting = false);
                        }
                      },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

void showPresetSheet(BuildContext context, WidgetRef ref, {GlassMorphAnchor? morphFrom}) {
  showGrassBagSheet(
    context,
    title: '角色预设',
    subtitle: '决定助手的工作方式、思考粒度与回复风格',
    icon: CupertinoIcons.sparkles,
    preferredHeight: 382,
    morphFrom: morphFrom,
    bodyBuilder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final state = ref.watch(
          appProvider.select(
            (s) => (presets: s.presets, activePresetId: s.activePresetId),
          ),
        );
        final ctrl = ref.read(appProvider.notifier);
        final t = GrassBagTokens.of(ctx);
        final iconSpecs = [
          (CupertinoIcons.compass_fill, t.isDark ? const Color(0xFF63B4E4) : const Color(0xFF236185)),
          (CupertinoIcons.chevron_left_slash_chevron_right, t.isDark ? const Color(0xFF7FA3F2) : const Color(0xFF425EA8)),
          (CupertinoIcons.bolt_fill, t.isDark ? const Color(0xFF4AC885) : const Color(0xFF1F9D63)),
          (CupertinoIcons.person_crop_circle_fill, t.isDark ? const Color(0xFFA993DE) : const Color(0xFF6B5B8E)),
        ];
        final presets = state.presets;
        return _SheetSectionCard(
          children: [
            for (int i = 0; i < presets.length; i++) ...[
              _SheetOptionRow(
                icon: iconSpecs[i % iconSpecs.length].$1,
                iconColor: iconSpecs[i % iconSpecs.length].$2,
                title: presets[i].name,
                badge: presets[i].isDefault ? '默认' : null,
                subtitle: presets[i].desc,
                selected: state.activePresetId == presets[i].id,
                onTap: () {
                  ctrl.setPreset(presets[i].id);
                  Navigator.of(ctx).pop();
                },
              ),
              if (i < presets.length - 1)
                Divider(height: 0.5, indent: 60, endIndent: 14, color: t.sep),
            ],
          ],
        );
      },
    ),
  );
}

void showPermissionSheet(BuildContext context, WidgetRef ref, {GlassMorphAnchor? morphFrom}) {
  showGrassBagSheet(
    context,
    title: '操作权限',
    subtitle: '控制助手读写文件与执行终端命令的授权边界',
    icon: CupertinoIcons.shield_lefthalf_fill,
    preferredHeight: 392,
    morphFrom: morphFrom,
    bodyBuilder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final state = ref.watch(
          appProvider.select(
            (s) => (
              permissionTiers: s.permissionTiers,
              activePermissionId: s.activePermissionId,
            ),
          ),
        );
        final ctrl = ref.read(appProvider.notifier);
        final t = GrassBagTokens.of(ctx);
        (IconData, Color) resolvePermissionVisual(PermissionTier tier) {
          final id = tier.id.toLowerCase();
          if (id.contains('read') || id == 'plan') {
            return (
              CupertinoIcons.lock_shield_fill,
              t.isDark ? const Color(0xFF7FA3F2) : const Color(0xFF425EA8),
            );
          }
          if (id.contains('danger') ||
              id.contains('bypass') ||
              id == 'full-access' ||
              id == 'unrestricted' ||
              tier.risky) {
            return (
              CupertinoIcons.exclamationmark_shield_fill,
              t.isDark ? const Color(0xFFEA8F5C) : const Color(0xFFC2571A),
            );
          }
          if (id.contains('auto') || id.contains('full')) {
            return (
              CupertinoIcons.bolt_circle_fill,
              t.isDark ? const Color(0xFFF0B24C) : const Color(0xFFB86C11),
            );
          }
          return (
            CupertinoIcons.checkmark_shield_fill,
            t.isDark ? const Color(0xFF4AC885) : const Color(0xFF1F9D63),
          );
        }

        final permTiers = state.permissionTiers.isNotEmpty
            ? state.permissionTiers
            : ref.read(appProvider).effectivePermissionTiers;
        return _SheetSectionCard(
          children: [
            for (int i = 0; i < permTiers.length; i++) ...[
              () {
                final visual = resolvePermissionVisual(permTiers[i]);
                return _SheetOptionRow(
                  icon: visual.$1,
                  iconColor: visual.$2,
                  title: permTiers[i].name,
                  badge: permTiers[i].isDefault
                      ? '默认'
                      : (permTiers[i].risky ? '高权限' : null),
                  subtitle: permTiers[i].desc,
                  selected: state.activePermissionId == permTiers[i].id,
                  warnTone: permTiers[i].risky,
                  onTap: () {
                    ctrl.setPermission(permTiers[i].id);
                    Navigator.of(ctx).pop();
                  },
                );
              }(),
              if (i < permTiers.length - 1)
                Divider(height: 0.5, indent: 60, endIndent: 14, color: t.sep),
            ],
          ],
        );
      },
    ),
  );
}

void showModelSheet(
  BuildContext context,
  WidgetRef ref, {
  GlassMorphAnchor? morphFrom,
  VoidCallback? onOpenModelSettings,
  VoidCallback? onAfterModelSelected,
  String? sheetTitle,
}) {
  const effortHints = {
    '自动': '按问题难度自动调节思考深度',
    '极速': '极简思考 · 超快首字响应',
    '关闭': '关闭长思考 · 最快直出',
    '低': '快速直出 · 低延迟',
    '中': '均衡思考 · 日常推荐',
    '高': '深度多步 · 复杂工程',
    '超高': '强推理深度 · 复杂排查',
    '极高': '最高推理预算 · 极限质量',
  };

  showGrassBagSheet(
    context,
    title: sheetTitle ?? '模型与思考深度',
    subtitle: onAfterModelSelected != null
        ? '选择新的可用模型后将立即重新生成该轮回复'
        : '支持关键词筛选与渠道折叠，选择后同步写入默认模型与当前会话',
    icon: CupertinoIcons.cube_box_fill,
    preferredHeight: 540,
    morphFrom: morphFrom,
    bodyBuilder: (ctx) => _SearchableModelSheetBody(
      outerContext: context,
      effortHints: effortHints,
      onOpenModelSettings: onOpenModelSettings,
      onAfterModelSelected: onAfterModelSelected,
    ),
  );
}

class _SearchableModelSheetBody extends ConsumerStatefulWidget {
  const _SearchableModelSheetBody({
    required this.outerContext,
    required this.effortHints,
    this.onOpenModelSettings,
    this.onAfterModelSelected,
  });
  final BuildContext outerContext;
  final Map<String, String> effortHints;
  final VoidCallback? onOpenModelSettings;
  final VoidCallback? onAfterModelSelected;

  @override
  ConsumerState<_SearchableModelSheetBody> createState() => _SearchableModelSheetBodyState();
}

class _SearchableModelSheetBodyState extends ConsumerState<_SearchableModelSheetBody> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  final Set<String> _expandedGroups = <String>{};
  bool _initialized = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(
      appProvider.select(
        (s) => (
          modelGroups: s.modelGroups,
          routableProvidersCount: s.routableProviders.length,
          activeModelProvider: s.activeModelProvider,
          activeModelId: s.activeModelId,
          modelName: s.modelName,
          modelShort: s.modelShort,
          modelEffort: s.modelEffort,
          modelEffortId: s.modelEffortId,
          glassTier: s.glassTier,
          connectionPhase: s.connectionPhase,
          activeHost: s.activeHost,
          activeHostNeedsAuth: s.activeHost.needsAuth,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final groups = state.modelGroups;

    if (!_initialized && groups.isNotEmpty) {
      _initialized = true;
      for (final g in groups) {
        if ((g.routable && g.models.length <= 6) ||
            g.id == state.activeModelProvider ||
            g.models.any((m) => m.id == state.activeModelId)) {
          _expandedGroups.add(g.id);
        }
      }
    }

    final totalModels = groups.fold<int>(0, (acc, g) => acc + g.models.length);
    ModelCatalogEntry? activeEntry;
    if (state.activeModelId.isNotEmpty) {
      for (final g in groups) {
        if (state.activeModelProvider.isNotEmpty && g.id != state.activeModelProvider) continue;
        for (final m in g.models) {
          if (m.id == state.activeModelId) {
            activeEntry = m;
            break;
          }
        }
        if (activeEntry != null) break;
      }
      if (activeEntry == null && state.activeModelProvider.isNotEmpty) {
        for (final g in groups) {
          for (final m in g.models) {
            if (m.id == state.activeModelId) {
              activeEntry = m;
              break;
            }
          }
          if (activeEntry != null) break;
        }
      }
    }
    // Non-empty model list must never leave selector empty; only empty model list may be empty.
    if (activeEntry == null && totalModels > 0) {
      final fallbackGroup =
          groups.where((g) => g.routable && g.models.isNotEmpty).firstOrNull ??
              groups.where((g) => g.models.isNotEmpty).firstOrNull;
      activeEntry = fallbackGroup?.models.first;
    }
    final effectiveModelId = activeEntry?.id ?? '';
    final effectiveProviderId = activeEntry?.providerId ?? '';
    final effectiveModelName = activeEntry?.name ?? state.modelName;
    final effectiveModelShort = activeEntry?.shortLabel ?? state.modelShort;
    final hasActiveModel = activeEntry != null;
    final supportsReasoning = activeEntry != null && activeEntry.efforts.isNotEmpty;
    final effortOpts = supportsReasoning ? activeEntry.efforts : const <ModelEffortOption>[];
    final curEffortIdx = effortOpts.isEmpty
        ? 0
        : effortOpts
            .indexWhere(
              (e) =>
                  e.id == state.modelEffortId ||
                  e.zhLabel == state.modelEffort ||
                  (state.modelEffortId.isEmpty && e.id == activeEntry!.defaultEffort),
            )
            .clamp(0, effortOpts.length - 1);
    final hint = effortOpts.isNotEmpty
        ? (widget.effortHints[effortOpts[curEffortIdx].zhLabel] ?? '')
        : '';

    final q = _query.trim().toLowerCase();
    final filteredGroups = <({ModelCatalogGroup group, List<ModelCatalogEntry> models})>[];
    for (final g in groups) {
      final matched = q.isEmpty
          ? g.models
          : g.models
              .where((m) =>
                  m.name.toLowerCase().contains(q) ||
                  m.id.toLowerCase().contains(q) ||
                  m.description.toLowerCase().contains(q) ||
                  g.name.toLowerCase().contains(q))
              .toList(growable: false);
      if (matched.isNotEmpty) {
        filteredGroups.add((group: g, models: matched));
      }
    }
    filteredGroups.sort((a, b) {
      if (a.group.routable != b.group.routable) {
        return a.group.routable ? -1 : 1;
      }
      return 0;
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1. Top Thinking Depth Selector — ONLY shown when active model supports reasoning efforts!
        if (hasActiveModel && supportsReasoning) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '思考深度',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text2),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: 11.5, color: t.text3),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          GrassBagSegmentedControl(
            labels: [for (final e in effortOpts) e.zhLabel],
            selectedIndex: curEffortIdx,
            tier: state.glassTier,
            height: 38,
            onSelected: (idx) {
              if (effectiveModelId.isEmpty) return;
              final picked = effortOpts[idx];
              ctrl.setModel(
                effectiveModelName,
                effectiveModelShort,
                provider: effectiveProviderId,
                modelId: effectiveModelId,
                effort: picked.zhLabel,
                effortId: picked.id,
                silent: true,
              );
            },
          ),
          const SizedBox(height: 12),
        ] else if (hasActiveModel) ...[
          GrassBagFresnelGlassSurface(
            borderRadius: 13,
            innerWell: true,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            child: Row(
              children: [
                Icon(CupertinoIcons.info_circle, size: 13.5, color: t.text3),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '当前模型「$effectiveModelName」为标准推理模式，不支持调节思考深度',
                    style: TextStyle(fontSize: 11.5, color: t.text3),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],

        // 1.5 Direct setup banner when connected with catalog entries but zero routable providers
        if (groups.isNotEmpty &&
            state.routableProvidersCount == 0 &&
            state.connectionPhase == ConnectionPhase.connected) ...[
          GrassBagStatusBanner(
            tone: GrassBagBannerTone.warn,
            icon: CupertinoIcons.sparkles,
            title: '当前尚未配置可用模型密钥',
            message: '一键登录 DeepSeek 账号，或前往模型渠道填好 API Key 后即可立即对话。',
            padding: const EdgeInsets.all(11),
            borderRadius: 14,
            action: Row(
              children: [
                Expanded(
                  child: GrassBagPrimaryGlassButton(
                    label: '登录 DeepSeek',
                    icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                    height: 34,
                    tier: state.glassTier,
                    insideGlass: true,
                    onTap: () {
                      final outer = widget.outerContext;
                      Navigator.of(context).pop();
                      Future<void>.delayed(const Duration(milliseconds: 160), () {
                        if (outer.mounted) launchDeepSeekSignInFlow(outer, ref);
                      });
                    },
                  ),
                ),
                if (widget.onOpenModelSettings != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: GrassBagSecondaryGlassButton(
                      label: '配置 API Key',
                      icon: CupertinoIcons.slider_horizontal_3,
                      height: 34,
                      tier: state.glassTier,
                      insideGlass: true,
                      accentForeground: true,
                      onTap: () {
                        Navigator.of(context).pop();
                        widget.onOpenModelSettings!.call();
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],

        // 2. Live Search Bar when catalog has multiple models
        if (totalModels > 6) ...[
          GrassBagGlassSearchBar(
            controller: _searchCtrl,
            placeholder: '搜索 $totalModels 个可用模型或渠道…',
            tier: state.glassTier,
            insideGlass: true,
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 12),
        ],

        // 3. Collapsible Provider Groups (fixed minHeight when searchable prevents sheet bounce while filtering!)
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: totalModels > 6 ? 240 : 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
        if (groups.isEmpty)
          _SheetSectionCard(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      state.activeHostNeedsAuth
                          ? '当前主机「${state.activeHost.name}」需要先完成一次性授权，才能同步可用模型列表。'
                          : (state.connectionPhase == ConnectionPhase.connected
                              ? '当前主机尚未登录 DeepSeek 账号或配置模型渠道 API Key。完成以下任一方式后将立即加载可用模型：'
                              : '正在从 DSH 主机加载模型目录，请确认已连接到运行中的 DSH。'),
                      style: TextStyle(fontSize: 13, height: 1.45, color: t.text2),
                    ),
                    const SizedBox(height: 12),
                    if (state.activeHostNeedsAuth)
                      GrassBagPrimaryGlassButton(
                        label: '完成主机授权',
                        icon: CupertinoIcons.lock_shield_fill,
                        height: 38,
                        tier: state.glassTier,
                        insideGlass: true,
                        onTap: () {
                          final outer = widget.outerContext;
                          final host = state.activeHost;
                          Navigator.of(context).pop();
                          Future<void>.delayed(const Duration(milliseconds: 180), () {
                            if (outer.mounted) showRemoteHostAuthSheet(outer, ref, host);
                          });
                        },
                      )
                    else if (state.connectionPhase != ConnectionPhase.connected)
                      GrassBagSecondaryGlassButton(
                        label: '重试连接',
                        icon: CupertinoIcons.refresh,
                        height: 38,
                        tier: state.glassTier,
                        insideGlass: true,
                        accentForeground: true,
                        onTap: () => ctrl.probeAndRefreshHost(state.activeHost.id),
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: GrassBagPrimaryGlassButton(
                              label: '登录 DeepSeek',
                              icon: CupertinoIcons.sparkles,
                              height: 38,
                              tier: state.glassTier,
                              insideGlass: true,
                              onTap: () {
                                final outer = widget.outerContext;
                                Navigator.of(context).pop();
                                Future<void>.delayed(const Duration(milliseconds: 160), () {
                                  if (outer.mounted) launchDeepSeekSignInFlow(outer, ref);
                                });
                              },
                            ),
                          ),
                          if (widget.onOpenModelSettings != null) ...[
                            const SizedBox(width: 8),
                            Expanded(
                              child: GrassBagSecondaryGlassButton(
                                label: '管理模型渠道',
                                icon: CupertinoIcons.slider_horizontal_3,
                                height: 38,
                                tier: state.glassTier,
                                insideGlass: true,
                                accentForeground: true,
                                onTap: () {
                                  Navigator.of(context).pop();
                                  widget.onOpenModelSettings!.call();
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            ],
          )
        else if (filteredGroups.isEmpty)
          _SheetSectionCard(
            children: [
              Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '未找到匹配「$_query」的模型',
                      style: TextStyle(fontSize: 13, color: t.text3),
                    ),
                    const SizedBox(height: 10),
                    GrassBagSecondaryGlassButton(
                      label: '清除搜索',
                      icon: CupertinoIcons.clear_circled,
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      tier: state.glassTier,
                      insideGlass: true,
                      accentForeground: true,
                      onTap: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    ),
                  ],
                ),
              ),
            ],
          )
        else
          for (int gIdx = 0; gIdx < filteredGroups.length; gIdx++) ...[
            () {
              final entry = filteredGroups[gIdx];
              final g = entry.group;
              final list = entry.models;
              final isExpanded = q.isNotEmpty || _expandedGroups.contains(g.id);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  GrassBagSpringTap(
                    pressedScale: 0.985,
                    enablePointerGlow: false,
                    haptic: true,
                    onTap: () => setState(() {
                      if (!_expandedGroups.add(g.id)) _expandedGroups.remove(g.id);
                    }),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(4, gIdx == 0 ? 0 : 12, 4, 6),
                      child: Row(
                        children: [
                          AnimatedRotation(
                            turns: isExpanded ? 0.25 : 0.0,
                            duration: GrassBagMotion.duration(
                              context,
                              const Duration(milliseconds: 210),
                            ),
                            curve: Curves.easeOutCubic,
                            child: Icon(
                              CupertinoIcons.chevron_right,
                              size: 12,
                              color: t.text3,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              '${g.name} (${list.length})',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: t.text2,
                              ),
                            ),
                          ),
                          AnimatedOpacity(
                            opacity: isExpanded ? 0.0 : 1.0,
                            duration: GrassBagMotion.duration(
                              context,
                              const Duration(milliseconds: 160),
                            ),
                            child: Text(
                              '点击展开',
                              style: TextStyle(fontSize: 11, color: t.text3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  GrassBagSmoothDisclosure(
                    expanded: isExpanded,
                    child: _SheetSectionCard(
                      children: [
                        for (int i = 0; i < list.length; i++) ...[
                          () {
                            final m = list[i];
                            final selected = effectiveModelId == m.id &&
                                (effectiveProviderId.isEmpty ||
                                    effectiveProviderId == g.id);
                            return _SheetOptionRow(
                              icon: g.id == 'deepseek-official'
                                  ? CupertinoIcons.sparkles
                                  : CupertinoIcons.cube_box_fill,
                              iconColor: g.id == 'deepseek-official'
                                  ? t.primary
                                  : (t.isDark ? const Color(0xFF7FA3F2) : const Color(0xFF425EA8)),
                              title: m.name,
                              badge: !g.routable
                                  ? '需配置密钥'
                                  : (m.efforts.isNotEmpty ? '可调思考' : null),
                              subtitle: m.description.isNotEmpty ? m.description : m.id,
                              monoSubtitle: m.description.isEmpty,
                              selected: selected,
                              onTap: () {
                                if (!g.routable) {
                                  Navigator.of(context).pop();
                                  if (g.id == 'deepseek-account') {
                                    launchDeepSeekSignInFlow(widget.outerContext, ref);
                                  } else if (widget.onOpenModelSettings != null) {
                                    widget.onOpenModelSettings!();
                                  } else {
                                    ctrl.showToast('请先在「设置 → 模型与渠道」配置 ${g.name} 密钥', tone: ToastTone.warn);
                                  }
                                  return;
                                }
                                final afterSelected = widget.onAfterModelSelected;
                                final setFuture = ctrl.setModel(
                                  m.name,
                                  m.shortLabel,
                                  provider: g.id,
                                  modelId: m.id,
                                  effortId: m.efforts.any((e) => e.id == state.modelEffortId)
                                      ? state.modelEffortId
                                      : m.defaultEffort,
                                );
                                Navigator.of(context).pop();
                                if (afterSelected != null) {
                                  unawaited(setFuture.then((_) => afterSelected()));
                                }
                              },
                            );
                          }(),
                          if (i < list.length - 1)
                            Divider(height: 0.5, indent: 60, endIndent: 14, color: t.sep),
                        ],
                      ],
                    ),
                  ),
                  ],
                );
              }(),
            ],
            ],
          ),
        ),
        if (groups.isNotEmpty && widget.onOpenModelSettings != null) ...[
          const SizedBox(height: 12),
          GrassBagSecondaryGlassButton(
            label: '管理模型渠道与 API Key',
            icon: CupertinoIcons.slider_horizontal_3,
            tier: state.glassTier,
            insideGlass: true,
            accentForeground: true,
            onTap: () {
              Navigator.of(context).pop();
              widget.onOpenModelSettings!.call();
            },
          ),
        ],
      ],
    );
  }
}

void showContextSheet(BuildContext context, WidgetRef ref, {GlassMorphAnchor? morphFrom}) {
  showGrassBagSheet(
    context,
    title: '上下文与会话用量',
    subtitle: '实时统计当前对话的上下文构成、Prompt 缓存命中与生成速率',
    icon: CupertinoIcons.gauge,
    morphFrom: morphFrom,
    bodyBuilder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final state = ref.watch(
          appProvider.select(
            (s) => (
              sessionTelemetry: s.sessionTelemetry,
              contextPct: s.contextPct,
              contextUsedK: s.contextUsedK,
              contextMaxK: s.contextMaxK,
              isCompactingContext: s.isCompactingContext,
              glassTier: s.glassTier,
            ),
          ),
        );
        final ctrl = ref.read(appProvider.notifier);
        final t = GrassBagTokens.of(ctx);
        final tel = state.sessionTelemetry;
        final ctxColor = state.contextPct >= 85
            ? t.err
            : (state.contextPct >= 65 ? t.warn : t.ok);
        final ctxStatusLabel = state.contextPct >= 85
            ? '接近上限'
            : (state.contextPct >= 65 ? '占用偏高' : '状态充裕');
        final hitRate = tel.cacheHitRate;
        final tps = tel.effectiveTps;
        final avgTtft = tel.avgTtftMs;
        final win = tel.contextWindow;
        final hasBreakdown =
            win > 0 && (tel.systemTokens + tel.toolsTokens + tel.messageTokens) > 0;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetSectionCard(
              children: [
                Padding(
                  padding: const EdgeInsets.all(15),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            '${state.contextPct}%',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.8,
                              fontFeatures: const [FontFeature.tabularFigures()],
                              color: state.contextPct >= 85
                                  ? t.err
                                  : state.contextPct >= 65
                                      ? t.warn
                                      : t.text,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '已用 ${state.contextUsedK}k / ${state.contextMaxK}k',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontFeatures: const [FontFeature.tabularFigures()],
                                color: t.text3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          GrassBagFresnelGlassSurface(
                            isPill: true,
                            innerWell: true,
                            tintColor: ctxColor.withValues(alpha: t.isDark ? 0.20 : 0.14),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            child: Text(
                              ctxStatusLabel,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: ctxColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Stacked breakdown bar when DSH reports contextBreakdown, else smooth crystal bar
                      hasBreakdown
                          ? Container(
                              height: 10,
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
                                      if (tel.systemTokens > 0)
                                        Expanded(
                                          flex: tel.systemTokens.clamp(1, win),
                                          child: Container(color: t.dusk),
                                        ),
                                      if (tel.toolsTokens > 0)
                                        Expanded(
                                          flex: tel.toolsTokens.clamp(1, win),
                                          child: Container(color: t.ok),
                                        ),
                                      if (tel.messageTokens > 0)
                                        Expanded(
                                          flex: tel.messageTokens.clamp(1, win),
                                          child: Container(color: t.primary),
                                        ),
                                      if (tel.otherContextTokens > 0)
                                        Expanded(
                                          flex: tel.otherContextTokens.clamp(1, win),
                                          child: Container(color: t.text3.withValues(alpha: 0.45)),
                                        ),
                                      if (tel.remainingContextTokens > 0)
                                        Expanded(
                                          flex: tel.remainingContextTokens,
                                          child: const SizedBox.shrink(),
                                        ),
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
                            )
                          : GrassBagProgressBar(
                              value: (state.contextPct / 100.0).clamp(0.02, 1.0),
                              height: 10,
                              color: state.contextPct >= 85
                                  ? t.err
                                  : (state.contextPct >= 65 ? t.warn : t.primary),
                            ),
                      const SizedBox(height: 12),
                      if (hasBreakdown) ...[
                        LayoutBuilder(
                          builder: (ctx, box) {
                            final cellW = (box.maxWidth - 10) / 2;
                            final items = [
                              _LegendDot(
                                color: t.dusk,
                                label: '系统提示',
                                value: formatCompactTokens(tel.systemTokens),
                              ),
                              _LegendDot(
                                color: t.ok,
                                label: '工具定义',
                                value: formatCompactTokens(tel.toolsTokens),
                              ),
                              _LegendDot(
                                color: t.primary,
                                label: '对话消息',
                                value: formatCompactTokens(tel.messageTokens),
                              ),
                              if (tel.remainingContextTokens > 0)
                                _LegendDot(
                                  color: t.text3.withValues(alpha: 0.45),
                                  label: '剩余可用',
                                  value: formatCompactTokens(tel.remainingContextTokens),
                                ),
                            ];
                            return Wrap(
                              spacing: 10,
                              runSpacing: 9,
                              children: [
                                for (final item in items) SizedBox(width: cellW, child: item),
                              ],
                            );
                          },
                        ),
                      ] else
                        Row(
                          children: [
                            Expanded(
                              child: _LegendDot(
                                color: t.primary,
                                label: '已用 Token',
                                value: '${state.contextUsedK}k',
                              ),
                            ),
                            Expanded(
                              child: _LegendDot(
                                color: t.ok,
                                label: '窗口上限',
                                value: '${state.contextMaxK}k',
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (tel.hasAnyData) ...[
              const SizedBox(height: 10),
              _SheetSectionCard(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: LayoutBuilder(
                      builder: (ctx, box) {
                        final cols = box.maxWidth < 310 ? 2 : 3;
                        final cellW = (box.maxWidth - (cols - 1) * 10) / cols;
                        final metrics = [
                          _LegendDot(
                            color: t.primary,
                            label: '解码速度',
                            value: tps != null ? '${tps.toStringAsFixed(1)} t/s' : '--',
                          ),
                          _LegendDot(
                            color: t.dusk,
                            label: '平均首字',
                            value: avgTtft != null ? formatDurationMs(avgTtft) : '--',
                          ),
                          _LegendDot(
                            color: t.ok,
                            label: '缓存命中',
                            value: hitRate != null
                                ? '${(hitRate * 100).toStringAsFixed(1)}%'
                                : '--',
                          ),
                          _LegendDot(
                            color: t.ok,
                            label: '缓存读取',
                            value: formatCompactTokens(tel.cacheReadTokens),
                          ),
                          _LegendDot(
                            color: t.primary,
                            label: '新输入',
                            value: formatCompactTokens(tel.uncachedInputTokens),
                          ),
                          _LegendDot(
                            color: t.warn,
                            label: '模型输出',
                            value: formatCompactTokens(tel.outputTokens),
                          ),
                        ];
                        return Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            for (final m in metrics) SizedBox(width: cellW, child: m),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '精简上下文会将早期历史压缩为摘要以释放额度，不会中断当前任务',
                style: TextStyle(fontSize: 11.5, color: t.text3),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: GrassBagPrimaryGlassButton(
                    label: state.isCompactingContext ? '正在精简上下文…' : '精简上下文',
                    icon: state.isCompactingContext ? null : CupertinoIcons.wand_stars,
                    tier: state.glassTier,
                    insideGlass: true,
                    enabled: !state.isCompactingContext,
                    onTap: () => unawaited(ctrl.compactContext()),
                  ),
                ),
                const SizedBox(width: 10),
                GrassBagSecondaryGlassButton(
                  label: '新对话',
                  icon: CupertinoIcons.square_pencil,
                  tier: state.glassTier,
                  insideGlass: true,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    ctrl.startNewChat();
                  },
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}

void showHostQuickSheet(
  BuildContext context,
  WidgetRef ref, {
  VoidCallback? onOpenHostSettings,
  VoidCallback? onConnected,
}) {
  final outerCtx = context;
  showGrassBagSheet(
    context,
    title: '切换主机',
    subtitle: '选择用于对话与执行的本机或远程主机',
    icon: CupertinoIcons.desktopcomputer,
    preferredHeight: 380,
    bodyBuilder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final state = ref.watch(
          appProvider.select(
            (s) => (
              hosts: s.hosts,
              activeHostId: s.activeHostId,
              connectionPhase: s.connectionPhase,
              glassTier: s.glassTier,
              nativeRuntimeStatus: s.nativeRuntimeStatus,
              runtimeProgressPct: s.runtimeProgressPct,
            ),
          ),
        );
        final fullState = ref.read(appProvider);
        final ctrl = ref.read(appProvider.notifier);
        final t = GrassBagTokens.of(ctx);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetSectionCard(
              children: [
                for (int i = 0; i < state.hosts.length; i++) ...[
                  Builder(
                    builder: (_) {
                      final h = state.hosts[i];
                      final healthy = fullState.hostIsHealthy(h);
                      final hasErr = fullState.hostHasError(h);
                      final needsAuth = h.needsAuth;
                      return _SheetOptionRow(
                        icon: h.isLocal
                            ? CupertinoIcons.device_phone_portrait
                            : (needsAuth
                                ? CupertinoIcons.lock_shield_fill
                                : CupertinoIcons.desktopcomputer),
                        iconColor: h.isLocal
                            ? (healthy ? t.ok : (hasErr ? t.err : t.primary))
                            : (healthy
                                ? t.ok
                                : (needsAuth || fullState.hostIsConnecting(h)
                                    ? t.primary
                                    : (hasErr ? t.err : t.text3))),
                        title: h.name,
                        badge: fullState.hostStatusBadge(h),
                        subtitle: h.isLocal
                            ? fullState.hostStatusLabel(h)
                            : (needsAuth
                                ? '已连通 · 点击完成一次授权（30 天免填）'
                                : '${h.address} · ${h.latency}'),
                        monoSubtitle: !h.isLocal && !needsAuth,
                        selected: h.id == state.activeHostId,
                        warnTone: hasErr,
                        onTap: () {
                          final isSameHost = h.id == state.activeHostId;
                          if (needsAuth) {
                            if (!isSameHost) {
                              ctrl.switchHost(h.id);
                            }
                            Navigator.of(ctx).pop();
                            Future<void>.delayed(const Duration(milliseconds: 180), () {
                              if (outerCtx.mounted) {
                                showRemoteHostAuthSheet(outerCtx, ref, h);
                              }
                            });
                            return;
                          }
                          if (isSameHost && state.connectionPhase == ConnectionPhase.connected) {
                            unawaited(ctrl.refreshSessionsList(silent: true));
                          } else {
                            ctrl.switchHost(h.id);
                          }
                          Navigator.of(ctx).pop();
                        },
                      );
                    },
                  ),
                  if (i < state.hosts.length - 1)
                    Divider(height: 0.5, indent: 60, endIndent: 14, color: t.sep),
                ],
              ],
            ),
            if (state.hosts.length <= 1) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '可免插件直连局域网 Mac / PC 上的 DeepSeek Harness 桌面端或 dsh web',
                  style: TextStyle(fontSize: 11.5, color: t.text3),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                if (!kIsWeb &&
                    (defaultTargetPlatform == TargetPlatform.android ||
                        defaultTargetPlatform == TargetPlatform.iOS ||
                        defaultTargetPlatform == TargetPlatform.macOS)) ...[
                  Expanded(
                    child: GrassBagPrimaryGlassButton(
                      label: '扫码连接',
                      icon: CupertinoIcons.qrcode_viewfinder,
                      tier: state.glassTier,
                      insideGlass: true,
                      onTap: () async {
                        Navigator.of(ctx).pop();
                        await Future<void>.delayed(const Duration(milliseconds: 140));
                        if (!outerCtx.mounted) return;
                        final raw = await Navigator.of(outerCtx).push<String>(
                          GrassBagPageRoute<String>(
                            builder: (_) => const QrPairScannerPage(),
                          ),
                        );
                        if (!outerCtx.mounted || raw == null || raw.trim().isEmpty) return;
                        final parsed = parseRemoteHostInput(raw.trim());
                        if (parsed == null) {
                          ctrl.showToast('未识别到有效的 GrassBag 配对链接', tone: ToastTone.warn);
                          return;
                        }
                        ctrl.showToast('已扫码识别「${parsed.suggestedName ?? parsed.address}」，正在接入…',
                            tone: ToastTone.info);
                        final outcome = await ctrl.connectRemoteInput(
                          raw.trim(),
                          name: parsed.suggestedName,
                        );
                        if (!outerCtx.mounted) return;
                        if (outcome.connected) {
                          onConnected?.call();
                        } else {
                          showQuickRemoteConnectSheet(
                            outerCtx,
                            initialInput: raw.trim(),
                            initialDiagnosis: outcome.diagnosis,
                            onConnected: onConnected,
                          );
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: GrassBagSecondaryGlassButton(
                    label: '手动 / 发现',
                    icon: CupertinoIcons.plus_circle_fill,
                    tier: state.glassTier,
                    insideGlass: true,
                    accentForeground: true,
                    onTap: () {
                      Navigator.of(ctx).pop();
                      Future<void>.delayed(const Duration(milliseconds: 160), () {
                        if (outerCtx.mounted) {
                          showQuickRemoteConnectSheet(
                            outerCtx,
                            onConnected: onConnected,
                          );
                        }
                      });
                    },
                  ),
                ),
              ],
            ),
            if (onOpenHostSettings != null) ...[
              const SizedBox(height: 10),
              GrassBagSpringTap(
                enablePointerGlow: false,
                haptic: true,
                onTap: () {
                  Navigator.of(ctx).pop();
                  onOpenHostSettings();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(CupertinoIcons.slider_horizontal_3, size: 13.5, color: t.primary),
                      const SizedBox(width: 5),
                      Text(
                        '管理全部主机与详情',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: t.primary,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(CupertinoIcons.chevron_right, size: 12, color: t.primary.withValues(alpha: 0.72)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    ),
  );
}

/// Direct 1-tap remote device connection sheet launchable straight from the Chat host pill.
void showQuickRemoteConnectSheet(
  BuildContext context, {
  String? initialInput,
  RemoteHostDiagnosis? initialDiagnosis,
  VoidCallback? onConnected,
}) {
  showGrassBagSheet<void>(
    context,
    title: '连接远程电脑 / 服务器',
    subtitle: '自动扫描同局域网设备，或直接粘贴 dsh web 启动链接',
    icon: CupertinoIcons.wifi,
    preferredHeight: 560,
    bodyBuilder: (sheetCtx) => RemoteHostConnectCard(
      showHeader: false,
      embeddedInSheet: true,
      connectImmediately: true,
      initiallyShowGuide: false,
      initialInput: initialInput,
      initialDiagnosis: initialDiagnosis,
      onConnectedHost: (_) {
        if (sheetCtx.mounted) {
          Navigator.of(sheetCtx).pop();
        }
        onConnected?.call();
      },
    ),
  );
}

/// Guided one-time authorization sheet for remote DSH hosts (missing token / expired cookie).
/// Replaces red error dialogs with a calm, 1-tap paste / token / WebView-login workflow.
void showRemoteHostAuthSheet(
  BuildContext context,
  WidgetRef ref,
  ManagedHost host,
) {
  showGrassBagSheet<void>(
    context,
    title: '授权连接「${host.name}」',
    subtitle: '只需完成一次验证，之后 30 天内自动免填 Token 重连',
    icon: CupertinoIcons.lock_shield_fill,
    bodyBuilder: (sheetCtx) => _RemoteHostAuthSheetBody(host: host),
  );
}

class _RemoteHostAuthSheetBody extends ConsumerStatefulWidget {
  const _RemoteHostAuthSheetBody({required this.host});
  final ManagedHost host;

  @override
  ConsumerState<_RemoteHostAuthSheetBody> createState() => _RemoteHostAuthSheetBodyState();
}

class _RemoteHostAuthSheetBodyState extends ConsumerState<_RemoteHostAuthSheetBody> {
  final TextEditingController _inputCtrl = TextEditingController();
  bool _submitting = false;
  bool _obscureToken = true;
  bool _showHelp = false;
  String? _tokenError;

  bool get _supportsWebLogin =>
      !kIsWeb &&
      !widget.host.isDesktopLanBridge &&
      defaultTargetPlatform == TargetPlatform.android;

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  static bool _looksLikePlainUrl(String value) {
    final lower = value.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('ws://') ||
        lower.startsWith('wss://');
  }

  Future<void> _pasteAndSubmit() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty) {
      ref.read(appProvider.notifier).showToast('剪贴板为空，请先在电脑端复制启动链接或 Token', tone: ToastTone.info);
      return;
    }
    _inputCtrl.text = raw;
    await _submitToken(raw);
  }

  Future<void> _submitToken(String raw) async {
    if (_submitting) return;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _tokenError = '请先粘贴包含 token 的启动链接或输入令牌';
      });
      return;
    }
    final parsed = (trimmed.contains('://') || trimmed.contains('token='))
        ? parseRemoteHostInput(trimmed)
        : null;
    final parsedToken = parsed?.token?.trim();
    if ((parsedToken == null || parsedToken.isEmpty) && _looksLikePlainUrl(trimmed)) {
      setState(() {
        _tokenError = '该链接未包含 ?token=... 参数，请复制带完整 token 的启动链接或使用「App 内网页登录」';
      });
      return;
    }
    setState(() {
      _submitting = true;
      _tokenError = null;
    });
    try {
      final ctrl = ref.read(appProvider.notifier);
      // Pass the full raw link when present so `updateHostToken` can also refresh DHCP IP changes!
      await ctrl.updateHostToken(widget.host.id, trimmed, awaitConnect: true);
      if (!mounted) return;
      final latest = ref.read(appProvider).hosts.where((h) => h.id == widget.host.id).firstOrNull;
      if (latest != null && latest.isConnectedUsable) {
        Navigator.of(context).pop();
      } else {
        setState(() {
          final errMsg = latest?.lastError?.trim();
          _tokenError = (errMsg != null && errMsg.isNotEmpty)
              ? errMsg
              : '令牌无效或已过期，请从电脑端重新复制完整链接或使用网页登录';
        });
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _openWebLogin() async {
    final nav = Navigator.of(context);
    final ctrl = ref.read(appProvider.notifier);
    nav.pop();
    final cookie = await nav.push<String>(
      GrassBagPageRoute<String>(
        builder: (_) => RemoteWebLoginPage(
          hostName: widget.host.name,
          baseAddress: widget.host.address,
          allowBadCertificates: widget.host.allowBadCertificates,
        ),
      ),
    );
    if (cookie != null && cookie.trim().isNotEmpty) {
      await ctrl.updateHostCookie(widget.host.id, cookie, switchAndConnect: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final t = GrassBagTokens.of(context);
    final isHtmlProxy = widget.host.isHtmlProxyAuth;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagStatusBanner(
          tone: GrassBagBannerTone.info,
          icon: CupertinoIcons.lock_shield_fill,
          title: isHtmlProxy ? '目标主机启用了网页网关认证' : '已连通目标主机，等待一次性授权',
          message: isHtmlProxy
              ? '点击下方「App 内网页登录」完成登录后，GrassBag 会自动保存 30 天会话凭证。'
              : '直接粘贴电脑端 dsh web 打印的整行链接（含 ?token=...）或桌面桥接 Token 即可立即接入，后续 30 天免填。',
          padding: const EdgeInsets.all(12),
          borderRadius: 16,
        ),
        const SizedBox(height: 12),
        if (isHtmlProxy && _supportsWebLogin) ...[
          GrassBagPrimaryGlassButton(
            label: 'App 内网页登录',
            icon: CupertinoIcons.globe,
            tier: tier,
            insideGlass: true,
            onTap: _openWebLogin,
          ),
          const SizedBox(height: 10),
        ],
        GrassBagTextField(
          controller: _inputCtrl,
          placeholder: '粘贴 http://.../?token=... 或直接输入 Token',
          insideGlass: true,
          monospace: true,
          obscureText: _obscureToken,
          hasError: _tokenError != null,
          fontSize: 13,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          textInputAction: TextInputAction.done,
          suffix: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _obscureToken = !_obscureToken),
            child: SizedBox(
              width: 34,
              height: 34,
              child: Center(
                child: Icon(
                  _obscureToken ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
                  size: 15,
                  color: t.text3,
                ),
              ),
            ),
          ),
          onChanged: (_) {
            if (_tokenError != null) setState(() => _tokenError = null);
          },
          onSubmitted: _submitToken,
        ),
        if (_tokenError != null) ...[
          const SizedBox(height: 6),
          Text(_tokenError!, style: TextStyle(fontSize: 12, color: t.err)),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '粘贴剪贴板',
                icon: CupertinoIcons.doc_on_clipboard,
                tier: tier,
                insideGlass: true,
                accentForeground: true,
                enabled: !_submitting,
                onTap: _submitting ? null : _pasteAndSubmit,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: _submitting ? '验证中…' : '验证并连接',
                icon: CupertinoIcons.checkmark_shield_fill,
                tier: tier,
                insideGlass: true,
                enabled: !_submitting,
                onTap: _submitting ? null : () => _submitToken(_inputCtrl.text),
              ),
            ),
          ],
        ),
        if (!isHtmlProxy && _supportsWebLogin) ...[
          const SizedBox(height: 8),
          GrassBagSecondaryGlassButton(
            label: 'App 内网页登录（反代 / 认证）',
            icon: CupertinoIcons.globe,
            tier: tier,
            insideGlass: true,
            onTap: _openWebLogin,
          ),
        ],
        const SizedBox(height: 8),
        GrassBagSpringTap(
          pressedScale: 0.97,
          enablePointerGlow: false,
          haptic: true,
          onTap: () => setState(() => _showHelp = !_showHelp),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _showHelp ? CupertinoIcons.chevron_up : CupertinoIcons.question_circle,
                  size: 13,
                  color: t.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  _showHelp ? '收起获取方式' : '如何获取启动链接 / Token？',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.primary),
                ),
              ],
            ),
          ),
        ),
        GrassBagSmoothDisclosure(
          expanded: _showHelp,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GrassBagSheetSection(
              borderRadius: 16,
              padding: const EdgeInsets.all(12),
              children: [
                Text(
                  widget.host.isDesktopLanBridge
                      ? '桌面端 :3081 桥接令牌保存在电脑的 ~/.dsh/gbridge-lan-token；也可点击下方复制一键指令发给电脑端 AI 自动提取完整链接。'
                      : '在电脑端运行 dsh web --host <局域网IP> 后会打印包含 ?token=... 的完整链接；或直接把一键指令发给电脑端 DeepSeek Harness 自动生成。',
                  style: TextStyle(fontSize: 11.5, height: 1.44, color: t.text2),
                ),
                const SizedBox(height: 8),
                GrassBagSecondaryGlassButton(
                  label: '复制桌面端一键指令',
                  icon: CupertinoIcons.sparkles,
                  height: 36,
                  tier: tier,
                  insideGlass: true,
                  accentForeground: true,
                  onTap: () {
                    Clipboard.setData(
                      const ClipboardData(text: RemoteHostConnectCard.desktopGuiPrompt),
                    );
                    ref.read(appProvider.notifier).showToast(
                          '已复制一键指令，发给电脑端 DeepSeek Harness 即可获取链接',
                          tone: ToastTone.ok,
                        );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '目标地址：${widget.host.address}',
          textAlign: TextAlign.center,
          style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: t.text3),
        ),
      ],
    );
  }
}

String _normalizeDiffPath(String raw) {
  var p = raw.trim().replaceAll('\\', '/');
  while (p.startsWith('./')) {
    p = p.substring(2);
  }
  while (p.startsWith('/')) {
    p = p.substring(1);
  }
  return p;
}

WorkspaceDiffRecord? _matchDiffRecord(List<WorkspaceDiffRecord> diffs, String filePath) {
  if (diffs.isEmpty) return null;
  final normTarget = _normalizeDiffPath(filePath);
  for (final d in diffs) {
    if (d.path == filePath || _normalizeDiffPath(d.path) == normTarget) return d;
  }
  for (final d in diffs) {
    final normD = _normalizeDiffPath(d.path);
    if (normTarget.endsWith('/$normD') || normD.endsWith('/$normTarget')) return d;
  }
  return null;
}

void showDiffSheet(BuildContext context, String filePath, {WorkspaceDiffRecord? record}) {
  final cleanPath = filePath.trim();
  final segs = cleanPath.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();
  final baseName = segs.isNotEmpty ? segs.last : cleanPath;
  final prev = record?.previousPath;
  final sub = (prev != null && prev.isNotEmpty && prev != cleanPath)
      ? '$prev → $cleanPath'
      : cleanPath;
  showGrassBagSheet(
    context,
    title: baseName,
    subtitle: sub,
    icon: CupertinoIcons.doc_text_search,
    expandable: true,
    initialExpanded: true,
    wideLayout: true,
    scrollableBody: false,
    bodyBuilder: (ctx) => _DiffSheetBody(filePath: cleanPath, record: record),
  );
}

class _ParsedDiffRow {
  const _ParsedDiffRow({
    required this.kind,
    required this.oldNum,
    required this.newNum,
    required this.text,
    this.pairIndex,
  });

  /// `'+'`, `'-'`, `' '`, `'@'`, or `'~'` (git meta header)
  final String kind;
  final String oldNum;
  final String newNum;
  final String text;

  /// Optional paired counterpart index inside the parsed list for intra-line word diffing.
  final int? pairIndex;
}

class _DiffSheetBody extends ConsumerStatefulWidget {
  const _DiffSheetBody({required this.filePath, this.record});
  final String filePath;
  final WorkspaceDiffRecord? record;

  @override
  ConsumerState<_DiffSheetBody> createState() => _DiffSheetBodyState();
}

class _DiffSheetBodyState extends ConsumerState<_DiffSheetBody> {
  static final RegExp _hunkRe = RegExp(r'^@@\s+-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s+@@');
  static const int _kDiffLinePageSize = 500;

  final ScrollController _vScrollCtrl = ScrollController();
  final ScrollController _hScrollCtrl = ScrollController();

  late String _activePath;
  WorkspaceDiffRecord? _pinnedRecord;
  bool _loading = false;
  bool _softWrap = false;
  bool _copiedFlash = false;
  Timer? _copyTimer;
  int _visibleLineCap = _kDiffLinePageSize;

  String? _cachedRawDiff;
  List<_ParsedDiffRow> _cachedLines = const [];
  List<int> _hunkRowIndices = const [];
  int _activeHunkIdx = 0;
  double _cachedMaxLinePx = 320.0;

  @override
  void initState() {
    super.initState();
    _activePath = widget.filePath;
    _pinnedRecord = widget.record;
    final initial = _pinnedRecord ??
        _matchDiffRecord(ref.read(appProvider).workspaceDiffs, _activePath);
    if (initial == null || (initial.unifiedDiff.isEmpty && !initial.binary)) {
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _refreshDiffs());
    }
  }

  @override
  void dispose() {
    _copyTimer?.cancel();
    _vScrollCtrl.dispose();
    _hScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshDiffs() async {
    if (mounted && !_loading) setState(() => _loading = true);
    try {
      await ref.read(appProvider.notifier).refreshWorkspaceDiffs(silent: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static bool _isGitMetaHeader(String l) {
    return l.startsWith('diff ') ||
        l.startsWith('index ') ||
        l.startsWith('--- ') ||
        l.startsWith('+++ ') ||
        l.startsWith('old mode ') ||
        l.startsWith('new mode ') ||
        l.startsWith('deleted file mode ') ||
        l.startsWith('new file mode ') ||
        l.startsWith('copy from ') ||
        l.startsWith('copy to ') ||
        l.startsWith('rename from ') ||
        l.startsWith('rename to ') ||
        l.startsWith('similarity index ') ||
        l.startsWith('dissimilarity index ') ||
        l.startsWith('Binary files ') ||
        l.startsWith('GIT binary patch') ||
        l.startsWith(r'\ No newline');
  }

  void _ensureParsed(String rawDiff) {
    if (_cachedRawDiff == rawDiff) return;
    _cachedRawDiff = rawDiff;
    _visibleLineCap = _kDiffLinePageSize;
    _activeHunkIdx = 0;
    if (rawDiff.isEmpty) {
      _cachedLines = const [];
      _hunkRowIndices = const [];
      _cachedMaxLinePx = 280.0;
      return;
    }
    final rawLines = rawDiff.replaceAll('\r\n', '\n').split('\n');
    final lineLimit =
        rawLines.isNotEmpty && rawLines.last.isEmpty ? rawLines.length - 1 : rawLines.length;
    final parsed = <_ParsedDiffRow>[];
    final hunks = <int>[];
    var oldLine = 0;
    var newLine = 0;
    var inHunk = false;
    var maxPx = 240.0;

    for (var i = 0; i < lineLimit; i++) {
      final l = rawLines[i];
      final m = _hunkRe.firstMatch(l);
      _ParsedDiffRow row;
      if (m != null) {
        oldLine = int.tryParse(m.group(1) ?? '1') ?? 1;
        newLine = int.tryParse(m.group(2) ?? '1') ?? 1;
        inHunk = true;
        hunks.add(parsed.length);
        row = _ParsedDiffRow(kind: '@', oldNum: '', newNum: '', text: l);
      } else if (_isGitMetaHeader(l)) {
        row = _ParsedDiffRow(kind: '~', oldNum: '', newNum: '', text: l);
      } else if (l.startsWith('+')) {
        row = _ParsedDiffRow(
          kind: '+',
          oldNum: '',
          newNum: inHunk ? '${newLine++}' : '${i + 1}',
          text: l.substring(1),
        );
      } else if (l.startsWith('-')) {
        row = _ParsedDiffRow(
          kind: '-',
          oldNum: inHunk ? '${oldLine++}' : '${i + 1}',
          newNum: '',
          text: l.substring(1),
        );
      } else {
        final oStr = inHunk ? '${oldLine++}' : '${i + 1}';
        final nStr = inHunk ? '${newLine++}' : '${i + 1}';
        row = _ParsedDiffRow(
          kind: ' ',
          oldNum: oStr,
          newNum: nStr,
          text: l.startsWith(' ') ? l.substring(1) : l,
        );
      }
      parsed.add(row);
      final px = estimateMonospaceLinePx(row.text, fontSize: 11.5);
      if (px > maxPx) maxPx = px;
    }

    // Pair contiguous `-` block followed immediately by `+` block for intra-line word diffing!
    var idx = 0;
    while (idx < parsed.length) {
      if (parsed[idx].kind == '-') {
        final delStart = idx;
        while (idx < parsed.length && parsed[idx].kind == '-') {
          idx++;
        }
        final delEnd = idx;
        final addStart = idx;
        while (idx < parsed.length && parsed[idx].kind == '+') {
          idx++;
        }
        final addEnd = idx;
        final pairCount = math.min(delEnd - delStart, addEnd - addStart);
        for (var p = 0; p < pairCount; p++) {
          final di = delStart + p;
          final ai = addStart + p;
          final dr = parsed[di];
          final ar = parsed[ai];
          parsed[di] = _ParsedDiffRow(
            kind: dr.kind,
            oldNum: dr.oldNum,
            newNum: dr.newNum,
            text: dr.text,
            pairIndex: ai,
          );
          parsed[ai] = _ParsedDiffRow(
            kind: ar.kind,
            oldNum: ar.oldNum,
            newNum: ar.newNum,
            text: ar.text,
            pairIndex: di,
          );
        }
      } else {
        idx++;
      }
    }

    _cachedLines = parsed;
    _hunkRowIndices = hunks;
    _cachedMaxLinePx = maxPx.clamp(240.0, 9000.0);
  }

  void _jumpToHunk(int delta) {
    if (_hunkRowIndices.isEmpty) return;
    HapticFeedback.selectionClick();
    final next = (_activeHunkIdx + delta) % _hunkRowIndices.length;
    final targetIdx = next < 0 ? next + _hunkRowIndices.length : next;
    final rowIdx = _hunkRowIndices[targetIdx];
    setState(() {
      _activeHunkIdx = targetIdx;
      if (rowIdx >= _visibleLineCap) {
        _visibleLineCap = rowIdx + _kDiffLinePageSize;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vScrollCtrl.hasClients) return;
      final rowExtent = math.max(
        22.0,
        MediaQuery.textScalerOf(context).scale(11.5) * 1.52 + 6.0,
      );
      final targetOffset = math.max(0.0, (rowIdx - 1) * rowExtent);
      _vScrollCtrl.animateTo(
        targetOffset.clamp(0.0, _vScrollCtrl.position.maxScrollExtent),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _switchToDiffRecord(WorkspaceDiffRecord nextRec) {
    HapticFeedback.selectionClick();
    setState(() {
      _activePath = nextRec.path;
      _pinnedRecord = nextRec;
      _cachedRawDiff = null;
      _copiedFlash = false;
    });
    if (_vScrollCtrl.hasClients) _vScrollCtrl.jumpTo(0);
    if (_hScrollCtrl.hasClients) _hScrollCtrl.jumpTo(0);
  }

  void _openFullFileSafely(String targetPath) {
    final hostCtx = grassBagNavigatorKey.currentContext;
    Navigator.of(context).pop();
    if (hostCtx != null && hostCtx.mounted) {
      scheduleMicrotask(() {
        if (hostCtx.mounted) {
          showWorkspaceFilePreviewSheet(hostCtx, path: targetPath);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final diffs = ref.watch(appProvider.select((s) => s.workspaceDiffs));
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final matched = (_pinnedRecord != null && _pinnedRecord!.path == _activePath && _pinnedRecord!.unifiedDiff.isNotEmpty)
        ? _pinnedRecord
        : (_matchDiffRecord(diffs, _activePath) ?? _pinnedRecord);
    final rawDiff = matched?.unifiedDiff ?? '';
    _ensureParsed(rawDiff);
    final lines = _cachedLines;
    final added = matched?.added ?? 0;
    final removed = matched?.removed ?? 0;
    final isBinary = matched?.binary == true;
    final isOversized = matched?.oversized == true;
    final t = GrassBagTokens.of(context);

    final activeIdxInList = diffs.indexWhere(
      (d) => _normalizeDiffPath(d.path) == _normalizeDiffPath(_activePath),
    );
    final hasFileSwitcher = diffs.length > 1 && activeIdxInList >= 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Top compact diff toolbar ──────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: [
                if (hasFileSwitcher) ...[
                  GrassBagFresnelGlassSurface(
                    isPill: true,
                    innerWell: true,
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: activeIdxInList > 0
                              ? () => _switchToDiffRecord(diffs[activeIdxInList - 1])
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                            child: Icon(
                              CupertinoIcons.chevron_left,
                              size: 12.5,
                              color: activeIdxInList > 0
                                  ? t.text2
                                  : t.text3.withValues(alpha: 0.35),
                            ),
                          ),
                        ),
                        Text(
                          '${activeIdxInList + 1}/${diffs.length}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: t.text2,
                          ),
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: activeIdxInList < diffs.length - 1
                              ? () => _switchToDiffRecord(diffs[activeIdxInList + 1])
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                            child: Icon(
                              CupertinoIcons.chevron_right,
                              size: 12.5,
                              color: activeIdxInList < diffs.length - 1
                                  ? t.text2
                                  : t.text3.withValues(alpha: 0.35),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                GrassBagFresnelGlassSurface(
                  isPill: true,
                  innerWell: true,
                  tintColor: t.okSoft,
                  padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 4),
                  child: Text(
                    '+$added',
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
                  padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 4),
                  child: Text(
                    '-$removed',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: t.err,
                    ),
                  ),
                ),
                if (_hunkRowIndices.length > 1) ...[
                  const SizedBox(width: 6),
                  GrassBagFresnelGlassSurface(
                    isPill: true,
                    innerWell: true,
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _jumpToHunk(-1),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                            child: Icon(CupertinoIcons.chevron_up, size: 12, color: t.text2),
                          ),
                        ),
                        Text(
                          '${_activeHunkIdx + 1}/${_hunkRowIndices.length} 处',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: t.text2,
                          ),
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _jumpToHunk(1),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                            child: Icon(CupertinoIcons.chevron_down, size: 12, color: t.text2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (lines.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  GrassBagSpringTap(
                    pressedScale: 0.94,
                    haptic: true,
                    onTap: () => setState(() => _softWrap = !_softWrap),
                    child: GrassBagFresnelGlassSurface(
                      isPill: true,
                      innerWell: true,
                      interactive: true,
                      tintColor: _softWrap ? t.primarySoft : null,
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.text_alignleft,
                            size: 11.5,
                            color: _softWrap ? (t.isDark ? t.primaryHi : t.primary) : t.text2,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _softWrap ? '自动换行' : '单行',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: _softWrap ? (t.isDark ? t.primaryHi : t.primary) : t.text2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // ── Main diff viewport ────────────────────────────────────────────────
        Expanded(
          child: _buildDiffViewport(
            context,
            t: t,
            tier: tier,
            lines: lines,
            isBinary: isBinary,
            isOversized: isOversized,
          ),
        ),

        // ── Load more lines bar ───────────────────────────────────────────────
        if (lines.length > _visibleLineCap) ...[
          const SizedBox(height: 8),
          GrassBagSecondaryGlassButton(
            label: '展开更多（剩余 ${lines.length - _visibleLineCap} 行）',
            icon: CupertinoIcons.chevron_down,
            height: 34,
            tier: tier,
            insideGlass: true,
            accentForeground: true,
            onTap: () => setState(() => _visibleLineCap += _kDiffLinePageSize),
          ),
        ],

        // ── Pinned footer actions ─────────────────────────────────────────────
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '查看完整文件',
                icon: CupertinoIcons.doc_text,
                height: 38,
                tier: tier,
                insideGlass: true,
                onTap: () => _openFullFileSafely(_activePath),
              ),
            ),
            if (rawDiff.isNotEmpty) ...[
              const SizedBox(width: 8),
              Expanded(
                child: GrassBagPrimaryGlassButton(
                  label: _copiedFlash ? '已复制' : '复制 Diff',
                  icon: _copiedFlash ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
                  height: 38,
                  tier: tier,
                  insideGlass: true,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    Clipboard.setData(ClipboardData(text: rawDiff));
                    ref.read(appProvider.notifier).showToast('已复制改动补丁');
                    _copyTimer?.cancel();
                    setState(() => _copiedFlash = true);
                    _copyTimer = Timer(const Duration(milliseconds: 1600), () {
                      if (mounted) setState(() => _copiedFlash = false);
                    });
                  },
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildDiffViewport(
    BuildContext context, {
    required GrassBagTokens t,
    required GrassBagGlassTier tier,
    required List<_ParsedDiffRow> lines,
    required bool isBinary,
    required bool isOversized,
  }) {
    final diffTier = resolveAmbientGlassTier(context);
    final frame = CustomPaint(
      foregroundPainter: diffTier == GrassBagGlassTier.solid
          ? null
          : GrassBagFresnelRimPainter(
              isDark: t.isDark,
              borderRadius: 16,
              accent: t.isDark ? t.primaryHi : null,
              innerWell: true,
              frosted: diffTier == GrassBagGlassTier.frosted,
              paintTopSheen: false,
              strokeWidth: 0.82,
            ),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: ShapeDecoration(
            color: t.codeBg,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(16),
              side: diffTier == GrassBagGlassTier.solid
                  ? BorderSide(
                      color: t.isDark ? Colors.white.withValues(alpha: 0.12) : t.sep,
                      width: 0.75,
                    )
                  : BorderSide.none,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Active file path header bar inside code box (updates when switching files!)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                color: t.codeBar,
                child: Row(
                  children: [
                    Icon(previewFileIcon(_activePath), size: 13, color: t.text3),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _activePath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.2,
                          fontWeight: FontWeight.w600,
                          color: t.text2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _buildDiffLinesContent(
                  context,
                  t: t,
                  tier: tier,
                  lines: lines,
                  isBinary: isBinary,
                  isOversized: isOversized,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return frame;
  }

  Widget _buildDiffLinesContent(
    BuildContext context, {
    required GrassBagTokens t,
    required GrassBagGlassTier tier,
    required List<_ParsedDiffRow> lines,
    required bool isBinary,
    required bool isOversized,
  }) {
    if (lines.isEmpty) {
      if (_loading) {
        return Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GrassBagActivityIndicator(radius: 10, color: t.primary),
              const SizedBox(width: 10),
              Text('正在加载工作区 Git 差异…', style: TextStyle(fontSize: 13, color: t.text2)),
            ],
          ),
        );
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isBinary ? CupertinoIcons.doc_fill : CupertinoIcons.doc_text_search,
                size: 28,
                color: t.text3,
              ),
              const SizedBox(height: 8),
              Text(
                isBinary
                    ? '二进制文件变更，无法展示逐行文本差异。'
                    : (isOversized
                        ? '该文件 Diff 体积过大已被主机截断，建议直接查看完整文件。'
                        : '当前工作区未检测到该文件的详细 Unified Diff。'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, height: 1.45, color: t.text3),
              ),
              const SizedBox(height: 12),
              GrassBagSecondaryGlassButton(
                label: '重新加载差异',
                icon: CupertinoIcons.refresh,
                height: 34,
                tier: tier,
                insideGlass: true,
                onTap: _refreshDiffs,
              ),
            ],
          ),
        ),
      );
    }

    final visibleCount = math.min(lines.length, _visibleLineCap);
    final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 2.0);
    final singleColW = (32.0 * textScale).ceilToDouble().clamp(30.0, 56.0);
    final rowExtent = math.max(22.0, textScale * 11.5 * 1.52 + 6.0).ceilToDouble();

    final addBg = t.isDark ? const Color(0x241F9D63) : const Color(0x1B16A34A);
    final delBg = t.isDark ? const Color(0x28D14E4E) : const Color(0x18DC2626);
    final addEmphBg = t.isDark ? const Color(0x5222C55E) : const Color(0x4016A34A);
    final delEmphBg = t.isDark ? const Color(0x54EF4444) : const Color(0x3CDC2626);
    final hunkBg = t.isDark ? const Color(0x243B82F6) : const Color(0x162563EB);
    final addFg = t.isDark ? const Color(0xFF5DD199) : const Color(0xFF15803D);
    final delFg = t.isDark ? const Color(0xFFF08A84) : const Color(0xFFB91C1C);
    final hunkFg = t.isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8);
    final mutedFg = t.text3;

    Widget buildDiffRow(int idx, {required bool wrap}) {
      final row = lines[idx];
      final baseStyle = TextStyle(
        fontFamily: 'monospace',
        fontSize: 11.5,
        height: 1.48,
        fontWeight: row.kind == '@' ? FontWeight.w600 : FontWeight.w400,
        color: row.kind == '@'
            ? hunkFg
            : (row.kind == '~' ? mutedFg : t.codeFg),
      );

      InlineSpan codeSpan;
      if (row.pairIndex != null && row.pairIndex! < lines.length) {
        final other = lines[row.pairIndex!];
        if (row.kind == '-') {
          codeSpan = computeIntraLineDiffSpans(
            oldText: row.text,
            newText: other.text,
            oldBaseStyle: baseStyle,
            newBaseStyle: baseStyle,
            oldEmphBg: delEmphBg,
            newEmphBg: addEmphBg,
          ).oldSpan;
        } else {
          codeSpan = computeIntraLineDiffSpans(
            oldText: other.text,
            newText: row.text,
            oldBaseStyle: baseStyle,
            newBaseStyle: baseStyle,
            oldEmphBg: delEmphBg,
            newEmphBg: addEmphBg,
          ).newSpan;
        }
      } else {
        codeSpan = TextSpan(text: expandTabs(row.text), style: baseStyle);
      }

      if (row.kind == '@') {
        return Container(
          color: hunkBg,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          alignment: Alignment.centerLeft,
          child: Text(
            row.text,
            maxLines: wrap ? null : 1,
            softWrap: wrap,
            overflow: wrap ? TextOverflow.clip : TextOverflow.visible,
            style: baseStyle,
          ),
        );
      }

      return Container(
        color: switch (row.kind) {
          '+' => addBg,
          '-' => delBg,
          _ => Colors.transparent,
        },
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
        child: Row(
          crossAxisAlignment: wrap ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            SelectionContainer.disabled(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: singleColW,
                    child: Text(
                      row.oldNum,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10.2,
                        height: 1.48,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: mutedFg.withValues(alpha: 0.72),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  SizedBox(
                    width: singleColW,
                    child: Text(
                      row.newNum,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10.2,
                        height: 1.48,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: mutedFg.withValues(alpha: 0.72),
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  SizedBox(
                    width: 12,
                    child: Text(
                      row.kind == '~' ? ' ' : row.kind,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        height: 1.48,
                        fontWeight: FontWeight.w700,
                        color: switch (row.kind) {
                          '+' => addFg,
                          '-' => delFg,
                          _ => mutedFg,
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Text.rich(
                codeSpan,
                softWrap: wrap,
                maxLines: wrap ? null : 1,
                overflow: wrap ? TextOverflow.clip : TextOverflow.visible,
              ),
            ),
          ],
        ),
      );
    }

    if (_softWrap) {
      return SelectionArea(
        contextMenuBuilder: buildGrassBagSelectableContextMenu,
        child: Scrollbar(
          controller: _vScrollCtrl,
          child: ListView.builder(
            controller: _vScrollCtrl,
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: visibleCount,
            physics: const BouncingScrollPhysics(),
            itemBuilder: (_, idx) => buildDiffRow(idx, wrap: true),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (ctx, box) {
        final gutterTotal = singleColW * 2 + 42.0;
        final desiredW = (_cachedMaxLinePx * textScale) + gutterTotal + 24.0;
        final effectiveW = math.max(box.maxWidth.isFinite ? box.maxWidth : 320.0, desiredW);
        // SelectionArea strictly OUTSIDE horizontal scroller for clean Android swipe!
        return SelectionArea(
          contextMenuBuilder: buildGrassBagSelectableContextMenu,
          child: Scrollbar(
            controller: _hScrollCtrl,
            notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: _hScrollCtrl,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: SizedBox(
                width: effectiveW.clamp(280.0, 12000.0),
                height: box.maxHeight,
                child: Scrollbar(
                  controller: _vScrollCtrl,
                  child: ListView.builder(
                    controller: _vScrollCtrl,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: visibleCount,
                    itemExtent: rowExtent,
                    cacheExtent: 360,
                    physics: const BouncingScrollPhysics(),
                    itemBuilder: (_, idx) => buildDiffRow(idx, wrap: false),
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

void showCommandOutputSheet(
  BuildContext context, {
  required String command,
  required bool failed,
  String? outputText,
  VoidCallback? onOpenTerminal,
  String? title,
  String? subtitle,
}) {
  showGrassBagSheet(
    context,
    title: title ?? '命令输出',
    subtitle: subtitle ?? (failed ? '执行返回非零状态' : '命令执行结果'),
    icon: failed
        ? CupertinoIcons.exclamationmark_triangle_fill
        : CupertinoIcons.chevron_left_slash_chevron_right,
    iconColor: failed ? GrassBagTokens.of(context).err : GrassBagTokens.of(context).primary,
    expandable: true,
    initialExpanded: true,
    wideLayout: true,
    scrollableBody: false,
    bodyBuilder: (_) => _CommandOutputSheetBody(
      command: command,
      failed: failed,
      outputText: outputText ?? '',
      onOpenTerminal: onOpenTerminal,
    ),
  );
}

class _CommandOutputSheetBody extends ConsumerStatefulWidget {
  const _CommandOutputSheetBody({
    required this.command,
    required this.failed,
    required this.outputText,
    this.onOpenTerminal,
  });

  final String command;
  final bool failed;
  final String outputText;
  final VoidCallback? onOpenTerminal;

  @override
  ConsumerState<_CommandOutputSheetBody> createState() => _CommandOutputSheetBodyState();
}

class _CommandOutputSheetBodyState extends ConsumerState<_CommandOutputSheetBody> {
  final ScrollController _vCtrl = ScrollController();
  final ScrollController _hCtrl = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  late final List<String> _rawLines;
  late final List<String> _plainLines;
  late final List<int> _errorIndices;
  late final String _cleanFullText;
  late final double _maxLinePx;

  bool _expandCommand = false;
  bool _onlyErrors = false;
  bool _softWrap = true;
  bool _showSearch = false;
  bool _copiedFlash = false;
  bool _atBottom = false;
  Timer? _copyTimer;

  String _searchQuery = '';
  List<int> _searchMatches = const [];
  int _activeMatchCursor = 0;

  @override
  void initState() {
    super.initState();
    final trimmed = widget.outputText.trimRight();
    if (trimmed.isEmpty) {
      _rawLines = const ['（暂无标准输出）'];
      _plainLines = const ['（暂无标准输出）'];
      _cleanFullText = '';
    } else {
      final norm = trimmed.replaceAll('\r\n', '\n');
      _rawLines = norm.split('\n');
      _plainLines = _rawLines.map(stripAnsiAndControl).toList(growable: false);
      _cleanFullText = _plainLines.join('\n');
    }
    final errs = <int>[];
    var maxPx = 240.0;
    for (var i = 0; i < _plainLines.length; i++) {
      if (isErrorLogLine(_plainLines[i])) errs.add(i);
      final px = estimateMonospaceLinePx(_plainLines[i], fontSize: 11.8);
      if (px > maxPx) maxPx = px;
    }
    _errorIndices = errs;
    _maxLinePx = maxPx.clamp(240.0, 9600.0);
    _vCtrl.addListener(_onVerticalScroll);
  }

  void _onVerticalScroll() {
    if (!_vCtrl.hasClients) return;
    final pos = _vCtrl.position;
    final nearBottom = pos.maxScrollExtent > 24 && pos.pixels >= pos.maxScrollExtent - 28;
    if (nearBottom != _atBottom && mounted) {
      setState(() => _atBottom = nearBottom);
    }
  }

  @override
  void dispose() {
    _copyTimer?.cancel();
    _vCtrl.removeListener(_onVerticalScroll);
    _vCtrl.dispose();
    _hCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  List<int> get _visibleIndices =>
      _onlyErrors ? _errorIndices : List<int>.generate(_rawLines.length, (i) => i);

  void _recomputeSearch() {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) {
      _searchMatches = const [];
      _activeMatchCursor = 0;
      return;
    }
    final visible = _visibleIndices;
    final hits = <int>[];
    for (var vi = 0; vi < visible.length; vi++) {
      if (_plainLines[visible[vi]].toLowerCase().contains(q)) {
        hits.add(vi);
      }
    }
    _searchMatches = hits;
    if (hits.isEmpty || _activeMatchCursor >= hits.length) {
      _activeMatchCursor = 0;
    }
  }

  void _jumpToMatch(int delta) {
    if (_searchMatches.isEmpty) return;
    HapticFeedback.selectionClick();
    final next = (_activeMatchCursor + delta) % _searchMatches.length;
    setState(() {
      _activeMatchCursor = next < 0 ? next + _searchMatches.length : next;
    });
    final visIdx = _searchMatches[_activeMatchCursor];
    if (_vCtrl.hasClients) {
      final estExtent = math.max(20.0, MediaQuery.textScalerOf(context).scale(11.8) * 1.54);
      final offset = math.max(0.0, (visIdx - 2) * estExtent);
      _vCtrl.animateTo(
        offset.clamp(0.0, _vCtrl.position.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _jumpTopOrBottom() {
    if (!_vCtrl.hasClients) return;
    HapticFeedback.selectionClick();
    final target = _atBottom ? 0.0 : _vCtrl.position.maxScrollExtent;
    _vCtrl.animateTo(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final visible = _visibleIndices;
    final activeMatchVisIdx = _searchMatches.isNotEmpty
        ? _searchMatches[_activeMatchCursor.clamp(0, _searchMatches.length - 1)]
        : -1;
    final matchBg = t.isDark ? const Color(0xCC9A6700) : const Color(0xFFFFE58F);
    final matchFg = t.isDark ? Colors.white : const Color(0xFF1F2937);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Compact log toolbar ───────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 4.5),
                  decoration: BoxDecoration(
                    color: t.fill1,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: t.sep, width: 0.6),
                  ),
                  child: Text(
                    _onlyErrors
                        ? '${_errorIndices.length} / ${_rawLines.length} 错误行'
                        : '${_rawLines.length} 行',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: t.text2,
                    ),
                  ),
                ),
                if (_errorIndices.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  GrassBagSpringTap(
                    pressedScale: 0.94,
                    haptic: true,
                    onTap: () => setState(() {
                      _onlyErrors = !_onlyErrors;
                      _recomputeSearch();
                    }),
                    child: GrassBagFresnelGlassSurface(
                      isPill: true,
                      innerWell: true,
                      interactive: true,
                      tintColor: _onlyErrors ? t.errSoft : null,
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.exclamationmark_circle,
                            size: 11.5,
                            color: _onlyErrors ? t.err : t.text2,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '仅看错误 (${_errorIndices.length})',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: _onlyErrors ? t.err : t.text2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                GrassBagSpringTap(
                  pressedScale: 0.94,
                  haptic: true,
                  onTap: () {
                    setState(() {
                      _showSearch = !_showSearch;
                      if (!_showSearch) {
                        _searchQuery = '';
                        _searchCtrl.clear();
                        _recomputeSearch();
                      }
                    });
                    if (_showSearch) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _searchFocus.requestFocus();
                      });
                    }
                  },
                  child: GrassBagFresnelGlassSurface(
                    isPill: true,
                    innerWell: true,
                    interactive: true,
                    tintColor: _showSearch ? t.primarySoft : null,
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          CupertinoIcons.search,
                          size: 11.5,
                          color: _showSearch ? (t.isDark ? t.primaryHi : t.primary) : t.text2,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '查找',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _showSearch ? (t.isDark ? t.primaryHi : t.primary) : t.text2,
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
                  onTap: _jumpTopOrBottom,
                  child: GrassBagFresnelGlassSurface(
                    isPill: true,
                    innerWell: true,
                    interactive: true,
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _atBottom ? CupertinoIcons.arrow_up_to_line : CupertinoIcons.arrow_down_to_line,
                          size: 11.5,
                          color: t.text2,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _atBottom ? '回到顶部' : '直达底部',
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
                const SizedBox(width: 6),
                GrassBagSpringTap(
                  pressedScale: 0.94,
                  haptic: true,
                  onTap: () => setState(() => _softWrap = !_softWrap),
                  child: GrassBagFresnelGlassSurface(
                    isPill: true,
                    innerWell: true,
                    interactive: true,
                    tintColor: _softWrap ? t.primarySoft : null,
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
                    child: Text(
                      _softWrap ? '自动换行' : '单行',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _softWrap ? (t.isDark ? t.primaryHi : t.primary) : t.text2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Collapsible search bar ────────────────────────────────────────────
        if (_showSearch)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: GrassBagTextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    placeholder: '搜索输出日志…',
                    insideGlass: true,
                    fontSize: 12.5,
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7.5),
                    onChanged: (v) {
                      setState(() {
                        _searchQuery = v;
                        _activeMatchCursor = 0;
                        _recomputeSearch();
                      });
                      if (_searchMatches.isNotEmpty) _jumpToMatch(0);
                    },
                    onSubmitted: (_) => _jumpToMatch(1),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _searchQuery.trim().isEmpty
                      ? ''
                      : (_searchMatches.isEmpty
                          ? '0 匹配'
                          : '${_activeMatchCursor + 1}/${_searchMatches.length}'),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: _searchMatches.isEmpty && _searchQuery.trim().isNotEmpty
                        ? t.warn
                        : t.text3,
                  ),
                ),
                const SizedBox(width: 4),
                GrassBagSpringTap(
                  onTap: () => _jumpToMatch(-1),
                  child: GrassBagFresnelGlassSurface(
                    isCircle: true,
                    innerWell: true,
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    child: Icon(CupertinoIcons.chevron_up, size: 12.5, color: t.text2),
                  ),
                ),
                const SizedBox(width: 4),
                GrassBagSpringTap(
                  onTap: () => _jumpToMatch(1),
                  child: GrassBagFresnelGlassSurface(
                    isCircle: true,
                    innerWell: true,
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    child: Icon(CupertinoIcons.chevron_down, size: 12.5, color: t.text2),
                  ),
                ),
              ],
            ),
          ),

        // ── Main ANSI & semantic log viewport ─────────────────────────────────
        Expanded(
          child: CustomPaint(
            foregroundPainter: tier == GrassBagGlassTier.solid
                ? null
                : GrassBagFresnelRimPainter(
                    isDark: t.isDark,
                    borderRadius: 16,
                    accent: widget.failed ? t.err : t.primaryHi,
                    innerWell: true,
                    frosted: tier == GrassBagGlassTier.frosted,
                    paintTopSheen: false,
                    strokeWidth: 0.85,
                  ),
            child: ClipRSuperellipse(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                decoration: ShapeDecoration(
                  color: t.codeBg,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: tier == GrassBagGlassTier.solid
                        ? BorderSide(
                            color: widget.failed
                                ? t.err.withValues(alpha: t.isDark ? 0.34 : 0.28)
                                : (t.isDark ? Colors.white.withValues(alpha: 0.12) : t.sep),
                            width: 0.75,
                          )
                        : BorderSide.none,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Expandable & copyable command header
                    if (widget.command.trim().isNotEmpty)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _expandCommand = !_expandCommand),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          color: t.codeBar,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Container(
                                  width: 6.5,
                                  height: 6.5,
                                  decoration: BoxDecoration(
                                    color: widget.failed ? t.err : t.ok,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '\$ ${widget.command}',
                                  maxLines: _expandCommand ? 8 : 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11.4,
                                    height: 1.4,
                                    fontWeight: FontWeight.w600,
                                    color: t.isDark ? t.primaryHi : t.primary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  Clipboard.setData(ClipboardData(text: widget.command));
                                  ref.read(appProvider.notifier).showToast('已复制命令');
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: Icon(CupertinoIcons.doc_on_doc, size: 12.5, color: t.text3),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Expanded(
                      child: visible.isEmpty
                          ? Center(
                              child: Text(
                                '未检测到明显错误行，可关闭「仅看错误」查看完整日志',
                                style: TextStyle(fontSize: 12.5, color: t.text3),
                              ),
                            )
                          : LayoutBuilder(
                              builder: (ctx, box) {
                                final digits = math.max(2, _rawLines.length.toString().length);
                                final gutterW =
                                    (digits * MediaQuery.textScalerOf(ctx).scale(7.0) + 14.0)
                                        .ceilToDouble()
                                        .clamp(30.0, 74.0);
                                final errFg = t.isDark ? const Color(0xFFFF8582) : t.err;
                                final warnFg = t.isDark ? const Color(0xFFFBBF24) : t.warn;
                                final okFg = t.isDark ? const Color(0xFF6EE7B7) : t.ok;
                                final accFg = t.isDark ? const Color(0xFF93C5FD) : t.primary;

                                Widget buildLogRow(int visIdx, {required bool wrap}) {
                                  final realIdx = visible[visIdx];
                                  final isSearchRow = visIdx == activeMatchVisIdx;
                                  final span = buildAnsiOrLogLineSpan(
                                    _rawLines[realIdx],
                                    isDark: t.isDark,
                                    fontSize: 11.8,
                                    height: 1.48,
                                    defaultColor: t.codeFg,
                                    errColor: errFg,
                                    warnColor: warnFg,
                                    okColor: okFg,
                                    accentColor: accFg,
                                    searchQuery: _searchQuery,
                                    matchBg: matchBg,
                                    matchFg: matchFg,
                                  );
                                  return Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
                                    color: isSearchRow
                                        ? t.warn.withValues(alpha: t.isDark ? 0.22 : 0.16)
                                        : null,
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        SelectionContainer.disabled(
                                          child: SizedBox(
                                            width: gutterW,
                                            child: Padding(
                                              padding: const EdgeInsets.only(right: 10),
                                              child: Text(
                                                '${realIdx + 1}',
                                                textAlign: TextAlign.right,
                                                style: TextStyle(
                                                  fontFamily: 'monospace',
                                                  fontSize: 10.2,
                                                  height: 1.48,
                                                  fontFeatures: const [FontFeature.tabularFigures()],
                                                  color: t.text3.withValues(alpha: 0.50),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: Text.rich(
                                            span,
                                            softWrap: wrap,
                                            maxLines: wrap ? null : 1,
                                            overflow:
                                                wrap ? TextOverflow.clip : TextOverflow.visible,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }

                                if (_softWrap) {
                                  return SelectionArea(
                                    contextMenuBuilder: buildGrassBagSelectableContextMenu,
                                    child: Scrollbar(
                                      controller: _vCtrl,
                                      child: ListView.builder(
                                        controller: _vCtrl,
                                        padding: const EdgeInsets.symmetric(vertical: 8),
                                        itemCount: visible.length,
                                        physics: const BouncingScrollPhysics(),
                                        itemBuilder: (_, vi) => buildLogRow(vi, wrap: true),
                                      ),
                                    ),
                                  );
                                }

                                final availW = box.maxWidth.isFinite ? box.maxWidth : 320.0;
                                final contentW = math.max(availW, _maxLinePx + gutterW + 36.0);
                                return SelectionArea(
                                  contextMenuBuilder: buildGrassBagSelectableContextMenu,
                                  child: Scrollbar(
                                    controller: _hCtrl,
                                    notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
                                    child: SingleChildScrollView(
                                      controller: _hCtrl,
                                      scrollDirection: Axis.horizontal,
                                      physics: const BouncingScrollPhysics(),
                                      child: SizedBox(
                                        width: contentW.clamp(280.0, 12000.0),
                                        height: box.maxHeight,
                                        child: Scrollbar(
                                          controller: _vCtrl,
                                          child: ListView.builder(
                                            controller: _vCtrl,
                                            padding: const EdgeInsets.symmetric(vertical: 8),
                                            itemCount: visible.length,
                                            physics: const BouncingScrollPhysics(),
                                            itemBuilder: (_, vi) => buildLogRow(vi, wrap: false),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
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

        // ── Pinned Footer Actions ─────────────────────────────────────────────
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: _copiedFlash ? '已复制' : '复制纯文本输出',
                icon: _copiedFlash ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
                height: 38,
                tier: tier,
                insideGlass: true,
                onTap: () {
                  HapticFeedback.selectionClick();
                  final copyPayload =
                      _cleanFullText.isEmpty ? widget.command : _cleanFullText;
                  Clipboard.setData(ClipboardData(text: copyPayload));
                  ref.read(appProvider.notifier).showToast('已复制干净输出（已去除控制符）', tone: ToastTone.ok);
                  _copyTimer?.cancel();
                  setState(() => _copiedFlash = true);
                  _copyTimer = Timer(const Duration(milliseconds: 1600), () {
                    if (mounted) setState(() => _copiedFlash = false);
                  });
                },
              ),
            ),
            if (widget.onOpenTerminal != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: GrassBagPrimaryGlassButton(
                  label: '在终端打开',
                  icon: CupertinoIcons.chevron_left_slash_chevron_right,
                  height: 38,
                  tier: tier,
                  insideGlass: true,
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onOpenTerminal!();
                  },
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _SheetOptionRow extends StatelessWidget {
  const _SheetOptionRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.badge,
    this.warnTone = false,
    this.monoSubtitle = false,
    this.trailingExtra,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;
  final bool warnTone;
  final bool monoSubtitle;
  final Widget? trailingExtra;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final accent = warnTone ? t.warn : t.primary;

    return GrassBagSpringTap(
      onTap: onTap,
      pressedScale: 0.985,
      haptic: true,
      borderRadius: 11,
      child: AnimatedContainer(
        duration: GrassBagMotion.duration(context, const Duration(milliseconds: 200)),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: ShapeDecoration(
          // Always supply a 2-stop gradient (never toggle color <-> gradient) so
          // `ShapeDecoration.lerp` never violates `!(color != null && gradient != null)`!
          // Borderless Apple tonal highlight avoids harsh box-inside-box double borders
          // inside the concentric `GrassBagSheetSection` well.
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: selected
                ? [
                    accent.withValues(alpha: t.isDark ? 0.22 : 0.12),
                    accent.withValues(alpha: t.isDark ? 0.11 : 0.055),
                  ]
                : const [Colors.transparent, Colors.transparent],
          ),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10.5),
        child: Row(
          children: [
            GrassBagSquircleIcon(
              icon: icon,
              color: iconColor,
              size: 36,
              iconSize: 17,
              filled: selected,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                            color: t.text,
                          ),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 7),
                        GrassBagFresnelGlassSurface(
                          isPill: true,
                          innerWell: true,
                          tintColor: warnTone
                              ? t.warnSoft
                              : iconColor.withValues(alpha: t.isDark ? 0.22 : 0.13),
                          padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 2),
                          child: Text(
                            badge!,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: warnTone ? t.warn : iconColor,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2.5),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: monoSubtitle ? 'monospace' : null,
                      fontSize: monoSubtitle ? 11.5 : 12,
                      height: 1.3,
                      color: t.text3,
                    ),
                  ),
                ],
              ),
            ),
            if (trailingExtra != null) ...[
              const SizedBox(width: 4),
              trailingExtra!,
            ],
            AnimatedSwitcher(
              duration: GrassBagMotion.duration(context, const Duration(milliseconds: 170)),
              switchInCurve: Curves.easeOutBack,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.72, end: 1.0).animate(anim),
                  child: child,
                ),
              ),
              child: selected
                  ? Padding(
                      key: const ValueKey('opt-selected'),
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(
                        CupertinoIcons.checkmark_circle_fill,
                        size: 21,
                        color: accent,
                      ),
                    )
                  : const SizedBox.shrink(key: ValueKey('opt-idle')),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({
    required this.color,
    required this.label,
    required this.value,
  });

  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: t.text2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: t.text3,
          ),
        ),
      ],
    );
  }
}

/// Leak-free shared Rename Session sheet (properly disposes `TextEditingController`).
void showRenameSessionSheet(
  BuildContext context,
  WidgetRef ref,
  ChatSessionItem session,
) {
  showGrassBagSheet<void>(
    context,
    title: '重命名对话',
    bodyBuilder: (ctx) => _RenameSessionSheetBody(session: session),
  );
}

class _RenameSessionSheetBody extends ConsumerStatefulWidget {
  const _RenameSessionSheetBody({required this.session});
  final ChatSessionItem session;

  @override
  ConsumerState<_RenameSessionSheetBody> createState() => _RenameSessionSheetBodyState();
}

class _RenameSessionSheetBodyState extends ConsumerState<_RenameSessionSheetBody> {
  late final TextEditingController _ctrl;
  String? _err;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.session.title);
    if (_ctrl.text.isNotEmpty) {
      _ctrl.selection = TextSelection(baseOffset: 0, extentOffset: _ctrl.text.length);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final clean = _ctrl.text.trim();
    if (clean.isEmpty) {
      setState(() => _err = '对话名称不能为空');
      return;
    }
    ref.read(appProvider.notifier).renameSession(widget.session.id, clean);
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
          controller: _ctrl,
          autofocus: true,
          placeholder: '输入对话名称…',
          insideGlass: true,
          hasError: _err != null,
          suffix: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _ctrl,
            builder: (_, val, __) => val.text.isEmpty
                ? const SizedBox.shrink()
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _ctrl.clear();
                      if (_err != null) setState(() => _err = null);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(CupertinoIcons.xmark_circle_fill, size: 16, color: t.text3),
                    ),
                  ),
          ),
          onChanged: (_) {
            if (_err != null) setState(() => _err = null);
          },
          onSubmitted: (_) => _save(),
        ),
        if (_err != null) ...[
          const SizedBox(height: 6),
          Text(_err!, style: TextStyle(fontSize: 12, color: t.err)),
        ],
        const SizedBox(height: 12),
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
                label: '保存',
                tier: tier,
                insideGlass: true,
                onTap: _save,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Real Deliverable Preview Sheet — delegates to the unified flagship previewer
/// (syntax highlighting, Markdown/JSON/CSV modes, search, font zoom, pagination, and real file export).
void showDeliverablePreviewSheet(
  BuildContext context,
  WidgetRef ref, {
  required String name,
  String? path,
  String subtitle = '生成产物',
  String sizeLabel = '',
}) {
  showDeliverableFilePreviewSheet(
    context,
    name: name,
    path: path,
    subtitle: subtitle,
    sizeLabel: sizeLabel,
  );
}

/// Honest Voice Dictation Sheet (no fake recording timer or fake preset chips).
void showVoiceInputSheet(
  BuildContext context,
  WidgetRef ref, {
  required ValueChanged<String> onTranscriptConfirmed,
}) {
  final state = ref.read(appProvider);
  showGrassBagSheet<void>(
    context,
    title: '系统语音听写',
    subtitle: '通过系统输入法麦克风完成听写，确认后一键填入对话输入框',
    bodyBuilder: (ctx) => _VoiceInputSheetBody(
      tier: state.glassTier,
      speechConfigured: state.speechConfigured,
      onConfirm: (text) {
        Navigator.of(ctx).pop();
        onTranscriptConfirmed(text);
      },
    ),
  );
}

class _VoiceInputSheetBody extends StatefulWidget {
  const _VoiceInputSheetBody({
    required this.tier,
    required this.speechConfigured,
    required this.onConfirm,
  });
  final GrassBagGlassTier tier;
  final bool speechConfigured;
  final ValueChanged<String> onConfirm;

  @override
  State<_VoiceInputSheetBody> createState() => _VoiceInputSheetBodyState();
}

class _VoiceInputSheetBodyState extends State<_VoiceInputSheetBody> {
  final _ctrl = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final next = _ctrl.text.trim().isNotEmpty;
    if (next != _hasText) setState(() => _hasText = next);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTextChanged);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagStatusBanner(
          tone: widget.speechConfigured
              ? GrassBagBannerTone.ok
              : GrassBagBannerTone.info,
          icon: CupertinoIcons.mic_fill,
          message: '请点按下方输入框，通过系统输入法麦克风完成语音听写后确认填入。',
        ),
        const SizedBox(height: 12),
        GrassBagTextField(
          controller: _ctrl,
          autofocus: true,
          maxLines: 4,
          minLines: 2,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) {
            final text = _ctrl.text.trim();
            if (text.isNotEmpty) widget.onConfirm(text);
          },
          placeholder: '使用系统键盘语音听写或直接输入内容…',
          padding: const EdgeInsets.all(12),
          insideGlass: true,
        ),
        const SizedBox(height: 14),
        GrassBagPrimaryGlassButton(
          label: '确认填入输入框',
          icon: CupertinoIcons.checkmark_alt,
          tier: widget.tier,
          insideGlass: true,
          enabled: _hasText,
          onTap: _hasText ? () => widget.onConfirm(_ctrl.text.trim()) : null,
        ),
      ],
    );
  }
}

/// Single image entry displayed inside [showImagePreviewDialog]'s swipeable lightbox gallery.
class GrassBagImagePreviewItem {
  const GrassBagImagePreviewItem({
    this.bytes,
    this.url,
    this.title,
    this.mimeType,
    this.heroTag,
  });

  final Uint8List? bytes;
  final String? url;
  final String? title;
  final String? mimeType;
  final Object? heroTag;

  bool get isValid =>
      (bytes != null && bytes!.isNotEmpty) || (url != null && url!.trim().isNotEmpty);
}

enum _LightboxSurface { dark, checkerboard, light }

/// Fullscreen pinch-zoom & swipe-gallery image lightbox preview for composer attachments,
/// sent photos, file previews, and Markdown images. Uses a translucent `PageRouteBuilder`
/// so [Hero] flights from thumbnails work natively!
void showImagePreviewDialog(
  BuildContext context, {
  Uint8List? bytes,
  String? url,
  String? title,
  String? mimeType,
  Object? heroTag,
  List<GrassBagImagePreviewItem>? items,
  int initialIndex = 0,
}) {
  final effectiveItems = <GrassBagImagePreviewItem>[
    if (items != null && items.isNotEmpty)
      ...items.where((e) => e.isValid)
    else if ((bytes != null && bytes.isNotEmpty) || (url != null && url.trim().isNotEmpty))
      GrassBagImagePreviewItem(
        bytes: bytes,
        url: url?.trim(),
        title: title,
        mimeType: mimeType,
        heroTag: heroTag,
      ),
  ];
  if (effectiveItems.isEmpty) return;
  final clampedIndex = initialIndex.clamp(0, effectiveItems.length - 1);
  final hasHero = effectiveItems[clampedIndex].heroTag != null;
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final transDur = reduceMotion
      ? const Duration(milliseconds: 90)
      : Duration(milliseconds: hasHero ? 260 : 220);

  _grassBagOpenSheetDepth.value++;
  Navigator.of(context, rootNavigator: true)
      .push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      transitionDuration: transDur,
      reverseTransitionDuration: reduceMotion
          ? const Duration(milliseconds: 80)
          : const Duration(milliseconds: 200),
      pageBuilder: (ctx, _, __) => _GrassBagImageLightbox(
        items: effectiveItems,
        initialIndex: clampedIndex,
      ),
      transitionsBuilder: (ctx, anim, _, child) => _ImageLightboxRouteTransition(
        animation: anim,
        hasHero: hasHero,
        child: child,
      ),
    ),
  )
      .whenComplete(() {
    final nextDepth = _grassBagOpenSheetDepth.value - 1;
    _grassBagOpenSheetDepth.value = nextDepth < 0 ? 0 : nextDepth;
  });
}

class _ImageLightboxRouteTransition extends StatefulWidget {
  const _ImageLightboxRouteTransition({
    required this.animation,
    required this.hasHero,
    required this.child,
  });

  final Animation<double> animation;
  final bool hasHero;
  final Widget child;

  @override
  State<_ImageLightboxRouteTransition> createState() =>
      _ImageLightboxRouteTransitionState();
}

class _ImageLightboxRouteTransitionState
    extends State<_ImageLightboxRouteTransition> {
  late CurvedAnimation _curve;
  late Animation<double> _scale;

  void _init() {
    _curve = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _scale = Tween<double>(begin: 0.94, end: 1.0).animate(_curve);
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant _ImageLightboxRouteTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _curve.dispose();
      _init();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion || widget.hasHero) {
      return FadeTransition(
        opacity: _curve,
        child: widget.child,
      );
    }
    return FadeTransition(
      opacity: _curve,
      child: ScaleTransition(
        scale: _scale,
        child: widget.child,
      ),
    );
  }
}

class _CheckerboardBackdropPainter extends CustomPainter {
  const _CheckerboardBackdropPainter();

  static const double _squareSize = 16.0;
  static const Color _lightColor = Color(0xFFD6DAE2);
  static const Color _darkColor = Color(0xFFB3BAC6);

  @override
  void paint(Canvas canvas, Size size) {
    final lightPaint = Paint()..color = _lightColor;
    final darkPaint = Paint()..color = _darkColor;
    canvas.drawRect(Offset.zero & size, lightPaint);
    final cols = (size.width / _squareSize).ceil();
    final rows = (size.height / _squareSize).ceil();
    for (var r = 0; r < rows; r++) {
      for (var c = (r.isEven ? 0 : 1); c < cols; c += 2) {
        canvas.drawRect(
          Rect.fromLTWH(c * _squareSize, r * _squareSize, _squareSize, _squareSize),
          darkPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerboardBackdropPainter old) => false;
}

class _GrassBagImageLightbox extends StatefulWidget {
  const _GrassBagImageLightbox({
    required this.items,
    required this.initialIndex,
  });

  final List<GrassBagImagePreviewItem> items;
  final int initialIndex;

  @override
  State<_GrassBagImageLightbox> createState() => _GrassBagImageLightboxState();
}

class _GrassBagImageLightboxState extends State<_GrassBagImageLightbox>
    with SingleTickerProviderStateMixin {
  late final PageController _pageCtrl;
  late final SingleSpringController _dragSpring;
  final ValueNotifier<double> _scaleNotifier = ValueNotifier<double>(1.0);
  final FocusNode _focusNode = FocusNode();
  final Map<int, GlobalKey<_LightboxPhotoPageState>> _pageKeys = {};
  final Map<int, Size> _dimsByIndex = {};

  late int _currentIndex;
  bool _showHud = true;
  _LightboxSurface _surface = _LightboxSurface.dark;
  bool _busyAction = false;
  bool _savedFlash = false;
  bool _copiedUrl = false;
  Timer? _flashTimer;

  GrassBagImagePreviewItem get _activeItem => widget.items[_currentIndex];
  bool get _isZoomed => _scaleNotifier.value > 1.03;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageCtrl = PageController(initialPage: widget.initialIndex);
    _dragSpring = SingleSpringController(
      vsync: this,
      spring: GlassSpring.snappy(duration: const Duration(milliseconds: 260)),
      initialValue: 0.0,
    );
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    _dragSpring.dispose();
    _scaleNotifier.dispose();
    _pageCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  GlobalKey<_LightboxPhotoPageState> _keyFor(int index) =>
      _pageKeys.putIfAbsent(index, () => GlobalKey<_LightboxPhotoPageState>());

  void _cycleSurface() {
    HapticFeedback.selectionClick();
    setState(() {
      _surface = switch (_surface) {
        _LightboxSurface.dark => _LightboxSurface.checkerboard,
        _LightboxSurface.checkerboard => _LightboxSurface.light,
        _LightboxSurface.light => _LightboxSurface.dark,
      };
    });
  }

  String _surfaceLabel(_LightboxSurface s) => switch (s) {
        _LightboxSurface.dark => '深色底',
        _LightboxSurface.checkerboard => '透明格',
        _LightboxSurface.light => '浅色底',
      };

  IconData _surfaceIcon(_LightboxSurface s) => switch (s) {
        _LightboxSurface.dark => CupertinoIcons.moon_fill,
        _LightboxSurface.checkerboard => CupertinoIcons.square_grid_2x2_fill,
        _LightboxSurface.light => CupertinoIcons.sun_max_fill,
      };

  void _showToast(String msg) {
    if (!mounted) return;
    try {
      ProviderScope.containerOf(context, listen: false)
          .read(appProvider.notifier)
          .showToast(msg);
    } catch (_) {}
  }

  String _resolvedFilename(GrassBagImagePreviewItem item) {
    final rawTitle = (item.title ?? '').trim();
    if (rawTitle.isNotEmpty && rawTitle != '图片预览' && !rawTitle.startsWith('http')) {
      final base = rawTitle.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull ?? rawTitle;
      if (base.contains('.')) return base;
      return '$base.${_extForMime(item.mimeType)}';
    }
    final url = item.url;
    if (url != null && url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      final seg = uri?.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
      if (seg != null && seg.contains('.') && seg.length <= 80) return seg;
    }
    return 'grassbag-image-${DateTime.now().millisecondsSinceEpoch}.${_extForMime(item.mimeType)}';
  }

  String _extForMime(String? mime) {
    final m = (mime ?? '').toLowerCase();
    if (m.contains('jpeg') || m.contains('jpg')) return 'jpg';
    if (m.contains('webp')) return 'webp';
    if (m.contains('gif')) return 'gif';
    return 'png';
  }

  String _resolvedMime(GrassBagImagePreviewItem item, String filename) {
    if (item.mimeType != null && item.mimeType!.isNotEmpty) return item.mimeType!;
    final lower = filename.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }

  Future<Uint8List?> _resolveActiveBytes() async {
    final item = _activeItem;
    if (item.bytes != null && item.bytes!.isNotEmpty) return item.bytes;
    final url = item.url;
    if (url != null && url.isNotEmpty) {
      return fetchRemoteBytes(url);
    }
    return null;
  }

  Future<void> _saveImage() async {
    if (_busyAction) return;
    HapticFeedback.selectionClick();
    setState(() => _busyAction = true);
    try {
      final item = _activeItem;
      final filename = _resolvedFilename(item);
      final mime = _resolvedMime(item, filename);
      final data = await _resolveActiveBytes();
      if (!mounted) return;
      if (data == null || data.isEmpty) {
        if (item.url != null && item.url!.isNotEmpty) {
          final opened = openUrlInNewTab(item.url!) ||
              await GrassBagNativeBridge.instance.openExternalUrl(item.url!);
          _showToast(opened ? '已在浏览器打开原图，可长按保存' : '未能获取原图数据');
        } else {
          _showToast('图片数据为空，无法保存');
        }
        return;
      }
      if (GrassBagNativeBridge.instance.isAndroidNative) {
        final res = await GrassBagNativeBridge.instance.saveImageBytes(
          bytes: data,
          filename: filename,
          mimeType: mime,
        );
        if (!mounted) return;
        if (res.ok) {
          _triggerSavedFlash();
          _showToast('已保存至相册 · ${res.location ?? filename}');
        } else {
          _showToast(res.error ?? '保存相册失败');
        }
        return;
      }
      final saved = downloadWebBytes(filename, data, mimeType: mime);
      if (saved) {
        _triggerSavedFlash();
        _showToast(kIsWeb ? '已开始下载 $filename' : '已保存至下载目录 · $filename');
      } else {
        _showToast('当前环境暂不支持直接保存');
      }
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  void _triggerSavedFlash() {
    _flashTimer?.cancel();
    setState(() => _savedFlash = true);
    _flashTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _savedFlash = false);
    });
  }

  Future<void> _shareImage() async {
    if (_busyAction) return;
    HapticFeedback.selectionClick();
    setState(() => _busyAction = true);
    try {
      final item = _activeItem;
      final filename = _resolvedFilename(item);
      final mime = _resolvedMime(item, filename);
      final data = await _resolveActiveBytes();
      if (!mounted) return;
      if (data != null && data.isNotEmpty) {
        if (GrassBagNativeBridge.instance.isAndroidNative) {
          final ok = await GrassBagNativeBridge.instance.shareFileBytes(
            bytes: data,
            filename: filename,
            mimeType: mime,
          );
          if (!ok) _showToast('调用系统分享失败');
          return;
        }
        if (downloadWebBytes(filename, data, mimeType: mime)) {
          _showToast(kIsWeb ? '已下载 $filename' : '已导出至下载目录 · $filename');
          return;
        }
      }
      if (item.url != null && item.url!.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: item.url!));
        _showToast('已复制图片链接');
      } else {
        _showToast('当前环境暂不支持系统分享');
      }
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  void _copyUrl() {
    final url = _activeItem.url;
    if (url == null || url.isEmpty) return;
    HapticFeedback.selectionClick();
    Clipboard.setData(ClipboardData(text: url));
    _flashTimer?.cancel();
    setState(() => _copiedUrl = true);
    _showToast('已复制图片链接');
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copiedUrl = false);
    });
  }

  void _goRelativePage(int delta) {
    final next = (_currentIndex + delta).clamp(0, widget.items.length - 1);
    if (next == _currentIndex) return;
    HapticFeedback.selectionClick();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageCtrl.jumpToPage(next);
    } else {
      _pageCtrl.animateToPage(
        next,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    if (_isZoomed) return;
    // Zero full-tree setState! Updates isolated ListenableBuilders at 120Hz.
    _dragSpring.setValue(_dragSpring.value + d.delta.dy);
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    if (_isZoomed) return;
    final vel = d.primaryVelocity ?? 0.0;
    final y = _dragSpring.value;
    if (y.abs() > 110.0 || vel.abs() > 620.0) {
      HapticFeedback.selectionClick();
      if (_activeItem.heroTag == null && !MediaQuery.disableAnimationsOf(context)) {
        final dir = y != 0 ? y.sign : (vel >= 0 ? 1.0 : -1.0);
        _dragSpring.animateTo(y + dir * 180.0, fromVelocity: vel);
      }
      Navigator.of(context).pop();
    } else {
      if (MediaQuery.disableAnimationsOf(context)) {
        _dragSpring.setValue(0.0);
      } else {
        _dragSpring.animateTo(0.0, fromVelocity: vel);
      }
    }
  }

  void _onVerticalDragCancel() {
    if (_dragSpring.value.abs() > 0.1) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _dragSpring.setValue(0.0);
      } else {
        _dragSpring.animateTo(0.0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final topPad = media.padding.top;
    final bottomPad = media.padding.bottom;
    final isWide = media.size.width >= 760;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final hudDur = GrassBagMotion.duration(context, const Duration(milliseconds: 190));
    final isLightSurface = _surface == _LightboxSurface.light;
    final hudFg = isLightSurface ? const Color(0xFF141820) : Colors.white;
    final hudMuted = isLightSurface
        ? const Color(0xFF475569)
        : Colors.white.withValues(alpha: 0.72);
    final hudPillBg = isLightSurface
        ? const Color(0xE0EEF2F8)
        : const Color(0xCC12161E);

    final item = _activeItem;
    final dim = _dimsByIndex[_currentIndex];
    final sizeLabel = item.bytes != null && item.bytes!.isNotEmpty
        ? formatPreviewBytes(item.bytes!.length)
        : '';

    final photoPager = ValueListenableBuilder<double>(
      valueListenable: _scaleNotifier,
      builder: (_, scaleVal, __) {
        final zoomed = scaleVal > 1.03;
        return PageView.builder(
          controller: _pageCtrl,
          physics: zoomed
              ? const NeverScrollableScrollPhysics()
              : const BouncingScrollPhysics(),
          itemCount: widget.items.length,
          onPageChanged: (idx) {
            _scaleNotifier.value = 1.0;
            setState(() {
              _currentIndex = idx;
              _savedFlash = false;
              _copiedUrl = false;
            });
          },
          itemBuilder: (ctx, idx) => _LightboxPhotoPage(
            key: _keyFor(idx),
            item: widget.items[idx],
            isLightSurface: isLightSurface,
            onToggleHud: () => setState(() => _showHud = !_showHud),
            onScaleChanged: (scale) {
              if (idx == _currentIndex && (scale - _scaleNotifier.value).abs() > 0.015) {
                _scaleNotifier.value = scale;
              }
            },
            onDimensionsResolved: (sz) {
              if (_dimsByIndex[idx] != sz && mounted) {
                setState(() => _dimsByIndex[idx] = sz);
              }
            },
          ),
        );
      },
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isLightSurface
          ? SystemUiOverlayStyle.dark
          : SystemUiOverlayStyle.light,
      child: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (ev) {
          if (ev is! KeyDownEvent) return;
          if (ev.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.of(context).pop();
          } else if (ev.logicalKey == LogicalKeyboardKey.arrowLeft && widget.items.length > 1) {
            _goRelativePage(-1);
          } else if (ev.logicalKey == LogicalKeyboardKey.arrowRight && widget.items.length > 1) {
            _goRelativePage(1);
          }
        },
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              // Dynamic surface backdrop (dark / checkerboard / light) with crossfade + isolated drag fade.
              Positioned.fill(
                child: RepaintBoundary(
                  child: ListenableBuilder(
                    listenable: _dragSpring,
                    child: AnimatedSwitcher(
                      duration: GrassBagMotion.duration(
                        context,
                        const Duration(milliseconds: 220),
                      ),
                      child: switch (_surface) {
                        _LightboxSurface.dark => const ColoredBox(
                            key: ValueKey('lb-surf-dark'),
                            color: Color(0xFA05080E),
                          ),
                        _LightboxSurface.light => const ColoredBox(
                            key: ValueKey('lb-surf-light'),
                            color: Color(0xF6F4F6FA),
                          ),
                        _LightboxSurface.checkerboard => const CustomPaint(
                            key: ValueKey('lb-surf-check'),
                            painter: _CheckerboardBackdropPainter(),
                          ),
                      },
                    ),
                    builder: (_, child) {
                      final p = (_dragSpring.value.abs() / 320.0).clamp(0.0, 1.0);
                      final alpha = (1.0 - p * 0.78).clamp(0.16, 1.0);
                      return GrassBagControlledOpacity(opacity: alpha, child: child);
                    },
                  ),
                ),
              ),
              // Swipeable multi-image photo stage: permanently attached drag callbacks (no recognizer
              // churn mid-pinch!) and isolated 120Hz ListenableBuilder transform!
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragUpdate: _onVerticalDragUpdate,
                  onVerticalDragEnd: _onVerticalDragEnd,
                  onVerticalDragCancel: _onVerticalDragCancel,
                  child: ListenableBuilder(
                    listenable: _dragSpring,
                    child: photoPager,
                    builder: (_, child) {
                      final y = _dragSpring.value;
                      final p = (y.abs() / 320.0).clamp(0.0, 1.0);
                      final s = (1.0 - p * 0.14).clamp(0.84, 1.0);
                      return Transform.translate(
                        offset: Offset(0, y),
                        child: Transform.scale(scale: s, child: child),
                      );
                    },
                  ),
                ),
              ),
              // Desktop / wide-screen gallery navigation arrows
              if (isWide && widget.items.length > 1) ...[
                if (_currentIndex > 0)
                  Positioned(
                    left: 18,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: ListenableBuilder(
                        listenable: _dragSpring,
                        builder: (_, child) {
                          final visible = _showHud && _dragSpring.value.abs() < 12;
                          return AnimatedOpacity(
                            opacity: visible ? 1.0 : 0.0,
                            duration: hudDur,
                            curve: Curves.easeOutCubic,
                            child: IgnorePointer(ignoring: !visible, child: child),
                          );
                        },
                        child: GrassBagGlassCircleButton(
                          icon: CupertinoIcons.chevron_left,
                          size: 42,
                          iconSize: 18,
                          iconColor: hudFg,
                          tintColor: hudPillBg,
                          tooltip: '上一张',
                          tier: GrassBagGlassTier.solid,
                          onTap: () => _goRelativePage(-1),
                        ),
                      ),
                    ),
                  ),
                if (_currentIndex < widget.items.length - 1)
                  Positioned(
                    right: 18,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: ListenableBuilder(
                        listenable: _dragSpring,
                        builder: (_, child) {
                          final visible = _showHud && _dragSpring.value.abs() < 12;
                          return AnimatedOpacity(
                            opacity: visible ? 1.0 : 0.0,
                            duration: hudDur,
                            curve: Curves.easeOutCubic,
                            child: IgnorePointer(ignoring: !visible, child: child),
                          );
                        },
                        child: GrassBagGlassCircleButton(
                          icon: CupertinoIcons.chevron_right,
                          size: 42,
                          iconSize: 18,
                          iconColor: hudFg,
                          tintColor: hudPillBg,
                          tooltip: '下一张',
                          tier: GrassBagGlassTier.solid,
                          onTap: () => _goRelativePage(1),
                        ),
                      ),
                    ),
                  ),
              ],
              // Top HUD gradient & title / gallery counter / close button
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: ListenableBuilder(
                  listenable: _dragSpring,
                  builder: (_, child) {
                    final visible = _showHud && _dragSpring.value.abs() < 16;
                    return AnimatedSlide(
                      offset: visible || reduceMotion ? Offset.zero : const Offset(0, -0.14),
                      duration: hudDur,
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: visible ? 1.0 : 0.0,
                        duration: hudDur,
                        curve: Curves.easeOutCubic,
                        child: IgnorePointer(ignoring: !visible, child: child),
                      ),
                    );
                  },
                  child: Container(
                    padding: EdgeInsets.fromLTRB(16, topPad + 10, 16, 18),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: isLightSurface
                            ? [
                                const Color(0xDCF4F6FA),
                                const Color(0x80F4F6FA),
                                Colors.transparent,
                              ]
                            : [
                                Colors.black.withValues(alpha: 0.72),
                                Colors.black.withValues(alpha: 0.28),
                                Colors.transparent,
                              ],
                      ),
                    ),
                    child: Row(
                      children: [
                        if (widget.items.length > 1) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                            decoration: BoxDecoration(
                              color: hudPillBg,
                              borderRadius: BorderRadius.circular(99),
                              border: Border.all(
                                color: hudFg.withValues(alpha: 0.14),
                                width: 0.6,
                              ),
                            ),
                            child: Text(
                              '${_currentIndex + 1} / ${widget.items.length}',
                              style: TextStyle(
                                color: hudFg,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Text(
                            item.title?.trim().isNotEmpty == true ? item.title!.trim() : '图片预览',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: hudFg,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              shadows: isLightSurface
                                  ? null
                                  : const [
                                      Shadow(color: Color(0x88000000), blurRadius: 6),
                                    ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GrassBagGlassCircleButton(
                          icon: CupertinoIcons.xmark,
                          size: 38,
                          iconSize: 16,
                          iconColor: hudFg,
                          tintColor: hudPillBg,
                          tooltip: '关闭预览',
                          tier: GrassBagGlassTier.solid,
                          onTap: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Bottom HUD: metadata readout + surface switcher + Save / Share / Copy URL
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: ListenableBuilder(
                  listenable: _dragSpring,
                  builder: (_, child) {
                    final visible = _showHud && _dragSpring.value.abs() < 16;
                    return AnimatedSlide(
                      offset: visible || reduceMotion ? Offset.zero : const Offset(0, 0.14),
                      duration: hudDur,
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: visible ? 1.0 : 0.0,
                        duration: hudDur,
                        curve: Curves.easeOutCubic,
                        child: IgnorePointer(ignoring: !visible, child: child),
                      ),
                    );
                  },
                  child: Container(
                    padding: EdgeInsets.fromLTRB(16, 20, 16, bottomPad + 14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: isLightSurface
                            ? [
                                const Color(0xE8F4F6FA),
                                const Color(0x90F4F6FA),
                                Colors.transparent,
                              ]
                            : [
                                Colors.black.withValues(alpha: 0.78),
                                Colors.black.withValues(alpha: 0.32),
                                Colors.transparent,
                              ],
                      ),
                    ),
                    child: ValueListenableBuilder<double>(
                      valueListenable: _scaleNotifier,
                      builder: (_, scaleVal, __) {
                        final metaParts = <String>[
                          if (dim != null) '${dim.width.round()} × ${dim.height.round()}',
                          if (sizeLabel.isNotEmpty) sizeLabel,
                          if (scaleVal > 1.03) '${scaleVal.toStringAsFixed(1)}×',
                        ];
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (metaParts.isNotEmpty) ...[
                              Text(
                                metaParts.join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: hudMuted,
                                  fontSize: 11.8,
                                  fontWeight: FontWeight.w500,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              physics: const BouncingScrollPhysics(),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AnimatedSize(
                                    duration: hudDur,
                                    curve: Curves.easeOutCubic,
                                    child: scaleVal > 1.05
                                        ? Padding(
                                            padding: const EdgeInsets.only(right: 8),
                                            child: _LightboxHudPill(
                                              icon: CupertinoIcons.arrow_down_right_arrow_up_left,
                                              label: '1× 还原',
                                              fg: hudFg,
                                              bg: hudPillBg,
                                              onTap: () =>
                                                  _keyFor(_currentIndex).currentState?.resetZoom(),
                                            ),
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                                  _LightboxHudPill(
                                    icon: _surfaceIcon(_surface),
                                    label: _surfaceLabel(_surface),
                                    fg: hudFg,
                                    bg: hudPillBg,
                                    onTap: _cycleSurface,
                                  ),
                                  if (item.url != null && item.url!.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    _LightboxHudPill(
                                      icon: _copiedUrl
                                          ? CupertinoIcons.checkmark
                                          : CupertinoIcons.link,
                                      label: _copiedUrl ? '已复制' : '复制链接',
                                      fg: _copiedUrl ? const Color(0xFF34D399) : hudFg,
                                      bg: hudPillBg,
                                      onTap: _copyUrl,
                                    ),
                                  ],
                                  const SizedBox(width: 8),
                                  _LightboxHudPill(
                                    icon: CupertinoIcons.share,
                                    label: '分享',
                                    fg: hudFg,
                                    bg: hudPillBg,
                                    busy: _busyAction,
                                    onTap: _shareImage,
                                  ),
                                  const SizedBox(width: 8),
                                  _LightboxHudPill(
                                    icon: _savedFlash
                                        ? CupertinoIcons.checkmark_alt
                                        : CupertinoIcons.arrow_down_to_line,
                                    label: _savedFlash ? '已保存' : '保存',
                                    fg: _savedFlash ? const Color(0xFF34D399) : hudFg,
                                    bg: hudPillBg,
                                    busy: _busyAction,
                                    onTap: _saveImage,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LightboxHudPill extends StatelessWidget {
  const _LightboxHudPill({
    required this.icon,
    required this.label,
    required this.fg,
    required this.bg,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final Color fg;
  final Color bg;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return GrassBagSpringTap(
      enabled: !busy,
      onTap: busy ? () {} : onTap,
      pressedScale: 0.94,
      enablePointerGlow: false,
      haptic: true,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: fg.withValues(alpha: 0.14),
            width: 0.65,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              GrassBagActivityIndicator(radius: 6, color: fg)
            else
              Icon(icon, size: 14, color: fg),
            const SizedBox(width: 5.5),
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 12.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LightboxPhotoPage extends StatefulWidget {
  const _LightboxPhotoPage({
    super.key,
    required this.item,
    required this.isLightSurface,
    required this.onToggleHud,
    required this.onScaleChanged,
    required this.onDimensionsResolved,
  });

  final GrassBagImagePreviewItem item;
  final bool isLightSurface;
  final VoidCallback onToggleHud;
  final ValueChanged<double> onScaleChanged;
  final ValueChanged<Size> onDimensionsResolved;

  @override
  State<_LightboxPhotoPage> createState() => _LightboxPhotoPageState();
}

class _LightboxPhotoPageState extends State<_LightboxPhotoPage>
    with SingleTickerProviderStateMixin {
  final TransformationController _transformCtrl = TransformationController();
  late final AnimationController _zoomCtrl;
  late final CurvedAnimation _zoomCurve;
  Animation<Matrix4>? _zoomAnim;
  Offset _doubleTapLocalPos = Offset.zero;
  Size _viewportSize = Size.zero;
  int _retryNonce = 0;

  ImageStream? _infoStream;
  ImageStreamListener? _infoListener;

  @override
  void initState() {
    super.initState();
    _zoomCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() {
        final anim = _zoomAnim;
        if (anim != null) {
          _transformCtrl.value = anim.value;
          widget.onScaleChanged(_currentScale);
        }
      });
    _zoomCurve = CurvedAnimation(parent: _zoomCtrl, curve: Curves.easeOutCubic);
    _transformCtrl.addListener(_handleTransformChange);
    _resolveNaturalDimensions();
  }

  @override
  void didUpdateWidget(covariant _LightboxPhotoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.bytes != widget.item.bytes ||
        oldWidget.item.url != widget.item.url) {
      _transformCtrl.value = Matrix4.identity();
      _resolveNaturalDimensions();
    }
  }

  void _disposeInfoStream() {
    if (_infoStream != null && _infoListener != null) {
      _infoStream!.removeListener(_infoListener!);
    }
    _infoStream = null;
    _infoListener = null;
  }

  void _resolveNaturalDimensions() {
    _disposeInfoStream();
    final ImageProvider? provider = widget.item.bytes != null && widget.item.bytes!.isNotEmpty
        ? MemoryImage(widget.item.bytes!)
        : (widget.item.url != null && widget.item.url!.isNotEmpty
            ? NetworkImage(widget.item.url!)
            : null);
    if (provider == null) return;
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        final sz = Size(info.image.width.toDouble(), info.image.height.toDouble());
        if (sz.width > 0 && sz.height > 0) {
          widget.onDimensionsResolved(sz);
        }
      },
      onError: (_, __) {},
    );
    _infoStream = stream;
    _infoListener = listener;
    stream.addListener(listener);
  }

  void _handleTransformChange() {
    widget.onScaleChanged(_currentScale);
  }

  double get _currentScale => _transformCtrl.value.getMaxScaleOnAxis();

  void resetZoom() {
    _animateMatrixTo(Matrix4.identity());
  }

  void _animateMatrixTo(Matrix4 end) {
    if (mounted && MediaQuery.disableAnimationsOf(context)) {
      _transformCtrl.value = end;
      widget.onScaleChanged(_currentScale);
      return;
    }
    final begin = Matrix4.copy(_transformCtrl.value);
    _zoomAnim = Matrix4Tween(begin: begin, end: end).animate(_zoomCurve);
    _zoomCtrl.forward(from: 0.0);
  }

  void _toggleDoubleTapZoom() {
    if (_currentScale > 1.05) {
      _animateMatrixTo(Matrix4.identity());
      return;
    }
    const targetScale = 2.5;
    final vw = _viewportSize.width;
    final vh = _viewportSize.height;
    var tx = -_doubleTapLocalPos.dx * (targetScale - 1.0);
    var ty = -_doubleTapLocalPos.dy * (targetScale - 1.0);
    if (vw > 0 && vh > 0) {
      tx = tx.clamp(-vw * (targetScale - 1.0), 0.0);
      ty = ty.clamp(-vh * (targetScale - 1.0), 0.0);
    }
    final end = Matrix4.identity()
      ..translateByDouble(tx, ty, 0.0, 1.0)
      ..scaleByDouble(targetScale, targetScale, 1.0, 1.0);
    _animateMatrixTo(end);
  }

  void _retryNetworkImage() {
    final url = widget.item.url;
    if (url != null && url.isNotEmpty) {
      PaintingBinding.instance.imageCache.evict(NetworkImage(url));
    }
    setState(() => _retryNonce++);
    _resolveNaturalDimensions();
  }

  @override
  void dispose() {
    _disposeInfoStream();
    _transformCtrl.removeListener(_handleTransformChange);
    _zoomCurve.dispose();
    _zoomCtrl.dispose();
    _transformCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.isLightSurface ? const Color(0xFF1F2937) : Colors.white;
    final muted = widget.isLightSurface ? const Color(0xFF64748B) : Colors.white70;

    return LayoutBuilder(
      builder: (ctx, box) {
        _viewportSize = box.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onToggleHud,
          onDoubleTapDown: (d) => _doubleTapLocalPos = d.localPosition,
          onDoubleTap: _toggleDoubleTapZoom,
          child: InteractiveViewer(
            transformationController: _transformCtrl,
            minScale: 0.75,
            maxScale: 5.0,
            onInteractionStart: (_) {
              if (_zoomCtrl.isAnimating) _zoomCtrl.stop();
            },
            onInteractionEnd: (_) {
              if (_currentScale < 0.99) {
                _animateMatrixTo(Matrix4.identity());
              }
            },
            child: Center(
              child: () {
                final Widget img = widget.item.bytes != null && widget.item.bytes!.isNotEmpty
                    ? Image.memory(
                        widget.item.bytes!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (_, __, ___) => _buildErrorCard(fg, muted, allowRetry: false),
                      )
                    : Image.network(
                        widget.item.url!,
                        key: ValueKey('lightbox-net-${widget.item.url}-$_retryNonce'),
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        loadingBuilder: (_, child, progress) {
                          if (progress == null) return child;
                          final total = progress.expectedTotalBytes;
                          final pct = total != null && total > 0
                              ? (progress.cumulativeBytesLoaded / total).clamp(0.0, 1.0)
                              : null;
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (pct != null)
                                SizedBox(
                                  width: 38,
                                  height: 38,
                                  child: CircularProgressIndicator(
                                    value: pct,
                                    strokeWidth: 2.6,
                                    color: fg,
                                    backgroundColor: fg.withValues(alpha: 0.18),
                                  ),
                                )
                              else
                                GrassBagActivityIndicator(radius: 13, color: fg),
                              if (pct != null) ...[
                                const SizedBox(height: 10),
                                Text(
                                  '${(pct * 100).round()}%',
                                  style: TextStyle(
                                    color: muted,
                                    fontSize: 12,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ],
                            ],
                          );
                        },
                        errorBuilder: (_, __, ___) => _buildErrorCard(fg, muted, allowRetry: true),
                      );
                final tag = widget.item.heroTag;
                return tag != null ? Hero(tag: tag, child: img) : img;
              }(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildErrorCard(Color fg, Color muted, {required bool allowRetry}) {
    return Container(
      margin: const EdgeInsets.all(24),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: widget.isLightSurface
            ? Colors.black.withValues(alpha: 0.05)
            : Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: fg.withValues(alpha: 0.12), width: 0.7),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.exclamationmark_triangle, size: 24, color: muted),
          const SizedBox(height: 8),
          Text(
            allowRetry ? '图片加载失败' : '图片解码失败',
            style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w600),
          ),
          if (allowRetry) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _LightboxHudPill(
                  icon: CupertinoIcons.refresh,
                  label: '重试加载',
                  fg: fg,
                  bg: fg.withValues(alpha: 0.12),
                  onTap: _retryNetworkImage,
                ),
                if (widget.item.url != null && widget.item.url!.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  _LightboxHudPill(
                    icon: CupertinoIcons.arrow_up_right_square,
                    label: '浏览器打开',
                    fg: fg,
                    bg: fg.withValues(alpha: 0.12),
                    onTap: () {
                      final u = widget.item.url!;
                      if (!openUrlInNewTab(u) &&
                          GrassBagNativeBridge.instance.isAndroidNative) {
                        GrassBagNativeBridge.instance.openExternalUrl(u);
                      }
                    },
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Starts local Android Ubuntu + Node 24 + DSH bootstrap, prompting for explicit
/// confirmation first when the thin APK needs an online download over a metered
/// (cellular / hotspot) network, or always when triggered implicitly (e.g. tapping
/// Send / a suggestion card before downloading).
Future<void> triggerLocalRuntimeBootstrapWithGuard(
  BuildContext context,
  WidgetRef ref, {
  bool requireConfirmForRemote = false,
  String? implicitContextHint,
}) async {
  final native = GrassBagNativeBridge.instance;
  final ctrl = ref.read(appProvider.notifier);
  final fallbackRt = ref.read(appProvider).nativeRuntimeStatus;
  if (native.isAndroidNative) {
    final fresh = await native.getRuntimeStatus();
    final rt = fresh ?? fallbackRt;
    final needsRemote = !rt.hasBundledRuntimePayloads && rt.runtimeDownloadBytes > 0;
    if (needsRemote && (rt.isMeteredNetwork || requireConfirmForRemote)) {
      if (!context.mounted) return;
      final sizeLabel = rt.hasPartialDownload
          ? '剩余 ${rt.formattedDownloadSize}'
          : '约 ${rt.formattedDownloadSize}';
      final title = rt.isMeteredNetwork ? '正在使用移动数据网络' : '下载本机运行环境？';
      final prefix = (implicitContextHint != null && implicitContextHint.isNotEmpty)
          ? '$implicitContextHint。'
          : '';
      final netNotice = rt.isMeteredNetwork
          ? '当前为移动数据网络，预计消耗 $sizeLabel 流量'
          : '预计下载 $sizeLabel（支持国内镜像加速与断点续传，部署完成后可离线使用）';
      final ok = await showGrassBagConfirmDialog(
        context,
        title: title,
        message: '$prefix本机运行需先下载 Ubuntu + Node 24 + DSH 核心，$netNotice，确认开始下载吗？',
        cancelLabel: '暂不下载',
        confirmLabel: rt.hasPartialDownload ? '继续下载' : '下载并部署',
      );
      if (!ok) return;
    }
  }
  await ctrl.bootstrapLocalRuntime();
}

/// Shows the Liquid Glass sheet for selecting or customizing the online runtime
/// download source (mirror failover presets or custom HTTP/HTTPS base URL).
void showRuntimeMirrorSheet(BuildContext context, WidgetRef ref) {
  final rt = ref.read(appProvider).nativeRuntimeStatus;
  final tagText = rt.runtimeReleaseTag.isNotEmpty ? rt.runtimeReleaseTag : 'runtime-arm64-r2';
  showGrassBagSheet<void>(
    context,
    title: '运行环境下载源',
    subtitle: '当前锁定版本 $tagText · 下载前自动校验 SHA-256 签名',
    icon: CupertinoIcons.cloud_download_fill,
    bodyBuilder: (sheetCtx) => _RuntimeMirrorSheetBody(
      initialMirror: rt.customRuntimeMirrorUrl,
      releaseTag: tagText,
      onClose: () => Navigator.of(sheetCtx).pop(),
    ),
  );
}

class _RuntimeMirrorSheetBody extends ConsumerStatefulWidget {
  const _RuntimeMirrorSheetBody({
    required this.initialMirror,
    required this.releaseTag,
    required this.onClose,
  });

  final String initialMirror;
  final String releaseTag;
  final VoidCallback onClose;

  @override
  ConsumerState<_RuntimeMirrorSheetBody> createState() => _RuntimeMirrorSheetBodyState();
}

class _RuntimeMirrorSheetBodyState extends ConsumerState<_RuntimeMirrorSheetBody> {
  late final TextEditingController _ctrl;
  bool _saving = false;
  String? _errorText;

  List<({String label, String sub, String url})> get _presets => [
        (
          label: '自动择优（推荐）',
          sub: '依次尝试 gh-proxy.com → ghfast.top → GitHub 官方源',
          url: '',
        ),
        (
          label: 'gh-proxy.com 国内加速',
          sub: '优先通过 gh-proxy.com 代理拉取，失败自动回退',
          url: 'https://gh-proxy.com',
        ),
        (
          label: 'ghfast.top 国内加速',
          sub: '优先通过 ghfast.top 代理拉取，失败自动回退',
          url: 'https://ghfast.top',
        ),
        (
          label: 'GitHub 官方直连',
          sub: '直接访问 github.com Releases（适合海外或已开代理网络）',
          url: 'https://github.com/moduqishi/grassbag/releases/download/${widget.releaseTag}',
        ),
      ];

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialMirror);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _applyMirror(String url) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _errorText = null;
    });
    final err = await ref.read(appProvider.notifier).setLocalRuntimeMirrorUrl(url);
    if (!mounted) return;
    if (err != null && err.isNotEmpty) {
      setState(() {
        _saving = false;
        _errorText = err;
      });
      return;
    }
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final currentClean = widget.initialMirror.trim().replaceAll(RegExp(r'/+$'), '');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagSheetSection(
          dividerIndent: 56,
          children: [
            for (final preset in _presets)
              GrassBagListTile(
                leading: GrassBagSquircleIcon(
                  icon: preset.url.isEmpty ? CupertinoIcons.sparkles : CupertinoIcons.cloud_download_fill,
                  color: preset.url.isEmpty ? t.primary : t.ok,
                  size: 30,
                  iconSize: 15,
                  filled: currentClean == preset.url,
                ),
                title: Text(preset.label),
                subtitle: Text(preset.sub),
                trailing: currentClean == preset.url
                    ? Icon(CupertinoIcons.checkmark_circle_fill, size: 18, color: t.primary)
                    : null,
                onTap: _saving ? null : () => unawaited(_applyMirror(preset.url)),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '自定义镜像前缀或局域网下载地址',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text2),
          ),
        ),
        const SizedBox(height: 6),
        GrassBagTextField(
          controller: _ctrl,
          placeholder: '如 https://mirror.example.com 或 http://192.168.1.10:8000',
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          insideGlass: true,
          hasError: _errorText != null,
          fontSize: 13.2,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          onSubmitted: (_) => unawaited(_applyMirror(_ctrl.text)),
          onChanged: (_) {
            if (_errorText != null) setState(() => _errorText = null);
          },
        ),
        if (_errorText != null) ...[
          const SizedBox(height: 6),
          Text(
            _errorText!,
            style: TextStyle(fontSize: 12, color: t.err),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          '留空并保存即恢复自动择优；自定义地址支持直链目录或 GitHub 反代前缀，失败时仍自动回退至内置备用源。',
          style: TextStyle(fontSize: 11.5, height: 1.4, color: t.text3),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '恢复自动',
                height: 42,
                tier: tier,
                insideGlass: true,
                enabled: !_saving,
                onTap: () => unawaited(_applyMirror('')),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: _saving ? '保存中…' : '保存下载源',
                icon: CupertinoIcons.checkmark_alt,
                height: 42,
                tier: tier,
                insideGlass: true,
                enabled: !_saving,
                onTap: () => unawaited(_applyMirror(_ctrl.text)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
