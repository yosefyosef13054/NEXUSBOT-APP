import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/preferences.dart';
import '../auth/auth_models.dart';
import '../auth/auth_providers.dart';
import 'org_model.dart';

class OrgsRepository {
  OrgsRepository(this._client);
  final ApiClient _client;

  /// `GET /orgs` — every organization the user belongs to (incl. the
  /// personal one), with the user's role in each.
  Future<List<Org>> list() async {
    final res = await _client.request<Map<String, dynamic>>('/orgs');
    return (res.data?['items'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => Org.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// `POST /orgs {name}` — the creator becomes its owner.
  Future<Org> create(String name) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/orgs',
      method: 'POST',
      data: {'name': name},
    );
    return Org.fromJson(res.data!);
  }

  Future<Org> get(String id) async {
    final res = await _client.request<Map<String, dynamic>>('/orgs/$id');
    return Org.fromJson(res.data!);
  }

  /// `PATCH /orgs/{id} {name?, settings?}` (owner / admin; 403 `forbidden`
  /// otherwise). [settings] is sent whole, see [OrgSettings.toJson].
  Future<Org> update(String id, {String? name, OrgSettings? settings}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/orgs/$id',
      method: 'PATCH',
      data: {
        if (name != null) 'name': name,
        if (settings != null) 'settings': settings.toJson(),
      },
    );
    return Org.fromJson(res.data!);
  }

  // ---- Members ----

  Future<List<OrgMember>> listMembers(String orgId) async {
    final res = await _client.request<Map<String, dynamic>>('/orgs/$orgId/members');
    return (res.data?['items'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => OrgMember.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// `POST /orgs/{id}/members {email, role}` — 404 `not_found` when no user
  /// has that email, 409 `conflict` when they are already a member.
  Future<OrgMember> addMember(
    String orgId, {
    required String email,
    OrgRole role = OrgRole.member,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/orgs/$orgId/members',
      method: 'POST',
      data: {'email': email, 'role': role.name},
    );
    return OrgMember.fromJson(res.data!);
  }

  Future<OrgMember> updateMemberRole(String orgId, String userId, OrgRole role) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/orgs/$orgId/members/$userId',
      method: 'PATCH',
      data: {'role': role.name},
    );
    return OrgMember.fromJson(res.data!);
  }

  /// A member may remove themselves; the owner cannot be removed.
  Future<void> removeMember(String orgId, String userId) async {
    await _client.request<Map<String, dynamic>>(
      '/orgs/$orgId/members/$userId',
      method: 'DELETE',
    );
  }
}

final orgsRepositoryProvider = FutureProvider<OrgsRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return OrgsRepository(client);
});

/// The organization id requests carry as `X-Org-Id`, as chosen by the
/// signed-in user; null = their personal workspace. Org-scoped providers
/// (sessions, documents, collections, assistants, usage, …) watch this so a
/// switch reloads them.
final activeOrgIdProvider = Provider<String?>((ref) {
  final userId = ref.watch(currentUserProvider.select((u) => u.valueOrNull?.id));
  if (userId == null) return null;
  return ref.watch(prefsProvider.select((p) => p.activeOrgIdFor(userId)));
});

/// `GET /orgs` for the signed-in user.
///
/// A stale choice — the user was removed from the org, or it was deleted —
/// makes every request fail with 403 `forbidden`; the choice is then reset to
/// the personal workspace and the list fetched again.
final orgListProvider = FutureProvider<List<Org>>((ref) async {
  final user = await ref.watch(currentUserProvider.future);
  if (user == null) return const [];
  final repo = await ref.watch(orgsRepositoryProvider.future);
  final activeId = ref.watch(activeOrgIdProvider);
  final List<Org> orgs;
  try {
    orgs = await repo.list();
  } on ApiException catch (e) {
    if (activeId == null || !e.isForbidden) rethrow;
    await ref.read(prefsProvider.notifier).setActiveOrg(userId: user.id, orgId: null);
    return repo.list();
  }
  if (activeId != null && orgs.none((o) => o.id == activeId)) {
    await ref.read(prefsProvider.notifier).setActiveOrg(userId: user.id, orgId: null);
  }
  return orgs;
});

/// The organization the app acts in: the stored choice while the user is a
/// member of it, else the personal workspace. Null until the list is known.
final activeOrgProvider = Provider<AsyncValue<Org?>>((ref) {
  final activeId = ref.watch(activeOrgIdProvider);
  return ref.watch(orgListProvider).whenData((orgs) {
    final chosen = activeId == null ? null : orgs.firstWhereOrNull((o) => o.id == activeId);
    return chosen ?? orgs.firstWhereOrNull((o) => o.isPersonal) ?? orgs.firstOrNull;
  });
});

/// `GET /orgs/{id}` — fresh settings for the organization screen.
final orgDetailProvider = FutureProvider.autoDispose.family<Org, String>((ref, id) async {
  final repo = await ref.watch(orgsRepositoryProvider.future);
  return repo.get(id);
});

final orgMembersProvider =
    FutureProvider.autoDispose.family<List<OrgMember>, String>((ref, id) async {
  final repo = await ref.watch(orgsRepositoryProvider.future);
  return repo.listMembers(id);
});

/// Makes [org] the active workspace for [user]. The personal workspace is
/// stored as "no choice" so no `X-Org-Id` header is sent for it.
Future<void> selectActiveOrg(PrefsController prefs, {required User user, required Org org}) =>
    prefs.setActiveOrg(userId: user.id, orgId: org.isPersonal ? null : org.id);
