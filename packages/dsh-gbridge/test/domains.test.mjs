import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request as httpRequest } from 'node:http';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createGbridgeCore, PREFIX, startLanBridgeListener } from '../lib/index.js';
import { SessionNormalizer } from '../lib/normalizer.js';
import { mountPhoneTools } from '../lib/phone-tools.js';

function jsonReq(port, path, { method = 'GET', body, cookie = 'dsh-auth=ok' } = {}) {
  return new Promise((resolve, reject) => {
    const raw = body !== undefined ? JSON.stringify(body) : undefined;
    const req = httpRequest({
      host: '127.0.0.1',
      port,
      path: `${PREFIX}${path}`,
      method,
      headers: {
        cookie,
        ...(raw !== undefined ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(raw) } : {}),
      },
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        resolve({ status: res.statusCode, json: text ? JSON.parse(text) : null });
      });
    });
    req.on('error', reject);
    if (raw !== undefined) req.end(raw);
    else req.end();
  });
}

test('all 12 domains dispatch cleanly to typertGateway and isolate unsupported endpoints', async (t) => {
  const dispatched = [];
  const supported = new Set([
    'session/list', 'session/prompt', 'session/cancel', 'session/fork', 'session/updateQueue',
    'session/modelCatalog', 'session/selectModel', 'commands/execute', 'skills/list',
    'workspace/create', 'workspace/rename', 'workspace/delete', 'directoryPicker/list',
    'workspaceFiles/list', 'workspaceFiles/read', 'workspaceFiles/changes',
    'terminal/list', 'terminal/create', 'terminal/rename', 'terminal/resize', 'terminal/close',
    'schedule/catalog', 'schedule/edit', 'schedule/run', 'schedule/delete',
    'pluginManager/listBundles', 'pluginManager/installBundle', 'pluginManager/setBundleEnabled',
    'pluginInventory/list', 'dynamicCordisRunner/inventory', 'dynamicCordisRunner/stopFromPanel',
    'settings/describe', 'settings/mutate', 'agentPresets/list', 'agentPresets/select',
    'llm/listProviders', 'credentials/describe', 'credentials/set', 'appAuth/list', 'appAuth/begin',
    'goals/get', 'goals/create', 'goals/pause', 'job/kill', 'subagents/prompt', 'cotTranslation/translate',
  ]);

  const gw = {
    claimsEndpoint: (ep) => supported.has(ep),
    collectSrcClaims: () => [...supported],
    operatorPeer: () => ({ id: 'op' }),
    async dispatchRpc(endpoint, payload) {
      dispatched.push({ endpoint, args: payload.args });
      return { ok: true, value: { ok: true, endpoint, args: payload.args } };
    },
  };
  const ctx = {
    get: (k) => ({
      typertGateway: gw,
      typert: { local: { list: () => [] } },
      connection: { admit: () => ({ peer: { id: 'op' } }) },
      webServer: { host: '127.0.0.1', port: 3080 },
    })[k],
    logger: { warn: () => {} },
  };

  const core = createGbridgeCore(ctx, { bootId: 'boot-domains-1' });
  const server = createServer((req, res) => core.handleHttp(req, res, { mode: 'webServer' }));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  t.after(() => { core.dispose(); server.closeAllConnections?.(); server.close(); });

  // Chat interrupt mode calls session/cancel BEFORE session/prompt
  const sendRes = await jsonReq(port, '/sessions/s1/messages', {
    method: 'POST',
    body: { text: 'stop and do X', mode: 'interrupt', clientRequestId: 'req-1' },
  });
  assert.equal(sendRes.status, 200);
  assert.equal(dispatched[0].endpoint, 'session/cancel');
  assert.equal(dispatched[1].endpoint, 'session/prompt');
  assert.equal(dispatched[1].args.requestId, 'req-1');

  // Workspaces & files
  assert.equal((await jsonReq(port, '/workspaces', { method: 'POST', body: { path: '/root/proj' } })).status, 201);
  assert.equal((await jsonReq(port, '/workspaces/w1/files/tree?path=src')).status, 200);
  assert.equal((await jsonReq(port, '/workspaces/w1/files/read?path=README.md')).status, 200);
  assert.equal((await jsonReq(port, '/workspaces/w1/files/changes')).status, 200);

  // Terminal CRUD
  assert.equal((await jsonReq(port, '/terminals', { method: 'POST', body: { sessionId: 's1' } })).status, 201);
  assert.equal((await jsonReq(port, '/terminals/t1', { method: 'PATCH', body: { title: 'zsh', cols: 100, rows: 30 } })).status, 200);
  assert.equal((await jsonReq(port, '/terminals/t1', { method: 'DELETE' })).status, 200);

  // Schedule, Plugins, Dynamic Cordis, Settings, Presets, Accounts, Experimental
  assert.equal((await jsonReq(port, '/schedules')).status, 200);
  assert.equal((await jsonReq(port, '/schedules/sc1/run', { method: 'POST' })).status, 200);
  assert.equal((await jsonReq(port, '/plugins/bundles')).status, 200);
  assert.equal((await jsonReq(port, '/plugins/install', { method: 'POST', body: { spec: 'dsh-gbridge' } })).status, 200);
  assert.equal((await jsonReq(port, '/cordis/dynamic/dyn1/stop', { method: 'POST' })).status, 200);
  assert.equal((await jsonReq(port, '/settings/schema')).status, 200);
  assert.equal((await jsonReq(port, '/settings', { method: 'PATCH', body: { key: 'a', value: 1 } })).status, 200);
  assert.equal((await jsonReq(port, '/presets')).status, 200);
  assert.equal((await jsonReq(port, '/models')).status, 200);
  assert.equal((await jsonReq(port, '/auth/subscriptions/begin', { method: 'POST', body: { provider: 'claude' } })).status, 200);
  assert.equal((await jsonReq(port, '/sessions/s1/goals', { method: 'POST', body: { action: 'pause' } })).status, 200);
  assert.equal((await jsonReq(port, '/tools/translate-cot', { method: 'POST', body: { text: 'hello' } })).status, 200);

  // Unsupported endpoint degrades cleanly with 501 gbridge/endpoint_unsupported (never 500!)
  const unsup = await jsonReq(port, '/speech/catalog');
  assert.equal(unsup.status, 501);
  assert.equal(unsup.json.error.code, 'gbridge/endpoint_unsupported');
});

