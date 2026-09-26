import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/app_cubit.dart';
import '../blocs/send_cubit.dart';
import '../core/bridge.dart';
import '../core/settings.dart';
import '../l10n/strings.dart';
import '../core/avatars.dart';
import 'common.dart';
import 'permissions.dart';
import 'nerd_log.dart';
import 'radar.dart';
import 'transfer_view.dart';

class SendPage extends StatelessWidget {
  const SendPage({super.key, required this.items});

  final List<SendItem> items;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => SendCubit(items, context.read<AppCubit>().state.settings)..begin(),
      child: const _SendView(),
    );
  }
}

class _SendView extends StatelessWidget {
  const _SendView();

  Future<void> _scan(BuildContext context) async {
    final cubit = context.read<SendCubit>();
    final s = context.s;
    final dark = Theme.of(context).brightness == Brightness.dark;
    await maybeAskNotifications(context);
    if (!context.mounted) return;
    if (!await ensurePermission(context, 'camera')) {
      cubit.cameraDenied();
      return;
    }
    String? raw;
    try {
      raw = await Bridge.call<String>('scanQr', {'hint': s.pointAtCode, 'fa': s.fa, 'dark': dark});
    } on PlatformException catch (e) {
      // The camera couldn't start: say so instead of silently doing nothing.
      cubit.cameraFailed(e.message ?? e.code);
      return;
    }
    if (!context.mounted) return;
    await cubit.connect(raw, () => ensurePermission(context, 'nearby'));
  }

