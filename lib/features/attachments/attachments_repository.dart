import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import 'attachment_model.dart';

/// Downloaded attachment content.
class AttachmentBytes {
  const AttachmentBytes({required this.bytes, required this.mimeType});
  final Uint8List bytes;
  final String mimeType;
}

/// `POST / GET / DELETE /sessions/{id}/attachments…` and the authenticated
/// content download.
class AttachmentsRepository {
  AttachmentsRepository(this._client);
  final ApiClient _client;

  /// Server-side limit (`MAX_ATTACHMENT_MB`); larger uploads are refused
  /// with a 422 before any bytes leave the device.
  static const maxUploadBytes = 20 * 1024 * 1024;

  /// Uploads [bytes] as `file` (multipart). The server sniffs the content:
  /// images get `kind: image` (+ `width` / `height`), audio is transcribed and
  /// documents have their text extracted (`text_excerpt`). Throws
  /// [ApiException] 422 `validation_error` for unsupported or oversized files.
  Future<Attachment> upload({
    required String sessionId,
    required Uint8List bytes,
    required String filename,
    void Function(double progress)? onProgress,
  }) async {
    if (bytes.isEmpty) {
      throw ApiException(code: 'validation_error', message: 'The file is empty', statusCode: 422);
    }
    if (bytes.length > maxUploadBytes) {
      throw ApiException(
        code: 'validation_error',
        message: 'The file is larger than ${formatBytes(maxUploadBytes)}',
        statusCode: 422,
      );
    }
    final form = FormData.fromMap({'file': MultipartFile.fromBytes(bytes, filename: filename)});
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/attachments',
      method: 'POST',
      data: form,
      options: Options(sendTimeout: const Duration(minutes: 5)),
      onSendProgress: (sent, total) {
        if (total > 0 && onProgress != null) onProgress(sent / total);
      },
    );
    return Attachment.fromJson(res.data!);
  }

  /// Every attachment of the session (uploads, artifacts, spoken replies).
  Future<List<Attachment>> list(String sessionId) async {
    final res = await _client.request<Map<String, dynamic>>('/sessions/$sessionId/attachments');
    return attachmentsFrom(res.data?['items']);
  }

  /// Full metadata incl. `text_excerpt`.
  Future<Attachment> get(String sessionId, String attachmentId) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/attachments/$attachmentId',
    );
    return Attachment.fromJson(res.data!);
  }

  /// Soft-deletes an attachment that is not bound to a message yet.
  Future<void> delete(String sessionId, String attachmentId) async {
    await _client.request<dynamic>(
      '/sessions/$sessionId/attachments/$attachmentId',
      method: 'DELETE',
    );
  }

  /// Absolute URL for an attachment's [Attachment.url]: the server sends the
  /// path on the API host (`/api/v1/sessions/…/content`), which is resolved
  /// against the origin of the configured base URL. Absolute URLs (presigned
  /// storage links) pass through unchanged.
  Uri resolveUrl(String url) => resolveAgainst(_client.dio.options.baseUrl, url);

  /// See [resolveUrl]; split out so it can be tested without a client.
  static Uri resolveAgainst(String baseUrl, String url) {
    final target = Uri.parse(url);
    if (target.hasScheme) return target;
    final base = Uri.parse(baseUrl);
    if (url.startsWith('/')) {
      return Uri(scheme: base.scheme, host: base.host, port: base.port).resolve(url);
    }
    final root = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    return Uri.parse(root).resolve(url);
  }

  /// Downloads the content behind [url] (an attachment's `url`, or an absolute
  /// link). The first request carries the bearer and `X-Org-Id` like any API
  /// call; a `307` to a presigned storage URL is followed with a bare request,
  /// since the redirect target must not receive the authorization header.
  Future<AttachmentBytes> fetchContent(String url) async {
    final target = resolveUrl(url).toString();
    final Response<List<int>> res;
    try {
      res = await _client.dio.get<List<int>>(
        target,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: false,
          receiveTimeout: const Duration(minutes: 5),
          validateStatus: (s) => s != null && s < 500,
        ),
      );
    } on DioException catch (e) {
      throw _toApiException(e);
    }
    final status = res.statusCode ?? 0;
    if (_isRedirect(status)) {
      final location = res.headers.value('location');
      if (location == null || location.isEmpty) {
        throw ApiException(code: 'network_error', message: 'Redirect without a location');
      }
      final next = Uri.parse(target).resolve(location).toString();
      return _fetchBare(next);
    }
    return _bytesOrThrow(res);
  }

  /// A plain download with no API headers (presigned URLs are self-authenticating).
  Future<AttachmentBytes> _fetchBare(String url) async {
    final bare = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(minutes: 5),
        responseType: ResponseType.bytes,
        followRedirects: true,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    try {
      final res = await bare.get<List<int>>(url);
      return _bytesOrThrow(res);
    } on DioException catch (e) {
      throw _toApiException(e);
    } finally {
      bare.close();
    }
  }

  static bool _isRedirect(int status) =>
      status == 301 || status == 302 || status == 303 || status == 307 || status == 308;

  static AttachmentBytes _bytesOrThrow(Response<List<int>> res) {
    final status = res.statusCode ?? 0;
    final data = res.data ?? const <int>[];
    if (status < 200 || status >= 300) {
      throw _envelopeFromBytes(data, status, res.headers.value('x-request-id'));
    }
    final mime = res.headers.value('content-type')?.split(';').first.trim();
    return AttachmentBytes(
      bytes: data is Uint8List ? data : Uint8List.fromList(data),
      mimeType: mime == null || mime.isEmpty ? 'application/octet-stream' : mime,
    );
  }

  static ApiException _envelopeFromBytes(List<int> data, int status, String? requestId) {
    Object? json;
    try {
      json = jsonDecode(utf8.decode(data));
    } on FormatException {
      json = null;
    }
    return ApiException.fromEnvelope(json, statusCode: status, headerRequestId: requestId) ??
        ApiException(
          code: 'http_$status',
          message: 'Download failed ($status)',
          statusCode: status,
          requestId: requestId,
        );
  }

  static ApiException _toApiException(DioException e) {
    final res = e.response;
    final body = res?.data;
    if (body is List<int>) {
      return _envelopeFromBytes(body, res?.statusCode ?? 0, res?.headers.value('x-request-id'));
    }
    return ApiException(
      code: e.type == DioExceptionType.cancel ? 'cancelled' : 'network_error',
      message: e.message ?? 'Network error',
      statusCode: res?.statusCode,
    );
  }
}

