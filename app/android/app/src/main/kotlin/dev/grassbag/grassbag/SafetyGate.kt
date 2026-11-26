package dev.grassbag.grassbag

import android.content.Context
import android.content.SharedPreferences
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Native Android Phone Control Safety Firewall (aligned with dsh-Go SafetyGate).
 *
 * Enforces:
 * 1. Hardcoded immutable rules (financial/payment apps, password/OTP inputs, GrassBag own UI,
 *    system settings writes) completely immune to prompt injection.
 * 2. Per-app confirmation overrides (e.g. WeChat readable, every write confirmed via native overlay).
 * 3. Seamless cooperation with BOTH DSH chat permission modes:
 *    - `workspace-write` ("工作区内修改"): native out-of-app Liquid Glass confirmation card
 *      (`允许一次` / `本轮允许` / `取消`).
 *    - `danger-full-access` ("完全权限"): ordinary actions execute smoothly with HUD + Edge Beam
 *      + 1-tap 急停, while sensitive actions/WeChat still pop the native overlay confirmation card!
 * 4. Per-session turn tracking (`ALLOW_TURN` never wiped by unrelated background sessions).
 * 5. Live pause/resume + emergency-stop listener broadcast to Flutter.
 */
object SafetyGate {
    enum class PolicyTier { ASK, ALLOW_TURN, ALWAYS }

    data class Decision(val allowed: Boolean, val reason: String)

    sealed class ActionVerdict {
        data class Allow(val reason: String) : ActionVerdict()
        data class NeedConfirm(
            val reason: String,
            val allowTurnOption: Boolean = true,
            val riskBadge: String? = null
        ) : ActionVerdict()
        data class Deny(val reason: String, val hint: String? = null) : ActionVerdict()
    }

    data class AuditRecord(
        val ts: Long,
        val tool: String,
        val target: String,
        val allowed: Boolean,
        val reason: String
    ) {
        fun toMap(): Map<String, Any> = mapOf(
            "ts" to ts,
            "tool" to tool,
            "target" to target,
            "allowed" to allowed,
            "reason" to reason
        )
    }

    private const val PREFS_NAME = "gb_safety_gate_v1"
    private const val TURN_WATCHDOG_MS = 5 * 60 * 1000L

    @Volatile
    private var prefs: SharedPreferences? = null
    private val policy = AtomicReference(PolicyTier.ASK)
    private val syncedChatPermissionPreset = AtomicReference("workspace-write")
    private val activeTurnsBySession = ConcurrentHashMap<String, Long>()
    private val sessionTurnGrants = ConcurrentHashMap<String, Long>()
    private val emergencyStopped = AtomicBoolean(false)
    private val paused = AtomicBoolean(false)
    private val confirmHighRisk = AtomicBoolean(true)
    private val autoReturnOnComplete = AtomicBoolean(true)
    private val showEdgeAurora = AtomicBoolean(true)
    private val showGestureFx = AtomicBoolean(true)
    private val auditLog = CopyOnWriteArrayList<AuditRecord>()
    private val auditLock = Any()
    private val turnPolicyLock = Any()
    private val emergencyStopListeners = CopyOnWriteArraySet<() -> Unit>()
    private val pauseListeners = CopyOnWriteArraySet<(Boolean) -> Unit>()

    private val interactiveWriteTools = setOf(
        "phone_tap", "phone_long_press", "phone_swipe", "phone_type", "phone_open", "phone_intent"
    )
    private val packageRequiredTools = setOf(
        "phone_screen", "phone_screenshot", "phone_tap", "phone_long_press", "phone_swipe", "phone_type"
    )
    @Volatile
    private var allowTurnSetAtMs: Long = 0L

    /** Hard-denied financial/wallet/payment apps & GrassBag own UI. */
    private val hardDeniedPackages: Set<String> = setOf(
        "dev.grassbag.grassbag",
        "com.eg.android.AlipayGphone",
        "com.google.android.apps.walletnfcrel",
        "com.samsung.android.spay",
        "com.mipay.wallet",
        "com.huawei.wallet",
        "com.icbc",
        "com.chinamworld.main",
        "com.android.bankabc",
        "com.chinamworld.bocmbci",
        "com.cmbchina",
        "cmb.pb",
        "com.cmbchina.ccd.pluto.cmbActivity",
        "com.bankcomm.Bankcomm",
        "com.unionpay",
        "com.abchina.ebank",
        "com.pingan.paces.ccms",
        "com.paypal.android.p2pmobile",
        "com.chase.sig.android",
        "cn.gov.pbc.dcep",
        "com.mybank.android.phone",
        "com.webank.wemoney"
    )