  Future<bool> _confirmStop(BuildContext context) async {
    final s = context.s;
    final stop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.stopSendingQ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.keepGoing)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(s.stop)),
        ],
      ),
    );
    if (stop == true && context.mounted) await context.read<SendCubit>().cancel();
    return stop == true;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final st = context.watch<SendCubit>().state;

    final Widget body = switch (st.step) {
      SendStep.askShrink => _Centered(
          key: const ValueKey('shrink'),
          children: [
            Icon(Icons.compress_rounded, size: 56, color: cs.primary),
            const SizedBox(height: 20),
            Text(s.shrinkTitle(st.mediaCount), style: t.titleLarge?.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(s.shrinkBody, style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
            const SizedBox(height: 28),
            _Choice(
              icon: Icons.auto_awesome_rounded,
              title: s.shrinkOriginal,
              subtitle: s.shrinkOriginalSub,
              highlighted: true,
              onTap: () => context.read<SendCubit>().shrinkChoice(null),
            ),
            const SizedBox(height: 10),
            _Choice(
              icon: Icons.compress_rounded,
              title: s.shrinkLight,
              subtitle: s.shrinkLightSub,
              onTap: () => context.read<SendCubit>().shrinkChoice(0),
            ),
            const SizedBox(height: 10),
            _Choice(
              icon: Icons.air_rounded,
              title: s.shrinkSmall,
              subtitle: s.shrinkSmallSub,
              onTap: () => context.read<SendCubit>().shrinkChoice(1),
            ),
          ],
        ),
      SendStep.shrinking => _Centered(
          key: const ValueKey('shrinking'),
          children: [
            SizedBox(width: 220, child: GlideBar(value: st.convertProgress)),
            const SizedBox(height: 24),
            Text(s.shrinking, style: t.titleMedium),
            const SizedBox(height: 6),
            Text(s.shrinkingSub, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
      SendStep.askHeic => _Centered(
          key: const ValueKey('heic'),
          children: [
            Icon(Icons.photo_outlined, size: 56, color: cs.primary),
            const SizedBox(height: 20),
            Text(s.heicTitle(st.heicCount), style: t.titleLarge?.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(s.heicBody, style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: () => context.read<SendCubit>().heicChoice(true), child: Text(s.heicConvert)),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(onPressed: () => context.read<SendCubit>().heicChoice(false), child: Text(s.heicKeep)),
            ),
          ],
        ),
      SendStep.converting => _Centered(
          key: const ValueKey('conv'),
          children: [
            SizedBox(width: 220, child: GlideBar(value: st.convertProgress)),
            const SizedBox(height: 24),
            Text(s.converting, style: t.titleMedium),
            const SizedBox(height: 6),
            Text(s.convertingSub, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
      SendStep.scanning => ListView(
          key: const ValueKey('scan'),
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          children: [
            _PrepLine(state: st),
            DiscoveryRadar(
              onPick: (picked) async {
                final cubit = context.read<SendCubit>();
                await maybeAskNotifications(context);
                if (!context.mounted) return;
                await cubit.sendTo(
                  [for (final (p, trusted) in picked) Target(p, trusted: trusted)],
                  () => ensurePermission(context, 'nearby'),
                );
              },
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () => _scan(context),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(s.orScan),
            ),
          ],
        ),
      SendStep.wifiOff => _Centered(
          key: const ValueKey('wifi'),
          children: [
            Breathing(child: Icon(Icons.wifi_off_rounded, size: 64, color: cs.primary)),
            const SizedBox(height: 22),
            Text(s.senderWifiOffTitle, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(s.senderWifiOffBody, style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: () => Bridge.call('wifiSettings'),
              icon: const Icon(Icons.wifi_rounded),
              label: Text(s.turnOnWifi),
            ),
          ],
        ),
      SendStep.joining => _Centered(
          key: const ValueKey('join'),
          children: [
            Breathing(
              child: Icon(
                switch (st.stage) {
                  'system_prompt' => Icons.touch_app_rounded,
                  'shrinking' => Icons.compress_rounded,
                  _ => Icons.wifi_tethering_rounded,
                },
                size: 72,
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 24),
            SoftText(_stageText(s, st), style: t.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            if (st.stage == 'shrinking') ...[
              // Everything picked needs shrinking: nothing can go before it's
              // done, so show how far along it is rather than a clock.
              const SizedBox(height: 8),
              SizedBox(width: 220, child: GlideBar(value: st.convertProgress)),
              const SizedBox(height: 10),
              SoftText(
                s.shrinkingRestSub((st.convertProgress * 100).round()),
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ] else ...[
              _Elapsed(since: st.stageSince),
              const SizedBox(height: 16),
              _PrepLine(state: st),
            ],
            const SizedBox(height: 28),
            TextButton(onPressed: () => context.read<SendCubit>().cancelConnect(), child: Text(s.cancel)),
          ],
        ),
      SendStep.error => _Centered(
          key: const ValueKey('err'),
          children: [
            Icon(_errorIcon(st.error), size: 60, color: cs.error),
            const SizedBox(height: 20),
            Text(_errorTitle(s, st), style: t.titleLarge?.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(_errorBody(s, st), style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
            const SizedBox(height: 26),
            if (st.targets.isNotEmpty && st.error != SendError.declined && st.error != SendError.peerOutdated &&
                st.error != SendError.selfOutdated)
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: () => context.read<SendCubit>().retryConnect(), child: Text(s.tryAgain)),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(onPressed: () => context.read<SendCubit>().backToPicking(), child: Text(s.pickAnother)),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NerdLogPage())),
              child: Text(s.showDetails),
            ),
          ],
        ),
      SendStep.transferring || SendStep.finished => SingleChildScrollView(
          key: const ValueKey('xfer'),
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            if (st.peer != null) ...[PeerHeader(peer: st.peer!), const SizedBox(height: 16)],
            if (st.targets.length > 1) ...[_Targets(targets: st.targets), const SizedBox(height: 16)],
            TransferView(
              // Keyed by the sessions themselves: finishing doesn't rebuild the
              // view (and throw away the graph); a new session does.
              key: ValueKey(st.targets.map((t) => t.session).join(',')),
              sending: true,
              connectingText: st.peer == null ? null : s.waitingFor(peerName(s, st.peer!.buddy, st.peer!.nick)),
              onRetry: () => context.read<SendCubit>().retry(),
              onFinished: (stats) => context.read<SendCubit>().finished(),
              preparing: st.preparing,
              prepProgress: st.convertProgress,
            ),
            if (st.step == SendStep.finished) ...[
              const SizedBox(height: 24),
              FadeIn(
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                    child: Text(s.done),
                  ),
                ),
              ),
            ],
          ]),
        ),
    };

    final busy = st.step == SendStep.transferring;
    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmStop(context) && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(s.sendingN(st.items.length)), actions: const [NerdLogButton()]),
        body: AnimatedSwitcher(
          duration: kSoft,
          switchInCurve: kEase,
          layoutBuilder: fullWidthLayout,
          transitionBuilder: (child, a) => FadeTransition(opacity: a, child: child),
          child: body,
        ),
      ),
    );
  }
}

String _stageText(S s, SendState st) {
  final who = st.peer == null ? s.theOtherPhone : peerName(s, st.peer!.buddy, st.peer!.nick);
  return switch (st.stage) {
    'fallback' => s.stageFallback,
    'system_prompt' => s.stageSystemPrompt,
    'joined' || 'reaching' => s.stageReaching(who),
    'approval' => s.waitingFor(who),
    'shrinking' => s.shrinking,
    _ => s.stageJoining(who),
  };
}

IconData _errorIcon(SendError e) => switch (e) {
      SendError.peerOutdated || SendError.selfOutdated => Icons.system_update_rounded,
      SendError.needCamera || SendError.cameraFailed => Icons.no_photography_outlined,
      SendError.declined => Icons.do_not_disturb_on_outlined,
      _ => Icons.cloud_off_rounded,
    };

String _errorTitle(S s, SendState st) => switch (st.error) {
      SendError.notOurCode => s.notOurCode,
      SendError.needNearby => s.needNearby,
      SendError.needCamera => s.needCamera,
      SendError.cameraFailed => s.errCameraTitle,
      SendError.declined => s.declined,
      SendError.vpn => s.errVpnTitle,
      SendError.joinFailed => s.errJoinTitle,
      SendError.unreachable => s.errUnreachableTitle,
      SendError.refused => s.errRefusedTitle,
      SendError.peerOutdated => s.errPeerOutdatedTitle,
      SendError.selfOutdated => s.errSelfOutdatedTitle,
      SendError.noAnswer => s.errNoAnswerTitle,
      _ => s.errGenericTitle,
    };

String _errorBody(S s, SendState st) => switch (st.error) {
      SendError.cameraFailed => s.errCameraBody,
      SendError.vpn => s.vpnHint,
      SendError.joinFailed => s.errJoinBody,
      SendError.unreachable => s.errUnreachableBody,
      SendError.refused => s.errRefusedBody,
      SendError.peerOutdated => s.errPeerOutdatedBody,
      SendError.selfOutdated => s.errSelfOutdatedBody,
      SendError.noAnswer => s.errNoAnswerBody,
      SendError.other => st.message,
      _ => '',
    };

/// Seconds spent in the current stage, shown only once it takes a while.
class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.since});

  final DateTime? since;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  late final Timer _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final since = widget.since;
    final secs = since == null ? 0 : DateTime.now().difference(since).inSeconds;
    final t = Theme.of(context).textTheme;
    return AnimatedOpacity(
      opacity: secs >= 5 ? 1 : 0,
      duration: kSoft,
      child: Text(context.s.n('${secs}s'), style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
  }
}

