import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/api_exception.dart';
import '../../core/connectivity.dart';
import '../../core/preferences.dart';
import '../../core/sync.dart';
import '../attachments/attachment_model.dart';
import '../attachments/attachments_repository.dart';
import '../tools/tools_repository.dart';
import '../usage/usage_model.dart';
import '../usage/usage_repository.dart';
import '../voice/audio_player_service.dart';
import '../voice/recorder.dart';
import '../voice/voice_repository.dart';
import 'chat_cache.dart';
import 'chat_models.dart';
import 'chat_repository.dart';
import 'send_queue.dart';

/// Live state for a single chat screen.
class ChatState {
  const ChatState({
    required this.messages,
    required this.sending,
    this.stopping = false,
    this.switchingBranch = false,
    this.useRag = true,
    this.useTools = true,
    this.error,
    this.session,
    this.modelOverride,
    this.collectionIds,
    this.toolNames,
    this.pendingAttachments = const [],
    this.uploading = 0,
    this.playingMessageId,
    this.nextCursor,
    this.loadingOlder = false,
    this.fromCache = false,
    this.loaded = false,
  });

  final List<ChatMessage> messages;

  /// A turn is in flight (request sent, final message not yet received).
  final bool sending;

  /// Stop was requested and we are waiting for the server's final message.
  final bool stopping;

  /// A sibling switch (`/siblings` + `/branch`) is in flight.
  final bool switchingBranch;
  final bool useRag;
  final bool useTools;

  /// Why the last turn could not run; shown above the composer.
  final ChatError? error;

  /// `GET /sessions/{id}` — carries the session model, assistant and
  /// metadata. Null until loaded (or when the fetch failed; the header then
  /// falls back to the session list).
  final ChatSession? session;

  /// Model picked in the composer chip; sent as `model` on every turn until
  /// cleared. Null = the session's model / the user's default.
  final String? modelOverride;

  /// Knowledge scope (`collection_ids`) sent on each turn — mirrors
  /// `session.meta.collection_ids`. Null = all of the user's documents.
  final List<String>? collectionIds;

  /// Tools picked for this chat (persisted per session on this device).
  /// Null = the default selection, see [ChatController.effectiveToolNames].
  final List<String>? toolNames;

  /// Uploads waiting in the composer; their ids go out as `attachment_ids`
  /// with the next send and the list is cleared once the turn is accepted.
  final List<Attachment> pendingAttachments;

  /// Uploads in flight.
  final int uploading;

  /// The reply whose spoken version is playing (its `meta.audio`).
  final String? playingMessageId;

  /// Cursor of the history page before the oldest loaded message; null when
  /// the beginning of the chat is loaded (or unknown).
  final String? nextCursor;

  /// `GET …/messages?cursor=` is in flight.
  final bool loadingOlder;

  /// The messages come from the device cache; the network refresh has not
  /// replaced them yet (or could not — offline).
  final bool fromCache;

  /// The first load (cache or network) finished.
  final bool loaded;

  /// Whether older messages can be fetched.
  bool get hasOlder => nextCursor != null;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? sending,
    bool? stopping,
    bool? switchingBranch,
    bool? useRag,
    bool? useTools,
    ChatError? error,
    bool clearError = false,
    ChatSession? session,
    String? modelOverride,
    bool clearModelOverride = false,
    List<String>? collectionIds,
    bool clearCollectionIds = false,
    List<String>? toolNames,
    bool clearToolNames = false,
    List<Attachment>? pendingAttachments,
    int? uploading,
    String? playingMessageId,
    bool clearPlaying = false,
    String? nextCursor,
    bool clearNextCursor = false,
    bool? loadingOlder,
    bool? fromCache,
    bool? loaded,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        sending: sending ?? this.sending,
        stopping: stopping ?? this.stopping,
        switchingBranch: switchingBranch ?? this.switchingBranch,
        useRag: useRag ?? this.useRag,
        useTools: useTools ?? this.useTools,
        error: clearError ? null : (error ?? this.error),
        session: session ?? this.session,
        modelOverride: clearModelOverride ? null : (modelOverride ?? this.modelOverride),
        collectionIds: clearCollectionIds ? null : (collectionIds ?? this.collectionIds),
        toolNames: clearToolNames ? null : (toolNames ?? this.toolNames),
        pendingAttachments: pendingAttachments ?? this.pendingAttachments,
        uploading: uploading ?? this.uploading,
        playingMessageId: clearPlaying ? null : (playingMessageId ?? this.playingMessageId),
        nextCursor: clearNextCursor ? null : (nextCursor ?? this.nextCursor),
        loadingOlder: loadingOlder ?? this.loadingOlder,
        fromCache: fromCache ?? this.fromCache,
        loaded: loaded ?? this.loaded,
      );

  static const empty = ChatState(messages: [], sending: false);
}

/// Lines the history up with the authoritative pending list
/// (`GET /sessions/{id}/approvals?status=pending`):
///
/// * a pending approval whose message is in the list is attached to it (and
///   the message is flagged `awaiting_approval`) — covers history rows that
///   lost their `meta.approval`;
/// * a message whose approval is *not* pending any more loses its buttons:
///   it is marked `expired` when past `expires_at`, `resolved` otherwise.
List<ChatMessage> reconcileApprovals(
  List<ChatMessage> messages,
  List<ApprovalRequest> pending, {
  DateTime? now,
}) {
  final byMessage = {for (final a in pending) a.messageId: a};
  final pendingIds = {for (final a in pending) a.approvalId};
  final clock = now ?? DateTime.now();
  return [
    for (final m in messages)
      if (m.role != MessageRole.assistant)
        m
      else if (byMessage[m.id] case final a?)
        m.copyWith(approval: a.copyWith(status: 'pending'), status: MessageStatus.awaitingApproval)
      else if (m.approval case final a? when a.isPending && !pendingIds.contains(a.approvalId))
        m.copyWith(
          approval: a.copyWith(
            status: a.expiresAt != null && a.expiresAt!.isBefore(clock) ? 'expired' : 'resolved',
          ),
        )
      else
        m,
  ];
}

/// Mutable bookkeeping for one streamed turn: which bubble the events land
/// in, the accumulated text, the tool runs seen so far and what is needed to
/// resume it after a dropped connection.
class _TurnContext {
  _TurnContext({
    required this.targetId,
    String initialText = '',
    List<ToolCall> tools = const [],
    List<Attachment> artifacts = const [],
    this.approval,
    this.generationId,
    this.idempotencyKey,
    this.restoreOnFailure,
  })  : buffer = StringBuffer(initialText),
        tools = List.of(tools),
        artifacts = List.of(artifacts);

  /// Id of the message the events are applied to (the streaming
  /// placeholder, or the persisted placeholder of an approval continuation).
  final String targetId;
  final StringBuffer buffer;
  List<ToolCall> tools;

  /// Files announced by `artifact` frames so far.
  List<Attachment> artifacts;

  /// Set when this turn continues a paused one; restored on failure so the
  /// user can try again.
  final ApprovalRequest? approval;

  /// The server-side generation, once known (from `user_message`, or up front
  /// when attaching to a running / background generation).
  String? generationId;

  /// `Idempotency-Key` of the send attempt that started this turn.
  final String? idempotencyKey;

  /// The message list to put back when an edit fails before it streams.
  final List<ChatMessage>? restoreOnFailure;

  /// Whether the one allowed reconnect has been used.
  bool resumed = false;

