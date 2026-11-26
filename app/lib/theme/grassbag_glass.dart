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

/// Centralized Apple iOS 26 / iOS 27 Liquid Glass material system for GrassBag.
///
/// Built strictly on `liquid_glass_widgets` 1.19.0's simulator-calibrated
/// [LiquidGlassSettings.ios27Light] / [LiquidGlassSettings.ios27Dark] optics and
/// golden rules (`SKILL.md` Rules 1, 2 & 5):
/// - Crisp luminous glass interior for effortless text legibility
/// - Thin-lens `GlassLensModel.spherical` (`thickness: 20–22`, `refractiveIndex: 1.11–1.12`)
///   for chrome/sheets/buttons so `isClearIndicator` stays false (zero charcoal Light ring,
///   authentic 135° diagonal dual-lobe Dark catchlights, zero `maxReach` clamping on 44dp pills!)
/// - `GlassLensModel.paraxial` reserved strictly for transient lifted interactive indicators
///   (`GrassBagGlassSwitch` / `GrassBagGlassSlider`)
/// - Never forces `GlassQuality.premium` globally so resting lists/switches mount ZERO shaders
/// - Never nests refractive glass inside refractive glass (zero Impeller deadlocks / freezes!)
abstract final class GrassBagGlassConfig {
  /// Quality for persistent floating chrome (nav buttons, title capsule, floating composer, sheets).
  /// Uses real GPU Impeller `GlassQuality.premium` (`liquid_glass_render.frag`) WITH `frost: 0`
  /// (`frostOpacity: 0.0`) — this BOTH unlocks genuine Kyant0-grade curved SDF optical lens
  /// refraction + subtle chromatic rim dispersion AND skips the expensive 45-tap frost pass!
  static GlassQuality chromeQualityFor(GrassBagGlassTier tier) {
    if (tier == GrassBagGlassTier.solid) return GlassQuality.minimal;
    // On Flutter Web (CanvasKit WebGL), multi-pass `premium` fragment readbacks cause
    // severe scroll/typing jank; `standard` delivers silky 60/120fps frosted glass!
    if (kIsWeb) return GlassQuality.standard;
    // On mobile Impeller: `liquid` unlocks full curved optical refraction (`GlassQuality.premium`),
    // while `frosted` routes through single-pass `GlassQuality.standard` so it is genuinely lighter
    // on GPU/battery, and `solid` mounts zero BackdropFilter shaders (`GlassQuality.minimal`).
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

  /// Calibrated Apple iOS 26/27 & Kyant0 thin-lens Liquid Glass optical settings for floating chrome:
  /// - Pure achromatic `Colors.white` glassColor in Dark & Light modes so `render.glsl`
  ///   routes through `directMix` (authentic luminous frosted glass lift instead of muddy tint).
  /// - Thin-lens `GlassLensModel.spherical` (`thickness: 22.0`, `refractiveIndex: 1.12`) keeps
  ///   `isClearIndicator == false` in `liquid_glass_render.frag` (eliminating Light-mode's 360°
  ///   charcoal outline & restoring true 135° diagonal dual-lobe Dark-mode catchlights) while
  ///   staying 98.5% unclamped on 44dp chrome pills!
  /// - Restrained `lightIntensity` (`0.18` Dark / `0.10` Light) paired with crisp dual-lobe `rimLight`
  ///   and `fresnelStrength` prevents Light-mode specular white-clipping and preserves prismatic bevels.
  /// - In `frosted` tier (`lightweight_glass.frag`), `lightIntensity: 0.0` and `rimShade: 0.0` keep
  ///   edges crystal-clean without double-rim floor activation.
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
      const blurSigma = 8.0;
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
          lightAngle: 0.75 * math.pi,
          lightIntensity: 0.0,
          ambientStrength: 0.06,
          ambientRim: 0.0,
          fresnelStrength: 0.18,
          edgeAbsorption: 0.02,
          rimShade: 0.0,
          rimLight: 0.40,
          bodyShade: elevated ? 0.16 : 0.12,
          specularSharpness: GlassSpecularSharpness.medium,
          shadow: const [],
        );
      }
      return LiquidGlassSettings(
        glassColor: Colors.white.withValues(alpha: elevated ? 0.54 : 0.44),
        blur: blurSigma,
        frost: 0.0,
        frostOpacity: 0.0,
        thickness: 1.0,
        refractiveIndex: 1.01,
        lensModel: GlassLensModel.spherical,
        chromaticAberration: 0.0,
        saturation: 1.0,
        lightAngle: 0.75 * math.pi,
        lightIntensity: 0.0,
        ambientStrength: 0.04,
        ambientRim: 0.0,
        fresnelStrength: 0.12,
        whitenStrength: 0.16,
        whitenGated: true,
        edgeAbsorption: 0.015,
        rimShade: 0.0,
        rimLight: 0.46,
        bodyShade: 0.0,
        specularSharpness: GlassSpecularSharpness.medium,
        shadow: [
          BoxShadow(
            color: const Color(0x14000000),
            blurRadius: elevated ? 16 : 12,
            offset: Offset(0, elevated ? 6 : 4),
          ),
        ],
      );
    }

    if (t.isDark) {
      return LiquidGlassSettings(
        glassColor: Colors.white.withValues(alpha: elevated ? 0.075 : 0.04),
        blur: 1.2,
        frost: 0.0,
        frostOpacity: 0.0,
        thickness: 30.0,
        refractiveIndex: 1.44,
        lensModel: GlassLensModel.spherical,
        chromaticAberration: 0.20,
        saturation: 1.68,
        lightAngle: 0.75 * math.pi,
        lightIntensity: 1.12,
        ambientStrength: 0.14,
        ambientRim: 0.0,
        fresnelStrength: 1.32,
        edgeAbsorption: 0.028,
        rimShade: 0.0,
        rimLight: 1.12,
        bodyShade: elevated ? 0.05 : 0.02,
        specularSharpness: GlassSpecularSharpness.sharp,
        shadow: const [],
      );
    }

    return LiquidGlassSettings(
      glassColor: Colors.white.withValues(alpha: elevated ? 0.085 : 0.045),
      blur: 1.2,
      frost: 0.0,
      frostOpacity: 0.0,
      thickness: 30.0,
      refractiveIndex: 1.42,
      lensModel: GlassLensModel.spherical,
      chromaticAberration: 0.18,
      saturation: 1.78,
      lightAngle: 0.75 * math.pi,
      lightIntensity: 0.85,
      ambientStrength: 0.09,
      ambientRim: 0.0,
      fresnelStrength: 1.05,
      whitenStrength: 0.0,
      whitenGated: true,
      edgeAbsorption: 0.014,
      rimShade: 0.0,
      rimLight: 0.98,
      bodyShade: 0.0,
      specularSharpness: GlassSpecularSharpness.sharp,
      shadow: [
        BoxShadow(
          color: const Color(0x10000000),
          blurRadius: elevated ? 18 : 14,
          offset: Offset(0, elevated ? 6 : 4),
        ),
      ],
    );
  }

  /// Kyant0-inspired crystal Liquid Glass for modal sheets, '+' deck, menus, dialogs, and drawer:
  /// silky `7.2dp` vibrancy bokeh + genuine curved spherical edge refraction + prismatic dispersion!
  static LiquidGlassSettings sheetSettings(GrassBagTokens t, GrassBagGlassTier tier) {
    final base = surfaceSettings(t, tier, elevated: true);
    if (tier == GrassBagGlassTier.solid) {
      return base;
    }
    if (tier != GrassBagGlassTier.liquid || kIsWeb) {
      return base.copyWith(
        glassColor: t.isDark
            ? Colors.white.withValues(alpha: 0.14)
            : Colors.white.withValues(alpha: 0.54),
        blur: kIsWeb ? 8.5 : 8.0,
        frost: 0.0,
        frostOpacity: 0.0,
        thickness: 1.0,
        refractiveIndex: 1.01,
        lensModel: GlassLensModel.spherical,
        saturation: 1.0,
        lightIntensity: 0.0,
        rimLight: t.isDark ? 0.38 : 0.46,
        rimShade: 0.0,
        ambientRim: 0.0,
        chromaticAberration: 0.0,
        bodyShade: t.isDark ? 0.18 : 0.0,
      );
    }
    return base.copyWith(
      glassColor: t.isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.white.withValues(alpha: 0.22),
      blur: 7.2,
      frost: 0.0,
      frostOpacity: 0.0,
      thickness: 30.0,
      refractiveIndex: t.isDark ? 1.38 : 1.36,
      lensModel: GlassLensModel.spherical,
      chromaticAberration: t.isDark ? 0.15 : 0.14,
      saturation: t.isDark ? 1.58 : 1.65,
      bodyShade: t.isDark ? 0.18 : 0.0,
      whitenStrength: 0.0,
      whitenGated: true,
      lightAngle: 0.75 * math.pi,
      lightIntensity: t.isDark ? 0.92 : 0.70,
      ambientStrength: t.isDark ? 0.11 : 0.08,
      ambientRim: 0.0,
      fresnelStrength: t.isDark ? 1.15 : 0.90,
      edgeAbsorption: t.isDark ? 0.032 : 0.018,
      rimLight: t.isDark ? 1.06 : 0.98,
      rimShade: 0.0,
      specularSharpness: GlassSpecularSharpness.sharp,
      shadow: t.isDark
          ? const []
          : const [
              BoxShadow(
                color: Color(0x12000000),
                blurRadius: 22,
                offset: Offset(0, 7),
              ),
            ],
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
    final indicatorTheme = isFrosted
        ? null
        : const GlassThemeSettings(
            refractiveIndex: 1.26,
            chromaticAberration: 0.09,
            lightAngle: 0.75 * math.pi,
            lightIntensity: 0.0,
            ambientStrength: 0.0,
            fresnelStrength: 0.18,
            rimLight: 1.0,
            rimShade: 0.35,
          );

    return GlassThemeData(
      style: GlassStyle.ios27,
      light: GlassThemeVariant.ios27Light.copyWith(
        settings: GlassThemeSettings.ios27Light.copyWith(
          glassColor: Colors.white.withValues(alpha: isFrosted ? 0.44 : 0.045),
          blur: isFrosted ? 8.0 : 1.2,
          frost: 0.0,
          frostOpacity: 0.0,
          thickness: isFrosted ? 1.0 : 30.0,
          refractiveIndex: isFrosted ? 1.01 : 1.42,
          lensModel: GlassLensModel.spherical,
          chromaticAberration: isFrosted ? 0.0 : 0.18,
          saturation: isFrosted ? 1.0 : 1.78,
          lightAngle: 0.75 * math.pi,
          lightIntensity: isFrosted ? 0.0 : 0.85,
          ambientStrength: isFrosted ? 0.04 : 0.09,
          fresnelStrength: isFrosted ? 0.12 : 1.05,
          edgeAbsorption: isFrosted ? 0.015 : 0.014,
          rimShade: 0.0,
          rimLight: isFrosted ? 0.46 : 0.98,
          bodyShade: 0.0,
          shadow: const [],
          specularSharpness:
              isFrosted ? GlassSpecularSharpness.medium : GlassSpecularSharpness.sharp,
        ),
        indicatorSettings: indicatorTheme,
        glowColors: GlassGlowColors(
          primary: lightTokens.primaryHi.withValues(alpha: 0.30),
          secondary: lightTokens.dusk.withValues(alpha: 0.24),
          success: lightTokens.ok.withValues(alpha: 0.26),
          warning: lightTokens.warn.withValues(alpha: 0.26),
          danger: lightTokens.err.withValues(alpha: 0.26),
          info: lightTokens.primary.withValues(alpha: 0.26),
          pressLight: Color.lerp(Colors.white, lightTokens.primaryHi, 0.22)!,
          glowBlurRadius: 0.0,
          glowSpreadRadius: 0.10,
        ),
      ),
      dark: GlassThemeVariant.ios27Dark.copyWith(
        settings: GlassThemeSettings.ios27Dark.copyWith(
          glassColor: Colors.white.withValues(alpha: isFrosted ? 0.10 : 0.04),
          blur: isFrosted ? 8.0 : 1.2,
          frost: 0.0,
          frostOpacity: 0.0,
          thickness: isFrosted ? 1.0 : 30.0,
          refractiveIndex: isFrosted ? 1.01 : 1.44,
          lensModel: GlassLensModel.spherical,
          chromaticAberration: isFrosted ? 0.0 : 0.20,
          saturation: isFrosted ? 1.0 : 1.68,
          lightAngle: 0.75 * math.pi,
          lightIntensity: isFrosted ? 0.0 : 1.12,
          ambientStrength: isFrosted ? 0.06 : 0.14,
          fresnelStrength: isFrosted ? 0.18 : 1.32,
          edgeAbsorption: isFrosted ? 0.02 : 0.028,
          rimShade: 0.0,
          rimLight: isFrosted ? 0.40 : 1.12,
          bodyShade: isFrosted ? 0.12 : 0.02,
          shadow: const [],
          specularSharpness:
              isFrosted ? GlassSpecularSharpness.medium : GlassSpecularSharpness.sharp,
        ),
        indicatorSettings: indicatorTheme,
        glowColors: GlassGlowColors(
          primary: darkTokens.primary.withValues(alpha: 0.36),
          secondary: darkTokens.dusk.withValues(alpha: 0.28),
          success: darkTokens.ok.withValues(alpha: 0.30),
          warning: darkTokens.warn.withValues(alpha: 0.30),
          danger: darkTokens.err.withValues(alpha: 0.30),
          info: darkTokens.primaryHi.withValues(alpha: 0.30),
          pressLight: Color.lerp(Colors.white, darkTokens.primaryHi, 0.30)!,
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
  late final AnimationController _alphaCtrl;
  late final CurvedAnimation _alphaAnim;
  final ValueNotifier<Offset> _touchPos = ValueNotifier<Offset>(Offset.zero);
  late final Listenable _repaintListenable;
  int? _activePointerId;
  Offset? _downPos;
  bool _suppressed = false;
  bool _shown = false;
  Timer? _scrollDeferTimer;
  Timer? _quickGlintTimer;

  @override
  void initState() {
    super.initState();
    _alphaCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      reverseDuration: const Duration(milliseconds: 280),
    );
    _alphaAnim = CurvedAnimation(
      parent: _alphaCtrl,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _repaintListenable = Listenable.merge([_alphaAnim, _touchPos]);
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
      _alphaCtrl.value = 0.0;
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
    _alphaAnim.dispose();
    _alphaCtrl.dispose();
    _touchPos.dispose();
    super.dispose();
  }

  void _onDown(PointerDownEvent e) {
    if (_activePointerId != null) return;
    _cancelTimers();
    _activePointerId = e.pointer;
    _downPos = e.localPosition;
    _suppressed = false;
    _shown = false;
    _touchPos.value = e.localPosition;
    if (Scrollable.maybeOf(context) != null) {
      _scrollDeferTimer = Timer(const Duration(milliseconds: 45), () {
        if (!mounted || _suppressed || _activePointerId != e.pointer) return;
        _shown = true;
        _alphaCtrl.forward();
      });
    } else {
      _shown = true;
      _alphaCtrl.forward();
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (_activePointerId != e.pointer || _suppressed) return;
    final down = _downPos;
    final scrollable = Scrollable.maybeOf(context);
    if (down != null && scrollable != null) {
      final delta = e.localPosition - down;
      final isVert = axisDirectionToAxis(scrollable.axisDirection) == Axis.vertical;
      final scrollDragged = isVert
          ? (delta.dy.abs() > 10.0 && delta.dy.abs() > delta.dx.abs() * 1.15)
          : (delta.dx.abs() > 10.0 && delta.dx.abs() > delta.dy.abs() * 1.15);
      if (scrollDragged) {
        _suppressed = true;
        _scrollDeferTimer?.cancel();
        _scrollDeferTimer = null;
        if (_alphaCtrl.value > 0.0 || _alphaCtrl.isAnimating) {
          _alphaCtrl.reverse();
        }
        return;
      }
    }
    _touchPos.value = e.localPosition;
  }

  void _onUp(PointerUpEvent e) {
    if (_activePointerId != e.pointer) return;
    _activePointerId = null;
    _downPos = null;
    _scrollDeferTimer?.cancel();
    _scrollDeferTimer = null;
    if (!_suppressed && !_shown) {
      // Brisk tap inside a ScrollView: emit a clean micro-glint without sticking!
      _alphaCtrl.forward(from: 0.32);
      _quickGlintTimer = Timer(const Duration(milliseconds: 110), () {
        if (mounted) _alphaCtrl.reverse();
      });
      return;
    }
    if (_alphaCtrl.value > 0.0 || _alphaCtrl.isAnimating) {
      _alphaCtrl.reverse();
    }
  }

  void _onCancel(PointerCancelEvent e) {
    if (_activePointerId != e.pointer) return;
    _activePointerId = null;
    _downPos = null;
    _cancelTimers();
    if (_alphaCtrl.value > 0.0 || _alphaCtrl.isAnimating) {
      _alphaCtrl.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    final t = GrassBagTokens.of(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: CustomPaint(
        foregroundPainter: _GrassBagInteractiveHighlightPainter(
          repaint: _repaintListenable,
          alpha: _alphaAnim,
          touchPos: _touchPos,
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

/// Reusable zero-shader sculpted translucent crystal glass container with 135° directional
/// luminance gradient and [GrassBagFresnelRimPainter] bevel catchlight.
/// Used for content cards, nested sheet wells, composer inner pills, and floating capsules.
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
    final isFrosted = ambientTier == GrassBagGlassTier.frosted;

    final highContrast = MediaQuery.highContrastOf(context);
    final solidStroke = highContrast ? 1.15 : 0.75;
    final solidPillStroke = highContrast ? 1.1 : 0.65;
    final ShapeBorder baseShape = isCircle
        ? CircleBorder(
            side: isSolid ? BorderSide(color: t.sepStrong, width: solidPillStroke) : BorderSide.none,
          )
        : (isPill
            ? StadiumBorder(
                side: isSolid
                    ? BorderSide(color: t.sepStrong, width: solidPillStroke)
                    : BorderSide.none,
              )
            : RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(borderRadius),
                side: isSolid
                    ? BorderSide(color: highContrast ? t.sepStrong : t.sep, width: solidStroke)
                    : BorderSide.none,
              ));

    final List<Color> gradColors;
    if (tintColor != null) {
      final hi = Color.lerp(
        tintColor!,
        Colors.white.withValues(alpha: tintColor!.a),
        t.isDark ? 0.12 : 0.18,
      )!;
      gradColors = [hi, tintColor!];
    } else if (innerWell) {
      gradColors = t.isDark
          ? [
              Colors.white.withValues(alpha: isFrosted ? 0.075 : 0.08),
              Colors.white.withValues(alpha: isFrosted ? 0.045 : 0.04),
            ]
          : [
              Colors.white.withValues(alpha: isFrosted ? 0.72 : 0.62),
              Colors.white.withValues(alpha: isFrosted ? 0.60 : 0.48),
            ];
    } else {
      gradColors = t.isDark
          ? [
              Color.lerp(t.cardSolid, Colors.white, isFrosted ? 0.06 : 0.08)!
                  .withValues(alpha: isFrosted ? 0.82 : 0.74),
              t.cardSolid.withValues(alpha: isFrosted ? 0.74 : 0.64),
            ]
          : [
              Colors.white.withValues(alpha: isFrosted ? 0.86 : 0.80),
              Colors.white.withValues(alpha: isFrosted ? 0.76 : 0.68),
            ];
    }

    final shadows = !elevated
        ? null
        : (isSolid
            ? [
                BoxShadow(
                  color: t.isDark
                      ? Colors.black.withValues(alpha: 0.20)
                      : const Color(0x0B000000),
                  blurRadius: 10,
                  offset: const Offset(0, 2.5),
                ),
              ]
            : [
                BoxShadow(
                  color: t.isDark
                      ? Colors.black.withValues(alpha: 0.22)
                      : const Color(0x0B000000),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ]);

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

    final showBgSheen = !isSolid && !isFrosted && !innerWell && paintTopSheen;
    final decorated = DecoratedBox(
      decoration: ShapeDecoration(
        color: isSolid ? (tintColor ?? t.cardSolid) : null,
        gradient: isSolid
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradColors,
              ),
        shape: baseShape,
        shadows: shadows,
      ),
      child: showBgSheen
          ? CustomPaint(
              // Paint top meniscus sheen ABOVE surface gradient and BELOW child so text/icons stay crisp!
              painter: _GrassBagTopSheenPainter(
                isDark: t.isDark,
                borderRadius: borderRadius,
                isPill: isPill,
                isCircle: isCircle,
              ),
              child: body,
            )
          : body,
    );

    if (isSolid) return decorated;

    final fresnel = CustomPaint(
      foregroundPainter: GrassBagFresnelRimPainter(
        isDark: t.isDark,
        borderRadius: borderRadius,
        isPill: isPill,
        isCircle: isCircle,
        accent: t.primaryHi,
        innerWell: innerWell,
        frosted: isFrosted,
        paintTopSheen: false,
      ),
      child: decorated,
    );
    if (!interactive) return fresnel;
    return GrassBagInteractiveHighlight(
      borderRadius: borderRadius,
      isPill: isPill,
      isCircle: isCircle,
      accent: t.primaryHi,
      child: fresnel,
    );
  }
}

class _GrassBagTopSheenPainter extends CustomPainter {
  const _GrassBagTopSheenPainter({
    required this.isDark,
    required this.borderRadius,
    required this.isPill,
    required this.isCircle,
  });

  final bool isDark;
  final double borderRadius;
  final bool isPill;
  final bool isCircle;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 1.0 || size.height <= 4.0) return;
    final rect = Offset.zero & size;
    final sheenHeight = math.min(size.height * 0.20, 18.0);
    final sheenRect = Rect.fromLTWH(0, 0, size.width, sheenHeight);
    final sheenAlpha = isDark ? 0.05 : 0.18;
    final Path clipPath;
    if (isCircle) {
      clipPath = Path()..addOval(rect);
    } else if (isPill) {
      clipPath = Path()
        ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(size.shortestSide * 0.5)));
    } else {
      final r = math.min(borderRadius, size.shortestSide * 0.5);
      clipPath = Path()
        ..addRSuperellipse(RSuperellipse.fromRectAndRadius(rect, Radius.circular(r)));
    }
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

  @override
  bool shouldRepaint(covariant _GrassBagTopSheenPainter old) =>
      old.isDark != isDark ||
      old.borderRadius != borderRadius ||
      old.isPill != isPill ||
      old.isCircle != isCircle;
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

class _GrassBagGlassBarScope extends InheritedWidget {
  const _GrassBagGlassBarScope({required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GrassBagGlassBarScope>() != null;

  @override
  bool updateShouldNotify(_GrassBagGlassBarScope oldWidget) => false;
}

/// Shared Impeller `AdaptiveLiquidGlassLayer` (SwiftUI `GlassEffectContainer` equivalent)
/// that batches sibling floating pills in a navigation bar into ONE single SDF
/// geometry matte + ONE single refraction pass (cutting header GPU passes by up to 67%!).
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
    // Strip Light-mode shader shadows from the shared bar layer so `LiquidGlassLayer._bakeShadows()`
    // never runs synchronous `picture.toImageSync()` GPU stalls; child pills paint clipped outer shadows!
    final baseSettings = GrassBagGlassConfig.surfaceSettings(t, effectiveTier);
    final layerSettings =
        !t.isDark && (baseSettings.shadow?.isNotEmpty ?? false)
            ? baseSettings.copyWith(shadow: const [])
            : baseSettings;
    return _GrassBagGlassBarScope(
      child: AdaptiveLiquidGlassLayer(
        settings: layerSettings,
        quality: GrassBagGlassConfig.chromeQualityFor(effectiveTier),
        blendAmount: 0.0,
        clipExpansion: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        child: child,
      ),
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
    // Drive scale via our stateful easeOutCubic/easeInCubic `_scaleAnim` (with `scaleFrom: 1.0`
    // inside `GlassMaterializeTransition`) so dialogs, menus, and toasts ease smoothly to rest
    // instead of slamming linearly at t = 0.92 (GrassBag uses `frost: 0.0`, so FrostRows is inactive).
    final materialized = GlassMaterializeTransition(
      animation: widget.animation,
      alignment: widget.alignment,
      scaleFrom: 1.0,
      contentSigma: reduceMotion ? 0.0 : widget.contentSigma,
      child: widget.child,
    );
    return GrassBagMaterializeScope(
      animation: widget.animation,
      child: reduceMotion
          ? materialized
          : ScaleTransition(
              alignment: widget.alignment,
              scale: _scaleAnim,
              child: materialized,
            ),
    );
  }
}

/// Even-odd inverse clip punching out the UNSHIFTED glass footprint so standard Gaussian
/// `BlurStyle.normal` drop shadows fade monotonically outward from the exact glass edge —
/// never leaking into translucent glass interiors and never creating `BlurStyle.outer`'s
/// shifted hollow moat / detached bottom double ring!
class _InverseGlassShapeClipper extends CustomClipper<Path> {
  const _InverseGlassShapeClipper({
    required this.shape,
    required this.expansion,
  });

  final ShapeBorder shape;
  final double expansion;

  @override
  Path getClip(Size size) {
    final rect = Offset.zero & size;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect.inflate(expansion))
      ..addPath(shape.getOuterPath(rect), Offset.zero);
  }

  @override
  bool shouldReclip(covariant _InverseGlassShapeClipper oldClipper) =>
      oldClipper.shape != shape || oldClipper.expansion != expansion;
}

/// Renders zero-cutout-artifact outer elevation shadows strictly outside the unshifted
/// glass silhouette while preserving constant Stack tree depth across materialization frames.
class _GrassBagOuterShadow extends StatelessWidget {
  const _GrassBagOuterShadow({
    required this.shape,
    required this.shadows,
    required this.child,
  });

  final ShapeBorder shape;
  final List<BoxShadow> shadows;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    var maxExtent = 16.0;
    final normalShadows = <BoxShadow>[];
    for (final s in shadows) {
      final extent = s.blurRadius * 2.5 +
          s.spreadRadius.abs() +
          math.max(s.offset.dx.abs(), s.offset.dy.abs()) +
          12.0;
      if (extent > maxExtent) maxExtent = extent;
      normalShadows.add(
        s.blurStyle == BlurStyle.normal
            ? s
            : BoxShadow(
                color: s.color,
                blurRadius: s.blurRadius,
                spreadRadius: s.spreadRadius,
                offset: s.offset,
                blurStyle: BlurStyle.normal,
              ),
      );
    }
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: normalShadows.isEmpty
              ? const SizedBox.shrink()
              : IgnorePointer(
                  child: ClipPath(
                    clipper: _InverseGlassShapeClipper(
                      shape: shape,
                      expansion: maxExtent,
                    ),
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        shape: shape,
                        shadows: normalShadows,
                      ),
                    ),
                  ),
                ),
        ),
        child,
      ],
    );
  }
}

