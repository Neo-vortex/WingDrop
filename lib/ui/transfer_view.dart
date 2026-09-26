import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/transfer_cubit.dart';
import '../core/avatars.dart';
import '../core/bridge.dart';
import '../core/format.dart';
import '../l10n/strings.dart';
import 'common.dart';
import '../blocs/chat_cubit.dart';
import 'chat.dart';
import 'overview.dart';
import 'radar.dart';
import 'speed_graph.dart';

/// Calm live view of the running transfers: a gliding ring, the speed graph,
/// the item in flight, per-phone cards when there are several, and gently
/// phrased time estimates.
class TransferView extends StatelessWidget {
  const TransferView({
    super.key,
    required this.sending,
    this.onFinished,
    this.connectingText,
    this.onRetry,
    this.showOverview = true,
    this.preparing = 0,
    this.prepProgress = 0,
    this.prepEta = double.nan,
  });

  final double prepEta;

  /// Sender: files still being shrunk; they follow in a second session, so
  /// the first one finishing isn't "all sent" yet.
  final int preparing;
  final double prepProgress;

  /// The per-file tile grid (the receiver shows its own, tappable one instead).
  final bool showOverview;

  final bool sending;
  final void Function(EngineStats stats)? onFinished;
  final String? connectingText;

  /// Shown as "Pick up where we left off" after a failure.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => TransferCubit()),
        BlocProvider(create: (context) => ChatCubit()..onIncoming = (m) => chatBanner(context, m)),
      ],
      child: BlocListener<TransferCubit, TransferState>(
        listenWhen: (a, b) => !a.finished && b.finished,
        listener: (context, state) => onFinished?.call(state.stats!),
        child: _TransferBody(
          sending: sending,
          connectingText: connectingText,
          onRetry: onRetry,
          showOverview: showOverview,
          preparing: preparing,
          prepProgress: prepProgress,
          prepEta: prepEta,
        ),
      ),
    );
  }
}

class _TransferBody extends StatelessWidget {
  const _TransferBody({
    required this.sending,
    this.connectingText,
    this.onRetry,
    this.showOverview = true,
    this.preparing = 0,
    this.prepProgress = 0,
    this.prepEta = double.nan,
  });

  final int preparing;
  final double prepProgress;
  final double prepEta;
  final bool sending;
  final bool showOverview;
  final String? connectingText;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final st = context.watch<TransferCubit>().state;
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final x = st.stats;
    if (x == null) return const SizedBox(height: 260);

    // Everything ready went over; the rest is still being shrunk.
    final holding = x.state == EngineState.done && preparing > 0;
    final done = x.state == EngineState.done && !holding;
    final failed = x.state == EngineState.failed || x.state == EngineState.cancelled;
    final connecting = x.state == EngineState.connecting || (x.state == EngineState.listening && x.totalBytes == 0);
    final sessions = x.sessions;

