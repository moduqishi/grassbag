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
    if (url == null || url.isEmpty || !context.mounted) return;

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
  bool _callbackHit = false;

  @override
  void initState() {
    super.initState();
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
            setState(() {
              _loadError = null;
              if (uri != null && uri.host.isNotEmpty) {
                _currentHost = _isLoopbackHost(uri.host) ? '正在完成本机授权校验…' : uri.host;
              }
            });
          },
          onPageFinished: (url) {
            if (!mounted) return;
            _progress.value = 1.0;
            final uri = Uri.tryParse(url);
            if (uri != null && _isLoopbackHost(uri.host)) {
              _callbackHit = true;
              // Loopback callback reached local DSH: refresh immediately & retry once after 600ms.
              unawaited(_pollFastAfterCallback());
            }
          },
          onWebResourceError: (err) {
            if (!mounted || err.isForMainFrame != true) return;
            // Ignore transient loopback redirect errors after DSH already accepted the callback.
            if (_callbackHit || ref.read(appProvider).isAccountSignedIn) return;
            setState(() {
              _loadError = err.description.isNotEmpty ? err.description : '页面加载失败 (${err.errorCode})';
            });
          },
        ),
      );
    if (initialUri != null && (initialUri.scheme == 'http' || initialUri.scheme == 'https')) {
      unawaited(_controller.loadRequest(initialUri));
    } else {
      _loadError = '授权地址格式无效：${widget.initialUrl}';
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

  Future<void> _pollFastAfterCallback() async {
    final ctrl = ref.read(appProvider.notifier);
    for (final delayMs in const [150, 500, 1200, 2000]) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      if (!mounted || _completed) return;
      await ctrl.refreshAccount(silent: true);
      if (!mounted || _completed) return;
      if (ref.read(appProvider).isAccountSignedIn) return;
    }
  }

  Future<void> _handleCancelBack() async {
    if (!_completed && !ref.read(appProvider).isAccountSignedIn) {
      unawaited(ref.read(appProvider.notifier).cancelDeepSeekSignIn());
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      appProvider.select((s) => s.isAccountSignedIn),
      (prev, next) {
        if (next && !_completed && mounted) {
          _completed = true;
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
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleCancelBack());
      },
      child: GrassBagGlassPage(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              Column(
                children: [
                  GrassBagUnifiedHeader(
                    title: '登录 DeepSeek 账号',
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
                            _progress.value = 0.12;
                            if (_loadError != null) {
                              final retryUri = Uri.tryParse(widget.initialUrl);
                              if (retryUri != null &&
                                  (retryUri.scheme == 'http' || retryUri.scheme == 'https')) {
                                setState(() => _loadError = null);
                                unawaited(_controller.loadRequest(retryUri));
                              } else {
                                setState(() => _loadError = '授权地址格式无效：${widget.initialUrl}');
                              }
                              return;
                            }
                            _controller.reload();
                          },
                        ),
                        const SizedBox(width: 8),
                        GrassBagGlassCircleButton(
                          icon: CupertinoIcons.compass,
                          tooltip: '在外部浏览器打开',
                          tier: glassTier,
                          useOwnLayer: false,
                          onTap: () async {
                            final ok = await GrassBagNativeBridge.instance
                                .openExternalUrl(widget.initialUrl);
                            if (!ok && mounted) {
                              await Clipboard.setData(ClipboardData(text: widget.initialUrl));
                              if (!mounted) return;
                              ref.read(appProvider.notifier).showToast('已复制授权链接到剪贴板', tone: ToastTone.info);
                            }
                          },
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
                        message: 'DeepSeek 授权回调默认指向目标电脑本机端口；若手机内回调超时，请点击右上角复制链接并在该电脑浏览器完成登录。',
                        borderRadius: 16,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: MediaQuery.viewPaddingOf(context).bottom),
                      child: Stack(
                        children: [
                          Positioned.fill(
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
                                                    label: '浏览器打开',
                                                    icon: CupertinoIcons.compass,
                                                    tier: glassTier,
                                                    insideGlass: true,
                                                    onTap: () => GrassBagNativeBridge.instance
                                                        .openExternalUrl(widget.initialUrl),
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
                                                      _progress.value = 0.12;
                                                      final retryUri = Uri.tryParse(widget.initialUrl);
                                                      if (retryUri != null &&
                                                          (retryUri.scheme == 'http' ||
                                                              retryUri.scheme == 'https')) {
                                                        setState(() => _loadError = null);
                                                        unawaited(_controller.loadRequest(retryUri));
                                                      } else {
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
                                    child: WebViewWidget(controller: _controller),
                                  ),
                          ),
                          // ValueListenable overlay progress bar: 50x onProgress ticks NEVER rebuild the page or resize WebView!
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
