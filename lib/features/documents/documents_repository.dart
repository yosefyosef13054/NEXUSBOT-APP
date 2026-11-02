import 'package:dio/dio.dart' show FormData, MultipartFile, Options;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import 'document_model.dart';

class DocumentsRepository {
  DocumentsRepository(this._client);
  final ApiClient _client;

  Future<List<Document>> list({int page = 1, int pageSize = 50}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/documents',
      query: {'page': page, 'page_size': pageSize},
    );
    return (res.data!['items'] as List)
        .cast<Map>()
        .map((m) => Document.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<Document> get(String id) async {
    final res = await _client.request<Map<String, dynamic>>('/documents/$id');
    return Document.fromJson(res.data!);
  }

  /// Upload with progress reporting (0..1). Caller can rebuild a progress bar
  /// from the `onProgress` callback.
  ///
  /// A duplicate upload (same content hash) comes back with `queued: false`
  /// and the existing document; callers should treat that as success.
  Future<UploadResult> upload({
    required String path,
    required String filename,
    String? sessionId,
    void Function(double progress)? onProgress,
  }) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(path, filename: filename),
      if (sessionId != null) 'session_id': sessionId,
    });
    final res = await _client.request<Map<String, dynamic>>(
      '/documents',
      method: 'POST',
      data: form,
      // Large files on slow links must not trip the default send timeout.
      options: Options(sendTimeout: const Duration(minutes: 10)),
      onSendProgress: (sent, total) {
        if (total > 0 && onProgress != null) onProgress(sent / total);
      },
    );
    final body = res.data!;
    return UploadResult(
      document: Document.fromJson((body['document'] as Map).cast<String, dynamic>()),
      queued: body['queued'] != false,
    );
  }

  Future<void> delete(String id) async {
    await _client.request<Map<String, dynamic>>('/documents/$id', method: 'DELETE');
  }
}

final documentsRepositoryProvider = FutureProvider<DocumentsRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return DocumentsRepository(client);
});

final documentListProvider = FutureProvider.autoDispose<List<Document>>((ref) async {
  final repo = await ref.watch(documentsRepositoryProvider.future);
  return repo.list();
});
