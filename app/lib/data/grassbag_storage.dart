import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persistent local store backed by `SharedPreferences` for instant cold-start
/// theme hydration, saved hosts, user preferences, and offline session/domain cache.
/// All calls are guarded so headless widget tests without platform channels never throw.
class GrassBagStorage {
  GrassBagStorage._();
  static final GrassBagStorage instance = GrassBagStorage._();

  static const _kPrefsKey = 'grassbag_app_prefs_v2';
  static const _kHostsKey = 'grassbag_saved_hosts_v2';
  static const _kDomainKey = 'grassbag_domain_cache_v2';
  static const _kHostContextsKey = 'grassbag_host_contexts_v1';
  static const _kWebSecretsKey = 'grassbag_web_secrets_v1';

  SharedPreferences? _cachedPrefs;

  Future<SharedPreferences?> _prefs() async {
    if (_cachedPrefs != null) return _cachedPrefs;
    try {
      return _cachedPrefs = await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> loadPrefs() async {
    final p = await _prefs();
    final raw = p?.getString(_kPrefsKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> savePrefs(Map<String, dynamic> data) async {
    final p = await _prefs();
    if (p == null) return;
    try {
      await p.setString(_kPrefsKey, jsonEncode(data));
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>?> loadSavedHosts() async {
    final p = await _prefs();
    final raw = p?.getString(_kHostsKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<Map<String, dynamic>>().toList(growable: false);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveHosts(List<Map<String, dynamic>> hosts) async {
    final p = await _prefs();
    if (p == null) return;
    try {
      await p.setString(_kHostsKey, jsonEncode(hosts));
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> loadDomainCache() async {
    final p = await _prefs();
    final raw = p?.getString(_kDomainKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveDomainCache(Map<String, dynamic> cache) async {
    final p = await _prefs();
    if (p == null) return;
    try {
      await p.setString(_kDomainKey, jsonEncode(cache));
    } catch (_) {}
  }

  Future<Map<String, Map<String, dynamic>>> loadHostContexts() async {
    final p = await _prefs();
    final raw = p?.getString(_kHostContextsKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final out = <String, Map<String, dynamic>>{};
      for (final entry in decoded.entries) {
        if (entry.value is Map) {
          out[entry.key.toString()] =
              (entry.value as Map).map((k, v) => MapEntry(k.toString(), v));
        }
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  Future<void> saveHostContexts(Map<String, Map<String, dynamic>> contexts) async {
    final p = await _prefs();
    if (p == null) return;
    try {
      await p.setString(_kHostContextsKey, jsonEncode(contexts));
    } catch (_) {}
  }

  Future<Map<String, String>> _loadWebSecretsMap() async {
    final p = await _prefs();
    final raw = p?.getString(_kWebSecretsKey);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      final out = <String, String>{};
      for (final entry in decoded.entries) {
        final v = entry.value?.toString();
        if (v != null && v.isNotEmpty) {
          out[entry.key.toString()] = v;
        }
      }
      return out;
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<String?> loadWebSecret(String key) async {
    final map = await _loadWebSecretsMap();
    return map[key];
  }

  Future<void> saveWebSecret(String key, String value) async {
    final p = await _prefs();
    if (p == null) return;
    try {
      final map = await _loadWebSecretsMap();
      map[key] = value;
      await p.setString(_kWebSecretsKey, jsonEncode(map));
    } catch (_) {}
  }

  Future<void> deleteWebSecret(String key) async {
    final p = await _prefs();
    if (p == null) return;
    try {
      final map = await _loadWebSecretsMap();
      if (map.remove(key) != null) {
        if (map.isEmpty) {
          await p.remove(_kWebSecretsKey);
        } else {
          await p.setString(_kWebSecretsKey, jsonEncode(map));
        }
      }
    } catch (_) {}
  }

  void resetCacheForTest() {
    _cachedPrefs = null;
  }
}
