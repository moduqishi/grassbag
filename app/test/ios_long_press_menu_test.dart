import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbridge_client/gbridge_client.dart';
import 'package:grassbag/data/grassbag_storage.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/theme/grassbag_glass.dart';
import 'package:grassbag/theme/grassbag_theme.dart';
import 'package:grassbag/ui/chat/composer_bar.dart';
import 'package:grassbag/ui/settings/settings_page.dart';
import 'package:grassbag/ui/shell/grassbag_shell.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealLoopbackHttpOverrides extends HttpOverrides {}

class _FakeLongPressDshServer {
  late final HttpServer server;
  final List<Map<String, dynamic>> selectModelPayloads = [];
  String activeEffort = 'high';
  int defaultModelRev = 2;

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> close() async {
    await server.close(force: true);
  }

  Future<void> _sendJson(HttpResponse res, int status, Object body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final method = req.method.toUpperCase();

    if (path == '/gbridge/v1/stream') {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.add(jsonEncode({
        'type': 'welcome',
        'serverVersion': '0.2.0',
        'dshVersion': '0.2.2-rc.5',
        'seq': 1,
      }));
      ws.listen((_) {}, onError: (_) {});
      return;
    }

    if (path == '/gbridge/v1/connect' && method == 'POST') {
      await _sendJson(req.response, 200, {'ok': true, 'token': 'test-token'});
      return;
    }
    if (path == '/gbridge/v1/capabilities') {
      await _sendJson(req.response, 200, {
        'v': 1,
        'dshVersion': '0.2.2-rc.5',
        'bridgeVersion': '0.2.0',
        'endpoints': ['session/list', 'session/selectModel', 'settings/describe', 'settings/mutate'],
      });
      return;
    }
    if (path == '/gbridge/v1/sessions') {
      await _sendJson(req.response, 200, {
        'v': 1,
        'sessions': [
          {
            'sessionId': 'sess-lp-1',
            'title': '长按交互测试',
            'cwd': '/root/workspace',
            'updatedAt': '2026-11-28T01:00:00.000Z',
          },
        ],
      });
      return;
    }
    if (path == '/gbridge/v1/workspaces') {
      await _sendJson(req.response, 200, {
        'v': 1,
        'workspaces': [
          {'id': 'ws-1', 'name': 'workspace', 'path': '/root/workspace'},
          {'id': 'ws-2', 'name': 'grassbag', 'path': '/root/grassbag'},
        ],
      });
      return;
    }
    if (path == '/gbridge/v1/models') {
      await _sendJson(req.response, 200, {
        'v': 1,
        'routableProviders': ['deepseek'],
        'groups': [
          {
            'id': 'deepseek',
            'name': '官方直连',
            'routable': true,
            'models': [
              {
                'id': 'deepseek-v4',
                'name': 'DeepSeek-V4.1',
                'provider': 'deepseek',
                'providerName': '官方直连',
                'reasoning': {
                  'defaultEffort': 'high',
                  'efforts': [
                    {'id': 'off', 'name': 'Off'},
                    {'id': 'low', 'name': 'Low'},
                    {'id': 'medium', 'name': 'Medium'},
                    {'id': 'high', 'name': 'High'},
                    {'id': 'xhigh', 'name': 'Xhigh'},
                  ],
                },
              },
              {
                'id': 'deepseek-chat',
                'name': 'DeepSeek-Chat',
                'provider': 'deepseek',
                'providerName': '官方直连',
              },
            ],
          },
        ],
      });
      return;
    }
    if (path == '/gbridge/v1/sessions/sess-lp-1/model' && method == 'PUT') {
      final raw = await utf8.decoder.bind(req).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;
      selectModelPayloads.add(body);
      if (body['reasoningEffort'] != null) {
        activeEffort = body['reasoningEffort'].toString();
      }
      defaultModelRev++;
      await _sendJson(req.response, 200, {
        'v': 1,
        'result': {'selected': body},
      });
      return;
    }
    if (path == '/gbridge/v1/settings' && method == 'GET') {
      await _sendJson(req.response, 200, {
        'v': 1,
        'namespaces': [
          {
            'ns': 'agent-default-model',
            'revision': defaultModelRev,
            'value': {
              'provider': 'deepseek',
              'model': 'deepseek-v4',
              'reasoningEffort': activeEffort,
            },
          },
        ],
      });
      return;
    }
    if (path == '/gbridge/v1/settings' && method == 'PATCH') {
      final raw = await utf8.decoder.bind(req).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;
      selectModelPayloads.add(body);
      defaultModelRev++;
      await _sendJson(req.response, 200, {
        'v': 1,
        'result': {'revision': defaultModelRev},
      });
      return;
    }
    await _sendJson(req.response, 200, {'ok': true, 'v': 1});
  }
}

