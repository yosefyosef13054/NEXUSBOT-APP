import 'dart:typed_data';

/// `GET /sessions/{id}/export?format=`.
enum ExportFormat {
  markdown('markdown', 'md', 'text/markdown'),
  json('json', 'json', 'application/json');

  const ExportFormat(this.wire, this.extension, this.mimeType);
  final String wire;
  final String extension;
  final String mimeType;
}

/// The downloaded transcript: bytes plus the name / type the server chose
/// (`Content-Disposition: attachment; filename=…`).
class ExportedChat {
  const ExportedChat({required this.bytes, required this.filename, required this.mimeType});
  final Uint8List bytes;
  final String filename;
  final String mimeType;
}

/// A read-only link to a conversation. [token] and [url] are only present on
/// the response that created the link; listings carry `null` for both.
class ShareLink {
  const ShareLink({
    required this.id,
    required this.expiresAt,
    this.token,
    this.url,
    this.views = 0,
  });

  factory ShareLink.fromJson(Map<String, dynamic> j) => ShareLink(
        id: (j['id'] as String?) ?? '',
        token: j['token'] as String?,
        url: j['url'] as String?,
        expiresAt: DateTime.tryParse(j['expires_at'] as String? ?? '') ?? DateTime.now(),
        views: (j['views'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String? token;

  /// Absolute when the server knows its public base URL, else
  /// `/api/v1/shared/{token}`.
  final String? url;
  final DateTime expiresAt;
  final int views;

  bool get isExpired => expiresAt.isBefore(DateTime.now());
}
