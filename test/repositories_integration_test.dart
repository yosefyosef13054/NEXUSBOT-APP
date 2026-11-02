import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/api_client.dart';
import 'package:nexusbot/features/auth/auth_repository.dart';
import 'package:nexusbot/features/chat/chat_models.dart';
import 'package:nexusbot/features/chat/chat_repository.dart';
import 'package:nexusbot/features/collections/collections_repository.dart';
import 'package:nexusbot/features/documents/documents_repository.dart';
import 'package:nexusbot/features/models/model_info.dart';
import 'package:nexusbot/features/models/models_repository.dart';
import 'package:nexusbot/features/tools/tools_repository.dart';

import 'helpers/fakes.dart';

/// Drives the Phase 2 repositories against a loopback HTTP server speaking
/// the backend contract: `/models`, `/tools`, `/collections`, the document
/// chunk viewer and collection filter, `/documents/from-url`, approvals,
/// `/search` and `PATCH /auth/me {default_model}`.
void main() {
  late HttpServer server;
  late ApiClient client;
  const access = 'access-ok';

  /// Every request the server saw: method, path, query, decoded JSON body.
  final seen = <({String method, String path, Map<String, String> query, Object? body})>[];

  Future<void> json(HttpResponse res, Object body, {int status = 200}) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }

  Future<void> envelope(HttpResponse res, int status, String code, String message) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.headers.set('x-request-id', 'req-1');
    res.write(
      jsonEncode({
        'error': {'code': code, 'message': message, 'details': {}},
        'request_id': 'req-1',
      }),
    );
    await res.close();
  }

  Map<String, dynamic> collection(String id, String name, {int docs = 0}) => {
        'id': id,
        'name': name,
        'description': 'about $name',
        'document_count': docs,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      };

  Map<String, dynamic> document(String id, {String? collectionId}) => {
        'id': id,
        'name': '$id.pdf',
        'mime_type': 'application/pdf',
        'size_bytes': 10,
        'status': 'ready',
        'collection_id': collectionId,
        'created_at': '2026-01-01T00:00:00Z',
        'meta': {},
      };

  const approval = {
    'approval_id': 'ap1',
    'session_id': 's1',
    'message_id': 'a1',
    'expires_at': '2026-11-02T13:00:00+00:00',
    'status': 'pending',
    'tool_calls': [
      {'call_id': 'call_1', 'tool': 'web_search', 'input': {'query': 'x'}, 'description': 'web'},
    ],
  };

  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    if (req.headers.value('authorization') != 'Bearer $access') {
      await envelope(res, 401, 'unauthorized', 'bad token');
      return;
    }
    final raw = await utf8.decodeStream(req);
    final body = raw.isEmpty ? null : jsonDecode(raw);
    seen.add((method: req.method, path: req.uri.path, query: req.uri.queryParameters, body: body));

    switch ((req.method, req.uri.path)) {
      case ('GET', '/models'):
        await json(res, {
          'default_model': 'gpt-4o-mini',
          'items': [
            {
              'id': 'gpt-4o-mini',
              'provider': 'openai',
              'display_name': 'GPT-4o mini',
              'context_window': 128000,
              'max_output_tokens': 16384,
              'supports_tools': true,
              'supports_vision': true,
              'supports_streaming': true,
              'input_usd_per_1m': 0.15,
              'output_usd_per_1m': 0.60,
              'tags': ['fast', 'cheap'],
              'is_default': true,
            },
            {
              'id': 'llama3',
              'provider': 'ollama',
              'display_name': 'Llama 3',
              'context_window': 8192,
              'supports_tools': false,
              'input_usd_per_1m': null,
              'output_usd_per_1m': null,
              'tags': [],
              'is_default': false,
            },
          ],
        });

      case ('GET', '/tools'):
        await json(res, {
          'items': [
            {'name': 'calculator', 'description': 'Math', 'requires_approval': false},
            {'name': 'web_search', 'description': 'Web', 'requires_approval': true},
          ],
        });

      case ('POST', '/collections'):
        final b = body as Map<String, dynamic>;
        await json(res, collection('c-new', b['name'] as String), status: 201);
      case ('GET', '/collections'):
        final page = int.parse(req.uri.queryParameters['page'] ?? '1');
        await json(res, {
          'items': page == 1 ? [collection('c1', 'Specs', docs: 2)] : [collection('c2', 'Legal')],
          'total': 2,
          'page': page,
          'page_size': 1,
        });
      case ('GET', '/collections/c1'):
        await json(res, collection('c1', 'Specs', docs: 2));
      case ('PATCH', '/collections/c1'):
        final b = body as Map<String, dynamic>;
        await json(res, collection('c1', (b['name'] as String?) ?? 'Specs'));
      case ('DELETE', '/collections/c1'):
        await json(res, {'ok': true});

      case ('GET', '/documents'):
        final filter = req.uri.queryParameters['collection_id'];
        await json(res, {
          'items': [
            document('d1', collectionId: 'c1'),
            if (filter == null) document('d2'),
          ],
          'total': filter == null ? 2 : 1,
          'page': 1,
          'page_size': 50,
        });
      case ('PATCH', '/documents/d2'):
        final b = body as Map<String, dynamic>;
        await json(res, document('d2', collectionId: b['collection_id'] as String?));
      case ('POST', '/documents/from-url'):
        final b = body as Map<String, dynamic>;
        if ((b['url'] as String).contains('private')) {
          await envelope(res, 422, 'validation_error', 'URL is private or unreachable');
          return;
        }
        await json(
          res,
          {'document': document('d-url', collectionId: b['collection_id'] as String?), 'queued': true},
          status: 202,
        );
      case ('GET', '/documents/d1/chunks'):
        await json(res, {
          'items': [
            {'id': 'ch1', 'chunk_index': 0, 'content': 'first', 'page': 1, 'tokens': 3},
            {'id': 'ch2', 'chunk_index': 1, 'content': 'second', 'page': 1, 'tokens': 3},
          ],
          'total': 2,
          'page': 1,
          'page_size': 50,
        });
      case ('GET', '/documents/d1/chunks/ch1'):
        await json(res, {
          'id': 'ch1',
          'chunk_index': 3,
          'content': 'The full chunk text.',
          'page': 4,
          'section': '2. Scope > 2.1 Goals',
          'start_index': 1200,
          'end_index': 1980,
          'tokens': 5,
        });
      case ('GET', '/documents/d1/chunks/missing'):
        await envelope(res, 404, 'not_found', 'Chunk not found');

      case ('GET', '/sessions/s1/approvals'):
        await json(res, {'items': [approval]});
      case ('POST', '/sessions/s1/approvals/ap1'):
        if (req.headers.value('accept') != 'text/event-stream') {
          await envelope(res, 406, 'not_acceptable', 'Accept must be text/event-stream');
          return;
        }
        res.headers.contentType = ContentType('text', 'event-stream');
        res.bufferOutput = false;
        res.write(': connected\n\n');
        for (final frame in [
          {'type': 'tool_call', 'data': {'phase': 'end', 'tool': 'web_search', 'call_id': 'call_1', 'output': 'r'}},
          {'type': 'token', 'data': 'Done'},
          {'type': 'done', 'data': {'text': 'Done', 'status': 'ok', 'model': 'gpt-4o-mini'}},
          {'type': 'assistant_message', 'data': {'id': 'a1', 'content': 'Done', 'status': 'ok'}},
        ]) {
          res.write('data: ${jsonEncode(frame)}\n\n');
        }
        await res.close();
      case ('POST', '/sessions/s1/approvals/ap-old'):
        await envelope(res, 409, 'conflict', 'Approval already resolved');

      case ('POST', '/sessions/s1/messages'):
        final b = body as Map<String, dynamic>;
        await json(res, {
          'user_message': {
            'id': 'u1',
            'session_id': 's1',
            'role': 'user',
            'content': b['content'],
            'created_at': '2026-01-01T00:00:00Z',
          },
          'tool_messages': [
            {
              'id': 't1',
              'session_id': 's1',
              'role': 'tool',
              'content': '4',
              'created_at': '2026-01-01T00:00:01Z',
              'meta': {'tool': 'calculator', 'call_id': 'call_1', 'status': 'ok', 'latency_ms': 3},
            },
          ],
          'assistant_message': {
            'id': 'a1',
            'session_id': 's1',
            'role': 'assistant',
            'content': 'It is 4.',
            'created_at': '2026-01-01T00:00:02Z',
            'meta': {'model': 'gpt-4o-mini', 'status': 'ok'},
          },
          'citations': [],
          'tool_calls': [],
          'usage': {},
          'approval': null,
        });

      case ('PATCH', '/sessions/s1'):
        final b = body as Map<String, dynamic>;
        await json(res, {
          'id': 's1',
          'title': 'T',
          'model': b['model'],
          'meta': b['meta'] ?? {},
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        });

      case ('POST', '/search'):
        await json(res, [
          {
            'session_id': 's1',
            'session_title': 'Invoices',
            'message_id': 'm1',
            'role': 'assistant',
            'snippet': 'The invoice total is 42',
            'highlight': 'The <mark>invoice</mark> total is 42',
            'rank': 0.9,
            'created_at': '2026-01-01T00:00:00Z',
          },
        ]);

      case ('PATCH', '/auth/me'):
        final b = body as Map<String, dynamic>;
        await json(res, {
          'id': 'u1',
          'email': 'a@b.com',
          'role': 'user',
          'default_model': b['default_model'],
        });

      default:
        await envelope(res, 404, 'not_found', 'no route');
    }
  }

  setUp(() async {
    seen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handle);
    client = ApiClient.create(
      MemoryTokenStorage(access: access, refresh: 'r'),
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
  });

  tearDown(() async {
    client.dio.close(force: true);
    await server.close(force: true);
  });

  test('models: GET /models → catalog with labels and default resolution', () async {
    final catalog = await ModelsRepository(client).list();
    expect(catalog.defaultModel, 'gpt-4o-mini');
    expect(catalog.items.map((m) => m.id), ['gpt-4o-mini', 'llama3']);
    final mini = catalog.byId('gpt-4o-mini')!;
    expect(mini.provider, 'openai');
    expect(mini.displayName, 'GPT-4o mini');
    expect(mini.contextLabel, '128k ctx');
    expect(mini.priceLabel, r'$0.15 / $0.60 per 1M');
    expect(mini.tags, ['fast', 'cheap']);
    expect(mini.isDefault, isTrue);
    final llama = catalog.byId('llama3')!;
    expect(llama.priceLabel, isNull);
    expect(llama.supportsTools, isFalse);
    expect(llama.contextLabel, '8.2k ctx');

    expect(
      resolveDefaultModel(catalog: catalog, preferred: 'gpt-4-turbo'),
      'gpt-4o-mini',
      reason: 'unknown local preference falls back to the server default',
    );
    expect(resolveDefaultModel(catalog: catalog, preferred: 'llama3'), 'llama3');
    expect(
      resolveDefaultModel(catalog: catalog, userDefault: 'llama3', preferred: 'gpt-4o-mini'),
      'llama3',
      reason: 'the account default wins',
    );
    expect(resolveDefaultModel(catalog: ModelCatalog.empty, preferred: 'x'), isNull);
    expect(catalog.labelFor('nope'), 'nope');
  });

  test('tools: GET /tools → list; default selection skips approval tools', () async {
    final tools = await ToolsRepository(client).list();
    expect(tools.map((t) => t.name), ['calculator', 'web_search']);
    expect(tools.last.requiresApproval, isTrue);
    expect(defaultToolSelection(tools), ['calculator']);
  });

  test('collections: create, list (paged), get, update, delete', () async {
    final repo = CollectionsRepository(client);

    final created = await repo.create(name: 'Specs', description: 'd');
    expect(created.id, 'c-new');
    expect(seen.last.body, {'name': 'Specs', 'description': 'd'});

    final page = await repo.list(page: 1, pageSize: 1);
    expect(page.items.single.name, 'Specs');
    expect(page.items.single.documentCount, 2);
    expect(page.total, 2);
    expect(page.hasMore, isTrue);
    expect(seen.last.query, {'page': '1', 'page_size': '1'});

    final all = await repo.listAll();
    expect(all.map((c) => c.id), ['c1', 'c2'], reason: 'follows pagination');

    expect((await repo.get('c1')).description, 'about Specs');

    final renamed = await repo.update('c1', name: 'Specifications');
    expect(renamed.name, 'Specifications');
    expect(seen.last.body, {'name': 'Specifications'});

    await repo.delete('c1', deleteDocuments: true);
    expect(seen.last.method, 'DELETE');
    expect(seen.last.query, {'delete_documents': 'true'});
  });

  test('documents: collection filter, move, add from URL (422 surfaced)', () async {
    final repo = DocumentsRepository(client);

    final all = await repo.list();
    expect(all.map((d) => d.id), ['d1', 'd2']);
    expect(all.first.collectionId, 'c1');
    expect(seen.last.query.containsKey('collection_id'), isFalse);

    final filtered = await repo.list(collectionId: 'c1');
    expect(filtered.map((d) => d.id), ['d1']);
    expect(seen.last.query['collection_id'], 'c1');

    final moved = await repo.moveToCollection('d2', 'c1');
    expect(moved.collectionId, 'c1');
    expect(seen.last.body, {'collection_id': 'c1'});
    final unassigned = await repo.moveToCollection('d2', null);
    expect(unassigned.collectionId, isNull);
    expect(seen.last.body, {'collection_id': null}, reason: 'null is sent explicitly to unassign');

    final added = await repo.addFromUrl(url: 'https://example.com/a', collectionId: 'c1');
    expect(added.queued, isTrue);
    expect(added.document.id, 'd-url');
    expect(seen.last.body, {'url': 'https://example.com/a', 'collection_id': 'c1'});

    try {
      await repo.addFromUrl(url: 'https://private.example/x');
      fail('expected ApiException');
    } on ApiException catch (e) {
      expect(e.statusCode, 422);
      expect(e.code, 'validation_error');
      expect(e.message, 'URL is private or unreachable');
    }
  });

  test('documents: chunk viewer endpoints', () async {
    final repo = DocumentsRepository(client);
    final chunk = await repo.getChunk('d1', 'ch1');
    expect(chunk.id, 'ch1');
    expect(chunk.chunkIndex, 3);
    expect(chunk.content, 'The full chunk text.');
    expect(chunk.page, 4);
    expect(chunk.section, '2. Scope > 2.1 Goals');
    expect(chunk.startIndex, 1200);
    expect(chunk.endIndex, 1980);
    expect(chunk.tokens, 5);

    final page = await repo.listChunks('d1');
    expect(page.items.map((c) => c.id), ['ch1', 'ch2']);
    expect(page.total, 2);
    expect(page.hasMore, isFalse);
    expect(seen.last.query, {'page': '1', 'page_size': '50'});

    try {
      await repo.getChunk('d1', 'missing');
      fail('expected ApiException');
    } on ApiException catch (e) {
      expect(e.statusCode, 404);
    }
  });

  test('approvals: pending list and SSE resolution', () async {
    final repo = ChatRepository(client);
    final pending = await repo.listPendingApprovals('s1');
    expect(seen.last.query, {'status': 'pending'});
    expect(pending.single.approvalId, 'ap1');
    expect(pending.single.isPending, isTrue);
    expect(pending.single.toolCalls.single.tool, 'web_search');

    final turn = await repo.resolveApproval(
      sessionId: 's1',
      approvalId: 'ap1',
      decision: ApprovalDecision.approve,
    );
    expect(seen.last.body, {'decision': 'approve'});
    final events = await turn.events.toList();
    expect(events.map((e) => e.runtimeType), [
      ToolCallEvent,
      TokenEvent,
      DoneEvent,
      AssistantMessageEvent,
    ]);
    final last = events.last as AssistantMessageEvent;
    expect(last.id, 'a1', reason: 'continuation lands on the placeholder id');
    expect((events[2] as DoneEvent).model, 'gpt-4o-mini');

    try {
      await repo.resolveApproval(
        sessionId: 's1',
        approvalId: 'ap-old',
        decision: ApprovalDecision.deny,
      );
      fail('expected ApiException');
    } on ApiException catch (e) {
      expect(e.statusCode, 409);
      expect(e.code, 'conflict');
    }
  });

  test('blocking send: body carries the overrides; tool_messages come back as rows', () async {
    final result = await ChatRepository(client).sendBlocking(
      sessionId: 's1',
      content: '2+2?',
      toolNames: ['calculator'],
      model: 'gpt-4o-mini',
      collectionIds: ['c1'],
    );
    expect(seen.last.body, {
      'content': '2+2?',
      'use_rag': true,
      'use_tools': true,
      'tool_names': ['calculator'],
      'temperature': null,
      'model': 'gpt-4o-mini',
      'collection_ids': ['c1'],
    });
    expect(result.userMessage?.id, 'u1');
    expect(result.toolMessages.single.isToolRun, isTrue);
    expect(result.toolMessages.single.toolCalls.single.latencyMs, 3);
    expect(result.assistantMessage.model, 'gpt-4o-mini');
    expect(result.replyRows.map((m) => m.id), ['t1', 'a1']);
  });

  test('sessions: PATCH model / meta.collection_ids', () async {
    final repo = ChatRepository(client);
    final s = await repo.updateSession('s1', model: 'llama3');
    expect(s.model, 'llama3');
    expect(seen.last.body, {'model': 'llama3'});
    final scoped = await repo.updateSession('s1', meta: {'collection_ids': ['c1']});
    expect(scoped.collectionIds, ['c1']);
    expect(seen.last.body, {
      'meta': {'collection_ids': ['c1']},
    });
  });

  test('search: POST /search returns highlighted hits', () async {
    final hits = await ChatRepository(client).search('invoice', limit: 5);
    expect(seen.last.body, {'query': 'invoice', 'limit': 5});
    expect(hits.single.sessionId, 's1');
    expect(hits.single.highlight, 'The <mark>invoice</mark> total is 42');
    expect(hits.single.rank, 0.9);
  });

  test('auth: PATCH /auth/me {default_model}', () async {
    final repo = AuthRepository(client);
    final user = await repo.setDefaultModel('llama3');
    expect(user.defaultModel, 'llama3');
    expect(seen.last.body, {'default_model': 'llama3'});
    final cleared = await repo.setDefaultModel(null);
    expect(cleared.defaultModel, isNull);
    expect(seen.last.body, {'default_model': null});
  });
}
