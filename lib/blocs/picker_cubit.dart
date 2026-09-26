import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/settings.dart';

/// A folder picked in the Files tab: sent whole, with its structure.
class PickedFolder {
  const PickedFolder(this.key, this.name, this.items);

  final String key;
  final String name;
  final List<SendItem> items;

  int get bytes => items.fold(0, (a, b) => a + b.size);
}

class PickerState {
  const PickerState({this.selected = const {}, this.files = const [], this.folders = const [], this.mediaAllowed});

  /// Selection key -> items (an app contributes all of its APKs).
  final Map<String, List<SendItem>> selected;

  /// Files added through the system picker, shown in the Files tab.
  final List<SendItem> files;

  /// Folders added through the system picker, one entry each.
  final List<PickedFolder> folders;

  /// null = not asked yet.
  final bool? mediaAllowed;

  List<SendItem> get items => selected.values.expand((e) => e).toList();
  int get totalBytes => items.fold(0, (a, b) => a + b.size);

  PickerState copyWith({
    Map<String, List<SendItem>>? selected,
    List<SendItem>? files,
    List<PickedFolder>? folders,
    bool? mediaAllowed,
  }) =>
      PickerState(
        selected: selected ?? this.selected,
        files: files ?? this.files,
        folders: folders ?? this.folders,
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

  /// Adds a folder as one selectable entry. The same folder picked again
  /// replaces the old entry (its contents may have changed).
  void addFolder(String name, List<SendItem> items) {
    final key = 'folder:${items.first.rel.split('/').first}:${items.first.uri}';
    final folders = [...state.folders.where((f) => f.name != name), PickedFolder(key, name, items)];
    final selected = Map.of(state.selected)..removeWhere((k, _) => state.folders.any((f) => f.name == name && f.key == k));
    selected[key] = items;
    emit(state.copyWith(folders: folders, selected: selected));
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
