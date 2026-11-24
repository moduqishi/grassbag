import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request as httpRequest } from 'node:http';
import { randomBytes, createHash } from 'node:crypto';
import { mkdtempSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createGbridgeCore, PREFIX, STREAM_PATH, apply, startLanBridgeListener } from '../lib/index.js';
import { detectSecretRanges } from '../lib/normalizer.js';
import { parseUrl } from '../lib/http-util.js';

function createMockDshEnv() {
  const calls = [];
  const endpoints = new Set([
    'session/list', 'session/create', 'session/page', 'session/prompt', 'session/cancel',
    'session/rename', 'session/search', 'session/projections', 'session/follow', 'session/modelCatalog',
    'workspace/create', 'workspaceFiles/list', 'workspaceFiles/read', 'workspaceFiles/changes',
    'directoryPicker/list', 'terminal/list', 'terminal/create', 'terminal/write', 'terminal/resize', 'terminal/follow',
    'schedule/catalog', 'pluginManager/listBundles', 'pluginManager/installBundle', 'pluginInventory/list',
    'dynamicCordisRunner/inventory', 'settings/describe', 'settings/mutate', 'agentPresets/list',
    'appAuth/usage', 'cotTranslation/translate', 'goals/get', 'goals/create', 'permissionPresets/catalog',
  ]);

  let eventPush;
  const eventQueue = [];
  let eventDone = false;

  const pushHostEvent = (frame) => {
    eventQueue.push(frame);
    if (eventPush) {
      const fn = eventPush;
      eventPush = null;
      fn();
    }
  };

  const mockGateway = {
    claimsEndpoint: (ep) => endpoints.has(ep),
    collectSrcClaims: () => [...endpoints],
    operatorPeer: () => ({ id: 'op-1' }),
    async dispatchRpc(endpoint, payload) {
      calls.push({ endpoint, args: payload.args });
      if (endpoint === '$events/result') {
        return { ok: true, value: undefined };
      }
      if (endpoint === 'session/list') {
        return { ok: true, value: [{ id: 's1', title: 'Test Chat' }] };
      }
      if (endpoint === 'session/page') {
        return {
          ok: true,
          value: {
            events: [
              { seq: 1, type: 'user/message', id: 'u1', data: { text: 'My key is sk-1234567890abcdef123456 please check' } },
              {
                seq: 2,
                type: 'assistant/message',
                data: {
                  content: [
                    { type: 'reasoning', text: 'First line thinking\nSecond line details' },
                    { type: 'tool-call', id: 'tc1', name: 'bash', arguments: { command: 'ls -la' } },
                    { type: 'text', text: 'All done!' },
                  ],
                },
              },
              { seq: 3, type: 'tool/result', data: { callId: 'tc1', name: 'bash', output: 'A'.repeat(350) } },
              { seq: 4, type: 'turn/end', data: { reason: 'completed', usage: { inputTokens: 100, outputTokens: 25 } } },
            ],
            hasMore: false,
          },
        };
      }
      if (endpoint === 'session/projections') {
        return { ok: true, value: { todos: [{ text: 'Run tests', done: true }] } };
      }
      if (endpoint === 'appAuth/usage') {
        return { ok: true, value: { balance: 42.5, currency: 'CNY' } };
      }
      if (endpoint === 'settings/describe') {
        return { ok: true, value: { namespaces: { general: { type: 'object' } } } };
      }
      return { ok: true, value: { echoed: endpoint, args: payload.args } };
    },
    async *openRemoteEvents(_payload, signal) {
      yield { type: 'ready', clientId: 'gw-client-1', host: { home: '/root' } };
      while (!signal?.aborted && !eventDone) {
        if (eventQueue.length > 0) {
          yield eventQueue.shift();
        } else {
          await new Promise((r) => {
            eventPush = r;
            signal?.addEventListener('abort', r, { once: true });
          });
        }
      }
    },
    async stream({ namespace, method, args, signal }) {
      calls.push({ stream: `${namespace}/${method}`, args });
      async function* gen() {
        if (namespace === 'terminal') {
          yield { data: 'hello ' };
          yield { data: 'world\n' };
        } else {
          yield { type: 'text-chunks', text: 'Hi ' };
          yield { type: 'text-chunks', text: 'GrassBag!' };
          yield { type: 'turn/end', reason: 'completed' };
        }
        await new Promise((r) => signal?.addEventListener('abort', r, { once: true }));
      }
      return gen();
    },
  };

  let admitted = true;
  const services = new Map([
    ['typertGateway', mockGateway],
    ['typert', { local: { list: () => [] } }],
    ['connection', {
      operator: { id: 'op-1' },
      admit: (req) => (admitted && req.headers.cookie === 'dsh-auth=valid' ? { peer: { id: 'op-1' } } : { rejection: 401 }),
      authenticatedUrl: (base) => `${base}/?token=ephemeral-test-token`,
    }],
    ['webServer', { host: '127.0.0.1', port: 3080 }],
  ]);

  const ctx = {
    get: (key) => services.get(key),
    logger: { warn: () => {}, info: () => {} },
  };

  return {
    ctx,
    calls,
    pushHostEvent,
    setAdmitted: (v) => { admitted = v; },
    stopEvents: () => { eventDone = true; pushHostEvent({ type: 'noop' }); },
  };
}

