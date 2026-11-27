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

bool _signInFlowLaunching = false;

/// Unified DeepSeek OAuth entry point:
/// - On Android / iOS: initiates OAuth via DSH and opens the authorization flow **entirely inside GrassBag**
///   using an embedded WebView that auto-closes the instant DSH finishes storing credentials.
/// - On Web / Desktop: opens in a new browser tab as standard.
Future<void> launchDeepSeekSignInFlow(BuildContext context, [WidgetRef? ref]) async {
  if (_signInFlowLaunching || !context.mounted) return;
  _signInFlowLaunching = true;
  try {
    // Always resolve via `context`'s ProviderScope so callers launching after popping a modal sheet
    // never crash with `Cannot use "ref" after the widget was disposed`!
    final ctrl = ProviderScope.containerOf(context, listen: false).read(appProvider.notifier);
    final useInAppWebView = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (!useInAppWebView) {
      await ctrl.startDeepSeekSignIn(openExternally: true);
      return;
    }

    ctrl.showToast('正在准备 DeepSeek 授权页面…', tone: ToastTone.info);
    final url = await ctrl.startDeepSeekSignIn(openExternally: false);
    if (url == null || url.isEmpty) return;
    if (!context.mounted) {
      unawaited(ctrl.cancelDeepSeekSignIn());
      return;
    }

    await Navigator.of(context).push(
      GrassBagPageRoute<void>(
        builder: (_) => DeepSeekSignInPage(initialUrl: url),
      ),
    );
  } finally {
    _signInFlowLaunching = false;
  }
}

/// Native In-App DeepSeek OAuth WebView Page.
/// Handles the entire sign-in and loopback callback inside the App without bouncing
/// the user out to an external browser, and auto-dismisses once signed in.
class DeepSeekSignInPage extends ConsumerStatefulWidget {
  const DeepSeekSignInPage({
    super.key,
    required this.initialUrl,
  });

  final String initialUrl;

  @override
  ConsumerState<DeepSeekSignInPage> createState() => _DeepSeekSignInPageState();
}

