import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'grassbag_theme.dart';

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
  /// Default global Liquid Glass refraction & chromatic dispersion intensity (`0.0..1.0`).
  /// `0.0` = clean refraction with zero RGB fringing; `0.50` = Apple iOS 27 calibrated baseline;
  /// `1.0` = vivid prismatic refraction & chromatic dispersion across all floating chrome.
  static const double defaultOpticalStrength = 0.50;

  /// Maps user-facing optical strength (`0.0..1.0`) onto shader `chromaticAberration` so:
  /// - `0.0` cleanly disables RGB channel splitting (`0.0`)
  /// - `0.5` preserves the exact calibrated iOS 27 default (`atDefault`)
  /// - `1.0` opens up rich prismatic corner/edge dispersion (`atMax`)
  static double scaleChromatic(
    double opticalStrength,
    double atDefault,
    double atMax,
  ) {
    final s = opticalStrength.clamp(0.0, 1.0);
    if (s <= 0.001) return 0.0;
    if (s <= defaultOpticalStrength) {
      return atDefault * (s / defaultOpticalStrength);
    }
    return atDefault +
        (atMax - atDefault) *
            ((s - defaultOpticalStrength) / (1.0 - defaultOpticalStrength));
  }

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

  /// Calibrated Apple iOS 27 `GlassLensModel.spherical` Liquid Glass for floating chrome
  /// (top nav pills, title capsule, floating composer, toasts), scaled by [opticalStrength].
  static LiquidGlassSettings surfaceSettings(
    GrassBagTokens t,
    GrassBagGlassTier tier, {
    bool elevated = false,
    double opticalStrength = defaultOpticalStrength,
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

    final s = opticalStrength.clamp(0.0, 1.0);
    final thickness = 22.0 + 16.0 * s;

    if (t.isDark) {
      return LiquidGlassSettings(
        glassColor: Colors.white.withValues(alpha: elevated ? 0.08 : 0.055),
        blur: 1.4,
        frost: 0.0,
        frostOpacity: 0.0,
        thickness: thickness,
        refractiveIndex: 1.22 + 0.24 * s,
        lensModel: GlassLensModel.spherical,
        chromaticAberration: scaleChromatic(s, 0.14, 0.68),
        saturation: 1.58,
        lightAngle: 0.75 * math.pi,
        lightIntensity: 0.70,
        ambientStrength: 0.12,
        ambientRim: 0.0,
        fresnelStrength: 0.95,
        edgeAbsorption: 0.032,
        rimShade: 0.0,
        rimLight: 0.86,
        bodyShade: elevated ? 0.06 : 0.03,
        specularSharpness: GlassSpecularSharpness.sharp,
        shadow: const [],
      );
    }

    return LiquidGlassSettings(
      glassColor: Colors.white.withValues(alpha: elevated ? 0.14 : 0.08),
      blur: 1.4,
      frost: 0.0,
      frostOpacity: 0.0,
      thickness: thickness,
      refractiveIndex: 1.20 + 0.24 * s,
      lensModel: GlassLensModel.spherical,
      chromaticAberration: scaleChromatic(s, 0.12, 0.62),
      saturation: 1.80,
      lightAngle: 0.75 * math.pi,
      lightIntensity: 0.72,
      ambientStrength: 0.10,
      ambientRim: 0.0,
      fresnelStrength: 0.96,
      whitenStrength: 0.0,
      whitenGated: true,
      edgeAbsorption: 0.025,
      rimShade: 0.0,
      rimLight: 0.88,
      bodyShade: 0.0,
      specularSharpness: GlassSpecularSharpness.sharp,
      shadow: [
        BoxShadow(
          color: const Color(0x120E1F33),
          blurRadius: elevated ? 20 : 14,
          offset: Offset(0, elevated ? 7 : 4),
        ),
      ],
    );
  }

  /// Crystal-clear Apple iOS 27 modal sheet, '+' deck, alert platter, context menu & drawer glass:
  /// silky optical bokeh (`7.2dp` sheets / `9.5dp` centered dialogs, zero milky opaque frost wall!)
  /// + spherical curved edge refraction + chromatic dispersion scaled by [opticalStrength].
  static LiquidGlassSettings sheetSettings(
    GrassBagTokens t,
    GrassBagGlassTier tier, {
    bool isDialog = false,
    double opticalStrength = defaultOpticalStrength,
  }) {
    final base = surfaceSettings(
      t,
      tier,
      elevated: true,
      opticalStrength: opticalStrength,
    );
    if (tier == GrassBagGlassTier.solid) {
      return base;
    }
    if (tier != GrassBagGlassTier.liquid || kIsWeb) {
      return base.copyWith(
        glassColor: t.isDark
            ? Colors.white.withValues(alpha: isDialog ? 0.16 : 0.14)
            : Colors.white.withValues(alpha: isDialog ? 0.64 : 0.56),
        blur: kIsWeb ? 9.5 : (isDialog ? 10.5 : 8.5),
        frost: 0.0,
        frostOpacity: 0.0,
        thickness: 1.0,
        refractiveIndex: 1.01,
        lensModel: GlassLensModel.spherical,
        saturation: 1.0,
        lightIntensity: 0.0,
        rimLight: t.isDark ? 0.34 : 0.42,
        rimShade: 0.0,
        ambientRim: 0.0,
        chromaticAberration: 0.0,
        bodyShade: t.isDark ? 0.18 : 0.0,
      );
    }
    final s = opticalStrength.clamp(0.0, 1.0);
    return base.copyWith(
      glassColor: t.isDark
          ? Colors.white.withValues(alpha: isDialog ? 0.13 : 0.11)
          : Colors.white.withValues(alpha: isDialog ? 0.46 : 0.36),
      blur: isDialog ? (t.isDark ? 9.0 : 10.0) : 7.2,
      frost: 0.0,
      frostOpacity: 0.0,
      thickness: 24.0 + 16.0 * s,
      refractiveIndex: 1.18 + 0.20 * s,
      lensModel: GlassLensModel.spherical,
      chromaticAberration: scaleChromatic(s, 0.09, 0.48),
      saturation: t.isDark ? 1.52 : 1.72,
      bodyShade: t.isDark ? (isDialog ? 0.16 : 0.12) : 0.0,
      whitenStrength: t.isDark ? 0.0 : (isDialog ? 0.06 : 0.04),
      whitenGated: true,
      lightAngle: 0.75 * math.pi,
      lightIntensity: 0.68,
      ambientStrength: t.isDark ? 0.12 : 0.10,
      ambientRim: 0.0,
      fresnelStrength: t.isDark ? 0.92 : 0.90,
      edgeAbsorption: t.isDark ? 0.028 : 0.024,
      rimLight: 0.84,
      rimShade: 0.0,
      specularSharpness: GlassSpecularSharpness.sharp,
      shadow: t.isDark
          ? const []
          : const [
              BoxShadow(
                color: Color(0x180E1F33),
                blurRadius: 22,
                offset: Offset(0, 8),
              ),
            ],
    );
  }

  /// Pure optical crystal prism lens preset for interactive optical showcases
  /// (Appearance Studio draggable lens capsule) — crisp spherical refraction + chromatic dispersion.
  static LiquidGlassSettings prismLensSettings(
    GrassBagTokens t,
    GrassBagGlassTier tier, {
    double opticalStrength = defaultOpticalStrength,
  }) {
    if (tier != GrassBagGlassTier.liquid || kIsWeb) {
      return surfaceSettings(t, tier, opticalStrength: opticalStrength);
    }
    final s = opticalStrength.clamp(0.0, 1.0);
    return LiquidGlassSettings(
      glassColor: Colors.white.withValues(alpha: t.isDark ? 0.06 : 0.10),
      blur: 0.8,
      frost: 0.0,
      frostOpacity: 0.0,
      thickness: 20.0 + 18.0 * s,
      refractiveIndex: 1.22 + 0.28 * s,
      lensModel: GlassLensModel.spherical,
      chromaticAberration: scaleChromatic(s, 0.18, 0.85),
      saturation: t.isDark ? 1.55 : 1.75,
      lightAngle: 0.75 * math.pi,
      lightIntensity: 0.78,
      ambientStrength: 0.10,
      ambientRim: 0.0,
      fresnelStrength: 1.05,
      edgeAbsorption: 0.024,
      rimShade: 0.0,
      rimLight: 0.92,
      bodyShade: t.isDark ? 0.04 : 0.0,
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
    GrassBagGlassTier tier, {
    double opticalStrength = defaultOpticalStrength,
  }) {
    if (tier == GrassBagGlassTier.solid) {
      return const GlassThemeData(
        style: GlassStyle.ios27,
        light: GlassThemeVariant.minimalLight,
        dark: GlassThemeVariant.minimalDark,
      );
    }

    final isFrosted = tier == GrassBagGlassTier.frosted || kIsWeb;
    final s = opticalStrength.clamp(0.0, 1.0);
    final lightSurf = surfaceSettings(
      lightTokens,
      tier,
      opticalStrength: s,
    );
    final darkSurf = surfaceSettings(
      darkTokens,
      tier,
      opticalStrength: s,
    );
    final indicatorTheme = isFrosted
        ? null
        : GlassThemeSettings(
            refractiveIndex: 1.20 + 0.24 * s,
            chromaticAberration: scaleChromatic(s, 0.14, 0.60),
            lightIntensity: 0.55,
            ambientStrength: 0.10,
            fresnelStrength: 0.85,
            rimLight: 1.0,
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

/// Explicit inherited scope carrying the active [GrassBagGlassTier] and user-tuned
/// [opticalStrength] (`0.0..1.0`) so every Liquid Glass surface, button, sheet, menu,
/// and interactive droplet lens updates live globally!
class GrassBagGlassTierScope extends InheritedWidget {
  const GrassBagGlassTierScope({
    super.key,
    required this.tier,
    this.opticalStrength = GrassBagGlassConfig.defaultOpticalStrength,
    required super.child,
  });

  final GrassBagGlassTier tier;
  final double opticalStrength;

  static GrassBagGlassTier? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<GrassBagGlassTierScope>()
        ?.tier;
  }

  static double opticalStrengthOf(BuildContext context) {
    final v = context
        .dependOnInheritedWidgetOfExactType<GrassBagGlassTierScope>()
        ?.opticalStrength;
    return (v ?? GrassBagGlassConfig.defaultOpticalStrength).clamp(0.0, 1.0);
  }

  @override
  bool updateShouldNotify(GrassBagGlassTierScope oldWidget) =>
      oldWidget.tier != tier || oldWidget.opticalStrength != opticalStrength;
}

/// Resolves the ambient Liquid Glass optical refraction/dispersion strength (`0.0..1.0`)
/// from [GrassBagGlassTierScope].
double resolveAmbientGlassOpticalStrength(BuildContext context) =>
    GrassBagGlassTierScope.opticalStrengthOf(context);

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

    // 0. Whisper-subtle top specular kiss on translucent Layer-1 content cards (zero garish stripe!)
    if (paintTopSheen && !frosted && !innerWell) {
      final clipPath = _cachedOuterPath(size, rect, 0.0);
      final sheenAlpha = tinted
          ? (isDark ? 0.08 : 0.14)
          : (isDark ? 0.024 : 0.09);
      final sheenHeight = math.min(size.height * 0.16, 14.0);
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
              Colors.white.withValues(alpha: sheenAlpha * 0.20),
              Colors.transparent,
            ],
            stops: const [0.0, 0.42, 1.0],
          ).createShader(sheenRect),
      );
      canvas.restore();
    }

    // Whisper-fine 135° Apple iOS 27 optical specular rim (zero thick white wireframe outlines!):
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
        Colors.white.withValues(alpha: isDark ? 0.28 : 0.46),
        Color.lerp(Colors.white, prismAccent, 0.25)!.withValues(alpha: isDark ? 0.12 : 0.18),
        Colors.white.withValues(alpha: 0.01),
        Colors.white.withValues(alpha: 0.015),
        Color.lerp(Colors.white, counterPrism, 0.22)!.withValues(alpha: isDark ? 0.08 : 0.12),
        Colors.white.withValues(alpha: isDark ? 0.16 : 0.24),
      ];
    } else if (isDark) {
      rimBlend = BlendMode.plus;
      final peak = frosted ? 0.10 : (innerWell ? 0.10 : 0.13);
      final bounce = frosted ? 0.04 : (innerWell ? 0.04 : 0.065);
      rimColors = [
        Colors.white.withValues(alpha: peak),
        Color.lerp(Colors.white, prismAccent, 0.28)!.withValues(alpha: frosted ? 0.04 : 0.065),
        Colors.white.withValues(alpha: 0.012),
        Colors.white.withValues(alpha: 0.015),
        Color.lerp(Colors.white, counterPrism, 0.24)!.withValues(alpha: frosted ? 0.025 : 0.045),
        Colors.white.withValues(alpha: bounce),
      ];
    } else {
      rimBlend = BlendMode.srcOver;
      final peak = frosted ? 0.68 : (innerWell ? 0.58 : 0.78);
      final bounce = frosted ? 0.42 : (innerWell ? 0.36 : 0.56);
      final waist = innerWell ? const Color(0x05162E42) : const Color(0x07162E42);
      rimColors = [
        Colors.white.withValues(alpha: peak),
        Colors.white.withValues(alpha: frosted ? 0.42 : (innerWell ? 0.30 : 0.52)),
        waist,
        waist,
        Colors.white.withValues(alpha: frosted ? 0.32 : (innerWell ? 0.24 : 0.42)),
        Colors.white.withValues(alpha: bounce),
      ];
    }

    final rimPath = _cachedOuterPath(size, insetRect, halfSw);
    canvas.drawPath(
      rimPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth ?? (innerWell ? 0.55 : 0.65)
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

    // Luminous translucent iOS 26/27 Layer-1 cards (zero BackdropFilter cost, 120Hz scroll-safe!)
    // - Content cards (`!innerWell`, no tint): crystal translucent white in Light Mode & luminous
    //   obsidian glass in Dark Mode with crisp 135° Fresnel specular edge highlights so Home cards
    //   and Settings platters feel cohesive & airy next to the floating refractive Liquid Glass chrome!
    // - Recessed wells (`innerWell`, no tint): quiet borderless tonal well that nests effortlessly
    //   inside both cards and floating translucent Liquid Glass sheets.
    final Color surfaceColor;
    if (tintColor != null) {
      surfaceColor = tintColor!;
    } else if (innerWell) {
      surfaceColor = t.isDark
          ? Colors.white.withValues(alpha: isSolid ? 0.095 : 0.075)
          : const Color(0x0E162E42);
    } else {
      surfaceColor = t.isDark
          ? Color.lerp(t.cardSolid, Colors.white, 0.075)!
              .withValues(alpha: isSolid ? 1.0 : 0.64)
          : Colors.white.withValues(alpha: isSolid ? 1.0 : 0.72);
    }

    // Only paint a crisp border for High Contrast accessibility or Solid tier cards;
    // liquid/frosted cards get a luminous zero-shader 135° Fresnel specular rim below!
    final BorderSide side;
    if (highContrast) {
      side = BorderSide(color: t.sepStrong, width: 1.1);
    } else if (isSolid && !innerWell && tintColor == null) {
      side = BorderSide(color: t.sep, width: 0.65);
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
                  ? Colors.black.withValues(alpha: isSolid ? 0.22 : 0.22)
                  : const Color(0x090E243B),
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

    final useFresnelRim = !isSolid && !highContrast && !innerWell && tintColor == null;
    final Widget decorated = DecoratedBox(
      decoration: ShapeDecoration(
        color: surfaceColor,
        shape: baseShape,
        shadows: shadows,
      ),
      child: useFresnelRim
          ? CustomPaint(
              foregroundPainter: GrassBagFresnelRimPainter(
                isDark: t.isDark,
                borderRadius: borderRadius,
                isPill: isPill,
                isCircle: isCircle,
                accent: t.primaryHi,
                frosted: ambientTier == GrassBagGlassTier.frosted,
                paintTopSheen: paintTopSheen,
              ),
              child: body,
            )
          : body,
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

/// Shared Impeller `AdaptiveLiquidGlassLayer` (SwiftUI `GlassEffectContainer` equivalent)
/// that batches sibling floating pills in a navigation bar into ONE single SDF geometry
/// matte + ONE single refraction pass (cutting header GPU passes by up to 67%!).
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
  Widget build(BuildContext context) {
    final effectiveTier = resolveEffectiveGlassTier(context, tier);
    if (effectiveTier == GrassBagGlassTier.solid || platformViewBackdrop) {
      return child;
    }
    final t = GrassBagTokens.of(context);
    final opticalStrength = resolveAmbientGlassOpticalStrength(context);
    return AdaptiveLiquidGlassLayer(
      settings: GrassBagGlassConfig.surfaceSettings(
        t,
        effectiveTier,
        opticalStrength: opticalStrength,
      ),
      quality: GrassBagGlassConfig.chromeQualityFor(effectiveTier),
      blendAmount: 0.0,
      clipExpansion: const EdgeInsets.all(12),
      child: child,
    );
  }
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
    // Delegate optical defogging directly to `GlassMaterializeTransition` (driving shader
    // `visibility` without ever wrapping `BackdropFilterLayer` in an outer `OpacityLayer`),
    // while synchronizing externalized elevation shadows via [GrassBagMaterializeScope]!
    return GrassBagMaterializeScope(
      animation: widget.animation,
      child: GlassMaterializeTransition(
        animation: widget.animation,
        alignment: widget.alignment,
        scaleFrom: reduceMotion ? 1.0 : widget.scaleFrom,
        contentSigma: reduceMotion ? 0.0 : widget.contentSigma,
        child: widget.child,
      ),
    );
  }
}

/// Unified Apple iOS 27 Liquid Glass floating container powered by genuine `liquid_glass_widgets`
/// 1.19.0 ([GlassContainer] / `liquid_glass_render.frag` spherical crystal refraction).
///
/// Use ONLY on floating chrome (composer, approval card, '+' panel, steer popover,
/// remote banner, bottom-centered Toast, floating phone drawer, dialogs, sheets).
/// Never nest refractive glass inside refractive glass!
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

    if (effectiveTier == GrassBagGlassTier.solid) {
      final innerChild = (padding != null || alignment != null || width != null || height != null)
          ? Container(
              width: width,
              height: height,
              padding: padding,
              alignment: alignment,
              child: child,
            )
          : child;
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
            : RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(borderRadius),
                side: BorderSide(color: solidBorder, width: strokeW),
              );
        final clippedChild = clipBehavior == Clip.none
            ? innerChild
            : (isOval
                ? ClipOval(clipBehavior: clipBehavior, child: innerChild)
                : ClipRSuperellipse(
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

    final isOverlayPlatter = useSheetSettings || isDialog;
    final effectiveOwnLayer = useOwnLayer || tintColor != null || isOverlayPlatter;
    final opticalStrength = resolveAmbientGlassOpticalStrength(context);
    final baseSettings = isOverlayPlatter
        ? GrassBagGlassConfig.sheetSettings(
            t,
            effectiveTier,
            isDialog: isDialog,
            opticalStrength: opticalStrength,
          )
        : GrassBagGlassConfig.surfaceSettings(
            t,
            effectiveTier,
            elevated: elevated,
            opticalStrength: opticalStrength,
          );
    final rawBaseShadows = baseSettings.shadow ?? const <BoxShadow>[];
    // Externalize standalone shadows via `BlurStyle.outer` so `LiquidGlassLayer._bakeShadows()`
    // NEVER calls synchronous `picture.toImageSync()` on sheets, drawers, dialogs, or cards!
    final externalizeLightShadow = !t.isDark && effectiveOwnLayer && rawBaseShadows.isNotEmpty;
    final externalizeDarkShadow = t.isDark && effectiveOwnLayer && (isOverlayPlatter || elevated);
    final rawSettings =
        tintColor != null ? baseSettings.copyWith(glassColor: tintColor) : baseSettings;
    final resolvedSettings =
        externalizeLightShadow ? rawSettings.copyWith(shadow: const []) : rawSettings;

    final Widget glassWidget = GlassContainer(
      useOwnLayer: effectiveOwnLayer,
      platformViewBackdrop: platformViewBackdrop,
      quality: useCardQuality
          ? GrassBagGlassConfig.cardQualityFor(effectiveTier)
          : GrassBagGlassConfig.chromeQualityFor(effectiveTier),
      width: width,
      height: height,
      padding: padding,
      alignment: alignment,
      clipBehavior: clipBehavior,
      shape: isOval
          ? const LiquidOval()
          : LiquidRoundedSuperellipse(borderRadius: borderRadius),
      settings: effectiveOwnLayer ? resolvedSettings : null,
      child: child,
    );

    final Widget interactiveGlass = interactiveGlow
        ? GrassBagInteractiveHighlight(
            borderRadius: borderRadius,
            isPill: !isOval && borderRadius >= 900,
            isCircle: isOval,
            accent: tintColor ?? t.primaryHi,
            child: glassWidget,
          )
        : glassWidget;

    if (externalizeDarkShadow || externalizeLightShadow) {
      final outerShape = isOval
          ? const CircleBorder()
          : RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(borderRadius));
      final baseShadows = externalizeDarkShadow
          ? [
              BoxShadow(
                color: Colors.black
                    .withValues(alpha: isDialog ? 0.42 : (useSheetSettings ? 0.38 : 0.26)),
                blurRadius: isOverlayPlatter ? 28 : 18,
                offset: Offset(0, isOverlayPlatter ? 10 : 6),
                blurStyle: BlurStyle.outer,
              ),
            ]
          : [
              for (final s in rawBaseShadows)
                BoxShadow(
                  color: s.color,
                  blurRadius: s.blurRadius,
                  spreadRadius: s.spreadRadius,
                  offset: s.offset,
                  blurStyle: BlurStyle.outer,
                ),
            ];
      Widget wrapOuterShadow(double materialize, Widget inner) {
        return DecoratedBox(
          decoration: ShapeDecoration(
            shape: outerShape,
            shadows: materialize <= 0.01
                ? const []
                : [
                    for (final s in baseShadows)
                      BoxShadow(
                        color: s.color.withValues(alpha: s.color.a * materialize),
                        blurRadius: s.blurRadius,
                        spreadRadius: s.spreadRadius,
                        offset: s.offset,
                        blurStyle: BlurStyle.outer,
                      ),
                  ],
          ),
          child: inner,
        );
      }

      if (materializeAnim != null) {
        return AnimatedBuilder(
          animation: materializeAnim,
          child: interactiveGlass,
          builder: (_, inner) =>
              wrapOuterShadow(materializeAnim.value.clamp(0.0, 1.0), inner!),
        );
      }
      return wrapOuterShadow(GrassBagMaterializeScope.progressOf(context), interactiveGlass);
    }
    return interactiveGlass;
  }
}

