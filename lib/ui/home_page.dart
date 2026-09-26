import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/app_cubit.dart';
import '../core/bridge.dart';
import '../main.dart' show sharedIntake;
import 'send_page.dart';
import '../core/settings.dart';
import '../l10n/strings.dart';
import 'benchmark_page.dart';
import 'common.dart';
import 'picker_page.dart';
import 'receive_page.dart';
import 'settings_page.dart';

String presetLabel(S s, Preset p) => switch (p) {
      Preset.maxSpeed => s.presetMax,
      Preset.compatibility => s.presetCompat,
      Preset.secure => s.presetSecure,
      Preset.custom => s.presetCustom,
    };

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    sharedIntake.addListener(_takeShared);
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeShared());
  }

  @override
  void dispose() {
    sharedIntake.removeListener(_takeShared);
    super.dispose();
  }

  /// Files handed to us with "Share to WingDrop" go straight to sending.
  Future<void> _takeShared() async {
    final list = await Bridge.list('takeShared');
    if (list.isEmpty || !mounted) return;
    final items = [
      for (final m in list)
        SendItem(
          id: (m['uri'] ?? m['path']) as String,
          uri: m['uri'] as String?,
          path: m['path'] as String?,
          name: m['name'] as String,
          size: (m['size'] as int?) ?? 0,
          cat: (m['cat'] as int?) ?? 0,
          mime: (m['mime'] as String?) ?? '',
          heic: m['heic'] == true,
        ),
    ];
    Navigator.of(context).popUntil((r) => r.isFirst);
    _open(context, SendPage(items: items));
  }

  void _open(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final preset = context.select<AppCubit, Preset>((c) => c.state.settings.preset);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              FadeIn(
                child: Row(children: [
                  const AppLogo(size: 52),
                  const SizedBox(width: 14),
                  Text(s.appName, style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
                ]),
              ),
              const SizedBox(height: 8),
              FadeIn(
                delay: const Duration(milliseconds: 80),
                child: Text(s.tagline, style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
              ),
              const Spacer(),
              FadeIn(
                delay: const Duration(milliseconds: 140),
                child: _BigAction(
                  icon: Icons.north_east_rounded,
                  title: s.send,
                  subtitle: s.sendSub,
                  filled: true,
                  onTap: () => _open(context, const PickerPage()),
                ),
              ),
              const SizedBox(height: 16),
              FadeIn(
                delay: const Duration(milliseconds: 200),
                child: _BigAction(
                  icon: Icons.south_west_rounded,
                  title: s.receive,
                  subtitle: s.receiveSub,
                  onTap: () => _open(context, const ReceivePage()),
                ),
              ),
              const Spacer(),
              FadeIn(
                delay: const Duration(milliseconds: 260),
                child: Row(
                  children: [
                    ActionChip(
                      avatar: Icon(Icons.tune_rounded, size: 18, color: cs.primary),
                      label: Text(presetLabel(s, preset)),
                      side: BorderSide(color: cs.outlineVariant),
                      shape: const StadiumBorder(),
                      onPressed: () => _open(context, const SettingsPage()),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.speed_rounded, size: 18),
                      label: Text(s.benchmark),
                      onPressed: () => _open(context, const BenchmarkPage()),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _BigAction extends StatelessWidget {
  const _BigAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final bg = filled ? cs.primaryContainer : cs.surfaceContainerLow;
    final fg = filled ? cs.onPrimaryContainer : cs.onSurface;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: fg.withValues(alpha: 0.08), shape: BoxShape.circle),
                child: Icon(icon, color: fg, size: 28),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.titleLarge?.copyWith(color: fg, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: t.bodyMedium?.copyWith(color: fg.withValues(alpha: 0.7))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
