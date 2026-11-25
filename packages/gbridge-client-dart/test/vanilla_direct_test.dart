import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gbridge_client/gbridge_client.dart';
import 'package:test/test.dart';

void main() {
  group('parseRemoteHostInput', () {
    test('extracts URL and token from `dsh web:` terminal output', () {
      final parsed = parseRemoteHostInput(
        '  dsh web: http://192.168.1.42:3080/?token=LaunchTok_9988  ',
      );
      expect(parsed, isNotNull);
      expect(parsed!.address, 'http://192.168.1.42:3080');
      expect(parsed.token, 'LaunchTok_9988');
      expect(parsed.suggestedName, '192.168.1.42');
      expect(parsed.wasExtractedFromText, isTrue);
    });

    test('auto-completes :3080 for bare LAN and Tailscale IPs without token', () {
      final lan = parseRemoteHostInput('192.168.50.12');
      expect(lan, isNotNull);
      expect(lan!.address, 'http://192.168.50.12:3080');
      expect(lan.token, isNull);
      expect(lan.wasAutoPorted, isTrue);

      final ts = parseRemoteHostInput('100.88.1.9');
      expect(ts, isNotNull);
      expect(ts!.address, 'http://100.88.1.9:3080');
      expect(ts.wasAutoPorted, isTrue);
    });

    test('defaults bare domain to https without adding :3080', () {
      final domain = parseRemoteHostInput('dsh.my-server.dev');
      expect(domain, isNotNull);
      expect(domain!.address, 'https://dsh.my-server.dev');
      expect(domain.wasAutoPorted, isFalse);
    });

    test('extracts inline GBRIDGE_TOKEN from multi-line snippet', () {
      final parsed = parseRemoteHostInput(
        'Connect to http://10.0.0.5:3080\nGBRIDGE_TOKEN=secret_token_abc123',
      );
      expect(parsed, isNotNull);
      expect(parsed!.address, 'http://10.0.0.5:3080');
      expect(parsed.token, 'secret_token_abc123');
    });

    test('strips Chinese punctuation, zero-width chars, and DSH web subpaths', () {
      final zh = parseRemoteHostInput(
        '请打开链接：http://192.168.1.88:3080/sessions/abc123?token=tok_zh_88）。\u200B',
      );
      expect(zh, isNotNull);
      expect(zh!.address, 'http://192.168.1.88:3080');
      expect(zh.token, 'tok_zh_88');
    });

    test('preserves bracketed IPv6 hosts cleanly', () {
      final v6 = parseRemoteHostInput('http://[fd7a:115c:a1e0::1]:3080/?token=ipv6tok');
      expect(v6, isNotNull);
      expect(v6!.address, 'http://[fd7a:115c:a1e0::1]:3080');
      expect(v6.token, 'ipv6tok');
    });
  });

  group('Zero-Plugin Stock DSH Direct Mode (NO dsh-gbridge installed)', () {
    late HttpServer server;
    late int port;
    var simulateForbiddenHost = false;
    var simulateHtmlLogin = false;
    final settledEvents = <Map<String, dynamic>>[];
    final receivedPrompts = <Map<String, dynamic>>[];

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;

      server.listen((req) async {
        final path = req.uri.path;

        // Public SSE endpoint exposed by stock DSH even BEFORE auth!
        if (path == '/plugins/events') {
          req.response.statusCode = 200;
          req.response.headers.set('content-type', 'text/event-stream');
          req.response.write(': connected\n\n');
          req.response.write(
            'data: ${jsonEncode({
                  'type': 'graph',
                  'graph': {
                    'rev': '1',
                    'release': {'version': '0.2.2-rc.5', 'commit': 'abc123'},
                    'entries': const [],
                  },
                })}\n\n',
          );
          await req.response.flush();
          await req.response.close();
          return;
        }

        if (simulateHtmlLogin) {
          req.response.statusCode = 200;
          req.response.headers.set('content-type', 'text/html; charset=utf-8');
          req.response.write('<!DOCTYPE html><html><body>Proxy SSO Login</body></html>');
          await req.response.close();
          return;
        }

        if (simulateForbiddenHost) {
          req.response.statusCode = 403;
          req.response.write('Forbidden');
          await req.response.close();
          return;
        }

        // Launch token -> 30-day v1 persistent cookie exchange
        if (path == '/' && req.uri.queryParameters['token'] == 'one-time-launch-tok') {
          req.response.statusCode = 303;
          req.response.headers.set('location', './');
          req.response.headers.add(
            'set-cookie',
            'dsh-auth-test=v1.persisted30daycookie; Path=/; HttpOnly; SameSite=Strict',
          );
          await req.response.close();
          return;
        }

        // NO /gbridge/v1 installed on stock DSH!
        if (path.startsWith('/gbridge/v1')) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }

        // Cookie auth check for /api/* (notice: NO Bearer token supported on stock DSH!)
        final cookie = req.headers.value(HttpHeaders.cookieHeader) ?? '';
        final authed = cookie.contains('dsh-auth-test=v1.persisted30daycookie');
        if (!authed) {
          req.response.statusCode = 401;
          req.response.write('dsh web authentication required');
          await req.response.close();
          return;
        }

        // Stock DSH multiplexed WebSocket `/api/remote.mux`
        if (path == '/api/remote.mux' && WebSocketTransformer.isUpgradeRequest(req)) {
          final ws = await WebSocketTransformer.upgrade(req);
          ws.listen((raw) {
            if (raw is! String) return;
            final msg = jsonDecode(raw) as Map<String, dynamic>;
            final type = msg['type']?.toString();
            final sid = msg['streamId']?.toString() ?? '';
            if (type == 'open') {
              final ep = msg['endpoint']?.toString() ?? '';
              if (ep == r'$events') {
                ws.add(jsonEncode({
                  'type': 'item',
                  'streamId': sid,
                  'value': {
                    'type': 'ready',
                    'clientId': 'cli-vanilla-1',
                    'host': {'home': '/Users/remote'},
                  },
                }));
                ws.add(jsonEncode({
                  'type': 'item',
                  'streamId': sid,
                  'value': {
                    'type': 'waterfall',
                    'event': 'approval/request',
                    'eventId': 'appr-1',
                    'agentId': 's-vanilla-1',
                    'request': {'toolName': 'bash', 'command': 'ls -la'},
                  },
                }));
              } else if (ep == 'workspace/follow') {
                ws.add(jsonEncode({
                  'type': 'item',
                  'streamId': sid,
                  'value': {
                    'items': [
                      {
                        'id': 'ws-1',
                        'path': '/Users/remote/project',
                        'title': 'project',
                        'sessionIds': ['s-vanilla-1'],
                      },
                    ],
                    'pinnedSessionIds': ['s-vanilla-1'],
                    'archivedSessionIds': const [],
                  },
                }));
              } else if (ep == 'mcpManager/watch') {
                ws.add(jsonEncode({
                  'type': 'item',
                  'streamId': sid,
                  'value': [
                    {'name': 'github', 'status': 'connected'},
                  ],
                }));
              } else if (ep == 'session/follow') {
                ws.add(jsonEncode({
                  'type': 'item',
                  'streamId': sid,
                  'value': {
                    'type': 'assistant-stream',
                    'frame': {
                      'type': 'chunk',
                      'chunk': {'type': 'text-delta', 'delta': 'Hello from stock DSH!'},
                    },
                  },
                }));
              } else if (ep == 'terminal/attach') {
                ws.add(jsonEncode({
                  'type': 'item',
                  'streamId': sid,
                  'value': {'type': 'snapshot', 'screen': 'remote# '},
                }));
              }
            } else if (type == 'item') {
              final val = msg['value'] as Map<String, dynamic>?;
              if (val?['type'] == 'write') {
                ws.add(jsonEncode({
                  'type': 'item',
                  'streamId': sid,
                  'value': {'type': 'output', 'data': 'OUT:${val?['data']}'},
                }));
              }
            }
          });
          return;
        }

        // Stock DSH unary Typert HTTP RPCs (`POST /api/<ns>/<method>`)
        if (req.method == 'POST' && path.startsWith('/api/')) {
          final bodyStr = await utf8.decoder.bind(req).join();
          final env = jsonDecode(bodyStr) as Map<String, dynamic>;
          final method = env['method']?.toString() ?? path.substring(5);
          final rpcId = env['rpcId']?.toString() ?? 'r1';
          final args = ((env['payload'] as Map?)?['args'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};

          dynamic value;
          if (method == 'session/list') {
            if (!args.containsKey('_request')) {
              req.response.statusCode = 200;
              req.response.headers.contentType = ContentType.json;
              req.response.write(jsonEncode({
                'type': 'server-response',
                'rpcId': rpcId,
                'result': {
                  'ok': false,
                  'error': {'code': 'gateway/arguments-invalid', 'message': 'expected _request'},
                },
              }));
              await req.response.close();
              return;
            }
            value = {
              'items': [
                {
                  'sessionId': 's-vanilla-1',
                  'title': 'Stock Remote Chat',
                  'cwd': '/Users/remote/project',
                  'updatedAt': 1700000000000,
                },
              ],
            };
          } else if (method == 'session/page') {
            value = {
              'hasMore': false,
              'records': [
                {
                  'type': 'event',
                  'event': {
                    'seq': 1,
                    'type': 'turn/start',
                    'data': {'turn': 1},
                  },
                },
                {
                  'type': 'event',
                  'event': {
                    'seq': 2,
                    'type': 'user/message',
                    'data': {
                      'source': {'kind': 'user'},
                      'content': [
                        {'type': 'text', 'text': 'Check files'},
                      ],
                    },
                  },
                },
                {
                  'type': 'event',
                  'event': {
                    'seq': 3,
                    'type': 'assistant/message',
                    'data': {
                      'content': [
                        {'type': 'reasoning', 'text': 'Inspecting workspace...'},
                        {
                          'type': 'tool-call',
                          'id': 'c-1',
                          'name': 'bash',
                          'arguments': {'command': 'ls'},
                        },
                      ],
                    },
                  },
                },
                {
                  'type': 'event',
                  'event': {
                    'seq': 4,
                    'type': 'tool/result',
                    'data': {'callId': 'c-1', 'name': 'bash', 'output': 'README.md\nsrc/'},
                  },
                },
                {
                  'type': 'event',
                  'event': {
                    'seq': 5,
                    'type': 'assistant/message',
                    'data': {
                      'content': [
                        {'type': 'text', 'text': 'Found README.md and src/.'},
                      ],
                    },
                  },
                },
                {
                  'type': 'event',
                  'event': {
                    'seq': 6,
                    'type': 'turn/end',
                    'data': {
                      'turn': 1,
                      'reason': {'kind': 'completed'},
                    },
                  },
                },
              ],
            };
          } else if (method == 'session/projections') {
            value = {'values': {'title': 'Stock Remote Chat'}};
          } else if (method == 'session/prompt') {
            receivedPrompts.add(args);
            value = {'accepted': true};
          } else if (method == 'session/modelCatalog') {
            value = {
              'groups': [
                {
                  'provider': 'deepseek',
                  'models': [
                    {'id': 'deepseek-chat', 'name': 'DeepSeek V3'},
                  ],
                },
              ],
            };
          } else if (method == 'llm/listProviders' || method == 'llm/listConfigurableProviders') {
            value = const [];
          } else if (method == r'$events/result') {
            settledEvents.add(args);
            value = true;
          } else {
            value = const <String, dynamic>{};
          }

          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'type': 'server-response',
            'rpcId': rpcId,
            'result': {'ok': true, 'value': value},
          }));
          await req.response.close();
          return;
        }

        req.response.statusCode = 404;
        await req.response.close();
      });
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    test('unauthenticated probe identifies stock DSH version, 403 fence, and HTML login proxy', () async {
      final noTokClient = GbridgeClient(
        HostEndpoint.http(baseUri: Uri.parse('http://127.0.0.1:$port')),
        autoReconnect: false,
      );
      addTearDown(noTokClient.dispose);

      // 1) Stock DSH 401 -> still detects exact version `0.2.2-rc.5` via public `/plugins/events`!
      final needsAuth = await noTokClient.probeHost();
      expect(needsAuth, isA<HostProbeNeedsAuth>());
      final authProbe = needsAuth as HostProbeNeedsAuth;
      expect(authProbe.dshVersion, '0.2.2-rc.5');
      expect(authProbe.hasGbridge, isFalse);
      expect(authProbe.isHtmlLoginPage, isFalse);

      // 2) Untrusted Host 403 -> structured HostProbeUntrustedHost
      simulateForbiddenHost = true;
      final forbidden = await noTokClient.probeHost();
      simulateForbiddenHost = false;
      expect(forbidden, isA<HostProbeUntrustedHost>());
      expect((forbidden as HostProbeUntrustedHost).dshVersion, '0.2.2-rc.5');

      // 3) Reverse-proxy HTML login page -> HostProbeNeedsAuth(isHtmlLoginPage: true)
      simulateHtmlLogin = true;
      final htmlLogin = await noTokClient.probeHost();
      simulateHtmlLogin = false;
      expect(htmlLogin, isA<HostProbeNeedsAuth>());
      expect((htmlLogin as HostProbeNeedsAuth).isHtmlLoginPage, isTrue);
    });

    test('persists 30-day cookie and runs FULL direct mode WITHOUT token or plugin', () async {
      // Phase A: Authenticate once with launch token -> capture 30-day cookie via callback.
      String? persistedCookie;
      final firstClient = GbridgeClient(
        HostEndpoint.http(
          baseUri: Uri.parse('http://127.0.0.1:$port'),
          token: 'one-time-launch-tok',
        ),
        autoReconnect: false,
        onCookieUpdated: (c) => persistedCookie = c,
      );
      final ok = await firstClient.exchangeAuthToken();
      await firstClient.dispose();
      expect(ok, isTrue);
      expect(persistedCookie, contains('dsh-auth-test=v1.persisted30daycookie'));

      // Phase B: Connect a brand-new client with ZERO token (only the saved 30-day cookie)!
      final directClient = GbridgeClient(
        HostEndpoint.http(
          baseUri: Uri.parse('http://127.0.0.1:$port'),
          cookie: persistedCookie,
        ),
        autoReconnect: false,
      );
      addTearDown(directClient.dispose);

      final probe = await directClient.probeHost();
      expect(probe, isA<HostProbeVanillaDirect>());
      final directProbe = probe as HostProbeVanillaDirect;
      expect(directProbe.dshVersion, '0.2.2-rc.5');

      // Enable zero-plugin direct mode!
      final caps = directClient.enableVanillaDirectMode(dshVersion: directProbe.dshVersion);
      expect(directClient.isVanillaDirect, isTrue);
      expect(caps.bridgeVersion, 'direct');

      // Connect WS /api/remote.mux -> receives $events ready + approval waterfall!
      final approvalFuture = directClient.stream.frames.firstWhere(
        (f) => f.type == 'interaction.requested',
      );
      final welcome = await directClient.stream.connect();
      expect(welcome.bootId, startsWith('vanilla-'));
      final approvalFrame = await approvalFuture.timeout(const Duration(seconds: 3));
      expect(approvalFrame.dataMap?['id'], 'appr-1');

      // Settle approval via POST /api/$events/result
      await directClient.respondInteraction('appr-1', decision: 'allow');
      expect(settledEvents, isNotEmpty);
      expect(settledEvents.last['eventId'], 'appr-1');
      expect((settledEvents.last['outcome'] as Map)['value'], 'allowed-once');

      // Workspaces + Sessions + MCP over direct mode
      final sessions = await directClient.listSessions();
      expect(sessions.length, 1);
      expect(sessions.first.id, 's-vanilla-1');
      expect(sessions.first.pinned, isTrue);
      expect(sessions.first.workspaceId, 'ws-1');

      final mcp = await directClient.listMcpServers();
      expect((mcp['servers'] as List).length, 1);

      // History turns normalized in Dart + lazy full tool output from Dart LRU cache!
      final page = await directClient.getSessionTurns('s-vanilla-1');
      expect(page.turns.length, 1);
      expect(page.turns.first.userMessage?.text, 'Check files');
      expect(page.turns.first.assistantText, 'Found README.md and src/.');
      expect(page.turns.first.steps.length, 2);
      final toolDetail = await directClient.getToolOutput('s-vanilla-1', 'c-1');
      expect(toolDetail['output'], 'README.md\nsrc/');

      // Send prompt via POST /api/session/prompt
      await directClient.sendMessage('s-vanilla-1', text: 'Run tests');
      expect(receivedPrompts, isNotEmpty);

      // Real-time session/follow delta over WS /api/remote.mux
      final deltaFuture = directClient.stream.frames.firstWhere((f) => f.type == 'turn.delta');
      directClient.stream.subscribe('session:s-vanilla-1');
      final deltaFrame = await deltaFuture.timeout(const Duration(seconds: 3));
      expect((deltaFrame.dataMap?['chunk'] as Map?)?['delta'], 'Hello from stock DSH!');

      // Real-time bidirectional PTY terminal over WS /api/remote.mux
      final snapFuture = directClient.stream.frames.firstWhere((f) => f.type == 'term.snapshot');
      directClient.stream.subscribe('terminal:s-vanilla-1:t1');
      final snapFrame = await snapFuture.timeout(const Duration(seconds: 3));
      expect(snapFrame.dataMap?['screen'], 'remote# ');

      final echoFuture = directClient.stream.frames.firstWhere((f) => f.type == 'term.data');
      directClient.stream.sendTerminalInput('t1', 'pwd\n');
      final echoFrame = await echoFuture.timeout(const Duration(seconds: 3));
      expect(echoFrame.dataMap?['chunk'], 'OUT:pwd\n');
    });
  });

  group('Self-device exclusion & IPv6 remote address parsing', () {
    test('isLoopbackHost classifies loopback & wildcard hosts accurately', () {
      expect(isLoopbackHost('127.0.0.1'), isTrue);
      expect(isLoopbackHost('127.0.1.1'), isTrue);
      expect(isLoopbackHost('localhost'), isTrue);
      expect(isLoopbackHost('::1'), isTrue);
      expect(isLoopbackHost('[::1]'), isTrue);
      expect(isLoopbackHost('0.0.0.0'), isTrue);
      expect(isLoopbackHost('::'), isTrue);
      expect(isLoopbackHost('192.168.1.50'), isFalse);
      expect(isLoopbackHost('mac-studio.local'), isFalse);
    });

    test('isSelfDeviceUri blocks loopback and own NIC IPs on Android while allowing remote LAN hosts', () {
      const localIps = {'192.168.1.42', '10.0.2.16', 'fe80::1'};
      expect(
        isSelfDeviceUri(
          Uri.parse('http://127.0.0.1:3080'),
          localIps,
          isAndroidNative: true,
        ),
        isTrue,
      );
      expect(
        isSelfDeviceUri(
          Uri.parse('http://localhost:13080'),
          localIps,
          isAndroidNative: true,
        ),
        isTrue,
      );
      expect(
        isSelfDeviceUri(
          Uri.parse('http://[::1]:3080'),
          localIps,
          isAndroidNative: true,
        ),
        isTrue,
      );
      expect(
        isSelfDeviceUri(
          Uri.parse('http://192.168.1.42:3080'),
          localIps,
          isAndroidNative: true,
        ),
        isTrue,
      );
      expect(
        isSelfDeviceUri(
          Uri.parse('http://10.0.2.16:3081'),
          localIps,
          isAndroidNative: true,
        ),
        isTrue,
      );
      expect(
        isSelfDeviceUri(
          Uri.parse('http://192.168.1.99:3080'),
          localIps,
          isAndroidNative: true,
        ),
        isFalse,
      );
      expect(
        isSelfDeviceUri(
          Uri.parse('http://192.168.1.99:3081'),
          localIps,
          isAndroidNative: true,
        ),
        isFalse,
      );
    });

    test('isSelfDeviceUri on Desktop/Web blocks same-port local host but permits distinct Desktop Bridge / SSH tunnel ports', () {
      final localUri = Uri.parse('http://127.0.0.1:3080');
      const localIps = {'192.168.1.42'};
      expect(
        isSelfDeviceUri(
          Uri.parse('http://127.0.0.1:3080'),
          localIps,
          isAndroidNative: false,
          localHostUri: localUri,
        ),
        isTrue,
      );
      expect(
        isSelfDeviceUri(
          Uri.parse('http://192.168.1.42:3080'),
          localIps,
          isAndroidNative: false,
          localHostUri: localUri,
        ),
        isTrue,
      );
      expect(
        isSelfDeviceUri(
          Uri.parse('http://127.0.0.1:3081'),
          localIps,
          isAndroidNative: false,
          localHostUri: localUri,
        ),
        isFalse,
      );
    });

    test('parseRemoteHostInput cleanly parses IPv6 URLs with tokens', () {
      final parsed = parseRemoteHostInput('dsh web: http://[::1]:3080/?token=ipv6tok1234567890');
      expect(parsed, isNotNull);
      expect(parsed!.address, 'http://[::1]:3080');
      expect(parsed.token, 'ipv6tok1234567890');
    });

    test('parseRemoteHostInput prefers non-loopback LAN token URL over 127.0.0.1 in multi-line terminal output', () {
      const paste = '''
  Local:   http://127.0.0.1:3080/?token=tok_lan_1234567890
  Network: http://192.168.1.88:3080/?token=tok_lan_1234567890
''';
      final parsed = parseRemoteHostInput(paste);
      expect(parsed, isNotNull);
      expect(parsed!.address, 'http://192.168.1.88:3080');
      expect(parsed.token, 'tok_lan_1234567890');
    });
  });

  group('VanillaDshAdapter wire-contract regressions', () {
    test('session/create, updateQueue, respondInteraction, deleteSchedule, uploadBinary & >64 credentials chunking match DSH schema', () async {
      final recorded = <({String method, String path, Map<String, dynamic>? body})>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((HttpRequest req) async {
        if (req.uri.path == '/api/remote.mux' && WebSocketTransformer.isUpgradeRequest(req)) {
          final ws = await WebSocketTransformer.upgrade(req);
          ws.listen((raw) {
            final msg = jsonDecode(raw.toString()) as Map<String, dynamic>;
            if (msg['type'] == 'open' && msg['endpoint'] == r'$events') {
              final sid = msg['streamId'];
              ws.add(jsonEncode({
                'type': 'item',
                'streamId': sid,
                'value': {'type': 'ready', 'clientId': 'cli-direct-1'},
              }));
              ws.add(jsonEncode({
                'type': 'item',
                'streamId': sid,
                'value': {
                  'type': 'waterfall',
                  'event': 'approval/request',
                  'eventId': 'int-1',
                  'agentId': 's-new-1',
                  'request': {'toolName': 'bash', 'command': 'ls'},
                },
              }));
              ws.add(jsonEncode({
                'type': 'item',
                'streamId': sid,
                'value': {
                  'type': 'waterfall',
                  'event': 'user-questions/request',
                  'eventId': 'int-2',
                  'agentId': 's-new-1',
                  'request': {'title': 'Pick one', 'questions': []},
                },
              }));
            }
          });
          return;
        }
        final rawBody = await utf8.decoder.bind(req).join();
        Map<String, dynamic>? parsedBody;
        if (rawBody.isNotEmpty) {
          try {
            final d = jsonDecode(rawBody);
            if (d is Map) parsedBody = Map<String, dynamic>.from(d);
          } catch (_) {}
        }
        recorded.add((method: req.method, path: req.uri.toString(), body: parsedBody));

        req.response.headers.contentType = ContentType.json;
        final payload = parsedBody?['payload'];
        final args = payload is Map && payload['args'] is Map
            ? Map<String, dynamic>.from(payload['args'] as Map)
            : parsedBody;
        if (req.uri.path == '/api/session/create') {
          req.response.write(jsonEncode({'result': {'ok': true, 'value': {'sessionId': 's-new-1'}}}));
        } else if (req.uri.path == '/api/credentials/describe') {
          final refs = (args?['refs'] as List?) ?? const [];
          req.response.write(jsonEncode({
            'result': {
              'ok': true,
              'value': {
                for (final r in refs) r.toString(): {'configured': true},
              },
            },
          }));
        } else if (req.uri.path == '/api/session/uploadFileBinary') {
          req.response.write(jsonEncode({'attachmentId': 'att-1'}));
        } else {
          req.response.write(jsonEncode({'result': {'ok': true, 'value': <String, dynamic>{}}}));
        }
        await req.response.close();
      });

      final baseUrl = 'http://127.0.0.1:${server.port}';
      final client = GbridgeClient(
        HostEndpoint.http(
          baseUri: Uri.parse(baseUrl),
          cookie: 'dsh-auth-test=1',
        ),
        autoReconnect: false,
      );
      client.enableVanillaDirectMode(dshVersion: '0.2.2-rc.5');
      addTearDown(client.dispose);

      Map<String, dynamic>? rpcArgs(({String method, String path, Map<String, dynamic>? body}) r) {
        final b = r.body;
        if (b == null) return null;
        if (b['payload'] is Map && (b['payload'] as Map)['args'] is Map) {
          return Map<String, dynamic>.from((b['payload'] as Map)['args'] as Map);
        }
        if (b['args'] is Map) return Map<String, dynamic>.from(b['args'] as Map);
        return b;
      }

      // 1. session/create sends workspaceId WITHOUT cwd when workspaceId is provided
      await client.createSession(workspaceId: 'ws-1', cwd: '/should/not/send', permission: 'full-access');
      final createArgs = rpcArgs(recorded.firstWhere((r) => r.path == '/api/session/create'));
      final createReq = createArgs?['request'] as Map?;
      expect(createReq?['workspaceId'], 'ws-1');
      expect(createReq?.containsKey('cwd'), isFalse);
      final permArgs = rpcArgs(recorded.firstWhere((r) => r.path == '/api/commands/execute'));
      expect(permArgs?['line'], '/permission full-access');

      // 2. updateQueue sends `{ kind: 'remove' }`
      await client.updateQueue('s-new-1', {'action': 'delete', 'itemId': 'q-1'});
      final qDelArgs = rpcArgs(recorded.firstWhere((r) => r.path == '/api/session/updateQueue'));
      final qDelReq = qDelArgs?['request'] as Map?;
      expect((qDelReq?['action'] as Map?)?['kind'], 'remove');

      // 3. Connect mux & verify respondInteraction uses `'rejected'` for deny & `{ answers: [...] }` for user_questions
      final qReady = client.stream.frames.firstWhere(
        (f) => f.type == 'interaction.requested' && f.dataMap?['id'] == 'int-2',
      );
      await client.stream.connect();
      await qReady.timeout(const Duration(seconds: 3));

      await client.respondInteraction('int-1', decision: 'deny');
      final denyArgs = rpcArgs(recorded.firstWhere((r) => r.path == r'/api/$events/result'));
      expect((denyArgs?['outcome'] as Map?)?['value'], 'rejected');

      await client.respondInteraction(
        'int-2',
        answers: [
          {'questionId': 'q1', 'answer': 'Option A'},
        ],
      );
      final qRespArgs = rpcArgs(recorded.lastWhere((r) => r.path == r'/api/$events/result'));
      expect((qRespArgs?['outcome'] as Map?)?['value'], isA<Map>());
      expect(((qRespArgs?['outcome'] as Map?)?['value'] as Map?)?['answers'], isA<List>());

      // 4. uploadBinary omits `mediaType` query for non-image MIME types
      await client.uploadBinary(
        Uint8List.fromList([1, 2, 3]),
        filename: 'notes.pdf',
        contentType: 'application/pdf',
      );
      final upCall = recorded.firstWhere((r) => r.path.startsWith('/api/session/uploadFileBinary'));
      expect(upCall.path.contains('mediaType='), isFalse);

      // 5. getCredentials chunks >64 refs into batches of 64
      final refs = List.generate(70, (i) => 'KEY_$i');
      final creds = await client.getCredentials(refs: refs);
      final credCalls = recorded.where((r) => r.path == '/api/credentials/describe').toList();
      expect(credCalls.length, 2);
      expect((rpcArgs(credCalls[0])?['refs'] as List).length, 64);
      expect((rpcArgs(credCalls[1])?['refs'] as List).length, inInclusiveRange(6, 64));
      expect((creds['credentials'] as Map)['KEY_69'], isNotNull);

      // 6. deleteSchedule invokes schedule/delete (falling back to schedule/edit if unsupported)
      await client.deleteSchedule('sched-9');
      final delSchedArgs = rpcArgs(recorded.firstWhere((r) => r.path == '/api/schedule/delete'));
      expect((delSchedArgs?['request'] as Map?)?['id'], 'sched-9');
    });
  });

  group('v14 Fluidity: TurnStreamReducer O(1) buffering, mux coalescing & checkLiveness guard', () {
    test('TurnStreamReducer buffers streaming text & reasoning chunks and flushes strictly before tool/end', () {
      final reducer = TurnStreamReducer();
      reducer.apply(StreamFrame(
        op: 'event',
        seq: 1,
        channel: 'session:s1',
        type: 'turn.start',
        data: {'turnId': 't-1', 'eventSeq': 1},
      ));
      // 120 reasoning chunks spanning > 5KB with multiple lines
      final longIntro = 'A' * 4500;
      reducer.apply(StreamFrame(
        op: 'delta',
        seq: 2,
        channel: 'session:s1',
        type: 'reasoning.delta',
        data: {'turnId': 't-1', 'delta': '$longIntro\nFirst line\n', 'eventSeq': 2},
      ));
      for (var i = 0; i < 60; i++) {
        reducer.apply(StreamFrame(
          op: 'delta',
          seq: 3 + i,
          channel: 'session:s1',
          type: 'reasoning.delta',
          data: {'turnId': 't-1', 'delta': 'step-$i\n', 'eventSeq': 3 + i},
        ));
      }
      // 150 assistant text chunks
      for (var i = 0; i < 150; i++) {
        reducer.apply(StreamFrame(
          op: 'delta',
          seq: 100 + i,
          channel: 'session:s1',
          type: 'text.delta',
          data: {'turnId': 't-1', 'delta': 'w$i ', 'eventSeq': 100 + i},
        ));
      }
      final snap1 = reducer.turns;
      final snap2 = reducer.turns;
      expect(identical(snap1, snap2), isTrue); // Cached unmodifiable list reused between reads!
      expect(snap1.length, 1);
      final rStep = snap1.first.steps.first as ReasoningStep;
      expect(rStep.text.contains('step-59\n'), isTrue);
      expect(rStep.collapsedPreview, 'step-59');
      expect(snap1.first.assistantText.startsWith('w0 w1 '), isTrue);
      expect(snap1.first.assistantText.endsWith('w149 '), isTrue);

      // Structural turn.completed flushes cleanly
      reducer.apply(StreamFrame(
        op: 'event',
        seq: 300,
        channel: 'session:s1',
        type: 'turn.completed',
        data: {'turnId': 't-1', 'reason': 'completed', 'eventSeq': 300},
      ));
      expect(reducer.turns.first.status, 'completed');
      expect(reducer.turns.first.assistantText.endsWith('w149 '), isTrue);
    });

    test('VanillaDshMuxEngine coalesces burst text chunks & preserves order before turn.completed', () async {
      final serverMsgCtrl = StreamController<String>.broadcast();
      final sentFrames = <Map<String, dynamic>>[];
      final doneComp = Completer<void>();

      final mux = VanillaDshMuxEngine(
        normalizer: VanillaDshNormalizer(),
        autoReconnect: false,
        coalesceWindow: const Duration(milliseconds: 30),
        openSocket: (_) async => _FakeRawWs(serverMsgCtrl.stream, sentFrames, doneComp),
      );
      addTearDown(() async {
        await mux.dispose();
        await serverMsgCtrl.close();
      });

      final events = <StreamFrame>[];
      final sub = mux.frames.listen(events.add);
      addTearDown(sub.cancel);

      final connectFuture = mux.connect();
      // Let `$events` open send, then emit ready
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final eventsOpen = sentFrames.firstWhere((m) => m['endpoint'] == r'$events');
      serverMsgCtrl.add(jsonEncode({
        'type': 'item',
        'streamId': eventsOpen['streamId'],
        'value': {'type': 'ready', 'clientId': 'c-test'},
      }));
      await connectFuture;

      mux.subscribe('session:s-coal');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final sessOpen = sentFrames.firstWhere((m) => m['endpoint'] == 'session/follow');
      final sid = sessOpen['streamId'];

      // Burst 10 consecutive text chunks + immediate turn/end
      for (final word in ['One ', 'Two ', 'Three ', 'Four ', 'Five ']) {
        serverMsgCtrl.add(jsonEncode({
          'type': 'item',
          'streamId': sid,
          'value': {
            'type': 'assistant-stream',
            'frame': {
              'type': 'chunk',
              'chunk': {'type': 'text-delta', 'delta': word},
            },
          },
        }));
      }
      serverMsgCtrl.add(jsonEncode({
        'type': 'item',
        'streamId': sid,
        'value': {
          'type': 'event',
          'event': {'type': 'turn/end', 'seq': 9, 'data': {'reason': 'completed'}},
        },
      }));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final deltas = events.where((e) => e.type == 'turn.delta').toList();
      final ends = events.where((e) => e.type == 'turn.completed').toList();
      expect(deltas.length, 1); // 5 chunks coalesced into 1!
      expect((deltas.first.dataMap?['chunk'] as Map?)?['delta'], 'One Two Three Four Five ');
      expect(ends.length, 1);
      // Causal order: coalesced delta emitted strictly BEFORE turn.completed!
      expect(deltas.first.seq!, lessThan(ends.first.seq!));
    });

    test('VanillaDshMuxEngine checkLiveness() does NOT abort an in-flight connecting handshake', () async {
      var openCount = 0;
      final gate = Completer<GbridgeRawWebSocket>();
      final mux = VanillaDshMuxEngine(
        normalizer: VanillaDshNormalizer(),
        autoReconnect: false,
        openSocket: (_) {
          openCount++;
          return gate.future;
        },
      );
      addTearDown(mux.dispose);

      final connectFut = mux.connect();
      expect(mux.phase, ConnectionPhase.connecting);
      final alive = await mux.checkLiveness();
      expect(alive, isFalse);
      expect(openCount, 1); // Must NOT open a second socket or abort the handshake!

      final serverCtrl = StreamController<String>.broadcast();
      final sent = <Map<String, dynamic>>[];
      gate.complete(_FakeRawWs(serverCtrl.stream, sent, Completer<void>()));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final evOpen = sent.firstWhere((m) => m['endpoint'] == r'$events');
      serverCtrl.add(jsonEncode({
        'type': 'item',
        'streamId': evOpen['streamId'],
        'value': {'type': 'ready', 'clientId': 'c-live'},
      }));
      await connectFut;
      expect(mux.phase, ConnectionPhase.connected);
      await serverCtrl.close();
    });

    test('VanillaDshNormalizer humanizes phone_* tools, flags blocked results as error, and preserves image attachment data', () {
      final norm = VanillaDshNormalizer();
      final turns = norm.normalizeEvents('s-vanilla-v27', [
        {'seq': 1, 'type': 'turn/start', 'turnId': 'tv-1', 'data': {'turnId': 'tv-1'}},
        {
          'seq': 2,
          'type': 'user/message',
          'turnId': 'tv-1',
          'data': {
            'id': 'uv-1',
            'content': [
              {'type': 'text', 'text': '打开时钟'},
              {'type': 'image', 'name': 'p.png', 'mimeType': 'image/png', 'data': 'BASE64_IMG'},
            ],
          },
        },
        {
          'seq': 3,
          'type': 'tool/call',
          'turnId': 'tv-1',
          'data': {'callId': 'v-open', 'name': 'phone_open', 'arguments': {'package': 'com.android.deskclock'}},
        },
        {
          'seq': 4,
          'type': 'tool/result',
          'turnId': 'tv-1',
          'data': {
            'callId': 'v-open',
            'name': 'phone_open',
            'output': jsonEncode({'ok': true, 'opened': '时钟', 'package': 'com.android.deskclock'}),
          },
        },
        {
          'seq': 5,
          'type': 'tool/call',
          'turnId': 'tv-1',
          'data': {'callId': 'v-tap', 'name': 'phone_tap', 'arguments': {'x': 120, 'y': 240}},
        },
        {
          'seq': 6,
          'type': 'tool/result',
          'turnId': 'tv-1',
          'data': {
            'callId': 'v-tap',
            'name': 'phone_tap',
            'output': jsonEncode({'ok': false, 'blocked': true, 'hint': '高风险按钮已拦截'}),
          },
        },
        {'seq': 7, 'type': 'turn/end', 'turnId': 'tv-1', 'data': {'turnId': 'tv-1'}},
      ]);

      expect(turns.length, 1);
      final t0 = turns.first;
      final userMsg = t0['userMessage'] as Map<String, dynamic>;
      final atts = (userMsg['attachments'] as List).cast<Map<String, dynamic>>();
      expect(atts.length, 1);
      expect(atts.first['data'], 'BASE64_IMG');
      final steps = (t0['steps'] as List).cast<Map<String, dynamic>>();
      final openStep = steps.firstWhere((s) => s['callId'] == 'v-open');
      expect(openStep['title'].toString(), contains('时钟'));
      final tapStep = steps.firstWhere((s) => s['callId'] == 'v-tap');
      expect(tapStep['status'], 'error');
      expect(tapStep['summary'].toString(), contains('高风险按钮已拦截'));
    });

    test('VanillaDshNormalizer never wipes cached tool output on replayed tool/call & mux disconnect settles pending interactions', () async {
      final norm = VanillaDshNormalizer();
      norm.normalizeEvents('s-v28-cache', [
        {'seq': 1, 'type': 'turn/start', 'turnId': 't1', 'data': {'turnId': 't1'}},
        {'seq': 2, 'type': 'tool/call', 'turnId': 't1', 'data': {'callId': 'c1', 'name': 'bash', 'arguments': {'command': 'pwd'}}},
        {'seq': 3, 'type': 'tool/result', 'turnId': 't1', 'data': {'callId': 'c1', 'name': 'bash', 'output': '/root/workspace'}},
        {'seq': 4, 'type': 'tool/call', 'turnId': 't1', 'data': {'callId': 'c1', 'name': 'bash', 'arguments': {'command': 'pwd'}}},
      ]);
      final cached = norm.getToolOutput('s-v28-cache', 'c1');
      expect(cached?['output'], '/root/workspace');
      expect(cached?['status'], 'ok');

      // Socket drop emits interaction.resolved (reason: disconnected) for any open interaction!
      final serverCtrl = StreamController<String>.broadcast();
      final sent = <Map<String, dynamic>>[];
      final done = Completer<void>();
      final mux = VanillaDshMuxEngine(
        normalizer: norm,
        autoReconnect: false,
        openSocket: (_) async => _FakeRawWs(serverCtrl.stream, sent, done),
      );
      addTearDown(() async {
        mux.dispose();
        await serverCtrl.close();
      });

      final frames = <StreamFrame>[];
      final sub = mux.frames.listen(frames.add);
      addTearDown(sub.cancel);

      final connectFut = mux.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final evOpen = sent.firstWhere((m) => m['endpoint'] == r'$events');
      serverCtrl.add(jsonEncode({
        'type': 'item',
        'streamId': evOpen['streamId'],
        'value': {'type': 'ready', 'clientId': 'c-drop-test'},
      }));
      await connectFut;

      // Simulate an incoming cordis/request-run interaction on $events
      serverCtrl.add(jsonEncode({
        'type': 'item',
        'streamId': evOpen['streamId'],
        'value': {
          'type': 'emit',
          'event': 'cordis/request-run',
          'args': [
            {'id': 'req-42', 'sessionId': 's-drop', 'plugin': 'demo'},
          ],
        },
      }));
      await Future<void>.delayed(const Duration(milliseconds: 15));

      // Drop the socket abruptly
      if (!done.isCompleted) done.complete();
      await serverCtrl.close();
      await Future<void>.delayed(const Duration(milliseconds: 25));

      final resolved = frames.where((f) => f.type == 'interaction.resolved').toList();
      expect(resolved, isNotEmpty);
      expect(resolved.first.dataMap?['reason'], 'disconnected');
    });

    test('v33 regression: deleteSession propagates errors, startSignIn uses loopback callbackOrigin, session always-allow excludes phone_*, and getSettingsSchema(forceFresh: true) bypasses cache', () async {
      final autoApproved = <(String, String)>[];
      final serverCtrl = StreamController<String>.broadcast();
      final sent = <Map<String, dynamic>>[];
      final done = Completer<void>();
      final mux = VanillaDshMuxEngine(
        normalizer: VanillaDshNormalizer(),
        autoReconnect: false,
        openSocket: (_) async => _FakeRawWs(serverCtrl.stream, sent, done),
        onAutoApprove: (clientId, eventId) async {
          autoApproved.add((clientId, eventId));
        },
      );
      addTearDown(() async {
        mux.dispose();
        await serverCtrl.close();
      });

      final frames = <StreamFrame>[];
      final sub = mux.frames.listen(frames.add);
      addTearDown(sub.cancel);

      final connectFut = mux.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final evOpen = sent.firstWhere((m) => m['endpoint'] == r'$events');
      serverCtrl.add(jsonEncode({
        'type': 'item',
        'streamId': evOpen['streamId'],
        'value': {'type': 'ready', 'clientId': 'c-v33'},
      }));
      await connectFut;

      // Remember 'bash' and attempt to remember 'phone_tap' (phone_* MUST be ignored!)
      mux.rememberSessionAlwaysAllowed('s-1', {'tool': 'bash'});
      mux.rememberSessionAlwaysAllowed('s-1', {'tool': 'phone_tap'});

      // bash approval on s-1 -> auto-approved, NOT emitted to UI
      serverCtrl.add(jsonEncode({
        'type': 'item',
        'streamId': evOpen['streamId'],
        'value': {
          'type': 'waterfall',
          'event': 'approval/request',
          'eventId': 'ev-bash',
          'agentId': 's-1',
          'request': {'tool': 'bash', 'command': 'ls'},
        },
      }));
      // phone_tap approval on s-1 -> NEVER auto-approved, emitted to UI!
      serverCtrl.add(jsonEncode({
        'type': 'item',
        'streamId': evOpen['streamId'],
        'value': {
          'type': 'waterfall',
          'event': 'approval/request',
          'eventId': 'ev-phone',
          'agentId': 's-1',
          'request': {'tool': 'phone_tap', 'x': 10, 'y': 20},
        },
      }));
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(autoApproved, [('c-v33', 'ev-bash')]);
      final reqs = frames.where((f) => f.type == 'interaction.requested').toList();
      expect(reqs.length, 1);
      expect(reqs.first.dataMap?['id'], 'ev-phone');

      // Local HTTP mock for deleteSession error propagation, settings/describe forceFresh, and startSignIn callbackOrigin
      var describeCalls = 0;
      String? capturedCallbackOrigin;
      final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => srv.close(force: true));
      srv.listen((req) async {
        final rawBody = await utf8.decoder.bind(req).join();
        final body = rawBody.isEmpty ? <String, dynamic>{} : (jsonDecode(rawBody) as Map<String, dynamic>);
        final payload = body['payload'] is Map ? body['payload'] as Map : const <String, dynamic>{};
        final args = payload['args'] is Map ? payload['args'] as Map : const <String, dynamic>{};
        if (req.uri.path == '/api/session/delete') {
          req.response.statusCode = 500;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'result': {'ok': false, 'error': {'message': 'session locked'}}}));
        } else if (req.uri.path == '/api/settings/describe') {
          describeCalls++;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'result': {
              'ok': true,
              'value': {
                'sections': [
                  {'ns': 'llm-pi-ai', 'revision': describeCalls, 'value': {}},
                ],
              },
            },
          }));
        } else if (req.uri.path == '/api/account/startSignIn') {
          capturedCallbackOrigin = args['callbackOrigin']?.toString();
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'result': {
              'ok': true,
              'value': {'attemptId': 'att-1'},
            },
          }));
        } else if (req.uri.path == '/api/account/getState') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'result': {
              'ok': true,
              'value': {
                'status': 'signing_in',
                'attempt': {'phase': 'awaiting_callback', 'authorizeUrl': 'https://auth.example/oauth'},
              },
            },
          }));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final endpoint = HostEndpoint.http(
        baseUri: Uri.parse('http://127.0.0.1:${srv.port}'),
      );
      final client = GbridgeClient(endpoint, autoReconnect: false);
      addTearDown(client.dispose);
      client.enableVanillaDirectMode(dshVersion: '0.2.2-rc.5');

      // 1. deleteSession must NOT swallow HTTP 500 error!
      await expectLater(
        () => client.deleteSession('s-locked'),
        throwsA(isA<GbridgeException>()),
      );

      // 2. getSettingsSchema(forceFresh: true) bypasses micro-cache
      await client.getSettingsSchema();
      expect(describeCalls, 1);
      await client.getSettingsSchema();
      expect(describeCalls, 1);
      await client.getSettingsSchema(forceFresh: true);
      expect(describeCalls, 2);

      // 3. startSignIn defaults callbackOrigin to loopback http://127.0.0.1:<port> & reads st['attempt'].authorizeUrl
      final signInRes = await client.accountAction('startSignIn');
      expect(capturedCallbackOrigin, 'http://127.0.0.1:${srv.port}');
      expect((signInRes['result'] as Map)['authorizeUrl'], 'https://auth.example/oauth');
    });

    test('v34 regression: TurnStreamReducer O(1) activeTurnHasOutput, VanillaDshNormalizer byte-capped object truncation & SessionSummary sanitization', () {
      // 1. O(1) activeTurnHasOutput & isActiveTurnEmpty inspect buffered chunks without flushing
      final reducer = TurnStreamReducer();
      reducer.apply(StreamFrame(
        op: 'event',
        seq: 1,
        channel: 'session:s-v34',
        type: 'turn.start',
        data: {'turnId': 't-v34', 'eventSeq': 1},
      ));
      expect(reducer.isActiveTurnEmpty, isTrue);
      expect(reducer.activeTurnHasOutput, isFalse);

      reducer.apply(StreamFrame(
        op: 'delta',
        seq: 2,
        channel: 'session:s-v34',
        type: 'text.delta',
        data: {'turnId': 't-v34', 'delta': 'Hello', 'eventSeq': 2},
      ));
      expect(reducer.activeTurnHasOutput, isTrue);
      expect(reducer.isActiveTurnEmpty, isFalse);
      expect(reducer.turns.first.assistantText, 'Hello');

      // 2. VanillaDshNormalizer truncates oversized map output (>512 KiB) & enforces byte cap
      final norm = VanillaDshNormalizer(maxCacheBytes: 300 * 1024);
      final hugeMap = {
        'rows': List.generate(10000, (i) => 'line-$i-${'x' * 60}'),
      };
      norm.cacheToolOutput('s-v34', 'c-big', {
        'tool': 'read',
        'status': 'ok',
        'output': hugeMap,
      });
      final cached = norm.getToolOutput('s-v34', 'c-big');
      expect(cached?['truncated'], isTrue);
      expect(cached?['output'], isA<String>());
      expect((cached?['output'] as String).contains('已截断'), isTrue);

      // 3. SessionSummary hoisted static regexes sanitize corrupt placeholder titles
      final sum = SessionSummary.fromJson({
        'id': 's-corrupt',
        'title': '[object Object]',
        'workingDirectory': '/Users/dev/grassbag',
      });
      expect(sum.title, isNot(contains('[object Object]')));
    });
  });
}

class _FakeRawWs implements GbridgeRawWebSocket {
  _FakeRawWs(this.messages, this.sentFrames, this._done);

  @override
  final Stream<String> messages;
  final List<Map<String, dynamic>> sentFrames;
  final Completer<void> _done;

  @override
  Future<void> get done => _done.future;

  @override
  void sendText(String text) {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) sentFrames.add(decoded);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_done.isCompleted) _done.complete();
  }
}
