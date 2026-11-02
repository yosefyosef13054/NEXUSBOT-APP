enum DocumentStatus { pending, processing, ready, failed, unknown }

class Document {
  const Document({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.status,
    required this.createdAt,
    this.error,
    this.progress,
    this.sha256,
    this.collectionId,
    this.sessionId,
    this.sourceUrl,
  });

  factory Document.fromJson(Map<String, dynamic> j) {
    final meta = (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Document(
      id: j['id'] as String,
      name: j['name'] as String,
      mimeType: (j['mime_type'] as String?) ?? 'application/octet-stream',
      sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
      status: _parseStatus(j['status'] as String? ?? ''),
      error: j['error'] as String?,
      createdAt: DateTime.parse(j['created_at'] as String),
      progress: (meta['progress'] as num?)?.toInt().clamp(0, 100),
      sha256: meta['sha256'] as String?,
      collectionId: j['collection_id'] as String?,
      sessionId: j['session_id'] as String?,
      sourceUrl: j['source_url'] as String?,
    );
  }

  final String id;
  final String name;
  final String mimeType;
  final int sizeBytes;
  final DocumentStatus status;
  final String? error;
  final DateTime createdAt;

  /// Ingest progress (0–100) reported in `meta.progress` while processing.
  final int? progress;

  /// Content hash (`meta.sha256`); the server de-duplicates uploads on it.
  final String? sha256;

  /// The collection (knowledge base) the document belongs to, if any.
  final String? collectionId;

  /// Set when the document is scoped to a single chat.
  final String? sessionId;

  /// The page this document was ingested from (`POST /documents/from-url`).
  final String? sourceUrl;

  /// Host of [sourceUrl], for a compact "from example.com" hint.
  String? get sourceHost {
    final url = sourceUrl;
    if (url == null) return null;
    final host = Uri.tryParse(url)?.host;
    return host == null || host.isEmpty ? null : host;
  }

  bool get isInFlight => status == DocumentStatus.pending || status == DocumentStatus.processing;
}

/// Result of `POST /documents` / `POST /documents/from-url`. [queued] is
/// false when the same content was already uploaded by this user —
/// [document] is then the existing one.
class UploadResult {
  const UploadResult({required this.document, required this.queued});

  factory UploadResult.fromJson(Map<String, dynamic> body) => UploadResult(
        document: Document.fromJson((body['document'] as Map).cast<String, dynamic>()),
        queued: body['queued'] != false,
      );

  final Document document;
  final bool queued;
}

/// One indexed chunk of a document (`GET /documents/{id}/chunks[/{chunk_id}]`).
class DocumentChunk {
  const DocumentChunk({
    required this.id,
    required this.chunkIndex,
    required this.content,
    this.page,
    this.section,
    this.startIndex,
    this.endIndex,
    this.tokens,
  });

  factory DocumentChunk.fromJson(Map<String, dynamic> j) => DocumentChunk(
        id: (j['id'] as String?) ?? '',
        chunkIndex: (j['chunk_index'] as num?)?.toInt() ?? 0,
        content: (j['content'] as String?) ?? '',
        page: (j['page'] as num?)?.toInt(),
        section: j['section'] as String?,
        startIndex: (j['start_index'] as num?)?.toInt(),
        endIndex: (j['end_index'] as num?)?.toInt(),
        tokens: (j['tokens'] as num?)?.toInt(),
      );

  final String id;
  final int chunkIndex;
  final String content;
  final int? page;
  final String? section;
  final int? startIndex;
  final int? endIndex;
  final int? tokens;
}

DocumentStatus _parseStatus(String s) {
  switch (s) {
    case 'pending':
      return DocumentStatus.pending;
    case 'processing':
      return DocumentStatus.processing;
    case 'ready':
      return DocumentStatus.ready;
    case 'failed':
      return DocumentStatus.failed;
    default:
      return DocumentStatus.unknown;
  }
}