test('zero-patch phone tools bridge forwards caller sessionId/turnId and turn/end over UDS', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'gbridge-phone-'));
  const socketPath = join(dir, 'phone.sock');
  const token = 'phone-secret-token';
  const received = [];

  const daemon = createServer((req, res) => {
    assert.equal(req.headers.authorization, `Bearer ${token}`);
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      received.push({ path: req.url, body: JSON.parse(Buffer.concat(chunks).toString('utf8')) });
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, elements: [{ id: 1, label: 'Send' }] }));
    });
  });
  await new Promise((r) => daemon.listen(socketPath, r));

  const registeredTools = new Map();
  let sessionEventListener = null;
  const fakeCtx = {
    get: (k) => (k === 'tools' ? {
      register: (tool) => { registeredTools.set(tool.name, tool); return () => registeredTools.delete(tool.name); },
    } : undefined),
    on: (ev, fn) => { if (ev === 'session/event') sessionEventListener = fn; return () => {}; },
  };

  const phone = mountPhoneTools(fakeCtx, { socketPath, token });
  t.after(() => {
    phone.dispose();
    daemon.closeAllConnections?.();
    daemon.close();
    rmSync(dir, { recursive: true, force: true });
  });

  assert.equal(phone.active, true);
  assert.equal(phone.registered, 12);
  assert.ok(registeredTools.has('phone_screen'));
  assert.ok(registeredTools.has('phone_apps'));
  assert.ok(registeredTools.has('phone_screenshot'));
  assert.equal(registeredTools.has('phone_shell'), false);

  const result = await registeredTools.get('phone_screen').execute(
    { includeScreenshot: false },
    { agent: { session: { id: 'sess-42' } }, turnId: 'turn-7' },
  );
  assert.equal(result.ok, true);
  assert.equal(received[0].path, '/v1/tool');
  assert.equal(received[0].body.tool, 'phone_screen');
  assert.deepEqual(received[0].body.caller, { sessionId: 'sess-42', turnId: 'turn-7' });

  // Simulate turn/end event -> forwarded to Kotlin SafetyGate daemon
  sessionEventListener({ id: 'sess-42' }, { type: 'turn/end', data: { reason: 'completed' } });
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(received[1].path, '/v1/turn-end');
  assert.equal(received[1].body.sessionId, 'sess-42');
});

