import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:grassbag/services/models_dev_service.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/theme/grassbag_glass.dart';
import 'package:grassbag/theme/grassbag_theme.dart';
import 'package:grassbag/ui/chat/chat_empty_state.dart';
import 'package:grassbag/ui/chat/composer_bar.dart';

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
      // Starter cards & rotating tip collapse to 0 opacity / 0 height when keyboard is fully open
      final opacityWidgets = tester.widgetList<Opacity>(find.byType(Opacity));
      expect(opacityWidgets.any((o) => o.opacity == 0.0), isTrue);
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
  });
}
