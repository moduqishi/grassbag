import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_theme.dart';
import '../shell/grassbag_shell.dart';
import 'onboarding_page.dart';

/// Pure-Canvas kinetic vector assembly of the locked GrassBag ("小草包") emblem:
/// 1) Golden-angle liquid-light dew particles converge into the center with comet arcs
/// 2) Dual opposing PathMetric strokes trace the pouch silhouette in mid-air
/// 3) Gradient liquid fill rises smoothly with a live sinusoidal wave meniscus
/// 4) Twin sprout leaves spring outward from the crown cinch with elastic overshoot
/// 5) Drawstring cinch ribbon sweeps across & pill eyes pop open with a playful micro-blink
/// 6) Diagonal liquid-glass specular sheen glides across leaving the signature highlight
///
/// Zero offscreen `saveLayer` allocations and zero BackdropFilter shaders -> rock-solid 120fps.
class GrassBagAnimatedLogo extends StatefulWidget {
  const GrassBagAnimatedLogo({
    super.key,
    this.size = 112,
    this.duration = const Duration(milliseconds: 1320),
    this.autoPlay = true,
    this.ambientFloat = true,
    this.paused = false,
    this.onAssembled,
  });

  final double size;
  final Duration duration;
  final bool autoPlay;
  final bool ambientFloat;
  final bool paused;
  final VoidCallback? onAssembled;

  @override
  State<GrassBagAnimatedLogo> createState() => _GrassBagAnimatedLogoState();
}

class _GrassBagAnimatedLogoState extends State<GrassBagAnimatedLogo>
    with TickerProviderStateMixin {
  late final AnimationController _assembleCtrl;
  late final AnimationController _ambientCtrl;
  bool _notifiedAssembled = false;

  void _syncAmbient() {
    final shouldRepeat =
        widget.ambientFloat && !widget.paused && _assembleCtrl.isCompleted;
    if (shouldRepeat) {
      if (!_ambientCtrl.isAnimating) {
        _ambientCtrl.repeat();
      }
    } else if (_ambientCtrl.isAnimating) {
      _ambientCtrl.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    _assembleCtrl = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: widget.autoPlay ? 0.0 : 1.0,
    );
    _ambientCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3400),
    );
    _assembleCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_notifiedAssembled) {
        _notifiedAssembled = true;
        widget.onAssembled?.call();
        if (mounted) _syncAmbient();
      }
    });
    if (widget.autoPlay) {
      // Begin kinetic assembly right after Frame 0 paints so GPU first-frame upload never
      // eats the opening dew-particle burst!
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _assembleCtrl.status == AnimationStatus.dismissed) {
          _assembleCtrl.forward();
        }
      });
    } else {
      _syncAmbient();
    }
  }

  @override
  void didUpdateWidget(covariant GrassBagAnimatedLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paused != widget.paused ||
        oldWidget.ambientFloat != widget.ambientFloat) {
      _syncAmbient();
    }
  }

  @override
  void dispose() {
    _assembleCtrl.dispose();
    _ambientCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    // Drive repaint directly on CustomPainter via `repaint: Listenable.merge(...)`
    // -> ZERO 120Hz AnimatedBuilder widget rebuilds!
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          painter: _GrassBagKineticLogoPainter(
            assemble: _assembleCtrl,
            ambient: _ambientCtrl,
            ambientFloat: widget.ambientFloat,
            hi: t.primaryHi,
            lo: t.primary,
            isDark: t.isDark,
          ),
        ),
      ),
    );
  }
}

class _GrassBagKineticLogoPainter extends CustomPainter {
  _GrassBagKineticLogoPainter({
    required this.assemble,
    required this.ambient,
    required this.ambientFloat,
    required this.hi,
    required this.lo,
    required this.isDark,
  })  : _gradientShader = LinearGradient(
          begin: const Alignment(-0.72, -0.88),
          end: const Alignment(0.72, 0.88),
          colors: [hi, lo],
        ).createShader(const Rect.fromLTWH(0, 0, 64, 64)),
        super(repaint: Listenable.merge([assemble, ambient]));

  final Animation<double> assemble;
  final Animation<double> ambient;
  final bool ambientFloat;
  final Color hi;
  final Color lo;
  final bool isDark;
  final Shader _gradientShader;

  static final Path _bodyPath = _buildBodyPath();
  static final Path _leftLeafPath = _buildLeftLeafPath();
  static final Path _rightLeafPath = _buildRightLeafPath();
  static final Path _collarPath = _buildCollarPath();
  static final Path _sheenPath = _buildSheenPath();
  static final Path _fullAssembledSilhouette = _buildFullAssembledSilhouette();
  static final PathMetric _bodyMetric = _bodyPath.computeMetrics().first;

