/**
 * GrassBag Android Container Compatibility & Fast-Boot Shim (`android-shim.mjs`)
 * Loaded via: `--import=/opt/shims/android-shim.mjs` (for DSH engine)
 *
 * Solves Android unprivileged container (tawcroot / PRoot) compatibility and cold-start
 * bottlenecks without patching `@deepseek-ai/dsh`:
 * 1. Missing or unreadable `/etc/resolv.conf` -> safe DNS server fallback
 * 2. Cross-mount `EXDEV` errors on `fs.rename` between `/root`, `/tmp`, `/sdcard`
 * 3. Restricted `/proc/stat` or `/proc/net` causing `os.cpus()` / `os.networkInterfaces()` errors
 * 4. High-hit self-uninstalling boot-time fs cache (`realpathSync`, `existsSync`, `statSync`,
 *    `lstatSync`, `readFileSync` for `package.json`, URL path support, pre-populated `node_modules`
 *    index, and negative caching of `/opt/node_modules`, `/node_modules`, `/root/.dsh/profiles/...`)
 * 5. Automatic V8 `module.flushCompileCache()` persistence after `dsh web:` boots
 */
import dns from 'node:dns';
import fs from 'node:fs';
import * as nodeModule from 'node:module';
import net from 'node:net';
import os from 'node:os';
import { basename as pathBasename, dirname as pathDirname, join as pathJoin, resolve as pathResolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMainThread } from 'node:worker_threads';

const { syncBuiltinESMExports } = nodeModule;

// 0. Android mobile dual-stack & TCP keep-alive hardening:
// - Prefer IPv4 first so glibc `getaddrinfo()` never stalls on blackholed mobile/Wi-Fi AAAA routes.
// - Enable Happy Eyeballs (`autoSelectFamily`) with a brisk 500ms fallback timeout.
// - Enable 15s TCP keep-alive probes on outbound non-loopback sockets so mobile carrier NATs
//   and Android OEM background firewalls (OriginOS / HyperOS / ColorOS) never silently reap
//   long-lived DeepSeek reasoning/SSE connections while operating other apps!
try {
  dns.setDefaultResultOrder?.('ipv4first');
} catch {}
try {
  net.setDefaultAutoSelectFamily?.(true);
  net.setDefaultAutoSelectFamilyAttemptTimeout?.(500);
} catch {}

const isLocalAndroid = process.env.GBRIDGE_LOCAL_ANDROID === '1';

if (isLocalAndroid && typeof net.Socket?.prototype?.connect === 'function') {
  const origSocketConnect = net.Socket.prototype.connect;
  net.Socket.prototype.connect = function grassbagKeepAliveConnect(...args) {
    const first = args[0];
    const isUnix =
      typeof first === 'string' ||
      (first && typeof first === 'object' && typeof first.path === 'string' && first.path.length > 0) ||
      (Array.isArray(first) && first[0] && typeof first[0].path === 'string');
    if (!isUnix) {
      const host =
        typeof first === 'object' && first !== null
          ? (Array.isArray(first) ? first[0]?.host : first.host)
          : (typeof args[1] === 'string' ? args[1] : undefined);
      const isLoopback =
        host === '127.0.0.1' || host === '::1' || host === 'localhost' || host === '::ffff:127.0.0.1';
      if (!isLoopback) {
        this.once('connect', () => {
          try {
            this.setKeepAlive(true, 15_000);
            this.setNoDelay(true);
          } catch {}
        });
      }
    }
    return Reflect.apply(origSocketConnect, this, args);
  };
}

