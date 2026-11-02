import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/preferences.dart';
import '../../core/sse_parser.dart';
import 'chat_models.dart';
import 'chat_ws.dart';

/// Live handle on a streamed assistant turn.
///
/// [events] delivers the same [StreamEvent]s on both transports and ends
/// after the terminal `assistant_message` / `error` event.
class ChatTurn {
  ChatTurn({
    required this.transport,
    required this.events,
    required Future<void> Function() stop,
    required Future<void> Function() close,
  })  : _stop = stop,
        _close = close;

  final StreamTransport transport;
  final Stream<StreamEvent> events;
  final Future<void> Function() _stop;
  final Future<void> Function() _close;

  /// Asks the server to stop generating.
  ///
  /// * WebSocket: sends `{"type":"stop"}`. The server persists the partial
  ///   text and still emits `done` + `assistant_message` (`interrupted: true`),
  ///   so [events] stays open until that final message arrives.
  /// * SSE: closes the HTTP connection — the server persists the partial on
  ///   disconnect — and [events] ends immediately.
  Future<void> stop() => _stop();

  /// Drops the connection without waiting for anything.
  Future<void> close() => _close();
}

/// Result of a blocking turn (`POST /sessions/{id}/messages`) or a
/// `regenerate`: the persisted reply plus the `role: "tool"` rows the server
/// stored for it — inserted before the reply so the chat looks exactly like
/// a history reload would.
class SendResult {
  const SendResult({
    required this.assistantMessage,
    this.userMessage,
    this.toolMessages = const [],
  });

  factory SendResult.fromJson(Map<String, dynamic> body) {
    final user = body['user_message'];
    return SendResult(
      userMessage: user is Map ? ChatMessage.fromJson(user.cast<String, dynamic>()) : null,
      assistantMessage:
          ChatMessage.fromJson((body['assistant_message'] as Map).cast<String, dynamic>()),
      toolMessages: (body['tool_messages'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => ChatMessage.fromJson(m.cast<String, dynamic>()))
          .toList(),
    );
  }

  /// The persisted user message (blocking send only).
  final ChatMessage? userMessage;
  final ChatMessage assistantMessage;

  /// One `role: "tool"` row per executed tool call.
  final List<ChatMessage> toolMessages;

  /// The rows to show for the turn, in history order.
  List<ChatMessage> get replyRows => [...toolMessages, assistantMessage];
}

class ChatRepository {
  ChatRepository(this._client);
  final ApiClient _client;

  // ---- Sessions ----

