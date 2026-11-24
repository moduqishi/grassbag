import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbridge_client/gbridge_client.dart';
import 'package:grassbag/main.dart';
import 'package:grassbag/services/native_bridge.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/theme/grassbag_glass.dart';
import 'package:grassbag/theme/grassbag_theme.dart';
import 'package:grassbag/ui/chat/turn_process_widget.dart';
import 'package:grassbag/ui/common/grassbag_sheets.dart';
import 'package:grassbag/ui/common/remote_host_connect_card.dart';
import 'package:grassbag/ui/detail/session_detail_page.dart';
import 'package:grassbag/ui/drawer/sessions_drawer.dart';
import 'package:grassbag/ui/features/jobs_page.dart';
import 'package:grassbag/ui/features/plugins_center_page.dart';
import 'package:grassbag/ui/features/schedules_page.dart';
import 'package:grassbag/ui/features/sdui_extensions_page.dart';
import 'package:grassbag/ui/features/subagents_page.dart';
import 'package:grassbag/ui/onboarding/onboarding_page.dart';
import 'package:grassbag/ui/sdui/schemastery_form.dart';
import 'package:grassbag/ui/sdui/sdui_renderer.dart';
import 'package:grassbag/ui/settings/model_config_view.dart';
import 'package:grassbag/ui/settings/permissions_center_page.dart';
import 'package:grassbag/ui/settings/settings_page.dart';
import 'package:grassbag/ui/terminal/terminal_page.dart';
import 'package:grassbag/ui/web/official_web_page.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

Widget _wrapApp({
  Size size = const Size(396, 834),
  EdgeInsets viewInsets = EdgeInsets.zero,
  GrassBagGlassTier tier = GrassBagGlassTier.liquid,
}) {
  return ProviderScope(
    overrides: [
      appProvider.overrideWith((ref) {
        final ctrl = GrassBagController();
        ctrl.setGlassTier(tier);
        return ctrl;
      }),
    ],
    child: MediaQuery(
      data: MediaQueryData(size: size, viewInsets: viewInsets),
      child: const GrassBagApp(),
    ),
  );
}

