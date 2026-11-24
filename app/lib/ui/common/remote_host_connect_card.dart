import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../web/remote_web_login_page.dart';

/// Unified, frictionless Remote DSH Host connector shared by Onboarding, Quick Connect Sheet,
/// and Settings:
/// - Auto-scans LAN on mount with 1-tap connect for discovered open DSH hosts
/// - Smart clipboard paste (recognizes `dsh web: http://.../?token=...`, bare IPs, and dotted/JWT tokens)
/// - Preserves freshly minted 30-day session cookies across diagnose -> connect (never burns a one-time token twice!)
/// - Non-destructive pre-flight diagnosis: never hijacks activeHostId when unreachable or awaiting auth
/// - Single clear primary action (`连接设备`) with clean 2-tab Desktop GUI + OS-switched CLI guide below the fold
class RemoteHostConnectCard extends ConsumerStatefulWidget {
  const RemoteHostConnectCard({
    super.key,
    this.onConnectedHost,
    this.connectImmediately = true,
    this.showHeader = true,
    this.initiallyShowGuide = false,
    this.autoScanLan = true,
  });

  /// Shared Desktop GUI 1-tap AI prompt used across Onboarding, Quick Connect, Auth Sheet, and Host Detail.
  static const String desktopGuiPrompt = '''请帮我开启当前电脑的局域网远程连接，让手机上的 GrassBag 可以连接这台电脑上的 DeepSeek Harness：
1. 先查询本机当前 Wi-Fi / 局域网 IPv4 地址（切勿使用 127.0.0.1 或 0.0.0.0）；
2. 若已安装 dsh-gbridge 桌面桥接插件并监听在 3081 端口，请读取 ~/.dsh/gbridge-lan-token 并直接给出 http://<局域网IP>:3081/?token=<令牌>；
3. 否则请使用本机 dsh 或 DeepSeek Harness 桌面端自带运行时（macOS: "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"，Windows: "%LOCALAPPDATA%\\Programs\\DeepSeek Harness\\resources\\runtime\\cli\\bin\\dsh.cmd"）在后台启动 Web 入口（与桌面端共享全部会话与模型配置）：dsh web --host <局域网IP> --port 3080 --no-open；
4. 启动后把完整可点击的 http://<局域网IP>:<端口>/?token=... 链接直接发给我。''';

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
  String? _capturedCookie;
  String? _selectedLanAddr;
  RemoteHostDiagnosis? _diagnosis;

  bool get _supportsInAppWebLogin =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _showGuide = widget.initiallyShowGuide;
    if (widget.autoScanLan && GrassBagNativeBridge.instance.isPluginVerified) {
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
    if (parsed == null) {
      _addrCtrl.text = text;
      setState(() {
        _capturedCookie = null;
        _diagnosis = null;
      });
      ref.read(appProvider.notifier).showToast('已填入剪贴板内容，请核对地址格式', tone: ToastTone.info);
      return;
    }
    final addrChanged = _addrCtrl.text.trim() != parsed.address;
    _addrCtrl.text = parsed.address;
    if (parsed.token != null && parsed.token!.isNotEmpty) {
      _tokenCtrl.text = parsed.token!;
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
      ref.read(appProvider.notifier).showToast('已识别地址与令牌，正在一键接入…', tone: ToastTone.ok);
      await _connectNow();
    } else {
      ref.read(appProvider.notifier).showToast('已自动识别远程地址，正在检测连通性…', tone: ToastTone.ok);
      await _diagnoseOnly();
    }
  }

