import 'package:gbridge_client/gbridge_client.dart';
import 'package:test/test.dart';

void main() {
  group('TurnStreamReducer', () {
    test('folds streaming reasoning, tool lifecycle, text deltas, and turn completion', () {
      final reducer = TurnStreamReducer();

      expect(
        reducer.apply(const StreamFrame(
          op: 'event',
          seq: 10,
          channel: 'session:s1',
          type: 'turn.start',
          data: {
            'turnId': 't1',
            'userMessage': {'id': 'u1', 'text': 'Fix PDF blur'},
          },
        )),
        isTrue,
      );

      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 11,
        channel: 'session:s1',
        type: 'reasoning.delta',
        data: {'turnId': 't1', 'id': 'r1', 'delta': 'Checking pdf-renderer.ts\n'},
      ));
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 12,
        channel: 'session:s1',
        type: 'reasoning.delta',
        data: {'turnId': 't1', 'id': 'r1', 'delta': 'Found dpr = 1 hardcoded.'},
      ));

      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 13,
        channel: 'session:s1',
        type: 'tool.call',
        data: {'turnId': 't1', 'callId': 'c1', 'name': 'edit', 'title': 'edit · src/pdf-renderer.ts'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 14,
        channel: 'session:s1',
        type: 'tool.result',
        data: {
          'turnId': 't1',
          'callId': 'c1',
          'status': 'ok',
          'summary': 'Updated dpr scaling to 2x',
          'durationMs': 42,
        },
      ));

      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 15,
        channel: 'session:s1',
        type: 'text.delta',
        data: {'turnId': 't1', 'delta': '已修复'},
      ));
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 16,
        channel: 'session:s1',
        type: 'text.delta',
        data: {'turnId': 't1', 'delta': '导出发糊问题。'},
      ));

      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 17,
        channel: 'session:s1',
        type: 'turn.end',
        data: {
          'turnId': 't1',
          'status': 'completed',
          'usage': {'inputTokens': 1200, 'outputTokens': 340},
        },
      ));

      expect(reducer.turns, hasLength(1));
      final turn = reducer.turns.single;
      expect(turn.turnId, 't1');
      expect(turn.status, 'completed');
      expect(turn.userMessage?.text, 'Fix PDF blur');
      expect(turn.assistantText, '已修复导出发糊问题。');
      expect(turn.usage?.inputTokens, 1200);
      expect(turn.steps, hasLength(2));

      final reason = turn.steps[0] as ReasoningStep;
      expect(reason.text, 'Checking pdf-renderer.ts\nFound dpr = 1 hardcoded.');
      expect(reason.collapsedPreview, 'Found dpr = 1 hardcoded.');

      final tool = turn.steps[1] as ToolStep;
      expect(tool.callId, 'c1');
      expect(tool.status, 'ok');
      expect(tool.durationMs, 42);
    });

    test('handles cancelled and error turn states', () {
      final reducer = TurnStreamReducer();
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 1,
        type: 'text.delta',
        data: {'turnId': 't2', 'delta': 'Partial'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 2,
        type: 'turn.end',
        data: {'turnId': 't2', 'reason': 'cancelled'},
      ));

      expect(reducer.turns.single.status, 'cancelled');
      expect(reducer.turns.single.isStreaming, isFalse);
    });

    test('reconciles trailing client-turn-* optimistic bubble with real server turnId without duplicates', () {
      final reducer = TurnStreamReducer();
      reducer.replaceAll([
        const NormalizedTurn(
          turnId: 'client-turn-1700000',
          status: 'streaming',
          userMessage: NormalizedUserMessage(id: 'u-opt', text: '分析当前目录结构'),
        ),
      ]);

      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 20,
        channel: 'session:s1',
        type: 'turn.start',
        data: {'turnId': 'srv-turn-99'},
      ));
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 21,
        channel: 'session:s1',
        type: 'text.delta',
        data: {'turnId': 'srv-turn-99', 'delta': '已扫描完成。'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 22,
        channel: 'session:s1',
        type: 'turn.end',
        data: {
          'turnId': 'srv-turn-99',
          'status': 'completed',
          'usage': {'inputTokens': 420, 'outputTokens': 88},
        },
      ));

      expect(reducer.turns, hasLength(1));
      expect(reducer.turns.single.turnId, 'srv-turn-99');
      expect(reducer.turns.single.userMessage?.text, '分析当前目录结构');
      expect(reducer.turns.single.assistantText, '已扫描完成。');
      expect(reducer.turns.single.status, 'completed');
      expect(reducer.turns.single.usage?.inputTokens, 420);
    });

    test('SessionSummary sanitizes [object Object], leaked title prompt, and absolute paths', () {
      final s1 = SessionSummary.fromJson({
        'id': 's1',
        'title': '[object Object], 帮我梳理项目',
      });
      expect(s1.title, '帮我梳理项目');

      final s2 = SessionSummary.fromJson({
        'id': 's2',
        'title': 'We need answer a short title for user message: "帮我检查 git diff"',
      });
      expect(s2.title, '帮我检查 git diff');

      final s3 = SessionSummary.fromJson({
        'id': 's3',
        'title': '[object Object]',
        'cwd': '/Users/cake/playground/grassbag',
      });
      expect(s3.title, 'grassbag');
    });

    test('promotes pre-tool narration into steps so final assistantText stays clean', () {
      final reducer = TurnStreamReducer();
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 1,
        type: 'turn.start',
        data: {'turnId': 't-agentic'},
      ));
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 2,
        type: 'text.delta',
        data: {'turnId': 't-agentic', 'delta': '我先读取配置文件看看。'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 3,
        type: 'tool.call',
        data: {'turnId': 't-agentic', 'callId': 'c-1', 'name': 'read', 'title': 'read · config.json'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 4,
        type: 'tool.result',
        data: {'turnId': 't-agentic', 'callId': 'c-1', 'status': 'ok', 'summary': 'ok'},
      ));
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 5,
        type: 'text.delta',
        data: {'turnId': 't-agentic', 'delta': '配置已核对完毕，一切正常。'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 6,
        type: 'turn.end',
        data: {'turnId': 't-agentic', 'status': 'completed'},
      ));

      final turn = reducer.turns.single;
      expect(turn.assistantText, '配置已核对完毕，一切正常。');
      expect(turn.steps, hasLength(2));
      expect((turn.steps.first as ReasoningStep).text, '我先读取配置文件看看。');
      expect((turn.steps.last as ToolStep).callId, 'c-1');
    });

    test('restores promoted narration on turn.end when no post-tool text follows', () {
      final reducer = TurnStreamReducer();
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 1,
        type: 'turn.start',
        data: {'turnId': 't-no-tail'},
      ));
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 2,
        type: 'text.delta',
        data: {'turnId': 't-no-tail', 'delta': '现在提交本次修改。'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 3,
        type: 'tool.call',
        data: {'turnId': 't-no-tail', 'callId': 'c-2', 'name': 'bash', 'title': 'bash · git commit'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 4,
        type: 'tool.result',
        data: {'turnId': 't-no-tail', 'callId': 'c-2', 'status': 'ok', 'summary': 'ok'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 5,
        type: 'turn.end',
        data: {'turnId': 't-no-tail', 'status': 'completed'},
      ));

      final turn = reducer.turns.single;
      expect(turn.assistantText, '现在提交本次修改。');
      expect(turn.steps, hasLength(1));
      expect((turn.steps.single as ToolStep).callId, 'c-2');
    });

    test('preserves optimistic new-chat turn across empty snapshot, user/message event, and turn/start without splitting turns', () {
      final reducer = TurnStreamReducer([
        const NormalizedTurn(
          turnId: 'client-turn-999',
          status: 'streaming',
          userMessage: NormalizedUserMessage(id: 'u-999', text: '用一句话回复：你好'),
        ),
      ]);

      // 1. Fresh session subscribe emits empty turn.snapshot -> MUST NOT wipe optimistic turn!
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 1,
        type: 'turn.snapshot',
        data: {'turns': <dynamic>[]},
      ));
      expect(reducer.turns, hasLength(1));
      expect(reducer.turns.single.isStreaming, isTrue);
      expect(reducer.turns.single.userMessage?.text, '用一句话回复：你好');

      // 2. Even an older server sending user/message as status=completed & turn-12 MUST NOT close stream!
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 2,
        type: 'session.event',
        data: {
          'normalizedTurn': {
            'turnId': 'turn-12',
            'status': 'completed',
            'userMessage': {'id': 'm-12', 'text': '用一句话回复：你好'},
            'steps': <dynamic>[],
            'assistantText': '',
          },
        },
      ));
      expect(reducer.turns, hasLength(1));
      expect(reducer.turns.single.isStreaming, isTrue);

      // 3. turn.delta turn/start (turn: 1) reconciles into the SAME turn (never spawns a 2nd turn!)
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 3,
        type: 'turn.delta',
        data: {
          'chunk': {'type': 'turn/start', 'turn': 1, 'step': 1},
        },
      ));
      expect(reducer.turns, hasLength(1));
      expect(reducer.turns.single.turnId, 'turn-1');
      expect(reducer.turns.single.isStreaming, isTrue);

      // 4. text-delta streams into that exact turn
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 4,
        type: 'turn.delta',
        data: {
          'turnId': 'turn-1',
          'chunk': {'type': 'text-delta', 'text': '你好，很高兴见到你！'},
        },
      ));
      expect(reducer.turns, hasLength(1));
      expect(reducer.turns.single.assistantText, '你好，很高兴见到你！');
      expect(reducer.turns.single.isStreaming, isTrue);

      // 5. turn.completed cleanly finalizes the single turn
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 5,
        type: 'turn.completed',
        data: {'turnId': 'turn-1', 'reason': 'completed'},
      ));
      expect(reducer.turns, hasLength(1));
      expect(reducer.turns.single.status, 'completed');
      expect(reducer.turns.single.userMessage?.text, '用一句话回复：你好');
      expect(reducer.turns.single.assistantText, '你好，很高兴见到你！');
    });

    test('turn.snapshot preserves stableKey across array and single-turn snapshots', () {
      final reducer = TurnStreamReducer([
        const NormalizedTurn(
          turnId: 'client-turn-42',
          status: 'streaming',
          userMessage: NormalizedUserMessage(id: 'u-42', text: '测试稳定键'),
        ),
      ]);

      // Array snapshot arrives with server turnId matching the optimistic user message
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 1,
        type: 'turn.snapshot',
        data: {
          'turns': [
            {
              'turnId': 'server-turn-42',
              'status': 'streaming',
              'userMessage': {'id': 'm-42', 'text': '测试稳定键'},
              'steps': <dynamic>[],
              'assistantText': '第一段',
            },
          ],
        },
      ));
      expect(reducer.turns, hasLength(1));
      expect(reducer.turns.single.turnId, 'server-turn-42');
      expect(reducer.turns.single.stableKey, 'client-turn-42');

      // Subsequent single-turn snapshot updates the same turn -> stableKey MUST remain intact
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 2,
        type: 'turn.snapshot',
        data: {
          'turn': {
            'turnId': 'server-turn-42',
            'status': 'completed',
            'userMessage': {'id': 'm-42', 'text': '测试稳定键'},
            'steps': <dynamic>[],
            'assistantText': '第一段，完整回复。',
          },
        },
      ));
      expect(reducer.turns, hasLength(1));
      expect(reducer.turns.single.status, 'completed');
      expect(reducer.turns.single.stableKey, 'client-turn-42');
      expect(reducer.turns.single.assistantText, '第一段，完整回复。');
    });

    test('turn.snapshot preserves optimistic regenerating turn with identical prompt text', () {
      final reducer = TurnStreamReducer([
        const NormalizedTurn(
          turnId: 'server-turn-1',
          status: 'completed',
          userMessage: NormalizedUserMessage(id: 'u-1', text: '再试一次'),
          assistantText: '旧回答',
        ),
        const NormalizedTurn(
          turnId: 'client-turn-regen',
          status: 'streaming',
          userMessage: NormalizedUserMessage(id: 'u-regen', text: '再试一次'),
        ),
      ]);

      // Snapshot contains ONLY the previously completed server-turn-1 (same text!) ->
      // MUST preserve the optimistic streaming turn-regen instead of dropping it!
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 1,
        type: 'turn.snapshot',
        data: {
          'turns': [
            {
              'turnId': 'server-turn-1',
              'status': 'completed',
              'userMessage': {'id': 'u-1', 'text': '再试一次'},
              'steps': <dynamic>[],
              'assistantText': '旧回答',
            },
          ],
        },
      ));
      expect(reducer.turns, hasLength(2));
      expect(reducer.turns.last.turnId, 'client-turn-regen');
      expect(reducer.turns.last.isStreaming, isTrue);
    });

    test('session.stream_end closes active streaming and false/empty error is ignored', () {
      final reducer = TurnStreamReducer([
        const NormalizedTurn(
          turnId: 'turn-7',
          status: 'streaming',
          userMessage: NormalizedUserMessage(id: 'u-7', text: '测试流结束'),
          assistantText: '生成中',
        ),
      ]);

      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 10,
        type: 'turn.delta',
        data: {
          'turnId': 'turn-7',
          'chunk': {'type': 'turn/start', 'turn': 8},
        },
      ));
      // Prior streaming turn-7 must be cleanly closed when turn-8 starts!
      expect(reducer.turns.first.status, 'completed');
      expect(reducer.turns.last.turnId, 'turn-8');
      expect(reducer.turns.last.isStreaming, isTrue);

      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 11,
        type: 'session.stream_end',
        data: {'error': false},
      ));
      expect(reducer.turns.last.isStreaming, isFalse);
      expect(reducer.turns.last.hasError, isFalse);
    });
  });
}
