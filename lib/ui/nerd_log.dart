import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../core/format.dart';
import '../l10n/strings.dart';
import 'common.dart';

/// App-bar button: a little bug that opens the nerd log.
class NerdLogButton extends StatelessWidget {
  const NerdLogButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: context.s.nerdLog,
        icon: const Icon(Icons.bug_report_outlined),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NerdLogPage())),
      );
}

/// Technical, terminal-style view of everything the app and engine did:
/// Wi-Fi / BLE / scanner / UI events and the native engine's log on one
/// timeline, plus live engine state and this phone's radio capabilities.
class NerdLogPage extends StatefulWidget {
  const NerdLogPage({super.key});

  @override
  State<NerdLogPage> createState() => _NerdLogPageState();
}

class _NerdLogPageState extends State<NerdLogPage> {
  static const _filters = {
    'all': null,
    'wifi': 'WingDropWifi',
    'ble': 'WingDropBle',
    'engine': 'wingdrop-',
    'scan': 'WingDropScan',
    'ui': 'WingDropUi',
  };

  Timer? _timer;
  bool _paused = false;
  String _filter = 'all';
  String _log = '';
  EngineStats? _stats;
  Map<String, dynamic> _caps = const {};

  @override
  void initState() {
    super.initState();
    Bridge.caps().then((c) => mounted ? setState(() => _caps = c) : null);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _paused ? null : _refresh());
  }

  Future<void> _refresh() async {
    final log = await Bridge.call<String>('diag') ?? '';
    final st = await Bridge.stats();
    if (mounted) setState(() {
      _log = log;
      _stats = st;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  List<String> get _lines {
    final key = _filters[_filter];
    final all = _log.split('\n').where((l) => l.isNotEmpty);
    return (key == null ? all : all.where((l) => l.contains(key))).toList();
  }

  String _report() {
    final c = _caps.entries.map((e) => '${e.key}=${e.value}').join(' ');
    return 'WingDrop nerd log\ncaps: $c\nstatus: ${_stats?.j}\n\n$_log';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    const term = Color(0xFF0E1412);
    const ink = Color(0xFFCFE3D6);
    final lines = _lines;
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [const Icon(Icons.bug_report_outlined), const SizedBox(width: 8), Text(s.nerdLog)]),
        actions: [
          IconButton(
            tooltip: _paused ? s.resumeLog : s.pauseLog,
            icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
            onPressed: () => setState(() => _paused = !_paused),
          ),
          IconButton(
            tooltip: s.copy,
            icon: const Icon(Icons.copy_all_rounded),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _report()));
              toast(context, s.copied);
            },
          ),
          IconButton(
            tooltip: s.clearLog,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () async {
              await Bridge.call('diagClear');
              _refresh();
            },
          ),
        ],
      ),
      body: Column(children: [
        _StatusPanel(stats: _stats, caps: _caps),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            children: [
              for (final f in _filters.keys)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(f, style: const TextStyle(fontFamily: 'monospace')),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            decoration: BoxDecoration(color: term, borderRadius: BorderRadius.circular(16)),
            child: lines.isEmpty
                ? Center(child: Text(s.logEmpty, style: const TextStyle(color: ink, fontFamily: 'monospace')))
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: lines.length,
                    itemBuilder: (context, i) => _LogLine(lines[lines.length - 1 - i]),
                  ),
          ),
        ),
      ]),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine(this.line);

  final String line;

  @override
  Widget build(BuildContext context) {
    // "HH:MM:SS.mmm L tag: message"
    final m = RegExp(r'^(\S+) ([IWE]) ([^:]+): (.*)$').firstMatch(line);
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.45);
    if (m == null) return Text(line, style: mono.copyWith(color: const Color(0xFFCFE3D6)));
    final level = m[2]!;
    final levelColor = switch (level) {
      'W' => const Color(0xFFE8C170),
      'E' => const Color(0xFFE88E7F),
      _ => const Color(0xFF7FD1A1),
    };
    return SelectableText.rich(
      TextSpan(style: mono, children: [
        TextSpan(text: '${m[1]} ', style: const TextStyle(color: Color(0xFF6E8579))),
        TextSpan(text: '$level ', style: TextStyle(color: levelColor, fontWeight: FontWeight.w700)),
        TextSpan(text: '${m[3]}: ', style: const TextStyle(color: Color(0xFF8FB3D9))),
        TextSpan(text: m[4], style: const TextStyle(color: Color(0xFFCFE3D6))),
      ]),
      textDirection: TextDirection.ltr,
    );
  }
}

/// Live engine state and radio capabilities, compact and monospace.
class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.stats, required this.caps});

  final EngineStats? stats;
  final Map<String, dynamic> caps;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final cs = Theme.of(context).colorScheme;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.5);
    final st = stats;
    final rows = <String>[
      'device  ${caps['model'] ?? '?'} · sdk ${caps['sdk'] ?? '?'} · ${caps['cores'] ?? '?'} cores',
      'radio   wifi7=${caps['wifi7']} wifi6=${caps['wifi6']} 6GHz=${caps['band6']} 5GHz=${caps['band5']} '
          'p2p=${caps['p2p']} R2=${caps['p2pR2']} wpa3=${caps['wpa3']}',
      'state   wifi=${caps['wifiOn']} bt=${caps['bt']} vpn=${caps['vpn']}',
      if (st != null) ...[
        'engine  ${st.state.name} · ${fmtBytes(s, st.doneBytes)}/${fmtBytes(s, st.totalBytes)} · '
            'wire ${fmtBytes(s, st.wireBytes)} · ${st.streams} streams · flags 0x${st.flags.toRadixString(16)}'
            '${st.encrypted ? (st.aegis ? ' aegis' : ' xchacha') : ''}${st.compressed ? ' lz4/zstd' : ''}',
        for (final x in st.sessions)
          '  #${x.id} ${x.sending ? 'send' : 'recv'} ${x.state.name} phase=${x.phase} '
              '${x.filesDone}/${x.filesTotal} files ${fmtBytes(s, x.done)}/${fmtBytes(s, x.total)}'
              '${x.skipped > 0 ? ' resumed ${fmtBytes(s, x.skipped)}' : ''}'
              ' peer=${x.nick.isEmpty ? '-' : x.nick}(${x.peer.isEmpty ? '?' : x.peer})'
              '${x.error.isEmpty ? '' : ' err=${x.error}'}',
      ],
    ];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(16)),
      child: SelectableText(rows.join('\n'), style: mono, textDirection: TextDirection.ltr),
    );
  }
}
