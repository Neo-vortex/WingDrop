import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../l10n/strings.dart';

/// Friendly permission flow: explain first, then ask; if the user has blocked
/// it for good, offer a gentle shortcut to Settings. Never nags twice in a row.
Future<bool> ensurePermission(BuildContext context, String kind) async {
  if (await Bridge.call<bool>('hasPermissions', {'kinds': [kind]}) == true) return true;
  if (!context.mounted) return false;
  final s = S.of(context);
  final (icon, title, body) = switch (kind) {
    'nearby' => (Icons.wifi_tethering_rounded, s.permNearbyTitle, s.permNearbyBody),
    'media' => (Icons.photo_library_outlined, s.permMediaTitle, s.permMediaBody),
    'camera' => (Icons.qr_code_scanner_rounded, s.permCameraTitle, s.permCameraBody),
    _ => (Icons.notifications_none_rounded, s.permNotifTitle, s.permNotifBody),
  };

  final go = await _sheet(context, icon: icon, title: title, body: body, primary: s.sure, secondary: s.notNow);
  if (go != true) return false;

  final status = await Bridge.call<String>('permissions', {'kinds': [kind]});
  if (status == 'granted') return true;
  if (status == 'blocked' && context.mounted) {
    final open = await _sheet(
      context,
      icon: Icons.settings_outlined,
      title: s.permBlockedTitle,
      body: s.permBlockedBody,
      primary: s.openSettings,
      secondary: s.notNow,
    );
    if (open == true) await Bridge.call('openSettings');
  }
  return false;
}

/// Notifications are optional: ask once, kindly, and never block the flow.
Future<void> maybeAskNotifications(BuildContext context) async {
  if (await Bridge.call<String>('prefsGet', {'key': 'askedNotif'}) == '1') return;
  await Bridge.call('prefsSet', {'key': 'askedNotif', 'value': '1'});
  if (context.mounted) await ensurePermission(context, 'notif');
}

Future<bool?> _sheet(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String body,
  required String primary,
  required String secondary,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    builder: (context) {
      final t = Theme.of(context).textTheme;
      final cs = Theme.of(context).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: cs.primaryContainer, shape: BoxShape.circle),
                child: Icon(icon, color: cs.onPrimaryContainer),
              ),
              const SizedBox(height: 18),
              Text(title, style: t.titleLarge),
              const SizedBox(height: 10),
              Text(body, style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant, height: 1.5)),
              const SizedBox(height: 26),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(primary)),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(onPressed: () => Navigator.pop(context, false), child: Text(secondary)),
              ),
            ],
          ),
        ),
      );
    },
  );
}
