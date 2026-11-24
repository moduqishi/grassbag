package dev.grassbag.grassbag

import android.accessibilityservice.AccessibilityService
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.SweepGradient
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Choreographer
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.RoundedCorner
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * Native Android Liquid Glass Phone-Control HUD, Edge Aurora Beam, and Out-of-App Confirmation Card.
 *
 * Uses `TYPE_ACCESSIBILITY_OVERLAY` owned by [GrassBagAccessibilityService] so every HUD capsule,
 * edge glow, and confirmation card renders reliably ON TOP OF ANY APP (even when GrassBag is in the
 * background) without requiring `SYSTEM_ALERT_WINDOW`, while remaining invisible to `TYPE_SYSTEM`
 * self-block checks. Falls back gracefully to `TYPE_APPLICATION_OVERLAY` when Accessibility is not
 * yet bound and the user has granted overlay permission.
 */
class PhoneOverlayController(private val appContext: Context) {

    enum class ConfirmDecision {
        ALLOW_ONCE,
        ALLOW_TURN,
        DENY,
        STOP,
        TIMEOUT,
        UNAVAILABLE
    }

    enum class HandoffDecision {
        CONTINUE,
        STOP,
        TIMEOUT,
        UNAVAILABLE
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val isInjectingGesture = AtomicBoolean(false)
    private val passThrough = AtomicBoolean(false)
    private val hiddenForCapture = AtomicBoolean(false)

    @Volatile
    private var activeService: AccessibilityService? = null

    // Attached overlay views (all accessed exclusively on Main Looper)
    private var beamView: GrassBagEdgeBeamView? = null
    private var beamParams: WindowManager.LayoutParams? = null
    private var hudContainer: FrameLayout? = null
    private var hudParams: WindowManager.LayoutParams? = null
    private var hudLogo: GrassBagOverlayLogoView? = null
    private var hudTitleView: TextView? = null
    private var hudSubView: TextView? = null
    private var hudPauseBtn: TextView? = null
    private var hudStepCount = 0
    private var hudStartedAtMs = 0L
    private var hudCurrentApp = ""
    private var hudActionText = "准备操控"
    private var hudTimerRunning = false
    private var hudAttachedWm: WindowManager? = null
    private var beamAttachedWm: WindowManager? = null

    private var activeConfirmContainer: FrameLayout? = null
    private var activeConfirmWm: WindowManager? = null
    private var activeConfirmTick: Runnable? = null
    private val activeConfirmLatch = AtomicReference<CountDownLatch?>(null)
    private val activeConfirmResult = AtomicReference<Any?>(null)

    private val hudClockTick = object : Runnable {
        override fun run() {
            if (!hudTimerRunning || hudContainer == null) return
            refreshHudSubtitle()
            mainHandler.postDelayed(this, 1000L)
        }
    }

    fun attachService(service: AccessibilityService) {
        activeService = service
    }

    fun detachService(service: AccessibilityService) {
        if (activeService === service) {
            activeService = null
        }
        dismissAll()
    }

    fun setInjectingGesture(injecting: Boolean) {
        isInjectingGesture.set(injecting)
        setPassThrough(injecting)
    }

    fun setPassThrough(enabled: Boolean) {
        passThrough.set(enabled)
        runOnMainSyncOrPost(sync = enabled) {
            val container = hudContainer
            val params = hudParams
            val wm = hudAttachedWm
            if (container != null && params != null && wm != null && container.isAttachedToWindow) {
                params.flags = if (enabled) {
                    params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                } else {
                    params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
                }
                runCatching { wm.updateViewLayout(container, params) }
            }
            beamView?.visibility = if (enabled || hiddenForCapture.get()) View.INVISIBLE else View.VISIBLE
        }
    }

    fun hideForCapture(hidden: Boolean) {
        hiddenForCapture.set(hidden)
        runOnMainSyncOrPost(sync = hidden) {
            val vis = if (hidden) View.INVISIBLE else View.VISIBLE
            hudContainer?.visibility = vis
            beamView?.visibility = if (hidden || passThrough.get()) View.INVISIBLE else View.VISIBLE
            activeConfirmContainer?.visibility = vis
        }
    }

    /**
     * Show or update the Liquid Glass Dynamic Island HUD + Edge Aurora Beam.
     */
    fun showOrUpdateHud(
        actionLabel: String,
        appLabel: String? = null,
        incrementStep: Boolean = true,
        waitingForUser: Boolean = false
    ) {
        mainHandler.post {
            val target = resolveWindowTarget() ?: return@post
            if (hudContainer == null) {
                hudStepCount = 0
                hudStartedAtMs = SystemClock.elapsedRealtime()
                attachBeam(target.first, target.second, target.third)
                attachHudCapsule(target.first, target.second, target.third)
            }
            if (incrementStep) hudStepCount++
            hudActionText = actionLabel
            if (!appLabel.isNullOrBlank()) hudCurrentApp = appLabel
            hudTitleView?.text = actionLabel
            hudLogo?.setMode(
                when {
                    SafetyGate.isPaused() -> GrassBagOverlayLogoView.Mode.PAUSED
                    waitingForUser -> GrassBagOverlayLogoView.Mode.WAITING
                    else -> GrassBagOverlayLogoView.Mode.ACTIVE
                }
            )
            beamView?.setPaused(SafetyGate.isPaused() || waitingForUser)
            refreshHudPauseLabel()
            refreshHudSubtitle()
            if (!hudTimerRunning) {
                hudTimerRunning = true
                mainHandler.postDelayed(hudClockTick, 1000L)
            }
        }
    }

    fun showPreviewDemo(onDone: (() -> Unit)? = null) {
        showOrUpdateHud(actionLabel = "液态玻璃悬浮岛预览", appLabel = "GrassBag 演示", incrementStep = true)
        Thread {
            val res = confirm(
                title = "GrassBag 操控手机预览",
                actionSummary = "在「计算器」中点击「=」并读取屏幕结果",
                appLabel = "计算器",
                allowTurnOption = true,
                timeoutMs = 15_000L
            )
            if (res == ConfirmDecision.STOP) {
                SafetyGate.resetEmergencyStop()
            }
            hideHud()
            onDone?.invoke()
        }.start()
    }

