import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/paging.dart';
import '../auth/auth_providers.dart';
import '../orgs/orgs_repository.dart';
import 'memory_model.dart';

class MemoryRepository {
  MemoryRepository(this._client);
  final ApiClient _client;

  /// `GET /memories?page=&page_size=`.
  Future<PageResult<Memory>> list({int page = 1, int pageSize = 50}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/memories',
      query: {'page': page, 'page_size': pageSize},
    );
    return PageResult.fromJson(res.data ?? const {}, Memory.fromJson);
  }

  /// Follows pagination.
  Future<List<Memory>> listAll() async {
    final out = <Memory>[];
    var page = 1;
    while (true) {
      final result = await list(page: page, pageSize: 50);
      out.addAll(result.items);
      if (!result.hasMore || result.items.isEmpty) return out;
      page++;
    }
  }

  Future<Memory> create({
    required String content,
    MemoryKind kind = MemoryKind.fact,
    int importance = 3,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/memories',
      method: 'POST',
      data: {'content': content, 'kind': kind.name, 'importance': importance},
    );
    return Memory.fromJson(res.data!);
  }

  /// `PATCH /memories/{id}` — only the given fields are sent.
  Future<Memory> update(
    String id, {
    String? content,
    MemoryKind? kind,
    int? importance,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/memories/$id',
      method: 'PATCH',
      data: {
        if (content != null) 'content': content,
        if (kind != null) 'kind': kind.name,
        if (importance != null) 'importance': importance,
      },
    );
    return Memory.fromJson(res.data!);
  }

  Future<void> delete(String id) async {
    await _client.request<Map<String, dynamic>>('/memories/$id', method: 'DELETE');
  }

  /// `DELETE /memories` — forgets everything.
  Future<void> clearAll() async {
    await _client.request<Map<String, dynamic>>('/memories', method: 'DELETE');
  }
}

final memoryRepositoryProvider = FutureProvider<MemoryRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return MemoryRepository(client);
});

/// Everything NexusBot remembers about the user in the active workspace;
/// invalidate after any mutation.
final memoryListProvider = FutureProvider<List<Memory>>((ref) async {
  ref.watch(currentUserProvider.select((u) => u.valueOrNull?.id));
  ref.watch(activeOrgIdProvider);
  final repo = await ref.watch(memoryRepositoryProvider.future);
  return repo.listAll();
});
