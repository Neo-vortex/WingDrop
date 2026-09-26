import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/app_cubit.dart';
import '../blocs/receive_cubit.dart';
import '../core/bridge.dart';
import '../core/format.dart';
import '../l10n/strings.dart';
import '../core/avatars.dart';
import 'common.dart';
import 'fancy_qr.dart';
import 'nerd_log.dart';
import 'overview.dart';
import 'permissions.dart';
import 'transfer_view.dart';

class ReceivePage extends StatelessWidget {
  const ReceivePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => ReceiveCubit(context.read<AppCubit>().state.settings),
      child: const _ReceiveView(),
    );
  }
}

class _ReceiveView extends StatefulWidget {
  const _ReceiveView();

  @override
  State<_ReceiveView> createState() => _ReceiveViewState();
}

class _ReceiveViewState extends State<_ReceiveView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final cubit = context.read<ReceiveCubit>();
    if (cubit.settings.link != 'lan' && !await ensurePermission(context, 'nearby')) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (!mounted) return;
    await maybeAskNotifications(context);
    await cubit.start();
    // The beacon (near-instant discovery for senders) needs Bluetooth; it
    // starts by itself once Bluetooth comes on.
    if (mounted && cubit.state.pairing?.mode == 'p2p') await offerBluetooth(context);
  }

  Future<bool> _confirmStop() async {
    final s = context.s;
    final stats = await Bridge.stats();
    if (!stats.active || !mounted) return true;
    final stop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.stopReceivingQ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.keepGoing)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(s.stop)),
        ],
      ),
    );
    if (stop == true && mounted) await context.read<ReceiveCubit>().cancel();
    return stop == true;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final st = context.watch<ReceiveCubit>().state;
    final Widget top = switch (st.phase) {
      ReceivePhase.starting => _Waiting(key: const ValueKey('start'), text: s.settingUp),
      ReceivePhase.error => _StartError(key: const ValueKey('err'), state: st, onRetry: _start),
      ReceivePhase.ready when st.active => Padding(
          key: const ValueKey('xfer'),
          padding: const EdgeInsets.only(top: 8),
          // The grid below shows the files; no second grid up here.
          child: const TransferView(sending: false, showOverview: false),
        ),
      ReceivePhase.ready => _QrCard(key: const ValueKey('qr'), state: st),
    };

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmStop() && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(s.receiveTitle), actions: const [NerdLogButton()]),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 600),
              switchInCurve: kEase,
              layoutBuilder: fullWidthLayout,
              transitionBuilder: (child, a) => FadeTransition(opacity: a, child: child),
              child: top,
            ),
            if (st.active && st.phase == ReceivePhase.ready)
              Align(
                child: TextButton(
                  onPressed: () => context.read<ReceiveCubit>().dismissTransfer(),
                  child: const Icon(Icons.qr_code_rounded),
                ),
              ),
            AnimatedSize(
              duration: kSoft,
              curve: kEase,
              child: st.received.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : _ReceivedGrid(items: st.received, progress: st.progress),
            ),
          ],
        ),
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 360,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Breathing(child: Icon(Icons.wifi_tethering_rounded, size: 72, color: cs.primary)),
        const SizedBox(height: 24),
        Text(text, style: Theme.of(context).textTheme.titleMedium),
      ]),
    );
  }
}

class _StartError extends StatelessWidget {
  const _StartError({super.key, required this.state, required this.onRetry});

  final ReceiveState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 380,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(state.wifiOff ? Icons.wifi_off_rounded : Icons.cloud_off_rounded, size: 60, color: cs.error),
        const SizedBox(height: 20),
        Text(state.wifiOff ? s.wifiOff : s.couldntStart, style: t.titleMedium, textAlign: TextAlign.center),
        if (!state.wifiOff && state.error.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(state.error, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
        ],
        const SizedBox(height: 24),
        if (state.wifiOff)
          OutlinedButton(onPressed: () => Bridge.call('wifiSettings'), child: Text(s.openWifi)),
        const SizedBox(height: 10),
        FilledButton(onPressed: onRetry, child: Text(s.tryAgain)),
      ]),
    );
  }
}

class _QrCard extends StatelessWidget {
  const _QrCard({super.key, required this.state});

  final ReceiveState state;

