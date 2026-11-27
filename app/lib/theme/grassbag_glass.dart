import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'grassbag_theme.dart';
import 'kyant_liquid_glass.dart';

export 'kyant_liquid_glass.dart'
    show
        KyantDampedDragController,
        KyantHighlightKind,
        KyantInteractiveGlassButton,
        KyantLiquidGlass,
        KyantLiquidGlassEngine,
        KyantLiquidGlassStyle;

/// Centralized Apple iOS 27 & Kyant0 Liquid Glass material system for GrassBag.
///
/// Built strictly on `liquid_glass_widgets` 1.19.0's simulator-calibrated
/// [LiquidGlassSettings.ios27Light] / [LiquidGlassSettings.ios27Dark] /
/// [LiquidGlassSettings.ios27Indicator] optics and Apple's 2-layer separation rule:
/// - **Layer 1 (Content)**: Calm, clean, borderless (or whisper-hairline) continuous superellipse
///   surfaces (`GrassBagCard`, `GrassBagGroupedSection`, `GrassBagSheetSection`, `GrassBagTextField`)
///   — zero wireframe outlines, zero glass-on-glass clutter!
/// - **Layer 2 (Floating Chrome)**: Genuine iOS 27 `GlassLensModel.paraxial` + calibrated `frost`
///   cloud + folded optical bevel + dual-lobe `rimLight` (`lightIntensity: 0`, `fresnelStrength: 0`,
///   so Dark Mode never blooms into plastic neon white rings and Light Mode stays silky & legible).
/// - **Transient Lifted Lenses**: Real `_UILiquidLensView` paraxial water-droplet refraction +
///   Kyant0 chromatic dispersion on `GlassSwitch`, `GlassSlider`, and `GlassSegmentedControl`
///   (zero shaders at rest!).
abstract final class GrassBagGlassConfig {
  /// Quality for persistent floating chrome (nav buttons, title capsule, floating composer, sheets).
  static GlassQuality chromeQualityFor(GrassBagGlassTier tier) {
    if (tier == GrassBagGlassTier.solid) return GlassQuality.minimal;
    if (kIsWeb) return GlassQuality.standard;
    return switch (tier) {
      GrassBagGlassTier.liquid => GlassQuality.premium,
      GrassBagGlassTier.frosted => GlassQuality.standard,
      GrassBagGlassTier.solid => GlassQuality.minimal,
    };
  }

  /// Quality for body glass platters (overview hero card, studio diorama) — single-pass `standard`.
  static GlassQuality cardQualityFor(GrassBagGlassTier tier) => switch (tier) {
        GrassBagGlassTier.liquid => GlassQuality.standard,
        GrassBagGlassTier.frosted => GlassQuality.standard,
        GrassBagGlassTier.solid => GlassQuality.minimal,
      };

  /// Calibrated Apple iOS 27 `GlassLensModel.paraxial` + frost-cloud Liquid Glass for floating chrome
  /// (top nav pills, title capsule, floating composer, toasts):
  /// - `frost: 12.0` + `frostOpacity: 0.72` (Light) / `0.84` (Dark) delivers silky frosted legibility
  ///   while the paraxial ghost (`thickness: 30, n: 1.24`) folds the curved rim optically!
  /// - `lightIntensity: 0.0` & `fresnelStrength: 0.0` eliminate blinding Dark-mode neon rings,
  ///   leaving only Apple's measured dual-lobe `rimLight` and whisper-fine `rimShade` hairline.
  static LiquidGlassSettings surfaceSettings(
    GrassBagTokens t,
    GrassBagGlassTier tier, {
    bool elevated = false,
  }) {
    if (tier == GrassBagGlassTier.solid) {
      return LiquidGlassSettings(
        glassColor: t.cardSolid,
        blur: 0.0,
        frost: 0.0,
        frostOpacity: 0.0,
        thickness: 0.0,
        refractiveIndex: 1.0,
        lensModel: GlassLensModel.spherical,
        chromaticAberration: 0.0,
        saturation: 1.0,
        ambientRim: 0.0,
        rimShade: 0.0,
        rimLight: 0.0,
        shadow: const [],
      );
    }
    if (tier == GrassBagGlassTier.frosted || kIsWeb) {
      const blurSigma = 10.0;
      if (t.isDark) {
        return LiquidGlassSettings(
          glassColor: Colors.white.withValues(alpha: elevated ? 0.14 : 0.10),
          blur: blurSigma,
          frost: 0.0,
          frostOpacity: 0.0,
          thickness: 1.0,
          refractiveIndex: 1.01,
          lensModel: GlassLensModel.spherical,
          chromaticAberration: 0.0,
          saturation: 1.0,
          lightAngle: -math.pi / 2,
          lightIntensity: 0.0,
          ambientStrength: 0.05,
          ambientRim: 0.0,
          fresnelStrength: 0.12,
          edgeAbsorption: 0.02,
          rimShade: 0.0,
          rimLight: 0.36,
          bodyShade: elevated ? 0.18 : 0.14,
          specularSharpness: GlassSpecularSharpness.medium,
          shadow: const [],
        );
      }
      return LiquidGlassSettings(
        glassColor: Colors.white.withValues(alpha: elevated ? 0.62 : 0.54),
        blur: blurSigma,
        frost: 0.0,
        frostOpacity: 0.0,
        thickness: 1.0,
        refractiveIndex: 1.01,
        lensModel: GlassLensModel.spherical,
        chromaticAberration: 0.0,
        saturation: 1.0,
        lightAngle: math.pi / 2,
        lightIntensity: 0.0,
        ambientStrength: 0.03,
        ambientRim: 0.0,
        fresnelStrength: 0.10,
        whitenStrength: 0.12,
        whitenGated: true,
        edgeAbsorption: 0.015,
        rimShade: 0.0,
        rimLight: 0.42,
        bodyShade: 0.0,
        specularSharpness: GlassSpecularSharpness.medium,
        shadow: [
          BoxShadow(
            color: const Color(0x100E1F33),
            blurRadius: elevated ? 16 : 12,
            offset: Offset(0, elevated ? 5 : 4),
          ),
        ],
      );
    }

    if (t.isDark) {
      return LiquidGlassSettings(
        glassColor: Colors.white.withValues(alpha: elevated ? 0.15 : 0.12),
        saturation: 1.45,
        blur: 0.6,
        blurWeight: 2.5,
        frost: 12.0,
        frostOpacity: elevated ? 0.86 : 0.84,
        frostClamp: -0.45,
        frostWeight: 0.5,
        thickness: 30.0,
        refractiveIndex: 1.24,
        lensModel: GlassLensModel.paraxial,
        chromaticAberration: 0.0,
        lightAngle: -math.pi / 2,
        lightIntensity: 0.0,
        ambientStrength: 0.0,
        ambientRim: 0.0,
        fresnelStrength: 0.0,
        edgeAbsorption: 0.035,
        rimShade: 0.48,
        rimShadeEnds: 0.0,
        rimLight: 0.92,
        bodyShade: elevated ? 0.30 : 0.26,
        shadow: const [],
      );
    }

    return LiquidGlassSettings(
      glassColor: const Color(0xFFF8FAFD).withValues(alpha: elevated ? 0.60 : 0.54),
      saturation: 1.95,
      blur: 0.6,
      blurWeight: 0.8,
      frost: 12.0,
      frostOpacity: elevated ? 0.78 : 0.73,
      frostClamp: 0.40,
      frostWeight: 2.0,
      thickness: 30.0,
      refractiveIndex: 1.24,
      lensModel: GlassLensModel.paraxial,
      chromaticAberration: 0.0,
      lightAngle: math.pi / 2,
      lightIntensity: 0.0,
      ambientStrength: 0.0,
      ambientRim: 0.0,
      fresnelStrength: 0.0,
      edgeAbsorption: 0.030,
      rimShade: 0.45,
      rimShadeEnds: 0.20,
      rimLight: 1.0,
      bodyShade: 0.0,
      shadow: [
        BoxShadow(
          color: const Color(0x0D0E1F33),
          blurRadius: elevated ? 18 : 13,
          offset: Offset(0, elevated ? 6 : 4.5),
        ),
      ],
    );
  }

  /// Calibrated Apple iOS 27 modal sheet, '+' deck, alert platter, context menu & drawer glass:
  /// deeper `16dp` frost cloud (`frostOpacity: 0.84` Light / `0.88` Dark) keeps dense sheet content
  /// effortlessly readable over busy screens while retaining the folded paraxial rim & whisper speculars.
  static LiquidGlassSettings sheetSettings(GrassBagTokens t, GrassBagGlassTier tier) {
    final base = surfaceSettings(t, tier, elevated: true);
    if (tier == GrassBagGlassTier.solid) {
      return base;
    }
    if (tier != GrassBagGlassTier.liquid || kIsWeb) {
      return base.copyWith(
        glassColor: t.isDark
            ? Colors.white.withValues(alpha: 0.15)
            : Colors.white.withValues(alpha: 0.66),
        blur: kIsWeb ? 10.0 : 11.0,
        frost: 0.0,
        frostOpacity: 0.0,
        thickness: 1.0,
        refractiveIndex: 1.01,
        lensModel: GlassLensModel.spherical,
        saturation: 1.0,
        lightIntensity: 0.0,
        rimLight: t.isDark ? 0.34 : 0.40,
        rimShade: 0.0,
        ambientRim: 0.0,
        chromaticAberration: 0.0,
        bodyShade: t.isDark ? 0.22 : 0.0,
      );
    }
    return base.copyWith(
      glassColor: t.isDark
          ? Colors.white.withValues(alpha: 0.18)
          : const Color(0xFFF8FAFD).withValues(alpha: 0.72),
      blur: 0.6,
      blurWeight: t.isDark ? 2.5 : 0.8,
      frost: 16.0,
      frostOpacity: t.isDark ? 0.88 : 0.84,
      frostClamp: t.isDark ? -0.45 : 0.40,
      frostWeight: t.isDark ? 0.5 : 2.0,
      thickness: 32.0,
      refractiveIndex: 1.24,
      lensModel: GlassLensModel.paraxial,
      chromaticAberration: 0.0,
      saturation: t.isDark ? 1.40 : 1.75,
      bodyShade: t.isDark ? 0.36 : 0.0,
      lightAngle: t.isDark ? -math.pi / 2 : math.pi / 2,
      lightIntensity: 0.0,
      ambientStrength: 0.0,
      ambientRim: 0.0,
      fresnelStrength: 0.0,
      edgeAbsorption: t.isDark ? 0.032 : 0.026,
      rimLight: t.isDark ? 0.86 : 0.96,
      rimShade: t.isDark ? 0.42 : 0.38,
      rimShadeEnds: t.isDark ? 0.0 : 0.20,
      shadow: t.isDark
          ? const []
          : const [
              BoxShadow(
                color: Color(0x140E1F33),
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
    );
  }

  /// Clear Kyant0-inspired crystal prism lens preset for interactive optical showcases
  /// (Appearance Studio draggable lens capsule) — crisp curved refraction + chromatic dispersion
  /// without Dark-mode neon ring blow-out.
  static LiquidGlassSettings prismLensSettings(GrassBagTokens t, GrassBagGlassTier tier) {
    if (tier != GrassBagGlassTier.liquid || kIsWeb) {
      return surfaceSettings(t, tier);
    }
    return LiquidGlassSettings(
      glassColor: Colors.white.withValues(alpha: t.isDark ? 0.08 : 0.16),
      blur: 1.2,
      frost: 0.0,
      frostOpacity: 0.0,
      thickness: 26.0,
      refractiveIndex: 1.32,
      lensModel: GlassLensModel.spherical,
      chromaticAberration: 0.16,
      saturation: t.isDark ? 1.50 : 1.70,
      lightAngle: 0.75 * math.pi,
      lightIntensity: t.isDark ? 0.22 : 0.18,
      ambientStrength: 0.04,
      ambientRim: 0.0,
      fresnelStrength: t.isDark ? 0.22 : 0.18,
      edgeAbsorption: 0.024,
      rimShade: 0.0,
      rimLight: t.isDark ? 0.78 : 0.85,
      bodyShade: t.isDark ? 0.10 : 0.0,
      specularSharpness: GlassSpecularSharpness.sharp,
      shadow: const [],
    );
  }

  /// Global [GlassThemeData] wired into [LiquidGlassWidgets.wrap].
  /// Intentionally leaves [GlassThemeVariant.quality] as `null` in liquid mode so
  /// `liquid_glass_widgets` routes premium/standard per widget class cleanly (zero freezes!).
  static GlassThemeData themeDataFor(
    GrassBagTokens lightTokens,
    GrassBagTokens darkTokens,
    GrassBagGlassTier tier,
  ) {
    if (tier == GrassBagGlassTier.solid) {
      return const GlassThemeData(
        style: GlassStyle.ios27,
        light: GlassThemeVariant.minimalLight,
        dark: GlassThemeVariant.minimalDark,
      );
    }

    final isFrosted = tier == GrassBagGlassTier.frosted || kIsWeb;
    final lightSurf = surfaceSettings(lightTokens, tier);
    final darkSurf = surfaceSettings(darkTokens, tier);
    final indicatorTheme = isFrosted
        ? null
        : const GlassThemeSettings(
            lensModel: GlassLensModel.paraxial,
            thickness: 28.0,
            refractiveIndex: 1.24,
            chromaticAberration: 0.14,
            lightAngle: math.pi / 2,
            lightIntensity: 0.0,
            ambientStrength: 0.0,
            fresnelStrength: 0.0,
            rimLight: 1.0,
            rimShade: 0.65,
            rimShadeEnds: 0.50,
          );

    return GlassThemeData(
      style: GlassStyle.ios27,
      light: GlassThemeVariant.ios27Light.copyWith(
        settings: GlassThemeSettings.ios27Light.copyWith(
          glassColor: lightSurf.glassColor,
          blur: lightSurf.blur,
          frost: lightSurf.frost,
          frostOpacity: lightSurf.frostOpacity,
          thickness: lightSurf.thickness,
          refractiveIndex: lightSurf.refractiveIndex,
          lensModel: lightSurf.lensModel,
          chromaticAberration: lightSurf.chromaticAberration,
          saturation: lightSurf.saturation,
          lightAngle: lightSurf.lightAngle,
          lightIntensity: lightSurf.lightIntensity,
          ambientStrength: lightSurf.ambientStrength,
          fresnelStrength: lightSurf.fresnelStrength,
          edgeAbsorption: lightSurf.edgeAbsorption,
          rimShade: lightSurf.rimShade,
          rimLight: lightSurf.rimLight,
          bodyShade: lightSurf.bodyShade,
          shadow: const [],
        ),
        indicatorSettings: indicatorTheme,
        glowColors: GlassGlowColors(
          primary: lightTokens.primaryHi.withValues(alpha: 0.28),
          secondary: lightTokens.dusk.withValues(alpha: 0.22),
          success: lightTokens.ok.withValues(alpha: 0.24),
          warning: lightTokens.warn.withValues(alpha: 0.24),
          danger: lightTokens.err.withValues(alpha: 0.24),
          info: lightTokens.primary.withValues(alpha: 0.24),
          pressLight: Color.lerp(Colors.white, lightTokens.primaryHi, 0.20)!,
          glowBlurRadius: 0.0,
          glowSpreadRadius: 0.10,
        ),
      ),
      dark: GlassThemeVariant.ios27Dark.copyWith(
        settings: GlassThemeSettings.ios27Dark.copyWith(
          glassColor: darkSurf.glassColor,
          blur: darkSurf.blur,
          frost: darkSurf.frost,
          frostOpacity: darkSurf.frostOpacity,
          thickness: darkSurf.thickness,
          refractiveIndex: darkSurf.refractiveIndex,
          lensModel: darkSurf.lensModel,
          chromaticAberration: darkSurf.chromaticAberration,
          saturation: darkSurf.saturation,
          lightAngle: darkSurf.lightAngle,
          lightIntensity: darkSurf.lightIntensity,
          ambientStrength: darkSurf.ambientStrength,
          fresnelStrength: darkSurf.fresnelStrength,
          edgeAbsorption: darkSurf.edgeAbsorption,
          rimShade: darkSurf.rimShade,
          rimLight: darkSurf.rimLight,
          bodyShade: darkSurf.bodyShade,
          shadow: const [],
        ),
        indicatorSettings: indicatorTheme,
        glowColors: GlassGlowColors(
          primary: darkTokens.primary.withValues(alpha: 0.34),
          secondary: darkTokens.dusk.withValues(alpha: 0.26),
          success: darkTokens.ok.withValues(alpha: 0.28),
          warning: darkTokens.warn.withValues(alpha: 0.28),
          danger: darkTokens.err.withValues(alpha: 0.28),
          info: darkTokens.primaryHi.withValues(alpha: 0.28),
          pressLight: Color.lerp(Colors.white, darkTokens.primaryHi, 0.26)!,
          glowBlurRadius: 0.0,
          glowSpreadRadius: 0.10,
        ),
      ),
    );
  }
}

/// Explicit inherited scope carrying the active [GrassBagGlassTier] so Web builds and
/// custom thickness tunings always resolve the exact user-selected glass tier.
class GrassBagGlassTierScope extends InheritedWidget {
  const GrassBagGlassTierScope({
    super.key,
    required this.tier,
    required super.child,
  });

  final GrassBagGlassTier tier;

  static GrassBagGlassTier? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<GrassBagGlassTierScope>()
        ?.tier;
  }

  @override
  bool updateShouldNotify(GrassBagGlassTierScope oldWidget) =>
      oldWidget.tier != tier;
}

/// Resolves the effective [GrassBagGlassTier], cleanly routing OS High Contrast /
/// Reduce Transparency to [GrassBagGlassTier.solid] BEFORE `AdaptiveGlass` runs its
/// white-washing dark-mode fallback slab.
GrassBagGlassTier resolveEffectiveGlassTier(
  BuildContext context,
  GrassBagGlassTier requested,
) {
  if (MediaQuery.highContrastOf(context)) return GrassBagGlassTier.solid;
  return requested;
}

/// Resolves the ambient [GrassBagGlassTier] from [GrassBagGlassTierScope] (or falls back
/// to [GlassTheme] in isolated test trees) so content-layer crystal cards, sheet wells,
/// and controls stay harmonized across `liquid`, `frosted`, and `solid` tiers.
GrassBagGlassTier resolveAmbientGlassTier(BuildContext context) {
  if (MediaQuery.highContrastOf(context)) return GrassBagGlassTier.solid;
  final scoped = GrassBagGlassTierScope.maybeOf(context);
  if (scoped != null) return scoped;
  final glassTheme = GlassTheme.maybeOf(context)?.data;
  if (glassTheme?.light.quality == GlassQuality.minimal) {
    return GrassBagGlassTier.solid;
  }
  if ((glassTheme?.light.settings?.thickness ?? 32.0) <= 16.0) {
    return GrassBagGlassTier.frosted;
  }
  return GrassBagGlassTier.liquid;
}

/// Zero-shader 135° Fresnel specular glass rim painter matching GrassBag's global
/// `0.75 * pi` light source: bright luminous top-left catchlight, subtle prismatic
/// accent shimmer along the mid-bevel, clean shadow waist, and delicate opposite-edge
/// counter-glint — zero `BackdropFilter`, zero `saveLayer`, 100% 120Hz scroll-safe!
class GrassBagFresnelRimPainter extends CustomPainter {
  const GrassBagFresnelRimPainter({
    required this.isDark,
    this.borderRadius = 24.0,
    this.customBorderRadius,
    this.isPill = false,
    this.isCircle = false,
    this.useCircularRRect = false,
    this.accent,
    this.tinted = false,
    this.innerWell = false,
    this.frosted = false,
    this.paintTopSheen = true,
    this.strokeWidth,
  });

  final bool isDark;
  final double borderRadius;
  final BorderRadius? customBorderRadius;
  final bool isPill;
  final bool isCircle;
  final bool useCircularRRect;
  final Color? accent;
  final bool tinted;
  final bool innerWell;
  final bool frosted;
  final bool paintTopSheen;
  final double? strokeWidth;

  static final Map<Object, Path> _pathCache = <Object, Path>{};

  static Path cachedPathFor({
    required Size size,
    required Rect targetRect,
    double inset = 0.0,
    bool isCircle = false,
    bool isPill = false,
    bool useCircularRRect = false,
    double borderRadius = 24.0,
    BorderRadius? customBorderRadius,
  }) {
    final key = (
      (size.width * 2).round(),
      (size.height * 2).round(),
      isCircle,
      isPill,
      useCircularRRect,
      borderRadius,
      customBorderRadius,
      (inset * 100).round(),
    );
    final hit = _pathCache.remove(key);
    if (hit != null) {
      _pathCache[key] = hit;
      return hit;
    }
    final ShapeBorder shape;
    if (isCircle) {
      shape = const CircleBorder();
    } else if (isPill) {
      shape = const StadiumBorder();
    } else if (customBorderRadius != null) {
      final br = customBorderRadius;
      Radius shrink(Radius r) => Radius.elliptical(
            math.max(0.0, r.x - inset),
            math.max(0.0, r.y - inset),
          );
      final shrunk = BorderRadius.only(
        topLeft: shrink(br.topLeft),
        topRight: shrink(br.topRight),
        bottomLeft: shrink(br.bottomLeft),
        bottomRight: shrink(br.bottomRight),
      );
      shape = useCircularRRect
          ? RoundedRectangleBorder(borderRadius: shrunk)
          : RoundedSuperellipseBorder(borderRadius: shrunk);
    } else {
      final r = BorderRadius.circular(math.max(0.0, borderRadius - inset));
      shape = useCircularRRect
          ? RoundedRectangleBorder(borderRadius: r)
          : RoundedSuperellipseBorder(borderRadius: r);
    }
    final built = shape.getOuterPath(targetRect);
    if (_pathCache.length >= 256) {
      _pathCache.remove(_pathCache.keys.first);
    }
    _pathCache[key] = built;
    return built;
  }

  Path _cachedOuterPath(Size size, Rect targetRect, double inset) =>
      cachedPathFor(
        size: size,
        targetRect: targetRect,
        inset: inset,
        isCircle: isCircle,
        isPill: isPill,
        useCircularRRect: useCircularRRect,
        borderRadius: borderRadius,
        customBorderRadius: customBorderRadius,
      );

  /// Centered square of side `(w + h) / 2` so `Alignment.topLeft -> Alignment.bottomRight`
  /// preserves a true 45° (135°) optical Fresnel angle across wide pills while landing
  /// `t = 0.0` precisely at `(0, 0)` and `t = 1.0` precisely at `(w, h)`.
  static Rect _trueDiagonalBox(Rect rect) {
    final side = (rect.width + rect.height) * 0.5;
    return Rect.fromCenter(center: rect.center, width: side, height: side);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0.5 || size.height <= 0.5) return;
    final rect = Offset.zero & size;
    final diagonalRect = _trueDiagonalBox(rect);
    final sw = strokeWidth ?? (tinted ? 0.9 : (isDark ? 0.9 : 1.0));
    final halfSw = sw * 0.5;
    final insetRect = rect.deflate(halfSw);

