import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/api_client.dart';
import 'package:nexusbot/core/preferences.dart';
import 'package:nexusbot/features/chat/chat_controller.dart';
import 'package:nexusbot/features/chat/chat_models.dart';
import 'package:nexusbot/features/chat/chat_repository.dart';
import 'package:nexusbot/features/tools/tools_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fakes.dart';

/// Hand-written fake: the controller only ever touches these members.
class FakeChatRepository extends ChatRepository {
  FakeChatRepository() : super(ApiClient.create(MemoryTokenStorage()));

  List<ChatMessage> history = [];
  ChatSession? session;
  List<ApprovalRequest> pendingApprovals = [];
  Object? openError;
  Object? resolveError;
  int listCalls = 0;
  int historyCalls = 0;
  int stopCalls = 0;
  int closeCalls = 0;
  StreamTransport? lastTransport;
  bool? lastUseRag;
  bool? lastUseTools;
  List<String>? lastToolNames;
  String? lastModel;
  List<String>? lastCollectionIds;

  /// Every `updateSession` call: `{title, model, meta}` as received.
  final updates = <Map<String, Object?>>[];

  /// Every `resolveApproval` call.
  final resolved = <(String approvalId, ApprovalDecision decision, StreamTransport transport)>[];
  StreamController<StreamEvent>? turn;

  /// Answer for the non-streaming path and for `regenerate`.
  SendResult? blockingResult;

  @override
  Future<SendResult> sendBlocking({
    required String sessionId,
    required String content,
    bool useRag = true,
    bool useTools = true,
    List<String>? toolNames,
    String? model,
    List<String>? collectionIds,
  }) async {
    lastUseRag = useRag;
    lastUseTools = useTools;
    lastToolNames = toolNames;
    lastModel = model;
    lastCollectionIds = collectionIds;
    return blockingResult!;
  }

