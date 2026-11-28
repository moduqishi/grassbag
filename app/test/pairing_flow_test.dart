import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbridge_client/gbridge_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:grassbag/data/grassbag_storage.dart';
import 'package:grassbag/services/native_bridge.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/theme/grassbag_glass.dart';
import 'package:grassbag/theme/grassbag_theme.dart';
import 'package:grassbag/ui/common/remote_host_connect_card.dart';
import 'package:grassbag/ui/shell/grassbag_shell.dart';

Widget _wrap(Widget child, {ProviderContainer? container}) {
  final app = MaterialApp(
    theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
    home: MediaQuery(
      data: const MediaQueryData(size: Size(396, 834)),
      child: GrassBagGlassTierScope(
        tier: GrassBagGlassTier.solid,
        child: child,
      ),
    ),
  );
  if (container != null) {
    return UncontrolledProviderScope(container: container, child: app);
  }
  return ProviderScope(child: app);
}

Map<String, dynamic> _mockCapabilitiesJson({String hostName = 'StudioMac'}) => {
      'v': 1,
      'bridgeVersion': '0.2.0',
      'dshVersion': '0.2.2-rc.5',
      'bootId': 'boot-pair-test-1',
      'host': {
        'name': hostName,
        'platform': 'darwin',
        'arch': 'arm64',
        'isLocalAndroid': false,
      },
      'transport': {
        'wsPath': '/gbridge/v1/stream',
        'coalesceMs': 35,
        'replayCapacity': 200,
      },
      'domains': {
        'chat': {'ok': true, 'features': ['streaming', 'turns']},
        'settings': {'ok': true, 'features': ['models']},
        'workspaces': {'ok': true, 'features': ['list']},
      },
      'endpointsCount': 42,
    };

