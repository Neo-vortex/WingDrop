import 'dart:async';
import 'dart:convert';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/bridge.dart';

class ChatMsg {
  ChatMsg(Map<String, dynamic> j)
      : seq = j['seq'] as int,
        session = j['session'] as int,
        mine = j['mine'] as bool,
        buddy = j['buddy'] as int,
        nick = j['nick'] as String,
        text = j['text'] as String;

  final int seq, session, buddy;
  final bool mine;
  final String nick, text;
}

class ChatState {
  const ChatState({this.messages = const [], this.unread = 0, this.canSend = false});

  final List<ChatMsg> messages;
  final int unread;

  /// True while a transfer's connection is open (chat rides on it).
  final bool canSend;
}

/// Chat while files move: polls the engine gently, counts unread lines while
/// the sheet is closed, and hands new incoming lines to [onIncoming].
class ChatCubit extends Cubit<ChatState> {
  ChatCubit() : super(const ChatState()) {
    _timer = Timer.periodic(const Duration(milliseconds: 600), (_) => _poll());
  }

  Timer? _timer;
  int _since = 0;
  bool open = false;
  void Function(ChatMsg m)? onIncoming;

  Future<void> _poll() async {
    final raw = await Bridge.call<String>('chatLog', {'since': _since});
    final stats = await Bridge.stats();
    if (isClosed) return;
    final fresh = raw == null ? const <ChatMsg>[] : [for (final j in jsonDecode(raw) as List) ChatMsg(j as Map<String, dynamic>)];
    fresh.sort((a, b) => a.seq.compareTo(b.seq));
    if (fresh.isNotEmpty) _since = fresh.last.seq;
    final incoming = fresh.where((m) => !m.mine).toList();
    if (!open) {
      for (final m in incoming) {
        onIncoming?.call(m);
      }
    }
    final canSend = stats.sessions.any((x) => x.active);
    if (fresh.isEmpty && canSend == state.canSend) return;
    emit(ChatState(
      messages: [...state.messages, ...fresh],
      unread: open ? 0 : state.unread + incoming.length,
      canSend: canSend,
    ));
  }

  Future<bool> send(String text) async {
    final t = text.trim();
    if (t.isEmpty) return false;
    final n = await Bridge.call<int>('chat', {'session': 0, 'text': t}) ?? 0;
    await _poll();
    return n > 0;
  }

  void setOpen(bool v) {
    open = v;
    if (v) emit(ChatState(messages: state.messages, canSend: state.canSend));
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
