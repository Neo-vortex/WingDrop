import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/picker_cubit.dart';
import '../core/bridge.dart';
import '../core/format.dart';
import '../core/settings.dart';
import '../l10n/strings.dart';
import 'common.dart';
import 'permissions.dart';
import 'send_page.dart';

/// Small LRU so scrolling back does not re-decode thumbnails.
class _ThumbCache {
  static final _map = <String, Future<Uint8List?>>{};

  static Future<Uint8List?> get(String key, Future<Uint8List?> Function() load) {
    final f = _map.remove(key) ?? load();
    _map[key] = f;
    if (_map.length > 500) _map.remove(_map.keys.first);
    return f;
  }
}

class PickerPage extends StatelessWidget {
  const PickerPage({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocProvider(create: (_) => PickerCubit(), child: const _PickerView());
}

class _PickerView extends StatefulWidget {
  const _PickerView();

  @override
  State<_PickerView> createState() => _PickerViewState();
}

class _PickerViewState extends State<_PickerView> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 5, vsync: this);
  bool _warm = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _askMedia());
    _warmUp();
  }

  /// Start looking for receivers while files are being picked, so the radar
  /// usually has them by the time it opens. Only when already allowed: the
  /// picker never asks for the nearby permission itself.
  Future<void> _warmUp() async {
    final ok = await Bridge.call<bool>('hasPermissions', {'kinds': ['nearby']}) == true;
    if (!ok || !mounted || await Bridge.call<bool>('wifiOn') != true || !mounted) return;
    _warm = true;
    await Bridge.call('discoverStart');
  }

  Future<void> _askMedia() async {
    final ok = await ensurePermission(context, 'media');
    if (mounted) context.read<PickerCubit>().setMediaAllowed(ok);
  }

  @override
  void dispose() {
    if (_warm) Bridge.call('discoverStop');
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final st = context.watch<PickerCubit>().state;
    final items = st.items;
    Widget media(Widget child) => switch (st.mediaAllowed) {
          null => const _Loader(),
          false => _PermissionHint(onRetry: _askMedia),
          true => child,
        };
    return Scaffold(
      appBar: AppBar(
        title: Text(s.pickTitle),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [Tab(text: s.photos), Tab(text: s.videos), Tab(text: s.music), Tab(text: s.apps), Tab(text: s.files)],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          media(const _MediaGrid(kind: 'image', cat: 1)),
          media(const _MediaGrid(kind: 'video', cat: 2)),
          media(const _MusicList()),
          const _AppsGrid(),
          const _FilesTab(),
        ],
      ),
      bottomNavigationBar: AnimatedSlide(
        offset: items.isEmpty ? const Offset(0, 1) : Offset.zero,
        duration: kSoft,
        curve: kEase,
        child: AnimatedOpacity(
          opacity: items.isEmpty ? 0 : 1,
          duration: kSoft,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SoftText(s.selected(st.selected.length), style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                        SoftText(fmtBytes(s, st.totalBytes), style: t.bodySmall),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    icon: const Icon(Icons.north_east_rounded),
                    label: Text(s.send),
                    onPressed: items.isEmpty
                        ? null
                        : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SendPage(items: items))),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PermissionHint extends StatelessWidget {
  const _PermissionHint({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.photo_library_outlined, size: 48, color: cs.primary),
          const SizedBox(height: 16),
          Text(s.noMediaAccess, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 20),
          OutlinedButton(onPressed: onRetry, child: Text(s.letMeSee)),
        ]),
      ),
    );
  }
}

class _Loader extends StatelessWidget {
  const _Loader();

  @override
  Widget build(BuildContext context) =>
      Center(child: Breathing(child: Icon(Icons.blur_on_rounded, size: 40, color: Theme.of(context).colorScheme.primary)));
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Center(child: Text(context.s.nothingHere));
}

/// Loads a list once and keeps it while switching tabs.
mixin _KeepList<T extends StatefulWidget> on State<T>, AutomaticKeepAliveClientMixin<T> {
  late final Future<List<Map<String, dynamic>>> items = load();

  Future<List<Map<String, dynamic>>> load();

  @override
  bool get wantKeepAlive => true;
}

class _MediaGrid extends StatefulWidget {
  const _MediaGrid({required this.kind, required this.cat});

  final String kind;
  final int cat;

