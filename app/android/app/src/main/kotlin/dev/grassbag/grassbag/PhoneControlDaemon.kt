package dev.grassbag.grassbag

import android.content.Context
import android.content.Intent
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.Uri
import android.os.Process
import android.provider.AlarmClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.OutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Private 0600 Unix Domain Socket HTTP daemon serving `dsh-gbridge/lib/phone-tools.js`.
 *
 * Handles native SafetyGate enforcement, out-of-app Liquid Glass confirmation/handoff cards
 * via [PhoneOverlayController] (`TYPE_ACCESSIBILITY_OVERLAY`), live Dynamic Island HUD updates,
 * pause/resume waiting, and rich phone tools (`phone_screen`, `phone_screenshot`, `phone_apps`,
 * `phone_open`, `phone_tap`, `phone_long_press`, `phone_swipe`, `phone_type`, `phone_key`,
 * `phone_intent`, `phone_wait`, `phone_handoff`).
 */
class PhoneControlDaemon(
    private val context: Context,
    private val socketFile: File,
    val bearerToken: String,
    private val onEvent: (String, Map<String, Any?>) -> Unit
) {
    private data class CachedApp(
        val pkg: String,
        val label: String,
        val labelLower: String,
        val pkgLower: String
    )

    private val running = AtomicBoolean(false)
    private val lifecycleLock = Any()
    @Volatile
    private var pool: java.util.concurrent.ExecutorService = Executors.newCachedThreadPool()
    @Volatile
    private var boundSocket: LocalSocket? = null
    @Volatile
    private var serverSocket: LocalServerSocket? = null
    private val appsCacheLock = Any()
    @Volatile
    private var cachedApps: List<CachedApp>? = null
    @Volatile
    private var cachedAppsAtMs: Long = 0L

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
                // Generous timeout covering 35s confirmation cards & 180s handoff cards.
                sock.soTimeout = 195_000
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
                val body = try {
                    if (req.body.isBlank()) JSONObject() else JSONObject(req.body)
                } catch (_: org.json.JSONException) {
                    writeJson(out, 400, JSONObject().put("error", JSONObject().put("message", "invalid_json")))
                    return
                }
                when (req.path) {
                    "/v1/turn-end" -> {
                        val sid = body.optString("sessionId").ifBlank { null }
                        val tid = body.optString("turnId").ifBlank { null }
                        val reason = body.optString("reason", "completed").ifBlank { "completed" }
                        val summary = body.optString("summary", "").trim()
                        val endedPhoneTurn = SafetyGate.endTurn(sid, tid)
                        val overlay = PhoneOverlayController.getInstance(context)
                        val shouldFinalize = endedPhoneTurn || overlay.isHudSessionActive()
                        val isStopped = SafetyGate.isNonSuccessTurnEndReason(reason)
                        val shouldAutoReturn = shouldFinalize && !isStopped && SafetyGate.isAutoReturnEnabled()
                        val stepsCount = overlay.currentStepCount()
                        val lastApp = overlay.currentAppLabel()
                        if (shouldFinalize && !SafetyGate.hasActiveTurn()) {
                            overlay.showCompletionAndReturn(
                                summary = summary,
                                reason = reason,
                                autoReturn = shouldAutoReturn
                            )
                            if (GrassBagEngineService.isServiceActive()) {
                                GrassBagEngineService.startOrUpdate(
                                    ctx = context,
                                    heading = "GrassBag 本机引擎运行中",
                                    detail = "手机操控已完成 · 后台待命保活",
                                    releaseWakeLock = true
                                )
                            }
                        }
                        onEvent("phone_turn_end", mapOf(
                            "sessionId" to (sid ?: ""),
                            "reason" to reason,
                            "summary" to summary,
                            "autoReturn" to shouldAutoReturn,
                            "stepsCount" to stepsCount,
                            "appLabel" to lastApp
                        ))
                        writeJson(out, 200, JSONObject().put("ok", true).put("autoReturn", shouldAutoReturn))
                    }
                    "/v1/tool" -> {
                        val tool = body.optString("tool")
                        val args = body.optJSONObject("args") ?: JSONObject()
                        val caller = body.optJSONObject("caller")
                        // Never accept client-supplied `userApproved` or self-elevating `permissionPreset`
                        // (`danger-full-access` / `full-access`) from UDS payloads; elevation ONLY follows
                        // Flutter's live synced SafetyGate chat permission preset.
                        val userApproved = false
                        val syncedPreset = SafetyGate.getSyncedChatPermissionPreset()
                        val requestedPreset = body.optString("permissionPreset", "").ifBlank { null }
                        val permissionPreset = if (
                            requestedPreset == "danger-full-access" || requestedPreset == "full-access"
                        ) {
                            syncedPreset
                        } else {
                            requestedPreset ?: syncedPreset
                        }
                        val turnId = if (caller == null || caller.isNull("turnId")) null else caller.optString("turnId").ifBlank { null }
                        val sessionId = if (caller == null || caller.isNull("sessionId")) null else caller.optString("sessionId").ifBlank { null }

                        // If user tapped 暂停 on the floating HUD, block on condition monitor (up to 3 min) until 继续 or 急停!
                        val wasPaused = SafetyGate.isPaused()
                        val hadActiveTurnBeforePause = wasPaused && SafetyGate.isTurnActiveForSession(sessionId, turnId)
                        if (wasPaused) {
                            val pauseDeadlineMs = System.currentTimeMillis() + 180_000L
                            SafetyGate.waitWhilePaused(
                                deadlineMs = pauseDeadlineMs,
                                sessionId = sessionId,
                                turnId = turnId,
                                hadActiveTurn = hadActiveTurnBeforePause
                            )
                        }
                        if (SafetyGate.isEmergencyStopped()) {
                            writeJson(
                                out,
                                403,
                                JSONObject()
                                    .put("ok", false)
                                    .put("blocked", true)
                                    .put("reason", "emergency_stop_active")
                                    .put("hint", "用户已触发急停，请立即停止后续手机操控。")
                            )
                            return
                        }
                        if (SafetyGate.isPaused()) {
                            writeJson(
                                out,
                                403,
                                JSONObject()
                                    .put("ok", false)
                                    .put("blocked", true)
                                    .put("reason", "pause_timeout")
                                    .put("hint", "操控处于暂停状态且等待已超时，请先点击继续后再重试。")
                            )
                            return
                        }
                        if (wasPaused && hadActiveTurnBeforePause && !SafetyGate.isTurnActiveForSession(sessionId, turnId)) {
                            writeJson(
                                out,
                                403,
                                JSONObject()
                                    .put("ok", false)
                                    .put("blocked", true)
                                    .put("reason", "turn_ended_while_paused")
                                    .put("hint", "暂停期间本轮对话已结束，已取消滞留操作。")
                            )
                            return
                        }

                        // Keep CPU WakeLock + low-latency WifiLock alive throughout phone control
                        // (including when GrassBag moves to background over target apps or waits for confirm cards).
                        GrassBagEngineService.startOrUpdate(
                            ctx = context,
                            heading = "GrassBag 正在操控手机",
                            detail = "执行中并保持后台连接稳定 · 可在悬浮岛随时暂停或急停",
                            wakeLockMs = 10 * 60 * 1000L,
                            holdWifiLock = true
                        )

                        val res = dispatchTool(
                            tool = tool,
                            args = args,
                            sessionId = sessionId,
                            turnId = turnId,
                            permissionPreset = permissionPreset,
                            userApproved = userApproved
                        )
                        val blocked = res.optBoolean("blocked", false)
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
                    "无障碍开关已开但系统服务未绑定，请在系统无障碍设置中关闭再重新开启「GrassBag 手机操控助手」，并在权限管理授予忽略电池优化。"
                } else {
                    "请前往 GrassBag「设置 → 权限管理」开启无障碍服务（Android 13+ 侧载应用需先在应用详情右上角允许受限设置）。"
                }
            )
    }

    /**
     * Evaluates SafetyGate and, when confirmation is needed, blocks directly on our native
     * out-of-app Liquid Glass confirmation card (`TYPE_ACCESSIBILITY_OVERLAY`) so it works
     * cleanly over ANY app in BOTH `工作区内修改` and `完全权限` modes!
     */
    private fun gateAndConfirm(
        tool: String,
        targetPackage: String?,
        targetAppLabel: String?,
        actionSummary: String,
        hudActionLabel: String,
        sessionId: String?,
        turnId: String?,
        permissionPreset: String?,
        targetLabel: String? = null,
        isSensitiveTarget: Boolean = false,
        userApproved: Boolean = false,
        outShowedPrompt: AtomicBoolean? = null
    ): JSONObject? {
        val verdict = SafetyGate.evaluateAction(
            tool = tool,
            targetPackage = targetPackage,
            sessionId = sessionId,
            turnId = turnId,
            permissionPreset = permissionPreset,
            targetLabel = targetLabel,
            isSensitiveTarget = isSensitiveTarget,
            userApproved = userApproved
        )
        val overlay = PhoneOverlayController.getInstance(context)
        when (verdict) {
            is SafetyGate.ActionVerdict.Deny -> {
                return JSONObject()
                    .put("ok", false)
                    .put("blocked", true)
                    .put("reason", verdict.reason)
                    .apply { if (!verdict.hint.isNullOrBlank()) put("hint", verdict.hint) }
            }
            is SafetyGate.ActionVerdict.Allow -> {
                SafetyGate.beginTurn(turnId, sessionId)
                val resolvedApp = targetAppLabel ?: targetPackage
                overlay.showOrUpdateHud(
                    actionLabel = hudActionLabel,
                    appLabel = resolvedApp,
                    toolName = tool
                )
                emitStepTelemetry(tool, hudActionLabel, resolvedApp, overlay)
                return null
            }
            is SafetyGate.ActionVerdict.NeedConfirm -> {
                outShowedPrompt?.set(true)
                SafetyGate.beginTurn(turnId, sessionId)
                val resolvedApp = targetAppLabel ?: targetPackage
                val decision = overlay.confirm(
                    title = "GrassBag 请求操控手机",
                    actionSummary = actionSummary,
                    appLabel = resolvedApp,
                    riskBadge = verdict.riskBadge,
                    allowTurnOption = verdict.allowTurnOption,
                    timeoutMs = 35_000L
                )
                return when (decision) {
                    PhoneOverlayController.ConfirmDecision.ALLOW_ONCE -> {
                        SafetyGate.recordAudit(tool, targetPackage ?: "screen", true, "allowed:native_overlay_once")
                        overlay.showOrUpdateHud(
                            actionLabel = hudActionLabel,
                            appLabel = resolvedApp,
                            toolName = tool
                        )
                        emitStepTelemetry(tool, hudActionLabel, resolvedApp, overlay)
                        null
                    }
                    PhoneOverlayController.ConfirmDecision.ALLOW_TURN -> {
                        SafetyGate.grantTurnAllow(sessionId, turnId)
                        overlay.showOrUpdateHud(
                            actionLabel = hudActionLabel,
                            appLabel = resolvedApp,
                            toolName = tool
                        )
                        emitStepTelemetry(tool, hudActionLabel, resolvedApp, overlay)
                        null
                    }
                    PhoneOverlayController.ConfirmDecision.DENY -> {
                        SafetyGate.recordAudit(tool, targetPackage ?: "screen", false, "user_cancelled_step")
                        JSONObject()
                            .put("ok", false)
                            .put("blocked", true)
                            .put("reason", "user_cancelled")
                            .put("hint", "用户取消了这一步操作，请尊重用户决定，不要强行重试。")
                    }
                    PhoneOverlayController.ConfirmDecision.STOP -> {
                        JSONObject()
                            .put("ok", false)
                            .put("blocked", true)
                            .put("reason", "emergency_stop_active")
                            .put("hint", "用户在悬浮卡片选择了急停任务，请立即停止后续手机操控。")
                    }
                    PhoneOverlayController.ConfirmDecision.TIMEOUT -> {
                        SafetyGate.recordAudit(tool, targetPackage ?: "screen", false, "confirm_timeout")
                        JSONObject()
                            .put("ok", false)
                            .put("blocked", true)
                            .put("reason", "confirm_timeout")
                            .put("hint", "确认弹窗已超时未响应，操作未执行。")
                    }
                    PhoneOverlayController.ConfirmDecision.UNAVAILABLE -> {
                        // Overlay unavailable (neither Accessibility nor SYSTEM_ALERT_WINDOW is active):
                        // give crystal-clear guidance instead of silent deadlock.
                        JSONObject()
                            .put("ok", false)
                            .put("blocked", true)
                            .put("reason", "overlay_unavailable")
                            .put("hint", "无法在当前界面显示悬浮确认卡片。请前往「设置 → 权限管理」开启无障碍服务（或悬浮窗权限），或在对话左下角将权限切为「完全权限」。")
                    }
                }
            }
        }
    }

    private fun emitStepTelemetry(
        tool: String,
        actionLabel: String,
        appLabel: String?,
        overlay: PhoneOverlayController
    ) {
        onEvent(
            "phone_step_event",
            mapOf(
                "active" to true,
                "tool" to tool,
                "action" to actionLabel,
                "appLabel" to (appLabel ?: ""),
                "stepCount" to overlay.currentStepCount(),
                "paused" to SafetyGate.isPaused(),
                "ts" to System.currentTimeMillis()
            )
        )
    }

    private fun getLaunchableAppsCached(forceRefresh: Boolean = false): List<CachedApp> {
        val now = System.currentTimeMillis()
        val existing = cachedApps
        if (!forceRefresh && existing != null && (now - cachedAppsAtMs) < 60_000L) {
            return existing
        }
        synchronized(appsCacheLock) {
            val recheck = cachedApps
            if (!forceRefresh && recheck != null && (System.currentTimeMillis() - cachedAppsAtMs) < 60_000L) {
                return recheck
            }
            val pm = context.packageManager
            val mainIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val activities = runCatching { pm.queryIntentActivities(mainIntent, 0) }.getOrDefault(emptyList())
            val seen = HashSet<String>(activities.size)
            val list = ArrayList<CachedApp>(activities.size)
            for (ri in activities) {
                val pkg = ri.activityInfo?.packageName ?: continue
                if (!seen.add(pkg)) continue
                val label = runCatching { ri.loadLabel(pm)?.toString() }.getOrNull()?.trim().orEmpty().ifBlank { pkg }
                list.add(CachedApp(pkg, label, label.lowercase(), pkg.lowercase()))
            }
            cachedApps = list
            cachedAppsAtMs = System.currentTimeMillis()
            return list
        }
    }

    private fun resolveAppByNameOrPackage(rawPkg: String, rawAppName: String): Pair<String, String>? {
        val pm = context.packageManager
        if (rawPkg.isNotBlank()) {
            val intent = pm.getLaunchIntentForPackage(rawPkg)
            if (intent != null) {
                val label = runCatching {
                    pm.getApplicationLabel(pm.getApplicationInfo(rawPkg, 0)).toString()
                }.getOrDefault(rawPkg)
                return rawPkg to label
            }
        }
        val query = rawAppName.ifBlank { rawPkg }.trim().lowercase()
        if (query.isEmpty()) return null
        val apps = getLaunchableAppsCached(forceRefresh = false)
        var exact: Pair<String, String>? = null
        var partial: Pair<String, String>? = null
        for (app in apps) {
            if (app.labelLower == query || app.pkgLower == query) {
                exact = app.pkg to app.label
                break
            }
            if (partial == null && (app.labelLower.contains(query) || (query.contains(app.labelLower) && app.labelLower.length >= 2) || app.pkgLower.contains(query))) {
                partial = app.pkg to app.label
            }
        }
        return exact ?: partial
    }

    private fun listLaunchableApps(query: String, forceRefresh: Boolean = false): JSONObject {
        val apps = getLaunchableAppsCached(forceRefresh = forceRefresh)
        val q = query.trim().lowercase()
        val arr = JSONArray()
        for (app in apps) {
            if (app.pkg == "dev.grassbag.grassbag") continue
            if (q.isNotEmpty() && !app.labelLower.contains(q) && !app.pkgLower.contains(q)) {
                continue
            }
            arr.put(
                JSONObject()
                    .put("name", app.label)
                    .put("package", app.pkg)
                    .put("blocked", SafetyGate.isPackageBlocked(app.pkg))
            )
            if (arr.length() >= 80) break
        }
        return JSONObject().put("ok", true).put("count", arr.length()).put("apps", arr)
    }

    private fun dispatchTool(
        tool: String,
        args: JSONObject,
        sessionId: String?,
        turnId: String?,
        permissionPreset: String?,
        userApproved: Boolean
    ): JSONObject {
        val overlay = PhoneOverlayController.getInstance(context)
        return when (tool) {
            "phone_apps" -> {
                val query = args.optString("query", "")
                val refresh = args.optBoolean("refresh", false)
                val denied = gateAndConfirm(
                    tool = tool,
                    targetPackage = "launcher",
                    targetAppLabel = "应用列表",
                    actionSummary = "查询已安装应用列表",
                    hudActionLabel = "查询应用列表",
                    sessionId = sessionId,
                    turnId = turnId,
                    permissionPreset = permissionPreset,
                    userApproved = userApproved
                )
                if (denied != null) return denied
                listLaunchableApps(query, forceRefresh = refresh)
            }
            "phone_wait" -> {
                val ms = args.optLong("ms", 1000L).coerceIn(100L, 10_000L)
                SafetyGate.beginTurn(turnId, sessionId)
                overlay.showOrUpdateHud(actionLabel = "等待界面稳定…", incrementStep = false, toolName = tool)
                runCatching { Thread.sleep(ms) }
                JSONObject().put("ok", true).put("waitedMs", ms)
            }
            "phone_screen" -> {
                val svc = GrassBagAccessibilityService.current() ?: return accessibilityMissingError()
                val pkg = svc.currentForegroundPackage()
                val appLabel = svc.resolveAppLabel(pkg)
                if (pkg != "dev.grassbag.grassbag") {
                    val denied = gateAndConfirm(
                        tool = tool,
                        targetPackage = pkg,
                        targetAppLabel = appLabel,
                        actionSummary = "读取屏幕界面",
                        hudActionLabel = "读取当前屏幕",
                        sessionId = sessionId,
                        turnId = turnId,
                        permissionPreset = permissionPreset,
                        userApproved = userApproved
                    )
                    if (denied != null) return denied
                }
                val maxNodes = args.optInt("maxNodes", 140).coerceIn(10, 300)
                svc.captureScreenTree(maxNodes)
            }
            "phone_screenshot" -> {
                val svc = GrassBagAccessibilityService.current() ?: return accessibilityMissingError()
                val pkg = svc.currentForegroundPackage()
                val appLabel = svc.resolveAppLabel(pkg)
                val denied = gateAndConfirm(
                    tool = tool,
                    targetPackage = pkg,
                    targetAppLabel = appLabel,
                    actionSummary = "截取当前屏幕画面",
                    hudActionLabel = "截取屏幕画面",
                    sessionId = sessionId,
                    turnId = turnId,
                    permissionPreset = permissionPreset,
                    userApproved = userApproved
                )
                if (denied != null) return denied
                svc.captureScreenshotBase64(
                    maxWidth = args.optInt("maxWidth", 720).coerceIn(320, 1080),
                    quality = args.optInt("quality", 68).coerceIn(35, 90)
                )
            }
            "phone_tap", "phone_long_press" -> {
                val svc = GrassBagAccessibilityService.current() ?: return accessibilityMissingError()
                val blockedMultiWin = svc.findBlockedVisibleWindowPackage(ignoreSelf = true)
                if (blockedMultiWin != null) {
                    SafetyGate.recordAudit(tool, blockedMultiWin, false, "blocked_sensitive_package")
                    return JSONObject().put("ok", false).put("blocked", true).put("reason", "blocked_sensitive_package")
                        .put("blockedPackage", blockedMultiWin)
                }
                val pkg = svc.currentForegroundPackage()
                val nodeId = args.optString("nodeId", "").trim()
                val cachedNode = if (nodeId.isNotEmpty()) svc.getCachedNode(nodeId) else null
                if (cachedNode != null && !pkg.isNullOrBlank() && cachedNode.packageName.isNotBlank() && cachedNode.packageName != pkg) {
                    return JSONObject().put("ok", false).put("reason", "stale_node_package_mismatch")
                        .put("hint", "前台应用已切换（${cachedNode.packageName} -> $pkg），请先重新调用 phone_screen 获取最新界面元素。")
                }
                val x = cachedNode?.cx?.toDouble() ?: args.optDouble("x", -1.0)
                val y = cachedNode?.cy?.toDouble() ?: args.optDouble("y", -1.0)
                if (!x.isFinite() || !y.isFinite() || x < 0.0 || y < 0.0) {
                    return JSONObject().put("ok", false).put("reason", "valid nodeId or non-negative finite x, y coordinates are required")
                }
                val appLabel = svc.resolveAppLabel(pkg) ?: (pkg ?: "当前应用")
                val (inspectedLabel, hitsSensitive) = svc.inspectPointTarget(x.toFloat(), y.toFloat())
                // Prefer live inspected label for UI summary, and evaluate SafetyGate sensitive keywords
                // against BOTH live inspected label and cached label so a newly appeared sensitive button is never bypassed.
                val elemLabel = inspectedLabel?.takeIf { it.isNotBlank() } ?: cachedNode?.label
                val gateLabel = listOfNotNull(inspectedLabel, cachedNode?.label).distinct().joinToString(" ").ifBlank { null }
                val isLong = tool == "phone_long_press"
                val verb = if (isLong) "长按" else "点击"
                val targetDesc = if (!elemLabel.isNullOrBlank()) "「$elemLabel」" else "位置 (${x.toInt()}, ${y.toInt()})"
                val showedPrompt = AtomicBoolean(false)
                val denied = gateAndConfirm(
                    tool = tool,
                    targetPackage = pkg,
                    targetAppLabel = appLabel,
                    actionSummary = "在「$appLabel」中$verb$targetDesc",
                    hudActionLabel = "$verb$targetDesc",
                    sessionId = sessionId,
                    turnId = turnId,
                    permissionPreset = permissionPreset,
                    targetLabel = gateLabel,
                    isSensitiveTarget = hitsSensitive || (cachedNode?.sensitive == true),
                    userApproved = userApproved,
                    outShowedPrompt = showedPrompt
                )
                if (denied != null) return denied
                if (SafetyGate.isEmergencyStopped()) {
                    return JSONObject().put("ok", false).put("blocked", true).put("reason", "foreground_changed_or_stopped")
                }
                if (showedPrompt.get()) {
                    val postPkg = svc.currentForegroundPackage()
                    val postBlockedWin = svc.findBlockedVisibleWindowPackage(ignoreSelf = true)
                    val appSwappedDuringConfirm = !pkg.isNullOrBlank() && !postPkg.isNullOrBlank() && postPkg != pkg
                    val preSensitive = hitsSensitive || (cachedNode?.sensitive == true)
                    val (postLabel, postSensitive) = svc.inspectPointTarget(x.toFloat(), y.toFloat())
                    val prevSensWord = SafetyGate.sensitiveActionHit(gateLabel)
                    val postSensWord = SafetyGate.sensitiveActionHit(postLabel)
                    val newSensitiveAppeared = (postSensitive && !preSensitive) ||
                        (postSensWord != null && postSensWord != prevSensWord)
                    if (SafetyGate.isPackageBlocked(postPkg) ||
                        postBlockedWin != null ||
                        appSwappedDuringConfirm ||
                        newSensitiveAppeared
                    ) {
                        return JSONObject().put("ok", false).put("blocked", true).put("reason", "foreground_changed_or_stopped")
                    }
                }
                val dur = if (isLong) args.optLong("durationMs", 650L).coerceIn(400L, 1800L) else 65L
                svc.executeTapGesture(x.toFloat(), y.toFloat(), dur, elemLabel).apply {
                    if (!elemLabel.isNullOrBlank()) put("label", elemLabel)
                }
            }
            "phone_swipe" -> {
                val svc = GrassBagAccessibilityService.current() ?: return accessibilityMissingError()
                val blockedMultiWin = svc.findBlockedVisibleWindowPackage(ignoreSelf = true)
                if (blockedMultiWin != null) {
                    SafetyGate.recordAudit(tool, blockedMultiWin, false, "blocked_sensitive_package")
                    return JSONObject().put("ok", false).put("blocked", true).put("reason", "blocked_sensitive_package")
                        .put("blockedPackage", blockedMultiWin)
                }
                val x1 = args.optDouble("x1", -1.0)
                val y1 = args.optDouble("y1", -1.0)
                val x2 = args.optDouble("x2", -1.0)
                val y2 = args.optDouble("y2", -1.0)
                val dur = args.optLong("durationMs", 300L)
                if (!x1.isFinite() || !y1.isFinite() || !x2.isFinite() || !y2.isFinite() || x1 < 0 || y1 < 0 || x2 < 0 || y2 < 0) {
                    return JSONObject().put("ok", false).put("reason", "valid non-negative finite swipe coordinates are required")
                }
                val pkg = svc.currentForegroundPackage()
                val appLabel = svc.resolveAppLabel(pkg) ?: (pkg ?: "当前应用")
                val showedPrompt = AtomicBoolean(false)
                val denied = gateAndConfirm(
                    tool = tool,
                    targetPackage = pkg,
                    targetAppLabel = appLabel,
                    actionSummary = "在「$appLabel」中滑动屏幕",
                    hudActionLabel = "滑动屏幕",
                    sessionId = sessionId,
                    turnId = turnId,
                    permissionPreset = permissionPreset,
                    userApproved = userApproved,
                    outShowedPrompt = showedPrompt
                )
                if (denied != null) return denied
                if (SafetyGate.isEmergencyStopped()) {
                    return JSONObject().put("ok", false).put("blocked", true).put("reason", "foreground_changed_or_stopped")
                }
                if (showedPrompt.get()) {
                    val postPkg = svc.currentForegroundPackage()
                    val postBlockedWin = svc.findBlockedVisibleWindowPackage(ignoreSelf = true)
                    val appSwappedDuringConfirm = !pkg.isNullOrBlank() && !postPkg.isNullOrBlank() && postPkg != pkg
                    if (SafetyGate.isPackageBlocked(postPkg) || postBlockedWin != null || appSwappedDuringConfirm) {
                        return JSONObject().put("ok", false).put("blocked", true).put("reason", "foreground_changed_or_stopped")
                    }
                }
                svc.executeSwipeGesture(x1.toFloat(), y1.toFloat(), x2.toFloat(), y2.toFloat(), dur)
            }
            "phone_key" -> {
                val svc = GrassBagAccessibilityService.current() ?: return accessibilityMissingError()
                val action = args.optString("action", "back").lowercase()
                val label = when (action) {
                    "back" -> "返回上一页"
                    "home" -> "回到手机桌面"
                    "recents" -> "打开最近任务"
                    "notifications" -> "展开通知栏"
                    else -> "按系统键 $action"
                }
                val pkg = svc.currentForegroundPackage()
                val targetForCheck = if (action == "home") "system_home" else pkg
                val denied = gateAndConfirm(
                    tool = tool,
                    targetPackage = targetForCheck,
                    targetAppLabel = "系统导航",
                    actionSummary = label,
                    hudActionLabel = label,
                    sessionId = sessionId,
                    turnId = turnId,
                    permissionPreset = permissionPreset,
                    userApproved = userApproved
                )
                if (denied != null) return denied
                svc.executeSystemAction(action)
            }
            "phone_type" -> {
                val svc = GrassBagAccessibilityService.current() ?: return accessibilityMissingError()
                val blockedMultiWin = svc.findBlockedVisibleWindowPackage(ignoreSelf = true)
                if (blockedMultiWin != null) {
                    SafetyGate.recordAudit(tool, blockedMultiWin, false, "blocked_sensitive_package")
                    return JSONObject().put("ok", false).put("blocked", true).put("reason", "blocked_sensitive_package")
                        .put("blockedPackage", blockedMultiWin)
                }
                val text = args.optString("text", "")
                val pkg = svc.currentForegroundPackage()
                val appLabel = svc.resolveAppLabel(pkg) ?: (pkg ?: "当前应用")
                val (_, sensitive, fieldLabel) = svc.inspectFocusedInput()
                val preview = if (text.length > 48) text.take(48) + "…" else text
                val submit = args.optBoolean("submit", false)
                val showedPrompt = AtomicBoolean(false)
                val denied = gateAndConfirm(
                    tool = tool,
                    targetPackage = pkg,
                    targetAppLabel = appLabel,
                    actionSummary = "在「$appLabel」中输入：\"$preview\"",
                    hudActionLabel = "输入「${if (text.length > 14) text.take(14) + "…" else text}」",
                    sessionId = sessionId,
                    turnId = turnId,
                    permissionPreset = permissionPreset,
                    targetLabel = fieldLabel,
                    isSensitiveTarget = sensitive,
                    userApproved = userApproved,
                    outShowedPrompt = showedPrompt
                )
                if (denied != null) return denied
                if (SafetyGate.isEmergencyStopped()) {
                    return JSONObject().put("ok", false).put("blocked", true).put("reason", "foreground_changed_or_stopped")
                }
                if (showedPrompt.get()) {
                    val postPkg = svc.currentForegroundPackage()
                    val postBlockedWin = svc.findBlockedVisibleWindowPackage(ignoreSelf = true)
                    val appSwappedDuringConfirm = !pkg.isNullOrBlank() && !postPkg.isNullOrBlank() && postPkg != pkg
                    val (_, postSensitive, postFieldLabel) = svc.inspectFocusedInput()
                    val prevSensWord = SafetyGate.sensitiveActionHit(fieldLabel)
                    val postSensWord = SafetyGate.sensitiveActionHit(postFieldLabel)
                    val newSensitiveAppeared = (postSensitive && !sensitive) ||
                        (postSensWord != null && postSensWord != prevSensWord)
                    if (SafetyGate.isPackageBlocked(postPkg) ||
                        postBlockedWin != null ||
                        appSwappedDuringConfirm ||
                        newSensitiveAppeared
                    ) {
                        return JSONObject().put("ok", false).put("blocked", true).put("reason", "foreground_changed_or_stopped")
                    }
                }
                overlay.showTypeFx(preview)
                svc.executeType(text, submit = submit)
            }
            "phone_open" -> {
                val rawPkg = args.optString("package", "").trim()
                val rawAppName = args.optString("appName", args.optString("name", "")).trim()
                val url = args.optString("url", "").trim()
                if (url.isNotEmpty() && rawPkg.isEmpty() && rawAppName.isEmpty()) {
                    val parsed = runCatching { Uri.parse(url) }.getOrNull()
                    val scheme = parsed?.scheme?.lowercase()
                    if (scheme != "http" && scheme != "https") {
                        return JSONObject().put("ok", false).put("blocked", true).put("reason", "disallowed_url_scheme")
                    }
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    val matchedPkgs = runCatching {
                        context.packageManager.queryIntentActivities(intent, 0)
                            .mapNotNull { it.activityInfo?.packageName }
                            .distinct()
                    }.getOrDefault(emptyList())
                    val blockedTarget = matchedPkgs.firstOrNull { SafetyGate.isPackageBlocked(it) }
                    if (blockedTarget != null) {
                        SafetyGate.recordAudit(tool, blockedTarget, false, "blocked_sensitive_url_target")
                        return JSONObject()
                            .put("ok", false)
                            .put("blocked", true)
                            .put("reason", "blocked_sensitive_package")
                            .put("hint", "该链接可能唤起受保护的金融/支付应用（$blockedTarget），已禁止自动打开。")
                    }
                    val resolvedPkg = context.packageManager.resolveActivity(intent, 0)?.activityInfo?.packageName
                        ?: return JSONObject().put("ok", false).put("reason", "no_browser_found")
                    val everyWriteTarget = matchedPkgs.firstOrNull { SafetyGate.isConfirmEveryWritePackage(it) }
                    val gateTargetPkg = everyWriteTarget ?: resolvedPkg
                    val gateAppLabel = if (everyWriteTarget != null) {
                        GrassBagAccessibilityService.current()?.resolveAppLabel(everyWriteTarget) ?: everyWriteTarget
                    } else {
                        "浏览器"
                    }
                    val denied = gateAndConfirm(
                        tool = tool,
                        targetPackage = gateTargetPkg,
                        targetAppLabel = gateAppLabel,
                        actionSummary = "打开链接：$url",
                        hudActionLabel = "打开网页链接",
                        sessionId = sessionId,
                        turnId = turnId,
                        permissionPreset = permissionPreset,
                        userApproved = userApproved
                    )
                    if (denied != null) return denied
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    val launchCtx: Context = GrassBagAccessibilityService.current() ?: context
                    val err = runCatching { launchCtx.startActivity(intent) }.exceptionOrNull()
                    return if (err != null) {
                        JSONObject().put("ok", false).put("reason", "activity_launch_failed:${err.message}")
                    } else {
                        JSONObject().put("ok", true).put("opened", url).put("resolvedPackage", resolvedPkg)
                    }
                }
                val resolved = resolveAppByNameOrPackage(rawPkg, rawAppName)
                    ?: return JSONObject()
                        .put("ok", false)
                        .put("reason", "target_app_not_found")
                        .put("hint", "未找到对应应用「${rawAppName.ifBlank { rawPkg }}」，请先调用 phone_apps 查看设备已安装应用及其准确包名。")
                val (resolvedPkg, resolvedLabel) = resolved
                val denied = gateAndConfirm(
                    tool = tool,
                    targetPackage = resolvedPkg,
                    targetAppLabel = resolvedLabel,
                    actionSummary = "打开应用「$resolvedLabel」",
                    hudActionLabel = "打开「$resolvedLabel」",
                    sessionId = sessionId,
                    turnId = turnId,
                    permissionPreset = permissionPreset,
                    userApproved = userApproved
                )
                if (denied != null) return denied
                val intent = context.packageManager.getLaunchIntentForPackage(resolvedPkg)
                    ?: return JSONObject().put("ok", false).put("reason", "launch_intent_missing")
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                val launchCtx: Context = GrassBagAccessibilityService.current() ?: context
                val launchErr = runCatching { launchCtx.startActivity(intent) }.exceptionOrNull()
                if (launchErr != null) {
                    JSONObject().put("ok", false).put("reason", "activity_launch_failed:${launchErr.message ?: launchErr.javaClass.simpleName}")
                } else {
                    JSONObject().put("ok", true).put("opened", resolvedLabel).put("resolvedPackage", resolvedPkg)
                }
            }
            "phone_intent" -> {
                val kind = args.optString("kind", "").trim()
                val supportedKinds = setOf("alarm", "timer", "share", "navigation", "calendar")
                if (kind !in supportedKinds) {
                    return JSONObject()
                        .put("ok", false)
                        .put("reason", "unsupported_intent_kind")
                        .put("hint", "不支持的系统快捷动作类型：$kind（支持 alarm / timer / share / navigation / calendar）")
                }
                if (kind == "navigation") {
                    val dest = args.optString("query", args.optString("destination", "")).trim()
                    if (dest.isEmpty()) {
                        return JSONObject()
                            .put("ok", false)
                            .put("reason", "destination_required")
                            .put("hint", "地图导航需要提供目的地 query 或 destination 参数。")
                    }
                }
                val summary = when (kind) {
                    "alarm" -> "设置闹钟 ${args.optInt("hour", 8)}:${args.optInt("minute", 0).toString().padStart(2, '0')}"
                    "timer" -> "启动计时器 ${args.optInt("seconds", 60)} 秒"
                    "share" -> "调用系统分享文本"
                    "navigation" -> "打开地图导航：${args.optString("query", args.optString("destination", ""))}"
                    "calendar" -> "新建系统日程：${args.optString("title", args.optString("label", "日程"))}"
                    else -> "执行系统快捷动作：$kind"
                }
                val denied = gateAndConfirm(
                    tool = tool,
                    targetPackage = "system_intent_$kind",
                    targetAppLabel = "系统快捷指令",
                    actionSummary = summary,
                    hudActionLabel = summary,
                    sessionId = sessionId,
                    turnId = turnId,
                    permissionPreset = permissionPreset,
                    userApproved = userApproved
                )
                if (denied != null) return denied
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
                val message = args.optString("message", "请手动完成当前敏感步骤，完成后点击继续")
                SafetyGate.beginTurn(turnId, sessionId)
                onEvent("phone_handoff", mapOf("message" to message))
                val svc = GrassBagAccessibilityService.current()
                val appLabel = svc?.resolveAppLabel(svc.currentForegroundPackage())
                val decision = overlay.handoff(message = message, appLabel = appLabel, timeoutMs = 180_000L)
                when (decision) {
                    PhoneOverlayController.HandoffDecision.CONTINUE -> {
                        JSONObject().put("ok", true).put("handedOff", true).put("userCompleted", true).put("message", message)
                    }
                    PhoneOverlayController.HandoffDecision.STOP -> {
                        JSONObject().put("ok", false).put("blocked", true).put("reason", "user_stopped_during_handoff")
                    }
                    PhoneOverlayController.HandoffDecision.TIMEOUT -> {
                        JSONObject().put("ok", false).put("reason", "handoff_timeout")
                    }
                    PhoneOverlayController.HandoffDecision.UNAVAILABLE -> {
                        JSONObject()
                            .put("ok", false)
                            .put("blocked", true)
                            .put("reason", "overlay_unavailable")
                            .put("hint", "无法显示人工接管悬浮卡片。请先在「设置 → 权限管理」开启无障碍服务或悬浮窗权限后重试。")
                    }
                }
            }
            "phone_return_app" -> {
                val summary = args.optString("summary", "").trim()
                val steps = overlay.currentStepCount()
                SafetyGate.endTurn(sessionId, turnId)
                overlay.showCompletionAndReturn(
                    summary = summary,
                    reason = "completed",
                    autoReturn = true
                )
                onEvent("phone_turn_end", mapOf(
                    "sessionId" to (sessionId ?: ""),
                    "reason" to "completed",
                    "summary" to summary,
                    "autoReturn" to true,
                    "stepsCount" to steps,
                    "appLabel" to overlay.currentAppLabel()
                ))
                JSONObject().put("ok", true).put("returned", true)
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
            val rawLenHeader = headers["content-length"]
            val rawLenLong = if (rawLenHeader != null) {
                rawLenHeader.toLongOrNull() ?: throw IllegalArgumentException("invalid_content_length")
            } else {
                null
            }
            if (rawLenLong != null && (rawLenLong < 0L || rawLenLong > 2L * 1024L * 1024L)) {
                throw IllegalArgumentException("payload_too_large")
            }
            val bodyStr = if (headers["transfer-encoding"]?.contains("chunked", ignoreCase = true) == true) {
                val out = java.io.ByteArrayOutputStream()
                while (true) {
                    val lineBytes = ArrayList<Byte>(16)
                    var gotNewline = false
                    while (true) {
                        val ch = input.read()
                        if (ch == -1) break
                        if (ch == '\n'.code) {
                            gotNewline = true
                            break
                        }
                        if (ch != '\r'.code) {
                            if (lineBytes.size >= 128) throw IllegalArgumentException("chunk_header_too_long")
                            lineBytes.add(ch.toByte())
                        }
                    }
                    if (!gotNewline && lineBytes.isEmpty()) {
                        throw java.io.EOFException("unexpected_eof_in_chunk_header")
                    }
                    val sizeHex = String(lineBytes.toByteArray(), Charsets.US_ASCII).substringBefore(';').trim()
                    val chunkSizeLong = sizeHex.toLongOrNull(16)
                        ?: throw IllegalArgumentException("invalid_chunk_size")
                    if (chunkSizeLong < 0L) throw IllegalArgumentException("invalid_chunk_size")
                    if (chunkSizeLong == 0L) break
                    if (out.size().toLong() + chunkSizeLong > 2L * 1024L * 1024L) {
                        throw IllegalArgumentException("payload_too_large")
                    }
                    val chunkSize = chunkSizeLong.toInt()
                    val buf = ByteArray(chunkSize)
                    var got = 0
                    while (got < chunkSize) {
                        val n = input.read(buf, got, chunkSize - got)
                        if (n <= 0) throw java.io.EOFException("unexpected_eof_in_chunk_body")
                        got += n
                    }
                    out.write(buf, 0, got)
                    val cr = input.read()
                    val lf = if (cr == '\r'.code) input.read() else cr
                    if (cr == -1 || lf == -1) throw java.io.EOFException("unexpected_eof_after_chunk")
                }
                String(out.toByteArray(), Charsets.UTF_8)
            } else {
                val contentLength = (rawLenLong ?: 0L).toInt()
                val bodyBytes = ByteArray(contentLength)
                var read = 0
                while (read < contentLength) {
                    val n = input.read(bodyBytes, read, contentLength - read)
                    if (n <= 0) throw java.io.EOFException("unexpected_eof_in_body")
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