  bool get isApprovalContinuation => approval != null;
}

/// Reducer over [StreamEvent]s for one session.
///
/// Appends `token`s to a live buffer, attaches `citations` / `tool_call`s as
/// they arrive, swaps the optimistic user bubble for the persisted
/// `user_message`, and replaces the streaming placeholder with the canonical
/// `assistant_message` when the turn completes. An `approval_required` turn
/// ends with the card attached to the bubble; resolving it streams the
/// continuation into that same bubble (matched on the message id).
///
/// Phase 3: every send carries an `Idempotency-Key`; a dropped connection is
/// reconnected once through the generation's event replay (continuing the
/// same bubble); a chat that opens while a generation is running attaches to
/// it; edits stream into a new branch; sibling switches swap the whole
/// branch; a `quota_exceeded` refusal raises the app-wide quota banner.
///
/// Phase 4: uploads wait in [ChatState.pendingAttachments] and go out as
/// `attachment_ids`; `artifact` frames attach files to the bubble; a voice
/// turn (`/messages/voice`) is attached like a background send; `audio_chunk`
/// frames play through the [AudioPlayerService]; a push notification's
/// generation is attached through [attachToGeneration].
///
/// Offline-first: the chat opens from the device cache and refreshes from
/// the network (cursor pagination for older history, [loadOlder]); a send
/// that cannot reach the server stays as a queued bubble and is replayed by
/// the [SendQueue] with the same `Idempotency-Key`; a reconnect
/// ([reconnectTickProvider]) resyncs the history and re-attaches to a
/// running generation.
class ChatController extends StateNotifier<ChatState> {
  ChatController(this._ref, this.sessionId) : super(ChatState.empty) {
    final prefs = _ref.read(prefsProvider);
    state = state.copyWith(
      useRag: prefs.ragByDefault,
      useTools: prefs.toolsByDefault,
      toolNames: _ref.read(sessionPrefsProvider).toolNames(sessionId),
    );
    _queueSub = _ref.read(sendQueueProvider.notifier).events.listen(_onQueueEvent);
    _ref.listen<int>(reconnectTickProvider, (_, __) => unawaited(_resync()));
    _initialLoad = _load();
  }

  /// After a WebSocket `stop`, how long to wait for the server's final
  /// `assistant_message` before finalising the bubble locally.
  static const stopGracePeriod = Duration(seconds: 8);

  /// Messages per history page (`limit=`).
  static const pageSize = 50;

  /// Text of the optimistic bubble while a voice clip is transcribed.
  static const voicePlaceholderText = ChatMessage.voicePlaceholderText;

  static const _uuid = Uuid();

  final Ref _ref;
  final String sessionId;

  ChatTurn? _turn;
  StreamSubscription<StreamEvent>? _sub;
  _TurnContext? _ctx;
  Timer? _stopTimeout;
  bool _stopRequested = false;
  late final Future<void> _initialLoad;
  StreamSubscription<bool>? _playerSub;
  StreamSubscription<SendQueueEvent>? _queueSub;

  // ---- Loading, cache, pagination ----

  String get _scope => _ref.read(cacheScopeProvider);
  ChatCache get _cache => _ref.read(chatCacheProvider);
  SendQueue get _queue => _ref.read(sendQueueProvider.notifier);

  /// The queued / failed sends of this chat, as bubbles.
  List<ChatMessage> _queuedBubbles() => [
        for (final q in _ref.read(sendQueueProvider).forSession(sessionId)) q.toMessage(),
      ];

  Future<void> _load() async {
    // Sends persisted by an earlier run must be on screen from the first frame.
    await _queue.ready;
    final cached = await _readCache();
    if (!mounted) return;
    if (cached != null) {
      state = state.copyWith(
        messages: [...cached.messages, ..._queuedBubbles()],
        nextCursor: cached.nextCursor,
        clearNextCursor: cached.nextCursor == null,
        fromCache: true,
        loaded: true,
      );
    }

    final ChatRepository repo;
    try {
      repo = await _ref.read(chatRepositoryProvider.future);
      final page = await repo.loadHistoryPage(sessionId, limit: pageSize);
      if (!mounted) return;
      state = state.copyWith(
        messages: [...page.items, ..._queuedBubbles()],
        nextCursor: page.nextCursor,
        clearNextCursor: page.nextCursor == null,
        fromCache: false,
        loaded: true,
      );
      _persistCache();
    } catch (e) {
      if (!mounted) return;
      // With a cached copy on screen the failure is just "offline".
      if (cached == null) {
        state = state.copyWith(
          error: ChatError.exception(e),
          loaded: true,
          messages: _queuedBubbles(),
        );
      }
      return;
    }
    await _loadSession(repo);
    await _reconcileApprovals(repo);
    await _attachToActiveGeneration(repo);
  }

  Future<CachedHistory?> _readCache() async {
    try {
      return await _cache.readMessages(_scope, sessionId);
    } catch (_) {
      return null;
    }
  }

  /// Stores the newest persisted messages (never queued or streaming rows).
  void _persistCache() {
    if (!mounted) return;
    unawaited(
      _cache
          .writeMessages(_scope, sessionId, state.messages, nextCursor: state.nextCursor)
          .catchError((Object _) {}),
    );
  }

  /// Fetches the page before the oldest loaded message and prepends it.
  Future<void> loadOlder() async {
    final cursor = state.nextCursor;
    if (cursor == null || state.loadingOlder) return;
    state = state.copyWith(loadingOlder: true);
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final page = await repo.loadHistoryPage(sessionId, cursor: cursor, limit: pageSize);
      if (!mounted) return;
      final known = {for (final m in state.messages) m.id};
      final older = [
        for (final m in page.items)
          if (!known.contains(m.id)) m,
      ];
      state = state.copyWith(
        messages: [...older, ...state.messages],
        nextCursor: page.nextCursor,
        clearNextCursor: page.nextCursor == null,
        loadingOlder: false,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(loadingOlder: false, error: ChatError.exception(e));
    }
  }

  /// Back online: refresh the history, the approvals and re-attach to a
  /// generation that may have run meanwhile. Skipped while a turn streams.
  Future<void> _resync() async {
    if (!mounted || state.sending) return;
    final ChatRepository repo;
    try {
      repo = await _ref.read(chatRepositoryProvider.future);
      final page = await repo.loadHistoryPage(sessionId, limit: pageSize);
      if (!mounted || state.sending) return;
      state = state.copyWith(
        messages: [...page.items, ..._queuedBubbles()],
        nextCursor: page.nextCursor,
        clearNextCursor: page.nextCursor == null,
        fromCache: false,
        loaded: true,
        clearError: true,
      );
      _persistCache();
    } catch (_) {
      return; // Still unreachable; the next reconnect tries again.
    }
    await _loadSession(repo);
    await _reconcileApprovals(repo);
    await _attachToActiveGeneration(repo);
  }

  Future<void> _loadSession(ChatRepository repo) async {
    try {
      final session = await repo.getSession(sessionId);
      if (!mounted) return;
      final ids = session.collectionIds;
      state = state.copyWith(session: session, collectionIds: ids, clearCollectionIds: ids == null);
    } catch (_) {
      // Non-fatal: the header falls back to the session list and the
      // knowledge scope stays "all documents".
    }
  }

  Future<void> _reconcileApprovals(ChatRepository repo) async {
    final List<ApprovalRequest> pending;
    try {
      pending = await repo.listPendingApprovals(sessionId);
    } catch (_) {
      return; // `meta.approval` on the history rows is the best we have.
    }
    if (!mounted) return;
    state = state.copyWith(messages: reconcileApprovals(state.messages, pending));
  }

