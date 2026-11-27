import { createServer } from 'node:http';
import { chmodSync, existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir, hostname, networkInterfaces } from 'node:os';
import { dirname, join } from 'node:path';
import { randomBytes, randomUUID } from 'node:crypto';
import {
  GbridgeError,
  Router,
  admitRequest,
  applyLoopbackCors,
  lanCookieNameForPort,
  parseUrl,
  readRawBody,
  safeEqualString,
  sendError,
  sendJson,
  signLanCookieValue,
} from './http-util.js';
import { rejectUpgrade, upgradeWebSocket } from './ws-server.js';
import { GatewayAdapter } from './gateway.js';
import { SessionNormalizer } from './normalizer.js';
import { StreamHub } from './stream-hub.js';
import { SduiRegistry } from './sdui.js';
import { mountPhoneTools } from './phone-tools.js';
import { repairLegacyInlineImageSessions } from './session-image-repair.js';
import { buildQrPathData, encodeQrMatrix } from './qr-svg.js';
import { renderPairingDashboardHtml } from './pairing-ui.js';
import { detectDshVersion, registerMetaDomain } from './domains/meta.js';
import { registerChatAndInteractionsDomain } from './domains/chat.js';
import { registerWorkspaceDomain } from './domains/workspace.js';
import { registerSystemDomain } from './domains/system.js';

export const name = 'gbridge';
export const PREFIX = '/gbridge/v1';
export const STREAM_PATH = `${PREFIX}/stream`;
export const UI_PATH = '/gbridge/ui';
export const PAIRING_API_PATH = '/api/gbridge/pairing';

const PKG_VERSION = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version;

// Latch Android container secrets once in module-private memory before scrubbing `process.env`.
// Prefer one-time `0600` `GBRIDGE_SECRETS_FILE` (unlinked immediately after read) so `/proc/<pid>/environ`
// never exposes privileged bearer tokens to same-UID child/terminal processes.
const latchedAndroidEnv = (() => {
  let token = process.env.GBRIDGE_TOKEN || undefined;
  let phoneToken = process.env.GBRIDGE_PHONE_TOKEN || undefined;
  const secretsFile = process.env.GBRIDGE_SECRETS_FILE || undefined;
  if (secretsFile) {
    try {
      const raw = readFileSync(secretsFile, 'utf8');
      const parsed = JSON.parse(raw);
      if (typeof parsed?.token === 'string' && parsed.token.trim()) token = parsed.token.trim();
      if (typeof parsed?.phoneToken === 'string' && parsed.phoneToken.trim()) phoneToken = parsed.phoneToken.trim();
    } catch {}
    try { unlinkSync(secretsFile); } catch {}
    delete process.env.GBRIDGE_SECRETS_FILE;
  }
  return {
    token,
    unixSocket: process.env.GBRIDGE_UNIX_SOCKET || undefined,
    phoneSocket: process.env.GBRIDGE_PHONE_SOCKET || undefined,
    phoneToken,
    pidFile: process.env.GBRIDGE_PID_FILE || undefined,
    isLocalAndroid: process.env.GBRIDGE_LOCAL_ANDROID === '1',
  };
})();
if (latchedAndroidEnv.unixSocket) {
  delete process.env.GBRIDGE_TOKEN;
  delete process.env.GBRIDGE_PHONE_TOKEN;
}

const activeUdsListeners = new Map();
const activeLanListeners = new Map();
let udsGenCounter = 0;
let lanGenCounter = 0;
let pidFileGenCounter = 0;

function isLoopbackHost(rawHost) {
  const h = String(rawHost || '').trim().toLowerCase().replace(/^\[|\]$/g, '');
  if (!h) return true;
  return h === 'localhost' ||
    h.endsWith('.localhost') ||
    h === '::1' ||
    h === '0:0:0:0:0:0:0:1' ||
    h.startsWith('127.') ||
    h.startsWith('::ffff:127.');
}

function getLanTokenFilePath() {
  const dshHome = process.env.DSH_HOME || join(homedir(), '.dsh');
  return { dshHome, tokenFile: join(dshHome, 'gbridge-lan-token') };
}

function resolveOrCreateLanToken(explicitToken) {
  if (typeof explicitToken === 'string' && explicitToken.trim().length >= 8) {
    return explicitToken.trim();
  }
  const { dshHome, tokenFile } = getLanTokenFilePath();
  try {
    if (existsSync(tokenFile)) {
      const saved = readFileSync(tokenFile, 'utf8').trim();
      if (saved.length >= 12) return saved;
    }
    mkdirSync(dshHome, { recursive: true, mode: 0o700 });
    const fresh = randomBytes(18).toString('base64url');
    writeFileSync(tokenFile, `${fresh}\n`, { mode: 0o600 });
    return fresh;
  } catch {
    return randomBytes(18).toString('base64url');
  }
}

function persistRotatedLanToken() {
  const fresh = randomBytes(18).toString('base64url');
  const { dshHome, tokenFile } = getLanTokenFilePath();
  try {
    mkdirSync(dshHome, { recursive: true, mode: 0o700 });
    writeFileSync(tokenFile, `${fresh}\n`, { mode: 0o600 });
  } catch {}
  return fresh;
}

/**
 * Enumerate reachable LAN & Tailscale IPv4 addresses sorted by recommendation priority.
 */
export function listReachableNetworkInterfaces() {
  const lan = [];
  const tailscale = [];
  const other = [];
  const skipIfaceRe = /^(docker|br-|veth|virbr|vmnet|lo|awdl|llw|anpi|bridge)/i;
  const seen = new Set();
  try {
    const ifaces = networkInterfaces();
    for (const [ifaceName, addrs] of Object.entries(ifaces)) {
      if (skipIfaceRe.test(ifaceName)) continue;
      for (const a of addrs || []) {
        if (!a || a.family !== 'IPv4' || a.internal || !a.address) continue;
        const ip = a.address;
        if (seen.has(ip) || ip.startsWith('169.254.') || ip.startsWith('127.')) continue;
        seen.add(ip);
        const isTailscale = /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(ip) || /^tailscale/i.test(ifaceName);
        const isPrivate = ip.startsWith('192.168.') || ip.startsWith('10.') || /^172\.(1[6-9]|2\d|3[01])\./.test(ip);
        if (isTailscale) {
          tailscale.push({ iface: ifaceName, ip, label: 'Tailscale', kind: 'tailscale' });
        } else if (isPrivate) {
          const isWifi = /^(en0|wlan|wi-fi|wifi|wlp)/i.test(ifaceName);
          lan.push({ iface: ifaceName, ip, label: isWifi ? 'Wi-Fi 局域网' : '局域网', kind: 'lan' });
        } else if (!/^(utun|tun|tap|wg)/i.test(ifaceName)) {
          other.push({ iface: ifaceName, ip, label: ifaceName, kind: 'other' });
        }
      }
    }
  } catch {}
  const combined = [...lan, ...tailscale, ...other];
  return combined.map((item, idx) => ({ ...item, recommended: idx === 0 }));
}

