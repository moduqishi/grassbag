import 'dart:async';

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
  final preloaded = results[0];
  if (preloaded is Map<String, dynamic>) {
    GrassBagController.preloadedInitialPrefs = preloaded;
    final savedDark = preloaded['isDark'] is bool ? preloaded['isDark'] as bool : false;
    final accentName = preloaded['accent']?.toString();
    final savedAccent = GrassBagAccent.values.firstWhere(
      (a) => a.name == accentName,
      orElse: () => GrassBagAccent.teal,
    );
    final resolved = GrassBagTokens.resolve(
      savedAccent,
      savedDark ? Brightness.dark : Brightness.light,
    );
    unawaited(
      GrassBagNativeBridge.instance.syncThemeMode(
        savedDark,
        accentPrimary: resolved.primary.toARGB32(),
        accentHi: resolved.primaryHi.toARGB32(),
      ),
    );
  } else {
    final resolved = GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light);
    unawaited(
      GrassBagNativeBridge.instance.syncThemeMode(
        false,
        accentPrimary: resolved.primary.toARGB32(),
        accentHi: resolved.primaryHi.toARGB32(),
      ),
    );
  }
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

    final overlayStyle = isDark
        ? SystemUiOverlayStyle.light.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
          )
        : SystemUiOverlayStyle.dark.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
          );

    return LiquidGlassWidgets.wrap(
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
          themeAnimationDuration: Duration.zero,
          builder: (context, child) => GrassBagGlobalToastHost(
            child: child ?? const SizedBox.shrink(),
          ),
          home: skipLaunchGate ? const GrassBagShell() : const GrassBagAppGate(),
        ),
      ),
    );
  }
}
