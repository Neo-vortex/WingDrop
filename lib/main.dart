import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'blocs/app_cubit.dart';
import 'core/bridge.dart';
import 'ui/approve.dart';
import 'ui/home_page.dart';
import 'ui/onboarding_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Everything the first frame depends on (language, theme, onboarding) is
  // read before runApp, so nothing snaps or re-lays out after launch.
  final initial = await AppCubit.load();
  // Android asks us when someone found over the air wants to send.
  Bridge.onCall((call) async {
    final ctx = navigatorKey.currentContext;
    if (call.method == 'approve' && ctx != null && ctx.mounted) return askApproval(ctx, call.arguments as Map);
    if (call.method == 'shared') sharedIntake.value++;
    return 0;
  });
  runApp(BlocProvider(create: (_) => AppCubit(initial), child: const WingDropApp()));
}

final navigatorKey = GlobalKey<NavigatorState>();

/// Bumped when files arrive through "Share to WingDrop" while the app is open.
final sharedIntake = ValueNotifier<int>(0);

/// Calm palette: muted sage accent on warm sand (light) or deep moss-slate
/// (dark). No pure white/black, soft contrast, gentle corners.
class Calm {
  static const sage = Color(0xFF7C9A86);
  static const sand = Color(0xFFF6F2EA);
  static const moss = Color(0xFF151A18);
  static const terracotta = Color(0xFFB9826F);

  static ThemeData theme(Brightness b, {required bool persian}) {
    final dark = b == Brightness.dark;
    var scheme = ColorScheme.fromSeed(seedColor: sage, brightness: b, dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot);
    scheme = scheme.copyWith(surface: dark ? moss : sand, error: terracotta, onError: Colors.white);
    // Bundled fonts: Nunito (soft, rounded) for Latin, Vazirmatn for Persian.
    // Each falls back to the other per glyph, so mixed text never switches font abruptly.
    final family = persian ? 'Vazirmatn' : 'Nunito';
    final fallback = persian ? const ['Nunito'] : const ['Vazirmatn'];
    final base = ThemeData(brightness: b, useMaterial3: true).textTheme;
    final text = base
        .apply(fontFamily: family, fontFamilyFallback: fallback, bodyColor: scheme.onSurface, displayColor: scheme.onSurface)
        .copyWith(
          bodyLarge: base.bodyLarge?.copyWith(fontFamily: family, fontFamilyFallback: fallback, height: 1.5),
          bodyMedium: base.bodyMedium?.copyWith(fontFamily: family, fontFamilyFallback: fallback, height: 1.45),
        );
    final radius = BorderRadius.circular(24);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: family,
      fontFamilyFallback: fallback,
      textTheme: text,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: radius),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 54),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 54),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearTrackColor: scheme.surfaceContainerHighest,
        linearMinHeight: 6,
        borderRadius: BorderRadius.circular(6),
        year2023: false,
      ),
      tabBarTheme: TabBarThemeData(
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        unselectedLabelStyle: text.titleSmall,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: scheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      ),
      dialogTheme: DialogThemeData(backgroundColor: scheme.surfaceContainerLow),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      }),
    );
  }
}

class WingDropApp extends StatelessWidget {
  const WingDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppCubit, AppState>(
      buildWhen: (a, b) => a.lang != b.lang || a.theme != b.theme || a.onboarded != b.onboarded,
      builder: (context, state) {
        final persian = state.lang == 'fa';
        return MaterialApp(
          title: 'WingDrop',
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          theme: Calm.theme(Brightness.light, persian: persian),
          darkTheme: Calm.theme(Brightness.dark, persian: persian),
          themeMode: state.themeMode,
          themeAnimationDuration: const Duration(milliseconds: 600),
          themeAnimationCurve: Curves.easeInOutCubic,
          locale: state.locale,
          supportedLocales: const [Locale('en'), Locale('fa')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: state.lang == null || !state.onboarded ? const OnboardingPage() : const HomePage(),
        );
      },
    );
  }
}
