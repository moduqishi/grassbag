import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import 'web_embed.dart';

/// Official DSH WebUI page using GrassBag's unified 44px Liquid Glass header,
/// real one-time `/gbridge/v1/web-ticket` auto-login exchange, real HTML iframe
/// on Flutter Web + real WebViewWidget on Android/iOS/macOS, and a Pure Original
/// toggle («纯净原版»).
class OfficialWebPage extends ConsumerStatefulWidget {
  const OfficialWebPage({
    super.key,
    this.initialUrl,
    this.hostName,
    this.allowBadCertificates,
  });

  final String? initialUrl;
  final String? hostName;
  final bool? allowBadCertificates;

  /// Extracts host from a `webview_flutter` `PlatformSslAuthError` / `SslAuthError`
  /// (unwrapping `.platform` first since `url` / `host` live on the platform subclass).
  @visibleForTesting
  static String? extractSslErrorHost(Object request) {
    final candidates = <dynamic>[];
    final dynamic dyn = request;
    try {
      final platform = dyn.platform;
      if (platform != null) candidates.add(platform);
    } catch (_) {}
    candidates.add(dyn);
    for (final candidate in candidates) {
      try {
        final rawUrl = candidate.url;
        if (rawUrl is String && rawUrl.isNotEmpty) {
          final uri = Uri.tryParse(rawUrl);
          if (uri != null && uri.host.isNotEmpty) return uri.host.toLowerCase();
        }
      } catch (_) {}
      try {
        final rawHost = candidate.host;
        if (rawHost is String && rawHost.isNotEmpty) {
          return rawHost.toLowerCase();
        }
      } catch (_) {}
    }
    return null;
  }

  @override
  ConsumerState<OfficialWebPage> createState() => _OfficialWebPageState();
}

class _OfficialWebPageState extends ConsumerState<OfficialWebPage> {
  static int _iframeSeq = 0;

  WebViewController? _webController;
  late final String _iframeViewType;
  bool _loading = true;
  int _loadProgress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _desktopMode = false;
  bool _pureOriginal = false;
  bool _forceCrossSiteIframe = false;
  int _loadSeq = 0;
  String _resolvedUrl = '';
  String? _loadError;

  @override
  void dispose() {
    if (supportsWebIframeEmbed) {
      disposeWebIframe(_iframeViewType);
    }
    super.dispose();
  }

  bool _isCrossSiteEmbed(String targetUrl) {
    if (!supportsWebIframeEmbed) return false;
    final browserOrigin = readBrowserOrigin();
    if (browserOrigin == null || browserOrigin.isEmpty) return false;
    final currentUri = Uri.tryParse(browserOrigin);
    final targetUri = Uri.tryParse(targetUrl);
    if (currentUri == null || targetUri == null) return false;
    if (currentUri.host.isEmpty || targetUri.host.isEmpty) return false;
    return currentUri.host.toLowerCase() != targetUri.host.toLowerCase();
  }