test('chat domain sanitizes corrupt titles and system domain localizes web providers', async (t) => {
  const handlers = new Map([
    [
      'session/list',
      async () => [
        { id: 's-obj', title: '[object Object], 调试网络超时', cwd: '/Users/cake/playground' },
        {
          id: 's-prompt',
          title: 'We need answer a title for the user prompt: "优化暗黑模式表格"',
          cwd: '/Users/cake/playground',
        },
        { id: 's-only-obj', title: { text: '' }, cwd: '/Users/cake/toys/grassbag' },
      ],
    ],
    [
      'web/listProviders',
      async () => ({
        search: [
          { id: 'deepseek-official', name: 'deepseek-official' },
          { id: 'commandcode', name: 'commandcode' },
        ],
        fetch: [{ id: 'http', name: 'http' }],
      }),
    ],
    [
      'settings/describe',
      async () => ({
        writable: true,
        namespaces: [{ name: 'web', title: 'Web' }],
      }),
    ],
  ]);

  const gw = {
    claimsEndpoint: (ep) => handlers.has(ep),
    collectSrcClaims: () => [...handlers.keys()],
    operatorPeer: () => ({ id: 'op' }),
    async dispatchRpc(endpoint, payload) {
      const fn = handlers.get(endpoint);
      if (!fn) return { ok: false, error: { message: `missing ${endpoint}` } };
      return { ok: true, value: await fn(payload.args || {}) };
    },
  };
  const ctx = {
    get: (k) =>
      ({
        typertGateway: gw,
        typert: { local: { list: () => [] } },
        connection: { admit: () => ({ peer: { id: 'op' } }) },
        webServer: { host: '127.0.0.1', port: 3080 },
      })[k],
    logger: { warn: () => {} },
  };
  const core = createGbridgeCore(ctx, { bootId: 'boot-polish-test' });
  const server = createServer((req, res) => core.handleHttp(req, res, { mode: 'webServer' }));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  t.after(() => {
    core.dispose();
    server.closeAllConnections?.();
    server.close();
  });

  const sessionsRes = await jsonReq(port, '/sessions');
  assert.equal(sessionsRes.status, 200);
  const byId = Object.fromEntries(sessionsRes.json.sessions.map((s) => [s.id, s]));
  assert.equal(byId['s-obj'].title, '调试网络超时');
  assert.equal(byId['s-prompt'].title, '优化暗黑模式表格');
  assert.equal(byId['s-only-obj'].title, 'grassbag');

  const manifestRes = await jsonReq(port, '/settings/manifest');
  assert.equal(manifestRes.status, 200);
  const webSection = (manifestRes.json.sections || []).find((s) => s.id === 'web-search');
  assert.ok(webSection, 'web-search manifest section present');
  const searchOpts = manifestRes.json.dynamicOptions?.['web.searchProvider'] || [];
  const fetchOpts = manifestRes.json.dynamicOptions?.['web.fetchProvider'] || [];
  const dsOpt = searchOpts.find((o) => o.value === 'deepseek-official');
  const httpOpt = fetchOpts.find((o) => o.value === 'http');
  assert.ok(dsOpt && dsOpt.label.includes('DeepSeek') && dsOpt.description.length > 0);
  assert.ok(httpOpt && httpOpt.label.includes('HTTP') && httpOpt.description.length > 0);
});

