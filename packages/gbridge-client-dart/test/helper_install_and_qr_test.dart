import 'dart:convert';
import 'dart:io';

import 'package:gbridge_client/gbridge_client.dart';
import 'package:test/test.dart';

void main() {
  group('QR pairing payload parsing', () {
    test('parses grassbag://pair deep link with encoded URL, token, and host name', () {
      const qr =
          'grassbag://pair?url=http%3A%2F%2F192.168.31.42%3A3081&token=gb_tok_987654321&name=Studio-Mac';
      final parsed = parseRemoteHostInput(qr);
      expect(parsed, isNotNull);
      expect(parsed!.address, 'http://192.168.31.42:3081');
      expect(parsed.token, 'gb_tok_987654321');
      expect(parsed.suggestedName, 'Studio-Mac');
    });

    test('parses http:// URL with ?token= and &name= and strips /gbridge/ui', () {
      const qr = 'http://100.64.2.9:3081/gbridge/ui?token=ts_tok_123456&name=Office-PC';
      final parsed = parseRemoteHostInput(qr);
      expect(parsed, isNotNull);
      expect(parsed!.address, 'http://100.64.2.9:3081');
      expect(parsed.token, 'ts_tok_123456');
      expect(parsed.suggestedName, 'Office-PC');
    });

    test('parses JSON QR payload', () {
      const qr = '{"url":"http://192.168.1.99:3081","token":"json_tok_abc","name":"DevBox"}';
      final parsed = parseRemoteHostInput(qr);
      expect(parsed, isNotNull);
      expect(parsed!.address, 'http://192.168.1.99:3081');
      expect(parsed.token, 'json_tok_abc');
      expect(parsed.suggestedName, 'DevBox');
    });
  });

  group('installHelperBundleDetailed mirror fallback & ChangeResult handling', () {
    test('automatically falls back from mirror 1 -> mirror 2 and returns capabilities', () async {
      final attemptedSpecs = <String>[];
      var installed = false;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final path = req.uri.path;
        if (path == '/api/pluginManager/installBundle') {
          final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
          final args = (body['payload'] as Map)['args'] as Map;
          final spec = args['spec'].toString();
          attemptedSpecs.add(spec);
          if (attemptedSpecs.length == 1) {
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'result': {
                  'ok': true,
                  'value': {
                    'application': 'failed',
                    'error': {'message': 'mirror 1 fetch 502'},
                  },
                },
              }));
            await req.response.close();
            return;
          }
          installed = true;
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'result': {
                'ok': true,
                'value': {'application': 'applied'},
              },
            }));
          await req.response.close();
          return;
        }
        if (path == '/gbridge/v1/capabilities' && installed) {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'v': 1,
              'bridgeVersion': '0.2.0',
              'dshVersion': '0.2.2-rc.5',
              'bootId': 'boot-mirror-ok',
              'host': {'name': 'PC', 'platform': 'darwin', 'arch': 'arm64'},
              'transport': {'wsPath': '/gbridge/v1/stream'},
              'domains': {'chat': {'ok': true}},
              'endpointsCount': 40,
            }));
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final client = GbridgeClient(
        HostEndpoint.http(baseUri: Uri.parse('http://127.0.0.1:${server.port}')),
        autoReconnect: false,
      );
      addTearDown(client.dispose);

      final result = await client.bootstrap.installHelperBundleDetailed(
        packageSpec: 'dsh-gbridge',
        pollInterval: const Duration(milliseconds: 50),
      );
      expect(attemptedSpecs.length, 2);
      expect(attemptedSpecs[0], kOfficialGbridgeInstallSpecs[0]);
      expect(attemptedSpecs[1], kOfficialGbridgeInstallSpecs[1]);
      expect(result.restartRequired, isFalse);
      expect(result.capabilities?.bridgeVersion, '0.2.0');
    });

    test('fails fast on pnpm-missing without spinning into timeout', () async {
      var calls = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        calls++;
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'result': {
              'ok': true,
              'value': {
                'application': 'failed',
                'packageResult': {'kind': 'pnpm-missing'},
              },
            },
          }));
        await req.response.close();
      });

      final client = GbridgeClient(
        HostEndpoint.http(baseUri: Uri.parse('http://127.0.0.1:${server.port}')),
        autoReconnect: false,
      );
      addTearDown(client.dispose);

      await expectLater(
        client.bootstrap.installHelperBundleDetailed(packageSpec: 'dsh-gbridge'),
        throwsA(isA<GbridgeException>().having((e) => e.code, 'code', 'plugin/pnpm_missing')),
      );
      expect(calls, 1);
    });

    test('returns restartRequired immediately when DSH reports application=restart-required', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'result': {
              'ok': true,
              'value': {'application': 'restart-required'},
            },
          }));
        await req.response.close();
      });

      final client = GbridgeClient(
        HostEndpoint.http(baseUri: Uri.parse('http://127.0.0.1:${server.port}')),
        autoReconnect: false,
      );
      addTearDown(client.dispose);

      final res = await client.bootstrap.installHelperBundleDetailed(
        packageSpec: kOfficialGbridgeDirectUrl,
      );
      expect(res.restartRequired, isTrue);
      expect(res.capabilities, isNull);
    });
  });

  group('Transient HTTP 503 gbridge/reloading automatic retry', () {
    test('retries HTTP 503 gbridge/reloading and resolves once Cordis finishes reload', () async {
      var attempts = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        if (req.uri.path == '/gbridge/v1/capabilities') {
          attempts++;
          if (attempts <= 2) {
            req.response
              ..statusCode = 503
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'error': {
                  'code': 'gbridge/reloading',
                  'message': 'Cordis profile reload in progress',
                },
              }));
            await req.response.close();
            return;
          }
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'v': 1,
              'bridgeVersion': '0.2.0',
              'dshVersion': '0.2.2-rc.5',
              'bootId': 'boot-after-reload',
              'host': {'name': 'AndroidLocal', 'platform': 'linux', 'arch': 'arm64'},
              'transport': {'wsPath': '/gbridge/v1/stream'},
              'domains': {'chat': {'ok': true}, 'models': {'ok': true}},
              'endpointsCount': 40,
            }));
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final client = GbridgeClient(
        HostEndpoint.http(baseUri: Uri.parse('http://127.0.0.1:${server.port}')),
        autoReconnect: false,
      );
      addTearDown(client.dispose);

      final caps = await client.getCapabilities();
      expect(attempts, 3);
      expect(caps.bootId, 'boot-after-reload');
      expect(caps.bridgeVersion, '0.2.0');
    });
  });
}
