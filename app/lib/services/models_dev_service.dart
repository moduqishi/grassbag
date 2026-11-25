import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_update_transport.dart';

/// Model specification resolved from `https://models.dev/api.json`.
@immutable
class ModelsDevSpec {
  const ModelsDevSpec({
    required this.id,
    required this.providerId,
    required this.providerName,
    required this.name,
    this.contextWindow,
    this.maxOutputTokens,
    this.reasoning = false,
    this.reasoningEfforts = const [],
    this.supportsImage = false,
  });

  final String id;
  final String providerId;
  final String providerName;
  final String name;
  final int? contextWindow;
  final int? maxOutputTokens;
  final bool reasoning;
  final List<String> reasoningEfforts;
  final bool supportsImage;
}

class _IndexedModelSpec {
  _IndexedModelSpec(this.spec)
      : idLower = spec.id.toLowerCase(),
        fullLower = '${spec.providerId.toLowerCase()}/${spec.id.toLowerCase()}',
        nameLower = spec.name.toLowerCase(),
        bareId = _extractBare(spec.id.toLowerCase()),
        normBareId = ModelsDevCatalogService._normalize(_extractBare(spec.id.toLowerCase())),
        primaryBonus = ModelsDevCatalogService._primaryProviders
                .contains(spec.providerId.toLowerCase())
            ? 8
            : 0;

  static String _extractBare(String s) => s.contains('/') ? s.split('/').last : s;

  final ModelsDevSpec spec;
  final String idLower;
  final String fullLower;
  final String nameLower;
  final String bareId;
  final String normBareId;
  final int primaryBonus;
}

class _CatalogIndex {
  _CatalogIndex(this.specs, this.indexed)
      : byFullLower = <String, _IndexedModelSpec>{},
        byIdLower = <String, _IndexedModelSpec>{},
        byBareId = <String, _IndexedModelSpec>{},
        byNormBareId = <String, _IndexedModelSpec>{},
        byNameLower = <String, _IndexedModelSpec>{} {
    void putBest(Map<String, _IndexedModelSpec> map, String key, _IndexedModelSpec item) {
      if (key.isEmpty) return;
      final prev = map[key];
      if (prev == null || item.primaryBonus > prev.primaryBonus) {
        map[key] = item;
      }
    }

    for (final item in indexed) {
      putBest(byFullLower, item.fullLower, item);
      putBest(byIdLower, item.idLower, item);
      putBest(byBareId, item.bareId, item);
      putBest(byNormBareId, item.normBareId, item);
      putBest(byNameLower, item.nameLower, item);
    }
  }

  factory _CatalogIndex.fromSpecs(List<ModelsDevSpec> specs) {
    final indexed = specs.map(_IndexedModelSpec.new).toList(growable: false);
    return _CatalogIndex(specs, indexed);
  }

  final List<ModelsDevSpec> specs;
  final List<_IndexedModelSpec> indexed;
  final Map<String, _IndexedModelSpec> byFullLower;
  final Map<String, _IndexedModelSpec> byIdLower;
  final Map<String, _IndexedModelSpec> byBareId;
  final Map<String, _IndexedModelSpec> byNormBareId;
  final Map<String, _IndexedModelSpec> byNameLower;

  /// O(1) exact-tier lookup covering scores >= 94 (strictly higher than any prefix/fuzzy match <= 90).
  ModelsDevSpec? lookupExact(String qLower, String bareQ, String normBareQ) {
    final fullHit = byFullLower[qLower];
    final idHit = byIdLower[qLower];
    if (fullHit != null || idHit != null) {
      if (fullHit == null) return idHit!.spec;
      if (idHit == null) return fullHit.spec;
      return fullHit.primaryBonus >= idHit.primaryBonus ? fullHit.spec : idHit.spec;
    }
    final bareHit = byBareId[bareQ];
    if (bareHit != null) return bareHit.spec;
    if (normBareQ.isNotEmpty) {
      final normHit = byNormBareId[normBareQ];
      if (normHit != null) return normHit.spec;
    }
    final nameHit = byNameLower[qLower];
    if (nameHit != null) return nameHit.spec;
    return null;
  }
}

