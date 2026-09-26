import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/settings.dart';

class PickerState {
  const PickerState({this.selected = const {}, this.files = const [], this.mediaAllowed});

  /// Selection key -> items (an app contributes all of its APKs).
  final Map<String, List<SendItem>> selected;

  /// Files added through the system picker, shown in the Files tab.
  final List<SendItem> files;

  /// null = not asked yet.
  final bool? mediaAllowed;

  List<SendItem> get items => selected.values.expand((e) => e).toList();
  int get totalBytes => items.fold(0, (a, b) => a + b.size);

  PickerState copyWith({Map<String, List<SendItem>>? selected, List<SendItem>? files, bool? mediaAllowed}) => PickerState(
        selected: selected ?? this.selected,
        files: files ?? this.files,
        mediaAllowed: mediaAllowed ?? this.mediaAllowed,
      );
}

class PickerCubit extends Cubit<PickerState> {
  PickerCubit() : super(const PickerState());

  void setMediaAllowed(bool v) => emit(state.copyWith(mediaAllowed: v));

  void toggle(String key, List<SendItem> Function() items) {
    final next = Map.of(state.selected);
    if (next.remove(key) == null) next[key] = items();
    emit(state.copyWith(selected: next));
  }

  void addFiles(List<SendItem> picked) {
    final files = List.of(state.files);
    final selected = Map.of(state.selected);
    for (final f in picked) {
      if (files.any((e) => e.id == f.id)) continue;
      files.add(f);
      selected[f.id] = [f];
    }
    emit(state.copyWith(files: files, selected: selected));
  }
}
