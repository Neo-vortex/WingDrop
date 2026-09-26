import 'dart:async';

import 'package:flutter/material.dart';

import '../core/avatars.dart';
import '../core/bridge.dart';
import '../core/settings.dart';
import '../l10n/strings.dart';
import 'common.dart';
import 'permissions.dart';

IconData signalIcon(int bars) => switch (bars) {
      <= 0 => Icons.signal_wifi_0_bar_rounded,
      1 => Icons.network_wifi_1_bar_rounded,
      2 => Icons.network_wifi_2_bar_rounded,
      3 => Icons.network_wifi_3_bar_rounded,
      _ => Icons.signal_wifi_4_bar_rounded,
    };

String peerName(S s, int buddy, String nick) => nick.isEmpty ? buddyAt(buddy).name(s.fa) : nick;

/// Receivers around us, found through Wi-Fi Direct service discovery. Shows
/// each one's buddy, Wi-Fi tech, requirements and live signal; one tap sends.
class DiscoveryRadar extends StatefulWidget {
  const DiscoveryRadar({super.key, required this.onPick});

  /// One or more receivers; `trusted` = we share a bond key with them.
  final void Function(List<(Pairing, bool trusted)> picked) onPick;

  @override
  State<DiscoveryRadar> createState() => _DiscoveryRadarState();
}

class _DiscoveryRadarState extends State<DiscoveryRadar> {
  Timer? _timer;
  bool? _allowed;
  bool _wifiOn = true;
  bool _btOn = true;
  List<Map<String, dynamic>> _found = const [];
  Set<String> _trusted = const {};
  final Set<String> _picked = {};

  @override
  void initState() {
    super.initState();
    Bridge.call<bool>('hasPermissions', {'kinds': ['nearby']}).then((ok) {
      if (!mounted) return;
      setState(() => _allowed = ok == true);
      if (ok == true) _start();
    });
  }

  Future<void> _ask() async {
    final ok = await ensurePermission(context, 'nearby');
    if (!mounted) return;
    setState(() => _allowed = ok);
    if (ok) _start();
  }

