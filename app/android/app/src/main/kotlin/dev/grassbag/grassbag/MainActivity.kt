package dev.grassbag.grassbag

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.os.SystemClock
import android.view.ViewTreeObserver
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var bridgePlugin: GrassBagBridgePlugin? = null
    private var preDrawListener: ViewTreeObserver.OnPreDrawListener? = null
    @Volatile
    private var flutterUiReady = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Eagerly pre-warm Keystore, RuntimeController & local Ubuntu/DSH engine OFF the UI thread
        // before Flutter initializes its engine & first frame (zero main-thread jank!).
        RuntimeController.prewarmInBackground(applicationContext)
        super.onCreate(savedInstanceState)

        WindowCompat.setDecorFitsSystemWindows(window, false)
        applySavedLaunchSurfaceTheme()

        // Hold initial window draw briefly until Flutter's Frame 0 is rendered (max 900ms cap)
        // so there is ZERO white/black SurfaceView hole-punch flash between OS splash and Flutter!
        val holdDeadlineMs = SystemClock.elapsedRealtime() + 900L
        val contentView = window.decorView
        val listener = object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                if (flutterUiReady || SystemClock.elapsedRealtime() >= holdDeadlineMs) {
                    if (contentView.viewTreeObserver.isAlive) {
                        contentView.viewTreeObserver.removeOnPreDrawListener(this)
                    }
                    preDrawListener = null
                    return true
                }
                return false
            }
        }
        preDrawListener = listener
        contentView.viewTreeObserver.addOnPreDrawListener(listener)
    }

    private fun applySavedLaunchSurfaceTheme() {
        val sp = applicationContext.getSharedPreferences("gb_native_ui_v1", Context.MODE_PRIVATE)
        val systemDark = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        val isDark = if (sp.contains("isDark")) sp.getBoolean("isDark", systemDark) else systemDark
        val bgColor = if (isDark) Color.parseColor("#192130") else Color.parseColor("#EDF4FB")
        window.setBackgroundDrawable(ColorDrawable(bgColor))
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.isAppearanceLightStatusBars = !isDark
        controller.isAppearanceLightNavigationBars = !isDark
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        flutterUiReady = true
    }

    override fun onResume() {
        super.onResume()
        isMainActivityResumed = true
        RuntimeController.ensureForegroundServiceIfRunning(applicationContext)
        bridgePlugin?.notifyForegroundResumed()
    }

    override fun onPause() {
        isMainActivityResumed = false
        super.onPause()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridgePlugin?.detach()
        bridgePlugin = GrassBagBridgePlugin(this).also { it.attach(flutterEngine) }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bridgePlugin?.detach()
        bridgePlugin = null
        super.cleanUpFlutterEngine(flutterEngine)
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
        isMainActivityResumed = false
        preDrawListener?.let { l ->
            val vto = window?.decorView?.viewTreeObserver
            if (vto != null && vto.isAlive) {
                vto.removeOnPreDrawListener(l)
            }
        }
        preDrawListener = null
        bridgePlugin?.detach()
        bridgePlugin = null
        super.onDestroy()
    }

    companion object {
        @Volatile
        var isMainActivityResumed: Boolean = false
            private set
    }
}