function sendClientWsFrame(socket, text) {
  const payload = Buffer.from(text, 'utf8');
  const mask = randomBytes(4);
  const masked = Buffer.allocUnsafe(payload.length);
  for (let i = 0; i < payload.length; i++) masked[i] = payload[i] ^ mask[i & 3];
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, 0x80 | payload.length]);
  } else {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(payload.length, 2);
  }
  socket.write(Buffer.concat([header, mask, masked]));
}

function connectRawWs(options, headers = {}) {
  return new Promise((resolve, reject) => {
    const key = randomBytes(16).toString('base64');
    const expectedAccept = createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    const req = httpRequest({
      ...options,
      headers: {
        upgrade: 'websocket',
        connection: 'Upgrade',
        'sec-websocket-key': key,
        'sec-websocket-version': '13',
        ...headers,
      },
    });
    req.on('upgrade', (res, socket, head) => {
      assert.equal(res.headers['sec-websocket-accept'], expectedAccept);
      const messages = [];
      let waiter = null;
      let buf = head || Buffer.alloc(0);
      const parse = () => {
        while (buf.length >= 2) {
          const op = buf[0] & 0x0f;
          let len = buf[1] & 0x7f;
          let off = 2;
          if (len === 126) {
            if (buf.length < 4) return;
            len = buf.readUInt16BE(2);
            off = 4;
          } else if (len === 127) {
            if (buf.length < 10) return;
            len = Number(buf.readBigUInt64BE(2));
            off = 10;
          }
          if (buf.length < off + len) return;
          const payload = buf.subarray(off, off + len);
          buf = buf.subarray(off + len);
          if (op === 0x1) {
            messages.push(JSON.parse(payload.toString('utf8')));
            if (waiter) { const w = waiter; waiter = null; w(); }
          }
        }
      };
      socket.on('data', (c) => { buf = Buffer.concat([buf, c]); parse(); });
      parse();
      resolve({
        socket,
        send: (obj) => sendClientWsFrame(socket, JSON.stringify(obj)),
        async nextMessage(timeoutMs = 2000) {
          if (messages.length > 0) return messages.shift();
          await new Promise((resW, rejW) => {
            const t = setTimeout(() => rejW(new Error('WS message timeout')), timeoutMs);
            waiter = () => { clearTimeout(t); resW(); };
          });
          return messages.shift();
        },
        close: () => { try { socket.destroy(); } catch {} },
      });
    });
    req.on('response', (res) => reject(new Error(`Unexpected HTTP ${res.statusCode}`)));
    req.on('error', reject);
    req.end();
  });
}

