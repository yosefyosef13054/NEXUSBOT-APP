import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/api_client.dart';

import 'helpers/fakes.dart';

/// End-to-end checks of [ApiClient] against a real loopback HTTP server:
/// the error envelope mapping, the single-flight 401 refresh through the
/// real interceptor, and — the one that cannot be unit tested — that
/// cancelling an SSE subscription really closes the TCP connection so the
/// server sees the disconnect.
void main() {
  late HttpServer server;
  late MemoryTokenStorage tokens;
  late ApiClient client;

  var refreshCalls = 0;
  var streamFramesSent = 0;
  var shuttingDown = false;
  const validAccess = 'access-new';

  Future<void> writeEnvelope(
    HttpResponse res,
    int status,
    String code,
    String message, {
    String requestId = 'req-0123456789abcdef',
  }) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.headers.set('x-request-id', requestId);
    res.write(
      jsonEncode({
        'error': {'code': code, 'message': message, 'details': {}},
        'request_id': requestId,
      }),
    );
    await res.close();
  }

  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    final auth = req.headers.value('authorization');

    switch ((req.method, req.uri.path)) {
      case ('POST', '/auth/refresh'):
        refreshCalls++;
        final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
        if (body['refresh_token'] != 'refresh-1') {
          await writeEnvelope(res, 401, 'unauthorized', 'refresh token revoked');
          return;
        }
        res.headers.contentType = ContentType.json;
        res.write(
          jsonEncode({
            'access_token': validAccess,
            'refresh_token': 'refresh-2',
            'token_type': 'bearer',
            'expires_in': 900,
          }),
        );
        await res.close();

      case ('GET', '/ping'):
        if (auth != 'Bearer $validAccess') {
          await writeEnvelope(res, 401, 'unauthorized', 'bad token');
          return;
        }
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'ok': true}));
        await res.close();

      case ('GET', '/missing'):
        await writeEnvelope(res, 404, 'not_found', 'Session not found');

      case ('POST', '/stream'):
        if (auth != 'Bearer $validAccess') {
          await writeEnvelope(res, 401, 'unauthorized', 'bad token');
          return;
        }
        if (req.headers.value('accept') != 'text/event-stream') {
          await writeEnvelope(res, 406, 'not_acceptable', 'Accept must be text/event-stream');
          return;
        }
        res.headers.contentType = ContentType('text', 'event-stream');
        res.bufferOutput = false;
        // Stream until the test shuts the server down. Writes to a socket the
        // client destroyed are silently dropped by dart:io, so the server
        // observes a disconnect through connectionsInfo(), not write errors.
        try {
          while (!shuttingDown && streamFramesSent < 2000) {
            res.write('data: {"type":"token","data":"x"}\n\n');
            await res.flush();
            streamFramesSent++;
            await Future<void>.delayed(const Duration(milliseconds: 15));
          }
          await res.close();
        } catch (_) {
          // Connection gone.
        }

      case ('POST', '/stream-limited'):
        await writeEnvelope(res, 429, 'rate_limited', 'Too many requests');

      default:
        await writeEnvelope(res, 404, 'not_found', 'no route');
    }
  }

  setUp(() async {
    refreshCalls = 0;
    shuttingDown = false;
    streamFramesSent = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handle);
    tokens = MemoryTokenStorage(access: 'access-old', refresh: 'refresh-1');
    client = ApiClient.create(tokens, baseUrl: 'http://127.0.0.1:${server.port}');
  });

  tearDown(() async {
    shuttingDown = true;
    client.dio.close(force: true);
    await server.close(force: true);
  });

  test('non-2xx responses become ApiException carrying the request id', () async {
    tokens.access = validAccess;
    try {
      await client.request<Map<String, dynamic>>('/missing');
      fail('expected ApiException');
    } on ApiException catch (e) {
      expect(e.code, 'not_found');
      expect(e.statusCode, 404);
      expect(e.message, 'Session not found');
      expect(e.requestId, 'req-0123456789abcdef');
      expect(e.shortRequestId, 'req-0123');
      expect(e.userMessage, 'Session not found (ref req-0123)');
      expect(e.toString(), contains('request_id=req-0123456789abcdef'));
    }
  });

  test('concurrent 401s share a single refresh and all retries succeed', () async {
    final responses = await Future.wait([
      client.request<Map<String, dynamic>>('/ping'),
      client.request<Map<String, dynamic>>('/ping'),
      client.request<Map<String, dynamic>>('/ping'),
    ]);
    expect(responses.map((r) => r.data!['ok']), [true, true, true]);
    expect(refreshCalls, 1, reason: 'single-flight refresh');
    expect(tokens.access, validAccess);
    expect(tokens.refresh, 'refresh-2', reason: 'rotated refresh token stored');
  });

  test('a revoked refresh token clears tokens and signals sign-out', () async {
    tokens.refresh = 'refresh-revoked';
    final signedOut = client.refresher.onSignedOut.first;
    try {
      await client.request<Map<String, dynamic>>('/ping');
      fail('expected ApiException');
    } on ApiException catch (e) {
      expect(e.isAuth, isTrue);
    }
    await signedOut.timeout(const Duration(seconds: 2));
    expect(tokens.access, isNull);
    expect(tokens.refresh, isNull);
  });

  test('SSE goes through the interceptor: a stale token is refreshed before streaming', () async {
    final frames = await client.openEventStream('/stream', data: {'content': 'hi'});
    final first = await frames.take(2).toList();
    expect(first.map((f) => jsonDecode(f.data)['type']), ['token', 'token']);
    expect(refreshCalls, 1);
  });

  test('cancelling the SSE subscription closes the connection so the server notices', () async {
    tokens.access = validAccess;
    final frames = await client.openEventStream('/stream', data: {'content': 'hi'});
    final received = Completer<void>();
    var count = 0;
    late StreamSubscription<dynamic> sub;
    sub = frames.listen((_) {
      count++;
      if (count == 3 && !received.isCompleted) received.complete();
    });
    await received.future.timeout(const Duration(seconds: 5));
    expect(server.connectionsInfo().active, 1, reason: 'the stream holds one active connection');

    await sub.cancel();

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (server.connectionsInfo().active > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(server.connectionsInfo().active, 0, reason: 'server must observe the client going away');
  });

  test('a non-2xx SSE response surfaces as ApiException', () async {
    tokens.access = validAccess;
    try {
      await client.openEventStream('/stream-limited', data: {'content': 'hi'});
      fail('expected ApiException');
    } on ApiException catch (e) {
      expect(e.code, 'rate_limited');
      expect(e.statusCode, 429);
      expect(e.isRateLimited, isTrue);
      expect(e.requestId, isNotNull);
    }
  });
}