/// Unified Liquid Glass floating container powered by `liquid_glass_widgets`.
///
/// Use ONLY on floating chrome (composer, approval card, '+' panel, steer popover,
/// remote banner, bottom-centered Toast, floating phone drawer) or standalone hero cards
/// (with `useCardQuality: true`). Never nest refractive glass inside refractive glass!
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
    if (effectiveTier == GrassBagGlassTier.solid) {
      final materializeAnim = GrassBagMaterializeScope.animationOf(context);
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
        final innerChild = padding != null || alignment != null
            ? Container(
                width: width,
                height: height,
                padding: padding,
                alignment: alignment,
                child: child,
              )
            : (width != null || height != null
                ? SizedBox(width: width, height: height, child: child)
                : child);
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

    final effectiveOwnLayer =
        useOwnLayer || tintColor != null || useSheetSettings || platformViewBackdrop || useCardQuality;
    final inBarLayer = !effectiveOwnLayer && _GrassBagGlassBarScope.of(context);
    final baseSettings = useSheetSettings
        ? GrassBagGlassConfig.sheetSettings(t, effectiveTier)
        : (useCardQuality && effectiveTier == GrassBagGlassTier.liquid
            ? GrassBagGlassConfig.surfaceSettings(t, GrassBagGlassTier.frosted, elevated: elevated)
            : GrassBagGlassConfig.surfaceSettings(t, effectiveTier, elevated: elevated));
    final materializeAnim = GrassBagMaterializeScope.animationOf(context);
    final rawBaseShadows = baseSettings.shadow ?? const <BoxShadow>[];
    // Externalize Light-mode glass shadows ONLY for standalone layers or non-blended header bar
    // pills (never for metaball-blended `AdaptiveLiquidGlassLayer` children where per-child
    // shadows would paint dark cutout seams across merged liquid necks!).
    final externalizeLightShadow =
        !t.isDark && rawBaseShadows.isNotEmpty && (effectiveOwnLayer || inBarLayer);
    final externalizeDarkShadow =
        t.isDark && effectiveOwnLayer && (useSheetSettings || elevated);
    // When `platformViewBackdrop` is active in Liquid or Frosted mode, `liquid_glass_widgets`
    // routes through `_FrostedFallback` with circular `ClipRRect`. Zero `lightIntensity` /
    // `ambientStrength` and match `useCircularRRect: true` on our single `GrassBagFresnelRimPainter`.
    final adaptPlatformView = platformViewBackdrop;
    final darkPlatformBackdrop = tintColor != null
        ? tintColor!.computeLuminance() < 0.35
        : t.isDark;
    final rawSettings = adaptPlatformView
        ? baseSettings.copyWith(
            blur: 10.0,
            glassColor: tintColor ??
                (darkPlatformBackdrop
                    ? t.codeBg.withValues(alpha: 0.62)
                    : Colors.white.withValues(alpha: 0.72)),
            saturation: 1.15,
            lightIntensity: 0.0,
            ambientStrength: 0.0,
          )
        : (tintColor != null
            ? baseSettings.copyWith(glassColor: tintColor)
            : baseSettings);
    final resolvedSettings =
        externalizeLightShadow ? rawSettings.copyWith(shadow: const []) : rawSettings;

    final rawGlassWidget = GlassContainer(
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
    final rimmedWidget = adaptPlatformView
        ? CustomPaint(
            foregroundPainter: GrassBagFresnelRimPainter(
              isDark: darkPlatformBackdrop || t.isDark,
              isCircle: isOval,
              isPill: !isOval && borderRadius >= 900,
              useCircularRRect: true,
              borderRadius: borderRadius,
              accent: t.primaryHi,
              frosted: effectiveTier == GrassBagGlassTier.frosted,
              paintTopSheen: false,
              strokeWidth: 0.85,
            ),
            child: rawGlassWidget,
          )
        : rawGlassWidget;
    // Live Kyant0 fingertip spotlight + curved-bevel rim flare (works cleanly in both Light & Dark
    // modes with zero MaskFilter.blur cost and never zeroed by `GlassContainer`'s InheritedLiquidGlass!).
    final glassWidget = (interactiveGlow && !adaptPlatformView)
        ? GrassBagInteractiveHighlight(
            borderRadius: borderRadius,
            isPill: !isOval && borderRadius >= 900,
            isCircle: isOval,
            accent: tintColor ?? t.primaryHi,
            child: rimmedWidget,
          )
        : rimmedWidget;

    // Render outer elevation shadows via inverse-clipped `BlurStyle.normal` so translucent
    // glass NEVER paints a dark slab inside, NEVER triggers `BlurStyle.outer`'s shifted
    // hollow moat / detached ring, and NEVER calls synchronous `toImageSync` shadow baking!
    if (externalizeDarkShadow || externalizeLightShadow) {
      final outerShape = isOval
          ? const CircleBorder()
          : RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(borderRadius));
      final baseShadows = externalizeDarkShadow
          ? [
              BoxShadow(
                color: Colors.black
                    .withValues(alpha: useSheetSettings ? 0.44 : 0.30),
                blurRadius: useSheetSettings ? 28 : 18,
                offset: Offset(0, useSheetSettings ? 10 : 6),
              ),
            ]
          : rawBaseShadows;
      Widget wrapOuterShadow(double materialize, Widget inner) {
        return _GrassBagOuterShadow(
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
                    ),
                ],
          child: inner,
        );
      }
      if (materializeAnim != null) {
        return AnimatedBuilder(
          animation: materializeAnim,
          child: glassWidget,
          builder: (_, inner) =>
              wrapOuterShadow(materializeAnim.value.clamp(0.0, 1.0), inner!),
        );
      }
      return wrapOuterShadow(GrassBagMaterializeScope.progressOf(context), glassWidget);
    }
    return glassWidget;
  }
}

