import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../l10n/strings.dart';
import 'common.dart';

/// A calm picture of everything in flight: per-type counts, then a grid of
/// tiles that start dim and fill with color and light from the bottom up as
/// each file arrives, like water rising in a glass.
class TransferOverview extends StatelessWidget {
  const TransferOverview({super.key, required this.sessions, this.maxTiles = 48});

  final List<OverviewSession> sessions;
  final int maxTiles;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final all = [for (final x in sessions) for (var i = 0; i < x.files.length; i++) (x.id, i, x.files[i])];
    if (all.isEmpty) return const SizedBox(width: double.infinity);
    final total = sessions.fold<int>(0, (a, x) => a + x.total);
    final counts = <int, int>{};
    for (final (_, _, f) in all) {
      counts[_group(f.cat)] = (counts[_group(f.cat)] ?? 0) + 1;
    }
    final tiles = all.take(maxTiles).toList();
    final more = total - tiles.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 14, runSpacing: 6, children: [
            for (final e in (counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(categoryIcon(e.key), size: 16, color: cs.primary),
                const SizedBox(width: 4),
                Text(s.n(e.value), style: t.labelLarge),
              ]),
          ]),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 78,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: tiles.length + (more > 0 ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == tiles.length) {
                return Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
                  child: Text(s.n('+$more'), style: t.titleSmall?.copyWith(color: cs.onSurfaceVariant)),
                );
              }
              final (sid, idx, f) = tiles[i];
              return FillTile(key: ValueKey('$sid:$idx'), session: sid, index: idx, file: f);
            },
          ),
        ]),
      ),
    );
  }

  static int _group(int cat) => cat == 1 || cat == 2 || cat == 3 || cat == 4 ? cat : 0;
}

/// Previews are fetched once per tile and kept.
class _PreviewCache {
  static final _m = <String, Future<Uint8List?>>{};

  static Future<Uint8List?> get(int session, int index) {
    final k = '$session:$index';
    return _m[k] ??= Bridge.preview(session, index);
  }
}

class FillTile extends StatelessWidget {
  const FillTile({super.key, required this.session, required this.index, required this.file});

  final int session, index;
  final OverviewFile file;

  @override
  Widget build(BuildContext context) => GlowTile(
        image: file.hasPreview ? _PreviewCache.get(session, index) : null,
        progress: file.progress,
        cat: file.cat,
        name: file.name,
      );
}

/// A tile that starts dim and grey and fills with color and light from the
/// bottom as [progress] rises, with a soft glow riding the fill line.
class GlowTile extends StatelessWidget {
  const GlowTile({super.key, this.image, required this.progress, required this.cat, required this.name, this.onTap});

  final Future<Uint8List?>? image;
  final double progress;
  final int cat;
  final String name;
  final VoidCallback? onTap;

  static const _grey = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0, 0, 0, 1, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final done = progress >= 1;
    return Tooltip(
      message: name,
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: FutureBuilder<Uint8List?>(
            future: image,
            builder: (context, snap) {
              final Widget face = snap.data != null
                  ? Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true)
                  : Container(
                      color: cs.primaryContainer,
                      alignment: Alignment.center,
                      child: Icon(categoryIcon(cat), color: cs.onPrimaryContainer, size: 26),
                    );
              return TweenAnimationBuilder<double>(
                tween: Tween(end: progress),
                duration: const Duration(milliseconds: 1100),
                curve: Curves.easeOutCubic,
                builder: (context, p, _) => Stack(fit: StackFit.expand, children: [
                  // Waiting: dim and quiet.
                  Opacity(opacity: 0.38, child: ColorFiltered(colorFilter: _grey, child: face)),
                  // Arrived part: full color, rising from the bottom.
                  ClipRect(clipper: _Rise(p), child: face),
                  if (p > 0 && p < 1) Positioned.fill(child: CustomPaint(painter: _Glow(p, cs.surface))),
                  AnimatedOpacity(
                    opacity: done ? 1 : 0,
                    duration: const Duration(milliseconds: 600),
                    child: Align(
                      alignment: AlignmentDirectional.bottomEnd,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.check_circle_rounded, size: 16, color: Colors.white.withValues(alpha: 0.9)),
                      ),
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Engine previews (what the sender sent before the files), cached per tile.
class PreviewCache {
  static Future<Uint8List?> get(int session, int index) => _PreviewCache.get(session, index);
}

class _Rise extends CustomClipper<Rect> {
  const _Rise(this.p);

  final double p;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, size.height * (1 - p), size.width, size.height);

  @override
  bool shouldReclip(_Rise old) => old.p != p;
}

class _Glow extends CustomPainter {
  _Glow(this.p, this.color);

  final double p;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * (1 - p);
    final r = Rect.fromLTRB(0, y - 10, size.width, y + 2);
    canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0), Colors.white.withValues(alpha: 0.35)],
        ).createShader(r),
    );
  }

  @override
  bool shouldRepaint(_Glow old) => old.p != p;
}
