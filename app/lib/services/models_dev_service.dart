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

/// Fetches, caches, and fuzzy-matches model metadata from `https://models.dev/api.json`
/// so users typing any model ID (e.g. `deepseek-v4-flash`, `claude-sonnet-4-5`, `gpt-5`,
/// `gemini-2.5-pro`) automatically get accurate context window, max output tokens,
/// reasoning support, effort tiers, and vision support.
class ModelsDevCatalogService {
  ModelsDevCatalogService._();
  static final ModelsDevCatalogService instance = ModelsDevCatalogService._();

  static const String catalogUrl = 'https://models.dev/api.json';
  static const Duration _cacheTtl = Duration(hours: 12);

  List<ModelsDevSpec>? _cachedSpecs;
  DateTime? _fetchedAt;
  Future<List<ModelsDevSpec>>? _inFlight;

  @visibleForTesting
  void seedForTest(List<ModelsDevSpec> specs) {
    _cachedSpecs = specs;
    _fetchedAt = DateTime.now();
  }

  @visibleForTesting
  void clearCache() {
    _cachedSpecs = null;
    _fetchedAt = null;
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
    if (_inFlight != null) return _inFlight!;

    final fut = _fetchAndParse(fetcher: fetcher);
    _inFlight = fut;
    try {
      final list = await fut;
      if (list.isNotEmpty) {
        _cachedSpecs = list;
        _fetchedAt = DateTime.now();
      }
      return list;
    } finally {
      if (identical(_inFlight, fut)) _inFlight = null;
    }
  }

  Future<List<ModelsDevSpec>> _fetchAndParse({
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
        return _cachedSpecs ?? const [];
      }
      return parseCatalogJson(body);
    } catch (_) {
      return _cachedSpecs ?? const [];
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
        if (modalities is Map && modalities['input'] is List) {
          for (final mod in modalities['input'] as List) {
            if (mod?.toString().toLowerCase() == 'image') {
              supportsImage = true;
              break;
            }
          }
        }
        if (!supportsImage && rawM['attachment'] == true) {
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
    final normQ = _normalize(q);
    final scored = <(int, ModelsDevSpec)>[];
    final seenIds = <String>{};
    for (final s in specs) {
      final score = _score(s, q.toLowerCase(), normQ);
      if (score > 0 && seenIds.add(s.id.toLowerCase())) {
        scored.add((score, s));
      }
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return scored.take(limit).map((e) => e.$2).toList(growable: false);
  }

  static ModelsDevSpec? matchInList(List<ModelsDevSpec> specs, String rawQuery) {
    final qLower = rawQuery.trim().toLowerCase();
    if (qLower.length < 2 || specs.isEmpty) return null;
    final normQ = _normalize(qLower);
    ModelsDevSpec? best;
    var bestScore = 0;
    for (final s in specs) {
      final sc = _score(s, qLower, normQ);
      if (sc > bestScore) {
        bestScore = sc;
        best = s;
      }
    }
    // Require a reasonably strong match so arbitrary short prefixes don't misfire.
    return bestScore >= 60 ? best : null;
  }

  static int _score(ModelsDevSpec s, String qLower, String normQ) {
    final idLower = s.id.toLowerCase();
    final fullLower = '${s.providerId.toLowerCase()}/$idLower';
    final nameLower = s.name.toLowerCase();
    final bareQ = qLower.contains('/') ? qLower.split('/').last : qLower;
    final bareId = idLower.contains('/') ? idLower.split('/').last : idLower;
    // Prefer canonical primary providers slightly over aggregator duplicates
    final primaryBonus = const {'deepseek', 'openai', 'anthropic', 'google', 'xai', 'moonshotai', 'alibaba', 'zhipuai'}
            .contains(s.providerId.toLowerCase())
        ? 8
        : 0;
    if (idLower == qLower || fullLower == qLower) return 120 + primaryBonus;
    if (bareId == bareQ) return 110 + primaryBonus;
    if (_normalize(bareId) == _normalize(bareQ)) return 100 + primaryBonus;
    if (nameLower == qLower) return 94 + primaryBonus;
    if (bareId.startsWith(bareQ) && bareQ.length >= 4) return 82 + primaryBonus;
    if (_normalize(bareId).startsWith(normQ) && normQ.length >= 4) return 76 + primaryBonus;
    if (bareQ.startsWith(bareId) && bareId.length >= 5) return 70 + primaryBonus;
    if (bareId.contains(bareQ) && bareQ.length >= 5) return 64 + primaryBonus;
    if (nameLower.contains(qLower) && qLower.length >= 5) return 52 + primaryBonus;
    return 0;
  }

  static String _normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static int? _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }
}
