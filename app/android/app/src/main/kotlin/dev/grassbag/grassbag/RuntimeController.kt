package dev.grassbag.grassbag

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.system.Os
import android.system.OsConstants
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.Collections
import java.util.LinkedList
import java.util.TimeZone
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

interface RuntimeAssetSource {
    val label: String
    fun loadManifest(): JSONObject?
    fun openStream(relPath: String): InputStream?
}

class BundledApkAssetSource(private val ctx: Context) : RuntimeAssetSource {
    override val label = "bundled-apk"
    @Volatile
    private var cachedManifestText: String? = null
    @Volatile
    private var manifestChecked = false

    fun hasBundledAssets(): Boolean {
        if (!manifestChecked) loadManifest()
        return cachedManifestText != null
    }

    override fun loadManifest(): JSONObject? {
        if (!manifestChecked) {
            cachedManifestText = runCatching {
                ctx.assets.open("runtime/runtime-manifest.json").use { it.bufferedReader().readText() }
            }.getOrNull()
            manifestChecked = true
        }
        val text = cachedManifestText ?: return null
        return runCatching { JSONObject(text) }.getOrNull()
    }

    override fun openStream(relPath: String): InputStream? = runCatching {
        ctx.assets.open(relPath)
    }.getOrNull()
}

class RemoteHttpAssetSource(private val rootUrl: String) : RuntimeAssetSource {
    override val label = "remote-https"
    override fun loadManifest(): JSONObject? = runCatching {
        val c = (URL("${rootUrl.trimEnd('/')}/runtime-manifest.json").openConnection() as HttpURLConnection).apply {
            connectTimeout = 8000
            readTimeout = 10000
        }
        try {
            if (c.responseCode in 200..299) c.inputStream.use { JSONObject(it.bufferedReader().readText()) } else null
        } finally {
            c.disconnect()
        }
    }.getOrNull()

    override fun openStream(relPath: String): InputStream? = runCatching {
        val c = (URL("${rootUrl.trimEnd('/')}/${relPath.trimStart('/')}").openConnection() as HttpURLConnection).apply {
            connectTimeout = 8000
            readTimeout = 30000
        }
        if (c.responseCode in 200..299) c.inputStream else null
    }.getOrNull()
}

