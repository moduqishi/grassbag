import 'dart:async';

import 'models.dart';
import 'transport.dart';

/// Official GitHub Release `.tgz` distribution URLs for `dsh-gbridge` (zero runtime dependencies,
/// strictly ending in `.tgz` without query parameters so DSH `0.2.2+` `TARBALL_SPEC` installs
/// directly in ~1-2s without hitting npmjs or git!).
const String kOfficialGbridgeDirectUrl =
    'https://github.com/moduqishi/grassbag/releases/latest/download/dsh-gbridge.tgz';

/// Primary China-accelerated GitHub mirror URL for `dsh-gbridge.tgz`.
const String kOfficialGbridgeAcceleratedUrl =
    'https://gh-proxy.com/https://github.com/moduqishi/grassbag/releases/latest/download/dsh-gbridge.tgz';

/// Ordered fallback list tried automatically when installing the official `dsh-gbridge` plugin.
const List<String> kOfficialGbridgeInstallSpecs = [
  kOfficialGbridgeAcceleratedUrl,
  'https://ghfast.top/https://github.com/moduqishi/grassbag/releases/latest/download/dsh-gbridge.tgz',
  kOfficialGbridgeDirectUrl,
];

/// Detailed result of remotely installing `dsh-gbridge` via DSH's `pluginManager/installBundle`.
class HelperInstallResult {
  const HelperInstallResult({
    this.capabilities,
    this.restartRequired = false,
    this.installedSpec = '',
    this.message,
  });

  /// Live `/gbridge/v1/capabilities` once active (null when [restartRequired] is true).
  final Capabilities? capabilities;

  /// True when DSH installed the bundle cleanly (`application: 'restart-required'`)
  /// and needs a restart to mount `/gbridge/v1` + client UI.
  final bool restartRequired;

  /// The tarball/package spec that succeeded.
  final String installedSpec;

