package dev.grassbag.grassbag

import android.app.Application

/**
 * Custom Application entrypoint that kicks off off-main-thread local container & DSH
 * prewarming at process birth (~150-300ms ahead of MainActivity.onCreate & FlutterEngine boot).
 */
class GrassBagApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        RuntimeController.prewarmInBackground(this)
    }
}
