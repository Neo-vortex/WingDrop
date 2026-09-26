import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../l10n/strings.dart';

/// A soft, slowly flowing area chart of transfer speed.
///
/// * One sample a second; between samples the curve glides left continuously
///   (driven by a ticker, so it moves at the display's full refresh rate).
/// * Catmull-Rom smoothing, a gradient wash under the line, no axes or grid.
/// * The vertical scale eases toward its new range instead of jumping.
/// * A quiet dot breathes at the newest point; the peak is marked faintly.
class SpeedGraph extends StatefulWidget {
  const SpeedGraph({super.key, required this.samples, this.height = 120, this.capacity = 90});

  final List<double> samples;
  final double height;
  final int capacity;

  @override
  State<SpeedGraph> createState() => _SpeedGraphState();
}

class _SpeedGraphState extends State<SpeedGraph> with TickerProviderStateMixin {
  // 0..1 progress between the previous sample and the next one.
  late final AnimationController _flow =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
  late final AnimationController _breath =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat(reverse: true);
  // Visible speed range [low, high], eased between updates.
  double _low = 0, _high = 1, _fromLow = 0, _fromHigh = 1;
  late final AnimationController _scaleAnim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didUpdateWidget(SpeedGraph old) {
    super.didUpdateWidget(old);
    if (widget.samples.length != old.samples.length || (widget.samples.isNotEmpty && widget.samples.last != _last(old))) {
      _flow.forward(from: 0);
      final (lo, hi) = _range(widget.samples);
      if ((lo - _low).abs() > 0.01 || (hi - _high).abs() > 0.01) {
        final (cl, ch) = _current;
        _fromLow = cl;
        _fromHigh = ch;
        _low = lo;
        _high = hi;
        _scaleAnim.forward(from: 0);
      }
    }
  }

  double? _last(SpeedGraph w) => w.samples.isEmpty ? null : w.samples.last;

  (double, double) get _current {
    final t = Curves.easeInOutCubic.transform(_scaleAnim.value);
    return (_fromLow + (_low - _fromLow) * t, _fromHigh + (_high - _fromHigh) * t);
  }

  /// Fit the chart to the speeds actually seen, so real ups and downs are
  /// visible. The span never drops below 40% of the peak: a steady transfer
  /// reads as calm, not as dramatic noise.
  static (double, double) _range(List<double> v) {
    if (v.isEmpty) return (0, 1);
    final mn = v.reduce(math.min), mx = v.reduce(math.max);
    final span = math.max(mx - mn, mx * 0.4).clamp(0.5, double.infinity);
    final mid = (mx + mn) / 2;
    final lo = math.max(0.0, mid - span * 0.65);
    return (lo, lo + span * 1.3);
  }

  @override
  void dispose() {
    _flow.dispose();
    _breath.dispose();
    _scaleAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final peak = widget.samples.fold<double>(0, math.max);
    return SizedBox(
      height: widget.height,
      child: Stack(children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: Listenable.merge([_flow, _breath, _scaleAnim]),
              builder: (context, _) => CustomPaint(
                painter: _GraphPainter(
                  samples: widget.samples,
                  capacity: widget.capacity,
                  flow: Curves.linear.transform(_flow.value),
                  breath: Curves.easeInOutSine.transform(_breath.value),
                  minY: _current.$1,
                  maxY: _current.$2,
                  line: cs.primary,
                  wash: cs.primary,
                  peakColor: cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        if (peak > 0)
          PositionedDirectional(
            top: 0,
            end: 4,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 700),
              child: Text(
                s.peak(fmtMBps(s, _roundPeak(peak)).replaceFirst('≈ ', '')),
                key: ValueKey(_roundPeak(peak)),
                style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
              ),
            ),
          ),
      ]),
    );
  }

  // The peak label only changes on meaningful steps.
  static double _roundPeak(double v) {
    if (v <= 0) return 0;
    final digits = (math.log(v) / math.ln10).floor();
    final f = math.pow(10, digits - 1).toDouble();
    return (v / f).round() * f;
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.samples,
    required this.capacity,
    required this.flow,
    required this.breath,
    required this.minY,
    required this.maxY,
    required this.line,
    required this.wash,
    required this.peakColor,
  });

  final List<double> samples;
  final int capacity;
  final double flow, breath, minY, maxY;
  final Color line, wash, peakColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) {
      // A calm baseline while we wait for data.
      final p = Paint()
        ..color = line.withValues(alpha: 0.18)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(0, size.height - 2), Offset(size.width, size.height - 2), p);
      return;
    }
    final top = 18.0;
    final h = size.height - top - 4;
    final step = size.width / (capacity - 1);
    // Newest sample sits at the right edge; everything glides left by `flow`.
    final shift = (1 - flow) * step;
    final pts = <Offset>[];
    for (var i = 0; i < samples.length; i++) {
      final x = size.width - 6 - (samples.length - 1 - i) * step + shift;
      final y = top + h - ((samples[i] - minY) / (maxY - minY)).clamp(0.0, 1.0) * h;
      pts.add(Offset(x, y));
    }

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 0; i < pts.length - 1; i++) {
      final p0 = i > 0 ? pts[i - 1] : pts[i];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = i + 2 < pts.length ? pts[i + 2] : p2;
      // Catmull-Rom to cubic Bézier, tension 0.5: smooth, no overshoot spikes.
      final c1 = p1 + (p2 - p0) / 6;
      final c2 = p2 - (p3 - p1) / 6;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final fill = Path.from(path)
      ..lineTo(pts.last.dx, size.height)
      ..lineTo(pts.first.dx, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [wash.withValues(alpha: 0.28), wash.withValues(alpha: 0.02)],
        ).createShader(Offset.zero & size),
    );
    // Fade the oldest part of the line out at the left edge.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = LinearGradient(colors: [line.withValues(alpha: 0), line, line], stops: const [0, 0.25, 1])
            .createShader(Offset.zero & size),
    );

    // Faint peak marker.
    var peakI = 0;
    for (var i = 1; i < samples.length; i++) {
      if (samples[i] > samples[peakI]) peakI = i;
    }
    final pk = pts[peakI];
    final dash = Paint()
      ..color = peakColor.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, pk.dy), Offset(x + 3, pk.dy), dash);
    }
    canvas.restore();

    // The newest point breathes softly.
    final last = pts.last;
    canvas.drawCircle(last, 7 + 3 * breath, Paint()..color = line.withValues(alpha: 0.12 + 0.08 * (1 - breath)));
    canvas.drawCircle(last, 4, Paint()..color = line);
  }

  @override
  bool shouldRepaint(_GraphPainter old) => true;
}
