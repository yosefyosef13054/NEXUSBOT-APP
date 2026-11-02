import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/connectivity.dart';
import '../../core/local_store.dart';
import '../attachments/attachment_model.dart';
import 'chat_cache.dart';
import 'chat_models.dart';
import 'chat_repository.dart';

/// A user message that could not be sent right away (offline, or the send
/// hit a transport error) and waits for the queue to replay it.
///
/// [key] is the `Idempotency-Key` of the first attempt and is reused on
/// every retry, so the server never creates a second turn for the same
/// message; it also names the optimistic bubble ([bubbleId]).
class QueuedSend {
  const QueuedSend({
    required this.key,
    required this.sessionId,
    required this.content,
    required this.createdAt,
    this.orgId,
    this.attachments = const [],
    this.useRag = true,
    this.useTools = true,
    this.toolNames,
    this.model,
    this.collectionIds,
    this.voiceReply,
    this.attempts = 0,
    this.failed = false,
    this.lastError,
  });

  factory QueuedSend.fromJson(Map<String, dynamic> j) => QueuedSend(
        key: j['key'] as String,
        sessionId: j['session_id'] as String,
        orgId: j['org_id'] as String?,
        content: (j['content'] as String?) ?? '',
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
        attachments: attachmentsFrom(j['attachments']),
        useRag: j['use_rag'] != false,
        useTools: j['use_tools'] != false,
        toolNames: (j['tool_names'] as List?)?.map((e) => e.toString()).toList(),
        model: j['model'] as String?,
        collectionIds: (j['collection_ids'] as List?)?.map((e) => e.toString()).toList(),
        voiceReply: j['voice_reply'] is Map
            ? VoiceReply(
                voice: (j['voice_reply'] as Map)['voice'] as String?,
                audioFormat: (j['voice_reply'] as Map)['audio_format'] as String?,
              )
            : null,
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        failed: j['failed'] == true,
        lastError: j['last_error'] as String?,
      );

  final String key;
  final String sessionId;

  /// The workspace the message belongs to (the queue is scoped by it).
  final String? orgId;
  final String content;
  final DateTime createdAt;

  /// Upload summaries, for the bubble; their ids go out as `attachment_ids`.
  final List<Attachment> attachments;
  final bool useRag;
  final bool useTools;
  final List<String>? toolNames;
  final String? model;
  final List<String>? collectionIds;
  final VoiceReply? voiceReply;

  /// Replays so far.
  final int attempts;

  /// Parked after a refusal the queue cannot fix (quota, validation, …);
  /// waits for a manual retry or a cancel.
  final bool failed;
  final String? lastError;

  List<String>? get attachmentIds =>
      attachments.isEmpty ? null : [for (final a in attachments) a.id];

  /// Id of the optimistic bubble this send is shown as.
  String get bubbleId => bubbleIdFor(key);

  static String bubbleIdFor(String key) => '${ChatMessage.pendingUserPrefix}$key';

  /// The bubble to render for this send.
  ChatMessage toMessage() => ChatMessage(
        id: bubbleId,
        sessionId: sessionId,
        role: MessageRole.user,
        content: content,
        createdAt: createdAt,
        attachments: attachments,
        delivery: failed ? MessageDelivery.failed : MessageDelivery.queued,
        deliveryError: lastError,
      );

  QueuedSend copyWith({
    int? attempts,
    bool? failed,
    String? lastError,
    bool clearLastError = false,
  }) =>
      QueuedSend(
        key: key,
        sessionId: sessionId,
        orgId: orgId,
        content: content,
        createdAt: createdAt,
        attachments: attachments,
        useRag: useRag,
        useTools: useTools,
        toolNames: toolNames,
        model: model,
        collectionIds: collectionIds,
        voiceReply: voiceReply,
        attempts: attempts ?? this.attempts,
        failed: failed ?? this.failed,
        lastError: clearLastError ? null : (lastError ?? this.lastError),
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'session_id': sessionId,
        'org_id': orgId,
        'content': content,
        'created_at': createdAt.toIso8601String(),
        'attachments': [for (final a in attachments) a.toJson()],
        'use_rag': useRag,
        'use_tools': useTools,
        'tool_names': toolNames,
        'model': model,
        'collection_ids': collectionIds,
        'voice_reply': voiceReply == null
            ? null
            : {'voice': voiceReply!.voice, 'audio_format': voiceReply!.audioFormat},
        'attempts': attempts,
        'failed': failed,
        'last_error': lastError,
      };
}

