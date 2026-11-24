import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/theme/grassbag_theme.dart';
import 'package:grassbag/ui/chat/composer_bar.dart';

class _FakeDshServer {
  late final HttpServer server;
  int defaultModelRevision = 3;
  int llmPiAiRevision = 1;
  Map<String, dynamic> defaultModel = {
    'provider': 'deepseek',
    'model': 'deepseek-chat',
    'reasoningEffort': 'high',
  };
  Map<String, dynamic> piAiProviders = {};
  List<Map<String, dynamic>> groups = [];
  int selectModelCalls = 0;
  int mutateDefaultModelCalls = 0;
  int conflictResponsesSent = 0;
  bool forceOneStaleConflict = false;

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
        'serverVersion': '0.1.0',
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
        'bridgeVersion': '0.1.0',
        'endpoints': ['session/list', 'session/selectModel', 'settings/describe', 'settings/mutate'],
      });
      return;
    }
    if (path == '/gbridge/v1/sessions') {
      await _sendJson(req.response, 200, {
        'v': 1,
        'sessions': [
          {
            'sessionId': 'sess-live-1',
            'title': '实测会话',
            'cwd': '/root/workspace',
            'updatedAt': '2026-11-24T10:00:00.000Z',
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
        ],
      });
      return;
    }
    if (path == '/gbridge/v1/models') {
      await _sendJson(req.response, 200, {
        'v': 1,
        'catalog': {
          'default': defaultModel,
          'routableProviders': groups.map((g) => g['id']).toList(),
          'groups': groups,
          'failures': [],
        },
        'providers': [],
        'configurable': [],
      });
      return;
    }
    if (path == '/gbridge/v1/settings/schema') {
      await _sendJson(req.response, 200, {
        'v': 1,
        'description': {
          'writable': true,
          'namespaces': [
            {
              'ns': 'agent-default-model',
              'revision': defaultModelRevision,
              'schema': {'uid': 1, 'refs': {'1': {'type': 'object', 'dict': {}}}},
              'value': defaultModel,
            },
            {
              'ns': 'llm-pi-ai',
              'revision': llmPiAiRevision,
              'schema': {'uid': 1, 'refs': {'1': {'type': 'object', 'dict': {}}}},
              'value': {'providers': piAiProviders},
            },
          ],
        },
      });
      return;
    }
    if (path == '/gbridge/v1/settings/manifest') {
      await _sendJson(req.response, 200, {'v': 1, 'sections': [], 'dynamicOptions': {}});
      return;
    }
    if (path == '/gbridge/v1/presets') {
      await _sendJson(req.response, 200, {'v': 1, 'presets': []});
      return;
    }
    if (path == '/gbridge/v1/permissions/catalog') {
      await _sendJson(req.response, 200, {'v': 1, 'catalog': {'options': []}});
      return;
    }
    if (path == '/gbridge/v1/account') {
      await _sendJson(req.response, 200, {'v': 1, 'state': {'status': 'signed-out'}});
      return;
    }
    if (path == '/gbridge/v1/credentials' && method == 'PUT') {
      await utf8.decoder.bind(req).join();
      await _sendJson(req.response, 200, {'v': 1, 'result': {'ok': true}});
      return;
    }
    if (path == '/gbridge/v1/credentials') {
      await _sendJson(req.response, 200, {'v': 1, 'credentials': {}});
      return;
    }
    if (path == '/gbridge/v1/sessions/sess-live-1/model' && method == 'PUT') {
      selectModelCalls++;
      final raw = await utf8.decoder.bind(req).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;
      // Mirror real DSH `session/selectModel` side-effect: saves default model & bumps revision!
      defaultModel = {
        if (body['provider'] != null) 'provider': body['provider'],
        if (body['model'] != null) 'model': body['model'],
        if (body['reasoningEffort'] != null) 'reasoningEffort': body['reasoningEffort'],
      };
      defaultModelRevision++;
      await _sendJson(req.response, 200, {'v': 1, 'result': {'selected': defaultModel}});
      return;
    }
    if (path == '/gbridge/v1/settings' && method == 'PATCH') {
      final raw = await utf8.decoder.bind(req).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final ns = body['ns']?.toString() ?? '';
      final expected = (body['expectedRevision'] as num?)?.toInt();

      if (ns == 'agent-default-model') {
        mutateDefaultModelCalls++;
        if (forceOneStaleConflict) {
          forceOneStaleConflict = false;
          defaultModelRevision++;
          conflictResponsesSent++;
          await _sendJson(req.response, 409, {
            'code': 'SETTINGS_CONFLICT',
            'message':
                'settings namespace "agent-default-model" changed since it was read (expected revision $expected, now $defaultModelRevision)',
          });
          return;
        }
        if (expected != null && expected != defaultModelRevision) {
          conflictResponsesSent++;
          await _sendJson(req.response, 409, {
            'code': 'SETTINGS_CONFLICT',
            'message':
                'settings namespace "agent-default-model" changed since it was read (expected revision $expected, now $defaultModelRevision)',
          });
          return;
        }
        final ops = body['ops'] as List<dynamic>? ?? const [];
        for (final rawOp in ops) {
          final op = rawOp as Map<String, dynamic>;
          final opPath = (op['path'] as List<dynamic>).map((e) => e.toString()).toList();
          if (opPath.length == 1) {
            if (op['op'] == 'set') {
              defaultModel[opPath.first] = op['value'];
            } else if (op['op'] == 'unset') {
              defaultModel.remove(opPath.first);
            }
          }
        }
        defaultModelRevision++;
        await _sendJson(req.response, 200, {
          'v': 1,
          'result': {'revision': defaultModelRevision, 'value': defaultModel},
        });
        return;
      }

      if (ns == 'llm-pi-ai') {
        if (expected != null && expected != llmPiAiRevision) {
          conflictResponsesSent++;
          await _sendJson(req.response, 409, {
            'code': 'SETTINGS_CONFLICT',
            'message':
                'settings namespace "llm-pi-ai" changed since it was read (expected revision $expected, now $llmPiAiRevision)',
          });
          return;
        }
        final section = body['section'] as Map<String, dynamic>? ?? const {};
        piAiProviders = Map<String, dynamic>.from(
          (section['providers'] as Map?) ?? const <String, dynamic>{},
        );
        // Project configured providers into live catalog groups immediately!
        groups = [
          for (final entry in piAiProviders.entries)
            if (entry.value is Map && (entry.value['models'] as List?)?.isNotEmpty == true)
              {
                'id': entry.key,
                'name': entry.value['displayName'] ?? entry.key,
                'models': [
                  for (final m in (entry.value['models'] as List))
                    if (m is Map)
                      {
                        'id': m['id'],
                        'name': m['name'] ?? m['id'],
                        if (m['reasoningEfforts'] is Map)
                          'reasoning': {
                            'efforts': [
                              for (final k in (m['reasoningEfforts'] as Map).keys)
                                {'id': k, 'name': k},
                            ],
                            'defaultEffort': (m['reasoningEfforts'] as Map).keys.first,
                          },
                      },
                ],
              },
        ];
        llmPiAiRevision++;
        await _sendJson(req.response, 200, {
          'v': 1,
          'result': {
            'revision': llmPiAiRevision,
            'value': {'providers': piAiProviders},
          },
        });
        return;
      }
    }

    await _sendJson(req.response, 200, {'v': 1});
  }
}