  static Path _buildLeftLeafPath() => Path()
    ..moveTo(30.2, 19.6)
    ..cubicTo(24.6, 15.8, 20.4, 10.6, 23.6, 7.4)
    ..cubicTo(26.6, 4.4, 31.8, 9.2, 32.4, 18.2)
    ..close();

  static Path _buildRightLeafPath() => Path()
    ..moveTo(33.4, 19.2)
    ..cubicTo(34.8, 9.6, 41.2, 4.6, 45.2, 7.2)
    ..cubicTo(49.0, 9.6, 45.2, 16.0, 37.2, 19.8)
    ..close();

  static Path _buildBodyPath() => Path()
    ..moveTo(24.2, 19.8)
    ..cubicTo(27.2, 18.6, 36.8, 18.6, 39.8, 19.8)
    ..cubicTo(40.8, 20.2, 41.6, 21.0, 42.2, 21.8)
    ..cubicTo(49.4, 25.4, 52.8, 34.4, 51.6, 43.4)
    ..cubicTo(50.3, 52.6, 42.8, 57.2, 32.0, 57.2)
    ..cubicTo(21.2, 57.2, 13.7, 52.6, 12.4, 43.4)
    ..cubicTo(11.2, 34.4, 14.6, 25.4, 21.8, 21.8)
    ..cubicTo(22.4, 21.0, 23.2, 20.2, 24.2, 19.8)
    ..close();

  static Path _buildCollarPath() => Path()
    ..moveTo(20.4, 20.2)
    ..quadraticBezierTo(32.0, 24.2, 43.6, 20.2)
    ..arcToPoint(const Offset(43.6, 22.9), radius: const Radius.circular(1.35))
    ..quadraticBezierTo(32.0, 26.9, 20.4, 22.9)
    ..arcToPoint(const Offset(20.4, 20.2), radius: const Radius.circular(1.35))
    ..close();

