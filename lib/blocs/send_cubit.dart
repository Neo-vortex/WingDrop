import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/bridge.dart';
import '../core/settings.dart';

enum SendStep { askShrink, shrinking, askHeic, converting, scanning, wifiOff, joining, transferring, finished, error }

enum SendError {
  none,
  notOurCode,
  needNearby,
  needCamera,
  cameraFailed,
  declined,
  vpn,
  joinFailed,
  unreachable,
  refused,
  peerOutdated,
  selfOutdated,
  noAnswer,
  other,
}

enum TargetState { waiting, joining, sending, done, failed, declined }

/// One phone we are sending to.
class Target {
  Target(this.pairing, {this.trusted = false});

  final Pairing pairing;
  final bool trusted;
  TargetState state = TargetState.waiting;
  int? session;
  String error = '';
  int retries = 0;
}

class SendState {
  const SendState({
    required this.step,
    required this.items,
    this.heicCount = 0,
    this.mediaCount = 0,
    this.convertProgress = 0,
    this.error = SendError.none,
    this.message = '',
    this.targets = const [],
    this.revision = 0,
    this.stage = '',
    this.stageSince,
  });

  final SendStep step;
  final List<SendItem> items;
  final int heicCount;
  final int mediaCount;
  final double convertProgress;
  final SendError error;
  final String message;
  final List<Target> targets;
  final int revision; // bumps when a target changes state

  /// What the connection is doing right now: joining, fallback,
  /// system_prompt, reaching, approval. Shown as a calm line of text.
  final String stage;
  final DateTime? stageSince;

  /// The single phone we're sending to (for the header), if just one.
  Pairing? get peer => targets.length == 1 ? targets.first.pairing : null;

  SendState copyWith({
    SendStep? step,
    List<SendItem>? items,
    int? heicCount,
    double? convertProgress,
    SendError? error,
    String? message,
    List<Target>? targets,
    bool bump = false,
    String? stage,
  }) =>
      SendState(
        step: step ?? this.step,
        items: items ?? this.items,
        heicCount: heicCount ?? this.heicCount,
        mediaCount: mediaCount,
        convertProgress: convertProgress ?? this.convertProgress,
        error: error ?? this.error,
        message: message ?? this.message,
        targets: targets ?? this.targets,
        revision: bump ? revision + 1 : revision,
        stage: stage ?? this.stage,
        stageSince: stage != null && stage != this.stage ? DateTime.now() : stageSince,
      );
}

/// Linear send flow: (shrink?) -> (HEIC?) -> pick phones -> join -> transfer.
///
/// Several phones: the ones on the same network get their sessions at once;
/// Wi-Fi Direct receivers each host their own group and a phone can be a
/// client of only one group, so those take turns automatically.
/// A dropped transfer retries once by itself and resumes where it stopped.
class SendCubit extends Cubit<SendState> {
  SendCubit(List<SendItem> items, this.settings)
      : super(SendState(
          step: SendStep.scanning,
          items: items,
          heicCount: items.where((i) => i.heic).length,
          mediaCount: items.where((i) => i.isMedia).length,
        ));

  final TransferSettings settings;
  bool _joined = false;
  bool _running = false;
  Timer? _wifiWatch;

  // ---------------------------------------------------------------- media prep

  Future<void> begin() async {
    if (state.mediaCount > 0) {
      if (settings.shrink == 'ask') {
        emit(state.copyWith(step: SendStep.askShrink));
        return;
      }
      if (settings.shrink == 'light' || settings.shrink == 'small') await _shrink(settings.shrink == 'light' ? 0 : 1);
    }
    await _afterShrink();
  }

  /// preset: null = send as is, 0 = a bit lighter, 1 = much lighter.
  Future<void> shrinkChoice(int? preset) async {
    if (preset != null) await _shrink(preset);
    await _afterShrink();
  }