  String _band(S s, int freq) {
    if (freq >= 5925) return s.n('6 GHz · $freq MHz');
    if (freq >= 4900) return s.n('5 GHz · $freq MHz');
    if (freq > 0) return s.n('2.4 GHz · $freq MHz');
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final p = state.pairing!;
    final details = <(String, String)>[
      (s.link, switch (p.mode) { 'p2p' => s.linkP2p, 'lohs' => s.linkLohs, _ => s.linkLan }),
      if (p.ssid.isNotEmpty) ('SSID', p.ssid),
      if (state.freq > 0) (s.band, _band(s, state.freq)),
      if (p.mode != 'lan') (s.wifiSecurity, p.security.toUpperCase()),
      ('IP', p.hosts.join(', ')),
    ];
    return Column(
      children: [
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          BuddyAvatar(index: p.buddy, size: 36),
          const SizedBox(width: 10),
          Text(p.nick.isEmpty ? buddyAt(p.buddy).name(s.fa) : p.nick,
              style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 14),
        Text(s.scanThis, style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
        const SizedBox(height: 18),
        FadeIn(
          child: LayoutBuilder(
            builder: (context, c) => FancyQr(
              data: p.encode(),
              buddy: p.buddy,
              size: (c.maxWidth - 60).clamp(220.0, 340.0),
              onTap: () => FullScreenQr.show(context, p.encode(), p.buddy),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.open_in_full_rounded, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(s.tapToEnlarge, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ]),
        if (!state.beacon) ...[
          const SizedBox(height: 12),
          // Tapping it goes straight to Android's "turn on Bluetooth?" popup.
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              if (await ensurePermission(context, 'nearby')) await Bridge.call('btSettings');
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.bluetooth_disabled_rounded, size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Flexible(child: Text(s.receiverBtOff, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant))),
                const SizedBox(width: 6),
                Text(s.turnOn, style: t.bodySmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ],
        const SizedBox(height: 22),
        Breathing(
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.hourglass_empty_rounded, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(s.waiting, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          ]),
        ),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(s.networkDetails, style: t.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
            children: [
              for (final d in details)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Text(d.$1, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant))),
                    Flexible(
                      flex: 2,
                      child: Text(d.$2, style: t.bodyMedium, textAlign: TextAlign.end, textDirection: TextDirection.ltr),
                    ),
                  ]),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Everything received, as one grid of tiles: the same dim-to-bright fill
/// while a file arrives, a real thumbnail once it has landed, and a tap for
/// Open / Install / Delete.
class _ReceivedGrid extends StatelessWidget {
  const _ReceivedGrid({required this.items, required this.progress});

  final List<ReceivedItem> items;
  final Map<String, OverviewFile> progress;

  static final _thumbs = <String, Future<Uint8List?>>{};

  Future<Uint8List?>? _image(ReceivedItem r) {
    final live = progress['${r.batch}:${r.index}'];
    if (r.done && (r.cat == 1 || r.cat == 2 || r.cat == 3 || r.mime.startsWith('image/') || r.mime.startsWith('video/'))) {
      // Landed: a real thumbnail from the saved file (survives the session).
      return _thumbs[r.uri] ??= Bridge.thumb(r.uri).then((b) async => b ?? await PreviewCache.get(r.batch, r.index));
    }
    if (live != null && live.hasPreview) return PreviewCache.get(r.batch, r.index);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    // One tile per split-app folder instead of one per APK part.
    final seenApps = <String>{};
    final tiles = items.where((r) => !(r.cat == 4 && r.rel.startsWith('Apps/') && !seenApps.add(r.rel))).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.receivedFiles, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(s.tapToOpen, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 96,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: tiles.length,
          itemBuilder: (context, i) {
            final r = tiles[i];
            final live = progress['${r.batch}:${r.index}'];
            return GlowTile(
              key: ValueKey(r.uri),
              image: _image(r),
              progress: r.done ? 1 : (live?.progress ?? 0),
              cat: r.cat,
              name: _title(r),
              onTap: () => _actions(context, r, _image(r)),
            );
          },
        ),
      ]),
    );
  }

  String _title(ReceivedItem r) => r.cat == 4 && r.rel.startsWith('Apps/') ? r.rel.substring(5) : r.name;

  Future<void> _actions(BuildContext context, ReceivedItem r, Future<Uint8List?>? image) async {
    final s = context.s;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) {
        final t = Theme.of(sheet).textTheme;
        final cs = Theme.of(sheet).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox.square(
                dimension: 150,
                child: GlowTile(image: image, progress: r.done ? 1 : 0, cat: r.cat, name: _title(r)),
              ),
              const SizedBox(height: 16),
              Text(_title(r), style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.center,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(r.done ? fmtBytes(s, r.size) : s.stillArriving, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 22),
              if (r.done) ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: Icon(r.cat == 4 ? Icons.install_mobile_rounded : Icons.open_in_new_rounded),
                    label: Text(r.cat == 4 ? s.install : s.open),
                    onPressed: () {
                      Navigator.pop(sheet);
                      _open(context, r);
                    },
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text(s.delete),
                    onPressed: () async {
                      Navigator.pop(sheet);
                      await _delete(context, r);
                    },
                  ),
                ),
              ],
            ]),
          ),
        );
      },
    );
  }

  Future<void> _open(BuildContext context, ReceivedItem r) async {
    final s = context.s;
    if (r.cat == 4) {
      // Split apps are installed as a group from their folder.
      final group = r.rel.startsWith('Apps/') ? items.where((i) => i.rel == r.rel && i.done).map((i) => i.uri).toList() : [r.uri];
      final msg = await Bridge.call<String>('install', {'uris': group}).catchError((_) => null);
      if (msg != null && context.mounted) toast(context, msg);
      return;
    }
    try {
      await Bridge.call('open', {'uri': r.uri, 'mime': r.mime});
    } catch (_) {
      if (context.mounted) toast(context, s.noAppToOpen);
    }
  }

  /// Delete after a gentle confirmation, then a quiet note.
  Future<void> _delete(BuildContext context, ReceivedItem r) async {
    final s = context.s;
    final name = _title(r);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: Text(s.deleteQ),
        content: Text(s.deleteBody(name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.keepIt)),
          FilledButton.tonal(onPressed: () => Navigator.pop(context, true), child: Text(s.delete)),
        ],
      ),
    );
    if (sure != true || !context.mounted) return;
    // A split app lives as several APKs in one folder; they go together.
    final targets = r.cat == 4 && r.rel.startsWith('Apps/') ? items.where((i) => i.rel == r.rel).toList() : [r];
    for (final x in targets) {
      await Bridge.call('deleteReceived', {'uri': x.uri});
    }
    if (context.mounted) toast(context, s.deleted);
  }
}