void main() {
  setUp(() {
    GrassBagController.disableAutoAppUpdateCheck = true;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    GrassBagStorage.instance.resetCacheForTest();
  });

  tearDown(() {
    GrassBagController.allowLoopbackRemoteForTest = false;
    GrassBagStorage.instance.resetCacheForTest();
  });

  group('Stage 1: Atomic Staged Pairing Verification & Failure Recovery', () {
    setUp(() {
      final prev = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prev);
    });

    test('preflight OK + realtime WebSocket FAIL keeps original host, session, turns, and composer draft intact', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      GrassBagController.allowLoopbackRemoteForTest = true;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        if (req.uri.path == '/gbridge/v1/capabilities') {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(_mockCapabilitiesJson(hostName: 'BrokenWsMac')));
          await req.response.close();
          return;
        }
        if (req.uri.path == '/gbridge/v1/stream') {
          req.response
            ..statusCode = 502
            ..write('WebSocket gateway down');
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      // Seed active original session + draft on local host
      ctrl.state = container.read(appProvider).copyWith(
            activeHostId: 'local',
            activeSessionId: 'orig-sess-1',
            sessions: const [
              ChatSessionItem(id: 'orig-sess-1', title: '原对话', group: '今天'),
            ],
            turns: const [
              NormalizedTurn(
                turnId: 't-orig',
                status: 'completed',
                userMessage: NormalizedUserMessage(id: 'u-orig', text: '不要丢掉我'),
                assistantText: '原会话内容完好。',
              ),
            ],
          );
      ctrl.setComposerDraftForScope('local', 'orig-sess-1', '尚未发出的重要草稿');
      final initialHostCount = container.read(appProvider).hosts.length;

      final stages = <PairingStage>[];
      final outcome = await ctrl.connectRemoteInput(
        'http://127.0.0.1:${server.port}/?token=testtok&name=BrokenWsMac',
        onStageChanged: (s, {computerName}) => stages.add(s),
      );

      expect(outcome.connected, isFalse);
      expect(outcome.diagnosis.kind, RemoteDiagnosisKind.realtimeFailed);
      expect(stages, containsAllInOrder([
        PairingStage.connecting,
        PairingStage.authorizing,
        PairingStage.openingSession,
        PairingStage.failed,
      ]));

      // Original host, session, turns, host list, and composer draft MUST be 100% untouched!
      final after = container.read(appProvider);
      expect(after.activeHostId, 'local');
      expect(after.activeSessionId, 'orig-sess-1');
      expect(after.turns.length, 1);
      expect(after.turns.first.userMessage?.text, '不要丢掉我');
      expect(after.hosts.length, initialHostCount);
      expect(ctrl.getComposerDraftForScope('local', 'orig-sess-1'), '尚未发出的重要草稿');
    });

    test('preflight + WS OK but sessions API FAIL keeps original session intact and reports realtimeFailed', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      GrassBagController.allowLoopbackRemoteForTest = true;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        if (req.uri.path == '/gbridge/v1/capabilities') {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(_mockCapabilitiesJson(hostName: 'NoSessionsMac')));
          await req.response.close();
          return;
        }
        if (req.uri.path == '/gbridge/v1/stream' && WebSocketTransformer.isUpgradeRequest(req)) {
          final ws = await WebSocketTransformer.upgrade(req);
          ws.listen((raw) {
            final msg = jsonDecode(raw.toString()) as Map<String, dynamic>;
            if (msg['op'] == 'hello') {
              ws.add(jsonEncode({
                'op': 'welcome',
                'v': 1,
                'bootId': 'boot-pair-test-1',
                'currentSeq': 1,
                'resumed': false,
                'replayedCount': 0,
                'heartbeatMs': 30000,
                'pendingInteractions': const [],
              }));
            }
          });
          return;
        }
        if (req.uri.path == '/gbridge/v1/sessions') {
          req.response
            ..statusCode = 500
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': {'code': 'gbridge/upstream_error', 'message': 'sessions store locked'}}));
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      ctrl.state = container.read(appProvider).copyWith(
            activeHostId: 'local',
            activeSessionId: 'orig-sess-2',
            sessions: const [ChatSessionItem(id: 'orig-sess-2', title: '原对话 2', group: '今天')],
          );

      final outcome = await ctrl.connectRemoteInput(
        'http://127.0.0.1:${server.port}/?token=testtok&name=NoSessionsMac',
      );
      expect(outcome.connected, isFalse);
      expect(outcome.diagnosis.kind, RemoteDiagnosisKind.realtimeFailed);
      expect(container.read(appProvider).activeHostId, 'local');
      expect(container.read(appProvider).activeSessionId, 'orig-sess-2');
    });

    test('full E2E pairing verifies WS hello pairCode + sessions API, transitions to ready, and commits switch cleanly', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      GrassBagController.allowLoopbackRemoteForTest = true;

      String? receivedHelloPairCode;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        if (req.uri.path == '/' && req.uri.queryParameters['token'] == 'valid-tok') {
          req.response
            ..statusCode = 303
            ..headers.set('set-cookie', 'gbridge-lan-auth-${server.port}=signedok; Path=/; HttpOnly')
            ..headers.set('location', '/');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/gbridge/v1/capabilities') {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(_mockCapabilitiesJson(hostName: 'WorkMac')));
          await req.response.close();
          return;
        }
        if (req.uri.path == '/gbridge/v1/stream' && WebSocketTransformer.isUpgradeRequest(req)) {
          final ws = await WebSocketTransformer.upgrade(req);
          ws.listen((raw) {
            final msg = jsonDecode(raw.toString()) as Map<String, dynamic>;
            if (msg['op'] == 'hello') {
              receivedHelloPairCode = msg['pairCode']?.toString();
              ws.add(jsonEncode({
                'op': 'welcome',
                'v': 1,
                'bootId': 'boot-pair-test-1',
                'currentSeq': 1,
                'resumed': false,
                'replayedCount': 0,
                'heartbeatMs': 30000,
                'pendingInteractions': const [],
              }));
            }
          });
          return;
        }
        if (req.uri.path == '/gbridge/v1/sessions') {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'sessions': [
                {'id': 'mac-s1', 'title': '电脑上的项目', 'updatedAt': 1732000000000},
              ],
            }));
          await req.response.close();
          return;
        }
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': true}));
        await req.response.close();
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      final stages = <PairingStage>[];
      final outcome = await ctrl.connectRemoteInput(
        'grassbag://pair?url=${Uri.encodeComponent('http://127.0.0.1:${server.port}')}&token=valid-tok&name=WorkMac&p=pair9988',
        onStageChanged: (s, {computerName}) => stages.add(s),
      );

      expect(outcome.connected, isTrue);
      expect(outcome.sessionCount, 1);
      expect(receivedHelloPairCode, 'pair9988');
      expect(stages, [
        PairingStage.connecting,
        PairingStage.authorizing,
        PairingStage.openingSession,
        PairingStage.ready,
      ]);
      final after = container.read(appProvider);
      expect(after.activeHost.name, 'WorkMac');
      expect(after.connectionPhase, ConnectionPhase.connected);
      expect(after.sessions.any((s) => s.id == 'mac-s1'), isTrue);
    });

    test('expired pairing code returns pairingCodeExpired without touching active session', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      GrassBagController.allowLoopbackRemoteForTest = true;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        if (req.uri.path == '/' || req.uri.path == '/connect') {
          req.response
            ..statusCode = 401
            ..headers.set('x-gbridge-error', 'gbridge/pairing_code_expired')
            ..write('expired');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/gbridge/v1/capabilities') {
          req.response
            ..statusCode = 401
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': {'code': 'gbridge/unauthorized', 'message': 'unauthorized'}}));
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      final outcome = await ctrl.connectRemoteInput(
        'http://127.0.0.1:${server.port}/?token=valid-tok&p=stale0001',
      );
      expect(outcome.connected, isFalse);
      expect(outcome.diagnosis.kind, RemoteDiagnosisKind.pairingCodeExpired);
      expect(container.read(appProvider).activeHostId, 'local');
    });
  });

  group('Stage 2 & 3: Unified Pairing UI, Single-CTA Failure Recovery, Deep Links & Wi-Fi Cleanup', () {
    testWidgets('first screen shows 3 clear choices, hides empty nearby section, and guides both DSH Desktop and dsh web users', (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _wrap(
          const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: RemoteHostConnectCard(autoScanLan: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 3 actions on screen 1; empty nearby section is hidden!
      expect(find.text('连接电脑'), findsOneWidget);
      expect(find.byKey(const ValueKey('pair-scan-qr-btn')), findsOneWidget);
      expect(find.byKey(const ValueKey('pair-paste-link-btn')), findsOneWidget);
      expect(find.byKey(const ValueKey('pair-prepare-guide-btn')), findsOneWidget);
      expect(find.byKey(const ValueKey('pair-nearby-section')), findsNothing);

      // Preparation guide splits cleanly into "我用 DSH Desktop" and "我已运行 dsh web"
      await tester.tap(find.byKey(const ValueKey('pair-prepare-guide-btn')));
      await tester.pumpAndSettle();
      expect(find.text('我用 DSH Desktop'), findsOneWidget);
      expect(find.text('我已运行 dsh web'), findsOneWidget);
      expect(find.textContaining('插件 → 添加插件 → 手机连接'), findsOneWidget);
      expect(find.byKey(const ValueKey('pair-copy-desktop-guide-btn')), findsOneWidget);

      await tester.tap(find.text('我已运行 dsh web'));
      await tester.pumpAndSettle();
      expect(find.textContaining('启动链接'), findsWidgets);
    });

    testWidgets('failure recovery surfaces single targeted CTA for selfDevice/loopback (no 127.0.0.1 command), expired QR, and realtime failure', (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 1) Self-device / loopback error -> CTA is "换成电脑上的连接链接" with ZERO `--host 127.0.0.1`!
      const loopbackDiag = RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.selfDevice,
        title: '这个地址指向当前设备自己',
        message: '127.0.0.1 指的是这台手机自己，不是你的电脑。请换成电脑上显示的局域网连接链接。',
        normalizedAddress: 'http://127.0.0.1:8769',
        isLoopbackTarget: true,
      );
      await tester.pumpWidget(
        _wrap(
          const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: RemoteHostConnectCard(
                autoScanLan: false,
                initialInput: 'http://127.0.0.1:8769',
                initialDiagnosis: loopbackDiag,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('换成电脑上的连接链接'), findsOneWidget);
      expect(find.textContaining('--host 127.0.0.1'), findsNothing);

      // 2) Expired pairing code -> CTA is "扫描新二维码"
      const expiredDiag = RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.pairingCodeExpired,
        title: '配对二维码已失效',
        message: '电脑可以连通，但当前配对码已过期。',
        normalizedAddress: 'http://192.168.1.42:3081',
      );
      await tester.pumpWidget(
        _wrap(
          const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: RemoteHostConnectCard(
                key: ValueKey('expired-card'),
                autoScanLan: false,
                initialInput: 'http://192.168.1.42:3081',
                initialDiagnosis: expiredDiag,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('扫描新二维码'), findsOneWidget);

      // 3) Preflight OK but realtime WS failed -> CTA is "重新连接"
      const realtimeDiag = RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.realtimeFailed,
        title: '实时连接未能建立',
        message: '已连通电脑，但实时通道未建立，原对话已保留。',
        technicalDetail: 'WebSocketException: HTTP 502',
        normalizedAddress: 'http://192.168.1.42:3081',
      );
      await tester.pumpWidget(
        _wrap(
          const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: RemoteHostConnectCard(
                key: ValueKey('realtime-card'),
                autoScanLan: false,
                initialInput: 'http://192.168.1.42:3081',
                initialDiagnosis: realtimeDiag,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('重新连接'), findsOneWidget);
      expect(find.text('查看技术详情'), findsOneWidget);
    });

    testWidgets('incoming grassbag://pair deep link opens unified pairing sheet showing target computer BEFORE connecting, and Wi-Fi cleanup clears stale LAN hosts', (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      // Verify Wi-Fi network change clears stale discovered LAN hosts immediately
      ctrl.state = container.read(appProvider).copyWith(
            discoveredLanHosts: const [
              DiscoveredLanHost(
                name: 'OldWifiMac',
                address: 'http://192.168.1.50:3085',
                latencyMs: 12,
                isDsh: true,
              ),
            ],
          );
      expect(container.read(appProvider).discoveredLanHosts, isNotEmpty);
      ctrl.clearDiscoveredLanHosts();
      expect(container.read(appProvider).discoveredLanHosts, isEmpty);

      // Render shell, then deliver a `grassbag://pair?...` deep link
      await tester.pumpWidget(_wrap(const GrassBagShell(), container: container));
      await tester.pumpAndSettle();

      ctrl.enqueuePairDeepLink(
        'grassbag://pair?url=${Uri.encodeComponent('http://192.168.1.88:3085')}&token=tok123&name=StudioMac&p=abc12345',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // Opens unified pairing sheet displaying target computer confirmation BEFORE auto-connecting!
      expect(find.byKey(const ValueKey('pair-deeplink-confirm-card')), findsOneWidget);
      expect(find.text('确认连接到「StudioMac」'), findsOneWidget);
      expect(find.text('连接「StudioMac」'), findsOneWidget);
      expect(container.read(appProvider).activeHostId, 'local');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