    /** System pages: readable for diagnosis, writes require user handoff (just like dsh-Go). */
    private val systemWriteBlockedPackages: Set<String> = setOf(
        "com.android.settings",
        "com.android.systemui",
        "com.android.keychain",
        "com.android.vpndialogs",
        "com.android.certinstaller",
        "com.android.packageinstaller",
        "com.google.android.packageinstaller",
        "com.miui.packageinstaller",
        "com.android.permissioncontroller",
        "com.google.android.permissioncontroller",
        "com.miui.securitycenter",
        "com.lbe.security.miui",
        "com.coloros.safecenter",
        "com.oplus.safecenter",
        "com.vivo.permissionmanager",
        "com.huawei.systemmanager",
        "com.hihonor.systemmanager"
    )

    /** Readable apps where every write confirms natively (aligned with dsh-Go). */
    private val confirmEveryWritePackages: Set<String> = setOf(
        "com.tencent.mm"
    )

    private val secretInputKeywords = listOf(
        "password", "passcode", "密码", "支付密码", "验证码", "指纹", "人脸验证", "银行卡号"
    )
    private val shortSecretTokenRe = Regex("\\b(pin|otp|cvv|cvc)\\b", RegexOption.IGNORE_CASE)

    private val sensitiveActionKeywords = listOf(
        "发送", "删除", "清空", "支付", "付款", "转账", "下单", "立即购买", "提交订单",
        "确认支付", "注销", "卸载", "格式化", "恢复出厂", "send", "delete", "pay", "transfer", "purchase"
    )

    @Volatile
    private var initialized: Boolean = false

    fun init(ctx: Context) {
        if (initialized) return
        synchronized(this) {
            if (initialized) return
            val p = ctx.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs = p
            val savedPolicy = p.getString("policy", "ASK") ?: "ASK"
            val tier = runCatching { PolicyTier.valueOf(savedPolicy) }.getOrDefault(PolicyTier.ASK)
            policy.set(if (tier == PolicyTier.ALLOW_TURN) PolicyTier.ASK else tier)
            confirmHighRisk.set(p.getBoolean("confirmHighRisk", true))
            autoReturnOnComplete.set(p.getBoolean("autoReturnOnComplete", true))
            showEdgeAurora.set(p.getBoolean("showEdgeAurora", true))
            showGestureFx.set(p.getBoolean("showGestureFx", true))
            initialized = true
        }
    }

    fun addEmergencyStopListener(listener: () -> Unit) {
        emergencyStopListeners.add(listener)
    }

    fun removeEmergencyStopListener(listener: () -> Unit) {
        emergencyStopListeners.remove(listener)
    }

    fun addPauseListener(listener: (Boolean) -> Unit) {
        pauseListeners.add(listener)
    }

    fun removePauseListener(listener: (Boolean) -> Unit) {
        pauseListeners.remove(listener)
    }

    private fun pruneExpiredTurns() {
        synchronized(turnPolicyLock) {
            val now = System.currentTimeMillis()
            val hadActive = activeTurnsBySession.isNotEmpty()
            activeTurnsBySession.entries.removeIf { now - it.value > TURN_WATCHDOG_MS }
            sessionTurnGrants.entries.removeIf { now - it.value > TURN_WATCHDOG_MS }
            // Only revert ALLOW_TURN -> ASK when an active turn expired OR the idle policy grant itself timed out.
            // Never wipe a freshly selected ALLOW_TURN policy while the user is still in Settings before starting a turn!
            if (activeTurnsBySession.isEmpty() &&
                (hadActive || (allowTurnSetAtMs > 0L && now - allowTurnSetAtMs > TURN_WATCHDOG_MS))
            ) {
                if (policy.compareAndSet(PolicyTier.ALLOW_TURN, PolicyTier.ASK)) {
                    allowTurnSetAtMs = 0L
                }
            }
        }
    }

