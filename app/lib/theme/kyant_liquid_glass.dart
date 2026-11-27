import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'grassbag_theme.dart';

/// Highlight shader style matching Kyant0 `HighlightStyle.kt`.
enum KyantHighlightKind {
  none(-1.0),
  defaultSpecular(0.0),
  ambient(1.0),
  plain(2.0);

  const KyantHighlightKind(this.shaderValue);
  final double shaderValue;
}

/// Complete optical configuration matching Kyant0 `AndroidLiquidGlass` `drawBackdrop` pipeline:
/// `colorControls/vibrancy -> blur -> lens(refractionHeight, refractionAmount, depthEffect, chromaticAberration) -> tint/surface -> innerShadow -> highlight -> shadow`.
@immutable
class KyantLiquidGlassStyle {
  const KyantLiquidGlassStyle({
    this.blurRadius = 2.0,
    this.refractionHeight = 12.0,
    this.refractionAmount = 24.0,
    this.depthEffect = false,
    this.chromaticAberration = 0.0,
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.5,
    this.surfaceColor = Colors.transparent,
    this.tintColor = Colors.transparent,
    this.highlightKind = KyantHighlightKind.defaultSpecular,
    this.highlightAlpha = 0.50,
    this.highlightAngleDeg = 45.0,
    this.highlightFalloff = 1.0,
    this.highlightWidth = 0.65,
    this.highlightBlur = 0.30,
    this.innerShadowRadius = 0.0,
    this.innerShadowAlpha = 0.0,
    this.ambientEdgeDarken = 0.0,
    this.shadows = const <BoxShadow>[],
  });

  final double blurRadius;
  final double refractionHeight;
  final double refractionAmount;
  final bool depthEffect;
  final double chromaticAberration;
  final double brightness;
  final double contrast;
  final double saturation;
  final Color surfaceColor;
  final Color tintColor;
  final KyantHighlightKind highlightKind;
  final double highlightAlpha;
  final double highlightAngleDeg;
  final double highlightFalloff;
  final double highlightWidth;
  final double highlightBlur;
  final double innerShadowRadius;
  final double innerShadowAlpha;
  final double ambientEdgeDarken;
  final List<BoxShadow> shadows;

  KyantLiquidGlassStyle copyWith({
    double? blurRadius,
    double? refractionHeight,
    double? refractionAmount,
    bool? depthEffect,
    double? chromaticAberration,
    double? brightness,
    double? contrast,
    double? saturation,
    Color? surfaceColor,
    Color? tintColor,
    KyantHighlightKind? highlightKind,
    double? highlightAlpha,
    double? highlightAngleDeg,
    double? highlightFalloff,
    double? highlightWidth,
    double? highlightBlur,
    double? innerShadowRadius,
    double? innerShadowAlpha,
    double? ambientEdgeDarken,
    List<BoxShadow>? shadows,
  }) {
    return KyantLiquidGlassStyle(
      blurRadius: blurRadius ?? this.blurRadius,
      refractionHeight: refractionHeight ?? this.refractionHeight,
      refractionAmount: refractionAmount ?? this.refractionAmount,
      depthEffect: depthEffect ?? this.depthEffect,
      chromaticAberration: chromaticAberration ?? this.chromaticAberration,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      surfaceColor: surfaceColor ?? this.surfaceColor,
      tintColor: tintColor ?? this.tintColor,
      highlightKind: highlightKind ?? this.highlightKind,
      highlightAlpha: highlightAlpha ?? this.highlightAlpha,
      highlightAngleDeg: highlightAngleDeg ?? this.highlightAngleDeg,
      highlightFalloff: highlightFalloff ?? this.highlightFalloff,
      highlightWidth: highlightWidth ?? this.highlightWidth,
      highlightBlur: highlightBlur ?? this.highlightBlur,
      innerShadowRadius: innerShadowRadius ?? this.innerShadowRadius,
      innerShadowAlpha: innerShadowAlpha ?? this.innerShadowAlpha,
      ambientEdgeDarken: ambientEdgeDarken ?? this.ambientEdgeDarken,
      shadows: shadows ?? this.shadows,
    );
  }

  /// Kyant0 `LiquidButton` optical recipe (vibrancy + 2dp blur + lens(12, 24) + Highlight.Default).
  static KyantLiquidGlassStyle button(
    GrassBagTokens t,
    GrassBagGlassTier tier, {
    Color? tint,
    Color? surfaceColor,
    bool elevated = false,
  }) {
    final isFrosted = tier == GrassBagGlassTier.frosted || kIsWeb;
    final hasTint = tint != null && tint.a > 0.001;
    final resolvedSurface = surfaceColor ??
        (hasTint
            ? Colors.transparent
            : (t.isDark
                ? const Color(0xFF181C24).withValues(alpha: isFrosted ? 0.44 : 0.30)
                : const Color(0xFFFAFAFA).withValues(alpha: isFrosted ? 0.62 : 0.42)));
    return KyantLiquidGlassStyle(
      blurRadius: isFrosted ? 8.0 : 2.5,
      refractionHeight: isFrosted ? 0.0 : 12.0,
      refractionAmount: isFrosted ? 0.0 : 24.0,
      depthEffect: false,
      chromaticAberration: isFrosted ? 0.0 : 0.16,
      brightness: 0.0,
      contrast: 1.0,
      saturation: isFrosted ? 1.15 : 1.5,
      surfaceColor: resolvedSurface,
      tintColor: hasTint ? tint.withValues(alpha: t.isDark ? 0.72 : 0.78) : Colors.transparent,
      highlightKind: KyantHighlightKind.defaultSpecular,
      highlightAlpha: hasTint
          ? (t.isDark ? 0.56 : 0.68)
          : (t.isDark ? 0.46 : 0.68),
      highlightAngleDeg: 45.0,
      highlightFalloff: 1.25,
      highlightWidth: 0.68,
      highlightBlur: 0.28,
      ambientEdgeDarken: (!t.isDark && !hasTint) ? 0.07 : 0.0,
      shadows: [
        BoxShadow(
          color: hasTint
              ? tint.withValues(alpha: t.isDark ? 0.30 : 0.22)
              : Colors.black.withValues(alpha: t.isDark ? (elevated ? 0.28 : 0.18) : (elevated ? 0.10 : 0.07)),
          blurRadius: elevated ? 20.0 : 14.0,
          offset: Offset(0, elevated ? 5.0 : 3.5),
        ),
      ],
    );
  }

  /// Kyant0 floating chrome recipe for navigation pills, composer dock, search capsules, and toasts.
  static KyantLiquidGlassStyle chrome(
    GrassBagTokens t,
    GrassBagGlassTier tier, {
    bool elevated = false,
    Color? tintColor,
  }) {
    final isFrosted = tier == GrassBagGlassTier.frosted || kIsWeb;
    final hasTint = tintColor != null && tintColor.a > 0.001;
    final surface = hasTint
        ? tintColor
        : (t.isDark
            ? const Color(0xFF141820).withValues(alpha: isFrosted ? 0.60 : (elevated ? 0.48 : 0.40))
            : const Color(0xFFFAFAFA).withValues(alpha: isFrosted ? 0.74 : (elevated ? 0.62 : 0.52)));
    return KyantLiquidGlassStyle(
      blurRadius: isFrosted ? 12.0 : (elevated ? 6.0 : 4.0),
      refractionHeight: isFrosted ? 0.0 : (elevated ? 16.0 : 14.0),
      refractionAmount: isFrosted ? 0.0 : (elevated ? 28.0 : 24.0),
      depthEffect: false,
      chromaticAberration: isFrosted ? 0.0 : 0.18,
      brightness: (!t.isDark && !isFrosted) ? 0.04 : 0.0,
      contrast: 1.0,
      saturation: isFrosted ? 1.15 : 1.5,
      surfaceColor: surface,
      highlightKind: KyantHighlightKind.defaultSpecular,
      highlightAlpha: t.isDark ? 0.44 : 0.72,
      highlightAngleDeg: 45.0,
      highlightFalloff: 1.3,
      highlightWidth: 0.68,
      highlightBlur: 0.28,
      ambientEdgeDarken: t.isDark ? 0.0 : 0.075,
      shadows: [
        BoxShadow(
          color: Colors.black.withValues(
            alpha: t.isDark ? (elevated ? 0.34 : 0.22) : (elevated ? 0.11 : 0.075),
          ),
          blurRadius: elevated ? 22.0 : 14.0,
          offset: Offset(0, elevated ? 6.0 : 4.0),
        ),
      ],
    );
  }

