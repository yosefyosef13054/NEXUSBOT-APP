import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/api_client.dart';
import 'package:nexusbot/core/connectivity.dart';
import 'package:nexusbot/core/local_store.dart';
import 'package:nexusbot/core/secure_storage.dart';
import 'package:nexusbot/core/sync.dart';
import 'package:nexusbot/features/chat/chat_models.dart';
import 'package:nexusbot/features/chat/chat_repository.dart';
import 'package:nexusbot/features/chat/send_queue.dart';
import 'package:nexusbot/features/usage/usage_repository.dart';

import 'helpers/fakes.dart';

class CountingRepository extends ChatRepository {
  CountingRepository() : super(ApiClient.create(MemoryTokenStorage()));

  int listCalls = 0;
  int backgroundCalls = 0;
  Object? listError;

  @override
  Future<List<ChatSession>> listSessions({int page = 1, int pageSize = 50}) async {
    listCalls++;
    final e = listError;
    if (e != null) throw e;
    return [
      ChatSession(
        id: 's$listCalls',
        title: 'Chat $listCalls',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    ];
  }

  @override
  Future<BackgroundSend> sendBackground({
    required String sessionId,
    required String content,
    bool useRag = true,
    bool useTools = true,
    List<String>? toolNames,
    String? model,
    List<String>? collectionIds,
    String? idempotencyKey,
    List<String>? attachmentIds,
    VoiceReply? voiceReply,
  }) async {
    backgroundCalls++;
    return const BackgroundSend(generationId: 'g1');
  }
}

void main() {
  late CountingRepository repo;
  late ManualConnectivityService connectivity;
  late MemoryLocalStore store;
  late ProviderContainer container;

  setUp(() {
    repo = CountingRepository();
    connectivity = ManualConnectivityService();
    store = MemoryLocalStore();
    container = ProviderContainer(
      overrides: [
        tokenStorageProvider.overrideWithValue(MemoryTokenStorage()),
        localStoreProvider.overrideWithValue(store),
        connectivityServiceProvider.overrideWithValue(connectivity),
        chatRepositoryProvider.overrideWith((ref) async => repo),
        usageRepositoryProvider.overrideWith(
          (ref) async => throw UnimplementedError('never read here'),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  test('connectivity provider follows the service', () async {
    container.listen(isOnlineProvider, (_, __) {});
    await pumpEventQueue();
    expect(container.read(onlineProvider), isTrue);
    connectivity.setOnline(false);
    await pumpEventQueue();
    expect(container.read(onlineProvider), isFalse);
    connectivity.setOnline(true);
    await pumpEventQueue();
    expect(container.read(onlineProvider), isTrue);
  });

  test('a reconnect refreshes the session list, bumps the tick and drains the queue', () async {
    final coordinator = container.read(syncCoordinatorProvider);
    container.listen(isOnlineProvider, (_, __) {});
    container.listen(sessionListProvider, (_, __) {});
    await pumpEventQueue();
    expect(repo.listCalls, 1);
    expect(container.read(reconnectTickProvider), 0);

    // Park a send while offline.
    connectivity.setOnline(false);
    await pumpEventQueue();
    final queue = container.read(sendQueueProvider.notifier);
    await queue.enqueue(
      QueuedSend(key: 'k1', sessionId: 's1', content: 'hi', createdAt: DateTime.utc(2026)),
    );
    await pumpEventQueue();
    expect(repo.backgroundCalls, 0);

    connectivity.setOnline(true);
    await pumpEventQueue();
    expect(coordinator.reconnects, 1);
    expect(container.read(reconnectTickProvider), 1);
    expect(repo.listCalls, 2, reason: 'session list invalidated');
    expect(repo.backgroundCalls, 1, reason: 'queued send replayed');
    expect(container.read(sendQueueProvider).isEmpty, isTrue);
  });

  test('the session list is served from the cache first and survives an outage', () async {
    final seen = <List<ChatSession>?>[];
    container.listen<AsyncValue<List<ChatSession>>>(
      sessionListProvider,
      (_, next) => seen.add(next.valueOrNull),
      fireImmediately: true,
    );
    await pumpEventQueue();
    expect(seen.last?.single.title, 'Chat 1');
    expect(await store.keys(prefix: 'cache:'), ['cache:anon:personal:sessions']);

    // Offline: the stored list is emitted, the network error swallowed.
    repo.listError = ApiException(code: 'network_error', message: 'offline');
    container.invalidate(sessionListProvider);
    await pumpEventQueue();
    final value = container.read(sessionListProvider);
    expect(value.hasError, isFalse);
    expect(value.valueOrNull?.single.title, 'Chat 1');
    expect(repo.listCalls, 2);
  });
}