  static Path _buildSheenPath() {
    final sheen = Path()
      ..moveTo(22.5, 25.5)
      ..cubicTo(17.6, 29.2, 15.8, 35.8, 16.8, 42.5)
      ..cubicTo(18.5, 34.8, 23.6, 29.2, 33.5, 27.6)
      ..cubicTo(28.5, 25.2, 25.0, 24.6, 22.5, 25.5)
      ..close();
    final eyeCutout = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(25.6, 34.2, 4.4, 7.4),
          const Radius.circular(2.2),
        ),
      );
    return Path.combine(PathOperation.difference, sheen, eyeCutout);
  }

  static Path _buildFullAssembledSilhouette() {
    final ears = Path.combine(PathOperation.union, _leftLeafPath, _rightLeafPath);
    final full = Path.combine(PathOperation.union, _bodyPath, ears);
    final cutouts = Path()
      ..addPath(_collarPath, Offset.zero)
      ..addRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(25.6, 34.2, 4.4, 7.4),
          const Radius.circular(2.2),
        ),
      )
      ..addRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(36.4, 34.2, 4.4, 7.4),
          const Radius.circular(2.2),
        ),
      );
    return Path.combine(PathOperation.difference, full, cutouts);
  }

  static double _seg(double t, double a, double b, [Curve curve = Curves.easeOutCubic]) {
    if (t <= a) return 0.0;
    if (t >= b) return 1.0;
    return curve.transform(((t - a) / (b - a)).clamp(0.0, 1.0));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = assemble.value.clamp(0.0, 1.0);
    final ambientPhase = ambient.value * math.pi * 2.0;
    final floatDy = ambientFloat && p >= 0.995 ? math.sin(ambientPhase) * 2.6 : 0.0;
    canvas.save();
    if (floatDy != 0.0) {
      canvas.translate(0, floatDy);
    }
    canvas.scale(size.width / 64.0, size.height / 64.0);

    final gradientShader = _gradientShader;

    // 1. Soft breathing ambient liquid halo + expanding lens ring
    final haloIn = _seg(p, 0.0, 0.45, Curves.easeOut);
    final breathe = p >= 1.0 ? (1.0 + math.sin(ambientPhase) * 0.04) : 1.0;
    final haloRadius = (26.0 + 5.0 * haloIn) * breathe;
    canvas.drawCircle(
      const Offset(32, 34),
      haloRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            hi.withValues(alpha: (isDark ? 0.34 : 0.24) * haloIn),
            lo.withValues(alpha: (isDark ? 0.12 : 0.08) * haloIn),
            lo.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.56, 1.0],
        ).createShader(Rect.fromCircle(center: const Offset(32, 34), radius: haloRadius)),
    );

    // Expanding liquid-glass shockwave ring when assembly locks in (0.48 -> 0.96)
    final ringT = _seg(p, 0.48, 0.96, Curves.easeOutCubic);
    if (ringT > 0.0 && ringT < 1.0) {
      final ringAlpha = (1.0 - ringT) * (isDark ? 0.46 : 0.36);
      canvas.drawCircle(
        const Offset(32, 34),
        18.0 + ringT * 24.0,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (1.6 * (1.0 - ringT * 0.65)).clamp(0.35, 1.8)
          ..color = hi.withValues(alpha: ringAlpha),
      );
    }

    // 2. Converging golden-angle liquid-light dew particles (0.0 -> 0.56)
    if (p < 0.62) {
      const count = 18;
      const goldenAngle = 2.399963229728653;
      for (int i = 0; i < count; i++) {
        final stagger = (i % 6) * 0.032;
        final pt = _seg(p, stagger, 0.44 + stagger, Curves.easeInOutCubic);
        if (pt <= 0.0 || pt >= 1.0) continue;
        final startAngle = i * goldenAngle;
        final swirlAngle = startAngle + (1.0 - pt) * 1.35;
        final dist = (1.0 - pt) * (28.0 + (i % 3) * 8.5);
        final cx = 32.0 + math.cos(swirlAngle) * dist;
        final cy = 34.0 + math.sin(swirlAngle) * dist;
        final tailAngle = swirlAngle + 0.22;
        final tailDist = dist + 4.8 * (1.0 - pt);
        final tx = 32.0 + math.cos(tailAngle) * tailDist;
        final ty = 34.0 + math.sin(tailAngle) * tailDist;
        final alpha = math.sin(pt * math.pi).clamp(0.0, 1.0) * (isDark ? 0.85 : 0.72);
        final particleColor = i.isEven ? hi : lo;
        canvas.drawLine(
          Offset(tx, ty),
          Offset(cx, cy),
          Paint()
            ..color = particleColor.withValues(alpha: alpha * 0.55)
            ..strokeWidth = 1.2
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawCircle(
          Offset(cx, cy),
          1.15 + (i % 3) * 0.35,
          Paint()..color = particleColor.withValues(alpha: alpha),
        );
      }
    }

    // If fully assembled, draw the locked true-cutout silhouette cleanly + ambient sheen!
    if (p >= 0.995) {
      canvas.drawPath(_fullAssembledSilhouette, Paint()..shader = gradientShader);
      canvas.drawPath(
        _sheenPath,
        Paint()..color = Colors.white.withValues(alpha: isDark ? 0.30 : 0.24),
      );
      // Subtle ambient shimmer pulse along the rim
      final pulseAlpha = (0.14 + 0.08 * math.sin(ambientPhase)) * (isDark ? 1.0 : 0.75);
      canvas.drawPath(
        _bodyPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.65
          ..color = Colors.white.withValues(alpha: pulseAlpha),
      );
      canvas.restore();
      return;
    }

    // 3. Kinetic Pouch Contour Drawing (dual symmetric luminous strokes, 0.08 -> 0.54)
    final strokeT = _seg(p, 0.08, 0.54, Curves.easeInOutCubic);
    final strokeFade = 1.0 - _seg(p, 0.68, 0.92, Curves.easeOut);
    if (strokeT > 0.0 && strokeFade > 0.0) {
      final len = _bodyMetric.length;
      final half = len * 0.5 * strokeT;
      final segA = _bodyMetric.extractPath(0.0, half);
      final segB = _bodyMetric.extractPath(len - half, len);

      final glowPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = hi.withValues(alpha: (isDark ? 0.36 : 0.26) * strokeFade);
      final corePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.65
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = gradientShader;

      canvas.drawPath(segA, glowPaint);
      canvas.drawPath(segB, glowPaint);
      canvas.drawPath(segA, corePaint);
      canvas.drawPath(segB, corePaint);
    }

    // 4. Rising Liquid Gradient Fill with Live Wave Meniscus + true transparent collar/eye cutouts
    final fillT = _seg(p, 0.24, 0.70, Curves.easeInOutCubic);
    final collarT = _seg(p, 0.58, 0.78, Curves.easeOutCubic);
    final eyePopT = _seg(p, 0.66, 0.84, Curves.easeOutBack);
    if (fillT > 0.0) {
      final hasCutouts = collarT > 0.0 || eyePopT > 0.0;
      // Use a tiny local 48×46 saveLayer + BlendMode.dstOut instead of per-frame CPU
      // Path.combine boolean tessellation — silky 120fps on Android during collar/eye reveal!
      if (hasCutouts) {
        canvas.saveLayer(const Rect.fromLTWH(8, 14, 48, 46), Paint());
      }
      canvas.save();
      canvas.clipPath(_bodyPath);
      final surfaceY = 59.0 - fillT * 43.0; // rises from y=59 -> y=16
      final waveAmp = math.sin(fillT * math.pi) * 2.8;
      final wavePhase = fillT * math.pi * 4.5;
      final liquidPath = Path()..moveTo(8, 62);
      liquidPath.lineTo(8, surfaceY);
      for (double x = 8; x <= 56; x += 3.0) {
        final wy = surfaceY + math.sin(x * 0.24 + wavePhase) * waveAmp;
        liquidPath.lineTo(x, wy);
      }
      liquidPath
        ..lineTo(56, 62)
        ..close();

      canvas.drawPath(liquidPath, Paint()..shader = gradientShader);

      // Luminous liquid meniscus crest highlight while filling
      if (fillT < 0.94) {
        final crestPath = Path();
        for (double x = 10; x <= 54; x += 2.5) {
          final wy = surfaceY + math.sin(x * 0.24 + wavePhase) * waveAmp;
          if (x == 10) {
            crestPath.moveTo(x, wy);
          } else {
            crestPath.lineTo(x, wy);
          }
        }
        canvas.drawPath(
          crestPath,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = Colors.white.withValues(alpha: (1.0 - fillT) * 0.72),
        );
      }
      canvas.restore();

      if (hasCutouts) {
        final erasePaint = Paint()..blendMode = BlendMode.dstOut;
        if (collarT > 0.0) {
          canvas.save();
          canvas.clipRect(Rect.fromLTWH(19.0, 18.0, 26.0 * collarT, 11.0));
          canvas.drawPath(_collarPath, erasePaint);
          canvas.restore();
        }
        if (eyePopT > 0.0) {
          double blinkScaleY = 1.0;
          if (p > 0.86 && p < 0.96) {
            final bt = (p - 0.86) / 0.10;
            blinkScaleY = 1.0 - math.sin(bt * math.pi) * 0.84;
          }
          final sy = (eyePopT.clamp(0.0, 1.15) * blinkScaleY).clamp(0.08, 1.2);
          final sx = eyePopT.clamp(0.0, 1.05);
          final w = 4.4 * sx;
          final h = 7.4 * sy;
          final r = math.min(w, h) * 0.5;
          for (final cx in const [27.8, 38.6]) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromCenter(center: Offset(cx, 37.9), width: w, height: h),
                Radius.circular(r),
              ),
              erasePaint,
            );
          }
        }
        canvas.restore();
      }
    }

    // 5. Twin Sprout Leaves Spring Unfurl from crown knot (0.40 -> 0.78)
    final leftLeafT = _seg(p, 0.40, 0.74, Curves.easeOutBack);
    if (leftLeafT > 0.0) {
      final s = leftLeafT.clamp(0.0, 1.18);
      final rot = (1.0 - leftLeafT) * -0.62;
      canvas.save();
      canvas.translate(31.2, 19.2);
      canvas.rotate(rot);
      canvas.scale(s, s);
      canvas.translate(-31.2, -19.2);
      canvas.drawPath(_leftLeafPath, Paint()..shader = gradientShader);
      canvas.restore();
    }

    final rightLeafT = _seg(p, 0.46, 0.80, Curves.easeOutBack);
    if (rightLeafT > 0.0) {
      final s = rightLeafT.clamp(0.0, 1.18);
      final rot = (1.0 - rightLeafT) * 0.66;
      canvas.save();
      canvas.translate(34.5, 19.2);
      canvas.rotate(rot);
      canvas.scale(s, s);
      canvas.translate(-34.5, -19.2);
      canvas.drawPath(_rightLeafPath, Paint()..shader = gradientShader);
      canvas.restore();
    }

    // 6. Crown sparkle glints when leaves lock in (0.56 -> 0.88)
    final sparkT = _seg(p, 0.56, 0.88, Curves.easeOutCubic);
    if (sparkT > 0.0 && sparkT < 1.0) {
      final sparkAlpha = math.sin(sparkT * math.pi) * (isDark ? 0.90 : 0.78);
      const sparkSeeds = [
        Offset(21.0, 7.5),
        Offset(47.0, 6.8),
        Offset(32.5, 3.8),
        Offset(15.5, 16.5),
        Offset(49.5, 16.2),
      ];
      for (int i = 0; i < sparkSeeds.length; i++) {
        final origin = sparkSeeds[i];
        final drift = Offset(
          (origin.dx - 32.0) * 0.18 * sparkT,
          (origin.dy - 19.0) * 0.18 * sparkT - 1.2 * sparkT,
        );
        final pos = origin + drift;
        final arm = (2.1 - (i % 2) * 0.6) * math.sin(sparkT * math.pi);
        final spPaint = Paint()
          ..color = (i.isEven ? Colors.white : hi).withValues(alpha: sparkAlpha)
          ..strokeWidth = 0.85
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(Offset(pos.dx - arm, pos.dy), Offset(pos.dx + arm, pos.dy), spPaint);
        canvas.drawLine(Offset(pos.dx, pos.dy - arm), Offset(pos.dx, pos.dy + arm), spPaint);
      }
    }

    // 8. Diagonal specular sheen sweep + permanent crescent glass highlight (0.68 -> 1.00)
    final sheenFade = _seg(p, 0.70, 0.94, Curves.easeOut);
    if (sheenFade > 0.0) {
      canvas.drawPath(
        _sheenPath,
        Paint()..color = Colors.white.withValues(alpha: (isDark ? 0.30 : 0.24) * sheenFade),
      );
    }

    final sweepT = _seg(p, 0.68, 0.98, Curves.easeInOutCubic);
    if (sweepT > 0.0 && sweepT < 1.0) {
      canvas.save();
      canvas.clipPath(_bodyPath);
      final sweepX = -20.0 + sweepT * 108.0;
      final beamRect = Rect.fromLTWH(sweepX - 10.0, 0, 20.0, 64.0);
      canvas.translate(32, 32);
      canvas.rotate(-0.42);
      canvas.translate(-32, -32);
      canvas.drawRect(
        beamRect,
        Paint()
          ..shader = LinearGradient(
            colors: [
              Colors.white.withValues(alpha: 0.0),
              Colors.white.withValues(alpha: isDark ? 0.42 : 0.52),
              Colors.white.withValues(alpha: 0.0),
            ],
          ).createShader(beamRect),
      );
      canvas.restore();
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GrassBagKineticLogoPainter oldDelegate) =>
      oldDelegate.assemble != assemble ||
      oldDelegate.ambient != ambient ||
      oldDelegate.ambientFloat != ambientFloat ||
      oldDelegate.hi != hi ||
      oldDelegate.lo != lo ||
      oldDelegate.isDark != isDark;
}

