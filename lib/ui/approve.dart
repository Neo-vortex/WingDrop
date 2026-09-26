import 'package:flutter/material.dart';

import '../core/avatars.dart';
import '../core/format.dart';
import '../l10n/strings.dart';
import 'radar.dart';

/// "🐼 Mamad wants to send you 12 items (1.2 GB)".
/// Returns 0 = not now, 1 = accept, 2 = accept and remember them.
Future<int> askApproval(BuildContext context, Map args) async {
  final s = S.of(context);
  final buddy = args['buddy'] as int;
  final who = peerName(s, buddy, args['nick'] as String);
  final answer = await showModalBottomSheet<int>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (context) {
      final t = Theme.of(context).textTheme;
      final cs = Theme.of(context).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            BuddyAvatar(index: buddy, size: 84, intro: true),
            const SizedBox(height: 18),
            Text(
              s.wantsToSend(who, args['files'] as int, fmtBytes(s, args['bytes'] as int)),
              style: t.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(s.acceptQ, style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 26),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: () => Navigator.pop(context, 2), child: Text(s.acceptRemember)),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(onPressed: () => Navigator.pop(context, 1), child: Text(s.accept)),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: TextButton(onPressed: () => Navigator.pop(context, 0), child: Text(s.decline)),
            ),
          ]),
        ),
      );
    },
  );
  return answer ?? 0;
}