// Schedule V8 compile-cache flushes for long-running DSH daemons that never exit cleanly
// (force-stop / kill bypasses Node's default exit-only compile-cache flush).
let compileCacheFlushScheduled = false;
function flushCompileCacheNow() {
  if (!isMainThread || !process.env.NODE_COMPILE_CACHE) return;
  const flushFn = nodeModule.flushCompileCache ?? nodeModule.default?.flushCompileCache;
  if (typeof flushFn === 'function') {
    try { flushFn(); } catch {}
  }
}
function scheduleCompileCacheFlush(delaysMs = [1200, 6000, 22000]) {
  if (compileCacheFlushScheduled || !isMainThread || !process.env.NODE_COMPILE_CACHE) return;
  const flushFn = nodeModule.flushCompileCache ?? nodeModule.default?.flushCompileCache;
  if (typeof flushFn !== 'function') return;
  compileCacheFlushScheduled = true;
  for (const ms of delaysMs) {
    const t = setTimeout(() => {
      flushCompileCacheNow();
    }, ms);
    t.unref?.();
  }
}
if (isMainThread && process.env.NODE_COMPILE_CACHE) {
  for (const sig of ['SIGTERM', 'SIGINT']) {
    try {
      process.prependListener(sig, () => {
        flushCompileCacheNow();
      });
    } catch {}
  }
}

