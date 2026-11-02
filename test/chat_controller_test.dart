import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/api_client.dart';
import 'package:nexusbot/core/connectivity.dart';
import 'package:nexusbot/core/local_store.dart';
import 'package:nexusbot/core/preferences.dart';
import 'package:nexusbot/core/secure_storage.dart';
import 'package:nexusbot/core/sync.dart';
import 'package:nexusbot/features/attachments/attachments_repository.dart';
import 'package:nexusbot/features/chat/chat_cache.dart';
import 'package:nexusbot/features/chat/chat_controller.dart';
import 'package:nexusbot/features/chat/chat_models.dart';
import 'package:nexusbot/features/chat/chat_repository.dart';
import 'package:nexusbot/features/chat/send_queue.dart';
import 'package:nexusbot/features/tools/tools_repository.dart';
import 'package:nexusbot/features/usage/usage_model.dart';
import 'package:nexusbot/features/usage/usage_repository.dart';
import 'package:nexusbot/features/voice/audio_player_service.dart';
import 'package:nexusbot/features/voice/recorder.dart';
import 'package:nexusbot/features/voice/voice_models.dart';
import 'package:nexusbot/features/voice/voice_repository.dart';
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

  // ── Phase 4 ──
  /// `attachment_ids` / `voice_reply` of the most recent send of any kind.
  List<String>? lastAttachmentIds;
  VoiceReply? lastVoiceReply;

  /// Every `Idempotency-Key` seen on a send / edit / background call, in order.
  final keys = <String?>[];

  /// Every `updateSession` call: `{title, model, meta, assistantId, clearAssistantId}`.
  final updates = <Map<String, Object?>>[];

  /// Every `resolveApproval` call.
  final resolved = <(String approvalId, ApprovalDecision decision, StreamTransport transport)>[];
  StreamController<StreamEvent>? turn;

  /// The handle of the most recently opened turn (tests set `lastEventId`).
  ChatTurn? lastTurn;

  /// Answer for the non-streaming path and for `regenerate`.
  SendResult? blockingResult;

  // ── Phase 3 ──
  Map<String, SiblingsResult> siblings = {};
  final siblingCalls = <String>[];
  List<ChatMessage>? branchHistory;
  final branchCalls = <String>[];
  Object? editError;
  final editCalls = <({String messageId, String content})>[];
  Object? resumeError;
  final resumeCalls = <({String generationId, String? after})>[];
  ActiveGeneration? activeGen;
  BackgroundSend? backgroundResult;
  Object? backgroundError;
  final backgroundCalls = <String>[];
  Object? feedbackError;
  final feedbackCalls = <({String messageId, int? rating, String? comment})>[];

  @override
  Future<SendResult> sendBlocking({
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
    lastUseRag = useRag;
    lastUseTools = useTools;
    lastToolNames = toolNames;
    lastModel = model;
    lastCollectionIds = collectionIds;
    lastAttachmentIds = attachmentIds;
    lastVoiceReply = voiceReply;
    keys.add(idempotencyKey);
    return blockingResult!;
  }

  @override
  Future<SendResult> regenerate(String sessionId, {double? temperature}) async => blockingResult!;

  /// `next_cursor` of the newest page (null = the whole chat fits in one).
  String? nextCursor;

  /// Items of the page before [nextCursor] (`cursor=` requests).
  List<ChatMessage> olderHistory = [];
  Object? historyError;

  /// Every `cursor` seen by [loadHistoryPage], in order.
  final historyPageCalls = <String?>[];

  /// When set, the newest page is not answered until this completes (lets a
  /// test look at the cached frame first).
  Completer<void>? historyGate;

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId, {int limit = 100}) async =>
      (await loadHistoryPage(sessionId, limit: limit)).items;

  @override
  Future<HistoryPage> loadHistoryPage(String sessionId, {String? cursor, int limit = 50}) async {
    historyCalls++;
    historyPageCalls.add(cursor);
    if (cursor == null && historyGate != null) await historyGate!.future;
    final error = historyError;
    if (error != null) throw error;
    if (cursor != null) return HistoryPage(items: olderHistory);
    return HistoryPage(items: history, nextCursor: nextCursor);
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
    String? assistantId,
    bool clearAssistantId = false,
  }) async {
    updates.add({
      'title': title,
      'model': model,
      'meta': meta,
      'assistantId': assistantId,
      'clearAssistantId': clearAssistantId,
    });
    final current = await getSession(id);
    return session = current.copyWith(
      title: title,
      model: model,
      meta: meta,
      assistantId: assistantId,
      clearAssistantId: clearAssistantId,
    );
  }

  ChatTurn _openTurn(StreamTransport transport, {String? generationId}) {
    final controller = StreamController<StreamEvent>();
    turn = controller;
    return lastTurn = ChatTurn(
      transport: transport,
      events: controller.stream,
      generationId: generationId,
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
    String? idempotencyKey,
    List<String>? attachmentIds,
    VoiceReply? voiceReply,
  }) async {
    final error = openError;
    if (error != null) throw error;
    lastTransport = transport;
    lastUseRag = useRag;
    lastUseTools = useTools;
    lastToolNames = toolNames;
    lastModel = model;
    lastCollectionIds = collectionIds;
    lastAttachmentIds = attachmentIds;
    lastVoiceReply = voiceReply;
    keys.add(idempotencyKey);
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

  @override
  Future<SiblingsResult> listSiblings(String sessionId, String messageId) async {
    siblingCalls.add(messageId);
    return siblings[messageId] ?? const SiblingsResult(items: [], activeIndex: 0);
  }

  @override
  Future<List<ChatMessage>> branch(String sessionId, {required String leafMessageId}) async {
    branchCalls.add(leafMessageId);
    return branchHistory ?? history;
  }

  @override
  Future<ChatTurn> editMessage({
    required String sessionId,
    required String messageId,
    required String content,
    bool useRag = true,
    bool useTools = true,
    List<String>? toolNames,
    double? temperature,
    String? model,
    List<String>? collectionIds,
    String? idempotencyKey,
    List<String>? attachmentIds,
    VoiceReply? voiceReply,
  }) async {
    final error = editError;
    if (error != null) throw error;
    editCalls.add((messageId: messageId, content: content));
    lastAttachmentIds = attachmentIds;
    lastVoiceReply = voiceReply;
    keys.add(idempotencyKey);
    return _openTurn(StreamTransport.sse);
  }

  @override
  Future<ChatTurn> resumeGeneration(
    String sessionId,
    String generationId, {
    String? after,
  }) async {
    final error = resumeError;
    if (error != null) throw error;
    resumeCalls.add((generationId: generationId, after: after));
    return _openTurn(StreamTransport.sse, generationId: generationId);
  }

  @override
  Future<ActiveGeneration?> activeGeneration(String sessionId) async => activeGen;

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
    backgroundCalls.add(content);
    keys.add(idempotencyKey);
    final error = backgroundError;
    if (error != null) throw error;
    lastAttachmentIds = attachmentIds;
    lastVoiceReply = voiceReply;
    return backgroundResult!;
  }

  @override
  Future<MessageFeedback> setFeedback(
    String sessionId,
    String messageId, {
    required int rating,
    String? comment,
  }) async {
    final error = feedbackError;
    if (error != null) throw error;
    feedbackCalls.add((messageId: messageId, rating: rating, comment: comment));
    return MessageFeedback(rating: rating, comment: comment);
  }

  @override
  Future<void> clearFeedback(String sessionId, String messageId) async {
    final error = feedbackError;
    if (error != null) throw error;
    feedbackCalls.add((messageId: messageId, rating: null, comment: null));
  }
}

/// `POST /sessions/{id}/attachments` / `DELETE` stand-in.
class FakeAttachmentsRepository extends AttachmentsRepository {
  FakeAttachmentsRepository() : super(ApiClient.create(MemoryTokenStorage()));

  Object? uploadError;
  final uploads = <String>[];
  final deletes = <String>[];