/// 44×44 symmetrical circular Apple iOS 27 Liquid Glass chrome icon button backed by real
/// [GlassButton.custom] with authentic optical refraction, LiquidStretch, and centered icon.
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

    if (isSolid) {
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
              color: tintColor ?? t.cardSolid,
              shape: CircleBorder(
                side: BorderSide(
                  color: t.sepStrong,
                  width: highContrast ? 1.15 : 0.65,
                ),
              ),
              shadows: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: t.isDark ? 0.24 : 0.08),
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

    final effectiveOwnLayer = useOwnLayer || platformViewBackdrop || tintColor != null;
    final opticalStrength = resolveAmbientGlassOpticalStrength(context);
    final btn = Semantics(
      button: true,
      label: tooltip,
      child: GlassButton.custom(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        width: size,
        height: size,
        shape: const LiquidOval(),
        useOwnLayer: effectiveOwnLayer,
        quality: GrassBagGlassConfig.chromeQualityFor(effectiveTier),
        surfaceStyle: GlassSurfaceStyle.glass,
        tintColor: tintColor,
        platformViewBackdrop: platformViewBackdrop,
        settings: !effectiveOwnLayer
            ? null
            : GrassBagGlassConfig.surfaceSettings(
                t,
                effectiveTier,
                opticalStrength: opticalStrength,
              ),
        interactionScale: 1.07,
        stretch: effectiveOwnLayer ? 0.35 : 0.16,
        anchorStretch: true,
        glowColor: (tintColor ?? t.primaryHi).withValues(alpha: t.isDark ? 0.30 : 0.20),
        child: iconWidget,
      ),
    );
    return tooltip != null
        ? Tooltip(message: tooltip!, excludeFromSemantics: true, child: btn)
        : btn;
  }
}

