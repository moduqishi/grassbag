package dev.grassbag.grassbag

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.graphics.drawable.ColorDrawable
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Base64
import android.util.Log
import android.webkit.CookieManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Proxy
import java.net.Socket
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

class GrassBagBridgePlugin(private val activity: Activity) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val bgPool = Executors.newCachedThreadPool()
    // Single-threaded FIFO executor for local PTY writes/resizes/signals so rapid typing never reorders!
    private val termIoExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "grassbag-term-io").apply { isDaemon = true }
    }
    private val vault by lazy { KeystoreVault.getInstance(activity.applicationContext) }
    private val runtimeReadyLatch = CountDownLatch(1)
    private val lifecycleLock = Any()
    private val lanScanLock = Any()
    @Volatile
    private var inFlightLanScan: java.util.concurrent.CompletableFuture<List<Map<String, Any>>>? = null
    @Volatile
    private var inFlightLanScanPort: Int = -1
    @Volatile
    private var runtime: RuntimeController? = null
    @Volatile
    private var runtimeInitError: String? = null
    @Volatile
    private var detached = false

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    @Volatile
    private var eventSink: EventChannel.EventSink? = null
    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingPermResult: MethodChannel.Result? = null
    private var pendingCameraPermResult: MethodChannel.Result? = null
    private var pendingCameraFile: File? = null
    private val runtimeListener: (String, Map<String, Any?>) -> Unit = { type, payload ->
        sendEvent(type, payload)
    }
    private val a11yStateListener: (Boolean) -> Unit = { connected ->
        sendEvent("accessibility_state", mapOf("connected" to connected))
    }

    private fun replySafe(result: MethodChannel.Result?, block: (MethodChannel.Result) -> Unit) {
        if (result == null || detached) return
        if (Looper.myLooper() == Looper.getMainLooper()) {
            if (!detached) runCatching { block(result) }
        } else {
            mainHandler.post {
                if (!detached) runCatching { block(result) }
            }
        }
    }

    private fun runBg(result: MethodChannel.Result? = null, block: () -> Unit) {
        if (detached || bgPool.isShutdown) {
            replySafe(result) { it.error("detached", "Bridge plugin detached", null) }
            return
        }
        try {
            bgPool.execute {
                try {
                    block()
                } catch (t: Throwable) {
                    Log.e("GrassBagBridgePlugin", "Unhandled error in bgPool task: ${t.message}", t)
                    replySafe(result) {
                        it.error("native_worker_error", t.message ?: t.javaClass.simpleName, null)
                    }
                }
            }
        } catch (t: Throwable) {
            replySafe(result) {
                it.error("executor_rejected", t.message ?: "Executor rejected task", null)
            }
        }
    }

    private fun runTermIo(result: MethodChannel.Result, block: () -> Unit) {
        if (detached || termIoExecutor.isShutdown) {
            replySafe(result) { it.success(false) }
            return
        }
        try {
            termIoExecutor.execute {
                runCatching { block() }.onFailure { t ->
                    Log.e("GrassBagBridgePlugin", "Unhandled error in termIoExecutor: ${t.message}", t)
                    replySafe(result) { it.success(false) }
                }
            }
        } catch (_: Throwable) {
            replySafe(result) { it.success(false) }
        }
    }

    private inline fun withRuntime(
        result: MethodChannel.Result,
        crossinline block: (RuntimeController) -> Unit
    ) {
        runBg(result) {
            runCatching { runtimeReadyLatch.await() }
            val rt = runtime
            if (rt == null) {
                val err = runtimeInitError ?: "本机运行时控制器初始化失败"
                replySafe(result) { it.error("runtime_init_failed", err, null) }
                return@runBg
            }
            block(rt)
        }
    }

    private val emergencyStopListener: () -> Unit = {
        if (!detached) {
            sendEvent("phone_emergency_stop", mapOf("stopped" to true))
        }
    }

    private val pauseStateListener: (Boolean) -> Unit = { paused ->
        if (!detached) {
            sendEvent("phone_pause_changed", mapOf("paused" to paused))
        }
    }

    fun attach(engine: FlutterEngine) {
        synchronized(lifecycleLock) {
            detached = false
        }
        GrassBagAccessibilityService.addStateListener(a11yStateListener)
        SafetyGate.addEmergencyStopListener(emergencyStopListener)
        SafetyGate.addPauseListener(pauseStateListener)
        bgPool.execute {
            try {
                SafetyGate.init(activity.applicationContext)
                // Clean up any orphaned camera/share temp files from previous interrupted sessions.
                runCatching {
                    val cutoff = System.currentTimeMillis() - 6 * 3600 * 1000L
                    listOf(File(activity.cacheDir, "camera"), File(activity.cacheDir, "share")).forEach { dir ->
                        dir.listFiles()?.forEach { f ->
                            if (f.isFile && f.lastModified() < cutoff) runCatching { f.delete() }
                        }
                    }
                }
                val rt = RuntimeController.getInstance(activity.applicationContext, vault)
                val shouldReplay = synchronized(lifecycleLock) {
                    runtime = rt
                    if (!detached) {
                        rt.addListener(runtimeListener)
                        true
                    } else {
                        false
                    }
                }
                if (shouldReplay) {
                    replayCurrentRuntimeSnapshot(rt)
                }
            } catch (t: Throwable) {
                runtimeInitError = t.message ?: t.javaClass.simpleName
            } finally {
                runtimeReadyLatch.countDown()
            }
        }
        methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    private fun replayCurrentRuntimeSnapshot(rt: RuntimeController) {
        if (detached || eventSink == null) return
        val snap = rt.currentEngineStateEvent()
        sendEvent("engine_state", snap)
    }

    fun detach() {
        val rtToRemove = synchronized(lifecycleLock) {
            detached = true
            runtime
        }
        GrassBagAccessibilityService.removeStateListener(a11yStateListener)
        SafetyGate.removeEmergencyStopListener(emergencyStopListener)
        SafetyGate.removePauseListener(pauseStateListener)
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
        pendingPickResult?.let { runCatching { it.success(null) } }
        pendingPickResult = null
        pendingPermResult?.let {
            runCatching { it.success(mapOf("granted" to false, "permanentlyDenied" to false)) }
        }
        pendingPermResult = null
        pendingCameraPermResult?.let { runCatching { it.success(null) } }
        pendingCameraPermResult = null
        pendingCameraFile = null
        // Only detach this Activity's event listener; keep the singleton Ubuntu + DSH container alive!
        rtToRemove?.removeListener(runtimeListener)
        mainHandler.removeCallbacksAndMessages(null)
        // Graceful shutdown so in-flight Keystore writes / status reads / PTY I/O complete cleanly.
        runCatching { bgPool.shutdown() }
        runCatching { termIoExecutor.shutdown() }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        sendEvent("accessibility_state", mapOf("connected" to GrassBagAccessibilityService.isRunning()))
        runtime?.let { rt ->
            runBg { replayCurrentRuntimeSnapshot(rt) }
        }
    }

    fun notifyForegroundResumed() {
        if (detached) return
        sendEvent("accessibility_state", mapOf("connected" to GrassBagAccessibilityService.isRunning()))
        // Re-check slightly after resume because OEM AccessibilityManagerService may finish
        // `onServiceConnected()` 150-350ms after the user navigates back from System Settings.
        mainHandler.postDelayed({
            if (!detached) {
                sendEvent("accessibility_state", mapOf("connected" to GrassBagAccessibilityService.isRunning()))
            }
        }, 400L)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun sendEvent(type: String, payload: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(mapOf("type" to type, "data" to payload))
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "runtime.status" -> withRuntime(result) { rt ->
                val res = rt.getStatus()
                replySafe(result) { it.success(res) }
            }
            "runtime.bootstrap" -> withRuntime(result) { rt ->
                rt.bootstrapRuntime { res ->
                    replySafe(result) { it.success(res) }
                }
            }
            "runtime.cancelBootstrap" -> withRuntime(result) { rt ->
                val res = rt.cancelBootstrap()
                replySafe(result) { it.success(res) }
            }
            "runtime.setRuntimeMirror" -> {
                val url = call.argument<String>("url") ?: ""
                withRuntime(result) { rt ->
                    val res = rt.setRuntimeMirrorUrl(url)
                    replySafe(result) { it.success(res) }
                }
            }
            "runtime.startEngine" -> withRuntime(result) { rt ->
                rt.startEngine { res ->
                    replySafe(result) { it.success(res) }
                }
            }
            "runtime.stopEngine" -> withRuntime(result) { rt ->
                val res = rt.stopEngine()
                replySafe(result) { it.success(res) }
            }
            "runtime.restartEngine" -> withRuntime(result) { rt ->
                rt.restartEngine { res ->
                    replySafe(result) { it.success(res) }
                }
            }
            "runtime.cleanCache" -> withRuntime(result) { rt ->
                val res = rt.cleanCache()
                replySafe(result) { it.success(res) }
            }
            "runtime.rebuildContainer" -> withRuntime(result) { rt ->
                rt.rebuildContainerPreserveHome { res ->
                    replySafe(result) { it.success(res) }
                }
            }
            "runtime.engineLogs" -> withRuntime(result) { rt ->
                val logs = rt.getEngineLogs()
                replySafe(result) { it.success(logs) }
            }
            "runtime.upgradeAb" -> {
                val version = call.argument<String>("version") ?: "0.2.3"
                val url = call.argument<String>("remoteUrl")
                withRuntime(result) { rt ->
                    rt.performAbUpgrade(version, url) { res ->
                        replySafe(result) { it.success(res) }
                    }
                }
            }
            "runtime.rollback" -> withRuntime(result) { rt ->
                rt.rollbackLkg { res ->
                    replySafe(result) { it.success(res) }
                }
            }
            "runtime.setExecutor" -> {
                val mode = call.argument<String>("mode") ?: "tawcroot"
                withRuntime(result) { rt ->
                    val res = rt.setExecutorMode(mode)
                    replySafe(result) { it.success(res) }
                }
            }
            "runtime.setSdcardMounted" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                withRuntime(result) { rt ->
                    val res = rt.setSdcardMounted(enabled)
                    replySafe(result) { it.success(res) }
                }
            }
            "runtime.setSystemProxy" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                withRuntime(result) { rt ->
                    val res = rt.setSystemProxy(enabled)
                    replySafe(result) { it.success(res) }
                }
            }
            "runtime.installToolkit" -> {
                val id = call.argument<String>("id") ?: ""
                val packages = call.argument<List<String>>("packages") ?: emptyList()
                withRuntime(result) { rt ->
                    rt.installToolkit(id, packages) { res ->
                        replySafe(result) { it.success(res) }
                    }
                }
            }
            "runtime.exportBackup" -> {
                val pass = call.argument<String>("passphrase") ?: "grassbag"
                withRuntime(result) { rt ->
                    val res = rt.exportEncryptedBackup(pass)
                    replySafe(result) { it.success(res) }
                }
            }

            // Local real shell sessions for xterm
            "term.start" -> {
                val tabId = call.argument<String>("tabId") ?: "local-1"
                val cwd = call.argument<String>("cwd")
                val cols = call.argument<Int>("cols") ?: 80
                val rows = call.argument<Int>("rows") ?: 24
                withRuntime(result) { rt ->
                    val res = rt.startLocalShell(tabId, cwd, cols, rows)
                    replySafe(result) { it.success(res) }
                }
            }
            "term.write" -> {
                val tabId = call.argument<String>("tabId") ?: "local-1"
                val data = call.argument<String>("data") ?: ""
                runTermIo(result) {
                    runCatching { runtimeReadyLatch.await() }
                    val rt = runtime
                    val ok = rt?.writeLocalShell(tabId, data) ?: false
                    replySafe(result) { it.success(ok) }
                }
            }
            "term.resize" -> {
                val tabId = call.argument<String>("tabId") ?: "local-1"
                val cols = call.argument<Int>("cols") ?: 80
                val rows = call.argument<Int>("rows") ?: 24
                runTermIo(result) {
                    runCatching { runtimeReadyLatch.await() }
                    val rt = runtime
                    val ok = rt?.resizeLocalShell(tabId, cols, rows) ?: false
                    replySafe(result) { it.success(ok) }
                }
            }
            "term.signal" -> {
                val tabId = call.argument<String>("tabId") ?: "local-1"
                val signal = call.argument<String>("signal") ?: "SIGINT"
                // Dispatch signals on bgPool (NEVER behind termIoExecutor) so a blocked stdin pipe
                // on one tab can never deadlock Ctrl+C / SIGTERM delivery!
                withRuntime(result) { rt ->
                    val ok = rt.signalLocalShell(tabId, signal)
                    replySafe(result) { it.success(ok) }
                }
            }
            "term.close" -> {
                val tabId = call.argument<String>("tabId") ?: "local-1"
                withRuntime(result) { rt ->
                    rt.closeLocalShell(tabId)
                    replySafe(result) { it.success(true) }
                }
            }

            // Keystore secrets (run off UI thread with OEM Keystore exception safety)
            "vault.put" -> {
                val k = call.argument<String>("key") ?: ""
                val v = call.argument<String>("value") ?: ""
                runBg(result) {
                    val ok = if (k.isNotEmpty()) runCatching { vault.putSecret(k, v); true }.getOrDefault(false) else false
                    replySafe(result) { it.success(ok) }
                }
            }
            "vault.get" -> {
                val k = call.argument<String>("key") ?: ""
                runBg(result) {
                    val v = if (k.isEmpty()) null else runCatching { vault.getSecret(k) }.getOrNull()
                    replySafe(result) { it.success(v) }
                }
            }
            "vault.delete" -> {
                val k = call.argument<String>("key") ?: ""
                runBg(result) {
                    if (k.isNotEmpty()) runCatching { vault.deleteSecret(k) }
                    replySafe(result) { it.success(true) }
                }
            }

            // SafetyGate & Phone Control (dispatched off Android UI thread!)
            "safety.status" -> {
                runBg(result) {
                    val snap = SafetyGate.statusSnapshot().toMutableMap()
                    snap["hudVisible"] = PhoneOverlayController.getInstance(activity.applicationContext).isHudVisible()
                    replySafe(result) { it.success(snap) }
                }
            }
            "safety.setPolicy" -> {
                val raw = (call.argument<String>("policy") ?: "ask").uppercase()
                val tier = runCatching { SafetyGate.PolicyTier.valueOf(raw) }
                    .getOrDefault(SafetyGate.PolicyTier.ASK)
                runBg(result) {
                    val ok = SafetyGate.setPolicy(tier)
                    replySafe(result) { it.success(ok) }
                }
            }
            "safety.setChatPermissionPreset" -> {
                val preset = call.argument<String>("preset") ?: "workspace-write"
                SafetyGate.setSyncedChatPermissionPreset(preset)
                replySafe(result) { it.success(true) }
            }
            "safety.setConfirmHighRisk" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                runBg(result) {
                    SafetyGate.setConfirmHighRisk(enabled)
                    replySafe(result) { it.success(true) }
                }
            }
            "safety.setAutoReturn" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                runBg(result) {
                    SafetyGate.setAutoReturnEnabled(enabled)
                    PhoneOverlayController.getInstance(activity.applicationContext).refreshVisualPreferences()
                    replySafe(result) { it.success(true) }
                }
            }
            "safety.setShowEdgeAurora" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                runBg(result) {
                    SafetyGate.setShowEdgeAurora(enabled)
                    PhoneOverlayController.getInstance(activity.applicationContext).refreshVisualPreferences()
                    replySafe(result) { it.success(true) }
                }
            }
            "safety.setShowGestureFx" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                runBg(result) {
                    SafetyGate.setShowGestureFx(enabled)
                    PhoneOverlayController.getInstance(activity.applicationContext).refreshVisualPreferences()
                    replySafe(result) { it.success(true) }
                }
            }
            "safety.setPaused" -> {
                val paused = call.argument<Boolean>("paused") ?: false
                runBg(result) {
                    SafetyGate.setPaused(paused)
                    PhoneOverlayController.getInstance(activity.applicationContext).syncPausedState(paused)
                    replySafe(result) { it.success(true) }
                }
            }
            "safety.returnToApp" -> {
                runBg(result) {
                    val ok = PhoneOverlayController.getInstance(activity.applicationContext).bringGrassBagToFrontNow()
                    replySafe(result) { it.success(ok) }
                }
            }
            "safety.notifyTurnDone" -> {
                val sid = call.argument<String>("sessionId")?.takeIf { it.isNotBlank() }
                val reason = call.argument<String>("reason") ?: "completed"
                val summary = call.argument<String>("summary") ?: ""
                runBg(result) {
                    val ended = SafetyGate.endTurn(sid)
                    val overlay = PhoneOverlayController.getInstance(activity.applicationContext)
                    val shouldFinalize = ended || overlay.isHudSessionActive()
                    val isStopped = SafetyGate.isNonSuccessTurnEndReason(reason)
                    val autoReturn = shouldFinalize && !isStopped && SafetyGate.isAutoReturnEnabled()
                    if (shouldFinalize && !SafetyGate.hasActiveTurn()) {
                        overlay.showCompletionAndReturn(
                            summary = summary,
                            reason = reason,
                            autoReturn = autoReturn
                        )
                    }
                    replySafe(result) { it.success(shouldFinalize) }
                }
            }
            "safety.emergencyStop" -> {
                runBg(result) {
                    SafetyGate.triggerEmergencyStop()
                    PhoneOverlayController.getInstance(activity.applicationContext).dismissAll()
                    replySafe(result) { it.success(true) }
                }
            }
            "safety.resetStop" -> {
                runBg(result) {
                    SafetyGate.resetEmergencyStop()
                    replySafe(result) { it.success(true) }
                }
            }
            "safety.previewOverlay" -> {
                val mode = call.argument<String>("mode") ?: "interactive"
                runBg(result) {
                    PhoneOverlayController.getInstance(activity.applicationContext).showPreviewDemo(mode = mode)
                    replySafe(result) { it.success(true) }
                }
            }
            "app.syncThemeMode" -> {
                val isDark = call.argument<Boolean>("isDark") ?: false
                val followSystemTheme = call.argument<Boolean>("followSystemTheme") ?: false
                // Dart Color.toARGB32() values (0xFF...... > 0x7FFFFFFF) arrive as java.lang.Long via StandardMessageCodec.
                val accentPrimary = call.argument<Number>("accentPrimary")?.toLong()?.toInt()
                val accentHi = call.argument<Number>("accentHi")?.toLong()?.toInt()
                val bgSolid = call.argument<Number>("bgSolid")?.toLong()?.toInt()
                val editor = activity.applicationContext
                    .getSharedPreferences("gb_native_ui_v1", Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean("isDark", isDark)
                    .putBoolean("followSystemTheme", followSystemTheme)
                if (accentPrimary != null) editor.putInt("accentPrimary", accentPrimary)
                if (accentHi != null) editor.putInt("accentHi", accentHi)
                if (bgSolid != null) editor.putInt("bgSolid", bgSolid)
                editor.apply()
                val resolvedBg = bgSolid ?: if (isDark) 0xFF192130.toInt() else 0xFFEDF4FB.toInt()
                mainHandler.post {
                    runCatching {
                        val win = activity.window
                        if (win != null) {
                            win.setBackgroundDrawable(ColorDrawable(resolvedBg))
                            val insetsCtrl = androidx.core.view.WindowInsetsControllerCompat(win, win.decorView)
                            insetsCtrl.isAppearanceLightStatusBars = !isDark
                            insetsCtrl.isAppearanceLightNavigationBars = !isDark
                        }
                    }
                }
                PhoneOverlayController.getInstance(activity.applicationContext).refreshVisualPreferences()
                replySafe(result) { it.success(true) }
            }

            // Background foreground service & alert notifications (off UI thread to avoid Binder stalls)
            "service.start" -> {
                val title = call.argument<String>("title") ?: "GrassBag 本机环境运行中"
                val text = call.argument<String>("text") ?: "对话与终端后台保活通道已就绪"
                val wakeLockMs = call.argument<Number>("wakeLockMs")?.toLong() ?: 0L
                val holdWifiLock = call.argument<Boolean>("holdWifiLock") ?: (wakeLockMs > 0L)
                val releaseWakeLock = call.argument<Boolean>("releaseWakeLock") ?: false
                runBg(result) {
                    GrassBagEngineService.startOrUpdate(
                        ctx = activity.applicationContext,
                        heading = title,
                        detail = text,
                        wakeLockMs = wakeLockMs,
                        releaseWakeLock = releaseWakeLock,
                        holdWifiLock = holdWifiLock
                    )
                    replySafe(result) { it.success(true) }
                }
            }
            "service.stop" -> {
                runBg(result) {
                    GrassBagEngineService.stop(activity.applicationContext)
                    replySafe(result) { it.success(true) }
                }
            }
            "service.notify" -> {
                val title = call.argument<String>("title") ?: "GrassBag"
                val text = call.argument<String>("text") ?: ""
                runBg(result) {
                    GrassBagEngineService.postAlertNotification(activity.applicationContext, title, text)
                    replySafe(result) { it.success(true) }
                }
            }

            // Permissions status & OS settings deep links (off UI thread: avoids 6+ Binder IPCs on UI Looper!)
            "permissions.status" -> {
                runBg(result) {
                    val status = readPermissionsStatus()
                    replySafe(result) { it.success(status) }
                }
            }
            "permissions.openSettings" -> {
                val target = call.argument<String>("target") ?: "app"
                openPermissionScreen(target)
                replySafe(result) { it.success(true) }
            }
            "permissions.requestRuntime" -> {
                val target = call.argument<String>("target") ?: ""
                requestRuntimePermission(target, result)
            }

            // Native attachment pickers (gallery / camera / file)
            "picker.pickFile" -> {
                val mime = call.argument<String>("mime") ?: "*/*"
                launchDocumentPicker(mime, result)
            }
            "picker.takePhoto" -> launchCameraPicker(result)

            // Native share sheet, external browser & LAN DSH host discovery
            "device.openUrl" -> {
                val rawUrl = call.argument<String>("url")?.trim() ?: ""
                val uri = runCatching { Uri.parse(rawUrl) }.getOrNull()
                val scheme = uri?.scheme?.lowercase()
                if (uri != null && (scheme == "http" || scheme == "https")) {
                    val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    val ok = runCatching {
                        activity.startActivity(intent)
                        true
                    }.getOrDefault(false)
                    replySafe(result) { it.success(ok) }
                } else {
                    replySafe(result) { it.success(false) }
                }
            }
            "device.shareText" -> {
                val text = call.argument<String>("text") ?: ""
                runBg(result) {
                    val ok = runCatching {
                        val utf8 = text.toByteArray(Charsets.UTF_8)
                        val intent = if (utf8.size > 96 * 1024) {
                            // Large session exports exceed Android Binder's 1MB IPC buffer: share as a FileProvider attachment.
                            val shareDir = File(activity.cacheDir, "share").apply { mkdirs() }
                            val file = File(shareDir, "grassbag-export-${System.currentTimeMillis()}.md")
                            file.writeBytes(utf8)
                            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", file)
                            Intent(Intent.ACTION_SEND).apply {
                                type = "text/markdown"
                                putExtra(Intent.EXTRA_STREAM, uri)
                                clipData = ClipData.newRawUri(file.name, uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                        } else {
                            Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, text)
                            }
                        }
                        mainHandler.post {
                            if (!detached) {
                                runCatching {
                                    val chooser = Intent.createChooser(intent, "分享内容").apply {
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    }
                                    activity.startActivity(chooser)
                                }
                            }
                        }
                        true
                    }.getOrDefault(false)
                    replySafe(result) { it.success(ok) }
                }
            }
            "lan.scan" -> {
                val port = call.argument<Int>("port") ?: 3080
                runBg(result) {
                    val found = scanLanHosts(port)
                    replySafe(result) { it.success(found) }
                }
            }
            "device.localIps" -> {
                runBg(result) {
                    val ips = collectAllLocalDeviceIps().toList()
                    replySafe(result) { it.success(ips) }
                }
            }
            "webview.getCookies" -> {
                val url = call.argument<String>("url") ?: ""
                if (url.isBlank()) {
                    replySafe(result) { it.success(null) }
                    return
                }
                runBg(result) {
                    val cookies = runCatching {
                        val cm = CookieManager.getInstance()
                        cm.flush()
                        cm.getCookie(url)
                    }.getOrNull()
                    replySafe(result) { it.success(cookies) }
                }
            }
            "webview.setCookies" -> {
                val url = call.argument<String>("url") ?: ""
                val header = call.argument<String>("cookieHeader") ?: ""
                if (url.isBlank() || header.isBlank()) {
                    replySafe(result) { it.success(false) }
                    return
                }
                runBg(result) {
                    val ok = runCatching {
                        val cm = CookieManager.getInstance()
                        cm.setAcceptCookie(true)
                        val secureSuffix = if (url.startsWith("https://", ignoreCase = true)) "; Secure" else ""
                        for (part in header.split(";")) {
                            val trimmed = part.trim()
                            if (trimmed.contains("=")) {
                                cm.setCookie(url, "$trimmed; Path=/$secureSuffix")
                            }
                        }
                        cm.flush()
                        true
                    }.getOrDefault(false)
                    replySafe(result) { it.success(ok) }
                }
            }
            "webview.clearCookies" -> {
                runBg(result) {
                    runCatching {
                        val cm = CookieManager.getInstance()
                        cm.removeAllCookies {
                            // Flush SQLite cookie store OFF the UI thread!
                            runBg { runCatching { cm.flush() } }
                            replySafe(result) { it.success(true) }
                        }
                    }.onFailure {
                        replySafe(result) { it.success(false) }
                    }
                }
            }
            "app.getVersion" -> {
                val info = runCatching {
                    val pm = activity.packageManager
                    val pkgInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        pm.getPackageInfo(
                            activity.packageName,
                            android.content.pm.PackageManager.PackageInfoFlags.of(0),
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        pm.getPackageInfo(activity.packageName, 0)
                    }
                    val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        pkgInfo.longVersionCode
                    } else {
                        @Suppress("DEPRECATION")
                        pkgInfo.versionCode.toLong()
                    }
                    mapOf(
                        "versionName" to (pkgInfo.versionName ?: "0.1.0"),
                        "buildNumber" to versionCode.toInt(),
                        "packageName" to activity.packageName,
                    )
                }.getOrElse {
                    mapOf(
                        "versionName" to "0.1.0",
                        "buildNumber" to 1,
                        "packageName" to activity.packageName,
                    )
                }
                replySafe(result) { it.success(info) }
            }
            "app.getUpdatesDir" -> {
                val dir = File(activity.cacheDir, "updates").apply { mkdirs() }
                replySafe(result) { it.success(dir.absolutePath) }
            }
            "app.installApk" -> {
                val rawPath = call.argument<String>("path")?.trim() ?: ""
                if (rawPath.isEmpty()) {
                    replySafe(result) { it.success("error:missing_path") }
                    return
                }
                runBg(result) {
                    val allowedDir = File(activity.cacheDir, "updates").canonicalFile
                    val apkFile = runCatching { File(rawPath).canonicalFile }.getOrNull()
                    val allowedPrefix = allowedDir.path.trimEnd(File.separatorChar) + File.separator
                    if (apkFile == null || !apkFile.path.startsWith(allowedPrefix)) {
                        replySafe(result) { it.success("error:invalid_apk_path") }
                        return@runBg
                    }
                    if (!apkFile.isFile || apkFile.length() <= 0L) {
                        replySafe(result) { it.success("error:file_not_found") }
                        return@runBg
                    }
                    mainHandler.post {
                        if (detached) return@post
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !activity.packageManager.canRequestPackageInstalls()
                        ) {
                            runCatching {
                                val settingsIntent = Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:${activity.packageName}"),
                                ).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                activity.startActivity(settingsIntent)
                            }
                            replySafe(result) { it.success("permission_required") }
                            return@post
                        }
                        val outcome = runCatching {
                            val apkUri = FileProvider.getUriForFile(
                                activity,
                                "${activity.packageName}.fileprovider",
                                apkFile,
                            )
                            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(apkUri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            activity.startActivity(installIntent)
                            "started"
                        }.getOrElse { err ->
                            "error:${err.message ?: err.javaClass.simpleName}"
                        }
                        replySafe(result) { it.success(outcome) }
                    }
                }
            }
            else -> replySafe(result) { it.notImplemented() }
        }
    }

    private fun readPermissionsStatus(): Map<String, Any> {
        val ctx = activity.applicationContext
        val pm = ctx.getSystemService(Activity.POWER_SERVICE) as PowerManager
        val batteryIgnored = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            pm.isIgnoringBatteryOptimizations(ctx.packageName)
        } else true
        val overlayOk = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(ctx)
        } else true
        val storageOk = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(ctx, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }
        val notificationsOk = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else true
        val microphoneOk = ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val a11yRunning = GrassBagAccessibilityService.isRunning()
        val a11ySystemBound = GrassBagAccessibilityService.isSystemServiceActive(ctx)
        val a11ySettingOn = GrassBagAccessibilityService.isSettingEnabled(ctx, precheckedSystemBound = a11ySystemBound)
        val shizukuInstalled = runCatching {
            ctx.packageManager.getPackageInfo("moe.shizuku.privileged.api", 0)
            true
        }.getOrDefault(false)
        return mapOf(
            "accessibilityEnabled" to a11yRunning,
            "accessibilitySettingEnabled" to a11ySettingOn,
            "accessibilitySystemBound" to a11ySystemBound,
            "overlayGranted" to overlayOk,
            "allFilesGranted" to storageOk,
            "batteryOptIgnored" to batteryIgnored,
            "notificationsGranted" to notificationsOk,
            "microphoneGranted" to microphoneOk,
            "shizukuInstalled" to shizukuInstalled,
            "sdkInt" to Build.VERSION.SDK_INT
        )
    }

    private fun requestRuntimePermission(target: String, result: MethodChannel.Result) {
        val perms = when (target) {
            "notifications" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                arrayOf(Manifest.permission.POST_NOTIFICATIONS)
            } else emptyArray()
            "microphone" -> arrayOf(Manifest.permission.RECORD_AUDIO)
            "camera" -> arrayOf(Manifest.permission.CAMERA)
            "storage" -> if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE)
            } else emptyArray()
            else -> emptyArray()
        }
        if (perms.isEmpty()) {
            val alreadyGranted = when (target) {
                "notifications" -> true
                "storage" -> Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()
                else -> false
            }
            if (!alreadyGranted) {
                openPermissionScreen(target)
            }
            result.success(mapOf("granted" to alreadyGranted, "permanentlyDenied" to false))
            return
        }
        val allGranted = perms.all {
            ContextCompat.checkSelfPermission(activity, it) == PackageManager.PERMISSION_GRANTED
        }
        if (allGranted) {
            result.success(mapOf("granted" to true, "permanentlyDenied" to false))
            return
        }
        pendingPermResult?.let {
            runCatching { it.success(mapOf("granted" to false, "permanentlyDenied" to false)) }
        }
        pendingPermResult = result
        runCatching {
            ActivityCompat.requestPermissions(activity, perms, REQ_RUNTIME_PERM)
        }.onFailure {
            pendingPermResult = null
            result.success(mapOf("granted" to false, "permanentlyDenied" to false))
        }
    }

    fun handleRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode == REQ_CAMERA_PERM) {
            val res = pendingCameraPermResult ?: return false
            pendingCameraPermResult = null
            val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            if (granted) {
                launchCameraCaptureIntent(res)
            } else {
                res.success(null)
            }
            return true
        }
        if (requestCode != REQ_RUNTIME_PERM) return false
        val res = pendingPermResult ?: return false
        pendingPermResult = null
        val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        val permanentlyDenied = !granted && permissions.isNotEmpty() && permissions.any { perm ->
            !ActivityCompat.shouldShowRequestPermissionRationale(activity, perm)
        }
        res.success(mapOf("granted" to granted, "permanentlyDenied" to permanentlyDenied))
        return true
    }

    private fun openPermissionScreen(target: String) {
        val pkgUri = Uri.parse("package:${activity.packageName}")
        val appDetails = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkgUri)
        val candidates: List<Intent> = when (target) {
            "accessibility" -> {
                val componentName = ComponentName(
                    activity.packageName,
                    GrassBagAccessibilityService::class.java.name
                ).flattenToString()
                val highlightArgs = Bundle().apply {
                    putString(":settings:fragment_args_key", componentName)
                }
                val highlighted = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                    putExtra(":settings:fragment_args_key", componentName)
                    putExtra(":settings:show_fragment_args", highlightArgs)
                }
                listOf(highlighted, Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS), appDetails)
            }
            "overlay" -> listOf(
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, pkgUri),
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION),
                appDetails
            )
            "storage" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                listOf(
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, pkgUri),
                    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
                    appDetails
                )
            } else {
                listOf(appDetails)
            }
            "battery" -> listOf(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, pkgUri),
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
                appDetails
            )
            "notifications" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                listOf(
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName),
                    appDetails
                )
            } else {
                listOf(appDetails)
            }
            "shizuku" -> {
                val launch = activity.packageManager.getLaunchIntentForPackage("moe.shizuku.privileged.api")
                if (launch != null) listOf(launch, appDetails) else listOf(appDetails)
            }
            else -> listOf(appDetails)
        }
        for (intent in candidates) {
            val ok = runCatching {
                activity.startActivity(intent)
                true
            }.getOrDefault(false)
            if (ok) return
        }
    }

    private fun launchDocumentPicker(mime: String, result: MethodChannel.Result) {
        pendingPickResult?.let { replySafe(it) { r -> r.success(null) } }
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
        }
        runCatching {
            activity.startActivityForResult(intent, REQ_PICK_FILE)
        }.onFailure {
            pendingPickResult = null
            replySafe(result) { it.success(null) }
        }
    }

    private fun launchCameraPicker(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            pendingCameraPermResult?.let { replySafe(it) { r -> r.success(null) } }
            pendingCameraPermResult = result
            runCatching {
                ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.CAMERA), REQ_CAMERA_PERM)
            }.onFailure {
                pendingCameraPermResult = null
                replySafe(result) { it.success(null) }
            }
            return
        }
        launchCameraCaptureIntent(result)
    }

    private fun launchCameraCaptureIntent(result: MethodChannel.Result) {
        pendingPickResult?.let { replySafe(it) { r -> r.success(null) } }
        pendingPickResult = result
        runCatching {
            val camDir = File(activity.cacheDir, "camera").apply { mkdirs() }
            val photo = File(camDir, "gb_photo_${System.currentTimeMillis()}.jpg")
            pendingCameraFile = photo
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", photo)
            val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                putExtra(MediaStore.EXTRA_OUTPUT, uri)
                clipData = ClipData.newRawUri("", uri)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivityForResult(intent, REQ_CAMERA)
        }.onFailure {
            pendingPickResult = null
            pendingCameraFile = null
            replySafe(result) { it.success(null) }
        }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val res = pendingPickResult ?: return false
        if (requestCode != REQ_PICK_FILE && requestCode != REQ_CAMERA) return false
        pendingPickResult = null

        if (resultCode != Activity.RESULT_OK) {
            pendingCameraFile?.let { runCatching { it.delete() } }
            pendingCameraFile = null
            replySafe(res) { it.success(null) }
            return true
        }

        if (requestCode == REQ_CAMERA) {
            val photo = pendingCameraFile
            pendingCameraFile = null
            if (photo == null || !photo.exists()) {
                replySafe(res) { it.success(null) }
                return true
            }
            runBg(res) {
                val payload = readAndCompressCameraPhoto(photo)
                replySafe(res) { it.success(payload) }
            }
            return true
        }

        val uri = data?.data
        if (uri == null) {
            replySafe(res) { it.success(null) }
            return true
        }
        runBg(res) {
            val meta = readPickedUri(uri)
            replySafe(res) { it.success(meta) }
        }
        return true
    }

    private fun compressAndRotateImageBytes(
        rawBytes: ByteArray,
        origMime: String,
        maxBytes: Int = 2 * 1024 * 1024
    ): Pair<ByteArray, String> {
        val lowerMime = origMime.lowercase()
        val isHeic = lowerMime.contains("heic") || lowerMime.contains("heif")
        val orientation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            runCatching {
                ExifInterface(ByteArrayInputStream(rawBytes)).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL
                )
            }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        } else {
            ExifInterface.ORIENTATION_NORMAL
        }
        val needsRotation = orientation != ExifInterface.ORIENTATION_NORMAL &&
            orientation != ExifInterface.ORIENTATION_UNDEFINED
        if (!isHeic && !needsRotation && rawBytes.size <= maxBytes) {
            return rawBytes to origMime
        }

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size, bounds)
        var sample = 1
        val maxDim = maxOf(bounds.outWidth, bounds.outHeight)
        while (maxDim > 0 && maxDim / sample > 2048) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        var bmp = BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size, opts) ?: return rawBytes to origMime
        try {
            if (needsRotation) {
                val matrix = Matrix()
                when (orientation) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
                    ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
                    ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.preScale(-1f, 1f)
                    ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.preScale(1f, -1f)
                    ExifInterface.ORIENTATION_TRANSPOSE -> {
                        matrix.postRotate(90f); matrix.postScale(-1f, 1f)
                    }
                    ExifInterface.ORIENTATION_TRANSVERSE -> {
                        matrix.postRotate(270f); matrix.postScale(-1f, 1f)
                    }
                }
                if (!matrix.isIdentity) {
                    val rotated = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, matrix, true)
                    if (rotated !== bmp) {
                        bmp.recycle()
                        bmp = rotated
                    }
                }
            }
            var quality = 86
            var compressed: ByteArray
            do {
                val baos = ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.JPEG, quality, baos)
                compressed = baos.toByteArray()
                quality -= 12
            } while (compressed.size > maxBytes && quality >= 35)
            return compressed to "image/jpeg"
        } finally {
            bmp.recycle()
        }
    }

    private fun readAndCompressCameraPhoto(photo: File): Map<String, Any>? {
        return try {
            val path = photo.absolutePath
            val orientation = runCatching {
                ExifInterface(path).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL
                )
            }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
            val needsRotation = orientation != ExifInterface.ORIENTATION_NORMAL &&
                orientation != ExifInterface.ORIENTATION_UNDEFINED
            val maxBytes = 2 * 1024 * 1024
            if (!needsRotation && photo.length() in 1L..maxBytes.toLong()) {
                val directBytes = photo.readBytes()
                return mapOf(
                    "name" to photo.name,
                    "mimeType" to "image/jpeg",
                    "size" to directBytes.size,
                    "bytes" to directBytes
                )
            }
            // Decode directly from disk with inSampleSize so 50MP+ camera photos never OOM JVM heap!
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            val maxDim = maxOf(bounds.outWidth, bounds.outHeight)
            while (maxDim > 0 && maxDim / sample > 2048) sample *= 2
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            var bmp = BitmapFactory.decodeFile(path, opts)
                ?: return mapOf("name" to photo.name, "mimeType" to "image/jpeg", "error" to "无法解码拍摄照片")
            val finalBytes = try {
                if (needsRotation) {
                    val matrix = Matrix()
                    when (orientation) {
                        ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
                        ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
                        ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
                        ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.preScale(-1f, 1f)
                        ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.preScale(1f, -1f)
                        ExifInterface.ORIENTATION_TRANSPOSE -> {
                            matrix.postRotate(90f); matrix.postScale(-1f, 1f)
                        }
                        ExifInterface.ORIENTATION_TRANSVERSE -> {
                            matrix.postRotate(270f); matrix.postScale(-1f, 1f)
                        }
                    }
                    if (!matrix.isIdentity) {
                        val rotated = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, matrix, true)
                        if (rotated !== bmp) {
                            bmp.recycle()
                            bmp = rotated
                        }
                    }
                }
                var quality = 86
                var compressed: ByteArray
                do {
                    val baos = ByteArrayOutputStream()
                    bmp.compress(Bitmap.CompressFormat.JPEG, quality, baos)
                    compressed = baos.toByteArray()
                    quality -= 12
                } while (compressed.size > maxBytes && quality >= 35)
                compressed
            } finally {
                bmp.recycle()
            }
            if (finalBytes.size > 4 * 1024 * 1024) {
                mapOf("name" to photo.name, "mimeType" to "image/jpeg", "error" to "拍摄照片超过 4 MB 大小上限")
            } else {
                mapOf(
                    "name" to photo.name,
                    "mimeType" to "image/jpeg",
                    "size" to finalBytes.size,
                    "bytes" to finalBytes
                )
            }
        } catch (e: Throwable) {
            mapOf("name" to photo.name, "mimeType" to "image/jpeg", "error" to (e.message ?: "读取照片失败"))
        } finally {
            runCatching { photo.delete() }
        }
    }

    private fun readPickedUri(uri: Uri): Map<String, Any>? = runCatching {
        val cr = activity.contentResolver
        var displayName = "attachment"
        cr.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) displayName = c.getString(0) ?: displayName
        }
        val mime = cr.getType(uri) ?: "application/octet-stream"
        val isImage = mime.startsWith("image/", ignoreCase = true) ||
            displayName.lowercase().let { n ->
                n.endsWith(".jpg") || n.endsWith(".jpeg") || n.endsWith(".png") ||
                    n.endsWith(".webp") || n.endsWith(".heic") || n.endsWith(".heif")
            }
        // Allow up to 24 MB raw input for gallery photos (compressed & EXIF-rotated to <= 2 MB JPEG).
        val maxReadBytes = if (isImage) 24 * 1024 * 1024 else 4 * 1024 * 1024
        val baos = ByteArrayOutputStream()
        var exceeded = false
        cr.openInputStream(uri)?.use { ins ->
            val buf = ByteArray(16384)
            while (true) {
                val n = ins.read(buf)
                if (n <= 0) break
                if (baos.size() + n > maxReadBytes) {
                    exceeded = true
                    break
                }
                baos.write(buf, 0, n)
            }
        }
        if (exceeded) {
            return@runCatching mapOf(
                "name" to displayName,
                "mimeType" to mime,
                "error" to (if (isImage) "图片原始体积超过 24 MB 上限" else "文件超过 4 MB 大小上限")
            )
        }
        var bytes = baos.toByteArray()
        var finalMime = mime
        var finalName = displayName
        if (isImage && !mime.equals("image/gif", ignoreCase = true)) {
            val (compBytes, compMime) = compressAndRotateImageBytes(bytes, mime)
            bytes = compBytes
            finalMime = compMime
            if (finalMime == "image/jpeg" && (displayName.endsWith(".heic", true) || displayName.endsWith(".heif", true))) {
                finalName = displayName.replace(Regex("""\.(heic|heif)$""", RegexOption.IGNORE_CASE), ".jpg")
            }
        }
        if (bytes.size > 4 * 1024 * 1024) {
            return@runCatching mapOf(
                "name" to finalName,
                "mimeType" to finalMime,
                "error" to "文件超过 4 MB 大小上限"
            )
        }
        mapOf(
            "name" to finalName,
            "mimeType" to finalMime,
            "size" to bytes.size,
            "bytes" to bytes
        )
    }.getOrNull()

    /**
     * Collect ALL local IP addresses across EVERY active network interface on this Android device
     * (Wi-Fi, dual-Wi-Fi, hotspot/ap0/swlan0, Ethernet, cellular, VPN, loopback) so LAN discovery
     * and remote host creation NEVER treat the phone itself as a remote host.
     */
    private fun collectAllLocalDeviceIps(): Set<String> {
        val ips = LinkedHashSet<String>()
        ips.add("127.0.0.1")
        ips.add("::1")
        ips.add("0.0.0.0")
        runCatching {
            val ifaces = NetworkInterface.getNetworkInterfaces()
            while (ifaces.hasMoreElements()) {
                val iface = ifaces.nextElement()
                val addrs = iface.inetAddresses
                while (addrs.hasMoreElements()) {
                    val raw = addrs.nextElement().hostAddress ?: continue
                    val clean = raw.substringBefore('%').lowercase()
                    if (clean.isNotEmpty()) ips.add(clean)
                }
            }
        }
        return ips
    }

    /**
     * Wi-Fi / Ethernet /24 parallel LAN probe skipping cellular (`rmnet*`), VPN (`tun*`), and ALL
     * local device IPs across every interface. Probes both standard `dsh web` (:3080) and
     * DSH Desktop LAN Bridge (:3081) simultaneously.
     */
    private fun scanLanHosts(port: Int): List<Map<String, Any>> {
        // Coalesce concurrent scans on the same port so rapid UI taps never stack 128+ scan threads.
        val existing: java.util.concurrent.CompletableFuture<List<Map<String, Any>>>?
        val mine: java.util.concurrent.CompletableFuture<List<Map<String, Any>>>
        synchronized(lanScanLock) {
            val cur = inFlightLanScan
            if (cur != null && !cur.isDone && inFlightLanScanPort == port) {
                existing = cur
                mine = cur
            } else {
                existing = null
                mine = java.util.concurrent.CompletableFuture()
                inFlightLanScan = mine
                inFlightLanScanPort = port
            }
        }
        if (existing != null) {
            return runCatching { existing.get(10, java.util.concurrent.TimeUnit.SECONDS) }.getOrDefault(emptyList())
        }
        return try {
            val res = runLanScanInternal(port)
            mine.complete(res)
            res
        } catch (t: Throwable) {
            mine.completeExceptionally(t)
            emptyList()
        } finally {
            synchronized(lanScanLock) {
                if (inFlightLanScan === mine) {
                    inFlightLanScan = null
                }
            }
        }
    }

    private fun runLanScanInternal(port: Int): List<Map<String, Any>> {
        val selfIps = collectAllLocalDeviceIps()
        val portsToScan = if (port == 3080) listOf(3080, 3081) else listOf(port)
        val candidates = LinkedHashSet<String>()
        val isEmulator = Build.FINGERPRINT.contains("generic", true) ||
            Build.MODEL.contains("Emulator", true) ||
            Build.MODEL.contains("sdk_gphone", true) ||
            Build.HARDWARE.contains("ranchu", true) ||
            Build.HARDWARE.contains("goldfish", true)
        if (isEmulator) {
            candidates.add("10.0.2.2")
        }
        // 1) Prioritize active ARP neighbors first so Macs/PCs on high DHCP IPs (.200-.254) are found in <300ms!
        runCatching {
            val arpFile = File("/proc/net/arp")
            if (arpFile.isFile && arpFile.canRead()) {
                arpFile.readLines().drop(1).forEach { line ->
                    val cols = line.trim().split(Regex("\\s+"))
                    if (cols.size >= 4) {
                        val ip = cols[0]
                        val flags = cols[2]
                        if (flags != "0x0" &&
                            ip.matches(Regex("^\\d+\\.\\d+\\.\\d+\\.\\d+$")) &&
                            ip !in selfIps &&
                            !ip.startsWith("127.") &&
                            ip != "0.0.0.0"
                        ) {
                            candidates.add(ip)
                        }
                    }
                }
            }
        }
        // 2) Full LAN interface /24 subnet sweep (including wlan/wifi/eth/ap/swlan/softap/usb)
        runCatching {
            val ifaces = NetworkInterface.getNetworkInterfaces()
            while (ifaces.hasMoreElements()) {
                val iface = ifaces.nextElement()
                if (!iface.isUp || iface.isLoopback) continue
                val n = iface.name.lowercase()
                val isLanIface = n.startsWith("wlan") || n.startsWith("wifi") || n.startsWith("eth") ||
                    n.startsWith("ap") || n.startsWith("swlan") || n.startsWith("softap") ||
                    n.startsWith("rndis") || n.startsWith("usb") || n.startsWith("br")
                if (!isLanIface) continue
                val addrs = iface.inetAddresses
                while (addrs.hasMoreElements()) {
                    val addr = addrs.nextElement()
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        val ip = addr.hostAddress ?: continue
                        val prefix = ip.substringBeforeLast('.')
                        for (last in 1..254) {
                            val probe = "$prefix.$last"
                            if (probe !in selfIps && !probe.startsWith("127.") && probe != "0.0.0.0") {
                                candidates.add(probe)
                            }
                        }
                    }
                }
            }
        }

        val endpoints = ArrayList<Pair<String, Int>>(candidates.size * portsToScan.size)
        for (ip in candidates) {
            if (ip in selfIps || ip.startsWith("127.") || ip == "0.0.0.0") continue
            for (p in portsToScan) {
                endpoints.add(ip to p)
            }
        }

        val discovered = java.util.Collections.synchronizedList(ArrayList<Map<String, Any>>())
        val latches = java.util.concurrent.CountDownLatch(endpoints.size)
        // 64-thread sweep with 180ms connect timeout covers full /24 (including .200-.254) reliably.
        val scanPool = Executors.newFixedThreadPool(64)
        try {
            for ((ip, p) in endpoints) {
                scanPool.execute {
                    val t0 = System.currentTimeMillis()
                    runCatching {
                        Socket().use { s ->
                            s.connect(InetSocketAddress(ip, p), 180)
                            val ms = (System.currentTimeMillis() - t0).coerceAtLeast(1L)
                            val baseUrl = "http://$ip:$p"
                            val meta = probeLanDshHost(baseUrl)
                            // Skip non-DSH web servers / routers listening on :3080/:3081 unless emulator host alias.
                            if (!meta.isDsh && !meta.hasGbridge && ip != "10.0.2.2") {
                                return@use
                            }
                            val isDesktopSurface = meta.surface == "desktop" || (p == 3081 && meta.hasGbridge)
                            val displayName = when {
                                ip == "10.0.2.2" && isDesktopSurface -> "宿主机 DSH 桌面端"
                                ip == "10.0.2.2" && meta.dshVersion != null -> "宿主机 DSH ${meta.dshVersion}"
                                ip == "10.0.2.2" -> "宿主机 (LAN)"
                                isDesktopSurface -> "DSH 桌面端 ($ip)"
                                meta.dshVersion != null -> "DSH ${meta.dshVersion} ($ip)"
                                else -> "局域网主机 $ip:$p"
                            }
                            val row = LinkedHashMap<String, Any>()
                            row["name"] = displayName
                            row["address"] = baseUrl
                            row["latencyMs"] = ms
                            row["isDsh"] = meta.isDsh
                            row["hasGbridge"] = meta.hasGbridge
                            row["requiresAuth"] = meta.requiresAuth
                            if (meta.surface != null) row["surface"] = meta.surface
                            if (meta.dshVersion != null) row["dshVersion"] = meta.dshVersion
                            discovered.add(row)
                        }
                    }
                    latches.countDown()
                }
            }
            runCatching { latches.await(8500, java.util.concurrent.TimeUnit.MILLISECONDS) }
        } finally {
            runCatching { scanPool.shutdownNow() }
        }
        val snapshot = synchronized(discovered) {
            discovered.filter { row ->
                val addr = row["address"]?.toString() ?: ""
                val host = runCatching { Uri.parse(addr).host?.lowercase() }.getOrNull() ?: ""
                host.isNotEmpty() && host !in selfIps && !host.startsWith("127.") && host != "0.0.0.0"
            }
        }
        return snapshot.sortedWith(
            compareByDescending<Map<String, Any>> { it["isDsh"] == true }
                .thenByDescending { it["hasGbridge"] == true }
                .thenBy { (it["latencyMs"] as? Long) ?: 999L }
        )
    }

    private data class LanDshProbeMeta(
        val isDsh: Boolean,
        val dshVersion: String?,
        val hasGbridge: Boolean,
        val requiresAuth: Boolean,
        val surface: String?,
    )

    private fun readBoundedText(stream: InputStream?, maxBytes: Int = 65536): String {
        if (stream == null) return ""
        return runCatching {
            stream.use { ins ->
                val out = ByteArrayOutputStream()
                val buf = ByteArray(4096)
                var total = 0
                while (total < maxBytes) {
                    val want = minOf(buf.size, maxBytes - total)
                    val n = ins.read(buf, 0, want)
                    if (n <= 0) break
                    out.write(buf, 0, n)
                    total += n
                }
                out.toString(Charsets.UTF_8.name())
            }
        }.getOrDefault("")
    }

    private fun probeLanDshHost(baseUrl: String): LanDshProbeMeta {
        var isDsh = false
        var dshVersion: String? = null
        var hasGbridge = false
        var requiresAuth = false
        var surface: String? = null

        // 1) Public unauthenticated stock DSH & Desktop LAN Bridge SSE endpoint `/plugins/events`
        runCatching {
            val conn = (URL("$baseUrl/plugins/events").openConnection(Proxy.NO_PROXY) as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 350
                readTimeout = 450
                setRequestProperty("Accept", "text/event-stream")
            }
            try {
                val code = conn.responseCode
                val ct = conn.contentType?.lowercase() ?: ""
                if (code == 200 && ct.contains("event-stream")) {
                    isDsh = true
                    val buf = ByteArray(4096)
                    val sb = StringBuilder()
                    var totalRead = 0
                    val ins = conn.inputStream
                    while (totalRead < 24576) {
                        val n = runCatching { ins.read(buf) }.getOrDefault(-1)
                        if (n <= 0) break
                        totalRead += n
                        sb.append(String(buf, 0, n, Charsets.UTF_8))
                        if (sb.contains("\n\n")) break
                    }
                    val text = sb.toString()
                    if (text.isNotEmpty()) {
                        val relMatch = Regex("\"release\"\\s*:\\s*\\{[^}]*\"version\"\\s*:\\s*\"([^\"]+)\"").find(text)
                            ?: Regex("\"dshVersion\"\\s*:\\s*\"([^\"]+)\"").find(text)
                            ?: Regex("\"version\"\\s*:\\s*\"([^\"]+)\"").find(text)
                        if (relMatch != null) dshVersion = relMatch.groupValues[1]
                        val surfMatch = Regex("\"surface\"\\s*:\\s*\"([^\"]+)\"").find(text)
                        if (surfMatch != null) surface = surfMatch.groupValues[1]
                        if (text.contains("\"hasGbridge\":true")) hasGbridge = true
                    }
                }
            } finally {
                conn.disconnect()
            }
        }

        // 2) Check `/gbridge/v1/capabilities` status
        runCatching {
            val conn = (URL("$baseUrl/gbridge/v1/capabilities").openConnection(Proxy.NO_PROXY) as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 300
                readTimeout = 350
                setRequestProperty("Accept", "application/json")
            }
            try {
                val code = conn.responseCode
                val ct = conn.contentType?.lowercase() ?: ""
                if (code == 200 && ct.contains("application/json")) {
                    isDsh = true
                    hasGbridge = true
                    val body = readBoundedText(conn.inputStream, 65536)
                    if (dshVersion == null) {
                        val m = Regex("\"dshVersion\"\\s*:\\s*\"([^\"]+)\"").find(body)
                        if (m != null) dshVersion = m.groupValues[1]
                    }
                } else if (code == 401 || code == 403) {
                    requiresAuth = true
                    val body = readBoundedText(conn.errorStream, 65536)
                    if (body.contains("gbridge/")) {
                        isDsh = true
                        hasGbridge = true
                    }
                }
            } finally {
                conn.disconnect()
            }
        }

        if (isDsh && !hasGbridge && !requiresAuth) {
            // Probe stock DSH `/api/session/list` (not `HEAD /` which returns 200 SPA shell!)
            // so `requiresAuth` accurately tells the UI whether a one-time token/cookie is needed.
            runCatching {
                val conn = (URL("$baseUrl/api/session/list").openConnection(Proxy.NO_PROXY) as HttpURLConnection).apply {
                    requestMethod = "POST"
                    doOutput = true
                    connectTimeout = 300
                    readTimeout = 350
                    setRequestProperty("Content-Type", "application/json")
                    setRequestProperty("Accept", "application/json")
                }
                try {
                    conn.outputStream.use { os ->
                        os.write("{\"type\":\"client-request\",\"rpcId\":\"scan\",\"method\":\"session/list\",\"payload\":{\"args\":{}}}".toByteArray(Charsets.UTF_8))
                    }
                    if (conn.responseCode == 401) {
                        requiresAuth = true
                    }
                } finally {
                    conn.disconnect()
                }
            }
        }

        return LanDshProbeMeta(
            isDsh = isDsh,
            dshVersion = dshVersion,
            hasGbridge = hasGbridge,
            requiresAuth = requiresAuth,
            surface = surface,
        )
    }

    companion object {
        const val METHOD_CHANNEL = "dev.grassbag/native"
        const val EVENT_CHANNEL = "dev.grassbag/native_events"
        private const val REQ_PICK_FILE = 4101
        private const val REQ_CAMERA = 4102
        private const val REQ_RUNTIME_PERM = 4103
        private const val REQ_CAMERA_PERM = 4104
    }
}