  /// Kyant0 `DialogContent` / modal sheet / '+' deck / floating drawer recipe:
  /// `colorControls(brightness: 0.12 Light / 0 Dark, saturation: 1.5) + blur(10..14dp) + lens(20, 38, depthEffect: true) + Highlight.Plain`.
  static KyantLiquidGlassStyle sheet(
    GrassBagTokens t,
    GrassBagGlassTier tier, {
    bool isDialog = false,
    Color? tintColor,
  }) {
    final isFrosted = tier == GrassBagGlassTier.frosted || kIsWeb;
    final hasTint = tintColor != null && tintColor.a > 0.001;
    final surface = hasTint
        ? tintColor
        : (t.isDark
            ? const Color(0xFF141820).withValues(alpha: isDialog ? 0.56 : 0.54)
            : const Color(0xFFFAFAFA).withValues(alpha: isDialog ? 0.70 : 0.68));
    return KyantLiquidGlassStyle(
      blurRadius: isFrosted ? 14.0 : (t.isDark ? (isDialog ? 9.0 : 8.0) : (isDialog ? 14.0 : 10.0)),
      refractionHeight: isFrosted ? 0.0 : (isDialog ? 22.0 : 18.0),
      refractionAmount: isFrosted ? 0.0 : (isDialog ? 42.0 : 34.0),
      depthEffect: !isFrosted && isDialog,
      chromaticAberration: isFrosted ? 0.0 : 0.14,
      brightness: (!t.isDark && !isFrosted) ? (isDialog ? 0.12 : 0.06) : 0.0,
      contrast: 1.0,
      saturation: isFrosted ? 1.12 : 1.5,
      surfaceColor: surface,
      highlightKind: KyantHighlightKind.plain,
      highlightAlpha: t.isDark ? 0.34 : 0.54,
      highlightAngleDeg: 45.0,
      highlightFalloff: 1.0,
      highlightWidth: 0.65,
      highlightBlur: 0.30,
      ambientEdgeDarken: t.isDark ? 0.0 : 0.055,
      shadows: [
        BoxShadow(
          color: Colors.black.withValues(alpha: t.isDark ? 0.42 : 0.13),
          blurRadius: isDialog ? 30.0 : 24.0,
          offset: Offset(0, isDialog ? 10.0 : 8.0),
        ),
      ],
    );
  }

  /// Kyant0 `LiquidBottomTabs` / `LiquidSegmentedControl` outer capsule track recipe.
  static KyantLiquidGlassStyle segmentedTrack(
    GrassBagTokens t,
    GrassBagGlassTier tier,
  ) {
    final isFrosted = tier == GrassBagGlassTier.frosted || kIsWeb;
    return KyantLiquidGlassStyle(
      blurRadius: isFrosted ? 8.0 : 5.0,
      refractionHeight: isFrosted ? 0.0 : 10.0,
      refractionAmount: isFrosted ? 0.0 : 16.0,
      depthEffect: false,
      chromaticAberration: 0.0,
      saturation: isFrosted ? 1.1 : 1.45,
      surfaceColor: t.isDark
          ? const Color(0xFF10141B).withValues(alpha: 0.48)
          : const Color(0xFFECEFF4).withValues(alpha: 0.56),
      highlightKind: KyantHighlightKind.defaultSpecular,
      highlightAlpha: t.isDark ? 0.30 : 0.52,
      highlightAngleDeg: 45.0,
      highlightFalloff: 1.5,
      highlightWidth: 0.60,
      highlightBlur: 0.25,
      ambientEdgeDarken: t.isDark ? 0.0 : 0.06,
      shadows: const [],
    );
  }

  /// Kyant0 `GlassPlayground` crystal prism lens showcase recipe (clear, vivid 7-band corner dispersion!).
  static KyantLiquidGlassStyle prismShowcase(
    GrassBagTokens t,
    GrassBagGlassTier tier, {
    double blurRadius = 0.0,
    double refractionHeight = 20.0,
    double refractionAmount = 34.0,
    double chromaticAberration = 1.0,
    bool depthEffect = true,
  }) {
    final isFrosted = tier == GrassBagGlassTier.frosted || kIsWeb;
    return KyantLiquidGlassStyle(
      blurRadius: isFrosted ? 8.0 : blurRadius,
      refractionHeight: isFrosted ? 0.0 : refractionHeight,
      refractionAmount: isFrosted ? 0.0 : refractionAmount,
      depthEffect: !isFrosted && depthEffect,
      chromaticAberration: isFrosted ? 0.0 : chromaticAberration,
      saturation: isFrosted ? 1.15 : 1.5,
      surfaceColor: t.isDark
          ? Colors.white.withValues(alpha: isFrosted ? 0.12 : 0.04)
          : Colors.white.withValues(alpha: isFrosted ? 0.40 : 0.08),
      highlightKind: KyantHighlightKind.defaultSpecular,
      highlightAlpha: t.isDark ? 0.56 : 0.72,
      highlightAngleDeg: 45.0,
      highlightFalloff: 1.2,
      highlightWidth: 0.75,
      highlightBlur: 0.30,
      innerShadowRadius: isFrosted ? 0.0 : 4.0,
      innerShadowAlpha: isFrosted ? 0.0 : 0.55,
      ambientEdgeDarken: t.isDark ? 0.0 : 0.06,
      shadows: [
        BoxShadow(
          color: Colors.black.withValues(alpha: t.isDark ? 0.30 : 0.11),
          blurRadius: 20.0,
          offset: const Offset(0, 6.0),
        ),
      ],
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is KyantLiquidGlassStyle &&
        other.blurRadius == blurRadius &&
        other.refractionHeight == refractionHeight &&
        other.refractionAmount == refractionAmount &&
        other.depthEffect == depthEffect &&
        other.chromaticAberration == chromaticAberration &&
        other.brightness == brightness &&
        other.contrast == contrast &&
        other.saturation == saturation &&
        other.surfaceColor == surfaceColor &&
        other.tintColor == tintColor &&
        other.highlightKind == highlightKind &&
        other.highlightAlpha == highlightAlpha &&
        other.highlightAngleDeg == highlightAngleDeg &&
        other.highlightFalloff == highlightFalloff &&
        other.highlightWidth == highlightWidth &&
        other.highlightBlur == highlightBlur &&
        other.innerShadowRadius == innerShadowRadius &&
        other.innerShadowAlpha == innerShadowAlpha &&
        other.ambientEdgeDarken == ambientEdgeDarken &&
        listEquals(other.shadows, shadows);
  }

  @override
  int get hashCode => Object.hashAll([
        blurRadius,
        refractionHeight,
        refractionAmount,
        depthEffect,
        chromaticAberration,
        brightness,
        contrast,
        saturation,
        surfaceColor,
        tintColor,
        highlightKind,
        highlightAlpha,
        highlightAngleDeg,
        highlightFalloff,
        highlightWidth,
        highlightBlur,
        innerShadowRadius,
        innerShadowAlpha,
        ambientEdgeDarken,
        Object.hashAll(shadows),
      ]);
}

/// Singleton preloader for `shaders/kyant_liquid_glass.frag`.
class KyantLiquidGlassEngine {
  static const String shaderAssetPath = 'shaders/kyant_liquid_glass.frag';

  static ui.FragmentProgram? _program;
  static Future<void>? _loading;
  static bool _failed = false;
  static final ChangeNotifier _readyNotifier = ChangeNotifier();

  static ui.FragmentProgram? get program => _program;
  static Listenable get readyListenable => _readyNotifier;
  static bool get isSupported => !kIsWeb && ui.ImageFilter.isShaderFilterSupported;

  static Future<void> warmUp() {
    if (_program != null || _failed || !isSupported) {
      return Future<void>.value();
    }
    return _loading ??= _loadInternal();
  }