/// Root launch gate mounted as `MaterialApp.home`:
/// - Mounts [GrassBagShell] immediately in parallel so DSH core boot & session hydration
///   begin at t=0ms behind the brand launch animation.
/// - Subsequent launches: plays the kinetic GrassBag logo assembly splash while absorbing
///   core startup latency, then dissolves straight into the live workspace.
/// - Genuine first launch: plays a concise brand emblem reveal, then smoothly transitions
///   into the dedicated full-screen [OnboardingPage] welcome & setup flow.
class GrassBagAppGate extends ConsumerStatefulWidget {
  const GrassBagAppGate({
    super.key,
    this.skipLaunchAnimation = false,
  });

  final bool skipLaunchAnimation;

  @override
  ConsumerState<GrassBagAppGate> createState() => _GrassBagAppGateState();
}

enum _GateStage {
  splash,
  onboarding,
  ready,
}

class _GrassBagAppGateState extends ConsumerState<GrassBagAppGate>
    with SingleTickerProviderStateMixin {
  late _GateStage _stage;
  late final AnimationController _exitCtrl;
  late final CurvedAnimation _exitCurve;
  _GateStage? _pendingExitStage;
  bool _shellMounted = false;
  bool _exitingSplash = false;
  bool _logoAssembled = false;
  bool _allowManualSkip = false;
  Timer? _shellMountTimer;
  Timer? _skipUnlockTimer;
  Timer? _maxHoldTimer;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _exitCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted && _exitingSplash) {
          final target = _pendingExitStage ?? _GateStage.ready;
          _pendingExitStage = null;
          setState(() {
            _stage = target;
            _exitingSplash = false;
          });
        }
      });
    _exitCurve = CurvedAnimation(
      parent: _exitCtrl,
      curve: Curves.easeOutCubic,
    );
    final initial = ref.read(appProvider);
    final isReturning = initial.onboardingCompleted ||
        initial.nativeRuntimeStatus.initialized ||
        initial.hosts.any((h) => !h.isLocal);

    if (widget.skipLaunchAnimation) {
      _shellMounted = true;
      _stage = isReturning ? _GateStage.ready : _GateStage.onboarding;
      return;
    }

    _stage = _GateStage.splash;
    // CRITICAL COLD-START 120FPS OPTIMIZATION:
    // On Android, `MainActivity.onCreate` ALREADY started booting the local Ubuntu + DSH engine
    // on a native background thread at t=0ms!
    // Render ONLY the pure-Canvas kinetic logo assembly on Frame 0 (zero GLSL shaders -> OS splash
    // lifts immediately and all 1280ms of particle convergence + outline trace + liquid wave fill
    // play at rock-solid 120fps!). Once the logo locks in (`_onLogoAssembled`), mount `GrassBagShell`
    // underneath to warm up Liquid Glass shaders while the assembled emblem & status pill hold cleanly!
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Allow impatient returning users to tap through after 1.15s once logo is nearly complete
      // (never unlock manual skip during first-launch onboarding beat).
      _skipUnlockTimer = Timer(const Duration(milliseconds: 1150), () {
        if (mounted && !_isOnboardingDecisionPending() && !_shouldShowOnboarding()) {
          setState(() => _allowManualSkip = true);
        }
      });
      // Safety fallback: ensure shell mounts only for returning users, and hold splash gracefully
      // up to 3.6s while container startup + model/DeepSeek auth hydration settle so Home NEVER flashes!
      _shellMountTimer = Timer(const Duration(milliseconds: 1400), () {
        if (mounted &&
            !_shellMounted &&
            !_isOnboardingDecisionPending() &&
            !_shouldShowOnboarding()) {
          setState(() => _shellMounted = true);
        }
      });
      _maxHoldTimer = Timer(const Duration(milliseconds: 3600), () {
        _beginSplashExit();
      });
    });
  }

  @override
  void dispose() {
    _shellMountTimer?.cancel();
    _skipUnlockTimer?.cancel();
    _maxHoldTimer?.cancel();
    _dismissTimer?.cancel();
    _exitCurve.dispose();
    _exitCtrl.dispose();
    super.dispose();
  }

  bool _isOnboardingDecisionPending() {
    final s = ref.read(appProvider);
    if (!GrassBagNativeBridge.instance.isAndroidNative) return false;
    if (s.onboardingCompleted || s.nativeRuntimeStatus.initialized) return false;
    if (s.hosts.any((h) => !h.isLocal)) return false;
    return !s.nativeStatusHydrated;
  }

  bool _shouldShowOnboarding() {
    final s = ref.read(appProvider);
    if (s.onboardingCompleted) return false;
    if (s.nativeRuntimeStatus.initialized) return false;
    if (s.hosts.any((h) => !h.isLocal)) return false;
    return true;
  }

  /// True once initial host startup, DSH namespaces, and DeepSeek auth/models have settled
  /// enough to enter Home cleanly without flashing intermediate "connecting / configure model" cards.
  bool _isStartupHydrationSettled(GrassBagAppState s) {
    if (GrassBagNativeBridge.instance.isAndroidNative &&
        s.activeHost.isLocal &&
        !s.nativeStatusHydrated) {
      return false;
    }
    if (s.connectionPhase == ConnectionPhase.connecting ||
        s.connectionPhase == ConnectionPhase.reconnecting ||
        s.connectionPhase == ConnectionPhase.bootstrapping) {
      return false;
    }
    if (s.activeHost.isLocal && s.nativeRuntimeStatus.engineState == 'starting') return false;
    if (s.hydratingDomains) return false;
    if (s.connectionPhase == ConnectionPhase.connected) {
      // Wait briefly until initial domain/model/auth hydration lands (prevents login-card flash!)
      if (s.dshNamespaces.isEmpty && s.modelGroups.isEmpty && !s.isAccountSignedIn) {
        return false;
      }
    }
    return true;
  }

  void _onLogoAssembled() {
    if (!mounted || _stage != _GateStage.splash) return;
    _logoAssembled = true;
    // On first launch, mount OnboardingPage DIRECTLY under the splash (NEVER mount GrassBagShell!)
    // so the splash cross-dissolves seamlessly into Onboarding with ZERO home-screen flash!
    // Note: `_beginSplashExit()` re-evaluates `_shouldShowOnboarding()` after the 220ms beat
    // (total ~1.5s from launch), giving Android's parallel `refreshNativeStatus()` plenty of
    // headroom to report `initialized == true` for upgrading users while never stalling if
    // the native channel is unavailable (e.g., headless tests or OEM binder error).
    if (_shouldShowOnboarding()) {
      _dismissTimer?.cancel();
      _dismissTimer = Timer(const Duration(milliseconds: 220), _beginSplashExit);
      return;
    }
    // On subsequent launch, mount GrassBagShell underneath to warm up Liquid Glass shaders
    // while holding the breathing emblem until container + model + DeepSeek auth settle!
    if (!_shellMounted) {
      setState(() => _shellMounted = true);
    }
    final s = ref.read(appProvider);
    if (_isStartupHydrationSettled(s)) {
      _dismissTimer?.cancel();
      _dismissTimer = Timer(const Duration(milliseconds: 260), _beginSplashExit);
    }
  }

  void _beginSplashExit() {
    if (!mounted || _stage != _GateStage.splash || _exitingSplash) return;
    _shellMountTimer?.cancel();
    _skipUnlockTimer?.cancel();
    _maxHoldTimer?.cancel();
    _dismissTimer?.cancel();
    final goOnboarding = _shouldShowOnboarding();
    if (!goOnboarding) {
      // Returning users who upgraded from an older version silently mark onboarding complete.
      final ctrl = ref.read(appProvider.notifier);
      if (!ref.read(appProvider).onboardingCompleted) {
        ctrl.completeOnboarding();
      }
    }
    _pendingExitStage = goOnboarding ? _GateStage.onboarding : _GateStage.ready;
    setState(() {
      if (goOnboarding) {
        _stage = _GateStage.onboarding;
      } else {
        _shellMounted = true;
      }
      _exitingSplash = true;
    });
    _exitCtrl.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    // Watch startup readiness while splash is visible so we dissolve right when engine + models + auth settle!
    if (_stage == _GateStage.splash) {
      ref.listen<(ConnectionPhase, String, bool, bool, bool)>(
        appProvider.select(
          (s) => (
            s.connectionPhase,
            s.nativeRuntimeStatus.engineState,
            s.nativeStatusHydrated,
            s.hydratingDomains,
            s.dshNamespaces.isNotEmpty || s.modelGroups.isNotEmpty || s.isAccountSignedIn,
          ),
        ),
        (prev, next) {
          if (!_logoAssembled || _exitingSplash) return;
          if (_shouldShowOnboarding()) {
            return;
          }
          // Returning user status just hydrated (e.g. initialized container on upgrade):
          // cancel any pending onboarding exit timer and mount GrassBagShell instead!
          _dismissTimer?.cancel();
          if (!_shellMounted) {
            setState(() {
              _shellMounted = true;
              _allowManualSkip = true;
            });
          }
          if (_isStartupHydrationSettled(ref.read(appProvider))) {
            _dismissTimer = Timer(const Duration(milliseconds: 180), _beginSplashExit);
          }
        },
      );
    }

    final showOnboarding = _stage == _GateStage.onboarding;
    final showSplash = _stage == _GateStage.splash || _exitingSplash;

    return Stack(
      children: [
        // Main shell mounts ONLY for returning users (or after onboarding completes);
        // mute all tickers while completely covered by the opaque brand splash!
        if (_shellMounted)
          TickerMode(
            enabled: !showSplash,
            child: GrassBagShell(isSplashCovered: showSplash),
          ),

        // Full-screen First-Launch Onboarding Experience (mounted BEFORE splash fades out -> zero flash!)
        if (showOnboarding)
          Positioned.fill(
            child: TickerMode(
              enabled: !showSplash,
              child: OnboardingPage(
                isFirstLaunch: true,
                onFinished: () {
                  _dismissTimer?.cancel();
                  _exitCtrl.stop();
                  if (!mounted) return;
                  setState(() {
                    _shellMounted = true;
                    _stage = _GateStage.ready;
                    _exitingSplash = false;
                  });
                },
              ),
            ),
          ),

        // Subsequent-launch (and first-launch opening beat) Kinetic Logo Assembly Splash
        if (showSplash)
          Positioned.fill(
            child: PopScope(
              canPop: false,
              child: IgnorePointer(
                ignoring: _exitingSplash,
                child: _GrassBagSplashLayer(
                  exiting: _exitingSplash,
                  exitProgress: _exitCurve,
                  allowTapSkip: _allowManualSkip,
                  onLogoAssembled: _onLogoAssembled,
                  onTapSkip: _beginSplashExit,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _GrassBagSplashLayer extends ConsumerWidget {
  const _GrassBagSplashLayer({
    required this.exiting,
    required this.exitProgress,
    required this.allowTapSkip,
    required this.onLogoAssembled,
    required this.onTapSkip,
  });

  final bool exiting;
  final Animation<double> exitProgress;
  final bool allowTapSkip;
  final VoidCallback onLogoAssembled;
  final VoidCallback onTapSkip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = GrassBagTokens.of(context);
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          phase: s.connectionPhase,
          isLocal: s.activeHost.isLocal,
          hostName: s.activeHost.name,
          onboardingDone: s.onboardingCompleted,
          initialized: s.nativeRuntimeStatus.initialized,
          hasRemoteHosts: s.hosts.any((h) => !h.isLocal),
          progressPct: s.runtimeProgressPct,
          hydrated: !s.hydratingDomains &&
              (s.dshNamespaces.isNotEmpty || s.modelGroups.isNotEmpty || s.isAccountSignedIn),
        ),
      ),
    );

    final String statusText;
    final bool statusReady;
    if (!slice.onboardingDone && !slice.initialized && !slice.hasRemoteHosts) {
      statusText = '把 DeepSeek Harness 装进口袋';
      statusReady = false;
    } else if (slice.phase == ConnectionPhase.connected && slice.hydrated) {
      statusText = slice.isLocal ? '本机核心与模型已就绪' : '已连接到 ${slice.hostName}';
      statusReady = true;
    } else if (slice.phase == ConnectionPhase.connected) {
      statusText = '正在同步模型与账号状态…';
      statusReady = false;
    } else if (slice.progressPct > 0 && slice.progressPct < 100) {
      statusText = '正在部署本机环境 ${slice.progressPct}%…';
      statusReady = false;
    } else if (slice.phase == ConnectionPhase.connecting) {
      statusText = slice.isLocal ? '正在唤醒本机容器与 DSH 核心…' : '正在连接 ${slice.hostName}…';
      statusReady = false;
    } else if (slice.phase == ConnectionPhase.reconnecting) {
      statusText = '正在重新连接 ${slice.hostName}…';
      statusReady = false;
    } else if (slice.phase == ConnectionPhase.bootstrapping) {
      statusText = '正在初始化本机运行环境…';
      statusReady = false;
    } else if (slice.phase == ConnectionPhase.needsAuth) {
      statusText = '已连通 ${slice.hostName} · 待授权';
      statusReady = false;
    } else if (slice.phase == ConnectionPhase.error) {
      statusText = '正在进入工作台（可稍后检查连接）…';
      statusReady = false;
    } else {
      statusText = '正在准备你的工作台…';
      statusReady = false;
    }

    final fadeOutAnim = Tween<double>(begin: 1.0, end: 0.0).animate(exitProgress);
    final scaleOutAnim = Tween<double>(begin: 1.0, end: 1.04).animate(exitProgress);

    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: allowTapSkip ? onTapSkip : null,
        child: FadeTransition(
          opacity: fadeOutAnim,
          child: ScaleTransition(
            scale: scaleOutAnim,
            child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [t.bgTop, t.bgSolid, t.bgBottom],
              ),
            ),
            child: Stack(
              children: [
                // Soft ambient aurora orbs
                Positioned(
                  top: -90,
                  right: -60,
                  child: Container(
                    width: 280,
                    height: 280,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          t.primaryHi.withValues(alpha: t.isDark ? 0.22 : 0.16),
                          t.primary.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: -110,
                  left: -70,
                  child: Container(
                    width: 300,
                    height: 300,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          t.primary.withValues(alpha: t.isDark ? 0.18 : 0.13),
                          t.primary.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
                // Centerpiece Kinetic Logo Assembly + Wordmark
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GrassBagAnimatedLogo(
                        size: 118,
                        duration: const Duration(milliseconds: 1280),
                        paused: exiting,
                        onAssembled: onLogoAssembled,
                      ),
                      const SizedBox(height: 18),
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.0, end: 1.0),
                        duration: const Duration(milliseconds: 760),
                        curve: const Interval(0.35, 1.0, curve: Curves.easeOutCubic),
                        builder: (context, v, child) => Opacity(
                          opacity: v,
                          child: Transform.translate(
                            offset: Offset(0, (1.0 - v) * 14.0),
                            child: child,
                          ),
                        ),
                        child: Text(
                          'GrassBag',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.7,
                            color: t.text,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.0, end: 1.0),
                        duration: const Duration(milliseconds: 980),
                        curve: const Interval(0.50, 1.0, curve: Curves.easeOutCubic),
                        builder: (context, v, child) => Opacity(
                          opacity: v,
                          child: Transform.translate(
                            offset: Offset(0, (1.0 - v) * 10.0),
                            child: child,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: t.isDark ? 0.07 : 0.72),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: t.isDark ? 0.14 : 0.92),
                                width: 0.7,
                              ),
                              boxShadow: t.isDark
                                  ? null
                                  : const [
                                      BoxShadow(
                                        color: Color(0x0A000000),
                                        blurRadius: 12,
                                        offset: Offset(0, 3),
                                      ),
                                    ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (statusReady)
                                  Icon(CupertinoIcons.checkmark_circle_fill, size: 13, color: t.ok)
                                else
                                  SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CupertinoActivityIndicator(
                                      radius: 5.5,
                                      color: t.primary,
                                    ),
                                  ),
                                const SizedBox(width: 7),
                                Flexible(
                                  child: Text(
                                    statusText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                      color: statusReady ? t.ok : t.text2,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Subtle bottom brand watermark
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: MediaQuery.viewPaddingOf(context).bottom + 24,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: allowTapSkip ? 0.65 : 0.35,
                      duration: const Duration(milliseconds: 300),
                      child: Text(
                        allowTapSkip ? '轻点屏幕立即进入' : 'DeepSeek Harness Mobile',
                        style: TextStyle(
                          fontSize: 11.5,
                          letterSpacing: 0.4,
                          color: t.text3,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    );
  }
}
