# Keep GrassBag Android components & Flutter native bridge classes intact under R8/ProGuard.
-keep class dev.grassbag.grassbag.GrassBagAccessibilityService { *; }
-keep class dev.grassbag.grassbag.GrassBagEngineService { *; }
-keep class dev.grassbag.grassbag.MainActivity { *; }
-keep class dev.grassbag.grassbag.GrassBagBridgePlugin { *; }
-keep class dev.grassbag.grassbag.SafetyGate { *; }
-keep class dev.grassbag.grassbag.RuntimeController { *; }
-keep class dev.grassbag.grassbag.PhoneControlDaemon { *; }