  @override
  State<_MediaGrid> createState() => _MediaGridState();
}

class _MediaGridState extends State<_MediaGrid> with AutomaticKeepAliveClientMixin, _KeepList {
  @override
  Future<List<Map<String, dynamic>>> load() => Bridge.list('media', {'kind': widget.kind});

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final selected = context.select<PickerCubit, Map<String, List<SendItem>>>((c) => c.state.selected);
    return FutureBuilder(
      future: items,
      builder: (context, snap) {
        if (!snap.hasData) return const _Loader();
        final list = snap.data!;
        if (list.isEmpty) return const _Empty();
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 120,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final m = list[i];
            final uri = m['uri'] as String;
            final sel = selected.containsKey(uri);
            return GestureDetector(
              onTap: () => context.read<PickerCubit>().toggle(uri, () => [
                    SendItem(
                      id: uri,
                      uri: uri,
                      name: m['name'],
                      size: m['size'],
                      cat: widget.cat,
                      mime: m['mime'],
                      heic: m['heic'] == true,
                    ),
                  ]),
              child: AnimatedScale(
                scale: sel ? 0.9 : 1,
                duration: const Duration(milliseconds: 280),
                curve: kEase,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(fit: StackFit.expand, children: [
                    Container(color: cs.surfaceContainerHighest),
                    FutureBuilder<Uint8List?>(
                      future: _ThumbCache.get(uri, () => Bridge.thumb(uri)),
                      builder: (context, s) => AnimatedOpacity(
                        opacity: s.data == null ? 0 : 1,
                        duration: kSoft,
                        child: s.data == null
                            ? const SizedBox()
                            : Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true),
                      ),
                    ),
                    if (widget.cat == 2)
                      const PositionedDirectional(
                        start: 6,
                        bottom: 6,
                        child: Icon(Icons.play_circle_outline_rounded, color: Colors.white70, size: 20),
                      ),
                    if (m['heic'] == true)
                      PositionedDirectional(
                        start: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(8)),
                          child: const Text('HEIC', style: TextStyle(color: Colors.white, fontSize: 10, fontFamily: 'Nunito')),
                        ),
                      ),
                    AnimatedOpacity(
                      opacity: sel ? 1 : 0,
                      duration: const Duration(milliseconds: 280),
                      child: Container(
                        color: cs.primary.withValues(alpha: 0.35),
                        alignment: AlignmentDirectional.topEnd,
                        padding: const EdgeInsets.all(6),
                        child: Icon(Icons.check_circle_rounded, color: cs.onPrimary),
                      ),
                    ),
                  ]),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _MusicList extends StatefulWidget {
  const _MusicList();

  @override
  State<_MusicList> createState() => _MusicListState();
}

class _MusicListState extends State<_MusicList> with AutomaticKeepAliveClientMixin, _KeepList {
  @override
  Future<List<Map<String, dynamic>>> load() => Bridge.list('media', {'kind': 'audio'});

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = context.s;
    final selected = context.select<PickerCubit, Map<String, List<SendItem>>>((c) => c.state.selected);
    return FutureBuilder(
      future: items,
      builder: (context, snap) {
        if (!snap.hasData) return const _Loader();
        final list = snap.data!;
        if (list.isEmpty) return const _Empty();
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final m = list[i];
            final uri = m['uri'] as String;
            final sel = selected.containsKey(uri);
            final artist = m['artist'] as String;
            return ListTile(
              leading: const CircleAvatar(child: Icon(Icons.music_note_outlined)),
              title: Text(m['name'], maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text([if (artist.isNotEmpty && artist != '<unknown>') artist, fmtBytes(s, m['size'])].join(' · ')),
              trailing: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                child: Icon(
                  sel ? Icons.check_circle_rounded : Icons.circle_outlined,
                  key: ValueKey(sel),
                  color: sel ? Theme.of(context).colorScheme.primary : null,
                ),
              ),
              onTap: () => context.read<PickerCubit>().toggle(uri, () => [
                    SendItem(id: uri, uri: uri, name: m['name'], size: m['size'], cat: 3, mime: m['mime']),
                  ]),
            );
          },
        );
      },
    );
  }
}

class _AppsGrid extends StatefulWidget {
  const _AppsGrid();

  @override
  State<_AppsGrid> createState() => _AppsGridState();
}

