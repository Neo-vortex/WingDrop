import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/bridge.dart';
import '../core/settings.dart';

class AppState {
  const AppState({required this.lang, required this.onboarded, required this.theme, required this.revision});

  /// null until the user picks one on first launch.
  final String? lang;
  final bool onboarded;
  final String theme; // system | light | dark
  final int revision; // bumps whenever transfer settings change

  TransferSettings get settings => TransferSettings.instance;

  ThemeMode get themeMode => switch (theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  Locale get locale => Locale(lang ?? 'en');

  AppState copyWith({String? lang, bool? onboarded, String? theme, int? revision}) => AppState(
        lang: lang ?? this.lang,
        onboarded: onboarded ?? this.onboarded,
        theme: theme ?? this.theme,
        revision: revision ?? this.revision,
      );
}

/// App-wide preferences: language, onboarding, theme and transfer settings.
class AppCubit extends Cubit<AppState> {
  AppCubit(super.initial);

  /// Loaded before runApp so the first frame is already the right screen,
  /// language and theme (no visible snap).
  static Future<AppState> load() async {
    String? lang;
    var onboarded = false;
    try {
      await TransferSettings.instance.load();
      lang = await Bridge.call<String>('prefsGet', {'key': 'lang'});
      onboarded = await Bridge.call<String>('prefsGet', {'key': 'onboarded'}) == '1';
    } catch (_) {}
    return AppState(lang: lang, onboarded: onboarded, theme: TransferSettings.instance.theme, revision: 0);
  }

  void setLanguage(String lang) {
    Bridge.call('prefsSet', {'key': 'lang', 'value': lang});
    emit(state.copyWith(lang: lang));
  }

  void finishOnboarding() {
    Bridge.call('prefsSet', {'key': 'onboarded', 'value': '1'});
    emit(state.copyWith(onboarded: true));
  }

  void setTheme(String theme) {
    state.settings.theme = theme;
    state.settings.save();
    emit(state.copyWith(theme: theme));
  }

  void applyPreset(Preset p) => _change((s) => s.apply(p));

  /// Any manual tweak moves the user onto the Advanced preset.
  void tweak(void Function(TransferSettings s) f) => _change((s) {
        f(s);
        s.preset = Preset.custom;
      });

  /// Changes that are not part of the transfer presets (HEIC, save location…).
  void update(void Function(TransferSettings s) f) => _change(f);

  void _change(void Function(TransferSettings s) f) {
    f(state.settings);
    state.settings.save();
    emit(state.copyWith(revision: state.revision + 1));
  }
}