  Future<void> _start() async {
    // Wi-Fi Direct runs on the Wi-Fi chip: nothing can be found with Wi-Fi off.
    final on = await Bridge.call<bool>('wifiOn') ?? true;
    if (!mounted) return;
    setState(() => _wifiOn = on);
    if (!on) {
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (t) async {
        if (await Bridge.call<bool>('wifiOn') == true) {
          t.cancel();
          await Future.delayed(const Duration(milliseconds: 1500));
          if (mounted) _start();
        }
      });
      return;
    }
    Bridge.list('bonds').then((b) {
      if (mounted) setState(() => _trusted = {for (final x in b) x['id'] as String});
    });
    if (!_discovering) Bridge.call('discoverStart');
    _discovering = true;
    _poll();
    _timer?.cancel();
    // Reading the list is cheap (it's in memory); poll often so a beacon shows
    // up the moment it's heard.
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
    offerBluetooth(context);
  }

  bool _discovering = false;


  bool _polling = false;

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    final list = await Bridge.list('discovered').catchError((_) => <Map<String, dynamic>>[]);
    final bt = await Bridge.call<bool>('btOn') ?? true;
    _polling = false;
    if (!mounted) return;
    if (bt != _btOn) setState(() => _btOn = bt);
    list.sort((a, b) => ((b['bars'] as int?) ?? -1).compareTo((a['bars'] as int?) ?? -1));
    setState(() => _found = list);
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_discovering) Bridge.call('discoverStop');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    if (_allowed == false) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: OutlinedButton.icon(onPressed: _ask, icon: const Icon(Icons.radar_rounded), label: Text(s.lookAround)),
      );
    }
    if (_allowed == null) return const SizedBox(height: 120);
    if (!_wifiOn) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(children: [
          Breathing(child: Icon(Icons.wifi_off_rounded, size: 56, color: cs.primary)),
          const SizedBox(height: 16),
          Text(s.radarWifiOff, style: t.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => Bridge.call('wifiSettings'),
            icon: const Icon(Icons.wifi_rounded),
            label: Text(s.turnOnWifi),
          ),
        ]),
      );
    }

    return AnimatedSize(
      duration: kSoft,
      curve: kEase,
      alignment: Alignment.topCenter,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_found.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 36),
            child: Column(children: [
              Breathing(child: Icon(Icons.radar_rounded, size: 64, color: cs.primary)),
              const SizedBox(height: 16),
              Text(s.lookingAround, style: t.titleMedium, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(s.radarHint, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
            ]),
          )
        else ...[
          Text(s.nearbyTitle, style: t.titleSmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(_found.length > 1 ? s.pickSeveral : s.radarNote, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 12),
          for (final m in _found)
            FadeIn(
              key: ValueKey(m['s']),
              child: _PeerTile(
                txt: m,
                trusted: _trusted.contains(m['i']),
                picked: _picked.contains(m['s']),
                onTap: (p) {
                  if (_picked.isNotEmpty) {
                    setState(() => _picked.contains(m['s']) ? _picked.remove(m['s']) : _picked.add(m['s'] as String));
                  } else {
                    widget.onPick([(p, _trusted.contains(p.deviceId))]);
                  }
                },
                onLongPress: () => setState(() => _picked.contains(m['s']) ? _picked.remove(m['s']) : _picked.add(m['s'] as String)),
              ),
            ),
          AnimatedSize(
            duration: kSoft,
            curve: kEase,
            child: _picked.length < 2
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: FilledButton.icon(
                      icon: const Icon(Icons.north_east_rounded),
                      label: Text('${s.sendToSelected} · ${s.selectedPeers(_picked.length)}'),
                      onPressed: () {
                        final chosen = <(Pairing, bool)>[];
                        for (final m in _found) {
                          if (!_picked.contains(m['s'])) continue;
                          final p = Pairing.fromTxt(m);
                          if (p != null) chosen.add((p, _trusted.contains(p.deviceId)));
                        }
                        widget.onPick(chosen);
                      },
                    ),
                  ),
          ),
        ],
        // Bluetooth makes finding phones instant; without it we still get
        // there over Wi-Fi Direct, just slower.
        AnimatedSize(
          duration: kSoft,
          child: _btOn
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Material(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(18),
                    child: ListTile(
                      leading: Icon(Icons.bluetooth_disabled_rounded, color: cs.primary),
                      title: Text(s.btOffTitle, style: t.titleSmall),
                      subtitle: Text(s.btOffBody),
                      trailing: TextButton(
                        // They tapped "Turn on" themselves: straight to the popup.
                        onPressed: () async {
                          if (await ensurePermission(context, 'nearby')) await Bridge.call('btSettings');
                        },
                        child: Text(s.turnOn),
                      ),
                    ),
                  ),
                ),
        ),
      ]),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({
    required this.txt,
    required this.onTap,
    required this.onLongPress,
    required this.trusted,
    required this.picked,
  });

  final Map<String, dynamic> txt;
  final void Function(Pairing p) onTap;
  final VoidCallback onLongPress;
  final bool trusted, picked;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final p = Pairing.fromTxt(txt);
    if (p == null) return const SizedBox();
    final bars = (txt['bars'] as int?) ?? -1;
    final freq = (txt['freq'] as int?) ?? 0;
    final band = freq >= 5925
        ? '6 GHz'
        : freq >= 4900
            ? '5 GHz'
            : freq > 0
                ? '2.4 GHz'
                : switch (p.band) { '6' => '6 GHz', '5' => '5 GHz', '2' => '2.4 GHz', _ => '' };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: picked ? cs.primaryContainer : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onTap(p),
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              BuddyAvatar(index: p.buddy, size: 52, intro: true),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(peerName(s, p.buddy, p.nick), style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    if (trusted) Pill(s.trusted, icon: Icons.favorite_rounded),
                    if (p.wifi.isNotEmpty) Pill(s.n('Wi-Fi ${p.wifi}')),
                    if (band.isNotEmpty) Pill(s.n(band)),
                    Pill(p.security.toUpperCase()),
                    if (p.requireEncrypt) Pill(s.encrypted, icon: Icons.lock_outline_rounded),
                    if (p.compress) Pill(s.compressed, icon: Icons.compress_rounded),
                  ]),
                ]),
              ),
              if (picked)
                Icon(Icons.check_circle_rounded, color: cs.primary)
              else if (bars >= 0)
                AnimatedSwitcher(duration: kSoft, child: Icon(signalIcon(bars), key: ValueKey(bars), color: cs.primary)),
            ]),
          ),
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 12, color: cs.onSurfaceVariant), const SizedBox(width: 4)],
        Text(text, style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
      ]),
    );
  }
}

/// The phone we're sending to, with calm, slowly refreshed signal bars.
class PeerHeader extends StatefulWidget {
  const PeerHeader({super.key, required this.peer});

  final Pairing peer;

  @override
  State<PeerHeader> createState() => _PeerHeaderState();
}

class _PeerHeaderState extends State<PeerHeader> {
  Timer? _timer;
  int? _bars, _rssi;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
  }

  Future<void> _poll() async {
    final m = await Bridge.call<Map>('signal').catchError((_) => null);
    if (!mounted || m == null) return;
    setState(() {
      _bars = m['bars'] as int?;
      _rssi = m['rssi'] as int?;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final p = widget.peer;
    return Row(children: [
      BuddyAvatar(index: p.buddy, size: 44),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(peerName(s, p.buddy, p.nick), style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          if (p.wifi.isNotEmpty) Text(s.n('Wi-Fi ${p.wifi}'), style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ]),
      ),
      if (_bars != null)
        Tooltip(
          message: _rssi == null ? '' : s.n('$_rssi dBm'),
          child: AnimatedSwitcher(
            duration: kSoft,
            child: Icon(signalIcon(_bars!), key: ValueKey(_bars), color: cs.primary),
          ),
        ),
    ]);
  }
}