    fun hideHud() {
        mainHandler.post {
            hudTimerRunning = false
            mainHandler.removeCallbacks(hudClockTick)
            val hud = hudContainer
            val hudWm = hudAttachedWm
            hudContainer = null
            hudParams = null
            hudLogo = null
            hudTitleView = null
            hudSubView = null
            hudPauseBtn = null
            hudAttachedWm = null
            if (hud != null && hudWm != null) {
                hud.animate()
                    .alpha(0f)
                    .scaleX(0.88f)
                    .scaleY(0.88f)
                    .translationY(-dp(appContext, 14).toFloat())
                    .setDuration(190L)
                    .setInterpolator(DecelerateInterpolator())
                    .setListener(object : AnimatorListenerAdapter() {
                        override fun onAnimationEnd(animation: Animator) {
                            runCatching { hudWm.removeViewImmediate(hud) }
                        }
                    })
                    .start()
            }
            val beam = beamView
            val beamWm = beamAttachedWm
            beamView = null
            beamParams = null
            beamAttachedWm = null
            if (beam != null && beamWm != null) {
                beam.fadeOutAndDetach {
                    runCatching { beamWm.removeViewImmediate(beam) }
                }
            }
        }
    }

    fun dismissAll() {
        cancelActivePrompt(ConfirmDecision.STOP)
        hideHud()
    }

    fun cancelActivePrompt(reason: Any = ConfirmDecision.STOP) {
        activeConfirmResult.compareAndSet(null, reason)
        activeConfirmLatch.getAndSet(null)?.countDown()
        mainHandler.post { removeActiveConfirmView(animate = true) }
    }

    /**
     * Blocking native out-of-app Liquid Glass confirmation card (called from PhoneControlDaemon worker thread).
     */
    fun confirm(
        title: String = "GrassBag 请求操控手机",
        actionSummary: String,
        appLabel: String? = null,
        riskBadge: String? = null,
        allowTurnOption: Boolean = true,
        timeoutMs: Long = 35_000L
    ): ConfirmDecision {
        val latch = CountDownLatch(1)
        val resultBox = AtomicReference<ConfirmDecision?>(null)
        val shownLatch = CountDownLatch(1)
        val shownOk = AtomicBoolean(false)

        showOrUpdateHud(
            actionLabel = "等你确认操作",
            appLabel = appLabel,
            incrementStep = false,
            waitingForUser = true
        )

        mainHandler.post {
            val target = resolveWindowTarget()
            if (target == null) {
                shownOk.set(false)
                shownLatch.countDown()
                return@post
            }
            removeActiveConfirmView(animate = false)
            activeConfirmLatch.set(latch)
            activeConfirmResult.set(null)

            val (ctx, wm, windowType) = target
            val deadlineMs = SystemClock.elapsedRealtime() + timeoutMs
            val armedAtMs = SystemClock.elapsedRealtime() + 360L

            fun finish(decision: ConfirmDecision) {
                if (resultBox.compareAndSet(null, decision)) {
                    activeConfirmResult.compareAndSet(null, decision)
                    removeActiveConfirmView(animate = true)
                    latch.countDown()
                }
            }

            val card = buildGlassPromptCard(
                ctx = ctx,
                title = title,
                appLabel = appLabel,
                riskBadge = riskBadge,
                actionSummary = actionSummary,
                deadlineMs = deadlineMs,
                totalMs = timeoutMs,
                armedAtMs = armedAtMs,
                isHandoff = false,
                allowTurnOption = allowTurnOption,
                onPrimary = { finish(ConfirmDecision.ALLOW_ONCE) },
                onSecondary = { finish(ConfirmDecision.ALLOW_TURN) },
                onCancel = { finish(ConfirmDecision.DENY) },
                onStop = {
                    SafetyGate.triggerEmergencyStop()
                    finish(ConfirmDecision.STOP)
                    hideHud()
                }
            )

            val params = buildBottomCardParams(ctx, windowType)
            val attached = runCatching {
                wm.addView(card, params)
                activeConfirmContainer = card
                activeConfirmWm = wm
                animateCardEntrance(card)
                true
            }.getOrDefault(false)
            shownOk.set(attached)
            shownLatch.countDown()
        }

        if (!runCatching { shownLatch.await(2000L, TimeUnit.MILLISECONDS) }.getOrDefault(false) || !shownOk.get()) {
            return ConfirmDecision.UNAVAILABLE
        }

        val completed = runCatching { latch.await(timeoutMs, TimeUnit.MILLISECONDS) }.getOrDefault(false)
        mainHandler.post { removeActiveConfirmView(animate = true) }
        val chosen = resultBox.get() ?: (activeConfirmResult.get() as? ConfirmDecision)
        if (chosen != null) return chosen
        return if (!completed) ConfirmDecision.TIMEOUT else ConfirmDecision.DENY
    }