  Future<List<ChatSession>> listSessions({int page = 1, int pageSize = 50}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions',
      query: {'page': page, 'page_size': pageSize},
    );
    return (res.data!['items'] as List)
        .cast<Map>()
        .map((m) => ChatSession.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<ChatSession> getSession(String id) async {
    final res = await _client.request<Map<String, dynamic>>('/sessions/$id');
    return ChatSession.fromJson(res.data!);
  }

  /// [model] is validated server-side (422 `validation_error` with
  /// `details.available` when unknown) — callers pass an id from `GET /models`.
  Future<ChatSession> createSession({
    String? title,
    String? systemPrompt,
    String? model,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions',
      method: 'POST',
      data: {
        if (title != null) 'title': title,
        if (systemPrompt != null) 'system_prompt': systemPrompt,
        if (model != null) 'model': model,
      },
    );
    return ChatSession.fromJson(res.data!);
  }

  Future<void> deleteSession(String id) async {
    await _client.request<Map<String, dynamic>>('/sessions/$id', method: 'DELETE');
  }

  /// `PATCH /sessions/{id}` — only the given fields are sent. [meta] replaces
  /// the session's metadata (send the merged map to keep other keys).
  Future<ChatSession> updateSession(
    String id, {
    String? title,
    String? model,
    Map<String, dynamic>? meta,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$id',
      method: 'PATCH',
      data: {
        if (title != null) 'title': title,
        if (model != null) 'model': model,
        if (meta != null) 'meta': meta,
      },
    );
    return ChatSession.fromJson(res.data!);
  }

  Future<ChatSession> renameSession(String id, String title) => updateSession(id, title: title);

  // ---- History ----

  Future<List<ChatMessage>> loadHistory(String sessionId, {int limit = 100}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/messages',
      query: {'limit': limit},
    );
    return (res.data!['items'] as List)
        .cast<Map>()
        .map((m) => ChatMessage.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  // ---- Search ----

  /// `POST /search` — full-text search across the user's messages. Results
  /// carry a `highlight` snippet with `<mark>` tags around matched terms.
  Future<List<SearchResult>> search(String query, {int limit = 20}) async {
    final res = await _client.request<dynamic>(
      '/search',
      method: 'POST',
      data: {'query': query, 'limit': limit},
    );
    final body = res.data;
    // The endpoint answers with a bare list; tolerate a `{items: [...]}` page too.
    final raw = body is List ? body : (body is Map ? body['items'] : null);
    return (raw as List? ?? const [])
        .whereType<Map>()
        .map((m) => SearchResult.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  // ---- Approvals ----

  /// Approvals still waiting for the user in this session (after an app
  /// restart the history rows carry them too; this is the authoritative list).
  Future<List<ApprovalRequest>> listPendingApprovals(String sessionId) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/approvals',
      query: {'status': 'pending'},
    );
    return (res.data?['items'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => ApprovalRequest.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// Resolves a pending approval and returns the continuation of the turn.
  ///
  /// * SSE: `POST /sessions/{id}/approvals/{approvalId}` with
  ///   `Accept: text/event-stream` — the same frames as a normal turn.
  /// * WebSocket: an `approval` frame on a fresh socket; the events arrive there.
  ///
  /// The final `assistant_message.data.id` equals the placeholder message's
  /// id. Throws [ApiException] 404 (`not_found`) / 409 (`conflict`) when the
  /// approval is unknown, already resolved or expired (SSE); over WebSocket
  /// these arrive as an [ErrorEvent] with the same codes.
  Future<ChatTurn> resolveApproval({
    required String sessionId,
    required String approvalId,
    required ApprovalDecision decision,
    StreamTransport transport = StreamTransport.sse,
  }) {
    return switch (transport) {
      StreamTransport.sse => _openSse(
          path: '/sessions/$sessionId/approvals/$approvalId',
          body: {'decision': decision.wire},
        ),
      StreamTransport.websocket => _openWs(
          sessionId: sessionId,
          sendFirstFrame: (ws) => ws.sendApproval(approvalId: approvalId, decision: decision),
        ),
    };
  }

  // ---- Non-streaming send (used when streaming is disabled in prefs) ----

  Future<SendResult> sendBlocking({
    required String sessionId,
    required String content,
    bool useRag = true,
    bool useTools = true,
    List<String>? toolNames,
    String? model,
    List<String>? collectionIds,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/messages',
      method: 'POST',
      data: _turnBody(
        content: content,
        useRag: useRag,
        useTools: useTools,
        toolNames: toolNames,
        model: model,
        collectionIds: collectionIds,
      ),
    );
    return SendResult.fromJson(res.data!);
  }

  static Map<String, Object?> _turnBody({
    required String content,
    required bool useRag,
    required bool useTools,
    List<String>? toolNames,
    double? temperature,
    String? model,
    List<String>? collectionIds,
  }) =>
      {
        'content': content,
        'use_rag': useRag,
        'use_tools': useTools,
        'tool_names': toolNames,
        'temperature': temperature,
        if (model != null) 'model': model,
        if (collectionIds != null) 'collection_ids': collectionIds,
      };

  // ---- Streaming ----

  /// Opens a streamed turn on the chosen transport and returns its handle.
  ///
  /// [model] overrides the session's model for this turn only;
  /// [collectionIds] restricts retrieval to those collections (null = the
  /// session default, i.e. `session.meta.collection_ids`, else all documents).
  ///
  /// The access token is refreshed proactively before the connection opens.
  /// Throws [ApiException] when the connection cannot be established (auth,
  /// rate limit, network); errors *during* the stream arrive as [ErrorEvent].
  Future<ChatTurn> streamMessage({
    required String sessionId,
    required String content,
    required StreamTransport transport,
    bool useRag = true,
    bool useTools = true,
    List<String>? toolNames,
    double? temperature,
    String? model,
    List<String>? collectionIds,
  }) {
    return switch (transport) {
      StreamTransport.sse => _openSse(
          path: '/sessions/$sessionId/messages/stream',
          body: _turnBody(
            content: content,
            useRag: useRag,
            useTools: useTools,
            toolNames: toolNames,
            temperature: temperature,
            model: model,
            collectionIds: collectionIds,
          ),
        ),
      StreamTransport.websocket => _openWs(
          sessionId: sessionId,
          sendFirstFrame: (ws) => ws.sendUserMessage(
            content: content,
            useRag: useRag,
            useTools: useTools,
            toolNames: toolNames,
            temperature: temperature,
            model: model,
            collectionIds: collectionIds,
          ),
        ),
    };
  }

  Future<ChatTurn> _openSse({
    required String path,
    required Map<String, Object?> body,
  }) async {
    // Goes through Dio: bearer injection + single-flight 401 refresh apply.
    final frames = await _client.openEventStream(path, data: body);

    final out = StreamController<StreamEvent>();
    StreamSubscription<SseEvent>? sub;

    // Cancelling the frame subscription closes the socket (see
    // ApiClient.openEventStream), so the server sees the disconnect and
    // persists the partial reply.
    Future<void> teardown() async {
      final s = sub;
      sub = null;
      await s?.cancel();
    }

    void finish() {
      if (!out.isClosed) out.close();
    }

    sub = frames.listen(
      (frame) {
        if (frame.data.isEmpty || out.isClosed) return;
        final StreamEvent event;
        try {
          event = StreamEvent.fromJson(jsonDecode(frame.data) as Map<String, dynamic>);
        } catch (e) {
          out.add(ErrorEvent(message: 'Bad frame: $e', code: 'bad_frame'));
          finish();
          return;
        }
        out.add(event);
        if (event is AssistantMessageEvent || event is ErrorEvent) finish();
      },
      onError: (Object e) {
        if (out.isClosed) return;
        out.add(ErrorEvent(message: errorText(e), code: 'network_error'));
        finish();
      },
      onDone: finish,
    );
    // Runs when the consumer cancels *and* after a normal close.
    out.onCancel = teardown;

    return ChatTurn(
      transport: StreamTransport.sse,
      events: out.stream,
      stop: () async {
        await teardown();
        finish();
      },
      close: () async {
        await teardown();
        finish();
      },
    );
  }

  /// Connects + authenticates a WebSocket for [sessionId], sends the frame
  /// that starts the turn through [sendFirstFrame], and relays its events.
  Future<ChatTurn> _openWs({
    required String sessionId,
    required void Function(ChatWebSocket ws) sendFirstFrame,
  }) async {
    var token = await _client.ensureFreshAccessToken();
    if (token == null) {
      throw ApiException(code: 'unauthorized', message: 'Not signed in', statusCode: 401);
    }

    ChatWebSocket ws;
    try {
      ws = await ChatWebSocket.connect(sessionId: sessionId, token: token);
    } on ApiException catch (e) {
      if (!e.isAuth) rethrow;
      // Mirror the HTTP interceptor: one refresh, one retry.
      token = await _client.refresher.refresh();
      if (token == null) rethrow;
      ws = await ChatWebSocket.connect(sessionId: sessionId, token: token);
    }

    final out = StreamController<StreamEvent>();
    late final StreamSubscription<StreamEvent> sub;

    void finish() {
      if (!out.isClosed) out.close();
      unawaited(ws.close());
    }

    sub = ws.events.listen(
      (event) {
        if (out.isClosed) return;
        out.add(event);
        if (event is AssistantMessageEvent || event is ErrorEvent) finish();
      },
      onError: (Object e) {
        if (!out.isClosed) out.add(ErrorEvent(message: errorText(e), code: 'network_error'));
        finish();
      },
      onDone: finish,
    );
    out.onCancel = () async {
      await sub.cancel();
      await ws.close();
    };

    sendFirstFrame(ws);

    return ChatTurn(
      transport: StreamTransport.websocket,
      events: out.stream,
      stop: () async => ws.sendStop(),
      close: () async {
        await ws.close();
        finish();
      },
    );
  }

  // ---- Regenerate ----

  /// Replaces the previous assistant turn (and its tool rows) with a fresh one.
  Future<SendResult> regenerate(String sessionId, {double? temperature}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/messages/regenerate',
      method: 'POST',
      data: {if (temperature != null) 'temperature': temperature},
    );
    return SendResult.fromJson(res.data!);
  }
}

final chatRepositoryProvider = FutureProvider<ChatRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return ChatRepository(client);
});

final sessionListProvider = FutureProvider.autoDispose<List<ChatSession>>((ref) async {
  final repo = await ref.watch(chatRepositoryProvider.future);
  return repo.listSessions();
});

final sessionHistoryProvider =
    FutureProvider.autoDispose.family<List<ChatMessage>, String>((ref, sessionId) async {
  final repo = await ref.watch(chatRepositoryProvider.future);
  return repo.loadHistory(sessionId);
});

/// Session titles are generated server-side *after* the stream closes, so the
/// sidebar re-fetches the list shortly after each completed turn.
class SessionListRefresher {
  SessionListRefresher(this._ref, {this.delay = const Duration(seconds: 2)});

  final Ref _ref;
  final Duration delay;
  Timer? _timer;

  /// Invalidates [sessionListProvider] after [delay] (debounced).
  void scheduleRefresh() {
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      _ref.invalidate(sessionListProvider);
    });
  }

  void dispose() => _timer?.cancel();
}

final sessionListRefresherProvider = Provider<SessionListRefresher>((ref) {
  final refresher = SessionListRefresher(ref);
  ref.onDispose(refresher.dispose);
  return refresher;
});
