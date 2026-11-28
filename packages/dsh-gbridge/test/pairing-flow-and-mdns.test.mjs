import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import crypto from 'node:crypto';
import { createGbridgeCore, createPairingController } from '../lib/index.js';
import { renderPairingDashboardHtml } from '../lib/pairing-ui.js';
import {
  GRASSBAG_SERVICE_TYPE,
  DNS_TYPE_PTR,
  DNS_TYPE_SRV,
  DNS_TYPE_TXT,
  DNS_TYPE_A,
  buildMdnsAnnouncementPacket,
  decodeDnsName,
  encodeDnsName,
  parseMdnsQueryQuestions,
} from '../lib/mdns.js';

function createMockCtx() {
  return {
    logger: { info() {}, warn() {}, debug() {}, error() {} },
    get(key) {
      if (key === 'profileContext') return { name: 'desktop' };
      if (key === 'webServer') return { host: '127.0.0.1', port: 49999 };
      return undefined;
    },
  };
}

function connectRawWs(port, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const key = crypto.randomBytes(16).toString('base64');
    const req = http.request({
      host: '127.0.0.1',
      port,
      path,
      headers: {
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': key,
        ...headers,
      },
    });
    req.on('upgrade', (_res, socket) => {
      resolve(socket);
    });
    req.on('response', (res) => {
      reject(new Error(`Unexpected HTTP ${res.statusCode}`));
    });
    req.on('error', reject);
    req.end();
  });
}

function encodeClientTextFrame(text) {
  const payload = Buffer.from(text, 'utf8');
  const mask = crypto.randomBytes(4);
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, 0x80 | payload.length]);
  } else {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(payload.length, 2);
  }
  const masked = Buffer.alloc(payload.length);
  for (let i = 0; i < payload.length; i++) {
    masked[i] = payload[i] ^ mask[i % 4];
  }
  return Buffer.concat([header, mask, masked]);
}

function readNextServerTextFrame(socket, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    let buf = Buffer.alloc(0);
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error('timeout waiting for WS frame'));
    }, timeoutMs);
    const onData = (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      if (buf.length < 2) return;
      let len = buf[1] & 0x7f;
      let offset = 2;
      if (len === 126) {
        if (buf.length < 4) return;
        len = buf.readUInt16BE(2);
        offset = 4;
      } else if (len === 127) {
        if (buf.length < 10) return;
        len = Number(buf.readBigUInt64BE(2));
        offset = 10;
      }
      if (buf.length < offset + len) return;
      const text = buf.subarray(offset, offset + len).toString('utf8');
      cleanup();
      resolve(JSON.parse(text));
    };
    const onErr = (err) => {
      cleanup();
      reject(err);
    };
    const cleanup = () => {
      clearTimeout(timer);
      socket.off('data', onData);
      socket.off('error', onErr);
    };
    socket.on('data', onData);
    socket.on('error', onErr);
  });
}

test('pairing session tracks waiting -> connecting -> connected per pairCode and rejects expired codes with x-gbridge-error', async () => {
  const ctx = createMockCtx();
  const core = createGbridgeCore(ctx, { logger: ctx.logger });
  const pairing = createPairingController(ctx, core, {
    lanPort: 0,
    lanToken: 'pair-secret-token-1234',
    mdns: false,
  });
  core.setPairingController(pairing);

  let wsSocket = null;
  try {
    await pairing.startLan(0);
    const snap1 = pairing.getSnapshot();
    assert.equal(snap1.mode, 'lan-bridge');
    assert.equal(snap1.pairingSession.status, 'waiting');
    assert.ok(snap1.pairingSession.code && snap1.pairingSession.code.length >= 8);
    assert.ok(snap1.primaryEndpoint.url.includes(`p=${snap1.pairingSession.code}`));
    assert.ok(snap1.primaryEndpoint.pairUri.includes(`p=${snap1.pairingSession.code}`));

    const port = snap1.activePort;
    const code1 = snap1.pairingSession.code;

    // 1) HTTP token + pairCode exchange transitions pairingSession to `connecting`
    const exchangeRes = await fetch(
      `http://127.0.0.1:${port}/?token=pair-secret-token-1234&p=${encodeURIComponent(code1)}`,
      { redirect: 'manual' },
    );
    assert.equal(exchangeRes.status, 303);
    const cookie = (exchangeRes.headers.get('set-cookie') || '').split(';')[0];
    assert.ok(cookie.startsWith(`gbridge-lan-auth-${port}=`));
    assert.equal(pairing.getSnapshot().pairingSession.status, 'connecting');

    // 2) WebSocket `hello` carrying matching `pairCode` transitions pairingSession to `connected`!
    wsSocket = await connectRawWs(port, '/gbridge/v1/stream', { Cookie: cookie });
    const welcomePromise = readNextServerTextFrame(wsSocket);
    wsSocket.write(encodeClientTextFrame(JSON.stringify({
      op: 'hello',
      v: 1,
      clientId: 'grassbag-android-phone',
      pairCode: code1,
      channels: ['host'],
    })));
    const welcome = await welcomePromise;
    assert.equal(welcome.op, 'welcome');

    const snap2 = pairing.getSnapshot();
    assert.equal(snap2.pairingSession.status, 'connected');
    assert.equal(snap2.pairingSession.deviceLabel, '你的手机');
    assert.equal(snap2.pairingSession.activeDeviceConnected, true);

    // 3) Issuing a new pairing code resets to `waiting` for the next phone while expiring the old code
    const snap3 = await pairing.applyAction({ action: 'newPairingCode' });
    assert.equal(snap3.pairingSession.status, 'waiting');
    assert.notEqual(snap3.pairingSession.code, code1);
    assert.equal(core.hub.clients.size, 1); // existing paired phone stays connected!

    // 4) Scanning the old expired/rotated pairCode returns 401 with `x-gbridge-error: gbridge/pairing_code_expired`
    const staleRes = await fetch(
      `http://127.0.0.1:${port}/?token=pair-secret-token-1234&p=${encodeURIComponent(code1)}`,
      { redirect: 'manual' },
    );
    assert.equal(staleRes.status, 401);
    assert.equal(staleRes.headers.get('x-gbridge-error'), 'gbridge/pairing_code_expired');
  } finally {
    try { wsSocket?.destroy(); } catch (_) {}
    pairing.dispose();
    core.dispose();
  }
});