  static Future<void> _loadInternal() async {
    try {
      final prog = await ui.FragmentProgram.fromAsset(shaderAssetPath);
      _program = prog;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      _readyNotifier.notifyListeners();
    } catch (_) {
      _failed = true;
    } finally {
      _loading = null;
    }
  }
}

/// Core Flutter Impeller Liquid Glass surface replicating Kyant0 `AndroidLiquidGlass`.
///
/// Architecture highlights:
/// - Runs `BackdropFilterLayer(ImageFilter.blur)` (when `blurRadius > 0`) followed by
///   `BackdropFilterLayer(ImageFilter.shader(kyant_liquid_glass.frag))` with an EMPTY child painter,
///   then paints [child] directly on top in the enclosing pass — so nested Kyant0 Liquid Glass
///   controls (Slider thumbs, Toggle thumbs, SegmentedControl lenses, LiquidButtons inside sheets)
///   sample the live rendered sheet & colored tracks directly with ZERO black-box bugs!
/// - Uses a lightweight `KyantTransformTrackingLayer` (`addToScene`) to recompute exact screen-space
///   `uBoxBounds` and `uCornerRadii` during scroll, drag, and spring-scale frames with ZERO 1-frame lag!
/// - Gracefully degrades to crisp frosted/solid Canvas rendering on `kIsWeb` and headless `flutter test`.
class KyantLiquidGlass extends StatefulWidget {
  const KyantLiquidGlass({
    super.key,
    required this.child,
    required this.style,
    this.borderRadius = BorderRadius.zero,
    this.isCapsule = false,
    this.isCircle = false,
    this.visibility = 1.0,
    this.pressPos = Offset.zero,
    this.pressIntensity = 0.0,
    this.enabled = true,
    this.clipBehavior = Clip.none,
  });

  final Widget child;
  final KyantLiquidGlassStyle style;
  final BorderRadius borderRadius;
  final bool isCapsule;
  final bool isCircle;
  final double visibility;
  final Offset pressPos;
  final double pressIntensity;
  final bool enabled;
  final Clip clipBehavior;

  @override
  State<KyantLiquidGlass> createState() => _KyantLiquidGlassState();
}

class _KyantLiquidGlassState extends State<KyantLiquidGlass> {
  @override
  void initState() {
    super.initState();
    if (widget.enabled && KyantLiquidGlassEngine.isSupported && KyantLiquidGlassEngine.program == null) {
      unawaited(KyantLiquidGlassEngine.warmUp());
      KyantLiquidGlassEngine.readyListenable.addListener(_onShaderReady);
    }
  }

  @override
  void didUpdateWidget(covariant KyantLiquidGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled && KyantLiquidGlassEngine.isSupported && KyantLiquidGlassEngine.program == null) {
      unawaited(KyantLiquidGlassEngine.warmUp());
      KyantLiquidGlassEngine.readyListenable.removeListener(_onShaderReady);
      KyantLiquidGlassEngine.readyListenable.addListener(_onShaderReady);
    }
  }

  void _onShaderReady() {
    KyantLiquidGlassEngine.readyListenable.removeListener(_onShaderReady);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    KyantLiquidGlassEngine.readyListenable.removeListener(_onShaderReady);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep constant widget tree depth across visibility 0.0 -> 1.0 transitions so
    // dialogs, sheets, popovers, and toasts NEVER unmount/remount on Frame 1!
    // `_RenderKyantLiquidGlass.paint` already fast-paths `visibility <= 0.001`.
    if (!widget.enabled) {
      return widget.child;
    }

    final t = GrassBagTokens.of(context);
    final program = KyantLiquidGlassEngine.program;
    final useGpuShader = program != null && KyantLiquidGlassEngine.isSupported;

    if (!useGpuShader) {
      return _KyantFallbackGlass(
        style: widget.style,
        borderRadius: widget.borderRadius,
        isCapsule: widget.isCapsule,
        isCircle: widget.isCircle,
        isDark: t.isDark,
        visibility: widget.visibility,
        pressPos: widget.pressPos,
        pressIntensity: widget.pressIntensity,
        clipBehavior: widget.clipBehavior,
        child: widget.child,
      );
    }

    final view = View.maybeOf(context);
    final dpr = view?.devicePixelRatio ?? MediaQuery.devicePixelRatioOf(context);
    final rootPhysicalSize = view?.physicalSize ?? (MediaQuery.sizeOf(context) * dpr);

    return _KyantShaderBox(
      program: program,
      style: widget.style,
      borderRadius: widget.borderRadius,
      isCapsule: widget.isCapsule,
      isCircle: widget.isCircle,
      isDark: t.isDark,
      devicePixelRatio: dpr,
      rootPhysicalSize: rootPhysicalSize,
      visibility: widget.visibility,
      pressPos: widget.pressPos,
      pressIntensity: widget.pressIntensity,
      clipBehavior: widget.clipBehavior,
      child: widget.child,
    );
  }
}

class _KyantFallbackGlass extends StatelessWidget {
  const _KyantFallbackGlass({
    required this.style,
    required this.borderRadius,
    required this.isCapsule,
    required this.isCircle,
    required this.isDark,
    required this.visibility,
    required this.pressPos,
    required this.pressIntensity,
    required this.clipBehavior,
    required this.child,
  });

  final KyantLiquidGlassStyle style;
  final BorderRadius borderRadius;
  final bool isCapsule;
  final bool isCircle;
  final bool isDark;
  final double visibility;
  final Offset pressPos;
  final double pressIntensity;
  final Clip clipBehavior;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = isCircle || isCapsule
        ? BorderRadius.circular(999)
        : borderRadius;
    final hasTint = style.tintColor.a > 0.001;
    final baseBg = hasTint
        ? style.tintColor.withValues(alpha: (style.tintColor.a * visibility).clamp(0.0, 1.0))
        : (style.surfaceColor.a > 0.001
            ? style.surfaceColor.withValues(alpha: (style.surfaceColor.a * visibility).clamp(0.0, 1.0))
            : (isDark
                ? Colors.white.withValues(alpha: 0.12 * visibility)
                : Colors.white.withValues(alpha: 0.56 * visibility)));
    final shape = isCircle
        ? const CircleBorder()
        : (isCapsule
            ? const StadiumBorder()
            : RoundedRectangleBorder(borderRadius: effectiveRadius));

    Widget content = child;
    if (clipBehavior != Clip.none) {
      content = isCircle
          ? ClipOval(clipBehavior: clipBehavior, child: content)
          : ClipRRect(borderRadius: effectiveRadius, clipBehavior: clipBehavior, child: content);
    }

    final painted = CustomPaint(
      foregroundPainter: _KyantFallbackRimPainter(
        style: style,
        borderRadius: borderRadius,
        isCapsule: isCapsule,
        isCircle: isCircle,
        isDark: isDark,
        visibility: visibility,
        pressPos: pressPos,
        pressIntensity: pressIntensity,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: baseBg,
          shape: shape,
          shadows: visibility <= 0.01
              ? const []
              : [
                  for (final s in style.shadows)
                    BoxShadow(
                      color: s.color.withValues(alpha: s.color.a * visibility),
                      blurRadius: s.blurRadius,
                      spreadRadius: s.spreadRadius,
                      offset: s.offset,
                    ),
                ],
        ),
        child: content,
      ),
    );

    if (style.blurRadius <= 0.01) {
      return painted;
    }

    final sigma = (style.blurRadius * visibility).clamp(0.0, 60.0);
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.mirror,
        ),
        child: painted,
      ),
    );
  }
}

class _KyantFallbackRimPainter extends CustomPainter {
  const _KyantFallbackRimPainter({
    required this.style,
    required this.borderRadius,
    required this.isCapsule,
    required this.isCircle,
    required this.isDark,
    required this.visibility,
    required this.pressPos,
    required this.pressIntensity,
  });

  final KyantLiquidGlassStyle style;
  final BorderRadius borderRadius;
  final bool isCapsule;
  final bool isCircle;
  final bool isDark;
  final double visibility;
  final Offset pressPos;
  final double pressIntensity;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || visibility <= 0.01) return;
    final rect = Offset.zero & size;
    final rrect = _resolveRRect(size, borderRadius, isCapsule: isCapsule, isCircle: isCircle);

    if (pressIntensity > 0.01) {
      final radius = math.max(size.shortestSide * 1.3, 40.0);
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.drawRect(
        rect,
        Paint()
          ..blendMode = isDark ? BlendMode.plus : BlendMode.srcOver
          ..shader = RadialGradient(
            colors: [
              Colors.white.withValues(alpha: (isDark ? 0.22 : 0.28) * pressIntensity),
              Colors.transparent,
            ],
          ).createShader(Rect.fromCircle(center: pressPos, radius: radius)),
      );
      canvas.restore();
    }

    if (style.highlightKind != KyantHighlightKind.none && style.highlightAlpha > 0.01) {
      final sw = style.highlightWidth.clamp(0.5, 1.5);
      final alpha = (style.highlightAlpha * visibility).clamp(0.0, 1.0);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = sw;
      if (style.highlightKind == KyantHighlightKind.plain) {
        paint.color = Colors.white.withValues(alpha: alpha * (isDark ? 0.72 : 0.90));
      } else {
        paint.shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: alpha * (isDark ? 0.85 : 0.95)),
            Colors.white.withValues(alpha: isDark ? 0.03 : 0.14),
            Colors.white.withValues(alpha: alpha * (isDark ? 0.55 : 0.72)),
          ],
          stops: const [0.0, 0.50, 1.0],
        ).createShader(rect);
      }
      canvas.drawRRect(rrect.deflate(sw * 0.5), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _KyantFallbackRimPainter old) =>
      old.style != style ||
      old.borderRadius != borderRadius ||
      old.isCapsule != isCapsule ||
      old.isCircle != isCircle ||
      old.isDark != isDark ||
      old.visibility != visibility ||
      old.pressPos != pressPos ||
      old.pressIntensity != pressIntensity;
}

