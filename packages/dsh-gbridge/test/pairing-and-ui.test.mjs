import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

import { buildQrPathData, encodeQrMatrix, renderQrSvg } from '../lib/qr-svg.js';
import { renderPairingDashboardHtml } from '../lib/pairing-ui.js';
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