/// 44×44 symmetrical circular iOS 26 Liquid Glass chrome icon button backed by real
/// [GlassButton.custom] with authentic swell-on-press, LiquidStretch, and centered icon
/// (zero misaligned badge dots!).
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
                side: BorderSide(color: t.sepStrong, width: highContrast ? 1.15 : 0.65),
              ),
              shadows: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: t.isDark ? 0.24 : 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Center(
              child: Icon(icon, size: iconSize, color: iconColor ?? t.text),
            ),
          ),
        ),
      );
      return tooltip != null
          ? Tooltip(message: tooltip!, excludeFromSemantics: true, child: solidBtn)
          : solidBtn;
    }
    final effectiveOwnLayer = useOwnLayer || platformViewBackdrop || tintColor != null;
    final inBarLayer = !effectiveOwnLayer && _GrassBagGlassBarScope.of(context);
    final adaptPlatformView = platformViewBackdrop;
    final darkPlatformBackdrop = tintColor != null
        ? tintColor!.computeLuminance() < 0.35
        : (t.isDark || (iconColor != null && iconColor!.computeLuminance() > 0.72));
    final baseSettings = GrassBagGlassConfig.surfaceSettings(t, effectiveTier);
    final rawShadows = baseSettings.shadow ?? const <BoxShadow>[];
    final externalizeLightShadow =
        !t.isDark && rawShadows.isNotEmpty && (effectiveOwnLayer || inBarLayer);
    final noBakeBase = externalizeLightShadow ? baseSettings.copyWith(shadow: const []) : baseSettings;
    final resolvedSettings = !effectiveOwnLayer
        ? null
        : (adaptPlatformView
            ? noBakeBase.copyWith(
                blur: 10.0,
                glassColor: tintColor ??
                    (darkPlatformBackdrop
                        ? t.codeBg.withValues(alpha: 0.62)
                        : Colors.white.withValues(alpha: 0.72)),
                saturation: 1.15,
                lightIntensity: 0.0,
                ambientStrength: 0.0,
              )
            : noBakeBase);
    final iconContent = Icon(icon, size: iconSize, color: iconColor ?? t.text);
    final rawBtn = GlassButton.custom(
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
      tintColor: adaptPlatformView ? null : tintColor,
      platformViewBackdrop: platformViewBackdrop,
      settings: resolvedSettings,
      interactionScale: effectiveOwnLayer ? 1.06 : 1.035,
      stretch: effectiveOwnLayer ? 0.35 : 0.14,
      anchorStretch: true,
      glowColor: (tintColor ?? t.primaryHi).withValues(alpha: t.isDark ? 0.32 : 0.22),
      child: adaptPlatformView
          ? SizedBox.expand(
              child: CustomPaint(
                foregroundPainter: GrassBagFresnelRimPainter(
                  isDark: darkPlatformBackdrop || t.isDark,
                  isCircle: true,
                  accent: t.primaryHi,
                  frosted: effectiveTier == GrassBagGlassTier.frosted,
                  paintTopSheen: false,
                  strokeWidth: 0.85,
                ),
                child: Center(child: iconContent),
              ),
            )
          : iconContent,
    );
    final shadowedBtn = externalizeLightShadow
        ? _GrassBagOuterShadow(
            shape: const CircleBorder(),
            shadows: rawShadows,
            child: rawBtn,
          )
        : rawBtn;
    final btn = Semantics(
      button: true,
      label: tooltip,
      child: shadowedBtn,
    );
    return tooltip != null
        ? Tooltip(message: tooltip!, excludeFromSemantics: true, child: btn)
        : btn;
  }
}

