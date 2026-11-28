import 'dart:convert';

/// Smart parser for remote DSH host addresses, GrassBag QR pairing codes & pasted terminal output.
///
/// Handles:
/// - GrassBag QR pairing links (`grassbag://pair?url=...&token=...&name=...`)
/// - Full `dsh web` / `dsh-gbridge` links (`http://192.168.1.8:3081/?token=abc...&name=MacBook`)
/// - JSON QR payloads (`{"url":"http://...","token":"...","name":"..."}`)
/// - Multi-line terminal blocks containing an `http(s)://` URL or `GBRIDGE_TOKEN=...`
/// - Bare IPv4 / Tailscale IPs (`192.168.1.8`, `100.64.1.2`) -> auto `:3080`
/// - `IP:port` / `localhost:3080` -> auto `http://`
/// - Bare domain names (`dsh.example.com`) -> auto `https://`
/// - Markdown/quoted/bracketed links (`<http://...>`, `[url](http://...)`)
class ParsedRemoteHostInput {
  const ParsedRemoteHostInput({
    required this.address,
    this.token,
    this.suggestedName,
    this.pairCode,
    this.wasAutoPorted = false,
    this.wasExtractedFromText = false,
  });

  /// Clean normalized `http(s)://...` base address with `?token=` stripped.
  final String address;

  /// Extracted launch/bearer token if present in query params or pasted text.
  final String? token;

  /// Suggested human-readable display name (hostname/IP).
  final String? suggestedName;

  /// Optional short-lived pairing session code (`?p=` / `?pairCode=`) used for per-pairing
  /// confirmation on the computer's pairing panel and expiry detection.
  final String? pairCode;

  /// True when `:3080` default DSH port was inferred for a bare IP/localhost.
  final bool wasAutoPorted;

  /// True when the URL was extracted from a longer pasted terminal/message block.
  final bool wasExtractedFromText;
}

final RegExp _httpUrlInTextRe = RegExp(
  r'https?://[^\s<>"\x27`(){}，。；：！？（）【】《》「」『』、\u200B-\u200D\uFEFF]+',
  caseSensitive: false,
);

final RegExp _envTokenRe = RegExp(
  r'''(?:GBRIDGE_TOKEN|DSH_TOKEN|token)\s*[=:]\s*["']?([A-Za-z0-9._~+/=-]{6,})["']?''',
  caseSensitive: false,
);

final RegExp _ipv4HostRe = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');

