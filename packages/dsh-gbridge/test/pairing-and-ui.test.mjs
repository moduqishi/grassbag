import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

import { buildQrPathData, encodeQrMatrix, renderQrSvg } from '../lib/qr-svg.js';
import { renderPairingDashboardHtml } from '../lib/pairing-ui.js';
import { SessionNormalizer } from '../lib/normalizer.js';
import {
  buildZeroConflictPortCandidates,
  createGbridgeCore,
  createPairingController,
  startLanBridgeListener,
} from '../lib/index.js';

const PKG_DIR = dirname(dirname(fileURLToPath(import.meta.url)));

test('QR SVG encoder produces valid ISO finder patterns and crisp SVG for typical pairing URLs', () => {
  const url = 'http://192.168.31.42:3081/?token=abcDEF1234567890xyz&name=MacBook-Pro';
  const mat = encodeQrMatrix(url);
  assert.ok(mat.version >= 1 && mat.version <= 10);
  assert.equal(mat.size, mat.version * 4 + 17);
  // Top-left 7x7 finder outer border must be dark, inner ring light, 3x3 core dark.
  for (let i = 0; i < 7; i++) {
    assert.equal(mat.modules[0][i], 1);
    assert.equal(mat.modules[6][i], 1);
    assert.equal(mat.modules[i][0], 1);
    assert.equal(mat.modules[i][6], 1);
  }
  assert.equal(mat.modules[1][1], 0);
  assert.equal(mat.modules[3][3], 1);

  const { viewBoxSize, pathData } = buildQrPathData(mat, 3);
  assert.equal(viewBoxSize, mat.size + 6);
  assert.ok(pathData.startsWith('M3 3'));

  const svg = renderQrSvg(url);
  assert.ok(svg.startsWith('<svg '));
  assert.ok(svg.includes(pathData));
});

test('zero-conflict port prober skips busy port and binds cleanly with port-scoped cookie + /gbridge/ui', async () => {
  // Occupy a real TCP port on 127.0.0.1 first to simulate an existing conflicting service.
  const blocker = createServer((_req, res) => res.end('busy'));
  await new Promise((resolve) => blocker.listen(0, '127.0.0.1', resolve));
  const busyPort = blocker.address().port;

  const mockCtx = { get: () => null, logger: { info() {}, warn() {}, error() {} } };
  const core = createGbridgeCore(mockCtx, { logger: mockCtx.logger });
  const pairing = createPairingController(mockCtx, core, { lanEnabled: false });
  core.setPairingController(pairing);

  const handle = startLanBridgeListener(core, {
    host: '127.0.0.1',
    port: busyPort,
    token: 'test-token-1234567890',
    surface: 'desktop',
    logger: mockCtx.logger,
    getPairingSnapshot: () => pairing.getSnapshot(),
  });

  try {
    const info = await handle.ready;
    assert.ok(info.port && info.port !== busyPort, `expected fallback port != ${busyPort}, got ${info.port}`);
    assert.equal(info.conflictAvoided, true);

    // 1. Discovery probe works unauthenticated
    const probeRes = await fetch(`http://127.0.0.1:${info.port}/plugins/events`);
    assert.equal(probeRes.status, 200);
    const probeBody = await probeRes.text();
    assert.ok(probeBody.includes('"hasGbridge":true'));

    // 2. Launch token issues port-scoped HttpOnly cookie `gbridge-lan-auth-<port>`
    const authRes = await fetch(`http://127.0.0.1:${info.port}/?token=test-token-1234567890`, {
      redirect: 'manual',
    });
    assert.equal(authRes.status, 303);
    const setCookie = authRes.headers.get('set-cookie') || '';
    assert.ok(setCookie.startsWith(`gbridge-lan-auth-${info.port}=`), `unexpected set-cookie: ${setCookie}`);

    // 3. Port-scoped cookie authorizes `/gbridge/ui` HTML QR dashboard & `/gbridge/v1/pairing`
    const cookieHeader = setCookie.split(';')[0];
    const uiRes = await fetch(`http://127.0.0.1:${info.port}/gbridge/ui`, {
      headers: { cookie: cookieHeader },
    });
    assert.equal(uiRes.status, 200);
    const uiHtml = await uiRes.text();
    assert.ok(uiHtml.includes('GrassBag 手机扫码配对'));

    const pairRes = await fetch(`http://127.0.0.1:${info.port}/gbridge/v1/pairing`, {
      headers: { cookie: cookieHeader },
    });
    assert.equal(pairRes.status, 200);
    const pairJson = await pairRes.json();
    assert.equal(pairJson.v, 1);
    assert.equal(pairJson.bridgeVersion, core.version);
  } finally {
    handle.dispose({ immediate: true });
    core.dispose();
    await new Promise((resolve) => blocker.close(resolve));
  }
});