function httpJson(options, { method = 'GET', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const raw = body !== undefined ? JSON.stringify(body) : undefined;
    const req = httpRequest({
      ...options,
      method,
      headers: {
        ...(raw !== undefined ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(raw) } : {}),
        ...headers,
      },
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        resolve({ status: res.statusCode, headers: res.headers, json: text ? JSON.parse(text) : null });
      });
    });
    req.on('error', reject);
    if (raw !== undefined) req.end(raw);
    else req.end();
  });
}

test('detectSecretRanges masks API keys accurately', () => {
  const ranges = detectSecretRanges('token sk-abcdef1234567890abcd and ghp_1234567890abcdefghij1234');
  assert.equal(ranges.length, 2);
  assert.equal(ranges[0].visiblePrefix, 8);
});

test('HTTP auth guard, capabilities, overview, normalized turns, lazy tool output, SDUI, web-ticket', async (t) => {
  const env = createMockDshEnv();
  const core = createGbridgeCore(env.ctx, { bootId: 'boot-test-1' });
  const server = createServer((req, res) => core.handleHttp(req, res, { mode: 'webServer' }));
  server.on('upgrade', (req, sock, head) => core.handleUpgrade(req, sock, head, { mode: 'webServer' }));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  t.after(() => { env.stopEvents(); core.dispose(); server.closeAllConnections?.(); server.close(); });

  const authHeaders = { cookie: 'dsh-auth=valid' };

  // 1. Unauthenticated must fail closed with 401
  const unauth = await httpJson({ host: '127.0.0.1', port, path: `${PREFIX}/capabilities` });
  assert.equal(unauth.status, 401);
  assert.equal(unauth.json.error.code, 'gbridge/unauthorized');

  // 2. Authenticated capabilities
  const caps = await httpJson({ host: '127.0.0.1', port, path: `${PREFIX}/capabilities` }, { headers: authHeaders });
  assert.equal(caps.status, 200);
  assert.equal(caps.json.v, 1);
  assert.equal(caps.json.bootId, 'boot-test-1');
  assert.equal(caps.json.domains.chat.ok, true);
  assert.equal(caps.json.domains.sdui.ok, true);

  // 3. Single-request overview aggregate
  const ov = await httpJson({ host: '127.0.0.1', port, path: `${PREFIX}/overview` }, { headers: authHeaders });
  assert.equal(ov.status, 200);
  assert.equal(ov.json.account.balance, 42.5);
  assert.equal(ov.json.sessionsCount, 1);

  // 4. Normalized turns + secret masking + lazy full tool output
  const turnsRes = await httpJson({ host: '127.0.0.1', port, path: `${PREFIX}/sessions/s1/turns` }, { headers: authHeaders });
  assert.equal(turnsRes.status, 200);
  assert.equal(turnsRes.json.turns.length, 1);
  const turn = turnsRes.json.turns[0];
  assert.equal(turn.userMessage.maskedRanges.length, 1);
  assert.equal(turn.assistantText, 'All done!');
  assert.equal(turn.steps.length, 2);
  assert.equal(turn.steps[0].kind, 'reasoning');
  assert.equal(turn.steps[0].collapsedPreview, 'First line thinking');
  assert.equal(turn.steps[1].kind, 'tool');
  assert.equal(turn.steps[1].hasFullOutput, true);

  const toolRes = await httpJson({ host: '127.0.0.1', port, path: `${PREFIX}/sessions/s1/tools/tc1` }, { headers: authHeaders });
  assert.equal(toolRes.status, 200);
  assert.equal(toolRes.json.tool.output.length, 350);

  // 5. SDUI built-in host-diagnostics view
  const sduiList = await httpJson({ host: '127.0.0.1', port, path: `${PREFIX}/sdui/surfaces` }, { headers: authHeaders });
  assert.equal(sduiList.status, 200);
  assert.ok(sduiList.json.surfaces.some((s) => s.id === 'host-diagnostics'));
  const sduiView = await httpJson({ host: '127.0.0.1', port, path: `${PREFIX}/sdui/views/host-diagnostics` }, { headers: authHeaders });
  assert.equal(sduiView.status, 200);
  assert.equal(sduiView.json.root.type, 'column');

  // 6. WebUI escape-hatch ticket
  const ticketRes = await httpJson({ host: '127.0.0.1', port, path: `${PREFIX}/web-ticket` }, {
    method: 'POST', headers: authHeaders, body: { sessionId: 's1' },
  });
  assert.equal(ticketRes.status, 200);
  assert.match(ticketRes.json.authenticatedUrl, /\?token=ephemeral-test-token/);

  // 7. Unknown route -> 404 structured JSON, wrong method -> 405
  const nf = await httpJson({ host: '127.0.0.1', port, path: `${PREFIX}/nope` }, { headers: authHeaders });
  assert.equal(nf.status, 404);
  assert.equal(nf.json.error.code, 'gbridge/route_not_found');
  const mna = await httpJson({ host: '127.0.0.1', port, path: `${PREFIX}/capabilities` }, { method: 'DELETE', headers: authHeaders });
  assert.equal(mna.status, 405);
});