// 1. Ensure DNS servers stay populated and track `/etc/resolv.conf` changes across Wi-Fi/5G/VPN switches.
let lastResolvMtimeMs = 0;
function syncDnsFromResolvConf(force = false) {
  try {
    const fallback = (process.env.GBRIDGE_DNS_SERVERS || '223.5.5.5,8.8.8.8,1.1.1.1')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    let parsed = [];
    try {
      const st = fs.statSync('/etc/resolv.conf');
      if (!force && st.mtimeMs === lastResolvMtimeMs) return;
      lastResolvMtimeMs = st.mtimeMs;
      const raw = fs.readFileSync('/etc/resolv.conf', 'utf8');
      for (const line of raw.split('\n')) {
        const m = /^\s*nameserver\s+([^\s#]+)/.exec(line);
        if (!m) continue;
        const ip = m[1].trim();
        if (!ip || ip === '127.0.0.1' || ip === '127.0.0.53' || ip === '::1') continue;
        if (ip.toLowerCase().startsWith('fe80:')) continue; // Unscoped IPv6 link-local is unroutable.
        if (!parsed.includes(ip)) parsed.push(ip);
      }
    } catch {}
    const effective = parsed.length > 0 ? parsed : fallback;
    if (effective.length > 0) {
      const current = dns.getServers();
      const same = Array.isArray(current) &&
        current.length === effective.length &&
        current.every((v, idx) => v === effective[idx]);
      if (!same) dns.setServers(effective);
    }
  } catch {
    // Ignore if runtime locks DNS resolver.
  }
}
syncDnsFromResolvConf(true);
if (isMainThread) {
  const dnsTimer = setInterval(() => syncDnsFromResolvConf(false), 2500);
  dnsTimer.unref?.();
}

// 1b. Resilient `globalThis.fetch` wrapper on Android local runtime:
// When GrassBag moves to the background (e.g. controlling another app via Accessibility or
// user switching apps on OriginOS/HyperOS/ColorOS), OEM firewalls and NATs often drop or
// half-close pooled undici keep-alive TLS sockets, causing `fetch()` to reject BEFORE headers
// arrive (`UND_ERR_SOCKET` / `ECONNRESET` / `other side closed` -> `[TRANSPORT] DeepSeek Messages transport failed`).
// Retrying pre-response socket failures on a FRESH connection (`connection: close`) with DNS
// refresh transparently recovers without duplicating responses or corrupting streams.
if (isLocalAndroid && typeof globalThis.fetch === 'function' && process.env.GBRIDGE_FETCH_RESILIENCE !== '0') {
  const origFetch = globalThis.fetch.bind(globalThis);
  const RETRYABLE_CODES = new Set([
    'UND_ERR_SOCKET',
    'UND_ERR_CONNECT_TIMEOUT',
    'UND_ERR_HEADERS_TIMEOUT',
    'UND_ERR_CLOSED',
    'UND_ERR_DESTROYED',
    'ECONNRESET',
    'EPIPE',
    'ETIMEDOUT',
    'EAI_AGAIN',
    'ENOTFOUND',
    'EHOSTUNREACH',
    'ENETUNREACH',
    'ECONNABORTED',
    'ECONNREFUSED',
    'ERR_SOCKET_CLOSED',
    'ERR_SSL_DECRYPTION_FAILED_OR_BAD_RECORD_MAC',
    'ERR_SSL_UNEXPECTED_EOF_WHILE_READING',
  ]);

  const extractUrlString = (input) => {
    if (typeof input === 'string') return input;
    if (input instanceof URL) return input.href;
    if (input && typeof input === 'object' && typeof input.url === 'string') return input.url;
    return '';
  };

  const isLoopbackUrl = (urlStr) => {
    try {
      const u = new URL(urlStr);
      const h = u.hostname.toLowerCase();
      return h === '127.0.0.1' || h === 'localhost' || h === '::1' || h === '[::1]';
    } catch {
      return false;
    }
  };

  const isBodyReplayable = (input, init) => {
    const body = init?.body;
    if (body !== undefined && body !== null) {
      if (
        typeof body === 'string' ||
        body instanceof ArrayBuffer ||
        ArrayBuffer.isView(body) ||
        body instanceof URLSearchParams ||
        (typeof Blob !== 'undefined' && body instanceof Blob)
      ) {
        return true;
      }
      return false;
    }
    // If caller passed a Request object with a body stream, avoid replaying consumed Request.
    if (input && typeof input === 'object' && !(input instanceof URL) && input.body !== undefined && input.body !== null) {
      return false;
    }
    return true;
  };

  const isRetryableTransportError = (err) => {
    if (!err || typeof err !== 'object') return false;
    if (err.name === 'AbortError' || err.name === 'TimeoutError') return false;
    let cur = err;
    for (let depth = 0; cur && depth < 5; depth++) {
      const code = typeof cur.code === 'string' ? cur.code : '';
      if (code && RETRYABLE_CODES.has(code)) return true;
      const msg = typeof cur.message === 'string' ? cur.message.toLowerCase() : '';
      if (
        msg.includes('fetch failed') ||
        msg.includes('other side closed') ||
        msg.includes('socket hang up') ||
        msg.includes('econnreset') ||
        msg.includes('etimedout') ||
        msg.includes('eai_again') ||
        msg.includes('enotfound') ||
        msg.includes('ehostunreach') ||
        msg.includes('enetunreach') ||
        msg.includes('connect timeout') ||
        msg.includes('tls') ||
        msg.includes('unexpected eof')
      ) {
        return true;
      }
      cur = cur.cause;
    }
    return false;
  };

  const sleepWithSignal = (ms, signal) => new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(signal.reason ?? Object.assign(new Error('Aborted'), { name: 'AbortError' }));
      return;
    }
    const onAbort = () => {
      clearTimeout(timer);
      reject(signal.reason ?? Object.assign(new Error('Aborted'), { name: 'AbortError' }));
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener?.('abort', onAbort);
      resolve();
    }, ms);
    signal?.addEventListener?.('abort', onAbort, { once: true });
  });

  const withFreshConnectionHeader = (init) => {
    const headers = new Headers(init?.headers || undefined);
    // Force a clean non-pooled TCP/TLS handshake on retry so a poisoned undici pool slot is bypassed!
    headers.set('connection', 'close');
    return { ...(init || {}), headers };
  };

  globalThis.fetch = async function grassbagResilientFetch(input, init) {
    const urlStr = extractUrlString(input);
    const signal = init?.signal ?? (input && typeof input === 'object' ? input.signal : undefined);
    const canRetry = Boolean(urlStr) && !isLoopbackUrl(urlStr) && isBodyReplayable(input, init);
    const delaysMs = [350, 900, 1800];
    let attempt = 0;
    while (true) {
      try {
        const effectiveInit = attempt === 0 ? init : withFreshConnectionHeader(init);
        return await origFetch(input, effectiveInit);
      } catch (err) {
        if (
          !canRetry ||
          attempt >= delaysMs.length ||
          signal?.aborted ||
          !isRetryableTransportError(err)
        ) {
          throw err;
        }
        syncDnsFromResolvConf(true);
        const baseDelay = delaysMs[attempt++];
        const jittered = Math.round(baseDelay * (0.85 + Math.random() * 0.3));
        await sleepWithSignal(jittered, signal);
      }
    }
  };
}