test('pairing controller opens ZERO extra ports when dsh web is already LAN-bound, and toggles live on Desktop', async () => {
  const candidates = buildZeroConflictPortCandidates(3080, [3080, 3081]);
  assert.ok(!candidates.includes(3080));
  assert.ok(!candidates.includes(3081));
  assert.equal(candidates[0], 3082);
  assert.equal(candidates[candidates.length - 1], 0);

  // Case A: `dsh web --host 192.168.1.50 --port 3080` -> shared-webserver mode, ZERO extra port!
  const sharedCtx = {
    logger: { info() {}, warn() {}, error() {} },
    get(key) {
      if (key === 'webServer') return { host: '192.168.1.50', port: 3080 };
      if (key === 'profileContext') return { name: 'web' };
      return null;
    },
  };
  const sharedCore = createGbridgeCore(sharedCtx, { logger: sharedCtx.logger });
  const sharedPairing = createPairingController(sharedCtx, sharedCore, {});
  assert.equal(sharedPairing.computeShouldAutoEnableLan(), false);
  const sharedSnap = sharedPairing.getSnapshot();
  assert.equal(sharedSnap.mode, 'shared-webserver');
  assert.equal(sharedSnap.activePort, 3080);
  assert.equal(sharedSnap.lan.enabled, false);
  sharedPairing.dispose();
  sharedCore.dispose();

  // Case B: DSH Desktop (`127.0.0.1:54321`) -> auto-enables in-process LAN bridge & supports live token rotate + pause
  const desktopCtx = {
    logger: { info() {}, warn() {}, error() {} },
    get(key) {
      if (key === 'webServer') return { host: '127.0.0.1', port: 54321 };
      if (key === 'profileContext') return { name: 'desktop' };
      return null;
    },
  };
  const desktopCore = createGbridgeCore(desktopCtx, { logger: desktopCtx.logger });
  const desktopPairing = createPairingController(desktopCtx, desktopCore, { lanHost: '127.0.0.1', lanPort: 0 });
  try {
    assert.equal(desktopPairing.computeShouldAutoEnableLan(), true);
    await desktopPairing.startLan(0);
    const snap1 = desktopPairing.getSnapshot();
    assert.equal(snap1.mode, 'lan-bridge');
    assert.equal(snap1.lan.listening, true);
    assert.ok(snap1.activePort > 0);
    const oldToken = snap1.token;

    const snap2 = await desktopPairing.applyAction({ action: 'rotateToken' });
    assert.notEqual(snap2.token, oldToken);

    const snap3 = await desktopPairing.applyAction({ action: 'setLanEnabled', enabled: false });
    assert.equal(snap3.lan.enabled, false);
    assert.equal(snap3.lan.listening, false);

    // Render standalone HTML with zero exceptions
    const html = renderPairingDashboardHtml(snap2);
    assert.ok(html.includes('GrassBag'));
  } finally {
    desktopPairing.dispose();
    desktopCore.dispose();
  }
});

