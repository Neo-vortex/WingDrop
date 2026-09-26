import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The animal buddies people pick as their identity. Colors are soft, muted
/// pastels that stay calm in both light and dark themes.
class Buddy {
  const Buddy(this.emoji, this.en, this.fa, this.color);

  final String emoji;
  final String en, fa;
  final Color color;

  String name(bool persian) => persian ? fa : en;
}

const buddies = <Buddy>[
  Buddy('🦊', 'Fox', 'روباه', Color(0xFFE0A07A)),
  Buddy('🐼', 'Panda', 'پاندا', Color(0xFF9AA5A0)),
  Buddy('🐨', 'Koala', 'کوالا', Color(0xFFA7B4C2)),
  Buddy('🦉', 'Owl', 'جغد', Color(0xFFB9A07E)),
  Buddy('🐢', 'Turtle', 'لاک‌پشت', Color(0xFF8DB596)),
  Buddy('🐬', 'Dolphin', 'دلفین', Color(0xFF7FAFC9)),
  Buddy('🦦', 'Otter', 'سمور آبی', Color(0xFFB08F7A)),
  Buddy('🐧', 'Penguin', 'پنگوئن', Color(0xFF8C9BB5)),
  Buddy('🦔', 'Hedgehog', 'جوجه‌تیغی', Color(0xFFC4A58A)),
  Buddy('🐝', 'Bee', 'زنبور', Color(0xFFE2C46E)),
  Buddy('🦋', 'Butterfly', 'پروانه', Color(0xFFB39DCC)),
  Buddy('🐙', 'Octopus', 'هشت‌پا', Color(0xFFD69A9A)),
  Buddy('🐱', 'Cat', 'گربه', Color(0xFFD9B38C)),
  Buddy('🐶', 'Pup', 'توله‌سگ', Color(0xFFC9A27E)),
  Buddy('🐰', 'Bunny', 'خرگوش', Color(0xFFD8B4C0)),
  Buddy('🦁', 'Lion', 'شیر', Color(0xFFE0B066)),
  Buddy('🐯', 'Tiger', 'ببر', Color(0xFFE39A62)),
  Buddy('🐻', 'Bear', 'خرس', Color(0xFFA88A74)),
  Buddy('🐻‍❄️', 'Polar bear', 'خرس قطبی', Color(0xFFA9C1CF)),
  Buddy('🦥', 'Sloth', 'تنبل', Color(0xFFA9A084)),
  Buddy('🦘', 'Kangaroo', 'کانگورو', Color(0xFFC8A07A)),
  Buddy('🦒', 'Giraffe', 'زرافه', Color(0xFFD9BE7C)),
  Buddy('🐘', 'Elephant', 'فیل', Color(0xFF9FAAB5)),
  Buddy('🦙', 'Llama', 'لاما', Color(0xFFCDB89C)),
  Buddy('🦌', 'Deer', 'آهو', Color(0xFFB8957A)),
  Buddy('🐿️', 'Squirrel', 'سنجاب', Color(0xFFC49373)),
  Buddy('🦩', 'Flamingo', 'فلامینگو', Color(0xFFE3A2B2)),
  Buddy('🦜', 'Parrot', 'طوطی', Color(0xFF8FC39A)),
  Buddy('🕊️', 'Dove', 'کبوتر', Color(0xFFB5C0CC)),
  Buddy('🦢', 'Swan', 'قو', Color(0xFFC3CBD6)),
  Buddy('🐳', 'Whale', 'نهنگ', Color(0xFF7F9FC4)),
  Buddy('🦭', 'Seal', 'فوک', Color(0xFF9AA7B3)),
  Buddy('🐸', 'Frog', 'قورباغه', Color(0xFF94BF87)),
  Buddy('🦎', 'Gecko', 'مارمولک', Color(0xFFA3C27E)),
  Buddy('🐞', 'Ladybug', 'کفشدوزک', Color(0xFFD99191)),
  Buddy('🐌', 'Snail', 'حلزون', Color(0xFFBDA88E)),
];

// Buddies are encoded as one base-36 character in the Wi-Fi Direct name
// (see ssid.dart), so there can be at most 36 of them.
const maxBuddies = 36;

Buddy buddyAt(int i) => buddies[i.clamp(0, buddies.length - 1)];

/// How each buddy moves when it says hi: a short, gentle motion that fits
/// the animal.
enum BuddyMotion { hop, flutter, swim, wiggle, nod, waddle, stretch, jelly }

const _motions = <String, BuddyMotion>{
  '🐰': BuddyMotion.hop, '🦘': BuddyMotion.hop, '🐸': BuddyMotion.hop, '🐿️': BuddyMotion.hop, '🐶': BuddyMotion.hop,
  '🦉': BuddyMotion.flutter, '🐝': BuddyMotion.flutter, '🦋': BuddyMotion.flutter, '🦜': BuddyMotion.flutter,
  '🕊️': BuddyMotion.flutter, '🦢': BuddyMotion.flutter, '🦩': BuddyMotion.flutter, '🐞': BuddyMotion.flutter,
  '🐬': BuddyMotion.swim, '🐳': BuddyMotion.swim, '🦭': BuddyMotion.swim, '🦦': BuddyMotion.swim,
  '🦊': BuddyMotion.wiggle, '🐱': BuddyMotion.wiggle, '🦔': BuddyMotion.wiggle, '🦎': BuddyMotion.wiggle,
  '🐯': BuddyMotion.wiggle, '🦙': BuddyMotion.wiggle,
  '🐼': BuddyMotion.nod, '🐨': BuddyMotion.nod, '🐻': BuddyMotion.nod, '🐻‍❄️': BuddyMotion.nod, '🦁': BuddyMotion.nod,
  '🐘': BuddyMotion.nod, '🦒': BuddyMotion.nod, '🦌': BuddyMotion.nod,
  '🐧': BuddyMotion.waddle,
  '🦥': BuddyMotion.stretch, '🐌': BuddyMotion.stretch, '🐢': BuddyMotion.stretch,
  '🐙': BuddyMotion.jelly,
};