RRect _resolveRRect(
  Size size,
  BorderRadius borderRadius, {
  required bool isCapsule,
  required bool isCircle,
}) {
  final rect = Offset.zero & size;
  final maxR = size.shortestSide * 0.5;
  if (isCircle || isCapsule) {
    return RRect.fromRectAndRadius(rect, Radius.circular(maxR));
  }
  return RRect.fromRectAndCorners(
    rect,
    topLeft: Radius.circular(borderRadius.topLeft.x.clamp(0.0, maxR)),
    topRight: Radius.circular(borderRadius.topRight.x.clamp(0.0, maxR)),
    bottomRight: Radius.circular(borderRadius.bottomRight.x.clamp(0.0, maxR)),
    bottomLeft: Radius.circular(borderRadius.bottomLeft.x.clamp(0.0, maxR)),
  );
}

class _KyantShaderBox extends SingleChildRenderObjectWidget {
  const _KyantShaderBox({
    required this.program,
    required this.style,
    required this.borderRadius,
    required this.isCapsule,
    required this.isCircle,
    required this.isDark,
    required this.devicePixelRatio,
    required this.rootPhysicalSize,
    required this.visibility,
    required this.pressPos,
    required this.pressIntensity,
    required this.clipBehavior,
    required super.child,
  });

  final ui.FragmentProgram program;
  final KyantLiquidGlassStyle style;
  final BorderRadius borderRadius;
  final bool isCapsule;
  final bool isCircle;
  final bool isDark;
  final double devicePixelRatio;
  final Size rootPhysicalSize;
  final double visibility;
  final Offset pressPos;
  final double pressIntensity;
  final Clip clipBehavior;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderKyantLiquidGlass(
      program: program,
      style: style,
      borderRadius: borderRadius,
      isCapsule: isCapsule,
      isCircle: isCircle,
      isDark: isDark,
      devicePixelRatio: devicePixelRatio,
      rootPhysicalSize: rootPhysicalSize,
      visibility: visibility,
      pressPos: pressPos,
      pressIntensity: pressIntensity,
      clipBehavior: clipBehavior,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderKyantLiquidGlass renderObject,
  ) {
    renderObject
      ..style = style
      ..borderRadius = borderRadius
      ..isCapsule = isCapsule
      ..isCircle = isCircle
      ..isDark = isDark
      ..devicePixelRatio = devicePixelRatio
      ..rootPhysicalSize = rootPhysicalSize
      ..visibility = visibility
      ..pressPos = pressPos
      ..pressIntensity = pressIntensity
      ..clipBehavior = clipBehavior;
  }
}

class _KyantTransformTrackingLayer extends OffsetLayer {
  _KyantTransformTrackingLayer();

  _RenderKyantLiquidGlass? renderObject;
  Matrix4? _lastTransform;

  @override
  bool get alwaysNeedsAddToScene => true;

  @override
  void addToScene(ui.SceneBuilder builder) {
    final ro = renderObject;
    if (ro == null || !ro.attached) return;
    Matrix4 currentTransform;
    try {
      currentTransform = ro.getTransformTo(null);
    } catch (_) {
      return;
    }
    final changed = !MatrixUtils.matrixEquals(currentTransform, _lastTransform);
    final updated = ro._updateAtComposite(currentTransform);
    if (!updated && changed && _lastTransform != null) {
      final binding = SchedulerBinding.instance;
      if (binding.schedulerPhase
          case SchedulerPhase.idle || SchedulerPhase.postFrameCallbacks) {
        ro.markNeedsPaint();
      } else {
        binding.addPostFrameCallback((_) {
          if (ro.attached) ro.markNeedsPaint();
        });
      }
    }
    _lastTransform = currentTransform;
  }
}

class _RenderKyantLiquidGlass extends RenderProxyBox {
  _RenderKyantLiquidGlass({
    required ui.FragmentProgram program,
    required KyantLiquidGlassStyle style,
    required BorderRadius borderRadius,
    required bool isCapsule,
    required bool isCircle,
    required bool isDark,
    required double devicePixelRatio,
    required Size rootPhysicalSize,
    required double visibility,
    required Offset pressPos,
    required double pressIntensity,
    required Clip clipBehavior,
  })  : _shader = program.fragmentShader(),
        _style = style,
        _borderRadius = borderRadius,
        _isCapsule = isCapsule,
        _isCircle = isCircle,
        _isDark = isDark,
        _dpr = devicePixelRatio,
        _rootPhysicalSize = rootPhysicalSize,
        _visibility = visibility,
        _pressPos = pressPos,
        _pressIntensity = pressIntensity,
        _clipBehavior = clipBehavior;

  ui.FragmentShader? _shader;
  final LayerHandle<_KyantTransformTrackingLayer> _trackingHandle =
      LayerHandle<_KyantTransformTrackingLayer>();
  final LayerHandle<ClipRRectLayer> _backdropClipHandle =
      LayerHandle<ClipRRectLayer>();
  final LayerHandle<BackdropFilterLayer> _blurLayerHandle =
      LayerHandle<BackdropFilterLayer>();
  final LayerHandle<BackdropFilterLayer> _shaderLayerHandle =
      LayerHandle<BackdropFilterLayer>();
  final LayerHandle<ClipRRectLayer> _childClipHandle =
      LayerHandle<ClipRRectLayer>();

  ui.ImageFilter? _cachedBlurFilter;
  double _cachedBlurSigma = -1.0;
  Matrix4? _lastWrittenTransform;
  Rect? _lastPassPhysical;

  KyantLiquidGlassStyle _style;
  set style(KyantLiquidGlassStyle value) {
    if (_style == value) return;
    _style = value;
    markNeedsPaint();
  }

  BorderRadius _borderRadius;
  set borderRadius(BorderRadius value) {
    if (_borderRadius == value) return;
    _borderRadius = value;
    markNeedsPaint();
  }

  bool _isCapsule;
  set isCapsule(bool value) {
    if (_isCapsule == value) return;
    _isCapsule = value;
    markNeedsPaint();
  }

  bool _isCircle;
  set isCircle(bool value) {
    if (_isCircle == value) return;
    _isCircle = value;
    markNeedsPaint();
  }

  bool _isDark;
  set isDark(bool value) {
    if (_isDark == value) return;
    _isDark = value;
    markNeedsPaint();
  }

  double _dpr;
  set devicePixelRatio(double value) {
    if (_dpr == value) return;
    _dpr = value;
    markNeedsPaint();
  }

  Size _rootPhysicalSize;
  set rootPhysicalSize(Size value) {
    if (_rootPhysicalSize == value) return;
    _rootPhysicalSize = value;
    markNeedsPaint();
  }

  double _visibility;
  set visibility(double value) {
    final next = value.clamp(0.0, 1.0);
    if ((_visibility - next).abs() < 0.0005) return;
    _visibility = next;
    markNeedsPaint();
  }

  Offset _pressPos;
  set pressPos(Offset value) {
    if (_pressPos == value) return;
    _pressPos = value;
    markNeedsPaint();
  }

  double _pressIntensity;
  set pressIntensity(double value) {
    final next = value.clamp(0.0, 1.0);
    if ((_pressIntensity - next).abs() < 0.0005) return;
    _pressIntensity = next;
    markNeedsPaint();
  }