test('lib/client.js registers all official DSH UI slots cleanly via __ModuleLoader__', () => {
  const src = readFileSync(join(PKG_DIR, 'lib/client.js'), 'utf8');
  let loadedEntry = null;
  const sandbox = {
    window: {
      __ModuleLoader__: {
        load(entry) { loadedEntry = entry; },
      },
    },
    globalThis: {},
    navigator: { language: 'zh-CN' },
    document: { documentElement: { lang: 'zh-CN' }, baseURI: 'http://127.0.0.1:3080/' },
    URL,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
  };
  vm.runInNewContext(src, sandbox);
  assert.ok(loadedEntry && loadedEntry.id === 'dsh-gbridge');

  const fakeReact = {
    createElement: (type, props, ...children) => ({ type, props, children }),
    useState: (init) => [init, () => {}],
    useEffect: () => {},
    useCallback: (fn) => fn,
  };
  const mod = loadedEntry.factory((id) => {
    if (id === 'react') return fakeReact;
    throw new Error(`unexpected require(${id})`);
  });
  assert.deepEqual([...mod.inject], ['slots']);
  assert.equal(typeof mod.apply, 'function');

  const registered = [];
  const fakeCtx = {
    slots: {
      inject(slotName, fn) { fn(); },
      register(opts, comp) {
        registered.push({ ...opts, hasComp: typeof comp === 'function' });
        return () => {};
      },
    },
  };
  mod.apply(fakeCtx);
  const slotNames = registered.map((r) => r.name);
  assert.ok(slotNames.includes('main'));
  assert.ok(slotNames.includes('sidebar.panellist'));
  assert.ok(slotNames.includes('plugins.bundle.activation'));
  assert.ok(slotNames.includes('plugins.bundle.config'));
  assert.ok(slotNames.includes('settings.section'));
  assert.ok(slotNames.includes('settings.section.icon'));
  assert.ok(registered.every((r) => r.hasComp));
});

test('package.json satisfies DSH 0.2.2-rc.5 bundle & client-modules export contract', () => {
  const pkg = JSON.parse(readFileSync(join(PKG_DIR, 'package.json'), 'utf8'));
  assert.notEqual(pkg.private, true, 'package.json must not be marked private for tarball/npm distribution');
  assert.equal(pkg.dsh?.bundle?.patch, './cordis.patch.yml');
  assert.equal(pkg.dsh?.client?.platform, 'web');
  assert.equal(pkg.exports['.'], './lib/index.js');
  assert.equal(pkg.exports['./client'], './lib/client.js');
  assert.equal(pkg.exports['./package.json'], './package.json');
  assert.equal(pkg.exports['./cordis.patch.yml'], './cordis.patch.yml');
  assert.equal(pkg.exports['./locale/*.json'], './locale/*.json');
  assert.ok(existsSync(join(PKG_DIR, pkg.icon)));
  assert.ok(existsSync(join(PKG_DIR, 'lib/client.js')));
  assert.ok(existsSync(join(PKG_DIR, 'locale/en.json')));
  assert.ok(existsSync(join(PKG_DIR, 'locale/zh.json')));
  assert.ok(existsSync(join(PKG_DIR, 'cordis.patch.yml')));
});

test('pairing snapshot gates canRotateToken on lan-bridge mode and dashboard uses safe clipboard copy & dark contrast', () => {
  const sharedCtx = {
    logger: { info() {}, warn() {}, error() {} },
    get(key) {
      if (key === 'webServer') return { host: '192.168.1.50', port: 3080 };
      if (key === 'profileContext') return { name: 'web' };
      return null;
    },
  };
  const sharedCore = createGbridgeCore(sharedCtx, { logger: sharedCtx.logger });
  const sharedPairing = createPairingController(sharedCtx, sharedCore, { lanEnabled: true });
  const snap = sharedPairing.getSnapshot();
  assert.equal(snap.mode, 'shared-webserver');
  assert.equal(snap.canRotateToken, false);
  const html = renderPairingDashboardHtml(snap);
  assert.ok(html.includes('copyTextSafe'), 'pairing-ui must include HTTP-LAN safe clipboard fallback');
  assert.ok(html.includes('--accent-fg: #042f2e'), 'dark primary button must use high-contrast foreground');
  assert.ok(html.includes('刷新状态'), 'pairing-ui must expose manual refresh action');
  sharedCore.dispose();
});

