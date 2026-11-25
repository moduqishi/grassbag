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
  assert.equal(phone.registered, 13);
  assert.ok(registeredTools.has('phone_screen'));
  assert.ok(registeredTools.has('phone_apps'));
  assert.ok(registeredTools.has('phone_screenshot'));
  assert.ok(registeredTools.has('phone_return_app'));
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

  // Duplicate StreamHub notifyTurnEnd for the same session is cleanly deduplicated
  assert.equal(phone.notifyTurnEnd('sess-42', 'completed'), false);

  // Fresh phone session ended via StreamHub fallback (without ctx.on session/event) still forwards /v1/turn-end!
  await registeredTools.get('phone_return_app').execute(
    { summary: '已完成计算器演示' },
    { agent: { session: { id: 'sess-99' } }, turnId: 'turn-9' },
  );
  assert.equal(phone.notifyTurnEnd('sess-99', 'completed', '已完成计算器演示'), true);
  await new Promise((r) => setTimeout(r, 60));
  const lastTurnEnd = received.filter((r) => r.path === '/v1/turn-end').at(-1);
  assert.equal(lastTurnEnd.body.sessionId, 'sess-99');
  assert.equal(lastTurnEnd.body.summary, '已完成计算器演示');
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

test('PATCH /settings auto-recovers stale expectedRevision on settings/mutate & settings/update while preserving 409 on replace', async (t) => {
  const calls = [];
  let rev = 3;
  const supported = new Set(['settings/mutate', 'settings/update', 'settings/replace']);
  const gw = {
    claimsEndpoint: (ep) => supported.has(ep),
    collectSrcClaims: () => [...supported],
    operatorPeer: () => ({ id: 'op' }),
    async dispatchRpc(endpoint, payload) {
      const args = payload.args || {};
      calls.push({ endpoint, args });
      if (args.expectedRevision !== undefined && args.expectedRevision !== rev) {
        return {
          ok: false,
          error: {
            code: 'settings/conflict',
            message: `settings namespace "${args.ns}" changed since it was read (expected revision ${args.expectedRevision}, now ${rev})`,
            details: { ns: args.ns, expected: args.expectedRevision, actual: rev },
          },
        };
      }
      rev += 1;
      return { ok: true, value: { ns: args.ns, revision: rev, value: { model: 'deepseek-reasoner' } } };
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
  const core = createGbridgeCore(ctx, { bootId: 'boot-settings-conflict' });
  const server = createServer((req, res) => core.handleHttp(req, res, { mode: 'webServer' }));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  t.after(() => { core.dispose(); server.closeAllConnections?.(); server.close(); });

  // 1. Stale expectedRevision on settings/mutate -> automatically retries without expectedRevision -> 200 OK
  const mutateRes = await jsonReq(port, '/settings', {
    method: 'PATCH',
    body: {
      ns: 'agent-default-model',
      ops: [{ op: 'set', path: ['reasoningEffort'], value: 'high' }],
      expectedRevision: 2,
    },
  });
  assert.equal(mutateRes.status, 200);
  assert.equal(mutateRes.json.conflictRecovered, true);
  assert.equal(mutateRes.json.result.revision, 4);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].args.expectedRevision, 2);
  assert.equal(calls[1].args.expectedRevision, undefined);

  // 2. Stale expectedRevision on settings/replace -> preserves 409 conflict semantics
  const replaceRes = await jsonReq(port, '/settings', {
    method: 'PATCH',
    body: {
      ns: 'llm-pi-ai',
      section: { providers: {} },
      expectedRevision: 1,
    },
  });
  assert.equal(replaceRes.status, 409);
  assert.equal(replaceRes.json.error.details.upstreamCode, 'settings/conflict');
});

