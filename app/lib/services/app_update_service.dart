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
  r'^(?:beta-)?v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+(\d+)|\s*\((\d+)\))?$',
  caseSensitive: false,
);

/// Parses `v0.1.2`, `0.1.2+5`, `0.1.2(5)`, `0.1.2-rc.1+3`, or `beta-v0.1.2+5` cleanly.
ParsedAppVersion? parseAppVersion(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final match = _kSemVerRegex.firstMatch(trimmed);
  if (match == null) return null;
  final major = int.tryParse(match.group(1) ?? '');
  final minor = int.tryParse(match.group(2) ?? '');
  final patch = int.tryParse(match.group(3) ?? '');
  if (major == null || minor == null || patch == null) return null;
  final prerelease = match.group(4)?.trim();
  final buildStr = match.group(5) ?? match.group(6);
  final buildNumber = buildStr == null ? null : int.tryParse(buildStr);
  return ParsedAppVersion(
    major: major,
    minor: minor,
    patch: patch,
    buildNumber: buildNumber,
    prerelease: (prerelease == null || prerelease.isEmpty) ? null : prerelease,
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
    return aPre.compareTo(bPre);
  }

  // If both expose positive build numbers, use monotonic Android versionCode as tie-breaker.
  final aBuild = a.buildNumber;
  final bBuild = b.buildNumber;
  if (aBuild != null && bBuild != null && aBuild > 0 && bBuild > 0) {
    return aBuild.compareTo(bBuild);
  }
  return 0;
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

  static final RegExp _kApkBuildRegex = RegExp(r'v?\d+\.\d+\.\d+\+(\d+)', caseSensitive: false);
  static final RegExp _kBodyBuildRegex = RegExp(r'\d+\.\d+\.\d+\s*\((\d+)\)');

  static AppReleaseInfo? fromGitHubReleaseJson(Map<String, dynamic> json) {
    final tag = json['tag_name']?.toString().trim() ?? '';
    if (tag.isEmpty) return null;

    final parsedTag = parseAppVersion(tag);
    final versionName = parsedTag?.coreString ?? tag.replaceFirst(RegExp(r'^v'), '');
    final title = (json['name']?.toString().trim().isNotEmpty == true)
        ? json['name'].toString().trim()
        : tag;
    final body = json['body']?.toString().trim() ?? '';
    final htmlUrl = json['html_url']?.toString().trim() ?? kGrassBagReleasesWebUrl;
    final publishedRaw = json['published_at']?.toString().trim();
    final publishedAt = publishedRaw == null ? null : DateTime.tryParse(publishedRaw);
    final isPrerelease = json['prerelease'] == true;

    String? apkName;
    String? apkDownloadUrl;
    int? apkSizeBytes;

    final assets = json['assets'];
    if (assets is List) {
      Map<String, dynamic>? preferred;
      Map<String, dynamic>? fallback;
      for (final item in assets) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final name = map['name']?.toString() ?? '';
        final lower = name.toLowerCase();
        if (!lower.endsWith('.apk')) continue;
        fallback ??= map;
        if (lower.contains('arm64') || lower.contains('grassbag')) {
          preferred = map;
          if (lower.contains('arm64')) break;
        }
      }
      final chosen = preferred ?? fallback;
      if (chosen != null) {
        apkName = chosen['name']?.toString();
        apkDownloadUrl = chosen['browser_download_url']?.toString();
        apkSizeBytes = (chosen['size'] as num?)?.toInt();
      }
    }

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
        other.body == body;
  }

  @override
  int get hashCode =>
      Object.hash(tagName, versionName, buildNumber, apkDownloadUrl, apkSizeBytes, body);
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

typedef AppUpdateFetcher = Future<AppUpdateHttpResponse> Function(
  Uri uri, {
  Duration timeout,
});

class AppUpdateService {
  const AppUpdateService({
    this.repoSlug = kGrassBagGitHubRepo,
    AppUpdateFetcher? fetcher,
  }) : _fetcher = fetcher ?? fetchAppUpdateJson;

  final String repoSlug;
  final AppUpdateFetcher _fetcher;

  Future<AppReleaseCheckResult> fetchLatestRelease({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final cleanSlug = repoSlug.trim();
    if (cleanSlug.isEmpty || !cleanSlug.contains('/')) {
      return const AppReleaseCheckResult(error: '未配置有效的 GitHub 仓库地址');
    }

    final latestUri = Uri.parse('https://api.github.com/repos/$cleanSlug/releases/latest');
    try {
      final resp = await _fetcher(latestUri, timeout: timeout);
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) {
          final info = AppReleaseInfo.fromGitHubReleaseJson(decoded);
          if (info != null) {
            return AppReleaseCheckResult(release: info);
          }
        }
        return const AppReleaseCheckResult(error: '解析 GitHub Release 元数据失败');
      }

      if (resp.statusCode == 404) {
        // Repo may not have a published stable release yet (or only prereleases).
        return const AppReleaseCheckResult(noReleasePublished: true);
      }

      if (resp.statusCode == 403) {
        return const AppReleaseCheckResult(
          error: 'GitHub API 请求频率受限，请稍后再试或直接前往 Release 页面',
        );
      }

      return AppReleaseCheckResult(
        error: '检查更新失败（GitHub HTTP ${resp.statusCode}）',
      );
    } catch (e) {
      return AppReleaseCheckResult(
        error: '无法连接 GitHub Releases：${_friendlyNetworkError(e)}',
      );
    }
  }

  Future<String> downloadApk({
    required String downloadUrl,
    required String destinationPath,
    void Function(int receivedBytes, int totalBytes)? onProgress,
    bool Function()? isCancelled,
  }) {
    final uri = Uri.parse(downloadUrl.trim());
    return downloadAppUpdateApk(
      uri,
      destinationPath,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
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