/// Parse arbitrary user input (URL, IP, `dsh web` stdout line, or pasted block)
/// into a normalized remote host address + optional extracted token.
///
/// When [strictQr] is `true` (camera QR scanner), bare words and unrelated consumer
/// web URLs are rejected unless they carry a `grassbag://pair` scheme, JSON pairing
/// payload, `?token=` param, explicit port, IP/LAN host, or DSH/gbridge path/host hint.
///
/// Returns `null` if no valid HTTP(S) host can be parsed.
ParsedRemoteHostInput? parseRemoteHostInput(
  String rawInput, {
  String? explicitToken,
  int defaultDshPort = 3080,
  bool strictQr = false,
}) {
  final trimmed = rawInput.trim();
  if (trimmed.isEmpty) return null;

  // 0a) Dedicated GrassBag QR pairing scheme: `grassbag://pair?url=http%3A%2F%2F...&token=...&name=...`
  final pairSchemeMatch = RegExp(r'grassbag://pair\?[^\s<>"\x27`]+', caseSensitive: false)
      .firstMatch(trimmed);
  if (pairSchemeMatch != null) {
    final pairUri = Uri.tryParse(_stripTrailingPunctuation(pairSchemeMatch.group(0)!));
    final innerUrl = pairUri?.queryParameters['url']?.trim();
    if (innerUrl != null && innerUrl.isNotEmpty) {
      final innerTok = pairUri?.queryParameters['token']?.trim();
      final innerName = pairUri?.queryParameters['name']?.trim();
      final innerPair = (pairUri?.queryParameters['p'] ??
              pairUri?.queryParameters['pair'] ??
              pairUri?.queryParameters['pairCode'])
          ?.trim();
      final nested = parseRemoteHostInput(
        innerUrl,
        explicitToken: (explicitToken != null && explicitToken.trim().isNotEmpty)
            ? explicitToken
            : innerTok,
        defaultDshPort: defaultDshPort,
      );
      if (nested != null) {
        return ParsedRemoteHostInput(
          address: nested.address,
          token: nested.token,
          suggestedName: (innerName != null && innerName.isNotEmpty)
              ? innerName
              : nested.suggestedName,
          pairCode: (innerPair != null && innerPair.isNotEmpty) ? innerPair : nested.pairCode,
          wasAutoPorted: nested.wasAutoPorted,
          wasExtractedFromText: true,
        );
      }
    }
  }

  // 0b) JSON QR payload (`{"url":"http://...","token":"...","name":"..."}`)
  if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final rawUrl = (decoded['url'] ?? decoded['address'] ?? decoded['host'])?.toString().trim();
        if (rawUrl != null && rawUrl.isNotEmpty) {
          final jsonTok = decoded['token']?.toString().trim();
          final jsonName = (decoded['name'] ?? decoded['hostName'])?.toString().trim();
          final jsonPair =
              (decoded['p'] ?? decoded['pair'] ?? decoded['pairCode'])?.toString().trim();
          final nested = parseRemoteHostInput(
            rawUrl,
            explicitToken: (explicitToken != null && explicitToken.trim().isNotEmpty)
                ? explicitToken
                : jsonTok,
            defaultDshPort: defaultDshPort,
          );
          if (nested != null) {
            return ParsedRemoteHostInput(
              address: nested.address,
              token: nested.token,
              suggestedName: (jsonName != null && jsonName.isNotEmpty)
                  ? jsonName
                  : nested.suggestedName,
              pairCode: (jsonPair != null && jsonPair.isNotEmpty) ? jsonPair : nested.pairCode,
              wasAutoPorted: nested.wasAutoPorted,
              wasExtractedFromText: true,
            );
          }
        }
      }
    } catch (_) {}
  }

  var candidate = trimmed;
  var extractedFromText = false;
  String? extraToken;

  // 1) Look for an explicit http(s):// URL anywhere inside pasted text (e.g. `dsh web: http://.../?token=...`).
  final urlMatches = _httpUrlInTextRe.allMatches(trimmed).toList();
  if (urlMatches.isNotEmpty) {
    // Score candidate URLs so non-loopback LAN `token=` URLs always win over `127.0.0.1` loopback URLs!
    int scoreUrl(String raw) {
      final clean = _stripTrailingPunctuation(raw);
      final parsed = Uri.tryParse(clean);
      final isLoop = parsed != null && isLoopbackHost(parsed.host);
      final hasTok = clean.contains('token=');
      final hasPort = clean.contains(':$defaultDshPort') || clean.contains(':3081');
      var s = 0;
      if (hasTok) s += 10;
      if (!isLoop) s += 5;
      if (hasPort) s += 2;
      return s;
    }

    String picked = urlMatches.first.group(0)!;
    var bestScore = scoreUrl(picked);
    for (final m in urlMatches.skip(1)) {
      final u = m.group(0)!;
      final sc = scoreUrl(u);
      if (sc > bestScore) {
        bestScore = sc;
        picked = u;
      }
    }
    candidate = _stripTrailingPunctuation(picked);
    extractedFromText = candidate != trimmed;
  } else {
    // Strip common prefixes like `dsh web:` or `url:` when user pasted without scheme.
    candidate = candidate
        .replaceFirst(RegExp(r'^(?:dsh\s+web|url|host|address)\s*[:：]\s*', caseSensitive: false), '')
        .trim();
    // Take first whitespace-delimited token if user pasted `192.168.1.5:3080 token=xxx`.
    final parts = candidate.split(RegExp(r'\s+'));
    if (parts.length > 1) {
      candidate = _stripTrailingPunctuation(parts.first);
      extractedFromText = true;
    } else {
      candidate = _stripTrailingPunctuation(candidate);
    }
  }

  // Extract inline `GBRIDGE_TOKEN=...` or `token=...` from the broader pasted text.
  final envMatch = _envTokenRe.firstMatch(trimmed);
  if (envMatch != null) {
    extraToken = envMatch.group(1)?.trim();
  }

  if (candidate.isEmpty) return null;

  // 2) Add scheme if omitted: private/IP/localhost/explicit-port -> http://, public domain -> https://.
  var withScheme = candidate;
  var autoPorted = false;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(withScheme)) {
    final hostPart = withScheme.split('/').first.split('?').first;
    // Strip any `user:pass@` prefix BEFORE checking port / bare host / IPv6 so credentials
    // containing a colon are never misread as an IPv6 literal or port separator!
    final authorityHost = hostPart.contains('@')
        ? hostPart.substring(hostPart.lastIndexOf('@') + 1)
        : hostPart;
    final hasPort = _hasExplicitPort(authorityHost);
    final bareHost = _extractHostOnly(authorityHost);
    final isLocalOrIp = _isLocalOrIpHost(bareHost);
    final scheme = (isLocalOrIp || hasPort) ? 'http' : 'https';
    final isBareIpv6 = !authorityHost.startsWith('[') &&
        authorityHost.indexOf(':') != authorityHost.lastIndexOf(':');
    final rest = withScheme.substring(hostPart.length);
    if (isBareIpv6) {
      final userPrefix = hostPart.contains('@')
          ? hostPart.substring(0, hostPart.lastIndexOf('@') + 1)
          : '';
      withScheme = '$scheme://$userPrefix[$authorityHost]$rest';
    } else {
      withScheme = '$scheme://$withScheme';
    }
  }

  var parsed = Uri.tryParse(withScheme);
  if (parsed == null ||
      (parsed.scheme != 'http' && parsed.scheme != 'https') ||
      parsed.host.isEmpty ||
      (parsed.hasPort && (parsed.port < 1 || parsed.port > 65535))) {
    return null;
  }

  final hadExplicitPort = parsed.hasPort;
  // 3) Auto-append default DSH port `:3080` when user types a bare IP / localhost without a port
  //    (e.g., `192.168.1.8` or `http://100.64.0.5`), because stock `dsh web` defaults to `:3080`.
  if (!parsed.hasPort && _isLocalOrIpHost(parsed.host) && parsed.scheme == 'http') {
    parsed = parsed.replace(port: defaultDshPort);
    autoPorted = true;
  }

  // 4) Extract `?token=`, optional `?name=`, and optional `?p=`/`?pairCode=` from query parameters
  //    and strip them from the stored address.
  final queryToken = parsed.queryParameters['token']?.trim();
  final queryName = parsed.queryParameters['name']?.trim();
  final queryPairCode = (parsed.queryParameters['p'] ??
          parsed.queryParameters['pair'] ??
          parsed.queryParameters['pairCode'])
      ?.trim();
  final resolvedToken = (explicitToken != null && explicitToken.trim().isNotEmpty)
      ? explicitToken.trim()
      : (queryToken != null && queryToken.isNotEmpty)
          ? queryToken
          : (extraToken != null && extraToken.isNotEmpty ? extraToken : null);

  if (strictQr) {
    final lowerHost = parsed.host.toLowerCase();
    final lowerPath = parsed.path.toLowerCase();
    final hasHttpScheme = urlMatches.isNotEmpty;
    final hasDshSignal = (resolvedToken != null && resolvedToken.isNotEmpty) ||
        (queryPairCode != null && queryPairCode.isNotEmpty) ||
        _isLocalOrIpHost(parsed.host) ||
        hadExplicitPort ||
        lowerPath.contains('/gbridge') ||
        lowerHost.contains('dsh');
    if (!hasHttpScheme || !hasDshSignal) {
      return null;
    }
  }

  final remainingQuery = Map<String, String>.from(parsed.queryParameters)
    ..remove('token')
    ..remove('name')
    ..remove('p')
    ..remove('pair')
    ..remove('pairCode');
  var cleanPath = parsed.path == '/' ? '' : parsed.path.replaceFirst(RegExp(r'/+$'), '');
  if (cleanPath == '/connect' ||
      cleanPath == '/gbridge/ui' ||
      cleanPath == '/gbridge/v1' ||
      cleanPath.startsWith('/gbridge/v1/') ||
      cleanPath == '/sessions' ||
      cleanPath.startsWith('/sessions/') ||
      cleanPath == '/settings' ||
      cleanPath.startsWith('/settings/') ||
      cleanPath == '/workspaces' ||
      cleanPath.startsWith('/workspaces/')) {
    cleanPath = '';
  }
  final cleanUri = Uri(
    scheme: parsed.scheme,
    userInfo: parsed.userInfo,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
    path: cleanPath,
    queryParameters: remainingQuery.isEmpty ? null : remainingQuery,
  );

  return ParsedRemoteHostInput(
    address: cleanUri.toString(),
    token: resolvedToken,
    suggestedName: (queryName != null && queryName.isNotEmpty) ? queryName : parsed.host,
    pairCode: (queryPairCode != null && queryPairCode.isNotEmpty) ? queryPairCode : null,
    wasAutoPorted: autoPorted,
    wasExtractedFromText: extractedFromText,
  );
}

