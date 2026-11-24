import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'grassbag_theme.dart';

/// Centralized Apple iOS 26 / iOS 27 Liquid Glass material system for GrassBag.
///
/// Built strictly on `liquid_glass_widgets` 1.19.0's simulator-calibrated
/// [LiquidGlassSettings.ios27Light] / [LiquidGlassSettings.ios27Dark] optics and
/// golden rules (`SKILL.md` Rules 1, 2 & 5):
/// - Crisp luminous frost interior for effortless text legibility (`chromaticAberration: 0`)
/// - Authentic `GlassLensModel.paraxial` (`thickness: 32`, `refractiveIndex: 1.24`, `blur: 0.6`)
///   curved edge refraction + clean `rimLight` highlight
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
    // On mobile Impeller, BOTH `liquid` and `frosted` route through `GlassQuality.premium`
    // so `GrassBagGlassBarLayer` sibling batching, `GlassBackdropGroup` blur sharing, and
    // baked light-mode shadows stay active (`frosted` uses flat thickness=0.5, n=1.01,
    // saturation=1.0 instead of unbatched `standard` double-pass BackdropFilters!).
    return switch (tier) {
      GrassBagGlassTier.liquid => GlassQuality.premium,
      GrassBagGlassTier.frosted => GlassQuality.premium,
      GrassBagGlassTier.solid => GlassQuality.minimal,
    };
  }

  /// Quality for body glass platters (overview hero card, studio diorama) — single-pass `standard`.
  static GlassQuality cardQualityFor(GrassBagGlassTier tier) => switch (tier) {
        GrassBagGlassTier.liquid => GlassQuality.standard,
        GrassBagGlassTier.frosted => GlassQuality.standard,
        GrassBagGlassTier.solid => GlassQuality.minimal,
      };

  /// Calibrated spherical Liquid Glass optical settings for floating chrome:
  /// - Pure achromatic `Colors.white` glassColor in Dark & Light modes so `render.glsl`
  ///   routes through `directMix` (authentic luminous frosted glass lift instead of dead dark tint).
  /// - `ambientRim: 0.0`, `rimLight: 0.0`, `rimShade: 0.0` (single coherent Fresnel + directional
  ///   specular model at 135° top-left; eliminates flat white wire strokes and `uNativeEdge` double-rim cliffs!).
  /// - `chromaticAberration: 0.0` (matches Apple ios26/ios27 presets, cuts bevel GPU fetches by 67%!).
  /// - `thickness: 24.0`, `refractiveIndex: 1.24–1.26` (optimal 44pt pill curvature without `maxReach` flat-clamping).
  /// - Unified `blur: 4.0` across normal & elevated chrome so `GlassBackdropGroup` shares Pass 1a blur!
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
      // saturation: 1.0 skips `ImageFilter.compose` second full-screen filter pass on Web/standard,
      // while blur 6.5–8.0 sits inside Impeller's single-downsample Gaussian sweet spot!
      final blurSigma = kIsWeb ? 8.0 : 6.5;
      if (t.isDark) {
        return LiquidGlassSettings(
          glassColor: Colors.white.withValues(alpha: elevated ? 0.16 : 0.11),
          blur: blurSigma,
          frost: 0.0,
          frostOpacity: 0.0,
          thickness: 0.5,
          refractiveIndex: 1.01,
          lensModel: GlassLensModel.spherical,
          chromaticAberration: 0.0,
          saturation: 1.0,
          lightAngle: 0.75 * math.pi,
          lightIntensity: 0.68,
          ambientStrength: 0.14,
          ambientRim: 0.0,
          fresnelStrength: 0.72,
          edgeAbsorption: 0.04,
          rimShade: 0.0,
          rimLight: 0.0,
          bodyShade: elevated ? 0.22 : 0.14,
          specularSharpness: GlassSpecularSharpness.medium,
          shadow: const [],
        );
      }
      return LiquidGlassSettings(
        glassColor: Colors.white.withValues(alpha: elevated ? 0.52 : 0.40),
        blur: blurSigma,
        frost: 0.0,
        frostOpacity: 0.0,
        thickness: 0.5,
        refractiveIndex: 1.01,
        lensModel: GlassLensModel.spherical,
        chromaticAberration: 0.0,
        saturation: 1.0,
        lightAngle: 0.75 * math.pi,
        lightIntensity: 0.56,
        ambientStrength: 0.10,
        ambientRim: 0.0,
        fresnelStrength: 0.64,
        edgeAbsorption: 0.03,
        rimShade: 0.0,
        rimLight: 0.0,
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
        glassColor: Colors.white.withValues(alpha: elevated ? 0.14 : 0.10),
        blur: 4.0,
        frost: 0.0,
        frostOpacity: 0.0,
        thickness: 24.0,
        refractiveIndex: 1.26,
        lensModel: GlassLensModel.spherical,
        chromaticAberration: 0.0,
        saturation: 1.48,
        lightAngle: 0.75 * math.pi,
        lightIntensity: 0.88,
        ambientStrength: 0.14,
        ambientRim: 0.0,
        fresnelStrength: 1.15,
        edgeAbsorption: 0.06,
        rimShade: 0.0,
        rimLight: 0.0,
        bodyShade: elevated ? 0.16 : 0.10,
        specularSharpness: GlassSpecularSharpness.medium,
        shadow: const [],
      );
    }

    return LiquidGlassSettings(
      glassColor: Colors.white.withValues(alpha: elevated ? 0.34 : 0.24),
      blur: 4.0,
      frost: 0.0,
      frostOpacity: 0.0,
      thickness: 24.0,
      refractiveIndex: 1.24,
      lensModel: GlassLensModel.spherical,
      chromaticAberration: 0.0,
      saturation: 1.65,
      lightAngle: 0.75 * math.pi,
      lightIntensity: 0.60,
      ambientStrength: 0.09,
      ambientRim: 0.0,
      fresnelStrength: 0.78,
      whitenStrength: elevated ? 0.16 : 0.12,
      whitenGated: true,
      edgeAbsorption: 0.04,
      rimShade: 0.0,
      rimLight: 0.0,
      bodyShade: 0.0,
      specularSharpness: GlassSpecularSharpness.medium,
      shadow: [
        BoxShadow(
          color: const Color(0x16000000),
          blurRadius: elevated ? 22 : 16,
          offset: Offset(0, elevated ? 8 : 5),
        ),
      ],
    );
  }

  /// Sculpted Liquid Glass for modal sheets, '+' deck, menus, dialogs, and floating phone drawer:
  /// single Gaussian bokeh blur (`10dp`) + smooth spherical bevel (`thickness: 28`, `n: 1.22`) with
  /// `rimLight: 0, rimShade: 0, ambientRim: 0, chromaticAberration: 0` so Pass 2 never expands
  /// beyond Pass 1a's blur clip — completely eliminating the double-border / ghosted outer rim!
  static LiquidGlassSettings sheetSettings(GrassBagTokens t, GrassBagGlassTier tier) {
    final base = surfaceSettings(t, tier, elevated: true);
    if (tier == GrassBagGlassTier.solid) {
      return base;
    }
    if (tier != GrassBagGlassTier.liquid || kIsWeb) {
      return base.copyWith(
        glassColor: t.isDark
            ? Colors.white.withValues(alpha: 0.16)
            : Colors.white.withValues(alpha: 0.66),
        blur: kIsWeb ? 9.0 : 8.0,
        saturation: 1.0,
        rimLight: 0.0,
        rimShade: 0.0,
        ambientRim: 0.0,
        chromaticAberration: 0.0,
        bodyShade: t.isDark ? 0.34 : 0.0,
      );
    }
    return base.copyWith(
      glassColor: t.isDark
          ? Colors.white.withValues(alpha: 0.14)
          : Colors.white.withValues(alpha: 0.56),
      blur: 7.5,
      frost: 0.0,
      frostOpacity: 0.0,
      thickness: 28.0,
      refractiveIndex: 1.22,
      lensModel: GlassLensModel.spherical,
      chromaticAberration: 0.0,
      saturation: t.isDark ? 1.44 : 1.58,
      bodyShade: t.isDark ? 0.34 : 0.0,
      whitenStrength: t.isDark ? 0.0 : 0.22,
      whitenGated: true,
      lightAngle: 0.75 * math.pi,
      lightIntensity: t.isDark ? 0.82 : 0.56,
      ambientStrength: t.isDark ? 0.14 : 0.09,
      ambientRim: 0.0,
      fresnelStrength: t.isDark ? 1.05 : 0.72,
      edgeAbsorption: 0.04,
      rimLight: 0.0,
      rimShade: 0.0,
      specularSharpness: GlassSpecularSharpness.medium,
      shadow: t.isDark
          ? const []
          : const [
              BoxShadow(
                color: Color(0x16000000),
                blurRadius: 16,
                offset: Offset(0, 6),
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

    return GlassThemeData(
      style: GlassStyle.ios27,
      light: GlassThemeVariant.ios27Light.copyWith(
        settings: GlassThemeSettings.ios27Light.copyWith(
          glassColor: Colors.white.withValues(alpha: isFrosted ? 0.40 : 0.24),
          blur: isFrosted ? (kIsWeb ? 8.0 : 6.5) : 4.0,
          frost: 0.0,
          frostOpacity: 0.0,
          thickness: isFrosted ? 0.5 : 24.0,
          refractiveIndex: isFrosted ? 1.01 : 1.24,
          lensModel: GlassLensModel.spherical,
          chromaticAberration: 0.0,
          saturation: isFrosted ? 1.0 : 1.65,
          lightAngle: 0.75 * math.pi,
          lightIntensity: isFrosted ? 0.56 : 0.60,
          ambientStrength: isFrosted ? 0.10 : 0.09,
          fresnelStrength: isFrosted ? 0.64 : 0.78,
          edgeAbsorption: isFrosted ? 0.03 : 0.04,
          rimShade: 0.0,
          rimLight: 0.0,
          bodyShade: 0.0,
          specularSharpness: GlassSpecularSharpness.medium,
        ),
        glowColors: GlassGlowColors(
          primary: lightTokens.primaryHi.withValues(alpha: 0.28),
          secondary: lightTokens.dusk.withValues(alpha: 0.22),
          success: lightTokens.ok.withValues(alpha: 0.24),
          warning: lightTokens.warn.withValues(alpha: 0.26),
          danger: lightTokens.err.withValues(alpha: 0.26),
          info: lightTokens.primary.withValues(alpha: 0.24),
          pressLight: Colors.white,
          glowBlurRadius: 8.0,
        ),
      ),
      dark: GlassThemeVariant.ios27Dark.copyWith(
        settings: GlassThemeSettings.ios27Dark.copyWith(
          glassColor: Colors.white.withValues(alpha: isFrosted ? 0.11 : 0.10),
          blur: isFrosted ? (kIsWeb ? 8.0 : 6.5) : 4.0,
          frost: 0.0,
          frostOpacity: 0.0,
          thickness: isFrosted ? 0.5 : 24.0,
          refractiveIndex: isFrosted ? 1.01 : 1.26,
          lensModel: GlassLensModel.spherical,
          chromaticAberration: 0.0,
          saturation: isFrosted ? 1.0 : 1.48,
          lightAngle: 0.75 * math.pi,
          lightIntensity: isFrosted ? 0.68 : 0.88,
          ambientStrength: isFrosted ? 0.14 : 0.14,
          fresnelStrength: isFrosted ? 0.72 : 1.15,
          edgeAbsorption: isFrosted ? 0.04 : 0.06,
          rimShade: 0.0,
          rimLight: 0.0,
          bodyShade: isFrosted ? 0.14 : 0.10,
          specularSharpness: GlassSpecularSharpness.medium,
        ),
        glowColors: GlassGlowColors(
          primary: darkTokens.primary.withValues(alpha: 0.34),
          secondary: darkTokens.dusk.withValues(alpha: 0.26),
          success: darkTokens.ok.withValues(alpha: 0.28),
          warning: darkTokens.warn.withValues(alpha: 0.28),
          danger: darkTokens.err.withValues(alpha: 0.28),
          info: darkTokens.primaryHi.withValues(alpha: 0.28),
          pressLight: Colors.white,
          glowBlurRadius: 10.0,
        ),
      ),
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
/// that batches sibling floating pills in a navigation bar or diorama into ONE single SDF
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
    if (tier == GrassBagGlassTier.solid || platformViewBackdrop) {
      return child;
    }
    final t = GrassBagTokens.of(context);
    return AdaptiveLiquidGlassLayer(
      settings: GrassBagGlassConfig.surfaceSettings(t, tier),
      quality: GrassBagGlassConfig.chromeQualityFor(tier),
      blendAmount: 0.0,
      clipExpansion: const EdgeInsets.all(4),
      child: child,
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
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final AlignmentGeometry? alignment;
  final Color? tintColor;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    if (tier == GrassBagGlassTier.solid) {
      return Container(
        width: width,
        height: height,
        padding: padding,
        alignment: alignment,
        decoration: BoxDecoration(
          color: t.cardSolid,
          shape: isOval ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: isOval ? null : BorderRadius.circular(borderRadius),
          border: Border.all(color: t.sepStrong, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: t.isDark ? 0.28 : 0.08),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: child,
      );
    }

    final baseSettings = useSheetSettings
        ? GrassBagGlassConfig.sheetSettings(t, tier)
        : GrassBagGlassConfig.surfaceSettings(t, tier, elevated: elevated);
    final resolvedSettings =
        tintColor != null ? baseSettings.copyWith(glassColor: tintColor) : baseSettings;

    return GlassContainer(
      useOwnLayer: useOwnLayer,
      quality: useCardQuality
          ? GrassBagGlassConfig.cardQualityFor(tier)
          : GrassBagGlassConfig.chromeQualityFor(tier),
      width: width,
      height: height,
      padding: padding,
      alignment: alignment,
      clipBehavior: clipBehavior,
      shape: isOval
          ? const LiquidOval()
          : LiquidRoundedSuperellipse(borderRadius: borderRadius),
      settings: useOwnLayer ? resolvedSettings : null,
      child: child,
    );
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
    final isSolid = tier == GrassBagGlassTier.solid;
    final effectiveOwnLayer = useOwnLayer || platformViewBackdrop || tintColor != null;
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
        quality: isSolid ? null : GrassBagGlassConfig.chromeQualityFor(tier),
        surfaceStyle: isSolid ? GlassSurfaceStyle.solid : GlassSurfaceStyle.glass,
        color: isSolid ? t.cardSolid : null,
        tintColor: tintColor,
        platformViewBackdrop: platformViewBackdrop,
        settings: isSolid || !effectiveOwnLayer
            ? null
            : GrassBagGlassConfig.surfaceSettings(t, tier),
        interactionScale: 1.07,
        stretch: effectiveOwnLayer ? 0.35 : 0.16,
        anchorStretch: true,
        glowColor: (tintColor ?? t.primaryHi).withValues(alpha: t.isDark ? 0.32 : 0.22),
        child: Icon(icon, size: iconSize, color: iconColor ?? t.text),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: btn) : btn;
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
  final bool useOwnLayer;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final isSolid = tier == GrassBagGlassTier.solid;
    final effectiveOwnLayer = useOwnLayer || prominent || tintColor != null;
    return GlassButton.custom(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      height: height,
      shape: LiquidRoundedSuperellipse(borderRadius: borderRadius),
      useOwnLayer: effectiveOwnLayer,
      quality: isSolid ? null : GrassBagGlassConfig.chromeQualityFor(tier),
      surfaceStyle: isSolid ? GlassSurfaceStyle.solid : GlassSurfaceStyle.glass,
      style: prominent ? GlassButtonStyle.prominent : GlassButtonStyle.filled,
      color: isSolid ? (prominent ? t.primary : t.cardSolid) : null,
      tintColor: tintColor,
      settings: isSolid || prominent || !effectiveOwnLayer
          ? null
          : GrassBagGlassConfig.surfaceSettings(t, tier),
      interactionScale: 1.04,
      stretch: effectiveOwnLayer ? 0.28 : 0.14,
      anchorStretch: true,
      glowColor: (tintColor ?? t.primaryHi).withValues(alpha: t.isDark ? 0.30 : 0.22),
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }
}

/// Native iOS 26 [GlassSearchBar] styled cleanly for GrassBag Settings & Lists.
class GrassBagGlassSearchBar extends StatelessWidget {
  const GrassBagGlassSearchBar({
    super.key,
    this.controller,
    this.placeholder = '搜索',
    this.onChanged,
    required this.tier,
    this.insideGlass = false,
  });

  final TextEditingController? controller;
  final String placeholder;
  final ValueChanged<String>? onChanged;
  final GrassBagGlassTier tier;
  final bool insideGlass;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final useSolid = insideGlass || tier == GrassBagGlassTier.solid;
    return GlassSearchBar(
      controller: controller,
      placeholder: placeholder,
      onChanged: onChanged,
      height: 40,
      useOwnLayer: !useSolid,
      surfaceStyle: useSolid ? GlassSurfaceStyle.solid : GlassSurfaceStyle.glass,
      color: useSolid ? t.fill1 : null,
      quality: useSolid ? null : GrassBagGlassConfig.cardQualityFor(tier),
      settings: useSolid ? null : GrassBagGlassConfig.surfaceSettings(t, tier),
      searchIconColor: t.text3,
      clearIconColor: t.text3,
      textStyle: TextStyle(fontSize: 14, color: t.text),
      placeholderStyle: TextStyle(fontSize: 14, color: t.text3),
    );
  }
}

/// Authentic iOS 26/27 [GlassSwitch] with lazy-mounted refractive thumb lens (zero shader at rest!).
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
    return GlassSwitch(
      value: value,
      onChanged: onChanged,
      activeColor: activeColor ?? t.ok,
      inactiveColor: t.isDark ? const Color(0x3DFFFFFF) : const Color(0x453C3C43),
      width: 62,
      height: 28,
      useOwnLayer: false,
      quality: tier == GrassBagGlassTier.solid ? GlassQuality.minimal : null,
      enableHaptics: true,
    );
  }
}

/// Authentic iOS 26/27 [GlassSegmentedControl] configured per `SKILL.md` Rule 2:
/// - `useOwnLayer: false` & `quality: null` so the library's native `ios27Indicator`
///   clear refractive jelly lens glides naturally without clipping or fighting an opaque fill!
/// - Always wrapped in vertical breathing room so the jelly-bloom overshoot is never clipped.
class GrassBagSegmentedControl extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: GlassSegmentedControl(
        segments: [for (final label in labels) GlassSegment(label: label)],
        selectedIndex: selectedIndex.clamp(0, labels.length - 1),
        onSegmentSelected: (i) {
          if (i == selectedIndex) return;
          HapticFeedback.selectionClick();
          onSelected(i);
        },
        height: height,
        borderRadius: GlassDefaults.capsuleRadius,
        useOwnLayer: false,
        quality: tier == GrassBagGlassTier.solid ? GlassQuality.minimal : null,
        backgroundColor: t.isDark
            ? const Color(0x3D787880)
            : const Color(0x21767680),
        indicatorColor: t.isDark
            ? const Color(0x2EFFFFFF)
            : const Color(0xEEFFFFFF),
        selectedTextStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: t.isDark ? Colors.white : t.text,
        ),
        unselectedTextStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: t.text2,
        ),
        glowColor: t.primaryHi.withValues(alpha: 0.22),
      ),
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

    final borderCol = t.isDark
        ? Colors.white.withValues(alpha: 0.13)
        : Colors.white.withValues(alpha: 0.94);
    final superellipse = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(24),
      side: BorderSide(color: borderCol, width: 0.75),
    );
    final innerColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
    final platter = DecoratedBox(
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: t.isDark
              ? [
                  Color.lerp(t.cardSolid, Colors.white, 0.05)!.withValues(alpha: 0.72),
                  t.cardSolid.withValues(alpha: 0.64),
                ]
              : [
                  Colors.white.withValues(alpha: 0.82),
                  Colors.white.withValues(alpha: 0.72),
                ],
        ),
        shape: superellipse,
        shadows: [
          BoxShadow(
            color: t.isDark
                ? Colors.black.withValues(alpha: 0.24)
                : Colors.black.withValues(alpha: 0.055),
            blurRadius: 18,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: clipBehavior == Clip.none
          ? innerColumn
          : ClipRSuperellipse(
              borderRadius: BorderRadius.circular(24),
              child: innerColumn,
            ),
    );

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 10, bottom: 7),
            child: Text(
              header!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.1,
                color: t.text3,
              ),
            ),
          ),
        platter,
        if (footer != null)
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 10, top: 7),
            child: Text(
              footer!,
              style: TextStyle(fontSize: 11.5, height: 1.4, color: t.text3),
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
    this.contentPadding = const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
  });

  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;
  final bool selected;
  final EdgeInsetsGeometry contentPadding;

  @override
  State<GrassBagListTile> createState() => _GrassBagListTileState();
}

