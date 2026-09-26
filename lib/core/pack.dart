import 'dart:convert';
import 'dart:typed_data';

/// Minimal MessagePack (the subset WingDrop needs: nil, bool, ints, strings,
/// binary, arrays and maps) plus Base45 (RFC 9285) so packed bytes fit the
/// QR code's compact alphanumeric mode.
class MsgPack {
  static Uint8List encode(Object? v) {
    final b = BytesBuilder(copy: false);
    _enc(b, v);
    return b.toBytes();
  }

  static void _enc(BytesBuilder b, Object? v) {
    if (v == null) {
      b.addByte(0xc0);
    } else if (v is bool) {
      b.addByte(v ? 0xc3 : 0xc2);
    } else if (v is int) {
      _int(b, v);
    } else if (v is String) {
      final s = utf8.encode(v);
      if (s.length < 32) {
        b.addByte(0xa0 | s.length);
      } else if (s.length < 256) {
        b..addByte(0xd9)..addByte(s.length);
      } else {
        b..addByte(0xda)..add(_u16(s.length));
      }
      b.add(s);
    } else if (v is Uint8List) {
      if (v.length < 256) {
        b..addByte(0xc4)..addByte(v.length);
      } else {
        b..addByte(0xc5)..add(_u16(v.length));
      }
      b.add(v);
    } else if (v is List) {
      if (v.length < 16) {
        b.addByte(0x90 | v.length);
      } else {
        b..addByte(0xdc)..add(_u16(v.length));
      }
      for (final x in v) {
        _enc(b, x);
      }
    } else if (v is Map) {
      if (v.length < 16) {
        b.addByte(0x80 | v.length);
      } else {
        b..addByte(0xde)..add(_u16(v.length));
      }
      v.forEach((k, x) {
        _enc(b, k);
        _enc(b, x);
      });
    } else {
      throw ArgumentError('cannot pack ${v.runtimeType}');
    }
  }

  static void _int(BytesBuilder b, int v) {
    if (v >= 0 && v < 128) {
      b.addByte(v);
    } else if (v < 0 && v >= -32) {
      b.addByte(v & 0xff);
    } else if (v >= 0 && v < 256) {
      b..addByte(0xcc)..addByte(v);
    } else if (v >= 0 && v < 65536) {
      b..addByte(0xcd)..add(_u16(v));
    } else if (v >= 0 && v < 4294967296) {
      b.addByte(0xce);
      b.add([v >> 24 & 0xff, v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff]);
    } else {
      final d = ByteData(8)..setInt64(0, v);
      b..addByte(0xd3)..add(d.buffer.asUint8List());
    }
  }

  static List<int> _u16(int v) => [v >> 8 & 0xff, v & 0xff];

  static Object? decode(Uint8List data) {
    final r = _Reader(data);
    final v = r.read();
    return v;
  }
}

class _Reader {
  _Reader(this.d);

  final Uint8List d;
  int p = 0;

  int _u8() => d[p++];
  int _u16() => (_u8() << 8) | _u8();
  int _u32() => (_u16() << 16) | _u16();

  Uint8List _bytes(int n) {
    final out = Uint8List.sublistView(d, p, p + n);
    p += n;
    return Uint8List.fromList(out);
  }

  Object? read() {
    final t = _u8();
    if (t < 0x80) return t;
    if (t >= 0xe0) return t - 0x100;
    if (t & 0xe0 == 0xa0) return utf8.decode(_bytes(t & 0x1f));
    if (t & 0xf0 == 0x90) return [for (var i = 0; i < (t & 0x0f); i++) read()];
    if (t & 0xf0 == 0x80) return _map(t & 0x0f);
    switch (t) {
      case 0xc0:
        return null;
      case 0xc2:
        return false;
      case 0xc3:
        return true;
      case 0xcc:
        return _u8();
      case 0xcd:
        return _u16();
      case 0xce:
        return _u32();
      case 0xd3:
        final v = ByteData.sublistView(d, p, p + 8).getInt64(0);
        p += 8;
        return v;
      case 0xd9:
        return utf8.decode(_bytes(_u8()));
      case 0xda:
        return utf8.decode(_bytes(_u16()));
      case 0xc4:
        return _bytes(_u8());
      case 0xc5:
        return _bytes(_u16());
      case 0xdc:
        final n = _u16();
        return [for (var i = 0; i < n; i++) read()];
      case 0xde:
        return _map(_u16());
    }
    throw FormatException('msgpack type 0x${t.toRadixString(16)}');
  }

  Map<Object?, Object?> _map(int n) => {for (var i = 0; i < n; i++) read(): read()};
}

/// Base45 (RFC 9285): 2 bytes -> 3 characters from the QR alphanumeric set.
class Base45 {
  static const _alphabet = r'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

  static String encode(Uint8List data) {
    final out = StringBuffer();
    for (var i = 0; i + 1 < data.length; i += 2) {
      var n = data[i] * 256 + data[i + 1];
      final c = n % 45;
      n ~/= 45;
      out
        ..write(_alphabet[c])
        ..write(_alphabet[n % 45])
        ..write(_alphabet[n ~/ 45]);
    }
    if (data.length.isOdd) {
      final n = data.last;
      out
        ..write(_alphabet[n % 45])
        ..write(_alphabet[n ~/ 45]);
    }
    return out.toString();
  }

  static Uint8List decode(String s) {
    final out = <int>[];
    int v(int i) {
      final x = _alphabet.indexOf(s[i]);
      if (x < 0) throw const FormatException('not base45');
      return x;
    }

    var i = 0;
    for (; i + 2 < s.length; i += 3) {
      final n = v(i) + v(i + 1) * 45 + v(i + 2) * 2025;
      if (n > 0xffff) throw const FormatException('not base45');
      out..add(n >> 8)..add(n & 0xff);
    }
    if (s.length - i == 2) {
      final n = v(i) + v(i + 1) * 45;
      if (n > 0xff) throw const FormatException('not base45');
      out.add(n);
    } else if (s.length - i == 1) {
      throw const FormatException('not base45');
    }
    return Uint8List.fromList(out);
  }
}
