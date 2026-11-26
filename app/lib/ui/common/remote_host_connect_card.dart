import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../web/remote_web_login_page.dart';
import 'qr_pair_scanner_page.dart';

/// Unified, frictionless Remote DSH Host connector shared by Onboarding, Quick Connect Sheet,
/// and Settings:
/// - 1-tap QR code scan (`扫码连接`) matching `dsh-gbridge` Desktop/Web native QR pairing UI
/// - Auto-scans LAN on mount with 1-tap connect for discovered open DSH hosts
/// - Smart clipboard paste (recognizes `grassbag://pair?...`, `dsh web: http://.../?token=...`, bare IPs, and tokens)
/// - Preserves freshly minted 30-day session cookies across diagnose -> connect (never burns a one-time token twice!)
/// - Non-destructive pre-flight diagnosis: never hijacks activeHostId when unreachable or awaiting auth
/// - Clean 2-tab Official Accelerated Plugin (Zero Port Conflict + QR UI) + Zero-Plugin CLI guide
class RemoteHostConnectCard extends ConsumerStatefulWidget {
  const RemoteHostConnectCard({
    super.key,
    this.onConnectedHost,
    this.connectImmediately = true,
    this.showHeader = true,
    this.initiallyShowGuide = false,
    this.autoScanLan = true,
    this.embeddedInSheet = false,
    this.initialInput,
    this.initialDiagnosis,
  });

  /// Official 1-line CLI command installing `dsh-gbridge.tgz` via China GitHub mirror (zero port conflict!).
  static const String acceleratedInstallCommand =
      'dsh plugin add $kOfficialGbridgeAcceleratedUrl';

  /// Shared Desktop GUI 1-tap AI prompt used across Onboarding, Quick Connect, Auth Sheet, and Host Detail.
  /// Installs our official zero-conflict `dsh-gbridge` plugin via GitHub mirror directly into the
  /// running DeepSeek Harness instance (NO slow second `dsh web` process, NO port conflict, shows QR UI!).
  static const String desktopGuiPrompt = '''请帮我安装并启用 GrassBag 官方连接助手插件（零端口冲突、无需另开第二套 dsh web 服务，安装后会在桌面端左侧出现「手机连接」二维码面板）：
1. 请直接使用当前 DeepSeek Harness 的插件管理能力（或本机 dsh CLI）安装官方加速包：
   $kOfficialGbridgeAcceleratedUrl
   （若主加速源下载失败，可自动改用备用源 $kOfficialGbridgeDirectUrl ）
2. 插件启用后会自动复用当前运行的 DSH 实例（桌面端自动在 3081+ 零冲突端口开启局域网桥接，dsh web 直接复用原端口），无需额外启动新的 dsh web 进程；
3. 安装完成后，请查看本机局域网 IPv4 地址与 ~/.dsh/gbridge-lan-token（或直接在左侧栏点开「手机连接」显示二维码），把配对链接发给我即可用手机 GrassBag 扫码或一键连接。''';

  /// Called after a host is added (and connected when [connectImmediately] is true).
  final ValueChanged<ManagedHost>? onConnectedHost;

  /// If true, switches immediately to the newly connected host.
  final bool connectImmediately;

  /// Whether to render the card's title row ("直连远程 DSH 设备").
  final bool showHeader;

  /// Whether to expand the Desktop/CLI setup guide initially.
  final bool initiallyShowGuide;

  /// Whether to automatically trigger a lightweight LAN scan when this card opens.
  final bool autoScanLan;

  /// When rendered inside a modal sheet, omits the redundant outer GrassBagCard chrome.
  final bool embeddedInSheet;

  /// Optional prefilled URL/token/pair string (e.g. forwarded from a failed QR quick-connect).
  final String? initialInput;

  /// Optional prefilled diagnosis from a failed QR quick-connect so user sees exact remediation.
  final RemoteHostDiagnosis? initialDiagnosis;

  @override
  ConsumerState<RemoteHostConnectCard> createState() => _RemoteHostConnectCardState();
}

class _RemoteHostConnectCardState extends ConsumerState<RemoteHostConnectCard> {
  final TextEditingController _addrCtrl = TextEditingController();
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _tokenCtrl = TextEditingController();
  final FocusNode _addrFocus = FocusNode();
  final FocusNode _tokenFocus = FocusNode();

  bool _showAdvanced = false;
  late bool _showGuide;
  int _guideTab = 0; // 0: 桌面端 (免命令), 1: 命令行 (dsh web)
  int _cliOsTab = 0; // 0: macOS, 1: Windows, 2: Linux
  bool _allowBadCerts = false;
  bool _obscureToken = true;
  bool _connecting = false;
  bool _hasScannedLan = false;
  bool _hadAddrText = false;
  String? _capturedCookie;
  String? _selectedLanAddr;
  RemoteHostDiagnosis? _diagnosis;

