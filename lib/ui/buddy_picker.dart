import 'package:flutter/material.dart';

import '../core/avatars.dart';
import 'common.dart';

/// Grid of animal buddies; the chosen one grows a little and gets a ring.
class BuddyPicker extends StatelessWidget {
  const BuddyPicker({super.key, required this.selected, required this.onPick, this.persian = false});

  final int selected;
  final ValueChanged<int> onPick;
  final bool persian;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 12,
      children: [
        for (var i = 0; i < buddies.length; i++)
          GestureDetector(
            onTap: () => onPick(i),
            child: SizedBox(
              width: 72,
              child: Column(children: [
                AnimatedContainer(
                  duration: kSoft,
                  curve: kEase,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: i == selected ? cs.primary : Colors.transparent, width: 2.5),
                  ),
                  child: AnimatedScale(
                    scale: i == selected ? 1.08 : 1,
                    duration: kSoft,
                    curve: Curves.easeOutBack,
                    // Says hi when picked (the tap itself plays it too).
                    child: BuddyAvatar(index: i, size: 54, trigger: i == selected),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  buddies[i].name(persian),
                  style: t.labelSmall?.copyWith(color: i == selected ? cs.primary : cs.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ]),
            ),
          ),
      ],
    );
  }
}
