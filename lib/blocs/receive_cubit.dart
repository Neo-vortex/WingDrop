import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/bridge.dart';
import '../core/settings.dart';
import '../core/ssid.dart';

class ReceivedItem {
  ReceivedItem(Map<String, dynamic> m)
      : name = m['name'],
        rel = m['rel'],
        cat = m['cat'],
        size = m['size'],
        mime = m['mime'],
        uri = m['uri'],
        done = m['done'],
        batch = m['batch'],
        index = (m['index'] as int?) ?? 0;

  final String name, rel, mime, uri;
  final int cat, size, batch, index;
  final bool done;
}

enum ReceivePhase { starting, ready, error }

class ReceiveState {
  const ReceiveState({
    this.phase = ReceivePhase.starting,
    this.pairing,
    this.freq = 0,
    this.error = '',
    this.wifiOff = false,
    this.received = const [],
    this.active = false,
    this.beacon = true,
    this.progress = const {},
  });

  final ReceivePhase phase;
  final Pairing? pairing;
  final int freq;
  final String error;
  final bool wifiOff;
  final List<ReceivedItem> received;

  /// A transfer is (or was just) running: show the transfer view.
  final bool active;

  /// Whether we're beaconing over Bluetooth (instant discovery for senders).
  final bool beacon;

  /// Live per-file progress from the engine, keyed "session:index".
  final Map<String, OverviewFile> progress;

  ReceiveState copyWith({
    ReceivePhase? phase,
    Pairing? pairing,
    int? freq,
    String? error,
    bool? wifiOff,
    List<ReceivedItem>? received,
    bool? active,
    bool? beacon,
    Map<String, OverviewFile>? progress,
  }) =>
      ReceiveState(
        phase: phase ?? this.phase,
        pairing: pairing ?? this.pairing,
        freq: freq ?? this.freq,
        error: error ?? this.error,
        wifiOff: wifiOff ?? this.wifiOff,
        received: received ?? this.received,
        active: active ?? this.active,
        beacon: beacon ?? this.beacon,
        progress: progress ?? this.progress,
      );
}

class ReceiveCubit extends Cubit<ReceiveState> {
  ReceiveCubit(this.settings) : super(const ReceiveState());

  final TransferSettings settings;
  Timer? _timer;

  Future<void> start() async {
    emit(state.copyWith(phase: ReceivePhase.starting));
    try {
      final caps = await Bridge.caps();
      if (settings.link != 'lan' && caps['wifiOn'] == false) {
        emit(state.copyWith(phase: ReceivePhase.error, wifiOff: true));
        return;
      }
      final deviceId = await Bridge.call<String>('deviceId') ?? '';
      final band = settings.resolveBand(caps);
      final security = settings.resolveSecurity(caps);
      final wifi = DeviceTag.wifiFromCaps(caps);
      final tag = DeviceTag(
        buddy: settings.buddy,
        wifi: wifi,
        encrypt: settings.encrypt,
        compress: settings.compression != 'off',
        wpa3: security == 'wpa3',
        nick: settings.nick,
      );
      final r = Map<String, dynamic>.from(await Bridge.call<Map>('host', {
            'mode': settings.link,
            'band': band,
            'security': security,
            'port': settings.port,
            'tag': tag.encode(),
            'txt': {
              'a': '${settings.buddy}',
              'n': settings.nick,
              'w': wifi,
              'f': '${(settings.encrypt ? 1 : 0) | (settings.compression != 'off' ? 2 : 0)}',
              'i': deviceId,
            },
          }) ??
          {});
      final pairing = Pairing(
        mode: r['mode'],
        hosts: (r['hosts'] as List).cast<String>(),
        port: r['port'],
        key: (r['key'] as List).cast<int>(),
        ssid: r['ssid'] ?? '',
        pass: r['pass'] ?? '',
        band: band,
        security: r['security'] ?? 'wpa2',
        buddy: settings.buddy,
        nick: settings.nick,
        wifi: wifi,
        requireEncrypt: settings.encrypt,
        compress: settings.compression != 'off',
        deviceId: deviceId,
        freq: (r['freq'] as int?) ?? 0,
      );
      emit(state.copyWith(
        phase: ReceivePhase.ready,
        pairing: pairing,
        freq: r['freq'] ?? 0,
        wifiOff: false,
        beacon: r['ble'] != false || settings.link != 'p2p',
      ));
      _timer = Timer.periodic(const Duration(milliseconds: 400), (_) => _poll());
    } catch (e) {
      final s = '$e';
      final m = RegExp(r'PlatformException\([^,]*, ([^,]*)').firstMatch(s);
      emit(state.copyWith(phase: ReceivePhase.error, error: m?.group(1) ?? s));
    }
  }

  // Incoming sessions we've already shown (or the person dismissed).
  final Set<int> _seen = {};

  Future<void> _poll() async {
    final list = await Bridge.list('received');
    final stats = await Bridge.stats();
    final overview = await Bridge.overview(limit: 400);
    if (isClosed) return;
    final progress = <String, OverviewFile>{
      for (final x in overview)
        for (var i = 0; i < x.files.length; i++) '${x.id}:$i': x.files[i],
    };
    // A small file can arrive entirely between two polls: any session we
    // haven't shown yet, even a finished one, switches to the transfer view.
    final fresh = stats.sessions.where((x) => !x.sending && !_seen.contains(x.id)).toList();
    _seen.addAll(fresh.map((x) => x.id));
    final active = fresh.isNotEmpty ||
        stats.state == EngineState.connecting ||
        stats.state == EngineState.transferring ||
        (state.active && stats.totalBytes > 0);
    emit(state.copyWith(received: list.map(ReceivedItem.new).toList(), active: active, progress: progress));
  }

  /// Back to showing the code after a finished batch.
  void dismissTransfer() => emit(state.copyWith(active: false));

  Future<void> cancel() => Bridge.call('cancel');

  @override
  Future<void> close() {
    _timer?.cancel();
    Bridge.call('stopHost');
    return super.close();
  }
}