    private fun isTurnLockedNow(): Boolean {
        synchronized(turnPolicyLock) {
            pruneExpiredTurns()
            return activeTurnsBySession.isNotEmpty()
        }
    }

    fun setPolicy(tier: PolicyTier): Boolean {
        synchronized(turnPolicyLock) {
            allowTurnSetAtMs = if (tier == PolicyTier.ALLOW_TURN) System.currentTimeMillis() else 0L
            policy.set(tier)
        }
        if (tier != PolicyTier.ALLOW_TURN) {
            prefs?.edit()?.putString("policy", tier.name)?.apply()
        }
        record("policy", tier.name, true, "policy_updated")
        return true
    }

    fun setConfirmHighRisk(enabled: Boolean) {
        confirmHighRisk.set(enabled)
        prefs?.edit()?.putBoolean("confirmHighRisk", enabled)?.apply()
    }

    fun isConfirmHighRisk(): Boolean = confirmHighRisk.get()

    fun setAutoReturnEnabled(enabled: Boolean) {
        autoReturnOnComplete.set(enabled)
        prefs?.edit()?.putBoolean("autoReturnOnComplete", enabled)?.apply()
    }

    fun isAutoReturnEnabled(): Boolean = autoReturnOnComplete.get()

    fun setShowEdgeAurora(enabled: Boolean) {
        showEdgeAurora.set(enabled)
        prefs?.edit()?.putBoolean("showEdgeAurora", enabled)?.apply()
    }

    fun isShowEdgeAurora(): Boolean = showEdgeAurora.get()

    fun setShowGestureFx(enabled: Boolean) {
        showGestureFx.set(enabled)
        prefs?.edit()?.putBoolean("showGestureFx", enabled)?.apply()
    }

    fun isShowGestureFx(): Boolean = showGestureFx.get()

    fun getPolicy(): PolicyTier = policy.get()

    fun setSyncedChatPermissionPreset(preset: String?) {
        val clean = preset?.trim()?.takeIf { it.isNotEmpty() } ?: "workspace-write"
        syncedChatPermissionPreset.set(clean)
    }

    fun getSyncedChatPermissionPreset(): String = syncedChatPermissionPreset.get()

    private val pauseLock = Object()

    fun isPaused(): Boolean = paused.get()

    fun setPaused(value: Boolean) {
        val prev = paused.getAndSet(value)
        synchronized(pauseLock) {
            pauseLock.notifyAll()
        }
        if (prev != value) {
            for (l in pauseListeners) {
                runCatching { l(value) }
            }
        }
    }

    fun waitWhilePaused(
        deadlineMs: Long,
        sessionId: String? = null,
        turnId: String? = null,
        hadActiveTurn: Boolean = false
    ) {
        synchronized(pauseLock) {
            while (paused.get() && !emergencyStopped.get()) {
                if (hadActiveTurn && !isTurnActiveForSession(sessionId, turnId)) break
                val remaining = deadlineMs - System.currentTimeMillis()
                if (remaining <= 0L || Thread.currentThread().isInterrupted) break
                try {
                    pauseLock.wait(remaining.coerceAtMost(5_000L))
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                }
            }
        }
    }

    fun beginTurn(turnId: String?, sessionId: String? = null) {
        synchronized(turnPolicyLock) {
            val key = sessionKey(sessionId, turnId)
            activeTurnsBySession[key] = System.currentTimeMillis()
        }
    }

    fun grantTurnAllow(sessionId: String?, turnId: String? = null) {
        val key = sessionKey(sessionId, turnId)
        synchronized(turnPolicyLock) {
            val now = System.currentTimeMillis()
            activeTurnsBySession[key] = now
            sessionTurnGrants[key] = now
        }
        record("confirm", key, true, "user_granted_turn_allow")
    }

    fun isTurnAllowed(sessionId: String?, turnId: String? = null): Boolean {
        synchronized(turnPolicyLock) {
            pruneExpiredTurns()
            val key = sessionKey(sessionId, turnId)
            return sessionTurnGrants.containsKey(key) || policy.get() == PolicyTier.ALLOW_TURN
        }
    }

