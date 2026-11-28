import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/theme/grassbag_theme.dart';
import 'package:grassbag/ui/onboarding/launch_splash_overlay.dart';
import 'package:grassbag/ui/onboarding/onboarding_page.dart';
import 'package:grassbag/ui/shell/grassbag_shell.dart';

void main() {
  testWidgets('GrassBagAnimatedLogo assembles cleanly through full timeline without errors',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
        home: const Scaffold(
          body: Center(
            child: GrassBagAnimatedLogo(
              size: 120,
              duration: Duration(milliseconds: 800),
            ),
          ),
        ),
      ),
    );
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Luxury 3-step OnboardingPage flows smoothly across all 3 pages and completes',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(appProvider.notifier).setGlassTier(GrassBagGlassTier.solid);

    var finished = false;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
          home: OnboardingPage(
            isFirstLaunch: true,
            onFinished: () => finished = true,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('欢迎使用 GrassBag'), findsOneWidget);
    expect(find.text('开始配置'), findsOneWidget);

    // Step 1 -> Step 2 (Mode selection)
    await tester.tap(find.text('开始配置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('选择你的运行方式'), findsOneWidget);
    expect(find.text('连接远程电脑'), findsOneWidget);

    // Toggle Remote mode and confirm unified "连接电脑" pairing card is visible
    await tester.tap(find.text('连接远程电脑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('pair-link-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('pair-prepare-guide-btn')), findsOneWidget);

    // Step 2 -> Step 3 (When host is not connected yet, shows honest "先连接主机" + "先进入首页" instead of bouncing model buttons!)
    await tester.tap(find.textContaining('下一步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('先连接主机'), findsOneWidget);
    expect(find.text('先进入首页'), findsOneWidget);
    expect(find.text('登录 DeepSeek'), findsNothing);

    // Finish onboarding cleanly via "先进入首页"
    await tester.tap(find.text('先进入首页'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(finished, isTrue);
    expect(container.read(appProvider).onboardingCompleted, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('GrassBagAppGate shows onboarding on first launch and kinetic logo splash on returning launch',
      (tester) async {
    // 1) First-launch state -> brief logo emblem beat, then transitions to OnboardingPage(isFirstLaunch: true)
    final firstContainer = ProviderContainer();
    addTearDown(firstContainer.dispose);
    firstContainer.read(appProvider.notifier).setGlassTier(GrassBagGlassTier.solid);
    firstContainer.read(appProvider.notifier).state =
        firstContainer.read(appProvider).copyWith(onboardingCompleted: false);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: firstContainer,
        child: MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
          home: const GrassBagAppGate(),
        ),
      ),
    );
    // Advance past post-frame start + logo assembly (1280ms) + brief hold (260ms) + dissolve (400ms)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump(const Duration(milliseconds: 460));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(OnboardingPage), findsOneWidget);
    expect(find.text('欢迎使用 GrassBag'), findsOneWidget);

    // Skip completes onboarding and reveals GrassBagShell
    await tester.tap(find.text('跳过'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(firstContainer.read(appProvider).onboardingCompleted, isTrue);
    expect(find.byType(GrassBagShell), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));

    // 2) Subsequent-launch state -> shows kinetic splash overlay (NOT OnboardingPage), then dissolves
    final returnContainer = ProviderContainer();
    addTearDown(returnContainer.dispose);
    returnContainer.read(appProvider.notifier).setGlassTier(GrassBagGlassTier.solid);
    returnContainer.read(appProvider.notifier).completeOnboarding();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: returnContainer,
        child: MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
          home: const GrassBagAppGate(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.byType(OnboardingPage), findsNothing);
    expect(find.byType(GrassBagAnimatedLogo), findsOneWidget);
    // GrassBagShell stays deferred while kinetic logo assembles at 120fps
    expect(find.byType(GrassBagShell), findsNothing);

    // Once logo finishes assembling, GrassBagShell mounts underneath, then splash dissolves
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.byType(GrassBagShell), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(GrassBagAnimatedLogo), findsNothing);
    expect(find.byType(GrassBagShell), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  test('Remote connect preserves minted cookie for single-use token and never marks 401 :3081 as bridged',
      () async {
    final prevHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevHttpOverrides);

    var tokenRedeemCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((req) async {
      final path = req.uri.path;
      // Single-use launch token -> 30-day session cookie (burns on first exchange!)
      if (path == '/' && req.uri.queryParameters['token'] == 'one-time-tok-2026') {
        tokenRedeemCount++;
        if (tokenRedeemCount == 1) {
          req.response.statusCode = 303;
          req.response.headers.set('location', './');
          req.response.headers.add(
            'set-cookie',
            'dsh-auth-once=v1.freshcookie; Path=/; HttpOnly',
          );
        } else {
          req.response.statusCode = 401;
          req.response.write('token already consumed');
        }
        await req.response.close();
        return;
      }
      if (path.startsWith('/gbridge/v1')) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final cookie = req.headers.value(HttpHeaders.cookieHeader) ?? '';
      if (!cookie.contains('dsh-auth-once=v1.freshcookie')) {
        req.response.statusCode = 401;
        req.response.write('auth required');
        await req.response.close();
        return;
      }
      if (path == '/api/remote.mux' && WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((_) {});
        return;
      }
      if (path == '/api/session/list') {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'result': {'sessions': const []}}));
        await req.response.close();
        return;
      }
      if (path == '/api/workspace/list') {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'result': {'workspaces': const []}}));
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'result': const <String, dynamic>{}}));
      await req.response.close();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final ctrl = container.read(appProvider.notifier);

    // 1) Production guard rejects loopback 127.0.0.1 as selfDevice before test override is enabled
    final loopbackDiag =
        await ctrl.diagnoseRemoteHost('http://127.0.0.1:${server.port}/?token=one-time-tok-2026');
    expect(loopbackDiag.kind, RemoteDiagnosisKind.selfDevice);
    expect(tokenRedeemCount, 0);

    // 2) Enable test loopback hook and genuinely exercise single-use token -> cookie exchange!
    GrassBagController.allowLoopbackRemoteForTest = true;
    addTearDown(() => GrassBagController.allowLoopbackRemoteForTest = false);

    final outcome = await ctrl.connectRemoteInput(
      'http://127.0.0.1:${server.port}/?token=one-time-tok-2026',
      name: 'Loopback Vanilla Host',
    );
    expect(tokenRedeemCount, 1, reason: 'Single-use launch token must only be exchanged once');
    expect(outcome.connected, isTrue);
    expect(outcome.diagnosis.kind, RemoteDiagnosisKind.readyDirect);
    expect(outcome.diagnosis.capturedCookie, contains('dsh-auth-once=v1.freshcookie'));
    expect(outcome.host, isNotNull);
    expect(outcome.host!.hasSavedCookie, isTrue);

    // 3) Spin up a mock Desktop LAN Bridge returning HTTP 401 on /gbridge/v1/capabilities
    //    and verify diagnoseRemoteHost / connectRemoteInput NEVER marks 401 as bridged or online!
    final bridge401Server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => bridge401Server.close(force: true));
    bridge401Server.listen((req) async {
      if (req.uri.path == '/plugins/events') {
        req.response.statusCode = 200;
        req.response.headers.set('content-type', 'text/event-stream; charset=utf-8');
        req.response.write(
          'data: ${jsonEncode({"graph": {"release": {"version": "0.2.2-rc.5"}}, "surface": "desktop", "hasGbridge": true, "requiresAuth": true})}\n\n',
        );
        await req.response.close();
        return;
      }
      req.response.statusCode = 401;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'error': {'code': 'gbridge/unauthorized', 'message': 'invalid token'},
      }));
      await req.response.close();
    });

    final diag401 = await ctrl.diagnoseRemoteHost(
      'http://127.0.0.1:${bridge401Server.port}/?token=wrong-token',
    );
    expect(diag401.kind, RemoteDiagnosisKind.needsAuth);
    final outcome401 = await ctrl.connectRemoteInput(
      'http://127.0.0.1:${bridge401Server.port}/?token=wrong-token',
      saveIfNeedsAuth: true,
    );
    expect(outcome401.connected, isFalse);
    expect(outcome401.host, isNotNull);
    expect(outcome401.host!.bridged, isFalse);
    expect(outcome401.host!.online, isFalse);

    // 4) Verify updateHostToken clears stale cookie & updates DHCP address when given a full URL
    final added = ctrl.addRemoteHost(
      'http://192.168.10.10:3080',
      name: 'Office Mac',
      cookie: 'stale-old-cookie',
      autoProbe: false,
      silent: true,
    );
    expect(added, isNotNull);
    expect(added!.hasSavedCookie, isTrue);

    await ctrl.updateHostToken(
      added.id,
      'dsh web: http://192.168.10.42:3080/?token=fresh_dhcp_tok',
      awaitConnect: false,
    );
    final updated = container.read(appProvider).hosts.firstWhere((h) => h.id == added.id);
    expect(updated.address, 'http://192.168.10.42:3080');
    expect(updated.token, 'fresh_dhcp_tok');
    expect(updated.hasSavedCookie, isFalse);

    // 5) Verify ManagedHost.isDesktopLanBridge detection
    final bridgeHost = ManagedHost(
      id: 'rem-bridge',
      isLocal: false,
      name: 'Desktop Bridge',
      address: 'http://192.168.1.20:3081',
      latency: '--',
      online: false,
      bridged: false,
    );
    expect(bridgeHost.isDesktopLanBridge, isTrue);
    expect(updated.isDesktopLanBridge, isFalse);
  });
}
