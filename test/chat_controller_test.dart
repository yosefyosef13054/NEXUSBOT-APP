import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/api_client.dart';
import 'package:nexusbot/core/preferences.dart';
import 'package:nexusbot/features/chat/chat_controller.dart';
import 'package:nexusbot/features/chat/chat_models.dart';
import 'package:nexusbot/features/chat/chat_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fakes.dart';

/// Hand-written fake: the controller only ever touches these members.
class FakeChatRepository extends ChatRepository {
  FakeChatRepository() : super(ApiClient.create(MemoryTokenStorage()));

  List<ChatMessage> history = [];
  Object? openError;
  int listCalls = 0;
  int stopCalls = 0;
  int closeCalls = 0;
  StreamTransport? lastTransport;
  bool? lastUseRag;
  bool? lastUseTools;
  StreamController<StreamEvent>? turn;

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId, {int limit = 100}) async => history;

  @override
  Future<List<ChatSession>> listSessions({int page = 1, int pageSize = 50}) async {
    listCalls++;
    return const [];
  }

  @override
  Future<ChatTurn> streamMessage({
    required String sessionId,
    required String content,
    required StreamTransport transport,
    bool useRag = true,
    bool useTools = true,
    List<String>? toolNames,
    double? temperature,
  }) async {
    final error = openError;
    if (error != null) throw error;
    lastTransport = transport;
    lastUseRag = useRag;
    lastUseTools = useTools;
    final controller = StreamController<StreamEvent>();
    turn = controller;
    return ChatTurn(
      transport: transport,
      events: controller.stream,
      stop: () async => stopCalls++,
      close: () async {
        closeCalls++;
        if (!controller.isClosed) await controller.close();
      },
    );
  }
}

const session = 's1';