    /**
     * Ends ONLY the phone-control turn matching [sessionId] or [turnId]. Unrelated sessions (such as title
     * generation or another text-only chat) NEVER wipe an active phone-control turn!
     */
    fun endTurn(sessionId: String? = null, turnId: String? = null): Boolean {
        val key = sessionId?.takeIf { it.isNotBlank() && it != "null" }
        val tKey = turnId?.takeIf { it.isNotBlank() && it != "null" }
        val (removed, nowEmpty) = synchronized(turnPolicyLock) {
            val didRemove = if (key != null || tKey != null) {
                var anyRemoved = false
                if (key != null) {
                    anyRemoved = (activeTurnsBySession.remove(key) != null) || anyRemoved
                    anyRemoved = (sessionTurnGrants.remove(key) != null) || anyRemoved
                }
                if (tKey != null && tKey != key) {
                    anyRemoved = (activeTurnsBySession.remove(tKey) != null) || anyRemoved
                    anyRemoved = (sessionTurnGrants.remove(tKey) != null) || anyRemoved
                }
                anyRemoved
            } else {
                val hadAny = activeTurnsBySession.isNotEmpty() || sessionTurnGrants.isNotEmpty()
                activeTurnsBySession.clear()
                sessionTurnGrants.clear()
                hadAny
            }
            pruneExpiredTurns()
            val empty = activeTurnsBySession.isEmpty()
            if (empty && didRemove) {
                allowTurnSetAtMs = 0L
                policy.compareAndSet(PolicyTier.ALLOW_TURN, PolicyTier.ASK)
            }
            didRemove to empty
        }
        if (nowEmpty) {
            setPaused(false)
        } else if (removed) {
            synchronized(pauseLock) { pauseLock.notifyAll() }
        }
        return removed
    }

    fun isNonSuccessTurnEndReason(reason: String?): Boolean {
        if (emergencyStopped.get()) return true
        val r = reason?.trim()?.lowercase() ?: return false
        return r == "stopped" ||
            r == "emergency_stop" ||
            r == "cancelled" ||
            r == "canceled" ||
            r == "aborted" ||
            r == "error" ||
            r == "failed" ||
            r == "interrupted" ||
            r.contains("error") ||
            r.contains("abort") ||
            r.contains("cancel")
    }

    fun isTurnActiveForSession(sessionId: String?, turnId: String? = null): Boolean {
        pruneExpiredTurns()
        val key = sessionKey(sessionId, turnId)
        return activeTurnsBySession.containsKey(key)
    }

    fun hasActiveTurn(): Boolean = isTurnLockedNow()

    fun triggerEmergencyStop() {
        emergencyStopped.set(true)
        setPaused(false)
        activeTurnsBySession.clear()
        sessionTurnGrants.clear()
        policy.compareAndSet(PolicyTier.ALLOW_TURN, PolicyTier.ASK)
        record("emergency_stop", "all", false, "user_triggered_stop")
        for (l in emergencyStopListeners) {
            runCatching { l() }
        }
    }

    fun resetEmergencyStop() {
        emergencyStopped.set(false)
        paused.set(false)
    }

    fun isEmergencyStopped(): Boolean = emergencyStopped.get()

    fun isPackageBlocked(packageName: String?): Boolean {
        if (packageName.isNullOrBlank()) return false
        return hardDeniedPackages.contains(packageName) ||
            packageName.contains(".bank", ignoreCase = true) ||
            packageName.contains("mobilebank", ignoreCase = true) ||
            packageName.contains("wallet", ignoreCase = true) ||
            packageName.contains("alipay", ignoreCase = true) ||
            packageName.contains("unionpay", ignoreCase = true)
    }

    fun isSystemWriteBlocked(packageName: String?): Boolean =
        !packageName.isNullOrBlank() && systemWriteBlockedPackages.contains(packageName)

    fun isConfirmEveryWritePackage(packageName: String?): Boolean =
        !packageName.isNullOrBlank() && confirmEveryWritePackages.contains(packageName)

    fun sensitiveActionHit(label: String?): String? {
        if (label.isNullOrBlank()) return null
        val lower = label.lowercase()
        return sensitiveActionKeywords.firstOrNull { lower.contains(it) }
    }

