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
  late final AnimationController _tabPulseCtrl;
  late final Animation<double> _tabPulseOpacity;
  int _activeIndex = 0;
  int _tabLabelSeq = 1;
  _ModLatch _ctrl = _ModLatch.off;
  _ModLatch _alt = _ModLatch.off;
  double _fontSize = 12.5;
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
    _focusTab(_activeIndex);
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
    final ws = appState.activeWorkspaceDisplayName;
    _boundHostId = host.id;

    // Strictly isolate host backends: Android local shell is ONLY allowed for `host.isLocal`!
    final canUseAndroidLocal = native.isAndroidNative && host.isLocal;

    if (live != null && !canUseAndroidLocal) {
      _ensureWsSubscription(live);
      final tab = _createTab(
        id: _nextTabId(host.id),
        hostId: host.id,
        title: 'shell',
        cwd: ws.isEmpty ? '~' : ws,
        backend: _TermBackend.remoteWs,
        ownerClient: live,
      );
      _tabs.add(tab);
      unawaited(_attachRemotePty(tab, live));
    } else if (canUseAndroidLocal) {
      final localCwd = _resolveLocalCwd(appState);
      final tab = _createTab(
        id: _nextTabId(host.id),
        hostId: host.id,
        title: 'bash',
        cwd: localCwd,
        backend: _TermBackend.androidLocal,
        bootLines: const [
          '\x1b[90m正在启动本机 Ubuntu 24.04.5 容器 Shell…\x1b[0m',
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
          cwd: ws.isEmpty ? '~' : ws,
          backend: _TermBackend.simulated,
          bootLines: [
            '\x1b[33m$notice\x1b[0m',
            '\x1b[90m连接就绪后可点击右上角重启或自动接入 PTY。\x1b[0m',
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
        : (appState.activeWorkspaceDisplayName.isEmpty ? '~' : appState.activeWorkspaceDisplayName);
    final replacement = _createTab(
      id: _nextTabId(host.id),
      hostId: host.id,
      title: old.title,
      cwd: cwd,
      backend: backend,
      ownerClient: backend == _TermBackend.remoteWs ? live : null,
      bootLines: backend == _TermBackend.simulated
          ? ['\x1b[33m主机「${host.name}」尚未连接，暂无法打开远程 PTY。\x1b[0m']
          : const [],
    );
    setState(() {
      _tabs[_activeIndex] = replacement;
    });
    _teardownTabs([old], deferResourceDispose: true);
    _focusTab(_activeIndex);
    if (backend == _TermBackend.remoteWs && live != null) {
      unawaited(_attachRemotePty(replacement, live));
    } else if (backend == _TermBackend.androidLocal) {
      _nativeSub ??= native.events.listen(_onNativeEvent);
      unawaited(_tryUpgradeToAndroidLocalShell(replacement));
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
    if (type == 'term.exit' || type == 'terminal.exit' || type == 'terminal.stream_end') {
      _flushPtyBuffers();
      final code = data?['exitCode'] ?? data?['code'];
      final exitNote = code != null ? '[远端 PTY 已退出 code=$code]' : '[远端 PTY 流已结束]';
      target.terminal.write('\r\n\x1b[90m$exitNote\x1b[0m\r\n');
      if (!target.exited) {
        setState(() => target!.exited = true);
      }
      return;
    }
    if (type == 'terminal.stream_error' || type == 'terminal.unavailable') {
      _flushPtyBuffers();
      final msg = data?['message']?.toString() ?? data?['error']?.toString() ?? '远端 PTY 连接中断';
      target.terminal.write('\r\n\x1b[31m[$msg]\x1b[0m\r\n');
      if (!target.exited) {
        setState(() => target!.exited = true);
      }
      return;
    }

    final chunk = data?['data']?.toString() ?? data?['chunk']?.toString() ?? '';
    if (chunk.isNotEmpty) {
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
    tab.ownerClient = client;
    tab.attaching = true;
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
        tab.remoteTermId = remoteId;
        tab.remoteSessionId = resolvedSid;
        tab.wsChannel = (resolvedSid != null && resolvedSid.isNotEmpty)
            ? 'terminal:$resolvedSid:$remoteId'
            : 'terminal:$remoteId';
        tab.attaching = false;
        if (tab.exited && mounted) {
          setState(() => tab.exited = false);
        } else {
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
      tab.attaching = false;
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
    if (_ctrl != _ModLatch.off && out.length == 1) {
      final code = out.toLowerCase().codeUnitAt(0);
      if (code >= 97 && code <= 122) {
        out = String.fromCharCode(code - 96);
      } else if (out == '[') {
        out = '\x1b';
      } else if (out == '\\') {
        out = '\x1c';
      } else if (out == ']') {
        out = '\x1d';
      } else if (out == '@' || out == ' ') {
        out = '\x00';
      } else if (out == '^') {
        out = '\x1e';
      } else if (out == '_') {
        out = '\x1f';
      }
    }
    if (_alt != _ModLatch.off && out.isNotEmpty) {
      out = '\x1b$out';
    }
    final clearCtrl = _ctrl == _ModLatch.once;
    final clearAlt = _alt == _ModLatch.once;
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
            tab.terminal.write('\r\n\x1b[33m[远程 PTY 连接已断开，点击右上角「重连终端」恢复]\x1b[0m\r\n');
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
    final ws = appState.activeWorkspaceDisplayName;
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
          : (ws.isEmpty ? '~' : ((ws.startsWith('/') || ws.startsWith('~')) ? ws : '~/$ws')),
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
      setState(() {
        _ctrl = switch (_ctrl) {
          _ModLatch.off => _ModLatch.once,
          _ModLatch.once => _ModLatch.locked,
          _ModLatch.locked => _ModLatch.off,
        };
      });
      _scrollTabToBottomAndFocus(tab);
      return;
    }
    if (key == 'alt') {
      setState(() {
        _alt = switch (_alt) {
          _ModLatch.off => _ModLatch.once,
          _ModLatch.once => _ModLatch.locked,
          _ModLatch.locked => _ModLatch.off,
        };
      });
      _scrollTabToBottomAndFocus(tab);
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
      final clearAlt = _alt == _ModLatch.once;
      if (clearCtrl || clearAlt) {
        setState(() {
          if (clearCtrl) _ctrl = _ModLatch.off;
          if (clearAlt) _alt = _ModLatch.off;
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
              setState(() {
                _fontSize = _fontSize == 12.5 ? 14.0 : (_fontSize == 14.0 ? 11.0 : 12.5);
              });
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
    final key = (t.accent, t.codeBg, t.codeFg);
    if (_cachedTerminalTheme != null && _cachedTerminalThemeKey == key) {
      return _cachedTerminalTheme!;
    }
    final darkAccent = GrassBagTokens.resolve(t.accent, Brightness.dark).primaryHi;
    final built = TerminalTheme(
      cursor: darkAccent,
      selection: darkAccent.withValues(alpha: 0.35),
      foreground: t.codeFg,
      background: t.codeBg,
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
        final active = _tabs[_activeIndex];
        final appState = ref.read(appProvider);
        final live = ref.read(appProvider.notifier).liveClient;
        final isAndroidLocal =
            GrassBagNativeBridge.instance.isAndroidNative && appState.activeHost.isLocal;
        if (live != null) {
          _ensureWsSubscription(live);
        }
        if (!isAndroidLocal && live != null) {
          if (active.backend == _TermBackend.simulated) {
            _restartActiveTab();
          } else if (active.backend == _TermBackend.remoteWs &&
              !active.attaching &&
              !identical(active.ownerClient, live)) {
            _restartActiveTab();
          }
        }
      } else if (next == ConnectionPhase.disconnected ||
          next == ConnectionPhase.error ||
          next == ConnectionPhase.needsAuth) {
        var changed = false;
        for (final t in _tabs) {
          if (t.backend == _TermBackend.remoteWs && !t.exited) {
            t.exited = true;
            t.terminal.write('\r\n\x1b[33m[主机连接已断开，重连后点击右上角「重连终端」]\x1b[0m\r\n');
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
                  subtitle: '${slice.activeHostName} · ${tab.cwd}',
                  tier: glassTier,
                  floating: false,
                  onBack: () => Navigator.of(context).pop(),
                  trailing: tab.exited
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GrassBagSpringTap(
                              onTap: _restartActiveTab,
                              pressedScale: 0.94,
                              haptic: true,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: t.primarySoft,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  tab.backend == _TermBackend.remoteWs ? '重连' : '重启',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: t.primary,
                                  ),
                                ),
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
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    itemCount: _tabs.length + 1,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, idx) {
                      if (idx == _tabs.length) {
                        return Center(
                          child: GrassBagSpringTap(
                            onTap: _addTab,
                            pressedScale: 0.90,
                            haptic: true,
                            child: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: t.fill1,
                                shape: BoxShape.circle,
                                border: Border.all(color: t.sep, width: 0.65),
                              ),
                              child: Icon(CupertinoIcons.add, size: 17, color: t.text2),
                            ),
                          ),
                        );
                      }
                      final item = _tabs[idx];
                      final active = idx == _activeIndex;
                      final canCloseInline = active && _tabs.length > 1;
                      return Center(
                        child: GrassBagSpringTap(
                          onTap: () {
                            if (_activeIndex == idx) return;
                            setState(() {
                              _activeIndex = idx;
                              _ctrl = _ModLatch.off;
                              _alt = _ModLatch.off;
                            });
                            _tabPulseCtrl.forward(from: 0.0);
                            _focusTab(idx);
                          },
                          pressedScale: 0.94,
                          haptic: true,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            padding: EdgeInsets.fromLTRB(
                              13,
                              4,
                              canCloseInline ? 4 : 13,
                              4,
                            ),
                            decoration: BoxDecoration(
                              color: active ? t.primarySoft : t.fill1,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: active ? t.primary.withValues(alpha: 0.45) : t.sep,
                                width: 0.7,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
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
                                            GestureDetector(
                                              behavior: HitTestBehavior.opaque,
                                              onTap: () => _closeTabAt(idx),
                                              child: SizedBox(
                                                width: 28,
                                                height: 28,
                                                child: Center(
                                                  child: Icon(
                                                    CupertinoIcons.xmark,
                                                    size: 12.5,
                                                    color: t.primary,
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
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _TerminalKeyboardMargin(
                    restingBottomMargin: restingBottomMargin,
                    child: ClipRSuperellipse(
                      borderRadius: BorderRadius.circular(24),
                      child: Container(
                        decoration: ShapeDecoration(
                          color: t.codeBg,
                          shape: RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.circular(24),
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.09),
                              width: 0.65,
                            ),
                          ),
                        ),
                        child: Column(
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
                                child: RepaintBoundary(
                                  // Aspect-isolated MediaQuery avoids subscribing to `viewInsets`
                                  // (unlike `MediaQuery.removePadding`), eliminating 120Hz IME rebuild storms!
                                  child: MediaQuery(
                                    data: MediaQueryData(
                                      size: MediaQuery.sizeOf(context),
                                      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                                      textScaler: MediaQuery.textScalerOf(context),
                                      platformBrightness: MediaQuery.platformBrightnessOf(context),
                                    ),
                                    // Keep all open tabs mounted via IndexedStack so switching tabs
                                    // preserves scrollback offset, text selection & soft-keyboard focus!
                                    child: FadeTransition(
                                      opacity: _tabPulseOpacity,
                                      child: IndexedStack(
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
                                                  controller: item.terminalController,
                                                  scrollController: item.scrollController,
                                                  focusNode: item.focusNode,
                                                  onSecondaryTapDown: (details, _) {
                                                    _openMoreSheet(anchor: details.globalPosition);
                                                  },
                                                  deleteDetection: !kIsWeb &&
                                                      (defaultTargetPlatform == TargetPlatform.android ||
                                                          defaultTargetPlatform == TargetPlatform.iOS),
                                                  keyboardType: TextInputType.text,
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
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (!kIsWeb || MediaQuery.sizeOf(context).width < 840)
                              ListenableBuilder(
                                listenable: tab.terminalController,
                                builder: (_, __) {
                                  final extraKeys =
                                      buildExtraKeys(tab.terminalController.selection != null);
                                  return Container(
                                    height: 46,
                                    decoration: BoxDecoration(
                                      color: t.codeBar,
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
                                          child: ListView.separated(
                                            scrollDirection: Axis.horizontal,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 6,
                                            ),
                                            itemCount: extraKeys.length,
                                            separatorBuilder: (_, __) => const SizedBox(width: 6),
                                            itemBuilder: (_, i) {
                                              final k = extraKeys[i];
                                              final latch = k.$2 == 'ctrl'
                                                  ? _ctrl
                                                  : (k.$2 == 'alt' ? _alt : _ModLatch.off);
                                              final isActive = latch != _ModLatch.off ||
                                                  k.$2 == 'copy';
                                              final darkAccent = GrassBagTokens.resolve(
                                                t.accent,
                                                Brightness.dark,
                                              ).primaryHi;
                                              return GrassBagSpringTap(
                                                onTap: () => _sendExtraKey(k.$2),
                                                pressedScale: 0.90,
                                                haptic: true,
                                                child: Container(
                                                  constraints: const BoxConstraints(minWidth: 40),
                                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                                  alignment: Alignment.center,
                                                  decoration: ShapeDecoration(
                                                    color: latch == _ModLatch.locked
                                                        ? darkAccent.withValues(alpha: 0.36)
                                                        : (isActive
                                                            ? darkAccent.withValues(alpha: 0.22)
                                                            : Colors.white.withValues(alpha: 0.085)),
                                                    shape: RoundedSuperellipseBorder(
                                                      borderRadius: BorderRadius.circular(10),
                                                      side: latch == _ModLatch.locked
                                                          ? BorderSide(color: darkAccent, width: 1.2)
                                                          : (latch == _ModLatch.once
                                                              ? BorderSide(
                                                                  color: darkAccent.withValues(alpha: 0.55),
                                                                  width: 0.8,
                                                                )
                                                              : BorderSide(
                                                                  color: Colors.white.withValues(alpha: 0.07),
                                                                  width: 0.5,
                                                                )),
                                                    ),
                                                  ),
                                                  child: Text(
                                                    k.$1,
                                                    style: TextStyle(
                                                      fontFamily: 'monospace',
                                                      fontSize: 11.5,
                                                      fontWeight: FontWeight.w600,
                                                      color: isActive ? darkAccent : t.codeFg,
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                        if (!kIsWeb &&
                                            (defaultTargetPlatform == TargetPlatform.android ||
                                                defaultTargetPlatform == TargetPlatform.iOS))
                                          Padding(
                                            padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
                                            child: Tooltip(
                                              message: '收起键盘',
                                              child: GrassBagSpringTap(
                                                onTap: () => _sendExtraKey('hide_kb'),
                                                pressedScale: 0.90,
                                                haptic: true,
                                                child: Container(
                                                  width: 38,
                                                  alignment: Alignment.center,
                                                  decoration: ShapeDecoration(
                                                    color: Colors.white.withValues(alpha: 0.085),
                                                    shape: RoundedSuperellipseBorder(
                                                      borderRadius: BorderRadius.circular(10),
                                                      side: BorderSide(
                                                        color: Colors.white.withValues(alpha: 0.07),
                                                        width: 0.5,
                                                      ),
                                                    ),
                                                  ),
                                                  child: Icon(
                                                    CupertinoIcons.keyboard_chevron_compact_down,
                                                    size: 16,
                                                    color: t.codeFg,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
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
  String? remoteTermId;
  String? remoteSessionId;
  String? wsChannel;

  bool _disposed = false;

  void disposeResources() {
    if (_disposed) return;
    _disposed = true;
    resizeDebounce?.cancel();
    resizeDebounce = null;
    terminalController.dispose();
    scrollController.dispose();
    focusNode.dispose();
  }
}

/// Isolates `MediaQuery.viewInsetsOf` to a tiny bottom-margin leaf so 120Hz IME animations
/// never rebuild `_TerminalPageState`, `GrassBagUnifiedHeader`, or `TerminalView`!
class _TerminalKeyboardMargin extends StatelessWidget {
  const _TerminalKeyboardMargin({
    required this.restingBottomMargin,
    required this.child,
  });

  final double restingBottomMargin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final kbInset = MediaQuery.viewInsetsOf(context).bottom;
    final bottom = math.max(restingBottomMargin, kbInset + 6.0);
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, bottom),
      child: child,
    );
  }
}