class _GrassBagListTileState extends State<GrassBagListTile> {
  bool _pressed = false;
  Timer? _pressDelayTimer;

  void _setPressed(bool v) {
    _pressDelayTimer?.cancel();
    _pressDelayTimer = null;
    if (_pressed != v && mounted) setState(() => _pressed = v);
  }

  void _handleTapDown() {
    _pressDelayTimer?.cancel();
    if (Scrollable.maybeOf(context) != null) {
      _pressDelayTimer = Timer(const Duration(milliseconds: 45), () {
        if (mounted && !_pressed) setState(() => _pressed = true);
      });
    } else {
      _setPressed(true);
    }
  }

  @override
  void dispose() {
    _pressDelayTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final resolvedTrailing = widget.trailing ??
        (widget.showChevron
            ? Icon(
                CupertinoIcons.chevron_right,
                size: 13.5,
                color: t.text3.withValues(alpha: 0.75),
              )
            : null);

    final bgColor = widget.selected
        ? t.primary.withValues(alpha: t.isDark ? 0.20 : 0.11)
        : (_pressed
            ? (t.isDark ? Colors.white.withValues(alpha: 0.075) : t.fill1)
            : Colors.transparent);

    // Keep margin (6, 3) and 0.7px border footprint CONSTANT across selected/unselected
    // states so toggling selection NEVER shifts vertical height (+1.4px) or text X (+3.4px).
    final basePad = widget.contentPadding.resolve(Directionality.of(context));
    final innerPad = EdgeInsets.fromLTRB(
      math.max(0.0, basePad.left - 6.7),
      math.max(0.0, basePad.top - 3.7),
      math.max(0.0, basePad.right - 6.7),
      math.max(0.0, basePad.bottom - 3.7),
    );

    final rowContent = Container(
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      padding: innerPad,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: widget.selected
              ? t.primary.withValues(alpha: t.isDark ? 0.34 : 0.22)
              : Colors.transparent,
          width: 0.7,
        ),
      ),
      child: Row(
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
      ),
    );

    if (widget.onTap == null) return rowContent;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _handleTapDown(),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap!();
      },
      child: rowContent,
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
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final bool haptic;
  final bool enablePointerGlow;
  final bool enabled;

  @override
  State<GrassBagSpringTap> createState() => _GrassBagSpringTapState();
}

