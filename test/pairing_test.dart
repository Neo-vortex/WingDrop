import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wingdrop/core/settings.dart';
import 'package:wingdrop/ui/fancy_qr.dart';

void main() {
  test('compact QR pairing round-trips and is smaller than JSON', () {
    final p = Pairing(
      mode: 'p2p',
      hosts: const ['192.168.49.1'],
      port: 42420,
      key: List.generate(32, (i) => (i * 37 + 11) & 0xff),
      ssid: 'DIRECT-n9-WD670-neo',
      security: 'wpa2',
      buddy: 6,
      nick: 'neo',
      wifi: '6E',
      requireEncrypt: true,
      deviceId: '0123456789abcdef',
      freq: 5240,
    );
    final packed = p.encode();
    final back = Pairing.decode(packed)!;
    expect(back.mode, 'p2p');
    expect(back.ssid, p.ssid);
    expect(back.key, p.key);
    expect(back.buddy, 6);
    expect(back.nick, 'neo');
    expect(back.wifi, '6E');
    expect(back.requireEncrypt, true);
    expect(back.deviceId, p.deviceId);
    expect(back.freq, 5240);
    expect(back.hosts, ['192.168.49.1']);

    final json = jsonEncode({'v': 1, 'm': 'p2p', 's': p.ssid, 'p': 'x' * 20, 'b': '5', 'sec': 'wpa2',
      'h': ['192.168.49.1', '10.0.0.5'], 'o': 42420, 'k': base64Encode(p.key), 'a': 6, 'n': 'neo', 'w': '6E',
      'f': 1, 'i': p.deviceId, 'fq': 5240});
    final newQr = buildQr(packed), oldQr = buildQr(json);
    // ignore: avoid_print
    print('packed ${packed.length} chars -> QR version ${newQr.typeNumber} (${newQr.moduleCount}x${newQr.moduleCount}); '
        'old JSON ${json.length} chars -> version ${oldQr.typeNumber} (${oldQr.moduleCount}x${oldQr.moduleCount})');
    expect(newQr.moduleCount, lessThan(oldQr.moduleCount));
  });

  test('lan pairing keeps hosts and passphrase', () {
    final p = Pairing(mode: 'lohs', hosts: const ['192.168.1.4', '10.0.0.2'], port: 5000, key: List.filled(32, 7),
        ssid: 'AndroidShare_1234', pass: 'secret123', security: 'wpa3t');
    final back = Pairing.decode(p.encode())!;
    expect(back.hosts, p.hosts);
    expect(back.port, 5000);
    expect(back.pass, 'secret123');
    expect(back.security, 'wpa3t');
  });
}