  Clip _clipBehavior;
  set clipBehavior(Clip value) {
    if (_clipBehavior == value) return;
    _clipBehavior = value;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void dispose() {
    _trackingHandle.layer?.renderObject = null;
    _trackingHandle.layer = null;
    _backdropClipHandle.layer = null;
    _blurLayerHandle.layer = null;
    _shaderLayerHandle.layer = null;
    _childClipHandle.layer = null;
    _shader?.dispose();
    _shader = null;
    super.dispose();
  }

  Rect _resolvePassPhysical() {
    // Check if an external Flutter `BackdropFilter` wraps this subtree;
    // our own `KyantLiquidGlass` closes its BackdropFilterLayer before painting children,
    // so nested Kyant glass always runs in root screen coordinates!
    RenderObject? node = parent;
    while (node != null) {
      if (node is RenderBackdropFilter && node.attached && node.hasSize) {
        final local = Offset.zero & node.size;
        final global = MatrixUtils.transformRect(node.getTransformTo(null), local);
        final rootLogical = Offset.zero & (_rootPhysicalSize / _dpr);
        final clipped = global.intersect(rootLogical);
        return Rect.fromLTRB(
          (clipped.left * _dpr).floorToDouble(),
          (clipped.top * _dpr).floorToDouble(),
          (clipped.right * _dpr).ceilToDouble(),
          (clipped.bottom * _dpr).ceilToDouble(),
        );
      }
      node = node.parent;
    }
    return Offset.zero & _rootPhysicalSize;
  }

  void _writeUniforms(Matrix4 transform, Rect passPhysical, bool hasBlurPass) {
    final shader = _shader;
    if (shader == null || size.isEmpty) return;

    final boxGlobal = MatrixUtils.transformRect(transform, Offset.zero & size);
    final boxPhysOriginX = boxGlobal.left * _dpr - passPhysical.left;
    final boxPhysOriginY = boxGlobal.top * _dpr - passPhysical.top;
    final boxPhysW = math.max(1.0, boxGlobal.width * _dpr);
    final boxPhysH = math.max(1.0, boxGlobal.height * _dpr);

    final scaleFactor = size.shortestSide > 0
        ? (boxGlobal.shortestSide / size.shortestSide).clamp(0.1, 4.0)
        : 1.0;
    final maxPhysR = math.min(boxPhysW, boxPhysH) * 0.5;
    final double rTL;
    final double rTR;
    final double rBR;
    final double rBL;
    if (_isCircle || _isCapsule) {
      rTL = maxPhysR;
      rTR = maxPhysR;
      rBR = maxPhysR;
      rBL = maxPhysR;
    } else {
      final k = scaleFactor * _dpr;
      rTL = (_borderRadius.topLeft.x * k).clamp(0.0, maxPhysR);
      rTR = (_borderRadius.topRight.x * k).clamp(0.0, maxPhysR);
      rBR = (_borderRadius.bottomRight.x * k).clamp(0.0, maxPhysR);
      rBL = (_borderRadius.bottomLeft.x * k).clamp(0.0, maxPhysR);
    }

    final sx = size.width > 0 ? boxGlobal.width / size.width : 1.0;
    final sy = size.height > 0 ? boxGlobal.height / size.height : 1.0;
    final effScaleDpr = scaleFactor * _dpr;

    final s = _style;
    final angleRad = s.highlightAngleDeg * (math.pi / 180.0);

    // 0..1: uPassSize
    shader.setFloat(0, math.max(1.0, passPhysical.width));
    shader.setFloat(1, math.max(1.0, passPhysical.height));
    // 2..5: uBoxBounds
    shader.setFloat(2, boxPhysOriginX);
    shader.setFloat(3, boxPhysOriginY);
    shader.setFloat(4, boxPhysW);
    shader.setFloat(5, boxPhysH);
    // 6..9: uCornerRadii
    shader.setFloat(6, rTL);
    shader.setFloat(7, rTR);
    shader.setFloat(8, rBR);
    shader.setFloat(9, rBL);
    // 10..13: uLensParams
    shader.setFloat(10, s.refractionHeight * effScaleDpr * _visibility);
    shader.setFloat(11, s.refractionAmount * effScaleDpr * _visibility);
    shader.setFloat(12, s.depthEffect ? 1.0 : 0.0);
    shader.setFloat(13, s.chromaticAberration * _visibility);
    // 14..17: uColorControls
    shader.setFloat(14, s.brightness);
    shader.setFloat(15, s.contrast);
    shader.setFloat(16, s.saturation);
    shader.setFloat(17, _visibility);
    // 18..21: uSurfaceColor (straight RGBA)
    shader.setFloat(18, s.surfaceColor.r);
    shader.setFloat(19, s.surfaceColor.g);
    shader.setFloat(20, s.surfaceColor.b);
    shader.setFloat(21, s.surfaceColor.a);
    // 22..25: uTintColor (straight RGBA)
    shader.setFloat(22, s.tintColor.r);
    shader.setFloat(23, s.tintColor.g);
    shader.setFloat(24, s.tintColor.b);
    shader.setFloat(25, s.tintColor.a);
    // 26..29: uHighlightParams
    shader.setFloat(26, s.highlightKind.shaderValue);
    shader.setFloat(27, s.highlightAlpha);
    shader.setFloat(28, angleRad);
    shader.setFloat(29, s.highlightFalloff);
    // 30..33: uEdgeParams
    shader.setFloat(30, s.highlightWidth * _dpr);
    shader.setFloat(31, s.highlightBlur * _dpr);
    shader.setFloat(32, s.innerShadowRadius * effScaleDpr);
    shader.setFloat(33, s.innerShadowAlpha);
    // 34..37: uInteractiveParams
    shader.setFloat(34, _pressPos.dx * sx * _dpr);
    shader.setFloat(35, _pressPos.dy * sy * _dpr);
    shader.setFloat(36, _pressIntensity);
    shader.setFloat(37, hasBlurPass ? 1.0 : 0.0);
    // 38..41: uExtraParams
    shader.setFloat(38, s.ambientEdgeDarken);
    shader.setFloat(39, _isDark ? 1.0 : 0.0);
    shader.setFloat(40, 0.0);
    shader.setFloat(41, 0.0);

    _lastWrittenTransform = transform;
    _lastPassPhysical = passPhysical;
  }

  bool _updateAtComposite(Matrix4 currentTransform) {
    final shaderLayer = _shaderLayerHandle.layer;
    final shader = _shader;
    if (!attached || shaderLayer == null || shader == null || size.isEmpty) {
      return false;
    }
    final passPhysical = _resolvePassPhysical();
    if (MatrixUtils.matrixEquals(currentTransform, _lastWrittenTransform) &&
        passPhysical == _lastPassPhysical) {
      return true;
    }
    final hasBlurPass = (_style.blurRadius * _visibility) > 0.05;
    _writeUniforms(currentTransform, passPhysical, hasBlurPass);
    shaderLayer.filter = ui.ImageFilter.shader(shader);
    return true;
  }

  Path? _cachedShadowClipPath;
  RRect? _cachedShadowRRect;
  double _cachedShadowMaxExtent = -1.0;

  void _paintOuterShadows(Canvas canvas, Offset offset, RRect rrect) {
    if (_style.shadows.isEmpty || _visibility <= 0.01) return;
    var maxExtent = 16.0;
    for (final s in _style.shadows) {
      final ext = s.blurRadius * 2.5 +
          s.spreadRadius.abs() +
          math.max(s.offset.dx.abs(), s.offset.dy.abs()) +
          12.0;
      if (ext > maxExtent) maxExtent = ext;
    }
    if (_cachedShadowClipPath == null ||
        _cachedShadowRRect != rrect ||
        (_cachedShadowMaxExtent - maxExtent).abs() > 0.1) {
      _cachedShadowRRect = rrect;
      _cachedShadowMaxExtent = maxExtent;
      _cachedShadowClipPath = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rrect.outerRect.inflate(maxExtent))
        ..addRRect(rrect);
    }

    canvas.save();
    if (offset != Offset.zero) {
      canvas.translate(offset.dx, offset.dy);
    }
    canvas.clipPath(_cachedShadowClipPath!);
    for (final s in _style.shadows) {
      final paint = Paint()
        ..color = s.color.withValues(alpha: s.color.a * _visibility)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s.blurSigma);
      final shadowRRect = s.spreadRadius == 0.0
          ? rrect.shift(s.offset)
          : rrect.inflate(s.spreadRadius).shift(s.offset);
      canvas.drawRRect(shadowRRect, paint);
    }
    canvas.restore();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!attached || size.isEmpty || _shader == null || _visibility <= 0.001) {
      super.paint(context, offset);
      return;
    }

    final rrect = _resolveRRect(
      size,
      _borderRadius,
      isCapsule: _isCapsule,
      isCircle: _isCircle,
    );

    // 1. Paint inverse-clipped outer elevation shadow (matches Kyant0 ShadowModifier.kt)
    _paintOuterShadows(context.canvas, offset, rrect);

    // 2. Push transform-tracking layer BEFORE BackdropFilterLayers so composite-time
    //    scroll/drag/scale updates apply in the exact same frame!
    final trackingLayer = (_trackingHandle.layer ??= _KyantTransformTrackingLayer())
      ..renderObject = this;
    context.pushLayer(trackingLayer, (ctx, off) {}, offset);

    // 3. Write exact physical-pixel uniforms for this frame
    final transform = getTransformTo(null);
    final passPhysical = _resolvePassPhysical();
    final effectiveBlur = _style.blurRadius * _visibility;
    final hasBlurPass = effectiveBlur > 0.05;
    _writeUniforms(transform, passPhysical, hasBlurPass);

    if (hasBlurPass) {
      if (_cachedBlurFilter == null || (_cachedBlurSigma - effectiveBlur).abs() > 0.01) {
        _cachedBlurFilter = ui.ImageFilter.blur(
          sigmaX: effectiveBlur,
          sigmaY: effectiveBlur,
          tileMode: TileMode.mirror,
        );
        _cachedBlurSigma = effectiveBlur;
      }
      (_blurLayerHandle.layer ??= BackdropFilterLayer()).filter = _cachedBlurFilter!;
    } else {
      _blurLayerHandle.layer = null;
    }

    final shaderLayer = (_shaderLayerHandle.layer ??= BackdropFilterLayer())
      ..filter = ui.ImageFilter.shader(_shader!);

    // 4. Push shape-clipped Blur + Kyant0 Refraction/Dispersion/Highlight passes
    //    with EMPTY child painters so child widgets paint cleanly in root coordinates after!
    _backdropClipHandle.layer = context.pushClipRRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      rrect,
      (ctx, off) {
        if (_blurLayerHandle.layer case final blurLayer?) {
          ctx.pushLayer(blurLayer, (c, o) {}, off);
        }
        ctx.pushLayer(shaderLayer, (c, o) {}, off);
      },
      clipBehavior: Clip.antiAlias,
      oldLayer: _backdropClipHandle.layer,
    );

    // 5. Paint child content cleanly ON TOP of the finished Liquid Glass surface!
    if (_clipBehavior != Clip.none) {
      _childClipHandle.layer = context.pushClipRRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        rrect,
        super.paint,
        clipBehavior: _clipBehavior,
        oldLayer: _childClipHandle.layer,
      );
    } else {
      _childClipHandle.layer = null;
      super.paint(context, offset);
    }
  }
}

