import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../../core/api_exception.dart';
import '../attachments/attachment_model.dart';

export '../attachments/attachment_model.dart' show Attachment, AttachmentKind;

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
    this.meta = const {},
    this.orgId,
    this.assistantId,
    this.activeLeafId,
  });

  factory ChatSession.fromJson(Map<String, dynamic> j) => ChatSession(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? 'Untitled',
        systemPrompt: j['system_prompt'] as String?,
        summary: j['summary'] as String?,
        model: j['model'] as String?,
        meta: (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
        orgId: j['org_id'] as String?,
        assistantId: j['assistant_id'] as String?,
        activeLeafId: j['active_leaf_id'] as String?,
        createdAt: DateTime.parse(j['created_at'] as String),
        updatedAt: DateTime.parse(j['updated_at'] as String),
      );

  final String id;
  final String title;
  final String? systemPrompt;
  final String? summary;

  /// The session's model id (`PATCH /sessions/{id} {model}`); null = the
  /// user's / server's default.
  final String? model;

  /// The organization the session belongs to.
  final String? orgId;

  /// The assistant (persona) the session uses for its defaults
  /// (`PATCH /sessions/{id} {assistant_id}`); null = plain chat.
  final String? assistantId;

  /// The message at the tip of the active branch (see `POST /sessions/{id}/branch`).
  final String? activeLeafId;

  /// Free-form session metadata. `meta.collection_ids` is the knowledge
  /// scope (see [collectionIds]).
  final Map<String, dynamic> meta;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Collections this chat's RAG retrieval is restricted to; null = all of
  /// the user's documents.
  List<String>? get collectionIds {
    final raw = meta['collection_ids'];
    if (raw is! List) return null;
    return raw.map((e) => e.toString()).toList();
  }

  ChatSession copyWith({
    String? title,
    String? model,
    Map<String, dynamic>? meta,
    String? assistantId,
    bool clearAssistantId = false,
    String? activeLeafId,
  }) =>
      ChatSession(
        id: id,
        title: title ?? this.title,
        systemPrompt: systemPrompt,
        summary: summary,
        model: model ?? this.model,
        meta: meta ?? this.meta,
        orgId: orgId,
        assistantId: clearAssistantId ? null : (assistantId ?? this.assistantId),
        activeLeafId: activeLeafId ?? this.activeLeafId,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

  /// The server shape (`SessionRead`), so a cached session round-trips
  /// through [ChatSession.fromJson].
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'system_prompt': systemPrompt,
        'summary': summary,
        'model': model,
        'meta': meta,
        'org_id': orgId,
        'assistant_id': assistantId,
        'active_leaf_id': activeLeafId,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };
}

/// Where a message sits among its siblings — the edits of a user message or
/// the regenerations of a reply (`MessageRead.siblings`). [index] is
/// zero-based; [displayIndex] is what the "‹ 2/3 ›" switcher shows.
class SiblingInfo {
  const SiblingInfo({required this.index, required this.count});

  factory SiblingInfo.fromJson(Map<String, dynamic> j) => SiblingInfo(
        index: (j['index'] as num?)?.toInt() ?? 0,
        count: (j['count'] as num?)?.toInt() ?? 1,
      );

  final int index;
  final int count;

  int get displayIndex => (index + 1).clamp(1, count < 1 ? 1 : count);
  bool get hasSiblings => count > 1;

  Map<String, dynamic> toJson() => {'index': index, 'count': count};
}

/// The user's thumbs up / down on a reply (`meta.feedback`).
class MessageFeedback {
  const MessageFeedback({required this.rating, this.comment});

  factory MessageFeedback.fromJson(Map<String, dynamic> j) => MessageFeedback(
        rating: (j['rating'] as num?)?.toInt() ?? 0,
        comment: j['comment'] as String?,
      );

  /// `1` or `-1`.
  final int rating;
  final String? comment;

  bool get isUp => rating > 0;
  bool get isDown => rating < 0;

  Map<String, dynamic> toJson() => {'rating': rating, if (comment != null) 'comment': comment};
}

/// `GET /sessions/{id}/messages/{message_id}/siblings`.
class SiblingsResult {
  const SiblingsResult({required this.items, required this.activeIndex});

  factory SiblingsResult.fromJson(Map<String, dynamic> j) => SiblingsResult(
        items: (j['items'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => ChatMessage.fromJson(m.cast<String, dynamic>()))
            .toList(),
        activeIndex: (j['active_index'] as num?)?.toInt() ?? 0,
      );

  final List<ChatMessage> items;

  /// Index into [items] of the sibling on the active branch.
  final int activeIndex;
}

/// `GET /sessions/{id}/generations/active`.
class ActiveGeneration {
  const ActiveGeneration({required this.generationId, required this.status, this.startedAt});

