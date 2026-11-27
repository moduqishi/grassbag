import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class NativeRuntimeStatus {
  const NativeRuntimeStatus({
    this.initialized = false,
    this.containerExtracted = false,
    this.slotExtracted = false,
    this.engineState = 'stopped',
    this.engineRunning = false,
    this.engineError,
    this.activeSlot = 'slot-a',
    this.lkgSlot = 'slot-a',
    this.canRollback = false,
    this.dshVersion = '0.2.2-rc.5',
    this.dshPrevVersion = '',
    this.bridgeVersion = '0.1.0',
    this.containerVersion = 'Ubuntu 24.04.5 · Node 24.22.3',
    this.executorMode = 'proot',
    this.configuredExecutorMode = 'proot',
    this.hasTawcroot = false,
    this.hasProot = false,
    this.hasBundledAssets = false,
    this.hasBundledRuntimePayloads = false,
    this.runtimeDelivery = 'remote',
    this.runtimeReleaseTag = '',
    this.runtimeTotalBytes = 0,
    this.runtimeDownloadBytes = 0,
    this.hasPartialDownload = false,
    this.isMeteredNetwork = false,
    this.customRuntimeMirrorUrl = '',
    this.bootstrapActive = false,
    this.homePath = '/root',
    this.homeSizeKb = 0,
    this.bridgeSocketPath = '',
    this.bridgeHttpUrl = 'http://127.0.0.1:13080',
    this.dshWebUrl = 'http://127.0.0.1:13080',
    this.bridgeToken = '',
    this.phoneSocketPath = '',
    this.droidSocketPath = '',
    this.udsReady = false,
    this.bridgeReady = false,
    this.sdcardMounted = false,
    this.useSystemProxy = false,
    this.installedToolkits = const [],
    this.deviceAbi = 'arm64-v8a',
    this.sdkInt = 35,
  });

  factory NativeRuntimeStatus.fromMap(Map<Object?, Object?> m) {
    final rawToolkits = m['installedToolkits'];
    final toolkits = rawToolkits is List
        ? rawToolkits.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toList(growable: false)
        : const <String>[];
    final execMode = m['executorMode']?.toString() ?? 'proot';
    return NativeRuntimeStatus(
      initialized: m['initialized'] == true,
      containerExtracted: m['containerExtracted'] == true,
      slotExtracted: m['slotExtracted'] == true,
      engineState: m['engineState']?.toString() ?? 'stopped',
      engineRunning: m['engineRunning'] == true,
      engineError: m['engineError']?.toString(),
      activeSlot: m['activeSlot']?.toString() ?? 'slot-a',
      lkgSlot: m['lkgSlot']?.toString() ?? 'slot-a',
      canRollback: m['canRollback'] == true,
      dshVersion: m['dshVersion']?.toString() ?? '0.2.2-rc.5',
      dshPrevVersion: m['dshPrevVersion']?.toString() ?? '',
      bridgeVersion: m['bridgeVersion']?.toString() ?? '0.1.0',
      containerVersion: m['containerVersion']?.toString() ?? 'Ubuntu 24.04.5 · Node 24.22.3',
      executorMode: execMode,
      configuredExecutorMode: m['configuredExecutorMode']?.toString() ?? execMode,
      hasTawcroot: m['hasTawcroot'] == true,
      hasProot: m['hasProot'] == true,
      hasBundledAssets: m['hasBundledAssets'] == true,
      hasBundledRuntimePayloads: m['hasBundledRuntimePayloads'] == true,
      runtimeDelivery: m['runtimeDelivery']?.toString() ??
          (m['hasBundledRuntimePayloads'] == true ? 'bundled' : 'remote'),
      runtimeReleaseTag: m['runtimeReleaseTag']?.toString() ?? '',
      runtimeTotalBytes: (m['runtimeTotalBytes'] as num?)?.toInt() ?? 0,
      runtimeDownloadBytes: (m['runtimeDownloadBytes'] as num?)?.toInt() ?? 0,
      hasPartialDownload: m['hasPartialDownload'] == true,
      isMeteredNetwork: m['isMeteredNetwork'] == true,
      customRuntimeMirrorUrl: m['customRuntimeMirrorUrl']?.toString() ?? '',
      bootstrapActive: m['bootstrapActive'] == true,
      homePath: m['homePath']?.toString() ?? '/root',
      homeSizeKb: (m['homeSizeKb'] as num?)?.toInt() ?? 0,
      bridgeSocketPath: m['bridgeSocketPath']?.toString() ?? '',
      bridgeHttpUrl: m['bridgeHttpUrl']?.toString() ?? 'http://127.0.0.1:13080',
      dshWebUrl: m['dshWebUrl']?.toString() ??
          m['bridgeHttpUrl']?.toString() ??
          'http://127.0.0.1:13080',
      bridgeToken: m['bridgeToken']?.toString() ?? '',
      phoneSocketPath: m['phoneSocketPath']?.toString() ?? '',
      droidSocketPath: m['droidSocketPath']?.toString() ?? '',
      udsReady: m['udsReady'] == true,
      bridgeReady: m['bridgeReady'] == true,
      sdcardMounted: m['sdcardMounted'] == true,
      useSystemProxy: m['useSystemProxy'] == true,
      installedToolkits: toolkits,
      deviceAbi: m['deviceAbi']?.toString() ?? 'arm64-v8a',
      sdkInt: (m['sdkInt'] as num?)?.toInt() ?? 35,
    );
  }

  final bool initialized;
  final bool containerExtracted;
  final bool slotExtracted;
  final String engineState;
  final bool engineRunning;
  final String? engineError;
  final String activeSlot;
  final String lkgSlot;
  final bool canRollback;
  final String dshVersion;
  final String dshPrevVersion;
  final String bridgeVersion;
  final String containerVersion;
  final String executorMode;
  final String configuredExecutorMode;
  final bool hasTawcroot;
  final bool hasProot;
  final bool hasBundledAssets;
  final bool hasBundledRuntimePayloads;
  final String runtimeDelivery;
  final String runtimeReleaseTag;
  final int runtimeTotalBytes;
  final int runtimeDownloadBytes;
  final bool hasPartialDownload;
  final bool isMeteredNetwork;
  final String customRuntimeMirrorUrl;
  final bool bootstrapActive;
  final String homePath;
  final int homeSizeKb;
  final String bridgeSocketPath;
  final String bridgeHttpUrl;
  final String dshWebUrl;
  final String bridgeToken;
  final String phoneSocketPath;
  final String droidSocketPath;
  final bool udsReady;
  final bool bridgeReady;
  final bool sdcardMounted;
  final bool useSystemProxy;
  final List<String> installedToolkits;
  final String deviceAbi;
  final int sdkInt;

  /// True when the thin APK requires downloading container/DSH bundles online.
  bool get requiresOnlineDownload => !hasBundledRuntimePayloads && runtimeDownloadBytes > 0;

  /// Human-readable pending download size (e.g. `188 MB`), falling back to total or `188 MB`.
  String get formattedDownloadSize {
    final bytes = runtimeDownloadBytes > 0
        ? runtimeDownloadBytes
        : (runtimeTotalBytes > 0 ? runtimeTotalBytes : 197125416);
    final mb = bytes / (1024.0 * 1024.0);
    if (mb < 1.0) return '< 1 MB';
    if (mb < 10.0) return '${mb.toStringAsFixed(1)} MB';
    return '${mb.round()} MB';
  }

  /// Short display label for the configured download mirror setting.
  String get runtimeMirrorDisplayLabel {
    final raw = customRuntimeMirrorUrl.trim();
    if (raw.isEmpty) return '自动择优';
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return raw;
  }

  NativeRuntimeStatus copyWith({
    String? configuredExecutorMode,
    String? customRuntimeMirrorUrl,
  }) {
    return NativeRuntimeStatus(
      initialized: initialized,
      containerExtracted: containerExtracted,
      slotExtracted: slotExtracted,
      engineState: engineState,
      engineRunning: engineRunning,
      engineError: engineError,
      activeSlot: activeSlot,
      lkgSlot: lkgSlot,
      canRollback: canRollback,
      dshVersion: dshVersion,
      dshPrevVersion: dshPrevVersion,
      bridgeVersion: bridgeVersion,
      containerVersion: containerVersion,
      executorMode: executorMode,
      configuredExecutorMode: configuredExecutorMode ?? this.configuredExecutorMode,
      hasTawcroot: hasTawcroot,
      hasProot: hasProot,
      hasBundledAssets: hasBundledAssets,
      hasBundledRuntimePayloads: hasBundledRuntimePayloads,
      runtimeDelivery: runtimeDelivery,
      runtimeReleaseTag: runtimeReleaseTag,
      runtimeTotalBytes: runtimeTotalBytes,
      runtimeDownloadBytes: runtimeDownloadBytes,
      hasPartialDownload: hasPartialDownload,
      isMeteredNetwork: isMeteredNetwork,
      customRuntimeMirrorUrl: customRuntimeMirrorUrl ?? this.customRuntimeMirrorUrl,
      bootstrapActive: bootstrapActive,
      homePath: homePath,
      homeSizeKb: homeSizeKb,
      bridgeSocketPath: bridgeSocketPath,
      bridgeHttpUrl: bridgeHttpUrl,
      dshWebUrl: dshWebUrl,
      bridgeToken: bridgeToken,
      phoneSocketPath: phoneSocketPath,
      droidSocketPath: droidSocketPath,
      udsReady: udsReady,
      bridgeReady: bridgeReady,
      sdcardMounted: sdcardMounted,
      useSystemProxy: useSystemProxy,
      installedToolkits: installedToolkits,
      deviceAbi: deviceAbi,
      sdkInt: sdkInt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NativeRuntimeStatus &&
        other.initialized == initialized &&
        other.containerExtracted == containerExtracted &&
        other.slotExtracted == slotExtracted &&
        other.engineState == engineState &&
        other.engineRunning == engineRunning &&
        other.engineError == engineError &&
        other.activeSlot == activeSlot &&
        other.lkgSlot == lkgSlot &&
        other.canRollback == canRollback &&
        other.dshVersion == dshVersion &&
        other.dshPrevVersion == dshPrevVersion &&
        other.bridgeVersion == bridgeVersion &&
        other.containerVersion == containerVersion &&
        other.executorMode == executorMode &&
        other.configuredExecutorMode == configuredExecutorMode &&
        other.hasTawcroot == hasTawcroot &&
        other.hasProot == hasProot &&
        other.hasBundledAssets == hasBundledAssets &&
        other.hasBundledRuntimePayloads == hasBundledRuntimePayloads &&
        other.runtimeDelivery == runtimeDelivery &&
        other.runtimeReleaseTag == runtimeReleaseTag &&
        other.runtimeTotalBytes == runtimeTotalBytes &&
        other.runtimeDownloadBytes == runtimeDownloadBytes &&
        other.hasPartialDownload == hasPartialDownload &&
        other.isMeteredNetwork == isMeteredNetwork &&
        other.customRuntimeMirrorUrl == customRuntimeMirrorUrl &&
        other.bootstrapActive == bootstrapActive &&
        other.homePath == homePath &&
        other.homeSizeKb == homeSizeKb &&
        other.bridgeSocketPath == bridgeSocketPath &&
        other.bridgeHttpUrl == bridgeHttpUrl &&
        other.dshWebUrl == dshWebUrl &&
        other.bridgeToken == bridgeToken &&
        other.phoneSocketPath == phoneSocketPath &&
        other.droidSocketPath == droidSocketPath &&
        other.udsReady == udsReady &&
        other.bridgeReady == bridgeReady &&
        other.sdcardMounted == sdcardMounted &&
        other.useSystemProxy == useSystemProxy &&
        other.deviceAbi == deviceAbi &&
        other.sdkInt == sdkInt &&
        listEquals(other.installedToolkits, installedToolkits);
  }

  @override
  int get hashCode => Object.hashAll([
        initialized,
        containerExtracted,
        slotExtracted,
        engineState,
        engineRunning,
        engineError,
        activeSlot,
        lkgSlot,
        canRollback,
        dshVersion,
        dshPrevVersion,
        bridgeVersion,
        containerVersion,
        executorMode,
        configuredExecutorMode,
        hasTawcroot,
        hasProot,
        hasBundledAssets,
        hasBundledRuntimePayloads,
        runtimeDelivery,
        runtimeReleaseTag,
        runtimeTotalBytes,
        runtimeDownloadBytes,
        hasPartialDownload,
        isMeteredNetwork,
        customRuntimeMirrorUrl,
        bootstrapActive,
        homePath,
        homeSizeKb,
        bridgeSocketPath,
        bridgeHttpUrl,
        dshWebUrl,
        bridgeToken,
        phoneSocketPath,
        droidSocketPath,
        udsReady,
        bridgeReady,
        sdcardMounted,
        useSystemProxy,
        deviceAbi,
        sdkInt,
        Object.hashAll(installedToolkits),
      ]);
}

@immutable
class NativePermissionsStatus {
  const NativePermissionsStatus({
    this.accessibilityEnabled = false,
    this.accessibilitySettingEnabled = false,
    this.accessibilitySystemBound = false,
    this.overlayGranted = false,
    this.allFilesGranted = false,
    this.batteryOptIgnored = false,
    this.notificationsGranted = true,
    this.microphoneGranted = false,
    this.shizukuInstalled = false,
    this.sdkInt = 34,
  });

  factory NativePermissionsStatus.fromMap(Map<Object?, Object?> m) {
    final running = m['accessibilityEnabled'] == true;
    return NativePermissionsStatus(
      accessibilityEnabled: running,
      accessibilitySettingEnabled: m['accessibilitySettingEnabled'] == true || running,
      accessibilitySystemBound: m['accessibilitySystemBound'] == true || running,
      overlayGranted: m['overlayGranted'] == true,
      allFilesGranted: m['allFilesGranted'] == true,
      batteryOptIgnored: m['batteryOptIgnored'] == true,
      notificationsGranted: m['notificationsGranted'] != false,
      microphoneGranted: m['microphoneGranted'] == true,
      shizukuInstalled: m['shizukuInstalled'] == true,
      sdkInt: (m['sdkInt'] as num?)?.toInt() ?? 34,
    );
  }

  final bool accessibilityEnabled;
  final bool accessibilitySettingEnabled;
  final bool accessibilitySystemBound;
  final bool overlayGranted;
  final bool allFilesGranted;
  final bool batteryOptIgnored;
  final bool notificationsGranted;
  final bool microphoneGranted;
  final bool shizukuInstalled;
  final int sdkInt;

  /// True when Android Settings toggle is ON, but OEM battery/restricted settings or
  /// a previous process kill/update put `GrassBagAccessibilityService` into crashed/unbound state.
  bool get accessibilityNeedsRetoggle => accessibilitySettingEnabled && !accessibilityEnabled;

  int get grantedCoreCount =>
      (accessibilityEnabled ? 1 : 0) +
      (overlayGranted ? 1 : 0) +
      (batteryOptIgnored ? 1 : 0) +
      (allFilesGranted ? 1 : 0) +
      (notificationsGranted ? 1 : 0) +
      (microphoneGranted ? 1 : 0);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NativePermissionsStatus &&
        other.accessibilityEnabled == accessibilityEnabled &&
        other.accessibilitySettingEnabled == accessibilitySettingEnabled &&
        other.accessibilitySystemBound == accessibilitySystemBound &&
        other.overlayGranted == overlayGranted &&
        other.allFilesGranted == allFilesGranted &&
        other.batteryOptIgnored == batteryOptIgnored &&
        other.notificationsGranted == notificationsGranted &&
        other.microphoneGranted == microphoneGranted &&
        other.shizukuInstalled == shizukuInstalled &&
        other.sdkInt == sdkInt;
  }

  @override
  int get hashCode => Object.hash(
        accessibilityEnabled,
        accessibilitySettingEnabled,
        accessibilitySystemBound,
        overlayGranted,
        allFilesGranted,
        batteryOptIgnored,
        notificationsGranted,
        microphoneGranted,
        shizukuInstalled,
        sdkInt,
      );
}

