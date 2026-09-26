import '../l10n/strings.dart';

String fmtBytes(S s, num b) {
  final units = s.fa ? const ['بایت', 'کیلوبایت', 'مگابایت', 'گیگابایت', 'ترابایت'] : const ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return s.n('${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}');
}

String fmtRate(S s, double bytesPerSec) {
  final mb = bytesPerSec / 1e6;
  return s.n(s.fa ? '${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} مگابایت بر ثانیه' : '${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} MB/s');
}

String fmtMBps(S s, double mbps) =>
    s.n(s.fa ? '≈ ${_trim(mbps)} مگابایت بر ثانیه' : '≈ ${_trim(mbps)} MB/s');

String _trim(double v) => v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

String fmtMs(S s, int ms) {
  final d = Duration(milliseconds: ms);
  final String out;
  if (s.fa) {
    out = d.inHours > 0
        ? '${d.inHours} ساعت و ${d.inMinutes % 60} دقیقه'
        : d.inMinutes > 0
            ? '${d.inMinutes} دقیقه و ${d.inSeconds % 60} ثانیه'
            : '${d.inSeconds} ثانیه';
  } else {
    out = d.inHours > 0
        ? '${d.inHours}h ${d.inMinutes % 60}m'
        : d.inMinutes > 0
            ? '${d.inMinutes}m ${d.inSeconds % 60}s'
            : '${d.inSeconds}s';
  }
  return s.n(out);
}
