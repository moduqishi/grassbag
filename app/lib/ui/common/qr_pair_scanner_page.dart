import 'dart:async';

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
    with SingleTickerProviderStateMixin {
  late final MobileScannerController _scannerCtrl;
  late final AnimationController _beamCtrl;
  bool _torchOn = false;
  bool _handled = false;
  bool _analyzingImage = false;
  String? _hintMessage;
  Timer? _hintTimer;

  @override
  void initState() {
    super.initState();
    _scannerCtrl = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
      facing: CameraFacing.back,
    );
    _beamCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
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
      if (mounted) setState(() => _torchOn = !_torchOn);
    } catch (_) {
      _showInlineHint('当前设备不支持切换闪光灯');
    }
  }

  Future<void> _scanFromGallery() async {
    if (_analyzingImage || _handled) return;
    setState(() => _analyzingImage = true);
    String? tempPath;
    try {
      final picked = await GrassBagNativeBridge.instance.pickAttachment(mime: 'image/*');
      if (!mounted) return;
      if (picked == null || picked.bytes.isEmpty) {
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
      if (mounted) setState(() => _analyzingImage = false);
    }
  }

  Future<void> _useClipboardFallback() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
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
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final mq = MediaQuery.of(context);
    final boxEdge = (mq.size.width * 0.68).clamp(220.0, 290.0);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Live camera feed
          MobileScanner(
            controller: _scannerCtrl,
            onDetect: (capture) => _handleDecodedBarcodes(capture.barcodes),
            errorBuilder: (ctx, err) => Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.camera_fill, size: 42, color: Colors.white.withValues(alpha: 0.72)),
                    const SizedBox(height: 12),
                    const Text(
                      '无法启动相机预览',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      err.errorCode == MobileScannerErrorCode.permissionDenied
                          ? '请授予 GrassBag 相机权限，或直接点击下方「相册选图」识别二维码。'
                          : '当前设备相机暂不可用，可通过相册图片或粘贴配对链接完成连接。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5, height: 1.45, color: Colors.white.withValues(alpha: 0.72)),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Translucent framing overlay + rounded glass viewfinder cutout
          IgnorePointer(
            child: CustomPaint(
              painter: _ScannerCutoutPainter(
                boxEdge: boxEdge,
                accent: t.primary,
              ),
            ),
          ),

          // Animated luminous scan beam inside the viewfinder square
          Center(
            child: SizedBox(
              width: boxEdge - 24,
              height: boxEdge - 24,
              child: AnimatedBuilder(
                animation: _beamCtrl,
                builder: (_, __) {
                  return Align(
                    alignment: Alignment(0, -0.88 + _beamCtrl.value * 1.76),
                    child: Container(
                      height: 2.5,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        gradient: LinearGradient(
                          colors: [
                            t.primary.withValues(alpha: 0.0),
                            t.primary.withValues(alpha: 0.92),
                            Colors.white.withValues(alpha: 0.95),
                            t.primary.withValues(alpha: 0.92),
                            t.primary.withValues(alpha: 0.0),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: t.primary.withValues(alpha: 0.55),
                            blurRadius: 12,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // Top floating Liquid Glass bar
          Positioned(
            top: mq.padding.top + 12,
            left: 16,
            right: 16,
            child: Row(
              children: [
                GrassBagGlassCircleButton(
                  icon: CupertinoIcons.chevron_left,
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
                    border: Border.all(color: Colors.white.withValues(alpha: 0.16), width: 0.7),
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
                GrassBagGlassCircleButton(
                  icon: _torchOn ? CupertinoIcons.bolt_fill : CupertinoIcons.bolt,
                  tier: tier,
                  size: 42,
                  iconSize: 18,
                  iconColor: _torchOn ? const Color(0xFFFBBF24) : Colors.white,
                  platformViewBackdrop: true,
                  onTap: _toggleTorch,
                ),
              ],
            ),
          ),

          // Live inline feedback pill above bottom card
          if (_hintMessage != null)
            Positioned(
              left: 24,
              right: 24,
              bottom: mq.padding.bottom + 146,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 0.7),
                  ),
                  child: Text(
                    _hintMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12.5, color: Colors.white, height: 1.35),
                  ),
                ),
              ),
            ),

          // Bottom floating Liquid Glass actions card (always dark-surface contrast over live camera)
          Positioned(
            left: 16,
            right: 16,
            bottom: mq.padding.bottom + 18,
            child: GrassBagGlass(
              tier: tier,
              borderRadius: 24,
              padding: const EdgeInsets.all(14),
              tintColor: Colors.black.withValues(alpha: 0.44),
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
                      if (!kIsWeb && GrassBagNativeBridge.instance.isAndroidNative) ...[
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
          ),
        ],
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