test('SessionNormalizer humanizes phone_* tool titles & summaries instead of raw JSON', () => {
  const norm = new SessionNormalizer();
  const turns = norm.normalizeEvents('s-phone-human', [
    { seq: 1, type: 'turn/start', turnId: 't1', data: { turnId: 't1' } },
    { seq: 2, type: 'message', turnId: 't1', data: { role: 'user', content: '打开时钟并截屏' } },
    {
      seq: 3,
      type: 'tool/call',
      turnId: 't1',
      data: { callId: 'c1', name: 'phone_open', arguments: { appName: '时钟' } },
    },
    {
      seq: 4,
      type: 'tool/result',
      turnId: 't1',
      data: { callId: 'c1', name: 'phone_open', output: '{"ok":true,"package":"com.android.deskclock","opened":"时钟"}' },
    },
    {
      seq: 5,
      type: 'tool/call',
      turnId: 't1',
      data: { callId: 'c2', name: 'phone_screenshot', arguments: {} },
    },
    {
      seq: 6,
      type: 'tool/result',
      turnId: 't1',
      data: { callId: 'c2', name: 'phone_screenshot', output: '{"ok":true,"width":1080,"height":2400}' },
    },
    {
      seq: 7,
      type: 'tool/call',
      turnId: 't1',
      data: { callId: 'c3', name: 'phone_return_app', arguments: { summary: '已完成查看' } },
    },
    {
      seq: 8,
      type: 'tool/result',
      turnId: 't1',
      data: { callId: 'c3', name: 'phone_return_app', output: '{"ok":true}' },
    },
    { seq: 9, type: 'turn/end', turnId: 't1', data: { turnId: 't1', reason: { kind: 'completed' } } },
  ]);
  assert.equal(turns.length, 1);
  const [s1, s2, s3] = turns[0].steps;
  assert.equal(s1.title, 'phone_open · 时钟');
  assert.equal(s1.summary, '已打开 时钟');
  assert.ok(!s1.summary.startsWith('{'));
  assert.equal(s2.title, 'phone_screenshot · 截取当前屏幕');
  assert.equal(s2.summary, '1080×2400');
  assert.equal(s3.title, 'phone_return_app · 已完成查看');
  assert.equal(s3.summary, '已返回应用');
});

test('v28 regression: normalizer keeps cached tool output, workspace honors explicit idParam, StreamHub cancels user_questions with next', async () => {
  const norm = new SessionNormalizer();
  norm.normalizeEvents('s-cache', [
    { seq: 1, type: 'turn/start', turnId: 't1', data: { turnId: 't1' } },
    { seq: 2, type: 'tool/call', turnId: 't1', data: { callId: 'c1', name: 'bash', arguments: { command: 'ls' } } },
    { seq: 3, type: 'tool/result', turnId: 't1', data: { callId: 'c1', name: 'bash', output: 'README.md\npackage.json' } },
    // Duplicate/replayed tool/call must NOT clobber already-cached tool output with null!
    { seq: 4, type: 'tool/call', turnId: 't1', data: { callId: 'c1', name: 'bash', arguments: { command: 'ls' } } },
  ]);
  const cached = norm.getToolOutput('s-cache', 'c1');
  assert.equal(cached?.output, 'README.md\npackage.json');
  assert.equal(cached?.status, 'ok');

  // StreamHub: user_questions cancel decision maps to `{ kind: 'next' }`
  const { StreamHub } = await import('../lib/stream-hub.js');
  const settled = [];
  const hub = new StreamHub({
    bootId: 'boot-v28',
    logger: { info() {}, warn() {}, debug() {} },
    normalizer: norm,
    gateway: {
      respondRemoteEvent: async (clientId, eventId, outcome) => {
        settled.push({ clientId, eventId, outcome });
      },
    },
  });
  hub.pendingInteractions.set('iq-1', {
    id: 'iq-1',
    kind: 'user_questions',
    event: 'ui/ask-user-questions',
    eventId: 'ev-1',
    gatewayClientId: 'gc-1',
    sessionId: 's-q',
    payload: {},
  });
  const res = await hub.respondInteraction('iq-1', { decision: 'cancel' });
  assert.equal(res.settled, true);
  assert.deepEqual(settled[0]?.outcome, { kind: 'next' });
  hub.dispose();
});

