import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
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
    final fullText = (toast.detail != null && toast.detail!.trim().isNotEmpty)
        ? '${toast.text}\n\n${toast.detail!.trim()}'
        : toast.text;
    final ctrl = ref.read(appProvider.notifier);
    ctrl.dismissToast();
    final navCtx = grassBagNavigatorKey.currentContext ?? context;
    showGrassBagSheet<void>(
      navCtx,
      title: toast.tone == ToastTone.warn ? '异常详情' : '提示详情',
      subtitle: '可长按选取或一键复制完整错误信息用于排查',
      bodyBuilder: (ctx) {
        final t = GrassBagTokens.of(ctx);
        final container = ProviderScope.containerOf(ctx, listen: false);
        final tier = container.read(appProvider).glassTier;
        final safeCtrl = container.read(appProvider.notifier);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: toast.tone == ToastTone.warn ? t.errSoft : t.fill1,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: toast.tone == ToastTone.warn
                      ? t.err.withValues(alpha: 0.28)
                      : t.sep,
                  width: 0.7,
                ),
              ),
              child: SelectableText(
                fullText,
contextMenuBuilder: buildGrassBagEditableContextMenu,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.2,
                  height: 1.5,
                  color: toast.tone == ToastTone.warn ? t.err : t.text,
                ),
              ),
            ),
            const SizedBox(height: 12),
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
                    label: '复制完整内容',
                    icon: CupertinoIcons.doc_on_doc,
                    tier: tier,
                    insideGlass: true,
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: fullText));
                      Navigator.of(ctx).pop();
                      safeCtrl.showToast('已复制异常详情');
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
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
            globalScope.registerOffset(_offsetToken, widget.bottomOffset);
          }
        });
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

    final isInspectable = (displayToast.detail != null && displayToast.detail!.trim().isNotEmpty) ||
        (displayToast.tone == ToastTone.warn && displayToast.text.trim().length > 48);
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
      child: Center(
        key: ValueKey('toast-${displayToast.id}'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Material(
            type: MaterialType.transparency,
            child: GestureDetector(
              onVerticalDragEnd: (details) {
                if ((details.primaryVelocity ?? 0) > 160) {
                  ref.read(appProvider.notifier).dismissToast();
                }
              },
              onTap: isInspectable
                  ? () => _openErrorDetail(context, ref, displayToast)
                  : () => ref.read(appProvider.notifier).dismissToast(),
              child: GrassBagGlass(
                tier: tier,
                borderRadius: displayToast.tone == ToastTone.warn ? 20 : 999,
                elevated: true,
                useSheetSettings: true,
                padding: EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: displayToast.tone == ToastTone.warn ? 10 : 9,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: switch (displayToast.tone) {
                          ToastTone.ok => t.okSoft,
                          ToastTone.warn => t.errSoft,
                          ToastTone.info => t.primarySoft,
                        },
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        switch (displayToast.tone) {
                          ToastTone.ok => CupertinoIcons.checkmark_alt,
                          ToastTone.warn => CupertinoIcons.exclamationmark,
                          ToastTone.info => CupertinoIcons.sparkles,
                        },
                        size: 13,
                        color: switch (displayToast.tone) {
                          ToastTone.ok => t.ok,
                          ToastTone.warn => t.err,
                          ToastTone.info => t.primary,
                        },
                      ),
                    ),
                    const SizedBox(width: 9),
                    Flexible(
                      child: Text(
                        displayToast.text,
                        maxLines: displayToast.tone == ToastTone.warn ? 2 : 1,
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
                          color: displayToast.tone == ToastTone.warn ? t.err : t.primary,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        CupertinoIcons.chevron_right,
                        size: 11,
                        color: displayToast.tone == ToastTone.warn ? t.err : t.primary,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
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
    if (widget.visible && !oldWidget.visible) {
      _enterCtrl.forward();
    } else if (!widget.visible && oldWidget.visible) {
      _enterCtrl.reverse();
    } else if (widget.visible && oldWidget.child.key != widget.child.key) {
      _enterCtrl
        ..value = 0.0
        ..forward();
    }
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
    final viewBot = MediaQuery.viewPaddingOf(context).bottom;
    final effectiveKb = kbInset > viewBot ? (kbInset - viewBot) : 0.0;
    final safeBottom = math.max(widget.bottomOffset, viewBot + 12.0);
    final motionChild = SlideTransition(
      position: _slide,
      child: GrassBagMaterializeTransition(
        animation: _enterCtrl,
        tier: widget.tier,
        alignment: Alignment.bottomCenter,
        scaleFrom: 0.94,
        contentSigma: 3.5,
        child: widget.child,
      ),
    );
    return Positioned(
      left: 16,
      right: 16,
      bottom: safeBottom,
      child: Transform.translate(
        offset: Offset(0, -effectiveKb),
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
}) async {
  final t = GrassBagTokens.of(context);
  final tier = ProviderScope.containerOf(context, listen: false).read(appProvider).glassTier;
  HapticFeedback.mediumImpact();
  _grassBagOpenSheetDepth.value++;
  try {
    final result = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: cancelLabel,
      barrierColor: t.isDark ? const Color(0x88080C12) : const Color(0x42182230),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogCtx, animation, secondaryAnimation) {
        final maxDialogH = (MediaQuery.sizeOf(dialogCtx).height * 0.78).clamp(240.0, 560.0);
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 332, maxHeight: maxDialogH),
              child: Material(
                type: MaterialType.transparency,
                child: GrassBagGlass(
                  tier: tier,
                  borderRadius: 32,
                  elevated: true,
                  useSheetSettings: true,
                  padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: t.text,
                        ),
                      ),
                      if (message.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Flexible(
                          child: SingleChildScrollView(
                            physics: const BouncingScrollPhysics(),
                            child: Text(
                              message,
                              style: TextStyle(
                                fontSize: 13.5,
                                height: 1.48,
                                color: t.text2,
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
                              height: 44,
                              tier: tier,
                              insideGlass: true,
                              onTap: () => Navigator.of(dialogCtx).pop(false),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: GrassBagPrimaryGlassButton(
                              label: confirmLabel,
                              height: 44,
                              tier: tier,
                              insideGlass: true,
                              color: isDestructive
                                  ? (t.isDark ? const Color(0xFFD94444) : t.err)
                                  : t.primary,
                              foregroundColor: isDestructive ? Colors.white : t.onPrimary,
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
        );
      },
      transitionBuilder: (ctx, anim, secondaryAnim, child) {
        return GrassBagMaterializeTransition(
          animation: anim,
          tier: tier,
          scaleFrom: tier == GrassBagGlassTier.solid ? 0.92 : 1.08,
          contentSigma: 6.0,
          child: child,
        );
      },
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
  required WidgetBuilder bodyBuilder,
  double? preferredHeight,
  bool expandable = false,
  GlassMorphAnchor? morphFrom,
}) async {
  final t = GrassBagTokens.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final tier = container.read(appProvider).glassTier;

  HapticFeedback.selectionClick();
  _grassBagOpenSheetDepth.value++;
  try {
    return await showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: t.isDark ? const Color(0x780D1017) : const Color(0x3B29293A),
    transitionDuration: const Duration(milliseconds: 260),
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
        tier: tier,
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
    required this.tier,
    required this.bodyBuilder,
  });

  final String title;
  final String? subtitle;
  final GrassBagGlassTier tier;
  final WidgetBuilder bodyBuilder;

  @override
  State<_IntrinsicLiquidGlassSheet> createState() => _IntrinsicLiquidGlassSheetState();
}

class _IntrinsicLiquidGlassSheetState extends State<_IntrinsicLiquidGlassSheet>
    with SingleTickerProviderStateMixin {
  late final SingleSpringController _dragSpring;
  bool _dragging = false;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _dragSpring = SingleSpringController(
      vsync: this,
      spring: GlassSpring.snappy(duration: const Duration(milliseconds: 300)),
      initialValue: 0.0,
    );
  }

  @override
  void dispose() {
    _dragSpring.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails _) {
    if (_dismissing) return;
    _dragging = true;
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
    final vel = d.primaryVelocity ?? 0.0;
    if (_dragSpring.value > 72.0 || vel > 520.0) {
      _dismissing = true;
      Navigator.of(context).pop();
    } else {
      _dragSpring.animateTo(0.0, fromVelocity: vel);
    }
  }

  void _onDragCancel() {
    if (_dismissing) return;
    _dragging = false;
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
      borderRadius: isDesktopDialog ? 26 : 32,
      elevated: true,
      useSheetSettings: true,
      padding: EdgeInsets.fromLTRB(16, isDesktopDialog ? 16 : 10, 16, 16),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
                    Center(
                      child: Container(
                          width: 36,
                          height: 4.5,
                          decoration: BoxDecoration(
                            color: t.isDark
                                ? Colors.white.withValues(alpha: 0.24)
                                : t.sepStrong,
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  widget.title,
                                  style: TextStyle(
                                    fontSize: 17.5,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: -0.35,
                                    color: t.text,
                                  ),
                                ),
                                if (widget.subtitle != null && widget.subtitle!.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Text(
                                      widget.subtitle!,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        height: 1.35,
                                        color: t.text3,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          GrassBagSpringTap(
                            onTap: () => Navigator.of(context).pop(),
                            pressedScale: 0.88,
                            haptic: true,
                            child: SizedBox(
                              width: 40,
                              height: 40,
                              child: Center(
                                child: Container(
                                  width: 30,
                                  height: 30,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: t.isDark
                                          ? [
                                              Colors.white.withValues(alpha: 0.16),
                                              Colors.white.withValues(alpha: 0.08),
                                            ]
                                          : [
                                              Colors.white.withValues(alpha: 0.78),
                                              const Color(0x14162E42),
                                            ],
                                    ),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: t.isDark
                                          ? Colors.white.withValues(alpha: 0.12)
                                          : const Color(0x16162E42),
                                      width: 0.55,
                                    ),
                                  ),
                                  child: Icon(
                                    CupertinoIcons.xmark,
                                    size: 13.5,
                                    color: t.text2,
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
              Flexible(
                child: RepaintBoundary(
                  child: SingleChildScrollView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
                    physics: const BouncingScrollPhysics(),
                    child: widget.bodyBuilder(context),
                  ),
                ),
              ),
            ],
          ),
        ),
    );

    return _SheetKeyboardFrame(
      size: size,
      viewPad: viewPad,
      isDesktopDialog: isDesktopDialog,
      child: ListenableBuilder(
        listenable: _dragSpring,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, _dragSpring.value),
          child: child,
        ),
        child: sheetCard,
      ),
    );
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

class _SheetKeyboardFrame extends StatefulWidget {
  const _SheetKeyboardFrame({
    required this.size,
    required this.viewPad,
    required this.isDesktopDialog,
    required this.child,
  });

  final Size size;
  final EdgeInsets viewPad;
  final bool isDesktopDialog;
  final Widget child;

  @override
  State<_SheetKeyboardFrame> createState() => _SheetKeyboardFrameState();
}

class _SheetKeyboardFrameState extends State<_SheetKeyboardFrame> {
  Timer? _settleTimer;
  double? _settledMaxH;
  double _lastKbInset = -1.0;
  double _lastViewportH = -1.0;

  @override
  void dispose() {
    _settleTimer?.cancel();
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
    final capH = widget.isDesktopDialog ? 700.0 : 660.0;
    final unclampedMaxH = math.min(capH, rawAvailableH).clamp(88.0, capH);
    final viewportResized =
        _lastViewportH > 0 && (widget.size.height - _lastViewportH).abs() > 1.0;

    // Keep `maxHeight` rock-steady during 120Hz IME flight (eliminating both 64px stair-step
    // snaps and per-frame `toImageSync` glass rebakes!) and settle ONCE 90ms after keyboard stops,
    // while immediately recomputing on rotation / split-screen viewport height changes.
    if (_settledMaxH == null || kbInset <= 0.5 || viewportResized) {
      _settleTimer?.cancel();
      _settledMaxH = unclampedMaxH;
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
    final effectiveMaxH = math.min(_settledMaxH ?? unclampedMaxH, capH);
    final desktopLiftY = widget.isDesktopDialog
        ? math.min(liftY * 0.5, math.max(0.0, (widget.size.height - topMargin - targetBottom) > 0 ? liftY : 0.0))
        : liftY;

    return Align(
      alignment: widget.isDesktopDialog ? Alignment.center : Alignment.bottomCenter,
      child: Transform.translate(
        offset: Offset(0, -desktopLiftY),
        child: MediaQuery.removeViewInsets(
          context: context,
          removeBottom: true,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, topMargin, 16, baseMargin),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: widget.isDesktopDialog ? 500 : 448,
                maxHeight: effectiveMaxH,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Concentric translucent card nested inside a floating sheet/dialog.
class _SheetSectionCard extends StatelessWidget {
  const _SheetSectionCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: t.isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.white.withValues(alpha: 0.68),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: t.isDark
                ? Colors.white.withValues(alpha: 0.10)
                : const Color(0x16162E42),
            width: 0.6,
          ),
        ),
      ),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
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
                                        GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () => _openRenameWorkspaceSheet(context, w),
                                          child: SizedBox(
                                            width: 32,
                                            height: 36,
                                            child: Center(
                                              child: Icon(CupertinoIcons.pencil, size: 15, color: t.text3),
                                            ),
                                          ),
                                        ),
                                        GestureDetector(
                                          behavior: HitTestBehavior.opaque,
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
                                            width: 32,
                                            height: 36,
                                            child: Center(
                                              child: Icon(CupertinoIcons.trash, size: 15, color: t.err),
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
          SingleChildScrollView(
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
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: t.errSoft,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(_browseError!, style: TextStyle(fontSize: 12, color: t.err)),
            ),
          ),
        Container(
          height: 240,
          decoration: BoxDecoration(
            color: t.fill1,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: t.sep, width: 0.5),
          ),
          child: _loading
              ? Center(child: CupertinoActivityIndicator(color: t.primary))
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
                  : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    if (_parentPath != null)
                      GrassBagListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        leading: Icon(CupertinoIcons.arrow_turn_up_left, size: 15, color: t.primary),
                        title: Text('.. (返回上级目录)', style: TextStyle(fontSize: 13, color: t.primary)),
                        onTap: () => _loadDir(_parentPath),
                      ),
                    if (_entries.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(18),
                        child: Center(
                          child: Text(
                            '此目录下没有子文件夹，可直接点击下方「挂载当前目录」',
                            style: TextStyle(fontSize: 12.5, color: t.text3),
                          ),
                        ),
                      )
                    else
                      for (final e in _entries)
                        GrassBagListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          leading: Icon(CupertinoIcons.folder_fill, size: 16, color: t.primary),
                          title: Text(
                            e['name']?.toString() ?? '',
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                          ),
                          showChevron: true,
                          onTap: () => _loadDir(e['path']?.toString()),
                        ),
                  ],
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
}) {
  const effortHints = {
    '关闭': '关闭长思考 · 最快直出',
    '低': '快速直出 · 低延迟',
    '中': '均衡思考 · 日常推荐',
    '高': '深度多步 · 复杂工程',
    '超高': '强推理深度 · 复杂排查',
    '极高': '最高推理预算 · 极限质量',
  };

  showGrassBagSheet(
    context,
    title: '模型与思考深度',
    subtitle: '支持关键词筛选与渠道折叠，选择后同步写入默认模型与当前会话',
    preferredHeight: 540,
    morphFrom: morphFrom,
    bodyBuilder: (ctx) => _SearchableModelSheetBody(
      outerContext: context,
      effortHints: effortHints,
      onOpenModelSettings: onOpenModelSettings,
    ),
  );
}

class _SearchableModelSheetBody extends ConsumerStatefulWidget {
  const _SearchableModelSheetBody({
    required this.outerContext,
    required this.effortHints,
    this.onOpenModelSettings,
  });
  final BuildContext outerContext;
  final Map<String, String> effortHints;
  final VoidCallback? onOpenModelSettings;

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
        if (g.models.length <= 6 ||
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              color: t.fill1,
              borderRadius: BorderRadius.circular(12),
            ),
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
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() {
                      if (!_expandedGroups.add(g.id)) _expandedGroups.remove(g.id);
                    }),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(4, gIdx == 0 ? 0 : 12, 4, 6),
                      child: Row(
                        children: [
                          Icon(
                            isExpanded ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_right,
                            size: 12,
                            color: t.text3,
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
                          if (!isExpanded)
                            Text(
                              '点击展开',
                              style: TextStyle(fontSize: 11, color: t.text3),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (isExpanded)
                    _SheetSectionCard(
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
                              badge: g.routable ? null : '需配置密钥',
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
                                ctrl.setModel(
                                  m.name,
                                  m.shortLabel,
                                  provider: g.id,
                                  modelId: m.id,
                                  effortId: m.efforts.any((e) => e.id == state.modelEffortId)
                                      ? state.modelEffortId
                                      : m.defaultEffort,
                                );
                                Navigator.of(context).pop();
                              },
                            );
                          }(),
                          if (i < list.length - 1)
                            Divider(height: 0.5, indent: 60, endIndent: 14, color: t.sep),
                        ],
                      ],
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
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: ctxColor.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(999),
                            ),
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
                      // Stacked breakdown bar when DSH reports contextBreakdown, else smooth single bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          height: 10,
                          color: t.fill1,
                          child: hasBreakdown
                              ? Row(
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
                                )
                              : FractionallySizedBox(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: (state.contextPct / 100.0).clamp(0.02, 1.0),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: state.contextPct >= 85
                                          ? t.err
                                          : (state.contextPct >= 65 ? t.warn : t.primary),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (hasBreakdown) ...[
                        Row(
                          children: [
                            Expanded(
                              child: _LegendDot(
                                color: t.dusk,
                                label: '系统提示',
                                value: formatCompactTokens(tel.systemTokens),
                              ),
                            ),
                            Expanded(
                              child: _LegendDot(
                                color: t.ok,
                                label: '工具定义',
                                value: formatCompactTokens(tel.toolsTokens),
                              ),
                            ),
                            Expanded(
                              child: _LegendDot(
                                color: t.primary,
                                label: '对话消息',
                                value: formatCompactTokens(tel.messageTokens),
                              ),
                            ),
                            if (tel.remainingContextTokens > 0)
                              Expanded(
                                child: _LegendDot(
                                  color: t.text3.withValues(alpha: 0.45),
                                  label: '剩余可用',
                                  value: formatCompactTokens(tel.remainingContextTokens),
                                ),
                              ),
                          ],
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
                    label: '精简上下文',
                    icon: CupertinoIcons.wand_stars,
                    tier: state.glassTier,
                    insideGlass: true,
                    onTap: () {
                      ctrl.compactContext();
                      Navigator.of(ctx).pop();
                    },
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
                    label: '手动 / 发现设备',
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
              const SizedBox(height: 8),
              GrassBagSecondaryGlassButton(
                label: '管理全部主机与详情',
                icon: CupertinoIcons.tray_2_fill,
                tier: state.glassTier,
                insideGlass: true,
                onTap: () {
                  Navigator.of(ctx).pop();
                  onOpenHostSettings();
                },
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
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

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
            label: '使用 App 内网页登录（适用于反代 / 网页认证）',
            icon: CupertinoIcons.globe,
            tier: tier,
            insideGlass: true,
            onTap: _openWebLogin,
          ),
        ],
        const SizedBox(height: 8),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
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
        // Avoid AnimatedSize inside a GrassBagGlass sheet so toggling help triggers ONE
        // layout pass instead of 22 consecutive `toImageSync` glass matte rebuilds.
        if (_showHelp)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: t.fill1,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.sep, width: 0.6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.host.isDesktopLanBridge
                      ? '桌面端 :3081 桥接令牌保存在电脑的 ~/.dsh/gbridge-lan-token；也可点击下方复制一键指令发给电脑端 AI 自动提取完整链接。'
                      : '在电脑端运行 dsh web --host <局域网IP> 后会打印包含 ?token=... 的完整链接；或直接把一键指令发给电脑端 DeepSeek Harness 自动生成。',
                  style: TextStyle(fontSize: 11.5, height: 1.42, color: t.text2),
                ),
                const SizedBox(height: 8),
                GrassBagSecondaryGlassButton(
                  label: '复制桌面端一键指令',
                  icon: CupertinoIcons.sparkles,
                  height: 34,
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
  showGrassBagSheet(
    context,
    title: filePath,
    subtitle: '工作区 Git 改动详情',
    preferredHeight: 396,
    expandable: true,
    bodyBuilder: (ctx) => _DiffSheetBody(filePath: filePath, record: record),
  );
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
  static const int _kDiffLinePageSize = 400;

  bool _loading = false;
  int _visibleLineCap = _kDiffLinePageSize;
  String? _cachedRawDiff;
  List<(String, String, String)> _cachedLines = const [];
  int _cachedMaxVisualUnits = 40;

  @override
  void initState() {
    super.initState();
    final initial = widget.record ??
        _matchDiffRecord(ref.read(appProvider).workspaceDiffs, widget.filePath);
    if (initial == null || initial.unifiedDiff.isEmpty) {
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _refreshDiffs());
    }
  }

  Future<void> _refreshDiffs() async {
    if (mounted && !_loading) setState(() => _loading = true);
    try {
      await ref.read(appProvider.notifier).refreshWorkspaceDiffs(silent: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _ensureParsed(String rawDiff) {
    if (_cachedRawDiff == rawDiff) return;
    _cachedRawDiff = rawDiff;
    _visibleLineCap = _kDiffLinePageSize;
    if (rawDiff.isEmpty) {
      _cachedLines = const [];
      _cachedMaxVisualUnits = 40;
      return;
    }
    final rawLines = rawDiff.split('\n');
    // Drop single phantom trailing empty line caused by trailing `\n` in unified diffs.
    final lineLimit = rawLines.isNotEmpty && rawLines.last.isEmpty
        ? rawLines.length - 1
        : rawLines.length;
    final parsed = <(String, String, String)>[];
    var oldLine = 0;
    var newLine = 0;
    var inHunk = false;
    var maxVisualUnits = 40;
    for (var i = 0; i < lineLimit; i++) {
      final l = rawLines[i];
      final m = _hunkRe.firstMatch(l);
      (String, String, String) row;
      if (m != null) {
        oldLine = int.tryParse(m.group(1) ?? '1') ?? 1;
        newLine = int.tryParse(m.group(2) ?? '1') ?? 1;
        inHunk = true;
        row = ('@', '@@', l);
      } else if (l.startsWith('diff ') ||
          l.startsWith('index ') ||
          l.startsWith('--- ') ||
          l.startsWith('+++ ')) {
        row = ('~', '', l);
      } else if (l.startsWith('+')) {
        final numStr = inHunk ? '${newLine++}' : '${i + 1}';
        row = ('+', numStr, l.substring(1));
      } else if (l.startsWith('-')) {
        final numStr = inHunk ? '${oldLine++}' : '${i + 1}';
        row = ('-', numStr, l.substring(1));
      } else if (l.startsWith(r'\')) {
        row = ('~', '', l);
      } else {
        final numStr = inHunk ? '${newLine++}' : '${i + 1}';
        if (inHunk) oldLine++;
        row = (' ', numStr, l.startsWith(' ') ? l.substring(1) : l);
      }
      parsed.add(row);
      var units = 0;
      for (final cu in row.$3.codeUnits) {
        units += cu > 0x7F ? 2 : 1;
      }
      if (units > maxVisualUnits) maxVisualUnits = units;
    }
    _cachedLines = parsed;
    _cachedMaxVisualUnits = maxVisualUnits;
  }

  @override
  Widget build(BuildContext context) {
    final diffs = ref.watch(appProvider.select((s) => s.workspaceDiffs));
    final matched = (widget.record != null && widget.record!.unifiedDiff.isNotEmpty)
        ? widget.record
        : (_matchDiffRecord(diffs, widget.filePath) ?? widget.record);
    final rawDiff = matched?.unifiedDiff ?? '';
    _ensureParsed(rawDiff);
    final lines = _cachedLines;
    final added = matched?.added ?? 0;
    final removed = matched?.removed ?? 0;
    final t = GrassBagTokens.of(context);
    if (lines.isEmpty) {
      if (_loading) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CupertinoActivityIndicator(radius: 10, color: t.primary),
              const SizedBox(width: 10),
              Text('正在加载工作区 Git 差异…', style: TextStyle(fontSize: 13, color: t.text2)),
            ],
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '当前工作区未检测到该文件的详细 Unified Diff。',
              style: TextStyle(fontSize: 13, color: t.text3),
            ),
            const SizedBox(height: 12),
            GrassBagSecondaryGlassButton(
              label: '重新加载差异',
              icon: CupertinoIcons.refresh,
              tier: ref.read(appProvider).glassTier,
              insideGlass: true,
              onTap: _refreshDiffs,
            ),
          ],
        ),
      );
    }
    final diffContentWidth = (_cachedMaxVisualUnits * 7.4 + 98.0).clamp(320.0, 6000.0);
    final visibleCount = math.min(lines.length, _visibleLineCap);
    final hiddenLines = lines.length - visibleCount;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Text('改动统计', style: TextStyle(fontSize: 12, color: t.text3)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: t.okSoft,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '+$added',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: t.ok,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: t.errSoft,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '-$removed',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: t.err,
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: t.codeBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10), width: 0.6),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                color: t.codeBar,
                child: Row(
                  children: [
                    _WindowDot(color: const Color(0xFFFF5F57).withValues(alpha: 0.78)),
                    const SizedBox(width: 6),
                    _WindowDot(color: const Color(0xFFFEBC2E).withValues(alpha: 0.78)),
                    const SizedBox(width: 6),
                    _WindowDot(color: const Color(0xFF28C840).withValues(alpha: 0.78)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.filePath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ),
                    Text(
                      '+$added',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF5DD199),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '-$removed',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFF08A84),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GrassBagSpringTap(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: rawDiff));
                        ref.read(appProvider.notifier).showToast('已复制改动补丁');
                      },
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(CupertinoIcons.doc_on_doc, size: 12, color: Color(0xFFCBD5E1)),
                          SizedBox(width: 3),
                          Text(
                            '复制',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFCBD5E1),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: RepaintBoundary(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final effectiveW = math.max(box.maxWidth, diffContentWidth);
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: effectiveW,
                          child: SelectionArea(
                            contextMenuBuilder: buildGrassBagSelectableContextMenu,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var idx = 0; idx < visibleCount; idx++)
                                  () {
                                    final line = lines[idx];
                                    return Container(
                                      color: switch (line.$1) {
                                        '+' => const Color(0x261F9D63),
                                        '-' => const Color(0x2AD14E4E),
                                        '@' => const Color(0x243B82F6),
                                        _ => Colors.transparent,
                                      },
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3.5),
                                      child: Row(
                                        children: [
                                          SizedBox(
                                            width: 44,
                                            child: Text(
                                              line.$2,
                                              textAlign: TextAlign.right,
                                              style: const TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 11,
                                                fontFeatures: [FontFeature.tabularFigures()],
                                                color: Color(0xFF64748B),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          SizedBox(
                                            width: 14,
                                            child: Text(
                                              line.$1 == '@' || line.$1 == '~' ? ' ' : line.$1,
                                              style: TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w700,
                                                color: switch (line.$1) {
                                                  '+' => const Color(0xFF5DD199),
                                                  '-' => const Color(0xFFF08A84),
                                                  _ => const Color(0xFF64748B),
                                                },
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            child: Text(
                                              line.$3,
                                              softWrap: false,
                                              overflow: TextOverflow.visible,
                                              style: TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 11.5,
                                                height: 1.45,
                                                color: line.$1 == '@'
                                                    ? const Color(0xFF93C5FD)
                                                    : (line.$1 == '~'
                                                        ? const Color(0xFF64748B)
                                                        : t.codeFg),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }(),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              if (hiddenLines > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GrassBagSpringTap(
                        onTap: () => setState(() => _visibleLineCap += _kDiffLinePageSize),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '展开更多（剩余 $hiddenLines 行）',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF93C5FD),
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
      ],
    );
  }
}

void showCommandOutputSheet(
  BuildContext context, {
  required String command,
  required bool failed,
  String? outputText,
  required VoidCallback onOpenTerminal,
}) {
  final rawText = (outputText ?? '').trim();
  final rawLines = rawText.isEmpty ? const <String>['（暂无标准输出）'] : rawText.split('\n');

  showGrassBagSheet(
    context,
    title: '命令输出',
    subtitle: failed ? '执行返回非零状态' : '命令执行结果',
    expandable: true,
    bodyBuilder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final t = GrassBagTokens.of(ctx);
        final tier = ref.watch(appProvider.select((s) => s.glassTier));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRSuperellipse(
              borderRadius: BorderRadius.circular(20),
              child: Container(
                decoration: BoxDecoration(
                  color: t.codeBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.10), width: 0.6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      color: t.codeBar,
                      child: Row(
                        children: [
                          _WindowDot(color: const Color(0xFFFF5F57).withValues(alpha: 0.78)),
                          const SizedBox(width: 6),
                          _WindowDot(color: const Color(0xFFFEBC2E).withValues(alpha: 0.78)),
                          const SizedBox(width: 6),
                          _WindowDot(color: const Color(0xFF28C840).withValues(alpha: 0.78)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '\$ $command',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF8CB9D7),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 340),
                      child: SelectionArea(
                        contextMenuBuilder: buildGrassBagSelectableContextMenu,
                        child: ListView.builder(
                          shrinkWrap: rawLines.length <= 24,
                          padding: const EdgeInsets.all(14),
                          itemCount: rawLines.length,
                          itemBuilder: (_, idx) => Text(
                            rawLines[idx],
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.8,
                              height: 1.48,
                              color: failed
                                  ? const Color(0xFFFCA5A5)
                                  : const Color(0xFFD5DCE4),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: GrassBagSecondaryGlassButton(
                    label: '复制输出',
                    icon: CupertinoIcons.doc_on_doc,
                    tier: tier,
                    insideGlass: true,
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: rawText.isEmpty ? command : rawText));
                      ProviderScope.containerOf(ctx, listen: false)
                          .read(appProvider.notifier)
                          .showToast('已复制输出到剪贴板', tone: ToastTone.ok);
                      Navigator.of(ctx).pop();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GrassBagSecondaryGlassButton(
                    label: '在终端中打开',
                    icon: CupertinoIcons.chevron_left_slash_chevron_right,
                    tier: tier,
                    insideGlass: true,
                    onTap: () {
                      Navigator.of(ctx).pop();
                      onOpenTerminal();
                    },
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

class _WindowDot extends StatelessWidget {
  const _WindowDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        color: selected
            ? accent.withValues(alpha: t.isDark ? 0.14 : 0.08)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            GrassBagSquircleIcon(
              icon: icon,
              color: selected && t.isDark
                  ? Color.lerp(iconColor, t.cardSolid, 0.25)!
                  : iconColor,
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
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: warnTone
                                ? t.warnSoft
                                : iconColor.withValues(alpha: t.isDark ? 0.22 : 0.13),
                            borderRadius: BorderRadius.circular(999),
                          ),
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
            if (selected) ...[
              const SizedBox(width: 6),
              Icon(
                CupertinoIcons.checkmark_circle_fill,
                size: 21,
                color: accent,
              ),
            ],
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

/// Real Deliverable Preview Sheet (loads real workspace text/image bytes from DSH, zero hardcoded demo cards).
void showDeliverablePreviewSheet(
  BuildContext context,
  WidgetRef ref, {
  required String name,
  String? path,
  String subtitle = '生成产物',
  String sizeLabel = '',
}) {
  showGrassBagSheet<void>(
    context,
    title: name,
    subtitle: sizeLabel.isEmpty ? subtitle : '$subtitle · $sizeLabel',
    bodyBuilder: (ctx) => _DeliverablePreviewBody(name: name, path: path),
  );
}

class _DeliverablePreviewBody extends ConsumerStatefulWidget {
  const _DeliverablePreviewBody({required this.name, this.path});
  final String name;
  final String? path;

  @override
  ConsumerState<_DeliverablePreviewBody> createState() => _DeliverablePreviewBodyState();
}

class _DeliverablePreviewBodyState extends ConsumerState<_DeliverablePreviewBody> {
  bool _loading = true;
  String? _textContent;
  Uint8List? _imageBytes;
  String? _errorMsg;
  bool _truncated = false;
  int _totalLines = 0;
  String _resolvedPath = '';

  static bool _isImageName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _errorMsg = null;
      });
    }
    try {
      final state = ref.read(appProvider);
      final ctrl = ref.read(appProvider.notifier);
      String targetPath = (widget.path != null && widget.path!.trim().isNotEmpty)
          ? widget.path!.trim()
          : widget.name;
      if (widget.path == null || widget.path!.trim().isEmpty) {
        bool found = false;
        void findFile(List<WorkspaceFileNode> nodes) {
          for (final n in nodes) {
            if (found) return;
            if (!n.isDir &&
                (n.name == widget.name ||
                    n.path == widget.name ||
                    n.path.endsWith('/${widget.name}'))) {
              targetPath = n.path;
              found = true;
              return;
            }
            if (n.children.isNotEmpty) findFile(n.children);
          }
        }
        findFile(state.workspaceFiles);
      }
      _resolvedPath = targetPath;

      if (_isImageName(targetPath) || _isImageName(widget.name)) {
        final bytes = await ctrl.readWorkspaceFileBytes(targetPath);
        if (!mounted) return;
        setState(() {
          _loading = false;
          if (bytes != null && bytes.isNotEmpty) {
            _imageBytes = bytes;
          } else {
            _errorMsg = '无法从当前主机加载该图片文件内容。';
          }
        });
        return;
      }

      final page = await ctrl.readWorkspaceFilePage(targetPath, offset: 1, limit: 240);
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (page['error'] == true) {
          _errorMsg = page['text']?.toString() ?? '无法读取产物文件。';
        } else if (page['binary'] == true) {
          _errorMsg = '该产物为二进制文件，暂不支持直接文本预览。';
        } else {
          _textContent = page['text']?.toString() ?? '';
          _truncated = page['truncated'] == true || page['eof'] == false;
          _totalLines = (page['totalLines'] as num?)?.toInt() ?? 0;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMsg = '读取产物失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final ctrl = ref.read(appProvider.notifier);
    final isImage = _imageBytes != null;
    final canCopy = !_loading && _errorMsg == null && (isImage || _textContent != null);
    final copyable = isImage
        ? (_resolvedPath.isNotEmpty ? _resolvedPath : widget.name)
        : (_textContent ?? (_resolvedPath.isNotEmpty ? _resolvedPath : widget.name));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_truncated) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: t.warnSoft,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Text(
              _totalLines > 0
                  ? '文件较大，当前仅预览前 240 行（共 $_totalLines 行），可在工作区文件浏览器中分页查看完整内容。'
                  : '文件较大，当前仅预览前 240 行。',
              style: TextStyle(fontSize: 11.5, color: t.warn),
            ),
          ),
        ],
        Container(
          constraints: const BoxConstraints(minHeight: 160, maxHeight: 360),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: t.fill1,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: t.sep, width: 0.6),
          ),
          child: _loading
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CupertinoActivityIndicator(radius: 11, color: t.primary),
                      const SizedBox(height: 10),
                      Text('正在从主机读取 ${widget.name}…', style: TextStyle(fontSize: 12.5, color: t.text3)),
                    ],
                  ),
                )
              : isImage
                  ? GestureDetector(
                      onTap: () => showImagePreviewDialog(
                        context,
                        bytes: _imageBytes,
                        title: widget.name,
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.memory(
                              _imageBytes!,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => Center(
                                child: Text('图片格式不受支持或数据损坏', style: TextStyle(fontSize: 12.5, color: t.text3)),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 8,
                            bottom: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.56),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(CupertinoIcons.zoom_in, size: 12, color: Colors.white),
                                  SizedBox(width: 4),
                                  Text(
                                    '点击全屏缩放',
                                    style: TextStyle(fontSize: 10.5, color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : _errorMsg != null
                      ? Text(_errorMsg!, style: TextStyle(fontSize: 12.5, height: 1.5, color: t.text2))
                      : SingleChildScrollView(
                          child: SelectableText(
                            _textContent!.isEmpty ? '（文件内容为空）' : _textContent!,
                            contextMenuBuilder: buildGrassBagEditableContextMenu,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.5,
                              color: t.text,
                            ),
                          ),
                        ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: isImage ? '复制路径' : (_truncated ? '复制预览内容' : '复制内容'),
                icon: CupertinoIcons.doc_on_doc,
                tier: tier,
                insideGlass: true,
                enabled: canCopy,
                onTap: !canCopy
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: copyable));
                        ctrl.showToast(
                          isImage
                              ? '已复制图片路径：$copyable'
                              : (_truncated
                                  ? '已复制 ${widget.name} 前 240 行预览内容'
                                  : '已复制 ${widget.name} 内容'),
                        );
                      },
              ),
            ),
            if (!isImage) ...[
              const SizedBox(width: 10),
              Expanded(
                child: GrassBagPrimaryGlassButton(
                  label: _truncated ? '分享预览' : '分享 / 导出',
                  icon: CupertinoIcons.share,
                  tier: tier,
                  insideGlass: true,
                  enabled: !_loading && _errorMsg == null && _textContent != null,
                  onTap: (_loading || _errorMsg != null || _textContent == null)
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          if (GrassBagNativeBridge.instance.isAndroidNative) {
                            GrassBagNativeBridge.instance
                                .shareText('GrassBag 产物 ${widget.name}\n\n$copyable');
                          } else {
                            Clipboard.setData(ClipboardData(text: copyable));
                          }
                          ctrl.showToast(
                            _truncated
                                ? '已准备好导出 ${widget.name}（前 240 行预览）'
                                : '已准备好导出 ${widget.name}',
                          );
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
    final t = GrassBagTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: widget.speechConfigured ? t.primarySoft : t.fill1,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: widget.speechConfigured ? t.primary.withValues(alpha: 0.28) : t.sep,
              width: 0.7,
            ),
          ),
          child: Row(
            children: [
              Icon(
                CupertinoIcons.mic_fill,
                size: 18,
                color: widget.speechConfigured ? t.primary : t.text3,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '请点按下方输入框，通过系统输入法麦克风完成语音听写后确认填入。',
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text2),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GrassBagTextField(
          controller: _ctrl,
          autofocus: true,
          maxLines: 4,
          minLines: 2,
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

/// Fullscreen pinch-zoom image lightbox preview for composer attachments, sent photos, and Markdown images.
void showImagePreviewDialog(
  BuildContext context, {
  Uint8List? bytes,
  String? url,
  String? title,
}) {
  if ((bytes == null || bytes.isEmpty) && (url == null || url.isEmpty)) return;
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭图片预览',
    barrierColor: Colors.black.withValues(alpha: 0.90),
    transitionDuration: const Duration(milliseconds: 220),
    transitionBuilder: (ctx, anim, _, child) => _ImageLightboxRouteTransition(
      animation: anim,
      child: child,
    ),
    pageBuilder: (ctx, _, __) {
      return _GrassBagImageLightbox(
        bytes: bytes,
        url: url,
        title: title,
      );
    },
  );
}

class _ImageLightboxRouteTransition extends StatefulWidget {
  const _ImageLightboxRouteTransition({
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
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
    return FadeTransition(
      opacity: _curve,
      child: ScaleTransition(
        scale: _scale,
        child: widget.child,
      ),
    );
  }
}

class _GrassBagImageLightbox extends StatefulWidget {
  const _GrassBagImageLightbox({
    required this.bytes,
    required this.url,
    required this.title,
  });

  final Uint8List? bytes;
  final String? url;
  final String? title;

  @override
  State<_GrassBagImageLightbox> createState() => _GrassBagImageLightboxState();
}

class _GrassBagImageLightboxState extends State<_GrassBagImageLightbox>
    with SingleTickerProviderStateMixin {
  final TransformationController _transformCtrl = TransformationController();
  late final AnimationController _zoomCtrl;
  Animation<Matrix4>? _zoomAnim;
  Offset _doubleTapLocalPos = Offset.zero;

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
        }
      });
  }

  @override
  void dispose() {
    _zoomCtrl.dispose();
    _transformCtrl.dispose();
    super.dispose();
  }

  double get _currentScale => _transformCtrl.value.getMaxScaleOnAxis();

  void _toggleZoom() {
    final begin = Matrix4.copy(_transformCtrl.value);
    final Matrix4 end;
    if (_currentScale > 1.05) {
      end = Matrix4.identity();
    } else {
      const targetScale = 2.4;
      final fx = _doubleTapLocalPos.dx;
      final fy = _doubleTapLocalPos.dy;
      end = Matrix4.identity()
        ..translateByDouble(-fx * (targetScale - 1.0), -fy * (targetScale - 1.0), 0.0, 1.0)
        ..scaleByDouble(targetScale, targetScale, 1.0, 1.0);
    }
    _zoomAnim = Matrix4Tween(begin: begin, end: end).animate(
      CurvedAnimation(parent: _zoomCtrl, curve: Curves.easeOutCubic),
    );
    _zoomCtrl.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                // Only dismiss when unzoomed so tapping a zoomed photo never unexpectedly exits!
                if (_currentScale <= 1.02) {
                  Navigator.of(context).pop();
                }
              },
              onDoubleTapDown: (d) => _doubleTapLocalPos = d.localPosition,
              onDoubleTap: _toggleZoom,
              child: InteractiveViewer(
                transformationController: _transformCtrl,
                minScale: 0.7,
                maxScale: 4.0,
                child: Center(
                  child: widget.bytes != null && widget.bytes!.isNotEmpty
                      ? Image.memory(
                          widget.bytes!,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              '图片解码失败',
                              style: TextStyle(color: Colors.white70, fontSize: 14),
                            ),
                          ),
                        )
                      : Image.network(
                          widget.url!,
                          fit: BoxFit.contain,
                          loadingBuilder: (_, child, progress) {
                            if (progress == null) return child;
                            return const CupertinoActivityIndicator(
                              radius: 13,
                              color: Colors.white,
                            );
                          },
                          errorBuilder: (_, __, ___) => const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              '图片加载失败',
                              style: TextStyle(color: Colors.white70, fontSize: 14),
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: topPad + 72,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.68),
                      Colors.black.withValues(alpha: 0.24),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: topPad + 10,
            left: 16,
            right: 16,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title ?? '图片预览',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      shadows: [
                        Shadow(
                          color: Color(0x88000000),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Solid translucent close orb so FadeTransition route never wraps live GLSL shaders!
                GrassBagGlassCircleButton(
                  icon: CupertinoIcons.xmark,
                  size: 38,
                  iconSize: 16,
                  iconColor: Colors.white,
                  tintColor: const Color(0xCC12161E),
                  tooltip: '关闭预览',
                  tier: GrassBagGlassTier.solid,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