test('SessionNormalizer restores last narration if a completed turn ends with a tool call and empty trailing text', () => {
  const normalizer = new SessionNormalizer();
  const turns = normalizer.normalizeEvents('s-tool-only', [
    { type: 'turn/start', seq: 1, data: { turnId: 't-1' } },
    { type: 'user/message', seq: 2, data: { message: { text: '帮我提交代码', source: { kind: 'user' } } } },
    { type: 'assistant/message', seq: 3, data: { message: { content: [{ type: 'text', text: '好的，我现在执行 git commit。' }] } } },
    { type: 'tool/call', seq: 4, data: { callId: 'c1', name: 'bash', arguments: { command: 'git commit -m ok' } } },
    { type: 'tool/result', seq: 5, data: { callId: 'c1', name: 'bash', output: '[main 1234] ok' } },
    { type: 'turn/end', seq: 6, data: { turnId: 't-1', reason: 'completed' } },
  ]);
  assert.equal(turns.length, 1);
  assert.equal(turns[0].assistantText, '好的，我现在执行 git commit。');
  assert.equal(turns[0].steps.length, 1);
  assert.equal(turns[0].steps[0].kind, 'tool');
});

test('SessionNormalizer incremental mode keeps live user/message and assistant/message streaming under activeTurnId', () => {
  const normalizer = new SessionNormalizer();
  const uTurns = normalizer.normalizeEvents(
    's-inc',
    [{ type: 'user/message', seq: 12, data: { message: { text: '你好', source: { kind: 'user' } } } }],
    { incremental: true, activeTurnId: 'turn-1' },
  );
  assert.equal(uTurns.length, 1);
  assert.equal(uTurns[0].turnId, 'turn-1');
  assert.equal(uTurns[0].status, 'streaming');

  const aTurns = normalizer.normalizeEvents(
    's-inc',
    [{ type: 'assistant/message', seq: 15, data: { message: { content: [{ type: 'text', text: '你好！' }] } } }],
    { incremental: true, activeTurnId: 'turn-1' },
  );
  assert.equal(aTurns.length, 1);
  assert.equal(aTurns[0].turnId, 'turn-1');
  assert.equal(aTurns[0].status, 'streaming');
});

