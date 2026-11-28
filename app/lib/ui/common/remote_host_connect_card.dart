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

/// Unified "连接电脑" pairing flow shared by Onboarding, Top Bar, Settings, and Deep Links:
/// - First screen asks what the user has right now:
///   1) Scan QR code on computer (when camera available)
///   2) Paste pairing / `dsh web` link (always visible)
///   3) Prepare computer guide -> choose "我用 DSH Desktop" or "我已运行 dsh web"
/// - Stays in place after scanning / pasting, displaying target computer name and live progress:
///   `正在连接 → 正在授权 → 正在打开会话` with Cancel support.
/// - Commits host switch ONLY after both real-time WebSocket handshake and sessions API pass,
///   then presents "打开会话" as the primary action.
/// - Preserves original session, drafts, and pairing input on failure, highlighting ONE
///   actionable recovery CTA plus collapsible technical details.
class RemoteHostConnectCard extends ConsumerStatefulWidget {
  const RemoteHostConnectCard({
    super.key,
    this.onConnectedHost,
    this.connectImmediately = true,
    this.showHeader = true,
    this.initiallyShowGuide = false,
    this.autoScanLan = true,
    this.autoLaunchScanner = false,
    this.confirmBeforeConnect = false,
    this.embeddedInSheet = false,
    this.initialInput,
    this.initialToken,
    this.initialPairCode,
    this.initialName,
    this.initialAllowBadCerts = false,
    this.initialDiagnosis,
    this.onDraftChanged,
    this.onDiagnosisChanged,
  });

  /// Official 1-line CLI command installing `dsh-gbridge.tgz` via China GitHub mirror.
  static const String acceleratedInstallCommand =
      'dsh plugin add $kOfficialGbridgeAcceleratedUrl';

  /// Short guide URL meant to be opened on a computer browser where copy buttons live.
  static const String desktopShortGuideUrl = kOfficialDesktopPairingGuideUrl;

  /// Shared Desktop GUI 1-tap AI prompt used across pairing help, Auth Sheet, and Host Detail.
  static const String desktopGuiPrompt = '''请帮我安装并启用 GrassBag 官方连接助手插件（零端口冲突、无需另开第二套 dsh web 服务，安装后会在桌面端左侧出现「手机连接」二维码面板）：
1. 请直接使用当前 DeepSeek Harness 的插件管理能力（或本机 dsh CLI）安装官方加速包：
   $kOfficialGbridgeAcceleratedUrl
   （若主加速源下载失败，可自动改用备用源 $kOfficialGbridgeDirectUrl ）
2. 插件启用后会自动复用当前运行的 DSH 实例（桌面端自动在 3081+ 零冲突端口开启局域网桥接，dsh web 直接复用原端口），无需额外启动新的 dsh web 进程；
3. 安装完成后，请在左侧栏点开「手机连接」显示配对二维码，或把配对链接发给我即可用手机 GrassBag 扫码连接。''';

  /// Called when the user confirms opening the newly connected host (or immediately when
  /// [connectImmediately] is false and host is saved).
  final ValueChanged<ManagedHost>? onConnectedHost;

  /// If true, switches to the newly verified host upon real-time + sessions verification.
  final bool connectImmediately;

  /// Whether to render the card's title row ("连接电脑").
  final bool showHeader;

  /// Whether to expand the preparation guide initially.
  final bool initiallyShowGuide;

  /// Whether to automatically trigger a lightweight background LAN/mDNS scan on native platforms.
  final bool autoScanLan;

  /// When true, opens the QR scanner immediately after mount while keeping this pairing sheet open.
  final bool autoLaunchScanner;

  /// When true (e.g. opened from a `grassbag://pair?...` deep link), displays target computer
  /// confirmation first before starting the connection.
  final bool confirmBeforeConnect;

  /// When rendered inside a modal sheet, omits the redundant outer GrassBagCard chrome.
  final bool embeddedInSheet;

  /// Optional prefilled URL/token/pair string.
  final String? initialInput;

  /// Optional prefilled token/pairCode/name/TLS flags preserved across step transitions.
  final String? initialToken;
  final String? initialPairCode;
  final String? initialName;
  final bool initialAllowBadCerts;

  /// Optional prefilled diagnosis from an earlier attempt.
  final RemoteHostDiagnosis? initialDiagnosis;

  /// Notifies parent when the user edits address/token/name/TLS flags so state survives step switches.
  final void Function({
    required String address,
    required String token,
    required String name,
    required bool allowBadCerts,
  })? onDraftChanged;

  /// Notifies parent whenever diagnosis updates or clears.
  final ValueChanged<RemoteHostDiagnosis?>? onDiagnosisChanged;

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
  int _guideTab = 0; // 0: 我用 DSH Desktop, 1: 我已运行 dsh web
  bool _showCliCommands = false;
  bool _showDesktopAdvancedCopy = false;
  int _cliOsTab = 0; // 0: macOS, 1: Windows, 2: Linux
  bool _allowBadCerts = false;
  bool _allowInsecurePublicHttp = false;
  bool _obscureToken = true;
  bool _explicitEmptyScan = false;
  bool _awaitingDeepLinkConfirm = false;
  bool _showTechnicalDetail = false;
  String? _pairCode;
  String? _capturedCookie;
  String? _selectedLanAddr;
  RemoteHostDiagnosis? _diagnosis;

  PairingStage _stage = PairingStage.idle;
  String? _targetComputerName;
  ManagedHost? _verifiedHost;
  int? _verifiedSessionCount;
  int _connectRunGen = 0;

  bool get _isPairingInProgress =>
      _stage == PairingStage.connecting ||
      _stage == PairingStage.authorizing ||
      _stage == PairingStage.openingSession;

  bool get _supportsInAppWebLogin =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _supportsQrScan =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  bool get _supportsLanDiscovery {
    if (kIsWeb) return false;
    final isLiveApp = WidgetsBinding.instance is WidgetsFlutterBinding;
    return GrassBagNativeBridge.instance.isPluginVerified ||
        (GrassBagNativeBridge.instance.isAndroidNative && isLiveApp);
  }

