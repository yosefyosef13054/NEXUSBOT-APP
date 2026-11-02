import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/paging.dart';
import '../auth/auth_providers.dart';
import 'collection_model.dart';

class CollectionsRepository {
  CollectionsRepository(this._client);
  final ApiClient _client;

  Future<PageResult<Collection>> list({int page = 1, int pageSize = 50}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/collections',
      query: {'page': page, 'page_size': pageSize},
    );
    return PageResult.fromJson(res.data!, Collection.fromJson);
  }

  /// Every collection of the user (follows pagination).
  Future<List<Collection>> listAll() async {
    final out = <Collection>[];
    var page = 1;
    while (true) {
      final result = await list(page: page, pageSize: 50);
      out.addAll(result.items);
      if (!result.hasMore || result.items.isEmpty) return out;
      page++;
    }
  }

  Future<Collection> get(String id) async {
    final res = await _client.request<Map<String, dynamic>>('/collections/$id');
    return Collection.fromJson(res.data!);
  }

  Future<Collection> create({required String name, String? description}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/collections',
      method: 'POST',
      data: {
        'name': name,
        if (description != null && description.isNotEmpty) 'description': description,
      },
    );
    return Collection.fromJson(res.data!);
  }

  Future<Collection> update(String id, {String? name, String? description}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/collections/$id',
      method: 'PATCH',
      data: {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
      },
    );
    return Collection.fromJson(res.data!);
  }

  /// Documents are unassigned unless [deleteDocuments] is true.
  Future<void> delete(String id, {bool deleteDocuments = false}) async {
    await _client.request<Map<String, dynamic>>(
      '/collections/$id',
      method: 'DELETE',
      query: {'delete_documents': deleteDocuments},
    );
  }
}

final collectionsRepositoryProvider = FutureProvider<CollectionsRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return CollectionsRepository(client);
});

/// The user's collections, cached for the app session (invalidate after any
/// mutation or on pull-to-refresh) and reloaded when the user changes.
final collectionListProvider = FutureProvider<List<Collection>>((ref) async {
  ref.watch(currentUserProvider.select((u) => u.valueOrNull?.id));
  final repo = await ref.watch(collectionsRepositoryProvider.future);
  return repo.listAll();
});
