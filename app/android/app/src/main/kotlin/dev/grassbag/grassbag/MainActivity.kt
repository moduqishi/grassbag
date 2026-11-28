package dev.grassbag.grassbag

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.View
import android.view.ViewTreeObserver
import android.view.WindowManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.lang.ref.WeakReference

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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        applySavedLaunchSurfaceTheme()

        // Hold initial window draw briefly until Flutter's Frame 0 is rendered (max 900ms cap)
        // so there is ZERO white/black SurfaceView hole-punch flash between OS splash and Flutter!
        val holdDeadlineMs = SystemClock.elapsedRealtime() + 900L
        val contentView: View = findViewById<View>(android.R.id.content) ?: window.decorView
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
        val followSystem = sp.getBoolean("followSystemTheme", !sp.contains("isDark"))
        val savedDark = sp.getBoolean("isDark", systemDark)
        val isDark = if (followSystem) systemDark else savedDark
        val fallbackBg = if (isDark) Color.parseColor("#192130") else Color.parseColor("#EDF4FB")
        val bgColor = if (sp.contains("bgSolid") && (!followSystem || isDark == savedDark)) {
            sp.getInt("bgSolid", fallbackBg)
        } else {
            fallbackBg
        }
        window.setBackgroundDrawable(ColorDrawable(bgColor))
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.isAppearanceLightStatusBars = !isDark
        controller.isAppearanceLightNavigationBars = !isDark
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        flutterUiReady = true
        val contentView: View? = findViewById<View>(android.R.id.content) ?: window?.decorView
        preDrawListener?.let { l ->
            val vto = contentView?.viewTreeObserver
            if (vto != null && vto.isAlive) {
                vto.removeOnPreDrawListener(l)
            }
            preDrawListener = null
        }
        contentView?.postInvalidateOnAnimation()
    }

    override fun onResume() {
        super.onResume()
        resumedActivityRef = WeakReference(this)
        RuntimeController.ensureForegroundServiceIfRunning(applicationContext)
        bridgePlugin?.notifyForegroundResumed()
    }

    override fun onPause() {
        // Reinforce foreground service + CPU/Wi-Fi locks BEFORE the Activity loses foreground
        // importance so switching to other apps never freezes the DSH container or drops LLM sockets!
        RuntimeController.onActivityBackgrounded(applicationContext)
        if (resumedActivityRef.get() === this) {
            resumedActivityRef = WeakReference(null)
        }
        super.onPause()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        applySavedLaunchSurfaceTheme()
        PhoneOverlayController.getInstance(applicationContext).onConfigurationChanged()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridgePlugin?.detach()
        bridgePlugin = GrassBagBridgePlugin(this).also {
            it.attach(flutterEngine)
            it.handleNotificationIntent(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        bridgePlugin?.handleNotificationIntent(intent)
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
        if (resumedActivityRef.get() === this) {
            resumedActivityRef = WeakReference(null)
        }
        preDrawListener?.let { l ->
            val vto = (findViewById<View>(android.R.id.content) ?: window?.decorView)?.viewTreeObserver
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
        private var resumedActivityRef: WeakReference<MainActivity?> = WeakReference(null)

        val isMainActivityResumed: Boolean
            get() = resumedActivityRef.get() != null
    }
}