    /**
     * Blocking native out-of-app Liquid Glass handoff card (for passwords, OTPs, payments, manual steps).
     */
    fun handoff(
        message: String,
        appLabel: String? = null,
        timeoutMs: Long = 180_000L
    ): HandoffDecision {
        val latch = CountDownLatch(1)
        val resultBox = AtomicReference<HandoffDecision?>(null)
        val shownLatch = CountDownLatch(1)
        val shownOk = AtomicBoolean(false)

        showOrUpdateHud(
            actionLabel = "需要你来接管",
            appLabel = appLabel,
            incrementStep = false,
            waitingForUser = true
        )

        mainHandler.post {
            val target = resolveWindowTarget()
            if (target == null) {
                shownOk.set(false)
                shownLatch.countDown()
                return@post
            }
            removeActiveConfirmView(animate = false)
            activeConfirmLatch.set(latch)
            activeConfirmResult.set(null)

            val (ctx, wm, windowType) = target
            val deadlineMs = SystemClock.elapsedRealtime() + timeoutMs
            val armedAtMs = SystemClock.elapsedRealtime() + 360L

            fun finish(decision: HandoffDecision) {
                if (resultBox.compareAndSet(null, decision)) {
                    activeConfirmResult.compareAndSet(null, decision)
                    removeActiveConfirmView(animate = true)
                    latch.countDown()
                }
            }

            val card = buildGlassPromptCard(
                ctx = ctx,
                title = "需要你手动完成这一步",
                appLabel = appLabel,
                riskBadge = "安全接管",
                actionSummary = message,
                deadlineMs = deadlineMs,
                totalMs = timeoutMs,
                armedAtMs = armedAtMs,
                isHandoff = true,
                allowTurnOption = false,
                onPrimary = { finish(HandoffDecision.CONTINUE) },
                onSecondary = {},
                onCancel = {
                    SafetyGate.triggerEmergencyStop()
                    finish(HandoffDecision.STOP)
                    hideHud()
                },
                onStop = {
                    SafetyGate.triggerEmergencyStop()
                    finish(HandoffDecision.STOP)
                    hideHud()
                }
            )

            val params = buildBottomCardParams(ctx, windowType)
            val attached = runCatching {
                wm.addView(card, params)
                activeConfirmContainer = card
                activeConfirmWm = wm
                animateCardEntrance(card)
                true
            }.getOrDefault(false)
            shownOk.set(attached)
            shownLatch.countDown()
        }

        if (!runCatching { shownLatch.await(2000L, TimeUnit.MILLISECONDS) }.getOrDefault(false) || !shownOk.get()) {
            return HandoffDecision.UNAVAILABLE
        }
        val completed = runCatching { latch.await(timeoutMs, TimeUnit.MILLISECONDS) }.getOrDefault(false)
        mainHandler.post { removeActiveConfirmView(animate = true) }
        val chosen = resultBox.get() ?: (activeConfirmResult.get() as? HandoffDecision)
        if (chosen != null) return chosen
        return if (!completed) HandoffDecision.TIMEOUT else HandoffDecision.STOP
    }

    // -------------------------------------------------------------------------
    // Window Target Resolution
    // -------------------------------------------------------------------------

    private fun resolveWindowTarget(): Triple<Context, WindowManager, Int>? {
        val svc = activeService ?: GrassBagAccessibilityService.current()
        if (svc != null) {
            val wm = svc.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            if (wm != null) {
                return Triple(svc, wm, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && Settings.canDrawOverlays(appContext)) {
            val wm = appContext.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            if (wm != null) {
                val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                } else {
                    @Suppress("DEPRECATION")
                    WindowManager.LayoutParams.TYPE_PHONE
                }
                return Triple(appContext, wm, type)
            }
        }
        return null
    }

    private fun isDarkPalette(ctx: Context): Boolean {
        val sp = appContext.getSharedPreferences("gb_native_ui_v1", Context.MODE_PRIVATE)
        if (sp.contains("isDark")) {
            return sp.getBoolean("isDark", false)
        }
        return (ctx.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
    }

    // -------------------------------------------------------------------------
    // 1. Edge Aurora Beam
    // -------------------------------------------------------------------------

    private fun attachBeam(ctx: Context, wm: WindowManager, windowType: Int) {
        if (beamView != null) return
        val dark = isDarkPalette(ctx)
        val view = GrassBagEdgeBeamView(ctx, dark)
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setFitInsetsTypes(0)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching {
                val insets = wm.currentWindowMetrics.windowInsets
                val r = maxOf(
                    insets.getRoundedCorner(RoundedCorner.POSITION_TOP_LEFT)?.radius ?: 0,
                    insets.getRoundedCorner(RoundedCorner.POSITION_TOP_RIGHT)?.radius ?: 0,
                    insets.getRoundedCorner(RoundedCorner.POSITION_BOTTOM_LEFT)?.radius ?: 0,
                    insets.getRoundedCorner(RoundedCorner.POSITION_BOTTOM_RIGHT)?.radius ?: 0
                )
                if (r > 0) view.cornerRadiusPx = r.toFloat()
            }
        }
        runCatching {
            wm.addView(view, params)
            beamView = view
            beamParams = params
            beamAttachedWm = wm
            view.startAurora()
        }
    }

    // -------------------------------------------------------------------------
    // 2. Draggable Liquid Glass Dynamic Island HUD Capsule
    // -------------------------------------------------------------------------

    private fun attachHudCapsule(ctx: Context, wm: WindowManager, windowType: Int) {
        val dark = isDarkPalette(ctx)
        val density = ctx.resources.displayMetrics.density

        val container = FrameLayout(ctx).apply {
            clipChildren = false
            clipToPadding = false
            setPadding(dp(ctx, 8), dp(ctx, 6), dp(ctx, 8), dp(ctx, 10))
        }

        val pill = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(ctx, 10), dp(ctx, 8), dp(ctx, 10), dp(ctx, 8))
            background = buildLiquidGlassSurface(
                ctx = ctx,
                dark = dark,
                radiusDp = 999f,
                elevated = true
            )
            elevation = 14f * density
        }

        val logo = GrassBagOverlayLogoView(ctx, dark).apply {
            layoutParams = LinearLayout.LayoutParams(dp(ctx, 32), dp(ctx, 32))
        }
        pill.addView(logo)

