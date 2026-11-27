import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_update_transport.dart';

export 'app_update_transport.dart' show AppUpdateDownloadCancelledException;

/// Default GitHub repository slug for in-app update checks.
/// Overridable at compile time via `--dart-define=GRASSBAG_GITHUB_REPO=owner/repo`.
const String kGrassBagGitHubRepo = String.fromEnvironment(
  'GRASSBAG_GITHUB_REPO',
  defaultValue: 'moduqishi/grassbag',
);

/// Release channel embedded at build time (`stable` or `beta`).
const String kGrassBagBuildChannel = String.fromEnvironment(
  'BUILD_CHANNEL',
  defaultValue: 'stable',
);

/// Compile-time fallback version for Web/non-Android hosts where Android PackageInfo is absent.
const String kGrassBagFallbackVersion = String.fromEnvironment(
  'GRASSBAG_VERSION_NAME',
  defaultValue: '0.1.0',
);

const int kGrassBagFallbackBuildNumber = int.fromEnvironment(
  'GRASSBAG_BUILD_NUMBER',
  defaultValue: 1,
);

/// Automatic background startup check cooldown (6 hours).
const Duration kAppUpdateAutoCheckCooldown = Duration(hours: 6);

String get kGrassBagRepoWebUrl => 'https://github.com/$kGrassBagGitHubRepo';
String get kGrassBagReleasesWebUrl => 'https://github.com/$kGrassBagGitHubRepo/releases';

@immutable
class ParsedAppVersion {
  const ParsedAppVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.buildNumber,
    this.prerelease,
  });

  final int major;
  final int minor;
  final int patch;
  final int? buildNumber;
  final String? prerelease;

  String get coreString => '$major.$minor.$patch';
  String get versionString =>
      (prerelease != null && prerelease!.isNotEmpty) ? '$coreString-$prerelease' : coreString;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ParsedAppVersion &&
        other.major == major &&
        other.minor == minor &&
        other.patch == patch &&
        other.buildNumber == buildNumber &&
        other.prerelease == prerelease;
  }

  @override
  int get hashCode => Object.hash(major, minor, patch, buildNumber, prerelease);
}

final RegExp _kSemVerRegex = RegExp(
  r'^(beta-)?v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+(\d+)|\s*\((\d+)\))?$',
  caseSensitive: false,
);

/// Parses `v0.1.2`, `0.1.2+5`, `0.1.2(5)`, `0.1.2-rc.1+3`, or `beta-v0.1.2+5` cleanly.
ParsedAppVersion? parseAppVersion(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final match = _kSemVerRegex.firstMatch(trimmed);
  if (match == null) return null;
  final hasBetaPrefix = (match.group(1)?.isNotEmpty ?? false);
  final major = int.tryParse(match.group(2) ?? '');
  final minor = int.tryParse(match.group(3) ?? '');
  final patch = int.tryParse(match.group(4) ?? '');
  if (major == null || minor == null || patch == null) return null;
  final rawPre = match.group(5)?.trim();
  final prerelease = (rawPre != null && rawPre.isNotEmpty)
      ? rawPre
      : (hasBetaPrefix ? 'beta' : null);
  final buildStr = match.group(6) ?? match.group(7);
  final buildNumber = buildStr == null ? null : int.tryParse(buildStr);
  return ParsedAppVersion(
    major: major,
    minor: minor,
    patch: patch,
    buildNumber: buildNumber,
    prerelease: prerelease,
  );
}

/// Compares two semantic versions: returns > 0 if [a] > [b], < 0 if [a] < [b], 0 if equal.
int compareAppVersions(ParsedAppVersion a, ParsedAppVersion b) {
  if (a.major != b.major) return a.major.compareTo(b.major);
  if (a.minor != b.minor) return a.minor.compareTo(b.minor);
  if (a.patch != b.patch) return a.patch.compareTo(b.patch);

  // Stable releases outrank prereleases of the exact same X.Y.Z.
  final aPre = a.prerelease;
  final bPre = b.prerelease;
  if (aPre == null && bPre != null) return 1;
  if (aPre != null && bPre == null) return -1;
  if (aPre != null && bPre != null && aPre != bPre) {
    final cmp = _compareSemVerPrerelease(aPre, bPre);
    if (cmp != 0) return cmp;
  }

  // If both expose positive build numbers, use monotonic Android versionCode as tie-breaker.
  final aBuild = a.buildNumber;
  final bBuild = b.buildNumber;
  if (aBuild != null && bBuild != null && aBuild > 0 && bBuild > 0) {
    return aBuild.compareTo(bBuild);
  }
  return 0;
}