String _stripTrailingPunctuation(String s) {
  var out = s.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '').trim();
  const trailingStrip = {
    ',', '.', ';', ')', '}', '>', '"', "'", '`',
    '，', '。', '；', '：', '！', '？', '）', '】', '》', '」', '』', '、',
  };
  const leadingStrip = {
    '(', '[', '{', '<', '"', "'", '`',
    '（', '【', '《', '「', '『',
  };
  while (out.isNotEmpty) {
    final last = out[out.length - 1];
    if (trailingStrip.contains(last)) {
      out = out.substring(0, out.length - 1);
      continue;
    }
    // Only strip trailing `]` when it does NOT close an IPv6 bracket (`http://[fd7a::1]`).
    if (last == ']' && !RegExp(r'://\[[^\]]+\]$').hasMatch(out)) {
      out = out.substring(0, out.length - 1);
      continue;
    }
    break;
  }
  while (out.isNotEmpty && leadingStrip.contains(out[0])) {
    out = out.substring(1);
  }
  return out;
}

bool _hasExplicitPort(String authority) {
  if (authority.startsWith('[')) {
    final endBracket = authority.indexOf(']');
    if (endBracket < 0) return false;
    final rest = authority.substring(endBracket + 1);
    return rest.startsWith(':') && rest.length > 1;
  }
  final firstColon = authority.indexOf(':');
  final colon = authority.lastIndexOf(':');
  // Bare IPv6 literal has >=2 colons without brackets — never treat last hex group as a port!
  if (firstColon != colon) return false;
  if (colon <= 0 || colon == authority.length - 1) return false;
  return int.tryParse(authority.substring(colon + 1)) != null;
}