class SendQueueState {
  const SendQueueState({this.items = const [], this.loaded = false});

  final List<QueuedSend> items;

  /// The persisted queue has been read.
  final bool loaded;

  bool get isEmpty => items.isEmpty;

  /// Sends still being retried automatically.
  int get pendingCount => items.where((i) => !i.failed).length;
  int get failedCount => items.where((i) => i.failed).length;

  List<QueuedSend> forSession(String sessionId) =>
      items.where((i) => i.sessionId == sessionId).toList();

  QueuedSend? byKey(String key) => items.firstWhereOrNull((i) => i.key == key);

  SendQueueState copyWith({List<QueuedSend>? items, bool? loaded}) =>
      SendQueueState(items: items ?? this.items, loaded: loaded ?? this.loaded);
}

/// What happened to a queued send.
sealed class SendQueueEvent {
  const SendQueueEvent(this.item);
  final QueuedSend item;
}

/// The server accepted the replay (`POST /messages/background` → 202): the
/// reply is produced server-side; a chat screen attaches to the generation.
class SendAccepted extends SendQueueEvent {
  const SendAccepted(super.item, this.accepted);
  final BackgroundSend accepted;
}

/// The queue parked the send after a refusal it cannot fix.
class SendFailed extends SendQueueEvent {
  const SendFailed(super.item, this.error);
  final Object error;
}

class SendCancelled extends SendQueueEvent {
  const SendCancelled(super.item);
}

/// Replays queued sends in order, with backoff, whenever the device is
/// online — through `POST /sessions/{id}/messages/background` so the reply
/// is produced even if the app is closed before it finishes. Persisted in
/// the [LocalStore] (per user and workspace) so a restart loses nothing.
class SendQueue extends StateNotifier<SendQueueState> {
  SendQueue({
    required Future<ChatRepository> Function() repository,
    required LocalStore store,
    required ConnectivityService connectivity,
    required this.scope,
    Duration Function(int attempts)? backoff,
    Future<void> Function(Duration)? wait,
    this.maxAttempts = 8,
  })  : _repository = repository,
        _store = store,
        _connectivity = connectivity,
        _backoff = backoff ?? defaultBackoff,
        _wait = wait ?? ((d) => Future<void>.delayed(d)),
        super(const SendQueueState()) {
    _ready = _load();
    _online = connectivity.onlineChanges.listen((online) {
      if (online) unawaited(drain());
    });
  }

  /// 1 s, 2 s, 4 s, … capped at a minute.
  static Duration defaultBackoff(int attempts) =>
      Duration(seconds: math.min(60, 1 << math.min(attempts - 1, 6).clamp(0, 6)));

  final Future<ChatRepository> Function() _repository;
  final LocalStore _store;
  final ConnectivityService _connectivity;
  final Duration Function(int attempts) _backoff;
  final Future<void> Function(Duration) _wait;

  /// `<user>:<org>` — see [cacheScopeProvider].
  final String scope;

  /// Transient failures tolerated before a send is parked.
  final int maxAttempts;

  final _events = StreamController<SendQueueEvent>.broadcast();
  late final Future<void> _ready;
  StreamSubscription<bool>? _online;
  bool _draining = false;
  bool _drainAgain = false;

  Stream<SendQueueEvent> get events => _events.stream;

  /// Completes once the persisted queue has been read.
  Future<void> get ready => _ready;

  String get _storeKey => 'sendqueue:$scope';