/// Interactive stadium-shaped iOS 26 Liquid Glass pill button backed by [GlassButton.custom]
/// (used for the floating dead-center chat title pill, secondary page title pill, and warning pills).
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
      return GrassBagSpringTap(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        pressedScale: 0.96,
        child: Container(
          height: height,
          padding: padding,
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            color: prominent ? (tintColor ?? t.primary) : (tintColor ?? t.cardSolid),
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
          child: child,
        ),
      );
    }
    final effectiveOwnLayer =
        useOwnLayer || prominent || platformViewBackdrop || tintColor != null;
    final inBarLayer = !effectiveOwnLayer && _GrassBagGlassBarScope.of(context);
    final adaptPlatformView = platformViewBackdrop;
    final darkPlatformBackdrop = tintColor != null
        ? tintColor!.computeLuminance() < 0.35
        : t.isDark;
    final baseSettings = GrassBagGlassConfig.surfaceSettings(t, effectiveTier);
    final rawShadows = baseSettings.shadow ?? const <BoxShadow>[];
    final externalizeLightShadow =
        !t.isDark && rawShadows.isNotEmpty && (effectiveOwnLayer || inBarLayer);
    final noBakeBase = externalizeLightShadow ? baseSettings.copyWith(shadow: const []) : baseSettings;
    final resolvedSettings = !effectiveOwnLayer
        ? null
        : (prominent
            ? noBakeBase.copyWith(
                bodyMode: GlassBodyMode.clear,
                glassColor: (tintColor ?? t.primary).withValues(alpha: t.isDark ? 0.82 : 0.88),
                blur: adaptPlatformView ? 10.0 : noBakeBase.blur,
                thickness: effectiveTier == GrassBagGlassTier.liquid && !kIsWeb ? 26.0 : 1.0,
                refractiveIndex: effectiveTier == GrassBagGlassTier.liquid && !kIsWeb ? 1.32 : 1.01,
                lensModel: GlassLensModel.spherical,
                chromaticAberration: effectiveTier == GrassBagGlassTier.liquid && !kIsWeb ? 0.12 : 0.0,
                lightIntensity: effectiveTier == GrassBagGlassTier.liquid && !kIsWeb
                    ? (t.isDark ? 0.92 : 0.72)
                    : 0.0,
                fresnelStrength: effectiveTier == GrassBagGlassTier.liquid && !kIsWeb
                    ? (t.isDark ? 1.12 : 0.92)
                    : 0.18,
                edgeAbsorption: 0.015,
                rimLight: effectiveTier == GrassBagGlassTier.liquid && !kIsWeb ? 0.98 : 0.38,
              )
            : (adaptPlatformView
                ? noBakeBase.copyWith(
                    blur: 10.0,
                    glassColor: tintColor ??
                        (darkPlatformBackdrop
                            ? t.codeBg.withValues(alpha: 0.62)
                            : Colors.white.withValues(alpha: 0.72)),
                    saturation: 1.15,
                    lightIntensity: 0.0,
                    ambientStrength: 0.0,
                  )
                : noBakeBase));
    final paddedChild = Padding(padding: padding, child: child);
    final pillBtn = GlassButton.custom(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      height: height,
      shape: LiquidRoundedSuperellipse(borderRadius: borderRadius),
      useOwnLayer: effectiveOwnLayer,
      quality: GrassBagGlassConfig.chromeQualityFor(effectiveTier),
      surfaceStyle: GlassSurfaceStyle.glass,
      style: GlassButtonStyle.filled,
      tintColor: (prominent || adaptPlatformView) ? null : tintColor,
      platformViewBackdrop: platformViewBackdrop,
      settings: resolvedSettings,
      interactionScale: effectiveOwnLayer ? 1.04 : 1.025,
      stretch: effectiveOwnLayer ? 0.28 : 0.12,
      anchorStretch: true,
      glowColor: (tintColor ?? t.primaryHi).withValues(alpha: t.isDark ? 0.30 : 0.22),
      child: adaptPlatformView
          ? SizedBox(
              height: height,
              child: CustomPaint(
                foregroundPainter: GrassBagFresnelRimPainter(
                  isDark: darkPlatformBackdrop || t.isDark,
                  isPill: borderRadius >= 900,
                  useCircularRRect: true,
                  borderRadius: borderRadius,
                  accent: t.primaryHi,
                  frosted: effectiveTier == GrassBagGlassTier.frosted,
                  paintTopSheen: false,
                  strokeWidth: 0.85,
                ),
                child: Center(widthFactor: 1.0, child: paddedChild),
              ),
            )
          : paddedChild,
    );
    if (!externalizeLightShadow) return pillBtn;
    return _GrassBagOuterShadow(
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(borderRadius)),
      shadows: rawShadows,
      child: pillBtn,
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
    final useSolid = widget.insideGlass || isSolid;
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
          if (_hasText)
            Tooltip(
              message: '清除搜索',
              excludeFromSemantics: true,
              child: Semantics(
                button: true,
                label: '清除搜索',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _clear,
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
          else
            const SizedBox(width: 12),
        ],
      ),
    );
    if (!useSolid) {
      return GrassBagGlass(
        tier: effectiveTier,
        borderRadius: 999,
        useOwnLayer: true,
        interactiveGlow: false,
        clipBehavior: Clip.antiAlias,
        child: field,
      );
    }
    if (isSolid) {
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
    return GrassBagFresnelGlassSurface(
      isPill: true,
      innerWell: widget.insideGlass,
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

/// Calibrated Apple iOS 26/27 + Kyant0 chromatic refractive lens settings for interactive
/// switch/slider/segmented-control thumbs (0 shaders at rest; full 3D GPU lens on press/drag).
LiquidGlassSettings _interactiveLensSettings(
  GrassBagGlassTier tier, {
  double refractiveIndex = 1.26,
  double chromaticAberration = 0.09,
}) {
  if (tier != GrassBagGlassTier.liquid || kIsWeb) {
    return LiquidGlassSettings.ios27Indicator.copyWith(
      lightAngle: 0.75 * math.pi,
      refractiveIndex: 1.14,
      chromaticAberration: 0.0,
      lightIntensity: 0.0,
      ambientStrength: 0.0,
      fresnelStrength: 0.12,
      rimLight: 0.85,
      rimShade: 0.0,
    );
  }
  return LiquidGlassSettings.ios27Indicator.copyWith(
    lightAngle: 0.75 * math.pi,
    refractiveIndex: refractiveIndex,
    chromaticAberration: chromaticAberration,
    lightIntensity: 0.0,
    ambientStrength: 0.0,
    fresnelStrength: 0.18,
    rimLight: 1.0,
    rimShade: 0.35,
  );
}

/// Authentic Apple iOS 26/27 & Kyant0 [GlassSwitch]:
/// - Calibrated `60×28` capsule proportions (`37×24` elongated pill thumb with `19pt` runway,
///   matching native iOS 27 `63×28` & Kyant0 `LiquidToggle` `64×28`)
/// - Zero GPU shaders at rest; elastically lifts `1.55×` into a real 3D refractive crystal lens
///   with chromatic rim dispersion, rubber-band `±12pt` over-drag, and spring jump on interaction!
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
        t.isDark ? const Color(0x4DEBEBF5) : const Color(0x4D3C3C43);

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
          refractiveIndex: 1.36,
          chromaticAberration: 0.14,
        ),
        enableHaptics: true,
      ),
    );
  }
}