/// The connection log, for "what actually happened?". Copyable.
Future<void> showDiagnostics(BuildContext context) async {
  final text = await Bridge.call<String>('diag') ?? '';
  if (!context.mounted) return;
  final s = context.s;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(child: Text(s.connectionLog, style: Theme.of(context).textTheme.titleMedium)),
              TextButton.icon(
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(s.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  toast(context, s.copied);
                },
              ),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              reverse: true,
              padding: const EdgeInsets.all(16),
              child: SelectableText(text, textDirection: TextDirection.ltr, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.4)),
            ),
          ),
        ]),
      ),
    ),
  );
}

/// Several phones: each gets a row with its buddy and where it's at.
class _Targets extends StatelessWidget {
  const _Targets({required this.targets});

  final List<Target> targets;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.sendingTo(targets.length), style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(s.oneAfterAnother, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 12),
          for (final x in targets)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                BuddyAvatar(index: x.pairing.buddy, size: 34),
                const SizedBox(width: 12),
                Expanded(child: Text(peerName(s, x.pairing.buddy, x.pairing.nick), style: t.bodyLarge)),
                AnimatedSwitcher(
                  duration: kSoft,
                  child: switch (x.state) {
                    TargetState.done => Icon(Icons.check_circle_rounded, key: const ValueKey('d'), color: cs.primary),
                    TargetState.sending || TargetState.joining => Breathing(
                        key: const ValueKey('s'),
                        child: Icon(Icons.north_east_rounded, color: cs.primary),
                      ),
                    TargetState.waiting => Text(s.waitingTurn, key: const ValueKey('w'), style: t.bodySmall),
                    _ => Icon(Icons.pause_circle_outline_rounded, key: const ValueKey('f'), color: cs.error),
                  },
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// A tappable option card. The highlighted one is the recommended default.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final fg = highlighted ? cs.onPrimaryContainer : cs.onSurface;
    return Material(
      color: highlighted ? cs.primaryContainer : cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      shape: highlighted
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: cs.primary, width: 1.5))
          : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(children: [
            Icon(icon, color: highlighted ? cs.onPrimaryContainer : cs.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: fg)),
                const SizedBox(height: 2),
                Text(subtitle, style: t.bodySmall?.copyWith(color: fg.withValues(alpha: 0.75))),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, color: fg.withValues(alpha: 0.6)),
          ]),
        ),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      );
}

/// "Shrinking 3 files in the background · 45%": a quiet line while the
/// person picks a phone or the ready files are already on their way.
class _PrepLine extends StatelessWidget {
  const _PrepLine({required this.state});

  final SendState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: kSoft,
      curve: kEase,
      child: state.preparing == 0
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.compress_rounded, size: 16, color: cs.primary),
                  const SizedBox(width: 6),
                  Flexible(
                    child: SoftText(
                      context.s.prepLine(state.preparing, (state.convertProgress * 100).round()),
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                SizedBox(width: 180, child: GlideBar(value: state.convertProgress, height: 4)),
              ]),
            ),
    );
  }
}