class RuntimeController private constructor(
    private val ctx: Context,
    private val vault: KeystoreVault
) {
    private data class ShellSession(
        val proc: Process,
        val usesPtyBridge: Boolean,
        val cwd: String
    )

    private val listeners = CopyOnWriteArraySet<(String, Map<String, Any?>) -> Unit>()
    private val worker = Executors.newCachedThreadPool()
    private val toolkitExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "grassbag-toolkit").apply { isDaemon = true }
    }
    private val activeToolkitInstalls = java.util.concurrent.atomic.AtomicInteger(0)
    private val coalesceScheduler = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "grassbag-event-coalesce").apply { isDaemon = true }
    }
    // 16ms PTY output coalescer (per tabId) with 64KB immediate backpressure flush
    // so heavy `cat`/`npm install` bursts never starve Android's UI Looper.
    private val termPendingLock = Any()
    private val termPendingBuffers = LinkedHashMap<String, StringBuilder>()
    private var termFlushScheduled = false
    // 200ms engine log batching so container boot/apt output crosses EventChannel once per 200ms.
    private val logBatchLock = Any()
    private val pendingLogBatch = ArrayList<String>()
    private var logBatchScheduled = false
    // 180ms progress throttle so tight extraction loops never spam EventChannel.
    private val progressLock = Any()
    private var lastProgressStage: String? = null
    private var lastProgressPct: Int = -1
    private var lastProgressAtMs: Long = 0L
    // In-memory cached copy of runtime-meta.json invalidated on writeMeta().
    private var cachedMetaText: String? = null

    /**
     * Dedicated permanent single-thread process spawner.
     * CRITICAL: `libtawcroot.so` arms Linux `prctl(PR_SET_PDEATHSIG, SIGKILL)`, which binds
     * to the spawning OS THREAD (not process). Spawning via `CachedThreadPool` causes Linux
     * to SIGKILL DSH / shells with exit code 137 exactly 60s later when the idle pool thread
     * expires! This core thread never times out while the app lives, and cleanly reaps child
     * container processes if the app process terminates.
     */
    private val processSpawner = Executors.newSingleThreadExecutor { r ->
        Thread(r, "GrassBag-ProcessSpawner").apply {
            isDaemon = false
            priority = Thread.NORM_PRIORITY
        }
    }

    private fun spawnProcess(pb: ProcessBuilder): Process {
        val result = processSpawner.submit<Result<Process>> {
            runCatching { pb.start() }
        }.get()
        return result.getOrThrow()
    }

    private val bundled = BundledApkAssetSource(ctx)
    private val shells = ConcurrentHashMap<String, ShellSession>()

    val homeDir = File(ctx.filesDir, "volumes/home")
    val slotsRoot = File(ctx.filesDir, "volumes/dsh-slots")
    val slotA = File(slotsRoot, "slot-a")
    val slotB = File(slotsRoot, "slot-b")
    val containersRoot = File(ctx.filesDir, "containers")
    val ubuntuRoot = File(containersRoot, "ubuntu-24.04.5")
    val shimsRoot = File(ctx.filesDir, "shims")
    val runRoot = File(ctx.filesDir, "run")
    val prootTmpDir = File(ctx.cacheDir, "proot-tmp")
    val tawcTmpDir = File(ctx.cacheDir, "tawc-tmp")

    private val metaFile = File(slotsRoot, "runtime-state.json")
    private val aptFile = File(homeDir, ".grassbag/apt-manifest.json")
    private val pidFile = File(runRoot, "dsh-engine.pid")

    val bridgeSocket = File(runRoot, "bridge.sock")
    val phoneSocket = File(runRoot, "phone-control.sock")
    val droidSocket = File(runRoot, "droid.sock")

    val bridgeToken: String
    private val phoneDaemon: PhoneControlDaemon
    private val droidDaemon: DroidBridgeDaemon

    @Volatile
    private var dshProcess: Process? = null
    @Volatile
    private var adoptedRunning: Boolean = false
    @Volatile
    private var engineState: String = "stopped" // stopped | starting | running | error
    @Volatile
    private var lastEngineError: String? = null
    @Volatile
    private var lastCapabilitiesDshVersion: String? = null
    @Volatile
    private var dshWebUrl: String? = null
    @Volatile
    private var ptySupportedCache: Boolean? = null
    @Volatile
    private var activeExecutorUsed: String? = null
    @Volatile
    private var etcPrepared: Boolean = false
    @Volatile
    private var cachedHomeSizeKb: Long = 0L
    @Volatile
    private var lastHomeSizeAtMs: Long = 0L
    @Volatile
    private var activeStartupLatch: CountDownLatch? = null

    private val homeSizeRefreshing = AtomicBoolean(false)
    private val prewarmTriggered = AtomicBoolean(false)
    private val networkCallbackRegistered = AtomicBoolean(false)
    private val lastNetworkNotifyMs = AtomicLong(0L)
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val engineLogs = Collections.synchronizedList(LinkedList<String>())
    private val engineLock = Any()
    private val bootstrapLock = Any()
    private val metaLock = Any()
    private val readinessSignal = Object()

    fun addListener(listener: (String, Map<String, Any?>) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (String, Map<String, Any?>) -> Unit) {
        listeners.remove(listener)
    }

    fun currentEngineStateEvent(): Map<String, Any?> {
        val alive = isEngineAlive()
        val effective = if (alive) engineState else if (engineState == "running") "stopped" else engineState
        return mapOf(
            "state" to effective,
            "error" to lastEngineError,
            "dshWebUrl" to (dshWebUrl ?: "http://127.0.0.1:$LOCAL_DSH_PORT"),
            "udsReady" to (alive && effective == "running" && bridgeSocket.exists())
        )
    }

    fun ensureForegroundServiceIfRunning() {
        worker.execute {
            runCatching {
                if (isEngineAlive() && engineState == "running" && !GrassBagEngineService.isServiceActive()) {
                    val ver = lastCapabilitiesDshVersion ?: readMeta().optString("dshVersion", "0.2.2-rc.5")
                    val exec = activeExecutorUsed ?: effectiveExecutorMode()
                    GrassBagEngineService.startOrUpdate(
                        ctx,
                        "GrassBag 本机引擎运行中",
                        "DSH $ver ($exec) · 后台保活中"
                    )
                }
            }
        }
    }

    private fun emit(type: String, payload: Map<String, Any?>) {
        for (l in listeners) {
            runCatching { l(type, payload) }
        }
    }

    init {
        SafetyGate.init(ctx)
        prepareLayout()
        registerNetworkDnsWatcher()
        bridgeToken = vault.getSecret("local_bridge_token")
            ?: vault.generateRandomToken(32).also { vault.putSecret("local_bridge_token", it) }
        val pTok = vault.getSecret("local_phone_token")
            ?: vault.generateRandomToken(24).also { vault.putSecret("local_phone_token", it) }
        val dTok = vault.getSecret("local_droid_token")
            ?: vault.generateRandomToken(24).also { vault.putSecret("local_droid_token", it) }
        phoneDaemon = PhoneControlDaemon(ctx, phoneSocket, pTok, ::emit)
        droidDaemon = DroidBridgeDaemon(ctx, droidSocket, dTok)
        phoneDaemon.start()
        droidDaemon.start()
    }

    private fun registerNetworkDnsWatcher() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        if (!networkCallbackRegistered.compareAndSet(false, true)) return
        runCatching {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
            fun notifyNetworkChanged() {
                val now = System.currentTimeMillis()
                val prev = lastNetworkNotifyMs.get()
                if (now - prev >= 500L && lastNetworkNotifyMs.compareAndSet(prev, now)) {
                    emit("network_changed", mapOf("ts" to now))
                }
            }
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    worker.execute {
                        refreshContainerDns()
                        notifyNetworkChanged()
                    }
                }
                override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                    worker.execute {
                        refreshContainerDns()
                        notifyNetworkChanged()
                    }
                }
            }
            networkCallback = cb
            cm.registerDefaultNetworkCallback(cb)
        }.onFailure {
            networkCallbackRegistered.set(false)
        }
    }

    private fun prepareLayout() {
        listOf(
            homeDir,
            File(homeDir, "workspace"),
            File(homeDir, ".dsh"),
            File(homeDir, ".cache/node-compile-cache"),
            File(homeDir, ".local/bin"),
            File(homeDir, ".grassbag"),
            slotA,
            slotB,
            containersRoot,
            shimsRoot,
            runRoot,
            prootTmpDir,
            tawcTmpDir
        ).forEach { it.mkdirs() }

        runRoot.setReadable(false, false)
        runRoot.setWritable(false, false)
        runRoot.setExecutable(false, false)
        runRoot.setReadable(true, true)
        runRoot.setWritable(true, true)
        runRoot.setExecutable(true, true)

        if (!aptFile.exists()) {
            aptFile.writeText(
                JSONObject()
                    .put("packages", JSONArray(listOf("ubuntu-base-24.04.5", "nodejs-24.22.3", "dsh-0.2.2-rc.5")))
                    .toString(2)
            )
        }
        if (ubuntuRoot.exists()) {
            ensureContainerEtcFiles()
        }
    }

    private fun resolveSystemDnsServers(): List<String> {
        val list = LinkedHashSet<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            runCatching {
                val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                val lp = cm?.getLinkProperties(cm.activeNetwork)
                lp?.dnsServers?.forEach { addr ->
                    if (addr.isLoopbackAddress || addr.isLinkLocalAddress) return@forEach
                    val host = addr.hostAddress?.substringBefore('%')?.trim()
                    if (!host.isNullOrEmpty() && host != "127.0.0.1" && host != "::1" && !host.startsWith("fe80:", ignoreCase = true)) {
                        list.add(host)
                    }
                }
            }
        }
        list.add("223.5.5.5")
        list.add("8.8.8.8")
        list.add("1.1.1.1")
        return list.toList()
    }

    private fun resolveSystemProxyUrl(): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        return runCatching {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return null
            val proxy = cm.defaultProxy ?: return null
            val host = proxy.host?.trim()
            val port = proxy.port
            if (!host.isNullOrEmpty() && port > 0) "http://$host:$port" else null
        }.getOrNull()
    }

    private fun refreshContainerDns() {
        if (!ubuntuRoot.exists()) return
        runCatching {
            val etcDir = File(ubuntuRoot, "etc")
            etcDir.mkdirs()
            val wantResolv = resolveSystemDnsServers().joinToString("\n", postfix = "\n") { "nameserver $it" }
            val resolv = File(etcDir, "resolv.conf")
            val curResolv = runCatching { if (resolv.isFile) resolv.readText() else null }.getOrNull()
            if (curResolv != wantResolv) {
                runCatching { Os.remove(resolv.absolutePath) }
                if (resolv.exists()) resolv.delete()
                resolv.writeText(wantResolv)
            }
        }
    }

    private fun writeAndroidCordisPatch(patchFile: File) {
        patchFile.parentFile?.mkdirs()
        // Insert zero-patch dsh-gbridge and disable dead desktop-only/telemetry plugins on Android
        // (including heavy OpenTelemetry / got SDK) so DSH boots noticeably faster!
        patchFile.writeText(
            """
            # grassbag-patch-v2
            - insert:
              - name: /opt/dsh-slots/current/dsh-gbridge/lib/index.js
            - id: otel
              disabled: true
            - id: session-telemetry-otel
              disabled: true
            - id: desktop-product-telemetry
              disabled: true
            - id: product-analytics
              disabled: true
            - id: office-kit
              disabled: true
            - id: client-hmr
              disabled: true
            - id: open-in-app
              disabled: true
            - id: ui-open-in-app
              disabled: true
            - id: harness-dev-context
              disabled: true
            - id: directory-picker
              disabled: true
            """.trimIndent() + "\n"
        )
    }

    private fun ensureContainerEtcFiles(force: Boolean = false) {
        if (etcPrepared && !force) return
        runCatching {
            val etcDir = File(ubuntuRoot, "etc")
            etcDir.mkdirs()
            val containerTmp = File(ubuntuRoot, "tmp").apply { mkdirs() }
            val containerVarTmp = File(ubuntuRoot, "var/tmp").apply { mkdirs() }
            File(ubuntuRoot, "var/cache/apt/archives/partial").mkdirs()
            File(ubuntuRoot, "var/lib/apt/lists/partial").mkdirs()
            prootTmpDir.mkdirs()
            tawcTmpDir.mkdirs()
            // Ensure sticky 01777 permissions on /tmp & /var/tmp so apt/dpkg/npm/mktemp/python never fail.
            runCatching { Os.chmod(containerTmp.absolutePath, 0x3FF) }
            runCatching { Os.chmod(containerVarTmp.absolutePath, 0x3FF) }
            runCatching { Os.chmod(prootTmpDir.absolutePath, 0x3FF) }
            runCatching { Os.chmod(tawcTmpDir.absolutePath, 0x3FF) }

            // Write live Android system DNS servers first (VPN/IPv6-5G/corporate Wi-Fi compatible)
            // ahead of reliable public fallbacks so apt/curl/git/python/DSH DNS always resolves.
            refreshContainerDns()

            val hosts = File(etcDir, "hosts")
            if (!hosts.exists() || hosts.length() == 0L) {
                hosts.writeText("127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n")
            }

            // Configure APT & dpkg for single-UID unprivileged Android containers:
            // - Avoids `_apt` setgroups/seccomp failures and `/dev/pts` PTY hangs (`DPkg::Use-Pty "0"`)
            // - Non-interactive config conflict handling (`--force-confdef --force-confold`)
            // - Automatic broken-dep recovery + mobile network retries
            val aptConfDir = File(etcDir, "apt/apt.conf.d").apply { mkdirs() }
            val aptConf = File(aptConfDir, "99grassbag")
            val wantAptConf = buildString {
                append("APT::Sandbox::User \"root\";\n")
                append("APT::Sandbox::Seccomp \"false\";\n")
                append("DPkg::Use-Pty \"0\";\n")
                append("DPkg::Options { \"--force-confdef\"; \"--force-confold\"; };\n")
                append("APT::Get::Fix-Broken \"true\";\n")
                append("Acquire::Languages \"none\";\n")
                append("Acquire::GzipIndexes \"true\";\n")
                append("Acquire::CompressionTypes::Order:: \"gz\";\n")
                append("Acquire::http::Pipeline-Depth \"5\";\n")
                append("Acquire::Retries \"3\";\n")
                append("Acquire::http::Timeout \"30\";\n")
                append("Acquire::https::Timeout \"30\";\n")
            }
            if (!aptConf.exists() || runCatching { aptConf.readText() }.getOrNull() != wantAptConf) {
                aptConf.writeText(wantAptConf)
            }

            // Allow pip/pip3 installs directly inside the isolated container (Ubuntu 24.04 PEP 668).
            val pipConf = File(etcDir, "pip.conf")
            val wantPipConf = "[global]\nbreak-system-packages = true\n"
            if (!pipConf.exists() || runCatching { pipConf.readText() }.getOrNull() != wantPipConf) {
                pipConf.writeText(wantPipConf)
            }

            // Speed up dpkg unpack 3-5x on Android flash (`force-unsafe-io`) and omit bulky docs/manpages.
            val dpkgConfDir = File(etcDir, "dpkg/dpkg.cfg.d").apply { mkdirs() }
            val dpkgConf = File(dpkgConfDir, "99grassbag")
            val wantDpkgConf = buildString {
                append("force-unsafe-io\n")
                append("path-exclude=/usr/share/man/*\n")
                append("path-exclude=/usr/share/info/*\n")
                append("path-exclude=/usr/share/doc/*\n")
                append("path-include=/usr/share/doc/*/copyright\n")
            }
            if (!dpkgConf.exists() || runCatching { dpkgConf.readText() }.getOrNull() != wantDpkgConf) {
                dpkgConf.writeText(wantDpkgConf)
            }

            // Standard Debian/Ubuntu container policy-rc.d: prevents package postinst scripts
            // from trying to start systemd/SysV background daemons inside the container.
            val policyRc = File(ubuntuRoot, "usr/sbin/policy-rc.d")
            val wantPolicyRc = "#!/bin/sh\nexit 101\n"
            if (!policyRc.exists() || runCatching { policyRc.readText() }.getOrNull() != wantPolicyRc) {
                policyRc.parentFile?.mkdirs()
                policyRc.writeText(wantPolicyRc)
                runCatching { Os.chmod(policyRc.absolutePath, 0x1ED) } // 0755
            }

            // Ensure system CA certificate bundle exists for curl/git/python/pip/HTTPS apt even on existing containers.
            val bundledCa = File(shimsRoot, "ca-certificates.crt")
            if (bundledCa.isFile && bundledCa.length() > 4096L) {
                val caDst = File(etcDir, "ssl/certs/ca-certificates.crt")
                if (!caDst.exists() || caDst.length() < 4096L) {
                    caDst.parentFile?.mkdirs()
                    runCatching { Os.remove(caDst.absolutePath) }
                    bundledCa.copyTo(caDst, overwrite = true)
                }
            }

            // Seed default /root/.bashrc and /root/.profile so interactive bash terminals have colors, prompt & PATH.
            val bashrc = File(homeDir, ".bashrc")
            if (!bashrc.exists()) {
                bashrc.writeText(
                    """
                    export PATH="/usr/local/bin:/opt/shims/droid-bin:/root/.local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                    export PS1='\u@grassbag:\w\$ '
                    alias ls='ls --color=auto'
                    alias ll='ls -la --color=auto'
                    [ -f /etc/profile.d/grassbag.sh ] && . /etc/profile.d/grassbag.sh
                    """.trimIndent() + "\n"
                )
            }
            val profile = File(homeDir, ".profile")
            if (!profile.exists()) {
                profile.writeText(
                    """
                    [ -f /etc/profile.d/grassbag.sh ] && . /etc/profile.d/grassbag.sh
                    [ -n "${'$'}BASH_VERSION" ] && [ -f "${'$'}HOME/.bashrc" ] && . "${'$'}HOME/.bashrc"
                    """.trimIndent() + "\n"
                )
            }

            // Register Android supplemental GIDs into /etc/group so bash/script PTY starts cleanly
            // without "groups: cannot find name for group ID xxxx" warnings.
            val groupFile = File(etcDir, "group")
            if (groupFile.exists()) {
                val existingText = groupFile.readText()
                val existingGids = Regex(""":x:(\d+):""").findAll(existingText).map { it.groupValues[1] }.toHashSet()
                val statusLine = runCatching {
                    File("/proc/self/status").readLines().firstOrNull { it.startsWith("Groups:") }
                }.getOrNull()
                val currentGids = mutableSetOf<String>()
                runCatching { currentGids.add(Os.getgid().toString()) }
                statusLine?.substringAfter("Groups:")?.trim()?.split(Regex("\\s+"))?.forEach { token ->
                    if (token.matches(Regex("\\d+"))) currentGids.add(token)
                }
                val toAppend = currentGids.filter { it != "0" && !existingGids.contains(it) }
                if (toAppend.isNotEmpty()) {
                    val sb = StringBuilder()
                    if (existingText.isNotEmpty() && !existingText.endsWith("\n")) sb.append("\n")
                    for (gid in toAppend) {
                        sb.append("aid_$gid:x:$gid:root\n")
                    }
                    groupFile.appendText(sb.toString())
                }
            }
            etcPrepared = true
        }
    }

    private fun updateRelativeSymlink(linkFile: File, relativeTarget: String) {
        runCatching { Os.remove(linkFile.absolutePath) }
        if (linkFile.exists()) linkFile.delete()
        Os.symlink(relativeTarget, linkFile.absolutePath)
    }

    private fun readMeta(): JSONObject = synchronized(metaLock) {
        val cached = cachedMetaText
        if (cached != null) {
            runCatching { return@synchronized JSONObject(cached) }
        }
        if (metaFile.exists()) {
            runCatching {
                val text = metaFile.readText()
                cachedMetaText = text
                return@synchronized JSONObject(text)
            }
        }
        JSONObject()
            .put("initialized", false)
            .put("activeSlot", "slot-a")
            .put("lkgSlot", "slot-a")
            .put("dshVersion", "0.2.2-rc.5")
            .put("dshPrevVersion", "")
            .put("bridgeVersion", "0.1.0")
            .put("containerVersion", "Ubuntu 24.04.5 · Node 24.22.3")
            .put("executorMode", detectExecutor())
    }

    private fun writeMeta(obj: JSONObject) = synchronized(metaLock) {
        val text = obj.toString(2)
        metaFile.parentFile?.mkdirs()
        val tmp = File(metaFile.parentFile, "${metaFile.name}.tmp")
        FileOutputStream(tmp).use { fos ->
            fos.write(text.toByteArray(Charsets.UTF_8))
            fos.flush()
            runCatching { fos.fd.sync() }
        }
        if (!tmp.renameTo(metaFile)) {
            metaFile.writeText(text)
            runCatching { tmp.delete() }
        }
        cachedMetaText = text
    }

    fun detectExecutor(): String {
        val libs = File(ctx.applicationInfo.nativeLibraryDir)
        return when {
            File(libs, "libtawcroot.so").exists() -> "tawcroot"
            File(libs, "libproot.so").exists() -> "proot"
            File("/system/bin/su").exists() || File("/system/xbin/su").exists() -> "chroot"
            else -> "android-sh"
        }
    }

    fun isContainerExtracted(): Boolean {
        val hasNode = File(ubuntuRoot, "usr/local/bin/node").exists()
        val hasBash = File(ubuntuRoot, "bin/bash").exists() || File(ubuntuRoot, "usr/bin/bash").exists()
        val hasLibc = File(ubuntuRoot, "usr/lib/aarch64-linux-gnu/libc.so.6").exists() ||
            File(ubuntuRoot, "lib/aarch64-linux-gnu/libc.so.6").exists()
        val hasLoader = File(ubuntuRoot, "usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1").exists() ||
            File(ubuntuRoot, "lib/aarch64-linux-gnu/ld-linux-aarch64.so.1").exists() ||
            File(ubuntuRoot, "lib/ld-linux-aarch64.so.1").exists()
        val marker = File(ubuntuRoot, ".extract-complete")
        val legacyPartial = File(ubuntuRoot, ".extracting").exists()
        if (legacyPartial) return false
        return hasNode && hasBash && hasLibc && hasLoader && (marker.exists() || readMeta().optBoolean("initialized", false))
    }

    fun isSlotExtracted(slotName: String = readMeta().optString("activeSlot", "slot-a")): Boolean {
        val dir = if (slotName == "slot-b") slotB else slotA
        if (File(dir, ".extracting").exists()) return false
        val hasDsh = File(dir, "node_modules/@deepseek-ai/dsh/lib/bin.js").exists()
        val hasBoot = File(dir, "node_modules/@deepseek-ai/dsh-app-boot/lib/index.js").exists()
        val hasBridge = File(dir, "dsh-gbridge/lib/index.js").exists()
        val marker = File(dir, ".extract-complete")
        return hasDsh && hasBoot && hasBridge && (marker.exists() || readMeta().optBoolean("initialized", false))
    }

    private fun readProcStat(pid: Int): Pair<String, Int>? = runCatching {
        val text = File("/proc/$pid/stat").readText()
        val closeParen = text.lastIndexOf(')')
        if (closeParen < 0 || closeParen + 2 >= text.length) return@runCatching null
        val parts = text.substring(closeParen + 2).trim().split(Regex("\\s+"))
        if (parts.size < 3) return@runCatching null
        val state = parts[0]
        val pgrp = parts[2].toIntOrNull() ?: -1
        state to pgrp
    }.getOrNull()

    private fun isValidEnginePid(pid: Int): Boolean {
        if (pid <= 1 || pid == android.os.Process.myPid()) return false
        val stat = readProcStat(pid) ?: return false
        if (stat.first == "Z" || stat.first == "X") return false
        val cmdline = runCatching {
            File("/proc/$pid/cmdline").readBytes().toString(Charsets.UTF_8).replace('\u0000', ' ')
        }.getOrNull() ?: return false
        if (cmdline.isBlank()) return false
        return cmdline.contains("tawcroot", ignoreCase = true) ||
            cmdline.contains("proot", ignoreCase = true) ||
            cmdline.contains("node", ignoreCase = true) ||
            cmdline.contains("dsh", ignoreCase = true)
    }

    fun isEngineAlive(): Boolean {
        val p = dshProcess
        if (p == null) {
            if (!adoptedRunning) return false
            // Verify adopted process is still actually alive (not exited, zombie, or recycled PID).
            val recordedPid = runCatching {
                if (pidFile.exists()) pidFile.readText().trim().toIntOrNull() else null
            }.getOrNull()
            if (recordedPid != null && recordedPid > 1) {
                if (!isValidEnginePid(recordedPid)) {
                    adoptedRunning = false
                    if (engineState == "running") {
                        engineState = "stopped"
                        runCatching { if (bridgeSocket.exists()) bridgeSocket.delete() }
                        runCatching { if (pidFile.exists()) pidFile.delete() }
                        GrassBagEngineService.stop(ctx)
                        emit("engine_state", mapOf("state" to "stopped"))
                    }
                    return false
                }
                return true
            }
            return probeLocalCapabilities() != null
        }
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) p.isAlive else {
                p.exitValue()
                false
            }
        }.getOrDefault(true)
    }

    fun detectInstalledToolkits(): List<String> {
        val found = mutableListOf<String>()
        if (isContainerExtracted()) found.add("core-node")
        // Verify full toolkit readiness (never falsely report half-installed broken apt runs as installed!)
        if (File(ubuntuRoot, "usr/bin/python3").exists() &&
            File(ubuntuRoot, "usr/bin/pip3").exists()
        ) {
            found.add("python-uv")
        }
        if (File(ubuntuRoot, "usr/bin/git").exists() &&
            File(ubuntuRoot, "usr/bin/rg").exists() &&
            File(ubuntuRoot, "usr/bin/jq").exists() &&
            File(ubuntuRoot, "usr/bin/sqlite3").exists() &&
            File(ubuntuRoot, "usr/bin/curl").exists()
        ) {
            found.add("dev-git-cli")
        }
        if (File(ubuntuRoot, "usr/bin/ffmpeg").exists() &&
            File(ubuntuRoot, "usr/bin/pandoc").exists() &&
            (File(ubuntuRoot, "usr/bin/convert").exists() || File(ubuntuRoot, "usr/bin/magick").exists())
        ) {
            found.add("media-office")
        }
        return found
    }

    fun effectiveExecutorMode(meta: JSONObject = readMeta()): String {
        val libs = File(ctx.applicationInfo.nativeLibraryDir)
        val hasTawc = File(libs, "libtawcroot.so").exists()
        val hasProot = File(libs, "libproot.so").exists()
        val pinned = meta.optBoolean("executorModePinned", false)
        val stored = meta.optString("executorMode", "")
        val tawcUnsupportedFp = meta.optString("tawcUnsupportedFingerprint", "")
        val tawcSupportedOnDevice = hasTawc && tawcUnsupportedFp != Build.FINGERPRINT
        if (pinned && stored.isNotEmpty()) {
            if (stored == "tawcroot" && hasTawc) return "tawcroot"
            if (stored == "proot" && hasProot) return "proot"
        }
        return when {
            tawcSupportedOnDevice -> "tawcroot"
            hasProot -> "proot"
            else -> detectExecutor()
        }
    }

    private fun refreshHomeSizeAsyncIfStale() {
        val now = System.currentTimeMillis()
        // Keep home size estimation lightweight: 10-minute cooldown, maxDepth(3), capped at 2000 files
        // so large workspaces / node_modules never stall background disk I/O during getStatus() polling.
        if (now - lastHomeSizeAtMs < 600_000L && lastHomeSizeAtMs > 0L) return
        if (!homeSizeRefreshing.compareAndSet(false, true)) return
        worker.execute {
            try {
                var bytes = 0L
                var count = 0
                for (f in homeDir.walkTopDown().maxDepth(3)) {
                    if (f.isFile) {
                        bytes += f.length()
                        count++
                        if (count >= 2000) break
                    }
                }
                cachedHomeSizeKb = bytes / 1024L
                lastHomeSizeAtMs = System.currentTimeMillis()
            } catch (_: Throwable) {
            } finally {
                homeSizeRefreshing.set(false)
            }
        }
    }

    private fun hasPendingFastOverlayUpdate(activeSlot: String): Boolean {
        val manifest = bundled.loadManifest() ?: return false
        val arts = manifest.optJSONObject("artifacts") ?: return false
        val st = readMeta()
        arts.optJSONObject("shims")?.let { art ->
            val wantSha = art.optString("sha256", "")
            val prevSha = st.optString("shimsSha256", "")
            if (!File(shimsRoot, "android-shim.mjs").exists() ||
                !File(shimsRoot, "pty-bridge.mjs").exists() ||
                (wantSha.isNotEmpty() && wantSha != prevSha)
            ) {
                return true
            }
        }
        arts.optJSONObject("gbridge")?.let { art ->
            val wantSha = art.optString("sha256", "")
            val prevSha = st.optString("gbridgeSha256_$activeSlot", st.optString("gbridgeSha256", ""))
            val targetSlotDir = if (activeSlot == "slot-b") slotB else slotA
            val bridgeDir = File(targetSlotDir, "dsh-gbridge")
            if (!File(bridgeDir, "lib/index.js").exists() || (wantSha.isNotEmpty() && wantSha != prevSha)) {
                return true
            }
        }
        return false
    }

    /**
     * Eagerly sync tiny shims/gbridge overlays (if APK updated) and start the local DSH engine
     * on a background thread from MainActivity.onCreate() so boot overlaps Flutter initialization.
     */
    fun prewarmIfReady() {
        if (!prewarmTriggered.compareAndSet(false, true)) return
        worker.execute {
            runCatching {
                val st = readMeta()
                val activeSlot = st.optString("activeSlot", "slot-a")
                if (!st.optBoolean("initialized", false) || !isContainerExtracted() || !isSlotExtracted(activeSlot)) {
                    return@execute
                }
                syncFastOverlaysIfNeeded(activeSlot)
                if (engineState == "stopped" && !isEngineAlive()) {
                    startEngineSync()
                }
            }.onFailure {
                Log.w(TAG, "prewarmIfReady skipped: ${it.message}")
            }
        }
    }

    /**
     * Fast-path atomic overlay updater (~20-50ms): refreshes tiny `shims.gbag` (~3KB) and `gbridge.gbag` (~60KB)
     * on APK upgrades WITHOUT re-extracting the 121MB `engine-init.gbag` or clobbering concurrent metadata writes!
     */
    private fun syncFastOverlaysIfNeeded(activeSlot: String): Boolean {
        val manifest = bundled.loadManifest() ?: return false
        val arts = manifest.optJSONObject("artifacts") ?: return false
        var updated = false
        synchronized(bootstrapLock) {
            val st = readMeta()
            arts.optJSONObject("shims")?.let { art ->
                val wantSha = art.optString("sha256", "")
                val prevSha = st.optString("shimsSha256", "")
                val needShims = !File(shimsRoot, "android-shim.mjs").exists() ||
                    !File(shimsRoot, "pty-bridge.mjs").exists() ||
                    (wantSha.isNotEmpty() && wantSha != prevSha)
                if (needShims) {
                    val stageDir = File(ctx.filesDir, "shims.stage-${System.currentTimeMillis()}")
                    TarGzExtractor.deleteTreeNoFollow(stageDir)
                    bundled.openStream(art.optString("asset"))?.use { ins ->
                        TarGzExtractor.extractStream(ins, stageDir, wantSha, art.optLong("bytes", 0L), freshDir = true)
                    } ?: error("无法读取 ${art.optString("asset")}")
                    TarGzExtractor.deleteTreeNoFollow(shimsRoot)
                    if (!stageDir.renameTo(shimsRoot)) {
                        stageDir.copyRecursively(shimsRoot, overwrite = true)
                        TarGzExtractor.deleteTreeNoFollow(stageDir)
                    }
                    if (wantSha.isNotEmpty()) st.put("shimsSha256", wantSha)
                    etcPrepared = false
                    updated = true
                }
            }
            arts.optJSONObject("gbridge")?.let { art ->
                val wantSha = art.optString("sha256", "")
                val prevSha = st.optString("gbridgeSha256_$activeSlot", st.optString("gbridgeSha256", ""))
                val targetSlotDir = if (activeSlot == "slot-b") slotB else slotA
                val bridgeDir = File(targetSlotDir, "dsh-gbridge")
                val patchFile = File(bridgeDir, "cordis.patch.yml")
                val needBridge = !File(bridgeDir, "lib/index.js").exists() ||
                    (wantSha.isNotEmpty() && wantSha != prevSha)
                if (needBridge) {
                    val stageDir = File(targetSlotDir, "dsh-gbridge.stage-${System.currentTimeMillis()}")
                    TarGzExtractor.deleteTreeNoFollow(stageDir)
                    bundled.openStream(art.optString("asset"))?.use { ins ->
                        TarGzExtractor.extractStream(ins, stageDir, wantSha, art.optLong("bytes", 0L), freshDir = true)
                    } ?: error("无法读取 ${art.optString("asset")}")
                    writeAndroidCordisPatch(File(stageDir, "cordis.patch.yml"))
                    TarGzExtractor.deleteTreeNoFollow(bridgeDir)
                    if (!stageDir.renameTo(bridgeDir)) {
                        stageDir.copyRecursively(bridgeDir, overwrite = true)
                        TarGzExtractor.deleteTreeNoFollow(stageDir)
                    }
                    if (wantSha.isNotEmpty()) {
                        st.put("gbridgeSha256", wantSha)
                        st.put("gbridgeSha256_$activeSlot", wantSha)
                    }
                    updated = true
                } else if (!patchFile.exists() || !runCatching { patchFile.readText().contains("grassbag-patch-v2") }.getOrDefault(false)) {
                    writeAndroidCordisPatch(patchFile)
                }
            }
            if (updated) {
                writeMeta(st)
                if (ubuntuRoot.exists()) ensureContainerEtcFiles(force = true)
            }
        }
        return updated
    }

    fun getStatus(): Map<String, Any?> {
        val m = readMeta()
        val libs = File(ctx.applicationInfo.nativeLibraryDir)
        refreshHomeSizeAsyncIfStale()
        val activeSlot = m.optString("activeSlot", "slot-a")
        val lkgSlot = m.optString("lkgSlot", "slot-a")
        val containerOk = isContainerExtracted()
        val slotOk = isSlotExtracted(activeSlot)
        val extracted = containerOk && slotOk
        val alive = isEngineAlive()
        val running = alive && engineState == "running"
        val configuredExec = effectiveExecutorMode(m)
        val effectiveExec = activeExecutorUsed ?: configuredExec
        val canRollback = lkgSlot != activeSlot && isSlotExtracted(lkgSlot)
        return mapOf(
            "initialized" to (m.optBoolean("initialized", false) && extracted),
            "containerExtracted" to containerOk,
            "slotExtracted" to slotOk,
            "engineState" to (if (alive) engineState else if (engineState == "running") "stopped" else engineState),
            "engineRunning" to running,
            "engineError" to lastEngineError,
            "activeSlot" to activeSlot,
            "lkgSlot" to lkgSlot,
            "canRollback" to canRollback,
            "dshVersion" to (lastCapabilitiesDshVersion ?: m.optString("dshVersion", "0.2.2-rc.5")),
            "dshPrevVersion" to (if (canRollback) m.optString("dshPrevVersion", "") else ""),
            "bridgeVersion" to m.optString("bridgeVersion", "0.1.0"),
            "containerVersion" to m.optString("containerVersion", "Ubuntu 24.04.5 · Node 24.22.3"),
            "executorMode" to effectiveExec,
            "configuredExecutorMode" to configuredExec,
            "sdcardMounted" to m.optBoolean("sdcardMounted", false),
            "useSystemProxy" to m.optBoolean("useSystemProxy", false),
            "installedToolkits" to detectInstalledToolkits(),
            "hasTawcroot" to File(libs, "libtawcroot.so").exists(),
            "hasProot" to File(libs, "libproot.so").exists(),
            "hasBundledAssets" to bundled.hasBundledAssets(),
            "homePath" to homeDir.absolutePath,
            "homeSizeKb" to cachedHomeSizeKb,
            "bridgeSocketPath" to bridgeSocket.absolutePath,
            "bridgeHttpUrl" to "http://127.0.0.1:$LOCAL_DSH_PORT",
            "dshWebUrl" to (dshWebUrl ?: "http://127.0.0.1:$LOCAL_DSH_PORT"),
            "bridgeToken" to bridgeToken,
            "phoneSocketPath" to phoneSocket.absolutePath,
            "droidSocketPath" to droidSocket.absolutePath,
            "udsReady" to (running && bridgeSocket.exists()),
            "bridgeReady" to running,
            "deviceAbi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a"),
            "sdkInt" to Build.VERSION.SDK_INT
        )
    }

    fun getEngineLogs(): List<String> = synchronized(engineLogs) { engineLogs.toList() }

    private fun appendLog(line: String) {
        val redacted = TOKEN_QUERY_REGEX.replace(line, "$1[REDACTED]")
        Log.i(TAG, redacted)
        synchronized(engineLogs) {
            engineLogs.add(redacted)
            while (engineLogs.size > 240) engineLogs.removeFirst()
        }
        var shouldSchedule = false
        synchronized(logBatchLock) {
            pendingLogBatch.add(redacted)
            if (!logBatchScheduled) {
                logBatchScheduled = true
                shouldSchedule = true
            }
        }
        if (shouldSchedule) {
            runCatching {
                coalesceScheduler.schedule({ flushEngineLogsBatch() }, 200, TimeUnit.MILLISECONDS)
            }
        }
    }

    private fun flushEngineLogsBatch() {
        val batch: List<String> = synchronized(logBatchLock) {
            logBatchScheduled = false
            if (pendingLogBatch.isEmpty()) return
            val copy = ArrayList<String>(pendingLogBatch)
            pendingLogBatch.clear()
            copy
        }
        emit("engine_log", mapOf("lines" to batch, "line" to batch.last()))
    }

    private fun enqueueLocalTermData(tabId: String, chunk: String) {
        var immediatePayload: String? = null
        var shouldSchedule = false
        synchronized(termPendingLock) {
            val sb = termPendingBuffers.getOrPut(tabId) { StringBuilder(chunk.length.coerceAtLeast(256)) }
            sb.append(chunk)
            if (sb.length >= 64 * 1024) {
                immediatePayload = sb.toString()
                sb.setLength(0)
                termPendingBuffers.remove(tabId)
            } else if (!termFlushScheduled) {
                termFlushScheduled = true
                shouldSchedule = true
            }
        }
        immediatePayload?.let { data ->
            emit("local_term_data", mapOf("tabId" to tabId, "data" to data))
        }
        if (shouldSchedule) {
            runCatching {
                coalesceScheduler.schedule({ flushAllLocalTermData() }, 16, TimeUnit.MILLISECONDS)
            }
        }
    }

    private fun flushLocalTermDataFor(tabId: String) {
        val data: String? = synchronized(termPendingLock) {
            termPendingBuffers.remove(tabId)?.takeIf { it.isNotEmpty() }?.toString()
        }
        if (data != null) {
            emit("local_term_data", mapOf("tabId" to tabId, "data" to data))
        }
    }

    private fun flushAllLocalTermData() {
        val snapshot: List<Pair<String, String>> = synchronized(termPendingLock) {
            termFlushScheduled = false
            if (termPendingBuffers.isEmpty()) return
            val out = ArrayList<Pair<String, String>>(termPendingBuffers.size)
            for ((tid, sb) in termPendingBuffers) {
                if (sb.isNotEmpty()) out.add(tid to sb.toString())
            }
            termPendingBuffers.clear()
            out
        }
        for ((tid, data) in snapshot) {
            emit("local_term_data", mapOf("tabId" to tid, "data" to data))
        }
    }

    fun bootstrapRuntime(done: (Map<String, Any?>) -> Unit) {
        worker.execute {
            val extractedOk: Boolean
            var bootstrapErr: String? = null
            synchronized(bootstrapLock) {
                var startedFgForBootstrap = false
                extractedOk = try {
                    sendProgress("layout", 4, "检查设备架构与存储空间，准备物理四分离持久卷…")
                    if (!Build.SUPPORTED_ABIS.any { it.equals("arm64-v8a", ignoreCase = true) }) {
                        error("当前设备架构 (${Build.SUPPORTED_ABIS.joinToString(",")}) 不支持 ARM64 本机容器，请使用远程设备模式连接桌面端 DSH")
                    }
                    prepareLayout()

                    val manifest = bundled.loadManifest()
                        ?: error("APK 内未找到 runtime/runtime-manifest.json")
                    val arts = manifest.optJSONObject("artifacts")
                        ?: error("runtime-manifest.json 缺少 artifacts 字段")
                    val st = readMeta()
                    val activeSlot = st.optString("activeSlot", "slot-a")
                    val targetSlotDir = if (activeSlot == "slot-b") slotB else slotA

                    val manifestDshVer = manifest.optString("dshVersion", "0.2.2-rc.5")
                    val baseArt = arts.optJSONObject("baseRootfs")
                    val engineArt = arts.optJSONObject("engineInit")
                    val needRootfsCheck = baseArt != null && (
                        !isContainerExtracted() ||
                            (baseArt.optString("sha256", "").isNotEmpty() &&
                                baseArt.optString("sha256", "") != st.optString("baseRootfsSha256", ""))
                        )
                    val needEngineCheck = engineArt != null && (
                        !isSlotExtracted(activeSlot) ||
                            (manifestDshVer.isNotEmpty() &&
                                st.optString("bundledDshVersion", "").isNotEmpty() &&
                                manifestDshVer != st.optString("bundledDshVersion", "") &&
                                !st.optBoolean("userUpgradedAb", false))
                        )
                    if (needRootfsCheck || needEngineCheck) {
                        val availBytes = runCatching { StatFs(ctx.filesDir.absolutePath).availableBytes }.getOrDefault(Long.MAX_VALUE)
                        // Account for reclaimable space when replacing an already-extracted rootfs or slot in-place.
                        val rootfsMarginMb = if (needRootfsCheck) {
                            if (ubuntuRoot.exists() && isContainerExtracted()) 150L else 350L
                        } else 0L
                        val engineMarginMb = if (needEngineCheck) {
                            if (targetSlotDir.exists() && isSlotExtracted(activeSlot)) 220L else 750L
                        } else 0L
                        val requiredBytes = (rootfsMarginMb + engineMarginMb) * 1024L * 1024L
                        if (availBytes < requiredBytes) {
                            val availMb = availBytes / (1024L * 1024L)
                            val reqMb = requiredBytes / (1024L * 1024L)
                            error("手机可用存储空间不足（当前仅剩 ${availMb} MB，至少需要 ${reqMb} MB 用于部署 Ubuntu + DSH 运行环境）")
                        }
                    }

                    // Start foreground service + bounded WakeLock ONLY after preflight checks pass so early
                    // errors never race startForegroundService() vs stop() on Android 10-16!
                    GrassBagEngineService.startOrUpdate(
                        ctx,
                        "正在初始化 GrassBag 本机容器",
                        "解压 Ubuntu + Node 24 + DSH 引擎，请保持应用运行…",
                        wakeLockMs = 10 * 60 * 1000L
                    )
                    startedFgForBootstrap = true

                    // 1. Shims & droid-* wrappers (always refresh when APK shims SHA-256 changes)
                    arts.optJSONObject("shims")?.let { art ->
                        val wantSha = art.optString("sha256", "")
                        val prevSha = st.optString("shimsSha256", "")
                        val needShims = !File(shimsRoot, "android-shim.mjs").exists() ||
                            !File(shimsRoot, "pty-bridge.mjs").exists() ||
                            (wantSha.isNotEmpty() && wantSha != prevSha)
                        if (needShims) {
                            sendProgress("shims", 10, "部署 android-shim、CA 证书与 droid-* 工具链…")
                            TarGzExtractor.deleteTreeNoFollow(shimsRoot)
                            shimsRoot.mkdirs()
                            bundled.openStream(art.optString("asset"))?.use { ins ->
                                TarGzExtractor.extractStream(
                                    compressedStream = ins,
                                    destDir = shimsRoot,
                                    expectedSha256 = wantSha,
                                    totalCompressedBytes = art.optLong("bytes", 0L),
                                    freshDir = true
                                )
                            } ?: error("无法读取 ${art.optString("asset")}")
                            if (wantSha.isNotEmpty()) st.put("shimsSha256", wantSha)
                        } else {
                            sendProgress("shims", 10, "android-shim 与 droid-* 工具链已是最新")
                        }
                    }

                    // 2 & 3. Extract Ubuntu 24.04.5 + Node 24 rootfs and @deepseek-ai/dsh engine slot.
                    // When both need extraction (fresh install), run them in parallel across 2 CPU cores
                    // while preserving the foreground service & WakeLock (keepForegroundService = true)!
                    if (needRootfsCheck || needEngineCheck) {
                        stopEngineSync(keepForegroundService = true)
                    }

                    if (needRootfsCheck && needEngineCheck && baseArt != null && engineArt != null) {
                        val rootfsTotal = baseArt.optLong("bytes", 75_000_000L).coerceAtLeast(1L)
                        val engineTotal = engineArt.optLong("bytes", 112_000_000L).coerceAtLeast(1L)
                        val combinedTotal = rootfsTotal + engineTotal
                        val rootfsRead = AtomicLong(0L)
                        val engineRead = AtomicLong(0L)
                        val lastEmitMs = AtomicLong(0L)

                        fun reportParallelProgress() {
                            val now = System.currentTimeMillis()
                            val prev = lastEmitMs.get()
                            if (now - prev < 180L || !lastEmitMs.compareAndSet(prev, now)) return
                            val doneBytes = rootfsRead.get() + engineRead.get()
                            val pct = 14 + ((doneBytes * 70L) / combinedTotal).toInt().coerceIn(0, 70)
                            sendProgress(
                                "rootfs",
                                pct,
                                "并行解压 Ubuntu + Node 24 与 DSH $manifestDshVer (${doneBytes / (1024 * 1024)} / ${combinedTotal / (1024 * 1024)} MB)…"
                            )
                        }

                        sendProgress("rootfs", 14, "正在并行部署 Ubuntu + Node 24 与 DSH $manifestDshVer…")
                        val fRootfs = worker.submit<Unit> {
                            TarGzExtractor.deleteTreeNoFollow(ubuntuRoot)
                            ubuntuRoot.mkdirs()
                            val extractingFlag = File(ubuntuRoot, ".extracting").apply { writeText("1") }
                            val wantSha = baseArt.optString("sha256", "")
                            bundled.openStream(baseArt.optString("asset"))?.use { ins ->
                                TarGzExtractor.extractStream(
                                    compressedStream = ins,
                                    destDir = ubuntuRoot,
                                    expectedSha256 = wantSha,
                                    totalCompressedBytes = rootfsTotal,
                                    freshDir = true
                                ) { read, _ ->
                                    rootfsRead.set(read)
                                    reportParallelProgress()
                                }
                            } ?: error("无法读取 ${baseArt.optString("asset")}")
                            extractingFlag.delete()
                            File(ubuntuRoot, ".extract-complete").writeText(wantSha.ifBlank { "ok" })
                        }
                        val fEngine = worker.submit<Unit> {
                            TarGzExtractor.deleteTreeNoFollow(targetSlotDir)
                            targetSlotDir.mkdirs()
                            val extractingFlag = File(targetSlotDir, ".extracting").apply { writeText("1") }
                            val wantSha = engineArt.optString("sha256", "")
                            bundled.openStream(engineArt.optString("asset"))?.use { ins ->
                                TarGzExtractor.extractStream(
                                    compressedStream = ins,
                                    destDir = targetSlotDir,
                                    expectedSha256 = wantSha,
                                    totalCompressedBytes = engineTotal,
                                    freshDir = true
                                ) { read, _ ->
                                    engineRead.set(read)
                                    reportParallelProgress()
                                }
                            } ?: error("无法读取 ${engineArt.optString("asset")}")
                            extractingFlag.delete()
                            File(targetSlotDir, ".extract-complete").writeText(wantSha.ifBlank { "ok" })
                        }
                        // Wait for both and propagate any extraction exception cleanly.
                        var firstErr: Throwable? = null
                        runCatching { fRootfs.get() }.onFailure { firstErr = it.cause ?: it }
                        runCatching { fEngine.get() }.onFailure { if (firstErr == null) firstErr = it.cause ?: it }
                        firstErr?.let { throw it }

                        etcPrepared = false
                        ptySupportedCache = null
                        val baseSha = baseArt.optString("sha256", "")
                        val engSha = engineArt.optString("sha256", "")
                        if (baseSha.isNotEmpty()) st.put("baseRootfsSha256", baseSha)
                        if (engSha.isNotEmpty()) st.put("engineInitSha256", engSha)
                        st.put("bundledDshVersion", manifestDshVer)
                        st.put("dshVersion", manifestDshVer)
                    } else {
                        baseArt?.let { art ->
                            val wantSha = art.optString("sha256", "")
                            if (needRootfsCheck) {
                                val total = art.optLong("bytes", 75_000_000L)
                                sendProgress("rootfs", 14, "清理旧容器并解压 Ubuntu 24.04.5 + Node 24.22.3 ARM64…")
                                TarGzExtractor.deleteTreeNoFollow(ubuntuRoot)
                                ubuntuRoot.mkdirs()
                                val extractingFlag = File(ubuntuRoot, ".extracting").apply { writeText("1") }
                                bundled.openStream(art.optString("asset"))?.use { ins ->
                                    TarGzExtractor.extractStream(
                                        compressedStream = ins,
                                        destDir = ubuntuRoot,
                                        expectedSha256 = wantSha,
                                        totalCompressedBytes = total,
                                        freshDir = true
                                    ) { read, tot ->
                                        val pct = if (tot > 0) 14 + ((read * 36) / tot).toInt().coerceIn(0, 36) else 32
                                        sendProgress("rootfs", pct, "正在解压 Ubuntu + Node 24 (${read / (1024 * 1024)} / ${tot / (1024 * 1024)} MB)…")
                                    }
                                } ?: error("无法读取 ${art.optString("asset")}")
                                extractingFlag.delete()
                                File(ubuntuRoot, ".extract-complete").writeText(wantSha.ifBlank { "ok" })
                                etcPrepared = false
                                ptySupportedCache = null
                            } else {
                                sendProgress("rootfs", 50, "Ubuntu 24.04.5 + Node 24 容器已存在，跳过解压")
                            }
                            if (wantSha.isNotEmpty()) st.put("baseRootfsSha256", wantSha)
                        }

                        engineArt?.let { art ->
                            val wantSha = art.optString("sha256", "")
                            if (needEngineCheck) {
                                val total = art.optLong("bytes", 112_000_000L)
                                sendProgress("engine", 52, "清理旧槽位并部署真实 DSH $manifestDshVer…")
                                TarGzExtractor.deleteTreeNoFollow(targetSlotDir)
                                targetSlotDir.mkdirs()
                                val extractingFlag = File(targetSlotDir, ".extracting").apply { writeText("1") }
                                bundled.openStream(art.optString("asset"))?.use { ins ->
                                    TarGzExtractor.extractStream(
                                        compressedStream = ins,
                                        destDir = targetSlotDir,
                                        expectedSha256 = wantSha,
                                        totalCompressedBytes = total,
                                        freshDir = true
                                    ) { read, tot ->
                                        val pct = if (tot > 0) 52 + ((read * 32) / tot).toInt().coerceIn(0, 32) else 72
                                        sendProgress("engine", pct, "正在部署 DSH 引擎 (${read / (1024 * 1024)} / ${tot / (1024 * 1024)} MB)…")
                                    }
                                } ?: error("无法读取 ${art.optString("asset")}")
                                extractingFlag.delete()
                                File(targetSlotDir, ".extract-complete").writeText(wantSha.ifBlank { "ok" })
                                if (wantSha.isNotEmpty()) st.put("engineInitSha256", wantSha)
                                st.put("bundledDshVersion", manifestDshVer)
                                st.put("dshVersion", manifestDshVer)
                            } else {
                                sendProgress("engine", 84, "DSH 引擎槽位 $activeSlot 核心已就绪")
                                if (st.optString("bundledDshVersion", "").isEmpty()) {
                                    st.put("bundledDshVersion", manifestDshVer)
                                }
                            }
                        }
                    }

                    updateRelativeSymlink(File(containersRoot, "current"), ubuntuRoot.name)
                    ensureContainerEtcFiles(force = true)

                    // 3b. Fast ~60KB incremental dsh-gbridge overlay (never forces 121MB re-extraction!)
                    arts.optJSONObject("gbridge")?.let { art ->
                        val wantSha = art.optString("sha256", "")
                        val prevSha = st.optString("gbridgeSha256_$activeSlot", st.optString("gbridgeSha256", ""))
                        val bridgeDir = File(targetSlotDir, "dsh-gbridge")
                        val needBridge = !File(bridgeDir, "lib/index.js").exists() ||
                            (wantSha.isNotEmpty() && wantSha != prevSha)
                        if (needBridge) {
                            sendProgress("gbridge", 86, "增量更新零侵入桥 dsh-gbridge…")
                            TarGzExtractor.deleteTreeNoFollow(bridgeDir)
                            bridgeDir.mkdirs()
                            bundled.openStream(art.optString("asset"))?.use { ins ->
                                TarGzExtractor.extractStream(ins, bridgeDir, wantSha, art.optLong("bytes", 0L), freshDir = true)
                            } ?: error("无法读取 ${art.optString("asset")}")
                            if (wantSha.isNotEmpty()) {
                                st.put("gbridgeSha256", wantSha)
                                st.put("gbridgeSha256_$activeSlot", wantSha)
                            }
                        }
                    }

                    updateRelativeSymlink(File(slotsRoot, "current"), activeSlot)
                    updateRelativeSymlink(File(slotsRoot, "lkg"), st.optString("lkgSlot", activeSlot))

                    writeAndroidCordisPatch(File(targetSlotDir, "dsh-gbridge/cordis.patch.yml"))

                    sendProgress("daemons", 88, "启动 0600 UDS 安全守护进程与本机 DSH 引擎…")
                    phoneDaemon.start()
                    droidDaemon.start()

                    st.put("initialized", true)
                    st.put("activeSlot", activeSlot)
                    st.put("lkgSlot", st.optString("lkgSlot", activeSlot))
                    st.put("containerVersion", manifest.optString("containerVersion", "Ubuntu 24.04.5 · Node 24.22.3"))
                    if (st.optString("dshVersion", "").isEmpty()) {
                        st.put("dshVersion", manifestDshVer)
                    }
                    st.put("bridgeVersion", manifest.optString("bridgeVersion", "0.1.0"))
                    if (!st.optBoolean("executorModePinned", false)) {
                        st.put("executorMode", detectExecutor())
                    }
                    writeMeta(st)
                    true
                } catch (err: Throwable) {
                    Log.e(TAG, "bootstrapRuntime failed", err)
                    bootstrapErr = err.message ?: "bootstrap_failed"
                    lastEngineError = bootstrapErr
                    if (startedFgForBootstrap) {
                        GrassBagEngineService.stop(ctx)
                    }
                    // Always reset progress percentage so UI Start/Retry controls are never locked out!
                    sendProgress("error", 0, "本机容器初始化失败：${bootstrapErr}")
                    false
                }
            }

            if (!extractedOk) {
                done(mapOf("ok" to false, "error" to (bootstrapErr ?: "bootstrap_failed"), "status" to getStatus()))
                return@execute
            }

            // Release bootstrapLock BEFORE starting DSH engine so status/start calls never stall!
            sendProgress("engine_boot", 92, "正在高速拉起本机 DSH 引擎（首次编译缓存约需 6-15 秒）…")
            val engineRes = startEngineSync()
            val ok = engineRes["ok"] == true
            if (ok) {
                val bootMs = (engineRes["bootMs"] as? Number)?.toLong() ?: 0L
                val execTag = engineRes["executorMode"]?.toString() ?: "tawcroot"
                val sec = if (bootMs > 0) String.format("%.1fs", bootMs / 1000.0) else ""
                sendProgress("ready", 100, "本机 Ubuntu + Node 24 + DSH 引擎已就绪 ($execTag${if (sec.isNotEmpty()) " · $sec" else ""})")
                done(mapOf("ok" to true, "engineStarted" to true, "bootMs" to bootMs, "status" to getStatus()))
            } else {
                val errStr = engineRes["error"]?.toString() ?: "engine_start_failed"
                sendProgress("error", 0, "容器已部署，但 DSH 启动失败：$errStr")
                done(mapOf("ok" to false, "engineStarted" to false, "error" to errStr, "status" to getStatus()))
            }
        }
    }

    fun startEngine(done: (Map<String, Any?>) -> Unit) {
        worker.execute {
            val res = startEngineSync()
            done(res)
        }
    }

    fun restartEngine(done: (Map<String, Any?>) -> Unit) {
        worker.execute {
            stopEngineSync()
            val res = startEngineSync()
            done(res)
        }
    }

    fun stopEngine(): Map<String, Any?> {
        stopEngineSync()
        return mapOf("ok" to true, "status" to getStatus())
    }

    private fun killProcessGroupSafe(pid: Int) {
        if (!isValidEnginePid(pid)) return
        val myPgid = readProcStat(android.os.Process.myPid())?.second ?: -1
        val targetPgid = readProcStat(pid)?.second ?: -1
        val canKillGroup = targetPgid > 1 && targetPgid != myPgid
        if (canKillGroup) {
            runCatching { Os.kill(-targetPgid, 15) } // SIGTERM whole container session/process group
        }
        runCatching { Os.kill(pid, 15) }
        runCatching { Thread.sleep(150) }
        if (canKillGroup) {
            runCatching { Os.kill(-targetPgid, 9) } // SIGKILL remaining children (bash/MCP/dev servers)
        }
        runCatching { Os.kill(pid, 9) }
    }

    private fun killRecordedEnginePid() {
        runCatching {
            if (pidFile.exists()) {
                val pid = pidFile.readText().trim().toIntOrNull()
                if (pid != null && pid > 1) {
                    killProcessGroupSafe(pid)
                }
                pidFile.delete()
            }
        }
    }

    private fun stopEngineSync(keepForegroundService: Boolean = false, emitStoppedEvent: Boolean = true) {
        synchronized(engineLock) {
            dshProcess?.let { proc ->
                appendLog("[runtime] stopping DSH engine...")
                // Terminate child process group first (via recorded PID from setsid session) so no orphan
                // bash / MCP / dev server child survives DSH stop/restart.
                killRecordedEnginePid()
                runCatching { proc.destroy() }
                runCatching {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        proc.waitFor(1500, TimeUnit.MILLISECONDS)
                    }
                }
                runCatching { proc.destroyForcibly() }
            }
            killRecordedEnginePid()
            dshProcess = null
            adoptedRunning = false
            dshWebUrl = null
            activeExecutorUsed = null
            engineState = "stopped"
            SafetyGate.endTurn()
            runCatching { if (bridgeSocket.exists()) bridgeSocket.delete() }
            if (!keepForegroundService) {
                GrassBagEngineService.stop(ctx)
            }
            if (emitStoppedEvent) {
                emit("engine_state", mapOf("state" to "stopped"))
            }
        }
    }

    private fun resolveHostDirForContainerWorkdir(workDirInsideContainer: String): File {
        val clean = workDirInsideContainer.trim().trimEnd('/').ifEmpty { "/root/workspace" }
        val candidate = when {
            clean == "/root" -> homeDir
            clean.startsWith("/root/") -> File(homeDir, clean.removePrefix("/root/"))
            clean == "/opt/dsh-slots" -> slotsRoot
            clean.startsWith("/opt/dsh-slots/") -> File(slotsRoot, clean.removePrefix("/opt/dsh-slots/"))
            clean == "/sdcard" -> Environment.getExternalStorageDirectory()
            clean.startsWith("/sdcard/") -> File(Environment.getExternalStorageDirectory(), clean.removePrefix("/sdcard/"))
            clean == "/tmp" -> File(ubuntuRoot, "tmp")
            clean.startsWith("/") -> File(ubuntuRoot, clean.removePrefix("/"))
            else -> File(homeDir, "workspace")
        }
        return if (candidate.isDirectory) candidate else File(homeDir, "workspace").also { it.mkdirs() }
    }

    private fun canOpenDirForBind(path: String): Boolean {
        return runCatching {
            val fd = Os.open(path, OsConstants.O_RDONLY, 0)
            runCatching { Os.close(fd) }
            true
        }.getOrDefault(false)
    }

    private fun buildProotProcess(
        commandArgs: List<String>,
        workDirInsideContainer: String = "/root",
        includeBridgeSecrets: Boolean = false,
        forceProot: Boolean? = null,
        disableProotSeccomp: Boolean? = null
    ): Pair<ProcessBuilder, String> {
        val nativeLibDir = File(ctx.applicationInfo.nativeLibraryDir)
        val tawcBin = File(nativeLibDir, "libtawcroot.so")
        val prootBin = File(nativeLibDir, "libproot.so")
        val prootLoader = File(nativeLibDir, "libproot_loader.so")

        val meta = readMeta()
        val effectiveForceProot = forceProot ?: (activeExecutorUsed == "proot" || activeExecutorUsed == "proot-legacy")
        val effectiveDisableSeccomp = disableProotSeccomp ?: (activeExecutorUsed == "proot-legacy")
        val wantTawc = !effectiveForceProot && tawcBin.exists() && effectiveExecutorMode(meta) == "tawcroot"
        if (!wantTawc) {
            check(prootBin.exists()) { "libproot.so not found in ${nativeLibDir.absolutePath}" }
        }

        prootTmpDir.mkdirs()
        tawcTmpDir.mkdirs()
        File(homeDir, ".cache/node-compile-cache").mkdirs()
        ensureContainerEtcFiles(force = includeBridgeSecrets)

        // Never fall back to `homeDir` for `/root/shared` (that would bind `/root` recursively inside itself!).
        val extShared = ctx.getExternalFilesDir(null)
        val sharedDir = (if (extShared != null && extShared.canonicalPath != homeDir.canonicalPath) {
            extShared
        } else {
            File(ctx.filesDir, "volumes/shared")
        }).also { it.mkdirs() }
        val mountSdcard = meta.optBoolean("sdcardMounted", false) && canOpenDirForBind("/sdcard")

        val executorTag: String
        val pb: ProcessBuilder
        if (wantTawc) {
            executorTag = "tawcroot"
            // CRITICAL: Do NOT `-b` bind `/tmp`! In tawcroot (`path_orchestrate.c`), paths matched
            // by a bind bypass the rootfs symlink resolver & linkstore, causing apt's staged symlinks
            // (`/tmp/apt-dpkg-install-*/0-*.deb -> /var/cache/apt/archives/*.deb`) and python/pip/gcc
            // guest symlinks in `/tmp` to fail with ENOENT! Use the native rootfs `ubuntuRoot/tmp`.
            val args = mutableListOf(
                tawcBin.absolutePath,
                "-s", // Create an isolated POSIX session/PGID so stop/restart cleanly reaps all child trees
                "-r", ubuntuRoot.absolutePath,
                "-b", "/dev:/dev",
                "-b", "/proc:/proc",
                "-b", "${homeDir.absolutePath}:/root",
                "-b", "${sharedDir.absolutePath}:/root/shared",
                "-b", "${slotsRoot.absolutePath}:/opt/dsh-slots",
                "-b", "${shimsRoot.absolutePath}:/opt/shims",
                "-b", "${runRoot.absolutePath}:/run/grassbag"
            )
            // Only bind /dev/pts separately if SELinux permits opening /dev/pts directly (otherwise /dev handles it).
            if (canOpenDirForBind("/dev/pts")) {
                args.addAll(listOf("-b", "/dev/pts:/dev/pts"))
            }
            if (mountSdcard) {
                args.addAll(listOf("-b", "/sdcard:/sdcard"))
            }
            args.add("--")
            args.addAll(commandArgs)
            pb = ProcessBuilder(args)
                .directory(resolveHostDirForContainerWorkdir(workDirInsideContainer))
                .redirectErrorStream(true)
        } else {
            executorTag = if (effectiveDisableSeccomp) "proot-legacy" else "proot"
            // Keep `/tmp` inside `ubuntuRoot/tmp` for uniform rootfs semantics; `PROOT_TMP_DIR`
            // env var still points to host `prootTmpDir` for PRoot's internal loader stubs.
            val args = mutableListOf(
                prootBin.absolutePath,
                "-0",
                "--link2symlink",
                "-r", ubuntuRoot.absolutePath,
                "-b", "/dev",
                "-b", "/proc",
                "-b", "${homeDir.absolutePath}:/root",
                "-b", "${sharedDir.absolutePath}:/root/shared",
                "-b", "${slotsRoot.absolutePath}:/opt/dsh-slots",
                "-b", "${shimsRoot.absolutePath}:/opt/shims",
                "-b", "${runRoot.absolutePath}:/run/grassbag",
                "-w", workDirInsideContainer
            )
            if (File("/dev/pts").exists()) {
                args.addAll(listOf("-b", "/dev/pts"))
            }
            if (mountSdcard) {
                args.addAll(listOf("-b", "/sdcard:/sdcard"))
            }
            // Strip Android Bionic LD_LIBRARY_PATH inside PRoot guest so Ubuntu glibc binaries never load host .so files!
            if (File(ubuntuRoot, "usr/bin/env").exists()) {
                args.addAll(listOf("/usr/bin/env", "-u", "LD_LIBRARY_PATH"))
            }
            args.addAll(commandArgs)
            pb = ProcessBuilder(args).redirectErrorStream(true)
        }

        val dnsServers = resolveSystemDnsServers().joinToString(",")
        val containerShell = if (File(ubuntuRoot, "bin/bash").exists()) "/bin/bash" else "/bin/sh"
        val caCertExists = File(ubuntuRoot, "etc/ssl/certs/ca-certificates.crt").exists()
        val proxyUrl = if (meta.optBoolean("useSystemProxy", false)) resolveSystemProxyUrl() else null
        pb.environment().apply {
            clear()
            if (!wantTawc) {
                put("LD_LIBRARY_PATH", nativeLibDir.absolutePath)
                if (prootLoader.exists()) put("PROOT_LOADER", prootLoader.absolutePath)
                put("PROOT_TMP_DIR", prootTmpDir.absolutePath)
                if (effectiveDisableSeccomp) {
                    put("PROOT_NO_SECCOMP", "1")
                }
            }
            put("HOME", "/root")
            put("USER", "root")
            put("LOGNAME", "root")
            put("SHELL", containerShell)
            put("TZ", TimeZone.getDefault().id)
            put("TERM", "xterm-256color")
            put("LANG", "C.UTF-8")
            put("TMPDIR", "/tmp")
            put("DEBIAN_FRONTEND", "noninteractive")
            put("UCF_FORCE_CONFFOLD", "1")
            put("NEEDRESTART_SUSPEND", "1")
            put("PIP_BREAK_SYSTEM_PACKAGES", "1")
            put("PS1", "\\u@grassbag:\\w\\$ ")
            put("PATH", "/usr/local/bin:/opt/shims/droid-bin:/root/.local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            put("DSH_HOME", "/root/.dsh")
            put("DSH_VERSION", meta.optString("dshVersion", "0.2.2-rc.5"))
            put("DSH_TELEMETRY_DISABLED", "1")
            put("GBRIDGE_DNS_SERVERS", dnsServers)
            put("GBRIDGE_LOCAL_ANDROID", "1")
            put("GBRIDGE_DEFAULT_WORKSPACE", "/root/workspace")
            if (caCertExists) {
                put("SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt")
                put("CURL_CA_BUNDLE", "/etc/ssl/certs/ca-certificates.crt")
                put("REQUESTS_CA_BUNDLE", "/etc/ssl/certs/ca-certificates.crt")
                put("GIT_SSL_CAINFO", "/etc/ssl/certs/ca-certificates.crt")
            }
            if (proxyUrl != null) {
                put("HTTP_PROXY", proxyUrl)
                put("HTTPS_PROXY", proxyUrl)
                put("http_proxy", proxyUrl)
                put("https_proxy", proxyUrl)
                put("NO_PROXY", "127.0.0.1,localhost,::1")
                put("no_proxy", "127.0.0.1,localhost,::1")
            }
            if (includeBridgeSecrets) {
                // Scope shim + V8 compile cache strictly to the DSH engine process (not shells/npm/droid scripts).
                put("GBRIDGE_DSH_BOOT", "1")
                put("NODE_COMPILE_CACHE", "/root/.cache/node-compile-cache")
                put("GBRIDGE_UNIX_SOCKET", "/run/grassbag/bridge.sock")
                put("GBRIDGE_TOKEN", bridgeToken)
                put("GBRIDGE_PHONE_SOCKET", "/run/grassbag/phone-control.sock")
                put("GBRIDGE_PHONE_TOKEN", phoneDaemon.bearerToken)
                put("GBRIDGE_PID_FILE", "/run/grassbag/dsh-engine.pid")
            }
            put("DROID_BRIDGE_SOCKET", "/run/grassbag/droid.sock")
            put("DROID_BRIDGE_TOKEN", droidDaemon.bearerToken)
        }
        return pb to executorTag
    }

    private fun startEngineSync(): Map<String, Any?> {
        // Coalesce concurrent startup attempts atomically (MainActivity prewarm + Flutter refreshNativeStatus).
        val waitLatch: CountDownLatch? = synchronized(engineLock) {
            if (isEngineAlive() && engineState == "running") {
                return mapOf("ok" to true, "alreadyRunning" to true, "status" to getStatus())
            }
            val existingLatch = activeStartupLatch
            if (existingLatch != null) {
                existingLatch
            } else {
                activeStartupLatch = CountDownLatch(1)
                engineState = "starting"
                lastEngineError = null
                null
            }
        }
        if (waitLatch != null) {
            runCatching { waitLatch.await(180, TimeUnit.SECONDS) }
            val ok = isEngineAlive() && engineState == "running"
            return mapOf(
                "ok" to ok,
                "alreadyRunning" to ok,
                "error" to (if (ok) null else lastEngineError),
                "status" to getStatus()
            )
        }

        try {
            val st = readMeta()
            val activeSlot = st.optString("activeSlot", "slot-a")
            if (!isContainerExtracted() || !isSlotExtracted(activeSlot)) {
                synchronized(engineLock) {
                    if (engineState == "starting") engineState = "stopped"
                }
                return mapOf("ok" to false, "error" to "runtime_not_initialized", "status" to getStatus())
            }

            // Adopt an already-healthy local DSH instance on our dedicated port ONLY when bundled overlays
            // haven't changed (if the APK just upgraded dsh-gbridge/shims, restart cleanly so fixes take effect).
            val existingCaps = probeLocalCapabilities()
            if (existingCaps != null) {
                if (hasPendingFastOverlayUpdate(activeSlot)) {
                    appendLog("[runtime] APK overlays updated; restarting previously running DSH to apply updates...")
                    stopEngineSync(keepForegroundService = true, emitStoppedEvent = false)
                } else {
                    synchronized(engineLock) {
                        adoptedRunning = true
                        lastCapabilitiesDshVersion = existingCaps.optString("dshVersion", "0.2.2-rc.5")
                        engineState = "running"
                        lastEngineError = null
                    }
                    GrassBagEngineService.startOrUpdate(
                        ctx,
                        "GrassBag 本机引擎运行中",
                        "DSH $lastCapabilitiesDshVersion · 后台保活中"
                    )
                    appendLog("[runtime] adopted existing healthy DSH on :$LOCAL_DSH_PORT (version=$lastCapabilitiesDshVersion)")
                    emit(
                        "engine_ready",
                        mapOf(
                            "bridgeSocketPath" to bridgeSocket.absolutePath,
                            "bridgeHttpUrl" to "http://127.0.0.1:$LOCAL_DSH_PORT",
                            "dshWebUrl" to (dshWebUrl ?: "http://127.0.0.1:$LOCAL_DSH_PORT"),
                            "bridgeToken" to bridgeToken,
                            "dshVersion" to lastCapabilitiesDshVersion,
                            "endpointsCount" to existingCaps.optInt("endpointsCount", 0),
                            "udsReady" to bridgeSocket.exists()
                        )
                    )
                    return mapOf("ok" to true, "alreadyRunning" to true, "status" to getStatus())
                }
            }

            // Fast ~20ms atomic sync if APK shipped updated shims or dsh-gbridge.
            runCatching { syncFastOverlaysIfNeeded(activeSlot) }

            val nativeLibDir = File(ctx.applicationInfo.nativeLibraryDir)
            val hasTawc = File(nativeLibDir, "libtawcroot.so").exists()
            val hasProot = File(nativeLibDir, "libproot.so").exists()
            if (!hasTawc && !hasProot) {
                engineState = "error"
                lastEngineError = "neither libtawcroot.so nor libproot.so found in ${nativeLibDir.absolutePath}"
                return mapOf("ok" to false, "error" to lastEngineError, "status" to getStatus())
            }

            updateRelativeSymlink(File(containersRoot, "current"), ubuntuRoot.name)
            updateRelativeSymlink(File(slotsRoot, "current"), activeSlot)
            ensureContainerEtcFiles(force = true)

            // Try fast path first (`tawcroot`), automatically falling back to `proot` (seccomp) -> `proot-legacy` if needed.
            val freshMeta = readMeta()
            val wantTawcFirst = hasTawc && effectiveExecutorMode(freshMeta) == "tawcroot"
            val attempts = mutableListOf<Pair<Boolean, Boolean>>() // (forceProot, disableProotSeccomp)
            if (wantTawcFirst) {
                attempts.add(false to false)
            }
            if (hasProot) {
                attempts.add(true to false)
                attempts.add(true to true)
            }

            var lastAttemptErr: String? = null
            for ((idx, attempt) in attempts.withIndex()) {
                val (forceProot, disableSeccomp) = attempt
                val res = launchAndWaitForEngine(activeSlot, forceProot, disableSeccomp)
                if (res["ok"] == true) {
                    return res
                }
                lastAttemptErr = res["error"]?.toString()
                // Only blacklist tawcroot on true kernel/seccomp incompatibility codes (86/88/89/92/94/95/159=SIGSYS),
                // never on transient rootfs/bind errors (90/93)!
                if (!forceProot && lastAttemptErr != null && Regex("""code (86|88|89|92|94|95|159)\b""").containsMatchIn(lastAttemptErr)) {
                    runCatching {
                        val updated = readMeta().put("tawcUnsupportedFingerprint", Build.FINGERPRINT)
                        writeMeta(updated)
                    }
                }
                // Clean up failed/timed-out attempt; keep FGS & suppress stopped flicker while falling back!
                val hasMoreAttempts = idx + 1 < attempts.size
                stopEngineSync(keepForegroundService = hasMoreAttempts, emitStoppedEvent = !hasMoreAttempts)
                if (hasMoreAttempts) {
                    appendLog("[runtime] startup attempt #${idx + 1} failed ($lastAttemptErr); retrying with fallback executor...")
                }
            }

            engineState = "error"
            lastEngineError = lastAttemptErr ?: "DSH startup failed"
            emit("engine_state", mapOf("state" to "error", "error" to lastEngineError))
            return mapOf("ok" to false, "error" to lastEngineError, "status" to getStatus())
        } finally {
            synchronized(engineLock) {
                if (engineState == "starting") {
                    engineState = if (lastEngineError != null) "error" else "stopped"
                }
                activeStartupLatch?.countDown()
                activeStartupLatch = null
            }
        }
    }

    private fun launchAndWaitForEngine(
        activeSlot: String,
        forceProot: Boolean,
        disableProotSeccomp: Boolean
    ): Map<String, Any?> {
        val t0 = System.currentTimeMillis()
        val proc: Process
        val executorTag: String
        synchronized(engineLock) {
            runCatching { if (bridgeSocket.exists()) bridgeSocket.delete() }
            runCatching { if (pidFile.exists()) pidFile.delete() }
            engineState = "starting"
            adoptedRunning = false
            dshWebUrl = null
            lastEngineError = null
            emit("engine_state", mapOf("state" to "starting"))

            val (pb, tag) = buildProotProcess(
                listOf(
                    "/usr/local/bin/node",
                    "--import=/opt/shims/android-shim.mjs",
                    "/opt/dsh-slots/current/node_modules/@deepseek-ai/dsh/lib/bin.js",
                    "web",
                    "--patch", "/opt/dsh-slots/current/dsh-gbridge/cordis.patch.yml",
                    "--",
                    "--no-open",
                    "--host", "127.0.0.1",
                    "--port", "$LOCAL_DSH_PORT"
                ),
                "/root/workspace",
                includeBridgeSecrets = true,
                forceProot = forceProot,
                disableProotSeccomp = disableProotSeccomp
            )
            executorTag = tag
            activeExecutorUsed = tag
            appendLog("[runtime] starting REAL DSH engine via $tag (slot=$activeSlot port=$LOCAL_DSH_PORT)...")

            proc = try {
                spawnProcess(pb)
            } catch (e: Throwable) {
                engineState = "error"
                lastEngineError = "failed to spawn $tag: ${e.message}"
                appendLog("[runtime] ERROR: $lastEngineError")
                return mapOf("ok" to false, "error" to lastEngineError, "status" to getStatus())
            }
            dshProcess = proc

            worker.execute {
                runCatching {
                    BufferedReader(InputStreamReader(proc.inputStream, Charsets.UTF_8)).use { br ->
                        while (true) {
                            val line = br.readLine() ?: break
                            var wake = false
                            DSH_WEB_URL_REGEX.find(line)?.value?.let { foundUrl ->
                                dshWebUrl = foundUrl
                                emit("engine_web_url", mapOf("dshWebUrl" to foundUrl))
                                wake = true
                            }
                            if (line.contains("UDS listener ready") || line.contains("gbridge")) {
                                wake = true
                            }
                            appendLog("[dsh] $line")
                            if (wake) {
                                synchronized(readinessSignal) { readinessSignal.notifyAll() }
                            }
                        }
                    }
                }
                val code = runCatching { proc.waitFor() }.getOrDefault(-1)
                appendLog("[runtime] DSH process ($tag) exited with code $code")
                SafetyGate.endTurn()
                synchronized(readinessSignal) { readinessSignal.notifyAll() }
                synchronized(engineLock) {
                    if (dshProcess === proc) {
                        dshProcess = null
                        runCatching { if (bridgeSocket.exists()) bridgeSocket.delete() }
                        runCatching { if (pidFile.exists()) pidFile.delete() }
                        if (engineState != "stopped") {
                            engineState = "error"
                            lastEngineError = "DSH ($tag) exited with code $code"
                            GrassBagEngineService.stop(ctx)
                        }
                        emit("engine_state", mapOf("state" to engineState, "exitCode" to code, "error" to lastEngineError))
                    }
                }
            }
        }

        // Executor-aware startup budget: 60s for fast tawcroot, 120s for slower PRoot on older phones.
        val timeoutMs = if (forceProot) 120_000L else 60_000L
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (!isEngineAlive()) {
                runCatching { proc.waitFor(500, java.util.concurrent.TimeUnit.MILLISECONDS) }
                val exitCode = runCatching { proc.exitValue() }.getOrNull()
                val tail = getEngineLogs().takeLast(6).joinToString(" | ")
                lastEngineError = lastEngineError ?: (
                    if (exitCode != null) "DSH ($executorTag) exited with code $exitCode: $tail"
                    else "DSH ($executorTag) exited early: $tail"
                )
                return mapOf("ok" to false, "error" to lastEngineError, "status" to getStatus())
            }
            // Only probe HTTP once dshWebUrl appeared or 1.8s have elapsed
            val elapsed = System.currentTimeMillis() - t0
            if (dshWebUrl != null || bridgeSocket.exists() || elapsed >= 1800L) {
                val caps = probeLocalCapabilities()
                if (caps != null) {
                    // Wait briefly (up to 500ms) only for `bridge.sock` if not yet visible;
                    // `dshWebUrl` arrives asynchronously via `engine_web_url` without stalling boot!
                    for (i in 0 until 10) {
                        if (bridgeSocket.exists()) break
                        runCatching { Thread.sleep(50) }
                    }
                    if (bridgeSocket.exists()) {
                        runCatching { Os.chmod(bridgeSocket.absolutePath, 0x180) }
                    }
                    val stillValid = synchronized(engineLock) {
                        if (dshProcess === proc && engineState == "starting") {
                            lastCapabilitiesDshVersion = caps.optString("dshVersion", "0.2.2-rc.5")
                            engineState = "running"
                            lastEngineError = null
                            true
                        } else {
                            false
                        }
                    }
                    if (!stillValid) {
                        return mapOf("ok" to false, "error" to "engine_stopped_during_startup", "status" to getStatus())
                    }
                    val bootMs = System.currentTimeMillis() - t0
                    GrassBagEngineService.startOrUpdate(
                        ctx,
                        "GrassBag 本机引擎运行中",
                        "DSH $lastCapabilitiesDshVersion ($executorTag) · 后台保活中"
                    )
                    appendLog("[runtime] DSH READY in ${bootMs}ms! executor=$executorTag version=$lastCapabilitiesDshVersion endpoints=${caps.optInt("endpointsCount")} uds=${bridgeSocket.exists()} webUrl=${dshWebUrl != null} port=$LOCAL_DSH_PORT")
                    emit(
                        "engine_ready",
                        mapOf(
                            "bridgeSocketPath" to bridgeSocket.absolutePath,
                            "bridgeHttpUrl" to "http://127.0.0.1:$LOCAL_DSH_PORT",
                            "dshWebUrl" to (dshWebUrl ?: "http://127.0.0.1:$LOCAL_DSH_PORT"),
                            "bridgeToken" to bridgeToken,
                            "dshVersion" to lastCapabilitiesDshVersion,
                            "executorMode" to executorTag,
                            "bootMs" to bootMs,
                            "endpointsCount" to caps.optInt("endpointsCount", 0),
                            "udsReady" to bridgeSocket.exists()
                        )
                    )
                    return mapOf("ok" to true, "bootMs" to bootMs, "executorMode" to executorTag, "capabilities" to caps.toString(), "status" to getStatus())
                }
            }
            synchronized(readinessSignal) {
                runCatching { readinessSignal.wait(140) }
            }
        }

        val tail = getEngineLogs().takeLast(6).joinToString(" | ")
        lastEngineError = "DSH ($executorTag) startup timed out (${timeoutMs / 1000}s): $tail"
        appendLog("[runtime] TIMEOUT: $lastEngineError")
        return mapOf("ok" to false, "error" to lastEngineError, "status" to getStatus())
    }

    private fun probeLocalCapabilities(): JSONObject? = runCatching {
        val conn = (URL("http://127.0.0.1:$LOCAL_DSH_PORT/gbridge/v1/capabilities").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 350
            readTimeout = 800
            setRequestProperty("Authorization", "Bearer $bridgeToken")
        }
        try {
            if (conn.responseCode in 200..299) {
                conn.inputStream.use { JSONObject(it.bufferedReader().readText()) }
            } else null
        } finally {
            conn.disconnect()
        }
    }.getOrNull()

    private fun cleanDirFilesNoFollow(dir: File, preservePrefix: String): Long {
        val st = runCatching { Os.lstat(dir.absolutePath) }.getOrNull() ?: return 0L
        if (!OsConstants.S_ISDIR(st.st_mode)) return 0L
        var freed = 0L
        val children = dir.listFiles() ?: return 0L
        for (child in children) {
            val cst = runCatching { Os.lstat(child.absolutePath) }.getOrNull() ?: continue
            if (OsConstants.S_ISLNK(cst.st_mode)) continue
            if (OsConstants.S_ISDIR(cst.st_mode)) {
                if (child.absolutePath == preservePrefix || child.absolutePath.startsWith("$preservePrefix/")) continue
                freed += cleanDirFilesNoFollow(child, preservePrefix)
            } else if (OsConstants.S_ISREG(cst.st_mode)) {
                if (child.absolutePath.startsWith("$preservePrefix/")) continue
                freed += cst.st_size
                runCatching { Os.remove(child.absolutePath) }
            }
        }
        return freed
    }

    fun cleanCache(): Map<String, Any?> {
        var freedBytes = 0L
        val compileCacheDir = File(homeDir, ".cache/node-compile-cache").absolutePath
        val dirs = mutableListOf(
            File(homeDir, ".npm/_cacache"),
            File(homeDir, ".cache")
        )
        // Avoid deleting active apt archives/lists while a toolkit installation is running!
        if (activeToolkitInstalls.get() == 0) {
            dirs.add(File(ubuntuRoot, "var/cache/apt/archives"))
            dirs.add(File(ubuntuRoot, "var/lib/apt/lists"))
        }
        // Only sweep active tmp dirs when no engine, shell, or toolkit install is using them!
        if (!isEngineAlive() && shells.isEmpty() && activeToolkitInstalls.get() == 0) {
            dirs.add(File(ubuntuRoot, "tmp"))
            dirs.add(prootTmpDir)
            dirs.add(tawcTmpDir)
        }
        dirs.forEach { dir ->
            if (dir.exists()) {
                freedBytes += cleanDirFilesNoFollow(dir, compileCacheDir)
            }
        }
        prootTmpDir.mkdirs()
        tawcTmpDir.mkdirs()
        lastHomeSizeAtMs = 0L
        return mapOf("ok" to true, "freedKb" to (freedBytes / 1024L), "status" to getStatus())
    }

    fun rebuildContainerPreserveHome(done: (Map<String, Any?>) -> Unit) {
        worker.execute {
            try {
                synchronized(bootstrapLock) {
                    stopEngineSync()
                    sendProgress("rebuild", 15, "保留 /root 数据卷，清理旧容器根文件系统…")
                    TarGzExtractor.deleteTreeNoFollow(ubuntuRoot)
                    TarGzExtractor.deleteTreeNoFollow(File(containersRoot, "tawcroot"))
                    ubuntuRoot.mkdirs()
                    etcPrepared = false
                    ptySupportedCache = null
                }
                bootstrapRuntime(done)
            } catch (e: Throwable) {
                val msg = e.message ?: "rebuild_failed"
                sendProgress("error", 0, "重建容器失败：$msg")
                done(mapOf("ok" to false, "error" to msg, "status" to getStatus()))
            }
        }
    }

    fun performAbUpgrade(targetVersion: String, remoteBaseUrl: String?, done: (Map<String, Any?>) -> Unit) {
        worker.execute {
            var stagedTargetDir: File? = null
            var startedFg = false
            var switchedMeta = false
            var revertMetaFn: (() -> Unit)? = null
            synchronized(bootstrapLock) {
                try {
                    val availBytes = runCatching { StatFs(ctx.filesDir.absolutePath).availableBytes }.getOrDefault(Long.MAX_VALUE)
                    if (availBytes < 750L * 1024L * 1024L) {
                        error("手机可用存储空间不足（当前 ${availBytes / (1024L * 1024L)} MB，A/B 槽位升级至少需要 750 MB）")
                    }
                    GrassBagEngineService.startOrUpdate(
                        ctx,
                        "正在执行 DSH A/B 槽位升级",
                        "部署 @deepseek-ai/dsh@$targetVersion 到备用槽位，请保持应用运行…",
                        wakeLockMs = 10 * 60 * 1000L
                    )
                    startedFg = true

                    val st = readMeta()
                    val cur = st.optString("activeSlot", "slot-a")
                    val standby = if (cur == "slot-a") "slot-b" else "slot-a"
                    val curDir = if (cur == "slot-a") slotA else slotB
                    val targetDir = if (standby == "slot-a") slotA else slotB
                    stagedTargetDir = targetDir
                    val prevVersion = lastCapabilitiesDshVersion ?: st.optString("dshVersion", "0.2.2-rc.5")
                    val prevLkgSlot = st.optString("lkgSlot", cur)
                    val prevDshPrevVersion = st.optString("dshPrevVersion", "")
                    val prevUserUpgradedAb = st.optBoolean("userUpgradedAb", false)

                    sendProgress("snapshot", 15, "为 ~/.dsh 生成回滚快照…")
                    File(slotsRoot, "snapshot-${System.currentTimeMillis()}.json").writeText(
                        JSONObject().put("slot", cur).put("version", prevVersion).toString(2)
                    )

                    sendProgress("stage", 30, "准备备用槽位 $standby ($targetVersion)…")
                    TarGzExtractor.deleteTreeNoFollow(targetDir)
                    targetDir.mkdirs()
                    val extractingFlag = File(targetDir, ".extracting").apply { writeText("1") }

                    if (!remoteBaseUrl.isNullOrBlank()) {
                        val remote = RemoteHttpAssetSource(remoteBaseUrl)
                        val art = remote.loadManifest()?.optJSONObject("artifacts")?.optJSONObject("engineInit")
                            ?: error("远程清单未包含 engineInit 构件")
                        remote.openStream(art.optString("asset"))?.use { ins ->
                            TarGzExtractor.extractStream(ins, targetDir, art.optString("sha256"), art.optLong("bytes", 0L), freshDir = true)
                        } ?: error("无法下载远程引擎包")
                    } else {
                        // Preserve our zero-patch dsh-gbridge into standby slot, then run REAL npm install!
                        val curBridge = File(curDir, "dsh-gbridge")
                        val standbyBridge = File(targetDir, "dsh-gbridge")
                        if (curBridge.exists()) {
                            curBridge.copyRecursively(standbyBridge, overwrite = true)
                        } else {
                            error("当前槽位缺少 dsh-gbridge，无法执行增量更新")
                        }
                        writeAndroidCordisPatch(File(standbyBridge, "cordis.patch.yml"))

                        val pkgSpec = "@deepseek-ai/dsh@$targetVersion"
                        sendProgress("download", 48, "正在通过 npm 安装 $pkgSpec 到备用槽位 $standby…")
                        appendLog("[upgrade] npm install --no-audit --no-fund --prefix /opt/dsh-slots/$standby $pkgSpec")
                        val pb = buildProotProcess(
                            listOf(
                                "/usr/local/bin/npm",
                                "install",
                                "--no-audit",
                                "--no-fund",
                                "--loglevel=error",
                                "--prefix",
                                "/opt/dsh-slots/$standby",
                                pkgSpec
                            ),
                            "/opt/dsh-slots/$standby"
                        ).first
                        val proc = spawnProcess(pb)
                        val outputTail = LinkedList<String>()
                        val reader = Thread({
                            runCatching {
                                BufferedReader(InputStreamReader(proc.inputStream, Charsets.UTF_8)).use { br ->
                                    while (true) {
                                        val line = br.readLine() ?: break
                                        appendLog("[upgrade] $line")
                                        synchronized(outputTail) {
                                            outputTail.add(line)
                                            while (outputTail.size > 12) outputTail.removeFirst()
                                        }
                                    }
                                }
                            }
                        }, "gb-upgrade-reader").apply { isDaemon = true; start() }
                        val exitedInTime = proc.waitFor(5, java.util.concurrent.TimeUnit.MINUTES)
                        if (!exitedInTime) {
                            runCatching { proc.destroyForcibly() }
                            runCatching { proc.inputStream.close() }
                            runCatching { reader.join(1000) }
                            error("npm 安装 $pkgSpec 超时（超过 5 分钟），请检查网络连接后重试")
                        }
                        runCatching { reader.join(1500) }
                        val exitCode = proc.exitValue()
                        if (exitCode != 0) {
                            val reason = synchronized(outputTail) { outputTail.joinToString("\n") }.ifBlank { "npm exited with code $exitCode" }
                            error("npm 安装 $pkgSpec 失败 (code=$exitCode)：$reason")
                        }
                    }

                    // Verify real installed @deepseek-ai/dsh binary & package.json version before switching!
                    val dshBin = File(targetDir, "node_modules/@deepseek-ai/dsh/lib/bin.js")
                    val dshPkg = File(targetDir, "node_modules/@deepseek-ai/dsh/package.json")
                    if (!dshBin.exists() || !dshPkg.exists()) {
                        error("备用槽位校验失败：未找到 @deepseek-ai/dsh/lib/bin.js")
                    }
                    val installedVer = runCatching { JSONObject(dshPkg.readText()).optString("version", targetVersion) }
                        .getOrDefault(targetVersion)
                    runCatching { extractingFlag.delete() }
                    runCatching { File(targetDir, ".extract-complete").writeText(installedVer) }

                    revertMetaFn = {
                        runCatching {
                            st.put("activeSlot", cur)
                            st.put("lkgSlot", prevLkgSlot)
                            st.put("dshVersion", prevVersion)
                            st.put("dshPrevVersion", prevDshPrevVersion)
                            st.put("userUpgradedAb", prevUserUpgradedAb)
                            writeMeta(st)
                            updateRelativeSymlink(File(slotsRoot, "current"), cur)
                            updateRelativeSymlink(File(slotsRoot, "lkg"), prevLkgSlot)
                        }
                    }

                    sendProgress("switch", 82, "预检通过 (v$installedVer)，原子切换至 $standby 并重启本机引擎…")
                    st.put("lkgSlot", cur)
                    st.put("dshPrevVersion", prevVersion)
                    st.put("activeSlot", standby)
                    st.put("dshVersion", installedVer)
                    st.put("userUpgradedAb", true)
                    val curBridgeSha = st.optString("gbridgeSha256_$cur", st.optString("gbridgeSha256", ""))
                    if (curBridgeSha.isNotEmpty()) st.put("gbridgeSha256_$standby", curBridgeSha)
                    writeMeta(st)
                    updateRelativeSymlink(File(slotsRoot, "current"), standby)
                    updateRelativeSymlink(File(slotsRoot, "lkg"), cur)
                    switchedMeta = true

                    stopEngineSync(keepForegroundService = true)
                    val res = startEngineSync()
                    if (res["ok"] != true) {
                        // Automatic LKG rollback on healthcheck failure: restore metadata + symlinks & remove broken slot!
                        appendLog("[upgrade] 新版本启动失败，自动回滚至 LKG 槽位 $cur (v$prevVersion)…")
                        revertMetaFn?.invoke()
                        switchedMeta = false
                        stopEngineSync(keepForegroundService = true)
                        runCatching { TarGzExtractor.deleteTreeNoFollow(targetDir) }
                        startEngineSync()
                        val errMsg = "v$installedVer 启动自检未通过，已自动回滚至 v$prevVersion：${res["error"]}"
                        sendProgress("error", 0, errMsg)
                        done(mapOf("ok" to false, "error" to errMsg, "status" to getStatus()))
                        return@execute
                    }
                    stagedTargetDir = null
                    switchedMeta = false
                    sendProgress("ready", 100, "已切换至 $standby (v$installedVer)")
                    done(mapOf("ok" to true, "engineStarted" to true, "version" to installedVer, "status" to getStatus()))
                } catch (err: Throwable) {
                    if (switchedMeta) {
                        revertMetaFn?.invoke()
                        switchedMeta = false
                    }
                    stagedTargetDir?.let { runCatching { TarGzExtractor.deleteTreeNoFollow(it) } }
                    if (startedFg && !isEngineAlive()) {
                        GrassBagEngineService.stop(ctx)
                    }
                    val msg = err.message ?: "upgrade_failed"
                    appendLog("[upgrade] ERROR: $msg")
                    sendProgress("error", 0, "升级失败：$msg")
                    done(mapOf("ok" to false, "error" to msg, "status" to getStatus()))
                }
            }
        }
    }

    fun rollbackLkg(done: (Map<String, Any?>) -> Unit) {
        worker.execute {
            synchronized(bootstrapLock) {
                val st = readMeta()
                val cur = st.optString("activeSlot", "slot-a")
                val lkg = st.optString("lkgSlot", "slot-a")
                if (lkg == cur || !isSlotExtracted(lkg)) {
                    done(mapOf("ok" to false, "error" to "备用 LKG 槽位 ($lkg) 尚未写入历史版本，当前无需回滚", "status" to getStatus()))
                    return@execute
                }
                val prevVer = st.optString("dshPrevVersion", "")
                val curVer = st.optString("dshVersion", "0.2.2-rc.5")
                st.put("activeSlot", lkg)
                st.put("lkgSlot", cur)
                if (prevVer.isNotEmpty()) st.put("dshVersion", prevVer)
                st.put("dshPrevVersion", curVer)
                writeMeta(st)
                updateRelativeSymlink(File(slotsRoot, "current"), lkg)
                updateRelativeSymlink(File(slotsRoot, "lkg"), cur)
                stopEngineSync(keepForegroundService = true)
                val res = startEngineSync()
                if (res["ok"] != true) {
                    sendProgress("error", 0, "回滚后引擎启动失败：${res["error"]}")
                }
                done(mapOf("ok" to (res["ok"] == true), "error" to res["error"], "status" to getStatus()))
            }
        }
    }

    fun setExecutorMode(mode: String): Map<String, Any?> {
        val clean = if (mode == "tawcroot" || mode == "proot") mode else detectExecutor()
        val st = readMeta()
            .put("executorMode", clean)
            .put("executorModePinned", true)
        if (clean == "tawcroot") {
            st.remove("tawcUnsupportedFingerprint")
        }
        ptySupportedCache = null
        writeMeta(st)
        return mapOf("ok" to true, "status" to getStatus())
    }

    fun setSdcardMounted(enabled: Boolean): Map<String, Any?> {
        val st = readMeta().put("sdcardMounted", enabled)
        writeMeta(st)
        return mapOf("ok" to true, "status" to getStatus())
    }

    fun setSystemProxy(enabled: Boolean): Map<String, Any?> {
        val st = readMeta().put("useSystemProxy", enabled)
        writeMeta(st)
        return mapOf("ok" to true, "status" to getStatus())
    }

    fun installToolkit(toolkitId: String, requestedPackages: List<String>, done: (Map<String, Any?>) -> Unit) {
        // Serialize all toolkit installs on a dedicated single-thread executor so tapping two
        // toolkits back-to-back never races on `/var/lib/dpkg/lock-frontend`!
        toolkitExecutor.execute {
            activeToolkitInstalls.incrementAndGet()
            var startedFg = false
            try {
                if (!isContainerExtracted()) {
                    done(mapOf("ok" to false, "error" to "请先初始化本机 Ubuntu 容器后再安装工具链", "status" to getStatus()))
                    return@execute
                }
                ensureContainerEtcFiles(force = true)
                val aptPkgs = requestedPackages.mapNotNull { raw ->
                    val clean = raw.trim()
                    when (clean) {
                        "pip" -> "python3-pip"
                        "uv" -> null // not an Ubuntu 24.04 apt package; installed via python3/pip if needed
                        "ubuntu-base", "nodejs-24.22.3", "npm", "dsh" -> null
                        "" -> null
                        else -> if (clean.matches(Regex("^[a-z0-9][a-z0-9+.-]+$"))) clean else null
                    }
                }.distinct()

                if (aptPkgs.isEmpty()) {
                    done(mapOf("ok" to true, "installedToolkits" to detectInstalledToolkits(), "status" to getStatus()))
                    return@execute
                }

                GrassBagEngineService.startOrUpdate(
                    ctx,
                    "正在安装容器工具包",
                    "apt 安装 ${aptPkgs.joinToString(" ")}…",
                    wakeLockMs = 15 * 60 * 1000L
                )
                startedFg = true

                val pkgLine = aptPkgs.joinToString(" ")
                // Self-healing, fast-cached apt/dpkg transaction:
                // 1) Recovers automatically if a prior dpkg run was interrupted halfway
                // 2) Cleans stale apt-dpkg-install-* staging dirs & lockfiles (safe inside serialized toolkitExecutor)
                // 3) Reuses fresh gzipped apt package lists (<4h) so sequential installs skip 60s+ index downloads,
                //    and automatically refreshes indexes + retries if a mirror rotated package versions.
                // 4) Uses rootfs /tmp with non-interactive confdef/confold, UCF_FORCE_CONFFOLD=1, and auto-retries.
                val cmd = buildString {
                    append("set -e; ")
                    append("export DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 NEEDRESTART_SUSPEND=1 TMPDIR=/tmp; ")
                    append("mkdir -p /tmp /var/tmp /var/cache/apt/archives/partial /var/lib/apt/lists/partial; ")
                    append("chmod 1777 /tmp /var/tmp 2>/dev/null || true; ")
                    append("rm -rf /tmp/apt-dpkg-install-* /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock; ")
                    append("dpkg --configure -a --force-confdef --force-confold || true; ")
                    append("if ! find /var/lib/apt/lists -maxdepth 1 -name '*_Packages*' -mmin -240 2>/dev/null | grep -q .; then ")
                    append("echo '[grassbag] syncing Ubuntu APT package indexes...'; ")
                    append("apt-get update -qq; ")
                    append("fi; ")
                    append("apt-get -f install -y --no-install-recommends || true; ")
                    append("if ! apt-get install -y --no-install-recommends $pkgLine; then ")
                    append("echo '[grassbag] refreshing APT indexes and retrying install...'; ")
                    append("apt-get update -qq; ")
                    append("apt-get -f install -y --no-install-recommends || true; ")
                    append("apt-get install -y --no-install-recommends $pkgLine; ")
                    append("fi; ")
                    append("apt-get clean; ")
                    append("rm -rf /tmp/apt-dpkg-install-*")
                }

                fun runAptAttempt(forceProot: Boolean?): Triple<Int, String, String> {
                    val (pb, execTag) = buildProotProcess(
                        listOf("/bin/sh", "-c", cmd),
                        "/root",
                        forceProot = forceProot
                    )
                    appendLog("[toolkit:$toolkitId] running ($execTag): apt-get install $pkgLine")
                    val proc = spawnProcess(pb)
                    val tail = LinkedList<String>()
                    val reader = Thread({
                        runCatching {
                            BufferedReader(InputStreamReader(proc.inputStream, Charsets.UTF_8)).use { br ->
                                while (true) {
                                    val line = br.readLine() ?: break
                                    appendLog("[apt] $line")
                                    synchronized(tail) {
                                        tail.add(line)
                                        while (tail.size > 16) tail.removeFirst()
                                    }
                                }
                            }
                        }
                    }, "gb-apt-reader").apply { isDaemon = true; start() }
                    val exitedInTime = proc.waitFor(12, java.util.concurrent.TimeUnit.MINUTES)
                    if (!exitedInTime) {
                        runCatching { proc.destroyForcibly() }
                        runCatching { proc.inputStream.close() }
                        runCatching { reader.join(1000) }
                        return Triple(-1, "apt-get 安装超时（超过 12 分钟），请检查网络连接后重试", execTag)
                    }
                    runCatching { reader.join(1500) }
                    val code = proc.exitValue()
                    val summary = synchronized(tail) { tail.joinToString("\n") }
                    return Triple(code, summary, execTag)
                }

                var (code, reason, usedExec) = runAptAttempt(forceProot = null)
                val hasProot = File(ctx.applicationInfo.nativeLibraryDir, "libproot.so").exists()
                val looksLikeContainerSyscallErr = code != 0 && code != -1 && usedExec == "tawcroot" && (
                    reason.contains("cannot stat", ignoreCase = true) ||
                        reason.contains("Function not implemented", ignoreCase = true) ||
                        reason.contains("Bad address", ignoreCase = true) ||
                        reason.contains("Operation not permitted", ignoreCase = true) ||
                        reason.contains("Segmentation fault", ignoreCase = true)
                    )
                if (looksLikeContainerSyscallErr && hasProot) {
                    appendLog("[toolkit:$toolkitId] tawcroot apt hit syscall error; auto-retrying via PRoot compatibility mode...")
                    val retry = runAptAttempt(forceProot = true)
                    code = retry.first
                    reason = retry.second
                    usedExec = retry.third
                }

                if (code != 0) {
                    val errText = reason.ifBlank { "apt-get exited with code $code ($usedExec)" }
                    done(mapOf("ok" to false, "error" to errText, "installedToolkits" to detectInstalledToolkits(), "status" to getStatus()))
                    return@execute
                }

                // Record installed packages into apt-manifest.json
                runCatching {
                    val curJson = if (aptFile.exists()) JSONObject(aptFile.readText()) else JSONObject()
                    val arr = curJson.optJSONArray("packages") ?: JSONArray()
                    val set = LinkedHashSet<String>()
                    for (i in 0 until arr.length()) set.add(arr.optString(i))
                    set.addAll(aptPkgs)
                    curJson.put("packages", JSONArray(set.toList()))
                    aptFile.writeText(curJson.toString(2))
                }

                appendLog("[toolkit:$toolkitId] installed successfully ($usedExec): $pkgLine")
                done(mapOf("ok" to true, "installedToolkits" to detectInstalledToolkits(), "status" to getStatus()))
            } catch (err: Throwable) {
                appendLog("[toolkit:$toolkitId] ERROR: ${err.message}")
                done(mapOf("ok" to false, "error" to (err.message ?: "toolkit_install_failed"), "status" to getStatus()))
            } finally {
                activeToolkitInstalls.decrementAndGet()
                if (startedFg) {
                    if (isEngineAlive() && engineState == "running") {
                        val ver = lastCapabilitiesDshVersion ?: readMeta().optString("dshVersion", "0.2.2-rc.5")
                        val exec = activeExecutorUsed ?: effectiveExecutorMode()
                        GrassBagEngineService.startOrUpdate(
                            ctx,
                            "GrassBag 本机引擎运行中",
                            "DSH $ver ($exec) · 后台保活中"
                        )
                    } else {
                        GrassBagEngineService.stop(ctx)
                    }
                }
            }
        }
    }

    private fun isScriptPtySupported(): Boolean {
        ptySupportedCache?.let { return it }
        if (!File(ubuntuRoot, "usr/bin/script").exists()) {
            ptySupportedCache = false
            return false
        }
        val ok = runCatching {
            val probe = spawnProcess(buildProotProcess(listOf("/usr/bin/script", "-qfc", "true", "/dev/null"), "/root").first)
            val finished = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                probe.waitFor(3, TimeUnit.SECONDS)
            } else {
                probe.waitFor()
                true
            }
            if (!finished) {
                probe.destroyForcibly()
                false
            } else {
                probe.exitValue() == 0
            }
        }.getOrDefault(false)
        ptySupportedCache = ok
        return ok
    }

    fun exportEncryptedBackup(passphrase: String): Map<String, Any?> = runCatching {
        val cleanPass = passphrase.trim()
        require(cleanPass.length >= 6) { "备份加密口令至少需要 6 位字符" }
        val zipOut = ByteArrayOutputStream()
        ZipOutputStream(zipOut).use { zos ->
            fun pack(f: File, name: String) {
                if (!f.exists() || !f.isFile) return
                zos.putNextEntry(ZipEntry(name))
                FileInputStream(f).use { it.copyTo(zos) }
                zos.closeEntry()
            }
            pack(metaFile, "runtime-state.json")
            pack(aptFile, "apt-manifest.json")
            File(homeDir, ".dsh").walkTopDown().maxDepth(3).forEach { f ->
                if (f.isFile && f.length() < 2 * 1024 * 1024) {
                    pack(f, "home/${f.relativeTo(homeDir).path}")
                }
            }
        }
        val cipherBytes = vault.encryptWithPassphrase(zipOut.toByteArray(), cleanPass)
        val dir = ctx.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: ctx.filesDir
        dir.mkdirs()
        val dest = File(dir, "GrassBag-Backup-${System.currentTimeMillis()}.gbag.enc")
        FileOutputStream(dest).use { it.write(cipherBytes) }
        mapOf("ok" to true, "path" to dest.absolutePath, "bytes" to cipherBytes.size)
    }.getOrElse { mapOf("ok" to false, "error" to (it.message ?: "backup_error")) }

    fun startLocalShell(tabId: String, cwd: String?, cols: Int = 80, rows: Int = 24): Map<String, Any?> {
        closeLocalShell(tabId)
        return runCatching {
            val nativeLibDir = File(ctx.applicationInfo.nativeLibraryDir)
            val useContainer = isContainerExtracted() &&
                (File(nativeLibDir, "libtawcroot.so").exists() || File(nativeLibDir, "libproot.so").exists())
            var isPty = false
            var usesPtyBridge = false
            var modeTag = "android-sh"
            var effectiveCwd = homeDir.absolutePath
            val pb = if (useContainer) {
                val requestedCwd = if (!cwd.isNullOrBlank() && cwd.startsWith("/")) cwd else "/root/workspace"
                val hostCwd = resolveHostDirForContainerWorkdir(requestedCwd)
                effectiveCwd = if (hostCwd.isDirectory) requestedCwd else "/root/workspace"
                val shellBin = if (File(ubuntuRoot, "bin/bash").exists()) "/bin/bash" else "/bin/sh"
                val hasPtyBridge = File(shimsRoot, "pty-bridge.mjs").exists() && isSlotExtracted()
                val pair = when {
                    hasPtyBridge -> {
                        isPty = true
                        usesPtyBridge = true
                        buildProotProcess(
                            listOf(
                                "/usr/local/bin/node",
                                "/opt/shims/pty-bridge.mjs",
                                shellBin,
                                effectiveCwd,
                                cols.coerceIn(20, 400).toString(),
                                rows.coerceIn(8, 200).toString()
                            ),
                            effectiveCwd
                        )
                    }
                    isScriptPtySupported() -> {
                        isPty = true
                        buildProotProcess(listOf("/usr/bin/script", "-qfc", "$shellBin -i", "/dev/null"), effectiveCwd)
                    }
                    else -> {
                        buildProotProcess(listOf(shellBin, "-i"), effectiveCwd)
                    }
                }
                modeTag = "${pair.second}-ubuntu${if (isPty) "-pty" else ""}"
                pair.first
            } else {
                val dir = if (!cwd.isNullOrBlank() && File(cwd).isDirectory) File(cwd) else homeDir
                effectiveCwd = dir.absolutePath
                ProcessBuilder("/system/bin/sh")
                    .directory(dir)
                    .redirectErrorStream(true)
                    .also { p ->
                        p.environment().apply {
                            put("HOME", homeDir.absolutePath)
                            put("TERM", "xterm-256color")
                            put("DROID_BRIDGE_SOCKET", droidSocket.absolutePath)
                            put("DROID_BRIDGE_TOKEN", droidDaemon.bearerToken)
                        }
                    }
            }
            val proc = spawnProcess(pb)
            val session = ShellSession(proc = proc, usesPtyBridge = usesPtyBridge, cwd = effectiveCwd)
            shells[tabId] = session
            worker.execute {
                val cbuf = CharArray(4096)
                var handshakeHandled = !usesPtyBridge
                val pendingOsc = StringBuilder()
                runCatching {
                    InputStreamReader(proc.inputStream, Charsets.UTF_8).use { reader ->
                        while (true) {
                            val n = reader.read(cbuf)
                            if (n <= 0) break
                            var chunk = String(cbuf, 0, n)
                            if (!handshakeHandled) {
                                pendingOsc.append(chunk)
                                val combined = pendingOsc.toString()
                                val hasComplete = combined.contains("\u001b]777;gbmode;pty\u0007") ||
                                    combined.contains("\u001b]777;gbmode;pipe\u0007")
                                if (hasComplete) {
                                    handshakeHandled = true
                                    val isPipeFallback = combined.contains("\u001b]777;gbmode;pipe\u0007")
                                    chunk = combined
                                        .replace("\u001b]777;gbmode;pty\u0007", "")
                                        .replace("\u001b]777;gbmode;pipe\u0007", "")
                                    pendingOsc.clear()
                                    if (isPipeFallback) {
                                        emit("local_term_mode", mapOf("tabId" to tabId, "isPty" to false, "mode" to "pipe"))
                                    }
                                } else if (combined.length < 32 && ("\u001b]777;gbmode;".startsWith(combined) || combined.startsWith("\u001b]777;gbmode;"))) {
                                    continue // Wait for the rest of the OSC handshake across read chunks
                                } else {
                                    handshakeHandled = true
                                    chunk = combined
                                    pendingOsc.clear()
                                }
                            }
                            if (chunk.isNotEmpty()) {
                                enqueueLocalTermData(tabId, chunk)
                            }
                        }
                    }
                }
                flushLocalTermDataFor(tabId)
                val exit = runCatching { proc.waitFor() }.getOrDefault(0)
                if (shells.remove(tabId, session)) {
                    emit("local_term_exit", mapOf("tabId" to tabId, "exitCode" to exit))
                }
            }
            mapOf(
                "ok" to true,
                "tabId" to tabId,
                "isPty" to isPty,
                "supportsResize" to usesPtyBridge,
                "mode" to modeTag,
                "cwd" to effectiveCwd
            )
        }.getOrElse { mapOf("ok" to false, "error" to (it.message ?: "shell_failed")) }
    }

    fun writeLocalShell(tabId: String, input: String): Boolean {
        val session = shells[tabId] ?: return false
        return runCatching {
            synchronized(session.proc.outputStream) {
                session.proc.outputStream.write(input.toByteArray(Charsets.UTF_8))
                session.proc.outputStream.flush()
            }
            true
        }.getOrDefault(false)
    }

    fun resizeLocalShell(tabId: String, cols: Int, rows: Int): Boolean {
        val session = shells[tabId] ?: return false
        if (!session.usesPtyBridge) return false
        val safeCols = cols.coerceIn(20, 400)
        val safeRows = rows.coerceIn(8, 200)
        val seq = "\u001b]777;gbresize;$safeCols;$safeRows\u0007"
        return writeLocalShell(tabId, seq)
    }

    fun signalLocalShell(tabId: String, signal: String): Boolean {
        val session = shells[tabId] ?: return false
        val cleanSig = if (signal.equals("SIGTERM", ignoreCase = true)) "SIGTERM" else "SIGINT"
        if (session.usesPtyBridge) {
            return writeLocalShell(tabId, "\u001b]777;gbsignal;$cleanSig\u0007")
        }
        return if (cleanSig == "SIGINT") writeLocalShell(tabId, "\u0003") else false
    }

    fun closeLocalShell(tabId: String) {
        shells.remove(tabId)?.let { session ->
            // Close stdin & send SIGTERM first so pty-bridge.mjs can SIGHUP its bash process group
            // cleanly instead of leaving orphaned shells behind!
            runCatching { session.proc.outputStream.close() }
            runCatching { session.proc.destroy() }
            worker.execute {
                runCatching {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        session.proc.waitFor(280, TimeUnit.MILLISECONDS)
                    } else {
                        Thread.sleep(200)
                    }
                }
                runCatching { session.proc.destroyForcibly() }
            }
        }
    }

    fun dispose() {
        networkCallback?.let { cb ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                runCatching {
                    val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                    cm?.unregisterNetworkCallback(cb)
                }
            }
        }
        networkCallback = null
        networkCallbackRegistered.set(false)
        stopEngineSync()
        shells.keys.toList().forEach { closeLocalShell(it) }
        phoneDaemon.stop()
        droidDaemon.stop()
    }

    private fun sendProgress(stage: String, percent: Int, message: String) {
        val now = System.currentTimeMillis()
        val shouldEmit = synchronized(progressLock) {
            val isEdge = percent <= 0 || percent >= 100 || stage != lastProgressStage
            val elapsed = now - lastProgressAtMs
            if (isEdge || elapsed >= 180L || (percent != lastProgressPct && elapsed >= 120L)) {
                lastProgressStage = stage
                lastProgressPct = percent
                lastProgressAtMs = now
                true
            } else {
                false
            }
        }
        if (shouldEmit) {
            emit("runtime_progress", mapOf("stage" to stage, "percent" to percent, "message" to message))
        }
    }

    companion object {
        private const val TAG = "GrassBagRuntime"
        const val LOCAL_DSH_PORT = 13080
        private val DSH_WEB_URL_REGEX = Regex("""https?://127\.0\.0\.1:\d+/\?token=[^\s\u001b"'<>)]+""")
        private val TOKEN_QUERY_REGEX = Regex("""([?&]token=)[^\s&"'#]+""", RegexOption.IGNORE_CASE)

        @Volatile
        private var instance: RuntimeController? = null

        private val bgPrewarmStarted = AtomicBoolean(false)

        fun getInstance(appContext: Context, vault: KeystoreVault): RuntimeController {
            return instance ?: synchronized(this) {
                instance ?: RuntimeController(appContext.applicationContext, vault).also { instance = it }
            }
        }

        fun ensureForegroundServiceIfRunning(appContext: Context) {
            instance?.ensureForegroundServiceIfRunning()
        }

        /**
         * Off-main-thread entrypoint for `MainActivity.onCreate()` so Keystore, SharedPreferences,
         * socket daemons, and DSH container startup never block the first Flutter frame.
         */
        fun prewarmInBackground(appContext: Context) {
            if (!bgPrewarmStarted.compareAndSet(false, true)) return
            val appCtx = appContext.applicationContext
            Thread({
                runCatching {
                    val vault = KeystoreVault.getInstance(appCtx)
                    getInstance(appCtx, vault).prewarmIfReady()
                }.onFailure {
                    Log.w(TAG, "prewarmInBackground failed: ${it.message}")
                }
            }, "GrassBag-Prewarm").apply {
                isDaemon = true
                start()
            }
        }
    }
}