  factory ActiveGeneration.fromJson(Map<String, dynamic> j) => ActiveGeneration(
        generationId: (j['generation_id'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'running',
        startedAt: DateTime.tryParse(j['started_at'] as String? ?? ''),
      );

  final String generationId;

  /// `running` | `done`.
  final String status;
  final DateTime? startedAt;

  bool get isRunning => status == 'running' && generationId.isNotEmpty;
}

/// `POST /sessions/{id}/messages/background` → 202.
class BackgroundSend {
  const BackgroundSend({required this.generationId, this.userMessage});

  factory BackgroundSend.fromJson(Map<String, dynamic> j) => BackgroundSend(
        generationId: (j['generation_id'] as String?) ?? '',
        userMessage: j['user_message'] is Map
            ? ChatMessage.fromJson((j['user_message'] as Map).cast<String, dynamic>())
            : null,
      );

  final String generationId;
  final ChatMessage? userMessage;
}

/// A retrieved chunk the answer was grounded in. Structured since Phase 2:
/// [chunkId] opens the chunk viewer, [page] / [section] locate it in the
/// source document. Optional fields are null when the server has no value.
class Citation {
  const Citation({
    required this.documentId,
    required this.documentName,
    required this.chunkIndex,
    required this.score,
    required this.excerpt,
    this.chunkId,
    this.page,
    this.section,
    this.startIndex,
    this.endIndex,
    this.collectionId,
    this.match,
  });

  factory Citation.fromJson(Map<String, dynamic> j) => Citation(
        documentId: (j['document_id'] as String?) ?? '',
        documentName: (j['document_name'] as String?) ?? 'Document',
        chunkId: j['chunk_id'] as String?,
        chunkIndex: (j['chunk_index'] as num?)?.toInt() ?? 0,
        page: (j['page'] as num?)?.toInt(),
        section: j['section'] as String?,
        startIndex: (j['start_index'] as num?)?.toInt(),
        endIndex: (j['end_index'] as num?)?.toInt(),
        collectionId: j['collection_id'] as String?,
        match: j['match'] as String?,
        score: (j['score'] as num?)?.toDouble() ?? 0,
        excerpt: (j['excerpt'] as String?) ?? '',
      );

  final String documentId;
  final String documentName;
  final String? chunkId;
  final int chunkIndex;
  final int? page;
  final String? section;
  final int? startIndex;
  final int? endIndex;
  final String? collectionId;

  /// How the chunk was found: `vector`, `keyword` or `hybrid` (null when the
  /// server does not say).
  final String? match;
  final double score;
  final String excerpt;

  /// `p. 4 · 2. Scope > 2.1 Goals` — null when neither page nor section is known.
  String? get locationLabel {
    final parts = <String>[
      if (page != null) 'p. $page',
      if (section != null && section!.trim().isNotEmpty) section!.trim(),
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Whether the chunk viewer can fetch the full text.
  bool get canOpen => documentId.isNotEmpty && chunkId != null && chunkId!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'document_id': documentId,
        'document_name': documentName,
        'chunk_id': chunkId,
        'chunk_index': chunkIndex,
        'page': page,
        'section': section,
        'start_index': startIndex,
        'end_index': endIndex,
        'collection_id': collectionId,
        'match': match,
        'score': score,
        'excerpt': excerpt,
      };
}

enum ToolCallStatus {
  ok,
  error,
  denied,
  unknown;

  static ToolCallStatus fromString(String? s) =>
      ToolCallStatus.values.firstWhereOrNull((v) => v.name == s) ?? ToolCallStatus.unknown;
}

/// One tool run — from a live `tool_call` event, the final
/// `assistant_message.tool_calls`, or a persisted `role: "tool"` history row.
/// [callId] identifies the same run across all three sources.
class ToolCall {
  const ToolCall({
    required this.tool,
    this.callId,
    this.input,
    this.output,
    this.status = ToolCallStatus.ok,
    this.latencyMs,
    this.error,
  });

  factory ToolCall.fromJson(Map<String, dynamic> j) => ToolCall(
        tool: (j['tool'] as String?) ?? 'tool',
        callId: j['call_id'] as String?,
        input: j['input'],
        output: j['output']?.toString(),
        status: _statusOf(j),
        latencyMs: (j['latency_ms'] as num?)?.toInt(),
        error: j['error']?.toString(),
      );

  static ToolCallStatus _statusOf(Map<String, dynamic> j) {
    final s = j['status'];
    if (s is String) return ToolCallStatus.fromString(s);
    if (j['error'] != null || j['phase'] == 'error') return ToolCallStatus.error;
    return ToolCallStatus.ok;
  }

  final String tool;
  final String? callId;
  final Object? input;
  final String? output;
  final ToolCallStatus status;
  final int? latencyMs;
  final String? error;

  Map<String, dynamic> toJson() => {
        'tool': tool,
        'call_id': callId,
        'input': input,
        'output': output,
        'status': status.name,
        'latency_ms': latencyMs,
        'error': error,
      };
}

/// Upserts [incoming] into [existing]: an entry with a known `call_id`
/// replaces the one it matches (so a history reload and the live stream
/// never show the same run twice); entries without an id are appended.
List<ToolCall> mergeToolCalls(List<ToolCall> existing, Iterable<ToolCall> incoming) {
  final out = List<ToolCall>.of(existing);
  for (final tc in incoming) {
    final id = tc.callId;
    final i = id == null ? -1 : out.indexWhere((e) => e.callId == id);
    if (i >= 0) {
      out[i] = tc;
    } else {
      out.add(tc);
    }
  }
  return out;
}

/// The user's answer to an [ApprovalRequest].
enum ApprovalDecision {
  approve,
  deny;

  /// Wire value for `{"decision": …}`.
  String get wire => name;
}

/// One tool call the agent wants to run and needs permission for.
class ApprovalToolCall {
  const ApprovalToolCall({
    required this.callId,
    required this.tool,
    this.input,
    this.description = '',
  });

  factory ApprovalToolCall.fromJson(Map<String, dynamic> j) => ApprovalToolCall(
        callId: (j['call_id'] as String?) ?? '',
        tool: (j['tool'] as String?) ?? 'tool',
        input: j['input'],
        description: (j['description'] as String?) ?? '',
      );

  final String callId;
  final String tool;
  final Object? input;
  final String description;

  Map<String, dynamic> toJson() =>
      {'call_id': callId, 'tool': tool, 'input': input, 'description': description};
}

/// A human-in-the-loop request: the agent paused before running one or more
/// approval-required tools. Carried by the `approval_required` event,
/// `assistant_message.data.approval`, history `meta.approval`, and
/// `GET /sessions/{id}/approvals?status=pending`.
class ApprovalRequest {
  const ApprovalRequest({
    required this.approvalId,
    required this.sessionId,
    required this.messageId,
    this.expiresAt,
    this.toolCalls = const [],
    this.status = 'pending',
  });

  factory ApprovalRequest.fromJson(Map<String, dynamic> j) => ApprovalRequest(
        approvalId: (j['approval_id'] as String?) ?? '',
        sessionId: (j['session_id'] as String?) ?? '',
        messageId: (j['message_id'] as String?) ?? '',
        expiresAt: DateTime.tryParse(j['expires_at'] as String? ?? ''),
        toolCalls: (j['tool_calls'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => ApprovalToolCall.fromJson(m.cast<String, dynamic>()))
            .toList(),
        status: (j['status'] as String?) ?? 'pending',
      );

  final String approvalId;
  final String sessionId;

  /// The placeholder assistant message this approval belongs to.
  final String messageId;
  final DateTime? expiresAt;
  final List<ApprovalToolCall> toolCalls;

  /// `pending` while the buttons should be shown; anything else (resolved,
  /// expired — as reconciled against the pending list) hides them.
  final String status;

  bool get isPending => status == 'pending';

  ApprovalRequest copyWith({String? status}) => ApprovalRequest(
        approvalId: approvalId,
        sessionId: sessionId,
        messageId: messageId,
        expiresAt: expiresAt,
        toolCalls: toolCalls,
        status: status ?? this.status,
      );

  Map<String, dynamic> toJson() => {
        'approval_id': approvalId,
        'session_id': sessionId,
        'message_id': messageId,
        'expires_at': expiresAt?.toIso8601String(),
        'tool_calls': [for (final c in toolCalls) c.toJson()],
        'status': status,
      };
}

List<Citation> _citationsFrom(Object? raw) => (raw as List? ?? const [])
    .whereType<Map>()
    .map((m) => Citation.fromJson(m.cast<String, dynamic>()))
    .toList();

List<ToolCall> _toolCallsFrom(Object? raw) => mergeToolCalls(
      const [],
      (raw as List? ?? const [])
          .whereType<Map>()
          .map((m) => ToolCall.fromJson(m.cast<String, dynamic>())),
    );

ApprovalRequest? _approvalFrom(Object? raw) =>
    raw is Map ? ApprovalRequest.fromJson(raw.cast<String, dynamic>()) : null;

SiblingInfo? _siblingsFrom(Object? raw) =>
    raw is Map ? SiblingInfo.fromJson(raw.cast<String, dynamic>()) : null;

MessageFeedback? _feedbackFrom(Object? raw) =>
    raw is Map ? MessageFeedback.fromJson(raw.cast<String, dynamic>()) : null;

List<String> _idsFrom(Object? raw) =>
    (raw as List? ?? const []).map((e) => e.toString()).where((s) => s.isNotEmpty).toList();

MessageAudio? _audioFrom(Object? raw) =>
    raw is Map ? MessageAudio.fromJson(raw.cast<String, dynamic>()) : null;

/// The spoken version of a reply (`assistant_message.data.audio` /
/// `MessageRead.meta.audio`): the whole clip stored as an audio attachment,
/// playable again through [url].
class MessageAudio {
  const MessageAudio({
    required this.attachmentId,
    required this.url,
    this.format,
    this.chunks = 1,
  });

  factory MessageAudio.fromJson(Map<String, dynamic> j) => MessageAudio(
        attachmentId: (j['attachment_id'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        format: j['format'] as String?,
        chunks: (j['chunks'] as num?)?.toInt() ?? 1,
      );

  /// Built from the `audio_done.data.attachment` summary.
  factory MessageAudio.fromAttachment(Attachment a, {int chunks = 1}) => MessageAudio(
        attachmentId: a.id,
        url: a.url,
        format: a.mimeType.contains('/') ? a.mimeType.split('/').last : null,
        chunks: chunks,
      );

  final String attachmentId;

  /// Content URL of the clip (resolve through `AttachmentsRepository.resolveUrl`).
  final String url;
  final String? format;
  final int chunks;

  bool get isPlayable => url.isNotEmpty;

  Map<String, dynamic> toJson() =>
      {'attachment_id': attachmentId, 'url': url, 'format': format, 'chunks': chunks};
}

/// `meta.status` of a persisted assistant message.
abstract final class MessageStatus {
  static const ok = 'ok';
  static const interrupted = 'interrupted';
  static const error = 'error';
  static const awaitingApproval = 'awaiting_approval';
}

/// Delivery state of a user message sent from this device.
enum MessageDelivery {
  /// Accepted by the server (or loaded from it).
  sent,

  /// Waiting in the send queue (offline, or the send hit a transport error);
  /// retried automatically on reconnect.
  queued,

  /// The queue gave up (a non-transient refusal): needs a manual retry or a
  /// cancel.
  failed,
}

/// Why a turn could not run — what the chat screen shows above the composer.
///
/// Kept as a kind + raw server text so the screen can translate the kinds
/// it knows ([ChatErrorKind.busy], …) and show the server's own message for
/// the rest; [text] is the untranslated fallback.
enum ChatErrorKind {
  /// Text from the server (an `error` stream frame).
  message,

  /// An exception thrown by a repository call (see [ChatError.error]).
  exception,
  busy,
  staleApproval,
  voiceUnavailable,
  visionRequired,
}

class ChatError {
  const ChatError(this.kind, {this.message = '', this.models = const [], this.error});

  const ChatError.message(String message) : this(ChatErrorKind.message, message: message);

  /// Classifies a thrown error: a vision refusal (422 with
  /// `details.vision_models`), a missing voice provider
  /// (`details.code == voice_unavailable`) or any other failure.
  factory ChatError.exception(Object error) {
    if (error is ApiException) {
      final visionModels = error.details?['vision_models'];
      if (visionModels is List && visionModels.isNotEmpty) {
        return ChatError(
          ChatErrorKind.visionRequired,
          message: error.userMessage,
          models: [for (final m in visionModels) m.toString()],
          error: error,
        );
      }
      if (error.details?['code'] == 'voice_unavailable') return ChatError.voiceUnavailable;
    }
    return ChatError(ChatErrorKind.exception, message: errorText(error), error: error);
  }

  static const busy = ChatError(ChatErrorKind.busy);
  static const staleApproval = ChatError(ChatErrorKind.staleApproval);
  static const voiceUnavailable = ChatError(ChatErrorKind.voiceUnavailable);

  final ChatErrorKind kind;

  /// The server's message (or the client's transport message).
  final String message;

  /// Ids of the models that can read images ([ChatErrorKind.visionRequired]).
  final List<String> models;

  /// The thrown object ([ChatErrorKind.exception]), for localised rendering.
  final Object? error;

  /// Untranslated text (what the screen shows when no translation applies,
  /// and what tests assert on).
  String get text => switch (kind) {
        ChatErrorKind.message || ChatErrorKind.exception => message,
        ChatErrorKind.busy =>
          'The assistant is still answering a previous message — wait for it to finish.',
        ChatErrorKind.staleApproval =>
          'That approval was already resolved or has expired — the chat was refreshed.',
        ChatErrorKind.voiceUnavailable => 'Voice is not available on this server.',
        ChatErrorKind.visionRequired => '$message Models with vision: ${models.join(', ')}.',
      };

  @override
  bool operator ==(Object other) =>
      other is ChatError &&
      other.kind == kind &&
      other.message == message &&
      const ListEquality<String>().equals(other.models, models);

  @override
  int get hashCode => Object.hash(kind, message, Object.hashAll(models));

  @override
  String toString() => 'ChatError($kind: $text)';
}

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
    this.status,
    this.approval,
    this.model,
    this.parentId,
    this.siblings,
    this.feedback,
    this.memoriesUsed = const [],
    this.generationId,
    this.attachments = const [],
    this.artifacts = const [],
    this.audio,
    this.delivery = MessageDelivery.sent,
    this.deliveryError,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> j) {
    final meta = (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    final role = MessageRole.fromString(j['role'] as String);
    final content = (j['content'] as String?) ?? '';
    final status = meta['status'] as String?;
    return ChatMessage(
      id: j['id'] as String,
      sessionId: j['session_id'] as String,
      role: role,
      content: content,
      tokens: (j['tokens'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(j['created_at'] as String),
      parentId: j['parent_id'] as String?,
      siblings: _siblingsFrom(j['siblings']),
      feedback: _feedbackFrom(meta['feedback']),
      memoriesUsed: _idsFrom(meta['memories_used']),
      generationId: (meta['generation_id'] ?? j['generation_id']) as String?,
      attachments: attachmentsFrom(meta['attachments']),
      artifacts: attachmentsFrom(meta['artifacts']),
      audio: _audioFrom(meta['audio']),
      citations: _citationsFrom(meta['citations']),
      // A `role: "tool"` row *is* one tool run: its meta carries the call,
      // its content the (truncated) output.
      toolCalls: role == MessageRole.tool
          ? [
              ToolCall(
                tool: (meta['tool'] as String?) ?? 'tool',
                callId: meta['call_id'] as String?,
                input: meta['input'],
                output: content,
                status: ToolCallStatus.fromString(meta['status'] as String?),
                latencyMs: (meta['latency_ms'] as num?)?.toInt(),
                error: meta['error']?.toString(),
              ),
            ]
          : _toolCallsFrom(meta['tool_calls']),
      // A generation stopped early is persisted with `meta.status == "interrupted"`.
      interrupted: status == MessageStatus.interrupted,
      status: status,
      approval: _approvalFrom(meta['approval']),
      model: meta['model'] as String?,
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

  /// `meta.status` (`ok`, `interrupted`, `error`, `awaiting_approval`).
  final String? status;

  /// Set while the agent waits for the user to approve a tool call.
  final ApprovalRequest? approval;

  /// The model id that produced this reply (`meta.model` / `done.data.model`).
  final String? model;

  /// The message this one answers / branches from (null for the root).
  final String? parentId;

  /// Set when the message has edit / regeneration siblings.
  final SiblingInfo? siblings;

  /// The user's thumbs up / down on this reply.
  final MessageFeedback? feedback;

  /// Ids of the memories injected into the turn that produced this reply.
  final List<String> memoriesUsed;

  /// The generation that produced (or is producing) this reply.
  final String? generationId;

  /// Images, files and audio clips the user attached to this message
  /// (`meta.attachments` / `user_message.data.attachments`).
  final List<Attachment> attachments;

  /// Files produced by tools during the turn that made this reply
  /// (`meta.artifacts` / `assistant_message.data.artifacts`).
  final List<Attachment> artifacts;

  /// The spoken version of the reply, when one was synthesized.
  final MessageAudio? audio;

  /// Whether the server has this message (user messages sent from here).
  final MessageDelivery delivery;

  /// Why the send queue gave up ([MessageDelivery.failed]).
  final String? deliveryError;

  /// A `role: "tool"` history row — rendered as a chip, never as a bubble.
  bool get isToolRun => role == MessageRole.tool;

  /// Waiting in the send queue, or parked there after a refusal.
  bool get isQueued => delivery != MessageDelivery.sent;

  /// The optimistic bubble of a voice turn while the clip is transcribed.
  bool get isVoicePlaceholder => isPendingUser && content == voicePlaceholderText;

  /// Text of the optimistic bubble while a voice clip is transcribed (a
  /// sentinel: the bubble renders a translated label instead).
  static const voicePlaceholderText = '\u0000voice-placeholder';

  bool get awaitingApproval => status == MessageStatus.awaitingApproval;

  /// Optimistic rows the server has not confirmed yet carry this prefix.
  static const pendingUserPrefix = 'pending-user-';
  bool get isPendingUser => id.startsWith(pendingUserPrefix);

  ChatMessage copyWith({
    String? id,
    String? content,
    List<Citation>? citations,
    List<ToolCall>? toolCalls,
    bool? streaming,
    bool? interrupted,
    String? status,
    bool clearStatus = false,
    ApprovalRequest? approval,
    bool clearApproval = false,
    String? model,
    String? parentId,
    SiblingInfo? siblings,
    bool clearSiblings = false,
    MessageFeedback? feedback,
    bool clearFeedback = false,
    List<String>? memoriesUsed,
    String? generationId,
    List<Attachment>? attachments,
    List<Attachment>? artifacts,
    MessageAudio? audio,
    bool clearAudio = false,
    MessageDelivery? delivery,
    String? deliveryError,
    bool clearDeliveryError = false,
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
        status: clearStatus ? null : (status ?? this.status),
        approval: clearApproval ? null : (approval ?? this.approval),
        model: model ?? this.model,
        parentId: parentId ?? this.parentId,
        siblings: clearSiblings ? null : (siblings ?? this.siblings),
        feedback: clearFeedback ? null : (feedback ?? this.feedback),
        memoriesUsed: memoriesUsed ?? this.memoriesUsed,
        generationId: generationId ?? this.generationId,
        attachments: attachments ?? this.attachments,
        artifacts: artifacts ?? this.artifacts,
        audio: clearAudio ? null : (audio ?? this.audio),
        delivery: delivery ?? this.delivery,
        deliveryError: clearDeliveryError ? null : (deliveryError ?? this.deliveryError),
      );

  /// The server shape (`MessageRead`), so a cached message round-trips
  /// through [ChatMessage.fromJson]. Local-only state (streaming, delivery)
  /// is not written: only persisted messages are cached.
  Map<String, dynamic> toJson() {
    final toolRun = role == MessageRole.tool ? toolCalls.firstOrNull : null;
    return {
      'id': id,
      'session_id': sessionId,
      'role': role.name,
      'content': content,
      'tokens': tokens,
      'created_at': createdAt.toIso8601String(),
      if (parentId != null) 'parent_id': parentId,
      if (siblings != null) 'siblings': siblings!.toJson(),
      'meta': {
        if (status != null)
          'status': status
        else if (interrupted)
          'status': MessageStatus.interrupted,
        if (model != null) 'model': model,
        if (generationId != null) 'generation_id': generationId,
        if (citations.isNotEmpty) 'citations': [for (final c in citations) c.toJson()],
        if (toolRun != null) ...{
          'tool': toolRun.tool,
          'call_id': toolRun.callId,
          'input': toolRun.input,
          if (status == null) 'status': toolRun.status.name,
          'latency_ms': toolRun.latencyMs,
          'error': toolRun.error,
        } else if (toolCalls.isNotEmpty)
          'tool_calls': [for (final tc in toolCalls) tc.toJson()],
        if (approval != null) 'approval': approval!.toJson(),
        if (feedback != null) 'feedback': feedback!.toJson(),
        if (memoriesUsed.isNotEmpty) 'memories_used': memoriesUsed,
        if (attachments.isNotEmpty) 'attachments': [for (final a in attachments) a.toJson()],
        if (artifacts.isNotEmpty) 'artifacts': [for (final a in artifacts) a.toJson()],
        if (audio != null) 'audio': audio!.toJson(),
      },
    };
  }
}

/// One hit of `POST /search`. [highlight] wraps matched terms in
/// `<mark>…</mark>` (see `shared/highlight_text.dart`).
class SearchResult {
  const SearchResult({
    required this.sessionId,
    required this.sessionTitle,
    required this.messageId,
    required this.role,
    required this.snippet,
    this.highlight,
    this.rank,
    this.createdAt,
  });

  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
        sessionId: (j['session_id'] as String?) ?? '',
        sessionTitle: (j['session_title'] as String?) ?? 'Untitled',
        messageId: (j['message_id'] as String?) ?? '',
        role: MessageRole.fromString((j['role'] as String?) ?? 'assistant'),
        snippet: (j['snippet'] as String?) ?? '',
        highlight: j['highlight'] as String?,
        rank: (j['rank'] as num?)?.toDouble(),
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
      );

  final String sessionId;
  final String sessionTitle;
  final String messageId;
  final MessageRole role;
  final String snippet;
  final String? highlight;
  final double? rank;
  final DateTime? createdAt;
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
      case 'approval_required':
        return ApprovalRequiredEvent(data: _asMap(data));
      case 'usage':
        return UsageEvent(data: _asMap(data));
      case 'done':
        return DoneEvent(data: _asMap(data));
      case 'assistant_message':
        return AssistantMessageEvent(data: _asMap(data));
      case 'artifact':
        return ArtifactEvent(data: _asMap(data));
      case 'audio_chunk':
        return AudioChunkEvent(data: _asMap(data));
      case 'audio_done':
        return AudioDoneEvent(data: _asMap(data));
      case 'error':
        final map = data is Map ? data.cast<String, dynamic>() : const <String, dynamic>{};
        return ErrorEvent(
          message: (map['message'] as String?) ?? (data is String ? data : 'error'),
          code: map['code'] as String?,
          details: (map['details'] as Map?)?.cast<String, dynamic>(),
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

  /// The generation this turn runs under — the handle for reconnecting
  /// (`GET /sessions/{id}/generations/{generation_id}/events`).
  String? get generationId => data['generation_id'] as String?;

  /// Set when the message was created by an edit (it then branches off its
  /// parent instead of continuing the tip).
  String? get parentId => data['parent_id'] as String?;

  Map<String, dynamic> get _meta => (data['meta'] as Map?)?.cast<String, dynamic>() ?? const {};

  /// The attachments bound to the message (`data.attachments`, or
  /// `data.meta.attachments` when the server sends the full `MessageRead`).
  List<Attachment> get attachments => attachmentsFrom(data['attachments'] ?? _meta['attachments']);

  ChatMessage toMessage(String sessionId, {DateTime? fallbackCreatedAt}) => ChatMessage(
        id: id ?? 'user-${DateTime.now().microsecondsSinceEpoch}',
        sessionId: (data['session_id'] as String?) ?? sessionId,
        role: MessageRole.user,
        content: (data['content'] as String?) ?? '',
        createdAt: DateTime.tryParse(data['created_at'] as String? ?? '') ??
            fallbackCreatedAt ??
            DateTime.now(),
        parentId: parentId,
        siblings: _siblingsFrom(data['siblings']),
        generationId: generationId,
        attachments: attachments,
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

  /// `start` / `end` / `error` (absent for single-frame tool calls).
  String? get phase => data['phase'] as String?;
  String get tool => (data['tool'] as String?) ?? 'tool';
  String? get callId => data['call_id'] as String?;
  Object? get input => data['input'];
  String? get output => data['output']?.toString();
  String? get error => data['error']?.toString();
  int? get latencyMs => (data['latency_ms'] as num?)?.toInt();

  /// Whether this frame carries the run's result (only `end` / `error`, or a
  /// single frame without a phase, do — `start` frames are lifecycle only).
  bool get isTerminal => phase == null || phase == 'end' || phase == 'error';

  ToolCall toToolCall() => ToolCall.fromJson(data);
}

/// The agent paused before running approval-required tools. The stream then
/// ends normally with `done` + `assistant_message` (both
/// `status: "awaiting_approval"`); resolve it through
/// `ChatRepository.resolveApproval`.
class ApprovalRequiredEvent extends StreamEvent {
  const ApprovalRequiredEvent({required this.data});
  final Map<String, dynamic> data;

  ApprovalRequest get approval => ApprovalRequest.fromJson(data);
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
/// was stopped early (then `text` is the partial output); `status` is
/// `awaiting_approval` when the turn paused for an approval.
class DoneEvent extends StreamEvent {
  const DoneEvent({required this.data});
  final Map<String, dynamic> data;

  String? get text => data['text'] as String?;
  int? get latencyMs => (data['latency_ms'] as num?)?.toInt();
  bool get interrupted => data['interrupted'] == true;
  String? get status => data['status'] as String?;
  bool get awaitingApproval => status == MessageStatus.awaitingApproval;

  /// The model id actually used for the turn.
  String? get model => data['model'] as String?;
  String? get generationId => data['generation_id'] as String?;
}

/// The persisted assistant message — the canonical end of a turn.
class AssistantMessageEvent extends StreamEvent {
  const AssistantMessageEvent({required this.data});
  final Map<String, dynamic> data;

  String? get id => data['id'] as String?;
  bool get interrupted => data['interrupted'] == true;

  Map<String, dynamic> get _meta => (data['meta'] as Map?)?.cast<String, dynamic>() ?? const {};

  String? get status => (data['status'] as String?) ?? _meta['status'] as String?;
  bool get awaitingApproval => status == MessageStatus.awaitingApproval;
  ApprovalRequest? get approval => _approvalFrom(data['approval'] ?? _meta['approval']);
  String? get model => (data['model'] as String?) ?? _meta['model'] as String?;
  String? get generationId =>
      (data['generation_id'] as String?) ?? _meta['generation_id'] as String?;

  /// Ids of the memories injected into this turn (`meta.memories_used`).
  List<String> get memoriesUsed => _idsFrom(data['memories_used'] ?? _meta['memories_used']);

  /// Files produced by tools during the turn (`data.artifacts` / `meta.artifacts`).
  List<Attachment> get artifacts => attachmentsFrom(data['artifacts'] ?? _meta['artifacts']);

  /// The stored spoken reply, for replay (`data.audio` / `meta.audio`).
  MessageAudio? get audio => _audioFrom(data['audio'] ?? _meta['audio']);

  ChatMessage toMessage(String sessionId) {
    final meta = _meta;
    return ChatMessage(
      id: id ?? 'assistant-${DateTime.now().microsecondsSinceEpoch}',
      sessionId: (data['session_id'] as String?) ?? sessionId,
      role: MessageRole.assistant,
      content: (data['content'] as String?) ?? '',
      tokens: (data['tokens'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(data['created_at'] as String? ?? '') ?? DateTime.now(),
      citations: _citationsFrom(data['citations'] ?? meta['citations']),
      toolCalls: _toolCallsFrom(data['tool_calls'] ?? meta['tool_calls']),
      interrupted: interrupted || status == MessageStatus.interrupted,
      status: status ?? (interrupted ? MessageStatus.interrupted : null),
      approval: approval,
      model: model,
      parentId: data['parent_id'] as String?,
      siblings: _siblingsFrom(data['siblings']),
      feedback: _feedbackFrom(meta['feedback']),
      memoriesUsed: memoriesUsed,
      generationId: generationId,
      artifacts: artifacts,
      audio: audio,
    );
  }
}

/// A file a tool produced during the turn (`run_python` plots, generated
/// documents, …). Arrives while the turn runs; the final `assistant_message`
/// lists the same artifacts again.
class ArtifactEvent extends StreamEvent {
  const ArtifactEvent({required this.data});
  final Map<String, dynamic> data;

  Attachment get artifact => Attachment.fromJson(data);
}

/// One sentence group of the spoken reply (`voice_reply`), base64-encoded
/// audio in [data]. Chunks arrive in order after `done` and before
/// `assistant_message`; play them back to back.
class AudioChunkEvent extends StreamEvent {
  const AudioChunkEvent({required this.data});
  final Map<String, dynamic> data;

  int get index => (data['index'] as num?)?.toInt() ?? 0;
  String get text => (data['text'] as String?) ?? '';
  String? get format => data['format'] as String?;
  String get mimeType =>
      (data['mime_type'] as String?) ?? (format == null ? 'audio/mpeg' : 'audio/$format');

  /// The decoded clip; empty when the payload is missing or not valid base64.
  Uint8List get bytes {
    final raw = data['data'];
    if (raw is! String || raw.isEmpty) return Uint8List(0);
    try {
      return base64Decode(base64.normalize(raw));
    } on FormatException {
      return Uint8List(0);
    }
  }
}

/// End of the spoken reply: how many chunks were sent and, when the server
/// keeps spoken replies, the attachment holding the whole clip. [error] is
/// set when synthesis failed midway (the text reply is unaffected).
class AudioDoneEvent extends StreamEvent {
  const AudioDoneEvent({required this.data});
  final Map<String, dynamic> data;

  int get chunks => (data['chunks'] as num?)?.toInt() ?? 0;
  String? get error => data['error'] as String?;
  Attachment? get attachment {
    final raw = data['attachment'];
    if (raw is! Map) return null;
    final a = Attachment.fromJson(raw.cast<String, dynamic>());
    return a.id.isEmpty ? null : a;
  }
}

class ErrorEvent extends StreamEvent {
  const ErrorEvent({required this.message, this.code, this.details});
  final String message;

  /// Backend error code (`busy`, `unauthorized`, `rate_limited`, …).
  final String? code;

  /// Structured details, e.g. the budget figures of a `quota_exceeded` frame.
  final Map<String, dynamic>? details;

  bool get isBusy => code == 'busy';

  /// The workspace's monthly budget is spent (same as HTTP 429 `quota_exceeded`).
  bool get isQuotaExceeded => code == 'quota_exceeded';

  /// The connection died (reported by the transport, not the server) — the
  /// turn may be resumable through the generation's event replay.
  bool get isTransportError => code == 'network_error';

  /// `conflict` / `not_found` — an approval that was already resolved or
  /// expired (WebSocket transport reports these as error frames).
  bool get isStaleApproval => code == 'conflict' || code == 'not_found';
}

class UnknownEvent extends StreamEvent {
  const UnknownEvent({required this.type});
  final String type;
}