test('WS /gbridge/v1/stream: hello, delta coalescing, resumeFromSeq replay, and interaction settlement', async (t) => {
  const env = createMockDshEnv();
  const core = createGbridgeCore(env.ctx, { bootId: 'boot-ws-1' });
  core.hub.startHostEventPump();
  const server = createServer((req, res) => core.handleHttp(req, res, { mode: 'webServer' }));
  server.on('upgrade', (req, sock, head) => core.handleUpgrade(req, sock, head, { mode: 'webServer' }));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  t.after(() => { env.stopEvents(); core.dispose(); server.closeAllConnections?.(); server.close(); });

  const authHeaders = { cookie: 'dsh-auth=valid' };

  // Unauthenticated WS upgrade must be rejected
  await assert.rejects(() => connectRawWs({ host: '127.0.0.1', port, path: STREAM_PATH }));

  // Connect client 1
  const ws1 = await connectRawWs({ host: '127.0.0.1', port, path: STREAM_PATH }, authHeaders);
  ws1.send({ op: 'hello', v: 1, clientId: 'phone-1', coalesceMs: 25 });
  const welcome1 = await ws1.nextMessage();
  assert.equal(welcome1.op, 'welcome');
  assert.equal(welcome1.bootId, 'boot-ws-1');
  assert.equal(welcome1.resumed, false);

  // Trigger an approval request from DSH host event stream
  env.pushHostEvent({
    type: 'request',
    event: 'approval/request',
    eventId: 'ev-approve-1',
    request: { sessionId: 's1', tool: 'bash', command: 'rm -rf /tmp/x' },
  });
  const reqEv = await ws1.nextMessage();
  assert.equal(reqEv.type, 'interaction.requested');
  assert.equal(reqEv.data.id, 'ev-approve-1');
  const lastSeenSeq = reqEv.seq;

  // Disconnect client 1, then settle the interaction via HTTP while disconnected
  ws1.close();
  const settle = await httpJson({ host: '127.0.0.1', port, path: `${PREFIX}/interactions/ev-approve-1/respond` }, {
    method: 'POST', headers: authHeaders, body: { decision: { allow: true } },
  });
  assert.equal(settle.status, 200);
  assert.equal(settle.json.settled, true);

  // Reconnect with resumeFromSeq -> must replay the missed `interaction.resolved` event!
  const ws2 = await connectRawWs({ host: '127.0.0.1', port, path: STREAM_PATH }, authHeaders);
  ws2.send({ op: 'hello', v: 1, clientId: 'phone-1', lastBootId: 'boot-ws-1', resumeFromSeq: lastSeenSeq, coalesceMs: 25 });
  const welcome2 = await ws2.nextMessage();
  assert.equal(welcome2.resumed, true);
  assert.equal(welcome2.replayedCount, 1);
  const replayed = await ws2.nextMessage();
  assert.equal(replayed.type, 'interaction.resolved');
  assert.equal(replayed.data.id, 'ev-approve-1');

  // Subscribe to terminal stream and verify delta coalescing + term.input
  ws2.send({ op: 'sub', channel: 'terminal:t1' });
  const termFrame = await ws2.nextMessage();
  assert.equal(termFrame.channel, 'terminal:t1');
  assert.equal(termFrame.type, 'term.data');
  assert.equal(termFrame.data.chunk, 'hello world\n');

  ws2.close();
});

