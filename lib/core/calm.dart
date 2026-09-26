import 'dart:math' as math;

import 'bridge.dart';

/// Turns jittery engine counters into numbers that are pleasant to look at.
///
/// * Speed is an exponential moving average with a ~10 s time constant and is
///   only re-published every few seconds, rounded to two significant figures.
/// * The published time estimates change at most every [_minInterval]. They
///   may always go down, but only go up when clearly (25%+) worse, so the
///   text never flip-flops. The UI phrases them in words.
class CalmTracker {
  static const _tau = 10.0; // seconds
  static const _minInterval = Duration(seconds: 6);
  static const _speedInterval = Duration(seconds: 3);
  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  double _rate = 0; // bytes / s, smoothed
  int _lastBytes = 0;
  DateTime? _lastAt;

  /// Published values; NaN = not known yet.
  double etaSecs = double.nan;
  double itemEtaSecs = double.nan;
  double speedMBps = 0;

  DateTime _etaAt = _epoch, _itemAt = _epoch, _speedAt = _epoch;
  int _itemIndex = -1;

  /// Lighter smoothing for the speed graph: lively but never jittery.
  double graphRate = 0;

  void update(EngineStats s, {int itemIndex = -1, int itemRemaining = 0}) {
    final now = DateTime.now();
    if (s.state != EngineState.transferring) {
      _lastAt = null;
      return;
    }
    if (_lastAt != null) {
      final dt = now.difference(_lastAt!).inMicroseconds / 1e6;
      if (dt > 0.05) {
        final inst = math.max(0, (s.doneBytes - s.skippedBytes) - _lastBytes) / dt;
        if (_rate == 0) {
          // Seed with the running average so the first seconds are not wild.
          _rate = s.avgBytesPerSec > 0 ? s.avgBytesPerSec : inst.toDouble();
        } else {
          _rate += (1 - math.exp(-dt / _tau)) * (inst - _rate);
        }
        graphRate = graphRate == 0 ? inst.toDouble() : graphRate + (1 - math.exp(-dt / 2.0)) * (inst - graphRate);
      }
    }
    _lastAt = now;
    _lastBytes = s.doneBytes - s.skippedBytes;

    // Give it a few seconds before promising anything.
    if (s.elapsedMs < 2500 || _rate <= 0) return;

    if (now.difference(_speedAt) >= _speedInterval) {
      _speedAt = now;
      speedMBps = _twoSig(_rate / 1e6);
    }

    final remaining = (s.totalBytes - s.doneBytes) / _rate;
    if (etaSecs.isNaN) {
      etaSecs = remaining;
      _etaAt = now;
    } else if (now.difference(_etaAt) >= _minInterval &&
        (remaining <= etaSecs || remaining > etaSecs * 1.25 + 5)) {
      etaSecs = remaining;
      _etaAt = now;
    }

    if (itemIndex != _itemIndex) {
      _itemIndex = itemIndex;
      _itemAt = _epoch;
      itemEtaSecs = double.nan;
    }
    if (itemIndex >= 0 && now.difference(_itemAt) >= _minInterval) {
      itemEtaSecs = itemRemaining / _rate;
      _itemAt = now;
    }
  }

  static double _twoSig(double v) {
    if (v <= 0) return 0;
    final digits = (math.log(v) / math.ln10).floor();
    final factor = math.pow(10, digits - 1).toDouble();
    return (v / factor).round() * factor;
  }
}