/// Interactive stadium-shaped Apple iOS 27 Liquid Glass pill button backed by [GlassButton.custom]
/// (floating chat title pill, secondary page title pills, prominent tinted glass pills, and action badges).
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

    if (isSolid) {
      final fill = prominent ? (tintColor ?? t.primary) : (tintColor ?? t.cardSolid);
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
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(borderRadius),
                  side: BorderSide(
                    color: prominent ? Colors.transparent : t.sepStrong,
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

    final effectiveOwnLayer = useOwnLayer || platformViewBackdrop || prominent || tintColor != null;
    final opticalStrength = resolveAmbientGlassOpticalStrength(context);
    final baseSettings = GrassBagGlassConfig.surfaceSettings(
      t,
      effectiveTier,
      opticalStrength: opticalStrength,
    );
    final isLiquid = effectiveTier == GrassBagGlassTier.liquid && !kIsWeb;
    final resolvedSettings = !effectiveOwnLayer
        ? null
        : (prominent
            ? baseSettings.copyWith(
                bodyMode: GlassBodyMode.clear,
                glassColor: (tintColor ?? t.primary).withValues(alpha: t.isDark ? 0.80 : 0.88),
                thickness: isLiquid ? (16.0 + 12.0 * opticalStrength) : 1.0,
                refractiveIndex: isLiquid ? (1.18 + 0.20 * opticalStrength) : 1.01,
                lensModel: GlassLensModel.spherical,
                chromaticAberration: isLiquid
                    ? GrassBagGlassConfig.scaleChromatic(opticalStrength, 0.08, 0.40)
                    : 0.0,
                rimLight: isLiquid ? 0.86 : 0.36,
              )
            : baseSettings);

    return Semantics(
      button: true,
      child: GlassButton.custom(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        height: height,
        shape: LiquidRoundedSuperellipse(borderRadius: borderRadius),
        useOwnLayer: effectiveOwnLayer,
        platformViewBackdrop: platformViewBackdrop,
        quality: GrassBagGlassConfig.chromeQualityFor(effectiveTier),
        surfaceStyle: GlassSurfaceStyle.glass,
        style: GlassButtonStyle.filled,
        tintColor: prominent ? null : tintColor,
        settings: resolvedSettings,
        interactionScale: 1.04,
        stretch: effectiveOwnLayer ? 0.28 : 0.14,
        anchorStretch: true,
        glowColor: (tintColor ?? t.primaryHi).withValues(alpha: t.isDark ? 0.28 : 0.20),
        child: Padding(
          padding: padding,
          child: child,
        ),
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
      // Inside a floating glass drawer or sheet (`insideGlass == true`), follow Apple iOS 27
      // Rule 2 (zero nested refractive glass, zero fat white plastic borders!): render a calm,
      // borderless translucent recessed capsule (`tertiarySystemFill`).
      if (widget.insideGlass) {
        return DecoratedBox(
          decoration: ShapeDecoration(
            color: t.isDark
                ? Colors.white.withValues(alpha: 0.095)
                : Colors.black.withValues(alpha: 0.055),
            shape: const StadiumBorder(),
          ),
          child: field,
        );
      }
      return GrassBagGlass(
        tier: effectiveTier,
        borderRadius: 999,
        useOwnLayer: true,
        interactiveGlow: false,
        clipBehavior: Clip.antiAlias,
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

/// Re-enables genuine 3D GPU paraxial/spherical lens refraction for transient lifted-lens
/// controls (`GlassSwitch`, `GlassSegmentedControl`, `GlassSlider`) even when hosted inside a
/// floating `GrassBagGlass` sheet or `+` deck. Mirrors `GlassModalSheet`'s own
/// `InheritedLiquidGlass(avoidsRefraction: false)` + `GlassIsolationScope` pattern while keeping
/// ZERO shader layers mounted at rest!
class _GrassBagLensScope extends StatelessWidget {
  const _GrassBagLensScope({
    required this.tier,
    required this.child,
  });

  final GrassBagGlassTier tier;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (tier == GrassBagGlassTier.solid) return child;
    final lensQuality = tier == GrassBagGlassTier.liquid && !kIsWeb
        ? GlassQuality.premium
        : GlassQuality.standard;
    final inherited =
        context.dependOnInheritedWidgetOfExactType<InheritedLiquidGlass>();
    if (inherited == null || !inherited.avoidsRefraction) return child;
    return InheritedLiquidGlass(
      settings: inherited.settings,
      quality: lensQuality,
      isBlurProvidedByAncestor: inherited.isBlurProvidedByAncestor,
      avoidsRefraction: false,
      hasExplicitSettings: inherited.hasExplicitSettings,
      hasExplicitQuality: true,
      child: GlassIsolationScope(
        isolated: true,
        defaultQuality: lensQuality,
        child: child,
      ),
    );
  }
}

/// Calibrated Apple iOS 27 `_UILiquidLensView` optical settings for interactive switch,
/// slider, and segmented-control thumbs (0 shaders at rest; full 3D GPU droplet lens on press/drag).
LiquidGlassSettings _interactiveLensSettings(
  GrassBagGlassTier tier, {
  double refractiveIndex = 1.38,
  double chromaticAberration = 0.15,
  double opticalStrength = GrassBagGlassConfig.defaultOpticalStrength,
}) {
  if (tier != GrassBagGlassTier.liquid || kIsWeb) {
    return LiquidGlassSettings.ios27Indicator.copyWith(
      refractiveIndex: 1.18,
      chromaticAberration: 0.0,
    );
  }
  final s = opticalStrength.clamp(0.0, 1.0);
  final minN = math.max(1.16, refractiveIndex - 0.12);
  final scaledN = minN + (refractiveIndex - minN) * (s / GrassBagGlassConfig.defaultOpticalStrength).clamp(0.0, 2.0);
  final scaledCa = GrassBagGlassConfig.scaleChromatic(
    s,
    chromaticAberration,
    math.min(0.65, chromaticAberration * 4.0),
  );
  return LiquidGlassSettings.ios27Indicator.copyWith(
    refractiveIndex: scaledN.clamp(1.16, 1.54),
    chromaticAberration: scaledCa,
    lightIntensity: 0.55,
    ambientStrength: 0.10,
    fresnelStrength: 0.85,
    rimLight: 1.0,
    rimShade: 0.85,
  );
}

/// Authentic Apple iOS 27 [GlassSwitch]:
/// - Calibrated `60×28` capsule proportions (`37×24` elongated pill thumb)
/// - Zero GPU shaders at rest; elastically lifts into a real 3D `_UILiquidLensView` crystal
///   water-droplet lens with chromatic rim dispersion and spring jump on press/drag!
class GrassBagGlassSwitch extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final effectiveTier = resolveEffectiveGlassTier(context, tier);
    final isSolid = effectiveTier == GrassBagGlassTier.solid;
    final resolvedActive = activeColor ??
        (t.isDark ? const Color(0xFF30D158) : const Color(0xFF34C759));
    final resolvedInactive =
        t.isDark ? const Color(0x4DEBEBF5) : const Color(0x363C3C43);

    if (isSolid) {
      return _GrassBagSolidSpringSwitch(
        value: value,
        onChanged: onChanged,
        activeColor: resolvedActive,
        inactiveColor: resolvedInactive,
      );
    }

    final lensQuality = effectiveTier == GrassBagGlassTier.liquid && !kIsWeb
        ? GlassQuality.premium
        : GlassQuality.standard;
    final opticalStrength = resolveAmbientGlassOpticalStrength(context);
    return _GrassBagLensScope(
      tier: effectiveTier,
      child: GlassSwitch(
        value: value,
        onChanged: onChanged,
        activeColor: resolvedActive,
        inactiveColor: resolvedInactive,
        width: 60.0,
        height: 28.0,
        useOwnLayer: false,
        quality: lensQuality,
        settings: _interactiveLensSettings(
          effectiveTier,
          refractiveIndex: 1.40,
          chromaticAberration: 0.16,
          opticalStrength: opticalStrength,
        ),
        enableHaptics: true,
      ),
    );
  }
}

/// Spring-driven 1:1 draggable solid switch for `GrassBagGlassTier.solid`.
class _GrassBagSolidSpringSwitch extends StatefulWidget {
  const _GrassBagSolidSpringSwitch({
    required this.value,
    required this.onChanged,
    required this.activeColor,
    required this.inactiveColor,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color activeColor;
  final Color inactiveColor;

  @override
  State<_GrassBagSolidSpringSwitch> createState() =>
      _GrassBagSolidSpringSwitchState();
}

class _GrassBagSolidSpringSwitchState extends State<_GrassBagSolidSpringSwitch>
    with SingleTickerProviderStateMixin {
  static const double _width = 60.0;
  static const double _height = 28.0;
  static const double _thumbW = 36.0;
  static const double _thumbH = 24.0;
  static const double _pad = 2.0;
  static const double _runway = _width - _pad * 2 - _thumbW;

  late final SingleSpringController _spring;
  double? _dragPos;

  @override
  void initState() {
    super.initState();
    _spring = SingleSpringController(
      vsync: this,
      spring: GlassSpring.snappy(duration: const Duration(milliseconds: 240)),
      initialValue: widget.value ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(covariant _GrassBagSolidSpringSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && _dragPos == null) {
      if (mounted && MediaQuery.disableAnimationsOf(context)) {
        _spring.setValue(widget.value ? 1.0 : 0.0);
      } else {
        _spring.animateTo(widget.value ? 1.0 : 0.0);
      }
    }
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _toggle(bool next) {
    final cb = widget.onChanged;
    if (cb == null) return;
    HapticFeedback.selectionClick();
    if (next == widget.value) {
      _spring.animateTo(widget.value ? 1.0 : 0.0);
      return;
    }
    cb(next);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final body = ListenableBuilder(
      listenable: _spring,
      builder: (context, thumb) {
        final t = (_dragPos ?? _spring.value).clamp(0.0, 1.0);
        final trackColor = Color.lerp(widget.inactiveColor, widget.activeColor, t)!;
        final dx = _pad + _runway * (_dragPos ?? _spring.value).clamp(-0.08, 1.08);
        return SizedBox(
          width: _width,
          height: _height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: trackColor,
              borderRadius: BorderRadius.circular(_height / 2),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: dx,
                  top: _pad,
                  child: thumb!,
                ),
              ],
            ),
          ),
        );
      },
      child: Container(
        width: _thumbW,
        height: _thumbH,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(_thumbH / 2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x28000000),
              blurRadius: 5,
              offset: Offset(0, 1.5),
            ),
          ],
        ),
      ),
    );

    return Semantics(
      toggled: widget.value,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => _toggle(!widget.value) : null,
        onHorizontalDragStart: enabled
            ? (_) {
                _dragPos = _spring.value.clamp(0.0, 1.0);
              }
            : null,
        onHorizontalDragUpdate: enabled
            ? (details) {
                final cur = (_dragPos ?? (widget.value ? 1.0 : 0.0)) +
                    details.delta.dx / _runway;
                _dragPos = cur.clamp(0.0, 1.0);
                _spring.setValue(_dragPos!);
              }
            : null,
        onHorizontalDragEnd: enabled
            ? (details) {
                final vx = details.primaryVelocity ?? 0.0;
                final pos = _dragPos ?? _spring.value;
                _dragPos = null;
                final bool next;
                if (vx > 90) {
                  next = true;
                } else if (vx < -90) {
                  next = false;
                } else {
                  next = pos >= 0.5;
                }
                _toggle(next);
              }
            : null,
        onHorizontalDragCancel: enabled
            ? () {
                _dragPos = null;
                _spring.animateTo(widget.value ? 1.0 : 0.0);
              }
            : null,
        child: enabled ? body : Opacity(opacity: 0.45, child: body),
      ),
    );
  }
}

/// Authentic Apple iOS 27 [GlassSegmentedControl]:
/// - Genuine swipe/drag-to-select across segments with velocity-driven jelly squash & stretch
/// - Real 3D GPU refractive crystal lens (`ios27Indicator` + chromatic dispersion + concave pinch)
///   that physically magnifies & refracts segment labels on touch, tap, and drag
/// - Automatically uses [GlassSegmentedControl.scrollable] for `> 6` options and handles `1` option safely.
class GrassBagSegmentedControl extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    final t = GrassBagTokens.of(context);
    final effectiveTier = resolveEffectiveGlassTier(context, tier);
    final safeIdx = selectedIndex.clamp(0, labels.length - 1);
    final bg = t.isDark ? const Color(0x38787880) : const Color(0x1B767680);
    final indicator = t.isDark ? const Color(0x36FFFFFF) : const Color(0xFFFFFFFF);
    final solidIndicator = t.isDark ? const Color(0xFF363E4F) : Colors.white;
    final selectedStyle = TextStyle(
      fontSize: height <= 34 ? 12.5 : 13.0,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.15,
      color: t.isDark ? Colors.white : t.text,
    );
    final unselectedStyle = TextStyle(
      fontSize: height <= 34 ? 12.5 : 13.0,
      fontWeight: FontWeight.w500,
      letterSpacing: -0.1,
      color: t.text2,
    );

    if (labels.length == 1) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Container(
          height: height,
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(height / 2),
          ),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: effectiveTier == GrassBagGlassTier.solid ? solidIndicator : indicator,
              borderRadius: BorderRadius.circular((height - 5) / 2),
              boxShadow: t.isDark
                  ? null
                  : const [
                      BoxShadow(
                        color: Color(0x14000000),
                        blurRadius: 6,
                        offset: Offset(0, 1.5),
                      ),
                    ],
            ),
            child: Text(
              labels.first,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: selectedStyle,
            ),
          ),
        ),
      );
    }

    final isSolid = effectiveTier == GrassBagGlassTier.solid;
    void handleSelect(int i) {
      if (i == safeIdx) return;
      HapticFeedback.selectionClick();
      onSelected(i);
    }

    if (isSolid) {
      if (labels.length >= 6) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Container(
            height: height,
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(height / 2),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  for (var i = 0; i < labels.length; i++)
                    Semantics(
                      button: true,
                      selected: i == safeIdx,
                      label: labels[i],
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => handleSelect(i),
                        child: AnimatedContainer(
                          duration: GrassBagMotion.duration(
                            context,
                            const Duration(milliseconds: 180),
                          ),
                          curve: Curves.easeOutCubic,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: i == safeIdx ? solidIndicator : Colors.transparent,
                            borderRadius: BorderRadius.circular((height - 5) / 2),
                            boxShadow: i == safeIdx && !t.isDark
                                ? const [
                                    BoxShadow(
                                      color: Color(0x14000000),
                                      blurRadius: 6,
                                      offset: Offset(0, 1.5),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Text(
                            labels[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: i == safeIdx ? selectedStyle : unselectedStyle,
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

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Container(
          height: height,
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(height / 2),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final segW = constraints.maxWidth / labels.length;
              void selectAtDx(double dx) {
                if (segW <= 0) return;
                final idx = (dx / segW).floor().clamp(0, labels.length - 1);
                handleSelect(idx);
              }
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) => selectAtDx(details.localPosition.dx),
                child: Stack(
                  children: [
                    AnimatedPositioned(
                      duration: GrassBagMotion.duration(
                        context,
                        const Duration(milliseconds: 220),
                      ),
                      curve: Curves.easeOutCubic,
                      left: segW * safeIdx,
                      top: 0,
                      bottom: 0,
                      width: segW,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: solidIndicator,
                          borderRadius: BorderRadius.circular((height - 5) / 2),
                          border: t.isDark
                              ? Border.all(
                                  color: Colors.white.withValues(alpha: 0.12),
                                  width: 0.6,
                                )
                              : null,
                          boxShadow: t.isDark
                              ? const [
                                  BoxShadow(
                                    color: Color(0x28000000),
                                    blurRadius: 6,
                                    offset: Offset(0, 1.5),
                                  ),
                                ]
                              : const [
                                  BoxShadow(
                                    color: Color(0x16000000),
                                    blurRadius: 6,
                                    offset: Offset(0, 1.5),
                                  ),
                                ],
                        ),
                      ),
                    ),
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
                                onTap: () => handleSelect(i),
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    child: Text(
                                      labels[i],
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: i == safeIdx ? selectedStyle : unselectedStyle,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    }

    final segments = [for (final label in labels) GlassSegment(label: label)];
    final lensQuality = effectiveTier == GrassBagGlassTier.liquid && !kIsWeb
        ? GlassQuality.premium
        : GlassQuality.standard;
    final opticalStrength = resolveAmbientGlassOpticalStrength(context);
    final lensSettings = _interactiveLensSettings(
      effectiveTier,
      refractiveIndex: 1.32,
      chromaticAberration: 0.14,
      opticalStrength: opticalStrength,
    );

    final control = labels.length > 6
        ? GlassSegmentedControl.scrollable(
            segments: segments,
            selectedIndex: safeIdx,
            onSegmentSelected: handleSelect,
            height: height,
            borderRadius: GlassDefaults.capsuleRadius,
            useOwnLayer: false,
            quality: lensQuality,
            backgroundColor: bg,
            indicatorColor: indicator,
            indicatorSettings: lensSettings,
            indicatorPinchStrength: 0.45,
            indicatorExpansion: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            selectedTextStyle: selectedStyle,
            unselectedTextStyle: unselectedStyle,
          )
        : GlassSegmentedControl(
            segments: segments,
            selectedIndex: safeIdx,
            onSegmentSelected: handleSelect,
            height: height,
            borderRadius: GlassDefaults.capsuleRadius,
            useOwnLayer: false,
            quality: lensQuality,
            backgroundColor: bg,
            indicatorColor: indicator,
            indicatorSettings: lensSettings,
            indicatorPinchStrength: 0.45,
            indicatorExpansion: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            selectedTextStyle: selectedStyle,
            unselectedTextStyle: unselectedStyle,
            glowColor: t.primaryHi.withValues(alpha: 0.22),
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: _GrassBagLensScope(
        tier: effectiveTier,
        child: control,
      ),
    );
  }
}

/// Authentic Apple iOS 27 [GlassSlider]:
/// - `6dp` capsule track + elongated pill thumb that lifts into a live 3D GPU `_UILiquidLensView`
///   crystal lens with velocity-driven jelly squash & stretch and prismatic edge dispersion!
class GrassBagGlassSlider extends StatelessWidget {
  const GrassBagGlassSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.divisions,
    this.activeColor,
    this.tier,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final int? divisions;
  final Color? activeColor;
  final GrassBagGlassTier? tier;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final resolvedTier = resolveEffectiveGlassTier(
      context,
      tier ?? resolveAmbientGlassTier(context),
    );
    final enabled = onChanged != null;
    final isSolid = resolvedTier == GrassBagGlassTier.solid;
    final safeMax = max > min ? max : min + 1.0;
    final clampedVal = value.clamp(min, safeMax);
    final rawActive = activeColor ?? t.primary;
    final resolvedActive = (t.isDark && rawActive.computeLuminance() > 0.65)
        ? Color.lerp(rawActive, t.cardSolid, 0.30)!
        : rawActive;
    final resolvedInactive =
        t.isDark ? const Color(0x38FFFFFF) : const Color(0x200F172A);

    if (isSolid) {
      final solidSlider = SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 6.0,
          activeTrackColor: resolvedActive,
          inactiveTrackColor: resolvedInactive,
          thumbColor: Colors.white,
          overlayColor: resolvedActive.withValues(alpha: 0.16),
          thumbShape: const _GrassBagSolidPillSliderThumbShape(),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 20.0),
          tickMarkShape: SliderTickMarkShape.noTickMark,
        ),
        child: Slider(
          value: clampedVal,
          min: min,
          max: safeMax,
          divisions: divisions,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      );
      if (enabled) return solidSlider;
      return IgnorePointer(
        child: Opacity(opacity: 0.45, child: solidSlider),
      );
    }

    final lensQuality = resolvedTier == GrassBagGlassTier.liquid && !kIsWeb
        ? GlassQuality.premium
        : GlassQuality.standard;
    final opticalStrength = resolveAmbientGlassOpticalStrength(context);
    const thumbRadius = 14.0;
    final slider = _GrassBagLensScope(
      tier: resolvedTier,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          void handleTapAt(Offset localPosition) {
            if (!enabled) return;
            final trackW = constraints.maxWidth - (thumbRadius * 2);
            if (trackW <= 0) return;
            final isRtl = Directionality.of(ctx) == TextDirection.rtl;
            final rawNorm = ((localPosition.dx - thumbRadius) / trackW).clamp(0.0, 1.0);
            final norm = isRtl ? 1.0 - rawNorm : rawNorm;
            var next = min + norm * (safeMax - min);
            if (divisions != null && divisions! > 0) {
              final step = (safeMax - min) / divisions!;
              next = ((next - min) / step).round() * step + min;
            }
            next = next.clamp(min, safeMax);
            HapticFeedback.selectionClick();
            onChanged?.call(next);
            onChangeEnd?.call(next);
          }

          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: enabled ? (d) => handleTapAt(d.localPosition) : null,
            child: GlassSlider(
              value: clampedVal,
              min: min,
              max: safeMax,
              divisions: divisions,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
              activeColor: resolvedActive,
              inactiveColor: resolvedInactive,
              trackHeight: 6.0,
              thumbRadius: thumbRadius,
              useOwnLayer: false,
              quality: lensQuality,
              settings: _interactiveLensSettings(
                resolvedTier,
                refractiveIndex: 1.38,
                chromaticAberration: 0.16,
                opticalStrength: opticalStrength,
              ),
            ),
          );
        },
      ),
    );
    if (enabled) return slider;
    return IgnorePointer(
      child: Opacity(opacity: 0.45, child: slider),
    );
  }
}

