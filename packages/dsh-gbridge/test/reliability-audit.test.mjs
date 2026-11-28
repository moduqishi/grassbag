import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { createServer } from 'node:http';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { StreamHub } from '../lib/stream-hub.js';
import { mountPhoneTools } from '../lib/phone-tools.js';
import { applyLoopbackCors, isAllowedCorsOrigin, Router } from '../lib/http-util.js';
import { registerChatAndInteractionsDomain } from '../lib/domains/chat.js';

function createFakeWs() {
  const emitter = new EventEmitter();
  const sent = [];
  emitter.closed = false;
  emitter.socket = { writableLength: 0 };
  emitter.sendJson = (obj) => {
    sent.push(obj);
  };
  emitter.sendText = (raw) => {
    sent.push(JSON.parse(raw));
  };
  emitter.ping = () => {};
  emitter.close = () => {
    emitter.closed = true;
    emitter.emit('close');
  };
  emitter.terminate = () => {
    emitter.closed = true;
    emitter.emit('close');
  };
  return { ws: emitter, sent };
}

test('P1.2: interleaved deltas across two channels preserve strict seq order and lose zero frames on resume', () => {
  const hub = new StreamHub({ bootId: 'boot-interleave' });
  try {
    const conn1 = createFakeWs();
    hub.attachClient(conn1.ws);
    conn1.ws.emit(
      'message',
      JSON.stringify({
        op: 'hello',
        v: 1,
        clientId: 'c1',
        coalesceMs: 50,
        channels: ['session:s1', 'terminal:t1'],
      }),
      false,
    );
    const welcome1 = conn1.sent.find((f) => f.op === 'welcome');
    assert.ok(welcome1);

    // Interleave f1 (session:s1), f2 (terminal:t1), f3 (session:s1) inside coalesce window
    const f1 = hub.publish('session:s1', 'turn.delta', { sessionId: 's1', chunk: { type: 'text', delta: 'A1' } }, { isDelta: true });
    const f2 = hub.publish('terminal:t1', 'term.data', { terminalId: 't1', chunk: 'B2' }, { isDelta: true });
    const f3 = hub.publish('session:s1', 'turn.delta', { sessionId: 's1', chunk: { type: 'text', delta: 'A3' } }, { isDelta: true });

    // Before timer fires, f1 AND f2 MUST ALREADY be flushed in strictly ascending seq order!
    const wireBeforeDisconnect = conn1.sent.filter((f) => f.op === 'delta');
    assert.equal(wireBeforeDisconnect.length, 2);
    assert.equal(wireBeforeDisconnect[0].seq, f1.seq);
    assert.equal(wireBeforeDisconnect[0].channel, 'session:s1');
    assert.equal(wireBeforeDisconnect[0].data.chunk.delta, 'A1');
    assert.equal(wireBeforeDisconnect[1].seq, f2.seq);
    assert.equal(wireBeforeDisconnect[1].channel, 'terminal:t1');
    assert.equal(wireBeforeDisconnect[1].data.chunk, 'B2');

    // Simulate client disconnecting right after receiving f2 (before f3 flushes)
    conn1.ws.close();

    // Reconnect and resume from f2.seq -> MUST report resumed: true and replay f3 ('A3')!
    const conn2 = createFakeWs();
    hub.attachClient(conn2.ws);
    conn2.ws.emit(
      'message',
      JSON.stringify({
        op: 'hello',
        v: 1,
        clientId: 'c1',
        lastBootId: 'boot-interleave',
        resumeFromSeq: f2.seq,
        coalesceMs: 50,
        channels: ['session:s1', 'terminal:t1'],
      }),
      false,
    );
    const welcome2 = conn2.sent.find((f) => f.op === 'welcome');
    assert.equal(welcome2.resumed, true);
    assert.equal(welcome2.replayedCount, 1);

    const replayed = conn2.sent.filter((f) => f.op === 'delta');
    assert.equal(replayed.length, 1);
    assert.equal(replayed[0].seq, f3.seq);
    assert.equal(replayed[0].data.chunk.delta, 'A3');

    // Combined stream across disconnect + resume contains ALL three payloads (A1, B2, A3) with zero loss!
    const allReceived = [...wireBeforeDisconnect, ...replayed];
    assert.deepEqual(
      allReceived.map((f) => f.seq),
      [f1.seq, f2.seq, f3.seq],
    );
  } finally {
    hub.dispose();
  }
});