/// Fetches, caches, and fuzzy-matches model metadata from `https://models.dev/api.json`
/// so users typing any model ID (e.g. `deepseek-v4-flash`, `claude-sonnet-4-5`, `gpt-5`,
/// `gemini-2.5-pro`) automatically get accurate context window, max output tokens,
/// reasoning support, effort tiers, and vision support.
class ModelsDevCatalogService {
  ModelsDevCatalogService._();
  static final ModelsDevCatalogService instance = ModelsDevCatalogService._();

  static const String catalogUrl = 'https://models.dev/api.json';
  static const Duration _cacheTtl = Duration(hours: 12);
  static const Duration _failureCooldown = Duration(seconds: 60);
  static final RegExp _nonAlnumRe = RegExp(r'[^a-z0-9]');
  static const Set<String> _primaryProviders = {
    'deepseek',
    'openai',
    'anthropic',
    'google',
    'xai',
    'moonshotai',
    'alibaba',
    'zhipuai',
  };

  List<ModelsDevSpec>? _cachedSpecs;
  _CatalogIndex? _catalogIndex;
  DateTime? _fetchedAt;
  DateTime? _lastFailureAt;
  Future<List<ModelsDevSpec>>? _inFlight;

  @visibleForTesting
  void seedForTest(List<ModelsDevSpec> specs) {
    _cachedSpecs = specs;
    _catalogIndex = _CatalogIndex.fromSpecs(specs);
    _fetchedAt = DateTime.now();
    _lastFailureAt = null;
  }

  @visibleForTesting
  void clearCache() {
    _cachedSpecs = null;
    _catalogIndex = null;
    _fetchedAt = null;
    _lastFailureAt = null;
    _inFlight = null;
  }

  Future<List<ModelsDevSpec>> loadCatalog({
    Future<String?> Function(Uri uri)? fetcher,
  }) async {
    final now = DateTime.now();
    if (_cachedSpecs != null &&
        _fetchedAt != null &&
        now.difference(_fetchedAt!) < _cacheTtl) {
      return _cachedSpecs!;
    }
    if (fetcher == null &&
        _lastFailureAt != null &&
        now.difference(_lastFailureAt!) < _failureCooldown) {
      return _cachedSpecs ?? const [];
    }
    if (_inFlight != null) return _inFlight!;

    final fetchFut = _fetchAndParse(fetcher: fetcher);
    final listFut = fetchFut.then((res) {
      if (res.ok && res.index != null && res.index!.specs.isNotEmpty) {
        _cachedSpecs = res.index!.specs;
        _catalogIndex = res.index;
        _fetchedAt = DateTime.now();
        _lastFailureAt = null;
        return res.index!.specs;
      } else if (fetcher == null) {
        _lastFailureAt = DateTime.now();
      }
      return res.specs;
    });
    _inFlight = listFut;
    try {
      return await listFut;
    } finally {
      if (identical(_inFlight, listFut)) _inFlight = null;
    }
  }

  static _CatalogIndex _parseAndIndexCatalog(String rawJson) {
    return _CatalogIndex.fromSpecs(parseCatalogJson(rawJson));
  }

  Future<({List<ModelsDevSpec> specs, _CatalogIndex? index, bool ok})> _fetchAndParse({
    Future<String?> Function(Uri uri)? fetcher,
  }) async {
    try {
      final uri = Uri.parse(catalogUrl);
      final String? body;
      if (fetcher != null) {
        body = await fetcher(uri);
      } else {
        final resp = await fetchAppUpdateJson(
          uri,
          timeout: const Duration(seconds: 9),
        );
        body = resp.statusCode == 200 ? resp.body : null;
      }
      if (body == null || body.isEmpty) {
        return (specs: _cachedSpecs ?? const <ModelsDevSpec>[], index: _catalogIndex, ok: false);
      }
      final built = body.length > 64 * 1024
          ? await compute(_parseAndIndexCatalog, body)
          : _parseAndIndexCatalog(body);
      if (built.specs.isEmpty) {
        return (specs: _cachedSpecs ?? const <ModelsDevSpec>[], index: _catalogIndex, ok: false);
      }
      return (specs: built.specs, index: built, ok: true);
    } catch (_) {
      return (specs: _cachedSpecs ?? const <ModelsDevSpec>[], index: _catalogIndex, ok: false);
    }
  }