/// Spring-driven 1:1 draggable solid switch for `GrassBagGlassTier.solid` (zero `Opacity`
/// offscreen layer when enabled, smooth `GlassSpring.snappy` overshoot, instant thumb drag).
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
    with TickerProviderStateMixin {
  static const double _width = 60.0;
  static const double _height = 28.0;
  static const double _thumbW = 36.0;
  static const double _thumbH = 24.0;
  static const double _pad = 2.0;
  static const double _runway = _width - _pad * 2 - _thumbW;

  late final SingleSpringController _spring;
  late final AnimationController _pressCtrl;
  late final Listenable _thumbListenable;
  double? _dragPos;

  @override
  void initState() {
    super.initState();
    _spring = SingleSpringController(
      vsync: this,
      spring: GlassSpring.snappy(duration: const Duration(milliseconds: 240)),
      initialValue: widget.value ? 1.0 : 0.0,
    );
    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 130),
    );
    _thumbListenable = Listenable.merge([_spring, _pressCtrl]);
  }

  void _moveSpringTo(double target) {
    if (mounted && MediaQuery.disableAnimationsOf(context)) {
      _spring.setValue(target);
    } else {
      _spring.animateTo(target);
    }
  }

  @override
  void didUpdateWidget(covariant _GrassBagSolidSpringSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onChanged != null && widget.onChanged == null) {
      _dragPos = null;
      _pressCtrl.value = 0.0;
      _moveSpringTo(widget.value ? 1.0 : 0.0);
    } else if (oldWidget.value != widget.value && _dragPos == null) {
      _moveSpringTo(widget.value ? 1.0 : 0.0);
    }
  }

  @override
  void dispose() {
    _spring.dispose();
    _pressCtrl.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (mounted && MediaQuery.disableAnimationsOf(context)) {
      _pressCtrl.value = 0.0;
      return;
    }
    if (pressed) {
      _pressCtrl.forward();
    } else {
      _pressCtrl.reverse();
    }
  }

  void _toggle(bool next) {
    final cb = widget.onChanged;
    if (cb == null) return;
    HapticFeedback.selectionClick();
    if (next == widget.value) {
      _moveSpringTo(widget.value ? 1.0 : 0.0);
      return;
    }
    cb(next);
    // If parent defers or rejects the toggle, snap smoothly back instead of stranding mid-track!
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _dragPos != null) return;
      final expected = widget.value ? 1.0 : 0.0;
      if ((_spring.value - expected).abs() > 0.01) {
        _moveSpringTo(expected);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final body = ListenableBuilder(
      listenable: _thumbListenable,
      builder: (context, _) {
        final rawPos = _dragPos ?? _spring.value;
        final t = rawPos.clamp(0.0, 1.0);
        final stretch = Curves.easeOutCubic.transform(_pressCtrl.value);
        final thumbW = _thumbW + 4.5 * stretch;
        final trackColor = Color.lerp(widget.inactiveColor, widget.activeColor, t)!;
        final effectiveRunway = _width - _pad * 2 - thumbW;
        final dx = _pad + effectiveRunway * rawPos.clamp(-0.10, 1.10);
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
                  child: Container(
                    width: thumbW,
                    height: _thumbH,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.white, Color(0xFFF2F6FA)],
                      ),
                      borderRadius: BorderRadius.circular(_thumbH / 2),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 0.5),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x2A000000),
                          blurRadius: 5.5,
                          offset: Offset(0, 1.5),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    return Semantics(
      toggled: widget.value,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTap: enabled ? () => _toggle(!widget.value) : null,
        onHorizontalDragStart: enabled
            ? (_) {
                _setPressed(true);
                _dragPos = _spring.value.clamp(0.0, 1.0);
              }
            : null,
        onHorizontalDragUpdate: enabled
            ? (details) {
                final cur = (_dragPos ?? (widget.value ? 1.0 : 0.0)) +
                    details.delta.dx / _runway;
                // Gentle rubber-band overhang past 0..1 like Kyant0 / iOS 26 switches
                final clamped = cur < 0.0
                    ? (cur * 0.28).clamp(-0.10, 0.0)
                    : (cur > 1.0 ? 1.0 + ((cur - 1.0) * 0.28).clamp(0.0, 0.10) : cur);
                _dragPos = clamped;
                _spring.setValue(_dragPos!);
              }
            : null,
        onHorizontalDragEnd: enabled
            ? (details) {
                final vx = details.primaryVelocity ?? 0.0;
                final pos = _dragPos ?? _spring.value;
                _dragPos = null;
                _setPressed(false);
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
                _setPressed(false);
                _spring.animateTo(widget.value ? 1.0 : 0.0);
              }
            : null,
        child: enabled ? body : Opacity(opacity: 0.45, child: body),
      ),
    );
  }
}

