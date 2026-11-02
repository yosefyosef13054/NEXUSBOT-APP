import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/preferences.dart';
import '../auth/auth_providers.dart';
import 'model_info.dart';

class ModelsRepository {
  ModelsRepository(this._client);
  final ApiClient _client;

  /// `GET /models` — only models whose provider is configured server-side.
  Future<ModelCatalog> list() async {
    final res = await _client.request<Map<String, dynamic>>('/models');
    return ModelCatalog.fromJson(res.data ?? const {});
  }
}

final modelsRepositoryProvider = FutureProvider<ModelsRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return ModelsRepository(client);
});

/// Loaded once per app session; `ref.invalidate(modelCatalogProvider)` on
/// pull-to-refresh. Models are server-wide, so a user switch needs no reload.
final modelCatalogProvider = FutureProvider<ModelCatalog>((ref) async {
  final repo = await ref.watch(modelsRepositoryProvider.future);
  return repo.list();
});

/// The model id used for new chats and as the header fallback — see
/// [resolveDefaultModel]. Null until the catalog is known or when it is empty.
final defaultModelIdProvider = Provider<String?>((ref) {
  final catalog = ref.watch(modelCatalogProvider).valueOrNull;
  final userDefault = ref.watch(currentUserProvider).valueOrNull?.defaultModel;
  final preferred = ref.watch(prefsProvider.select((p) => p.model));
  return resolveDefaultModel(
    catalog: catalog,
    userDefault: userDefault,
    preferred: preferred,
  );
});