  bool get _supportsNativeWebView =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  String get _fallbackUrl {
    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      return widget.initialUrl!;
    }
    final state = ref.read(appProvider);
    final host = state.activeHost;
    if (host.isLocal && GrassBagNativeBridge.instance.isAndroidNative) {
      final localUrl = state.nativeRuntimeStatus.dshWebUrl.trim();
      if (localUrl.startsWith('http://') || localUrl.startsWith('https://')) {
        return localUrl;
      }
      return state.nativeRuntimeStatus.bridgeHttpUrl;
    }
    final addr = host.address.trim();
    if (addr.startsWith('http://') || addr.startsWith('https://')) {
      return addr;
    }
    return 'http://127.0.0.1:3080';
  }

  static String? _extractSslErrorHost(Object request) =>
      OfficialWebPage.extractSslErrorHost(request);

  @override
  void initState() {
    super.initState();
    _iframeViewType = 'grassbag-dsh-webui-${++_iframeSeq}';
    _resolvedUrl = _fallbackUrl;

    if (_supportsNativeWebView) {
      try {
        final isDarkNow = ref.read(appProvider).isDark;
        final ctrl = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(isDarkNow ? const Color(0xFF141B26) : const Color(0xFFF6F9FC))
          ..setNavigationDelegate(
            NavigationDelegate(
              onProgress: (progress) {
                if (mounted) {
                  setState(() => _loadProgress = progress.clamp(0, 100));
                }
              },
              onPageStarted: (startedUrl) {
                if (startedUrl == 'about:blank') return;
                if (mounted) {
                  setState(() {
                    _loading = true;
                    _loadProgress = 12;
                    _loadError = null;
                    if (startedUrl.startsWith('http://') || startedUrl.startsWith('https://')) {
                      _resolvedUrl = _stripTokenParam(startedUrl);
                    }
                  });
                }
                unawaited(_syncNavAvailability());
              },
              onPageFinished: (finishedUrl) {
                if (finishedUrl == 'about:blank') return;
                if (mounted) {
                  setState(() {
                    _loading = false;
                    _loadProgress = 100;
                    if (finishedUrl.startsWith('http://') || finishedUrl.startsWith('https://')) {
                      _resolvedUrl = _stripTokenParam(finishedUrl);
                    }
                  });
                }
                unawaited(_syncNavAvailability());
                unawaited(_syncRemoteHostCookiesFromWebView(finishedUrl));
                if (!_pureOriginal) {
                  unawaited(_injectSafeAreaViewportCss());
                }
              },
              onWebResourceError: (err) {
                if (err.isForMainFrame == false) return;
                if (mounted) {
                  setState(() {
                    _loading = false;
                    _loadProgress = 0;
                    _loadError = _localizeWebError(err.description, err.errorCode);
                  });
                }
              },
              onSslAuthError: (request) async {
                final allowBad = widget.allowBadCertificates ??
                    (mounted && ref.read(appProvider).activeHost.allowBadCertificates);
                final targetUrl = (widget.initialUrl != null && widget.initialUrl!.isNotEmpty)
                    ? widget.initialUrl!
                    : (mounted ? ref.read(appProvider).activeHost.address : _fallbackUrl);
                final targetHost = Uri.tryParse(targetUrl)?.host.toLowerCase() ?? '';
                final errHost = _extractSslErrorHost(request);
                final hostMatches =
                    targetHost.isNotEmpty && errHost != null && errHost == targetHost;
                if (allowBad && hostMatches) {
                  await request.proceed();
                } else {
                  await request.cancel();
                  if (mounted) {
                    setState(() {
                      _loading = false;
                      _loadError = allowBad && !hostMatches
                          ? '已拦截非目标主机 (${errHost ?? '未知域名'}) 的不受信任 HTTPS 证书。'
                          : '检测到自签名或不受信任的 HTTPS 证书，请先在「主机与环境」开启「信任自签名证书」后重试。';
                    });
                  }
                }
              },
            ),
          );
        _webController = ctrl;
      } catch (_) {
        _webController = null;
      }
    }

    unawaited(_loadWithWebTicket());
  }

  Future<void> _loadWithWebTicket({bool forceReload = false, bool clearPrevious = false}) async {
    final seq = ++_loadSeq;
    final targetHostId = ref.read(appProvider).activeHostId;
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
        if (clearPrevious) {
          _canGoBack = false;
          _canGoForward = false;
          _resolvedUrl = _fallbackUrl;
        }
      });
    }
    if (clearPrevious && _webController != null) {
      await _webController!.clearCache().catchError((_) {});
      await _webController!.loadRequest(Uri.parse('about:blank')).catchError((_) {});
      if (!mounted || seq != _loadSeq || ref.read(appProvider).activeHostId != targetHostId) {
        return;
      }
    }
    String? urlToOpen = (widget.initialUrl != null && widget.initialUrl!.isNotEmpty)
        ? widget.initialUrl
        : null;
    if (urlToOpen == null) {
      try {
        final ticketUrl = await ref.read(appProvider.notifier).createWebUiTicketUrl();
        if (!mounted || seq != _loadSeq || ref.read(appProvider).activeHostId != targetHostId) {
          return;
        }
        if (ticketUrl != null && ticketUrl.isNotEmpty) {
          urlToOpen = ticketUrl;
        } else {
          setState(() {
            _loading = false;
            _resolvedUrl = _fallbackUrl;
            _loadError = '免登票据签发失败，请确认当前 DSH 主机在线后点击重试。';
          });
          return;
        }
      } catch (e) {
        if (!mounted || seq != _loadSeq || ref.read(appProvider).activeHostId != targetHostId) {
          return;
        }
        setState(() {
          _loading = false;
          _resolvedUrl = _fallbackUrl;
          _loadError = '获取一次性登录票据失败：$e';
        });
        return;
      }
    }
    if (!mounted || seq != _loadSeq || ref.read(appProvider).activeHostId != targetHostId) return;
    setState(() {
      _resolvedUrl = urlToOpen!;
      if (supportsWebIframeEmbed) {
        _loading = false;
      }
    });

    if (_webController != null) {
      final uri = Uri.tryParse(urlToOpen);
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
        await _webController!.loadRequest(uri);
      } else if (mounted) {
        setState(() {
          _loading = false;
          _loadError = '目标网页地址格式无效，请检查当前主机配置。';
        });
      }
    } else if (supportsWebIframeEmbed) {
      updateWebIframeUrl(_iframeViewType, urlToOpen, forceReload: forceReload);
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _syncRemoteHostCookiesFromWebView(String finishedUrl) async {
    if (!mounted || !_supportsNativeWebView) return;
    final finUri = Uri.tryParse(finishedUrl);
    if (finUri == null || !finUri.hasScheme || finUri.host.isEmpty) return;
    final state = ref.read(appProvider);
    final activeHost = state.activeHost;
    // Strictly scope cookie capture to the currently active remote host so redirects never
    // bleed cookies across hosts.
    if (activeHost.isLocal) return;
    final hUri = Uri.tryParse(activeHost.address);
    if (hUri == null ||
        hUri.host.toLowerCase() != finUri.host.toLowerCase() ||
        (hUri.hasPort ? hUri.port : (hUri.scheme == 'https' ? 443 : 80)) !=
            (finUri.hasPort ? finUri.port : (finUri.scheme == 'https' ? 443 : 80))) {
      return;
    }
    final cookies = await GrassBagNativeBridge.instance.getWebViewCookies(activeHost.address);
    if (!mounted ||
        ref.read(appProvider).activeHostId != activeHost.id ||
        cookies == null ||
        cookies.isEmpty ||
        cookies == activeHost.sessionCookie) {
      return;
    }
    if (cookies.contains('dsh-auth-') || !activeHost.hasSavedCookie) {
      await ref
          .read(appProvider.notifier)
          .updateHostCookie(activeHost.id, cookies, switchAndConnect: false);
    }
  }

  Future<void> _openInExternalNewTab() async {
    String urlToOpen = _resolvedUrl;
    if (widget.initialUrl == null || widget.initialUrl!.isEmpty) {
      final fresh = await ref.read(appProvider.notifier).createWebUiTicketUrl();
      if (fresh != null && fresh.isNotEmpty) {
        urlToOpen = fresh;
      }
    }
    if (!mounted) return;
    var opened = openUrlInNewTab(urlToOpen);
    if (!opened && GrassBagNativeBridge.instance.isAndroidNative) {
      opened = await GrassBagNativeBridge.instance.openExternalUrl(urlToOpen);
    }
    if (!mounted) return;
    ref.read(appProvider.notifier).showToast(
          opened ? '已在系统浏览器打开 DSH 官方网页版' : '无法调起外部浏览器，请长按地址复制打开',
          tone: opened ? ToastTone.ok : ToastTone.warn,
        );
  }

  Future<void> _injectSafeAreaViewportCss() async {
    try {
      await _webController?.runJavaScript(
        '''
        (function() {
          if (document.getElementById('gb-safe-style')) return;
          var s = document.createElement('style');
          s.id = 'gb-safe-style';
          s.textContent = 'html, body { overscroll-behavior: contain; -webkit-tap-highlight-color: transparent; }';
          document.head.appendChild(s);
        })();
        ''',
      );
    } catch (_) {}
  }

  void _reload() {
    if (_webController != null && _loadError == null && !_resolvedUrl.contains('token=')) {
      _webController!.reload();
    } else {
      unawaited(_loadWithWebTicket(forceReload: true));
    }
    ref.read(appProvider.notifier).showToast('正在刷新官方网页版…', tone: ToastTone.info);
  }

  Future<void> _syncNavAvailability() async {
    final ctrl = _webController;
    if (ctrl == null) return;
    try {
      final back = await ctrl.canGoBack();
      final fwd = await ctrl.canGoForward();
      if (mounted && (back != _canGoBack || fwd != _canGoForward)) {
        setState(() {
          _canGoBack = back;
          _canGoForward = fwd;
        });
      }
    } catch (_) {}
  }

  Future<void> _goBack() async {
    if (await _webController?.canGoBack() == true) {
      await _webController?.goBack();
      unawaited(_syncNavAvailability());
    }
  }

  Future<void> _goForward() async {
    if (await _webController?.canGoForward() == true) {
      await _webController?.goForward();
      unawaited(_syncNavAvailability());
    }
  }

  Future<void> _toggleDesktopMode() async {
    final next = !_desktopMode;
    setState(() => _desktopMode = next);
    if (next) {
      await _webController?.setUserAgent(
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      );
    } else {
      await _webController?.setUserAgent(null);
    }
    if (!mounted) return;
    // Always re-issue a fresh one-time ticket instead of replaying a spent `?token=` URL!
    if (_resolvedUrl.contains('token=') || _loadError != null) {
      unawaited(_loadWithWebTicket(forceReload: true));
    } else {
      await _webController?.reload();
    }
    if (!mounted) return;
    ref.read(appProvider.notifier).showToast(
          next ? '已切换桌面版视图' : '已切换移动版视图',
          tone: ToastTone.info,
        );
  }

  void _togglePureOriginal() {
    setState(() => _pureOriginal = !_pureOriginal);
    if (_resolvedUrl.contains('token=') || _loadError != null) {
      unawaited(_loadWithWebTicket(forceReload: true));
    } else {
      _webController?.reload();
    }
    ref.read(appProvider.notifier).showToast(
          _pureOriginal ? '已开启纯净原版（零注入）' : '已恢复移动端安全区适配',
          tone: ToastTone.info,
        );
  }

  static String _localizeWebError(String description, int errorCode) {
    final upper = description.toUpperCase();
    if (upper.contains('ERR_CONNECTION_REFUSED')) {
      return '目标主机拒绝连接，请确认 DSH 网页服务正在运行。';
    }
    if (upper.contains('ERR_NAME_NOT_RESOLVED')) {
      return '无法解析主机域名，请检查网络连接或主机地址。';
    }
    if (upper.contains('ERR_TIMED_OUT') || upper.contains('ERR_CONNECTION_TIMED_OUT')) {
      return '连接超时，请确认设备与目标主机处于可达网络中。';
    }
    if (upper.contains('ERR_INTERNET_DISCONNECTED') || upper.contains('ERR_NETWORK_CHANGED')) {
      return '当前网络已断开，请检查 Wi-Fi 或移动数据后重试。';
    }
    if (upper.contains('ERR_CLEARTEXT_NOT_PERMITTED')) {
      return '系统拦截了明文 HTTP 请求，请检查主机地址或切换 HTTPS。';
    }
    if (upper.contains('SSL') || upper.contains('CERT')) {
      return 'HTTPS 安全证书校验失败，若为自签名证书请在主机设置中开启信任。';
    }
    return description.isNotEmpty ? '页面加载失败：$description' : '页面加载失败（错误码 $errorCode）';
  }

  static String _stripTokenParam(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.queryParameters.containsKey('token')) return raw;
    final nextParams = Map<String, String>.from(uri.queryParameters)..remove('token');
    if (nextParams.isEmpty) {
      return Uri(
        scheme: uri.scheme,
        userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
        fragment: uri.fragment.isEmpty ? null : uri.fragment,
      ).toString();
    }
    return uri.replace(queryParameters: nextParams).toString();
  }

  String _displayUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;
    if (uri.queryParameters.containsKey('token')) {
      return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}${uri.path.isEmpty ? '/' : uri.path} · 已自动免登';
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(appProvider.select((s) => s.activeHostId), (prev, next) {
      if (prev != null &&
          prev != next &&
          (widget.initialUrl == null || widget.initialUrl!.isEmpty)) {
        setState(() => _forceCrossSiteIframe = false);
        unawaited(_loadWithWebTicket(forceReload: true, clearPrevious: true));
      }
    });
    ref.listen<bool>(appProvider.select((s) => s.isDark), (prev, next) {
      if (prev != null && prev != next) {
        _webController?.setBackgroundColor(
          next ? const Color(0xFF141B26) : const Color(0xFFF6F9FC),
        );
      }
    });
    ref.listen<ConnectionPhase>(appProvider.select((s) => s.connectionPhase), (prev, next) {
      if (next == ConnectionPhase.connected &&
          _loadError != null &&
          (widget.initialUrl == null || widget.initialUrl!.isEmpty)) {
        unawaited(_loadWithWebTicket(forceReload: true));
      }
    });
    ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          activeHostId: s.activeHostId,
          connectionPhase: s.connectionPhase,
          hosts: s.hosts,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final t = GrassBagTokens.of(context);
    final botPad = MediaQuery.viewPaddingOf(context).bottom;

    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          final nav = Navigator.of(context);
          unawaited(() async {
            if (await _webController?.canGoBack() == true) {
              await _webController?.goBack();
              unawaited(_syncNavAvailability());
            } else if (mounted) {
              setState(() => _canGoBack = false);
              unawaited(nav.maybePop());
            }
          }());
        }
      },
      child: GrassBagGlassPage(
        child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Column(
              children: [
                GrassBagUnifiedHeader(
                  title: '官方网页版',
                  subtitle: widget.hostName ?? state.activeHost.name,
                  tier: state.glassTier,
                  floating: false,
                  onBack: () => Navigator.of(context).pop(),
                  trailing: GrassBagGlassCircleButton(
                    icon: CupertinoIcons.refresh,
                    tooltip: '刷新页面',
                    tier: state.glassTier,
                    useOwnLayer: false,
                    onTap: _reload,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(12, 0, 12, botPad > 0 ? botPad + 8 : 14),
                    child: CustomPaint(
                      foregroundPainter: state.glassTier == GrassBagGlassTier.solid
                          ? null
                          : GrassBagFresnelRimPainter(
                              isDark: t.isDark,
                              borderRadius: 24,
                              accent: t.primaryHi,
                              frosted: state.glassTier == GrassBagGlassTier.frosted,
                              paintTopSheen: false,
                              strokeWidth: 0.88,
                            ),
                      child: ClipRSuperellipse(
                        borderRadius: BorderRadius.circular(24),
                        child: Container(
                          decoration: ShapeDecoration(
                            color: t.cardSolid,
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(24),
                              side: state.glassTier == GrassBagGlassTier.solid
                                  ? BorderSide(color: t.sepStrong, width: 0.65)
                                  : BorderSide.none,
                            ),
                          ),
                        child: Column(
                          children: [
                            Container(
                              height: 46,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: t.isDark
                                    ? Colors.white.withValues(alpha: 0.04)
                                    : t.fill1.withValues(alpha: 0.72),
                                border: Border(bottom: BorderSide(color: t.sep, width: 0.5)),
                              ),
                              child: Row(
                                children: [
                                  if (_webController != null) ...[
                                    Tooltip(
                                      message: '后退',
                                      child: GrassBagSpringTap(
                                        enabled: _canGoBack,
                                        borderRadius: 999,
                                        haptic: true,
                                        onTap: _goBack,
                                        child: SizedBox(
                                          width: 34,
                                          height: 34,
                                          child: Center(
                                            child: Icon(
                                              CupertinoIcons.chevron_back,
                                              size: 16,
                                              color: _canGoBack
                                                  ? t.text2
                                                  : t.text3.withValues(alpha: 0.38),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Tooltip(
                                      message: '前进',
                                      child: GrassBagSpringTap(
                                        enabled: _canGoForward,
                                        borderRadius: 999,
                                        haptic: true,
                                        onTap: _goForward,
                                        child: SizedBox(
                                          width: 34,
                                          height: 34,
                                          child: Center(
                                            child: Icon(
                                              CupertinoIcons.chevron_forward,
                                              size: 16,
                                              color: _canGoForward
                                                  ? t.text2
                                                  : t.text3.withValues(alpha: 0.38),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Expanded(
                                    child: Tooltip(
                                      message: '轻点复制当前地址',
                                      child: GrassBagSpringTap(
                                        enablePointerGlow: false,
                                        haptic: true,
                                        onTap: () {
                                          if (_resolvedUrl.isEmpty) return;
                                          Clipboard.setData(
                                            ClipboardData(text: _stripTokenParam(_resolvedUrl)),
                                          );
                                          ref
                                              .read(appProvider.notifier)
                                              .showToast('已复制网页地址', tone: ToastTone.ok);
                                        },
                                        child: GrassBagFresnelGlassSurface(
                                          isPill: true,
                                          innerWell: true,
                                          interactive: true,
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                          child: Row(
                                            children: [
                                              Icon(
                                                _resolvedUrl.contains('token=')
                                                    ? CupertinoIcons.checkmark_shield
                                                    : (_resolvedUrl.startsWith('https://')
                                                        ? CupertinoIcons.lock_fill
                                                        : CupertinoIcons.lock_open),
                                                size: 12.5,
                                                color: _resolvedUrl.startsWith('https://')
                                                    ? t.ok
                                                    : (_resolvedUrl.contains('token=') ? t.primary : t.text3),
                                              ),
                                              const SizedBox(width: 5),
                                              Expanded(
                                                child: Text(
                                                  _displayUrl(_resolvedUrl),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontFamily: 'monospace',
                                                    fontSize: 11,
                                                    color: t.text2,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  if (supportsWebIframeEmbed)
                                    Tooltip(
                                      message: '在浏览器新标签页打开',
                                      child: GrassBagSpringTap(
                                        onTap: _openInExternalNewTab,
                                        pressedScale: 0.94,
                                        enablePointerGlow: false,
                                        haptic: true,
                                        child: GrassBagFresnelGlassSurface(
                                          isPill: true,
                                          innerWell: true,
                                          interactive: true,
                                          tintColor: t.primarySoft,
                                          padding: const EdgeInsets.symmetric(horizontal: 9.5, vertical: 5.5),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(CupertinoIcons.arrow_up_right_square, size: 12, color: t.primary),
                                              const SizedBox(width: 4),
                                              Text(
                                                '新标签打开',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                  color: t.primary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    )
                                  else if (_webController != null) ...[
                                    Tooltip(
                                      message: _pureOriginal
                                          ? '纯净原版模式（零样式注入）'
                                          : '移动端适配模式（轻点切换纯净原版）',
                                      child: GrassBagSpringTap(
                                        onTap: _togglePureOriginal,
                                        pressedScale: 0.94,
                                        enablePointerGlow: false,
                                        haptic: true,
                                        child: GrassBagFresnelGlassSurface(
                                          isPill: true,
                                          innerWell: true,
                                          interactive: true,
                                          tintColor: _pureOriginal ? t.okSoft : null,
                                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5.5),
                                          child: Text(
                                            _pureOriginal ? '纯净原版' : '适配',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: _pureOriginal ? t.ok : t.text2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    Tooltip(
                                      message: _desktopMode ? '切换移动视图' : '切换桌面视图',
                                      child: GrassBagSpringTap(
                                        onTap: _toggleDesktopMode,
                                        pressedScale: 0.94,
                                        enablePointerGlow: false,
                                        haptic: true,
                                        child: GrassBagFresnelGlassSurface(
                                          isPill: true,
                                          innerWell: true,
                                          interactive: true,
                                          tintColor: _desktopMode ? t.primarySoft : null,
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5.5),
                                          child: Text(
                                            _desktopMode ? '桌面' : '移动',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: _desktopMode ? t.primary : t.text2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (widget.initialUrl == null || widget.initialUrl!.isEmpty) ...[
                                      const SizedBox(width: 4),
                                      Tooltip(
                                        message: '重新签发一次性免登票据',
                                        child: GrassBagSpringTap(
                                          onTap: () {
                                            ref.read(appProvider.notifier).showToast(
                                                  '正在重新免登…',
                                                  tone: ToastTone.info,
                                                );
                                            unawaited(
                                              _loadWithWebTicket(
                                                forceReload: true,
                                                clearPrevious: true,
                                              ),
                                            );
                                          },
                                          pressedScale: 0.92,
                                          enablePointerGlow: false,
                                          haptic: true,
                                          child: GrassBagFresnelGlassSurface(
                                            isCircle: true,
                                            innerWell: true,
                                            interactive: true,
                                            width: 28,
                                            height: 28,
                                            alignment: Alignment.center,
                                            child: Icon(
                                              CupertinoIcons.person_crop_circle_badge_checkmark,
                                              size: 13.5,
                                              color: t.primary,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                    const SizedBox(width: 4),
                                    Tooltip(
                                      message: '在系统浏览器打开',
                                      child: GrassBagSpringTap(
                                        onTap: _openInExternalNewTab,
                                        pressedScale: 0.92,
                                        enablePointerGlow: false,
                                        haptic: true,
                                        child: GrassBagFresnelGlassSurface(
                                          isCircle: true,
                                          innerWell: true,
                                          interactive: true,
                                          width: 28,
                                          height: 28,
                                          alignment: Alignment.center,
                                          child: Icon(
                                            CupertinoIcons.arrow_up_right_square,
                                            size: 13.5,
                                            color: t.text2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (_loading)
                              SizedBox(
                                height: 2.5,
                                child: LinearProgressIndicator(
                                  value: (_loadProgress > 0 && _loadProgress < 100)
                                      ? _loadProgress / 100.0
                                      : null,
                                  backgroundColor: Colors.transparent,
                                  valueColor: AlwaysStoppedAnimation<Color>(t.primary),
                                ),
                              ),
                            Expanded(
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: _loadError != null
                                        ? Center(
                                            child: Padding(
                                              padding: const EdgeInsets.all(24),
                                              child: ConstrainedBox(
                                                constraints: const BoxConstraints(maxWidth: 360),
                                                child: GrassBagCard(
                                                  borderRadius: 24,
                                                  padding: const EdgeInsets.all(20),
                                                  child: Column(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      GrassBagSquircleIcon(
                                                        icon: CupertinoIcons.wifi_exclamationmark,
                                                        color: t.warn,
                                                        size: 42,
                                                        iconSize: 20,
                                                      ),
                                                      const SizedBox(height: 12),
                                                      Text(
                                                        '网页版加载失败',
                                                        style: TextStyle(
                                                          fontSize: 15.5,
                                                          fontWeight: FontWeight.w600,
                                                          color: t.text,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 6),
                                                      Text(
                                                        _loadError!,
                                                        textAlign: TextAlign.center,
                                                        style: TextStyle(
                                                          fontSize: 12.5,
                                                          height: 1.45,
                                                          color: t.text3,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 16),
                                                      GrassBagPrimaryGlassButton(
                                                        label: '重新加载',
                                                        icon: CupertinoIcons.refresh,
                                                        tier: state.glassTier,
                                                        insideGlass: true,
                                                        onTap: () => unawaited(
                                                          _loadWithWebTicket(forceReload: true),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          )
                                        : _buildWebSurface(t),
                                  ),
                                  // Keep GrassBagProgressBar mounted inside AnimatedOpacity (pausing its
                                  // ticker via TickerMode when idle) so the 160ms fade-out actually animates!
                                  Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    child: IgnorePointer(
                                      child: AnimatedOpacity(
                                        opacity: _loading ? 1.0 : 0.0,
                                        duration: const Duration(milliseconds: 160),
                                        child: TickerMode(
                                          enabled: _loading,
                                          child: GrassBagProgressBar(
                                            height: 2.5,
                                            color: t.primary,
                                            trackColor: Colors.transparent,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    ),
                  ),
                ),
              ],
            ),
            const GrassBagToastOverlay(bottomOffset: 28),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildWebSurface(GrassBagTokens t) {
    if (_webController != null) {
      return WebViewWidget(controller: _webController!);
    }
    if (supportsWebIframeEmbed) {
      if (_loading && !_resolvedUrl.contains('token=')) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CupertinoActivityIndicator(radius: 12, color: t.primary),
              const SizedBox(height: 12),
              Text('正在签发一次性免登票据并加载 DSH 网页版…', style: TextStyle(fontSize: 13, color: t.text2)),
            ],
          ),
        );
      }
      if (!_forceCrossSiteIframe && _isCrossSiteEmbed(_resolvedUrl)) {
        final tier = ref.read(appProvider).glassTier;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GrassBagSquircleIcon(
                    icon: CupertinoIcons.compass_fill,
                    color: t.primary,
                    size: 52,
                    iconSize: 24,
                    filled: true,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '跨站点主机建议在新标签页打开',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: t.text),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '浏览器出于安全策略会拦截跨站 iframe 的免登 Cookie。点击下方按钮将在新标签页使用一次性票据直接免登。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, height: 1.45, color: t.text2),
                  ),
                  const SizedBox(height: 18),
                  GrassBagPrimaryGlassButton(
                    label: '在新标签页打开官方网页版',
                    icon: CupertinoIcons.arrow_up_right_square,
                    tier: tier,
                    insideGlass: true,
                    onTap: _openInExternalNewTab,
                  ),
                  const SizedBox(height: 10),
                  GrassBagSecondaryGlassButton(
                    label: '仍尝试在此内嵌加载',
                    tier: tier,
                    insideGlass: true,
                    onTap: () => setState(() => _forceCrossSiteIframe = true),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return buildWebIframeView(
        viewType: _iframeViewType,
        url: _resolvedUrl,
      );
    }
    final tier = ref.read(appProvider).glassTier;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GrassBagSquircleIcon(
                icon: CupertinoIcons.globe,
                color: t.primary,
                size: 48,
                iconSize: 22,
              ),
              const SizedBox(height: 12),
              Text(
                '官方 DSH 网页界面',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _displayUrl(_resolvedUrl),
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: t.text3),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: GrassBagSecondaryGlassButton(
                      label: '复制链接',
                      icon: CupertinoIcons.doc_on_doc,
                      tier: tier,
                      insideGlass: true,
                      onTap: () async {
                        await Clipboard.setData(
                          ClipboardData(text: _stripTokenParam(_resolvedUrl)),
                        );
                        if (!mounted) return;
                        ref.read(appProvider.notifier).showToast('已复制网页地址', tone: ToastTone.ok);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GrassBagPrimaryGlassButton(
                      label: '浏览器打开',
                      icon: CupertinoIcons.compass,
                      tier: tier,
                      insideGlass: true,
                      onTap: () async {
                        var ok = await GrassBagNativeBridge.instance.openExternalUrl(_resolvedUrl);
                        if (!ok) {
                          ok = openUrlInNewTab(_resolvedUrl);
                        }
                        if (!ok && mounted) {
                          await Clipboard.setData(
                            ClipboardData(text: _stripTokenParam(_resolvedUrl)),
                          );
                          if (!mounted) return;
                          ref.read(appProvider.notifier).showToast('已复制链接，请在浏览器粘贴打开', tone: ToastTone.info);
                        }
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
