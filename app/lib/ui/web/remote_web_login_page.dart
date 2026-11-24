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
  WebViewController? _controller;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0.0);
  Timer? _pollTimer;
  String _currentUrl = '';
  String _statusText = '在下方完成网页登录或粘贴一次启动链接，认证通过后自动返回原生界面';
  bool _verifying = false;
  bool _completed = false;
  String? _lastCheckedCookie;

  bool get _supportsNativeWebView =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.baseAddress;
    if (_supportsNativeWebView) {
      final ctrl = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..setNavigationDelegate(
          NavigationDelegate(
            onProgress: (p) {
              if (!mounted) return;
              _progress.value = (p / 100.0).clamp(0.0, 1.0);
            },
            onPageStarted: (url) {
              if (mounted) setState(() => _currentUrl = url);
            },
            onPageFinished: (url) {
              if (!mounted) return;
              _progress.value = 1.0;
              setState(() => _currentUrl = url);
              unawaited(_checkCookiesAndComplete(silent: true));
            },
            onWebResourceError: (err) {
              if (err.isForMainFrame == false || !mounted) return;
              setState(() {
                _progress.value = 1.0;
                _statusText = '页面加载失败：${err.description.isNotEmpty ? err.description : '错误码 ${err.errorCode}'}';
              });
            },
            onSslAuthError: (request) async {
              if (widget.allowBadCertificates) {
                await request.proceed();
              } else {
                await request.cancel();
                if (mounted) {
                  setState(() {
                    _progress.value = 1.0;
                    _statusText = '检测到自签名 HTTPS 证书，请先开启「信任自签名证书」后再重试登录';
                  });
                }
              }
            },
          ),
        );
      final parsed = Uri.tryParse(widget.baseAddress);
      if (parsed != null && parsed.hasScheme) {
        unawaited(ctrl.loadRequest(parsed));
      }
      _controller = ctrl;
      _pollTimer = Timer.periodic(const Duration(milliseconds: 2400), (_) {
        unawaited(_checkCookiesAndComplete(silent: true));
      });
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _progress.dispose();
    super.dispose();
  }

  Future<void> _checkCookiesAndComplete({required bool silent}) async {
    if (!mounted || _completed || _verifying) return;
    _verifying = true;
    try {
      final baseCookie = await GrassBagNativeBridge.instance.getWebViewCookies(widget.baseAddress);
      if (!mounted || _completed) return;
      final curCookie = (_currentUrl.startsWith('http') && _currentUrl != widget.baseAddress)
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
      _lastCheckedCookie = merged;
      if (!silent && mounted) {
        setState(() => _statusText = '正在验证登录凭证与远程 DSH 连通性…');
      }
      final diag = await ref.read(appProvider.notifier).diagnoseRemoteHost(
            widget.baseAddress,
            cookie: merged,
            allowBadCertificates: widget.allowBadCertificates,
          );
      if (!mounted || _completed) return;
      if (diag.canConnectNow) {
        _completed = true;
        _pollTimer?.cancel();
        Navigator.of(context).pop<String>(merged);
        return;
      }
      if (!silent && mounted) {
        setState(() => _statusText = diag.message);
      }
    } finally {
      _verifying = false;
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

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final topPad = MediaQuery.viewPaddingOf(context).top;
    final botPad = MediaQuery.viewPaddingOf(context).bottom;

    return GrassBagGlassPage(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Column(
              children: [
                SizedBox(height: topPad + 66),
                // Compact status + one-tap verify/paste bar
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: GrassBagCard(
                    borderRadius: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(CupertinoIcons.lock_shield_fill, size: 15, color: t.primary),
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
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: GrassBagPrimaryGlassButton(
                                label: '我已登录 · 同步凭证',
                                icon: CupertinoIcons.checkmark_shield_fill,
                                height: 34,
                                tier: tier,
                                insideGlass: true,
                                onTap: () => _checkCookiesAndComplete(silent: false),
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
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(12, 0, 12, botPad + 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: t.bgSolid,
                          border: Border.all(color: t.sep, width: 0.7),
                          borderRadius: BorderRadius.circular(18),
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
              ],
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GrassBagUnifiedHeader(
                title: '登录 ${widget.hostName}',
                tier: tier,
                onBack: () => Navigator.of(context).pop<String>(null),
                trailing: _controller == null
                    ? null
                    : GrassBagGlassCircleButton(
                        icon: CupertinoIcons.refresh,
                        tooltip: '刷新页面',
                        size: 40,
                        iconSize: 17,
                        tier: tier,
                        useOwnLayer: false,
                        onTap: () => _controller?.reload(),
                      ),
              ),
            ),
            const GrassBagToastOverlay(bottomOffset: 24),
          ],
        ),
      ),
    );
  }
}