class _GrassBagSolidPillSliderThumbShape extends SliderComponentShape {
  const _GrassBagSolidPillSliderThumbShape();

  static const double _width = 30.0;
  static const double _height = 20.0;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(_width, _height);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final rect = Rect.fromCenter(center: center, width: _width, height: _height);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(_height / 2));
    final shadowPath = Path()..addRRect(rrect);
    canvas.drawShadow(shadowPath, const Color(0x40000000), 3.0, true);
    canvas.drawRRect(
      rrect,
      Paint()..color = sliderTheme.thumbColor ?? Colors.white,
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = const Color(0x1A000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6,
    );
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

/// Prominent Apple iOS 27 tinted Liquid Glass capsule CTA button powered by [GlassButton.custom]:
/// - Full 3D GPU optical refraction (`GlassBodyMode.clear`) + [LiquidStretch] + [GlassGlow] on canvas
/// - Clean borderless luminous capsule inside floating glass sheets/dialogs (zero double-glass wireframes!)
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
    final inRefractiveGlass =
        context.dependOnInheritedWidgetOfExactType<InheritedLiquidGlass>()?.avoidsRefraction ??
            false;
    final inSolidCard =
        InheritedGlassSurfaceStyle.maybeOf(context) == GlassSurfaceStyle.solid;
    final renderAsSolidCapsule = isSolid || insideGlass || inSolidCard;
    final useOwn = !renderAsSolidCapsule && !inRefractiveGlass;

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

    final isFrosted = effectiveTier == GrassBagGlassTier.frosted || kIsWeb;
    final glassSettings = renderAsSolidCapsule
        ? null
        : LiquidGlassSettings(
            bodyMode: GlassBodyMode.clear,
            glassColor: bg.withValues(
              alpha: inRefractiveGlass
                  ? (t.isDark ? 0.84 : 0.88)
                  : (t.isDark ? 0.78 : 0.84),
            ),
            blur: isFrosted ? 6.0 : 1.8,
            frost: 0.0,
            frostOpacity: 0.0,
            thickness: isFrosted ? 1.0 : 22.0,
            refractiveIndex: isFrosted ? 1.01 : 1.28,
            lensModel: GlassLensModel.spherical,
            chromaticAberration: isFrosted ? 0.0 : 0.08,
            saturation: isFrosted ? 1.0 : 1.45,
            lightAngle: 0.75 * math.pi,
            lightIntensity: isFrosted ? 0.16 : 0.65,
            ambientStrength: isFrosted ? 0.06 : 0.10,
            fresnelStrength: isFrosted ? 0.20 : 0.85,
            edgeAbsorption: 0.02,
            rimLight: isFrosted ? 0.36 : 0.82,
            rimShade: 0.0,
            bodyShade: 0.0,
            specularSharpness:
                isFrosted ? GlassSpecularSharpness.medium : GlassSpecularSharpness.sharp,
            shadow: [
              BoxShadow(
                color: bg.withValues(alpha: t.isDark ? 0.30 : 0.22),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          );

    return GlassButton.custom(
      onTap: () {
        if (!active) return;
        HapticFeedback.lightImpact();
        onTap!();
      },
      enabled: active,
      height: height,
      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
      useOwnLayer: useOwn,
      quality: renderAsSolidCapsule ? null : GrassBagGlassConfig.chromeQualityFor(effectiveTier),
      surfaceStyle: renderAsSolidCapsule ? GlassSurfaceStyle.solid : GlassSurfaceStyle.glass,
      style: GlassButtonStyle.filled,
      color: renderAsSolidCapsule ? bg.withValues(alpha: insideGlass && !isSolid ? 0.92 : 1.0) : null,
      settings: glassSettings,
      interactionScale: 1.035,
      stretch: useOwn ? 0.26 : 0.18,
      anchorStretch: true,
      glowColor: Colors.white.withValues(alpha: 0.28),
      glowRadius: 1.35,
      child: labelRow,
    );
  }
}

/// Secondary Apple iOS 27 crystal translucent glass capsule button powered by [GlassButton.custom]:
/// - Full 3D GPU optical refraction (`GlassBodyMode.clear`) on canvas
/// - Clean borderless iOS 27 translucent filled capsule (`_UIAlertControllerFilledBackgroundView`)
///   inside floating glass sheets, drawers, and dialogs (ZERO fat white wireframe outlines!)
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
    final inRefractiveGlass =
        context.dependOnInheritedWidgetOfExactType<InheritedLiquidGlass>()?.avoidsRefraction ??
            false;
    final inSolidCard =
        InheritedGlassSurfaceStyle.maybeOf(context) == GlassSurfaceStyle.solid;
    final renderAsSolidCapsule = isSolid || insideGlass || inSolidCard;
    final useOwn = !renderAsSolidCapsule && !inRefractiveGlass;

    final Color solidBg = destructive
        ? t.errSoft
        : (accentForeground
            ? (insideGlass && !isSolid
                ? t.primary.withValues(alpha: t.isDark ? 0.22 : 0.13)
                : t.primarySoft)
            : (insideGlass && !isSolid
                ? (t.isDark
                    ? Colors.white.withValues(alpha: 0.12)
                    : Colors.black.withValues(alpha: 0.075))
                : (t.isDark
                    ? Colors.white.withValues(alpha: 0.10)
                    : const Color(0x12162E42))));

    final Color glassTint;
    if (destructive) {
      glassTint = t.err.withValues(alpha: t.isDark ? 0.22 : 0.12);
    } else if (accentForeground) {
      glassTint = t.isDark
          ? t.primary.withValues(alpha: 0.20)
          : Color.lerp(Colors.white, t.primary, 0.14)!.withValues(alpha: 0.42);
    } else if (t.isDark) {
      glassTint = Colors.white.withValues(alpha: inRefractiveGlass ? 0.12 : 0.08);
    } else {
      glassTint = Colors.white.withValues(alpha: inRefractiveGlass ? 0.48 : 0.32);
    }

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

    final isFrosted = effectiveTier == GrassBagGlassTier.frosted || kIsWeb;
    final glassSettings = renderAsSolidCapsule
        ? null
        : LiquidGlassSettings(
            bodyMode: GlassBodyMode.clear,
            glassColor: glassTint,
            blur: isFrosted ? 6.5 : 1.8,
            frost: 0.0,
            frostOpacity: 0.0,
            thickness: isFrosted ? 1.0 : 22.0,
            refractiveIndex: isFrosted ? 1.01 : 1.28,
            lensModel: GlassLensModel.spherical,
            chromaticAberration: isFrosted ? 0.0 : 0.08,
            saturation: isFrosted ? 1.0 : 1.58,
            lightAngle: 0.75 * math.pi,
            lightIntensity: isFrosted ? 0.14 : 0.68,
            ambientStrength: isFrosted ? 0.06 : 0.10,
            fresnelStrength: isFrosted ? 0.18 : 0.90,
            edgeAbsorption: 0.02,
            rimLight: isFrosted ? 0.36 : 0.84,
            rimShade: 0.0,
            bodyShade: 0.0,
            specularSharpness:
                isFrosted ? GlassSpecularSharpness.medium : GlassSpecularSharpness.sharp,
            shadow: t.isDark
                ? const []
                : const [
                    BoxShadow(
                      color: Color(0x0E000000),
                      blurRadius: 12,
                      offset: Offset(0, 3),
                    ),
                  ],
          );

    return GlassButton.custom(
      onTap: () {
        if (!active) return;
        HapticFeedback.selectionClick();
        onTap?.call();
      },
      enabled: active,
      height: height,
      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
      useOwnLayer: useOwn,
      quality: renderAsSolidCapsule ? null : GrassBagGlassConfig.chromeQualityFor(effectiveTier),
      surfaceStyle: renderAsSolidCapsule ? GlassSurfaceStyle.solid : GlassSurfaceStyle.glass,
      style: GlassButtonStyle.filled,
      color: renderAsSolidCapsule ? solidBg : null,
      settings: glassSettings,
      interactionScale: 1.035,
      stretch: useOwn ? 0.24 : 0.16,
      anchorStretch: true,
      glowColor: (destructive ? t.err : t.primaryHi).withValues(alpha: 0.24),
      glowRadius: 1.35,
      child: labelRow,
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

/// Lightweight pure-gradient top-edge scroll feather placed BEHIND floating Liquid Glass
/// navigation bars ([GrassBagUnifiedHeader] and [GrassBagShell]):
/// - Zero extra full-width `BackdropFilter` GPU readbacks per scroll frame (rock-solid 120Hz!)
/// - Whisper-clear alpha curve keeps status-bar glyphs legible while letting scrolled content
///   pass visibly right beneath the floating crystal nav pills for real live refraction!
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
    final isSolid = effectiveTier == GrassBagGlassTier.solid;
    final hasStatusBar = topPad > 4.0;
    final baseTop = hasStatusBar ? topPad : 0.0;
    final extra = extraHeight.clamp(0.0, 140.0);
    // Keep the narrow OS status-bar band cleanly shaded so system clock/5G glyphs NEVER
    // collide with scrolled cards, then dissolve rapidly to 0.0 right above the floating
    // crystal nav pills so scrolled content refracts unobstructed through the glass!
    final capH = baseTop + (isSolid ? 64.0 : 28.0) + extra * 0.65;
    final s1 = (baseTop * 0.85 / capH).clamp(0.18, 0.58);
    final s2 = ((baseTop + 10.0) / capH).clamp(s1 + 0.10, 0.82);
    final topAlphas = isSolid
        ? (t.isDark ? const [0.94, 0.78, 0.34, 0.0] : const [0.96, 0.80, 0.36, 0.0])
        : (t.isDark ? const [0.90, 0.70, 0.22, 0.0] : const [0.90, 0.68, 0.18, 0.0]);

    return IgnorePointer(
      child: SizedBox(
        height: capH,
        width: double.infinity,
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
              ],
              stops: [0.0, s1, s2, 1.0],
            ),
          ),
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
    final chipContent = Padding(
      padding: padding,
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
    final pillBody = AnimatedContainer(
      duration: animDur,
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected
            ? t.primary
            : (t.isDark
                ? Colors.white.withValues(alpha: isSolid ? 0.09 : 0.085)
                : (isSolid ? const Color(0x11162E42) : Colors.black.withValues(alpha: 0.055))),
        borderRadius: BorderRadius.circular(999),
        border: isSolid
            ? Border.all(
                color: selected ? t.primary : t.sep,
                width: 0.65,
              )
            : null,
      ),
      child: chipContent,
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
// Apple iOS 26/27 Floating Liquid Glass Context Menus, Press-Hold Scrubbing & Text Selection Toolbars
// ---------------------------------------------------------------------------

/// Miniature 4-bar Apple-style reasoning depth indicator used inside the composer
/// effort badge and the iOS Liquid Glass long-press thinking-effort menu.
class GrassBagEffortDepthBars extends StatelessWidget {
  const GrassBagEffortDepthBars({
    super.key,
    required this.level,
    required this.activeColor,
    this.inactiveColor,
    this.compact = false,
  });

  /// Normalized depth level in `0..4`.
  final int level;
  final Color activeColor;
  final Color? inactiveColor;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final clamped = level.clamp(0, 4);
    final offColor = inactiveColor ?? activeColor.withValues(alpha: 0.20);
    final heights = compact
        ? const [4.0, 6.2, 8.4, 10.6]
        : const [5.0, 7.8, 10.6, 13.4];
    final barW = compact ? 2.0 : 2.5;
    final gap = compact ? 1.5 : 2.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) SizedBox(width: gap),
          AnimatedContainer(
            duration: GrassBagMotion.duration(context, const Duration(milliseconds: 180)),
            curve: Curves.easeOutCubic,
            width: barW,
            height: heights[i],
            decoration: BoxDecoration(
              color: i < clamped ? activeColor : offColor,
              borderRadius: BorderRadius.circular(barW),
            ),
          ),
        ],
      ],
    );
  }
}

/// Compact horizontal quick-action tile rendered at the top of an iOS 26/27
/// Liquid Glass context menu (matching iOS Safari / Mail / Notes quick icon strip).
class GrassBagContextMenuQuickAction {
  const GrassBagContextMenuQuickAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.selected = false,
    this.destructive = false,
    this.accentColor,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool selected;
  final bool destructive;
  final Color? accentColor;
  final bool enabled;
}

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
    this.accentColor,
    this.trailing,
    this.badge,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final String? subtitle;
  final bool destructive;
  final bool selected;
  final bool dividerBefore;
  final Color? accentColor;
  final Widget? trailing;
  final String? badge;
  final bool enabled;
}

/// Menu content specification returned dynamically by [GrassBagGlassLongPressTrigger].
class GrassBagLongPressMenuSpec {
  const GrassBagLongPressMenuSpec({
    required this.items,
    this.quickActions = const [],
    this.headerTitle,
    this.headerSubtitle,
    this.menuWidth,
    this.preferAbove,
  });

  final List<GrassBagContextMenuItem> items;
  final List<GrassBagContextMenuQuickAction> quickActions;
  final String? headerTitle;
  final String? headerSubtitle;
  final double? menuWidth;
  final bool? preferAbove;
}

/// Native iOS 27 underdamped spring curve for blooming Liquid Glass menus.
class _GrassBagSpringBloomCurve extends Curve {
  const _GrassBagSpringBloomCurve();

  static final SpringSimulation _sim = SpringSimulation(
    const SpringDescription(mass: 1.0, stiffness: 330.0, damping: 24.5),
    0.0,
    1.0,
    0.0,
  );

  @override
  double transformInternal(double t) {
    if (t <= 0.0) return 0.0;
    if (t >= 1.0) return 1.0;
    // Scale simulation time to ~420ms so overshoot peeks gently (~1.035) and settles smoothly.
    return _sim.x(t * 0.42);
  }
}