/// Faithful port of Kyant0 `InteractiveHighlight.kt` + `LiquidButton.kt` elastic drag-stretch:
/// - Spring `pressProgress` (`stiffness: 300, dampingRatio: 0.5`)
/// - Magnetic `tanh` offset follow + directional `scaleX`/`scaleY` stretch
/// - Feeds live `pressPos` & `pressIntensity` directly into [KyantLiquidGlass] shader!
/// - Automatically defers press inside `Scrollable`s so vertical scrolling never fights touches.
class KyantInteractiveGlassButton extends StatefulWidget {
  const KyantInteractiveGlassButton({
    super.key,
    required this.child,
    required this.style,
    required this.onTap,
    this.enabled = true,
    this.isCapsule = true,
    this.isCircle = false,
    this.borderRadius = BorderRadius.zero,
    this.width,
    this.height,
    this.padding,
    this.alignment = Alignment.center,
    this.haptic = true,
    this.clipBehavior = Clip.none,
    this.visibility = 1.0,
    this.materializeAnimation,
  });

  final Widget child;
  final KyantLiquidGlassStyle style;
  final VoidCallback? onTap;
  final bool enabled;
  final bool isCapsule;
  final bool isCircle;
  final BorderRadius borderRadius;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final AlignmentGeometry alignment;
  final bool haptic;
  final Clip clipBehavior;
  final double visibility;
  final Animation<double>? materializeAnimation;

  @override
  State<KyantInteractiveGlassButton> createState() =>
      _KyantInteractiveGlassButtonState();
}

