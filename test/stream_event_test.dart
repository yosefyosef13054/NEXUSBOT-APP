import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/features/chat/chat_models.dart';

void main() {
  group('StreamEvent.fromJson', () {
    test('user_message', () {
      final e = StreamEvent.fromJson({
        'type': 'user_message',
        'data': {'id': 'u1', 'content': 'hi', 'created_at': '2026-01-01T00:00:00Z'},
      });
      expect(e, isA<UserMessageEvent>());
      final m = (e as UserMessageEvent).toMessage('s1');
      expect(m.id, 'u1');
      expect(m.role, MessageRole.user);
      expect(m.content, 'hi');
      expect(m.sessionId, 's1');
      expect(m.createdAt.toUtc().year, 2026);
    });

    test('citations', () {
      final e = StreamEvent.fromJson({
        'type': 'citations',
        'data': [
          {
            'document_id': 'd1',
            'document_name': 'spec.pdf',
            'chunk_index': 3,
            'score': 0.84,
            'excerpt': '…',
          },
          {'document_name': 'partial.md'},
        ],
      });
      expect(e, isA<CitationsEvent>());
      final cits = (e as CitationsEvent).citations;
      expect(cits, hasLength(2));
      expect(cits.first.documentName, 'spec.pdf');
      expect(cits.first.chunkIndex, 3);
      expect(cits.first.score, closeTo(0.84, 1e-9));
      expect(cits.last.documentId, '', reason: 'missing fields fall back to defaults');
    });

    test('token (string and tolerant non-string)', () {
      expect((StreamEvent.fromJson({'type': 'token', 'data': 'Hel'}) as TokenEvent).token, 'Hel');
      expect((StreamEvent.fromJson({'type': 'token', 'data': 42}) as TokenEvent).token, '42');
      expect((StreamEvent.fromJson({'type': 'token'}) as TokenEvent).token, '');
    });

    test('tool_call lifecycle', () {
      final start = StreamEvent.fromJson({
        'type': 'tool_call',
        'data': {'phase': 'start', 'tool': 'calculator', 'input': '2+2'},
      }) as ToolCallEvent;
      expect(start.phase, 'start');
      expect(start.tool, 'calculator');
      expect(start.output, isNull);

      final end = StreamEvent.fromJson({
        'type': 'tool_call',
        'data': {'phase': 'end', 'tool': 'calculator', 'input': '2+2', 'output': 4},
      }) as ToolCallEvent;
      expect(end.phase, 'end');
      expect(end.toToolCall().output, '4');
    });

    test('usage carries token counts', () {
      final e = StreamEvent.fromJson({
        'type': 'usage',
        'data': {'prompt_tokens': 1240, 'completion_tokens': 312, 'total_tokens': 1552},
      }) as UsageEvent;
      expect(e.promptTokens, 1240);
      expect(e.completionTokens, 312);
      expect(e.totalTokens, 1552);
      expect((StreamEvent.fromJson({'type': 'usage', 'data': null}) as UsageEvent).totalTokens, isNull);
    });

    test('done — normal and interrupted', () {
      final done = StreamEvent.fromJson({
        'type': 'done',
        'data': {'text': 'Hello!', 'latency_ms': 820},
      }) as DoneEvent;
      expect(done.text, 'Hello!');
      expect(done.latencyMs, 820);
      expect(done.interrupted, isFalse);

      final stopped = StreamEvent.fromJson({
        'type': 'done',
        'data': {'text': 'Hel', 'latency_ms': 120, 'interrupted': true},
      }) as DoneEvent;
      expect(stopped.interrupted, isTrue);
      expect(stopped.text, 'Hel');
    });

    test('assistant_message — normal and interrupted', () {
      final e = StreamEvent.fromJson({
        'type': 'assistant_message',
        'data': {
          'id': 'a1',
          'session_id': 's1',
          'content': 'Hello!',
          'created_at': '2026-01-01T00:00:01Z',
          'citations': [
            {'document_id': 'd1', 'document_name': 'spec.pdf', 'chunk_index': 0, 'score': 0.5, 'excerpt': 'x'},
          ],
          'tool_calls': [
            {'tool': 'calculator', 'input': '2+2', 'output': '4'},
          ],
        },
      }) as AssistantMessageEvent;
      expect(e.interrupted, isFalse);
      final m = e.toMessage('fallback');
      expect(m.id, 'a1');
      expect(m.sessionId, 's1');
      expect(m.role, MessageRole.assistant);
      expect(m.content, 'Hello!');
      expect(m.citations.single.documentName, 'spec.pdf');
      expect(m.toolCalls.single.tool, 'calculator');
      expect(m.interrupted, isFalse);
      expect(m.streaming, isFalse);

      final stopped = StreamEvent.fromJson({
        'type': 'assistant_message',
        'data': {'id': 'a2', 'content': 'Hel', 'interrupted': true},
      }) as AssistantMessageEvent;
      expect(stopped.interrupted, isTrue);
      final sm = stopped.toMessage('s1');
      expect(sm.interrupted, isTrue);
      expect(sm.content, 'Hel');
      expect(sm.sessionId, 's1', reason: 'falls back to the caller-provided session id');
    });

    test('assistant_message reads meta.status == interrupted too', () {
      final e = StreamEvent.fromJson({
        'type': 'assistant_message',
        'data': {
          'id': 'a3',
          'content': 'partial',
          'meta': {'status': 'interrupted', 'citations': []},
        },
      }) as AssistantMessageEvent;
      expect(e.toMessage('s1').interrupted, isTrue);
    });

    test('error — message and code', () {
      final e = StreamEvent.fromJson({
        'type': 'error',
        'data': {'code': 'busy', 'message': 'generation in progress'},
      }) as ErrorEvent;
      expect(e.code, 'busy');
      expect(e.isBusy, isTrue);
      expect(e.message, 'generation in progress');

      final bare = StreamEvent.fromJson({'type': 'error', 'data': 'boom'}) as ErrorEvent;
      expect(bare.message, 'boom');
      expect(bare.code, isNull);

      final empty = StreamEvent.fromJson({'type': 'error'}) as ErrorEvent;
      expect(empty.message, 'error');
    });

    test('unknown types are preserved, never thrown', () {
      final e = StreamEvent.fromJson({'type': 'pong'});
      expect(e, isA<UnknownEvent>());
      expect((e as UnknownEvent).type, 'pong');
      expect(StreamEvent.fromJson({}), isA<UnknownEvent>());
    });
  });

  group('ChatMessage.fromJson', () {
    test('marks a persisted partial reply as interrupted via meta.status', () {
      final m = ChatMessage.fromJson({
        'id': 'a1',
        'session_id': 's1',
        'role': 'assistant',
        'content': 'partial',
        'created_at': '2026-01-01T00:00:00Z',
        'meta': {'status': 'interrupted'},
      });
      expect(m.interrupted, isTrue);
      expect(m.streaming, isFalse);
    });

    test('defaults interrupted to false and parses meta citations/tool_calls', () {
      final m = ChatMessage.fromJson({
        'id': 'a1',
        'session_id': 's1',
        'role': 'assistant',
        'content': 'done',
        'tokens': 12,
        'created_at': '2026-01-01T00:00:00Z',
        'meta': {
          'citations': [
            {'document_id': 'd', 'document_name': 'n', 'chunk_index': 1, 'score': 0.1, 'excerpt': 'e'},
          ],
          'tool_calls': [
            {'tool': 'web_search', 'input': 'q', 'output': 'r'},
          ],
        },
      });
      expect(m.interrupted, isFalse);
      expect(m.tokens, 12);
      expect(m.citations, hasLength(1));
      expect(m.toolCalls.single.tool, 'web_search');
      expect(m.copyWith(interrupted: true).interrupted, isTrue);
    });
  });
}
