import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/api_exception.dart';
import '../../core/env.dart';
import 'chat_models.dart';
import 'chat_repository.dart' show VoiceReply;

/// WebSocket transport for `/api/v1/ws/sessions/{id}`.
///
/// Protocol:
/// 1. connect without a token in the query string;
/// 2. send `{"type":"auth","token":"<jwt>","org_id":"<active org>"}` as the
///    first frame (`org_id` only when a workspace other than the personal
///    one is active) and wait for `auth_ok` (an `error` frame / close
///    before that fails [connect]);
/// 3. send `user_message`; the server streams the same event frames as SSE;
/// 4. `stop` cancels the in-flight generation — the server still emits `done`
///    and `assistant_message` (both `interrupted: true`), so keep listening;
/// 5. `ping` / `pong` keep the socket alive; `pong` and `auth_ok` are
///    consumed here and never reach [events].
///
/// Same event shape as the SSE transport so the chat controller doesn't care
/// which one is in use — the active transport is chosen in `ChatRepository`.
class ChatWebSocket {
  ChatWebSocket._(this._channel);

  static const authTimeout = Duration(seconds: 10);
  static const pingInterval = Duration(seconds: 25);

  final WebSocketChannel _channel;
  final _events = StreamController<StreamEvent>();
  final _authed = Completer<void>();
  StreamSubscription<dynamic>? _sub;
  Timer? _ping;
  bool _closed = false;

  /// Connects and authenticates. Resolves once the server answers `auth_ok`;
  /// throws [ApiException] (`unauthorized`, `network_error`, `timeout`)
  /// otherwise.
  static Future<ChatWebSocket> connect({
    required String sessionId,
    required String token,
    String? orgId,
    String? baseUrl,
  }) async {
    final uri = Uri.parse('${baseUrl ?? Env.wsBaseUrl}/ws/sessions/$sessionId');
    final channel = WebSocketChannel.connect(uri);
    try {
      await channel.ready;
    } catch (e) {
      throw ApiException(code: 'network_error', message: 'WebSocket connection failed: $e');
    }

    final ws = ChatWebSocket._(channel).._listen();
    ws._send({
      'type': 'auth',
      'token': token,
      if (orgId != null && orgId.isNotEmpty) 'org_id': orgId,
    });
    try {
      await ws._authed.future.timeout(authTimeout);
    } on TimeoutException {
      await ws.close();
      throw ApiException(code: 'timeout', message: 'WebSocket authentication timed out');
    } on ApiException {
      await ws.close();
      rethrow;
    }
    ws._ping = Timer.periodic(pingInterval, (_) => ws._send({'type': 'ping'}));
    return ws;
  }

  /// Events for the current turn. Single-subscription; buffered until listened.
  Stream<StreamEvent> get events => _events.stream;

  void _listen() {
    _sub = _channel.stream.listen(
      (raw) {
        final Map<String, dynamic> frame;
        try {
          frame = jsonDecode(raw as String) as Map<String, dynamic>;
        } catch (e) {
          _emit(ErrorEvent(message: 'Bad frame: $e', code: 'bad_frame'));
          return;
        }
        switch (frame['type']) {
          case 'auth_ok':
            if (!_authed.isCompleted) _authed.complete();
          case 'pong':
            break;
          case 'error':
            final error = StreamEvent.fromJson(frame) as ErrorEvent;
            if (!_authed.isCompleted) {
              _authed.completeError(
                ApiException(
                  code: error.code ?? 'unauthorized',
                  message: error.message,
                  statusCode: error.code == 'unauthorized' ? 401 : null,
                ),
              );
            } else {
              _emit(error);
            }
          default:
            _emit(StreamEvent.fromJson(frame));
        }
      },
      onError: (Object e) {
        if (!_authed.isCompleted) {
          _authed.completeError(ApiException(code: 'network_error', message: '$e'));
          return;
        }
        _emit(ErrorEvent(message: '$e', code: 'network_error'));
      },
      onDone: () {
        if (!_authed.isCompleted) {
          _authed.completeError(
            ApiException(
              code: 'unauthorized',
              message: 'WebSocket closed before authentication '
                  '(${_channel.closeCode ?? 'no close code'})',
              statusCode: _channel.closeCode == 1008 ? 401 : null,
            ),
          );
        }
        _ping?.cancel();
        if (!_events.isClosed) _events.close();
      },
    );
  }

  void _emit(StreamEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _send(Map<String, Object?> frame) {
    if (_closed) return;
    _channel.sink.add(jsonEncode(frame));
  }

  /// Send a user message frame matching the backend's expected schema.
  ///
  /// [model] is a per-turn model override and [collectionIds] the knowledge
  /// scope for this turn; both are omitted (server resolves the session /
  /// user default) when null. [attachmentIds] binds uploads to the message
  /// and [voiceReply] asks for `audio_chunk` frames before the final message.
  void sendUserMessage({
    required String content,
    bool useRag = true,
    bool useTools = true,
    List<String>? toolNames,
    double? temperature,
    String? model,
    List<String>? collectionIds,
    List<String>? attachmentIds,
    VoiceReply? voiceReply,
  }) {
    _send({
      'type': 'user_message',
      'content': content,
      'use_rag': useRag,
      'use_tools': useTools,
      'tool_names': toolNames,
      'temperature': temperature,
      if (model != null) 'model': model,
      if (collectionIds != null) 'collection_ids': collectionIds,
      if (attachmentIds != null && attachmentIds.isNotEmpty) 'attachment_ids': attachmentIds,
      ...?voiceReply?.toJson(),
    });
  }

  /// Resolve a pending approval; the continuation of the turn (`tool_call`,
  /// `token`, …, `assistant_message`) then arrives on this socket.
  void sendApproval({required String approvalId, required ApprovalDecision decision}) {
    _send({'type': 'approval', 'approval_id': approvalId, 'decision': decision.wire});
  }

  /// Ask the server to cancel the in-flight generation. The server persists
  /// the partial text and still emits `done` + `assistant_message`.
  void sendStop() => _send({'type': 'stop'});

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _ping?.cancel();
    // Not awaited on purpose: a single-subscription controller's close()
    // only completes once a listener drains it, and there may never be one
    // (e.g. a failed auth handshake).
    if (!_events.isClosed) unawaited(_events.close());
    try {
      await _channel.sink.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Already closed / never opened — nothing to do.
    }
    await _sub?.cancel();
  }
}
