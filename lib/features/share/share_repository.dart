import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import 'share_model.dart';

/// Export (`GET /sessions/{id}/export`) and share links
/// (`/sessions/{id}/share`).
class ShareRepository {
  ShareRepository(this._client);
  final ApiClient _client;

  /// Downloads the active branch as Markdown or JSON.
  Future<ExportedChat> export(
    String sessionId, {
    ExportFormat format = ExportFormat.markdown,
    bool includeTools = true,
  }) async {
    final res = await _client.request<List<int>>(
      '/sessions/$sessionId/export',
      query: {'format': format.wire, 'include_tools': includeTools},
      options:
          Options(responseType: ResponseType.bytes, receiveTimeout: const Duration(minutes: 2)),
    );
    final data = res.data ?? const <int>[];
    final mime = res.headers.value('content-type')?.split(';').first.trim();
    return ExportedChat(
      bytes: data is Uint8List ? data : Uint8List.fromList(data),
      filename: filenameFromDisposition(res.headers.value('content-disposition')) ??
          'chat.${format.extension}',
      mimeType: mime == null || mime.isEmpty ? format.mimeType : mime,
    );
  }

  /// `attachment; filename="chat.md"` → `chat.md` (also the RFC 5987
  /// `filename*=UTF-8''…` form). Null when the header names no file.
  static String? filenameFromDisposition(String? header) {
    if (header == null) return null;
    final star = RegExp("filename\\*=(?:UTF-8|utf-8)''([^;]+)").firstMatch(header);
    if (star != null) {
      final raw = star.group(1)!.trim();
      try {
        return Uri.decodeComponent(raw);
      } on ArgumentError {
        return raw;
      }
    }
    final quoted = RegExp(r'filename="([^"]+)"').firstMatch(header);
    if (quoted != null) return quoted.group(1);
    final bare = RegExp(r'filename=([^;]+)').firstMatch(header);
    return bare?.group(1)?.trim();
  }

  /// `POST /sessions/{id}/share {expires_in_hours?}` → the link, with its
  /// token (shown once). [expiresInHours] null = the server default.
  Future<ShareLink> createShare(String sessionId, {int? expiresInHours}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/share',
      method: 'POST',
      data: {if (expiresInHours != null) 'expires_in_hours': expiresInHours},
    );
    return ShareLink.fromJson(res.data ?? const {});
  }

  /// Active links (without tokens) and their view counts.
  Future<List<ShareLink>> listShares(String sessionId) async {
    final res = await _client.request<Map<String, dynamic>>('/sessions/$sessionId/share');
    return (res.data?['items'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => ShareLink.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// Revokes one link, or every link of the session when [shareId] is null.
  Future<void> revokeShares(String sessionId, {String? shareId}) async {
    await _client.request<dynamic>(
      '/sessions/$sessionId/share',
      method: 'DELETE',
      query: {if (shareId != null) 'share_id': shareId},
    );
  }

  /// Absolute form of a link's `url` (the server sends a path when it has no
  /// `PUBLIC_BASE_URL`): resolved against the API origin.
  Uri resolveShareUrl(String url) {
    final target = Uri.parse(url);
    if (target.hasScheme) return target;
    final base = Uri.parse(_client.dio.options.baseUrl);
    return Uri(scheme: base.scheme, host: base.host, port: base.port).resolve(url);
  }

  /// Decodes an error envelope out of a bytes response, for callers that
  /// stream downloads outside [ApiClient.request].
  static String describeBytesError(List<int> body, int status) {
    try {
      final json = jsonDecode(utf8.decode(body));
      final e = ApiException.fromEnvelope(json, statusCode: status);
      if (e != null) return e.userMessage;
    } on FormatException {
      // Not JSON.
    }
    return 'Request failed ($status)';
  }
}

final shareRepositoryProvider = FutureProvider<ShareRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return ShareRepository(client);
});