    // 0. Tight Kyant0-style top curved meniscus glint with pure vertical fade to 0.0 at sheenHeight
    //    so wide shallow surfaces NEVER hard-clip along y = sheenHeight; disabled on concave innerWells!
    if (paintTopSheen && !frosted && !innerWell) {
      final clipPath = _cachedOuterPath(size, rect, 0.0);
      final sheenAlpha = tinted
          ? (isDark ? 0.12 : 0.20)
          : (isDark ? 0.05 : 0.18);
      final sheenHeight = math.min(size.height * 0.20, 18.0);
      final sheenRect = Rect.fromLTWH(0, 0, size.width, sheenHeight);
      canvas.save();
      canvas.clipPath(clipPath);
      canvas.drawRect(
        sheenRect,
        Paint()
          ..blendMode = isDark ? BlendMode.plus : BlendMode.screen
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: sheenAlpha),
              Colors.white.withValues(alpha: sheenAlpha * 0.22),
              Colors.transparent,
            ],
            stops: const [0.0, 0.42, 1.0],
          ).createShader(sheenRect),
      );
      canvas.restore();
    }

    // Clean single-pass 135° Apple iOS 26 luminous hairline rim:
    // ZERO muddy black outer contours, ZERO double-stroke inner dark rings, and ZERO
    // inverted dark top bevels on Light-mode innerWells!
    final rawAccent = accent ?? Colors.white;
    final hsl = HSLColor.fromColor(rawAccent);
    final isMonochrome = hsl.saturation < 0.08;
    final prismAccent = isMonochrome ? Colors.white : rawAccent;
    final counterPrism = isMonochrome
        ? Colors.white
        : hsl.withHue((hsl.hue + 24.0) % 360.0).withLightness(isDark ? 0.78 : 0.72).toColor();
    final List<Color> rimColors;
    final BlendMode rimBlend;
    if (tinted) {
      rimBlend = isDark ? BlendMode.plus : BlendMode.screen;
      rimColors = [
        Colors.white.withValues(alpha: isDark ? 0.44 : 0.62),
        Color.lerp(Colors.white, prismAccent, 0.25)!.withValues(alpha: isDark ? 0.18 : 0.26),
        Colors.white.withValues(alpha: 0.02),
        Colors.white.withValues(alpha: 0.03),
        Color.lerp(Colors.white, counterPrism, 0.22)!.withValues(alpha: isDark ? 0.12 : 0.16),
        Colors.white.withValues(alpha: isDark ? 0.24 : 0.32),
      ];
    } else if (isDark) {
      rimBlend = BlendMode.plus;
      final peak = frosted ? 0.15 : (innerWell ? 0.16 : 0.22);
      final bounce = frosted ? 0.06 : (innerWell ? 0.07 : 0.11);
      rimColors = [
        Colors.white.withValues(alpha: peak),
        Color.lerp(Colors.white, prismAccent, 0.32)!.withValues(alpha: frosted ? 0.06 : 0.11),
        Colors.white.withValues(alpha: 0.02),
        Colors.white.withValues(alpha: 0.025),
        Color.lerp(Colors.white, counterPrism, 0.28)!.withValues(alpha: frosted ? 0.04 : 0.07),
        Colors.white.withValues(alpha: bounce),
      ];
    } else {
      rimBlend = BlendMode.srcOver;
      final peak = frosted ? 0.84 : (innerWell ? 0.76 : 0.96);
      final bounce = frosted ? 0.56 : (innerWell ? 0.52 : 0.78);
      final waist = innerWell ? const Color(0x07162E42) : const Color(0x09162E42);
      rimColors = [
        Colors.white.withValues(alpha: peak),
        Colors.white.withValues(alpha: frosted ? 0.54 : (innerWell ? 0.42 : 0.68)),
        waist,
        waist,
        Colors.white.withValues(alpha: frosted ? 0.44 : (innerWell ? 0.34 : 0.56)),
        Colors.white.withValues(alpha: bounce),
      ];
    }

    final rimPath = _cachedOuterPath(size, insetRect, halfSw);
    canvas.drawPath(
      rimPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth ?? (innerWell ? 0.7 : 0.85)
        ..blendMode = rimBlend
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: rimColors,
          stops: const [0.0, 0.20, 0.45, 0.66, 0.86, 1.0],
        ).createShader(diagonalRect),
    );
  }

  @override
  bool shouldRepaint(covariant GrassBagFresnelRimPainter old) =>
      old.isDark != isDark ||
      old.borderRadius != borderRadius ||
      old.customBorderRadius != customBorderRadius ||
      old.isPill != isPill ||
      old.isCircle != isCircle ||
      old.useCircularRRect != useCircularRRect ||
      old.accent != accent ||
      old.tinted != tinted ||
      old.innerWell != innerWell ||
      old.frosted != frosted ||
      old.paintTopSheen != paintTopSheen ||
      old.strokeWidth != strokeWidth;
}

/// Zero-shader Kyant0-inspired `InteractiveHighlight`: tracks fingertip position passively
/// (via `Listener`, never competing in the gesture arena!) and paints a smooth spring-eased
/// additive radial spotlight + local curved-bevel rim flare directly inside the glass shape.
/// Zero `setState` during pointer movement and zero paint cost when at rest (`alpha == 0`).
class GrassBagInteractiveHighlight extends StatefulWidget {
  const GrassBagInteractiveHighlight({
    super.key,
    required this.child,
    this.borderRadius = 16.0,
    this.isPill = false,
    this.isCircle = false,
    this.accent,
    this.enabled = true,
  });

  final Widget child;
  final double borderRadius;
  final bool isPill;
  final bool isCircle;
  final Color? accent;
  final bool enabled;

  @override
  State<GrassBagInteractiveHighlight> createState() => _GrassBagInteractiveHighlightState();
}

class _GrassBagInteractiveHighlightState extends State<GrassBagInteractiveHighlight>
    with SingleTickerProviderStateMixin {
  AnimationController? _alphaCtrl;
  CurvedAnimation? _alphaAnim;
  ValueNotifier<Offset>? _touchPos;
  Listenable? _repaintListenable;
  int? _activePointerId;
  Offset? _downPos;
  Axis? _scrollableAxis;
  bool _suppressed = false;
  bool _shown = false;
  Timer? _scrollDeferTimer;
  Timer? _quickGlintTimer;

  void _ensureAnim() {
    if (_alphaCtrl != null) return;
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      reverseDuration: const Duration(milliseconds: 280),
    );
    final anim = CurvedAnimation(
      parent: ctrl,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final pos = ValueNotifier<Offset>(Offset.zero);
    _alphaCtrl = ctrl;
    _alphaAnim = anim;
    _touchPos = pos;
    _repaintListenable = Listenable.merge([anim, pos]);
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant GrassBagInteractiveHighlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _cancelTimers();
      _activePointerId = null;
      _downPos = null;
      _suppressed = false;
      _shown = false;
      _alphaCtrl?.value = 0.0;
    }
  }

  void _cancelTimers() {
    _scrollDeferTimer?.cancel();
    _scrollDeferTimer = null;
    _quickGlintTimer?.cancel();
    _quickGlintTimer = null;
  }

  @override
  void dispose() {
    _cancelTimers();
    _alphaAnim?.dispose();
    _alphaCtrl?.dispose();
    _touchPos?.dispose();
    super.dispose();
  }

  void _onDown(PointerDownEvent e) {
    if (_activePointerId != null) return;
    _ensureAnim();
    _cancelTimers();
    _activePointerId = e.pointer;
    _downPos = e.localPosition;
    _suppressed = false;
    _shown = false;
    _touchPos!.value = e.localPosition;
    final scrollable = Scrollable.maybeOf(context);
    _scrollableAxis =
        scrollable != null ? axisDirectionToAxis(scrollable.axisDirection) : null;
    if (_scrollableAxis != null) {
      _scrollDeferTimer = Timer(const Duration(milliseconds: 45), () {
        if (!mounted || _suppressed || _activePointerId != e.pointer) return;
        _shown = true;
        _alphaCtrl?.forward();
      });
    } else {
      _shown = true;
      _alphaCtrl?.forward();
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (_activePointerId != e.pointer || _suppressed) return;
    final down = _downPos;
    final scrollAxis = _scrollableAxis;
    if (down != null && scrollAxis != null) {
      final delta = e.localPosition - down;
      final isVert = scrollAxis == Axis.vertical;
      final scrollDragged = isVert
          ? (delta.dy.abs() > 10.0 && delta.dy.abs() > delta.dx.abs() * 1.15)
          : (delta.dx.abs() > 10.0 && delta.dx.abs() > delta.dy.abs() * 1.15);
      if (scrollDragged) {
        _suppressed = true;
        _scrollDeferTimer?.cancel();
        _scrollDeferTimer = null;
        final ctrl = _alphaCtrl;
        if (ctrl != null && (ctrl.value > 0.0 || ctrl.isAnimating)) {
          ctrl.reverse();
        }
        return;
      }
    }
    _touchPos?.value = e.localPosition;
  }

  void _onUp(PointerUpEvent e) {
    if (_activePointerId != e.pointer) return;
    _activePointerId = null;
    _downPos = null;
    _scrollDeferTimer?.cancel();
    _scrollDeferTimer = null;
    final ctrl = _alphaCtrl;
    if (ctrl == null) return;
    if (!_suppressed && !_shown) {
      // Brisk tap inside a ScrollView: emit a clean micro-glint without sticking!
      ctrl.forward(from: 0.32);
      _quickGlintTimer = Timer(const Duration(milliseconds: 110), () {
        if (mounted) _alphaCtrl?.reverse();
      });
      return;
    }
    if (ctrl.value > 0.0 || ctrl.isAnimating) {
      ctrl.reverse();
    }
  }

  void _onCancel(PointerCancelEvent e) {
    if (_activePointerId != e.pointer) return;
    _activePointerId = null;
    _downPos = null;
    _cancelTimers();
    final ctrl = _alphaCtrl;
    if (ctrl != null && (ctrl.value > 0.0 || ctrl.isAnimating)) {
      ctrl.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    final t = GrassBagTokens.of(context);
    final listenable = _repaintListenable;
    // Keep constant CustomPaint tree depth before & after first touch so child
    // glass / shader subtrees NEVER unmount & remount on initial pointer down!
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: CustomPaint(
        foregroundPainter: listenable == null
            ? null
            : _GrassBagInteractiveHighlightPainter(
                repaint: listenable,
                alpha: _alphaAnim!,
                touchPos: _touchPos!,
                isDark: t.isDark,
                accent: widget.accent ?? t.primaryHi,
                borderRadius: widget.borderRadius,
                isPill: widget.isPill,
                isCircle: widget.isCircle,
              ),
        child: widget.child,
      ),
    );
  }
}

class _GrassBagInteractiveHighlightPainter extends CustomPainter {
  _GrassBagInteractiveHighlightPainter({
    required Listenable repaint,
    required this.alpha,
    required this.touchPos,
    required this.isDark,
    required this.accent,
    required this.borderRadius,
    required this.isPill,
    required this.isCircle,
  }) : super(repaint: repaint);

  final Animation<double> alpha;
  final ValueNotifier<Offset> touchPos;
  final bool isDark;
  final Color accent;
  final double borderRadius;
  final bool isPill;
  final bool isCircle;

  @override
  void paint(Canvas canvas, Size size) {
    final a = alpha.value.clamp(0.0, 1.0);
    if (a <= 0.005 || size.width <= 0.5 || size.height <= 0.5) return;
    final rect = Offset.zero & size;
    final clipPath = GrassBagFresnelRimPainter.cachedPathFor(
      size: size,
      targetRect: rect,
      inset: 0.0,
      isCircle: isCircle,
      isPill: isPill,
      borderRadius: borderRadius,
    );
    final rimPath = GrassBagFresnelRimPainter.cachedPathFor(
      size: size,
      targetRect: rect.deflate(0.65),
      inset: 0.65,
      isCircle: isCircle,
      isPill: isPill,
      borderRadius: borderRadius,
    );
    final rawPos = touchPos.value;
    final pos = Offset(
      rawPos.dx.clamp(0.0, size.width),
      rawPos.dy.clamp(0.0, size.height),
    );
    final radius = math.max(size.shortestSide * 1.15, 58.0);
    final spotRect = Rect.fromCircle(center: pos, radius: radius);

    canvas.save();
    canvas.clipPath(clipPath);
    // 1. Kyant0 touch-following radial spotlight:
    //    Dark mode uses additive white+accent glow; Light mode uses translucent tinted
    //    specular wash (`srcOver`) so it reads crisply even over 80%-white glass cards!
    final spotColor = Color.lerp(Colors.white, accent, isDark ? 0.24 : 0.36)!;
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = isDark ? BlendMode.plus : BlendMode.srcOver
        ..shader = RadialGradient(
          colors: [
            spotColor.withValues(alpha: (isDark ? 0.20 : 0.24) * a),
            spotColor.withValues(alpha: (isDark ? 0.065 : 0.09) * a),
            Colors.transparent,
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(spotRect),
    );
    canvas.restore();

    // 2. Local rim specular glint illuminating the curved bevel nearest the fingertip
    canvas.drawPath(
      rimPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..blendMode = isDark ? BlendMode.plus : BlendMode.srcOver
        ..shader = RadialGradient(
          colors: [
            (isDark ? Colors.white : Color.lerp(Colors.white, accent, 0.30)!)
                .withValues(alpha: (isDark ? 0.54 : 0.68) * a),
            accent.withValues(alpha: (isDark ? 0.24 : 0.42) * a),
            Colors.transparent,
          ],
          stops: const [0.0, 0.48, 1.0],
        ).createShader(Rect.fromCircle(center: pos, radius: radius * 0.85)),
    );
  }

  @override
  bool shouldRepaint(covariant _GrassBagInteractiveHighlightPainter old) =>
      old.isDark != isDark ||
      old.accent != accent ||
      old.borderRadius != borderRadius ||
      old.isPill != isPill ||
      old.isCircle != isCircle;
}

/// Calm Apple iOS 27 Layer-1 content container & recessed tonal well (`secondarySystemGroupedBackground`
/// for content cards; `tertiarySystemFill` for nested wells, search bars, and inline pills).
///
/// Deliberately omits heavy specular wireframe outlines so scrollable content stays effortless
/// and calm, letting genuine Layer-2 Liquid Glass floating chrome stand out crisply above it.
class GrassBagFresnelGlassSurface extends StatelessWidget {
  const GrassBagFresnelGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = 16.0,
    this.isPill = false,
    this.isCircle = false,
    this.innerWell = false,
    this.elevated = false,
    this.interactive = false,
    this.paintTopSheen = true,
    this.padding,
    this.width,
    this.height,
    this.alignment,
    this.tintColor,
    this.clipBehavior = Clip.none,
  });

  final Widget child;
  final double borderRadius;
  final bool isPill;
  final bool isCircle;
  final bool innerWell;
  final bool elevated;
  final bool interactive;
  final bool paintTopSheen;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;
  final AlignmentGeometry? alignment;
  final Color? tintColor;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final ambientTier = resolveAmbientGlassTier(context);
    final isSolid = ambientTier == GrassBagGlassTier.solid;
    final highContrast = MediaQuery.highContrastOf(context);

    // Calm iOS 27 surface fills:
    // - Content cards (`!innerWell`, no tint): crisp luminous white in Light Mode, softly lifted
    //   elevated slate in Dark Mode — unmistakable figure-ground separation with ZERO wireframe glare!
    // - Recessed wells (`innerWell`, no tint): iOS 27 `tertiarySystemFill` — quiet borderless well
    //   that nests effortlessly inside both white/dark cards and floating Liquid Glass sheets.
    final Color surfaceColor;
    if (tintColor != null) {
      surfaceColor = tintColor!;
    } else if (innerWell) {
      surfaceColor = t.isDark
          ? Colors.white.withValues(alpha: isSolid ? 0.095 : 0.085)
          : const Color(0x11162E42);
    } else {
      surfaceColor = t.isDark
          ? Color.lerp(t.cardSolid, Colors.white, 0.055)!
              .withValues(alpha: isSolid ? 1.0 : 0.90)
          : Colors.white.withValues(alpha: isSolid ? 1.0 : 0.92);
    }

    // Only paint a border for High Contrast accessibility, Solid tier cards, or a whisper-quiet
    // 0.5px separation hairline on Dark Mode content cards (NEVER glowing neon wireframes!).
    final BorderSide side;
    if (highContrast) {
      side = BorderSide(color: t.sepStrong, width: 1.1);
    } else if (isSolid && !innerWell && tintColor == null) {
      side = BorderSide(color: t.sep, width: 0.65);
    } else if (!innerWell && tintColor == null && t.isDark) {
      side = BorderSide(color: Colors.white.withValues(alpha: 0.075), width: 0.5);
    } else {
      side = BorderSide.none;
    }

    final ShapeBorder baseShape = isCircle
        ? CircleBorder(side: side)
        : (isPill
            ? StadiumBorder(side: side)
            : RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(borderRadius),
                side: side,
              ));

    final shadows = (!elevated || innerWell || tintColor != null)
        ? null
        : [
            BoxShadow(
              color: t.isDark
                  ? Colors.black.withValues(alpha: isSolid ? 0.22 : 0.26)
                  : const Color(0x0A0E243B),
              blurRadius: isSolid ? 12 : 16,
              offset: const Offset(0, 4),
            ),
          ];

    Widget body = padding != null || alignment != null || width != null || height != null
        ? Container(
            width: width,
            height: height,
            padding: padding,
            alignment: alignment,
            child: child,
          )
        : child;

    if (clipBehavior != Clip.none) {
      body = isCircle
          ? ClipOval(clipBehavior: clipBehavior, child: body)
          : ClipRSuperellipse(
              borderRadius: BorderRadius.circular(isPill ? 999 : borderRadius),
              clipBehavior: clipBehavior,
              child: body,
            );
    }

    final decorated = DecoratedBox(
      decoration: ShapeDecoration(
        color: surfaceColor,
        shape: baseShape,
        shadows: shadows,
      ),
      child: body,
    );

    if (isSolid || !interactive) return decorated;
    return GrassBagInteractiveHighlight(
      borderRadius: borderRadius,
      isPill: isPill,
      isCircle: isCircle,
      accent: t.primaryHi,
      child: decorated,
    );
  }
}

/// Full-bleed screen root layering the static [GrassBagCanvasBackground] behind [child].
/// Avoids `GlassPage`'s unused full-screen `LiquidGlassLayer` + `GeometryTransformTrackingLayer`
/// + per-frame `ClipRSuperellipse` / `MaskFilter.blur` route transition shadow across all 14 routes!
class GrassBagGlassPage extends StatelessWidget {
  const GrassBagGlassPage({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const GrassBagCanvasBackground(),
        child,
      ],
    );
  }
}

/// Semantic bar scope for floating navigation pill rows.
/// With GrassBag's single-pass direct-SDF [KyantLiquidGlass] engine, sibling pills render
/// directly with zero `toImageSync` geometry rasterization stalls or shared-clip clipping!
class GrassBagGlassBarLayer extends StatelessWidget {
  const GrassBagGlassBarLayer({
    super.key,
    required this.tier,
    required this.child,
    this.platformViewBackdrop = false,
  });

  final GrassBagGlassTier tier;
  final Widget child;
  final bool platformViewBackdrop;

  @override
  Widget build(BuildContext context) => child;
}

/// Public-API materialization progress scope propagated by [GrassBagMaterializeTransition]
/// so both Solid-tier `GrassBagGlass` containers and Dark-mode outer elevation shadows
/// dissolve in exact lock-step with Impeller's shader-level materialization (zero snap-in,
/// zero disembodied dark halo ring at frame 0 or on exit!).
class GrassBagMaterializeScope extends InheritedWidget {
  const GrassBagMaterializeScope({
    super.key,
    this.progress,
    this.animation,
    required super.child,
  });

  final double? progress;
  final Animation<double>? animation;

  static Animation<double>? animationOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<GrassBagMaterializeScope>()
        ?.animation;
  }

  static double progressOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<GrassBagMaterializeScope>();
    if (scope == null) return 1.0;
    final p = scope.progress ?? scope.animation?.value ?? 1.0;
    return p.clamp(0.0, 1.0);
  }

  @override
  bool updateShouldNotify(GrassBagMaterializeScope oldWidget) =>
      oldWidget.progress != progress || oldWidget.animation != animation;
}

/// Unified iOS 26 materialization transition across Liquid, Frosted, and Solid tiers.
/// - Liquid / Frosted: delegates optical blur/refraction ramp to [GlassMaterializeTransition]
///   with `scaleFrom: 1.0` while driving scale via a stateful [CurvedAnimation] (`easeOutCubic`
///   / `easeInCubic`) so popovers, dialogs, and sheets ease to rest instead of hard-stopping at `t=0.92`.
/// - Solid: smooth `FadeTransition` + `ScaleTransition` using cached [CurvedAnimation]s (zero listener leaks).
class GrassBagMaterializeTransition extends StatefulWidget {
  const GrassBagMaterializeTransition({
    super.key,
    required this.animation,
    required this.tier,
    required this.child,
    this.alignment = Alignment.center,
    this.scaleFrom = 0.90,
    this.contentSigma = 5.0,
  });

  final Animation<double> animation;
  final GrassBagGlassTier tier;
  final Widget child;
  final Alignment alignment;
  final double scaleFrom;
  final double contentSigma;

  @override
  State<GrassBagMaterializeTransition> createState() =>
      _GrassBagMaterializeTransitionState();
}

class _GrassBagMaterializeTransitionState
    extends State<GrassBagMaterializeTransition> {
  late CurvedAnimation _scaleCurve;
  late CurvedAnimation _fadeCurve;
  late Animation<double> _scaleAnim;

  void _initCurves() {
    _scaleCurve = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _fadeCurve = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );
    _scaleAnim = Tween<double>(begin: widget.scaleFrom, end: 1.0)
        .animate(_scaleCurve);
  }

  @override
  void initState() {
    super.initState();
    _initCurves();
  }

  @override
  void didUpdateWidget(covariant GrassBagMaterializeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _scaleCurve.dispose();
      _fadeCurve.dispose();
      _initCurves();
    } else if (oldWidget.scaleFrom != widget.scaleFrom) {
      _scaleAnim = Tween<double>(begin: widget.scaleFrom, end: 1.0)
          .animate(_scaleCurve);
    }
  }

  @override
  void dispose() {
    _scaleCurve.dispose();
    _fadeCurve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveTier = resolveEffectiveGlassTier(context, widget.tier);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (effectiveTier == GrassBagGlassTier.solid) {
      if (reduceMotion) {
        return FadeTransition(opacity: _fadeCurve, child: widget.child);
      }
      return FadeTransition(
        opacity: _fadeCurve,
        child: ScaleTransition(
          alignment: widget.alignment,
          scale: _scaleAnim,
          child: widget.child,
        ),
      );
    }
    // Propagate curved materialization progress via [GrassBagMaterializeScope] WITHOUT
    // wrapping [KyantLiquidGlass] (`BackdropFilterLayer`) in an outer `FadeTransition`
    // (`OpacityLayer`), eliminating Impeller offscreen `saveLayer` backdrop pops and `t²`
    // double-fading! Glass containers fade their own optics via `visibility` and their
    // inner content via zero-layer-at-rest [GrassBagControlledOpacity].
    return GrassBagMaterializeScope(
      animation: _fadeCurve,
      child: reduceMotion
          ? widget.child
          : ScaleTransition(
              alignment: widget.alignment,
              scale: _scaleAnim,
              child: widget.child,
            ),
    );
  }
}

/// Unified Liquid Glass floating container powered by GrassBag's faithful Kyant0
/// `AndroidLiquidGlass` GLSL engine ([KyantLiquidGlass]).
///
/// Delivers exact Kyant0 `vibrancy() -> blur -> lens(refractionHeight, refractionAmount,
/// depthEffect, chromaticAberration) -> surfaceColor -> Highlight.Default/Plain -> Shadow`
/// optics with zero `toImageSync` stalls and full nested-glass support!
class GrassBagGlass extends StatelessWidget {
  const GrassBagGlass({
    super.key,
    required this.child,
    required this.tier,
    this.borderRadius = 22,
    this.isOval = false,
    this.elevated = false,
    this.useCardQuality = false,
    this.useSheetSettings = false,
    this.isDialog = false,
    this.useOwnLayer = true,
    this.platformViewBackdrop = false,
    this.interactiveGlow = false,
    this.width,
    this.height,
    this.padding,
    this.alignment,
    this.tintColor,
    this.clipBehavior = Clip.none,
  });

