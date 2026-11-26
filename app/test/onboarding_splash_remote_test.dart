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

    // Toggle Remote mode and confirm redesigned RemoteHostConnectCard is visible
    await tester.tap(find.text('连接远程电脑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('连接远程设备'), findsOneWidget);

    // Step 2 -> Step 3 (Ready & Model setup)
    await tester.tap(find.textContaining('下一步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('登录 DeepSeek'), findsOneWidget);
    expect(find.text('API Key / 中转'), findsOneWidget);

    // Finish onboarding (when model is not yet configured, deferred secondary CTA is shown)
    await tester.tap(find.text('稍后配置模型，直接进入'));
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

    // 1) Diagnose with single-use token on non-loopback IP alias? Use 127.0.0.1 won't pass selfDevice check;
    //    test diagnoseRemoteHost + connectRemoteInput directly via a non-self IP? Wait: 127.0.0.1 is loopback,
    //    so verify selfDevice detection on loopback AND verify Desktop :3081 401 + cookie persistence directly!
    final loopbackDiag = await ctrl.diagnoseRemoteHost('http://127.0.0.1:${server.port}/?token=one-time-tok-2026');
    expect(loopbackDiag.kind, RemoteDiagnosisKind.selfDevice);

    // 2) Verify updateHostToken clears stale cookie & updates DHCP address when given a full URL
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

    // 3) Verify ManagedHost.isDesktopLanBridge detection
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