test('v32 send & reply generation: CJK liveTps, tool-phase suppression, durationMs fallback, interrupt->steer & tornDownChannels', async (t) => {
  const norm = new SessionNormalizer();
  const baseTs = 1700000000000;

  // 1. Tool duration fallback (`ev.time`) & turn/end durationMs preservation
  const turns = norm.normalizeEvents('s-v32', [
    { seq: 1, id: 'ev-turn-1', type: 'turn/start', time: baseTs, data: {} },
    { seq: 2, type: 'user/message', turnId: 'ev-turn-1', time: baseTs + 5, data: { text: '检查状态' } },
    { seq: 3, type: 'tool/call', turnId: 'ev-turn-1', time: baseTs + 100, data: { callId: 'c1', name: 'bash', arguments: { command: 'ls' } } },
    { seq: 4, type: 'tool/result', turnId: 'ev-turn-1', time: baseTs + 650, data: { callId: 'c1', name: 'bash', output: 'ok' } },
    { seq: 5, type: 'assistant/message', turnId: 'ev-turn-1', time: baseTs + 900, data: { text: '检查完成', usage: { inputTokens: 100, outputTokens: 20, durationMs: 800 } } },
    { seq: 6, type: 'turn/end', turnId: 'ev-turn-1', time: baseTs + 920, data: { usage: { inputTokens: 100, outputTokens: 20 } } },
  ]);
  assert.equal(turns.length, 1);
  assert.equal(turns[0].turnId, 'ev-turn-1');
  const toolStep = turns[0].steps.find((s) => s.kind === 'tool');
  assert.equal(toolStep?.durationMs, 550);
  assert.equal(turns[0].usage?.durationMs, 800);

  // 2. DSH 0.2.2-rc.5 content envelope sends `mode: 'interrupt'` with `session/cancel` + `mode: 'steer'`
  const dispatched = [];
  const dshSupported = new Set(['session/list', 'session/listEvents', 'session/cancel', 'session/prompt']);
  const gw = {
    claimsEndpoint: (ep) => dshSupported.has(ep),
    collectSrcClaims: () => [...dshSupported],
    operatorPeer: () => ({ id: 'op' }),
    async dispatchRpc(endpoint, payload) {
      dispatched.push({ endpoint, args: payload.args });
      return { ok: true, value: { ok: true } };
    },
  };
  const core = createGbridgeCore({
    get: (k) => ({
      typertGateway: gw,
      typert: {
        local: {
          list: () => [],
          get: (ep) => (ep === 'session/prompt'
            ? { parameters: [{ wire: 'request', codec: { jsonSchema: { properties: { requestId: {}, content: {} } } } }] }
            : null),
        },
      },
      connection: { admit: () => ({ peer: { id: 'op' } }) },
      webServer: { host: '127.0.0.1', port: 3080 },
    })[k],
    logger: { warn: () => {} },
  }, { bootId: 'boot-v32-chat' });
  const srv = createServer((req, res) => core.handleHttp(req, res, { mode: 'webServer' }));
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  t.after(() => { core.dispose(); srv.closeAllConnections?.(); srv.close(); });
  const sendRes = await jsonReq(srv.address().port, '/sessions/s-v32/messages', {
    method: 'POST',
    body: { text: '立刻改做 B', mode: 'interrupt', clientRequestId: 'req-v32' },
  });
  assert.equal(sendRes.status, 200);
  assert.equal(dispatched[0]?.endpoint, 'session/cancel');
  assert.equal(dispatched[1]?.endpoint, 'session/prompt');
  assert.equal(dispatched[1]?.args?.request?.mode, 'steer');

  // 3. CJK-aware rolling liveTps + tool-phase suppression + step/start reset
  norm.observeStreamChunk('s-tps', { type: 'turn/start' });
  norm.observeStreamChunk('s-tps', { type: 'text-delta', delta: '这是一段用于测试中文流式吞吐量估算的示例输出文本。' });
  await new Promise((r) => setTimeout(r, 240));
  const snapChinese = norm.observeStreamChunk('s-tps', { type: 'text-delta', delta: '继续输出第二段流畅的中文内容以确保速度准确。' });
  assert.equal(snapChinese.phase, 'streaming');
  assert.ok(snapChinese.tps != null && snapChinese.tps > 20, `expected CJK tps > 20, got ${snapChinese.tps}`);

  const snapTool = norm.observeStreamChunk('s-tps', { type: 'tool-call-delta', name: 'bash' });
  assert.equal(snapTool.phase, 'tool');
  assert.equal(snapTool.tps, undefined);

  norm.observeStreamChunk('s-tps', { type: 'step/start' });
  const snapPostTool = norm.observeStreamChunk('s-tps', { type: 'text-delta', delta: '工具执行完毕后重新开始输出。' });
  assert.equal(snapPostTool.phase, 'streaming');
  assert.equal(snapPostTool.tps, undefined);

  // 4. StreamHub tornDownChannels forces `resumed: false` on reconnect hello
  const { StreamHub } = await import('../lib/stream-hub.js');
  const hub = new StreamHub({
    bootId: 'boot-v32',
    logger: { info() {}, warn() {}, debug() {} },
    normalizer: norm,
    gateway: { has: () => false },
  });
  hub.seq = 10;
  hub.tornDownChannels.add('session:s-v32');
  const sentFrames = [];
  const fakeWs = {
    on() {},
    sendJson(obj) { sentFrames.push(obj); },
    sendText(raw) { sentFrames.push(JSON.parse(raw)); },
    close() {},
  };
  const connId = hub.attachClient(fakeWs);
  hub._onClientMessage(hub.clients.get(connId), {
    op: 'hello',
    channels: ['session:s-v32'],
    resumeFromSeq: 5,
  });
  const welcome = sentFrames.find((f) => f.op === 'welcome');
  assert.equal(welcome?.resumed, false);
  hub.dispose();
});

