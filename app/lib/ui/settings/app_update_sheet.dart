import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
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
  return showGrassBagSheet<void>(
    context,
    title: '应用版本与更新',
    subtitle: '优先国内镜像加速 · 自动回退 GitHub Releases',
    icon: CupertinoIcons.arrow_down_circle_fill,
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
          appUpdateDownloadSource: st.appUpdateDownloadSource,
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
        GrassBagSheetSection(
          borderRadius: 16,
          padding: const EdgeInsets.all(14),
          children: [
            Row(
              children: [
              ClipRSuperellipse(
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
                        Builder(
                          builder: (_) {
                            final hasErr =
                                s.appUpdateError != null && s.appUpdateError!.isNotEmpty;
                            final (label, fg, bg) = s.checkingAppUpdate
                                ? ('检查中', t.primary, t.primarySoft)
                                : s.hasAppUpdate
                                    ? ('可更新', t.primary, t.primarySoft)
                                    : hasErr
                                        ? ('检查失败', t.warn, t.warnSoft)
                                        : release != null
                                            ? ('最新', t.ok, t.okSoft)
                                            : ('待检查', t.text3, t.fill1);
                            return GrassBagFresnelGlassSurface(
                              isPill: true,
                              innerWell: true,
                              tintColor: bg,
                              padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 2.5),
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: fg,
                                ),
                              ),
                            );
                          },
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
          ],
        ),
        if (s.appUpdateError != null && s.appUpdateError!.isNotEmpty) ...[
          const SizedBox(height: 10),
          GrassBagStatusBanner(
            tone: GrassBagBannerTone.warn,
            message: s.appUpdateError!,
            borderRadius: 14,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
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
          GrassBagSheetSection(
            borderRadius: 16,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 186),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: _ReleaseNotesBlock(markdown: release.body),
                ),
              ),
            ],
          ),
        ],
        if (s.appUpdateDownloading) ...[
          const SizedBox(height: 14),
          _DownloadProgressCard(
            progress: s.appUpdateDownloadProgress,
            receivedBytes: s.appUpdateDownloadBytes,
            totalBytes: s.appUpdateTotalBytes,
            sourceLabel: s.appUpdateDownloadSource,
            insideSheet: true,
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
              enabled: !s.checkingAppUpdate,
              onTap: s.checkingAppUpdate
                  ? null
                  : () => unawaited(ctrl.checkForAppUpdate(manual: true)),
            ),
          const SizedBox(height: 10),
          if (release != null &&
              s.hasAppUpdate &&
              hasLocalApk &&
              isAndroid &&
              release.apkDownloadUrl != null) ...[
            Row(
              children: [
                Expanded(
                  child: GrassBagSecondaryGlassButton(
                    label: '重新下载',
                    icon: CupertinoIcons.arrow_clockwise,
                    height: 38,
                    tier: s.glassTier,
                    insideGlass: true,
                    onTap: () => unawaited(ctrl.downloadAndInstallAppUpdate(forceRedownload: true)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GrassBagSecondaryGlassButton(
                    label: '发布页',
                    icon: CupertinoIcons.arrow_up_right_square,
                    height: 38,
                    tier: s.glassTier,
                    insideGlass: true,
                    onTap: () => unawaited(ctrl.openAppReleasePage()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            GrassBagSpringTap(
              enablePointerGlow: false,
              haptic: true,
              onTap: () {
                ctrl.skipAppUpdateVersion(release.versionKey);
                Navigator.of(context).pop();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  '跳过此版本',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: t.text3,
                  ),
                ),
              ),
            ),
          ] else
            Row(
              children: [
                Expanded(
                  child: GrassBagSecondaryGlassButton(
                    label: '发布页',
                    icon: CupertinoIcons.arrow_up_right_square,
                    height: 38,
                    tier: s.glassTier,
                    insideGlass: true,
                    onTap: () => unawaited(ctrl.openAppReleasePage()),
                  ),
                ),
                if (release != null && s.hasAppUpdate) ...[
                  const SizedBox(width: 8),
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
          appUpdateDownloadSource: st.appUpdateDownloadSource,
          appUpdateLocalApkPath: st.appUpdateLocalApkPath,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final release = s.appUpdateInfo;

    final statusText = s.checkingAppUpdate
        ? '正在通过国内镜像检查新版本…'
        : s.hasAppUpdate && release != null
            ? '发现新版本 v${release.versionLabel}${release.formattedApkSize.isNotEmpty ? '（${release.formattedApkSize}）' : ''}'
            : (s.appUpdateError != null && s.appUpdateError!.isNotEmpty)
                ? s.appUpdateError!
                : (s.lastAppUpdateCheckedAt != null
                    ? '已是最新版本 · 上次检测 ${_formatTime(s.lastAppUpdateCheckedAt!.toLocal())}'
                    : '优先通过国内镜像自动检测并加速下载新版本，失败自动回退 GitHub 官方源');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagCard(
          borderRadius: 24,
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              DecoratedBox(
                decoration: ShapeDecoration(
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  shadows: [
                    BoxShadow(
                      color: t.primary.withValues(alpha: t.isDark ? 0.34 : 0.24),
                      blurRadius: 16,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: CustomPaint(
                  foregroundPainter: s.glassTier == GrassBagGlassTier.solid
                      ? null
                      : GrassBagFresnelRimPainter(
                          isDark: t.isDark,
                          borderRadius: 18,
                          accent: t.primaryHi,
                          tinted: true,
                          frosted: s.glassTier == GrassBagGlassTier.frosted,
                          strokeWidth: 0.9,
                        ),
                  child: ClipRSuperellipse(
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
                        GrassBagFresnelGlassSurface(
                          isPill: true,
                          innerWell: true,
                          tintColor: t.primary.withValues(alpha: t.isDark ? 0.22 : 0.13),
                          padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 2.5),
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
                      kIsWeb
                          ? 'DeepSeek Harness (DSH) 液态玻璃网页端'
                          : (defaultTargetPlatform == TargetPlatform.android
                              ? 'Android 原生 DeepSeek Harness (DSH) 液态玻璃客户端'
                              : '跨平台 DeepSeek Harness (DSH) 液态玻璃客户端'),
                      style: TextStyle(fontSize: 12, color: t.text3),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (s.appUpdateError != null && s.appUpdateError!.isNotEmpty) ...[
          GrassBagStatusBanner(
            tone: GrassBagBannerTone.warn,
            icon: CupertinoIcons.exclamationmark_triangle_fill,
            message: s.appUpdateError!,
            borderRadius: 16,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            trailing: GrassBagSecondaryGlassButton(
              label: '重试',
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tier: s.glassTier,
              insideGlass: true,
              onTap: s.checkingAppUpdate
                  ? null
                  : () => unawaited(ctrl.checkForAppUpdate(manual: true)),
            ),
          ),
          const SizedBox(height: 12),
        ],
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
                    : '已开启自动检查更新（每 6 小时静默检测一次）',
              ),
              trailing: s.checkingAppUpdate
                  ? GrassBagActivityIndicator(radius: 9, color: t.primary)
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
                      sourceLabel: s.appUpdateDownloadSource,
                      insideSheet: true,
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
    this.sourceLabel = '',
    this.insideSheet = false,
  });

  final double? progress;
  final int receivedBytes;
  final int totalBytes;
  final String sourceLabel;
  final bool insideSheet;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final determinate = progress != null && progress! >= 0;
    final pct = determinate ? (progress!.clamp(0.0, 1.0) * 100).round() : null;
    final bytesLabel = totalBytes > 0
        ? '${_formatBytes(receivedBytes)} / ${_formatBytes(totalBytes)}'
        : '已下载 ${_formatBytes(receivedBytes)}';
    final titleText = sourceLabel.isNotEmpty
        ? '正在通过 $sourceLabel 下载安装包…'
        : '正在下载 APK 安装包…';
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                titleText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              pct != null ? '$pct%' : '下载中',
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
        GrassBagProgressBar(
          value: determinate ? progress!.clamp(0.0, 1.0) : null,
          height: 6,
          color: t.primary,
          trackColor: t.fill1,
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
    );
    if (insideSheet) {
      return GrassBagSheetSection(
        borderRadius: 16,
        padding: const EdgeInsets.all(12),
        children: [content],
      );
    }
    return GrassBagCard(
      borderRadius: 16,
      padding: const EdgeInsets.all(12),
      child: content,
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

  static final RegExp _inlineRe = RegExp(
    r'(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\))',
  );

  List<InlineSpan> _parseInline(GrassBagTokens t, String text, TextStyle base) {
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final m in _inlineRe.allMatches(text)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, m.start)));
      }
      final tok = m.group(0)!;
      if (tok.startsWith('**') && tok.endsWith('**') && tok.length > 4) {
        spans.add(
          TextSpan(
            text: tok.substring(2, tok.length - 2),
            style: base.copyWith(fontWeight: FontWeight.w700, color: t.text),
          ),
        );
      } else if (tok.startsWith('`') && tok.endsWith('`') && tok.length > 2) {
        spans.add(
          TextSpan(
            text: tok.substring(1, tok.length - 1),
            style: base.copyWith(
              fontFamily: 'monospace',
              fontSize: (base.fontSize ?? 12.5) - 0.8,
              color: t.text,
            ),
          ),
        );
      } else if (tok.startsWith('[')) {
        final closeBracket = tok.indexOf('](');
        final label = closeBracket > 1 ? tok.substring(1, closeBracket) : tok;
        spans.add(
          TextSpan(
            text: label,
            style: base.copyWith(color: t.primary, fontWeight: FontWeight.w500),
          ),
        );
      } else {
        spans.add(TextSpan(text: tok));
      }
      cursor = m.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return spans;
  }

  Widget _renderLine(GrassBagTokens t, String line) {
    if (line.startsWith('# ')) {
      return Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Text(
          line.substring(2).trim(),
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: t.text),
        ),
      );
    }
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
    final clean = (isBullet ? line.substring(2) : line).trim();
    final bodyStyle = TextStyle(fontSize: 12.5, height: 1.45, color: t.text2);
    final rich = Text.rich(
      TextSpan(style: bodyStyle, children: _parseInline(t, clean, bodyStyle)),
    );
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
          Expanded(child: rich),
        ],
      );
    }
    return rich;
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