ChatMessage assistantFrom(Map<String, dynamic> data) =>
    AssistantMessageEvent(data: data).toMessage(session);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeChatRepository repo;
  late ProviderContainer container;

  Future<void> setUpContainer({
    StreamTransport transport = StreamTransport.sse,
    bool streaming = true,
    bool tools = true,
    bool rag = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      'pref.transport': transport.index,
      'pref.streaming': streaming,
      'pref.tools': tools,
      'pref.rag': rag,
    });
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWith((ref) async => repo),
        prefsProvider.overrideWith((ref) => PrefsController(prefs)),
        sessionListRefresherProvider.overrideWith((ref) {
          final r = SessionListRefresher(ref, delay: Duration.zero);
          ref.onDispose(r.dispose);
          return r;
        }),
      ],
    );
    addTearDown(container.dispose);
    // Keep the autoDispose providers alive for the duration of the test.
    container.listen(chatControllerProvider(session), (_, __) {});
    container.listen(sessionListProvider, (_, __) {});
    await pumpEventQueue();
  }

  ChatState state() => container.read(chatControllerProvider(session));
  ChatController controller() => container.read(chatControllerProvider(session).notifier);

  /// Sends a message and returns the fake turn's event sink.
  Future<StreamController<StreamEvent>> send(String text) async {
    await controller().send(text);
    await pumpEventQueue();
    return repo.turn!;
  }

  Future<void> emit(StreamController<StreamEvent> turn, StreamEvent event) async {
    turn.add(event);
    await pumpEventQueue();
  }

  setUp(() => repo = FakeChatRepository());

  test('loads history on creation', () async {
    repo.history = [
      assistantFrom({'id': 'a0', 'content': 'earlier', 'meta': {'status': 'interrupted'}}),
    ];
    await setUpContainer();
    expect(state().messages.map((m) => m.id), ['a0']);
    expect(state().messages.single.interrupted, isTrue);
  });

  test('seeds RAG/tools toggles from preferences and sends them', () async {
    await setUpContainer(tools: false, rag: true);
    expect(state().useTools, isFalse);
    expect(state().useRag, isTrue);
    await send('hi');
    expect(repo.lastUseTools, isFalse);
    expect(repo.lastUseRag, isTrue);
    expect(repo.lastTransport, StreamTransport.sse);
  });

  test('appends an optimistic user bubble and a streaming placeholder', () async {
    await setUpContainer();
    await send('hello');
    final msgs = state().messages;
    expect(msgs, hasLength(2));
    expect(msgs[0].role, MessageRole.user);
    expect(msgs[0].id, startsWith('pending-user-'));
    expect(msgs[1].role, MessageRole.assistant);
    expect(msgs[1].streaming, isTrue);
    expect(state().sending, isTrue);
    expect(state().error, isNull);
  });

  test('tokens accumulate into the placeholder', () async {
    await setUpContainer();
    final turn = await send('hello');
    await emit(turn, const TokenEvent(token: 'Hel'));
    await emit(turn, const TokenEvent(token: 'lo'));
    final last = state().messages.last;
    expect(last.content, 'Hello');
    expect(last.streaming, isTrue);
    expect(state().sending, isTrue);
  });

  test('citations and tool calls attach to the placeholder', () async {
    await setUpContainer();
    final turn = await send('hello');
    await emit(
      turn,
      const CitationsEvent(
        citations: [
          Citation(documentId: 'd1', documentName: 'spec.pdf', chunkIndex: 0, score: 0.9, excerpt: 'x'),
        ],
      ),
    );
    await emit(turn, const ToolCallEvent(data: {'phase': 'start', 'tool': 'calculator'}));
    expect(state().messages.last.toolCalls, isEmpty, reason: 'start frames carry no result');
    await emit(
      turn,
      const ToolCallEvent(data: {'phase': 'end', 'tool': 'calculator', 'input': '2+2', 'output': '4'}),
    );
    final last = state().messages.last;
    expect(last.citations.single.documentName, 'spec.pdf');
    expect(last.toolCalls.single.tool, 'calculator');
    expect(last.toolCalls.single.output, '4');
  });

  test('user_message replaces the optimistic user bubble', () async {
    await setUpContainer();
    final turn = await send('hello');
    await emit(
      turn,
      const UserMessageEvent(
        data: {'id': 'u1', 'content': 'hello', 'created_at': '2026-01-01T00:00:00Z'},
      ),
    );
    expect(state().messages.first.id, 'u1');
    expect(state().messages.first.role, MessageRole.user);
  });

  test('assistant_message replaces the placeholder, ends the turn and refreshes titles', () async {
    await setUpContainer();
    final turn = await send('hello');
    await emit(turn, const TokenEvent(token: 'Hel'));
    final listCallsBefore = repo.listCalls;
    await emit(
      turn,
      const DoneEvent(data: {'text': 'Hello!', 'latency_ms': 10}),
    );
    expect(state().messages.last.content, 'Hello!', reason: 'done carries the full text');
    await emit(
      turn,
      const AssistantMessageEvent(
        data: {'id': 'a1', 'content': 'Hello!', 'created_at': '2026-01-01T00:00:01Z'},
      ),
    );
    final last = state().messages.last;
    expect(last.id, 'a1');
    expect(last.content, 'Hello!');
    expect(last.streaming, isFalse);
    expect(last.interrupted, isFalse);
    expect(state().sending, isFalse);
    expect(state().stopping, isFalse);
    await pumpEventQueue();
    expect(repo.listCalls, listCallsBefore + 1, reason: 'session list re-fetched for the title');
  });

  test('error event ends the turn, surfaces the message and drops an empty placeholder', () async {
    await setUpContainer();
    final turn = await send('hello');
    await emit(turn, const ErrorEvent(message: 'model exploded', code: 'llm_error'));
    expect(state().sending, isFalse);
    expect(state().error, 'model exploded');
    expect(state().messages, hasLength(1), reason: 'empty placeholder removed');
    expect(state().messages.single.role, MessageRole.user);
  });

  test('error after partial output keeps the partial text', () async {
    await setUpContainer();
    final turn = await send('hello');
    await emit(turn, const TokenEvent(token: 'partial'));
    await emit(turn, const ErrorEvent(message: 'cut off'));
    expect(state().messages.last.content, 'partial');
    expect(state().messages.last.streaming, isFalse);
    expect(state().error, 'cut off');
  });

  test('busy error gets a friendly message', () async {
    await setUpContainer();
    final turn = await send('hello');
    await emit(turn, const ErrorEvent(message: 'generation in progress', code: 'busy'));
    expect(state().error, contains('still answering'));
    expect(state().sending, isFalse);
  });

  test('a failed connection surfaces the ApiException with its request id', () async {
    await setUpContainer();
    repo.openError = ApiException(
      code: 'rate_limited',
      message: 'Too many requests',
      statusCode: 429,
      requestId: 'c0ffee1234567890',
    );
    await controller().send('hello');
    await pumpEventQueue();
    expect(state().sending, isFalse);
    expect(state().error, 'Too many requests (ref c0ffee12)');
    expect(state().messages.single.role, MessageRole.user);
  });

  test('stop over SSE closes the connection and marks the bubble as stopped', () async {
    await setUpContainer(transport: StreamTransport.sse);
    final turn = await send('hello');
    await emit(turn, const TokenEvent(token: 'Hel'));

    await controller().stop();
    await pumpEventQueue();

    expect(repo.closeCalls, 1, reason: 'subscription cancelled → connection closed');
    expect(repo.stopCalls, 0, reason: 'no stop frame on SSE');
    final last = state().messages.last;
    expect(last.content, 'Hel', reason: 'partial text is kept');
    expect(last.streaming, isFalse);
    expect(last.interrupted, isTrue);
    expect(state().sending, isFalse);
    expect(state().stopping, isFalse);
  });

  test('stop over WebSocket sends stop and waits for the interrupted assistant_message', () async {
    await setUpContainer(transport: StreamTransport.websocket);
    final turn = await send('hello');
    await emit(turn, const TokenEvent(token: 'Hel'));

    await controller().stop();
    await pumpEventQueue();
    expect(repo.stopCalls, 1);
    expect(repo.closeCalls, 0, reason: 'stays connected for the final message');
    expect(state().stopping, isTrue);
    expect(state().sending, isTrue);
    expect(state().messages.last.streaming, isTrue);

    await controller().stop();
    expect(repo.stopCalls, 1, reason: 'stop is idempotent while waiting');

    await emit(turn, const DoneEvent(data: {'text': 'Hel', 'interrupted': true}));
    expect(state().messages.last.interrupted, isTrue);
    await emit(
      turn,
      const AssistantMessageEvent(data: {'id': 'a9', 'content': 'Hel', 'interrupted': true}),
    );
    final last = state().messages.last;
    expect(last.id, 'a9');
    expect(last.interrupted, isTrue);
    expect(last.streaming, isFalse);
    expect(state().sending, isFalse);
    expect(state().stopping, isFalse);
  });

  test('stream ending without a terminal event releases the composer', () async {
    await setUpContainer();
    final turn = await send('hello');
    await emit(turn, const TokenEvent(token: 'Hel'));
    await turn.close();
    await pumpEventQueue();
    expect(state().sending, isFalse);
    expect(state().messages.last.streaming, isFalse);
  });

  test('ignores a send while a turn is in flight', () async {
    await setUpContainer();
    await send('first');
    await controller().send('second');
    await pumpEventQueue();
    expect(state().messages.where((m) => m.role == MessageRole.user), hasLength(1));
  });

  test('disposing the controller closes the active turn', () async {
    await setUpContainer();
    await send('hello');
    container.dispose();
    await pumpEventQueue();
    expect(repo.closeCalls, 1);
  });
}