  /// `GET /sessions/{id}/generations/active`: a turn started elsewhere (a
  /// background send, another device, a chat left mid-reply) is still
  /// running — stream it into a bubble for its user message.
  Future<void> _attachToActiveGeneration(ChatRepository repo) async {
    if (state.sending) return;
    final ActiveGeneration? active;
    try {
      active = await repo.activeGeneration(sessionId);
    } catch (_) {
      return; // Older server / transient failure: nothing to attach to.
    }
    if (active == null || !active.isRunning || !mounted || state.sending) return;
    await _attach(repo, active.generationId);
  }

  /// Opens the event replay of [generationId] from its first frame into a
  /// fresh streaming bubble.
  Future<void> _attach(ChatRepository repo, String generationId) async {
    final placeholder =
        ChatMessage.streamingPlaceholder(sessionId: sessionId).copyWith(generationId: generationId);
    _stopRequested = false;
    state = state.copyWith(
      sending: true,
      stopping: false,
      clearError: true,
      messages: [...state.messages, placeholder],
    );
    try {
      final turn = await repo.resumeGeneration(sessionId, generationId);
      if (!mounted) {
        await turn.close();
        return;
      }
      _listen(turn, _TurnContext(targetId: placeholder.id, generationId: generationId));
    } catch (e) {
      if (!mounted) return;
      _dropEmptyStreaming(placeholder.id);
      _failTurn(e);
    }
  }

