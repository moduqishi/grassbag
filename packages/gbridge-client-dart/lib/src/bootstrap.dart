import 'dart:async';

import 'models.dart';
import 'transport.dart';

/// Structured result of probing a DSH host so GrassBag automatically selects:
/// - [HostProbeFull]: Full `dsh-gbridge` enhanced mode (`/gbridge/v1` + replay stream)
/// - [HostProbeVanillaDirect]: Zero-plugin direct stock `dsh web` mode (`POST /api/*` + `WS /api/remote.mux`)
/// - [HostProbeNeedsAuth]: Genuine DSH (or proxy-protected) host reachable, awaiting 1-time auth/cookie
/// - [HostProbeUntrustedHost]: Genuine DSH host rejecting `Host`/`Origin` header (`403`, needs `--host` or `--trusted-host`)
/// - [HostProbeBootstrapOnly]: Legacy fallback when vanilla DSH is reachable but RPCs failed
sealed class HostProbeResult {
  const HostProbeResult();
}

class HostProbeFull extends HostProbeResult {
  const HostProbeFull(this.capabilities);
  final Capabilities capabilities;
}

class HostProbeVanillaDirect extends HostProbeResult {
  const HostProbeVanillaDirect({
    required this.dshVersion,
    required this.capabilities,
  });

  final String dshVersion;
  final Capabilities capabilities;
}

class HostProbeNeedsAuth extends HostProbeResult {
  const HostProbeNeedsAuth({
    this.dshVersion,
    this.hasGbridge = false,
    this.isHtmlLoginPage = false,
    this.message,
  });

  final String? dshVersion;
  final bool hasGbridge;
  final bool isHtmlLoginPage;
  final String? message;
}

class HostProbeUntrustedHost extends HostProbeResult {
  const HostProbeUntrustedHost({
    required this.hostAuthority,
    this.dshVersion,
    this.message,
  });

  final String hostAuthority;
  final String? dshVersion;
  final String? message;
}

class HostProbeBootstrapOnly extends HostProbeResult {
  const HostProbeBootstrapOnly({
    required this.reason,
    this.dshVersion,
    this.canInstallRemote = true,
  });

  final String reason;
  final String? dshVersion;
  final bool canInstallRemote;
}

/// Probes a remote DSH host cleanly across:
/// 1) `/gbridge/v1/capabilities` (enhanced `dsh-gbridge` mode)
/// 2) Stock DSH public `/plugins/events` SSE + `POST /api/session/list` (zero-plugin direct mode!)
/// 3) Clear classification of `401` (needs token or in-app WebView login) vs `403` (untrusted Host) vs HTML proxy.
class RemoteBootstrapClient {
  RemoteBootstrapClient(this._transport);

  final GbridgeHttpTransport _transport;