test('Android local 0600 Unix Domain Socket listener isolates auth with Bearer token', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'gbridge-uds-'));
  const socketPath = join(dir, 'bridge.sock');
  const token = 'secret-uds-token-1234567890';
  const env = createMockDshEnv();

  const effects = [];
  const fakeCtx = {
    ...env.ctx,
    provide: () => {},
    effect: (fn) => { const d = fn(); if (typeof d === 'function') effects.push(d); },
    inject: () => {},
  };

  apply(fakeCtx, { unixSocket: socketPath, unixToken: token, isLocalAndroid: true });
  await new Promise((r) => setTimeout(r, 80));
  t.after(() => {
    for (const d of effects.reverse()) d();
    env.stopEvents();
    rmSync(dir, { recursive: true, force: true });
  });

  // Verify 0600 permission on Unix Domain Socket
  const mode = statSync(socketPath).mode & 0o777;
  assert.equal(mode, 0o600);

  // Wrong token rejected
  const bad = await httpJson({ socketPath, path: `${PREFIX}/capabilities` }, {
    headers: { authorization: 'Bearer wrong-token' },
  });
  assert.equal(bad.status, 401);

  // Correct Bearer token succeeds
  const ok = await httpJson({ socketPath, path: `${PREFIX}/capabilities` }, {
    headers: { authorization: `Bearer ${token}` },
  });
  assert.equal(ok.status, 200);
  assert.equal(ok.json.host.isLocalAndroid, true);

  // WS over UDS works too!
  const ws = await connectRawWs({ socketPath, path: STREAM_PATH }, {
    authorization: `Bearer ${token}`,
  });
  ws.send({ op: 'hello', v: 1, clientId: 'android-local' });
  const welcome = await ws.nextMessage();
  assert.equal(welcome.op, 'welcome');
  ws.close();
});

test('Cordis plugin reload preserves latched env secrets and hot-swaps UDS without dropping bridge.sock', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'gbridge-reload-'));
  const socketPath = join(dir, 'bridge.sock');
  const token = 'reload-latched-token-9876543210';
  const prevEnv = {
    GBRIDGE_UNIX_SOCKET: process.env.GBRIDGE_UNIX_SOCKET,
    GBRIDGE_TOKEN: process.env.GBRIDGE_TOKEN,
    GBRIDGE_LOCAL_ANDROID: process.env.GBRIDGE_LOCAL_ANDROID,
  };
  process.env.GBRIDGE_UNIX_SOCKET = socketPath;
  process.env.GBRIDGE_TOKEN = token;
  process.env.GBRIDGE_LOCAL_ANDROID = '1';

  const env1 = createMockDshEnv();
  const env2 = createMockDshEnv();
  const effects1 = [];
  const effects2 = [];
  const fakeCtx1 = {
    ...env1.ctx,
    provide: () => {},
    effect: (fn) => { const d = fn(); if (typeof d === 'function') effects1.push(d); },
    inject: () => {},
  };
  const fakeCtx2 = {
    ...env2.ctx,
    provide: () => {},
    effect: (fn) => { const d = fn(); if (typeof d === 'function') effects2.push(d); },
    inject: () => {},
  };

  t.after(() => {
    for (const d of effects2.reverse()) d();
    env1.stopEvents();
    env2.stopEvents();
    for (const [k, v] of Object.entries(prevEnv)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    rmSync(dir, { recursive: true, force: true });
  });

  // First Cordis apply: binds UDS and scrubs process.env.GBRIDGE_TOKEN
  apply(fakeCtx1, {});
  assert.equal(process.env.GBRIDGE_TOKEN, undefined);
  await new Promise((r) => setTimeout(r, 80));

  // Simulate Cordis plugin reload: dispose 1st apply, then invoke 2nd apply with scrubbed env
  for (const d of effects1.reverse()) d();
  await new Promise((r) => setTimeout(r, 40));
  apply(fakeCtx2, {});
  await new Promise((r) => setTimeout(r, 80));

  // UDS socket must still exist with 0600 permissions and accept the original Bearer token!
  assert.equal(statSync(socketPath).mode & 0o777, 0o600);
  const ok = await httpJson({ socketPath, path: `${PREFIX}/capabilities` }, {
    headers: { authorization: `Bearer ${token}` },
  });
  assert.equal(ok.status, 200);
  assert.equal(ok.json.host.isLocalAndroid, true);
});