  /// Attaches to [generationId] — the one a `generation_done` push
  /// notification names. No-op when the chat is already streaming or the
  /// reply is in the history; a generation that is gone (404) falls back to
  /// a history reload.
  Future<void> attachToGeneration(String generationId) async {
    await _initialLoad;
    if (!mounted || state.sending) return;
    final known = state.messages.any(
      (m) => m.role == MessageRole.assistant && m.generationId == generationId && !m.streaming,
    );
    if (known) return;
    final placeholder =
        ChatMessage.streamingPlaceholder(sessionId: sessionId).copyWith(generationId: generationId);
    _stopRequested = false;
    state = state.copyWith(
      sending: true,
      stopping: false,
      clearError: true,
      messages: [...state.messages, placeholder],
    );
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final turn = await repo.resumeGeneration(sessionId, generationId);
      if (!mounted) {
        await turn.close();
        return;
      }
      _listen(turn, _TurnContext(targetId: placeholder.id, generationId: generationId));
    } catch (e) {
      if (!mounted) return;
      _dropEmptyStreaming(placeholder.id);
      if (e is ApiException && e.isNotFound) {
        // Expired replay: the persisted reply is in the history by now.
        state = state.copyWith(sending: false, stopping: false);
        await reload();
        return;
      }
      _failTurn(e);
    }
  }

  /// Re-fetches history, session and pending approvals (drops any in-flight turn).
  Future<void> reload() async {
    await _closeTurn();
    _ctx = null;
    if (!mounted) return;
    state = state.copyWith(sending: false, stopping: false, switchingBranch: false);
    await _load();
  }

  void toggleRag(bool v) => state = state.copyWith(useRag: v);
  void toggleTools(bool v) => state = state.copyWith(useTools: v);

  // ---- Send queue ----

  /// Whether a request can be attempted right now.
  Future<bool> _isOnline() async {
    try {
      return await _ref.read(connectivityServiceProvider).checkOnline();
    } catch (_) {
      return true;
    }
  }

  /// Parks a send in the queue: the optimistic bubble becomes "queued", the
  /// streaming placeholder goes away and the composer is free again.
  Future<void> _enqueueSend(QueuedSend send, {required String placeholderId}) async {
    _dropEmptyStreaming(placeholderId);
    final bubble = send.toMessage();
    if (!_replaceById(bubble.id, (_) => bubble)) {
      state = state.copyWith(messages: [...state.messages, bubble]);
    }
    state = state.copyWith(sending: false, stopping: false, clearError: true);
    await _queue.enqueue(send);
  }

  void _onQueueEvent(SendQueueEvent event) {
    if (!mounted || event.item.sessionId != sessionId) return;
    final bubbleId = event.item.bubbleId;
    switch (event) {
      case SendAccepted(:final accepted):
        final persisted = accepted.userMessage;
        _replaceById(
          bubbleId,
          (m) => persisted ?? m.copyWith(delivery: MessageDelivery.sent, clearDeliveryError: true),
        );
        if (accepted.generationId.isNotEmpty && !state.sending) {
          unawaited(_attachAccepted(accepted.generationId));
        }
      case SendFailed():
        final bubble = event.item.toMessage();
        _replaceById(bubbleId, (_) => bubble);
      case SendCancelled():
        _dropPendingUser(bubbleId);
    }
  }

  Future<void> _attachAccepted(String generationId) async {
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      if (!mounted || state.sending) return;
      await _attach(repo, generationId);
    } catch (_) {
      // The next resync picks the reply up from the history.
    }
  }

  /// Replays a parked send now (its "Retry" button).
  Future<void> retryQueued(String bubbleId) => _queue.retry(_keyOf(bubbleId));

  /// Drops a queued / parked send (its "Cancel" button).
  Future<void> cancelQueued(String bubbleId) => _queue.cancel(_keyOf(bubbleId));

  static String _keyOf(String bubbleId) => bubbleId.startsWith(ChatMessage.pendingUserPrefix)
      ? bubbleId.substring(ChatMessage.pendingUserPrefix.length)
      : bubbleId;

  // ---- Attachments ----

  /// Uploads [bytes] to this session (`POST /sessions/{id}/attachments`) and
  /// parks the result in the composer. Returns the attachment, or null when
  /// the upload was refused (the error is shown in the chat).
  Future<Attachment?> attachFile({required Uint8List bytes, required String filename}) async {
    state = state.copyWith(uploading: state.uploading + 1, clearError: true);
    try {
      final repo = await _ref.read(attachmentsRepositoryProvider.future);
      final attachment = await repo.upload(sessionId: sessionId, bytes: bytes, filename: filename);
      if (!mounted) return null;
      state = state.copyWith(pendingAttachments: [...state.pendingAttachments, attachment]);
      return attachment;
    } catch (e) {
      if (!mounted) return null;
      state = state.copyWith(error: ChatError.exception(e));
      return null;
    } finally {
      if (mounted) state = state.copyWith(uploading: state.uploading - 1);
    }
  }

  /// Drops a pending attachment from the composer and deletes it server-side
  /// (best effort — an unbound upload is garbage either way).
  Future<void> removeAttachment(String attachmentId) async {
    state = state.copyWith(
      pendingAttachments: state.pendingAttachments.where((a) => a.id != attachmentId).toList(),
    );
    try {
      final repo = await _ref.read(attachmentsRepositoryProvider.future);
      await repo.delete(sessionId, attachmentId);
    } catch (_) {
      // Already gone or unreachable; nothing to show.
    }
  }

  /// Whether the composer holds images (they need a vision model).
  bool get hasPendingImages => state.pendingAttachments.any((a) => a.isImage);

  List<String>? get _pendingAttachmentIds =>
      state.pendingAttachments.isEmpty ? null : state.pendingAttachments.map((a) => a.id).toList();

  /// Spoken-reply options for typed sends, from the "Speak replies" setting.
  VoiceReply? get _voiceReply {
    final prefs = _ref.read(prefsProvider);
    return prefs.speakReplies ? VoiceReply(voice: prefs.voice) : null;
  }

  // ---- Spoken replies ----

  AudioPlayerService get _player {
    final player = _ref.read(audioPlayerProvider);
    _playerSub ??= player.playingStream.listen((playing) {
      if (!playing && mounted && state.playingMessageId != null) {
        state = state.copyWith(clearPlaying: true);
      }
    });
    return player;
  }

  /// Plays (or stops) the stored spoken version of a reply (`meta.audio`).
  Future<void> playMessageAudio(ChatMessage message) async {
    final audio = message.audio;
    if (audio == null || !audio.isPlayable) return;
    if (state.playingMessageId == message.id) {
      await stopAudio();
      return;
    }
    state = state.copyWith(playingMessageId: message.id, clearError: true);
    try {
      final loader = _ref.read(attachmentContentLoaderProvider);
      final content = await loader.load(audio.url);
      if (!mounted || state.playingMessageId != message.id) return;
      await _player.play(AudioClip(bytes: content.bytes, mimeType: content.mimeType));
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(clearPlaying: true, error: ChatError.exception(e));
    }
  }

  Future<void> stopAudio() async {
    state = state.copyWith(clearPlaying: true);
    await _player.stop();
  }

  /// Per-turn model override (null = session / default model).
  void setModelOverride(String? modelId) =>
      state = state.copyWith(modelOverride: modelId, clearModelOverride: modelId == null);

  /// The chat's tool selection; persisted per session on this device.
  Future<void> setToolNames(List<String>? names) async {
    state = state.copyWith(toolNames: names, clearToolNames: names == null);
    await _ref.read(sessionPrefsProvider).setToolNames(sessionId, names);
  }

  /// `tool_names` for the next turn: the picker's selection (filtered to
  /// tools the server still lists), else the default — every tool that runs
  /// without approval. Null when tools are off or the catalog is unknown /
  /// empty (the server then applies its own default).
  List<String>? get effectiveToolNames {
    if (!state.useTools) return null;
    final catalog = _ref.read(toolCatalogProvider).valueOrNull;
    final picked = state.toolNames;
    if (catalog == null) return picked;
    if (catalog.isEmpty) return null;
    final known = {for (final t in catalog) t.name};
    if (picked != null) return picked.where(known.contains).toList();
    return defaultToolSelection(catalog);
  }

  /// Switches the session's model (`PATCH /sessions/{id} {model}`).
  Future<void> setSessionModel(String modelId) async {
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final updated = await repo.updateSession(sessionId, model: modelId);
      if (!mounted) return;
      state = state.copyWith(session: updated, clearError: true);
      _ref.invalidate(sessionListProvider);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(error: ChatError.exception(e));
    }
  }

  /// Switches the session's assistant (`PATCH /sessions/{id} {assistant_id}`);
  /// null makes it a plain chat again.
  Future<void> setAssistant(String? assistantId) async {
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final updated = await repo.updateSession(
        sessionId,
        assistantId: assistantId,
        clearAssistantId: assistantId == null,
      );
      if (!mounted) return;
      state = state.copyWith(session: updated, clearError: true);
      _ref.invalidate(sessionListProvider);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(error: ChatError.exception(e));
    }
  }

  /// Sets the chat's knowledge scope: saved as the session default
  /// (`PATCH /sessions/{id} {"meta": {"collection_ids": [...]}}`) and sent
  /// as `collection_ids` on each turn. Null = all documents.
  Future<void> setCollectionIds(List<String>? ids) async {
    final previous = state.collectionIds;
    state = state.copyWith(collectionIds: ids, clearCollectionIds: ids == null, clearError: true);
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final meta = <String, dynamic>{...?state.session?.meta, 'collection_ids': ids};
      final updated = await repo.updateSession(sessionId, meta: meta);
      if (!mounted) return;
      state = state.copyWith(session: updated);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        collectionIds: previous,
        clearCollectionIds: previous == null,
        error: ChatError.exception(e),
      );
    }
  }

  /// Stop the in-flight generation (the composer's stop button).
  ///
  /// * WebSocket: sends `stop` and keeps listening — the server persists the
  ///   partial text and emits `assistant_message` with `interrupted: true`,
  ///   which completes the turn like any other. A grace period guards
  ///   against a server that never answers.
  /// * SSE: asks the server to stop the generation (stop endpoint, when its
  ///   id is known), closes the connection and marks the bubble as stopped
  ///   with the text we have; the server persists the same partial reply.
  ///   Disconnecting alone would let the server finish the reply.
  Future<void> stop() async {
    if (!state.sending) return;
    final turn = _turn;
    if (turn == null) {
      // Still connecting; the stop is applied as soon as the turn opens.
      _stopRequested = true;
      return;
    }
    switch (turn.transport) {
      case StreamTransport.websocket:
        if (state.stopping) return;
        state = state.copyWith(stopping: true);
        await turn.stop();
        _stopTimeout = Timer(stopGracePeriod, _finishInterruptedLocally);
      case StreamTransport.sse:
        await _closeTurn();
        _finishInterruptedLocally();
    }
  }

  /// A fresh `Idempotency-Key` for one send attempt. Dio's transparent 401
  /// retry resends the same request options, so the key is reused there.
  static String newIdempotencyKey() => _uuid.v4();

  /// The optimistic bubble of a send; its id carries the send's
  /// `Idempotency-Key` so a queued replay maps back to it.
  ChatMessage _optimisticUser(
    String content, {
    required String key,
    String? parentId,
    List<Attachment> attachments = const [],
  }) =>
      ChatMessage(
        id: QueuedSend.bubbleIdFor(key),
        sessionId: sessionId,
        role: MessageRole.user,
        content: content,
        createdAt: DateTime.now(),
        parentId: parentId,
        attachments: attachments,
      );

  /// The composer's uploads are bound to the turn that was just accepted.
  void _consumePendingAttachments() {
    if (state.pendingAttachments.isNotEmpty) state = state.copyWith(pendingAttachments: const []);
  }

  Future<void> send(String content) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty || state.sending) return;
    _stopRequested = false;

    // Optimistically append the user message + a streaming placeholder.
    final key = newIdempotencyKey();
    final attachments = state.pendingAttachments;
    final optimisticUser = _optimisticUser(trimmed, key: key, attachments: attachments);
    final placeholder = ChatMessage.streamingPlaceholder(sessionId: sessionId);
    state = state.copyWith(
      sending: true,
      stopping: false,
      clearError: true,
      messages: [...state.messages, optimisticUser, placeholder],
    );

    final toolNames = effectiveToolNames;
    final model = state.modelOverride;
    final collectionIds = state.collectionIds;
    final attachmentIds = _pendingAttachmentIds;
    final voiceReply = _voiceReply;
    final queued = QueuedSend(
      key: key,
      sessionId: sessionId,
      content: trimmed,
      createdAt: optimisticUser.createdAt,
      attachments: attachments,
      useRag: state.useRag,
      useTools: state.useTools,
      toolNames: toolNames,
      model: model,
      collectionIds: collectionIds,
      voiceReply: voiceReply,
    );

    if (!await _isOnline()) {
      if (!mounted) return;
      _consumePendingAttachments();
      await _enqueueSend(queued, placeholderId: placeholder.id);
      return;
    }

    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final prefs = _ref.read(prefsProvider);

      // Non-streaming path — fall through to the regular POST endpoint.
      if (!prefs.streamingEnabled) {
        final assistant = await repo.sendBlocking(
          sessionId: sessionId,
          content: trimmed,
          useRag: state.useRag,
          useTools: state.useTools,
          toolNames: toolNames,
          model: model,
          collectionIds: collectionIds,
          idempotencyKey: key,
          attachmentIds: attachmentIds,
          voiceReply: voiceReply,
        );
        if (!mounted) return;
        _consumePendingAttachments();
        _finishBlockingTurn(placeholder.id, assistant);
        return;
      }

      final turn = await repo.streamMessage(
        sessionId: sessionId,
        content: trimmed,
        transport: prefs.transport,
        useRag: state.useRag,
        useTools: state.useTools,
        toolNames: toolNames,
        model: model,
        collectionIds: collectionIds,
        idempotencyKey: key,
        attachmentIds: attachmentIds,
        voiceReply: voiceReply,
      );
      if (!mounted) {
        await turn.close();
        return;
      }
      _consumePendingAttachments();
      _listen(turn, _TurnContext(targetId: placeholder.id, idempotencyKey: key));

      if (_stopRequested) {
        _stopRequested = false;
        await stop();
      }
    } catch (e) {
      if (!mounted) return;
      if (_shouldQueue(e)) {
        // The server was never reached (or never answered): the queue
        // replays the same key once the connection is back.
        _consumePendingAttachments();
        await _enqueueSend(queued, placeholderId: placeholder.id);
        return;
      }
      // The uploads stay in the composer so the send can be retried (e.g.
      // after switching to a vision model).
      _dropEmptyStreaming(placeholder.id);
      _failTurn(e);
    }
  }

  /// A transport-level failure before the turn opened (no network, a
  /// timeout, a server error) goes to the queue; a refusal does not.
  static bool _shouldQueue(Object e) =>
      e is ApiException && e.isTransient && !e.isBusy && !e.isRateLimited;

  /// Voice mode: `POST /sessions/{id}/messages/voice` transcribes [clip] and
  /// starts the turn in the background (202). The transcript becomes the user
  /// bubble, with the clip as an `audio` attachment, and the reply is
  /// attached through the generation's event replay — `audio_chunk` frames
  /// play as they arrive. Voice turns always ask for a spoken reply (the
  /// server skips it when it has no text-to-speech).
  Future<void> sendVoice(RecordedClip clip) async {
    if (clip.isEmpty || state.sending) return;
    _stopRequested = false;

    final key = newIdempotencyKey();
    final optimisticUser = _optimisticUser(voicePlaceholderText, key: key);
    final placeholder = ChatMessage.streamingPlaceholder(sessionId: sessionId);
    state = state.copyWith(
      sending: true,
      stopping: false,
      clearError: true,
      messages: [...state.messages, optimisticUser, placeholder],
    );

    try {
      final voiceRepo = await _ref.read(voiceRepositoryProvider.future);
      final prefs = _ref.read(prefsProvider);
      final accepted = await voiceRepo.sendVoiceTurn(
        sessionId: sessionId,
        bytes: clip.bytes,
        filename: clip.filename,
        useRag: state.useRag,
        useTools: state.useTools,
        model: state.modelOverride,
        voice: prefs.voice,
        idempotencyKey: key,
      );
      if (!mounted) return;

      final attachmentId = accepted.attachmentId;
      final user = ChatMessage(
        id: accepted.userMessageId.isEmpty ? optimisticUser.id : accepted.userMessageId,
        sessionId: sessionId,
        role: MessageRole.user,
        content: accepted.transcript,
        createdAt: optimisticUser.createdAt,
        generationId: accepted.generationId,
        attachments: [
          if (attachmentId != null && attachmentId.isNotEmpty)
            Attachment(
              id: attachmentId,
              kind: AttachmentKind.audio,
              name: clip.filename,
              mimeType: clip.mimeType,
              sizeBytes: clip.bytes.length,
              url: '/api/v1/sessions/$sessionId/attachments/$attachmentId/content',
              hasText: true,
            ),
        ],
      );
      _replaceById(optimisticUser.id, (_) => user);
      _replaceById(placeholder.id, (m) => m.copyWith(generationId: accepted.generationId));

      final repo = await _ref.read(chatRepositoryProvider.future);
      final turn = await repo.resumeGeneration(sessionId, accepted.generationId);
      if (!mounted) {
        await turn.close();
        return;
      }
      _listen(
        turn,
        _TurnContext(
          targetId: placeholder.id,
          generationId: accepted.generationId,
          idempotencyKey: key,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _dropEmptyStreaming(placeholder.id);
      // Nothing was transcribed: drop the optimistic bubble too.
      _dropPendingUser(optimisticUser.id);
      _failTurn(e);
    }
  }

  void _dropPendingUser(String id) {
    final msgs = state.messages;
    final i = msgs.indexWhere((m) => m.id == id && m.isPendingUser);
    if (i < 0) return;
    state = state.copyWith(messages: [...msgs.sublist(0, i), ...msgs.sublist(i + 1)]);
  }

  /// `POST /sessions/{id}/messages/background`: the server produces the reply
  /// even if this client goes away; the chat attaches to the generation's
  /// event replay right away (and again on the next open if it is still running).
  Future<void> sendInBackground(String content) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty || state.sending) return;
    _stopRequested = false;

    final key = newIdempotencyKey();
    final attachments = state.pendingAttachments;
    final optimisticUser = _optimisticUser(trimmed, key: key, attachments: attachments);
    final placeholder = ChatMessage.streamingPlaceholder(sessionId: sessionId);
    state = state.copyWith(
      sending: true,
      stopping: false,
      clearError: true,
      messages: [...state.messages, optimisticUser, placeholder],
    );
    final queued = QueuedSend(
      key: key,
      sessionId: sessionId,
      content: trimmed,
      createdAt: optimisticUser.createdAt,
      attachments: attachments,
      useRag: state.useRag,
      useTools: state.useTools,
      toolNames: effectiveToolNames,
      model: state.modelOverride,
      collectionIds: state.collectionIds,
      voiceReply: _voiceReply,
    );

    if (!await _isOnline()) {
      if (!mounted) return;
      _consumePendingAttachments();
      await _enqueueSend(queued, placeholderId: placeholder.id);
      return;
    }

    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final accepted = await repo.sendBackground(
        sessionId: sessionId,
        content: trimmed,
        useRag: queued.useRag,
        useTools: queued.useTools,
        toolNames: queued.toolNames,
        model: queued.model,
        collectionIds: queued.collectionIds,
        idempotencyKey: key,
        attachmentIds: queued.attachmentIds,
        voiceReply: queued.voiceReply,
      );
      if (!mounted) return;
      _consumePendingAttachments();
      final user = accepted.userMessage;
      if (user != null) _replaceById(optimisticUser.id, (_) => user);
      _replaceById(placeholder.id, (m) => m.copyWith(generationId: accepted.generationId));

      final turn = await repo.resumeGeneration(sessionId, accepted.generationId);
      if (!mounted) {
        await turn.close();
        return;
      }
      _listen(
        turn,
        _TurnContext(
          targetId: placeholder.id,
          generationId: accepted.generationId,
          idempotencyKey: key,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      if (_shouldQueue(e)) {
        _consumePendingAttachments();
        await _enqueueSend(queued, placeholderId: placeholder.id);
        return;
      }
      _dropEmptyStreaming(placeholder.id);
      _failTurn(e);
    }
  }

  /// Edits a user message: the new text becomes a sibling of [messageId]
  /// (same parent), the reply streams into a new bubble and the messages
  /// after the edited one disappear — the branch changed.
  Future<void> editMessage(String messageId, String content) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty || state.sending) return;
    final i = state.messages.indexWhere((m) => m.id == messageId);
    if (i < 0 || state.messages[i].role != MessageRole.user) return;
    _stopRequested = false;

    final snapshot = state.messages;
    final original = snapshot[i];
    final key = newIdempotencyKey();
    final optimisticUser = _optimisticUser(
      trimmed,
      key: key,
      parentId: original.parentId,
      attachments: state.pendingAttachments,
    );
    final placeholder = ChatMessage.streamingPlaceholder(sessionId: sessionId);
    state = state.copyWith(
      sending: true,
      stopping: false,
      clearError: true,
      messages: [...snapshot.sublist(0, i), optimisticUser, placeholder],
    );

    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final turn = await repo.editMessage(
        sessionId: sessionId,
        messageId: messageId,
        content: trimmed,
        useRag: state.useRag,
        useTools: state.useTools,
        toolNames: effectiveToolNames,
        model: state.modelOverride,
        collectionIds: state.collectionIds,
        idempotencyKey: key,
        attachmentIds: _pendingAttachmentIds,
        voiceReply: _voiceReply,
      );
      if (!mounted) {
        await turn.close();
        return;
      }
      _consumePendingAttachments();
      _listen(
        turn,
        _TurnContext(targetId: placeholder.id, idempotencyKey: key, restoreOnFailure: snapshot),
      );
      if (_stopRequested) {
        _stopRequested = false;
        await stop();
      }
    } catch (e) {
      if (!mounted) return;
      // Nothing was sent: put the branch back exactly as it was.
      state = state.copyWith(messages: snapshot);
      _failTurn(e);
    }
  }

  /// Moves to the previous (`delta = -1`) or next (`+1`) sibling of
  /// [messageId]: `GET …/siblings` to find it, then `POST /sessions/{id}/branch`
  /// with its id; the returned history replaces the message list.
  Future<void> switchSibling(String messageId, int delta) async {
    if (state.sending || state.switchingBranch) return;
    state = state.copyWith(switchingBranch: true, clearError: true);
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final siblings = await repo.listSiblings(sessionId, messageId);
      final n = siblings.items.length;
      if (n < 2) {
        if (mounted) state = state.copyWith(switchingBranch: false);
        return;
      }
      final target = siblings.items[(((siblings.activeIndex + delta) % n) + n) % n];
      final history = await repo.branch(sessionId, leafMessageId: target.id);
      if (!mounted) return;
      state = state.copyWith(
        messages: [...history, ..._queuedBubbles()],
        switchingBranch: false,
        clearNextCursor: true,
        session: state.session?.copyWith(activeLeafId: history.lastOrNull?.id),
      );
      _persistCache();
      await _reconcileApprovals(repo);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(switchingBranch: false, error: ChatError.exception(e));
    }
  }

  /// Thumbs up (`1`) / down (`-1`) on a reply, with an optional comment.
  Future<void> setFeedback(String messageId, int rating, {String? comment}) async {
    final i = state.messages.indexWhere((m) => m.id == messageId);
    if (i < 0) return;
    final previous = state.messages[i].feedback;
    _replaceById(
      messageId,
      (m) => m.copyWith(feedback: MessageFeedback(rating: rating, comment: comment)),
    );
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final saved = await repo.setFeedback(sessionId, messageId, rating: rating, comment: comment);
      if (!mounted) return;
      _replaceById(messageId, (m) => m.copyWith(feedback: saved));
    } catch (e) {
      if (!mounted) return;
      _replaceById(
        messageId,
        (m) => m.copyWith(feedback: previous, clearFeedback: previous == null),
      );
      state = state.copyWith(error: ChatError.exception(e));
    }
  }

  /// Removes the user's feedback from a reply.
  Future<void> clearFeedback(String messageId) async {
    final i = state.messages.indexWhere((m) => m.id == messageId);
    if (i < 0) return;
    final previous = state.messages[i].feedback;
    if (previous == null) return;
    _replaceById(messageId, (m) => m.copyWith(clearFeedback: true));
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      await repo.clearFeedback(sessionId, messageId);
    } catch (e) {
      if (!mounted) return;
      _replaceById(messageId, (m) => m.copyWith(feedback: previous));
      state = state.copyWith(error: ChatError.exception(e));
    }
  }

  /// Answers a pending approval. The continuation streams into the same
  /// bubble: the server's final `assistant_message.data.id` equals the
  /// placeholder's id. A 409 / 404 (already resolved, expired, unknown)
  /// refreshes the chat instead.
  Future<void> resolveApproval(String approvalId, ApprovalDecision decision) async {
    if (state.sending) return;
    final index = state.messages.indexWhere((m) => m.approval?.approvalId == approvalId);
    if (index < 0) return;
    final original = state.messages[index];
    _stopRequested = false;

    // The card collapses right away and the bubble shows activity.
    _replaceById(
      original.id,
      (m) => m.copyWith(clearApproval: true, clearStatus: true, streaming: true),
    );
    state = state.copyWith(sending: true, stopping: false, clearError: true);

    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final prefs = _ref.read(prefsProvider);
      final turn = await repo.resolveApproval(
        sessionId: sessionId,
        approvalId: approvalId,
        decision: decision,
        transport: prefs.transport,
      );
      if (!mounted) {
        await turn.close();
        return;
      }
      _listen(
        turn,
        _TurnContext(
          targetId: original.id,
          initialText: original.content,
          tools: original.toolCalls,
          approval: original.approval,
        ),
      );
      if (_stopRequested) {
        _stopRequested = false;
        await stop();
      }
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && _isStaleApproval(e)) {
        state = state.copyWith(sending: false, stopping: false, error: ChatError.staleApproval);
        await reload();
        return;
      }
      // Give the card back so the user can retry.
      _replaceById(
        original.id,
        (m) => m.copyWith(
          approval: original.approval,
          status: MessageStatus.awaitingApproval,
          streaming: false,
        ),
      );
      _failTurn(e);
    }
  }

  static bool _isStaleApproval(ApiException e) =>
      e.statusCode == 409 || e.statusCode == 404 || e.code == 'conflict' || e.code == 'not_found';

  /// Ends a turn that could not start (or be resumed). A `quota_exceeded`
  /// refusal raises the app-wide quota banner instead of an inline error; a
  /// vision refusal (422 with `details.vision_models`) names the models that
  /// can read the attached images.
  void _failTurn(Object e) {
    final quota = _quotaFrom(e);
    if (quota != null) _ref.read(quotaStateProvider.notifier).set(quota);
    state = state.copyWith(
      sending: false,
      stopping: false,
      error: quota == null ? ChatError.exception(e) : null,
      clearError: quota != null,
    );
  }

  static QuotaExceeded? _quotaFrom(Object e) => e is ApiException && e.isQuotaExceeded
      ? QuotaExceeded.fromDetails(e.details, message: e.message)
      : null;

  void _listen(ChatTurn turn, _TurnContext ctx) {
    _turn = turn;
    _ctx = ctx;
    _sub = turn.events.listen(
      (event) => _onEvent(ctx, turn, event),
      onDone: () {
        // Stream ended without a terminal event (connection dropped).
        if (!mounted || !state.sending || _ctx != ctx || _turn != turn) return;
        if (_tryResume(ctx, turn)) return;
        _update(ctx, (m) => m.copyWith(streaming: false));
        _ctx = null;
        state = state.copyWith(sending: false, stopping: false);
      },
      onError: (Object e) {
        if (!mounted || _ctx != ctx || _turn != turn) return;
        if (_tryResume(ctx, turn)) return;
        _update(ctx, (m) => m.copyWith(streaming: false));
        _ctx = null;
        state = state.copyWith(sending: false, stopping: false, error: ChatError.exception(e));
      },
    );
  }

  /// A transport drop mid-stream (not a user stop) gets exactly one
  /// reconnect through `GET …/generations/{id}/events?after=<last seq>`,
  /// continuing the same bubble. Returns false when the turn cannot be
  /// resumed (no generation id yet, already resumed once, stopping).
  bool _tryResume(_TurnContext ctx, ChatTurn turn) {
    final generationId = turn.generationId ?? ctx.generationId;
    if (generationId == null || ctx.resumed || state.stopping || _stopRequested) return false;
    ctx
      ..resumed = true
      ..generationId = generationId;
    unawaited(_resume(ctx, generationId, after: turn.lastEventId));
    return true;
  }

  Future<void> _resume(_TurnContext ctx, String generationId, {String? after}) async {
    await _closeTurn();
    if (!mounted) return;
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final turn = await repo.resumeGeneration(sessionId, generationId, after: after);
      if (!mounted) {
        await turn.close();
        return;
      }
      if (after == null) {
        // No cursor (WebSocket turn): the replay starts from the first
        // frame, so the text we already have will arrive again.
        ctx.buffer.clear();
        ctx.tools = [];
        ctx.artifacts = [];
      }
      _listen(turn, ctx);
    } catch (e) {
      if (!mounted || _ctx != ctx) return;
      _update(ctx, (m) => m.copyWith(streaming: false));
      _ctx = null;
      _failTurn(e);
    }
  }

  void _onEvent(_TurnContext ctx, ChatTurn turn, StreamEvent event) {
    switch (event) {
      case TokenEvent(:final token):
        ctx.buffer.write(token);
        _update(ctx, (m) => m.copyWith(content: ctx.buffer.toString(), streaming: true));
      case CitationsEvent(:final citations):
        _update(ctx, (m) => m.copyWith(citations: citations));
      case ToolCallEvent():
        // Lifecycle frames: only `end` / `error` (or a single frame) carry a
        // result; the same `call_id` updates the chip already shown.
        if (event.isTerminal) {
          ctx.tools = mergeToolCalls(ctx.tools, [event.toToolCall()]);
          _update(ctx, (m) => m.copyWith(toolCalls: ctx.tools));
        }
      case UserMessageEvent():
        if (event.generationId != null) ctx.generationId = event.generationId;
        _upsertUserMessage(event, beforeId: ctx.targetId, key: ctx.idempotencyKey);
      case ApprovalRequiredEvent(:final approval):
        _update(
          ctx,
          (m) => m.copyWith(approval: approval, status: MessageStatus.awaitingApproval),
        );
      case DoneEvent(:final text, :final interrupted, :final status, :final model):
        // `done` carries the full text; trust it over our token buffer.
        if (text != null && text.isNotEmpty) {
          ctx.buffer
            ..clear()
            ..write(text);
        }
        _update(
          ctx,
          (m) => m.copyWith(
            content: text == null || text.isEmpty ? m.content : text,
            interrupted: interrupted || m.interrupted,
            status: status,
            model: model,
            generationId: event.generationId,
          ),
        );
      case ArtifactEvent(:final artifact):
        if (artifact.id.isEmpty) break;
        ctx.artifacts = mergeAttachments(ctx.artifacts, [artifact]);
        _update(ctx, (m) => m.copyWith(artifacts: ctx.artifacts));
      case AudioChunkEvent():
        // Spoken reply: the server only sends chunks when they were asked for.
        final bytes = event.bytes;
        if (bytes.isNotEmpty) {
          state = state.copyWith(playingMessageId: ctx.targetId);
          unawaited(_player.enqueue(AudioClip(bytes: bytes, mimeType: event.mimeType)));
        }
      case AudioDoneEvent(:final attachment, :final chunks):
        if (attachment != null) {
          _update(
            ctx,
            (m) => m.copyWith(audio: MessageAudio.fromAttachment(attachment, chunks: chunks)),
          );
        }
      case AssistantMessageEvent():
        // Final canonical version straight from the server.
        _stopTimeout?.cancel();
        _stopTimeout = null;
        final message = event.toMessage(sessionId);
        _finishTurn(
          ctx,
          message.copyWith(
            // Frames may have announced artifacts the final message omits.
            artifacts: mergeAttachments(ctx.artifacts, message.artifacts),
            audio: message.audio ?? _currentAudio(ctx),
          ),
          persistedId: event.id,
        );
      case ErrorEvent(:final message, :final isBusy, :final isStaleApproval):
        if (event.isTransportError && _tryResume(ctx, turn)) return;
        _stopTimeout?.cancel();
        _stopTimeout = null;
        if (ctx.isApprovalContinuation && isStaleApproval) {
          // WebSocket reports 409 / 404 as error frames.
          _ctx = null;
          state = state.copyWith(sending: false, stopping: false, error: ChatError.staleApproval);
          unawaited(reload());
          return;
        }
        final quota = event.isQuotaExceeded
            ? QuotaExceeded.fromDetails(event.details, message: event.message)
            : null;
        final error = isBusy ? ChatError.busy : ChatError.message(message);
        if (ctx.isApprovalContinuation) {
          _update(
            ctx,
            (m) => m.copyWith(
              streaming: false,
              approval: ctx.approval,
              status: MessageStatus.awaitingApproval,
            ),
          );
        } else if (quota != null && ctx.restoreOnFailure != null && ctx.buffer.isEmpty) {
          // A refused edit: the branch never changed server-side.
          state = state.copyWith(messages: ctx.restoreOnFailure);
        } else {
          _dropEmptyStreaming(ctx.targetId);
          _update(ctx, (m) => m.copyWith(streaming: false));
        }
        _ctx = null;
        if (quota != null) _ref.read(quotaStateProvider.notifier).set(quota);
        state = state.copyWith(
          sending: false,
          stopping: false,
          error: quota == null ? error : null,
          clearError: quota != null,
        );
      case UsageEvent():
      case UnknownEvent():
        break;
    }
  }

  /// The `meta.audio` the turn's bubble already carries (from `audio_done`).
  MessageAudio? _currentAudio(_TurnContext ctx) {
    for (final m in state.messages) {
      if (m.id == ctx.targetId) return m.audio;
    }
    return null;
  }

  /// Blocking turn: the persisted user message replaces the optimistic one
  /// and the placeholder gives way to the server's tool rows + reply.
  void _finishBlockingTurn(String placeholderId, SendResult result) {
    final msgs = List<ChatMessage>.of(state.messages);
    final user = result.userMessage;
    if (user != null) {
      final u = msgs.indexWhere((m) => m.isPendingUser && !m.isQueued);
      if (u >= 0) msgs[u] = user;
    }
    final i = msgs.indexWhere((m) => m.id == placeholderId);
    if (i < 0) {
      msgs.addAll(result.replyRows);
    } else {
      msgs.replaceRange(i, i + 1, result.replyRows);
    }
    state = state.copyWith(messages: msgs, sending: false);
    _afterTurn();
  }

  /// Replaces the bubble the turn streamed into with the persisted message.
  /// An approval continuation's final message carries the placeholder's own
  /// id, so a row with [persistedId] wins over the context target.
  void _finishTurn(_TurnContext ctx, ChatMessage message, {String? persistedId}) {
    final msgs = List<ChatMessage>.of(state.messages);
    var i = persistedId == null ? -1 : msgs.indexWhere((m) => m.id == persistedId);
    if (i < 0) i = msgs.indexWhere((m) => m.id == ctx.targetId);
    if (i < 0) i = msgs.lastIndexWhere((m) => m.role == MessageRole.assistant);
    if (i < 0) {
      msgs.add(message);
    } else {
      msgs[i] = message;
      // The persisted id matched a different row than the placeholder: drop
      // the placeholder so the reply is not shown twice.
      final leftover = msgs.indexWhere((m) => m.id == ctx.targetId);
      if (leftover >= 0 && leftover != i) msgs.removeAt(leftover);
    }
    _ctx = null;
    state = state.copyWith(
      messages: msgs,
      sending: false,
      stopping: false,
      // The spoken reply was attributed to the placeholder; move it to the
      // persisted message so the stop button follows the bubble.
      playingMessageId: state.playingMessageId == ctx.targetId ? message.id : null,
    );
    _afterTurn();
  }

  void _finishInterruptedLocally() {
    _stopTimeout?.cancel();
    _stopTimeout = null;
    unawaited(_closeTurn());
    if (!mounted) return;
    final ctx = _ctx;
    _ctx = null;
    if (ctx != null) {
      _update(ctx, (m) => m.copyWith(streaming: false, interrupted: true));
    } else {
      _replaceLastAssistant((m) => m.copyWith(streaming: false, interrupted: true));
    }
    state = state.copyWith(sending: false, stopping: false);
    _afterTurn();
  }

  Future<void> _closeTurn() async {
    final sub = _sub;
    final turn = _turn;
    _sub = null;
    _turn = null;
    await sub?.cancel();
    await turn?.close();
  }

  /// Titles are generated server-side after the stream closes; re-fetch the
  /// session list a moment later so the sidebar picks the title up. The
  /// usage meter is refreshed as well — the turn just spent tokens — and
  /// the finished turn goes to the device cache.
  void _afterTurn() {
    _ref.read(sessionListRefresherProvider).scheduleRefresh();
    if (_ref.exists(usageMeProvider)) _ref.invalidate(usageMeProvider);
    _persistCache();
  }

  /// Applies [update] to the turn's target bubble (falls back to the last
  /// assistant message if the target vanished, e.g. after a reload).
  void _update(_TurnContext ctx, ChatMessage Function(ChatMessage) update) {
    if (!_replaceById(ctx.targetId, update)) _replaceLastAssistant(update);
  }

  bool _replaceById(String id, ChatMessage Function(ChatMessage) update) {
    final msgs = List<ChatMessage>.of(state.messages);
    final i = msgs.indexWhere((m) => m.id == id);
    if (i < 0) return false;
    msgs[i] = update(msgs[i]);
    state = state.copyWith(messages: msgs);
    return true;
  }

  void _replaceLastAssistant(ChatMessage Function(ChatMessage) update) {
    final msgs = List<ChatMessage>.of(state.messages);
    for (var i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].role == MessageRole.assistant) {
        msgs[i] = update(msgs[i]);
        state = state.copyWith(messages: msgs);
        return;
      }
    }
  }

  /// Drops a streaming placeholder that never received any text (the turn
  /// failed before the model produced anything).
  void _dropEmptyStreaming(String id) {
    final msgs = state.messages;
    final i = msgs.indexWhere((m) => m.id == id);
    if (i < 0) return;
    final m = msgs[i];
    if (m.role == MessageRole.assistant && m.streaming && m.content.isEmpty) {
      state = state.copyWith(messages: [...msgs.sublist(0, i), ...msgs.sublist(i + 1)]);
    }
  }

  /// The persisted `user_message` replaces the optimistic bubble of the same
  /// send ([key]), else the in-flight optimistic bubble; when there is none
  /// (an attached generation replaying from its first frame) it updates the
  /// row with the same id, or is inserted before [beforeId]. Queued bubbles
  /// of other sends are never touched.
  void _upsertUserMessage(UserMessageEvent event, {required String beforeId, String? key}) {
    final msgs = List<ChatMessage>.of(state.messages);
    var pending = key == null ? -1 : msgs.indexWhere((m) => m.id == QueuedSend.bubbleIdFor(key));
    if (pending < 0) pending = msgs.indexWhere((m) => m.isPendingUser && !m.isQueued);
    if (pending >= 0) {
      msgs[pending] = event.toMessage(sessionId, fallbackCreatedAt: msgs[pending].createdAt);
      state = state.copyWith(messages: msgs);
      return;
    }
    final id = event.id;
    final existing = id == null ? -1 : msgs.indexWhere((m) => m.id == id);
    final message = event.toMessage(sessionId);
    if (existing >= 0) {
      msgs[existing] = message;
    } else {
      final target = msgs.indexWhere((m) => m.id == beforeId);
      msgs.insert(target < 0 ? msgs.length : target, message);
    }
    state = state.copyWith(messages: msgs);
  }

  /// A fresh reply for the last user message (blocking endpoint). The
  /// previous reply stays as a sibling, so the active branch is reloaded
  /// from the server afterwards to pick up the sibling counts.
  Future<void> regenerate() async {
    if (state.sending) return;
    state = state.copyWith(sending: true, clearError: true);
    try {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final result = await repo.regenerate(sessionId);
      if (!mounted) return;
      // Swap the previous reply (and the tool rows directly above it) for the
      // regenerated turn right away, then reload the branch.
      final msgs = List<ChatMessage>.of(state.messages);
      final last = msgs.lastIndexWhere((m) => m.role == MessageRole.assistant);
      if (last < 0) {
        msgs.addAll(result.replyRows);
      } else {
        var start = last;
        while (start > 0 && msgs[start - 1].isToolRun) {
          start--;
        }
        msgs.replaceRange(start, last + 1, result.replyRows);
      }
      state = state.copyWith(messages: msgs, sending: false);
      _afterTurn();
      try {
        final page = await repo.loadHistoryPage(sessionId, limit: pageSize);
        if (!mounted) return;
        state = state.copyWith(
          messages: [...page.items, ..._queuedBubbles()],
          nextCursor: page.nextCursor,
          clearNextCursor: page.nextCursor == null,
        );
        _persistCache();
        await _reconcileApprovals(repo);
      } catch (_) {
        // The optimistic swap stands; the next reload shows the siblings.
      }
    } catch (e) {
      if (!mounted) return;
      _failTurn(e);
    }
  }

  /// Re-checks `/usage/me`; the quota banner disappears once turns are
  /// allowed again.
  Future<bool> refreshQuota() => _ref.read(quotaStateProvider.notifier).refresh();

  @override
  void dispose() {
    _stopTimeout?.cancel();
    unawaited(_playerSub?.cancel());
    unawaited(_queueSub?.cancel());
    unawaited(_closeTurn());
    super.dispose();
  }
}

final chatControllerProvider =
    StateNotifierProvider.autoDispose.family<ChatController, ChatState, String>(
  (ref, sessionId) => ChatController(ref, sessionId),
);
