import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/preferences.dart';
import '../tools/tools_repository.dart';
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
    this.session,
    this.modelOverride,
    this.collectionIds,
    this.toolNames,
  });

  final List<ChatMessage> messages;

  /// A turn is in flight (request sent, final message not yet received).
  final bool sending;

  /// Stop was requested and we are waiting for the server's final message.
  final bool stopping;
  final bool useRag;
  final bool useTools;
  final String? error;

  /// `GET /sessions/{id}` — carries the session model and metadata. Null
  /// until loaded (or when the fetch failed; the header then falls back to
  /// the session list).
  final ChatSession? session;

  /// Model picked in the composer chip; sent as `model` on every turn until
  /// cleared. Null = the session's model / the user's default.
  final String? modelOverride;

  /// Knowledge scope (`collection_ids`) sent on each turn — mirrors
  /// `session.meta.collection_ids`. Null = all of the user's documents.
  final List<String>? collectionIds;

  /// Tools picked for this chat (persisted per session on this device).
  /// Null = the default selection, see [ChatController.effectiveToolNames].
  final List<String>? toolNames;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? sending,
    bool? stopping,
    bool? useRag,
    bool? useTools,
    String? error,
    bool clearError = false,
    ChatSession? session,
    String? modelOverride,
    bool clearModelOverride = false,
    List<String>? collectionIds,
    bool clearCollectionIds = false,
    List<String>? toolNames,
    bool clearToolNames = false,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        sending: sending ?? this.sending,
        stopping: stopping ?? this.stopping,
        useRag: useRag ?? this.useRag,
        useTools: useTools ?? this.useTools,
        error: clearError ? null : (error ?? this.error),
        session: session ?? this.session,
        modelOverride: clearModelOverride ? null : (modelOverride ?? this.modelOverride),
        collectionIds: clearCollectionIds ? null : (collectionIds ?? this.collectionIds),
        toolNames: clearToolNames ? null : (toolNames ?? this.toolNames),
      );

  static const empty = ChatState(messages: [], sending: false);
}

/// Lines the history up with the authoritative pending list
/// (`GET /sessions/{id}/approvals?status=pending`):
///
/// * a pending approval whose message is in the list is attached to it (and
///   the message is flagged `awaiting_approval`) — covers history rows that
///   lost their `meta.approval`;
/// * a message whose approval is *not* pending any more loses its buttons:
///   it is marked `expired` when past `expires_at`, `resolved` otherwise.
List<ChatMessage> reconcileApprovals(
  List<ChatMessage> messages,
  List<ApprovalRequest> pending, {
  DateTime? now,
}) {
  final byMessage = {for (final a in pending) a.messageId: a};
  final pendingIds = {for (final a in pending) a.approvalId};
  final clock = now ?? DateTime.now();
  return [
    for (final m in messages)
      if (m.role != MessageRole.assistant)
        m
      else if (byMessage[m.id] case final a?)
        m.copyWith(approval: a.copyWith(status: 'pending'), status: MessageStatus.awaitingApproval)
      else if (m.approval case final a? when a.isPending && !pendingIds.contains(a.approvalId))
        m.copyWith(
          approval: a.copyWith(
            status: a.expiresAt != null && a.expiresAt!.isBefore(clock) ? 'expired' : 'resolved',
          ),
        )
      else
        m,
  ];
}

/// Mutable bookkeeping for one streamed turn: which bubble the events land
/// in, the accumulated text and the tool runs seen so far.
class _TurnContext {
  _TurnContext({
    required this.targetId,
    String initialText = '',
    List<ToolCall> tools = const [],
    this.approval,
  })  : buffer = StringBuffer(initialText),
        tools = List.of(tools);

  /// Id of the message the events are applied to (the streaming
  /// placeholder, or the persisted placeholder of an approval continuation).
  final String targetId;
  final StringBuffer buffer;
  List<ToolCall> tools;

  /// Set when this turn continues a paused one; restored on failure so the
  /// user can try again.
  final ApprovalRequest? approval;

