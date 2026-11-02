import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/local_store.dart';
import 'package:nexusbot/features/assistants/assistant_model.dart';
import 'package:nexusbot/features/auth/auth_models.dart';
import 'package:nexusbot/features/chat/chat_cache.dart';
import 'package:nexusbot/features/chat/chat_models.dart';

ChatMessage msg(String id, {MessageRole role = MessageRole.user, String content = 'x'}) =>
    ChatMessage(
      id: id,
      sessionId: 's1',
      role: role,
      content: content,
      createdAt: DateTime.utc(2026, 1, 1, 12),
    );

void main() {
  group('ChatMessage.toJson', () {
    test('round-trips an assistant message with every meta field', () {
      final original = ChatMessage.fromJson({
        'id': 'a1',
        'session_id': 's1',
        'role': 'assistant',
        'content': 'Grounded **answer**',
        'tokens': 42,
        'created_at': '2026-01-01T12:00:00.000Z',
        'parent_id': 'u1',
        'siblings': {'index': 1, 'count': 3},
        'meta': {
          'status': 'ok',
          'model': 'gpt-4o-mini',
          'generation_id': 'g1',
          'citations': [
            {
              'document_id': 'd1',
              'document_name': 'spec.pdf',
              'chunk_id': 'c1',
              'chunk_index': 3,
              'page': 4,
              'section': 'Scope',
              'score': 0.83,
              'excerpt': 'first chars',
              'match': 'hybrid',
            },
          ],
          'tool_calls': [
            {
              'tool': 'calculator',
              'call_id': 'call1',
              'input': {'expression': '2+2'},
              'output': '4',
              'status': 'ok',
              'latency_ms': 12,
            },
          ],
          'feedback': {'rating': 1, 'comment': 'nice'},
          'memories_used': ['m1', 'm2'],
          'artifacts': [
            {
              'id': 'art1',
              'kind': 'artifact',
              'name': 'plot.png',
              'mime_type': 'image/png',
              'size_bytes': 100,
              'url': '/api/v1/sessions/s1/attachments/art1/content',
            },
          ],
          'audio': {'attachment_id': 'spk', 'url': '/api/v1/x', 'format': 'mp3', 'chunks': 2},
        },
      });
      final copy = ChatMessage.fromJson(original.toJson());
      expect(copy.id, 'a1');
      expect(copy.role, MessageRole.assistant);
      expect(copy.content, original.content);
      expect(copy.tokens, 42);
      expect(copy.createdAt, original.createdAt);
      expect(copy.parentId, 'u1');
      expect(copy.siblings?.index, 1);
      expect(copy.siblings?.count, 3);
      expect(copy.status, 'ok');
      expect(copy.model, 'gpt-4o-mini');
      expect(copy.generationId, 'g1');
      expect(copy.citations.single.documentName, 'spec.pdf');
      expect(copy.citations.single.page, 4);
      expect(copy.citations.single.match, 'hybrid');
      expect(copy.toolCalls.single.callId, 'call1');
      expect(copy.toolCalls.single.input, {'expression': '2+2'});
      expect(copy.toolCalls.single.latencyMs, 12);
      expect(copy.feedback?.rating, 1);
      expect(copy.feedback?.comment, 'nice');
      expect(copy.memoriesUsed, ['m1', 'm2']);
      expect(copy.artifacts.single.name, 'plot.png');
      expect(copy.audio?.attachmentId, 'spk');
      expect(copy.audio?.chunks, 2);
    });

    test('round-trips a tool row, an approval and an interrupted reply', () {
      final tool = ChatMessage.fromJson({
        'id': 't1',
        'session_id': 's1',
        'role': 'tool',
        'content': 'result text',
        'created_at': '2026-01-01T12:00:00.000Z',
        'meta': {'tool': 'web_search', 'call_id': 'c9', 'status': 'denied', 'latency_ms': 3},
      });
      final toolCopy = ChatMessage.fromJson(tool.toJson());
      expect(toolCopy.isToolRun, isTrue);
      expect(toolCopy.toolCalls.single.tool, 'web_search');
      expect(toolCopy.toolCalls.single.status, ToolCallStatus.denied);
      expect(toolCopy.toolCalls.single.output, 'result text');
      expect(toolCopy.toolCalls.single.latencyMs, 3);

      final paused = ChatMessage.fromJson({
        'id': 'a2',
        'session_id': 's1',
        'role': 'assistant',
        'content': '',
        'created_at': '2026-01-01T12:00:00.000Z',
        'meta': {
          'status': 'awaiting_approval',
          'approval': {
            'approval_id': 'ap1',
            'session_id': 's1',
            'message_id': 'a2',
            'expires_at': '2099-01-01T00:00:00.000Z',
            'tool_calls': [
              {
                'call_id': 'c1',
                'tool': 'web_search',
                'input': {'q': 'x'},
                'description': 'd',
              },
            ],
          },
        },
      });
      final pausedCopy = ChatMessage.fromJson(paused.toJson());
      expect(pausedCopy.awaitingApproval, isTrue);
      expect(pausedCopy.approval?.approvalId, 'ap1');
      expect(pausedCopy.approval?.toolCalls.single.description, 'd');
      expect(pausedCopy.approval?.expiresAt, DateTime.utc(2099));

      final stopped = msg('a3', role: MessageRole.assistant).copyWith(interrupted: true);
      final stoppedCopy = ChatMessage.fromJson(stopped.toJson());
      expect(stoppedCopy.interrupted, isTrue);
      expect(stoppedCopy.status, MessageStatus.interrupted);
    });

    test('local-only state is not serialised', () {
      final queued = msg('${ChatMessage.pendingUserPrefix}k1')
          .copyWith(delivery: MessageDelivery.queued, deliveryError: 'offline');
      final copy = ChatMessage.fromJson(queued.toJson());
      expect(copy.delivery, MessageDelivery.sent);
      expect(copy.deliveryError, isNull);
      expect(copy.streaming, isFalse);
    });

    test('ChatSession round-trips', () {
      final session = ChatSession.fromJson({
        'id': 's1',
        'title': 'Hello',
        'model': 'gpt-4o',
        'meta': {
          'collection_ids': ['c1'],
        },
        'org_id': 'o1',
        'assistant_id': 'as1',
        'active_leaf_id': 'a9',
        'created_at': '2026-01-01T12:00:00.000Z',
        'updated_at': '2026-01-02T12:00:00.000Z',
      });
      final copy = ChatSession.fromJson(session.toJson());
      expect(copy.id, 's1');
      expect(copy.title, 'Hello');
      expect(copy.model, 'gpt-4o');
      expect(copy.collectionIds, ['c1']);
      expect(copy.orgId, 'o1');
      expect(copy.assistantId, 'as1');
      expect(copy.activeLeafId, 'a9');
      expect(copy.updatedAt, session.updatedAt);
    });
  });

  group('ChatCache', () {
    late MemoryLocalStore store;
    late ChatCache cache;

    setUp(() {
      store = MemoryLocalStore();
      cache = ChatCache(store, maxMessages: 3);
    });

    test('sessions are kept per scope', () async {
      final s = ChatSession(
        id: 's1',
        title: 'T',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      await cache.writeSessions('u1:personal', [s]);
      expect((await cache.readSessions('u1:personal'))!.single.title, 'T');
      expect(await cache.readSessions('u2:personal'), isNull, reason: 'another user');
      expect(await cache.readSessions('u1:org9'), isNull, reason: 'another workspace');
    });

    test('messages keep only the newest persisted rows and drop the cursor when trimmed', () async {
      final rows = [
        msg('u1'),
        msg('a1', role: MessageRole.assistant),
        msg('u2'),
        msg('a2', role: MessageRole.assistant),
        ChatMessage.streamingPlaceholder(sessionId: 's1'),
        msg('${ChatMessage.pendingUserPrefix}k').copyWith(delivery: MessageDelivery.queued),
      ];
      await cache.writeMessages('u1:personal', 's1', rows, nextCursor: '2025-12-31T00:00:00Z');
      final cached = (await cache.readMessages('u1:personal', 's1'))!;
      expect(cached.messages.map((m) => m.id), ['a1', 'u2', 'a2']);
      expect(cached.nextCursor, isNull, reason: 'a truncated cache cannot continue the cursor');
      expect(cached.savedAt, isNotNull);

      await cache.writeMessages('u1:personal', 's1', rows.sublist(2, 4), nextCursor: 'c');
      expect((await cache.readMessages('u1:personal', 's1'))!.nextCursor, 'c');

      await cache.removeSession('u1:personal', 's1');
      expect(await cache.readMessages('u1:personal', 's1'), isNull);
    });

    test('assistants and the profile round-trip; clear wipes every cached document', () async {
      const a = Assistant(
        id: 'as1',
        name: 'Support',
        toolNames: ['calculator'],
        collectionIds: [],
        useRag: true,
        useTools: true,
        memoryEnabled: false,
        isDefault: true,
        createdBy: 'u1',
      );
      await cache.writeAssistants('u1:personal', [a]);
      final back = (await cache.readAssistants('u1:personal'))!.single;
      expect(back.name, 'Support');
      expect(back.toolNames, ['calculator']);
      expect(back.isDefault, isTrue);
      expect(back.memoryEnabled, isFalse);
      expect(back.createdBy, 'u1');

      const user = User(id: 'u1', email: 'a@b.com', role: 'admin', fullName: 'Ann');
      await cache.writeProfile(user);
      final profile = (await cache.readProfile())!;
      expect(profile.id, 'u1');
      expect(profile.fullName, 'Ann');
      expect(profile.isServerAdmin, isTrue);

      await store.write('sendqueue:u1:personal', {'items': []});
      await cache.clear();
      expect(await cache.readAssistants('u1:personal'), isNull);
      expect(await cache.readProfile(), isNull);
      expect(await store.keys(), ['sendqueue:u1:personal'], reason: 'the queue is not cache');
    });

    test('a corrupt row is skipped instead of breaking the cache', () async {
      await store.write(ChatCache.messagesKey('u1:personal', 's1'), {
        'items': [
          msg('u1').toJson(),
          {'id': 'broken'},
          'junk',
        ],
      });
      final cached = (await cache.readMessages('u1:personal', 's1'))!;
      expect(cached.messages.map((m) => m.id), ['u1']);
    });

    test('cacheScope formats user and workspace', () {
      expect(cacheScope(), 'anon:personal');
      expect(cacheScope(userId: 'u1'), 'u1:personal');
      expect(cacheScope(userId: 'u1', orgId: 'o1'), 'u1:o1');
    });
  });
}