test('WS hello with channels subscribes upstream session stream on reconnect without silent drop', async (t) => {
  const env = createMockDshEnv();
  const core = createGbridgeCore(env.ctx, { bootId: 'boot-reconnect-1' });
  const server = createServer((req, res) => core.handleHttp(req, res, { mode: 'webServer' }));
  server.on('upgrade', (req, sock, head) => core.handleUpgrade(req, sock, head, { mode: 'webServer' }));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  t.after(() => { env.stopEvents(); core.dispose(); server.closeAllConnections?.(); server.close(); });

  const authHeaders = { cookie: 'dsh-auth=valid' };
  const ws = await connectRawWs({ host: '127.0.0.1', port, path: STREAM_PATH }, authHeaders);
  ws.send({
    op: 'hello',
    v: 1,
    clientId: 'reconnect-phone',
    channels: ['session:s1'],
    coalesceMs: 10,
  });
  const welcome = await ws.nextMessage();
  assert.equal(welcome.op, 'welcome');

  const receivedTypes = [];
  let textChunk = '';
  for (let i = 0; i < 4; i++) {
    const frame = await ws.nextMessage();
    receivedTypes.push(frame.type);
    if (frame.type === 'turn.delta') {
      if (Array.isArray(frame.data?.chunks)) {
        textChunk += frame.data.chunks.map((c) => c?.text ?? '').join('');
      } else {
        textChunk += frame.data?.chunk?.text ?? '';
      }
    }
    if (frame.type === 'turn.completed') break;
  }
  assert.ok(env.calls.some((c) => c.stream === 'session/follow'), 'upstream session/follow must be subscribed');
  assert.ok(receivedTypes.includes('turn.completed'), `expected turn.completed, got ${receivedTypes.join(',')}`);
  assert.equal(textChunk, 'Hi GrassBag!');
  ws.close();
});

