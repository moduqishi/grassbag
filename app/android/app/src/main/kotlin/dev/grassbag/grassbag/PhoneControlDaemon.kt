package dev.grassbag.grassbag

import android.content.Context
import android.content.Intent
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.Uri
import android.os.Process
import android.provider.AlarmClock
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.OutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Private 0600 Unix Domain Socket HTTP daemon serving `dsh-gbridge/lib/phone-tools.js`.
 * Speaks exact JSON-over-HTTP wire protocol:
 *   POST /v1/tool      (Authorization: Bearer <token>)
 *   POST /v1/turn-end  (Authorization: Bearer <token>)
 */
class PhoneControlDaemon(
    private val context: Context,
    private val socketFile: File,
    val bearerToken: String,
    private val onEvent: (String, Map<String, Any?>) -> Unit
) {
    private val running = AtomicBoolean(false)
    private val pool = Executors.newCachedThreadPool()
    private var boundSocket: LocalSocket? = null
    private var serverSocket: LocalServerSocket? = null

    fun start(): Boolean {
        if (running.getAndSet(true)) return true
        return try {
            socketFile.parentFile?.mkdirs()
            if (socketFile.exists()) socketFile.delete()
            val bindSocket = LocalSocket()
            bindSocket.bind(LocalSocketAddress(socketFile.absolutePath, LocalSocketAddress.Namespace.FILESYSTEM))
            socketFile.setReadable(false, false)
            socketFile.setWritable(false, false)
            socketFile.setReadable(true, true)
            socketFile.setWritable(true, true)
            // Keep strong reference to bindSocket so GC cannot finalize/close its FD underneath serverSocket.
            boundSocket = bindSocket
            serverSocket = LocalServerSocket(bindSocket.fileDescriptor)
            pool.execute { acceptLoop() }
            true
        } catch (_: Throwable) {
            runCatching { boundSocket?.close() }
            boundSocket = null
            serverSocket = null
            running.set(false)
            false
        }
    }

    fun stop() {
        if (!running.getAndSet(false)) return
        try { serverSocket?.close() } catch (_: Throwable) {}
        serverSocket = null
        try { boundSocket?.close() } catch (_: Throwable) {}
        boundSocket = null
        try { if (socketFile.exists()) socketFile.delete() } catch (_: Throwable) {}
    }

    private fun acceptLoop() {
        while (running.get()) {
            try {
                val client = serverSocket?.accept() ?: break
                pool.execute { handleClient(client) }
            } catch (_: Throwable) {
                if (!running.get()) break
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
                    writeJson(sock.outputStream, 403, JSONObject().put("error", JSONObject().put("message", "forbidden_peer_uid")))
                    return
                }
                val req = readHttpRequest(BufferedInputStream(sock.inputStream)) ?: return
                val out = sock.outputStream
                val auth = req.headers["authorization"] ?: ""
                if (!constantTimeEquals(auth, "Bearer $bearerToken")) {
                    writeJson(out, 401, JSONObject().put("error", JSONObject().put("message", "unauthorized")))
                    return
                }
                val body = if (req.body.isBlank()) JSONObject() else JSONObject(req.body)
                when (req.path) {
                    "/v1/turn-end" -> {
                        val sid = body.optString("sessionId").ifBlank { null }
                        SafetyGate.endTurn(sid)
                        if (!SafetyGate.hasActiveTurn()) {
                            GrassBagAccessibilityService.current()?.hideEmergencyStopOverlay()
                        }
                        onEvent("phone_turn_end", mapOf(
                            "sessionId" to (sid ?: ""),
                            "reason" to body.optString("reason", "completed")
                        ))
                        writeJson(out, 200, JSONObject().put("ok", true))
                    }
                    "/v1/tool" -> {
                        val tool = body.optString("tool")
                        val args = body.optJSONObject("args") ?: JSONObject()
                        val caller = body.optJSONObject("caller")
                        val userApproved = body.optBoolean("userApproved", false)
                        val turnId = if (caller == null || caller.isNull("turnId")) null else caller.optString("turnId").ifBlank { null }
                        val sessionId = if (caller == null || caller.isNull("sessionId")) null else caller.optString("sessionId").ifBlank { null }
                        SafetyGate.beginTurn(turnId, sessionId)
                        val res = dispatchTool(tool, args, userApproved)
                        val blocked = res.optBoolean("blocked", false)
                        if (!blocked && res.optBoolean("ok", false)) {
                            GrassBagAccessibilityService.current()?.showEmergencyStopOverlay("GrassBag 操控中 · 点击急停")
                        }
                        val status = if (blocked) 403 else 200
                        writeJson(out, status, res)
                    }
                    else -> {
                        writeJson(out, 404, JSONObject().put("error", JSONObject().put("message", "not found")))
                    }
                }
            } catch (t: Throwable) {
                try {
                    writeJson(
                        sock.outputStream,
                        500,
                        JSONObject().put("error", JSONObject().put("message", t.message ?: "internal error"))
                    )
                } catch (_: Throwable) {}
            }
        }
    }

    private fun accessibilityMissingError(): JSONObject {
        val settingOn = GrassBagAccessibilityService.isSettingEnabled(context)
        return JSONObject()
            .put("ok", false)
            .put("reason", if (settingOn) "accessibility_service_unbound_please_retoggle" else "accessibility_service_not_enabled")
            .put(
                "hint",
                if (settingOn) {
                    "无障碍开关已开但系统服务未绑定，请在系统无障碍设置中关闭再重新开启「GrassBag 手机操控助手」，并在权限中心授予忽略电池优化。"
                } else {
                    "请前往 GrassBag「设置 → 权限管理」开启无障碍服务（Android 13+ 侧载应用需先在应用详情右上角允许受限设置）。"
                }
            )
    }

    private fun dispatchTool(tool: String, args: JSONObject, userApproved: Boolean = false): JSONObject {
        return when (tool) {
            "phone_screen" -> {
                val svc = GrassBagAccessibilityService.current() ?: return accessibilityMissingError()
                val maxNodes = args.optInt("maxNodes", 120).coerceIn(10, 300)
                svc.captureScreenTree(maxNodes)
            }
            "phone_tap" -> {
                val svc = GrassBagAccessibilityService.current() ?: return accessibilityMissingError()
                val x = args.optDouble("x", -1.0)
                val y = args.optDouble("y", -1.0)
                if (!x.isFinite() || !y.isFinite() || x < 0.0 || y < 0.0) {
                    JSONObject().put("ok", false).put("reason", "valid non-negative finite x and y coordinates are required")
                } else {
                    svc.performTap(x.toFloat(), y.toFloat(), userApproved)
                }
            }
            "phone_swipe" -> {
                val svc = GrassBagAccessibilityService.current() ?: return accessibilityMissingError()
                val x1 = args.optDouble("x1", -1.0)
                val y1 = args.optDouble("y1", -1.0)
                val x2 = args.optDouble("x2", -1.0)
                val y2 = args.optDouble("y2", -1.0)
                val dur = args.optLong("durationMs", 300L)
                if (!x1.isFinite() || !y1.isFinite() || !x2.isFinite() || !y2.isFinite() || x1 < 0 || y1 < 0 || x2 < 0 || y2 < 0) {
                    JSONObject().put("ok", false).put("reason", "valid non-negative finite swipe coordinates are required")
                } else {
                    svc.performSwipe(x1.toFloat(), y1.toFloat(), x2.toFloat(), y2.toFloat(), dur, userApproved)
                }
            }
            "phone_key" -> {
                val svc = GrassBagAccessibilityService.current() ?: return accessibilityMissingError()
                svc.performSystemAction(args.optString("action", "back"), userApproved)
            }
            "phone_type" -> {
                val svc = GrassBagAccessibilityService.current() ?: return accessibilityMissingError()
                svc.performType(args.optString("text", ""), userApproved)
            }
            "phone_open" -> {
                val pkg = args.optString("package", "").trim()
                val url = args.optString("url", "").trim()
                if (url.isNotEmpty() && pkg.isEmpty()) {
                    val parsed = runCatching { Uri.parse(url) }.getOrNull()
                    val scheme = parsed?.scheme?.lowercase()
                    if (scheme != "http" && scheme != "https") {
                        return JSONObject().put("ok", false).put("blocked", true).put("reason", "disallowed_url_scheme")
                    }
                }
                if (pkg.isNotEmpty() && SafetyGate.isPackageBlocked(pkg)) {
                    return JSONObject().put("ok", false).put("blocked", true).put("reason", "blocked_sensitive_package")
                }
                val intent = when {
                    pkg.isNotEmpty() -> context.packageManager.getLaunchIntentForPackage(pkg)
                    url.isNotEmpty() -> Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    else -> null
                } ?: return JSONObject().put("ok", false).put("reason", "target_not_found")
                val resolvedPkg = context.packageManager.resolveActivity(intent, 0)?.activityInfo?.packageName
                if (resolvedPkg.isNullOrBlank()) {
                    return JSONObject().put("ok", false).put("blocked", true).put("reason", "unresolved_target_activity_fail_closed")
                }
                val resolvedDecision = SafetyGate.evaluateToolCall("phone_open", resolvedPkg, userApproved = userApproved)
                if (!resolvedDecision.allowed) {
                    return JSONObject().put("ok", false).put("blocked", true).put("reason", resolvedDecision.reason)
                }
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                val launchCtx: Context = GrassBagAccessibilityService.current() ?: context
                val launchErr = runCatching { launchCtx.startActivity(intent) }.exceptionOrNull()
                if (launchErr != null) {
                    JSONObject().put("ok", false).put("reason", "activity_launch_failed:${launchErr.message ?: launchErr.javaClass.simpleName}")
                } else {
                    JSONObject().put("ok", true).put("opened", pkg.ifEmpty { url }).put("resolvedPackage", resolvedPkg)
                }
            }
            "phone_intent" -> {
                val kind = args.optString("kind", "")
                val decision = SafetyGate.evaluateToolCall("phone_intent", kind, userApproved = userApproved)
                if (!decision.allowed) {
                    return JSONObject().put("ok", false).put("blocked", true).put("reason", decision.reason)
                }
                val launchCtx: Context = GrassBagAccessibilityService.current() ?: context
                runCatching {
                    when (kind) {
                        "alarm" -> {
                            val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
                                putExtra(AlarmClock.EXTRA_HOUR, args.optInt("hour", 8))
                                putExtra(AlarmClock.EXTRA_MINUTES, args.optInt("minute", 0))
                                putExtra(AlarmClock.EXTRA_MESSAGE, args.optString("label", "GrassBag 闹钟"))
                                putExtra(AlarmClock.EXTRA_SKIP_UI, false)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            launchCtx.startActivity(intent)
                            JSONObject().put("ok", true).put("kind", "alarm")
                        }
                        "timer" -> {
                            val intent = Intent(AlarmClock.ACTION_SET_TIMER).apply {
                                putExtra(AlarmClock.EXTRA_LENGTH, args.optInt("seconds", 60))
                                putExtra(AlarmClock.EXTRA_MESSAGE, args.optString("label", "GrassBag 计时器"))
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            launchCtx.startActivity(intent)
                            JSONObject().put("ok", true).put("kind", "timer")
                        }
                        "share" -> {
                            val text = args.optString("text", args.optString("label", ""))
                            val intent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, text)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            launchCtx.startActivity(Intent.createChooser(intent, "分享").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            JSONObject().put("ok", true).put("kind", "share")
                        }
                        "navigation" -> {
                            val query = args.optString("query", args.optString("destination", "")).trim()
                            if (query.isEmpty()) {
                                JSONObject().put("ok", false).put("reason", "destination_required")
                            } else {
                                val uri = Uri.parse("geo:0,0?q=${Uri.encode(query)}")
                                val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                launchCtx.startActivity(intent)
                                JSONObject().put("ok", true).put("kind", "navigation").put("query", query)
                            }
                        }
                        "calendar" -> {
                            val intent = Intent(Intent.ACTION_INSERT).apply {
                                data = Uri.parse("content://com.android.calendar/events")
                                putExtra("title", args.optString("title", args.optString("label", "GrassBag 日程")))
                                putExtra("description", args.optString("description", ""))
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            launchCtx.startActivity(intent)
                            JSONObject().put("ok", true).put("kind", "calendar")
                        }
                        else -> JSONObject().put("ok", false).put("reason", "unsupported_intent_kind")
                    }
                }.getOrElse { err ->
                    JSONObject().put("ok", false).put("reason", "intent_launch_failed:${err.message ?: err.javaClass.simpleName}")
                }
            }
            "phone_handoff" -> {
                val message = args.optString("message", "请接管完成当前敏感步骤")
                onEvent("phone_handoff", mapOf("message" to message))
                JSONObject().put("ok", true).put("handedOff", true).put("message", message)
            }
            "phone_shell" -> {
                JSONObject().put("ok", false).put("reason", "unsupported_shizuku_not_integrated")
            }
            else -> JSONObject().put("ok", false).put("reason", "unknown_tool:$tool")
        }
    }

    companion object {
        fun constantTimeEquals(a: String, b: String): Boolean =
            MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))

        data class SimpleHttpRequest(
            val method: String,
            val path: String,
            val headers: Map<String, String>,
            val body: String
        )

        fun readHttpRequest(input: BufferedInputStream): SimpleHttpRequest? {
            val headerBytes = ArrayList<Byte>(512)
            var matched = 0
            while (true) {
                val b = input.read()
                if (b == -1) return null
                headerBytes.add(b.toByte())
                matched = when {
                    (matched == 0 || matched == 2) && b == '\r'.code -> matched + 1
                    (matched == 1 || matched == 3) && b == '\n'.code -> matched + 1
                    b == '\r'.code -> 1
                    else -> 0
                }
                if (matched == 4) break
                if (headerBytes.size > 32768) return null
            }
            val headerStr = String(headerBytes.toByteArray(), Charsets.UTF_8)
            val lines = headerStr.split("\r\n")
            val first = lines.firstOrNull()?.split(" ") ?: return null
            if (first.size < 2) return null
            val headers = HashMap<String, String>()
            for (i in 1 until lines.size) {
                val idx = lines[i].indexOf(':')
                if (idx > 0) {
                    headers[lines[i].substring(0, idx).trim().lowercase()] =
                        lines[i].substring(idx + 1).trim()
                }
            }
            val rawLen = headers["content-length"]?.toIntOrNull()
            if (rawLen != null && rawLen > 2 * 1024 * 1024) {
                throw IllegalArgumentException("payload_too_large")
            }
            val bodyStr = if (headers["transfer-encoding"]?.contains("chunked", ignoreCase = true) == true) {
                val out = java.io.ByteArrayOutputStream()
                while (true) {
                    val lineBytes = ArrayList<Byte>(16)
                    while (true) {
                        val ch = input.read()
                        if (ch == -1) break
                        if (ch == '\n'.code) break
                        if (ch != '\r'.code) lineBytes.add(ch.toByte())
                    }
                    val sizeHex = String(lineBytes.toByteArray(), Charsets.US_ASCII).substringBefore(';').trim()
                    val chunkSize = sizeHex.toIntOrNull(16) ?: 0
                    if (chunkSize <= 0) break
                    if (out.size() + chunkSize > 2 * 1024 * 1024) throw IllegalArgumentException("payload_too_large")
                    val buf = ByteArray(chunkSize)
                    var got = 0
                    while (got < chunkSize) {
                        val n = input.read(buf, got, chunkSize - got)
                        if (n <= 0) break
                        got += n
                    }
                    out.write(buf, 0, got)
                    // Consume trailing CRLF after chunk
                    input.read()
                    input.read()
                }
                String(out.toByteArray(), Charsets.UTF_8)
            } else {
                val contentLength = (rawLen ?: 0).coerceAtLeast(0)
                val bodyBytes = ByteArray(contentLength)
                var read = 0
                while (read < contentLength) {
                    val n = input.read(bodyBytes, read, contentLength - read)
                    if (n <= 0) break
                    read += n
                }
                String(bodyBytes, 0, read, Charsets.UTF_8)
            }
            return SimpleHttpRequest(
                method = first[0],
                path = first[1].substringBefore('?'),
                headers = headers,
                body = bodyStr
            )
        }

        fun writeJson(out: OutputStream, status: Int, json: JSONObject) {
            val payload = json.toString().toByteArray(Charsets.UTF_8)
            val reason = when (status) {
                200 -> "OK"
                401 -> "Unauthorized"
                403 -> "Forbidden"
                404 -> "Not Found"
                else -> "Error"
            }
            val head = "HTTP/1.1 $status $reason\r\n" +
                "Content-Type: application/json; charset=utf-8\r\n" +
                "Content-Length: ${payload.size}\r\n" +
                "Connection: close\r\n\r\n"
            out.write(head.toByteArray(Charsets.US_ASCII))
            out.write(payload)
            out.flush()
        }
    }
}
