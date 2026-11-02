import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/paging.dart';
import '../auth/auth_providers.dart';
import '../orgs/orgs_repository.dart';
import 'assistant_model.dart';

class AssistantsRepository {
  AssistantsRepository(this._client);
  final ApiClient _client;

  /// `GET /assistants?page=&page_size=` — every assistant of the active org.
  Future<PageResult<Assistant>> list({int page = 1, int pageSize = 50}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/assistants',
      query: {'page': page, 'page_size': pageSize},
    );
    return PageResult.fromJson(res.data ?? const {}, Assistant.fromJson);
  }

  /// Follows pagination.
  Future<List<Assistant>> listAll() async {
    final out = <Assistant>[];
    var page = 1;
    while (true) {
      final result = await list(page: page, pageSize: 50);
      out.addAll(result.items);
      if (!result.hasMore || result.items.isEmpty) return out;
      page++;
    }
  }

  Future<Assistant> get(String id) async {
    final res = await _client.request<Map<String, dynamic>>('/assistants/$id');
    return Assistant.fromJson(res.data!);
  }

  /// `POST /assistants` (any member). `is_default: true` clears the
  /// organization's previous default.
  Future<Assistant> create(AssistantDraft draft) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/assistants',
      method: 'POST',
      data: draft.toJson(),
    );
    return Assistant.fromJson(res.data!);
  }

  /// `PATCH /assistants/{id}` — creator or org admin, 403 `forbidden` otherwise.
  Future<Assistant> update(String id, AssistantDraft draft) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/assistants/$id',
      method: 'PATCH',
      data: draft.toJson(),
    );
    return Assistant.fromJson(res.data!);
  }

  /// `PATCH /assistants/{id} {is_default}` only.
  Future<Assistant> setDefault(String id, bool isDefault) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/assistants/$id',
      method: 'PATCH',
      data: {'is_default': isDefault},
    );
    return Assistant.fromJson(res.data!);
  }

  Future<void> delete(String id) async {
    await _client.request<Map<String, dynamic>>('/assistants/$id', method: 'DELETE');
  }
}

final assistantsRepositoryProvider = FutureProvider<AssistantsRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return AssistantsRepository(client);
});

/// The active organization's assistants, reloaded when the user or the
/// workspace changes; invalidate after any mutation.
final assistantListProvider = FutureProvider<List<Assistant>>((ref) async {
  ref.watch(currentUserProvider.select((u) => u.valueOrNull?.id));
  ref.watch(activeOrgIdProvider);
  final repo = await ref.watch(assistantsRepositoryProvider.future);
  return repo.listAll();
});

/// The assistant flagged `is_default` (preselected in the new-chat picker).
final defaultAssistantProvider = Provider<Assistant?>((ref) {
  final list = ref.watch(assistantListProvider).valueOrNull;
  return list?.firstWhereOrNull((a) => a.isDefault);
});
