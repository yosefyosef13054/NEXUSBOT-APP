import 'package:nexusbot/core/secure_storage.dart';

/// In-memory [TokenStorage] for tests — no platform channels involved.
class MemoryTokenStorage implements TokenStorage {
  MemoryTokenStorage({this.access, this.refresh});

  String? access;
  String? refresh;
  int writes = 0;
  int clears = 0;

  @override
  Future<String?> readAccess() async => access;

  @override
  Future<String?> readRefresh() async => refresh;

  @override
  Future<void> writeTokens({required String access, required String refresh}) async {
    this.access = access;
    this.refresh = refresh;
    writes++;
  }

  @override
  Future<void> clear() async {
    access = null;
    refresh = null;
    clears++;
  }
}
