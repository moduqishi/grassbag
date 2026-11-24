package dev.grassbag.grassbag

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Opt-in AccessibilityService powering SafetyGate-protected Phone Control tools.
 * Never reads or types into blocked packages or password/OTP fields.
 */
class GrassBagAccessibilityService : AccessibilityService() {

    override fun onCreate() {
        super.onCreate()
        runCatching { SafetyGate.init(applicationContext) }
    }

    override fun onServiceConnected() {
        runCatching { super.onServiceConnected() }
        runCatching { SafetyGate.init(applicationContext) }
        activeInstance = this
        serviceConnected.set(true)
        notifyStateChanged(true)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Track foreground package ONLY on window state transitions, ignoring SystemUI/IME overlays
        // so status-bar clock/notifications never falsely trigger SafetyGate's SystemUI block.
        runCatching {
            if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
            val pkg = event.packageName?.toString()
            if (!pkg.isNullOrBlank() && pkg != "com.android.systemui" && !pkg.contains("inputmethod", ignoreCase = true)) {
                lastForegroundPackage = pkg
            }
        }
    }

    override fun onInterrupt() {
        // No-op.
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var stopOverlayView: View? = null

    /**
     * Show a floating Emergency-Stop pill via `TYPE_ACCESSIBILITY_OVERLAY` (requires ZERO
     * `SYSTEM_ALERT_WINDOW` permission and stays visible even when driving other apps!).
     */
    fun showEmergencyStopOverlay(actionLabel: String = "手机操控中 · 急停") {
        mainHandler.post {
            if (!serviceConnected.get() || activeInstance !== this) return@post
            runCatching {
                val existing = stopOverlayView as? TextView
                if (existing != null) {
                    existing.text = actionLabel
                    return@runCatching
                }
                val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return@runCatching
                val density = resources.displayMetrics.density
                val pill = TextView(this).apply {
                    text = actionLabel
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
                    setPadding(
                        (14 * density).toInt(),
                        (8 * density).toInt(),
                        (14 * density).toInt(),
                        (8 * density).toInt()
                    )
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.RECTANGLE
                        cornerRadius = 999f * density
                        setColor(Color.parseColor("#E6D93B3B"))
                        setStroke((1 * density).toInt(), Color.parseColor("#88FFFFFF"))
                    }
                    elevation = 10f * density
                    setOnClickListener {
                        SafetyGate.triggerEmergencyStop()
                        hideEmergencyStopOverlay()
                    }
                }
                val params = WindowManager.LayoutParams(
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                    PixelFormat.TRANSLUCENT
                ).apply {
                    gravity = Gravity.TOP or Gravity.END
                    x = (14 * density).toInt()
                    y = (54 * density).toInt()
                }
                wm.addView(pill, params)
                stopOverlayView = pill
            }
        }
    }

