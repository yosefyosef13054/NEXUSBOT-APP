import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/preferences.dart';
import 'chat_models.dart';
import 'chat_repository.dart';

/// Live state for a single chat screen.
class ChatState {
  const ChatState({
    required this.messages,
    required this.sending,
    this.stopping = false,
    this.useRag = true,
    this.useTools = true,
    this.error,
  });

  final List<ChatMessage> messages;

  /// A turn is in flight (request sent, final message not yet received).
  final bool sending;

  /// Stop was requested and we are waiting for the server's final message.
  final bool stopping;
  final bool useRag;
  final bool useTools;
  final String? error;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? sending,
    bool? stopping,
    bool? useRag,
    bool? useTools,
    String? error,
    bool clearError = false,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        sending: sending ?? this.sending,
        stopping: stopping ?? this.stopping,
        useRag: useRag ?? this.useRag,
        useTools: useTools ?? this.useTools,
        error: clearError ? null : (error ?? this.error),
      );

  static const empty = ChatState(messages: [], sending: false);
}

/// Reducer over [StreamEvent]s for one session.
///
/// Appends `token`s to a live buffer, attaches `citations` / `tool_call`s as
/// they arrive, swaps the optimistic user bubble for the persisted
/// `user_message`, and replaces the streaming placeholder with the canonical
/// `assistant_message` when the turn completes.
class ChatController extends StateNotifier<ChatState> {
  ChatController(this._ref, this.sessionId) : super(ChatState.empty) {
    final prefs = _ref.read(prefsProvider);
    state = state.copyWith(useRag: prefs.ragByDefault, useTools: prefs.toolsByDefault);
    unawaited(_load());
  }

  /// After a WebSocket `stop`, how long to wait for the server's final
  /// `assistant_message` before finalising the bubble locally.
  static const stopGracePeriod = Duration(seconds: 8);

  final Ref _ref;
  final String sessionId;

  ChatTurn? _turn;
  StreamSubscription<StreamEvent>? _sub;
  Timer? _stopTimeout;
  bool _stopRequested = false;