/// SemVer 2.0 §11 dot-separated prerelease comparison (`rc.10 > rc.2`, numeric < alphanumeric).
int _compareSemVerPrerelease(String a, String b) {
  final aParts = a.split('.');
  final bParts = b.split('.');
  final minLen = aParts.length < bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < minLen; i++) {
    final ap = aParts[i];
    final bp = bParts[i];
    if (ap == bp) continue;
    final ai = int.tryParse(ap);
    final bi = int.tryParse(bp);
    if (ai != null && bi != null) {
      return ai.compareTo(bi);
    }
    if (ai != null) return -1;
    if (bi != null) return 1;
    return ap.compareTo(bp);
  }
  return aParts.length.compareTo(bParts.length);
}

@immutable
class AppReleaseInfo {
  const AppReleaseInfo({
    required this.tagName,
    required this.versionName,
    this.buildNumber,
    required this.title,
    required this.body,
    required this.htmlUrl,
    this.publishedAt,
    this.isPrerelease = false,
    this.apkName,
    this.apkDownloadUrl,
    this.apkSizeBytes,
    this.checksumsDownloadUrl,
    this.apkSha256,
  });

  final String tagName;
  final String versionName;
  final int? buildNumber;
  final String title;
  final String body;
  final String htmlUrl;
  final DateTime? publishedAt;
  final bool isPrerelease;
  final String? apkName;
  final String? apkDownloadUrl;
  final int? apkSizeBytes;
  final String? checksumsDownloadUrl;
  final String? apkSha256;

  String get versionKey =>
      (buildNumber != null && buildNumber! > 0) ? '$versionName+$buildNumber' : versionName;

  String get versionLabel =>
      (buildNumber != null && buildNumber! > 0) ? '$versionName ($buildNumber)' : versionName;