String _extractHostOnly(String authority) {
  if (authority.startsWith('[')) {
    final endBracket = authority.indexOf(']');
    if (endBracket > 0) return authority.substring(1, endBracket);
  }
  final firstColon = authority.indexOf(':');
  final colon = authority.lastIndexOf(':');
  if (firstColon == colon && colon > 0 && int.tryParse(authority.substring(colon + 1)) != null) {
    return authority.substring(0, colon);
  }
  return authority;
}

bool _isLocalOrIpHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '::1' || h.endsWith('.local') || h.endsWith('.lan')) {
    return true;
  }
  if (_ipv4HostRe.hasMatch(h)) return true;
  if (h.contains(':')) return true; // IPv6 literal
  return false;
}

/// Returns true for loopback / unspecified addresses (`localhost`, `127.*`, `::1`, `0.0.0.0`, `::`).
bool isLoopbackHost(String rawHost) {
  var h = rawHost.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']') && h.length >= 2) {
    h = h.substring(1, h.length - 1);
  }
  final zoneIdx = h.indexOf('%');
  if (zoneIdx > 0) h = h.substring(0, zoneIdx);
  if (h.startsWith('::ffff:')) {
    h = h.substring('::ffff:'.length);
  }
  if (h.isEmpty) return false;
  if (h == 'localhost' ||
      h.endsWith('.localhost') ||
      h == '::1' ||
      h == '0:0:0:0:0:0:0:1' ||
      h == '0.0.0.0' ||
      h == '::' ||
      h == '0:0:0:0:0:0:0:0') {
    return true;
  }
  if (h.startsWith('127.')) return true;
  if (h.startsWith('::ffff:127.')) return true;
  return false;
}

/// Returns true if [uri] points back to the current device itself and should be excluded
/// from remote hosts.
///
/// On Android (`isAndroidNative == true`), all loopback addresses (`127.*`, `localhost`, `::1`,
/// `0.0.0.0`) AND any address matching [deviceIps] (the phone's own Wi-Fi/hotspot/LAN IPs)
/// are considered self-device. On desktop/Web, only an exact match with [localHostUri] or
/// [deviceIps] matching the local host port is excluded so local dev testing stays supported.
bool isSelfDeviceUri(
  Uri uri,
  Set<String> deviceIps, {
  required bool isAndroidNative,
  Uri? localHostUri,
}) {
  var h = uri.host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']') && h.length >= 2) {
    h = h.substring(1, h.length - 1);
  }
  final zoneIdx = h.indexOf('%');
  if (zoneIdx > 0) h = h.substring(0, zoneIdx);
  if (h.startsWith('::ffff:')) {
    h = h.substring('::ffff:'.length);
  }
  if (h.isEmpty) return false;

  if (isAndroidNative) {
    if (isLoopbackHost(h)) return true;
    for (final ip in deviceIps) {
      if (ip.trim().toLowerCase() == h) return true;
    }
    return false;
  }

  if (localHostUri != null && localHostUri.hasAuthority) {
    final localPort = localHostUri.hasPort
        ? localHostUri.port
        : (localHostUri.scheme == 'https' ? 443 : 80);
    final uriPort = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    if (uriPort == localPort) {
      final lh = localHostUri.host.trim().toLowerCase();
      if (h == lh || (isLoopbackHost(h) && isLoopbackHost(lh))) {
        return true;
      }
      for (final ip in deviceIps) {
        if (ip.trim().toLowerCase() == h) return true;
      }
    }
  }
  return false;
}