function inspectWebServerBinding(ctx) {
  const ws = ctx?.get?.('webServer');
  const conn = ctx?.get?.('connection');
  let host = ws?.host ?? null;
  let port = Number(ws?.port || 0) || null;
  if ((!host || !port) && ws?.url) {
    try {
      const u = new URL(ws.url);
      if (!host) host = u.hostname;
      if (!port && u.port) port = Number(u.port);
    } catch {}
  }
  if ((!host || !port) && typeof ws?.server?.address === 'function') {
    try {
      const addr = ws.server.address();
      if (addr && typeof addr === 'object') {
        if (!host) host = addr.address;
        if (!port) port = addr.port;
      }
    } catch {}
  }
  const loopback = isLoopbackHost(host);
  const allowsRemote = Boolean(conn?.allowsRemoteAuthorities);
  return {
    available: Boolean(ws),
    host: host || '127.0.0.1',
    port,
    isLoopback: loopback,
    allowsRemote,
    isRemotelyReachable: Boolean(ws && port && (!loopback || allowsRemote)),
  };
}

function scheduleLanTeardown(listenKey, expectedGen, { immediate = false } = {}) {
  const entry = activeLanListeners.get(listenKey);
  if (!entry || entry.gen !== expectedGen) return Promise.resolve();
  entry.disposed = true;
  const closeNow = () => new Promise((resolve) => {
    const cur = activeLanListeners.get(listenKey);
    if (!cur || cur.gen !== expectedGen) {
      resolve();
      return;
    }
    activeLanListeners.delete(listenKey);
    const srv = cur.server;
    if (!srv) {
      resolve();
      return;
    }
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      resolve();
    };
    const guard = setTimeout(finish, 800);
    guard.unref?.();
    try { srv.closeAllConnections?.(); } catch {}
    try {
      srv.close(() => {
        clearTimeout(guard);
        finish();
      });
    } catch {
      clearTimeout(guard);
      finish();
    }
  });
  if (immediate) {
    if (entry.closeTimer) {
      clearTimeout(entry.closeTimer);
      entry.closeTimer = null;
    }
    return closeNow();
  }
  entry.closeTimer = setTimeout(() => { closeNow(); }, 5000);
  entry.closeTimer.unref?.();
  return Promise.resolve();
}

/**
 * Build ordered candidate port list avoiding `avoidPorts` (e.g. DSH's own `webServer.port`),
 * probing `preferredPort`, then `3081..3099`, and finally OS ephemeral port `0` so port
 * conflicts NEVER happen!
 */
export function buildZeroConflictPortCandidates(preferredPort = 3081, avoidPorts = []) {
  const avoid = new Set(
    (Array.isArray(avoidPorts) ? avoidPorts : [avoidPorts])
      .map((p) => Number(p))
      .filter((p) => Number.isInteger(p) && p > 0),
  );
  const out = [];
  const push = (p) => {
    if (!Number.isInteger(p) || p < 0 || p > 65535) return;
    if (p > 0 && avoid.has(p)) return;
    if (!out.includes(p)) out.push(p);
  };
  if (preferredPort === 0) {
    push(0);
    return out;
  }
  push(preferredPort);
  for (let p = 3081; p <= 3099; p++) push(p);
  push(0);
  return out;
}

/**
 * Standalone zero-conflict LAN HTTP + WebSocket bridge listener for DSH Desktop (which binds its own
 * webServer strictly to `127.0.0.1:0`). Reuses the live in-process `typertGateway` with 0ms startup,
 * automatically avoids `avoidPorts` and falls back through `3081..3099 -> :0` on `EADDRINUSE`!
 */