  String get formattedApkSize {
    final bytes = apkSizeBytes;
    if (bytes == null || bytes <= 0) return '';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  static final RegExp _kApkBuildRegex =
      RegExp(r'v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+|[-_.]b)(\d+)', caseSensitive: false);
  static final RegExp _kBodyBuildRegex = RegExp(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\s*\((\d+)\)');

  static bool isRuntimeAssetTag(String tag) {
    final lower = tag.trim().toLowerCase();
    return lower.startsWith('runtime-') || lower.startsWith('runtime/');
  }

  static AppReleaseInfo? fromGitHubReleaseJson(Map<String, dynamic> json) {
    final tag = json['tag_name']?.toString().trim() ?? '';
    if (tag.isEmpty || isRuntimeAssetTag(tag)) return null;

    final parsedTag = parseAppVersion(tag);
    final versionName = parsedTag?.versionString ?? tag.replaceFirst(RegExp(r'^v'), '');
    final title = (json['name']?.toString().trim().isNotEmpty == true)
        ? json['name'].toString().trim()
        : tag;
    final body = json['body']?.toString().trim() ?? '';
    final rawHtmlUrl = json['html_url']?.toString().trim() ?? '';
    final htmlUrl = rawHtmlUrl.isNotEmpty ? rawHtmlUrl : kGrassBagReleasesWebUrl;
    final publishedRaw = json['published_at']?.toString().trim();
    final publishedAt = publishedRaw == null ? null : DateTime.tryParse(publishedRaw);
    final isPrerelease = json['prerelease'] == true;

    String? apkName;
    String? apkDownloadUrl;
    int? apkSizeBytes;
    String? checksumsDownloadUrl;

    final assets = json['assets'];
    if (assets is List) {
      Map<String, dynamic>? preferred;
      Map<String, dynamic>? fallback;
      for (final item in assets) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final name = map['name']?.toString() ?? '';
        final lower = name.toLowerCase();
        if (lower == 'sha256sums.txt' || lower == 'sha256sums') {
          final rawSumUrl = map['browser_download_url']?.toString().trim() ?? '';
          if (rawSumUrl.isNotEmpty) {
            checksumsDownloadUrl = rawSumUrl;
          }
          continue;
        }
        if (!lower.endsWith('.apk')) continue;
        fallback ??= map;
        if (lower.contains('arm64') || lower.contains('grassbag')) {
          preferred = map;
          if (lower.contains('arm64')) break;
        }
      }
      final chosen = preferred ?? fallback;
      if (chosen != null) {
        final rawApkName = chosen['name']?.toString().trim() ?? '';
        final rawApkUrl = chosen['browser_download_url']?.toString().trim() ?? '';
        apkName = rawApkName.isNotEmpty ? rawApkName : null;
        apkDownloadUrl = rawApkUrl.isNotEmpty ? rawApkUrl : null;
        apkSizeBytes = (chosen['size'] as num?)?.toInt();
      }
      // Continue scanning assets in case SHA256SUMS.txt appeared after the preferred arm64 APK.
      if (checksumsDownloadUrl == null) {
        for (final item in assets) {
          if (item is! Map) continue;
          final name = item['name']?.toString().trim().toLowerCase() ?? '';
          if (name == 'sha256sums.txt' || name == 'sha256sums') {
            final rawSumUrl = item['browser_download_url']?.toString().trim() ?? '';
            if (rawSumUrl.isNotEmpty) {
              checksumsDownloadUrl = rawSumUrl;
              break;
            }
          }
        }
      }
    }

    final apkSha256 = extractApkSha256FromReleaseBody(body, apkName: apkName);

    var buildNumber = parsedTag?.buildNumber;
    if (buildNumber == null && apkName != null) {
      final m = _kApkBuildRegex.firstMatch(apkName);
      if (m != null) buildNumber = int.tryParse(m.group(1) ?? '');
    }
    if (buildNumber == null && body.isNotEmpty) {
      final m = _kBodyBuildRegex.firstMatch(body);
      if (m != null) buildNumber = int.tryParse(m.group(1) ?? '');
    }

    return AppReleaseInfo(
      tagName: tag,
      versionName: versionName,
      buildNumber: buildNumber,
      title: title,
      body: body,
      htmlUrl: htmlUrl,
      publishedAt: publishedAt,
      isPrerelease: isPrerelease,
      apkName: apkName,
      apkDownloadUrl: apkDownloadUrl,
      apkSizeBytes: apkSizeBytes,
      checksumsDownloadUrl: checksumsDownloadUrl,
      apkSha256: apkSha256,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppReleaseInfo &&
        other.tagName == tagName &&
        other.versionName == versionName &&
        other.buildNumber == buildNumber &&
        other.apkDownloadUrl == apkDownloadUrl &&
        other.apkSizeBytes == apkSizeBytes &&
        other.checksumsDownloadUrl == checksumsDownloadUrl &&
        other.apkSha256 == apkSha256 &&
        other.body == body;
  }

  @override
  int get hashCode => Object.hash(
        tagName,
        versionName,
        buildNumber,
        apkDownloadUrl,
        apkSizeBytes,
        checksumsDownloadUrl,
        apkSha256,
        body,
      );
}

final RegExp _kSha256HexRegex = RegExp(r'^[0-9a-fA-F]{64}$');

/// Parses a standard `sha256sum` manifest (`<64-hex>  <filename>`) for [assetName].
String? parseSha256SumsForAsset(String content, String? assetName) {
  final target = assetName?.trim() ?? '';
  String? singleApkFallback;
  var apkEntryCount = 0;
  for (final rawLine in content.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line);
    if (match == null) continue;
    final digest = match.group(1)!.toLowerCase();
    final rawFile = match.group(2)!.trim();
    final baseName = rawFile.split(RegExp(r'[/\\]')).last;
    if (target.isNotEmpty && (rawFile == target || baseName == target)) {
      return digest;
    }
    if (baseName.toLowerCase().endsWith('.apk')) {
      apkEntryCount++;
      singleApkFallback = digest;
    }
  }
  if (target.isEmpty && apkEntryCount == 1) {
    return singleApkFallback;
  }
  return null;
}

/// Extracts an optional 64-hex APK SHA-256 embedded in release notes as a secondary cross-check.
String? extractApkSha256FromReleaseBody(String body, {String? apkName}) {
  if (body.isEmpty) return null;
  final fromSums = parseSha256SumsForAsset(body, apkName);
  if (fromSums != null) return fromSums;
  final target = apkName?.trim() ?? '';
  for (final rawLine in body.split(RegExp(r'\r?\n'))) {
    final lower = rawLine.toLowerCase();
    final mentionsApk = (target.isNotEmpty && rawLine.contains(target)) ||
        lower.contains('.apk') ||
        lower.contains('apk sha');
    if (!mentionsApk) continue;
    final m = RegExp(r'\b([0-9a-fA-F]{64})\b').firstMatch(rawLine);
    if (m != null) return m.group(1)!.toLowerCase();
  }
  return null;
}

bool isRemoteReleaseNewer({
  required String currentVersion,
  required int currentBuild,
  required AppReleaseInfo remote,
}) {
  final current = parseAppVersion('$currentVersion+$currentBuild') ??
      parseAppVersion(currentVersion);
  final candidate = parseAppVersion(
        remote.buildNumber != null && remote.buildNumber! > 0
            ? '${remote.versionName}+${remote.buildNumber}'
            : remote.versionName,
      ) ??
      parseAppVersion(remote.tagName);
  if (current == null || candidate == null) {
    return remote.versionName.trim() != currentVersion.trim();
  }
  return compareAppVersions(candidate, current) > 0;
}

@immutable
class AppReleaseCheckResult {
  const AppReleaseCheckResult({
    this.release,
    this.error,
    this.noReleasePublished = false,
  });

