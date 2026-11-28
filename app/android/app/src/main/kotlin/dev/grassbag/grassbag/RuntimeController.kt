package dev.grassbag.grassbag

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URL
import java.security.MessageDigest
import java.util.Collections
import java.util.LinkedList
import java.util.TimeZone
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
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
    @Volatile
    private var cachedHasPayloads: Boolean? = null

    fun hasBundledAssets(): Boolean {
        if (!manifestChecked) loadManifest()
        return cachedManifestText != null
    }

    fun hasAsset(relPath: String): Boolean {
        if (relPath.isBlank()) return false
        return runCatching {
            ctx.assets.open(relPath).use { true }
        }.getOrDefault(false)
    }

    /**
     * Returns true ONLY when heavy offline container + DSH payloads (`base-arm64.gbag` &
     * `engine-init.gbag`) are physically bundled inside the APK. Lean online-download APKs
     * bundle only `shims.gbag`, `gbridge.gbag`, and `runtime-manifest.json` (~260 KB).
     */
    fun hasBundledRuntimePayloads(): Boolean {
        cachedHasPayloads?.let { return it }
        val manifest = loadManifest()
        val arts = manifest?.optJSONObject("artifacts")
        val baseAsset = arts?.optJSONObject("baseRootfs")?.optString("asset", "") ?: ""
        val engineAsset = arts?.optJSONObject("engineInit")?.optString("asset", "") ?: ""
        val present = baseAsset.isNotBlank() &&
            engineAsset.isNotBlank() &&
            hasAsset(baseAsset) &&
            hasAsset(engineAsset)
        cachedHasPayloads = present
        return present
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

    private fun openHttpsConnection(
        initialUrl: String,
        connectTimeoutMs: Int,
        readTimeoutMs: Int
    ): HttpURLConnection? {
        var current = URL(initialUrl)
        if (!current.protocol.equals("https", ignoreCase = true)) {
            return null
        }
        for (hop in 0..5) {
            val conn = (current.openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = false
                connectTimeout = connectTimeoutMs
                readTimeout = readTimeoutMs
            }
            val code = conn.responseCode
            if (code in 301..303 || code == 307 || code == 308) {
                val loc = conn.getHeaderField("Location")?.trim().orEmpty()
                runCatching { conn.disconnect() }
                if (loc.isEmpty() || hop == 5) return null
                val next = URL(current, loc)
                if (!next.protocol.equals("https", ignoreCase = true)) return null
                current = next
                continue
            }
            return conn
        }
        return null
    }

    override fun loadManifest(): JSONObject? = runCatching {
        val c = openHttpsConnection(
            "${rootUrl.trimEnd('/')}/runtime-manifest.json",
            connectTimeoutMs = 8000,
            readTimeoutMs = 10000
        ) ?: return@runCatching null
        try {
            if (c.responseCode !in 200..299) return@runCatching null
            if (c.contentLengthLong > MAX_MANIFEST_BYTES) return@runCatching null
            c.inputStream.use { ins ->
                val out = java.io.ByteArrayOutputStream()
                val buf = ByteArray(8192)
                var total = 0L
                while (true) {
                    val n = ins.read(buf)
                    if (n <= 0) break
                    total += n
                    if (total > MAX_MANIFEST_BYTES) return@runCatching null
                    out.write(buf, 0, n)
                }
                JSONObject(out.toString(Charsets.UTF_8.name()))
            }
        } finally {
            c.disconnect()
        }
    }.getOrNull()

    override fun openStream(relPath: String): InputStream? = runCatching {
        val c = openHttpsConnection(
            "${rootUrl.trimEnd('/')}/${relPath.trimStart('/')}",
            connectTimeoutMs = 8000,
            readTimeoutMs = 30000
        ) ?: return@runCatching null
        try {
            if (c.responseCode in 200..299 && c.contentLengthLong <= MAX_PAYLOAD_BYTES) {
                val raw = c.inputStream
                object : java.io.FilterInputStream(raw) {
                    private var bytesRead = 0L

                    private fun checkCap(n: Int): Int {
                        if (n > 0) {
                            bytesRead += n
                            if (bytesRead > MAX_PAYLOAD_BYTES) {
                                throw java.io.IOException("Remote runtime asset exceeds 512 MiB safety cap")
                            }
                        }
                        return n
                    }

                    override fun read(): Int {
                        val b = super.read()
                        if (b >= 0) checkCap(1)
                        return b
                    }

                    override fun read(b: ByteArray, off: Int, len: Int): Int =
                        checkCap(super.read(b, off, len))

                    override fun close() {
                        try {
                            super.close()
                        } finally {
                            runCatching { c.disconnect() }
                        }
                    }
                }
            } else {
                runCatching { c.disconnect() }
                null
            }
        } catch (t: Throwable) {
            runCatching { c.disconnect() }
            throw t
        }
    }.getOrNull()

    companion object {
        private const val MAX_MANIFEST_BYTES = 2L * 1024L * 1024L
        private const val MAX_PAYLOAD_BYTES = 512L * 1024L * 1024L
    }
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
    private val upgradeInProgress = AtomicBoolean(false)
    private val bootstrapRunning = AtomicBoolean(false)
    private val bootstrapCancelRequested = AtomicBoolean(false)
    private val activeDownloadConn = AtomicReference<HttpURLConnection?>(null)
    private class BootstrapCancelledException : RuntimeException("已暂停下载，断点进度已保留")
    private val nativeLibDirFile = File(ctx.applicationInfo.nativeLibraryDir)
    private val hasTawcrootBin: Boolean = File(nativeLibDirFile, "libtawcroot.so").exists()
    private val hasProotBin: Boolean = File(nativeLibDirFile, "libproot.so").exists()
    @Volatile
    private var cachedInstalledToolkits: List<String>? = null
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
    val runtimeDownloadsDir = File(ctx.filesDir, "runtime-downloads")
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
    @Volatile
    private var activeStartupEpoch: Int = -1

    private val homeSizeRefreshing = AtomicBoolean(false)
    private val prewarmTriggered = AtomicBoolean(false)
    private val autoRecoverPending = AtomicBoolean(false)
    private val stopEpoch = AtomicInteger(0)
    private val autoRestartLock = Any()
    private val recentAutoRestartMs = LinkedList<Long>()
    private val networkCallbackRegistered = AtomicBoolean(false)
    private val lastNetworkNotifyMs = AtomicLong(0L)
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val engineLogs = Collections.synchronizedList(LinkedList<String>())
    private val engineLock = Any()
    private val bootstrapLock = Any()
    private val metaLock = Any()
    private val dnsLock = Any()
    private val etcLock = Any()
    private val readinessSignal = Object()

    fun addListener(listener: (String, Map<String, Any?>) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (String, Map<String, Any?>) -> Unit) {
        listeners.remove(listener)
    }

    fun ownsForegroundService(): Boolean =
        bootstrapRunning.get() ||
            upgradeInProgress.get() ||
            activeToolkitInstalls.get() > 0 ||
            autoRecoverPending.get() ||
            engineState == "starting" ||
            isEngineAlive()

    fun cancelLocalSessionsAsync(sessionIds: List<String>) {
        val unique = sessionIds.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        if (unique.isEmpty()) return
        worker.execute {
            for (sid in unique) {
                cancelLocalSessionSync(sid)
            }
        }
    }

    private fun cancelLocalSessionSync(sessionId: String): Boolean {
        val encoded = runCatching { java.net.URLEncoder.encode(sessionId, "UTF-8") }.getOrDefault(sessionId)
        val path = "/gbridge/v1/sessions/$encoded/cancel"
        if (bridgeSocket.exists()) {
            val udsOk = runCatching {
                val sock = LocalSocket(LocalSocket.SOCKET_STREAM)
                try {
                    sock.connect(LocalSocketAddress(bridgeSocket.absolutePath, LocalSocketAddress.Namespace.FILESYSTEM))
                    sock.soTimeout = 2500
                    val body = "{}"
                    val req = "POST $path HTTP/1.1\r\n" +
                        "Host: localhost\r\n" +
                        "Authorization: Bearer $bridgeToken\r\n" +
                        "Content-Type: application/json\r\n" +
                        "Content-Length: ${body.length}\r\n" +
                        "Connection: close\r\n\r\n$body"
                    sock.outputStream.write(req.toByteArray(Charsets.UTF_8))
                    sock.outputStream.flush()
                    val buf = ByteArray(256)
                    val n = sock.inputStream.read(buf)
                    val firstLine = if (n > 0) String(buf, 0, n, Charsets.UTF_8).substringBefore("\r\n") else ""
                    val code = firstLine.split(' ').getOrNull(1)?.toIntOrNull() ?: -1
                    code in 200..299
                } finally {
                    runCatching { sock.close() }
                }
            }.getOrDefault(false)
            if (udsOk) {
                appendLog("[runtime] emergency-stop cancelled local session $sessionId via UDS")
                return true
            }
        }
        val httpOk = runCatching {
            val conn = (URL("http://127.0.0.1:$LOCAL_DSH_PORT$path").openConnection(Proxy.NO_PROXY) as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 800
                readTimeout = 2000
                doOutput = true
                setRequestProperty("Authorization", "Bearer $bridgeToken")
                setRequestProperty("Content-Type", "application/json")
            }
            try {
                conn.outputStream.use { it.write("{}".toByteArray(Charsets.UTF_8)) }
                conn.responseCode in 200..299
            } finally {
                conn.disconnect()
            }
        }.getOrDefault(false)
        if (httpOk) {
            appendLog("[runtime] emergency-stop cancelled local session $sessionId via HTTP")
        }
        return httpOk
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

    private fun tryReserveAutoRestartSlot(): Boolean = synchronized(autoRestartLock) {
        val now = SystemClock.elapsedRealtime()
        while (recentAutoRestartMs.isNotEmpty() && now - recentAutoRestartMs.first > 5 * 60 * 1000L) {
            recentAutoRestartMs.removeFirst()
        }
        if (recentAutoRestartMs.size >= 3) {
            return false
        }
        recentAutoRestartMs.addLast(now)
        true
    }

    private fun nextAutoRestartBackoffMs(): Long = synchronized(autoRestartLock) {
        when (recentAutoRestartMs.size) {
            1 -> 600L
            2 -> 1500L
            else -> 3000L
        }
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

    /**
     * Called synchronously from `MainActivity.onPause()` BEFORE the Activity loses foreground
     * importance: ensures `GrassBagEngineService` is promoted while foreground-eligible AND holds
     * CPU WakeLock + low-latency WifiLock so switching to other apps never freezes DSH or drops
     * active DeepSeek HTTPS streams!
     */
    fun onActivityBackgrounded() {
        val alive = isEngineAlive()
        val starting = engineState == "starting"
        val hasActiveWork = GrassBagEngineService.hasNativeActiveWork() ||
            activeToolkitInstalls.get() > 0 ||
            upgradeInProgress.get() ||
            bootstrapRunning.get()
        if (!alive && !starting && !hasActiveWork) return
        if (hasActiveWork) {
            val isPhone = SafetyGate.hasActiveTurn()
            GrassBagEngineService.startOrUpdate(
                ctx = ctx,
                heading = if (isPhone) "GrassBag 正在操控手机" else "GrassBag 正在后台执行任务",
                detail = if (isPhone) "操作执行中并保持网络稳定 · 可在悬浮岛随时暂停" else "保持后台 CPU 与网络通道畅通，防止切应用断连",
                wakeLockMs = 15 * 60 * 1000L,
                holdWifiLock = true
            )
        } else if (starting) {
            GrassBagEngineService.startOrUpdate(
                ctx = ctx,
                heading = "GrassBag 正在启动本机引擎…",
                detail = "后台持续启动中，完成后自动保活",
                wakeLockMs = 3 * 60 * 1000L,
                holdWifiLock = true
            )
        } else {
            // Brief 120s grace WakeLock + WifiLock on app switches so copying content, OAuth sign-in,
            // or immediate background handoffs never freeze the container or poison pooled sockets.
            val ver = lastCapabilitiesDshVersion ?: readMeta().optString("dshVersion", "0.2.2-rc.5")
            val exec = activeExecutorUsed ?: effectiveExecutorMode()
            GrassBagEngineService.startOrUpdate(
                ctx = ctx,
                heading = "GrassBag 本机引擎运行中",
                detail = "DSH $ver ($exec) · 后台保活中",
                wakeLockMs = 120_000L,
                holdWifiLock = true
            )
        }
    }

    private fun emit(type: String, payload: Map<String, Any?>) {
        for (l in listeners) {
            runCatching { l(type, payload) }
        }
    }

    init {
        SafetyGate.init(ctx)
        SafetyGate.addEmergencyStopListener { sessionIds ->
            cancelLocalSessionsAsync(sessionIds)
        }
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
            runtimeDownloadsDir,
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

    private fun resolveSystemProxyInfo(): Pair<String, String>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        return runCatching {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return null
            val proxy = cm.defaultProxy ?: return null
            val host = proxy.host?.trim()
            val port = proxy.port
            if (host.isNullOrEmpty() || port <= 0) return null
            val formattedHost = if (host.contains(':') && !host.startsWith("[")) "[$host]" else host
            val exclusions = LinkedHashSet<String>().apply {
                add("127.0.0.1")
                add("localhost")
                add("::1")
                proxy.exclusionList?.forEach { raw ->
                    val cleaned = raw.trim()
                    if (cleaned.isNotEmpty()) add(cleaned)
                }
            }
            "http://$formattedHost:$port" to exclusions.joinToString(",")
        }.getOrNull()
    }

    private fun refreshContainerDns() {
        if (!ubuntuRoot.exists()) return
        synchronized(dnsLock) {
            runCatching {
                val etcDir = File(ubuntuRoot, "etc")
                etcDir.mkdirs()
                val wantResolv = resolveSystemDnsServers().joinToString("\n", postfix = "\n") { "nameserver $it" }
                val resolv = File(etcDir, "resolv.conf")
                val curResolv = runCatching { if (resolv.isFile) resolv.readText() else null }.getOrNull()
                if (curResolv != wantResolv) {
                    val tmp = File(etcDir, "resolv.conf.tmp.${Thread.currentThread().id}")
                    tmp.writeText(wantResolv)
                    runCatching { Os.rename(tmp.absolutePath, resolv.absolutePath) }.onFailure {
                        runCatching { Os.remove(resolv.absolutePath) }
                        if (!tmp.renameTo(resolv)) {
                            resolv.writeText(wantResolv)
                            runCatching { tmp.delete() }
                        }
                    }
                }
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

    private fun ensureContainerEtcFiles(force: Boolean = false): Unit = synchronized(etcLock) {
        if (etcPrepared && !force) return@synchronized
        runCatching {
            val etcDir = File(ubuntuRoot, "etc")
            val etcStamp = File(etcDir, ".grassbag-etc-v2")
            // Cold-start fast path: skip 15+ redundant config writes/chmod/group scans when container
            // /etc was already configured; only refresh live Android DNS servers!
            if (!force && etcStamp.isFile) {
                refreshContainerDns()
                etcPrepared = true
                return@synchronized
            }
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
                    val caTmp = File(caDst.parentFile, ".ca-certificates.crt.tmp.${System.nanoTime()}")
                    bundledCa.copyTo(caTmp, overwrite = true)
                    if (!caTmp.renameTo(caDst)) {
                        runCatching { Os.remove(caDst.absolutePath) }
                        if (!caTmp.renameTo(caDst)) {
                            bundledCa.copyTo(caDst, overwrite = true)
                            runCatching { caTmp.delete() }
                        }
                    }
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
                val existingGids = GROUP_GID_REGEX.findAll(existingText).map { it.groupValues[1] }.toHashSet()
                val statusLine = runCatching {
                    File("/proc/self/status").readLines().firstOrNull { it.startsWith("Groups:") }
                }.getOrNull()
                val currentGids = mutableSetOf<String>()
                runCatching { currentGids.add(Os.getgid().toString()) }
                statusLine?.substringAfter("Groups:")?.trim()?.split(WHITESPACE_REGEX)?.forEach { token ->
                    if (token.matches(DIGITS_REGEX)) currentGids.add(token)
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
            runCatching { File(etcDir, ".grassbag-etc-v2").writeText("ok") }
            etcPrepared = true
        }
        Unit
    }

    private fun updateRelativeSymlink(linkFile: File, relativeTarget: String) {
        val parent = linkFile.parentFile ?: error("Missing parent directory for symlink ${linkFile.path}")
        val tmpLink = File(parent, ".${linkFile.name}.tmp.${System.nanoTime()}")
        runCatching { Os.remove(tmpLink.absolutePath) }
        Os.symlink(relativeTarget, tmpLink.absolutePath)
        try {
            Os.rename(tmpLink.absolutePath, linkFile.absolutePath)
        } catch (_: Throwable) {
            runCatching { Os.remove(tmpLink.absolutePath) }
            runCatching { Os.remove(linkFile.absolutePath) }
            if (linkFile.exists()) linkFile.delete()
            Os.symlink(relativeTarget, linkFile.absolutePath)
        }
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

    private fun updateMeta(mutator: (JSONObject) -> Unit): JSONObject = synchronized(metaLock) {
        val obj = readMeta()
        mutator(obj)
        writeMeta(obj)
        obj
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

    private fun containerEntryExists(relPath: String): Boolean {
        val f = File(ubuntuRoot, relPath)
        if (f.exists()) return true
        // Ubuntu alternatives symlinks (e.g. /usr/bin/convert -> /etc/alternatives/convert) target absolute
        // container paths that appear broken from host File.exists(); Os.lstat detects the symlink itself.
        return runCatching { Os.lstat(f.absolutePath) != null }.getOrDefault(false)
    }

    fun detectInstalledToolkits(forceRefresh: Boolean = false): List<String> {
        if (!forceRefresh) {
            cachedInstalledToolkits?.let { return it }
        }
        val found = mutableListOf<String>()
        if (isContainerExtracted()) found.add("core-node")
        // Read usr/bin directory listing once (detects both regular files and container-relative
        // alternatives symlinks like /usr/bin/convert without throwing Os.lstat ErrnoExceptions!).
        val binEntries = File(ubuntuRoot, "usr/bin").list()?.toHashSet() ?: emptySet()
        if (binEntries.contains("python3") && binEntries.contains("pip3")) {
            found.add("python-uv")
        }
        if (binEntries.contains("git") &&
            binEntries.contains("rg") &&
            binEntries.contains("jq") &&
            binEntries.contains("sqlite3") &&
            binEntries.contains("curl")
        ) {
            found.add("dev-git-cli")
        }
        if (binEntries.contains("ffmpeg") &&
            binEntries.contains("pandoc") &&
            (binEntries.contains("convert") ||
                binEntries.contains("convert-im6.q16") ||
                binEntries.contains("magick"))
        ) {
            found.add("media-office")
        }
        val immutable = found.toList()
        cachedInstalledToolkits = immutable
        return immutable
    }

    fun effectiveExecutorMode(meta: JSONObject = readMeta()): String {
        val hasTawc = hasTawcrootBin
        val hasProot = hasProotBin
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
                // Let startEngineSync() check `hasPendingFastOverlayUpdate(activeSlot)` BEFORE syncing
                // overlays so an APK upgrade reliably restarts an adopted stale DSH instance!
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
                    val backupDir = File(ctx.filesDir, "shims.old-${System.currentTimeMillis()}")
                    TarGzExtractor.deleteTreeNoFollow(backupDir)
                    val movedOld = if (shimsRoot.exists()) shimsRoot.renameTo(backupDir) else false
                    if (!stageDir.renameTo(shimsRoot)) {
                        TarGzExtractor.deleteTreeNoFollow(shimsRoot)
                        try {
                            stageDir.copyRecursively(shimsRoot, overwrite = true)
                            TarGzExtractor.deleteTreeNoFollow(stageDir)
                        } catch (t: Throwable) {
                            if (movedOld && !shimsRoot.exists()) backupDir.renameTo(shimsRoot)
                            throw t
                        }
                    }
                    if (movedOld) TarGzExtractor.deleteTreeNoFollow(backupDir)
                    if (wantSha.isNotEmpty()) {
                        updateMeta { it.put("shimsSha256", wantSha) }
                    }
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
                    val backupDir = File(targetSlotDir, "dsh-gbridge.old-${System.currentTimeMillis()}")
                    TarGzExtractor.deleteTreeNoFollow(stageDir)
                    TarGzExtractor.deleteTreeNoFollow(backupDir)
                    bundled.openStream(art.optString("asset"))?.use { ins ->
                        TarGzExtractor.extractStream(ins, stageDir, wantSha, art.optLong("bytes", 0L), freshDir = true)
                    } ?: error("无法读取 ${art.optString("asset")}")
                    writeAndroidCordisPatch(File(stageDir, "cordis.patch.yml"))
                    val movedOld = if (bridgeDir.exists()) bridgeDir.renameTo(backupDir) else false
                    if (!stageDir.renameTo(bridgeDir)) {
                        TarGzExtractor.deleteTreeNoFollow(bridgeDir)
                        try {
                            stageDir.copyRecursively(bridgeDir, overwrite = true)
                            TarGzExtractor.deleteTreeNoFollow(stageDir)
                        } catch (t: Throwable) {
                            if (movedOld && !bridgeDir.exists()) backupDir.renameTo(bridgeDir)
                            throw t
                        }
                    }
                    if (movedOld) TarGzExtractor.deleteTreeNoFollow(backupDir)
                    val bridgeVer = manifest.optString("bridgeVersion", "0.2.0")
                    if (wantSha.isNotEmpty()) {
                        updateMeta {
                            it.put("gbridgeSha256", wantSha)
                            it.put("gbridgeSha256_$activeSlot", wantSha)
                            if (bridgeVer.isNotEmpty()) it.put("bridgeVersion", bridgeVer)
                        }
                    }
                    updated = true
                } else if (!patchFile.exists() || !runCatching { patchFile.readText().contains("grassbag-patch-v2") }.getOrDefault(false)) {
                    writeAndroidCordisPatch(patchFile)
                }
            }
            if (updated) {
                if (ubuntuRoot.exists()) ensureContainerEtcFiles(force = true)
            }
        }
        return updated
    }

    private data class RemoteDownloadEstimate(
        val totalBytes: Long,
        val remainingBytes: Long,
        val hasPartial: Boolean
    )

    private fun isMeteredNetwork(): Boolean {
        return runCatching {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return@runCatching false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val net = cm.activeNetwork ?: return@runCatching false
                val caps = cm.getNetworkCapabilities(net) ?: return@runCatching cm.isActiveNetworkMetered
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) return@runCatching true
                if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) return@runCatching false
            }
            cm.isActiveNetworkMetered
        }.getOrDefault(false)
    }

    private fun estimatePendingRemoteDownload(
        manifest: JSONObject?,
        meta: JSONObject,
        activeSlot: String,
        containerOk: Boolean,
        slotOk: Boolean
    ): RemoteDownloadEstimate {
        if (manifest == null) return RemoteDownloadEstimate(0L, 0L, false)
        val arts = manifest.optJSONObject("artifacts") ?: return RemoteDownloadEstimate(0L, 0L, false)
        val manifestDshVer = manifest.optString("dshVersion", "0.2.2-rc.5")
        val baseArt = arts.optJSONObject("baseRootfs")
        val engineArt = arts.optJSONObject("engineInit")

        val needRootfs = baseArt != null && (
            !containerOk ||
                (baseArt.optString("sha256", "").isNotEmpty() &&
                    baseArt.optString("sha256", "") != meta.optString("baseRootfsSha256", ""))
            )
        val engineSha = engineArt?.optString("sha256", "") ?: ""
        val storedEngineSha = meta.optString("engineInitSha256", "")
        val needEngine = engineArt != null && (
            !slotOk ||
                (!meta.optBoolean("userUpgradedAb", false) && (
                    (manifestDshVer.isNotEmpty() &&
                        meta.optString("bundledDshVersion", "").isNotEmpty() &&
                        manifestDshVer != meta.optString("bundledDshVersion", "")) ||
                        (engineSha.isNotEmpty() &&
                            storedEngineSha.isNotEmpty() &&
                            engineSha != storedEngineSha)
                    ))
            )

        var total = 0L
        var remaining = 0L
        var hasPartial = false

        fun accountArtifact(art: JSONObject?) {
            if (art == null) return
            val assetPath = art.optString("asset", "")
            if (bundled.hasAsset(assetPath)) return // Offline bundled in APK: 0 remote bytes needed
            val expectedBytes = art.optLong("bytes", 0L).coerceAtLeast(0L)
            if (expectedBytes <= 0L) return
            total += expectedBytes
            val filename = art.optString("filename", "").ifBlank { File(assetPath).name }
            val cached = File(runtimeDownloadsDir, filename)
            val part = File(runtimeDownloadsDir, "$filename.part")
            if (cached.isFile && cached.length() == expectedBytes) {
                hasPartial = true
                return
            }
            val partLen = if (part.isFile) part.length().coerceIn(0L, expectedBytes) else 0L
            if (partLen > 0L) hasPartial = true
            remaining += (expectedBytes - partLen).coerceAtLeast(0L)
        }

        if (needRootfs) accountArtifact(baseArt)
        if (needEngine) accountArtifact(engineArt)
        return RemoteDownloadEstimate(total, remaining, hasPartial)
    }

    fun setRuntimeMirrorUrl(rawUrl: String): Map<String, Any?> {
        val clean = rawUrl.trim().trimEnd('/')
        if (clean.isNotEmpty()) {
            val lower = clean.lowercase()
            if (!lower.startsWith("https://") && !lower.startsWith("http://")) {
                return mapOf("ok" to false, "error" to "镜像地址必须以 http:// 或 https:// 开头", "status" to getStatus())
            }
            val parsed = runCatching { URL(clean) }.getOrNull()
            if (parsed == null || parsed.host.isNullOrBlank()) {
                return mapOf("ok" to false, "error" to "镜像地址格式无效，请检查后重试", "status" to getStatus())
            }
        }
        updateMeta { it.put("customRuntimeMirrorUrl", clean) }
        return mapOf("ok" to true, "customRuntimeMirrorUrl" to clean, "status" to getStatus())
    }

    fun cancelBootstrap(): Map<String, Any?> {
        bootstrapCancelRequested.set(true)
        runCatching { activeDownloadConn.getAndSet(null)?.disconnect() }
        return mapOf("ok" to true, "cancelling" to bootstrapRunning.get())
    }

    private fun resolveArtifactDownloadUrls(
        art: JSONObject,
        manifest: JSONObject,
        customMirror: String
    ): List<String> {
        val assetPath = art.optString("asset", "")
        val filename = art.optString("filename", "").ifBlank { File(assetPath).name }
        val repo = manifest.optString("githubRepo", "moduqishi/grassbag").ifBlank { "moduqishi/grassbag" }
        val tag = manifest.optString("runtimeTag", "runtime-arm64-r2").ifBlank { "runtime-arm64-r2" }
        val directUrl = "https://github.com/$repo/releases/download/$tag/$filename"
        val out = LinkedHashSet<String>()

        val cleanCustom = customMirror.trim().trimEnd('/')
        if (cleanCustom.isNotEmpty()) {
            val lower = cleanCustom.lowercase()
            val looksLikeGhProxy = lower.contains("gh-proxy") ||
                lower.contains("ghproxy") ||
                lower.contains("ghfast") ||
                lower.contains("ghp.")
            if (looksLikeGhProxy) {
                out.add("$cleanCustom/$directUrl")
                out.add("$cleanCustom/$filename")
            } else {
                out.add("$cleanCustom/$filename")
                out.add("$cleanCustom/$directUrl")
            }
        }

        val manifestUrls = art.optJSONArray("urls")
        if (manifestUrls != null) {
            for (i in 0 until manifestUrls.length()) {
                val u = manifestUrls.optString(i, "").trim()
                if (u.startsWith("http://") || u.startsWith("https://")) {
                    out.add(u)
                }
            }
        }
        out.add(directUrl)
        return out.toList()
    }

    private fun computeFileSha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(131072)
        FileInputStream(file).use { fis ->
            while (true) {
                val n = fis.read(buf)
                if (n < 0) break
                if (n > 0) md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun openHttpFollowingRedirects(rawUrl: String, rangeStart: Long): HttpURLConnection {
        var current = rawUrl
        for (hop in 0 until 8) {
            if (bootstrapCancelRequested.get()) throw BootstrapCancelledException()
            val url = URL(current)
            val proto = url.protocol.lowercase()
            if (proto != "http" && proto != "https") {
                throw java.io.IOException("不支持的下载协议：$proto")
            }
            val conn = (url.openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = false
                connectTimeout = 15_000
                readTimeout = 30_000
                requestMethod = "GET"
                setRequestProperty("User-Agent", "GrassBag-Android/1.0")
                setRequestProperty("Accept", "application/octet-stream, */*")
                setRequestProperty("Accept-Encoding", "identity")
                if (rangeStart > 0L) {
                    setRequestProperty("Range", "bytes=$rangeStart-")
                }
            }
            activeDownloadConn.set(conn)
            if (bootstrapCancelRequested.get()) {
                runCatching { conn.disconnect() }
                activeDownloadConn.compareAndSet(conn, null)
                throw BootstrapCancelledException()
            }
            val code = try {
                conn.responseCode
            } catch (t: Throwable) {
                runCatching { conn.disconnect() }
                activeDownloadConn.compareAndSet(conn, null)
                throw t
            }
            if (code in listOf(301, 302, 303, 307, 308)) {
                val loc = conn.getHeaderField("Location")?.trim()
                runCatching { conn.disconnect() }
                activeDownloadConn.compareAndSet(conn, null)
                if (loc.isNullOrEmpty()) {
                    throw java.io.IOException("重定向缺少 Location 头 (HTTP $code)")
                }
                val resolved = URL(url, loc)
                val nextProto = resolved.protocol.lowercase()
                if (nextProto != "http" && nextProto != "https") {
                    throw java.io.IOException("重定向目标协议不受支持：$nextProto")
                }
                if (proto == "https" && nextProto != "https") {
                    throw java.io.IOException("拒绝从 HTTPS 降级重定向至非加密协议：$nextProto")
                }
                current = resolved.toString()
                continue
            }
            return conn
        }
        throw java.io.IOException("下载重定向次数过多")
    }

    private fun shortSourceLabel(rawUrl: String): String {
        val host = runCatching { URL(rawUrl).host }.getOrNull()?.lowercase() ?: return "在线源"
        return when {
            host.contains("gh-proxy") -> "国内镜像 1"
            host.contains("ghfast") -> "国内镜像 2"
            host.contains("github.com") -> "GitHub 直连"
            else -> host
        }
    }

    /**
     * Downloads a remote runtime `.gbag` artifact into `runtimeDownloadsDir` with:
     *  - Persistent `.part` HTTP Range resume (206 append / 200 restart / 416 verify-or-reset)
     *  - Automatic mirror failover (custom mirror -> China mirrors -> GitHub direct)
     *  - Immediate rejection of HTML error/proxy pages
     *  - Exact byte-size + SHA-256 verification before atomic rename
     *  - Instant cancellation preserving `.part` for future resume
     */
    private fun downloadArtifactResumable(
        art: JSONObject,
        manifest: JSONObject,
        customMirror: String,
        displayName: String,
        pctStart: Int,
        pctSpan: Int
    ): File {
        runtimeDownloadsDir.mkdirs()
        val assetPath = art.optString("asset", "")
        val filename = art.optString("filename", "").ifBlank { File(assetPath).name }
        val wantSha = art.optString("sha256", "").trim().lowercase()
        val expectedBytes = art.optLong("bytes", 0L).coerceAtLeast(0L)
        val finalFile = File(runtimeDownloadsDir, filename)
        val partFile = File(runtimeDownloadsDir, "$filename.part")

        if (finalFile.isFile) {
            val sizeOk = expectedBytes <= 0L || finalFile.length() == expectedBytes
            if (sizeOk && (wantSha.isEmpty() || computeFileSha256(finalFile).equals(wantSha, ignoreCase = true))) {
                sendProgress(
                    "downloading",
                    pctStart + pctSpan,
                    "$displayName 已存在本地缓存，校验通过",
                    mapOf("canCancel" to true)
                )
                return finalFile
            }
            runCatching { finalFile.delete() }
        }

        val candidates = resolveArtifactDownloadUrls(art, manifest, customMirror)
        if (candidates.isEmpty()) error("清单中未配置 $filename 的下载地址")
        val errors = mutableListOf<String>()

        for ((idx, urlStr) in candidates.withIndex()) {
            if (bootstrapCancelRequested.get()) throw BootstrapCancelledException()
            val label = shortSourceLabel(urlStr)
            var retriedFromZero = false
            while (true) {
                var conn: HttpURLConnection? = null
                var resumedInAttempt = false
                try {
                    if (partFile.isFile && expectedBytes > 0L && partFile.length() > expectedBytes) {
                        runCatching { partFile.delete() }
                    }
                    if (partFile.isFile && expectedBytes > 0L && partFile.length() == expectedBytes) {
                        if (wantSha.isEmpty() || computeFileSha256(partFile).equals(wantSha, ignoreCase = true)) {
                            if (finalFile.exists()) finalFile.delete()
                            if (!partFile.renameTo(finalFile)) {
                                partFile.copyTo(finalFile, overwrite = true)
                                partFile.delete()
                            }
                            return finalFile
                        }
                        runCatching { partFile.delete() }
                    }

                    var resumeFrom = if (partFile.isFile) partFile.length().coerceAtLeast(0L) else 0L
                    resumedInAttempt = resumeFrom > 0L
                appendLog("[runtime] downloading $filename from $label ($urlStr, resume=$resumeFrom)")
                val initialPct = if (expectedBytes > 0L && resumeFrom > 0L) {
                    (pctStart + ((resumeFrom.toDouble() / expectedBytes.toDouble()) * pctSpan).toInt())
                        .coerceIn(pctStart, pctStart + pctSpan)
                } else {
                    pctStart
                }
                sendProgress(
                    "downloading",
                    initialPct,
                    if (resumeFrom > 0L) "正在从 $label 续传 $displayName…" else "正在连接 $label 下载 $displayName…",
                    mapOf("canCancel" to true, "currentMirror" to label),
                    force = true
                )

                conn = openHttpFollowingRedirects(urlStr, resumeFrom)
                var code = conn.responseCode
                if (code == 416 && resumeFrom > 0L) {
                    runCatching { conn.disconnect() }
                    activeDownloadConn.compareAndSet(conn, null)
                    runCatching { partFile.delete() }
                    resumeFrom = 0L
                    conn = openHttpFollowingRedirects(urlStr, 0L)
                    code = conn.responseCode
                }
                if (code != 200 && code != 206) {
                    throw java.io.IOException("HTTP $code")
                }
                val contentType = (conn.contentType ?: "").lowercase()
                if (contentType.contains("text/html")) {
                    throw java.io.IOException("下载源返回了 HTML 错误页")
                }

                val cr = conn.getHeaderField("Content-Range") ?: ""
                val appendMode = if (code == 206 && resumeFrom > 0L) {
                    if (!cr.startsWith("bytes $resumeFrom-")) {
                        throw java.io.IOException("镜像返回无效的 206 Content-Range（期望 bytes $resumeFrom-，实际：$cr）")
                    }
                    val declaredTotal = cr.substringAfter('/', "").trim().toLongOrNull()
                    if (expectedBytes > 0L && declaredTotal != null && declaredTotal != expectedBytes) {
                        throw java.io.IOException("镜像 Content-Range 总大小不匹配 ($declaredTotal != $expectedBytes)")
                    }
                    true
                } else if (code == 206) {
                    throw java.io.IOException("非续传请求意外收到 HTTP 206 ($cr)")
                } else {
                    false
                }
                if (!appendMode && resumeFrom > 0L) {
                    resumeFrom = 0L
                }

                val contentLen = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    conn.contentLengthLong
                } else {
                    conn.contentLength.toLong()
                }
                if (expectedBytes > 0L && contentLen > 0L && (resumeFrom + contentLen) != expectedBytes) {
                    throw java.io.IOException("下载源返回大小异常（${resumeFrom + contentLen} / $expectedBytes 字节）")
                }
                val totalBytes = when {
                    expectedBytes > 0L -> expectedBytes
                    contentLen > 0L -> resumeFrom + contentLen
                    else -> 0L
                }
                val hardMaxBytes = if (expectedBytes > 0L) expectedBytes else 512L * 1024L * 1024L

                val expectGzipHeader = resumeFrom == 0L &&
                    (filename.endsWith(".gbag", ignoreCase = true) ||
                        filename.endsWith(".gz", ignoreCase = true) ||
                        filename.endsWith(".tgz", ignoreCase = true))
                val magicBuf = ByteArray(2)
                var magicCount = 0
                var downloaded = resumeFrom
                var speedBytesPerSec = 0.0
                var windowBytes = 0L
                var windowStartMs = SystemClock.elapsedRealtime()
                val buf = ByteArray(65536)

                conn.inputStream.use { ins ->
                    FileOutputStream(partFile, appendMode).use { fos ->
                        while (true) {
                            if (bootstrapCancelRequested.get()) {
                                fos.flush()
                                throw BootstrapCancelledException()
                            }
                            val n = ins.read(buf)
                            if (n < 0) break
                            if (n > 0) {
                                if (downloaded + n > hardMaxBytes) {
                                    fos.close()
                                    runCatching { partFile.delete() }
                                    throw java.io.IOException("下载数据超出预期大小上限（>${hardMaxBytes / (1024 * 1024)} MB）")
                                }
                                if (expectGzipHeader && magicCount < 2) {
                                    var i = 0
                                    while (i < n && magicCount < 2) {
                                        magicBuf[magicCount++] = buf[i++]
                                    }
                                    if (magicCount == 2) {
                                        val b0 = magicBuf[0].toInt() and 0xFF
                                        val b1 = magicBuf[1].toInt() and 0xFF
                                        if (b0 != 0x1F || b1 != 0x8B) {
                                            fos.close()
                                            runCatching { partFile.delete() }
                                            throw java.io.IOException("下载源返回了损坏或非 gzip 数据（可能为镜像拦截页）")
                                        }
                                    }
                                }
                                fos.write(buf, 0, n)
                                downloaded += n
                                windowBytes += n
                                val nowMs = SystemClock.elapsedRealtime()
                                val dtMs = nowMs - windowStartMs
                                if (dtMs >= 350L) {
                                    val inst = (windowBytes * 1000.0) / dtMs.coerceAtLeast(1L)
                                    speedBytesPerSec = if (speedBytesPerSec <= 0.0) inst else (speedBytesPerSec * 0.65 + inst * 0.35)
                                    windowBytes = 0L
                                    windowStartMs = nowMs
                                    val frac = if (totalBytes > 0L) {
                                        (downloaded.toDouble() / totalBytes.toDouble()).coerceIn(0.0, 1.0)
                                    } else 0.0
                                    val pct = (pctStart + (frac * pctSpan).toInt()).coerceIn(pctStart, pctStart + pctSpan)
                                    val doneMb = String.format("%.1f", downloaded / (1024.0 * 1024.0))
                                    val totMb = if (totalBytes > 0L) String.format("%.1f", totalBytes / (1024.0 * 1024.0)) else "?"
                                    val speedStr = if (speedBytesPerSec >= 1024.0 * 1024.0) {
                                        String.format("%.1f MB/s", speedBytesPerSec / (1024.0 * 1024.0))
                                    } else {
                                        String.format("%.0f KB/s", speedBytesPerSec / 1024.0)
                                    }
                                    sendProgress(
                                        "downloading",
                                        pct,
                                        "正在下载 $displayName（$doneMb / $totMb MB · $speedStr · $label）",
                                        mapOf(
                                            "canCancel" to true,
                                            "downloadedBytes" to downloaded,
                                            "totalBytes" to totalBytes,
                                            "speedBytesPerSec" to speedBytesPerSec.toLong(),
                                            "currentMirror" to label
                                        )
                                    )
                                }
                            }
                        }
                        fos.flush()
                    }
                }

                if (bootstrapCancelRequested.get()) throw BootstrapCancelledException()
                if (expectedBytes > 0L && partFile.length() != expectedBytes) {
                    if (!appendMode && partFile.length() < 65536L) {
                        runCatching { partFile.delete() }
                    }
                    throw java.io.IOException("下载不完整（${partFile.length()} / $expectedBytes 字节）")
                }
                if (wantSha.isNotEmpty()) {
                    sendProgress(
                        "verifying",
                        pctStart + pctSpan,
                        "正在校验 $displayName SHA-256 完整性…",
                        mapOf("canCancel" to false),
                        force = true
                    )
                    val actualSha = computeFileSha256(partFile)
                    if (!actualSha.equals(wantSha, ignoreCase = true)) {
                        runCatching { partFile.delete() }
                        if (resumedInAttempt && !retriedFromZero) {
                            retriedFromZero = true
                            appendLog("[runtime] SHA-256 mismatch after resume from $label; retrying clean from byte 0")
                            sendProgress(
                                "downloading",
                                pctStart,
                                "$displayName 断点校验异常，正在从 $label 重新完整下载…",
                                mapOf("canCancel" to true, "currentMirror" to label),
                                force = true
                            )
                            continue
                        }
                        throw java.io.IOException("SHA-256 校验失败（已丢弃损坏分片）")
                    }
                }
                if (finalFile.exists()) finalFile.delete()
                if (!partFile.renameTo(finalFile)) {
                    partFile.copyTo(finalFile, overwrite = true)
                    partFile.delete()
                }
                appendLog("[runtime] verified $filename (${finalFile.length()} bytes) via $label")
                return finalFile
            } catch (c: BootstrapCancelledException) {
                throw c
            } catch (t: Throwable) {
                if (bootstrapCancelRequested.get()) throw BootstrapCancelledException()
                val msg = "$label: ${t.message ?: t.javaClass.simpleName}"
                errors.add(msg)
                appendLog("[runtime] download mirror failed ($msg)")
                if (idx < candidates.lastIndex) {
                    sendProgress(
                        "downloading",
                        pctStart,
                        "$label 连接失败，自动切换下一个镜像源…",
                        mapOf("canCancel" to true)
                    )
                }
                break
            } finally {
                val c = conn
                if (c != null) {
                    activeDownloadConn.compareAndSet(c, null)
                    runCatching { c.disconnect() }
                }
            }
            }
        }
        error("下载 $displayName 失败（已自动尝试全部下载源：${errors.joinToString("；")}）。请检查网络或前往「本机设置 -> 下载源」配置可用镜像后重试")
    }

    fun getStatus(): Map<String, Any?> {
        val m = readMeta()
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
        val manifest = bundled.loadManifest()
        val hasPayloads = bundled.hasBundledRuntimePayloads()
        val dlEstimate = estimatePendingRemoteDownload(manifest, m, activeSlot, containerOk, slotOk)
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
            "dshVersion" to (lastCapabilitiesDshVersion ?: m.optString("dshVersion", manifest?.optString("dshVersion", "0.2.2-rc.5") ?: "0.2.2-rc.5")),
            "dshPrevVersion" to (if (canRollback) m.optString("dshPrevVersion", "") else ""),
            "bridgeVersion" to m.optString("bridgeVersion", manifest?.optString("bridgeVersion", "0.2.0") ?: "0.2.0"),
            "containerVersion" to m.optString("containerVersion", manifest?.optString("containerVersion", "Ubuntu 24.04.5 · Node 24.22.3") ?: "Ubuntu 24.04.5 · Node 24.22.3"),
            "executorMode" to effectiveExec,
            "configuredExecutorMode" to configuredExec,
            "sdcardMounted" to m.optBoolean("sdcardMounted", false),
            "useSystemProxy" to m.optBoolean("useSystemProxy", false),
            "installedToolkits" to detectInstalledToolkits(),
            "hasTawcroot" to hasTawcrootBin,
            "hasProot" to hasProotBin,
            "hasBundledAssets" to bundled.hasBundledAssets(),
            "hasBundledRuntimePayloads" to hasPayloads,
            "runtimeDelivery" to (if (hasPayloads) "bundled" else "remote"),
            "runtimeReleaseTag" to (manifest?.optString("runtimeTag", "") ?: ""),
            "runtimeTotalBytes" to dlEstimate.totalBytes,
            "runtimeDownloadBytes" to dlEstimate.remainingBytes,
            "hasPartialDownload" to dlEstimate.hasPartial,
            "isMeteredNetwork" to isMeteredNetwork(),
            "customRuntimeMirrorUrl" to m.optString("customRuntimeMirrorUrl", ""),
            "bootstrapActive" to bootstrapRunning.get(),
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

    private fun enqueueLocalTermData(tabId: String, chunk: String, expectedSession: ShellSession? = null) {
        var shouldSchedule = false
        synchronized(termPendingLock) {
            if (expectedSession != null && shells[tabId] !== expectedSession) return
            val sb = termPendingBuffers.getOrPut(tabId) { StringBuilder(chunk.length.coerceAtLeast(256)) }
            sb.append(chunk)
            if (sb.length >= 64 * 1024) {
                val data = sb.toString()
                sb.setLength(0)
                termPendingBuffers.remove(tabId)
                // Emit inside termPendingLock (Handler.post is non-blocking) so large bursts
                // never overtake an earlier coalesced flush on mainHandler!
                emit("local_term_data", mapOf("tabId" to tabId, "data" to data))
            } else if (!termFlushScheduled) {
                termFlushScheduled = true
                shouldSchedule = true
            }
        }
        if (shouldSchedule) {
            runCatching {
                coalesceScheduler.schedule({ flushAllLocalTermData() }, 16, TimeUnit.MILLISECONDS)
            }
        }
    }

    private fun flushLocalTermDataFor(tabId: String, expectedSession: ShellSession? = null, exitCode: Int? = null) {
        synchronized(termPendingLock) {
            val stillOwner = expectedSession == null || shells[tabId] === expectedSession
            val data = if (stillOwner) {
                termPendingBuffers.remove(tabId)?.takeIf { it.isNotEmpty() }?.toString()
            } else {
                null
            }
            if (data != null) {
                emit("local_term_data", mapOf("tabId" to tabId, "data" to data))
            }
            if (exitCode != null && expectedSession != null && shells.remove(tabId, expectedSession)) {
                emit("local_term_exit", mapOf("tabId" to tabId, "exitCode" to exitCode))
            }
        }
    }

    private fun flushAllLocalTermData() {
        synchronized(termPendingLock) {
            termFlushScheduled = false
            if (termPendingBuffers.isEmpty()) return
            for ((tid, sb) in termPendingBuffers) {
                if (sb.isNotEmpty() && shells.containsKey(tid)) {
                    emit("local_term_data", mapOf("tabId" to tid, "data" to sb.toString()))
                }
            }
            termPendingBuffers.clear()
        }
    }

    fun bootstrapRuntime(alreadyAcquiredLock: Boolean = false, done: (Map<String, Any?>) -> Unit) {
        if (!alreadyAcquiredLock && upgradeInProgress.get()) {
            done(mapOf("ok" to false, "error" to "当前有版本升级或回滚任务在进行中，请稍候完成", "status" to getStatus()))
            return
        }
        if (!alreadyAcquiredLock && activeToolkitInstalls.get() > 0) {
            done(mapOf("ok" to false, "error" to "当前有工具包正在安装，请等待完成后重试", "status" to getStatus()))
            return
        }
        if (!alreadyAcquiredLock && !bootstrapRunning.compareAndSet(false, true)) {
            done(mapOf("ok" to false, "error" to "本机环境正在下载或部署中，请稍候…", "status" to getStatus()))
            return
        }
        bootstrapCancelRequested.set(false)
        worker.execute {
            val extractedOk: Boolean
            var bootstrapErr: String? = null
            var bootstrapCancelled = false
            var startedFgForBootstrap = false
            var overlaysUpdated = false
            try {
                // Pre-stop any in-flight/running engine OUTSIDE bootstrapLock when rootfs or engine slot
                // needs re-deployment so stopEngineSync never waits on startEngineSync while holding bootstrapLock!
                val preCheckManifest = bundled.loadManifest()
                val preCheckArts = preCheckManifest?.optJSONObject("artifacts")
                val preCheckMeta = readMeta()
                val preCheckSlot = preCheckMeta.optString("activeSlot", "slot-a")
                val preBaseArt = preCheckArts?.optJSONObject("baseRootfs")
                val preEngArt = preCheckArts?.optJSONObject("engineInit")
                val preNeedRootfs = preBaseArt != null && (
                    !isContainerExtracted() ||
                        (preBaseArt.optString("sha256", "").isNotEmpty() &&
                            preBaseArt.optString("sha256", "") != preCheckMeta.optString("baseRootfsSha256", ""))
                    )
                val preEngSha = preEngArt?.optString("sha256", "") ?: ""
                val preStoredEngSha = preCheckMeta.optString("engineInitSha256", "")
                val preManifestVer = preCheckManifest?.optString("dshVersion", "0.2.2-rc.5") ?: "0.2.2-rc.5"
                val preNeedEngine = preEngArt != null && (
                    !isSlotExtracted(preCheckSlot) ||
                        (!preCheckMeta.optBoolean("userUpgradedAb", false) && (
                            (preManifestVer.isNotEmpty() &&
                                preCheckMeta.optString("bundledDshVersion", "").isNotEmpty() &&
                                preManifestVer != preCheckMeta.optString("bundledDshVersion", "")) ||
                                (preEngSha.isNotEmpty() &&
                                    preStoredEngSha.isNotEmpty() &&
                                    preEngSha != preStoredEngSha)
                            ))
                    )
                if (preNeedRootfs || preNeedEngine) {
                    stopEngineSync(keepForegroundService = true)
                }
                synchronized(bootstrapLock) {
                    extractedOk = try {
                        sendProgress("layout", 2, "检查设备架构、网络与存储空间…", mapOf("canCancel" to true))
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
                        val customMirror = st.optString("customRuntimeMirrorUrl", "")

                        val manifestDshVer = manifest.optString("dshVersion", "0.2.2-rc.5")
                        val baseArt = arts.optJSONObject("baseRootfs")
                        val engineArt = arts.optJSONObject("engineInit")
                        val needRootfsCheck = baseArt != null && (
                            !isContainerExtracted() ||
                                (baseArt.optString("sha256", "").isNotEmpty() &&
                                    baseArt.optString("sha256", "") != st.optString("baseRootfsSha256", ""))
                            )
                        val engineSha = engineArt?.optString("sha256", "") ?: ""
                        val storedEngineSha = st.optString("engineInitSha256", "")
                        val needEngineCheck = engineArt != null && (
                            !isSlotExtracted(activeSlot) ||
                                (!st.optBoolean("userUpgradedAb", false) && (
                                    (manifestDshVer.isNotEmpty() &&
                                        st.optString("bundledDshVersion", "").isNotEmpty() &&
                                        manifestDshVer != st.optString("bundledDshVersion", "")) ||
                                        (engineSha.isNotEmpty() &&
                                            storedEngineSha.isNotEmpty() &&
                                            engineSha != storedEngineSha)
                                    ))
                            )

                        val rootfsIsBundled = baseArt != null && bundled.hasAsset(baseArt.optString("asset", ""))
                        val engineIsBundled = engineArt != null && bundled.hasAsset(engineArt.optString("asset", ""))
                        val needsRemoteDownload =
                            (needRootfsCheck && !rootfsIsBundled) || (needEngineCheck && !engineIsBundled)

                        if (needRootfsCheck || needEngineCheck) {
                            val availBytes = runCatching { StatFs(ctx.filesDir.absolutePath).availableBytes }.getOrDefault(Long.MAX_VALUE)
                            val rootfsMarginMb = if (needRootfsCheck) {
                                if (ubuntuRoot.exists() && isContainerExtracted()) 180L else 360L
                            } else 0L
                            val engineMarginMb = if (needEngineCheck) {
                                if (targetSlotDir.exists() && isSlotExtracted(activeSlot)) 260L else 760L
                            } else 0L
                            val downloadScratchMb = if (needsRemoteDownload) 130L else 0L
                            val requiredBytes = (rootfsMarginMb + engineMarginMb + downloadScratchMb) * 1024L * 1024L
                            if (availBytes < requiredBytes) {
                                val availMb = availBytes / (1024L * 1024L)
                                val reqMb = requiredBytes / (1024L * 1024L)
                                error("手机可用存储空间不足（当前仅剩 ${availMb} MB，至少需要 ${reqMb} MB 用于下载并部署 Ubuntu + DSH 运行环境）")
                            }
                        }

                        if (bootstrapCancelRequested.get()) throw BootstrapCancelledException()

                        GrassBagEngineService.startOrUpdate(
                            ctx,
                            if (needsRemoteDownload) "正在下载并部署 GrassBag 运行环境" else "正在初始化 GrassBag 本机容器",
                            if (needsRemoteDownload) "断点续传下载 Ubuntu + Node 24 + DSH 引擎，请保持应用运行…" else "解压 Ubuntu + Node 24 + DSH 引擎，请保持应用运行…",
                            wakeLockMs = 15 * 60 * 1000L
                        )
                        startedFgForBootstrap = true

                        // 1. Shims & droid-* wrappers (always bundled ~156KB inside APK; atomic swap so live engine isn't broken mid-read)
                        arts.optJSONObject("shims")?.let { art ->
                            val wantSha = art.optString("sha256", "")
                            val prevSha = st.optString("shimsSha256", "")
                            val needShims = !File(shimsRoot, "android-shim.mjs").exists() ||
                                !File(shimsRoot, "pty-bridge.mjs").exists() ||
                                (wantSha.isNotEmpty() && wantSha != prevSha)
                            if (needShims) {
                                sendProgress("shims", 5, "部署 android-shim、CA 证书与 droid-* 工具链…")
                                val stageDir = File(ctx.filesDir, "shims.stage-${System.currentTimeMillis()}")
                                TarGzExtractor.deleteTreeNoFollow(stageDir)
                                bundled.openStream(art.optString("asset"))?.use { ins ->
                                    TarGzExtractor.extractStream(
                                        compressedStream = ins,
                                        destDir = stageDir,
                                        expectedSha256 = wantSha,
                                        totalCompressedBytes = art.optLong("bytes", 0L),
                                        freshDir = true
                                    )
                                } ?: error("无法读取 ${art.optString("asset")}")
                                val backupDir = File(ctx.filesDir, "shims.old-${System.currentTimeMillis()}")
                                TarGzExtractor.deleteTreeNoFollow(backupDir)
                                val movedOld = if (shimsRoot.exists()) shimsRoot.renameTo(backupDir) else false
                                if (!stageDir.renameTo(shimsRoot)) {
                                    TarGzExtractor.deleteTreeNoFollow(shimsRoot)
                                    try {
                                        stageDir.copyRecursively(shimsRoot, overwrite = true)
                                        TarGzExtractor.deleteTreeNoFollow(stageDir)
                                    } catch (t: Throwable) {
                                        if (movedOld && !shimsRoot.exists()) backupDir.renameTo(shimsRoot)
                                        throw t
                                    }
                                }
                                if (movedOld) TarGzExtractor.deleteTreeNoFollow(backupDir)
                                overlaysUpdated = true
                                if (wantSha.isNotEmpty()) {
                                    st.put("shimsSha256", wantSha)
                                    updateMeta { it.put("shimsSha256", wantSha) }
                                }
                            } else {
                                sendProgress("shims", 5, "android-shim 与 droid-* 工具链已是最新")
                            }
                        }

                        if (needRootfsCheck || needEngineCheck) {
                            stopEngineSync(keepForegroundService = true, cancelStartup = false)
                        }

                        // 2 & 3. Deploy Ubuntu + Node 24 rootfs and @deepseek-ai/dsh engine slot.
                        // Fast path: when BOTH payloads are bundled offline in APK, extract in parallel across 2 CPU cores.
                        // Lean APK path: sequentially download (resumable HTTP Range + mirror failover + SHA-256)
                        // -> extract -> immediately delete archive to minimize peak storage and allow clean resume!
                        if (needRootfsCheck && needEngineCheck && rootfsIsBundled && engineIsBundled && baseArt != null && engineArt != null) {
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
                                val pct = 10 + ((doneBytes * 74L) / combinedTotal).toInt().coerceIn(0, 74)
                                sendProgress(
                                    "rootfs",
                                    pct,
                                    "并行解压 Ubuntu + Node 24 与 DSH $manifestDshVer (${doneBytes / (1024 * 1024)} / ${combinedTotal / (1024 * 1024)} MB)…"
                                )
                            }

                            sendProgress("rootfs", 10, "正在并行部署 Ubuntu + Node 24 与 DSH $manifestDshVer…", mapOf("canCancel" to false), force = true)
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
                                    val total = art.optLong("bytes", 75_000_000L).coerceAtLeast(1L)
                                    var downloadedFile: File? = null
                                    val openRootfsStream: () -> InputStream = if (rootfsIsBundled) {
                                        { bundled.openStream(art.optString("asset")) ?: error("无法读取 ${art.optString("asset")}") }
                                    } else {
                                        val file = downloadArtifactResumable(
                                            art = art,
                                            manifest = manifest,
                                            customMirror = customMirror,
                                            displayName = "Ubuntu + Node 24 容器",
                                            pctStart = 6,
                                            pctSpan = 28
                                        )
                                        downloadedFile = file
                                        { FileInputStream(file) }
                                    }
                                    if (bootstrapCancelRequested.get()) throw BootstrapCancelledException()
                                    val extractBase = if (rootfsIsBundled) 10 else 34
                                    val extractSpan = if (rootfsIsBundled) 38 else 12
                                    sendProgress("rootfs", extractBase, "正在隔离目录解压并校验 Ubuntu 24.04.5 + Node 24.22.3 ARM64…", mapOf("canCancel" to false), force = true)
                                    val requiredRootfsSpace = maxOf(total * 3L, 260L * 1024L * 1024L)
                                    val availRootfsSpace = runCatching { StatFs(containersRoot.absolutePath).availableBytes }.getOrDefault(Long.MAX_VALUE)
                                    if (availRootfsSpace < requiredRootfsSpace) {
                                        error("磁盘可用空间不足（需要至少 ${requiredRootfsSpace / (1024 * 1024)} MB，当前剩余 ${availRootfsSpace / (1024 * 1024)} MB），已保留现有容器环境")
                                    }
                                    val stageRoot = File(containersRoot, "${ubuntuRoot.name}.stage-${System.currentTimeMillis()}")
                                    val oldRootBackup = File(containersRoot, "${ubuntuRoot.name}.old-${System.currentTimeMillis()}")
                                    TarGzExtractor.deleteTreeNoFollow(stageRoot)
                                    TarGzExtractor.deleteTreeNoFollow(oldRootBackup)
                                    stageRoot.mkdirs()
                                    val extractingFlag = File(stageRoot, ".extracting").apply { writeText("1") }
                                    try {
                                        openRootfsStream().use { ins ->
                                            TarGzExtractor.extractStream(
                                                compressedStream = ins,
                                                destDir = stageRoot,
                                                expectedSha256 = wantSha,
                                                totalCompressedBytes = total,
                                                freshDir = true
                                            ) { read, tot ->
                                                val pct = if (tot > 0) extractBase + ((read * extractSpan) / tot).toInt().coerceIn(0, extractSpan) else extractBase + extractSpan / 2
                                                sendProgress("rootfs", pct, "正在解压 Ubuntu + Node 24 (${read / (1024 * 1024)} / ${tot / (1024 * 1024)} MB)…")
                                            }
                                        }
                                        val hasShellOrNode = File(stageRoot, "bin/sh").exists() ||
                                            File(stageRoot, "usr/bin/sh").exists() ||
                                            File(stageRoot, "usr/local/bin/node").exists()
                                        if (!hasShellOrNode) {
                                            error("新根文件系统缺少关键可执行文件（bin/sh 或 node），已中止激活并保留原环境")
                                        }
                                        extractingFlag.delete()
                                        File(stageRoot, ".extract-complete").writeText(wantSha.ifBlank { "ok" })
                                        // Atomic swap: move old rootfs aside only AFTER staging extraction & verification succeeded!
                                        val movedOld = if (ubuntuRoot.exists()) ubuntuRoot.renameTo(oldRootBackup) else false
                                        if (ubuntuRoot.exists() && !movedOld) {
                                            error("无法原子切换旧根文件系统目录，已保留原环境")
                                        }
                                        if (!stageRoot.renameTo(ubuntuRoot)) {
                                            if (movedOld && oldRootBackup.exists() && !ubuntuRoot.exists()) {
                                                oldRootBackup.renameTo(ubuntuRoot)
                                            }
                                            error("激活新根文件系统失败，已自动回退到原环境")
                                        }
                                        if (movedOld) {
                                            runCatching { TarGzExtractor.deleteTreeNoFollow(oldRootBackup) }
                                        }
                                    } catch (t: Throwable) {
                                        runCatching { TarGzExtractor.deleteTreeNoFollow(stageRoot) }
                                        if (!ubuntuRoot.exists() && oldRootBackup.exists()) {
                                            runCatching { oldRootBackup.renameTo(ubuntuRoot) }
                                        }
                                        throw t
                                    }
                                    // Immediately reclaim compressed archive (~72MB) once extracted & activated!
                                    downloadedFile?.let { runCatching { it.delete() } }
                                    etcPrepared = false
                                    ptySupportedCache = null
                                    if (wantSha.isNotEmpty()) {
                                        st.put("baseRootfsSha256", wantSha)
                                        updateMeta { it.put("baseRootfsSha256", wantSha) }
                                    }
                                } else {
                                    sendProgress("rootfs", 46, "Ubuntu 24.04.5 + Node 24 容器已就绪，跳过下载")
                                    if (wantSha.isNotEmpty()) st.put("baseRootfsSha256", wantSha)
                                }
                            }

                            engineArt?.let { art ->
                                val wantSha = art.optString("sha256", "")
                                if (needEngineCheck) {
                                    val total = art.optLong("bytes", 116_000_000L).coerceAtLeast(1L)
                                    var downloadedFile: File? = null
                                    val openEngineStream: () -> InputStream = if (engineIsBundled) {
                                        { bundled.openStream(art.optString("asset")) ?: error("无法读取 ${art.optString("asset")}") }
                                    } else {
                                        val file = downloadArtifactResumable(
                                            art = art,
                                            manifest = manifest,
                                            customMirror = customMirror,
                                            displayName = "DSH $manifestDshVer 引擎",
                                            pctStart = 46,
                                            pctSpan = 34
                                        )
                                        downloadedFile = file
                                        { FileInputStream(file) }
                                    }
                                    if (bootstrapCancelRequested.get()) throw BootstrapCancelledException()
                                    val extractBase = if (engineIsBundled) 50 else 80
                                    val extractSpan = if (engineIsBundled) 34 else 9
                                    sendProgress("engine", extractBase, "正在隔离目录解压并校验真实 DSH $manifestDshVer…", mapOf("canCancel" to false), force = true)
                                    val requiredEngineSpace = maxOf(total * 3L, 320L * 1024L * 1024L)
                                    val availEngineSpace = runCatching { StatFs(slotsRoot.absolutePath).availableBytes }.getOrDefault(Long.MAX_VALUE)
                                    if (availEngineSpace < requiredEngineSpace) {
                                        error("磁盘可用空间不足（需要至少 ${requiredEngineSpace / (1024 * 1024)} MB，当前剩余 ${availEngineSpace / (1024 * 1024)} MB），已保留现有引擎槽位")
                                    }
                                    val stageSlot = File(slotsRoot, "${targetSlotDir.name}.stage-${System.currentTimeMillis()}")
                                    val oldSlotBackup = File(slotsRoot, "${targetSlotDir.name}.old-${System.currentTimeMillis()}")
                                    TarGzExtractor.deleteTreeNoFollow(stageSlot)
                                    TarGzExtractor.deleteTreeNoFollow(oldSlotBackup)
                                    stageSlot.mkdirs()
                                    val extractingFlag = File(stageSlot, ".extracting").apply { writeText("1") }
                                    try {
                                        openEngineStream().use { ins ->
                                            TarGzExtractor.extractStream(
                                                compressedStream = ins,
                                                destDir = stageSlot,
                                                expectedSha256 = wantSha,
                                                totalCompressedBytes = total,
                                                freshDir = true
                                            ) { read, tot ->
                                                val pct = if (tot > 0) extractBase + ((read * extractSpan) / tot).toInt().coerceIn(0, extractSpan) else extractBase + extractSpan / 2
                                                sendProgress("engine", pct, "正在部署 DSH 引擎 (${read / (1024 * 1024)} / ${tot / (1024 * 1024)} MB)…")
                                            }
                                        }
                                        val hasDshPayload = File(stageSlot, "node_modules/@deepseek-ai/dsh").exists() ||
                                            File(stageSlot, "package.json").exists()
                                        if (!hasDshPayload) {
                                            error("新引擎槽位缺少 DSH 核心文件，已中止激活并保留现有槽位")
                                        }
                                        extractingFlag.delete()
                                        File(stageSlot, ".extract-complete").writeText(wantSha.ifBlank { "ok" })
                                        val movedOld = if (targetSlotDir.exists()) targetSlotDir.renameTo(oldSlotBackup) else false
                                        if (targetSlotDir.exists() && !movedOld) {
                                            error("无法原子切换旧引擎槽位目录，已保留原槽位")
                                        }
                                        if (!stageSlot.renameTo(targetSlotDir)) {
                                            if (movedOld && oldSlotBackup.exists() && !targetSlotDir.exists()) {
                                                oldSlotBackup.renameTo(targetSlotDir)
                                            }
                                            error("激活新引擎槽位失败，已自动回退到原槽位")
                                        }
                                        if (movedOld) {
                                            runCatching { TarGzExtractor.deleteTreeNoFollow(oldSlotBackup) }
                                        }
                                    } catch (t: Throwable) {
                                        runCatching { TarGzExtractor.deleteTreeNoFollow(stageSlot) }
                                        if (!targetSlotDir.exists() && oldSlotBackup.exists()) {
                                            runCatching { oldSlotBackup.renameTo(targetSlotDir) }
                                        }
                                        throw t
                                    }
                                    // Immediately reclaim compressed archive (~116MB) once extracted & activated!
                                    downloadedFile?.let { runCatching { it.delete() } }
                                    if (wantSha.isNotEmpty()) {
                                        st.put("engineInitSha256", wantSha)
                                        updateMeta { it.put("engineInitSha256", wantSha) }
                                    }
                                    st.put("bundledDshVersion", manifestDshVer)
                                    st.put("dshVersion", manifestDshVer)
                                } else {
                                    sendProgress("engine", 88, "DSH 引擎槽位 $activeSlot 核心已就绪")
                                    if (st.optString("bundledDshVersion", "").isEmpty()) {
                                        st.put("bundledDshVersion", manifestDshVer)
                                    }
                                }
                            }
                        }

                        updateRelativeSymlink(File(containersRoot, "current"), ubuntuRoot.name)
                        ensureContainerEtcFiles(force = true)

                        // 3b. Always apply tiny ~102KB APK-bundled dsh-gbridge overlay on top of target slot
                        arts.optJSONObject("gbridge")?.let { art ->
                            val wantSha = art.optString("sha256", "")
                            val prevSha = st.optString("gbridgeSha256_$activeSlot", st.optString("gbridgeSha256", ""))
                            val bridgeDir = File(targetSlotDir, "dsh-gbridge")
                            val needBridge = needEngineCheck ||
                                !File(bridgeDir, "lib/index.js").exists() ||
                                (wantSha.isNotEmpty() && wantSha != prevSha)
                            if (needBridge) {
                                sendProgress("gbridge", 90, "增量更新零侵入桥 dsh-gbridge…")
                                val stageBridge = File(targetSlotDir, "dsh-gbridge.stage-${System.currentTimeMillis()}")
                                TarGzExtractor.deleteTreeNoFollow(stageBridge)
                                bundled.openStream(art.optString("asset"))?.use { ins ->
                                    TarGzExtractor.extractStream(ins, stageBridge, wantSha, art.optLong("bytes", 0L), freshDir = true)
                                } ?: error("无法读取 ${art.optString("asset")}")
                                val backupBridge = File(targetSlotDir, "dsh-gbridge.old-${System.currentTimeMillis()}")
                                TarGzExtractor.deleteTreeNoFollow(backupBridge)
                                val movedOld = if (bridgeDir.exists()) bridgeDir.renameTo(backupBridge) else false
                                if (!stageBridge.renameTo(bridgeDir)) {
                                    TarGzExtractor.deleteTreeNoFollow(bridgeDir)
                                    try {
                                        stageBridge.copyRecursively(bridgeDir, overwrite = true)
                                        TarGzExtractor.deleteTreeNoFollow(stageBridge)
                                    } catch (t: Throwable) {
                                        if (movedOld && !bridgeDir.exists()) backupBridge.renameTo(bridgeDir)
                                        throw t
                                    }
                                }
                                if (movedOld) TarGzExtractor.deleteTreeNoFollow(backupBridge)
                                overlaysUpdated = true
                                if (wantSha.isNotEmpty()) {
                                    st.put("gbridgeSha256", wantSha)
                                    st.put("gbridgeSha256_$activeSlot", wantSha)
                                }
                            }
                        }

                        updateRelativeSymlink(File(slotsRoot, "current"), activeSlot)
                        updateRelativeSymlink(File(slotsRoot, "lkg"), st.optString("lkgSlot", activeSlot))

                        writeAndroidCordisPatch(File(targetSlotDir, "dsh-gbridge/cordis.patch.yml"))

                        sendProgress("daemons", 91, "启动 0600 UDS 安全守护进程与本机 DSH 引擎…")
                        phoneDaemon.start()
                        droidDaemon.start()

                        updateMeta { fresh ->
                            fresh.put("initialized", true)
                            fresh.put("activeSlot", activeSlot)
                            fresh.put("lkgSlot", fresh.optString("lkgSlot", st.optString("lkgSlot", activeSlot)))
                            fresh.put("containerVersion", manifest.optString("containerVersion", "Ubuntu 24.04.5 · Node 24.22.3"))
                            val shimsSha = st.optString("shimsSha256", "")
                            if (shimsSha.isNotEmpty()) fresh.put("shimsSha256", shimsSha)
                            val baseSha = st.optString("baseRootfsSha256", "")
                            if (baseSha.isNotEmpty()) fresh.put("baseRootfsSha256", baseSha)
                            val engSha = st.optString("engineInitSha256", "")
                            if (engSha.isNotEmpty()) fresh.put("engineInitSha256", engSha)
                            val gbSha = st.optString("gbridgeSha256", "")
                            if (gbSha.isNotEmpty()) fresh.put("gbridgeSha256", gbSha)
                            val gbSlotSha = st.optString("gbridgeSha256_$activeSlot", "")
                            if (gbSlotSha.isNotEmpty()) fresh.put("gbridgeSha256_$activeSlot", gbSlotSha)
                            val bundledVer = st.optString("bundledDshVersion", "")
                            if (bundledVer.isNotEmpty()) fresh.put("bundledDshVersion", bundledVer)
                            val dshVer = st.optString("dshVersion", "")
                            if (dshVer.isNotEmpty()) {
                                fresh.put("dshVersion", dshVer)
                            } else if (fresh.optString("dshVersion", "").isEmpty()) {
                                fresh.put("dshVersion", manifestDshVer)
                            }
                            fresh.put("bridgeVersion", manifest.optString("bridgeVersion", "0.2.0"))
                            if (!fresh.optBoolean("executorModePinned", false)) {
                                fresh.put("executorMode", detectExecutor())
                            }
                        }
                        lastEngineError = null
                        true
                    } catch (c: BootstrapCancelledException) {
                        bootstrapCancelled = true
                        if ((startedFgForBootstrap || alreadyAcquiredLock) &&
                            !isEngineAlive() &&
                            activeToolkitInstalls.get() <= 0 &&
                            !upgradeInProgress.get()
                        ) {
                            GrassBagEngineService.stop(ctx)
                        }
                        sendProgress("cancelled", 0, c.message ?: "已暂停下载，断点进度已保留")
                        false
                    } catch (err: Throwable) {
                        Log.e(TAG, "bootstrapRuntime failed", err)
                        bootstrapErr = err.message ?: "bootstrap_failed"
                        lastEngineError = bootstrapErr
                        if ((startedFgForBootstrap || alreadyAcquiredLock) &&
                            !isEngineAlive() &&
                            activeToolkitInstalls.get() <= 0 &&
                            !upgradeInProgress.get()
                        ) {
                            GrassBagEngineService.stop(ctx)
                        }
                        sendProgress("error", 0, "本机环境部署失败：${bootstrapErr}")
                        false
                    }
                }

                if (!extractedOk) {
                    done(
                        if (bootstrapCancelled) {
                            mapOf("ok" to false, "cancelled" to true, "status" to getStatus())
                        } else {
                            mapOf("ok" to false, "error" to (bootstrapErr ?: "bootstrap_failed"), "status" to getStatus())
                        }
                    )
                    return@execute
                }
                cachedInstalledToolkits = null

                // Release bootstrapLock BEFORE starting DSH engine so status/start calls never stall!
                if (bootstrapCancelRequested.get()) {
                    if ((startedFgForBootstrap || alreadyAcquiredLock) &&
                        !isEngineAlive() &&
                        activeToolkitInstalls.get() <= 0 &&
                        !upgradeInProgress.get()
                    ) {
                        GrassBagEngineService.stop(ctx)
                    }
                    sendProgress("cancelled", 0, "已暂停部署，容器环境已保留", mapOf("canCancel" to false), force = true)
                    done(mapOf("ok" to false, "cancelled" to true, "status" to getStatus()))
                    return@execute
                }
                if (overlaysUpdated && isEngineAlive()) {
                    appendLog("[runtime] overlays updated during bootstrap; restarting DSH engine to apply updates...")
                    stopEngineSync(keepForegroundService = true, emitStoppedEvent = false)
                }
                sendProgress("engine_boot", 92, "正在高速拉起本机 DSH 引擎（首次编译缓存约需 6-15 秒）…", mapOf("canCancel" to false), force = true)
                val engineRes = try {
                    startEngineSync()
                } catch (t: Throwable) {
                    mapOf("ok" to false, "error" to (t.message ?: t.javaClass.simpleName))
                }
                val ok = engineRes["ok"] == true
                if (ok) {
                    val bootMs = (engineRes["bootMs"] as? Number)?.toLong() ?: 0L
                    val execTag = engineRes["executorMode"]?.toString() ?: "tawcroot"
                    val sec = if (bootMs > 0) String.format("%.1fs", bootMs / 1000.0) else ""
                    sendProgress("ready", 100, "本机 Ubuntu + Node 24 + DSH 引擎已就绪 ($execTag${if (sec.isNotEmpty()) " · $sec" else ""})")
                    done(mapOf("ok" to true, "engineStarted" to true, "bootMs" to bootMs, "status" to getStatus()))
                } else {
                    val errStr = engineRes["error"]?.toString() ?: "engine_start_failed"
                    if (startedFgForBootstrap && !isEngineAlive() && activeToolkitInstalls.get() <= 0) {
                        GrassBagEngineService.stop(ctx)
                    }
                    sendProgress("error", 0, "容器已部署，但 DSH 启动失败：$errStr")
                    done(mapOf("ok" to false, "engineStarted" to false, "error" to errStr, "status" to getStatus()))
                }
            } finally {
                bootstrapRunning.set(false)
                bootstrapCancelRequested.set(false)
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
            // Keep FGS alive across stop -> start so Android 12+ never rejects re-foregrounding if backgrounded!
            stopEngineSync(keepForegroundService = true, emitStoppedEvent = false)
            val res = startEngineSync()
            done(res)
        }
    }

    fun stopEngine(): Map<String, Any?> {
        stopEngineSync()
        return mapOf("ok" to true, "status" to getStatus())
    }

    private fun extractProcessPid(proc: Process): Int? {
        Regex("""pid=(\d+)""").find(proc.toString())?.groupValues?.getOrNull(1)?.toIntOrNull()?.let {
            if (it > 1) return it
        }
        runCatching {
            val m = proc.javaClass.getMethod("pid")
            (m.invoke(proc) as? Number)?.toInt()
        }.getOrNull()?.let { if (it > 1) return it }
        return runCatching {
            val field = proc.javaClass.getDeclaredField("pid")
            field.isAccessible = true
            (field.get(proc) as? Number)?.toInt()
        }.getOrNull()
    }

    private fun killProcessGroupSafe(pid: Int) {
        if (pid <= 1 || pid == android.os.Process.myPid()) return
        val stat = readProcStat(pid)
        val isZombie = stat?.first == "Z" || stat?.first == "X"
        if (!isZombie && !isValidEnginePid(pid)) return
        val myPgid = readProcStat(android.os.Process.myPid())?.second ?: -1
        val targetPgid = stat?.second ?: -1
        val canKillGroup = targetPgid > 1 && targetPgid != myPgid
        if (canKillGroup) {
            runCatching { Os.kill(-targetPgid, 15) } // SIGTERM whole container session/process group
        }
        if (!isZombie) {
            runCatching { Os.kill(pid, 15) }
        }
        runCatching { Thread.sleep(150) }
        if (canKillGroup) {
            runCatching { Os.kill(-targetPgid, 9) } // SIGKILL remaining children (bash/MCP/dev servers)
        }
        if (!isZombie) {
            runCatching { Os.kill(pid, 9) }
        }
    }

    /**
     * Kills a spawned subprocess AND its entire process group (`-pgid`) so timed-out `npm`/`apt-get`
     * runs or closed terminal tabs never leave orphan grandchild processes holding ports or pipe FDs.
     */
    private fun killSubprocessGroup(proc: Process, graceMs: Long = 200L) {
        val pid = extractProcessPid(proc)
        val myPgid = readProcStat(android.os.Process.myPid())?.second ?: -1
        val targetPgid = if (pid != null && pid > 1) readProcStat(pid)?.second ?: -1 else -1
        val canKillGroup = targetPgid > 1 && targetPgid != myPgid
        if (canKillGroup) {
            runCatching { Os.kill(-targetPgid, 15) }
        }
        runCatching { proc.destroy() }
        if (graceMs > 0L) {
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    proc.waitFor(graceMs, TimeUnit.MILLISECONDS)
                } else {
                    Thread.sleep(graceMs)
                }
            }
        }
        if (canKillGroup) {
            runCatching { Os.kill(-targetPgid, 9) }
        }
        runCatching { proc.destroyForcibly() }
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

    private fun stopEngineSync(
        keepForegroundService: Boolean = false,
        emitStoppedEvent: Boolean = true,
        cancelStartup: Boolean = true,
        nextState: String = "stopped"
    ) {
        if (cancelStartup) {
            autoRecoverPending.set(false)
            stopEpoch.incrementAndGet()
            synchronized(readinessSignal) { readinessSignal.notifyAll() }
            val inFlightLatch = synchronized(engineLock) { activeStartupLatch }
            if (inFlightLatch != null) {
                runCatching { inFlightLatch.await(2500, TimeUnit.MILLISECONDS) }
            }
        }
        synchronized(engineLock) {
            dshProcess?.let { proc ->
                appendLog("[runtime] stopping DSH engine...")
                // Terminate child process group first (via recorded PID from setsid session, or direct
                // proc PID if killed before pidFile was written) so no orphan worker survives stop/fallback.
                killRecordedEnginePid()
                extractProcessPid(proc)?.let { procPid ->
                    if (procPid > 1) killProcessGroupSafe(procPid)
                }
                runCatching { proc.destroy() }
                runCatching {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        proc.waitFor(1200, TimeUnit.MILLISECONDS)
                    }
                }
                runCatching { proc.destroyForcibly() }
                runCatching {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        proc.waitFor(500, TimeUnit.MILLISECONDS)
                    }
                }
                extractProcessPid(proc)?.let { procPid ->
                    if (procPid > 1) killProcessGroupSafe(procPid)
                }
            }
            killRecordedEnginePid()
            dshProcess = null
            adoptedRunning = false
            dshWebUrl = null
            activeExecutorUsed = null
            engineState = nextState
            SafetyGate.endTurn()
            GrassBagEngineService.clearNativeActiveWork()
            PhoneOverlayController.getInstance(ctx).dismissAll()
            runCatching { if (bridgeSocket.exists()) bridgeSocket.delete() }
            if (!keepForegroundService) {
                GrassBagEngineService.stop(ctx)
            }
            if (emitStoppedEvent) {
                emit("engine_state", mapOf("state" to nextState))
            }
        }
    }

    private fun mapContainerWorkdirToHost(workDirInsideContainer: String): File {
        val clean = workDirInsideContainer.trim().trimEnd('/').ifEmpty { "/root/workspace" }
        return when {
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
    }

    private fun resolveHostDirForContainerWorkdir(workDirInsideContainer: String): File {
        val candidate = mapContainerWorkdirToHost(workDirInsideContainer)
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
        val cachedDisableProotSeccomp =
            meta.optString("prootSeccompUnsupportedFingerprint", "") == Build.FINGERPRINT
        val effectiveForceProot = forceProot ?: (activeExecutorUsed == "proot" || activeExecutorUsed == "proot-legacy")
        val effectiveDisableSeccomp =
            disableProotSeccomp ?: (activeExecutorUsed == "proot-legacy" || cachedDisableProotSeccomp)
        val wantTawc = !effectiveForceProot && tawcBin.exists() && effectiveExecutorMode(meta) == "tawcroot"
        if (!wantTawc) {
            check(prootBin.exists()) { "libproot.so not found in ${nativeLibDir.absolutePath}" }
        }

        prootTmpDir.mkdirs()
        tawcTmpDir.mkdirs()
        File(homeDir, ".cache/node-compile-cache").mkdirs()
        if (!etcPrepared) {
            ensureContainerEtcFiles(force = false)
        }

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
        val proxyInfo = if (meta.optBoolean("useSystemProxy", false)) resolveSystemProxyInfo() else null
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
            if (proxyInfo != null) {
                val (proxyUrl, noProxyList) = proxyInfo
                put("HTTP_PROXY", proxyUrl)
                put("HTTPS_PROXY", proxyUrl)
                put("http_proxy", proxyUrl)
                put("https_proxy", proxyUrl)
                put("NO_PROXY", noProxyList)
                put("no_proxy", noProxyList)
            }
            if (includeBridgeSecrets) {
                // Scope shim + V8 compile cache strictly to the DSH engine process (not shells/npm/droid scripts).
                put("GBRIDGE_DSH_BOOT", "1")
                put("GBRIDGE_BOOT_CACHE_TIMEOUT_MS", if (forceProot == true) "120000" else "90000")
                put("NODE_COMPILE_CACHE", "/root/.cache/node-compile-cache")
                put("GBRIDGE_UNIX_SOCKET", "/run/grassbag/bridge.sock")
                put("GBRIDGE_PHONE_SOCKET", "/run/grassbag/phone-control.sock")
                put("GBRIDGE_PID_FILE", "/run/grassbag/dsh-engine.pid")
                // Deliver bearer tokens via a one-time 0600 file that dsh-gbridge immediately unlinks on import,
                // so `/proc/<pid>/environ` never exposes privileged tokens to same-UID terminal/agent processes.
                val secretFileName = ".boot-${vault.generateRandomToken(12)}.json"
                val secretHostFile = File(runRoot, secretFileName)
                val wroteSecretsFile = runCatching {
                    runRoot.mkdirs()
                    // Clean up any stale unconsumed bootstrap files from crashed starts.
                    runRoot.listFiles()?.forEach { f ->
                        if (f.name.startsWith(".boot-") && f.name.endsWith(".json")) {
                            runCatching { f.delete() }
                        }
                    }
                    val fd = Os.open(
                        secretHostFile.absolutePath,
                        OsConstants.O_CREAT or OsConstants.O_WRONLY or OsConstants.O_TRUNC,
                        0x180 // 0600
                    )
                    try {
                        val payload = JSONObject()
                            .put("token", bridgeToken)
                            .put("phoneToken", phoneDaemon.bearerToken)
                            .toString()
                            .toByteArray(Charsets.UTF_8)
                        Os.write(fd, payload, 0, payload.size)
                    } finally {
                        Os.close(fd)
                    }
                    true
                }.getOrDefault(false)
                if (wroteSecretsFile) {
                    put("GBRIDGE_SECRETS_FILE", "/run/grassbag/$secretFileName")
                } else {
                    put("GBRIDGE_TOKEN", bridgeToken)
                    put("GBRIDGE_PHONE_TOKEN", phoneDaemon.bearerToken)
                }
            }
            put("DROID_BRIDGE_SOCKET", "/run/grassbag/droid.sock")
            put("DROID_BRIDGE_TOKEN", droidDaemon.bearerToken)
        }
        return pb to executorTag
    }

    private fun startEngineSync(): Map<String, Any?> {
        var myStartEpoch = stopEpoch.get()
        // Coalesce concurrent startup attempts atomically, but NEVER coalesce onto an aborted
        // startup whose epoch was already superseded by stopEngineSync()!
        while (true) {
            var existingEpoch = -1
            val waitLatch: CountDownLatch? = synchronized(engineLock) {
                if (isEngineAlive() && engineState == "running") {
                    return mapOf("ok" to true, "alreadyRunning" to true, "status" to getStatus())
                }
                val existingLatch = activeStartupLatch
                if (existingLatch != null) {
                    existingEpoch = activeStartupEpoch
                    existingLatch
                } else {
                    myStartEpoch = stopEpoch.get()
                    activeStartupEpoch = myStartEpoch
                    activeStartupLatch = CountDownLatch(1)
                    engineState = "starting"
                    lastEngineError = null
                    null
                }
            }
            if (waitLatch == null) break
            runCatching { waitLatch.await(360, TimeUnit.SECONDS) }
            val currentStopEpoch = stopEpoch.get()
            if (currentStopEpoch != existingEpoch) {
                // Previous startup was cancelled by an earlier stopEngineSync(); if our own caller
                // hasn't been cancelled since entry, loop and initiate a fresh startup cleanly!
                if (currentStopEpoch == myStartEpoch) {
                    continue
                }
                return mapOf("ok" to false, "error" to "engine_stopped", "status" to getStatus())
            }
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
                emit("engine_state", mapOf("state" to "stopped"))
                return mapOf("ok" to false, "error" to "runtime_not_initialized", "status" to getStatus())
            }

            // Adopt an already-healthy local DSH instance ONLY when a prior pid/socket exists AND
            // any recorded PID is genuinely alive (avoids slow stale UDS + cold HttpURLConnection
            // probes after an OEM background kill!).
            val existingCaps = if (pidFile.exists() || bridgeSocket.exists()) {
                val recordedPid = runCatching {
                    if (pidFile.isFile) pidFile.readText().trim().toIntOrNull() else null
                }.getOrNull()
                if (recordedPid != null && !isValidEnginePid(recordedPid)) {
                    runCatching { pidFile.delete() }
                    runCatching { if (bridgeSocket.exists()) bridgeSocket.delete() }
                    null
                } else {
                    probeLocalCapabilities()
                }
            } else {
                null
            }
            if (existingCaps != null) {
                if (hasPendingFastOverlayUpdate(activeSlot)) {
                    appendLog("[runtime] APK overlays updated; restarting previously running DSH to apply updates...")
                    stopEngineSync(keepForegroundService = true, emitStoppedEvent = false, cancelStartup = false)
                    synchronized(engineLock) {
                        engineState = "starting"
                        lastEngineError = null
                    }
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
                        "DSH $lastCapabilitiesDshVersion · 后台保活中",
                        releaseWakeLock = true
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
            if (stopEpoch.get() != myStartEpoch) {
                appendLog("[runtime] startup cancelled before overlay sync")
                return mapOf("ok" to false, "error" to "engine_stopped", "status" to getStatus())
            }
            if (hasPendingFastOverlayUpdate(activeSlot)) {
                runCatching { syncFastOverlaysIfNeeded(activeSlot) }.onFailure { err ->
                    Log.w(TAG, "syncFastOverlaysIfNeeded failed: ${err.message}", err)
                    appendLog("[runtime] WARN: fast overlay sync failed: ${err.message}")
                }
            }

            val nativeLibDir = File(ctx.applicationInfo.nativeLibraryDir)
            val hasTawc = File(nativeLibDir, "libtawcroot.so").exists()
            val hasProot = File(nativeLibDir, "libproot.so").exists()
            if (!hasTawc && !hasProot) {
                val errMsg = "neither libtawcroot.so nor libproot.so found in ${nativeLibDir.absolutePath}"
                synchronized(engineLock) {
                    engineState = "error"
                    lastEngineError = errMsg
                }
                emit("engine_state", mapOf("state" to "error", "error" to errMsg))
                return mapOf("ok" to false, "error" to errMsg, "status" to getStatus())
            }

            if (stopEpoch.get() != myStartEpoch) {
                appendLog("[runtime] startup cancelled by stop request before launching FGS")
                return mapOf("ok" to false, "error" to "engine_stopped", "status" to getStatus())
            }

            // Keep Android 12-16 cached-app freezer & Doze from stalling cold V8 boot!
            GrassBagEngineService.startOrUpdate(
                ctx,
                "GrassBag 正在启动本机引擎…",
                "首次编译缓存加载中，完成后自动保活",
                wakeLockMs = 180_000L
            )

            updateRelativeSymlink(File(containersRoot, "current"), ubuntuRoot.name)
            updateRelativeSymlink(File(slotsRoot, "current"), activeSlot)
            if (!etcPrepared) {
                ensureContainerEtcFiles(force = true)
            } else {
                refreshContainerDns()
            }

            // Try fast path first (`tawcroot`), automatically falling back to `proot` (seccomp) -> `proot-legacy` if needed.
            val freshMeta = readMeta()
            val wantTawcFirst = hasTawc && effectiveExecutorMode(freshMeta) == "tawcroot"
            val skipProotSeccomp =
                freshMeta.optString("prootSeccompUnsupportedFingerprint", "") == Build.FINGERPRINT
            val attempts = mutableListOf<Pair<Boolean, Boolean>>() // (forceProot, disableProotSeccomp)
            if (wantTawcFirst) {
                attempts.add(false to false)
            }
            if (hasProot) {
                if (!skipProotSeccomp) {
                    attempts.add(true to false)
                }
                attempts.add(true to true)
            }

            val attemptErrors = mutableListOf<String>()
            var lastAttemptErr: String? = null
            var tawcTimedOutNoOutput = false
            var prootSeccompTimedOutNoOutput = false
            for ((idx, attempt) in attempts.withIndex()) {
                if (stopEpoch.get() != myStartEpoch) {
                    appendLog("[runtime] startup cancelled by stop request before attempt #${idx + 1}")
                    if (!isEngineAlive() && activeToolkitInstalls.get() <= 0 && !upgradeInProgress.get()) {
                        GrassBagEngineService.stop(ctx)
                    }
                    return mapOf("ok" to false, "error" to "engine_stopped", "status" to getStatus())
                }
                val (forceProot, disableSeccomp) = attempt
                if (idx > 0) {
                    // Renew WakeLock per fallback attempt so slower PRoot cold boots stay unthrottled!
                    GrassBagEngineService.startOrUpdate(
                        ctx,
                        "GrassBag 正在切换兼容模式启动引擎…",
                        "兼容执行器加载中，完成后自动保活",
                        wakeLockMs = 180_000L
                    )
                }
                val res = launchAndWaitForEngine(activeSlot, forceProot, disableSeccomp, myStartEpoch)
                if (res["ok"] == true) {
                    // If tawcroot or proot (seccomp) hung silently while a fallback succeeded,
                    // remember fallback for this OS fingerprint so subsequent launches skip the hang!
                    if (forceProot && tawcTimedOutNoOutput) {
                        runCatching {
                            updateMeta { it.put("tawcUnsupportedFingerprint", Build.FINGERPRINT) }
                        }
                        appendLog("[runtime] cached proot fallback for fingerprint after silent tawcroot hang")
                    }
                    if (forceProot && disableSeccomp && prootSeccompTimedOutNoOutput) {
                        runCatching {
                            updateMeta { it.put("prootSeccompUnsupportedFingerprint", Build.FINGERPRINT) }
                        }
                        appendLog("[runtime] cached proot-legacy (NO_SECCOMP) fallback for fingerprint after silent proot seccomp hang")
                    }
                    return res
                }
                if (stopEpoch.get() != myStartEpoch) {
                    appendLog("[runtime] startup aborted by stop request")
                    if (!isEngineAlive() && activeToolkitInstalls.get() <= 0 && !upgradeInProgress.get()) {
                        GrassBagEngineService.stop(ctx)
                    }
                    return mapOf("ok" to false, "error" to "engine_stopped", "status" to getStatus())
                }
                lastAttemptErr = res["error"]?.toString()
                if (!lastAttemptErr.isNullOrBlank()) {
                    attemptErrors.add("#${idx + 1}: $lastAttemptErr")
                }
                // Cache tawcroot fallback on kernel/seccomp/loader/signal crash codes (60..79, 86/88/89/91/92/94/95,
                // SIGILL=132, SIGABRT=134, SIGBUS=135, SIGSEGV=139, SIGSYS=159); never on transient rootfs/bind errors (90/93).
                var skipFurtherFallback = false
                if (!forceProot && lastAttemptErr != null) {
                    val isHardTawcCrash = Regex("""code (6\d|7\d|86|88|89|91|92|94|95|132|134|135|139|159)\b""")
                        .containsMatchIn(lastAttemptErr)
                    if (isHardTawcCrash) {
                        runCatching {
                            updateMeta { it.put("tawcUnsupportedFingerprint", Build.FINGERPRINT) }
                        }
                    } else if (res["timedOutNoOutput"] == true) {
                        tawcTimedOutNoOutput = true
                    } else if (res["reachedUserland"] == true && res["timedOut"] != true) {
                        // tawcroot successfully entered Node/JS userland and exited with an application-level
                        // error (e.g. invalid config or EADDRINUSE) — retrying under slower PRoot won't fix it.
                        skipFurtherFallback = true
                        appendLog("[runtime] tawcroot reached Node/JS userland before exiting; skipping redundant proot fallback")
                    }
                } else if (forceProot && !disableSeccomp && res["timedOutNoOutput"] == true) {
                    prootSeccompTimedOutNoOutput = true
                }
                // Clean up failed/timed-out attempt; keep FGS & keep engineState="starting" while falling back!
                val hasMoreAttempts = !skipFurtherFallback && idx + 1 < attempts.size
                stopEngineSync(
                    keepForegroundService = hasMoreAttempts,
                    emitStoppedEvent = false,
                    cancelStartup = false,
                    nextState = if (hasMoreAttempts) "starting" else "stopped"
                )
                if (skipFurtherFallback) {
                    break
                }
                if (hasMoreAttempts) {
                    appendLog("[runtime] startup attempt #${idx + 1} failed ($lastAttemptErr); retrying with fallback executor...")
                }
            }

            val combinedErr = if (attemptErrors.size > 1) {
                attemptErrors.joinToString(" || ")
            } else {
                lastAttemptErr ?: "DSH startup failed"
            }
            synchronized(engineLock) {
                engineState = "error"
                lastEngineError = combinedErr
            }
            if (activeToolkitInstalls.get() <= 0 && !upgradeInProgress.get()) {
                GrassBagEngineService.stop(ctx)
            }
            emit("engine_state", mapOf("state" to "error", "error" to lastEngineError))
            return mapOf("ok" to false, "error" to lastEngineError, "status" to getStatus())
        } catch (t: Throwable) {
            val errMsg = t.message ?: t.javaClass.simpleName
            Log.e(TAG, "startEngineSync crashed: $errMsg", t)
            appendLog("[runtime] ERROR: startEngineSync exception: $errMsg")
            synchronized(engineLock) {
                engineState = "error"
                lastEngineError = errMsg
            }
            if (!isEngineAlive() && activeToolkitInstalls.get() <= 0 && !upgradeInProgress.get()) {
                GrassBagEngineService.stop(ctx)
            }
            emit("engine_state", mapOf("state" to "error", "error" to errMsg))
            return mapOf("ok" to false, "error" to errMsg, "status" to getStatus())
        } finally {
            synchronized(engineLock) {
                if (engineState == "starting") {
                    engineState = if (lastEngineError != null) "error" else "stopped"
                }
                activeStartupEpoch = -1
                activeStartupLatch?.countDown()
                activeStartupLatch = null
            }
        }
    }

    private fun launchAndWaitForEngine(
        activeSlot: String,
        forceProot: Boolean,
        disableProotSeccomp: Boolean,
        startEpoch: Int
    ): Map<String, Any?> {
        val t0 = SystemClock.elapsedRealtime()
        val proc: Process
        val executorTag: String
        val sawAnyStdout = AtomicBoolean(false)
        val sawUserlandOutput = AtomicBoolean(false)
        val stdoutDrainedLatch = CountDownLatch(1)
        synchronized(engineLock) {
            if (stopEpoch.get() != startEpoch) {
                return mapOf("ok" to false, "error" to "engine_stopped", "status" to getStatus())
            }
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
                    "--no-warnings",
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
                try {
                    runCatching {
                        BufferedReader(InputStreamReader(proc.inputStream, Charsets.UTF_8)).use { br ->
                            while (true) {
                                val line = br.readLine() ?: break
                                sawAnyStdout.set(true)
                                if (!sawUserlandOutput.get() &&
                                    (line.contains("dsh web:") ||
                                        line.contains("?token=") ||
                                        line.contains("gbridge") ||
                                        line.contains("cordis") ||
                                        line.contains("UDS listener") ||
                                        line.contains("EADDRINUSE") ||
                                        line.contains("SyntaxError:") ||
                                        line.contains("TypeError:") ||
                                        line.contains("ReferenceError:") ||
                                        line.contains("Error:") ||
                                        line.contains("node:internal"))
                                ) {
                                    sawUserlandOutput.set(true)
                                }
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
                } finally {
                    stdoutDrainedLatch.countDown()
                }
                val code = runCatching { proc.waitFor() }.getOrDefault(-1)
                appendLog("[runtime] DSH process ($tag) exited with code $code")
                synchronized(readinessSignal) { readinessSignal.notifyAll() }
                synchronized(engineLock) {
                    if (dshProcess === proc) {
                        SafetyGate.endTurn()
                        GrassBagEngineService.clearNativeActiveWork()
                        PhoneOverlayController.getInstance(ctx).dismissAll()
                        dshProcess = null
                        runCatching { if (bridgeSocket.exists()) bridgeSocket.delete() }
                        runCatching { if (pidFile.exists()) pidFile.delete() }
                        // During "starting", startEngineSync() owns fallback retries (tawcroot -> proot) and final
                        // error reporting; preserve the stderr tail so crash diagnostics are never discarded!
                        val tail = getEngineLogs().takeLast(6).joinToString(" | ")
                        val formattedErr = if (tail.isNotEmpty()) "DSH ($tag) exited with code $code: $tail" else "DSH ($tag) exited with code $code"
                        if (engineState == "starting") {
                            lastEngineError = formattedErr
                        } else if (engineState != "stopped") {
                            val canAutoRecover = stopEpoch.get() == startEpoch &&
                                !bootstrapRunning.get() &&
                                !upgradeInProgress.get() &&
                                tryReserveAutoRestartSlot()
                            if (canAutoRecover) {
                                autoRecoverPending.set(true)
                                engineState = "starting"
                                lastEngineError = null
                                appendLog("[runtime] unexpected DSH exit (code=$code); keeping FGS alive and auto-recovering...")
                                GrassBagEngineService.startOrUpdate(
                                    ctx,
                                    "GrassBag 正在自动恢复本机引擎…",
                                    "检测到后台进程中断，正在自动重启 DSH 核心",
                                    wakeLockMs = 180_000L,
                                    holdWifiLock = true
                                )
                                emit("engine_state", mapOf("state" to "starting", "exitCode" to code, "recovering" to true))
                                val backoffMs = nextAutoRestartBackoffMs()
                                worker.execute {
                                    try {
                                        runCatching { Thread.sleep(backoffMs) }
                                        if (stopEpoch.get() == startEpoch && !bootstrapRunning.get() && !upgradeInProgress.get()) {
                                            startEngineSync()
                                        }
                                    } finally {
                                        autoRecoverPending.set(false)
                                    }
                                }
                            } else {
                                engineState = "error"
                                lastEngineError = formattedErr
                                if (activeToolkitInstalls.get() <= 0) {
                                    GrassBagEngineService.stop(ctx)
                                }
                                emit("engine_state", mapOf("state" to engineState, "exitCode" to code, "error" to lastEngineError))
                            }
                        }
                    }
                }
            }
        }

        // Executor-aware monotonic startup budget: allow 75s on cold V8 compile-cache miss for tawcroot,
        // 60s on warm tawcroot, and 120s for slower PRoot on older phones.
        val compileCacheEmpty = (File(homeDir, ".cache/node-compile-cache").listFiles()?.isEmpty() != false)
        val timeoutMs = when {
            forceProot -> 120_000L
            compileCacheEmpty -> 75_000L
            else -> 60_000L
        }
        val deadline = t0 + timeoutMs
        var consecutive401AfterWebUrl = 0
        var lastBlindTcpProbeAt = 0L
        while (SystemClock.elapsedRealtime() < deadline) {
            if (stopEpoch.get() != startEpoch) {
                return mapOf("ok" to false, "error" to "engine_stopped", "status" to getStatus())
            }
            if (!isEngineAlive()) {
                runCatching { proc.waitFor(500, java.util.concurrent.TimeUnit.MILLISECONDS) }
                // Wait briefly for stdout/stderr reader to drain final crash lines before capturing tail logs!
                runCatching { stdoutDrainedLatch.await(300, TimeUnit.MILLISECONDS) }
                val exitCode = runCatching { proc.exitValue() }.getOrNull()
                val tail = getEngineLogs().takeLast(6).joinToString(" | ")
                lastEngineError = lastEngineError ?: (
                    if (exitCode != null) "DSH ($executorTag) exited with code $exitCode: $tail"
                    else "DSH ($executorTag) exited early: $tail"
                )
                return mapOf(
                    "ok" to false,
                    "error" to lastEngineError,
                    "reachedUserland" to (sawUserlandOutput.get() || dshWebUrl != null),
                    "timedOut" to false,
                    "status" to getStatus()
                )
            }
            val nowMs = SystemClock.elapsedRealtime()
            val elapsed = nowMs - t0
            val udsExists = bridgeSocket.exists()
            var probe: Pair<JSONObject?, Int> = null to -1
            var readyViaUds = false
            if (udsExists) {
                probe = probeUdsCapabilitiesWithStatus()
                if (probe.first != null) {
                    readyViaUds = true
                }
            }
            if (probe.first == null && (dshWebUrl != null || (elapsed >= 2000L && nowMs - lastBlindTcpProbeAt >= 500L))) {
                lastBlindTcpProbeAt = nowMs
                probe = probeLocalCapabilitiesWithStatus()
            }
            val caps = probe.first
            if (probe.second == 401 && dshWebUrl != null) {
                consecutive401AfterWebUrl++
                if (consecutive401AfterWebUrl == 1 || consecutive401AfterWebUrl == 10) {
                    appendLog("[runtime] WARN: capabilities probe returned HTTP 401 after dshWebUrl appeared (token mismatch / legacy plugin)")
                }
            }
            if (caps != null) {
                if (!readyViaUds && !bridgeSocket.exists()) {
                    // Brief grace (up to 250ms) only if TCP responded before bridge.sock appeared.
                    for (i in 0 until 5) {
                        if (bridgeSocket.exists()) break
                        runCatching { Thread.sleep(50) }
                    }
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
                val bootMs = SystemClock.elapsedRealtime() - t0
                GrassBagEngineService.startOrUpdate(
                    ctx,
                    "GrassBag 本机引擎运行中",
                    "DSH $lastCapabilitiesDshVersion ($executorTag) · 后台保活中",
                    releaseWakeLock = activeToolkitInstalls.get() <= 0 && !GrassBagEngineService.hasNativeActiveWork()
                )
                appendLog("[runtime] DSH READY in ${bootMs}ms! executor=$executorTag version=$lastCapabilitiesDshVersion endpoints=${caps.optInt("endpointsCount")} uds=${bridgeSocket.exists()} readyViaUds=$readyViaUds webUrl=${dshWebUrl != null} port=$LOCAL_DSH_PORT")
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
            val waitMs = if (dshWebUrl != null || udsExists) 60L else if (elapsed < 8_000L) 120L else 220L
            synchronized(readinessSignal) {
                runCatching { readinessSignal.wait(waitMs) }
            }
        }

        val tail = getEngineLogs().takeLast(6).joinToString(" | ")
        lastEngineError = "DSH ($executorTag) startup timed out (${timeoutMs / 1000}s): $tail"
        appendLog("[runtime] TIMEOUT: $lastEngineError")
        return mapOf(
            "ok" to false,
            "error" to lastEngineError,
            "timedOut" to true,
            "timedOutNoOutput" to (!sawAnyStdout.get() && dshWebUrl == null && !bridgeSocket.exists()),
            "reachedUserland" to (sawUserlandOutput.get() || dshWebUrl != null),
            "status" to getStatus()
        )
    }

    private fun probeLocalCapabilities(): JSONObject? {
        if (bridgeSocket.exists()) {
            probeUdsCapabilitiesWithStatus().first?.let { return it }
        }
        return probeLocalCapabilitiesWithStatus().first
    }

    private fun probeUdsCapabilitiesWithStatus(): Pair<JSONObject?, Int> = runCatching {
        if (!bridgeSocket.exists()) return@runCatching null to -1
        val sock = LocalSocket(LocalSocket.SOCKET_STREAM)
        try {
            sock.connect(LocalSocketAddress(bridgeSocket.absolutePath, LocalSocketAddress.Namespace.FILESYSTEM))
            sock.soTimeout = 600
            val req = "GET /gbridge/v1/capabilities HTTP/1.1\r\n" +
                "Host: localhost\r\n" +
                "Authorization: Bearer $bridgeToken\r\n" +
                "Connection: close\r\n\r\n"
            sock.outputStream.write(req.toByteArray(Charsets.UTF_8))
            sock.outputStream.flush()
            val rawBytes = java.io.ByteArrayOutputStream()
            val buf = ByteArray(4096)
            var total = 0
            val maxProbeBytes = 128 * 1024
            while (true) {
                val n = sock.inputStream.read(buf)
                if (n <= 0) break
                val take = n.coerceAtMost(maxProbeBytes - total)
                if (take > 0) {
                    rawBytes.write(buf, 0, take)
                    total += take
                }
                if (total >= maxProbeBytes) break
            }
            val raw = rawBytes.toString(Charsets.UTF_8.name())
            val headerEnd = raw.indexOf("\r\n\r\n")
            if (headerEnd < 0) return@runCatching null to -1
            val statusLine = raw.substring(0, raw.indexOf("\r\n").coerceAtLeast(0))
            val parts = statusLine.split(' ')
            val code = parts.getOrNull(1)?.toIntOrNull() ?: -1
            if (code !in 200..299) return@runCatching null to code
            var body = raw.substring(headerEnd + 4)
            if (raw.substring(0, headerEnd).contains("transfer-encoding: chunked", ignoreCase = true)) {
                val decoded = StringBuilder()
                var pos = 0
                while (pos < body.length) {
                    val lineEnd = body.indexOf("\r\n", pos)
                    if (lineEnd < 0) break
                    val sizeHex = body.substring(pos, lineEnd).substringBefore(';').trim()
                    val chunkLen = sizeHex.toIntOrNull(16) ?: break
                    pos = lineEnd + 2
                    if (chunkLen == 0) break
                    val end = (pos + chunkLen).coerceAtMost(body.length)
                    decoded.append(body, pos, end)
                    pos = end
                    if (pos + 2 <= body.length && body.startsWith("\r\n", pos)) {
                        pos += 2
                    }
                }
                if (decoded.isNotEmpty()) {
                    body = decoded.toString()
                }
            }
            JSONObject(body) to code
        } finally {
            runCatching { sock.close() }
        }
    }.getOrDefault(null to -1)

    private fun probeLocalCapabilitiesWithStatus(): Pair<JSONObject?, Int> = runCatching {
        val conn = (URL("http://127.0.0.1:$LOCAL_DSH_PORT/gbridge/v1/capabilities").openConnection(Proxy.NO_PROXY) as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 350
            readTimeout = 800
            setRequestProperty("Authorization", "Bearer $bridgeToken")
        }
        try {
            val code = conn.responseCode
            if (code in 200..299) {
                val obj = conn.inputStream.use { JSONObject(it.bufferedReader().readText()) }
                obj to code
            } else {
                null to code
            }
        } finally {
            conn.disconnect()
        }
    }.getOrDefault(null to -1)

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
        if (!bootstrapRunning.get()) {
            dirs.add(runtimeDownloadsDir)
        }
        dirs.forEach { dir ->
            if (dir.exists()) {
                freedBytes += cleanDirFilesNoFollow(dir, compileCacheDir)
            }
        }
        runtimeDownloadsDir.mkdirs()
        prootTmpDir.mkdirs()
        tawcTmpDir.mkdirs()
        lastHomeSizeAtMs = 0L
        return mapOf("ok" to true, "freedKb" to (freedBytes / 1024L), "status" to getStatus())
    }

    fun rebuildContainerPreserveHome(done: (Map<String, Any?>) -> Unit) {
        worker.execute {
            if (!bootstrapRunning.compareAndSet(false, true)) {
                done(mapOf("ok" to false, "error" to "当前已有运行环境下载或部署任务在进行中，请先等待完成或暂停后再重试", "status" to getStatus()))
                return@execute
            }
            var handedOffToBootstrap = false
            try {
                if (upgradeInProgress.get()) {
                    done(mapOf("ok" to false, "error" to "当前有版本升级或回滚任务在进行中，请等待完成后再重建容器", "status" to getStatus()))
                    return@execute
                }
                if (activeToolkitInstalls.get() > 0) {
                    done(mapOf("ok" to false, "error" to "当前有工具包正在安装，请等待安装完成后再重建容器", "status" to getStatus()))
                    return@execute
                }
                shells.keys.toList().forEach { closeLocalShell(it) }
                // Keep FGS alive while deleting ubuntuRoot so Android 12-16 won't reject FGS re-start if backgrounded.
                // Stop engine OUTSIDE bootstrapLock to prevent AB-BA inversion with syncFastOverlaysIfNeeded().
                stopEngineSync(keepForegroundService = true)
                synchronized(bootstrapLock) {
                    sendProgress("rebuild", 15, "保留 /root 数据卷，清理旧容器根文件系统…")
                    TarGzExtractor.deleteTreeNoFollow(ubuntuRoot)
                    TarGzExtractor.deleteTreeNoFollow(File(containersRoot, "tawcroot"))
                    ubuntuRoot.mkdirs()
                    etcPrepared = false
                    ptySupportedCache = null
                    cachedInstalledToolkits = null
                }
                handedOffToBootstrap = true
                bootstrapRuntime(alreadyAcquiredLock = true, done = done)
            } catch (e: Throwable) {
                if (!isEngineAlive() && activeToolkitInstalls.get() <= 0 && !upgradeInProgress.get()) {
                    GrassBagEngineService.stop(ctx)
                }
                val msg = e.message ?: "rebuild_failed"
                sendProgress("error", 0, "重建容器失败：$msg")
                done(mapOf("ok" to false, "error" to msg, "status" to getStatus()))
            } finally {
                if (!handedOffToBootstrap) {
                    bootstrapRunning.set(false)
                }
            }
        }
    }

    fun performAbUpgrade(targetVersion: String, remoteBaseUrl: String?, done: (Map<String, Any?>) -> Unit) {
        worker.execute {
            if (bootstrapRunning.get()) {
                done(mapOf("ok" to false, "error" to "当前正在下载或部署运行环境，请等待完成后再升级", "status" to getStatus()))
                return@execute
            }
            if (!upgradeInProgress.compareAndSet(false, true)) {
                done(mapOf("ok" to false, "error" to "已有版本升级或回滚任务正在进行中，请稍候完成", "status" to getStatus()))
                return@execute
            }
            var stagedTargetDir: File? = null
            var startedFg = false
            var switchedMeta = false
            var revertMetaFn: (() -> Unit)? = null
            var prevVersionForRollback = ""
            var prevSlotForRollback = ""
            var installedVer = targetVersion
            var standbyName = ""
            try {
                // Hold bootstrapLock ONLY while preparing & atomically switching the standby slot;
                // release BEFORE calling startEngineSync() to prevent AB-BA deadlock with syncFastOverlaysIfNeeded().
                synchronized(bootstrapLock) {
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
                    standbyName = standby
                    val prevVersion = lastCapabilitiesDshVersion ?: st.optString("dshVersion", "0.2.2-rc.5")
                    prevVersionForRollback = prevVersion
                    prevSlotForRollback = cur
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
                        // Ensure dsh-gbridge exists inside standby slot BEFORE isSlotExtracted() runs in startEngineSync()!
                        val standbyBridge = File(targetDir, "dsh-gbridge")
                        if (!File(standbyBridge, "lib/index.js").exists()) {
                            val curBridge = File(curDir, "dsh-gbridge")
                            if (curBridge.exists()) {
                                curBridge.copyRecursively(standbyBridge, overwrite = true)
                            } else {
                                val bundledBridge = bundled.loadManifest()?.optJSONObject("artifacts")?.optJSONObject("gbridge")
                                if (bundledBridge != null) {
                                    standbyBridge.mkdirs()
                                    bundled.openStream(bundledBridge.optString("asset"))?.use { ins ->
                                        TarGzExtractor.extractStream(ins, standbyBridge, bundledBridge.optString("sha256"), bundledBridge.optLong("bytes", 0L), freshDir = true)
                                    }
                                }
                            }
                            writeAndroidCordisPatch(File(standbyBridge, "cordis.patch.yml"))
                        }
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
                        val registries = listOf(
                            "国内镜像 (npmmirror)" to "https://registry.npmmirror.com",
                            "npm 官方源" to "https://registry.npmjs.org"
                        )
                        var installSucceeded = false
                        var lastInstallErr = ""
                        for ((regIdx, regPair) in registries.withIndex()) {
                            val (regLabel, regUrl) = regPair
                            sendProgress(
                                "download",
                                if (regIdx == 0) 48 else 54,
                                "正在通过 $regLabel 安装 $pkgSpec 到备用槽位 $standby…"
                            )
                            appendLog("[upgrade] npm install --registry=$regUrl --no-audit --no-fund --prefix /opt/dsh-slots/$standby $pkgSpec")
                            val pb = buildProotProcess(
                                listOf(
                                    "/usr/local/bin/npm",
                                    "install",
                                    "--registry=$regUrl",
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
                                killSubprocessGroup(proc)
                                runCatching { proc.inputStream.close() }
                                runCatching { reader.join(1000) }
                                lastInstallErr = "$regLabel 安装 $pkgSpec 超时（超过 5 分钟）"
                                appendLog("[upgrade] $lastInstallErr")
                                continue
                            }
                            runCatching { reader.join(1500) }
                            val exitCode = proc.exitValue()
                            if (exitCode == 0) {
                                installSucceeded = true
                                break
                            }
                            val reason = synchronized(outputTail) { outputTail.joinToString("\n") }
                                .ifBlank { "npm exited with code $exitCode" }
                            lastInstallErr = "$regLabel 安装 $pkgSpec 失败 (code=$exitCode)：$reason"
                            appendLog("[upgrade] $lastInstallErr")
                        }
                        if (!installSucceeded) {
                            error(lastInstallErr.ifBlank { "npm 安装 $pkgSpec 失败，请检查网络连接后重试" })
                        }
                    }

                    // Verify real installed @deepseek-ai/dsh binary & package.json version before switching!
                    val dshBin = File(targetDir, "node_modules/@deepseek-ai/dsh/lib/bin.js")
                    val dshPkg = File(targetDir, "node_modules/@deepseek-ai/dsh/package.json")
                    if (!dshBin.exists() || !dshPkg.exists()) {
                        error("备用槽位校验失败：未找到 @deepseek-ai/dsh/lib/bin.js")
                    }
                    installedVer = runCatching { JSONObject(dshPkg.readText()).optString("version", targetVersion) }
                        .getOrDefault(targetVersion)
                    runCatching { extractingFlag.delete() }
                    runCatching { File(targetDir, ".extract-complete").writeText(installedVer) }

                    revertMetaFn = {
                        runCatching {
                            updateMeta { fresh ->
                                fresh.put("activeSlot", cur)
                                fresh.put("lkgSlot", prevLkgSlot)
                                fresh.put("dshVersion", prevVersion)
                                fresh.put("dshPrevVersion", prevDshPrevVersion)
                                fresh.put("userUpgradedAb", prevUserUpgradedAb)
                            }
                            updateRelativeSymlink(File(slotsRoot, "current"), cur)
                            updateRelativeSymlink(File(slotsRoot, "lkg"), prevLkgSlot)
                        }
                    }

                    sendProgress("switch", 82, "预检通过 (v$installedVer)，原子切换至 $standby 并重启本机引擎…")
                    updateMeta { fresh ->
                        fresh.put("lkgSlot", cur)
                        fresh.put("dshPrevVersion", prevVersion)
                        fresh.put("activeSlot", standby)
                        fresh.put("dshVersion", installedVer)
                        fresh.put("userUpgradedAb", true)
                        if (remoteBaseUrl.isNullOrBlank()) {
                            val curBridgeSha = fresh.optString("gbridgeSha256_$cur", fresh.optString("gbridgeSha256", ""))
                            if (curBridgeSha.isNotEmpty()) fresh.put("gbridgeSha256_$standby", curBridgeSha)
                        } else {
                            fresh.remove("gbridgeSha256_$standby")
                        }
                    }
                    updateRelativeSymlink(File(slotsRoot, "current"), standby)
                    updateRelativeSymlink(File(slotsRoot, "lkg"), cur)
                    switchedMeta = true
                }

                stopEngineSync(keepForegroundService = true, emitStoppedEvent = false)
                val res = startEngineSync()
                if (res["ok"] != true) {
                    // Automatic LKG rollback on healthcheck failure: restore metadata + symlinks & remove broken slot!
                    appendLog("[upgrade] 新版本启动失败，自动回滚至 LKG 槽位 $prevSlotForRollback (v$prevVersionForRollback)…")
                    stopEngineSync(keepForegroundService = true, emitStoppedEvent = false)
                    synchronized(bootstrapLock) {
                        revertMetaFn?.invoke()
                        switchedMeta = false
                        stagedTargetDir?.let { runCatching { TarGzExtractor.deleteTreeNoFollow(it) } }
                        stagedTargetDir = null
                    }
                    val rbRes = startEngineSync()
                    if (rbRes["ok"] != true && !isEngineAlive() && activeToolkitInstalls.get() <= 0) {
                        GrassBagEngineService.stop(ctx)
                    }
                    val errMsg = "v$installedVer 启动自检未通过，已自动回滚至 v$prevVersionForRollback：${res["error"]}"
                    sendProgress("error", 0, errMsg)
                    done(mapOf("ok" to false, "error" to errMsg, "status" to getStatus()))
                    return@execute
                }
                stagedTargetDir = null
                switchedMeta = false
                sendProgress("ready", 100, "已切换至 $standbyName (v$installedVer)")
                done(mapOf("ok" to true, "engineStarted" to true, "version" to installedVer, "status" to getStatus()))
            } catch (err: Throwable) {
                synchronized(bootstrapLock) {
                    if (switchedMeta) {
                        revertMetaFn?.invoke()
                        switchedMeta = false
                    }
                    stagedTargetDir?.let { runCatching { TarGzExtractor.deleteTreeNoFollow(it) } }
                }
                if (startedFg) {
                    if (isEngineAlive() && engineState == "running") {
                        val ver = lastCapabilitiesDshVersion ?: readMeta().optString("dshVersion", "0.2.2-rc.5")
                        val exec = activeExecutorUsed ?: effectiveExecutorMode()
                        GrassBagEngineService.startOrUpdate(
                            ctx,
                            "GrassBag 本机引擎运行中",
                            "DSH $ver ($exec) · 后台保活中",
                            releaseWakeLock = true
                        )
                    } else if (activeToolkitInstalls.get() <= 0) {
                        GrassBagEngineService.stop(ctx)
                    }
                }
                val msg = err.message ?: "upgrade_failed"
                appendLog("[upgrade] ERROR: $msg")
                sendProgress("error", 0, "升级失败：$msg")
                done(mapOf("ok" to false, "error" to msg, "status" to getStatus()))
            } finally {
                upgradeInProgress.set(false)
            }
        }
    }

    fun rollbackLkg(done: (Map<String, Any?>) -> Unit) {
        worker.execute {
            if (bootstrapRunning.get()) {
                done(mapOf("ok" to false, "error" to "当前正在下载或部署运行环境，请等待完成后再回滚", "status" to getStatus()))
                return@execute
            }
            if (!upgradeInProgress.compareAndSet(false, true)) {
                done(mapOf("ok" to false, "error" to "已有版本升级或回滚任务正在进行中，请稍候完成", "status" to getStatus()))
                return@execute
            }
            try {
                var prevSlot = ""
                var targetSlot = ""
                var prevVer = ""
                var curVer = ""
                val canProceed = synchronized(bootstrapLock) {
                    val st = readMeta()
                    val cur = st.optString("activeSlot", "slot-a")
                    val lkg = st.optString("lkgSlot", "slot-a")
                    if (lkg == cur || !isSlotExtracted(lkg)) {
                        done(mapOf("ok" to false, "error" to "备用 LKG 槽位 ($lkg) 尚未写入历史版本，当前无需回滚", "status" to getStatus()))
                        false
                    } else {
                        prevSlot = cur
                        targetSlot = lkg
                        prevVer = st.optString("dshPrevVersion", "")
                        curVer = st.optString("dshVersion", "0.2.2-rc.5")
                        updateMeta { fresh ->
                            fresh.put("activeSlot", targetSlot)
                            fresh.put("lkgSlot", prevSlot)
                            if (prevVer.isNotEmpty()) fresh.put("dshVersion", prevVer)
                            fresh.put("dshPrevVersion", curVer)
                        }
                        updateRelativeSymlink(File(slotsRoot, "current"), targetSlot)
                        updateRelativeSymlink(File(slotsRoot, "lkg"), prevSlot)
                        true
                    }
                }
                if (!canProceed) return@execute
                // Release bootstrapLock BEFORE starting DSH engine to avoid AB-BA deadlock!
                stopEngineSync(keepForegroundService = true, emitStoppedEvent = false)
                val res = startEngineSync()
                if (res["ok"] != true) {
                    val failReason = res["error"]?.toString() ?: "health_check_failed"
                    appendLog("[rollback] target slot $targetSlot failed to start ($failReason); reverting to $prevSlot")
                    synchronized(bootstrapLock) {
                        updateMeta { fresh ->
                            fresh.put("activeSlot", prevSlot)
                            fresh.put("lkgSlot", targetSlot)
                            if (curVer.isNotEmpty()) fresh.put("dshVersion", curVer)
                            if (prevVer.isNotEmpty()) fresh.put("dshPrevVersion", prevVer) else fresh.remove("dshPrevVersion")
                        }
                        updateRelativeSymlink(File(slotsRoot, "current"), prevSlot)
                        updateRelativeSymlink(File(slotsRoot, "lkg"), targetSlot)
                    }
                    stopEngineSync(keepForegroundService = true, emitStoppedEvent = false)
                    val revertRes = startEngineSync()
                    val revertedOk = revertRes["ok"] == true
                    val msg = if (revertedOk) {
                        "回滚槽位 ($targetSlot) 启动失败（$failReason），已自动切回原槽位 ($prevSlot) 并恢复运行"
                    } else {
                        "回滚槽位 ($targetSlot) 启动失败（$failReason），已切回原槽位 ($prevSlot)，请手动重启引擎"
                    }
                    sendProgress("error", 0, msg)
                    done(
                        mapOf(
                            "ok" to false,
                            "reverted" to true,
                            "revertedEngineOk" to revertedOk,
                            "error" to msg,
                            "status" to getStatus()
                        )
                    )
                    return@execute
                }
                done(mapOf("ok" to true, "activeSlot" to targetSlot, "status" to getStatus()))
            } catch (t: Throwable) {
                val msg = t.message ?: "rollback_failed"
                appendLog("[rollback] ERROR: $msg")
                sendProgress("error", 0, "回滚失败：$msg")
                done(mapOf("ok" to false, "error" to msg, "status" to getStatus()))
            } finally {
                upgradeInProgress.set(false)
            }
        }
    }

    fun setExecutorMode(mode: String): Map<String, Any?> {
        val clean = if (mode == "tawcroot" || mode == "proot") mode else detectExecutor()
        updateMeta { st ->
            st.put("executorMode", clean)
            st.put("executorModePinned", true)
            if (clean == "tawcroot") {
                st.remove("tawcUnsupportedFingerprint")
            }
        }
        ptySupportedCache = null
        return mapOf("ok" to true, "status" to getStatus())
    }

    fun setSdcardMounted(enabled: Boolean): Map<String, Any?> {
        updateMeta { it.put("sdcardMounted", enabled) }
        return mapOf("ok" to true, "status" to getStatus())
    }

    fun setSystemProxy(enabled: Boolean): Map<String, Any?> {
        updateMeta { it.put("useSystemProxy", enabled) }
        return mapOf("ok" to true, "status" to getStatus())
    }

    fun installToolkit(toolkitId: String, requestedPackages: List<String>, done: (Map<String, Any?>) -> Unit) {
        // Increment BEFORE enqueueing so queued multi-toolkit installs never stop FGS between jobs
        // and rebuildContainerPreserveHome() accurately sees pending installs.
        activeToolkitInstalls.incrementAndGet()
        // Serialize all toolkit installs on a dedicated single-thread executor so tapping two
        // toolkits back-to-back never races on `/var/lib/dpkg/lock-frontend`!
        toolkitExecutor.execute {
            var startedFg = false
            try {
                if (bootstrapRunning.get() || upgradeInProgress.get()) {
                    done(mapOf("ok" to false, "error" to "当前正在部署或升级运行环境，请等待完成后再安装工具链", "status" to getStatus()))
                    return@execute
                }
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
                        killSubprocessGroup(proc)
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
                    cachedInstalledToolkits = null
                    val errText = reason.ifBlank { "apt-get exited with code $code ($usedExec)" }
                    done(mapOf("ok" to false, "error" to errText, "installedToolkits" to detectInstalledToolkits(forceRefresh = true), "status" to getStatus()))
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

                cachedInstalledToolkits = null
                appendLog("[toolkit:$toolkitId] installed successfully ($usedExec): $pkgLine")
                done(mapOf("ok" to true, "installedToolkits" to detectInstalledToolkits(forceRefresh = true), "status" to getStatus()))
            } catch (err: Throwable) {
                appendLog("[toolkit:$toolkitId] ERROR: ${err.message}")
                done(mapOf("ok" to false, "error" to (err.message ?: "toolkit_install_failed"), "status" to getStatus()))
            } finally {
                val remainingInstalls = activeToolkitInstalls.decrementAndGet()
                if (startedFg && remainingInstalls <= 0 && !upgradeInProgress.get()) {
                    if (isEngineAlive() && engineState == "running") {
                        val ver = lastCapabilitiesDshVersion ?: readMeta().optString("dshVersion", "0.2.2-rc.5")
                        val exec = activeExecutorUsed ?: effectiveExecutorMode()
                        GrassBagEngineService.startOrUpdate(
                            ctx,
                            "GrassBag 本机引擎运行中",
                            "DSH $ver ($exec) · 后台保活中",
                            releaseWakeLock = true
                        )
                    } else if (engineState != "starting") {
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

    private fun backupStorageDir(): File {
        val dir = ctx.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: ctx.filesDir
        dir.mkdirs()
        return dir
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    fun listEncryptedBackups(): Map<String, Any?> = runCatching {
        val dir = backupStorageDir()
        val files = (dir.listFiles() ?: emptyArray())
            .filter { it.isFile && it.name.endsWith(".gbag.enc") }
            .sortedByDescending { it.lastModified() }
            .take(20)
            .map { f ->
                mapOf(
                    "path" to f.absolutePath,
                    "filename" to f.name,
                    "bytes" to f.length(),
                    "modifiedAtMs" to f.lastModified()
                )
            }
        mapOf("ok" to true, "dir" to dir.absolutePath, "backups" to files)
    }.getOrElse { mapOf("ok" to false, "error" to (it.message ?: "list_backups_error")) }

    fun exportEncryptedBackup(passphrase: String): Map<String, Any?> = runCatching {
        val cleanPass = passphrase.trim()
        require(cleanPass.length >= 6) { "备份加密口令至少需要 6 位字符" }
        val maxTotalBytes = 64L * 1024L * 1024L
        val maxSingleFileBytes = 8L * 1024L * 1024L
        val maxDepth = 6
        var packedBytes = 0L
        val includedManifest = JSONArray()
        val skippedList = mutableListOf<Map<String, Any>>()
        val skippedManifest = JSONArray()

        fun recordSkip(relPath: String, sizeBytes: Long, reason: String) {
            skippedManifest.put(JSONObject().apply {
                put("path", relPath)
                put("bytes", sizeBytes)
                put("reason", reason)
            })
            if (skippedList.size < 30) {
                skippedList.add(mapOf("path" to relPath, "bytes" to sizeBytes, "reason" to reason))
            }
        }

        val zipOut = ByteArrayOutputStream()
        ZipOutputStream(zipOut).use { zos ->
            fun pack(f: File, name: String) {
                val st = runCatching { Os.lstat(f.absolutePath) }.getOrNull() ?: return
                if (!OsConstants.S_ISREG(st.st_mode)) {
                    recordSkip(name, 0L, "non_regular")
                    return
                }
                val fLen = st.st_size.coerceAtLeast(0L)
                if (fLen > maxSingleFileBytes) {
                    recordSkip(name, fLen, "exceeds_8mb_limit")
                    return
                }
                if (packedBytes + fLen > maxTotalBytes) {
                    recordSkip(name, fLen, "exceeds_64mb_archive_budget")
                    return
                }
                val raw = f.readBytes()
                if (packedBytes + raw.size > maxTotalBytes) {
                    recordSkip(name, raw.size.toLong(), "exceeds_64mb_archive_budget")
                    return
                }
                val digest = sha256Hex(raw)
                zos.putNextEntry(ZipEntry(name))
                zos.write(raw)
                zos.closeEntry()
                packedBytes += raw.size.toLong()
                includedManifest.put(JSONObject().apply {
                    put("path", name)
                    put("bytes", raw.size)
                    put("sha256", digest)
                })
            }

            if (metaFile.exists()) pack(metaFile, "runtime-state.json")
            if (aptFile.exists()) pack(aptFile, "apt-manifest.json")

            val dshDir = File(homeDir, ".dsh")
            val dshDirSt = runCatching { Os.lstat(dshDir.absolutePath) }.getOrNull()
            if (dshDirSt != null && OsConstants.S_ISDIR(dshDirSt.st_mode)) {
                fun walkDir(dir: File, depth: Int) {
                    val children = dir.listFiles()?.sortedBy { it.name } ?: return
                    for (child in children) {
                        val rel = "home/${child.relativeTo(homeDir).path}"
                        val st = runCatching { Os.lstat(child.absolutePath) }.getOrNull()
                        if (st == null) {
                            recordSkip(rel, 0L, "unreadable")
                            continue
                        }
                        if (OsConstants.S_ISDIR(st.st_mode)) {
                            if (depth >= maxDepth) {
                                recordSkip("$rel/", 0L, "max_depth_exceeded")
                            } else {
                                walkDir(child, depth + 1)
                            }
                        } else if (OsConstants.S_ISREG(st.st_mode)) {
                            pack(child, rel)
                        } else {
                            recordSkip(rel, 0L, "symlink_or_special")
                        }
                    }
                }
                walkDir(dshDir, 0)
            }

            val manifestJson = JSONObject().apply {
                put("schema", "grassbag-backup-v2")
                put("createdAtMs", System.currentTimeMillis())
                put("scope", "runtime-meta + /root/.dsh")
                put("includedCount", includedManifest.length())
                put("skippedCount", skippedManifest.length())
                put("totalUncompressedBytes", packedBytes)
                put("included", includedManifest)
                put("skipped", skippedManifest)
            }.toString(2).toByteArray(Charsets.UTF_8)
            zos.putNextEntry(ZipEntry("backup-manifest.json"))
            zos.write(manifestJson)
            zos.closeEntry()
        }
        val cipherBytes = vault.encryptWithPassphrase(zipOut.toByteArray(), cleanPass)
        val dir = backupStorageDir()
        val filename = "GrassBag-Backup-${System.currentTimeMillis()}.gbag.enc"
        val dest = File(dir, filename)
        FileOutputStream(dest).use { it.write(cipherBytes) }
        mapOf(
            "ok" to true,
            "path" to dest.absolutePath,
            "filename" to filename,
            "bytes" to cipherBytes.size,
            "includedCount" to includedManifest.length(),
            "skippedCount" to skippedManifest.length(),
            "skippedFiles" to skippedList,
            "scope" to "runtime-meta + /root/.dsh",
            "locationNote" to "已保存在应用专属下载目录，可点击「分享 / 另存」导出到系统 Download 或云盘"
        )
    }.getOrElse { mapOf("ok" to false, "error" to (it.message ?: "backup_error")) }

    private fun readAndVerifyBackupArchive(filePath: String, passphrase: String): Pair<JSONObject?, Map<String, ByteArray>> {
        val cleanPass = passphrase.trim()
        require(cleanPass.length >= 6) { "解密口令至少需要 6 位字符" }
        val file = File(filePath)
        require(file.exists() && file.isFile) { "未找到指定备份文件：$filePath" }
        val plainZip = vault.decryptWithPassphrase(file.readBytes(), cleanPass)
        val entries = LinkedHashMap<String, ByteArray>()
        var manifest: JSONObject? = null
        var totalDecoded = 0L
        val maxRestoreBytes = 96L * 1024L * 1024L
        ZipInputStream(ByteArrayInputStream(plainZip)).use { zis ->
            while (true) {
                val entry = zis.nextEntry ?: break
                val name = entry.name.replace('\\', '/')
                if (name.isEmpty() || name.startsWith("/") || name.split('/').any { it == ".." }) {
                    throw SecurityException("备份包含非法路径条目：$name")
                }
                if (!entry.isDirectory) {
                    val out = ByteArrayOutputStream()
                    val buf = ByteArray(8192)
                    while (true) {
                        val n = zis.read(buf)
                        if (n <= 0) break
                        totalDecoded += n.toLong()
                        if (totalDecoded > maxRestoreBytes) {
                            throw IllegalStateException("备份解压体积超过安全上限（96 MB）")
                        }
                        out.write(buf, 0, n)
                    }
                    val bytes = out.toByteArray()
                    if (name == "backup-manifest.json") {
                        manifest = runCatching { JSONObject(String(bytes, Charsets.UTF_8)) }.getOrNull()
                    } else {
                        entries[name] = bytes
                    }
                }
                zis.closeEntry()
            }
        }
        return Pair(manifest, entries)
    }

    fun previewEncryptedBackup(filePath: String, passphrase: String): Map<String, Any?> = runCatching {
        val (manifest, entries) = readAndVerifyBackupArchive(filePath, passphrase)
        val corrupted = mutableListOf<String>()
        val manifestIncluded = manifest?.optJSONArray("included")
        if (manifestIncluded != null) {
            for (i in 0 until manifestIncluded.length()) {
                val item = manifestIncluded.optJSONObject(i) ?: continue
                val p = item.optString("path", "")
                val expectedSha = item.optString("sha256", "")
                val actualBytes = entries[p]
                if (actualBytes == null || (expectedSha.isNotEmpty() && sha256Hex(actualBytes) != expectedSha)) {
                    corrupted.add(p)
                }
            }
        }
        val skippedPreview = mutableListOf<Map<String, Any>>()
        val manifestSkipped = manifest?.optJSONArray("skipped")
        if (manifestSkipped != null) {
            for (i in 0 until minOf(manifestSkipped.length(), 20)) {
                val item = manifestSkipped.optJSONObject(i) ?: continue
                skippedPreview.add(
                    mapOf(
                        "path" to item.optString("path", ""),
                        "bytes" to item.optLong("bytes", 0L),
                        "reason" to item.optString("reason", "")
                    )
                )
            }
        }
        val totalBytes = entries.values.sumOf { it.size.toLong() }
        mapOf(
            "ok" to true,
            "schema" to (manifest?.optString("schema", "grassbag-backup-v1") ?: "grassbag-backup-v1"),
            "scope" to (manifest?.optString("scope", "runtime-meta + /root/.dsh") ?: "runtime-meta + /root/.dsh"),
            "createdAtMs" to (manifest?.optLong("createdAtMs", File(filePath).lastModified()) ?: File(filePath).lastModified()),
            "includedCount" to entries.size,
            "skippedCount" to (manifestSkipped?.length() ?: 0),
            "skippedFiles" to skippedPreview,
            "totalBytes" to totalBytes,
            "integrityOk" to corrupted.isEmpty(),
            "corruptedEntries" to corrupted,
            "sampleEntries" to entries.keys.take(25).toList()
        )
    }.getOrElse { mapOf("ok" to false, "error" to (it.message ?: "preview_backup_error")) }

    fun restoreEncryptedBackup(filePath: String, passphrase: String, done: (Map<String, Any?>) -> Unit) {
        worker.execute {
            if (bootstrapRunning.get() || upgradeInProgress.get()) {
                done(mapOf("ok" to false, "error" to "当前正在部署或升级运行环境，请稍后再执行恢复"))
                return@execute
            }
            try {
                val (manifest, entries) = readAndVerifyBackupArchive(filePath, passphrase)
                val manifestIncluded = manifest?.optJSONArray("included")
                if (manifestIncluded != null) {
                    for (i in 0 until manifestIncluded.length()) {
                        val item = manifestIncluded.optJSONObject(i) ?: continue
                        val p = item.optString("path", "")
                        val expectedSha = item.optString("sha256", "")
                        val actualBytes = entries[p]
                        if (actualBytes == null || (expectedSha.isNotEmpty() && sha256Hex(actualBytes) != expectedSha)) {
                            done(mapOf("ok" to false, "error" to "备份完整性校验未通过（条目 $p 缺失或校验和不匹配），已中止恢复"))
                            return@execute
                        }
                    }
                }
                if (entries.isEmpty()) {
                    done(mapOf("ok" to false, "error" to "备份归档中没有任何可恢复的文件"))
                    return@execute
                }
                val wasRunning = isEngineAlive() && engineState == "running"
                if (wasRunning) {
                    stopEngineSync(keepForegroundService = true, emitStoppedEvent = false)
                }
                val ts = System.currentTimeMillis()
                val dshDir = File(homeDir, ".dsh")
                val dshPreRestore = File(homeDir, ".dsh.pre-restore-$ts")
                val hasHomeEntries = entries.keys.any { it.startsWith("home/.dsh/") }
                var restoredCount = 0
                try {
                    if (hasHomeEntries && dshDir.exists()) {
                        TarGzExtractor.deleteTreeNoFollow(dshPreRestore)
                        dshDir.copyRecursively(dshPreRestore, overwrite = true)
                    }
                    val canonicalHome = homeDir.canonicalFile
                    for ((rel, bytes) in entries) {
                        val dest: File = when {
                            rel == "apt-manifest.json" -> aptFile
                            rel.startsWith("home/.dsh/") -> {
                                val sub = rel.removePrefix("home/")
                                val candidate = File(homeDir, sub).canonicalFile
                                if (!candidate.path.startsWith(canonicalHome.path + File.separator)) {
                                    throw SecurityException("越界路径已被拦截：$rel")
                                }
                                candidate
                            }
                            else -> continue
                        }
                        dest.parentFile?.mkdirs()
                        FileOutputStream(dest).use { it.write(bytes) }
                        restoredCount++
                    }
                    if (dshPreRestore.exists()) {
                        runCatching { TarGzExtractor.deleteTreeNoFollow(dshPreRestore) }
                    }
                } catch (t: Throwable) {
                    if (dshPreRestore.exists()) {
                        runCatching {
                            TarGzExtractor.deleteTreeNoFollow(dshDir)
                            dshPreRestore.renameTo(dshDir)
                        }
                    }
                    throw t
                }
                if (wasRunning) {
                    startEngineSync()
                }
                done(
                    mapOf(
                        "ok" to true,
                        "restoredCount" to restoredCount,
                        "restartedEngine" to wasRunning,
                        "status" to getStatus()
                    )
                )
            } catch (t: Throwable) {
                done(mapOf("ok" to false, "error" to (t.message ?: "restore_backup_error")))
            }
        }
    }

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
                val rawHostCwd = mapContainerWorkdirToHost(requestedCwd)
                effectiveCwd = if (rawHostCwd.isDirectory) requestedCwd else "/root/workspace"
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
            val displaced = shells.put(tabId, session)
            if (displaced != null && displaced !== session) {
                runCatching { displaced.proc.outputStream.close() }
                worker.execute {
                    killSubprocessGroup(displaced.proc, graceMs = 200L)
                    runCatching { displaced.proc.inputStream.close() }
                }
            }
            worker.execute {
                val cbuf = CharArray(4096)
                var handshakeHandled = !usesPtyBridge
                var oscScanRemaining = 4096
                val pendingOsc = StringBuilder()
                val ptyMarker = "\u001b]777;gbmode;pty\u0007"
                val pipeMarker = "\u001b]777;gbmode;pipe\u0007"
                runCatching {
                    InputStreamReader(proc.inputStream, Charsets.UTF_8).use { reader ->
                        while (true) {
                            val n = reader.read(cbuf)
                            if (n <= 0) break
                            var chunk = String(cbuf, 0, n)
                            if (!handshakeHandled) {
                                pendingOsc.append(chunk)
                                val combined = pendingOsc.toString()
                                val hasPty = combined.contains(ptyMarker)
                                val hasPipe = combined.contains(pipeMarker)
                                if (hasPty || hasPipe) {
                                    handshakeHandled = true
                                    chunk = combined
                                        .replace(ptyMarker, "")
                                        .replace(pipeMarker, "")
                                    pendingOsc.clear()
                                    if (hasPipe) {
                                        emit("local_term_mode", mapOf("tabId" to tabId, "isPty" to false, "mode" to "pipe"))
                                    }
                                } else {
                                    oscScanRemaining -= n
                                    if (oscScanRemaining <= 0) {
                                        handshakeHandled = true
                                        chunk = combined
                                        pendingOsc.clear()
                                    } else {
                                        // Flush safe prefix immediately (e.g. PRoot stderr warnings) while
                                        // holding any trailing partial ESC sequence for the next read.
                                        val lastEsc = combined.lastIndexOf('\u001b')
                                        if (lastEsc >= 0 && combined.length - lastEsc <= 24) {
                                            chunk = combined.substring(0, lastEsc)
                                            pendingOsc.clear()
                                            pendingOsc.append(combined.substring(lastEsc))
                                        } else {
                                            chunk = combined
                                            pendingOsc.clear()
                                        }
                                    }
                                }
                            }
                            if (chunk.isNotEmpty()) {
                                enqueueLocalTermData(tabId, chunk, expectedSession = session)
                            }
                        }
                        if (pendingOsc.isNotEmpty()) {
                            enqueueLocalTermData(tabId, pendingOsc.toString(), expectedSession = session)
                            pendingOsc.clear()
                        }
                    }
                }
                runCatching { proc.outputStream.close() }
                val exit = runCatching { proc.waitFor() }.getOrDefault(0)
                flushLocalTermDataFor(tabId, expectedSession = session, exitCode = exit)
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
        // Deliver SIGTERM directly via OS signal so a blocked stdin pipe can never deadlock termination!
        if (cleanSig == "SIGTERM") {
            extractProcessPid(session.proc)?.let { pid ->
                if (pid > 1) return runCatching { Os.kill(pid, 15); true }.getOrDefault(false)
            }
            return runCatching { session.proc.destroy(); true }.getOrDefault(false)
        }
        if (session.usesPtyBridge) {
            return writeLocalShell(tabId, "\u001b]777;gbsignal;$cleanSig\u0007")
        }
        return writeLocalShell(tabId, "\u0003")
    }

    fun closeLocalShell(tabId: String) {
        shells.remove(tabId)?.let { session ->
            synchronized(termPendingLock) {
                termPendingBuffers.remove(tabId)
            }
            // Close stdin & signal the whole subprocess group so pty-bridge / bash / grandchildren
            // exit cleanly without leaking orphan servers, pipe FDs, or blocked reader threads!
            runCatching { session.proc.outputStream.close() }
            worker.execute {
                killSubprocessGroup(session.proc, graceMs = 280L)
                runCatching { session.proc.inputStream.close() }
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

    private fun sendProgress(
        stage: String,
        percent: Int,
        message: String,
        extra: Map<String, Any?> = emptyMap(),
        force: Boolean = false
    ) {
        val now = System.currentTimeMillis()
        val shouldEmit = synchronized(progressLock) {
            val isEdge = force || percent <= 0 || percent >= 100 || stage != lastProgressStage
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
            val payload = LinkedHashMap<String, Any?>(4 + extra.size)
            payload["stage"] = stage
            payload["percent"] = percent
            payload["message"] = message
            if (extra.isNotEmpty()) payload.putAll(extra)
            emit("runtime_progress", payload)
        }
    }

    companion object {
        private const val TAG = "GrassBagRuntime"
        const val LOCAL_DSH_PORT = 13080
        private val DSH_WEB_URL_REGEX = Regex("""https?://127\.0\.0\.1:\d+/\?token=[^\s\u001b"'<>)]+""")
        private val TOKEN_QUERY_REGEX = Regex("""([?&]token=)[^\s&"'#]+""", RegexOption.IGNORE_CASE)
        private val GROUP_GID_REGEX = Regex(""":x:(\d+):""")
        private val WHITESPACE_REGEX = Regex("""\s+""")
        private val DIGITS_REGEX = Regex("""\d+""")

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

        fun onActivityBackgrounded(appContext: Context) {
            instance?.onActivityBackgrounded()
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
                    // Skip booting the local Ubuntu/DSH container on cold launch if the user's
                    // active host is a remote desktop/server!
                    val savedPrefsRaw = appCtx
                        .getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                        .getString("flutter.grassbag_app_prefs_v2", null)
                    val savedHostId = savedPrefsRaw?.let {
                        runCatching { JSONObject(it).optString("activeHostId", "local") }.getOrNull()
                    } ?: "local"
                    val vault = KeystoreVault.getInstance(appCtx)
                    val controller = getInstance(appCtx, vault)
                    if (savedHostId == "local" || savedHostId.isBlank()) {
                        controller.prewarmIfReady()
                    } else {
                        Log.i(TAG, "prewarmInBackground: activeHostId=$savedHostId (remote), skipping local DSH prewarm")
                    }
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
