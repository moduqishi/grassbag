import 'package:flutter_test/flutter_test.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/ui/sdui/schemastery_form.dart';

void main() {
  test('decodes real @deepseek-ai/dsh@0.2.2-rc.5 Schemastery {uid, refs} graph accurately', () {
    // Exact real wire schema captured from @deepseek-ai/dsh@0.2.2-rc.5 `ui-theme` & `subagent`
    final realUiThemeSchema = {
      'uid': 5850,
      'refs': {
        '5840': {'type': 'const', 'meta': {'required': true}, 'value': 'light'},
        '5841': {'type': 'const', 'meta': {'required': true}, 'value': 'dark'},
        '5842': {'type': 'const', 'meta': {'required': true}, 'value': 'system'},
        '5843': {'type': 'union', 'meta': {'default': 'system'}, 'list': [5840, 5841, 5842]},
        '5844': {'type': 'number', 'meta': {'step': 1, 'min': 10, 'max': 22, 'default': 14}},
        '5845': {'type': 'string', 'meta': {'role': 'secret', 'default': ''}},
        '5850': {
          'type': 'object',
          'meta': {'default': {}},
          'dict': {'preference': 5843, 'fontSize': 5844, 'apiKey': 5845},
        },
      },
    };

    final jsonSchema = normalizeSchemasteryToJsonSchema(realUiThemeSchema);
    expect(jsonSchema['type'], 'object');
    final props = jsonSchema['properties'] as Map<String, dynamic>;
    expect(props['preference']['enum'], ['light', 'dark', 'system']);
    expect(props['fontSize']['type'], 'integer');
    expect(props['fontSize']['minimum'], 10);
    expect(props['fontSize']['maximum'], 22);
    expect(props['apiKey']['secret'], true);
  });

  test('parseDshSettingsNamespaces groups & sorts live DSH namespaces', () {
    final desc = {
      'writable': true,
      'namespaces': [
        {
          'ns': 'mcp-manager',
          'revision': 2,
          'schema': {'uid': 1, 'refs': {'1': {'type': 'object', 'dict': {}}}},
          'value': {'servers': {}},
        },
        {
          'ns': 'agent-default-model',
          'revision': 5,
          'schema': {'uid': 1, 'refs': {'1': {'type': 'object', 'dict': {}}}},
          'value': {'provider': 'deepseek', 'model': 'deepseek-reasoner'},
        },
        {
          'ns': 'bash-sandbox',
          'revision': 1,
          'schema': {'uid': 1, 'refs': {'1': {'type': 'object', 'dict': {}}}},
          'value': {'timeoutMs': 60000},
        },
      ],
    };

    final list = parseDshSettingsNamespaces(desc);
    expect(list.length, 3);
    expect(list.first.ns, 'agent-default-model');
    expect(list.first.group, '模型与推理');
    expect(list[1].ns, 'bash-sandbox');
    expect(list[1].group, '代理与沙箱');
    expect(list[2].ns, 'mcp-manager');
    expect(list[2].group, '联网与扩展');
  });

  test('controller enforces DSH single source of truth offline, queue & app-only config sync', () async {
    final ctrl = GrassBagController();
    addTearDown(ctrl.dispose);

    // DSH configs MUST NOT fake-save when disconnected from DSH core
    final patchErr = await ctrl.patchDshNamespace('agent-preset-registry', {'selectedDefault': 'ptc'});
    expect(patchErr, isNotNull);
    expect(ctrl.state.activePresetId, 'standard');

    await ctrl.upsertProviderCredential('OPENAI_API_KEY', 'sk-test-1234567890');
    expect(ctrl.state.providerCredentials.where((p) => p.envRef == 'OPENAI_API_KEY' && p.configured), isEmpty);
    expect(ctrl.state.toast?.tone, ToastTone.warn);

    await ctrl.removeProviderCredential('OPENAI_API_KEY');
    expect(ctrl.state.toast?.tone, ToastTone.warn);

    final queued = await ctrl.enqueueMessage('第一条排队任务');
    expect(queued, false);
    expect(ctrl.state.queuedMessages, isEmpty);

    final snapshot = ctrl.exportConfigJson();
    expect(snapshot, contains('grassbag-app-config-v3'));
    expect(snapshot, isNot(contains('dshNamespaces')));
    expect(ctrl.importConfigJson(snapshot), true);
  });

  test('parses real DSH 0.2.2-rc.5 ScheduleCatalogEntry and GoalView payloads cleanly', () {
    final sched = ScheduleTaskRecord.fromJson({
      'id': 'schedule-1',
      'kind': 'cron',
      'title': '晨间巡检',
      'prompt': '检查仓库状态',
      'status': 'paused',
      'expression': '0 9 * * 1-5',
      'timeZone': 'Asia/Shanghai',
      'lastDelivery': {
        'deliveredAt': '2026-11-24T01:00:00.000Z',
        'targetSessionId': 'session-abc',
      },
    });
    expect(sched.id, 'schedule-1');
    expect(sched.name, '晨间巡检');
    expect(sched.enabled, false);
    expect(sched.cronExpr, '0 9 * * 1-5');
    expect(sched.humanSchedule, '工作日 09:00');
    expect(sched.lastStatus, 'ok');
    expect(sched.lastRunAt, '2026-11-24 01:00:00');

    final everySched = ScheduleTaskRecord.fromJson({
      'id': 'schedule-2',
      'kind': 'every',
      'title': '半小时巡检',
      'prompt': 'ping',
      'status': 'active',
      'everySeconds': 1800,
    });
    expect(everySched.enabled, true);
    expect(everySched.humanSchedule, '每 30 分钟');

    final goal = SessionGoalRecord.fromJson({
      'id': 'goal-42',
      'revision': 3,
      'objective': '完成全链路回归\n验收标准：全部单测通过',
      'phase': 'complete',
      'roundsStarted': 4,
      'maxGoalRounds': 5,
    });
    expect(goal.id, 'goal-42');
    expect(goal.revision, 3);
    expect(goal.title, '完成全链路回归');
    expect(goal.criteria, '全部单测通过');
    expect(goal.status, 'completed');
    expect(goal.progressPct, 100);
  });
}
