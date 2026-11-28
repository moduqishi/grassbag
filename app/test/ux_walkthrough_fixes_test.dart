import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbridge_client/gbridge_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:grassbag/data/grassbag_storage.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/theme/grassbag_glass.dart';
import 'package:grassbag/theme/grassbag_theme.dart';
import 'package:grassbag/ui/common/pending_inbox_sheet.dart';
import 'package:grassbag/ui/common/remote_host_connect_card.dart';
import 'package:grassbag/ui/onboarding/onboarding_page.dart';
import 'package:grassbag/ui/settings/model_config_view.dart';
import 'package:grassbag/ui/settings/settings_page.dart';
import 'package:grassbag/ui/shell/grassbag_shell.dart';

Widget _wrapWithProviders(
  Widget child, {
  ProviderContainer? container,
  Size size = const Size(396, 834),
}) {
  final app = MaterialApp(
    theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
    home: MediaQuery(
      data: MediaQueryData(size: size),
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

  group('UX Walkthrough 1-3: Onboarding guide, failure recovery & input preservation', () {
    testWidgets('guide defaults to zero-plugin dsh web, preserves typed address across Step 2<->3, and avoids bouncing model buttons before host connect', (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _wrapWithProviders(const OnboardingPage(isFirstLaunch: true), container: container),
      );
      await tester.pumpAndSettle();

      // Step 0 -> Step 1
      await tester.tap(find.text('开始配置'));
      await tester.pumpAndSettle();

      // Select remote mode card
      await tester.tap(find.text('连接远程电脑'));
      await tester.pumpAndSettle();

      // Expand preparation guide -> asks whether user is on DSH Desktop or dsh web
      await tester.tap(find.byKey(const ValueKey('pair-prepare-guide-btn')));
      await tester.pumpAndSettle();
      expect(find.text('我用 DSH Desktop'), findsOneWidget);
      expect(find.text('我已运行 dsh web'), findsOneWidget);
      expect(find.text('复制电脑端操作指南链接'), findsOneWidget);
      expect(find.textContaining('dsh plugin add'), findsNothing);
      await tester.tap(find.text('我已运行 dsh web'));
      await tester.pumpAndSettle();
      expect(find.textContaining('启动链接'), findsWidgets);

      // Type a remote address then skip to Step 2
      const typedUrl = 'http://192.168.1.77:8767';
      await tester.enterText(find.byType(CupertinoTextField).first, typedUrl);
      await tester.pump();
      await tester.tap(find.text('稍后配置，继续下一步'));
      await tester.pumpAndSettle();

      // Step 2 when no host is connected MUST NOT show misleading active API Key / DeepSeek bounce buttons!
      expect(find.text('API Key / 中转'), findsNothing);
      expect(find.text('登录 DeepSeek'), findsNothing);
      expect(find.text('先连接主机'), findsOneWidget);
      expect(find.text('先进入首页'), findsOneWidget);

      // Going back via "先连接主机" MUST preserve previously typed remote address!
      await tester.tap(find.text('先连接主机'));
      await tester.pumpAndSettle();
      expect(find.text(typedUrl), findsOneWidget);
    });

    testWidgets('connection failure shows actionable guidance and folds raw exception inside collapsible technical details', (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const diag = RemoteHostDiagnosis(
        kind: RemoteDiagnosisKind.unreachable,
        title: '无法连通目标主机',
        message: '无法连通 http://192.168.1.99:8767。请确认电脑端已运行 dsh web --host <局域网IP> 且同局域网可达。',
        technicalDetail: 'TypeError: Failed to fetch',
        suggestedCommand: 'dsh web --host 192.168.1.99 --port 8767',
      );

      await tester.pumpWidget(
        _wrapWithProviders(
          const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: RemoteHostConnectCard(
                initialInput: 'http://192.168.1.99:8767',
                initialDiagnosis: diag,
                autoScanLan: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('无法连通目标主机'), findsOneWidget);
      expect(find.text('修改地址'), findsOneWidget);
      expect(find.text('查看连接引导'), findsOneWidget);
      // Raw exception is hidden by default until user expands "查看技术详情"
      expect(find.text('TypeError: Failed to fetch'), findsNothing);
      expect(find.text('查看技术详情'), findsOneWidget);

      await tester.tap(find.text('查看技术详情'));
      await tester.pumpAndSettle();
      expect(find.text('TypeError: Failed to fetch'), findsOneWidget);
    });
  });

  group('UX Walkthrough 5-6: Settings host entry, drawer labels & Add Provider sheet', () {
    testWidgets('disconnected Settings promotes Host Management and tapping hero host pill opens Hosts instead of Account', (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _wrapWithProviders(
          SettingsPage(onOpenWebUi: () {}),
          container: container,
        ),
      );
      await tester.pumpAndSettle();

      // Disconnected host promotes "连接与主机" above "DSH 核心设置"
      final hostGroupY = tester.getTopLeft(find.text('连接与主机')).dy;
      final coreGroupY = tester.getTopLeft(find.text('DSH 核心设置')).dy;
      expect(hostGroupY, lessThan(coreGroupY));

      // Tapping the host status pill inside the top card opens Hosts, NOT Account & Balance!
      await tester.tap(find.byKey(const ValueKey('settings-hero-host-pill')));
      await tester.pumpAndSettle();
      expect(find.text('本机与远程主机'), findsWidgets);
      expect(find.text('账号与余额'), findsNothing);
    });

    testWidgets('Add Custom Provider sheet collapses protocol/URL on template pick, has single test button, and keeps Save visible', (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);
      ctrl.state = container.read(appProvider).copyWith(
            connectionPhase: ConnectionPhase.connected,
          );

      await tester.pumpWidget(
        _wrapWithProviders(
          Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showVisualProviderEditorSheet(
                    ctx,
                    providerId: 'custom-relay',
                    settingsNs: 'llm-pi-ai',
                    initialDisplayName: '',
                    initialBaseUrl: '',
                    initialEnvRef: '',
                    isCustomNew: true,
                  ),
                  child: const Text('打开渠道表单'),
                ),
              ),
            ),
          ),
          container: container,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('打开渠道表单'));
      await tester.pumpAndSettle();

      // Only ONE test-connection button (no duplicate "测试连通" pill!)
      expect(find.text('测试连通并拉取模型'), findsOneWidget);
      expect(find.text('测试连通'), findsNothing);
      // Sticky Save button is visible on the first viewport!
      expect(find.text('保存并刷新模型'), findsOneWidget);
      final saveBottomY = tester.getBottomLeft(find.text('保存并刷新模型')).dy;
      expect(saveBottomY, lessThanOrEqualTo(834.0));

      // Picking a template collapses protocol & Base URL into a compact summary
      await tester.tap(find.text('DeepSeek API'));
      await tester.pumpAndSettle();
      expect(find.text('修改地址'), findsOneWidget);
      expect(find.text('保存并刷新模型'), findsOneWidget);
    });
  });

  group('Priority Chat Interactions & Pending Inbox', () {
    testWidgets('home suggestion cards uniformly prefill composer instead of auto-sending', (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);
      ctrl.state = container.read(appProvider).copyWith(
            connectionPhase: ConnectionPhase.connected,
            hosts: [
              container.read(appProvider).localHost.copyWith(online: true, bridged: true),
            ],
            modelGroups: const [
              ModelCatalogGroup(
                id: 'deepseek',
                name: 'DeepSeek',
                models: [
                  ModelCatalogEntry(
                    id: 'deepseek-chat',
                    providerId: 'deepseek',
                    providerName: 'DeepSeek',
                    name: 'DeepSeek Chat',
                  ),
                ],
              ),
            ],
            routableProviders: const ['deepseek'],
            activeModelProvider: 'deepseek',
            activeModelId: 'deepseek-chat',
            modelName: 'DeepSeek Chat',
            modelShort: 'DS',
          );

      await tester.pumpWidget(_wrapWithProviders(const GrassBagShell(), container: container));
      await tester.pumpAndSettle();

      await tester.tap(find.text('看看工作区'));
      await tester.pumpAndSettle();

      // Prompt is prefilled in composer, NOT auto-sent!
      final tf = tester.widget<TextField>(find.byType(TextField));
      expect(tf.controller?.text, contains('目录结构'));
      expect(container.read(appProvider).turns, isEmpty);

      // Flush debounced draft/context persistence timers cleanly before disposal
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    test('long-press send in Plan Mode aborts send and preserves draft when switching plan mode fails', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final prevHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevHttpOverrides);
      GrassBagController.allowLoopbackRemoteForTest = true;

      var promptCalls = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final path = req.uri.path;
        if (path == '/gbridge/v1/capabilities') {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'v': 1,
              'bridgeVersion': '0.2.0',
              'dshVersion': '0.2.2-rc.5',
              'bootId': 'boot-plan-guard',
              'host': {'name': 'MockHost', 'platform': 'darwin', 'arch': 'arm64'},
              'transport': {'wsPath': '/gbridge/v1/stream'},
              'domains': {'chat': {'ok': true}},
              'endpointsCount': 40,
            }));
          await req.response.close();
          return;
        }
        if (path == '/gbridge/v1/sessions/sess-plan/commands') {
          req.response
            ..statusCode = 500
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': {'code': 'plan/error', 'message': 'plan mode unavailable'}}));
          await req.response.close();
          return;
        }
        if (path == '/gbridge/v1/sessions/sess-plan/prompt') {
          promptCalls++;
        }
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'v': 1, 'sessions': [], 'workspaces': [], 'models': {'groups': []}}));
        await req.response.close();
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      final host = ctrl.addRemoteHost(
        'http://127.0.0.1:${server.port}',
        name: 'PlanMock',
        autoProbe: false,
        silent: true,
      )!;
      await ctrl.switchHost(host.id, awaitConnect: true, announce: false);
      ctrl.state = container.read(appProvider).copyWith(
            activeSessionId: 'sess-plan',
            planMode: false,
          );

      // setPlanMode(true) MUST return false and roll back planMode to false on server error!
      final switched = await ctrl.setPlanMode(true);
      expect(switched, isFalse);
      expect(container.read(appProvider).planMode, isFalse);
      expect(promptCalls, 0);
    });

    testWidgets('visible top search button opens scoped search with load-older CTA, and Enter send works after menu dismiss', (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      await tester.pumpWidget(_wrapWithProviders(const GrassBagShell(), container: container));
      await tester.pumpAndSettle();

      const offlineRemote = ManagedHost(
        id: 'rem-search-offline',
        name: '远程主机',
        address: 'http://192.168.1.99:8767',
        isLocal: false,
        online: false,
        bridged: false,
        latency: '--',
      );
      ctrl.state = container.read(appProvider).copyWith(
            activeHostId: offlineRemote.id,
            hosts: [container.read(appProvider).localHost, offlineRemote],
            connectionPhase: ConnectionPhase.disconnected,
            loadingSessions: false,
            activeSessionId: 'sess-search-1',
            sessions: const [
              ChatSessionItem(id: 'sess-search-1', title: '架构讨论', group: '今天'),
            ],
            hasMoreTurns: true,
            turns: const [
              NormalizedTurn(
                turnId: 't1',
                status: 'completed',
                userMessage: NormalizedUserMessage(id: 'u1', text: '介绍一下存储架构'),
                assistantText: '这里使用 SQLite 与 Keystore 双层存储。',
              ),
            ],
          );
      await tester.pumpAndSettle();

      // Mobile top bar exposes visible search button directly!
      final searchBtn = find.byKey(const ValueKey('top-inchat-search-btn'));
      expect(searchBtn, findsOneWidget);

      await tester.tap(searchBtn);
      await tester.pumpAndSettle();

      // Search bar explicitly states loaded scope AND offers "继续查找更早记录" when hasMoreTurns is true
      expect(find.textContaining('已加载的 1 轮'), findsWidgets);
      expect(find.byKey(const ValueKey('inchat-search-load-older-btn')), findsOneWidget);
      expect(find.text('继续查找更早记录'), findsOneWidget);

      // Close search, open drawer to verify labeled footer buttons ('功能', '设置')
      await tester.tap(find.byTooltip('关闭搜索'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('top-left-false')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.text('功能'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);

      // Close drawer by tapping outside, open & dismiss title long-press menu, then verify
      // composer focus and Enter send shortcut still work cleanly!
      await tester.tapAt(const Offset(370, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));

      // Focus composer first, then open title long-press menu -> menu MUST release composer focus
      // so hardware shortcuts never accidentally send while menu is open!
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '回车快捷发送校验');
      await tester.pump();

      final titlePill = find.text('架构讨论');
      await tester.longPress(titlePill);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('大纲'), findsOneWidget);
      final tfDuringMenu = tester.widget<TextField>(find.byType(TextField));
      expect(tfDuringMenu.focusNode?.hasFocus, isFalse);

      // Pressing Ctrl+Enter while menu is open MUST NOT submit behind the overlay!
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byKey(const ValueKey('composer-offline-unsent-strip')), findsNothing);

      // Dismiss long-press menu via backdrop tap, refocus composer, and Ctrl+Enter sends cleanly!
      await tester.tapAt(const Offset(20, 700));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('大纲'), findsNothing);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final tfAfterMenu = tester.widget<TextField>(find.byType(TextField));
      expect(tfAfterMenu.focusNode?.hasFocus, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const ValueKey('composer-offline-unsent-strip')), findsOneWidget);
      expect(tfAfterMenu.controller?.text, '回车快捷发送校验');

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Pending Inbox consolidates pending approvals, questions, failed jobs, and unsent drafts', (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      ctrl.state = container.read(appProvider).copyWith(
            sessions: const [
              ChatSessionItem(id: 'sess-a', title: '部署脚本', group: '今天'),
              ChatSessionItem(id: 'sess-b', title: '需求澄清', group: '今天'),
            ],
            pendingInteractions: const [
              PendingInteraction(
                id: 'int-appr-1',
                kind: 'approval',
                sessionId: 'sess-a',
                payload: {'toolName': 'bash', 'command': 'npm run build'},
              ),
              PendingInteraction(
                id: 'int-q-1',
                kind: 'user_questions',
                sessionId: 'sess-b',
                payload: {
                  'questions': [
                    {'id': 'q1', 'question': '是否启用暗色默认主题？'},
                  ],
                },
              ),
            ],
            jobs: const [
              BackgroundJobRecord(
                id: 'job-fail-1',
                command: 'pytest tests/integration',
                cwd: '/workspace',
                status: 'failed',
                startedAtLabel: '刚刚',
                outputLines: ['AssertionError'],
              ),
            ],
            pendingOutbox: const [
              PendingOutboxItem(
                id: 'out-1',
                hostId: 'local',
                sessionId: '',
                text: '帮我总结今天的提交记录',
                status: 'unsent',
              ),
            ],
          );

      expect(container.read(appProvider).pendingInboxCount, 4);

      await tester.pumpWidget(
        _wrapWithProviders(
          Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: Consumer(
                  builder: (c, ref, _) => ElevatedButton(
                    onPressed: () => showPendingInboxSheet(c, ref),
                    child: const Text('打开收件箱'),
                  ),
                ),
              ),
            ),
          ),
          container: container,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('打开收件箱'));
      await tester.pumpAndSettle();

      expect(find.text('待处理收件箱'), findsOneWidget);
      expect(find.text('待审批操作'), findsOneWidget);
      expect(find.text('npm run build'), findsOneWidget);
      expect(find.text('待回答提问'), findsOneWidget);
      expect(find.text('是否启用暗色默认主题？'), findsOneWidget);
      expect(find.text('失败的后台任务'), findsOneWidget);
      expect(find.text('pytest tests/integration'), findsOneWidget);
      expect(find.text('未发送消息'), findsOneWidget);
      expect(find.text('帮我总结今天的提交记录'), findsOneWidget);
    });
  });
}