BuddyMotion motionOf(Buddy b) => _motions[b.emoji] ?? BuddyMotion.nod;

Duration _durationOf(BuddyMotion m) => switch (m) {
      BuddyMotion.stretch => const Duration(milliseconds: 1300),
      BuddyMotion.swim => const Duration(milliseconds: 950),
      BuddyMotion.waddle || BuddyMotion.jelly => const Duration(milliseconds: 850),
      _ => const Duration(milliseconds: 700),
    };

/// A buddy in a soft colored circle. It does its little move when tapped,
/// when [trigger] changes to a new value, or once on appearing with [intro].
class BuddyAvatar extends StatefulWidget {
  const BuddyAvatar({super.key, required this.index, this.size = 48, this.intro = false, this.trigger, this.onTap = true});

  final int index;
  final double size;
  final bool intro;
  final Object? trigger;

  /// Move on tap. Uses a raw pointer listener, so the tap still reaches
  /// whatever the avatar sits in (a list tile, a button).
  final bool onTap;

  @override
  State<BuddyAvatar> createState() => _BuddyAvatarState();
}

class _BuddyAvatarState extends State<BuddyAvatar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: _durationOf(motionOf(buddyAt(widget.index))));

  @override
  void initState() {
    super.initState();
    if (widget.intro) Future.delayed(const Duration(milliseconds: 250), _play);
  }

  @override
  void didUpdateWidget(BuddyAvatar old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _c.duration = _durationOf(motionOf(buddyAt(widget.index)));
      _play();
    } else if (widget.trigger != null && widget.trigger != false && widget.trigger != old.trigger) {
      _play();
    }
  }

  void _play() {
    if (!mounted || MediaQuery.maybeDisableAnimationsOf(context) == true) return;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = buddyAt(widget.index);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final size = widget.size;
    final motion = motionOf(b);
    final avatar = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: b.color.withValues(alpha: dark ? 0.32 : 0.28),
      ),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) =>
            _c.isAnimating ? Transform(alignment: Alignment.bottomCenter, transform: _pose(motion, _c.value, size), child: child) : child!,
        child: Text(b.emoji, style: TextStyle(fontSize: size * 0.52, height: 1.1)),
      ),
    );
    if (!widget.onTap) return avatar;
    return Listener(onPointerDown: (_) => _play(), child: avatar);
  }
}

/// Where the animal is at time t (0..1) of its move. Everything settles back
/// to rest at t = 1; amplitudes fade out so the end is soft.
Matrix4 _pose(BuddyMotion m, double t, double size) {
  const pi = 3.141592653589793;
  final fade = 1 - t;
  double x = 0, y = 0, rot = 0, sx = 1, sy = 1;
  switch (m) {
    case BuddyMotion.hop:
      // A big hop and a little one, squashing on each landing.
      final phase = _sin(2 * pi * t).abs();
      y = -phase * (t < 0.5 ? 0.30 : 0.14) * size;
      final land = 1 - phase;
      sx = 1 + 0.10 * land * fade;
      sy = 1 - 0.10 * land * fade;
    case BuddyMotion.flutter:
      y = -_sin(pi * t) * 0.14 * size;
      sx = 1 + 0.16 * _sin(8 * pi * t) * fade;
    case BuddyMotion.swim:
      // Glides side to side, leaning into the stroke, bobbing on the wave.
      x = _sin(2 * pi * t) * 0.10 * size * fade;
      rot = _sin(2 * pi * t) * 0.18 * fade;
      y = _sin(4 * pi * t) * 0.03 * size;
    case BuddyMotion.wiggle:
      rot = _sin(6 * pi * t) * 0.22 * fade;
    case BuddyMotion.nod:
      y = -_sin(3 * pi * t).abs() * 0.08 * size * fade;
      rot = _sin(3 * pi * t) * 0.06 * fade;
    case BuddyMotion.waddle:
      rot = _sin(4 * pi * t) * 0.16 * fade;
      y = -_sin(4 * pi * t).abs() * 0.05 * size;
    case BuddyMotion.stretch:
      final s = _sin(pi * t);
      sx = 1 + 0.12 * s;
      sy = 1 - 0.06 * s;
      rot = 0.08 * s;
    case BuddyMotion.jelly:
      final s = _sin(4 * pi * t) * fade;
      sx = 1 + 0.12 * s;
      sy = 1 - 0.12 * s;
  }
  return Matrix4.identity()
    ..translateByDouble(x, y, 0, 1)
    ..rotateZ(rot)
    ..scaleByDouble(sx, sy, 1, 1);
}

double _sin(double v) => math.sin(v);
