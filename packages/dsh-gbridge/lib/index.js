import { createServer } from 'node:http';
import { chmodSync, existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir, networkInterfaces } from 'node:os';
import { dirname, join } from 'node:path';
import { randomBytes, randomUUID } from 'node:crypto';
import {
  GbridgeError,
  Router,
  admitRequest,
  applyLoopbackCors,
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
import { detectDshVersion, registerMetaDomain } from './domains/meta.js';
import { registerChatAndInteractionsDomain } from './domains/chat.js';
import { registerWorkspaceDomain } from './domains/workspace.js';
import { registerSystemDomain } from './domains/system.js';

export const name = 'gbridge';
export const PREFIX = '/gbridge/v1';
export const STREAM_PATH = `${PREFIX}/stream`;

const PKG_VERSION = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version;

// Latch Android container secrets once in module-private memory before scrubbing `process.env`.
// Cordis reloads plugins during DSH web profile hydration (~0.5-1s after boot); without latching,
// the 2nd `apply(ctx)` sees deleted env vars and drops UDS + Bearer auth + phone-control auth!
const latchedAndroidEnv = {
  token: process.env.GBRIDGE_TOKEN || undefined,
  unixSocket: process.env.GBRIDGE_UNIX_SOCKET || undefined,
  phoneSocket: process.env.GBRIDGE_PHONE_SOCKET || undefined,
  phoneToken: process.env.GBRIDGE_PHONE_TOKEN || undefined,
  pidFile: process.env.GBRIDGE_PID_FILE || undefined,
  isLocalAndroid: process.env.GBRIDGE_LOCAL_ANDROID === '1',
};
if (latchedAndroidEnv.unixSocket) {
  delete process.env.GBRIDGE_TOKEN;
  delete process.env.GBRIDGE_PHONE_TOKEN;
}

const activeUdsListeners = new Map();
const activeLanListeners = new Map();
let udsGenCounter = 0;
let lanGenCounter = 0;
let pidFileGenCounter = 0;

function resolveOrCreateLanToken(explicitToken) {
  if (typeof explicitToken === 'string' && explicitToken.trim().length >= 8) {
    return explicitToken.trim();
  }
  const dshHome = process.env.DSH_HOME || join(homedir(), '.dsh');
  const tokenFile = join(dshHome, 'gbridge-lan-token');
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

function listLocalLanIpv4s() {
  const preferred = [];
  const fallback = [];
  const virtualIfaceRe = /^(docker|br-|veth|utun|tun|tap|wg|virbr|vmnet|lo|awdl|llw)/i;
  try {
    const ifaces = networkInterfaces();
    for (const [ifaceName, addrs] of Object.entries(ifaces)) {
      if (virtualIfaceRe.test(ifaceName)) continue;
      for (const a of addrs || []) {
        if (!a || a.family !== 'IPv4' || a.internal || !a.address) continue;
        if (a.address.startsWith('169.254.')) continue; // skip APIPA link-local
        if (a.address.startsWith('192.168.') || a.address.startsWith('10.') || /^172\.(1[6-9]|2\d|3[01])\./.test(a.address)) {
          preferred.push(a.address);
        } else {
          fallback.push(a.address);
        }
      }
    }
  } catch {}
  return preferred.length > 0 ? preferred : fallback;
}

function scheduleLanTeardown(listenKey, expectedGen) {
  const entry = activeLanListeners.get(listenKey);
  if (!entry || entry.gen !== expectedGen) return;
  const closeNow = () => {
    const cur = activeLanListeners.get(listenKey);
    if (!cur || cur.gen !== expectedGen) return;
    activeLanListeners.delete(listenKey);
    try { cur.server?.closeAllConnections?.(); } catch {}
    try { cur.server?.close(); } catch {}
  };
  entry.closeTimer = setTimeout(closeNow, 5000);
  entry.closeTimer.unref?.();
}

/**
 * Standalone LAN HTTP + WebSocket bridge listener for DSH Desktop (which binds its own
 * webServer strictly to `127.0.0.1:0`). Reuses the live in-process `typertGateway` without
 * disturbing Desktop's internal loopback server or modifying `@deepseek-ai/dsh`.
 */
export function startLanBridgeListener(core, {
  host = '0.0.0.0',
  port = 3081,
  token,
  surface = 'desktop',
  logger = console,
} = {}) {
  const bearerToken = resolveOrCreateLanToken(token);
  const listenKey = `${host}:${port}`;
  const myGen = ++lanGenCounter;
  const existing = activeLanListeners.get(listenKey);
  if (existing) {
    if (existing.closeTimer) {
      clearTimeout(existing.closeTimer);
      existing.closeTimer = null;
    }
    existing.gen = myGen;
    existing.core = core;
    existing.bearerToken = bearerToken;
    existing.surface = surface;
    existing.logger = logger;
    logger?.info?.(`[gbridge] LAN bridge hot-swapped on ${listenKey}`);
    return {
      token: bearerToken,
      address: () => existing.server?.address?.() ?? { address: host, port },
      dispose: () => scheduleLanTeardown(listenKey, myGen),
    };
  }

  const entry = {
    gen: myGen,
    core,
    bearerToken,
    surface,
    logger,
    server: null,
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
        });
        res.write(`data: ${payload}\n\n`);
      }
      res.end();
      return;
    }

    // 2) Root launch-token -> 30-day cookie exchange (GET /?token=... for 1-click launch URLs + POST /connect form without leaking token in URL/history).
    if (rawPath === '/' || rawPath === '/connect') {
      const renderLoginHtml = (errMsg = '') =>
        `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>GrassBag 桌面端远程授权</title><style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#f5f7fb;color:#111827;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0;padding:20px}main{background:#fff;border-radius:20px;padding:24px;max-width:380px;width:100%;box-shadow:0 12px 32px rgba(0,0,0,.08)}h1{font-size:18px;margin:0 0 8px}p{font-size:13px;color:#6b7280;line-height:1.5;margin:0 0 16px}.err{background:#fef2f2;color:#b91c1c;border:1px solid #fecaca;border-radius:10px;padding:9px 12px;font-size:12.5px;margin-bottom:12px}input{width:100%;box-sizing:border-box;padding:12px;border:1px solid #d1d5db;border-radius:12px;font-size:14px;margin-bottom:12px}button{width:100%;padding:12px;border:0;border-radius:12px;background:#111827;color:#fff;font-size:14px;font-weight:600;cursor:pointer}</style></head><body><main><h1>DeepSeek Harness 桌面端授权</h1><p>输入桌面端 GrassBag 连接插件显示的连接令牌（Token），授权后 30 天免填。</p>${errMsg ? `<div class="err">${errMsg}</div>` : ''}<form method="POST" action="/connect"><input name="token" placeholder="粘贴连接 Token" autocomplete="off" required><button type="submit">验证并授权连接</button></form></main></body></html>`;

      const issueCookieRedirect = () => {
        const cookieVal = signLanCookieValue(entry.bearerToken);
        res.writeHead(303, {
          'set-cookie': `gbridge-lan-auth=${cookieVal}; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000`,
          'location': '/',
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
      const auth = admitRequest(req, { mode: 'lan', ctx: entry.core.gateway?.ctx ?? {}, bearerToken: entry.bearerToken });
      if (auth.ok) {
        sendJson(res, 200, {
          ok: true,
          surface: entry.surface,
          bridgeVersion: entry.core.version,
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
        entry.core.handleHttp(req, res, { mode: 'lan', bearerToken: entry.bearerToken }),
      ).catch((err) => {
        entry.logger?.warn?.('[gbridge] LAN request error:', err?.message || err);
      });
      return;
    }

    sendError(res, new GbridgeError(404, 'gbridge/route_not_found', `unknown LAN route ${rawPath}`));
  });

  server.on('error', (err) => {
    if (!server.listening && activeLanListeners.get(listenKey) === entry) {
      activeLanListeners.delete(listenKey);
    }
    entry.logger?.warn?.(`[gbridge] LAN bridge listener error on ${listenKey}:`, err?.message || err);
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
      entry.core.handleUpgrade(req, socket, head, { mode: 'lan', bearerToken: entry.bearerToken });
    } catch {
      rejectUpgrade(socket, 400, 'Bad Request');
    }
  });

  entry.server = server;
  activeLanListeners.set(listenKey, entry);

  try {
    server.listen(port, host, () => {
      const bound = server.address();
      const boundPort = typeof bound === 'object' && bound ? bound.port : port;
      const ips = listLocalLanIpv4s();
      const sampleIp = ips[0] || '127.0.0.1';
      entry.logger?.info?.(
        `[gbridge] Desktop LAN Bridge ready: http://${sampleIp}:${boundPort}/?token=${bearerToken}`,
      );
    });
  } catch (err) {
    activeLanListeners.delete(listenKey);
    logger?.warn?.(`[gbridge] LAN bridge listen failed on ${listenKey}:`, err?.message || err);
  }

  return {
    token: bearerToken,
    address: () => server.address(),
    dispose: () => scheduleLanTeardown(listenKey, myGen),
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

  const router = new Router();
  const deps = { ctx, gateway, hub, normalizer, sdui, bridgeVersion: PKG_VERSION, bootId, phoneState, isLocalAndroid };

  registerIsolated('meta', () => registerMetaDomain(router, deps), logger);
  registerIsolated('chat', () => registerChatAndInteractionsDomain(router, deps), logger);
  registerIsolated('workspace', () => registerWorkspaceDomain(router, deps), logger);
  registerIsolated('system', () => registerSystemDomain(router, deps), logger);

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

  const handleHttp = async (req, res, { mode = 'webServer', bearerToken } = {}) => {
    try {
      applyLoopbackCors(req, res);
      if (req.method === 'OPTIONS') {
        res.writeHead(204, { 'content-length': 0 });
        res.end();
        return;
      }
      const auth = admitRequest(req, { mode, ctx, bearerToken: bearerToken ?? capturedBridgeToken });
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
      });
    } catch (err) {
      sendError(res, err);
    }
  };

  const handleUpgrade = (req, socket, head, { mode = 'webServer', bearerToken } = {}) => {
    try {
      const auth = admitRequest(req, { mode, ctx, bearerToken: bearerToken ?? capturedBridgeToken });
      if (!auth.ok) {
        rejectUpgrade(socket, auth.status, auth.status === 401 ? 'Unauthorized' : 'Forbidden');
        return;
      }
      const ws = upgradeWebSocket(req, socket, head, { peer: auth.peer });
      if (ws) {
        hub.attachClient(ws, { peer: auth.peer });
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
    handleHttp,
    handleUpgrade,
    dispose,
  };
}

function scheduleUdsTeardown(socketPath, expectedGen) {
  const entry = activeUdsListeners.get(socketPath);
  if (!entry || entry.gen !== expectedGen) return;
  // Defer actual UDS close briefly so Cordis plugin reloads hot-swap seamlessly without
  // unlinking `bridge.sock` or dropping Android local clients.
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
 * Standard Cordis plugin entrypoint (`dsh plugin add` / `dsh web --patch`).
 */
export function apply(ctx, config = {}) {
  const logger = ctx.logger ?? console;
  const core = createGbridgeCore(ctx, config);

  // Public Cordis service allowing other plugins to register native SDUI views on GrassBag.
  if (typeof ctx.provide === 'function') {
    ctx.provide('gbridge', {
      version: core.version,
      bootId: core.bootId,
      registerSurface: (surface) => core.sdui.register(surface),
      publishEvent: (channel, type, data) => core.hub.publish(channel, type, data),
    });
  }

  ctx.effect(() => () => core.dispose(), 'gbridge: core lifecycle');

  // Start host event pump once typertGateway is mounted.
  if (typeof ctx.inject === 'function') {
    ctx.inject(['typertGateway'], () => {
      core.hub.startHostEventPump();
    });

    // Mount `/gbridge/v1` HTTP prefix + `/gbridge/v1/stream` WS on DSH's webServer.
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
    });
  }

  // Optional Android local UID-isolated Unix Domain Socket listener.
  // Use core.udsPath & core.udsToken captured BEFORE createGbridgeCore() scrubs process.env!
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

  // Optional Desktop / standalone LAN Bridge listener (so DSH Desktop, which binds its own
  // webServer strictly to `127.0.0.1:0`, becomes directly reachable from GrassBag over LAN!).
  const profileName = ctx.get?.('profileContext')?.name;
  const isDesktopProfile = profileName === 'desktop';
  const envLanPort = Number(process.env.GBRIDGE_LAN_PORT || 0);
  const lanEnabled = !udsPath && (
    config.lanEnabled === true ||
    process.env.GBRIDGE_LAN_ENABLED === '1' ||
    (Number.isFinite(envLanPort) && envLanPort > 0) ||
    (isDesktopProfile && config.lanEnabled !== false)
  );
  if (lanEnabled) {
    const lanHost = typeof config.lanHost === 'string' && config.lanHost.trim()
      ? config.lanHost.trim()
      : (process.env.GBRIDGE_LAN_HOST || '0.0.0.0');
    const cfgPort = Number(config.lanPort ?? (envLanPort > 0 ? envLanPort : 3081));
    const lanPort = Number.isFinite(cfgPort) && cfgPort >= 0 && cfgPort <= 65535 ? cfgPort : 3081;
    const lanToken = config.lanToken ?? process.env.GBRIDGE_LAN_TOKEN;
    const surface = isDesktopProfile ? 'desktop' : 'web';
    const mountLan = (targetCtx) => {
      targetCtx.effect(() => {
        const handle = startLanBridgeListener(core, {
          host: lanHost,
          port: lanPort,
          token: lanToken,
          surface,
          logger,
        });
        return () => handle.dispose();
      }, 'gbridge: Desktop LAN bridge');
    };
    if (ctx.get?.('typertGateway') || typeof ctx.inject !== 'function') {
      mountLan(ctx);
    } else {
      ctx.inject(['typertGateway'], (readyCtx) => mountLan(readyCtx));
    }
  }
}