  Future<RemoteHostDiagnosis?> _diagnoseOnly() async {
    final raw = _addrCtrl.text.trim();
    if (raw.isEmpty) {
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

    return GrassBagCard(
      borderRadius: 24,
      padding: const EdgeInsets.all(15),
      child: Column(
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
                        '免装插件直连原版 DSH · 认证一次 30 天免填',
                        style: TextStyle(fontSize: 11.5, color: t.text3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
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
            suffix: Padding(
              padding: const EdgeInsets.only(right: 5),
              child: GrassBagSpringTap(
                onTap: () {
                  if (!_connecting) _pasteFromClipboard();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                  decoration: BoxDecoration(
                    color: t.primarySoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
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
            ),
            onChanged: (_) {
              if (_diagnosis != null || _capturedCookie != null || _selectedLanAddr != null) {
                setState(() {
                  _capturedCookie = null;
                  _selectedLanAddr = null;
                  _diagnosis = null;
                });
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

          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _showAdvanced
                ? Padding(
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
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '信任自签名 HTTPS 证书（Tailscale / Caddy / 内网）',
                                style: TextStyle(fontSize: 12, color: t.text2),
                              ),
                            ),
                            GrassBagGlassSwitch(
                              value: _allowBadCerts,
                              tier: slice.glassTier,
                              activeColor: t.primary,
                              onChanged: (v) => setState(() {
                                _allowBadCerts = v;
                                _diagnosis = null;
                              }),
                            ),
                          ],
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
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
          const SizedBox(height: 12),
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

          // Clean 2-tab Setup Guide positioned below the primary CTA so actions stay above the fold
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _showGuide
                ? Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: t.fill1,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: t.sep, width: 0.6),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _GuideSegmentPill(
                                label: '桌面端（免命令）',
                                selected: _guideTab == 0,
                                onTap: () => setState(() => _guideTab = 0),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _GuideSegmentPill(
                                label: '命令行（dsh web）',
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
                            text: '确保手机与电脑在同一个 Wi-Fi / 局域网，打开电脑上的 DeepSeek Harness。',
                          ),
                          const SizedBox(height: 6),
                          const _CompactStepRow(
                            step: '2',
                            text: '点击下方按钮复制一键指令，直接发给电脑端对话框，它会自动开启共享入口。',
                          ),
                          const SizedBox(height: 6),
                          const _CompactStepRow(
                            step: '3',
                            text: '复制电脑回复的 http://... 链接，回到这里点输入框里的「粘贴」即可自动连上。',
                          ),
                          const SizedBox(height: 10),
                          GrassBagSecondaryGlassButton(
                            label: '复制桌面端一键指令',
                            icon: CupertinoIcons.sparkles,
                            height: 36,
                            tier: slice.glassTier,
                            insideGlass: true,
                            accentForeground: true,
                            onTap: () {
                              Clipboard.setData(
                                const ClipboardData(text: RemoteHostConnectCard.desktopGuiPrompt),
                              );
                              ctrl.showToast('已复制一键指令，粘贴发给电脑上的 DeepSeek Harness 即可',
                                  tone: ToastTone.ok);
                            },
                          ),
                          const SizedBox(height: 7),
                          Text(
                            '已在桌面端安装 dsh-gbridge 插件的设备会自动在 :3081 广播，上方雷达将自动发现。',
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
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
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
                label: 'App 内网页登录',
                icon: CupertinoIcons.globe,
                height: 34,
                tier: tier,
                insideGlass: true,
                onTap: _openInAppWebLogin,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '粘贴链接 / Token',
                icon: CupertinoIcons.doc_on_clipboard,
                height: 34,
                tier: tier,
                insideGlass: true,
                onTap: _pasteFromClipboard,
              ),
            ),
          ] else ...[
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: '粘贴链接 / Token',
                icon: CupertinoIcons.doc_on_clipboard,
                height: 34,
                tier: tier,
                insideGlass: true,
                onTap: _pasteFromClipboard,
              ),
            ),
            if (_supportsInAppWebLogin) ...[
              const SizedBox(width: 8),
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
        onTap: () {
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
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: t.fill1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.sep, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (scanning)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CupertinoActivityIndicator(radius: 6.5),
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
                onTap: () {
                  if (!scanning) onRescan();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                  onTap: onOpenGuide,
                  child: Text(
                    '开启引导',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: t.primary,
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
      onTap: () {
        if (!busy) onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? t.primarySoft : t.bgSolid.withValues(alpha: t.isDark ? 0.5 : 0.85),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? t.primary : t.sep,
            width: selected ? 0.9 : 0.6,
          ),
        ),
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: oneTapReady ? t.okSoft : t.primarySoft,
                borderRadius: BorderRadius.circular(8),
              ),
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
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 7),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? t.primarySoft : t.bgSolid.withValues(alpha: t.isDark ? 0.35 : 0.65),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? t.primary.withValues(alpha: 0.5) : t.sep,
            width: 0.65,
          ),
        ),
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
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(vertical: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? t.primary : t.bgSolid.withValues(alpha: t.isDark ? 0.35 : 0.72),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? t.primary : t.sep,
            width: 0.6,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: selected ? const Color(0xFFFFFFFF) : t.text2,
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
        Container(
          width: 18,
          height: 18,
          margin: const EdgeInsets.only(top: 1),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.primarySoft,
            shape: BoxShape.circle,
          ),
          child: Text(
            step,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: t.primary,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: t.bgSolid.withValues(alpha: t.isDark ? 0.58 : 0.88),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: t.sep, width: 0.6),
      ),
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
          GrassBagSpringTap(
            onTap: () => onCopy(command),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: t.primarySoft,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(CupertinoIcons.doc_on_doc, size: 14, color: t.primary),
            ),
          ),
        ],
      ),
    );
  }
}
