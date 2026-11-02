import 'package:collection/collection.dart';

enum MessageRole {
  user,
  assistant,
  system,
  tool;

  static MessageRole fromString(String s) =>
      MessageRole.values.firstWhereOrNull((r) => r.name == s) ?? MessageRole.assistant;
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.systemPrompt,
    this.summary,
    this.model,
  });

  factory ChatSession.fromJson(Map<String, dynamic> j) => ChatSession(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? 'Untitled',
        systemPrompt: j['system_prompt'] as String?,
        summary: j['summary'] as String?,
        model: j['model'] as String?,
        createdAt: DateTime.parse(j['created_at'] as String),
        updatedAt: DateTime.parse(j['updated_at'] as String),
      );

  final String id;
  final String title;
  final String? systemPrompt;
  final String? summary;
  final String? model;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class Citation {
  const Citation({
    required this.documentId,
    required this.documentName,
    required this.chunkIndex,
    required this.score,
    required this.excerpt,
  });

  factory Citation.fromJson(Map<String, dynamic> j) => Citation(
        documentId: (j['document_id'] as String?) ?? '',
        documentName: (j['document_name'] as String?) ?? 'Document',
        chunkIndex: (j['chunk_index'] as num?)?.toInt() ?? 0,
        score: (j['score'] as num?)?.toDouble() ?? 0,
        excerpt: (j['excerpt'] as String?) ?? '',
      );

  final String documentId;
  final String documentName;
  final int chunkIndex;
  final double score;
  final String excerpt;
}

class ToolCall {
  const ToolCall({required this.tool, this.input, this.output});

  factory ToolCall.fromJson(Map<String, dynamic> j) => ToolCall(
        tool: (j['tool'] as String?) ?? 'tool',
        input: j['input'],
        output: j['output']?.toString(),
      );

  final String tool;
  final Object? input;
  final String? output;
}

List<Citation> _citationsFrom(Object? raw) => (raw as List? ?? const [])
    .whereType<Map>()
    .map((m) => Citation.fromJson(m.cast<String, dynamic>()))
    .toList();