  Future<void> _load() async {
    final doc = await _store.read(_storeKey);
    final raw = doc?['items'];
    final items = <QueuedSend>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        try {
          items.add(QueuedSend.fromJson(item.cast<String, dynamic>()));
        } catch (_) {
          // From an older build: drop it.
        }
      }
    }
    if (!mounted) return;
    state = SendQueueState(items: items, loaded: true);
    if (items.isNotEmpty) unawaited(drain());
  }

  Future<void> _persist() => _store.write(_storeKey, {
        'items': [for (final i in state.items) i.toJson()],
      });

  void _emit(SendQueueEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Appends [send] and starts replaying when online.
  Future<void> enqueue(QueuedSend send) async {
    await _ready;
    if (!mounted) return;
    state = state.copyWith(items: [...state.items.where((i) => i.key != send.key), send]);
    await _persist();
    unawaited(drain());
  }

  Future<void> cancel(String key) async {
    await _ready;
    final item = state.byKey(key);
    if (item == null || !mounted) return;
    state = state.copyWith(items: state.items.where((i) => i.key != key).toList());
    await _persist();
    _emit(SendCancelled(item));
  }

  /// Un-parks a failed send (or hurries a queued one) and replays now.
  Future<void> retry(String key) async {
    await _ready;
    final item = state.byKey(key);
    if (item == null || !mounted) return;
    _replace(item.copyWith(attempts: 0, failed: false, clearLastError: true));
    await _persist();
    await drain();
  }

  void _replace(QueuedSend item) {
    state = state.copyWith(
      items: [for (final i in state.items) i.key == item.key ? item : i],
    );
  }

  /// Sends every queued (non-parked) item in order. Transient failures
  /// (no network, timeouts, 5xx, a busy session, a plain rate limit) back
  /// off and retry; anything else parks the item.
  Future<void> drain() async {
    if (_draining) {
      _drainAgain = true;
      return;
    }
    _draining = true;
    try {
      await _ready;
      while (mounted) {
        final item = state.items.firstWhereOrNull((i) => !i.failed);
        if (item == null) break;
        if (!await _connectivity.checkOnline()) break; // the reconnect event resumes
        final ChatRepository repo;
        try {
          repo = await _repository();
        } catch (_) {
          break;
        }
        try {
          final accepted = await repo.sendBackground(
            sessionId: item.sessionId,
            content: item.content,
            useRag: item.useRag,
            useTools: item.useTools,
            toolNames: item.toolNames,
            model: item.model,
            collectionIds: item.collectionIds,
            idempotencyKey: item.key,
            attachmentIds: item.attachmentIds,
            voiceReply: item.voiceReply,
          );
          if (!mounted) return;
          state = state.copyWith(items: state.items.where((i) => i.key != item.key).toList());
          await _persist();
          _emit(SendAccepted(item, accepted));
        } catch (e) {
          if (!mounted) return;
          final transient = e is ApiException && e.isTransient;
          final attempts = item.attempts + 1;
          if (transient && attempts < maxAttempts) {
            _replace(item.copyWith(attempts: attempts, lastError: errorText(e)));
            await _persist();
            await _wait(_backoff(attempts));
            continue;
          }
          final parked = item.copyWith(attempts: attempts, failed: true, lastError: errorText(e));
          _replace(parked);
          await _persist();
          _emit(SendFailed(parked, e));
        }
      }
    } finally {
      _draining = false;
      if (_drainAgain) {
        _drainAgain = false;
        unawaited(drain());
      }
    }
  }

  @override
  void dispose() {
    unawaited(_online?.cancel());
    unawaited(_events.close());
    super.dispose();
  }
}

/// The send queue of the signed-in user in the active workspace (a new one
/// per scope; the previous one is disposed).
final sendQueueProvider = StateNotifierProvider<SendQueue, SendQueueState>((ref) {
  final scope = ref.watch(cacheScopeProvider);
  return SendQueue(
    repository: () => ref.read(chatRepositoryProvider.future),
    store: ref.watch(localStoreProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    scope: scope,
  );
});