  final Widget child;
  final GrassBagGlassTier tier;
  final double borderRadius;
  final bool isOval;
  final bool elevated;
  final bool useCardQuality;
  final bool useSheetSettings;
  final bool isDialog;
  final bool useOwnLayer;
  final bool platformViewBackdrop;
  final bool interactiveGlow;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final AlignmentGeometry? alignment;
  final Color? tintColor;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final effectiveTier = resolveEffectiveGlassTier(context, tier);
    final highContrast = MediaQuery.highContrastOf(context);
    final materializeAnim = GrassBagMaterializeScope.animationOf(context);
    final isPill = !isOval && borderRadius >= 900;

    final innerChild = (padding != null || alignment != null || width != null || height != null)
        ? Container(
            width: width,
            height: height,
            padding: padding,
            alignment: alignment,
            child: child,
          )
        : child;

    if (effectiveTier == GrassBagGlassTier.solid) {
      Widget buildSolid(double materialize) {
        final baseFill = tintColor ?? t.cardSolid;
        final solidFill = materialize >= 0.999
            ? baseFill
            : baseFill.withValues(alpha: baseFill.a * materialize);
        final solidBorder = materialize >= 0.999
            ? t.sepStrong
            : t.sepStrong.withValues(alpha: t.sepStrong.a * materialize);
        final strokeW = highContrast ? 1.15 : 0.6;
        final solidShape = isOval
            ? CircleBorder(side: BorderSide(color: solidBorder, width: strokeW))
            : RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(borderRadius),
                side: BorderSide(color: solidBorder, width: strokeW),
              );
        final clippedChild = clipBehavior == Clip.none
            ? innerChild
            : (isOval
                ? ClipOval(clipBehavior: clipBehavior, child: innerChild)
                : ClipRRect(
                    borderRadius: BorderRadius.circular(borderRadius),
                    clipBehavior: clipBehavior,
                    child: innerChild,
                  ));
        final body = materialize >= 0.999
            ? clippedChild
            : GrassBagControlledOpacity(opacity: materialize, child: clippedChild);
        return DecoratedBox(
          decoration: ShapeDecoration(
            color: solidFill,
            shape: solidShape,
            shadows: materialize <= 0.01
                ? const []
                : [
                    BoxShadow(
                      color: Colors.black
                          .withValues(alpha: (t.isDark ? 0.28 : 0.08) * materialize),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: body,
        );
      }

      if (materializeAnim != null) {
        return AnimatedBuilder(
          animation: materializeAnim,
          builder: (_, __) => buildSolid(materializeAnim.value.clamp(0.0, 1.0)),
        );
      }
      return buildSolid(GrassBagMaterializeScope.progressOf(context));
    }

    // PlatformView (WebView / Camera) safe translucent frosted veil (no BackdropFilter over SurfaceView)
    if (platformViewBackdrop) {
      final darkPv = tintColor != null ? tintColor!.computeLuminance() < 0.35 : t.isDark;
      final fill = tintColor ??
          (darkPv
              ? const Color(0xFF141820).withValues(alpha: 0.78)
              : const Color(0xFFFAFAFA).withValues(alpha: 0.84));
      final shape = isOval
          ? CircleBorder(
              side: BorderSide(
                color: Colors.white.withValues(alpha: darkPv ? 0.18 : 0.80),
                width: 0.65,
              ),
            )
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(borderRadius),
              side: BorderSide(
                color: Colors.white.withValues(alpha: darkPv ? 0.18 : 0.80),
                width: 0.65,
              ),
            );
      final clipped = clipBehavior == Clip.none
          ? innerChild
          : (isOval
              ? ClipOval(clipBehavior: clipBehavior, child: innerChild)
              : ClipRRect(
                  borderRadius: BorderRadius.circular(borderRadius),
                  clipBehavior: clipBehavior,
                  child: innerChild,
                ));
      return DecoratedBox(
        decoration: ShapeDecoration(
          color: fill,
          shape: shape,
          shadows: [
            BoxShadow(
              color: Colors.black.withValues(alpha: darkPv ? 0.30 : 0.10),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: clipped,
      );
    }

    final style = useSheetSettings || isDialog
        ? KyantLiquidGlassStyle.sheet(
            t,
            effectiveTier,
            isDialog: isDialog,
            tintColor: tintColor,
          )
        : (useCardQuality && effectiveTier == GrassBagGlassTier.liquid
            ? KyantLiquidGlassStyle.chrome(
                t,
                GrassBagGlassTier.frosted,
                elevated: elevated,
                tintColor: tintColor,
              )
            : KyantLiquidGlassStyle.chrome(
                t,
                effectiveTier,
                elevated: elevated,
                tintColor: tintColor,
              ));

    Widget buildKyant(double visibility) {
      final fadedContent = visibility >= 0.999
          ? innerChild
          : GrassBagControlledOpacity(opacity: visibility, child: innerChild);
      final glass = KyantLiquidGlass(
        style: style,
        borderRadius: BorderRadius.circular(borderRadius),
        isCapsule: isPill,
        isCircle: isOval,
        visibility: visibility,
        clipBehavior: clipBehavior,
        child: fadedContent,
      );
      if (!interactiveGlow) return glass;
      return GrassBagInteractiveHighlight(
        borderRadius: borderRadius,
        isPill: isPill,
        isCircle: isOval,
        accent: tintColor ?? t.primaryHi,
        child: glass,
      );
    }

    if (materializeAnim != null) {
      return AnimatedBuilder(
        animation: materializeAnim,
        builder: (_, __) => buildKyant(materializeAnim.value.clamp(0.0, 1.0)),
      );
    }
    return buildKyant(GrassBagMaterializeScope.progressOf(context));
  }
}

/// 44×44 symmetrical circular Kyant0 Liquid Glass icon button with authentic curved refraction,
/// 0.65dp opposite-corner specular rim, touch-following glow, and `tanh` elastic stretch!
class GrassBagGlassCircleButton extends StatelessWidget {
  const GrassBagGlassCircleButton({
    super.key,
    required this.icon,
    required this.tier,
    required this.onTap,
    this.tooltip,
    this.iconColor,
    this.size = 44,
    this.iconSize = 20,
    this.tintColor,
    this.platformViewBackdrop = false,
    this.useOwnLayer = true,
  });

  final IconData icon;
  final GrassBagGlassTier tier;
  final VoidCallback onTap;
  final String? tooltip;
  final Color? iconColor;
  final double size;
  final double iconSize;
  final Color? tintColor;
  final bool platformViewBackdrop;
  final bool useOwnLayer;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final effectiveTier = resolveEffectiveGlassTier(context, tier);
    final highContrast = MediaQuery.highContrastOf(context);
    final isSolid = effectiveTier == GrassBagGlassTier.solid;
    final iconWidget = Icon(icon, size: iconSize, color: iconColor ?? t.text);

    if (isSolid || platformViewBackdrop) {
      final darkPv = tintColor != null
          ? tintColor!.computeLuminance() < 0.35
          : (t.isDark || (iconColor != null && iconColor!.computeLuminance() > 0.72));
      final fill = isSolid
          ? (tintColor ?? t.cardSolid)
          : (tintColor ??
              (darkPv
                  ? const Color(0xFF141820).withValues(alpha: 0.78)
                  : const Color(0xFFFAFAFA).withValues(alpha: 0.84)));
      final solidBtn = Semantics(
        button: true,
        label: tooltip,
        child: GrassBagSpringTap(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          pressedScale: 0.94,
          child: Container(
            width: size,
            height: size,
            decoration: ShapeDecoration(
              color: fill,
              shape: CircleBorder(
                side: BorderSide(
                  color: isSolid
                      ? t.sepStrong
                      : Colors.white.withValues(alpha: darkPv ? 0.20 : 0.82),
                  width: highContrast ? 1.15 : 0.65,
                ),
              ),
              shadows: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: (isSolid ? t.isDark : darkPv) ? 0.24 : 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Center(child: iconWidget),
          ),
        ),
      );
      return tooltip != null
          ? Tooltip(message: tooltip!, excludeFromSemantics: true, child: solidBtn)
          : solidBtn;
    }

    final materializeAnim = GrassBagMaterializeScope.animationOf(context);
    final style = tintColor != null
        ? KyantLiquidGlassStyle.button(t, effectiveTier, tint: tintColor)
        : KyantLiquidGlassStyle.chrome(t, effectiveTier);
    final btn = Semantics(
      button: true,
      label: tooltip,
      child: KyantInteractiveGlassButton(
        onTap: onTap,
        style: style,
        isCircle: true,
        isCapsule: false,
        width: size,
        height: size,
        materializeAnimation: materializeAnim,
        child: iconWidget,
      ),
    );
    return tooltip != null
        ? Tooltip(message: tooltip!, excludeFromSemantics: true, child: btn)
        : btn;
  }
}

/// Interactive stadium-shaped Kyant0 Liquid Glass pill button (floating chat title pill,
/// secondary page title pills, prominent tinted glass pills, and action badges).
class GrassBagGlassPillButton extends StatelessWidget {
  const GrassBagGlassPillButton({
    super.key,
    required this.child,
    required this.tier,
    required this.onTap,
    this.height = 44,
    this.padding = const EdgeInsets.symmetric(horizontal: 18),
    this.tintColor,
    this.borderRadius = 999,
    this.prominent = false,
    this.platformViewBackdrop = false,
    this.useOwnLayer = true,
  });

  final Widget child;
  final GrassBagGlassTier tier;
  final VoidCallback onTap;
  final double height;
  final EdgeInsetsGeometry padding;
  final Color? tintColor;
  final double borderRadius;
  final bool prominent;
  final bool platformViewBackdrop;
  final bool useOwnLayer;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final effectiveTier = resolveEffectiveGlassTier(context, tier);
    final highContrast = MediaQuery.highContrastOf(context);
    final isSolid = effectiveTier == GrassBagGlassTier.solid;
    final isPill = borderRadius >= 900;

    if (isSolid || platformViewBackdrop) {
      final darkPv = tintColor != null ? tintColor!.computeLuminance() < 0.35 : t.isDark;
      final fill = isSolid
          ? (prominent ? (tintColor ?? t.primary) : (tintColor ?? t.cardSolid))
          : (prominent
              ? (tintColor ?? t.primary).withValues(alpha: 0.88)
              : (tintColor ??
                  (darkPv
                      ? const Color(0xFF141820).withValues(alpha: 0.78)
                      : const Color(0xFFFAFAFA).withValues(alpha: 0.84))));
      return Semantics(
        button: true,
        child: GrassBagSpringTap(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          pressedScale: 0.96,
          child: SizedBox(
            height: height,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: fill,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(borderRadius),
                  side: BorderSide(
                    color: prominent
                        ? Colors.white.withValues(alpha: 0.24)
                        : (isSolid
                            ? t.sepStrong
                            : Colors.white.withValues(alpha: darkPv ? 0.20 : 0.82)),
                    width: highContrast ? 1.15 : 0.65,
                  ),
                ),
                shadows: [
                  BoxShadow(
                    color: (prominent ? (tintColor ?? t.primary) : Colors.black)
                        .withValues(alpha: t.isDark ? 0.24 : (prominent ? 0.20 : 0.08)),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Padding(
                padding: padding,
                child: Align(
                  alignment: Alignment.center,
                  widthFactor: 1.0,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final style = prominent
        ? KyantLiquidGlassStyle.button(
            t,
            effectiveTier,
            tint: tintColor ?? t.primary,
          )
        : (tintColor != null
            ? KyantLiquidGlassStyle.chrome(t, effectiveTier, tintColor: tintColor)
            : KyantLiquidGlassStyle.chrome(t, effectiveTier));

    final materializeAnim = GrassBagMaterializeScope.animationOf(context);
    return Semantics(
      button: true,
      child: KyantInteractiveGlassButton(
        onTap: onTap,
        style: style,
        isCapsule: isPill,
        borderRadius: BorderRadius.circular(borderRadius),
        height: height,
        padding: padding,
        materializeAnimation: materializeAnim,
        child: child,
      ),
    );
  }
}

/// Native iOS 26 Liquid Glass search capsule with liquid-glass text selection toolbar,
/// `TextInputAction.search`, and a full `36×40dp` opaque clear tap target (replacing
/// `GlassSearchBar`'s unpadded `18×18dp` clear icon).
class GrassBagGlassSearchBar extends StatefulWidget {
  const GrassBagGlassSearchBar({
    super.key,
    this.controller,
    this.placeholder = '搜索',
    this.onChanged,
    this.onSubmitted,
    required this.tier,
    this.insideGlass = false,
  });

  final TextEditingController? controller;
  final String placeholder;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final GrassBagGlassTier tier;
  final bool insideGlass;

  @override
  State<GrassBagGlassSearchBar> createState() => _GrassBagGlassSearchBarState();
}

class _GrassBagGlassSearchBarState extends State<GrassBagGlassSearchBar> {
  TextEditingController? _ownedCtrl;
  bool _hasText = false;

  TextEditingController get _ctrl => widget.controller ?? (_ownedCtrl ??= TextEditingController());

  @override
  void initState() {
    super.initState();
    _hasText = _ctrl.text.isNotEmpty;
    _ctrl.addListener(_onTextTick);
  }

  @override
  void didUpdateWidget(covariant GrassBagGlassSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownedCtrl)?.removeListener(_onTextTick);
      _hasText = _ctrl.text.isNotEmpty;
      _ctrl.addListener(_onTextTick);
    }
  }

  void _onTextTick() {
    final next = _ctrl.text.isNotEmpty;
    if (next != _hasText && mounted) {
      setState(() => _hasText = next);
    }
  }

  @override
  void dispose() {
    (widget.controller ?? _ownedCtrl)?.removeListener(_onTextTick);
    _ownedCtrl?.dispose();
    super.dispose();
  }

  void _clear() {
    HapticFeedback.selectionClick();
    _ctrl.clear();
    widget.onChanged?.call('');
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final effectiveTier = resolveEffectiveGlassTier(context, widget.tier);
    final highContrast = MediaQuery.highContrastOf(context);
    final isSolid = effectiveTier == GrassBagGlassTier.solid;
    final field = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(CupertinoIcons.search, size: 17, color: t.text3),
          const SizedBox(width: 7),
          Expanded(
            child: CupertinoTextField(
              controller: _ctrl,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              placeholder: widget.placeholder,
              placeholderStyle: TextStyle(fontSize: 14, color: t.text3),
              style: TextStyle(fontSize: 14, color: t.text),
              cursorColor: t.primary,
              textInputAction: TextInputAction.search,
              decoration: null,
              padding: const EdgeInsets.symmetric(vertical: 8),
              contextMenuBuilder: buildGrassBagEditableContextMenu,
            ),
          ),
          AnimatedSwitcher(
            duration: GrassBagMotion.duration(context, GrassBagMotion.microDuration),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.72, end: 1.0).animate(anim),
                child: child,
              ),
            ),
            child: _hasText
                ? Tooltip(
                    key: const ValueKey('search-clear'),
                    message: '清除搜索',
                    excludeFromSemantics: true,
                    child: Semantics(
                      button: true,
                      label: '清除搜索',
                      child: GrassBagSpringTap(
                        onTap: _clear,
                        pressedScale: 0.88,
                        enablePointerGlow: false,
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: Center(
                            child: Icon(
                              CupertinoIcons.clear_circled_solid,
                              size: 17,
                              color: t.text3,
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                : const SizedBox(key: ValueKey('search-pad'), width: 12),
          ),
        ],
      ),
    );
    if (!isSolid) {
      return GrassBagGlass(
        tier: effectiveTier,
        borderRadius: 999,
        useOwnLayer: true,
        interactiveGlow: false,
        clipBehavior: Clip.antiAlias,
        tintColor: widget.insideGlass
            ? (t.isDark
                ? Colors.white.withValues(alpha: 0.09)
                : const Color(0xFFF2F5F9).withValues(alpha: 0.62))
            : null,
        child: field,
      );
    }
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: t.cardSolid,
        shape: StadiumBorder(
          side: BorderSide(
            color: (t.isDark || highContrast) ? t.sepStrong : t.sep,
            width: highContrast ? 1.1 : 0.7,
          ),
        ),
      ),
      child: field,
    );
  }
}

/// Faithful 1:1 Flutter replica of Kyant0 `LiquidToggle.kt`:
/// - `64×28dp` capsule track (`#34C759` Light / `#30D158` Dark active; `0x33787878` / `0x5C787880` inactive)
/// - `40×24dp` elongated capsule thumb with `20dp` exact runway
/// - Driven by [KyantDampedDragController] (`1.5×` pressed expansion + velocity squash/stretch!)
/// - At rest (`pressProgress == 0`): crisp pure-white elevated pill (ZERO GPU shaders at rest!)
/// - On press, drag, or toggle glide: swells `1.5×` (`60×36dp`) as white fades (`1 - progress`)
///   into a live 7-band chromatic-aberration [KyantLiquidGlass] water-droplet lens refracting
///   the colored track directly underneath!
class GrassBagGlassSwitch extends StatefulWidget {
  const GrassBagGlassSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.tier,
    this.activeColor,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final GrassBagGlassTier tier;
  final Color? activeColor;

  @override
  State<GrassBagGlassSwitch> createState() => _GrassBagGlassSwitchState();
}

class _GrassBagGlassSwitchState extends State<GrassBagGlassSwitch>
    with TickerProviderStateMixin {
  static const double _trackW = 64.0;
  static const double _trackH = 28.0;
  static const double _thumbW = 40.0;
  static const double _thumbH = 24.0;
  static const double _pad = 2.0;
  static const double _dragWidth = 20.0; // _trackW - _pad * 2 - _thumbW

  late final KyantDampedDragController _drag;
  bool _didDrag = false;
  bool _dragging = false;
  double _fraction = 0.0;

  @override
  void initState() {
    super.initState();
    _fraction = widget.value ? 1.0 : 0.0;
    _drag = KyantDampedDragController(
      vsync: this,
      initialValue: _fraction,
      minValue: 0.0,
      maxValue: 1.0,
      initialScale: 1.0,
      pressedScale: 1.5,
    );
  }

  @override
  void didUpdateWidget(covariant GrassBagGlassSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onChanged != null && widget.onChanged == null) {
      _dragging = false;
      _didDrag = false;
      _fraction = widget.value ? 1.0 : 0.0;
      _drag.release(reduceMotion: true);
      _drag.updateValue(_fraction, reduceMotion: true, trackVelocity: false);
    } else if (!_dragging && oldWidget.value != widget.value) {
      final target = widget.value ? 1.0 : 0.0;
      _fraction = target;
      final reduceMotion = mounted && MediaQuery.disableAnimationsOf(context);
      _drag.animateToValue(target, reduceMotion: reduceMotion);
    }
  }

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  void _commitValue(bool next, {double? flingVelocity}) {
    final cb = widget.onChanged;
    if (cb == null) return;
    HapticFeedback.selectionClick();
    final target = next ? 1.0 : 0.0;
    _fraction = target;
    final reduceMotion = mounted && MediaQuery.disableAnimationsOf(context);
    if (flingVelocity != null) {
      final normVel = (isLtrDir ? flingVelocity : -flingVelocity) / _dragWidth;
      _drag.settleTo(target, normalizedVelocity: normVel, reduceMotion: reduceMotion);
      if (next == widget.value) return;
      cb(next);
    } else {
      if (next == widget.value) {
        _drag.updateValue(target, reduceMotion: reduceMotion, trackVelocity: false);
        return;
      }
      _drag.animateToValue(target, reduceMotion: reduceMotion);
      cb(next);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _dragging) return;
      final expected = widget.value ? 1.0 : 0.0;
      if ((_drag.targetValue - expected).abs() > 0.01) {
        _fraction = expected;
        _drag.updateValue(
          expected,
          reduceMotion: MediaQuery.disableAnimationsOf(context),
          trackVelocity: false,
        );
      }
    });
  }

  bool get isLtrDir => !mounted || Directionality.of(context) == TextDirection.ltr;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final effectiveTier = resolveEffectiveGlassTier(context, widget.tier);
    final isSolid = effectiveTier == GrassBagGlassTier.solid;
    final isLiquid = effectiveTier == GrassBagGlassTier.liquid && !kIsWeb;
    final enabled = widget.onChanged != null;
    final isLtr = Directionality.of(context) == TextDirection.ltr;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final accentColor = widget.activeColor ??
        (t.isDark ? const Color(0xFF30D158) : const Color(0xFF34C759));
    final trackColor = t.isDark
        ? const Color(0xFF787880).withValues(alpha: 0.36)
        : const Color(0xFF787878).withValues(alpha: 0.22);

    final control = RepaintBoundary(
      child: ListenableBuilder(
        listenable: _drag,
        builder: (context, _) {
          final frac = _drag.value.clamp(0.0, 1.0);
          final press = reduceMotion ? 0.0 : _drag.pressProgress;
          final vel = (_drag.velocity / 50.0).clamp(-0.26, 0.26);
          final rawScaleX = _drag.scaleX / (1.0 - (vel * 0.75).clamp(-0.2, 0.2));
          final rawScaleY = _drag.scaleY * (1.0 - (vel * 0.25).clamp(-0.2, 0.2));
          final effScaleX = isSolid ? (1.0 + 0.14 * press) : rawScaleX.clamp(0.85, 1.72);
          final effScaleY = isSolid ? (1.0 + 0.05 * press) : rawScaleY.clamp(0.85, 1.65);

          final curThumbW = _thumbW * effScaleX;
          final curThumbH = _thumbH * effScaleY;
          final centerX = isLtr
              ? (_pad + _thumbW * 0.5) + _dragWidth * frac
              : (_trackW - _pad - _thumbW * 0.5) - _dragWidth * frac;
          final centerY = _trackH * 0.5;
          final left = centerX - curThumbW * 0.5;
          final top = centerY - curThumbH * 0.5;

          final resolvedTrack = Color.lerp(trackColor, accentColor, frac)!;
          final useLens = !isSolid && press > 0.015;

          final Widget thumbWidget;
          if (!useLens) {
            thumbWidget = Container(
              width: curThumbW,
              height: curThumbH,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(curThumbH * 0.5),
                border: Border.all(
                  color: Colors.black.withValues(alpha: t.isDark ? 0.08 : 0.04),
                  width: 0.5,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x1F000000),
                    blurRadius: 5.0,
                    offset: Offset(0, 1.5),
                  ),
                ],
              ),
            );
          } else {
            // Exact Kyant0 LiquidToggle.kt:158-198 clear optical crystal lens morph
            // (`blurRadius: 0.0` in liquid mode avoids per-frame ImageFilter reallocation
            // and the 0.05 `clampToBox` threshold pop at peak press!).
            final lensStyle = KyantLiquidGlassStyle(
              blurRadius: isLiquid ? 0.0 : 4.0,
              refractionHeight: isLiquid ? 5.0 * press : 0.0,
              refractionAmount: isLiquid ? 10.0 * press : 0.0,
              depthEffect: false,
              chromaticAberration: isLiquid ? 1.0 * press : 0.0,
              saturation: 1.35,
              surfaceColor: Colors.white.withValues(alpha: (1.0 - press).clamp(0.0, 1.0)),
              highlightKind: KyantHighlightKind.ambient,
              highlightAlpha: (t.isDark ? 0.56 : 0.46) * press,
              highlightAngleDeg: 45.0,
              highlightFalloff: 1.0,
              highlightWidth: 0.50,
              highlightBlur: 0.22,
              innerShadowRadius: 4.0 * press,
              innerShadowAlpha: (t.isDark ? 0.65 : 1.0) * press,
              shadows: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08 + 0.05 * press),
                  blurRadius: 6.0 + 4.0 * press,
                  offset: const Offset(0, 2.0),
                ),
              ],
            );
            thumbWidget = KyantLiquidGlass(
              style: lensStyle,
              isCapsule: true,
              child: SizedBox(width: curThumbW, height: curThumbH),
            );
          }

          return SizedBox(
            width: _trackW,
            height: _trackH,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: resolvedTrack,
                      borderRadius: BorderRadius.circular(_trackH * 0.5),
                    ),
                  ),
                ),
                Positioned(
                  left: left,
                  top: top,
                  width: curThumbW,
                  height: curThumbH,
                  child: thumbWidget,
                ),
              ],
            ),
          );
        },
      ),
    );

    return Semantics(
      toggled: widget.value,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled
            ? (_) {
                if (!reduceMotion) _drag.press();
              }
            : null,
        onTapCancel: enabled
            ? () {
                if (!_dragging) _drag.release(reduceMotion: reduceMotion);
              }
            : null,
        onTap: enabled ? () => _commitValue(!widget.value) : null,
        onHorizontalDragStart: enabled
            ? (_) {
                _dragging = true;
                _didDrag = false;
                _fraction = _drag.value.clamp(0.0, 1.0);
                _drag.press(reduceMotion: reduceMotion);
              }
            : null,
        onHorizontalDragUpdate: enabled
            ? (details) {
                if (details.delta.dx != 0) _didDrag = true;
                final delta = details.delta.dx / _dragWidth;
                _fraction = (isLtr ? _fraction + delta : _fraction - delta).clamp(0.0, 1.0);
                _drag.updateValue(_fraction, reduceMotion: reduceMotion);
              }
            : null,
        onHorizontalDragEnd: enabled
            ? (details) {
                final vx = details.primaryVelocity ?? 0.0;
                _dragging = false;
                final bool next;
                if (_didDrag) {
                  if (vx.abs() > 140) {
                    next = isLtr ? vx > 0 : vx < 0;
                  } else {
                    next = _fraction >= 0.5;
                  }
                } else {
                  next = !widget.value;
                }
                _didDrag = false;
                _commitValue(next, flingVelocity: vx);
              }
            : null,
        onHorizontalDragCancel: enabled
            ? () {
                _dragging = false;
                _didDrag = false;
                _drag.release(reduceMotion: reduceMotion);
                _drag.updateValue(
                  widget.value ? 1.0 : 0.0,
                  reduceMotion: reduceMotion,
                  trackVelocity: false,
                );
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.0),
          child: enabled ? control : Opacity(opacity: 0.45, child: control),
        ),
      ),
    );
  }
}