test('P2.2: job.event surfaces top-level status and exitCode extracted from nested raw.job', () => {
  const hub = new StreamHub({ bootId: 'boot-job-status' });
  const observed = [];
  hub.setOnJobStateChanged((ev) => observed.push(ev));
  try {
    const conn = createFakeWs();
    hub.attachClient(conn.ws);
    conn.ws.emit(
      'message',
      JSON.stringify({ op: 'hello', v: 1, clientId: 'c-job', coalesceMs: 0, channels: ['job:s1:job-42'] }),
      false,
    );

    hub._forwardUpstreamStreamItem('job', 'job-42', 'job:s1:job-42', {
      type: 'state',
      job: { id: 'job-42', status: 'completed', exitCode: 0 },
    });

    const jobFrame = conn.sent.find((f) => f.type === 'job.event');
    assert.ok(jobFrame);
    assert.equal(jobFrame.data.jobId, 'job-42');
    assert.equal(jobFrame.data.status, 'completed');
    assert.equal(jobFrame.data.exitCode, 0);
    assert.equal(jobFrame.data.raw.job.status, 'completed');
    assert.deepEqual(observed, [{ jobId: 'job-42', status: 'completed' }]);
  } finally {
    hub.dispose();
  }
});

test('P2.1: unified keepalive covers standalone background jobs and fallback turn-end release', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'gbridge-keepalive-test-'));
  const socketPath = join(dir, 'phone.sock');
  const keepaliveCalls = [];

  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
      if (req.url === '/v1/keepalive') {
        keepaliveCalls.push(body);
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    });
  });

  await new Promise((resolve) => server.listen(socketPath, resolve));

  const bus = new EventEmitter();
  const ctx = {
    on(ev, fn) {
      bus.on(ev, fn);
      return () => bus.off(ev, fn);
    },
    get() {
      return null;
    },
  };

  const phone = mountPhoneTools(ctx, { socketPath, token: 'test-tok' });
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  try {
    // 1) Standalone background job starts -> active: true, activeTurns: 0, activeJobs: 1
    phone.notifyJobState('job-bg-1', 'running');
    await wait(40);
    assert.ok(keepaliveCalls.length >= 1);
    assert.equal(keepaliveCalls[keepaliveCalls.length - 1].active, true);
    assert.equal(keepaliveCalls[keepaliveCalls.length - 1].activeTurns, 0);
    assert.equal(keepaliveCalls[keepaliveCalls.length - 1].activeJobs, 1);

    // 2) Standalone background job completes -> active: false, activeTurns: 0, activeJobs: 0
    phone.notifyJobState('job-bg-1', 'completed');
    await wait(40);
    assert.equal(keepaliveCalls[keepaliveCalls.length - 1].active, false);
    assert.equal(keepaliveCalls[keepaliveCalls.length - 1].activeTurns, 0);
    assert.equal(keepaliveCalls[keepaliveCalls.length - 1].activeJobs, 0);

    // 3) Turn starts via session/event, ends ONLY via fallback notifyTurnEnd (no phone tools used)
    bus.emit('session/event', { id: 'sess-fallback' }, { type: 'turn/start', data: { turnId: 't1' } });
    await wait(40);
    assert.equal(keepaliveCalls[keepaliveCalls.length - 1].active, true);
    assert.equal(keepaliveCalls[keepaliveCalls.length - 1].activeTurns, 1);

    phone.notifyTurnEnd('sess-fallback', 'completed');
    await wait(40);
    assert.equal(keepaliveCalls[keepaliveCalls.length - 1].active, false);
    assert.equal(keepaliveCalls[keepaliveCalls.length - 1].activeTurns, 0);
    assert.equal(keepaliveCalls[keepaliveCalls.length - 1].activeJobs, 0);
  } finally {
    phone.dispose();
    await new Promise((resolve) => server.close(resolve));
    rmSync(dir, { recursive: true, force: true });
  }
});

