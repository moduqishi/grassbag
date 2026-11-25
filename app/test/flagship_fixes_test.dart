import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbridge_client/gbridge_client.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'package:grassbag/services/app_update_service.dart';
import 'package:grassbag/services/models_dev_service.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/theme/grassbag_glass.dart';
import 'package:grassbag/theme/grassbag_theme.dart';
import 'package:grassbag/ui/chat/chat_empty_state.dart';
import 'package:grassbag/ui/chat/composer_bar.dart';
import 'package:grassbag/ui/chat/turn_process_widget.dart';
import 'package:grassbag/ui/features/schedules_page.dart';
import 'package:grassbag/ui/onboarding/launch_splash_overlay.dart';
import 'package:grassbag/ui/sdui/schemastery_form.dart';
import 'package:grassbag/ui/sdui/sdui_renderer.dart';
import 'package:grassbag/ui/settings/model_config_view.dart';
import 'package:grassbag/ui/settings/settings_page.dart';
import 'package:grassbag/ui/shell/grassbag_shell.dart';

void main() {
  setUpAll(() {
    GrassBagController.disableAutoAppUpdateCheck = true;
  });

  group('ModelsDevCatalogService & 7-level effort localization', () {
    tearDown(() => ModelsDevCatalogService.instance.clearCache());

    test('parses real models.dev api.json schema and fuzzy-matches models cleanly', () async {
      final rawJson = jsonEncode({
        'anthropic': {
          'id': 'anthropic',
          'name': 'Anthropic',
          'models': {
            'claude-sonnet-4-5': {
              'id': 'claude-sonnet-4-5',
              'name': 'Claude Sonnet 4.5',
              'attachment': true,
              'reasoning': true,
              'reasoning_options': [
                {
                  'type': 'effort',
                  'values': ['low', 'medium', 'high', 'max'],
                }
              ],
              'modalities': {
                'input': ['text', 'image', 'pdf'],
              },
              'limit': {'context': 200000, 'output': 64000},
            },
          },
        },
        'deepseek': {
          'id': 'deepseek',
          'name': 'DeepSeek',
          'models': {
            'deepseek-reasoner': {
              'id': 'deepseek-reasoner',
              'name': 'DeepSeek Reasoner',
              'attachment': false,
              'reasoning': true,
              'modalities': {
                'input': ['text'],
              },
              'limit': {'context': 131072, 'output': 32768},
            },
          },
        },
      });

      final specs = ModelsDevCatalogService.parseCatalogJson(rawJson);
      expect(specs.length, 2);

      final claude = await ModelsDevCatalogService.instance.lookupModel(
        'claude-sonnet-4.5',
        fetcher: (_) async => rawJson,
      );
      expect(claude, isNotNull);
      expect(claude!.id, 'claude-sonnet-4-5');
      expect(claude.name, 'Claude Sonnet 4.5');
      expect(claude.contextWindow, 200000);
      expect(claude.maxOutputTokens, 64000);
      expect(claude.reasoning, true);
      expect(claude.supportsImage, true);
      expect(claude.reasoningEfforts, ['low', 'medium', 'high', 'max']);

      final ds = await ModelsDevCatalogService.instance.lookupModel(
        'deepseek/deepseek-reasoner',
        fetcher: (_) async => rawJson,
      );
      expect(ds, isNotNull);
      expect(ds!.contextWindow, 131072);
      expect(ds.maxOutputTokens, 32768);
      expect(ds.supportsImage, false);

      final suggestions = await ModelsDevCatalogService.instance.searchSuggestions('claude');
      expect(suggestions, isNotEmpty);
      expect(suggestions.first.id, 'claude-sonnet-4-5');
    });

    test('ModelEffortOption localizes all 7 DSH canonical thinking levels cleanly', () {
      const expected = {
        'off': '关闭',
        'minimal': '极轻',
        'low': '低',
        'medium': '中',
        'high': '高',
        'xhigh': '超高',
        'max': '极高',
      };
      for (final entry in expected.entries) {
        final opt = ModelEffortOption(id: entry.key, name: entry.key);
        expect(opt.zhLabel, entry.value, reason: 'Level ${entry.key}');
      }
    });
  });

  group('DSH 0.2.2-rc.5 GoalProjection & ScheduleTaskRecord fidelity', () {
    test('SessionGoalRecord unwraps nested GoalProjection and preserves blocked/disarmed state without fake 15%', () {
      final projGoal = SessionGoalRecord.fromJson({
        'goal': {
          'id': 'g-101',
          'revision': 5,
          'objective': '完成全部端到端测试\n验收标准：零报错且截图清晰',
          'phase': 'blocked',
          'activation': 'disarmed',
          'blockedReason': {
            'code': 'NEEDS_APPROVAL',
            'message': '等待用户确认危险命令',
          },
          'maxGoalRounds': 10,
        },
        'roundsStarted': 3,
      });

      expect(projGoal.id, 'g-101');
      expect(projGoal.revision, 5);
      expect(projGoal.title, '完成全部端到端测试');
      expect(projGoal.criteria, '零报错且截图清晰');
      expect(projGoal.isBlocked, true);
      expect(projGoal.blockedReasonCode, 'NEEDS_APPROVAL');
      expect(projGoal.blockedReasonMessage, '等待用户确认危险命令');
      expect(projGoal.roundsStarted, 3);
      expect(projGoal.maxGoalRounds, 10);
      expect(projGoal.progressPct, 30);

      final unboundedActive = SessionGoalRecord.fromJson({
        'id': 'g-102',
        'objective': '持续优化性能',
        'phase': 'active',
        'activation': 'armed',
        'roundsStarted': 2,
      });
      expect(unboundedActive.isArmed, true);
      expect(unboundedActive.progressPct, 0);
      expect(unboundedActive.statusLabel, '已推进 2 轮');

      final disarmedActive = SessionGoalRecord.fromJson({
        'id': 'g-103',
        'objective': '恢复后继续推进',
        'phase': 'active',
        'activation': 'disarmed',
      });
      expect(disarmedActive.isDisarmed, true);
      expect(disarmedActive.isArmed, false);
      expect(disarmedActive.statusLabel, '待恢复');
    });

    test('ScheduleTaskRecord handles ended, weekly weekdays, and rrule schedules cleanly', () {
      final endedOneShot = ScheduleTaskRecord.fromJson({
        'id': 'sched-ended',
        'kind': 'at',
        'title': '一次性提醒',
        'prompt': '检查构建',
        'status': 'ended',
        'scheduledAt': '2026-11-24T08:00:00.000Z',
      });
      expect(endedOneShot.isEnded, true);
      expect(endedOneShot.enabled, false);
      expect(endedOneShot.kind, 'at');
      expect(endedOneShot.nextRunAt, isNotEmpty);

      final weekly = ScheduleTaskRecord.fromJson({
        'id': 'sched-weekly',
        'kind': 'weekly',
        'title': '周报汇总',
        'prompt': '汇总提交',
        'status': 'active',
        'weekdays': ['mon', 'fri'],
        'time': '18:00',
      });
      expect(weekly.kind, 'weekly');
      expect(weekly.enabled, true);
      expect(weekly.humanSchedule, contains('mon,fri'));

      final rrule = ScheduleTaskRecord.fromJson({
        'id': 'sched-rrule',
        'kind': 'rrule',
        'title': '月初结算',
        'prompt': '生成月报',
        'status': 'active',
        'rrule': 'FREQ=MONTHLY;BYMONTHDAY=1',
      });
      expect(rrule.kind, 'rrule');
      expect(rrule.cronExpr, 'FREQ=MONTHLY;BYMONTHDAY=1');
      expect(rrule.humanSchedule, contains('RRule'));
    });
  });

  group('Empty-state keyboard morph, right-edge alignment & Liquid Glass controls', () {
    testWidgets('ChatEmptyState smoothly hides 4 starter cards when keyboard rises while keeping greeting', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final container = ProviderContainer();
      addTearDown(container.dispose);

      Widget buildStage(double kbProgress) => UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: ChatEmptyState(
                  keyboardProgress: kbProgress,
                  onSuggestionTap: (_) {},
                  onOpenModelSettings: () {},
                  onOpenHostSettings: () {},
                ),
              ),
            ),
          );

      await tester.pumpWidget(buildStage(0.0));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('看看工作区'), findsOneWidget);

      await tester.pumpWidget(buildStage(1.0));
      await tester.pump(const Duration(milliseconds: 200));
      // Starter cards & rotating tip skip painting via Visibility(visible: false, maintainSize: true)
      // + FadeTransition(0.0) when keyboard is open, while keeping greeting visible.
      expect(find.text('今天想做点什么？'), findsOneWidget);
      final cardVisibilities = tester.widgetList<Visibility>(
        find.ancestor(of: find.text('看看工作区'), matching: find.byType(Visibility)),
      );
      expect(cardVisibilities.any((v) => !v.visible), isTrue);
      final controlledOpacities = tester.widgetList<GrassBagControlledOpacity>(
        find.byType(GrassBagControlledOpacity),
      );
      expect(controlledOpacities.any((c) => c.opacity == 0.0), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Plus deck 角色预设 / 操作权限 trailing labels flush to right edge matching switch', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final textCtrl = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(textCtrl.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
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
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('composer-plus-btn')));
      await tester.pump(const Duration(milliseconds: 350));

      final roleRowText = tester.getRect(find.text('角色预设'));
      final chevrons = find.byIcon(CupertinoIcons.chevron_right);
      expect(chevrons, findsAtLeastNWidgets(2));
      final firstChevronRect = tester.getRect(chevrons.first);
      final switchRect = tester.getRect(find.byType(GrassBagGlassSwitch));

      // Right edge of chevron must sit near the right edge of the switch (within 14px), NOT in the middle!
      expect((switchRect.right - firstChevronRect.right).abs(), lessThan(14.0));
      expect(firstChevronRect.left - roleRowText.right, greaterThan(120.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('showGrassBagGlassContextMenu renders items and fires action cleanly', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: GrassBagPrimaryGlassButton(
                  label: '打开菜单',
                  tier: GrassBagGlassTier.frosted,
                  onTap: () {
                    showGrassBagGlassContextMenu(
                      ctx,
                      tier: GrassBagGlassTier.frosted,
                      globalAnchor: const Offset(200, 200),
                      headerTitle: '操作菜单',
                      items: [
                        GrassBagContextMenuItem(
                          label: '置顶对话',
                          icon: CupertinoIcons.pin_fill,
                          onTap: () => tapped = true,
                        ),
                        GrassBagContextMenuItem(
                          label: '删除对话',
                          icon: CupertinoIcons.trash_fill,
                          destructive: true,
                          dividerBefore: true,
                          onTap: () {},
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开菜单'));
      await tester.pumpAndSettle();
      expect(find.text('操作菜单'), findsOneWidget);
      expect(find.text('置顶对话'), findsOneWidget);
      expect(find.text('删除对话'), findsOneWidget);

      await tester.tap(find.text('置顶对话'));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'GrassBagShell keyboard open/close animates smoothly on snap IME with strictly monotonic hero Y and zero jitter',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(412, 915));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final ctrl = container.read(appProvider.notifier);
        ctrl.state = ctrl.state.copyWith(
          glassTier: GrassBagGlassTier.solid,
          onboardingCompleted: true,
        );

        Widget buildShell(double kbBottom) => UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: const Size(412, 915),
                    viewPadding: const EdgeInsets.only(top: 44, bottom: 24),
                    viewInsets: EdgeInsets.only(bottom: kbBottom),
                  ),
                  child: const GrassBagShell(),
                ),
              ),
            );

        await tester.pumpWidget(buildShell(0.0));
        await tester.pumpAndSettle();

        final heroFinder = find.text('今天想做点什么？');
        final composerFinder = find.byType(TextField);
        expect(heroFinder, findsOneWidget);

        final heroYClosed = tester.getTopLeft(heroFinder).dy;
        final composerYClosed = tester.getBottomLeft(composerFinder).dy;

        // 1. Simulate Android OEM single-frame snap keyboard jump (0 -> 310px)
        await tester.pumpWidget(buildShell(310.0));
        final openSamplesHero = <double>[heroYClosed];
        final openSamplesComposer = <double>[composerYClosed];
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          openSamplesHero.add(tester.getTopLeft(heroFinder).dy);
          openSamplesComposer.add(tester.getBottomLeft(composerFinder).dy);
        }
        await tester.pumpAndSettle();
        final heroYOpen = tester.getTopLeft(heroFinder).dy;
        final composerYOpen = tester.getBottomLeft(composerFinder).dy;
        openSamplesHero.add(heroYOpen);
        openSamplesComposer.add(composerYOpen);

        // Must animate smoothly across intermediate frames (NOT teleport in 1 frame!)
        expect(openSamplesComposer[2], lessThan(composerYClosed - 15.0));
        expect(openSamplesComposer[2], greaterThan(composerYOpen + 30.0));
        expect(composerYOpen, lessThan(composerYClosed - 260.0));

        // Hero MUST glide monotonically upward with ZERO down-then-up direction reversal!
        expect(heroYOpen, lessThan(heroYClosed - 10.0));
        for (var i = 1; i < openSamplesHero.length; i++) {
          expect(
            openSamplesHero[i],
            lessThanOrEqualTo(openSamplesHero[i - 1] + 0.5),
            reason: 'Hero bounced downward at frame $i: ${openSamplesHero[i - 1]} -> ${openSamplesHero[i]}',
          );
        }

        // 2. Simulate Android OEM single-frame snap keyboard close (310 -> 0px)
        await tester.pumpWidget(buildShell(0.0));
        final closeSamplesHero = <double>[heroYOpen];
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          closeSamplesHero.add(tester.getTopLeft(heroFinder).dy);
        }
        await tester.pumpAndSettle();
        final heroYRestored = tester.getTopLeft(heroFinder).dy;
        closeSamplesHero.add(heroYRestored);

        // Hero MUST glide monotonically downward back to exact resting Y!
        for (var i = 1; i < closeSamplesHero.length; i++) {
          expect(
            closeSamplesHero[i],
            greaterThanOrEqualTo(closeSamplesHero[i - 1] - 0.5),
            reason: 'Hero bounced upward while closing at frame $i: ${closeSamplesHero[i - 1]} -> ${closeSamplesHero[i]}',
          );
        }
        expect((heroYRestored - heroYClosed).abs(), lessThan(2.0));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Model pill NEVER flashes 未连接 during ConnectionPhase.reconnecting & iOS 26/27 spherical-chrome / paraxial-sheet glass optics contract holds',
      (tester) async {
        // 1. iOS 26/27 spherical zero-frost chrome (zero isClearIndicator dark-rim burn) &
        //    iOS 27 paraxial frosted sheet cloud (zero wasted double backdrop blur) contracts
        for (final brightness in [Brightness.light, Brightness.dark]) {
          final tok = GrassBagTokens.resolve(GrassBagAccent.teal, brightness);
          final surf = GrassBagGlassConfig.surfaceSettings(tok, GrassBagGlassTier.liquid);
          final sheet = GrassBagGlassConfig.sheetSettings(tok, GrassBagGlassTier.liquid);
          expect(surf.lensModel, GlassLensModel.spherical);
          expect(surf.chromaticAberration, 0.0);
          expect(sheet.lensModel, GlassLensModel.paraxial);
          expect(sheet.blur, 0.0);
          expect(sheet.frostOpacity, 1.0);
          expect(sheet.frost, greaterThanOrEqualTo(14.0));
          expect(surf.lightIntensity, lessThanOrEqualTo(0.25));
        }

        // 2. Composer model pill during ConnectionPhase.reconnecting keeps showing cached model
        //    (and shows 重连中… when no models loaded yet) — NEVER flashes 未连接!
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final ctrl = container.read(appProvider.notifier);
        final textCtrl = TextEditingController();
        final focusNode = FocusNode();
        addTearDown(textCtrl.dispose);
        addTearDown(focusNode.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
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

        // Case A: Reconnecting with already-loaded model -> stays on DeepSeek-V4.1!
        ctrl.state = ctrl.state.copyWith(
          connectionPhase: ConnectionPhase.reconnecting,
          activeModelProvider: 'deepseek-official',
          activeModelId: 'deepseek-v4',
          modelName: 'DeepSeek-V4.1',
          modelShort: 'DeepSeek-V4.1',
          modelEffort: '极高',
          modelGroups: const [
            ModelCatalogGroup(
              id: 'deepseek-official',
              name: 'DeepSeek',
              routable: true,
              models: [
                ModelCatalogEntry(
                  id: 'deepseek-v4',
                  name: 'DeepSeek-V4.1',
                  providerId: 'deepseek-official',
                  providerName: 'DeepSeek',
                ),
              ],
            ),
          ],
        );
        await tester.pumpAndSettle();
        expect(find.text('DeepSeek-V4.1'), findsOneWidget);
        expect(find.text('未连接'), findsNothing);

        // Case B: Reconnecting BEFORE any model hydrated -> shows 重连中…, NEVER 未连接!
        ctrl.state = ctrl.state.copyWith(
          connectionPhase: ConnectionPhase.reconnecting,
          activeModelId: '',
          modelGroups: const [],
        );
        await tester.pumpAndSettle();
        expect(find.text('重连中…'), findsOneWidget);
        expect(find.text('未连接'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Phone control prefs default ON, toggle cleanly, and TurnView renders dedicated Chinese verbs for phone_* steps',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final ctrl = container.read(appProvider.notifier);

        expect(container.read(appProvider).phoneAutoReturn, isTrue);
        expect(container.read(appProvider).phoneShowEdgeAurora, isTrue);
        expect(container.read(appProvider).phoneShowGestureFx, isTrue);

        ctrl.setPhoneSetting(autoReturn: false, showEdgeAurora: false, showGestureFx: false);
        expect(container.read(appProvider).phoneAutoReturn, isFalse);
        expect(container.read(appProvider).phoneShowEdgeAurora, isFalse);
        expect(container.read(appProvider).phoneShowGestureFx, isFalse);

        const phoneTurn = NormalizedTurn(
          turnId: 'turn-phone-ux',
          status: 'completed',
          userMessage: NormalizedUserMessage(id: 'u-p1', text: '打开计算器并点击 9'),
          steps: [
            ToolStep(
              callId: 'c1',
              name: 'phone_open',
              title: 'phone_open · 计算器',
              status: 'ok',
              summary: '{"ok":true}',
            ),
            ToolStep(
              callId: 'c2',
              name: 'phone_tap',
              title: 'phone_tap · 9',
              status: 'ok',
              summary: '{"ok":true}',
            ),
            ToolStep(
              callId: 'c3',
              name: 'phone_swipe',
              title: 'phone_swipe · 滑动屏幕',
              status: 'ok',
              summary: '{"ok":true}',
            ),
            ToolStep(
              callId: 'c4',
              name: 'phone_return_app',
              title: 'phone_return_app · 返回 GrassBag',
              status: 'ok',
              summary: '{"ok":true}',
            ),
          ],
          assistantText: '已打开计算器并点击 9，现在已返回 GrassBag。',
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TurnView(turn: phoneTurn, onOpenTerminal: () {}),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Expand collapsed process summary (autoFoldSteps defaults to true)
        await tester.tap(find.textContaining('4 项操作'));
        await tester.pumpAndSettle();

        expect(find.text('打开'), findsOneWidget);
        expect(find.text('点按'), findsOneWidget);
        expect(find.text('滑动'), findsOneWidget);
        expect(find.text('返回'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'UX polish regressions: humanized tool pills, cancelled badge, Chinese error card hides empty process rail, and Unix path avoids slash hijack',
      (tester) async {
        // 1) Error classifier + paren formatting check
        final transport = GrassBagController.classifyReadableError(
          'DeepSeek Messages transport failed',
          code: 'TRANSPORT',
        );
        expect(transport.title, '连接中断或主机不可达');
        expect(transport.actionKind, 'host');

        final ctxErr = GrassBagController.classifyReadableError(
          'maximum context length exceeded',
        );
        expect(ctxErr.title, '上下文长度已达上限');
        expect(ctxErr.actionKind, 'compact');

        expect(
          GrassBagController.formatReadableError(
            const GbridgeException(message: '服务异常', code: '', status: 503),
          ),
          '服务异常 (HTTP 503)',
        );

        // 2) 0-step failed turn with only an error NoticeStep hides empty process rail
        //    and displays friendly Chinese guidance + collapsible tech detail.
        final container = ProviderContainer();
        addTearDown(container.dispose);

        const failedTurn = NormalizedTurn(
          turnId: 'turn-err-polish',
          status: 'error',
          userMessage: NormalizedUserMessage(id: 'u-e1', text: '测试失败态'),
          steps: [
            NoticeStep(level: 'error', text: '[TRANSPORT] DeepSeek Messages transport failed'),
          ],
          errorCode: 'TRANSPORT',
          errorMessage: 'DeepSeek Messages transport failed',
        );

        const toolPolishTurn = NormalizedTurn(
          turnId: 'turn-tool-polish',
          status: 'completed',
          userMessage: NormalizedUserMessage(id: 'u-t1', text: '检查工具展示'),
          steps: [
            ToolStep(
              callId: 't-open',
              name: 'phone_open',
              title: 'phone_open',
              status: 'ok',
              summary: '{"ok":true,"package":"com.android.deskclock","opened":"时钟"}',
            ),
            ToolStep(
              callId: 't-todo',
              name: 'todo_write',
              title: 'todo_write · 更新进度',
              status: 'ok',
              summary: '{"ok":true}',
            ),
            ToolStep(
              callId: 't-cancel',
              name: 'bash',
              title: 'bash · sleep 10',
              status: 'cancelled',
              summary: '',
            ),
          ],
          assistantText: '检查完成。',
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TurnView(turn: failedTurn, onOpenTerminal: () {}),
                    TurnView(turn: toolPolishTurn, onOpenTerminal: () {}),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Empty `! 执行遇到错误` process header MUST NOT mount for 0-step error turn!
        expect(find.text('执行遇到错误'), findsNothing);
        expect(find.text('连接中断或主机不可达'), findsOneWidget);
        expect(find.text('技术详情'), findsOneWidget);
        expect(find.text('检查主机'), findsOneWidget);
        // Raw English error stays tucked behind disclosure until expanded
        expect(find.textContaining('DeepSeek Messages transport failed'), findsNothing);
        await tester.tap(find.text('技术详情'));
        await tester.pumpAndSettle();
        expect(find.textContaining('DeepSeek Messages transport failed'), findsOneWidget);

        // Expand tool polish turn: no raw `phone_open` or `{"ok":true...}`, todo_write is 待办, cancelled is 已中断!
        await tester.tap(find.textContaining('3 项操作'));
        await tester.pumpAndSettle();
        expect(find.text('phone_open'), findsNothing);
        expect(find.textContaining('{"ok":true'), findsNothing);
        expect(find.text('时钟'), findsOneWidget);
        expect(find.text('待办'), findsOneWidget);
        expect(find.text('已中断'), findsOneWidget);
        expect(find.text('失败'), findsNothing);

        // 3) Composer `/` popover must NOT hijack Unix file paths like `/etc/hosts`
        final composerCtrl = TextEditingController();
        final composerFocus = FocusNode();
        addTearDown(() {
          composerCtrl.dispose();
          composerFocus.dispose();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: ChatComposerDock(
                    controller: composerCtrl,
                    focusNode: composerFocus,
                    onOpenTerminal: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        composerCtrl.text = '/etc/hosts';
        composerCtrl.selection = const TextSelection.collapsed(offset: 10);
        await tester.pumpAndSettle();
        expect(find.textContaining('快捷指令'), findsNothing);

        composerCtrl.text = '/comp';
        composerCtrl.selection = const TextSelection.collapsed(offset: 5);
        await tester.pumpAndSettle();
        expect(find.textContaining('快捷指令'), findsOneWidget);
        // Drain debounced draft persistence timer cleanly before tearDown.
        await tester.pump(const Duration(milliseconds: 1400));
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('v27 Flagship UX, Glass, Markdown & Reliability regressions', () {
    double contrastRatio(Color fg, Color bg) {
      final l1 = fg.computeLuminance();
      final l2 = bg.computeLuminance();
      final hi = l1 > l2 ? l1 : l2;
      final lo = l1 > l2 ? l2 : l1;
      return (hi + 0.05) / (lo + 0.05);
    }

    test('all 6 Light and 6 Dark themes satisfy WCAG AA contrast for status & tertiary text', () {
      for (final accent in GrassBagAccent.values) {
        final light = GrassBagTokens.resolve(accent, Brightness.light);
        expect(contrastRatio(light.ok, light.cardSolid), greaterThanOrEqualTo(4.5), reason: 'Light $accent ok');
        expect(contrastRatio(light.warn, light.cardSolid), greaterThanOrEqualTo(4.5), reason: 'Light $accent warn');
        expect(contrastRatio(light.text3, light.cardSolid), greaterThanOrEqualTo(4.5), reason: 'Light $accent text3');

        final dark = GrassBagTokens.resolve(accent, Brightness.dark);
        expect(contrastRatio(dark.err, dark.cardSolid), greaterThanOrEqualTo(4.5), reason: 'Dark $accent err');
        expect(contrastRatio(dark.text3, dark.cardSolid), greaterThanOrEqualTo(4.5), reason: 'Dark $accent text3');
      }
    });

    test('exportConfigJson strips query tokens completely and offline send creates zero ghost sessions', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);

      // Add a remote host containing a query token, then verify export strips `?token=` completely
      // (regression for Dart Uri.replace(queryParameters: null) no-op bug).
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      ctrl.state = ctrl.state.copyWith(
        hosts: [
          ...ctrl.state.hosts,
          const ManagedHost(
            id: 'remote-tok-test',
            name: 'TestMac',
            address: 'http://192.168.1.99:3081/?token=SECRET_SHOULD_STRIP',
            token: 'SECRET_SHOULD_STRIP',
            isLocal: false,
            online: false,
            bridged: false,
            latency: '--',
          ),
        ],
      );
      final exported = ctrl.exportConfigJson();
      expect(exported, isNot(contains('SECRET_SHOULD_STRIP')));
      expect(exported, isNot(contains('?token=')));

      // Offline send renders honest notice turn WITHOUT creating a pending-session-* ghost in state.sessions!
      final initialSessionCount = container.read(appProvider).sessions.length;
      await ctrl.sendPrompt('离线测试消息');
      final afterOffline = container.read(appProvider);
      expect(afterOffline.sessions.length, initialSessionCount);
      expect(afterOffline.sessions.any((s) => s.id.startsWith('pending-session-')), isFalse);
      expect(afterOffline.turns, isNotEmpty);
      expect(afterOffline.isEmptyChat, isFalse);

      // cancelStreaming clears pending approval & question takeovers cleanly
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      ctrl.state = ctrl.state.copyWith(
        isStreaming: true,
        pendingApprovalCommand: 'rm -rf /tmp/x',
        pendingApprovalInteractionId: 'ia-1',
        pendingApprovalToolName: 'bash',
      );
      ctrl.cancelStreaming(announce: false);
      final afterCancel = container.read(appProvider);
      expect(afterCancel.isStreaming, isFalse);
      expect(afterCancel.pendingApprovalCommand, isNull);
      expect(afterCancel.pendingApprovalInteractionId, isNull);
    });

    test('isValidCron5Field validates numeric ranges and SessionTelemetry.remainingContextTokens handles zero pressure', () {
      expect(isValidCron5Field('0 9 * * *'), isTrue);
      expect(isValidCron5Field('30 18 * * 1-5'), isTrue);
      expect(isValidCron5Field('0 */6 * * *'), isTrue);
      expect(isValidCron5Field('99 9 * * *'), isFalse);
      expect(isValidCron5Field('0 25 * * *'), isFalse);
      expect(isValidCron5Field('0 9 32 * *'), isFalse);
      expect(isValidCron5Field('0 9 * 13 *'), isFalse);
      expect(isValidCron5Field('0 9 * * 9'), isFalse);

      const zeroTelemetry = SessionTelemetry(contextWindow: 128000);
      expect(zeroTelemetry.remainingContextTokens, 0);
    });

    testWidgets(
      'TurnView renders DeepSeek LaTeX delimiters, balanced links, tool-only completed turns without false cancel, and cancelled partial badge',
      (WidgetTester tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final latexAndLinksTurn = NormalizedTurn(
          turnId: 'turn-latex-v27',
          status: 'completed',
          userMessage: const NormalizedUserMessage(id: 'u-latex', text: '公式和链接'),
          assistantText:
              r'Inline math \(a^2 + b^2 = c^2\) and block:\n\[\int_0^1 x^2 dx = \frac{1}{3}\]\n\nCheck [Wiki (v2)](https://en.wikipedia.org/wiki/Foo_(bar)).',
        );
        const toolOnlyTurn = NormalizedTurn(
          turnId: 'turn-tool-only-v27',
          status: 'completed',
          userMessage: NormalizedUserMessage(id: 'u-tool', text: '仅工具完成'),
          assistantText: '',
          steps: [
            ToolStep(
              callId: 'tc-1',
              name: 'bash',
              title: '运行检查',
              status: 'done',
              summary: '全部通过',
            ),
          ],
        );
        const cancelledPartialTurn = NormalizedTurn(
          turnId: 'turn-cancelled-partial-v27',
          status: 'cancelled',
          userMessage: NormalizedUserMessage(id: 'u-cp', text: '中途取消'),
          assistantText: '这是已经输出到一半的回答',
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
                      TurnView(turn: latexAndLinksTurn, onOpenTerminal: () {}),
                      TurnView(turn: toolOnlyTurn, onOpenTerminal: () {}),
                      TurnView(turn: cancelledPartialTurn, onOpenTerminal: () {}),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('a^2 + b^2 = c^2', findRichText: true), findsOneWidget);
        expect(find.textContaining('Wiki (v2)', findRichText: true), findsOneWidget);
        expect(find.textContaining('这是已经输出到一半的回答', findRichText: true), findsOneWidget);
        // Only the explicitly cancelled turn shows '已停止生成' — the tool-only completed turn must NOT!
        expect(find.text('已停止生成'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Solid tier glass controls and Dark Mode GrassBagGlass render crisply with outer shadow',
      (WidgetTester tester) async {
        var sw = true;
        var seg = 1;
        var sliderVal = 0.5;
        await tester.pumpWidget(
          MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
            home: StatefulBuilder(
              builder: (context, setState) => Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      GrassBagGlass(
                        tier: GrassBagGlassTier.liquid,
                        borderRadius: 20,
                        padding: const EdgeInsets.all(12),
                        child: const Text('Dark Glass Box'),
                      ),
                      GrassBagGlassSwitch(
                        value: sw,
                        tier: GrassBagGlassTier.solid,
                        onChanged: (v) => setState(() => sw = v),
                      ),
                      GrassBagSegmentedControl(
                        labels: const ['一', '二', '三'],
                        selectedIndex: seg,
                        tier: GrassBagGlassTier.solid,
                        onSelected: (i) => setState(() => seg = i),
                      ),
                      GrassBagGlassSlider(
                        value: sliderVal,
                        min: 0,
                        max: 1,
                        tier: GrassBagGlassTier.solid,
                        onChanged: (v) => setState(() => sliderVal = v),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Tap solid switch and solid segment
        await tester.tap(find.byType(GrassBagGlassSwitch));
        await tester.pumpAndSettle();
        expect(sw, isFalse);

        await tester.tap(find.text('三'));
        await tester.pumpAndSettle();
        expect(seg, 2);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'v28 regression: SquircleIcon white-on-green contrast, compact SecondaryGlassButton in Wrap, models.dev canonical dedup, SemVer prereleases, wildcard secrets & protocol allowlist',
      (WidgetTester tester) async {
        // 1) GrassBagSquircleIcon raises luminance threshold to 0.38 so green badges get crisp white icons
        await tester.pumpWidget(
          MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: Scaffold(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const GrassBagSquircleIcon(
                    icon: CupertinoIcons.doc_fill,
                    color: Color(0xFF1A8F56),
                    filled: true,
                  ),
                  SizedBox(
                    width: 360,
                    child: Wrap(
                      spacing: 8,
                      children: [
                        GrassBagSecondaryGlassButton(
                          label: '短按钮',
                          tier: GrassBagGlassTier.solid,
                          insideGlass: true,
                          onTap: () {},
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final iconWidget = tester.widget<Icon>(find.byIcon(CupertinoIcons.doc_fill));
        expect(iconWidget.color, Colors.white);
        final btnSize = tester.getSize(find.byType(GrassBagSecondaryGlassButton));
        expect(btnSize.width, lessThan(200), reason: 'SecondaryGlassButton must stay compact inside Wrap');

        // 2) ModelsDevCatalogService: canonical primary provider beats aggregator duplicate,
        //    provider-prefixed queries & 2-char prefixes (`o1`) resolve cleanly
        ModelsDevCatalogService.instance.seedForTest(const [
          ModelsDevSpec(
            id: 'gpt-5',
            providerId: 'openrouter',
            providerName: 'OpenRouter',
            name: 'GPT-5 (OR)',
            contextWindow: 128000,
          ),
          ModelsDevSpec(
            id: 'gpt-5',
            providerId: 'openai',
            providerName: 'OpenAI',
            name: 'GPT-5',
            contextWindow: 400000,
          ),
          ModelsDevSpec(
            id: 'o1-pro',
            providerId: 'openai',
            providerName: 'OpenAI',
            name: 'o1 Pro',
            contextWindow: 200000,
          ),
        ]);
        addTearDown(ModelsDevCatalogService.instance.clearCache);
        final sugs = await ModelsDevCatalogService.instance.searchSuggestions('openai/gpt-5');
        expect(sugs.first.providerId, 'openai');
        expect(sugs.first.contextWindow, 400000);
        final o1Sugs = await ModelsDevCatalogService.instance.searchSuggestions('o1');
        expect(o1Sugs.map((e) => e.id), contains('o1-pro'));

        // 3) SemVer §11 numeric prerelease comparison (`rc.10 > rc.2`, stable > prerelease)
        //    and prerelease APK buildNumber parsing
        expect(
          compareAppVersions(parseAppVersion('1.0.0-rc.10')!, parseAppVersion('1.0.0-rc.2')!),
          greaterThan(0),
        );
        expect(
          compareAppVersions(parseAppVersion('1.0.0')!, parseAppVersion('1.0.0-rc.10')!),
          greaterThan(0),
        );
        final preRel = AppReleaseInfo.fromGitHubReleaseJson({
          'tag_name': 'v0.9.0-beta.4',
          'name': 'Beta 4',
          'body': 'notes',
          'html_url': 'https://github.com/moduqishi/grassbag/releases/tag/v0.9.0-beta.4',
          'prerelease': true,
          'assets': [
            {
              'name': 'GrassBag-v0.9.0-beta.4-b42-arm64.apk',
              'browser_download_url': 'https://example.com/a.apk',
              'size': 123456,
            },
          ],
        });
        expect(preRel, isNotNull);
        expect(preRel!.versionName, '0.9.0-beta.4');
        expect(preRel.buildNumber, 42);

        // 4) Schemastery wildcard secret paths protect redacted nested keys on save
        expect(
          matchesSchemasterySecretPath(
            const ['providers', 'myRelay', 'apiKey'],
            const ['providers.*.apiKey'],
          ),
          isTrue,
        );
        final ops = computeSchemasteryMutationOps(
          {
            'providers': {
              'myRelay': {'baseURL': 'https://a.example/v1', 'apiKey': ''},
            },
          },
          {
            'providers': {
              'myRelay': {'baseURL': 'https://b.example/v1', 'apiKey': ''},
            },
          },
          secretPaths: const {'providers.*.apiKey'},
        );
        expect(ops.length, 1);
        expect(ops.first['path'], ['providers', 'myRelay', 'baseURL']);

        // 5) Provider API protocol allowlist rejects `'llm-pi-ai'` and infers Anthropic/OpenAI cleanly
        expect(resolveProviderApiProtocol(explicit: 'llm-pi-ai', providerId: 'anthropic'), 'anthropic-messages');
        expect(resolveProviderApiProtocol(explicit: 'llm-pi-ai', providerId: 'openai'), 'openai-responses');
        expect(resolveProviderApiProtocol(explicit: 'llm-pi-ai', providerId: 'custom-relay'), 'openai-completions');
        expect(resolveProviderApiProtocol(explicit: 'anthropic-messages', providerId: 'custom'), 'anthropic-messages');

        // 6) importConfigJson rejects empty JSON and preserves live credentials on matching origin
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final ctrl = container.read(appProvider.notifier);
        expect(ctrl.importConfigJson('{}'), isFalse);
        ctrl.state = ctrl.state.copyWith(
          hosts: [
            ctrl.state.localHost,
            const ManagedHost(
              id: 'r1',
              isLocal: false,
              name: 'Mac Studio',
              address: 'http://192.168.1.50:3080',
              latency: '12ms',
              token: 'secret-tok',
              sessionCookie: 'sid=abc',
              online: true,
              bridged: true,
            ),
          ],
          activeHostId: 'r1',
        );
        final exported = ctrl.exportConfigJson();
        expect(ctrl.importConfigJson(exported), isTrue);
        final restored = container.read(appProvider).hosts.firstWhere((h) => h.id == 'r1');
        expect(restored.token, 'secret-tok');
        expect(restored.sessionCookie, 'sid=abc');
        expect(restored.online, isTrue);
        container.dispose();
        await tester.pump(const Duration(seconds: 3));
      },
    );

    test('v29 validators: Schemastery dict keys, finite numbers, and strict Cron parsing', () {
      // Dict key validation blocks prototype pollution, dot-path separators, and control chars
      expect(validateSchemasteryDictKey('my-provider'), isNull);
      expect(validateSchemasteryDictKey('__proto__'), isNotNull);
      expect(validateSchemasteryDictKey('constructor'), isNotNull);
      expect(validateSchemasteryDictKey('prototype'), isNotNull);
      expect(validateSchemasteryDictKey('a.b'), isNotNull);
      expect(validateSchemasteryDictKey('bad\nkey'), isNotNull);

      // Finite number parser rejects NaN / Infinity / -Infinity
      expect(parseFiniteSchemaNumber('42', isInteger: true), 42);
      expect(parseFiniteSchemaNumber('3.14', isInteger: false), 3.14);
      expect(parseFiniteSchemaNumber('NaN', isInteger: false), isNull);
      expect(parseFiniteSchemaNumber('Infinity', isInteger: false), isNull);
      expect(parseFiniteSchemaNumber('-Infinity', isInteger: false), isNull);

      // Cron validation rejects malformed ranges/stars while allowing valid 5-field expressions
      expect(isValidCron5Field('0 9 * * *'), isTrue);
      expect(isValidCron5Field('*/15 9-17 * * MON-FRI'), isTrue);
      expect(isValidCron5Field('0 0 L * ?'), isTrue);
      expect(isValidCron5Field('1- * * * *'), isFalse);
      expect(isValidCron5Field('--- * * * *'), isFalse);
      expect(isValidCron5Field('** * * * *'), isFalse);
      expect(isValidCron5Field('*/5/2 * * * *'), isFalse);
    });

    testWidgets('v29 SduiNodeRenderer survives deep nesting, non-finite gap/progress & untyped maps', (tester) async {
      // Build a 32-level nested column tree + non-finite gap/progress + untyped tab map
      Map<String, dynamic> deep = {
        'type': 'progress',
        'label': 'Deep',
        'value': double.nan,
        'max': double.infinity,
      };
      for (var i = 0; i < 32; i++) {
        deep = {
          'type': 'column',
          'gap': double.nan,
          'children': [deep],
        };
      }
      final root = <String, dynamic>{
        'type': 'column',
        'gap': double.infinity,
        'children': [
          deep,
          {
            'type': 'tabs',
            'items': [
              <Object?, Object?>{
                'label': 'Tab 1',
                'child': <Object?, Object?>{'type': 'text', 'value': 'Safe untyped tab'},
              },
            ],
          },
        ],
      };

      await tester.pumpWidget(
        MaterialApp(
          theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SduiNodeRenderer(
                node: root,
                tier: GrassBagGlassTier.solid,
                onAction: (_, __) => null,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Safe untyped tab'), findsOneWidget);
      expect(find.textContaining('嵌套层级超过上限'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'v30 motion & fluidity: GrassBagUnifiedHeader ignores IME viewInsets, GrassBagListTile isolates press highlight, GrassBagSpringTap fast-taps inside ListView, and GrassBagDirectionalTabSwitcher settles cleanly',
      (tester) async {
        // 1. GrassBagUnifiedHeader must NOT rebuild when MediaQuery.viewInsets.bottom changes
        var trailingBuilds = 0;
        final viewInsetsNotifier = ValueNotifier<double>(0.0);
        addTearDown(viewInsetsNotifier.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: ValueListenableBuilder<double>(
              valueListenable: viewInsetsNotifier,
              builder: (ctx, inset, child) => MediaQuery(
                data: MediaQueryData(
                  size: const Size(390, 844),
                  viewInsets: EdgeInsets.only(bottom: inset),
                ),
                child: child!,
              ),
              child: Scaffold(
                body: GrassBagUnifiedHeader(
                  title: '设置',
                  subtitle: '性能测试',
                  tier: GrassBagGlassTier.solid,
                  onBack: () {},
                  trailing: Builder(
                    builder: (_) {
                      trailingBuilds++;
                      return const SizedBox(width: 24, height: 24);
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(trailingBuilds, 1);

        // Simulate 120Hz IME frames raising viewInsets from 0 -> 140 -> 300
        viewInsetsNotifier.value = 140.0;
        await tester.pump();
        viewInsetsNotifier.value = 300.0;
        await tester.pump();
        expect(trailingBuilds, 1, reason: 'GrassBagUnifiedHeader must not depend on viewInsets');

        // 2. GrassBagListTile press highlight must NOT rebuild trailing child
        var tileTrailingBuilds = 0;
        var tileTapped = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: Scaffold(
              body: GrassBagListTile(
                title: const Text('隔离按压行'),
                trailing: Builder(
                  builder: (_) {
                    tileTrailingBuilds++;
                    return const Text('尾部');
                  },
                ),
                onTap: () => tileTapped++,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tileTrailingBuilds, 1);

        final gesture = await tester.startGesture(tester.getCenter(find.text('隔离按压行')));
        await tester.pump(const Duration(milliseconds: 60));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tileTapped, 1);
        expect(tileTrailingBuilds, 1, reason: 'Pressing GrassBagListTile must not rebuild trailing');

        // 3. GrassBagSpringTap fast tap inside ListView fires onTap & impulse without errors
        var fastTapCount = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: Scaffold(
              body: ListView(
                children: [
                  GrassBagSpringTap(
                    onTap: () => fastTapCount++,
                    child: const SizedBox(height: 56, child: Center(child: Text('快速点击项'))),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('快速点击项'));
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pumpAndSettle();
        expect(fastTapCount, 1);

        // 4. GrassBagDirectionalTabSwitcher transitions cleanly both directions
        final tabIdx = ValueNotifier<int>(0);
        addTearDown(tabIdx.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: Scaffold(
              body: ValueListenableBuilder<int>(
                valueListenable: tabIdx,
                builder: (_, idx, __) => GrassBagDirectionalTabSwitcher(
                  direction: idx == 0 ? -1 : 1,
                  child: KeyedSubtree(
                    key: ValueKey('tab-$idx'),
                    child: Text('面板 $idx'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('面板 0'), findsOneWidget);
        tabIdx.value = 1;
        await tester.pump(const Duration(milliseconds: 80));
        await tester.pumpAndSettle();
        expect(find.text('面板 1'), findsOneWidget);

        // 5. GrassBagGlassSwitch solid spring switch toggles cleanly by tap & horizontal drag
        var switchVal = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (_, setLocal) => GrassBagGlassSwitch(
                  value: switchVal,
                  tier: GrassBagGlassTier.solid,
                  onChanged: (v) => setLocal(() => switchVal = v),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.byType(GrassBagGlassSwitch));
        await tester.pumpAndSettle();
        expect(switchVal, isTrue);

        // 6. GrassBagAppGate mutes underlying subtree tickers via TickerMode while splash shows
        final gateContainer = ProviderContainer();
        addTearDown(gateContainer.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: gateContainer,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: const GrassBagAppGate(skipLaunchAnimation: false),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 60));
        expect(find.byType(GrassBagAnimatedLogo), findsOneWidget);
        // Tear down cleanly before timers fire
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 4));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'v31 chat experience: display math prose safety, zero-NBSP inline code, callouts, long user collapse, CJK @ trigger & live scroll pill',
      (tester) async {
        // 1. Error classification covers Chinese + split 402/429/signin/host/compact
        expect(
          GrassBagController.classifyReadableError('ACCOUNT_SIGNED_OUT').actionKind,
          'signin',
        );
        expect(
          GrassBagController.classifyReadableError('当前账户余额不足 (402)').actionKind,
          'model',
        );
        expect(
          GrassBagController.classifyReadableError('请求过于频繁 429 rate limit').actionKind,
          'retry',
        );
        expect(
          GrassBagController.classifyReadableError('prompt is too long / 上下文超长').actionKind,
          'compact',
        );
        expect(
          GrassBagController.classifyReadableError('host_offline 未连接主机').actionKind,
          'host',
        );

        // 2. TurnView: display-math with trailing prose does NOT swallow next paragraph,
        //    inline code has ZERO NBSP (\u00A0), callout renders localized badge,
        //    long user message collapses & expands, and @file reference chips render.
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final longUserText = List.generate(14, (i) => '用户粘贴的第 ${i + 1} 行日志输出').join('\n');
        final richTurn = NormalizedTurn(
          turnId: 'turn-v31-rich',
          status: 'completed',
          userMessage: NormalizedUserMessage(
            id: 'u-v31',
            text: longUserText,
            references: const [
              {'kind': 'file', 'path': 'lib/ui/chat/turn_process_widget.dart'},
            ],
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
          steps: const [
            ToolStep(
              callId: 'c-edit-1',
              name: 'edit_file',
              title: 'edit_file · app/lib/ui/chat/turn_process_widget.dart',
              status: 'ok',
              summary: 'updated 2 lines',
            ),
          ],
          assistantText:
              '\$\$E = mc^2\$\$ 是质能方程。\n\n'
              '请运行 `git status` 检查工作区。\n\n'
              '> [!WARNING]\n'
              '> 提交前请先核对改动。\n\n'
              '```dart\nfinal count = 42;\n```',
          usage: const TurnUsage(
            inputTokens: 1200,
            outputTokens: 240,
            cacheReadTokens: 600,
            durationMs: 2400,
          ),
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: TurnView(
                    turn: richTurn,
                    onOpenTerminal: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // @file chip & long user message collapse toggle
        expect(find.text('turn_process_widget.dart'), findsAtLeastNWidgets(1));
        expect(find.text('展开全部（共 14 行）'), findsOneWidget);
        await tester.tap(find.text('展开全部（共 14 行）'));
        await tester.pumpAndSettle();
        expect(find.text('收起内容'), findsOneWidget);

        // Trailing prose after inline $$...$$ MUST NOT swallow following paragraph or callout!
        expect(find.textContaining('请运行'), findsOneWidget);
        expect(find.text('注意'), findsOneWidget);
        expect(find.textContaining('提交前请先核对改动'), findsOneWidget);
        expect(find.textContaining('已修改 1 个文件'), findsOneWidget);

        // Inline code MUST NOT contain invisible NBSP (\u00A0)!
        final richTexts = tester.widgetList<RichText>(find.byType(RichText));
        final hasNbspCode = richTexts.any((rt) => rt.text.toPlainText().contains('\u00A0git status\u00A0'));
        expect(hasNbspCode, isFalse);
        expect(
          richTexts.any((rt) => rt.text.toPlainText().contains('git status')),
          isTrue,
        );

        // 3. Composer CJK `@` trigger + mid-token replacement + live scroll pill
        final composerCtrl = TextEditingController();
        final focusNode = FocusNode();
        final showScroll = ValueNotifier<bool>(true);
        final hasNewBelow = ValueNotifier<bool>(true);
        addTearDown(composerCtrl.dispose);
        addTearDown(focusNode.dispose);
        addTearDown(showScroll.dispose);
        addTearDown(hasNewBelow.dispose);

        final compContainer = ProviderContainer();
        addTearDown(compContainer.dispose);
        compContainer.read(appProvider.notifier).state = compContainer.read(appProvider).copyWith(
          activeSessionId: 'sess-v31',
          turns: [richTurn],
          workspaceFiles: const [
            WorkspaceFileNode(name: 'main_controller.dart', path: 'lib/main_controller.dart', isDir: false),
          ],
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: compContainer,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: ChatComposerDock(
                    controller: composerCtrl,
                    focusNode: focusNode,
                    onOpenTerminal: () {},
                    showScrollToBottomListenable: showScroll,
                    hasNewBelowListenable: hasNewBelow,
                    onScrollToBottom: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Live scroll pill shows '有新回复' when scrolled away & new content arrived!
        expect(find.text('有新回复'), findsOneWidget);

        // Typing Chinese prose + `@ma` mid-token before `in.dart` triggers `@` and replaces whole token cleanly!
        composerCtrl.value = const TextEditingValue(
          text: '帮我看看@main.dart',
          selection: TextSelection.collapsed(offset: 7), // cursor at `帮我看看@ma|in.dart`
        );
        await tester.pump(const Duration(milliseconds: 220));
        expect(find.text('lib/main_controller.dart'), findsOneWidget);
        await tester.tap(find.text('lib/main_controller.dart'));
        await tester.pumpAndSettle();
        expect(composerCtrl.text, '帮我看看@lib/main_controller.dart ');
        // Flush debounced draft persistence timer cleanly before test teardown.
        await tester.pump(const Duration(milliseconds: 1400));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'v32 reply generation: streaming GFM table/inline stability, non-copyable caret, stalled pill, continue button, edit banner & IME guard',
      (tester) async {
        tester.view.physicalSize = const Size(420, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        // 1. Streaming TurnView:
        //    - partial GFM table + incomplete **bold + incomplete [link](url stabilize cleanly
        //    - NO copyable ' ▍' cursor character in RichText
        //    - stalled pill renders when `streamStalled: true`
        //    - completed tool-heavy turn suppresses distorted `t/s` in usage badge
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(appProvider.notifier).state = container.read(appProvider).copyWith(
          activeSessionId: 'sess-v32',
          isStreaming: true,
          streamStalled: true,
        );

        const streamingTurn = NormalizedTurn(
          turnId: 'turn-v32-stream',
          status: 'streaming',
          userMessage: NormalizedUserMessage(id: 'u-v32', text: '生成对比表格'),
          steps: [
            ReasoningStep(id: 'r1', text: '第一步已结束推理。', collapsedPreview: '第一步已结束推理。', durationMs: 1200),
            ToolStep(callId: 'c1', name: 'bash', title: 'bash · ls -la', status: 'ok', durationMs: 400),
            ReasoningStep(id: 'r2', text: '正在整理最终表格...', collapsedPreview: '正在整理最终表格...'),
          ],
          assistantText:
              '| 维度 | 状态 |\n'
              '| --- |\n'
              '| 流式渲染 | **已优化\n\n'
              '参考 [说明文档](https://example.com/incom',
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: TurnView(
                    turn: streamingTurn,
                    onOpenTerminal: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        // Pump long enough for streaming typewriter to reveal the full buffered text
        await tester.pump(const Duration(milliseconds: 800));
        await tester.pump(const Duration(milliseconds: 800));

        expect(find.text('响应较慢 · 点击同步状态'), findsOneWidget);
        expect(find.text('流式渲染'), findsOneWidget);
        expect(find.textContaining('说明文档'), findsOneWidget);
        // Incomplete `[说明文档](https://example.com/incom` must NOT leak raw broken URL syntax!
        expect(find.textContaining('https://example.com/incom'), findsNothing);
        // Streaming caret MUST be a non-copyable WidgetSpan, NEVER a literal '▍' character!
        final richTexts = tester.widgetList<RichText>(find.byType(RichText));
        expect(richTexts.any((rt) => rt.text.toPlainText().contains('▍')), isFalse);

        // 2. Cancelled partial turn shows '已停止' badge + '继续' button;
        //    tool-heavy completed turn hides distorted t/s in usage micro-badge.
        container.read(appProvider.notifier).state = container.read(appProvider).copyWith(
          isStreaming: false,
          streamStalled: false,
        );
        const partialStoppedTurn = NormalizedTurn(
          turnId: 'turn-v32-stopped',
          status: 'cancelled',
          userMessage: NormalizedUserMessage(id: 'u-stop', text: '写一段总结'),
          steps: [
            ToolStep(callId: 'c2', name: 'read', title: 'read README.md', status: 'ok', durationMs: 2000),
          ],
          assistantText: '这是已经生成的前半段内容。',
          usage: TurnUsage(inputTokens: 500, outputTokens: 120, durationMs: 4000),
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: TurnView(
                    turn: partialStoppedTurn,
                    onOpenTerminal: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('已停止生成'), findsOneWidget);
        expect(find.text('继续'), findsOneWidget);
        expect(find.textContaining('t/s'), findsNothing);

        // 3. Contextual Edit Banner in ChatComposerDock:
        //    - displays '正在编辑' + '分支重发' toggle
        //    - Escape during active CJK IME composition MUST NOT cancel editing
        //    - tapping cancel restores stashedDraft cleanly
        final composerCtrl = TextEditingController(text: '修改后的提问');
        final focusNode = FocusNode();
        final editNotifier = ValueNotifier<EditingMessageContext?>(
          const EditingMessageContext(
            turnId: 'turn-2',
            originalText: '原始提问',
            stashedDraft: '之前没发完的草稿',
            forkBeforeTurnId: 'turn-1',
          ),
        );
        addTearDown(composerCtrl.dispose);
        addTearDown(focusNode.dispose);
        addTearDown(editNotifier.dispose);

        final compContainer = ProviderContainer();
        addTearDown(compContainer.dispose);
        compContainer.read(appProvider.notifier).state = compContainer.read(appProvider).copyWith(
          activeSessionId: 'sess-v32-edit',
          isStreaming: true,
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: compContainer,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: ChatComposerDock(
                    controller: composerCtrl,
                    focusNode: focusNode,
                    editingContextNotifier: editNotifier,
                    onOpenTerminal: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('正在编辑'), findsOneWidget);
        expect(find.text('分支重发'), findsOneWidget);
        // Streaming follow-up mode pill reflects default busyEnter ('排队')
        expect(find.text('排队'), findsOneWidget);

        // Simulate active CJK IME composing range + Escape -> MUST NOT cancel edit banner!
        focusNode.requestFocus();
        await tester.pump();
        composerCtrl.value = const TextEditingValue(
          text: '修改后的提问nihao',
          selection: TextSelection.collapsed(offset: 11),
          composing: TextRange(start: 6, end: 11),
        );
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(editNotifier.value, isNotNull);

        // Clear IME composing range + Escape -> cancels editing and restores stashedDraft!
        composerCtrl.value = const TextEditingValue(
          text: '修改后的提问你好',
          selection: TextSelection.collapsed(offset: 8),
        );
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(editNotifier.value, isNull);
        expect(composerCtrl.text, '之前没发完的草稿');

        await tester.pump(const Duration(milliseconds: 1400));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'v33 regression: running tool detail does not tight-loop, queued edit sheet disposes cleanly, short-IME takeover card fits without overflow, multi-word settings search & Cron 5L/FRIL',
      (tester) async {
        // 1. Multi-word Settings search + no misleading proxy alias on General + Cron 5L/FRIL
        expect(
          settingsSectionMatchesQuery(
            SettingsSection.appearance,
            title: '外观与主题',
            summary: '浅色 · 液态玻璃',
            groupTitle: '连接与本机',
            rawQuery: '深色 玻璃',
          ),
          isTrue,
        );
        expect(
          settingsSectionMatchesQuery(
            SettingsSection.model,
            title: '模型与渠道',
            summary: 'DeepSeek',
            groupTitle: 'DSH 核心设置',
            rawQuery: 'base key',
          ),
          isTrue,
        );
        expect(
          settingsSectionMatchesQuery(
            SettingsSection.general,
            title: '通用与对话',
            summary: '工作区写入',
            groupTitle: 'DSH 核心设置',
            rawQuery: '代理',
          ),
          isFalse,
        );
        expect(isValidCron5Field('0 9 * * 5L'), isTrue);
        expect(isValidCron5Field('0 9 * * FRIL'), isTrue);

        // 2. Expanded running ToolStep returning empty detail must NOT tight-loop HTTP fetches!
        var detailFetchCount = 0;
        final container = ProviderContainer(
          overrides: [
            appProvider.overrideWith(
              (ref) => _CountingToolDetailController(
                onFetch: () => detailFetchCount++,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        final ctrl = container.read(appProvider.notifier);
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        ctrl.state = ctrl.state.copyWith(
          expandedTurnProcessIds: const {'turn-v33-loop'},
          expandedStepIds: const {'call-v33-running'},
        );
        const runningTurn = NormalizedTurn(
          turnId: 'turn-v33-loop',
          status: 'streaming',
          userMessage: NormalizedUserMessage(id: 'u-v33', text: '测试运行中工具'),
          steps: [
            ToolStep(
              callId: 'call-v33-running',
              name: 'bash',
              title: 'bash · sleep 5',
              status: 'running',
            ),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: TurnView(
                    turn: runningTurn,
                    onOpenTerminal: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(detailFetchCount, 1, reason: 'Running tool with empty detail must fetch once, not loop every frame');

        // 3. Cramped short-IME (240px) UserQuestion takeover card fits with ZERO RenderFlex overflow!
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        ctrl.state = ctrl.state.copyWith(
          activeQuestion: const ActiveUserQuestion(
            interactionId: 'q-v33-ime',
            title: '需要确认方案',
            prompt: '请选择接下来的处理方式：',
            options: [
              '选项 A · 保留现有结构并增量优化',
              '选项 B · 彻底重构模块',
              '选项 C · 仅修复崩溃与泄漏',
            ],
            allowFreeText: true,
          ),
        );
        final composerCtrl = TextEditingController();
        final focusNode = FocusNode();
        addTearDown(() {
          composerCtrl.dispose();
          focusNode.dispose();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ChatComposerDock(
                      controller: composerCtrl,
                      focusNode: focusNode,
                      onOpenTerminal: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('需要确认方案'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // 4. Queued message edit sheet opens & dismisses cleanly without disposed TextEditingController error!
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        ctrl.state = ctrl.state.copyWith(
          clearActiveQuestion: true,
          isStreaming: true,
          queuedMessages: const [
            QueuedMessageItem(id: 'q-edit-1', text: '排队中的原始消息', mode: 'queue'),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 520),
                    child: ChatComposerDock(
                      controller: composerCtrl,
                      focusNode: focusNode,
                      onOpenTerminal: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('排队中的原始消息'), findsOneWidget);
        await tester.tap(find.byIcon(CupertinoIcons.pencil).first);
        await tester.pumpAndSettle();
        expect(find.text('编辑排队消息'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.text('编辑排队消息'), findsNothing);
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'v34 regression: readable LaTeX formatting, incremental block-comment code highlighting, WCAG AA accent contrast across all 12 themes, frosted tier budget & GrassBagControlledOpacity elision',
      (tester) async {
        // 1. LaTeX formatting handles nested \frac{\sqrt{x}}{2}, braced ^{2n}, \mathbb{R}, aligned envs
        final fracSqrt = formatReadableLatexForTest(r'\frac{\sqrt{x}}{2}');
        expect(fracSqrt, contains('√(x)'));
        expect(fracSqrt, isNot(contains(r'\frac')));
        expect(formatReadableLatexForTest(r'x^{2n} + y_{i+1}'), contains('²ⁿ'));
        expect(formatReadableLatexForTest(r'x \in \mathbb{R}'), contains('ℝ'));
        final aligned = formatReadableLatexForTest(r'\begin{aligned} a &= b \\ c &= d \end{aligned}');
        expect(aligned, contains('\n'));
        expect(aligned, isNot(contains(r'\begin')));

        // 2. Frosted chrome tier uses standard quality (no shader oversampling)
        expect(
          GrassBagGlassConfig.chromeQualityFor(GrassBagGlassTier.frosted),
          GlassQuality.standard,
        );

        // 3. WCAG AA contrast (>= 4.5:1) for primary over blended primarySoft on cardSolid across all 12 themes
        double lum(Color c) => c.computeLuminance();
        double contrastRatio(Color fg, Color bg) {
          final l1 = lum(fg);
          final l2 = lum(bg);
          return (l1 > l2 ? l1 : l2) + 0.05 > 0
              ? ((l1 > l2 ? l1 : l2) + 0.05) / ((l1 < l2 ? l1 : l2) + 0.05)
              : 1.0;
        }
        for (final accent in GrassBagAccent.values) {
          for (final brightness in Brightness.values) {
            final t = GrassBagTokens.resolve(accent, brightness);
            final blendedSoft = Color.alphaBlend(t.primarySoft, t.cardSolid);
            final ratio = contrastRatio(t.primary, blendedSoft);
            expect(
              ratio,
              greaterThanOrEqualTo(4.5),
              reason: 'Accent $accent ($brightness) primary on primarySoft contrast=$ratio < 4.5',
            );
          }
        }

        // 4. GrassBagControlledOpacity elides OpacityLayer at 1.0 and enables compositing at 0.5
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                GrassBagControlledOpacity(
                  key: Key('op-full'),
                  opacity: 1.0,
                  child: Text('Full'),
                ),
                GrassBagControlledOpacity(
                  key: Key('op-half'),
                  opacity: 0.5,
                  child: Text('Half'),
                ),
              ],
            ),
          ),
        );
        final fullRo = tester.renderObject(find.byKey(const Key('op-full')));
        final halfRo = tester.renderObject(find.byKey(const Key('op-half')));
        // ignore: invalid_use_of_protected_member
        expect(fullRo.alwaysNeedsCompositing, isFalse);
        // ignore: invalid_use_of_protected_member
        expect(halfRo.alwaysNeedsCompositing, isTrue);

        // 5. TurnView renders multi-line /* ... */ code block and opens fullscreen sheet with Soft-Wrap & Copy controls
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final codeTurn = NormalizedTurn(
          turnId: 'turn-v34-code',
          status: 'completed',
          userMessage: const NormalizedUserMessage(id: 'u-v34', text: '展示代码块'),
          assistantText: '```dart\n'
              '/* start comment\n'
              'still inside comment\n'
              'end comment */\n'
              '${List.generate(12, (i) => 'final v$i = $i;').join('\n')}\n'
              '```',
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: TurnView(
                    turn: codeTurn,
                    onOpenTerminal: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('still inside comment'), findsOneWidget);
        expect(find.text('全屏'), findsOneWidget);
        await tester.tap(find.text('全屏'));
        await tester.pumpAndSettle();
        expect(find.text('自动换行'), findsOneWidget);
        expect(find.text('复制代码'), findsOneWidget);
        await tester.tap(find.text('自动换行'));
        await tester.pumpAndSettle();
        expect(find.text('切换单行'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}

class _CountingToolDetailController extends GrassBagController {
  _CountingToolDetailController({required this.onFetch});

  final VoidCallback onFetch;

  @override
  Future<Map<String, dynamic>> loadToolDetail(String callId, {bool forceRefresh = false}) async {
    onFetch();
    return const <String, dynamic>{};
  }
}
