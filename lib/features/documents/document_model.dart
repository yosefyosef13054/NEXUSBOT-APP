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

  bool get isInFlight =>
      status == DocumentStatus.pending || status == DocumentStatus.processing;
}

/// Result of `POST /documents`. [queued] is false when the same file was
/// already uploaded by this user — [document] is then the existing one.
class UploadResult {
  const UploadResult({required this.document, required this.queued});
  final Document document;
  final bool queued;
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