  final AppReleaseInfo? release;
  final String? error;
  final bool noReleasePublished;

  bool get ok => error == null;
}

/// Ordered China mirror prefixes tried BEFORE direct GitHub API calls when checking updates.
const List<String> kAppUpdateApiMirrorPrefixes = [
  'https://gh-proxy.com/',
];

/// Ordered China mirror prefixes tried BEFORE direct GitHub Releases when downloading APKs.
const List<String> kAppUpdateDownloadMirrorPrefixes = [
  'https://gh-proxy.com/',
  'https://ghfast.top/',
];

bool _looksLikeGitHubProxyPrefix(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.host.isEmpty) return false;
  if (_isGitHubUrl(trimmed)) return false;
  return uri.scheme == 'https';
}

bool _isGitHubUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  final host = uri?.host.toLowerCase() ?? '';
  return host == 'github.com' ||
      host == 'api.github.com' ||
      host.endsWith('.github.com') ||
      host.endsWith('.githubusercontent.com');
}

String _prefixWithMirror(String mirrorPrefix, String targetUrl) {
  final cleanPrefix = mirrorPrefix.trim().replaceAll(RegExp(r'/+$'), '');
  return '$cleanPrefix/$targetUrl';
}

/// Builds prioritized candidate URIs for GitHub API release metadata checks:
/// custom proxy (if configured) → China mirrors (`gh-proxy.com`) → direct `api.github.com`.
List<Uri> buildAppUpdateApiCandidateUris(
  String rawApiUrl, {
  String? customMirrorUrl,
}) {
  final cleanTarget = rawApiUrl.trim();
  final seen = <String>{};
  final out = <Uri>[];
  void addUrl(String u) {
    final trimmed = u.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) return;
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      out.add(parsed);
    }
  }

  if (_isGitHubUrl(cleanTarget)) {
    final custom = customMirrorUrl?.trim() ?? '';
    if (custom.isNotEmpty && _looksLikeGitHubProxyPrefix(custom)) {
      addUrl(_prefixWithMirror(custom, cleanTarget));
    }
    for (final prefix in kAppUpdateApiMirrorPrefixes) {
      addUrl(_prefixWithMirror(prefix, cleanTarget));
    }
  }
  addUrl(cleanTarget);
  return out;
}