  bool get isApprovalContinuation => approval != null;
}

/// Reducer over [StreamEvent]s for one session.
///
/// Appends `token`s to a live buffer, attaches `citations` / `tool_call`s as
/// they arrive, swaps the optimistic user bubble for the persisted
/// `user_message`, and replaces the streaming placeholder with the canonical
/// `assistant_message` when the turn completes. An `approval_required` turn
/// ends with the card attached to the bubble; resolving it streams the
/// continuation into that same bubble (matched on the message id).
class ChatController extends StateNotifier<ChatState> {
  ChatController(this._ref, this.sessionId) : super(ChatState.empty) {
    final prefs = _ref.read(prefsProvider);
    state = state.copyWith(
      useRag: prefs.ragByDefault,
      useTools: prefs.toolsByDefault,
      toolNames: _ref.read(sessionPrefsProvider).toolNames(sessionId),
    );
    unawaited(_load());
  }

  /// After a WebSocket `stop`, how long to wait for the server's final
  /// `assistant_message` before finalising the bubble locally.
  static const stopGracePeriod = Duration(seconds: 8);

  static const _staleApprovalMessage =
      'That approval was already resolved or has expired — the chat was refreshed.';

  final Ref _ref;
  final String sessionId;

  ChatTurn? _turn;
  StreamSubscription<StreamEvent>? _sub;
  _TurnContext? _ctx;
  Timer? _stopTimeout;
  bool _stopRequested = false;

  Future<void> _load() async {
    final ChatRepository repo;
    try {
      repo = await _ref.read(chatRepositoryProvider.future);
      final history = await repo.loadHistory(sessionId);
      if (!mounted) return;
      state = state.copyWith(messages: history);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(error: errorText(e));
      return;
    }
    await _loadSession(repo);
    await _reconcileApprovals(repo);
  }

  Future<void> _loadSession(ChatRepository repo) async {
    try {
      final session = await repo.getSession(sessionId);
      if (!mounted) return;
      final ids = session.collectionIds;
      state = state.copyWith(session: session, collectionIds: ids, clearCollectionIds: ids == null);
    } catch (_) {
      // Non-fatal: the header falls back to the session list and the
      // knowledge scope stays "all documents".
    }
  }

  Future<void> _reconcileApprovals(ChatRepository repo) async {
    final List<ApprovalRequest> pending;
    try {
      pending = await repo.listPendingApprovals(sessionId);
    } catch (_) {
      return; // `meta.approval` on the history rows is the best we have.
    }
    if (!mounted) return;
    state = state.copyWith(messages: reconcileApprovals(state.messages, pending));
  }

  /// Re-fetches history, session and pending approvals (drops any in-flight turn).
  Future<void> reload() async {
    await _closeTurn();
    _ctx = null;
    if (!mounted) return;
    state = state.copyWith(sending: false, stopping: false);
    await _load();
  }

  void toggleRag(bool v) => state = state.copyWith(useRag: v);
  void toggleTools(bool v) => state = state.copyWith(useTools: v);

  /// Per-turn model override (null = session / default model).
  void setModelOverride(String? modelId) =>
      state = state.copyWith(modelOverride: modelId, clearModelOverride: modelId == null);

  /// The chat's tool selection; persisted per session on this device.
  Future<void> setToolNames(List<String>? names) async {
    state = state.copyWith(toolNames: names, clearToolNames: names == null);
    await _ref.read(sessionPrefsProvider).setToolNames(sessionId, names);
  }

  /// `tool_names` for the next turn: the picker's selection (filtered to
  /// tools the server still lists), else the default — every tool that runs
  /// without approval. Null when tools are off or the catalog is unknown /
  /// empty (the server then applies its own default).
  List<String>? get effectiveToolNames {
    if (!state.useTools) return null;
    final catalog = _ref.read(toolCatalogProvider).valueOrNull;
    final picked = state.toolNames;
    if (catalog == null) return picked;
    if (catalog.isEmpty) return null;
    final known = {for (final t in catalog) t.name};
    if (picked != null) return picked.where(known.contains).toList();
    return defaultToolSelection(catalog);
  }

