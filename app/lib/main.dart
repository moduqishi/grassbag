import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'data/grassbag_storage.dart';
import 'services/native_bridge.dart';
import 'state/app_state.dart';
import 'theme/grassbag_glass.dart';
import 'theme/grassbag_theme.dart';
import 'ui/common/grassbag_sheets.dart';
import 'ui/onboarding/launch_splash_overlay.dart';
import 'ui/shell/grassbag_shell.dart';

SystemUiOverlayStyle _systemOverlayStyleFor(bool isDark) {
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
    statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
    systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Preload ONLY fast SharedPreferences (~2-4ms) before Frame 0 so the OS splash lifts
  // immediately onto our pure-Canvas kinetic logo with exact saved theme/onboarding polarity,
  // while GLSL shader compilation warms up off the critical Frame-0 path!
  final results = await Future.wait<Object?>([
    GrassBagStorage.instance.loadPrefs(),
    GrassBagStorage.instance.loadSavedHosts(),
  ]);
  final platformDark =
      ui.PlatformDispatcher.instance.platformBrightness == Brightness.dark;
  final preloaded = results[0];
  final bool initialDark;
  if (preloaded is Map<String, dynamic>) {
    GrassBagController.preloadedInitialPrefs = preloaded;
    final hasExplicitDark = preloaded['isDark'] is bool;
    initialDark = hasExplicitDark ? preloaded['isDark'] as bool : platformDark;
    final accentName = preloaded['accent']?.toString();
    final savedAccent = GrassBagAccent.values.firstWhere(
      (a) => a.name == accentName,
      orElse: () => GrassBagAccent.teal,
    );
    final resolved = GrassBagTokens.resolve(
      savedAccent,
      initialDark ? Brightness.dark : Brightness.light,
    );
    unawaited(
      GrassBagNativeBridge.instance.syncThemeMode(
        initialDark,
        accentPrimary: resolved.primary.toARGB32(),
        accentHi: resolved.primaryHi.toARGB32(),
        bgSolid: resolved.bgSolid.toARGB32(),
        followSystemTheme: !hasExplicitDark,
      ),
    );
  } else {
    initialDark = platformDark;
    final resolved = GrassBagTokens.resolve(
      GrassBagAccent.teal,
      initialDark ? Brightness.dark : Brightness.light,
    );
    unawaited(
      GrassBagNativeBridge.instance.syncThemeMode(
        initialDark,
        accentPrimary: resolved.primary.toARGB32(),
        accentHi: resolved.primaryHi.toARGB32(),
        bgSolid: resolved.bgSolid.toARGB32(),
        followSystemTheme: true,
      ),
    );
  }
  SystemChrome.setSystemUIOverlayStyle(_systemOverlayStyleFor(initialDark));
  final preloadedHosts = results[1];
  if (preloadedHosts is List<Map<String, dynamic>>) {
    GrassBagController.preloadedInitialHosts = preloadedHosts;
  }

  unawaited(
    LiquidGlassWidgets.initialize(
      warmUpMode: GlassWarmUpMode.auto,
      enablePerformanceMonitor: false,
    ),
  );

  runApp(
    const ProviderScope(
      child: GrassBagApp(),
    ),
  );
}

class GrassBagApp extends ConsumerWidget {
  const GrassBagApp({super.key, this.skipLaunchGate = false});

  final bool skipLaunchGate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(appProvider.select((s) => s.accent));
    final isDark = ref.watch(appProvider.select((s) => s.isDark));
    final glassTier = ref.watch(appProvider.select((s) => s.glassTier));

    final lightTokens = GrassBagTokens.resolve(accent, Brightness.light);
    final darkTokens = GrassBagTokens.resolve(accent, Brightness.dark);
    final overlayStyle = _systemOverlayStyleFor(isDark);

    return GrassBagGlassTierScope(
      tier: glassTier,
      child: LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GrassBagGlassConfig.themeDataFor(lightTokens, darkTokens, glassTier),
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: overlayStyle,
          child: MaterialApp(
            navigatorKey: grassBagNavigatorKey,
            title: 'GrassBag',
            debugShowCheckedModeBanner: false,
            theme: lightTokens.toMaterialTheme(),
            darkTheme: darkTokens.toMaterialTheme(),
            themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
            themeAnimationDuration: const Duration(milliseconds: 220),
            themeAnimationCurve: Curves.easeOutCubic,
            builder: (context, child) {
              final highContrast = MediaQuery.highContrastOf(context);
              final content = GrassBagGlobalToastHost(
                child: child ?? const SizedBox.shrink(),
              );
              if (!highContrast) return content;
              // Route OS High Contrast / Reduce Transparency cleanly to `solid`
              // BEFORE `AdaptiveGlass` runs its white-washing fallback slab on Dark mode!
              return GrassBagGlassTierScope(
                tier: GrassBagGlassTier.solid,
                child: GlassTheme(
                  data: GrassBagGlassConfig.themeDataFor(
                    lightTokens,
                    darkTokens,
                    GrassBagGlassTier.solid,
                  ),
                  child: content,
                ),
              );
            },
            home: skipLaunchGate ? const GrassBagShell() : const GrassBagAppGate(),
          ),
        ),
      ),
    );
  }
}