class _SpringTickProxy extends ChangeNotifier {
  void notify() => notifyListeners();
}

class _GrassBagSpringTapState extends State<GrassBagSpringTap>
    with TickerProviderStateMixin {
  final _SpringTickProxy _tickProxy = _SpringTickProxy();
  SingleSpringController? _pressSpring;
  SingleSpringController? _dragXSpring;
  SingleSpringController? _dragYSpring;
  Timer? _scrollDeferTimer;
  Offset _startPos = Offset.zero;
  Offset _pointerPos = Offset.zero;
  bool _tracking = false;
  bool _engaged = false;
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
  void dispose() {
    _scrollDeferTimer?.cancel();
    _pressSpring?.removeListener(_tickProxy.notify);
    _dragXSpring?.removeListener(_tickProxy.notify);
    _dragYSpring?.removeListener(_tickProxy.notify);
    _pressSpring?.dispose();
    _dragXSpring?.dispose();
    _dragYSpring?.dispose();
    _tickProxy.dispose();
    super.dispose();
  }

  static double _tanh(double x) {
    final e2x = math.exp(2.0 * x.clamp(-6.0, 6.0));
    return (e2x - 1.0) / (e2x + 1.0);
  }

  void _engagePress() {
    if (!_tracking || _engaged || !mounted) return;
    _engaged = true;
    _ensurePressSpring();
    _pressSpring!.spring = GlassSpring.smooth(duration: const Duration(milliseconds: 95));
    _pressSpring!.animateTo(1.0);
  }

  void _release() {
    _scrollDeferTimer?.cancel();
    _scrollDeferTimer = null;
    if (!_tracking) return;
    _tracking = false;
    final wasEngaged = _engaged;
    _engaged = false;
    if (!wasEngaged) return;
    final press = _pressSpring;
    if (press == null) return;
    press.spring = GlassSpring.interactive(
      duration: const Duration(milliseconds: 240),
      extraBounce: 0.08,
    );
    press.animateTo(0.0);
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
                    center: _pointerPos,
                    progress: p.clamp(0.0, 1.0),
                  )
                : null,
            child: child!,
          ),
        );
      },
    );

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: widget.enabled
          ? (e) {
              _scrollDeferTimer?.cancel();
              _tracking = true;
              _engaged = false;
              _startPos = e.localPosition;
              _pointerPos = e.localPosition;
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
              if (!_tracking) return;
              final delta = e.localPosition - _startPos;
              final slop = _inScrollable ? 10.0 : 22.0;
              if (delta.distance > slop) {
                _release();
                return;
              }
              _pointerPos = e.localPosition;
              // Magnetic finger-follow only on floating chrome outside scrollables
              if (_engaged && !_inScrollable) {
                _ensureDragSprings();
                const maxPull = 3.5;
                _dragXSpring!.setValue(maxPull * _tanh(delta.dx * 0.08));
                _dragYSpring!.setValue(maxPull * _tanh(delta.dy * 0.08));
              }
            }
          : null,
      onPointerUp: widget.enabled ? (_) => _release() : null,
      onPointerCancel: widget.enabled ? (_) => _release() : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: (!widget.enabled || widget.onLongPress == null)
            ? null
            : () {
                _release();
                HapticFeedback.mediumImpact();
                widget.onLongPress!();
              },
        onTap: widget.enabled
            ? () {
                if (widget.haptic) HapticFeedback.selectionClick();
                widget.onTap();
              }
            : null,
        child: inner,
      ),
    );
  }
}

