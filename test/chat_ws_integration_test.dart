import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/api_exception.dart';
import 'package:nexusbot/features/chat/chat_models.dart';
import 'package:nexusbot/features/chat/chat_ws.dart';

/// Drives [ChatWebSocket] against a loopback server that speaks the Phase 1
/// protocol: auth-first frame, `auth_ok`, `user_message` → event stream,
/// `stop` → interrupted `done` + `assistant_message`, `busy`, `ping`/`pong`.
void main() {
  late HttpServer server;
  late String baseUrl;
  final received = <Map<String, dynamic>>[];
  final closeCodes = <int?>[];

  Future<void> serve(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    // Contract: no `?token=` in the query string any more.
    expect(req.uri.queryParameters, isNot(contains('token')));
    expect(req.uri.path, '/ws/sessions/s1');

    final socket = await WebSocketTransformer.upgrade(req);
    void send(Map<String, Object?> frame) => socket.add(jsonEncode(frame));

    var authed = false;
    var generating = false;
    var stopRequested = false;

    socket.listen(
      (raw) async {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        received.add(frame);
        switch (frame['type']) {
          case 'auth':
            if (frame['token'] == 'good-token') {
              authed = true;
              send({
                'type': 'auth_ok',
                'data': {'user_id': 'u1'},
              });
              // Unsolicited keep-alive answer; must never reach the app.
              send({'type': 'pong'});
            } else {
              send({
                'type': 'error',
                'data': {'code': 'unauthorized', 'message': 'bad token'},
              });
              await socket.close(1008, 'unauthorized');
            }
          case 'ping':
            send({'type': 'pong'});
          case 'stop':
            stopRequested = true;
          case 'approval':
            if (!authed) return;
            send({
              'type': 'tool_call',
              'data': {'phase': 'end', 'tool': 'web_search', 'call_id': 'call_1', 'output': 'r'},
            });
            send({'type': 'token', 'data': 'Approved.'});
            send({
              'type': 'done',
              'data': {'text': 'Approved.', 'status': 'ok', 'model': 'gpt-4o-mini'},
            });
            send({
              'type': 'assistant_message',
              'data': {'id': 'a-placeholder', 'content': 'Approved.', 'status': 'ok'},
            });
          case 'user_message':
            if (!authed) {
              send({
                'type': 'error',
                'data': {'code': 'unauthorized', 'message': 'auth first'},
              });
              return;
            }
            if (generating) {
              send({
                'type': 'error',
                'data': {'code': 'busy', 'message': 'generation in progress'},
              });
              return;
            }
            generating = true;
            stopRequested = false;
            send({
              'type': 'user_message',
              'data': {
                'id': 'u-1',
                'content': frame['content'],
                'created_at': '2026-01-01T00:00:00Z',
              },
            });
            final text = StringBuffer();
            for (var i = 0; i < 6; i++) {
              if (stopRequested) break;
              send({'type': 'token', 'data': 't$i '});
              text.write('t$i ');
              await Future<void>.delayed(const Duration(milliseconds: 25));
            }
            send({
              'type': 'usage',
              'data': {'prompt_tokens': 3, 'completion_tokens': 6, 'total_tokens': 9},
            });
            send({
              'type': 'done',
              'data': {'text': text.toString(), 'latency_ms': 150, 'interrupted': stopRequested},
            });
            send({
              'type': 'assistant_message',
              'data': {
                'id': 'a-1',
                'content': text.toString(),
                'created_at': '2026-01-01T00:00:01Z',
                'interrupted': stopRequested,
              },
            });
            generating = false;
        }
      },
      onDone: () => closeCodes.add(socket.closeCode),
    );
  }

  setUp(() async {
    received.clear();
    closeCodes.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(serve);
    baseUrl = 'ws://127.0.0.1:${server.port}';
  });

  tearDown(() => server.close(force: true));

  Future<ChatWebSocket> connect([String token = 'good-token', String? orgId]) =>
      ChatWebSocket.connect(sessionId: 's1', token: token, orgId: orgId, baseUrl: baseUrl);

  /// Collects events until the terminal `assistant_message` / `error`.
  Future<List<StreamEvent>> collect(ChatWebSocket ws) async {
    final events = <StreamEvent>[];
    await for (final e in ws.events) {
      events.add(e);
      if (e is AssistantMessageEvent || e is ErrorEvent) break;
    }
    return events;
  }

  test('authenticates with the first frame, then streams a full turn', () async {
    final ws = await connect();
    expect(received.first['type'], 'auth');
    expect(received.first['token'], 'good-token');

    ws.sendUserMessage(content: 'hello', useRag: false, useTools: true);
    final events = await collect(ws).timeout(const Duration(seconds: 5));
    await ws.close();

    final userFrame = received.firstWhere((f) => f['type'] == 'user_message');
    expect(userFrame, {
      'type': 'user_message',
      'content': 'hello',
      'use_rag': false,
      'use_tools': true,
      'tool_names': null,
      'temperature': null,
    });

    expect(events.first, isA<UserMessageEvent>());
    expect(events.whereType<TokenEvent>().map((e) => e.token).join(), 't0 t1 t2 t3 t4 t5 ');
    expect(events.whereType<UsageEvent>().single.totalTokens, 9);
    final done = events.whereType<DoneEvent>().single;
    expect(done.interrupted, isFalse);
    final last = events.last as AssistantMessageEvent;
    expect(last.id, 'a-1');
    expect(last.interrupted, isFalse);
    expect(
      events.whereType<UnknownEvent>(),
      isEmpty,
      reason: 'auth_ok/pong are consumed internally',
    );
  });

  test('the auth frame carries org_id only when a workspace other than the personal one is active',
      () async {
    final plain = await connect();
    await plain.close();
    expect(received.first.containsKey('org_id'), isFalse);

    received.clear();
    final scoped = await connect('good-token', 'org-7');
    await scoped.close();
    expect(received.first, {'type': 'auth', 'token': 'good-token', 'org_id': 'org-7'});
  });

  test('a rejected auth frame fails connect with an auth ApiException', () async {
    try {
      await connect('bad-token');
      fail('expected ApiException');
    } on ApiException catch (e) {
      expect(e.isAuth, isTrue);
      expect(e.message, 'bad token');
    }
  });

  test('stop cancels generation; done and assistant_message carry interrupted: true', () async {
    final ws = await connect();
    ws.sendUserMessage(content: 'long answer please');

    final events = <StreamEvent>[];
    await for (final e in ws.events) {
      events.add(e);
      if (e is TokenEvent && events.whereType<TokenEvent>().length == 2) ws.sendStop();
      if (e is AssistantMessageEvent) break;
    }
    await ws.close();

    expect(received.any((f) => f['type'] == 'stop'), isTrue);
    expect(events.whereType<TokenEvent>().length, lessThan(6), reason: 'generation stopped early');
    expect(events.whereType<DoneEvent>().single.interrupted, isTrue);
    final last = events.last as AssistantMessageEvent;
    expect(last.interrupted, isTrue);
    expect(last.toMessage('s1').content, isNotEmpty, reason: 'partial text is persisted');
  });

  test('a second user_message while generating yields a busy error', () async {
    final ws = await connect();
    ws.sendUserMessage(content: 'first');
    ws.sendUserMessage(content: 'second');

    final events = <StreamEvent>[];
    await for (final e in ws.events) {
      events.add(e);
      if (e is ErrorEvent && e.isBusy) break;
    }
    await ws.close();
    expect(events.whereType<ErrorEvent>().single.code, 'busy');
  });

  test('user_message carries model and collection_ids only when set', () async {
    final ws = await connect();
    ws.sendUserMessage(
      content: 'scoped',
      model: 'gpt-4o',
      collectionIds: const ['c1', 'c2'],
      toolNames: const ['calculator'],
    );
    await collect(ws).timeout(const Duration(seconds: 5));
    await ws.close();
    final frame = received.firstWhere((f) => f['type'] == 'user_message');
    expect(frame['model'], 'gpt-4o');
    expect(frame['collection_ids'], ['c1', 'c2']);
    expect(frame['tool_names'], ['calculator']);
  });

  test('approval frame resumes the turn on the same socket', () async {
    final ws = await connect();
    ws.sendApproval(approvalId: 'ap1', decision: ApprovalDecision.approve);
    final events = await collect(ws).timeout(const Duration(seconds: 5));
    await ws.close();

    expect(
      received.firstWhere((f) => f['type'] == 'approval'),
      {'type': 'approval', 'approval_id': 'ap1', 'decision': 'approve'},
    );
    expect(events.first, isA<ToolCallEvent>());
    expect((events.first as ToolCallEvent).callId, 'call_1');
    expect(events.whereType<DoneEvent>().single.model, 'gpt-4o-mini');
    expect((events.last as AssistantMessageEvent).id, 'a-placeholder');
  });

  test('close shuts the socket down cleanly', () async {
    final ws = await connect();
    await ws.close();
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (closeCodes.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(closeCodes, isNotEmpty, reason: 'server saw the close handshake');
  });
}
