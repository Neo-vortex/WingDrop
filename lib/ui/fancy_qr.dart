import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/avatars.dart';
import '../core/bridge.dart';
import '../l10n/strings.dart';
import 'common.dart';

/// Builds the smallest QR that fits. Compact payloads ("WD1:" + Base45) use
/// alphanumeric mode, which needs far fewer modules than byte mode.
QrCode buildQr(String data) {
  const alnum = r'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';
  final alphanumeric = data.split('').every(alnum.contains);
  for (var t = 1; t <= 40; t++) {
    try {
      final q = QrCode(t, QrErrorCorrectLevel.H);
      alphanumeric ? q.addAlphaNumeric(data) : q.addData(data);
      QrImage(q); // throws if it doesn't fit this version
      return q;
    } on InputTooLongException {
      continue;
    }
  }
  throw ArgumentError('QR payload too long');
}

/// Colorful, soft QR: round modules painted with a gradient in the owner's
/// buddy colors, the buddy sitting in the middle. High error correction keeps
/// it easy to scan despite the decoration. In dark mode the code is drawn
/// light-on-dark (the scanner tries both polarities). Tap to go full screen.
class FancyQr extends StatelessWidget {
  const FancyQr({super.key, required this.data, required this.buddy, this.size = 300, this.onTap});

  final String data;
  final int buddy;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = HSLColor.fromColor(buddyAt(buddy).color);
    // Contrast first: dark modules on light, light modules on dark.
    Color tone(double hueShift) => base
        .withHue((base.hue + hueShift) % 360)
        .withSaturation((base.saturation * 1.1).clamp(0.35, 0.7))
        .withLightness(dark ? 0.78 : 0.34)
        .toColor();
    final colors = [tone(0), tone(40), tone(-50)];

    return GestureDetector(
      onTap: onTap,
      child: Hero(
        tag: 'wingdrop-qr',
        child: Container(
          padding: EdgeInsets.all(size * 0.07),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(36),
            color: cs.surfaceContainerLow,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                buddyAt(buddy).color.withValues(alpha: dark ? 0.16 : 0.14),
                cs.surfaceContainerLow,
                colors[2].withValues(alpha: dark ? 0.12 : 0.10),
              ],
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => SweepGradient(
                  center: Alignment.center,
                  colors: [...colors, colors.first],
                ).createShader(r),
                child: QrImageView.withQr(
                  qr: buildQr(data),
                  size: size,
                  padding: EdgeInsets.zero,
                  backgroundColor: Colors.transparent,
                  eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Colors.white),
                  dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Colors.white),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: cs.surfaceContainerLow, shape: BoxShape.circle),
                child: Breathing(
                  period: const Duration(milliseconds: 4200),
                  child: BuddyAvatar(index: buddy, size: size * 0.17),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The QR as big as the screen allows, with brightness turned up while shown.
class FullScreenQr extends StatefulWidget {
  const FullScreenQr({super.key, required this.data, required this.buddy});

  final String data;
  final int buddy;

  static Future<void> show(BuildContext context, String data, int buddy) => Navigator.of(context).push(
        PageRouteBuilder(
          opaque: false,
          barrierColor: Colors.black54,
          transitionDuration: const Duration(milliseconds: 450),
          reverseTransitionDuration: const Duration(milliseconds: 350),
          pageBuilder: (_, a, _) => FadeTransition(opacity: a, child: FullScreenQr(data: data, buddy: buddy)),
        ),
      );

  @override
  State<FullScreenQr> createState() => _FullScreenQrState();
}

class _FullScreenQrState extends State<FullScreenQr> {
  @override
  void initState() {
    super.initState();
    Bridge.call('brightness', {'value': 1.0});
  }

  @override
  void dispose() {
    Bridge.call('brightness', {'value': -1});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final side = MediaQuery.sizeOf(context).shortestSide * 0.78;
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Scaffold(
        backgroundColor: cs.surface.withValues(alpha: 0.96),
        body: SafeArea(
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              FancyQr(data: widget.data, buddy: widget.buddy, size: side),
              const SizedBox(height: 24),
              Text(s.tapToClose, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }
}
