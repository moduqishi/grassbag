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

    test('turn.start settles prior unclosed streaming turn and running tool steps', () {
      final reducer = TurnStreamReducer([
        const NormalizedTurn(
          turnId: 'turn-prev',
          status: 'streaming',
          userMessage: NormalizedUserMessage(id: 'u-prev', text: '旧问题'),
          steps: [
            ToolStep(callId: 'c-run', name: 'bash', title: 'bash', status: 'running'),
          ],
        ),
      ]);

      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 20,
        type: 'turn.start',
        data: {
          'turnId': 'turn-next',
          'userMessage': {'id': 'u-next', 'text': '新问题'},
        },
      ));
      expect(reducer.turns, hasLength(2));
      expect(reducer.turns.first.status, 'completed');
      final settledStep = reducer.turns.first.steps.single as ToolStep;
      expect(settledStep.status, 'ok');
      expect(reducer.turns.last.turnId, 'turn-next');
      expect(reducer.turns.last.isStreaming, isTrue);
    });

    test('turn.snapshot updates ToolStep status/summary when step count is unchanged', () {
      final reducer = TurnStreamReducer([
        const NormalizedTurn(
          turnId: 't-snap',
          status: 'streaming',
          steps: [
            ToolStep(callId: 'c1', name: 'bash', title: 'bash', status: 'running'),
          ],
        ),
      ]);

      final changed = reducer.apply(const StreamFrame(
        op: 'event',
        seq: 5,
        type: 'turn.snapshot',
        data: {
          'turns': [
            {
              'turnId': 't-snap',
              'status': 'streaming',
              'steps': [
                {
                  'kind': 'tool',
                  'callId': 'c1',
                  'name': 'bash',
                  'title': 'bash',
                  'status': 'ok',
                  'summary': 'done',
                },
              ],
            },
          ],
        },
      ));
      expect(changed, isTrue);
      final step = reducer.turns.single.steps.single as ToolStep;
      expect(step.status, 'ok');
      expect(step.summary, 'done');
    });

    test('turn.delta turn/start settles running tools on prior turn', () {
      final reducer = TurnStreamReducer([
        const NormalizedTurn(
          turnId: 'turn-1',
          status: 'streaming',
          steps: [
            ToolStep(callId: 'c-old', name: 'read', title: 'read', status: 'running'),
          ],
        ),
      ]);

      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 12,
        type: 'turn.delta',
        data: {
          'turnId': 'turn-1',
          'chunk': {'type': 'turn/start', 'turn': 2},
        },
      ));
      expect(reducer.turns, hasLength(2));
      expect((reducer.turns.first.steps.single as ToolStep).status, 'ok');
      expect(reducer.turns.last.turnId, 'turn-2');
    });

    test('parseRemoteHostInput handles userinfo@host:port and rejects invalid ports', () {
      final withUserInfo = parseRemoteHostInput('user:pass@192.168.1.25:3080/?token=abc');
      expect(withUserInfo, isNotNull);
      expect(withUserInfo!.address, contains('192.168.1.25:3080'));
      expect(withUserInfo.token, 'abc');

      expect(parseRemoteHostInput('http://192.168.1.25:99999'), isNull);
      expect(parseRemoteHostInput('http://192.168.1.25:0'), isNull);
    });

    test('v30 persistent StringBuffer survives repeated turns flushes and detaches cleanly on structural events', () {
      final reducer = TurnStreamReducer();
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 1,
        type: 'turn.start',
        data: {'turnId': 't-v30'},
      ));

      // Stream reasoning across multiple intermediate `turns` snapshots
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 2,
        type: 'reasoning.delta',
        data: {'turnId': 't-v30', 'id': 'r1', 'delta': 'Step 1: '},
      ));
      expect((reducer.turns.single.steps.single as ReasoningStep).text, 'Step 1: ');
      // Repeated read with no new delta returns identical cached list without mutating
      final snapA = reducer.turns;
      final snapB = reducer.turns;
      expect(identical(snapA, snapB), isTrue);

      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 3,
        type: 'reasoning.delta',
        data: {'turnId': 't-v30', 'id': 'r1', 'delta': 'analyze.'},
      ));
      expect((reducer.turns.single.steps.single as ReasoningStep).text, 'Step 1: analyze.');

      // Stream assistant text across multiple intermediate `turns` snapshots
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 4,
        type: 'text.delta',
        data: {'turnId': 't-v30', 'delta': 'Hello '},
      ));
      expect(reducer.turns.single.assistantText, 'Hello ');
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 5,
        type: 'text.delta',
        data: {'turnId': 't-v30', 'delta': 'GrassBag'},
      ));
      expect(reducer.turns.single.assistantText, 'Hello GrassBag');

      // Tool call must flush & detach the active text buffer cleanly (promoting text to narration)
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 6,
        type: 'tool.call',
        data: {'turnId': 't-v30', 'callId': 'c-v30', 'name': 'read', 'title': 'read file'},
      ));
      expect(reducer.turns.single.assistantText, isEmpty);
      expect(reducer.turns.single.steps.whereType<ReasoningStep>().length, 2);

      // Post-tool text starts fresh (zero stale carryover from pre-tool buffer!)
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 7,
        type: 'text.delta',
        data: {'turnId': 't-v30', 'delta': 'Final answer.'},
      ));
      expect(reducer.turns.single.assistantText, 'Final answer.');

      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 8,
        type: 'turn.end',
        data: {'turnId': 't-v30', 'status': 'completed'},
      ));
      expect(reducer.turns.single.status, 'completed');
      expect(reducer.turns.single.assistantText, 'Final answer.');
    });

    test('v31 turn.snapshot preserves prepended older turns and merges server maskedRanges & references', () {
      final reducer = TurnStreamReducer([
        const NormalizedTurn(
          turnId: 'turn-older-1',
          seqStart: 1,
          seqEnd: 3,
          status: 'completed',
          userMessage: NormalizedUserMessage(id: 'u-1', text: 'older message'),
          assistantText: 'older answer',
        ),
        const NormalizedTurn(
          turnId: 'client-turn-500',
          seqStart: 10,
          seqEnd: 10,
          status: 'streaming',
          userMessage: NormalizedUserMessage(
            id: 'u-client-500',
            text: 'key sk-1234567890abcdef12345678',
          ),
        ),
      ]);

      // Live snapshot carrying only the recent window (>= seq 10) with server-masked ranges & refs
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 12,
        type: 'turn.snapshot',
        data: {
          'turns': [
            {
              'turnId': 'turn-new-10',
              'seqStart': 10,
              'seqEnd': 12,
              'status': 'streaming',
              'userMessage': {
                'id': 'u-srv-10',
                'text': 'key sk-1234567890abcdef12345678',
                'maskedRanges': [
                  {'start': 4, 'end': 31, 'kind': 'api_key', 'visiblePrefix': 6},
                ],
                'references': [
                  {'kind': 'file', 'path': 'lib/main.dart'},
                ],
              },
              'steps': <dynamic>[],
              'assistantText': 'received',
            },
          ],
        },
      ));

      expect(reducer.turns, hasLength(2));
      expect(reducer.turns.first.turnId, 'turn-older-1');
      expect(reducer.turns.last.turnId, 'turn-new-10');
      expect(reducer.turns.last.stableKey, 'client-turn-500');
      expect(reducer.turns.last.userMessage?.maskedRanges, hasLength(1));
      expect(reducer.turns.last.userMessage?.references, hasLength(1));
    });

    test('v31 stale turn.end for another turnId does not cancel a newer streaming interrupt turn', () {
      final reducer = TurnStreamReducer([
        const NormalizedTurn(
          turnId: 'turn-new-interrupt',
          seqStart: 20,
          seqEnd: 21,
          status: 'streaming',
          assistantText: 'fresh interrupt output',
        ),
      ]);

      final changed = reducer.apply(const StreamFrame(
        op: 'event',
        seq: 22,
        type: 'turn.completed',
        data: {'turnId': 'turn-old-cancelled', 'reason': 'cancelled'},
      ));
      expect(changed, isFalse);
      expect(reducer.turns.single.status, 'streaming');
      expect(reducer.turns.single.assistantText, 'fresh interrupt output');
    });

    test('v32 reasoning/tool durationMs, post-tool dedup, abandoned drop, @file reconcile & client-turn interrupt guard', () {
      final reducer = TurnStreamReducer();
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 1,
        type: 'turn.start',
        data: {'turnId': 't-v32'},
      ));
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 2,
        type: 'reasoning.delta',
        data: {'turnId': 't-v32', 'id': 'r1', 'delta': '先定位配置文件。'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 3,
        type: 'tool.call',
        data: {'turnId': 't-v32', 'callId': 'c1', 'name': 'read', 'title': 'read config'},
      ));
      final reasonedBefore = reducer.turns.single.steps.whereType<ReasoningStep>().single;
      expect(reasonedBefore.durationMs, isNotNull);

      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 4,
        type: 'tool.result',
        data: {'turnId': 't-v32', 'callId': 'c1', 'name': 'read', 'status': 'ok', 'summary': 'ok'},
      ));
      final toolStep = reducer.turns.single.steps.whereType<ToolStep>().single;
      expect(toolStep.durationMs, isNotNull);

      // Persisted assistant.message carrying the same reasoning must NOT duplicate it after the ToolStep!
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 5,
        type: 'assistant.message',
        data: {'turnId': 't-v32', 'text': '已完成检查', 'reasoning': '先定位配置文件。'},
      ));
      expect(reducer.turns.single.steps.whereType<ReasoningStep>().length, 1);
      expect(reducer.turns.single.steps.first, isA<ReasoningStep>());
      expect(reducer.turns.single.steps.last, isA<ToolStep>());

      // assistant-stream/abandoned drops unfinalized trailing live reasoning step
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 6,
        type: 'reasoning.delta',
        data: {'turnId': 't-v32', 'id': 'r-abandoned', 'delta': '准备再次重试...'},
      ));
      expect(reducer.turns.single.steps.whereType<ReasoningStep>().length, 2);
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 7,
        type: 'turn.delta',
        data: {
          'turnId': 't-v32',
          'chunks': [
            {'type': 'assistant-stream/abandoned'},
          ],
        },
      ));
      expect(reducer.turns.single.steps.whereType<ReasoningStep>().length, 1);

      // Stale turn.completed from earlier cancelled turn must NOT cancel a new optimistic client-turn-* interrupt turn
      final interruptReducer = TurnStreamReducer([
        const NormalizedTurn(
          turnId: 'turn-old-dying',
          status: 'cancelled',
          userMessage: NormalizedUserMessage(id: 'u-old', text: '旧问题'),
        ),
        const NormalizedTurn(
          turnId: 'client-turn-999',
          status: 'streaming',
          userMessage: NormalizedUserMessage(id: 'u-999', text: '看看 @app/lib/main.dart'),
        ),
      ]);
      final staleApplied = interruptReducer.apply(const StreamFrame(
        op: 'event',
        seq: 20,
        type: 'turn.completed',
        data: {'turnId': 'turn-old-dying', 'reason': 'cancelled'},
      ));
      expect(staleApplied, isFalse);
      expect(interruptReducer.turns.last.status, 'streaming');

      // turn.snapshot reconciles optimistic user prompt even when server prepends @file ref line
      interruptReducer.apply(const StreamFrame(
        op: 'event',
        seq: 21,
        type: 'turn.snapshot',
        data: {
          'turns': [
            {
              'turnId': 'turn-old-dying',
              'seqStart': 1,
              'seqEnd': 5,
              'status': 'cancelled',
              'userMessage': {'id': 'u-old', 'text': '旧问题'},
              'steps': <dynamic>[],
              'assistantText': '',
            },
            {
              'turnId': 'turn-srv-999',
              'seqStart': 21,
              'seqEnd': 21,
              'status': 'streaming',
              'userMessage': {
                'id': 'u-srv-999',
                'text': '@file:app/lib/main.dart\n看看 @app/lib/main.dart',
              },
              'steps': <dynamic>[],
              'assistantText': '',
            },
          ],
        },
      ));
      expect(interruptReducer.turns, hasLength(2));
      expect(interruptReducer.turns.last.turnId, 'turn-srv-999');
      expect(interruptReducer.turns.last.stableKey, 'client-turn-999');

      // Matching turn.completed with reason: 'interrupted' sets error status + clear localized errorMessage
      interruptReducer.apply(const StreamFrame(
        op: 'event',
        seq: 22,
        type: 'turn.completed',
        data: {'turnId': 'turn-srv-999', 'reason': 'interrupted'},
      ));
      expect(interruptReducer.turns.last.status, 'error');
      expect(interruptReducer.turns.last.errorMessage, '本轮回复已被中断');
    });

    test('v51 replaceAll preserves running reasoning & tool start timestamps across bundle resyncs', () {
      final reducer = TurnStreamReducer();
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 1,
        type: 'turn.start',
        data: {'turnId': 't-v51'},
      ));
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 2,
        type: 'reasoning.delta',
        data: {'turnId': 't-v51', 'id': 'r-live', 'delta': '思考中…'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 3,
        type: 'tool.call',
        data: {'turnId': 't-v51', 'callId': 'call-live', 'name': 'bash', 'title': 'ls'},
      ));

      // Simulate a periodic bundle snapshot resync while `call-live` is still running!
      reducer.replaceAll(reducer.turns);

      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 4,
        type: 'tool.result',
        data: {'turnId': 't-v51', 'callId': 'call-live', 'name': 'bash', 'status': 'ok', 'summary': 'done'},
      ));
      final completedTool = reducer.turns.single.steps.whereType<ToolStep>().single;
      expect(completedTool.durationMs, isNotNull);
      expect(completedTool.durationMs!, greaterThanOrEqualTo(1));
    });

    test('v52 regression: settles running ToolStep on turn completion/next turn & routes type:chunk via kind', () {
      final reducer = TurnStreamReducer();
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 1,
        type: 'turn.start',
        data: {'turnId': 't-v52-a'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 2,
        type: 'tool.call',
        data: {'turnId': 't-v52-a', 'callId': 'c-hang', 'name': 'bash', 'title': 'sleep 1'},
      ));
      // `type: 'chunk'` with `kind: 'text'` must route to assistantText cleanly.
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 3,
        type: 'turn.delta',
        data: {
          'turnId': 't-v52-a',
          'chunks': [
            {'type': 'chunk', 'kind': 'text', 'delta': 'Hello chunk!'},
          ],
        },
      ));
      expect(reducer.turns.single.assistantText, 'Hello chunk!');
      expect(reducer.turns.single.steps.whereType<ToolStep>().single.status, 'running');

      // Completing turn without a tool.result must settle still-running ToolStep!
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 4,
        type: 'turn.completed',
        data: {'turnId': 't-v52-a', 'reason': 'done'},
      ));
      expect(reducer.turns.single.steps.whereType<ToolStep>().single.status, 'ok');

      // Also verify an error/cancelled turn settles a running ToolStep as error,
      // and a new turn arriving while previous turn's ToolStep is still running settles it too.
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 5,
        type: 'turn.start',
        data: {'turnId': 't-v52-b'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 6,
        type: 'tool.call',
        data: {'turnId': 't-v52-b', 'callId': 'c-next', 'name': 'read', 'title': 'read file'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 7,
        type: 'turn.start',
        data: {'turnId': 't-v52-c'},
      ));
      expect(reducer.turns[1].steps.whereType<ToolStep>().single.status, isNot('running'));
    });

    test('v53 regression: preserves client-measured ReasoningStep & ToolStep durationMs across turn.snapshot & updates collapsedPreview past 4096 chars', () {
      final reducer = TurnStreamReducer();
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 1,
        type: 'turn.start',
        data: {'turnId': 't-v53'},
      ));
      // Push > 4500 chars of reasoning, then append new line -> collapsedPreview must stay fresh!
      final pad = 'X' * 4300;
      reducer.apply(StreamFrame(
        op: 'delta',
        seq: 2,
        type: 'reasoning.delta',
        data: {'turnId': 't-v53', 'id': 'r-v53', 'delta': '$pad\nLine A\n'},
      ));
      reducer.apply(const StreamFrame(
        op: 'delta',
        seq: 3,
        type: 'reasoning.delta',
        data: {'turnId': 't-v53', 'id': 'r-v53', 'delta': 'Final reasoning tail'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 4,
        type: 'tool.call',
        data: {'turnId': 't-v53', 'callId': 'c-v53', 'name': 'read', 'title': 'read · pubspec.yaml'},
      ));
      reducer.apply(const StreamFrame(
        op: 'event',
        seq: 5,
        type: 'tool.result',
        data: {'turnId': 't-v53', 'callId': 'c-v53', 'status': 'ok', 'summary': 'read ok'},
      ));

      final beforeSnap = reducer.turns.single;
      final beforeReason = beforeSnap.steps.whereType<ReasoningStep>().single;
      final beforeTool = beforeSnap.steps.whereType<ToolStep>().single;
      expect(beforeReason.collapsedPreview, 'Final reasoning tail');
      expect(beforeReason.durationMs, isNotNull);
      expect(beforeTool.durationMs, isNotNull);

      // Server snapshot arrives omitting durationMs on reasoning & tool steps -> client timings must survive!
      reducer.apply(StreamFrame(
        op: 'event',
        seq: 6,
        type: 'turn.snapshot',
        data: {
          'turn': {
            'turnId': 't-v53',
            'status': 'completed',
            'steps': [
              {
                'kind': 'reasoning',
                'id': 'r-v53',
                'text': '$pad\nLine A\nFinal reasoning tail',
                'collapsedPreview': 'Final reasoning tail',
              },
              {
                'kind': 'tool',
                'callId': 'c-v53',
                'name': 'read',
                'title': 'read · pubspec.yaml',
                'status': 'ok',
                'summary': 'read ok',
              },
            ],
            'assistantText': 'Done.',
          },
        },
      ));
      final afterSnap = reducer.turns.single;
      final afterReason = afterSnap.steps.whereType<ReasoningStep>().single;
      final afterTool = afterSnap.steps.whereType<ToolStep>().single;
      expect(afterReason.durationMs, beforeReason.durationMs);
      expect(afterTool.durationMs, beforeTool.durationMs);
    });
  });
}
