/// Typed API failure surfaced to the UI — screens never import `dio`.
///
/// Mirrors the backend error envelope:
/// `{ "error": { "code", "message", "details" }, "request_id": "…" }`.
class ApiException implements Exception {
  ApiException({
    required this.code,
    required this.message,
    this.details,
    this.statusCode,
    this.requestId,
  });

  /// Builds an exception from a decoded error envelope, or returns `null`
  /// when [body] is not one. [headerRequestId] (the `X-Request-Id` header)
  /// is used when the envelope carries no top-level `request_id`.
  static ApiException? fromEnvelope(
    Object? body, {
    int? statusCode,
    String? headerRequestId,
  }) {
    if (body is! Map || body['error'] is! Map) return null;
    final error = (body['error'] as Map).cast<String, dynamic>();
    return ApiException(
      code: (error['code'] as String?) ?? 'unknown',
      message: (error['message'] as String?) ?? 'Request failed',
      details: (error['details'] as Map?)?.cast<String, dynamic>(),
      statusCode: statusCode,
      requestId: (body['request_id'] as String?) ?? headerRequestId,
    );
  }

  final String code;
  final String message;
  final Map<String, dynamic>? details;
  final int? statusCode;

  /// Server-side correlation id. Quote it when reporting a problem — every
  /// backend log line for the request carries it.
  final String? requestId;

  bool get isAuth => code == 'unauthorized' || statusCode == 401;
  bool get isRateLimited => code == 'rate_limited' || statusCode == 429;

  /// First 8 characters of [requestId]: short enough for a banner, long
  /// enough to find the request in server logs.
  String? get shortRequestId {
    final id = requestId;
    if (id == null || id.isEmpty) return null;
    return id.length > 8 ? id.substring(0, 8) : id;
  }

  /// Message for banners/snackbars; appends the short request id when present.
  String get userMessage {
    final short = shortRequestId;
    return short == null ? message : '$message (ref $short)';
  }

  @override
  String toString() => requestId == null
      ? 'ApiException($code: $message)'
      : 'ApiException($code: $message, request_id=$requestId)';
}

/// Human-readable text for any error thrown by a repository call.
String errorText(Object error) =>
    error is ApiException ? error.userMessage : error.toString();
