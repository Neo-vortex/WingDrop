import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/app_cubit.dart';
import '../core/bridge.dart';
import '../core/settings.dart';
import '../l10n/strings.dart';
import '../core/avatars.dart';
import 'buddy_picker.dart';
import 'radar.dart' show peerName;
import 'common.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic> _caps = const {};
  String? _tree;
  List<Map<String, dynamic>> _bonds = const [];

  Future<void> _loadBonds() async {
    final b = await Bridge.list('bonds');
    if (mounted) setState(() => _bonds = b);
  }

  @override
  void initState() {
    super.initState();
    Bridge.caps().then((c) => mounted ? setState(() => _caps = c) : null);
    Bridge.call<String>('tree').then((t) => mounted ? setState(() => _tree = t) : null);
    _loadBonds();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final app = context.watch<AppCubit>();
    final st = app.state;
    final cfg = st.settings;

    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 28, 4, 12),
          child: Text(text, style: t.titleSmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w600)),
        );

    Widget seg<T>(List<(T, String)> options, T value, void Function(T) onChanged) => SizedBox(
          width: double.infinity,
          child: SegmentedButton<T>(
            showSelectedIcon: false,
            segments: [for (final o in options) ButtonSegment(value: o.$1, label: Text(o.$2))],
            selected: {value},
            onSelectionChanged: (v) => onChanged(v.first),
          ),
        );

    Widget labelled(String label, Widget child, {String? hint}) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: t.labelLarge),
            if (hint != null) Text(hint, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            child,
          ]),
        );

    Widget slider(String label, int value, List<int> steps, String Function(int) show, void Function(int) set) {
      final i = steps.indexOf(value).clamp(0, steps.length - 1);
      return labelled(
        label,
        Row(children: [
          Expanded(
            child: Slider(
              value: i.toDouble(),
              max: (steps.length - 1).toDouble(),
              divisions: steps.length - 1,
              onChanged: (v) => set(steps[v.round()]),
            ),
          ),
          SizedBox(width: 72, child: Text(show(value), textAlign: TextAlign.end, style: t.bodyMedium)),
        ]),
      );
    }

    final presets = [
      (Preset.maxSpeed, s.presetMax, s.presetMaxBody, Icons.bolt_rounded),
      (Preset.compatibility, s.presetCompat, s.presetCompatBody, Icons.wifi_rounded),
      (Preset.secure, s.presetSecure, s.presetSecureBody, Icons.lock_outline_rounded),
      (Preset.custom, s.presetCustom, s.presetCustomBody, Icons.tune_rounded),
    ];

    final bandOptions = <(String, String)>[
      ('best', s.bandBest),
      ('2', s.n('2.4')),
      if (_caps['band5'] != false) ('5', s.n('5')),
      if (_caps['band6'] == true) ('6', s.n('6')),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(s.settings)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
        children: [
          header(s.presets),
          for (final p in presets)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _PresetCard(
                icon: p.$4,
                title: p.$2,
                body: p.$3,
                selected: cfg.preset == p.$1,
                onTap: () => p.$1 == Preset.custom ? app.tweak((_) {}) : app.applyPreset(p.$1),
              ),
            ),

          header(s.advanced),
          Text(s.advancedHint, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 16),
          labelled(s.link, seg([('p2p', s.linkP2p), ('lohs', s.linkLohs), ('lan', s.linkLan)], cfg.link, (v) => app.tweak((c) => c.link = v))),
          AnimatedSize(
            duration: kSoft,
            child: cfg.link == 'lan'
                ? const SizedBox(width: double.infinity)
                : Column(children: [
                    labelled(s.band, seg(bandOptions, bandOptions.any((b) => b.$1 == cfg.band) ? cfg.band : 'best', (v) => app.tweak((c) => c.band = v))),
                    labelled(
                      s.wifiSecurity,
                      seg([('best', s.bandBest), ('wpa2', 'WPA2'), if (_caps['p2pR2'] == true) ('wpa3', 'WPA3')],
                          cfg.security == 'wpa3' && _caps['p2pR2'] != true ? 'best' : cfg.security, (v) => app.tweak((c) => c.security = v)),
                    ),
                  ]),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.e2e),
            subtitle: Text(s.e2eSub),
            value: cfg.encrypt,
            onChanged: (v) => app.tweak((c) => c.encrypt = v),
          ),
          const SizedBox(height: 8),
          labelled(s.compression, seg([('off', s.off), ('auto', s.compressionAuto), ('all', s.compressionAll)], cfg.compression, (v) => app.tweak((c) => c.compression = v))),
          slider(s.streams, cfg.streams, const [0, 1, 2, 3, 4, 6, 8, 12, 16], (v) => v == 0 ? s.streamsAuto : s.n(v), (v) => app.tweak((c) => c.streams = v)),
          slider(s.chunk, cfg.chunkKb, const [256, 512, 1024, 2048, 4096, 8192, 16384], (v) => s.n(v >= 1024 ? '${v ~/ 1024} MB' : '$v KB'), (v) => app.tweak((c) => c.chunkKb = v)),
          slider(s.sockBuf, cfg.sockBufKb, const [512, 1024, 2048, 4096, 8192, 16384], (v) => s.n(v >= 1024 ? '${v ~/ 1024} MB' : '$v KB'), (v) => app.tweak((c) => c.sockBufKb = v)),
          slider(s.depth, cfg.depth, const [1, 2, 3, 4, 6, 8], (v) => s.n(v), (v) => app.tweak((c) => c.depth = v)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.zeroCopy),
            value: cfg.zeroCopy,
            onChanged: (v) => app.tweak((c) => c.zeroCopy = v),
          ),
          const SizedBox(height: 8),
          labelled(s.wmm, seg([(0, s.wmmBe), (0x80, s.wmmVi), (0xB8, s.wmmVo)], cfg.tos, (v) => app.tweak((c) => c.tos = v))),

          header(s.shrinkSetting),
          labelled('', seg([('ask', s.shrinkAsk), ('original', s.shrinkOriginal), ('light', s.shrinkLight), ('small', s.shrinkSmall)], cfg.shrink, (v) => app.update((c) => c.shrink = v))),

          header(s.heicSection),
          labelled('', seg([('ask', s.heicAsk), ('convert', s.heicAlways), ('keep', s.heicNever)], cfg.heic, (v) => app.update((c) => c.heic = v))),
          slider(s.jpegQuality, cfg.jpegQuality, const [70, 75, 80, 85, 90, 92, 95, 98], (v) => s.n(v), (v) => app.update((c) => c.jpegQuality = v)),

          header(s.saveTo),
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(_tree == null ? s.saveDefault : Uri.decodeComponent(_tree!.split('/').last)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (_tree != null)
                  TextButton(
                    onPressed: () async {
                      await Bridge.call('clearTree');
                      setState(() => _tree = null);
                    },
                    child: Text(s.reset),
                  ),
                TextButton(
                  onPressed: () async {
                    final t = await Bridge.call<String>('pickTree');
                    if (t != null) setState(() => _tree = t);
                  },
                  child: Text(s.change),
                ),
              ]),
            ),
          ),

          header(s.you),
          BuddyPicker(selected: cfg.buddy, persian: s.fa, onPick: (i) => app.update((c) => c.buddy = i)),
          const SizedBox(height: 16),
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

          header(s.trustedTitle),
          Text(s.trustedHint, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          if (_bonds.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(s.noTrusted, style: t.bodyMedium),
            ),
          for (final b in _bonds)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: BuddyAvatar(index: b['buddy'] as int, size: 40),
              title: Text(peerName(s, b['buddy'] as int, b['nick'] as String)),
              trailing: IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () async {
                  await Bridge.call('removeBond', {'id': b['id']});
                  _loadBonds();
                },
              ),
            ),

          header(s.appearance),
          labelled(s.theme, seg([('system', s.themeSystem), ('light', s.themeLight), ('dark', s.themeDark)], st.theme, app.setTheme)),
          labelled(s.language, seg([('en', 'English'), ('fa', 'فارسی')], st.lang ?? 'en', app.setLanguage)),

          header(s.thisPhone),
          if (_caps.isNotEmpty) _CapsCard(caps: _caps),
        ],
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({required this.icon, required this.title, required this.body, required this.selected, required this.onTap});

  final IconData icon;
  final String title, body;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: kSoft,
      curve: kEase,
      decoration: BoxDecoration(
        color: selected ? cs.primaryContainer : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, color: selected ? cs.onPrimaryContainer : cs.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  AnimatedCrossFade(
                    duration: kSoft,
                    crossFadeState: selected ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                    firstChild: Text(body, style: t.bodyMedium?.copyWith(color: cs.onPrimaryContainer.withValues(alpha: 0.8))),
                    secondChild: Text(body, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              AnimatedOpacity(
                opacity: selected ? 1 : 0,
                duration: kSoft,
                child: Icon(Icons.check_circle_rounded, color: cs.onPrimaryContainer),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _CapsCard extends StatelessWidget {
  const _CapsCard({required this.caps});

  final Map<String, dynamic> caps;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final chips = <String>[
      if (caps['wifi7'] == true) 'Wi-Fi 7' else if (caps['wifi6'] == true) 'Wi-Fi 6',
      if (caps['band6'] == true) '6 GHz',
      if (caps['band5'] == true) '5 GHz',
      '2.4 GHz',
      if (caps['p2p'] == true) 'Wi-Fi Direct',
      if (caps['p2pR2'] == true) 'Wi-Fi Direct R2',
      if (caps['wpa3'] == true) 'WPA3',
      s.n('${caps['cores']} cores'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${caps['model']}', style: t.titleMedium),
          Text(s.n('Android SDK ${caps['sdk']}'), style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in chips) Chip(label: Text(c), side: BorderSide(color: cs.outlineVariant), visualDensity: VisualDensity.compact),
          ]),
        ]),
      ),
    );
  }
}
