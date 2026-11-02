import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/api_client.dart';
import 'package:nexusbot/core/connectivity.dart';
import 'package:nexusbot/core/local_store.dart';
import 'package:nexusbot/features/chat/chat_models.dart';
import 'package:nexusbot/features/chat/chat_repository.dart';
import 'package:nexusbot/features/chat/send_queue.dart';

import 'helpers/fakes.dart';

/// `POST /messages/background` stand-in: answers from [script] in order, or
/// with [fallback] once the script is exhausted.
class ScriptedRepository extends ChatRepository {
  ScriptedRepository() : super(ApiClient.create(MemoryTokenStorage()));

  final script = <Object>[];
  Object fallback = const BackgroundSend(generationId: 'g-default');
  final calls = <({String sessionId, String content, String? key, List<String>? attachments})>[];

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
    calls.add(
      (sessionId: sessionId, content: content, key: idempotencyKey, attachments: attachmentIds),
    );
    final answer = script.isEmpty ? fallback : script.removeAt(0);
    if (answer is BackgroundSend) return answer;
    throw answer;
  }
}

QueuedSend queued(String key, {String content = 'hi', String session = 's1'}) => QueuedSend(
      key: key,
      sessionId: session,
      content: content,
      createdAt: DateTime.utc(2026),
      attachments: const [
        Attachment(
          id: 'att1',
          kind: AttachmentKind.file,
          name: 'n.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 1,
          url: '/x',
        ),
      ],
      toolNames: const ['calculator'],
      model: 'gpt-4o',
      voiceReply: const VoiceReply(voice: 'alloy'),
    );

ApiException transient() => ApiException(code: 'network_error', message: 'offline');
ApiException refusal() =>
    ApiException(code: 'validation_error', message: 'Type not allowed', statusCode: 422);