class _KyantPointerGlowPainter extends CustomPainter {
  const _KyantPointerGlowPainter({
    required this.center,
    required this.progress,
  });

  final Offset center;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = math.max(size.shortestSide * 1.15, 36.0);
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(math.min(size.shortestSide * 0.5, 24.0))),
    );
    final paint = Paint()
      ..blendMode = BlendMode.plus
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: 0.13 * progress),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawRect(rect, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _KyantPointerGlowPainter old) =>
      old.progress != progress || old.center != center;
}

/// Prominent Apple iOS 26 capsule action button powered by [GlassButton.custom]
/// (replaces Material `FilledButton` across sheets, cards, banners, and settings!).
/// Automatically honours `insideGlass` (`GlassSurfaceStyle.solid` inside sheets/glass
/// containers per `SKILL.md` Rule 2; refractive prominent `GlassSurfaceStyle.glass` on canvas).
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
    this.padding = const EdgeInsets.symmetric(horizontal: 18),
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
    final baseBg = color ?? t.primary;
    final bg = active ? baseBg : baseBg.withValues(alpha: 0.45);
    final baseFg = foregroundColor ?? t.onPrimary;
    final fg = active ? baseFg : baseFg.withValues(alpha: 0.55);
    final useSolid = insideGlass || tier == GrassBagGlassTier.solid;

    final labelRow = Padding(
      padding: padding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.15,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );

    if (useSolid) {
      return GrassBagSpringTap(
        enabled: active,
        pressedScale: 0.965,
        haptic: true,
        onTap: () {
          if (!active) return;
          HapticFeedback.lightImpact();
          onTap!();
        },
        child: Container(
          height: height,
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            color: bg,
            shape: const RoundedSuperellipseBorder(
              borderRadius: BorderRadius.all(Radius.circular(999)),
            ),
          ),
          child: labelRow,
        ),
      );
    }

    return GlassButton.custom(
      onTap: () {
        if (!active) return;
        HapticFeedback.lightImpact();
        onTap!();
      },
      enabled: active,
      height: height,
      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
      useOwnLayer: true,
      quality: GrassBagGlassConfig.chromeQualityFor(tier),
      surfaceStyle: GlassSurfaceStyle.glass,
      style: GlassButtonStyle.prominent,
      tintColor: bg,
      interactionScale: 1.03,
      stretch: 0.24,
      anchorStretch: true,
      glowColor: bg.withValues(alpha: 0.34),
      glowRadius: 1.3,
      child: labelRow,
    );
  }
}