  @override
  Future<Attachment> upload({
    required String sessionId,
    required Uint8List bytes,
    required String filename,
    void Function(double progress)? onProgress,
  }) async {
    final error = uploadError;
    if (error != null) throw error;
    uploads.add(filename);
    final image = filename.endsWith('.png');
    return Attachment(
      id: 'att-$filename',
      kind: image ? AttachmentKind.image : AttachmentKind.file,
      name: filename,
      mimeType: image ? 'image/png' : 'text/plain',
      sizeBytes: bytes.length,
      url: '/api/v1/sessions/$sessionId/attachments/att-$filename/content',
      hasText: !image,
      sessionId: sessionId,
    );
  }

  @override
  Future<void> delete(String sessionId, String attachmentId) async => deletes.add(attachmentId);
}

/// `POST /sessions/{id}/messages/voice` stand-in.
class FakeVoiceRepository extends VoiceRepository {
  FakeVoiceRepository() : super(ApiClient.create(MemoryTokenStorage()));

  Object? error;
  VoiceTurn? result;
  final calls = <({
    String filename,
    int size,
    bool useRag,
    bool useTools,
    String? model,
    bool replyAudio,
    String? voice,
    String? idempotencyKey,
  })>[];

  @override
  Future<VoiceTurn> sendVoiceTurn({
    required String sessionId,
    required Uint8List bytes,
    required String filename,
    bool useRag = true,
    bool useTools = true,
    String? model,
    bool replyAudio = true,
    String? voice,
    String? audioFormat,
    String? language,
    String? idempotencyKey,
  }) async {
    final e = error;
    if (e != null) throw e;
    calls.add(
      (
        filename: filename,
        size: bytes.length,
        useRag: useRag,
        useTools: useTools,
        model: model,
        replyAudio: replyAudio,
        voice: voice,
        idempotencyKey: idempotencyKey,
      ),
    );
    return result!;
  }
}

/// Records what the controller plays; `playingStream` is driven by the test.
class FakeAudioPlayerService implements AudioPlayerService {
  final enqueued = <AudioClip>[];
  final played = <AudioClip>[];
  int stopCalls = 0;
  final _playing = StreamController<bool>.broadcast();
  bool _isPlaying = false;

  @override
  bool get isPlaying => _isPlaying;

  @override
  Stream<bool> get playingStream => _playing.stream;

  void finish() {
    _isPlaying = false;
    _playing.add(false);
  }

  @override
  Future<void> enqueue(AudioClip clip) async {
    enqueued.add(clip);
    _isPlaying = true;
  }

  @override
  Future<void> play(AudioClip clip) async {
    played.add(clip);
    _isPlaying = true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _isPlaying = false;
  }

  @override
  Future<void> dispose() => _playing.close();
}

/// Serves attachment content from memory.
class FakeContentLoader implements AttachmentContentLoader {
  final loaded = <String>[];
  Object? error;

  @override
  Future<AttachmentBytes> load(String url) async {
    final e = error;
    if (e != null) throw e;
    loaded.add(url);
    return AttachmentBytes(bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'audio/mpeg');
  }
}

/// `GET /usage/me` stand-in for the quota refresh.
class FakeUsageRepository extends UsageRepository {
  FakeUsageRepository() : super(ApiClient.create(MemoryTokenStorage()));

  int meCalls = 0;
  UsageSummary summary = usageSummary(remainingUsd: 4);

  @override
  Future<UsageSummary> me() async {
    meCalls++;
    return summary;
  }
}

UsageSummary usageSummary({required double remainingUsd}) => UsageSummary.fromJson({
      'period': {'start': '2026-11-01T00:00:00+00:00', 'end': '2026-12-01T00:00:00+00:00'},
      'user': {'tokens': 10, 'cost_usd': 0.1, 'messages': 1},
      'org': {
        'id': 'o1',
        'tokens': 100,
        'cost_usd': 10 - remainingUsd,
        'messages': 5,
        'budget_usd_per_month': 10,
        'remaining_usd': remainingUsd,
      },
    });

const session = 's1';

ChatMessage assistantFrom(Map<String, dynamic> data) =>
    AssistantMessageEvent(data: data).toMessage(session);

ChatMessage userMessage(String id, String content, {String? parentId, SiblingInfo? siblings}) =>
    ChatMessage(
      id: id,
      sessionId: session,
      role: MessageRole.user,
      content: content,
      createdAt: DateTime(2026),
      parentId: parentId,
      siblings: siblings,
    );

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

