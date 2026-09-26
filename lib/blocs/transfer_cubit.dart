import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/bridge.dart';
import '../core/calm.dart';

class TransferState {
  const TransferState({
    this.stats,
    this.etaSecs = double.nan,
    this.itemEtaSecs = double.nan,
    this.speedMBps = 0,
    this.graph = const [],
    this.overview = const [],
  });

  final EngineStats? stats;
  final double etaSecs, itemEtaSecs, speedMBps;

  /// Speed samples (MB/s), one per second, oldest first.
  final List<double> graph;

  /// What's being moved, file by file (for the tile grid).
  final List<OverviewSession> overview;

  bool get finished {
    final s = stats?.state;
    return (s == EngineState.done || s == EngineState.failed || s == EngineState.cancelled) &&
        (stats?.totalBytes ?? 0) > 0;
  }
}

/// Polls the engine twice a second and publishes calm, smoothed numbers plus a
/// gently sampled speed history for the graph.
class TransferCubit extends Cubit<TransferState> {
  TransferCubit() : super(const TransferState()) {
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
    _poll();
  }

  static const graphLength = 120;

  final _calm = CalmTracker();
  final _graph = <double>[];
  Timer? _timer;
  int _tick = 0;
  int _moving = 0;
  List<OverviewSession> _overview = const [];
  String? _itemKey;

  Future<void> _poll() async {
    final s = await Bridge.stats();
    if (isClosed) return;
    final cur = s.current;
    final key = cur?['key'] as String?;
    if (key != _itemKey) _itemKey = key;
    final itemIndex = key == null ? -1 : key.hashCode & 0x7fffffff;
    final remaining = cur == null ? 0 : (cur['size'] as int) - (cur['done'] as int);
    _calm.update(s, itemIndex: itemIndex, itemRemaining: remaining);

    // The tile grid refreshes once a second; plenty for gliding fills.
    if (_tick % 2 == 0 || _overview.isEmpty) {
      _overview = await Bridge.overview();
      if (isClosed) return;
    }
    // Two graph samples a second while bytes are moving. The first second is
    // warm-up (TCP ramping, a partial interval): leaving it out keeps the
    // chart about the real flow instead of a climb from zero.
    ++_tick;
    if (s.state == EngineState.transferring) {
      if (++_moving > 2 && _calm.graphRate > 0) {
        _graph.add(_calm.graphRate / 1e6);
        if (_graph.length > graphLength) _graph.removeAt(0);
      }
    } else {
      _moving = 0;
    }
    emit(TransferState(
      stats: s,
      etaSecs: _calm.etaSecs,
      itemEtaSecs: _calm.itemEtaSecs,
      speedMBps: _calm.speedMBps,
      graph: List.unmodifiable(_graph),
      overview: _overview,
    ));
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