class _KyantInteractiveGlassButtonState extends State<KyantInteractiveGlassButton>
    with TickerProviderStateMixin {
  static final SpringDescription _kyantSpring = SpringDescription.withDampingRatio(
    mass: 1.0,
    stiffness: 300.0,
    ratio: 0.58,
  );

  AnimationController? _pressCtrl;
  AnimationController? _offsetXCtrl;
  AnimationController? _offsetYCtrl;
  final ValueNotifier<Offset> _touchPos = ValueNotifier<Offset>(Offset.zero);
  final _TickBus _bus = _TickBus();
  late Listenable _mergedListenable;

  int? _activePointer;
  Offset _startPos = Offset.zero;
  Offset _lastMovePos = Offset.zero;
  int _lastMoveUs = 0;
  Offset _moveVel = Offset.zero;
  final Stopwatch _moveClock = Stopwatch()..start();
  bool _inScrollable = false;
  bool _engaged = false;
  bool _didEngage = false;
  Timer? _scrollDeferTimer;

  static double _tanh(double x) {
    final e2x = math.exp(2.0 * x.clamp(-6.0, 6.0));
    return (e2x - 1.0) / (e2x + 1.0);
  }

  void _rebuildMergedListenable() {
    final matAnim = widget.materializeAnimation;
    _mergedListenable = matAnim != null
        ? Listenable.merge([_bus, _touchPos, matAnim])
        : Listenable.merge([_bus, _touchPos]);
  }

  @override
  void initState() {
    super.initState();
    _rebuildMergedListenable();
  }

  void _ensureControllers() {
    if (_pressCtrl != null) return;
    _pressCtrl = AnimationController.unbounded(vsync: this, value: 0.0)
      ..addListener(_bus.notify);
    _offsetXCtrl = AnimationController.unbounded(vsync: this, value: 0.0)
      ..addListener(_bus.notify);
    _offsetYCtrl = AnimationController.unbounded(vsync: this, value: 0.0)
      ..addListener(_bus.notify);
  }

  void _animateSpring(AnimationController ctrl, double target, {double? initialVelocity}) {
    if (mounted && MediaQuery.disableAnimationsOf(context)) {
      // Under Reduce Motion, suppress kinetic scale pops completely.
      ctrl.value = 0.0;
      return;
    }
    ctrl.animateWith(
      SpringSimulation(
        _kyantSpring,
        ctrl.value,
        target,
        initialVelocity ?? ctrl.velocity,
        tolerance: const Tolerance(distance: 0.002, velocity: 0.01),
      ),
    );
  }

  void _engage() {
    if (_engaged || !mounted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _engaged = true;
      _didEngage = true;
      return;
    }
    _engaged = true;
    _didEngage = true;
    _ensureControllers();
    _animateSpring(_pressCtrl!, 1.0);
  }

  void _release({bool force = false}) {
    _scrollDeferTimer?.cancel();
    _scrollDeferTimer = null;
    if (_activePointer == null && !force) return;
    _activePointer = null;
    _engaged = false;
    final vx = _moveVel.dx.clamp(-600.0, 600.0);
    final vy = _moveVel.dy.clamp(-600.0, 600.0);
    _moveVel = Offset.zero;
    if (_pressCtrl != null) {
      _animateSpring(_pressCtrl!, 0.0);
    }
    if (_offsetXCtrl != null) {
      _animateSpring(_offsetXCtrl!, 0.0, initialVelocity: vx * 0.25);
    }
    if (_offsetYCtrl != null) {
      _animateSpring(_offsetYCtrl!, 0.0, initialVelocity: vy * 0.25);
    }
  }

  void _quickPulse() {
    if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
    _ensureControllers();
    // Smooth velocity impulse from rest instead of a 1-frame 0 -> 0.72 jump!
    _pressCtrl!.animateWith(
      SpringSimulation(
        _kyantSpring,
        _pressCtrl!.value,
        0.0,
        10.5,
        tolerance: const Tolerance(distance: 0.002, velocity: 0.01),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant KyantInteractiveGlassButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.materializeAnimation != widget.materializeAnimation) {
      _rebuildMergedListenable();
    }
    if (oldWidget.enabled && !widget.enabled) {
      _release(force: true);
    }
  }

  @override
  void dispose() {
    _scrollDeferTimer?.cancel();
    _pressCtrl?.dispose();
    _offsetXCtrl?.dispose();
    _offsetYCtrl?.dispose();
    _touchPos.dispose();
    _bus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && widget.onTap != null;

    final Widget paddedChild = widget.padding != null
        ? Padding(padding: widget.padding!, child: widget.child)
        : widget.child;
    final Widget innerContent;
    if (widget.width != null) {
      innerContent = SizedBox(
        width: widget.width,
        height: widget.height,
        child: Align(alignment: widget.alignment, child: paddedChild),
      );
    } else if (widget.height != null) {
      innerContent = ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: widget.height!,
          maxHeight: widget.height!,
        ),
        child: Center(
          widthFactor: 1.0,
          child: paddedChild,
        ),
      );
    } else {
      innerContent = paddedChild;
    }

    // Constant widget tree depth across rest, press, negative rebound, disabled,
    // and materialization so `_KyantLiquidGlassState` & GLSL shader NEVER unmount!
    final animatedGlass = RepaintBoundary(
      child: ListenableBuilder(
        listenable: _mergedListenable,
        child: innerContent,
        builder: (context, child) {
          final rawP = _pressCtrl?.value ?? 0.0;
          final p = rawP.clamp(-0.22, 1.35);
          final dx = _offsetXCtrl?.value ?? 0.0;
          final dy = _offsetYCtrl?.value ?? 0.0;
          final atRest = p.abs() < 0.002 && dx.abs() < 0.05 && dy.abs() < 0.05;

          final matVis =
              (widget.materializeAnimation?.value ?? widget.visibility).clamp(0.0, 1.0);
          final contentAlpha = (matVis * (active ? 1.0 : 0.45)).clamp(0.0, 1.0);

          final Widget visualChild = contentAlpha >= 0.999
              ? child!
              : Opacity(opacity: contentAlpha, child: child!);

          final glass = KyantLiquidGlass(
            style: widget.style,
            isCapsule: widget.isCapsule,
            isCircle: widget.isCircle,
            borderRadius: widget.borderRadius,
            visibility: matVis * (active ? 1.0 : 0.72),
            pressPos: _touchPos.value,
            pressIntensity: p.clamp(0.0, 1.0),
            clipBehavior: widget.clipBehavior,
            child: visualChild,
          );

          final Matrix4 mat;
          if (atRest) {
            mat = Matrix4.identity();
          } else {
            final rb = context.findRenderObject();
            final measured = rb is RenderBox && rb.hasSize ? rb.size : null;
            final h = widget.height ?? measured?.height ?? 44.0;
            final w = widget.width ?? measured?.width ?? (h * 2.2);
            final minDim = math.min(w, h);
            final maxDim = math.max(w, h);
            // Exact Kyant0 LiquidButton.kt:68-86 spring scale (preserving subtle release rebound!) + tanh magnetic stretch
            final baseScale = 1.0 + (4.0 / math.max(h, 24.0)) * p;
            final tx = minDim * _tanh(0.05 * dx / math.max(minDim, 1.0));
            final ty = minDim * _tanh(0.05 * dy / math.max(minDim, 1.0));
            final maxDragScale = 4.0 / math.max(h, 24.0);
            final angle = math.atan2(dy, dx);
            final sx = (baseScale +
                    maxDragScale *
                        (math.cos(angle) * dx / math.max(maxDim, 1.0)).abs() *
                        math.min(w / math.max(h, 1.0), 1.0))
                .clamp(0.92, 1.14);
            final sy = (baseScale +
                    maxDragScale *
                        (math.sin(angle) * dy / math.max(maxDim, 1.0)).abs() *
                        math.min(h / math.max(w, 1.0), 1.0))
                .clamp(0.92, 1.14);

            mat = Matrix4.identity()
              ..translateByDouble(tx, ty, 0.0, 1.0)
              ..scaleByDouble(sx, sy, 1.0, 1.0);
          }

          return Transform(
            alignment: Alignment.center,
            transform: mat,
            child: glass,
          );
        },
      ),
    );

    return IgnorePointer(
      ignoring: !active,
      child: MouseRegion(
        cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: active
              ? (e) {
                  if (_activePointer != null) return;
                  _scrollDeferTimer?.cancel();
                  _activePointer = e.pointer;
                  _startPos = e.localPosition;
                  _lastMovePos = e.localPosition;
                  _lastMoveUs = _moveClock.elapsedMicroseconds;
                  _moveVel = Offset.zero;
                  _touchPos.value = e.localPosition;
                  _engaged = false;
                  _didEngage = false;
                  _inScrollable = Scrollable.maybeOf(context) != null;
                  if (_inScrollable) {
                    _scrollDeferTimer = Timer(const Duration(milliseconds: 50), _engage);
                  } else {
                    _engage();
                  }
                }
              : null,
          onPointerMove: active
              ? (e) {
                  if (_activePointer != e.pointer) return;
                  final delta = e.localPosition - _startPos;
                  if (_inScrollable && delta.distance > 11.0) {
                    _release();
                    return;
                  }
                  if (!_engaged) return;
                  final nowUs = _moveClock.elapsedMicroseconds;
                  final dtSec = ((nowUs - _lastMoveUs) / 1000000.0).clamp(0.004, 0.08);
                  final instVel = (e.localPosition - _lastMovePos) / dtSec;
                  _moveVel = Offset(
                    _moveVel.dx * 0.65 + instVel.dx * 0.35,
                    _moveVel.dy * 0.65 + instVel.dy * 0.35,
                  );
                  _lastMovePos = e.localPosition;
                  _lastMoveUs = nowUs;
                  _touchPos.value = e.localPosition;
                  if (!_inScrollable && _offsetXCtrl != null) {
                    _offsetXCtrl!.value = delta.dx.clamp(-80.0, 80.0);
                    _offsetYCtrl!.value = delta.dy.clamp(-80.0, 80.0);
                  }
                }
              : null,
          onPointerUp: active
              ? (e) {
                  if (_activePointer == e.pointer) _release();
                }
              : null,
          onPointerCancel: active
              ? (e) {
                  if (_activePointer == e.pointer) _release();
                }
              : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: active
                ? () {
                    if (!_didEngage) _quickPulse();
                    if (widget.haptic) HapticFeedback.lightImpact();
                    widget.onTap?.call();
                  }
                : null,
            child: animatedGlass,
          ),
        ),
      ),
    );
  }
}

class _TickBus extends ChangeNotifier {
  void notify() => notifyListeners();
}

class _KyantSpringChannel {
  _KyantSpringChannel({
    required double initialValue,
    required this.stiffness,
    required this.dampingRatio,
  })  : position = initialValue,
        target = initialValue,
        _damping = 2.0 * dampingRatio * math.sqrt(stiffness);

  final double stiffness;
  final double dampingRatio;
  final double _damping;

  double position;
  double velocity = 0.0;
  double target;

  bool step(double dt, {required double posEps, required double velEps}) {
    const int subSteps = 4;
    final subDt = dt / subSteps;
    for (int i = 0; i < subSteps; i++) {
      final force = -stiffness * (position - target) - _damping * velocity;
      velocity += force * subDt;
      position += velocity * subDt;
    }
    if ((position - target).abs() <= posEps && velocity.abs() <= velEps) {
      position = target;
      velocity = 0.0;
      return true;
    }
    return false;
  }

  void snap(double v) {
    position = v;
    target = v;
    velocity = 0.0;
  }

  bool isSettled({required double posEps, required double velEps}) =>
      (position - target).abs() <= posEps && velocity.abs() <= velEps;
}

/// Faithful port of Kyant0 `DampedDragAnimation.kt` physics controller used by
/// `LiquidSlider`, `LiquidToggle`, and `LiquidSegmentedControl`:
/// - `valueSpring`: dampingRatio 1.0, stiffness 1000
/// - `pressSpring`: dampingRatio 1.0, stiffness 1000
/// - `scaleXSpring`: dampingRatio 0.6, stiffness 250 (bouncy horizontal swell!)
/// - `scaleYSpring`: dampingRatio 0.7, stiffness 250 (bouncy vertical swell!)
/// - `velocitySpring`: dampingRatio 0.5, stiffness 300 (fluid squash & stretch!)
///
/// Driven by ONE persistent [Ticker] (never restarting `Ticker._startTime` on continuous
/// 60/120Hz pointer moves, eliminating Flutter's `animateWith` drag starvation completely!).
class KyantDampedDragController extends ChangeNotifier {
  KyantDampedDragController({
    required TickerProvider vsync,
    required double initialValue,
    required this.minValue,
    required this.maxValue,
    this.initialScale = 1.0,
    this.pressedScale = 1.5,
  })  : _val = _KyantSpringChannel(
          initialValue: initialValue,
          stiffness: 1000.0,
          dampingRatio: 1.0,
        ),
        _press = _KyantSpringChannel(
          initialValue: 0.0,
          stiffness: 1000.0,
          dampingRatio: 1.0,
        ),
        _scaleX = _KyantSpringChannel(
          initialValue: initialScale,
          stiffness: 250.0,
          dampingRatio: 0.6,
        ),
        _scaleY = _KyantSpringChannel(
          initialValue: initialScale,
          stiffness: 250.0,
          dampingRatio: 0.7,
        ),
        _vel = _KyantSpringChannel(
          initialValue: 0.0,
          stiffness: 300.0,
          dampingRatio: 0.5,
        ) {
    _ticker = vsync.createTicker(_onTick);
  }