/// Builds prioritized candidate URIs for APK downloads:
/// custom mirror (if configured) → `gh-proxy.com` → `ghfast.top` → direct GitHub Releases.
List<Uri> buildAppUpdateDownloadCandidateUris(
  String rawDownloadUrl, {
  String? customMirrorUrl,
}) {
  final cleanTarget = rawDownloadUrl.trim();
  final seen = <String>{};
  final out = <Uri>[];
  void addUrl(String u) {
    final trimmed = u.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) return;
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      out.add(parsed);
    }
  }

  if (_isGitHubUrl(cleanTarget)) {
    final custom = customMirrorUrl?.trim() ?? '';
    if (custom.isNotEmpty && _looksLikeGitHubProxyPrefix(custom)) {
      addUrl(_prefixWithMirror(custom, cleanTarget));
    }
    for (final prefix in kAppUpdateDownloadMirrorPrefixes) {
      addUrl(_prefixWithMirror(prefix, cleanTarget));
    }
  }
  addUrl(cleanTarget);
  return out;
}

/// Human-readable short label describing the active update mirror/direct source.
String formatAppUpdateSourceLabel(Uri uri) {
  final host = uri.host.toLowerCase();
  if (host.contains('gh-proxy')) return '国内镜像 1';
  if (host.contains('ghfast')) return '国内镜像 2';
  if (host == 'github.com' ||
      host == 'api.github.com' ||
      host.endsWith('.github.com') ||
      host.endsWith('.githubusercontent.com')) {
    return 'GitHub 直连';
  }
  return host.isNotEmpty ? host : '在线源';
}

typedef AppUpdateFetcher = Future<AppUpdateHttpResponse> Function(
  Uri uri, {
  Duration timeout,
});

/// Builds candidate URIs for fetching trusted release checksums (`SHA256SUMS.txt`):
/// ALWAYS prioritizes direct official GitHub first before falling back to mirrors so
/// an untrusted mirror cannot spoof both the APK and its checksum manifest simultaneously.
List<Uri> buildAppUpdateTrustedChecksumCandidateUris(
  String rawChecksumUrl, {
  String? customMirrorUrl,
}) {
  final cleanTarget = rawChecksumUrl.trim();
  final seen = <String>{};
  final out = <Uri>[];
  void addUrl(String u) {
    final trimmed = u.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) return;
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      out.add(parsed);
    }
  }

  addUrl(cleanTarget);
  if (_isGitHubUrl(cleanTarget)) {
    final custom = customMirrorUrl?.trim() ?? '';
    if (custom.isNotEmpty && _looksLikeGitHubProxyPrefix(custom)) {
      addUrl(_prefixWithMirror(custom, cleanTarget));
    }
    for (final prefix in kAppUpdateDownloadMirrorPrefixes) {
      addUrl(_prefixWithMirror(prefix, cleanTarget));
    }
  }
  return out;
}

typedef AppUpdateApkDownloader = Future<String> Function(
  Uri uri,
  String destinationPath, {
  void Function(int receivedBytes, int totalBytes)? onProgress,
  bool Function()? isCancelled,
  int? expectedSizeBytes,
  String? expectedSha256,
  void Function(void Function() abort)? onAbortReady,
});

class AppUpdateService {
  const AppUpdateService({
    this.repoSlug = kGrassBagGitHubRepo,
    AppUpdateFetcher? fetcher,
    AppUpdateApkDownloader? downloader,
  })  : _fetcher = fetcher ?? fetchAppUpdateJson,
        _downloader = downloader ?? downloadAppUpdateApk;

  final String repoSlug;
  final AppUpdateFetcher _fetcher;
  final AppUpdateApkDownloader _downloader;