@immutable
class PickedAttachment {
  const PickedAttachment({
    required this.name,
    required this.mimeType,
    required this.size,
    required this.bytes,
    this.error,
  });

  final String name;
  final String mimeType;
  final int size;
  final Uint8List bytes;
  final String? error;
}

@immutable
class DiscoveredLanHost {
  const DiscoveredLanHost({
    required this.name,
    required this.address,
    required this.latencyMs,
    this.isDsh = false,
    this.dshVersion,
    this.hasGbridge = false,
    this.requiresAuth = false,
    this.surface,
  });

  final String name;
  final String address;
  final int latencyMs;
  final bool isDsh;
  final String? dshVersion;
  final bool hasGbridge;
  final bool requiresAuth;
  final String? surface;

  bool get isDesktop => surface == 'desktop';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DiscoveredLanHost &&
        other.name == name &&
        other.address == address &&
        other.latencyMs == latencyMs &&
        other.isDsh == isDsh &&
        other.dshVersion == dshVersion &&
        other.hasGbridge == hasGbridge &&
        other.requiresAuth == requiresAuth &&
        other.surface == surface;
  }

  @override
  int get hashCode =>
      Object.hash(name, address, latencyMs, isDsh, dshVersion, hasGbridge, requiresAuth, surface);
}