/// Faithful 1:1 Kyant0 `LiquidBottomTabs` / `LiquidSegmentedControl`:
/// - Real translucent [KyantLiquidGlass] capsule track (`KyantLiquidGlassStyle.segmentedTrack`)
///   with subtle ±4dp elastic panel follow when dragged past edges!
/// - Sliding capsule indicator driven by [KyantDampedDragController] (`1.24×` press swell +
///   velocity squash & stretch): crisp high-contrast pill at rest (zero extra shader), lifting
///   above the labels into a live 7-band chromatic-aberration [KyantLiquidGlass] refracting lens
///   (`lens(10, 14, chromaticAberration: true)` + `Highlight.Default` + `InnerShadow`) on drag/tap!
/// - Supports both equal-width (`2..5` items) and scrollable (`>= 6` items) + safe `1`-item mode.
class GrassBagSegmentedControl extends StatefulWidget {
  const GrassBagSegmentedControl({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    required this.tier,
    this.height = 40,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final GrassBagGlassTier tier;
  final double height;

  @override
  State<GrassBagSegmentedControl> createState() => _GrassBagSegmentedControlState();
}

class _GrassBagSegmentedControlState extends State<GrassBagSegmentedControl>
    with TickerProviderStateMixin {
  late final KyantDampedDragController _drag;
  late final SingleSpringController _panelOffsetSpring;
  late final Listenable _merged;
  final ScrollController _scrollCtrl = ScrollController();
  List<GlobalKey> _itemKeys = const [];
  bool _dragging = false;
  int _lastHapticIdx = -1;

  double get _maxIdx => math.max(0.0, (widget.labels.length - 1).toDouble());

  void _syncItemKeys() {
    if (widget.labels.length >= 6) {
      if (_itemKeys.length != widget.labels.length) {
        _itemKeys = List.generate(widget.labels.length, (_) => GlobalKey());
      }
    } else if (_itemKeys.isNotEmpty) {
      _itemKeys = const [];
    }
  }

  void _scrollSelectedIntoView({bool animate = true}) {
    if (widget.labels.length < 6 || _itemKeys.isEmpty) return;
    final safeIdx = widget.selectedIndex.clamp(0, _itemKeys.length - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || safeIdx >= _itemKeys.length) return;
      final ctx = _itemKeys[safeIdx].currentContext;
      if (ctx == null) return;
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: (!animate || reduceMotion)
            ? Duration.zero
            : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    final safeIdx = widget.labels.isEmpty
        ? 0
        : widget.selectedIndex.clamp(0, widget.labels.length - 1);
    _lastHapticIdx = safeIdx;
    _syncItemKeys();
    _drag = KyantDampedDragController(
      vsync: this,
      initialValue: safeIdx.toDouble(),
      minValue: 0.0,
      maxValue: _maxIdx,
      initialScale: 1.0,
      pressedScale: 1.24,
    );
    _panelOffsetSpring = SingleSpringController(
      vsync: this,
      spring: GlassSpring.snappy(duration: const Duration(milliseconds: 280)),
      initialValue: 0.0,
    );
    _merged = Listenable.merge([_drag, _panelOffsetSpring]);
    _scrollSelectedIntoView(animate: false);
  }

  @override
  void didUpdateWidget(covariant GrassBagSegmentedControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncItemKeys();
    if (widget.labels.isEmpty) return;
    final safeIdx = widget.selectedIndex.clamp(0, widget.labels.length - 1);
    final reduceMotion = mounted && MediaQuery.disableAnimationsOf(context);
    if (oldWidget.labels.length != widget.labels.length) {
      _drag.updateRange(0.0, _maxIdx, safeIdx.toDouble(), reduceMotion: true);
      _lastHapticIdx = safeIdx;
    } else if (!_dragging && oldWidget.selectedIndex != widget.selectedIndex) {
      _drag.animateToValue(safeIdx.toDouble(), reduceMotion: reduceMotion);
      _lastHapticIdx = safeIdx;
      _scrollSelectedIntoView(animate: true);
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _drag.dispose();
    _panelOffsetSpring.dispose();
    super.dispose();
  }

  void _select(int i) {
    if (widget.labels.isEmpty) return;
    final safe = i.clamp(0, widget.labels.length - 1);
    if (safe == widget.selectedIndex.clamp(0, widget.labels.length - 1)) return;
    HapticFeedback.selectionClick();
    _lastHapticIdx = safe;
    final reduceMotion = mounted && MediaQuery.disableAnimationsOf(context);
    _drag.animateToValue(safe.toDouble(), reduceMotion: reduceMotion);
    widget.onSelected(safe);
  }

  Widget _buildRestingThumb(
    GrassBagTokens t, {
    required GrassBagGlassTier effectiveTier,
    required double radius,
    required double opacity,
  }) {
    if (opacity <= 0.01) return const SizedBox.shrink();
    final isSolid = effectiveTier == GrassBagGlassTier.solid;
    final color = isSolid
        ? (t.isDark ? Color.lerp(t.cardSolid, Colors.white, 0.14)! : Colors.white)
        : (t.isDark
            ? Colors.white.withValues(alpha: 0.17 * opacity)
            : Colors.white.withValues(alpha: 0.94 * opacity));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isSolid ? color : color,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: t.isDark
              ? Colors.white.withValues(alpha: (isSolid ? 0.16 : 0.22) * opacity)
              : Colors.white.withValues(alpha: 0.92 * opacity),
          width: 0.65,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: (t.isDark ? 0.22 : 0.075) * opacity),
            blurRadius: 7.0,
            offset: const Offset(0, 1.5),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;
    if (labels.isEmpty) return const SizedBox.shrink();
    final t = GrassBagTokens.of(context);
    final effectiveTier = resolveEffectiveGlassTier(context, widget.tier);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.35);
    final safeIdx = widget.selectedIndex.clamp(0, labels.length - 1);
    final isSolid = effectiveTier == GrassBagGlassTier.solid;
    final isLiquid = effectiveTier == GrassBagGlassTier.liquid && !kIsWeb;
    final h = widget.height * textScale;
    final innerR = (h - 6.0) * 0.5;

    final selectedStyle = TextStyle(
      fontSize: widget.height <= 34 ? 12.5 : 13.0,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.15,
      color: t.isDark ? Colors.white : t.text,
    );
    final unselectedStyle = TextStyle(
      fontSize: widget.height <= 34 ? 12.5 : 13.0,
      fontWeight: FontWeight.w500,
      letterSpacing: -0.1,
      color: t.text2,
    );

    Widget wrapTrack(Widget inner) {
      if (isSolid) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Container(
            height: h,
            padding: const EdgeInsets.all(3.0),
            decoration: BoxDecoration(
              color: t.isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(h * 0.5),
            ),
            child: inner,
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: KyantLiquidGlass(
          style: KyantLiquidGlassStyle.segmentedTrack(t, effectiveTier),
          isCapsule: true,
          child: Container(
            height: h,
            padding: const EdgeInsets.all(3.0),
            child: inner,
          ),
        ),
      );
    }

    if (labels.length == 1) {
      return wrapTrack(
        Stack(
          fit: StackFit.expand,
          children: [
            _buildRestingThumb(t, effectiveTier: effectiveTier, radius: innerR, opacity: 1.0),
            Center(
              child: Text(
                labels.first,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: selectedStyle,
              ),
            ),
          ],
        ),
      );
    }

    if (labels.length >= 6) {
      return wrapTrack(
        ClipRRect(
          borderRadius: BorderRadius.circular(innerR),
          child: SingleChildScrollView(
            controller: _scrollCtrl,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: [
                for (var i = 0; i < labels.length; i++)
                  Semantics(
                    key: i < _itemKeys.length ? _itemKeys[i] : null,
                    button: true,
                    selected: i == safeIdx,
                    label: labels[i],
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _select(i),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Positioned.fill(
                            child: AnimatedOpacity(
                              opacity: i == safeIdx ? 1.0 : 0.0,
                              duration: reduceMotion
                                  ? Duration.zero
                                  : const Duration(milliseconds: 170),
                              curve: Curves.easeOutCubic,
                              child: _buildRestingThumb(
                                t,
                                effectiveTier: effectiveTier,
                                radius: innerR,
                                opacity: 1.0,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: AnimatedDefaultTextStyle(
                              duration: reduceMotion
                                  ? Duration.zero
                                  : const Duration(milliseconds: 160),
                              curve: Curves.easeOutCubic,
                              style: i == safeIdx ? selectedStyle : unselectedStyle,
                              child: Text(
                                labels[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: _panelOffsetSpring,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final innerW = math.max(1.0, constraints.maxWidth - 6.0);
            final segW = innerW / labels.length;
            final innerH = h - 6.0;
            final isLtr = Directionality.of(context) == TextDirection.ltr;

            double overdragRubber(double excess) {
              final e2x = math.exp(2.0 * (excess * 0.045).clamp(-5.0, 5.0));
              return 4.5 * ((e2x - 1.0) / (e2x + 1.0));
            }

            void handleDragUpdate(double localDx, double deltaDx) {
              if (segW <= 0) return;
              final unclampedNext =
                  _drag.targetValue + (deltaDx / segW) * (isLtr ? 1.0 : -1.0);
              final nextVal = unclampedNext.clamp(0.0, _maxIdx);
              _drag.updateValue(nextVal, reduceMotion: reduceMotion);
              // Elastic panel nudge ONLY when pushing past the left/right edges!
              if (unclampedNext < 0.0) {
                final overscrollPx = (unclampedNext * segW) * (isLtr ? 1.0 : -1.0);
                _panelOffsetSpring.setValue(
                  overdragRubber(_panelOffsetSpring.value * 4.0 + overscrollPx),
                );
              } else if (unclampedNext > _maxIdx) {
                final overscrollPx =
                    ((unclampedNext - _maxIdx) * segW) * (isLtr ? 1.0 : -1.0);
                _panelOffsetSpring.setValue(
                  overdragRubber(_panelOffsetSpring.value * 4.0 + overscrollPx),
                );
              } else if (_panelOffsetSpring.value.abs() > 0.01) {
                _panelOffsetSpring.setValue(_panelOffsetSpring.value * 0.72);
              }
              final snapped = nextVal.round().clamp(0, labels.length - 1);
              if (snapped != _lastHapticIdx) {
                _lastHapticIdx = snapped;
                HapticFeedback.selectionClick();
              }
            }

            void handleDragEnd({double primaryVelocity = 0.0}) {
              _dragging = false;
              final velIdxPerSec =
                  (primaryVelocity / math.max(segW, 1.0)) * (isLtr ? 1.0 : -1.0);
              final projected = _drag.targetValue + (velIdxPerSec * 0.08).clamp(-0.65, 0.65);
              final target = projected.round().clamp(0, labels.length - 1);
              final span = math.max(_maxIdx, 1.0);
              _drag.settleTo(
                target.toDouble(),
                normalizedVelocity: velIdxPerSec / span,
                reduceMotion: reduceMotion,
              );
              _panelOffsetSpring.animateTo(
                0.0,
                fromVelocity: (primaryVelocity * 0.05).clamp(-120.0, 120.0),
              );
              if (target != safeIdx) {
                widget.onSelected(target);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || _dragging || widget.labels.isEmpty) return;
                  final curSafe = widget.selectedIndex.clamp(0, widget.labels.length - 1);
                  if (curSafe != target) {
                    _drag.updateValue(
                      curSafe.toDouble(),
                      reduceMotion: MediaQuery.disableAnimationsOf(context),
                      trackVelocity: false,
                    );
                    _lastHapticIdx = curSafe;
                  }
                });
              }
            }

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) {
                if (!reduceMotion) _drag.press();
              },
              onTapCancel: () {
                if (!_dragging) _drag.release(reduceMotion: reduceMotion);
              },
              onHorizontalDragStart: (details) {
                _dragging = true;
                _drag.press(reduceMotion: reduceMotion);
                final rawIdx =
                    ((details.localPosition.dx - 3.0) / segW - 0.5).clamp(0.0, _maxIdx);
                _drag.updateValue(
                  isLtr ? rawIdx : _maxIdx - rawIdx,
                  reduceMotion: reduceMotion,
                  trackVelocity: false,
                );
              },
              onHorizontalDragUpdate: (details) =>
                  handleDragUpdate(details.localPosition.dx, details.delta.dx),
              onHorizontalDragEnd: (details) =>
                  handleDragEnd(primaryVelocity: details.primaryVelocity ?? 0.0),
              onHorizontalDragCancel: () => handleDragEnd(),
              child: wrapTrack(
                ListenableBuilder(
                  listenable: _merged,
                  builder: (context, _) {
                    final pos = _drag.value.clamp(0.0, _maxIdx);
                    final press = reduceMotion ? 0.0 : _drag.pressProgress;
                    final vel = (_drag.velocity / 12.0).clamp(-0.24, 0.24);
                    final effScaleX = (isSolid
                            ? (1.0 + 0.04 * press)
                            : (_drag.scaleX / (1.0 - (vel * 0.75).clamp(-0.2, 0.2))))
                        .clamp(0.92, 1.38);
                    final effScaleY = (isSolid
                            ? (1.0 + 0.04 * press)
                            : (_drag.scaleY * (1.0 - (vel * 0.25).clamp(-0.2, 0.2))))
                        .clamp(0.92, 1.32);

                    final visualPos = isLtr ? pos : (_maxIdx - pos);
                    final restLeft = segW * visualPos;
                    final lensW = segW * effScaleX;
                    final lensH = innerH * effScaleY;
                    final lensLeft = (restLeft + segW * 0.5) - lensW * 0.5;
                    final lensTop = (innerH * 0.5) - lensH * 0.5;
                    final showCrystalLens = !isSolid && press > 0.02;

                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // 1. Resting luminous sculpted capsule BEHIND labels (fades out as lens lifts)
                        if (1.0 - press > 0.01)
                          Positioned(
                            left: restLeft,
                            top: 0,
                            bottom: 0,
                            width: segW,
                            child: _buildRestingThumb(
                              t,
                              effectiveTier: effectiveTier,
                              radius: innerR,
                              opacity: (1.0 - press).clamp(0.0, 1.0),
                            ),
                          ),
                        // 2. Segment labels with continuous color interpolation as the lens glides over!
                        Row(
                          children: [
                            for (var i = 0; i < labels.length; i++)
                              Expanded(
                                child: Semantics(
                                  button: true,
                                  selected: i == safeIdx,
                                  label: labels[i],
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => _select(i),
                                    child: Center(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                        child: Text(
                                          labels[i],
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle.lerp(
                                            unselectedStyle,
                                            selectedStyle,
                                            (1.0 - (pos - i).abs()).clamp(0.0, 1.0),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        // 3. Lifted Kyant0 7-band chromatic refracting lens OVER labels during drag/tap!
                        if (showCrystalLens)
                          Positioned(
                            left: lensLeft,
                            top: lensTop,
                            width: lensW,
                            height: lensH,
                            child: IgnorePointer(
                              child: KyantLiquidGlass(
                                style: KyantLiquidGlassStyle(
                                  blurRadius: 0.0,
                                  refractionHeight: isLiquid ? 10.0 * press : 0.0,
                                  refractionAmount: isLiquid ? 14.0 * press : 0.0,
                                  depthEffect: false,
                                  chromaticAberration: isLiquid ? 1.0 * press : 0.0,
                                  saturation: 1.45,
                                  surfaceColor: t.isDark
                                      ? Colors.white.withValues(alpha: 0.05 * press)
                                      : Colors.black.withValues(alpha: 0.03 * press),
                                  highlightKind: KyantHighlightKind.defaultSpecular,
                                  highlightAlpha: 0.58 * press,
                                  highlightAngleDeg: 45.0,
                                  highlightFalloff: 1.2,
                                  highlightWidth: 0.65,
                                  highlightBlur: 0.25,
                                  innerShadowRadius: 6.0 * press,
                                  innerShadowAlpha: press,
                                  shadows: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.14 * press),
                                      blurRadius: 14.0,
                                      offset: const Offset(0, 4.0),
                                    ),
                                  ],
                                ),
                                isCapsule: true,
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ),
        builder: (_, child) {
          // ALWAYS keep Transform.translate in the tree so starting a horizontal drag
          // NEVER changes widget tree depth and cancels GestureDetector!
          final ox = reduceMotion ? 0.0 : _panelOffsetSpring.value;
          return Transform.translate(offset: Offset(ox, 0), child: child);
        },
      ),
    );
  }
}

/// Faithful 1:1 Flutter replica of Kyant0 `LiquidSlider.kt`:
/// - `6dp` capsule track (`0x33787878` Light / `0x5C787880` Dark) + accent filled track
/// - `40×24dp` elongated capsule thumb driven by [KyantDampedDragController] (`1.5×` pressed
///   expansion + velocity squash/stretch `scaleX /= 1 - v*0.75`, `scaleY *= 1 - v*0.25`)
/// - At rest (`pressProgress == 0`): crisp pure-white `40×24dp` capsule (ZERO shaders at rest!)
/// - On press, drag, or tap-to-seek: swells `1.5×` (`60×36dp`) as white fades (`1 - progress`)
///   into a live 7-band chromatic-aberration [KyantLiquidGlass] water-droplet lens
///   (`lens(10, 14, chromaticAberration: true)` + `Highlight.Ambient` + `InnerShadow(4dp)`)
///   magnifying & refracting the colored track right underneath!
class GrassBagGlassSlider extends StatefulWidget {
  const GrassBagGlassSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.activeColor,
    this.tier,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;
  final int? divisions;
  final Color? activeColor;
  final GrassBagGlassTier? tier;

  @override
  State<GrassBagGlassSlider> createState() => _GrassBagGlassSliderState();
}

class _GrassBagGlassSliderState extends State<GrassBagGlassSlider>
    with TickerProviderStateMixin {
  static const double _trackH = 6.0;
  static const double _thumbW = 40.0;
  static const double _thumbH = 24.0;
  static const double _hitHeight = 40.0;

  late final KyantDampedDragController _drag;
  bool _dragging = false;
  int? _lastDivisionTick;

  double get _safeMax => widget.max > widget.min ? widget.max : widget.min + 1.0;
  double get _clampedValue => widget.value.clamp(widget.min, _safeMax);

  double _quantize(double raw) {
    final clamped = raw.clamp(widget.min, _safeMax);
    final div = widget.divisions;
    if (div == null || div <= 0) return clamped;
    final step = (_safeMax - widget.min) / div;
    final idx = ((clamped - widget.min) / step).round();
    if (_lastDivisionTick != idx) {
      _lastDivisionTick = idx;
      HapticFeedback.selectionClick();
    }
    return (widget.min + idx * step).clamp(widget.min, _safeMax);
  }

  @override
  void initState() {
    super.initState();
    _drag = KyantDampedDragController(
      vsync: this,
      initialValue: _clampedValue,
      minValue: widget.min,
      maxValue: _safeMax,
      initialScale: 1.0,
      pressedScale: 1.5,
    );
  }

  @override
  void didUpdateWidget(covariant GrassBagGlassSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reduceMotion = mounted && MediaQuery.disableAnimationsOf(context);
    if (oldWidget.min != widget.min || oldWidget.max != widget.max) {
      _drag.updateRange(widget.min, _safeMax, _clampedValue, reduceMotion: true);
    } else if (!_dragging && (oldWidget.value - widget.value).abs() > 1e-5) {
      _drag.updateValue(_clampedValue, reduceMotion: reduceMotion, trackVelocity: false);
    }
  }

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final resolvedTier =
        resolveEffectiveGlassTier(context, widget.tier ?? resolveAmbientGlassTier(context));
    final enabled = widget.onChanged != null;
    final isSolid = resolvedTier == GrassBagGlassTier.solid;
    final isLiquid = resolvedTier == GrassBagGlassTier.liquid && !kIsWeb;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final isLtr = Directionality.of(context) == TextDirection.ltr;

    final rawActive = widget.activeColor ?? t.primary;
    final resolvedActive = (t.isDark && rawActive.computeLuminance() > 0.65)
        ? Color.lerp(rawActive, t.cardSolid, 0.30)!
        : rawActive;
    final resolvedInactive = t.isDark
        ? const Color(0xFF787880).withValues(alpha: 0.36)
        : const Color(0xFF787878).withValues(alpha: 0.22);

    final sliderBody = LayoutBuilder(
      builder: (context, constraints) {
        final trackW = constraints.hasBoundedWidth && constraints.maxWidth > 0
            ? constraints.maxWidth
            : 240.0;

        double valueAtDx(double dx) {
          final frac = (dx / trackW).clamp(0.0, 1.0);
          final dirFrac = isLtr ? frac : (1.0 - frac);
          return _quantize(widget.min + dirFrac * (_safeMax - widget.min));
        }

        final visual = RepaintBoundary(
          child: ListenableBuilder(
            listenable: _drag,
            builder: (context, _) {
              final prog = _drag.progress.clamp(0.0, 1.0);
              final press = reduceMotion ? 0.0 : _drag.pressProgress;
              final vel = (_drag.velocity / 10.0).clamp(-0.26, 0.26);
              final rawScaleX = _drag.scaleX / (1.0 - (vel * 0.75).clamp(-0.2, 0.2));
              final rawScaleY = _drag.scaleY * (1.0 - (vel * 0.25).clamp(-0.2, 0.2));
              final effScaleX = isSolid ? (1.0 + 0.14 * press) : rawScaleX.clamp(0.85, 1.72);
              final effScaleY = isSolid ? (1.0 + 0.08 * press) : rawScaleY.clamp(0.85, 1.65);

              final curThumbW = _thumbW * effScaleX;
              final curThumbH = _thumbH * effScaleY;
              final curTrackH = _trackH + 2.2 * press;
              // Exact Kyant0 LiquidSlider.kt:149-151 horizontal thumb positioning
              final minCenter = _thumbW * 0.25;
              final maxCenter = math.max(minCenter, trackW - _thumbW * 0.25);
              final rawCenter = isLtr ? (trackW * prog) : (trackW * (1.0 - prog));
              final thumbCenterX = rawCenter.clamp(minCenter, maxCenter);
              final thumbLeft = thumbCenterX - curThumbW * 0.5;
              final thumbTop = (_hitHeight - curThumbH) * 0.5;

              final useLens = !isSolid && press > 0.015;
              final Widget thumbWidget;
              if (!useLens) {
                thumbWidget = Container(
                  width: curThumbW,
                  height: curThumbH,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(curThumbH * 0.5),
                    border: Border.all(
                      color: Colors.black.withValues(alpha: t.isDark ? 0.10 : 0.06),
                      width: 0.5,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x22000000),
                        blurRadius: 6.0,
                        offset: Offset(0, 2.0),
                      ),
                    ],
                  ),
                );
              } else {
                // Exact Kyant0 LiquidSlider.kt:167-207 clear crystal lens morph
                // (`blurRadius: 0.0` in liquid mode eliminates the 0.05 threshold pop!)
                final lensStyle = KyantLiquidGlassStyle(
                  blurRadius: isLiquid ? 0.0 : 4.0,
                  refractionHeight: isLiquid ? 10.0 * press : 0.0,
                  refractionAmount: isLiquid ? 14.0 * press : 0.0,
                  depthEffect: false,
                  chromaticAberration: isLiquid ? 1.0 * press : 0.0,
                  saturation: 1.40,
                  surfaceColor: Colors.white.withValues(alpha: (1.0 - press).clamp(0.0, 1.0)),
                  highlightKind: KyantHighlightKind.ambient,
                  highlightAlpha: (t.isDark ? 0.56 : 0.46) * press,
                  highlightAngleDeg: 45.0,
                  highlightFalloff: 1.0,
                  highlightWidth: 0.50,
                  highlightBlur: 0.22,
                  innerShadowRadius: 4.0 * press,
                  innerShadowAlpha: (t.isDark ? 0.65 : 1.0) * press,
                  shadows: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08 + 0.06 * press),
                      blurRadius: 8.0 + 4.0 * press,
                      offset: const Offset(0, 2.0),
                    ),
                  ],
                );
                thumbWidget = KyantLiquidGlass(
                  style: lensStyle,
                  isCapsule: true,
                  child: SizedBox(width: curThumbW, height: curThumbH),
                );
              }

              final fillW = (trackW * prog).clamp(0.0, trackW);
              return SizedBox(
                width: trackW,
                height: _hitHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.centerLeft,
                  children: [
                    // Tactile swelling capsule background track (6dp -> 8.2dp on press!)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: (_hitHeight - curTrackH) * 0.5,
                      height: curTrackH,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: resolvedInactive,
                          borderRadius: BorderRadius.circular(curTrackH * 0.5),
                        ),
                      ),
                    ),
                    // Tactile swelling capsule accent fill track
                    Positioned(
                      left: isLtr ? 0 : (trackW - fillW),
                      top: (_hitHeight - curTrackH) * 0.5,
                      width: fillW,
                      height: curTrackH,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: resolvedActive,
                          borderRadius: BorderRadius.circular(curTrackH * 0.5),
                        ),
                      ),
                    ),
                    // 40×24dp Kyant0 Liquid Glass capsule thumb
                    Positioned(
                      left: thumbLeft,
                      top: thumbTop,
                      width: curThumbW,
                      height: curThumbH,
                      child: thumbWidget,
                    ),
                  ],
                ),
              );
            },
          ),
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled
              ? (_) {
                  if (!reduceMotion) _drag.press();
                }
              : null,
          onTapCancel: enabled
              ? () {
                  if (!_dragging) _drag.release(reduceMotion: reduceMotion);
                }
              : null,
          onTapUp: enabled
              ? (details) {
                  final next = valueAtDx(details.localPosition.dx);
                  _drag.animateToValue(next, reduceMotion: reduceMotion);
                  HapticFeedback.selectionClick();
                  widget.onChanged?.call(next);
                }
              : null,
          onHorizontalDragStart: enabled
              ? (details) {
                  _dragging = true;
                  _lastDivisionTick = null;
                  _drag.press(reduceMotion: reduceMotion);
                  final next = valueAtDx(details.localPosition.dx);
                  // Avoid violent 1-frame squash spike on tap-far-from-thumb drag start!
                  _drag.updateValue(next, reduceMotion: reduceMotion, trackVelocity: false);
                  widget.onChanged?.call(next);
                }
              : null,
          onHorizontalDragUpdate: enabled
              ? (details) {
                  final next = valueAtDx(details.localPosition.dx);
                  _drag.updateValue(next, reduceMotion: reduceMotion);
                  widget.onChanged?.call(next);
                }
              : null,
          onHorizontalDragEnd: enabled
              ? (details) {
                  _dragging = false;
                  final vx = details.primaryVelocity ?? 0.0;
                  final normVel = ((isLtr ? vx : -vx) / math.max(trackW, 1.0)) * 0.35;
                  final target = _quantize(_drag.targetValue);
                  _drag.settleTo(
                    target,
                    normalizedVelocity: normVel,
                    reduceMotion: reduceMotion,
                  );
                  widget.onChanged?.call(target);
                }
              : null,
          onHorizontalDragCancel: enabled
              ? () {
                  _dragging = false;
                  _drag.release(reduceMotion: reduceMotion);
                }
              : null,
          child: visual,
        );
      },
    );

    final semantic = Semantics(
      slider: true,
      enabled: enabled,
      value: _clampedValue.toStringAsFixed(2),
      child: sliderBody,
    );
    if (enabled) return semantic;
    return IgnorePointer(child: Opacity(opacity: 0.45, child: semantic));
  }
}

/// Bespoke Apple iOS 26 / macOS Tahoe translucent luminous grouped section platter:
/// - Replaces harsh opaque `#1C1C1E` slabs in Dark Mode with a soft luminous cool-slate
///   frosted veil that harmonizes seamlessly with the ocean-slate aurora backdrop!
/// - Continuous `24pt` superellipse silhouette (`ClipRSuperellipse`), hairline specular rim,
///   auto-indented `0.5px` dividers, and zero sharp Material press rectangles.
/// - Safe for `GlassSwitch` lifted lenses (zero shader nesting at rest!).
class GrassBagGroupedSection extends StatelessWidget {
  const GrassBagGroupedSection({
    super.key,
    required this.children,
    this.header,
    this.footer,
    this.margin = EdgeInsets.zero,
    this.dividerIndent,
    this.clipBehavior = Clip.none,
  });

  final List<Widget> children;
  final String? header;
  final String? footer;
  final EdgeInsetsGeometry margin;
  final double? dividerIndent;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      final item = children[i];
      rows.add(item);
      if (i < children.length - 1) {
        final hasLeading = item is GrassBagListTile && item.leading != null;
        final indent = dividerIndent ?? (hasLeading ? 58.0 : 16.0);
        rows.add(
          Divider(
            height: 0.5,
            thickness: 0.5,
            indent: indent,
            endIndent: 16,
            color: t.sep,
          ),
        );
      }
    }

    final innerColumn = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
    final platter = InheritedGlassSurfaceStyle(
      surfaceStyle: GlassSurfaceStyle.solid,
      child: GrassBagFresnelGlassSurface(
        borderRadius: 24,
        elevated: true,
        clipBehavior: clipBehavior,
        child: innerColumn,
      ),
    );

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
            child: Text(
              header!,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.12,
                color: t.text3,
              ),
            ),
          ),
        platter,
        if (footer != null)
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 12, top: 7),
            child: Text(
              footer!,
              style: TextStyle(fontSize: 11.5, height: 1.42, color: t.text3),
            ),
          ),
      ],
    );

    return margin == EdgeInsets.zero ? content : Padding(padding: margin, child: content);
  }
}

