import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Token vault. Centralizes keys + provides a single tested API.
///
/// Abstract so tests can substitute an in-memory fake; the app uses
/// [SecureTokenStorage] (Keychain / Keystore).
abstract class TokenStorage {
  Future<String?> readAccess();
  Future<String?> readRefresh();
  Future<void> writeTokens({required String access, required String refresh});
  Future<void> clear();
}

/// [TokenStorage] backed by `flutter_secure_storage`.
class SecureTokenStorage implements TokenStorage {
  SecureTokenStorage(this._storage);
  final FlutterSecureStorage _storage;

  static const _kAccess = 'nexusbot.access_token';
  static const _kRefresh = 'nexusbot.refresh_token';

  @override
  Future<String?> readAccess() => _storage.read(key: _kAccess);

  @override
  Future<String?> readRefresh() => _storage.read(key: _kRefresh);

  @override
  Future<void> writeTokens({required String access, required String refresh}) async {
    await _storage.write(key: _kAccess, value: access);
    await _storage.write(key: _kRefresh, value: refresh);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
  }
}

final tokenStorageProvider = Provider<TokenStorage>((ref) {
  return SecureTokenStorage(
    const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    ),
  );
});