@immutable
class NativeEvent {
  const NativeEvent(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;
}

/// Unified platform bridge to Android Kotlin `GrassBagBridgePlugin`.
/// Gracefully degrades to safe no-ops on Web, macOS, and headless widget tests.
class GrassBagNativeBridge {
  GrassBagNativeBridge._();
  static final GrassBagNativeBridge instance = GrassBagNativeBridge._();

  static const _method = MethodChannel('dev.grassbag/native');
  static const _event = EventChannel('dev.grassbag/native_events');

  bool _pluginVerified = false;

  bool get isAndroidNative => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get isPluginVerified => _pluginVerified;
  bool get isPluginAvailable => isAndroidNative || _pluginVerified;

  Stream<NativeEvent>? _eventStream;

  static bool get _hasServicesBinding {
    try {
      ServicesBinding.instance;
      return true;
    } catch (_) {
      return false;
    }
  }

  Stream<NativeEvent> get events {
    if (!isAndroidNative || !_hasServicesBinding) return const Stream<NativeEvent>.empty();
    return _eventStream ??= _event.receiveBroadcastStream().map((raw) {
      if (raw is Map) {
        final type = raw['type']?.toString() ?? '';
        final rawData = raw['data'];
        final map = <String, dynamic>{};
        if (rawData is Map) {
          for (final entry in rawData.entries) {
            map[entry.key.toString()] = entry.value;
          }
        }
        return NativeEvent(type, map);
      }
      return const NativeEvent('unknown', {});
    }).handleError((Object _) {
      // Keep the shared broadcast stream attached across transient EventChannel errors;
      // explicit teardown uses `resetEventStream()`.
    });
  }