  Future<void> _shrink(int preset) async {
    emit(state.copyWith(step: SendStep.shrinking, convertProgress: 0));
    final media = state.items.where((i) => i.isMedia).toList();
    final timer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final p = await Bridge.call<double>('shrinkProgress');
      if (!isClosed && p != null) emit(state.copyWith(convertProgress: p));
    });
    try {
      final out = await Bridge.call<List>('shrink', {
        'items': [for (final m in media) {'uri': m.uri, 'path': m.path, 'name': m.name, 'mime': m.mime}],
        'preset': preset,
      });
      final items = List.of(state.items);
      for (var i = 0; i < media.length; i++) {
        final r = out?[i] as Map?;
        if (r == null) continue; // not worth it or unsupported: send the original
        final old = media[i];
        items[items.indexOf(old)] = SendItem(
          id: old.id,
          path: r['path'] as String,
          name: r['name'] as String,
          size: r['size'] as int,
          cat: old.cat,
          rel: old.rel,
          mime: old.mime,
        );
      }
      if (!isClosed) emit(state.copyWith(items: items, heicCount: items.where((i) => i.heic).length, convertProgress: 1));
    } finally {
      timer.cancel();
    }
  }

  Future<void> _afterShrink() async {
    if (state.heicCount > 0) {
      if (settings.heic == 'ask') {
        emit(state.copyWith(step: SendStep.askHeic));
        return;
      }
      if (settings.heic == 'convert') await _convert();
    }
    emit(state.copyWith(step: SendStep.scanning));
  }

  Future<void> heicChoice(bool convert) async {
    if (convert) await _convert();
    emit(state.copyWith(step: SendStep.scanning));
  }

  Future<void> _convert() async {
    emit(state.copyWith(step: SendStep.converting, convertProgress: 0));
    final heics = state.items.where((i) => i.heic).toList();
    final timer = Timer.periodic(const Duration(milliseconds: 400), (_) async {
      final p = await Bridge.call<List>('heicProgress');
      if (!isClosed && p != null && p[1] > 0) emit(state.copyWith(convertProgress: p[0] / p[1]));
    });
    try {
      final paths = await Bridge.call<List>('heicConvert', {
        'uris': heics.map((e) => e.uri).toList(),
        'quality': settings.jpegQuality,
      });
      final items = List.of(state.items);
      for (var i = 0; i < heics.length; i++) {
        final r = paths?[i] as Map?;
        if (r == null) continue; // conversion failed: send the original
        final old = heics[i];
        items[items.indexOf(old)] = SendItem(
          id: old.id,
          path: r['path'] as String,
          name: '${old.name.replaceAll(RegExp(r'\.(heic|heif)$', caseSensitive: false), '')}.jpg',
          size: r['size'] as int,
          cat: old.cat,
          rel: old.rel,
          mime: 'image/jpeg',
        );
      }
      if (!isClosed) emit(state.copyWith(items: items, convertProgress: 1));
    } finally {
      timer.cancel();
    }
  }

  // ---------------------------------------------------------------- connect & send

  void cameraDenied() => emit(state.copyWith(step: SendStep.error, error: SendError.needCamera));

  void cameraFailed(String why) {
    Bridge.call('diagNote', {'text': 'scanner failed: $why'});
    emit(state.copyWith(step: SendStep.error, error: SendError.cameraFailed, message: why));
  }

  /// From a scanned QR code.
  Future<void> connect(String? raw, Future<bool> Function() nearbyGranted) async {
    if (raw == null) return;
    final pairing = Pairing.decode(raw);
    if (pairing == null) {
      emit(state.copyWith(step: SendStep.error, error: SendError.notOurCode));
      return;
    }
    await sendTo([Target(pairing)], nearbyGranted);
  }

  Future<void> connectTo(Pairing p, Future<bool> Function() nearbyGranted, {bool trusted = false}) =>
      sendTo([Target(p, trusted: trusted)], nearbyGranted);

  /// Sends to every target; same-network ones in parallel, Wi-Fi Direct ones in turn.
  Future<void> sendTo(List<Target> targets, Future<bool> Function() nearbyGranted) async {
    final needsWifi = targets.any((t) => t.pairing.mode != 'lan');
    if (needsWifi && !await nearbyGranted()) {
      emit(state.copyWith(step: SendStep.error, error: SendError.needNearby));
      return;
    }
    // Wi-Fi Direct needs Wi-Fi on, and apps can't flip it themselves: ask
    // kindly, then carry on by ourselves the moment it's on.
    if (needsWifi && await Bridge.call<bool>('wifiOn') == false) {
      emit(state.copyWith(step: SendStep.wifiOff, targets: targets));
      _wifiWatch?.cancel();
      _wifiWatch = Timer.periodic(const Duration(seconds: 1), (timer) async {
        if (isClosed) return timer.cancel();
        if (await Bridge.call<bool>('wifiOn') == true) {
          timer.cancel();
          // Give the Wi-Fi stack a moment to settle before joining.
          await Future.delayed(const Duration(milliseconds: 1500));
          if (!isClosed) await sendTo(targets, nearbyGranted);
        }
      });
      return;
    }
    Bridge.call('diagNote', {'text': 'sending to ${targets.map((t) => '${t.pairing.ssid} (${t.pairing.mode})').join(', ')}'});
    emit(state.copyWith(step: SendStep.joining, error: SendError.none, targets: targets, stage: 'joining'));
    await _run();
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    try {
      final pending = state.targets.where((t) => t.state == TargetState.waiting || t.state == TargetState.failed).toList();
      final lan = pending.where((t) => t.pairing.mode == 'lan').toList();
      final direct = pending.where((t) => t.pairing.mode != 'lan').toList();
      // Same network: everyone at once.
      await Future.wait(lan.map((t) => _sendOne(t, join: false)));
      // Wi-Fi Direct / hotspot: one group at a time.
      for (final t in direct) {
        if (isClosed) return;
        await _sendOne(t, join: true);
      }
      if (isClosed) return;
      // An explanation screen (or a cancel) already took over: leave it be.
      if (state.step == SendStep.error || state.step == SendStep.scanning || state.step == SendStep.wifiOff) return;
      final ok = state.targets.every((t) => t.state == TargetState.done);
      final declined = state.targets.every((t) => t.state == TargetState.declined);
      if (declined) {
        emit(state.copyWith(step: SendStep.error, error: SendError.declined, bump: true));
      } else {
        emit(state.copyWith(step: ok ? SendStep.finished : SendStep.transferring, bump: true));
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _sendOne(Target t, {required bool join}) async {
    _set(t, TargetState.joining);
    _stage(join ? 'joining' : 'reaching');
    Timer? poll;
    var started = false;
    try {
      var hosts = t.pairing.hosts;
      var netHandle = 0;
      if (join) {
        // Mirror the platform's join stages (Wi-Fi Direct, fallback, system popup).
        poll = Timer.periodic(const Duration(milliseconds: 400), (_) async {
          final st = await Bridge.call<String>('stage');
          if (st != null && st.isNotEmpty && !isClosed && state.step == SendStep.joining) _stage(st);
        });
        final r = Map<String, dynamic>.from(await Bridge.call<Map>('join', {'qr': t.pairing.toJoinArgs()}) ?? {});
        poll.cancel();
        _joined = true;
        hosts = {...((r['hosts'] as List?)?.cast<String>() ?? const <String>[]), ...hosts}.toList();
        netHandle = (r['netHandle'] as int?) ?? 0;
      }
      _stage('reaching');
      final id = await Bridge.call<int>('send', {
        'hosts': hosts,
        'port': t.pairing.port,
        'key': t.pairing.key,
        'netHandle': netHandle,
        'items': state.items.map((e) => e.toArgs()).toList(),
        'opts': [..._options(t.pairing), settings.buddy],
        'nick': settings.nick,
        'peerId': t.pairing.deviceId,
        'useBond': t.trusted,
      });
      t.session = id;
      _set(t, TargetState.sending);
      final result = await _await(id!, (x) {
        if (x.phase == 1) _stage('approval');
        if (x.phase == 2 && !started) {
          started = true;
          if (state.step != SendStep.transferring) emit(state.copyWith(step: SendStep.transferring));
        }
      });
      final code = result.error;
      if (result.state == EngineState.done) {
        _set(t, TargetState.done);
        // They trust us now (QR pairing or "remember them"): keep the bond.
        if (result.bond.isNotEmpty && result.peer.isNotEmpty) {
          await Bridge.call('saveBond', {'id': result.peer, 'key': result.bond, 'buddy': t.pairing.buddy, 'nick': t.pairing.nick});
        }
      } else if (code == 'declined') {
        _set(t, TargetState.declined);
      } else if (result.state == EngineState.cancelled || code == 'cancelled') {
        _set(t, TargetState.failed, error: 'cancelled');
      } else if (_retryable(code) && t.retries < 1) {
        // One calm automatic retry; the receiver keeps what it has, so this resumes.
        t.retries++;
        Bridge.call('diagNote', {'text': 'retrying after: $code'});
        _set(t, TargetState.failed, error: code);
        await Future.delayed(const Duration(seconds: 3));
        if (!isClosed) await _sendOne(t, join: join);
        return;
      } else {
        await _fail(t, code, beforeData: !started || result.done == result.skipped);
      }
    } catch (e) {
      await _fail(t, _clean(e), beforeData: !started);
    } finally {
      poll?.cancel();
      if (join && _joined) {
        await Bridge.call('leave');
        _joined = false;
      }
    }
  }

  /// Failures before any data moved get a clear explanation screen (for a
  /// single phone); mid-transfer ones show "Pick up where we left off".
  Future<void> _fail(Target t, String code, {required bool beforeData}) async {
    Bridge.call('diagNote', {'text': 'send failed: $code'});
    _set(t, TargetState.failed, error: code);
    if (isClosed) return;
    if (code == 'wifi_off') {
      emit(state.copyWith(step: SendStep.wifiOff));
      return;
    }
    if (state.targets.length != 1 || !beforeData) return;
    var err = _errorFor(code);
    if (err == SendError.unreachable && await Bridge.call<bool>('vpn') == true) err = SendError.vpn;
    if (!isClosed) emit(state.copyWith(step: SendStep.error, error: err, message: code));
  }

  static bool _retryable(String code) => !const {
        'refused', 'peer_outdated', 'self_outdated', 'declined', 'handshake', 'bad_code', 'cancelled', 'wifi_off',
      }.contains(code);

  static SendError _errorFor(String code) {
    if (code.startsWith('join_')) return SendError.joinFailed;
    return switch (code) {
      'unreachable' => SendError.unreachable,
      'refused' => SendError.refused,
      'peer_outdated' => SendError.peerOutdated,
      'self_outdated' => SendError.selfOutdated,
      'no_answer' => SendError.noAnswer,
      'bad_code' => SendError.notOurCode,
      _ => SendError.other,
    };
  }

  void _stage(String s) {
    if (!isClosed && s != state.stage) emit(state.copyWith(stage: s));
  }

  /// Try the same phone(s) again from the start (join included).
  Future<void> retryConnect() async {
    for (final t in state.targets) {
      if (t.state != TargetState.done) {
        t.state = TargetState.waiting;
        t.retries = 0;
      }
    }
    emit(state.copyWith(step: SendStep.joining, error: SendError.none, stage: 'joining', bump: true));
    await _run();
  }

  /// Back to the radar / QR screen to choose again.
  void backToPicking() => emit(state.copyWith(step: SendStep.scanning, error: SendError.none, stage: '', targets: const []));

  /// Stop trying to connect and go back to picking a phone.
  Future<void> cancelConnect() async {
    await Bridge.call('cancel', {'id': 0});
    if (_joined) {
      await Bridge.call('leave');
      _joined = false;
    }
    for (final t in state.targets) {
      t.state = TargetState.failed;
      t.error = 'cancelled';
    }
    emit(state.copyWith(step: SendStep.scanning, stage: '', bump: true));
  }

  /// Waits for one session to finish, polling calmly.
  Future<SessionStats> _await(int id, [void Function(SessionStats s)? onUpdate]) async {
    SessionStats? last;
    while (!isClosed) {
      await Future.delayed(const Duration(milliseconds: 400));
      final s = await Bridge.stats();
      for (final x in s.sessions) {
        if (x.id == id) last = x;
      }
      if (last != null) onUpdate?.call(last);
      if (last != null && !last.active) return last;
      // The group was reset under us (new batch); treat as finished with what we saw.
      if (last == null && s.sessions.isEmpty && s.state != EngineState.connecting) break;
    }
    return last ?? SessionStats(const {'id': 0, 'role': 'send', 'state': 5, 'buddy': 0, 'nick': '', 'peer': '', 'total': 0,
      'done': 0, 'skipped': 0, 'filesTotal': 0, 'filesDone': 0, 'error': 'lost', 'bond': ''});
  }

  /// "Pick up where we left off": retries every target that didn't finish.
  Future<void> retry() async {
    for (final t in state.targets) {
      if (t.state == TargetState.failed) {
        t.state = TargetState.waiting;
        t.retries = 0;
      }
    }
    emit(state.copyWith(step: SendStep.transferring, bump: true));
    await _run();
  }

  void _set(Target t, TargetState s, {String error = ''}) {
    t.state = s;
    t.error = error;
    if (!isClosed) emit(state.copyWith(bump: true));
  }

  /// Our settings, plus whatever the receiver insists on.
  List<int> _options(Pairing p) {
    final o = settings.engineOptions();
    if (p.requireEncrypt) o[0] |= 4;
    if (p.compress && o[0] & 3 == 0) o[0] |= 1;
    return o;
  }

  void finished() {
    if (state.targets.every((t) => t.state == TargetState.done)) emit(state.copyWith(step: SendStep.finished));
  }

  Future<void> cancel() => Bridge.call('cancel', {'id': 0});

  static String _clean(Object e) {
    final s = '$e';
    final m = RegExp(r'PlatformException\([^,]*, ([^,]*)').firstMatch(s);
    return m?.group(1) ?? s;
  }

  @override
  Future<void> close() {
    _wifiWatch?.cancel();
    if (state.step == SendStep.shrinking) Bridge.call('shrinkCancel');
    if (_joined) Bridge.call('leave');
    return super.close();
  }
}