final attachmentsRepositoryProvider = FutureProvider<AttachmentsRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return AttachmentsRepository(client);
});

/// Loads attachment content for widgets (thumbnails, previews, playback) and
/// keeps the last few downloads in memory so a rebuild never refetches.
///
/// Abstract so widget tests can serve bytes without a network.
abstract class AttachmentContentLoader {
  Future<AttachmentBytes> load(String url);
}

class CachingAttachmentContentLoader implements AttachmentContentLoader {
  CachingAttachmentContentLoader(this._repository, {this.maxEntries = 48});

  final Future<AttachmentsRepository> _repository;
  final int maxEntries;
  final _cache = <String, Future<AttachmentBytes>>{};

  @override
  Future<AttachmentBytes> load(String url) {
    final cached = _cache.remove(url);
    if (cached != null) {
      _cache[url] = cached; // most recently used last
      return cached;
    }
    final future = _repository.then((repo) => repo.fetchContent(url));
    _cache[url] = future;
    // A failed download must not be cached forever (the caller still sees the error).
    future.then<void>(
      (_) {},
      onError: (Object _) {
        _cache.remove(url);
      },
    );
    while (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    return future;
  }
}

final attachmentContentLoaderProvider = Provider<AttachmentContentLoader>((ref) {
  return CachingAttachmentContentLoader(ref.watch(attachmentsRepositoryProvider.future));
});
