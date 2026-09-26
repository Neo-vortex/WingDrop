import 'dart:math' as math;

import 'package:flutter/material.dart';

const kGentle = Duration(milliseconds: 900);
const kSoft = Duration(milliseconds: 450);
const kEase = Curves.easeOutCubic;

/// A progress bar that glides to each new value instead of jumping.
class GlideBar extends StatelessWidget {
  const GlideBar({super.key, required this.value, this.height = 8});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.clamp(0.0, 1.0)),
      duration: kGentle,
      curve: kEase,
      builder: (context, v, _) => LinearProgressIndicator(
        value: v,
        minHeight: height,
        borderRadius: BorderRadius.circular(height),
      ),
    );
  }
}

/// Large soft ring with a gliding sweep, used for overall progress.
class GlideRing extends StatelessWidget {
  const GlideRing({super.key, required this.value, required this.child, this.size = 200});

  final double value;
  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 1200),
      curve: kEase,
      builder: (context, v, _) => SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _RingPainter(v, cs.primary, cs.surfaceContainerHighest),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color, this.track);

  final double value;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 10.0;
    final rect = Offset.zero & size;
    final r = rect.deflate(stroke / 2);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, 0, math.pi * 2, false, p..color = track);
    if (value > 0) canvas.drawArc(r, -math.pi / 2, math.pi * 2 * value, false, p..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value || old.color != color;
}

/// Slow breathing pulse: a calm stand-in for spinners while waiting.
class Breathing extends StatefulWidget {
  const Breathing({super.key, required this.child, this.period = const Duration(milliseconds: 3600)});

  final Widget child;
  final Duration period;

  @override
  State<Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<Breathing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.period)..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = CurvedAnimation(parent: _c, curve: Curves.easeInOutSine);
    return AnimatedBuilder(
      animation: a,
      builder: (context, child) => Opacity(
        opacity: 0.55 + 0.45 * a.value,
        child: Transform.scale(scale: 0.96 + 0.04 * a.value, child: child),
      ),
      child: widget.child,
    );
  }
}

/// Cross-fades text changes so updates feel like breathing, not flicker.
class SoftText extends StatelessWidget {
  const SoftText(this.text, {super.key, this.style, this.textAlign});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 700),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, a) => FadeTransition(opacity: a, child: child),
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.center, children: [...previous, ?current]),
      child: Text(text, key: ValueKey(text), style: style, textAlign: textAlign),
    );
  }
}

/// AnimatedSwitcher layout that keeps every child at the full available
/// width, top-centered. Inside a scroll view the width constraint is loose,
/// so a child with only short text (e.g. a centered Column) would otherwise
/// shrink to its content and sit in the top-left corner.
Widget fullWidthLayout(Widget? current, List<Widget> previous) => Stack(
      alignment: Alignment.topCenter,
      children: [
        for (final c in [...previous, ?current]) SizedBox(key: ValueKey(c.key), width: double.infinity, child: c),
      ],
    );

/// The WingDrop butterfly. Fades in on its first frame instead of popping.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/logo.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, sync) => sync
          ? child
          : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: kSoft, curve: Curves.easeOut, child: child),
    );
  }
}

/// Fades and lifts its child in once, for gentle screen entrances.
class FadeIn extends StatelessWidget {
  const FadeIn({super.key, required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: kSoft + delay,
      curve: Interval(delay.inMilliseconds / (kSoft + delay).inMilliseconds, 1, curve: kEase),
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 12 * (1 - v)), child: child),
      ),
      child: child,
    );
  }
}

IconData categoryIcon(int cat) => switch (cat) {
      1 => Icons.image_outlined,
      2 => Icons.movie_outlined,
      3 => Icons.music_note_outlined,
      4 => Icons.android_outlined,
      _ => Icons.insert_drive_file_outlined,
    };

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}