// 2. Patch fs.promises.rename, fs.rename & fs.renameSync to fall back cleanly & atomically on EXDEV across bind mounts.
let exdevNonce = 0;
function makeExdevTempSibling(newPath) {
  const target = typeof newPath === 'string' ? newPath : fileURLToPath(newPath);
  const dir = pathDirname(target);
  const base = pathBasename(target);
  exdevNonce = (exdevNonce + 1) & 0x7fffffff;
  return pathJoin(dir, `.${base}.gb-exdev-${process.pid}-${exdevNonce}.tmp`);
}

const origRenameAsync = fs.promises.rename.bind(fs.promises);
fs.promises.rename = async function grassbagSafeRename(oldPath, newPath) {
  try {
    return await origRenameAsync(oldPath, newPath);
  } catch (err) {
    if (err && err.code === 'EXDEV') {
      const tmp = makeExdevTempSibling(newPath);
      try {
        await fs.promises.cp(oldPath, tmp, { recursive: true, force: true, verbatimSymlinks: true });
        await origRenameAsync(tmp, newPath);
      } catch (copyErr) {
        try { await fs.promises.rm(tmp, { recursive: true, force: true }); } catch {}
        throw copyErr;
      }
      await fs.promises.rm(oldPath, { recursive: true, force: true });
      return;
    }
    throw err;
  }
};

const origRenameCb = fs.rename.bind(fs);
fs.rename = function grassbagSafeRenameCb(oldPath, newPath, callback) {
  origRenameCb(oldPath, newPath, (err) => {
    if (err && err.code === 'EXDEV') {
      fs.promises
        .rename(oldPath, newPath)
        .then(() => callback(null), (e) => callback(e));
      return;
    }
    callback(err);
  });
};

const origRenameSync = fs.renameSync.bind(fs);
fs.renameSync = function grassbagSafeRenameSync(oldPath, newPath) {
  try {
    return origRenameSync(oldPath, newPath);
  } catch (err) {
    if (err && err.code === 'EXDEV') {
      const tmp = makeExdevTempSibling(newPath);
      try {
        fs.cpSync(oldPath, tmp, { recursive: true, force: true, verbatimSymlinks: true });
        origRenameSync(tmp, newPath);
      } catch (copyErr) {
        try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
        throw copyErr;
      }
      fs.rmSync(oldPath, { recursive: true, force: true });
      return;
    }
    throw err;
  }
};

// 3. Guard os.cpus() against empty array on SELinux-restricted Android /proc/stat.
const origCpus = os.cpus.bind(os);
os.cpus = function grassbagSafeCpus() {
  try {
    const list = origCpus();
    if (Array.isArray(list) && list.length > 0) return list;
  } catch {
    // Fall through to synthetic quad-core descriptor so libuv/Node pools scale normally.
  }
  return [
    { model: 'ARMv8 Android', speed: 2200, times: { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 } },
    { model: 'ARMv8 Android', speed: 2200, times: { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 } },
  ];
};

// 4. Guard os.networkInterfaces() against EACCES netlink restrictions on Android 14/15 SELinux.
const origNetIfaces = os.networkInterfaces.bind(os);
os.networkInterfaces = function grassbagSafeNetworkInterfaces() {
  try {
    const ifaces = origNetIfaces();
    if (ifaces && Object.keys(ifaces).length > 0) return ifaces;
  } catch {
    // Fall through to safe loopback descriptor.
  }
  return {
    lo: [{
      address: '127.0.0.1',
      netmask: '255.0.0.0',
      family: 'IPv4',
      mac: '00:00:00:00:00:00',
      internal: true,
      cidr: '127.0.0.1/8',
    }],
  };
};

