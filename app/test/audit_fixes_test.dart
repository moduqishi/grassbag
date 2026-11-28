import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:grassbag/data/grassbag_storage.dart';
import 'package:grassbag/services/app_update_service.dart';
import 'package:grassbag/services/app_update_transport.dart';
import 'package:grassbag/services/native_bridge.dart';
import 'package:grassbag/services/sha256_util.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/ui/onboarding/launch_splash_overlay.dart';

void main() {
  group('P1.1: Emergency stop targets only phone-control local sessions', () {
    test('emergency stop on remote host or unrelated local session does not cancel active UI stream', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      // 1) Active on a remote host while streaming -> triggering phone emergency stop MUST NOT cancel remote stream!
      final remote = ctrl.addRemoteHost(
        'http://192.168.50.88:3080',
        name: 'Remote Mac',
        token: 'tok-rem',
        autoProbe: false,
        silent: true,
      )!;
      await ctrl.switchHost(remote.id, announce: false);
      ctrl.state = container.read(appProvider).copyWith(
            activeSessionId: 'remote-session-1',
            isStreaming: true,
            phoneLiveActive: true,
          );

      await ctrl.triggerEmergencyStop();
      expect(container.read(appProvider).emergencyStopped, isTrue);
      expect(container.read(appProvider).phoneLiveActive, isFalse);
      expect(
        container.read(appProvider).isStreaming,
        isTrue,
        reason: 'Emergency stop for local Android phone control must never cancel a remote host chat',
      );
    });
  });

  group('P1.4: FGS ownership during Android auto-recovery', () {
    test('treats engineState=starting as native-owned so Flutter never stops FGS mid-recovery', () {
      const recovering = GrassBagAppState(
        nativeRuntimeStatus: NativeRuntimeStatus(
          initialized: true,
          engineState: 'starting',
          engineRunning: false,
          bootstrapActive: false,
        ),
      );
      final plan = GrassBagController.computeAndroidKeepalivePlan(
        recovering,
        runningSessionsCount: 0,
      );
      expect(plan.managedByBootstrap, isTrue);
      expect(plan.shouldRun, isTrue);
      expect(plan.needsWakeLock, isTrue);
    });
  });

  group('P2.2: job.event nested status extraction', () {
    test('extracts terminal status from raw.job.status and top-level status/state', () {
      expect(
        GrassBagController.extractJobEventStatus({
          'jobId': 'j1',
          'raw': {
            'type': 'state',
            'job': {'id': 'j1', 'status': 'completed', 'exitCode': 0},
          },
        }),
        'completed',
      );
      expect(
        GrassBagController.extractJobEventStatus({
          'jobId': 'j2',
          'raw': {
            'info': {'state': 'failed'},
          },
        }),
        'failed',
      );
      expect(
        GrassBagController.extractJobEventStatus({'status': 'killed'}),
        'killed',
      );
      expect(GrassBagController.isTerminalJobStatus('completed'), isTrue);
      expect(GrassBagController.isTerminalJobStatus('failed'), isTrue);
      expect(GrassBagController.isTerminalJobStatus('exited'), isTrue);
      expect(GrassBagController.isTerminalJobStatus('running'), isFalse);
    });
  });

  group('P2.3: Reconnect attachment preservation, origin isolation & parentSessionId reset', () {
    test('preserves unsent attachments on same-host token update, isolates across URL change, and clears parentSessionId on switchHost', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      final host = ctrl.addRemoteHost(
        'http://192.168.50.10:3080',
        name: 'Lab Host',
        token: 'tok-v1',
        autoProbe: false,
        silent: true,
      )!;
      await ctrl.switchHost(host.id, announce: false);

      // Attach a pending draft file on the active host
      ctrl.addPendingAttachment(
        ComposerAttachment(
          id: 'att-1',
          name: 'spec.txt',
          mimeType: 'text/plain',
          sizeBytes: 5,
          bytes: Uint8List.fromList([1, 2, 3, 4, 5]),
        ),
      );
      expect(container.read(appProvider).pendingAttachments.length, 1);

      // 1) Updating token on the SAME host address preserves pending attachments across reconnect
      await ctrl.updateHostToken(host.id, 'tok-v2', awaitConnect: false);
      expect(container.read(appProvider).pendingAttachments.length, 1);
      expect(container.read(appProvider).pendingAttachments.first.id, 'att-1');

      // 2) Changing the same host entry's URL to a DIFFERENT address MUST NOT carry over old attachments
      await ctrl.updateHostDetails(host.id, address: 'http://192.168.50.99:3080');
      expect(container.read(appProvider).pendingAttachments, isEmpty);

      // 3) Switching hosts clears subagent parentSessionId so Back never queries old parent on new host
      ctrl.state = container.read(appProvider).copyWith(
            parentSessionId: 'old-host-parent-sid',
            parentSessionTitle: 'Old Parent',
          );
      expect(container.read(appProvider).parentSessionId, 'old-host-parent-sid');
      await ctrl.switchHost('local', announce: false);
      expect(container.read(appProvider).parentSessionId, isNull);
    });
  });

  group('P2.4: Splash readiness on valid empty config & monotonic hold timer', () {
    test('settles immediately when initialDomainsHydrated=true even with empty models/namespaces/account', () {
      const emptyReady = GrassBagAppState(
        nativeStatusHydrated: true,
        connectionPhase: ConnectionPhase.connected,
        hydratingDomains: false,
        loadingSessions: false,
        initialDomainsHydrated: true,
        dshNamespaces: [],
        modelGroups: [],
        nativeRuntimeStatus: NativeRuntimeStatus(
          initialized: true,
          engineState: 'running',
          engineRunning: true,
        ),
      );
      expect(
        GrassBagAppGate.isStartupHydrationSettled(emptyReady, isAndroidOverride: true),
        isTrue,
      );

      // Hold timer subtraction never resets elapsed wait when changing tiers
      expect(
        GrassBagAppGate.computeRemainingHoldDuration(
          const Duration(seconds: 20),
          const Duration(seconds: 3),
        ),
        const Duration(seconds: 17),
      );
      expect(
        GrassBagAppGate.computeRemainingHoldDuration(
          const Duration(milliseconds: 3600),
          const Duration(seconds: 5),
        ),
        Duration.zero,
      );
    });
  });

  group('P2.5: Permissions refresh preserves emergencyStopped when safety query fails', () {
    test('null safety snapshot does not overwrite emergencyStopped=true with false', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      ctrl.state = container.read(appProvider).copyWith(emergencyStopped: true);
      ctrl.applyPermissionsAndSafetySnapshotForTest(
        const NativePermissionsStatus(overlayGranted: true),
        null,
      );
      expect(container.read(appProvider).emergencyStopped, isTrue);

      // Explicit false from a healthy safety snapshot DOES clear it
      ctrl.applyPermissionsAndSafetySnapshotForTest(
        const NativePermissionsStatus(overlayGranted: true),
        const {'emergencyStopped': false},
      );
      expect(container.read(appProvider).emergencyStopped, isFalse);
    });
  });

  group('P2.6: Web token-only saved host credential persistence across reload', () {
    test('persists and restores host_token via Web storage fallback', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      GrassBagStorage.instance.resetCacheForTest();
      GrassBagNativeBridge.useWebSecretFallbackForTest = true;
      addTearDown(() {
        GrassBagNativeBridge.useWebSecretFallbackForTest = false;
        GrassBagStorage.instance.resetCacheForTest();
      });

      await GrassBagNativeBridge.instance.putSecret('host_token_rem-1', 'web-token-xyz');
      // Simulate page reload by clearing in-memory SharedPreferences handle
      GrassBagStorage.instance.resetCacheForTest();
      final restored = await GrassBagNativeBridge.instance.getSecret('host_token_rem-1');
      expect(restored, 'web-token-xyz');

      await GrassBagNativeBridge.instance.deleteSecret('host_token_rem-1');
      expect(await GrassBagNativeBridge.instance.getSecret('host_token_rem-1'), isNull);
    });
  });

  group('P2.7: In-app update SHA-256 verification & trusted checksum source', () {
    test('StreamingSha256 matches FIPS 180-4 test vectors', () {
      expect(
        sha256HexBytes(utf8.encode('')),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        sha256HexBytes(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      final stream = StreamingSha256()
        ..add(utf8.encode('abcdbcdecdefdefgefghfghighijhijk'))
        ..add(utf8.encode('ijkljklmklmnlmnomnopnopq'));
      expect(
        stream.digestHex(),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('resolveExpectedApkSha256 prioritizes direct GitHub first and rejects tampered APK bytes', () async {
      final prevHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevHttpOverrides);

      final goodApkBytes = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, ...utf8.encode('good-apk-payload')]);
      final badApkBytes = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, ...utf8.encode('evil-apk-payload')]);
      final goodSha = sha256HexBytes(goodApkBytes);

      final release = AppReleaseInfo.fromGitHubReleaseJson({
        'tag_name': 'v0.3.0',
        'name': 'v0.3.0',
        'body': 'APK SHA-256: `$goodSha` (grassbag-v0.3.0+15-arm64-v8a.apk)',
        'html_url': 'https://github.com/moduqishi/grassbag/releases/tag/v0.3.0',
        'assets': [
          {
            'name': 'grassbag-v0.3.0+15-arm64-v8a.apk',
            'size': goodApkBytes.length,
            'browser_download_url':
                'https://github.com/moduqishi/grassbag/releases/download/v0.3.0/grassbag-v0.3.0+15-arm64-v8a.apk',
          },
          {
            'name': 'SHA256SUMS.txt',
            'size': 128,
            'browser_download_url':
                'https://github.com/moduqishi/grassbag/releases/download/v0.3.0/SHA256SUMS.txt',
          },
        ],
      })!;

      final fetchedChecksumsFrom = <String>[];
      final svc = AppUpdateService(
        fetcher: (uri, {timeout = const Duration(seconds: 12)}) async {
          fetchedChecksumsFrom.add(uri.toString());
          return AppUpdateHttpResponse(
            statusCode: 200,
            body: '$goodSha  grassbag-v0.3.0+15-arm64-v8a.apk\n',
          );
        },
      );
      final resolvedSha = await svc.resolveExpectedApkSha256(release);
      expect(resolvedSha, goodSha);
      expect(
        fetchedChecksumsFrom.first,
        'https://github.com/moduqishi/grassbag/releases/download/v0.3.0/SHA256SUMS.txt',
        reason: 'Must query direct GitHub before any mirror for checksum manifest',
      );

      // Verify downloadAppUpdateApk rejects tampered bytes with wrong SHA-256 and accepts valid bytes
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.statusCode = 200;
        final payload = req.uri.path == '/tampered.apk' ? badApkBytes : goodApkBytes;
        req.response.contentLength = payload.length;
        req.response.add(payload);
        await req.response.close();
      });

      final tmpDir = await Directory.systemTemp.createTemp('grassbag-apk-sha-test-');
      addTearDown(() => tmpDir.delete(recursive: true));

      await expectLater(
        downloadAppUpdateApk(
          Uri.parse('http://127.0.0.1:${server.port}/tampered.apk'),
          '${tmpDir.path}/tampered.apk',
          expectedSizeBytes: goodApkBytes.length,
          expectedSha256: goodSha,
        ),
        throwsA(isA<HttpException>()),
      );
      expect(await File('${tmpDir.path}/tampered.apk').exists(), isFalse);

      final saved = await downloadAppUpdateApk(
        Uri.parse('http://127.0.0.1:${server.port}/good.apk'),
        '${tmpDir.path}/good.apk',
        expectedSizeBytes: goodApkBytes.length,
        expectedSha256: goodSha,
      );
      expect(await File(saved).exists(), isTrue);
    });
  });

  group('Audit Pass 2: P1-1, P1-4, B-2, and C-2 regressions', () {
    test('P1-1: offline sendPrompt returns false so draft is preserved and records persisted outbox entry', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      GrassBagStorage.instance.resetCacheForTest();
      addTearDown(GrassBagStorage.instance.resetCacheForTest);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      final sent = await ctrl.sendPrompt('离线待确认消息');
      expect(sent, isFalse, reason: 'Offline send must return false so composer preserves draft');
      final outbox = await GrassBagStorage.instance.loadPendingOutbox();
      expect(outbox.any((e) => e['text'] == '离线待确认消息'), isTrue);
    });

    test('P1-4: public cleartext http:// diagnosis fails closed before transmitting credentials', () async {
      expect(GrassBagController.isPublicCleartextHttpUri(Uri.parse('http://example.com:3080')), isTrue);
      expect(GrassBagController.isPublicCleartextHttpUri(Uri.parse('https://example.com:3080')), isFalse);
      expect(GrassBagController.isPublicCleartextHttpUri(Uri.parse('http://192.168.1.50:3080')), isFalse);
      expect(GrassBagController.isPublicCleartextHttpUri(Uri.parse('http://100.64.0.9:3080')), isFalse);
      expect(GrassBagController.isPublicCleartextHttpUri(Uri.parse('http://127.0.0.1:3080')), isFalse);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      final diag = await ctrl.diagnoseRemoteHost(
        'http://public.example.com:3080',
        token: 'super-secret-token',
      );
      expect(diag.kind, RemoteDiagnosisKind.insecurePublicHttp);
      expect(diag.canConnectNow, isFalse);
    });

    test('B-2: importConfigJson merges hosts by default and previewImportConfigJson reports accurate diff', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      final existing = ctrl.addRemoteHost(
        'http://192.168.50.10:3080',
        name: 'Office Mac',
        token: 'tok-office',
        autoProbe: false,
        silent: true,
      )!;
      final incomingSnapshot = jsonEncode({
        'prefs': {'isDark': true},
        'hosts': [
          {
            'id': 'remote-new-1',
            'isLocal': false,
            'name': 'Lab Linux',
            'address': 'http://192.168.50.20:3080',
          },
        ],
      });

      final preview = ctrl.previewImportConfigJson(incomingSnapshot);
      expect(preview, isNotNull);
      expect(preview!['addedHosts'], 1);
      expect(preview['updatedHosts'], 0);
      expect(preview['preservedExistingHosts'], 1);

      expect(ctrl.importConfigJson(incomingSnapshot), isTrue);
      final afterMerge = container.read(appProvider).hosts;
      expect(afterMerge.any((h) => h.id == existing.id && h.token == 'tok-office'), isTrue);
      expect(afterMerge.any((h) => h.id == 'remote-new-1'), isTrue);

      // Explicit replaceHosts: true removes unlisted remote hosts when local host is included
      final replaceSnapshot = jsonEncode({
        'hosts': [
          {'id': 'local', 'isLocal': true, 'name': '本机', 'address': 'unix:///tmp/local.sock'},
          {'id': 'remote-only', 'isLocal': false, 'name': 'Only Box', 'address': 'http://192.168.50.30:3080'},
        ],
      });
      expect(ctrl.importConfigJson(replaceSnapshot, replaceHosts: true), isTrue);
      final afterReplace = container.read(appProvider).hosts;
      expect(afterReplace.any((h) => h.id == existing.id), isFalse);
      expect(afterReplace.any((h) => h.id == 'remote-only'), isTrue);
    });

    test('C-2: handleNotificationOpened routes across host/session and opens JobsPage for job alerts', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      final remote = ctrl.addRemoteHost(
        'http://192.168.50.42:3080',
        name: 'Build Box',
        token: 'tok-build',
        autoProbe: false,
        silent: true,
      )!;
      expect(container.read(appProvider).activeHostId, 'local');

      // 1) Job notification switches host and signals JobsPage
      final prevJobSignal = container.read(appProvider).openJobsSignal;
      await ctrl.handleNotificationOpened({
        'kind': 'job',
        'hostId': remote.id,
        'jobId': 'job-99',
      });
      expect(container.read(appProvider).activeHostId, remote.id);
      expect(container.read(appProvider).openJobsSignal, prevJobSignal + 1);

      // 2) Same-host interaction notification selects target session
      ctrl.state = container.read(appProvider).copyWith(
        sessions: const [
          ChatSessionItem(id: 'sess-1', title: 'One', group: '今天'),
          ChatSessionItem(id: 'sess-2', title: 'Two', group: '今天'),
        ],
        activeSessionId: 'sess-1',
      );
      await ctrl.handleNotificationOpened({
        'kind': 'interaction',
        'hostId': remote.id,
        'sessionId': 'sess-2',
        'interactionId': 'int-42',
      });
      expect(container.read(appProvider).activeSessionId, 'sess-2');
    });
  });
}
