import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/chat_cubit.dart';
import '../core/avatars.dart';
import '../l10n/strings.dart';
import 'common.dart';
import 'radar.dart' show peerName;

/// A small chat bubble button with an unread badge. Incoming lines show as a
/// quiet banner while the chat is closed.
class ChatButton extends StatelessWidget {
  const ChatButton({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<ChatCubit>().state;
    final s = context.s;
    final cs = Theme.of(context).colorScheme;
    return Badge(
      isLabelVisible: st.unread > 0,
      label: Text(s.n(st.unread)),
      child: FilledButton.tonalIcon(
        onPressed: () => openChat(context),
        icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
        label: Text(s.chat),
        style: FilledButton.styleFrom(minimumSize: const Size(0, 40), foregroundColor: cs.onSecondaryContainer),
      ),
    );
  }
}

Future<void> openChat(BuildContext context) async {
  final cubit = context.read<ChatCubit>();
  cubit.setOpen(true);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BlocProvider.value(value: cubit, child: const _ChatSheet()),
  );
  cubit.setOpen(false);
}

class _ChatSheet extends StatefulWidget {
  const _ChatSheet();

  @override
  State<_ChatSheet> createState() => _ChatSheetState();
}

class _ChatSheetState extends State<_ChatSheet> {
  final _text = TextEditingController();
  static const _quick = ['😀', '👍', '❤️', '🎉', '🙏', '😂', '🔥', '✨', '👋', '😍'];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send([String? v]) async {
    final text = v ?? _text.text;
    if (text.trim().isEmpty) return;
    final ok = await context.read<ChatCubit>().send(text);
    if (ok && v == null) _text.clear();
    if (!ok && mounted) toast(context, context.s.chatClosed);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final st = context.watch<ChatCubit>().state;
    final msgs = st.messages.reversed.toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.62,
        child: Column(children: [
          Text(s.chat, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Expanded(
            child: msgs.isEmpty
                ? Center(child: Text(s.chatEmpty, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center))
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: msgs.length,
                    itemBuilder: (context, i) => FadeIn(key: ValueKey(msgs[i].seq), child: _Bubble(m: msgs[i])),
                  ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final e in _quick)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: st.canSend ? () => _send(e) : null,
                      child: Padding(padding: const EdgeInsets.all(6), child: Text(e, style: const TextStyle(fontSize: 24))),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    enabled: st.canSend,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: st.canSend ? s.chatHint : s.chatClosed,
                      filled: true,
                      fillColor: cs.surfaceContainerHigh,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(onPressed: st.canSend ? () => _send() : null, icon: const Icon(Icons.send_rounded)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.m});

  final ChatMsg m;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.7),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: m.mine ? cs.primaryContainer : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(m.text, style: t.bodyLarge?.copyWith(color: m.mine ? cs.onPrimaryContainer : cs.onSurface)),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: m.mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: m.mine
            ? [bubble]
            : [
                Tooltip(message: peerName(s, m.buddy, m.nick), child: BuddyAvatar(index: m.buddy, size: 30)),
                const SizedBox(width: 8),
                bubble,
              ],
      ),
    );
  }
}

/// Shows a quiet banner for a line that arrived while the chat was closed.
void chatBanner(BuildContext context, ChatMsg m) {
  final s = context.s;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(children: [
        BuddyAvatar(index: m.buddy, size: 28),
        const SizedBox(width: 10),
        Expanded(child: Text('${peerName(s, m.buddy, m.nick)}: ${m.text}', maxLines: 2, overflow: TextOverflow.ellipsis)),
      ]),
      action: SnackBarAction(label: s.reply, onPressed: () => openChat(context)),
      duration: const Duration(seconds: 4),
    ));
}
