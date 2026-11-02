import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show Options;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/preferences.dart';
import '../../core/sse_parser.dart';
import '../attachments/attachment_model.dart';
import '../orgs/orgs_repository.dart';
import 'chat_cache.dart';
import 'chat_models.dart';
import 'chat_ws.dart';

/// Spoken-reply options of a send (`voice_reply`, `voice`, `audio_format`).
/// The stream then carries `audio_chunk` frames before `assistant_message`;
/// a blocking send answers with `meta.audio` instead.
class VoiceReply {
  const VoiceReply({this.voice, this.audioFormat});

  /// Voice id from `GET /audio/voices`; null = the server default.
  final String? voice;

  /// `mp3` | `wav` | … ; null = the server default.
  final String? audioFormat;

  Map<String, Object?> toJson() => {
        'voice_reply': true,
        if (voice != null) 'voice': voice,
        if (audioFormat != null) 'audio_format': audioFormat,
      };
}

/// Live handle on a streamed assistant turn.
///
/// [events] delivers the same [StreamEvent]s on both transports and ends
/// after the terminal `assistant_message` / `error` event.
///
/// The turn also tracks what is needed to pick it up again after a drop:
/// [generationId] (from `user_message.data.generation_id`, or known up front
/// when attaching to a running generation) and [lastEventId], the `id:` of
/// the last SSE frame received — the `after=` cursor of
/// `GET /sessions/{id}/generations/{generation_id}/events`.
class ChatTurn {
  ChatTurn({
    required this.transport,
    required this.events,
    required Future<void> Function() stop,
    required Future<void> Function() close,
    this.generationId,
  })  : _stop = stop,
        _close = close;

  final StreamTransport transport;
  final Stream<StreamEvent> events;
  final Future<void> Function() _stop;
  final Future<void> Function() _close;

  /// The server-side generation this turn belongs to, once known.
  String? generationId;

  /// Sequence (`id:` line) of the last SSE frame seen; null on WebSocket or
  /// before the first frame.
  String? lastEventId;

