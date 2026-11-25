package dev.grassbag.grassbag

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Base64
import android.view.Display
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Opt-in AccessibilityService powering SafetyGate-protected Phone Control tools &
 * [PhoneOverlayController] Liquid Glass HUD / out-of-app confirmation cards.
 */
class GrassBagAccessibilityService : AccessibilityService() {

    data class CachedScreenNode(
        val id: String,
        val label: String,
        val cx: Float,
        val cy: Float,
        val editable: Boolean,
        val sensitive: Boolean,
        val packageName: String
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val screenshotExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "gb-a11y-shot").apply { isDaemon = true }
    }
    private val lastScreenNodes = ConcurrentHashMap<String, CachedScreenNode>()
    private var screenOffRegistered = false

    private val screenOffReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) {
                PhoneOverlayController.getInstance(applicationContext).dismissAll()
                SafetyGate.endTurn(null)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        runCatching { SafetyGate.init(applicationContext) }
    }

    override fun onServiceConnected() {
        runCatching { super.onServiceConnected() }
        runCatching { SafetyGate.init(applicationContext) }
        activeInstance = this
        serviceConnected.set(true)
        PhoneOverlayController.getInstance(applicationContext).attachService(this)
        if (!screenOffRegistered) {
            runCatching {
                val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    registerReceiver(screenOffReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    registerReceiver(screenOffReceiver, filter)
                }
                screenOffRegistered = true
            }
        }
        notifyStateChanged(true)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        runCatching {
            if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
            val pkg = event.packageName?.toString()
            if (!pkg.isNullOrBlank() &&
                pkg != "com.android.systemui" &&
                !pkg.contains("inputmethod", ignoreCase = true) &&
                (pkg != applicationContext.packageName || MainActivity.isMainActivityResumed)
            ) {
                lastForegroundPackage = pkg
            }
        }
    }

    override fun onInterrupt() {
        // Keep active task intact on system feedback interrupt (matches dsh-Go).
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        PhoneOverlayController.getInstance(applicationContext).onConfigurationChanged()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        cleanupServiceState()
        return runCatching { super.onUnbind(intent) }.getOrDefault(false)
    }

    override fun onDestroy() {
        cleanupServiceState()
        runCatching { screenshotExecutor.shutdownNow() }
        runCatching { super.onDestroy() }
    }

    private fun cleanupServiceState() {
        if (screenOffRegistered) {
            runCatching { unregisterReceiver(screenOffReceiver) }
            screenOffRegistered = false
        }
        PhoneOverlayController.getInstance(applicationContext).detachService(this)
        lastScreenNodes.clear()
        if (activeInstance === this) {
            activeInstance = null
            lastForegroundPackage = null
            serviceConnected.set(false)
            notifyStateChanged(false)
        }
    }

    fun getCachedNode(nodeId: String): CachedScreenNode? = lastScreenNodes[nodeId]

    fun currentForegroundPackage(): String? {
        val root = waitForActiveRoot(retries = 2)
        val rootPkg = try {
            root?.packageName?.toString()?.takeIf { it.isNotBlank() }
        } finally {
            recycleCompat(root)
        }
        if (rootPkg != null &&
            rootPkg != "com.android.systemui" &&
            !rootPkg.contains("inputmethod", ignoreCase = true)
        ) {
            return rootPkg
        }
        // Ignore transient SystemUI volume/notification popups or IME overlays by inspecting top application window.
        val topAppPkg = runCatching {
            windows?.firstOrNull { win ->
                win.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_APPLICATION &&
                    win.root?.packageName?.toString()?.let { p ->
                        p.isNotBlank() && p != "com.android.systemui" && !p.contains("inputmethod", ignoreCase = true)
                    } == true
            }?.let { win ->
                val r = win.root
                try {
                    r?.packageName?.toString()
                } finally {
                    recycleCompat(r)
                }
            }
        }.getOrNull()
        return topAppPkg ?: lastForegroundPackage ?: rootPkg
    }

    fun resolveAppLabel(pkg: String?): String? {
        if (pkg.isNullOrBlank()) return null
        return runCatching {
            val ai = packageManager.getApplicationInfo(pkg, 0)
            packageManager.getApplicationLabel(ai)?.toString()?.takeIf { it.isNotBlank() }
        }.getOrNull()
    }

    /**
     * Brings GrassBag's MainActivity cleanly back to the foreground from the AccessibilityService
     * context (sanctioned OS exemption for Android 10-16 Background Activity Launch restrictions).
     */
    fun bringGrassBagToFront(preferPendingIntent: Boolean = false): Boolean {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
            )
        }
        if (!preferPendingIntent) {
            val directOk = runCatching {
                startActivity(intent)
                true
            }.getOrDefault(false)
            if (directOk) return true
        }
        return runCatching {
            val pi = PendingIntent.getActivity(
                this,
                7701,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val opts = ActivityOptions.makeBasic()
                    .setPendingIntentBackgroundActivityStartMode(
                        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                    )
                    .toBundle()
                pi.send(this, 0, null, null, null, null, opts)
            } else {
                pi.send()
            }
            true
        }.getOrDefault(false)
    }

    private fun waitForActiveRoot(retries: Int = 3): AccessibilityNodeInfo? {
        for (i in 0 until retries) {
            val r = runCatching { rootInActiveWindow }.getOrNull()
            if (r != null) return r
            if (i + 1 < retries) {
                runCatching { Thread.sleep(110L) }
            }
        }
        return null
    }

    @Suppress("DEPRECATION")
    private fun recycleCompat(node: AccessibilityNodeInfo?) {
        if (node != null && Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            runCatching { node.recycle() }
        }
    }

    private fun nodeHintCompat(node: AccessibilityNodeInfo): String? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) node.hintText?.toString() else null

    private fun isNodeOrAncestorsSensitive(node: AccessibilityNodeInfo?): Boolean {
        var cur = node
        var depth = 0
        try {
            while (cur != null && depth < 4) {
                val hintOrDesc = listOfNotNull(cur.contentDescription?.toString(), nodeHintCompat(cur)).joinToString(" ")
                val isPwd = runCatching { cur.isPassword }.getOrDefault(false)
                val editable = runCatching { cur.isEditable }.getOrDefault(false)
                // Check ancestors (`depth > 0`) regardless of `isEditable` so Material TextInputLayout /
                // custom PIN/OTP wrapper containers carrying "密码"/"验证码"/"银行卡号" are always caught.
                val textForCheck = if (depth == 0 && editable) cur.text?.toString() else null
                if (isPwd || SafetyGate.isSensitiveNode(false, textForCheck, hintOrDesc.ifBlank { null }, cur.viewIdResourceName)) {
                    return true
                }
                val parent = cur.parent
                if (depth > 0) recycleCompat(cur)
                cur = parent
                depth++
            }
            return false
        } finally {
            if (cur != null && depth > 0) recycleCompat(cur)
        }
    }

    /**
     * Checks ONLY visible `TYPE_APPLICATION` windows (ignoring background OEM `TYPE_SYSTEM` daemons
     * and our own `TYPE_ACCESSIBILITY_OVERLAY` HUD/cards).
     */
    fun findBlockedVisibleWindowPackage(ignoreSelf: Boolean = false): String? {
        return runCatching {
            val allWindows = windows ?: return@runCatching null
            for (win in allWindows) {
                if (win.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                val r = win.root ?: continue
                try {
                    val pkg = r.packageName?.toString()
                    if (pkg.isNullOrBlank()) continue
                    if (ignoreSelf && pkg == "dev.grassbag.grassbag") continue
                    if (SafetyGate.isPackageBlocked(pkg)) return@runCatching pkg
                } finally {
                    recycleCompat(r)
                }
            }
            null
        }.getOrNull()
    }

    private fun physicalScreenSize(): Pair<Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        if (wm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = runCatching { wm.maximumWindowMetrics.bounds }.getOrNull()
            if (b != null && b.width() > 0 && b.height() > 0) {
                return b.width() to b.height()
            }
        }
        val dm = android.util.DisplayMetrics()
        @Suppress("DEPRECATION")
        val gotReal = wm != null && runCatching {
            wm.defaultDisplay?.getRealMetrics(dm)
            dm.widthPixels > 0 && dm.heightPixels > 0
        }.getOrDefault(false)
        if (gotReal) return dm.widthPixels to dm.heightPixels
        val fallback = resources.displayMetrics
        return fallback.widthPixels.coerceAtLeast(1) to fallback.heightPixels.coerceAtLeast(1)
    }

    private fun clampPoint(x: Float, y: Float): Pair<Float, Float> {
        val (w, h) = physicalScreenSize()
        val maxW = (w - 1).coerceAtLeast(1).toFloat()
        val maxH = (h - 1).coerceAtLeast(1).toFloat()
        return x.coerceIn(0f, maxW) to y.coerceIn(0f, maxH)
    }

    /** Inspects the visible leaf node at `(x, y)` to find its label & whether it is a password/OTP input. */
    fun inspectPointTarget(x: Float, y: Float): Pair<String?, Boolean> {
        val (cx, cy) = clampPoint(x, y)
        val root = waitForActiveRoot(retries = 2) ?: return Pair(null, false)
        try {
            val rect = Rect()
            var bestLabel: String? = null
            var bestArea = Long.MAX_VALUE
            var hitsSensitive = false
            var visited = 0

            fun walk(node: AccessibilityNodeInfo?, depth: Int) {
                if (node == null || depth > 42 || visited >= 1200) return
                val visible = runCatching { node.isVisibleToUser }.getOrDefault(true)
                if (!visible) return
                runCatching { node.getBoundsInScreen(rect) }
                if (rect.isEmpty) return
                if (depth > 0 && !rect.contains(cx.toInt(), cy.toInt())) return
                visited++

                val isPwd = runCatching { node.isPassword }.getOrDefault(false)
                val editable = runCatching { node.isEditable }.getOrDefault(false)
                val text = runCatching { node.text?.toString() }.getOrNull()?.trim()
                val desc = runCatching { node.contentDescription?.toString() }.getOrNull()?.trim()
                val hint = runCatching { nodeHintCompat(node) }.getOrNull()?.trim()
                val viewId = runCatching { node.viewIdResourceName }.getOrNull()

                if (rect.contains(cx.toInt(), cy.toInt())) {
                    val hintDesc = listOfNotNull(desc, hint).joinToString(" ").ifBlank { null }
                    if (isPwd || SafetyGate.isSensitiveNode(false, if (editable) text else null, hintDesc, viewId)) {
                        hitsSensitive = true
                    }
                    val area = rect.width().toLong() * rect.height().toLong()
                    val candidateLabel = text?.takeIf { it.isNotEmpty() }
                        ?: desc?.takeIf { it.isNotEmpty() }
                        ?: hint?.takeIf { it.isNotEmpty() }
                    if (candidateLabel != null && area <= bestArea) {
                        bestArea = area
                        bestLabel = candidateLabel.take(40)
                    }
                }
                val childCount = runCatching { node.childCount }.getOrDefault(0)
                for (i in 0 until childCount) {
                    val child = runCatching { node.getChild(i) }.getOrNull() ?: continue
                    try {
                        walk(child, depth + 1)
                    } finally {
                        recycleCompat(child)
                    }
                }
            }
            walk(root, 0)
            return Pair(bestLabel, hitsSensitive)
        } finally {
            recycleCompat(root)
        }
    }

    fun captureScreenTree(maxNodes: Int = 140): JSONObject {
        val safeMax = maxNodes.coerceIn(10, 300)
        val root = waitForActiveRoot(retries = 3)
        try {
            val pkg = root?.packageName?.toString() ?: lastForegroundPackage ?: "unknown"
            if (pkg == "dev.grassbag.grassbag") {
                return JSONObject()
                    .put("ok", true)
                    .put("package", pkg)
                    .put("inGrassBag", true)
                    .put("message", "当前前台为 GrassBag 本身（安全隔离）。请先调用 phone_open(appName/package) 打开目标应用，或 phone_apps 查看已安装应用，或 phone_key(action=home) 返回桌面。")
                    .put("elements", JSONArray())
            }
            val blockedMultiWin = findBlockedVisibleWindowPackage(ignoreSelf = true)
            if (blockedMultiWin != null) {
                return JSONObject()
                    .put("ok", false)
                    .put("blocked", true)
                    .put("package", blockedMultiWin)
                    .put("reason", "blocked_sensitive_package")
            }
            if (SafetyGate.isPackageBlocked(pkg)) {
                return JSONObject()
                    .put("ok", false)
                    .put("blocked", true)
                    .put("package", pkg)
                    .put("reason", "blocked_sensitive_package")
            }

            lastScreenNodes.clear()
            val elements = JSONArray()
            if (root != null) {
                val rect = Rect()
                var count = 0
                var visited = 0
                fun walk(node: AccessibilityNodeInfo?, depth: Int, parentSensitive: Boolean) {
                    if (node == null || count >= safeMax || depth > 48 || visited >= 1600) return
                    visited++
                    val isPwd = runCatching { node.isPassword }.getOrDefault(false)
                    val editable = runCatching { node.isEditable }.getOrDefault(false)
                    val text = runCatching { node.text?.toString() }.getOrNull()
                    val desc = runCatching { node.contentDescription?.toString() }.getOrNull()
                    val hint = runCatching { nodeHintCompat(node) }.getOrNull()
                    val combinedHint = listOfNotNull(desc, hint).joinToString(" ").ifBlank { null }
                    val viewId = runCatching { node.viewIdResourceName }.getOrNull()
                    val sensitive = parentSensitive ||
                        isPwd ||
                        SafetyGate.isSensitiveNode(false, if (editable) text else null, combinedHint, viewId)
                    val visible = runCatching { node.isVisibleToUser }.getOrDefault(false)
                    val clickable = runCatching { node.isClickable }.getOrDefault(false)

                    if (visible && (clickable || editable || !text.isNullOrBlank() || !desc.isNullOrBlank())) {
                        runCatching { node.getBoundsInScreen(rect) }
                        val scrollable = runCatching { node.isScrollable }.getOrDefault(false)
                        val checked = runCatching { node.isChecked }.getOrDefault(false)
                        val focused = runCatching { node.isFocused }.getOrDefault(false)
                        val nodeId = "n$count"
                        val item = JSONObject()
                            .put("id", nodeId)
                            .put("class", runCatching { node.className?.toString()?.substringAfterLast('.') }.getOrNull() ?: "View")
                            .put("clickable", clickable)
                            .put("editable", editable)
                            .put("sensitive", sensitive)
                        if (scrollable) item.put("scrollable", true)
                        if (checked) item.put("checked", true)
                        if (focused) item.put("focused", true)
                        if (sensitive) {
                            item.put("text", "[REDACTED_BY_SAFETY_GATE]")
                        } else {
                            val cx = (rect.left + rect.right) / 2f
                            val cy = (rect.top + rect.bottom) / 2f
                            item.put("bounds", JSONArray().put(rect.left).put(rect.top).put(rect.right).put(rect.bottom))
                            item.put("center", JSONArray().put(cx.toInt()).put(cy.toInt()))
                            if (!text.isNullOrBlank()) item.put("text", text.take(160))
                            if (!desc.isNullOrBlank()) item.put("desc", desc.take(160))
                            val label = text?.trim()?.takeIf { it.isNotEmpty() }
                                ?: desc?.trim()?.takeIf { it.isNotEmpty() }
                                ?: hint?.trim()?.takeIf { it.isNotEmpty() }
                                ?: (viewId?.substringAfterLast('/') ?: "元素")
                            lastScreenNodes[nodeId] = CachedScreenNode(
                                id = nodeId,
                                label = label.take(40),
                                cx = cx,
                                cy = cy,
                                editable = editable,
                                sensitive = false,
                                packageName = pkg
                            )
                        }
                        if (!viewId.isNullOrBlank()) {
                            item.put("viewId", viewId.substringAfterLast('/'))
                        }
                        elements.put(item)
                        count++
                    }
                    val childCount = runCatching { node.childCount }.getOrDefault(0)
                    for (i in 0 until childCount) {
                        if (count >= safeMax || visited >= 1600) break
                        val child = runCatching { node.getChild(i) }.getOrNull() ?: continue
                        try {
                            walk(child, depth + 1, sensitive)
                        } finally {
                            recycleCompat(child)
                        }
                    }
                }
                walk(root, 0, false)
            }

            val (sw, sh) = physicalScreenSize()
            return JSONObject()
                .put("ok", true)
                .put("package", pkg)
                .put("appLabel", resolveAppLabel(pkg) ?: pkg)
                .put("screen", JSONObject()
                    .put("width", sw)
                    .put("height", sh)
                    .put("density", resources.displayMetrics.density.toDouble()))
                .put("elements", elements)
        } finally {
            recycleCompat(root)
        }
    }

    /**
     * Captures a compact JPEG screenshot via Android 11+ `AccessibilityService.takeScreenshot`,
     * cleanly hiding GrassBag's own HUD & Edge Beam during capture.
     */
    fun captureScreenshotBase64(maxWidth: Int = 720, quality: Int = 68): JSONObject {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return JSONObject()
                .put("ok", false)
                .put("reason", "screenshot_requires_android_11")
                .put("hint", "截屏需要 Android 11 及以上，请改用 phone_screen 读取无障碍界面树。")
        }
        val pkg = currentForegroundPackage()
        val blockedMultiWin = findBlockedVisibleWindowPackage(ignoreSelf = true)
        if (SafetyGate.isPackageBlocked(pkg) || pkg == "dev.grassbag.grassbag" || blockedMultiWin != null) {
            return JSONObject()
                .put("ok", false)
                .put("blocked", true)
                .put("reason", "blocked_sensitive_package")
                .apply { if (blockedMultiWin != null) put("blockedPackage", blockedMultiWin) }
        }
        val overlay = PhoneOverlayController.getInstance(applicationContext)
        overlay.hideForCapture(true)
        var captureSucceeded = false
        try {
            runCatching { Thread.sleep(60L) }
            val latch = CountDownLatch(1)
            val resultRef = AtomicReference<JSONObject?>()
            takeScreenshot(
                Display.DEFAULT_DISPLAY,
                screenshotExecutor,
                object : TakeScreenshotCallback {
                    override fun onSuccess(screenshot: ScreenshotResult) {
                        try {
                            val hw = Bitmap.wrapHardwareBuffer(screenshot.hardwareBuffer, screenshot.colorSpace)
                            if (hw == null) {
                                resultRef.set(JSONObject().put("ok", false).put("reason", "bitmap_wrap_failed"))
                            } else {
                                val soft = try {
                                    hw.copy(Bitmap.Config.ARGB_8888, false)
                                } finally {
                                    hw.recycle()
                                }
                                if (soft == null) {
                                    resultRef.set(JSONObject().put("ok", false).put("reason", "bitmap_copy_failed"))
                                } else {
                                    var scaled: Bitmap? = null
                                    try {
                                        scaled = if (soft.width > maxWidth && maxWidth > 120) {
                                            val targetH = (soft.height.toFloat() * maxWidth / soft.width).toInt().coerceAtLeast(1)
                                            Bitmap.createScaledBitmap(soft, maxWidth, targetH, true)
                                        } else {
                                            soft
                                        }
                                        val baos = ByteArrayOutputStream()
                                        val w = scaled.width
                                        val h = scaled.height
                                        scaled.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(30, 90), baos)
                                        val b64 = Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
                                        resultRef.set(
                                            JSONObject()
                                                .put("ok", true)
                                                .put("package", pkg ?: "unknown")
                                                .put("appLabel", resolveAppLabel(pkg) ?: (pkg ?: "unknown"))
                                                .put("mimeType", "image/jpeg")
                                                .put("width", w)
                                                .put("height", h)
                                                .put("base64", b64)
                                        )
                                    } finally {
                                        if (scaled != null && scaled !== soft && !scaled.isRecycled) {
                                            scaled.recycle()
                                        }
                                        if (!soft.isRecycled) {
                                            soft.recycle()
                                        }
                                    }
                                }
                            }
                        } catch (t: Throwable) {
                            resultRef.set(JSONObject().put("ok", false).put("reason", "screenshot_encode_error:${t.message}"))
                        } finally {
                            runCatching { screenshot.hardwareBuffer.close() }
                            latch.countDown()
                        }
                    }

                    override fun onFailure(errorCode: Int) {
                        resultRef.set(JSONObject().put("ok", false).put("reason", "screenshot_failed_code_$errorCode"))
                        latch.countDown()
                    }
                }
            )
            val done = runCatching { latch.await(4500L, TimeUnit.MILLISECONDS) }.getOrDefault(false)
            val result = resultRef.get() ?: JSONObject().put("ok", false).put("reason", if (!done) "screenshot_timeout" else "screenshot_failed")
            captureSucceeded = result.optBoolean("ok", false)
            return result
        } finally {
            overlay.hideForCapture(false)
            if (captureSucceeded) {
                overlay.showScreenshotPulse()
            }
        }
    }

    fun executeTapGesture(
        x: Float,
        y: Float,
        durationMs: Long = 65L,
        targetLabel: String? = null
    ): JSONObject {
        val (cx, cy) = clampPoint(x, y)
        val clampedDur = durationMs.coerceIn(40L, 1800L)
        val overlay = PhoneOverlayController.getInstance(applicationContext)
        overlay.showTapFx(cx, cy, label = targetLabel, isLongPress = clampedDur >= 350L, durationMs = clampedDur)
        val path = Path().apply { moveTo(cx, cy) }
        val stroke = GestureDescription.StrokeDescription(path, 0L, clampedDur)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        return dispatchSafeGesture(gesture, clampedDur + 1500L).put("x", cx).put("y", cy)
    }

    fun executeSwipeGesture(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long = 300L): JSONObject {
        val (cx1, cy1) = clampPoint(x1, y1)
        val (cx2, cy2) = clampPoint(x2, y2)
        val dur = durationMs.coerceIn(80L, 2000L)
        val overlay = PhoneOverlayController.getInstance(applicationContext)
        overlay.showSwipeFx(cx1, cy1, cx2, cy2, durationMs = dur)
        val path = Path().apply {
            moveTo(cx1, cy1)
            lineTo(cx2, cy2)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0L, dur)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        return dispatchSafeGesture(gesture, dur + 1500L)
            .put("x1", cx1).put("y1", cy1).put("x2", cx2).put("y2", cy2)
    }

    private fun dispatchSafeGesture(gesture: GestureDescription, timeoutMs: Long): JSONObject {
        val overlay = PhoneOverlayController.getInstance(applicationContext)
        overlay.setInjectingGesture(true)
        try {
            val latch = CountDownLatch(1)
            val ok = AtomicBoolean(false)
            val cancelled = AtomicBoolean(false)
            val dispatched = dispatchGesture(
                gesture,
                object : GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription?) {
                        ok.set(true)
                        latch.countDown()
                    }
                    override fun onCancelled(gestureDescription: GestureDescription?) {
                        cancelled.set(true)
                        ok.set(false)
                        latch.countDown()
                    }
                },
                null
            )
            if (!dispatched) {
                return JSONObject().put("ok", false).put("reason", "gesture_dispatch_rejected")
            }
            val finished = latch.await(timeoutMs, TimeUnit.MILLISECONDS)
            val res = JSONObject().put("ok", ok.get())
            if (!ok.get()) {
                res.put("reason", if (!finished) "gesture_timeout" else if (cancelled.get()) "gesture_cancelled" else "gesture_failed")
            }
            return res
        } finally {
            overlay.setInjectingGesture(false)
        }
    }

    fun executeSystemAction(action: String): JSONObject {
        val normAction = action.lowercase()
        val globalAction = when (normAction) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            else -> return JSONObject().put("ok", false).put("reason", "unsupported_key_action:$action")
        }
        val ok = performGlobalAction(globalAction)
        return JSONObject().put("ok", ok).put("action", normAction)
    }

    fun inspectFocusedInput(): Triple<Boolean, Boolean, String?> {
        val root = waitForActiveRoot(retries = 2) ?: return Triple(false, false, null)
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        try {
            if (focused == null) return Triple(false, false, null)
            val editable = runCatching { focused.isEditable }.getOrDefault(false)
            val sensitive = isNodeOrAncestorsSensitive(focused)
            val label = runCatching { nodeHintCompat(focused) ?: focused.contentDescription?.toString() }.getOrNull()
            return Triple(editable, sensitive, label)
        } finally {
            if (focused != null && focused !== root) recycleCompat(focused)
            recycleCompat(root)
        }
    }

    fun executeType(text: String, submit: Boolean = false): JSONObject {
        val root = waitForActiveRoot(retries = 3)
            ?: return JSONObject().put("ok", false).put("reason", "active_window_unavailable")
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        try {
            if (focused == null || !focused.isEditable) {
                return JSONObject().put("ok", false).put("reason", "no_editable_field_focused")
                    .put("hint", "当前没有聚焦的输入框，请先用 phone_tap 点击目标输入框后再输入。")
            }
            if (isNodeOrAncestorsSensitive(focused)) {
                return JSONObject().put("ok", false).put("blocked", true).put("reason", "blocked_sensitive_input_field")
            }
            val args = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
            }
            var ok = focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            if (!ok && text.isNotEmpty()) {
                val clipSet = AtomicBoolean(false)
                val previousClip = AtomicReference<ClipData?>(null)
                val clipLatch = CountDownLatch(1)
                mainHandler.post {
                    runCatching {
                        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                        if (cm != null) {
                            previousClip.set(runCatching { cm.primaryClip }.getOrNull())
                            cm.setPrimaryClip(ClipData.newPlainText("grassbag_input", text))
                            clipSet.set(true)
                        }
                    }
                    clipLatch.countDown()
                }
                if (runCatching { clipLatch.await(1500, TimeUnit.MILLISECONDS) }.getOrDefault(false) && clipSet.get()) {
                    ok = runCatching { focused.performAction(AccessibilityNodeInfo.ACTION_PASTE) }.getOrDefault(false)
                    // Restore user's prior clipboard after target app reads it; never wipe if previousClip
                    // was unreadable (Android 10+ background clipboard privacy returns null!).
                    mainHandler.postDelayed({
                        runCatching {
                            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return@runCatching
                            val curLabel = cm.primaryClipDescription?.label?.toString()
                            val prev = previousClip.get()
                            if (curLabel == "grassbag_input" && prev != null) {
                                cm.setPrimaryClip(prev)
                            }
                        }
                    }, 350L)
                }
            }
            var submitted = false
            if (ok && submit && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                runCatching { Thread.sleep(80L) }
                submitted = runCatching {
                    focused.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
                }.getOrDefault(false)
            }
            return JSONObject().put("ok", ok).put("length", text.length).put("submitted", submitted)
        } finally {
            if (focused != null && focused !== root) recycleCompat(focused)
            recycleCompat(root)
        }
    }

    companion object {
        @Volatile
        private var activeInstance: GrassBagAccessibilityService? = null

        private val serviceConnected = AtomicBoolean(false)

        @Volatile
        var lastForegroundPackage: String? = null
            private set

        private val stateListeners = CopyOnWriteArraySet<(Boolean) -> Unit>()

        fun addStateListener(listener: (Boolean) -> Unit) {
            stateListeners.add(listener)
        }

        fun removeStateListener(listener: (Boolean) -> Unit) {
            stateListeners.remove(listener)
        }

        private fun notifyStateChanged(connected: Boolean) {
            for (l in stateListeners) {
                runCatching { l(connected) }
            }
        }

        fun current(): GrassBagAccessibilityService? = activeInstance
        fun isRunning(): Boolean = activeInstance != null && serviceConnected.get()

        fun isSystemServiceActive(ctx: Context): Boolean = runCatching {
            val am = ctx.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
                ?: return@runCatching false
            am.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK).any { info ->
                val si = info.resolveInfo?.serviceInfo
                si != null && si.packageName == ctx.packageName &&
                    (si.name == GrassBagAccessibilityService::class.java.name ||
                        si.name.endsWith(".${GrassBagAccessibilityService::class.java.simpleName}"))
            }
        }.getOrDefault(false)

        fun isSettingEnabled(ctx: Context, precheckedSystemBound: Boolean? = null): Boolean {
            if (precheckedSystemBound ?: isSystemServiceActive(ctx)) return true
            val masterOn = runCatching {
                Settings.Secure.getInt(ctx.contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED, 0) == 1
            }.getOrDefault(false)
            if (!masterOn) return false
            val expectedComp = ComponentName(ctx.packageName, GrassBagAccessibilityService::class.java.name)
            val flattened = expectedComp.flattenToString()
            val shortFlattened = expectedComp.flattenToShortString()
            return runCatching {
                val enabled = Settings.Secure.getString(
                    ctx.contentResolver,
                    Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                ) ?: return@runCatching false
                enabled.split(':').any { entry ->
                    val trimmed = entry.trim()
                    trimmed.equals(flattened, ignoreCase = true) ||
                        trimmed.equals(shortFlattened, ignoreCase = true) ||
                        (trimmed.startsWith("${ctx.packageName}/") &&
                            trimmed.endsWith(GrassBagAccessibilityService::class.java.simpleName))
                }
            }.getOrDefault(false)
        }
    }
}
