package dev.grassbag.grassbag

import android.accessibilityservice.AccessibilityService
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.ComponentCallbacks
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RadialGradient
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.graphics.SweepGradient
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.TextPaint
import android.text.TextUtils
import android.util.TypedValue
import android.view.Choreographer
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.RoundedCorner
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.animation.LinearInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.graphics.ColorUtils
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.sin

/**
 * Native Android Apple iOS 26/27 Liquid Glass Phone-Control HUD, Interactive Control Card,
 * Docked Edge Bubble, Ambient Aurora Edge Glow, On-Screen Gesture Telemetry FX, and
 * Out-of-App Confirmation / Handoff Cards.
 *
 * Uses `TYPE_ACCESSIBILITY_OVERLAY` owned by [GrassBagAccessibilityService] so every surface
 * renders smoothly over any app (and falls back cleanly to `TYPE_APPLICATION_OVERLAY`).
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

    private enum class HudMode {
        COMPACT,
        EXPANDED,
        DOCKED_LEFT,
        DOCKED_RIGHT
    }

    private data class StepEntry(
        val index: Int,
        val tool: String,
        val action: String,
        val appLabel: String,
        val timeLabel: String
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val gestureInjectRefCount = AtomicInteger(0)
    private val passThrough = AtomicBoolean(false)
    private val captureHideRefCount = AtomicInteger(0)
    private val stepCountAtomic = AtomicInteger(0)
    private val currentAppAtomic = AtomicReference("")
    private val recentSteps = CopyOnWriteArrayList<StepEntry>()
    private val fadingOverlayViews = java.util.Collections.synchronizedSet(mutableSetOf<Pair<WindowManager, View>>())
    private val promptGen = AtomicInteger(0)
    private val timeFmt = SimpleDateFormat("HH:mm:ss", Locale.getDefault())

    @Volatile
    private var activeService: AccessibilityService? = null

    // Ambient edge aurora + live gesture FX canvas (always FLAG_NOT_TOUCHABLE!)
    private var fxCanvasView: GrassBagAmbientAndGestureCanvasView? = null
    private var fxParams: WindowManager.LayoutParams? = null
    private var fxAttachedWm: WindowManager? = null

    // Interactive 3-mode Dynamic Island HUD window
    @Volatile
    private var hudContainer: FrameLayout? = null
    private var hudParams: WindowManager.LayoutParams? = null
    private var hudAttachedWm: WindowManager? = null
    private var hudSnapAnimator: ValueAnimator? = null
    private var hudMode: HudMode = HudMode.COMPACT
    private var hudSavedY: Int = -1
    private var hudLogo: GrassBagOverlayLogoView? = null
    private var hudTitleView: TextView? = null
    private var hudSubView: TextView? = null
    private var hudStatusBadge: TextView? = null
    private var hudPauseBtn: TextView? = null
    private var hudAutoReturnBtn: TextView? = null
    private var hudTimelineContainer: LinearLayout? = null
    private var hudDockBadge: TextView? = null

    private var hudStartedAtMs = 0L
    private var hudPausedAccumMs = 0L
    private var hudPausedSinceMs = 0L
    private var hudActionText = "准备操控手机"
    private var hudCurrentApp = ""
    private var hudWaitingForUser = false
    private var hudCompletedState = false
    private var hudCompletedAlreadyInApp = false
    private var hudCompletedSubtitle = ""
    private var hudTimerRunning = false
    private var pendingHideRunnable: Runnable? = null
    private val completionGen = AtomicInteger(0)
    private var lastHudBadgeKey: String? = null
    private var hudBadgeDrawable: GradientDrawable? = null
    private val previewDemoActive = AtomicBoolean(false)
    private val previewDemoGen = AtomicInteger(0)
    private val hudSessionActiveAtomic = AtomicBoolean(false)
    private var lastUiModeNight: Int =
        appContext.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
    private var configCallbacksRegistered = false
    private val appConfigCallbacks = object : ComponentCallbacks {
        override fun onConfigurationChanged(newConfig: Configuration) {
            this@PhoneOverlayController.onConfigurationChanged()
        }

        override fun onLowMemory() {}
    }

    private data class SafeScreenMetrics(
        val width: Int,
        val height: Int,
        val topInset: Int,
        val bottomInset: Int,
        val leftInset: Int,
        val rightInset: Int
    )

    private fun screenMetrics(ctx: Context, wm: WindowManager?): SafeScreenMetrics {
        val resolvedWm = wm ?: (ctx.getSystemService(Context.WINDOW_SERVICE) as? WindowManager)
        if (resolvedWm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val metrics = runCatching { resolvedWm.currentWindowMetrics }.getOrNull()
            if (metrics != null && metrics.bounds.width() > 0 && metrics.bounds.height() > 0) {
                val insets = runCatching {
                    metrics.windowInsets.getInsetsIgnoringVisibility(
                        WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()
                    )
                }.getOrNull()
                return SafeScreenMetrics(
                    width = metrics.bounds.width(),
                    height = metrics.bounds.height(),
                    topInset = insets?.top ?: systemBarHeightPx(ctx, "status_bar_height", 28),
                    bottomInset = insets?.bottom ?: systemBarHeightPx(ctx, "navigation_bar_height", 24),
                    leftInset = insets?.left ?: 0,
                    rightInset = insets?.right ?: 0
                )
            }
        }
        val dm = ctx.resources.displayMetrics
        return SafeScreenMetrics(
            width = dm.widthPixels.coerceAtLeast(1),
            height = dm.heightPixels.coerceAtLeast(1),
            topInset = systemBarHeightPx(ctx, "status_bar_height", 28),
            bottomInset = systemBarHeightPx(ctx, "navigation_bar_height", 24),
            leftInset = 0,
            rightInset = 0
        )
    }

    private fun ensureConfigCallbacksRegistered() {
        if (!configCallbacksRegistered) {
            configCallbacksRegistered = true
            runCatching { appContext.registerComponentCallbacks(appConfigCallbacks) }
        }
    }

    private fun unregisterConfigCallbacksIfIdle() {
        if (configCallbacksRegistered &&
            hudContainer == null &&
            fxCanvasView == null &&
            activeConfirmContainer == null
        ) {
            configCallbacksRegistered = false
            runCatching { appContext.unregisterComponentCallbacks(appConfigCallbacks) }
        }
    }

    // Out-of-app confirmation / handoff card
    private val promptSerializationLock = Any()
    private val promptStateLock = Any()
    private var activeConfirmContainer: FrameLayout? = null
    private var activeConfirmWm: WindowManager? = null
    private var activeConfirmParams: WindowManager.LayoutParams? = null
    private var activeConfirmTick: Runnable? = null
    private var activeConfirmProgressAnim: Animator? = null
    private val activeConfirmLatch = AtomicReference<CountDownLatch?>(null)
    private val activeConfirmResult = AtomicReference<Any?>(null)

    private val hudClockTick = object : Runnable {
        override fun run() {
            if (!hudTimerRunning || hudContainer == null || SafetyGate.isPaused()) return
            refreshHudTexts()
            mainHandler.postDelayed(this, 1000L)
        }
    }

    fun attachService(service: AccessibilityService) {
        activeService = service
    }

    fun detachService(service: AccessibilityService) {
        if (activeService === service) {
            activeService = null
            dismissAll(immediate = true)
        }
    }

    fun isHudVisible(): Boolean = hudContainer != null

    fun isHudSessionActive(): Boolean = hudSessionActiveAtomic.get()

    fun onConfigurationChanged() {
        mainHandler.post {
            val curNight = appContext.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
            if (curNight != lastUiModeNight) {
                lastUiModeNight = curNight
                refreshVisualPreferences()
            }
            val hud = hudContainer
            val hp = hudParams
            val hwm = hudAttachedWm
            if (hud != null && hp != null && hwm != null && hud.isAttachedToWindow) {
                val m = screenMetrics(hud.context, hwm)
                val safeW = (m.width - m.leftInset - m.rightInset).coerceAtLeast(dp(appContext, 220))
                val minTop = (m.topInset + dp(appContext, 6)).coerceAtLeast(dp(appContext, 24))
                hudSnapAnimator?.cancel()
                hudSnapAnimator = null
                when (hudMode) {
                    HudMode.EXPANDED -> {
                        hp.width = min(safeW - dp(appContext, 22), dp(appContext, 368))
                            .coerceAtLeast(dp(appContext, 220))
                        hp.x = 0
                        hp.y = hp.y.coerceIn(
                            minTop,
                            (m.height - m.bottomInset - dp(appContext, 240)).coerceAtLeast(minTop)
                        )
                    }
                    HudMode.DOCKED_LEFT, HudMode.DOCKED_RIGHT -> {
                        hp.x = if (hudMode == HudMode.DOCKED_LEFT) m.leftInset else m.rightInset
                        hp.y = hp.y.coerceIn(
                            minTop + dp(appContext, 12),
                            (m.height - m.bottomInset - dp(appContext, 100)).coerceAtLeast(minTop + dp(appContext, 12))
                        )
                    }
                    HudMode.COMPACT -> {
                        val halfHud = if (hud.width > 0) hud.width / 2 else dp(appContext, 132)
                        val maxOffsetX = (safeW / 2 - halfHud - dp(appContext, 6)).coerceAtLeast(0)
                        hp.x = hp.x.coerceIn(-maxOffsetX, maxOffsetX)
                        hp.y = hp.y.coerceIn(
                            minTop,
                            (m.height - m.bottomInset - dp(appContext, 100)).coerceAtLeast(minTop)
                        )
                    }
                }
                hudSavedY = hp.y
                runCatching { hwm.updateViewLayout(hud, hp) }
            }
            val confirm = activeConfirmContainer
            val cp = activeConfirmParams
            val cwm = activeConfirmWm
            if (confirm != null && cp != null && cwm != null && confirm.isAttachedToWindow) {
                val m = screenMetrics(confirm.context, cwm)
                val safeW = (m.width - m.leftInset - m.rightInset).coerceAtLeast(dp(appContext, 240))
                cp.width = min(safeW - dp(appContext, 24), dp(appContext, 412))
                if ((cp.gravity and Gravity.TOP) == Gravity.TOP) {
                    val minY = (m.topInset + dp(appContext, 6)).coerceAtLeast(dp(appContext, 24))
                    val maxY = (m.height - m.bottomInset - dp(appContext, 200)).coerceAtLeast(minY)
                    cp.y = cp.y.coerceIn(minY, maxY)
                }
                runCatching { cwm.updateViewLayout(confirm, cp) }
            }
            val fx = fxCanvasView
            val fxWm = fxAttachedWm
            if (fx != null && fxWm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                runCatching {
                    val insets = fxWm.currentWindowMetrics.windowInsets
                    val r = maxOf(
                        insets.getRoundedCorner(RoundedCorner.POSITION_TOP_LEFT)?.radius ?: 0,
                        insets.getRoundedCorner(RoundedCorner.POSITION_TOP_RIGHT)?.radius ?: 0,
                        insets.getRoundedCorner(RoundedCorner.POSITION_BOTTOM_LEFT)?.radius ?: 0,
                        insets.getRoundedCorner(RoundedCorner.POSITION_BOTTOM_RIGHT)?.radius ?: 0
                    )
                    if (r > 0) {
                        fx.cornerRadiusPx = r.toFloat()
                        fx.invalidate()
                    }
                }
            }
        }
    }

    fun currentStepCount(): Int = stepCountAtomic.get()

    fun currentAppLabel(): String = currentAppAtomic.get()

    fun setInjectingGesture(injecting: Boolean) {
        val count = if (injecting) {
            gestureInjectRefCount.incrementAndGet()
        } else {
            gestureInjectRefCount.updateAndGet { cur -> (cur - 1).coerceAtLeast(0) }
        }
        setPassThrough(count > 0)
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
            // IMPORTANT: fxCanvasView ALWAYS has FLAG_NOT_TOUCHABLE | FLAG_NOT_FOCUSABLE,
            // so NEVER hide it during gesture injection (eliminates edge-aurora blinking on every tap/swipe!).
        }
    }

    fun hideForCapture(hidden: Boolean): Boolean {
        val count = if (hidden) {
            captureHideRefCount.incrementAndGet()
        } else {
            captureHideRefCount.updateAndGet { cur -> (cur - 1).coerceAtLeast(0) }
        }
        val shouldHide = count > 0
        val wereAnyVisible = AtomicBoolean(false)
        runOnMainSyncOrPost(sync = shouldHide) {
            if (shouldHide) {
                val pendingFading = synchronized(fadingOverlayViews) {
                    val copy = fadingOverlayViews.toList()
                    fadingOverlayViews.clear()
                    copy
                }
                val anyVis = (hudContainer?.visibility == View.VISIBLE) ||
                    (fxCanvasView?.visibility == View.VISIBLE) ||
                    (activeConfirmContainer?.visibility == View.VISIBLE) ||
                    pendingFading.isNotEmpty()
                wereAnyVisible.set(anyVis)
                for ((wm, view) in pendingFading) {
                    runCatching { view.animate().cancel() }
                    runCatching { view.visibility = View.INVISIBLE }
                    runCatching { if (view.isAttachedToWindow) wm.removeViewImmediate(view) }
                }
            }
            val vis = if (shouldHide) View.INVISIBLE else View.VISIBLE
            hudContainer?.visibility = vis
            fxCanvasView?.visibility = vis
            if (!shouldHide &&
                ((SafetyGate.isShowEdgeAurora() && !SafetyGate.isPaused()) ||
                    fxCanvasView?.hasActiveFx() == true)
            ) {
                fxCanvasView?.startLoop()
            }
            activeConfirmContainer?.visibility = vis
        }
        return wereAnyVisible.get()
    }

    fun refreshVisualPreferences() {
        mainHandler.post {
            val (accentPrimary, accentHi) = resolveAccentColors()
            val dark = isDarkPalette()
            val wantAurora = SafetyGate.isShowEdgeAurora()
            val wantGestureFx = SafetyGate.isShowGestureFx()
            if (!wantAurora && !wantGestureFx) {
                val fx = fxCanvasView
                val fxWm = fxAttachedWm
                fxCanvasView = null
                fxParams = null
                fxAttachedWm = null
                if (fx != null && fxWm != null) {
                    val entry = fxWm to (fx as View)
                    fadingOverlayViews.add(entry)
                    fx.fadeOutAndDetach {
                        fadingOverlayViews.remove(entry)
                        runCatching { if (fx.isAttachedToWindow) fxWm.removeViewImmediate(fx) }
                    }
                }
            } else {
                if (fxCanvasView == null && hudContainer != null) {
                    ensureFxCanvasAttached()
                }
                fxCanvasView?.updateThemeAndPrefs(
                    dark = dark,
                    accentPrimary = accentPrimary,
                    accentHi = accentHi,
                    showAurora = wantAurora,
                    showGestureFx = wantGestureFx
                )
            }
            val target = resolveWindowTarget()
            if (hudContainer != null && target != null) {
                rebuildHudContent(target.first, target.second, hudMode, animateMorph = false)
            } else {
                refreshHudAutoReturnLabel()
            }
        }
    }

    fun syncPausedState(paused: Boolean) {
        mainHandler.post {
            if (hudContainer == null) return@post
            if (paused) {
                if (hudPausedSinceMs == 0L) {
                    hudPausedSinceMs = SystemClock.elapsedRealtime()
                }
                mainHandler.removeCallbacks(hudClockTick)
            } else {
                if (hudPausedSinceMs > 0L) {
                    hudPausedAccumMs += (SystemClock.elapsedRealtime() - hudPausedSinceMs).coerceAtLeast(0L)
                    hudPausedSinceMs = 0L
                }
                if (hudTimerRunning && !hudCompletedState) {
                    mainHandler.removeCallbacks(hudClockTick)
                    mainHandler.postDelayed(hudClockTick, 1000L)
                }
            }
            hudLogo?.setMode(
                when {
                    hudCompletedState -> GrassBagOverlayLogoView.Mode.COMPLETED
                    paused -> GrassBagOverlayLogoView.Mode.PAUSED
                    hudWaitingForUser -> GrassBagOverlayLogoView.Mode.WAITING
                    else -> GrassBagOverlayLogoView.Mode.ACTIVE
                }
            )
            fxCanvasView?.setVisualMode(
                when {
                    hudCompletedState -> GrassBagAmbientAndGestureCanvasView.VisualMode.COMPLETED
                    paused -> GrassBagAmbientAndGestureCanvasView.VisualMode.PAUSED
                    hudWaitingForUser -> GrassBagAmbientAndGestureCanvasView.VisualMode.WAITING
                    else -> GrassBagAmbientAndGestureCanvasView.VisualMode.ACTIVE
                }
            )
            refreshHudPauseLabel()
            refreshHudTexts()
        }
    }

    // -------------------------------------------------------------------------
    // On-Screen Gesture Telemetry FX (Zero-Touch Full-Screen Canvas)
    // -------------------------------------------------------------------------

    fun showTapFx(
        x: Float,
        y: Float,
        label: String? = null,
        isLongPress: Boolean = false,
        durationMs: Long = 65L
    ) {
        if (!SafetyGate.isShowGestureFx()) return
        mainHandler.post {
            ensureFxCanvasAttached()
            fxCanvasView?.emitTap(
                x = x,
                y = y,
                label = label?.takeIf { it.isNotBlank() }?.let {
                    if (isLongPress) "长按「$it」" else "点击「$it」"
                },
                isLongPress = isLongPress,
                holdMs = durationMs
            )
        }
    }

    fun showSwipeFx(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long = 300L) {
        if (!SafetyGate.isShowGestureFx()) return
        mainHandler.post {
            ensureFxCanvasAttached()
            fxCanvasView?.emitSwipe(x1, y1, x2, y2, durationMs)
        }
    }

    fun showTypeFx(previewText: String) {
        if (!SafetyGate.isShowGestureFx()) return
        mainHandler.post {
            ensureFxCanvasAttached()
            val trimmed = previewText.trim()
            if (trimmed.isNotEmpty()) {
                fxCanvasView?.emitTypeBadge("输入「${if (trimmed.length > 22) trimmed.take(22) + "…" else trimmed}」")
            }
        }
    }

    fun showScreenshotPulse() {
        if (!SafetyGate.isShowGestureFx()) return
        mainHandler.post {
            ensureFxCanvasAttached()
            fxCanvasView?.emitShutterPulse()
        }
    }

    // -------------------------------------------------------------------------
    // Dynamic Island HUD Show / Update / Completion Auto-Return
    // -------------------------------------------------------------------------

    fun showOrUpdateHud(
        actionLabel: String,
        appLabel: String? = null,
        incrementStep: Boolean = true,
        waitingForUser: Boolean = false,
        toolName: String = "",
        isPreview: Boolean = false
    ) {
        if (!isPreview && previewDemoActive.getAndSet(false)) {
            previewDemoGen.incrementAndGet()
        }
        val canAttachOverlay = resolveWindowTarget() != null
        // Only real phone-control runs with an attachable window target claim hudSessionActiveAtomic
        // so missing overlay permissions never leave hudSessionActiveAtomic wedged true!
        val startedFreshAtomic = if (isPreview || !canAttachOverlay) {
            false
        } else {
            hudSessionActiveAtomic.compareAndSet(false, true)
        }
        if (startedFreshAtomic) {
            stepCountAtomic.set(0)
        }
        val nextStep = if (incrementStep) stepCountAtomic.incrementAndGet() else stepCountAtomic.get()
        if (!appLabel.isNullOrBlank()) {
            currentAppAtomic.set(appLabel)
        }
        mainHandler.post {
            cancelPendingHide()
            val target = resolveWindowTarget()
            if (target == null) {
                if (startedFreshAtomic) hudSessionActiveAtomic.set(false)
                return@post
            }
            val freshSession = startedFreshAtomic || hudContainer == null || hudCompletedState
            if (freshSession) {
                recentSteps.clear()
                hudStartedAtMs = SystemClock.elapsedRealtime()
                hudPausedAccumMs = 0L
                hudPausedSinceMs = 0L
                hudCompletedState = false
                hudCompletedSubtitle = ""
                hudMode = HudMode.COMPACT
                ensureFxCanvasAttached(target)
                if (hudContainer == null) {
                    attachHudWindow(target.first, target.second, target.third, HudMode.COMPACT)
                } else {
                    rebuildHudContent(target.first, target.second, HudMode.COMPACT, animateMorph = true)
                }
            } else {
                ensureFxCanvasAttached(target)
            }

            hudActionText = actionLabel
            hudWaitingForUser = waitingForUser
            if (!appLabel.isNullOrBlank()) {
                hudCurrentApp = appLabel
            }
            if (incrementStep && actionLabel.isNotBlank()) {
                recentSteps.add(
                    StepEntry(
                        index = nextStep,
                        tool = toolName,
                        action = actionLabel,
                        appLabel = hudCurrentApp,
                        timeLabel = timeFmt.format(Date())
                    )
                )
                while (recentSteps.size > 8) {
                    recentSteps.removeAt(0)
                }
            }

            val logoMode = when {
                SafetyGate.isPaused() -> GrassBagOverlayLogoView.Mode.PAUSED
                waitingForUser -> GrassBagOverlayLogoView.Mode.WAITING
                else -> GrassBagOverlayLogoView.Mode.ACTIVE
            }
            hudLogo?.setMode(logoMode)
            fxCanvasView?.setVisualMode(
                when {
                    SafetyGate.isPaused() -> GrassBagAmbientAndGestureCanvasView.VisualMode.PAUSED
                    waitingForUser -> GrassBagAmbientAndGestureCanvasView.VisualMode.WAITING
                    else -> GrassBagAmbientAndGestureCanvasView.VisualMode.ACTIVE
                }
            )
            animateActionTitleSwap(actionLabel)
            refreshHudPauseLabel()
            refreshHudAutoReturnLabel()
            refreshHudTexts()
            refreshTimelineRows()

            if (!hudTimerRunning) {
                hudTimerRunning = true
                mainHandler.postDelayed(hudClockTick, 1000L)
            }
        }
    }

    /**
     * Celebrates task completion on the Dynamic Island + Edge Aurora and reliably brings
     * GrassBag back to the foreground when [autoReturn] is enabled and user is outside GrassBag.
     */
    fun showCompletionAndReturn(
        summary: String = "",
        reason: String = "completed",
        autoReturn: Boolean = true
    ) {
        hudSessionActiveAtomic.set(false)
        cancelActivePrompt(ConfirmDecision.STOP)
        mainHandler.post {
            cancelPendingHide()
            val isStopped = SafetyGate.isNonSuccessTurnEndReason(reason)
            if (isStopped) {
                hideHud()
                return@post
            }

            val alreadyInGrassBag = MainActivity.isMainActivityResumed
            val willReturn = autoReturn && !alreadyInGrassBag

            // If HUD wasn't attached yet and we're already inside GrassBag, nothing to animate.
            if (hudContainer == null && !willReturn) {
                hideHud()
                return@post
            }

            val target = resolveWindowTarget()
            if (target != null) {
                ensureFxCanvasAttached(target)
                hudCompletedState = true
                hudCompletedAlreadyInApp = alreadyInGrassBag
                hudWaitingForUser = false
                hudActionText = if (willReturn) "操作完成 · 正在返回 GrassBag" else "手机操控已完成"
                val subSummary = summary.trim().take(28)
                hudCompletedSubtitle = when {
                    subSummary.isNotEmpty() -> subSummary
                    alreadyInGrassBag && stepCountAtomic.get() > 0 -> "共执行 ${stepCountAtomic.get()} 步 · 操控已完成"
                    alreadyInGrassBag -> "任务已完成"
                    stepCountAtomic.get() > 0 -> "共执行 ${stepCountAtomic.get()} 步 · 点击立即返回"
                    else -> "轻点悬浮岛立即返回 GrassBag"
                }
                if (hudContainer == null) {
                    hudStartedAtMs = SystemClock.elapsedRealtime()
                    attachHudWindow(target.first, target.second, target.third, HudMode.COMPACT)
                } else {
                    // Always rebuild into the clean completion pill (omitting ▾ / 暂停 / 急停!).
                    rebuildHudContent(target.first, target.second, HudMode.COMPACT, animateMorph = true)
                }
                hudLogo?.setMode(GrassBagOverlayLogoView.Mode.COMPLETED)
                fxCanvasView?.setVisualMode(GrassBagAmbientAndGestureCanvasView.VisualMode.COMPLETED)
                fxCanvasView?.emitCompletionWave()
                animateActionTitleSwap(hudActionText)
                hudSubView?.text = hudCompletedSubtitle
            }

            val finishDelayMs = if (willReturn) 680L else 1250L
            val myCompletionGen = completionGen.incrementAndGet()
            val runnable = Runnable {
                pendingHideRunnable = null
                if (completionGen.get() != myCompletionGen) return@Runnable
                if (willReturn) {
                    bringGrassBagToFrontNow(preferPendingIntent = false)
                    // Defer hideHud() past the 320ms retry so SYSTEM_ALERT_WINDOW BAL exemption remains active
                    // AND try PendingIntent fallback when direct startActivity was silently dropped by OEM BAL!
                    val retryRunnable = Runnable {
                        pendingHideRunnable = null
                        if (completionGen.get() != myCompletionGen) return@Runnable
                        if (!MainActivity.isMainActivityResumed) {
                            bringGrassBagToFrontNow(preferPendingIntent = true)
                        }
                        hideHud()
                    }
                    pendingHideRunnable = retryRunnable
                    mainHandler.postDelayed(retryRunnable, 320L)
                } else {
                    hideHud()
                }
            }
            pendingHideRunnable = runnable
            mainHandler.postDelayed(runnable, finishDelayMs)
        }
    }

    /**
     * Multi-tier BAL-safe bring-to-front:
     * 1. AccessibilityService context (official Android 10-16 BAL exemption)
     * 2. PendingIntent with ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED (API 34+)
     * 3. Direct ApplicationContext launch intent fallback
     */
    fun bringGrassBagToFrontNow(preferPendingIntent: Boolean = false): Boolean {
        val svc = activeService as? GrassBagAccessibilityService ?: GrassBagAccessibilityService.current()
        if (svc != null && svc.bringGrassBagToFront(preferPendingIntent = preferPendingIntent)) {
            return true
        }
        val intent = Intent(appContext, MainActivity::class.java).apply {
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
                (activeService ?: appContext).startActivity(intent)
                true
            }.getOrDefault(false)
            if (directOk) return true
        }

        return runCatching {
            val pi = PendingIntent.getActivity(
                appContext,
                7702,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val opts = ActivityOptions.makeBasic()
                    .setPendingIntentBackgroundActivityStartMode(
                        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                    )
                    .toBundle()
                pi.send(appContext, 0, null, null, null, null, opts)
            } else {
                pi.send()
            }
            true
        }.getOrDefault(false)
    }

    /**
     * Interactive native preview allowing users to experience the 3-mode Liquid Glass Dynamic Island,
     * ambient edge aurora, live tap/swipe/type gesture FX, and confirmation card immediately.
     */
    fun showPreviewDemo(mode: String = "interactive", onDone: (() -> Unit)? = null) {
        // Never allow interactive preview demo to interfere with a real running phone-control turn.
        if (SafetyGate.hasActiveTurn()) {
            onDone?.invoke()
            return
        }
        val myGen = previewDemoGen.incrementAndGet()
        previewDemoActive.set(true)
        Thread {
            try {
                val dm = appContext.resources.displayMetrics
                val w = dm.widthPixels.toFloat().coerceAtLeast(360f)
                val h = dm.heightPixels.toFloat().coerceAtLeast(640f)
                showOrUpdateHud(
                    actionLabel = "打开「计算器」",
                    appLabel = "GrassBag 演示",
                    incrementStep = true,
                    toolName = "phone_open",
                    isPreview = true
                )
                runCatching { Thread.sleep(520L) }
                if (previewDemoGen.get() != myGen) return@Thread
                showOrUpdateHud(
                    actionLabel = "点击「9」",
                    appLabel = "计算器",
                    incrementStep = true,
                    toolName = "phone_tap",
                    isPreview = true
                )
                showTapFx(w * 0.68f, h * 0.56f, label = "9", isLongPress = false)
                runCatching { Thread.sleep(680L) }
                if (previewDemoGen.get() != myGen) return@Thread
                showOrUpdateHud(
                    actionLabel = "上滑浏览结果",
                    appLabel = "计算器",
                    incrementStep = true,
                    toolName = "phone_swipe",
                    isPreview = true
                )
                showSwipeFx(w * 0.50f, h * 0.66f, w * 0.50f, h * 0.36f, durationMs = 360L)
                runCatching { Thread.sleep(720L) }
                if (previewDemoGen.get() != myGen) return@Thread

                if (mode == "gestures") {
                    showTapFx(w * 0.34f, h * 0.50f, label = "长按预览", isLongPress = true, durationMs = 650L)
                    runCatching { Thread.sleep(820L) }
                    if (previewDemoGen.get() != myGen) return@Thread
                    showTypeFx("Hello GrassBag")
                    runCatching { Thread.sleep(950L) }
                    if (previewDemoGen.get() != myGen) return@Thread
                    showCompletionAndReturn(summary = "触控与流光动效演示完成", reason = "completed", autoReturn = false)
                    onDone?.invoke()
                    return@Thread
                }

                if (mode == "expanded") {
                    mainHandler.post {
                        val target = resolveWindowTarget()
                        if (target != null && hudContainer != null && previewDemoGen.get() == myGen) {
                            rebuildHudContent(target.first, target.second, HudMode.EXPANDED, animateMorph = true)
                        }
                    }
                    runCatching { Thread.sleep(6000L) }
                    if (previewDemoGen.get() != myGen) return@Thread
                    hideHud()
                    onDone?.invoke()
                    return@Thread
                }

                val res = confirm(
                    title = "GrassBag 操控手机预览",
                    actionSummary = "在「计算器」中点击「=」并读取屏幕结果（顶部悬浮岛可点击展开、拖动或贴边收起）",
                    appLabel = "计算器",
                    riskBadge = "工作区安全确认",
                    allowTurnOption = true,
                    timeoutMs = 18_000L,
                    isPreview = true
                )
                if (previewDemoGen.get() != myGen) return@Thread
                if (res == ConfirmDecision.STOP) {
                    hideHud()
                } else {
                    showCompletionAndReturn(
                        summary = "演示完成 · 液态玻璃浮岛就绪",
                        reason = "completed",
                        autoReturn = false
                    )
                }
                onDone?.invoke()
            } finally {
                if (previewDemoGen.get() == myGen) {
                    previewDemoActive.set(false)
                }
            }
        }.start()
    }

    fun hideHud(immediate: Boolean = false) {
        hudSessionActiveAtomic.set(false)
        val doHide = {
            cancelPendingHide()
            hudSnapAnimator?.cancel()
            hudSnapAnimator = null
            hudTimerRunning = false
            hudCompletedState = false
            hudCompletedSubtitle = ""
            hudWaitingForUser = false
            mainHandler.removeCallbacks(hudClockTick)

            if (immediate) {
                val pendingFading = synchronized(fadingOverlayViews) {
                    val copy = fadingOverlayViews.toList()
                    fadingOverlayViews.clear()
                    copy
                }
                for ((wm, view) in pendingFading) {
                    runCatching { view.animate().cancel() }
                    runCatching { if (view.isAttachedToWindow) wm.removeViewImmediate(view) }
                }
            }
            val hud = hudContainer
            val hudWm = hudAttachedWm
            val oldHudLp = hudParams
            hudContainer = null
            hudParams = null
            hudAttachedWm = null
            clearHudViewRefs()
            if (hud != null && hudWm != null) {
                hud.animate().cancel()
                if (immediate) {
                    runCatching { hudWm.removeViewImmediate(hud) }
                } else {
                    if (oldHudLp != null) {
                        oldHudLp.flags = oldHudLp.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        runCatching { if (hud.isAttachedToWindow) hudWm.updateViewLayout(hud, oldHudLp) }
                    }
                    val entry = hudWm to (hud as View)
                    fadingOverlayViews.add(entry)
                    hud.animate()
                        .alpha(0f)
                        .scaleX(0.88f)
                        .scaleY(0.88f)
                        .translationY(-dp(appContext, 14).toFloat())
                        .setDuration(200L)
                        .setInterpolator(DecelerateInterpolator())
                        .setListener(object : AnimatorListenerAdapter() {
                            override fun onAnimationEnd(animation: Animator) {
                                fadingOverlayViews.remove(entry)
                                runCatching { if (hud.isAttachedToWindow) hudWm.removeViewImmediate(hud) }
                            }
                        })
                        .start()
                }
            }

            val fx = fxCanvasView
            val fxWm = fxAttachedWm
            fxCanvasView = null
            fxParams = null
            fxAttachedWm = null
            if (fx != null && fxWm != null) {
                if (immediate) {
                    fx.stopImmediately()
                    runCatching { fxWm.removeViewImmediate(fx) }
                } else {
                    val entry = fxWm to (fx as View)
                    fadingOverlayViews.add(entry)
                    fx.fadeOutAndDetach {
                        fadingOverlayViews.remove(entry)
                        runCatching { if (fx.isAttachedToWindow) fxWm.removeViewImmediate(fx) }
                    }
                }
            }
            unregisterConfigCallbacksIfIdle()
        }
        if (immediate && Looper.myLooper() == Looper.getMainLooper()) {
            doHide()
        } else {
            mainHandler.post(doHide)
        }
    }

    fun dismissAll(immediate: Boolean = false) {
        cancelActivePrompt(ConfirmDecision.STOP, immediate = immediate)
        hideHud(immediate = immediate)
    }

    fun cancelActivePrompt(reason: Any = ConfirmDecision.STOP, immediate: Boolean = false) {
        val latchToRelease = synchronized(promptStateLock) {
            promptGen.incrementAndGet()
            activeConfirmResult.compareAndSet(null, reason)
            activeConfirmLatch.getAndSet(null)
        }
        latchToRelease?.countDown()
        if (immediate && Looper.myLooper() == Looper.getMainLooper()) {
            removeActiveConfirmView(animate = false)
        } else {
            mainHandler.post { removeActiveConfirmView(animate = !immediate) }
        }
    }

    // -------------------------------------------------------------------------
    // Blocking Out-of-App Confirmation & Handoff Cards
    // -------------------------------------------------------------------------

    fun confirm(
        title: String = "GrassBag 请求操控手机",
        actionSummary: String,
        appLabel: String? = null,
        riskBadge: String? = null,
        allowTurnOption: Boolean = true,
        timeoutMs: Long = 35_000L,
        isPreview: Boolean = false
    ): ConfirmDecision {
        synchronized(promptSerializationLock) {
            return confirmSerialized(
                title = title,
                actionSummary = actionSummary,
                appLabel = appLabel,
                riskBadge = riskBadge,
                allowTurnOption = allowTurnOption,
                timeoutMs = timeoutMs,
                isPreview = isPreview
            )
        }
    }

    private fun confirmSerialized(
        title: String,
        actionSummary: String,
        appLabel: String?,
        riskBadge: String?,
        allowTurnOption: Boolean,
        timeoutMs: Long,
        isPreview: Boolean
    ): ConfirmDecision {
        if (!isPreview && SafetyGate.isEmergencyStopped()) {
            return ConfirmDecision.STOP
        }
        val myPromptGen = promptGen.incrementAndGet()
        val latch = CountDownLatch(1)
        val resultBox = AtomicReference<ConfirmDecision?>(null)
        val shownLatch = CountDownLatch(1)
        val shownOk = AtomicBoolean(false)
        val cardRef = AtomicReference<FrameLayout?>(null)

        showOrUpdateHud(
            actionLabel = "等待确认操作",
            appLabel = appLabel,
            incrementStep = false,
            waitingForUser = true,
            isPreview = isPreview
        )

        mainHandler.post {
            val prevLatch = synchronized(promptStateLock) {
                if (promptGen.get() != myPromptGen || (!isPreview && SafetyGate.isEmergencyStopped())) {
                    resultBox.compareAndSet(null, ConfirmDecision.STOP)
                    shownOk.set(false)
                    shownLatch.countDown()
                    latch.countDown()
                    return@post
                }
                activeConfirmResult.set(null)
                activeConfirmLatch.getAndSet(latch)
            }
            prevLatch?.countDown()
            val target = resolveWindowTarget()
            if (target == null) {
                synchronized(promptStateLock) { activeConfirmLatch.compareAndSet(latch, null) }
                shownOk.set(false)
                shownLatch.countDown()
                return@post
            }
            removeActiveConfirmView(animate = false)

            val (ctx, wm, windowType) = target
            // Never set FLAG_BLUR_BEHIND on raw WindowManager overlay windows: Android 12+ blurs
            // the entire underlying target app screen instead of just the card bounds!
            val hasBlur = false
            val deadlineMs = SystemClock.elapsedRealtime() + timeoutMs
            val armedAtMs = SystemClock.elapsedRealtime() + 360L

            fun finish(decision: ConfirmDecision) {
                if (resultBox.compareAndSet(null, decision)) {
                    synchronized(promptStateLock) {
                        activeConfirmResult.compareAndSet(null, decision)
                        activeConfirmLatch.compareAndSet(latch, null)
                    }
                    removeActiveConfirmView(animate = true, expectedView = cardRef.get())
                    latch.countDown()
                }
            }

            val (card, startCountdown) = buildGlassPromptCard(
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
                hasBackdropBlur = hasBlur,
                onPrimary = { finish(ConfirmDecision.ALLOW_ONCE) },
                onSecondary = { finish(ConfirmDecision.ALLOW_TURN) },
                onCancel = { finish(ConfirmDecision.DENY) },
                onStop = {
                    if (!isPreview) {
                        SafetyGate.triggerEmergencyStop()
                    } else {
                        previewDemoGen.incrementAndGet()
                        previewDemoActive.set(false)
                    }
                    finish(ConfirmDecision.STOP)
                    hideHud()
                }
            )
            cardRef.set(card)

            val params = buildBottomCardParams(ctx, windowType, atTop = false, hasBlur = hasBlur)
            val attached = runCatching {
                wm.addView(card, params)
                activeConfirmContainer = card
                activeConfirmWm = wm
                activeConfirmParams = params
                ensureConfigCallbacksRegistered()
                startCountdown()
                animateCardEntrance(card)
                true
            }.getOrDefault(false)
            if (!attached) {
                synchronized(promptStateLock) { activeConfirmLatch.compareAndSet(latch, null) }
            }
            shownOk.set(attached)
            shownLatch.countDown()
        }

        if (!runCatching { shownLatch.await(2000L, TimeUnit.MILLISECONDS) }.getOrDefault(false) || !shownOk.get()) {
            promptGen.compareAndSet(myPromptGen, myPromptGen + 1)
            mainHandler.post { removeActiveConfirmView(animate = false, expectedView = cardRef.get()) }
            return resultBox.get() ?: ConfirmDecision.UNAVAILABLE
        }

        val completed = runCatching { latch.await(timeoutMs, TimeUnit.MILLISECONDS) }.getOrDefault(false)
        mainHandler.post { removeActiveConfirmView(animate = true, expectedView = cardRef.get()) }
        val chosen = resultBox.get() ?: (activeConfirmResult.get() as? ConfirmDecision)
        if (chosen != null) return chosen
        return if (!completed) ConfirmDecision.TIMEOUT else ConfirmDecision.DENY
    }

    fun handoff(
        message: String,
        appLabel: String? = null,
        timeoutMs: Long = 180_000L
    ): HandoffDecision {
        synchronized(promptSerializationLock) {
            return handoffSerialized(message = message, appLabel = appLabel, timeoutMs = timeoutMs)
        }
    }

    private fun handoffSerialized(
        message: String,
        appLabel: String?,
        timeoutMs: Long
    ): HandoffDecision {
        if (SafetyGate.isEmergencyStopped()) {
            return HandoffDecision.STOP
        }
        val myPromptGen = promptGen.incrementAndGet()
        val latch = CountDownLatch(1)
        val resultBox = AtomicReference<HandoffDecision?>(null)
        val shownLatch = CountDownLatch(1)
        val shownOk = AtomicBoolean(false)
        val cardRef = AtomicReference<FrameLayout?>(null)

        showOrUpdateHud(
            actionLabel = "请手动完成此步",
            appLabel = appLabel,
            incrementStep = false,
            waitingForUser = true
        )

        mainHandler.post {
            val prevLatch = synchronized(promptStateLock) {
                if (promptGen.get() != myPromptGen || SafetyGate.isEmergencyStopped()) {
                    resultBox.compareAndSet(null, HandoffDecision.STOP)
                    shownOk.set(false)
                    shownLatch.countDown()
                    latch.countDown()
                    return@post
                }
                activeConfirmResult.set(null)
                activeConfirmLatch.getAndSet(latch)
            }
            prevLatch?.countDown()
            val target = resolveWindowTarget()
            if (target == null) {
                synchronized(promptStateLock) { activeConfirmLatch.compareAndSet(latch, null) }
                shownOk.set(false)
                shownLatch.countDown()
                return@post
            }
            removeActiveConfirmView(animate = false)

            val (ctx, wm, windowType) = target
            val hasBlur = false
            val deadlineMs = SystemClock.elapsedRealtime() + timeoutMs
            val armedAtMs = SystemClock.elapsedRealtime() + 360L

            fun finish(decision: HandoffDecision) {
                if (resultBox.compareAndSet(null, decision)) {
                    synchronized(promptStateLock) {
                        activeConfirmResult.compareAndSet(null, decision)
                        activeConfirmLatch.compareAndSet(latch, null)
                    }
                    removeActiveConfirmView(animate = true, expectedView = cardRef.get())
                    latch.countDown()
                }
            }

            val (card, startCountdown) = buildGlassPromptCard(
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
                hasBackdropBlur = hasBlur,
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
            cardRef.set(card)

            // Position handoff card cleanly near the top below the HUD so it NEVER covers
            // the soft keyboard while the user types passwords / 2FA codes, and let the user
            // vertically drag the grabber/header if it sits over a login or SMS input!
            val params = buildBottomCardParams(ctx, windowType, atTop = true, hasBlur = hasBlur)
            card.findViewWithTag<View>("prompt_drag_area")
                ?.setOnTouchListener(createVerticalDragListener(ctx, wm, card, params, saveHudY = false))
            val attached = runCatching {
                wm.addView(card, params)
                activeConfirmContainer = card
                activeConfirmWm = wm
                activeConfirmParams = params
                ensureConfigCallbacksRegistered()
                startCountdown()
                animateCardEntrance(card)
                true
            }.getOrDefault(false)
            if (!attached) {
                synchronized(promptStateLock) { activeConfirmLatch.compareAndSet(latch, null) }
            }
            shownOk.set(attached)
            shownLatch.countDown()
        }

        if (!runCatching { shownLatch.await(2000L, TimeUnit.MILLISECONDS) }.getOrDefault(false) || !shownOk.get()) {
            promptGen.compareAndSet(myPromptGen, myPromptGen + 1)
            mainHandler.post { removeActiveConfirmView(animate = false, expectedView = cardRef.get()) }
            return resultBox.get() ?: HandoffDecision.UNAVAILABLE
        }
        val completed = runCatching { latch.await(timeoutMs, TimeUnit.MILLISECONDS) }.getOrDefault(false)
        mainHandler.post { removeActiveConfirmView(animate = true, expectedView = cardRef.get()) }
        val chosen = resultBox.get() ?: (activeConfirmResult.get() as? HandoffDecision)
        if (chosen != null) return chosen
        return if (!completed) HandoffDecision.TIMEOUT else HandoffDecision.STOP
    }

    // -------------------------------------------------------------------------
    // Window Target & Theme Sync
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

    private fun isDarkPalette(): Boolean {
        val sp = appContext.getSharedPreferences("gb_native_ui_v1", Context.MODE_PRIVATE)
        val systemDark = (appContext.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        val followSystem = sp.getBoolean("followSystemTheme", !sp.contains("isDark"))
        return if (followSystem) systemDark else sp.getBoolean("isDark", systemDark)
    }

    private fun resolveAccentColors(): Pair<Int, Int> {
        val sp = appContext.getSharedPreferences("gb_native_ui_v1", Context.MODE_PRIVATE)
        val dark = isDarkPalette()
        val defaultPrimary = if (dark) Color.parseColor("#54AAE8") else Color.parseColor("#2A78B5")
        val defaultHi = if (dark) Color.parseColor("#84C6F5") else Color.parseColor("#4D9CD6")
        val p = sp.getInt("accentPrimary", defaultPrimary)
        val hi = sp.getInt("accentHi", defaultHi)
        return p to hi
    }

    private fun cancelPendingHide() {
        completionGen.incrementAndGet()
        pendingHideRunnable?.let { mainHandler.removeCallbacks(it) }
        pendingHideRunnable = null
    }

    private fun clearHudViewRefs() {
        hudLogo = null
        hudTitleView = null
        hudSubView = null
        hudStatusBadge = null
        lastHudBadgeKey = null
        hudBadgeDrawable = null
        hudPauseBtn = null
        hudAutoReturnBtn = null
        hudTimelineContainer = null
        hudDockBadge = null
    }

    // -------------------------------------------------------------------------
    // 1. Unified Edge Aurora + Live Gesture FX Canvas
    // -------------------------------------------------------------------------

    private fun ensureFxCanvasAttached(preResolved: Triple<Context, WindowManager, Int>? = null) {
        if (fxCanvasView != null) return
        if (activeConfirmContainer != null) return
        if (!SafetyGate.isShowEdgeAurora() && !SafetyGate.isShowGestureFx()) return
        val target = preResolved ?: resolveWindowTarget() ?: return
        val (ctx, wm, windowType) = target
        val dark = isDarkPalette()
        val (accentPrimary, accentHi) = resolveAccentColors()
        val view = GrassBagAmbientAndGestureCanvasView(
            context = ctx,
            dark = dark,
            accentPrimary = accentPrimary,
            accentHi = accentHi,
            showAurora = SafetyGate.isShowEdgeAurora(),
            showGestureFx = SafetyGate.isShowGestureFx()
        )
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
            fxCanvasView = view
            fxParams = params
            fxAttachedWm = wm
            ensureConfigCallbacksRegistered()
            view.startLoop()
        }
    }

    // -------------------------------------------------------------------------
    // 2. Three-Mode Morphing Liquid Glass Dynamic Island HUD
    // -------------------------------------------------------------------------

    private fun attachHudWindow(ctx: Context, wm: WindowManager, windowType: Int, mode: HudMode) {
        val m = screenMetrics(ctx, wm)
        val safeTopY = (m.topInset + dp(ctx, 8)).coerceAtLeast(dp(ctx, 28))
        val maxY = (m.height - m.bottomInset - dp(ctx, 120)).coerceAtLeast(safeTopY)
        val container = FrameLayout(ctx).apply {
            clipChildren = false
            clipToPadding = false
            setPadding(dp(ctx, 8), dp(ctx, 6), dp(ctx, 8), dp(ctx, 10))
        }
        // Never set FLAG_BLUR_BEHIND on raw WindowManager overlay windows: Android 12+ blurs
        // the entire underlying screen behind the window instead of just the HUD capsule!
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
            y = (if (hudSavedY >= safeTopY) hudSavedY else safeTopY).coerceIn(safeTopY, maxY)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
            }
        }

        hudContainer = container
        hudParams = params
        hudAttachedWm = wm
        hudMode = mode

        populateHudContent(ctx, wm, container, params, mode)

        runCatching {
            wm.addView(container, params)
            ensureConfigCallbacksRegistered()
            container.alpha = 0f
            container.scaleX = 0.84f
            container.scaleY = 0.84f
            container.translationY = -dp(ctx, 20).toFloat()
            container.animate()
                .alpha(1f)
                .scaleX(1f)
                .scaleY(1f)
                .translationY(0f)
                .setDuration(300L)
                .setInterpolator(OvershootInterpolator(1.06f))
                .start()
        }.onFailure {
            hudContainer = null
            hudParams = null
            hudAttachedWm = null
            clearHudViewRefs()
        }
    }

    private fun rebuildHudContent(ctx: Context, wm: WindowManager, nextMode: HudMode, animateMorph: Boolean) {
        val container = hudContainer ?: return
        val params = hudParams ?: return
        val attachedWm = hudAttachedWm ?: wm
        hudSnapAnimator?.cancel()
        hudSnapAnimator = null
        hudMode = nextMode
        val m = screenMetrics(ctx, attachedWm)
        val safeW = (m.width - m.leftInset - m.rightInset).coerceAtLeast(dp(ctx, 220))
        val safeTopY = (m.topInset + dp(ctx, 8)).coerceAtLeast(dp(ctx, 28))
        when (nextMode) {
            HudMode.COMPACT -> {
                val minY = safeTopY
                val maxY = (m.height - m.bottomInset - dp(ctx, 120)).coerceAtLeast(minY)
                params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                params.width = WindowManager.LayoutParams.WRAP_CONTENT
                params.x = 0
                params.y = (if (hudSavedY >= minY) hudSavedY else safeTopY).coerceIn(minY, maxY)
                container.setPadding(dp(ctx, 8), dp(ctx, 6), dp(ctx, 8), dp(ctx, 10))
            }
            HudMode.EXPANDED -> {
                val minY = safeTopY
                val maxY = (m.height * 0.45f).toInt().coerceAtLeast(minY)
                params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                params.width = min(safeW - dp(ctx, 22), dp(ctx, 368)).coerceAtLeast(dp(ctx, 220))
                params.x = 0
                params.y = (if (hudSavedY >= minY) hudSavedY else safeTopY).coerceIn(minY, maxY)
                container.setPadding(dp(ctx, 6), dp(ctx, 6), dp(ctx, 6), dp(ctx, 10))
            }
            HudMode.DOCKED_LEFT -> {
                val minY = safeTopY + dp(ctx, 12)
                val maxY = (m.height - m.bottomInset - dp(ctx, 120)).coerceAtLeast(minY)
                // Use physical Gravity.LEFT/RIGHT so flat bezel edge stays flush on RTL locales too.
                @Suppress("RtlHardcoded")
                params.gravity = Gravity.TOP or Gravity.LEFT
                params.width = WindowManager.LayoutParams.WRAP_CONTENT
                params.x = m.leftInset
                params.y = (if (hudSavedY >= minY) hudSavedY else (m.height * 0.24f).toInt())
                    .coerceIn(minY, maxY)
                container.setPadding(0, dp(ctx, 4), dp(ctx, 6), dp(ctx, 6))
            }
            HudMode.DOCKED_RIGHT -> {
                val minY = safeTopY + dp(ctx, 12)
                val maxY = (m.height - m.bottomInset - dp(ctx, 120)).coerceAtLeast(minY)
                @Suppress("RtlHardcoded")
                params.gravity = Gravity.TOP or Gravity.RIGHT
                params.width = WindowManager.LayoutParams.WRAP_CONTENT
                params.x = m.rightInset
                params.y = (if (hudSavedY >= minY) hudSavedY else (m.height * 0.24f).toInt())
                    .coerceIn(minY, maxY)
                container.setPadding(dp(ctx, 6), dp(ctx, 4), 0, dp(ctx, 6))
            }
        }
        container.removeAllViews()
        clearHudViewRefs()
        populateHudContent(ctx, attachedWm, container, params, nextMode)
        if (container.isAttachedToWindow) {
            runCatching { attachedWm.updateViewLayout(container, params) }
        }
        if (animateMorph) {
            container.scaleX = 0.91f
            container.scaleY = 0.91f
            container.alpha = 0.72f
            container.animate()
                .scaleX(1f)
                .scaleY(1f)
                .alpha(1f)
                .setDuration(240L)
                .setInterpolator(OvershootInterpolator(1.04f))
                .start()
        }
    }

    private fun populateHudContent(
        ctx: Context,
        wm: WindowManager,
        container: FrameLayout,
        params: WindowManager.LayoutParams,
        mode: HudMode
    ) {
        when (mode) {
            HudMode.COMPACT -> buildCompactIslandView(ctx, wm, container, params)
            HudMode.EXPANDED -> buildExpandedControlCard(ctx, wm, container, params)
            HudMode.DOCKED_LEFT, HudMode.DOCKED_RIGHT -> buildDockedBubbleView(ctx, wm, container, params, mode == HudMode.DOCKED_LEFT)
        }
        refreshHudPauseLabel()
        refreshHudAutoReturnLabel()
        refreshHudTexts()
        refreshTimelineRows()
    }

    private fun currentLogoMode(): GrassBagOverlayLogoView.Mode = when {
        hudCompletedState -> GrassBagOverlayLogoView.Mode.COMPLETED
        SafetyGate.isPaused() -> GrassBagOverlayLogoView.Mode.PAUSED
        hudWaitingForUser -> GrassBagOverlayLogoView.Mode.WAITING
        else -> GrassBagOverlayLogoView.Mode.ACTIVE
    }

    private fun buildCompactIslandView(
        ctx: Context,
        wm: WindowManager,
        container: FrameLayout,
        params: WindowManager.LayoutParams
    ) {
        val dark = isDarkPalette()
        val (accentPrimary, accentHi) = resolveAccentColors()
        val density = ctx.resources.displayMetrics.density

        val pill = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(ctx, 9), dp(ctx, 7), dp(ctx, 9), dp(ctx, 7))
            background = LiquidGlassDrawable(
                ctx = ctx,
                dark = dark,
                radiusDp = 999f,
                accentTint = accentPrimary,
                elevated = true,
                hasBackdropBlur = false
            )
            elevation = 16f * density
        }

        val logo = GrassBagOverlayLogoView(ctx, dark, accentPrimary, accentHi).apply {
            setMode(currentLogoMode())
            layoutParams = LinearLayout.LayoutParams(dp(ctx, 34), dp(ctx, 34))
        }
        pill.addView(logo)

        val centerBox = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 9), 0, dp(ctx, 9), 0)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        }
        val titleRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val titleTv = TextView(ctx).apply {
            text = hudActionText
            setTextColor(if (dark) Color.parseColor("#F5F9FF") else Color.parseColor("#0F1E2E"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            maxWidth = dp(ctx, if (hudCompletedState) 196 else 152)
        }
        titleRow.addView(titleTv)
        if (!hudCompletedState) {
            val expandHint = TextView(ctx).apply {
                text = " ▾"
                setTextColor(if (dark) Color.parseColor("#9AB3CC") else Color.parseColor("#546B82"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            }
            titleRow.addView(expandHint)
        }

        val subTv = TextView(ctx).apply {
            setTextColor(if (dark) Color.parseColor("#A3B8CE") else Color.parseColor("#51667B"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            maxWidth = dp(ctx, if (hudCompletedState) 210 else 166)
        }
        centerBox.addView(titleRow)
        centerBox.addView(subTv)
        pill.addView(centerBox)

        var pauseBtnRef: TextView? = null
        if (hudCompletedState) {
            val doneLabel = if (hudCompletedAlreadyInApp) "完成" else "返回"
            val doneBtn = makeTactilePillButton(
                ctx = ctx,
                label = doneLabel,
                textColor = Color.WHITE,
                bgDrawable = GradientDrawable(
                    GradientDrawable.Orientation.TOP_BOTTOM,
                    intArrayOf(Color.parseColor("#22B87A"), Color.parseColor("#14915C"))
                ).apply {
                    cornerRadius = 999f * density
                    setStroke((0.8f * density).toInt().coerceAtLeast(1), Color.parseColor("#55FFFFFF"))
                },
                hPadDp = 12,
                vPadDp = 6,
                textSp = 11.5f
            ) {
                cancelPendingHide()
                if (!hudCompletedAlreadyInApp) {
                    bringGrassBagToFrontNow()
                }
                hideHud()
            }
            pill.addView(doneBtn)
        } else {
            val pauseBtn = makeTactilePillButton(
                ctx = ctx,
                label = if (SafetyGate.isPaused()) "继续" else "暂停",
                textColor = if (dark) Color.parseColor("#EBF4FF") else Color.parseColor("#16314A"),
                bgDrawable = GradientDrawable().apply {
                    cornerRadius = 999f * density
                    setColor(if (dark) Color.parseColor("#2AFFFFFF") else Color.parseColor("#1614395C"))
                    setStroke((0.8f * density).toInt().coerceAtLeast(1), if (dark) Color.parseColor("#38FFFFFF") else Color.parseColor("#220F3554"))
                },
                hPadDp = 12,
                vPadDp = 9,
                textSp = 11.8f,
                minHeightDp = 40
            ) {
                togglePauseFromOverlay()
            }
            pauseBtnRef = pauseBtn
            pill.addView(
                pauseBtn,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { marginEnd = dp(ctx, 8) }
            )

            val stopBtn = makeTactilePillButton(
                ctx = ctx,
                label = "急停",
                textColor = Color.WHITE,
                bgDrawable = GradientDrawable(
                    GradientDrawable.Orientation.TOP_BOTTOM,
                    intArrayOf(Color.parseColor("#F05252"), Color.parseColor("#C92A2A"))
                ).apply {
                    cornerRadius = 999f * density
                    setStroke((0.8f * density).toInt().coerceAtLeast(1), Color.parseColor("#55FFFFFF"))
                },
                hPadDp = 12,
                vPadDp = 9,
                textSp = 11.8f,
                minHeightDp = 40,
                longPressHaptic = true
            ) {
                triggerStopFromOverlay()
            }
            pill.addView(stopBtn)
        }

        container.addView(
            pill,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            )
        )

        hudLogo = logo
        hudTitleView = titleTv
        hudSubView = subTv
        hudPauseBtn = pauseBtnRef

        // Smooth drag anywhere + edge-snap dock + tap to expand live control card (or immediately dismiss/return if completed!)
        val dragListener = createCompactDragTouchListener(ctx, wm, container, params) {
            if (hudCompletedState) {
                cancelPendingHide()
                if (!hudCompletedAlreadyInApp) {
                    bringGrassBagToFrontNow()
                }
                hideHud()
            } else {
                rebuildHudContent(ctx, wm, HudMode.EXPANDED, animateMorph = true)
            }
        }
        logo.setOnTouchListener(dragListener)
        centerBox.setOnTouchListener(dragListener)
    }

    private fun buildExpandedControlCard(
        ctx: Context,
        wm: WindowManager,
        container: FrameLayout,
        params: WindowManager.LayoutParams
    ) {
        val dark = isDarkPalette()
        val (accentPrimary, accentHi) = resolveAccentColors()
        val density = ctx.resources.displayMetrics.density
        val ink = if (dark) Color.parseColor("#F4F8FD") else Color.parseColor("#102030")
        val subInk = if (dark) Color.parseColor("#9DB3C9") else Color.parseColor("#54697F")

        val card = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 15), dp(ctx, 13), dp(ctx, 15), dp(ctx, 14))
            background = LiquidGlassDrawable(
                ctx = ctx,
                dark = dark,
                radiusDp = 28f,
                accentTint = accentPrimary,
                elevated = true,
                hasBackdropBlur = false
            )
            elevation = 22f * density
        }

        // Top drag handle bar
        val handle = View(ctx).apply {
            background = GradientDrawable().apply {
                cornerRadius = 999f * density
                setColor(if (dark) Color.parseColor("#44FFFFFF") else Color.parseColor("#2A132C44"))
            }
        }
        card.addView(
            handle,
            LinearLayout.LayoutParams(dp(ctx, 36), dp(ctx, 4)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(ctx, 10)
            }
        )

        // Header Row: Logo + Title/Status + Dock & Collapse pills
        val headerRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val logo = GrassBagOverlayLogoView(ctx, dark, accentPrimary, accentHi).apply {
            setMode(currentLogoMode())
            layoutParams = LinearLayout.LayoutParams(dp(ctx, 34), dp(ctx, 34))
        }
        headerRow.addView(logo)

        val headTextCol = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 10), 0, dp(ctx, 8), 0)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val titleTv = TextView(ctx).apply {
            text = hudActionText
            setTextColor(ink)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14.5f)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        val subLine = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(ctx, 2), 0, 0)
        }
        val statusBadge = TextView(ctx).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            setPadding(dp(ctx, 7), dp(ctx, 1), dp(ctx, 7), dp(ctx, 1))
        }
        val subTv = TextView(ctx).apply {
            setTextColor(subInk)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        subLine.addView(
            statusBadge,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { marginEnd = dp(ctx, 6) }
        )
        subLine.addView(subTv)
        headTextCol.addView(titleTv)
        headTextCol.addView(subLine)
        headerRow.addView(headTextCol)

        val dockBtn = makeTactilePillButton(
            ctx = ctx,
            label = "贴边",
            textColor = subInk,
            bgDrawable = GradientDrawable().apply {
                cornerRadius = 999f * density
                setColor(if (dark) Color.parseColor("#20FFFFFF") else Color.parseColor("#B5F1F6FC"))
                setStroke(
                    (0.75f * density).toInt().coerceAtLeast(1),
                    if (dark) Color.parseColor("#32FFFFFF") else Color.parseColor("#2214395C")
                )
            },
            hPadDp = 10,
            vPadDp = 7,
            textSp = 11.2f,
            minHeightDp = 36
        ) {
            rebuildHudContent(ctx, wm, HudMode.DOCKED_RIGHT, animateMorph = true)
        }
        headerRow.addView(
            dockBtn,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { marginEnd = dp(ctx, 6) }
        )

        val collapseBtn = makeTactilePillButton(
            ctx = ctx,
            label = "收起",
            textColor = subInk,
            bgDrawable = GradientDrawable().apply {
                cornerRadius = 999f * density
                setColor(if (dark) Color.parseColor("#20FFFFFF") else Color.parseColor("#B5F1F6FC"))
                setStroke(
                    (0.75f * density).toInt().coerceAtLeast(1),
                    if (dark) Color.parseColor("#32FFFFFF") else Color.parseColor("#2214395C")
                )
            },
            hPadDp = 10,
            vPadDp = 7,
            textSp = 11.2f,
            minHeightDp = 36
        ) {
            rebuildHudContent(ctx, wm, HudMode.COMPACT, animateMorph = true)
        }
        headerRow.addView(collapseBtn)
        card.addView(headerRow)

        // Live Step Timeline Glass Well (concentric: 28dp outer - 15dp padding = 13dp)
        val timelineWell = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 12), dp(ctx, 10), dp(ctx, 12), dp(ctx, 10))
            background = GradientDrawable().apply {
                cornerRadius = 13f * density
                setColor(if (dark) Color.parseColor("#18FFFFFF") else Color.parseColor("#C2FFFFFF"))
                setStroke(
                    (0.75f * density).toInt().coerceAtLeast(1),
                    if (dark) Color.parseColor("#28FFFFFF") else Color.parseColor("#2014395C")
                )
            }
        }
        card.addView(
            timelineWell,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(ctx, 11)
                bottomMargin = dp(ctx, 11)
            }
        )

        // Control Row 1: Pause/Resume + Return to GrassBag
        val row1 = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
        val pauseBtn = makeTactilePillButton(
            ctx = ctx,
            label = if (SafetyGate.isPaused()) "继续操控" else "暂停操控",
            textColor = ink,
            bgDrawable = GradientDrawable().apply {
                cornerRadius = 999f * density
                setColor(if (dark) Color.parseColor("#26FFFFFF") else Color.parseColor("#C8F1F6FC"))
                setStroke(
                    (0.8f * density).toInt().coerceAtLeast(1),
                    if (dark) Color.parseColor("#38FFFFFF") else Color.parseColor("#2414395C")
                )
            },
            hPadDp = 12,
            vPadDp = 9,
            textSp = 12.5f
        ) {
            togglePauseFromOverlay()
        }
        row1.addView(pauseBtn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))

        val returnMid = blendColor(accentHi, accentPrimary, 0.5f)
        val returnInk = if (ColorUtils.calculateLuminance(returnMid) > 0.36) Color.parseColor("#0A1A2A") else Color.WHITE
        val returnBtn = makeTactilePillButton(
            ctx = ctx,
            label = "返回 GrassBag",
            textColor = returnInk,
            bgDrawable = GradientDrawable(
                GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(accentHi, accentPrimary)
            ).apply {
                cornerRadius = 999f * density
                setStroke((0.85f * density).toInt().coerceAtLeast(1), Color.parseColor("#55FFFFFF"))
            },
            hPadDp = 12,
            vPadDp = 9,
            textSp = 12.5f
        ) {
            rebuildHudContent(ctx, wm, HudMode.COMPACT, animateMorph = false)
            bringGrassBagToFrontNow()
        }
        row1.addView(
            returnBtn,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginStart = dp(ctx, 8)
            }
        )
        card.addView(row1)

        // Control Row 2: Auto-Return Quick Toggle + Emergency Stop
        val row2 = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
        val autoReturnBtn = makeTactilePillButton(
            ctx = ctx,
            label = "",
            textColor = subInk,
            bgDrawable = GradientDrawable().apply {
                cornerRadius = 999f * density
                setColor(if (dark) Color.parseColor("#1AFFFFFF") else Color.parseColor("#1214395C"))
                setStroke((0.75f * density).toInt().coerceAtLeast(1), if (dark) Color.parseColor("#2CFFFFFF") else Color.parseColor("#1E14395C"))
            },
            hPadDp = 10,
            vPadDp = 8,
            textSp = 11.5f
        ) {
            val next = !SafetyGate.isAutoReturnEnabled()
            SafetyGate.setAutoReturnEnabled(next)
            refreshHudAutoReturnLabel()
        }
        row2.addView(autoReturnBtn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.35f))

        val stopBtn = makeTactilePillButton(
            ctx = ctx,
            label = "急停任务",
            textColor = if (dark) Color.parseColor("#FCA5A5") else Color.parseColor("#C92A2A"),
            bgDrawable = GradientDrawable().apply {
                cornerRadius = 999f * density
                setColor(if (dark) Color.parseColor("#2EF05252") else Color.parseColor("#1AE03131"))
                setStroke((0.8f * density).toInt().coerceAtLeast(1), Color.parseColor("#55F05252"))
            },
            hPadDp = 10,
            vPadDp = 8,
            textSp = 11.5f,
            longPressHaptic = true
        ) {
            triggerStopFromOverlay()
        }
        row2.addView(
            stopBtn,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 0.85f).apply {
                marginStart = dp(ctx, 8)
            }
        )
        card.addView(
            row2,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(ctx, 8) }
        )

        container.addView(
            card,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            )
        )

        hudLogo = logo
        hudTitleView = titleTv
        hudSubView = subTv
        hudStatusBadge = statusBadge
        hudPauseBtn = pauseBtn
        hudAutoReturnBtn = autoReturnBtn
        hudTimelineContainer = timelineWell

        // Drag handle / header vertically repositions expanded card
        val dragHead = createVerticalDragListener(ctx, wm, container, params)
        handle.setOnTouchListener(dragHead)
        headTextCol.setOnTouchListener(dragHead)
    }

    private fun buildDockedBubbleView(
        ctx: Context,
        wm: WindowManager,
        container: FrameLayout,
        params: WindowManager.LayoutParams,
        dockedLeft: Boolean
    ) {
        val dark = isDarkPalette()
        val (accentPrimary, accentHi) = resolveAccentColors()
        val density = ctx.resources.displayMetrics.density

        val bubble = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(
                dp(ctx, if (dockedLeft) 8 else 10),
                dp(ctx, 7),
                dp(ctx, if (dockedLeft) 10 else 8),
                dp(ctx, 7)
            )
            val radii = if (dockedLeft) {
                floatArrayOf(0f, 0f, 999f * density, 999f * density, 999f * density, 999f * density, 0f, 0f)
            } else {
                floatArrayOf(999f * density, 999f * density, 0f, 0f, 0f, 0f, 999f * density, 999f * density)
            }
            background = LiquidGlassDrawable(
                ctx = ctx,
                dark = dark,
                customRadiiPx = radii,
                accentTint = accentPrimary,
                elevated = true,
                dockedEdge = if (dockedLeft) -1 else 1,
                hasBackdropBlur = false
            )
            elevation = 16f * density
        }

        val logo = GrassBagOverlayLogoView(ctx, dark, accentPrimary, accentHi).apply {
            setMode(currentLogoMode())
            layoutParams = LinearLayout.LayoutParams(dp(ctx, 32), dp(ctx, 32))
        }
        val badge = TextView(ctx).apply {
            setTextColor(if (dark) Color.parseColor("#EBF4FF") else Color.parseColor("#16314A"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            gravity = Gravity.CENTER
            minWidth = dp(ctx, 20)
            setPadding(dp(ctx, 6), dp(ctx, 2), dp(ctx, 6), dp(ctx, 2))
            background = GradientDrawable().apply {
                cornerRadius = 999f * density
                setColor(withAlpha(if (dark) accentHi else accentPrimary, if (dark) 54 else 30))
            }
        }
        val badgeLp = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply {
            if (dockedLeft) marginStart = dp(ctx, 5) else marginEnd = dp(ctx, 5)
        }
        if (dockedLeft) {
            bubble.addView(logo)
            bubble.addView(badge, badgeLp)
        } else {
            bubble.addView(badge, badgeLp)
            bubble.addView(logo)
        }

        container.addView(
            bubble,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            )
        )

        hudLogo = logo
        hudDockBadge = badge

        // Tap bubble to expand back into Compact Dynamic Island; drag vertically or toward center to undock!
        val touchSlop = ViewConfiguration.get(ctx).scaledTouchSlop
        var downX = 0f
        var downY = 0f
        var startY = 0
        var dragged = false
        bubble.setOnTouchListener { v, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = ev.rawX
                    downY = ev.rawY
                    startY = params.y
                    dragged = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = ev.rawX - downX
                    val dy = ev.rawY - downY
                    if (!dragged && (abs(dx) > touchSlop || abs(dy) > touchSlop)) {
                        dragged = true
                    }
                    if (dragged) {
                        val m = screenMetrics(ctx, wm)
                        val minY = (m.topInset + dp(ctx, 14)).coerceAtLeast(dp(ctx, 40))
                        val maxY = (m.height - m.bottomInset - dp(ctx, 110)).coerceAtLeast(minY)
                        params.y = (startY + dy.toInt()).coerceIn(minY, maxY)
                        hudSavedY = params.y
                        val inwardPull = if (dockedLeft) dx.coerceAtLeast(0f) else (-dx).coerceAtLeast(0f)
                        val maxNudge = dp(ctx, 22).toFloat()
                        val damped = (inwardPull * 0.38f).coerceIn(0f, maxNudge)
                        bubble.translationX = if (dockedLeft) damped else -damped
                        runCatching { wm.updateViewLayout(container, params) }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    val pulledIn = if (dockedLeft) (ev.rawX - downX) > dp(ctx, 46) else (downX - ev.rawX) > dp(ctx, 46)
                    if (!dragged || pulledIn) {
                        bubble.translationX = 0f
                        v.performClick()
                        v.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                        rebuildHudContent(ctx, wm, HudMode.COMPACT, animateMorph = true)
                    } else if (bubble.translationX != 0f) {
                        bubble.animate()
                            .translationX(0f)
                            .setDuration(180L)
                            .setInterpolator(OvershootInterpolator(1.08f))
                            .start()
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    if (bubble.translationX != 0f) {
                        bubble.animate().translationX(0f).setDuration(150L).start()
                    }
                    true
                }
                else -> false
            }
        }
    }

    private fun createCompactDragTouchListener(
        ctx: Context,
        wm: WindowManager,
        container: FrameLayout,
        params: WindowManager.LayoutParams,
        onTap: () -> Unit
    ): View.OnTouchListener {
        val touchSlop = ViewConfiguration.get(ctx).scaledTouchSlop
        var downRawX = 0f
        var downRawY = 0f
        var startX = 0
        var startY = 0
        var dragged = false
        return View.OnTouchListener { v, event ->
            val glassBg = container.getChildAt(0)?.background as? LiquidGlassDrawable
            val localX = event.x + v.left.toFloat()
            val localY = event.y + v.top.toFloat()
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    hudSnapAnimator?.cancel()
                    hudSnapAnimator = null
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startX = params.x
                    startY = params.y
                    dragged = false
                    glassBg?.setTouchHighlight(localX, localY, 1f)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY
                    if (!dragged && (abs(dx) > touchSlop || abs(dy) > touchSlop)) {
                        dragged = true
                    }
                    glassBg?.setTouchHighlight(localX, localY, 1f)
                    if (dragged) {
                        val m = screenMetrics(ctx, wm)
                        val safeW = (m.width - m.leftInset - m.rightInset).coerceAtLeast(dp(ctx, 220))
                        val halfHud = if (container.width > 0) container.width / 2 else dp(ctx, 132)
                        val maxOffsetX = (safeW / 2 - halfHud - dp(ctx, 6)).coerceAtLeast(0)
                        val minY = (m.topInset + dp(ctx, 6)).coerceAtLeast(dp(ctx, 24))
                        val maxY = (m.height - m.bottomInset - dp(ctx, 100)).coerceAtLeast(minY)
                        params.x = (startX + dx.toInt()).coerceIn(-maxOffsetX, maxOffsetX)
                        params.y = (startY + dy.toInt()).coerceIn(minY, maxY)
                        hudSavedY = params.y
                        runCatching { wm.updateViewLayout(container, params) }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    glassBg?.fadeOutTouchHighlight()
                    if (!dragged) {
                        v.performClick()
                        v.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                        onTap()
                    } else {
                        val m = screenMetrics(ctx, wm)
                        val edgeThreshold = dp(ctx, 42)
                        if (!hudCompletedState && event.rawX < m.leftInset + edgeThreshold) {
                            v.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                            rebuildHudContent(ctx, wm, HudMode.DOCKED_LEFT, animateMorph = true)
                        } else if (!hudCompletedState && event.rawX > m.width - m.rightInset - edgeThreshold) {
                            v.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                            rebuildHudContent(ctx, wm, HudMode.DOCKED_RIGHT, animateMorph = true)
                        } else if (abs(params.x) < dp(ctx, 64)) {
                            hudSnapAnimator?.cancel()
                            hudSnapAnimator = ValueAnimator.ofInt(params.x, 0).apply {
                                duration = 240L
                                interpolator = OvershootInterpolator(1.05f)
                                addUpdateListener {
                                    params.x = it.animatedValue as Int
                                    if (container.isAttachedToWindow) {
                                        runCatching { wm.updateViewLayout(container, params) }
                                    }
                                }
                                start()
                            }
                        }
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    glassBg?.fadeOutTouchHighlight()
                    true
                }
                else -> false
            }
        }
    }

    private fun createVerticalDragListener(
        ctx: Context,
        wm: WindowManager,
        container: FrameLayout,
        params: WindowManager.LayoutParams,
        saveHudY: Boolean = true
    ): View.OnTouchListener {
        val touchSlop = ViewConfiguration.get(ctx).scaledTouchSlop
        var downY = 0f
        var startY = 0
        var dragged = false
        return View.OnTouchListener { _, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downY = ev.rawY
                    startY = params.y
                    dragged = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dy = ev.rawY - downY
                    if (!dragged && abs(dy) > touchSlop) dragged = true
                    if (dragged) {
                        val m = screenMetrics(ctx, wm)
                        val minY = (m.topInset + dp(ctx, 6)).coerceAtLeast(dp(ctx, 24))
                        val maxY = (m.height - m.bottomInset - dp(ctx, 220)).coerceAtLeast(minY)
                        params.y = (startY + dy.toInt()).coerceIn(minY, maxY)
                        if (saveHudY) hudSavedY = params.y
                        runCatching { wm.updateViewLayout(container, params) }
                    }
                    true
                }
                else -> true
            }
        }
    }

    private fun togglePauseFromOverlay() {
        if (hudCompletedState) return
        val nextPaused = !SafetyGate.isPaused()
        SafetyGate.setPaused(nextPaused)
        syncPausedState(nextPaused)
    }

    private fun triggerStopFromOverlay() {
        if (hudCompletedState) return
        if (previewDemoActive.get() && !SafetyGate.hasActiveTurn()) {
            previewDemoGen.incrementAndGet()
            previewDemoActive.set(false)
            cancelActivePrompt(ConfirmDecision.STOP)
            hideHud()
            return
        }
        previewDemoGen.incrementAndGet()
        previewDemoActive.set(false)
        SafetyGate.triggerEmergencyStop()
        cancelActivePrompt(ConfirmDecision.STOP)
        hideHud()
    }

    private fun animateActionTitleSwap(nextText: String) {
        val tv = hudTitleView ?: return
        if (tv.text?.toString() == nextText) return
        tv.animate().cancel()
        tv.alpha = 0.25f
        tv.translationY = dp(appContext, 4).toFloat()
        tv.text = nextText
        tv.animate()
            .alpha(1f)
            .translationY(0f)
            .setDuration(180L)
            .setInterpolator(DecelerateInterpolator())
            .start()
    }

    private fun refreshHudPauseLabel() {
        val paused = SafetyGate.isPaused()
        hudPauseBtn?.text = when (hudMode) {
            HudMode.EXPANDED -> if (paused) "继续操控" else "暂停操控"
            else -> if (paused) "继续" else "暂停"
        }
    }

    private fun refreshHudAutoReturnLabel() {
        val btn = hudAutoReturnBtn ?: return
        val on = SafetyGate.isAutoReturnEnabled()
        val dark = isDarkPalette()
        val (accentPrimary, accentHi) = resolveAccentColors()
        btn.text = if (on) "完后返回：开" else "完后返回：关"
        btn.setTextColor(
            if (on) (if (dark) accentHi else accentPrimary)
            else (if (dark) Color.parseColor("#9DB3C9") else Color.parseColor("#54697F"))
        )
    }

    private fun refreshHudTexts() {
        val nowMs = if (hudPausedSinceMs > 0L) hudPausedSinceMs else SystemClock.elapsedRealtime()
        val elapsedSec = ((nowMs - hudStartedAtMs - hudPausedAccumMs) / 1000L).coerceAtLeast(0L)
        val timeText = String.format(Locale.US, "%02d:%02d", elapsedSec / 60L, elapsedSec % 60L)
        val steps = stepCountAtomic.get()
        val appPart = if (hudCurrentApp.isNotBlank()) " · $hudCurrentApp" else ""

        hudDockBadge?.text = if (steps > 0) "$steps" else "●"

        if (hudCompletedState) {
            if (hudCompletedSubtitle.isNotEmpty()) {
                hudSubView?.text = hudCompletedSubtitle
            }
        } else {
            hudSubView?.text = when {
                SafetyGate.isPaused() -> "已暂停 · $timeText$appPart"
                hudWaitingForUser -> "等待确认 · $timeText$appPart"
                else -> {
                    val stepPart = if (steps > 0) "第 $steps 步 · " else ""
                    "$stepPart$timeText$appPart"
                }
            }
        }

        val badge = hudStatusBadge
        if (badge != null) {
            val dark = isDarkPalette()
            val (accentPrimary, accentHi) = resolveAccentColors()
            val statusState = when {
                hudCompletedState -> "done"
                SafetyGate.isPaused() -> "paused"
                hudWaitingForUser -> "waiting"
                else -> "active"
            }
            val badgeKey = "$statusState:$dark:$accentPrimary"
            if (badgeKey != lastHudBadgeKey) {
                lastHudBadgeKey = badgeKey
                val density = appContext.resources.displayMetrics.density
                val (label, fg, bg) = when (statusState) {
                    "done" -> Triple(
                        "已完成",
                        if (dark) Color.parseColor("#5CE0A4") else Color.parseColor("#188A56"),
                        if (dark) Color.parseColor("#2A22C55E") else Color.parseColor("#1C188A56")
                    )
                    "paused" -> Triple(
                        "已暂停",
                        if (dark) Color.parseColor("#CBD5E1") else Color.parseColor("#475569"),
                        if (dark) Color.parseColor("#2494A3B8") else Color.parseColor("#1864748B")
                    )
                    "waiting" -> Triple(
                        "待确认",
                        if (dark) Color.parseColor("#FBBF24") else Color.parseColor("#B45309"),
                        if (dark) Color.parseColor("#2CF59E0B") else Color.parseColor("#1CE68A00")
                    )
                    else -> Triple(
                        "操控中",
                        if (dark) accentHi else accentPrimary,
                        withAlpha(if (dark) accentHi else accentPrimary, if (dark) 38 else 26)
                    )
                }
                badge.text = label
                badge.setTextColor(fg)
                val drawable = hudBadgeDrawable ?: GradientDrawable().also {
                    it.cornerRadius = 999f * density
                    hudBadgeDrawable = it
                }
                drawable.setColor(bg)
                if (badge.background !== drawable) {
                    badge.background = drawable
                }
            }
        }
    }

    private fun refreshTimelineRows() {
        val well = hudTimelineContainer ?: return
        val ctx = well.context
        val dark = isDarkPalette()
        val (accentPrimary, accentHi) = resolveAccentColors()
        val ink = if (dark) Color.parseColor("#EBF3FC") else Color.parseColor("#16283B")
        val muted = if (dark) Color.parseColor("#8FA6BE") else Color.parseColor("#5F748A")

        well.removeAllViews()
        val slice = recentSteps.toList().takeLast(4)
        if (slice.isEmpty()) {
            well.addView(TextView(ctx).apply {
                text = "正在准备执行手机操控步骤…"
                setTextColor(muted)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            })
            return
        }
        slice.forEachIndexed { idx, entry ->
            val isLatest = idx == slice.lastIndex
            val row = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, dp(ctx, if (idx == 0) 0 else 5), 0, 0)
            }
            val dot = TextView(ctx).apply {
                text = if (isLatest && !hudCompletedState) "●" else "✓"
                setTextColor(
                    when {
                        isLatest && !hudCompletedState -> if (dark) accentHi else accentPrimary
                        else -> if (dark) Color.parseColor("#4ADE80") else Color.parseColor("#1B945B")
                    }
                )
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                typeface = Typeface.DEFAULT_BOLD
                setPadding(0, 0, dp(ctx, 7), 0)
            }
            val label = TextView(ctx).apply {
                text = "${entry.index}. ${entry.action}"
                setTextColor(if (isLatest) ink else muted)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, if (isLatest) 12.5f else 11.5f)
                typeface = if (isLatest) Typeface.create("sans-serif-medium", Typeface.BOLD) else Typeface.DEFAULT
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            val meta = TextView(ctx).apply {
                text = if (entry.appLabel.isNotBlank()) "${entry.appLabel} · ${entry.timeLabel}" else entry.timeLabel
                setTextColor(muted)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
                maxLines = 1
                setPadding(dp(ctx, 6), 0, 0, 0)
            }
            row.addView(dot)
            row.addView(label)
            row.addView(meta)
            well.addView(row)
        }
    }

    private fun makeTactilePillButton(
        ctx: Context,
        label: String,
        textColor: Int,
        bgDrawable: Drawable,
        hPadDp: Int,
        vPadDp: Int,
        textSp: Float,
        minHeightDp: Int = 0,
        longPressHaptic: Boolean = false,
        onClick: () -> Unit
    ): TextView {
        return TextView(ctx).apply {
            text = label
            gravity = Gravity.CENTER
            setTextColor(textColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, textSp)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            setPadding(dp(ctx, hPadDp), dp(ctx, vPadDp), dp(ctx, hPadDp), dp(ctx, vPadDp))
            if (minHeightDp > 0) {
                minHeight = dp(ctx, minHeightDp)
                minimumHeight = dp(ctx, minHeightDp)
            }
            background = bgDrawable
            isClickable = true
            setOnTouchListener { v, ev ->
                when (ev.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        v.animate().scaleX(0.93f).scaleY(0.93f).setDuration(90L).start()
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        v.animate().scaleX(1f).scaleY(1f).setDuration(140L).setInterpolator(OvershootInterpolator(1.1f)).start()
                    }
                }
                false
            }
            setOnClickListener {
                it.performHapticFeedback(
                    if (longPressHaptic) HapticFeedbackConstants.LONG_PRESS else HapticFeedbackConstants.VIRTUAL_KEY
                )
                onClick()
            }
        }
    }

    // -------------------------------------------------------------------------
    // 3. Sculpted Liquid Glass Out-of-App Confirmation & Handoff Card
    // -------------------------------------------------------------------------

    private fun systemBarHeightPx(ctx: Context, name: String, fallbackDp: Int): Int {
        val resId = ctx.resources.getIdentifier(name, "dimen", "android")
        return if (resId > 0) ctx.resources.getDimensionPixelSize(resId) else dp(ctx, fallbackDp)
    }

    private fun withAlpha(color: Int, alpha: Int): Int =
        Color.argb(alpha.coerceIn(0, 255), Color.red(color), Color.green(color), Color.blue(color))

    private fun blendColor(from: Int, to: Int, ratio: Float): Int {
        val t = ratio.coerceIn(0f, 1f)
        val inv = 1f - t
        return Color.argb(
            (Color.alpha(from) * inv + Color.alpha(to) * t).toInt().coerceIn(0, 255),
            (Color.red(from) * inv + Color.red(to) * t).toInt().coerceIn(0, 255),
            (Color.green(from) * inv + Color.green(to) * t).toInt().coerceIn(0, 255),
            (Color.blue(from) * inv + Color.blue(to) * t).toInt().coerceIn(0, 255)
        )
    }

    private fun buildBottomCardParams(
        ctx: Context,
        windowType: Int,
        atTop: Boolean = false,
        hasBlur: Boolean = false
    ): WindowManager.LayoutParams {
        val m = screenMetrics(ctx, null)
        val safeW = (m.width - m.leftInset - m.rightInset).coerceAtLeast(dp(ctx, 240))
        val dark = isDarkPalette()
        val cardWidth = min(safeW - dp(ctx, 24), dp(ctx, 412))
        // Keep the underlying target app 100% crisp & readable during confirmation so the user can
        // verify the exact UI element before approving (NO FLAG_BLUR_BEHIND full-screen blur!).
        var flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        if (!atTop) {
            flags = flags or WindowManager.LayoutParams.FLAG_DIM_BEHIND
        }
        return WindowManager.LayoutParams(
            cardWidth,
            WindowManager.LayoutParams.WRAP_CONTENT,
            windowType,
            flags,
            PixelFormat.TRANSLUCENT
        ).apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
            }
            if (!atTop) {
                dimAmount = if (dark) 0.24f else 0.12f
            }
            if (atTop) {
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                x = 0
                y = m.topInset + dp(ctx, 88)
            } else {
                gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                x = 0
                y = m.bottomInset + dp(ctx, 20)
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
        hasBackdropBlur: Boolean = false,
        onPrimary: () -> Unit,
        onSecondary: () -> Unit,
        onCancel: () -> Unit,
        onStop: () -> Unit
    ): Pair<FrameLayout, () -> Unit> {
        val dark = isDarkPalette()
        val (accentPrimary, accentHi) = resolveAccentColors()
        val density = ctx.resources.displayMetrics.density
        val ink = if (dark) Color.parseColor("#F5F9FF") else Color.parseColor("#0E1E2E")
        val subInk = if (dark) Color.parseColor("#9EB4CA") else Color.parseColor("#54697F")
        val isHighRisk = isHandoff ||
            (riskBadge?.contains("敏感") == true) ||
            (riskBadge?.contains("关键") == true) ||
            (riskBadge?.contains("接管") == true)
        val displayTitle = title.removePrefix("GrassBag ").ifBlank { title }

        val wrapper = FrameLayout(ctx).apply {
            clipChildren = false
            clipToPadding = false
            setPadding(dp(ctx, 4), dp(ctx, 4), dp(ctx, 4), dp(ctx, 10))
        }

        val card = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 18), dp(ctx, 12), dp(ctx, 18), dp(ctx, 16))
            background = LiquidGlassDrawable(
                ctx = ctx,
                dark = dark,
                radiusDp = 32f,
                accentTint = if (isHighRisk) Color.parseColor("#E69500") else accentPrimary,
                elevated = true,
                hasBackdropBlur = hasBackdropBlur
            )
            elevation = 24f * density
        }

        // Subtle iOS 26 floating-sheet grabber pill ONLY on draggable Handoff cards (never a dead affordance!)
        if (isHandoff) {
            val dragZone = FrameLayout(ctx).apply {
                tag = "prompt_drag_area"
                setPadding(0, dp(ctx, 2), 0, dp(ctx, 11))
            }
            val handle = View(ctx).apply {
                background = GradientDrawable().apply {
                    cornerRadius = 999f * density
                    setColor(if (dark) Color.parseColor("#44FFFFFF") else Color.parseColor("#2A132C44"))
                }
            }
            dragZone.addView(
                handle,
                FrameLayout.LayoutParams(dp(ctx, 38), (4f * density).toInt().coerceAtLeast(3), Gravity.CENTER)
            )
            card.addView(
                dragZone,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                )
            )
        } else {
            card.setPadding(dp(ctx, 18), dp(ctx, 16), dp(ctx, 18), dp(ctx, 16))
        }

        // Header row: Brand Glass Medallion + Title & Scoped Meta + Precision Countdown Ring
        val headerRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val logo = GrassBagOverlayLogoView(ctx, dark, accentPrimary, accentHi).apply {
            setMode(GrassBagOverlayLogoView.Mode.WAITING)
            layoutParams = LinearLayout.LayoutParams(dp(ctx, 40), dp(ctx, 40))
        }
        headerRow.addView(logo)

        val titleCol = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 11), 0, dp(ctx, 10), 0)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        titleCol.addView(TextView(ctx).apply {
            text = displayTitle
            setTextColor(ink)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            letterSpacing = -0.02f
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        })
        if (!appLabel.isNullOrBlank() || !riskBadge.isNullOrBlank()) {
            val metaRow = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, dp(ctx, 3), 0, 0)
            }
            if (!appLabel.isNullOrBlank()) {
                metaRow.addView(TextView(ctx).apply {
                    text = appLabel
                    setTextColor(subInk)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                    typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                    if (!riskBadge.isNullOrBlank()) {
                        maxWidth = dp(ctx, 128)
                    }
                })
            }
            if (!riskBadge.isNullOrBlank()) {
                val badgeFg = if (isHighRisk) {
                    if (dark) Color.parseColor("#FCD34D") else Color.parseColor("#B45309")
                } else {
                    if (dark) blendColor(accentHi, Color.WHITE, 0.25f) else accentPrimary
                }
                val badgeBg = if (isHighRisk) {
                    if (dark) Color.parseColor("#2AF59E0B") else Color.parseColor("#18E68A00")
                } else {
                    withAlpha(if (dark) accentHi else accentPrimary, if (dark) 38 else 22)
                }
                val badgeStroke = if (isHighRisk) {
                    if (dark) Color.parseColor("#44F59E0B") else Color.parseColor("#33D97706")
                } else {
                    withAlpha(if (dark) accentHi else accentPrimary, if (dark) 62 else 42)
                }
                metaRow.addView(TextView(ctx).apply {
                    text = riskBadge
                    setTextColor(badgeFg)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f)
                    typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
                    setPadding(dp(ctx, 8), dp(ctx, 2), dp(ctx, 8), dp(ctx, 2))
                    background = GradientDrawable().apply {
                        cornerRadius = 999f * density
                        setColor(badgeBg)
                        setStroke((0.65f * density).toInt().coerceAtLeast(1), badgeStroke)
                    }
                }, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { if (!appLabel.isNullOrBlank()) marginStart = dp(ctx, 7) })
            }
            titleCol.addView(metaRow)
        }
        headerRow.addView(titleCol)

        val countdownRing = CountdownRingView(
            context = ctx,
            dark = dark,
            accentPrimary = accentPrimary,
            accentHi = accentHi,
            highRisk = isHighRisk
        ).apply {
            layoutParams = LinearLayout.LayoutParams(dp(ctx, 38), dp(ctx, 38))
        }
        headerRow.addView(countdownRing)
        card.addView(headerRow)

        // Concentric recessed crystal glass well (32dp outer - 18dp horizontal padding = 14dp)
        val actionWell = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 15), dp(ctx, 12), dp(ctx, 15), dp(ctx, 13))
            background = GradientDrawable().apply {
                cornerRadius = 14f * density
                setColor(if (dark) Color.parseColor("#18FFFFFF") else Color.parseColor("#B8FFFFFF"))
                setStroke(
                    (0.8f * density).toInt().coerceAtLeast(1),
                    if (dark) Color.parseColor("#26FFFFFF") else Color.parseColor("#2014395C")
                )
            }
        }
        val eyebrowRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, dp(ctx, 5))
        }
        eyebrowRow.addView(
            View(ctx).apply {
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(if (isHighRisk) Color.parseColor("#F59E0B") else (if (dark) accentHi else accentPrimary))
                }
            },
            LinearLayout.LayoutParams(dp(ctx, 6), dp(ctx, 6)).apply {
                marginEnd = dp(ctx, 6)
            }
        )
        eyebrowRow.addView(TextView(ctx).apply {
            text = when {
                isHandoff -> "需要你手动完成"
                isHighRisk -> "敏感操作 · 请仔细核对"
                else -> "即将执行的操作"
            }
            setTextColor(
                if (isHighRisk) (if (dark) Color.parseColor("#FCD34D") else Color.parseColor("#B45309"))
                else subInk
            )
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            letterSpacing = 0.02f
        })
        actionWell.addView(eyebrowRow)

        val maxSummaryPx = dp(ctx, 144)
        val summaryScroll = object : ScrollView(ctx) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                val cappedH = View.MeasureSpec.makeMeasureSpec(maxSummaryPx, View.MeasureSpec.AT_MOST)
                super.onMeasure(widthMeasureSpec, cappedH)
            }
        }.apply {
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
            addView(
                TextView(ctx).apply {
                    text = actionSummary
                    setTextColor(ink)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 14.8f)
                    typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                    setLineSpacing(0f, 1.38f)
                }
            )
        }
        actionWell.addView(
            summaryScroll,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        )
        card.addView(
            actionWell,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(ctx, 14)
                bottomMargin = dp(ctx, 15)
            }
        )

        // Guarded anti-hijack button factory with silky tactile press spring!
        // Positive approval buttons (guarded = true) enforce the 360ms arming delay and
        // full-occlusion tapjacking rejection; Cancel / Stop / Return stay ALWAYS clickable.
        fun makeGuardedButton(
            label: String,
            bgDrawable: GradientDrawable,
            textColor: Int,
            guarded: Boolean,
            minHeightDp: Int = 46,
            textSp: Float = 14.5f,
            action: () -> Unit
        ): TextView = object : TextView(ctx) {
            private var rejected = false
            init {
                text = label
                gravity = Gravity.CENTER
                setTextColor(textColor)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, textSp)
                typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
                letterSpacing = -0.01f
                minimumHeight = dp(ctx, minHeightDp)
                setPadding(dp(ctx, 14), dp(ctx, 10), dp(ctx, 14), dp(ctx, 10))
                background = bgDrawable
                filterTouchesWhenObscured = guarded
                isClickable = true
            }

            override fun dispatchTouchEvent(event: MotionEvent): Boolean {
                if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                    val fullyObscured = (event.flags and MotionEvent.FLAG_WINDOW_IS_OBSCURED) != 0
                    rejected = if (guarded) {
                        SystemClock.elapsedRealtime() < armedAtMs || gestureInjectRefCount.get() > 0 || fullyObscured
                    } else {
                        gestureInjectRefCount.get() > 0
                    }
                    if (!rejected) {
                        animate().scaleX(0.96f).scaleY(0.96f).setDuration(80L).start()
                    }
                } else if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
                    animate().scaleX(1f).scaleY(1f).setDuration(150L).setInterpolator(OvershootInterpolator(1.06f)).start()
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

        // Tier 1: Unmistakable Full-Width Hero Primary Pill (harmonized with live accent & WCAG AAA ink)
        val heroTop = blendColor(accentHi, Color.WHITE, if (dark) 0.06f else 0.10f)
        val heroMid = blendColor(heroTop, accentPrimary, 0.5f)
        val heroTextColor = if (ColorUtils.calculateLuminance(heroMid) > 0.36) Color.parseColor("#0A1A2A") else Color.WHITE
        val primaryBg = GradientDrawable(
            GradientDrawable.Orientation.TOP_BOTTOM,
            intArrayOf(heroTop, accentPrimary)
        ).apply {
            cornerRadius = 999f * density
            setStroke((0.9f * density).toInt().coerceAtLeast(1), Color.parseColor("#66FFFFFF"))
        }
        val primaryBtn = makeGuardedButton(
            label = if (isHandoff) "我已完成，继续" else "允许本次",
            bgDrawable = primaryBg,
            textColor = heroTextColor,
            guarded = true,
            minHeightDp = 48,
            textSp = 15f,
            action = onPrimary
        )
        card.addView(
            primaryBtn,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        )

        // Tier 2: Harmonious Frosted Glass Secondary Row (NO clashing rainbow pills!)
        val secondaryRow = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
        val neutralGlassBg = GradientDrawable().apply {
            cornerRadius = 999f * density
            setColor(if (dark) Color.parseColor("#1EFFFFFF") else Color.parseColor("#C2F1F6FC"))
            setStroke(
                (0.8f * density).toInt().coerceAtLeast(1),
                if (dark) Color.parseColor("#32FFFFFF") else Color.parseColor("#2414395C")
            )
        }

        if (isHandoff) {
            val backAppBtn = makeGuardedButton(
                label = "返回 GrassBag",
                bgDrawable = neutralGlassBg,
                textColor = ink,
                guarded = false,
                minHeightDp = 44,
                textSp = 14f,
                action = { bringGrassBagToFrontNow() }
            )
            val stopHandoffBg = GradientDrawable().apply {
                cornerRadius = 999f * density
                setColor(if (dark) Color.parseColor("#26EF4444") else Color.parseColor("#14DC2626"))
                setStroke(
                    (0.8f * density).toInt().coerceAtLeast(1),
                    if (dark) Color.parseColor("#44F87171") else Color.parseColor("#33DC2626")
                )
            }
            val stopHandoffBtn = makeGuardedButton(
                label = "停止任务",
                bgDrawable = stopHandoffBg,
                textColor = if (dark) Color.parseColor("#FCA5A5") else Color.parseColor("#C92A2A"),
                guarded = false,
                minHeightDp = 44,
                textSp = 14f,
                action = onCancel
            )
            secondaryRow.addView(backAppBtn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            secondaryRow.addView(
                stopHandoffBtn,
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    marginStart = dp(ctx, 10)
                }
            )
        } else {
            if (allowTurnOption) {
                val turnGlassBg = GradientDrawable().apply {
                    cornerRadius = 999f * density
                    setColor(withAlpha(if (dark) accentHi else accentPrimary, if (dark) 44 else 24))
                    setStroke(
                        (0.85f * density).toInt().coerceAtLeast(1),
                        withAlpha(if (dark) accentHi else accentPrimary, if (dark) 88 else 58)
                    )
                }
                val turnBtn = makeGuardedButton(
                    label = "本轮允许",
                    bgDrawable = turnGlassBg,
                    textColor = if (dark) blendColor(accentHi, Color.WHITE, 0.28f) else accentPrimary,
                    guarded = true,
                    minHeightDp = 44,
                    textSp = 14f,
                    action = onSecondary
                )
                secondaryRow.addView(
                    turnBtn,
                    LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                        marginEnd = dp(ctx, 10)
                    }
                )
            }
            val cancelBtn = makeGuardedButton(
                label = "取消此步",
                bgDrawable = neutralGlassBg,
                textColor = ink,
                guarded = false,
                minHeightDp = 44,
                textSp = 14f,
                action = onCancel
            )
            secondaryRow.addView(cancelBtn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        card.addView(
            secondaryRow,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(ctx, 10) }
        )

        // Tier 3 (Confirmation only): Calm, restrained low-profile Emergency Stop escape bar
        if (!isHandoff) {
            val stopBg = GradientDrawable().apply {
                cornerRadius = 999f * density
                setColor(if (dark) Color.parseColor("#18EF4444") else Color.parseColor("#0EDC2626"))
                setStroke(
                    (0.75f * density).toInt().coerceAtLeast(1),
                    if (dark) Color.parseColor("#36F87171") else Color.parseColor("#28DC2626")
                )
            }
            val stopBtn = makeGuardedButton(
                label = "急停全部操控",
                bgDrawable = stopBg,
                textColor = if (dark) Color.parseColor("#FCA5A5") else Color.parseColor("#C92A2A"),
                guarded = false,
                minHeightDp = 42,
                textSp = 13f,
                action = onStop
            )
            card.addView(
                stopBtn,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { topMargin = dp(ctx, 8) }
            )
        }

        val cardScroll = object : ScrollView(ctx) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                val m = screenMetrics(ctx, activeConfirmWm)
                val dynamicMaxH =
                    (m.height - m.topInset - m.bottomInset - dp(ctx, 56))
                        .coerceAtLeast(dp(ctx, 260))
                val cappedH = View.MeasureSpec.makeMeasureSpec(dynamicMaxH, View.MeasureSpec.AT_MOST)
                super.onMeasure(widthMeasureSpec, cappedH)
            }
        }.apply {
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
            clipChildren = false
            clipToPadding = false
            addView(
                card,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT
                )
            )
        }
        wrapper.addView(
            cardScroll,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            )
        )

        val startCountdown: () -> Unit = {
            activeConfirmProgressAnim?.cancel()
            activeConfirmProgressAnim = ValueAnimator.ofFloat(1f, 0f).apply {
                duration = totalMs.coerceAtLeast(1L)
                interpolator = LinearInterpolator()
                addUpdateListener { anim ->
                    countdownRing.setProgress(anim.animatedValue as Float)
                }
                start()
            }

            val tick = object : Runnable {
                private var lastSec = -1
                override fun run() {
                    if (activeConfirmContainer !== wrapper) return
                    val remMs = (deadlineMs - SystemClock.elapsedRealtime()).coerceAtLeast(0L)
                    val sec = ((remMs + 999L) / 1000L).toInt()
                    if (sec != lastSec) {
                        lastSec = sec
                        countdownRing.setSeconds(sec)
                    }
                    if (remMs > 0L) {
                        val nextDelay = ((remMs - 1L) % 1000L + 16L).coerceIn(100L, 1000L)
                        mainHandler.postDelayed(this, nextDelay)
                    }
                }
            }
            activeConfirmTick = tick
            mainHandler.post(tick)
        }

        return wrapper to startCountdown
    }

    private fun animateCardEntrance(view: View) {
        view.alpha = 0f
        view.translationY = dp(appContext, 38).toFloat()
        view.scaleX = 0.94f
        view.scaleY = 0.94f
        view.animate()
            .alpha(1f)
            .translationY(0f)
            .scaleX(1f)
            .scaleY(1f)
            .setDuration(270L)
            .setInterpolator(OvershootInterpolator(1.04f))
            .start()
    }

    private fun removeActiveConfirmView(animate: Boolean, expectedView: FrameLayout? = null) {
        val view = activeConfirmContainer ?: return
        if (expectedView != null && view !== expectedView) return
        activeConfirmTick?.let { mainHandler.removeCallbacks(it) }
        activeConfirmTick = null
        activeConfirmProgressAnim?.cancel()
        activeConfirmProgressAnim = null
        val wm = activeConfirmWm ?: return
        val lp = activeConfirmParams
        activeConfirmContainer = null
        activeConfirmWm = null
        activeConfirmParams = null
        if (!animate) {
            runCatching { wm.removeViewImmediate(view) }
            unregisterConfigCallbacksIfIdle()
            return
        }
        // Immediately make the fading confirmation card non-touchable BEFORE starting the 175ms
        // exit animation (and before latch.countDown()) so bottom-screen taps/swipes dispatched
        // 1-5ms after approval pass straight through to the target app!
        if (lp != null) {
            lp.flags = lp.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
            runCatching { if (view.isAttachedToWindow) wm.updateViewLayout(view, lp) }
        }
        val entry = wm to (view as View)
        fadingOverlayViews.add(entry)
        view.animate()
            .alpha(0f)
            .translationY(dp(appContext, 28).toFloat())
            .scaleX(0.95f)
            .scaleY(0.95f)
            .setDuration(175L)
            .setInterpolator(DecelerateInterpolator())
            .setListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    fadingOverlayViews.remove(entry)
                    runCatching { if (view.isAttachedToWindow) wm.removeViewImmediate(view) }
                    unregisterConfigCallbacksIfIdle()
                }
            })
            .start()
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
    // Kyant0-inspired Android 13+ AGSL RuntimeShader Liquid Glass Drawable
    // (Analytic SDF + Dual-Lobe Directional/Ambient Fresnel Rim + Clipped
    // Meniscus InnerShadow + Micro RGB Dispersion + Interactive Touch Spotlight,
    // with automatic Canvas fallback on API < 33)
    // =========================================================================

    private class LiquidGlassDrawable(
        ctx: Context,
        private val dark: Boolean,
        private val radiusDp: Float = 28f,
        private val customRadiiPx: FloatArray? = null,
        private val accentTint: Int = Color.parseColor("#2A78B5"),
        private val elevated: Boolean = true,
        private val dockedEdge: Int = 0, // -1 left bezel, +1 right bezel, 0 floating
        private val hasBackdropBlur: Boolean = false
    ) : Drawable() {
        companion object {
            // Kyant0 AndroidLiquidGlass-inspired AGSL shader:
            // analytic rounded-rect SDF + finite-diff normal + meniscus InnerShadow
            // + dual-lobe directional/ambient Fresnel rim + subtle corner RGB dispersion
            // + interactive pointer-tracking specular spotlight.
            private const val KYANT_LIQUID_GLASS_AGSL = """
                uniform float2 uSize;
                uniform float4 uRadii; // (rTR, rBR, rTL, rBL)
                uniform float uDensity;
                uniform float uDark;
                uniform float uElevated;
                uniform float uHasBlur;
                uniform float4 uAccent;
                uniform float2 uTouchPos;
                uniform float uTouchAlpha;
                uniform float uDockedEdge;

                float sdRoundedRect(float2 p, float2 b, float4 r4) {
                    float2 rx = (p.x > 0.0) ? r4.xy : r4.zw;
                    float r = (p.y > 0.0) ? rx.y : rx.x;
                    float2 q = abs(p) - b + float2(r);
                    return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - r;
                }

                float2 gradSdRoundedRect(float2 p, float2 b, float4 r4) {
                    float eps = 0.75;
                    float dx = sdRoundedRect(p + float2(eps, 0.0), b, r4) - sdRoundedRect(p - float2(eps, 0.0), b, r4);
                    float dy = sdRoundedRect(p + float2(0.0, eps), b, r4) - sdRoundedRect(p - float2(0.0, eps), b, r4);
                    float2 g = float2(dx, dy);
                    float len = length(g);
                    return (len > 0.0001) ? (g / len) : float2(0.0, -1.0);
                }

                half4 main(float2 fragCoord) {
                    float2 halfSize = uSize * 0.5;
                    float2 p = fragCoord - halfSize;
                    float d = sdRoundedRect(p, halfSize, uRadii);
                    float cov = clamp(0.5 - d, 0.0, 1.0);
                    if (cov <= 0.001) {
                        return half4(0.0);
                    }

                    float dens = max(uDensity, 1.0);
                    float depthDp = max(0.0, -d) / dens;
                    float2 n = gradSdRoundedRect(p, halfSize, uRadii);
                    float2 uv = clamp(fragCoord / max(uSize, float2(1.0)), float2(0.0), float2(1.0));

                    // Mask out the bezel-attached edge when docked left (-1) or right (+1)
                    float edgeMask = 1.0;
                    if (uDockedEdge < -0.5) {
                        edgeMask = smoothstep(0.0, 4.0 * dens, fragCoord.x);
                    } else if (uDockedEdge > 0.5) {
                        edgeMask = smoothstep(0.0, 4.0 * dens, uSize.x - fragCoord.x);
                    }

                    // 1. Sculpted translucent glass body gradient (lighter veil when cross-window blur is live)
                    float diag = clamp(uv.x * 0.42 + uv.y * 0.58, 0.0, 1.0);
                    float3 topCol;
                    float3 botCol;
                    float baseAlpha;
                    if (uDark > 0.5) {
                        topCol = mix(float3(0.148, 0.165, 0.198), uAccent.rgb, 0.07);
                        botCol = mix(float3(0.082, 0.094, 0.118), uAccent.rgb, 0.04);
                        baseAlpha = (uHasBlur > 0.5) ? 0.72 : ((uElevated > 0.5) ? 0.84 : 0.79);
                    } else {
                        topCol = mix(float3(0.990, 0.992, 0.996), uAccent.rgb, 0.025);
                        botCol = mix(float3(0.935, 0.945, 0.960), uAccent.rgb, 0.055);
                        baseAlpha = (uHasBlur > 0.5) ? 0.78 : ((uElevated > 0.5) ? 0.87 : 0.83);
                    }
                    float3 rgb = mix(topCol, botCol, diag);

                    // 2. Subtle top-left ambient accent wash
                    float wash = pow(clamp(1.0 - length(uv * float2(0.85, 1.15)), 0.0, 1.0), 1.6);
                    rgb = mix(rgb, uAccent.rgb, wash * (uDark > 0.5 ? 0.14 : 0.065));

                    // 3. Kyant0 Clipped Meniscus InnerShadow (opposite 135-deg light axis, zero muddiness)
                    float2 lightDir = normalize(float2(-0.7071, -0.7071));
                    float shadowFace = clamp(dot(n, -lightDir), 0.0, 1.0);
                    float innerShadow = exp(-depthDp * 0.36) * pow(max(shadowFace, 0.0001), 1.7) * (uDark > 0.5 ? 0.26 : 0.10) * edgeMask;
                    rgb *= (1.0 - innerShadow);

                    // 4. Tight top meniscus catchlight sheen (stays cleanly above body text)
                    float topSheen = exp(-uv.y * 5.0) * clamp(1.0 - uv.x * 0.55, 0.0, 1.0);
                    rgb += float3(1.0) * topSheen * (uDark > 0.5 ? 0.12 : 0.26);

                    // Delicate 0.65dp outer contrast hairline applied BEFORE Fresnel specular so bright
                    // top-left catchlights stay luminous while keeping a neutral crisp contour over white apps.
                    rgb = clamp(rgb, 0.0, 1.0);
                    float outerEdge = smoothstep(0.75, 0.0, depthDp) * edgeMask;
                    rgb = mix(rgb, uDark > 0.5 ? float3(0.0) : float3(0.08, 0.10, 0.13), outerEdge * (uDark > 0.5 ? 0.22 : 0.13));

                    // 5. Kyant0 Dual-Lobe Directional + Ambient Fresnel Rim + Accent-Harmonized Corner Shimmer
                    float rimMask = smoothstep(1.85, 0.0, depthDp) * edgeMask;
                    float primaryLobe = pow(max(dot(n, lightDir), 0.0001), 3.6);
                    float counterLobe = 0.76 * pow(max(dot(n, -lightDir), 0.0001), 4.2);
                    float ambientLobe = 0.16;
                    float rimEnergy = rimMask * (primaryLobe + counterLobe + ambientLobe);

                    float corner = 4.0 * abs(n.x * n.y);
                    float3 accentChroma = uAccent.rgb - float3(dot(uAccent.rgb, float3(0.299, 0.587, 0.114)));
                    float3 prismTint = accentChroma * corner * (uDark > 0.5 ? 0.26 : 0.14);
                    float3 rimColor = mix(float3(1.0), uAccent.rgb * 0.55 + float3(0.45), 0.24) + prismTint;
                    rgb += rimColor * rimEnergy * (uDark > 0.5 ? 0.54 : 0.62);
                    rgb = clamp(rgb, 0.0, 1.0);

                    // 6. Kyant0 InteractiveHighlight (finger-tracking radial spotlight + local curved rim glint)
                    if (uTouchAlpha > 0.001) {
                        float distDp = length(fragCoord - uTouchPos) / dens;
                        float spot = exp(-(distDp * distDp) / (46.0 * 46.0));
                        float rimSpot = exp(-(distDp * distDp) / (36.0 * 36.0)) * smoothstep(2.2, 0.0, depthDp) * edgeMask;
                        float3 touchCol = mix(float3(1.0), uAccent.rgb * 0.4 + float3(0.6), 0.28);
                        rgb += touchCol * (spot * (uDark > 0.5 ? 0.22 : 0.30) + rimSpot * (uDark > 0.5 ? 0.62 : 0.54)) * uTouchAlpha;
                    }

                    float outAlpha = clamp(baseAlpha + rimEnergy * 0.16 + uTouchAlpha * 0.04, 0.0, 1.0) * cov;
                    return half4(clamp(rgb, 0.0, 1.0) * outAlpha, outAlpha);
                }
            """
        }

        private val density = ctx.resources.displayMetrics.density
        private val clipPath = Path()
        private val boundsRect = RectF()
        private val rimRect = RectF()
        private val rimPath = Path()
        private val outerRect = RectF()
        private val outerPath = Path()
        private var cachedRimRadiusPx = 0f
        private var cachedOuterRadiusPx = 0f
        private var agslShader: Shader? = null
        private val agslPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private var touchX = 0f
        private var touchY = 0f
        private var touchAlpha = 0f
        private var touchFadeAnimator: ValueAnimator? = null
        private val bodyPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val tintWashPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val specularPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val rimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = (if (dark) 1.05f else 1.1f) * density
        }
        private val outerHairlinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 0.65f * density
            color = if (dark) Color.parseColor("#38000000") else Color.parseColor("#1C132C44")
        }

        init {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                agslShader = runCatching { RuntimeShader(KYANT_LIQUID_GLASS_AGSL) }.getOrNull()
                agslShader?.let { agslPaint.shader = it }
            }
        }

        fun setTouchHighlight(xPx: Float, yPx: Float, alpha: Float) {
            touchFadeAnimator?.cancel()
            touchFadeAnimator = null
            touchX = xPx
            touchY = yPx
            touchAlpha = alpha.coerceIn(0f, 1f)
            invalidateSelf()
        }

        fun fadeOutTouchHighlight() {
            if (touchAlpha <= 0.01f) {
                touchAlpha = 0f
                return
            }
            touchFadeAnimator?.cancel()
            val start = touchAlpha
            touchFadeAnimator = ValueAnimator.ofFloat(start, 0f).apply {
                duration = 220L
                interpolator = DecelerateInterpolator()
                addUpdateListener {
                    touchAlpha = it.animatedValue as Float
                    invalidateSelf()
                }
                start()
            }
        }

        override fun onBoundsChange(bounds: Rect) {
            super.onBoundsChange(bounds)
            boundsRect.set(bounds)
            val w = boundsRect.width()
            val h = boundsRect.height()
            if (w <= 0f || h <= 0f) return

            clipPath.reset()
            val maxR = min(w, h) / 2f
            val rPx = min(radiusDp * density, maxR)
            if (customRadiiPx != null) {
                clipPath.addRoundRect(boundsRect, customRadiiPx, Path.Direction.CW)
            } else {
                clipPath.addRoundRect(boundsRect, rPx, rPx, Path.Direction.CW)
            }

            // Configure API 33+ AGSL RuntimeShader uniforms once per resize (zero per-frame allocs!)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                (agslShader as? RuntimeShader)?.let { shader ->
                    val rTL = if (customRadiiPx != null) min(customRadiiPx[0], maxR) else rPx
                    val rTR = if (customRadiiPx != null) min(customRadiiPx[2], maxR) else rPx
                    val rBR = if (customRadiiPx != null) min(customRadiiPx[4], maxR) else rPx
                    val rBL = if (customRadiiPx != null) min(customRadiiPx[6], maxR) else rPx
                    shader.setFloatUniform("uSize", w, h)
                    shader.setFloatUniform("uRadii", rTR, rBR, rTL, rBL)
                    shader.setFloatUniform("uDensity", density)
                    shader.setFloatUniform("uDark", if (dark) 1f else 0f)
                    shader.setFloatUniform("uElevated", if (elevated) 1f else 0f)
                    shader.setFloatUniform("uHasBlur", if (hasBackdropBlur) 1f else 0f)
                    shader.setFloatUniform(
                        "uAccent",
                        Color.red(accentTint) / 255f,
                        Color.green(accentTint) / 255f,
                        Color.blue(accentTint) / 255f,
                        1f
                    )
                    shader.setFloatUniform("uDockedEdge", dockedEdge.toFloat())
                }
            }

            // 1. Sculpted Apple iOS 26/27 Liquid Glass body (Canvas fallback for API < 33):
            // Harmonized subtly with active accentTint so non-blue themes stay cohesive.
            val baseTop = if (dark) {
                when {
                    hasBackdropBlur -> Color.parseColor("#C81F2530")
                    elevated -> Color.parseColor("#D61E242E")
                    else -> Color.parseColor("#CE191F29")
                }
            } else {
                when {
                    hasBackdropBlur -> Color.parseColor("#D4FCFEFF")
                    elevated -> Color.parseColor("#E0FCFEFF")
                    else -> Color.parseColor("#D8F7FAFD")
                }
            }
            val baseBot = if (dark) {
                when {
                    hasBackdropBlur -> Color.parseColor("#BE131820")
                    elevated -> Color.parseColor("#CC141A24")
                    else -> Color.parseColor("#C411161F")
                }
            } else {
                when {
                    hasBackdropBlur -> Color.parseColor("#C6EEF3F8")
                    elevated -> Color.parseColor("#D2EEF3F8")
                    else -> Color.parseColor("#CAEAF0F6")
                }
            }
            val topCol = ColorUtils.setAlphaComponent(
                ColorUtils.blendARGB(baseTop, accentTint, if (dark) 0.14f else 0.05f),
                Color.alpha(baseTop)
            )
            val botCol = ColorUtils.setAlphaComponent(
                ColorUtils.blendARGB(baseBot, accentTint, if (dark) 0.10f else 0.07f),
                Color.alpha(baseBot)
            )
            bodyPaint.shader = LinearGradient(
                boundsRect.left, boundsRect.top, boundsRect.right, boundsRect.bottom,
                topCol, botCol, Shader.TileMode.CLAMP
            )

            // 2. Subtle ambient accent wash radiating from top-left
            val tintA = if (dark) 26 else 16
            val washCol = Color.argb(tintA, Color.red(accentTint), Color.green(accentTint), Color.blue(accentTint))
            tintWashPaint.shader = LinearGradient(
                boundsRect.left, boundsRect.top, boundsRect.right, boundsRect.bottom,
                washCol, Color.TRANSPARENT, Shader.TileMode.CLAMP
            )

            // 3. Directional 135-degree iOS 26/27 liquid specular sheen + subtle top meniscus glow
            specularPaint.shader = LinearGradient(
                boundsRect.left, boundsRect.top, boundsRect.left + w * 0.42f, boundsRect.top + h * 0.52f,
                intArrayOf(
                    if (dark) Color.parseColor("#36FFFFFF") else Color.parseColor("#C2FFFFFF"),
                    if (dark) Color.parseColor("#12CFE8FF") else Color.parseColor("#44FFFFFF"),
                    Color.TRANSPARENT
                ),
                floatArrayOf(0f, 0.40f, 1f),
                Shader.TileMode.CLAMP
            )

            // 4. 4-stop 135-degree Fresnel prism rim highlight (luminous top-left catchlight ->
            //    cool accent shimmer -> delicate shadow waist -> opposite-edge counter-glint)
            val accentRim = Color.argb(
                if (dark) 62 else 148,
                (Color.red(accentTint) + 255) / 2,
                (Color.green(accentTint) + 255) / 2,
                (Color.blue(accentTint) + 255) / 2
            )
            rimPaint.shader = LinearGradient(
                boundsRect.left, boundsRect.top, boundsRect.right, boundsRect.bottom,
                intArrayOf(
                    if (dark) Color.parseColor("#7CE4F3FF") else Color.parseColor("#FEFFFFFF"),
                    accentRim,
                    if (dark) Color.parseColor("#1695C2EC") else Color.parseColor("#24162E42"),
                    if (dark) Color.parseColor("#3C9CC8F0") else Color.parseColor("#A4FFFFFF")
                ),
                floatArrayOf(0f, 0.30f, 0.70f, 1f),
                Shader.TileMode.CLAMP
            )

            // Precompute rim & outer hairline geometry once per size change (zero allocations in draw())
            val inset = 0.75f * density
            val outerInset = 0.35f * density
            val bezelBleed = 2.0f * density
            rimRect.set(
                boundsRect.left + if (dockedEdge < 0) -bezelBleed else inset,
                boundsRect.top + inset,
                boundsRect.right + if (dockedEdge > 0) bezelBleed else -inset,
                boundsRect.bottom - inset
            )
            outerRect.set(
                boundsRect.left + if (dockedEdge < 0) -bezelBleed else outerInset,
                boundsRect.top + outerInset,
                boundsRect.right + if (dockedEdge > 0) bezelBleed else -outerInset,
                boundsRect.bottom - outerInset
            )
            cachedRimRadiusPx = min((radiusDp * density - inset).coerceAtLeast(0f), min(rimRect.width(), rimRect.height()) / 2f)
            cachedOuterRadiusPx = min((radiusDp * density - outerInset).coerceAtLeast(0f), min(outerRect.width(), outerRect.height()) / 2f)
            rimPath.reset()
            outerPath.reset()
            if (customRadiiPx != null) {
                val rimRadii = FloatArray(8) { i -> (customRadiiPx[i] - inset).coerceAtLeast(0f) }
                val outerRadii = FloatArray(8) { i -> (customRadiiPx[i] - outerInset).coerceAtLeast(0f) }
                rimPath.addRoundRect(rimRect, rimRadii, Path.Direction.CW)
                outerPath.addRoundRect(outerRect, outerRadii, Path.Direction.CW)
            }
        }

        override fun draw(canvas: Canvas) {
            if (boundsRect.width() <= 0f || boundsRect.height() <= 0f) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val shader = agslShader as? RuntimeShader
                if (shader != null) {
                    shader.setFloatUniform("uTouchPos", touchX, touchY)
                    shader.setFloatUniform("uTouchAlpha", touchAlpha)
                    // Draw unclipped rect: SDF `cov` in KYANT_LIQUID_GLASS_AGSL handles exact
                    // single-pass edge anti-aliasing without double-clip fraying!
                    canvas.drawRect(boundsRect, agslPaint)
                    return
                }
            }

            canvas.save()
            canvas.clipPath(clipPath)
            canvas.drawRect(boundsRect, bodyPaint)
            canvas.drawRect(boundsRect, tintWashPaint)
            canvas.drawRect(boundsRect, specularPaint)
            if (touchAlpha > 0.01f) {
                val glowRadius = (min(boundsRect.width(), boundsRect.height()) * 0.72f).coerceAtLeast(36f * density)
                val peakAlpha = ((if (dark) 78f else 110f) * touchAlpha).toInt().coerceIn(0, 255)
                val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    shader = RadialGradient(
                        touchX,
                        touchY,
                        glowRadius,
                        intArrayOf(
                            ColorUtils.setAlphaComponent(
                                if (dark) Color.WHITE else ColorUtils.blendARGB(Color.WHITE, accentTint, 0.18f),
                                peakAlpha
                            ),
                            Color.TRANSPARENT
                        ),
                        floatArrayOf(0f, 1f),
                        Shader.TileMode.CLAMP
                    )
                }
                canvas.drawCircle(touchX, touchY, glowRadius, glowPaint)
            }
            canvas.restore()

            // Draw outer contrast hairline first, then 4-stop 135-degree Fresnel catchlight on top
            // so the dark outer hairline never dulls the luminous specular top-left rim.
            if (customRadiiPx != null) {
                canvas.save()
                canvas.clipRect(boundsRect)
                canvas.drawPath(outerPath, outerHairlinePaint)
                canvas.drawPath(rimPath, rimPaint)
                canvas.restore()
            } else {
                canvas.drawRoundRect(outerRect, cachedOuterRadiusPx, cachedOuterRadiusPx, outerHairlinePaint)
                canvas.drawRoundRect(rimRect, cachedRimRadiusPx, cachedRimRadiusPx, rimPaint)
            }
        }

        override fun getOutline(outline: Outline) {
            if (bounds.isEmpty) return
            val w = bounds.width().toFloat()
            val h = bounds.height().toFloat()
            val rPx = min(radiusDp * density, min(w, h) / 2f)
            if (customRadiiPx != null && !clipPath.isEmpty) {
                val pathOk = runCatching {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        outline.setPath(clipPath)
                    } else {
                        @Suppress("DEPRECATION")
                        outline.setConvexPath(clipPath)
                    }
                    true
                }.getOrDefault(false)
                if (pathOk) return
            }
            outline.setRoundRect(bounds, rPx)
        }

        override fun setVisible(visible: Boolean, restart: Boolean): Boolean {
            if (!visible) {
                touchFadeAnimator?.cancel()
                touchFadeAnimator = null
                touchAlpha = 0f
            }
            return super.setVisible(visible, restart)
        }

        override fun setAlpha(alpha: Int) {
            agslPaint.alpha = alpha
            bodyPaint.alpha = alpha
            tintWashPaint.alpha = alpha
            specularPaint.alpha = alpha
            rimPaint.alpha = alpha
            outerHairlinePaint.alpha = alpha
            invalidateSelf()
        }

        override fun setColorFilter(colorFilter: ColorFilter?) {
            agslPaint.colorFilter = colorFilter
            bodyPaint.colorFilter = colorFilter
            tintWashPaint.colorFilter = colorFilter
            specularPaint.colorFilter = colorFilter
            rimPaint.colorFilter = colorFilter
            outerHairlinePaint.colorFilter = colorFilter
            invalidateSelf()
        }

        @Deprecated("Deprecated in Java")
        override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
    }

    /**
     * Precision circular Liquid Glass countdown complication for authorization cards.
     * Replaces noisy full-width gradient progress bars with a calm Apple-style sweeping ring.
     */
    private class CountdownRingView(
        context: Context,
        private val dark: Boolean,
        private val accentPrimary: Int,
        private val accentHi: Int,
        private val highRisk: Boolean
    ) : View(context) {
        private val density = context.resources.displayMetrics.density
        private var progress = 1f
        private var seconds = 35
        private val arcRect = RectF()
        private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            color = if (dark) Color.parseColor("#18FFFFFF") else Color.parseColor("#88FFFFFF")
        }
        private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2.4f * density
            color = if (dark) Color.parseColor("#24FFFFFF") else Color.parseColor("#18132C44")
        }
        private val arcPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2.4f * density
            strokeCap = Paint.Cap.ROUND
        }
        private val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            textAlign = Paint.Align.CENTER
            textSize = 10.5f * context.resources.displayMetrics.scaledDensity
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            fontFeatureSettings = "tnum"
        }

        fun setProgress(value: Float) {
            val clamped = value.coerceIn(0f, 1f)
            if (abs(clamped - progress) >= 0.002f) {
                progress = clamped
                invalidate()
            }
        }

        fun setSeconds(sec: Int) {
            val clamped = sec.coerceAtLeast(0)
            if (clamped != seconds) {
                seconds = clamped
                invalidate()
            }
        }

        override fun onDraw(canvas: Canvas) {
            val w = width.toFloat()
            val h = height.toFloat()
            if (w <= 0f || h <= 0f) return
            val cx = w / 2f
            val cy = h / 2f
            val stroke = trackPaint.strokeWidth
            val r = min(w, h) / 2f - stroke
            if (r <= 0f) return

            val urgent = seconds in 1..8
            val activeColor = when {
                urgent -> if (dark) Color.parseColor("#FBBF24") else Color.parseColor("#B45309")
                highRisk -> if (dark) Color.parseColor("#FBBF24") else Color.parseColor("#D97706")
                else -> if (dark) accentHi else accentPrimary
            }

            canvas.drawCircle(cx, cy, r, fillPaint)
            canvas.drawCircle(cx, cy, r, trackPaint)
            arcRect.set(cx - r, cy - r, cx + r, cy + r)
            arcPaint.color = activeColor
            canvas.drawArc(arcRect, -90f, 360f * progress, false, arcPaint)

            textPaint.color = if (urgent) {
                if (dark) Color.parseColor("#FDE68A") else Color.parseColor("#9A4D00")
            } else {
                if (dark) Color.parseColor("#E6F1FC") else Color.parseColor("#183149")
            }
            val fm = textPaint.fontMetrics
            val baseline = cy - (fm.ascent + fm.descent) / 2f
            canvas.drawText("${seconds}s", cx, baseline, textPaint)
        }
    }

    // =========================================================================
    // Custom Vector GrassBag Brand Logo View with Orbital Ring & Completion Check
    // =========================================================================

    private class GrassBagOverlayLogoView(
        context: Context,
        private val dark: Boolean,
        private val accentPrimary: Int,
        private val accentHi: Int
    ) : View(context) {
        enum class Mode { ACTIVE, WAITING, PAUSED, COMPLETED }

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
            val pouchMid = Color.rgb(
                (Color.red(accentPrimary) + Color.red(accentHi)) / 2,
                (Color.green(accentPrimary) + Color.green(accentHi)) / 2,
                (Color.blue(accentPrimary) + Color.blue(accentHi)) / 2
            )
            color = if (ColorUtils.calculateLuminance(pouchMid) > 0.42) {
                Color.parseColor("#18191D")
            } else {
                Color.WHITE
            }
        }
        private val checkPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            color = Color.WHITE
        }
        private val donePaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val waitingRingColor = Color.parseColor("#F59E0B")
        private val pausedRingColor = if (dark) Color.parseColor("#64748B") else Color.parseColor("#94A3B8")
        private val highlightColor = Color.parseColor("#88FFFFFF")

        private val checkPath = Path()
        private val scratchRect = RectF()
        private val sweepMatrix = Matrix()
        private var sweepShader: SweepGradient? = null

        override fun onAttachedToWindow() {
            super.onAttachedToWindow()
            if (mode != Mode.PAUSED && mode != Mode.COMPLETED && animator == null) {
                startSpin()
            }
        }

        fun setMode(next: Mode) {
            if (mode == next) return
            mode = next
            if (next == Mode.PAUSED || next == Mode.COMPLETED) {
                animator?.cancel()
                animator = null
            } else if (animator == null && isAttachedToWindow) {
                startSpin()
            }
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
                    Color.argb(0, Color.red(accentPrimary), Color.green(accentPrimary), Color.blue(accentPrimary)),
                    accentHi,
                    Color.parseColor("#FF20C997"),
                    Color.argb(0, Color.red(accentPrimary), Color.green(accentPrimary), Color.blue(accentPrimary))
                ),
                floatArrayOf(0f, 0.36f, 0.74f, 1f)
            )
            badgePaint.shader = LinearGradient(
                0f, 0f, w.toFloat(), h.toFloat(),
                if (dark) Color.parseColor("#2A3D58") else Color.parseColor("#DCEBFB"),
                if (dark) Color.parseColor("#1A2738") else Color.parseColor("#C7E1F7"),
                Shader.TileMode.CLAMP
            )
            pouchPaint.shader = LinearGradient(
                w * 0.25f, h * 0.2f, w * 0.78f, h * 0.85f,
                accentHi,
                accentPrimary,
                Shader.TileMode.CLAMP
            )
            donePaint.shader = LinearGradient(
                0f, 0f, w.toFloat(), h.toFloat(),
                Color.parseColor("#34D399"),
                Color.parseColor("#10B981"),
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

            if (mode == Mode.COMPLETED) {
                // Crisp emerald completion medallion with checkmark!
                canvas.drawCircle(cx, cy, r * 0.88f, donePaint)
                checkPaint.strokeWidth = r * 0.16f
                checkPath.reset()
                checkPath.moveTo(cx - r * 0.34f, cy + r * 0.02f)
                checkPath.lineTo(cx - r * 0.08f, cy + r * 0.28f)
                checkPath.lineTo(cx + r * 0.38f, cy - r * 0.24f)
                canvas.drawPath(checkPath, checkPaint)
                return
            }

            canvas.drawCircle(cx, cy, r * 0.86f, badgePaint)

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
                    ringPaint.color = waitingRingColor
                    ringPaint.alpha = (pulse * 225f).toInt()
                    canvas.drawCircle(cx, cy, ringRadius, ringPaint)
                }
                Mode.PAUSED -> {
                    ringPaint.shader = null
                    ringPaint.color = pausedRingColor
                    ringPaint.alpha = 165
                    canvas.drawCircle(cx, cy, ringRadius, ringPaint)
                }
                Mode.COMPLETED -> Unit
            }

            // GrassBag mascot silhouette (zero per-frame RectF allocations)
            val s = r * 0.56f
            canvas.save()
            canvas.rotate(-26f, cx - s * 0.18f, cy - s * 0.44f)
            scratchRect.set(cx - s * 0.36f, cy - s * 0.96f, cx - s * 0.02f, cy - s * 0.34f)
            canvas.drawOval(scratchRect, pouchPaint)
            canvas.restore()

            canvas.save()
            canvas.rotate(26f, cx + s * 0.18f, cy - s * 0.44f)
            scratchRect.set(cx + s * 0.02f, cy - s * 0.96f, cx + s * 0.36f, cy - s * 0.34f)
            canvas.drawOval(scratchRect, pouchPaint)
            canvas.restore()

            scratchRect.set(cx - s * 0.72f, cy - s * 0.42f, cx + s * 0.72f, cy + s * 0.78f)
            canvas.drawRoundRect(scratchRect, s * 0.56f, s * 0.56f, pouchPaint)

            highlightPaint.color = highlightColor
            highlightPaint.strokeWidth = s * 0.13f
            scratchRect.set(cx - s * 0.50f, cy - s * 0.24f, cx + s * 0.50f, cy + s * 0.56f)
            canvas.drawArc(scratchRect, 200f, 65f, false, highlightPaint)

            // Playful micro-blink once per orbital cycle when active
            val blinkScale = if (mode == Mode.ACTIVE && phase in 336f..352f) 0.24f else 1f
            val eyeW = s * 0.15f
            val eyeH = s * 0.28f * blinkScale
            val eyeY = cy + s * 0.14f
            scratchRect.set(cx - s * 0.27f - eyeW / 2f, eyeY - eyeH / 2f, cx - s * 0.27f + eyeW / 2f, eyeY + eyeH / 2f)
            canvas.drawRoundRect(scratchRect, eyeW, eyeW, eyePaint)
            scratchRect.set(cx + s * 0.27f - eyeW / 2f, eyeY - eyeH / 2f, cx + s * 0.27f + eyeW / 2f, eyeY + eyeH / 2f)
            canvas.drawRoundRect(scratchRect, eyeW, eyeW, eyePaint)
        }
    }

    // =========================================================================
    // Unified 60/120Hz Ambient Edge Aurora + Live Gesture FX Canvas
    // (ALWAYS FLAG_NOT_TOUCHABLE — zero interference with touch injection!)
    // =========================================================================

    private class GrassBagAmbientAndGestureCanvasView(
        context: Context,
        private var dark: Boolean,
        private var accentPrimary: Int,
        private var accentHi: Int,
        private var showAurora: Boolean,
        private var showGestureFx: Boolean
    ) : View(context) {

        enum class VisualMode { ACTIVE, WAITING, PAUSED, COMPLETED }

        private data class TapEffect(
            val x: Float,
            val y: Float,
            val label: String?,
            val isLongPress: Boolean,
            val holdMs: Long,
            val startMs: Long,
            val totalMs: Long
        )

        private data class SwipeEffect(
            val x1: Float,
            val y1: Float,
            val x2: Float,
            val y2: Float,
            val startMs: Long,
            val moveMs: Long,
            val totalMs: Long
        )

        private data class TypeBadgeEffect(
            val text: String,
            val startMs: Long,
            val totalMs: Long
        )

        var cornerRadiusPx: Float = 36f * context.resources.displayMetrics.density
        private var visualMode = VisualMode.ACTIVE
        private var fade = 0f
        private var targetFade = 1f
        private var phaseDeg = 0f
        private var reactivePulse = 0f
        private var shutterAlpha = 0f
        private var running = false
        private var lastFrameMs = 0L
        private var lastDrawNanos = 0L
        private var onFadedOut: (() -> Unit)? = null

        private val tapEffects = ArrayList<TapEffect>()
        private val swipeEffects = ArrayList<SwipeEffect>()
        private var activeTypeBadge: TypeBadgeEffect? = null

        private val density = context.resources.displayMetrics.density
        // 5-layer tapered concentric vector strokes replace BlurMaskFilter so Skia/HWUI never
        // runs a full-screen Gaussian blur pass at 60/120Hz while eliminating stepped halo banding!
        private val outerHaloPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 24f * density
        }
        private val outerGlowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 15f * density
        }
        private val midGlowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 8.5f * density
        }
        private val innerGlowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 4.2f * density
        }
        private val rimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 1.9f * density
        }
        private val fxRingPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
        }
        private val fxFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
        }
        private val fxTrailPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
        }
        private val trailMatrix = Matrix()
        private var trailShader: LinearGradient? = null
        private var trailShaderAccent: Int = 0
        private val innerRippleColor = Color.parseColor("#20C997")
        private val darkTagBgColor = Color.parseColor("#F21C2736")
        private val lightTagBgColor = Color.parseColor("#F8FBFDFF")
        private val darkTagRimColor = Color.parseColor("#9FC8F0")
        private val lightTagRimColor = Color.parseColor("#132C44")
        private val darkTagTextColor = Color.parseColor("#F4F8FD")
        private val lightTagTextColor = Color.parseColor("#112131")
        private val tagShadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
        private val tagBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
        private val tagRimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 0.8f * density
        }
        private val tagTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 11.5f * context.resources.displayMetrics.scaledDensity
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            textAlign = Paint.Align.CENTER
        }
        private val tagMeasurePaint = TextPaint(tagTextPaint)
        private var cachedTagRaw: String? = null
        private var cachedTagWidth: Int = -1
        private var cachedTagEllipsized: String = ""
        private var cachedTagTextW: Float = 0f
        private val scratchRect = RectF()
        private val shutterPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 18f * density
        }

        private val borderPath = Path()
        private val sweepMatrix = Matrix()
        private var sweepShader: SweepGradient? = null

        fun hasActiveFx(): Boolean =
            tapEffects.isNotEmpty() || swipeEffects.isNotEmpty() || activeTypeBadge != null || shutterAlpha > 0.01f

        private val frameCallback = object : Choreographer.FrameCallback {
            override fun doFrame(frameTimeNanos: Long) {
                if (!running) return
                val nowMs = SystemClock.elapsedRealtime()
                val hasActiveFx = tapEffects.isNotEmpty() || swipeEffects.isNotEmpty() || activeTypeBadge != null || shutterAlpha > 0.01f
                val ambientSettled = !hasActiveFx && kotlin.math.abs(targetFade - fade) <= 0.01f
                // Throttle ambient-only edge aurora to ~33fps (28ms cadence) to cut GPU power by ~70% on 120Hz phones
                // while keeping full native 60/120fps whenever gesture ripples, swipes, or fade transitions are active!
                if (ambientSettled && lastDrawNanos != 0L && (frameTimeNanos - lastDrawNanos) < 28_000_000L) {
                    Choreographer.getInstance().postFrameCallback(this)
                    return
                }
                lastDrawNanos = frameTimeNanos

                val dt = if (lastFrameMs == 0L) 16f else (nowMs - lastFrameMs).coerceIn(1L, 64L).toFloat()
                lastFrameMs = nowMs

                val fadeSpeed = if (targetFade > fade) 0.0045f else 0.0055f
                fade = if (fade < targetFade) {
                    (fade + dt * fadeSpeed).coerceAtMost(targetFade)
                } else {
                    (fade - dt * fadeSpeed).coerceAtLeast(targetFade)
                }

                val speedDegPerMs = when (visualMode) {
                    VisualMode.PAUSED -> 0.015f
                    VisualMode.WAITING -> 0.042f
                    VisualMode.COMPLETED -> 0.135f
                    VisualMode.ACTIVE -> 0.078f + reactivePulse * 0.09f
                }
                phaseDeg = (phaseDeg + dt * speedDegPerMs) % 360f
                if (reactivePulse > 0f) {
                    reactivePulse = (reactivePulse - dt * 0.0022f).coerceAtLeast(0f)
                }
                if (shutterAlpha > 0f) {
                    shutterAlpha = (shutterAlpha - dt * 0.0038f).coerceAtLeast(0f)
                }

                // Prune finished gesture FX
                if (tapEffects.isNotEmpty()) {
                    tapEffects.removeAll { nowMs - it.startMs >= it.totalMs }
                }
                if (swipeEffects.isNotEmpty()) {
                    swipeEffects.removeAll { nowMs - it.startMs >= it.totalMs }
                }
                activeTypeBadge?.let { if (nowMs - it.startMs >= it.totalMs) activeTypeBadge = null }

                invalidate()

                val stillHasFx = tapEffects.isNotEmpty() || swipeEffects.isNotEmpty() || activeTypeBadge != null || shutterAlpha > 0.01f
                if (targetFade == 0f && ((fade <= 0.01f && !stillHasFx) || visibility != View.VISIBLE)) {
                    running = false
                    val cb = onFadedOut
                    onFadedOut = null
                    cb?.invoke()
                } else if (visibility != View.VISIBLE ||
                    (!showAurora && !stillHasFx && targetFade > 0f && fade >= targetFade - 0.01f) ||
                    (visualMode == VisualMode.PAUSED && !stillHasFx && targetFade > 0f && fade >= targetFade - 0.01f)
                ) {
                    // Halt Choreographer loop when aurora is disabled, hidden, or paused with no active gesture FX.
                    running = false
                } else {
                    Choreographer.getInstance().postFrameCallback(this)
                }
            }
        }

        init {
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }

        fun stopImmediately() {
            running = false
            onFadedOut = null
            Choreographer.getInstance().removeFrameCallback(frameCallback)
        }

        fun startLoop() {
            targetFade = 1f
            onFadedOut = null
            if (!running) {
                running = true
                lastFrameMs = 0L
                Choreographer.getInstance().postFrameCallback(frameCallback)
            }
        }

        fun setVisualMode(next: VisualMode) {
            if (visualMode == next) return
            visualMode = next
            rebuildSweepShader()
            if (next != VisualMode.PAUSED && showAurora && targetFade > 0f) {
                startLoop()
            } else {
                invalidate()
            }
        }

        fun updateThemeAndPrefs(
            dark: Boolean,
            accentPrimary: Int,
            accentHi: Int,
            showAurora: Boolean,
            showGestureFx: Boolean
        ) {
            this.dark = dark
            this.accentPrimary = accentPrimary
            this.accentHi = accentHi
            this.showAurora = showAurora
            this.showGestureFx = showGestureFx
            rebuildSweepShader()
            if (showAurora && visualMode != VisualMode.PAUSED && targetFade > 0f) {
                startLoop()
            }
            invalidate()
        }

        fun emitTap(x: Float, y: Float, label: String?, isLongPress: Boolean, holdMs: Long) {
            if (!showGestureFx) return
            val now = SystemClock.elapsedRealtime()
            val total = if (isLongPress) (holdMs + 480L) else 660L
            tapEffects.add(TapEffect(x, y, label, isLongPress, holdMs, now, total))
            reactivePulse = 1f
            startLoop()
        }

        fun emitSwipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long) {
            if (!showGestureFx) return
            val now = SystemClock.elapsedRealtime()
            val moveMs = durationMs.coerceIn(140L, 1600L)
            swipeEffects.add(SwipeEffect(x1, y1, x2, y2, now, moveMs, moveMs + 480L))
            reactivePulse = 0.9f
            startLoop()
        }

        fun emitTypeBadge(text: String) {
            if (!showGestureFx) return
            activeTypeBadge = TypeBadgeEffect(text, SystemClock.elapsedRealtime(), 1250L)
            reactivePulse = 0.65f
            startLoop()
        }

        fun emitShutterPulse() {
            if (!showGestureFx) return
            shutterAlpha = 1f
            startLoop()
        }

        fun emitCompletionWave() {
            reactivePulse = 1f
            startLoop()
        }

        fun fadeOutAndDetach(onDone: () -> Unit) {
            targetFade = 0f
            onFadedOut = onDone
            if (!running) {
                if (fade > 0.01f && showAurora && visibility == View.VISIBLE) {
                    running = true
                    lastFrameMs = 0L
                    Choreographer.getInstance().postFrameCallback(frameCallback)
                } else {
                    onFadedOut = null
                    onDone()
                }
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
            rebuildSweepShader()
        }

        private fun rebuildSweepShader() {
            if (width <= 0 || height <= 0) return
            val palette = when (visualMode) {
                VisualMode.COMPLETED -> intArrayOf(
                    Color.parseColor("#34D399"),
                    Color.parseColor("#10B981"),
                    Color.parseColor("#2DD4BF"),
                    Color.parseColor("#34D399")
                )
                VisualMode.WAITING -> intArrayOf(
                    Color.parseColor("#F59E0B"),
                    Color.parseColor("#FBBF24"),
                    accentHi,
                    Color.parseColor("#F59E0B")
                )
                VisualMode.PAUSED -> intArrayOf(
                    Color.parseColor("#64748B"),
                    Color.parseColor("#94A3B8"),
                    Color.parseColor("#64748B")
                )
                VisualMode.ACTIVE -> intArrayOf(
                    accentHi,
                    Color.parseColor("#20C997"),
                    Color.parseColor("#7C8CF8"),
                    accentPrimary,
                    accentHi
                )
            }
            sweepShader = SweepGradient(width / 2f, height / 2f, palette, null)
            outerHaloPaint.shader = sweepShader
            outerGlowPaint.shader = sweepShader
            midGlowPaint.shader = sweepShader
            innerGlowPaint.shader = sweepShader
            rimPaint.shader = sweepShader
        }

        private fun ensureTrailShader(): LinearGradient {
            val existing = trailShader
            if (existing != null && trailShaderAccent == accentHi) return existing
            val created = LinearGradient(
                0f, 0f, 1f, 0f,
                Color.argb(0, Color.red(accentHi), Color.green(accentHi), Color.blue(accentHi)),
                Color.argb(255, Color.red(accentHi), Color.green(accentHi), Color.blue(accentHi)),
                Shader.TileMode.CLAMP
            )
            trailShader = created
            trailShaderAccent = accentHi
            return created
        }

        override fun onDraw(canvas: Canvas) {
            if (width == 0 || height == 0) return
            val nowMs = SystemClock.elapsedRealtime()

            // 1. Ambient Apple Intelligence Style Edge Aurora (5-layer tapered halo, zero BlurMaskFilter)
            if (showAurora && fade > 0.01f) {
                sweepShader?.let { s ->
                    sweepMatrix.setRotate(phaseDeg, width / 2f, height / 2f)
                    s.setLocalMatrix(sweepMatrix)
                }
                val baseBreathe = when (visualMode) {
                    VisualMode.PAUSED -> 0.42f
                    VisualMode.COMPLETED -> 1.0f
                    else -> (0.76f + 0.24f * cos(Math.toRadians(phaseDeg * 2.0)).toFloat())
                }
                val boost = 1f + reactivePulse * 0.28f
                val intensity = (fade * baseBreathe * boost).coerceIn(0f, 1.25f)
                outerHaloPaint.strokeWidth = (24f + reactivePulse * 8f) * density
                outerHaloPaint.alpha = (intensity * (if (dark) 22f else 16f)).toInt().coerceIn(0, 255)
                outerGlowPaint.strokeWidth = (15f + reactivePulse * 5.5f) * density
                outerGlowPaint.alpha = (intensity * (if (dark) 40f else 30f)).toInt().coerceIn(0, 255)
                midGlowPaint.strokeWidth = (8.5f + reactivePulse * 3.2f) * density
                midGlowPaint.alpha = (intensity * (if (dark) 78f else 62f)).toInt().coerceIn(0, 255)
                innerGlowPaint.strokeWidth = (4.2f + reactivePulse * 1.5f) * density
                innerGlowPaint.alpha = (intensity * (if (dark) 142f else 115f)).toInt().coerceIn(0, 255)
                rimPaint.alpha = (intensity * (if (dark) 235f else 195f)).toInt().coerceIn(0, 255)
                canvas.drawPath(borderPath, outerHaloPaint)
                canvas.drawPath(borderPath, outerGlowPaint)
                canvas.drawPath(borderPath, midGlowPaint)
                canvas.drawPath(borderPath, innerGlowPaint)
                canvas.drawPath(borderPath, rimPaint)
            }

            // 2. Post-Capture Screenshot Shutter Pulse
            if (shutterAlpha > 0.01f) {
                shutterPaint.color = if (dark) Color.WHITE else accentHi
                shutterPaint.alpha = (shutterAlpha * 110f).toInt().coerceIn(0, 255)
                canvas.drawPath(borderPath, shutterPaint)
            }

            if (!showGestureFx) return

            // 3. Tap & Long-Press Liquid Ripple Rings
            for (fx in tapEffects) {
                val elapsed = (nowMs - fx.startMs).coerceAtLeast(0L)
                val p = (elapsed.toFloat() / fx.totalMs.toFloat()).coerceIn(0f, 1f)
                val ease = 1f - (1f - p) * (1f - p) * (1f - p)

                if (fx.isLongPress) {
                    val chargeP = (elapsed.toFloat() / fx.holdMs.coerceAtLeast(1L).toFloat()).coerceIn(0f, 1f)
                    val fadeOut = if (elapsed > fx.holdMs) {
                        1f - ((elapsed - fx.holdMs).toFloat() / (fx.totalMs - fx.holdMs).coerceAtLeast(1L).toFloat()).coerceIn(0f, 1f)
                    } else 1f
                    val ringR = (22f + 10f * chargeP) * density
                    fxFillPaint.color = accentHi
                    fxFillPaint.alpha = (fadeOut * 56f).toInt().coerceIn(0, 255)
                    canvas.drawCircle(fx.x, fx.y, ringR, fxFillPaint)

                    fxRingPaint.color = accentHi
                    fxRingPaint.strokeWidth = 3.2f * density
                    fxRingPaint.alpha = (fadeOut * 235f).toInt().coerceIn(0, 255)
                    scratchRect.set(fx.x - ringR, fx.y - ringR, fx.x + ringR, fx.y + ringR)
                    canvas.drawArc(scratchRect, -90f, 360f * chargeP, false, fxRingPaint)
                } else {
                    // Outer expanding prism ring
                    val outerR = (10f + 36f * ease) * density
                    val alphaOuter = ((1f - p) * 230f).toInt().coerceIn(0, 255)
                    fxRingPaint.color = accentHi
                    fxRingPaint.strokeWidth = (3.2f - 1.6f * p) * density
                    fxRingPaint.alpha = alphaOuter
                    canvas.drawCircle(fx.x, fx.y, outerR, fxRingPaint)

                    // Inner staggered glowing ring
                    val p2 = ((p - 0.14f) / 0.86f).coerceIn(0f, 1f)
                    if (p2 > 0f) {
                        val innerR = (8f + 24f * (1f - (1f - p2) * (1f - p2))) * density
                        fxRingPaint.color = innerRippleColor
                        fxRingPaint.strokeWidth = 2.0f * density
                        fxRingPaint.alpha = ((1f - p2) * 200f).toInt().coerceIn(0, 255)
                        canvas.drawCircle(fx.x, fx.y, innerR, fxRingPaint)
                    }

                    // Luminous center dot
                    val dotAlpha = ((1f - (p * 1.45f).coerceAtMost(1f)) * 240f).toInt().coerceIn(0, 255)
                    if (dotAlpha > 0) {
                        fxFillPaint.color = Color.WHITE
                        fxFillPaint.alpha = dotAlpha
                        canvas.drawCircle(fx.x, fx.y, (6.5f - 2f * p) * density, fxFillPaint)
                    }
                }

                // Floating micro-label pill above touch point
                if (!fx.label.isNullOrBlank()) {
                    val tagAlpha = when {
                        p < 0.16f -> p / 0.16f
                        p > 0.70f -> (1f - p) / 0.30f
                        else -> 1f
                    }.coerceIn(0f, 1f)
                    val liftY = (36f + 16f * ease) * density
                    val tagY = (fx.y - liftY).coerceAtLeast(108f * density)
                    drawFloatingMicroTag(canvas, fx.x, tagY, fx.label, tagAlpha)
                }
            }

            // 4. Swipe Glowing Comet Trajectory
            for (sw in swipeEffects) {
                val elapsed = (nowMs - sw.startMs).coerceAtLeast(0L)
                val moveP = (elapsed.toFloat() / sw.moveMs.coerceAtLeast(1L).toFloat()).coerceIn(0f, 1f)
                val easeMove = 1f - (1f - moveP) * (1f - moveP)
                val fadeOut = if (elapsed > sw.moveMs) {
                    1f - ((elapsed - sw.moveMs).toFloat() / (sw.totalMs - sw.moveMs).coerceAtLeast(1L).toFloat()).coerceIn(0f, 1f)
                } else 1f

                val curX = sw.x1 + (sw.x2 - sw.x1) * easeMove
                val curY = sw.y1 + (sw.y2 - sw.y1) * easeMove
                val tailP = (easeMove - 0.55f).coerceAtLeast(0f)
                val tailX = sw.x1 + (sw.x2 - sw.x1) * tailP
                val tailY = sw.y1 + (sw.y2 - sw.y1) * tailP

                // Faint origin anchor ring
                fxRingPaint.color = accentHi
                fxRingPaint.strokeWidth = 2f * density
                fxRingPaint.alpha = (fadeOut * 120f).toInt().coerceIn(0, 255)
                canvas.drawCircle(sw.x1, sw.y1, 8f * density, fxRingPaint)

                // Glowing directional ribbon (reused unit LinearGradient + Matrix — zero per-frame Shader allocations!)
                val dx = curX - tailX
                val dy = curY - tailY
                val segLen = hypot(dx.toDouble(), dy.toDouble()).toFloat()
                if (segLen > 2f) {
                    val shader = ensureTrailShader()
                    val deg = Math.toDegrees(atan2(dy.toDouble(), dx.toDouble())).toFloat()
                    trailMatrix.reset()
                    trailMatrix.setScale(segLen, 1f)
                    trailMatrix.postRotate(deg)
                    trailMatrix.postTranslate(tailX, tailY)
                    shader.setLocalMatrix(trailMatrix)
                    fxTrailPaint.shader = shader
                    fxTrailPaint.alpha = (fadeOut * 230f).toInt().coerceIn(0, 255)
                    fxTrailPaint.strokeWidth = 6.5f * density
                    canvas.drawLine(tailX, tailY, curX, curY, fxTrailPaint)
                    fxTrailPaint.shader = null
                    fxTrailPaint.alpha = 255
                }

                // Glowing moving head orb + subtle directional chevron
                fxFillPaint.color = accentHi
                fxFillPaint.alpha = (fadeOut * 95f).toInt().coerceIn(0, 255)
                canvas.drawCircle(curX, curY, 15f * density, fxFillPaint)
                fxFillPaint.color = Color.WHITE
                fxFillPaint.alpha = (fadeOut * 240f).toInt().coerceIn(0, 255)
                canvas.drawCircle(curX, curY, 6f * density, fxFillPaint)

                val angle = atan2((sw.y2 - sw.y1).toDouble(), (sw.x2 - sw.x1).toDouble())
                val arrowLen = 10f * density
                val a1 = angle + Math.toRadians(145.0)
                val a2 = angle - Math.toRadians(145.0)
                fxRingPaint.color = Color.WHITE
                fxRingPaint.strokeWidth = 2.2f * density
                fxRingPaint.alpha = (fadeOut * 220f).toInt().coerceIn(0, 255)
                val tipX = curX + (cos(angle) * 11f * density).toFloat()
                val tipY = curY + (sin(angle) * 11f * density).toFloat()
                canvas.drawLine(tipX, tipY, tipX + (cos(a1) * arrowLen).toFloat(), tipY + (sin(a1) * arrowLen).toFloat(), fxRingPaint)
                canvas.drawLine(tipX, tipY, tipX + (cos(a2) * arrowLen).toFloat(), tipY + (sin(a2) * arrowLen).toFloat(), fxRingPaint)
            }

            // 5. Floating Typing Preview Pill
            activeTypeBadge?.let { badge ->
                val p = ((nowMs - badge.startMs).toFloat() / badge.totalMs.toFloat()).coerceIn(0f, 1f)
                val alpha = when {
                    p < 0.14f -> p / 0.14f
                    p > 0.78f -> (1f - p) / 0.22f
                    else -> 1f
                }.coerceIn(0f, 1f)
                drawFloatingMicroTag(canvas, width / 2f, height * 0.20f, badge.text, alpha)
            }
        }

        private fun drawFloatingMicroTag(canvas: Canvas, cx: Float, cy: Float, text: String, alphaFrac: Float) {
            if (alphaFrac <= 0.01f || width <= 0) return
            val padX = 11f * density
            val padY = 6f * density
            val maxPillW = (width - 28f * density).coerceAtLeast(80f * density)
            val maxTextW = (maxPillW - padX * 2f).coerceAtLeast(32f * density)
            if (cachedTagRaw != text || cachedTagWidth != width) {
                cachedTagRaw = text
                cachedTagWidth = width
                cachedTagEllipsized = TextUtils.ellipsize(
                    text,
                    tagMeasurePaint,
                    maxTextW,
                    TextUtils.TruncateAt.END
                ).toString()
                cachedTagTextW = tagTextPaint.measureText(cachedTagEllipsized).coerceAtMost(maxTextW)
            }
            val displayText = cachedTagEllipsized
            val tw = cachedTagTextW
            val fm = tagTextPaint.fontMetrics
            val th = fm.descent - fm.ascent
            val halfW = tw / 2f + padX
            val minCx = halfW + 12f * density
            val maxCx = width - halfW - 12f * density
            val clampedCx = if (minCx >= maxCx) width / 2f else cx.coerceIn(minCx, maxCx)

            // Soft cheap drop-shadow pill (replaces expensive per-frame setShadowLayer!)
            val shadowOffY = 2f * density
            val shadowPad = 1.5f * density
            scratchRect.set(
                clampedCx - halfW - shadowPad,
                cy - th / 2f - padY + shadowOffY,
                clampedCx + halfW + shadowPad,
                cy + th / 2f + padY + shadowOffY + shadowPad
            )
            tagShadowPaint.color = if (dark) Color.BLACK else Color.rgb(15, 30, 48)
            tagShadowPaint.alpha = (alphaFrac * (if (dark) 68f else 26f)).toInt().coerceIn(0, 255)
            canvas.drawRoundRect(scratchRect, 999f, 999f, tagShadowPaint)

            scratchRect.set(clampedCx - halfW, cy - th / 2f - padY, clampedCx + halfW, cy + th / 2f + padY)
            val rect = scratchRect

            tagBgPaint.color = if (dark) darkTagBgColor else lightTagBgColor
            tagBgPaint.alpha = (alphaFrac * 245f).toInt().coerceIn(0, 255)
            tagRimPaint.color = if (dark) darkTagRimColor else lightTagRimColor
            tagRimPaint.alpha = (alphaFrac * (if (dark) 110f else 72f)).toInt().coerceIn(0, 255)
            tagTextPaint.color = if (dark) darkTagTextColor else lightTagTextColor
            tagTextPaint.alpha = (alphaFrac * 255f).toInt().coerceIn(0, 255)

            canvas.drawRoundRect(rect, 999f, 999f, tagBgPaint)
            canvas.drawRoundRect(rect, 999f, 999f, tagRimPaint)
            val baseline = rect.centerY() - (fm.ascent + fm.descent) / 2f
            canvas.drawText(displayText, clampedCx, baseline, tagTextPaint)
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
