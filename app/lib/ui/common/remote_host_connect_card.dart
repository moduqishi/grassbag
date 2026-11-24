import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../web/remote_web_login_page.dart';

/// Unified, frictionless Remote DSH Host connector shared by Settings and Onboarding:
/// - Zero-plugin direct stock `dsh web` support
/// - Zero-token & In-App WebView cookie login (30-day persistence)
/// - Smart clipboard paste (`dsh web: http://.../?token=...`, bare IP auto `:3080`)
/// - Real LAN DSH discovery with version & mode badges
/// - Live inline connection diagnosis + copyable 1-line remote start commands
class RemoteHostConnectCard extends ConsumerStatefulWidget {
  const RemoteHostConnectCard({
    super.key,
    this.onConnectedHost,
    this.connectImmediately = true,
    this.showHeader = true,
    this.initiallyShowGuide = false,
  });

  /// Called after a host is added (and optionally connected).
  final ValueChanged<ManagedHost>? onConnectedHost;

  /// If true, switches immediately to the newly added host and connects.
  final bool connectImmediately;

  /// Whether to render the card's title row ("连接远程主机").
  final bool showHeader;

  /// Whether to expand the Desktop/CLI setup guide initially (e.g. when no remote hosts exist yet).
  final bool initiallyShowGuide;

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
  int _guideTab = 0; // 0: DSH Desktop GUI (no CLI), 1: CLI `dsh web`
  bool _allowBadCerts = false;
  bool _obscureToken = true;
  bool _testing = false;
  bool _connecting = false;
  bool _hasScannedLan = false;
  String? _capturedCookie;
  String? _selectedLanAddr;
  RemoteHostDiagnosis? _diagnosis;

  @override
  void initState() {
    super.initState();
    _showGuide = widget.initiallyShowGuide;
  }

  static const String _desktopGuiPrompt = '''请帮我开启当前电脑的局域网远程连接，让手机上的 GrassBag 可以连接这台电脑上的 DeepSeek Harness：
1. 先查询本机当前 Wi-Fi / 局域网 IPv4 地址（切勿使用 127.0.0.1 或 0.0.0.0）；
2. 若已安装 dsh-gbridge 桌面桥接插件并监听在 3081 端口，请读取 ~/.dsh/gbridge-lan-token 并直接给出 http://<局域网IP>:3081/?token=<令牌>；
3. 否则请使用本机 dsh 或 DeepSeek Harness 桌面端自带运行时（macOS: "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"，Windows: "%LOCALAPPDATA%\\Programs\\DeepSeek Harness\\resources\\runtime\\cli\\bin\\dsh.cmd"）在后台启动 Web 入口（与桌面端共享全部会话与模型配置）：dsh web --host <局域网IP> --port 3080 --no-open；
4. 启动后把完整可点击的 http://<局域网IP>:<端口>/?token=... 链接直接发给我。''';

