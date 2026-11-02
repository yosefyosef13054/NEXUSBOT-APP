import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import 'auth_models.dart';
import 'auth_repository.dart';

/// Lazily loaded "current user". Returns null when no valid token exists.
///
/// Also drops the cached user when the token refresher gives up (a revoked
/// or reused refresh token), so the router bounces to `/login`.
final currentUserProvider = FutureProvider<User?>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  final signedOut = client.refresher.onSignedOut.listen((_) => ref.invalidateSelf());
  ref.onDispose(signedOut.cancel);

  final access = await client.tokens.readAccess();
  if (access == null) return null;
  try {
    final repo = await ref.watch(authRepositoryProvider.future);
    return await repo.me();
  } on ApiException {
    return null;
  }
});

/// Convenience boolean for the router redirect.
final isAuthenticatedProvider = Provider<AsyncValue<bool>>((ref) {
  return ref.watch(currentUserProvider).whenData((u) => u != null);
});