  /// Pure parser for `https://models.dev/api.json` top-level map.
  static List<ModelsDevSpec> parseCatalogJson(String rawJson) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) return const [];
    final out = <ModelsDevSpec>[];
    for (final entry in decoded.entries) {
      final provId = entry.key.toString();
      final provObj = entry.value;
      if (provObj is! Map) continue;
      final provName = provObj['name']?.toString().trim().isNotEmpty == true
          ? provObj['name'].toString().trim()
          : provId;
      final models = provObj['models'];
      if (models is! Map) continue;
      for (final mEntry in models.entries) {
        final rawM = mEntry.value;
        if (rawM is! Map) continue;
        final id = (rawM['id']?.toString() ?? mEntry.key.toString()).trim();
        if (id.isEmpty) continue;
        final name = (rawM['name']?.toString() ?? id).trim();
        final limit = rawM['limit'];
        final ctx = limit is Map ? _asInt(limit['context']) : null;
        final maxOut = limit is Map ? _asInt(limit['output']) : null;
        final reasoning = rawM['reasoning'] == true;
        final efforts = <String>[];
        final rOpts = rawM['reasoning_options'];
        if (rOpts is List) {
          for (final opt in rOpts) {
            if (opt is Map && opt['type']?.toString() == 'effort') {
              final vals = opt['values'];
              if (vals is List) {
                for (final v in vals) {
                  final s = v?.toString().trim() ?? '';
                  if (s.isNotEmpty && !efforts.contains(s)) efforts.add(s);
                }
              }
            }
          }
        }
        bool supportsImage = false;
        final modalities = rawM['modalities'];
        final hasExplicitInputModalities = modalities is Map && modalities['input'] is List;
        if (hasExplicitInputModalities) {
          for (final mod in modalities['input'] as List) {
            if (mod?.toString().toLowerCase() == 'image') {
              supportsImage = true;
              break;
            }
          }
        } else if (rawM['attachment'] == true) {
          supportsImage = true;
        }
        out.add(
          ModelsDevSpec(
            id: id,
            providerId: provId,
            providerName: provName,
            name: name,
            contextWindow: ctx,
            maxOutputTokens: maxOut,
            reasoning: reasoning,
            reasoningEfforts: efforts,
            supportsImage: supportsImage,
          ),
        );
      }
    }
    return out;
  }

  /// Fuzzy lookup by typed model ID or name (e.g. `deepseek-reasoner`, `openai/gpt-5`, `claude-sonnet-4.5`).
  Future<ModelsDevSpec?> lookupModel(
    String rawQuery, {
    Future<String?> Function(Uri uri)? fetcher,
  }) async {
    final q = rawQuery.trim();
    if (q.length < 2) return null;
    final specs = await loadCatalog(fetcher: fetcher);
    return matchInList(specs, q);
  }

  /// Returns up to [limit] top autocomplete suggestions matching [rawQuery].
  Future<List<ModelsDevSpec>> searchSuggestions(
    String rawQuery, {
    int limit = 6,
    Future<String?> Function(Uri uri)? fetcher,
  }) async {
    final q = rawQuery.trim();
    if (q.length < 2) return const [];
    final specs = await loadCatalog(fetcher: fetcher);
    if (specs.isEmpty) return const [];
    final qLower = q.toLowerCase();
    final bareQ = qLower.contains('/') ? qLower.split('/').last : qLower;
    final normBareQ = _normalize(bareQ);
    final indexed = identical(specs, _cachedSpecs) ? _catalogIndex?.indexed : null;
    final bestById = <String, (int, ModelsDevSpec)>{};
    if (indexed != null) {
      for (final idx in indexed) {
        final score = _scoreIndexed(idx, qLower, bareQ, normBareQ);
        if (score <= 0) continue;
        final prev = bestById[idx.idLower];
        if (prev == null || score > prev.$1) {
          bestById[idx.idLower] = (score, idx.spec);
        }
      }
    } else {
      for (final s in specs) {
        final score = _scoreRaw(s, qLower, bareQ, normBareQ);
        if (score <= 0) continue;
        final key = s.id.toLowerCase();
        final prev = bestById[key];
        if (prev == null || score > prev.$1) {
          bestById[key] = (score, s);
        }
      }
    }
    final scored = bestById.values.toList()..sort((a, b) => b.$1.compareTo(a.$1));
    return scored.take(limit).map((e) => e.$2).toList(growable: false);
  }

  static ModelsDevSpec? matchInList(List<ModelsDevSpec> specs, String rawQuery) {
    final qLower = rawQuery.trim().toLowerCase();
    if (qLower.length < 2 || specs.isEmpty) return null;
    final bareQ = qLower.contains('/') ? qLower.split('/').last : qLower;
    final normBareQ = _normalize(bareQ);
    final index = identical(specs, instance._cachedSpecs) ? instance._catalogIndex : null;
    if (index != null) {
      final exact = index.lookupExact(qLower, bareQ, normBareQ);
      if (exact != null) return exact;
    }
    final indexed = index?.indexed;
    ModelsDevSpec? best;
    var bestScore = 0;
    if (indexed != null) {
      for (final idx in indexed) {
        final sc = _scoreIndexed(idx, qLower, bareQ, normBareQ);
        if (sc > bestScore) {
          bestScore = sc;
          best = idx.spec;
        }
      }
    } else {
      for (final s in specs) {
        final sc = _scoreRaw(s, qLower, bareQ, normBareQ);
        if (sc > bestScore) {
          bestScore = sc;
          best = s;
        }
      }
    }
    // Require a reasonably strong match so arbitrary short prefixes don't misfire.
    return bestScore >= 60 ? best : null;
  }

  static int _scoreIndexed(
    _IndexedModelSpec idx,
    String qLower,
    String bareQ,
    String normBareQ,
  ) {
    if (idx.idLower == qLower || idx.fullLower == qLower) return 120 + idx.primaryBonus;
    if (idx.bareId == bareQ) return 110 + idx.primaryBonus;
    if (idx.normBareId == normBareQ && normBareQ.isNotEmpty) return 100 + idx.primaryBonus;
    if (idx.nameLower == qLower) return 94 + idx.primaryBonus;
    if (idx.bareId.startsWith(bareQ) && bareQ.length >= 2) return 82 + idx.primaryBonus;
    if (idx.normBareId.startsWith(normBareQ) && normBareQ.length >= 2) {
      return 76 + idx.primaryBonus;
    }
    if (bareQ.startsWith(idx.bareId) && idx.bareId.length >= 5) return 70 + idx.primaryBonus;
    if (idx.bareId.contains(bareQ) && bareQ.length >= 4) return 64 + idx.primaryBonus;
    if (idx.nameLower.contains(qLower) && qLower.length >= 4) return 52 + idx.primaryBonus;
    return 0;
  }

  static int _scoreRaw(
    ModelsDevSpec s,
    String qLower,
    String bareQ,
    String normBareQ,
  ) {
    final idLower = s.id.toLowerCase();
    final fullLower = '${s.providerId.toLowerCase()}/$idLower';
    final nameLower = s.name.toLowerCase();
    final bareId = idLower.contains('/') ? idLower.split('/').last : idLower;
    final normBareId = _normalize(bareId);
    final primaryBonus = _primaryProviders.contains(s.providerId.toLowerCase()) ? 8 : 0;
    if (idLower == qLower || fullLower == qLower) return 120 + primaryBonus;
    if (bareId == bareQ) return 110 + primaryBonus;
    if (normBareId == normBareQ && normBareQ.isNotEmpty) return 100 + primaryBonus;
    if (nameLower == qLower) return 94 + primaryBonus;
    if (bareId.startsWith(bareQ) && bareQ.length >= 2) return 82 + primaryBonus;
    if (normBareId.startsWith(normBareQ) && normBareQ.length >= 2) return 76 + primaryBonus;
    if (bareQ.startsWith(bareId) && bareId.length >= 5) return 70 + primaryBonus;
    if (bareId.contains(bareQ) && bareQ.length >= 4) return 64 + primaryBonus;
    if (nameLower.contains(qLower) && qLower.length >= 4) return 52 + primaryBonus;
    return 0;
  }

  static String _normalize(String s) => s.toLowerCase().replaceAll(_nonAlnumRe, '');

  static int? _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }
}