  /// Optional human-readable status message.
  final String? message;
}

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

  static bool _isLikelyUntrustedHost403(GbridgeException err, String? dshVer) {
    final msgLower = err.message.toLowerCase();
    if (msgLower.contains('<!doctype') ||
        msgLower.contains('<html') ||
        msgLower.contains('cloudflare') ||
        msgLower.contains('sign in') ||
        msgLower.contains('login') ||
        msgLower.contains('authenticate') ||
        msgLower.contains('unauthorized') ||
        msgLower.contains('invalid token') ||
        msgLower.contains('access denied')) {
      return false;
    }
    if (msgLower.contains('host') || msgLower.contains('origin') || msgLower.contains('trusted')) {
      return true;
    }
    return dshVer != null;
  }

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
        if (!_isLikelyUntrustedHost403(err, dshVer)) {
          final msgLower = err.message.toLowerCase();
          return HostProbeNeedsAuth(
            dshVersion: dshVer,
            hasGbridge: err.code.startsWith('gbridge/') && err.code != 'gbridge/http_403',
            isHtmlLoginPage: msgLower.contains('<html') || msgLower.contains('<!doctype'),
            message: err.message,
          );
        }
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
      if (!err.isNotFound &&
          err.status != 405 &&
          err.status != 501 &&
          err.code != 'gbridge/html_response') {
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
        if (!_isLikelyUntrustedHost403(err, dshVer)) {
          final msgLower = err.message.toLowerCase();
          return HostProbeNeedsAuth(
            dshVersion: dshVer,
            hasGbridge: false,
            isHtmlLoginPage: msgLower.contains('<html') || msgLower.contains('<!doctype'),
            message: err.message,
          );
        }
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
    throw GbridgeException(
      status: 502,
      code: 'gbridge/non_dsh_response',
      message: '目标服务未返回有效的 DeepSeek Harness 接口响应',
    );
  }

  /// Trigger optional remote installation of `dsh-gbridge` on a stock `dsh web` host
  /// using DSH's standard `pluginManager/installBundle` RPC.
  ///
  /// When [packageSpec] is omitted, empty, or the bare alias `'dsh-gbridge'`, automatically
  /// tries [kOfficialGbridgeInstallSpecs] (China-accelerated GitHub Release `.tgz` mirrors
  /// falling back to direct GitHub Release `.tgz`).
  ///
  /// Properly inspects DSH `0.2.2+` `ChangeResult` (`applied` / `restart-required` / `failed`),
  /// recovers transient timeouts via `pluginManager/waitForInstall`, and surfaces exact
  /// diagnostics (`pnpm-missing`, `not-bundle`, `build-blocked`, etc.) immediately.
  Future<HelperInstallResult> installHelperBundleDetailed({
    String packageSpec = kOfficialGbridgeAcceleratedUrl,
    String? registryUrl,
    Duration pollTimeout = const Duration(seconds: 35),
    Duration pollInterval = const Duration(milliseconds: 900),
    void Function(String stage)? onProgress,
  }) async {
    final trimmedSpec = packageSpec.trim();
    final useOfficialMirrors = trimmedSpec.isEmpty ||
        trimmedSpec == 'dsh-gbridge' ||
        trimmedSpec == '@grassbag/dsh-gbridge' ||
        trimmedSpec == kOfficialGbridgeAcceleratedUrl ||
        trimmedSpec == kOfficialGbridgeDirectUrl ||
        kOfficialGbridgeInstallSpecs.contains(trimmedSpec);
    final candidateSpecs = useOfficialMirrors
        ? (trimmedSpec == kOfficialGbridgeDirectUrl
            ? <String>[
                kOfficialGbridgeDirectUrl,
                for (final s in kOfficialGbridgeInstallSpecs)
                  if (s != kOfficialGbridgeDirectUrl) s,
              ]
            : kOfficialGbridgeInstallSpecs)
        : <String>[trimmedSpec];

    Map<String, dynamic>? installValue;
    String succeededSpec = candidateSpecs.first;
    GbridgeException? lastFailure;

    for (var i = 0; i < candidateSpecs.length; i++) {
      final spec = candidateSpecs[i];
      final requestId = 'gb-inst-${DateTime.now().microsecondsSinceEpoch}-$i';
      onProgress?.call(
        candidateSpecs.length > 1
            ? '正在通过${i == 0 ? '加速镜像' : (i == candidateSpecs.length - 1 ? 'GitHub 直连' : '备用镜像')}安装连接助手 (${i + 1}/${candidateSpecs.length})…'
            : '正在向远程主机下发连接助手安装指令…',
      );
      try {
        final rawResult = await _invokeInstallBundleWithRecovery(
          spec: spec,
          requestId: requestId,
          registryUrl: registryUrl,
        );
        final err = _extractInstallFailure(rawResult);
        if (err != null) {
          lastFailure = err;
          // Non-network local environment blockers (missing pnpm, not a bundle, build blocked)
          // won't be cured by trying another mirror — fail fast with clear diagnosis!
          if (!_isRetryableMirrorError(err)) {
            throw err;
          }
          continue;
        }
        installValue = rawResult;
        succeededSpec = spec;
        break;
      } on GbridgeException catch (e) {
        lastFailure = e;
        if (!_isRetryableMirrorError(e) || i == candidateSpecs.length - 1) {
          rethrow;
        }
      } on TimeoutException catch (e) {
        lastFailure = GbridgeException(
          status: 504,
          code: 'gbridge/timeout',
          message: '安装连接助手请求超时 (${e.message ?? 'timeout'})',
        );
        if (i == candidateSpecs.length - 1) {
          throw lastFailure;
        }
      } catch (e) {
        lastFailure = GbridgeException(
          status: 502,
          code: 'bootstrap/transport_error',
          message: '安装连接助手网络异常：$e',
        );
        if (i == candidateSpecs.length - 1) {
          throw lastFailure;
        }
      }
    }

    if (installValue == null) {
      throw lastFailure ??
          const GbridgeException(
            status: 502,
            code: 'bootstrap/install_failed',
            message: '远程安装连接助手失败，请检查远程主机网络与 pnpm 环境',
          );
    }

    final application = installValue['application']?.toString().toLowerCase() ?? '';
    if (application == 'restart-required') {
      onProgress?.call('插件已安装，重启远程 DeepSeek Harness 后立即生效');
      return HelperInstallResult(
        restartRequired: true,
        installedSpec: succeededSpec,
        message: '连接助手插件已安装完成，重启远程电脑上的 DeepSeek Harness 后将自动开启增强模式与扫码界面。',
      );
    }

    onProgress?.call('安装完成，正在等待助手通道就绪…');
    final deadline = DateTime.now().add(pollTimeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final raw = await _transport.requestJson('GET', '/gbridge/v1/capabilities');
        if (raw['domains'] is Map || raw['bridgeVersion'] != null) {
          onProgress?.call('已启用完整增强模式');
          return HelperInstallResult(
            capabilities: Capabilities.fromJson(raw),
            restartRequired: false,
            installedSpec: succeededSpec,
          );
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

    // Plugin installed cleanly (`application == 'applied'` or unknown) yet hot-reload did not
    // expose `/gbridge/v1` in time — report restart-required instead of a confusing 504 error!
    if (application == 'applied') {
      return HelperInstallResult(
        restartRequired: true,
        installedSpec: succeededSpec,
        message: '连接助手已写入远程主机配置，但未能热加载路由；重启远程 DSH 后即可生效。',
      );
    }
    throw const GbridgeException(
      status: 504,
      code: 'bootstrap/install_timeout',
      message: '已下发安装指令但等待 /gbridge/v1/capabilities 超时，请检查远程主机日志或重启 DSH',
    );
  }

  /// Backwards-compatible convenience wrapper returning [Capabilities] directly.
  Future<Capabilities> installHelperBundle({
    String packageSpec = kOfficialGbridgeAcceleratedUrl,
    String? registryUrl,
    Duration pollTimeout = const Duration(seconds: 45),
    Duration pollInterval = const Duration(milliseconds: 900),
    void Function(String stage)? onProgress,
  }) async {
    final result = await installHelperBundleDetailed(
      packageSpec: packageSpec,
      registryUrl: registryUrl,
      pollTimeout: pollTimeout,
      pollInterval: pollInterval,
      onProgress: onProgress,
    );
    if (result.capabilities != null) return result.capabilities!;
    throw GbridgeException(
      status: 202,
      code: 'bootstrap/restart_required',
      message: result.message ?? '连接助手已安装，请重启远程 DeepSeek Harness 以生效',
    );
  }

  Future<Map<String, dynamic>> _invokeInstallBundleWithRecovery({
    required String spec,
    required String requestId,
    String? registryUrl,
  }) async {
    final args = <String, dynamic>{
      'spec': spec,
      'options': <String, dynamic>{
        'enabled': true,
        'requestId': requestId,
        if (registryUrl != null && registryUrl.isNotEmpty) 'registry': registryUrl,
      },
    };
    try {
      return await _typertRpc('pluginManager/installBundle', args);
    } on TimeoutException {
      return _typertRpc('pluginManager/waitForInstall', {'requestId': requestId});
    } on GbridgeException catch (e) {
      // If the initial HTTP request timed out while DSH's pnpm download was still running,
      // recover the in-flight operation cleanly via `pluginManager/waitForInstall({ requestId })`!
      if (e.code == 'gbridge/timeout' || e.status == 408 || e.status == 504) {
        try {
          return await _typertRpc('pluginManager/waitForInstall', {'requestId': requestId});
        } catch (_) {
          rethrow;
        }
      }
      rethrow;
    }
  }

  static GbridgeException? _extractInstallFailure(Map<String, dynamic> result) {
    final application = result['application']?.toString().toLowerCase() ?? '';
    final pkgRes = result['packageResult'];
    final pkgKind = pkgRes is Map ? (pkgRes['kind']?.toString().toLowerCase() ?? '') : '';
    final rawErr = result['error'];
    final errMap = rawErr is Map ? rawErr : null;

    if (pkgKind == 'pnpm-missing') {
      return const GbridgeException(
        status: 422,
        code: 'plugin/pnpm_missing',
        message: '远程主机未安装 pnpm，无法在线安装插件。请先在电脑安装 pnpm 或在桌面端直接运行安装命令。',
      );
    }
    if (pkgKind == 'not-bundle') {
      return const GbridgeException(
        status: 422,
        code: 'plugin/not_bundle',
        message: '目标插件包缺少有效的 DSH bundle 清单，请确认下载地址指向最新版 dsh-gbridge.tgz。',
      );
    }
    if (pkgKind == 'build-blocked') {
      return const GbridgeException(
        status: 422,
        code: 'plugin/build_blocked',
        message: '远程 DSH 安全策略拦截了构建脚本，请使用预打包的官方 dsh-gbridge.tgz 下载地址。',
      );
    }
    if (application == 'failed' || pkgKind == 'failed' || errMap != null) {
      final diag = errMap?['diagnostic']?.toString().trim();
      final errMsg = errMap?['message']?.toString().trim();
      final pkgMsg = pkgRes is Map ? pkgRes['message']?.toString().trim() : null;
      final detail = [
        if (errMsg != null && errMsg.isNotEmpty) errMsg,
        if (diag != null && diag.isNotEmpty && diag != errMsg) diag,
        if (pkgMsg != null && pkgMsg.isNotEmpty && pkgMsg != errMsg) pkgMsg,
      ].join(' · ');
      return GbridgeException(
        status: 400,
        code: 'plugin/install_failed',
        message: detail.isNotEmpty ? detail : '远程主机插件安装失败（application=$application）',
      );
    }
    return null;
  }

  static bool _isRetryableMirrorError(GbridgeException e) {
    if (e.code == 'plugin/pnpm_missing' ||
        e.code == 'plugin/not_bundle' ||
        e.code == 'plugin/build_blocked' ||
        e.status == 401 ||
        e.status == 403 ||
        e.status == 422) {
      return false;
    }
    final lower = e.message.toLowerCase();
    if (lower.contains('pnpm') && lower.contains('not found')) return false;
    return true;
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
