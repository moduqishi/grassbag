package dev.grassbag.grassbag

import android.content.Intent
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var bridgePlugin: GrassBagBridgePlugin? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Eagerly pre-warm Keystore, RuntimeController & local Ubuntu/DSH engine OFF the UI thread
        // before Flutter initializes its engine & first frame (zero main-thread jank!).
        RuntimeController.prewarmInBackground(applicationContext)
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }

    override fun onResume() {
        super.onResume()
        // If the engine booted while backgrounded (Android 12+ skipped startForegroundService),
        // re-arm the foreground keepalive service cleanly once the user returns to foreground.
        RuntimeController.ensureForegroundServiceIfRunning(applicationContext)
        bridgePlugin?.notifyForegroundResumed()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridgePlugin = GrassBagBridgePlugin(this).also { it.attach(flutterEngine) }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (bridgePlugin?.handleActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (bridgePlugin?.handleRequestPermissionsResult(requestCode, permissions, grantResults) == true) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        bridgePlugin?.detach()
        bridgePlugin = null
        super.onDestroy()
    }
}