  void _emitDraftChanged() {
    widget.onDraftChanged?.call(
      address: _addrCtrl.text,
      token: _tokenCtrl.text,
      name: _nameCtrl.text,
      allowBadCerts: _allowBadCerts,
    );
  }

  void _setDiagnosisState(RemoteHostDiagnosis? diag) {
    _diagnosis = diag;
    _showTechnicalDetail = false;
    widget.onDiagnosisChanged?.call(diag);
  }

  @override
  void initState() {
    super.initState();
    _showGuide = widget.initiallyShowGuide;
    _allowBadCerts = widget.initialAllowBadCerts;
    if (widget.initialInput != null && widget.initialInput!.trim().isNotEmpty) {
      final parsed = parseRemoteHostInput(widget.initialInput!.trim());
      if (parsed != null) {
        _addrCtrl.text = parsed.address;
        if (parsed.token != null && parsed.token!.isNotEmpty) {
          _tokenCtrl.text = parsed.token!;
        }
        if (parsed.pairCode != null && parsed.pairCode!.isNotEmpty) {
          _pairCode = parsed.pairCode;
        }
        if (parsed.suggestedName != null && parsed.suggestedName!.isNotEmpty) {
          _nameCtrl.text = parsed.suggestedName!;
          _targetComputerName = parsed.suggestedName;
        }
      } else {
        _addrCtrl.text = widget.initialInput!.trim();
      }
    }
    if (widget.initialToken != null &&
        widget.initialToken!.trim().isNotEmpty &&
        _tokenCtrl.text.trim().isEmpty) {
      _tokenCtrl.text = widget.initialToken!.trim();
    }
    if (widget.initialPairCode != null &&
        widget.initialPairCode!.trim().isNotEmpty &&
        (_pairCode == null || _pairCode!.isEmpty)) {
      _pairCode = widget.initialPairCode!.trim();
    }
    if (widget.initialName != null &&
        widget.initialName!.trim().isNotEmpty &&
        _nameCtrl.text.trim().isEmpty) {
      _nameCtrl.text = widget.initialName!.trim();
      _targetComputerName = widget.initialName!.trim();
    }
    if (widget.confirmBeforeConnect && _addrCtrl.text.trim().isNotEmpty) {
      _awaitingDeepLinkConfirm = true;
    } else if (_tokenCtrl.text.trim().isNotEmpty ||
        _nameCtrl.text.trim().isNotEmpty ||
        _allowBadCerts) {
      _showAdvanced = true;
    }
    if (widget.initialDiagnosis != null) {
      _diagnosis = widget.initialDiagnosis;
      _stage = widget.initialDiagnosis!.canConnectNow
          ? PairingStage.idle
          : PairingStage.failed;
    }
    if (widget.autoScanLan && _supportsLanDiscovery && !widget.confirmBeforeConnect) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final state = ref.read(appProvider);
        if (!state.scanningLan && state.discoveredLanHosts.isEmpty) {
          unawaited(ref.read(appProvider.notifier).scanLanForHosts(silent: true));
        }
      });
    }
    if (widget.autoLaunchScanner && _supportsQrScan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_scanQrCode());
        }
      });
    }
  }

  @override
  void dispose() {
    _connectRunGen++;
    _addrCtrl.dispose();
    _nameCtrl.dispose();
    _tokenCtrl.dispose();
    _addrFocus.dispose();
    _tokenFocus.dispose();
    super.dispose();
  }

  Future<void> _scanQrCode() async {
    if (_isPairingInProgress) return;
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
      setState(() {
        _capturedCookie = null;
        _pairCode = null;
        _awaitingDeepLinkConfirm = false;
        _verifiedHost = null;
        _stage = PairingStage.failed;
        _setDiagnosisState(const RemoteHostDiagnosis(
          kind: RemoteDiagnosisKind.invalidAddress,
          title: '未识别到有效连接链接',
          message: '请扫描电脑端「手机连接」二维码，或粘贴完整的 `http://.../?token=...` 连接链接。',
        ));
      });
      _emitDraftChanged();
      return;
    }
    final addrChanged = _addrCtrl.text.trim() != parsed.address;
    _addrCtrl.text = parsed.address;
    if (parsed.token != null && parsed.token!.isNotEmpty) {
      _tokenCtrl.text = parsed.token!;
    } else if (addrChanged) {
      _tokenCtrl.clear();
    }
    _pairCode = parsed.pairCode;
    if (parsed.suggestedName != null && parsed.suggestedName!.isNotEmpty) {
      if (addrChanged || _nameCtrl.text.trim().isEmpty) {
        _nameCtrl.text = parsed.suggestedName!;
      }
      _targetComputerName = parsed.suggestedName;
    } else {
      _targetComputerName = parsed.address;
    }
    setState(() {
      if (addrChanged) _capturedCookie = null;
      _selectedLanAddr = null;
      _awaitingDeepLinkConfirm = false;
      _verifiedHost = null;
      _verifiedSessionCount = null;
      _stage = PairingStage.idle;
      _setDiagnosisState(null);
    });
    _emitDraftChanged();
    await _connectNow();
  }

  Future<void> _pasteFromClipboard() async {
    if (_isPairingInProgress) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      ref.read(appProvider.notifier).showToast('剪贴板为空，请先在电脑端复制配对链接或启动链接', tone: ToastTone.info);
      return;
    }
    final parsed = parseRemoteHostInput(text);
    final looksBareToken = _addrCtrl.text.trim().isNotEmpty &&
        parsed == null &&
        !text.contains('://') &&
        !text.contains('/') &&
        RegExp(r'^[A-Za-z0-9._~+/=-]{8,}$').hasMatch(text);
    if (looksBareToken) {
      _tokenCtrl.text = text;
      setState(() {
        _showAdvanced = true;
        _awaitingDeepLinkConfirm = false;
        _stage = PairingStage.idle;
        _setDiagnosisState(null);
      });
      _emitDraftChanged();
      await _connectNow();
      return;
    }
    await _applyParsedRemoteText(text, sourceLabel: '剪贴板');
  }

  void _cancelPairing() {
    if (!_isPairingInProgress) return;
    _connectRunGen++;
    setState(() {
      _stage = PairingStage.idle;
      _setDiagnosisState(null);
    });
    ref.read(appProvider.notifier).showToast('已取消连接，原对话未受影响', tone: ToastTone.info);
  }

  Future<void> _openInAppWebLogin() async {
    final parsed = parseRemoteHostInput(_addrCtrl.text.trim());
    if (parsed == null) {
      ref.read(appProvider.notifier).showToast('请先填写或粘贴电脑连接链接', tone: ToastTone.warn);
      return;
    }
    final displayName =
        _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : (parsed.suggestedName ?? '远程电脑');
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
    await _connectNow();
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
    if (diag.extractedPairCode != null && diag.extractedPairCode!.isNotEmpty) {
      _pairCode = diag.extractedPairCode;
    }
    if (diag.capturedCookie != null && diag.capturedCookie!.isNotEmpty) {
      _capturedCookie = diag.capturedCookie;
    }
    if (diag.hostName != null && diag.hostName!.trim().isNotEmpty) {
      _targetComputerName = diag.hostName!.trim();
    }
    _setDiagnosisState(diag);
    _emitDraftChanged();
  }

  Future<void> _connectNow() async {
    if (_isPairingInProgress) return;
    final raw = _addrCtrl.text.trim();
    if (raw.isEmpty) {
      _addrFocus.requestFocus();
      ref.read(appProvider.notifier).showToast('请先扫码，或粘贴电脑上的连接链接', tone: ToastTone.warn);
      return;
    }
    final parsed = parseRemoteHostInput(raw);
    final initialComputer = _nameCtrl.text.trim().isNotEmpty
        ? _nameCtrl.text.trim()
        : (parsed?.suggestedName ?? raw);
    final myGen = ++_connectRunGen;

    setState(() {
      _awaitingDeepLinkConfirm = false;
      _verifiedHost = null;
      _verifiedSessionCount = null;
      _targetComputerName = initialComputer;
      _stage = PairingStage.connecting;
      _setDiagnosisState(null);
    });

    final ctrl = ref.read(appProvider.notifier);
    final tokenText = _tokenCtrl.text.trim();

    final outcome = await ctrl.connectRemoteInput(
      raw,
      name: _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
      token: tokenText.isEmpty ? null : tokenText,
      pairCode: _pairCode,
      cookie: _capturedCookie,
      allowBadCertificates: _allowBadCerts,
      allowInsecurePublicHttp: _allowInsecurePublicHttp,
      switchOnSuccess: widget.connectImmediately,
      isCancelled: () => !mounted || _connectRunGen != myGen,
      onStageChanged: (nextStage, {String? computerName}) {
        if (!mounted || _connectRunGen != myGen) return;
        setState(() {
          _stage = nextStage;
          if (computerName != null && computerName.trim().isNotEmpty) {
            _targetComputerName = computerName.trim();
          }
        });
      },
    );

    if (!mounted || _connectRunGen != myGen) return;
    if (outcome.cancelled) {
      setState(() {
        _stage = PairingStage.idle;
      });
      return;
    }

    setState(() {
      _applyDiagnosisFields(outcome.diagnosis, raw);
      if (outcome.connected && outcome.host != null) {
        _verifiedHost = outcome.host;
        _verifiedSessionCount = outcome.sessionCount;
        _targetComputerName = outcome.host!.name;
        _stage = PairingStage.ready;
      } else {
        _stage = PairingStage.failed;
        if (outcome.diagnosis.kind == RemoteDiagnosisKind.needsAuth) {
          _showAdvanced = true;
        }
      }
    });
  }

  Future<void> _onTapLanHost(DiscoveredLanHost h) async {
    if (_isPairingInProgress) return;
    final changed = _addrCtrl.text.trim() != h.address;
    _addrCtrl.text = h.address;
    _nameCtrl.text = h.name;
    _targetComputerName = h.name;
    setState(() {
      if (changed) {
        _capturedCookie = null;
        _tokenCtrl.clear();
        _pairCode = null;
      }
      _selectedLanAddr = h.address;
      _awaitingDeepLinkConfirm = false;
      _verifiedHost = null;
      _stage = PairingStage.idle;
      _setDiagnosisState(null);
    });
    _emitDraftChanged();
    await _connectNow();
  }

  void _focusReplaceLink() {
    setState(() {
      _stage = PairingStage.idle;
      _setDiagnosisState(null);
    });
    _addrFocus.requestFocus();
    _addrCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _addrCtrl.text.length,
    );
  }

  void _copyText(String content, String toastMsg) {
    Clipboard.setData(ClipboardData(text: content));
    ref.read(appProvider.notifier).showToast(toastMsg, tone: ToastTone.ok);
  }

  (String label, String cmd) get _currentCliCommand => switch (_cliOsTab) {
        0 => (
            'macOS 终端（自动绑定当前网卡 IP）',
            r'dsh web --host $(ipconfig getifaddr $(route -n get default 2>/dev/null | awk "/interface:/{print \$2}" | head -n1) 2>/dev/null || ipconfig getifaddr en0) --no-open',
          ),
        1 => (
            'Windows PowerShell（自动绑定当前网卡 IP）',
            r'$ip=(Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1 | Get-NetIPAddress -AddressFamily IPv4).IPAddress; dsh web --host $ip --no-open',
          ),
        _ => (
            'Linux 终端（自动绑定当前网卡 IP）',
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
                      '连接电脑',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '按你手里已有的信息扫码或粘贴链接，确认可打开会话后再切换',
                      style: TextStyle(fontSize: 11.5, color: t.text3),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],

        // -------------------------------------------------------------------
        // A. Deep-link confirmation gate ("先展示目标电脑再继续")
        // -------------------------------------------------------------------
        if (_awaitingDeepLinkConfirm && _stage == PairingStage.idle) ...[
          _DeepLinkConfirmCard(
            computerName: _targetComputerName ?? _addrCtrl.text.trim(),
            address: _addrCtrl.text.trim(),
            tier: slice.glassTier,
            onConfirm: _connectNow,
            onCancel: () {
              setState(() {
                _awaitingDeepLinkConfirm = false;
              });
            },
          ),
          const SizedBox(height: 10),
        ],

        // -------------------------------------------------------------------
        // B. Live in-place pairing progress stepper (stays on page after scan!)
        // -------------------------------------------------------------------
        if (_isPairingInProgress) ...[
          _PairingProgressCard(
            computerName: _targetComputerName ?? _addrCtrl.text.trim(),
            address: _addrCtrl.text.trim(),
            stage: _stage,
            tier: slice.glassTier,
            onCancel: _cancelPairing,
          ),
        ]
        // -------------------------------------------------------------------
        // C. Verified Ready state — ONLY after WS handshake + sessions API pass
        // -------------------------------------------------------------------
        else if (_stage == PairingStage.ready && _verifiedHost != null) ...[
          _PairingReadyCard(
            host: _verifiedHost!,
            sessionCount: _verifiedSessionCount,
            message: diag?.message ?? '实时连接与会话列表已就绪，可以开始对话。',
            tier: slice.glassTier,
            onOpenSession: () {
              final host = _verifiedHost!;
              widget.onConnectedHost?.call(host);
            },
          ),
        ]
        // -------------------------------------------------------------------
        // D. Normal / Recovery first-screen pairing actions
        // -------------------------------------------------------------------
        else ...[
          // Action 1: Scan QR code on computer (mobile / macOS camera devices)
          if (_supportsQrScan && diag == null) ...[
            GrassBagPrimaryGlassButton(
              key: const ValueKey('pair-scan-qr-btn'),
              label: '扫电脑上的二维码',
              icon: CupertinoIcons.qrcode_viewfinder,
              height: 44,
              tier: slice.glassTier,
              insideGlass: true,
              onTap: _scanQrCode,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, bottom: 10),
              child: Text(
                '电脑已经显示二维码时直接扫，扫完后在此页等待连接完成',
                style: TextStyle(fontSize: 11.5, color: t.text3),
              ),
            ),
          ],

          // Action 2: Always-visible Paste Link bar & smart input
          GrassBagTextField(
            key: const ValueKey('pair-link-input'),
            controller: _addrCtrl,
            focusNode: _addrFocus,
            placeholder: '粘贴电脑配对链接或 dsh web 启动链接',
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
                      _pairCode = null;
                      _capturedCookie = null;
                      _selectedLanAddr = null;
                      setState(() {
                        _stage = PairingStage.idle;
                        _setDiagnosisState(null);
                      });
                      _emitDraftChanged();
                    },
                    child: Tooltip(
                      message: '清空链接',
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
                    key: const ValueKey('pair-paste-link-btn'),
                    enablePointerGlow: false,
                    haptic: true,
                    onTap: _pasteFromClipboard,
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
                            '粘贴连接链接',
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
            onChanged: (_) {
              _emitDraftChanged();
              if (_diagnosis != null ||
                  _capturedCookie != null ||
                  _selectedLanAddr != null ||
                  _pairCode != null) {
                setState(() {
                  _capturedCookie = null;
                  _selectedLanAddr = null;
                  _pairCode = null;
                  _stage = PairingStage.idle;
                  _setDiagnosisState(null);
                });
              } else {
                setState(() {});
              }
            },
            onSubmitted: (_) => _connectNow(),
          ),

          // Primary Connect CTA when user typed/pasted a link (and no failure banner overriding primary CTA)
          if (diag == null && _addrCtrl.text.trim().isNotEmpty && !_awaitingDeepLinkConfirm) ...[
            const SizedBox(height: 10),
            GrassBagPrimaryGlassButton(
              key: const ValueKey('pair-connect-submit-btn'),
              label: '连接这台电脑',
              icon: CupertinoIcons.arrow_right_circle_fill,
              height: 44,
              tier: slice.glassTier,
              insideGlass: true,
              onTap: _connectNow,
            ),
          ] else if (diag == null && !_supportsQrScan && !_awaitingDeepLinkConfirm) ...[
            const SizedBox(height: 10),
            GrassBagPrimaryGlassButton(
              key: const ValueKey('pair-paste-primary-btn'),
              label: '粘贴连接链接并连接',
              icon: CupertinoIcons.doc_on_clipboard,
              height: 44,
              tier: slice.glassTier,
              insideGlass: true,
              onTap: _pasteFromClipboard,
            ),
          ],

          // Live Failure Recovery Banner (single primary actionable CTA + collapsible tech details)
          if (diag != null && _stage == PairingStage.failed) ...[
            const SizedBox(height: 10),
            GrassBagStatusBanner(
              key: const ValueKey('pair-failure-banner'),
              tone: diag.kind == RemoteDiagnosisKind.selfDevice ||
                      diag.needsWebOrTokenAuth
                  ? GrassBagBannerTone.warn
                  : GrassBagBannerTone.error,
              icon: diag.needsWebOrTokenAuth
                  ? CupertinoIcons.lock_shield_fill
                  : (diag.kind == RemoteDiagnosisKind.selfDevice
                      ? CupertinoIcons.info_circle_fill
                      : CupertinoIcons.exclamationmark_triangle_fill),
              title: diag.title,
              message: diag.message,
              padding: const EdgeInsets.all(12),
              borderRadius: 16,
              action: _buildSingleCtaFailureActions(diag, slice.glassTier),
            ),
          ],

          // Nearby Devices — ONLY displayed on native platforms when scanning OR results exist
          // (or when an explicit rescan returned empty, highlighting "扫码或粘贴链接")
          if (_supportsLanDiscovery &&
              (slice.discoveredLanHosts.isNotEmpty ||
                  slice.scanningLan ||
                  _explicitEmptyScan)) ...[
            const SizedBox(height: 11),
            _NearbyDevicesSection(
              scanning: slice.scanningLan,
              hosts: slice.discoveredLanHosts,
              selectedAddr: _selectedLanAddr,
              tier: slice.glassTier,
              onRescan: () {
                setState(() => _explicitEmptyScan = true);
                ctrl.scanLanForHosts(silent: true);
              },
              onSelectHost: _onTapLanHost,
              onScanOrPaste: _supportsQrScan ? _scanQrCode : _pasteFromClipboard,
            ),
          ],

          // Action 3: "电脑上还没有链接？" + Collapsible Manual / Advanced Options row
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  key: const ValueKey('pair-prepare-guide-btn'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _showGuide = !_showGuide),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          CupertinoIcons.desktopcomputer,
                          size: 13.5,
                          color: t.primary,
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            _showGuide ? '收起电脑准备说明' : '电脑上还没有链接？',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: t.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              GestureDetector(
                key: const ValueKey('pair-advanced-toggle'),
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
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
                      Text(
                        _tokenCtrl.text.trim().isNotEmpty ? '高级选项（已填令牌）' : '高级选项',
                        style: TextStyle(fontSize: 12, color: t.text3),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // Collapsible Manual / Advanced Options (Token, Name, Self-signed TLS, Manual LAN scan)
          if (_showAdvanced)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GrassBagTextField(
                    controller: _tokenCtrl,
                    focusNode: _tokenFocus,
                    placeholder: '访问令牌 Token（选填，二维码或完整链接已自动包含）',
                    insideGlass: true,
                    monospace: true,
                    obscureText: _obscureToken,
                    textInputAction: TextInputAction.done,
                    fontSize: 13,
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                    onChanged: (_) {
                      _emitDraftChanged();
                      if (_diagnosis != null) {
                        setState(() {
                          _stage = PairingStage.idle;
                          _setDiagnosisState(null);
                        });
                      }
                    },
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
                    placeholder: '电脑备注名（选填，例如：办公室 Mac）',
                    insideGlass: true,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => _emitDraftChanged(),
                    onSubmitted: (_) => _connectNow(),
                    fontSize: 13,
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() {
                        _allowBadCerts = !_allowBadCerts;
                        _setDiagnosisState(null);
                      });
                      _emitDraftChanged();
                    },
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
                            onChanged: (v) {
                              setState(() {
                                _allowBadCerts = v;
                                _setDiagnosisState(null);
                              });
                              _emitDraftChanged();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_supportsLanDiscovery &&
                      slice.discoveredLanHosts.isEmpty &&
                      !slice.scanningLan) ...[
                    const SizedBox(height: 6),
                    GrassBagSecondaryGlassButton(
                      label: '扫描同局域网附近电脑',
                      icon: CupertinoIcons.antenna_radiowaves_left_right,
                      height: 36,
                      tier: slice.glassTier,
                      insideGlass: true,
                      onTap: () {
                        setState(() => _explicitEmptyScan = true);
                        ctrl.scanLanForHosts(silent: true);
                      },
                    ),
                  ],
                ],
              ),
            ),

          // Preparation Guide: first choose "我用 DSH Desktop" or "我已运行 dsh web"
          if (_showGuide)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _buildPreparationGuide(t, slice.glassTier),
            ),
        ],
      ],
    );

    if (widget.embeddedInSheet) return body;
    return GrassBagCard(
      borderRadius: 24,
      padding: const EdgeInsets.all(15),
      child: body,
    );
  }

  Widget _buildPreparationGuide(GrassBagTokens t, GrassBagGlassTier tier) {
    return GrassBagSheetSection(
      borderRadius: 16,
      padding: const EdgeInsets.all(12),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '你电脑上现在打开的是哪一种？',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: t.text,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _GuideSegmentPill(
                    key: const ValueKey('pair-guide-desktop-tab'),
                    label: '我用 DSH Desktop',
                    selected: _guideTab == 0,
                    onTap: () => setState(() => _guideTab = 0),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _GuideSegmentPill(
                    key: const ValueKey('pair-guide-dshweb-tab'),
                    label: '我已运行 dsh web',
                    selected: _guideTab == 1,
                    onTap: () => setState(() => _guideTab = 1),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 11),
            if (_guideTab == 0) ...[
              const _CompactStepRow(
                step: '1',
                text: '已安装助手：在电脑端 DSH Desktop 左侧栏点开「手机连接」，直接扫描屏幕上的二维码。',
              ),
              const SizedBox(height: 8),
              const _CompactStepRow(
                step: '2',
                text: '还没装助手：在电脑浏览器打开简短指南，按「插件 → 添加插件 → 手机连接」三步完成（复制按钮都在电脑页上）。',
              ),
              const SizedBox(height: 10),
              GrassBagSecondaryGlassButton(
                key: const ValueKey('pair-copy-desktop-guide-btn'),
                label: '复制电脑端操作指南链接',
                icon: CupertinoIcons.compass,
                height: 38,
                tier: tier,
                insideGlass: true,
                accentForeground: true,
                onTap: () => _copyText(
                  RemoteHostConnectCard.desktopShortGuideUrl,
                  '已复制指南链接，发到电脑浏览器打开即可一键复制安装',
                ),
              ),
              const SizedBox(height: 6),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _showDesktopAdvancedCopy = !_showDesktopAdvancedCopy),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _showDesktopAdvancedCopy
                            ? CupertinoIcons.chevron_down
                            : CupertinoIcons.chevron_right,
                        size: 11,
                        color: t.text3,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '或者直接复制插件包地址 / AI 安装指令',
                        style: TextStyle(fontSize: 11.5, color: t.text3),
                      ),
                    ],
                  ),
                ),
              ),
              if (_showDesktopAdvancedCopy) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: '复制插件包地址',
                        icon: CupertinoIcons.link,
                        height: 34,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tier: tier,
                        insideGlass: true,
                        onTap: () => _copyText(
                          kOfficialGbridgeAcceleratedUrl,
                          '已复制插件包 .tgz 地址',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: '复制 AI 指令',
                        icon: CupertinoIcons.sparkles,
                        height: 34,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tier: tier,
                        insideGlass: true,
                        onTap: () => _copyText(
                          RemoteHostConnectCard.desktopGuiPrompt,
                          '已复制 AI 安装指令',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ] else ...[
              const _CompactStepRow(
                step: '1',
                text: '直接找到电脑终端打印的 `http://<局域网IP>:<端口>/?token=...` 启动链接（免装任何插件）。',
              ),
              const SizedBox(height: 7),
              const _CompactStepRow(
                step: '2',
                text: '把链接发到手机，点上方「粘贴连接链接」即可直接打开电脑会话（自动保持 30 天登录态）。',
              ),
              const SizedBox(height: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _showCliCommands = !_showCliCommands),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _showCliCommands
                            ? CupertinoIcons.chevron_down
                            : CupertinoIcons.chevron_right,
                        size: 11,
                        color: t.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _showCliCommands ? '收起局域网启动命令' : '链接是 127.0.0.1？查看局域网启动命令',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: t.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_showCliCommands) ...[
                const SizedBox(height: 8),
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
                  onCopy: (cmd) => _copyText(cmd, '已复制启动命令到剪贴板'),
                ),
              ],
            ],
          ],
        ),
      ],
    );
  }

  /// Renders ONE clear primary recovery CTA tailored to the exact failure cause,
  /// plus optional collapsible technical details so raw errors never confuse users.
  Widget _buildSingleCtaFailureActions(RemoteHostDiagnosis diag, GrassBagGlassTier tier) {
    final t = GrassBagTokens.of(context);
    final rawTech = diag.technicalDetail?.trim();
    final hasTechDetail =
        rawTech != null && rawTech.isNotEmpty && rawTech != diag.message.trim();

    late final Widget primaryCta;
    Widget? secondaryRow;

    switch (diag.kind) {
      case RemoteDiagnosisKind.selfDevice:
        primaryCta = GrassBagPrimaryGlassButton(
          key: const ValueKey('pair-failure-primary-cta'),
          label: '换成电脑上的连接链接',
          icon: CupertinoIcons.arrow_2_squarepath,
          height: 38,
          tier: tier,
          insideGlass: true,
          onTap: _focusReplaceLink,
        );
        secondaryRow = Row(
          children: [
            if (_supportsQrScan) ...[
              Expanded(
                child: GrassBagSecondaryGlassButton(
                  label: '扫电脑二维码',
                  icon: CupertinoIcons.qrcode_viewfinder,
                  height: 34,
                  tier: tier,
                  insideGlass: true,
                  onTap: _scanQrCode,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '查看电脑准备说明',
                icon: CupertinoIcons.question_circle,
                height: 34,
                tier: tier,
                insideGlass: true,
                onTap: () => setState(() => _showGuide = true),
              ),
            ),
          ],
        );
      case RemoteDiagnosisKind.pairingCodeExpired:
        primaryCta = GrassBagPrimaryGlassButton(
          key: const ValueKey('pair-failure-primary-cta'),
          label: _supportsQrScan ? '扫描新二维码' : '粘贴新连接链接',
          icon: _supportsQrScan
              ? CupertinoIcons.qrcode_viewfinder
              : CupertinoIcons.doc_on_clipboard,
          height: 38,
          tier: tier,
          insideGlass: true,
          onTap: _supportsQrScan ? _scanQrCode : _pasteFromClipboard,
        );
        if (_supportsQrScan) {
          secondaryRow = GrassBagSecondaryGlassButton(
            label: '改为粘贴最新链接',
            icon: CupertinoIcons.doc_on_clipboard,
            height: 34,
            tier: tier,
            insideGlass: true,
            onTap: _pasteFromClipboard,
          );
        }
      case RemoteDiagnosisKind.realtimeFailed:
        primaryCta = GrassBagPrimaryGlassButton(
          key: const ValueKey('pair-failure-primary-cta'),
          label: '重新连接',
          icon: CupertinoIcons.refresh,
          height: 38,
          tier: tier,
          insideGlass: true,
          onTap: _connectNow,
        );
        secondaryRow = GrassBagSecondaryGlassButton(
          label: '修改连接链接',
          icon: CupertinoIcons.pencil,
          height: 34,
          tier: tier,
          insideGlass: true,
          onTap: _focusReplaceLink,
        );
      case RemoteDiagnosisKind.htmlLoginPage:
        primaryCta = GrassBagPrimaryGlassButton(
          key: const ValueKey('pair-failure-primary-cta'),
          label: _supportsInAppWebLogin ? '完成网页登录' : '粘贴连接链接',
          icon: _supportsInAppWebLogin
              ? CupertinoIcons.globe
              : CupertinoIcons.doc_on_clipboard,
          height: 38,
          tier: tier,
          insideGlass: true,
          onTap: _supportsInAppWebLogin ? _openInAppWebLogin : _pasteFromClipboard,
        );
      case RemoteDiagnosisKind.needsAuth:
        primaryCta = GrassBagPrimaryGlassButton(
          key: const ValueKey('pair-failure-primary-cta'),
          label: _tokenCtrl.text.trim().isNotEmpty
              ? '重新连接'
              : (_supportsQrScan ? '扫描新二维码' : '粘贴含授权的连接链接'),
          icon: _tokenCtrl.text.trim().isNotEmpty
              ? CupertinoIcons.refresh
              : (_supportsQrScan
                  ? CupertinoIcons.qrcode_viewfinder
                  : CupertinoIcons.doc_on_clipboard),
          height: 38,
          tier: tier,
          insideGlass: true,
          onTap: _tokenCtrl.text.trim().isNotEmpty
              ? _connectNow
              : (_supportsQrScan ? _scanQrCode : _pasteFromClipboard),
        );
        secondaryRow = Row(
          children: [
            if (_supportsInAppWebLogin) ...[
              Expanded(
                child: GrassBagSecondaryGlassButton(
                  label: '网页登录',
                  icon: CupertinoIcons.globe,
                  height: 34,
                  tier: tier,
                  insideGlass: true,
                  onTap: _openInAppWebLogin,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '手动填写令牌',
                icon: CupertinoIcons.lock,
                height: 34,
                tier: tier,
                insideGlass: true,
                onTap: () {
                  setState(() => _showAdvanced = true);
                  _tokenFocus.requestFocus();
                },
              ),
            ),
          ],
        );
      case RemoteDiagnosisKind.selfSignedTls:
        primaryCta = GrassBagPrimaryGlassButton(
          key: const ValueKey('pair-failure-primary-cta'),
          label: '信任自签名证书并连接',
          icon: CupertinoIcons.checkmark_shield_fill,
          height: 38,
          tier: tier,
          insideGlass: true,
          onTap: () {
            setState(() => _allowBadCerts = true);
            _connectNow();
          },
        );
      case RemoteDiagnosisKind.insecurePublicHttp:
        primaryCta = GrassBagPrimaryGlassButton(
          key: const ValueKey('pair-failure-primary-cta'),
          label: '改用 HTTPS 连接',
          icon: CupertinoIcons.lock_shield_fill,
          height: 38,
          tier: tier,
          insideGlass: true,
          onTap: () {
            final cur = _addrCtrl.text.trim();
            if (cur.toLowerCase().startsWith('http://')) {
              _addrCtrl.text = 'https://${cur.substring(7)}';
            }
            setState(() => _allowInsecurePublicHttp = false);
            _connectNow();
          },
        );
        secondaryRow = GrassBagSecondaryGlassButton(
          label: '仍以明文继续',
          icon: CupertinoIcons.exclamationmark_triangle,
          height: 34,
          tier: tier,
          insideGlass: true,
          onTap: () {
            setState(() => _allowInsecurePublicHttp = true);
            _connectNow();
          },
        );
      case RemoteDiagnosisKind.invalidAddress:
        primaryCta = GrassBagPrimaryGlassButton(
          key: const ValueKey('pair-failure-primary-cta'),
          label: _supportsQrScan ? '扫码或粘贴链接' : '粘贴连接链接',
          icon: _supportsQrScan
              ? CupertinoIcons.qrcode_viewfinder
              : CupertinoIcons.doc_on_clipboard,
          height: 38,
          tier: tier,
          insideGlass: true,
          onTap: _supportsQrScan ? _scanQrCode : _pasteFromClipboard,
        );
      case RemoteDiagnosisKind.untrustedHost:
      case RemoteDiagnosisKind.unreachable:
      case RemoteDiagnosisKind.readyGbridge:
      case RemoteDiagnosisKind.readyDirect:
        primaryCta = GrassBagPrimaryGlassButton(
          key: const ValueKey('pair-failure-primary-cta'),
          label: diag.isLoopbackTarget ? '换成电脑上的连接链接' : '重新连接',
          icon: diag.isLoopbackTarget
              ? CupertinoIcons.arrow_2_squarepath
              : CupertinoIcons.refresh,
          height: 38,
          tier: tier,
          insideGlass: true,
          onTap: diag.isLoopbackTarget ? _focusReplaceLink : _connectNow,
        );
        secondaryRow = Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '修改地址',
                icon: CupertinoIcons.pencil,
                height: 34,
                tier: tier,
                insideGlass: true,
                onTap: _focusReplaceLink,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: _showGuide ? '已展开说明' : '查看连接引导',
                icon: CupertinoIcons.question_circle,
                height: 34,
                tier: tier,
                insideGlass: true,
                onTap: () => setState(() => _showGuide = true),
              ),
            ),
          ],
        );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (diag.suggestedCommand != null && diag.suggestedCommand!.isNotEmpty) ...[
          _CommandCopyRow(
            label: '在电脑端启动命令',
            command: diag.suggestedCommand!,
            onCopy: (cmd) => _copyText(cmd, '已复制启动命令'),
          ),
          const SizedBox(height: 8),
        ],
        primaryCta,
        if (secondaryRow != null) ...[
          const SizedBox(height: 7),
          secondaryRow,
        ],
        if (hasTechDetail) ...[
          const SizedBox(height: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showTechnicalDetail = !_showTechnicalDetail),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _showTechnicalDetail
                        ? CupertinoIcons.chevron_down
                        : CupertinoIcons.chevron_right,
                    size: 11.5,
                    color: t.text3,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _showTechnicalDetail ? '收起技术详情' : '查看技术详情',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: t.text3),
                  ),
                ],
              ),
            ),
          ),
          if (_showTechnicalDetail) ...[
            const SizedBox(height: 6),
            GrassBagFresnelGlassSurface(
              borderRadius: 10,
              innerWell: true,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Text(
                rawTech,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.35,
                  color: t.text2,
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _DeepLinkConfirmCard extends StatelessWidget {
  const _DeepLinkConfirmCard({
    required this.computerName,
    required this.address,
    required this.tier,
    required this.onConfirm,
    required this.onCancel,
  });

  final String computerName;
  final String address;
  final GrassBagGlassTier tier;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagFresnelGlassSurface(
      key: const ValueKey('pair-deeplink-confirm-card'),
      borderRadius: 18,
      innerWell: true,
      tintColor: t.primarySoft,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GrassBagSquircleIcon(
                icon: CupertinoIcons.desktopcomputer,
                color: t.primary,
                size: 38,
                iconSize: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '确认连接到「$computerName」',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: t.text2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GrassBagPrimaryGlassButton(
            key: const ValueKey('pair-deeplink-confirm-btn'),
            label: '连接「$computerName」',
            icon: CupertinoIcons.link,
            height: 42,
            tier: tier,
            insideGlass: true,
            onTap: onConfirm,
          ),
          const SizedBox(height: 7),
          GrassBagSecondaryGlassButton(
            label: '先不连接，改用其他方式',
            height: 36,
            tier: tier,
            insideGlass: true,
            onTap: onCancel,
          ),
        ],
      ),
    );
  }
}

class _PairingProgressCard extends StatelessWidget {
  const _PairingProgressCard({
    required this.computerName,
    required this.address,
    required this.stage,
    required this.tier,
    required this.onCancel,
  });

  final String computerName;
  final String address;
  final PairingStage stage;
  final GrassBagGlassTier tier;
  final VoidCallback onCancel;

  int get _activeIdx => switch (stage) {
        PairingStage.connecting => 0,
        PairingStage.authorizing => 1,
        PairingStage.openingSession => 2,
        _ => 0,
      };

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    const steps = ['正在连接', '正在授权', '正在打开会话'];
    final activeIdx = _activeIdx;

    return GrassBagFresnelGlassSurface(
      key: const ValueKey('pair-progress-card'),
      borderRadius: 18,
      innerWell: true,
      tintColor: t.primarySoft.withValues(alpha: 0.72),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GrassBagSquircleIcon(
                icon: CupertinoIcons.desktopcomputer,
                color: t.primary,
                size: 38,
                iconSize: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      computerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: t.text3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (int i = 0; i < steps.length; i++) ...[
            if (i > 0) const SizedBox(height: 7),
            Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: Center(
                    child: i < activeIdx
                        ? Icon(CupertinoIcons.checkmark_circle_fill, size: 15, color: t.ok)
                        : (i == activeIdx
                            ? GrassBagActivityIndicator(radius: 6.5, color: t.primary)
                            : Icon(CupertinoIcons.circle, size: 13, color: t.text3)),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  steps[i],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: i == activeIdx ? FontWeight.w600 : FontWeight.w500,
                    color: i < activeIdx
                        ? t.ok
                        : (i == activeIdx ? t.text : t.text3),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          GrassBagSecondaryGlassButton(
            key: const ValueKey('pair-cancel-btn'),
            label: '取消',
            icon: CupertinoIcons.xmark,
            height: 38,
            tier: tier,
            insideGlass: true,
            onTap: onCancel,
          ),
        ],
      ),
    );
  }
}

class _PairingReadyCard extends StatelessWidget {
  const _PairingReadyCard({
    required this.host,
    required this.sessionCount,
    required this.message,
    required this.tier,
    required this.onOpenSession,
  });

  final ManagedHost host;
  final int? sessionCount;
  final String message;
  final GrassBagGlassTier tier;
  final VoidCallback onOpenSession;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagFresnelGlassSurface(
      key: const ValueKey('pair-ready-card'),
      borderRadius: 18,
      innerWell: true,
      tintColor: t.okSoft,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GrassBagSquircleIcon(
                icon: CupertinoIcons.checkmark_alt,
                color: t.ok,
                size: 38,
                iconSize: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '已连接到「${host.name}」',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      message,
                      style: TextStyle(fontSize: 12, height: 1.35, color: t.text2),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GrassBagPrimaryGlassButton(
            key: const ValueKey('pair-open-session-btn'),
            label: '打开会话',
            icon: CupertinoIcons.chat_bubble_2_fill,
            height: 44,
            tier: tier,
            insideGlass: true,
            onTap: onOpenSession,
          ),
        ],
      ),
    );
  }
}

