import 'dart:convert';
import 'dart:typed_data';

import 'pack.dart';

import 'bridge.dart';

enum Preset { maxSpeed, compatibility, secure, custom }

/// Everything that shapes a transfer. The receiver uses the link settings,
/// the sender the pipeline settings.
class TransferSettings {
  Preset preset = Preset.maxSpeed;

  // Link (receiver side)
  String link = 'p2p'; // p2p | lohs | lan
  String band = 'best'; // best | auto | 2 | 5 | 6
  String security = 'best'; // best | wpa2 | wpa3
  int port = 42420;

  // Pipeline (sender side)
  bool encrypt = false;
  String compression = 'off'; // off | auto | all
  int streams = 0; // 0 = auto (one per big core, min 4)
  int chunkKb = 4096;
  int sockBufKb = 8192;
  int depth = 4;
  bool zeroCopy = true;
  int tos = 0; // 0 best effort, 0x80 video, 0xB8 voice (WMM access categories)

  // Identity
  int buddy = 0;
  String nick = '';

  // Appearance: system | light | dark
  String theme = 'system';

  // Media shrinking: ask | original | light | small
  String shrink = 'ask';

  // HEIC handling
  String heic = 'ask'; // ask | convert | keep
  int jpegQuality = 92;

  static final TransferSettings instance = TransferSettings();

  void apply(Preset p) {
    preset = p;
    switch (p) {
      case Preset.maxSpeed:
        link = 'p2p';
        band = 'best';
        security = 'best';
        encrypt = false;
        compression = 'off';
        streams = 0;
        chunkKb = 4096;
        sockBufKb = 8192;
        depth = 4;
        zeroCopy = true;
        tos = 0;
      case Preset.compatibility:
        link = 'p2p';
        band = '2';
        security = 'wpa2';
        encrypt = false;
        compression = 'off';
        streams = 2;
        chunkKb = 1024;
        sockBufKb = 2048;
        depth = 2;
        zeroCopy = true;
        tos = 0;
      case Preset.secure:
        link = 'p2p';
        band = 'best';
        security = 'best';
        encrypt = true;
        compression = 'auto';
        streams = 0;
        chunkKb = 4096;
        sockBufKb = 8192;
        depth = 4;
        zeroCopy = true;
        tos = 0;
      case Preset.custom:
        break;
    }
  }

  /// Resolves "best" against what this phone can do. That's 5 GHz: nearly
  /// every phone can join it and it is fast. 6 GHz is left to an explicit
  /// choice, because many phones can't see a 6 GHz Wi-Fi Direct group at all.
  String resolveBand(Map<String, dynamic> caps) {
    if (band != 'best') return band;
    return caps['band5'] == true ? '5' : 'auto';
  }

  String resolveSecurity(Map<String, dynamic> caps) {
    if (security != 'best') return security;
    return caps['p2pR2'] == true ? 'wpa3' : 'wpa2';
  }

  /// [flags, streams, chunkSize, sockBuf, tos, depth] for the native engine.
  List<int> engineOptions() {
    var flags = 0;
    if (compression == 'auto') flags |= 1;
    if (compression == 'all') flags |= 2;
    if (encrypt) flags |= 4;
    if (zeroCopy) flags |= 8;
    return [flags, streams, chunkKb * 1024, sockBufKb * 1024, tos, depth];
  }

  Map<String, dynamic> toJson() => {
        'preset': preset.name,
        'link': link,
        'band': band,
        'security': security,
        'port': port,
        'encrypt': encrypt,
        'compression': compression,
        'streams': streams,
        'chunkKb': chunkKb,
        'sockBufKb': sockBufKb,
        'depth': depth,
        'zeroCopy': zeroCopy,
        'tos': tos,
        'heic': heic,
        'shrink': shrink,
        'theme': theme,
        'buddy': buddy,
        'nick': nick,
        'jpegQuality': jpegQuality,
      };

  void fromJson(Map<String, dynamic> j) {
    preset = Preset.values.firstWhere((p) => p.name == j['preset'], orElse: () => Preset.maxSpeed);
    link = j['link'] ?? link;
    band = j['band'] ?? band;
    security = j['security'] ?? security;
    port = j['port'] ?? port;
    encrypt = j['encrypt'] ?? encrypt;
    compression = j['compression'] ?? compression;
    streams = j['streams'] ?? streams;
    chunkKb = j['chunkKb'] ?? chunkKb;
    sockBufKb = j['sockBufKb'] ?? sockBufKb;
    depth = j['depth'] ?? depth;
    zeroCopy = j['zeroCopy'] ?? zeroCopy;
    tos = j['tos'] ?? tos;
    heic = j['heic'] ?? heic;
    shrink = j['shrink'] ?? shrink;
    theme = j['theme'] ?? theme;
    buddy = j['buddy'] ?? buddy;
    nick = j['nick'] ?? nick;
    jpegQuality = j['jpegQuality'] ?? jpegQuality;
  }

  Future<void> load() async {
    final s = await Bridge.call<String>('prefsGet', {'key': 'settings'});
    if (s != null) fromJson(jsonDecode(s) as Map<String, dynamic>);
  }

  Future<void> save() => Bridge.call('prefsSet', {'key': 'settings', 'value': jsonEncode(toJson())});
}

/// What the receiver's QR code carries.
class Pairing {
  Pairing({
    required this.mode,
    required this.hosts,
    required this.port,
    required this.key,
    this.ssid = '',
    this.pass = '',
    this.band = 'auto',
    this.security = 'wpa2',
    this.buddy = 0,
    this.nick = '',
    this.wifi = '',
    this.requireEncrypt = false,
    this.compress = false,
    this.deviceId = '',
    this.freq = 0,
  });