  Future<({AppUpdateHttpResponse? response, Object? error, bool sawNotFound, bool sawRateLimit})>
      _fetchFirstValidJson(
    String rawApiUrl, {
    required Duration timeout,
    String? customMirrorUrl,
    bool expectList = false,
  }) async {
    final candidates = buildAppUpdateApiCandidateUris(
      rawApiUrl,
      customMirrorUrl: customMirrorUrl,
    );
    Object? lastError;
    AppUpdateHttpResponse? lastResponse;
    var officialNotFound = false;
    var allNotFound = candidates.isNotEmpty;
    var sawRateLimit = false;

    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      final isDirectFallback = i == candidates.length - 1;
      try {
        final resp = await _fetcher(candidate, timeout: timeout);
        if (resp.statusCode == 200) {
          allNotFound = false;
          final bodyTrim = resp.body.trimLeft();
          if (bodyTrim.startsWith('{') || bodyTrim.startsWith('[')) {
            try {
              final decoded = jsonDecode(bodyTrim);
              final isValidRelease = expectList
                  ? (decoded is List &&
                      (decoded.isEmpty ||
                          decoded.any((e) => e is Map && e.containsKey('tag_name'))))
                  : (decoded is Map && decoded.containsKey('tag_name'));
              if (isValidRelease) {
                return (
                  response: resp,
                  error: null,
                  sawNotFound: false,
                  sawRateLimit: false,
                );
              }
            } catch (_) {}
          }
          // Mirror returned HTML/text or non-release JSON error page — fail over without retaining it.
          lastError = const FormatException('镜像返回了非法的版本 JSON 内容');
          continue;
        }
        lastResponse = resp;
        if (resp.statusCode == 404) {
          if (isDirectFallback) {
            officialNotFound = true;
            return (
              response: resp,
              error: null,
              sawNotFound: true,
              sawRateLimit: false,
            );
          }
          continue;
        }
        allNotFound = false;
        if (resp.statusCode == 403) {
          sawRateLimit = true;
          if (isDirectFallback) {
            return (
              response: resp,
              error: null,
              sawNotFound: false,
              sawRateLimit: true,
            );
          }
          continue;
        }
      } catch (e) {
        allNotFound = false;
        lastError = e;
      }
    }

