package dev.grassbag.grassbag

import android.content.Context
import android.content.SharedPreferences
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Hardcoded native-layer Phone Control security firewall (completely immune to prompt injection).
 *
 * Enforces:
 * 1. Denylisted financial, payment, wallet, Play Store, System Settings, and self packages.
 * 2. Password / OTP / biometric input field redaction and typing block.
 * 3. Active-turn policy lock (cannot loosen safety tier while an agent turn is in progress, with 5m watchdog TTL).
 * 4. Emergency stop kill-switch and in-memory audit trail for Settings -> Phone Control.
 */
object SafetyGate {
    enum class PolicyTier { ASK, ALLOW_TURN, ALWAYS }

    data class Decision(val allowed: Boolean, val reason: String)

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
    // Per-session active phone-control turns (`sessionKey -> startedAtMs`), preventing an unrelated
    // text-only session's `/v1/turn-end` from unlocking an active phone-control turn mid-flight!
    private val activeTurnsBySession = ConcurrentHashMap<String, Long>()
    private val emergencyStopped = AtomicBoolean(false)
    private val confirmHighRisk = AtomicBoolean(true)
    private val auditLog = CopyOnWriteArrayList<AuditRecord>()
    private val auditLock = Any()

    private val highRiskTools = setOf(
        "phone_tap", "phone_swipe", "phone_key", "phone_type", "phone_open", "phone_intent", "phone_shell"
    )
    private val packageRequiredTools = setOf(
        "phone_screen", "phone_tap", "phone_swipe", "phone_type"
    )

    fun init(ctx: Context) {
        if (prefs != null) return
        val p = ctx.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs = p
        val savedPolicy = p.getString("policy", "ASK") ?: "ASK"
        val tier = runCatching { PolicyTier.valueOf(savedPolicy) }.getOrDefault(PolicyTier.ASK)
        // Never persist ephemeral ALLOW_TURN across restarts.
        policy.set(if (tier == PolicyTier.ALLOW_TURN) PolicyTier.ASK else tier)
        confirmHighRisk.set(p.getBoolean("confirmHighRisk", true))
    }

    private fun isTurnLockedNow(): Boolean {
        if (activeTurnsBySession.isEmpty()) return false
        val now = System.currentTimeMillis()
        val it = activeTurnsBySession.entries.iterator()
        while (it.hasNext()) {
            val e = it.next()
            if (now - e.value > TURN_WATCHDOG_MS) {
                it.remove()
            }
        }
        if (activeTurnsBySession.isEmpty()) {
            policy.compareAndSet(PolicyTier.ALLOW_TURN, PolicyTier.ASK)
            return false
        }
        return true
    }

    private val hardDeniedPackages: Set<String> = setOf(
        "dev.grassbag.grassbag",
        "com.android.settings",
        "com.android.systemui",
        "com.android.keychain",
        "com.android.vending",
        "com.google.android.gms",
        "com.tencent.mm",
        "com.eg.android.AlipayGphone",
        "com.google.android.apps.walletnfcrel",
        "com.samsung.android.spay",
        "com.mipay.wallet",
        "com.huawei.wallet",
        "com.icbc",
        "com.chinamworld.main",
        "com.cmbchina",
        "com.bankcomm.Bankcomm",
        "com.unionpay",
        "com.abchina.ebank",
        "com.pingan.paces.ccms",
        "com.paypal.android.p2pmobile",
        "com.chase.sig.android",
        "com.android.packageinstaller",
        "com.google.android.packageinstaller",
        "com.android.permissioncontroller",
        "com.google.android.permissioncontroller",
        "com.miui.securitycenter",
        "com.lbe.security.miui",
        "com.coloros.safecenter",
        "com.huawei.systemmanager"
    )

    private val sensitiveKeywords = listOf(
        "password", "passcode",
        "密码", "支付密码", "验证码", "指纹", "人脸验证", "银行卡", "转账", "确认支付"
    )

    private val shortSensitiveTokenRe = Regex("\\b(pin|otp|cvv|cvc)\\b", RegexOption.IGNORE_CASE)

    fun setPolicy(tier: PolicyTier): Boolean {
        // Hard rule: never allow relaxing policy mid-turn!
        val current = policy.get()
        if (isTurnLockedNow() && tier.ordinal > current.ordinal) {
            record("policy", tier.name, false, "blocked_relax_during_active_turn")
            return false
        }
        policy.set(tier)
        if (tier != PolicyTier.ALLOW_TURN) {
            prefs?.edit()?.putString("policy", tier.name)?.apply()
        }
        return true
    }