// 5. High-hit self-uninstalling boot-time fs cache gated strictly on `GBRIDGE_DSH_BOOT=1`
// (never interferes with user scripts or shells).
const isDshBoot =
  isMainThread &&
  (process.env.GBRIDGE_DSH_BOOT === '1' ||
    (process.env.GBRIDGE_LOCAL_ANDROID === '1' && process.argv[1]?.includes('@deepseek-ai/dsh')));

if (isDshBoot && process.env.GBRIDGE_BOOT_CACHE !== '0') {
  try {
    const ROOTS = [
      '/opt/dsh-slots/',
      '/opt/shims/',
      '/usr/local/lib/node_modules/',
      '/opt/node_modules/',
      '/node_modules/',
    ];
    const PASS = Symbol('pass');
    const origLstat = fs.lstatSync;
    const origStat = fs.statSync;
    const origRealpath = fs.realpathSync;
    const origRealpathNative = fs.realpathSync.native;
    const origExists = fs.existsSync;
    const origReadFile = fs.readFileSync;
    const origStdoutWrite = process.stdout.write;

    const components = new Map();
    const statsCache = new Map(); // resolved path -> Stats | { code }
    const manifests = new Map();

    // Pre-seed truly immutable absent parent node_modules trees (never negative-cache
    // mutable `/root/.dsh/profiles/web/node_modules` so plugin installs work immediately!).
    for (const absentDir of ['/opt/node_modules', '/node_modules']) {
      try {
        origLstat.call(fs, absentDir);
      } catch (err) {
        if (err?.code === 'ENOENT' || err?.code === 'ENOTDIR') {
          components.set(absentDir, { code: err.code, at: absentDir });
        }
      }
    }

    // Pre-populate `/opt/dsh-slots/current` symlink + top-level package names via 2 fast `getdents64` calls!
    try {
      const slotReal = origRealpathNative.call(fs.realpathSync, '/opt/dsh-slots/current');
      if (typeof slotReal === 'string' && slotReal.startsWith('/opt/dsh-slots/')) {
        components.set('/opt', '/opt');
        components.set('/opt/dsh-slots', '/opt/dsh-slots');
        components.set('/opt/dsh-slots/current', { link: slotReal });
        components.set(slotReal, slotReal);
        const nmDir = `${slotReal}/node_modules`;
        components.set(nmDir, nmDir);
        const topEntries = fs.readdirSync(nmDir, { withFileTypes: true });
        const topSet = new Set(topEntries.map((e) => e.name));
        for (const entry of topEntries) {
          const name = entry.name;
          if (name.startsWith('.') || entry.isSymbolicLink()) continue;
          const full = `${nmDir}/${name}`;
          if (name.startsWith('@')) {
            components.set(full, full);
            try {
              for (const sub of fs.readdirSync(full, { withFileTypes: true })) {
                if (!sub.isSymbolicLink()) {
                  components.set(`${full}/${sub.name}`, `${full}/${sub.name}`);
                }
              }
            } catch {}
          } else {
            components.set(full, full);
          }
        }
        // Cache known-present vs absent check helper for direct `node_modules/<pkg>` lookups
        components.set(`${nmDir}/__indexed__`, { indexedTop: topSet });
      }
    } catch {
      // Fall back seamlessly to lazy lstat caching.
    }

    const toPathStr = (p) => {
      if (typeof p === 'string') return p;
      if (p instanceof URL && p.protocol === 'file:') {
        try { return fileURLToPath(p); } catch { return null; }
      }
      return null;
    };

    const inRoots = (p) => ROOTS.some((r) => (p + '/').startsWith(r));
    const cacheable = (p) => inRoots(p) || ROOTS.some((r) => r.startsWith(p + '/'));
    const eligible = (p) =>
      typeof p === 'string' &&
      p.startsWith('/') &&
      !p.endsWith('/') &&
      !/(?:^|\/)\.{1,2}(?:\/|$)/u.test(p) &&
      inRoots(p);
    const isUtf8 = (o) =>
      o === 'utf8' ||
      o === 'utf-8' ||
      (o !== null && typeof o === 'object' && /^utf-?8$/i.test(o.encoding ?? '') && o.flag === undefined);
    const isStringRes = (o) =>
      o === undefined ||
      o === 'utf8' ||
      o === 'utf-8' ||
      (o !== null && typeof o === 'object' && (o.encoding === undefined || /^utf-?8$/i.test(o.encoding)));

    const makeMissing = (code, syscall, path) => {
      const msg = code === 'ENOTDIR' ? 'not a directory' : 'no such file or directory';
      return Object.assign(new Error(`${code}: ${msg}, ${syscall} '${path}'`), {
        errno: code === 'ENOTDIR' ? -20 : -2,
        code,
        syscall,
        path,
      });
    };

    function resolveCached(p) {
      if (!eligible(p)) return PASS;
      const direct = components.get(p);
      if (typeof direct === 'string') return direct;
      if (direct && typeof direct === 'object' && direct.code !== undefined) return direct;
      const parts = pathResolve(p).split('/');
      let cur = '';
      for (let i = 1; i < parts.length; i++) {
        const key = cur + '/' + parts[i];
        let hit = components.get(key);
        if (hit === undefined) {
          // Fast-path negative hit if parent is an indexed `node_modules` directory!
          const idxMeta = components.get(`${cur}/__indexed__`);
          if (idxMeta?.indexedTop && !idxMeta.indexedTop.has(parts[i])) {
            hit = { code: 'ENOENT', at: key };
            components.set(key, hit);
            return hit;
          }
          let st;
          try {
            st = origLstat.call(fs, key);
          } catch (err) {
            if (err?.code !== 'ENOENT' && err?.code !== 'ENOTDIR') return PASS;
            hit = { code: err.code, at: key };
            if (cacheable(cur)) components.set(key, hit);
            return hit;
          }
          if (st.isSymbolicLink()) {
            try {
              const target = origRealpathNative.call(fs.realpathSync, key);
              if (!inRoots(target)) return PASS;
              hit = { link: target };
            } catch {
              return PASS;
            }
          } else {
            hit = key;
            statsCache.set(key, st);
          }
          if (cacheable(key)) components.set(key, hit);
        }
        if (typeof hit === 'object') {
          if (hit.code !== undefined) return hit;
          cur = hit.link;
          continue;
        }
        cur = hit;
      }
      return cur || '/';
    }

    let active = true;
    let timer;

    function uninstallBootCache() {
      if (!active) return;
      active = false;
      components.clear();
      statsCache.clear();
      manifests.clear();
      if (timer) clearTimeout(timer);
      if (fs.realpathSync === cachedRealpathSync) fs.realpathSync = origRealpath;
      if (fs.existsSync === cachedExistsSync) fs.existsSync = origExists;
      if (fs.statSync === cachedStatSync) fs.statSync = origStat;
      if (fs.lstatSync === cachedLstatSync) fs.lstatSync = origLstat;
      if (fs.readFileSync === cachedReadFileSync) fs.readFileSync = origReadFile;
      if (process.stdout.write === watchStdout) process.stdout.write = origStdoutWrite;
      try { syncBuiltinESMExports(); } catch {}
    }

    function cachedRealpathSync(p, options) {
      if (active && isStringRes(options)) {
        const ps = toPathStr(p);
        if (ps) {
          const hit = resolveCached(ps);
          if (typeof hit === 'string') return hit;
          if (hit !== PASS) throw makeMissing(hit.code, 'lstat', hit.at);
        }
      }
      return Reflect.apply(origRealpath, this, arguments);
    }
    cachedRealpathSync.native = function cachedRealpathNative(p, options) {
      if (active && isStringRes(options)) {
        const ps = toPathStr(p);
        if (ps) {
          const hit = resolveCached(ps);
          if (typeof hit === 'string') return hit;
          if (hit !== PASS) throw makeMissing(hit.code, 'realpath', ps);
        }
      }
      return Reflect.apply(origRealpathNative, this, arguments);
    };

    function cachedExistsSync(p) {
      if (active) {
        const ps = toPathStr(p);
        if (ps) {
          const hit = resolveCached(ps);
          if (hit !== PASS) return typeof hit === 'string';
        }
      }
      return Reflect.apply(origExists, this, arguments);
    }

    function cachedStatSync(p, options) {
      if (active && (!options || (!options.bigint))) {
        const ps = toPathStr(p);
        if (ps && eligible(ps)) {
          const hit = resolveCached(ps);
          if (hit !== PASS) {
            if (typeof hit === 'object' && hit.code !== undefined) {
              if (options && options.throwIfNoEntry === false) return undefined;
              throw makeMissing(hit.code, 'stat', ps);
            }
            if (typeof hit === 'string') {
              const cached = statsCache.get(hit);
              if (cached) return cached;
              const st = Reflect.apply(origStat, this, arguments);
              if (st) statsCache.set(hit, st);
              return st;
            }
          }
        }
      }
      return Reflect.apply(origStat, this, arguments);
    }

    function cachedLstatSync(p, options) {
      if (active && (!options || (!options.bigint))) {
        const ps = toPathStr(p);
        if (ps && eligible(ps)) {
          const hit = resolveCached(ps);
          if (hit !== PASS) {
            if (typeof hit === 'object' && hit.code !== undefined) {
              if (options && options.throwIfNoEntry === false) return undefined;
              throw makeMissing(hit.code, 'lstat', ps);
            }
            // Serve positive lstat hits directly from statsCache when path had no symlink indirection
            if (typeof hit === 'string' && hit === ps) {
              const cached = statsCache.get(hit);
              if (cached) return cached;
            }
          }
        }
      }
      return Reflect.apply(origLstat, this, arguments);
    }

    function cachedReadFileSync(p, options) {
      if (active && isUtf8(options)) {
        const ps = toPathStr(p);
        if (ps && eligible(ps) && ps.endsWith('/package.json')) {
          let text = manifests.get(ps);
          if (text === undefined) {
            const hit = resolveCached(ps);
            if (typeof hit === 'string') {
              text = Reflect.apply(origReadFile, this, arguments);
              manifests.set(ps, text);
              return text;
            }
            if (hit !== PASS && typeof hit === 'object' && hit.code !== undefined) {
              throw makeMissing(hit.code, 'open', ps);
            }
          } else {
            return text;
          }
        }
      }
      return Reflect.apply(origReadFile, this, arguments);
    }

    function watchStdout(chunk, ...rest) {
      const res = Reflect.apply(origStdoutWrite, this, [chunk, ...rest]);
      if (!active) return res;
      const text =
        typeof chunk === 'string'
          ? chunk
          : ArrayBuffer.isView(chunk)
            ? Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength).toString()
            : String(chunk);
      if (text.includes('?token=') || text.includes('dsh web:')) {
        uninstallBootCache();
        scheduleCompileCacheFlush([1200, 6000, 22000]);
      } else if (text.includes('UDS listener ready')) {
        scheduleCompileCacheFlush([1200, 6000, 22000]);
      }
      return res;
    }

    fs.realpathSync = cachedRealpathSync;
    fs.existsSync = cachedExistsSync;
    fs.statSync = cachedStatSync;
    fs.lstatSync = cachedLstatSync;
    fs.readFileSync = cachedReadFileSync;
    process.stdout.write = watchStdout;
    const rawCacheTtl = Number(process.env.GBRIDGE_BOOT_CACHE_TIMEOUT_MS);
    const bootCacheTtlMs =
      Number.isFinite(rawCacheTtl) && rawCacheTtl >= 15_000
        ? Math.min(rawCacheTtl, 180_000)
        : 90_000;
    timer = setTimeout(() => {
      uninstallBootCache();
      scheduleCompileCacheFlush([1000]);
    }, bootCacheTtlMs);
    timer.unref?.();
  } catch {
    // Boot cache is purely opportunistic; never impede launch.
  }
} else if (isDshBoot) {
  scheduleCompileCacheFlush([8000, 20000]);
}

try {
  syncBuiltinESMExports();
} catch {
  // Best-effort sync for ESM named imports.
}
