import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'data/grassbag_storage.dart';
import 'state/app_state.dart';
import 'theme/grassbag_glass.dart';
import 'theme/grassbag_theme.dart';
import 'ui/common/grassbag_sheets.dart';
import 'ui/onboarding/launch_splash_overlay.dart';
import 'ui/shell/grassbag_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Preload persisted theme/accent/glass preferences synchronously before Frame 0
  // so dark mode & accent render immediately without a cold-start color-lerp flash.
  final results = await Future.wait<Object?>([
    GrassBagStorage.instance.loadPrefs(),
    LiquidGlassWidgets.initialize(
      warmUpMode: GlassWarmUpMode.auto,
      enablePerformanceMonitor: false,
    ),
  ]);
  final preloaded = results.first;
  if (preloaded is Map<String, dynamic>) {
    GrassBagController.preloadedInitialPrefs = preloaded;
  }

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