test('SessionNormalizer humanizes phone_* results, marks blocked/error results, and preserves user attachment data/url', () => {
  const norm = new SessionNormalizer();
  const turns = norm.normalizeEvents('s-phone-v27', [
    { seq: 1, type: 'turn/start', turnId: 't-phone-1', data: { turnId: 't-phone-1' } },
    {
      seq: 2,
      type: 'user/message',
      turnId: 't-phone-1',
      data: {
        id: 'u-1',
        content: [
          { type: 'text', text: '看看这张图' },
          { type: 'image', name: 'shot.png', mimeType: 'image/png', data: 'iVBORw0KGgo=' },
        ],
      },
    },
    {
      seq: 3,
      type: 'tool/call',
      turnId: 't-phone-1',
      data: { callId: 'tc-open', name: 'phone_open', arguments: { package: 'com.android.deskclock' } },
    },
    {
      seq: 4,
      type: 'tool/result',
      turnId: 't-phone-1',
      data: {
        callId: 'tc-open',
        name: 'phone_open',
        output: JSON.stringify({ ok: true, opened: '时钟', package: 'com.android.deskclock' }),
      },
    },
    {
      seq: 5,
      type: 'tool/call',
      turnId: 't-phone-1',
      data: { callId: 'tc-screen', name: 'phone_screen', arguments: {} },
    },
    {
      seq: 6,
      type: 'tool/result',
      turnId: 't-phone-1',
      data: {
        callId: 'tc-screen',
        name: 'phone_screen',
        output: JSON.stringify({
          ok: true,
          package: 'com.android.deskclock',
          count: 3,
          elements: [{ text: '闹钟' }, { text: '秒表' }, { text: '计时器' }],
        }),
      },
    },
    {
      seq: 7,
      type: 'tool/call',
      turnId: 't-phone-1',
      data: { callId: 'tc-tap', name: 'phone_tap', arguments: { index: 2 } },
    },
    {
      seq: 8,
      type: 'tool/result',
      turnId: 't-phone-1',
      data: {
        callId: 'tc-tap',
        name: 'phone_tap',
        output: JSON.stringify({ ok: false, blocked: true, reason: 'bank_app', hint: '银行应用已安全拦截' }),
      },
    },
    { seq: 9, type: 'turn/end', turnId: 't-phone-1', data: { turnId: 't-phone-1' } },
  ]);

  assert.equal(turns.length, 1);
  const t0 = turns[0];
  assert.equal(t0.userMessage.attachments.length, 1);
  assert.equal(t0.userMessage.attachments[0].data, 'iVBORw0KGgo=');
  const openStep = t0.steps.find((s) => s.callId === 'tc-open');
  assert.ok(openStep.title.includes('时钟'), `expected humanized title, got: ${openStep.title}`);
  const screenStep = t0.steps.find((s) => s.callId === 'tc-screen');
  assert.ok(screenStep.summary.includes('3'), `expected element count in summary, got: ${screenStep.summary}`);
  const tapStep = t0.steps.find((s) => s.callId === 'tc-tap');
  assert.equal(tapStep.status, 'error');
  assert.ok(tapStep.summary.includes('银行应用已安全拦截'));
});

test('QR SVG encoder emits ISO/IEC 18004 valid BCH(15,5) format bits & mandatory dark module', () => {
  const sampleUrls = [
    'http://192.168.1.2:3080/?t=1',
    'http://192.168.31.42:3081/?token=abcDEF1234567890xyz&name=MacBook-Pro',
    `http://192.168.1.99:3080/?token=${'a'.repeat(120)}`,
  ];
  const bchSyndrome = (bits15) => {
    const raw = bits15 ^ 0x5412;
    let rem = raw;
    for (let i = 14; i >= 10; i--) {
      if ((rem >>> i) & 1) rem ^= 0x537 << (i - 10);
    }
    return rem;
  };
  for (const url of sampleUrls) {
    const { size, modules } = encodeQrMatrix(url);
    assert.equal(modules[size - 8][8], 1, `mandatory dark module must be 1 for ${url}`);
    // Copy 1: top-left around finder (MSB first: bit 14 -> bit 0)
    const c1Coords = [
      [8, 0], [8, 1], [8, 2], [8, 3], [8, 4], [8, 5], [8, 7], [8, 8],
      [7, 8], [5, 8], [4, 8], [3, 8], [2, 8], [1, 8], [0, 8],
    ];
    // Copy 2: bottom-left + top-right (MSB first: bit 14 -> bit 0)
    const c2Coords = [
      [size - 1, 8], [size - 2, 8], [size - 3, 8], [size - 4, 8],
      [size - 5, 8], [size - 6, 8], [size - 7, 8],
      [8, size - 8], [8, size - 7], [8, size - 6], [8, size - 5],
      [8, size - 4], [8, size - 3], [8, size - 2], [8, size - 1],
    ];
    let copy1 = 0;
    let copy2 = 0;
    for (let i = 0; i < 15; i++) {
      copy1 = (copy1 << 1) | modules[c1Coords[i][0]][c1Coords[i][1]];
      copy2 = (copy2 << 1) | modules[c2Coords[i][0]][c2Coords[i][1]];
    }
    assert.equal(copy1, copy2, `format info copies must match for ${url}`);
    assert.equal(bchSyndrome(copy1), 0, `format info BCH(15,5) syndrome must be 0 for ${url}`);
  }
});