class _NearbyDevicesSection extends StatelessWidget {
  const _NearbyDevicesSection({
    required this.scanning,
    required this.hosts,
    required this.selectedAddr,
    required this.tier,
    required this.onRescan,
    required this.onSelectHost,
    required this.onScanOrPaste,
  });

  final bool scanning;
  final List<DiscoveredLanHost> hosts;
  final String? selectedAddr;
  final GrassBagGlassTier tier;
  final VoidCallback onRescan;
  final ValueChanged<DiscoveredLanHost> onSelectHost;
  final VoidCallback onScanOrPaste;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagFresnelGlassSurface(
      key: const ValueKey('pair-nearby-section'),
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
                  hosts.isNotEmpty
                      ? CupertinoIcons.wifi
                      : CupertinoIcons.antenna_radiowaves_left_right,
                  size: 14,
                  color: hosts.isNotEmpty ? t.ok : t.text3,
                ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  scanning
                      ? '正在查找附近电脑…'
                      : (hosts.isNotEmpty
                          ? '发现 ${hosts.length} 台附近电脑'
                          : '没有发现附近设备'),
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
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Text(
                    scanning ? '查找中' : '重新查找',
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
                onTap: () => onSelectHost(hosts[i]),
              ),
            ],
          ] else if (!scanning) ...[
            const SizedBox(height: 8),
            GrassBagSecondaryGlassButton(
              label: '扫码或粘贴链接',
              icon: CupertinoIcons.qrcode_viewfinder,
              height: 34,
              tier: tier,
              insideGlass: true,
              accentForeground: true,
              onTap: onScanOrPaste,
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
    required this.onTap,
  });

  final DiscoveredLanHost host;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final oneTapReady = !host.requiresAuth && host.isDsh;
    return GrassBagSpringTap(
      enablePointerGlow: false,
      haptic: true,
      onTap: onTap,
      child: GrassBagFresnelGlassSurface(
        borderRadius: 14,
        innerWell: !selected,
        interactive: true,
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
                    '${host.address} · ${host.latencyMs}ms',
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
                oneTapReady ? '连接' : '连接并授权',
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
    super.key,
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
        padding: const EdgeInsets.symmetric(vertical: 7.5),
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
            style: TextStyle(fontSize: 12, height: 1.4, color: t.text2),
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
    return GrassBagFresnelGlassSurface(
      borderRadius: 12,
      innerWell: true,
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: t.text3),
                ),
                const SizedBox(height: 3),
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
          const SizedBox(width: 6),
          Tooltip(
            message: '复制命令',
            child: GrassBagSpringTap(
              enablePointerGlow: false,
              haptic: true,
              onTap: () => onCopy(command),
              child: GrassBagFresnelGlassSurface(
                borderRadius: 9,
                innerWell: true,
                interactive: true,
                tintColor: t.primarySoft,
                width: 32,
                height: 32,
                alignment: Alignment.center,
                child: Icon(CupertinoIcons.doc_on_doc, size: 13.5, color: t.primary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
