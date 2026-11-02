import 'package:dio/dio.dart' show FormData, MultipartFile, Options;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/paging.dart';
import '../auth/auth_providers.dart';
import 'document_model.dart';

class DocumentsRepository {
  DocumentsRepository(this._client);
  final ApiClient _client;

  /// `GET /documents`, optionally filtered to one collection.
  Future<List<Document>> list({
    int page = 1,
    int pageSize = 50,
    String? collectionId,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/documents',
      query: {
        'page': page,
        'page_size': pageSize,
        if (collectionId != null) 'collection_id': collectionId,
      },
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
    String? collectionId,
    void Function(double progress)? onProgress,
  }) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(path, filename: filename),
      if (sessionId != null) 'session_id': sessionId,
      if (collectionId != null) 'collection_id': collectionId,
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
    return UploadResult.fromJson(res.data!);
  }

  /// `POST /documents/from-url` — the server fetches and ingests the page.
  /// Throws [ApiException] 422 (`validation_error`) for unreachable,
  /// unsupported or private URLs; the message is user-facing.
  Future<UploadResult> addFromUrl({
    required String url,
    String? sessionId,
    String? collectionId,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/documents/from-url',
      method: 'POST',
      data: {
        'url': url,
        if (sessionId != null) 'session_id': sessionId,
        if (collectionId != null) 'collection_id': collectionId,
      },
      // Fetching a remote page can take a while.
      options: Options(receiveTimeout: const Duration(minutes: 2)),
    );
    return UploadResult.fromJson(res.data!);
  }

  /// `PATCH /documents/{id} {collection_id}` — null unassigns the document.
  Future<Document> moveToCollection(String id, String? collectionId) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/documents/$id',
      method: 'PATCH',
      data: {'collection_id': collectionId},
    );
    return Document.fromJson(res.data!);
  }

  Future<Document> rename(String id, String name) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/documents/$id',
      method: 'PATCH',
      data: {'name': name},
    );
    return Document.fromJson(res.data!);
  }

  Future<void> delete(String id) async {
    await _client.request<Map<String, dynamic>>('/documents/$id', method: 'DELETE');
  }

  // ---- Chunks (citation viewer) ----

  Future<PageResult<DocumentChunk>> listChunks(
    String documentId, {
    int page = 1,
    int pageSize = 50,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/documents/$documentId/chunks',
      query: {'page': page, 'page_size': pageSize},
    );
    return PageResult.fromJson(res.data!, DocumentChunk.fromJson);
  }

  Future<DocumentChunk> getChunk(String documentId, String chunkId) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/documents/$documentId/chunks/$chunkId',
    );
    return DocumentChunk.fromJson(res.data!);
  }
}

final documentsRepositoryProvider = FutureProvider<DocumentsRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return DocumentsRepository(client);
});

/// The collection the Documents screen is filtered to (null = all). Also the
/// default target for uploads started from that screen.
final documentCollectionFilterProvider = StateProvider<String?>((ref) {
  // Reset the filter when the signed-in user changes.
  ref.watch(currentUserProvider.select((u) => u.valueOrNull?.id));
  return null;
});

final documentListProvider = FutureProvider.autoDispose<List<Document>>((ref) async {
  final repo = await ref.watch(documentsRepositoryProvider.future);
  final collectionId = ref.watch(documentCollectionFilterProvider);
  return repo.list(collectionId: collectionId);
});