  Future<void> _load() async {
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final history = await repo.loadHistory(sessionId);
      if (!mounted) return;
      state = state.copyWith(messages: history);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(error: errorText(e));
    }
  }

  void toggleRag(bool v) => state = state.copyWith(useRag: v);
  void toggleTools(bool v) => state = state.copyWith(useTools: v);

  /// Stop the in-flight generation (the composer's stop button).
  ///
  /// * WebSocket: sends `stop` and keeps listening — the server persists the
  ///   partial text and emits `assistant_message` with `interrupted: true`,
  ///   which completes the turn like any other. A grace period guards
  ///   against a server that never answers.
  /// * SSE: closes the connection (the server persists the partial on
  ///   disconnect) and marks the bubble as stopped with the text we have.
  Future<void> stop() async {
    if (!state.sending) return;
    final turn = _turn;
    if (turn == null) {
      // Still connecting; the stop is applied as soon as the turn opens.
      _stopRequested = true;
      return;
    }
    switch (turn.transport) {
      case StreamTransport.websocket:
        if (state.stopping) return;
        state = state.copyWith(stopping: true);
        await turn.stop();
        _stopTimeout = Timer(stopGracePeriod, _finishInterruptedLocally);
      case StreamTransport.sse:
        await _closeTurn();
        _finishInterruptedLocally();
    }
  }

  Future<void> send(String content) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty || state.sending) return;
    _stopRequested = false;

    // Optimistically append the user message + a streaming placeholder.
    final optimisticUser = ChatMessage(
      id: 'pending-user-${DateTime.now().microsecondsSinceEpoch}',
      sessionId: sessionId,
      role: MessageRole.user,
      content: trimmed,
      createdAt: DateTime.now(),
    );
    final placeholder = ChatMessage.streamingPlaceholder(sessionId: sessionId);
    state = state.copyWith(
      sending: true,
      stopping: false,
      clearError: true,
      messages: [...state.messages, optimisticUser, placeholder],
    );

    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final prefs = _ref.read(prefsProvider);

      // Non-streaming path — fall through to the regular POST endpoint.
      if (!prefs.streamingEnabled) {
        final assistant = await repo.sendBlocking(
          sessionId: sessionId,
          content: trimmed,
          useRag: state.useRag,
          useTools: state.useTools,
        );
        if (!mounted) return;
        _replaceLastAssistant((_) => assistant);
        state = state.copyWith(sending: false);
        _scheduleTitleRefresh();
        return;
      }

      final turn = await repo.streamMessage(
        sessionId: sessionId,
        content: trimmed,
        transport: prefs.transport,
        useRag: state.useRag,
        useTools: state.useTools,
      );
      if (!mounted) {
        await turn.close();
        return;
      }
      _turn = turn;

      final buffer = StringBuffer();
      final tools = <ToolCall>[];
      _sub = turn.events.listen(
        (event) => _onEvent(event, buffer, tools),
        onDone: () {
          // Stream ended without a terminal event (connection dropped).
          if (!mounted || !state.sending) return;
          _replaceLastAssistant((m) => m.copyWith(streaming: false));
          state = state.copyWith(sending: false, stopping: false);
        },
        onError: (Object e) {
          if (!mounted) return;
          _replaceLastAssistant((m) => m.copyWith(streaming: false));
          state = state.copyWith(sending: false, stopping: false, error: errorText(e));
        },
      );

      if (_stopRequested) {
        _stopRequested = false;
        await stop();
      }
    } catch (e) {
      if (!mounted) return;
      _removeEmptyPlaceholder();
      state = state.copyWith(sending: false, stopping: false, error: errorText(e));
    }
  }

  void _onEvent(StreamEvent event, StringBuffer buffer, List<ToolCall> tools) {
    switch (event) {
      case TokenEvent(:final token):
        buffer.write(token);
        _replaceLastAssistant(
          (m) => m.copyWith(content: buffer.toString(), streaming: true),
        );
      case CitationsEvent(:final citations):
        _replaceLastAssistant((m) => m.copyWith(citations: citations));
      case ToolCallEvent():
        // Lifecycle frames: only the `end` (or a single frame) carries output.
        if (event.phase == null || event.phase == 'end') {
          tools.add(event.toToolCall());
          _replaceLastAssistant((m) => m.copyWith(toolCalls: List.of(tools)));
        }
      case UserMessageEvent():
        _replaceFirstPendingUser(event);
      case DoneEvent(:final text, :final interrupted):
        // `done` carries the full text; trust it over our token buffer.
        if (text != null && text.isNotEmpty) {
          buffer
            ..clear()
            ..write(text);
        }
        _replaceLastAssistant(
          (m) => m.copyWith(
            content: text == null || text.isEmpty ? m.content : text,
            interrupted: interrupted || m.interrupted,
          ),
        );
      case AssistantMessageEvent():
        // Final canonical version straight from the server.
        _stopTimeout?.cancel();
        _stopTimeout = null;
        _replaceLastAssistant((_) => event.toMessage(sessionId));
        state = state.copyWith(sending: false, stopping: false);
        _scheduleTitleRefresh();
      case ErrorEvent(:final message, :final isBusy):
        final text = isBusy
            ? 'The assistant is still answering a previous message — wait for it to finish.'
            : message;
        _stopTimeout?.cancel();
        _stopTimeout = null;
        _removeEmptyPlaceholder();
        _replaceLastAssistant((m) => m.copyWith(streaming: false));
        state = state.copyWith(sending: false, stopping: false, error: text);
      case UsageEvent():
      case UnknownEvent():
        break;
    }
  }

  void _finishInterruptedLocally() {
    _stopTimeout?.cancel();
    _stopTimeout = null;
    unawaited(_closeTurn());
    if (!mounted) return;
    _replaceLastAssistant((m) => m.copyWith(streaming: false, interrupted: true));
    state = state.copyWith(sending: false, stopping: false);
    _scheduleTitleRefresh();
  }

  Future<void> _closeTurn() async {
    final sub = _sub;
    final turn = _turn;
    _sub = null;
    _turn = null;
    await sub?.cancel();
    await turn?.close();
  }

  /// Titles are generated server-side after the stream closes; re-fetch the
  /// session list a moment later so the sidebar picks the title up.
  void _scheduleTitleRefresh() {
    _ref.read(sessionListRefresherProvider).scheduleRefresh();
  }

  void _replaceLastAssistant(ChatMessage Function(ChatMessage) update) {
    final msgs = List<ChatMessage>.of(state.messages);
    for (var i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].role == MessageRole.assistant) {
        msgs[i] = update(msgs[i]);
        state = state.copyWith(messages: msgs);
        return;
      }
    }
  }

  /// Drops a streaming placeholder that never received any text (the turn
  /// failed before the model produced anything).
  void _removeEmptyPlaceholder() {
    final msgs = state.messages;
    if (msgs.isEmpty) return;
    final last = msgs.last;
    if (last.role == MessageRole.assistant && last.streaming && last.content.isEmpty) {
      state = state.copyWith(messages: msgs.sublist(0, msgs.length - 1));
    }
  }

  void _replaceFirstPendingUser(UserMessageEvent event) {
    final msgs = List<ChatMessage>.of(state.messages);
    for (var i = 0; i < msgs.length; i++) {
      if (msgs[i].id.startsWith('pending-user-')) {
        msgs[i] = event.toMessage(sessionId, fallbackCreatedAt: msgs[i].createdAt);
        state = state.copyWith(messages: msgs);
        return;
      }
    }
  }

  Future<void> regenerate() async {
    if (state.sending) return;
    state = state.copyWith(sending: true, clearError: true);
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final msg = await repo.regenerate(sessionId);
      if (!mounted) return;
      _replaceLastAssistant((_) => msg);
      state = state.copyWith(sending: false);
      _scheduleTitleRefresh();
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(sending: false, error: errorText(e));
    }
  }

  @override
  void dispose() {
    _stopTimeout?.cancel();
    unawaited(_closeTurn());
    super.dispose();
  }
}

final chatControllerProvider =
    StateNotifierProvider.autoDispose.family<ChatController, ChatState, String>(
  (ref, sessionId) => ChatController(ref, sessionId),
);