export function startLanBridgeListener(core, {
  host = '0.0.0.0',
  port = 3081,
  avoidPorts = [],
  token,
  surface = 'desktop',
  logger = console,
  getPairingSnapshot,
  onListening,
} = {}) {
  const bearerToken = resolveOrCreateLanToken(token);
  const preferredPort = Number.isFinite(Number(port)) && Number(port) >= 0 && Number(port) <= 65535
    ? Number(port)
    : 3081;
  const listenKey = `${host}:${preferredPort}`;
  const myGen = ++lanGenCounter;
  const existing = activeLanListeners.get(listenKey);
  if (existing && existing.server?.listening) {
    if (existing.closeTimer) {
      clearTimeout(existing.closeTimer);
      existing.closeTimer = null;
    }
    existing.disposed = false;
    existing.gen = myGen;
    existing.core = core;
    existing.bearerToken = bearerToken;
    existing.surface = surface;
    existing.logger = logger;
    existing.getPairingSnapshot = getPairingSnapshot;
    const bound = existing.server.address();
    const boundPort = typeof bound === 'object' && bound ? bound.port : existing.boundPort;
    logger?.info?.(`[gbridge] LAN bridge hot-swapped on ${host}:${boundPort}`);
    onListening?.({ host, port: boundPort, preferredPort, conflictAvoided: boundPort !== preferredPort });
    return {
      get token() { return existing.bearerToken; },
      setToken(nextToken) { existing.bearerToken = nextToken; },
      address: () => existing.server?.address?.() ?? { address: host, port: boundPort },
      isListening: () => Boolean(existing.server?.listening),
      conflictAvoided: () => Boolean(existing.conflictAvoided),
      error: () => existing.lastError,
      ready: Promise.resolve({ host, port: boundPort, conflictAvoided: Boolean(existing.conflictAvoided) }),
      dispose: (opts) => scheduleLanTeardown(listenKey, myGen, opts),
    };
  }
  if (existing) {
    // Supersede any pending non-listening startup so its async onBound never leaks an untracked server!
    existing.disposed = true;
    if (existing.closeTimer) {
      clearTimeout(existing.closeTimer);
      existing.closeTimer = null;
    }
    try { existing.server?.closeAllConnections?.(); } catch {}
    try { existing.server?.close?.(); } catch {}
    activeLanListeners.delete(listenKey);
  }

  const entry = {
    gen: myGen,
    core,
    bearerToken,
    surface,
    logger,
    getPairingSnapshot,
    server: null,
    boundPort: preferredPort,
    preferredPort,
    conflictAvoided: false,
    lastError: null,
    closeTimer: null,
  };

  const server = createServer((req, res) => {
    if (entry.core?.hub?._disposed) {
      res.writeHead(503, { 'content-type': 'application/json; charset=utf-8', 'retry-after': '1' });
      res.end(JSON.stringify({ error: { code: 'gbridge/reloading', message: 'bridge reloading, retry shortly', retryable: true } }));
      return;
    }
    let parsedUrl;
    try {
      parsedUrl = new URL(req.url || '/', 'http://gbridge.local');
    } catch {
      res.writeHead(400);
      res.end('Bad Request');
      return;
    }
    const rawPath = parsedUrl.pathname;
    const currentPort = entry.boundPort;

    // 1) Public unauthenticated LAN discovery probe (matching GrassBag LAN scanner).
    if (rawPath === '/plugins/events' && (req.method === 'GET' || req.method === 'HEAD')) {
      res.writeHead(200, {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache, no-store',
        'connection': 'close',
      });
      if (req.method === 'GET') {
        const dshVer = detectDshVersion(entry.core.gateway?.ctx ?? {});
        const payload = JSON.stringify({
          graph: { release: { version: dshVer !== 'unknown' ? dshVer : 'desktop' } },
          surface: entry.surface,
          hasGbridge: true,
          requiresAuth: true,
          bridgeVersion: entry.core.version,
          hostName: hostname(),
          port: currentPort,
        });
        res.write(`data: ${payload}\n\n`);
      }
      res.end();
      return;
    }

    // 2) Root launch-token -> 30-day port-scoped cookie exchange + authorized pairing status / HTML dashboard
    if (rawPath === '/' || rawPath === '/connect' || rawPath === UI_PATH) {
      const renderLoginHtml = (errMsg = '') =>
        `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>GrassBag 桌面端远程授权</title><style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#f4f7f6;color:#0f172a;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0;padding:20px}main{background:#fff;border-radius:22px;padding:26px;max-width:390px;width:100%;box-shadow:0 16px 40px rgba(0,0,0,.08)}h1{font-size:18px;margin:0 0 8px}p{font-size:13px;color:#64748b;line-height:1.5;margin:0 0 16px}.err{background:#fef2f2;color:#b91c1c;border:1px solid #fecaca;border-radius:10px;padding:9px 12px;font-size:12.5px;margin-bottom:12px}input{width:100%;box-sizing:border-box;padding:12px;border:1px solid #cbd5e1;border-radius:12px;font-size:14px;margin-bottom:12px}button{width:100%;padding:12px;border:0;border-radius:12px;background:#0f766e;color:#fff;font-size:14px;font-weight:600;cursor:pointer}</style></head><body><main><h1>GrassBag 连接授权</h1><p>输入电脑端 GrassBag 连接插件显示的连接令牌（Token），或直接使用手机 GrassBag 扫描二维码秒连。</p>${errMsg ? `<div class="err">${errMsg}</div>` : ''}<form method="POST" action="/connect"><input name="token" placeholder="粘贴连接 Token" autocomplete="off" required><button type="submit">验证并授权连接</button></form></main></body></html>`;

      const issueCookieRedirect = () => {
        const cookieVal = signLanCookieValue(entry.bearerToken);
        const cookieName = lanCookieNameForPort(currentPort);
        res.writeHead(303, {
          'set-cookie': `${cookieName}=${cookieVal}; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000`,
          'location': rawPath === UI_PATH ? UI_PATH : '/',
          'cache-control': 'no-store',
        });
        res.end();
      };

      if (req.method === 'POST') {
        readRawBody(req, 8192).then((rawBuf) => {
          const rawBody = rawBuf.toString('utf8');
          let submitted = '';
          const ct = String(req.headers['content-type'] || '').toLowerCase();
          if (ct.includes('application/json')) {
            try { submitted = String(JSON.parse(rawBody)?.token || '').trim(); } catch {}
          } else {
            submitted = String(new URLSearchParams(rawBody).get('token') || '').trim();
          }
          if (submitted && safeEqualString(submitted, entry.bearerToken)) {
            issueCookieRedirect();
            return;
          }
          res.writeHead(401, {
            'content-type': 'text/html; charset=utf-8',
            'cache-control': 'no-store',
          });
          res.end(renderLoginHtml('连接令牌（Token）不正确，请核对后重试。'));
        }).catch((err) => {
          sendError(res, err);
        });
        return;
      }

      const qToken = parsedUrl.searchParams.get('token');
      if (qToken && safeEqualString(qToken.trim(), entry.bearerToken)) {
        issueCookieRedirect();
        return;
      }
      const auth = admitRequest(req, {
        mode: 'lan',
        ctx: entry.core.gateway?.ctx ?? {},
        bearerToken: entry.bearerToken,
        lanPort: currentPort,
      });
      if (auth.ok) {
        if (rawPath === UI_PATH && typeof entry.getPairingSnapshot === 'function') {
          res.writeHead(200, {
            'content-type': 'text/html; charset=utf-8',
            'cache-control': 'no-store',
          });
          res.end(renderPairingDashboardHtml(entry.getPairingSnapshot(), { apiPath: `${PREFIX}/pairing` }));
          return;
        }
        sendJson(res, 200, {
          ok: true,
          surface: entry.surface,
          bridgeVersion: entry.core.version,
          port: currentPort,
          message: 'GrassBag Desktop LAN Bridge authorized',
        });
        return;
      }
      res.writeHead(401, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
      });
      res.end(renderLoginHtml(qToken ? '链接中的 Token 已失效或不匹配，请重新输入。' : ''));
      return;
    }

    // 3) All `/gbridge/v1/*` routes served via LAN bearer/cookie auth.
    if (rawPath === PREFIX || rawPath.startsWith(`${PREFIX}/`)) {
      Promise.resolve(
        entry.core.handleHttp(req, res, { mode: 'lan', bearerToken: entry.bearerToken, lanPort: currentPort }),
      ).catch((err) => {
        entry.logger?.warn?.('[gbridge] LAN request error:', err?.message || err);
      });
      return;
    }

    sendError(res, new GbridgeError(404, 'gbridge/route_not_found', `unknown LAN route ${rawPath}`));
  });

  server.on('upgrade', (req, socket, head) => {
    try {
      if (entry.core?.hub?._disposed) {
        rejectUpgrade(socket, 503, 'Service Unavailable');
        return;
      }
      const { pathname } = parseUrl(req, PREFIX);
      if (pathname !== '/stream') {
        rejectUpgrade(socket, 404, 'Not Found');
        return;
      }
      entry.core.handleUpgrade(req, socket, head, {
        mode: 'lan',
        bearerToken: entry.bearerToken,
        lanPort: entry.boundPort,
      });
    } catch {
      rejectUpgrade(socket, 400, 'Bad Request');
    }
  });

  entry.server = server;
  activeLanListeners.set(listenKey, entry);

  const candidates = buildZeroConflictPortCandidates(preferredPort, avoidPorts);
  let candIdx = 0;

  let resolveReady;
  const ready = new Promise((resolve) => {
    resolveReady = resolve;
  });

  const tryListenNext = () => {
    if (entry.disposed) {
      if (activeLanListeners.get(listenKey) === entry) activeLanListeners.delete(listenKey);
      resolveReady({ host, port: null, error: 'disposed' });
      return;
    }
    if (candIdx >= candidates.length) {
      if (activeLanListeners.get(listenKey) === entry) activeLanListeners.delete(listenKey);
      entry.lastError = 'no available port for LAN bridge';
      entry.logger?.warn?.(`[gbridge] LAN bridge failed on all candidate ports`);
      resolveReady({ host, port: null, error: entry.lastError });
      return;
    }
    const candidatePort = candidates[candIdx++];
    const onError = (err) => {
      server.removeListener('listening', onBound);
      if (entry.disposed) {
        if (activeLanListeners.get(listenKey) === entry) activeLanListeners.delete(listenKey);
        resolveReady({ host, port: null, error: 'disposed' });
        return;
      }
      const code = err?.code || '';
      if ((code === 'EADDRINUSE' || code === 'EACCES') && candIdx < candidates.length) {
        entry.logger?.info?.(`[gbridge] port ${candidatePort} busy (${code}), probing next conflict-free port...`);
        tryListenNext();
        return;
      }
      if (!server.listening && activeLanListeners.get(listenKey) === entry) {
        activeLanListeners.delete(listenKey);
      }
      entry.lastError = err?.message || String(err);
      entry.logger?.warn?.(`[gbridge] LAN bridge listen error on ${host}:${candidatePort}:`, entry.lastError);
      resolveReady({ host, port: null, error: entry.lastError });
    };
    const onBound = () => {
      server.removeListener('error', onError);
      if (entry.disposed) {
        if (activeLanListeners.get(listenKey) === entry) activeLanListeners.delete(listenKey);
        try { server.closeAllConnections?.(); } catch {}
        try { server.close(); } catch {}
        resolveReady({ host, port: null, error: 'disposed' });
        return;
      }
      server.on('error', (err) => {
        entry.lastError = err?.message || String(err);
        entry.logger?.warn?.(`[gbridge] LAN bridge runtime error:`, entry.lastError);
      });
      const bound = server.address();
      const actualPort = typeof bound === 'object' && bound ? bound.port : candidatePort;
      entry.boundPort = actualPort;
      entry.conflictAvoided = preferredPort > 0 && actualPort !== preferredPort;
      entry.lastError = null;
      const ifaces = listReachableNetworkInterfaces();
      const sampleIp = ifaces[0]?.ip || '127.0.0.1';
      entry.logger?.info?.(
        `[gbridge] Zero-conflict LAN Bridge ready on :${actualPort}${entry.conflictAvoided ? ` (avoided busy :${preferredPort})` : ''}: http://${sampleIp}:${actualPort}/?token=***`,
      );
      onListening?.({ host, port: actualPort, preferredPort, conflictAvoided: entry.conflictAvoided });
      resolveReady({ host, port: actualPort, conflictAvoided: entry.conflictAvoided });
    };

    server.once('error', onError);
    server.once('listening', onBound);
    try {
      server.listen(candidatePort, host);
    } catch (err) {
      onError(err);
    }
  };

  tryListenNext();

  return {
    get token() { return entry.bearerToken; },
    setToken(nextToken) { entry.bearerToken = nextToken; },
    address: () => (server.listening ? server.address() : null),
    isListening: () => Boolean(server.listening),
    conflictAvoided: () => Boolean(entry.conflictAvoided),
    error: () => entry.lastError,
    ready,
    dispose: (opts) => scheduleLanTeardown(listenKey, myGen, opts),
  };
}