  /// Switches the session's model (`PATCH /sessions/{id} {model}`).
  Future<void> setSessionModel(String modelId) async {
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final updated = await repo.updateSession(sessionId, model: modelId);
      if (!mounted) return;
      state = state.copyWith(session: updated, clearError: true);
      _ref.invalidate(sessionListProvider);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(error: errorText(e));
    }
  }

  /// Sets the chat's knowledge scope: saved as the session default
  /// (`PATCH /sessions/{id} {"meta": {"collection_ids": [...]}}`) and sent
  /// as `collection_ids` on each turn. Null = all documents.
  Future<void> setCollectionIds(List<String>? ids) async {
    final previous = state.collectionIds;
    state = state.copyWith(collectionIds: ids, clearCollectionIds: ids == null, clearError: true);
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final meta = <String, dynamic>{...?state.session?.meta, 'collection_ids': ids};
      final updated = await repo.updateSession(sessionId, meta: meta);
      if (!mounted) return;
      state = state.copyWith(session: updated);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        collectionIds: previous,
        clearCollectionIds: previous == null,
        error: errorText(e),
      );
    }
  }

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

    final toolNames = effectiveToolNames;
    final model = state.modelOverride;
    final collectionIds = state.collectionIds;

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
          toolNames: toolNames,
          model: model,
          collectionIds: collectionIds,
        );
        if (!mounted) return;
        _finishBlockingTurn(placeholder.id, assistant);
        return;
      }

      final turn = await repo.streamMessage(
        sessionId: sessionId,
        content: trimmed,
        transport: prefs.transport,
        useRag: state.useRag,
        useTools: state.useTools,
        toolNames: toolNames,
        model: model,
        collectionIds: collectionIds,
      );
      if (!mounted) {
        await turn.close();
        return;
      }
      _listen(turn, _TurnContext(targetId: placeholder.id));

      if (_stopRequested) {
        _stopRequested = false;
        await stop();
      }
    } catch (e) {
      if (!mounted) return;
      _dropEmptyStreaming(placeholder.id);
      state = state.copyWith(sending: false, stopping: false, error: errorText(e));
    }
  }

  /// Answers a pending approval. The continuation streams into the same
  /// bubble: the server's final `assistant_message.data.id` equals the
  /// placeholder's id. A 409 / 404 (already resolved, expired, unknown)
  /// refreshes the chat instead.
  Future<void> resolveApproval(String approvalId, ApprovalDecision decision) async {
    if (state.sending) return;
    final index = state.messages.indexWhere((m) => m.approval?.approvalId == approvalId);
    if (index < 0) return;
    final original = state.messages[index];
    _stopRequested = false;

    // The card collapses right away and the bubble shows activity.
    _replaceById(
      original.id,
      (m) => m.copyWith(clearApproval: true, clearStatus: true, streaming: true),
    );
    state = state.copyWith(sending: true, stopping: false, clearError: true);

    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final prefs = _ref.read(prefsProvider);
      final turn = await repo.resolveApproval(
        sessionId: sessionId,
        approvalId: approvalId,
        decision: decision,
        transport: prefs.transport,
      );
      if (!mounted) {
        await turn.close();
        return;
      }
      _listen(
        turn,
        _TurnContext(
          targetId: original.id,
          initialText: original.content,
          tools: original.toolCalls,
          approval: original.approval,
        ),
      );
      if (_stopRequested) {
        _stopRequested = false;
        await stop();
      }
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && _isStaleApproval(e)) {
        state = state.copyWith(sending: false, stopping: false, error: _staleApprovalMessage);
        await reload();
        return;
      }
      // Give the card back so the user can retry.
      _replaceById(
        original.id,
        (m) => m.copyWith(
          approval: original.approval,
          status: MessageStatus.awaitingApproval,
          streaming: false,
        ),
      );
      state = state.copyWith(sending: false, stopping: false, error: errorText(e));
    }
  }

  static bool _isStaleApproval(ApiException e) =>
      e.statusCode == 409 || e.statusCode == 404 || e.code == 'conflict' || e.code == 'not_found';

  void _listen(ChatTurn turn, _TurnContext ctx) {
    _turn = turn;
    _ctx = ctx;
    _sub = turn.events.listen(
      (event) => _onEvent(ctx, event),
      onDone: () {
        // Stream ended without a terminal event (connection dropped).
        if (!mounted || !state.sending || _ctx != ctx) return;
        _update(ctx, (m) => m.copyWith(streaming: false));
        _ctx = null;
        state = state.copyWith(sending: false, stopping: false);
      },
      onError: (Object e) {
        if (!mounted) return;
        _update(ctx, (m) => m.copyWith(streaming: false));
        _ctx = null;
        state = state.copyWith(sending: false, stopping: false, error: errorText(e));
      },
    );
  }

  void _onEvent(_TurnContext ctx, StreamEvent event) {
    switch (event) {
      case TokenEvent(:final token):
        ctx.buffer.write(token);
        _update(ctx, (m) => m.copyWith(content: ctx.buffer.toString(), streaming: true));
      case CitationsEvent(:final citations):
        _update(ctx, (m) => m.copyWith(citations: citations));
      case ToolCallEvent():
        // Lifecycle frames: only `end` / `error` (or a single frame) carry a
        // result; the same `call_id` updates the chip already shown.
        if (event.isTerminal) {
          ctx.tools = mergeToolCalls(ctx.tools, [event.toToolCall()]);
          _update(ctx, (m) => m.copyWith(toolCalls: ctx.tools));
        }
      case UserMessageEvent():
        _replaceFirstPendingUser(event);
      case ApprovalRequiredEvent(:final approval):
        _update(
          ctx,
          (m) => m.copyWith(approval: approval, status: MessageStatus.awaitingApproval),
        );
      case DoneEvent(:final text, :final interrupted, :final status, :final model):
        // `done` carries the full text; trust it over our token buffer.
        if (text != null && text.isNotEmpty) {
          ctx.buffer
            ..clear()
            ..write(text);
        }
        _update(
          ctx,
          (m) => m.copyWith(
            content: text == null || text.isEmpty ? m.content : text,
            interrupted: interrupted || m.interrupted,
            status: status,
            model: model,
          ),
        );
      case AssistantMessageEvent():
        // Final canonical version straight from the server.
        _stopTimeout?.cancel();
        _stopTimeout = null;
        _finishTurn(ctx, event.toMessage(sessionId), persistedId: event.id);
      case ErrorEvent(:final message, :final isBusy, :final isStaleApproval):
        _stopTimeout?.cancel();
        _stopTimeout = null;
        if (ctx.isApprovalContinuation && isStaleApproval) {
          // WebSocket reports 409 / 404 as error frames.
          _ctx = null;
          state = state.copyWith(sending: false, stopping: false, error: _staleApprovalMessage);
          unawaited(reload());
          return;
        }
        final text = isBusy
            ? 'The assistant is still answering a previous message — wait for it to finish.'
            : message;
        if (ctx.isApprovalContinuation) {
          _update(
            ctx,
            (m) => m.copyWith(
              streaming: false,
              approval: ctx.approval,
              status: MessageStatus.awaitingApproval,
            ),
          );
        } else {
          _dropEmptyStreaming(ctx.targetId);
          _update(ctx, (m) => m.copyWith(streaming: false));
        }
        _ctx = null;
        state = state.copyWith(sending: false, stopping: false, error: text);
      case UsageEvent():
      case UnknownEvent():
        break;
    }
  }

  /// Blocking turn: the persisted user message replaces the optimistic one
  /// and the placeholder gives way to the server's tool rows + reply.
  void _finishBlockingTurn(String placeholderId, SendResult result) {
    final msgs = List<ChatMessage>.of(state.messages);
    final user = result.userMessage;
    if (user != null) {
      final u = msgs.indexWhere((m) => m.id.startsWith('pending-user-'));
      if (u >= 0) msgs[u] = user;
    }
    final i = msgs.indexWhere((m) => m.id == placeholderId);
    if (i < 0) {
      msgs.addAll(result.replyRows);
    } else {
      msgs.replaceRange(i, i + 1, result.replyRows);
    }
    state = state.copyWith(messages: msgs, sending: false);
    _scheduleTitleRefresh();
  }

  /// Replaces the bubble the turn streamed into with the persisted message.
  /// An approval continuation's final message carries the placeholder's own
  /// id, so a row with [persistedId] wins over the context target.
  void _finishTurn(_TurnContext ctx, ChatMessage message, {String? persistedId}) {
    final msgs = List<ChatMessage>.of(state.messages);
    var i = persistedId == null ? -1 : msgs.indexWhere((m) => m.id == persistedId);
    if (i < 0) i = msgs.indexWhere((m) => m.id == ctx.targetId);
    if (i < 0) i = msgs.lastIndexWhere((m) => m.role == MessageRole.assistant);
    if (i < 0) {
      msgs.add(message);
    } else {
      msgs[i] = message;
      // The persisted id matched a different row than the placeholder: drop
      // the placeholder so the reply is not shown twice.
      final leftover = msgs.indexWhere((m) => m.id == ctx.targetId);
      if (leftover >= 0 && leftover != i) msgs.removeAt(leftover);
    }
    _ctx = null;
    state = state.copyWith(messages: msgs, sending: false, stopping: false);
    _scheduleTitleRefresh();
  }

  void _finishInterruptedLocally() {
    _stopTimeout?.cancel();
    _stopTimeout = null;
    unawaited(_closeTurn());
    if (!mounted) return;
    final ctx = _ctx;
    _ctx = null;
    if (ctx != null) {
      _update(ctx, (m) => m.copyWith(streaming: false, interrupted: true));
    } else {
      _replaceLastAssistant((m) => m.copyWith(streaming: false, interrupted: true));
    }
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

  /// Applies [update] to the turn's target bubble (falls back to the last
  /// assistant message if the target vanished, e.g. after a reload).
  void _update(_TurnContext ctx, ChatMessage Function(ChatMessage) update) {
    if (!_replaceById(ctx.targetId, update)) _replaceLastAssistant(update);
  }

  bool _replaceById(String id, ChatMessage Function(ChatMessage) update) {
    final msgs = List<ChatMessage>.of(state.messages);
    final i = msgs.indexWhere((m) => m.id == id);
    if (i < 0) return false;
    msgs[i] = update(msgs[i]);
    state = state.copyWith(messages: msgs);
    return true;
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
  void _dropEmptyStreaming(String id) {
    final msgs = state.messages;
    final i = msgs.indexWhere((m) => m.id == id);
    if (i < 0) return;
    final m = msgs[i];
    if (m.role == MessageRole.assistant && m.streaming && m.content.isEmpty) {
      state = state.copyWith(messages: [...msgs.sublist(0, i), ...msgs.sublist(i + 1)]);
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
      final result = await repo.regenerate(sessionId);
      if (!mounted) return;
      // The previous reply *and* the tool rows directly above it are gone
      // server-side; swap both for the regenerated turn.
      final msgs = List<ChatMessage>.of(state.messages);
      final last = msgs.lastIndexWhere((m) => m.role == MessageRole.assistant);
      if (last < 0) {
        msgs.addAll(result.replyRows);
      } else {
        var start = last;
        while (start > 0 && msgs[start - 1].isToolRun) {
          start--;
        }
        msgs.replaceRange(start, last + 1, result.replyRows);
      }
      state = state.copyWith(messages: msgs, sending: false);
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
