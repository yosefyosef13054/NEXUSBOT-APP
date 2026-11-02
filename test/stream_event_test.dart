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
      expect(
        (StreamEvent.fromJson({'type': 'usage', 'data': null}) as UsageEvent).totalTokens,
        isNull,
      );
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
            {
              'document_id': 'd1',
              'document_name': 'spec.pdf',
              'chunk_index': 0,
              'score': 0.5,
              'excerpt': 'x',
            },
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
            {
              'document_id': 'd',
              'document_name': 'n',
              'chunk_index': 1,
              'score': 0.1,
              'excerpt': 'e',
            },
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

  phase2Tests();
}

void phase2Tests() {
  group('Phase 2 events', () {
    test('approval_required carries the approval request', () {
      final e = StreamEvent.fromJson({
        'type': 'approval_required',
        'data': {
          'approval_id': 'ap1',
          'session_id': 's1',
          'message_id': 'a1',
          'expires_at': '2026-11-02T13:00:00+00:00',
          'tool_calls': [
            {
              'call_id': 'call_1',
              'tool': 'web_search',
              'input': {'query': 'x'},
              'description': 'Searches the web',
            },
          ],
        },
      });
      expect(e, isA<ApprovalRequiredEvent>());
      final a = (e as ApprovalRequiredEvent).approval;
      expect(a.approvalId, 'ap1');
      expect(a.sessionId, 's1');
      expect(a.messageId, 'a1');
      expect(a.expiresAt?.toUtc().hour, 13);
      expect(a.status, 'pending');
      expect(a.isPending, isTrue);
      expect(a.toolCalls.single.callId, 'call_1');
      expect(a.toolCalls.single.tool, 'web_search');
      expect(a.toolCalls.single.input, {'query': 'x'});
      expect(a.toolCalls.single.description, 'Searches the web');
      expect(a.copyWith(status: 'expired').isPending, isFalse);
    });

    test('done carries status and model', () {
      final paused = StreamEvent.fromJson({
        'type': 'done',
        'data': {
          'text': '',
          'status': 'awaiting_approval',
          'interrupted': false,
          'model': 'gpt-4o',
        },
      }) as DoneEvent;
      expect(paused.awaitingApproval, isTrue);
      expect(paused.interrupted, isFalse);
      expect(paused.model, 'gpt-4o');
      final plain = StreamEvent.fromJson({
        'type': 'done',
        'data': {'text': 'x'},
      }) as DoneEvent;
      expect(plain.awaitingApproval, isFalse);
      expect(plain.status, isNull);
      expect(plain.model, isNull);
    });

    test('assistant_message with status, approval and model', () {
      final e = StreamEvent.fromJson({
        'type': 'assistant_message',
        'data': {
          'id': 'a1',
          'content': '',
          'status': 'awaiting_approval',
          'model': 'gpt-4o-mini',
          'approval': {
            'approval_id': 'ap1',
            'session_id': 's1',
            'message_id': 'a1',
            'tool_calls': [
              {'call_id': 'c', 'tool': 'web_search'},
            ],
          },
          'meta': {'provider': 'openai'},
        },
      }) as AssistantMessageEvent;
      expect(e.awaitingApproval, isTrue);
      expect(e.model, 'gpt-4o-mini');
      final m = e.toMessage('s1');
      expect(m.awaitingApproval, isTrue);
      expect(m.approval?.approvalId, 'ap1');
      expect(m.model, 'gpt-4o-mini');
      expect(m.interrupted, isFalse);
      expect(m.copyWith(clearApproval: true).approval, isNull);
      expect(m.copyWith(clearStatus: true).awaitingApproval, isFalse);
    });

    test('assistant_message falls back to meta for status / approval / model', () {
      final m = (StreamEvent.fromJson({
        'type': 'assistant_message',
        'data': {
          'id': 'a1',
          'content': 'x',
          'meta': {
            'status': 'awaiting_approval',
            'model': 'claude',
            'approval': {'approval_id': 'ap2', 'session_id': 's1', 'message_id': 'a1'},
          },
        },
      }) as AssistantMessageEvent)
          .toMessage('s1');
      expect(m.awaitingApproval, isTrue);
      expect(m.approval?.approvalId, 'ap2');
      expect(m.model, 'claude');
    });

    test('structured citations', () {
      final e = StreamEvent.fromJson({
        'type': 'citations',
        'data': [
          {
            'document_id': 'd1',
            'document_name': 'spec.pdf',
            'chunk_id': 'ch1',
            'chunk_index': 3,
            'page': 4,
            'section': '2. Scope > 2.1 Goals',
            'start_index': 1200,
            'end_index': 1980,
            'collection_id': null,
            'score': 0.83,
            'match': 'hybrid',
            'excerpt': 'first 300 chars',
          },
          {
            'document_id': 'd2',
            'document_name': 'notes.md',
            'chunk_index': 0,
            'score': 0.5,
            'excerpt': '',
          },
        ],
      }) as CitationsEvent;
      final c = e.citations.first;
      expect(c.chunkId, 'ch1');
      expect(c.page, 4);
      expect(c.section, '2. Scope > 2.1 Goals');
      expect(c.startIndex, 1200);
      expect(c.endIndex, 1980);
      expect(c.collectionId, isNull);
      expect(c.match, 'hybrid');
      expect(c.locationLabel, 'p. 4 · 2. Scope > 2.1 Goals');
      expect(c.canOpen, isTrue);
      final legacy = e.citations.last;
      expect(legacy.chunkId, isNull);
      expect(legacy.match, isNull);
      expect(legacy.locationLabel, isNull);
      expect(legacy.canOpen, isFalse, reason: 'no chunk id → nothing to fetch');
    });

    test('tool_call frames carry call_id, latency and error', () {
      final end = StreamEvent.fromJson({
        'type': 'tool_call',
        'data': {
          'phase': 'end',
          'tool': 'calculator',
          'call_id': 'call_1',
          'input': {'expression': '2+2'},
          'output': 4,
          'latency_ms': 12,
        },
      }) as ToolCallEvent;
      expect(end.callId, 'call_1');
      expect(end.isTerminal, isTrue);
      final tc = end.toToolCall();
      expect(tc.callId, 'call_1');
      expect(tc.status, ToolCallStatus.ok);
      expect(tc.latencyMs, 12);
      expect(tc.output, '4');

      final failed = StreamEvent.fromJson({
        'type': 'tool_call',
        'data': {'phase': 'error', 'tool': 'web_search', 'call_id': 'c2', 'error': 'boom'},
      }) as ToolCallEvent;
      expect(failed.isTerminal, isTrue);
      expect(failed.toToolCall().status, ToolCallStatus.error);
      expect(failed.toToolCall().error, 'boom');

      final start = StreamEvent.fromJson({
        'type': 'tool_call',
        'data': {'phase': 'start', 'tool': 'web_search', 'call_id': 'c2'},
      }) as ToolCallEvent;
      expect(start.isTerminal, isFalse);
    });

    test('mergeToolCalls dedupes on call_id and appends id-less runs', () {
      final merged = mergeToolCalls(
        const [ToolCall(tool: 'a', callId: '1', output: 'old'), ToolCall(tool: 'b')],
        const [ToolCall(tool: 'a', callId: '1', output: 'new'), ToolCall(tool: 'c')],
      );
      expect(merged.map((t) => t.tool), ['a', 'b', 'c']);
      expect(merged.first.output, 'new');
    });

    test('error frames flag stale approvals', () {
      final conflict = StreamEvent.fromJson({
        'type': 'error',
        'data': {'code': 'conflict', 'message': 'resolved'},
      }) as ErrorEvent;
      expect(conflict.isStaleApproval, isTrue);
      final busy = StreamEvent.fromJson({
        'type': 'error',
        'data': {'code': 'busy'},
      }) as ErrorEvent;
      expect(busy.isStaleApproval, isFalse);
    });
  });

  group('ChatMessage.fromJson (Phase 2)', () {
    test('tool-role rows become one tool run with the content as output', () {
      final m = ChatMessage.fromJson({
        'id': 't1',
        'session_id': 's1',
        'role': 'tool',
        'content': '<tool output>',
        'tokens': 0,
        'created_at': '2026-01-01T00:00:00Z',
        'meta': {
          'tool': 'calculator',
          'call_id': 'call_1',
          'input': {'expression': '2+2'},
          'status': 'denied',
          'latency_ms': 12,
        },
      });
      expect(m.role, MessageRole.tool);
      expect(m.isToolRun, isTrue);
      final run = m.toolCalls.single;
      expect(run.tool, 'calculator');
      expect(run.callId, 'call_1');
      expect(run.input, {'expression': '2+2'});
      expect(run.output, '<tool output>');
      expect(run.status, ToolCallStatus.denied);
      expect(run.latencyMs, 12);
    });

    test('awaiting_approval rows carry meta.approval', () {
      final m = ChatMessage.fromJson({
        'id': 'a1',
        'session_id': 's1',
        'role': 'assistant',
        'content': '',
        'created_at': '2026-01-01T00:00:00Z',
        'meta': {
          'status': 'awaiting_approval',
          'model': 'gpt-4o-mini',
          'approval': {
            'approval_id': 'ap1',
            'session_id': 's1',
            'message_id': 'a1',
            'status': 'pending',
            'tool_calls': [
              {
                'call_id': 'c1',
                'tool': 'web_search',
                'input': {'query': 'q'},
              },
            ],
          },
        },
      });
      expect(m.awaitingApproval, isTrue);
      expect(m.status, 'awaiting_approval');
      expect(m.approval?.approvalId, 'ap1');
      expect(m.approval?.toolCalls.single.tool, 'web_search');
      expect(m.model, 'gpt-4o-mini');
      expect(m.interrupted, isFalse);
    });

    test('assistant rows dedupe meta.tool_calls on call_id', () {
      final m = ChatMessage.fromJson({
        'id': 'a1',
        'session_id': 's1',
        'role': 'assistant',
        'content': 'x',
        'created_at': '2026-01-01T00:00:00Z',
        'meta': {
          'tool_calls': [
            {'tool': 'calculator', 'call_id': 'c1', 'output': 'first'},
            {'tool': 'calculator', 'call_id': 'c1', 'output': 'final'},
          ],
        },
      });
      expect(m.toolCalls.single.output, 'final');
    });
  });

  group('ChatSession / SearchResult', () {
    test('session meta exposes collection_ids', () {
      final s = ChatSession.fromJson({
        'id': 's1',
        'title': 'T',
        'model': 'gpt-4o',
        'meta': {
          'collection_ids': ['c1', 'c2'],
        },
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      });
      expect(s.collectionIds, ['c1', 'c2']);
      expect(s.model, 'gpt-4o');
      expect(s.copyWith(meta: const {}).collectionIds, isNull);
    });

    test('search results keep highlight and rank', () {
      final r = SearchResult.fromJson({
        'session_id': 's1',
        'session_title': 'Invoices',
        'message_id': 'm1',
        'role': 'assistant',
        'snippet': 'The invoice total is 42',
        'highlight': 'The <mark>invoice</mark> total is 42',
        'rank': 0.42,
        'created_at': '2026-01-01T00:00:00Z',
      });
      expect(r.sessionTitle, 'Invoices');
      expect(r.highlight, contains('<mark>'));
      expect(r.rank, closeTo(0.42, 1e-9));
      expect(r.role, MessageRole.assistant);
    });
  });

  phase3Tests();
}