  void resetEventStream() {
    _eventStream = null;
  }

  Future<T?> _safeInvoke<T>(String method, [Map<String, dynamic>? args]) async {
    if (!isAndroidNative) return null;
    try {
      final res = await _method.invokeMethod<T>(method, args);
      if (res != null) _pluginVerified = true;
      return res;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _safeInvokeMap(
    String method, [
    Map<String, dynamic>? args,
    String? unavailableError,
  ]) async {
    if (!isAndroidNative) {
      return {
        'ok': false,
        if (unavailableError != null) 'error': unavailableError,
      };
    }
    try {
      final res = await _method.invokeMethod<Map<Object?, Object?>>(method, args);
      if (res != null) {
        _pluginVerified = true;
        return res.map((k, v) => MapEntry(k.toString(), v));
      }
      return const {'ok': false, 'error': '本机通道返回空结果'};
    } on PlatformException catch (e) {
      return {
        'ok': false,
        'code': e.code,
        'error': e.message?.trim().isNotEmpty == true ? e.message!.trim() : e.code,
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // Runtime & A/B Slots
  Future<NativeRuntimeStatus?> getRuntimeStatus() async {
    final res = await _safeInvoke<Map<Object?, Object?>>('runtime.status');
    return res == null ? null : NativeRuntimeStatus.fromMap(res);
  }

  Future<Map<String, dynamic>> bootstrapRuntime() => _safeInvokeMap('runtime.bootstrap');

  Future<Map<String, dynamic>> cancelRuntimeBootstrap() => _safeInvokeMap('runtime.cancelBootstrap');

  Future<Map<String, dynamic>> setRuntimeMirrorUrl(String url) =>
      _safeInvokeMap('runtime.setRuntimeMirror', {'url': url});

  Future<Map<String, dynamic>> startLocalEngine() => _safeInvokeMap('runtime.startEngine');

  Future<Map<String, dynamic>> stopLocalEngine() => _safeInvokeMap('runtime.stopEngine');

  Future<Map<String, dynamic>> restartLocalEngine() => _safeInvokeMap('runtime.restartEngine');

  Future<Map<String, dynamic>> cleanRuntimeCache() => _safeInvokeMap('runtime.cleanCache');

  Future<Map<String, dynamic>> rebuildContainer() => _safeInvokeMap('runtime.rebuildContainer');

  Future<List<String>> getEngineLogs() async {
    final res = await _safeInvoke<List<Object?>>('runtime.engineLogs');
    if (res == null) return const [];
    return res.map((e) => e?.toString() ?? '').toList(growable: false);
  }

  Future<Map<String, dynamic>> upgradeAbSlot({
    required String version,
    String? remoteUrl,
  }) =>
      _safeInvokeMap('runtime.upgradeAb', {
        'version': version,
        if (remoteUrl != null) 'remoteUrl': remoteUrl,
      });

  Future<Map<String, dynamic>> rollbackLkg() => _safeInvokeMap('runtime.rollback');

  Future<NativeRuntimeStatus?> setExecutorMode(String mode) async {
    final res = await _safeInvoke<Object?>('runtime.setExecutor', {'mode': mode});
    if (res is Map) {
      final statusMap = res['status'];
      if (statusMap is Map) {
        return NativeRuntimeStatus.fromMap(statusMap);
      }
      if (res.containsKey('configuredExecutorMode')) {
        return NativeRuntimeStatus.fromMap(res);
      }
    }
    return null;
  }

  Future<void> setSdcardMounted(bool enabled) async {
    await _safeInvoke<Object?>('runtime.setSdcardMounted', {'enabled': enabled});
  }

  Future<void> setSystemProxy(bool enabled) async {
    await _safeInvoke<Object?>('runtime.setSystemProxy', {'enabled': enabled});
  }

  Future<Map<String, dynamic>> installToolkit(String id, List<String> packages) =>
      _safeInvokeMap(
        'runtime.installToolkit',
        {'id': id, 'packages': packages},
        '仅 Android 本机 Linux 容器支持在线安装工具链',
      );

  Future<Map<String, dynamic>> exportEncryptedBackup(String passphrase) =>
      _safeInvokeMap(
        'runtime.exportBackup',
        {'passphrase': passphrase},
        '仅 Android 原生环境支持加密归档导出',
      );

  // Real local Android shell sessions for xterm
  Future<Map<String, dynamic>> startLocalShellDetailed(
    String tabId, {
    String? cwd,
    int? cols,
    int? rows,
  }) async {
    final res = await _safeInvoke<Map<Object?, Object?>>('term.start', {
      'tabId': tabId,
      if (cwd != null) 'cwd': cwd,
      if (cols != null) 'cols': cols,
      if (rows != null) 'rows': rows,
    });
    if (res == null) return const {'ok': false, 'isPty': false};
    return res.map((k, v) => MapEntry(k.toString(), v));
  }

  Future<bool> startLocalShell(String tabId, {String? cwd, int? cols, int? rows}) async {
    final res = await startLocalShellDetailed(tabId, cwd: cwd, cols: cols, rows: rows);
    return res['ok'] == true;
  }

  Future<bool> writeLocalShell(String tabId, String data) async {
    return (await _safeInvoke<bool>('term.write', {'tabId': tabId, 'data': data})) == true;
  }

  Future<bool> resizeLocalShell(String tabId, int cols, int rows) async {
    return (await _safeInvoke<bool>('term.resize', {
          'tabId': tabId,
          'cols': cols,
          'rows': rows,
        })) ==
        true;
  }

  Future<bool> signalLocalShell(String tabId, String signal) async {
    return (await _safeInvoke<bool>('term.signal', {
          'tabId': tabId,
          'signal': signal,
        })) ==
        true;
  }

  Future<void> closeLocalShell(String tabId) async {
    await _safeInvoke<bool>('term.close', {'tabId': tabId});
  }

  // Hardware Keystore Vault
  Future<void> putSecret(String key, String value) async {
    await _safeInvoke<bool>('vault.put', {'key': key, 'value': value});
  }

  Future<String?> getSecret(String key) async {
    return _safeInvoke<String>('vault.get', {'key': key});
  }

  Future<void> deleteSecret(String key) async {
    await _safeInvoke<bool>('vault.delete', {'key': key});
  }

  // SafetyGate & Phone Control
  Future<Map<String, dynamic>?> getSafetyStatus() async {
    final res = await _safeInvoke<Map<Object?, Object?>>('safety.status');
    return res?.map((k, v) => MapEntry(k.toString(), v));
  }

  Future<bool> setSafetyPolicy(String policy) async {
    return (await _safeInvoke<bool>('safety.setPolicy', {'policy': policy})) == true;
  }

  Future<bool> setSafetyChatPermissionPreset(String preset) async {
    return (await _safeInvoke<bool>('safety.setChatPermissionPreset', {'preset': preset})) == true;
  }

  Future<bool> setSafetyConfirmHighRisk(bool enabled) async {
    return (await _safeInvoke<bool>('safety.setConfirmHighRisk', {'enabled': enabled})) == true;
  }

  Future<bool> setSafetyAutoReturn(bool enabled) async {
    return (await _safeInvoke<bool>('safety.setAutoReturn', {'enabled': enabled})) == true;
  }

  Future<bool> setSafetyShowEdgeAurora(bool enabled) async {
    return (await _safeInvoke<bool>('safety.setShowEdgeAurora', {'enabled': enabled})) == true;
  }

  Future<bool> setSafetyShowGestureFx(bool enabled) async {
    return (await _safeInvoke<bool>('safety.setShowGestureFx', {'enabled': enabled})) == true;
  }

  Future<bool> setPhonePaused(bool paused) async {
    return (await _safeInvoke<bool>('safety.setPaused', {'paused': paused})) == true;
  }

  Future<bool> returnToGrassBagApp() async {
    return (await _safeInvoke<bool>('safety.returnToApp')) == true;
  }

  Future<bool> notifyPhoneTurnDone({
    String? sessionId,
    String reason = 'completed',
    String summary = '',
  }) async {
    return (await _safeInvoke<bool>('safety.notifyTurnDone', {
          if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
          'reason': reason,
          if (summary.isNotEmpty) 'summary': summary,
        })) ==
        true;
  }

  Future<void> triggerEmergencyStop() async {
    await _safeInvoke<bool>('safety.emergencyStop');
  }

  Future<bool> resetEmergencyStop() async {
    return (await _safeInvoke<bool>('safety.resetStop')) == true;
  }

  Future<bool> previewPhoneOverlay({String mode = 'interactive'}) async {
    return (await _safeInvoke<bool>('safety.previewOverlay', {'mode': mode})) == true;
  }

  Future<void> syncThemeMode(
    bool isDark, {
    int? accentPrimary,
    int? accentHi,
    int? bgSolid,
    bool followSystemTheme = false,
  }) async {
    await _safeInvoke<bool>('app.syncThemeMode', {
      'isDark': isDark,
      'followSystemTheme': followSystemTheme,
      if (accentPrimary != null) 'accentPrimary': accentPrimary,
      if (accentHi != null) 'accentHi': accentHi,
      if (bgSolid != null) 'bgSolid': bgSolid,
    });
  }

  // Background Keepalive Service & Alert Notifications
  Future<bool> startKeepaliveService({
    String title = 'GrassBag 本机环境运行中',
    String text = '对话与终端后台保活通道已就绪',
    int wakeLockMs = 0,
    bool? holdWifiLock,
    bool releaseWakeLock = false,
  }) async {
    return (await _safeInvoke<bool>('service.start', {
          'title': title,
          'text': text,
          if (wakeLockMs > 0) 'wakeLockMs': wakeLockMs,
          if (holdWifiLock != null) 'holdWifiLock': holdWifiLock,
          if (releaseWakeLock) 'releaseWakeLock': true,
        })) ==
        true;
  }

  Future<void> stopKeepaliveService() async {
    await _safeInvoke<bool>('service.stop');
  }

  Future<void> postAlertNotification(String title, String text) async {
    await _safeInvoke<bool>('service.notify', {'title': title, 'text': text});
  }

  // System Permissions & Deep Links
  Future<NativePermissionsStatus?> getPermissionsStatus() async {
    final res = await _safeInvoke<Map<Object?, Object?>>('permissions.status');
    return res == null ? null : NativePermissionsStatus.fromMap(res);
  }

  Future<void> openPermissionSettings(String target) async {
    await _safeInvoke<bool>('permissions.openSettings', {'target': target});
  }

  Future<Map<String, dynamic>> requestRuntimePermission(String target) async {
    final res = await _safeInvoke<Map<Object?, Object?>>('permissions.requestRuntime', {
      'target': target,
    });
    if (res == null) return const {'granted': false, 'unsupported': true};
    return res.map((k, v) => MapEntry(k.toString(), v));
  }

  // Native File / Gallery / Camera Pickers & Share
  static Uint8List _decodeBase64Isolate(String b64) {
    try {
      return base64Decode(b64);
    } catch (_) {
      return Uint8List(0);
    }
  }

  Future<Uint8List> _safeBase64DecodeAsync(String b64) async {
    if (b64.isEmpty) return Uint8List(0);
    if (b64.length > 64 * 1024) {
      return compute(_decodeBase64Isolate, b64);
    }
    return _decodeBase64Isolate(b64);
  }

  Future<PickedAttachment?> pickAttachment({String mime = '*/*'}) async {
    final res = await _safeInvoke<Map<Object?, Object?>>('picker.pickFile', {'mime': mime});
    if (res == null) return null;
    final err = res['error']?.toString();
    if (err != null && err.isNotEmpty) {
      return PickedAttachment(
        name: res['name']?.toString() ?? 'file',
        mimeType: res['mimeType']?.toString() ?? 'application/octet-stream',
        size: 0,
        bytes: Uint8List(0),
        error: err,
      );
    }
    final rawBytes = res['bytes'];
    final bytes = rawBytes is Uint8List
        ? rawBytes
        : await _safeBase64DecodeAsync(res['base64']?.toString() ?? '');
    return PickedAttachment(
      name: res['name']?.toString() ?? 'file',
      mimeType: res['mimeType']?.toString() ?? 'application/octet-stream',
      size: (res['size'] as num?)?.toInt() ?? bytes.length,
      bytes: bytes,
    );
  }

  Future<PickedAttachment?> takePhotoAttachment() async {
    final res = await _safeInvoke<Map<Object?, Object?>>('picker.takePhoto');
    if (res == null) return null;
    final err = res['error']?.toString();
    if (err != null && err.isNotEmpty) {
      return PickedAttachment(
        name: res['name']?.toString() ?? 'photo.jpg',
        mimeType: res['mimeType']?.toString() ?? 'image/jpeg',
        size: 0,
        bytes: Uint8List(0),
        error: err,
      );
    }
    final rawBytes = res['bytes'];
    final bytes = rawBytes is Uint8List
        ? rawBytes
        : await _safeBase64DecodeAsync(res['base64']?.toString() ?? '');
    return PickedAttachment(
      name: res['name']?.toString() ?? 'photo.jpg',
      mimeType: res['mimeType']?.toString() ?? 'image/jpeg',
      size: (res['size'] as num?)?.toInt() ?? bytes.length,
      bytes: bytes,
    );
  }

  Future<void> shareText(String text) async {
    await _safeInvoke<bool>('device.shareText', {'text': text});
  }

  /// Shares arbitrary bytes as a real named file via Android FileProvider (`ACTION_SEND`).
  Future<bool> shareFileBytes({
    required Uint8List bytes,
    required String filename,
    String mimeType = 'application/octet-stream',
  }) async {
    if (!isAndroidNative || bytes.isEmpty) return false;
    return (await _safeInvoke<bool>('device.shareFile', {
          'bytes': bytes,
          'filename': filename,
          'mimeType': mimeType,
        })) ==
        true;
  }

  /// Shares UTF-8 text as a named file via Android FileProvider (`ACTION_SEND`).
  Future<bool> shareTextFile({
    required String text,
    required String filename,
    String mimeType = 'text/plain',
  }) async {
    if (!isAndroidNative) return false;
    return (await _safeInvoke<bool>('device.shareFile', {
          'text': text,
          'filename': filename,
          'mimeType': mimeType,
        })) ==
        true;
  }

  /// Saves image bytes directly into Android system gallery (`Pictures/GrassBag` via MediaStore).
  Future<({bool ok, String? location, String? error})> saveImageBytes({
    required Uint8List bytes,
    required String filename,
    String mimeType = 'image/png',
  }) async {
    if (!isAndroidNative || bytes.isEmpty) {
      return (ok: false, location: null, error: '当前平台不支持原生相册保存');
    }
    final res = await _safeInvoke<Map<Object?, Object?>>('device.saveImage', {
      'bytes': bytes,
      'filename': filename,
      'mimeType': mimeType,
    });
    if (res == null) {
      return (ok: false, location: null, error: '系统相册服务无响应');
    }
    return (
      ok: res['ok'] == true,
      location: res['location']?.toString(),
      error: res['error']?.toString(),
    );
  }

  Future<bool> openExternalUrl(String url) async {
    return (await _safeInvoke<bool>('device.openUrl', {'url': url})) == true;
  }

  Future<List<DiscoveredLanHost>> scanLanHosts({int port = 3080}) async {
    final res = await _safeInvoke<List<Object?>>('lan.scan', {'port': port});
    if (res == null) return const [];
    return res.whereType<Map<Object?, Object?>>().map((m) {
      return DiscoveredLanHost(
        name: m['name']?.toString() ?? 'LAN Host',
        address: m['address']?.toString() ?? '',
        latencyMs: (m['latencyMs'] as num?)?.toInt() ?? 10,
        isDsh: m['isDsh'] == true,
        dshVersion: m['dshVersion']?.toString(),
        hasGbridge: m['hasGbridge'] == true,
        requiresAuth: m['requiresAuth'] == true,
        surface: m['surface']?.toString(),
      );
    }).toList(growable: false);
  }

  /// Returns all local IP addresses currently assigned to this device's network interfaces
  /// (Wi-Fi, hotspot, Ethernet, loopback) so remote hosts can strictly exclude this device.
  Future<Set<String>> getLocalDeviceIps() async {
    final res = await _safeInvoke<List<Object?>>('device.localIps');
    if (res == null) return const {'127.0.0.1', '::1', '0.0.0.0'};
    final out = <String>{'127.0.0.1', '::1', '0.0.0.0'};
    for (final item in res) {
      final clean = item?.toString().trim().toLowerCase() ?? '';
      if (clean.isNotEmpty) out.add(clean);
    }
    return out;
  }

  Future<String?> getWebViewCookies(String url) async {
    final res = await _safeInvoke<String>('webview.getCookies', {'url': url});
    if (res == null || res.trim().isEmpty) return null;
    return res.trim();
  }

  Future<bool> setWebViewCookies(String url, String cookieHeader) async {
    return (await _safeInvoke<bool>('webview.setCookies', {
          'url': url,
          'cookieHeader': cookieHeader,
        })) ==
        true;
  }

  Future<bool> clearWebViewCookies() async {
    return (await _safeInvoke<bool>('webview.clearCookies')) == true;
  }

  Future<AppPackageVersion?> getAppVersion() async {
    if (!isAndroidNative) return null;
    final res = await _safeInvoke<Map<Object?, Object?>>('app.getVersion');
    if (res == null) return null;
    final versionName = res['versionName']?.toString().trim() ?? '';
    final buildNumber = (res['buildNumber'] as num?)?.toInt() ?? 1;
    final packageName = res['packageName']?.toString().trim() ?? 'dev.grassbag.grassbag';
    if (versionName.isEmpty) return null;
    return AppPackageVersion(
      versionName: versionName,
      buildNumber: buildNumber,
      packageName: packageName,
    );
  }

  Future<String?> getUpdatesCacheDir() async {
    if (!isAndroidNative) return null;
    final res = await _safeInvoke<String>('app.getUpdatesDir');
    if (res == null || res.trim().isEmpty) return null;
    return res.trim();
  }

  /// Triggers Android's system package installer via FileProvider.
  /// Returns `'started'`, `'permission_required'`, or `'error:<reason>'`.
  Future<String> installApk(String filePath) async {
    if (!isAndroidNative) return 'error:unsupported_platform';
    final res = await _safeInvoke<String>('app.installApk', {'path': filePath});
    return res ?? 'error:bridge_unavailable';
  }
}

class AppPackageVersion {
  const AppPackageVersion({
    required this.versionName,
    required this.buildNumber,
    required this.packageName,
  });

  final String versionName;
  final int buildNumber;
  final String packageName;
}