class _RealLoopbackHttpOverrides extends HttpOverrides {}

void main() {
  setUpAll(() {
    GrassBagController.disableAutoAppUpdateCheck = true;
  });

  test('empty model list keeps selector empty; adding first model auto-selects it; switching thinking effort succeeds without SettingsConflictError', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
    final fakeDsh = _FakeDshServer();
    await fakeDsh.start();
    addTearDown(fakeDsh.close);

    final ctrl = GrassBagController();
    addTearDown(ctrl.dispose);

    // Connect controller's local host to loopback fake DSH (starts with 0 models, even though catalog.default has stale deepseek-chat!)
    ctrl.state = ctrl.state.copyWith(
      hosts: [
        ctrl.state.localHost.copyWith(
          address: fakeDsh.baseUrl,
          token: 'test-token',
        ),
      ],
    );
    await ctrl.switchHost(ctrl.state.localHost.id, savePreviousContext: false);
    // Allow initial hydrate to finish deterministically (wait for WS + settings namespaces)
    for (var i = 0;
        i < 40 &&
            (ctrl.state.connectionPhase != ConnectionPhase.connected ||
                ctrl.state.dshNamespaces.isEmpty);
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    // 1. Model list is empty -> model selector MUST be empty (NOT stale deepseek-chat!)
    expect(ctrl.state.hasAvailableModels, false);
    expect(ctrl.state.activeModelId, '');
    expect(ctrl.state.effectiveActiveModelEntry, isNull);

    // 2. Add the FIRST custom provider + reasoning model -> MUST automatically select it!
    final saveErr = await ctrl.saveProviderConfig(
      providerId: 'my-relay',
      settingsNs: 'llm-pi-ai',
      displayName: '我的中转',
      apiProtocol: 'openai-completions',
      baseUrl: 'https://relay.example.com/v1',
      envRef: 'MY_RELAY_API_KEY',
      apiKeyValue: 'sk-first-model',
      isCustomProvider: true,
      customModels: [
        {
          'id': 'deepseek-v4-flash',
          'name': 'DeepSeek-V4.1-Flash',
          'reasoningEfforts': {
            'low': 'low',
            'medium': 'medium',
            'high': 'high',
            'xhigh': 'xhigh',
          },
        },
      ],
    );
    expect(saveErr, isNull);
    expect(ctrl.state.hasAvailableModels, true);
    expect(ctrl.state.activeModelProvider, 'my-relay');
    expect(ctrl.state.activeModelId, 'deepseek-v4-flash');
    expect(ctrl.state.modelName, 'DeepSeek-V4.1-Flash');
    expect(ctrl.state.effectiveActiveModelEntry?.id, 'deepseek-v4-flash');
    expect(ctrl.state.recentErrors, isEmpty);

    // 3. Switch thinking effort with NO active session AND forced stale revision conflict -> auto-recovers silently!
    fakeDsh.forceOneStaleConflict = true;
    await ctrl.setModel(
      ctrl.state.modelName,
      ctrl.state.modelShort,
      provider: ctrl.state.activeModelProvider,
      modelId: ctrl.state.activeModelId,
      effortId: 'xhigh',
      silent: true,
    );
    expect(fakeDsh.conflictResponsesSent, 1);
    expect(ctrl.state.modelEffortId, 'xhigh');
    expect(ctrl.state.modelEffort, '超高');
    expect(ctrl.state.recentErrors, isEmpty);

    // 4. Switch thinking effort WITH an active server session -> calls selectModel ONLY (no double-write SettingsConflictError!)
    ctrl.state = ctrl.state.copyWith(activeSessionId: 'sess-live-1');
    final mutatesBefore = fakeDsh.mutateDefaultModelCalls;
    final conflictsBefore = fakeDsh.conflictResponsesSent;
    await ctrl.setModel(
      ctrl.state.modelName,
      ctrl.state.modelShort,
      provider: ctrl.state.activeModelProvider,
      modelId: ctrl.state.activeModelId,
      effortId: 'medium',
      silent: true,
    );
    expect(fakeDsh.selectModelCalls, greaterThanOrEqualTo(1));
    expect(fakeDsh.mutateDefaultModelCalls, mutatesBefore);
    expect(fakeDsh.conflictResponsesSent, conflictsBefore);
    expect(ctrl.state.modelEffortId, 'medium');
    expect(ctrl.state.modelEffort, '中');
    expect(ctrl.state.recentErrors, isEmpty);

    // 5. Add a second provider, then delete the active first provider -> selector auto-falls back to remaining model!
    await ctrl.saveProviderConfig(
      providerId: 'backup-relay',
      settingsNs: 'llm-pi-ai',
      displayName: '备用中转',
      apiProtocol: 'openai-completions',
      baseUrl: 'https://backup.example.com/v1',
      envRef: 'BACKUP_API_KEY',
      apiKeyValue: 'sk-backup',
      isCustomProvider: true,
      customModels: [
        {'id': 'gpt-5-mini', 'name': 'GPT-5 Mini'},
      ],
    );
    final delErr1 = await ctrl.deleteCustomProvider('my-relay');
    expect(delErr1, isNull);
    expect(ctrl.state.hasAvailableModels, true);
    expect(ctrl.state.activeModelProvider, 'backup-relay');
    expect(ctrl.state.activeModelId, 'gpt-5-mini');
    expect(ctrl.state.effectiveActiveModelEntry?.id, 'gpt-5-mini');

    // 6. Delete the LAST remaining provider -> model list becomes empty -> selector becomes empty!
    final delErr2 = await ctrl.deleteCustomProvider('backup-relay');
    expect(delErr2, isNull);
    expect(ctrl.state.hasAvailableModels, false);
    expect(ctrl.state.activeModelId, '');
    expect(ctrl.state.effectiveActiveModelEntry, isNull);
    }, _RealLoopbackHttpOverrides());
  });

  testWidgets('ComposerBar auto-fills model pill when modelGroups is non-empty even if activeModelId is blank, and shows 配置模型 only when empty', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final ctrl = container.read(appProvider.notifier);
    final focusNode = FocusNode();
    final textCtrl = TextEditingController();
    addTearDown(focusNode.dispose);
    addTearDown(textCtrl.dispose);

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

    // Case A: Connected with NON-EMPTY model list, even if activeModelId is blank -> auto-fills first model!
    ctrl.state = ctrl.state.copyWith(
      connectionPhase: ConnectionPhase.connected,
      hosts: [
        ctrl.state.activeHost.copyWith(online: true, bridged: true),
      ],
      activeModelProvider: '',
      activeModelId: '',
      modelName: '未配置模型',
      modelShort: '未配置',
      routableProviders: const ['my-relay'],
      modelGroups: const [
        ModelCatalogGroup(
          id: 'my-relay',
          name: '我的中转',
          routable: true,
          models: [
            ModelCatalogEntry(
              id: 'deepseek-v4',
              name: 'DeepSeek-V4.1',
              providerId: 'my-relay',
              providerName: '我的中转',
              efforts: [
                ModelEffortOption(id: 'high', name: 'High'),
              ],
              defaultEffort: 'high',
            ),
          ],
        ),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('DeepSeek-V4.1'), findsOneWidget);
    expect(find.text('配置模型'), findsNothing);

    // Case B: Connected with EMPTY model list -> shows 配置模型!
    ctrl.state = ctrl.state.copyWith(
      activeModelProvider: '',
      activeModelId: '',
      modelName: '未配置模型',
      modelShort: '未配置',
      routableProviders: const [],
      modelGroups: const [],
    );
    await tester.pumpAndSettle();
    expect(find.text('配置模型'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });
}