class _DeepSeekSignInPageState extends ConsumerState<DeepSeekSignInPage> {
  late final WebViewController _controller;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0.08);
  String _currentHost = 'DeepSeek 账号授权';
  String? _loadError;
  bool _completed = false;
  bool _popped = false;
  bool _callbackHit = false;
  bool _pollingAfterCallback = false;
  bool _handedOffExternally = false;
  bool _canGoBack = false;

  Future<void> _syncCanGoBack() async {
    try {
      final back = await _controller.canGoBack();
      if (mounted && back != _canGoBack) {
        setState(() => _canGoBack = back);
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    final initialState = ref.read(appProvider);
    if (initialState.isAccountSignedIn) {
      _completed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_popped) {
          _popped = true;
          Navigator.of(context).pop();
        }
      });
    }
    final initialUri = Uri.tryParse(widget.initialUrl);
    if (initialUri != null && initialUri.host.isNotEmpty) {
      _currentHost = initialUri.host;
    }

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (!mounted) return;
            _progress.value = (p / 100.0).clamp(0.05, 1.0);
          },
          onPageStarted: (url) {
            if (!mounted) return;
            final uri = Uri.tryParse(url);
            final isLoopback = uri != null && _isLoopbackHost(uri.host);
            if (isLoopback) {
              _callbackHit = true;
              unawaited(_pollFastAfterCallback());
            } else {
              _callbackHit = false;
            }
            setState(() {
              _loadError = null;
              if (uri != null && uri.host.isNotEmpty) {
                _currentHost = isLoopback ? '正在完成本机授权校验…' : uri.host;
              }
            });
            unawaited(_syncCanGoBack());
          },
          onPageFinished: (url) {
            if (!mounted) return;
            _progress.value = 1.0;
            final uri = Uri.tryParse(url);
            if (uri != null && _isLoopbackHost(uri.host)) {
              if (!_callbackHit) setState(() => _callbackHit = true);
              // Loopback callback reached local DSH: refresh immediately & retry.
              unawaited(_pollFastAfterCallback());
            }
            unawaited(_syncCanGoBack());
          },
          onWebResourceError: (err) {
            if (!mounted || err.isForMainFrame != true) return;
            _progress.value = 1.0;
            final appState = ref.read(appProvider);
            if (appState.isAccountSignedIn) return;
            // On local Android container, a transient loopback redirect error after DSH
            // already accepted the callback is harmless; on a remote host, 127.0.0.1 is the
            // remote computer's loopback so show clear guidance instead of a broken WebView!
            if (_callbackHit) {
              if (appState.activeHost.isLocal) return;
              setState(() {
                _loadError =
                    '授权回调指向目标电脑的本机回环地址，手机端无法直接访问。请点击下方「复制授权链接」，在目标电脑浏览器中打开并完成登录。';
              });
              return;
            }
            setState(() {
              _loadError = _localizeWebError(err.description, err.errorCode);
            });
          },
        ),
      );
    try {
      unawaited(
        _controller.setBackgroundColor(
          initialState.isDark ? const Color(0xFF141B26) : const Color(0xFFF6F9FC),
        ),
      );
    } catch (_) {}
    if (!_completed) {
      if (initialUri != null && (initialUri.scheme == 'http' || initialUri.scheme == 'https')) {
        unawaited(_controller.loadRequest(initialUri));
      } else {
        _progress.value = 1.0;
        _loadError = '授权地址格式无效：${widget.initialUrl}';
      }
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  static bool _isLoopbackHost(String host) {
    final h = host.toLowerCase();
    return h == '127.0.0.1' || h == 'localhost' || h == '::1';
  }

  static String _localizeWebError(String description, int errorCode) {
    final upper = description.toUpperCase();
    if (upper.contains('ERR_CONNECTION_REFUSED')) {
      return '目标主机拒绝连接，请确认服务可达或网络通畅后重试。';
    }
    if (upper.contains('ERR_NAME_NOT_RESOLVED')) {
      return '无法解析登录域名，请检查网络连接或 DNS 设置。';
    }
    if (upper.contains('ERR_TIMED_OUT') || upper.contains('ERR_CONNECTION_TIMED_OUT')) {
      return '连接超时，请检查网络或代理设置后重试。';
    }
    if (upper.contains('ERR_INTERNET_DISCONNECTED') || upper.contains('ERR_NETWORK_CHANGED')) {
      return '当前网络已断开，请恢复网络后点击重新加载。';
    }
    if (upper.contains('SSL') || upper.contains('CERT')) {
      return 'HTTPS 安全证书校验失败，请检查系统时间或网络代理。';
    }
    return description.isNotEmpty ? '授权页面加载失败：$description' : '授权页面加载失败（错误码 $errorCode）';
  }

  Future<void> _pollFastAfterCallback() async {
    if (_pollingAfterCallback) return;
    _pollingAfterCallback = true;
    try {
      final ctrl = ref.read(appProvider.notifier);
      for (final delayMs in const [150, 500, 1200, 2000]) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        if (!mounted || _completed) return;
        await ctrl.refreshAccount(silent: true);
        if (!mounted || _completed) return;
        if (ref.read(appProvider).isAccountSignedIn) return;
      }
      if (mounted &&
          !_completed &&
          _callbackHit &&
          ref.read(appProvider).activeHost.isLocal &&
          !ref.read(appProvider).isAccountSignedIn) {
        _progress.value = 1.0;
        setState(() {
          _loadError = '本机授权回调超时，请点击「重新加载」重试或改用外部浏览器完成登录。';
        });
      }
    } finally {
      _pollingAfterCallback = false;
    }
  }

  Future<void> _copySignInUrl() async {
    _handedOffExternally = true;
    await Clipboard.setData(ClipboardData(text: widget.initialUrl));
    if (!mounted) return;
    ref.read(appProvider.notifier).showToast('已复制授权链接，可粘贴到浏览器完成登录', tone: ToastTone.ok);
  }

  Future<void> _openExternallyOrCopy() async {
    _handedOffExternally = true;
    final ok = await GrassBagNativeBridge.instance.openExternalUrl(widget.initialUrl);
    if (!ok && mounted) {
      await _copySignInUrl();
    }
  }

  Future<void> _handleCancelBack() async {
    if (_popped || !mounted) return;
    _popped = true;
    // Do NOT cancel the DSH OAuth session if the user handed off to an external browser or copied the link!
    if (!_completed && !_handedOffExternally && !ref.read(appProvider).isAccountSignedIn) {
      unawaited(ref.read(appProvider.notifier).cancelDeepSeekSignIn());
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      appProvider.select((s) => s.isAccountSignedIn),
      (prev, next) {
        if (next && !_completed && !_popped && mounted) {
          _completed = true;
          _popped = true;
          HapticFeedback.mediumImpact();
          Navigator.of(context).pop();
        }
      },
    );

    final glassTier = ref.watch(appProvider.select((s) => s.glassTier));
    final isRemoteHost = ref.watch(appProvider.select((s) => !s.activeHost.isLocal));
    final activeHostName = ref.watch(appProvider.select((s) => s.activeHost.name));
    final t = GrassBagTokens.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_canGoBack && !_callbackHit && _loadError == null) {
          try {
            if (await _controller.canGoBack()) {
              if (!mounted) return;
              await _controller.goBack();
              if (!mounted) return;
              unawaited(_syncCanGoBack());
              return;
            }
          } catch (_) {}
        }
        if (!mounted) return;
        unawaited(_handleCancelBack());
      },
      child: GrassBagGlassPage(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              Column(
                children: [
                  GrassBagUnifiedHeader(
                    title: 'DeepSeek 登录',
                    subtitle: _currentHost,
                    tier: glassTier,
                    floating: false,
                    onBack: _handleCancelBack,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GrassBagGlassCircleButton(
                          icon: CupertinoIcons.refresh,
                          tooltip: '刷新页面',
                          tier: glassTier,
                          useOwnLayer: false,
                          onTap: () {
                            _callbackHit = false;
                            if (_loadError != null) {
                              final retryUri = Uri.tryParse(widget.initialUrl);
                              if (retryUri != null &&
                                  (retryUri.scheme == 'http' || retryUri.scheme == 'https')) {
                                _progress.value = 0.12;
                                setState(() => _loadError = null);
                                unawaited(_controller.loadRequest(retryUri));
                              } else {
                                _progress.value = 1.0;
                                setState(() => _loadError = '授权地址格式无效：${widget.initialUrl}');
                              }
                              return;
                            }
                            _progress.value = 0.12;
                            _controller.reload();
                          },
                        ),
                        const SizedBox(width: 8),
                        GrassBagGlassCircleButton(
                          icon: isRemoteHost ? CupertinoIcons.doc_on_doc : CupertinoIcons.compass,
                          tooltip: isRemoteHost ? '复制授权链接到电脑浏览器打开' : '在外部浏览器打开',
                          tier: glassTier,
                          useOwnLayer: false,
                          onTap: isRemoteHost ? _copySignInUrl : _openExternallyOrCopy,
                        ),
                      ],
                    ),
                  ),
                  if (isRemoteHost)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: GrassBagStatusBanner(
                        tone: GrassBagBannerTone.info,
                        icon: CupertinoIcons.info_circle_fill,
                        title: '远程主机「$activeHostName」授权提示',
                        message: 'DeepSeek 授权回调默认指向目标电脑本机端口；若手机内回调超时，请复制链接并在该电脑浏览器完成登录。',
                        borderRadius: 16,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                        action: GrassBagSecondaryGlassButton(
                          label: '复制授权链接',
                          icon: CupertinoIcons.doc_on_doc,
                          height: 32,
                          tier: glassTier,
                          insideGlass: true,
                          accentForeground: true,
                          onTap: _copySignInUrl,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
                      child: _loadError != null
                          ? Center(
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
                                        '授权页面加载失败',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: t.text,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        _loadError!,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(fontSize: 12.5, height: 1.45, color: t.text3),
                                      ),
                                      const SizedBox(height: 16),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: GrassBagSecondaryGlassButton(
                                              label: isRemoteHost ? '复制授权链接' : '浏览器打开',
                                              icon: isRemoteHost ? CupertinoIcons.doc_on_doc : CupertinoIcons.compass,
                                              tier: glassTier,
                                              insideGlass: true,
                                              onTap: isRemoteHost ? _copySignInUrl : _openExternallyOrCopy,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: GrassBagPrimaryGlassButton(
                                              label: '重新加载',
                                              icon: CupertinoIcons.refresh,
                                              tier: glassTier,
                                              insideGlass: true,
                                              onTap: () {
                                                _callbackHit = false;
                                                final retryUri = Uri.tryParse(widget.initialUrl);
                                                if (retryUri != null &&
                                                    (retryUri.scheme == 'http' ||
                                                        retryUri.scheme == 'https')) {
                                                  _progress.value = 0.12;
                                                  setState(() => _loadError = null);
                                                  unawaited(_controller.loadRequest(retryUri));
                                                } else {
                                                  _progress.value = 1.0;
                                                  setState(() => _loadError = '授权地址格式无效：${widget.initialUrl}');
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
                            )
                          : ClipRSuperellipse(
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                              child: Stack(
                                children: [
                                  Positioned.fill(child: WebViewWidget(controller: _controller)),
                                  if (_callbackHit && !isRemoteHost)
                                    Positioned.fill(
                                      child: ColoredBox(
                                        color: t.bgSolid.withValues(alpha: 0.94),
                                        child: Center(
                                          child: Padding(
                                            padding: const EdgeInsets.all(24),
                                            child: GrassBagCard(
                                              borderRadius: 24,
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 24,
                                                vertical: 22,
                                              ),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  GrassBagActivityIndicator(
                                                    radius: 13,
                                                    color: t.primary,
                                                  ),
                                                  const SizedBox(height: 14),
                                                  Text(
                                                    '正在完成本机授权校验…',
                                                    style: TextStyle(
                                                      fontSize: 15,
                                                      fontWeight: FontWeight.w600,
                                                      color: t.text,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    '验证通过后将自动返回',
                                                    style: TextStyle(
                                                      fontSize: 12.5,
                                                      color: t.text3,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  // ValueListenable overlay progress bar clipped cleanly inside rounded corners
                                  Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    child: IgnorePointer(
                                      child: ValueListenableBuilder<double>(
                                        valueListenable: _progress,
                                        builder: (_, val, __) => AnimatedOpacity(
                                          opacity: val < 0.99 ? 1.0 : 0.0,
                                          duration: const Duration(milliseconds: 160),
                                          child: GrassBagProgressBar(
                                            value: val,
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