/// Refined Apple iOS 26 / macOS Tahoe grouped row with soft inset rounded highlight,
/// subtle tactile press feedback, optional macOS-style pill `selected` state, and
/// ZERO sharp Material rectangular highlights!
class _GrassBagSectionTileRadiusScope extends InheritedWidget {
  const _GrassBagSectionTileRadiusScope({
    required this.radius,
    required super.child,
  });

  final double radius;

  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GrassBagSectionTileRadiusScope>()?.radius;

  @override
  bool updateShouldNotify(covariant _GrassBagSectionTileRadiusScope oldWidget) =>
      oldWidget.radius != radius;
}

class GrassBagListTile extends StatefulWidget {
  const GrassBagListTile({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.showChevron = false,
    this.selected = false,
    this.borderRadius,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
  });

  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;
  final bool selected;
  final double? borderRadius;
  final EdgeInsetsGeometry contentPadding;

  @override
  State<GrassBagListTile> createState() => _GrassBagListTileState();
}

class _GrassBagListTileState extends State<GrassBagListTile> {
  final ValueNotifier<bool> _pressedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _hoveredNotifier = ValueNotifier<bool>(false);
  late final Listenable _interactionListenable;
  Timer? _pressDelayTimer;
  Timer? _quickFlashTimer;
  bool _didShowPress = false;

  @override
  void initState() {
    super.initState();
    _interactionListenable = Listenable.merge([_pressedNotifier, _hoveredNotifier]);
  }

  @override
  void didUpdateWidget(covariant GrassBagListTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onTap != null && widget.onTap == null) {
      _pressDelayTimer?.cancel();
      _pressDelayTimer = null;
      _quickFlashTimer?.cancel();
      _quickFlashTimer = null;
      _didShowPress = false;
      _pressedNotifier.value = false;
      _hoveredNotifier.value = false;
    }
  }

  void _setPressed(bool v) {
    _pressDelayTimer?.cancel();
    _pressDelayTimer = null;
    if (v) {
      _quickFlashTimer?.cancel();
      _quickFlashTimer = null;
      _didShowPress = true;
    }
    if (_pressedNotifier.value != v && mounted) {
      _pressedNotifier.value = v;
    }
  }

  void _handleTapDown() {
    _pressDelayTimer?.cancel();
    _quickFlashTimer?.cancel();
    _didShowPress = false;
    if (Scrollable.maybeOf(context) != null) {
      _pressDelayTimer = Timer(const Duration(milliseconds: 45), () {
        if (mounted) {
          _didShowPress = true;
          _pressedNotifier.value = true;
        }
      });
    } else {
      _setPressed(true);
    }
  }

  void _triggerQuickFlashIfNeeded() {
    if (_didShowPress) return;
    _pressDelayTimer?.cancel();
    _quickFlashTimer?.cancel();
    _pressedNotifier.value = true;
    _quickFlashTimer = Timer(const Duration(milliseconds: 95), () {
      if (mounted) _pressedNotifier.value = false;
    });
  }

  @override
  void dispose() {
    _pressDelayTimer?.cancel();
    _quickFlashTimer?.cancel();
    _pressedNotifier.dispose();
    _hoveredNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final chevronIcon = Icon(
      CupertinoIcons.chevron_right,
      size: 13.5,
      color: t.text3.withValues(alpha: 0.75),
    );
    final Widget? resolvedTrailing;
    if (widget.trailing != null && widget.showChevron) {
      resolvedTrailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          widget.trailing!,
          const SizedBox(width: 6),
          chevronIcon,
        ],
      );
    } else if (widget.trailing != null) {
      resolvedTrailing = widget.trailing;
    } else if (widget.showChevron) {
      resolvedTrailing = chevronIcon;
    } else {
      resolvedTrailing = null;
    }

    // Automatically wire full-row tap to toggle trailing GrassBagGlassSwitch when no custom onTap is set!
    final switchTrailing = widget.trailing is GrassBagGlassSwitch
        ? widget.trailing! as GrassBagGlassSwitch
        : null;
    final VoidCallback? effectiveOnTap = widget.onTap ??
        (switchTrailing != null && switchTrailing.onChanged != null
            ? () => switchTrailing.onChanged!(!switchTrailing.value)
            : null);

    // Keep margin (6, 3) and 0.7px border footprint CONSTANT across selected/unselected
    // states so toggling selection NEVER shifts vertical height (+1.4px) or text X (+3.4px),
    // while honoring explicit `EdgeInsets.zero` callers flush without phantom inset!
    final basePad = widget.contentPadding.resolve(Directionality.of(context));
    final isFlush = basePad == EdgeInsets.zero;
    final innerPad = isFlush
        ? EdgeInsets.zero
        : EdgeInsets.fromLTRB(
            math.max(0.0, basePad.left - 6.7),
            math.max(0.0, basePad.top - 3.7),
            math.max(0.0, basePad.right - 6.7),
            math.max(0.0, basePad.bottom - 3.7),
          );

    final rowInner = Row(
      children: [
        if (widget.leading != null) ...[
          widget.leading!,
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              DefaultTextStyle.merge(
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
                  letterSpacing: -0.15,
                  color: widget.selected ? t.primary : t.text,
                ),
                child: widget.title,
              ),
              if (widget.subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(fontSize: 12, height: 1.32, color: t.text3),
                    child: widget.subtitle!,
                  ),
                ),
            ],
          ),
        ),
        if (resolvedTrailing != null) ...[
          const SizedBox(width: 10),
          resolvedTrailing,
        ],
      ],
    );

    final pressedBg = t.isDark ? Colors.white.withValues(alpha: 0.08) : t.fill1;
    final hoveredBg = t.isDark
        ? Colors.white.withValues(alpha: 0.045)
        : t.fill1.withValues(alpha: 0.55);
    final inSection = _GrassBagSectionTileRadiusScope.maybeOf(context) != null;
    final selectedBorder = t.primary.withValues(
      alpha: inSection
          ? (t.isDark ? 0.22 : 0.14)
          : (t.isDark ? 0.34 : 0.22),
    );
    final margin =
        isFlush ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 6, vertical: 3);
    final resolvedRadius =
        widget.borderRadius ?? _GrassBagSectionTileRadiusScope.maybeOf(context) ?? 18.0;

    final selectedGrad = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        t.primary.withValues(alpha: t.isDark ? 0.24 : 0.14),
        t.primary.withValues(alpha: t.isDark ? 0.14 : 0.08),
      ],
    );
    final selectedPressedGrad = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        t.primary.withValues(alpha: t.isDark ? 0.32 : 0.20),
        t.primary.withValues(alpha: t.isDark ? 0.20 : 0.12),
      ],
    );
    final rowShape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(resolvedRadius),
      side: BorderSide(
        color: widget.selected ? selectedBorder : Colors.transparent,
        width: 0.7,
      ),
    );

    if (effectiveOnTap == null) {
      return Container(
        margin: margin,
        padding: innerPad,
        decoration: ShapeDecoration(
          color: widget.selected ? null : Colors.transparent,
          gradient: widget.selected ? selectedGrad : null,
          shape: rowShape,
        ),
        child: rowInner,
      );
    }

    // Isolate press/hover highlight into ListenableBuilder so tapping a row NEVER rebuilds
    // title/subtitle/trailing GrassBagGlassSwitch children!
    final interactiveRow = ListenableBuilder(
      listenable: _interactionListenable,
      child: rowInner,
      builder: (context, child) {
        final pressed = _pressedNotifier.value;
        final hovered = _hoveredNotifier.value;
        final bgColor = pressed ? pressedBg : (hovered ? hoveredBg : Colors.transparent);
        // Always provide a 2-stop LinearGradient (never switching between `color` and
        // `gradient`) so `AnimatedContainer` -> `ShapeDecoration.lerp` never violates
        // `!(color != null && gradient != null)` during selection transitions!
        final rowGrad = widget.selected
            ? (pressed ? selectedPressedGrad : selectedGrad)
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [bgColor, bgColor],
              );
        return AnimatedContainer(
          duration: GrassBagMotion.duration(context, const Duration(milliseconds: 110)),
          curve: Curves.easeOutCubic,
          margin: margin,
          padding: innerPad,
          decoration: ShapeDecoration(
            gradient: rowGrad,
            shape: rowShape,
          ),
          child: child,
        );
      },
    );

    return Semantics(
      button: true,
      selected: widget.selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          if (!_hoveredNotifier.value) _hoveredNotifier.value = true;
        },
        onExit: (_) {
          if (_hoveredNotifier.value) _hoveredNotifier.value = false;
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _handleTapDown(),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          onTap: () {
            _triggerQuickFlashIfNeeded();
            HapticFeedback.selectionClick();
            effectiveOnTap();
          },
          child: interactiveRow,
        ),
      ),
    );
  }
}

/// Snappy 120fps Cupertino-style page route (`260ms` forward / `220ms` reverse) replacing
/// the sluggish `500ms` full-screen clipped `GlassPageRoute` so navigating between Chat,
/// Settings, Terminal, and Detail pages feels instantaneous and stutter-free on Android!
class GrassBagPageRoute<T> extends CupertinoPageRoute<T> {
  GrassBagPageRoute({
    required super.builder,
    super.title,
    super.settings,
    super.maintainState = true,
    super.fullscreenDialog = false,
  });

  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 220);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final bounded = RepaintBoundary(child: child);
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: animation, child: bounded);
    }
    return super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      bounded,
    );
  }
}

/// Kyant0 `AndroidLiquidGlass`-inspired tactile spring wrapper combining:
/// - Underdamped spring swell/press response (`GlassSpring.bouncy`)
/// - Magnetic `tanh` rubber-band finger follow & subtle anisotropic stretch while pressed
/// - Pointer-following radial specular highlight (`InteractiveHighlight`)
/// - Non-competing `Listener` tracking so `ListView` vertical scrolling stays 100% silky!
class GrassBagSpringTap extends StatefulWidget {
  const GrassBagSpringTap({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.pressedScale = 0.962,
    this.haptic = false,
    this.enablePointerGlow = true,
    this.enabled = true,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final bool haptic;
  final bool enablePointerGlow;
  final bool enabled;
  final double? borderRadius;

  @override
  State<GrassBagSpringTap> createState() => _GrassBagSpringTapState();
}

class _SpringTickProxy extends ChangeNotifier {
  void notify() => notifyListeners();
}

class _GrassBagSpringTapState extends State<GrassBagSpringTap>
    with TickerProviderStateMixin {
  final _SpringTickProxy _tickProxy = _SpringTickProxy();
  final ValueNotifier<Offset> _pointerPosNotifier = ValueNotifier<Offset>(Offset.zero);
  late final Listenable _glowRepaintListenable =
      Listenable.merge([_tickProxy, _pointerPosNotifier]);
  SingleSpringController? _pressSpring;
  SingleSpringController? _dragXSpring;
  SingleSpringController? _dragYSpring;
  Timer? _scrollDeferTimer;
  int? _activePointerId;
  Offset _startPos = Offset.zero;
  bool _tracking = false;
  bool _engaged = false;
  bool _didEngageThisGesture = false;
  bool _inScrollable = false;

  /// Lazily allocates spring controllers & tickers ONLY on first genuine press!
  /// Tree depth stays 100% constant at rest, during press, and when disabled, so stateful
  /// children NEVER unmount/remount mid-tap.
  void _ensurePressSpring() {
    if (_pressSpring != null) return;
    _pressSpring = SingleSpringController(
      vsync: this,
      spring: GlassSpring.interactive(duration: const Duration(milliseconds: 200)),
      initialValue: 0.0,
    )..addListener(_tickProxy.notify);
  }

  void _ensureDragSprings() {
    if (_dragXSpring != null) return;
    _dragXSpring = SingleSpringController(
      vsync: this,
      spring: GlassSpring.snappy(duration: const Duration(milliseconds: 220)),
      initialValue: 0.0,
    )..addListener(_tickProxy.notify);
    _dragYSpring = SingleSpringController(
      vsync: this,
      spring: GlassSpring.snappy(duration: const Duration(milliseconds: 220)),
      initialValue: 0.0,
    )..addListener(_tickProxy.notify);
  }

  @override
  void didUpdateWidget(covariant GrassBagSpringTap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _release(force: true);
    }
  }

  @override
  void dispose() {
    _scrollDeferTimer?.cancel();
    _pressSpring?.removeListener(_tickProxy.notify);
    _dragXSpring?.removeListener(_tickProxy.notify);
    _dragYSpring?.removeListener(_tickProxy.notify);
    _pressSpring?.dispose();
    _dragXSpring?.dispose();
    _dragYSpring?.dispose();
    _pointerPosNotifier.dispose();
    _tickProxy.dispose();
    super.dispose();
  }

  static double _tanh(double x) {
    final e2x = math.exp(2.0 * x.clamp(-6.0, 6.0));
    return (e2x - 1.0) / (e2x + 1.0);
  }

  void _engagePress() {
    if (!_tracking || _engaged || !mounted) return;
    if (MediaQuery.disableAnimationsOf(context)) return;
    _engaged = true;
    _didEngageThisGesture = true;
    _ensurePressSpring();
    _pressSpring!.spring = GlassSpring.smooth(duration: const Duration(milliseconds: 95));
    _pressSpring!.animateTo(1.0);
  }

  /// Ensures brisk 35–55ms taps inside a `Scrollable` still deliver a crisp tactile bounce
  /// even when `onPointerUp` fires before the scroll-disambiguation defer timer elapses!
  void _triggerQuickTapImpulse() {
    if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
    _ensurePressSpring();
    _pressSpring!.spring = GlassSpring.interactive(
      duration: const Duration(milliseconds: 220),
      extraBounce: 0.08,
    );
    // Smooth spring-velocity impulse from rest instead of a 1-frame 0 -> 0.65 snap!
    _pressSpring!.animateTo(0.0, fromVelocity: 11.0);
  }

  void _release({bool force = false}) {
    _scrollDeferTimer?.cancel();
    _scrollDeferTimer = null;
    if (!_tracking && !force) return;
    _activePointerId = null;
    _tracking = false;
    final wasEngaged = _engaged;
    _engaged = false;
    final reduceMotion = mounted && MediaQuery.disableAnimationsOf(context);
    final press = _pressSpring;
    if (press != null && (wasEngaged || press.value.abs() > 0.001 || press.velocity.abs() > 0.001)) {
      if (reduceMotion) {
        press.setValue(0.0);
      } else {
        press.spring = GlassSpring.interactive(
          duration: const Duration(milliseconds: 240),
          extraBounce: 0.08,
        );
        press.animateTo(0.0);
      }
    }
    final dx = _dragXSpring;
    if (dx != null && (dx.value.abs() > 0.001 || dx.velocity.abs() > 0.001)) {
      if (reduceMotion) {
        dx.setValue(0.0);
      } else {
        dx.animateTo(0.0);
      }
    }
    final dy = _dragYSpring;
    if (dy != null && (dy.value.abs() > 0.001 || dy.velocity.abs() > 0.001)) {
      if (reduceMotion) {
        dy.setValue(0.0);
      } else {
        dy.animateTo(0.0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final inner = RepaintBoundary(
      child: ListenableBuilder(
        listenable: _tickProxy,
        child: widget.child,
        builder: (context, child) {
          final p = _pressSpring?.value ?? 0.0;
          final dx = _dragXSpring?.value ?? 0.0;
          final dy = _dragYSpring?.value ?? 0.0;
          final atRest = p.abs() < 0.0005 && dx.abs() < 0.01 && dy.abs() < 0.01;

          final Matrix4 mat;
          if (atRest) {
            mat = Matrix4.identity();
          } else {
            final baseScale = 1.0 + (widget.pressedScale - 1.0) * p;
            final stretchX = (baseScale + dx.abs() * 0.004).clamp(0.84, 1.08);
            final stretchY = (baseScale + dy.abs() * 0.004).clamp(0.84, 1.08);
            mat = Matrix4.identity()
              ..translateByDouble(dx, dy, 0.0, 1.0)
              ..scaleByDouble(stretchX, stretchY, 1.0, 1.0);
          }

          return Transform(
            alignment: Alignment.center,
            transform: mat,
            child: CustomPaint(
              foregroundPainter: (widget.enablePointerGlow && p > 0.01)
                  ? _KyantPointerGlowPainter(
                      repaint: _glowRepaintListenable,
                      centerNotifier: _pointerPosNotifier,
                      progress: p.clamp(0.0, 1.0),
                      isDark: t.isDark,
                      accent: t.primaryHi,
                      borderRadius: widget.borderRadius,
                    )
                  : null,
              child: child!,
            ),
          );
        },
      ),
    );

    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: widget.enabled
            ? (e) {
                // Ignore secondary multi-touch pointers so they never clobber the active press!
                if (_activePointerId != null) return;
                _scrollDeferTimer?.cancel();
                _activePointerId = e.pointer;
                _tracking = true;
                _engaged = false;
                _didEngageThisGesture = false;
                _startPos = e.localPosition;
                _pointerPosNotifier.value = e.localPosition;
                _inScrollable = Scrollable.maybeOf(context) != null;
                if (_inScrollable) {
                  // Defer press-scale slightly inside scrollables so normal ListView drags
                  // cancel cleanly before shrinking or pulling cards under the thumb!
                  _scrollDeferTimer = Timer(const Duration(milliseconds: 55), _engagePress);
                } else {
                  _engagePress();
                }
              }
            : null,
        onPointerMove: widget.enabled
            ? (e) {
                if (!_tracking || _activePointerId != e.pointer) return;
                final delta = e.localPosition - _startPos;
                final slop = _inScrollable ? 10.0 : 22.0;
                if (delta.distance > slop) {
                  _release();
                  return;
                }
                _pointerPosNotifier.value = e.localPosition;
                // Magnetic finger-follow only on floating chrome outside scrollables
                if (_engaged && !_inScrollable) {
                  _ensureDragSprings();
                  const maxPull = 3.5;
                  _dragXSpring!.setValue(maxPull * _tanh(delta.dx * 0.08));
                  _dragYSpring!.setValue(maxPull * _tanh(delta.dy * 0.08));
                }
              }
            : null,
        onPointerUp: widget.enabled
            ? (e) {
                if (_activePointerId == e.pointer) _release();
              }
            : null,
        onPointerCancel: widget.enabled
            ? (e) {
                if (_activePointerId == e.pointer) _release();
              }
            : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: (!widget.enabled || widget.onLongPress == null)
              ? null
              : () {
                  _release(force: true);
                  HapticFeedback.mediumImpact();
                  widget.onLongPress!();
                },
          onTap: widget.enabled
              ? () {
                  if (!_didEngageThisGesture) {
                    _triggerQuickTapImpulse();
                  }
                  if (widget.haptic) HapticFeedback.selectionClick();
                  widget.onTap();
                }
              : null,
          child: inner,
        ),
      ),
    );
  }
}

class _KyantPointerGlowPainter extends CustomPainter {
  const _KyantPointerGlowPainter({
    required super.repaint,
    required this.centerNotifier,
    required this.progress,
    required this.isDark,
    required this.accent,
    this.borderRadius,
  });

