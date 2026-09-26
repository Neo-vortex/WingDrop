/// Device info packed into the Wi-Fi Direct network name, so senders can see
/// who is around before connecting. Layout after Android's mandatory
/// "DIRECT-xy-" prefix (32-byte SSID limit):
///
///   `WD{buddy base36}{wifi 4,5,6,E,7}{flags hex}-{nickname}`
///
/// flags: 1 = encryption required, 2 = compression on, 4 = WPA3 link.
class DeviceTag {
  const DeviceTag({
    required this.buddy,
    required this.wifi,
    required this.encrypt,
    required this.compress,
    required this.wpa3,
    required this.nick,
  });

  final int buddy;
  final String wifi; // '4', '5', '6', '6E', '7'
  final bool encrypt, compress, wpa3;
  final String nick;

  static String wifiFromCaps(Map<String, dynamic> caps) {
    if (caps['wifi7'] == true) return '7';
    if (caps['wifi6'] == true) return caps['band6'] == true ? '6E' : '6';
    if (caps['band5'] == true) return '5';
    return '4';
  }

  String encode() {
    final flags = (encrypt ? 1 : 0) | (compress ? 2 : 0) | (wpa3 ? 4 : 0);
    final w = wifi == '6E' ? 'E' : wifi;
    // Nicknames go over the air: keep them short and ASCII-safe.
    final safeNick = nick.replaceAll(RegExp(r'[^A-Za-z0-9 _.]'), '').trim();
    final n = safeNick.length > 14 ? safeNick.substring(0, 14) : safeNick;
    return 'WD${buddy.toRadixString(36)}$w${flags.toRadixString(16)}${n.isEmpty ? '' : '-$n'}';
  }

  static DeviceTag? parse(String ssid) {
    final m = RegExp(r'^DIRECT-..-WD([0-9a-z])([4567E])([0-9a-f])(?:-(.*))?$').firstMatch(ssid);
    if (m == null) return null;
    final flags = int.parse(m[3]!, radix: 16);
    return DeviceTag(
      buddy: int.parse(m[1]!, radix: 36),
      wifi: m[2] == 'E' ? '6E' : m[2]!,
      encrypt: flags & 1 != 0,
      compress: flags & 2 != 0,
      wpa3: flags & 4 != 0,
      nick: m[4] ?? '',
    );
  }
}
