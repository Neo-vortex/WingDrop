import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/bridge.dart';

class BenchResult {
  BenchResult(this.r);

  final List<double> r; // layout: see bench.h

  double get encSingle => r[0];
  double get encMulti => r[1];
  double get lzcSingle => r[2];
  double get lzcMulti => r[3];
  double get lzdSingle => r[4];
  double get lzdMulti => r[5];
  double get memory => r[6];
  double get network => r[7];
  int get threads => r[8].round();
  double get singleScore => r[9];
  double get multiScore => r[10];
  double get score => r[11];
  double get pipelineMBps => r[12];
  bool get aegis => r.length > 13 && r[13] > 0;
}

sealed class BenchState {
  const BenchState();
}

class BenchIdle extends BenchState {
  const BenchIdle();
}

class BenchRunning extends BenchState {
  const BenchRunning();
}

class BenchDone extends BenchState {
  const BenchDone(this.result);

  final BenchResult result;
}

class BenchFailed extends BenchState {
  const BenchFailed(this.message);

  final String message;
}

class BenchmarkCubit extends Cubit<BenchState> {
  BenchmarkCubit() : super(const BenchIdle());

  Future<void> run() async {
    emit(const BenchRunning());
    try {
      final started = DateTime.now();
      final r = await Bridge.call<List>('benchmark');
      // Let the calm "working" state breathe for a moment even on fast phones.
      final wait = const Duration(seconds: 2) - DateTime.now().difference(started);
      if (wait > Duration.zero) await Future.delayed(wait);
      emit(BenchDone(BenchResult(r!.cast<double>())));
    } catch (e) {
      emit(BenchFailed('$e'));
    }
  }
}