  bool get _supportsInAppWebLogin =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _supportsQrScan =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  Future<void> _scanQrCode() async {
    if (_connecting) return;
    final raw = await Navigator.of(context).push<String>(
      GrassBagPageRoute<String>(
        builder: (_) => const QrPairScannerPage(),
      ),
    );
    if (!mounted || raw == null || raw.trim().isEmpty) return;
    await _applyParsedRemoteText(raw.trim(), sourceLabel: '二维码');
  }

  Future<void> _applyParsedRemoteText(String text, {required String sourceLabel}) async {
    final parsed = parseRemoteHostInput(text);
    if (parsed == null) {
      _addrCtrl.text = text;
      _hadAddrText = text.trim().isNotEmpty;
      setState(() {
        _capturedCookie = null;
        _diagnosis = null;
      });
      ref.read(appProvider.notifier).showToast('已填入$sourceLabel内容，请核对地址格式', tone: ToastTone.info);
      return;
    }
    final addrChanged = _addrCtrl.text.trim() != parsed.address;
    _addrCtrl.text = parsed.address;
    _hadAddrText = parsed.address.trim().isNotEmpty;
    if (parsed.token != null && parsed.token!.isNotEmpty) {
      _tokenCtrl.text = parsed.token!;
    } else if (addrChanged) {
      _tokenCtrl.clear();
    }
    if (_nameCtrl.text.trim().isEmpty && parsed.suggestedName != null) {
      _nameCtrl.text = parsed.suggestedName!;
    }
    setState(() {
      if (addrChanged) _capturedCookie = null;
      _selectedLanAddr = null;
      _diagnosis = null;
    });
    if (parsed.token != null && parsed.token!.isNotEmpty) {
      ref.read(appProvider.notifier).showToast('已识别$sourceLabel配对信息，正在一键接入…', tone: ToastTone.ok);
      await _connectNow();
    } else {
      ref.read(appProvider.notifier).showToast('已识别远程地址，正在检测连通性…', tone: ToastTone.ok);
      await _diagnoseOnly();
    }
  }