test('simplified desktop HTML dashboard focuses on live pairing status, copy link, collapsible More, and explicit LAN error retry', () => {
  const htmlWaiting = renderPairingDashboardHtml({
    hostName: 'StudioMac',
    bridgeVersion: '0.2.0',
    mode: 'lan-bridge',
    activePort: 3085,
    connectedClients: 0,
    pairingSession: { code: 'abc12345', status: 'waiting' },
    lan: { enabled: true, listening: true, port: 3085, error: null },
    endpoints: [
      { iface: 'en0', label: 'Wi-Fi', ip: '192.168.1.42', port: 3085, url: 'http://192.168.1.42:3085/?token=t&p=abc12345', qr: { viewBoxSize: 29, pathData: 'M0 0h1v1h-1z' } },
    ],
  });
  assert.ok(htmlWaiting.includes('等待手机扫码连接'));
  assert.ok(htmlWaiting.includes('复制配对链接'));
  assert.ok(htmlWaiting.includes('>更多<'));
  assert.ok(htmlWaiting.includes('已连接到'));
  assert.ok(htmlWaiting.includes('局域网监听启动失败'));
  assert.ok(htmlWaiting.includes('重试启动'));
});

test('mDNS DNS-SD responder packet encodes non-standard dynamic port, PTR/SRV/TXT/A records, and parses queries', () => {
  const pkt = buildMdnsAnnouncementPacket({
    instanceLabel: 'StudioMac (54321)',
    hostLabel: 'StudioMac',
    port: 54321,
    ipv4List: ['192.168.1.88'],
    txtEntries: ['v=1', 'host=StudioMac', 'surface=desktop', 'port=54321'],
    ttl: 120,
  });
  // Verify header: QR=1 AA=1 (0x8400), ANCOUNT = 4 (PTR + SRV + TXT + A)
  assert.equal(pkt.readUInt16BE(2), 0x8400);
  assert.equal(pkt.readUInt16BE(6), 4);

  // Walk answer RRs to confirm exact SRV port 54321, PTR service type, TXT, and A 192.168.1.88
  let offset = 12;
  const seenTypes = new Set();
  let srvPort = null;
  let aRecordIp = null;
  for (let i = 0; i < 4; i++) {
    const dec = decodeDnsName(pkt, offset);
    offset = dec.nextOffset;
    const type = pkt.readUInt16BE(offset);
    const rdlen = pkt.readUInt16BE(offset + 8);
    const rdataStart = offset + 10;
    seenTypes.add(type);
    if (type === DNS_TYPE_PTR) {
      assert.equal(dec.name, GRASSBAG_SERVICE_TYPE);
    } else if (type === DNS_TYPE_SRV) {
      srvPort = pkt.readUInt16BE(rdataStart + 4);
    } else if (type === DNS_TYPE_A) {
      aRecordIp = [...pkt.subarray(rdataStart, rdataStart + 4)].join('.');
    }
    offset = rdataStart + rdlen;
  }
  assert.deepEqual([...seenTypes].sort((a, b) => a - b), [DNS_TYPE_A, DNS_TYPE_PTR, DNS_TYPE_TXT, DNS_TYPE_SRV]);
  assert.equal(srvPort, 54321);
  assert.equal(aRecordIp, '192.168.1.88');

  // Construct an incoming mDNS PTR query for `_grassbag._tcp.local` and confirm parser extracts it
  const qHeader = Buffer.alloc(12);
  qHeader.writeUInt16BE(0x0000, 2); // QR=0 query
  qHeader.writeUInt16BE(1, 4); // QDCOUNT=1
  const qName = encodeDnsName(GRASSBAG_SERVICE_TYPE);
  const qTail = Buffer.alloc(4);
  qTail.writeUInt16BE(DNS_TYPE_PTR, 0);
  qTail.writeUInt16BE(1, 2);
  const questions = parseMdnsQueryQuestions(Buffer.concat([qHeader, qName, qTail]));
  assert.equal(questions.length, 1);
  assert.equal(questions[0].name, GRASSBAG_SERVICE_TYPE);
  assert.equal(questions[0].type, DNS_TYPE_PTR);
});