  bool get _supportsInAppWebLogin =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

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
      ref.read(appProvider.notifier).showToast('剪贴板为空', tone: ToastTone.info);
      return;
    }
    final parsed = parseRemoteHostInput(text);
    // If clipboard holds a bare token (no URL/IP) and address is already filled in, treat it as token!
    final looksBareToken = _addrCtrl.text.trim().isNotEmpty &&
        !text.contains('://') &&
        !text.contains('.') &&
        !text.contains(':') &&
        RegExp(r'^[A-Za-z0-9._~+/=-]{8,}$').hasMatch(text);
    if (looksBareToken) {
      _tokenCtrl.text = text;
      setState(() {
        _showAdvanced = true;
        _diagnosis = null;
      });
      ref.read(appProvider.notifier).showToast('已填入访问令牌，正在验证连接…', tone: ToastTone.ok);
      await _runDiagnosis();
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
    ref.read(appProvider.notifier).showToast(
          parsed.token != null
              ? '已自动识别地址与一次性令牌，正在检测连通性…'
              : '已自动识别远程地址，正在检测连通性…',
          tone: ToastTone.ok,
        );
    await _runDiagnosis();
  }

  Future<RemoteHostDiagnosis?> _runDiagnosis() async {
    final raw = _addrCtrl.text.trim();
    if (raw.isEmpty) {
      ref.read(appProvider.notifier).showToast('请先输入远程地址或粘贴 dsh web 启动链接', tone: ToastTone.warn);
      return null;
    }
    if (_testing) return _diagnosis;
    setState(() => _testing = true);
    try {
      final diag = await ref.read(appProvider.notifier).diagnoseRemoteHost(
            raw,
            token: _tokenCtrl.text.trim().isEmpty ? null : _tokenCtrl.text.trim(),
            cookie: _capturedCookie,
            allowBadCertificates: _allowBadCerts,
          );
      if (!mounted) return diag;
      if (diag.normalizedAddress != null && diag.normalizedAddress != raw) {
        _addrCtrl.text = diag.normalizedAddress!;
      }
      if (diag.extractedToken != null &&
          diag.extractedToken!.isNotEmpty &&
          _tokenCtrl.text.trim().isEmpty) {
        _tokenCtrl.text = diag.extractedToken!;
      }
      setState(() => _diagnosis = diag);
      return diag;
    } finally {
      if (mounted) setState(() => _testing = false);
    }
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
    ref.read(appProvider.notifier).showToast('已捕获 30 天免密登录凭证，正在接入…', tone: ToastTone.ok);
    await _addAndConnect();
  }

  Future<void> _addAndConnect() async {
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
      final created = ctrl.addRemoteHost(
        raw,
        name: _nameCtrl.text.trim(),
        token: tokenText.isEmpty ? null : tokenText,
        cookie: _capturedCookie,
        allowBadCertificates: _allowBadCerts,
        autoProbe: !widget.connectImmediately,
      );
      if (created == null) {
        await _runDiagnosis();
        return;
      }
      if (widget.connectImmediately) {
        await ctrl.switchHost(created.id, awaitConnect: true);
      }
      if (!mounted) return;
      final refreshed = ref.read(appProvider);
      final latest = refreshed.hosts.where((h) => h.id == created.id).firstOrNull ?? created;
      if (latest.isConnectedUsable || !widget.connectImmediately) {
        _addrCtrl.clear();
        _nameCtrl.clear();
        _tokenCtrl.clear();
        setState(() {
          _capturedCookie = null;
          _diagnosis = null;
          _selectedLanAddr = null;
        });
        widget.onConnectedHost?.call(latest);
      } else if (latest.needsAuth) {
        // Calm guided auth flow: stay right on the card, expose the Token input & inline guide
        // instead of navigating away or flashing a red error!
        setState(() => _showAdvanced = true);
        await _runDiagnosis();
        if (mounted && !latest.isHtmlProxyAuth) {
          _tokenFocus.requestFocus();
        }
      } else {
        // Stay on screen and surface the actionable inline diagnosis (desktop guide / cert toggle)
        await _runDiagnosis();
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _copyCommand(String cmd) {
    Clipboard.setData(ClipboardData(text: cmd));
    ref.read(appProvider.notifier).showToast('已复制启动命令到剪贴板', tone: ToastTone.ok);
  }

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
                  icon: CupertinoIcons.wifi,
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
                        '直连远程 DSH 设备',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '原版 dsh web 免插件直连 · 认证一次 30 天免填 Token',
                        style: TextStyle(fontSize: 11.5, color: t.text3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          // Quick action strip: Paste Clipboard + Scan LAN
          Row(
            children: [
              Expanded(
                child: GrassBagSecondaryGlassButton(
                  label: '粘贴启动链接',
                  icon: CupertinoIcons.doc_on_clipboard,
                  height: 36,
                  tier: slice.glassTier,
                  insideGlass: true,
                  accentForeground: true,
                  onTap: _pasteFromClipboard,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GrassBagSecondaryGlassButton(
                  label: slice.scanningLan ? '扫描局域网…' : '发现局域网设备',
                  icon: CupertinoIcons.wifi,
                  height: 36,
                  tier: slice.glassTier,
                  insideGlass: true,
                  enabled: !slice.scanningLan,
                  onTap: slice.scanningLan
                      ? null
                      : () {
                          setState(() => _hasScannedLan = true);
                          ctrl.scanLanForHosts();
                        },
                ),
              ),
            ],
          ),

          // Empty LAN scan explanation + 1-tap desktop guide CTA
          if (_hasScannedLan && !slice.scanningLan && slice.discoveredLanHosts.isEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: t.fill1,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: t.sep, width: 0.6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '当前局域网未发现已开放端口的 DSH 设备',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '桌面版 DeepSeek Harness 默认仅监听本机回环地址；在电脑端开启局域网接入后即可被自动发现。',
                    style: TextStyle(fontSize: 11.5, height: 1.4, color: t.text3),
                  ),
                  if (!_showGuide) ...[
                    const SizedBox(height: 8),
                    GrassBagSecondaryGlassButton(
                      label: '查看桌面端免命令引导',
                      icon: CupertinoIcons.sparkles,
                      height: 32,
                      tier: slice.glassTier,
                      insideGlass: true,
                      accentForeground: true,
                      onTap: () => setState(() {
                        _showGuide = true;
                        _guideTab = 0;
                      }),
                    ),
                  ],
                ],
              ),
            ),
          ],

          // Discovered LAN DSH hosts
          if (slice.discoveredLanHosts.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final h in slice.discoveredLanHosts)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: GrassBagSpringTap(
                  onTap: () {
                    final changed = _addrCtrl.text.trim() != h.address;
                    _addrCtrl.text = h.address;
                    _nameCtrl.text = h.name;
                    setState(() {
                      if (changed) _capturedCookie = null;
                      _selectedLanAddr = h.address;
                      _diagnosis = null;
                    });
                    _runDiagnosis();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: _selectedLanAddr == h.address ? t.primarySoft : t.fill1,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _selectedLanAddr == h.address ? t.primary : t.sep,
                        width: 0.7,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          h.isDsh ? CupertinoIcons.sparkles : CupertinoIcons.desktopcomputer,
                          size: 16,
                          color: h.isDsh ? t.ok : t.text2,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                h.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: t.text,
                                ),
                              ),
                              Text(
                                '${h.address} · ${h.latencyMs}ms'
                                '${h.isDesktop ? ' · 桌面端桥接' : (h.hasGbridge ? ' · 已装助手' : (h.isDsh ? ' · 免插件直连' : ''))}'
                                '${h.requiresAuth ? ' · 待授权' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  color: t.text3,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          (!h.requiresAuth && h.isDsh) ? '直连' : '检测',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: t.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],

          const SizedBox(height: 10),
          // Smart URL input (accepts IP, domain, or full `dsh web: http://.../?token=...` line)
          GrassBagTextField(
            controller: _addrCtrl,
            focusNode: _addrFocus,
            placeholder: '192.168.x.x:3080 或粘贴 dsh web: http://... 链接',
            insideGlass: true,
            monospace: true,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            fontSize: 13,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            onChanged: (_) {
              if (_diagnosis != null || _capturedCookie != null || _selectedLanAddr != null) {
                setState(() {
                  _capturedCookie = null;
                  _selectedLanAddr = null;
                  _diagnosis = null;
                });
              }
            },
            onSubmitted: (_) => _runDiagnosis(),
          ),

          // Collapsible Advanced Options (Custom Name, Optional Token, Self-signed TLS)
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _showAdvanced
                              ? CupertinoIcons.chevron_down
                              : CupertinoIcons.chevron_right,
                          size: 12,
                          color: t.text3,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            _tokenCtrl.text.trim().isNotEmpty
                                ? '高级选项（已填 Token）'
                                : '高级选项（Token / 证书）',
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
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _showGuide = !_showGuide),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                  child: Text(
                    _showGuide ? '收起引导' : '桌面端 / 电脑引导',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: t.primary,
                    ),
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
                          controller: _nameCtrl,
                          placeholder: '自定义主机名（选填，默认取 IP/域名）',
                          insideGlass: true,
                          textInputAction: TextInputAction.next,
                          onSubmitted: (_) => _tokenFocus.requestFocus(),
                          fontSize: 13,
                          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                        ),
                        const SizedBox(height: 8),
                        GrassBagTextField(
                          controller: _tokenCtrl,
                          focusNode: _tokenFocus,
                          placeholder: 'Token 令牌（选填：无 Token 可直接留空或走网页登录）',
                          insideGlass: true,
                          monospace: true,
                          obscureText: _obscureToken,
                          textInputAction: TextInputAction.done,
                          fontSize: 13,
                          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                          onChanged: (_) => setState(() => _diagnosis = null),
                          onSubmitted: (_) => _addAndConnect(),
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
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '信任自签名 HTTPS 证书（局域网 / Caddy / Tailscale）',
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

          // Expandable Desktop GUI + CLI remote startup guide (supports GUI-only Desktop & CLI!)
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _showGuide
                ? Container(
                    margin: const EdgeInsets.only(top: 6, bottom: 4),
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: t.fill1,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: t.sep, width: 0.7),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: GrassBagSpringTap(
                                onTap: () => setState(() => _guideTab = 0),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 7),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: _guideTab == 0 ? t.primarySoft : t.bgSolid.withValues(alpha: 0.35),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: _guideTab == 0 ? t.primary.withValues(alpha: 0.5) : t.sep,
                                      width: 0.6,
                                    ),
                                  ),
                                  child: Text(
                                    '桌面端 GUI (免命令)',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: _guideTab == 0 ? t.primary : t.text2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: GrassBagSpringTap(
                                onTap: () => setState(() => _guideTab = 1),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 7),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: _guideTab == 1 ? t.primarySoft : t.bgSolid.withValues(alpha: 0.35),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: _guideTab == 1 ? t.primary.withValues(alpha: 0.5) : t.sep,
                                      width: 0.6,
                                    ),
                                  ),
                                  child: Text(
                                    '命令行 (dsh web)',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: _guideTab == 1 ? t.primary : t.text2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 9),
                        if (_guideTab == 0) ...[
                          Text(
                            'DeepSeek Harness 桌面端默认仅监听本机随机端口，没有终端命令也能连：',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: t.text,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '方法 1（推荐）：点击下方复制「桌面端一键指令」，直接粘贴发送给电脑上的 DeepSeek Harness 对话框，它会自动用桌面端内置运行时开启局域网共享入口（同步全部对话与模型）并给出连接链接。',
                            style: TextStyle(fontSize: 11, height: 1.45, color: t.text2),
                          ),
                          const SizedBox(height: 8),
                          GrassBagPrimaryGlassButton(
                            label: '复制桌面端一键指令（发给桌面 AI）',
                            icon: CupertinoIcons.sparkles,
                            height: 36,
                            tier: slice.glassTier,
                            insideGlass: true,
                            onTap: () {
                              Clipboard.setData(const ClipboardData(text: _desktopGuiPrompt));
                              ctrl.showToast('已复制一键指令，粘贴发给电脑上的 DeepSeek Harness 即可', tone: ToastTone.ok);
                            },
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '方法 2（插件直连）：在桌面端「设置 → 插件」安装 dsh-gbridge 后，会自动在 :3081 开启独立局域网桥接端口，点击上方「发现局域网设备」即可直接找到桌面端。',
                            style: TextStyle(fontSize: 11, height: 1.45, color: t.text3),
                          ),
                        ] else ...[
                          Text(
                            '无需安装插件！在远程电脑终端运行以下任一命令（注意：DSH 拒绝 0.0.0.0，需指定具体局域网 IP）：',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: t.text,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _CommandCopyRow(
                            label: 'macOS (Wi-Fi 自动取 IP)',
                            command: 'dsh web --host \$(ipconfig getifaddr en0) --no-open',
                            onCopy: _copyCommand,
                          ),
                          const SizedBox(height: 6),
                          _CommandCopyRow(
                            label: 'Linux (自动取局域网 IP)',
                            command: "dsh web --host \$(hostname -I | awk '{print \$1}') --no-open",
                            onCopy: _copyCommand,
                          ),
                          const SizedBox(height: 6),
                          _CommandCopyRow(
                            label: 'Windows PowerShell',
                            command: r'$ip=(Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.InterfaceAlias -notmatch "Loopback|vEthernet" -and $_.IPAddress -notlike "169.254.*"} | Select -First 1 -Expand IPAddress); dsh web --host $ip --no-open',
                            onCopy: _copyCommand,
                          ),
                          const SizedBox(height: 6),
                          _CommandCopyRow(
                            label: '通用指定 IP',
                            command: 'dsh web --host 192.168.1.100 --no-open',
                            onCopy: _copyCommand,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '提示：原版 dsh web 与桌面端共享 ~/.dsh 的全部会话与模型；首次粘贴启动链接后自动保存 30 天凭证，后续免填 Token。',
                            style: TextStyle(fontSize: 11, height: 1.4, color: t.text3),
                          ),
                        ],
                        // Keep a compact visible `dsh web --host` hint on tab 0 too for quick reference.
                        if (_guideTab == 0) ...[
                          const SizedBox(height: 6),
                          _CommandCopyRow(
                            label: '或手动在终端运行（macOS · 与桌面端共享全部会话）',
                            command: 'dsh web --host \$(ipconfig getifaddr en0) --no-open',
                            onCopy: _copyCommand,
                          ),
                        ],
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          // Live inline diagnosis result banner (calm info tone for auth/self-device guidance!)
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

          const SizedBox(height: 12),
          Row(
            children: [
              GrassBagSecondaryGlassButton(
                label: _testing ? '检测中…' : '检测连通',
                icon: CupertinoIcons.antenna_radiowaves_left_right,
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 13),
                tier: slice.glassTier,
                insideGlass: true,
                enabled: !_testing && !_connecting,
                onTap: (_testing || _connecting) ? null : _runDiagnosis,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GrassBagPrimaryGlassButton(
                  label: _connecting
                      ? '正在连接…'
                      : (diag?.kind == RemoteDiagnosisKind.readyDirect
                          ? '免插件立即连接'
                          : '添加并连接'),
                  icon: CupertinoIcons.arrow_right_circle_fill,
                  height: 42,
                  tier: slice.glassTier,
                  insideGlass: true,
                  enabled: !_connecting,
                  onTap: _connecting ? null : _addAndConnect,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget? _buildDiagnosisActions(RemoteHostDiagnosis diag, GrassBagGlassTier tier) {
    if (diag.canConnectNow) {
      return GrassBagPrimaryGlassButton(
        label: _connecting
            ? '正在连接…'
            : (diag.kind == RemoteDiagnosisKind.readyDirect ? '免插件立即连接' : '立即连接'),
        icon: CupertinoIcons.arrow_right_circle_fill,
        height: 34,
        tier: tier,
        insideGlass: true,
        enabled: !_connecting,
        onTap: _connecting ? null : _addAndConnect,
      );
    }
    if (diag.kind == RemoteDiagnosisKind.selfDevice) {
      if (_showGuide) return null;
      return GrassBagSecondaryGlassButton(
        label: '查看桌面端免命令连接引导',
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
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
                    label: '粘贴启动链接 / Token',
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
          ),
        ],
      );
    }
    if (diag.kind == RemoteDiagnosisKind.selfSignedTls) {
      return GrassBagPrimaryGlassButton(
        label: '信任自签名证书并重试',
        icon: CupertinoIcons.checkmark_shield_fill,
        height: 34,
        tier: tier,
        insideGlass: true,
        onTap: () {
          setState(() => _allowBadCerts = true);
          _runDiagnosis();
        },
      );
    }
    if (diag.suggestedCommand != null && diag.suggestedCommand!.isNotEmpty) {
      return _CommandCopyRow(
        label: '推荐启动命令',
        command: diag.suggestedCommand!,
        onCopy: _copyCommand,
      );
    }
    return null;
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: t.bgSolid.withValues(alpha: t.isDark ? 0.58 : 0.88),
        borderRadius: BorderRadius.circular(10),
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
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
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