    fun isSensitiveNode(isPassword: Boolean, text: String?, hint: String?, viewId: String?): Boolean {
        if (isPassword) return true
        if (hint.isNullOrBlank() && viewId.isNullOrBlank() && text.isNullOrBlank()) return false
        val combined = buildString {
            if (!hint.isNullOrBlank()) append(hint)
            if (!viewId.isNullOrBlank()) {
                if (isNotEmpty()) append(' ')
                append(viewId)
            }
            if (!text.isNullOrBlank()) {
                if (isNotEmpty()) append(' ')
                append(text)
            }
        }.lowercase()
        return secretInputKeywords.any { combined.contains(it) } ||
            shortSecretTokenRe.containsMatchIn(combined)
    }

    /**
     * Rich native verdict used by [PhoneControlDaemon] to decide between immediate execution,
     * showing the native out-of-app Liquid Glass confirmation card, or hard-denying.
     */
    fun evaluateAction(
        tool: String,
        targetPackage: String?,
        sessionId: String? = null,
        turnId: String? = null,
        permissionPreset: String? = null,
        targetLabel: String? = null,
        isSensitiveTarget: Boolean = false,
        userApproved: Boolean = false
    ): ActionVerdict {
        if (emergencyStopped.get()) {
            record(tool, targetPackage ?: "-", false, "emergency_stop_active")
            return ActionVerdict.Deny(
                "emergency_stop_active",
                "已触发手机操控急停保护。如需重新允许操控，请在 GrassBag「设置 → 操控手机」恢复保护开关。"
            )
        }
        if (packageRequiredTools.contains(tool) && (targetPackage.isNullOrBlank() || targetPackage == "unknown")) {
            record(tool, "unknown", false, "unknown_foreground_package")
            return ActionVerdict.Deny(
                "unknown_foreground_package",
                "暂时无法识别当前前台应用，请稍候重试或先调用 phone_open 打开目标应用。"
            )
        }
        if (isPackageBlocked(targetPackage)) {
            record(tool, targetPackage ?: "-", false, "blocked_sensitive_package")
            return ActionVerdict.Deny(
                "blocked_sensitive_package",
                if (targetPackage == "dev.grassbag.grassbag") {
                    "当前前台是 GrassBag 自身界面，请先调用 phone_open 打开目标应用或 phone_key(home) 返回桌面。"
                } else {
                    "「$targetPackage」属于银行/支付安全隔离应用，默认禁止自动读取或操作；请调用 phone_handoff 交由用户手动完成。"
                }
            )
        }
        if (tool != "phone_screen" && tool != "phone_screenshot" && tool != "phone_apps" &&
            tool != "phone_key" && isSystemWriteBlocked(targetPackage)
        ) {
            record(tool, targetPackage ?: "-", false, "blocked_system_settings_write")
            return ActionVerdict.Deny(
                "blocked_system_settings_write",
                "系统设置、权限或安装页默认只读不代点，请调用 phone_handoff 请用户手动完成。"
            )
        }
        if (isSensitiveTarget && (tool == "phone_type" || tool == "phone_tap" || tool == "phone_long_press")) {
            record(tool, targetPackage ?: "-", false, "blocked_sensitive_input_field")
            return ActionVerdict.Deny(
                "blocked_sensitive_input_field",
                "检测到密码 / 验证码 / 支付输入框，严禁自动填写或点击，请调用 phone_handoff 请用户输入。"
            )
        }

        // Read-only & safe navigation tools always run cleanly
        if (tool == "phone_screen" || tool == "phone_screenshot" || tool == "phone_apps" ||
            tool == "phone_wait" || tool == "phone_key" || tool == "phone_return_app"
        ) {
            record(tool, targetPackage ?: "screen", true, "allowed:safe_tool")
            return ActionVerdict.Allow("allowed:safe_tool")
        }

        if (userApproved) {
            record(tool, targetPackage ?: "screen", true, "allowed:user_approved")
            return ActionVerdict.Allow("allowed:user_approved")
        }

        val currentPolicy = policy.get()
        val isFullAccessPreset = permissionPreset == "danger-full-access" || permissionPreset == "full-access"
        val isEveryWriteApp = isConfirmEveryWritePackage(targetPackage)
        val sensitiveWord = sensitiveActionHit(targetLabel)

        // WeChat / every-write apps & sensitive action buttons ALWAYS require native confirmation
        // regardless of PolicyTier.ALWAYS or danger-full-access (matching hard SafetyGate contract).
        if (isEveryWriteApp || sensitiveWord != null) {
            val badge = when {
                sensitiveWord != null -> "敏感操作「$sensitiveWord」"
                isEveryWriteApp -> "关键应用确认"
                else -> "操作确认"
            }
            return ActionVerdict.NeedConfirm(
                reason = if (sensitiveWord != null) "sensitive:$sensitiveWord" else "confirm_every_write",
                allowTurnOption = false,
                riskBadge = badge
            )
        }

        // Swiping on ordinary apps does not need repetitive popups
        if (tool == "phone_swipe") {
            record(tool, targetPackage ?: "screen", true, "allowed:scroll")
            return ActionVerdict.Allow("allowed:scroll")
        }

        // Ordinary write tools:
        // - Allowed immediately if PolicyTier.ALWAYS, PolicyTier.ALLOW_TURN, per-session turn grant,
        //   confirmHighRisk==false, OR user explicitly chose "完全权限" (danger-full-access)!
        if (currentPolicy == PolicyTier.ALWAYS ||
            isTurnAllowed(sessionId, turnId) ||
            !confirmHighRisk.get() ||
            isFullAccessPreset
        ) {
            val modeTag = when {
                currentPolicy == PolicyTier.ALWAYS -> "policy_always"
                isTurnAllowed(sessionId, turnId) -> "turn_granted"
                isFullAccessPreset -> "full_access"
                else -> "confirm_off"
            }
            record(tool, targetPackage ?: "screen", true, "allowed:$modeTag")
            return ActionVerdict.Allow("allowed:$modeTag")
        }

        // Default ASK mode in workspace-write -> trigger native Liquid Glass out-of-app confirmation card!
        return ActionVerdict.NeedConfirm(
            reason = "requires_native_confirmation",
            allowTurnOption = true,
            riskBadge = "工作区安全确认"
        )
    }