void phase3Tests() {
  group('Phase 3 events', () {
    test('user_message carries generation_id, parent_id and siblings', () {
      final e = StreamEvent.fromJson({
        'type': 'user_message',
        'data': {
          'id': 'u2',
          'content': 'edited',
          'generation_id': 'gen-1',
          'parent_id': 'a1',
          'siblings': {'index': 1, 'count': 2},
          'created_at': '2026-01-01T00:00:00Z',
        },
      }) as UserMessageEvent;
      expect(e.generationId, 'gen-1');
      expect(e.parentId, 'a1');
      final m = e.toMessage('s1');
      expect(m.generationId, 'gen-1');
      expect(m.parentId, 'a1');
      expect(m.siblings?.index, 1);
      expect(m.siblings?.count, 2);
      expect(m.siblings?.displayIndex, 2);
      expect(m.siblings?.hasSiblings, isTrue);
    });

    test('done and assistant_message carry generation_id; memories_used is read from meta', () {
      final done = StreamEvent.fromJson({
        'type': 'done',
        'data': {'text': 'x', 'generation_id': 'gen-1'},
      }) as DoneEvent;
      expect(done.generationId, 'gen-1');

      final e = StreamEvent.fromJson({
        'type': 'assistant_message',
        'data': {
          'id': 'a2',
          'content': 'Personalised answer',
          'parent_id': 'u2',
          'generation_id': 'gen-1',
          'meta': {
            'memories_used': ['m1', 'm2'],
            'feedback': {'rating': 1, 'comment': null},
          },
        },
      }) as AssistantMessageEvent;
      expect(e.generationId, 'gen-1');
      expect(e.memoriesUsed, ['m1', 'm2']);
      final m = e.toMessage('s1');
      expect(m.parentId, 'u2');
      expect(m.generationId, 'gen-1');
      expect(m.memoriesUsed, ['m1', 'm2']);
      expect(m.feedback?.isUp, isTrue);
      expect(m.copyWith(clearFeedback: true).feedback, isNull);
      expect(m.copyWith(clearSiblings: true).siblings, isNull);
    });

    test('error frames expose quota details and transport drops', () {
      final quota = StreamEvent.fromJson({
        'type': 'error',
        'data': {
          'code': 'quota_exceeded',
          'message': 'budget spent',
          'details': {
            'budget_usd_per_month': 10,
            'used_usd': 10.2,
            'resets_at': '2026-12-01T00:00:00Z',
          },
        },
      }) as ErrorEvent;
      expect(quota.isQuotaExceeded, isTrue);
      expect(quota.details?['used_usd'], 10.2);
      expect(quota.isTransportError, isFalse);
      const drop = ErrorEvent(message: 'socket closed', code: 'network_error');
      expect(drop.isTransportError, isTrue);
      expect(drop.isQuotaExceeded, isFalse);
    });
  });

  group('Phase 3 models', () {
    test('history rows parse parent_id, siblings, feedback and memories_used', () {
      final m = ChatMessage.fromJson({
        'id': 'a1',
        'session_id': 's1',
        'parent_id': 'u1',
        'role': 'assistant',
        'content': 'x',
        'created_at': '2026-01-01T00:00:00Z',
        'siblings': {'index': 0, 'count': 3},
        'meta': {
          'feedback': {'rating': -1, 'comment': 'too long'},
          'memories_used': ['m1'],
          'generation_id': 'gen-0',
        },
      });
      expect(m.parentId, 'u1');
      expect(m.siblings?.displayIndex, 1);
      expect(m.siblings?.count, 3);
      expect(m.feedback?.isDown, isTrue);
      expect(m.feedback?.comment, 'too long');
      expect(m.memoriesUsed, ['m1']);
      expect(m.generationId, 'gen-0');
      expect(m.isPendingUser, isFalse);

      final plain = ChatMessage.fromJson({
        'id': 'u1',
        'session_id': 's1',
        'role': 'user',
        'content': 'q',
        'created_at': '2026-01-01T00:00:00Z',
      });
      expect(plain.siblings, isNull);
      expect(plain.feedback, isNull);
      expect(plain.memoriesUsed, isEmpty);
    });

    test('sessions expose org_id, assistant_id and active_leaf_id', () {
      final s = ChatSession.fromJson({
        'id': 's1',
        'org_id': 'o1',
        'assistant_id': 'as1',
        'active_leaf_id': 'a9',
        'title': 'T',
        'meta': {},
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      });
      expect(s.orgId, 'o1');
      expect(s.assistantId, 'as1');
      expect(s.activeLeafId, 'a9');
      expect(s.copyWith(clearAssistantId: true).assistantId, isNull);
      expect(s.copyWith(assistantId: 'as2').assistantId, 'as2');
    });

    test('siblings, active generation and background responses', () {
      final siblings = SiblingsResult.fromJson({
        'items': [
          {
            'id': 'a1',
            'session_id': 's1',
            'role': 'assistant',
            'content': 'x',
            'created_at': '2026-01-01T00:00:00Z',
          },
          {
            'id': 'a2',
            'session_id': 's1',
            'role': 'assistant',
            'content': 'y',
            'created_at': '2026-01-01T00:00:01Z',
          },
        ],
        'active_index': 1,
      });
      expect(siblings.items.map((m) => m.id), ['a1', 'a2']);
      expect(siblings.activeIndex, 1);

      final running = ActiveGeneration.fromJson({
        'generation_id': 'g1',
        'started_at': '2026-01-01T00:00:00Z',
        'status': 'running',
      });
      expect(running.isRunning, isTrue);
      expect(
        ActiveGeneration.fromJson({'generation_id': 'g1', 'status': 'done'}).isRunning,
        isFalse,
      );

      final bg = BackgroundSend.fromJson({
        'generation_id': 'g2',
        'user_message': {
          'id': 'u1',
          'session_id': 's1',
          'role': 'user',
          'content': 'q',
          'created_at': '2026-01-01T00:00:00Z',
        },
      });
      expect(bg.generationId, 'g2');
      expect(bg.userMessage?.id, 'u1');
    });
  });
}
