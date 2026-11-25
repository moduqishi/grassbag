import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import 'qr_temp_file_stub.dart' if (dart.library.io) 'qr_temp_file_io.dart';

/// Full-screen Liquid Glass QR code scanner for instant 1-scan GrassBag pairing with
/// `dsh-gbridge` Desktop/Web QR codes (`grassbag://pair?...` or `http://<ip>:<port>/?token=...`).
class QrPairScannerPage extends ConsumerStatefulWidget {
  const QrPairScannerPage({super.key});

  @override
  ConsumerState<QrPairScannerPage> createState() => _QrPairScannerPageState();
}

class _QrPairScannerPageState extends ConsumerState<QrPairScannerPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final MobileScannerController _scannerCtrl;
  late final AnimationController _beamCtrl;
  bool _handled = false;
  bool _analyzingImage = false;
  bool _readingClipboard = false;
  bool _lifecycleResumed = true;
  bool _cameraHasError = false;
  GrassBagAccent? _cachedAccent;
  GrassBagTokens? _cachedDarkTokens;
  ThemeData? _cachedDarkTheme;
  String? _hintMessage;
  Timer? _hintTimer;

  void _syncBeamTicker() {
    final shouldRun = _lifecycleResumed &&
        !_handled &&
        !_analyzingImage &&
        !_cameraHasError;
    if (shouldRun) {
      if (!_beamCtrl.isAnimating) {
        _beamCtrl.repeat(reverse: true);
      }
    } else if (_beamCtrl.isAnimating) {
      _beamCtrl.stop();
    }
  }

  void _onScannerStateChanged() {
    final err = _scannerCtrl.value.error != null;
    if (err != _cameraHasError) {
      _cameraHasError = err;
      _syncBeamTicker();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scannerCtrl = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
      facing: CameraFacing.back,
    )..addListener(_onScannerStateChanged);
    _beamCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleResumed = state == AppLifecycleState.resumed;
    _syncBeamTicker();
    if (!mounted || _handled) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_scannerCtrl.stop().catchError((_) {}));
    } else if (state == AppLifecycleState.resumed && !_analyzingImage) {
      unawaited(_scannerCtrl.start().catchError((_) {}));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hintTimer?.cancel();
    _scannerCtrl.removeListener(_onScannerStateChanged);
    _beamCtrl.dispose();
    unawaited(_scannerCtrl.dispose());
    super.dispose();
  }

  void _showInlineHint(String msg) {
    _hintTimer?.cancel();
    if (!mounted) return;
    setState(() => _hintMessage = msg);
    _hintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _hintMessage = null);
    });
  }

  void _handleDecodedBarcodes(List<Barcode> barcodes) {
    if (_handled || !mounted) return;
    for (final code in barcodes) {
      final raw = code.rawValue?.trim() ?? '';
      if (raw.isEmpty) continue;
      final parsed = parseRemoteHostInput(raw);
      if (parsed != null) {
        _handled = true;
        _syncBeamTicker();
        HapticFeedback.mediumImpact();
        Navigator.of(context).pop<String>(raw);
        return;
      }
      _showInlineHint('未识别到 GrassBag 配对链接，请对准电脑端「手机连接」二维码');
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await _scannerCtrl.toggleTorch();
    } catch (_) {
      _showInlineHint('当前设备不支持切换闪光灯');
    }
  }

  Future<void> _scanFromGallery() async {
    if (_analyzingImage || _handled) return;
    setState(() => _analyzingImage = true);
    _syncBeamTicker();
    String? tempPath;
    try {
      final picked = await GrassBagNativeBridge.instance.pickAttachment(mime: 'image/*');
      if (!mounted) return;
      if (picked == null) {
        return;
      }
      if (picked.error != null && picked.error!.trim().isNotEmpty) {
        _showInlineHint(picked.error!.trim());
        return;
      }
      if (picked.bytes.isEmpty) {
        _showInlineHint('所选图片为空或无法读取');
        return;
      }
      tempPath = await writeTempQrImageFile(picked.bytes, picked.name);
      if (tempPath == null) {
        _showInlineHint('无法读取所选图片');
        return;
      }
      final capture = await _scannerCtrl.analyzeImage(tempPath);
      if (!mounted) return;
      if (capture == null || capture.barcodes.isEmpty) {
        _showInlineHint('所选图片中未检测到有效二维码');
        return;
      }
      _handleDecodedBarcodes(capture.barcodes);
    } catch (_) {
      _showInlineHint('识别相册图片失败，请尝试直接扫码或粘贴链接');
    } finally {
      unawaited(deleteTempQrImageFile(tempPath));
      if (mounted) {
        setState(() => _analyzingImage = false);
        _syncBeamTicker();
        if (!_handled && _lifecycleResumed) {
          unawaited(_scannerCtrl.start().catchError((_) {}));
        }
      }
    }
  }

  Future<void> _useClipboardFallback() async {
    if (_handled || _readingClipboard) return;
    _readingClipboard = true;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || _handled) return;
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        _showInlineHint('剪贴板为空，请先在电脑端复制配对链接');
        return;
      }
      if (parseRemoteHostInput(text) == null) {
        _showInlineHint('剪贴板内容不是有效的配对链接');
        return;
      }
      _handled = true;
      HapticFeedback.selectionClick();
      Navigator.of(context).pop<String>(text);
    } finally {
      _readingClipboard = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final slice = ref.watch(
      appProvider.select((s) => (tier: s.glassTier, accent: s.accent)),
    );
    final tier = slice.tier;
    if (_cachedAccent != slice.accent || _cachedDarkTheme == null) {
      _cachedAccent = slice.accent;
      _cachedDarkTokens = GrassBagTokens.resolve(slice.accent, Brightness.dark);
      _cachedDarkTheme = _cachedDarkTokens!.toMaterialTheme();
    }
    final darkTokens = _cachedDarkTokens!;
    final darkTheme = _cachedDarkTheme!;
    final screenSize = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final availH = (screenSize.height - pad.vertical - 260.0).clamp(160.0, 290.0);
    final boxEdge = math.min(screenSize.width * 0.68, availH).clamp(160.0, 290.0);
    final supportsGallery = !kIsWeb && GrassBagNativeBridge.instance.isAndroidNative;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Theme(
        data: darkTheme,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: ValueListenableBuilder<MobileScannerState>(
            valueListenable: _scannerCtrl,
            builder: (context, scannerState, _) {
              final hasCameraError = scannerState.error != null;
              final torchOn = scannerState.torchState == TorchState.on;
              final torchAvailable = scannerState.torchState != TorchState.unavailable;
              return Stack(
                fit: StackFit.expand,
                children: [
                  // Live camera feed
                  MobileScanner(
                    controller: _scannerCtrl,
                    onDetect: (capture) => _handleDecodedBarcodes(capture.barcodes),
                    errorBuilder: (ctx, err) {
                      final isDenied = err.errorCode == MobileScannerErrorCode.permissionDenied;
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                CupertinoIcons.camera_fill,
                                size: 42,
                                color: Colors.white.withValues(alpha: 0.72),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                isDenied ? '未获得相机权限' : '无法启动相机预览',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                isDenied
                                    ? (supportsGallery
                                        ? '请授予 GrassBag 相机权限，或使用下方「相册选图」「粘贴配对链接」完成连接。'
                                        : '请在系统设置中授予 GrassBag 相机权限，或点击下方「粘贴配对链接」完成连接。')
                                    : (supportsGallery
                                        ? '当前设备相机暂不可用，可通过相册选图或粘贴配对链接完成连接。'
                                        : '当前设备相机暂不可用，可点击下方「粘贴配对链接」完成连接。'),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.45,
                                  color: Colors.white.withValues(alpha: 0.76),
                                ),
                              ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                alignment: WrapAlignment.center,
                                children: [
                                  if (isDenied && supportsGallery)
                                    SizedBox(
                                      width: 158,
                                      child: GrassBagPrimaryGlassButton(
                                        label: '去开启相机权限',
                                        icon: CupertinoIcons.settings,
                                        height: 38,
                                        tier: tier,
                                        insideGlass: true,
                                        onTap: () => GrassBagNativeBridge.instance
                                            .openPermissionSettings('app_details'),
                                      ),
                                    ),
                                  SizedBox(
                                    width: 144,
                                    child: GrassBagSecondaryGlassButton(
                                      label: '重试启动相机',
                                      icon: CupertinoIcons.refresh,
                                      height: 38,
                                      tier: tier,
                                      insideGlass: true,
                                      onTap: () => unawaited(
                                        _scannerCtrl.start().catchError((_) {}),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                  // Translucent framing overlay + rounded glass viewfinder cutout (isolated RepaintBoundary)
                  if (!hasCameraError)
                    RepaintBoundary(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _ScannerCutoutPainter(
                            boxEdge: boxEdge,
                            accent: darkTokens.primary,
                          ),
                        ),
                      ),
                    ),

                  // Animated luminous scan beam inside the viewfinder square:
                  // Static beam Container hoisted into `AnimatedBuilder.child` inside its own
                  // `RepaintBoundary` and moved purely via GPU Transform.translate (ZERO per-frame
                  // BoxShadow/Gradient allocations or Align layout passes at 120Hz!).
                  if (!hasCameraError)
                    Center(
                      child: RepaintBoundary(
                        child: SizedBox(
                          width: boxEdge - 24,
                          height: boxEdge - 24,
                          child: AnimatedBuilder(
                            animation: _beamCtrl,
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: Container(
                                height: 2.5,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(999),
                                  gradient: LinearGradient(
                                    colors: [
                                      darkTokens.primary.withValues(alpha: 0.0),
                                      darkTokens.primary.withValues(alpha: 0.92),
                                      Colors.white.withValues(alpha: 0.95),
                                      darkTokens.primary.withValues(alpha: 0.92),
                                      darkTokens.primary.withValues(alpha: 0.0),
                                    ],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: darkTokens.primary.withValues(alpha: 0.55),
                                      blurRadius: 12,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            builder: (_, beamChild) {
                              final travel = math.max(0.0, (boxEdge - 24.0) * 0.88 - 2.5);
                              final topMargin = (boxEdge - 24.0) * 0.06;
                              return Transform.translate(
                                offset: Offset(0, topMargin + _beamCtrl.value * travel),
                                child: beamChild,
                              );
                            },
                          ),
                        ),
                      ),
                    ),

                  // Top floating Liquid Glass bar
                  Positioned(
                    top: pad.top + 12,
                    left: 16,
                    right: 16,
                    child: Row(
                      children: [
                        GrassBagGlassCircleButton(
                          icon: CupertinoIcons.chevron_left,
                          tooltip: '返回',
                          tier: tier,
                          size: 42,
                          iconSize: 19,
                          iconColor: Colors.white,
                          platformViewBackdrop: true,
                          onTap: () => Navigator.of(context).pop(),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.42),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.16),
                              width: 0.7,
                            ),
                          ),
                          child: const Text(
                            '扫码连接电脑',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const Spacer(),
                        IgnorePointer(
                          ignoring: !(torchAvailable && !hasCameraError),
                          child: Opacity(
                            opacity: torchAvailable && !hasCameraError ? 1.0 : 0.42,
                            child: GrassBagGlassCircleButton(
                              icon: torchOn ? CupertinoIcons.bolt_fill : CupertinoIcons.bolt,
                              tooltip: torchOn ? '关闭闪光灯' : '开启闪光灯',
                              tier: tier,
                              size: 42,
                              iconSize: 18,
                              iconColor: torchOn ? const Color(0xFFFBBF24) : Colors.white,
                              platformViewBackdrop: true,
                              onTap: _toggleTorch,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Bottom stack: inline feedback pill + floating Liquid Glass actions card
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: pad.bottom + 18,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_hintMessage != null) ...[
                          Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.76),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.18),
                                  width: 0.7,
                                ),
                              ),
                              child: Text(
                                _hintMessage!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  color: Colors.white,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
                        GrassBagGlass(
                          tier: tier,
                          borderRadius: 24,
                          padding: const EdgeInsets.all(14),
                          tintColor: Colors.black.withValues(alpha: 0.48),
                          platformViewBackdrop: true,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '对准电脑端 DeepSeek Harness 左侧「手机连接」二维码，自动识别地址与令牌',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.45,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white.withValues(alpha: 0.90),
                                ),
                              ),
                              const SizedBox(height: 11),
                              Row(
                                children: [
                                  if (supportsGallery) ...[
                                    Expanded(
                                      child: GrassBagSecondaryGlassButton(
                                        label: _analyzingImage ? '识别中…' : '相册选图',
                                        icon: CupertinoIcons.photo,
                                        height: 40,
                                        tier: tier,
                                        insideGlass: true,
                                        onTap: _analyzingImage ? null : _scanFromGallery,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                  ],
                                  Expanded(
                                    child: GrassBagPrimaryGlassButton(
                                      label: '粘贴配对链接',
                                      icon: CupertinoIcons.doc_on_clipboard,
                                      height: 40,
                                      tier: tier,
                                      insideGlass: true,
                                      onTap: _useClipboardFallback,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ScannerCutoutPainter extends CustomPainter {
  const _ScannerCutoutPainter({
    required this.boxEdge,
    required this.accent,
  });

  final double boxEdge;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: boxEdge,
      height: boxEdge,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(26));
    final scrimPath = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      scrimPath,
      Paint()..color = Colors.black.withValues(alpha: 0.56),
    );

    // Subtle glass rim
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.34),
    );

    // Crisp luminous corner brackets
    const cornerLen = 26.0;
    const cornerR = 22.0;
    final bracketPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round
      ..color = accent;

    void drawCorner(Offset origin, double dx, double dy) {
      final path = Path()
        ..moveTo(origin.dx, origin.dy + dy * cornerLen)
        ..lineTo(origin.dx, origin.dy + dy * cornerR)
        ..quadraticBezierTo(origin.dx, origin.dy, origin.dx + dx * cornerR, origin.dy)
        ..lineTo(origin.dx + dx * cornerLen, origin.dy);
      canvas.drawPath(path, bracketPaint);
    }

    drawCorner(rect.topLeft, 1, 1);
    drawCorner(rect.topRight, -1, 1);
    drawCorner(rect.bottomLeft, 1, -1);
    drawCorner(rect.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(covariant _ScannerCutoutPainter oldDelegate) =>
      oldDelegate.boxEdge != boxEdge || oldDelegate.accent != accent;
}