function registerIsolated(label, fn, logger) {
  try {
    fn();
  } catch (err) {
    logger?.warn?.(`[gbridge] domain "${label}" registration failed (isolated):`, err?.message || err);
  }
}

/**
 * Create the complete `/gbridge/v1` HTTP + WebSocket handler set.
 * Exported directly so unit/contract tests can run without spinning up full Cordis.
 */
export function createGbridgeCore(ctx, options = {}) {
  const bootId = options.bootId || randomUUID();
  const logger = options.logger ?? ctx.logger ?? console;
  const gateway = options.gateway ?? new GatewayAdapter(ctx);
  const normalizer = new SessionNormalizer();
  const hub = new StreamHub({ bootId, gateway, normalizer, logger });
  const sdui = new SduiRegistry();
  let legacyRepairPromise = null;
  const waitForLegacyImageRepair = async (timeoutMs = 2000) => {
    if (!legacyRepairPromise) return;
    let timer;
    try {
      await Promise.race([
        legacyRepairPromise.catch(() => {}),
        new Promise((resolve) => {
          timer = setTimeout(resolve, timeoutMs);
          timer.unref?.();
        }),
      ]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  };

  if (process.env.GBRIDGE_TOKEN) latchedAndroidEnv.token = process.env.GBRIDGE_TOKEN;
  if (process.env.GBRIDGE_PHONE_TOKEN) latchedAndroidEnv.phoneToken = process.env.GBRIDGE_PHONE_TOKEN;

  const isLocalAndroid = Boolean(options.isLocalAndroid ?? process.env.GBRIDGE_LOCAL_ANDROID === '1');
  const capturedUnixSocket = options.unixSocket ?? process.env.GBRIDGE_UNIX_SOCKET ?? undefined;
  const capturedPhoneSocket = options.phoneSocket ?? process.env.GBRIDGE_PHONE_SOCKET ?? undefined;
  const capturedPidFile = options.pidFile ?? process.env.GBRIDGE_PID_FILE ?? undefined;
  const capturedBridgeToken =
    options.unixToken ??
    options.token ??
    process.env.GBRIDGE_TOKEN ??
    (capturedUnixSocket ? latchedAndroidEnv.token : undefined);
  const capturedPhoneToken =
    options.phoneToken ??
    process.env.GBRIDGE_PHONE_TOKEN ??
    (capturedPhoneSocket ? latchedAndroidEnv.phoneToken : undefined);

  const phoneState = mountPhoneTools(ctx, {
    socketPath: capturedPhoneSocket,
    token: capturedPhoneToken,
    logger,
  });
  if (typeof phoneState.notifyTurnEnd === 'function') {
    hub.setOnTurnCompleted(({ sessionId, reason }) => {
      phoneState.notifyTurnEnd(sessionId, reason);
    });
  }

  // Live pairing controller wired by `apply(ctx)` (and safely usable standalone in tests).
  let pairingController = options.pairingController ?? null;

  const router = new Router();
  const deps = { ctx, gateway, hub, normalizer, sdui, bridgeVersion: PKG_VERSION, bootId, phoneState, isLocalAndroid, waitForLegacyImageRepair };

  registerIsolated('meta', () => registerMetaDomain(router, deps), logger);
  registerIsolated('chat', () => registerChatAndInteractionsDomain(router, deps), logger);
  registerIsolated('workspace', () => registerWorkspaceDomain(router, deps), logger);
  registerIsolated('system', () => registerSystemDomain(router, deps), logger);

  // Pairing snapshot & live control endpoints under `/gbridge/v1/pairing`
  router.get('/pairing', async (_req, res) => {
    const snap = pairingController ? pairingController.getSnapshot() : {
      v: 1,
      bridgeVersion: PKG_VERSION,
      dshVersion: detectDshVersion(ctx),
      hostName: hostname(),
      platform: process.platform,
      arch: process.arch,
      surface: isLocalAndroid ? 'android' : 'web',
      mode: 'shared-webserver',
      connectedClients: hub.clients.size,
      endpoints: [],
    };
    sendJson(res, 200, snap);
  }, { domain: 'meta' });

  router.post('/pairing', async (req, res, { mode: reqMode, lanPort: reqLanPort } = {}) => {
    if (!pairingController) {
      throw new GbridgeError(501, 'gbridge/pairing_unavailable', 'pairing controller not attached');
    }
    const raw = await readRawBody(req, 16384);
    let body = {};
    if (raw.length > 0) {
      try { body = JSON.parse(raw.toString('utf8')); } catch {
        throw new GbridgeError(400, 'gbridge/invalid_json', 'invalid JSON payload');
      }
    }
    const action = String(body?.action || '').trim();
    const deferStop = reqMode === 'lan' && action === 'setLanEnabled' && !Boolean(body?.enabled);
    const deferPrevDispose = reqMode === 'lan' && action === 'setLanPort';
    let deferredDisposePrev = null;
    const next = await pairingController.applyAction(body, {
      deferLanStop: deferStop,
      deferPrevDispose,
      onDeferredDispose: (fn) => { deferredDisposePrev = fn; },
    });
    if (reqMode === 'lan' && action === 'rotateToken' && next?.token && reqLanPort) {
      const cookieName = lanCookieNameForPort(reqLanPort);
      const cookieVal = signLanCookieValue(next.token);
      res.setHeader(
        'set-cookie',
        `${cookieName}=${cookieVal}; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000`,
      );
    }
    if (deferStop || deferredDisposePrev) {
      res.once('finish', () => {
        const t = setTimeout(() => {
          try { if (deferStop) pairingController.stopLanIfDisabled?.(true); } catch {}
          try { deferredDisposePrev?.(); } catch {}
        }, 150);
        t.unref?.();
      });
    }
    sendJson(res, 200, next);
  }, { domain: 'meta' });

  const myPidGen = ++pidFileGenCounter;
  if (capturedPidFile) {
    try {
      mkdirSync(dirname(capturedPidFile), { recursive: true, mode: 0o700 });
      writeFileSync(capturedPidFile, `${process.pid}\n`, { mode: 0o600 });
    } catch {}
  }
  if (capturedUnixSocket) {
    // Prevent child agent shell / MCP / npm processes inside Android containers from inheriting privileged tokens.
    delete process.env.GBRIDGE_TOKEN;
    delete process.env.GBRIDGE_PHONE_TOKEN;
  }

  const handleHttp = async (req, res, { mode = 'webServer', bearerToken, lanPort } = {}) => {
    try {
      applyLoopbackCors(req, res);
      if (req.method === 'OPTIONS') {
        res.writeHead(204, { 'content-length': 0 });
        res.end();
        return;
      }
      const auth = admitRequest(req, { mode, ctx, bearerToken: bearerToken ?? capturedBridgeToken, lanPort });
      if (!auth.ok) {
        sendError(res, new GbridgeError(auth.status, auth.code, auth.message));
        return;
      }
      const { pathname, searchParams } = parseUrl(req, PREFIX);
      const matched = router.match(req.method, pathname);
      if (matched.kind === 'not_found') {
        sendError(res, new GbridgeError(404, 'gbridge/route_not_found', `unknown route ${pathname}`));
        return;
      }
      if (matched.kind === 'method_not_allowed') {
        res.setHeader('allow', matched.allowed.join(', '));
        sendError(res, new GbridgeError(405, 'gbridge/method_not_allowed', `method ${req.method} not allowed`, {
          details: { allowed: matched.allowed },
        }));
        return;
      }
      await matched.route.handler(req, res, {
        params: matched.params,
        searchParams,
        peer: auth.peer,
        mode,
        lanPort,
      });
    } catch (err) {
      sendError(res, err);
    }
  };

  const handleUpgrade = (req, socket, head, { mode = 'webServer', bearerToken, lanPort } = {}) => {
    try {
      const auth = admitRequest(req, { mode, ctx, bearerToken: bearerToken ?? capturedBridgeToken, lanPort });
      if (!auth.ok) {
        rejectUpgrade(socket, auth.status, auth.status === 401 ? 'Unauthorized' : 'Forbidden');
        return;
      }
      const ws = upgradeWebSocket(req, socket, head, { peer: auth.peer });
      if (ws) {
        hub.attachClient(ws, { peer: auth.peer, mode });
      }
    } catch {
      rejectUpgrade(socket, 400, 'Bad Request');
    }
  };

  const dispose = () => {
    hub.dispose();
    phoneState.dispose();
    gateway.dispose?.();
    if (capturedPidFile && pidFileGenCounter === myPidGen) {
      try { unlinkSync(capturedPidFile); } catch {}
    }
  };

  return {
    bootId,
    version: PKG_VERSION,
    udsPath: capturedUnixSocket,
    udsToken: capturedBridgeToken,
    gateway,
    normalizer,
    hub,
    sdui,
    phoneState,
    router,
    setPairingController(ctrl) { pairingController = ctrl; },
    setLegacyImageRepairPromise(p) { legacyRepairPromise = p; },
    handleHttp,
    handleUpgrade,
    dispose,
  };
}

function scheduleUdsTeardown(socketPath, expectedGen) {
  const entry = activeUdsListeners.get(socketPath);
  if (!entry || entry.gen !== expectedGen) return;
  const closeNow = () => {
    const cur = activeUdsListeners.get(socketPath);
    if (!cur || cur.gen !== expectedGen) return;
    activeUdsListeners.delete(socketPath);
    try { cur.server?.closeAllConnections?.(); } catch {}
    try {
      cur.server?.close(() => {
        if (!activeUdsListeners.has(socketPath)) {
          try { unlinkSync(socketPath); } catch {}
        }
      });
    } catch {
      if (!activeUdsListeners.has(socketPath)) {
        try { unlinkSync(socketPath); } catch {}
      }
    }
  };
  entry.closeTimer = setTimeout(closeNow, 5000);
  entry.closeTimer.unref?.();
}

/**
 * Start (or hot-swap) a private `0600` Unix Domain Socket listener for Android local host UID isolation.
 */
function startUdsListener(core, socketPath, bearerToken, logger) {
  const myGen = ++udsGenCounter;
  const existing = activeUdsListeners.get(socketPath);
  if (existing) {
    if (existing.closeTimer) {
      clearTimeout(existing.closeTimer);
      existing.closeTimer = null;
    }
    existing.gen = myGen;
    existing.core = core;
    existing.bearerToken = bearerToken;
    existing.logger = logger;
    logger?.info?.(`[gbridge] UDS listener hot-swapped on ${socketPath}`);
    return () => scheduleUdsTeardown(socketPath, myGen);
  }

  const entry = {
    gen: myGen,
    core,
    bearerToken,
    logger,
    server: null,
    closeTimer: null,
  };

  try {
    mkdirSync(dirname(socketPath), { recursive: true, mode: 0o700 });
    try { chmodSync(dirname(socketPath), 0o700); } catch {}
  } catch (err) {
    logger?.warn?.('[gbridge] failed to create UDS parent dir:', err?.message || err);
  }
  try { unlinkSync(socketPath); } catch {}

  const server = createServer((req, res) => {
    if (entry.core?.hub?._disposed) {
      res.writeHead(503, { 'content-type': 'application/json; charset=utf-8', 'retry-after': '1' });
      res.end(JSON.stringify({ error: { code: 'gbridge/reloading', message: 'bridge reloading, retry shortly', retryable: true } }));
      return;
    }
    Promise.resolve(
      entry.core.handleHttp(req, res, { mode: 'uds', bearerToken: entry.bearerToken }),
    ).catch((err) => {
      entry.logger?.warn?.('[gbridge] UDS request error:', err?.message || err);
    });
  });
  server.on('error', (err) => {
    if (!server.listening && activeUdsListeners.get(socketPath) === entry) {
      activeUdsListeners.delete(socketPath);
    }
    entry.logger?.warn?.('[gbridge] UDS listener error:', err?.message || err);
  });
  server.on('upgrade', (req, socket, head) => {
    try {
      if (entry.core?.hub?._disposed) {
        rejectUpgrade(socket, 503, 'Service Unavailable');
        return;
      }
      const { pathname } = parseUrl(req, PREFIX);
      if (pathname !== '/stream') {
        rejectUpgrade(socket, 404, 'Not Found');
        return;
      }
      entry.core.handleUpgrade(req, socket, head, { mode: 'uds', bearerToken: entry.bearerToken });
    } catch {
      rejectUpgrade(socket, 400, 'Bad Request');
    }
  });
  entry.server = server;
  activeUdsListeners.set(socketPath, entry);

  try {
    server.listen(socketPath, () => {
      try { chmodSync(socketPath, 0o600); } catch (err) {
        entry.logger?.warn?.('[gbridge] failed to chmod 0600 on UDS:', err?.message || err);
      }
      entry.logger?.info?.(`[gbridge] UDS listener ready on ${socketPath}`);
    });
  } catch (err) {
    activeUdsListeners.delete(socketPath);
    logger?.warn?.('[gbridge] UDS listen failed:', err?.message || err);
  }
  return () => scheduleUdsTeardown(socketPath, myGen);
}

/**
 * Create the live zero-conflict Pairing & LAN Bridge controller shared by:
 *   - `/api/gbridge/pairing` (DSH Desktop Electron IPC + `dsh web` HTTP)
 *   - `/gbridge/v1/pairing` (GrassBag mobile API)
 *   - `/gbridge/ui` (standalone browser QR dashboard)
 *   - `/grassbag` slash command
 */
export function createPairingController(ctx, core, config = {}) {
  const logger = ctx.logger ?? console;
  const udsPath = core.udsPath;
  const profileName = ctx.get?.('profileContext')?.name;
  const isDesktopProfile = profileName === 'desktop';
  const surface = udsPath ? 'android' : (isDesktopProfile ? 'desktop' : 'web');

  const envLanPort = Number(process.env.GBRIDGE_LAN_PORT || 0);
  const cfgPort = Number(config.lanPort ?? (envLanPort > 0 ? envLanPort : 3081));
  let preferredPort = Number.isFinite(cfgPort) && cfgPort >= 0 && cfgPort <= 65535 ? cfgPort : 3081;
  const lanHost = typeof config.lanHost === 'string' && config.lanHost.trim()
    ? config.lanHost.trim()
    : (process.env.GBRIDGE_LAN_HOST || '0.0.0.0');
  let lanToken = resolveOrCreateLanToken(config.lanToken ?? process.env.GBRIDGE_LAN_TOKEN);
  let lanHandle = null;
  let lanWanted = false;
  let lanOpChain = Promise.resolve();
  let disposed = false;

  const runLanOp = (fn) => {
    const next = lanOpChain.then(fn, fn);
    lanOpChain = next.catch(() => {});
    return next;
  };

  const resolveSharedWebToken = () => {
    const explicit = core.udsToken || process.env.GBRIDGE_TOKEN || null;
    if (explicit) return explicit;
    try {
      const conn = ctx?.get?.('connection');
      if (typeof conn?.authenticatedUrl === 'function') {
        const authed = conn.authenticatedUrl('http://127.0.0.1/');
        const t = new URL(authed).searchParams.get('token');
        if (t && t.trim()) return t.trim();
      }
    } catch {}
    return null;
  };

  const computeShouldAutoEnableLan = () => {
    if (udsPath) return false;
    if (config.lanEnabled === false || process.env.GBRIDGE_LAN_ENABLED === '0') return false;
    const wsInfo = inspectWebServerBinding(ctx);
    // ZERO-CONFLICT RULE: If `dsh web` is ALREADY bound to a non-loopback LAN/proxy host,
    // NEVER open a redundant second port unless the user explicitly forced `lanEnabled: true`!
    if (wsInfo.isRemotelyReachable && config.lanEnabled !== true && process.env.GBRIDGE_LAN_ENABLED !== '1') {
      return false;
    }
    return config.lanEnabled === true ||
      process.env.GBRIDGE_LAN_ENABLED === '1' ||
      (Number.isFinite(envLanPort) && envLanPort > 0) ||
      isDesktopProfile;
  };

  const stopLan = (immediate = true) => runLanOp(async () => {
    lanWanted = false;
    try { core.hub.disconnectByMode('lan', 4001, 'lan bridge stopped'); } catch {}
    const prev = lanHandle;
    lanHandle = null;
    if (prev) {
      try { await prev.dispose({ immediate }); } catch {}
    }
  });

  const stopLanIfDisabled = (immediate = true) => runLanOp(async () => {
    if (lanWanted || disposed) return;
    try { core.hub.disconnectByMode('lan', 4001, 'lan bridge stopped'); } catch {}
    const prev = lanHandle;
    lanHandle = null;
    if (prev) {
      try { await prev.dispose({ immediate }); } catch {}
    }
  });

  const startLan = (portOverride, { deferPrevDispose = false, onDeferredDispose } = {}) => runLanOp(async () => {
    if (udsPath || disposed) return;
    if (portOverride !== undefined) preferredPort = portOverride;
    const wsInfo = inspectWebServerBinding(ctx);
    const avoidPorts = wsInfo.port ? [wsInfo.port] : [];
    const prev = lanHandle;
    const prevPort = prev?.address?.()?.port;
    const canDeferPrev = Boolean(deferPrevDispose && prev && prevPort && prevPort !== preferredPort);
    lanHandle = null;
    if (prev && !canDeferPrev) {
      try { await prev.dispose({ immediate: true }); } catch {}
    }
    if (disposed) {
      if (canDeferPrev) {
        try { await prev.dispose({ immediate: true }); } catch {}
      }
      return;
    }
    lanWanted = true;
    const nextHandle = startLanBridgeListener(core, {
      host: lanHost,
      port: preferredPort,
      avoidPorts,
      token: lanToken,
      surface,
      logger,
      getPairingSnapshot: () => getSnapshot(),
    });
    if (disposed) {
      try { await nextHandle.dispose({ immediate: true }); } catch {}
      if (canDeferPrev) {
        try { await prev.dispose({ immediate: true }); } catch {}
      }
      return;
    }
    lanHandle = nextHandle;
    await nextHandle.ready;
    if (canDeferPrev) {
      if (typeof onDeferredDispose === 'function') {
        onDeferredDispose(() => {
          try { prev.dispose({ immediate: true }); } catch {}
        });
      } else {
        try { await prev.dispose({ immediate: true }); } catch {}
      }
    }
    if (disposed) {
      lanHandle = null;
      try { await nextHandle.dispose({ immediate: true }); } catch {}
    }
  });

  const qrCache = new Map();
  const buildEndpoints = (port, tokenForUrl) => {
    if (!port) return [];
    const rawHostLabel = (hostname() || 'DSH').trim();
    const hostLabel = rawHostLabel.length > 24 ? rawHostLabel.slice(0, 24) : rawHostLabel;
    const ifaces = listReachableNetworkInterfaces();
    return ifaces.map((item) => {
      const base = `http://${item.ip}:${port}`;
      const qs = new URLSearchParams();
      if (tokenForUrl) qs.set('token', tokenForUrl);
      if (hostLabel) qs.set('name', hostLabel);
      const url = qs.toString() ? `${base}/?${qs.toString()}` : base;
      const pairQs = new URLSearchParams({ url: base });
      if (tokenForUrl) pairQs.set('token', tokenForUrl);
      if (hostLabel) pairQs.set('name', hostLabel);
      const pairUri = `grassbag://pair?${pairQs.toString()}`;
      let qrUrl = url;
      if (Buffer.byteLength(qrUrl, 'utf8') > 200) {
        const compactQs = new URLSearchParams();
        if (tokenForUrl) compactQs.set('token', tokenForUrl);
        qrUrl = compactQs.toString() ? `${base}/?${compactQs.toString()}` : base;
      }
      let qr = qrCache.get(qrUrl) ?? null;
      if (qr === null) {
        try {
          qr = buildQrPathData(encodeQrMatrix(qrUrl), 3);
          if (qrCache.size >= 16) {
            const oldestKey = qrCache.keys().next().value;
            if (oldestKey !== undefined) qrCache.delete(oldestKey);
          }
          qrCache.set(qrUrl, qr);
        } catch {}
      }
      return {
        iface: item.iface,
        label: item.label,
        kind: item.kind,
        ip: item.ip,
        port,
        recommended: item.recommended,
        url,
        pairUri,
        qr,
      };
    });
  };

  const getSnapshot = () => {
    const wsInfo = inspectWebServerBinding(ctx);
    const lanBound = lanHandle?.address?.();
    const lanPort = (lanBound && typeof lanBound === 'object') ? lanBound.port : null;
    const lanListening = Boolean(lanHandle?.isListening?.() && lanPort);

    let mode = 'loopback-only';
    let activePort = null;
    let activeToken = null;
    let portConflictAvoided = false;

    if (wsInfo.isRemotelyReachable && !lanListening) {
      mode = 'shared-webserver';
      activePort = wsInfo.port;
      activeToken = resolveSharedWebToken();
    } else if (lanListening) {
      mode = 'lan-bridge';
      activePort = lanPort;
      activeToken = lanHandle.token;
      portConflictAvoided = Boolean(lanHandle.conflictAvoided?.());
    } else if (wsInfo.isRemotelyReachable) {
      mode = 'shared-webserver';
      activePort = wsInfo.port;
      activeToken = resolveSharedWebToken();
    }

    const endpoints = buildEndpoints(activePort, activeToken);

    return {
      v: 1,
      bridgeVersion: core.version,
      dshVersion: detectDshVersion(ctx),
      hostName: hostname() || 'DSH',
      platform: process.platform,
      arch: process.arch,
      surface,
      mode,
      activePort,
      portConflictAvoided,
      hasBridgeToken: mode === 'lan-bridge' || Boolean(activeToken),
      canRotateToken: mode === 'lan-bridge',
      token: activeToken,
      connectedClients: core.hub.clients.size,
      webServer: {
        available: wsInfo.available,
        host: wsInfo.host,
        port: wsInfo.port,
        isLoopback: wsInfo.isLoopback,
        isRemotelyReachable: wsInfo.isRemotelyReachable,
      },
      lan: {
        enabled: lanWanted,
        listening: lanListening,
        host: lanHost,
        port: lanPort,
        preferredPort,
        error: lanHandle?.error?.() ?? null,
      },
      endpoints,
      primaryEndpoint: endpoints[0] ?? null,
    };
  };

  const applyAction = async (body = {}, { deferLanStop = false, deferPrevDispose = false, onDeferredDispose } = {}) => {
    const action = String(body?.action || '').trim();
    if (action === 'rotateToken') {
      lanToken = persistRotatedLanToken();
      if (lanHandle) lanHandle.setToken(lanToken);
      // Immediately revoke active LAN WebSocket sessions so rotated-out devices must re-authorize.
      try { core.hub.disconnectByMode('lan', 4001, 'token rotated'); } catch {}
      return getSnapshot();
    }
    if (action === 'setLanEnabled') {
      const enabled = Boolean(body?.enabled);
      if (enabled) {
        await startLan();
        return getSnapshot();
      }
      if (deferLanStop) {
        lanWanted = false;
        const snap = getSnapshot();
        const sharedOk = Boolean(snap.webServer?.isRemotelyReachable);
        const sharedToken = resolveSharedWebToken();
        const sharedEndpoints = sharedOk ? buildEndpoints(snap.webServer.port, sharedToken) : [];
        return {
          ...snap,
          mode: sharedOk ? 'shared-webserver' : 'loopback-only',
          activePort: sharedOk ? snap.webServer.port : null,
          hasBridgeToken: Boolean(sharedToken),
          canRotateToken: false,
          token: sharedOk ? sharedToken : null,
          lan: {
            ...snap.lan,
            enabled: false,
            listening: false,
          },
          endpoints: sharedEndpoints,
          primaryEndpoint: sharedEndpoints[0] ?? null,
        };
      }
      await stopLan(true);
      return getSnapshot();
    }
    if (action === 'setLanPort') {
      const nextPort = Number(body?.port);
      if (!Number.isInteger(nextPort) || nextPort < 0 || nextPort > 65535) {
        throw new GbridgeError(400, 'gbridge/invalid_port', 'port must be an integer between 0 and 65535');
      }
      await startLan(nextPort, {
        deferPrevDispose: Boolean(deferPrevDispose),
        onDeferredDispose,
      });
      return getSnapshot();
    }
    throw new GbridgeError(400, 'gbridge/unknown_action', `unsupported pairing action: ${action || '(empty)'}`);
  };

  return {
    computeShouldAutoEnableLan,
    startLan,
    stopLan,
    stopLanIfDisabled,
    getSnapshot,
    applyAction,
    dispose: () => {
      disposed = true;
      lanWanted = false;
      if (lanHandle) {
        try { lanHandle.dispose({ immediate: false }); } catch {}
        lanHandle = null;
      }
    },
  };
}

/**
 * Standard Cordis plugin entrypoint (`dsh plugin add` / `dsh web --patch`).
 */
export function apply(ctx, config = {}) {
  const logger = ctx.logger ?? console;
  const core = createGbridgeCore(ctx, config);
  const pairing = createPairingController(ctx, core, config);
  core.setPairingController(pairing);

  // Public Cordis service allowing other plugins to register native SDUI views on GrassBag.
  if (typeof ctx.provide === 'function') {
    ctx.provide('gbridge', {
      version: core.version,
      bootId: core.bootId,
      getPairingSnapshot: () => pairing.getSnapshot(),
      registerSurface: (surface) => core.sdui.register(surface),
      publishEvent: (channel, type, data) => core.hub.publish(channel, type, data),
    });
  }

  ctx.effect(() => () => {
    pairing.dispose();
    core.dispose();
  }, 'gbridge: core lifecycle');

  if (typeof ctx.inject === 'function') {
    // Automatically migrate any historical session logs containing legacy inline `{ type: 'image', data }`
    // tool results (from older `phone_screenshot` calls) into durable `ctx.attachments` refs so poisoned
    // sessions recover cleanly on boot without crashing `dsh-llm-pi-ai` / `dsh-llm-deepseek`.
    let legacyImageRepairTriggered = false;
    ctx.inject(['attachments'], (attCtx) => {
      if (legacyImageRepairTriggered) return;
      legacyImageRepairTriggered = true;
      const attachments = attCtx.attachments ?? attCtx.get?.('attachments');
      const dshHome = process.env.DSH_HOME || join(homedir(), '.dsh');
      const repairPromise = repairLegacyInlineImageSessions({ dshHome, attachments, logger }).catch((err) => {
        logger?.warn?.('[gbridge] legacy inline image session scan failed:', err?.message || err);
      });
      core.setLegacyImageRepairPromise(repairPromise);
    });

    // Start host event pump once typertGateway is mounted.
    ctx.inject(['typertGateway'], () => {
      core.hub.startHostEventPump();
    });

    // Register `/api/gbridge/pairing` on DSH's `connection.fetch` so BOTH Electron Desktop (IPC)
    // and `dsh web` (HTTP cookie auth) can query & control QR pairing seamlessly!
    ctx.inject(['connection'], (connCtx) => {
      if (typeof connCtx.connection?.fetch?.register === 'function') {
        connCtx.effect(() => connCtx.connection.fetch.register({
          path: PAIRING_API_PATH,
          methods: ['GET', 'POST'],
          requestBody: 'buffered',
          fetch: async (request) => {
            try {
              if (request.method === 'POST') {
                const text = await request.text();
                let body = {};
                if (text) {
                  try { body = JSON.parse(text); } catch {
                    throw new GbridgeError(400, 'gbridge/invalid_json', 'invalid JSON payload');
                  }
                }
                const next = await pairing.applyAction(body);
                return new Response(JSON.stringify(next), {
                  status: 200,
                  headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
                });
              }
              return new Response(JSON.stringify(pairing.getSnapshot()), {
                status: 200,
                headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
              });
            } catch (err) {
              const status = err instanceof GbridgeError ? err.status : 500;
              const code = err instanceof GbridgeError ? err.code : 'gbridge/internal_error';
              return new Response(JSON.stringify({ error: { code, message: err?.message || String(err) } }), {
                status,
                headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
              });
            }
          },
        }), 'gbridge: /api/gbridge/pairing');
      }
    });

    // Mount `/gbridge/v1`, `/gbridge/v1/stream`, AND `/gbridge/ui` HTML QR dashboard on DSH's webServer!
    ctx.inject(['webServer'], (webCtx) => {
      webCtx.effect(() => webCtx.webServer.register({
        kind: 'prefix',
        path: PREFIX,
        handler: (req, res) => core.handleHttp(req, res, { mode: 'webServer' }),
      }), 'gbridge: HTTP /gbridge/v1');

      webCtx.effect(() => webCtx.webServer.registerUpgrade({
        path: STREAM_PATH,
        handler: (req, socket, head) => core.handleUpgrade(req, socket, head, { mode: 'webServer' }),
      }), 'gbridge: WS /gbridge/v1/stream');

      webCtx.effect(() => webCtx.webServer.register({
        kind: 'exact',
        path: UI_PATH,
        handler: (req, res) => {
          const auth = admitRequest(req, { mode: 'webServer', ctx: webCtx });
          if (!auth.ok) {
            sendError(res, new GbridgeError(auth.status, auth.code, auth.message));
            return;
          }
          res.writeHead(200, {
            'content-type': 'text/html; charset=utf-8',
            'cache-control': 'no-store',
          });
          res.end(renderPairingDashboardHtml(pairing.getSnapshot(), { apiPath: PAIRING_API_PATH }));
        },
      }), 'gbridge: HTML /gbridge/ui');
    });

    // Optional `/grassbag` slash command so users can inspect their QR/pairing URL from any chat!
    ctx.inject(['commands'], (cmdCtx) => {
      if (typeof cmdCtx.commands?.register === 'function') {
        try {
          cmdCtx.effect(() => cmdCtx.commands.register({
            name: 'grassbag',
            description: '显示 GrassBag 手机连接链接与端口状态',
            execute: async () => {
              const snap = pairing.getSnapshot();
              const lines = [
                `GrassBag 连接助手 v${snap.bridgeVersion}（${snap.mode === 'shared-webserver' ? `复用 DSH Web :${snap.activePort}` : snap.mode === 'lan-bridge' ? `内置局域网桥接 :${snap.activePort}` : '仅本机回环'}）`,
              ];
              if (snap.primaryEndpoint?.url) {
                lines.push(`推荐配对链接：${snap.primaryEndpoint.url}`);
              } else {
                lines.push('提示：请在左侧栏「手机连接」面板开启局域网桥接，即可显示扫码二维码。');
              }
              lines.push(`已连接手机客户端：${snap.connectedClients}`);
              return { message: lines.join('\n') };
            },
          }), 'gbridge: /grassbag command');
        } catch {}
      }
    });
  }

  // Optional Android local UID-isolated Unix Domain Socket listener.
  const udsPath = core.udsPath;
  const udsToken = core.udsToken;
  if (udsPath && udsToken) {
    if (ctx.get?.('typertGateway') || typeof ctx.inject !== 'function') {
      ctx.effect(() => startUdsListener(core, udsPath, udsToken, logger), 'gbridge: UDS listener');
    } else {
      ctx.inject(['typertGateway'], (readyCtx) => {
        readyCtx.effect(() => startUdsListener(core, udsPath, udsToken, logger), 'gbridge: UDS listener');
      });
    }
  }

  // Zero-conflict Desktop / loopback LAN Bridge startup:
  // Wait for `typertGateway` so Desktop's internal webServer binding is already known and avoided!
  const maybeStartLan = () => {
    if (pairing.computeShouldAutoEnableLan()) {
      void pairing.startLan();
    }
  };
  if (ctx.get?.('typertGateway') || typeof ctx.inject !== 'function') {
    maybeStartLan();
  } else {
    ctx.inject(['typertGateway'], () => {
      maybeStartLan();
    });
  }
}