test('DSH 0.2.2-rc.5 strict Zod adapters: schedules, goals, diffs, archive-delete, permission, preset, export, search', async (t) => {
  const calls = [];
  const supported = new Set([
    'forgePanel/localDiff',
    'schedule/create',
    'schedule/edit',
    'schedule/history',
    'schedule/run',
    'goals/create',
    'goals/get',
    'goals/pause',
    'goals/clear',
    'workspace/archiveSession',
    'commands/execute',
    'session/list',
    'session/page',
    'settings/update',
    'agentPresets/select',
  ]);
  const fakeGateway = {
    claimsEndpoint: (ep) => supported.has(ep),
    collectSrcClaims: () => [...supported],
    operatorPeer: () => ({ id: 'op' }),
    async dispatchRpc(ep, payload) {
      const args = payload.args;
      calls.push({ ep, args });
      if (ep === 'forgePanel/localDiff') {
        assert.equal(args.scope?.kind, 'uncommitted');
        return {
          ok: true,
          value: {
            base: null,
            files: [{
              path: 'lib/app.dart',
              previousPath: null,
              status: 'modified',
              binary: false,
              oversized: false,
              untracked: false,
              additions: 1,
              deletions: 1,
              hunks: [{ oldStart: 10, oldLines: 1, newStart: 10, newLines: 1, lines: ['-old', '+new'] }],
            }],
          },
        };
      }
      if (ep === 'goals/get') return { ok: true, value: { id: 'g-1', revision: 3, objective: 'Ship clean build', phase: 'active' } };
      if (ep === 'session/list') return { ok: true, value: [{ sessionId: 's-1', title: 'GrassBag Audit', cwd: '/tmp/gb' }] };
      if (ep === 'session/page') {
        return {
          ok: true,
          value: {
            records: [
              { type: 'turn/start', seq: 1, data: { turnId: 't-1' } },
              { type: 'user/message', seq: 2, data: { message: { text: 'Hello' } } },
              { type: 'assistant/message', seq: 3, data: { message: { content: [{ type: 'text', text: 'World' }] } } },
              { type: 'turn/end', seq: 4, data: { turnId: 't-1', reason: 'completed' } },
            ],
          },
        };
      }
      if (ep === 'commands/execute') return { ok: true, value: { kind: 'success', text: 'preset workspace-write' } };
      return { ok: true, value: { ok: true } };
    },
  };
  const fakeCtx = {
    get: (k) => ({
      typertGateway: fakeGateway,
      typert: { local: { list: () => [] } },
      connection: { admit: () => ({ peer: { id: 'op' } }) },
      webServer: { host: '127.0.0.1', port: 3080 },
    })[k],
    logger: { warn: () => {} },
    on: () => () => {},
  };
  const core = createGbridgeCore(fakeCtx, { bootId: 'boot-strict-1' });
  const server = createServer((req, res) => { core.handleHttp(req, res, { mode: 'webServer' }); });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  t.after(() => { core.dispose(); server.closeAllConnections?.(); server.close(); });

  // 1. Diffs use uncommitted scope & render hunks into unified diff patch
  const diffRes = await jsonReq(port, '/workspaces/w1/files/changes?sessionId=s-1');
  assert.equal(diffRes.status, 200);
  assert.equal(diffRes.json.changes.files.length, 1);
  assert.ok(diffRes.json.changes.files[0].patch.includes('@@ -10,1 +10,1 @@'));
  assert.ok(diffRes.json.changes.files[0].patch.includes('+new'));

  // 2. Schedule create / patch / history / delete send exact { request: ... } envelopes
  const scCreate = await jsonReq(port, '/schedules', {
    method: 'POST',
    body: { name: 'Daily Check', cronExpr: '0 9 * * *', prompt: 'Check status' },
  });
  assert.equal(scCreate.status, 201);
  const scCall = calls.find((c) => c.ep === 'schedule/create');
  assert.equal(scCall.args.request.title, 'Daily Check');
  assert.equal(scCall.args.request.timing.kind, 'cron');
  assert.equal(scCall.args.request.timing.cron.expression, '0 9 * * *');

  const scPatch = await jsonReq(port, '/schedules/sc-9', { method: 'PATCH', body: { enabled: false } });
  assert.equal(scPatch.status, 200);
  const patchCall = calls.find((c) => c.ep === 'schedule/edit' && c.args.request.action === 'update');
  assert.equal(patchCall.args.request.patch.active, false);

  const scHist = await jsonReq(port, '/schedules/sc-9/history');
  assert.equal(scHist.status, 200);
  const histCall = calls.find((c) => c.ep === 'schedule/history');
  assert.equal(histCall.args.request.id, 'sc-9');
  assert.equal(histCall.args.request.limit, 20);

  const scDel = await jsonReq(port, '/schedules/sc-9', { method: 'DELETE' });
  assert.equal(scDel.status, 200);
  const delCall = calls.find((c) => c.ep === 'schedule/edit' && c.args.request.action === 'delete');
  assert.equal(delCall.args.request.id, 'sc-9');

  // 3. Goals create + pause auto-resolves ref { id, revision }
  const gCreate = await jsonReq(port, '/sessions/s-1/goals', {
    method: 'POST',
    body: { action: 'create', title: 'Fix all bugs', criteria: 'Zero errors' },
  });
  assert.equal(gCreate.status, 200);
  const gcCall = calls.find((c) => c.ep === 'goals/create');
  assert.equal(gcCall.args.agentId, 's-1');
  assert.ok(gcCall.args.request.objective.includes('Fix all bugs'));

  const gPause = await jsonReq(port, '/sessions/s-1/goals', { method: 'POST', body: { action: 'pause' } });
  assert.equal(gPause.status, 200);
  const gpCall = calls.find((c) => c.ep === 'goals/pause');
  assert.deepEqual(gpCall.args.ref, { id: 'g-1', revision: 3 });

  // 4. DELETE /sessions/:id falls back to workspace/archiveSession
  const sDel = await jsonReq(port, '/sessions/s-1', { method: 'DELETE' });
  assert.equal(sDel.status, 200);
  assert.equal(sDel.json.archived, true);

  // 5. PUT /sessions/:id/permission dispatches /permission <preset>
  const permRes = await jsonReq(port, '/sessions/s-1/permission', { method: 'PUT', body: { preset: 'workspace-write' } });
  assert.equal(permRes.status, 200);
  const cmdCall = calls.find((c) => c.ep === 'commands/execute');
  assert.equal(cmdCall.args.line, '/permission workspace-write');

  // 6. Preset select without sessionId updates default setting
  const preRes = await jsonReq(port, '/presets/select', { method: 'POST', body: { preset: 'coder' } });
  assert.equal(preRes.status, 200);
  assert.equal(preRes.json.scope, 'default');

  // 7. Search fallback & Export Markdown fallback & Speech config 200
  const searchRes = await jsonReq(port, '/sessions/search?q=grassbag');
  assert.equal(searchRes.status, 200);
  assert.equal(searchRes.json.results.length, 1);

  const expRes = await jsonReq(port, '/sessions/s-1/export');
  assert.equal(expRes.status, 200);
  assert.equal(expRes.json.format, 'markdown');
  assert.ok(expRes.json.markdown.includes('Hello'));

  const spCfg = await jsonReq(port, '/speech/config');
  assert.equal(spCfg.status, 200);
  assert.equal(spCfg.json.configured, false);
});

