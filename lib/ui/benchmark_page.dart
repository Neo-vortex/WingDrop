import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/benchmark_cubit.dart';
import '../l10n/strings.dart';
import 'common.dart';

class BenchmarkPage extends StatelessWidget {
  const BenchmarkPage({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocProvider(create: (_) => BenchmarkCubit(), child: const _BenchView());
}

class _BenchView extends StatelessWidget {
  const _BenchView();

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final st = context.watch<BenchmarkCubit>().state;

    final Widget body = switch (st) {
      BenchIdle() || BenchFailed() => Column(
          key: const ValueKey('idle'),
          children: [
            const SizedBox(height: 60),
            Breathing(child: Icon(Icons.speed_rounded, size: 80, color: cs.primary)),
            const SizedBox(height: 32),
            Text(s.benchTitle, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(s.benchBody, style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
            if (st is BenchFailed) ...[
              const SizedBox(height: 12),
              Text(st.message, style: t.bodySmall?.copyWith(color: cs.error)),
            ],
            const SizedBox(height: 36),
            FilledButton(onPressed: () => context.read<BenchmarkCubit>().run(), child: Text(s.benchStart)),
          ],
        ),
      BenchRunning() => Column(
          key: const ValueKey('run'),
          children: [
            const SizedBox(height: 120),
            Breathing(
              period: const Duration(milliseconds: 1800),
              child: Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(color: cs.primaryContainer, shape: BoxShape.circle),
                child: Icon(Icons.memory_rounded, size: 56, color: cs.onPrimaryContainer),
              ),
            ),
            const SizedBox(height: 32),
            Text(s.benchRunning, style: t.titleMedium),
            const SizedBox(height: 6),
            Text(s.benchRunningSub, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
      BenchDone(:final result) => _Result(key: const ValueKey('done'), r: result),
    };

    return Scaffold(
      appBar: AppBar(title: Text(s.benchmark)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          switchInCurve: kEase,
          layoutBuilder: fullWidthLayout,
          transitionBuilder: (child, a) => FadeTransition(opacity: a, child: child),
          child: body,
        ),
      ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({super.key, required this.r});

  final BenchResult r;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    String mb(double v) => s.n(v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1));
    final rows = [
      ('${s.benchEncrypt} · ${r.aegis ? 'AEGIS-128L' : 'XChaCha20'}', r.encSingle, r.encMulti),
      (s.benchCompress, r.lzcSingle, r.lzcMulti),
      (s.benchDecompress, r.lzdSingle, r.lzdMulti),
    ];
    return Column(
      children: [
        const SizedBox(height: 24),
        Text(s.score, style: t.titleMedium?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 4),
        // The score counts up once, slowly, then rests.
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: r.score),
          duration: const Duration(milliseconds: 1600),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => Text(
            s.n(v.round()),
            style: t.displayLarge?.copyWith(fontWeight: FontWeight.w600, color: cs.primary),
          ),
        ),
        Text(s.higherBetter, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 24),
        Row(children: [
          Expanded(child: _ScoreTile(label: s.singleCore, value: s.n(r.singleScore.round()))),
          const SizedBox(width: 12),
          Expanded(child: _ScoreTile(label: s.multiCore, value: s.n(r.multiScore.round()))),
        ]),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Text(s.verdict(r.pipelineMBps), style: t.bodyLarge),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            child: Column(children: [
              Row(children: [
                const Expanded(child: SizedBox()),
                SizedBox(width: 80, child: Text(s.singleCore, textAlign: TextAlign.end, style: t.labelSmall)),
                SizedBox(width: 80, child: Text(s.multiCore, textAlign: TextAlign.end, style: t.labelSmall)),
              ]),
              const SizedBox(height: 8),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    Expanded(child: Text(row.$1, style: t.bodyMedium)),
                    SizedBox(width: 80, child: Text(mb(row.$2), textAlign: TextAlign.end, style: t.bodyMedium)),
                    SizedBox(width: 80, child: Text(mb(row.$3), textAlign: TextAlign.end, style: t.bodyMedium)),
                  ]),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Expanded(child: Text(s.benchMemory, style: t.bodyMedium)),
                  SizedBox(width: 80, child: Text(mb(r.memory), textAlign: TextAlign.end, style: t.bodyMedium)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Expanded(child: Text(s.benchNet, style: t.bodyMedium)),
                  SizedBox(width: 80, child: Text(mb(r.network), textAlign: TextAlign.end, style: t.bodyMedium)),
                ]),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Text('MB/s', style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton(onPressed: () => context.read<BenchmarkCubit>().run(), child: Text(s.benchAgain)),
      ],
    );
  }
}

class _ScoreTile extends StatelessWidget {
  const _ScoreTile({required this.label, required this.value});

  final String label, value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Text(label, style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(value, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
