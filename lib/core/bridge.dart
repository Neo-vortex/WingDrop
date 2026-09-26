import 'dart:convert';

import 'package:flutter/services.dart';

/// Thin wrapper over the Kotlin side. No file bytes ever cross this channel:
/// the native engine reads and writes fds directly.
class Bridge {
  static const _ch = MethodChannel('wingdrop/core');

  /// Handles calls coming from Android (e.g. "may this sender send?").
  static void onCall(Future<dynamic> Function(MethodCall call) handler) => _ch.setMethodCallHandler(handler);

  static Future<T?> call<T>(String method, [Map<String, dynamic>? args]) =>
      _ch.invokeMethod<T>(method, args);

  static Future<Map<String, dynamic>> caps() async =>
      Map<String, dynamic>.from(await call<Map>('caps') ?? {});

  static Future<bool> permissions(List<String> kinds) async =>
      await call<bool>('permissions', {'kinds': kinds}) ?? false;

  static bool _btOffered = false;

  /// Bluetooth makes discovery near-instant (the receiver beacons, the sender
  /// hears it within a second); without it we fall back to slow Wi-Fi Direct
  /// discovery. Show Android's one-tap "turn on Bluetooth?" popup once per
  /// app run when it's off; the radar keeps a hint card for later.
  static Future<void> offerBluetooth() async {
    if (_btOffered || await call<bool>('btOn') != false) return;
    _btOffered = true;
    await call('btSettings');
  }

  static Future<List<Map<String, dynamic>>> list(String method, [Map<String, dynamic>? args]) async {
    final r = await _ch.invokeListMethod<Map>(method, args) ?? const [];
    return r.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static Future<Uint8List?> thumb(String uri) => call<Uint8List>('thumb', {'uri': uri, 'px': 192});

  static Future<Uint8List?> appIcon(String pkg) => call<Uint8List>('appIcon', {'pkg': pkg, 'px': 128});

  /// Per-file overview of the current sessions, for the tile grid.
  static Future<List<OverviewSession>> overview({int limit = 120}) async {
    final raw = await call<String>('files', {'limit': limit});
    if (raw == null) return const [];
    return [
      for (final s in jsonDecode(raw) as List)
        OverviewSession(
          s['id'] as int,
          s['total'] as int,
          [for (final f in s['files'] as List) OverviewFile(f[0] as String, f[1] as int, f[2] as int, f[3] as int, f[4] == 1)],
        ),
    ];
  }

  static Future<Uint8List?> preview(int session, int index) =>
      call<Uint8List>('preview', {'id': session, 'index': index});

  static Future<EngineStats> stats() async {
    final raw = await call<String>('status');
    return EngineStats(raw == null ? const {} : jsonDecode(raw) as Map<String, dynamic>);
  }
}

enum EngineState { idle, listening, connecting, transferring, done, failed, cancelled }

class OverviewFile {
  const OverviewFile(this.name, this.size, this.cat, this.done, this.hasPreview);

  final String name;
  final int size, cat, done;
  final bool hasPreview;

  double get progress => size == 0 ? 1 : (done / size).clamp(0.0, 1.0);
}

class OverviewSession {
  const OverviewSession(this.id, this.total, this.files);

  final int id;
  final int total; // may exceed files.length when capped
  final List<OverviewFile> files;
}

/// One sender or receiver session inside the engine.
class SessionStats {
  SessionStats(this.j);

  final Map<String, dynamic> j;

  int get id => j['id'] as int;
  bool get sending => j['role'] == 'send';
  EngineState get state => EngineState.values[(j['state'] as int).clamp(0, EngineState.values.length - 1)];
  int get buddy => j['buddy'] as int;
  String get nick => j['nick'] as String;
  String get peer => j['peer'] as String;
  int get total => j['total'] as int;
  int get done => j['done'] as int;
  int get skipped => j['skipped'] as int;
  int get filesTotal => j['filesTotal'] as int;
  int get filesDone => j['filesDone'] as int;
  String get error => j['error'] as String;
  String get bond => j['bond'] as String;

  /// Sender: 0 reaching the receiver, 1 waiting for its answer, 2 moving data.
  int get phase => (j['phase'] as int?) ?? 0;
  double get progress => total == 0 ? 0 : done / total;
  bool get active => state == EngineState.connecting || state == EngineState.transferring;
}

class EngineStats {
  EngineStats(this.j);

  final Map<String, dynamic> j;

  int _i(String k) => (j[k] as int?) ?? 0;

  EngineState get state => EngineState.values[_i('state').clamp(0, EngineState.values.length - 1)];
  int get totalBytes => _i('total');
  int get doneBytes => _i('done');
  int get skippedBytes => _i('skipped');
  int get wireBytes => _i('wire');
  int get filesTotal => _i('filesTotal');
  int get filesDone => _i('filesDone');
  int get elapsedMs => _i('elapsedMs');
  int get streams => _i('streams');
  int get flags => _i('flags');
  String get error => (j['error'] as String?) ?? '';

  /// The file in flight right now (name, size, done, cat), if any.
  Map<String, dynamic>? get current => j['current'] as Map<String, dynamic>?;

  List<SessionStats> get sessions => [for (final s in (j['sessions'] as List? ?? const [])) SessionStats(s as Map<String, dynamic>)];

  bool get encrypted => flags & 4 != 0;
  bool get aegis => flags & 16 != 0;
  bool get compressed => flags & 3 != 0;
  double get progress => totalBytes == 0 ? 0 : doneBytes / totalBytes;

  /// Bytes that actually crossed the air (resumed chunks don't count).
  double get avgBytesPerSec => elapsedMs <= 0 ? 0 : (doneBytes - skippedBytes) * 1000 / elapsedMs;
  bool get active => state == EngineState.connecting || state == EngineState.transferring;
}