  final ValueNotifier<Offset> centerNotifier;
  final double progress;
  final bool isDark;
  final Color accent;
  final double? borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = math.max(size.shortestSide * 1.15, 36.0);
    final rect = Offset.zero & size;
    final clipR = borderRadius ?? math.min(size.shortestSide * 0.5, 24.0);
    final superellipse = RSuperellipse.fromRectAndRadius(rect, Radius.circular(clipR));
    final center = centerNotifier.value;
    final spotColor = Color.lerp(Colors.white, accent, isDark ? 0.22 : 0.36)!;
    final blend = isDark ? BlendMode.plus : BlendMode.srcOver;
    canvas.save();
    canvas.clipRSuperellipse(superellipse);
    final paint = Paint()
      ..blendMode = blend
      ..shader = RadialGradient(
        colors: [
          spotColor.withValues(alpha: (isDark ? 0.16 : 0.22) * progress),
          spotColor.withValues(alpha: (isDark ? 0.04 : 0.08) * progress),
          spotColor.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawRect(rect, paint);
    canvas.restore();
    // Subtle specular crystal edge glint emanating from the contact point
    final rimColor = isDark ? Colors.white : Color.lerp(Colors.white, accent, 0.30)!;
    final rimPaint = Paint()
      ..blendMode = blend
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..shader = RadialGradient(
        colors: [
          rimColor.withValues(alpha: (isDark ? 0.28 : 0.48) * progress),
          rimColor.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius * 0.92));
    canvas.drawRSuperellipse(superellipse.deflate(0.5), rimPaint);
  }

  @override
  bool shouldRepaint(covariant _KyantPointerGlowPainter old) =>
      old.progress != progress ||
      old.isDark != isDark ||
      old.accent != accent ||
      old.borderRadius != borderRadius;
}

/// Prominent Kyant0 `LiquidButton` tinted Liquid Glass CTA capsule:
/// - Faithful `vibrancy() -> blur(2.5dp) -> lens(12dp, 24dp) -> BlendMode.hue + tint.alpha ->
///   Highlight.Default` optical rendering on EVERY surface (canvas, cards, sheets, dialogs!)
/// - Full Kyant0 `InteractiveHighlight` touch-following glow + `tanh` magnetic elastic stretch!
class GrassBagPrimaryGlassButton extends StatelessWidget {
  const GrassBagPrimaryGlassButton({
    super.key,
    required this.label,
    required this.onTap,
    required this.tier,
    this.icon,
    this.height = 44,
    this.insideGlass = false,
    this.enabled = true,
    this.color,
    this.foregroundColor,
    this.padding = const EdgeInsets.symmetric(horizontal: 14),
  });

  final String label;
  final VoidCallback? onTap;
  final GrassBagGlassTier tier;
  final IconData? icon;
  final double height;
  final bool insideGlass;
  final bool enabled;
  final Color? color;
  final Color? foregroundColor;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final active = enabled && onTap != null;
    final bg = color ?? t.primary;
    final fg = foregroundColor ?? t.onPrimary;
    final effectiveTier = resolveEffectiveGlassTier(context, tier);
    final isSolid = effectiveTier == GrassBagGlassTier.solid;

    final compact = height <= 34;
    final clampedScaler = compact
        ? MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2)
        : null;
    final labelRow = Padding(
      padding: padding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: compact ? 14 : 16, color: fg),
            SizedBox(width: compact ? 4.5 : 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textScaler: clampedScaler,
              style: TextStyle(
                fontSize: compact ? 12.2 : 13.5,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.15,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );

    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: height, maxHeight: height),
      child: Center(
        widthFactor: 1.0,
        child: labelRow,
      ),
    );

    if (isSolid) {
      final solidPill = DecoratedBox(
        decoration: ShapeDecoration(
          color: bg,
          shape: StadiumBorder(
            side: BorderSide(color: Colors.white.withValues(alpha: 0.16), width: 0.65),
          ),
        ),
        child: content,
      );
      if (!active) {
        return IgnorePointer(child: Opacity(opacity: 0.45, child: solidPill));
      }
      return Semantics(
        button: true,
        label: label,
        child: GrassBagSpringTap(
          onTap: () {
            HapticFeedback.lightImpact();
            onTap!();
          },
          pressedScale: 0.96,
          enablePointerGlow: false,
          child: solidPill,
        ),
      );
    }

    // Genuine Kyant0 LiquidButton tinted refractive glass everywhere!
    final style = KyantLiquidGlassStyle.button(
      t,
      effectiveTier,
      tint: bg,
    );
    final materializeAnim = GrassBagMaterializeScope.animationOf(context);
    return Semantics(
      button: true,
      label: label,
      enabled: active,
      child: KyantInteractiveGlassButton(
        onTap: active ? onTap : null,
        enabled: active,
        style: style,
        isCapsule: true,
        height: height,
        materializeAnimation: materializeAnim,
        child: labelRow,
      ),
    );
  }
}

/// Secondary Kyant0 `LiquidButton` crystal translucent glass capsule:
/// - Faithful `vibrancy() -> blur(2.5dp) -> lens(12dp, 24dp) -> Highlight.Default` crystal glass
///   on cards, sheets, dialogs, and canvas (or softly tinted red/accent glass!)
/// - Full Kyant0 `InteractiveHighlight` touch glow + `tanh` magnetic elastic stretch!
class GrassBagSecondaryGlassButton extends StatelessWidget {
  const GrassBagSecondaryGlassButton({
    super.key,
    required this.label,
    required this.onTap,
    required this.tier,
    this.icon,
    this.height = 44,
    this.insideGlass = false,
    this.destructive = false,
    this.accentForeground = false,
    this.enabled = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 14),
  });

  final String label;
  final VoidCallback? onTap;
  final GrassBagGlassTier tier;
  final IconData? icon;
  final double height;
  final bool insideGlass;
  final bool destructive;
  final bool accentForeground;
  final bool enabled;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final active = enabled && onTap != null;
    final fg = destructive
        ? (t.isDark ? const Color(0xFFFF8F8B) : t.err)
        : (accentForeground ? (t.isDark ? t.primaryHi : t.primary) : t.text);
    final effectiveTier = resolveEffectiveGlassTier(context, tier);
    final isSolid = effectiveTier == GrassBagGlassTier.solid;

    final compact = height <= 34;
    final clampedScaler = compact
        ? MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2)
        : null;
    final labelRow = Padding(
      padding: padding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: compact ? 14 : 16, color: fg),
            SizedBox(width: compact ? 4.5 : 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textScaler: clampedScaler,
              style: TextStyle(
                fontSize: compact ? 12.2 : 13.5,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.15,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );

    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: height, maxHeight: height),
      child: Center(
        widthFactor: 1.0,
        child: labelRow,
      ),
    );

    if (isSolid) {
      final solidBg = destructive
          ? t.errSoft
          : (accentForeground
              ? t.primarySoft
              : (t.isDark
                  ? Colors.white.withValues(alpha: 0.11)
                  : Color.lerp(t.fill1, Colors.white, 0.76)!));
      final solidBorder = destructive
          ? t.err.withValues(alpha: t.isDark ? 0.34 : 0.24)
          : (accentForeground
              ? t.primary.withValues(alpha: t.isDark ? 0.32 : 0.24)
              : (t.isDark ? Colors.white.withValues(alpha: 0.16) : t.sepStrong));
      final solidPill = DecoratedBox(
        decoration: ShapeDecoration(
          color: solidBg,
          shape: StadiumBorder(side: BorderSide(color: solidBorder, width: 0.65)),
        ),
        child: content,
      );
      if (!active) {
        return IgnorePointer(child: Opacity(opacity: 0.45, child: solidPill));
      }
      return Semantics(
        button: true,
        label: label,
        child: GrassBagSpringTap(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap?.call();
          },
          pressedScale: 0.96,
          enablePointerGlow: false,
          child: solidPill,
        ),
      );
    }

    // Real Kyant0 LiquidButton crystal / subtly tinted refractive glass!
    final Color surfaceColor;
    if (destructive) {
      surfaceColor = t.err.withValues(alpha: t.isDark ? 0.22 : 0.12);
    } else if (accentForeground) {
      surfaceColor = t.primary.withValues(alpha: t.isDark ? 0.20 : 0.11);
    } else {
      surfaceColor = t.isDark
          ? Colors.white.withValues(alpha: insideGlass ? 0.11 : 0.12)
          : const Color(0xFFFAFAFA).withValues(alpha: insideGlass ? 0.50 : 0.56);
    }
    final style = KyantLiquidGlassStyle.button(
      t,
      effectiveTier,
      surfaceColor: surfaceColor,
    );
    final materializeAnim = GrassBagMaterializeScope.animationOf(context);
    return Semantics(
      button: true,
      label: label,
      enabled: active,
      child: KyantInteractiveGlassButton(
        onTap: active ? onTap : null,
        enabled: active,
        style: style,
        isCapsule: true,
        height: height,
        materializeAnimation: materializeAnim,
        child: labelRow,
      ),
    );
  }
}

/// Signature Apple iOS 26 continuous superellipse icon badge with luminous vertical sheen
/// and hairline inner specular edge (concentric geometry, zero boxy Android corners!).
class GrassBagSquircleIcon extends StatelessWidget {
  const GrassBagSquircleIcon({
    super.key,
    required this.icon,
    required this.color,
    this.size = 34,
    this.iconSize = 17,
    this.filled = false,
    this.foregroundColor,
  });

  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;
  final bool filled;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final radius = size * 0.30;

    // Normalize luminous chromatic Dark-mode filled badges into rich Apple jewel pigments
    // so white glyphs stay uniformly crisp (>= 4.2:1) instead of flipping randomly to black!
    final hsl = HSLColor.fromColor(color);
    final isChromatic = hsl.saturation >= 0.08;
    final Color baseColor;
    if (filled && t.isDark && isChromatic && hsl.lightness > 0.42) {
      baseColor = hsl.withLightness(0.42).toColor();
    } else {
      baseColor = color;
    }

    final topCol = filled
        ? Color.lerp(baseColor, Colors.white, t.isDark ? 0.14 : 0.20)!
        : baseColor.withValues(alpha: t.isDark ? 0.30 : 0.21);
    final botCol = filled
        ? Color.lerp(baseColor, Colors.black, t.isDark ? 0.16 : 0.10)!
        : baseColor.withValues(alpha: t.isDark ? 0.12 : 0.085);

    final Color fgColor;
    if (foregroundColor != null) {
      fgColor = foregroundColor!;
    } else if (filled) {
      final baseLum = baseColor.computeLuminance();
      if (!isChromatic && baseLum > 0.55) {
        fgColor = t.onPrimary;
      } else if (!t.isDark && baseLum > 0.62) {
        fgColor = const Color(0xFF0F1C26);
      } else {
        fgColor = Colors.white;
      }
    } else {
      fgColor = color;
    }

    final box = Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: filled ? [topCol, baseColor, botCol] : [topCol, botCol],
          stops: filled ? const [0.0, 0.55, 1.0] : null,
        ),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
          side: filled
              ? BorderSide(
                  color: Colors.white.withValues(alpha: t.isDark ? 0.22 : 0.34),
                  width: 0.6,
                )
              : BorderSide.none,
        ),
        shadows: filled
            ? [
                BoxShadow(
                  color: baseColor.withValues(alpha: t.isDark ? 0.28 : 0.20),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: Icon(
        icon,
        size: iconSize,
        color: fgColor,
      ),
    );
    return box;
  }
}

/// Shared Apple iOS 26/27 & Kyant0 top-edge scroll dissolve veil placed BEHIND floating
/// Liquid Glass navigation bars ([GrassBagUnifiedHeader] and [GrassBagShell]):
/// - Extends `ProgressiveBlur` smoothly through the full floating nav pill zone (`topPad + 72dp`,
///   `falloff: 1.75`) so scrolled card borders & text melt cleanly beneath `<` and title pills
///   without double-blurring or colliding into high-contrast clutter!
class GrassBagScrollEdgeMist extends StatelessWidget {
  const GrassBagScrollEdgeMist({
    super.key,
    required this.tier,
    required this.topPad,
    this.extraHeight = 0.0,
  });

  final GrassBagGlassTier tier;
  final double topPad;
  final double extraHeight;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final effectiveTier = resolveEffectiveGlassTier(context, tier);
    final isLiquid = effectiveTier == GrassBagGlassTier.liquid;
    final useProgressiveBlur = effectiveTier != GrassBagGlassTier.solid &&
        !MediaQuery.highContrastOf(context) &&
        !kIsWeb &&
        ui.ImageFilter.isShaderFilterSupported;
    final hasStatusBar = topPad > 4.0;
    final baseTop = hasStatusBar ? topPad : 0.0;
    final extra = extraHeight.clamp(0.0, 140.0);
    final blurH = baseTop + (isLiquid ? 72.0 : 80.0) + extra;
    final capH = baseTop + 68.0 + extra * 0.85;
    final s1 = (baseTop / capH).clamp(0.18, 0.46);
    final s2 = ((baseTop + 26.0) / capH).clamp(s1 + 0.14, 0.70);
    final s3 = ((baseTop + 48.0) / capH).clamp(s2 + 0.12, 0.90);
    final topAlphas = useProgressiveBlur
        ? (t.isDark
            ? const [0.88, 0.62, 0.30, 0.08, 0.0]
            : const [0.92, 0.68, 0.34, 0.10, 0.0])
        : (t.isDark
            ? const [0.96, 0.80, 0.46, 0.14, 0.0]
            : const [0.98, 0.84, 0.50, 0.16, 0.0]);

    return IgnorePointer(
      child: SizedBox(
        height: math.max(blurH, capH),
        width: double.infinity,
        child: Stack(
          children: [
            if (useProgressiveBlur)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: blurH,
                child: ProgressiveBlur(
                  maxSigma: isLiquid ? 8.5 : 10.0,
                  direction: ProgressiveBlurDirection.topToBottom,
                  falloff: isLiquid ? 1.75 : 1.6,
                ),
              ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: capH,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      t.bgTop.withValues(alpha: topAlphas[0]),
                      t.bgTop.withValues(alpha: topAlphas[1]),
                      t.bgTop.withValues(alpha: topAlphas[2]),
                      t.bgTop.withValues(alpha: topAlphas[3]),
                      t.bgTop.withValues(alpha: topAlphas[4]),
                    ],
                    stops: [0.0, s1, s2, s3, 1.0],
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

/// Symmetrical dead-center Liquid Glass header used on ALL secondary pages
/// (Settings, Session Detail, Terminal, All Features, Official WebUI, Permissions, Features).
/// Uses a centered [Stack] so 2-button trailing clusters NEVER pull the title pill off-center!
class GrassBagUnifiedHeader extends StatelessWidget {
  const GrassBagUnifiedHeader({
    super.key,
    required this.title,
    required this.tier,
    required this.onBack,
    this.subtitle,
    this.trailing,
    this.platformViewBackdrop = false,
    this.glassTitlePill = true,
    this.floating = true,
    this.wideTrailing,
  });

  final String title;
  final String? subtitle;
  final GrassBagGlassTier tier;
  final VoidCallback onBack;
  final Widget? trailing;
  final bool platformViewBackdrop;
  final bool glassTitlePill;
  final bool floating;
  final bool? wideTrailing;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final effectiveTier = resolveEffectiveGlassTier(context, tier);
    final topPad = MediaQuery.viewPaddingOf(context).top;
    final hasWideTrailing = wideTrailing ??
        (trailing is Row ||
            trailing is GrassBagGlassPillButton ||
            trailing is GrassBagSecondaryGlassButton);
    final clampedTitleScaler =
        MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.15);
    // Apply `textScaler` directly on each Text instead of wrapping `MediaQuery.of(context)`
    // so IME `viewInsets` ticks NEVER rebuild every glass header at 120Hz!
    final titleContent = AnimatedSwitcher(
      duration: GrassBagMotion.duration(context, const Duration(milliseconds: 180)),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: Column(
        key: ValueKey('$title|${subtitle ?? ''}'),
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            textScaler: clampedTitleScaler,
            style: TextStyle(
              fontSize: subtitle != null && subtitle!.isNotEmpty ? 13.5 : 15,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              height: 1.15,
              color: t.text,
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              textScaler: clampedTitleScaler,
              style: TextStyle(fontSize: 10.5, height: 1.15, color: t.text3),
            ),
        ],
      ),
    );

    final headerRow = Padding(
      padding: EdgeInsets.fromLTRB(12, topPad + 12, 12, 10),
      child: SizedBox(
        height: 44,
        child: GrassBagGlassBarLayer(
          tier: tier,
          platformViewBackdrop: platformViewBackdrop,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Keep title pill dead-center whenever viewport width accommodates symmetric margins;
              // fall back to asymmetric clearance only on ultra-narrow (<340dp) viewports.
              final titlePadding = !hasWideTrailing
                  ? const EdgeInsets.symmetric(horizontal: 54.0)
                  : (constraints.maxWidth >= 340
                      ? const EdgeInsets.symmetric(horizontal: 104.0)
                      : const EdgeInsets.only(left: 54.0, right: 104.0));
              return Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GrassBagGlassCircleButton(
                      icon: CupertinoIcons.chevron_back,
                      tooltip: '返回',
                      tier: tier,
                      iconSize: 19,
                      useOwnLayer: false,
                      platformViewBackdrop: platformViewBackdrop,
                      onTap: onBack,
                    ),
                  ),
                  Padding(
                    padding: titlePadding,
                    child: glassTitlePill
                        ? GrassBagGlass(
                            tier: tier,
                            borderRadius: 999,
                            height: 44,
                            useOwnLayer: platformViewBackdrop,
                            platformViewBackdrop: platformViewBackdrop,
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minWidth: 52),
                              child: Center(
                                widthFactor: 1.0,
                                child: titleContent,
                              ),
                            ),
                          )
                        : titleContent,
                  ),
                  if (trailing != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: trailing!,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );

    if (platformViewBackdrop || !floating) return headerRow;

    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: GrassBagScrollEdgeMist(
            tier: effectiveTier,
            topPad: topPad,
          ),
        ),
        headerRow,
      ],
    );
  }
}

/// Lightweight status dot that renders as a static circle when idle (zero tickers)
/// and gently breathes when `pulsing == true` (e.g. connecting / bootstrapping).
class GrassBagStatusDot extends StatefulWidget {
  const GrassBagStatusDot({
    super.key,
    required this.color,
    this.size = 7.0,
    this.pulsing = false,
    this.border,
  });

  final Color color;
  final double size;
  final bool pulsing;
  final BoxBorder? border;

  @override
  State<GrassBagStatusDot> createState() => _GrassBagStatusDotState();
}

class _GrassBagStatusDotState extends State<GrassBagStatusDot>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;
  bool _routeCurrent = true;
  bool _animationsEnabled = true;

  void _syncController() {
    // Only spin an infinite pulse ticker on real app bindings when this route is foremost
    // and OS animations are enabled — prevents sheets/dialogs above from re-blurring at 120Hz
    // and lets flutter_test `pumpAndSettle()` finish cleanly!
    final canAnimate = widget.pulsing && WidgetsBinding.instance is WidgetsFlutterBinding;
    if (!canAnimate) {
      _ctrl?.dispose();
      _ctrl = null;
      return;
    }
    _ctrl ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    if (_routeCurrent && _animationsEnabled) {
      if (!_ctrl!.isAnimating) {
        _ctrl!.repeat(reverse: true);
      }
    } else {
      if (_ctrl!.isAnimating) {
        _ctrl!.stop();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final nextEnabled =
        !MediaQuery.disableAnimationsOf(context) && TickerMode.valuesOf(context).enabled;
    if (nextCurrent != _routeCurrent || nextEnabled != _animationsEnabled || _ctrl == null) {
      _routeCurrent = nextCurrent;
      _animationsEnabled = nextEnabled;
      _syncController();
    }
  }

  @override
  void didUpdateWidget(covariant GrassBagStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulsing != widget.pulsing) {
      _syncController();
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    if (ctrl == null) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          border: widget.border,
          boxShadow: widget.pulsing
              ? [
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.36),
                    blurRadius: 6.0,
                    spreadRadius: 0.4,
                  ),
                ]
              : null,
        ),
      );
    }
    // Isolate pulsing repaint inside RepaintBoundary + CustomPaint with bloom headroom
    // so 120Hz status breathing never clips its outer radial halo or dirties parent glass!
    final paintExtent = widget.size + 8.0;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: OverflowBox(
        minWidth: paintExtent,
        maxWidth: paintExtent,
        minHeight: paintExtent,
        maxHeight: paintExtent,
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.square(paintExtent),
            painter: _PulsingStatusDotPainter(
              animation: ctrl,
              color: widget.color,
              dotSize: widget.size,
              border: widget.border,
            ),
          ),
        ),
      ),
    );
  }
}

