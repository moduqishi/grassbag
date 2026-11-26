import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';

/// In-App WebView authentication & automatic 30-day session cookie capture page
/// for remote DSH hosts (supports reverse proxies, Cloudflare Access, Authelia/SSO,
/// and pasting a one-time `dsh web` URL once to mint a 30-day `dsh-auth-*` cookie).
///
/// Pops with the captured `Cookie` header string as soon as authentication succeeds,
/// or `null` if cancelled.
class RemoteWebLoginPage extends ConsumerStatefulWidget {
  const RemoteWebLoginPage({
    super.key,
    required this.hostName,
    required this.baseAddress,
    this.allowBadCertificates = false,
  });

  final String hostName;
  final String baseAddress;
  final bool allowBadCertificates;

  @override
  ConsumerState<RemoteWebLoginPage> createState() => _RemoteWebLoginPageState();
}

class _RemoteWebLoginPageState extends ConsumerState<RemoteWebLoginPage> {
  static const String _defaultStatusText =
      '在下方完成网页登录或粘贴一次启动链接，认证通过后自动返回原生界面';

  WebViewController? _controller;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0.0);
  Timer? _pollTimer;
  String _currentUrl = '';
  String _statusText = _defaultStatusText;
  bool _verifying = false;
  bool _manualVerifying = false;
  bool _pendingManualVerify = false;
  bool _canGoBack = false;
  bool _completed = false;
  bool _hasLoadError = false;
  String? _lastCheckedCookie;

  bool get _supportsNativeWebView =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static String _localizeWebError(String description, int errorCode) {
    final upper = description.toUpperCase();
    if (upper.contains('ERR_CONNECTION_REFUSED')) {
      return '目标主机拒绝连接，请确认远程 DSH 服务正在运行。';
    }
    if (upper.contains('ERR_NAME_NOT_RESOLVED')) {
      return '无法解析主机域名，请检查网络连接或主机地址。';
    }
    if (upper.contains('ERR_TIMED_OUT') || upper.contains('ERR_CONNECTION_TIMED_OUT')) {
      return '连接超时，请检查局域网或反向代理可达性。';
    }
    if (upper.contains('ERR_INTERNET_DISCONNECTED') || upper.contains('ERR_NETWORK_CHANGED')) {
      return '当前网络已断开，请恢复网络后点击右上角刷新。';
    }
    if (upper.contains('SSL') || upper.contains('CERT')) {
      return 'HTTPS 证书校验失败，若为自签名证书请先开启「信任自签名证书」。';
    }
    return '页面加载失败：${description.isNotEmpty ? description : '错误码 $errorCode'}';
  }

  static String? _extractSslErrorHost(Object request) {
    final dynamic dyn = request;
    try {
      final rawUrl = dyn.url;
      if (rawUrl is String && rawUrl.isNotEmpty) {
        final uri = Uri.tryParse(rawUrl);
        if (uri != null && uri.host.isNotEmpty) return uri.host.toLowerCase();
      }
    } catch (_) {}
    try {
      final rawHost = dyn.host;
      if (rawHost is String && rawHost.isNotEmpty) {
        return rawHost.toLowerCase();
      }
    } catch (_) {}
    return null;
  }

  static bool _isSameHostPort(String urlA, String urlB) {
    final a = Uri.tryParse(urlA);
    final b = Uri.tryParse(urlB);
    if (a == null || b == null || a.host.isEmpty || b.host.isEmpty) return false;
    final portA = a.hasPort ? a.port : (a.scheme == 'https' ? 443 : 80);
    final portB = b.hasPort ? b.port : (b.scheme == 'https' ? 443 : 80);
    return a.host.toLowerCase() == b.host.toLowerCase() && portA == portB;
  }

  Future<void> _syncCanGoBack() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    try {
      final back = await ctrl.canGoBack();
      if (mounted && back != _canGoBack) {
        setState(() => _canGoBack = back);
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.baseAddress;
    if (_supportsNativeWebView) {
      final isDarkNow = ref.read(appProvider).isDark;
      try {
        final ctrl = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(
            isDarkNow ? const Color(0xFF141B26) : const Color(0xFFF6F9FC),
          )
          ..setNavigationDelegate(
            NavigationDelegate(
              onProgress: (p) {
                if (!mounted) return;
                _progress.value = (p / 100.0).clamp(0.0, 1.0);
              },
              onPageStarted: (url) {
                if (mounted) {
                  setState(() {
                    _currentUrl = url;
                    if (_hasLoadError) {
                      _hasLoadError = false;
                      if (!_manualVerifying) {
                        _statusText = _defaultStatusText;
                      }
                    }
                  });
                }
                unawaited(_syncCanGoBack());
              },
              onPageFinished: (url) {
                if (!mounted) return;
                _progress.value = 1.0;
                setState(() => _currentUrl = url);
                unawaited(_syncCanGoBack());
                if (!_hasLoadError) {
                  unawaited(_checkCookiesAndComplete(silent: true));
                }
              },
              onWebResourceError: (err) {
                if (err.isForMainFrame == false || !mounted) return;
                setState(() {
                  _hasLoadError = true;
                  _progress.value = 1.0;
                  _statusText = _localizeWebError(err.description, err.errorCode);
                });
              },
              onSslAuthError: (request) async {
                final targetUri = Uri.tryParse(widget.baseAddress);
                final targetHost = targetUri?.host.toLowerCase() ?? '';
                final errHost = _extractSslErrorHost(request);
                final hostMatches =
                    targetHost.isNotEmpty && errHost != null && errHost == targetHost;
                if (widget.allowBadCertificates && hostMatches) {
                  await request.proceed();
                } else {
                  await request.cancel();
                  if (mounted) {
                    setState(() {
                      _hasLoadError = true;
                      _progress.value = 1.0;
                      _statusText = widget.allowBadCertificates && !hostMatches
                          ? '已拦截第三方域名 (${errHost ?? '未知'}) 的不受信任 HTTPS 证书'
                          : '检测到自签名 HTTPS 证书，请先开启「信任自签名证书」后再重试登录';
                    });
                  }
                }
              },
            ),
          );
        final parsed = Uri.tryParse(widget.baseAddress);
        if (parsed != null && (parsed.scheme == 'http' || parsed.scheme == 'https')) {
          unawaited(ctrl.loadRequest(parsed));
        } else {
          _hasLoadError = true;
          _statusText = '远程主机地址格式无效，请检查后重试：${widget.baseAddress}';
        }
        _controller = ctrl;
        _pollTimer = Timer.periodic(const Duration(milliseconds: 2400), (_) {
          if (!_hasLoadError) {
            unawaited(_checkCookiesAndComplete(silent: true));
          }
        });
      } catch (e) {
        _controller = null;
        _hasLoadError = true;
        _statusText = '内置 WebView 初始化失败：$e';
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _progress.dispose();
    super.dispose();
  }

  Future<void> _checkCookiesAndComplete({required bool silent}) async {
    if (!mounted || _completed) return;
    if (_verifying) {
      if (!silent) {
        _pendingManualVerify = true;
        setState(() {
          _manualVerifying = true;
          _statusText = '正在验证登录凭证与远程 DSH 连通性…';
        });
      }
      return;
    }
    _verifying = true;
    if (!silent && mounted) {
      setState(() {
        _manualVerifying = true;
        _statusText = '正在验证登录凭证与远程 DSH 连通性…';
      });
    }
    try {
      final baseCookie = await GrassBagNativeBridge.instance.getWebViewCookies(widget.baseAddress);
      if (!mounted || _completed) return;
      // Only merge cookies from `_currentUrl` when it matches the target host & port
      // so third-party SSO/IdP domain cookies are never leaked to the remote DSH host.
      final curCookie = (_currentUrl.startsWith('http') &&
              _currentUrl != widget.baseAddress &&
              _isSameHostPort(_currentUrl, widget.baseAddress))
          ? await GrassBagNativeBridge.instance.getWebViewCookies(_currentUrl)
          : null;
      if (!mounted || _completed) return;
      final merged = _mergeCookieHeaders(baseCookie, curCookie);
      if (merged.isEmpty) {
        if (!silent && mounted) {
          setState(() => _statusText = '尚未检测到登录凭证，请先在网页中完成认证');
        }
        return;
      }
      if (silent && merged == _lastCheckedCookie) {
        return;
      }
      final diag = await ref.read(appProvider.notifier).diagnoseRemoteHost(
            widget.baseAddress,
            cookie: merged,
            allowBadCertificates: widget.allowBadCertificates,
          );
      if (!mounted || _completed) return;
      if (diag.canConnectNow) {
        _lastCheckedCookie = merged;
        _completed = true;
        _pollTimer?.cancel();
        HapticFeedback.mediumImpact();
        Navigator.of(context).pop<String>(merged);
        return;
      }
      // Only suppress repeated background polls when diagnosis returned a definitive
      // non-transient result (never permanently cache over temporary unreachable glitches).
      if (diag.kind != RemoteDiagnosisKind.unreachable) {
        _lastCheckedCookie = merged;
      }
      if (!silent && mounted) {
        setState(() => _statusText = diag.message);
      }
    } finally {
      _verifying = false;
      if (mounted && !_completed) {
        if (_pendingManualVerify) {
          _pendingManualVerify = false;
          unawaited(_checkCookiesAndComplete(silent: false));
        } else if (_manualVerifying) {
          setState(() => _manualVerifying = false);
        }
      }
    }
  }

  Future<void> _pasteAndNavigate() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = clip?.text?.trim() ?? '';
    if (text.isEmpty) {
      ref.read(appProvider.notifier).showToast('剪贴板为空', tone: ToastTone.info);
      return;
    }
    final parsed = parseRemoteHostInput(text);
    final baseUri = parsed == null ? null : Uri.tryParse(parsed.address);
    if (parsed == null || baseUri == null || !baseUri.hasScheme) {
      ref.read(appProvider.notifier).showToast('剪贴板中未识别到有效链接', tone: ToastTone.warn);
      return;
    }
    final target = (parsed.token != null && parsed.token!.isNotEmpty)
        ? baseUri.replace(
            queryParameters: {...baseUri.queryParameters, 'token': parsed.token!},
          )
        : baseUri;
    if (!_isSameHostPort(target.toString(), widget.baseAddress)) {
      ref.read(appProvider.notifier).showToast(
            '粘贴链接的主机地址与当前目标「${widget.hostName}」不一致，已取消跳转',
            tone: ToastTone.warn,
          );
      return;
    }
    if (_controller != null) {
      setState(() => _statusText = '正在加载粘贴的认证链接…');
      await _controller!.loadRequest(target);
    }
  }

  static String _mergeCookieHeaders(String? a, String? b) {
    final map = <String, String>{};
    for (final raw in [a, b]) {
      if (raw == null || raw.trim().isEmpty) continue;
      for (final part in raw.split(';')) {
        final idx = part.indexOf('=');
        if (idx > 0) {
          map[part.substring(0, idx).trim()] = part.substring(idx + 1).trim();
        }
      }
    }
    return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  void _reloadOrRetry() {
    final ctrl = _controller;
    if (ctrl == null) return;
    if (_hasLoadError) {
      final baseUri = Uri.tryParse(widget.baseAddress);
      if (baseUri != null && (baseUri.scheme == 'http' || baseUri.scheme == 'https')) {
        _progress.value = 0.1;
        setState(() {
          _hasLoadError = false;
          _statusText = _defaultStatusText;
        });
        unawaited(ctrl.loadRequest(baseUri));
      } else {
        setState(() {
          _hasLoadError = true;
          _statusText = '远程主机地址格式无效，请检查后重试：${widget.baseAddress}';
        });
      }
      return;
    }
    _progress.value = 0.1;
    setState(() => _statusText = _defaultStatusText);
    unawaited(ctrl.reload());
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final botPad = MediaQuery.paddingOf(context).bottom;
    final parsedCur = Uri.tryParse(_currentUrl);
    final hostSubtitle = (parsedCur != null && parsedCur.host.isNotEmpty)
        ? (parsedCur.hasPort ? '${parsedCur.host}:${parsedCur.port}' : parsedCur.host)
        : widget.baseAddress;

    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && _canGoBack && _controller != null) {
          final nav = Navigator.of(context);
          if (await _controller!.canGoBack()) {
            await _controller!.goBack();
            unawaited(_syncCanGoBack());
          } else if (mounted) {
            setState(() => _canGoBack = false);
            nav.pop<String>(null);
          }
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
                    title: '登录 ${widget.hostName}',
                    subtitle: hostSubtitle,
                    tier: tier,
                    floating: false,
                    onBack: () => Navigator.of(context).pop<String>(null),
                    trailing: _controller == null
                        ? null
                        : GrassBagGlassCircleButton(
                            icon: CupertinoIcons.refresh,
                            tooltip: '刷新页面',
                            tier: tier,
                            useOwnLayer: false,
                            onTap: _reloadOrRetry,
                          ),
                  ),
                  // Compact status + one-tap verify/paste bar
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                    child: GrassBagCard(
                      borderRadius: 18,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              if (_manualVerifying)
                                GrassBagActivityIndicator(radius: 7.5, color: t.primary)
                              else
                                Icon(
                                  _hasLoadError
                                      ? CupertinoIcons.exclamationmark_triangle_fill
                                      : CupertinoIcons.lock_shield_fill,
                                  size: 15,
                                  color: _hasLoadError ? t.warn : t.primary,
                                ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  _statusText,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, height: 1.35, color: t.text2),
                                ),
                              ),
                            ],
                          ),
                          if (_controller != null) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: GrassBagPrimaryGlassButton(
                                    label: _manualVerifying ? '正在验证凭证…' : '我已登录 · 同步凭证',
                                    icon: CupertinoIcons.checkmark_shield_fill,
                                    height: 34,
                                    tier: tier,
                                    insideGlass: true,
                                    enabled: !_manualVerifying,
                                    onTap: _manualVerifying
                                        ? null
                                        : () => _checkCookiesAndComplete(silent: false),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                GrassBagSecondaryGlassButton(
                                  label: '粘贴链接',
                                  icon: CupertinoIcons.doc_on_clipboard,
                                  height: 34,
                                  padding: const EdgeInsets.symmetric(horizontal: 11),
                                  tier: tier,
                                  insideGlass: true,
                                  onTap: _pasteAndNavigate,
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(12, 0, 12, botPad > 0 ? botPad + 8 : 14),
                      child: CustomPaint(
                        foregroundPainter: tier == GrassBagGlassTier.solid
                            ? null
                            : GrassBagFresnelRimPainter(
                                isDark: t.isDark,
                                borderRadius: 24,
                                innerWell: true,
                                frosted: tier == GrassBagGlassTier.frosted,
                                paintTopSheen: false,
                                strokeWidth: 0.85,
                              ),
                        child: ClipRSuperellipse(
                          borderRadius: BorderRadius.circular(24),
                          child: DecoratedBox(
                            decoration: ShapeDecoration(
                              color: t.cardSolid,
                              shape: RoundedSuperellipseBorder(
                                borderRadius: BorderRadius.circular(24),
                                side: tier == GrassBagGlassTier.solid
                                    ? BorderSide(color: t.sepStrong, width: 0.65)
                                    : BorderSide.none,
                              ),
                            ),
                            child: Stack(
                              children: [
                                if (_controller != null)
                                  WebViewWidget(controller: _controller!)
                                else
                                  Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(24),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(CupertinoIcons.globe, size: 36, color: t.text3),
                                          const SizedBox(height: 12),
                                          Text(
                                            '当前平台不支持内置 WebView 凭证同步',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: t.text,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            '请在浏览器打开 ${widget.baseAddress}，或直接粘贴终端打印的 dsh web 启动链接。',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(fontSize: 12.5, height: 1.45, color: t.text2),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                if (_controller != null && _hasLoadError)
                                  Positioned.fill(
                                    child: ColoredBox(
                                      color: t.bgSolid.withValues(alpha: 0.96),
                                      child: Center(
                                        child: Padding(
                                          padding: const EdgeInsets.all(24),
                                          child: GrassBagCard(
                                            borderRadius: 24,
                                            padding: const EdgeInsets.all(20),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                GrassBagSquircleIcon(
                                                  icon: CupertinoIcons.wifi_exclamationmark,
                                                  color: t.warn,
                                                  size: 44,
                                                  iconSize: 20,
                                                ),
                                                const SizedBox(height: 12),
                                                Text(
                                                  '登录页面加载失败',
                                                  style: TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w600,
                                                    color: t.text,
                                                  ),
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  _statusText,
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    fontSize: 12.5,
                                                    height: 1.45,
                                                    color: t.text3,
                                                  ),
                                                ),
                                                const SizedBox(height: 16),
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: GrassBagSecondaryGlassButton(
                                                        label: '粘贴链接',
                                                        icon: CupertinoIcons.doc_on_clipboard,
                                                        tier: tier,
                                                        insideGlass: true,
                                                        onTap: _pasteAndNavigate,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 10),
                                                    Expanded(
                                                      child: GrassBagPrimaryGlassButton(
                                                        label: '重新加载',
                                                        icon: CupertinoIcons.refresh,
                                                        tier: tier,
                                                        insideGlass: true,
                                                        onTap: _reloadOrRetry,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  child: IgnorePointer(
                                    child: ValueListenableBuilder<double>(
                                      valueListenable: _progress,
                                      builder: (_, v, __) {
                                        if (v <= 0 || v >= 0.99) return const SizedBox.shrink();
                                        return GrassBagProgressBar(
                                          value: v,
                                          height: 2.5,
                                          color: t.primary,
                                          trackColor: Colors.transparent,
                                        );
                                      },
                                    ),
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
              const GrassBagToastOverlay(bottomOffset: 24),
            ],
          ),
        ),
      ),
    );
  }
}
