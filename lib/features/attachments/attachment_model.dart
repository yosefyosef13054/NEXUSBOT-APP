import 'package:collection/collection.dart';

/// What an attachment is, as sniffed by the server from its bytes.
enum AttachmentKind {
  image,
  file,
  audio,
  artifact,
  unknown;

  static AttachmentKind fromString(String? s) =>
      AttachmentKind.values.firstWhereOrNull((k) => k.name == s) ?? AttachmentKind.unknown;
}

/// A binary that travels with a chat message: an upload the user attached
/// (`POST /sessions/{id}/attachments`), a file a tool produced (an artifact)
/// or a spoken reply.
///
/// Parses both the full `AttachmentRead` (upload / get / list responses, with
/// [sessionId], [messageId], [textExcerpt] and [createdAt]) and the compact
/// summary carried by `user_message.data.attachments`,
/// `assistant_message.data.artifacts`, `MessageRead.meta.attachments` /
/// `meta.artifacts` and the `artifact` stream frame.
class Attachment {
  const Attachment({
    required this.id,
    required this.kind,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.url,
    this.width,
    this.height,
    this.description,
    this.hasText = false,
    this.textExcerpt,
    this.sessionId,
    this.messageId,
    this.createdAt,
  });

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
        id: (j['id'] as String?) ?? '',
        kind: AttachmentKind.fromString(j['kind'] as String?),
        name: (j['name'] as String?) ?? 'attachment',
        mimeType: (j['mime_type'] as String?) ?? 'application/octet-stream',
        sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
        width: (j['width'] as num?)?.toInt(),
        height: (j['height'] as num?)?.toInt(),
        url: (j['url'] as String?) ?? '',
        description: j['description'] as String?,
        hasText: j['has_text'] == true,
        textExcerpt: j['text_excerpt'] as String?,
        sessionId: j['session_id'] as String?,
        messageId: j['message_id'] as String?,
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
      );

  final String id;
  final AttachmentKind kind;
  final String name;
  final String mimeType;
  final int sizeBytes;
  final int? width;
  final int? height;

  /// Content endpoint (`/api/v1/sessions/{id}/attachments/{aid}/content`),
  /// relative to the API host unless the server sent an absolute URL. Resolve
  /// it through `AttachmentsRepository.resolveUrl`.
  final String url;
  final String? description;

  /// The model sees extracted text / a transcript for this attachment.
  final bool hasText;

  /// Beginning of the extracted text (full read only).
  final String? textExcerpt;
  final String? sessionId;

  /// Set once the attachment is bound to a message (it cannot be reused then).
  final String? messageId;
  final DateTime? createdAt;

  bool get isImage => kind == AttachmentKind.image || mimeType.startsWith('image/');
  bool get isAudio => kind == AttachmentKind.audio || mimeType.startsWith('audio/');
  bool get isArtifact => kind == AttachmentKind.artifact;

  /// Whether the content can be shown inline as a picture.
  bool get isRenderableImage => mimeType.startsWith('image/');

  /// `48 KB`, `1.2 MB` — human-readable size.
  String get sizeLabel => formatBytes(sizeBytes);

  /// Summary form (what the server stores in `meta.attachments`).
  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'name': name,
        'mime_type': mimeType,
        'size_bytes': sizeBytes,
        'width': width,
        'height': height,
        'url': url,
        'description': description,
        'has_text': hasText,
        if (textExcerpt != null) 'text_excerpt': textExcerpt,
        if (sessionId != null) 'session_id': sessionId,
        if (messageId != null) 'message_id': messageId,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      };

  Attachment copyWith({String? messageId}) => Attachment(
        id: id,
        kind: kind,
        name: name,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        width: width,
        height: height,
        url: url,
        description: description,
        hasText: hasText,
        textExcerpt: textExcerpt,
        sessionId: sessionId,
        messageId: messageId ?? this.messageId,
        createdAt: createdAt,
      );
}

/// Parses a list of attachment summaries; tolerant of nulls and junk.
List<Attachment> attachmentsFrom(Object? raw) => (raw as List? ?? const [])
    .whereType<Map>()
    .map((m) => Attachment.fromJson(m.cast<String, dynamic>()))
    .where((a) => a.id.isNotEmpty)
    .toList();

/// Upserts [incoming] into [existing] by id (an artifact announced by a stream
/// frame and again by the final message is listed once).
List<Attachment> mergeAttachments(List<Attachment> existing, Iterable<Attachment> incoming) {
  final out = List<Attachment>.of(existing);
  for (final a in incoming) {
    final i = out.indexWhere((e) => e.id == a.id);
    if (i >= 0) {
      out[i] = a;
    } else {
      out.add(a);
    }
  }
  return out;
}

/// `48 KB`, `1.2 MB`, `0 B`.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(bytes < 10240 ? 1 : 0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