        val textCol = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 9), 0, dp(ctx, 10), 0)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        }
        val titleTv = TextView(ctx).apply {
            text = hudActionText
            setTextColor(if (dark) Color.parseColor("#F4F8FC") else Color.parseColor("#111D2C"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            maxWidth = dp(ctx, 162)
        }
        val subTv = TextView(ctx).apply {
            text = "GrassBag 操控中"
            setTextColor(if (dark) Color.parseColor("#A7BACF") else Color.parseColor("#51657C"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            maxWidth = dp(ctx, 162)
        }
        textCol.addView(titleTv)
        textCol.addView(subTv)
        pill.addView(textCol)

        val pauseBtn = TextView(ctx).apply {
            text = "暂停"
            gravity = Gravity.CENTER
            setTextColor(if (dark) Color.parseColor("#E8F2FC") else Color.parseColor("#18324D"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            setPadding(dp(ctx, 11), dp(ctx, 6), dp(ctx, 11), dp(ctx, 6))
            background = GradientDrawable().apply {
                cornerRadius = 999f * density
                setColor(if (dark) Color.parseColor("#2BFFFFFF") else Color.parseColor("#1A1C4E78"))
                setStroke(dp(ctx, 1), if (dark) Color.parseColor("#38FFFFFF") else Color.parseColor("#280F3554"))
            }
            setOnClickListener {
                it.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                val nextPaused = !SafetyGate.isPaused()
                SafetyGate.setPaused(nextPaused)
                hudLogo?.setMode(
                    if (nextPaused) GrassBagOverlayLogoView.Mode.PAUSED
                    else GrassBagOverlayLogoView.Mode.ACTIVE
                )
                beamView?.setPaused(nextPaused)
                refreshHudPauseLabel()
                refreshHudSubtitle()
            }
        }
        pill.addView(pauseBtn, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { marginEnd = dp(ctx, 6) })

        val stopBtn = TextView(ctx).apply {
            text = "急停"
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            setPadding(dp(ctx, 11), dp(ctx, 6), dp(ctx, 11), dp(ctx, 6))
            background = GradientDrawable(
                GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(Color.parseColor("#F05252"), Color.parseColor("#C81E1E"))
            ).apply {
                cornerRadius = 999f * density
                setStroke(dp(ctx, 1), Color.parseColor("#55FFFFFF"))
            }
            setOnClickListener {
                it.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                SafetyGate.triggerEmergencyStop()
                cancelActivePrompt(ConfirmDecision.STOP)
                hideHud()
            }
        }
        pill.addView(stopBtn)

        container.addView(
            pill,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            )
        )

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                (if (passThrough.get()) WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE else 0),
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            x = 0
            y = dp(ctx, 42)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                runCatching { blurBehindRadius = dp(ctx, 18) }
            }
        }

        // Smooth drag-to-reposition + tap-center to return to GrassBag!
        val touchSlop = ViewConfiguration.get(ctx).scaledTouchSlop
        var downRawX = 0f
        var downRawY = 0f
        var startX = 0
        var startY = 0
        var dragged = false
        textCol.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startX = params.x
                    startY = params.y
                    dragged = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY
                    if (!dragged && (abs(dx) > touchSlop || abs(dy) > touchSlop)) {
                        dragged = true
                    }
                    if (dragged) {
                        val dm = ctx.resources.displayMetrics
                        val halfW = (dm.widthPixels / 2 - dp(ctx, 120)).coerceAtLeast(0)
                        params.x = (startX + dx.toInt()).coerceIn(-halfW, halfW)
                        params.y = (startY + dy.toInt()).coerceIn(dp(ctx, 24), dm.heightPixels - dp(ctx, 120))
                        runCatching { wm.updateViewLayout(container, params) }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!dragged) {
                        v.performClick()
                        SafetyGate.setPaused(true)
                        refreshHudPauseLabel()
                        bringGrassBagToFront()
                    } else {
                        // Magnetic snap to center when near horizontal center
                        if (abs(params.x) < dp(ctx, 56)) {
                            val anim = ValueAnimator.ofInt(params.x, 0).apply {
                                duration = 220L
                                interpolator = OvershootInterpolator(1.0f)
                                addUpdateListener {
                                    params.x = it.animatedValue as Int
                                    if (container.isAttachedToWindow) {
                                        runCatching { wm.updateViewLayout(container, params) }
                                    }
                                }
                            }
                            anim.start()
                        }
                    }
                    true
                }
                else -> false
            }
        }

        runCatching {
            wm.addView(container, params)
            hudContainer = container
            hudParams = params
            hudLogo = logo
            hudTitleView = titleTv
            hudSubView = subTv
            hudPauseBtn = pauseBtn
            hudAttachedWm = wm

            // Silky entrance spring
            container.alpha = 0f
            container.scaleX = 0.86f
            container.scaleY = 0.86f
            container.translationY = -dp(ctx, 18).toFloat()
            container.animate()
                .alpha(1f)
                .scaleX(1f)
                .scaleY(1f)
                .translationY(0f)
                .setDuration(280L)
                .setInterpolator(OvershootInterpolator(1.08f))
                .start()
        }
    }

    private fun refreshHudPauseLabel() {
        val paused = SafetyGate.isPaused()
        hudPauseBtn?.text = if (paused) "继续" else "暂停"
    }

    private fun refreshHudSubtitle() {
        val elapsedSec = ((SystemClock.elapsedRealtime() - hudStartedAtMs) / 1000L).coerceAtLeast(0L)
        val mm = elapsedSec / 60L
        val ss = elapsedSec % 60L
        val timeText = String.format("%02d:%02d", mm, ss)
        val appPart = if (hudCurrentApp.isNotBlank()) " · $hudCurrentApp" else ""
        hudSubView?.text = if (SafetyGate.isPaused()) {
            "已暂停 · $timeText$appPart"
        } else {
            val stepPart = if (hudStepCount > 0) "第 $hudStepCount 步 · " else ""
            "$stepPart$timeText$appPart"
        }
    }

    private fun bringGrassBagToFront() {
        runCatching {
            val intent = appContext.packageManager.getLaunchIntentForPackage(appContext.packageName)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            } ?: return
            (activeService ?: appContext).startActivity(intent)
        }
    }

    // -------------------------------------------------------------------------
    // 3. Sculpted Liquid Glass Out-of-App Confirmation & Handoff Card
    // -------------------------------------------------------------------------

    private fun buildBottomCardParams(ctx: Context, windowType: Int): WindowManager.LayoutParams {
        val dm = ctx.resources.displayMetrics
        val cardWidth = min(dm.widthPixels - dp(ctx, 24), dp(ctx, 420))
        return WindowManager.LayoutParams(
            cardWidth,
            WindowManager.LayoutParams.WRAP_CONTENT,
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            x = 0
            y = dp(ctx, 26)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                runCatching { blurBehindRadius = dp(ctx, 28) }
            }
        }
    }

    private fun buildGlassPromptCard(
        ctx: Context,
        title: String,
        appLabel: String?,
        riskBadge: String?,
        actionSummary: String,
        deadlineMs: Long,
        totalMs: Long,
        armedAtMs: Long,
        isHandoff: Boolean,
        allowTurnOption: Boolean,
        onPrimary: () -> Unit,
        onSecondary: () -> Unit,
        onCancel: () -> Unit,
        onStop: () -> Unit
    ): FrameLayout {
        val dark = isDarkPalette(ctx)
        val density = ctx.resources.displayMetrics.density
        val ink = if (dark) Color.parseColor("#F3F7FC") else Color.parseColor("#111D2C")
        val subInk = if (dark) Color.parseColor("#9FB4C9") else Color.parseColor("#54687F")

        val wrapper = FrameLayout(ctx).apply {
            clipChildren = false
            clipToPadding = false
            setPadding(dp(ctx, 4), dp(ctx, 4), dp(ctx, 4), dp(ctx, 8))
        }

        val card = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 18), dp(ctx, 16), dp(ctx, 18), dp(ctx, 16))
            background = buildLiquidGlassSurface(ctx, dark, radiusDp = 28f, elevated = true)
            elevation = 20f * density
            filterTouchesWhenObscured = true
        }

        // Top countdown hairline progress track
        val progressTrack = FrameLayout(ctx).apply {
            background = GradientDrawable().apply {
                cornerRadius = 999f * density
                setColor(if (dark) Color.parseColor("#22FFFFFF") else Color.parseColor("#160F3554"))
            }
        }
        val progressFill = View(ctx).apply {
            background = GradientDrawable(
                GradientDrawable.Orientation.LEFT_RIGHT,
                intArrayOf(Color.parseColor("#2A9DF4"), Color.parseColor("#20C997"))
            ).apply {
                cornerRadius = 999f * density
            }
        }
        progressTrack.addView(
            progressFill,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        card.addView(
            progressTrack,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(ctx, 3)).apply {
                bottomMargin = dp(ctx, 12)
            }
        )

        // Header row: GrassBag Logo + Title + Countdown Pill
        val headerRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val logo = GrassBagOverlayLogoView(ctx, dark).apply {
            setMode(GrassBagOverlayLogoView.Mode.WAITING)
            layoutParams = LinearLayout.LayoutParams(dp(ctx, 32), dp(ctx, 32))
        }
        headerRow.addView(logo)

        val titleCol = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 10), 0, dp(ctx, 8), 0)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        titleCol.addView(TextView(ctx).apply {
            text = title
            setTextColor(ink)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15.5f)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        })
        if (!appLabel.isNullOrBlank() || !riskBadge.isNullOrBlank()) {
            val metaText = listOfNotNull(
                appLabel?.takeIf { it.isNotBlank() }?.let { "目标应用：$it" },
                riskBadge?.takeIf { it.isNotBlank() }
            ).joinToString(" · ")
            titleCol.addView(TextView(ctx).apply {
                text = metaText
                setTextColor(subInk)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            })
        }
        headerRow.addView(titleCol)

        val countdownPill = TextView(ctx).apply {
            setTextColor(if (dark) Color.parseColor("#8AC8FF") else Color.parseColor("#1D649C"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            setPadding(dp(ctx, 9), dp(ctx, 4), dp(ctx, 9), dp(ctx, 4))
            background = GradientDrawable().apply {
                cornerRadius = 999f * density
                setColor(if (dark) Color.parseColor("#24499CF0") else Color.parseColor("#182575B8"))
            }
        }
        headerRow.addView(countdownPill)
        card.addView(headerRow)

        // Human-readable action summary glass well
        val actionWell = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 14), dp(ctx, 12), dp(ctx, 14), dp(ctx, 12))
            background = GradientDrawable().apply {
                cornerRadius = 18f * density
                setColor(if (dark) Color.parseColor("#24FFFFFF") else Color.parseColor("#A8FFFFFF"))
                setStroke(dp(ctx, 1), if (dark) Color.parseColor("#2EFFFFFF") else Color.parseColor("#CCFFFFFF"))
            }
        }
        actionWell.addView(TextView(ctx).apply {
            text = actionSummary
            setTextColor(ink)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14.5f)
            setLineSpacing(0f, 1.32f)
            maxLines = 4
            ellipsize = TextUtils.TruncateAt.END
        })
        card.addView(
            actionWell,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(ctx, 12)
                bottomMargin = dp(ctx, 14)
            }
        )

        // Guarded button factory (anti-hijack: refuses obscured or self-injected touches + 360ms arming!)
        fun makeGuardedButton(
            label: String,
            bgDrawable: GradientDrawable,
            textColor: Int,
            action: () -> Unit
        ): TextView = object : TextView(ctx) {
            private var rejected = false
            init {
                text = label
                gravity = Gravity.CENTER
                setTextColor(textColor)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
                minimumHeight = dp(ctx, 44)
                setPadding(dp(ctx, 12), dp(ctx, 10), dp(ctx, 12), dp(ctx, 10))
                background = bgDrawable
                filterTouchesWhenObscured = true
                isClickable = true
            }

            override fun dispatchTouchEvent(event: MotionEvent): Boolean {
                if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                    val obscured = (event.flags and (MotionEvent.FLAG_WINDOW_IS_OBSCURED or MotionEvent.FLAG_WINDOW_IS_PARTIALLY_OBSCURED)) != 0
                    rejected = SystemClock.elapsedRealtime() < armedAtMs || isInjectingGesture.get() || obscured
                }
                if (rejected) {
                    if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
                        isPressed = false
                    }
                    return true
                }
                return super.dispatchTouchEvent(event)
            }
        }.apply {
            setOnClickListener {
                it.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                action()
            }
        }

        // Primary action row
        val primaryRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        val primaryBg = GradientDrawable(
            GradientDrawable.Orientation.TOP_BOTTOM,
            if (dark) intArrayOf(Color.parseColor("#47A6F5"), Color.parseColor("#2474BA"))
            else intArrayOf(Color.parseColor("#2F8AD8"), Color.parseColor("#1D68A8"))
        ).apply {
            cornerRadius = 999f * density
            setStroke(dp(ctx, 1), Color.parseColor("#55FFFFFF"))
        }
        val primaryBtn = makeGuardedButton(
            label = if (isHandoff) "我已完成，继续" else "允许一次",
            bgDrawable = primaryBg,
            textColor = Color.WHITE,
            action = onPrimary
        )
        primaryRow.addView(primaryBtn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))

        if (!isHandoff && allowTurnOption) {
            val turnBg = GradientDrawable(
                GradientDrawable.Orientation.TOP_BOTTOM,
                if (dark) intArrayOf(Color.parseColor("#30C98E"), Color.parseColor("#1D9B6C"))
                else intArrayOf(Color.parseColor("#2AC589"), Color.parseColor("#1A9B6A"))
            ).apply {
                cornerRadius = 999f * density
                setStroke(dp(ctx, 1), Color.parseColor("#55FFFFFF"))
            }
            val turnBtn = makeGuardedButton(
                label = "本轮允许",
                bgDrawable = turnBg,
                textColor = Color.WHITE,
                action = onSecondary
            )
            primaryRow.addView(
                turnBtn,
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    marginStart = dp(ctx, 8)
                }
            )
        }
        card.addView(primaryRow)

        // Secondary cancel / emergency stop row
        val secondaryRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        val cancelBg = GradientDrawable().apply {
            cornerRadius = 999f * density
            setColor(if (dark) Color.parseColor("#22FFFFFF") else Color.parseColor("#180F3554"))
            setStroke(dp(ctx, 1), if (dark) Color.parseColor("#32FFFFFF") else Color.parseColor("#220F3554"))
        }
        val cancelBtn = makeGuardedButton(
            label = if (isHandoff) "停止任务" else "取消此步",
            bgDrawable = cancelBg,
            textColor = if (isHandoff) Color.parseColor("#F87171") else ink,
            action = onCancel
        )
        secondaryRow.addView(cancelBtn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))

        if (!isHandoff) {
            val stopBg = GradientDrawable().apply {
                cornerRadius = 999f * density
                setColor(if (dark) Color.parseColor("#2CF05252") else Color.parseColor("#1CE03131"))
                setStroke(dp(ctx, 1), Color.parseColor("#55F05252"))
            }
            val stopBtn = makeGuardedButton(
                label = "急停任务",
                bgDrawable = stopBg,
                textColor = if (dark) Color.parseColor("#FCA5A5") else Color.parseColor("#C92A2A"),
                action = onStop
            )
            secondaryRow.addView(
                stopBtn,
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    marginStart = dp(ctx, 8)
                }
            )
        }
        card.addView(
            secondaryRow,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(ctx, 8)
            }
        )

        wrapper.addView(
            card,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            )
        )

        // Live countdown ticker
        val tick = object : Runnable {
            override fun run() {
                if (activeConfirmContainer !== wrapper) return
                val remMs = (deadlineMs - SystemClock.elapsedRealtime()).coerceAtLeast(0L)
                val sec = ((remMs + 999L) / 1000L).toInt()
                countdownPill.text = "${sec}s"
                val frac = (remMs.toFloat() / totalMs.coerceAtLeast(1L).toFloat()).coerceIn(0f, 1f)
                progressFill.scaleX = frac
                progressFill.pivotX = 0f
                if (remMs > 0L) {
                    mainHandler.postDelayed(this, 120L)
                }
            }
        }
        activeConfirmTick = tick
        mainHandler.post(tick)

        return wrapper
    }

    private fun animateCardEntrance(view: View) {
        view.alpha = 0f
        view.translationY = dp(appContext, 36).toFloat()
        view.scaleX = 0.94f
        view.scaleY = 0.94f
        view.animate()
            .alpha(1f)
            .translationY(0f)
            .scaleX(1f)
            .scaleY(1f)
            .setDuration(260L)
            .setInterpolator(OvershootInterpolator(1.04f))
            .start()
    }

    private fun removeActiveConfirmView(animate: Boolean) {
        activeConfirmTick?.let { mainHandler.removeCallbacks(it) }
        activeConfirmTick = null
        val view = activeConfirmContainer ?: return
        val wm = activeConfirmWm ?: return
        activeConfirmContainer = null
        activeConfirmWm = null
        if (!animate) {
            runCatching { wm.removeViewImmediate(view) }
            return
        }
        view.animate()
            .alpha(0f)
            .translationY(dp(appContext, 28).toFloat())
            .scaleX(0.95f)
            .scaleY(0.95f)
            .setDuration(170L)
            .setInterpolator(DecelerateInterpolator())
            .setListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    runCatching { wm.removeViewImmediate(view) }
                }
            })
            .start()
    }

    private fun buildLiquidGlassSurface(
        ctx: Context,
        dark: Boolean,
        radiusDp: Float,
        elevated: Boolean
    ): GradientDrawable {
        val density = ctx.resources.displayMetrics.density
        val colors = if (dark) {
            if (elevated) {
                intArrayOf(Color.parseColor("#E6222E40"), Color.parseColor("#E0182230"))
            } else {
                intArrayOf(Color.parseColor("#D9202B3B"), Color.parseColor("#D417202D"))
            }
        } else {
            if (elevated) {
                intArrayOf(Color.parseColor("#F0F8FCFF"), Color.parseColor("#E6EAF3FC"))
            } else {
                intArrayOf(Color.parseColor("#E6F4F9FE"), Color.parseColor("#DCE6F0FA"))
            }
        }
        return GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, colors).apply {
            cornerRadius = radiusDp * density
            setStroke(
                (1.1f * density).toInt().coerceAtLeast(1),
                if (dark) Color.parseColor("#4C9FC8F0") else Color.parseColor("#E8FFFFFF")
            )
        }
    }

    private fun runOnMainSyncOrPost(sync: Boolean, block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
            return
        }
        if (!sync) {
            mainHandler.post(block)
            return
        }
        val done = CountDownLatch(1)
        mainHandler.post {
            try {
                block()
            } finally {
                done.countDown()
            }
        }
        runCatching { done.await(300L, TimeUnit.MILLISECONDS) }
    }

    private fun dp(ctx: Context, value: Int): Int =
        (ctx.resources.displayMetrics.density * value).toInt()

    // =========================================================================
    // Custom Vector GrassBag Brand Logo View with Orbital Liquid Light Ring
    // =========================================================================

    private class GrassBagOverlayLogoView(
        context: Context,
        private val dark: Boolean
    ) : View(context) {
        enum class Mode { ACTIVE, WAITING, PAUSED }

        private var mode = Mode.ACTIVE
        private var phase = 0f
        private var animator: ValueAnimator? = null

        private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
        }
        private val badgePaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val pouchPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val highlightPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
        }
        private val eyePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
        }
        private val sweepMatrix = Matrix()
        private var sweepShader: SweepGradient? = null

        init {
            startSpin()
        }

        fun setMode(next: Mode) {
            if (mode == next) return
            mode = next
            invalidate()
        }

        private fun startSpin() {
            animator?.cancel()
            animator = ValueAnimator.ofFloat(0f, 360f).apply {
                duration = 2400L
                repeatCount = ValueAnimator.INFINITE
                interpolator = android.view.animation.LinearInterpolator()
                addUpdateListener {
                    phase = it.animatedValue as Float
                    invalidate()
                }
                start()
            }
        }

        override fun onDetachedFromWindow() {
            animator?.cancel()
            animator = null
            super.onDetachedFromWindow()
        }

        override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
            super.onSizeChanged(w, h, oldw, oldh)
            val cx = w / 2f
            val cy = h / 2f
            sweepShader = SweepGradient(
                cx, cy,
                intArrayOf(
                    Color.parseColor("#002A9DF4"),
                    Color.parseColor("#FF38BDF8"),
                    Color.parseColor("#FF20C997"),
                    Color.parseColor("#002A9DF4")
                ),
                floatArrayOf(0f, 0.35f, 0.72f, 1f)
            )
            badgePaint.shader = LinearGradient(
                0f, 0f, w.toFloat(), h.toFloat(),
                if (dark) Color.parseColor("#2A3D58") else Color.parseColor("#DCEBFB"),
                if (dark) Color.parseColor("#1A2738") else Color.parseColor("#C7E1F7"),
                Shader.TileMode.CLAMP
            )
            pouchPaint.shader = LinearGradient(
                w * 0.25f, h * 0.2f, w * 0.78f, h * 0.85f,
                Color.parseColor("#47A6F5"),
                Color.parseColor("#1D6BA8"),
                Shader.TileMode.CLAMP
            )
        }

        override fun onDraw(canvas: Canvas) {
            val w = width.toFloat()
            val h = height.toFloat()
            if (w <= 0f || h <= 0f) return
            val cx = w / 2f
            val cy = h / 2f
            val r = min(w, h) / 2f

            // Soft circular glass backplate
            canvas.drawCircle(cx, cy, r * 0.86f, badgePaint)

            // Animated orbital energy ring around logo
            val ringRadius = r * 0.90f
            ringPaint.strokeWidth = r * 0.13f
            when (mode) {
                Mode.ACTIVE -> {
                    sweepShader?.let { s ->
                        sweepMatrix.setRotate(phase, cx, cy)
                        s.setLocalMatrix(sweepMatrix)
                        ringPaint.shader = s
                    }
                    ringPaint.alpha = 240
                    canvas.drawCircle(cx, cy, ringRadius, ringPaint)
                }
                Mode.WAITING -> {
                    val pulse = (0.55f + 0.45f * sin(Math.toRadians((phase * 2.0))).toFloat())
                    ringPaint.shader = null
                    ringPaint.color = Color.parseColor("#F59E0B")
                    ringPaint.alpha = (pulse * 220f).toInt()
                    canvas.drawCircle(cx, cy, ringRadius, ringPaint)
                }
                Mode.PAUSED -> {
                    ringPaint.shader = null
                    ringPaint.color = if (dark) Color.parseColor("#64748B") else Color.parseColor("#94A3B8")
                    ringPaint.alpha = 160
                    canvas.drawCircle(cx, cy, ringRadius, ringPaint)
                }
            }

            // GrassBag Mascot Pouch Silhouette (twin leaf ears + rounded pouch + expressive eyes!)
            val s = r * 0.56f
            // Left ear
            canvas.save()
            canvas.rotate(-26f, cx - s * 0.18f, cy - s * 0.44f)
            canvas.drawOval(
                RectF(cx - s * 0.36f, cy - s * 0.96f, cx - s * 0.02f, cy - s * 0.34f),
                pouchPaint
            )
            canvas.restore()

            // Right ear
            canvas.save()
            canvas.rotate(26f, cx + s * 0.18f, cy - s * 0.44f)
            canvas.drawOval(
                RectF(cx + s * 0.02f, cy - s * 0.96f, cx + s * 0.36f, cy - s * 0.34f),
                pouchPaint
            )
            canvas.restore()

            // Rounded pouch body
            val bodyRect = RectF(cx - s * 0.72f, cy - s * 0.42f, cx + s * 0.72f, cy + s * 0.78f)
            canvas.drawRoundRect(bodyRect, s * 0.56f, s * 0.56f, pouchPaint)

            // Specular curved glass highlight inside top-left of pouch
            highlightPaint.color = Color.parseColor("#88FFFFFF")
            highlightPaint.strokeWidth = s * 0.13f
            val arcRect = RectF(cx - s * 0.50f, cy - s * 0.24f, cx + s * 0.50f, cy + s * 0.56f)
            canvas.drawArc(arcRect, 200f, 65f, false, highlightPaint)

            // Cute twin capsule eyes
            val eyeW = s * 0.15f
            val eyeH = s * 0.28f
            val eyeY = cy + s * 0.14f
            canvas.drawRoundRect(
                RectF(cx - s * 0.27f - eyeW / 2f, eyeY - eyeH / 2f, cx - s * 0.27f + eyeW / 2f, eyeY + eyeH / 2f),
                eyeW, eyeW, eyePaint
            )
            canvas.drawRoundRect(
                RectF(cx + s * 0.27f - eyeW / 2f, eyeY - eyeH / 2f, cx + s * 0.27f + eyeW / 2f, eyeY + eyeH / 2f),
                eyeW, eyeW, eyePaint
            )
        }
    }

    // =========================================================================
    // Full-Screen Liquid Aurora Edge Beam View (60fps Choreographer)
    // =========================================================================

    private class GrassBagEdgeBeamView(
        context: Context,
        private val dark: Boolean
    ) : View(context) {
        var cornerRadiusPx: Float = 36f * context.resources.displayMetrics.density
        private var paused = false
        private var fade = 0f
        private var targetFade = 1f
        private var phaseDeg = 0f
        private var running = false
        private var lastFrameMs = 0L
        private var onFadedOut: (() -> Unit)? = null

        private val density = context.resources.displayMetrics.density
        private val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 10f * density
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                maskFilter = BlurMaskFilter(9f * density, BlurMaskFilter.Blur.NORMAL)
            }
        }
        private val rimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2.4f * density
        }
        private val borderPath = Path()
        private val sweepMatrix = Matrix()
        private var sweepShader: SweepGradient? = null

        private val frameCallback = object : Choreographer.FrameCallback {
            override fun doFrame(frameTimeNanos: Long) {
                if (!running) return
                val nowMs = frameTimeNanos / 1_000_000L
                val dt = if (lastFrameMs == 0L) 16f else (nowMs - lastFrameMs).coerceIn(1L, 64L).toFloat()
                lastFrameMs = nowMs

                val fadeSpeed = if (targetFade > fade) 0.0045f else 0.006f
                fade = if (fade < targetFade) {
                    (fade + dt * fadeSpeed).coerceAtMost(targetFade)
                } else {
                    (fade - dt * fadeSpeed).coerceAtLeast(targetFade)
                }
                val speedDegPerMs = if (paused) 0.015f else 0.075f
                phaseDeg = (phaseDeg + dt * speedDegPerMs) % 360f
                invalidate()

                if (targetFade == 0f && fade <= 0.01f) {
                    running = false
                    val cb = onFadedOut
                    onFadedOut = null
                    cb?.invoke()
                } else {
                    Choreographer.getInstance().postFrameCallback(this)
                }
            }
        }

        init {
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }

        fun startAurora() {
            targetFade = 1f
            onFadedOut = null
            if (!running) {
                running = true
                lastFrameMs = 0L
                Choreographer.getInstance().postFrameCallback(frameCallback)
            }
        }

        fun setPaused(isPaused: Boolean) {
            paused = isPaused
        }

        fun fadeOutAndDetach(onDone: () -> Unit) {
            targetFade = 0f
            onFadedOut = onDone
            if (!running) {
                onDone()
            }
        }

        override fun onDetachedFromWindow() {
            running = false
            Choreographer.getInstance().removeFrameCallback(frameCallback)
            super.onDetachedFromWindow()
        }

        override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
            super.onSizeChanged(w, h, oldw, oldh)
            if (w <= 0 || h <= 0) return
            val inset = 1.5f * density
            borderPath.reset()
            borderPath.addRoundRect(
                RectF(inset, inset, w - inset, h - inset),
                cornerRadiusPx,
                cornerRadiusPx,
                Path.Direction.CW
            )
            val palette = if (dark) {
                intArrayOf(
                    Color.parseColor("#38BDF8"),
                    Color.parseColor("#20C997"),
                    Color.parseColor("#818CF8"),
                    Color.parseColor("#38BDF8")
                )
            } else {
                intArrayOf(
                    Color.parseColor("#2A8BD8"),
                    Color.parseColor("#18B884"),
                    Color.parseColor("#5C7CFA"),
                    Color.parseColor("#2A8BD8")
                )
            }
            sweepShader = SweepGradient(w / 2f, h / 2f, palette, null)
            glowPaint.shader = sweepShader
            rimPaint.shader = sweepShader
        }

        override fun onDraw(canvas: Canvas) {
            if (fade <= 0.01f || width == 0 || height == 0) return
            sweepShader?.let { s ->
                sweepMatrix.setRotate(phaseDeg, width / 2f, height / 2f)
                s.setLocalMatrix(sweepMatrix)
            }
            val breathe = if (paused) 0.50f else (0.78f + 0.22f * cos(Math.toRadians(phaseDeg * 2.0)).toFloat())
            glowPaint.alpha = (fade * breathe * (if (dark) 128f else 96f)).toInt().coerceIn(0, 255)
            rimPaint.alpha = (fade * breathe * (if (dark) 215f else 175f)).toInt().coerceIn(0, 255)
            canvas.drawPath(borderPath, glowPaint)
            canvas.drawPath(borderPath, rimPaint)
        }
    }

    companion object {
        @Volatile
        private var singleton: PhoneOverlayController? = null

        fun getInstance(context: Context): PhoneOverlayController {
            return singleton ?: synchronized(this) {
                singleton ?: PhoneOverlayController(context.applicationContext).also { singleton = it }
            }
        }
    }
}
