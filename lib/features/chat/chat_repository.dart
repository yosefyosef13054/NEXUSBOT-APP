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

  /// [model] is accepted by the backend but not yet honored (Phase 2); we
  /// keep sending the user's pick so sessions carry it from day one.
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

  Future<ChatSession> renameSession(String id, String title) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$id',
      method: 'PATCH',
      data: {'title': title},
    );
    return ChatSession.fromJson(res.data!);
  }

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

  // ---- Non-streaming send (used when streaming is disabled in prefs) ----

  Future<ChatMessage> sendBlocking({
    required String sessionId,
    required String content,
    bool useRag = true,
    bool useTools = true,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/messages',
      method: 'POST',
      data: {'content': content, 'use_rag': useRag, 'use_tools': useTools},
    );
    final m = (res.data!['assistant_message'] as Map).cast<String, dynamic>();
    return ChatMessage.fromJson(m);
  }

  // ---- Streaming ----

  /// Opens a streamed turn on the chosen transport and returns its handle.
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
  }) {
    return switch (transport) {
      StreamTransport.sse => _openSse(
          sessionId: sessionId,
          body: {
            'content': content,
            'use_rag': useRag,
            'use_tools': useTools,
            'tool_names': toolNames,
            'temperature': temperature,
          },
        ),
      StreamTransport.websocket => _openWs(
          sessionId: sessionId,
          content: content,
          useRag: useRag,
          useTools: useTools,
          toolNames: toolNames,
          temperature: temperature,
        ),
    };
  }

  Future<ChatTurn> _openSse({
    required String sessionId,
    required Map<String, Object?> body,
  }) async {
    // Goes through Dio: bearer injection + single-flight 401 refresh apply.
    final frames = await _client.openEventStream(
      '/sessions/$sessionId/messages/stream',
      data: body,
    );

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

  Future<ChatTurn> _openWs({
    required String sessionId,
    required String content,
    required bool useRag,
    required bool useTools,
    List<String>? toolNames,
    double? temperature,
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

    ws.sendUserMessage(
      content: content,
      useRag: useRag,
      useTools: useTools,
      toolNames: toolNames,
      temperature: temperature,
    );

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

  Future<ChatMessage> regenerate(String sessionId, {double? temperature}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/messages/regenerate',
      method: 'POST',
      data: {if (temperature != null) 'temperature': temperature},
    );
    final m = (res.data!['assistant_message'] as Map).cast<String, dynamic>();
    return ChatMessage.fromJson(m);
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