void main() {
  late ScriptedRepository repo;
  late ManualConnectivityService connectivity;
  late MemoryLocalStore store;
  late List<Duration> waits;

  SendQueue make({bool online = true, int maxAttempts = 8}) {
    connectivity = ManualConnectivityService(online: online);
    return SendQueue(
      repository: () async => repo,
      store: store,
      connectivity: connectivity,
      scope: 'u1:personal',
      maxAttempts: maxAttempts,
      backoff: (attempts) => Duration(seconds: attempts),
      wait: (d) async => waits.add(d),
    );
  }

  setUp(() {
    repo = ScriptedRepository();
    store = MemoryLocalStore();
    waits = [];
  });

  test('QueuedSend serialises everything and renders a queued bubble', () {
    final q = queued('k1');
    final copy = QueuedSend.fromJson(q.toJson());
    expect(copy.key, 'k1');
    expect(copy.sessionId, 's1');
    expect(copy.content, 'hi');
    expect(copy.attachments.single.id, 'att1');
    expect(copy.attachmentIds, ['att1']);
    expect(copy.toolNames, ['calculator']);
    expect(copy.model, 'gpt-4o');
    expect(copy.voiceReply?.voice, 'alloy');
    expect(copy.createdAt, q.createdAt);
    expect(copy.bubbleId, 'pending-user-k1');

    final bubble = q.toMessage();
    expect(bubble.id, 'pending-user-k1');
    expect(bubble.isPendingUser, isTrue);
    expect(bubble.isQueued, isTrue);
    expect(bubble.delivery, MessageDelivery.queued);
    expect(bubble.attachments.single.id, 'att1');
    expect(
      q.copyWith(failed: true, lastError: 'nope').toMessage().delivery,
      MessageDelivery.failed,
    );
  });

  test('waits while offline and replays in order with the same key once online', () async {
    final queue = make(online: false);
    final events = <SendQueueEvent>[];
    queue.events.listen(events.add);
    await queue.enqueue(queued('k1', content: 'first'));
    await queue.enqueue(queued('k2', content: 'second'));
    await pumpEventQueue();
    expect(repo.calls, isEmpty, reason: 'offline: nothing is attempted');
    expect(queue.state.pendingCount, 2);
    expect((await store.read('sendqueue:u1:personal'))!['items'], hasLength(2));

    repo.script.addAll([
      const BackgroundSend(generationId: 'g1'),
      const BackgroundSend(generationId: 'g2'),
    ]);
    connectivity.setOnline(true);
    await pumpEventQueue();

    expect(repo.calls.map((c) => c.key), ['k1', 'k2']);
    expect(repo.calls.first.attachments, ['att1']);
    expect(queue.state.isEmpty, isTrue);
    expect((await store.read('sendqueue:u1:personal'))!['items'], isEmpty);
    expect(events.whereType<SendAccepted>().map((e) => e.accepted.generationId), ['g1', 'g2']);
    queue.dispose();
  });

  test('transient failures back off and retry with the same key', () async {
    repo.script.addAll([transient(), transient(), const BackgroundSend(generationId: 'g1')]);
    final queue = make();
    final events = <SendQueueEvent>[];
    queue.events.listen(events.add);
    await queue.enqueue(queued('k1'));
    await pumpEventQueue();

    expect(repo.calls.map((c) => c.key), ['k1', 'k1', 'k1']);
    expect(waits, [const Duration(seconds: 1), const Duration(seconds: 2)]);
    expect(queue.state.isEmpty, isTrue);
    expect(events.single, isA<SendAccepted>());
    queue.dispose();
  });

  test('a refusal parks the send; retry and cancel are manual', () async {
    repo.script.add(refusal());
    final queue = make();
    final events = <SendQueueEvent>[];
    queue.events.listen(events.add);
    await queue.enqueue(queued('k1'));
    await pumpEventQueue();

    expect(queue.state.failedCount, 1);
    expect(queue.state.pendingCount, 0);
    expect(queue.state.byKey('k1')!.lastError, 'Type not allowed');
    expect(events.single, isA<SendFailed>());
    expect(repo.calls, hasLength(1));
    expect((await store.read('sendqueue:u1:personal'))!['items'].first['failed'], isTrue);

    // Still parked after a reconnect: nothing is retried behind the user's back.
    connectivity.setOnline(false);
    connectivity.setOnline(true);
    await pumpEventQueue();
    expect(repo.calls, hasLength(1));

    await queue.retry('k1');
    await pumpEventQueue();
    expect(repo.calls, hasLength(2));
    expect(queue.state.isEmpty, isTrue);
    expect(events.last, isA<SendAccepted>());

    // Refused again on retry, then cancelled by hand.
    repo.fallback = refusal();
    await queue.enqueue(queued('k2'));
    await pumpEventQueue();
    expect(queue.state.byKey('k2')!.failed, isTrue);
    await queue.retry('k2');
    await pumpEventQueue();
    expect(queue.state.byKey('k2')!.failed, isTrue);
    expect(repo.calls.where((c) => c.key == 'k2'), hasLength(2));
    await queue.cancel('k2');
    await pumpEventQueue();
    expect(queue.state.isEmpty, isTrue);
    expect(events.last, isA<SendCancelled>());
    expect((await store.read('sendqueue:u1:personal'))!['items'], isEmpty);
    queue.dispose();
  });

  test('gives up after maxAttempts transient failures', () async {
    repo.script.addAll([transient(), transient(), transient()]);
    final queue = make(maxAttempts: 3);
    await queue.enqueue(queued('k1'));
    await pumpEventQueue();
    expect(repo.calls, hasLength(3));
    expect(queue.state.failedCount, 1);
    expect(waits, hasLength(2));
    queue.dispose();
  });

  test('the persisted queue survives a restart', () async {
    final first = make(online: false);
    await first.enqueue(queued('k1'));
    await first.enqueue(queued('k2'));
    await pumpEventQueue();
    first.dispose();

    final second = make();
    await second.ready;
    await pumpEventQueue();
    expect(repo.calls.map((c) => c.key), ['k1', 'k2'], reason: 'drained on load');
    expect(second.state.isEmpty, isTrue);
    second.dispose();
  });

  test('busy and plain rate limits are transient, quota and auth are not', () {
    expect(ApiException(code: 'busy', message: 'b').isTransient, isTrue);
    expect(ApiException(code: 'rate_limited', message: 'r', statusCode: 429).isTransient, isTrue);
    expect(ApiException(code: 'timeout', message: 't').isTransient, isTrue);
    expect(ApiException(code: 'http_503', message: 'x', statusCode: 503).isTransient, isTrue);
    expect(
      ApiException(code: 'quota_exceeded', message: 'q', statusCode: 429).isTransient,
      isFalse,
    );
    expect(ApiException(code: 'unauthorized', message: 'u', statusCode: 401).isTransient, isFalse);
    expect(refusal().isTransient, isFalse);
    expect(SendQueue.defaultBackoff(1), const Duration(seconds: 1));
    expect(SendQueue.defaultBackoff(4), const Duration(seconds: 8));
    expect(SendQueue.defaultBackoff(20), const Duration(seconds: 60));
  });
}