    final Widget center;
    if (holding) {
      center = Breathing(child: Icon(Icons.compress_rounded, size: 56, color: cs.primary));
    } else if (done) {
      center = Icon(Icons.check_rounded, size: 72, color: cs.primary);
    } else if (failed) {
      center = Icon(Icons.pause_rounded, size: 64, color: cs.error);
    } else if (connecting) {
      center = Breathing(child: Icon(Icons.wifi_tethering_rounded, size: 56, color: cs.primary));
    } else {
      center = Column(mainAxisSize: MainAxisSize.min, children: [
        SoftText(s.itemsOf(x.filesDone, x.filesTotal), style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(s.items, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ]);
    }

    final String headline;
    if (holding) {
      headline = s.shrinkingRest(preparing);
    } else if (done) {
      headline = sending ? s.allSent : s.allReceived;
    } else if (failed) {
      headline = x.state == EngineState.cancelled ? s.stopped : s.paused;
    } else if (connecting) {
      headline = connectingText ?? s.connectingShort;
    } else {
      headline = s.eta(st.etaSecs);
    }

    final String sub;
    if (holding) {
      sub = '${s.eta(prepEta)} · ${s.pct((prepProgress * 100).round())}';
    } else if (done) {
      sub = s.doneIn(fmtBytes(s, x.totalBytes), fmtMs(s, x.elapsedMs), fmtRate(s, x.avgBytesPerSec));
    } else if (failed) {
      sub = x.state == EngineState.cancelled ? '' : (x.error == 'declined' ? s.declined : s.interrupted);
    } else {
      // Bytes are coarse (one decimal) so this line changes slowly.
      sub = s.bytesOf(fmtBytes(s, x.doneBytes), fmtBytes(s, x.totalBytes));
    }

    final cur = x.current;
    return Column(
      children: [
        const SizedBox(height: 8),
        GlideRing(
          value: holding ? prepProgress : (done ? 1 : x.progress),
          child: AnimatedSwitcher(duration: kSoft, child: KeyedSubtree(key: ValueKey((x.state, holding)), child: center)),
        ),
        const SizedBox(height: 28),
        SoftText(headline, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.center),
        const SizedBox(height: 6),
        SoftText(sub, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
        if (failed && x.error != 'declined' && x.state != EngineState.cancelled && onRetry != null) ...[
          const SizedBox(height: 18),
          FadeIn(child: FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.replay_rounded), label: Text(s.resume))),
        ],
        const SizedBox(height: 24),
        AnimatedSize(
          duration: kSoft,
          curve: kEase,
          child: st.graph.length >= 2
              // Kept after the end, frozen: a quiet picture of how it went.
              ? Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                    child: SpeedGraph(samples: st.graph, capacity: TransferCubit.graphLength),
                  ),
                )
              : done && x.elapsedMs > 0
                  // Too quick to chart: say so instead of showing nothing.
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.bolt_rounded, size: 18, color: cs.primary),
                        const SizedBox(width: 6),
                        Text(s.flewOver(fmtMs(s, x.elapsedMs < 1000 ? 1000 : x.elapsedMs), x.elapsedMs < 1000),
                            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                      ]),
                    )
                  : const SizedBox(width: double.infinity),
        ),
        const SizedBox(height: 12),
        AnimatedSize(
          duration: kSoft,
          curve: kEase,
          alignment: Alignment.topCenter,
          child: showOverview ? TransferOverview(sessions: st.overview) : const SizedBox(width: double.infinity),
        ),
        const SizedBox(height: 12),
        AnimatedSize(
          duration: kSoft,
          curve: kEase,
          child: (!done && !failed && cur != null)
              ? _CurrentItem(
                  name: cur['name'] as String,
                  size: cur['size'] as int,
                  cat: cur['cat'] as int,
                  progress: (cur['size'] as int) == 0 ? 0 : (cur['done'] as int) / (cur['size'] as int),
                  caption: st.itemEtaSecs.isNaN || st.itemEtaSecs < 8 ? '' : s.eta(st.itemEtaSecs, forItem: true),
                  label: sending ? s.sendingNow : s.receivingNow,
                )
              : const SizedBox(width: double.infinity),
        ),
        const SizedBox(height: 14),
        if (!done && !failed && st.speedMBps > 0)
          SoftText(fmtMBps(s, st.speedMBps), style: t.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
        // Chat rides on the transfer's connection: there while it's open,
        // and the conversation stays readable afterwards.
        Builder(builder: (context) {
          final chat = context.watch<ChatCubit>().state;
          final show = chat.canSend || chat.messages.isNotEmpty;
          return AnimatedSize(
            duration: kSoft,
            child: show
                ? const Padding(padding: EdgeInsets.only(top: 14), child: ChatButton())
                : const SizedBox(width: double.infinity),
          );
        }),
        if (!sending && sessions.length > 1) ...[
          const SizedBox(height: 16),
          for (final ss in sessions) _PeerProgress(session: ss),
        ],
        const SizedBox(height: 8),
        _Details(stats: x),
      ],
    );
  }
}

/// One sender among several: buddy, name and a thin gliding bar.
class _PeerProgress extends StatelessWidget {
  const _PeerProgress({required this.session});

  final SessionStats session;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        BuddyAvatar(index: session.buddy, size: 36),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(peerName(s, session.buddy, session.nick), style: t.titleSmall),
            const SizedBox(height: 6),
            GlideBar(value: session.state == EngineState.done ? 1 : session.progress, height: 5),
          ]),
        ),
        const SizedBox(width: 12),
        Icon(
          switch (session.state) {
            EngineState.done => Icons.check_circle_rounded,
            EngineState.failed || EngineState.cancelled => Icons.pause_circle_outline_rounded,
            _ => Icons.more_horiz_rounded,
          },
          color: session.state == EngineState.failed ? cs.error : cs.primary,
          size: 20,
        ),
      ]),
    );
  }
}

class _CurrentItem extends StatelessWidget {
  const _CurrentItem({
    required this.name,
    required this.size,
    required this.cat,
    required this.progress,
    required this.caption,
    required this.label,
  });

  final String name, caption, label;
  final int size, cat;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 10),
            AnimatedSwitcher(
              duration: kSoft,
              child: Row(
                key: ValueKey(name),
                children: [
                  Icon(categoryIcon(cat), color: cs.primary),
                  const SizedBox(width: 12),
                  Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleMedium)),
                  const SizedBox(width: 8),
                  Text(fmtBytes(s, size), style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GlideBar(value: progress, height: 6),
            AnimatedSize(
              duration: kSoft,
              child: caption.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: SoftText(caption, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Technical details, tucked away; most people never open this.
class _Details extends StatelessWidget {
  const _Details({required this.stats});

  final EngineStats stats;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final moved = stats.doneBytes - stats.skippedBytes;
    final ratio = stats.wireBytes > 0 && moved > 0 ? moved / stats.wireBytes : 1.0;
    final rows = <(String, String)>[
      (s.streams, s.n(stats.streams)),
      (s.encryption, stats.encrypted ? (stats.aegis ? 'Vortex · AEGIS-128L' : 'Vortex · XChaCha20-Poly1305') : s.off),
      (s.compression, stats.compressed ? 'LZ4 / zstd · ${s.n(ratio.toStringAsFixed(2))}×' : s.off),
      if (stats.skippedBytes > 0) (s.resumedFrom, fmtBytes(s, stats.skippedBytes)),
      (s.avgSpeed, fmtRate(s, stats.avgBytesPerSec)),
    ];
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: Text(s.details, style: t.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text(r.$1, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant))),
                Text(r.$2, style: t.bodyMedium),
              ]),
            ),
        ],
      ),
    );
  }
}