    fun setConfirmHighRisk(enabled: Boolean) {
        confirmHighRisk.set(enabled)
        prefs?.edit()?.putBoolean("confirmHighRisk", enabled)?.apply()
    }

    fun isConfirmHighRisk(): Boolean = confirmHighRisk.get()

    fun getPolicy(): PolicyTier = policy.get()

    fun beginTurn(turnId: String?, sessionId: String? = null) {
        // Never auto-clear emergencyStopped here; only explicit user reset clears it.
        val key = sessionId?.takeIf { it.isNotBlank() && it != "null" }
            ?: turnId?.takeIf { it.isNotBlank() && it != "null" }
            ?: "default"
        activeTurnsBySession[key] = System.currentTimeMillis()
    }

    fun endTurn(sessionId: String? = null) {
        val key = sessionId?.takeIf { it.isNotBlank() && it != "null" }
        if (key != null) {
            activeTurnsBySession.remove(key)
        } else {
            activeTurnsBySession.clear()
        }
        // Revert ephemeral "本轮允许" back to ASK once no active phone-control turn remains.
        if (activeTurnsBySession.isEmpty()) {
            policy.compareAndSet(PolicyTier.ALLOW_TURN, PolicyTier.ASK)
        }
    }

    fun hasActiveTurn(): Boolean = isTurnLockedNow()

    fun triggerEmergencyStop() {
        emergencyStopped.set(true)
        activeTurnsBySession.clear()
        policy.compareAndSet(PolicyTier.ALLOW_TURN, PolicyTier.ASK)
        record("emergency_stop", "all", false, "user_triggered_stop")
    }

    fun resetEmergencyStop() {
        emergencyStopped.set(false)
    }

    fun isPackageBlocked(packageName: String?): Boolean {
        if (packageName.isNullOrBlank()) return false
        return hardDeniedPackages.contains(packageName) ||
            packageName.contains("bank", ignoreCase = true) ||
            packageName.contains("wallet", ignoreCase = true) ||
            packageName.contains("pay", ignoreCase = true)
    }

    fun isSensitiveNode(isPassword: Boolean, text: String?, hint: String?, viewId: String?): Boolean {
        if (isPassword) return true
        val combined = listOfNotNull(text, hint, viewId).joinToString(" ").lowercase()
        if (combined.isBlank()) return false
        return sensitiveKeywords.any { combined.contains(it) } ||
            shortSensitiveTokenRe.containsMatchIn(combined)
    }

    fun evaluateToolCall(
        tool: String,
        targetPackage: String?,
        isSensitiveTarget: Boolean = false,
        userApproved: Boolean = false
    ): Decision {
        if (emergencyStopped.get()) {
            return deny(tool, targetPackage ?: "-", "emergency_stop_active")
        }
        // Fail closed when target package is unknown for interactive screen tools.
        if (packageRequiredTools.contains(tool) && (targetPackage.isNullOrBlank() || targetPackage == "unknown")) {
            return deny(tool, "unknown", "unknown_foreground_package_fail_closed")
        }
        if (isPackageBlocked(targetPackage)) {
            return deny(tool, targetPackage ?: "-", "blocked_sensitive_package")
        }
        if (isSensitiveTarget && (tool == "phone_type" || tool == "phone_tap" || tool == "phone_swipe")) {
            return deny(tool, targetPackage ?: "-", "blocked_sensitive_input_field")
        }
        val currentPolicy = policy.get()
        if (!userApproved && currentPolicy == PolicyTier.ASK && confirmHighRisk.get() && highRiskTools.contains(tool)) {
            return deny(tool, targetPackage ?: "-", "requires_user_confirmation_or_allow_turn_policy")
        }
        val reason = if (userApproved) "allowed:user_approved" else "allowed:${currentPolicy.name.lowercase()}"
        record(tool, targetPackage ?: "screen", true, reason)
        return Decision(true, "ok")
    }

    fun recentAudit(limit: Int = 40): List<Map<String, Any>> {
        val list = auditLog.toList()
        val slice = if (list.size > limit) list.takeLast(limit) else list
        return slice.reversed().map { it.toMap() }
    }

    fun statusSnapshot(): Map<String, Any> = mapOf(
        "policy" to policy.get().name.lowercase(),
        "confirmHighRisk" to confirmHighRisk.get(),
        "activeTurnLocked" to isTurnLockedNow(),
        "emergencyStopped" to emergencyStopped.get(),
        "deniedPackagesCount" to hardDeniedPackages.size,
        "audit" to recentAudit(20)
    )

    private fun deny(tool: String, target: String, reason: String): Decision {
        record(tool, target, false, reason)
        return Decision(false, reason)
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
