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

/// A buddy in a soft colored circle.
class BuddyAvatar extends StatelessWidget {
  const BuddyAvatar({super.key, required this.index, this.size = 48});

  final int index;
  final double size;

  @override
  Widget build(BuildContext context) {
    final b = buddyAt(index);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: b.color.withValues(alpha: dark ? 0.32 : 0.28),
      ),
      child: Text(b.emoji, style: TextStyle(fontSize: size * 0.52, height: 1.1)),
    );
  }
}