class _PulsingStatusDotPainter extends CustomPainter {
  _PulsingStatusDotPainter({
    required this.animation,
    required this.color,
    required this.dotSize,
    this.border,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final double dotSize;
  final BoxBorder? border;

  final Paint _outerHaloPaint = Paint();
  final Paint _innerHaloPaint = Paint();
  final Paint _fillPaint = Paint();
  final Paint _borderPaint = Paint()..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final v = Curves.easeInOutSine.transform(animation.value);
    final center = Offset(size.width / 2, size.height / 2);
    final radius = dotSize / 2;
    if (v > 0.02) {
      // Soft two-ring radial bloom (zero GPU MaskFilter.blur offscreen pass per frame!)
      _outerHaloPaint.color = color.withValues(alpha: 0.14 * v);
      canvas.drawCircle(center, radius + 3.2 * v, _outerHaloPaint);
      _innerHaloPaint.color = color.withValues(alpha: 0.28 * v);
      canvas.drawCircle(center, radius + 1.5 * v, _innerHaloPaint);
    }
    _fillPaint.color = color.withValues(alpha: 0.48 + 0.52 * v);
    canvas.drawCircle(center, radius, _fillPaint);
    if (border is Border) {
      final top = (border! as Border).top;
      if (top.width > 0 && top.style != BorderStyle.none) {
        _borderPaint
          ..color = top.color
          ..strokeWidth = top.width;
        canvas.drawCircle(center, radius - top.width / 2, _borderPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PulsingStatusDotPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.dotSize != dotSize ||
      oldDelegate.border != border ||
      oldDelegate.animation != animation;
}

/// Content-layer iOS 26 continuous superellipse card ([RoundedSuperellipseBorder]) harmonized
/// with [GrassBagGroupedSection]'s luminous translucent surface, specular rim, and soft depth.
class GrassBagCard extends StatelessWidget {
  const GrassBagCard({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius = 24,
    this.color,
    this.elevated = true,
    this.interactive = false,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double borderRadius;
  final Color? color;
  final bool elevated;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    return InheritedGlassSurfaceStyle(
      surfaceStyle: GlassSurfaceStyle.solid,
      child: GrassBagFresnelGlassSurface(
        borderRadius: borderRadius,
        padding: padding,
        elevated: elevated,
        interactive: interactive,
        tintColor: color,
        child: child,
      ),
    );
  }
}

/// Concentric `16pt` continuous superellipse grouped section specifically designed for
/// inside floating `showGrassBagSheet` modals (`32pt` outer − `16px` padding = `16pt` inner;
/// carved translucent crystal glass well, auto-indented dividers, ZERO drop shadow).
class GrassBagSheetSection extends StatelessWidget {
  const GrassBagSheetSection({
    super.key,
    required this.children,
    this.header,
    this.footer,
    this.dividerIndent,
    this.borderRadius = 16,
    this.padding,
    this.clipBehavior = Clip.none,
    this.showDividers = true,
  });

  final List<Widget> children;
  final String? header;
  final String? footer;
  final double? dividerIndent;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final Clip clipBehavior;
  final bool showDividers;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      final item = children[i];
      rows.add(item);
      if (showDividers &&
          i < children.length - 1 &&
          item is! Divider &&
          children[i + 1] is! Divider) {
        final hasLeading = item is GrassBagListTile && item.leading != null;
        final indent = dividerIndent ?? (hasLeading ? 56.0 : 14.0);
        rows.add(
          Divider(
            height: 0.5,
            thickness: 0.5,
            indent: indent,
            endIndent: 14,
            color: t.sep,
          ),
        );
      }
    }

    final content = Padding(
      padding: padding ?? const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );

    final surface = InheritedGlassSurfaceStyle(
      surfaceStyle: GlassSurfaceStyle.solid,
      child: _GrassBagSectionTileRadiusScope(
        radius: math.max(10.0, borderRadius - 6.0),
        child: GrassBagFresnelGlassSurface(
          borderRadius: borderRadius,
          innerWell: true,
          clipBehavior: clipBehavior,
          child: content,
        ),
      ),
    );

    if (header == null && footer == null) return surface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.only(left: 6, right: 6, bottom: 6),
            child: Text(
              header!,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.text3),
            ),
          ),
        surface,
        if (footer != null)
          Padding(
            padding: const EdgeInsets.only(left: 6, right: 6, top: 6),
            child: Text(
              footer!,
              style: TextStyle(fontSize: 11.5, height: 1.38, color: t.text3),
            ),
          ),
      ],
    );
  }
}

/// Canonical iOS 26 continuous superellipse text input with smooth focus ring,
/// harmonized placeholder typography, and optional prefix/suffix/monospace styling.
/// Replaces all inconsistent raw `CupertinoTextField` / `TextField` inputs across sheets & settings.
class GrassBagTextField extends StatefulWidget {
  const GrassBagTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.placeholder,
    this.onChanged,
    this.onSubmitted,
    this.keyboardType,
    this.textInputAction,
    this.obscureText = false,
    this.autofocus = false,
    this.enabled = true,
    this.readOnly = false,
    this.monospace = false,
    this.insideGlass = true,
    this.minLines,
    this.maxLines = 1,
    this.fontSize = 14,
    this.borderRadius = 14,
    this.padding = const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
    this.prefix,
    this.suffix,
    this.style,
    this.hasError = false,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? placeholder;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool obscureText;
  final bool autofocus;
  final bool enabled;
  final bool readOnly;
  final bool monospace;
  final bool insideGlass;
  final int? minLines;
  final int? maxLines;
  final double fontSize;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final Widget? prefix;
  final Widget? suffix;
  final TextStyle? style;
  final bool hasError;

  @override
  State<GrassBagTextField> createState() => _GrassBagTextFieldState();
}

class _GrassBagTextFieldState extends State<GrassBagTextField> {
  FocusNode? _ownedFocus;
  bool _focused = false;

  FocusNode get _effectiveFocus => widget.focusNode ?? (_ownedFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _effectiveFocus.addListener(_onFocusChange);
    _focused = _effectiveFocus.hasFocus;
  }

  @override
  void didUpdateWidget(covariant GrassBagTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownedFocus)?.removeListener(_onFocusChange);
      _effectiveFocus.addListener(_onFocusChange);
      _focused = _effectiveFocus.hasFocus;
    }
  }

  @override
  void dispose() {
    (widget.focusNode ?? _ownedFocus)?.removeListener(_onFocusChange);
    _ownedFocus?.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    final next = _effectiveFocus.hasFocus;
    if (next != _focused && mounted) {
      setState(() => _focused = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final ambientTier = resolveAmbientGlassTier(context);
    final isSolid = ambientTier == GrassBagGlassTier.solid;
    final baseFillColor = widget.insideGlass
        ? (t.isDark
            ? Colors.white.withValues(alpha: _focused ? 0.115 : 0.07)
            : Colors.white.withValues(alpha: _focused ? 0.88 : (isSolid ? 0.92 : 0.58)))
        : (t.isDark
            ? (isSolid ? t.cardSolid : t.cardSolid.withValues(alpha: 0.78))
            : Colors.white.withValues(alpha: _focused ? 0.92 : (isSolid ? 0.95 : 0.74)));
    final fillColor = widget.enabled
        ? baseFillColor
        : baseFillColor.withValues(alpha: baseFillColor.a * 0.65);
    final borderColor = widget.hasError
        ? t.err
        : (_focused
            ? t.primary.withValues(alpha: 0.78)
            : (t.isDark ? Colors.white.withValues(alpha: 0.16) : t.sepStrong));
    final resolvedStyle = widget.style ??
        TextStyle(
          fontSize: widget.fontSize,
          fontFamily: widget.monospace ? 'monospace' : null,
          height: widget.monospace ? 1.45 : 1.35,
          color: widget.enabled ? t.text : t.text3,
        );

    // Clean recessed borderless fill at rest + crisp focus/error ring (zero resting wireframe!)
    final restingBorderColor = isSolid
        ? (t.isDark ? Colors.white.withValues(alpha: 0.16) : t.sepStrong)
        : (t.isDark ? Colors.white.withValues(alpha: 0.08) : Colors.transparent);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      decoration: ShapeDecoration(
        color: fillColor,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
        shadows: _focused
            ? [
                BoxShadow(
                  color: (widget.hasError ? t.err : t.primary)
                      .withValues(alpha: isSolid ? 0.18 : (t.isDark ? 0.24 : 0.15)),
                  blurRadius: isSolid ? 6 : 10,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
      foregroundDecoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          side: BorderSide(
            color: (_focused || widget.hasError) ? borderColor : restingBorderColor,
            width: (_focused || widget.hasError) ? 1.2 : 0.65,
          ),
        ),
      ),
      child: CupertinoTextField(
        controller: widget.controller,
        focusNode: _effectiveFocus,
        placeholder: widget.placeholder,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        obscureText: widget.obscureText,
        autofocus: widget.autofocus,
        enabled: widget.enabled,
        readOnly: widget.readOnly,
        minLines: widget.minLines,
        maxLines: widget.obscureText ? 1 : widget.maxLines,
        cursorColor: t.primary,
        padding: widget.padding,
        prefix: widget.prefix,
        suffix: widget.suffix,
        style: resolvedStyle,
        contextMenuBuilder: buildGrassBagEditableContextMenu,
        placeholderStyle: TextStyle(
          fontSize: widget.fontSize,
          fontFamily: widget.monospace ? 'monospace' : null,
          color: t.text3,
        ),
        decoration: const BoxDecoration(color: Colors.transparent),
      ),
    );
  }
}

/// Sleek iOS 26 capsule progress bar replacing raw Material [LinearProgressIndicator]s.
/// Supports both determinate (`value` in `0.0..1.0`) with smooth fill interpolation and
/// indeterminate (`value == null`) with a quiet luminous sliding shimmer capsule.
class GrassBagProgressBar extends StatefulWidget {
  const GrassBagProgressBar({
    super.key,
    this.value,
    this.height = 5.0,
    this.color,
    this.trackColor,
  });

  final double? value;
  final double height;
  final Color? color;
  final Color? trackColor;

  @override
  State<GrassBagProgressBar> createState() => _GrassBagProgressBarState();
}

class _GrassBagProgressBarState extends State<GrassBagProgressBar>
    with SingleTickerProviderStateMixin {
  AnimationController? _indetCtrl;
  bool _routeCurrent = true;
  bool _animationsEnabled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final nextEnabled =
        !MediaQuery.disableAnimationsOf(context) && TickerMode.valuesOf(context).enabled;
    if (nextCurrent != _routeCurrent ||
        nextEnabled != _animationsEnabled ||
        (widget.value == null && _indetCtrl == null)) {
      _routeCurrent = nextCurrent;
      _animationsEnabled = nextEnabled;
      _syncIndeterminate();
    }
  }

  @override
  void didUpdateWidget(covariant GrassBagProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.value == null) != (widget.value == null)) {
      _syncIndeterminate();
    }
  }

  void _syncIndeterminate() {
    if (widget.value == null) {
      _indetCtrl ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1250),
      );
      if (WidgetsBinding.instance is WidgetsFlutterBinding &&
          _routeCurrent &&
          _animationsEnabled) {
        if (!_indetCtrl!.isAnimating) {
          _indetCtrl!.repeat();
        }
      } else if (_indetCtrl!.isAnimating) {
        _indetCtrl!.stop();
      }
    } else {
      _indetCtrl?.stop();
      _indetCtrl?.dispose();
      _indetCtrl = null;
    }
  }

  @override
  void dispose() {
    _indetCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final fillCol = widget.color ?? t.primary;
    final bgCol = widget.trackColor ?? t.fill2;

    final hasTrack = bgCol.a > 0.01;
    final trackBorderColor = t.isDark
        ? Colors.white.withValues(alpha: 0.11)
        : Colors.white.withValues(alpha: 0.72);

    if (widget.value == null && _indetCtrl != null) {
      final luminousHighlight =
          Color.lerp(fillCol, Colors.white, t.isDark ? 0.38 : 0.30)!;
      return RepaintBoundary(
        child: Container(
          height: widget.height,
          width: double.infinity,
          decoration: BoxDecoration(
            color: bgCol,
            borderRadius: BorderRadius.circular(999),
            border: hasTrack
                ? Border.all(color: trackBorderColor, width: 0.5)
                : null,
          ),
          clipBehavior: Clip.antiAlias,
          child: LayoutBuilder(
            builder: (ctx, box) {
              final w = box.maxWidth.isFinite ? box.maxWidth : 200.0;
              final barW = (w * 0.36).clamp(44.0, 148.0);
              final capsule = SizedBox(
                width: barW,
                height: widget.height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        fillCol.withValues(alpha: 0.0),
                        fillCol.withValues(alpha: 0.65),
                        luminousHighlight,
                        fillCol.withValues(alpha: 0.72),
                        fillCol.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.25, 0.56, 0.80, 1.0],
                    ),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              );
              return Align(
                alignment: Alignment.centerLeft,
                child: AnimatedBuilder(
                  animation: _indetCtrl!,
                  child: capsule,
                  builder: (_, child) {
                    final v = Curves.easeInOut.transform(_indetCtrl!.value);
                    final dx = -barW + (w + barW) * v;
                    return Transform.translate(
                      offset: Offset(dx, 0),
                      child: child,
                    );
                  },
                ),
              );
            },
          ),
        ),
      );
    }

    final clamped = (widget.value ?? 0.0).clamp(0.0, 1.0);
    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: bgCol,
        borderRadius: BorderRadius.circular(999),
        border: hasTrack
            ? Border.all(color: trackBorderColor, width: 0.5)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.centerLeft,
      child: AnimatedFractionallySizedBox(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        widthFactor: clamped,
        heightFactor: 1.0,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                fillCol,
                Color.lerp(fillCol, Colors.white, t.isDark ? 0.28 : 0.22)!,
              ],
            ),
            borderRadius: BorderRadius.circular(999),
            boxShadow: clamped > 0.02
                ? [
                    BoxShadow(
                      color: fillCol.withValues(alpha: t.isDark ? 0.42 : 0.28),
                      blurRadius: 6,
                      offset: const Offset(0, 0),
                    ),
                  ]
                : null,
          ),
        ),
      ),
    );
  }
}

enum GrassBagBannerTone { info, ok, warn, error }

/// Continuous `18pt` superellipse status/alert banner harmonized with GrassBag's OKLCH palette.
class GrassBagStatusBanner extends StatelessWidget {
  const GrassBagStatusBanner({
    super.key,
    required this.tone,
    required this.message,
    this.title,
    this.icon,
    this.trailing,
    this.action,
    this.borderRadius = 18,
    this.padding = const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
  });

  final GrassBagBannerTone tone;
  final String? title;
  final String message;
  final IconData? icon;
  final Widget? trailing;
  final Widget? action;
  final double borderRadius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final ambientTier = resolveAmbientGlassTier(context);
    final isSolid = ambientTier == GrassBagGlassTier.solid;
    final (accent, bg, defaultIcon) = switch (tone) {
      GrassBagBannerTone.ok => (t.ok, t.okSoft, CupertinoIcons.checkmark_circle_fill),
      GrassBagBannerTone.warn => (t.warn, t.warnSoft, CupertinoIcons.exclamationmark_circle_fill),
      GrassBagBannerTone.error => (t.err, t.errSoft, CupertinoIcons.exclamationmark_triangle_fill),
      GrassBagBannerTone.info => (t.primary, t.primarySoft, CupertinoIcons.info_circle_fill),
    };

    final bannerBox = Container(
      padding: padding,
      decoration: ShapeDecoration(
        color: isSolid ? bg : null,
        gradient: isSolid
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.lerp(
                    bg,
                    Colors.white.withValues(alpha: bg.a),
                    t.isDark ? 0.08 : 0.26,
                  )!,
                  bg,
                ],
              ),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(borderRadius),
          side: isSolid
              ? BorderSide(
                  color: accent.withValues(alpha: t.isDark ? 0.34 : 0.22),
                  width: 0.75,
                )
              : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              GrassBagSquircleIcon(
                icon: icon ?? defaultIcon,
                color: accent,
                size: 28,
                iconSize: 14.5,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title != null && title!.isNotEmpty)
                      Text(
                        title!,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.15,
                          color: t.text,
                        ),
                      ),
                    if (message.isNotEmpty) ...[
                      if (title != null && title!.isNotEmpty) const SizedBox(height: 2.5),
                      Text(
                        message,
                        style: TextStyle(
                          fontSize: 12.2,
                          height: 1.44,
                          color: (title != null && title!.isNotEmpty) ? t.text2 : t.text,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 10),
                trailing!,
              ],
            ],
          ),
          if (action != null) ...[
            const SizedBox(height: 10),
            action!,
          ],
        ],
      ),
    );

    return bannerBox;
  }
}

