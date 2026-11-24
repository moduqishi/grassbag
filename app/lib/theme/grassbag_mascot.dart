import 'package:flutter/material.dart';

import 'grassbag_theme.dart';

/// Pure vector Canvas implementation of the locked GrassBag ("小草包") cute silhouette
/// mascot with true negative-space transparency for the collar cinch and pill eyes.
class GrassBagMascot extends StatelessWidget {
  const GrassBagMascot({
    super.key,
    this.size = 28,
    this.withShadow = false,
  });

  final double size;
  final bool withShadow;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final painter = _GrassBagMascotPainter(
      hi: t.primaryHi,
      lo: t.primary,
      isDark: t.isDark,
    );
    Widget widget = RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: painter),
      ),
    );
    if (withShadow) {
      widget = DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: t.primary.withValues(alpha: t.isDark ? 0.24 : 0.16),
              blurRadius: 16,
              offset: const Offset(0, 6),
              spreadRadius: -4,
            ),
          ],
        ),
        child: widget,
      );
    }
    return widget;
  }
}

class _GrassBagMascotPainter extends CustomPainter {
  const _GrassBagMascotPainter({
    required this.hi,
    required this.lo,
    required this.isDark,
  });

  final Color hi;
  final Color lo;
  final bool isDark;

  /// Precomputed once in 64×64 vector coordinates using Path boolean difference
  /// so drawing GrassBagMascot NEVER allocates a GPU offscreen `canvas.saveLayer`!
  static final Path _silhouettePath = _buildSilhouettePath();
  static final Path _sheenPath = _buildSheenPath();

  static Path _buildSilhouettePath() {
    final leftEar = Path()
      ..moveTo(30.2, 19.6)
      ..cubicTo(24.6, 15.8, 20.4, 10.6, 23.6, 7.4)
      ..cubicTo(26.6, 4.4, 31.8, 9.2, 32.4, 18.2)
      ..close();

    final rightEar = Path()
      ..moveTo(33.4, 19.2)
      ..cubicTo(34.8, 9.6, 41.2, 4.6, 45.2, 7.2)
      ..cubicTo(49.0, 9.6, 45.2, 16.0, 37.2, 19.8)
      ..close();

    final body = Path()
      ..moveTo(24.2, 19.8)
      ..cubicTo(27.2, 18.6, 36.8, 18.6, 39.8, 19.8)
      ..cubicTo(40.8, 20.2, 41.6, 21.0, 42.2, 21.8)
      ..cubicTo(49.4, 25.4, 52.8, 34.4, 51.6, 43.4)
      ..cubicTo(50.3, 52.6, 42.8, 57.2, 32.0, 57.2)
      ..cubicTo(21.2, 57.2, 13.7, 52.6, 12.4, 43.4)
      ..cubicTo(11.2, 34.4, 14.6, 25.4, 21.8, 21.8)
      ..cubicTo(22.4, 21.0, 23.2, 20.2, 24.2, 19.8)
      ..close();

    final ears = Path.combine(PathOperation.union, leftEar, rightEar);
    final fullBody = Path.combine(PathOperation.union, body, ears);

    // Negative-space cutouts: curved collar cinch ribbon + two pill eyes
    final cutouts = Path()
      ..moveTo(20.4, 20.2)
      ..quadraticBezierTo(32.0, 24.2, 43.6, 20.2)
      ..arcToPoint(const Offset(43.6, 22.9), radius: const Radius.circular(1.35))
      ..quadraticBezierTo(32.0, 26.9, 20.4, 22.9)
      ..arcToPoint(const Offset(20.4, 20.2), radius: const Radius.circular(1.35))
      ..close()
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

    return Path.combine(PathOperation.difference, fullBody, cutouts);
  }

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

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 64.0, size.height / 64.0);

    final bodyPaint = Paint()
      ..shader = LinearGradient(
        begin: const Alignment(-0.72, -0.88),
        end: const Alignment(0.72, 0.88),
        colors: [hi, lo],
      ).createShader(const Rect.fromLTWH(0, 0, 64, 64));

    canvas.drawPath(_silhouettePath, bodyPaint);
    canvas.drawPath(
      _sheenPath,
      Paint()..color = Colors.white.withValues(alpha: isDark ? 0.28 : 0.22),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GrassBagMascotPainter oldDelegate) =>
      oldDelegate.hi != hi || oldDelegate.lo != lo || oldDelegate.isDark != isDark;
}