/// Wraps any floating pill, orb, or chrome button with authentic Apple iOS 26/27
/// **press-hold anticipation lift + Liquid Glass menu bloom + continuous single-gesture
/// slide-to-select scrubbing** (plus desktop right-click parity).
///
/// - **Quick tap** (`< holdDuration`): zero delay, child's own `onTap` wins immediately.
/// - **Touch & hold** (`105ms → holdDuration`): subtle elastic swell (`1.0 → 1.055`) & specular
///   accent halo telegraphing the imminent Liquid Glass pop.
/// - **Commit** (`holdDuration`): `LongPressGestureRecognizer` wins the arena (automatically
///   cancelling child `onTap` so release never triggers a stray tap!), fires `mediumImpact()`,
///   lifts the trigger spotlight above a whisper-clean scrim, and blooms the anchored Liquid
///   Glass menu.
/// - **Single-gesture scrub**: keeping the thumb down and gliding onto any quick-action tile
///   or row glides a translucent Liquid Glass highlight capsule smoothly underneath with
///   `selectionClick()` haptics; lifting the thumb activates that option immediately!
/// - **Hold & lift**: releasing on the trigger keeps the menu gracefully open for tapping.
class GrassBagGlassLongPressTrigger extends StatefulWidget {
  const GrassBagGlassLongPressTrigger({
    super.key,
    required this.child,
    required this.tier,
    required this.menuBuilder,
    this.liftedBuilder,
    this.onWillOpen,
    this.enabled = true,
    this.enableSecondaryClick = true,
    this.holdDuration = const Duration(milliseconds: 340),
    this.anticipationBorderRadius = 18.0,
    this.isCircle = false,
  });

  final Widget child;
  final GrassBagGlassTier tier;
  final GrassBagLongPressMenuSpec? Function(BuildContext context) menuBuilder;
  final Widget Function(BuildContext context)? liftedBuilder;
  final VoidCallback? onWillOpen;
  final bool enabled;
  final bool enableSecondaryClick;
  final Duration holdDuration;
  final double anticipationBorderRadius;
  final bool isCircle;

  @override
  State<GrassBagGlassLongPressTrigger> createState() =>
      _GrassBagGlassLongPressTriggerState();
}

class _GrassBagGlassLongPressTriggerState
    extends State<GrassBagGlassLongPressTrigger>
    with SingleTickerProviderStateMixin {
  SingleSpringController? _chargeSpring;
  final _SpringTickProxy _tickProxy = _SpringTickProxy();
  Timer? _chargeTimer;
  int? _activePointerId;
  Offset _downGlobalPos = Offset.zero;
  bool _charging = false;
  bool _menuOpen = false;
  GlobalKey<_GrassBagGlassContextMenuViewState>? _activeMenuKey;

  void _ensureChargeSpring() {
    if (_chargeSpring != null) return;
    _chargeSpring = SingleSpringController(
      vsync: this,
      spring: GlassSpring.smooth(duration: const Duration(milliseconds: 220)),
      initialValue: 0.0,
    )..addListener(_tickProxy.notify);
  }

  void _cancelCharge({bool snap = false}) {
    _chargeTimer?.cancel();
    _chargeTimer = null;
    final wasCharging = _charging;
    _charging = false;
    final spring = _chargeSpring;
    if (spring != null && (wasCharging || spring.value.abs() > 0.001)) {
      if (snap || !mounted || MediaQuery.disableAnimationsOf(context)) {
        spring.setValue(0.0);
      } else {
        spring.spring = GlassSpring.snappy(duration: const Duration(milliseconds: 190));
        spring.animateTo(0.0);
      }
    }
  }

  void _startChargeTimer() {
    _chargeTimer?.cancel();
    final delayMs = math.min(105, widget.holdDuration.inMilliseconds ~/ 3);
    _chargeTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted || _activePointerId == null || _menuOpen) return;
      if (MediaQuery.disableAnimationsOf(context)) return;
      _charging = true;
      _ensureChargeSpring();
      _chargeSpring!.spring = GlassSpring.smooth(
        duration: Duration(
          milliseconds: math.max(140, widget.holdDuration.inMilliseconds - delayMs),
        ),
      );
      _chargeSpring!.animateTo(1.0);
    });
  }

  void _openMenu({
    required Offset fingerGlobalPos,
    required bool interactiveScrub,
  }) {
    if (!widget.enabled || _menuOpen || !mounted) return;
    final spec = widget.menuBuilder(context);
    if (spec == null || (spec.items.isEmpty && spec.quickActions.isEmpty)) {
      _cancelCharge();
      return;
    }
    final renderBox = context.findRenderObject();
    if (renderBox is! RenderBox || !renderBox.hasSize || !renderBox.attached) {
      _cancelCharge();
      return;
    }
    final targetRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
    final pointerId = interactiveScrub ? _activePointerId : null;
    _cancelCharge(snap: true);
    widget.onWillOpen?.call();

    final menuKey = GlobalKey<_GrassBagGlassContextMenuViewState>();
    _activeMenuKey = menuKey;
    setState(() => _menuOpen = true);

    _showGrassBagGlassContextMenuInternal(
      context,
      tier: widget.tier,
      items: spec.items,
      quickActions: spec.quickActions,
      headerTitle: spec.headerTitle,
      headerSubtitle: spec.headerSubtitle,
      menuWidth: spec.menuWidth,
      preferAbove: spec.preferAbove,
      targetRect: targetRect,
      globalAnchor: targetRect.center,
      liftedTriggerBuilder: widget.liftedBuilder,
      interactiveScrub: interactiveScrub,
      scrubPointerId: pointerId,
      initialFingerPosition: fingerGlobalPos,
      viewKey: menuKey,
    ).whenComplete(() {
      if (_activeMenuKey == menuKey) {
        _activeMenuKey = null;
      }
      _activePointerId = null;
      if (mounted && _menuOpen) {
        setState(() => _menuOpen = false);
      }
    });
  }

  @override
  void dispose() {
    _chargeTimer?.cancel();
    _chargeSpring?.removeListener(_tickProxy.notify);
    _chargeSpring?.dispose();
    _tickProxy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final t = GrassBagTokens.of(context);
    final hasLiftedSpotlight = widget.liftedBuilder != null;

    final animatedChild = ListenableBuilder(
      listenable: _tickProxy,
      child: Visibility(
        visible: !(_menuOpen && hasLiftedSpotlight),
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: widget.child,
      ),
      builder: (context, child) {
        final c = (_chargeSpring?.value ?? 0.0).clamp(0.0, 1.25);
        if (c < 0.002) return child!;
        final scale = 1.0 + 0.055 * c;
        final liftY = -1.8 * c;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..translateByDouble(0.0, liftY, 0.0, 1.0)
            ..scaleByDouble(scale, scale, 1.0, 1.0),
          child: CustomPaint(
            foregroundPainter: _LongPressChargeHaloPainter(
              progress: c.clamp(0.0, 1.0),
              color: t.primaryHi,
              isDark: t.isDark,
              isCircle: widget.isCircle,
              borderRadius: widget.anticipationBorderRadius,
            ),
            child: child!,
          ),
        );
      },
    );

    final gestures = <Type, GestureRecognizerFactory>{
      LongPressGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
        () => LongPressGestureRecognizer(
          duration: widget.holdDuration,
          debugOwner: this,
        ),
        (instance) {
          instance
            ..onLongPressStart = (details) {
              _openMenu(
                fingerGlobalPos: details.globalPosition,
                interactiveScrub: true,
              );
            }
            ..onLongPressMoveUpdate = (details) {
              _activeMenuKey?.currentState?.handleFallbackScrubMove(
                details.globalPosition,
              );
            }
            ..onLongPressEnd = (details) {
              _activeMenuKey?.currentState?.handleFallbackScrubEnd(
                details.globalPosition,
              );
            }
            ..onLongPressCancel = () {
              _cancelCharge();
            };
        },
      ),
      if (widget.enableSecondaryClick)
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          () => TapGestureRecognizer(debugOwner: this),
          (instance) {
            instance.onSecondaryTapUp = (details) {
              _openMenu(
                fingerGlobalPos: details.globalPosition,
                interactiveScrub: false,
              );
            };
          },
        ),
    };

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        // Only track primary touch / primary mouse button for press-hold anticipation.
        if (e.kind == PointerDeviceKind.mouse &&
            (e.buttons & kPrimaryMouseButton) == 0) {
          return;
        }
        if (_activePointerId != null || _menuOpen) return;
        _activePointerId = e.pointer;
        _downGlobalPos = e.position;
        _startChargeTimer();
      },
      onPointerMove: (e) {
        if (_activePointerId != e.pointer || _menuOpen) return;
        if ((e.position - _downGlobalPos).distance > 18.0) {
          _cancelCharge();
        }
      },
      onPointerUp: (e) {
        if (_activePointerId == e.pointer) {
          if (!_menuOpen) {
            _activePointerId = null;
          }
          _cancelCharge();
        }
      },
      onPointerCancel: (e) {
        if (_activePointerId == e.pointer) {
          if (!_menuOpen) {
            _activePointerId = null;
          }
          _cancelCharge();
        }
      },
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: gestures,
        child: animatedChild,
      ),
    );
  }
}

class _LongPressChargeHaloPainter extends CustomPainter {
  const _LongPressChargeHaloPainter({
    required this.progress,
    required this.color,
    required this.isDark,
    required this.isCircle,
    required this.borderRadius,
  });