test('security hardening: /fs/browse rejects /etc, /web-ticket ignores forged X-Forwarded-Host, rotateToken revokes LAN WS', async () => {
  const mockConnection = {
    allowsRemoteAuthorities: false,
    authenticatedUrl(baseUrl) {
      return `${baseUrl}/?token=secret-dsh-tok`;
    },
    admit() {
      return { peer: { id: 'test-peer' } };
    },
  };
  const mockCtx = {
    logger: { info() {}, warn() {}, error() {} },
    get(key) {
      if (key === 'webServer') {
        return { host: '127.0.0.1', port: 54321 };
      }
      if (key === 'connection') return mockConnection;
      if (key === 'profileContext') return { name: 'desktop' };
      return null;
    },
  };
  const core = createGbridgeCore(mockCtx, { logger: mockCtx.logger });
  const pairing = createPairingController(mockCtx, core, { lanHost: '127.0.0.1', lanPort: 0 });
  core.setPairingController(pairing);
  try {
    await pairing.startLan(0);
    const snap = pairing.getSnapshot();
    const port = snap.activePort;
    const token = snap.token;
    const headers = { authorization: `Bearer ${token}` };

    // 1. /fs/browse must reject /etc outside home & registered workspaces
    const browseRes = await fetch(`http://127.0.0.1:${port}/gbridge/v1/fs/browse?path=/etc`, {
      headers,
    });
    assert.equal(browseRes.status, 403);

    // 2. /web-ticket on shared webServer mode must ignore forged X-Forwarded-Host when remote authorities disallowed
    const webSrv = createServer((req, res) => core.handleHttp(req, res, { mode: 'webServer' }));
    await new Promise((resolve) => webSrv.listen(0, '127.0.0.1', resolve));
    try {
      const wPort = webSrv.address().port;
      const ticketRes = await fetch(`http://127.0.0.1:${wPort}/gbridge/v1/web-ticket`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-forwarded-host': 'evil.attacker.example',
          'x-forwarded-proto': 'https',
        },
        body: '{}',
      });
      assert.equal(ticketRes.status, 200);
      const ticketJson = await ticketRes.json();
      assert.ok(
        String(ticketJson.authenticatedUrl || '').startsWith(`http://127.0.0.1:${wPort}`),
        `expected request host origin, got: ${ticketJson.authenticatedUrl}`,
      );
      assert.ok(
        !String(ticketJson.authenticatedUrl || '').includes('evil.attacker.example'),
        `forged host leaked: ${ticketJson.authenticatedUrl}`,
      );
    } finally {
      await new Promise((resolve) => webSrv.close(resolve));
    }

    // 3. rotateToken must forcibly disconnect existing LAN WebSocket clients with code 4001
    const closedCodes = [];
    const fakeWs = {
      readyState: 1,
      send() {},
      close(code) {
        closedCodes.push(code);
        this.readyState = 3;
      },
      on() {},
    };
    core.hub.attachClient(fakeWs, { mode: 'lan' });
    await pairing.applyAction({ action: 'rotateToken' });
    assert.deepEqual(closedCodes, [4001]);
  } finally {
    pairing.dispose();
    core.dispose();
  }
});
