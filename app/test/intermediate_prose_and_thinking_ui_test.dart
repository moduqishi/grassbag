import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbridge_client/gbridge_client.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/theme/grassbag_theme.dart';
import 'package:grassbag/ui/chat/turn_process_widget.dart';

void main() {
  testWidgets(
    'TurnView renders intermediate prose inline chronologically without hiding it inside collapsed process steps',
    (tester) async {
      final turn = NormalizedTurn(
        turnId: 'turn-interleaved-1',
        status: 'completed',
        userMessage: const NormalizedUserMessage(id: 'u1', text: '帮我排查并修改配置'),
        steps: const [
          ReasoningStep(
            id: 'r1',
            text: '先检查仓库配置和当前环境变量。',
            collapsedPreview: '先检查仓库配置和当前环境变量。',
            durationMs: 1200,
          ),
          ToolStep(
            callId: 'c1',
            name: 'read_file',
            title: 'read_file · config.yaml',
            status: 'ok',
            summary: '42 lines',
          ),
          ReasoningStep(
            id: 'narration-4-2',
            role: 'prose',
            text: '我发现 `config.yaml` 中有两套环境，**请问要保留旧配置吗？**',
            collapsedPreview: '我发现 `config.yaml` 中有两套环境，请问要保留旧配置吗？',
          ),
          ReasoningStep(
            id: 'r2',
            text: '继续查看第二个配置并准备最终改动。',
            collapsedPreview: '继续查看第二个配置并准备最终改动。',
            durationMs: 850,
          ),
          ToolStep(
            callId: 'c2',
            name: 'edit_file',
            title: 'edit_file · config.yaml',
            status: 'ok',
            summary: '+2 -1',
          ),
        ],
        assistantText: '已完成修改并验证通过。',
      );

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: TurnView(
                  turn: turn,
                  onOpenTerminal: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Even with default autoFoldSteps=true (both process segments collapsed!),
      // BOTH the intermediate prose question AND the final prose MUST be visible inline!
      expect(find.textContaining('请问要保留旧配置吗', findRichText: true), findsOneWidget);
      expect(find.textContaining('已完成修改并验证通过', findRichText: true), findsOneWidget);

      // Verify chronological order: intermediate prose appears ABOVE final prose.
      final midY = tester.getTopLeft(find.textContaining('请问要保留旧配置吗', findRichText: true)).dy;
      final finalY = tester.getTopLeft(find.textContaining('已完成修改并验证通过', findRichText: true)).dy;
      expect(midY, lessThan(finalY));
    },
  );

  testWidgets(
    'Expanded thinking detail renders structured card with zero nested vertical SingleChildScrollView traps',
    (tester) async {
      final turn = NormalizedTurn(
        turnId: 'turn-think-scroll',
        status: 'completed',
        userMessage: const NormalizedUserMessage(id: 'u2', text: '分析根因'),
        steps: const [
          ReasoningStep(
            id: 'reason-detail-1',
            text: '第一步：**定位崩溃点**。\n\n- 检查 `phone-tools.js` 返回结构\n- 对照 `dsh-tool-fs` 的 `saveImage()` 格式\n\n第二步：确认旧会话修复策略。',
            collapsedPreview: '第一步：定位崩溃点。',
            durationMs: 2400,
          ),
        ],
        assistantText: '根因已确认。',
      );

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(appProvider.notifier);
      ctrl.toggleTurnProcessFor(turn.stableKey, currentlyOpen: false);
      ctrl.toggleStepExpanded('reason-detail-1');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark).toMaterialTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: TurnView(
                  turn: turn,
                  onOpenTerminal: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('思考详情'), findsOneWidget);
      expect(find.textContaining('定位崩溃点', findRichText: true), findsOneWidget);
      expect(find.textContaining('确认旧会话修复策略', findRichText: true), findsOneWidget);

      // Inside TurnView, there must be ZERO nested vertical SingleChildScrollView widgets
      // so vertical touch drags never fight or get stuck inside thinking/tool cards!
      final nestedVerticalScrolls = tester
          .widgetList<SingleChildScrollView>(
            find.descendant(
              of: find.byType(TurnView),
              matching: find.byType(SingleChildScrollView),
            ),
          )
          .where((s) => s.scrollDirection == Axis.vertical)
          .toList();
      expect(nestedVerticalScrolls, isEmpty);
    },
  );

  test('TurnStreamReducer promotes intermediate prose before new reasoning delta during live streaming', () {
    final reducer = TurnStreamReducer();
    reducer.apply(const StreamFrame(
      op: 'event',
      seq: 1,
      type: 'turn.start',
      data: {'turnId': 't-live', 'eventSeq': 1},
    ));
    reducer.apply(const StreamFrame(
      op: 'delta',
      seq: 2,
      type: 'reasoning.delta',
      data: {'turnId': 't-live', 'delta': '第一阶段思考', 'eventSeq': 2},
    ));
    reducer.apply(const StreamFrame(
      op: 'delta',
      seq: 3,
      type: 'text.delta',
      data: {'turnId': 't-live', 'delta': '请问你希望覆盖还是追加？', 'eventSeq': 3},
    ));
    // Now a brand-new thinking phase arrives BEFORE any tool call!
    reducer.apply(const StreamFrame(
      op: 'delta',
      seq: 4,
      type: 'reasoning.delta',
      data: {'turnId': 't-live', 'delta': '第二阶段继续分析', 'eventSeq': 4},
    ));
    reducer.apply(const StreamFrame(
      op: 'delta',
      seq: 5,
      type: 'text.delta',
      data: {'turnId': 't-live', 'delta': '最终结论在此。', 'eventSeq': 5},
    ));

    final turns = reducer.turns;
    expect(turns, hasLength(1));
    final t = turns.first;
    expect(t.assistantText, '最终结论在此。');
    expect(t.steps.length, 3);
    expect((t.steps[0] as ReasoningStep).text, '第一阶段思考');
    expect((t.steps[0] as ReasoningStep).isIntermediateProse, isFalse);
    expect((t.steps[1] as ReasoningStep).text, '请问你希望覆盖还是追加？');
    expect((t.steps[1] as ReasoningStep).isIntermediateProse, isTrue);
    expect((t.steps[2] as ReasoningStep).text, '第二阶段继续分析');
    expect((t.steps[2] as ReasoningStep).isIntermediateProse, isFalse);
    expect(t.combinedAssistantProse, '请问你希望覆盖还是追加？\n\n最终结论在此。');
  });
}