class _AppsGridState extends State<_AppsGrid> with AutomaticKeepAliveClientMixin, _KeepList {
  @override
  Future<List<Map<String, dynamic>>> load() => Bridge.list('apps');

  List<SendItem> _apks(Map<String, dynamic> m) {
    final apks = (m['apks'] as List).cast<String>();
    final sizes = (m['apkSizes'] as List).cast<int>();
    final label = m['label'] as String;
    final version = m['version'] as String;
    if (apks.length == 1) {
      return [
        SendItem(
          id: apks.first,
          path: apks.first,
          name: '$label${version.isEmpty ? '' : ' $version'}.apk',
          size: sizes.first,
          cat: 4,
          rel: 'Apps',
        ),
      ];
    }
    // Split app: keep the parts together in one folder so it can be installed.
    return [
      for (var i = 0; i < apks.length; i++)
        SendItem(id: apks[i], path: apks[i], name: apks[i].split('/').last, size: sizes[i], cat: 4, rel: 'Apps/$label'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = context.s;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final selected = context.select<PickerCubit, Map<String, List<SendItem>>>((c) => c.state.selected);
    return FutureBuilder(
      future: items,
      builder: (context, snap) {
        if (!snap.hasData) return const _Loader();
        final list = snap.data!;
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 104,
            childAspectRatio: 0.76,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final m = list[i];
            final pkg = m['pkg'] as String;
            final sel = selected.containsKey(pkg);
            return InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => context.read<PickerCubit>().toggle(pkg, () => _apks(m)),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 320),
                curve: kEase,
                decoration: BoxDecoration(
                  color: sel ? cs.primaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                ),
                padding: const EdgeInsets.all(8),
                child: Column(children: [
                  SizedBox.square(
                    dimension: 52,
                    child: FutureBuilder<Uint8List?>(
                      future: _ThumbCache.get('app:$pkg', () => Bridge.appIcon(pkg)),
                      builder: (context, snap) => AnimatedOpacity(
                        opacity: snap.data == null ? 0 : 1,
                        duration: kSoft,
                        child: snap.data == null ? const SizedBox() : Image.memory(snap.data!),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(m['label'], maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: t.bodySmall),
                  Text(fmtBytes(s, m['size']), style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}

class _FilesTab extends StatelessWidget {
  const _FilesTab();

  Future<void> _pick(BuildContext context) async {
    final picked = await Bridge.list('pickFiles');
    if (!context.mounted) return;
    context.read<PickerCubit>().addFiles([
      for (final m in picked)
        SendItem(
          id: m['uri'],
          uri: m['uri'],
          name: m['name'],
          size: m['size'],
          cat: 0,
          mime: m['mime'],
          heic: m['heic'] == true,
        ),
    ]);
  }

  Future<void> _pickFolder(BuildContext context) async {
    final picked = await Bridge.list('pickFolder');
    if (!context.mounted) return;
    if (picked.isEmpty) return; // cancelled, or an empty folder: nothing to send
    final items = [
      for (final m in picked)
        SendItem(
          id: m['uri'],
          uri: m['uri'],
          name: m['name'],
          size: m['size'],
          cat: 0,
          rel: m['rel'],
          mime: m['mime'],
          keep: true,
        ),
    ];
    context.read<PickerCubit>().addFolder((picked.first['rel'] as String).split('/').first, items);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final st = context.watch<PickerCubit>().state;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(onPressed: () => _pick(context), icon: const Icon(Icons.add_rounded), label: Text(s.addFiles)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _pickFolder(context),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(s.addFolder),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        for (final d in st.folders)
          CheckboxListTile(
            value: st.selected.containsKey(d.key),
            onChanged: (_) => context.read<PickerCubit>().toggle(d.key, () => d.items),
            secondary: Icon(Icons.folder_rounded, color: Theme.of(context).colorScheme.primary),
            title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(s.folderSummary(d.items.length, fmtBytes(s, d.bytes)), maxLines: 1),
          ),
        for (final f in st.files)
          CheckboxListTile(
            value: st.selected.containsKey(f.id),
            onChanged: (_) => context.read<PickerCubit>().toggle(f.id, () => [f]),
            secondary: Icon(categoryIcon(0)),
            title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text([if (f.rel.isNotEmpty) f.rel, fmtBytes(s, f.size)].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
    );
  }
}
