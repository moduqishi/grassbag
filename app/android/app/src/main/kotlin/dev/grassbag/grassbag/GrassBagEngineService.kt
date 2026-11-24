package dev.grassbag.grassbag

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class GrassBagEngineService : Service() {
    private var lock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        registerChannels(this)
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        lock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "grassbag:keepalive").apply {
            setReferenceCounted(false)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Do not show a stale "running" notification after OS process restart with a dead engine.
        if (intent == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }

        val action = intent.action
        val heading = intent.getStringExtra(KEY_HEADING) ?: "GrassBag 本机服务运行中"
        val detail = intent.getStringExtra(KEY_DETAIL) ?: "后台会话与终端保活中"
        val holdWakeLockMs = intent.getLongExtra(KEY_WAKELOCK_MS, 0L)

        val openApp = PendingIntent.getActivity(
            this,
            10,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val banner = NotificationCompat.Builder(this, ENGINE_CH)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(heading)
            .setContentText(detail)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openApp)
            .build()

        // Always fulfill startForeground contract BEFORE handling ACTION_STOP so Android 10-16 never
        // throws ForegroundServiceDidNotStartInTimeException when stop() races with startOrUpdate()!
        val started = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(FG_NOTIF_ID, banner, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(FG_NOTIF_ID, banner)
            }
            true
        }.getOrDefault(false)

        if (!started || action == ACTION_STOP) {
            runCatching { if (lock?.isHeld == true) lock?.release() }
            if (started) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
                } else {
                    @Suppress("DEPRECATION")
                    runCatching { stopForeground(true) }
                }
            }
            startRequested.set(false)
            serviceActive.set(false)
            stopSelf(startId)
            return START_NOT_STICKY
        }

        serviceActive.set(true)
        startRequested.set(true)
        // Acquire bounded WakeLock only when requested; never clobber an active long-running work WakeLock on status updates.
        val nowMs = System.currentTimeMillis()
        if (holdWakeLockMs > 0L) {
            val clamped = holdWakeLockMs.coerceIn(60_000L, 15 * 60 * 1000L)
            wakeLockUntilMs = maxOf(wakeLockUntilMs, nowMs + clamped)
            val effectiveDuration = (wakeLockUntilMs - nowMs).coerceAtLeast(clamped)
            runCatching { lock?.acquire(effectiveDuration) }
        } else if (nowMs >= wakeLockUntilMs) {
            wakeLockUntilMs = 0L
            runCatching { if (lock?.isHeld == true) lock?.release() }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        startRequested.set(false)
        serviceActive.set(false)
        wakeLockUntilMs = 0L
        runCatching { if (lock?.isHeld == true) lock?.release() }
        lock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val TAG = "GrassBagEngineSvc"
        private const val ENGINE_CH = "grassbag_engine_channel"
        private const val ALERT_CH = "grassbag_approval_channel"
        private const val FG_NOTIF_ID = 1001
        private const val KEY_HEADING = "heading"
        private const val KEY_DETAIL = "detail"
        private const val KEY_WAKELOCK_MS = "wakelock_ms"
        private const val ACTION_STOP = "dev.grassbag.grassbag.ACTION_STOP_ENGINE_SVC"
        private val alertCounter = AtomicInteger(3000)
        private val serviceActive = AtomicBoolean(false)
        private val startRequested = AtomicBoolean(false)
        @Volatile
        private var wakeLockUntilMs: Long = 0L

        fun isServiceActive(): Boolean = serviceActive.get()

        private fun isProcessForeground(ctx: Context): Boolean {
            return runCatching {
                val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return true
                val myPid = android.os.Process.myPid()
                val proc = am.runningAppProcesses?.firstOrNull { it.pid == myPid } ?: return true
                proc.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
            }.getOrDefault(true)
        }

        fun registerChannels(ctx: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val mgr = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(ENGINE_CH) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(ENGINE_CH, "GrassBag 后台保活", NotificationManager.IMPORTANCE_LOW)
                )
            }
            if (mgr.getNotificationChannel(ALERT_CH) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(ALERT_CH, "审批与任务完成提醒", NotificationManager.IMPORTANCE_HIGH)
                )
            }
        }

        fun startOrUpdate(ctx: Context, heading: String, detail: String, wakeLockMs: Long = 0L) {
            registerChannels(ctx)
            // On Android 12+, calling startForegroundService() while backgrounded throws ForegroundServiceStartNotAllowedException.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !serviceActive.get() && !isProcessForeground(ctx)) {
                Log.i(TAG, "Skipping startForegroundService while app is backgrounded")
                return
            }
            val svcIntent = Intent(ctx, GrassBagEngineService::class.java).apply {
                putExtra(KEY_HEADING, heading)
                putExtra(KEY_DETAIL, detail)
                putExtra(KEY_WAKELOCK_MS, wakeLockMs)
            }
            startRequested.set(true)
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(svcIntent)
                } else {
                    ctx.startService(svcIntent)
                }
            }.onFailure { err ->
                if (!serviceActive.get()) {
                    startRequested.set(false)
                }
                Log.w(TAG, "startOrUpdate failed: ${err.message}")
            }
        }

        fun stop(ctx: Context) {
            // Never fire a ghost startService(ACTION_STOP) when FGS was never started or requested
            // (avoids ghost notification flash & Android 8+ background IllegalStateException).
            if (!serviceActive.get() && !startRequested.get()) {
                return
            }
            startRequested.set(false)
            val stopIntent = Intent(ctx, GrassBagEngineService::class.java).apply { action = ACTION_STOP }
            runCatching { ctx.startService(stopIntent) }.onFailure {
                serviceActive.set(false)
                runCatching { ctx.stopService(Intent(ctx, GrassBagEngineService::class.java)) }
            }
        }

        fun postAlertNotification(ctx: Context, heading: String, detail: String) {
            registerChannels(ctx)
            val mgr = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val id = alertCounter.incrementAndGet()
            val openApp = PendingIntent.getActivity(
                ctx,
                id,
                Intent(ctx, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val alert = NotificationCompat.Builder(ctx, ALERT_CH)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(heading)
                .setContentText(detail)
                .setAutoCancel(true)
                .setContentIntent(openApp)
                .build()
            runCatching { mgr.notify(id, alert) }
        }
    }
}
