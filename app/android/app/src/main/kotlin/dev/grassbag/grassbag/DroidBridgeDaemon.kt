package dev.grassbag.grassbag

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.speech.tts.TextToSpeech
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Private 0600 UDS daemon powering `droid-clip`, `droid-notify`, `droid-share`,
 * `droid-vibrate`, `droid-tts`, and `droid-info` from inside the Linux container.
 */
class DroidBridgeDaemon(
    private val context: Context,
    private val socketFile: File,
    val bearerToken: String
) {
    private val running = AtomicBoolean(false)
    private val lifecycleLock = Any()
    @Volatile
    private var pool: java.util.concurrent.ExecutorService = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var boundSocket: LocalSocket? = null
    @Volatile
    private var serverSocket: LocalServerSocket? = null
    private var tts: TextToSpeech? = null
    private var ttsReady: Boolean = false
    private var pendingTtsText: String? = null

    fun start(): Boolean = synchronized(lifecycleLock) {
        if (running.get()) return true
        return try {
            val exec = if (pool.isShutdown || pool.isTerminated) {
                Executors.newCachedThreadPool().also { pool = it }
            } else {
                pool
            }
            socketFile.parentFile?.mkdirs()
            if (socketFile.exists()) socketFile.delete()
            val bindSocket = LocalSocket()
            bindSocket.bind(LocalSocketAddress(socketFile.absolutePath, LocalSocketAddress.Namespace.FILESYSTEM))
            socketFile.setReadable(false, false)
            socketFile.setWritable(false, false)
            socketFile.setReadable(true, true)
            socketFile.setWritable(true, true)
            // Keep strong reference so GC cannot close bindSocket FD underneath serverSocket.
            val ss = LocalServerSocket(bindSocket.fileDescriptor)
            boundSocket = bindSocket
            serverSocket = ss
            running.set(true)
            exec.execute { acceptLoop(ss, exec) }
            true
        } catch (_: Throwable) {
            running.set(false)
            runCatching { serverSocket?.close() }
            runCatching { boundSocket?.close() }
            boundSocket = null
            serverSocket = null
            false
        }
    }

    fun stop() = synchronized(lifecycleLock) {
        if (!running.getAndSet(false)) return
        try { serverSocket?.close() } catch (_: Throwable) {}
        serverSocket = null
        try { boundSocket?.close() } catch (_: Throwable) {}
        boundSocket = null
        runCatching { pool.shutdownNow() }
        try {
            mainHandler.post {
                runCatching { tts?.shutdown() }
                tts = null
                ttsReady = false
                pendingTtsText = null
            }
        } catch (_: Throwable) {}
        try { if (socketFile.exists()) socketFile.delete() } catch (_: Throwable) {}
    }

    private fun acceptLoop(ss: LocalServerSocket, exec: java.util.concurrent.ExecutorService) {
        while (running.get() && serverSocket === ss) {
            try {
                val client = ss.accept() ?: break
                try {
                    exec.execute { handleClient(client) }
                } catch (_: Throwable) {
                    runCatching { client.close() }
                    if (!running.get() || exec.isShutdown) break
                }
            } catch (_: Throwable) {
                if (!running.get() || serverSocket !== ss) break
                runCatching { Thread.sleep(150) }
            }
        }
    }

    private fun handleClient(client: LocalSocket) {
        client.use { sock ->
            try {
                sock.soTimeout = 15_000
                val peerUid = runCatching { sock.peerCredentials.uid }.getOrDefault(-1)
                if (peerUid != Process.myUid()) {
                    PhoneControlDaemon.writeJson(sock.outputStream, 403, JSONObject().put("error", JSONObject().put("message", "forbidden_peer_uid")))
                    return
                }
                val req = PhoneControlDaemon.readHttpRequest(BufferedInputStream(sock.inputStream)) ?: return
                val out = sock.outputStream
                if (!PhoneControlDaemon.constantTimeEquals(req.headers["authorization"] ?: "", "Bearer $bearerToken")) {
                    PhoneControlDaemon.writeJson(out, 401, JSONObject().put("error", JSONObject().put("message", "unauthorized")))
                    return
                }
                val body = try {
                    if (req.body.isBlank()) JSONObject() else JSONObject(req.body)
                } catch (_: org.json.JSONException) {
                    PhoneControlDaemon.writeJson(out, 400, JSONObject().put("error", JSONObject().put("message", "invalid_json")))
                    return
                }
                val action = body.optString("action", "")
                val argsArr = body.optJSONArray("args")
                val args = List(argsArr?.length() ?: 0) { argsArr!!.optString(it) }
                val stdin = body.optString("stdin", "")
                val result = executeAction(action, args, stdin)
                PhoneControlDaemon.writeJson(out, 200, result)
            } catch (t: Throwable) {
                try {
                    PhoneControlDaemon.writeJson(
                        sock.outputStream,
                        500,
                        JSONObject().put("error", JSONObject().put("message", t.message ?: "error"))
                    )
                } catch (_: Throwable) {}
            }
        }
    }

    private fun executeAction(action: String, args: List<String>, stdin: String): JSONObject {
        return when (action) {
            "clip" -> {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val rawText = if (args.isNotEmpty()) args.joinToString(" ") else stdin
                if (rawText.isNotEmpty()) {
                    val textToSet = if (rawText.length > 262_144) rawText.substring(0, 262_144) else rawText
                    val latch = java.util.concurrent.CountDownLatch(1)
                    val writeErr = java.util.concurrent.atomic.AtomicReference<String?>(null)
                    mainHandler.post {
                        try {
                            cm.setPrimaryClip(ClipData.newPlainText("GrassBag", textToSet))
                        } catch (t: Throwable) {
                            writeErr.set(t.message ?: t.javaClass.simpleName)
                        } finally {
                            latch.countDown()
                        }
                    }
                    val completed = runCatching { latch.await(1500, java.util.concurrent.TimeUnit.MILLISECONDS) }.getOrDefault(false)
                    val errMsg = writeErr.get()
                    if (!completed) {
                        JSONObject().put("ok", false).put("error", "clipboard_write_timeout")
                    } else if (errMsg != null) {
                        JSONObject().put("ok", false).put("error", errMsg)
                    } else {
                        JSONObject().put("ok", true).put("output", "copied ${textToSet.length} chars")
                    }
                } else {
                    val clipTextRef = java.util.concurrent.atomic.AtomicReference("")
                    val latch = java.util.concurrent.CountDownLatch(1)
                    mainHandler.post {
                        try {
                            val clip = cm.primaryClip
                            val txt = if (clip != null && clip.itemCount > 0) {
                                clip.getItemAt(0)?.coerceToText(context)?.toString() ?: ""
                            } else {
                                ""
                            }
                            clipTextRef.set(txt)
                        } catch (_: Throwable) {
                            clipTextRef.set("")
                        } finally {
                            latch.countDown()
                        }
                    }
                    val completed = runCatching { latch.await(1500, java.util.concurrent.TimeUnit.MILLISECONDS) }.getOrDefault(false)
                    if (!completed) {
                        JSONObject().put("ok", false).put("error", "clipboard_read_timeout")
                    } else {
                        JSONObject().put("ok", true).put("output", clipTextRef.get())
                    }
                }
            }
            "notify" -> {
                val title = args.getOrNull(0) ?: "GrassBag"
                val message = args.drop(1).joinToString(" ").ifEmpty { stdin.ifEmpty { "任务通知" } }
                GrassBagEngineService.postAlertNotification(context, title, message)
                JSONObject().put("ok", true).put("output", "notified")
            }
            "share" -> {
                val text = args.joinToString(" ").ifEmpty { stdin }
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, text)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                val launchCtx: Context = GrassBagAccessibilityService.current() ?: context
                val res = runCatching {
                    launchCtx.startActivity(Intent.createChooser(intent, "分享").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                if (res.isSuccess) {
                    JSONObject().put("ok", true).put("output", "shared")
                } else {
                    JSONObject().put("ok", false).put("error", res.exceptionOrNull()?.message ?: "share_failed")
                }
            }
            "vibrate" -> {
                val ms = args.firstOrNull()?.toLongOrNull()?.coerceIn(20L, 1500L) ?: 80L
                val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
                } else {
                    @Suppress("DEPRECATION")
                    context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(ms)
                }
                JSONObject().put("ok", true).put("output", "vibrated ${ms}ms")
            }
            "tts" -> {
                val text = args.joinToString(" ").ifEmpty { stdin }
                if (text.isNotEmpty()) {
                    mainHandler.post {
                        if (tts == null) {
                            pendingTtsText = text
                            ttsReady = false
                            var createdTts: TextToSpeech? = null
                            createdTts = TextToSpeech(context) { status ->
                                mainHandler.post {
                                    val instance = createdTts
                                    if (instance == null || tts !== instance || !running.get()) {
                                        runCatching { instance?.shutdown() }
                                        if (tts === instance) {
                                            tts = null
                                            ttsReady = false
                                            pendingTtsText = null
                                        }
                                        return@post
                                    }
                                    if (status == TextToSpeech.SUCCESS) {
                                        ttsReady = true
                                        instance.language = Locale.getDefault()
                                        val queued = pendingTtsText
                                        pendingTtsText = null
                                        if (!queued.isNullOrEmpty()) {
                                            instance.speak(queued, TextToSpeech.QUEUE_FLUSH, null, "grassbag-tts")
                                        }
                                    } else {
                                        runCatching { instance.shutdown() }
                                        tts = null
                                        ttsReady = false
                                        pendingTtsText = null
                                    }
                                }
                            }
                            tts = createdTts
                        } else if (ttsReady) {
                            tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "grassbag-tts")
                        } else {
                            pendingTtsText = text
                        }
                    }
                }
                JSONObject().put("ok", true).put("output", "speaking")
            }
            "info" -> {
                val bm = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                val battery = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                val info = JSONObject()
                    .put("manufacturer", Build.MANUFACTURER)
                    .put("model", Build.MODEL)
                    .put("sdkInt", Build.VERSION.SDK_INT)
                    .put("abi", Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown")
                    .put("batteryPct", battery)
                JSONObject().put("ok", true).put("output", info.toString(2))
            }
            else -> JSONObject().put("ok", false).put("error", JSONObject().put("message", "unknown droid action: $action"))
        }
    }
}