List<ToolCall> _toolCallsFrom(Object? raw) => (raw as List? ?? const [])
    .whereType<Map>()
    .map((m) => ToolCall.fromJson(m.cast<String, dynamic>()))
    .toList();

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.tokens = 0,
    this.citations = const [],
    this.toolCalls = const [],
    this.streaming = false,
    this.interrupted = false,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> j) {
    final meta = (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ChatMessage(
      id: j['id'] as String,
      sessionId: j['session_id'] as String,
      role: MessageRole.fromString(j['role'] as String),
      content: (j['content'] as String?) ?? '',
      tokens: (j['tokens'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(j['created_at'] as String),
      citations: _citationsFrom(meta['citations']),
      toolCalls: _toolCallsFrom(meta['tool_calls']),
      // A generation stopped early is persisted with `meta.status == "interrupted"`.
      interrupted: meta['status'] == 'interrupted',
    );
  }

  /// Build a placeholder assistant message for streaming. Will be replaced
  /// with the persisted server message once the stream completes.
  factory ChatMessage.streamingPlaceholder({required String sessionId}) => ChatMessage(
        id: 'streaming-${DateTime.now().microsecondsSinceEpoch}',
        sessionId: sessionId,
        role: MessageRole.assistant,
        content: '',
        createdAt: DateTime.now(),
        streaming: true,
      );

  final String id;
  final String sessionId;
  final MessageRole role;
  final String content;
  final int tokens;
  final DateTime createdAt;
  final List<Citation> citations;
  final List<ToolCall> toolCalls;
  final bool streaming;

  /// True when the generation was stopped before the model finished —
  /// [content] holds the partial text.
  final bool interrupted;

  ChatMessage copyWith({
    String? id,
    String? content,
    List<Citation>? citations,
    List<ToolCall>? toolCalls,
    bool? streaming,
    bool? interrupted,
  }) =>
      ChatMessage(
        id: id ?? this.id,
        sessionId: sessionId,
        role: role,
        content: content ?? this.content,
        tokens: tokens,
        createdAt: createdAt,
        citations: citations ?? this.citations,
        toolCalls: toolCalls ?? this.toolCalls,
        streaming: streaming ?? this.streaming,
        interrupted: interrupted ?? this.interrupted,
      );
}

/// Discriminated streaming event, identical over SSE and WebSocket.
///
/// Frames look like `{"type": "...", "data": ...}`; see README for the full
/// wire format.
sealed class StreamEvent {
  const StreamEvent();

  factory StreamEvent.fromJson(Map<String, dynamic> j) {
    final type = j['type'] as String? ?? '';
    final data = j['data'];
    switch (type) {
      case 'user_message':
        return UserMessageEvent(data: _asMap(data));
      case 'citations':
        return CitationsEvent(citations: _citationsFrom(data));
      case 'token':
        return TokenEvent(token: data is String ? data : '${data ?? ''}');
      case 'tool_call':
        return ToolCallEvent(data: _asMap(data));
      case 'usage':
        return UsageEvent(data: _asMap(data));
      case 'done':
        return DoneEvent(data: _asMap(data));
      case 'assistant_message':
        return AssistantMessageEvent(data: _asMap(data));
      case 'error':
        final map = data is Map ? data.cast<String, dynamic>() : const <String, dynamic>{};
        return ErrorEvent(
          message: (map['message'] as String?) ?? (data is String ? data : 'error'),
          code: map['code'] as String?,
        );
      default:
        return UnknownEvent(type: type);
    }
  }

  static Map<String, dynamic> _asMap(Object? data) =>
      data is Map ? data.cast<String, dynamic>() : const <String, dynamic>{};
}

/// The user's message as persisted by the server (replaces the optimistic one).
class UserMessageEvent extends StreamEvent {
  const UserMessageEvent({required this.data});
  final Map<String, dynamic> data;

  String? get id => data['id'] as String?;

  ChatMessage toMessage(String sessionId, {DateTime? fallbackCreatedAt}) => ChatMessage(
        id: id ?? 'user-${DateTime.now().microsecondsSinceEpoch}',
        sessionId: (data['session_id'] as String?) ?? sessionId,
        role: MessageRole.user,
        content: (data['content'] as String?) ?? '',
        createdAt: DateTime.tryParse(data['created_at'] as String? ?? '') ??
            fallbackCreatedAt ??
            DateTime.now(),
      );
}

class CitationsEvent extends StreamEvent {
  const CitationsEvent({required this.citations});
  final List<Citation> citations;
}

class TokenEvent extends StreamEvent {
  const TokenEvent({required this.token});
  final String token;
}

class ToolCallEvent extends StreamEvent {
  const ToolCallEvent({required this.data});
  final Map<String, dynamic> data;

  /// `start` / `end` (absent for single-frame tool calls).
  String? get phase => data['phase'] as String?;
  String get tool => (data['tool'] as String?) ?? 'tool';
  Object? get input => data['input'];
  String? get output => data['output']?.toString();

  ToolCall toToolCall() => ToolCall(tool: tool, input: input, output: output);
}

/// Provider-reported token counts for the turn.
class UsageEvent extends StreamEvent {
  const UsageEvent({required this.data});
  final Map<String, dynamic> data;

  int? get promptTokens => (data['prompt_tokens'] as num?)?.toInt();
  int? get completionTokens => (data['completion_tokens'] as num?)?.toInt();
  int? get totalTokens => (data['total_tokens'] as num?)?.toInt();
}

/// Full assembled text + latency. `interrupted` is set when the generation
/// was stopped early (then `text` is the partial output).
class DoneEvent extends StreamEvent {
  const DoneEvent({required this.data});
  final Map<String, dynamic> data;

  String? get text => data['text'] as String?;
  int? get latencyMs => (data['latency_ms'] as num?)?.toInt();
  bool get interrupted => data['interrupted'] == true;
}

/// The persisted assistant message — the canonical end of a turn.
class AssistantMessageEvent extends StreamEvent {
  const AssistantMessageEvent({required this.data});
  final Map<String, dynamic> data;

  String? get id => data['id'] as String?;
  bool get interrupted => data['interrupted'] == true;

  ChatMessage toMessage(String sessionId) {
    final meta = (data['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ChatMessage(
      id: id ?? 'assistant-${DateTime.now().microsecondsSinceEpoch}',
      sessionId: (data['session_id'] as String?) ?? sessionId,
      role: MessageRole.assistant,
      content: (data['content'] as String?) ?? '',
      tokens: (data['tokens'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(data['created_at'] as String? ?? '') ?? DateTime.now(),
      citations: _citationsFrom(data['citations'] ?? meta['citations']),
      toolCalls: _toolCallsFrom(data['tool_calls'] ?? meta['tool_calls']),
      interrupted: interrupted || meta['status'] == 'interrupted',
    );
  }
}

class ErrorEvent extends StreamEvent {
  const ErrorEvent({required this.message, this.code});
  final String message;

  /// Backend error code (`busy`, `unauthorized`, `rate_limited`, …).
  final String? code;

  bool get isBusy => code == 'busy';
}

class UnknownEvent extends StreamEvent {
  const UnknownEvent({required this.type});
  final String type;
}
