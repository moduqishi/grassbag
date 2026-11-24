import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gbridge_client/gbridge_client.dart';
import 'package:test/test.dart';

/// Real cross-language integration test: Dart SDK (`gbridge_client`) talking directly
/// to the real Node `packages/dsh-gbridge` implementation over BOTH TCP HTTP+WS
/// and `0600` Unix Domain Socket, plus Remote Bootstrap Mode 404 -> 1-tap install.
void main() {
  late Directory tempDir;
  late Process nodeProc;
  late int tcpPort;
  late String udsPath;
  const udsToken = 'test-uds-secret-token-42';

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('gbridge-dart-e2e-');
    udsPath = '${tempDir.path}/gbridge.sock';
    final bridgeEntry = File('../dsh-gbridge/lib/index.js').absolute.path;

    final serverScript = '''
import { createServer } from 'node:http';
import { chmodSync } from 'node:fs';
import { createGbridgeCore, PREFIX, STREAM_PATH } from ${jsonEncode(bridgeEntry)};

let bridgeInstalled = true;
const mockEndpoints = new Map([
  ['session/list', async () => [{ id: 's1', title: 'PDF Export Fix', running: false }]],
  ['session/page', async ({ sessionId }) => ({
    events: [
      { seq: 1, type: 'user/message', id: 'u1', data: { text: 'Check key sk-1234567890abcdef1234' } },
      { seq: 2, type: 'assistant/message', data: { content: [
        { type: 'reasoning', id: 'r1', text: 'Inspecting DPR' },
        { type: 'tool-call', id: 'c1', name: 'edit', arguments: { path: 'src/pdf.ts' } },
        { type: 'text', text: 'Done!' }
      ] } },
      { seq: 3, type: 'tool/result', data: { callId: 'c1', output: 'ok', durationMs: 12 } },
      { seq: 4, type: 'turn/end', data: { status: 'completed', usage: { inputTokens: 100, outputTokens: 20 } } },
    ],
    hasMore: false,
  })],
  ['session/prompt', async (args) => ({ accepted: true, sessionId: args.sessionId, text: args.text })],
  ['terminal/write', async (args) => {
    core.hub.publish('terminal:' + args.terminalId, 'term.data', { terminalId: args.terminalId, chunk: 'ECHO:' + args.data });
    return { ok: true };
  }],
]);

const fakeGateway = {
  ready: true,
  has: (ep) => mockEndpoints.has(ep),
  listEndpoints: () => [...mockEndpoints.keys()],
  call: async (ep, args) => {
    const fn = mockEndpoints.get(ep);
    if (!fn) throw new Error('missing ' + ep);
    return fn(args || {});
  },
  openStream: async function* () {},
  openRemoteEvents: () => null,
};

const fakeCtx = {
  get: (key) => {
    if (key === 'connection') {
      return {
        admit: (req) => {
          const cookie = String(req.headers?.cookie || '');
          if (!cookie.includes('dsh_session=valid-cookie')) {
            return { rejection: 401 };
          }
          return { peer: { role: 'operator' } };
        },
        authenticatedUrl: (u) => u + '/?token=web-tk',
      };
    }
    if (key === 'webServer') return { host: '127.0.0.1', port: 3080 };
    return undefined;
  },
};

const core = createGbridgeCore(fakeCtx, {
  bootId: 'boot-dart-e2e-1',
  gateway: fakeGateway,
  isLocalAndroid: false,
});

// Helper to emit a test event on demand (for resumeFromSeq test)
const tcpServer = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname === '/' && url.searchParams.get('token') === 'valid-token') {
    res.writeHead(200, { 'set-cookie': 'dsh_session=valid-cookie; Path=/; HttpOnly' });
    res.end('ok');
    return;
  }
  if (url.pathname === '/__toggle_bridge') {
    bridgeInstalled = url.searchParams.get('on') !== '0';
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ bridgeInstalled }));
    return;
  }
  if (url.pathname === '/__emit') {
    const frame = core.hub.publish('host', 'test.ping', { n: Number(url.searchParams.get('n') || 1) });
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ seq: frame.seq }));
    return;
  }
  if (url.pathname === '/api/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, version: '0.2.2-rc.5' }));
    return;
  }
  if (url.pathname === '/api/pluginManager/installBundle') {
    bridgeInstalled = true;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      type: 'server-response',
      result: { ok: true, value: { application: 'applied' } },
    }));
    return;
  }
  if (url.pathname.startsWith(PREFIX)) {
    if (!bridgeInstalled) {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { code: 'not_found', message: 'gbridge not installed' } }));
      return;
    }
    await core.handleHttp(req, res, { mode: 'webServer' });
    return;
  }
  res.writeHead(404);
  res.end('not found');
});

tcpServer.on('upgrade', (req, socket, head) => {
  if (req.url?.startsWith(STREAM_PATH) && bridgeInstalled) {
    core.handleUpgrade(req, socket, head, { mode: 'webServer' });
  } else {
    socket.destroy();
  }
});

const udsServer = createServer((req, res) => {
  core.handleHttp(req, res, { mode: 'uds', bearerToken: ${jsonEncode(udsToken)} });
});
udsServer.on('upgrade', (req, socket, head) => {
  core.handleUpgrade(req, socket, head, { mode: 'uds', bearerToken: ${jsonEncode(udsToken)} });
});

await new Promise((r) => tcpServer.listen(0, '127.0.0.1', r));
await new Promise((r) => udsServer.listen(${jsonEncode(udsPath)}, () => {
  chmodSync(${jsonEncode(udsPath)}, 0o600);
  r();
}));

console.log(JSON.stringify({ ready: true, port: tcpServer.address().port }));
process.on('SIGTERM', () => {
  core.dispose();
  tcpServer.closeAllConnections?.();
  udsServer.closeAllConnections?.();
  process.exit(0);
});
''';

    final scriptFile = File('${tempDir.path}/server.mjs');
    await scriptFile.writeAsString(serverScript);

    nodeProc = await Process.start('node', [scriptFile.path]);
    final readyCompleter = Completer<int>();
    nodeProc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (!readyCompleter.isCompleted && line.startsWith('{')) {
        final obj = jsonDecode(line) as Map<String, dynamic>;
        if (obj['ready'] == true) {
          readyCompleter.complete((obj['port'] as num).toInt());
        }
      }
    });
    final stderrBuf = StringBuffer();
    nodeProc.stderr.transform(utf8.decoder).listen(stderrBuf.write);
    tcpPort = await readyCompleter.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => throw StateError('Node harness failed to boot: $stderrBuf'),
    );
  });

  tearDownAll(() async {
    nodeProc.kill(ProcessSignal.sigterm);
    await nodeProc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => 0);
    await tempDir.delete(recursive: true);
  });

  test('TCP HTTP cookie exchange + capabilities + normalized turns + SDUI + WS resumeFromSeq', () async {
    final client = GbridgeClient(
      HostEndpoint.http(
        baseUri: Uri.parse('http://127.0.0.1:$tcpPort'),
        token: 'valid-token',
      ),
      autoReconnect: false,
    );
    addTearDown(client.dispose);

    // 1. Capabilities auto-exchanges token -> cookie on first 401
    final caps = await client.getCapabilities();
    expect(caps.v, 1);
    expect(caps.bootId, 'boot-dart-e2e-1');
    expect(caps.hasDomain('chat'), isTrue);
    expect(caps.hasDomain('sdui'), isTrue);

    // 2. Sessions & normalized turns with secret masking
    final sessions = await client.listSessions();
    expect(sessions.single.id, 's1');

    final turnsPage = await client.getSessionTurns('s1');
    expect(turnsPage.turns, hasLength(1));
    final turn = turnsPage.turns.single;
    expect(turn.userMessage?.maskedRanges, isNotEmpty);
    expect(turn.assistantText, 'Done!');
    expect(turn.steps, hasLength(2));

    // 3. Send message
    final sent = await client.sendMessage('s1', text: 'hello grassbag');
    expect((sent['result'] as Map)['accepted'], isTrue);

    // 4. SDUI surface discovery & view fetch
    final surfaces = await client.listSduiSurfaces();
    expect(surfaces.any((s) => s.id == 'host-diagnostics'), isTrue);
    final view = await client.getSduiView('host-diagnostics');
    expect(view.title, '主机运行状态');

    // 5. WebSocket welcome + live event + disconnect + resumeFromSeq replay!
    final welcome1 = await client.stream.connect();
    expect(welcome1.bootId, 'boot-dart-e2e-1');
    expect(welcome1.resumed, isFalse);

    final firstEventFuture = client.stream.frames.firstWhere((f) => f.type == 'test.ping');
    await client.transport.requestJson('GET', '/__emit', query: {'n': '1'});
    final ev1 = await firstEventFuture.timeout(const Duration(seconds: 3));
    expect((ev1.dataMap?['n'] as num).toInt(), 1);
    final seqAtDisconnect = client.stream.lastSeq;
    expect(seqAtDisconnect, greaterThanOrEqualTo(1));

    // Disconnect, emit missed event on server, then reconnect & verify replay!
    await client.stream.disconnect();
    await client.transport.requestJson('GET', '/__emit', query: {'n': '2'});

    final replayedFuture = client.stream.frames.firstWhere(
      (f) => f.type == 'test.ping' && f.dataMap?['n'] == 2,
    );
    final welcome2 = await client.stream.connect();
    expect(welcome2.resumed, isTrue);
    expect(welcome2.replayedCount, greaterThanOrEqualTo(1));
    final replayed = await replayedFuture.timeout(const Duration(seconds: 3));
    expect(replayed.seq, greaterThan(seqAtDisconnect));
  });

  test('0600 Unix Domain Socket HTTP + WebSocket terminal input round-trip', () async {
    final udsClient = GbridgeClient(
      HostEndpoint.unix(socketPath: udsPath, token: udsToken),
      autoReconnect: false,
    );
    addTearDown(udsClient.dispose);

    final caps = await udsClient.getCapabilities();
    expect(caps.bootId, 'boot-dart-e2e-1');

    final welcome = await udsClient.stream.connect();
    expect(welcome.bootId, 'boot-dart-e2e-1');

    udsClient.stream.subscribe('terminal:t1');
    final termFuture = udsClient.stream.frames.firstWhere((f) => f.type == 'term.data');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    udsClient.stream.sendTerminalInput('t1', 'ls\n');

    final termFrame = await termFuture.timeout(const Duration(seconds: 3));
    expect(termFrame.dataMap?['chunk'], 'ECHO:ls\n');
  });

  test('Remote Bootstrap Mode detects 404 vanilla DSH and upgrades via 1-tap installHelperBundle', () async {
    final client = GbridgeClient(
      HostEndpoint.http(
        baseUri: Uri.parse('http://127.0.0.1:$tcpPort'),
        token: 'valid-token',
      ),
      autoReconnect: false,
    );
    addTearDown(() async {
      await client.transport.requestJson('GET', '/__toggle_bridge', query: {'on': '1'}).catchError((_) => <String, dynamic>{});
      await client.dispose();
    });

    await client.exchangeAuthToken();
    await client.transport.requestJson('GET', '/__toggle_bridge', query: {'on': '0'});

    final probe = await client.probeHost();
    expect(probe, isA<HostProbeBootstrapOnly>());
    expect((probe as HostProbeBootstrapOnly).dshVersion, '0.2.2-rc.5');

    final stages = <String>[];
    final upgradedCaps = await client.bootstrap.installHelperBundle(
      onProgress: stages.add,
      pollInterval: const Duration(milliseconds: 100),
    );
    expect(upgradedCaps.bootId, 'boot-dart-e2e-1');
    expect(stages.length, greaterThanOrEqualTo(2));
  });

  test('disconnect() and dispose() return promptly without hanging on unresponsive peer sockets', () async {
    // Spawn a mock TCP server that accepts connections and never replies to HTTP/WS frames.
    final stalledServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = <Socket>[];
    final sub = stalledServer.listen((sock) {
      accepted.add(sock);
      // Intentionally swallow all bytes and never reply or close!
      sock.listen((_) {});
    });
    addTearDown(() async {
      await sub.cancel();
      for (final s in accepted) {
        s.destroy();
      }
      await stalledServer.close();
    });

    final client = GbridgeClient(
      HostEndpoint.http(
        baseUri: Uri.parse('http://127.0.0.1:${stalledServer.port}'),
        token: 'stalled-token',
      ),
      autoReconnect: true,
    );

    // Kick off a connection attempt against the blackhole socket, then immediately dispose.
    // Even with a blackhole peer, dispose() must finish cleanly well under 1.2s!
    final Future<WelcomeInfo?> connectFuture =
        client.stream.connect().then<WelcomeInfo?>((w) => w).catchError((_) => null);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final sw = Stopwatch()..start();
    await client.dispose();
    sw.stop();

    expect(sw.elapsedMilliseconds, lessThan(1200));
    await connectFuture.timeout(const Duration(seconds: 2), onTimeout: () => null);
  });
}