test('v33 regression: StreamHub handles turn_end, bounds tornDownChannels & clears on dispose, and /sessions/search fallback reads projections.values', async (t) => {
  const norm = new SessionNormalizer();
  const { StreamHub } = await import('../lib/stream-hub.js');
  const hub = new StreamHub({
    bootId: 'boot-v33',
    logger: { info() {}, warn() {}, debug() {} },
    normalizer: norm,
    gateway: { has: () => false },
  });

  // 1. tornDownChannels bounded to 512 FIFO entries & cleared on dispose()
  for (let i = 0; i < 600; i++) {
    const ch = `job:j-${i}`;
    hub.upstreamStreams.set(ch, {
      subscribers: new Set(['c1']),
      abort: new AbortController(),
      teardownTimer: null,
    });
    hub._releaseUpstreamStream(ch, 'c1');
  }
  assert.equal(hub.tornDownChannels.size, 512);
  assert.equal(hub.tornDownChannels.has('job:j-0'), false);
  assert.equal(hub.tornDownChannels.has('job:j-599'), true);

  // 2. turn_end variant emits turn.completed alongside turn/end
  const published = [];
  hub.publish = (channel, type, data) => {
    published.push({ channel, type, data });
    return { seq: published.length };
  };
  hub._forwardUpstreamStreamItem('session', 's-v33-end', 'session:s-v33-end', {
    type: 'event',
    event: { seq: 12, type: 'turn_end', turnId: 't-v33', data: { reason: { kind: 'completed' } } },
  });
  assert.ok(
    published.some((e) => e.channel === 'session:s-v33-end' && e.type === 'turn.completed'),
    'expected turn_end event to emit turn.completed',
  );
  hub.dispose();
  assert.equal(hub.tornDownChannels.size, 0);

  // 3. /sessions/search fallback reads nested projections.values.title & workingDirectory
  const dshSupported = new Set(['session/list']);
  const gw = {
    claimsEndpoint: (ep) => dshSupported.has(ep),
    collectSrcClaims: () => [...dshSupported],
    operatorPeer: () => ({ id: 'op' }),
    async dispatchRpc(endpoint) {
      if (endpoint === 'session/list') {
        return {
          ok: true,
          value: {
            items: [
              {
                id: 's-proj-1',
                workingDirectory: '/Users/dev/grassbag-mobile',
                projections: { values: { title: '部署安卓内核修复' } },
              },
            ],
          },
        };
      }
      return { ok: false, error: 'unsupported' };
    },
  };
  const core = createGbridgeCore({
    get: (k) => ({
      typertGateway: gw,
      typert: { local: { list: () => [], get: () => null } },
      connection: { admit: () => ({ peer: { id: 'op' } }) },
      webServer: { host: '127.0.0.1', port: 3080 },
    })[k],
    logger: { warn: () => {} },
  }, { bootId: 'boot-v33-search' });
  const srv = createServer((req, res) => core.handleHttp(req, res, { mode: 'webServer' }));
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  t.after(() => { core.dispose(); srv.closeAllConnections?.(); srv.close(); });

  const byTitle = await jsonReq(srv.address().port, '/sessions/search?q=' + encodeURIComponent('安卓内核'));
  assert.equal(byTitle.status, 200);
  assert.equal(byTitle.json.results.length, 1);
  assert.equal(byTitle.json.results[0].sessionId, 's-proj-1');
  assert.equal(byTitle.json.results[0].title, '部署安卓内核修复');

  const byCwd = await jsonReq(srv.address().port, '/sessions/search?q=grassbag-mobile');
  assert.equal(byCwd.status, 200);
  assert.equal(byCwd.json.results.length, 1);
});

