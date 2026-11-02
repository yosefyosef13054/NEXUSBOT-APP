import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/secure_storage.dart';
import 'auth_models.dart';

class AuthRepository {
  AuthRepository(this._client);
  final ApiClient _client;
  TokenStorage get _tokens => _client.tokens;

  Future<User> register({
    required String email,
    required String password,
    String? fullName,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/auth/register',
      method: 'POST',
      data: {
        'email': email,
        'password': password,
        if (fullName != null && fullName.isNotEmpty) 'full_name': fullName,
      },
      authRetry: false,
    );
    return User.fromJson(res.data!);
  }

  Future<User> login({required String email, required String password}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/auth/login',
      method: 'POST',
      data: {'email': email, 'password': password},
      authRetry: false,
    );
    final pair = TokenPair.fromJson(res.data!);
    await _tokens.writeTokens(access: pair.accessToken, refresh: pair.refreshToken);
    return me();
  }

  Future<User> me() async {
    final res = await _client.request<Map<String, dynamic>>('/auth/me');
    return User.fromJson(res.data!);
  }

  /// `PATCH /auth/me` — currently only the display name is editable.
  Future<User> updateProfile({required String fullName}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/auth/me',
      method: 'PATCH',
      data: {'full_name': fullName},
    );
    return User.fromJson(res.data!);
  }

  /// `POST /auth/change-password`. Every other refresh token is revoked
  /// server-side; the returned pair keeps this device signed in.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    // A 401 here means "wrong current password", not "stale token" — make
    // sure the token is fresh up front and don't refresh-and-retry on 401.
    await _client.ensureFreshAccessToken();
    final res = await _client.request<Map<String, dynamic>>(
      '/auth/change-password',
      method: 'POST',
      data: {'current_password': currentPassword, 'new_password': newPassword},
      authRetry: false,
    );
    final pair = TokenPair.fromJson(res.data!);
    await _tokens.writeTokens(access: pair.accessToken, refresh: pair.refreshToken);
  }

  /// `DELETE /auth/me` — deactivates the account and revokes every token.
  /// Clears local tokens on success; the caller navigates to `/login`.
  Future<void> deleteAccount({required String password}) async {
    await _client.ensureFreshAccessToken();
    await _client.request<Map<String, dynamic>>(
      '/auth/me',
      method: 'DELETE',
      data: {'password': password},
      authRetry: false,
    );
    await _tokens.clear();
  }

  /// Sign out of this device: revokes the refresh token server-side (best
  /// effort — a dead network must never keep the user signed in), then
  /// clears local tokens.
  Future<void> logout() async {
    final refresh = await _tokens.readRefresh();
    if (refresh != null) {
      try {
        await _client.request<Map<String, dynamic>>(
          '/auth/logout',
          method: 'POST',
          data: {'refresh_token': refresh},
          authRetry: false,
        );
      } catch (_) {
        // Best effort.
      }
    }
    await _tokens.clear();
  }

  /// Sign out everywhere: revokes every refresh token of the user.
  Future<void> logoutAll() async {
    await _client.request<Map<String, dynamic>>('/auth/logout-all', method: 'POST');
    await _tokens.clear();
  }
}

final authRepositoryProvider = FutureProvider<AuthRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return AuthRepository(client);
});