  /// Probe host protocol capabilities, auth state, and DSH version.
  Future<HostProbeResult> probeHost() async {
    try {
      final raw = await _transport.requestJson('GET', '/gbridge/v1/capabilities');
      if (raw['domains'] is Map || raw['bridgeVersion'] != null) {
        return HostProbeFull(Capabilities.fromJson(raw));
      }
      // Unexpected non-gbridge JSON -> check vanilla DSH below.
    } on GbridgeException catch (err) {
      if (err.status == 401) {
        final dshVer = await _transport.probeDshSseVersion();
        return HostProbeNeedsAuth(
          dshVersion: dshVer,
          hasGbridge: err.code.startsWith('gbridge/') && err.code != 'gbridge/http_401',
          message: err.message,
        );
      }
      if (err.status == 403) {
        final dshVer = await _transport.probeDshSseVersion();
        final uri = _transport.endpoint.baseUri;
        final authority = uri == null
            ? 'unknown'
            : (uri.hasPort ? '${uri.host}:${uri.port}' : uri.host);
        return HostProbeUntrustedHost(
          hostAuthority: authority,
          dshVersion: dshVer,
          message: err.message,
        );
      }
      if (!err.isNotFound && err.code != 'gbridge/html_response') {
        rethrow;
      }
    }

    // `/gbridge/v1` not installed -> probe stock DSH directly (zero-plugin direct mode!).
    final sseVersionFuture = _transport.probeDshSseVersion();

    try {
      await _probeVanillaSessionList();
      final ver = await sseVersionFuture ?? 'dsh';
      final hostName = _transport.endpoint.baseUri?.host ?? 'remote-dsh';
      final directCaps = Capabilities(
        v: 1,
        bridgeVersion: 'direct',
        dshVersion: ver,
        bootId: 'vanilla-$hostName',
        host: HostInfo(
          name: hostName,
          platform: 'remote',
          arch: 'direct',
          isLocalAndroid: false,
        ),
        transport: const TransportCapabilities(
          wsPath: '/api/remote.mux',
          coalesceMs: 35,
          replayCapacity: 0,
        ),
        domains: const {
          'chat': DomainCapability(ok: true, features: ['streaming', 'turns', 'search', 'fork', 'queue', 'attachments']),
          'interactions': DomainCapability(ok: true, features: ['approval', 'user_questions']),
          'workspaces': DomainCapability(ok: true, features: ['list', 'create', 'rename', 'delete', 'browse']),
          'files': DomainCapability(ok: true, features: ['tree', 'read', 'changes', 'upload']),
          'terminal': DomainCapability(ok: true, features: ['pty', 'shells', 'multi_tab']),
          'settings': DomainCapability(ok: true, features: ['schema', 'manifest', 'models', 'credentials', 'account', 'presets']),
          'plugins': DomainCapability(ok: true, features: ['bundles', 'entries', 'install', 'mcp']),
          'schedule': DomainCapability(ok: true, features: ['list', 'create', 'edit', 'run', 'history']),
          'jobs': DomainCapability(ok: true, features: ['list', 'follow', 'kill']),
          'goals': DomainCapability(ok: true, features: ['get', 'mutate']),
          'subagents': DomainCapability(ok: true, features: ['prompt', 'interrupt']),
          'sdui': DomainCapability(ok: false, reason: 'direct_mode'),
        },
        endpointsCount: 60,
      );
      return HostProbeVanillaDirect(dshVersion: ver, capabilities: directCaps);
    } on GbridgeException catch (err) {
      final dshVer = await sseVersionFuture;
      if (err.status == 401) {
        return HostProbeNeedsAuth(
          dshVersion: dshVer,
          hasGbridge: false,
          message: err.message,
        );
      }
      if (err.status == 403) {
        final uri = _transport.endpoint.baseUri;
        final authority = uri == null
            ? 'unknown'
            : (uri.hasPort ? '${uri.host}:${uri.port}' : uri.host);
        return HostProbeUntrustedHost(
          hostAuthority: authority,
          dshVersion: dshVer,
          message: err.message,
        );
      }
      if (err.code == 'gbridge/html_response') {
        return HostProbeNeedsAuth(
          dshVersion: dshVer,
          hasGbridge: false,
          isHtmlLoginPage: true,
          message: err.message,
        );
      }
      if (dshVer != null) {
        return HostProbeBootstrapOnly(
          reason: 'gbridge_not_installed',
          dshVersion: dshVer,
          canInstallRemote: true,
        );
      }
      // Backwards-compatible fallback for custom / older DSH proxies exposing `/api/health`.
      try {
        final health = await _transport.requestJson('GET', '/api/health');
        final ver = health['version']?.toString() ?? health['dshVersion']?.toString();
        if (ver != null && ver.isNotEmpty) {
          return HostProbeBootstrapOnly(
            reason: 'gbridge_not_installed',
            dshVersion: ver,
            canInstallRemote: true,
          );
        }
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _probeVanillaSessionList() async {
    try {
      await _typertRpc('session/list', const {'_request': <String, dynamic>{}});
    } on GbridgeException catch (err) {
      if (err.status == 401 || err.status == 403 || err.code == 'gbridge/html_response') {
        rethrow;
      }
      await _typertRpc('session/list', const {});
    }
  }

  Future<Map<String, dynamic>> _typertRpc(String method, Map<String, dynamic> args) async {
    final res = await _transport.requestJson(
      'POST',
      '/api/$method',
      body: {
        'type': 'client-request',
        'rpcId': 'gb-${DateTime.now().microsecondsSinceEpoch}',
        'method': method,
        'payload': {'args': args},
      },
    );
    final result = res['result'];
    if (result is Map<String, dynamic>) {
      if (result['ok'] == false) {
        final err = result['error'];
        final msg = err is Map
            ? (err['message']?.toString() ?? 'RPC failed')
            : (err?.toString() ?? 'RPC failed');
        throw GbridgeException(status: 400, code: 'dsh/rpc_error', message: msg);
      }
      final val = result['value'];
      if (val is Map<String, dynamic>) return val;
      return {'value': val, ...result};
    }
    return res;
  }

  /// Trigger optional remote installation of `dsh-gbridge` on a stock `dsh web` host
  /// using DSH's standard `pluginManager/installBundle` RPC (supports npm package,
  /// git URL, local path, or tarball spec), then poll `/gbridge/v1/capabilities`.
  Future<Capabilities> installHelperBundle({
    String packageSpec = 'dsh-gbridge',
    String? registryUrl,
    Duration pollTimeout = const Duration(seconds: 45),
    Duration pollInterval = const Duration(milliseconds: 900),
    void Function(String stage)? onProgress,
  }) async {
    onProgress?.call('正在向远程主机下发连接助手安装指令…');
    try {
      await _typertRpc('pluginManager/installBundle', {
        'spec': packageSpec,
        'options': {
          'enabled': true,
          if (registryUrl != null && registryUrl.isNotEmpty) 'registry': registryUrl,
        },
      });
    } on GbridgeException catch (e) {
      if (!e.isNotFound) rethrow;
      await _transport.requestJson(
        'POST',
        '/api/rpc/pluginManager/installBundle',
        body: {
          'spec': packageSpec,
          if (registryUrl != null && registryUrl.isNotEmpty) 'registry': registryUrl,
          'enable': true,
          'options': {
            'enabled': true,
            if (registryUrl != null && registryUrl.isNotEmpty) 'registry': registryUrl,
          },
        },
      );
    }

    onProgress?.call('安装完成，正在等待助手通道就绪…');
    final deadline = DateTime.now().add(pollTimeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final raw = await _transport.requestJson('GET', '/gbridge/v1/capabilities');
        if (raw['domains'] is Map || raw['bridgeVersion'] != null) {
          onProgress?.call('已启用完整增强模式');
          return Capabilities.fromJson(raw);
        }
      } on GbridgeException catch (err) {
        if (!err.isNotFound &&
            err.status != 502 &&
            err.status != 503 &&
            err.code != 'gbridge/html_response') {
          rethrow;
        }
      } catch (_) {
        // Host may briefly reload plugins via HMR.
      }
      await Future<void>.delayed(pollInterval);
    }
    throw const GbridgeException(
      status: 504,
      code: 'bootstrap/install_timeout',
      message: 'timed out waiting for /gbridge/v1/capabilities after remote install',
    );
  }

  // ---------------------------------------------------------------------------
  // Backwards-compatible minimal vanilla RPC helpers
  // ---------------------------------------------------------------------------
  Future<List<SessionSummary>> listVanillaSessions() async {
    Map<String, dynamic> res;
    try {
      res = await _typertRpc('session/list', const {'_request': <String, dynamic>{}});
    } catch (_) {
      res = await _typertRpc('session/list', const {});
    }
    final list = (res['items'] ?? res['sessions'] ?? res['value']) as List<dynamic>?;
    return list
            ?.whereType<Map<String, dynamic>>()
            .map(SessionSummary.fromJson)
            .toList(growable: false) ??
        const [];
  }

  Future<SessionSummary> createVanillaSession({String? workspaceId, String? title}) async {
    final req = <String, dynamic>{
      if (workspaceId != null) 'workspaceId': workspaceId,
      if (title != null) 'title': title,
    };
    Map<String, dynamic> res;
    try {
      res = await _typertRpc('session/create', {'request': req});
    } catch (_) {
      res = await _typertRpc('session/create', req);
    }
    final raw = res['session'] ?? res['value'] ?? res;
    return SessionSummary.fromJson(raw is Map<String, dynamic> ? raw : res);
  }

  Future<Map<String, dynamic>> sendVanillaPrompt(String sessionId, String text) {
    final req = <String, dynamic>{
      'requestId': 'gb-basic-${DateTime.now().microsecondsSinceEpoch}',
      'sessionId': sessionId,
      'mode': 'queue',
      'content': [
        {'type': 'text', 'text': text},
      ],
    };
    return _typertRpc('session/prompt', {'request': req}).catchError(
      (_) => _typertRpc('session/prompt', req),
    );
  }

  Future<Map<String, dynamic>> cancelVanillaSession(String sessionId) {
    return _typertRpc('session/cancel', {
      'request': {'sessionId': sessionId},
    }).catchError(
      (_) => _typertRpc('session/cancel', {'sessionId': sessionId}),
    );
  }

  Future<Map<String, dynamic>> respondVanillaInteraction(
    String interactionId,
    Map<String, dynamic> result, {
    String? clientId,
  }) {
    final outcome = result['outcome'] ?? {'kind': 'result', 'value': result['value'] ?? result};
    return _typertRpc(r'$events/result', {
      if (clientId != null && clientId.isNotEmpty) 'clientId': clientId,
      'eventId': interactionId,
      'outcome': outcome,
    });
  }
}