test('v34 regression: slim session.event raw, durableRing byte cap & snapshot exclusion, oversized object tool cache truncation', async () => {
  const norm = new SessionNormalizer();
  const { StreamHub } = await import('../lib/stream-hub.js');
  const hub = new StreamHub({
    bootId: 'boot-v34',
    logger: { info() {}, warn() {}, debug() {} },
    normalizer: norm,
    gateway: { has: () => false },
    durableReplayMaxBytes: 1024,
  });

  // 1. durableRing skips giant snapshots and enforces byte cap via head-pointer compaction
  hub.publish('session:s-v34', 'turn.snapshot', { huge: 'X'.repeat(5000) });
  assert.equal(hub.durableRing.length - hub.durableRingHead, 0);
  for (let i = 0; i < 12; i++) {
    hub.publish('session:s-v34', 'turn.completed', { turnId: `t-${i}`, pad: 'A'.repeat(160) });
  }
  assert.ok(hub.durableRingBytes <= 1024, `expected durableRingBytes <= 1024, got ${hub.durableRingBytes}`);
  assert.ok(hub.durableRing.length - hub.durableRingHead >= 1);

  // 2. session.event strips redundant full raw when normalizedTurn is present, but preserves raw for todo/write
  const published = [];
  hub.publish = (channel, type, data) => {
    published.push({ channel, type, data });
    return { seq: published.length };
  };
  hub._forwardUpstreamStreamItem('session', 's-v34-slim', 'session:s-v34-slim', {
    type: 'event',
    event: {
      seq: 1,
      type: 'assistant/message',
      turnId: 'tv34-1',
      data: { text: '完整回复正文 '.repeat(50) },
    },
  });
  hub._forwardUpstreamStreamItem('session', 's-v34-slim', 'session:s-v34-slim', {
    type: 'event',
    event: {
      seq: 2,
      type: 'todo/write',
      turnId: 'tv34-1',
      data: { todos: [{ id: '1', content: 'Verify v34', status: 'in_progress' }] },
    },
  });
  const msgEv = published.find((e) => e.type === 'session.event' && e.data?.raw?.type === 'assistant/message');
  assert.ok(msgEv?.data?.normalizedTurn, 'expected normalizedTurn on assistant/message');
  assert.equal(msgEv?.data?.raw?.data, undefined, 'expected slim raw without duplicated payload data');
  const todoEv = published.find((e) => e.type === 'session.event' && e.data?.raw?.type === 'todo/write');
  assert.ok(Array.isArray(todoEv?.data?.raw?.data?.todos), 'expected full raw preserved for todo/write');
  hub.dispose();

  // 3. SessionNormalizer.cacheToolOutput truncates oversized object outputs accurately (>512 KiB)
  const hugeObj = { items: Array.from({ length: 10000 }, (_, i) => ({ idx: i, body: 'payload-'.repeat(8) })) };
  norm.cacheToolOutput('s-v34-cache', 'call-big', { tool: 'read', status: 'ok', output: hugeObj });
  const cached = norm.getToolOutput('s-v34-cache', 'call-big');
  assert.equal(cached?.truncated, true);
  assert.equal(typeof cached?.output, 'string');
  assert.ok(cached.output.includes('已截断'), 'expected truncated marker on oversized object output');
});