  @override
  Future<SendResult> regenerate(String sessionId, {double? temperature}) async => blockingResult!;

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId, {int limit = 100}) async {
    historyCalls++;
    return history;
  }

  @override
  Future<ChatSession> getSession(String id) async =>
      session ??
      ChatSession(
        id: id,
        title: 'New chat',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  @override
  Future<List<ApprovalRequest>> listPendingApprovals(String sessionId) async => pendingApprovals;

  @override
  Future<List<ChatSession>> listSessions({int page = 1, int pageSize = 50}) async {
    listCalls++;
    return const [];
  }

  @override
  Future<ChatSession> updateSession(
    String id, {
    String? title,
    String? model,
    Map<String, dynamic>? meta,
  }) async {
    updates.add({'title': title, 'model': model, 'meta': meta});
    final current = await getSession(id);
    return session = current.copyWith(title: title, model: model, meta: meta);
  }

  ChatTurn _openTurn(StreamTransport transport) {
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

  @override
  Future<ChatTurn> streamMessage({
    required String sessionId,
    required String content,
    required StreamTransport transport,
    bool useRag = true,
    bool useTools = true,
    List<String>? toolNames,
    double? temperature,
    String? model,
    List<String>? collectionIds,
  }) async {
    final error = openError;
    if (error != null) throw error;
    lastTransport = transport;
    lastUseRag = useRag;
    lastUseTools = useTools;
    lastToolNames = toolNames;
    lastModel = model;
    lastCollectionIds = collectionIds;
    return _openTurn(transport);
  }

  @override
  Future<ChatTurn> resolveApproval({
    required String sessionId,
    required String approvalId,
    required ApprovalDecision decision,
    StreamTransport transport = StreamTransport.sse,
  }) async {
    final error = resolveError;
    if (error != null) throw error;
    resolved.add((approvalId, decision, transport));
    return _openTurn(transport);
  }
}

const session = 's1';

ChatMessage assistantFrom(Map<String, dynamic> data) =>
    AssistantMessageEvent(data: data).toMessage(session);

const approvalJson = {
  'approval_id': 'ap1',
  'session_id': session,
  'message_id': 'a1',
  'expires_at': '2099-01-01T00:00:00+00:00',
  'tool_calls': [
    {
      'call_id': 'call_1',
      'tool': 'web_search',
      'input': {'query': 'flutter'},
      'description': 'Searches the web',
    },
  ],
};

const tools = [
  ToolInfo(name: 'calculator', description: 'Math'),
  ToolInfo(name: 'web_search', description: 'Web', requiresApproval: true),
  ToolInfo(name: 'db_lookup', description: 'DB'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeChatRepository repo;
  late ProviderContainer container;

  Future<void> setUpContainer({
    StreamTransport transport = StreamTransport.sse,
    bool streaming = true,
    bool tools = true,
    bool rag = true,
    List<ToolInfo> toolCatalog = const [],
    List<String>? sessionToolNames,
  }) async {
    SharedPreferences.setMockInitialValues({
      'pref.transport': transport.index,
      'pref.streaming': streaming,
      'pref.tools': tools,
      'pref.rag': rag,
      if (sessionToolNames != null) 'pref.session.$session.toolNames': sessionToolNames,
    });
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWith((ref) async => repo),
        prefsProvider.overrideWith((ref) => PrefsController(prefs)),
        sessionPrefsProvider.overrideWith((ref) => SessionPrefs(prefs)),
        toolCatalogProvider.overrideWith((ref) async => toolCatalog),
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
    container.listen(toolCatalogProvider, (_, __) {});
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

  /// Runs a turn up to the point where it pauses for approval `ap1` on the
  /// persisted placeholder `a1`.
  Future<void> pauseForApproval() async {
    final turn = await send('search for me');
    await emit(turn, const TokenEvent(token: 'Let me check.'));
    await emit(turn, const ApprovalRequiredEvent(data: approvalJson));
    await emit(
      turn,
      const DoneEvent(data: {'text': 'Let me check.', 'status': 'awaiting_approval'}),
    );
    await emit(
      turn,
      const AssistantMessageEvent(
        data: {
          'id': 'a1',
          'content': 'Let me check.',
          'status': 'awaiting_approval',
          'approval': approvalJson,
          'model': 'gpt-4o-mini',
        },
      ),
    );
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
    expect(repo.lastToolNames, isNull, reason: 'no tool list while tools are off');
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

  test('tool_call frames with the same call_id update one chip', () async {
    await setUpContainer();
    final turn = await send('hello');
    await emit(
      turn,
      const ToolCallEvent(
        data: {'phase': 'error', 'tool': 'web_search', 'call_id': 'c1', 'error': 'timeout'},
      ),
    );
    expect(state().messages.last.toolCalls.single.status, ToolCallStatus.error);
    await emit(
      turn,
      const ToolCallEvent(
        data: {'phase': 'end', 'tool': 'web_search', 'call_id': 'c1', 'output': 'ok', 'latency_ms': 7},
      ),
    );
    await emit(
      turn,
      const ToolCallEvent(data: {'phase': 'end', 'tool': 'calculator', 'call_id': 'c2', 'output': '4'}),
    );
    final calls = state().messages.last.toolCalls;
    expect(calls.map((c) => c.callId), ['c1', 'c2']);
    expect(calls.first.status, ToolCallStatus.ok);
    expect(calls.first.latencyMs, 7);
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
      const DoneEvent(data: {'text': 'Hello!', 'latency_ms': 10, 'model': 'gpt-4o-mini'}),
    );
    expect(state().messages.last.content, 'Hello!', reason: 'done carries the full text');
    expect(state().messages.last.model, 'gpt-4o-mini', reason: 'done carries the model used');
    await emit(
      turn,
      const AssistantMessageEvent(
        data: {'id': 'a1', 'content': 'Hello!', 'created_at': '2026-01-01T00:00:01Z', 'model': 'gpt-4o'},
      ),
    );
    final last = state().messages.last;
    expect(last.id, 'a1');
    expect(last.content, 'Hello!');
    expect(last.model, 'gpt-4o');
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

  // ── Phase 2: tools, model and knowledge overrides ───────────────────────

  group('per-turn overrides', () {
    test('default tool selection is every tool that needs no approval', () async {
      await setUpContainer(toolCatalog: tools);
      expect(state().toolNames, isNull, reason: 'nothing persisted yet');
      await send('hi');
      expect(repo.lastToolNames, ['calculator', 'db_lookup']);
    });

    test('a persisted per-session selection is sent, filtered to known tools', () async {
      await setUpContainer(toolCatalog: tools, sessionToolNames: ['web_search', 'retired_tool']);
      expect(state().toolNames, ['web_search', 'retired_tool']);
      await send('hi');
      expect(repo.lastToolNames, ['web_search']);
    });

    test('setToolNames persists the picker selection per session', () async {
      await setUpContainer(toolCatalog: tools);
      await controller().setToolNames(['web_search']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('pref.session.$session.toolNames'), ['web_search']);
      await send('hi');
      expect(repo.lastToolNames, ['web_search']);

      await controller().setToolNames(null);
      expect(prefs.getStringList('pref.session.$session.toolNames'), isNull);
      expect(state().toolNames, isNull);
    });

    test('sends the model override and the session knowledge scope', () async {
      repo.session = ChatSession(
        id: session,
        title: 'Specs',
        model: 'gpt-4o',
        meta: const {'collection_ids': ['c1', 'c2']},
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      await setUpContainer();
      expect(state().session?.model, 'gpt-4o');
      expect(state().collectionIds, ['c1', 'c2'], reason: 'seeded from session.meta');

      await send('first');
      expect(repo.lastModel, isNull, reason: 'no override → server resolves the model');
      expect(repo.lastCollectionIds, ['c1', 'c2']);
      await emit(repo.turn!, const AssistantMessageEvent(data: {'id': 'a1', 'content': 'ok'}));

      controller().setModelOverride('claude-sonnet');
      await send('second');
      expect(repo.lastModel, 'claude-sonnet');

      await emit(repo.turn!, const AssistantMessageEvent(data: {'id': 'a2', 'content': 'ok'}));
      controller().setModelOverride(null);
      await send('third');
      expect(repo.lastModel, isNull);
    });

    test('setCollectionIds saves the session default through PATCH meta', () async {
      repo.session = ChatSession(
        id: session,
        title: 'Specs',
        meta: const {'other': 1},
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      await setUpContainer();
      await controller().setCollectionIds(['c9']);
      expect(repo.updates.single['meta'], {'other': 1, 'collection_ids': ['c9']});
      expect(state().collectionIds, ['c9']);
      expect(state().session?.collectionIds, ['c9']);

      await controller().setCollectionIds(null);
      expect(repo.updates.last['meta'], {'other': 1, 'collection_ids': null});
      expect(state().collectionIds, isNull);
      await send('hi');
      expect(repo.lastCollectionIds, isNull);
    });

    test('setSessionModel patches the session and refreshes the list', () async {
      await setUpContainer();
      final listCallsBefore = repo.listCalls;
      await controller().setSessionModel('gpt-4o');
      await pumpEventQueue();
      expect(repo.updates.single['model'], 'gpt-4o');
      expect(state().session?.model, 'gpt-4o');
      expect(repo.listCalls, listCallsBefore + 1);
    });
  });

  // ── Phase 2: approvals ────────────────────────────────────────────────

  group('approvals', () {
    test('approval_required attaches the card; the turn ends awaiting approval', () async {
      await setUpContainer();
      await pauseForApproval();
      final last = state().messages.last;
      expect(last.id, 'a1');
      expect(last.awaitingApproval, isTrue);
      expect(last.approval?.approvalId, 'ap1');
      expect(last.approval?.isPending, isTrue);
      expect(last.approval?.toolCalls.single.tool, 'web_search');
      expect(last.content, 'Let me check.');
      expect(last.streaming, isFalse);
      expect(state().sending, isFalse, reason: 'the stream ended normally');
    });

    test('approve streams the continuation into the same bubble', () async {
      await setUpContainer(transport: StreamTransport.websocket);
      await pauseForApproval();
      final countBefore = state().messages.length;

      await controller().resolveApproval('ap1', ApprovalDecision.approve);
      await pumpEventQueue();
      expect(repo.resolved, [('ap1', ApprovalDecision.approve, StreamTransport.websocket)]);
      expect(state().sending, isTrue);
      final paused = state().messages.last;
      expect(paused.id, 'a1');
      expect(paused.approval, isNull, reason: 'card collapses while the tool runs');
      expect(paused.streaming, isTrue);
      expect(paused.content, 'Let me check.', reason: 'text so far is kept');

      final turn = repo.turn!;
      await emit(
        turn,
        const ToolCallEvent(
          data: {'phase': 'end', 'tool': 'web_search', 'call_id': 'call_1', 'output': 'results'},
        ),
      );
      await emit(turn, const TokenEvent(token: ' Found it.'));
      expect(state().messages.last.content, 'Let me check. Found it.');
      await emit(turn, const DoneEvent(data: {'text': 'Let me check. Found it.', 'status': 'ok'}));
      await emit(
        turn,
        const AssistantMessageEvent(
          data: {
            'id': 'a1',
            'content': 'Let me check. Found it.',
            'status': 'ok',
            'tool_calls': [
              {'tool': 'web_search', 'call_id': 'call_1', 'output': 'results', 'status': 'ok'},
            ],
          },
        ),
      );
      expect(state().messages, hasLength(countBefore), reason: 'no extra bubble');
      final last = state().messages.last;
      expect(last.id, 'a1');
      expect(last.content, 'Let me check. Found it.');
      expect(last.approval, isNull);
      expect(last.awaitingApproval, isFalse);
      expect(last.toolCalls.single.callId, 'call_1');
      expect(last.streaming, isFalse);
      expect(state().sending, isFalse);
    });

    test('deny sends the decision and finishes without the tool', () async {
      await setUpContainer();
      await pauseForApproval();
      await controller().resolveApproval('ap1', ApprovalDecision.deny);
      await pumpEventQueue();
      expect(repo.resolved.single.$2, ApprovalDecision.deny);
      expect(repo.resolved.single.$3, StreamTransport.sse);

      final turn = repo.turn!;
      await emit(turn, const TokenEvent(token: ' I was not allowed to search.'));
      await emit(
        turn,
        const AssistantMessageEvent(
          data: {'id': 'a1', 'content': 'Let me check. I was not allowed to search.', 'status': 'ok'},
        ),
      );
      final last = state().messages.last;
      expect(last.id, 'a1');
      expect(last.content, 'Let me check. I was not allowed to search.');
      expect(last.approval, isNull);
      expect(last.toolCalls, isEmpty);
      expect(state().sending, isFalse);
    });

    test('a failed resolve gives the card back', () async {
      await setUpContainer();
      await pauseForApproval();
      repo.resolveError = ApiException(code: 'network_error', message: 'offline');
      await controller().resolveApproval('ap1', ApprovalDecision.approve);
      await pumpEventQueue();
      expect(state().sending, isFalse);
      expect(state().error, 'offline');
      final last = state().messages.last;
      expect(last.approval?.approvalId, 'ap1');
      expect(last.awaitingApproval, isTrue);
      expect(last.streaming, isFalse);
    });

    test('409 / 404 on resolve refreshes the history', () async {
      await setUpContainer();
      await pauseForApproval();
      repo.resolveError = ApiException(code: 'conflict', message: 'already resolved', statusCode: 409);
      repo.history = [
        assistantFrom({'id': 'a1', 'content': 'Resolved elsewhere', 'meta': {'status': 'ok'}}),
      ];
      final historyCallsBefore = repo.historyCalls;
      await controller().resolveApproval('ap1', ApprovalDecision.approve);
      await pumpEventQueue();
      expect(repo.historyCalls, historyCallsBefore + 1);
      expect(state().error, contains('refreshed'));
      expect(state().sending, isFalse);
      expect(state().messages.single.content, 'Resolved elsewhere');
      expect(state().messages.single.approval, isNull);
    });

    test('a stale-approval error frame over WebSocket also refreshes', () async {
      await setUpContainer(transport: StreamTransport.websocket);
      await pauseForApproval();
      repo.history = [
        assistantFrom({'id': 'a1', 'content': 'Expired', 'meta': {'status': 'ok'}}),
      ];
      await controller().resolveApproval('ap1', ApprovalDecision.approve);
      await pumpEventQueue();
      await emit(repo.turn!, const ErrorEvent(message: 'expired', code: 'conflict'));
      await pumpEventQueue();
      expect(state().sending, isFalse);
      expect(state().messages.single.content, 'Expired');
    });

    test('pending approvals are reconciled against history on load', () async {
      repo.history = [
        // Flagged in history but without its approval payload.
        ChatMessage.fromJson({
          'id': 'a1',
          'session_id': session,
          'role': 'assistant',
          'content': '',
          'created_at': '2026-01-01T00:00:00Z',
          'meta': {'status': 'awaiting_approval'},
        }),
        // Carries an approval the server no longer lists as pending.
        ChatMessage.fromJson({
          'id': 'a2',
          'session_id': session,
          'role': 'assistant',
          'content': '',
          'created_at': '2026-01-01T00:00:01Z',
          'meta': {
            'status': 'awaiting_approval',
            'approval': {
              'approval_id': 'ap-old',
              'session_id': session,
              'message_id': 'a2',
              'expires_at': '2000-01-01T00:00:00+00:00',
              'tool_calls': [],
            },
          },
        }),
      ];
      repo.pendingApprovals = [ApprovalRequest.fromJson(approvalJson)];
      await setUpContainer();
      final msgs = state().messages;
      expect(msgs[0].approval?.approvalId, 'ap1', reason: 'attached from the pending list');
      expect(msgs[0].approval?.isPending, isTrue);
      expect(msgs[1].approval?.isPending, isFalse);
      expect(msgs[1].approval?.status, 'expired');
    });

    test('a blocking send inserts the server tool rows before the reply', () async {
      repo.blockingResult = SendResult.fromJson({
        'user_message': {
          'id': 'u1',
          'session_id': session,
          'role': 'user',
          'content': '2+2?',
          'created_at': '2026-01-01T00:00:00Z',
        },
        'tool_messages': [
          {
            'id': 't1',
            'session_id': session,
            'role': 'tool',
            'content': '4',
            'created_at': '2026-01-01T00:00:01Z',
            'meta': {'tool': 'calculator', 'call_id': 'call_1', 'status': 'ok'},
          },
        ],
        'assistant_message': {
          'id': 'a1',
          'session_id': session,
          'role': 'assistant',
          'content': 'It is 4.',
          'created_at': '2026-01-01T00:00:02Z',
          'meta': {'model': 'gpt-4o-mini'},
        },
      });
      await setUpContainer(streaming: false, toolCatalog: tools);
      controller().setModelOverride('gpt-4o');
      await controller().send('2+2?');
      await pumpEventQueue();
      expect(repo.lastModel, 'gpt-4o');
      expect(repo.lastToolNames, ['calculator', 'db_lookup']);
      expect(state().messages.map((m) => m.id), ['u1', 't1', 'a1']);
      expect(state().messages[1].isToolRun, isTrue);
      expect(state().messages.last.model, 'gpt-4o-mini');
      expect(state().sending, isFalse);
    });

    test('regenerate swaps the previous reply and its tool rows', () async {
      repo.history = [
        ChatMessage.fromJson({
          'id': 'u1',
          'session_id': session,
          'role': 'user',
          'content': 'q',
          'created_at': '2026-01-01T00:00:00Z',
        }),
        ChatMessage.fromJson({
          'id': 't1',
          'session_id': session,
          'role': 'tool',
          'content': 'old',
          'created_at': '2026-01-01T00:00:01Z',
          'meta': {'tool': 'calculator', 'call_id': 'c1', 'status': 'ok'},
        }),
        assistantFrom({'id': 'a1', 'content': 'old answer'}),
      ];
      repo.blockingResult = SendResult.fromJson({
        'tool_messages': [
          {
            'id': 't2',
            'session_id': session,
            'role': 'tool',
            'content': 'new',
            'created_at': '2026-01-01T00:00:03Z',
            'meta': {'tool': 'calculator', 'call_id': 'c2', 'status': 'ok'},
          },
        ],
        'assistant_message': {
          'id': 'a2',
          'session_id': session,
          'role': 'assistant',
          'content': 'new answer',
          'created_at': '2026-01-01T00:00:04Z',
        },
      });
      await setUpContainer();
      await controller().regenerate();
      await pumpEventQueue();
      expect(state().messages.map((m) => m.id), ['u1', 't2', 'a2']);
      expect(state().sending, isFalse);
    });

    test('tool-role history rows parse into chip messages', () async {
      repo.history = [
        ChatMessage.fromJson({
          'id': 'u1',
          'session_id': session,
          'role': 'user',
          'content': '2+2?',
          'created_at': '2026-01-01T00:00:00Z',
        }),
        ChatMessage.fromJson({
          'id': 't1',
          'session_id': session,
          'role': 'tool',
          'content': '4',
          'created_at': '2026-01-01T00:00:01Z',
          'meta': {
            'tool': 'calculator',
            'call_id': 'call_1',
            'input': {'expression': '2+2'},
            'status': 'ok',
            'latency_ms': 12,
          },
        }),
        ChatMessage.fromJson({
          'id': 'a1',
          'session_id': session,
          'role': 'assistant',
          'content': 'It is 4.',
          'created_at': '2026-01-01T00:00:02Z',
          'meta': {
            'tool_calls': [
              {'tool': 'calculator', 'call_id': 'call_1', 'output': '4'},
            ],
          },
        }),
      ];
      await setUpContainer();
      final msgs = state().messages;
      expect(msgs[1].isToolRun, isTrue);
      final run = msgs[1].toolCalls.single;
      expect(run.tool, 'calculator');
      expect(run.callId, 'call_1');
      expect(run.output, '4');
      expect(run.status, ToolCallStatus.ok);
      expect(run.latencyMs, 12);
      expect(msgs[2].toolCalls.single.callId, 'call_1', reason: 'same run, deduped by the UI');
    });
  });
}