    /** Legacy compatibility wrapper. */
    fun evaluateToolCall(
        tool: String,
        targetPackage: String?,
        isSensitiveTarget: Boolean = false,
        userApproved: Boolean = false
    ): Decision {
        return when (val v = evaluateAction(
            tool = tool,
            targetPackage = targetPackage,
            isSensitiveTarget = isSensitiveTarget,
            userApproved = userApproved
        )) {
            is ActionVerdict.Allow -> Decision(true, "ok")
            is ActionVerdict.NeedConfirm -> Decision(false, "requires_user_confirmation_or_allow_turn_policy")
            is ActionVerdict.Deny -> Decision(false, v.reason)
        }
    }

    fun recentAudit(limit: Int = 40): List<Map<String, Any>> {
        val list = auditLog.toList()
        val slice = if (list.size > limit) list.takeLast(limit) else list
        return slice.reversed().map { it.toMap() }
    }

    fun statusSnapshot(): Map<String, Any> = mapOf(
        "policy" to policy.get().name.lowercase(),
        "confirmHighRisk" to confirmHighRisk.get(),
        "autoReturnOnComplete" to autoReturnOnComplete.get(),
        "showEdgeAurora" to showEdgeAurora.get(),
        "showGestureFx" to showGestureFx.get(),
        "activeTurnLocked" to isTurnLockedNow(),
        "emergencyStopped" to emergencyStopped.get(),
        "paused" to paused.get(),
        "deniedPackagesCount" to hardDeniedPackages.size,
        "audit" to recentAudit(24)
    )

    private fun sessionKey(sessionId: String?, turnId: String?): String =
        sessionId?.takeIf { it.isNotBlank() && it != "null" }
            ?: turnId?.takeIf { it.isNotBlank() && it != "null" }
            ?: "default"

    fun recordAudit(tool: String, target: String, allowed: Boolean, reason: String) {
        record(tool, target, allowed, reason)
    }

    private fun record(tool: String, target: String, allowed: Boolean, reason: String) {
        synchronized(auditLock) {
            auditLog.add(AuditRecord(System.currentTimeMillis(), tool, target, allowed, reason))
            while (auditLog.size > 100) {
                auditLog.removeAt(0)
            }
        }
    }
}