test('Desktop LAN Bridge advertises surface="desktop", persists 0600 token, exchanges 30-day cookie, and serves HTTP + WS', async (t) => {
  const dshHome = mkdtempSync(join(tmpdir(), 'gbridge-desktop-lan-'));
  const prevDshHome = process.env.DSH_HOME;
  process.env.DSH_HOME = dshHome;

  const env = createMockDshEnv();
  const core = createGbridgeCore(env.ctx, { bootId: 'boot-desktop-lan-1' });
  const listener = startLanBridgeListener(core, {
    host: '127.0.0.1',
    port: 0,
    surface: 'desktop',
    logger: { info() {}, warn() {} },
  });

  t.after(() => {
    listener.dispose();
    env.stopEvents();
    core.dispose();
    if (prevDshHome === undefined) delete process.env.DSH_HOME;
    else process.env.DSH_HOME = prevDshHome;
    rmSync(dshHome, { recursive: true, force: true });
  });

  // Wait briefly for OS ephemeral port bind
  let port = 0;
  for (let i = 0; i < 30; i++) {
    const addr = listener.address();
    if (addr && typeof addr === 'object' && addr.port > 0) {
      port = addr.port;
      break;
    }
    await new Promise((r) => setTimeout(r, 10));
  }
  assert.ok(port > 0, 'LAN bridge must bind ephemeral port');

  // Persisted 0600 token file created under DSH_HOME
  const tokenPath = join(dshHome, 'gbridge-lan-token');
  assert.equal(statSync(tokenPath).mode & 0o777, 0o600);
  assert.ok(listener.token.length >= 16);

  // 1) Public /plugins/events SSE advertises surface: "desktop" and hasGbridge: true without auth
  const sseText = await new Promise((resolve, reject) => {
    const req = httpRequest({ host: '127.0.0.1', port, path: '/plugins/events', method: 'GET' }, (res) => {
      let data = '';
      res.on('data', (chunk) => {
        data += chunk.toString('utf8');
        if (data.includes('\n\n')) {
          req.destroy();
          resolve(data);
        }
      });
      res.on('end', () => resolve(data));
    });
    req.on('error', (err) => {
      if (err.code === 'ECONNRESET') return;
      reject(err);
    });
    req.end();
  });
  assert.ok(sseText.includes('"surface":"desktop"'), `expected desktop surface in SSE: ${sseText}`);
  assert.ok(sseText.includes('"hasGbridge":true'), `expected hasGbridge in SSE: ${sseText}`);

  // 2) Unauthenticated capabilities -> 401; unauthenticated GET / -> 401 HTML token form (renders in browser/WebView while signaling auth required)
  const unauthCaps = await httpJson({ host: '127.0.0.1', port, path: `${PREFIX}/capabilities` });
  assert.equal(unauthCaps.status, 401);

  const loginPage = await new Promise((resolve, reject) => {
    const req = httpRequest({ host: '127.0.0.1', port, path: '/', method: 'GET' }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    req.end();
  });
  assert.equal(loginPage.status, 401);
  assert.ok(String(loginPage.headers['content-type'] || '').includes('text/html'));
  assert.ok(loginPage.body.includes('name="token"'));

  // 3) Token exchange GET /?token=... -> 303 + 30-day gbridge-lan-auth HttpOnly cookie
  const exchange = await new Promise((resolve, reject) => {
    const req = httpRequest(
      { host: '127.0.0.1', port, path: `/?token=${encodeURIComponent(listener.token)}`, method: 'GET' },
      (res) => {
        res.resume();
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers }));
      },
    );
    req.on('error', reject);
    req.end();
  });
  assert.equal(exchange.status, 303);
  const setCookie = Array.isArray(exchange.headers['set-cookie'])
    ? exchange.headers['set-cookie'][0]
    : String(exchange.headers['set-cookie'] || '');
  assert.ok(setCookie.includes('gbridge-lan-auth='), `expected gbridge-lan-auth cookie, got ${setCookie}`);
  assert.ok(setCookie.includes('SameSite=Strict'), `expected SameSite=Strict cookie, got ${setCookie}`);
  assert.ok(setCookie.includes('Max-Age=2592000'));
  const cookiePair = setCookie.split(';')[0];

  // Cross-site / cross-origin cookie request must be rejected with 403 (CSWSH/CSRF protection)
  const crossSiteCaps = await httpJson(
    { host: '127.0.0.1', port, path: `${PREFIX}/capabilities` },
    { headers: { cookie: cookiePair, origin: 'https://evil.example', 'sec-fetch-site': 'cross-site' } },
  );
  assert.equal(crossSiteCaps.status, 403);

  // 4) Both signed Cookie (without Bearer) AND Bearer token admit HTTP + WS!
  const cookieCaps = await httpJson(
    { host: '127.0.0.1', port, path: `${PREFIX}/capabilities` },
    { headers: { cookie: cookiePair } },
  );
  assert.equal(cookieCaps.status, 200);
  assert.equal(cookieCaps.json.bridgeVersion, '0.1.0');

  const bearerCaps = await httpJson(
    { host: '127.0.0.1', port, path: `${PREFIX}/capabilities` },
    { headers: { authorization: `Bearer ${listener.token}` } },
  );
  assert.equal(bearerCaps.status, 200);

  const ws = await connectRawWs({ host: '127.0.0.1', port, path: STREAM_PATH }, { cookie: cookiePair });
  ws.send({ op: 'hello', v: 1, clientId: 'phone-desktop-lan', channels: [] });
  const welcome = await ws.nextMessage();
  assert.equal(welcome.op, 'welcome');
  assert.equal(welcome.bootId, 'boot-desktop-lan-1');
  ws.close();
});
