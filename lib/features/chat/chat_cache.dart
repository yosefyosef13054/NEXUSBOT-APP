import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local_store.dart';
import '../assistants/assistant_model.dart';
import '../auth/auth_models.dart';
import '../auth/auth_providers.dart';
import '../orgs/orgs_repository.dart';
import 'chat_models.dart';

/// The cached active branch of one chat.
class CachedHistory {
  const CachedHistory({required this.messages, this.nextCursor, this.savedAt});

  final List<ChatMessage> messages;

  /// `next_cursor` of the newest page, so "load earlier" can continue.
  final String? nextCursor;
  final DateTime? savedAt;
}

/// The offline copy of what the user sees first: the session list, the last
/// [maxMessages] messages of every opened chat (active branch), the
/// workspace's assistants and the signed-in profile.
///
/// Everything but the profile is keyed by [scope] — `<user>:<org>` — so a
/// second account or workspace on the same device never sees another's data.
/// Only persisted messages are cached (streaming placeholders and queued
/// sends live in their own places).
class ChatCache {
  ChatCache(this._store, {this.maxMessages = 100});

  final LocalStore _store;

  /// How many of the newest messages of a chat are kept.
  final int maxMessages;

  static String sessionsKey(String scope) => 'cache:$scope:sessions';
  static String messagesKey(String scope, String sessionId) => 'cache:$scope:messages:$sessionId';
  static String assistantsKey(String scope) => 'cache:$scope:assistants';

  /// The last signed-in user, device-wide (tokens are per device too).
  static const profileKey = 'cache:profile';

  // ---- Sessions ----

  Future<List<ChatSession>?> readSessions(String scope) async {
    final doc = await _store.read(sessionsKey(scope));
    final items = doc?['items'];
    if (items is! List) return null;
    return _parseList(items, ChatSession.fromJson);
  }

  Future<void> writeSessions(String scope, List<ChatSession> sessions) =>
      _store.write(sessionsKey(scope), {
        'items': [for (final s in sessions) s.toJson()],
        'saved_at': DateTime.now().toIso8601String(),
      });

  // ---- Messages ----

  Future<CachedHistory?> readMessages(String scope, String sessionId) async {
    final doc = await _store.read(messagesKey(scope, sessionId));
    final items = doc?['items'];
    if (items is! List) return null;
    return CachedHistory(
      messages: _parseList(items, ChatMessage.fromJson),
      nextCursor: doc?['next_cursor'] as String?,
      savedAt: DateTime.tryParse(doc?['saved_at'] as String? ?? ''),
    );
  }

  /// Keeps the newest [maxMessages] persisted rows of [messages].
  Future<void> writeMessages(
    String scope,
    String sessionId,
    List<ChatMessage> messages, {
    String? nextCursor,
  }) {
    final persisted = [
      for (final m in messages)
        if (!m.streaming && !m.isPendingUser && !m.isQueued) m,
    ];
    final kept = persisted.length > maxMessages
        ? persisted.sublist(persisted.length - maxMessages)
        : persisted;
    // A truncated cache cannot continue the server's cursor: older rows are
    // fetched from the first page again.
    final cursor = kept.length == persisted.length ? nextCursor : null;
    return _store.write(messagesKey(scope, sessionId), {
      'items': [for (final m in kept) m.toJson()],
      if (cursor != null) 'next_cursor': cursor,
      'saved_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> removeSession(String scope, String sessionId) =>
      _store.delete(messagesKey(scope, sessionId));

  // ---- Assistants ----

  Future<List<Assistant>?> readAssistants(String scope) async {
    final doc = await _store.read(assistantsKey(scope));
    final items = doc?['items'];
    if (items is! List) return null;
    return _parseList(items, Assistant.fromJson);
  }

  Future<void> writeAssistants(String scope, List<Assistant> assistants) =>
      _store.write(assistantsKey(scope), {
        'items': [for (final a in assistants) a.toJson()],
        'saved_at': DateTime.now().toIso8601String(),
      });

  // ---- Profile ----

  Future<User?> readProfile() async {
    final doc = await _store.read(profileKey);
    final user = doc?['user'];
    if (user is! Map) return null;
    try {
      return User.fromJson(user.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  Future<void> writeProfile(User user) => _store.write(profileKey, {'user': user.toJson()});

  Future<void> clearProfile() => _store.delete(profileKey);

  /// Every cached document (Settings → "Clear saved chats"); the send queue
  /// lives in the same store and is left alone.
  Future<void> clear() async {
    for (final key in await _store.keys(prefix: 'cache:')) {
      await _store.delete(key);
    }
  }

  static List<T> _parseList<T>(List raw, T Function(Map<String, dynamic>) parse) {
    final out = <T>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        out.add(parse(item.cast<String, dynamic>()));
      } catch (_) {
        // A row from an older build: skip it rather than lose the cache.
      }
    }
    return out;
  }
}

/// `<user>:<org>` — the cache partition of the signed-in user in the active
/// workspace. `anon:personal` before the user is known.
final cacheScopeProvider = Provider<String>((ref) {
  final userId = ref.watch(currentUserProvider.select((u) => u.valueOrNull?.id));
  final orgId = ref.watch(activeOrgIdProvider);
  return cacheScope(userId: userId, orgId: orgId);
});

String cacheScope({String? userId, String? orgId}) => '${userId ?? 'anon'}:${orgId ?? 'personal'}';

final chatCacheProvider = Provider<ChatCache>((ref) => ChatCache(ref.watch(localStoreProvider)));