    return (
      response: lastResponse,
      error: lastError,
      sawNotFound: officialNotFound || allNotFound,
      sawRateLimit: sawRateLimit,
    );
  }

  Future<AppReleaseCheckResult> fetchLatestRelease({
    Duration timeout = const Duration(seconds: 12),
    String? customMirrorUrl,
  }) async {
    final cleanSlug = repoSlug.trim();
    if (cleanSlug.isEmpty || !cleanSlug.contains('/')) {
      return const AppReleaseCheckResult(error: '未配置有效的 GitHub 仓库地址');
    }

    final latestUrl = 'https://api.github.com/repos/$cleanSlug/releases/latest';
    final latestAttempt = await _fetchFirstValidJson(
      latestUrl,
      timeout: timeout,
      customMirrorUrl: customMirrorUrl,
    );
    final resp = latestAttempt.response;
    if (resp != null && resp.statusCode == 200) {
      try {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) {
          final info = AppReleaseInfo.fromGitHubReleaseJson(decoded);
          if (info != null) {
            return AppReleaseCheckResult(release: info);
          }
          // If `/releases/latest` ever points to a non-app runtime asset release, fall back
          // to scanning recent releases (also mirror-first) so app update checks never break.
          final listUrl = 'https://api.github.com/repos/$cleanSlug/releases?per_page=10';
          final listAttempt = await _fetchFirstValidJson(
            listUrl,
            timeout: timeout,
            customMirrorUrl: customMirrorUrl,
            expectList: true,
          );
          final listResp = listAttempt.response;
          if (listResp != null && listResp.statusCode == 200) {
            final listDecoded = jsonDecode(listResp.body);
            if (listDecoded is List) {
              for (final item in listDecoded) {
                if (item is! Map) continue;
                final map = Map<String, dynamic>.from(item);
                if (map['draft'] == true || map['prerelease'] == true) continue;
                final fallbackInfo = AppReleaseInfo.fromGitHubReleaseJson(map);
                if (fallbackInfo != null && fallbackInfo.apkDownloadUrl != null) {
                  return AppReleaseCheckResult(release: fallbackInfo);
                }
              }
            }
          }
        }
        return const AppReleaseCheckResult(error: '解析 GitHub Release 元数据失败');
      } catch (e) {
        return AppReleaseCheckResult(
          error: '解析更新元数据失败：${_friendlyNetworkError(e)}',
        );
      }
    }

    if (latestAttempt.sawNotFound && (resp == null || resp.statusCode == 404)) {
      return const AppReleaseCheckResult(noReleasePublished: true);
    }

    if (latestAttempt.sawRateLimit && (resp == null || resp.statusCode == 403)) {
      return const AppReleaseCheckResult(
        error: 'GitHub API 请求频率受限，请稍后再试或直接前往 Release 页面',
      );
    }

    if (resp != null && resp.statusCode != 200) {
      return AppReleaseCheckResult(
        error: '检查更新失败（GitHub HTTP ${resp.statusCode}）',
      );
    }

    return AppReleaseCheckResult(
      error: '无法连接更新源：${_friendlyNetworkError(latestAttempt.error ?? '网络异常')}',
    );
  }

  /// Fetches and verifies the trusted SHA-256 digest for [release]'s APK from `SHA256SUMS.txt`
  /// (prioritizing direct GitHub first) and cross-checks against any digest embedded in release notes.
  Future<String?> resolveExpectedApkSha256(
    AppReleaseInfo release, {
    Duration timeout = const Duration(seconds: 12),
    String? customMirrorUrl,
  }) async {
    final bodyDigest = release.apkSha256?.trim().toLowerCase();
    final validBodyDigest =
        (bodyDigest != null && _kSha256HexRegex.hasMatch(bodyDigest)) ? bodyDigest : null;
    final sumsUrl = release.checksumsDownloadUrl?.trim() ?? '';
    if (sumsUrl.isEmpty) {
      return validBodyDigest;
    }

    final candidates = buildAppUpdateTrustedChecksumCandidateUris(
      sumsUrl,
      customMirrorUrl: customMirrorUrl,
    );
    Object? lastError;
    for (final candidate in candidates) {
      try {
        final resp = await _fetcher(candidate, timeout: timeout);
        if (resp.statusCode != 200) {
          lastError = StateError('SHA256SUMS HTTP ${resp.statusCode}');
          continue;
        }
        final parsed = parseSha256SumsForAsset(resp.body, release.apkName);
        if (parsed == null) {
          lastError = const FormatException('SHA256SUMS.txt 中未找到对应 APK 的 SHA-256 校验值');
          continue;
        }
        if (validBodyDigest != null && validBodyDigest != parsed) {
          throw const FormatException('发布校验清单与版本说明中的 APK SHA-256 不一致，已中止更新');
        }
        return parsed;
      } catch (e) {
        if (e is FormatException && e.message.contains('不一致')) {
          rethrow;
        }
        lastError = e;
      }
    }
    if (validBodyDigest != null) {
      return validBodyDigest;
    }
    throw Exception('无法获取可信 APK SHA-256 校验清单：${_friendlyNetworkError(lastError ?? '网络异常')}');
  }

  Future<String> downloadApk({
    required String downloadUrl,
    required String destinationPath,
    void Function(int receivedBytes, int totalBytes)? onProgress,
    bool Function()? isCancelled,
    int? expectedSizeBytes,
    String? expectedSha256,
    void Function(void Function() abort)? onAbortReady,
    String? customMirrorUrl,
    void Function(String sourceLabel)? onSourceChanged,
  }) async {
    final candidates = buildAppUpdateDownloadCandidateUris(
      downloadUrl,
      customMirrorUrl: customMirrorUrl,
    );
    if (candidates.isEmpty) {
      throw ArgumentError('无效的 APK 下载地址');
    }

    Object? lastError;
    for (final candidate in candidates) {
      if (isCancelled?.call() == true) {
        throw const AppUpdateDownloadCancelledException();
      }
      onSourceChanged?.call(formatAppUpdateSourceLabel(candidate));
      try {
        return await _downloader(
          candidate,
          destinationPath,
          onProgress: onProgress,
          isCancelled: isCancelled,
          expectedSizeBytes: expectedSizeBytes,
          expectedSha256: expectedSha256,
          onAbortReady: onAbortReady,
        );
      } on AppUpdateDownloadCancelledException {
        rethrow;
      } catch (e) {
        if (isCancelled?.call() == true) {
          throw const AppUpdateDownloadCancelledException();
        }
        lastError = e;
      }
    }
    throw lastError ?? Exception('所有更新下载源均不可用，请检查网络连接后重试');
  }

  static String _friendlyNetworkError(Object error) {
    final raw = error.toString();
    if (raw.contains('TimeoutException')) return '连接超时，请检查网络或代理设置';
    if (raw.contains('SocketException') || raw.contains('Failed host lookup')) {
      return '网络不可达或 DNS 解析失败';
    }
    if (raw.contains('HandshakeException')) return 'TLS 证书校验失败';
    return raw.length > 90 ? '${raw.substring(0, 90)}…' : raw;
  }
}