    fun hideEmergencyStopOverlay() {
        val removeNow = Runnable {
            val v = stopOverlayView ?: return@Runnable
            stopOverlayView = null
            runCatching {
                val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
                wm?.removeViewImmediate(v)
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            removeNow.run()
        } else {
            mainHandler.post(removeNow)
        }
    }

    override fun onUnbind(intent: Intent?): Boolean {
        hideEmergencyStopOverlay()
        if (activeInstance === this) {
            activeInstance = null
            serviceConnected.set(false)
            notifyStateChanged(false)
        }
        return runCatching { super.onUnbind(intent) }.getOrDefault(false)
    }

    override fun onDestroy() {
        hideEmergencyStopOverlay()
        if (activeInstance === this) {
            activeInstance = null
            serviceConnected.set(false)
            notifyStateChanged(false)
        }
        runCatching { super.onDestroy() }
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
            while (cur != null && depth < 6) {
                val hintOrDesc = listOfNotNull(cur.contentDescription?.toString(), nodeHintCompat(cur)).joinToString(" ")
                if (SafetyGate.isSensitiveNode(cur.isPassword, cur.text?.toString(), hintOrDesc, cur.viewIdResourceName)) {
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

    private fun findBlockedVisibleWindowPackage(ignoreSelf: Boolean = false): String? {
        return runCatching {
            val allWindows = windows ?: return@runCatching null
            for (win in allWindows) {
                if (win.type != AccessibilityWindowInfo.TYPE_APPLICATION &&
                    win.type != AccessibilityWindowInfo.TYPE_SYSTEM
                ) continue
                val r = win.root ?: continue
                try {
                    val pkg = r.packageName?.toString()
                    if (pkg.isNullOrBlank()) continue
                    if (ignoreSelf && pkg == "dev.grassbag.grassbag") continue
                    // Ignore passive status bar / IME windows; inspect dialogs, split-screen, and overlays.
                    if (pkg == "com.android.systemui" && win.type == AccessibilityWindowInfo.TYPE_SYSTEM) continue
                    if (pkg.contains("inputmethod", ignoreCase = true)) continue
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
        val gotReal = wm != null && runCatching { wm.defaultDisplay?.getRealMetrics(dm); dm.widthPixels > 0 && dm.heightPixels > 0 }.getOrDefault(false)
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

    fun captureScreenTree(maxNodes: Int = 120): JSONObject {
        val safeMax = maxNodes.coerceIn(10, 300)
        val root = rootInActiveWindow
        try {
            val pkg = root?.packageName?.toString() ?: lastForegroundPackage ?: "unknown"
            // Friendly guidance when GrassBag itself is in the foreground (instead of failing with 403).
            if (pkg == "dev.grassbag.grassbag") {
                return JSONObject()
                    .put("ok", true)
                    .put("package", pkg)
                    .put("inGrassBag", true)
                    .put("message", "当前前台为 GrassBag 本身（受安全隔离保护）。请先调用 phone_open 打开目标应用或 phone_key(action=home) 返回桌面，再读取目标屏幕。")
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
            val decision = SafetyGate.evaluateToolCall("phone_screen", pkg)
            if (!decision.allowed) {
                return JSONObject()
                    .put("ok", false)
                    .put("blocked", true)
                    .put("package", pkg)
                    .put("reason", decision.reason)
            }

            val elements = JSONArray()
            if (root != null) {
                val rect = Rect()
                var count = 0
                var visited = 0
                fun walk(node: AccessibilityNodeInfo?, depth: Int, parentSensitive: Boolean) {
                    if (node == null || count >= safeMax || depth > 48 || visited >= 1500) return
                    visited++
                    val isPwd = runCatching { node.isPassword }.getOrDefault(false)
                    val text = runCatching { node.text?.toString() }.getOrNull()
                    val desc = runCatching { node.contentDescription?.toString() }.getOrNull()
                    val hint = runCatching { nodeHintCompat(node) }.getOrNull()
                    val combinedHint = listOfNotNull(desc, hint).joinToString(" ").ifBlank { null }
                    val viewId = runCatching { node.viewIdResourceName }.getOrNull()
                    val sensitive = parentSensitive || SafetyGate.isSensitiveNode(isPwd, text, combinedHint, viewId)
                    val visible = runCatching { node.isVisibleToUser }.getOrDefault(false)
                    val clickable = runCatching { node.isClickable }.getOrDefault(false)
                    val editable = runCatching { node.isEditable }.getOrDefault(false)

                    if (visible && (clickable || editable || !text.isNullOrBlank() || !desc.isNullOrBlank())) {
                        runCatching { node.getBoundsInScreen(rect) }
                        val scrollable = runCatching { node.isScrollable }.getOrDefault(false)
                        val checked = runCatching { node.isChecked }.getOrDefault(false)
                        val focused = runCatching { node.isFocused }.getOrDefault(false)
                        val item = JSONObject()
                            .put("id", "n$count")
                            .put("class", runCatching { node.className?.toString()?.substringAfterLast('.') }.getOrNull() ?: "View")
                            .put("clickable", clickable)
                            .put("editable", editable)
                            .put("sensitive", sensitive)
                        if (scrollable) item.put("scrollable", true)
                        if (checked) item.put("checked", true)
                        if (focused) item.put("focused", true)
                        if (sensitive) {
                            // Omit screen bounds for sensitive nodes so prompt injection cannot target them.
                            item.put("text", "[REDACTED_BY_SAFETY_GATE]")
                        } else {
                            item.put("bounds", JSONArray().put(rect.left).put(rect.top).put(rect.right).put(rect.bottom))
                            if (!text.isNullOrBlank()) item.put("text", text.take(160))
                            if (!desc.isNullOrBlank()) item.put("desc", desc.take(160))
                        }
                        if (!viewId.isNullOrBlank()) {
                            item.put("viewId", viewId.substringAfterLast('/'))
                        }
                        elements.put(item)
                        count++
                    }
                    val childCount = runCatching { node.childCount }.getOrDefault(0)
                    for (i in 0 until childCount) {
                        if (count >= safeMax || visited >= 1500) break
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
                .put("screen", JSONObject()
                    .put("width", sw)
                    .put("height", sh)
                    .put("density", resources.displayMetrics.density.toDouble()))
                .put("elements", elements)
        } finally {
            recycleCompat(root)
        }
    }

    private fun isPointOnSensitiveNode(root: AccessibilityNodeInfo?, x: Int, y: Int): Boolean {
        if (root == null) return true
        val rect = Rect()
        var visited = 0
        var capExceeded = false
        fun walk(node: AccessibilityNodeInfo?, depth: Int, parentSensitive: Boolean): Boolean {
            if (node == null) return false
            if (depth > 48 || visited >= 1500) {
                capExceeded = true
                return true // fail closed when visible tree exceeds safe inspection bounds
            }
            val visible = runCatching { node.isVisibleToUser }.getOrDefault(true)
            if (!visible) return false
            runCatching { node.getBoundsInScreen(rect) }
            if (rect.isEmpty) return false
            // Prune visible subtrees that don't even intersect the tap target (except root container)
            if (depth > 0 && !rect.contains(x, y)) return false
            visited++
            val sensitive = parentSensitive || SafetyGate.isSensitiveNode(
                runCatching { node.isPassword }.getOrDefault(false),
                runCatching { node.text?.toString() }.getOrNull(),
                listOfNotNull(
                    runCatching { node.contentDescription?.toString() }.getOrNull(),
                    runCatching { nodeHintCompat(node) }.getOrNull()
                ).joinToString(" ").ifBlank { null },
                runCatching { node.viewIdResourceName }.getOrNull()
            )
            if (sensitive && rect.contains(x, y)) return true
            val childCount = runCatching { node.childCount }.getOrDefault(0)
            for (i in 0 until childCount) {
                val child = runCatching { node.getChild(i) }.getOrNull() ?: continue
                try {
                    if (walk(child, depth + 1, sensitive)) return true
                } finally {
                    recycleCompat(child)
                }
            }
            return false
        }
        return walk(root, 0, false) || capExceeded
    }

    fun performTap(x: Float, y: Float, userApproved: Boolean = false): JSONObject {
        val blockedMultiWin = findBlockedVisibleWindowPackage(ignoreSelf = false)
        if (blockedMultiWin != null) {
            return JSONObject().put("ok", false).put("blocked", true).put("reason", "blocked_sensitive_package")
        }
        val (cx, cy) = clampPoint(x, y)
        val root = rootInActiveWindow
            ?: return JSONObject().put("ok", false).put("blocked", true).put("reason", "active_window_unavailable_fail_closed")
        val pkg: String?
        val hitsSensitive: Boolean
        try {
            pkg = root.packageName?.toString() ?: lastForegroundPackage
            hitsSensitive = isPointOnSensitiveNode(root, cx.toInt(), cy.toInt())
        } finally {
            recycleCompat(root)
        }
        val decision = SafetyGate.evaluateToolCall("phone_tap", pkg, isSensitiveTarget = hitsSensitive, userApproved = userApproved)
        if (!decision.allowed) {
            return JSONObject().put("ok", false).put("blocked", true).put("reason", decision.reason)
        }
        val path = Path().apply { moveTo(cx, cy) }
        val stroke = GestureDescription.StrokeDescription(path, 0L, 60L)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
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
        val finished = latch.await(1500, TimeUnit.MILLISECONDS)
        val res = JSONObject().put("ok", ok.get()).put("x", cx).put("y", cy)
        if (!ok.get()) {
            res.put("reason", if (!finished) "gesture_timeout" else if (cancelled.get()) "gesture_cancelled" else "gesture_failed")
        }
        return res
    }

    fun performSwipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long = 300L, userApproved: Boolean = false): JSONObject {
        val blockedMultiWin = findBlockedVisibleWindowPackage(ignoreSelf = false)
        if (blockedMultiWin != null) {
            return JSONObject().put("ok", false).put("blocked", true).put("reason", "blocked_sensitive_package")
        }
        val (cx1, cy1) = clampPoint(x1, y1)
        val (cx2, cy2) = clampPoint(x2, y2)
        val root = rootInActiveWindow
            ?: return JSONObject().put("ok", false).put("blocked", true).put("reason", "active_window_unavailable_fail_closed")
        val pkg: String?
        val hitsSensitive: Boolean
        try {
            pkg = root.packageName?.toString() ?: lastForegroundPackage
            hitsSensitive = isPointOnSensitiveNode(root, cx1.toInt(), cy1.toInt()) ||
                isPointOnSensitiveNode(root, cx2.toInt(), cy2.toInt())
        } finally {
            recycleCompat(root)
        }
        val decision = SafetyGate.evaluateToolCall("phone_swipe", pkg, isSensitiveTarget = hitsSensitive, userApproved = userApproved)
        if (!decision.allowed) {
            return JSONObject().put("ok", false).put("blocked", true).put("reason", decision.reason)
        }
        val dur = durationMs.coerceIn(80L, 2000L)
        val path = Path().apply {
            moveTo(cx1, cy1)
            lineTo(cx2, cy2)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0L, dur)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
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
        val finished = latch.await(dur + 1500L, TimeUnit.MILLISECONDS)
        val res = JSONObject().put("ok", ok.get()).put("x1", cx1).put("y1", cy1).put("x2", cx2).put("y2", cy2)
        if (!ok.get()) {
            res.put("reason", if (!finished) "gesture_timeout" else if (cancelled.get()) "gesture_cancelled" else "gesture_failed")
        }
        return res
    }

    fun performSystemAction(action: String, userApproved: Boolean = false): JSONObject {
        val normAction = action.lowercase()
        // Never allow pulling down notification shade (can expose SMS OTPs) unless explicitly allowed.
        if (normAction == "notifications" && SafetyGate.isConfirmHighRisk() && !userApproved) {
            return JSONObject().put("ok", false).put("blocked", true).put("reason", "blocked_notifications_otp_protection")
        }
        val root = rootInActiveWindow
        val fgPkg = try {
            root?.packageName?.toString() ?: lastForegroundPackage
        } finally {
            recycleCompat(root)
        }
        // Always check foreground package against SafetyGate (except `home`, which safely exits any blocked app!).
        val targetForCheck = if (normAction == "home") "system_home" else fgPkg
        val decision = SafetyGate.evaluateToolCall("phone_key", targetForCheck, userApproved = userApproved)
        if (!decision.allowed) {
            return JSONObject().put("ok", false).put("blocked", true).put("reason", decision.reason)
        }
        val globalAction = when (normAction) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            else -> return JSONObject().put("ok", false).put("reason", "unsupported_key_action:$action")
        }
        val ok = performGlobalAction(globalAction)
        return JSONObject().put("ok", ok).put("action", action)
    }

    fun performType(text: String, userApproved: Boolean = false): JSONObject {
        val blockedMultiWin = findBlockedVisibleWindowPackage(ignoreSelf = false)
        if (blockedMultiWin != null) {
            return JSONObject().put("ok", false).put("blocked", true).put("reason", "blocked_sensitive_package")
        }
        val root = rootInActiveWindow
            ?: return JSONObject().put("ok", false).put("blocked", true).put("reason", "active_window_unavailable_fail_closed")
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        try {
            val pkg = root.packageName?.toString() ?: lastForegroundPackage
            val sensitive = focused != null && isNodeOrAncestorsSensitive(focused)
            val decision = SafetyGate.evaluateToolCall("phone_type", pkg, isSensitiveTarget = sensitive, userApproved = userApproved)
            if (!decision.allowed) {
                return JSONObject().put("ok", false).put("blocked", true).put("reason", decision.reason)
            }
            if (focused == null || !focused.isEditable) {
                return JSONObject().put("ok", false).put("reason", "no_editable_field_focused")
            }
            val args = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
            }
            var ok = focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            if (!ok && text.isNotEmpty()) {
                // Fallback for WebView / Compose text inputs that reject ACTION_SET_TEXT:
                // ClipboardManager MUST be accessed on the main Looper thread!
                val clipSet = AtomicBoolean(false)
                val clipLatch = CountDownLatch(1)
                mainHandler.post {
                    runCatching {
                        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                        if (cm != null) {
                            cm.setPrimaryClip(ClipData.newPlainText("grassbag_input", text))
                            clipSet.set(true)
                        }
                    }
                    clipLatch.countDown()
                }
                if (runCatching { clipLatch.await(1500, TimeUnit.MILLISECONDS) }.getOrDefault(false) && clipSet.get()) {
                    ok = runCatching { focused.performAction(AccessibilityNodeInfo.ACTION_PASTE) }.getOrDefault(false)
                }
            }
            return JSONObject().put("ok", ok).put("length", text.length)
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

        /**
         * Check whether Android's AccessibilityManager currently lists our service as actively
         * enabled & bound (vs crashed/malfunctioning).
         */
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

        /**
         * Check whether the user has toggled GrassBag's AccessibilityService ON in Android System Settings,
         * even if the OEM battery manager or an APK reinstall put the service into crashed/unbound state.
         */
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