  final double progress;
  final Color color;
  final bool isDark;
  final bool isCircle;
  final double borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.01) return;
    final rect = Offset.zero & size;
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = color.withValues(alpha: (isDark ? 0.42 : 0.34) * progress);
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: (isDark ? 0.12 : 0.08) * progress);
    if (isCircle) {
      final center = rect.center;
      final radius = math.min(size.width, size.height) * 0.5;
      canvas.drawCircle(center, radius, fillPaint);
      canvas.drawCircle(center, radius - 0.5, glowPaint);
    } else {
      final r = math.min(borderRadius, math.min(size.width, size.height) * 0.5);
      final shape = RSuperellipse.fromRectAndRadius(rect, Radius.circular(r));
      canvas.drawRSuperellipse(shape, fillPaint);
      canvas.drawRSuperellipse(shape.deflate(0.5), glowPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _LongPressChargeHaloPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.isDark != isDark ||
      oldDelegate.isCircle != isCircle ||
      oldDelegate.borderRadius != borderRadius;
}

/// Anchored Apple iOS 26/27 floating Liquid Glass popup context menu with:
/// - Underdamped iOS 27 spring bloom from the trigger's exact bounding rect
/// - Continuous translucent sliding Liquid Glass selection lens (`AnimatedPositioned`)
/// - Optional compact top horizontal [quickActions] strip
/// - Optional lifted trigger spotlight floating cleanly above a whisper-light scrim
/// - Single-gesture press-hold-slide-release scrubbing + desktop hover & right-click parity
Future<void> showGrassBagGlassContextMenu(
  BuildContext context, {
  required List<GrassBagContextMenuItem> items,
  required GrassBagGlassTier tier,
  List<GrassBagContextMenuQuickAction> quickActions = const [],
  Offset? globalAnchor,
  Rect? targetRect,
  String? headerTitle,
  String? headerSubtitle,
  double? menuWidth,
  bool? preferAbove,
  Widget Function(BuildContext context)? liftedTriggerBuilder,
}) =>
    _showGrassBagGlassContextMenuInternal(
      context,
      items: items,
      tier: tier,
      quickActions: quickActions,
      globalAnchor: globalAnchor,
      targetRect: targetRect,
      headerTitle: headerTitle,
      headerSubtitle: headerSubtitle,
      menuWidth: menuWidth,
      preferAbove: preferAbove,
      liftedTriggerBuilder: liftedTriggerBuilder,
    );

VoidCallback? _activeGlassContextMenuClose;

Future<void> _showGrassBagGlassContextMenuInternal(
  BuildContext context, {
  required List<GrassBagContextMenuItem> items,
  required GrassBagGlassTier tier,
  List<GrassBagContextMenuQuickAction> quickActions = const [],
  Offset? globalAnchor,
  Rect? targetRect,
  String? headerTitle,
  String? headerSubtitle,
  double? menuWidth,
  bool? preferAbove,
  Widget Function(BuildContext context)? liftedTriggerBuilder,
  bool interactiveScrub = false,
  int? scrubPointerId,
  Offset? initialFingerPosition,
  GlobalKey<_GrassBagGlassContextMenuViewState>? viewKey,
}) async {
  if (items.isEmpty && quickActions.isEmpty) return;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _activeGlassContextMenuClose?.call();
  HapticFeedback.mediumImpact();
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final capturedThemes = InheritedTheme.capture(
    from: context,
    to: overlay.context,
  );
  final completer = Completer<void>();
  var removed = false;
  late final OverlayEntry entry;

  void finishCompleter() {
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  void removeEntry() {
    if (removed) return;
    removed = true;
    if (_activeGlassContextMenuClose == removeEntry) {
      _activeGlassContextMenuClose = null;
    }
    if (entry.mounted) {
      entry.remove();
    }
    finishCompleter();
  }

  void handleViewDisposed() {
    removed = true;
    if (_activeGlassContextMenuClose == removeEntry) {
      _activeGlassContextMenuClose = null;
    }
    finishCompleter();
  }

  // Hosted directly in the root Overlay (instead of Navigator.push) so active
  // touch pointers are NEVER cancelled by NavigatorState._cancelActivePointers()
  // — enabling true native iOS 27 continuous press-hold-slide-release scrubbing!
  entry = OverlayEntry(
    builder: (overlayContext) => capturedThemes.wrap(
      _GrassBagGlassContextMenuView(
        key: viewKey,
        items: items,
        quickActions: quickActions,
        tier: tier,
        reduceMotion: reduceMotion,
        globalAnchor: globalAnchor,
        targetRect: targetRect,
        headerTitle: headerTitle,
        headerSubtitle: headerSubtitle,
        menuWidth: menuWidth,
        preferAbove: preferAbove,
        liftedTriggerBuilder: liftedTriggerBuilder,
        interactiveScrub: interactiveScrub,
        scrubPointerId: scrubPointerId,
        initialFingerPosition: initialFingerPosition,
        onRequestRemove: removeEntry,
        onDisposed: handleViewDisposed,
      ),
    ),
  );
  _activeGlassContextMenuClose = removeEntry;
  overlay.insert(entry);
  return completer.future;
}

class _GrassBagGlassContextMenuView extends StatefulWidget {
  const _GrassBagGlassContextMenuView({
    super.key,
    required this.items,
    required this.quickActions,
    required this.tier,
    required this.reduceMotion,
    required this.onRequestRemove,
    required this.onDisposed,
    this.globalAnchor,
    this.targetRect,
    this.headerTitle,
    this.headerSubtitle,
    this.menuWidth,
    this.preferAbove,
    this.liftedTriggerBuilder,
    this.interactiveScrub = false,
    this.scrubPointerId,
    this.initialFingerPosition,
  });

  final List<GrassBagContextMenuItem> items;
  final List<GrassBagContextMenuQuickAction> quickActions;
  final GrassBagGlassTier tier;
  final bool reduceMotion;
  final VoidCallback onRequestRemove;
  final VoidCallback onDisposed;
  final Offset? globalAnchor;
  final Rect? targetRect;
  final String? headerTitle;
  final String? headerSubtitle;
  final double? menuWidth;
  final bool? preferAbove;
  final Widget Function(BuildContext context)? liftedTriggerBuilder;
  final bool interactiveScrub;
  final int? scrubPointerId;
  final Offset? initialFingerPosition;

  @override
  State<_GrassBagGlassContextMenuView> createState() =>
      _GrassBagGlassContextMenuViewState();
}

class _GrassBagGlassContextMenuViewState
    extends State<_GrassBagGlassContextMenuView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const Curve _bloomCurve = _GrassBagSpringBloomCurve();

  late final List<GlobalKey> _quickKeys;
  late final List<GlobalKey> _rowKeys;
  final GlobalKey _quickStripKey = GlobalKey();
  final GlobalKey _listStackKey = GlobalKey();

  bool _scrubActive = false;
  int? _scrubPointerId;
  late final bool _usingPointerRouter;
  late Offset _initialFingerPos;
  bool _scrubArmed = false;
  bool _didPop = false;

  int? _hoveredQuickIndex;
  Rect? _hoveredQuickRect;
  int? _hoveredRowIndex;
  Rect? _hoveredRowRect;

  late final AnimationController _controller;
  late CurvedAnimation _scrimCurve;
  late CurvedAnimation _springBloomAnim;

  @override
  void initState() {
    super.initState();
    _quickKeys = List<GlobalKey>.generate(widget.quickActions.length, (_) => GlobalKey());
    _rowKeys = List<GlobalKey>.generate(widget.items.length, (_) => GlobalKey());
    _scrubActive = widget.interactiveScrub || widget.scrubPointerId != null;
    _scrubPointerId = widget.scrubPointerId;
    _usingPointerRouter = _scrubActive;
    _initialFingerPos = widget.initialFingerPosition ??
        widget.targetRect?.center ??
        widget.globalAnchor ??
        Offset.zero;
    _controller = AnimationController(
      vsync: this,
      duration: widget.reduceMotion
          ? const Duration(milliseconds: 80)
          : const Duration(milliseconds: 300),
      reverseDuration: widget.reduceMotion
          ? const Duration(milliseconds: 70)
          : const Duration(milliseconds: 190),
    );
    _initAnimations();
    _controller.forward();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    if (_usingPointerRouter) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_handleGlobalPointer);
    }
  }

  void _initAnimations() {
    _scrimCurve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _springBloomAnim = CurvedAnimation(
      parent: _controller,
      curve: _bloomCurve,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  Future<bool> didPopRoute() async {
    if (!mounted || _didPop) return false;
    _dismiss();
    return true;
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!mounted || _didPop) return false;
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      _dismiss();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    if (_usingPointerRouter) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_handleGlobalPointer);
    }
    _scrimCurve.dispose();
    _springBloomAnim.dispose();
    _controller.dispose();
    widget.onDisposed();
    super.dispose();
  }

  void _beginClose({VoidCallback? onAfterStart}) {
    if (_didPop) return;
    _didPop = true;
    _scrubActive = false;
    _scrubPointerId = null;
    if (mounted) {
      setState(() {});
    }
    onAfterStart?.call();
    _controller.reverse().whenComplete(() {
      widget.onRequestRemove();
    });
  }

  void _dismiss() {
    if (_didPop || !mounted) return;
    _beginClose();
  }

  void _activateRow(int index) {
    if (_didPop || index < 0 || index >= widget.items.length) return;
    final item = widget.items[index];
    if (!item.enabled) return;
    HapticFeedback.selectionClick();
    _beginClose(onAfterStart: item.onTap);
  }

  void _activateQuickAction(int index) {
    if (_didPop || index < 0 || index >= widget.quickActions.length) return;
    final qa = widget.quickActions[index];
    if (!qa.enabled) return;
    HapticFeedback.selectionClick();
    _beginClose(onAfterStart: qa.onTap);
  }

  void _handleGlobalPointer(PointerEvent event) {
    if (!mounted || _didPop || !_scrubActive) return;
    if (event is PointerDownEvent) {
      // A new touch arrived after the menu opened -> normal tap mode, stop initial scrub!
      _scrubActive = false;
      _scrubPointerId = null;
      return;
    }
    _scrubPointerId ??= event.pointer;
    if (event.pointer != _scrubPointerId) return;
    if (event is PointerMoveEvent) {
      if (!_scrubArmed && (event.position - _initialFingerPos).distance >= 8.0) {
        _scrubArmed = true;
      }
      if (_scrubArmed) {
        _updateScrubAt(event.position);
      }
    } else if (event is PointerUpEvent) {
      _scrubActive = false;
      _scrubPointerId = null;
      if (_scrubArmed) {
        _updateScrubAt(event.position);
        _commitScrubIfHovered();
      } else {
        _clearHover();
      }
    } else if (event is PointerCancelEvent) {
      _scrubActive = false;
      _scrubPointerId = null;
      _clearHover();
    }
  }

  void handleFallbackScrubMove(Offset globalPos) {
    if (!mounted || _didPop || _usingPointerRouter) return;
    if (!_scrubArmed && (globalPos - _initialFingerPos).distance >= 8.0) {
      _scrubArmed = true;
    }
    if (_scrubArmed) {
      _updateScrubAt(globalPos);
    }
  }

  void handleFallbackScrubEnd(Offset globalPos) {
    if (!mounted || _didPop || _usingPointerRouter) return;
    if (_scrubArmed) {
      _updateScrubAt(globalPos);
      _commitScrubIfHovered();
    } else {
      _clearHover();
    }
  }

  void _clearHover() {
    if (!mounted) return;
    if (_hoveredRowIndex != null || _hoveredQuickIndex != null) {
      setState(() {
        _hoveredRowIndex = null;
        _hoveredQuickIndex = null;
      });
    }
  }

  Rect? _measureRelativeRect(GlobalKey itemKey, GlobalKey containerKey) {
    final itemBox = itemKey.currentContext?.findRenderObject();
    final hostBox = containerKey.currentContext?.findRenderObject();
    if (itemBox is! RenderBox ||
        hostBox is! RenderBox ||
        !itemBox.hasSize ||
        !hostBox.hasSize ||
        !itemBox.attached ||
        !hostBox.attached) {
      return null;
    }
    final topLeft = itemBox.localToGlobal(Offset.zero, ancestor: hostBox);
    return topLeft & itemBox.size;
  }

  void _setHoveredRow(int? index, {bool withHaptic = false}) {
    if (!mounted) return;
    if (index == null) {
      if (_hoveredRowIndex != null) {
        setState(() => _hoveredRowIndex = null);
      }
      return;
    }
    if (index < 0 || index >= widget.items.length || !widget.items[index].enabled) {
      return;
    }
    final rect = _measureRelativeRect(_rowKeys[index], _listStackKey);
    final changed = _hoveredRowIndex != index || _hoveredQuickIndex != null;
    setState(() {
      _hoveredQuickIndex = null;
      _hoveredRowIndex = index;
      if (rect != null) _hoveredRowRect = rect;
    });
    if (changed && withHaptic) {
      HapticFeedback.selectionClick();
    }
  }

  void _setHoveredQuick(int? index, {bool withHaptic = false}) {
    if (!mounted) return;
    if (index == null) {
      if (_hoveredQuickIndex != null) {
        setState(() => _hoveredQuickIndex = null);
      }
      return;
    }
    if (index < 0 ||
        index >= widget.quickActions.length ||
        !widget.quickActions[index].enabled) {
      return;
    }
    final rect = _measureRelativeRect(_quickKeys[index], _quickStripKey);
    final changed = _hoveredQuickIndex != index || _hoveredRowIndex != null;
    setState(() {
      _hoveredRowIndex = null;
      _hoveredQuickIndex = index;
      if (rect != null) _hoveredQuickRect = rect;
    });
    if (changed && withHaptic) {
      HapticFeedback.selectionClick();
    }
  }

  void _updateScrubAt(Offset globalPos) {
    if (!_scrubArmed) return;
    // 1. Check horizontal quick-action tiles first
    for (var i = 0; i < _quickKeys.length; i++) {
      if (!widget.quickActions[i].enabled) continue;
      final box = _quickKeys[i].currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize && box.attached) {
        final p0 = box.localToGlobal(Offset.zero);
        final p1 = box.localToGlobal(box.size.bottomRight(Offset.zero));
        if ((p1.dx - p0.dx).abs() < 4.0 || (p1.dy - p0.dy).abs() < 4.0) {
          continue;
        }
        final globalRect = Rect.fromPoints(p0, p1).inflate(4.0);
        if (globalRect.contains(globalPos)) {
          _setHoveredQuick(i, withHaptic: true);
          return;
        }
      }
    }
    // 2. Check vertical menu rows
    for (var i = 0; i < _rowKeys.length; i++) {
      if (!widget.items[i].enabled) continue;
      final box = _rowKeys[i].currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize && box.attached) {
        final p0 = box.localToGlobal(Offset.zero);
        final p1 = box.localToGlobal(box.size.bottomRight(Offset.zero));
        if ((p1.dx - p0.dx).abs() < 4.0 || (p1.dy - p0.dy).abs() < 4.0) {
          continue;
        }
        final rawRect = Rect.fromPoints(p0, p1);
        // Gentle horizontal grace margin so thumb scrubbing feels effortless like native iOS!
        final hitRect = Rect.fromLTRB(
          rawRect.left - 8.0,
          rawRect.top,
          rawRect.right + 8.0,
          rawRect.bottom,
        );
        if (hitRect.contains(globalPos)) {
          _setHoveredRow(i, withHaptic: true);
          return;
        }
      }
    }
    _clearHover();
  }

  void _commitScrubIfHovered() {
    if (!_scrubArmed) {
      _clearHover();
      return;
    }
    if (_hoveredQuickIndex != null) {
      final idx = _hoveredQuickIndex!;
      _clearHover();
      _activateQuickAction(idx);
      return;
    }
    if (_hoveredRowIndex != null) {
      final idx = _hoveredRowIndex!;
      _clearHover();
      _activateRow(idx);
      return;
    }
    _clearHover();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final media = MediaQuery.of(context);
    final size = media.size;
    final safePad = media.padding;
    final effectiveBottom = math.max(safePad.bottom, media.viewInsets.bottom);
    final textScale = media.textScaler.scale(1.0).clamp(1.0, 1.45);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final hasHeader = (widget.headerTitle != null && widget.headerTitle!.trim().isNotEmpty) ||
        (widget.headerSubtitle != null && widget.headerSubtitle!.trim().isNotEmpty);
    final hasQuick = widget.quickActions.isNotEmpty;

    final double menuW = (widget.menuWidth ?? (hasQuick ? 256.0 : 244.0))
        .clamp(210.0, math.max(210.0, size.width - 24.0))
        .toDouble();

    final estHeaderH = hasHeader
        ? ((widget.headerSubtitle != null && widget.headerSubtitle!.trim().isNotEmpty)
            ? 46.0
            : 34.0)
        : 0.0;
    final estQuickH = hasQuick ? 68.0 : 0.0;
    final estItemsH = widget.items.fold<double>(
      14.0,
      (acc, it) =>
          acc +
          (it.subtitle != null && it.subtitle!.isNotEmpty ? 54.0 : 44.0) +
          (it.dividerBefore ? 7.0 : 0.0),
    );
    final estH = (estHeaderH + estQuickH + estItemsH) * textScale;

    final targetRect = widget.targetRect;
    final bool openDown;
    final double left;
    final double? topPos;
    final double? bottomPos;
    final double maxPlatterH;
    final double alignX;

    if (targetRect != null) {
      final spaceAbove = math.max(0.0, targetRect.top - safePad.top - 22.0);
      final spaceBelow =
          math.max(0.0, (size.height - effectiveBottom) - targetRect.bottom - 22.0);
      if (widget.preferAbove == true) {
        openDown = spaceAbove < math.min(estH, 160.0) && spaceBelow > spaceAbove;
      } else if (widget.preferAbove == false) {
        openDown = spaceBelow >= math.min(estH, 160.0) || spaceBelow >= spaceAbove;
      } else {
        openDown = spaceBelow >= estH || spaceBelow >= spaceAbove;
      }

      // Natural iOS horizontal alignment: center if trigger is centered, else match nearest edge!
      final triggerCenterX = targetRect.center.dx;
      final nearCenter = (triggerCenterX - size.width * 0.5).abs() < 60.0;
      final rawLeft = nearCenter
          ? triggerCenterX - menuW * 0.5
          : (triggerCenterX < size.width * 0.5
              ? targetRect.left
              : targetRect.right - menuW);
      left = rawLeft.clamp(12.0, math.max(12.0, size.width - menuW - 12.0));
      alignX = ((triggerCenterX - left) / menuW * 2.0 - 1.0).clamp(-0.92, 0.92);

      if (openDown) {
        topPos = (targetRect.bottom + 10.0).clamp(
          safePad.top + 12.0,
          math.max(safePad.top + 12.0, size.height - effectiveBottom - 130.0),
        );
        bottomPos = null;
        maxPlatterH = math.max(120.0, size.height - effectiveBottom - topPos - 12.0);
      } else {
        bottomPos = (size.height - targetRect.top + 10.0).clamp(
          effectiveBottom + 12.0,
          math.max(effectiveBottom + 12.0, size.height - safePad.top - 130.0),
        );
        topPos = null;
        maxPlatterH = math.max(120.0, size.height - bottomPos - safePad.top - 12.0);
      }
    } else {
      final availH = math.max(120.0, size.height - safePad.top - effectiveBottom - 24.0);
      final menuH = math.min(estH, availH);
      final rawAnchor = widget.globalAnchor ?? Offset(size.width * 0.5, size.height * 0.45);
      final openRight = rawAnchor.dx + menuW + 14 <= size.width;
      openDown = widget.preferAbove == true
          ? false
          : (rawAnchor.dy + menuH + effectiveBottom + 18 <= size.height);
      left = (openRight ? rawAnchor.dx - 16 : rawAnchor.dx - menuW + 16)
          .clamp(12.0, math.max(12.0, size.width - menuW - 12.0));
      if (openDown) {
        topPos = (rawAnchor.dy + 6).clamp(
          safePad.top + 12.0,
          math.max(safePad.top + 12.0, size.height - effectiveBottom - menuH - 12.0),
        );
        bottomPos = null;
      } else {
        bottomPos = (size.height - rawAnchor.dy + 6).clamp(
          effectiveBottom + 12.0,
          math.max(effectiveBottom + 12.0, size.height - safePad.top - 120.0),
        );
        topPos = null;
      }
      maxPlatterH = availH - 12.0;
      alignX = ((rawAnchor.dx - left) / menuW * 2.0 - 1.0).clamp(-0.92, 0.92);
    }

    final alignY = openDown ? -0.94 : 0.94;
    final scrimColor =
        t.isDark ? const Color(0x4E05080F) : const Color(0x1E0D1A2B);

    final hoveredRowIsDestructive = _hoveredRowIndex != null &&
        _hoveredRowIndex! < widget.items.length &&
        widget.items[_hoveredRowIndex!].destructive;
    final hoveredQuickIsDestructive = _hoveredQuickIndex != null &&
        _hoveredQuickIndex! < widget.quickActions.length &&
        widget.quickActions[_hoveredQuickIndex!].destructive;

    final platterContent = Material(
      type: MaterialType.transparency,
      child: GrassBagGlass(
        tier: widget.tier,
        borderRadius: 26,
        elevated: true,
        useSheetSettings: true,
        interactiveGlow: false,
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 7),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxPlatterH),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasHeader) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 5, 12, 7),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.headerTitle != null &&
                            widget.headerTitle!.trim().isNotEmpty)
                          Text(
                            widget.headerTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.0,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.1,
                              color: t.text2,
                            ),
                          ),
                        if (widget.headerSubtitle != null &&
                            widget.headerSubtitle!.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 1.5),
                            child: Text(
                              widget.headerSubtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w500,
                                color: t.text3,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Divider(
                    height: 0.5,
                    thickness: 0.5,
                    indent: 8,
                    endIndent: 8,
                    color: t.sep,
                  ),
                  const SizedBox(height: 4),
                ],
                if (hasQuick) ...[
                  Stack(
                    key: _quickStripKey,
                    children: [
                      if (_hoveredQuickRect != null)
                        AnimatedPositioned(
                          duration: GrassBagMotion.duration(
                            context,
                            const Duration(milliseconds: 145),
                          ),
                          curve: Curves.easeOutCubic,
                          left: _hoveredQuickRect!.left,
                          top: _hoveredQuickRect!.top,
                          width: _hoveredQuickRect!.width,
                          height: _hoveredQuickRect!.height,
                          child: IgnorePointer(
                            child: AnimatedOpacity(
                              opacity: _hoveredQuickIndex != null ? 1.0 : 0.0,
                              duration: GrassBagMotion.duration(
                                context,
                                const Duration(milliseconds: 110),
                              ),
                              child: _LiquidMenuSelectionLens(
                                borderRadius: 16,
                                destructive: hoveredQuickIsDestructive,
                              ),
                            ),
                          ),
                        ),
                      Row(
                        children: [
                          for (var i = 0; i < widget.quickActions.length; i++) ...[
                            if (i > 0) const SizedBox(width: 4),
                            Expanded(
                              child: _GrassBagContextMenuQuickTile(
                                key: _quickKeys[i],
                                action: widget.quickActions[i],
                                activeHover: _hoveredQuickIndex == i,
                                onHoverChanged: (hovering) {
                                  if (hovering) {
                                    _setHoveredQuick(i);
                                  } else if (_hoveredQuickIndex == i) {
                                    _setHoveredQuick(null);
                                  }
                                },
                                onSelect: () => _activateQuickAction(i),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                  if (widget.items.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Divider(
                      height: 0.5,
                      thickness: 0.5,
                      indent: 8,
                      endIndent: 8,
                      color: t.sep,
                    ),
                    const SizedBox(height: 4),
                  ],
                ],
                if (widget.items.isNotEmpty)
                  Stack(
                    key: _listStackKey,
                    children: [
                      if (_hoveredRowRect != null)
                        AnimatedPositioned(
                          duration: GrassBagMotion.duration(
                            context,
                            const Duration(milliseconds: 145),
                          ),
                          curve: Curves.easeOutCubic,
                          left: 0,
                          right: 0,
                          top: _hoveredRowRect!.top,
                          height: _hoveredRowRect!.height,
                          child: IgnorePointer(
                            child: AnimatedOpacity(
                              opacity: _hoveredRowIndex != null ? 1.0 : 0.0,
                              duration: GrassBagMotion.duration(
                                context,
                                const Duration(milliseconds: 110),
                              ),
                              child: _LiquidMenuSelectionLens(
                                borderRadius: 16,
                                destructive: hoveredRowIsDestructive,
                              ),
                            ),
                          ),
                        ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < widget.items.length; i++) ...[
                            if (widget.items[i].dividerBefore && i > 0)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 3.5),
                                child: Divider(
                                  height: 0.5,
                                  thickness: 0.5,
                                  indent: 10,
                                  endIndent: 10,
                                  color: t.sep,
                                ),
                              ),
                            _GrassBagContextMenuRow(
                              key: _rowKeys[i],
                              item: widget.items[i],
                              activeHover: _hoveredRowIndex == i,
                              onHoverChanged: (hovering) {
                                if (hovering) {
                                  _setHoveredRow(i);
                                } else if (_hoveredRowIndex == i) {
                                  _setHoveredRow(null);
                                }
                              },
                              onSelect: () => _activateRow(i),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    return IgnorePointer(
      ignoring: _didPop,
      child: Stack(
        children: [
          // 1. Whisper-clean iOS 27 dimming scrim
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _dismiss,
              child: AnimatedBuilder(
                animation: _scrimCurve,
                builder: (_, __) => ColoredBox(
                  color: scrimColor.withValues(alpha: scrimColor.a * _scrimCurve.value),
                ),
              ),
            ),
          ),

          // 2. Lifted Trigger Spotlight floating above the scrim
          if (targetRect != null && widget.liftedTriggerBuilder != null)
            Positioned(
              left: targetRect.left,
              top: targetRect.top,
              width: targetRect.width,
              height: targetRect.height,
              child: AnimatedBuilder(
                animation: _springBloomAnim,
                builder: (ctx, child) {
                  final v = _springBloomAnim.value;
                  final liftScale = reduceMotion ? 1.0 : (1.0 + 0.042 * v);
                  final liftDy = reduceMotion ? 0.0 : (openDown ? -1.5 : 1.5) * v;
                  return Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..translateByDouble(0.0, liftDy, 0.0, 1.0)
                      ..scaleByDouble(liftScale, liftScale, 1.0, 1.0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(
                          math.min(targetRect.width, targetRect.height) * 0.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: (t.isDark ? 0.44 : 0.16) * v.clamp(0.0, 1.0),
                            ),
                            blurRadius: 22.0,
                            spreadRadius: -2.0,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: child,
                    ),
                  );
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _dismiss,
                  child: Material(
                    type: MaterialType.transparency,
                    child: IgnorePointer(
                      child: widget.liftedTriggerBuilder!(context),
                    ),
                  ),
                ),
              ),
            ),

          // 3. Anchored iOS 27 Liquid Glass Platter with spring bloom
          Positioned(
            left: left,
            top: topPos,
            bottom: bottomPos,
            width: menuW,
            child: AnimatedBuilder(
              animation: _springBloomAnim,
              child: GrassBagMaterializeTransition(
                animation: _controller,
                tier: widget.tier,
                alignment: Alignment(alignX, alignY),
                scaleFrom: 1.0,
                contentSigma: 4.5,
                child: platterContent,
              ),
              builder: (context, child) {
                if (reduceMotion) return child!;
                final s = 0.80 + 0.20 * _springBloomAnim.value;
                final dy = (openDown ? -8.0 : 8.0) * (1.0 - _springBloomAnim.value.clamp(0.0, 1.15));
                return Transform(
                  alignment: Alignment(alignX, alignY),
                  transform: Matrix4.identity()
                    ..translateByDouble(0.0, dy, 0.0, 1.0)
                    ..scaleByDouble(s, s, 1.0, 1.0),
                  child: child,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Luminous translucent Apple iOS 27 sliding glass lens highlight pill gliding smoothly
/// behind hovered/scrubbed rows and quick-action tiles (zero nested BackdropFilter!).
class _LiquidMenuSelectionLens extends StatelessWidget {
  const _LiquidMenuSelectionLens({
    required this.borderRadius,
    this.destructive = false,
  });

  final double borderRadius;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final fillColor = destructive
        ? t.err.withValues(alpha: t.isDark ? 0.24 : 0.13)
        : (t.isDark
            ? Colors.white.withValues(alpha: 0.14)
            : Colors.black.withValues(alpha: 0.075));
    final rimColor = destructive
        ? t.err.withValues(alpha: t.isDark ? 0.34 : 0.24)
        : (t.isDark
            ? Colors.white.withValues(alpha: 0.20)
            : Colors.white.withValues(alpha: 0.65));
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: fillColor,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(borderRadius),
          side: BorderSide(color: rimColor, width: 0.55),
        ),
      ),
    );
  }
}

class _GrassBagContextMenuQuickTile extends StatefulWidget {
  const _GrassBagContextMenuQuickTile({
    super.key,
    required this.action,
    required this.activeHover,
    required this.onHoverChanged,
    required this.onSelect,
  });

  final GrassBagContextMenuQuickAction action;
  final bool activeHover;
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onSelect;

  @override
  State<_GrassBagContextMenuQuickTile> createState() =>
      _GrassBagContextMenuQuickTileState();
}

class _GrassBagContextMenuQuickTileState
    extends State<_GrassBagContextMenuQuickTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final a = widget.action;
    final fg = !a.enabled
        ? t.text3.withValues(alpha: 0.45)
        : (a.destructive
            ? t.err
            : (a.selected ? (a.accentColor ?? t.primary) : (a.accentColor ?? t.text)));
    final baseFill = a.selected
        ? (a.accentColor ?? t.primary).withValues(alpha: t.isDark ? 0.18 : 0.10)
        : (t.isDark
            ? Colors.white.withValues(alpha: 0.055)
            : Colors.black.withValues(alpha: 0.032));
    final active = _pressed || widget.activeHover;

    return Semantics(
      button: true,
      enabled: a.enabled,
      selected: a.selected,
      label: a.label,
      child: MouseRegion(
        cursor: a.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => widget.onHoverChanged(true),
        onExit: (_) => widget.onHoverChanged(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: a.enabled
              ? (_) {
                  setState(() => _pressed = true);
                  widget.onHoverChanged(true);
                }
              : null,
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () {
            setState(() => _pressed = false);
            widget.onHoverChanged(false);
          },
          onTap: a.enabled ? widget.onSelect : null,
          child: AnimatedScale(
            scale: active && !MediaQuery.disableAnimationsOf(context) ? 0.96 : 1.0,
            duration: GrassBagMotion.duration(context, const Duration(milliseconds: 110)),
            curve: Curves.easeOutCubic,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: widget.activeHover ? Colors.transparent : baseFill,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: a.selected && !widget.activeHover
                        ? (a.accentColor ?? t.primary).withValues(alpha: t.isDark ? 0.30 : 0.22)
                        : Colors.transparent,
                    width: 0.6,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(a.icon, size: 18, color: fg),
                    const SizedBox(height: 4),
                    Text(
                      a.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: a.selected || active ? FontWeight.w600 : FontWeight.w500,
                        letterSpacing: -0.1,
                        color: fg,
                      ),
                    ),
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

class _GrassBagContextMenuRow extends StatefulWidget {
  const _GrassBagContextMenuRow({
    super.key,
    required this.item,
    required this.activeHover,
    required this.onHoverChanged,
    required this.onSelect,
  });

  final GrassBagContextMenuItem item;
  final bool activeHover;
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onSelect;

  @override
  State<_GrassBagContextMenuRow> createState() => _GrassBagContextMenuRowState();
}

class _GrassBagContextMenuRowState extends State<_GrassBagContextMenuRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final item = widget.item;
    final accent = item.accentColor ?? t.primary;
    final fg = !item.enabled
        ? t.text3.withValues(alpha: 0.45)
        : (item.destructive
            ? t.err
            : (item.selected ? accent : t.text));
    final iconColor = !item.enabled
        ? t.text3.withValues(alpha: 0.40)
        : (item.destructive
            ? t.err
            : (item.selected
                ? accent
                : (item.accentColor ?? t.text.withValues(alpha: 0.86))));
    final staticSelectedBg = item.selected && !widget.activeHover
        ? accent.withValues(alpha: t.isDark ? 0.14 : 0.085)
        : Colors.transparent;
    final pressedOrScrubbed = _pressed || widget.activeHover;

    return Semantics(
      button: true,
      enabled: item.enabled,
      selected: item.selected,
      label: item.label,
      child: MouseRegion(
        cursor: item.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => widget.onHoverChanged(true),
        onExit: (_) => widget.onHoverChanged(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: item.enabled
              ? (_) {
                  setState(() => _pressed = true);
                  widget.onHoverChanged(true);
                }
              : null,
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () {
            setState(() => _pressed = false);
            widget.onHoverChanged(false);
          },
          onTap: item.enabled ? widget.onSelect : null,
          child: AnimatedScale(
            scale: pressedOrScrubbed && !MediaQuery.disableAnimationsOf(context)
                ? 0.985
                : 1.0,
            duration: GrassBagMotion.duration(context, const Duration(milliseconds: 110)),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: GrassBagMotion.duration(context, const Duration(milliseconds: 110)),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9.5),
              decoration: ShapeDecoration(
                color: staticSelectedBg,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: item.selected && !widget.activeHover
                        ? accent.withValues(alpha: t.isDark ? 0.28 : 0.20)
                        : Colors.transparent,
                    width: 0.6,
                  ),
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: Center(
                      child: Icon(item.icon, size: 17, color: iconColor),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                item.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: item.selected || item.destructive || widget.activeHover
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  letterSpacing: -0.15,
                                  color: fg,
                                ),
                              ),
                            ),
                            if (item.badge != null && item.badge!.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5.5,
                                  vertical: 1.2,
                                ),
                                decoration: ShapeDecoration(
                                  color: accent.withValues(alpha: t.isDark ? 0.18 : 0.11),
                                  shape: const StadiumBorder(),
                                ),
                                child: Text(
                                  item.badge!,
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w600,
                                    color: accent,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (item.subtitle != null && item.subtitle!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 1.5),
                            child: Text(
                              item.subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: widget.activeHover ? t.text2 : t.text3,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (item.trailing != null) ...[
                    const SizedBox(width: 8),
                    item.trailing!,
                  ],
                  if (item.selected) ...[
                    const SizedBox(width: 8),
                    Icon(CupertinoIcons.checkmark_alt, size: 15.5, color: accent),
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

/// Joins an ancestor [SelectionArea] when already mounted inside one (e.g. the unified
/// chat [CustomScrollView] selection area), or mounts a local [SelectionArea] when
/// rendered standalone (e.g. isolated sheets or unit tests).
///
/// Avoiding nested [SelectionArea]s inside a scrollable is critical in Flutter: only a
/// [Scrollable] *descendant* of [SelectionArea] mounts `_ScrollableSelectionHandler`
/// and supports continuous cross-viewport edge auto-scrolling.
class GrassBagSelectableScope extends StatelessWidget {
  const GrassBagSelectableScope({
    super.key,
    required this.child,
    this.onSelectionChanged,
    this.contextMenuBuilder = buildGrassBagSelectableContextMenu,
  });

  final Widget child;
  final ValueChanged<SelectedContent?>? onSelectionChanged;
  final SelectableRegionContextMenuBuilder contextMenuBuilder;

  @override
  Widget build(BuildContext context) {
    if (SelectionContainer.maybeOf(context) != null) {
      return child;
    }
    return SelectionArea(
      onSelectionChanged: onSelectionChanged,
      contextMenuBuilder: contextMenuBuilder,
      child: child,
    );
  }
}

/// Edge-inset-aware auto-scroller placed *inside* a [SelectionArea] and *outside* a
/// vertical [ScrollView] (`CustomScrollView`, `ListView`, `SingleChildScrollView`).
///
/// Flutter's built-in `EdgeDraggingAutoScroller` only triggers when the dragged selection
/// edge moves strictly *outside* the scroll view's raw `RenderBox` bounds — which is
/// unreachable on edge-to-edge screens where floating Liquid Glass top headers and bottom
/// composer bars overlap the scroll view, and does not auto-scroll during mobile
/// long-press-drag (`continuous: false`).
///
/// This scope accounts for [topEdgeInset] / [bottomEdgeInset] (or dynamic resolvers) plus
/// a smooth [hotZoneExtent] inside the visible reading band, scrolls smoothly at
/// frame-rate-independent velocity, prevents blind overshoot behind floating bars while
/// scrolling, and supports BOTH teardrop handle dragging and long-press-and-drag.
class GrassBagSelectionAutoScrollScope extends StatefulWidget {
  const GrassBagSelectionAutoScrollScope({
    super.key,
    required this.scrollController,
    required this.child,
    this.topEdgeInset = 0.0,
    this.bottomEdgeInset = 0.0,
    this.resolveTopEdgeInset,
    this.resolveBottomEdgeInset,
    this.hotZoneExtent = 56.0,
    this.onAutoScrollActiveChanged,
    this.onAutoScrollStep,
  });

  final ScrollController scrollController;
  final Widget child;
  final double topEdgeInset;
  final double bottomEdgeInset;
  final double Function()? resolveTopEdgeInset;
  final double Function()? resolveBottomEdgeInset;
  final double hotZoneExtent;
  final ValueChanged<bool>? onAutoScrollActiveChanged;
  final ValueChanged<double>? onAutoScrollStep;

  @override
  State<GrassBagSelectionAutoScrollScope> createState() =>
      _GrassBagSelectionAutoScrollScopeState();
}

class _GrassBagSelectionAutoScrollScopeState
    extends State<GrassBagSelectionAutoScrollScope>
    with SingleTickerProviderStateMixin {
  late final _EdgeInsetAutoScrollSelectionDelegate _delegate;
  late final Ticker _autoScrollTicker;
  Duration? _lastTickElapsed;

  @override
  void initState() {
    super.initState();
    _autoScrollTicker = createTicker(_onAutoScrollTick);
    _delegate = _EdgeInsetAutoScrollSelectionDelegate(
      scrollController: widget.scrollController,
      getScopeContext: () => mounted ? context : null,
      getTopEdgeInset: () => widget.resolveTopEdgeInset?.call() ?? widget.topEdgeInset,
      getBottomEdgeInset: () =>
          widget.resolveBottomEdgeInset?.call() ?? widget.bottomEdgeInset,
      hotZoneExtent: widget.hotZoneExtent,
      onStartTicker: _ensureTickerRunning,
      onStopTicker: _stopTicker,
      onAutoScrollActiveChanged: widget.onAutoScrollActiveChanged,
      onAutoScrollStep: widget.onAutoScrollStep,
    );
  }

  void _ensureTickerRunning() {
    if (!mounted || _autoScrollTicker.isActive) return;
    _lastTickElapsed = null;
    _autoScrollTicker.start();
  }

  void _stopTicker() {
    if (_autoScrollTicker.isActive) {
      _autoScrollTicker.stop();
    }
    _lastTickElapsed = null;
  }

  void _onAutoScrollTick(Duration elapsed) {
    if (!mounted) {
      _stopTicker();
      return;
    }
    final prev = _lastTickElapsed;
    _lastTickElapsed = elapsed;
    final dtSec = prev == null
        ? 0.016
        : ((elapsed - prev).inMicroseconds / 1000000.0).clamp(0.004, 0.034);
    _delegate.stepAutoScroll(dtSec);
  }

  @override
  void didUpdateWidget(covariant GrassBagSelectionAutoScrollScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _delegate.scrollController = widget.scrollController;
    _delegate.getTopEdgeInset =
        () => widget.resolveTopEdgeInset?.call() ?? widget.topEdgeInset;
    _delegate.getBottomEdgeInset =
        () => widget.resolveBottomEdgeInset?.call() ?? widget.bottomEdgeInset;
    _delegate.hotZoneExtent = widget.hotZoneExtent;
    _delegate.onAutoScrollActiveChanged = widget.onAutoScrollActiveChanged;
    _delegate.onAutoScrollStep = widget.onAutoScrollStep;
  }

  @override
  void dispose() {
    _stopTicker();
    _autoScrollTicker.dispose();
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final registrar = SelectionContainer.maybeOf(context);
    if (registrar == null) {
      return widget.child;
    }
    return SelectionContainer(
      registrar: registrar,
      delegate: _delegate,
      child: widget.child,
    );
  }
}

class _EdgeInsetAutoScrollSelectionDelegate
    extends MultiSelectableSelectionContainerDelegate {
  _EdgeInsetAutoScrollSelectionDelegate({
    required this.scrollController,
    required this.getScopeContext,
    required this.getTopEdgeInset,
    required this.getBottomEdgeInset,
    required this.hotZoneExtent,
    required this.onStartTicker,
    required this.onStopTicker,
    this.onAutoScrollActiveChanged,
    this.onAutoScrollStep,
  }) {
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handleGlobalPointerEvent);
  }

  ScrollController scrollController;
  final BuildContext? Function() getScopeContext;
  double Function() getTopEdgeInset;
  double Function() getBottomEdgeInset;
  double hotZoneExtent;
  final VoidCallback onStartTicker;
  final VoidCallback onStopTicker;
  ValueChanged<bool>? onAutoScrollActiveChanged;
  ValueChanged<double>? onAutoScrollStep;

  final Set<int> _activePointers = <int>{};
  SelectionEdgeUpdateEvent? _lastHotEdgeEvent;
  double _currentVelocityPxPerSec = 0.0;
  int _edgeGeneration = 0;
  bool _postFrameEdgeSyncScheduled = false;
  bool _autoScrollActive = false;
  bool _disposed = false;

  void _setAutoScrollActive(bool next) {
    if (_autoScrollActive == next) return;
    _autoScrollActive = next;
    onAutoScrollActiveChanged?.call(next);
  }

  void _stopAutoScroll() {
    _currentVelocityPxPerSec = 0.0;
    _lastHotEdgeEvent = null;
    _postFrameEdgeSyncScheduled = false;
    onStopTicker();
    _setAutoScrollActive(false);
  }

  void _handleGlobalPointerEvent(PointerEvent event) {
    if (_disposed) return;
    if (event is PointerDownEvent) {
      _activePointers.add(event.pointer);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _activePointers.remove(event.pointer);
      if (_activePointers.isEmpty) {
        _stopAutoScroll();
      }
    }
  }

  void stepAutoScroll(double dtSec) {
    if (_disposed || _activePointers.isEmpty || _currentVelocityPxPerSec == 0.0) {
      _stopAutoScroll();
      return;
    }
    final ScrollPosition? pos =
        (scrollController.hasClients && scrollController.positions.length == 1)
            ? scrollController.position
            : null;
    if (pos == null) {
      _stopAutoScroll();
      return;
    }
    final oldPixels = pos.pixels;
    final nextPixels = (oldPixels + _currentVelocityPxPerSec * dtSec)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    final delta = nextPixels - oldPixels;
    if (delta.abs() <= 0.05) {
      // Reached min/max scroll extent: run one final unclamped edge update and stop!
      final finalEvent = _lastHotEdgeEvent;
      _stopAutoScroll();
      if (finalEvent != null) {
        super.handleSelectionEdgeUpdate(finalEvent);
      }
      return;
    }
    pos.jumpTo(nextPixels);
    onAutoScrollStep?.call(delta);

    // After layout catches up to the new scroll offset, ensure selection extends onto newly
    // visible lines even for `continuous: false` gestures (Android long-press + drag down).
    final expectedGen = _edgeGeneration;
    if (!_postFrameEdgeSyncScheduled) {
      _postFrameEdgeSyncScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _postFrameEdgeSyncScheduled = false;
        if (_disposed || _activePointers.isEmpty) return;
        // If `SelectableRegion` already dispatched its own continuous edge update this frame,
        // skip duplicate dispatch.
        if (_edgeGeneration != expectedGen) return;
        final pending = _lastHotEdgeEvent;
        if (pending != null) {
          handleSelectionEdgeUpdate(pending);
        }
      });
    }
  }

  @override
  void ensureChildUpdated(Selectable selectable) {
    // Child Scrollable's `_ScrollableSelectionContainerDelegate` already maintains
    // scroll-relative edge offsets and updates its own selectables on scroll.
  }

  @override
  SelectionResult handleClearSelection(ClearSelectionEvent event) {
    _stopAutoScroll();
    return super.handleClearSelection(event);
  }

  @override
  SelectionResult handleSelectionEdgeUpdate(SelectionEdgeUpdateEvent event) {
    _edgeGeneration++;

    final scopeCtx = getScopeContext();
    final renderObj = scopeCtx?.findRenderObject();
    final RenderBox? box =
        (renderObj is RenderBox && renderObj.hasSize) ? renderObj : null;
    final ScrollPosition? pos =
        (scrollController.hasClients && scrollController.positions.length == 1)
            ? scrollController.position
            : null;

    double velocityPxPerSec = 0.0;
    SelectionEdgeUpdateEvent effectiveEvent = event;

    if (box != null && pos != null) {
      final topLeft = box.localToGlobal(Offset.zero);
      final viewportTop = topLeft.dy;
      final viewportBottom = topLeft.dy + box.size.height;
      final topInset = getTopEdgeInset().clamp(0.0, math.max(0.0, box.size.height * 0.45));
      final bottomInset =
          getBottomEdgeInset().clamp(0.0, math.max(0.0, box.size.height * 0.45));
      final visibleTop = math.min(viewportBottom - 48.0, viewportTop + topInset);
      final visibleBottom = math.max(visibleTop + 48.0, viewportBottom - bottomInset);
      final effectiveHotZone =
          math.min(hotZoneExtent, math.max(20.0, (visibleBottom - visibleTop) * 0.22));

      final canScrollDown = pos.pixels < pos.maxScrollExtent - 0.5;
      final canScrollUp = pos.pixels > pos.minScrollExtent + 0.5;
      final dy = event.globalPosition.dy;

      final bottomDepth = dy - (visibleBottom - effectiveHotZone);
      final topDepth = (visibleTop + effectiveHotZone) - dy;

      if (bottomDepth > 0 && canScrollDown) {
        final t = (bottomDepth / (effectiveHotZone * 1.65)).clamp(0.0, 1.0);
        velocityPxPerSec = 140.0 + 820.0 * t * t;
        if (dy > visibleBottom) {
          final clampedPos = Offset(event.globalPosition.dx, visibleBottom - 4.0);
          effectiveEvent = event.type == SelectionEventType.endEdgeUpdate
              ? SelectionEdgeUpdateEvent.forEnd(
                  globalPosition: clampedPos,
                  granularity: event.granularity,
                )
              : SelectionEdgeUpdateEvent.forStart(
                  globalPosition: clampedPos,
                  granularity: event.granularity,
                );
        }
      } else if (topDepth > 0 && canScrollUp) {
        final t = (topDepth / (effectiveHotZone * 1.65)).clamp(0.0, 1.0);
        velocityPxPerSec = -(140.0 + 820.0 * t * t);
        if (dy < visibleTop) {
          final clampedPos = Offset(event.globalPosition.dx, visibleTop + 4.0);
          effectiveEvent = event.type == SelectionEventType.endEdgeUpdate
              ? SelectionEdgeUpdateEvent.forEnd(
                  globalPosition: clampedPos,
                  granularity: event.granularity,
                )
              : SelectionEdgeUpdateEvent.forStart(
                  globalPosition: clampedPos,
                  granularity: event.granularity,
                );
        }
      }
    }

    final result = super.handleSelectionEdgeUpdate(effectiveEvent);
    if (result == SelectionResult.pending) {
      // A nested scrollable (or Flutter's native outer edge scroller) is already scrolling.
      _currentVelocityPxPerSec = 0.0;
      _lastHotEdgeEvent = null;
      onStopTicker();
      return result;
    }

    if (velocityPxPerSec != 0.0 && pos != null) {
      _currentVelocityPxPerSec = velocityPxPerSec;
      _lastHotEdgeEvent = event;
      _setAutoScrollActive(true);
      onStartTicker();
      return SelectionResult.pending;
    }

    _stopAutoScroll();
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopAutoScroll();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_handleGlobalPointerEvent);
    super.dispose();
  }
}

/// Keeps a virtualized list item (`SliverList.builder` / `ListView.builder`) alive while
/// [keepAliveListenable] is `true` (e.g. while an active text selection is in progress),
/// preventing `SliverList.builder` from disposing the selection's start/end item when the
/// user auto-scrolls multiple screens away (which would otherwise truncate copied text
/// and trip Flutter's `startGlyphHeight` null crash).
///
/// Unlike wrapping each item in a `SelectionListener` / nested `SelectionContainer`, this
/// adds ZERO intermediate selection containers inside the scrollable and immediately
/// releases keep-alive as soon as the selection clears.
class GrassBagSelectionKeepAlive extends StatefulWidget {
  const GrassBagSelectionKeepAlive({
    super.key,
    required this.keepAliveListenable,
    required this.child,
  });

  final ValueListenable<bool> keepAliveListenable;
  final Widget child;

  @override
  State<GrassBagSelectionKeepAlive> createState() => _GrassBagSelectionKeepAliveState();
}

class _GrassBagSelectionKeepAliveState extends State<GrassBagSelectionKeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.keepAliveListenable.value;

  @override
  void initState() {
    super.initState();
    widget.keepAliveListenable.addListener(_onKeepAliveChanged);
  }

  @override
  void didUpdateWidget(covariant GrassBagSelectionKeepAlive oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keepAliveListenable != widget.keepAliveListenable) {
      oldWidget.keepAliveListenable.removeListener(_onKeepAliveChanged);
      widget.keepAliveListenable.addListener(_onKeepAliveChanged);
      updateKeepAlive();
    }
  }

  void _onKeepAliveChanged() {
    if (!mounted) return;
    updateKeepAlive();
  }

  @override
  void dispose() {
    widget.keepAliveListenable.removeListener(_onKeepAliveChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Safely reads [SelectableRegionState.contextMenuAnchors], falling back cleanly if a
/// virtualized list ever evicted one selection endpoint (`startSelectionPoint == null`),
/// which otherwise throws a null-check error in Flutter's `SelectableRegionState.startGlyphHeight`.
TextSelectionToolbarAnchors _safeSelectableContextMenuAnchors(
  BuildContext context,
  SelectableRegionState state,
) {
  try {
    return state.contextMenuAnchors;
  } catch (_) {
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final fallback = Offset(size.width * 0.5, pad.top + 96.0);
    return TextSelectionToolbarAnchors(primaryAnchor: fallback);
  }
}

/// Floating Apple iOS 26 Liquid Glass horizontal text selection toolbar for `SelectionArea`.
Widget buildGrassBagSelectableContextMenu(
  BuildContext context,
  SelectableRegionState selectableRegionState,
) {
  return _GrassBagGlassSelectionToolbar(
    anchors: _safeSelectableContextMenuAnchors(context, selectableRegionState),
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
      anchors: _safeSelectableContextMenuAnchors(context, selectableRegionState),
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