  /// Asks the server to stop generating.
  ///
  /// * WebSocket: sends `{"type":"stop"}`. The server persists the partial
  ///   text and still emits `done` + `assistant_message` (`interrupted: true`),
  ///   so [events] stays open until that final message arrives.
  /// * SSE: asks the server to stop through
  ///   `POST /sessions/{id}/generations/{generation_id}/stop` (when the
  ///   generation id is known), then closes the HTTP connection; [events] ends
  ///   immediately. Merely disconnecting would let the server finish the reply.
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
    var assistant =
        ChatMessage.fromJson((body['assistant_message'] as Map).cast<String, dynamic>());
    // The top-level `artifacts` duplicate `assistant_message.meta.artifacts`;
    // keep whichever the server filled in.
    final artifacts = attachmentsFrom(body['artifacts']);
    if (artifacts.isNotEmpty) {
      assistant = assistant.copyWith(artifacts: mergeAttachments(assistant.artifacts, artifacts));
    }
    return SendResult(
      userMessage: user is Map ? ChatMessage.fromJson(user.cast<String, dynamic>()) : null,
      assistantMessage: assistant,
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

/// One page of `GET /sessions/{id}/messages?cursor=&limit=`: the newest
/// messages of the active branch (oldest first within the page) and the
/// cursor of the page before it.
class HistoryPage {
  const HistoryPage({required this.items, this.nextCursor});

  factory HistoryPage.fromJson(Map<String, dynamic> j) => HistoryPage(
        items: ChatRepository._messages(j['items']),
        nextCursor: j['next_cursor'] as String?,
      );

  final List<ChatMessage> items;

  /// `created_at` of the oldest message here; pass it as `cursor` for the
  /// page before. Null when the beginning of the chat was reached.
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
}

class ChatRepository {
  ChatRepository(this._client);
  final ApiClient _client;

  /// Header that lets the server collapse a retried send into the original
  /// turn (24 h window). One key per send attempt.
  static const idempotencyHeader = 'Idempotency-Key';

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
  /// [assistantId] makes the session use that assistant's prompt, model,
  /// tools, collections and memory setting as defaults.
  Future<ChatSession> createSession({
    String? title,
    String? systemPrompt,
    String? model,
    String? assistantId,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions',
      method: 'POST',
      data: {
        if (title != null) 'title': title,
        if (systemPrompt != null) 'system_prompt': systemPrompt,
        if (model != null) 'model': model,
        if (assistantId != null) 'assistant_id': assistantId,
      },
    );
    return ChatSession.fromJson(res.data!);
  }

  Future<void> deleteSession(String id) async {
    await _client.request<Map<String, dynamic>>('/sessions/$id', method: 'DELETE');
  }

  /// `PATCH /sessions/{id}` — only the given fields are sent. [meta] replaces
  /// the session's metadata (send the merged map to keep other keys).
  /// [clearAssistantId] sends `assistant_id: null` (back to a plain chat).
  Future<ChatSession> updateSession(
    String id, {
    String? title,
    String? model,
    Map<String, dynamic>? meta,
    String? assistantId,
    bool clearAssistantId = false,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$id',
      method: 'PATCH',
      data: {
        if (title != null) 'title': title,
        if (model != null) 'model': model,
        if (meta != null) 'meta': meta,
        if (assistantId != null || clearAssistantId) 'assistant_id': assistantId,
      },
    );
    return ChatSession.fromJson(res.data!);
  }

  Future<ChatSession> renameSession(String id, String title) => updateSession(id, title: title);

  // ---- History & branches ----

  /// The newest [limit] messages of the active branch (linear, oldest first).
  Future<List<ChatMessage>> loadHistory(String sessionId, {int limit = 100}) async =>
      (await loadHistoryPage(sessionId, limit: limit)).items;

  /// Cursor pagination over the active branch: without [cursor] the newest
  /// page, with it the messages created before that timestamp
  /// (`HistoryPage.nextCursor` of the previous page).
  Future<HistoryPage> loadHistoryPage(String sessionId, {String? cursor, int limit = 50}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/messages',
      query: {'limit': limit, if (cursor != null) 'cursor': cursor},
    );
    return HistoryPage.fromJson(res.data ?? const {});
  }

  /// `GET /sessions/{id}/messages/{message_id}/siblings` — the edits of a
  /// user message or the regenerations of a reply, with the active one.
  Future<SiblingsResult> listSiblings(String sessionId, String messageId) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/messages/$messageId/siblings',
    );
    return SiblingsResult.fromJson(res.data ?? const {});
  }

  /// `POST /sessions/{id}/branch {leaf_message_id}` — makes the branch
  /// through [leafMessageId] active (the server picks that message's latest
  /// descendant as the new leaf) and returns its history.
  Future<List<ChatMessage>> branch(String sessionId, {required String leafMessageId}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/branch',
      method: 'POST',
      data: {'leaf_message_id': leafMessageId},
    );
    return _messages(res.data?['items']);
  }

  static List<ChatMessage> _messages(Object? raw) => (raw as List? ?? const [])
      .whereType<Map>()
      .map((m) => ChatMessage.fromJson(m.cast<String, dynamic>()))
      .toList();

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

  // ---- Feedback ----

  /// `POST /sessions/{id}/messages/{message_id}/feedback {rating, comment}`
  /// (upsert). [rating] is `1` or `-1`.
  Future<MessageFeedback> setFeedback(
    String sessionId,
    String messageId, {
    required int rating,
    String? comment,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/messages/$messageId/feedback',
      method: 'POST',
      data: {
        'rating': rating,
        if (comment != null && comment.trim().isNotEmpty) 'comment': comment.trim(),
      },
    );
    return MessageFeedback.fromJson(res.data ?? {'rating': rating, 'comment': comment});
  }

  Future<void> clearFeedback(String sessionId, String messageId) async {
    await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/messages/$messageId/feedback',
      method: 'DELETE',
    );
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
          sessionId: sessionId,
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
    String? idempotencyKey,
    List<String>? attachmentIds,
    VoiceReply? voiceReply,
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
        attachmentIds: attachmentIds,
        voiceReply: voiceReply,
      ),
      options: _idempotent(idempotencyKey),
    );
    return SendResult.fromJson(res.data!);
  }

  static Options? _idempotent(String? key) =>
      key == null ? null : Options(headers: {idempotencyHeader: key});

  static Map<String, String>? _idempotentHeaders(String? key) =>
      key == null ? null : {idempotencyHeader: key};

  /// The body shared by every send path. `attachment_ids` binds uploads of
  /// this session to the new user message (images need a vision model: 422
  /// with `details.vision_models` otherwise); `voice_reply` asks for a spoken
  /// reply. Both are omitted when unused so older servers are unaffected.
  static Map<String, Object?> _turnBody({
    required String content,
    required bool useRag,
    required bool useTools,
    List<String>? toolNames,
    double? temperature,
    String? model,
    List<String>? collectionIds,
    List<String>? attachmentIds,
    VoiceReply? voiceReply,
  }) =>
      {
        'content': content,
        'use_rag': useRag,
        'use_tools': useTools,
        'tool_names': toolNames,
        'temperature': temperature,
        if (model != null) 'model': model,
        if (collectionIds != null) 'collection_ids': collectionIds,
        if (attachmentIds != null && attachmentIds.isNotEmpty) 'attachment_ids': attachmentIds,
        ...?voiceReply?.toJson(),
      };

  // ---- Streaming ----

  /// Opens a streamed turn on the chosen transport and returns its handle.
  ///
  /// [model] overrides the session's model for this turn only;
  /// [collectionIds] restricts retrieval to those collections (null = the
  /// session default, i.e. `session.meta.collection_ids`, else all documents).
  /// [idempotencyKey] is sent as `Idempotency-Key` (SSE) so a retried send
  /// replays the original generation instead of creating a second turn.
  ///
  /// The access token is refreshed proactively before the connection opens.
  /// Throws [ApiException] when the connection cannot be established (auth,
  /// rate limit, quota, network); errors *during* the stream arrive as
  /// [ErrorEvent].
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
    String? idempotencyKey,
    List<String>? attachmentIds,
    VoiceReply? voiceReply,
  }) {
    return switch (transport) {
      StreamTransport.sse => _openSse(
          sessionId: sessionId,
          path: '/sessions/$sessionId/messages/stream',
          body: _turnBody(
            content: content,
            useRag: useRag,
            useTools: useTools,
            toolNames: toolNames,
            temperature: temperature,
            model: model,
            collectionIds: collectionIds,
            attachmentIds: attachmentIds,
            voiceReply: voiceReply,
          ),
          headers: _idempotentHeaders(idempotencyKey),
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
            attachmentIds: attachmentIds,
            voiceReply: voiceReply,
          ),
        ),
    };
  }

  /// Edits a user message: `POST /sessions/{id}/messages/{message_id}/edit`
  /// streamed exactly like `/messages/stream` (SSE only). The new user
  /// message carries `parent_id`, the reply streams into a new bubble and
  /// the new branch becomes the active one.
  Future<ChatTurn> editMessage({
    required String sessionId,
    required String messageId,
    required String content,
    bool useRag = true,
    bool useTools = true,
    List<String>? toolNames,
    double? temperature,
    String? model,
    List<String>? collectionIds,
    String? idempotencyKey,
    List<String>? attachmentIds,
    VoiceReply? voiceReply,
  }) {
    return _openSse(
      sessionId: sessionId,
      path: '/sessions/$sessionId/messages/$messageId/edit',
      body: _turnBody(
        content: content,
        useRag: useRag,
        useTools: useTools,
        toolNames: toolNames,
        temperature: temperature,
        model: model,
        collectionIds: collectionIds,
        attachmentIds: attachmentIds,
        voiceReply: voiceReply,
      ),
      headers: _idempotentHeaders(idempotencyKey),
    );
  }

  // ---- Generations: resume, attach, background ----

  /// `POST /sessions/{id}/generations/{generation_id}/stop` — ends a running
  /// generation server-side; the partial reply is persisted with
  /// `interrupted: true` and the stream still finishes with `done` +
  /// `assistant_message`. Idempotent (a finished generation answers 200 too).
  Future<void> stopGeneration(String sessionId, String generationId) async {
    await _client.request<dynamic>(
      '/sessions/$sessionId/generations/$generationId/stop',
      method: 'POST',
    );
  }

  /// `GET /sessions/{id}/generations/active` — the running generation, if any.
  Future<ActiveGeneration?> activeGeneration(String sessionId) async {
    final res = await _client.request<dynamic>('/sessions/$sessionId/generations/active');
    final body = res.data;
    if (body is! Map) return null;
    final active = ActiveGeneration.fromJson(body.cast<String, dynamic>());
    return active.generationId.isEmpty ? null : active;
  }

  /// `GET /sessions/{id}/generations/{generation_id}/events?after=<seq>` —
  /// replays the frames after [after] (also sent as `Last-Event-ID`) and
  /// follows the generation live until its `assistant_message`. Without
  /// [after] the replay starts from the first frame. 404 `not_found` when
  /// the generation is unknown or expired.
  Future<ChatTurn> resumeGeneration(
    String sessionId,
    String generationId, {
    String? after,
  }) {
    return _openSse(
      sessionId: sessionId,
      path: '/sessions/$sessionId/generations/$generationId/events',
      method: 'GET',
      query: {if (after != null) 'after': after},
      headers: {if (after != null) 'Last-Event-ID': after},
      generationId: generationId,
    );
  }

  /// `POST /sessions/{id}/messages/background` → 202: the reply is produced
  /// even if this client disconnects. Attach with [resumeGeneration].
  Future<BackgroundSend> sendBackground({
    required String sessionId,
    required String content,
    bool useRag = true,
    bool useTools = true,
    List<String>? toolNames,
    String? model,
    List<String>? collectionIds,
    String? idempotencyKey,
    List<String>? attachmentIds,
    VoiceReply? voiceReply,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/messages/background',
      method: 'POST',
      data: _turnBody(
        content: content,
        useRag: useRag,
        useTools: useTools,
        toolNames: toolNames,
        model: model,
        collectionIds: collectionIds,
        attachmentIds: attachmentIds,
        voiceReply: voiceReply,
      ),
      options: _idempotent(idempotencyKey),
    );
    return BackgroundSend.fromJson(res.data ?? const {});
  }

  Future<ChatTurn> _openSse({
    required String sessionId,
    required String path,
    Map<String, Object?>? body,
    String method = 'POST',
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    String? generationId,
  }) async {
    // Goes through Dio: bearer injection, X-Org-Id and single-flight 401
    // refresh apply.
    final frames = await _client.openEventStream(
      path,
      method: method,
      data: body,
      query: query,
      headers: headers,
    );

    final out = StreamController<StreamEvent>();
    StreamSubscription<SseEvent>? sub;

    // Cancelling the frame subscription closes the socket (see
    // ApiClient.openEventStream). Disconnecting does *not* stop the server-side
    // generation (it keeps running and stays resumable), so a stop first asks
    // the server to end it through the stop endpoint.
    Future<void> teardown() async {
      final s = sub;
      sub = null;
      await s?.cancel();
    }

    void finish() {
      if (!out.isClosed) out.close();
    }

    late final ChatTurn turn;
    turn = ChatTurn(
      transport: StreamTransport.sse,
      events: out.stream,
      generationId: generationId,
      stop: () async {
        final gid = turn.generationId;
        if (gid != null) {
          try {
            await stopGeneration(sessionId, gid);
          } catch (_) {
            // Best effort: the connection is closed either way and the server
            // persists whatever it produced.
          }
        }
        await teardown();
        finish();
      },
      close: () async {
        await teardown();
        finish();
      },
    );

    sub = frames.listen(
      (frame) {
        if (out.isClosed) return;
        if (frame.id != null && frame.id!.isNotEmpty) turn.lastEventId = frame.id;
        if (frame.data.isEmpty) return;
        final StreamEvent event;
        try {
          event = StreamEvent.fromJson(jsonDecode(frame.data) as Map<String, dynamic>);
        } catch (e) {
          out.add(ErrorEvent(message: 'Bad frame: $e', code: 'bad_frame'));
          finish();
          return;
        }
        _trackGeneration(turn, event);
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

    return turn;
  }

  /// Remembers the generation id as soon as a frame names it.
  static void _trackGeneration(ChatTurn turn, StreamEvent event) {
    final id = switch (event) {
      UserMessageEvent(:final generationId) => generationId,
      DoneEvent(:final generationId) => generationId,
      AssistantMessageEvent(:final generationId) => generationId,
      _ => null,
    };
    if (id != null && id.isNotEmpty) turn.generationId = id;
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
    final orgId = _client.currentOrgId;

    ChatWebSocket ws;
    try {
      ws = await ChatWebSocket.connect(sessionId: sessionId, token: token, orgId: orgId);
    } on ApiException catch (e) {
      if (!e.isAuth) rethrow;
      // Mirror the HTTP interceptor: one refresh, one retry.
      token = await _client.refresher.refresh();
      if (token == null) rethrow;
      ws = await ChatWebSocket.connect(sessionId: sessionId, token: token, orgId: orgId);
    }

    final out = StreamController<StreamEvent>();
    late final StreamSubscription<StreamEvent> sub;

    void finish() {
      if (!out.isClosed) out.close();
      unawaited(ws.close());
    }

    final turn = ChatTurn(
      transport: StreamTransport.websocket,
      events: out.stream,
      stop: () async => ws.sendStop(),
      close: () async {
        await ws.close();
        finish();
      },
    );

    sub = ws.events.listen(
      (event) {
        if (out.isClosed) return;
        _trackGeneration(turn, event);
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

    return turn;
  }

  // ---- Regenerate ----

  /// Produces a fresh reply for the last user message; the previous reply is
  /// kept as a sibling (blocking, same shape as a send). Reload the history
  /// afterwards to pick up the sibling counts.
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

/// The active workspace's sessions; reloads when the workspace changes.
///
/// Cache first: the list stored by the last successful load is emitted at
/// once, then the fresh list replaces it (and the cache). When the server
/// cannot be reached the cached list simply stays.
final sessionListProvider = StreamProvider.autoDispose<List<ChatSession>>((ref) async* {
  ref.watch(activeOrgIdProvider);
  final scope = ref.watch(cacheScopeProvider);
  final cache = ref.watch(chatCacheProvider);
  final repo = await ref.watch(chatRepositoryProvider.future);
  List<ChatSession>? cached;
  try {
    cached = await cache.readSessions(scope);
  } catch (_) {
    cached = null;
  }
  if (cached != null) yield cached;
  try {
    final fresh = await repo.listSessions();
    await cache.writeSessions(scope, fresh);
    yield fresh;
  } catch (_) {
    if (cached == null) rethrow;
    // Offline: the cached list stays on screen.
  }
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