  double minValue;
  double maxValue;
  final double initialScale;
  final double pressedScale;

  final _KyantSpringChannel _val;
  final _KyantSpringChannel _press;
  final _KyantSpringChannel _scaleX;
  final _KyantSpringChannel _scaleY;
  final _KyantSpringChannel _vel;

  late final Ticker _ticker;
  final Stopwatch _clock = Stopwatch()..start();
  Duration? _lastElapsed;
  int _lastSampleUs = 0;
  double _lastSampleVal = 0.0;
  double _smoothedVel = 0.0;
  bool _pendingRelease = false;
  Timer? _velDecayTimer;
  Timer? _releaseTimer;
  bool _disposed = false;

  double get _span => math.max(maxValue - minValue, 1e-4);
  double get value => _val.position;
  double get targetValue => _val.target;
  double get progress {
    final span = maxValue - minValue;
    if (span <= 0.0) return 0.0;
    return ((_val.position - minValue) / span).clamp(0.0, 1.0);
  }

  double get pressProgress => _press.position.clamp(0.0, 1.0);
  double get scaleX => _scaleX.position.clamp(0.75, 2.0);
  double get scaleY => _scaleY.position.clamp(0.75, 2.0);
  double get velocity => _vel.position;

  void _ensureTicking() {
    if (_disposed || _ticker.isActive) return;
    _lastElapsed = null;
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    if (_disposed) {
      _ticker.stop();
      return;
    }
    final double dt;
    if (_lastElapsed == null) {
      dt = 1.0 / 60.0;
    } else {
      final raw = (elapsed - _lastElapsed!).inMicroseconds / 1000000.0;
      dt = raw.clamp(0.001, 0.033);
    }
    _lastElapsed = elapsed;

    final valEps = (_span * 0.001).clamp(1e-4, 0.01);
    final valSettled = _val.step(dt, posEps: valEps, velEps: valEps * 8.0);

    // Faithful Kyant0 DampedDragAnimation.kt:96-105: keep the crystal lens expanded
    // while gliding to target, then release once within 2.5% of span.
    if (_pendingRelease && (_val.position - _val.target).abs() <= _span * 0.025) {
      _pendingRelease = false;
      _press.target = 0.0;
      _scaleX.target = initialScale;
      _scaleY.target = initialScale;
      _vel.target = 0.0;
    }

    final pressSettled = _press.step(dt, posEps: 0.001, velEps: 0.01);
    final sxSettled = _scaleX.step(dt, posEps: 0.001, velEps: 0.01);
    final sySettled = _scaleY.step(dt, posEps: 0.001, velEps: 0.01);
    final velSettled = _vel.step(dt, posEps: 0.02, velEps: 0.1);

    if (valSettled && pressSettled && sxSettled && sySettled && velSettled && !_pendingRelease) {
      _ticker.stop();
      _lastElapsed = null;
    }
    notifyListeners();
  }

  void press({bool reduceMotion = false}) {
    if (_disposed) return;
    _releaseTimer?.cancel();
    _pendingRelease = false;
    _lastSampleUs = _clock.elapsedMicroseconds;
    _lastSampleVal = _val.position;
    _smoothedVel = 0.0;
    if (reduceMotion) {
      _press.snap(1.0);
      _scaleX.snap(pressedScale);
      _scaleY.snap(pressedScale);
      notifyListeners();
      return;
    }
    _press.target = 1.0;
    _scaleX.target = pressedScale;
    _scaleY.target = pressedScale;
    _ensureTicking();
  }

  void release({bool reduceMotion = false, int delayMs = 0}) {
    if (_disposed) return;
    _releaseTimer?.cancel();
    void doRelease() {
      if (_disposed) return;
      if (reduceMotion) {
        _pendingRelease = false;
        _press.snap(0.0);
        _scaleX.snap(initialScale);
        _scaleY.snap(initialScale);
        _vel.snap(0.0);
        notifyListeners();
        return;
      }
      if ((_val.position - _val.target).abs() > _span * 0.025) {
        _pendingRelease = true;
      } else {
        _pendingRelease = false;
        _press.target = 0.0;
        _scaleX.target = initialScale;
        _scaleY.target = initialScale;
        _vel.target = 0.0;
      }
      _ensureTicking();
    }

    if (delayMs > 0 && !reduceMotion) {
      _releaseTimer = Timer(Duration(milliseconds: delayMs), doRelease);
    } else {
      doRelease();
    }
  }

  void updateRange(double minV, double maxV, double currentV, {bool reduceMotion = false}) {
    minValue = minV;
    maxValue = maxV;
    final clamped = currentV.clamp(minValue, maxValue);
    if (reduceMotion) {
      _val.snap(clamped);
      notifyListeners();
      return;
    }
    _val.target = clamped;
    _ensureTicking();
  }

  void updateValue(double nextValue, {bool reduceMotion = false, bool trackVelocity = true}) {
    if (_disposed) return;
    final clamped = nextValue.clamp(minValue, maxValue);
    if (reduceMotion) {
      _val.snap(clamped);
      _vel.snap(0.0);
      notifyListeners();
      return;
    }

    if (trackVelocity) {
      final nowUs = _clock.elapsedMicroseconds;
      final dtSec = ((nowUs - _lastSampleUs) / 1000000.0).clamp(0.005, 0.12);
      final instantVel = ((clamped - _lastSampleVal) / _span) / dtSec;
      _lastSampleUs = nowUs;
      _lastSampleVal = clamped;
      _smoothedVel = (_smoothedVel * 0.62 + instantVel * 0.38).clamp(-16.0, 16.0);
      _vel.target = _smoothedVel;
      _velDecayTimer?.cancel();
      _velDecayTimer = Timer(const Duration(milliseconds: 55), () {
        if (!_disposed) {
          _smoothedVel = 0.0;
          _vel.target = 0.0;
          _ensureTicking();
        }
      });
    }

    _val.target = clamped;
    _ensureTicking();
  }

  /// Hands off finger fling velocity seamlessly into the spring settlement without
  /// re-calling [press] or injecting a stop-start delay.
  void settleTo(
    double nextValue, {
    double normalizedVelocity = 0.0,
    bool reduceMotion = false,
  }) {
    if (_disposed) return;
    final clamped = nextValue.clamp(minValue, maxValue);
    _velDecayTimer?.cancel();
    _smoothedVel = 0.0;
    if (reduceMotion) {
      _val.snap(clamped);
      _vel.snap(0.0);
      _press.snap(0.0);
      _scaleX.snap(initialScale);
      _scaleY.snap(initialScale);
      _pendingRelease = false;
      notifyListeners();
      return;
    }
    final clampedNormVel = normalizedVelocity.clamp(-16.0, 16.0);
    _val.target = clamped;
    if (clampedNormVel.abs() > 0.05) {
      _val.velocity = clampedNormVel * _span;
      _vel.target = clampedNormVel;
    } else {
      _vel.target = 0.0;
    }
    release(reduceMotion: false);
    _ensureTicking();
  }

  void snapValue(double nextValue) {
    if (_disposed) return;
    final clamped = nextValue.clamp(minValue, maxValue);
    _val.snap(clamped);
    notifyListeners();
  }

  void animateToValue(double nextValue, {bool reduceMotion = false}) {
    if (_disposed) return;
    final clamped = nextValue.clamp(minValue, maxValue);
    if (reduceMotion) {
      _val.snap(clamped);
      _vel.snap(0.0);
      notifyListeners();
      return;
    }
    press();
    _val.target = clamped;
    _vel.target = 0.0;
    _ensureTicking();
    release(delayMs: 90);
  }

  @override
  void dispose() {
    _disposed = true;
    _velDecayTimer?.cancel();
    _releaseTimer?.cancel();
    _ticker.dispose();
    super.dispose();
  }
}