/// Secondary Apple iOS 26 capsule button powered by [GlassButton.custom]
/// (replaces Material `TextButton` across sheets, approval cards, and settings!).
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
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
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
    final useSolid = insideGlass || tier == GrassBagGlassTier.solid;
    final baseFg = destructive
        ? t.err
        : (accentForeground ? t.primary : t.text);
    final fg = active ? baseFg : baseFg.withValues(alpha: 0.45);
    final solidBg = destructive
        ? t.errSoft
        : (active ? t.fill2 : t.fill1);

    final labelRow = Padding(
      padding: padding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.15,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );

    if (useSolid) {
      return GrassBagSpringTap(
        enabled: active,
        pressedScale: 0.965,
        haptic: true,
        onTap: () {
          if (!active) return;
          HapticFeedback.selectionClick();
          onTap?.call();
        },
        child: Container(
          height: height,
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            color: solidBg,
            shape: RoundedSuperellipseBorder(
              borderRadius: const BorderRadius.all(Radius.circular(999)),
              side: BorderSide(
                color: destructive
                    ? t.err.withValues(alpha: 0.22)
                    : t.sep,
                width: 0.6,
              ),
            ),
          ),
          child: labelRow,
        ),
      );
    }

    return GlassButton.custom(
      onTap: () {
        if (!active) return;
        HapticFeedback.selectionClick();
        onTap?.call();
      },
      enabled: active,
      height: height,
      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
      useOwnLayer: true,
      quality: GrassBagGlassConfig.chromeQualityFor(tier),
      surfaceStyle: GlassSurfaceStyle.glass,
      style: GlassButtonStyle.filled,
      settings: GrassBagGlassConfig.surfaceSettings(t, tier),
      interactionScale: 1.03,
      stretch: 0.24,
      anchorStretch: true,
      glowColor: (destructive ? t.err : t.primaryHi).withValues(alpha: 0.24),
      glowRadius: 1.2,
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
  });

  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final radius = size * 0.30;
    final topCol = filled
        ? Color.lerp(color, Colors.white, 0.16)!
        : color.withValues(alpha: t.isDark ? 0.25 : 0.17);
    final botCol = filled
        ? color
        : color.withValues(alpha: t.isDark ? 0.11 : 0.08);

    final fgColor = filled
        ? (color.computeLuminance() > 0.48 ? const Color(0xFF0F1C26) : Colors.white)
        : color;

    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [topCol, botCol],
        ),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(
            color: filled
                ? Colors.white.withValues(alpha: 0.22)
                : color.withValues(alpha: t.isDark ? 0.30 : 0.18),
            width: 0.65,
          ),
        ),
      ),
      child: Icon(
        icon,
        size: iconSize,
        color: fgColor,
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
    final topPad = MediaQuery.viewPaddingOf(context).top;
    final hasWideTrailing = wideTrailing ?? (trailing is Row);
    final titleSideInset = hasWideTrailing ? 104.0 : 56.0;
    final titleContent = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: subtitle != null && subtitle!.isNotEmpty ? 13.5 : 15,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: t.text,
          ),
        ),
        if (subtitle != null && subtitle!.isNotEmpty)
          Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10.5, color: t.text3),
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
          child: Stack(
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
                padding: EdgeInsets.symmetric(horizontal: titleSideInset),
                child: glassTitlePill && !platformViewBackdrop
                    ? GrassBagGlass(
                        tier: tier,
                        borderRadius: 999,
                        height: 44,
                        useOwnLayer: false,
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
          ),
        ),
      ),
    );

    if (platformViewBackdrop || !floating) return headerRow;

    // Crisp status-bar-only cap (`topPad + 14dp`):
    // 100% solid `t.bgTop` across the OS status bar (0% text ghosting under clock/battery!),
    // then feathers cleanly to 0% right at the top edge of the floating Liquid Glass pills
    // (`topPad + 12..56`) so scrolled cards pass at full vibrant contrast underneath for true refraction!
    if (topPad <= 4.0) return headerRow;
    final capH = topPad + 14.0;
    final solidStop = ((topPad - 2.0) / capH).clamp(0.45, 0.85);
    final midStop = ((topPad + 5.0) / capH).clamp(solidStop + 0.05, 0.94);
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: capH,
          child: IgnorePointer(
            child: DecoratedBox(
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
            ),
          ),
        ),
        headerRow,
      ],
    );
  }
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
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double borderRadius;
  final Color? color;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(borderRadius),
      side: BorderSide(
        color: t.isDark
            ? Colors.white.withValues(alpha: 0.13)
            : Colors.white.withValues(alpha: 0.94),
        width: 0.75,
      ),
    );
    return Container(
      padding: padding,
      decoration: ShapeDecoration(
        color: color,
        gradient: color == null
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: t.isDark
                    ? [
                        Color.lerp(t.cardSolid, Colors.white, 0.05)!.withValues(alpha: 0.72),
                        t.cardSolid.withValues(alpha: 0.64),
                      ]
                    : [
                        Colors.white.withValues(alpha: 0.82),
                        Colors.white.withValues(alpha: 0.72),
                      ],
              )
            : null,
        shape: shape,
        shadows: elevated
            ? [
                BoxShadow(
                  color: t.isDark
                      ? Colors.black.withValues(alpha: 0.22)
                      : Colors.black.withValues(alpha: 0.05),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}

/// Concentric `18pt` continuous superellipse grouped section specifically designed for
/// inside floating `showGrassBagSheet` modals (translucent surface, auto-indented dividers,
/// ZERO drop shadow so sheets never stack muddy double-elevation!).
class GrassBagSheetSection extends StatelessWidget {
  const GrassBagSheetSection({
    super.key,
    required this.children,
    this.header,
    this.footer,
    this.dividerIndent,
    this.borderRadius = 18,
    this.padding,
    this.clipBehavior = Clip.none,
  });

  final List<Widget> children;
  final String? header;
  final String? footer;
  final double? dividerIndent;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
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
      padding: padding ?? EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );

    final surface = DecoratedBox(
      decoration: ShapeDecoration(
        color: t.isDark
            ? Colors.white.withValues(alpha: 0.055)
            : Colors.white.withValues(alpha: 0.72),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(borderRadius),
          side: BorderSide(color: t.sep, width: 0.65),
        ),
      ),
      child: clipBehavior == Clip.none
          ? content
          : ClipRSuperellipse(
              borderRadius: BorderRadius.circular(borderRadius),
              clipBehavior: clipBehavior,
              child: content,
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
    final fillColor = widget.insideGlass
        ? (t.isDark
            ? Colors.white.withValues(alpha: _focused ? 0.10 : 0.065)
            : (_focused ? Colors.white.withValues(alpha: 0.94) : t.fill1))
        : (t.isDark ? t.cardSolid : Colors.white.withValues(alpha: 0.90));
    final borderColor = widget.hasError
        ? t.err
        : (_focused ? t.primary.withValues(alpha: 0.72) : t.sep);
    final resolvedStyle = widget.style ??
        TextStyle(
          fontSize: widget.fontSize,
          fontFamily: widget.monospace ? 'monospace' : null,
          height: widget.monospace ? 1.45 : 1.35,
          color: widget.enabled ? t.text : t.text3,
        );

    // Fill in `decoration` and stroke in `foregroundDecoration` so changing border width
    // (0.7 -> 1.2) on focus/blur/error produces ZERO ShapeDecoration.padding layout shift!
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      decoration: ShapeDecoration(
        color: fillColor,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
      ),
      foregroundDecoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          side: BorderSide(
            color: borderColor,
            width: _focused || widget.hasError ? 1.2 : 0.7,
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

  @override
  void initState() {
    super.initState();
    _syncIndeterminate();
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
      )..repeat();
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

    if (widget.value == null && _indetCtrl != null) {
      return RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: ColoredBox(
              color: bgCol,
              child: LayoutBuilder(
                builder: (ctx, box) {
                  final w = box.maxWidth.isFinite ? box.maxWidth : 200.0;
                  final barW = (w * 0.34).clamp(40.0, 140.0);
                  final capsule = SizedBox(
                    width: barW,
                    height: widget.height,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            fillCol.withValues(alpha: 0.25),
                            fillCol,
                            fillCol.withValues(alpha: 0.25),
                          ],
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
          ),
        ),
      );
    }

    final clamped = (widget.value ?? 0.0).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: widget.height,
        width: double.infinity,
        color: bgCol,
        alignment: Alignment.centerLeft,
        child: AnimatedFractionallySizedBox(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          widthFactor: clamped,
          heightFactor: 1.0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [fillCol, Color.lerp(fillCol, Colors.white, 0.16)!],
              ),
              borderRadius: BorderRadius.circular(999),
            ),
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
    final (accent, bg, defaultIcon) = switch (tone) {
      GrassBagBannerTone.ok => (t.ok, t.okSoft, CupertinoIcons.checkmark_circle_fill),
      GrassBagBannerTone.warn => (t.warn, t.warnSoft, CupertinoIcons.exclamationmark_circle_fill),
      GrassBagBannerTone.error => (t.err, t.errSoft, CupertinoIcons.exclamationmark_triangle_fill),
      GrassBagBannerTone.info => (t.primary, t.primarySoft, CupertinoIcons.info_circle_fill),
    };

    return Container(
      padding: padding,
      decoration: ShapeDecoration(
        color: bg,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(borderRadius),
          side: BorderSide(
            color: accent.withValues(alpha: t.isDark ? 0.36 : 0.24),
            width: 0.75,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment:
                (title != null && title!.isNotEmpty) ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              Padding(
                padding: EdgeInsets.only(top: (title != null && title!.isNotEmpty) ? 1.5 : 0),
                child: Icon(icon ?? defaultIcon, size: 16, color: accent),
              ),
              const SizedBox(width: 9),
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
                          color: accent,
                        ),
                      ),
                    if (message.isNotEmpty) ...[
                      if (title != null && title!.isNotEmpty) const SizedBox(height: 3),
                      Text(
                        message,
                        style: TextStyle(
                          fontSize: 12.2,
                          height: 1.42,
                          color: (title != null && title!.isNotEmpty) ? t.text2 : accent,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
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
    final fg = selected ? t.onPrimary : t.text2;
    return GrassBagSpringTap(
      onTap: onTap,
      pressedScale: 0.94,
      haptic: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        padding: padding,
        decoration: BoxDecoration(
          color: selected ? t.primary : t.fill1,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? t.primary : t.sep,
            width: 0.7,
          ),
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
      ),
    );
  }
}