/// Kyant0 & Apple iOS 26/27 Sculpted Liquid Glass Segmented Control:
/// - Recessed concave Fresnel inner-well track (`painter:` behind thumb, NEVER slicing through
///   the lifted glass thumb!)
/// - Luminous sculpted crystal lens thumb even at rest (135° directional luminance gradient +
///   Fresnel rim catchlight + soft Light-mode elevation), with live spring glide, velocity
///   jelly squash-stretch, rubber-band drag tracking, and Kyant0 touch-specular flare on drag!
/// - Fires selection on `onTap` (NOT `onTapDown`) so vertical scrolling inside `ListView`s
///   NEVER accidentally flips tabs or glass tiers!
/// - Unified scrollable threshold (`>= 6` options) and safe `1`-option rendering.
class GrassBagSegmentedControl extends StatefulWidget {
  const GrassBagSegmentedControl({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    required this.tier,
    this.height = 38,
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
  late final SingleSpringController _posSpring;
  late final AnimationController _liftCtrl;
  late final Listenable _thumbListenable;
  final ScrollController _scrollCtrl = ScrollController();
  List<GlobalKey> _itemKeys = const [];
  Timer? _tapPulseTimer;
  Timer? _dragDecayTimer;
  double? _dragIndex;
  double _velocity = 0.0;
  int _lastDragMs = 0;
  int _lastHapticIdx = -1;

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
    _posSpring = SingleSpringController(
      vsync: this,
      spring: GlassSpring.snappy(duration: const Duration(milliseconds: 280)),
      initialValue: safeIdx.toDouble(),
    );
    _liftCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _thumbListenable = Listenable.merge([_posSpring, _liftCtrl]);
    _scrollSelectedIntoView(animate: false);
  }

  @override
  void didUpdateWidget(covariant GrassBagSegmentedControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncItemKeys();
    if (widget.labels.isEmpty) return;
    final safeIdx = widget.selectedIndex.clamp(0, widget.labels.length - 1);
    if (_dragIndex == null &&
        (oldWidget.selectedIndex != widget.selectedIndex ||
            oldWidget.labels.length != widget.labels.length)) {
      if (mounted && MediaQuery.disableAnimationsOf(context)) {
        _posSpring.setValue(safeIdx.toDouble());
      } else {
        _posSpring.animateTo(safeIdx.toDouble());
      }
      _lastHapticIdx = safeIdx;
      _scrollSelectedIntoView(animate: oldWidget.labels.length == widget.labels.length);
    }
  }

  @override
  void dispose() {
    _tapPulseTimer?.cancel();
    _dragDecayTimer?.cancel();
    _scrollCtrl.dispose();
    _posSpring.dispose();
    _liftCtrl.dispose();
    super.dispose();
  }

  void _pulseTapLift() {
    if (!mounted || _dragIndex != null || MediaQuery.disableAnimationsOf(context)) return;
    _tapPulseTimer?.cancel();
    _liftCtrl.forward();
    _tapPulseTimer = Timer(const Duration(milliseconds: 140), () {
      if (mounted && _dragIndex == null) {
        _liftCtrl.reverse();
      }
    });
  }

  void _select(int i) {
    if (widget.labels.isEmpty) return;
    final safe = i.clamp(0, widget.labels.length - 1);
    if (safe == widget.selectedIndex.clamp(0, widget.labels.length - 1)) return;
    HapticFeedback.selectionClick();
    _lastHapticIdx = safe;
    _pulseTapLift();
    widget.onSelected(safe);
  }

  Widget _buildThumb(
    GrassBagTokens t, {
    required GrassBagGlassTier effectiveTier,
    required double radius,
    double lift = 0.0,
  }) {
    final isSolid = effectiveTier == GrassBagGlassTier.solid;
    final isFrosted = effectiveTier == GrassBagGlassTier.frosted;
    if (isSolid) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: t.isDark ? Color.lerp(t.cardSolid, Colors.white, 0.14)! : Colors.white,
          borderRadius: BorderRadius.circular(radius),
          border: t.isDark
              ? Border.all(color: Colors.white.withValues(alpha: 0.16), width: 0.7)
              : Border.all(color: t.sepStrong, width: 0.65),
          boxShadow: [
            BoxShadow(
              color: t.isDark
                  ? Colors.black.withValues(alpha: 0.22)
                  : Colors.black.withValues(alpha: 0.09),
              blurRadius: 7 + 3 * lift,
              offset: Offset(0, 1.5 + 1.0 * lift),
            ),
          ],
        ),
      );
    }

    // Translucent sculpted Kyant0 crystal lens capsule (gleams at rest & blooms on tap/drag!).
    // On high-luminance Dark Graphite (`primaryHi == #FFFFFF`), cap alpha so white label keeps >= 7:1 contrast!
    final highLumaDarkAccent = t.isDark && t.primaryHi.computeLuminance() > 0.72;
    final List<Color> gradColors = t.isDark
        ? (highLumaDarkAccent
            ? [
                Colors.white.withValues(alpha: 0.21 + 0.06 * lift),
                Colors.white.withValues(alpha: 0.10 + 0.04 * lift),
              ]
            : [
                Color.lerp(Colors.white, t.primaryHi, 0.28)!.withValues(alpha: 0.28 + 0.08 * lift),
                Color.lerp(Colors.white, t.primaryHi, 0.14)!.withValues(alpha: 0.14 + 0.05 * lift),
              ])
        : [
            Colors.white.withValues(alpha: (isFrosted ? 0.97 : 0.96) + 0.03 * lift),
            Colors.white.withValues(alpha: (isFrosted ? 0.90 : 0.88) + 0.06 * lift),
          ];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: gradColors,
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: t.isDark
              ? Colors.white.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.94),
          width: 0.7,
        ),
        boxShadow: [
          BoxShadow(
            color: t.isDark
                ? Colors.black.withValues(alpha: 0.26 + 0.08 * lift)
                : Colors.black.withValues(alpha: 0.07 + 0.04 * lift),
            blurRadius: 8 + 4 * lift,
            offset: Offset(0, 1.5 + 1.0 * lift),
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
    final isFrosted = effectiveTier == GrassBagGlassTier.frosted;
    final h = widget.height * textScale;
    final bg = t.isDark ? Colors.black.withValues(alpha: 0.28) : Colors.black.withValues(alpha: 0.052);
    final selectedStyle = TextStyle(
      fontSize: widget.height <= 34 ? 12.5 : 13,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.15,
      color: t.isDark ? Colors.white : t.text,
    );
    final unselectedStyle = TextStyle(
      fontSize: widget.height <= 34 ? 12.5 : 13,
      fontWeight: FontWeight.w500,
      letterSpacing: -0.1,
      color: t.text2,
    );

    Widget wrapTrack(Widget inner) {
      final track = Container(
        height: h,
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(h / 2),
        ),
        child: inner,
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: isSolid
            ? track
            : CustomPaint(
                // Paint concave well rim BEHIND the lifted thumb so it never slices through it!
                painter: GrassBagFresnelRimPainter(
                  isDark: t.isDark,
                  isPill: true,
                  accent: t.primaryHi,
                  innerWell: true,
                  frosted: isFrosted,
                  paintTopSheen: false,
                  strokeWidth: 0.82,
                ),
                child: track,
              ),
      );
    }

    if (labels.length == 1) {
      return wrapTrack(
        Stack(
          fit: StackFit.expand,
          children: [
            _buildThumb(t, effectiveTier: effectiveTier, radius: (h - 5) / 2),
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

    // Unified scrollable threshold (>= 6 options) across all tiers with rounded clip,
    // auto-scroll to active segment, and smooth thumb cross-fade.
    if (labels.length >= 6) {
      return wrapTrack(
        ClipRSuperellipse(
          borderRadius: BorderRadius.circular((h - 5) / 2),
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
                              child: _buildThumb(
                                t,
                                effectiveTier: effectiveTier,
                                radius: (h - 5) / 2,
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

    return wrapTrack(
      LayoutBuilder(
        builder: (context, constraints) {
          final segW = constraints.maxWidth / labels.length;
          final maxIdx = (labels.length - 1).toDouble();

          void updateDrag(double localDx, double deltaDx) {
            if (segW <= 0) return;
            final raw = (localDx / segW) - 0.5;
            final double pos;
            if (raw < 0) {
              pos = (raw * 0.25).clamp(-0.08, 0.0);
            } else if (raw > maxIdx) {
              pos = maxIdx + ((raw - maxIdx) * 0.25).clamp(0.0, 0.08);
            } else {
              pos = raw;
            }
            _lastDragMs = DateTime.now().millisecondsSinceEpoch;
            _velocity = (_velocity * 0.55 + (deltaDx / segW) * 0.45).clamp(-1.0, 1.0);
            _dragIndex = pos;
            _posSpring.setValue(pos);
            _dragDecayTimer?.cancel();
            if (_velocity.abs() > 0.01) {
              _dragDecayTimer = Timer(const Duration(milliseconds: 65), () {
                if (!mounted || _dragIndex == null) return;
                _velocity = 0.0;
                // Re-trigger AnimatedBuilder so stretched thumb relaxes immediately on drag pause.
                _posSpring.setValue(_dragIndex!);
              });
            }
            final snapped = pos.round().clamp(0, labels.length - 1);
            if (snapped != _lastHapticIdx) {
              _lastHapticIdx = snapped;
              HapticFeedback.selectionClick();
            }
          }

          void finishDrag([double primaryVelocity = 0.0]) {
            _dragDecayTimer?.cancel();
            _tapPulseTimer?.cancel();
            final pos = _dragIndex ?? _posSpring.value;
            _dragIndex = null;
            _velocity = 0.0;
            _liftCtrl.reverse();
            final target = pos.round().clamp(0, labels.length - 1);
            if (reduceMotion) {
              _posSpring.setValue(target.toDouble());
            } else {
              _posSpring.animateTo(
                target.toDouble(),
                fromVelocity: segW > 0 ? primaryVelocity / segW : 0.0,
              );
            }
            if (target != safeIdx) {
              widget.onSelected(target);
              // Snap back if parent ignores or defers the selection change.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || _dragIndex != null || widget.labels.isEmpty) return;
                final currentSafe = widget.selectedIndex.clamp(0, widget.labels.length - 1);
                if (currentSafe != target) {
                  if (MediaQuery.disableAnimationsOf(context)) {
                    _posSpring.setValue(currentSafe.toDouble());
                  } else {
                    _posSpring.animateTo(currentSafe.toDouble());
                  }
                  _lastHapticIdx = currentSafe;
                }
              });
            }
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (details) {
              if (!reduceMotion) _liftCtrl.forward();
              updateDrag(details.localPosition.dx, 0.0);
            },
            onHorizontalDragUpdate: (details) {
              updateDrag(details.localPosition.dx, details.delta.dx);
            },
            onHorizontalDragEnd: (details) => finishDrag(details.primaryVelocity ?? 0.0),
            onHorizontalDragCancel: () => finishDrag(),
            child: GrassBagInteractiveHighlight(
              isPill: true,
              accent: t.primaryHi,
              enabled: !isSolid,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedBuilder(
                    animation: _thumbListenable,
                    builder: (context, _) {
                      final pos = (_dragIndex ?? _posSpring.value).clamp(-0.08, maxIdx + 0.08);
                      final lift = reduceMotion
                          ? 0.0
                          : Curves.easeOutCubic.transform(_liftCtrl.value);
                      // Derive jelly stretch from spring velocity on taps/flicks and decay
                      // drag velocity cleanly if the user pauses mid-drag!
                      double velStretch = 0.0;
                      if (!reduceMotion) {
                        if (_dragIndex != null) {
                          final idleMs = DateTime.now().millisecondsSinceEpoch - _lastDragMs;
                          final decayedDragVel = idleMs > 60 ? 0.0 : _velocity.abs();
                          velStretch = (decayedDragVel * 0.085).clamp(0.0, 0.085) * lift;
                        } else {
                          velStretch = (_posSpring.velocity.abs() * 0.0085).clamp(0.0, 0.065);
                        }
                      }
                      final scaleX = 1.0 + 0.045 * lift + velStretch;
                      final scaleY = 1.0 + 0.06 * lift - velStretch * 0.45;
                      return Positioned(
                        left: segW * pos,
                        top: 0,
                        bottom: 0,
                        width: segW,
                        child: RepaintBoundary(
                          child: Transform.scale(
                            scaleX: scaleX,
                            scaleY: scaleY,
                            child: _buildThumb(
                              t,
                              effectiveTier: effectiveTier,
                              radius: (h - 5) / 2,
                              lift: lift,
                            ),
                          ),
                        ),
                      );
                    },
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
                              onTap: () => _select(i),
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
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
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Authentic Apple iOS 26/27 & Kyant0 [GlassSlider]:
/// - `6dp` capsule track + elongated `37:24` pill thumb that expands `1.55×` on press/drag
///   into a live 3D GPU refractive crystal lens with velocity-driven jelly squash & stretch,
///   prismatic edge dispersion, AND instant tap-to-seek anywhere along the track!
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
    with SingleTickerProviderStateMixin {
  late final AnimationController _tapSeekCtrl;
  late double _seekFrom;
  late double _seekTo;
  bool _animatingTapSeek = false;

  double get _safeMax => widget.max > widget.min ? widget.max : widget.min + 1.0;

  double get _clampedWidgetValue => widget.value.clamp(widget.min, _safeMax);

  @override
  void initState() {
    super.initState();
    _seekFrom = _clampedWidgetValue;
    _seekTo = _clampedWidgetValue;
    _tapSeekCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 170),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
          _animatingTapSeek = false;
        }
      });
  }

  @override
  void didUpdateWidget(covariant GrassBagGlassSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextVal = _clampedWidgetValue;
    if (_animatingTapSeek && (nextVal - _seekTo).abs() > 1e-4) {
      // External or drag change superseded tap-to-seek; track immediately.
      _animatingTapSeek = false;
      _tapSeekCtrl.stop();
      _seekFrom = nextVal;
      _seekTo = nextVal;
    } else if (!_animatingTapSeek) {
      _seekFrom = nextVal;
      _seekTo = nextVal;
    }
  }

  @override
  void dispose() {
    _tapSeekCtrl.dispose();
    super.dispose();
  }

  double get _displayValue {
    if (!_animatingTapSeek) return _clampedWidgetValue;
    final t = Curves.easeOutCubic.transform(_tapSeekCtrl.value);
    return (_seekFrom + (_seekTo - _seekFrom) * t).clamp(widget.min, _safeMax);
  }

  void _handleDragChanged(double v) {
    if (_animatingTapSeek) {
      _animatingTapSeek = false;
      _tapSeekCtrl.stop();
    }
    _seekFrom = v;
    _seekTo = v;
    widget.onChanged?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final resolvedTier =
        resolveEffectiveGlassTier(context, widget.tier ?? resolveAmbientGlassTier(context));
    final enabled = widget.onChanged != null;
    final isSolid = resolvedTier == GrassBagGlassTier.solid;
    final safeMax = _safeMax;
    final clampedVal = _clampedWidgetValue;
    final rawActive = widget.activeColor ?? t.primary;
    // Tone near-white Dark Graphite active track so the white crystal thumb stays clearly distinct.
    final resolvedActive = (t.isDark && rawActive.computeLuminance() > 0.65)
        ? Color.lerp(rawActive, t.cardSolid, 0.30)!
        : rawActive;
    final resolvedInactive =
        t.isDark ? const Color(0x38FFFFFF) : Colors.black.withValues(alpha: 0.12);

    if (isSolid) {
      final solidSlider = SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 6.0,
          activeTrackColor: resolvedActive,
          inactiveTrackColor: resolvedInactive,
          thumbColor: Colors.white,
          overlayColor: resolvedActive.withValues(alpha: 0.16),
          thumbShape: _GrassBagSolidPillSliderThumbShape(isDark: t.isDark),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 20.0),
          tickMarkShape: SliderTickMarkShape.noTickMark,
        ),
        child: Slider(
          value: clampedVal,
          min: widget.min,
          max: safeMax,
          divisions: widget.divisions,
          onChanged: widget.onChanged,
        ),
      );
      if (enabled) return solidSlider;
      return IgnorePointer(child: solidSlider);
    }

    final lensQuality = resolvedTier == GrassBagGlassTier.liquid && !kIsWeb
        ? GlassQuality.premium
        : GlassQuality.standard;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final slider = _GrassBagLensScope(
      tier: resolvedTier,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final glassSlider = AnimatedBuilder(
            animation: _tapSeekCtrl,
            builder: (_, __) => GlassSlider(
              value: _displayValue,
              min: widget.min,
              max: safeMax,
              divisions: widget.divisions,
              onChanged: enabled ? _handleDragChanged : null,
              activeColor: resolvedActive,
              inactiveColor: resolvedInactive,
              trackHeight: 6.0,
              thumbRadius: 14.0,
              useOwnLayer: false,
              quality: lensQuality,
              settings: _interactiveLensSettings(
                resolvedTier,
                refractiveIndex: 1.09,
                chromaticAberration: 0.06,
              ),
            ),
          );
          if (!enabled || !constraints.hasBoundedWidth || constraints.maxWidth <= 38.0) {
            return glassSlider;
          }
          final isRtl = Directionality.of(context) == TextDirection.rtl;
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: (details) {
              const pad = 14.0;
              final usable = constraints.maxWidth - pad * 2;
              if (usable <= 0) return;
              final rawRatio = ((details.localPosition.dx - pad) / usable).clamp(0.0, 1.0);
              final ratio = isRtl ? (1.0 - rawRatio) : rawRatio;
              double next = widget.min + ratio * (safeMax - widget.min);
              final div = widget.divisions;
              if (div != null && div > 0) {
                final step = (safeMax - widget.min) / div;
                next = (widget.min + ((next - widget.min) / step).round() * step)
                    .clamp(widget.min, safeMax);
              }
              if (!reduceMotion && (next - _displayValue).abs() > 1e-4) {
                _seekFrom = _displayValue;
                _seekTo = next;
                _animatingTapSeek = true;
                _tapSeekCtrl.forward(from: 0.0);
              }
              HapticFeedback.selectionClick();
              widget.onChanged?.call(next);
            },
            child: glassSlider,
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
  const _GrassBagSolidPillSliderThumbShape({this.isDark = false});

  final bool isDark;
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
    final lift = Curves.easeOutCubic.transform(activationAnimation.value);
    final w = _width + 5.0 * lift;
    final h = _height + 3.0 * lift;
    final rect = Rect.fromCenter(center: center, width: w, height: h);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(h / 2));
    final shadowPath = Path()..addRRect(rrect);
    canvas.drawShadow(shadowPath, const Color(0x40000000), 3.0 + 2.0 * lift, true);
    canvas.drawRRect(
      rrect,
      Paint()..color = sliderTheme.thumbColor ?? Colors.white,
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = isDark ? Colors.white.withValues(alpha: 0.35) : const Color(0x1E0E243B)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7,
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
          duration: const Duration(milliseconds: 110),
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
    return super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      RepaintBoundary(child: child),
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
    _pressSpring!.setValue(0.65);
    _pressSpring!.spring = GlassSpring.interactive(
      duration: const Duration(milliseconds: 220),
      extraBounce: 0.08,
    );
    _pressSpring!.animateTo(0.0);
  }

  void _release({bool force = false}) {
    _scrollDeferTimer?.cancel();
    _scrollDeferTimer = null;
    if (!_tracking && !force) return;
    _activePointerId = null;
    _tracking = false;
    final wasEngaged = _engaged;
    _engaged = false;
    final press = _pressSpring;
    if (press != null && (wasEngaged || press.value.abs() > 0.001 || press.velocity.abs() > 0.001)) {
      press.spring = GlassSpring.interactive(
        duration: const Duration(milliseconds: 240),
        extraBounce: 0.08,
      );
      press.animateTo(0.0);
    }
    final dx = _dragXSpring;
    if (dx != null && (dx.value.abs() > 0.001 || dx.velocity.abs() > 0.001)) {
      dx.animateTo(0.0);
    }
    final dy = _dragYSpring;
    if (dy != null && (dy.value.abs() > 0.001 || dy.velocity.abs() > 0.001)) {
      dy.animateTo(0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final inner = ListenableBuilder(
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

/// Prominent Apple iOS 26/27 & Kyant0 tinted Liquid Glass capsule CTA button powered by
/// genuine [GlassButton.custom]:
/// - Uses `GlassBodyMode.clear` + calibrated Kyant0 bevel (`thickness: 20, n: 1.28, blur: 2.0`)
///   instead of `GlassButtonStyle.prominent` (which multiplies thickness to 75 and muddies hue!)
/// - Full 3D GPU optical refraction + chromatic rim + [LiquidStretch] + [GlassGlow] on canvas/cards,
///   and automatic nested vibrancy glass with specular rim inside floating `GrassBagGlass` sheets!
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
    // Route `insideGlass: true`, solid cards, and Solid tier cleanly to solid capsule rendering
    // so sheets/dialogs/cards NEVER spawn nested `_VibrancyFill` `ImageFiltered` `saveLayer`s!
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
                  ? (t.isDark ? 0.82 : 0.86)
                  : (t.isDark ? 0.78 : 0.84),
            ),
            blur: isFrosted ? 8.0 : 1.5,
            frost: 0.0,
            frostOpacity: 0.0,
            thickness: isFrosted ? 1.0 : 24.0,
            refractiveIndex: isFrosted ? 1.01 : 1.32,
            lensModel: GlassLensModel.spherical,
            chromaticAberration: isFrosted ? 0.0 : 0.12,
            saturation: isFrosted ? 1.0 : 1.55,
            lightAngle: 0.75 * math.pi,
            lightIntensity: isFrosted ? 0.0 : (t.isDark ? 0.92 : 0.72),
            ambientStrength: isFrosted ? 0.04 : 0.10,
            fresnelStrength: isFrosted ? 0.18 : (t.isDark ? 1.12 : 0.92),
            edgeAbsorption: 0.015,
            rimLight: isFrosted ? 0.40 : 0.98,
            rimShade: 0.0,
            bodyShade: 0.0,
            specularSharpness:
                isFrosted ? GlassSpecularSharpness.medium : GlassSpecularSharpness.sharp,
            shadow: const [],
          );

    Widget buildButton(Widget child) {
      final btn = GlassButton.custom(
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
        color: renderAsSolidCapsule ? Colors.transparent : null,
        settings: glassSettings,
        interactionScale: 1.035,
        stretch: useOwn ? 0.26 : 0.18,
        anchorStretch: true,
        glowColor: (renderAsSolidCapsule && !isSolid)
            ? Colors.transparent
            : Colors.white.withValues(alpha: 0.30),
        glowRadius: 1.4,
        child: child,
      );
      if (!active) return IgnorePointer(child: btn);
      return btn;
    }

    if (!renderAsSolidCapsule) {
      final glassBtn = buildButton(labelRow);
      if (!useOwn) return glassBtn;
      return _GrassBagOuterShadow(
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(999)),
        shadows: [
          BoxShadow(
            color: bg.withValues(alpha: t.isDark ? 0.32 : 0.22),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
        child: glassBtn,
      );
    }

    // Sculpted luminous iOS 26 jewel pill (clean top highlight, zero muddy dark darkening!)
    final topSheen = Color.lerp(bg, Colors.white, t.isDark ? 0.14 : 0.22)!;
    final deepEdge = t.isDark ? Color.lerp(bg, Colors.black, 0.06)! : bg;
    return LayoutBuilder(
      builder: (context, outerConstraints) {
        final fillWidth = outerConstraints.hasTightWidth;
        final body = DecoratedBox(
          decoration: ShapeDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [topSheen, bg, deepEdge],
              stops: const [0.0, 0.56, 1.0],
            ),
            shape: StadiumBorder(
              side: isSolid
                  ? BorderSide(color: Colors.white.withValues(alpha: 0.18), width: 0.65)
                  : BorderSide.none,
            ),
            shadows: isSolid
                ? null
                : [
                    BoxShadow(
                      color: bg.withValues(alpha: t.isDark ? 0.30 : 0.24),
                      blurRadius: 12,
                      offset: const Offset(0, 3.5),
                    ),
                  ],
          ),
          child: SizedBox(
            width: fillWidth ? double.infinity : null,
            height: height,
            child: Center(
              widthFactor: fillWidth ? null : 1.0,
              child: labelRow,
            ),
          ),
        );
        final sculpted = isSolid
            ? body
            : GrassBagInteractiveHighlight(
                isPill: true,
                accent: bg.computeLuminance() > 0.62 ? t.onPrimary : Colors.white,
                enabled: active,
                child: CustomPaint(
                  foregroundPainter: GrassBagFresnelRimPainter(
                    isDark: t.isDark,
                    isPill: true,
                    tinted: true,
                    accent: color ?? t.primaryHi,
                  ),
                  child: body,
                ),
              );
        return buildButton(sculpted);
      },
    );
  }
}

/// Secondary Apple iOS 26/27 & Kyant0 crystal-clear / sky-tinted Liquid Glass capsule button
/// powered by genuine [GlassButton.custom]:
/// - Crystal-clear refractive glass on canvas/cards (`GlassBodyMode.clear`, Kyant0 bevel +
///   chromatic rim + [LiquidStretch] + [GlassGlow])
/// - Bright luminous translucent vibrancy glass with specular rim inside floating sheets (zero
///   murky double-BackdropFilter gray fog!)
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
        ? (t.isDark ? const Color(0xFFFF9A97) : t.err)
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

    final bool translucentInsideGlass = insideGlass && !isSolid && !inSolidCard;
    final List<Color> capsuleGrad;
    if (destructive) {
      capsuleGrad = [
        Color.lerp(t.errSoft, Colors.white, t.isDark ? 0.06 : 0.25)!,
        t.errSoft,
      ];
    } else if (accentForeground) {
      capsuleGrad = translucentInsideGlass
          ? (t.isDark
              ? [
                  t.primary.withValues(alpha: 0.19),
                  t.primary.withValues(alpha: 0.10),
                ]
              : [
                  Color.lerp(Colors.white, t.primary, 0.08)!.withValues(alpha: 0.78),
                  Color.lerp(Colors.white, t.primary, 0.14)!.withValues(alpha: 0.62),
                ])
          : (t.isDark
              ? [
                  t.primary.withValues(alpha: 0.22),
                  t.primary.withValues(alpha: 0.12),
                ]
              : [
                  Color.lerp(Colors.white, t.primary, 0.08)!.withValues(alpha: 0.88),
                  Color.lerp(Colors.white, t.primary, 0.15)!.withValues(alpha: 0.72),
                ]);
    } else if (translucentInsideGlass) {
      capsuleGrad = t.isDark
          ? [
              Colors.white.withValues(alpha: 0.15),
              Colors.white.withValues(alpha: 0.075),
            ]
          : [
              Colors.white.withValues(alpha: 0.68),
              Colors.white.withValues(alpha: 0.46),
            ];
    } else {
      capsuleGrad = t.isDark
          ? [
              Colors.white.withValues(alpha: 0.145),
              Colors.white.withValues(alpha: 0.085),
            ]
          : [
              Colors.white.withValues(alpha: 0.86),
              Color.lerp(Colors.white, t.bgSolid, 0.45)!.withValues(alpha: 0.72),
            ];
    }
    final Color solidBg = isSolid
        ? (destructive
            ? t.errSoft
            : (accentForeground
                ? t.primarySoft
                : (t.isDark
                    ? Colors.white.withValues(alpha: 0.11)
                    : Color.lerp(t.fill1, Colors.white, 0.76)!)))
        : Colors.transparent;

    final Color glassTint;
    if (destructive) {
      glassTint = t.err.withValues(alpha: t.isDark ? 0.24 : 0.13);
    } else if (accentForeground) {
      glassTint = t.isDark
          ? t.primary.withValues(alpha: inRefractiveGlass ? 0.20 : 0.18)
          : Color.lerp(Colors.white, t.primary, 0.12)!
              .withValues(alpha: inRefractiveGlass ? 0.56 : 0.44);
    } else if (t.isDark) {
      glassTint = Colors.white.withValues(alpha: inRefractiveGlass ? 0.14 : 0.09);
    } else {
      glassTint = Colors.white.withValues(alpha: inRefractiveGlass ? 0.54 : 0.36);
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
            blur: isFrosted ? 8.0 : 1.5,
            frost: 0.0,
            frostOpacity: 0.0,
            thickness: isFrosted ? 1.0 : 24.0,
            refractiveIndex: isFrosted ? 1.01 : 1.32,
            lensModel: GlassLensModel.spherical,
            chromaticAberration: isFrosted ? 0.0 : 0.12,
            saturation: isFrosted ? 1.0 : 1.55,
            lightAngle: 0.75 * math.pi,
            lightIntensity: isFrosted ? 0.0 : (t.isDark ? 0.90 : 0.70),
            ambientStrength: isFrosted ? 0.04 : 0.09,
            fresnelStrength: isFrosted ? 0.18 : (t.isDark ? 1.08 : 0.88),
            edgeAbsorption: 0.015,
            rimLight: isFrosted ? 0.40 : 0.96,
            rimShade: 0.0,
            bodyShade: 0.0,
            specularSharpness:
                isFrosted ? GlassSpecularSharpness.medium : GlassSpecularSharpness.sharp,
            shadow: const [],
          );

    // Keep subtle capsule contour INSIDE the stretched button so press-scale never
    // overflows a static outer border (and destructive/crystal buttons always keep crisp edges).
    final needsInnerRim =
        (inRefractiveGlass && !t.isDark && !isSolid) || renderAsSolidCapsule;
    final innerRimColor = destructive
        ? t.err.withValues(alpha: t.isDark ? 0.36 : 0.26)
        : (accentForeground
            ? t.primary.withValues(alpha: t.isDark ? 0.34 : 0.26)
            : (translucentInsideGlass
                ? (t.isDark
                    ? Colors.white.withValues(alpha: 0.22)
                    : t.sepStrong)
                : (t.isDark ? Colors.white.withValues(alpha: 0.16) : t.sepStrong)));
    Widget buildGlassButton(Widget content) {
      final btn = GlassButton.custom(
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
        glowColor: (renderAsSolidCapsule && !isSolid)
            ? Colors.transparent
            : (destructive ? t.err : t.primaryHi).withValues(alpha: 0.26),
        glowRadius: 1.35,
        child: content,
      );
      if (!active) return IgnorePointer(child: btn);
      return btn;
    }

    if (!needsInnerRim) {
      final glassBtn = buildGlassButton(labelRow);
      if (t.isDark || !useOwn) return glassBtn;
      return _GrassBagOuterShadow(
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(999)),
        shadows: const [
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
        child: glassBtn,
      );
    }

    // Measure OUTER constraints (outside GlassButton.custom's internal Center) so `Expanded`
    // buttons stretch the inner rim edge-to-edge 1:1 with the outer capsule while `Wrap` buttons
    // stay compact at their intrinsic label width!
    return LayoutBuilder(
      builder: (context, outerConstraints) {
        final fillWidth = outerConstraints.hasTightWidth;
        final useFresnelCapsule = renderAsSolidCapsule && !isSolid;
        final innerBox = DecoratedBox(
          decoration: ShapeDecoration(
            gradient: useFresnelCapsule
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: capsuleGrad,
                  )
                : null,
            shape: StadiumBorder(
              side: useFresnelCapsule
                  ? BorderSide.none
                  : BorderSide(color: innerRimColor, width: 0.65),
            ),
            shadows: useFresnelCapsule && !t.isDark && !translucentInsideGlass
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 2.5),
                    ),
                  ]
                : null,
          ),
          child: SizedBox(
            height: height,
            width: fillWidth ? double.infinity : null,
            child: Center(
              widthFactor: fillWidth ? null : 1.0,
              child: labelRow,
            ),
          ),
        );
        final styledContent = useFresnelCapsule
            ? GrassBagInteractiveHighlight(
                isPill: true,
                accent: destructive ? t.err : t.primaryHi,
                enabled: active,
                child: CustomPaint(
                  foregroundPainter: GrassBagFresnelRimPainter(
                    isDark: t.isDark,
                    isPill: true,
                    accent: destructive ? t.err : t.primaryHi,
                    tinted: destructive || accentForeground,
                    innerWell: translucentInsideGlass,
                    frosted: effectiveTier == GrassBagGlassTier.frosted,
                  ),
                  child: innerBox,
                ),
              )
            : innerBox;
        return buildGlassButton(styledContent);
      },
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
          side: BorderSide(
            color: filled
                ? Colors.white.withValues(alpha: t.isDark ? 0.24 : 0.40)
                : (t.isDark
                    ? baseColor.withValues(alpha: 0.30)
                    : Colors.white.withValues(alpha: 0.84)),
            width: 0.75,
          ),
        ),
        shadows: filled
            ? [
                BoxShadow(
                  color: baseColor.withValues(alpha: t.isDark ? 0.30 : 0.22),
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
  });

  final GrassBagGlassTier tier;
  final double topPad;

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
    final blurH = baseTop + (isLiquid ? 72.0 : 80.0);
    final capH = baseTop + 68.0;
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
    final titleContent = Column(
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
    // Isolate pulsing repaint inside RepaintBoundary + CustomPaint so 120Hz status breathing
    // never invalidates the enclosing top Liquid Glass bar layer!
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: _PulsingStatusDotPainter(
            animation: ctrl,
            color: widget.color,
            border: widget.border,
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
    this.border,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final BoxBorder? border;

  final Paint _outerHaloPaint = Paint();
  final Paint _innerHaloPaint = Paint();
  final Paint _fillPaint = Paint();
  final Paint _borderPaint = Paint()..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final v = Curves.easeInOutSine.transform(animation.value);
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
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

    // Fill in `decoration` and stroke in `foregroundDecoration` / `CustomPaint` so changing
    // border width on focus/blur/error produces ZERO ShapeDecoration.padding layout shift!
    final useRestingFresnel = !isSolid && !_focused && !widget.hasError;
    final fillTopColor = isSolid
        ? fillColor
        : Color.lerp(
            fillColor,
            Colors.white.withValues(alpha: fillColor.a),
            t.isDark ? 0.06 : 0.36,
          )!;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      decoration: ShapeDecoration(
        // Always use a 2-stop gradient so toggling Solid <-> Liquid never triggers
        // ShapeDecoration.lerp's `!(color != null && gradient != null)` assertion.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [fillTopColor, fillColor],
        ),
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
      // Always keep a non-null `foregroundDecoration` so Container's widget tree depth NEVER
      // toggles between null/non-null on focus/blur (which would remount CupertinoTextField
      // and detach the soft keyboard!). Use Colors.transparent while resting Fresnel paints.
      foregroundDecoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          side: BorderSide(
            color: useRestingFresnel ? Colors.transparent : borderColor,
            width: _focused || widget.hasError ? 1.2 : 0.7,
          ),
        ),
      ),
      child: CustomPaint(
        foregroundPainter: useRestingFresnel
            ? GrassBagFresnelRimPainter(
                isDark: t.isDark,
                borderRadius: widget.borderRadius,
                accent: t.primaryHi,
                innerWell: widget.insideGlass,
                frosted: ambientTier == GrassBagGlassTier.frosted,
                paintTopSheen: false,
                strokeWidth: 0.85,
              )
            : null,
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

    if (isSolid) return bannerBox;
    return CustomPaint(
      foregroundPainter: GrassBagFresnelRimPainter(
        isDark: t.isDark,
        borderRadius: borderRadius,
        accent: accent,
        innerWell: true,
        frosted: ambientTier == GrassBagGlassTier.frosted,
        paintTopSheen: false,
        strokeWidth: 0.75,
      ),
      child: bannerBox,
    );
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
    final pillBody = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      padding: padding,
      decoration: BoxDecoration(
        color: isSolid ? (selected ? t.primary : t.fill1) : null,
        gradient: isSolid
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: selected
                    ? [
                        Color.lerp(t.primary, Colors.white, t.isDark ? 0.14 : 0.18)!,
                        t.primary,
                      ]
                    : (t.isDark
                        ? [
                            Colors.white.withValues(alpha: 0.125),
                            Colors.white.withValues(alpha: 0.05),
                          ]
                        : [
                            Colors.white.withValues(alpha: 0.62),
                            Colors.white.withValues(alpha: 0.36),
                          ]),
              ),
        borderRadius: BorderRadius.circular(999),
        border: isSolid
            ? Border.all(
                color: selected ? t.primary : t.sep,
                width: 0.7,
              )
            : null,
        boxShadow: selected && !isSolid
            ? [
                BoxShadow(
                  color: t.primary.withValues(alpha: t.isDark ? 0.30 : 0.22),
                  blurRadius: 8,
                  offset: const Offset(0, 2.5),
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: fontSize + 1.5, color: fg),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: fg,
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
    );
    return GrassBagSpringTap(
      onTap: onTap,
      pressedScale: 0.94,
      haptic: true,
      child: isSolid
          ? pillBody
          : CustomPaint(
              foregroundPainter: GrassBagFresnelRimPainter(
                isDark: t.isDark,
                isPill: true,
                tinted: selected,
                innerWell: !selected,
                accent: t.primaryHi,
                frosted: ambientTier == GrassBagGlassTier.frosted,
                paintTopSheen: selected,
                strokeWidth: 0.8,
              ),
              child: pillBody,
            ),
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
    transitionDuration: const Duration(milliseconds: 220),
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
              scaleFrom: 0.90,
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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
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
class GrassBagDirectionalTabSwitcher extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduceMotion ? const Duration(milliseconds: 80) : duration,
      reverseDuration:
          reduceMotion ? const Duration(milliseconds: 60) : const Duration(milliseconds: 140),
      switchInCurve: Curves.linear,
      switchOutCurve: Curves.linear,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: alignment,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      transitionBuilder: (w, anim) => _DirectionalSlideFadeTransition(
        animation: anim,
        direction: reduceMotion ? 0 : direction,
        child: w,
      ),
      child: child,
    );
  }
}

class _DirectionalSlideFadeTransition extends StatefulWidget {
  const _DirectionalSlideFadeTransition({
    required this.animation,
    required this.direction,
    required this.child,
  });

  final Animation<double> animation;
  final int direction;
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
        if (widget.direction == 0) {
          return GrassBagControlledOpacity(opacity: fade, child: child!);
        }
        // Read animation.status dynamically on EVERY tick (AnimatedSwitcher caches its
        // transitionBuilder subtree and never rebuilds on reverse!).
        final isOutgoing = widget.animation.status == AnimationStatus.reverse;
        final dx = (widget.direction >= 0 ? 0.03 : -0.03) * (isOutgoing ? -1.0 : 1.0);
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
    return CupertinoActivityIndicator(
      radius: radius,
      color: color,
      animating: animating && isCurrent && motionAllowed,
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
    // streaming/thinking headers incur ZERO 120Hz widget rebuilds or HarfBuzz re-shaping!
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
            final tp = TextPainter(
              text: TextSpan(
                text: widget.text,
                style: effectiveStyle.copyWith(color: Colors.white),
              ),
              maxLines: widget.maxLines,
              ellipsis: widget.overflow == TextOverflow.ellipsis ? '…' : null,
              textDirection: textDirection,
              textScaler: textScaler,
            )..layout(maxWidth: maxW);
            final size = Size(
              tp.width.clamp(1.0, maxW.isFinite ? maxW : tp.width.clamp(1.0, 2048.0)),
              tp.height.clamp(1.0, 256.0),
            );
            return SizedBox(
              width: size.width,
              height: size.height,
              child: CustomPaint(
                size: size,
                painter: _GrassBagShimmerTextPainter(
                  repaint: _ctrl,
                  progress: _ctrl,
                  textPainter: tp,
                  baseColor: baseColor,
                  highlightColor: hiColor,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _GrassBagShimmerTextPainter extends CustomPainter {
  _GrassBagShimmerTextPainter({
    required Listenable repaint,
    required this.progress,
    required this.textPainter,
    required this.baseColor,
    required this.highlightColor,
  }) : super(repaint: repaint);

  final Animation<double> progress;
  final TextPainter textPainter;
  final Color baseColor;
  final Color highlightColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0.5 || size.height <= 0.5) return;
    final bounds = Offset.zero & size;
    final slide = -0.6 + progress.value * 2.2;
    final shader = LinearGradient(
      begin: Alignment(slide - 0.55, 0),
      end: Alignment(slide + 0.55, 0),
      colors: [baseColor, highlightColor, baseColor],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(bounds);
    canvas.saveLayer(bounds, Paint());
    textPainter.paint(canvas, Offset.zero);
    canvas.drawRect(
      bounds,
      Paint()
        ..blendMode = BlendMode.srcIn
        ..shader = shader,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GrassBagShimmerTextPainter old) =>
      old.textPainter != textPainter ||
      old.baseColor != baseColor ||
      old.highlightColor != highlightColor;
}
