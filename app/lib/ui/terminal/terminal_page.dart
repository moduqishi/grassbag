import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart';
import 'package:xterm/xterm.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';

enum _ModLatch { off, once, locked }

enum _TermBackend { remoteWs, androidLocal, simulated }

/// Multi-tab interactive Terminal powered by `xterm` with three-tier live execution:
/// 1. Live `/gbridge/v1` WebSocket PTY (`terminal:<id>`) when bridged to a remote/local DSH host.
/// 2. Real Android Kotlin `/system/bin/sh` process (`GrassBagNativeBridge.startLocalShell`) on Android.
/// 3. Clean interactive simulated shell fallback for Web preview & headless widget tests.
class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({super.key});

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage>
    with SingleTickerProviderStateMixin {
  static int _tabSeq = 0;

  final List<_LocalTermTab> _tabs = [];
  final ScrollController _tabScrollCtrl = ScrollController();
  late final AnimationController _tabPulseCtrl;
  late final Animation<double> _tabPulseOpacity;
  int _activeIndex = 0;
  int _tabLabelSeq = 1;
  _ModLatch _ctrl = _ModLatch.off;
  _ModLatch _alt = _ModLatch.off;
  double _fontSize = 12.5;
  final ScrollController _extraKeysScrollCtrl = ScrollController();
  GbridgeClient? _attachedClient;
  String _boundHostId = '';
  StreamSubscription<NativeEvent>? _nativeSub;
  StreamSubscription<StreamFrame>? _wsSub;
  final Map<String, StringBuffer> _ptyBuffers = <String, StringBuffer>{};
  Timer? _ptyFlushTimer;
  bool _bypassLatchTransform = false;

  void _focusTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    for (var i = 0; i < _tabs.length; i++) {
      if (i != index && _tabs[i].focusNode.hasFocus) {
        _tabs[i].focusNode.unfocus();
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || index < 0 || index >= _tabs.length || _activeIndex != index) return;
      _tabs[index].focusNode.requestFocus();
    });
  }

  Future<void> _copySelection() async {
    if (_tabs.isEmpty) return;
    final tab = _tabs[_activeIndex];
    if (tab.closed) return;
    final sel = tab.terminalController.selection;
    if (sel == null) {
      ref.read(appProvider.notifier).showToast('请先长按或拖拽选中终端文本', tone: ToastTone.info);
      return;
    }
    final text = tab.terminal.buffer.getText(sel);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted || tab.closed) return;
    tab.terminalController.clearSelection();
    ref.read(appProvider.notifier).showToast('已复制终端选区', tone: ToastTone.ok);
  }

  Future<void> _pasteClipboard() async {
    if (_tabs.isEmpty) return;
    final tab = _tabs[_activeIndex];
    if (tab.closed) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || tab.closed) return;
    final text = data?.text ?? '';
    if (text.isEmpty) {
      ref.read(appProvider.notifier).showToast('剪贴板为空', tone: ToastTone.info);
      return;
    }
    _bypassLatchTransform = true;
    try {
      tab.terminal.paste(text);
    } finally {
      _bypassLatchTransform = false;
    }
    _scrollTabToBottomAndFocus(tab);
  }

  Future<void> _closeTabAt(int idx) async {
    if (_tabs.length <= 1 || idx < 0 || idx >= _tabs.length) return;
    final closing = _tabs[idx];
    if (!closing.exited && closing.backend != _TermBackend.simulated) {
      final ok = await showGrassBagConfirmDialog(
        context,
        title: '关闭终端「${closing.title}」？',
        message: '关闭后该标签内正在运行的 Shell 进程将立即终止。',
        confirmLabel: '关闭终端',
        isDestructive: true,
      );
      if (!ok || !mounted) return;
      final currentIdx = _tabs.indexOf(closing);
      if (currentIdx < 0 || _tabs.length <= 1) return;
      idx = currentIdx;
    }
    final hadFocus = _tabs.any((t) => t.focusNode.hasFocus);
    setState(() {
      _tabs.removeAt(idx);
      if (_activeIndex >= _tabs.length) {
        _activeIndex = _tabs.length - 1;
      } else if (idx < _activeIndex) {
        _activeIndex = (_activeIndex - 1).clamp(0, _tabs.length - 1);
      }
      _ctrl = _ModLatch.off;
      _alt = _ModLatch.off;
    });
    _teardownTabs([closing], deferResourceDispose: true);
    if (hadFocus) {
      _focusTab(_activeIndex);
    }
  }

  void _enqueuePtyChunk(_LocalTermTab tab, String chunk) {
    if (chunk.isEmpty) return;
    _ptyBuffers.putIfAbsent(tab.id, StringBuffer.new).write(chunk);
    _ptyFlushTimer ??= Timer(const Duration(milliseconds: 16), _flushPtyBuffers);
  }

  void _flushPtyBuffers() {
    _ptyFlushTimer?.cancel();
    _ptyFlushTimer = null;
    if (!mounted || _ptyBuffers.isEmpty) return;
    for (final tab in _tabs) {
      final buf = _ptyBuffers.remove(tab.id);
      if (buf != null && buf.isNotEmpty) {
        tab.terminal.write(buf.toString());
      }
    }
    _ptyBuffers.clear();
  }

  void _ensureWsSubscription(GbridgeClient client) {
    if (identical(_attachedClient, client) && _wsSub != null) return;
    unawaited(_wsSub?.cancel());
    _attachedClient = client;
    _wsSub = client.stream.frames.listen((frame) {
      if (!mounted || !identical(_attachedClient, client)) return;
      _onWsFrame(client, frame);
    });
  }

  String _nextTabId(String hostId) =>
      'term-${hostId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}-${++_tabSeq}-${DateTime.now().millisecondsSinceEpoch}';

  String _resolveLocalCwd(GrassBagAppState appState) {
    final wsPath = appState.activeWorkspaceItem?.path.trim() ?? '';
    if (wsPath.startsWith('/')) return wsPath;
    if (appState.activeWorkspace.startsWith('/')) return appState.activeWorkspace;
    return '/root/workspace';
  }

  String _resolveRemoteCwd(GrassBagAppState appState) {
    final ws = appState.activeWorkspaceDisplayName.trim();
    if (ws.isEmpty) return '~';
    return (ws.startsWith('/') || ws.startsWith('~')) ? ws : '~/$ws';
  }

  /// Keeps the leaf directory visible for deep paths (e.g. `…/toys/grassbag`) instead of
  /// truncating the right-most folder name off with `TextOverflow.ellipsis`.
  String _formatTerminalCwd(String raw) {
    final trimmed = raw.trim();
    if (trimmed.length <= 24) return trimmed;
    final parts = trimmed.split('/').where((p) => p.isNotEmpty).toList(growable: false);
    if (parts.length >= 2) {
      return '…/${parts[parts.length - 2]}/${parts.last}';
    }
    return trimmed;
  }

  void _teardownTabs(
    List<_LocalTermTab> tabsToClose, {
    bool deferResourceDispose = false,
  }) {
    for (final tab in tabsToClose) {
      _ptyBuffers.remove(tab.id);
      tab.closed = true;
      tab.resizeDebounce?.cancel();
      tab.resizeDebounce = null;
      if (!deferResourceDispose) {
        tab.disposeResources();
      }
      if (tab.backend == _TermBackend.androidLocal) {
        unawaited(GrassBagNativeBridge.instance.closeLocalShell(tab.id));
      } else if (tab.backend == _TermBackend.remoteWs) {
        final owner = tab.ownerClient ?? _attachedClient;
        if (owner != null) {
          if (tab.wsChannel != null) {
            owner.stream.unsubscribe(tab.wsChannel!);
          }
          if (tab.remoteTermId != null && tab.remoteTermId!.isNotEmpty) {
            unawaited(
              owner
                  .closeTerminal(tab.remoteTermId!, sessionId: tab.remoteSessionId)
                  .catchError((_) => const <String, dynamic>{}),
            );
          }
        }
      }
    }
    if (deferResourceDispose && tabsToClose.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final tab in tabsToClose) {
          tab.disposeResources();
        }
      });
    }
    if (_ptyBuffers.isEmpty) {
      _ptyFlushTimer?.cancel();
      _ptyFlushTimer = null;
    }
  }

  void _initTabsForActiveHost() {
    final ctrl = ref.read(appProvider.notifier);
    final live = ctrl.liveClient;
    final native = GrassBagNativeBridge.instance;
    final appState = ref.read(appProvider);
    final host = appState.activeHost;
    final remoteCwd = _resolveRemoteCwd(appState);
    _boundHostId = host.id;

    // Strictly isolate host backends: Android local shell is ONLY allowed for `host.isLocal`!
    final canUseAndroidLocal = native.isAndroidNative && host.isLocal;

    if (live != null && !canUseAndroidLocal) {
      _ensureWsSubscription(live);
      final tab = _createTab(
        id: _nextTabId(host.id),
        hostId: host.id,
        title: 'shell',
        cwd: remoteCwd,
        backend: _TermBackend.remoteWs,
        ownerClient: live,
      );
      _tabs.add(tab);
      unawaited(_attachRemotePty(tab, live));
    } else if (canUseAndroidLocal) {
      final localCwd = _resolveLocalCwd(appState);
      final extracted = appState.nativeRuntimeStatus.containerExtracted;
      final tab = _createTab(
        id: _nextTabId(host.id),
        hostId: host.id,
        title: 'bash',
        cwd: localCwd,
        backend: _TermBackend.androidLocal,
        bootLines: [
          extracted
              ? '\x1b[90m正在启动本机 Ubuntu 24.04.5 容器 Shell…\x1b[0m'
              : '\x1b[90m正在检查本机 Linux 容器环境…\x1b[0m',
        ],
      );
      _tabs.add(tab);
      _nativeSub ??= native.events.listen(_onNativeEvent);
      unawaited(_tryUpgradeToAndroidLocalShell(tab));
    } else {
      final notice = host.isLocal
          ? '当前尚未连接到运行中的本机 DSH 主机。'
          : '远程主机「${host.name}」尚未连接，连接后将自动接入实时远程 PTY（绝不回退到手机本机终端）。';
      _tabs.add(
        _createTab(
          id: _nextTabId(host.id),
          hostId: host.id,
          title: 'shell',
          cwd: remoteCwd,
          backend: _TermBackend.simulated,
          bootLines: [
            '\x1b[33m$notice\x1b[0m',
            '\x1b[90m连接就绪后可点击右上角重连或自动接入 PTY。\x1b[0m',
          ],
        ),
      );
    }
  }

  void _resetForHostSwitch() {
    final oldTabs = List<_LocalTermTab>.of(_tabs);
    _tabs.clear();
    _activeIndex = 0;
    _tabLabelSeq = 1;
    _ctrl = _ModLatch.off;
    _alt = _ModLatch.off;
    unawaited(_wsSub?.cancel());
    _wsSub = null;
    _attachedClient = null;
    _initTabsForActiveHost();
    if (mounted) {
      setState(() {});
      _teardownTabs(oldTabs, deferResourceDispose: true);
      _focusTab(_activeIndex);
    } else {
      _teardownTabs(oldTabs);
    }
  }

  void _restartActiveTab() {
    if (_tabs.isEmpty) return;
    final old = _tabs[_activeIndex];
    final ctrl = ref.read(appProvider.notifier);
    final live = ctrl.liveClient;
    final native = GrassBagNativeBridge.instance;
    final appState = ref.read(appProvider);
    final host = appState.activeHost;
    final canUseAndroidLocal = native.isAndroidNative && host.isLocal;
    final backend = (live != null && !canUseAndroidLocal)
        ? _TermBackend.remoteWs
        : (canUseAndroidLocal ? _TermBackend.androidLocal : _TermBackend.simulated);
    final cwd = backend == _TermBackend.androidLocal
        ? _resolveLocalCwd(appState)
        : _resolveRemoteCwd(appState);
    final replacement = _createTab(
      id: _nextTabId(host.id),
      hostId: host.id,
      title: old.title,
      cwd: cwd,
      backend: backend,
      ownerClient: backend == _TermBackend.remoteWs ? live : null,
      bootLines: backend == _TermBackend.simulated
          ? ['\x1b[33m正在尝试重新连接主机「${host.name}」…\x1b[0m']
          : const [],
    );
    final hadFocus = _tabs.any((t) => t.focusNode.hasFocus);
    setState(() {
      _tabs[_activeIndex] = replacement;
    });
    _teardownTabs([old], deferResourceDispose: true);
    if (hadFocus) {
      _focusTab(_activeIndex);
    }
    if (backend == _TermBackend.remoteWs && live != null) {
      unawaited(_attachRemotePty(replacement, live));
    } else if (backend == _TermBackend.androidLocal) {
      _nativeSub ??= native.events.listen(_onNativeEvent);
      unawaited(_tryUpgradeToAndroidLocalShell(replacement));
    } else {
      unawaited(ctrl.probeAndRefreshHost(host.id));
    }
  }

  @override
  void initState() {
    super.initState();
    _tabPulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      value: 1.0,
    );
    _tabPulseOpacity = Tween<double>(begin: 0.72, end: 1.0).animate(
      CurvedAnimation(parent: _tabPulseCtrl, curve: Curves.easeOutCubic),
    );
    _initTabsForActiveHost();
  }

  @override
  void dispose() {
    _tabScrollCtrl.dispose();
    _extraKeysScrollCtrl.dispose();
    _tabPulseCtrl.dispose();
    _ptyFlushTimer?.cancel();
    _ptyFlushTimer = null;
    _ptyBuffers.clear();
    unawaited(_nativeSub?.cancel());
    unawaited(_wsSub?.cancel());
    _teardownTabs(List<_LocalTermTab>.of(_tabs));
    _tabs.clear();
    super.dispose();
  }

  void _onNativeEvent(NativeEvent evt) {
    if (!mounted) return;
    if (evt.type == 'local_term_data') {
      final id = evt.data['tabId']?.toString();
      final text = evt.data['data']?.toString() ?? '';
      for (final t in _tabs) {
        if (t.id == id && t.backend == _TermBackend.androidLocal && text.isNotEmpty) {
          _enqueuePtyChunk(
            t,
            t.isLocalPty ? text : text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n'),
          );
          break;
        }
      }
    } else if (evt.type == 'local_term_mode') {
      final id = evt.data['tabId']?.toString();
      final isPty = evt.data['isPty'] == true;
      for (final t in _tabs) {
        if (t.id == id && t.backend == _TermBackend.androidLocal) {
          t.isLocalPty = isPty;
          t.localModeLocked = true;
          break;
        }
      }
    } else if (evt.type == 'local_term_exit') {
      final id = evt.data['tabId']?.toString();
      final code = evt.data['exitCode'] ?? 0;
      for (final t in _tabs) {
        if (t.id == id && t.backend == _TermBackend.androidLocal) {
          _flushPtyBuffers();
          t.terminal.write('\r\n\x1b[90m[进程已退出 code=$code]\x1b[0m\r\n');
          if (!t.exited) {
            setState(() => t.exited = true);
          }
          break;
        }
      }
    }
  }

  void _onWsFrame(GbridgeClient sourceClient, StreamFrame frame) {
    if (!mounted) return;
    final ch = frame.channel ?? '';
    if (!ch.startsWith('terminal:')) return;
    final type = frame.type ?? '';
    final data = frame.dataMap;
    final tid = data?['terminalId']?.toString() ?? '';
    _LocalTermTab? target;
    for (final t in _tabs) {
      if (identical(t.ownerClient, sourceClient) &&
          (t.wsChannel == ch || (tid.isNotEmpty && t.remoteTermId == tid))) {
        target = t;
        break;
      }
    }
    if (target == null) return;

    if (type == 'term.snapshot') {
      target.streamRetryTimer?.cancel();
      target.streamRetryTimer = null;
      target.streamRetryCount = 0;
      target.streamReconnecting = false;
      final screen = data?['data']?.toString() ?? data?['screen']?.toString() ?? '';
      if (target.exited && mounted) {
        setState(() => target!.exited = false);
      }
      if (screen.isNotEmpty) {
        _flushPtyBuffers();
        target.terminal.write('\x1b[2J\x1b[H$screen');
      }
      return;
    }
    if (type == 'term.exit' || type == 'terminal.exit') {
      target.streamRetryTimer?.cancel();
      target.streamRetryTimer = null;
      target.streamReconnecting = false;
      _flushPtyBuffers();
      final code = data?['exitCode'] ?? data?['code'];
      final exitNote = code != null ? '[远端 PTY 已退出 code=$code]' : '[远端 PTY 已退出]';
      target.terminal.write('\r\n\x1b[90m$exitNote\x1b[0m\r\n');
      if (!target.exited) {
        setState(() => target!.exited = true);
      }
      return;
    }
    if (type == 'terminal.unavailable') {
      target.streamRetryTimer?.cancel();
      target.streamRetryTimer = null;
      target.streamReconnecting = false;
      _flushPtyBuffers();
      final msg = data?['message']?.toString() ?? data?['error']?.toString() ?? '远端 PTY 不可用';
      target.terminal.write('\r\n\x1b[31m[$msg]\x1b[0m\r\n');
      if (!target.exited) {
        setState(() => target!.exited = true);
      }
      return;
    }
    if (type == 'terminal.stream_error' || type == 'terminal.stream_end') {
      _flushPtyBuffers();
      final msg = data?['message']?.toString() ??
          data?['error']?.toString() ??
          (type == 'terminal.stream_end' ? '远端 PTY 子流已断开' : '远端 PTY 子流异常');
      const maxRetries = 4;
      final channel = target.wsChannel;
      if (channel != null &&
          channel.isNotEmpty &&
          !target.closed &&
          target.streamRetryCount < maxRetries) {
        final attempt = ++target.streamRetryCount;
        final delayMs = 500 * (1 << (attempt - 1));
        target.streamReconnecting = true;
        target.terminal.write(
          '\r\n\x1b[33m[$msg，正在尝试重新订阅（第 $attempt/$maxRetries 次）…]\x1b[0m\r\n',
        );
        target.streamRetryTimer?.cancel();
        final capturedTab = target;
        target.streamRetryTimer = Timer(Duration(milliseconds: delayMs), () {
          if (!mounted ||
              capturedTab.closed ||
              !identical(capturedTab.ownerClient, sourceClient)) {
            return;
          }
          sourceClient.stream.subscribe(channel, force: true);
        });
      } else {
        target.streamRetryTimer?.cancel();
        target.streamRetryTimer = null;
        target.streamReconnecting = false;
        target.terminal.write('\r\n\x1b[31m[$msg，自动重连已达上限，可点击重连按钮恢复]\x1b[0m\r\n');
        if (!target.exited) {
          setState(() => target!.exited = true);
        }
      }
      return;
    }

    final chunk = data?['data']?.toString() ?? data?['chunk']?.toString() ?? '';
    if (chunk.isNotEmpty) {
      if (target.streamRetryCount > 0 || target.streamReconnecting) {
        target.streamRetryTimer?.cancel();
        target.streamRetryTimer = null;
        target.streamRetryCount = 0;
        target.streamReconnecting = false;
      }
      if (target.exited && mounted) {
        setState(() => target!.exited = false);
      }
      _enqueuePtyChunk(target, chunk);
    }
  }

  void _closeIfLeakedRemotePty(
    GbridgeClient client,
    Map<String, dynamic>? res,
    String? fallbackSid,
  ) {
    if (res == null) return;
    final termObj = res['terminal'];
    final remoteId =
        (termObj is Map ? (termObj['id'] ?? termObj['terminalId']) : res['id'])?.toString() ?? '';
    final resolvedSid =
        (termObj is Map ? termObj['sessionId']?.toString() : null) ?? fallbackSid;
    if (remoteId.isNotEmpty) {
      unawaited(
        client
            .closeTerminal(remoteId, sessionId: resolvedSid)
            .catchError((_) => const <String, dynamic>{}),
      );
    }
  }

  Future<void> _attachRemotePty(_LocalTermTab tab, GbridgeClient client) async {
    tab.backend = _TermBackend.remoteWs;
    tab.ownerClient = client;
    if (mounted) {
      setState(() => tab.attaching = true);
    } else {
      tab.attaching = true;
    }
    _ensureWsSubscription(client);
    final appState = ref.read(appProvider);
    tab.terminal.write('\x1b[90m正在连接「${appState.activeHost.name}」实时 PTY…\x1b[0m\r\n');
    try {
      String? sid = appState.activeSessionId;
      if (sid != null && sid.startsWith('pending-session-')) sid = null;
      final activePreset = appState.activeSession?.agentPreset;
      final presetAvailable = activePreset == null ||
          activePreset.isEmpty ||
          appState.presets.any((p) => p.id == activePreset);
      Map<String, dynamic>? res;
      if (sid != null && sid.isNotEmpty && presetAvailable) {
        try {
          res = await client.createTerminal(
            sessionId: sid,
            cols: tab.lastCols,
            rows: tab.lastRows,
          );
        } catch (_) {
          res = null;
        }
      }
      if (!mounted || tab.closed || !identical(ref.read(appProvider.notifier).liveClient, client)) {
        _closeIfLeakedRemotePty(client, res, sid);
        return;
      }
      if (res == null) {
        final targetPath = appState.activeWorkspaceItem?.path ?? '';
        final candidate = appState.sessions
            .where((s) =>
                !s.archived &&
                !s.id.startsWith('pending-session-') &&
                (s.agentPreset == null ||
                    s.agentPreset!.isEmpty ||
                    appState.presets.any((p) => p.id == s.agentPreset)))
            .toList(growable: false);
        final preferred = targetPath.isNotEmpty
            ? candidate.where((s) => s.cwd == targetPath).firstOrNull ?? candidate.firstOrNull
            : candidate.firstOrNull;
        if (preferred != null) {
          try {
            sid = preferred.id;
            res = await client.createTerminal(
              sessionId: sid,
              cols: tab.lastCols,
              rows: tab.lastRows,
            );
          } catch (_) {
            res = null;
          }
        }
      }
      if (!mounted || tab.closed || !identical(ref.read(appProvider.notifier).liveClient, client)) {
        _closeIfLeakedRemotePty(client, res, sid);
        return;
      }
      if (res == null) {
        final cwd = appState.activeWorkspaceItem?.path;
        final created = await client.createSession(
          cwd: cwd != null && cwd.isNotEmpty ? cwd : null,
          presetId: 'standard',
        );
        if (!mounted || tab.closed || !identical(ref.read(appProvider.notifier).liveClient, client)) {
          return;
        }
        sid = created.id;
        res = await client.createTerminal(
          sessionId: sid,
          cols: tab.lastCols,
          rows: tab.lastRows,
        );
      }
      final termObj = res['terminal'];
      final remoteId = (termObj is Map ? (termObj['id'] ?? termObj['terminalId']) : res['id'])
          ?.toString() ?? '';
      final resolvedSid = (termObj is Map ? termObj['sessionId']?.toString() : null) ?? sid;
      if (remoteId.isNotEmpty) {
        if (!mounted || tab.closed || !identical(ref.read(appProvider.notifier).liveClient, client)) {
          _closeIfLeakedRemotePty(client, res, resolvedSid);
          return;
        }
        final prevChannel = tab.wsChannel;
        final prevOwner = tab.ownerClient;
        if (prevChannel != null && prevOwner != null) {
          prevOwner.stream.unsubscribe(prevChannel);
        }
        tab.backend = _TermBackend.remoteWs;
        tab.ownerClient = client;
        tab.remoteTermId = remoteId;
        tab.remoteSessionId = resolvedSid;
        tab.wsChannel = (resolvedSid != null && resolvedSid.isNotEmpty)
            ? 'terminal:$resolvedSid:$remoteId'
            : 'terminal:$remoteId';
        if (mounted) {
          setState(() {
            tab.attaching = false;
            tab.exited = false;
          });
        } else {
          tab.attaching = false;
          tab.exited = false;
        }
        client.stream.subscribe(tab.wsChannel!);
        tab.sentCols = tab.lastCols;
        tab.sentRows = tab.lastRows;
        client.stream.sendTerminalResize(remoteId, tab.lastCols, tab.lastRows);
        tab.terminal.write('\x1b[32m✓ 已接入「${appState.activeHost.name}」真实 PTY ($remoteId)\x1b[0m\r\n');
        return;
      }
    } catch (e) {
      if (mounted && !tab.closed) {
        tab.terminal.write('\x1b[31m创建远端 PTY 失败：$e\x1b[0m\r\n');
      }
    } finally {
      if (tab.attaching) {
        if (mounted) {
          setState(() => tab.attaching = false);
        } else {
          tab.attaching = false;
        }
      }
    }
    if (!mounted || tab.closed) return;
    // NEVER fall back to Android local shell when connected to a REMOTE host!
    if (tab.hostId == 'local' &&
        ref.read(appProvider).activeHost.isLocal &&
        GrassBagNativeBridge.instance.isAndroidNative) {
      _nativeSub ??= GrassBagNativeBridge.instance.events.listen(_onNativeEvent);
      await _tryUpgradeToAndroidLocalShell(tab);
    } else {
      tab.backend = _TermBackend.simulated;
      setState(() => tab.exited = true);
      tab.terminal.write('\x1b[33m远端 PTY 不可用，请检查主机状态后点击「重启终端」重试\x1b[0m\r\n');
    }
  }

  Future<void> _tryUpgradeToAndroidLocalShell(_LocalTermTab tab) async {
    final res = await GrassBagNativeBridge.instance.startLocalShellDetailed(
      tab.id,
      cwd: tab.cwd,
      cols: tab.lastCols,
      rows: tab.lastRows,
    );
    if (!mounted || tab.closed) {
      if (res['ok'] == true) {
        unawaited(GrassBagNativeBridge.instance.closeLocalShell(tab.id));
      }
      return;
    }
    if (res['ok'] != true) {
      setState(() => tab.exited = true);
      tab.terminal.write('\x1b[31m启动本机 Shell 失败：${res['error'] ?? '未知错误'}\x1b[0m\r\n');
      return;
    }
    tab.backend = _TermBackend.androidLocal;
    if (!tab.localModeLocked) {
      tab.isLocalPty = res['isPty'] == true;
    }
    if (tab.isLocalPty) {
      tab.sentCols = tab.lastCols;
      tab.sentRows = tab.lastRows;
      unawaited(GrassBagNativeBridge.instance.resizeLocalShell(tab.id, tab.lastCols, tab.lastRows));
    }
    final hasUbuntu = ref.read(appProvider).nativeRuntimeStatus.containerExtracted;
    final banner = hasUbuntu
        ? (tab.isLocalPty
            ? '✓ 已接入本机 Ubuntu 24.04.5 实时 PTY (/bin/bash · Node 24)'
            : '✓ 已接入本机 Ubuntu 24.04.5 容器 (/bin/bash · Node 24)')
        : '✓ 已接入 Android 本机真实 Shell (/system/bin/sh)';
    tab.terminal.write('\r\n\x1b[32m$banner\x1b[0m\r\n');
    if (!tab.isLocalPty) {
      unawaited(
        GrassBagNativeBridge.instance.writeLocalShell(
          tab.id,
          'echo "[\$(id -un)@grassbag \$(pwd)]"\n',
        ),
      );
    }
  }

  String _applyLatchesToInput(String data) {
    if (_bypassLatchTransform || (_ctrl == _ModLatch.off && _alt == _ModLatch.off)) return data;
    var out = data;
    var ctrlTransformed = false;
    var altTransformed = false;
    if (_ctrl != _ModLatch.off && out.length == 1) {
      final code = out.toLowerCase().codeUnitAt(0);
      if (code >= 97 && code <= 122) {
        out = String.fromCharCode(code - 96);
        ctrlTransformed = true;
      } else if (out == '[' || out == '3') {
        out = '\x1b';
        ctrlTransformed = true;
      } else if (out == '\\' || out == '4') {
        out = '\x1c';
        ctrlTransformed = true;
      } else if (out == ']' || out == '5') {
        out = '\x1d';
        ctrlTransformed = true;
      } else if (out == '@' || out == ' ' || out == '2') {
        out = '\x00';
        ctrlTransformed = true;
      } else if (out == '^' || out == '6') {
        out = '\x1e';
        ctrlTransformed = true;
      } else if (out == '_' || out == '7' || out == '/') {
        out = '\x1f';
        ctrlTransformed = true;
      } else if (out == '?' || out == '8') {
        out = '\x7f';
        ctrlTransformed = true;
      }
    }
    if (_alt != _ModLatch.off && out.isNotEmpty) {
      out = '\x1b$out';
      altTransformed = true;
    }
    final clearCtrl = _ctrl == _ModLatch.once && ctrlTransformed;
    final clearAlt = _alt == _ModLatch.once && altTransformed;
    if ((clearCtrl || clearAlt) && mounted) {
      setState(() {
        if (clearCtrl) _ctrl = _ModLatch.off;
        if (clearAlt) _alt = _ModLatch.off;
      });
    }
    return out;
  }

  _LocalTermTab _createTab({
    required String id,
    required String hostId,
    required String title,
    required String cwd,
    required _TermBackend backend,
    GbridgeClient? ownerClient,
    List<String> bootLines = const [],
  }) {
    final buf = StringBuffer();
    late final _LocalTermTab tab;
    final term = Terminal(
      maxLines: 2000,
      onResize: (w, h, pw, ph) {
        if (w <= 0 || h <= 0) return;
        tab.lastCols = w;
        tab.lastRows = h;
        // Debounce SIGWINCH by 120ms & dedupe identical sizes so keyboard open/close
        // animations never flood the PTY with 60–120Hz redraw storms!
        tab.resizeDebounce?.cancel();
        tab.resizeDebounce = Timer(const Duration(milliseconds: 120), () {
          if (!mounted || tab.closed) return;
          if (tab.sentCols == tab.lastCols && tab.sentRows == tab.lastRows) return;
          final live = ref.read(appProvider.notifier).liveClient;
          if (tab.backend == _TermBackend.remoteWs &&
              tab.remoteTermId != null &&
              live != null &&
              identical(live, tab.ownerClient)) {
            tab.sentCols = tab.lastCols;
            tab.sentRows = tab.lastRows;
            live.stream.sendTerminalResize(tab.remoteTermId!, tab.lastCols, tab.lastRows);
          } else if (tab.backend == _TermBackend.androidLocal && tab.isLocalPty) {
            tab.sentCols = tab.lastCols;
            tab.sentRows = tab.lastRows;
            unawaited(
              GrassBagNativeBridge.instance.resizeLocalShell(tab.id, tab.lastCols, tab.lastRows),
            );
          }
        });
      },
      onOutput: (rawData) {
        if (!mounted || tab.closed || tab.hostId != ref.read(appProvider).activeHostId) return;
        final data = _applyLatchesToInput(rawData);
        final live = ref.read(appProvider.notifier).liveClient;
        if (tab.backend == _TermBackend.remoteWs) {
          if (tab.attaching) {
            return;
          }
          if (tab.remoteTermId != null &&
              live != null &&
              identical(live, tab.ownerClient)) {
            live.stream.sendTerminalInput(tab.remoteTermId!, data);
          } else if (!tab.exited) {
            tab.terminal.write('\r\n\x1b[33m[远程 PTY 连接已断开，点击右上角「重连」恢复]\x1b[0m\r\n');
            if (mounted) setState(() => tab.exited = true);
          }
          return;
        }
        if (tab.backend == _TermBackend.androidLocal && tab.isLocalPty) {
          unawaited(GrassBagNativeBridge.instance.writeLocalShell(tab.id, data));
          return;
        }
        // Line-buffered mode (Android non-PTY pipe or simulated fallback):
        // handles multi-line pastes, strips ANSI CSI sequences, supports ^C/^D, and
        // erases wide CJK / emoji grapheme clusters accurately!
        final isAndroidPipe = tab.backend == _TermBackend.androidLocal;
        final cleaned = data
            .replaceAll('\r\n', '\n')
            .replaceAll('\r', '\n')
            .replaceAll(_ansiEscapeRe, '');
        if (cleaned.isEmpty) return;

        for (final cluster in cleaned.characters) {
          if (cluster == '\n') {
            final line = buf.toString();
            buf.clear();
            tab.terminal.write('\r\n');
            if (isAndroidPipe) {
              unawaited(GrassBagNativeBridge.instance.writeLocalShell(tab.id, '$line\n'));
            } else {
              final cmd = line.trim();
              if (cmd.isNotEmpty) {
                _runSimulatedCommand(tab.terminal, cwd, cmd);
              }
              tab.terminal.write('\x1b[32m$cwd ❯\x1b[0m ');
            }
          } else if (cluster == '\x7f' || cluster == '\b') {
            if (buf.isNotEmpty) {
              final chars = buf.toString().characters;
              final removed = chars.last;
              buf
                ..clear()
                ..write(chars.skipLast(1).toString());
              final w = _displayWidthOfGrapheme(removed);
              tab.terminal.write(w >= 2 ? '\b\b  \b\b' : '\b \b');
            }
          } else if (cluster == '\x03') {
            buf.clear();
            if (isAndroidPipe) {
              tab.terminal.write('^C\r\n');
              unawaited(GrassBagNativeBridge.instance.signalLocalShell(tab.id, 'SIGINT'));
            } else {
              tab.terminal.write('^C\r\n\x1b[32m$cwd ❯\x1b[0m ');
            }
          } else if (cluster == '\x04') {
            if (buf.isEmpty) {
              if (isAndroidPipe) {
                tab.terminal.write('^D\r\n');
                unawaited(GrassBagNativeBridge.instance.writeLocalShell(tab.id, 'exit\n'));
              } else {
                tab.terminal.write('^D\r\n\x1b[32m$cwd ❯\x1b[0m ');
              }
            }
          } else if (cluster == '\x1b') {
            // Ignore bare Esc in line-buffered mode so cursor never jumps over prompt.
          } else {
            buf.write(cluster);
            tab.terminal.write(cluster);
          }
        }
      },
    );
    tab = _LocalTermTab(
      id: id,
      hostId: hostId,
      title: title,
      cwd: cwd,
      terminal: term,
      backend: backend,
      ownerClient: ownerClient,
    );
    for (final line in bootLines) {
      term.write('$line\r\n');
    }
    if (backend == _TermBackend.simulated) {
      term.write('\x1b[32m$cwd ❯\x1b[0m ');
    }
    return tab;
  }

  void _runSimulatedCommand(Terminal term, String cwd, String cmd) {
    if (cmd == 'clear') {
      term.write('\x1b[2J\x1b[H');
      return;
    }
    term.write('\x1b[33m当前未连接运行中的 DSH 主机 PTY，无法执行: $cmd\x1b[0m\r\n');
  }

  void _addTab() {
    final n = ++_tabLabelSeq;
    final live = ref.read(appProvider.notifier).liveClient;
    final native = GrassBagNativeBridge.instance;
    final appState = ref.read(appProvider);
    final host = appState.activeHost;
    final canUseAndroidLocal = native.isAndroidNative && host.isLocal;

    final backend = (live != null && !canUseAndroidLocal)
        ? _TermBackend.remoteWs
        : (canUseAndroidLocal ? _TermBackend.androidLocal : _TermBackend.simulated);

    final newTab = _createTab(
      id: _nextTabId(host.id),
      hostId: host.id,
      title: backend == _TermBackend.androidLocal ? 'bash #$n' : 'shell #$n',
      cwd: backend == _TermBackend.androidLocal
          ? _resolveLocalCwd(appState)
          : _resolveRemoteCwd(appState),
      backend: backend,
      ownerClient: backend == _TermBackend.remoteWs ? live : null,
      bootLines: backend == _TermBackend.simulated
          ? ['\x1b[90m主机「${host.name}」尚未连接，暂无法打开实时 PTY\x1b[0m']
          : const [],
    );

    setState(() {
      _tabs.add(newTab);
      _activeIndex = _tabs.length - 1;
    });
    _focusTab(_activeIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tabScrollCtrl.hasClients) return;
      final maxExt = _tabScrollCtrl.position.maxScrollExtent;
      if (maxExt > 0) {
        _tabScrollCtrl.animateTo(
          maxExt,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    });

    if (backend == _TermBackend.remoteWs && live != null) {
      unawaited(_attachRemotePty(newTab, live));
    } else if (backend == _TermBackend.androidLocal) {
      _nativeSub ??= native.events.listen(_onNativeEvent);
      unawaited(_tryUpgradeToAndroidLocalShell(newTab));
    }

    ref.read(appProvider.notifier).showToast('已新建「${host.name}」终端标签', tone: ToastTone.info);
  }

  void _scrollTabToBottomAndFocus(_LocalTermTab tab) {
    if (!tab.focusNode.hasFocus) {
      tab.focusNode.requestFocus();
    }
    if (tab.scrollController.hasClients) {
      final maxExt = tab.scrollController.position.maxScrollExtent;
      if ((maxExt - tab.scrollController.offset).abs() > 2.0) {
        tab.scrollController.jumpTo(maxExt);
      }
    }
  }

  void _sendExtraKey(String key) {
    final tab = _tabs[_activeIndex];
    if (key == 'ctrl') {
      final next = switch (_ctrl) {
        _ModLatch.off => _ModLatch.once,
        _ModLatch.once => _ModLatch.locked,
        _ModLatch.locked => _ModLatch.off,
      };
      setState(() => _ctrl = next);
      if (!tab.focusNode.hasFocus) {
        tab.focusNode.requestFocus();
      }
      return;
    }
    if (key == 'alt') {
      final next = switch (_alt) {
        _ModLatch.off => _ModLatch.once,
        _ModLatch.once => _ModLatch.locked,
        _ModLatch.locked => _ModLatch.off,
      };
      setState(() => _alt = next);
      if (!tab.focusNode.hasFocus) {
        tab.focusNode.requestFocus();
      }
      return;
    }

    if (key == 'hide_kb') {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    if (key == 'copy') {
      unawaited(_copySelection());
      return;
    }
    if (key == 'paste') {
      unawaited(_pasteClipboard());
      return;
    }

    final ctrlActive = _ctrl != _ModLatch.off;
    final altActive = _alt != _ModLatch.off;
    final specialKey = switch (key) {
      'esc' => TerminalKey.escape,
      'tab' => TerminalKey.tab,
      'home' => TerminalKey.home,
      'end' => TerminalKey.end,
      'left' => TerminalKey.arrowLeft,
      'up' => TerminalKey.arrowUp,
      'down' => TerminalKey.arrowDown,
      'right' => TerminalKey.arrowRight,
      _ => null,
    };
    if (specialKey != null) {
      final clearCtrl = _ctrl == _ModLatch.once;
      final clearAlt = _alt == _ModLatch.once;
      if (clearCtrl || clearAlt) {
        setState(() {
          if (clearCtrl) _ctrl = _ModLatch.off;
          if (clearAlt) _alt = _ModLatch.off;
        });
      }
      // Guard against locked Ctrl/Alt double-prefixing `keyInput`'s own escape sequence!
      _bypassLatchTransform = true;
      try {
        tab.terminal.keyInput(specialKey, ctrl: ctrlActive, alt: altActive);
      } finally {
        _bypassLatchTransform = false;
      }
      _scrollTabToBottomAndFocus(tab);
      return;
    }
    final ctrlChar = switch (key) {
      'ctrl_c' => '\x03',
      'ctrl_d' => '\x04',
      'ctrl_z' => '\x1a',
      _ => null,
    };
    if (ctrlChar != null) {
      final clearCtrl = _ctrl == _ModLatch.once;
      if (clearCtrl) {
        setState(() {
          _ctrl = _ModLatch.off;
        });
      }
      _bypassLatchTransform = true;
      try {
        tab.terminal.textInput(ctrlChar);
      } finally {
        _bypassLatchTransform = false;
      }
      _scrollTabToBottomAndFocus(tab);
      return;
    }
    // Single characters flow through `onOutput`, where `_applyLatchesToInput` applies Ctrl/Alt!
    tab.terminal.textInput(key);
    _scrollTabToBottomAndFocus(tab);
  }

  void _openMoreSheet({Offset? anchor}) {
    final activeTab = _tabs[_activeIndex];
    final tier = ref.read(appProvider).glassTier;
    final media = MediaQuery.of(context);
    final envLabel = switch (activeTab.backend) {
      _TermBackend.remoteWs => '实时远程 PTY',
      _TermBackend.androidLocal => 'Android 本机 Shell',
      _TermBackend.simulated =>
        ref.read(appProvider).activeHost.isLocal ? '未连接本机引擎' : '等待连接远程主机',
    };
    unawaited(
      showGrassBagGlassContextMenu(
        context,
        tier: tier,
        globalAnchor: anchor ?? Offset(media.size.width - 24, media.viewPadding.top + 62),
        headerTitle: '终端选项 · $envLabel',
        items: [
          if (activeTab.terminalController.selection != null)
            GrassBagContextMenuItem(
              label: '复制选中文本',
              icon: CupertinoIcons.doc_on_doc,
              onTap: () => unawaited(_copySelection()),
            ),
          GrassBagContextMenuItem(
            label: '粘贴剪贴板',
            icon: CupertinoIcons.doc_on_clipboard,
            onTap: () => unawaited(_pasteClipboard()),
          ),
          GrassBagContextMenuItem(
            label: '字号大小 (${_fontSize.toStringAsFixed(1)} pt)',
            subtitle: '点击循环切换 11 / 12.5 / 14 pt',
            icon: CupertinoIcons.textformat_size,
            onTap: () {
              final next = _fontSize == 12.5 ? 14.0 : (_fontSize == 14.0 ? 11.0 : 12.5);
              setState(() => _fontSize = next);
              ref.read(appProvider.notifier).showToast(
                '终端字号已切换为 ${next.toStringAsFixed(1)} pt',
                tone: ToastTone.info,
              );
            },
          ),
          GrassBagContextMenuItem(
            label: '清屏',
            icon: CupertinoIcons.sparkles,
            dividerBefore: true,
            onTap: () {
              activeTab.terminal.write('\x1b[2J\x1b[H');
              if (activeTab.backend == _TermBackend.simulated) {
                activeTab.terminal.write('\x1b[32m${activeTab.cwd} ❯\x1b[0m ');
              }
            },
          ),
          GrassBagContextMenuItem(
            label: '重启当前终端',
            icon: CupertinoIcons.refresh,
            onTap: _restartActiveTab,
          ),
          if (_tabs.length > 1)
            GrassBagContextMenuItem(
              label: '关闭当前标签',
              icon: CupertinoIcons.xmark_circle_fill,
              destructive: true,
              dividerBefore: true,
              onTap: () => _closeTabAt(_activeIndex),
            ),
        ],
      ),
    );
  }

  static final RegExp _ansiEscapeRe = RegExp(r'\x1b\[[0-9;?]*[ -/]*[@-~]');

  static int _displayWidthOfGrapheme(String grapheme) {
    if (grapheme.isEmpty) return 0;
    final cp = grapheme.runes.first;
    // East Asian Wide / Fullwidth / CJK / Emoji ranges render 2 cells wide in terminal.
    if ((cp >= 0x1100 && cp <= 0x115F) ||
        (cp >= 0x2E80 && cp <= 0xA4CF) ||
        (cp >= 0xAC00 && cp <= 0xD7A3) ||
        (cp >= 0xF900 && cp <= 0xFAFF) ||
        (cp >= 0xFE10 && cp <= 0xFE6F) ||
        (cp >= 0xFF00 && cp <= 0xFF60) ||
        (cp >= 0xFFE0 && cp <= 0xFFE6) ||
        cp >= 0x1F300) {
      return 2;
    }
    return 1;
  }

  TerminalTheme? _cachedTerminalTheme;
  (GrassBagAccent, Color, Color)? _cachedTerminalThemeKey;

  TerminalTheme _resolveTerminalTheme(GrassBagTokens t) {
    final darkTokens = GrassBagTokens.resolve(t.accent, Brightness.dark);
    final key = (t.accent, darkTokens.codeBg, darkTokens.codeFg);
    if (_cachedTerminalTheme != null && _cachedTerminalThemeKey == key) {
      return _cachedTerminalTheme!;
    }
    final darkAccent = darkTokens.primaryHi;
    // Translucent block cursor (`alpha: 0.45`) so glyphs beneath the cursor remain 100% legible
    // across all 6 accent palettes including pure-white Graphite!
    final built = TerminalTheme(
      cursor: darkAccent.withValues(alpha: 0.45),
      selection: darkAccent.withValues(alpha: 0.35),
      foreground: darkTokens.codeFg,
      background: darkTokens.codeBg,
      black: const Color(0xFF1A2026),
      red: const Color(0xFFE69089),
      green: const Color(0xFF5DD199),
      yellow: const Color(0xFFEDB060),
      blue: const Color(0xFF8CB9D7),
      magenta: const Color(0xFFB8ABD2),
      cyan: const Color(0xFF72C6D8),
      white: const Color(0xFFE5EBF0),
      brightBlack: const Color(0xFF6B7D8C),
      brightRed: const Color(0xFFF3A7A1),
      brightGreen: const Color(0xFF7CE0AF),
      brightYellow: const Color(0xFFF4C582),
      brightBlue: const Color(0xFFA8D0EC),
      brightMagenta: const Color(0xFFCEC3E5),
      brightCyan: const Color(0xFF93DBE9),
      brightWhite: const Color(0xFFFFFFFF),
      searchHitBackground: const Color(0x66EDB060),
      searchHitBackgroundCurrent: const Color(0xAAEDB060),
      searchHitForeground: Colors.black,
    );
    _cachedTerminalThemeKey = key;
    _cachedTerminalTheme = built;
    return built;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(appProvider.select((s) => s.activeHostId), (prev, next) {
      if (prev != null && prev != next && next != _boundHostId) {
        _resetForHostSwitch();
      }
    });
    ref.listen<ConnectionPhase>(appProvider.select((s) => s.connectionPhase), (prev, next) {
      if (_tabs.isEmpty) return;
      if (next == ConnectionPhase.connected) {
        final appState = ref.read(appProvider);
        final live = ref.read(appProvider.notifier).liveClient;
        final isAndroidLocal =
            GrassBagNativeBridge.instance.isAndroidNative && appState.activeHost.isLocal;
        if (live != null) {
          _ensureWsSubscription(live);
        }
        if (!isAndroidLocal && live != null) {
          for (var ti = 0; ti < _tabs.length; ti++) {
            final item = _tabs[ti];
            final needsReattach = item.backend == _TermBackend.simulated ||
                (item.backend == _TermBackend.remoteWs &&
                    !item.attaching &&
                    (!identical(item.ownerClient, live) || item.exited));
            if (needsReattach) {
              if (ti == _activeIndex) {
                _restartActiveTab();
              } else if (!item.closed) {
                final prevTermId = item.remoteTermId;
                final prevSid = item.remoteSessionId;
                final prevOwner = item.ownerClient;
                if (item.wsChannel != null && prevOwner != null) {
                  prevOwner.stream.unsubscribe(item.wsChannel!);
                  item.wsChannel = null;
                }
                if (prevTermId != null && prevTermId.isNotEmpty) {
                  item.remoteTermId = null;
                  item.remoteSessionId = null;
                  unawaited(
                    live
                        .closeTerminal(prevTermId, sessionId: prevSid)
                        .catchError((_) => <String, dynamic>{}),
                  );
                }
                item.ownerClient = live;
                item.exited = false;
                unawaited(_attachRemotePty(item, live));
              }
            }
          }
        }
      } else if (next == ConnectionPhase.disconnected ||
          next == ConnectionPhase.error ||
          next == ConnectionPhase.needsAuth) {
        var changed = false;
        for (final t in _tabs) {
          if (t.backend == _TermBackend.remoteWs && !t.exited) {
            t.exited = true;
            t.terminal.write('\r\n\x1b[33m[主机连接已断开，重连后点击右上角「重连」恢复]\x1b[0m\r\n');
            changed = true;
          }
        }
        if (changed && mounted) setState(() {});
      }
    });
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          activeHostName: s.activeHost.name,
          isLocalHost: s.activeHost.isLocal,
        ),
      ),
    );
    final glassTier = slice.glassTier;
    final t = GrassBagTokens.of(context);
    final tab = _tabs[_activeIndex];
    final botPad = MediaQuery.viewPaddingOf(context).bottom;
    final restingBottomMargin = botPad > 0 ? botPad + 8.0 : 14.0;

    List<(String, String)> buildExtraKeys(bool hasSelection) => <(String, String)>[
          if (hasSelection) ('复制', 'copy'),
          ('粘贴', 'paste'),
          ('Esc', 'esc'),
          ('Tab', 'tab'),
          ('^C', 'ctrl_c'),
          (
            switch (_ctrl) {
              _ModLatch.off => 'Ctrl',
              _ModLatch.once => 'Ctrl•',
              _ModLatch.locked => 'CTRL',
            },
            'ctrl',
          ),
          (
            switch (_alt) {
              _ModLatch.off => 'Alt',
              _ModLatch.once => 'Alt•',
              _ModLatch.locked => 'ALT',
            },
            'alt',
          ),
          ('^D', 'ctrl_d'),
          ('^Z', 'ctrl_z'),
          ('←', 'left'),
          ('↑', 'up'),
          ('↓', 'down'),
          ('→', 'right'),
          ('Home', 'home'),
          ('End', 'end'),
          ('|', '|'),
          ('~', '~'),
          ('/', '/'),
          ('-', '-'),
        ];

    return GrassBagGlassPage(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            Column(
              children: [
                GrassBagUnifiedHeader(
                  title: '终端',
                  subtitle: '${slice.activeHostName} · ${_formatTerminalCwd(tab.cwd)}',
                  tier: glassTier,
                  floating: false,
                  onBack: () => Navigator.of(context).pop(),
                  trailing: (tab.exited || tab.backend == _TermBackend.simulated)
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GrassBagGlassPillButton(
                              onTap: _restartActiveTab,
                              tier: glassTier,
                              height: 36,
                              useOwnLayer: false,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(CupertinoIcons.refresh, size: 12.5, color: t.primary),
                                  const SizedBox(width: 4),
                                  Text(
                                    tab.backend == _TermBackend.simulated
                                        ? '重连主机'
                                        : (tab.backend == _TermBackend.remoteWs ? '重连' : '重启'),
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: t.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            GrassBagGlassCircleButton(
                              icon: CupertinoIcons.ellipsis,
                              tooltip: '更多',
                              tier: glassTier,
                              useOwnLayer: false,
                              onTap: _openMoreSheet,
                            ),
                          ],
                        )
                      : GrassBagGlassCircleButton(
                          icon: CupertinoIcons.ellipsis,
                          tooltip: '更多',
                          tier: glassTier,
                          useOwnLayer: false,
                          onTap: _openMoreSheet,
                        ),
                ),
                SizedBox(
                  height: 42,
                  child: ListView.separated(
                    controller: _tabScrollCtrl,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    itemCount: _tabs.length + 1,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, idx) {
                      if (idx == _tabs.length) {
                        return Center(
                          child: Tooltip(
                            message: '新建终端标签',
                            child: GrassBagSpringTap(
                              onTap: _addTab,
                              pressedScale: 0.90,
                              enablePointerGlow: false,
                              haptic: true,
                              child: GrassBagFresnelGlassSurface(
                                isCircle: true,
                                interactive: true,
                                width: 36,
                                height: 36,
                                alignment: Alignment.center,
                                child: Icon(CupertinoIcons.add, size: 17, color: t.text2),
                              ),
                            ),
                          ),
                        );
                      }
                      final item = _tabs[idx];
                      final active = idx == _activeIndex;
                      final canCloseInline = _tabs.length > 1;
                      final isSolid = glassTier == GrassBagGlassTier.solid;
                      return Center(
                        child: GrassBagSpringTap(
                          onTap: () {
                            if (_activeIndex == idx) return;
                            final hadFocus = _tabs.any((tabItem) => tabItem.focusNode.hasFocus);
                            setState(() {
                              _activeIndex = idx;
                              _ctrl = _ModLatch.off;
                              _alt = _ModLatch.off;
                            });
                            _tabPulseCtrl.forward(from: 0.0);
                            if (hadFocus) {
                              _focusTab(idx);
                            }
                          },
                          pressedScale: 0.94,
                          borderRadius: 999,
                          haptic: true,
                          child: CustomPaint(
                            foregroundPainter: isSolid
                                ? null
                                : GrassBagFresnelRimPainter(
                                    isDark: t.isDark,
                                    isPill: true,
                                    accent: active ? t.primary : t.primaryHi,
                                    innerWell: !active,
                                    frosted: glassTier == GrassBagGlassTier.frosted,
                                    paintTopSheen: active,
                                    strokeWidth: 0.85,
                                  ),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOutCubic,
                              height: 36,
                              padding: EdgeInsets.fromLTRB(
                                13,
                                0,
                                canCloseInline ? 4 : 13,
                                0,
                              ),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isSolid
                                    ? (active ? t.primarySoft : t.fill1)
                                    : null,
                                gradient: isSolid
                                    ? null
                                    : LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: active
                                            ? (t.isDark
                                                ? [
                                                    t.primary.withValues(alpha: 0.32),
                                                    t.primary.withValues(alpha: 0.15),
                                                  ]
                                                : [
                                                    Colors.white.withValues(alpha: 0.88),
                                                    Color.lerp(Colors.white, t.primary, 0.14)!
                                                        .withValues(alpha: 0.74),
                                                  ])
                                            : (t.isDark
                                                ? [
                                                    Colors.white.withValues(alpha: 0.12),
                                                    Colors.white.withValues(alpha: 0.05),
                                                  ]
                                                : [
                                                    Colors.white.withValues(alpha: 0.72),
                                                    Colors.white.withValues(alpha: 0.44),
                                                  ]),
                                      ),
                                borderRadius: BorderRadius.circular(999),
                                border: isSolid
                                    ? Border.all(
                                        color: active
                                            ? t.primary.withValues(alpha: t.isDark ? 0.50 : 0.34)
                                            : t.sep,
                                        width: 0.7,
                                      )
                                    : null,
                                boxShadow: active && !isSolid
                                    ? [
                                        BoxShadow(
                                          color: t.primary.withValues(alpha: t.isDark ? 0.24 : 0.14),
                                          blurRadius: 10,
                                          offset: const Offset(0, 2.5),
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  GrassBagStatusDot(
                                    size: 6.5,
                                    pulsing: item.attaching,
                                    color: (item.exited || item.closed)
                                        ? t.text3.withValues(alpha: 0.45)
                                        : (item.attaching
                                            ? t.primary
                                            : (item.backend == _TermBackend.simulated
                                                ? t.warn
                                                : (active
                                                    ? t.ok
                                                    : t.ok.withValues(alpha: 0.65)))),
                                  ),
                                  const SizedBox(width: 6.5),
                                  Text(
                                    item.title,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                                      color: active ? t.primary : t.text2,
                                    ),
                                  ),
                                  AnimatedSize(
                                    duration: const Duration(milliseconds: 170),
                                    curve: Curves.easeOutCubic,
                                    child: canCloseInline
                                        ? Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const SizedBox(width: 4),
                                              Tooltip(
                                                message: '关闭此终端',
                                                child: GestureDetector(
                                                  behavior: HitTestBehavior.opaque,
                                                  onTap: () {
                                                    HapticFeedback.selectionClick();
                                                    _closeTabAt(idx);
                                                  },
                                                  child: SizedBox(
                                                    width: 32,
                                                    height: 32,
                                                    child: Center(
                                                      child: Icon(
                                                        CupertinoIcons.xmark,
                                                        size: 12.5,
                                                        color: active ? t.primary : t.text3,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _TerminalKeyboardMargin(
                    restingBottomMargin: restingBottomMargin,
                    child: () {
                      final darkTerm = GrassBagTokens.resolve(t.accent, Brightness.dark);
                      final consoleTier = resolveAmbientGlassTier(context);
                      final consoleSolid = consoleTier == GrassBagGlassTier.solid;
                      final consoleCard = DecoratedBox(
                        decoration: ShapeDecoration(
                          color: darkTerm.codeBg,
                          shape: RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.circular(24),
                            side: consoleSolid
                                ? BorderSide(
                                    color: t.isDark
                                        ? Colors.white.withValues(alpha: 0.11)
                                        : const Color(0xFF2B3746),
                                    width: t.isDark ? 0.7 : 1.1,
                                  )
                                : (!t.isDark
                                    ? const BorderSide(
                                        color: Color(0x360B1726),
                                        width: 0.85,
                                      )
                                    : BorderSide.none),
                          ),
                          shadows: t.isDark
                              ? [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.28),
                                    blurRadius: 20,
                                    offset: const Offset(0, 8),
                                  ),
                                ]
                              : const [
                                  BoxShadow(
                                    color: Color(0x220B1726),
                                    blurRadius: 22,
                                    offset: Offset(0, 8),
                                  ),
                                ],
                        ),
                        child: ClipRSuperellipse(
                          borderRadius: BorderRadius.circular(24),
                          child: Column(
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
                                  // Keep all open tabs mounted via IndexedStack so switching tabs
                                  // preserves scrollback offset, text selection & soft-keyboard focus!
                                  // GrassBagControlledOpacity elides OpacityLayer completely at 1.0.
                                  child: AnimatedBuilder(
                                    animation: _tabPulseOpacity,
                                    builder: (_, child) => GrassBagControlledOpacity(
                                      opacity: _tabPulseOpacity.value,
                                      child: child,
                                    ),
                                    child: Stack(
                                      children: [
                                        IndexedStack(
                                          index: _activeIndex,
                                          children: [
                                            for (var idx = 0; idx < _tabs.length; idx++)
                                              () {
                                                final item = _tabs[idx];
                                                return TickerMode(
                                                  key: ValueKey(item.id),
                                                  enabled: idx == _activeIndex,
                                                  child: RepaintBoundary(
                                                    child: TerminalView(
                                                      item.terminal,
                                                      key: item.viewKey,
                                                      controller: item.terminalController,
                                                      scrollController: item.scrollController,
                                                      focusNode: item.focusNode,
                                                      onSecondaryTapDown: (details, _) {
                                                        _openMoreSheet(anchor: details.globalPosition);
                                                      },
                                                      deleteDetection: !kIsWeb &&
                                                          (defaultTargetPlatform == TargetPlatform.android ||
                                                              defaultTargetPlatform == TargetPlatform.iOS),
                                                      keyboardType: TextInputType.visiblePassword,
                                                      alwaysShowCursor: true,
                                                      textStyle: TerminalStyle(
                                                        fontSize: _fontSize,
                                                        fontFamily: kIsWeb ? 'Menlo' : 'monospace',
                                                        fontFamilyFallback: const [
                                                          'SF Mono',
                                                          'Monaco',
                                                          'Consolas',
                                                          'Liberation Mono',
                                                          'Courier New',
                                                          'monospace',
                                                        ],
                                                      ),
                                                      theme: _resolveTerminalTheme(t),
                                                      autofocus: false,
                                                    ),
                                                  ),
                                                );
                                              }(),
                                          ],
                                        ),
                                        Positioned(
                                          right: 6,
                                          bottom: 6,
                                          child: ListenableBuilder(
                                            listenable: tab.scrollController,
                                            builder: (_, __) {
                                              final sc = tab.scrollController;
                                              final scrolledUp = sc.hasClients &&
                                                  sc.positions.length == 1 &&
                                                  sc.position.hasContentDimensions &&
                                                  sc.position.hasPixels &&
                                                  (sc.position.maxScrollExtent - sc.offset) > 80.0;
                                              if (!scrolledUp) return const SizedBox.shrink();
                                              return GrassBagSpringTap(
                                                onTap: () => _scrollTabToBottomAndFocus(tab),
                                                pressedScale: 0.90,
                                                borderRadius: 999,
                                                haptic: true,
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 6,
                                                  ),
                                                  decoration: ShapeDecoration(
                                                    color: darkTerm.codeBar.withValues(alpha: 0.92),
                                                    shape: StadiumBorder(
                                                      side: BorderSide(
                                                        color: Colors.white.withValues(alpha: 0.16),
                                                        width: 0.7,
                                                      ),
                                                    ),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        CupertinoIcons.arrow_down,
                                                        size: 12,
                                                        color: darkTerm.primaryHi,
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                        '回到底部',
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.w600,
                                                          color: darkTerm.codeFg,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              if ((!kIsWeb &&
                                      (defaultTargetPlatform == TargetPlatform.android ||
                                          defaultTargetPlatform == TargetPlatform.iOS)) ||
                                  MediaQuery.sizeOf(context).width < 840)
                                ListenableBuilder(
                                  listenable: tab.terminalController,
                                  builder: (_, __) {
                                    final extraKeys =
                                        buildExtraKeys(tab.terminalController.selection != null);
                                    return Container(
                                      height: 52,
                                      decoration: BoxDecoration(
                                        color: darkTerm.codeBar,
                                        border: Border(
                                          top: BorderSide(
                                            color: Colors.white.withValues(alpha: 0.08),
                                            width: 0.5,
                                          ),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Stack(
                                              children: [
                                                ListView.separated(
                                                  controller: _extraKeysScrollCtrl,
                                                  scrollDirection: Axis.horizontal,
                                                  physics: const BouncingScrollPhysics(),
                                                  padding: const EdgeInsets.fromLTRB(10, 7, 28, 7),
                                                  itemCount: extraKeys.length,
                                                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                                                  itemBuilder: (_, i) {
                                                    final k = extraKeys[i];
                                                    final latch = k.$2 == 'ctrl'
                                                        ? _ctrl
                                                        : (k.$2 == 'alt' ? _alt : _ModLatch.off);
                                                    final isActive = latch != _ModLatch.off ||
                                                        k.$2 == 'copy';
                                                    final darkAccent = darkTerm.primaryHi;
                                                    final repeatable = k.$2 == 'left' ||
                                                        k.$2 == 'up' ||
                                                        k.$2 == 'down' ||
                                                        k.$2 == 'right' ||
                                                        k.$2 == 'tab';
                                                    final keyCore = Container(
                                                      constraints: const BoxConstraints(minWidth: 42),
                                                      padding: const EdgeInsets.symmetric(horizontal: 11),
                                                      alignment: Alignment.center,
                                                      decoration: ShapeDecoration(
                                                        color: consoleSolid
                                                            ? (latch == _ModLatch.locked
                                                                ? darkAccent.withValues(alpha: 0.36)
                                                                : (isActive
                                                                    ? darkAccent.withValues(alpha: 0.22)
                                                                    : Colors.white.withValues(alpha: 0.085)))
                                                            : null,
                                                        gradient: consoleSolid
                                                            ? null
                                                            : LinearGradient(
                                                                begin: Alignment.topLeft,
                                                                end: Alignment.bottomRight,
                                                                colors: latch == _ModLatch.locked
                                                                    ? [
                                                                        darkAccent.withValues(alpha: 0.44),
                                                                        darkAccent.withValues(alpha: 0.24),
                                                                      ]
                                                                    : (isActive
                                                                        ? [
                                                                            darkAccent.withValues(alpha: 0.30),
                                                                            darkAccent.withValues(alpha: 0.15),
                                                                          ]
                                                                        : [
                                                                            Colors.white.withValues(alpha: 0.135),
                                                                            Colors.white.withValues(alpha: 0.055),
                                                                          ]),
                                                              ),
                                                        shape: RoundedSuperellipseBorder(
                                                          borderRadius: BorderRadius.circular(10),
                                                          side: latch == _ModLatch.locked
                                                              ? BorderSide(color: darkAccent, width: 1.2)
                                                              : (latch == _ModLatch.once
                                                                  ? BorderSide(
                                                                      color: darkAccent.withValues(alpha: 0.55),
                                                                      width: 0.8,
                                                                    )
                                                                  : (consoleSolid
                                                                      ? BorderSide(
                                                                          color: Colors.white.withValues(alpha: 0.07),
                                                                          width: 0.5,
                                                                        )
                                                                      : BorderSide.none)),
                                                        ),
                                                      ),
                                                      child: Text(
                                                        k.$1,
                                                        style: TextStyle(
                                                          fontFamily: 'monospace',
                                                          fontSize: 12,
                                                          fontWeight: FontWeight.w600,
                                                          color: isActive ? darkAccent : darkTerm.codeFg,
                                                        ),
                                                      ),
                                                    );
                                                    final pill = (consoleSolid || latch == _ModLatch.locked)
                                                        ? keyCore
                                                        : CustomPaint(
                                                            foregroundPainter: GrassBagFresnelRimPainter(
                                                              isDark: true,
                                                              borderRadius: 10,
                                                              accent: isActive ? darkAccent : null,
                                                              innerWell: !isActive,
                                                              frosted: consoleTier == GrassBagGlassTier.frosted,
                                                              paintTopSheen: false,
                                                              strokeWidth: 0.72,
                                                            ),
                                                            child: keyCore,
                                                          );
                                                    if (repeatable) {
                                                      return _RepeatableTerminalKey(
                                                        onFire: () => _sendExtraKey(k.$2),
                                                        child: pill,
                                                      );
                                                    }
                                                    return GrassBagSpringTap(
                                                      onTap: () => _sendExtraKey(k.$2),
                                                      pressedScale: 0.90,
                                                      borderRadius: 10,
                                                      haptic: true,
                                                      child: pill,
                                                    );
                                                  },
                                                ),
                                                Positioned(
                                                  left: 0,
                                                  top: 0,
                                                  bottom: 0,
                                                  width: 20,
                                                  child: IgnorePointer(
                                                    child: ListenableBuilder(
                                                      listenable: _extraKeysScrollCtrl,
                                                      builder: (_, __) {
                                                        final scrolled = _extraKeysScrollCtrl.hasClients &&
                                                            _extraKeysScrollCtrl.positions.length == 1 &&
                                                            _extraKeysScrollCtrl.position.hasPixels &&
                                                            _extraKeysScrollCtrl.offset > 2.0;
                                                        if (!scrolled) return const SizedBox.shrink();
                                                        return DecoratedBox(
                                                          decoration: BoxDecoration(
                                                            gradient: LinearGradient(
                                                              begin: Alignment.centerLeft,
                                                              end: Alignment.centerRight,
                                                              colors: [
                                                                darkTerm.codeBar,
                                                                darkTerm.codeBar.withValues(alpha: 0.0),
                                                              ],
                                                            ),
                                                          ),
                                                        );
                                                      },
                                                    ),
                                                  ),
                                                ),
                                                Positioned(
                                                  right: 0,
                                                  top: 0,
                                                  bottom: 0,
                                                  width: 32,
                                                  child: IgnorePointer(
                                                    child: ListenableBuilder(
                                                      listenable: _extraKeysScrollCtrl,
                                                      builder: (_, __) {
                                                        final hasMoreRight = !_extraKeysScrollCtrl.hasClients ||
                                                            _extraKeysScrollCtrl.positions.length != 1 ||
                                                            !_extraKeysScrollCtrl.position.hasContentDimensions ||
                                                            (_extraKeysScrollCtrl.position.maxScrollExtent > 2.0 &&
                                                                _extraKeysScrollCtrl.position.pixels <
                                                                    _extraKeysScrollCtrl.position.maxScrollExtent - 2.0);
                                                        if (!hasMoreRight) return const SizedBox.shrink();
                                                        return DecoratedBox(
                                                          decoration: BoxDecoration(
                                                            gradient: LinearGradient(
                                                              begin: Alignment.centerLeft,
                                                              end: Alignment.centerRight,
                                                              colors: [
                                                                darkTerm.codeBar.withValues(alpha: 0.0),
                                                                darkTerm.codeBar.withValues(alpha: 0.82),
                                                                darkTerm.codeBar,
                                                              ],
                                                              stops: const [0.0, 0.62, 0.88],
                                                            ),
                                                          ),
                                                        );
                                                      },
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (tab.terminalController.selection != null)
                                            Padding(
                                              padding: const EdgeInsets.fromLTRB(4, 7, 4, 7),
                                              child: GrassBagSpringTap(
                                                onTap: () => _sendExtraKey('copy'),
                                                pressedScale: 0.90,
                                                borderRadius: 10,
                                                haptic: true,
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                                  alignment: Alignment.center,
                                                  decoration: ShapeDecoration(
                                                    color: darkTerm.primaryHi.withValues(alpha: 0.24),
                                                    shape: RoundedSuperellipseBorder(
                                                      borderRadius: BorderRadius.circular(10),
                                                      side: BorderSide(
                                                        color: darkTerm.primaryHi.withValues(alpha: 0.48),
                                                        width: 0.7,
                                                      ),
                                                    ),
                                                  ),
                                                  child: Text(
                                                    '复制',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w600,
                                                      color: darkTerm.primaryHi,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          if (!kIsWeb &&
                                              (defaultTargetPlatform == TargetPlatform.android ||
                                                  defaultTargetPlatform == TargetPlatform.iOS)) ...[
                                            Container(
                                              width: 0.9,
                                              height: 24,
                                              color: Colors.white.withValues(alpha: 0.22),
                                            ),
                                            Padding(
                                              padding: const EdgeInsets.fromLTRB(6, 7, 8, 7),
                                              child: Builder(
                                                builder: (kbCtx) {
                                                  final kbOpen = _TerminalKeyboardScope.isOpenOf(kbCtx);
                                                  return Tooltip(
                                                    message: kbOpen ? '收起键盘' : '唤起键盘',
                                                    child: GrassBagSpringTap(
                                                      onTap: () {
                                                        if (kbOpen) {
                                                          _sendExtraKey('hide_kb');
                                                        } else {
                                                          _scrollTabToBottomAndFocus(tab);
                                                          final viewState = tab.viewKey.currentState;
                                                          if (viewState != null) {
                                                            viewState.requestKeyboard();
                                                          } else {
                                                            unawaited(
                                                              SystemChannels.textInput
                                                                  .invokeMethod<void>('TextInput.show'),
                                                            );
                                                          }
                                                        }
                                                      },
                                                      pressedScale: 0.90,
                                                      borderRadius: 10,
                                                      haptic: true,
                                                      child: CustomPaint(
                                                        foregroundPainter: consoleSolid
                                                            ? null
                                                            : GrassBagFresnelRimPainter(
                                                                isDark: true,
                                                                borderRadius: 10,
                                                                innerWell: true,
                                                                frosted: consoleTier == GrassBagGlassTier.frosted,
                                                                paintTopSheen: false,
                                                                strokeWidth: 0.72,
                                                              ),
                                                        child: Container(
                                                          width: 40,
                                                          alignment: Alignment.center,
                                                          decoration: ShapeDecoration(
                                                            color: consoleSolid
                                                                ? Colors.white.withValues(alpha: 0.085)
                                                                : null,
                                                            gradient: consoleSolid
                                                                ? null
                                                                : LinearGradient(
                                                                    begin: Alignment.topLeft,
                                                                    end: Alignment.bottomRight,
                                                                    colors: [
                                                                      Colors.white.withValues(alpha: 0.135),
                                                                      Colors.white.withValues(alpha: 0.055),
                                                                    ],
                                                                  ),
                                                            shape: RoundedSuperellipseBorder(
                                                              borderRadius: BorderRadius.circular(10),
                                                              side: consoleSolid
                                                                  ? BorderSide(
                                                                      color: Colors.white.withValues(alpha: 0.07),
                                                                      width: 0.5,
                                                                    )
                                                                  : BorderSide.none,
                                                            ),
                                                          ),
                                                          child: Icon(
                                                            kbOpen
                                                                ? CupertinoIcons.keyboard_chevron_compact_down
                                                                : CupertinoIcons.keyboard,
                                                            size: 17,
                                                            color: darkTerm.codeFg,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  );
                                                },
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                      if (consoleSolid) return consoleCard;
                      return CustomPaint(
                        foregroundPainter: GrassBagFresnelRimPainter(
                          isDark: true,
                          borderRadius: 24,
                          accent: darkTerm.primaryHi,
                          frosted: consoleTier == GrassBagGlassTier.frosted,
                          paintTopSheen: false,
                          strokeWidth: 0.95,
                        ),
                        child: consoleCard,
                      );
                    }(),
                  ),
                ),
              ],
            ),
            GrassBagToastOverlay(
              bottomOffset: restingBottomMargin + 56.0,
              includeKeyboardInset: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalTermTab {
  _LocalTermTab({
    required this.id,
    required this.hostId,
    required this.title,
    required this.cwd,
    required this.terminal,
    required this.backend,
    this.ownerClient,
  });

  final String id;
  final String hostId;
  final String title;
  final String cwd;
  final Terminal terminal;
  final GlobalKey<TerminalViewState> viewKey = GlobalKey<TerminalViewState>();
  final TerminalController terminalController = TerminalController();
  final ScrollController scrollController = ScrollController();
  final FocusNode focusNode = FocusNode();
  _TermBackend backend;
  GbridgeClient? ownerClient;
  bool isLocalPty = false;
  bool localModeLocked = false;
  bool closed = false;
  bool exited = false;
  bool attaching = false;
  int lastCols = 80;
  int lastRows = 24;
  int sentCols = -1;
  int sentRows = -1;
  Timer? resizeDebounce;
  Timer? streamRetryTimer;
  int streamRetryCount = 0;
  bool streamReconnecting = false;
  String? remoteTermId;
  String? remoteSessionId;
  String? wsChannel;

  bool _disposed = false;

  void disposeResources() {
    if (_disposed) return;
    _disposed = true;
    resizeDebounce?.cancel();
    resizeDebounce = null;
    streamRetryTimer?.cancel();
    streamRetryTimer = null;
    terminalController.dispose();
    scrollController.dispose();
    focusNode.dispose();
  }
}

/// Repeatable soft-key button for arrow/Tab keys: fires immediately on tap and auto-repeats
/// at 65ms intervals after a 350ms hold, cancelling cleanly on lift, drag-away, or dispose.
class _RepeatableTerminalKey extends StatefulWidget {
  const _RepeatableTerminalKey({
    required this.onFire,
    required this.child,
  });

  final VoidCallback onFire;
  final Widget child;

  @override
  State<_RepeatableTerminalKey> createState() => _RepeatableTerminalKeyState();
}

class _RepeatableTerminalKeyState extends State<_RepeatableTerminalKey> {
  Timer? _holdTimer;
  Timer? _repeatTimer;
  bool _pressed = false;
  bool _repeated = false;

  void _cancelTimers() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        _repeated = false;
        if (!_pressed) setState(() => _pressed = true);
        _cancelTimers();
        _holdTimer = Timer(const Duration(milliseconds: 350), () {
          if (!mounted) return;
          _repeated = true;
          HapticFeedback.selectionClick();
          widget.onFire();
          _repeatTimer = Timer.periodic(const Duration(milliseconds: 65), (_) {
            if (!mounted) {
              _cancelTimers();
              return;
            }
            widget.onFire();
          });
        });
      },
      onTapUp: (_) {
        _cancelTimers();
        if (_pressed) setState(() => _pressed = false);
        if (!_repeated) {
          HapticFeedback.selectionClick();
          widget.onFire();
        }
      },
      onTapCancel: () {
        _cancelTimers();
        if (_pressed) setState(() => _pressed = false);
      },
      child: AnimatedScale(
        scale: _pressed ? 0.90 : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

/// Isolates `MediaQuery.viewInsetsOf` and settles the bottom padding 70ms after IME flight
/// so `xterm`'s `TerminalView` runs `terminal.resize()` ONCE instead of 30x per keyboard open,
/// while preserving all ambient MediaQuery accessibility & gesture settings!
class _TerminalKeyboardScope extends InheritedWidget {
  const _TerminalKeyboardScope({
    required this.kbOpen,
    required super.child,
  });

  final bool kbOpen;

  static bool isOpenOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<_TerminalKeyboardScope>()
            ?.kbOpen ??
        false;
  }

  @override
  bool updateShouldNotify(_TerminalKeyboardScope oldWidget) =>
      oldWidget.kbOpen != kbOpen;
}

class _TerminalKeyboardMargin extends StatelessWidget {
  const _TerminalKeyboardMargin({
    required this.restingBottomMargin,
    required this.child,
  });

  final double restingBottomMargin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Track live IME inset smoothly without freezing 320ms behind the keyboard;
    // propagate `kbOpen` BEFORE `removeViewInsets(removeBottom: true)` so the pinned
    // keyboard toggle button always knows when the IME is open!
    final kbInset = MediaQuery.viewInsetsOf(context).bottom;
    final bottom = math.max(restingBottomMargin, kbInset + 6.0);
    return _TerminalKeyboardScope(
      kbOpen: kbInset > 40.0,
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 0, 12, bottom),
          child: child,
        ),
      ),
    );
  }
}
