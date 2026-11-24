import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:grassbag/services/app_update_service.dart';
import 'package:grassbag/services/app_update_transport.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/theme/grassbag_theme.dart';
import 'package:grassbag/ui/settings/app_update_sheet.dart';

void main() {
  group('SemVer & build comparison', () {
    test('parses v-prefix, build numbers, parentheses, and prereleases', () {
      expect(
        parseAppVersion('v0.1.2+5'),
        const ParsedAppVersion(major: 0, minor: 1, patch: 2, buildNumber: 5),
      );
      expect(
        parseAppVersion('0.2.0(12)'),
        const ParsedAppVersion(major: 0, minor: 2, patch: 0, buildNumber: 12),
      );
      expect(
        parseAppVersion('beta-v1.0.0-rc.1+8'),
        const ParsedAppVersion(
          major: 1,
          minor: 0,
          patch: 0,
          buildNumber: 8,
          prerelease: 'rc.1',
        ),
      );
      expect(parseAppVersion('not-a-version'), isNull);
    });

    test('compares major/minor/patch, stable vs prerelease, and monotonic buildNumber', () {
      final v010 = parseAppVersion('0.1.0+1')!;
      final v011 = parseAppVersion('0.1.1+2')!;
      final v020 = parseAppVersion('0.2.0+10')!;
      final v011Build3 = parseAppVersion('0.1.1+3')!;
      final v011Pre = parseAppVersion('0.1.1-beta.1+5')!;

      expect(compareAppVersions(v011, v010), greaterThan(0));
      expect(compareAppVersions(v020, v011), greaterThan(0));
      expect(compareAppVersions(v011Build3, v011), greaterThan(0));
      expect(compareAppVersions(v011, v011Pre), greaterThan(0));
      expect(compareAppVersions(v010, v010), 0);
    });
  });

  group('GitHub Release JSON parsing & AppUpdateService', () {
    test('selects arm64 APK asset and extracts build number from filename/body', () {
      final info = AppReleaseInfo.fromGitHubReleaseJson({
        'tag_name': 'v0.1.2',
        'name': 'v0.1.2',
        'body': '## 正式版发布\n\n- 版本：`0.1.2(3)`\n- 优化液态玻璃质感',
        'html_url': 'https://github.com/moduqishi/grassbag/releases/tag/v0.1.2',
        'published_at': '2026-11-24T10:00:00Z',
        'prerelease': false,
        'assets': [
          {
            'name': 'SHA256SUMS.txt',
            'size': 256,
            'browser_download_url': 'https://example.com/SHA256SUMS.txt',
          },
          {
            'name': 'grassbag-v0.1.2+3-arm64-v8a.apk',
            'size': 210 * 1024 * 1024,
            'browser_download_url': 'https://example.com/grassbag-v0.1.2+3-arm64-v8a.apk',
          },
        ],
      });

      expect(info, isNotNull);
      expect(info!.versionName, '0.1.2');
      expect(info.buildNumber, 3);
      expect(info.versionKey, '0.1.2+3');
      expect(info.versionLabel, '0.1.2 (3)');
      expect(info.apkName, 'grassbag-v0.1.2+3-arm64-v8a.apk');
      expect(info.formattedApkSize, '210.0 MB');
      expect(
        isRemoteReleaseNewer(currentVersion: '0.1.0', currentBuild: 1, remote: info),
        isTrue,
      );
      expect(
        isRemoteReleaseNewer(currentVersion: '0.1.2', currentBuild: 3, remote: info),
        isFalse,
      );
    });

    test('handles HTTP 200, 404 (no releases yet), and 403 rate limit cleanly', () async {
      final okService = AppUpdateService(
        repoSlug: 'moduqishi/grassbag',
        fetcher: (uri, {timeout = const Duration(seconds: 12)}) async {
          expect(uri.toString(), 'https://api.github.com/repos/moduqishi/grassbag/releases/latest');
          return AppUpdateHttpResponse(
            statusCode: 200,
            body: jsonEncode({
              'tag_name': 'v0.1.5',
              'name': 'v0.1.5',
              'body': '- 修复若干细节',
              'html_url': 'https://github.com/moduqishi/grassbag/releases/tag/v0.1.5',
              'assets': [
                {
                  'name': 'grassbag-v0.1.5+6-arm64-v8a.apk',
                  'size': 12345678,
                  'browser_download_url': 'https://example.com/app.apk',
                },
              ],
            }),
          );
        },
      );
      final okRes = await okService.fetchLatestRelease();
      expect(okRes.ok, isTrue);
      expect(okRes.release?.versionName, '0.1.5');
      expect(okRes.release?.buildNumber, 6);

      final emptyService = AppUpdateService(
        repoSlug: 'moduqishi/grassbag',
        fetcher: (_, {timeout = const Duration(seconds: 12)}) async =>
            const AppUpdateHttpResponse(statusCode: 404, body: '{"message":"Not Found"}'),
      );
      final emptyRes = await emptyService.fetchLatestRelease();
      expect(emptyRes.ok, isTrue);
      expect(emptyRes.noReleasePublished, isTrue);

      final rateLimited = AppUpdateService(
        repoSlug: 'moduqishi/grassbag',
        fetcher: (_, {timeout = const Duration(seconds: 12)}) async =>
            const AppUpdateHttpResponse(statusCode: 403, body: '{"message":"rate limit"}'),
      );
      final limitedRes = await rateLimited.fetchLatestRelease();
      expect(limitedRes.ok, isFalse);
      expect(limitedRes.error, contains('受限'));
    });
  });

  group('GrassBagController & AppAboutAndUpdateView integration', () {
    testWidgets('detects new release, renders update UI, and respects skip version', (tester) async {
      GrassBagController.disableAutoAppUpdateCheck = true;
      addTearDown(() => GrassBagController.disableAutoAppUpdateCheck = false);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final ctrl = container.read(appProvider.notifier);
      ctrl.configureAppUpdateServiceForTest(
        AppUpdateService(
          repoSlug: 'moduqishi/grassbag',
          fetcher: (_, {timeout = const Duration(seconds: 12)}) async => AppUpdateHttpResponse(
            statusCode: 200,
            body: jsonEncode({
              'tag_name': 'v0.2.0',
              'name': 'v0.2.0',
              'body': '## 正式版发布\n- 版本：`0.2.0(10)`\n- 全新版本更新体系',
              'html_url': 'https://github.com/moduqishi/grassbag/releases/tag/v0.2.0',
              'assets': [
                {
                  'name': 'grassbag-v0.2.0+10-arm64-v8a.apk',
                  'size': 188 * 1024 * 1024,
                  'browser_download_url': 'https://example.com/grassbag-v0.2.0+10-arm64-v8a.apk',
                },
              ],
            }),
          ),
        ),
      );

      await ctrl.checkForAppUpdate(manual: true);
      expect(container.read(appProvider).hasAppUpdate, isTrue);
      expect(container.read(appProvider).hasUnignoredAppUpdate, isTrue);
      expect(container.read(appProvider).showAppUpdateBanner, isTrue);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: AppAboutAndUpdateView(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('当前版本 v0.1.0 (1)'), findsOneWidget);
      expect(find.text('发现新版本 v0.2.0 (10)'), findsOneWidget);
      expect(find.textContaining('188.0 MB'), findsOneWidget);
      expect(find.text('moduqishi/grassbag'), findsOneWidget);

      ctrl.skipAppUpdateVersion('0.2.0+10');
      expect(container.read(appProvider).hasUnignoredAppUpdate, isFalse);
      expect(container.read(appProvider).showAppUpdateBanner, isFalse);

      // Pump past toast & prefs debounce timers before widget tree teardown.
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
