import { createHmac, timingSafeEqual } from 'node:crypto';

export const DEFAULT_MAX_BODY_BYTES = 1024 * 1024; // 1 MiB for JSON bodies
export const DEFAULT_MAX_UPLOAD_BYTES = 50 * 1024 * 1024; // 50 MiB for binary uploads

export class GbridgeError extends Error {
  constructor(status, code, message, { retryable = false, details } = {}) {
    super(message);
    this.name = 'GbridgeError';
    this.status = status;
    this.code = code;
    this.retryable = retryable;
    if (details !== undefined) this.details = details;
  }
}

export function isPlainObject(v) {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

export function safeEqualString(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const bufA = Buffer.from(a, 'utf8');
  const bufB = Buffer.from(b, 'utf8');
  if (bufA.length !== bufB.length) return false;
  return timingSafeEqual(bufA, bufB);
}

export function parseBearerToken(req) {
  const header = req.headers?.authorization;
  if (typeof header !== 'string') return undefined;
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match ? match[1].trim() : undefined;
}

export function parseCookieValue(req, name) {
  const raw = req.headers?.cookie;
  if (typeof raw !== 'string' || !raw) return undefined;
  for (const part of raw.split(';')) {
    const eq = part.indexOf('=');
    if (eq <= 0) continue;
    const k = part.slice(0, eq).trim();
    if (k === name) return part.slice(eq + 1).trim();
  }
  return undefined;
}

export function signLanCookieValue(secret, ttlSec = 30 * 24 * 3600) {
  const exp = Math.floor(Date.now() / 1000) + ttlSec;
  const payload = `v1.${exp}`;
  const sig = createHmac('sha256', secret).update(payload).digest('base64url');
  return `${payload}.${sig}`;
}

export function verifyLanCookieValue(value, secret) {
  if (typeof value !== 'string' || typeof secret !== 'string' || !secret) return false;
  const parts = value.split('.');
  if (parts.length !== 3 || parts[0] !== 'v1') return false;
  const exp = Number(parts[1]);
  if (!Number.isFinite(exp) || exp < Math.floor(Date.now() / 1000)) return false;
  const payload = `${parts[0]}.${parts[1]}`;
  const expected = createHmac('sha256', secret).update(payload).digest('base64url');
  return safeEqualString(parts[2], expected);
}

export function isLoopbackOrigin(origin) {
  if (typeof origin !== 'string' || !origin) return false;
  return /^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/i.test(origin.trim());
}

export function applyLoopbackCors(req, res) {
  const origin = req.headers?.origin;
  if (!isLoopbackOrigin(origin)) return false;
  res.setHeader('access-control-allow-origin', origin);
  res.setHeader('vary', 'Origin');
  // Only expose credentialed cookies to exact same-origin requests; cross-port localhost
  // frontends must authenticate via `Authorization: Bearer` to prevent cross-port CSRF.
  let sameHost = false;
  const hostHeader = String(req.headers?.host || '').trim().toLowerCase();
  if (hostHeader) {
    try {
      sameHost = new URL(origin).host.toLowerCase() === hostHeader;
    } catch {}
  }
  if (sameHost) {
    res.setHeader('access-control-allow-credentials', 'true');
  }
  res.setHeader('access-control-allow-headers', 'Authorization, Content-Type');
  res.setHeader('access-control-allow-methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS');
  return true;
}

export function securityHeaders(extra = {}) {
  return {
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    ...extra,
  };
}

export function sendJson(res, status, payload, extraHeaders = {}) {
  if (res.writableEnded) return;
  const body = payload === undefined ? '' : JSON.stringify(payload);
  const headers = securityHeaders({
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    ...extraHeaders,
  });
  res.writeHead(status, headers);
  res.end(body);
}

const SAFE_MIME_RE = /^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/i;
const ACTIVE_WEB_MIMES = new Set([
  'text/html',
  'application/xhtml+xml',
  'image/svg+xml',
  'text/javascript',
  'application/javascript',
  'application/x-javascript',
  'text/xml',
  'application/xml',
]);

export function sanitizeBinaryContentType(raw) {
  if (typeof raw !== 'string') return 'application/octet-stream';
  const base = raw.split(';')[0].trim().toLowerCase();
  if (!SAFE_MIME_RE.test(base) || ACTIVE_WEB_MIMES.has(base)) {
    return 'application/octet-stream';
  }
  return base;
}

export function sendBinary(res, status, buffer, contentType = 'application/octet-stream', extraHeaders = {}) {
  if (res.writableEnded) return;
  const data = Buffer.isBuffer(buffer) ? buffer : Buffer.from(buffer);
  const safeType = sanitizeBinaryContentType(contentType);
  res.writeHead(status, securityHeaders({
    'content-type': safeType,
    'content-length': data.length,
    'content-disposition': 'attachment',
    'content-security-policy': "default-src 'none'; sandbox",
    ...extraHeaders,
  }));
  res.end(data);
}

export function sendError(res, error) {
  if (res.writableEnded) return;
  if (error instanceof GbridgeError) {
    const body = {
      error: {
        code: error.code,
        message: error.message,
        retryable: Boolean(error.retryable),
        ...(error.details !== undefined ? { details: error.details } : {}),
      },
    };
    sendJson(res, error.status, body, error.status === 413 ? { connection: 'close' } : {});
    return;
  }
  const status = typeof error?.status === 'number' && error.status >= 400 && error.status <= 599 ? error.status : 500;
  const code = typeof error?.code === 'string' && error.code.includes('/') ? error.code : 'gbridge/internal_error';
  const message = error instanceof Error ? error.message : String(error ?? 'internal error');
  sendJson(res, status, {
    error: { code, message, retryable: status >= 500 },
  });
}

export function readRawBody(req, maxBytes = DEFAULT_MAX_BODY_BYTES) {
  return new Promise((resolve, reject) => {
    if (req.aborted || req.destroyed) {
      reject(new GbridgeError(499, 'gbridge/request_aborted', 'request body interrupted', { retryable: true }));
      return;
    }
    const declaredLen = Number(req.headers?.['content-length']);
    if (Number.isFinite(declaredLen) && declaredLen > maxBytes) {
      reject(new GbridgeError(413, 'gbridge/payload_too_large', `request body exceeds ${maxBytes} bytes`));
      req.resume?.();
      return;
    }
    const chunks = [];
    let total = 0;
    let settled = false;
    const finishErr = (err) => {
      if (settled) return;
      settled = true;
      chunks.length = 0;
      reject(err);
    };
    req.on('data', (chunk) => {
      if (settled) return;
      total += chunk.length;
      if (total > maxBytes) {
        finishErr(new GbridgeError(413, 'gbridge/payload_too_large', `request body exceeds ${maxBytes} bytes`));
        req.resume?.();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (settled) return;
      settled = true;
      resolve(Buffer.concat(chunks));
    });
    req.on('error', (err) => {
      finishErr(new GbridgeError(400, 'gbridge/body_read_error', err?.message || 'failed to read body'));
    });
    req.on('close', () => {
      if (!settled && !req.complete) {
        finishErr(new GbridgeError(499, 'gbridge/request_aborted', 'client closed connection before body completed', { retryable: true }));
      }
    });
  });
}

export async function readJsonBody(req, maxBytes = DEFAULT_MAX_BODY_BYTES) {
  const raw = await readRawBody(req, maxBytes);
  if (raw.length === 0) return {};
  try {
    const parsed = JSON.parse(raw.toString('utf8'));
    if (!isPlainObject(parsed)) {
      throw new GbridgeError(400, 'gbridge/validation_error', 'JSON body must be an object');
    }
    return parsed;
  } catch (err) {
    if (err instanceof GbridgeError) throw err;
    throw new GbridgeError(400, 'gbridge/invalid_json', 'invalid JSON request body');
  }
}

export function parseUrl(req, prefix = '/gbridge/v1') {
  const raw = req.url || '/';
  const parsed = new URL(raw, 'http://gbridge.local');
  let pathname = parsed.pathname;
  if (pathname === prefix) {
    pathname = '/';
  } else if (pathname.startsWith(`${prefix}/`)) {
    pathname = pathname.slice(prefix.length);
  }
  if (pathname.length > 1 && pathname.endsWith('/')) {
    pathname = pathname.slice(0, -1);
  }
  return { pathname, searchParams: parsed.searchParams, url: parsed };
}

/**
 * Lightweight path router with `:param` extraction and 405 Method Not Allowed detection.
 */
export class Router {
  constructor() {
    this.routes = [];
  }

  add(method, pattern, handler, { domain = 'core' } = {}) {
    const upper = method.toUpperCase();
    const parts = pattern.split('/').filter(Boolean);
    const paramNames = [];
    const regexParts = parts.map((seg) => {
      if (seg.startsWith(':')) {
        paramNames.push(seg.slice(1));
        return '([^/]+)';
      }
      return seg.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    });
    const regex = new RegExp(`^/${regexParts.join('/')}$`);
    this.routes.push({ method: upper, pattern, regex, paramNames, handler, domain });
    return this;
  }

  get(pattern, handler, opts) { return this.add('GET', pattern, handler, opts); }
  post(pattern, handler, opts) { return this.add('POST', pattern, handler, opts); }
  put(pattern, handler, opts) { return this.add('PUT', pattern, handler, opts); }
  patch(pattern, handler, opts) { return this.add('PATCH', pattern, handler, opts); }
  delete(pattern, handler, opts) { return this.add('DELETE', pattern, handler, opts); }

  match(method, pathname) {
    const upper = (method || 'GET').toUpperCase();
    const allowedMethods = new Set();
    for (const route of this.routes) {
      const m = route.regex.exec(pathname);
      if (!m) continue;
      allowedMethods.add(route.method);
      if (route.method === upper || (upper === 'HEAD' && route.method === 'GET')) {
        const params = {};
        for (let i = 0; i < route.paramNames.length; i++) {
          try {
            params[route.paramNames[i]] = decodeURIComponent(m[i + 1]);
          } catch {
            throw new GbridgeError(400, 'gbridge/invalid_url', 'malformed percent-encoding in route parameter');
          }
        }
        return { kind: 'match', route, params };
      }
    }
    if (allowedMethods.size > 0) {
      return { kind: 'method_not_allowed', allowed: [...allowedMethods].sort() };
    }
    return { kind: 'not_found' };
  }
}

/**
 * Enforce DSH Connection auth on webServer routes or Bearer token auth on UDS routes.
 * Fails closed (503) if webServer mode has no connection service yet.
 */
export function lanCookieNameForPort(port) {
  const n = Number(port);
  return Number.isInteger(n) && n > 0 ? `gbridge-lan-auth-${n}` : 'gbridge-lan-auth';
}

export function admitRequest(req, { mode, ctx, bearerToken, lanPort } = {}) {
  let queryToken = null;
  try {
    queryToken = new URL(req.url || '/', 'http://gbridge.local').searchParams.get('token');
  } catch {}
  const reqToken = parseBearerToken(req) ?? queryToken;
  const resolveConnPeer = (conn) => {
    if (conn?.browserPeer && !conn.browserPeer.signal?.aborted) return conn.browserPeer;
    if (conn?.operator && !conn.operator.signal?.aborted) return conn.operator;
    return undefined;
  };
  if (mode === 'uds' || mode === 'lan') {
    if (!bearerToken) {
      return {
        ok: false,
        status: 503,
        code: 'gbridge/auth_unconfigured',
        message: `${mode.toUpperCase()} auth token missing`,
      };
    }
    const tokenOk = Boolean(reqToken && safeEqualString(reqToken, bearerToken));
    const scopedCookieName = lanCookieNameForPort(lanPort);
    const cookieOk = mode === 'lan' && (
      verifyLanCookieValue(parseCookieValue(req, scopedCookieName), bearerToken) ||
      (scopedCookieName !== 'gbridge-lan-auth' &&
        verifyLanCookieValue(parseCookieValue(req, 'gbridge-lan-auth'), bearerToken))
    );
    if (!tokenOk && !cookieOk) {
      return {
        ok: false,
        status: 401,
        code: 'gbridge/unauthorized',
        message: mode === 'lan' ? 'authentication required for LAN bridge' : 'invalid gbridge bearer token',
      };
    }
    if (mode === 'lan' && !tokenOk && cookieOk) {
      const secFetchSite = String(req.headers?.['sec-fetch-site'] || '').toLowerCase();
      if (secFetchSite === 'cross-site') {
        return {
          ok: false,
          status: 403,
          code: 'gbridge/cross_site_rejected',
          message: 'cross-site cookie request rejected',
        };
      }
      const originHeader = String(req.headers?.origin || '').trim();
      const hostHeader = String(req.headers?.host || '').trim().toLowerCase();
      if (originHeader && hostHeader) {
        try {
          const originHost = new URL(originHeader).host.toLowerCase();
          if (originHost !== hostHeader) {
            return {
              ok: false,
              status: 403,
              code: 'gbridge/origin_rejected',
              message: 'cross-origin cookie request rejected',
            };
          }
        } catch {
          return {
            ok: false,
            status: 403,
            code: 'gbridge/origin_rejected',
            message: 'malformed origin header',
          };
        }
      }
    }
    const connection = ctx.get?.('connection');
    return { ok: true, peer: resolveConnPeer(connection) };
  }
  const configuredToken = bearerToken || process.env.GBRIDGE_TOKEN || undefined;
  if (configuredToken && reqToken && safeEqualString(reqToken, configuredToken)) {
    const connection = ctx.get?.('connection');
    return { ok: true, peer: resolveConnPeer(connection) };
  }
  const connection = ctx.get?.('connection');
  if (!connection) {
    return { ok: false, status: 503, code: 'gbridge/host_unavailable', message: 'DSH connection guard not ready' };
  }
  if (typeof connection.admit === 'function') {
    const res = connection.admit(req);
    if (res && 'rejection' in res && res.rejection !== undefined) {
      const status = typeof res.rejection === 'number' ? res.rejection : 403;
      return {
        ok: false,
        status,
        code: status === 401 ? 'gbridge/unauthorized' : 'gbridge/forbidden',
        message: status === 401 ? 'authentication required' : 'request rejected by host guard',
      };
    }
    return { ok: true, peer: res?.peer ?? resolveConnPeer(connection) };
  }
  if (typeof connection.requestRejection === 'function') {
    const rejection = connection.requestRejection(req);
    if (rejection !== undefined) {
      const status = typeof rejection === 'number' ? rejection : 403;
      return {
        ok: false,
        status,
        code: status === 401 ? 'gbridge/unauthorized' : 'gbridge/forbidden',
        message: status === 401 ? 'authentication required' : 'request rejected by host guard',
      };
    }
    return { ok: true, peer: resolveConnPeer(connection) };
  }
  return { ok: false, status: 503, code: 'gbridge/host_unavailable', message: 'DSH connection guard lacks admit/requestRejection' };
}
