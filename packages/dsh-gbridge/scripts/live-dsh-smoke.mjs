#!/usr/bin/env node
/**
 * Live end-to-end smoke test against the real local `dsh web` binary using an
 * isolated temporary DSH_HOME (never touches the user's real ~/.dsh).
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { request as httpRequest } from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const HERE = resolve(fileURLToPath(import.meta.url), '..');
const PLUGIN_ENTRY = resolve(HERE, '../lib/index.js');

function pickFreePort() {
  return new Promise((res, rej) => {
    const s = createServer();
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => res(port));
    });
    s.on('error', rej);
  });
}

function httpReq(port, path, { method = 'GET', headers = {}, body } = {}) {
  return new Promise((res, rej) => {
    const raw = body !== undefined ? JSON.stringify(body) : undefined;
    const req = httpRequest({
      host: '127.0.0.1',
      port,
      path,
      method,
      headers: {
        host: `127.0.0.1:${port}`,
        ...(raw !== undefined ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(raw) } : {}),
        ...headers,
      },
    }, (r) => {
      const chunks = [];
      r.on('data', (c) => chunks.push(c));
      r.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json = null;
        try { json = text ? JSON.parse(text) : null; } catch {}
        res({ status: r.statusCode, headers: r.headers, text, json });
      });
    });
    req.on('error', rej);
    if (raw !== undefined) req.end(raw);
    else req.end();
  });
}

function wsConnect(port, path, cookie) {
  return new Promise((res, rej) => {
    const key = randomBytes(16).toString('base64');
    const expected = createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    const req = httpRequest({
      host: '127.0.0.1',
      port,
      path,
      headers: {
        host: `127.0.0.1:${port}`,
        cookie,
        upgrade: 'websocket',
        connection: 'Upgrade',
        'sec-websocket-key': key,
        'sec-websocket-version': '13',
      },
    });
    req.on('upgrade', (r, sock, head) => {
      assert.equal(r.headers['sec-websocket-accept'], expected);
      const msgs = [];
      let waiter = null;
      let buf = head || Buffer.alloc(0);
      const parse = () => {
        while (buf.length >= 2) {
          const op = buf[0] & 0x0f;
          let len = buf[1] & 0x7f;
          let off = 2;
          if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
          else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
          if (buf.length < off + len) return;
          const payload = buf.subarray(off, off + len);
          buf = buf.subarray(off + len);
          if (op === 0x1) {
            msgs.push(JSON.parse(payload.toString('utf8')));
            if (waiter) { const w = waiter; waiter = null; w(); }
          }
        }
      };
      sock.on('data', (c) => { buf = Buffer.concat([buf, c]); parse(); });
      parse();
      res({
        send(obj) {
          const p = Buffer.from(JSON.stringify(obj), 'utf8');
          const m = randomBytes(4);
          const masked = Buffer.allocUnsafe(p.length);
          for (let i = 0; i < p.length; i++) masked[i] = p[i] ^ m[i & 3];
          const hdr = p.length < 126
            ? Buffer.from([0x81, 0x80 | p.length])
            : (() => { const b = Buffer.alloc(4); b[0] = 0x81; b[1] = 0x80 | 126; b.writeUInt16BE(p.length, 2); return b; })();
          sock.write(Buffer.concat([hdr, m, masked]));
        },
        async next(ms = 3000) {
          if (msgs.length) return msgs.shift();
          await new Promise((ok, fail) => {
            const t = setTimeout(() => fail(new Error('WS timeout')), ms);
            waiter = () => { clearTimeout(t); ok(); };
          });
          return msgs.shift();
        },
        close() { try { sock.destroy(); } catch {} },
      });
    });
    req.on('response', (r) => rej(new Error(`WS upgrade failed HTTP ${r.statusCode}`)));
    req.on('error', rej);
    req.end();
  });
}

const work = mkdtempSync(join(tmpdir(), 'grassbag-live-dsh-'));
const dshHome = join(work, 'dsh-home');
const patchFile = join(work, 'gbridge.patch.yml');
const udsSocket = join(work, 'bridge.sock');
const udsToken = randomBytes(24).toString('hex');

writeFileSync(patchFile, `- insert:\n    - id: gbridge\n      name: ${JSON.stringify(PLUGIN_ENTRY)}\n`, 'utf8');

const port = await pickFreePort();
const dshBin = process.env.DSH_BIN || 'dsh';
console.log(`[live-smoke] Launching real ${dshBin} web on 127.0.0.1:${port} with isolated DSH_HOME=${dshHome}`);

const child = spawn(dshBin, [
  'web',
  '--patch', patchFile,
  '--host', '127.0.0.1',
  '--port', String(port),
  '--no-open',
], {
  env: {
    ...process.env,
    DSH_HOME: dshHome,
    GBRIDGE_UNIX_SOCKET: udsSocket,
    GBRIDGE_TOKEN: udsToken,
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});

let launchUrl = null;
let stderrLog = '';

const cleanup = () => {
  try { child.kill('SIGTERM'); } catch {}
  setTimeout(() => { try { child.kill('SIGKILL'); } catch {} }, 1500).unref();
  try { rmSync(work, { recursive: true, force: true }); } catch {}
};

try {
  launchUrl = await new Promise((resolveUrl, rejectUrl) => {
    const timer = setTimeout(() => rejectUrl(new Error(`dsh web startup timeout.\nstderr:\n${stderrLog}`)), 25000);
    const scan = (chunk) => {
      const text = chunk.toString('utf8');
      const m = text.match(/http:\/\/127\.0\.0\.1:\d+\/\?token=\S+/);
      if (m) {
        clearTimeout(timer);
        resolveUrl(m[0]);
      }
    };
    child.stdout.on('data', scan);
    child.stderr.on('data', (c) => { stderrLog += c.toString('utf8'); scan(c); });
    child.on('exit', (code) => {
      clearTimeout(timer);
      rejectUrl(new Error(`dsh web exited early with code ${code}.\nstderr:\n${stderrLog}`));
    });
  });

  console.log('[live-smoke] dsh web ready!');

  // 1. Unauthenticated must be rejected (401)
  const unauth = await httpReq(port, '/gbridge/v1/capabilities');
  assert.equal(unauth.status, 401, `Expected 401 unauthenticated, got ${unauth.status}: ${unauth.text}`);
  console.log('[live-smoke] PASS 1: unauthenticated /gbridge/v1/capabilities -> 401');

  // 2. Exchange launch token for real 30-day DSH cookie
  const u = new URL(launchUrl);
  const loginRes = await httpReq(port, `${u.pathname}${u.search}`);
  const setCookies = loginRes.headers['set-cookie'] || [];
  const authCookie = setCookies.map((c) => c.split(';')[0]).find((c) => c.startsWith('dsh-auth-'));
  assert.ok(authCookie, `Expected dsh-auth-* cookie, got headers: ${JSON.stringify(loginRes.headers)}`);
  console.log('[live-smoke] PASS 2: exchanged launch token for real dsh-auth-* cookie');

  const h = { cookie: authCookie };

  // 3. Capabilities
  const caps = await httpReq(port, '/gbridge/v1/capabilities', { headers: h });
  assert.equal(caps.status, 200, `capabilities failed: ${caps.text}`);
  assert.equal(caps.json.v, 1);
  assert.notEqual(caps.json.dshVersion, 'unknown', 'Expected resolved dshVersion');
  console.log('[live-smoke] PASS 3: /capabilities ->', JSON.stringify({
    dshVersion: caps.json.dshVersion,
    bridgeVersion: caps.json.bridgeVersion,
    endpointsCount: caps.json.endpointsCount,
    domains: Object.fromEntries(Object.entries(caps.json.domains).map(([k, v]) => [k, v.ok])),
  }));

  // 4. Overview
  const ov = await httpReq(port, '/gbridge/v1/overview', { headers: h });
  assert.equal(ov.status, 200, `overview failed: ${ov.text}`);
  assert.equal(ov.json.sessionsCount, 0);
  console.log('[live-smoke] PASS 4: /overview -> dshVersion =', ov.json.dshVersion, ', sessionsCount =', ov.json.sessionsCount);

  // 5. Sessions, Models, Presets, Plugins, Schedules, Remote FS Browse
  const sess = await httpReq(port, '/gbridge/v1/sessions', { headers: h });
  assert.equal(sess.status, 200, `sessions failed: ${sess.text}`);
  for (const ep of ['/gbridge/v1/models', '/gbridge/v1/presets', '/gbridge/v1/plugins/bundles', '/gbridge/v1/schedules', '/gbridge/v1/fs/browse']) {
    const r = await httpReq(port, ep, { headers: h });
    assert.equal(r.status, 200, `${ep} failed: ${r.text}`);
  }
  console.log('[live-smoke] PASS 5: /sessions, /models, /presets, /plugins/bundles, /schedules, /fs/browse -> all 200 OK');

  // 6. Settings Schemastery schema
  if (caps.json.domains.settings.ok) {
    const schema = await httpReq(port, '/gbridge/v1/settings/schema', { headers: h });
    assert.equal(schema.status, 200, `settings/schema failed: ${schema.text}`);
    console.log('[live-smoke] PASS 6: /settings/schema -> 200 OK');
  }

  // 7. SDUI built-in host-diagnostics view
  const sdui = await httpReq(port, '/gbridge/v1/sdui/views/host-diagnostics', { headers: h });
  assert.equal(sdui.status, 200, `sdui view failed: ${sdui.text}`);
  assert.equal(sdui.json.root.type, 'column');
  console.log('[live-smoke] PASS 7: /sdui/views/host-diagnostics -> 200 OK');

  // 8. WebUI escape-hatch ticket
  const ticket = await httpReq(port, '/gbridge/v1/web-ticket', { method: 'POST', headers: h, body: {} });
  assert.equal(ticket.status, 200, `web-ticket failed: ${ticket.text}`);
  assert.ok(ticket.json.authenticatedUrl.includes('?token='));
  console.log('[live-smoke] PASS 8: /web-ticket -> 200 OK');

  // 9. Live WebSocket /gbridge/v1/stream handshake + ping/pong
  const ws = await wsConnect(port, '/gbridge/v1/stream', authCookie);
  ws.send({ op: 'hello', v: 1, clientId: 'live-smoke-phone' });
  const welcome = await ws.next();
  assert.equal(welcome.op, 'welcome');
  assert.equal(welcome.bootId, caps.json.bootId);
  ws.send({ op: 'ping', id: 99 });
  const pong = await ws.next();
  assert.equal(pong.op, 'pong');
  assert.equal(pong.id, 99);
  ws.close();
  console.log('[live-smoke] PASS 9: WS /gbridge/v1/stream hello/welcome + ping/pong OK');

  // 10. Verify UDS 0600 local Android isolation listener simultaneously works!
  const udsRes = await new Promise((res, rej) => {
    const req = httpRequest({
      socketPath: udsSocket,
      path: '/gbridge/v1/capabilities',
      headers: { authorization: `Bearer ${udsToken}` },
    }, (r) => {
      const chunks = [];
      r.on('data', (c) => chunks.push(c));
      r.on('end', () => res({ status: r.statusCode, json: JSON.parse(Buffer.concat(chunks).toString('utf8')) }));
    });
    req.on('error', rej);
    req.end();
  });
  assert.equal(udsRes.status, 200);
  assert.equal(udsRes.json.bootId, caps.json.bootId);
  console.log('[live-smoke] PASS 10: UDS 0600 listener -> 200 OK (same bootId)');

  console.log('\n✅ ALL 10 LIVE DSH SMOKE CHECKS PASSED!');
} finally {
  cleanup();
}