test('Security & robustness: workspace root confinement, >64 credentials batching, POST /connect auth, phone_* approval guard', async (t) => {
  const dshHome = mkdtempSync(join(tmpdir(), 'gbridge-sec-lan-'));
  const prevDshHome = process.env.DSH_HOME;
  process.env.DSH_HOME = dshHome;
  const describeCalls = [];
  const fakeGateway = {
    claimsEndpoint: (ep) => ep === 'credentials/describe' || ep === 'workspace/list',
    collectSrcClaims: () => ['credentials/describe', 'workspace/list'],
    operatorPeer: () => ({ id: 'op' }),
    async dispatchRpc(ep, payload) {
      if (ep === 'workspace/list') {
        return { ok: true, value: [{ id: 'w-home', path: process.env.HOME || tmpdir() }] };
      }
      if (ep === 'credentials/describe') {
        const refs = payload?.args?.refs ?? [];
        describeCalls.push(refs.length);
        const out = {};
        for (const r of refs) {
          out[r] = { configured: true, masked: 'sk-***' };
        }
        return { ok: true, value: out };
      }
      return { ok: true, value: {} };
    },
  };
  const fakeCtx = {
    get: (k) => ({
      typertGateway: fakeGateway,
      typert: { local: { list: () => [] } },
      connection: { admit: () => ({ peer: { id: 'op' } }) },
      webServer: { host: '127.0.0.1', port: 3080 },
    })[k],
    logger: { warn: () => {} },
    on: () => () => {},
  };
  const core = createGbridgeCore(fakeCtx, { bootId: 'boot-sec-1' });
  const listener = startLanBridgeListener(core, {
    host: '127.0.0.1',
    port: 0,
    surface: 'desktop',
    logger: { info() {}, warn() {} },
  });
  t.after(() => {
    listener.dispose();
    core.dispose();
    if (prevDshHome === undefined) delete process.env.DSH_HOME;
    else process.env.DSH_HOME = prevDshHome;
    rmSync(dshHome, { recursive: true, force: true });
  });
  let port = 0;
  for (let i = 0; i < 40; i++) {
    const addr = listener.address?.();
    if (addr && addr.port) {
      port = addr.port;
      break;
    }
    await new Promise((r) => setTimeout(r, 15));
  }
  assert.ok(port > 0, 'LAN listener failed to bind ephemeral port');

  // 1. POST /connect sets HttpOnly cookie on valid token and rejects invalid token inline
  const badLogin = await new Promise((resolve, reject) => {
    const body = 'token=wrong-token';
    const req = httpRequest({
      host: '127.0.0.1',
      port,
      path: '/connect',
      method: 'POST',
      headers: {
        'content-type': 'application/x-www-form-urlencoded',
        'content-length': Buffer.byteLength(body),
      },
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    req.end(body);
  });
  assert.equal(badLogin.status, 401);
  assert.ok(badLogin.body.includes('Token'));

  const goodLogin = await new Promise((resolve, reject) => {
    const body = `token=${encodeURIComponent(listener.token)}`;
    const req = httpRequest({
      host: '127.0.0.1',
      port,
      path: '/connect',
      method: 'POST',
      headers: {
        'content-type': 'application/x-www-form-urlencoded',
        'content-length': Buffer.byteLength(body),
      },
    }, (res) => {
      res.resume();
      res.on('end', () => resolve({ status: res.statusCode, setCookie: res.headers['set-cookie'] || [] }));
    });
    req.on('error', reject);
    req.end(body);
  });
  assert.equal(goodLogin.status, 303);
  const authCookie = String(goodLogin.setCookie[0] || '').split(';')[0];
  assert.match(authCookie, /^gbridge-lan-auth-\d+=/);

  // 2. Workspace root confinement blocks `%2F` filesystem root escape
  const escapeTree = await jsonReq(port, '/workspaces/%2F/files/tree', { cookie: authCookie });
  assert.equal(escapeTree.status, 403);
  const escapeRead = await jsonReq(port, '/workspaces/%2F/files/read?path=etc/passwd', { cookie: authCookie });
  assert.equal(escapeRead.status, 403);

  // 3. POST /web-ticket is disabled in LAN mode (501)
  const lanTicket = await jsonReq(port, '/web-ticket', { method: 'POST', cookie: authCookie });
  assert.equal(lanTicket.status, 501);

  // 4. GET /credentials with >64 refs batches in chunks of 64 and merges into top-level map
  const refs = Array.from({ length: 70 }, (_, i) => `ENV_KEY_${i}`);
  const credRes = await jsonReq(
    port,
    `/credentials?refs=${encodeURIComponent(refs.join(','))}`,
    { cookie: authCookie },
  );
  assert.equal(credRes.status, 200);
  assert.equal(describeCalls.length, 2);
  assert.equal(describeCalls[0], 64);
  assert.ok(describeCalls[1] >= 6 && describeCalls[1] <= 64);
  assert.equal(credRes.json.credentials.ENV_KEY_0.configured, true);
  assert.equal(credRes.json.credentials.ENV_KEY_69.configured, true);

  // 5. StreamHub never auto-approves `phone_*` even when user clicks "always" (`本次均允许`)
  core.hub._eventsClientId = 'cli-1';
  core.hub.gateway.respondRemoteEvent = async () => {};
  core.hub._handleHostEventFrame({
    type: 'waterfall',
    event: 'approval/request',
    eventId: 'ev-phone-1',
    agentId: 'sess-phone-1',
    request: { toolName: 'phone_tap', sessionId: 'sess-phone-1' },
  });
  assert.equal(core.hub.pendingInteractions.has('ev-phone-1'), true);
  await core.hub.respondInteraction('ev-phone-1', { decision: 'always' });
  assert.equal(core.hub.sessionAlwaysAllowed.has('sess-phone-1'), false);
  // Second phone_tap MUST still require manual approval (never auto-approved!)
  core.hub._handleHostEventFrame({
    type: 'waterfall',
    event: 'approval/request',
    eventId: 'ev-phone-2',
    agentId: 'sess-phone-1',
    request: { toolName: 'phone_tap', sessionId: 'sess-phone-1' },
  });
  assert.equal(core.hub.pendingInteractions.has('ev-phone-2'), true);
});
