import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/app_cubit.dart';
import '../l10n/strings.dart';
import 'buddy_picker.dart';
import 'common.dart';

/// First launch: pick a language, then three short, friendly pages.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _pages = PageController();
  int _page = 0;

  static const _icons = [Icons.waving_hand_outlined, Icons.bolt_rounded, Icons.spa_outlined];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  static const _pagesCount = 4;

  void _next() {
    if (_page == _pagesCount - 1) {
      context.read<AppCubit>().finishOnboarding();
    } else {
      _pages.nextPage(duration: const Duration(milliseconds: 650), curve: Curves.easeInOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppCubit>().state;
    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          switchInCurve: kEase,
          layoutBuilder: fullWidthLayout,
          child: app.lang == null ? const _LanguagePicker(key: ValueKey('lang')) : _intro(context),
        ),
      ),
    );
  }

  Widget _intro(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final titles = [s.ob1Title, s.ob2Title, s.ob3Title];
    final bodies = [s.ob1Body, s.ob2Body, s.ob3Body];
    return Padding(
      key: const ValueKey('intro'),
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: AnimatedOpacity(
              opacity: _page < 2 ? 1 : 0,
              duration: kSoft,
              child: TextButton(
                // Skipping the intro still lands on the buddy picker.
                onPressed: _page < 2
                    ? () => _pages.animateToPage(3, duration: const Duration(milliseconds: 800), curve: Curves.easeInOutCubic)
                    : null,
                child: Text(s.skip),
              ),
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pages,
              itemCount: _pagesCount,
              onPageChanged: (p) => setState(() => _page = p),
              itemBuilder: (context, i) => i == 3 ? const _BuddyPage() : AnimatedBuilder(
                animation: _pages,
                builder: (context, child) {
                  // Gentle parallax: content drifts and fades as you swipe.
                  final pos = _pages.hasClients && _pages.position.haveDimensions ? (_pages.page ?? 0) - i : 0.0;
                  final v = (1 - pos.abs()).clamp(0.0, 1.0);
                  return Opacity(opacity: v, child: Transform.translate(offset: Offset(pos * -40, 0), child: child));
                },
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Breathing(
                      child: i == 0
                          ? const AppLogo(size: 132)
                          : Container(
                              width: 132,
                              height: 132,
                              decoration: BoxDecoration(color: cs.primaryContainer, shape: BoxShape.circle),
                              child: Icon(_icons[i], size: 56, color: cs.onPrimaryContainer),
                            ),
                    ),
                    const SizedBox(height: 44),
                    Text(titles[i], style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    Text(
                      bodies[i],
                      style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < _pagesCount; i++)
                AnimatedContainer(
                  duration: kSoft,
                  curve: kEase,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: i == _page ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == _page ? cs.primary : cs.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _next,
              child: SoftText(_page == _pagesCount - 1 ? s.letsGo : s.next),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _BuddyPage extends StatelessWidget {
  const _BuddyPage();

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final app = context.watch<AppCubit>();
    final cfg = app.state.settings;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(children: [
        const SizedBox(height: 12),
        Text(s.pickBuddyTitle, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.center),
        const SizedBox(height: 10),
        Text(s.pickBuddyBody, style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
        const SizedBox(height: 24),
        BuddyPicker(selected: cfg.buddy, persian: s.fa, onPick: (i) => app.update((c) => c.buddy = i)),
        const SizedBox(height: 24),
        TextFormField(
          initialValue: cfg.nick,
          maxLength: 14,
          decoration: InputDecoration(
            labelText: s.nickname,
            helperText: s.nicknameHint,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
          ),
          onChanged: (v) => app.update((c) => c.nick = v.trim()),
        ),
        // Room between the hint and the page dots, even with the keyboard up.
        const SizedBox(height: 32),
      ]),
    );
  }
}

class _LanguagePicker extends StatelessWidget {
  const _LanguagePicker({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    // No language is chosen yet, so the screen is left-to-right; Persian text
    // must still be laid out right-to-left or "سلام!" shows as "!سلام".
    Widget option(String code, String label, String hello, String family, TextDirection dir) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Material(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(24),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => context.read<AppCubit>().setLanguage(code),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
                child: Directionality(
                  textDirection: dir,
                  child: Row(children: [
                    Expanded(
                      child: Text(label, style: t.titleLarge?.copyWith(fontFamily: family, fontWeight: FontWeight.w600)),
                    ),
                    Text(hello, style: t.bodyLarge?.copyWith(fontFamily: family, color: cs.onSurfaceVariant)),
                  ]),
                ),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(flex: 2),
          const FadeIn(child: Center(child: Breathing(child: AppLogo(size: 96)))),
          const SizedBox(height: 28),
          // Shown in both languages: we don't know which one yet.
          FadeIn(
            delay: const Duration(milliseconds: 80),
            child: Text('Pick your language', textAlign: TextAlign.center, style: t.headlineSmall?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 6),
          FadeIn(
            delay: const Duration(milliseconds: 120),
            child: Text(
              'زبانت رو انتخاب کن',
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              style: t.titleMedium?.copyWith(fontFamily: 'Vazirmatn', color: cs.onSurfaceVariant),
            ),
          ),
          const Spacer(),
          FadeIn(delay: const Duration(milliseconds: 180), child: option('en', 'English', 'Hi!', 'Nunito', TextDirection.ltr)),
          FadeIn(delay: const Duration(milliseconds: 240), child: option('fa', 'فارسی', 'سلام!', 'Vazirmatn', TextDirection.rtl)),
          const Spacer(flex: 2),
        ],
      ),
    );
  }
}