  @override
  void initState() {
    super.initState();
    _showGuide = widget.initiallyShowGuide;
    if (widget.initialInput != null && widget.initialInput!.trim().isNotEmpty) {
      final parsed = parseRemoteHostInput(widget.initialInput!.trim());
      if (parsed != null) {
        _addrCtrl.text = parsed.address;
        if (parsed.token != null && parsed.token!.isNotEmpty) {
          _tokenCtrl.text = parsed.token!;
        }
        if (parsed.suggestedName != null && parsed.suggestedName!.isNotEmpty) {
          _nameCtrl.text = parsed.suggestedName!;
        }
      } else {
        _addrCtrl.text = widget.initialInput!.trim();
      }
    }
    _hadAddrText = _addrCtrl.text.trim().isNotEmpty;
    if (widget.initialDiagnosis != null) {
      _diagnosis = widget.initialDiagnosis;
    }
    final isLiveApp = WidgetsBinding.instance is WidgetsFlutterBinding;
    final canAutoScan = !kIsWeb &&
        (GrassBagNativeBridge.instance.isPluginVerified ||
            (GrassBagNativeBridge.instance.isAndroidNative && isLiveApp));
    if (widget.autoScanLan && canAutoScan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final state = ref.read(appProvider);
        if (!state.scanningLan && state.discoveredLanHosts.isEmpty) {
          setState(() => _hasScannedLan = true);
          unawaited(ref.read(appProvider.notifier).scanLanForHosts(silent: true));
        } else if (state.discoveredLanHosts.isNotEmpty) {
          setState(() => _hasScannedLan = true);
        }
      });
    }
  }

  @override
  void dispose() {
    _addrCtrl.dispose();
    _nameCtrl.dispose();
    _tokenCtrl.dispose();
    _addrFocus.dispose();
    _tokenFocus.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      ref.read(appProvider.notifier).showToast('剪贴板为空，请先在电脑端复制链接或令牌', tone: ToastTone.info);
      return;
    }
    final parsed = parseRemoteHostInput(text);
    // Treat as a bare token (including JWTs / dotted tokens!) ONLY when it does NOT parse as a
    // host URL/IP and the user already has a host address entered.
    final looksBareToken = _addrCtrl.text.trim().isNotEmpty &&
        parsed == null &&
        !text.contains('://') &&
        !text.contains('/') &&
        RegExp(r'^[A-Za-z0-9._~+/=-]{8,}$').hasMatch(text);
    if (looksBareToken) {
      _tokenCtrl.text = text;
      setState(() {
        _showAdvanced = true;
        _diagnosis = null;
      });
      ref.read(appProvider.notifier).showToast('已填入访问令牌，正在验证并连接…', tone: ToastTone.ok);
      await _connectNow();
      return;
    }
    await _applyParsedRemoteText(text, sourceLabel: '剪贴板');
  }

  Future<RemoteHostDiagnosis?> _diagnoseOnly() async {
    final raw = _addrCtrl.text.trim();
    if (raw.isEmpty) {
      _addrFocus.requestFocus();
      ref.read(appProvider.notifier).showToast('请先输入远程地址或粘贴启动链接', tone: ToastTone.warn);
      return null;
    }
    if (_connecting) return _diagnosis;
    setState(() => _connecting = true);
    try {
      final diag = await ref.read(appProvider.notifier).diagnoseRemoteHost(
            raw,
            token: _tokenCtrl.text.trim().isEmpty ? null : _tokenCtrl.text.trim(),
            cookie: _capturedCookie,
            allowBadCertificates: _allowBadCerts,
          );
      if (!mounted) return diag;
      _applyDiagnosisFields(diag, raw);
      if (diag.needsWebOrTokenAuth) {
        setState(() => _showAdvanced = true);
      }
      return diag;
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _applyDiagnosisFields(RemoteHostDiagnosis diag, String raw) {
    if (diag.normalizedAddress != null && diag.normalizedAddress != raw) {
      _addrCtrl.text = diag.normalizedAddress!;
    }
    if (diag.extractedToken != null &&
        diag.extractedToken!.isNotEmpty &&
        _tokenCtrl.text.trim().isEmpty) {
      _tokenCtrl.text = diag.extractedToken!;
    }
    if (diag.capturedCookie != null && diag.capturedCookie!.isNotEmpty) {
      _capturedCookie = diag.capturedCookie;
    }
    setState(() => _diagnosis = diag);
  }

  Future<void> _openInAppWebLogin() async {
    final parsed = parseRemoteHostInput(_addrCtrl.text.trim());
    if (parsed == null) {
      ref.read(appProvider.notifier).showToast('请先填写远程主机地址', tone: ToastTone.warn);
      return;
    }
    final displayName =
        _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : (parsed.suggestedName ?? '远程主机');
    final cookie = await Navigator.of(context).push<String>(
      GrassBagPageRoute<String>(
        builder: (_) => RemoteWebLoginPage(
          hostName: displayName,
          baseAddress: parsed.address,
          allowBadCertificates: _allowBadCerts,
        ),
      ),
    );
    if (!mounted || cookie == null || cookie.trim().isEmpty) return;
    setState(() => _capturedCookie = cookie.trim());
    ref.read(appProvider.notifier).showToast('已获取 30 天免密登录凭证，正在接入…', tone: ToastTone.ok);
    await _connectNow();
  }

  Future<void> _connectNow() async {
    if (_connecting) return;
    final raw = _addrCtrl.text.trim();
    if (raw.isEmpty) {
      _addrFocus.requestFocus();
      ref.read(appProvider.notifier).showToast('请先输入远程地址或粘贴启动链接', tone: ToastTone.warn);
      return;
    }
    setState(() => _connecting = true);
    try {
      final ctrl = ref.read(appProvider.notifier);
      final tokenText = _tokenCtrl.text.trim();
      if (!widget.connectImmediately) {
        final diag = await ctrl.diagnoseRemoteHost(
          raw,
          token: tokenText.isEmpty ? null : tokenText,
          cookie: _capturedCookie,
          allowBadCertificates: _allowBadCerts,
        );
        if (!mounted) return;
        _applyDiagnosisFields(diag, raw);
        if (diag.canConnectNow && diag.normalizedAddress != null) {
          final created = ctrl.addRemoteHost(
            diag.normalizedAddress!,
            name: _nameCtrl.text.trim(),
            token: diag.extractedToken ?? (tokenText.isEmpty ? null : tokenText),
            cookie: diag.capturedCookie ?? _capturedCookie,
            allowBadCertificates: _allowBadCerts,
            autoProbe: true,
          );
          if (created != null) {
            _resetForm();
            widget.onConnectedHost?.call(created);
          }
        } else if (diag.needsWebOrTokenAuth) {
          setState(() => _showAdvanced = true);
          if (diag.kind != RemoteDiagnosisKind.htmlLoginPage) {
            _tokenFocus.requestFocus();
          }
        }
        return;
      }

      // Non-destructive 1-tap connect: diagnoses first, preserves newly minted session cookie,
      // and NEVER switches activeHostId if unreachable or awaiting auth!
      final outcome = await ctrl.connectRemoteInput(
        raw,
        name: _nameCtrl.text.trim(),
        token: tokenText.isEmpty ? null : tokenText,
        cookie: _capturedCookie,
        allowBadCertificates: _allowBadCerts,
      );
      if (!mounted) return;
      _applyDiagnosisFields(outcome.diagnosis, raw);
      if (outcome.connected && outcome.host != null) {
        _resetForm();
        widget.onConnectedHost?.call(outcome.host!);
      } else if (outcome.diagnosis.needsWebOrTokenAuth) {
        setState(() => _showAdvanced = true);
        if (outcome.diagnosis.kind != RemoteDiagnosisKind.htmlLoginPage) {
          _tokenFocus.requestFocus();
        }
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _resetForm() {
    _addrCtrl.clear();
    _nameCtrl.clear();
    _tokenCtrl.clear();
    setState(() {
      _capturedCookie = null;
      _diagnosis = null;
      _selectedLanAddr = null;
    });
  }

  Future<void> _onTapLanHost(DiscoveredLanHost h) async {
    final changed = _addrCtrl.text.trim() != h.address;
    _addrCtrl.text = h.address;
    _nameCtrl.text = h.name;
    setState(() {
      if (changed) {
        _capturedCookie = null;
        _tokenCtrl.clear();
      }
      _selectedLanAddr = h.address;
      _diagnosis = null;
    });
    if (!h.requiresAuth && h.isDsh) {
      await _connectNow();
    } else {
      await _diagnoseOnly();
      if (mounted && _diagnosis?.needsWebOrTokenAuth == true) {
        setState(() => _showAdvanced = true);
        if (_diagnosis?.kind != RemoteDiagnosisKind.htmlLoginPage) {
          _tokenFocus.requestFocus();
        }
      }
    }
  }

  void _copyCommand(String cmd) {
    Clipboard.setData(ClipboardData(text: cmd));
    ref.read(appProvider.notifier).showToast('已复制启动命令到剪贴板', tone: ToastTone.ok);
  }

  (String label, String cmd) get _currentCliCommand => switch (_cliOsTab) {
        0 => (
            'macOS 终端（自动检测当前网卡 IP）',
            r'dsh web --host $(ipconfig getifaddr $(route -n get default 2>/dev/null | awk "/interface:/{print \$2}" | head -n1) 2>/dev/null || ipconfig getifaddr en0) --no-open',
          ),
        1 => (
            'Windows PowerShell（自动检测默认出口 IP）',
            r'$ip=(Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1 | Get-NetIPAddress -AddressFamily IPv4).IPAddress; dsh web --host $ip --no-open',
          ),
        _ => (
            'Linux 终端（自动检测默认路由 IP）',
            r'dsh web --host $(ip -4 route get 1.1.1.1 | awk "{for(i=1;i<=NF;i++) if(\$i==\"src\") {print \$(i+1); exit}}") --no-open',
          ),
      };

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          scanningLan: s.scanningLan,
          discoveredLanHosts: s.discoveredLanHosts,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final diag = _diagnosis;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
          if (widget.showHeader) ...[
            Row(
              children: [
                GrassBagSquircleIcon(
                  icon: CupertinoIcons.desktopcomputer,
                  color: t.primary,
                  size: 36,
                  iconSize: 17,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '直连远程电脑 / 服务器',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '支持扫码秒连官方插件 · 也支持免插件直连原版 DSH',
                        style: TextStyle(fontSize: 11.5, color: t.text3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          // Quick-Action Top Bar: 1-tap QR Scan — single primary CTA hierarchy per viewport
          if (_supportsQrScan) ...[
            if (_addrCtrl.text.trim().isEmpty && _selectedLanAddr == null && diag == null)
              GrassBagPrimaryGlassButton(
                label: '扫码连接',
                icon: CupertinoIcons.qrcode_viewfinder,
                height: 42,
                tier: slice.glassTier,
                insideGlass: true,
                enabled: !_connecting,
                onTap: _connecting ? null : _scanQrCode,
              )
            else
              GrassBagSecondaryGlassButton(
                label: '改用扫码连接',
                icon: CupertinoIcons.qrcode_viewfinder,
                height: 40,
                tier: slice.glassTier,
                insideGlass: true,
                accentForeground: true,
                enabled: !_connecting,
                onTap: _connecting ? null : _scanQrCode,
              ),
            const SizedBox(height: 11),
          ],

          // LAN Auto-Discovery Live Radar Strip
          if (!kIsWeb) ...[
            _LanRadarStrip(
              scanning: slice.scanningLan,
              hasScanned: _hasScannedLan,
              hosts: slice.discoveredLanHosts,
              selectedAddr: _selectedLanAddr,
              busy: _connecting,
              onRescan: () {
                setState(() => _hasScannedLan = true);
                ctrl.scanLanForHosts();
              },
              onSelectHost: _onTapLanHost,
              onOpenGuide: () => setState(() {
                _showGuide = true;
                _guideTab = 0;
              }),
            ),
            const SizedBox(height: 11),
          ],

          // Smart Address / One-Line Link Input + Integrated Clipboard Paste Pill
          GrassBagTextField(
            controller: _addrCtrl,
            focusNode: _addrFocus,
            placeholder: '粘贴 dsh web: http://... 链接，或输入 IP:端口',
            insideGlass: true,
            monospace: true,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            fontSize: 13,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            suffix: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _addrCtrl,
              builder: (_, val, __) {
                if (val.text.isNotEmpty) {
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _addrCtrl.clear();
                      _tokenCtrl.clear();
                      _hadAddrText = false;
                      if (_diagnosis != null ||
                          _capturedCookie != null ||
                          _selectedLanAddr != null) {
                        setState(() {
                          _capturedCookie = null;
                          _selectedLanAddr = null;
                          _diagnosis = null;
                        });
                      } else {
                        setState(() {});
                      }
                    },
                    child: Tooltip(
                      message: '清空地址',
                      child: SizedBox(
                        width: 34,
                        height: 34,
                        child: Center(
                          child: Icon(
                            CupertinoIcons.xmark_circle_fill,
                            size: 16,
                            color: t.text3,
                          ),
                        ),
                      ),
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.only(right: 5),
                  child: GrassBagSpringTap(
                    enablePointerGlow: false,
                    haptic: true,
                    onTap: () {
                      if (!_connecting) _pasteFromClipboard();
                    },
                    child: GrassBagFresnelGlassSurface(
                      borderRadius: 10,
                      innerWell: true,
                      interactive: true,
                      tintColor: t.primarySoft,
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(CupertinoIcons.doc_on_clipboard, size: 12.5, color: t.primary),
                          const SizedBox(width: 4),
                          Text(
                            '粘贴',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: t.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            onChanged: (v) {
              final hasText = v.trim().isNotEmpty;
              final toggledEmpty = hasText != _hadAddrText;
              _hadAddrText = hasText;
              if (_diagnosis != null || _capturedCookie != null || _selectedLanAddr != null) {
                setState(() {
                  _capturedCookie = null;
                  _selectedLanAddr = null;
                  _diagnosis = null;
                });
              } else if (_supportsQrScan && toggledEmpty) {
                setState(() {});
              }
            },
            onSubmitted: (_) => _connectNow(),
          ),

          // Collapsible Advanced Options (Custom Name, Token, Self-signed TLS)
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _showAdvanced
                              ? CupertinoIcons.chevron_down
                              : CupertinoIcons.chevron_right,
                          size: 11.5,
                          color: t.text3,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            _tokenCtrl.text.trim().isNotEmpty
                                ? '高级选项（已填 Token）'
                                : '名称 / Token / 证书选项',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: t.text3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _showGuide = !_showGuide),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.question_circle,
                        size: 13,
                        color: t.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _showGuide ? '收起引导' : '如何获取电脑链接？',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: t.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          if (_showAdvanced)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GrassBagTextField(
                    controller: _tokenCtrl,
                    focusNode: _tokenFocus,
                    placeholder: '访问令牌 Token（选填，留空或走网页登录）',
                    insideGlass: true,
                    monospace: true,
                    obscureText: _obscureToken,
                    textInputAction: TextInputAction.done,
                    fontSize: 13,
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                    onChanged: (_) => setState(() => _diagnosis = null),
                    onSubmitted: (_) => _connectNow(),
                    suffix: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _obscureToken = !_obscureToken),
                      child: SizedBox(
                        width: 34,
                        height: 34,
                        child: Center(
                          child: Icon(
                            _obscureToken ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
                            size: 15,
                            color: t.text3,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  GrassBagTextField(
                    controller: _nameCtrl,
                    placeholder: '备注名称（选填，例如：办公室 Mac）',
                    insideGlass: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _connectNow(),
                    fontSize: 13,
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() {
                      _allowBadCerts = !_allowBadCerts;
                      _diagnosis = null;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '信任自签名 HTTPS 证书（Tailscale / Caddy / 内网）',
                              style: TextStyle(fontSize: 12, color: t.text2),
                            ),
                          ),
                          const SizedBox(width: 10),
                          GrassBagGlassSwitch(
                            value: _allowBadCerts,
                            tier: slice.glassTier,
                            onChanged: (v) => setState(() {
                              _allowBadCerts = v;
                              _diagnosis = null;
                            }),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Live inline diagnosis result banner (only shown when actionable!)
          if (diag != null) ...[
            const SizedBox(height: 10),
            GrassBagStatusBanner(
              tone: diag.canConnectNow
                  ? GrassBagBannerTone.ok
                  : (diag.needsWebOrTokenAuth || diag.kind == RemoteDiagnosisKind.selfDevice
                      ? GrassBagBannerTone.info
                      : (diag.kind == RemoteDiagnosisKind.unreachable ||
                              diag.kind == RemoteDiagnosisKind.invalidAddress
                          ? GrassBagBannerTone.error
                          : GrassBagBannerTone.warn)),
              icon: diag.canConnectNow
                  ? CupertinoIcons.checkmark_circle_fill
                  : (diag.needsWebOrTokenAuth
                      ? CupertinoIcons.lock_shield_fill
                      : (diag.kind == RemoteDiagnosisKind.selfDevice
                          ? CupertinoIcons.info_circle_fill
                          : CupertinoIcons.exclamationmark_triangle_fill)),
              title: diag.title,
              message: diag.message,
              padding: const EdgeInsets.all(12),
              borderRadius: 16,
              action: _buildDiagnosisActions(diag, slice.glassTier),
            ),
          ],

          // Single crystal-clear primary Connect CTA — always above the guide!
          // When QR scan is the active hero (empty input), keep Connect as crisp accent secondary
          // so only one Primary button leads the eye at any moment.
          const SizedBox(height: 12),
          if (_supportsQrScan &&
              _addrCtrl.text.trim().isEmpty &&
              _selectedLanAddr == null &&
              diag == null)
            GrassBagSecondaryGlassButton(
              label: _connecting ? '正在检测并连接…' : '连接远程设备',
              icon: CupertinoIcons.arrow_right_circle_fill,
              height: 44,
              tier: slice.glassTier,
              insideGlass: true,
              accentForeground: true,
              enabled: !_connecting,
              onTap: _connecting ? null : _connectNow,
            )
          else
            GrassBagPrimaryGlassButton(
              label: _connecting
                  ? '正在检测并连接…'
                  : (diag?.canConnectNow == true
                      ? (diag!.kind == RemoteDiagnosisKind.readyDirect ? '免插件立即接入' : '立即接入设备')
                      : (diag?.needsWebOrTokenAuth == true && _tokenCtrl.text.trim().isNotEmpty
                          ? '验证令牌并连接'
                          : '连接远程设备')),
              icon: CupertinoIcons.arrow_right_circle_fill,
              height: 44,
              tier: slice.glassTier,
              insideGlass: true,
              enabled: !_connecting,
              onTap: _connecting ? null : _connectNow,
            ),

          // Clean 2-tab Setup Guide positioned below the primary CTA so actions stay above the fold.
          // Avoid AnimatedSize so toggling inside a GrassBagGlass sheet does a single layout pass
          // instead of 22 consecutive glass backdrop rebakes.
          if (_showGuide)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: GrassBagSheetSection(
                borderRadius: 16,
                padding: const EdgeInsets.all(12),
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                    Row(
                      children: [
                        Expanded(
                          child: _GuideSegmentPill(
                            label: '官方插件（扫码推荐）',
                            selected: _guideTab == 0,
                            onTap: () => setState(() => _guideTab = 0),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: _GuideSegmentPill(
                            label: '免插件直连（dsh web）',
                            selected: _guideTab == 1,
                            onTap: () => setState(() => _guideTab = 1),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_guideTab == 0) ...[
                      const _CompactStepRow(
                        step: '1',
                        text: '在电脑端 DeepSeek Harness 安装 GrassBag 官方插件（国内镜像加速，零额外服务、零端口冲突）：',
                      ),
                      const SizedBox(height: 7),
                      _CommandCopyRow(
                        label: '终端一键安装（或在桌面端「插件 → 添加插件」直接粘贴 .tgz 地址）',
                        command: RemoteHostConnectCard.acceleratedInstallCommand,
                        onCopy: _copyCommand,
                      ),
                      const SizedBox(height: 8),
                      const _CompactStepRow(
                        step: '2',
                        text: '启用后桌面端左侧栏出现「手机连接」并立即弹出配对二维码，点击上方「扫码连接」1 秒接入。',
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: GrassBagSecondaryGlassButton(
                              label: '复制加速包地址',
                              icon: CupertinoIcons.link,
                              height: 36,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              tier: slice.glassTier,
                              insideGlass: true,
                              accentForeground: true,
                              onTap: () {
                                Clipboard.setData(
                                  const ClipboardData(text: kOfficialGbridgeAcceleratedUrl),
                                );
                                ctrl.showToast('已复制 .tgz 加速地址，可直接粘贴到 DSH 插件安装框',
                                    tone: ToastTone.ok);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: GrassBagSecondaryGlassButton(
                              label: '复制 AI 安装指令',
                              icon: CupertinoIcons.sparkles,
                              height: 36,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              tier: slice.glassTier,
                              insideGlass: true,
                              accentForeground: true,
                              onTap: () {
                                Clipboard.setData(
                                  const ClipboardData(text: RemoteHostConnectCard.desktopGuiPrompt),
                                );
                                ctrl.showToast('已复制 AI 安装指令，发给电脑端 DSH 即可自动安装',
                                    tone: ToastTone.ok);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 9),
                      Text(
                        '官方插件直接复用运行中的 DSH 实例：dsh web 共享原端口不另开服务，桌面端自动避让冲突端口并支持实时切换。',
                        style: TextStyle(fontSize: 11, height: 1.4, color: t.text3),
                      ),
                    ] else ...[
                      // Clean 1-command OS switcher
                      Row(
                        children: [
                          for (final (idx, osName) in [
                            (0, 'macOS'),
                            (1, 'Windows'),
                            (2, 'Linux'),
                          ]) ...[
                            if (idx > 0) const SizedBox(width: 6),
                            Expanded(
                              child: _OsChip(
                                label: osName,
                                selected: _cliOsTab == idx,
                                onTap: () => setState(() => _cliOsTab = idx),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      _CommandCopyRow(
                        label: _currentCliCommand.$1,
                        command: _currentCliCommand.$2,
                        onCopy: _copyCommand,
                      ),
                      const SizedBox(height: 7),
                      Text(
                        '无需任何插件：原版 dsh web 与桌面端共享全部会话与模型；首次粘贴启动链接后自动保持 30 天登录态。',
                        style: TextStyle(fontSize: 11, height: 1.4, color: t.text3),
                      ),
                    ],
                  ],
                ),
                ],
              ),
            ),
        ],
      );
    if (widget.embeddedInSheet) return body;
    return GrassBagCard(
      borderRadius: 24,
      padding: const EdgeInsets.all(15),
      child: body,
    );
  }

  Widget? _buildDiagnosisActions(RemoteHostDiagnosis diag, GrassBagGlassTier tier) {
    // Primary Connect CTA sits directly below the banner — never render a duplicate connect button!
    if (diag.canConnectNow) return null;

    if (diag.kind == RemoteDiagnosisKind.selfDevice) {
      if (_showGuide) return null;
      return GrassBagSecondaryGlassButton(
        label: '查看电脑端开启步骤',
        icon: CupertinoIcons.sparkles,
        height: 34,
        tier: tier,
        insideGlass: true,
        accentForeground: true,
        onTap: () => setState(() {
          _showGuide = true;
          _guideTab = 0;
        }),
      );
    }
    if (diag.needsWebOrTokenAuth) {
      final isHtmlProxy = diag.kind == RemoteDiagnosisKind.htmlLoginPage;
      return Row(
        children: [
          if (isHtmlProxy && _supportsInAppWebLogin) ...[
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: '网页登录',
                icon: CupertinoIcons.globe,
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tier: tier,
                insideGlass: true,
                enabled: !_connecting,
                onTap: _connecting ? null : _openInAppWebLogin,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '粘贴链接',
                icon: CupertinoIcons.doc_on_clipboard,
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tier: tier,
                insideGlass: true,
                enabled: !_connecting,
                onTap: _connecting ? null : _pasteFromClipboard,
              ),
            ),
          ] else ...[
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: '粘贴链接',
                icon: CupertinoIcons.doc_on_clipboard,
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tier: tier,
                insideGlass: true,
                enabled: !_connecting,
                onTap: _connecting ? null : _pasteFromClipboard,
              ),
            ),
            if (_supportsInAppWebLogin) ...[
              const SizedBox(width: 8),
              Expanded(
                child: GrassBagSecondaryGlassButton(
                  label: '网页登录',
                  icon: CupertinoIcons.globe,
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  tier: tier,
                  insideGlass: true,
                  enabled: !_connecting,
                  onTap: _connecting ? null : _openInAppWebLogin,
                ),
              ),
            ],
          ],
        ],
      );
    }
    if (diag.kind == RemoteDiagnosisKind.selfSignedTls) {
      return GrassBagPrimaryGlassButton(
        label: '信任自签名证书并连接',
        icon: CupertinoIcons.checkmark_shield_fill,
        height: 34,
        tier: tier,
        insideGlass: true,
        enabled: !_connecting,
        onTap: _connecting
            ? null
            : () {
                setState(() => _allowBadCerts = true);
                _connectNow();
              },
      );
    }
    if (diag.suggestedCommand != null && diag.suggestedCommand!.isNotEmpty) {
      return _CommandCopyRow(
        label: '在远程电脑运行后重试',
        command: diag.suggestedCommand!,
        onCopy: _copyCommand,
      );
    }
    return null;
  }
}

class _LanRadarStrip extends StatelessWidget {
  const _LanRadarStrip({
    required this.scanning,
    required this.hasScanned,
    required this.hosts,
    required this.selectedAddr,
    required this.busy,
    required this.onRescan,
    required this.onSelectHost,
    required this.onOpenGuide,
  });

  final bool scanning;
  final bool hasScanned;
  final List<DiscoveredLanHost> hosts;
  final String? selectedAddr;
  final bool busy;
  final VoidCallback onRescan;
  final ValueChanged<DiscoveredLanHost> onSelectHost;
  final VoidCallback onOpenGuide;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagFresnelGlassSurface(
      borderRadius: 16,
      innerWell: true,
      padding: const EdgeInsets.all(11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (scanning)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: GrassBagActivityIndicator(radius: 6.5, color: t.primary),
                )
              else
                Icon(
                  hosts.isNotEmpty ? CupertinoIcons.wifi : CupertinoIcons.antenna_radiowaves_left_right,
                  size: 14,
                  color: hosts.isNotEmpty ? t.ok : t.primary,
                ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  scanning
                      ? '正在搜索同局域网 DSH 设备…'
                      : (hosts.isNotEmpty
                          ? '已发现 ${hosts.length} 台局域网设备 · 点击直连'
                          : (hasScanned ? '同局域网暂未发现开放端口的设备' : '局域网自动发现')),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
              ),
              GrassBagSpringTap(
                enablePointerGlow: false,
                haptic: true,
                enabled: !scanning,
                onTap: onRescan,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Text(
                    scanning ? '扫描中' : '重新扫描',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: scanning ? t.text3 : t.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (hosts.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (int i = 0; i < hosts.length; i++) ...[
              if (i > 0) const SizedBox(height: 6),
              _LanHostTile(
                host: hosts[i],
                selected: selectedAddr == hosts[i].address,
                busy: busy,
                onTap: () => onSelectHost(hosts[i]),
              ),
            ],
          ] else if (hasScanned && !scanning) ...[
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '电脑端默认仅监听本机回环，开启共享后可被自动发现。',
                    style: TextStyle(fontSize: 11, height: 1.35, color: t.text3),
                  ),
                ),
                const SizedBox(width: 8),
                GrassBagSpringTap(
                  enablePointerGlow: false,
                  haptic: true,
                  onTap: onOpenGuide,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Text(
                      '开启引导',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: t.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LanHostTile extends StatelessWidget {
  const _LanHostTile({
    required this.host,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  final DiscoveredLanHost host;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final oneTapReady = !host.requiresAuth && host.isDsh;
    return GrassBagSpringTap(
      enablePointerGlow: false,
      haptic: true,
      enabled: !busy,
      onTap: onTap,
      child: GrassBagFresnelGlassSurface(
        borderRadius: 14,
        innerWell: !selected,
        interactive: !busy,
        tintColor: selected ? t.primarySoft : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(
              host.isDsh ? CupertinoIcons.desktopcomputer : CupertinoIcons.globe,
              size: 15,
              color: oneTapReady ? t.ok : t.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    host.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: t.text,
                    ),
                  ),
                  Text(
                    '${host.address} · ${host.latencyMs}ms'
                    '${host.isDesktop ? ' · 桌面桥接' : (host.hasGbridge ? ' · 增强助手' : (host.isDsh ? ' · 原生直连' : ''))}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      color: t.text3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            GrassBagFresnelGlassSurface(
              isPill: true,
              innerWell: true,
              tintColor: oneTapReady ? t.okSoft : t.primarySoft,
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              child: Text(
                oneTapReady ? '一键直连' : '授权接入',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: oneTapReady ? t.ok : t.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideSegmentPill extends StatelessWidget {
  const _GuideSegmentPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagSpringTap(
      enablePointerGlow: false,
      haptic: true,
      onTap: onTap,
      child: GrassBagFresnelGlassSurface(
        borderRadius: 10,
        innerWell: !selected,
        elevated: selected,
        interactive: true,
        tintColor: selected ? t.primarySoft : null,
        padding: const EdgeInsets.symmetric(vertical: 7),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: selected ? t.primary : t.text2,
          ),
        ),
      ),
    );
  }
}

class _OsChip extends StatelessWidget {
  const _OsChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagSpringTap(
      enablePointerGlow: false,
      haptic: true,
      onTap: onTap,
      child: GrassBagFresnelGlassSurface(
        borderRadius: 9,
        innerWell: !selected,
        interactive: true,
        tintColor: selected ? t.primary : null,
        padding: const EdgeInsets.symmetric(vertical: 7.5),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: selected ? t.onPrimary : t.text2,
          ),
        ),
      ),
    );
  }
}

class _CompactStepRow extends StatelessWidget {
  const _CompactStepRow({required this.step, required this.text});

  final String step;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: GrassBagFresnelGlassSurface(
            isCircle: true,
            innerWell: true,
            tintColor: t.primarySoft,
            width: 18,
            height: 18,
            alignment: Alignment.center,
            child: Text(
              step,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: t.primary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 11.5, height: 1.42, color: t.text2),
          ),
        ),
      ],
    );
  }
}

class _CommandCopyRow extends StatelessWidget {
  const _CommandCopyRow({
    required this.label,
    required this.command,
    required this.onCopy,
  });

  final String label;
  final String command;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Tooltip(
      message: '点击复制命令',
      child: GrassBagSpringTap(
        enablePointerGlow: false,
        haptic: true,
        pressedScale: 0.985,
        onTap: () => onCopy(command),
        child: GrassBagFresnelGlassSurface(
          borderRadius: 12,
          innerWell: true,
          interactive: true,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: TextStyle(fontSize: 10.5, color: t.text3)),
                    const SizedBox(height: 2),
                    Text(
                      command,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.35,
                        color: t.text,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GrassBagFresnelGlassSurface(
                borderRadius: 10,
                innerWell: true,
                tintColor: t.primarySoft,
                width: 32,
                height: 32,
                alignment: Alignment.center,
                child: Icon(CupertinoIcons.doc_on_doc, size: 14, color: t.primary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