void main() {
  testWidgets(
    'Phone layout starts clean with zero fake mock data, clean + panel (no WebUI), and spring drawer',
    (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrapApp(size: const Size(396, 834), tier: GrassBagGlassTier.liquid));
      await tester.pumpAndSettle();

      // Zero fake placeholder sessions or turns on fresh disconnected launch
      expect(find.text('修复导出 PDF 模糊问题'), findsNothing);
      expect(find.text('今天想做点什么？'), findsOneWidget);
      expect(find.text('标准模式'), findsOneWidget);
      expect(find.text('工作区内修改'), findsOneWidget);

      // Open '+' GlassPopover and verify NO WebUI tile inside '+' panel + GlassSwitch present!
      await tester.tap(find.byKey(const ValueKey('composer-plus-btn')));
      await tester.pumpAndSettle();
      expect(find.text('相册'), findsOneWidget);
      expect(find.text('拍照'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);
      expect(find.text('终端'), findsOneWidget);
      expect(find.text('官方网页版'), findsNothing);
      expect(find.byType(GlassSwitch), findsOneWidget);

      // Dismiss '+' GlassPopover by tapping outside barrier
      await tester.tapAt(const Offset(200, 120));
      await tester.pumpAndSettle();
      expect(find.text('相册'), findsNothing);

      // Open & close spring-animated phone drawer
      await tester.tap(find.byTooltip('打开侧边栏'));
      await tester.pumpAndSettle();
      expect(find.text('GrassBag'), findsOneWidget);
      await tester.tapAt(const Offset(360, 420));
      await tester.pumpAndSettle();
      expect(find.text('GrassBag'), findsNothing);
    },
  );

  testWidgets(
    'Sending a prompt when disconnected reports honest offline notice instead of fake LLM reply',
    (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrapApp(size: const Size(396, 834), tier: GrassBagGlassTier.liquid));
      await tester.pumpAndSettle();

      const msg = '请帮我检查当前目录状态';
      await tester.enterText(find.byType(TextField), msg);
      await tester.pump();
      await tester.tap(find.byIcon(CupertinoIcons.arrow_up));
      await tester.pumpAndSettle();

      expect(find.text(msg), findsWidgets);
      expect(find.textContaining('尚未连接到运行中的 DSH 引擎'), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
    },
  );

  testWidgets(
    'Keyboard opening smoothly elevates floating composer above IME and preserves focus',
    (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrapApp(size: const Size(396, 834), tier: GrassBagGlassTier.liquid));
      await tester.pumpAndSettle();

      final composerYClosed = tester.getBottomLeft(find.byType(TextField)).dy;

      await tester.tap(find.byKey(const ValueKey('composer-plus-btn')));
      await tester.pumpAndSettle();
      expect(find.text('相册'), findsOneWidget);

      await tester.tapAt(const Offset(200, 120));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.text('相册'), findsNothing);
      final tfBefore = tester.widget<TextField>(find.byType(TextField));
      expect(tfBefore.focusNode?.hasFocus, isTrue);

      tester.view.viewInsets = const FakeViewPadding(bottom: 310);
      await tester.pumpWidget(
        _wrapApp(
          size: const Size(396, 834),
          viewInsets: const EdgeInsets.only(bottom: 310),
          tier: GrassBagGlassTier.liquid,
        ),
      );
      await tester.pumpAndSettle();

      final tfAfter = tester.widget<TextField>(find.byType(TextField));
      expect(tfAfter.focusNode?.hasFocus, isTrue);
      final composerYKeyboard = tester.getBottomLeft(find.byType(TextField)).dy;
      expect(composerYKeyboard, lessThan(composerYClosed - 260));
    },
  );

  testWidgets(
    'Tablet layout hides workbench by default and shows real Settings split-view with zero fake hosts',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrapApp(size: const Size(1024, 760), tier: GrassBagGlassTier.solid));
      await tester.pumpAndSettle();

      expect(find.text('GrassBag'), findsOneWidget);
      expect(find.text('工作台'), findsNothing);
      expect(find.byTooltip('展开工作台'), findsOneWidget);

      await tester.tap(find.byTooltip('收起侧边栏'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('展开侧边栏'), findsOneWidget);

      await tester.tap(find.byTooltip('展开工作台'));
      await tester.pumpAndSettle();
      expect(find.text('工作台'), findsOneWidget);
      expect(find.byTooltip('收起工作台'), findsOneWidget);
      expect(find.byTooltip('展开工作台'), findsNothing);

      await tester.tap(find.byTooltip('展开侧边栏'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('本机与远程主机'), findsOneWidget);
      expect(find.text('余额 ¥42.50'), findsNothing);

      await tester.tap(find.text('本机与远程主机'));
      await tester.pumpAndSettle();
      expect(find.text('公司 MacBook'), findsNothing);
      expect(find.text('本机环境（容器与 DSH 引擎）'), findsOneWidget);

      await tester.ensureVisible(find.text('外观与主题'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('外观与主题'));
      await tester.pumpAndSettle();
      expect(find.byType(GlassSwitch), findsOneWidget);
      expect(find.byType(GlassSegmentedControl), findsOneWidget);
    },
  );

  testWidgets('Terminal page renders capsule tabs and 12-key ExtraKeysRow', (tester) async {
    tester.view.physicalSize = const Size(396, 834);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrapApp(size: const Size(396, 834), tier: GrassBagGlassTier.liquid));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('composer-plus-btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('终端'));
    await tester.pumpAndSettle();

    expect(find.text('终端'), findsOneWidget);
    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('Ctrl'), findsOneWidget);
  });

  testWidgets(
    'Toggling 计划模式 switch triggers Liquid Glass Toast smoothly without freezing',
    (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrapApp(size: const Size(396, 834), tier: GrassBagGlassTier.liquid));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('composer-plus-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(GlassSwitch));
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(find.text('已开启计划模式'), findsOneWidget);

      await tester.tap(find.byType(GlassSwitch));
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(find.text('已关闭计划模式'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 2400));
      await tester.pumpAndSettle();
      expect(find.text('已关闭计划模式'), findsNothing);
    },
  );

  testWidgets('Composer shows / slash commands and real attachment chips without fake stubs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(396, 834);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrapApp(size: const Size(396, 834), tier: GrassBagGlassTier.solid));
    await tester.pumpAndSettle();

    final field = find.byType(TextField).last;
    await tester.enterText(field, '/');
    await tester.pumpAndSettle();
    expect(find.text('/compact'), findsOneWidget);

    // Tapping 文件 in headless VM test should NOT invent fake spec-notes.md
    await tester.tap(find.byKey(const ValueKey('composer-plus-btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('spec-notes.md'), findsNothing);

    // Adding a real attachment renders its removable chip cleanly
    final container = ProviderScope.containerOf(tester.element(find.byType(GrassBagApp)));
    container.read(appProvider.notifier).addPendingAttachment(
          const ComposerAttachment(
            id: 'att-real-1',
            name: 'design-spec.md',
            mimeType: 'text/markdown',
            sizeBytes: 2048,
          ),
        );
    await tester.pumpAndSettle();
    expect(find.text('design-spec.md'), findsOneWidget);

    // Wait for toast auto-dismiss to clear pending timer
    await tester.pump(const Duration(milliseconds: 2400));
    await tester.pumpAndSettle();
  });

  testWidgets('6-tab Session Workbench navigates Files, Diffs, Progress Goals & Subagents cleanly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrapApp(size: const Size(1024, 760), tier: GrassBagGlassTier.solid));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('展开工作台'));
    await tester.pumpAndSettle();

    expect(find.text('文件'), findsOneWidget);
    expect(find.text('改动'), findsOneWidget);
    expect(find.text('进度'), findsOneWidget);
    expect(find.text('轨迹'), findsOneWidget);
    expect(find.text('子代理'), findsOneWidget);

    await tester.tap(find.text('改动'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有未提交的文件改动'), findsOneWidget);

    await tester.tap(find.text('进度'));
    await tester.pumpAndSettle();
    expect(find.text('当前任务清单'), findsOneWidget);
    expect(find.text('长期自主目标 (/goal)'), findsOneWidget);
  });

  testWidgets('All 6 feature pages render cleanly in Dark Mode with zero exceptions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(396, 834);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Widget wrapDarkPage(Widget page) {
      return ProviderScope(
        overrides: [
          appProvider.overrideWith((ref) {
            final c = GrassBagController();
            c.setDark(true);
            c.setGlassTier(GrassBagGlassTier.solid);
            return c;
          }),
        ],
        child: MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
          home: page,
        ),
      );
    }

    await tester.pumpWidget(wrapDarkPage(const SchedulesPage()));
    await tester.pumpAndSettle();
    expect(find.text('定时任务'), findsOneWidget);

    await tester.pumpWidget(wrapDarkPage(const JobsPage()));
    await tester.pumpAndSettle();
    expect(find.text('后台任务'), findsOneWidget);

    await tester.pumpWidget(wrapDarkPage(const SubagentsPage()));
    await tester.pumpAndSettle();
    expect(find.text('协作子代理'), findsOneWidget);

    await tester.pumpWidget(wrapDarkPage(const PluginsCenterPage()));
    await tester.pumpAndSettle();
    expect(find.text('插件与市场'), findsOneWidget);

    await tester.pumpWidget(wrapDarkPage(const SduiExtensionsPage()));
    await tester.pumpAndSettle();
    expect(find.text('诊断与扩展'), findsOneWidget);

    await tester.pumpWidget(wrapDarkPage(const OnboardingPage()));
    await tester.pumpAndSettle();
    expect(find.text('环境初始化向导'), findsOneWidget);
  });

  testWidgets('SchemasteryForm and SduiNodeRenderer render schema controls & fire actions', (
    tester,
  ) async {
    Map<String, dynamic>? submitted;
    String? firedAction;

    await tester.pumpWidget(
      MaterialApp(
        theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                SchemasteryForm(
                  schema: const {
                    'type': 'object',
                    'properties': {
                      'autoCompact': {
                        'type': 'boolean',
                        'title': '自动精简',
                      },
                      'port': {
                        'type': 'string',
                        'title': '监听端口',
                      },
                    },
                  },
                  initialValues: const {'autoCompact': true, 'port': '3080'},
                  tier: GrassBagGlassTier.solid,
                  onSubmit: (v) async {
                    submitted = v;
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                SduiNodeRenderer(
                  node: const {
                    'type': 'column',
                    'children': [
                      {'type': 'metric', 'label': '延迟', 'value': '4 ms'},
                      {
                        'type': 'actions',
                        'items': [
                          {'id': 'ping', 'label': '探测节点', 'primary': true},
                        ],
                      },
                    ],
                  },
                  tier: GrassBagGlassTier.solid,
                  onAction: (id, _) => firedAction = id,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('自动精简'), findsOneWidget);
    expect(find.text('4 ms'), findsOneWidget);

    await tester.tap(find.text('探测节点'));
    await tester.pumpAndSettle();
    expect(firedAction, 'ping');

    await tester.tap(find.byType(GlassSwitch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存配置（有未保存改动）'));
    await tester.pumpAndSettle();
    expect(submitted?['autoCompact'], false);
  });

  testWidgets(
    'Recursive SchemasteryForm visually edits dict<object>, array<string>, oneOf & surfaces save errors',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SchemasteryForm(
                  schema: const {
                    'type': 'object',
                    'properties': {
                      'providers': {
                        'type': 'dict',
                        'title': '自定义渠道',
                        'inner': {
                          'type': 'object',
                          'properties': {
                            'baseUrl': {'type': 'string', 'title': 'API 地址'},
                            'enabled': {'type': 'boolean', 'title': '启用'},
                          },
                        },
                      },
                      'tags': {
                        'type': 'array',
                        'title': '标签列表',
                        'inner': {'type': 'string'},
                      },
                    },
                  },
                  initialValues: const {
                    'providers': {
                      'opencode': {'baseUrl': 'https://api.example.com', 'enabled': true},
                    },
                    'tags': ['fast', 'coding'],
                  },
                  tier: GrassBagGlassTier.solid,
                  onSubmit: (_) async => '400 INVALID_SCHEMA: baseUrl 必须以 https:// 开头',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('自定义渠道'), findsOneWidget);
      expect(find.text('opencode'), findsOneWidget);
      expect(find.text('fast'), findsOneWidget);
      expect(find.text('coding'), findsOneWidget);
      expect(find.text('JSON 源码'), findsOneWidget);

      await tester.tap(find.text('保存配置'));
      await tester.pumpAndSettle();
      expect(find.text('写入 DSH 配置失败（修改已保留）'), findsOneWidget);
      expect(find.textContaining('INVALID_SCHEMA'), findsOneWidget);
    },
  );

  testWidgets('TurnView surfaces structured error card with retry even when process is collapsed', (tester) async {
    var retried = false;
    final errorTurn = NormalizedTurn(
      turnId: 'turn-err-1',
      status: 'error',
      userMessage: const NormalizedUserMessage(id: 'u1', text: '帮我运行测试'),
      steps: const [
        ReasoningStep(
          id: 'r1',
          text: '正在检查环境',
          collapsedPreview: '正在检查环境',
          durationMs: 1200,
        ),
      ],
      errorCode: 'provider/rate_limit',
      errorMessage: 'HTTP 429: 模型接口请求过于频繁，请稍后重试',
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: TurnView(
                turn: errorTurn,
                onOpenTerminal: () {},
                onPrefillPrompt: (_) {},
                onRegenerate: () => retried = true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('执行失败 · provider/rate_limit'), findsOneWidget);
    expect(find.textContaining('HTTP 429'), findsOneWidget);

    await tester.tap(find.text('重新发送'));
    await tester.pumpAndSettle();
    expect(retried, isTrue);
  });

  test('ManagedHost never reports fake updates by default and scrubs legacy cached fake versions', () {
    const fresh = ManagedHost(
      id: 'local',
      isLocal: true,
      name: '本机',
      address: '127.0.0.1',
      latency: '< 1 ms',
      online: true,
      bridged: true,
    );
    expect(fresh.hasLocalUpdates, isFalse);

    final migrated = ManagedHost.fromJson(const {
      'id': 'local',
      'isLocal': true,
      'name': '本机',
      'address': '127.0.0.1',
      'dshVersion': '0.2.2-rc.5',
      'dshLatest': '0.2.3',
      'containerVersion': 'Ubuntu 24.04 · r1',
      'containerLatest': 'Ubuntu 24.04 · r2',
    });
    expect(migrated.dshLatest, '0.2.2-rc.5');
    expect(migrated.containerLatest, 'Ubuntu 24.04 · r1');
    expect(migrated.hasLocalUpdates, isFalse);
  });

  test('ModelEffortOption localizes xhigh and per-turn process toggle stays independent', () {
    expect(const ModelEffortOption(id: 'xhigh', name: 'Xhigh').zhLabel, '超高');
    expect(const ModelEffortOption(id: 'high', name: 'High').zhLabel, '高');

    final ctrl = GrassBagController();
    addTearDown(ctrl.dispose);
    // Completed turns default collapsed; toggling turn-a must not affect turn-b
    ctrl.toggleTurnProcessFor('turn-a', currentlyOpen: false);
    expect(ctrl.state.expandedTurnProcessIds.contains('turn-a'), isTrue);
    expect(ctrl.state.expandedTurnProcessIds.contains('turn-b'), isFalse);

    ctrl.toggleTurnProcessFor('turn-a', currentlyOpen: true);
    expect(ctrl.state.expandedTurnProcessIds.contains('turn-a'), isFalse);
    expect(ctrl.state.collapsedTurnProcessIds.contains('turn-a'), isTrue);
  });

  test('Graphite-Slate dark palette avoids pitch-black glare and sidebar workspace filter works', () {
    for (final accent in GrassBagAccent.values) {
      final dark = GrassBagTokens.resolve(accent, Brightness.dark);
      // Ensure comfortable graphite-slate elevation (> #161616) rather than #050507 OLED black
      expect(dark.bgSolid.computeLuminance(), greaterThan(0.012));
      expect(dark.cardSolid.computeLuminance(), greaterThan(dark.bgSolid.computeLuminance()));
      expect(dark.codeBg.computeLuminance(), lessThan(dark.bgSolid.computeLuminance()));
    }

    final ctrl = GrassBagController();
    addTearDown(ctrl.dispose);
    final prevSignal = ctrl.state.newChatSignal;
    ctrl.startNewChat(workspace: 'playground');
    expect(ctrl.state.newChatSignal, prevSignal + 1);
    expect(ctrl.state.activeWorkspace, 'playground');
    expect(ctrl.state.activeSessionId, isNull);
  });

  testWidgets('Workspace picker -> add workspace directory browser opens cleanly without disposed-ref crash',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const ProviderScope(child: GrassBagApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('选择工作区'));
    await tester.pumpAndSettle();
    expect(find.text('浏览与挂载新工作区目录'), findsOneWidget);

    await tester.tap(find.text('浏览与挂载新工作区目录'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('浏览与挂载工作区'), findsOneWidget);
    expect(find.text('挂载当前目录'), findsOneWidget);
    expect(find.text('主目录 ~'), findsOneWidget);
    expect(find.text('新建'), findsOneWidget);
  });

  testWidgets('DshModelConfigView quick-add custom relay, add custom model, and tab switch work smoothly',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    late GrassBagController ctrl;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appProvider.overrideWith((ref) {
            ctrl = GrassBagController();
            ctrl.setGlassTier(GrassBagGlassTier.solid);
            return ctrl;
          }),
        ],
        child: MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
          home: const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: DshModelConfigView(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Hero card (clean empty-model guidance with NO locked reasoning bar), 2-tab switcher, and 6 quick presets
    expect(find.text('尚未配置可用模型'), findsOneWidget);
    expect(find.text('默认推理思考深度'), findsNothing);
    expect(find.textContaining('模型渠道'), findsOneWidget);
    expect(find.textContaining('全部模型'), findsOneWidget);
    expect(find.text('自定义中转 / 兼容站'), findsOneWidget);
    expect(find.text('DeepSeek 官方'), findsOneWidget);
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('Anthropic Claude'), findsOneWidget);
    expect(find.text('Google Gemini'), findsOneWidget);
    expect(find.text('OpenRouter 聚合'), findsOneWidget);

    // When a reasoning-capable model is active, the reasoning effort selector unlocks cleanly
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    ctrl.state = ctrl.state.copyWith(
      activeModelId: 'deepseek-reasoner',
      activeModelProvider: 'deepseek',
      modelShort: 'DeepSeek Reasoner',
      modelEffort: 'high',
      modelGroups: const [
        ModelCatalogGroup(
          id: 'deepseek',
          name: 'DeepSeek',
          models: [
            ModelCatalogEntry(
              id: 'deepseek-reasoner',
              name: 'DeepSeek Reasoner',
              providerId: 'deepseek',
              providerName: 'DeepSeek',
              efforts: [
                ModelEffortOption(id: 'low', name: '低'),
                ModelEffortOption(id: 'medium', name: '中'),
                ModelEffortOption(id: 'high', name: '高'),
              ],
              defaultEffort: 'high',
            ),
          ],
        ),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('默认推理思考深度'), findsOneWidget);

    // Open Custom Relay visual editor
    await tester.tap(find.text('自定义中转 / 兼容站'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('添加自定义渠道 / 中转站'), findsOneWidget);
    expect(find.text('OpenAI 兼容'), findsOneWidget);
    expect(find.text('Anthropic'), findsOneWidget);
    expect(find.text('128K'), findsOneWidget);
    expect(find.text('200K'), findsOneWidget);
    expect(find.text('1M'), findsOneWidget);

    // Fill custom relay info + add a custom model inline + save
    final fields = find.byType(CupertinoTextField);
    await tester.enterText(fields.at(0), 'MyRelay');
    await tester.enterText(fields.at(1), 'https://relay.example.com/v1');
    await tester.enterText(fields.at(2), 'sk-test-123456');
    await tester.enterText(fields.at(3), 'gpt-5-codex');
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('添加到模型列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加到模型列表'));
    await tester.pumpAndSettle();
    expect(find.text('gpt-5-codex'), findsWidgets);

    await tester.ensureVisible(find.text('保存并刷新模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并刷新模型'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // DSH Single Source of Truth: offline save MUST NOT fake-succeed or close the sheet!
    expect(find.text('添加自定义渠道 / 中转站'), findsOneWidget);
    expect(find.textContaining('当前未连接到 DSH 核心'), findsWidgets);

    // Dismiss sheet cleanly and switch to All Models tab
    await tester.tap(find.byIcon(CupertinoIcons.xmark).first);
    await tester.pumpAndSettle();
    expect(find.text('添加自定义渠道 / 中转站'), findsNothing);

    await tester.tap(find.textContaining('全部模型'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Wide Markdown table renders dedicated non-overlapping horizontal scrollbar and scrolls cleanly',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const wideTableMd = '''
以下为各渠道与模型实测对比表：

| 渠道名称 | 模型 ID | 上下文窗口 | 解码速率 | 缓存命中率 | 首字延迟 TTFT | 备注说明 |
| :--- | :--- | :---: | ---: | ---: | ---: | :--- |
| DeepSeek 官方 | `deepseek-v4-pro` | 1M | 142.5 tok/s | 96.4% | 1.12s | 支持深度推理与工具调用 \\| 稳定高并发 |
| OpenCode 中转 | `deepseek-flash` | 1M | 359.5 tok/s | 97.3% | 2.87s | 极致性价比，支持超长上下文缓存命中 |
''';

    final turn = NormalizedTurn(
      turnId: 'turn-table-1',
      status: 'completed',
      assistantText: wideTableMd,
      usage: const TurnUsage(
        inputTokens: 1414,
        outputTokens: 206,
        cacheReadTokens: 21120,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TurnView(
                  turn: turn,
                  onOpenTerminal: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('渠道名称'), findsOneWidget);
    expect(find.text('DeepSeek 官方'), findsOneWidget);
    // Dedicated horizontal scrollbar strip with nudge buttons & table copy appears on wide tables
    expect(find.byIcon(CupertinoIcons.chevron_right), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.chevron_left), findsOneWidget);
    // Inline per-turn usage micro-badge appears cleanly on completed turn
    expect(find.textContaining('缓存 94%'), findsOneWidget);

    // Tap right nudge button to scroll horizontally without throwing PrimaryScrollController error
    await tester.tap(find.byIcon(CupertinoIcons.chevron_right));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Workbench telemetry dashboard renders real DSH token, speed, TTFT, cache & model groups',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final realProjections = <String, dynamic>{
      'asOfSeq': 2103,
      'values': {
        'sessionStats': {
          'turns': 5,
          'steps': 289,
          'llmMs': 5339419,
          'toolMs': 2695601,
          'ttftMs': 4506782,
          'ttftSteps': 288,
          'decodeMs': 832637,
          'decodeTokens': 299313,
        },
        'tokenUsage': {
          'uncachedInputTokens': 2262265,
          'outputTokens': 299313,
          'cacheReadTokens': 80105344,
          'cacheWriteTokens': 12500,
        },
        'contextPressure': {
          'pressureTokens': 515143,
          'projectedTokens': 515706,
          'contextWindow': 1000000,
        },
        'contextBreakdown': {
          'systemTokens': 7243,
          'toolsTokens': 14037,
          'messageTokens': 376380,
        },
        'commandCodeCost': {
          'groups': [
            {
              'provider': 'opencode',
              'model': 'deepseek-flash',
              'contextTokens': 28982,
              'tokens': {
                'uncachedInputTokens': 2262265,
                'outputTokens': 299313,
                'cacheReadTokens': 80105344,
                'cacheWriteTokens': 12500,
              },
            },
          ],
        },
        'modelSelection': {
          'lastUsed': {'provider': 'opencode', 'model': 'deepseek-flash', 'reasoningEffort': 'max'},
        },
        'workingDirectory': '/Users/cake/toys/playground',
      },
    };

    final telemetry = SessionTelemetry.fromProjections(realProjections);
    expect(telemetry.decodeTps, closeTo(359.47, 0.2));
    expect(telemetry.cacheHitRate, closeTo(0.972, 0.002));
    expect(telemetry.avgTtftMs, 15649);
    expect(telemetry.modelGroups.length, 1);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appProvider.overrideWith((ref) {
            final ctrl = GrassBagController();
            ctrl.setGlassTier(GrassBagGlassTier.solid);
            // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
            ctrl.state = ctrl.state.copyWith(
              contextPct: 52,
              contextUsedK: 515.1,
              contextMaxK: 1000,
              sessionTelemetry: telemetry,
            );
            return ctrl;
          }),
        ],
        child: MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
          home: Scaffold(
            body: SessionDetailContent(
              isTabletPane: true,
              initialTab: 4,
              onOpenTerminal: () {},
              onOpenWebUi: () {},
              onOpenHostDetail: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Hero KPIs + Speed & Latency + Cache Hit Rate + Model Breakdown
    expect(find.text('359 t/s'), findsWidgets);
    expect(find.text('97.2%'), findsOneWidget);
    expect(find.text('生成速度与耗时'), findsOneWidget);
    expect(find.text('Token 与 Prompt 缓存'), findsOneWidget);
    expect(find.textContaining('命中率 97.2%'), findsOneWidget);
    expect(find.text('80.1M'), findsOneWidget);
    expect(find.text('opencode / deepseek-flash'), findsOneWidget);
  });

  testWidgets(
      'Scrolled-up chat stays rock-steady when focusing composer, toggling workbench, or clicking buttons',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final longTurns = [
      for (int i = 0; i < 8; i++)
        NormalizedTurn(
          turnId: 'hist-turn-$i',
          status: 'completed',
          userMessage: NormalizedUserMessage(id: 'u-$i', text: '历史问题 #$i'),
          assistantText:
              '这是第 $i 轮较长的回复内容。\n\n```dart\nvoid fn$i() {\n  print("line $i");\n}\n```\n\n${'详细说明段落 ' * 24}',
        ),
    ];

    late GrassBagController ctrl;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appProvider.overrideWith((ref) {
            ctrl = GrassBagController();
            ctrl.setGlassTier(GrassBagGlassTier.solid);
            // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
            ctrl.state = ctrl.state.copyWith(
              sessions: const [
                ChatSessionItem(id: 'sess-scroll', title: '长对话稳定性测试', group: '今天'),
              ],
              activeSessionId: 'sess-scroll',
              turns: longTurns,
              sessionJumpSignal: 1,
            );
            return ctrl;
          }),
        ],
        child: const GrassBagApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Find the main vertical chat ListView
    final listFinder = find.byType(ListView).last;
    final scrollState = tester.state<ScrollableState>(
      find.descendant(of: listFinder, matching: find.byType(Scrollable)).first,
    );
    expect(scrollState.position.maxScrollExtent, greaterThan(400));
    // Jump cleanly to bottom first, then simulate desktop mouse-wheel scroll UP (no dragDetails!)
    scrollState.position.jumpTo(scrollState.position.maxScrollExtent);
    await tester.pumpAndSettle();
    scrollState.position.pointerScroll(-450);
    await tester.pumpAndSettle();
    final anchoredOffset = scrollState.position.pixels;
    expect(scrollState.position.maxScrollExtent - anchoredOffset, greaterThan(200));

    // 1. Focus composer on Desktop (viewInsets == 0) + wait 300ms -> MUST NOT jolt upward!
    await tester.tap(find.byType(TextField).last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect((scrollState.position.pixels - anchoredOffset).abs(), lessThan(4.0));

    // 2. Toggle Right Workbench open & closed -> MUST NOT yank chat to bottom!
    await tester.tap(find.byTooltip('展开工作台'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收起工作台'));
    await tester.pumpAndSettle();
    expect((scrollState.position.pixels - anchoredOffset).abs(), lessThan(4.0));

    // 3. Background state updates (permission / telemetry / toast) -> MUST NOT scroll!
    ctrl.setPermission('read-only');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect((scrollState.position.pixels - anchoredOffset).abs(), lessThan(4.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Tool execution steps expand inline cleanly and streaming typewriter reveals smoothly',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const toolTurn = NormalizedTurn(
      turnId: 'turn-tool-expand',
      status: 'completed',
      userMessage: NormalizedUserMessage(id: 'u-t1', text: '帮我检查项目状态'),
      steps: [
        ReasoningStep(
          id: 'r-t1',
          text: '先执行 git status 检查工作区变更。',
          collapsedPreview: '先执行 git status 检查工作区变更。',
        ),
        ToolStep(
          callId: 'call-git-1',
          name: 'bash',
          title: 'bash · git status -sb',
          status: 'ok',
          summary: '## main...origin/main',
          hasFullOutput: true,
          durationMs: 145,
        ),
        ToolStep(
          callId: 'call-read-2',
          name: 'read_file',
          title: 'read_file · pubspec.yaml',
          status: 'ok',
          summary: 'name: grassbag',
          hasFullOutput: false,
        ),
      ],
      assistantText: '已完成检查，工作区状态正常。',
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TurnView(
                  turn: toolTurn,
                  onOpenTerminal: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Expand the process summary first
    await tester.tap(find.textContaining('2 项操作'));
    await tester.pumpAndSettle();
    expect(find.text('git status -sb'), findsOneWidget);
    expect(find.text('pubspec.yaml'), findsOneWidget);

    // Tap the bash tool step -> MUST expand inline and show output & quick actions!
    await tester.tap(find.text('git status -sb'));
    await tester.pumpAndSettle();
    expect(find.text('执行结果'), findsOneWidget);
    expect(find.text('## main...origin/main'), findsWidgets);
    expect(find.text('复制输出'), findsOneWidget);
    expect(find.text('打开终端'), findsOneWidget);

    // Tap the read_file tool step (even with hasFullOutput == false!) -> MUST ALSO expand inline!
    await tester.tap(find.text('pubspec.yaml'));
    await tester.pumpAndSettle();
    expect(find.text('name: grassbag'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Switching hosts immediately clears stale chats, shows syncing state, and fast-hydrates new host sessions',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);

    var slowEndpointsFinished = false;
    late HttpServer server;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final path = req.uri.path;
        req.response.headers.contentType = ContentType.json;
        if (path == '/gbridge/v1/capabilities') {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          req.response.write(jsonEncode({
            'bridgeVersion': '0.1.0',
            'dshVersion': '0.2.2-rc.5',
            'protocolVersion': 1,
            'authMode': 'none',
            'host': {'platform': 'darwin', 'arch': 'arm64', 'isLocalAndroid': false},
            'domains': {
              'chat': {'ok': true},
              'workspaces': {'ok': true},
            },
          }));
        } else if (path == '/gbridge/v1/sessions') {
          req.response.write(jsonEncode({
            'sessions': [
              {
                'id': 'remote-s1',
                'title': '远程 Mac 真实对话 Alpha',
                'updatedAt': DateTime.now().millisecondsSinceEpoch,
                'cwd': '/Users/dev/alpha',
                'blank': false,
              },
              {
                'id': 'remote-s2',
                'title': '远程 Mac 真实对话 Beta',
                'updatedAt': DateTime.now().millisecondsSinceEpoch - 60000,
                'cwd': '/Users/dev/beta',
                'blank': false,
              },
            ],
          }));
        } else if (path == '/gbridge/v1/workspaces') {
          req.response.write(jsonEncode({
            'workspaces': [
              {
                'id': 'ws-alpha',
                'name': 'alpha',
                'rootPath': '/Users/dev/alpha',
                'explicit': true,
                'sessionIds': ['remote-s1'],
                'sessionCount': 1,
              },
            ],
          }));
        } else {
          // Simulate slow secondary endpoints (schema/models/market) — MUST NOT block sessions!
          await Future<void>.delayed(const Duration(milliseconds: 500));
          slowEndpointsFinished = true;
          req.response.write(jsonEncode({}));
        }
        await req.response.close();
      });
    });
    addTearDown(() async {
      await tester.runAsync(() => server.close(force: true));
    });

    late GrassBagController ctrl;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appProvider.overrideWith((ref) {
            ctrl = GrassBagController();
            ctrl.setGlassTier(GrassBagGlassTier.solid);
            // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
            ctrl.state = ctrl.state.copyWith(
              activeHostId: 'local',
              connectionPhase: ConnectionPhase.connected,
              searchQuery: '旧搜索词',
              hosts: [
                const ManagedHost(
                  id: 'local',
                  name: '本机设备',
                  isLocal: true,
                  address: 'local://android-proot',
                  latency: '< 1 ms',
                  online: true,
                  bridged: true,
                ),
                ManagedHost(
                  id: 'mac-remote',
                  name: 'Mac Studio',
                  isLocal: false,
                  // Intentionally omit `http://` to verify scheme normalization!
                  address: '127.0.0.1:${server.port}',
                  latency: '8 ms',
                  online: true,
                  bridged: true,
                ),
              ],
              sessions: const [
                ChatSessionItem(id: 'local-old-1', title: '本机旧对话不应残留', group: '今天'),
              ],
            );
            return ctrl;
          }),
        ],
        child: MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
          home: Scaffold(
            body: SessionsSidebar(
              isTabletDocked: true,
              onOpenTerminal: () {},
              onOpenFeatures: () {},
              onOpenSettings: () {},
              onOpenHostsSettings: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('本机旧对话不应残留'), findsNothing); // filtered by '旧搜索词'
    ctrl.setSearchQuery('');
    await tester.pump();
    expect(find.text('本机旧对话不应残留'), findsOneWidget);

    // Switch to Mac Studio -> immediately clears old sessions & shows syncing spinner!
    ctrl.switchHost('mac-remote');
    await tester.pump();
    expect(find.text('本机旧对话不应残留'), findsNothing);
    expect(find.text('正在同步「Mac Studio」的对话…'), findsOneWidget);
    expect(find.text('还没有历史对话'), findsNothing);
    expect(ctrl.state.loadingSessions, isTrue);

    // Stage 0 fast-path hydrates new host's real sessions BEFORE slow 500ms endpoints finish!
    for (int i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (ctrl.state.sessions.length == 2 && !ctrl.state.loadingSessions) break;
    }

    expect(ctrl.state.loadingSessions, isFalse);
    expect(slowEndpointsFinished, isFalse);
    expect(find.text('远程 Mac 真实对话 Alpha'), findsOneWidget);
    expect(find.text('远程 Mac 真实对话 Beta'), findsOneWidget);
    expect(find.text('本机旧对话不应残留'), findsNothing);
    expect(tester.takeException(), isNull);

    // Cleanly unmount widget tree & drain background HTTP/WS timers created in FakeAsync.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => server.close(force: true));
    await tester.pump(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('New Chat preserves draft on re-tap and sending shows instant live waiting indicator without remount flicker',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    late GrassBagController ctrl;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appProvider.overrideWith((ref) {
            ctrl = GrassBagController();
            ctrl.setGlassTier(GrassBagGlassTier.solid);
            return ctrl;
          }),
        ],
        child: const GrassBagApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Typing a draft on Empty New Chat + tapping top-right New Chat button MUST NOT erase the draft!
    final composerField = find.byType(TextField).last;
    await tester.enterText(composerField, '未发出的草稿内容');
    await tester.pump();
    ctrl.startNewChat();
    await tester.pump();
    final tf = tester.widget<TextField>(composerField);
    expect(tf.controller?.text, '未发出的草稿内容');

    // 2. Simulate an active brand-new turn waiting for createSession / first token:
    // MUST immediately show user bubble + calm live waiting indicator (never blank void!)
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    ctrl.state = ctrl.state.copyWith(
      activeSessionId: 'pending-session-1',
      sessions: const [
        ChatSessionItem(id: 'pending-session-1', title: '帮我写个脚本', group: '今天', running: true),
      ],
      turns: const [
        NormalizedTurn(
          turnId: 'client-turn-1',
          status: 'streaming',
          userMessage: NormalizedUserMessage(id: 'u-1', text: '帮我写个脚本'),
        ),
      ],
      isStreaming: true,
    );
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.text('帮我写个脚本'), findsWidgets);
    expect(find.text('正在创建对话并接入工作区…'), findsOneWidget);

    // 3. Once session is created (real UUID) and waiting for TTFT -> switches cleanly to awaiting model response!
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    ctrl.state = ctrl.state.copyWith(
      activeSessionId: 'session-real-1',
      sessions: const [
        ChatSessionItem(id: 'session-real-1', title: '帮我写个脚本', group: '今天', running: true),
      ],
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('已发送，等待模型响应…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Lazy GrassBagSpringTap mounts cleanly at rest and handles press, drag, and tap smoothly',
    (tester) async {
      var tapCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: GrassBagSpringTap(
                onTap: () => tapCount++,
                child: const SizedBox(width: 120, height: 48, child: Text('懒加载按钮')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // At rest before any press: zero Transform wrappers needed!
      expect(find.text('懒加载按钮'), findsOneWidget);

      // Press, slight magnetic drag, release & tap -> triggers spring lazily and invokes onTap!
      await tester.tap(find.text('懒加载按钮'));
      await tester.pumpAndSettle();
      expect(tapCount, 1);

      final gesture = await tester.startGesture(tester.getCenter(find.text('懒加载按钮')));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveBy(const Offset(10, 4));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tapCount, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Incremental Markdown block caching preserves settled code & table blocks while streaming tail updates',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late GrassBagController ctrl;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appProvider.overrideWith((ref) {
              ctrl = GrassBagController();
              ctrl.setGlassTier(GrassBagGlassTier.solid);
              return ctrl;
            }),
          ],
          child: const GrassBagApp(),
        ),
      );
      await tester.pumpAndSettle();

      const blockPrefix = '# 性能报告\n\n'
          '```dart\nfinal fast = true;\n```\n\n'
          '| 模块 | 优化前 | 优化后 |\n'
          '| --- | --- | --- |\n'
          '| Markdown | O(N^2) | O(1) 增量 |\n\n';

      // Start streaming with settled prefix + first tail paragraph
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      ctrl.state = ctrl.state.copyWith(
        activeSessionId: 'stream-perf-1',
        sessions: const [
          ChatSessionItem(id: 'stream-perf-1', title: '性能测试', group: '今天', running: true),
        ],
        turns: const [
          NormalizedTurn(
            turnId: 't-settled-1',
            status: 'completed',
            userMessage: NormalizedUserMessage(id: 'u-0', text: '第一轮问题'),
            assistantText: '第一轮已完成回复',
          ),
          NormalizedTurn(
            turnId: 't-live-2',
            status: 'streaming',
            userMessage: NormalizedUserMessage(id: 'u-1', text: '分析流畅性'),
            assistantText: '$blockPrefix正在输出首段',
          ),
        ],
        isStreaming: true,
        streamTick: 1,
      );
      // Advance streaming typewriter frames smoothly past the settled heading, code block & table
      for (int i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // Collapsed tablet Workbench MUST stay completely unmounted while closed!
      expect(find.byType(SessionDetailContent), findsNothing);
      expect(find.byType(Table), findsOneWidget);

      // Stream additional tail tokens & finish turn
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      ctrl.state = ctrl.state.copyWith(
        turns: const [
          NormalizedTurn(
            turnId: 't-settled-1',
            status: 'completed',
            userMessage: NormalizedUserMessage(id: 'u-0', text: '第一轮问题'),
            assistantText: '第一轮已完成回复',
          ),
          NormalizedTurn(
            turnId: 't-live-2',
            status: 'completed',
            userMessage: NormalizedUserMessage(id: 'u-1', text: '分析流畅性'),
            assistantText: '$blockPrefix正在输出首段，全部已完成。',
          ),
        ],
        isStreaming: false,
        streamTick: 2,
      );
      await tester.pumpAndSettle();

      expect(find.byType(Table), findsOneWidget);
      expect(find.textContaining('全部已完成', findRichText: true), findsOneWidget);
      expect(find.textContaining('第一轮已完成回复', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Keyboard send preserves composer focus, balance formats to 2 decimals, and Permissions Center renders cleanly',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrapApp(size: const Size(412, 915), tier: GrassBagGlassTier.solid),
      );
      await tester.pumpAndSettle();

      // Verify keyboard Send action keeps focus on TextField (does NOT dismiss soft keyboard!)
      final fieldFinder = find.byType(TextField).last;
      await tester.tap(fieldFinder);
      await tester.pumpAndSettle();
      final tf = tester.widget<TextField>(fieldFinder);
      expect(tf.focusNode?.hasFocus, isTrue);
      await tester.enterText(fieldFinder, '测试键盘发送不收起');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(tf.focusNode?.hasFocus, isTrue);

      // Verify 2-decimal balance formatting on DeepSeek account state
      const stateWithLongFloat = GrassBagAppState(
        accountSnapshot: {
          'balance': {
            'value': [
              {'balance': '12.3456789012', 'currency': 'CNY'},
            ],
          },
        },
      );
      expect(stateWithLongFloat.accountBalanceText, '¥12.35');
      const stateWithTrailingZero = GrassBagAppState(
        accountSnapshot: {
          'balance': {
            'value': [
              {'balance': 99.1, 'currency': 'USD'},
            ],
          },
        },
      );
      expect(stateWithTrailingZero.accountBalanceText, r'$99.10');

      // Verify unified Permissions Center renders cleanly
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            appProvider.overrideWith((ref) {
              final ctrl = GrassBagController();
              ctrl.setGlassTier(GrassBagGlassTier.solid);
              return ctrl;
            }),
          ],
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
            home: const PermissionsCenterPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('权限管理'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Design-system unification: Markdown blockquote never crashes, dark accents meet WCAG contrast, and canonical glass primitives & OfficialWebPage render cleanly',
    (WidgetTester tester) async {
      // 1. Verify WCAG contrast of onPrimary on primary across ALL 6 accents in Light & Dark modes
      double contrastRatio(Color a, Color b) {
        final la = a.computeLuminance();
        final lb = b.computeLuminance();
        final hi = la > lb ? la : lb;
        final lo = la > lb ? lb : la;
        return (hi + 0.05) / (lo + 0.05);
      }

      for (final accent in GrassBagAccent.values) {
        for (final brightness in Brightness.values) {
          final tok = GrassBagTokens.resolve(accent, brightness);
          final ratio = contrastRatio(tok.primary, tok.onPrimary);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason: '${accent.name}/${brightness.name} primary/onPrimary contrast $ratio < 4.5',
          );
        }
      }

      // 2. Render Markdown blockquote + canonical primitives in Dark Mode (zero non-uniform borderRadius crash!)
      final textCtrl = TextEditingController();
      addTearDown(textCtrl.dispose);

      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            appProvider.overrideWith((ref) {
              final ctrl = GrassBagController();
              ctrl.setGlassTier(GrassBagGlassTier.solid);
              return ctrl;
            }),
          ],
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.amber, Brightness.dark).toMaterialTheme(),
            home: GrassBagGlassPage(
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TurnView(
                      turn: const NormalizedTurn(
                        turnId: 'quote-check-1',
                        status: 'completed',
                        userMessage: NormalizedUserMessage(id: 'u-q', text: '测试引用块'),
                        assistantText: '> 引用段落测试\n> 第二行引用\n\n`inline code` 与 `\$x^2\$`',
                      ),
                      onOpenTerminal: () {},
                    ),
                    const SizedBox(height: 12),
                    GrassBagTextField(
                      controller: textCtrl,
                      placeholder: '统一超椭圆输入框',
                      insideGlass: true,
                    ),
                    const SizedBox(height: 12),
                    const GrassBagProgressBar(value: 0.65),
                    const SizedBox(height: 12),
                    const GrassBagStatusBanner(
                      tone: GrassBagBannerTone.warn,
                      title: '横幅标题',
                      message: '统一状态提示横幅',
                    ),
                    const SizedBox(height: 12),
                    GrassBagSheetSection(
                      header: '弹窗内同心分组',
                      children: [
                        GrassBagListTile(
                          title: const Text('测试条目'),
                          trailing: GrassBagFilterChip(
                            label: '筛选标签',
                            selected: true,
                            onTap: () {},
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('引用段落测试', findRichText: true), findsOneWidget);
      expect(find.text('统一状态提示横幅'), findsOneWidget);
      expect(find.text('筛选标签'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 3. OfficialWebPage renders cleanly with GrassBagGlassPage (no legacy GrassBagBackdrop)
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            appProvider.overrideWith((ref) {
              final ctrl = GrassBagController();
              ctrl.setGlassTier(GrassBagGlassTier.solid);
              return ctrl;
            }),
          ],
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: const OfficialWebPage(initialUrl: 'http://127.0.0.1:3080'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('官方网页版'), findsOneWidget);
      expect(find.byType(GrassBagGlassPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Anti-jitter regression: SpringTap preserves child state, TextField/ListTile zero shift, FilterChip no overflow, SchemasteryForm keeps saved values',
    (tester) async {
      // 1. GrassBagSpringTap NEVER unmounts/remounts stateful children across press, release, and disable
      var mountCount = 0;
      var tapCount = 0;
      var enabled = true;
      late StateSetter setOuterState;

      await tester.pumpWidget(
        MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                setOuterState = setState;
                return Center(
                  child: GrassBagSpringTap(
                    enabled: enabled,
                    onTap: () => tapCount++,
                    child: _MountCountingChild(onInit: () => mountCount++),
                  ),
                );
              },
            ),
          ),
        ),
      );
      expect(mountCount, 1);

      final gesture = await tester.startGesture(tester.getCenter(find.text('stateful-child')));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tapCount, 1);
      expect(mountCount, 1);

      setOuterState(() => enabled = false);
      await tester.pumpAndSettle();
      expect(mountCount, 1);

      // 2. GrassBagTextField has ZERO height shift on focus & hasError toggle
      final tfCtrl = TextEditingController();
      addTearDown(tfCtrl.dispose);
      final tfFocus = FocusNode();
      addTearDown(tfFocus.dispose);
      var hasErr = false;
      late StateSetter setTfState;

      await tester.pumpWidget(
        MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: StatefulBuilder(
                builder: (_, setState) {
                  setTfState = setState;
                  return GrassBagTextField(
                    controller: tfCtrl,
                    focusNode: tfFocus,
                    hasError: hasErr,
                    insideGlass: true,
                    placeholder: '防抖动测试',
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rectRest = tester.getRect(find.byType(GrassBagTextField));

      tfFocus.requestFocus();
      await tester.pumpAndSettle();
      final rectFocused = tester.getRect(find.byType(GrassBagTextField));
      expect((rectFocused.height - rectRest.height).abs(), lessThan(0.01));

      setTfState(() => hasErr = true);
      await tester.pumpAndSettle();
      final rectErr = tester.getRect(find.byType(GrassBagTextField));
      expect((rectErr.height - rectRest.height).abs(), lessThan(0.01));

      // 3. GrassBagListTile has ZERO height or title X jump on selected toggle
      var tileSelected = false;
      late StateSetter setTileState;

      await tester.pumpWidget(
        MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                setTileState = setState;
                return GrassBagListTile(
                  selected: tileSelected,
                  title: const Text('稳定行项'),
                  onTap: () {},
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tileRectBefore = tester.getRect(find.byType(GrassBagListTile));
      final titlePosBefore = tester.getTopLeft(find.text('稳定行项'));

      setTileState(() => tileSelected = true);
      await tester.pumpAndSettle();
      final tileRectAfter = tester.getRect(find.byType(GrassBagListTile));
      final titlePosAfter = tester.getTopLeft(find.text('稳定行项'));
      expect((tileRectAfter.height - tileRectBefore.height).abs(), lessThan(0.01));
      expect((titlePosAfter.dx - titlePosBefore.dx).abs(), lessThan(0.01));

      // 4. GrassBagFilterChip inside narrow 80px constraint never triggers RenderFlex overflow
      await tester.pumpWidget(
        MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 80,
                child: GrassBagFilterChip(
                  label: 'super-long-model-identifier-name',
                  selected: true,
                  showDot: true,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 5. SchemasteryForm retains freshly saved value immediately (never snaps back to stale initialValues)
      Map<String, dynamic>? submitted;
      await tester.pumpWidget(
        MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SchemasteryForm(
                schema: const {
                  'type': 'object',
                  'properties': {
                    'endpoint': {'type': 'string', 'description': 'API 地址'},
                  },
                },
                initialValues: const {'endpoint': 'https://old.example.com'},
                tier: GrassBagGlassTier.solid,
                submitLabel: '保存测试',
                onSubmit: (vals) async {
                  submitted = vals;
                  return null;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField), 'https://new.example.com');
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('保存测试'));
      await tester.pumpAndSettle();

      expect(submitted?['endpoint'], 'https://new.example.com');
      final tfAfterSave = tester.widget<CupertinoTextField>(find.byType(CupertinoTextField));
      expect(tfAfterSave.controller?.text, 'https://new.example.com');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'RemoteHostConnectCard supports zero-plugin zero-token flow, smart paste parsing, and direct-mode badges',
    (WidgetTester tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // 1) Smart `addRemoteHost` parses raw `dsh web:` terminal output & bare LAN IP cleanly
      final ctrl = container.read(appProvider.notifier);
      final fromLine = ctrl.addRemoteHost(
        'dsh web: http://192.168.1.44:3080/?token=launch_xyz',
        autoProbe: false,
      );
      expect(fromLine, isNotNull);
      expect(fromLine!.address, 'http://192.168.1.44:3080');
      expect(fromLine.token, 'launch_xyz');

      final bareIp = ctrl.addRemoteHost('192.168.1.88', autoProbe: false);
      expect(bareIp, isNotNull);
      expect(bareIp!.address, 'http://192.168.1.88:3080');
      expect(bareIp.token, isNull);

      // 2) Direct-mode stock DSH host reports healthy & '原生直连' badge without plugin
      const directHost = ManagedHost(
        id: 'rem-direct',
        isLocal: false,
        name: 'Mac Mini',
        address: 'http://192.168.1.88:3080',
        latency: '8ms',
        online: true,
        bridged: false,
        directMode: true,
      );
      final appState = container.read(appProvider);
      expect(appState.hostIsHealthy(directHost), isTrue);
      expect(appState.hostStatusBadge(directHost), '原生直连');
      expect(appState.hostStatusLabel(directHost), contains('原生直连'));

      // 3) Render RemoteHostConnectCard with collapsible advanced options + 1-line start commands
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: RemoteHostConnectCard(connectImmediately: false),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('直连远程 DSH 设备'), findsOneWidget);
      expect(find.text('粘贴启动链接'), findsOneWidget);
      expect(find.text('发现局域网设备'), findsOneWidget);
      expect(find.text('检测连通'), findsOneWidget);

      // Expand Desktop GUI + CLI guide
      await tester.tap(find.text('桌面端 / 电脑引导'));
      await tester.pumpAndSettle();
      expect(find.text('桌面端 GUI (免命令)'), findsOneWidget);
      await tester.tap(find.text('命令行 (dsh web)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('dsh web --host'), findsWidgets);

      // Expand optional advanced options (Token optional + self-signed cert toggle)
      await tester.tap(find.textContaining('高级选项'));
      await tester.pumpAndSettle();
      expect(find.textContaining('信任自签名 HTTPS 证书'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Multi-host isolation: ManagedHost scrubs stale online/fake prevVersion, directMode enables isDshConnected, switchHost isolates drafts & resets presets, and TerminalPage isolates remote host',
    (WidgetTester tester) async {
      // 1) ManagedHost.toJson/fromJson strips volatile connectivity state & scrubs fake '0.2.2-rc.1'
      const rawHost = ManagedHost(
        id: 'rem-stale',
        isLocal: false,
        name: 'Lab Server',
        address: 'http://10.0.0.5:3080',
        latency: '12ms',
        online: true,
        bridged: true,
        directMode: true,
        dshPrevVersion: '0.2.2-rc.1',
      );
      final encoded = rawHost.toJson();
      expect(encoded.containsKey('online'), isFalse);
      expect(encoded.containsKey('bridged'), isFalse);
      expect(encoded.containsKey('directMode'), isFalse);
      final restored = ManagedHost.fromJson({
        ...encoded,
        'online': true,
        'bridged': true,
        'directMode': true,
        'dshPrevVersion': '0.2.2-rc.1',
      });
      expect(restored.online, isFalse);
      expect(restored.bridged, isFalse);
      expect(restored.directMode, isFalse);
      expect(restored.dshPrevVersion, isEmpty);

      // 2) Zero-Plugin Vanilla Direct Mode sets isConnectedUsable & GrassBagAppState.isDshConnected = true
      const directHost = ManagedHost(
        id: 'rem-vanilla',
        isLocal: false,
        name: 'Mac Studio',
        address: 'http://192.168.1.99:3080',
        latency: '5ms',
        online: true,
        bridged: false,
        directMode: true,
      );
      expect(directHost.isConnectedUsable, isTrue);
      final baseContainer = ProviderContainer();
      addTearDown(baseContainer.dispose);
      final baseState = baseContainer.read(appProvider);
      final directState = baseState.copyWith(
        hosts: [baseState.localHost, directHost],
        activeHostId: directHost.id,
        connectionPhase: ConnectionPhase.connected,
      );
      expect(directState.isDshConnected, isTrue);

      // 3) switchHost synchronously clears turns/attachments/planMode, resets preset/permission, and isolates drafts & filters
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      final added = ctrl.addRemoteHost('http://198.51.100.10:3080', autoProbe: false);
      expect(added, isNotNull);
      ctrl.setComposerDraftForActiveHost('local draft only');
      ctrl.setPlanMode(true);
      ctrl.setSidebarWorkspaceFilter('/root/local-proj');
      ctrl.addPendingAttachment(
        const ComposerAttachment(
          id: 'att-local-1',
          name: 'local.txt',
          mimeType: 'text/plain',
          sizeBytes: 12,
        ),
      );
      expect(container.read(appProvider).planMode, isTrue);
      expect(container.read(appProvider).pendingAttachments, hasLength(1));

      await ctrl.switchHost(added!.id);
      final afterRemote = container.read(appProvider);
      expect(afterRemote.activeHostId, added.id);
      expect(afterRemote.activePresetId, 'standard');
      expect(afterRemote.activePermissionId, 'workspace-write');
      expect(afterRemote.planMode, isFalse);
      expect(afterRemote.pendingAttachments, isEmpty);
      expect(afterRemote.sidebarWorkspaceFilter, isNull);
      expect(afterRemote.turns, isEmpty);
      expect(ctrl.getComposerDraftForActiveHost(), isEmpty);

      ctrl.setComposerDraftForActiveHost('remote draft only');
      ctrl.setSidebarWorkspaceFilter('/srv/remote-proj');
      await ctrl.switchHost('local');
      expect(container.read(appProvider).activeHostId, 'local');
      expect(ctrl.getComposerDraftForActiveHost(), 'local draft only');
      expect(container.read(appProvider).sidebarWorkspaceFilter, '/root/local-proj');

      await ctrl.switchHost(added.id);
      expect(ctrl.getComposerDraftForActiveHost(), 'remote draft only');
      expect(container.read(appProvider).sidebarWorkspaceFilter, '/srv/remote-proj');

      // 4) TerminalPage on disconnected remote host shows honest disconnected state and never falls back to local shell
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: const TerminalPage(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining(added.name), findsWidgets);
      await tester.tap(find.byTooltip('更多'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('等待连接远程主机'), findsOneWidget);
      expect(find.text('Android 本机 Shell'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Desktop remote guide, self-device exclusion, calm needsAuth state, Accessibility malfunction help, and spherical Liquid Glass optics',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // 1) Calm needsAuth state MUST NEVER flag hostHasError == true!
      const authHost = ManagedHost(
        id: 'rem-desktop-auth',
        isLocal: false,
        name: 'Mac Desktop',
        address: 'http://192.168.1.99:3081',
        latency: '4 ms',
        online: false,
        bridged: false,
        lastErrorCode: 'needs_auth',
        lastError: '需要授权 Token',
      );
      expect(authHost.needsAuth, isTrue);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      final authState = container.read(appProvider).copyWith(
        hosts: [container.read(appProvider).localHost, authHost],
        activeHostId: authHost.id,
        connectionPhase: ConnectionPhase.needsAuth,
      );
      expect(authState.hostHasError(authHost), isFalse);
      expect(authState.hostStatusBadge(authHost), '待鉴权');

      // 2) Self-device exclusion blocks Android loopback + local container + own Wi-Fi IP, allows remote LAN
      final pcLoopbackHint = ctrl.selfDeviceGuidanceForUri(
        Uri.parse('http://127.0.0.1:3080'),
        isAndroidOverride: true,
        deviceIpsOverride: const {'192.168.1.42'},
      );
      expect(pcLoopbackHint, isNotNull);
      expect(pcLoopbackHint, contains('局域网 IP'));

      final androidSelfHint = ctrl.selfDeviceGuidanceForUri(
        Uri.parse('http://127.0.0.1:13080'),
        isAndroidOverride: true,
        deviceIpsOverride: const {'192.168.1.42'},
      );
      expect(androidSelfHint, isNotNull);
      expect(androidSelfHint, contains('当前设备本机'));

      final ownWifiHint = ctrl.selfDeviceGuidanceForUri(
        Uri.parse('http://192.168.1.42:3080'),
        isAndroidOverride: true,
        deviceIpsOverride: const {'192.168.1.42'},
      );
      expect(ownWifiHint, isNotNull);

      expect(
        ctrl.selfDeviceGuidanceForUri(
          Uri.parse('http://192.168.1.99:3081'),
          isAndroidOverride: true,
          deviceIpsOverride: const {'192.168.1.42'},
        ),
        isNull,
      );

      // On Android test target, addRemoteHost refuses loopback 127.0.0.1:3080 cleanly
      final rejectedSelf = ctrl.addRemoteHost('http://127.0.0.1:3080', autoProbe: false);
      expect(rejectedSelf, isNull);
      expect(container.read(appProvider).hosts.where((h) => !h.isLocal), isEmpty);

      // 3) Crystal-clear Liquid Glass optics: spherical lens, zero frost/ambientRim/rimShade,
      //    low-haze refraction blur, luminous dual-lobe rimLight, and subtle edge prism CA!
      for (final dark in [false, true]) {
        final tokens = GrassBagTokens.resolve(
          GrassBagAccent.teal,
          dark ? Brightness.dark : Brightness.light,
        );
        final surf = GrassBagGlassConfig.surfaceSettings(tokens, GrassBagGlassTier.liquid);
        final sheet = GrassBagGlassConfig.sheetSettings(tokens, GrassBagGlassTier.liquid);
        expect(surf.lensModel, GlassLensModel.spherical);
        expect(surf.frost, 0.0);
        expect(surf.ambientRim, 0.0);
        expect(surf.rimShade, 0.0);
        expect(surf.rimLight, greaterThan(0.5));
        expect(surf.chromaticAberration, greaterThan(0.0));
        expect(surf.blur, lessThanOrEqualTo(2.0));
        expect(surf.whitenStrength, 0.0);
        expect(sheet.lensModel, GlassLensModel.spherical);
        expect(sheet.frost, 0.0);
        expect(sheet.rimShade, 0.0);
        expect(sheet.rimLight, greaterThan(0.5));
        expect(sheet.blur, greaterThan(surf.blur));
        expect(sheet.blur, lessThanOrEqualTo(5.0));
        expect(sheet.whitenStrength, lessThanOrEqualTo(0.08));
      }

      // 4) RemoteHostConnectCard shows Desktop GUI (免命令) 1-click prompt + concrete-IP CLI tab (zero 0.0.0.0)
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: RemoteHostConnectCard(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('桌面端 / 电脑引导'));
      await tester.pumpAndSettle();
      expect(find.text('桌面端 GUI (免命令)'), findsOneWidget);
      expect(find.text('复制桌面端一键指令（发给桌面 AI）'), findsOneWidget);

      await tester.tap(find.text('命令行 (dsh web)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('--host 0.0.0.0'), findsNothing);
      expect(find.textContaining('dsh web --host'), findsWidgets);

      // 5) PermissionsCenterView renders Android Accessibility malfunction recovery banner cleanly
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      ctrl.state = ctrl.state.copyWith(
        nativePermissions: const NativePermissionsStatus(
          accessibilityEnabled: false,
          accessibilitySettingEnabled: true,
          accessibilitySystemBound: false,
          overlayGranted: false,
          notificationsGranted: true,
          allFilesGranted: true,
          batteryOptIgnored: false,
          sdkInt: 34,
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: PermissionsCenterView(),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('无障碍服务未绑定 / 系统提示「服务出现故障」'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'v11 Polish regressions: Phone Settings deep-link, Account search, Markdown math/currency/code-collapse, cancelled turn, Terminal Copy/Paste & global modal toast',
    (tester) async {
      tester.view.physicalSize = const Size(396, 834);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      // 1) Phone SettingsPage deep-link auto-pushes _PhoneSettingsSubpage for SettingsSection.hosts
      // Mount inside GrassBagGlobalToastHost (same as real MaterialApp.builder) to guarantee
      // Positioned-only page Stacks NEVER collapse to Size.zero!
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            builder: (_, child) => GrassBagGlobalToastHost(child: child ?? const SizedBox.shrink()),
            home: SettingsPage(
              initialSection: SettingsSection.hosts,
              onOpenWebUi: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Deep-linked directly into Hosts subpage (header title is '本机与远程主机', not root '设置')!
      expect(find.text('本机与远程主机'), findsWidgets);
      expect(find.text('直连远程 DSH 设备'), findsOneWidget);
      expect(tester.getSize(find.text('直连远程 DSH 设备')).width, greaterThan(40));

      // 2) Settings search matches DeepSeek Account Hero Card (also inside GrassBagGlobalToastHost)
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            key: const ValueKey('settings-search-app'),
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            builder: (_, child) => GrassBagGlobalToastHost(child: child ?? const SizedBox.shrink()),
            home: SettingsPage(onOpenWebUi: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).first, '余额');
      await tester.pumpAndSettle();
      expect(find.text('DeepSeek 账号'), findsOneWidget);
      expect(tester.getSize(find.text('DeepSeek 账号')).width, greaterThan(40));

      // 3) Markdown currency guard (`$5 to $10`), display math `$$E = mc^2$$`,
      // rich link `[**bold** link](...)`, long collapsible fenced code block (>40 lines),
      // AND cancelled empty turn indicator ('已停止生成' + '重试')
      final longCode = List.generate(48, (i) => 'final line$i = $i;').join('\n');
      final mdTurn = NormalizedTurn(
        turnId: 'turn-md-v11',
        status: 'completed',
        userMessage: const NormalizedUserMessage(id: 'u-md', text: '测试 Markdown 渲染'),
        assistantText:
            'Price is \$5 to \$10 today.\n\n\$\$\nE = mc^2\n\$\$\n\nSee [**Bold Docs**](https://example.com) and https://grassbag.dev.\n\n```dart\n$longCode\n```',
      );
      const cancelledTurn = NormalizedTurn(
        turnId: 'turn-cancel-v11',
        status: 'completed',
        userMessage: NormalizedUserMessage(id: 'u-cancel', text: '被中断的问题'),
        assistantText: '',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TurnView(
                      turn: mdTurn,
                      onOpenTerminal: () {},
                    ),
                    TurnView(
                      turn: cancelledTurn,
                      onOpenTerminal: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Price is \$5 to \$10 today', findRichText: true), findsOneWidget);
      expect(find.text('E = mc^2'), findsOneWidget);
      expect(find.textContaining('Bold Docs', findRichText: true), findsOneWidget);
      expect(find.text('换行'), findsOneWidget);
      expect(find.text('48 行'), findsOneWidget);
      expect(find.textContaining('展开剩余 24 行'), findsOneWidget);
      expect(find.text('已停止生成'), findsOneWidget);

      // Tap expand on long code block -> collapses button disappears & '收起' appears
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);

      // 4) TerminalPage renders Paste key inside GrassBagGlobalToastHost, adds 2nd tab with inline close icon, and closes it cleanly
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            key: const ValueKey('terminal-v11-app'),
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
            builder: (_, child) => GrassBagGlobalToastHost(child: child ?? const SizedBox.shrink()),
            home: const TerminalPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('粘贴'), findsOneWidget);
      expect(tester.getSize(find.text('粘贴')).width, greaterThan(10));
      await tester.tap(find.byIcon(CupertinoIcons.add));
      await tester.pumpAndSettle();
      expect(find.textContaining('#2'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.xmark), findsOneWidget);
      await tester.tap(find.byIcon(CupertinoIcons.xmark));
      await tester.pumpAndSettle();
      expect(find.textContaining('#2'), findsNothing);

      // 5) Global toast host renders toast cleanly above an open modal sheet
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            key: const ValueKey('global-toast-v11-app'),
            navigatorKey: grassBagNavigatorKey,
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            builder: (_, child) => GrassBagGlobalToastHost(child: child ?? const SizedBox.shrink()),
            home: Builder(
              builder: (ctx) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () {
                      showGrassBagSheet<void>(
                        ctx,
                        title: '测试弹窗',
                        bodyBuilder: (_) => const Text('弹窗内容'),
                      );
                      ctrl.showToast('弹窗上层提示可见');
                    },
                    child: const Text('Open Sheet'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();
      expect(find.text('弹窗内容'), findsOneWidget);
      expect(find.text('弹窗上层提示可见'), findsOneWidget);
      final toastText = tester.widget<Text>(find.text('弹窗上层提示可见'));
      expect(toastText.style?.decoration, TextDecoration.none);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'v12 regression: Liquid Glass optics calibration, nested italic+bold, streaming code stability, fractional slider & Cron weekdays',
    (tester) async {
      // 1) Crystal-clear Liquid Glass calibration: zero ambientRim/rimShade, matched low-haze blur, pure achromatic glassColor
      for (final brightness in Brightness.values) {
        final t = GrassBagTokens.resolve(GrassBagAccent.teal, brightness);
        final norm = GrassBagGlassConfig.surfaceSettings(t, GrassBagGlassTier.liquid, elevated: false);
        final elev = GrassBagGlassConfig.surfaceSettings(t, GrassBagGlassTier.liquid, elevated: true);
        final sheet = GrassBagGlassConfig.sheetSettings(t, GrassBagGlassTier.liquid);
        expect(norm.chromaticAberration, greaterThan(0.0));
        expect(elev.chromaticAberration, greaterThan(0.0));
        expect(sheet.chromaticAberration, greaterThan(0.0));
        expect(norm.ambientRim, 0.0);
        expect(norm.rimLight, greaterThan(0.5));
        expect(norm.rimShade, 0.0);
        expect(sheet.ambientRim, 0.0);
        expect(sheet.rimLight, greaterThan(0.5));
        expect(sheet.rimShade, 0.0);
        expect(norm.blur, 1.5);
        expect(elev.blur, 1.5);
        expect(norm.glassColor.r, closeTo(1.0, 0.01));
        expect(norm.glassColor.g, closeTo(1.0, 0.01));
        expect(norm.glassColor.b, closeTo(1.0, 0.01));
      }

      // 2) Named weekday/month Cron validation
      expect(isValidCron5Field('0 9 * * MON-FRI'), isTrue);
      expect(isValidCron5Field('30 8 1 JAN,JUL MON#1'), isTrue);
      expect(isValidCron5Field('0 9 * * *'), isTrue);
      expect(isValidCron5Field('0 9 * *'), isFalse);
      expect(isValidCron5Field('bad 9 * * *'), isFalse);

      // 3) Nested italic + bold markdown & live streaming 50-line code block stays expanded (never collapses at line 41!)
      final liveLines = List.generate(50, (i) => 'final v$i = $i;').join('\n');
      final streamingTurn = NormalizedTurn(
        turnId: 'v12-stream-code',
        status: 'streaming',
        assistantText: 'Check *italic **bold** italic* now.\n\n```dart\n$liveLines\n```',
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);
      ctrl.setGlassTier(GrassBagGlassTier.solid);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: TurnView(
                  turn: streamingTurn,
                  onOpenTerminal: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('italic bold italic', findRichText: true), findsOneWidget);
      // Streaming 50-line code block MUST NOT show '展开剩余' auto-collapse pill while streaming!
      expect(find.textContaining('展开剩余'), findsNothing);

      // 4) SchemasteryForm fractional slider (max-min < 0.5 with step: 1.0) never crashes with divisions == 0
      await tester.pumpWidget(
        MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SchemasteryForm(
                namespaceId: 'test-slider',
                schema: const {
                  'type': 'object',
                  'properties': {
                    'tinyRatio': {
                      'type': 'number',
                      'minimum': 0.0,
                      'maximum': 0.4,
                      'step': 1.0,
                    },
                  },
                },
                initialValues: const {'tinyRatio': 0.2},
                tier: GrassBagGlassTier.solid,
                onSubmit: (_) async => null,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(CupertinoSlider), findsOneWidget);

      // 5) No-op Schemastery mutation returns empty ops (protecting masked secrets)
      final ops = computeSchemasteryMutationOps(
        const {'apiKey': '••••', 'timeout': 30},
        const {'apiKey': '••••', 'timeout': 30},
        secretPaths: const {'apiKey'},
      );
      expect(ops, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'v13 UX & guidance: Cron Zh preview, Settings keyword alias search, readiness strip, truthful Composer pill & send guard',
    (tester) async {
      // 1) Pure Chinese Cron preview helper
      expect(describeCronZh('0 9 * * *'), '每天 09:00');
      expect(describeCronZh('30 18 * * 1-5'), '工作日 18:30');
      expect(describeCronZh('0 */6 * * *'), '每 6 小时整点执行');
      expect(describeCronZh('*/15 * * * *'), '每 15 分钟执行');
      expect(describeCronZh('0 8 * * 1'), '每周一 08:00');
      expect(describeCronZh('15 10 1 * *'), '每月 1 日 10:15');
      expect(describeCronZh('0 9 * *'), contains('格式有误'));

      // 2) Settings natural keyword alias search (Chinese & English)
      expect(
        settingsSectionMatchesQuery(
          SettingsSection.permissions,
          title: '权限管理',
          summary: '0/6 已授权',
          groupTitle: '连接与本机',
          rawQuery: '无障碍',
        ),
        isTrue,
      );
      expect(
        settingsSectionMatchesQuery(
          SettingsSection.hosts,
          title: '本机与远程主机',
          summary: '未连接',
          groupTitle: '连接与本机',
          rawQuery: '代理',
        ),
        isTrue,
      );
      expect(
        settingsSectionMatchesQuery(
          SettingsSection.model,
          title: '模型与渠道',
          summary: '未配置',
          groupTitle: 'DSH 核心设置',
          rawQuery: 'Base URL',
        ),
        isTrue,
      );
      expect(
        settingsSectionMatchesQuery(
          SettingsSection.appearance,
          title: '外观与主题',
          summary: '浅色',
          groupTitle: '连接与本机',
          rawQuery: '深色',
        ),
        isTrue,
      );

      // 3) Truthful Composer pill + connected zero-model Home 2-CTA card + draft-preserving send guard
      tester.view.physicalSize = const Size(412, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);
      ctrl.setGlassTier(GrassBagGlassTier.solid);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const GrassBagApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Inject connected-with-zero-models state AFTER initial boot probe settles
      ctrl.state = ctrl.state.copyWith(
        connectionPhase: ConnectionPhase.connected,
        nativeRuntimeStatus: const NativeRuntimeStatus(
          initialized: true,
          engineRunning: true,
          engineState: 'running',
        ),
        hosts: [
          ctrl.state.localHost.copyWith(online: true, bridged: true),
        ],
        routableProviders: const [],
        modelGroups: const [],
        activeModelId: '',
        modelName: '',
        modelShort: '',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(ctrl.state.isDshConnected, isTrue);
      expect(ctrl.state.routableProviders, isEmpty);

      // Home empty state shows direct 2-button model setup card + truthful '配置模型' composer pill
      expect(find.text('登录 DeepSeek'), findsOneWidget);
      expect(find.text('API Key / 中转'), findsOneWidget);
      expect(find.text('配置模型'), findsOneWidget);

      // Typing a prompt and tapping send while connected with zero routable providers
      // MUST preserve the typed draft and route to Model Settings instead of failing with an error!
      const draftText = '帮我检查项目依赖';
      await tester.enterText(find.byType(TextField).first, draftText);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(CupertinoIcons.arrow_up));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Routed to Settings -> Model view
      expect(find.text('模型与渠道'), findsWidgets);
      // Navigate back to Home (subpage -> settings -> home) and confirm draft text was NOT wiped!
      await tester.tap(find.byTooltip('返回').first);
      await tester.pumpAndSettle();
      if (find.byTooltip('返回').evaluate().isNotEmpty) {
        await tester.tap(find.byTooltip('返回').first);
        await tester.pumpAndSettle();
      }
      expect(find.text(draftText), findsOneWidget);

      // Switch to needsAuth state -> truthful '待授权' pill on composer
      ctrl.state = ctrl.state.copyWith(
        connectionPhase: ConnectionPhase.needsAuth,
        hosts: const [
          ManagedHost(
            id: 'remote-auth',
            name: '办公 Mac',
            address: 'http://192.168.1.9:3080',
            isLocal: false,
            online: false,
            bridged: false,
            latency: '--',
            lastErrorCode: 'needs_auth',
            lastError: '需要访问令牌',
          ),
        ],
        activeHostId: 'remote-auth',
      );
      await tester.pumpAndSettle();
      expect(find.text('待授权'), findsWidgets);

      // 4) Onboarding 3-step ribbon + '稍后再说' skip button + Settings readiness strip
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: const OnboardingPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('环境初始化向导'), findsOneWidget);
      expect(find.text('稍后再说'), findsOneWidget);
      expect(find.text('1. 准备环境'), findsOneWidget);
      expect(find.text('2. 配置模型'), findsOneWidget);
      expect(find.text('3. 开始对话'), findsOneWidget);

      // 5) SettingsPage compact readiness strip + natural keyword search ('无障碍' / '中转')
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: SettingsPage(onOpenWebUi: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('快速就绪'), findsOneWidget);

      await tester.enterText(find.byType(EditableText).first, '中转');
      await tester.pumpAndSettle();
      expect(find.text('模型与渠道'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'v14 Fluidity: solid/frosted glass contracts, streaming long code block stays expanded after completion, incremental Markdown settling & toast unmount',
    (tester) async {
      // 1) Glass tier performance contracts: solid has blur == 0.0 & no shadows; frosted has saturation == 1.0
      for (final b in [Brightness.light, Brightness.dark]) {
        final t = GrassBagTokens.resolve(GrassBagAccent.teal, b);
        final solidSurf = GrassBagGlassConfig.surfaceSettings(t, GrassBagGlassTier.solid);
        final solidSheet = GrassBagGlassConfig.sheetSettings(t, GrassBagGlassTier.solid);
        expect(solidSurf.blur, 0.0);
        expect(solidSurf.saturation, 1.0);
        expect(solidSurf.shadow, isEmpty);
        expect(solidSheet.blur, 0.0);
        expect(solidSheet.saturation, 1.0);
        expect(solidSheet.shadow, isEmpty);

        final frostedSurf = GrassBagGlassConfig.surfaceSettings(t, GrassBagGlassTier.frosted);
        final frostedSheet = GrassBagGlassConfig.sheetSettings(t, GrassBagGlassTier.frosted);
        expect(frostedSurf.saturation, 1.0);
        expect(frostedSheet.saturation, 1.0);
      }

      // 2) Streaming 50-line code block stays expanded when stream completes (ZERO 300px collapse jump!),
      //    while a freshly mounted historical 50-line code block still defaults to collapsed!
      final longCodeLines = List.generate(50, (i) => 'final v$i = $i;').join('\n');
      final mdText =
          '第一段说明文本，用来验证超过 160 字符后前导段落会自动沉淀到独立 RepaintBoundary。\n\n'
          '第二段说明文本，包含内联 **加粗** 与 `code` 与表格：\n\n'
          '| 列A | 列B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n\n'
          '```dart\n$longCodeLines\n```';

      final streamingTurn = NormalizedTurn(
        turnId: 't-fluid-stream',
        seqStart: 1,
        seqEnd: 1,
        status: 'streaming',
        assistantText: mdText,
      );
      final completedTurn = streamingTurn.copyWith(status: 'completed');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appProvider.notifier).setGlassTier(GrassBagGlassTier.solid);

      Widget wrapTurn(NormalizedTurn turn) => UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: TurnView(turn: turn, onOpenTerminal: () {}),
                ),
              ),
            ),
          );

      await tester.pumpWidget(wrapTurn(streamingTurn));
      // Advance typewriter until full 50-line code block is revealed while still streaming
      for (var f = 0; f < 30; f++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull);
      expect(find.textContaining('展开剩余'), findsNothing);

      // Stream finishes -> code block MUST remain expanded (no sudden collapse jump!)
      await tester.pumpWidget(wrapTurn(completedTurn));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('展开剩余'), findsNothing);

      // Fresh historical 50-line code block mounted directly as completed MUST default to collapsed!
      final historicalTurn = NormalizedTurn(
        turnId: 't-fluid-history',
        seqStart: 2,
        seqEnd: 2,
        status: 'completed',
        assistantText: '```dart\n$longCodeLines\n```',
      );
      await tester.pumpWidget(wrapTurn(historicalTurn));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('展开剩余 26 行'), findsOneWidget);

      // 3) GrassBagToastOverlay renders toast when present and unmounts cleanly when dismissed
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: const Scaffold(
              body: Stack(
                children: [
                  SizedBox.expand(),
                  GrassBagToastOverlay(bottomOffset: 24),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      container.read(appProvider.notifier).showToast('流畅性测试提示');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('流畅性测试提示'), findsOneWidget);

      // Wait for auto-dismiss timer + exit animation -> toast host unmounts completely
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('流畅性测试提示'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );
}

class _MountCountingChild extends StatefulWidget {
  const _MountCountingChild({required this.onInit});
  final VoidCallback onInit;

  @override
  State<_MountCountingChild> createState() => _MountCountingChildState();
}

class _MountCountingChildState extends State<_MountCountingChild> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(12),
      child: Text('stateful-child'),
    );
  }
}
