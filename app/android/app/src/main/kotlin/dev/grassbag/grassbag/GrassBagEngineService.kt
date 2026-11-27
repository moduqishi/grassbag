package dev.grassbag.grassbag

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class GrassBagEngineService : Service() {
    private var lock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var lastHeading: String? = null
    private var lastDetail: String? = null
    private val wifiReleaseRunnable = Runnable {
        if (SystemClock.elapsedRealtime() >= wakeLockUntilMs && !hasNativeActiveWork()) {
            releaseLocks()
        } else if (hasNativeActiveWork()) {
            // Native DSH turns or phone control are still active: keep CPU/Wi-Fi locks renewed
            // autonomously even if the Flutter Dart isolate is throttled in background!
            renewLocksForNativeWork()
        }
    }
    private val nativeRenewRunnable = object : Runnable {
        override fun run() {
            if (!serviceActive.get()) return
            if (hasNativeActiveWork()) {
                val now = SystemClock.elapsedRealtime()
                // Guard against an orphaned counter if DSH crashed without sending turn/end:
                // renew autonomously up to 45 minutes past the latest native heartbeat.
                if (now - lastNativeWorkHeartbeatMs <= NATIVE_HEARTBEAT_MAX_STALE_MS) {
                    applyLockState(holdWakeLockMs = 10 * 60 * 1000L, holdWifiLock = true, releaseWakeLock = false)
                    mainHandler.postDelayed(this, NATIVE_RENEW_INTERVAL_MS)
                    return
                } else {
                    nativeActiveTurns.set(0)
                    nativeActiveJobs.set(0)
                }
            }
            if (SystemClock.elapsedRealtime() >= wakeLockUntilMs) {
                releaseLocks()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        activeInstance = this
        registerChannels(this)
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        lock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "grassbag:keepalive").apply {
            setReferenceCounted(false)
        }
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifi != null) {
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = runCatching {
                wifi.createWifiLock(mode, "grassbag:wifi_keepalive").apply {
                    setReferenceCounted(false)
                }
            }.getOrNull()
        }
    }

    private fun buildNotification(heading: String, detail: String): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            10,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, ENGINE_CH)
            .setSmallIcon(R.drawable.ic_stat_grassbag)
            .setContentTitle(heading)
            .setContentText(detail)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(openApp)
            .build()
    }

    private fun releaseLocks() {
        mainHandler.removeCallbacks(wifiReleaseRunnable)
        mainHandler.removeCallbacks(nativeRenewRunnable)
        wakeLockUntilMs = 0L
        runCatching { if (lock?.isHeld == true) lock?.release() }
        runCatching { if (wifiLock?.isHeld == true) wifiLock?.release() }
    }

    private fun renewLocksForNativeWork() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastNativeWorkHeartbeatMs <= NATIVE_HEARTBEAT_MAX_STALE_MS) {
            applyLockState(holdWakeLockMs = 10 * 60 * 1000L, holdWifiLock = true, releaseWakeLock = false)
            scheduleNativeRenewalIfNeeded()
        } else {
            nativeActiveTurns.set(0)
            nativeActiveJobs.set(0)
            releaseLocks()
        }
    }

    private fun scheduleNativeRenewalIfNeeded() {
        mainHandler.removeCallbacks(nativeRenewRunnable)
        if (serviceActive.get() && hasNativeActiveWork()) {
            mainHandler.postDelayed(nativeRenewRunnable, NATIVE_RENEW_INTERVAL_MS)
        }
    }

    private fun applyLockState(holdWakeLockMs: Long, holdWifiLock: Boolean, releaseWakeLock: Boolean) {
        val nowMs = SystemClock.elapsedRealtime()
        if (holdWakeLockMs > 0L) {
            val clamped = holdWakeLockMs.coerceIn(60_000L, 20 * 60 * 1000L)
            wakeLockUntilMs = maxOf(wakeLockUntilMs, nowMs + clamped)
            val effectiveDuration = (wakeLockUntilMs - nowMs).coerceAtLeast(clamped)
            runCatching { lock?.acquire(effectiveDuration) }
            if (holdWifiLock) {
                runCatching {
                    if (wifiLock?.isHeld != true) wifiLock?.acquire()
                }
            }
            if (holdWifiLock || wifiLock?.isHeld == true) {
                mainHandler.removeCallbacks(wifiReleaseRunnable)
                mainHandler.postDelayed(wifiReleaseRunnable, effectiveDuration + 1000L)
            }
            scheduleNativeRenewalIfNeeded()
        } else if (releaseWakeLock || nowMs >= wakeLockUntilMs) {
            // Never release CPU/Wi-Fi locks while DSH or SafetyGate still has active native work!
            if (hasNativeActiveWork()) {
                renewLocksForNativeWork()
            } else {
                releaseLocks()
            }
        }
    }

    internal fun updateInProcess(
        heading: String,
        detail: String,
        holdWakeLockMs: Long,
        holdWifiLock: Boolean,
        releaseWakeLock: Boolean
    ) {
        mainHandler.post {
            if (!serviceActive.get() || activeInstance !== this) return@post
            if (heading != lastHeading || detail != lastDetail) {
                lastHeading = heading
                lastDetail = detail
                val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                runCatching { mgr?.notify(FG_NOTIF_ID, buildNotification(heading, detail)) }
            }
            applyLockState(holdWakeLockMs, holdWifiLock, releaseWakeLock)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Do not show a stale "running" notification after OS process restart with a dead engine.
        if (intent == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }

        val action = intent.action
        val cmdGen = intent.getIntExtra(KEY_GEN, -1)
        val heading = intent.getStringExtra(KEY_HEADING) ?: "GrassBag 本机服务运行中"
        val detail = intent.getStringExtra(KEY_DETAIL) ?: "后台会话与终端保活中"
        val holdWakeLockMs = intent.getLongExtra(KEY_WAKELOCK_MS, 0L)
        val holdWifiLock = intent.getBooleanExtra(KEY_WIFI_LOCK, holdWakeLockMs > 0L)
        val releaseWakeLock = intent.getBooleanExtra(KEY_RELEASE_WAKELOCK, false)

        val needsForegroundCall = !serviceActive.get() ||
            (action != ACTION_STOP && (heading != lastHeading || detail != lastDetail))

        val started = if (needsForegroundCall) {
            val notifHeading = if (action == ACTION_STOP) (lastHeading ?: heading) else heading
            val notifDetail = if (action == ACTION_STOP) (lastDetail ?: detail) else detail
            val banner = buildNotification(notifHeading, notifDetail)

            // Always fulfill startForeground contract BEFORE handling ACTION_STOP when not yet active
            // so Android 10-16 never throws ForegroundServiceDidNotStartInTimeException!
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(FG_NOTIF_ID, banner, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
                } else {
                    startForeground(FG_NOTIF_ID, banner)
                }
                if (action != ACTION_STOP) {
                    lastHeading = heading
                    lastDetail = detail
                }
                true
            }.getOrDefault(false)
        } else {
            true
        }

        val shouldStop = !started ||
            (action == ACTION_STOP && (cmdGen < 0 || cmdGen >= intentGen.get())) ||
            (pendingStop.get() && (cmdGen < 0 || cmdGen <= stopGen.get()))

        if (shouldStop) {
            serviceActive.set(false)
            lastHeading = null
            lastDetail = null
            if (cmdGen < 0 || cmdGen >= intentGen.get() || stopGen.get() >= intentGen.get()) {
                startRequested.set(false)
                pendingStop.set(false)
            }
            releaseLocks()
            if (started) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
                } else {
                    @Suppress("DEPRECATION")
                    runCatching { stopForeground(true) }
                }
            }
            stopSelf(startId)
            return START_NOT_STICKY
        }

        // Ignore stale ACTION_STOP intents superseded by a newer startOrUpdate() so they never
        // overwrite the live notification banner or release an active WakeLock!
        if (action == ACTION_STOP) {
            return START_NOT_STICKY
        }

        pendingStop.set(false)
        serviceActive.set(true)
        startRequested.set(true)
        applyLockState(holdWakeLockMs, holdWifiLock, releaseWakeLock)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (activeInstance === this) {
            activeInstance = null
        }
        if (pendingStop.get() || stopGen.get() >= intentGen.get()) {
            startRequested.set(false)
            pendingStop.set(false)
        }
        serviceActive.set(false)
        lastHeading = null
        lastDetail = null
        releaseLocks()
        lock = null
        wifiLock = null
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
        private const val KEY_WIFI_LOCK = "wifi_lock"
        private const val KEY_RELEASE_WAKELOCK = "release_wakelock"
        private const val KEY_GEN = "gen"
        private const val ACTION_STOP = "dev.grassbag.grassbag.ACTION_STOP_ENGINE_SVC"
        private const val NATIVE_RENEW_INTERVAL_MS = 4 * 60 * 1000L
        private const val NATIVE_HEARTBEAT_MAX_STALE_MS = 45 * 60 * 1000L
        private val alertCounter = AtomicInteger(3000)
        private val intentGen = AtomicInteger(0)
        private val stopGen = AtomicInteger(0)
        private val serviceActive = AtomicBoolean(false)
        private val startRequested = AtomicBoolean(false)
        private val pendingStop = AtomicBoolean(false)
        private val nativeActiveTurns = AtomicInteger(0)
        private val nativeActiveJobs = AtomicInteger(0)
        private val stateLock = Any()
        @Volatile
        private var activeInstance: GrassBagEngineService? = null
        @Volatile
        private var wakeLockUntilMs: Long = 0L
        @Volatile
        private var lastNativeWorkHeartbeatMs: Long = 0L

        fun isServiceActive(): Boolean = serviceActive.get()

        fun isHoldingWakeLock(): Boolean =
            serviceActive.get() && SystemClock.elapsedRealtime() < wakeLockUntilMs

        fun hasNativeActiveWork(): Boolean {
            if (SafetyGate.hasActiveTurn()) return true
            val count = nativeActiveTurns.get() + nativeActiveJobs.get()
            if (count <= 0) return false
            return (SystemClock.elapsedRealtime() - lastNativeWorkHeartbeatMs) <= NATIVE_HEARTBEAT_MAX_STALE_MS
        }

        fun updateNativeActiveWork(
            ctx: Context,
            activeTurns: Int,
            activeJobs: Int,
            reason: String? = null
        ) {
            val turns = activeTurns.coerceAtLeast(0)
            val jobs = activeJobs.coerceAtLeast(0)
            nativeActiveTurns.set(turns)
            nativeActiveJobs.set(jobs)
            if (turns > 0 || jobs > 0) {
                lastNativeWorkHeartbeatMs = SystemClock.elapsedRealtime()
                val isPhone = SafetyGate.hasActiveTurn()
                val heading = when {
                    isPhone -> "GrassBag 正在操控手机"
                    turns > 0 -> "GrassBag 正在后台执行对话"
                    else -> "GrassBag 后台任务运行中"
                }
                val detail = when {
                    isPhone -> "操作执行中并保持网络稳定 · 可在悬浮岛随时暂停"
                    turns > 0 && jobs > 0 -> "$turns 个对话 + $jobs 个任务进行中 · 防止切后台断连"
                    turns > 0 -> "模型思考与工具执行中 · 后台 CPU/Wi-Fi 保活中"
                    else -> "$jobs 个后台任务运行中 · 持续保活中"
                }
                startOrUpdate(
                    ctx = ctx,
                    heading = heading,
                    detail = detail,
                    wakeLockMs = 10 * 60 * 1000L,
                    holdWifiLock = true
                )
            } else if (!SafetyGate.hasActiveTurn() && serviceActive.get()) {
                // Keep a short 90s cooldown before dropping WakeLock when a turn finishes
                // so multi-step follow-ups or quick app switches never race with lock release!
                val now = SystemClock.elapsedRealtime()
                if (wakeLockUntilMs > now + 90_000L) {
                    wakeLockUntilMs = now + 90_000L
                }
                val suffix = reason?.takeIf { it.isNotBlank() }?.let { " ($it)" } ?: ""
                startOrUpdate(
                    ctx = ctx,
                    heading = "GrassBag 本机引擎运行中",
                    detail = "本机 DSH 服务已就绪$suffix · 后台待命保活",
                    wakeLockMs = 90_000L,
                    holdWifiLock = true
                )
            }
        }

        fun clearNativeActiveWork() {
            nativeActiveTurns.set(0)
            nativeActiveJobs.set(0)
            lastNativeWorkHeartbeatMs = 0L
        }

        private fun isProcessForeground(ctx: Context): Boolean {
            return runCatching {
                val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return true
                val myPid = android.os.Process.myPid()
                val proc = am.runningAppProcesses?.firstOrNull { it.pid == myPid } ?: return true
                proc.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
            }.getOrDefault(true)
        }

        private fun canStartForegroundServiceFromBackground(ctx: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
            if (isProcessForeground(ctx)) return true
            if (GrassBagAccessibilityService.isRunning()) return true
            val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (pm != null && runCatching { pm.isIgnoringBatteryOptimizations(ctx.packageName) }.getOrDefault(false)) {
                return true
            }
            if (runCatching { Settings.canDrawOverlays(ctx) }.getOrDefault(false)) {
                return true
            }
            return false
        }

        fun registerChannels(ctx: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val mgr = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(ENGINE_CH) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(ENGINE_CH, "GrassBag 后台保活", NotificationManager.IMPORTANCE_LOW).apply {
                        setShowBadge(false)
                        enableVibration(false)
                        setSound(null, null)
                    }
                )
            }
            if (mgr.getNotificationChannel(ALERT_CH) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(ALERT_CH, "审批与任务完成提醒", NotificationManager.IMPORTANCE_HIGH)
                )
            }
        }

        fun startOrUpdate(
            ctx: Context,
            heading: String,
            detail: String,
            wakeLockMs: Long = 0L,
            releaseWakeLock: Boolean = false,
            holdWifiLock: Boolean = wakeLockMs > 0L
        ) {
            synchronized(stateLock) {
                registerChannels(ctx)
                val live = activeInstance
                // Fast, zero-IPC in-process update when the foreground service is ALREADY active!
                // Eliminates BackgroundServiceStartNotAllowedException races while operating other apps.
                if (serviceActive.get() && live != null && !pendingStop.get()) {
                    pendingStop.set(false)
                    startRequested.set(true)
                    live.updateInProcess(heading, detail, wakeLockMs, holdWifiLock, releaseWakeLock)
                    return
                }
                val fg = isProcessForeground(ctx)
                // On Android 12+, only start a brand-new FGS from background when an official OS exemption holds.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !serviceActive.get() && !canStartForegroundServiceFromBackground(ctx)) {
                    Log.i(TAG, "Skipping startForegroundService while app is backgrounded without FGS exemption")
                    return
                }
                val gen = intentGen.incrementAndGet()
                pendingStop.set(false)
                val svcIntent = Intent(ctx, GrassBagEngineService::class.java).apply {
                    putExtra(KEY_GEN, gen)
                    putExtra(KEY_HEADING, heading)
                    putExtra(KEY_DETAIL, detail)
                    putExtra(KEY_WAKELOCK_MS, wakeLockMs)
                    putExtra(KEY_WIFI_LOCK, holdWifiLock)
                    putExtra(KEY_RELEASE_WAKELOCK, releaseWakeLock)
                }
                startRequested.set(true)
                runCatching {
                    if (serviceActive.get() && (fg || Build.VERSION.SDK_INT < Build.VERSION_CODES.O)) {
                        ctx.startService(svcIntent)
                    } else if (serviceActive.get()) {
                        ctx.startService(svcIntent)
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        ctx.startForegroundService(svcIntent)
                    } else {
                        ctx.startService(svcIntent)
                    }
                }.onFailure { err ->
                    if (!serviceActive.get()) {
                        startRequested.set(false)
                        pendingStop.set(false)
                    }
                    Log.w(TAG, "startOrUpdate failed: ${err.message}")
                }
            }
        }

        fun stop(ctx: Context) {
            synchronized(stateLock) {
                // Never fire a ghost startService(ACTION_STOP) when FGS was never started or requested
                // (avoids ghost notification flash & Android 8+ background IllegalStateException).
                if (!serviceActive.get() && !startRequested.get()) {
                    return
                }
                val gen = intentGen.incrementAndGet()
                stopGen.set(gen)
                pendingStop.set(true)
                if (!serviceActive.get()) {
                    // Start intent is in flight (startForeground() has not run yet). Do NOT call ctx.stopService()
                    // here — onStartCommand() will fulfill startForeground() first and immediately self-stop cleanly!
                    return
                }
                startRequested.set(false)
                // When backgrounded on Android 8+, avoid ctx.startService(ACTION_STOP) which can race with
                // OS background start restrictions; stopping an already-foregrounded service via stopService() is safe.
                // Keep pendingStop=true (with stopGen=gen) so any in-flight startService intent with cmdGen <= stopGen
                // cannot resurrect the FGS + WakeLock if delivered before onDestroy().
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !isProcessForeground(ctx)) {
                    serviceActive.set(false)
                    runCatching { ctx.stopService(Intent(ctx, GrassBagEngineService::class.java)) }
                    return
                }
                val stopIntent = Intent(ctx, GrassBagEngineService::class.java).apply {
                    action = ACTION_STOP
                    putExtra(KEY_GEN, gen)
                }
                runCatching { ctx.startService(stopIntent) }.onFailure {
                    // Service is already active and foregrounded, so stopService fallback is safe here.
                    serviceActive.set(false)
                    runCatching { ctx.stopService(Intent(ctx, GrassBagEngineService::class.java)) }
                }
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
                .setSmallIcon(R.drawable.ic_stat_grassbag)
                .setContentTitle(heading)
                .setContentText(detail)
                .setAutoCancel(true)
                .setContentIntent(openApp)
                .build()
            runCatching { mgr.notify(id, alert) }
        }
    }
}