  final String mode;
  final List<String> hosts;
  final int port;
  final List<int> key;
  final String ssid, pass, band, security;
  final int buddy;
  final String nick, wifi;

  /// The receiver insists on these; the sender adds them to its own choice.
  final bool requireEncrypt, compress;

  /// The receiver's stable device id (for trusted buddies and resuming).
  final String deviceId;

  /// The Wi-Fi Direct group's channel in MHz, so the sender joins without scanning.
  final int freq;

  static const _prefix = 'WD1:';
  static const _modes = ['p2p', 'lohs', 'lan'];

  /// Compact QR payload: MessagePack with small integer keys, written in
  /// Base45 so the QR uses alphanumeric mode (about 3x fewer modules than
  /// JSON in byte mode). Things the sender can work out itself are left out:
  /// the Wi-Fi Direct passphrase derives from the group name, the group
  /// owner's address is always 192.168.49.1, and 42420 is the default port.
  String encode() {
    final m = <int, Object>{
      1: _modes.indexOf(mode),
      2: ssid,
      6: Uint8List.fromList(key),
      7: buddy,
      10: (requireEncrypt ? 1 : 0) | (compress ? 2 : 0) | (security == 'wpa3' ? 4 : 0),
    };
    if (mode != 'p2p' && pass.isNotEmpty) m[3] = pass;
    if (mode != 'p2p') m[4] = hosts.take(3).toList();
    if (port != 42420) m[5] = port;
    if (nick.isNotEmpty) m[8] = nick;
    if (wifi.isNotEmpty) m[9] = wifi;
    if (deviceId.length == 16) m[11] = _hex(deviceId);
    if (freq > 0) m[12] = freq;
    if (mode == 'lohs' && security == 'wpa3t') m[13] = 1;
    return _prefix + Base45.encode(MsgPack.encode(m));
  }

  static Uint8List _hex(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

  static String _unhex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Pairing? _decodePacked(String raw) {
    try {
      final m = MsgPack.decode(Base45.decode(raw.substring(_prefix.length))) as Map;
      final mode = _modes[m[1] as int];
      final f = (m[10] as int?) ?? 0;
      return Pairing(
        mode: mode,
        hosts: mode == 'p2p' ? const ['192.168.49.1'] : ((m[4] as List?)?.cast<String>() ?? const []),
        port: (m[5] as int?) ?? 42420,
        key: (m[6] as Uint8List).toList(),
        ssid: m[2] as String,
        pass: (m[3] as String?) ?? '',
        security: f & 4 != 0 ? 'wpa3' : (m[13] == 1 ? 'wpa3t' : 'wpa2'),
        buddy: (m[7] as int?) ?? 0,
        nick: (m[8] as String?) ?? '',
        wifi: (m[9] as String?) ?? '',
        requireEncrypt: f & 1 != 0,
        compress: f & 2 != 0,
        deviceId: m[11] is Uint8List ? _unhex(m[11] as Uint8List) : '',
        freq: (m[12] as int?) ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Arguments for Kotlin's WifiLink.join.
  Map<String, dynamic> toJoinArgs() => {
        'm': mode,
        's': ssid,
        'p': pass,
        'sec': security,
        'fq': freq,
      };

  /// From a receiver's Wi-Fi Direct service record (tap-to-send).
  static Pairing? fromTxt(Map<String, dynamic> t) {
    try {
      final f = int.tryParse('${t['f']}') ?? 0;
      return Pairing(
        mode: 'p2p',
        hosts: const ['192.168.49.1'],
        port: int.parse('${t['o']}'),
        key: base64Decode('${t['k']}'),
        ssid: '${t['s']}',
        pass: '${t['p']}',
        band: '${t['b'] ?? 'auto'}',
        security: '${t['sec'] ?? 'wpa2'}',
        buddy: int.tryParse('${t['a']}') ?? 0,
        nick: '${t['n'] ?? ''}',
        wifi: '${t['w'] ?? ''}',
        requireEncrypt: f & 1 != 0,
        compress: f & 2 != 0,
        deviceId: '${t['i'] ?? ''}',
        freq: int.tryParse('${t['fq'] ?? ''}') ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  static Pairing? decode(String raw) {
    if (raw.startsWith(_prefix)) return _decodePacked(raw);
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['v'] != 1) return null;
      return Pairing(
        mode: j['m'],
        hosts: (j['h'] as List).cast<String>(),
        port: j['o'],
        key: base64Decode(j['k']),
        ssid: j['s'] ?? '',
        pass: j['p'] ?? '',
        band: j['b'] ?? 'auto',
        security: j['sec'] ?? 'wpa2',
        buddy: j['a'] ?? 0,
        nick: j['n'] ?? '',
        wifi: j['w'] ?? '',
        requireEncrypt: ((j['f'] ?? 0) as int) & 1 != 0,
        compress: ((j['f'] ?? 0) as int) & 2 != 0,
        deviceId: j['i'] ?? '',
        freq: j['fq'] ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// One file to send.
class SendItem {
  SendItem({
    required this.id,
    required this.name,
    required this.size,
    required this.cat,
    this.uri,
    this.path,
    this.rel = '',
    this.mime = '',
    this.heic = false,
  });

  final String id;
  String name;
  final int size;
  final int cat; // 0 file, 1 photo, 2 video, 3 music, 4 app
  String? uri;
  String? path;
  final String rel;
  final String mime;
  bool heic;

  /// Photos, videos and music can be shrunk; other files and apps never are.
  bool get isMedia => cat != 4 && (mime.startsWith('image/') || mime.startsWith('video/') || mime.startsWith('audio/'));

  Map<String, dynamic> toArgs() => {'uri': uri, 'path': path, 'name': name, 'rel': rel, 'cat': cat, 'mime': mime};
}