ApiException quotaException() => ApiException(
      code: 'quota_exceeded',
      message: 'Monthly spending budget exhausted for this organization',
      statusCode: 429,
      details: const {
        'budget_usd_per_month': 10.0,
        'used_usd': 10.2,
        'resets_at': '2026-12-01T00:00:00+00:00',
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeChatRepository repo;
  late FakeUsageRepository usageRepo;
  late FakeAttachmentsRepository attachmentsRepo;
  late FakeVoiceRepository voiceRepo;
  late FakeAudioPlayerService player;
  late FakeContentLoader loader;
  late ManualConnectivityService connectivity;
  late MemoryLocalStore store;
  late ProviderContainer container;

  Future<void> setUpContainer({
    StreamTransport transport = StreamTransport.sse,
    bool streaming = true,
    bool tools = true,
    bool rag = true,
    bool speakReplies = false,
    String? voice,
    List<ToolInfo> toolCatalog = const [],
    List<String>? sessionToolNames,
  }) async {
    SharedPreferences.setMockInitialValues({
      'pref.transport': transport.index,
      'pref.streaming': streaming,
      'pref.tools': tools,
      'pref.rag': rag,
      'pref.speakReplies': speakReplies,
      if (voice != null) 'pref.voice': voice,
      if (sessionToolNames != null) 'pref.session.$session.toolNames': sessionToolNames,
    });
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        // No platform channels: the signed-in user resolves to null.
        tokenStorageProvider.overrideWithValue(MemoryTokenStorage()),
        localStoreProvider.overrideWithValue(store),
        connectivityServiceProvider.overrideWithValue(connectivity),
        chatRepositoryProvider.overrideWith((ref) async => repo),
        usageRepositoryProvider.overrideWith((ref) async => usageRepo),
        attachmentsRepositoryProvider.overrideWith((ref) async => attachmentsRepo),
        voiceRepositoryProvider.overrideWith((ref) async => voiceRepo),
        audioPlayerProvider.overrideWithValue(player),
        attachmentContentLoaderProvider.overrideWithValue(loader),
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
    container.listen(quotaStateProvider, (_, __) {});
    await pumpEventQueue();
  }

  ChatState state() => container.read(chatControllerProvider(session));
  ChatController controller() => container.read(chatControllerProvider(session).notifier);
  QuotaExceeded? quota() => container.read(quotaStateProvider);

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

  setUp(() {
    repo = FakeChatRepository();
    usageRepo = FakeUsageRepository();
    attachmentsRepo = FakeAttachmentsRepository();
    voiceRepo = FakeVoiceRepository();
    player = FakeAudioPlayerService();
    loader = FakeContentLoader();
    connectivity = ManualConnectivityService();
    store = MemoryLocalStore();
  });

  test('loads history on creation', () async {
    repo.history = [
      assistantFrom({
        'id': 'a0',
        'content': 'earlier',
        'meta': {'status': 'interrupted'},
      }),
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
          Citation(
            documentId: 'd1',
            documentName: 'spec.pdf',
            chunkIndex: 0,
            score: 0.9,
            excerpt: 'x',
          ),
        ],
      ),
    );
    await emit(turn, const ToolCallEvent(data: {'phase': 'start', 'tool': 'calculator'}));
    expect(state().messages.last.toolCalls, isEmpty, reason: 'start frames carry no result');
    await emit(
      turn,
      const ToolCallEvent(
        data: {'phase': 'end', 'tool': 'calculator', 'input': '2+2', 'output': '4'},
      ),
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
        data: {
          'phase': 'end',
          'tool': 'web_search',
          'call_id': 'c1',
          'output': 'ok',
          'latency_ms': 7,
        },
      ),
    );
    await emit(
      turn,
      const ToolCallEvent(
        data: {'phase': 'end', 'tool': 'calculator', 'call_id': 'c2', 'output': '4'},
      ),
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
        data: {
          'id': 'a1',
          'content': 'Hello!',
          'created_at': '2026-01-01T00:00:01Z',
          'model': 'gpt-4o',
        },
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
    expect(state().error?.text, 'model exploded');
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
    expect(state().error?.text, 'cut off');
  });

  test('busy error gets a friendly message', () async {
    await setUpContainer();
    final turn = await send('hello');
    await emit(turn, const ErrorEvent(message: 'generation in progress', code: 'busy'));
    expect(state().error?.text, contains('still answering'));
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
    expect(state().error?.text, 'Too many requests (ref c0ffee12)');
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
    expect(repo.resumeCalls, isEmpty, reason: 'no generation id yet → nothing to resume');
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
        meta: const {
          'collection_ids': ['c1', 'c2'],
        },
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
      expect(repo.updates.single['meta'], {
        'other': 1,
        'collection_ids': ['c9'],
      });
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

    test('setAssistant patches assistant_id; null clears it', () async {
      await setUpContainer();
      await controller().setAssistant('as1');
      expect(repo.updates.single['assistantId'], 'as1');
      expect(state().session?.assistantId, 'as1');
      await controller().setAssistant(null);
      expect(repo.updates.last['clearAssistantId'], isTrue);
      expect(state().session?.assistantId, isNull);
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
          data: {
            'id': 'a1',
            'content': 'Let me check. I was not allowed to search.',
            'status': 'ok',
          },
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
      expect(state().error?.text, 'offline');
      final last = state().messages.last;
      expect(last.approval?.approvalId, 'ap1');
      expect(last.awaitingApproval, isTrue);
      expect(last.streaming, isFalse);
    });

    test('409 / 404 on resolve refreshes the history', () async {
      await setUpContainer();
      await pauseForApproval();
      repo.resolveError =
          ApiException(code: 'conflict', message: 'already resolved', statusCode: 409);
      repo.history = [
        assistantFrom({
          'id': 'a1',
          'content': 'Resolved elsewhere',
          'meta': {'status': 'ok'},
        }),
      ];
      final historyCallsBefore = repo.historyCalls;
      await controller().resolveApproval('ap1', ApprovalDecision.approve);
      await pumpEventQueue();
      expect(repo.historyCalls, historyCallsBefore + 1);
      expect(state().error?.text, contains('refreshed'));
      expect(state().sending, isFalse);
      expect(state().messages.single.content, 'Resolved elsewhere');
      expect(state().messages.single.approval, isNull);
    });

    test('a stale-approval error frame over WebSocket also refreshes', () async {
      await setUpContainer(transport: StreamTransport.websocket);
      await pauseForApproval();
      repo.history = [
        assistantFrom({
          'id': 'a1',
          'content': 'Expired',
          'meta': {'status': 'ok'},
        }),
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
      expect(repo.keys.single, isNotNull, reason: 'blocking sends carry an Idempotency-Key');
    });

    test('regenerate swaps the previous reply, then reloads the branch with its siblings',
        () async {
      repo.history = [
        userMessage('u1', 'q'),
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
      final historyCallsBefore = repo.historyCalls;
      // What the server's active branch looks like after the regenerate: the
      // old reply is kept as a sibling of the new one.
      repo.history = [
        userMessage('u1', 'q'),
        assistantFrom({
          'id': 'a2',
          'content': 'new answer',
          'siblings': {'index': 1, 'count': 2},
        }),
      ];
      await controller().regenerate();
      await pumpEventQueue();
      expect(repo.historyCalls, historyCallsBefore + 1, reason: 'active branch reloaded');
      expect(state().messages.map((m) => m.id), ['u1', 'a2']);
      expect(state().messages.last.siblings?.count, 2);
      expect(state().messages.last.siblings?.displayIndex, 2);
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

  // ── Phase 3: branching ───────────────────────────────────────────────

  group('branching', () {
    final a0 = assistantFrom({'id': 'a0', 'content': 'first answer'});
    final a1 = assistantFrom({
      'id': 'a1',
      'content': 'second answer',
      'siblings': {'index': 1, 'count': 2},
    });

    test('‹ resolves the previous sibling through /siblings and swaps in its branch', () async {
      repo.history = [userMessage('u1', 'q'), a1];
      repo.siblings['a1'] = SiblingsResult(items: [a0, a1], activeIndex: 1);
      repo.branchHistory = [
        userMessage('u1', 'q'),
        assistantFrom({
          'id': 'a0',
          'content': 'first answer',
          'siblings': {'index': 0, 'count': 2},
        }),
      ];
      await setUpContainer();

      final future = controller().switchSibling('a1', -1);
      expect(state().switchingBranch, isTrue);
      await future;
      expect(repo.siblingCalls, ['a1']);
      expect(repo.branchCalls, ['a0'], reason: 'the chosen sibling is the new leaf');
      expect(state().messages.map((m) => m.id), ['u1', 'a0']);
      expect(state().messages.last.siblings?.displayIndex, 1);
      expect(state().session?.activeLeafId, 'a0');
      expect(state().switchingBranch, isFalse);
      expect(state().error, isNull);
    });

    test('› wraps around to the first sibling', () async {
      repo.history = [userMessage('u1', 'q'), a1];
      repo.siblings['a1'] = SiblingsResult(items: [a0, a1], activeIndex: 1);
      repo.branchHistory = [userMessage('u1', 'q'), a0];
      await setUpContainer();
      await controller().switchSibling('a1', 1);
      expect(repo.branchCalls, ['a0']);
    });

    test('a message without siblings is left alone', () async {
      repo.history = [userMessage('u1', 'q'), a0];
      repo.siblings['a0'] = SiblingsResult(items: [a0], activeIndex: 0);
      await setUpContainer();
      await controller().switchSibling('a0', 1);
      expect(repo.branchCalls, isEmpty);
      expect(state().switchingBranch, isFalse);
    });

    test('a failed switch surfaces the error and releases the switcher', () async {
      repo.history = [userMessage('u1', 'q'), a1];
      repo.siblings['a1'] = SiblingsResult(items: [a0, a1], activeIndex: 1);
      await setUpContainer();
      repo.branchHistory = null;
      repo.siblings['a1'] = const SiblingsResult(items: [], activeIndex: 0);
      await controller().switchSibling('a1', -1);
      expect(repo.branchCalls, isEmpty);
      expect(state().switchingBranch, isFalse);
    });

    test('editing a user message streams the reply into a new branch', () async {
      repo.history = [
        userMessage('u1', 'first question'),
        assistantFrom({'id': 'a1', 'content': 'first answer'}),
        userMessage('u2', 'second question', parentId: 'a1'),
        assistantFrom({'id': 'a2', 'content': 'second answer'}),
      ];
      await setUpContainer();

      await controller().editMessage('u2', 'second question, rephrased');
      await pumpEventQueue();
      expect(repo.editCalls.single.messageId, 'u2');
      expect(repo.editCalls.single.content, 'second question, rephrased');
      expect(repo.keys.single, isNotNull, reason: 'edits carry an Idempotency-Key');
      expect(state().sending, isTrue);
      final msgs = state().messages;
      expect(msgs.map((m) => m.id).take(2), ['u1', 'a1'], reason: 'the branch root stays');
      expect(msgs[2].isPendingUser, isTrue);
      expect(msgs[2].content, 'second question, rephrased');
      expect(msgs[2].parentId, 'a1');
      expect(msgs[3].streaming, isTrue);
      expect(msgs, hasLength(4), reason: 'the old reply a2 is gone — the branch changed');

      final turn = repo.turn!;
      await emit(
        turn,
        const UserMessageEvent(
          data: {
            'id': 'u3',
            'content': 'second question, rephrased',
            'parent_id': 'a1',
            'generation_id': 'g3',
            'siblings': {'index': 1, 'count': 2},
          },
        ),
      );
      expect(state().messages[2].id, 'u3');
      expect(state().messages[2].parentId, 'a1');
      expect(state().messages[2].siblings?.count, 2);
      await emit(turn, const TokenEvent(token: 'New '));
      await emit(turn, const TokenEvent(token: 'answer'));
      expect(state().messages.last.content, 'New answer');
      await emit(
        turn,
        const AssistantMessageEvent(
          data: {'id': 'a3', 'content': 'New answer', 'parent_id': 'u3', 'generation_id': 'g3'},
        ),
      );
      expect(state().messages.map((m) => m.id), ['u1', 'a1', 'u3', 'a3']);
      expect(state().messages.last.parentId, 'u3');
      expect(state().sending, isFalse);
    });

    test('stop works on an edited turn', () async {
      repo.history = [
        userMessage('u1', 'q'),
        assistantFrom({'id': 'a1', 'content': 'a'}),
      ];
      await setUpContainer();
      await controller().editMessage('u1', 'q2');
      await pumpEventQueue();
      await emit(repo.turn!, const TokenEvent(token: 'part'));
      await controller().stop();
      await pumpEventQueue();
      expect(state().sending, isFalse);
      expect(state().messages.last.interrupted, isTrue);
      expect(state().messages.last.content, 'part');
      expect(repo.resumeCalls, isEmpty, reason: 'a user stop is never resumed');
    });

    test('a failed edit puts the branch back', () async {
      repo.history = [
        userMessage('u1', 'q'),
        assistantFrom({'id': 'a1', 'content': 'a'}),
        userMessage('u2', 'q2', parentId: 'a1'),
        assistantFrom({'id': 'a2', 'content': 'b'}),
      ];
      await setUpContainer();
      repo.editError = ApiException(code: 'network_error', message: 'offline');
      await controller().editMessage('u1', 'changed');
      await pumpEventQueue();
      expect(state().messages.map((m) => m.id), ['u1', 'a1', 'u2', 'a2']);
      expect(state().messages.first.content, 'q');
      expect(state().sending, isFalse);
      expect(state().error?.text, 'offline');
    });
  });

  // ── Phase 3: resumable streams, attach, background ──────────────────

  group('resume & attach', () {
    const userWithGeneration = UserMessageEvent(
      data: {'id': 'u1', 'content': 'hello', 'generation_id': 'g1'},
    );

    test('a transport drop mid-stream reconnects once after the last seq and continues the bubble',
        () async {
      await setUpContainer();
      final turn = await send('hello');
      await emit(turn, userWithGeneration);
      await emit(turn, const TokenEvent(token: 'Hel'));
      repo.lastTurn!.lastEventId = '3';

      await emit(turn, const ErrorEvent(message: 'socket closed', code: 'network_error'));
      expect(repo.resumeCalls, [(generationId: 'g1', after: '3')]);
      expect(state().sending, isTrue, reason: 'still streaming — into the same bubble');
      expect(state().error, isNull);
      expect(state().messages.last.content, 'Hel');
      expect(state().messages.last.streaming, isTrue);

      final resumed = repo.turn!;
      expect(resumed, isNot(same(turn)));
      await emit(resumed, const TokenEvent(token: 'lo'));
      expect(state().messages.last.content, 'Hello', reason: 'replay continues the buffer');
      await emit(
        resumed,
        const AssistantMessageEvent(data: {'id': 'a1', 'content': 'Hello', 'generation_id': 'g1'}),
      );
      expect(state().messages.map((m) => m.id), ['u1', 'a1']);
      expect(state().messages.last.generationId, 'g1');
      expect(state().sending, isFalse);
    });

    test('a drop of the resumed stream is not resumed again', () async {
      await setUpContainer();
      final turn = await send('hello');
      await emit(turn, userWithGeneration);
      await emit(turn, const TokenEvent(token: 'Hel'));
      await emit(turn, const ErrorEvent(message: 'drop', code: 'network_error'));
      expect(repo.resumeCalls, hasLength(1));

      await emit(repo.turn!, const ErrorEvent(message: 'drop again', code: 'network_error'));
      expect(repo.resumeCalls, hasLength(1), reason: 'one reconnect per turn');
      expect(state().sending, isFalse);
      expect(state().error?.text, 'drop again');
      expect(state().messages.last.content, 'Hel');
      expect(state().messages.last.streaming, isFalse);
    });

    test('a clean close without a terminal event is treated as a drop too', () async {
      await setUpContainer();
      final turn = await send('hello');
      await emit(turn, userWithGeneration);
      await emit(turn, const TokenEvent(token: 'Hel'));
      await turn.close();
      await pumpEventQueue();
      expect(repo.resumeCalls.single.generationId, 'g1');
      expect(state().sending, isTrue);
    });

    test('a failed reconnect falls back to the error path', () async {
      await setUpContainer();
      final turn = await send('hello');
      await emit(turn, userWithGeneration);
      await emit(turn, const TokenEvent(token: 'Hel'));
      repo.resumeError =
          ApiException(code: 'not_found', message: 'generation expired', statusCode: 404);
      await emit(turn, const ErrorEvent(message: 'drop', code: 'network_error'));
      expect(state().sending, isFalse);
      expect(state().error?.text, 'generation expired');
      expect(state().messages.last.content, 'Hel', reason: 'partial text is kept');
      expect(state().messages.last.streaming, isFalse);
    });

    test('a drop before the generation id is known is not resumable', () async {
      await setUpContainer();
      final turn = await send('hello');
      await emit(turn, const TokenEvent(token: 'Hel'));
      await emit(turn, const ErrorEvent(message: 'drop', code: 'network_error'));
      expect(repo.resumeCalls, isEmpty);
      expect(state().sending, isFalse);
      expect(state().error?.text, 'drop');
    });

    test('a WebSocket drop replays from the first frame without doubling the text', () async {
      await setUpContainer(transport: StreamTransport.websocket);
      final turn = await send('hello');
      await emit(turn, userWithGeneration);
      await emit(turn, const TokenEvent(token: 'Hel'));
      await emit(turn, const ErrorEvent(message: 'drop', code: 'network_error'));
      expect(repo.resumeCalls, [(generationId: 'g1', after: null)]);

      final resumed = repo.turn!;
      await emit(resumed, userWithGeneration);
      await emit(resumed, const TokenEvent(token: 'Hel'));
      await emit(resumed, const TokenEvent(token: 'lo'));
      expect(state().messages.last.content, 'Hello');
      expect(state().messages.where((m) => m.role == MessageRole.user), hasLength(1));
    });

    test('opening a chat with a running generation attaches to it', () async {
      repo.history = [userMessage('u1', 'hello')];
      repo.activeGen = const ActiveGeneration(generationId: 'g9', status: 'running');
      await setUpContainer();

      expect(repo.resumeCalls, [(generationId: 'g9', after: null)]);
      expect(state().sending, isTrue);
      expect(state().messages.map((m) => m.id).first, 'u1');
      expect(state().messages.last.streaming, isTrue);
      expect(state().messages.last.generationId, 'g9');

      final turn = repo.turn!;
      await emit(
        turn,
        const UserMessageEvent(data: {'id': 'u1', 'content': 'hello', 'generation_id': 'g9'}),
      );
      expect(state().messages, hasLength(2), reason: 'the replayed user message is already there');
      await emit(turn, const TokenEvent(token: 'Hi!'));
      await emit(
        turn,
        const AssistantMessageEvent(data: {'id': 'a9', 'content': 'Hi!', 'generation_id': 'g9'}),
      );
      expect(state().messages.map((m) => m.id), ['u1', 'a9']);
      expect(state().sending, isFalse);
    });

    test('a replayed user message missing from history is inserted before the bubble', () async {
      repo.history = [
        userMessage('u0', 'earlier'),
        assistantFrom({'id': 'a0', 'content': 'x'}),
      ];
      repo.activeGen = const ActiveGeneration(generationId: 'g9', status: 'running');
      await setUpContainer();
      await emit(
        repo.turn!,
        const UserMessageEvent(data: {'id': 'u1', 'content': 'hello', 'generation_id': 'g9'}),
      );
      expect(state().messages.map((m) => m.id).take(3), ['u0', 'a0', 'u1']);
      expect(state().messages.last.streaming, isTrue);
    });

    test('a finished generation is not attached', () async {
      repo.history = [userMessage('u1', 'hello')];
      repo.activeGen = const ActiveGeneration(generationId: 'g9', status: 'done');
      await setUpContainer();
      expect(repo.resumeCalls, isEmpty);
      expect(state().sending, isFalse);
      expect(state().messages, hasLength(1));
    });

    test('sendInBackground posts to /background, keeps the persisted user message and attaches',
        () async {
      await setUpContainer();
      repo.backgroundResult = BackgroundSend(
        generationId: 'g5',
        userMessage: userMessage('u5', 'later'),
      );
      await controller().sendInBackground('later');
      await pumpEventQueue();
      expect(repo.backgroundCalls, ['later']);
      expect(repo.keys.single, isNotNull, reason: 'background sends carry an Idempotency-Key');
      expect(repo.resumeCalls, [(generationId: 'g5', after: null)]);
      expect(state().sending, isTrue);
      expect(state().messages.first.id, 'u5');
      expect(state().messages.last.streaming, isTrue);
      expect(state().messages.last.generationId, 'g5');

      final turn = repo.turn!;
      await emit(turn, const TokenEvent(token: 'Done'));
      await emit(
        turn,
        const AssistantMessageEvent(data: {'id': 'a5', 'content': 'Done', 'generation_id': 'g5'}),
      );
      expect(state().messages.map((m) => m.id), ['u5', 'a5']);
      expect(state().sending, isFalse);
    });

    test('a refused background send drops the placeholder', () async {
      await setUpContainer();
      repo.backgroundError = ApiException(code: 'busy', message: 'generation in progress');
      await controller().sendInBackground('later');
      await pumpEventQueue();
      expect(state().sending, isFalse);
      expect(state().error?.text, 'generation in progress');
      expect(state().messages.single.role, MessageRole.user);
    });

    test('every send attempt gets a fresh Idempotency-Key', () async {
      await setUpContainer();
      await send('one');
      await emit(repo.turn!, const AssistantMessageEvent(data: {'id': 'a1', 'content': 'x'}));
      await send('two');
      await emit(repo.turn!, const AssistantMessageEvent(data: {'id': 'a2', 'content': 'y'}));
      expect(repo.keys, hasLength(2));
      expect(repo.keys.toSet(), hasLength(2), reason: 'distinct UUIDs');
      expect(repo.keys.first, matches(RegExp(r'^[0-9a-f-]{36}$')));
    });
  });

  // ── Phase 3: quota ────────────────────────────────────────────────────

  group('quota', () {
    test('a 429 quota_exceeded on send raises the app-wide banner and drops the placeholder',
        () async {
      await setUpContainer();
      repo.openError = quotaException();
      await controller().send('hello');
      await pumpEventQueue();
      final q = quota();
      expect(q, isNotNull);
      expect(q!.resetsAt?.toUtc().month, 12);
      expect(q.budgetUsd, 10);
      expect(q.usedUsd, 10.2);
      expect(q.figures, r'$10.20 of $10.00 spent');
      expect(state().sending, isFalse);
      expect(state().error, isNull, reason: 'the banner replaces the inline error');
      expect(state().messages.single.role, MessageRole.user);
    });

    test('a quota_exceeded error frame does the same', () async {
      await setUpContainer();
      final turn = await send('hello');
      await emit(
        turn,
        const ErrorEvent(
          message: 'budget spent',
          code: 'quota_exceeded',
          details: {
            'budget_tokens_per_month': 1000,
            'used_tokens': 1200,
            'resets_at': '2026-12-01T00:00:00Z',
          },
        ),
      );
      final q = quota();
      expect(q?.budgetTokens, 1000);
      expect(q?.figures, '1.2k of 1k tokens used');
      expect(state().sending, isFalse);
      expect(state().error, isNull);
      expect(state().messages, hasLength(1));
    });

    test('a refused edit keeps the branch intact', () async {
      repo.history = [
        userMessage('u1', 'q'),
        assistantFrom({'id': 'a1', 'content': 'a'}),
      ];
      await setUpContainer();
      repo.editError = quotaException();
      await controller().editMessage('u1', 'changed');
      await pumpEventQueue();
      expect(quota(), isNotNull);
      expect(state().messages.map((m) => m.id), ['u1', 'a1']);
      expect(state().sending, isFalse);
    });

    test('refreshQuota clears the banner once /usage/me allows turns again', () async {
      await setUpContainer();
      repo.openError = quotaException();
      await controller().send('hello');
      await pumpEventQueue();
      expect(quota(), isNotNull);

      usageRepo.summary = usageSummary(remainingUsd: 0);
      expect(await controller().refreshQuota(), isFalse);
      expect(quota(), isNotNull, reason: 'still exhausted');
      expect(usageRepo.meCalls, 1);

      usageRepo.summary = usageSummary(remainingUsd: 2.5);
      expect(await controller().refreshQuota(), isTrue);
      expect(quota(), isNull);
      expect(usageRepo.meCalls, 2);

      // Sending works again.
      repo.openError = null;
      await send('again');
      expect(state().sending, isTrue);
    });
  });

  // ── Phase 3: feedback ─────────────────────────────────────────────────

  group('feedback', () {
    test('setFeedback updates the message optimistically and posts the rating', () async {
      repo.history = [
        userMessage('u1', 'q'),
        assistantFrom({'id': 'a1', 'content': 'a'}),
      ];
      await setUpContainer();
      await controller().setFeedback('a1', -1, comment: 'wrong');
      expect(repo.feedbackCalls.single, (messageId: 'a1', rating: -1, comment: 'wrong'));
      expect(state().messages.last.feedback?.isDown, isTrue);
      expect(state().messages.last.feedback?.comment, 'wrong');

      await controller().clearFeedback('a1');
      expect(repo.feedbackCalls.last.rating, isNull);
      expect(state().messages.last.feedback, isNull);
    });

    test('a failed feedback call reverts the message', () async {
      repo.history = [
        userMessage('u1', 'q'),
        ChatMessage.fromJson({
          'id': 'a1',
          'session_id': session,
          'role': 'assistant',
          'content': 'a',
          'created_at': '2026-01-01T00:00:00Z',
          'meta': {
            'feedback': {'rating': 1, 'comment': null},
          },
        }),
      ];
      await setUpContainer();
      expect(state().messages.last.feedback?.isUp, isTrue, reason: 'reflected from history');
      repo.feedbackError = ApiException(code: 'network_error', message: 'offline');
      await controller().setFeedback('a1', -1);
      expect(state().messages.last.feedback?.isUp, isTrue, reason: 'reverted');
      expect(state().error?.text, 'offline');
      await controller().clearFeedback('a1');
      expect(state().messages.last.feedback?.isUp, isTrue, reason: 'reverted again');
    });
  });

  // ── Phase 4: attachments ─────────────────────────────────────────────

  group('attachments', () {
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);

    test('attachFile uploads into the composer; the next send binds the ids and clears them',
        () async {
      await setUpContainer();
      final att = await controller().attachFile(bytes: png, filename: 'chart.png');
      expect(att?.id, 'att-chart.png');
      expect(attachmentsRepo.uploads, ['chart.png']);
      expect(state().uploading, 0);
      expect(state().pendingAttachments.map((a) => a.id), ['att-chart.png']);
      expect(controller().hasPendingImages, isTrue);

      await send('what is this?');
      expect(repo.lastAttachmentIds, ['att-chart.png']);
      expect(repo.lastVoiceReply, isNull, reason: 'speak replies is off');
      expect(state().pendingAttachments, isEmpty, reason: 'bound to the turn');
      final optimistic = state().messages.first;
      expect(optimistic.isPendingUser, isTrue);
      expect(optimistic.attachments.single.name, 'chart.png', reason: 'shown on the bubble');

      await emit(
        repo.turn!,
        const UserMessageEvent(
          data: {
            'id': 'u1',
            'content': 'what is this?',
            'attachments': [
              {
                'id': 'att-chart.png',
                'kind': 'image',
                'name': 'chart.png',
                'mime_type': 'image/png',
                'size_bytes': 4,
                'width': 10,
                'height': 10,
                'url': '/api/v1/sessions/s1/attachments/att-chart.png/content',
              },
            ],
          },
        ),
      );
      expect(state().messages.first.id, 'u1');
      expect(state().messages.first.attachments.single.width, 10);
    });

    test('a refused upload surfaces the error and nothing is parked', () async {
      await setUpContainer();
      attachmentsRepo.uploadError =
          ApiException(code: 'validation_error', message: 'Type not allowed', statusCode: 422);
      final att = await controller().attachFile(bytes: png, filename: 'x.exe');
      expect(att, isNull);
      expect(state().pendingAttachments, isEmpty);
      expect(state().uploading, 0);
      expect(state().error?.text, 'Type not allowed');
    });

    test('a vision refusal keeps the attachments and names the vision models', () async {
      await setUpContainer();
      await controller().attachFile(bytes: png, filename: 'chart.png');
      repo.openError = ApiException(
        code: 'validation_error',
        message: 'Model llama3 cannot read images.',
        statusCode: 422,
        details: const {
          'vision_models': ['gpt-4o', 'gpt-4o-mini'],
        },
      );
      await controller().send('describe');
      await pumpEventQueue();
      expect(state().sending, isFalse);
      expect(
        state().error?.text,
        'Model llama3 cannot read images. Models with vision: gpt-4o, gpt-4o-mini.',
      );
      expect(state().pendingAttachments, hasLength(1), reason: 'retry after switching models');
    });

    test('removeAttachment drops the chip and deletes the upload', () async {
      await setUpContainer();
      await controller().attachFile(bytes: png, filename: 'notes.txt');
      await controller().removeAttachment('att-notes.txt');
      expect(state().pendingAttachments, isEmpty);
      expect(attachmentsRepo.deletes, ['att-notes.txt']);
      await send('hi');
      expect(repo.lastAttachmentIds, isNull);
    });

    test('background sends and edits carry the attachment ids too', () async {
      repo.history = [
        userMessage('u1', 'q'),
        assistantFrom({'id': 'a1', 'content': 'a'}),
      ];
      await setUpContainer();
      await controller().attachFile(bytes: png, filename: 'a.txt');
      repo.backgroundResult =
          BackgroundSend(generationId: 'g5', userMessage: userMessage('u5', 'x'));
      await controller().sendInBackground('x');
      await pumpEventQueue();
      expect(repo.lastAttachmentIds, ['att-a.txt']);
      expect(state().pendingAttachments, isEmpty);
      await emit(repo.turn!, const AssistantMessageEvent(data: {'id': 'a5', 'content': 'y'}));

      await controller().attachFile(bytes: png, filename: 'b.txt');
      await controller().editMessage('u1', 'q2');
      await pumpEventQueue();
      expect(repo.lastAttachmentIds, ['att-b.txt']);
      expect(state().pendingAttachments, isEmpty);
    });

    test('the Speak replies preference asks for a spoken reply with the chosen voice', () async {
      await setUpContainer(speakReplies: true, voice: 'nova');
      await send('read this');
      expect(repo.lastVoiceReply?.voice, 'nova');
      expect(repo.lastVoiceReply?.toJson(), {'voice_reply': true, 'voice': 'nova'});
    });
  });

  // ── Phase 4: artifacts and spoken replies ────────────────────────────

  group('artifacts & audio', () {
    const artifactJson = {
      'id': 'art-1',
      'kind': 'artifact',
      'name': 'plot.png',
      'mime_type': 'image/png',
      'size_bytes': 1234,
      'url': '/api/v1/sessions/s1/attachments/art-1/content',
      'has_text': false,
    };

    test('artifact frames attach files to the bubble and merge with the final message', () async {
      await setUpContainer();
      final turn = await send('plot it');
      await emit(turn, const ArtifactEvent(data: artifactJson));
      expect(state().messages.last.artifacts.single.name, 'plot.png');
      expect(state().messages.last.artifacts.single.isRenderableImage, isTrue);
      await emit(turn, const ArtifactEvent(data: artifactJson));
      expect(state().messages.last.artifacts, hasLength(1), reason: 'same id, listed once');

      await emit(
        turn,
        const AssistantMessageEvent(
          data: {
            'id': 'a1',
            'content': 'Here is the plot.',
            'artifacts': [
              artifactJson,
              {
                'id': 'art-2',
                'kind': 'artifact',
                'name': 'data.csv',
                'mime_type': 'text/csv',
                'size_bytes': 10,
                'url': '/api/v1/sessions/s1/attachments/art-2/content',
              },
            ],
          },
        ),
      );
      expect(state().messages.last.id, 'a1');
      expect(state().messages.last.artifacts.map((a) => a.name), ['plot.png', 'data.csv']);
    });

    test('audio chunks play in order and audio_done keeps the stored clip for replay', () async {
      await setUpContainer();
      final turn = await send('say hi');
      final placeholderId = state().messages.last.id;
      await emit(
        turn,
        AudioChunkEvent(
          data: {
            'index': 0,
            'text': 'Hi.',
            'format': 'wav',
            'mime_type': 'audio/wav',
            'data': base64Encode([1, 2, 3]),
          },
        ),
      );
      await emit(
        turn,
        AudioChunkEvent(
          data: {
            'index': 1,
            'text': 'Bye.',
            'format': 'wav',
            'data': base64Encode([4, 5]),
          },
        ),
      );
      await emit(turn, const AudioChunkEvent(data: {'index': 2, 'data': 'not base64!'}));
      expect(player.enqueued.map((c) => c.bytes.length), [3, 2], reason: 'bad chunk skipped');
      expect(player.enqueued.first.mimeType, 'audio/wav');
      expect(player.enqueued.last.mimeType, 'audio/wav', reason: 'derived from the format');
      expect(state().playingMessageId, placeholderId);

      await emit(
        turn,
        const AudioDoneEvent(
          data: {
            'chunks': 2,
            'attachment': {
              'id': 'spk-1',
              'kind': 'audio',
              'name': 'reply.wav',
              'mime_type': 'audio/wav',
              'size_bytes': 5,
              'url': '/api/v1/sessions/s1/attachments/spk-1/content',
            },
          },
        ),
      );
      expect(state().messages.last.audio?.attachmentId, 'spk-1');
      expect(state().messages.last.audio?.chunks, 2);
      expect(state().messages.last.audio?.format, 'wav');

      await emit(turn, const AssistantMessageEvent(data: {'id': 'a1', 'content': 'Hi. Bye.'}));
      expect(state().messages.last.audio?.attachmentId, 'spk-1', reason: 'kept from audio_done');
      expect(state().playingMessageId, 'a1', reason: 'follows the persisted bubble');
      expect(state().sending, isFalse);

      player.finish();
      await pumpEventQueue();
      expect(state().playingMessageId, isNull);
    });

    test('a failed synthesis leaves the text reply untouched', () async {
      await setUpContainer();
      final turn = await send('say hi');
      await emit(
        turn,
        const AudioDoneEvent(data: {'chunks': 0, 'attachment': null, 'error': 'tts down'}),
      );
      await emit(turn, const AssistantMessageEvent(data: {'id': 'a1', 'content': 'Hi.'}));
      expect(state().messages.last.audio, isNull);
      expect(state().error, isNull);
      expect(player.enqueued, isEmpty);
    });

    test('playMessageAudio downloads the stored clip; tapping again stops it', () async {
      repo.history = [
        userMessage('u1', 'q'),
        assistantFrom({
          'id': 'a1',
          'content': 'Spoken.',
          'meta': {
            'audio': {
              'attachment_id': 'spk-1',
              'url': '/api/v1/sessions/s1/attachments/spk-1/content',
              'format': 'mp3',
              'chunks': 3,
            },
          },
        }),
      ];
      await setUpContainer();
      final reply = state().messages.last;
      expect(reply.audio?.isPlayable, isTrue);
      await controller().playMessageAudio(reply);
      expect(loader.loaded, ['/api/v1/sessions/s1/attachments/spk-1/content']);
      expect(player.played.single.mimeType, 'audio/mpeg');
      expect(state().playingMessageId, 'a1');

      await controller().playMessageAudio(reply);
      expect(player.stopCalls, 1);
      expect(state().playingMessageId, isNull);

      loader.error = ApiException(code: 'not_found', message: 'gone', statusCode: 404);
      await controller().playMessageAudio(reply);
      expect(state().playingMessageId, isNull);
      expect(state().error?.text, 'gone');
    });
  });

  // ── Phase 4: voice turns ─────────────────────────────────────────────

  group('voice', () {
    final clip = RecordedClip(
      bytes: Uint8List.fromList(List.filled(32, 7)),
      mimeType: 'audio/mp4',
      filename: 'voice.m4a',
    );

    test('sendVoice posts the clip, shows the transcript and attaches to the generation', () async {
      await setUpContainer(voice: 'alloy');
      voiceRepo.result = const VoiceTurn(
        generationId: 'g-v',
        transcript: 'hello there',
        userMessageId: 'u-v',
        attachmentId: 'att-v',
      );
      controller().setModelOverride('gpt-4o');
      final future = controller().sendVoice(clip);
      expect(state().sending, isTrue);
      expect(state().messages.first.content, ChatController.voicePlaceholderText);
      await future;
      await pumpEventQueue();

      final call = voiceRepo.calls.single;
      expect(call.filename, 'voice.m4a');
      expect(call.size, 32);
      expect(call.useRag, isTrue);
      expect(call.useTools, isTrue);
      expect(call.model, 'gpt-4o');
      expect(call.replyAudio, isTrue, reason: 'voice mode always asks for a spoken reply');
      expect(call.voice, 'alloy');
      expect(call.idempotencyKey, isNotNull);

      expect(repo.resumeCalls, [(generationId: 'g-v', after: null)]);
      final user = state().messages.first;
      expect(user.id, 'u-v');
      expect(user.content, 'hello there');
      expect(user.isPendingUser, isFalse);
      expect(user.attachments.single.id, 'att-v');
      expect(user.attachments.single.isAudio, isTrue);
      expect(state().messages.last.streaming, isTrue);
      expect(state().messages.last.generationId, 'g-v');

      final turn = repo.turn!;
      await emit(
        turn,
        const UserMessageEvent(
          data: {
            'id': 'u-v',
            'content': 'hello there',
            'generation_id': 'g-v',
            'attachments': [
              {
                'id': 'att-v',
                'kind': 'audio',
                'name': 'voice.m4a',
                'mime_type': 'audio/mp4',
                'size_bytes': 32,
                'url': '/api/v1/sessions/s1/attachments/att-v/content',
                'has_text': true,
              },
            ],
          },
        ),
      );
      expect(state().messages, hasLength(2), reason: 'the replayed user message updates in place');
      expect(state().messages.first.attachments.single.hasText, isTrue);
      await emit(turn, const TokenEvent(token: 'Hi!'));
      await emit(
        turn,
        const AssistantMessageEvent(data: {'id': 'a-v', 'content': 'Hi!', 'generation_id': 'g-v'}),
      );
      expect(state().messages.map((m) => m.id), ['u-v', 'a-v']);
      expect(state().sending, isFalse);
    });

    test('a refused voice turn drops both optimistic bubbles', () async {
      await setUpContainer();
      voiceRepo.error = ApiException(
        code: 'service_unavailable',
        message: 'Speech-to-text is not configured',
        statusCode: 503,
        details: const {'code': 'voice_unavailable'},
      );
      await controller().sendVoice(clip);
      await pumpEventQueue();
      expect(state().sending, isFalse);
      expect(state().messages, isEmpty);
      expect(state().error?.text, 'Voice is not available on this server.');
      expect(repo.resumeCalls, isEmpty);
    });

    test('an empty clip is ignored', () async {
      await setUpContainer();
      await controller().sendVoice(
        RecordedClip(bytes: Uint8List(0), mimeType: 'audio/wav', filename: 'voice.wav'),
      );
      expect(voiceRepo.calls, isEmpty);
      expect(state().messages, isEmpty);
    });
  });

  // ── Phase 4: push notifications ──────────────────────────────────────

  group('push', () {
    test('attachToGeneration attaches a generation that is not in the history yet', () async {
      repo.history = [userMessage('u1', 'later')];
      await setUpContainer();
      await controller().attachToGeneration('g-push');
      await pumpEventQueue();
      expect(repo.resumeCalls, [(generationId: 'g-push', after: null)]);
      expect(state().sending, isTrue);
      expect(state().messages.last.streaming, isTrue);
      expect(state().messages.last.generationId, 'g-push');

      final turn = repo.turn!;
      await emit(turn, const TokenEvent(token: 'Done'));
      await emit(
        turn,
        const AssistantMessageEvent(
          data: {'id': 'a-push', 'content': 'Done', 'generation_id': 'g-push'},
        ),
      );
      expect(state().messages.map((m) => m.id), ['u1', 'a-push']);
      expect(state().sending, isFalse);
    });

    test('attachToGeneration is a no-op when the reply is already there or a turn runs', () async {
      repo.history = [
        userMessage('u1', 'later'),
        assistantFrom({'id': 'a1', 'content': 'Done', 'generation_id': 'g-push'}),
      ];
      await setUpContainer();
      await controller().attachToGeneration('g-push');
      expect(repo.resumeCalls, isEmpty);
      expect(state().sending, isFalse);

      await send('another');
      await controller().attachToGeneration('g-other');
      expect(repo.resumeCalls, isEmpty, reason: 'a turn is in flight');
    });

    test('attachToGeneration reloads the history when the replay is gone', () async {
      repo.history = [userMessage('u1', 'later')];
      await setUpContainer();
      repo.resumeError =
          ApiException(code: 'not_found', message: 'Generation expired', statusCode: 404);
      repo.history = [
        userMessage('u1', 'later'),
        assistantFrom({'id': 'a1', 'content': 'Persisted reply'}),
      ];
      final historyCallsBefore = repo.historyCalls;
      await controller().attachToGeneration('g-gone');
      await pumpEventQueue();
      expect(repo.historyCalls, historyCallsBefore + 1);
      expect(state().sending, isFalse);
      expect(state().error, isNull);
      expect(state().messages.map((m) => m.id), ['u1', 'a1']);
    });

    test('a failed attach surfaces the error', () async {
      repo.history = [userMessage('u1', 'later')];
      await setUpContainer();
      repo.resumeError = ApiException(code: 'network_error', message: 'offline');
      await controller().attachToGeneration('g-x');
      expect(state().sending, isFalse);
      expect(state().error?.text, 'offline');
      expect(state().messages, hasLength(1), reason: 'empty placeholder dropped');
    });
  });
  // ── Offline-first (phase 4b) ──────────────────────────────────────────

  group('offline-first', () {
    ChatMessage cachedUser(String id, String content) => ChatMessage(
          id: id,
          sessionId: session,
          role: MessageRole.user,
          content: content,
          createdAt: DateTime.utc(2026, 1, 1),
        );

    test('opens from the cache, then the network replaces it and refreshes the cache', () async {
      await ChatCache(MemoryLocalStore()).writeMessages('x', 'y', const []); // smoke
      store = MemoryLocalStore();
      final cache = ChatCache(store);
      await cache.writeMessages(
        'anon:personal',
        session,
        [cachedUser('old-1', 'from cache')],
        nextCursor: '2025-12-31T00:00:00Z',
      );
      repo.history = [userMessage('u1', 'fresh')];
      repo.nextCursor = '2026-01-01T00:00:00Z';
      repo.historyGate = Completer<void>();
      await setUpContainer();

      // The network is still pending: the cached copy is on screen.
      final cachedFrame = state();
      expect(cachedFrame.fromCache, isTrue);
      expect(cachedFrame.loaded, isTrue);
      expect(cachedFrame.messages.single.content, 'from cache');
      expect(cachedFrame.nextCursor, '2025-12-31T00:00:00Z');
      expect(repo.historyPageCalls, [null]);

      repo.historyGate!.complete();
      await pumpEventQueue();
      expect(state().fromCache, isFalse);
      expect(state().messages.single.content, 'fresh');
      expect(state().nextCursor, '2026-01-01T00:00:00Z');
      expect(state().loaded, isTrue);
      final stored = await store.read(ChatCache.messagesKey('anon:personal', session));
      expect((stored!['items'] as List).single['content'], 'fresh');
    });

    test('a network failure with a cached copy shows the copy without an error', () async {
      store = MemoryLocalStore();
      await ChatCache(store).writeMessages('anon:personal', session, [cachedUser('c1', 'kept')]);
      repo.historyError = ApiException(code: 'network_error', message: 'offline');
      await setUpContainer();
      expect(state().messages.single.content, 'kept');
      expect(state().fromCache, isTrue);
      expect(state().error, isNull);

      // Without a cache the failure is shown.
      store = MemoryLocalStore();
      await setUpContainer();
      expect(state().messages, isEmpty);
      expect(state().error?.text, 'offline');
      expect(state().loaded, isTrue);
    });

    test('loadOlder fetches the page before the cursor and prepends it', () async {
      repo.history = [userMessage('u2', 'newer')];
      repo.nextCursor = 'cursor-1';
      repo.olderHistory = [userMessage('u1', 'older'), userMessage('u2', 'newer')];
      await setUpContainer();
      expect(state().hasOlder, isTrue);
      await controller().loadOlder();
      await pumpEventQueue();
      expect(repo.historyPageCalls, [null, 'cursor-1']);
      expect(state().messages.map((m) => m.content), ['older', 'newer'], reason: 'deduplicated');
      expect(state().hasOlder, isFalse);
      expect(state().loadingOlder, isFalse);

      await controller().loadOlder();
      expect(repo.historyPageCalls, hasLength(2), reason: 'nothing older to fetch');
    });

    test('an offline send is queued as a pending bubble and replayed on reconnect', () async {
      await setUpContainer();
      connectivity.setOnline(false);
      await pumpEventQueue();
      await controller().send('later');
      await pumpEventQueue();

      expect(state().sending, isFalse, reason: 'the composer is free again');
      expect(state().error, isNull);
      final bubble = state().messages.single;
      expect(bubble.isQueued, isTrue);
      expect(bubble.delivery, MessageDelivery.queued);
      expect(bubble.content, 'later');
      expect(repo.keys, isEmpty, reason: 'the server was never contacted');
      final queued = container.read(sendQueueProvider).items.single;
      expect(bubble.id, 'pending-user-${queued.key}');
      expect(queued.content, 'later');
      expect((await store.read('sendqueue:anon:personal'))!['items'], hasLength(1));

      // Back online: replayed through /messages/background with the same key,
      // the bubble becomes the persisted message and the reply is attached.
      repo.backgroundResult = BackgroundSend(
        generationId: 'g1',
        userMessage: userMessage('u-persisted', 'later'),
      );
      connectivity.setOnline(true);
      await pumpEventQueue();
      expect(repo.backgroundCalls, ['later']);
      expect(repo.keys, [queued.key]);
      expect(container.read(sendQueueProvider).isEmpty, isTrue);
      expect(state().messages.first.id, 'u-persisted');
      expect(state().messages.first.isQueued, isFalse);
      expect(repo.resumeCalls.single.generationId, 'g1');
      expect(state().sending, isTrue);
      expect(state().messages.last.streaming, isTrue);

      repo.turn!.add(const TokenEvent(token: 'ok'));
      repo.turn!.add(const AssistantMessageEvent(data: {'id': 'a1', 'content': 'ok'}));
      await pumpEventQueue();
      expect(state().sending, isFalse);
      expect(state().messages.last.content, 'ok');
    });

    test('a transport failure when opening the stream queues instead of failing', () async {
      await setUpContainer();
      repo.openError = ApiException(code: 'network_error', message: 'Connection refused');
      await controller().send('flaky');
      await pumpEventQueue();
      expect(state().error, isNull);
      expect(state().messages.single.isQueued, isTrue);
      expect(container.read(sendQueueProvider).items.single.content, 'flaky');
      // Not a transport problem: still an inline error, nothing queued.
      repo.openError = ApiException(code: 'validation_error', message: 'Bad', statusCode: 422);
      await controller().cancelQueued(state().messages.single.id);
      await pumpEventQueue();
      expect(state().messages, isEmpty);
      await controller().send('bad');
      await pumpEventQueue();
      expect(state().error?.text, 'Bad');
      expect(container.read(sendQueueProvider).isEmpty, isTrue);
    });

    test('a parked send shows its reason; retry replays it, cancel drops it', () async {
      await setUpContainer();
      repo.backgroundError =
          ApiException(code: 'validation_error', message: 'Type not allowed', statusCode: 422);
      connectivity.setOnline(false);
      await pumpEventQueue();
      await controller().send('one');
      await pumpEventQueue();
      connectivity.setOnline(true);
      await pumpEventQueue();
      final parked = state().messages.single;
      expect(parked.delivery, MessageDelivery.failed);
      expect(parked.deliveryError, 'Type not allowed');

      repo.backgroundError = null;
      repo.backgroundResult = const BackgroundSend(generationId: 'g2');
      await controller().retryQueued(parked.id);
      await pumpEventQueue();
      expect(repo.backgroundCalls, ['one', 'one']);
      expect(state().messages.first.isQueued, isFalse);
      expect(repo.resumeCalls.single.generationId, 'g2');

      repo.turn!.add(const AssistantMessageEvent(data: {'id': 'a1', 'content': 'done'}));
      await pumpEventQueue();
      connectivity.setOnline(false);
      await pumpEventQueue();
      await controller().send('two');
      await pumpEventQueue();
      await controller().cancelQueued(state().messages.last.id);
      await pumpEventQueue();
      expect(state().messages.where((m) => m.isQueued), isEmpty);
      expect(container.read(sendQueueProvider).isEmpty, isTrue);
    });

    test('queued sends persisted by an earlier run are shown when the chat opens', () async {
      store = MemoryLocalStore();
      await store.write('sendqueue:anon:personal', {
        'items': [
          QueuedSend(
            key: 'old-key',
            sessionId: session,
            content: 'from last time',
            createdAt: DateTime.utc(2026),
            failed: true,
            lastError: 'gave up',
          ).toJson(),
          QueuedSend(
            key: 'other-chat',
            sessionId: 'other',
            content: 'elsewhere',
            createdAt: DateTime.utc(2026),
            failed: true,
          ).toJson(),
        ],
      });
      await setUpContainer();
      final bubble = state().messages.single;
      expect(bubble.id, 'pending-user-old-key');
      expect(bubble.content, 'from last time');
      expect(bubble.delivery, MessageDelivery.failed);
      expect(bubble.deliveryError, 'gave up');
    });

    test('a reconnect resyncs the history and re-attaches to a running generation', () async {
      repo.history = [userMessage('u1', 'before')];
      await setUpContainer();
      repo.history = [
        userMessage('u1', 'before'),
        assistantFrom({'id': 'a1', 'content': 'reply'}),
      ];
      repo.activeGen = const ActiveGeneration(generationId: 'g9', status: 'running');
      container.read(reconnectTickProvider.notifier).state++;
      await pumpEventQueue();
      expect(repo.historyCalls, 2);
      expect(state().messages.map((m) => m.id), containsAll(['u1', 'a1']));
      expect(repo.resumeCalls.single.generationId, 'g9');
      expect(state().sending, isTrue);
    });

    test('a finished turn is written to the cache', () async {
      await setUpContainer();
      final turn = await send('hello');
      await emit(turn, const AssistantMessageEvent(data: {'id': 'a1', 'content': 'world'}));
      await pumpEventQueue();
      final stored = await store.read(ChatCache.messagesKey('anon:personal', session));
      final items = (stored!['items'] as List).cast<Map>();
      expect(items.map((m) => m['id']), ['a1'], reason: 'the optimistic bubble is not persisted');
    });
  });
}