test('P1.4: sessionAlwaysAllowed is committed only AFTER upstream respondRemoteEvent succeeds', async () => {
  let failRespond = true;
  const calls = [];
  const fakeGateway = {
    async respondRemoteEvent(clientId, eventId, outcome) {
      calls.push({ clientId, eventId, outcome });
      if (failRespond) throw new Error('upstream rpc disconnected');
      return { ok: true };
    },
  };
  const hub = new StreamHub({ bootId: 'boot-always-gate', gateway: fakeGateway });
  try {
    hub._eventsClientId = 'cli-1';
    hub._handleHostEventFrame({
      type: 'request',
      eventId: 'evt-1',
      event: 'approval/request',
      agentId: 'sess-a',
      request: { toolName: 'bash', command: 'ls -la' },
    });
    assert.equal(hub.pendingInteractions.size, 1);

    // 1) Upstream failure MUST NOT populate sessionAlwaysAllowed and MUST leave interaction retryable
    await assert.rejects(
      () => hub.respondInteraction('evt-1', { decision: 'always' }),
      /upstream rpc disconnected/,
    );
    assert.equal(hub.sessionAlwaysAllowed.has('sess-a'), false);
    assert.equal(hub.pendingInteractions.has('evt-1'), true);

    // 2) Upstream confirmation commits sessionAlwaysAllowed and auto-approves matching follow-up
    failRespond = false;
    const res = await hub.respondInteraction('evt-1', { decision: 'always' });
    assert.equal(res.id, 'evt-1');
    assert.equal(hub.sessionAlwaysAllowed.get('sess-a')?.has('bash'), true);

    hub._handleHostEventFrame({
      type: 'request',
      eventId: 'evt-2',
      event: 'approval/request',
      agentId: 'sess-a',
      request: { toolName: 'bash', command: 'pwd' },
    });
    assert.equal(hub.pendingInteractions.has('evt-2'), false);
    assert.equal(calls.some((c) => c.eventId === 'evt-2' && c.outcome?.value === 'allowed-once'), true);
  } finally {
    hub.dispose();
  }
});

test('B-3: applyLoopbackCors honors GB_ALLOWED_ORIGINS without allowing wildcards', () => {
  const prev = process.env.GB_ALLOWED_ORIGINS;
  process.env.GB_ALLOWED_ORIGINS = 'https://app.example.com/, *, https://studio.internal:8443';
  try {
    assert.equal(isAllowedCorsOrigin('https://app.example.com'), true);
    assert.equal(isAllowedCorsOrigin('https://studio.internal:8443'), true);
    assert.equal(isAllowedCorsOrigin('https://evil.example.net'), false);
    assert.equal(isAllowedCorsOrigin('*'), false);

    const headers = {};
    const ok = applyLoopbackCors(
      { headers: { origin: 'https://app.example.com', host: '127.0.0.1:3080' } },
      { setHeader(k, v) { headers[k] = v; } },
    );
    assert.equal(ok, true);
    assert.equal(headers['access-control-allow-origin'], 'https://app.example.com');
    assert.equal(headers['access-control-allow-credentials'], 'true');

    const crossPortHeaders = {};
    const okLoop = applyLoopbackCors(
      { headers: { origin: 'http://localhost:8080', host: '127.0.0.1:3080' } },
      { setHeader(k, v) { crossPortHeaders[k] = v; } },
    );
    assert.equal(okLoop, true);
    assert.equal(crossPortHeaders['access-control-allow-credentials'], undefined);
  } finally {
    if (prev === undefined) delete process.env.GB_ALLOWED_ORIGINS;
    else process.env.GB_ALLOWED_ORIGINS = prev;
  }
});

test('B-1: POST /sessions surfaces setupWarnings instead of swallowing post-create failures', async () => {
  const router = new Router();
  const gateway = {
    has: (ep) => ['session/create', 'session/selectModel', 'commands/execute'].includes(ep),
    async call(ep) {
      if (ep === 'session/create') return { sessionId: 'sess-warn-1', title: 'New' };
      if (ep === 'session/selectModel') throw new Error('model quota exhausted');
      if (ep === 'commands/execute') throw new Error('preset locked');
      return {};
    },
  };
  registerChatAndInteractionsDomain(router, { ctx: {}, gateway, hub: { publish() {} }, normalizer: {} });

  const req = new EventEmitter();
  req.method = 'POST';
  req.url = '/sessions';
  let statusCode = 0;
  let bodyText = '';
  const res = {
    writableEnded: false,
    writeHead(code) { statusCode = code; },
    end(chunk) {
      bodyText = String(chunk || '');
      this.writableEnded = true;
    },
  };
  const match = router.match('POST', '/sessions');
  assert.equal(match.kind, 'match');
  const promise = match.route.handler(req, res, { params: match.params, searchParams: new URLSearchParams(), peer: null });
  req.emit('data', Buffer.from(JSON.stringify({
    provider: 'deepseek',
    model: 'deepseek-reasoner',
    permission: 'workspace-write',
  })));
  req.emit('end');
  await promise;

  assert.equal(statusCode, 201);
  const parsed = JSON.parse(bodyText);
  assert.equal(parsed.session.sessionId, 'sess-warn-1');
  assert.ok(Array.isArray(parsed.warnings) && parsed.warnings.length >= 2);
  assert.ok(parsed.warnings.some((w) => w.step === 'model' && w.message.includes('quota')));
  assert.ok(parsed.warnings.some((w) => w.step === 'permission' && w.message.includes('locked')));
});