/// Canonical stadium filter/selection chip with spring haptics and consistent contrast
/// across all 6 OKLCH light & dark accents (including Graphite & Amber!).
class GrassBagFilterChip extends StatelessWidget {
  const GrassBagFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.showDot = false,
    this.dotColor,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6.5),
    this.fontSize = 12,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final bool showDot;
  final Color? dotColor;
  final EdgeInsetsGeometry padding;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final ambientTier = resolveAmbientGlassTier(context);
    final isSolid = ambientTier == GrassBagGlassTier.solid;
    final fg = selected ? t.onPrimary : t.text2;
    final animDur = GrassBagMotion.duration(context, const Duration(milliseconds: 170));
    final pillBody = AnimatedContainer(
      duration: animDur,
      curve: Curves.easeOutCubic,
      padding: padding,
      decoration: BoxDecoration(
        color: selected
            ? t.primary
            : (t.isDark
                ? Colors.white.withValues(alpha: isSolid ? 0.09 : 0.085)
                : const Color(0x11162E42)),
        borderRadius: BorderRadius.circular(999),
        border: isSolid
            ? Border.all(
                color: selected ? t.primary : t.sep,
                width: 0.65,
              )
            : null,
        boxShadow: selected && !isSolid
            ? [
                BoxShadow(
                  color: t.primary.withValues(alpha: t.isDark ? 0.28 : 0.20),
                  blurRadius: 8,
                  offset: const Offset(0, 2.5),
                ),
              ]
            : null,
      ),
      child: AnimatedSize(
        duration: animDur,
        curve: Curves.easeOutCubic,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              TweenAnimationBuilder<Color?>(
                duration: animDur,
                curve: Curves.easeOutCubic,
                tween: ColorTween(end: fg),
                builder: (_, col, __) => Icon(icon, size: fontSize + 1.5, color: col ?? fg),
              ),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: AnimatedDefaultTextStyle(
                duration: animDur,
                curve: Curves.easeOutCubic,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (showDot && !selected) ...[
              const SizedBox(width: 5),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: dotColor ?? t.warn,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return GrassBagSpringTap(
      onTap: onTap,
      pressedScale: 0.94,
      haptic: true,
      enablePointerGlow: false,
      child: pillBody,
    );
  }
}

// ---------------------------------------------------------------------------
// Apple iOS 26 Floating Liquid Glass Context Menus & Text Selection Toolbars
// ---------------------------------------------------------------------------

/// Single item inside [showGrassBagGlassContextMenu].
class GrassBagContextMenuItem {
  const GrassBagContextMenuItem({
    required this.label,
    required this.icon,
    required this.onTap,
    this.subtitle,
    this.destructive = false,
    this.selected = false,
    this.dividerBefore = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final String? subtitle;
  final bool destructive;
  final bool selected;
  final bool dividerBefore;
}

/// Anchored Apple iOS 26 floating Liquid Glass popup context menu with spring
/// scale-from-anchor animation, smart viewport edge clamping, and trailing Cupertino icons.
Future<void> showGrassBagGlassContextMenu(
  BuildContext context, {
  required List<GrassBagContextMenuItem> items,
  required GrassBagGlassTier tier,
  Offset? globalAnchor,
  String? headerTitle,
}) async {
  if (items.isEmpty) return;
  HapticFeedback.mediumImpact();
  final t = GrassBagTokens.of(context);
  final media = MediaQuery.of(context);
  final size = media.size;
  final safePad = media.padding;
  final effectiveBottom = math.max(safePad.bottom, media.viewInsets.bottom);
  final textScale = media.textScaler.scale(1.0).clamp(1.0, 1.6);
  const menuW = 228.0;
  final estH = ((headerTitle != null ? 36.0 : 0.0) +
          items.fold<double>(
            12.0,
            (acc, it) => acc + (it.subtitle != null ? 54.0 : 44.0) + (it.dividerBefore ? 7.0 : 0.0),
          )) *
      textScale;
  final availH = math.max(120.0, size.height - safePad.top - effectiveBottom - 24.0);
  final menuH = math.min(estH, availH);

  final rawAnchor = globalAnchor ?? Offset(size.width * 0.5, size.height * 0.45);
  final openRight = rawAnchor.dx + menuW + 14 <= size.width;
  final openDown = rawAnchor.dy + menuH + effectiveBottom + 18 <= size.height;

  final double left = (openRight ? rawAnchor.dx - 16 : rawAnchor.dx - menuW + 16)
      .clamp(12.0, math.max(12.0, size.width - menuW - 12.0));
  final double top = (rawAnchor.dy + 6).clamp(
    safePad.top + 12.0,
    math.max(safePad.top + 12.0, size.height - effectiveBottom - menuH - 12.0),
  );
  final double bottom = (size.height - rawAnchor.dy + 6).clamp(
    effectiveBottom + 12.0,
    math.max(effectiveBottom + 12.0, size.height - safePad.top - 120.0),
  );

  final alignX = ((rawAnchor.dx - left) / menuW * 2.0 - 1.0).clamp(-1.0, 1.0);
  final alignY = openDown ? -0.9 : 0.9;

  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭菜单',
    barrierColor: t.isDark ? const Color(0x4A06090F) : const Color(0x22101A28),
    transitionDuration: GrassBagMotion.duration(
      context,
      const Duration(milliseconds: 220),
      reduced: const Duration(milliseconds: 80),
    ),
    pageBuilder: (dialogCtx, anim, __) {
      final dt = GrassBagTokens.of(dialogCtx);
      return Stack(
        children: [
          Positioned(
            left: left,
            top: openDown ? top : null,
            bottom: openDown ? null : bottom,
            width: menuW,
            child: GrassBagMaterializeTransition(
              animation: anim,
              tier: tier,
              alignment: Alignment(alignX, alignY),
              scaleFrom: 0.86,
              contentSigma: 5.0,
              child: Material(
                type: MaterialType.transparency,
                child: GrassBagGlass(
                  tier: tier,
                  borderRadius: 22,
                  elevated: true,
                  useSheetSettings: true,
                  clipBehavior: Clip.antiAlias,
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: availH - 12.0),
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (headerTitle != null && headerTitle.trim().isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                              child: Text(
                                headerTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.1,
                                  color: dt.text3,
                                ),
                              ),
                            ),
                            Divider(height: 0.5, thickness: 0.5, indent: 8, endIndent: 8, color: dt.sep),
                          ],
                          for (var i = 0; i < items.length; i++) ...[
                            if (items[i].dividerBefore && i > 0)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 3),
                                child: Divider(height: 0.5, thickness: 0.5, indent: 8, endIndent: 8, color: dt.sep),
                              ),
                            _GrassBagContextMenuRow(
                              item: items[i],
                              onSelect: () {
                                Navigator.of(dialogCtx).pop();
                                items[i].onTap();
                              },
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
        ],
      );
    },
    transitionBuilder: (_, __, ___, child) => child,
  );
}

class _GrassBagContextMenuRow extends StatefulWidget {
  const _GrassBagContextMenuRow({
    required this.item,
    required this.onSelect,
  });

  final GrassBagContextMenuItem item;
  final VoidCallback onSelect;

  @override
  State<_GrassBagContextMenuRow> createState() => _GrassBagContextMenuRowState();
}

class _GrassBagContextMenuRowState extends State<_GrassBagContextMenuRow> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final item = widget.item;
    final fg = item.destructive
        ? t.err
        : (item.selected ? t.primary : t.text);
    final bg = _pressed
        ? (item.destructive
            ? t.err.withValues(alpha: t.isDark ? 0.22 : 0.12)
            : (t.isDark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.06)))
        : (item.selected
            ? t.primary.withValues(alpha: t.isDark ? 0.16 : 0.09)
            : (_hovered
                ? (t.isDark ? Colors.white.withValues(alpha: 0.07) : Colors.black.withValues(alpha: 0.035))
                : Colors.transparent));

    return Semantics(
      button: true,
      selected: item.selected,
      label: item.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: () {
            HapticFeedback.selectionClick();
            widget.onSelect();
          },
          child: AnimatedScale(
            scale: _pressed && !MediaQuery.disableAnimationsOf(context) ? 0.98 : 1.0,
            duration: GrassBagMotion.duration(context, const Duration(milliseconds: 110)),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: GrassBagMotion.duration(context, const Duration(milliseconds: 110)),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
              decoration: ShapeDecoration(
                color: bg,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: item.selected
                        ? t.primary.withValues(alpha: t.isDark ? 0.32 : 0.22)
                        : Colors.transparent,
                    width: 0.65,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(item.icon, size: 17, color: fg.withValues(alpha: 0.92)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: item.selected || item.destructive ? FontWeight.w600 : FontWeight.w500,
                            letterSpacing: -0.15,
                            color: fg,
                          ),
                        ),
                        if (item.subtitle != null && item.subtitle!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 1.5),
                            child: Text(
                              item.subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: t.text3),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (item.selected) ...[
                    const SizedBox(width: 8),
                    Icon(CupertinoIcons.checkmark_alt, size: 15, color: t.primary),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating Apple iOS 26 Liquid Glass horizontal text selection toolbar for `TextField` /
/// `CupertinoTextField` (replaces plain gray Material / Cupertino popup menus!).
Widget buildGrassBagEditableContextMenu(
  BuildContext context,
  EditableTextState editableTextState,
) {
  return _GrassBagGlassSelectionToolbar(
    anchors: editableTextState.contextMenuAnchors,
    buttonItems: editableTextState.contextMenuButtonItems,
  );
}

/// Floating Apple iOS 26 Liquid Glass horizontal text selection toolbar for `SelectionArea`.
Widget buildGrassBagSelectableContextMenu(
  BuildContext context,
  SelectableRegionState selectableRegionState,
) {
  return _GrassBagGlassSelectionToolbar(
    anchors: selectableRegionState.contextMenuAnchors,
    buttonItems: selectableRegionState.contextMenuButtonItems,
  );
}

/// SelectionArea context menu with an extra `"引用回复"` action that extracts the
/// selected excerpt into the composer as a Markdown blockquote (`> excerpt\n\n`).
/// When [getSelectedText] is supplied (fed by `SelectionArea.onSelectionChanged`),
/// extraction is synchronous and NEVER touches the system clipboard!
Widget Function(BuildContext, SelectableRegionState)
    buildGrassBagSelectableContextMenuWithQuote({
  required ValueChanged<String> onQuoteSelectedText,
  String Function()? getSelectedText,
}) {
  return (BuildContext context, SelectableRegionState selectableRegionState) {
    final baseItems = List<ContextMenuButtonItem>.of(
      selectableRegionState.contextMenuButtonItems,
    );
    final copyItem = baseItems
        .where((b) => b.type == ContextMenuButtonType.copy && b.onPressed != null)
        .firstOrNull;
    final quoteItem = ContextMenuButtonItem(
      label: '引用回复',
      onPressed: () {
        final directText = getSelectedText?.call().trim() ?? '';
        if (directText.isNotEmpty) {
          selectableRegionState.clearSelection();
          selectableRegionState.hideToolbar();
          onQuoteSelectedText(directText);
          return;
        }
        final prevClipFuture = Clipboard.getData(Clipboard.kTextPlain);
        copyItem?.onPressed?.call();
        selectableRegionState.hideToolbar();
        unawaited(() async {
          final prevText = (await prevClipFuture)?.text;
          await Future<void>.delayed(const Duration(milliseconds: 28));
          final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
          if (prevText != null && prevText != copied) {
            unawaited(Clipboard.setData(ClipboardData(text: prevText)));
          }
          if (copied.isNotEmpty) {
            onQuoteSelectedText(copied);
          }
        }());
      },
    );
    // Insert right after Copy (index 1) or at the start so it's immediately reachable
    final insertIdx = baseItems.isNotEmpty ? 1 : 0;
    baseItems.insert(insertIdx, quoteItem);
    return _GrassBagGlassSelectionToolbar(
      anchors: selectableRegionState.contextMenuAnchors,
      buttonItems: baseItems,
    );
  };
}

class _GrassBagGlassSelectionToolbar extends StatefulWidget {
  const _GrassBagGlassSelectionToolbar({
    required this.anchors,
    required this.buttonItems,
  });

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;

  @override
  State<_GrassBagGlassSelectionToolbar> createState() => _GrassBagGlassSelectionToolbarState();
}

class _GrassBagGlassSelectionToolbarState extends State<_GrassBagGlassSelectionToolbar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 190),
    )..forward();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  static (String, IconData?) _labelAndIcon(ContextMenuButtonItem item) {
    final custom = item.label?.trim();
    return switch (item.type) {
      ContextMenuButtonType.cut => ('剪切', CupertinoIcons.scissors),
      ContextMenuButtonType.copy => ('复制', CupertinoIcons.doc_on_doc),
      ContextMenuButtonType.paste => ('粘贴', CupertinoIcons.doc_on_clipboard),
      ContextMenuButtonType.selectAll => ('全选', CupertinoIcons.selection_pin_in_out),
      ContextMenuButtonType.delete => ('删除', CupertinoIcons.trash),
      ContextMenuButtonType.share => ('分享', CupertinoIcons.share),
      ContextMenuButtonType.lookUp => ('查询', CupertinoIcons.search),
      ContextMenuButtonType.searchWeb => ('搜索', CupertinoIcons.globe),
      ContextMenuButtonType.liveTextInput => ('文本识别', CupertinoIcons.viewfinder),
      ContextMenuButtonType.custom => (custom?.isNotEmpty == true ? custom! : '操作', null),
    };
  }

  @override
  Widget build(BuildContext context) {
    if (widget.buttonItems.isEmpty) return const SizedBox.shrink();
    final t = GrassBagTokens.of(context);
    final safeTop = MediaQuery.paddingOf(context).top + 8.0;
    final anchorAbove = Offset(
      widget.anchors.primaryAnchor.dx,
      math.max(safeTop, widget.anchors.primaryAnchor.dy - 10.0),
    );
    final anchorBelow = (widget.anchors.secondaryAnchor ?? widget.anchors.primaryAnchor) +
        const Offset(0, 14.0);

    final tier = resolveAmbientGlassTier(context);

    final toolbar = Material(
      type: MaterialType.transparency,
      child: GrassBagGlass(
        tier: tier,
        borderRadius: 999,
        elevated: true,
        interactiveGlow: false,
        useSheetSettings: false,
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < widget.buttonItems.length; i++) ...[
                  if (i > 0)
                    Container(
                      width: 0.6,
                      height: 18,
                      color: t.sep,
                    ),
                  _ToolbarActionPillItem(
                    label: _labelAndIcon(widget.buttonItems[i]).$1,
                    icon: _labelAndIcon(widget.buttonItems[i]).$2,
                    onPressed: widget.buttonItems[i].onPressed,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    return CustomSingleChildLayout(
      delegate: TextSelectionToolbarLayoutDelegate(
        anchorAbove: anchorAbove,
        anchorBelow: anchorBelow,
      ),
      child: GrassBagMaterializeTransition(
        animation: _animCtrl,
        tier: tier,
        scaleFrom: 0.90,
        contentSigma: 4.0,
        child: toolbar,
      ),
    );
  }
}

class _ToolbarActionPillItem extends StatelessWidget {
  const _ToolbarActionPillItem({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagSpringTap(
      onTap: () {
        HapticFeedback.selectionClick();
        onPressed?.call();
      },
      pressedScale: 0.92,
      enablePointerGlow: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13.5, color: t.primary),
              const SizedBox(width: 4.5),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.15,
                color: t.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Crisp iOS 26 directional tab/subpage micro-transition (`175ms` fade + `±3%` horizontal slide).
/// Owns & disposes its [CurvedAnimation]s per child so switching tabs/views never leaks listeners.
class GrassBagDirectionalTabSwitcher extends StatefulWidget {
  const GrassBagDirectionalTabSwitcher({
    super.key,
    required this.child,
    this.direction = 1,
    this.duration = const Duration(milliseconds: 175),
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final int direction;
  final Duration duration;
  final AlignmentGeometry alignment;

  @override
  State<GrassBagDirectionalTabSwitcher> createState() =>
      _GrassBagDirectionalTabSwitcherState();
}

class _GrassBagDirectionalTabSwitcherState
    extends State<GrassBagDirectionalTabSwitcher> {
  late final ValueNotifier<int> _liveDir = ValueNotifier<int>(widget.direction);

  @override
  void didUpdateWidget(covariant GrassBagDirectionalTabSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.direction != widget.direction) {
      _liveDir.value = widget.direction;
    }
  }

  @override
  void dispose() {
    _liveDir.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduceMotion ? const Duration(milliseconds: 80) : widget.duration,
      reverseDuration:
          reduceMotion ? const Duration(milliseconds: 60) : const Duration(milliseconds: 140),
      switchInCurve: Curves.linear,
      switchOutCurve: Curves.linear,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: widget.alignment,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      transitionBuilder: (w, anim) => _DirectionalSlideFadeTransition(
        animation: anim,
        directionNotifier: _liveDir,
        reduceMotion: reduceMotion,
        child: w,
      ),
      child: widget.child,
    );
  }
}

class _DirectionalSlideFadeTransition extends StatefulWidget {
  const _DirectionalSlideFadeTransition({
    required this.animation,
    required this.directionNotifier,
    required this.reduceMotion,
    required this.child,
  });

  final Animation<double> animation;
  final ValueNotifier<int> directionNotifier;
  final bool reduceMotion;
  final Widget child;

  @override
  State<_DirectionalSlideFadeTransition> createState() =>
      _DirectionalSlideFadeTransitionState();
}

class _DirectionalSlideFadeTransitionState
    extends State<_DirectionalSlideFadeTransition> {
  late CurvedAnimation _fadeCurve;
  late CurvedAnimation _slideCurve;

  void _init() {
    _fadeCurve = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );
    _slideCurve = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant _DirectionalSlideFadeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _fadeCurve.dispose();
      _slideCurve.dispose();
      _init();
    }
  }

  @override
  void dispose() {
    _fadeCurve.dispose();
    _slideCurve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animation,
      child: widget.child,
      builder: (context, child) {
        final fade = _fadeCurve.value.clamp(0.0, 1.0);
        final dir = widget.reduceMotion ? 0 : widget.directionNotifier.value;
        if (dir == 0) {
          return GrassBagControlledOpacity(opacity: fade, child: child!);
        }
        // Read live direction + animation.status on EVERY tick so rapid 0->1->0
        // tab reversals slide outgoing tabs cleanly in the latest direction!
        final isOutgoing = widget.animation.status == AnimationStatus.reverse;
        final dx = (dir >= 0 ? 0.03 : -0.03) * (isOutgoing ? -1.0 : 1.0);
        final offsetX = dx * (1.0 - _slideCurve.value);
        return GrassBagControlledOpacity(
          opacity: fade,
          child: FractionalTranslation(
            translation: Offset(offsetX, 0),
            child: child,
          ),
        );
      },
    );
  }
}

/// Zero-`OpacityLayer` opacity widget at rest: when `opacity >= 0.999`, skips
/// `pushOpacity` and `alwaysNeedsCompositing` completely so resting widgets/glass
/// keep ZERO offscreen compositing layers (unlike `FadeTransition`!).
class GrassBagControlledOpacity extends SingleChildRenderObjectWidget {
  const GrassBagControlledOpacity({
    super.key,
    required this.opacity,
    super.child,
  });

  final double opacity;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderGrassBagControlledOpacity(opacity: opacity);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderGrassBagControlledOpacity).opacity = opacity;
  }
}

class _RenderGrassBagControlledOpacity extends RenderProxyBox {
  _RenderGrassBagControlledOpacity({required double opacity})
      : _opacity = opacity.clamp(0.0, 1.0);

  double _opacity;
  double get opacity => _opacity;
  set opacity(double value) {
    final next = value.clamp(0.0, 1.0);
    if ((_opacity - next).abs() < 0.0005) return;
    final prevCompositing = alwaysNeedsCompositing;
    final prevSemanticsVisible = _opacity > 0.001;
    _opacity = next;
    if (prevCompositing != alwaysNeedsCompositing) {
      markNeedsCompositingBitsUpdate();
    }
    if (prevSemanticsVisible != (_opacity > 0.001)) {
      markNeedsSemanticsUpdate();
    }
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => _opacity > 0.0 && _opacity < 0.999;

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_opacity > 0.001) {
      super.visitChildrenForSemantics(visitor);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || _opacity <= 0.001) {
      layer = null;
      return;
    }
    if (_opacity >= 0.999) {
      layer = null;
      context.paintChild(child!, offset);
      return;
    }
    layer = context.pushOpacity(
      offset,
      (_opacity * 255.0).round().clamp(0, 255),
      super.paint,
      oldLayer: layer as OpacityLayer?,
    );
  }
}

/// Route-aware Cupertino activity indicator that automatically pauses its ticker
/// whenever its enclosing route is covered or Reduce Motion is active.
class GrassBagActivityIndicator extends StatelessWidget {
  const GrassBagActivityIndicator({
    super.key,
    this.radius = 10.0,
    this.color,
    this.animating = true,
  });

  final double radius;
  final Color? color;
  final bool animating;

  @override
  Widget build(BuildContext context) {
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final motionAllowed = !MediaQuery.disableAnimationsOf(context);
    return RepaintBoundary(
      child: CupertinoActivityIndicator(
        radius: radius,
        color: color,
        animating: animating && isCurrent && motionAllowed,
      ),
    );
  }
}

/// Subtle, `RepaintBoundary`-isolated Apple Intelligence / iOS 26 shimmer text for active
/// thinking, waiting, and tool-execution headers. Automatically pauses when off-route,
/// when reduced-motion is active, or inside deterministic widget tests.
class GrassBagShimmerText extends StatefulWidget {
  const GrassBagShimmerText(
    this.text, {
    super.key,
    required this.style,
    this.highlightColor,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
    this.enabled = true,
  });

  final String text;
  final TextStyle style;
  final Color? highlightColor;
  final int maxLines;
  final TextOverflow overflow;
  final bool enabled;

  @override
  State<GrassBagShimmerText> createState() => _GrassBagShimmerTextState();
}

class _GrassBagShimmerTextState extends State<GrassBagShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1750),
    );
  }

  void _syncAnim() {
    final shouldRun = widget.enabled &&
        WidgetsBinding.instance is WidgetsFlutterBinding &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        !MediaQuery.disableAnimationsOf(context);
    if (shouldRun && !_running) {
      _running = true;
      _ctrl.repeat();
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
  void didUpdateWidget(covariant GrassBagShimmerText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      _syncAnim();
    }
  }

  @override
  void dispose() {
    _measureTp?.dispose();
    _measureTp = null;
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final baseColor = widget.style.color ?? t.text2;
    final hiColor = widget.highlightColor ?? (t.isDark ? Colors.white : t.text);
    if (!_running) {
      return Text(
        widget.text,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
        style: widget.style,
      );
    }
    // Paint shimmer via a cached TextPainter inside CustomPainter(repaint: _ctrl) so
    // Zero-saveLayer, leak-free 1-pass shimmer: reuses a single Paint shader and disposes
    // cached TextPainter cleanly on unmount, eliminating 120Hz offscreen render passes!
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final defaultStyle = DefaultTextStyle.of(context).style;
    final effectiveStyle = defaultStyle.merge(widget.style);
    return Semantics(
      label: widget.text,
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (ctx, box) {
            final maxW = box.maxWidth.isFinite && box.maxWidth > 1.0
                ? box.maxWidth
                : double.infinity;
            final measureTp = _ensureMeasurePainter(
              text: widget.text,
              style: effectiveStyle,
              maxLines: widget.maxLines,
              ellipsis: widget.overflow == TextOverflow.ellipsis ? '…' : null,
              textDirection: textDirection,
              textScaler: textScaler,
              maxW: maxW,
            );
            final size = Size(
              measureTp.width.clamp(1.0, maxW.isFinite ? maxW : measureTp.width.clamp(1.0, 2048.0)),
              measureTp.height.clamp(1.0, 256.0),
            );
            return SizedBox(
              width: size.width,
              height: size.height,
              child: CustomPaint(
                size: size,
                painter: _GrassBagShimmerTextPainter(
                  animation: _ctrl,
                  textPainter: measureTp,
                  baseColor: baseColor,
                  hiColor: hiColor,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  TextPainter? _measureTp;
  String? _measureSig;

  TextPainter _ensureMeasurePainter({
    required String text,
    required TextStyle style,
    required int maxLines,
    required String? ellipsis,
    required TextDirection textDirection,
    required TextScaler textScaler,
    required double maxW,
  }) {
    final sig = '$text|${style.fontSize}|${style.fontWeight}|${style.height}|$maxLines|$ellipsis|${textScaler.scale(14).toStringAsFixed(2)}|${maxW.isFinite ? maxW.round() : -1}';
    if (_measureTp != null && _measureSig == sig) {
      return _measureTp!;
    }
    _measureTp?.dispose();
    _measureSig = sig;
    _measureTp = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: maxLines,
      ellipsis: ellipsis,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: maxW);
    return _measureTp!;
  }
}

class _GrassBagShimmerTextPainter extends CustomPainter {
  _GrassBagShimmerTextPainter({
    required this.animation,
    required this.textPainter,
    required this.baseColor,
    required this.hiColor,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final TextPainter textPainter;
  final Color baseColor;
  final Color hiColor;

  final Paint _maskPaint = Paint()..blendMode = BlendMode.srcIn;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final slide = -0.6 + animation.value * 2.2;
    _maskPaint.shader = LinearGradient(
      begin: Alignment(slide - 0.55, 0),
      end: Alignment(slide + 0.55, 0),
      colors: [baseColor, hiColor, baseColor],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(rect);
    canvas.saveLayer(rect, Paint());
    textPainter.paint(canvas, Offset.zero);
    canvas.drawRect(rect, _maskPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GrassBagShimmerTextPainter oldDelegate) =>
      oldDelegate.textPainter != textPainter ||
      oldDelegate.baseColor != baseColor ||
      oldDelegate.hiColor != hiColor ||
      oldDelegate.animation != animation;
}

// ---------------------------------------------------------------------------
// Canonical iOS 26 / 27 Motion Tokens, Smooth Disclosures & Micro-Morphs
// ---------------------------------------------------------------------------

/// Canonical physics, durations, curves, and reduced-motion resolver for GrassBag.
abstract final class GrassBagMotion {
  static const Duration microDuration = Duration(milliseconds: 120);
  static const Duration quickDuration = Duration(milliseconds: 170);
  static const Duration standardDuration = Duration(milliseconds: 220);
  static const Duration disclosureDuration = Duration(milliseconds: 230);
  static const Duration panelDuration = Duration(milliseconds: 270);

  static const Curve easeOut = Curves.easeOutCubic;
  static const Curve easeIn = Curves.easeInCubic;
  static const Curve easeInOut = Curves.easeInOutCubic;

  static final SpringDescription pressSpring =
      GlassSpring.smooth(duration: const Duration(milliseconds: 120));
  static final SpringDescription releaseSpring = GlassSpring.interactive(
    duration: const Duration(milliseconds: 250),
    extraBounce: 0.10,
  );
  static final SpringDescription popoverSpring = GlassSpring.snappy(
    duration: const Duration(milliseconds: 280),
  );
  static final SpringDescription sheetSpring = GlassSpring.smooth(
    duration: const Duration(milliseconds: 340),
  );
  static final SpringDescription drawerSpring = GlassSpring.smooth(
    duration: const Duration(milliseconds: 260),
  );

  /// Whether OS Reduce Motion / Disable Animations is active.
  static bool reduceMotion(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// Returns [reduced] (defaults to `Duration.zero`) when OS Reduce Motion is active.
  static Duration duration(
    BuildContext context,
    Duration normal, {
    Duration reduced = Duration.zero,
  }) {
    return reduceMotion(context) ? reduced : normal;
  }
}

/// Toggle-only smooth expand/collapse disclosure (`SizeTransition` + `FadeTransition`).
/// Unlike `AnimatedSize`, it only animates when [expanded] changes — so dynamic live
/// children (streaming logs, thinking text, tool output) grow smoothly without
/// triggering rubber-band size re-animations!
class GrassBagSmoothDisclosure extends StatefulWidget {
  const GrassBagSmoothDisclosure({
    super.key,
    required this.expanded,
    required this.child,
    this.duration = GrassBagMotion.disclosureDuration,
    this.reverseDuration = const Duration(milliseconds: 185),
    this.axis = Axis.vertical,
    this.axisAlignment = -1.0,
    this.fade = true,
  });

  final bool expanded;
  final Widget child;
  final Duration duration;
  final Duration reverseDuration;
  final Axis axis;
  final double axisAlignment;
  final bool fade;

  @override
  State<GrassBagSmoothDisclosure> createState() => _GrassBagSmoothDisclosureState();
}

class _GrassBagSmoothDisclosureState extends State<GrassBagSmoothDisclosure>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late CurvedAnimation _sizeCurve;
  late CurvedAnimation _fadeCurve;
  bool _mountedChild = false;

  @override
  void initState() {
    super.initState();
    _mountedChild = widget.expanded;
    _ctrl = AnimationController(
      vsync: this,
      value: widget.expanded ? 1.0 : 0.0,
      duration: widget.duration,
      reverseDuration: widget.reverseDuration,
    )..addStatusListener(_onStatus);
    _sizeCurve = CurvedAnimation(
      parent: _ctrl,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _fadeCurve = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.08, 1.0, curve: Curves.easeOut),
      reverseCurve: const Interval(0.0, 0.72, curve: Curves.easeIn),
    );
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.expanded && _mountedChild) {
      if (mounted) setState(() => _mountedChild = false);
    }
  }

  @override
  void didUpdateWidget(covariant GrassBagSmoothDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _ctrl.duration = widget.duration;
    }
    if (oldWidget.reverseDuration != widget.reverseDuration) {
      _ctrl.reverseDuration = widget.reverseDuration;
    }
    if (oldWidget.expanded != widget.expanded) {
      final reduceMotion = mounted && MediaQuery.disableAnimationsOf(context);
      if (widget.expanded) {
        if (!_mountedChild) _mountedChild = true;
        if (reduceMotion) {
          _ctrl.value = 1.0;
        } else {
          _ctrl.forward();
        }
      } else {
        if (reduceMotion) {
          _ctrl.value = 0.0;
          _mountedChild = false;
        } else {
          _ctrl.reverse();
        }
      }
    }
  }

  @override
  void dispose() {
    _ctrl.removeStatusListener(_onStatus);
    _sizeCurve.dispose();
    _fadeCurve.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_mountedChild && !widget.expanded && _ctrl.isDismissed) {
      return const SizedBox.shrink();
    }
    Widget content = widget.child;
    if (widget.fade) {
      content = AnimatedBuilder(
        animation: _fadeCurve,
        child: content,
        builder: (_, child) =>
            GrassBagControlledOpacity(opacity: _fadeCurve.value, child: child),
      );
    }
    return ClipRect(
      child: SizeTransition(
        axis: widget.axis,
        axisAlignment: widget.axisAlignment,
        sizeFactor: _sizeCurve,
        child: content,
      ),
    );
  }
}

/// Crisp iOS 26 scale+fade morph between a copy icon and a confirmed checkmark.
class GrassBagCopyMorphIcon extends StatelessWidget {
  const GrassBagCopyMorphIcon({
    super.key,
    required this.copied,
    required this.color,
    this.copiedColor,
    this.size = 13.5,
    this.idleIcon = CupertinoIcons.doc_on_doc,
    this.copiedIcon = CupertinoIcons.checkmark_alt,
  });

  final bool copied;
  final Color color;
  final Color? copiedColor;
  final double size;
  final IconData idleIcon;
  final IconData copiedIcon;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
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
      child: Icon(
        copied ? copiedIcon : idleIcon,
        key: ValueKey(copied),
        size: size,
        color: copied ? (copiedColor ?? color) : color,
      ),
    );
  }
}
