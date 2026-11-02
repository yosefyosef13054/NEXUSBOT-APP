import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/preferences.dart';
import '../chat/chat_cache.dart';
import 'auth_models.dart';
import 'auth_repository.dart';

/// Lazily loaded "current user". Returns null when no valid token exists.
///
/// Also drops the cached user when the token refresher gives up (a revoked
/// or reused refresh token), so the router bounces to `/login`.
///
/// Once the user is known, the API client starts sending `X-Org-Id` for the
/// organization *this* user chose (see `AppPrefs.activeOrgIdFor`); signed
/// out, the header is dropped again.
///
/// Offline-first: a successful `GET /auth/me` is cached on the device; when
/// the server cannot be reached (or the token could not be refreshed for a
/// transport reason) and a token is still stored, the cached profile keeps
/// the app usable with its cached chats. A definitive rejection (revoked
/// tokens while online) still signs the user out.
final currentUserProvider = FutureProvider<User?>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  final cache = ref.watch(chatCacheProvider);
  final signedOut = client.refresher.onSignedOut.listen((_) => ref.invalidateSelf());
  ref.onDispose(signedOut.cancel);

  client.activeOrgId = null;
  final access = await client.tokens.readAccess();
  if (access == null) return null;
  try {
    final repo = await ref.watch(authRepositoryProvider.future);
    final user = await repo.me();
    client.activeOrgId = () => ref.read(prefsProvider).activeOrgIdFor(user.id);
    unawaited(cache.writeProfile(user));
    return user;
  } on ApiException catch (e) {
    if (e.isAuth && !client.refresher.lastRefreshFailedTransiently) return null;
    final cached = await cache.readProfile();
    if (cached == null) return null;
    client.activeOrgId = () => ref.read(prefsProvider).activeOrgIdFor(cached.id);
    return cached;
  }
});

/// Convenience boolean for the router redirect.
final isAuthenticatedProvider = Provider<AsyncValue<bool>>((ref) {
  return ref.watch(currentUserProvider).whenData((u) => u != null);
});
