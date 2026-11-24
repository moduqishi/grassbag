import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<HttpServer> _startMockBridgeHost({
  required String hostName,
  required String sessionId,
  required String sessionTitle,
  required String workspaceId,
  required String workspaceName,
  required String workspacePath,
  required String assistantReply,
  required String toolOutput,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final path = req.uri.path;
    resJson(Map<String, dynamic> data, {int status = 200}) async {
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(data));
      await req.response.close();
    }

    if (path == '/gbridge/v1/capabilities') {
      await resJson({
        'v': 1,
        'bridgeVersion': '0.2.0',
        'dshVersion': '0.2.2-rc.5',
        'bootId': 'boot-$hostName',
        'host': {
          'name': hostName,
          'platform': 'darwin',
          'arch': 'arm64',
          'isLocalAndroid': false,
        },
        'transport': {
          'wsPath': '/gbridge/v1/stream',
          'coalesceMs': 35,
          'replayCapacity': 100,
        },
        'domains': {
          'chat': {'ok': true, 'features': ['streaming', 'turns']},
          'workspaces': {'ok': true, 'features': ['list']},
        },
        'endpointsCount': 40,
      });
      return;
    }
    if (path == '/gbridge/v1/sessions') {
      await resJson({
        'v': 1,
        'sessions': [
          {
            'sessionId': sessionId,
            'title': sessionTitle,
            'workspaceId': workspaceId,
            'workspaceName': workspaceName,
            'cwd': workspacePath,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
            'running': false,
          },
        ],
      });
      return;
    }
    if (path == '/gbridge/v1/workspaces') {
      await resJson({
        'v': 1,
        'workspaces': [
          {
            'workspaceId': workspaceId,
            'title': workspaceName,
            'rootPath': workspacePath,
            'explicit': true,
            'sessionIds': [sessionId],
            'sessionCount': 1,
          },
        ],
      });
      return;
    }
    if (path == '/gbridge/v1/sessions/$sessionId/turns') {
      await resJson({
        'v': 1,
        'sessionId': sessionId,
        'hasMore': false,
        'turns': [
          {
            'turnId': 'turn-1',
            'status': 'completed',
            'userMessage': {'id': 'u-1', 'text': 'Hello $hostName'},
            'assistantText': assistantReply,
            'steps': [
              {
                'kind': 'tool',
                'callId': 'call-1-0',
                'name': 'shell',
                'status': 'ok',
                'summary': 'echo $hostName',
              },
            ],
          },
        ],
      });
      return;
    }
    if (path == '/gbridge/v1/sessions/$sessionId/tools/call-1-0') {
      await resJson({
        'v': 1,
        'tool': {
          'name': 'shell',
          'status': 'ok',
          'args': {'command': 'echo $hostName'},
          'output': toolOutput,
        },
      });
      return;
    }
    if (path == '/gbridge/v1/stream') {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.add(jsonEncode({
          'type': 'welcome',
          'v': 1,
          'bootId': 'boot-$hostName',
          'resumed': false,
          'pendingInteractions': const [],
        }));
        ws.listen((_) {}, onDone: () {}, onError: (_) {});
        return;
      }
    }
    await resJson({'v': 1, 'ok': true});
  });
  return server;
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'switching between hosts with same-title sessions & same turn/tool IDs never crosses sessions or leaks tool cache',
    () async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() {
        HttpOverrides.global = prevOverrides;
        debugDefaultTargetPlatformOverride = null;
      });
      SharedPreferences.setMockInitialValues({});
      GrassBagController.disableAutoAppUpdateCheck = true;

      final hostAServer = await _startMockBridgeHost(
        hostName: 'MacBook-A',
        sessionId: 'sess-host-a-1',
        sessionTitle: '同名话题',
        workspaceId: 'ws-a',
        workspaceName: 'workspace',
        workspacePath: '/Users/dev/a/workspace',
        assistantReply: 'Reply strictly from Host A',
        toolOutput: 'TOOL_OUTPUT_FROM_HOST_A',
      );
      final hostBServer = await _startMockBridgeHost(
        hostName: 'Linux-B',
        sessionId: 'sess-host-b-1',
        sessionTitle: '同名话题',
        workspaceId: 'ws-b',
        workspaceName: 'workspace',
        workspacePath: '/home/dev/b/workspace',
        assistantReply: 'Reply strictly from Host B',
        toolOutput: 'TOOL_OUTPUT_FROM_HOST_B',
      );
      addTearDown(() async {
        await hostAServer.close(force: true);
        await hostBServer.close(force: true);
      });

      final ctrl = GrassBagController();
      addTearDown(ctrl.dispose);

      // Give initial storage hydration a moment to finish
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final hostA = ctrl.addRemoteHost(
        'http://127.0.0.1:${hostAServer.port}',
        name: 'MacBook-A',
        autoProbe: false,
        silent: true,
      )!;
      final hostB = ctrl.addRemoteHost(
        'http://127.0.0.1:${hostBServer.port}',
        name: 'Linux-B',
        autoProbe: false,
        silent: true,
      )!;
      expect(hostA.id, isNot(hostB.id));

      // 1. Connect to Host A -> should start on New Chat (never auto-select Host A's session)
      await ctrl.switchHost(hostA.id, awaitConnect: true);
      await _waitUntil(() => ctrl.state.sessions.any((s) => s.id == 'sess-host-a-1'));
      expect(ctrl.state.activeSessionId, isNull);
      expect(ctrl.state.turns, isEmpty);

      // 2. Open Host A's "同名话题" and load tool call-1-0 + add feedback on turn-1
      ctrl.selectSession('sess-host-a-1');
      await _waitUntil(() => ctrl.state.turns.isNotEmpty);
      expect(ctrl.state.turns.first.assistantText, 'Reply strictly from Host A');
      final toolA = await ctrl.loadToolDetail('call-1-0');
      expect(toolA['outputText'], 'TOOL_OUTPUT_FROM_HOST_A');
      await ctrl.putTurnFeedback('turn-1', 'up');
      expect(ctrl.feedbackForTurn(ctrl.state.turns.first), 'up');

      // 3. Switch to Host B (which ALSO has a session titled "同名话题"!)
      //    Host B has NEVER had a session opened -> MUST stay on New Chat, NEVER enter Host B's "同名话题"!
      await ctrl.switchHost(hostB.id, awaitConnect: true);
      await _waitUntil(() => ctrl.state.sessions.any((s) => s.id == 'sess-host-b-1'));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(ctrl.state.activeHostId, hostB.id);
      expect(ctrl.state.activeSessionId, isNull);
      expect(ctrl.state.turns, isEmpty);

      // 4. Now open Host B's "同名话题" (`sess-host-b-1`), verify NO tool/feedback bleed from Host A
      ctrl.selectSession('sess-host-b-1');
      await _waitUntil(() => ctrl.state.turns.isNotEmpty);
      expect(ctrl.state.turns.first.assistantText, 'Reply strictly from Host B');
      expect(ctrl.feedbackForTurn(ctrl.state.turns.first), isNull);
      final toolB = await ctrl.loadToolDetail('call-1-0');
      expect(toolB['outputText'], 'TOOL_OUTPUT_FROM_HOST_B');

      // 5. Switch back to Host A -> restores Host A's previously open `sess-host-a-1`
      await ctrl.switchHost(hostA.id, awaitConnect: true);
      await _waitUntil(() => ctrl.state.activeSessionId == 'sess-host-a-1' && ctrl.state.turns.isNotEmpty);
      expect(ctrl.state.activeSessionId, 'sess-host-a-1');
      expect(ctrl.state.turns.first.assistantText, 'Reply strictly from Host A');

      // 6. Switch back to Host B -> restores Host B's previously open `sess-host-b-1`
      await ctrl.switchHost(hostB.id, awaitConnect: true);
      await _waitUntil(() => ctrl.state.activeSessionId == 'sess-host-b-1' && ctrl.state.turns.isNotEmpty);
      expect(ctrl.state.activeSessionId, 'sess-host-b-1');
      expect(ctrl.state.turns.first.assistantText, 'Reply strictly from Host B');

      // 7. Tap New Chat on Host B, switch away to Host A, and switch back to Host B -> MUST remain on New Chat!
      ctrl.startNewChat();
      expect(ctrl.state.activeSessionId, isNull);
      await ctrl.switchHost(hostA.id, awaitConnect: true);
      await _waitUntil(() => ctrl.state.activeSessionId == 'sess-host-a-1');
      await ctrl.switchHost(hostB.id, awaitConnect: true);
      await _waitUntil(() => ctrl.state.sessions.any((s) => s.id == 'sess-host-b-1'));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(ctrl.state.activeSessionId, isNull);
      expect(ctrl.state.turns, isEmpty);

      // 8. Re-open Host B's session, then switch away to Host A while Host B's session is remembered,
      //    then switch to Host B and immediately switch back to Host A before Host B hydrates ->
      //    Host B's remembered `lastSessionId` MUST NOT be wiped!
      ctrl.selectSession('sess-host-b-1');
      await _waitUntil(() => ctrl.state.turns.isNotEmpty);
      unawaited(ctrl.switchHost(hostA.id));
      // Immediately switch back while Host A is still connecting (`activeSessionId == null`)!
      await ctrl.switchHost(hostB.id, awaitConnect: true);
      await _waitUntil(() => ctrl.state.activeSessionId == 'sess-host-b-1');
      expect(ctrl.state.activeSessionId, 'sess-host-b-1');
      // And Host A's remembered `sess-host-a-1` MUST still be intact too!
      await ctrl.switchHost(hostA.id, awaitConnect: true);
      await _waitUntil(() => ctrl.state.activeSessionId == 'sess-host-a-1');
      expect(ctrl.state.activeSessionId, 'sess-host-a-1');

      // 9. Changing Host B's address to a different server clears stale host context -> lands on New Chat
      final hostCServer = await _startMockBridgeHost(
        hostName: 'Linux-C',
        sessionId: 'sess-host-c-1',
        sessionTitle: '同名话题',
        workspaceId: 'ws-c',
        workspaceName: 'workspace',
        workspacePath: '/home/dev/c/workspace',
        assistantReply: 'Reply from Host C',
        toolOutput: 'TOOL_OUTPUT_FROM_HOST_C',
      );
      addTearDown(() => hostCServer.close(force: true));
      await ctrl.updateHostDetails(
        hostB.id,
        address: 'http://127.0.0.1:${hostCServer.port}',
      );
      await ctrl.switchHost(hostB.id, awaitConnect: true);
      await _waitUntil(() => ctrl.state.sessions.any((s) => s.id == 'sess-host-c-1'));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(ctrl.state.activeSessionId, isNull);
      expect(ctrl.state.turns, isEmpty);
    },
  );
}