Future<ProviderContainer> _seedConnectedModelContainer(
  WidgetTester tester,
  _FakeLongPressDshServer fake,
) async {
  final container = ProviderContainer();
  final ctrl = container.read(appProvider.notifier);
  ctrl.state = ctrl.state.copyWith(
    hosts: [
      ctrl.state.localHost.copyWith(
        address: fake.baseUrl,
        token: 'test-token',
      ),
    ],
    glassTier: GrassBagGlassTier.frosted,
  );
  await tester.runAsync(() async {
    await ctrl.switchHost(ctrl.state.localHost.id, savePreviousContext: false);
    for (var i = 0; i < 40 && ctrl.state.connectionPhase != ConnectionPhase.connected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  });
  ctrl.state = ctrl.state.copyWith(
    connectionPhase: ConnectionPhase.connected,
    activeSessionId: 'sess-lp-1',
    sessions: const [
      ChatSessionItem(
        id: 'sess-lp-1',
        title: '长按交互测试',
        group: '今天',
        workspaceId: 'ws-1',
        workspaceName: 'workspace',
        cwd: '/root/workspace',
      ),
    ],
    workspaces: const [
      WorkspaceItem(id: 'ws-1', name: 'workspace', path: '/root/workspace'),
      WorkspaceItem(id: 'ws-2', name: 'grassbag', path: '/root/grassbag'),
    ],
    activeWorkspace: 'ws-1',
    activeModelProvider: 'deepseek',
    activeModelId: 'deepseek-v4',
    modelName: 'DeepSeek-V4.1',
    modelShort: 'DeepSeek-V4.1',
    modelEffort: '高',
    modelEffortId: 'high',
    contextPct: 68,
    routableProviders: const ['deepseek'],
    modelGroups: const [
      ModelCatalogGroup(
        id: 'deepseek',
        name: '官方直连',
        routable: true,
        models: [
          ModelCatalogEntry(
            id: 'deepseek-v4',
            name: 'DeepSeek-V4.1',
            providerId: 'deepseek',
            providerName: '官方直连',
            defaultEffort: 'high',
            efforts: [
              ModelEffortOption(id: 'off', name: 'Off'),
              ModelEffortOption(id: 'low', name: 'Low'),
              ModelEffortOption(id: 'medium', name: 'Medium'),
              ModelEffortOption(id: 'high', name: 'High'),
              ModelEffortOption(id: 'xhigh', name: 'Xhigh'),
            ],
          ),
          ModelCatalogEntry(
            id: 'deepseek-chat',
            name: 'DeepSeek-Chat',
            providerId: 'deepseek',
            providerName: '官方直连',
          ),
        ],
      ),
    ],
    glassTier: GrassBagGlassTier.frosted,
  );
  return container;
}

Widget _wrapComposerHost({
  required ProviderContainer container,
  required TextEditingController textCtrl,
  required FocusNode focusNode,
  Brightness brightness = Brightness.light,
  bool disableAnimations = false,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: GrassBagTokens.resolve(GrassBagAccent.teal, brightness).toMaterialTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ChatComposerDock(
              controller: textCtrl,
              focusNode: focusNode,
              onOpenTerminal: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    GrassBagController.disableAutoAppUpdateCheck = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.grassbag/native_events'),
      (_) async => null,
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.grassbag/native_events'),
      null,
    );
  });

  testWidgets(
    'Long-pressing composer model pill opens iOS Liquid Glass effort menu and selects directly',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await HttpOverrides.runWithHttpOverrides(() async {
        final fake = _FakeLongPressDshServer();
        await tester.runAsync(() => fake.start());
        addTearDown(() => tester.runAsync(() => fake.close()));

        final container = await _seedConnectedModelContainer(tester, fake);
        addTearDown(container.dispose);

        final textCtrl = TextEditingController();
        final focusNode = FocusNode();
        addTearDown(textCtrl.dispose);
        addTearDown(focusNode.dispose);

        await tester.pumpWidget(
          _wrapComposerHost(
            container: container,
            textCtrl: textCtrl,
            focusNode: focusNode,
          ),
        );
        await tester.pumpAndSettle();

        final modelPill = find.byKey(const ValueKey('composer-model-pill'));
        expect(modelPill, findsOneWidget);

        // Stationary long-press & lift keeps the iOS Liquid Glass menu open (without firing tap!)
        await tester.longPress(modelPill);
        await tester.pumpAndSettle();

        expect(find.textContaining('选择思考深度'), findsOneWidget);
        expect(find.text('关闭'), findsOneWidget);
        expect(find.text('低'), findsOneWidget);
        expect(find.text('中'), findsOneWidget);
        expect(find.text('超高'), findsOneWidget);
        expect(find.text('DeepSeek-Chat'), findsOneWidget);
        expect(find.text('全部模型与渠道…'), findsOneWidget);

        // Tap '低' directly -> updates thinking effort without cycling!
        await tester.tap(find.text('低'));
        await tester.pumpAndSettle();
        for (var i = 0; i < 20 && !fake.selectModelPayloads.any((p) => p['reasoningEffort'] == 'low'); i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        }

        final st = container.read(appProvider);
        expect(st.modelEffortId, 'low');
        expect(st.modelEffort, '低');
        expect(
          fake.selectModelPayloads.any((p) => p['reasoningEffort'] == 'low'),
          isTrue,
        );
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.pump(const Duration(seconds: 32));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }, _RealLoopbackHttpOverrides());
    },
  );

  testWidgets(
    'Single-gesture press-hold-slide-release on model pill selects thinking effort in one motion',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await HttpOverrides.runWithHttpOverrides(() async {
        final fake = _FakeLongPressDshServer();
        await tester.runAsync(() => fake.start());
        addTearDown(() => tester.runAsync(() => fake.close()));

        final container = await _seedConnectedModelContainer(tester, fake);
        addTearDown(container.dispose);

        final textCtrl = TextEditingController();
        final focusNode = FocusNode();
        addTearDown(textCtrl.dispose);
        addTearDown(focusNode.dispose);

        await tester.pumpWidget(
          _wrapComposerHost(
            container: container,
            textCtrl: textCtrl,
            focusNode: focusNode,
            brightness: Brightness.dark,
          ),
        );
        await tester.pumpAndSettle();

        final modelPill = find.byKey(const ValueKey('composer-model-pill'));
        final pillCenter = tester.getCenter(modelPill);

        // Single continuous thumb gesture: press down -> hold 420ms -> glide to '超高' -> release!
        final gesture = await tester.startGesture(pillCenter);
        await tester.pump(const Duration(milliseconds: 420));
        await tester.pump(const Duration(milliseconds: 220));

        final xhighFinder = find.text('超高');
        expect(xhighFinder, findsOneWidget);
        final targetCenter = tester.getCenter(xhighFinder);

        await gesture.moveTo(targetCenter);
        await tester.pump(const Duration(milliseconds: 80));
        await gesture.up();
        await tester.pumpAndSettle();
        for (var i = 0; i < 20 && !fake.selectModelPayloads.any((p) => p['reasoningEffort'] == 'xhigh'); i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        }

        // Selected immediately on finger lift and menu dismissed!
        expect(find.textContaining('选择思考深度'), findsNothing);
        final st = container.read(appProvider);
        expect(st.modelEffortId, 'xhigh');
        expect(st.modelEffort, '超高');
        expect(
          fake.selectModelPayloads.any((p) => p['reasoningEffort'] == 'xhigh'),
          isTrue,
        );
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.pump(const Duration(seconds: 32));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }, _RealLoopbackHttpOverrides());
    },
  );

  testWidgets(
    'Long-pressing composer +, Send orb (idle & streaming), and Context ring open iOS menus',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await HttpOverrides.runWithHttpOverrides(() async {
        final fake = _FakeLongPressDshServer();
        await tester.runAsync(() => fake.start());
        addTearDown(() => tester.runAsync(() => fake.close()));

        final container = await _seedConnectedModelContainer(tester, fake);
        addTearDown(container.dispose);
        final ctrl = container.read(appProvider.notifier);

        final textCtrl = TextEditingController();
        final focusNode = FocusNode();
        addTearDown(textCtrl.dispose);
        addTearDown(focusNode.dispose);

        await tester.pumpWidget(
          _wrapComposerHost(
            container: container,
            textCtrl: textCtrl,
            focusNode: focusNode,
          ),
        );
        await tester.pumpAndSettle();

        // 1. Long-press '+' orb -> quick actions strip + Plan Mode + @ mention
        await tester.longPress(find.byKey(const ValueKey('composer-plus-btn')));
        await tester.pumpAndSettle();
        expect(find.text('快捷操作与模式'), findsOneWidget);
        expect(find.text('终端'), findsOneWidget);
        expect(find.text('开启计划模式'), findsOneWidget);
        expect(find.text('引用工作区文件 (@)'), findsOneWidget);

        await tester.tap(find.text('引用工作区文件 (@)'));
        await tester.pumpAndSettle();
        expect(textCtrl.text, contains('@'));

        // 2. Long-press Send orb while idle with text -> iMessage-style send options
        textCtrl.text = '准备发送的消息';
        await tester.pumpAndSettle();
        await tester.longPress(find.byKey(const ValueKey('composer-action-btn')));
        await tester.pumpAndSettle();
        expect(find.text('发送选项'), findsOneWidget);
        expect(find.text('立即发送'), findsOneWidget);
        expect(find.text('以计划模式发送'), findsOneWidget);
        expect(find.text('清空当前草稿'), findsOneWidget);

        await tester.tap(find.text('清空当前草稿'));
        await tester.pumpAndSettle();
        expect(textCtrl.text, isEmpty);

        // 3. Long-press Send orb while streaming with text -> Steer / Queue / Interrupt
        ctrl.state = ctrl.state.copyWith(isStreaming: true);
        textCtrl.text = '插话补充';
        await tester.pumpAndSettle();
        await tester.longPress(find.byKey(const ValueKey('composer-action-btn')));
        await tester.pumpAndSettle();
        expect(find.text('生成中发送方式'), findsOneWidget);
        expect(find.text('插话引导'), findsOneWidget);
        expect(find.text('本轮后排队'), findsOneWidget);
        expect(find.text('打断并改问'), findsOneWidget);

        // Dismiss by tapping top-left scrim
        await tester.tapAt(const Offset(20, 40));
        await tester.pumpAndSettle();
        expect(find.text('生成中发送方式'), findsNothing);

        // 4. Long-press Context Ring -> compact / fork / details
        ctrl.state = ctrl.state.copyWith(isStreaming: false);
        await tester.pumpAndSettle();
        await tester.longPress(find.byKey(const ValueKey('composer-context-ring-btn')));
        await tester.pumpAndSettle();
        expect(find.text('上下文占用 68%'), findsOneWidget);
        expect(find.text('立即精简上下文'), findsOneWidget);
        expect(find.text('创建分支对话 (Fork)'), findsOneWidget);
        expect(find.text('查看 Token 明细'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
      }, _RealLoopbackHttpOverrides());
    },
  );

  testWidgets(
    'Long-pressing top New Chat button & empty-chat Host pill open iOS menus with reduced-motion safety',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);
      final local = ctrl.state.localHost.copyWith(
        name: '本机运行环境',
        online: true,
        bridged: true,
      );
      const remote = ManagedHost(
        id: 'remote-1',
        name: '开发服务器',
        address: '10.0.0.8:4296',
        isLocal: false,
        latency: '12ms',
        online: true,
        bridged: true,
      );
      ctrl.state = ctrl.state.copyWith(
        glassTier: GrassBagGlassTier.frosted,
        hosts: [local, remote],
        activeHostId: local.id,
        workspaces: const [
          WorkspaceItem(id: 'ws-1', name: 'workspace', path: '/root/workspace'),
          WorkspaceItem(id: 'ws-2', name: 'grassbag', path: '/root/grassbag'),
        ],
        activeWorkspace: 'ws-1',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const GrassBagShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Home screen stays clean: no unnecessary '继续 · xxx' recent-session strip!
      ctrl.state = ctrl.state.copyWith(
        sessions: const [
          ChatSessionItem(id: 's-1', title: '旧项目调试', group: '今天'),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('继续 ·'), findsNothing);

      // 1. Long-press top-right New Chat button -> quick new chat options + other workspace
      await tester.longPress(find.byKey(const ValueKey('top-right-false')));
      await tester.pumpAndSettle();
      expect(find.text('新建对话'), findsOneWidget);
      expect(find.text('空白新对话'), findsOneWidget);
      expect(find.text('计划模式新对话'), findsOneWidget);
      expect(find.text('在「grassbag」新建'), findsOneWidget);

      await tester.tap(find.text('计划模式新对话'));
      await tester.pumpAndSettle();
      expect(container.read(appProvider).planMode, isTrue);

      // 2. Long-press top center Host Capsule on empty chat -> quick host switcher
      await tester.longPress(find.text('本机运行环境').first);
      await tester.pumpAndSettle();
      expect(find.text('切换运行主机'), findsOneWidget);
      expect(find.text('开发服务器'), findsOneWidget);
      expect(find.text('管理与添加主机…'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'Streaming chat scroll follows in 0-frame lockstep without overscroll and yields immediately on upward user drag',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      final longHistory = List<NormalizedTurn>.generate(
        6,
        (i) => NormalizedTurn(
          turnId: 't-$i',
          userMessage: NormalizedUserMessage(id: 'u-$i', text: '问题 #$i：请帮我解释第 $i 段架构设计'),
          assistantText: List.filled(8, '第 $i 轮详细回复内容，用于铺满视口并验证流畅滑动与不越界停止。').join('\n\n'),
          status: 'done',
        ),
      );
      final liveTurn = NormalizedTurn(
        turnId: 't-live',
        userMessage: const NormalizedUserMessage(id: 'u-live', text: '开始流式输出测试'),
        assistantText: '第一段流式回复已经开始输出。\n\n第二段内容紧随其后。',
        status: 'streaming',
      );

      ctrl.state = ctrl.state.copyWith(
        glassTier: GrassBagGlassTier.frosted,
        activeSessionId: 'sess-scroll-1',
        sessions: const [
          ChatSessionItem(id: 'sess-scroll-1', title: '滚动体验测试', group: '今天'),
        ],
        turns: [...longHistory, liveTurn],
        isStreaming: true,
        streamTick: 1,
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: const GrassBagShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scrollViewFinder = find.byType(CustomScrollView);
      expect(scrollViewFinder, findsOneWidget);
      final scrollCtrl = tester.widget<CustomScrollView>(scrollViewFinder).controller!;

      // Jump to bottom and verify Android/default ClampingScrollPhysics never overscrolls!
      scrollCtrl.jumpTo(scrollCtrl.position.maxScrollExtent);
      await tester.pump();
      expect(scrollCtrl.position.pixels, lessThanOrEqualTo(scrollCtrl.position.maxScrollExtent));

      // Stream additional lines while pinned -> stays cleanly locked to bottom with zero overscroll
      ctrl.state = ctrl.state.copyWith(
        turns: [
          ...longHistory,
          NormalizedTurn(
            turnId: 't-live',
            userMessage: const NormalizedUserMessage(id: 'u-live', text: '开始流式输出测试'),
            assistantText:
                '${liveTurn.assistantText}\n\n新增流式段落 A\n\n新增流式段落 B\n\n新增流式段落 C',
            status: 'streaming',
          ),
        ],
        streamTick: 2,
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump(const Duration(milliseconds: 220));
      expect(
        scrollCtrl.position.pixels,
        lessThanOrEqualTo(scrollCtrl.position.maxScrollExtent + 0.5),
      );

      // User gently drags upward -> immediately yields scroll ownership, NEVER tugs back down!
      await tester.drag(scrollViewFinder, const Offset(0, 120));
      await tester.pumpAndSettle();
      final userReadingOffset = scrollCtrl.position.pixels;
      expect(userReadingOffset, lessThan(scrollCtrl.position.maxScrollExtent - 30.0));

      // Stream even more lines while user is reading above -> viewport MUST stay rock-steady!
      ctrl.state = ctrl.state.copyWith(
        turns: [
          ...longHistory,
          NormalizedTurn(
            turnId: 't-live',
            userMessage: const NormalizedUserMessage(id: 'u-live', text: '开始流式输出测试'),
            assistantText:
                '${liveTurn.assistantText}\n\n新增流式段落 A\n\n新增流式段落 B\n\n新增流式段落 C\n\n新增流式段落 D\n\n新增流式段落 E\n\n新增流式段落 F',
            status: 'streaming',
          ),
        ],
        streamTick: 3,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect((scrollCtrl.position.pixels - userReadingOffset).abs(), lessThan(2.0));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'Liquid glass chromatic dispersion slider takes global effect and persists across restarts',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // 1. Optical curve check across 0%, 50% (default), and 100% in Light & Dark
      for (final b in [Brightness.light, Brightness.dark]) {
        final tok = GrassBagTokens.resolve(GrassBagAccent.teal, b);
        final zeroSurf = GrassBagGlassConfig.surfaceSettings(
          tok,
          GrassBagGlassTier.liquid,
          opticalStrength: 0.0,
        );
        final midSurf = GrassBagGlassConfig.surfaceSettings(
          tok,
          GrassBagGlassTier.liquid,
          opticalStrength: GrassBagGlassConfig.defaultOpticalStrength,
        );
        final maxSurf = GrassBagGlassConfig.surfaceSettings(
          tok,
          GrassBagGlassTier.liquid,
          opticalStrength: 1.0,
        );
        expect(zeroSurf.chromaticAberration, 0.0);
        expect(midSurf.chromaticAberration, greaterThan(0.08));
        expect(maxSurf.chromaticAberration, greaterThan(0.55));
        expect(maxSurf.refractiveIndex, greaterThan(midSurf.refractiveIndex));
        expect(maxSurf.thickness, greaterThan(midSurf.thickness));

        final zeroSheet = GrassBagGlassConfig.sheetSettings(
          tok,
          GrassBagGlassTier.liquid,
          opticalStrength: 0.0,
        );
        final maxSheet = GrassBagGlassConfig.sheetSettings(
          tok,
          GrassBagGlassTier.liquid,
          opticalStrength: 1.0,
        );
        expect(zeroSheet.chromaticAberration, 0.0);
        expect(maxSheet.chromaticAberration, greaterThan(0.40));
      }

      // 2. End-to-end Settings UI -> global GrassBagGlassTierScope -> SharedPreferences persistence
      SharedPreferences.setMockInitialValues({});
      GrassBagStorage.instance.resetCacheForTest();
      GrassBagController.preloadedInitialPrefs = null;

      final container = ProviderContainer();
      addTearDown(container.dispose);

      Widget buildApp(ProviderContainer c) {
        return UncontrolledProviderScope(
          container: c,
          child: Consumer(
            builder: (context, ref, _) {
              final accent = ref.watch(appProvider.select((s) => s.accent));
              final isDark = ref.watch(appProvider.select((s) => s.isDark));
              final tier = ref.watch(appProvider.select((s) => s.glassTier));
              final opt = ref.watch(appProvider.select((s) => s.glassOpticalStrength));
              final lt = GrassBagTokens.resolve(accent, Brightness.light);
              final dk = GrassBagTokens.resolve(accent, Brightness.dark);
              return GrassBagGlassTierScope(
                tier: tier,
                opticalStrength: opt,
                child: LiquidGlassWidgets.wrap(
                  brightnessResolver: Theme.maybeBrightnessOf,
                  theme: GrassBagGlassConfig.themeDataFor(
                    lt,
                    dk,
                    tier,
                    opticalStrength: opt,
                  ),
                  child: MaterialApp(
                    theme: lt.toMaterialTheme(),
                    darkTheme: dk.toMaterialTheme(),
                    themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
                    home: Stack(
                      children: [
                        SettingsPage(
                          initialSection: SettingsSection.appearance,
                          onOpenWebUi: () {},
                        ),
                        // Sample global floating chrome pill reflecting live ambient dispersion
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: GrassBagGlass(
                            key: const ValueKey('global-chrome-probe'),
                            tier: tier,
                            child: const SizedBox(width: 24, height: 24),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      }

      await tester.pumpWidget(buildApp(container));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('glass-optical-strength-slider')), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);

      double probeChromatic() {
        final glass = tester.widget<GlassContainer>(
          find.descendant(
            of: find.byKey(const ValueKey('global-chrome-probe')),
            matching: find.byType(GlassContainer),
          ),
        );
        return glass.settings!.chromaticAberration;
      }

      final baselineCa = probeChromatic();
      expect(baselineCa, closeTo(0.12, 0.02));

      // Tap near the right edge of the slider -> jumps high, updates live chrome, persists!
      final sliderRect = tester.getRect(find.byKey(const ValueKey('glass-optical-strength-slider')));
      await tester.tapAt(Offset(sliderRect.right - 16, sliderRect.center.dy));
      await tester.pumpAndSettle();

      final boosted = container.read(appProvider).glassOpticalStrength;
      expect(boosted, greaterThan(0.85));
      expect(probeChromatic(), greaterThan(0.45));
      expect(find.byKey(const ValueKey('glass-optical-strength-reset')), findsOneWidget);

      // Verify persisted directly into SharedPreferences (survives app cold restart!)
      final savedPrefs = await tester.runAsync(() => GrassBagStorage.instance.loadPrefs());
      expect(savedPrefs, isNotNull);
      expect((savedPrefs!['glassOpticalStrength'] as num).toDouble(), closeTo(boosted, 0.01));

      // Simulate full cold restart with preloaded prefs + fresh container
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      GrassBagController.preloadedInitialPrefs = savedPrefs;
      addTearDown(() => GrassBagController.preloadedInitialPrefs = null);

      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      expect(restarted.read(appProvider).glassOpticalStrength, closeTo(boosted, 0.01));

      await tester.pumpWidget(buildApp(restarted));
      await tester.pumpAndSettle();
      expect(probeChromatic(), greaterThan(0.45));

      // Verify export/import roundtrip preserves glassOpticalStrength
      final exported = restarted.read(appProvider.notifier).exportConfigJson();
      restarted.read(appProvider.notifier).setGlassOpticalStrength(0.0, persistImmediately: true);
      await tester.pumpAndSettle();
      expect(restarted.read(appProvider).glassOpticalStrength, 0.0);
      expect(probeChromatic(), 0.0);
      expect(find.text('关闭'), findsOneWidget);

      expect(restarted.read(appProvider.notifier).importConfigJson(exported), isTrue);
      await tester.pumpAndSettle();
      expect(restarted.read(appProvider).glassOpticalStrength, closeTo(boosted, 0.01));

      // Tap '恢复默认' -> returns cleanly to 50%
      await tester.tap(find.byKey(const ValueKey('glass-optical-strength-reset')));
      await tester.pumpAndSettle();
      expect(restarted.read(appProvider).glassOpticalStrength, 0.50);
      expect(probeChromatic(), closeTo(0.12, 0.02));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    },
  );
}
