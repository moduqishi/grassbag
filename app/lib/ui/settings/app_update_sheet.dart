import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import '../onboarding/onboarding_page.dart';

/// Opens a Liquid Glass bottom sheet displaying the latest GitHub Release details,
/// changelog, download progress, and one-tap Android APK installer.
Future<void> showAppUpdateSheet(BuildContext context, WidgetRef ref) {
  final state = ref.read(appProvider);
  final release = state.appUpdateInfo;
  final hasUpdate = state.hasAppUpdate;
  return showGrassBagSheet<void>(
    context,
    title: hasUpdate ? '发现 GrassBag 新版本' : '应用版本与更新',
    subtitle: release != null
        ? 'GitHub Releases · ${release.tagName}'
        : '当前版本 v${state.appVersionLabel}',
    bodyBuilder: (_) => const _AppUpdateSheetBody(),
  );
}

class _AppUpdateSheetBody extends ConsumerWidget {
  const _AppUpdateSheetBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(
      appProvider.select(
        (st) => (
          glassTier: st.glassTier,
          appVersion: st.appVersion,
          appBuildNumber: st.appBuildNumber,
          appVersionLabel: st.appVersionLabel,
          appUpdateInfo: st.appUpdateInfo,
          hasAppUpdate: st.hasAppUpdate,
          checkingAppUpdate: st.checkingAppUpdate,
          appUpdateError: st.appUpdateError,
          appUpdateDownloading: st.appUpdateDownloading,
          appUpdateDownloadProgress: st.appUpdateDownloadProgress,
          appUpdateDownloadBytes: st.appUpdateDownloadBytes,
          appUpdateTotalBytes: st.appUpdateTotalBytes,
          appUpdateLocalApkPath: st.appUpdateLocalApkPath,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final release = s.appUpdateInfo;
    final isAndroid = GrassBagNativeBridge.instance.isAndroidNative;
    final hasLocalApk = s.appUpdateLocalApkPath != null && s.appUpdateLocalApkPath!.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagCard(
          borderRadius: 20,
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.asset(
                  'assets/brand/grassbag_app_icon_1024.png',
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => GrassBagSquircleIcon(
                    icon: CupertinoIcons.sparkles,
                    color: t.primary,
                    size: 48,
                    iconSize: 22,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'GrassBag',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: t.text,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: (s.hasAppUpdate ? t.primary : t.ok).withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            s.hasAppUpdate ? '可更新' : '最新',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: s.hasAppUpdate ? t.primary : t.ok,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      release != null && s.hasAppUpdate
                          ? 'v${s.appVersionLabel}  →  v${release.versionLabel}'
                          : '当前版本 v${s.appVersionLabel}',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: s.hasAppUpdate ? t.primary : t.text2,
                      ),
                    ),
                    if (release != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (release.publishedAt != null)
                            '发布于 ${_formatDate(release.publishedAt!.toLocal())}',
                          if (release.formattedApkSize.isNotEmpty)
                            'APK ${release.formattedApkSize}',
                        ].join(' · '),
                        style: TextStyle(fontSize: 11.5, color: t.text3),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (s.appUpdateError != null && s.appUpdateError!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: t.warn.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              s.appUpdateError!,
              style: TextStyle(fontSize: 12, height: 1.4, color: t.warn),
            ),
          ),
        ],
        if (release != null && release.body.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '更新日志',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: t.text2,
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 210),
            child: GrassBagCard(
              borderRadius: 16,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: SingleChildScrollView(
                child: _ReleaseNotesBlock(markdown: release.body),
              ),
            ),
          ),
        ],
        if (s.appUpdateDownloading) ...[
          const SizedBox(height: 14),
          _DownloadProgressCard(
            progress: s.appUpdateDownloadProgress,
            receivedBytes: s.appUpdateDownloadBytes,
            totalBytes: s.appUpdateTotalBytes,
          ),
          const SizedBox(height: 10),
          GrassBagSecondaryGlassButton(
            label: '取消下载',
            icon: CupertinoIcons.xmark,
            tier: s.glassTier,
            insideGlass: true,
            onTap: ctrl.cancelAppUpdateDownload,
          ),
        ] else ...[
          const SizedBox(height: 14),
          if (release != null && s.hasAppUpdate)
            GrassBagPrimaryGlassButton(
              label: hasLocalApk
                  ? '立即安装已下载 APK'
                  : (isAndroid && release.apkDownloadUrl != null
                      ? '下载并安装新版本'
                      : '前往下载新版本'),
              icon: hasLocalApk
                  ? CupertinoIcons.checkmark_shield_fill
                  : CupertinoIcons.arrow_down_circle_fill,
              tier: s.glassTier,
              insideGlass: true,
              onTap: () => unawaited(ctrl.downloadAndInstallAppUpdate()),
            )
          else
            GrassBagPrimaryGlassButton(
              label: s.checkingAppUpdate ? '正在检查更新…' : '重新检查更新',
              icon: CupertinoIcons.refresh,
              tier: s.glassTier,
              insideGlass: true,
              onTap: s.checkingAppUpdate
                  ? null
                  : () => unawaited(ctrl.checkForAppUpdate(manual: true)),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: GrassBagSecondaryGlassButton(
                  label: 'GitHub Release',
                  icon: CupertinoIcons.arrow_up_right_square,
                  height: 38,
                  tier: s.glassTier,
                  insideGlass: true,
                  onTap: () => unawaited(ctrl.openAppReleasePage()),
                ),
              ),
              if (release != null && s.hasAppUpdate) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: GrassBagSecondaryGlassButton(
                    label: '跳过此版本',
                    height: 38,
                    tier: s.glassTier,
                    insideGlass: true,
                    onTap: () {
                      ctrl.skipAppUpdateVersion(release.versionKey);
                      Navigator.of(context).pop();
                    },
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// Dedicated "关于与更新" Settings detail view with real PackageInfo version readout,
/// GitHub Releases update trigger, changelog preview, and repository links.
class AppAboutAndUpdateView extends ConsumerWidget {
  const AppAboutAndUpdateView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(
      appProvider.select(
        (st) => (
          glassTier: st.glassTier,
          appVersion: st.appVersion,
          appBuildNumber: st.appBuildNumber,
          appVersionLabel: st.appVersionLabel,
          appUpdateInfo: st.appUpdateInfo,
          hasAppUpdate: st.hasAppUpdate,
          hasUnignoredAppUpdate: st.hasUnignoredAppUpdate,
          checkingAppUpdate: st.checkingAppUpdate,
          appUpdateError: st.appUpdateError,
          lastAppUpdateCheckedAt: st.lastAppUpdateCheckedAt,
          skippedAppUpdateVersion: st.skippedAppUpdateVersion,
          appUpdateDownloading: st.appUpdateDownloading,
          appUpdateDownloadProgress: st.appUpdateDownloadProgress,
          appUpdateDownloadBytes: st.appUpdateDownloadBytes,
          appUpdateTotalBytes: st.appUpdateTotalBytes,
          appUpdateLocalApkPath: st.appUpdateLocalApkPath,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final release = s.appUpdateInfo;

    final statusText = s.checkingAppUpdate
        ? '正在连接 GitHub Releases 检查更新…'
        : s.hasAppUpdate && release != null
            ? '发现新版本 v${release.versionLabel}${release.formattedApkSize.isNotEmpty ? '（${release.formattedApkSize}）' : ''}'
            : (s.appUpdateError != null && s.appUpdateError!.isNotEmpty)
                ? s.appUpdateError!
                : (s.lastAppUpdateCheckedAt != null
                    ? '已是最新版本 · 上次检测 ${_formatTime(s.lastAppUpdateCheckedAt!.toLocal())}'
                    : '启动时自动检测 GitHub Releases 新版本');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagCard(
          borderRadius: 24,
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Image.asset(
                  'assets/brand/grassbag_app_icon_1024.png',
                  width: 60,
                  height: 60,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => GrassBagSquircleIcon(
                    icon: CupertinoIcons.sparkles,
                    color: t.primary,
                    size: 60,
                    iconSize: 28,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'GrassBag',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                            color: t.text,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: t.primary.withValues(alpha: 0.13),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            kGrassBagBuildChannel == 'beta' ? 'Beta' : 'Stable',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: t.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '当前版本 v${s.appVersionLabel}',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: t.text2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Android 原生 DeepSeek Harness (DSH) 液态玻璃客户端',
                      style: TextStyle(fontSize: 12, color: t.text3),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        GrassBagGroupedSection(
          header: '版本更新（GitHub Releases）',
          footer: statusText,
          dividerIndent: 56,
          children: [
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: s.hasAppUpdate
                    ? CupertinoIcons.arrow_down_circle_fill
                    : CupertinoIcons.checkmark_seal_fill,
                color: s.hasAppUpdate ? t.primary : t.ok,
                size: 32,
                iconSize: 16,
              ),
              title: Text(
                s.hasAppUpdate && release != null
                    ? '发现新版本 v${release.versionLabel}'
                    : '检查新版本',
              ),
              subtitle: Text(
                s.hasAppUpdate
                    ? '点击查看更新日志并一键下载安装 APK'
                    : '已接入自动更新埋点（每 6 小时静默检测一次）',
              ),
              trailing: s.checkingAppUpdate
                  ? CupertinoActivityIndicator(radius: 9, color: t.primary)
                  : GrassBagSecondaryGlassButton(
                      label: s.hasAppUpdate ? '去更新' : '检查更新',
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tier: s.glassTier,
                      insideGlass: true,
                      accentForeground: s.hasAppUpdate,
                      onTap: () {
                        if (s.hasAppUpdate) {
                          unawaited(showAppUpdateSheet(context, ref));
                        } else {
                          unawaited(() async {
                            final res = await ctrl.checkForAppUpdate(manual: true);
                            if (context.mounted &&
                                res.ok &&
                                res.release != null &&
                                ref.read(appProvider).hasAppUpdate) {
                              await showAppUpdateSheet(context, ref);
                            }
                          }());
                        }
                      },
                    ),
              onTap: () {
                if (s.hasAppUpdate) {
                  unawaited(showAppUpdateSheet(context, ref));
                } else if (!s.checkingAppUpdate) {
                  unawaited(() async {
                    final res = await ctrl.checkForAppUpdate(manual: true);
                    if (context.mounted &&
                        res.ok &&
                        res.release != null &&
                        ref.read(appProvider).hasAppUpdate) {
                      await showAppUpdateSheet(context, ref);
                    }
                  }());
                }
              },
            ),
            if (s.appUpdateDownloading)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _DownloadProgressCard(
                      progress: s.appUpdateDownloadProgress,
                      receivedBytes: s.appUpdateDownloadBytes,
                      totalBytes: s.appUpdateTotalBytes,
                    ),
                    const SizedBox(height: 8),
                    GrassBagSecondaryGlassButton(
                      label: '取消下载',
                      height: 34,
                      tier: s.glassTier,
                      insideGlass: true,
                      onTap: ctrl.cancelAppUpdateDownload,
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        GrassBagGroupedSection(
          header: '项目与发版渠道',
          dividerIndent: 56,
          children: [
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.sparkles,
                color: t.isDark ? const Color(0xFF4AC885) : const Color(0xFF1F9D63),
                size: 32,
                iconSize: 15,
              ),
              title: const Text('查看欢迎与快速引导'),
              subtitle: const Text('重温首次启动引导与环境配置流程'),
              showChevron: true,
              onTap: () {
                Navigator.of(context).push(
                  GrassBagPageRoute<void>(
                    builder: (_) => const OnboardingPage(isFirstLaunch: false),
                  ),
                );
              },
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.chevron_left_slash_chevron_right,
                color: t.isDark ? const Color(0xFF7FA3F2) : const Color(0xFF425EA8),
                size: 32,
                iconSize: 15,
              ),
              title: const Text('GitHub 开源仓库'),
              subtitle: const Text(kGrassBagGitHubRepo),
              showChevron: true,
              onTap: () => unawaited(ctrl.openGitHubRepoPage()),
            ),
            GrassBagListTile(
              leading: GrassBagSquircleIcon(
                icon: CupertinoIcons.cube_box_fill,
                color: t.primary,
                size: 32,
                iconSize: 15,
              ),
              title: const Text('全部历史版本与 APK 下载'),
              subtitle: const Text('GitHub Releases · 双分支自动递增发版'),
              showChevron: true,
              onTap: () => unawaited(ctrl.openAppReleasePage()),
            ),
          ],
        ),
      ],
    );
  }
}

class _DownloadProgressCard extends StatelessWidget {
  const _DownloadProgressCard({
    required this.progress,
    required this.receivedBytes,
    required this.totalBytes,
  });

  final double? progress;
  final int receivedBytes;
  final int totalBytes;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final determinate = progress != null && progress! >= 0;
    final pct = determinate ? (progress!.clamp(0.0, 1.0) * 100).round() : null;
    final bytesLabel = totalBytes > 0
        ? '${_formatBytes(receivedBytes)} / ${_formatBytes(totalBytes)}'
        : '已下载 ${_formatBytes(receivedBytes)}';
    return GrassBagCard(
      borderRadius: 16,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '正在下载 APK 安装包…',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text),
              ),
              const Spacer(),
              Text(
                pct != null ? '$pct%' : bytesLabel,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: t.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: determinate ? progress!.clamp(0.0, 1.0) : null,
              minHeight: 6,
              backgroundColor: t.fill1,
              valueColor: AlwaysStoppedAnimation<Color>(t.primary),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            bytesLabel,
            style: TextStyle(
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: t.text3,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReleaseNotesBlock extends StatelessWidget {
  const _ReleaseNotesBlock({required this.markdown});

  final String markdown;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final rawLines = markdown.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in rawLines)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: _renderLine(t, line),
          ),
      ],
    );
  }

  Widget _renderLine(GrassBagTokens t, String line) {
    if (line.startsWith('## ')) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          line.substring(3).trim(),
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: t.text),
        ),
      );
    }
    if (line.startsWith('### ')) {
      return Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          line.substring(4).trim(),
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text),
        ),
      );
    }
    final isBullet = line.startsWith('- ') || line.startsWith('* ');
    final clean = (isBullet ? line.substring(2) : line).replaceAll('`', '').trim();
    if (isBullet) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 7),
            child: Container(
              width: 4.5,
              height: 4.5,
              decoration: BoxDecoration(color: t.primary, shape: BoxShape.circle),
            ),
          ),
          Expanded(
            child: Text(
              clean,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: t.text2),
            ),
          ),
        ],
      );
    }
    return Text(
      clean,
      style: TextStyle(fontSize: 12.5, height: 1.45, color: t.text2),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
  return '$bytes B';
}

String _formatDate(DateTime dt) {
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

String _formatTime(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m';
}
