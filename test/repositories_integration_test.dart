import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/api_client.dart';
import 'package:nexusbot/core/preferences.dart';
import 'package:nexusbot/features/admin/admin_repository.dart';
import 'package:nexusbot/features/assistants/assistant_model.dart';
import 'package:nexusbot/features/assistants/assistants_repository.dart';
import 'package:nexusbot/features/attachments/attachments_repository.dart';
import 'package:nexusbot/features/auth/auth_repository.dart';
import 'package:nexusbot/features/chat/chat_models.dart';
import 'package:nexusbot/features/chat/chat_repository.dart';
import 'package:nexusbot/features/collections/collections_repository.dart';
import 'package:nexusbot/features/documents/documents_repository.dart';
import 'package:nexusbot/features/mcp/mcp_model.dart';
import 'package:nexusbot/features/mcp/mcp_repository.dart';
import 'package:nexusbot/features/memory/memory_model.dart';
import 'package:nexusbot/features/memory/memory_repository.dart';
import 'package:nexusbot/features/models/model_info.dart';
import 'package:nexusbot/features/models/models_repository.dart';
import 'package:nexusbot/features/orgs/org_model.dart';
import 'package:nexusbot/features/orgs/orgs_repository.dart';
import 'package:nexusbot/features/push/devices_repository.dart';
import 'package:nexusbot/features/share/share_model.dart';
import 'package:nexusbot/features/share/share_repository.dart';
import 'package:nexusbot/features/tools/tools_repository.dart';
import 'package:nexusbot/features/usage/usage_model.dart';
import 'package:nexusbot/features/usage/usage_repository.dart';
import 'package:nexusbot/features/voice/voice_repository.dart';

import 'helpers/fakes.dart';

/// Splits a `multipart/form-data` body into its text fields and files
/// (`{fields: {name: value}, files: {name: {filename, size, content}}}`).
/// Latin-1 keeps every byte intact, so sizes are exact.
Map<String, Object?> parseMultipart(List<int> bytes, String boundary) {
  final text = latin1.decode(bytes);
  final fields = <String, String>{};
  final files = <String, Map<String, Object?>>{};
  for (final part in text.split('--$boundary')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty || trimmed == '--') continue;
    final sep = part.indexOf('\r\n\r\n');
    if (sep < 0) continue;
    final headers = part.substring(0, sep);
    var content = part.substring(sep + 4);
    if (content.endsWith('\r\n')) content = content.substring(0, content.length - 2);
    final name = RegExp(r'name="([^"]*)"').firstMatch(headers)?.group(1) ?? '';
    final filename = RegExp(r'filename="([^"]*)"').firstMatch(headers)?.group(1);
    if (filename != null) {
      files[name] = {'filename': filename, 'size': content.length, 'content': content};
    } else {
      fields[name] = content;
    }
  }
  return {'fields': fields, 'files': files};
}

/// Drives the repositories against a loopback HTTP server speaking the
/// backend contract: Phase 2 (`/models`, `/tools`, `/collections`, the
/// document chunk viewer and collection filter, `/documents/from-url`,
/// approvals, `/search`, `PATCH /auth/me {default_model}`), Phase 3
/// (organizations and members with the `X-Org-Id` header, usage and the
/// `quota_exceeded` 429, assistants, feedback, memories, siblings / branch,
/// generation event replay with `id:` lines, background sends and the
/// `Idempotency-Key` header) and Phase 4 (attachments incl. the 307 to
/// presigned storage, voice, MCP servers, export, share links, devices).
void main() {
  late HttpServer server;
  late ApiClient client;
  const access = 'access-ok';

  /// Every request the server saw: method, path, query, decoded JSON body
  /// (or the parsed multipart form) and (lower-cased) headers.
  final seen = <({
    String method,
    String path,
    Map<String, String> query,
    Object? body,
    Map<String, String> headers,
  })>[];

  final pngBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);

  Map<String, dynamic> attachment(
    String id, {
    String kind = 'image',
    String name = 'chart.png',
    String mime = 'image/png',
    int size = 11,
    bool hasText = false,
    String? textExcerpt,
    String? messageId,
  }) =>
      {
        'id': id,
        'session_id': 's1',
        'message_id': messageId,
        'kind': kind,
        'name': name,
        'mime_type': mime,
        'size_bytes': size,
        'width': kind == 'image' ? 1200 : null,
        'height': kind == 'image' ? 800 : null,
        'url': '/api/v1/sessions/s1/attachments/$id/content',
        'description': null,
        'has_text': hasText,
        'text_excerpt': textExcerpt,
        'created_at': '2026-01-01T00:00:00Z',
      };

  Map<String, dynamic> mcpServer(String id, String name, {bool enabled = true}) => {
        'id': id,
        'org_id': 'o1',
        'name': name,
        'description': 'GitHub tools',
        'transport': 'http',
        'command': null,
        'args': [],
        'env_keys': [],
        'url': 'https://mcp.example.com/github',
        'header_keys': ['Authorization'],
        'enabled': enabled,
        'requires_approval': true,
        'created_by': 'u1',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      };

  Future<void> json(HttpResponse res, Object? body, {int status = 200}) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }

  Future<void> envelope(
    HttpResponse res,
    int status,
    String code,
    String message, {
    Map<String, Object?> details = const {},
  }) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.headers.set('x-request-id', 'req-1');
    res.write(
      jsonEncode({
        'error': {'code': code, 'message': message, 'details': details},
        'request_id': 'req-1',
      }),
    );
    await res.close();
  }

  const quotaDetails = {
    'budget_usd_per_month': 10.0,
    'used_usd': 10.25,
    'resets_at': '2026-12-01T00:00:00+00:00',
  };

  Future<void> sse(HttpResponse res, List<(int?, Map<String, Object?>)> frames) async {
    res.headers.contentType = ContentType('text', 'event-stream');
    res.bufferOutput = false;
    res.write(': connected\n\n');
    for (final (seq, frame) in frames) {
      if (seq != null) res.write('id: $seq\n');
      res.write('data: ${jsonEncode(frame)}\n\n');
    }
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

  Map<String, dynamic> message(
    String id,
    String role,
    String content, {
    String? parentId,
    Map<String, Object?>? siblings,
    Map<String, Object?> meta = const {},
  }) =>
      {
        'id': id,
        'session_id': 's1',
        'parent_id': parentId,
        'role': role,
        'content': content,
        'tokens': 1,
        'created_at': '2026-01-01T00:00:00Z',
        'siblings': siblings,
        'meta': meta,
      };

  Map<String, dynamic> org(
    String id,
    String name, {
    String role = 'owner',
    bool personal = false,
  }) =>
      {
        'id': id,
        'name': name,
        'slug': name.toLowerCase(),
        'role': role,
        'is_personal': personal,
        'plan': 'free',
        'member_count': personal ? 1 : 3,
        'settings': {
          'budget_tokens_per_month': null,
          'budget_usd_per_month': personal ? null : 25.0,
          'default_model': null,
          'allowed_models': personal ? null : ['gpt-4o-mini'],
        },
        'created_at': '2026-01-01T00:00:00Z',
      };

  Map<String, dynamic> member(String userId, String email, String role) => {
        'user_id': userId,
        'email': email,
        'full_name': email == 'owner@acme.com' ? 'Olivia Owner' : null,
        'role': role,
        'joined_at': '2026-01-01T00:00:00Z',
      };

  Map<String, dynamic> assistant(
    String id, {
    String name = 'Support bot',
    bool isDefault = false,
  }) =>
      {
        'id': id,
        'org_id': 'o1',
        'name': name,
        'description': 'Answers support questions',
        'avatar': '🤖',
        'system_prompt': 'Be helpful.',
        'model': 'gpt-4o-mini',
        'tool_names': ['calculator'],
        'collection_ids': ['c1'],
        'use_rag': true,
        'use_tools': true,
        'temperature': 0.3,
        'memory_enabled': true,
        'is_default': isDefault,
        'created_by': 'u1',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      };

  Map<String, dynamic> memory(
    String id,
    String content, {
    String kind = 'fact',
    int importance = 3,
  }) =>
      {
        'id': id,
        'content': content,
        'kind': kind,
        'importance': importance,
        'source_message_id': null,
        'created_at': '2026-01-01T00:00:00Z',
        'last_used_at': kind == 'preference' ? '2026-01-02T00:00:00Z' : null,
      };

  const approval = {
    'approval_id': 'ap1',
    'session_id': 's1',
    'message_id': 'a1',
    'expires_at': '2026-11-02T13:00:00+00:00',
    'status': 'pending',
    'tool_calls': [
      {
        'call_id': 'call_1',
        'tool': 'web_search',
        'input': {'query': 'x'},
        'description': 'web',
      },
    ],
  };

  // The replayable generation `g1`: every frame carries its sequence number.
  final generationFrames = <(int?, Map<String, Object?>)>[
    (
      1,
      {
        'type': 'user_message',
        'data': {'id': 'u1', 'content': 'hi', 'generation_id': 'g1'},
      }
    ),
    (2, {'type': 'token', 'data': 'Hel'}),
    (3, {'type': 'token', 'data': 'lo'}),
    (
      4,
      {
        'type': 'done',
        'data': {'text': 'Hello', 'status': 'ok', 'generation_id': 'g1'},
      }
    ),
    (
      5,
      {
        'type': 'assistant_message',
        'data': {'id': 'a1', 'content': 'Hello', 'generation_id': 'g1'},
      }
    ),
  ];

  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    // Presigned storage links authenticate themselves: a bearer arriving here
    // means the client forwarded it across the redirect, which must not happen.
    if (req.uri.path.startsWith('/presigned/')) {
      await req.drain<void>();
      if (req.headers.value('authorization') != null || req.headers.value('x-org-id') != null) {
        await envelope(res, 400, 'bad_request', 'API headers forwarded to storage');
        return;
      }
      res.headers.contentType = ContentType('image', 'png');
      res.add(pngBytes);
      await res.close();
      return;
    }
    if (req.headers.value('authorization') != 'Bearer $access') {
      await envelope(res, 401, 'unauthorized', 'bad token');
      return;
    }
    final bytes = await req.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
    final contentType = req.headers.contentType;
    final Object? body;
    if (bytes.isEmpty) {
      body = null;
    } else if (contentType?.mimeType == 'multipart/form-data') {
      body = parseMultipart(bytes, contentType!.parameters['boundary']!);
    } else {
      body = jsonDecode(utf8.decode(bytes));
    }
    final headers = <String, String>{};
    req.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(','));
    seen.add(
      (
        method: req.method,
        path: req.uri.path,
        query: req.uri.queryParameters,
        body: body,
        headers: headers,
      ),
    );

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
            {
              'name': 'calculator',
              'description': 'Math',
              'requires_approval': false,
              'source': 'builtin',
            },
            {'name': 'web_search', 'description': 'Web', 'requires_approval': true},
            {
              'name': 'mcp:github:search_issues',
              'description': 'Find issues',
              'requires_approval': true,
              'source': 'mcp:github',
            },
          ],
        });

      // ── Attachments ──
      case ('POST', '/sessions/s1/attachments'):
        final file = ((body as Map)['files'] as Map)['file'] as Map;
        final name = file['filename'] as String;
        if (name.endsWith('.exe')) {
          await envelope(
            res,
            422,
            'validation_error',
            'File type not allowed',
            details: {
              'allowed_extensions': ['pdf', 'txt'],
            },
          );
          return;
        }
        await json(
          res,
          attachment(
            'a-new',
            kind: name.endsWith('.png') ? 'image' : 'file',
            name: name,
            mime: name.endsWith('.png') ? 'image/png' : 'text/plain',
            size: file['size'] as int,
            hasText: !name.endsWith('.png'),
            textExcerpt: name.endsWith('.png') ? null : 'hello',
          ),
          status: 201,
        );
      case ('GET', '/sessions/s1/attachments'):
        await json(res, {
          'items': [
            attachment('a1', messageId: 'u1'),
            attachment('a2', kind: 'audio', name: 'voice.m4a', mime: 'audio/mp4', hasText: true),
          ],
        });
      case ('GET', '/sessions/s1/attachments/a1'):
        await json(res, attachment('a1', messageId: 'u1', textExcerpt: null));
      case ('DELETE', '/sessions/s1/attachments/a1'):
        await json(res, {'ok': true, 'message': 'Attachment deleted'});
      case ('GET', '/api/v1/sessions/s1/attachments/a1/content'):
        res.headers.contentType = ContentType('image', 'png');
        res.headers.set('content-disposition', 'inline; filename="chart.png"');
        res.add(pngBytes);
        await res.close();
      case ('GET', '/api/v1/sessions/s1/attachments/a2/content'):
        res.statusCode = 307;
        res.headers.set('location', 'http://127.0.0.1:${server.port}/presigned/a2?sig=abc');
        await res.close();
      case ('GET', '/api/v1/sessions/s1/attachments/missing/content'):
        await envelope(res, 404, 'not_found', 'Attachment not found');

      // ── Voice ──
      case ('GET', '/audio/voices'):
        await json(res, {
          'provider': 'openai',
          'stt_available': true,
          'tts_available': true,
          'default_voice': 'alloy',
          'default_format': 'mp3',
          'voices': [
            {'id': 'alloy', 'name': 'Alloy'},
            {'id': 'nova', 'name': 'Nova'},
          ],
        });
      case ('POST', '/audio/transcriptions'):
        final form = body as Map;
        final file = (form['files'] as Map)['file'] as Map;
        await json(res, {
          'text': 'hello from ${file['filename']}',
          'language': (form['fields'] as Map)['language'] ?? 'en',
          'duration_seconds': 1.5,
          'provider': 'openai',
        });
      case ('POST', '/audio/speech'):
        final b = body as Map<String, dynamic>;
        if (b['voice'] == 'ghost') {
          await envelope(res, 422, 'validation_error', "Unknown voice 'ghost'");
          return;
        }
        res.headers.contentType = ContentType('audio', 'mpeg');
        res.headers.set('content-disposition', 'inline; filename="speech.mp3"');
        res.add([0xFF, 0xFB, 0x90, 0x00]);
        await res.close();
      case ('POST', '/sessions/s1/messages/voice'):
        final form = body as Map;
        final file = (form['files'] as Map)['file'] as Map;
        await json(
          res,
          {
            'generation_id': 'g-voice',
            'transcript': 'what is the weather (${file['size']} bytes)',
            'user_message_id': 'u-voice',
            'attachment_id': 'a-voice',
          },
          status: 202,
        );
      case ('POST', '/sessions/s-novoice/messages/voice'):
        await envelope(
          res,
          503,
          'service_unavailable',
          'Speech-to-text is not configured',
          details: {'code': 'voice_unavailable'},
        );

      // ── MCP servers ──
      case ('GET', '/mcp/servers'):
        if (req.headers.value('x-org-id') != 'o1') {
          await envelope(res, 403, 'forbidden', 'Not a member of this organization');
          return;
        }
        await json(res, {
          'items': [mcpServer('m1', 'github'), mcpServer('m2', 'broken', enabled: false)],
        });
      case ('POST', '/mcp/servers'):
        final b = body as Map<String, dynamic>;
        if (b['name'] == 'github') {
          await envelope(res, 409, 'conflict', 'An MCP server with this name already exists');
          return;
        }
        if (b['transport'] == 'stdio') {
          await envelope(res, 403, 'forbidden', 'Only server administrators can register stdio');
          return;
        }
        final created = mcpServer('m-new', b['name'] as String);
        created['url'] = b['url'];
        created['header_keys'] = ((b['headers'] as Map?) ?? {}).keys.toList();
        created['requires_approval'] = b['requires_approval'];
        await json(res, created, status: 201);
      case ('GET', '/mcp/servers/m1'):
        await json(res, mcpServer('m1', 'github'));
      case ('PATCH', '/mcp/servers/m1'):
        final b = body as Map<String, dynamic>;
        final updated = mcpServer('m1', 'github', enabled: (b['enabled'] as bool?) ?? true);
        if (b.containsKey('requires_approval')) {
          updated['requires_approval'] = b['requires_approval'];
        }
        if (b.containsKey('description')) updated['description'] = b['description'];
        await json(res, updated);
      case ('DELETE', '/mcp/servers/m1'):
        await json(res, {'ok': true, 'message': 'MCP server removed'});
      case ('POST', '/mcp/servers/m1/test'):
        await json(res, {
          'ok': true,
          'tools': [
            {
              'name': 'mcp:github:search_issues',
              'server': 'github',
              'tool': 'search_issues',
              'description': 'Find issues',
              'input_schema': {
                'type': 'object',
                'properties': {
                  'q': {'type': 'string'},
                },
              },
              'requires_approval': true,
            },
          ],
          'error': null,
          'latency_ms': 42,
        });
      case ('POST', '/mcp/servers/m2/test'):
        await json(res, {'ok': false, 'tools': [], 'error': 'connection refused', 'latency_ms': 7});
      case ('GET', '/mcp/servers/m1/tools'):
        await json(res, [
          {
            'name': 'mcp:github:search_issues',
            'server': 'github',
            'tool': 'search_issues',
            'description': 'Find issues',
            'input_schema': {},
            'requires_approval': true,
          },
        ]);

      // ── Export & share ──
      case ('GET', '/sessions/s1/export'):
        final format = req.uri.queryParameters['format'] ?? 'markdown';
        if (format == 'json') {
          res.headers.contentType = ContentType.json;
          res.headers.set('content-disposition', 'attachment; filename="invoices.json"');
          res.write(
            jsonEncode({
              'session': {'title': 'Invoices'},
              'messages': [],
            }),
          );
        } else {
          res.headers.contentType = ContentType('text', 'markdown', charset: 'utf-8');
          res.headers.set('content-disposition', 'attachment; filename="invoices.md"');
          res.write('# Invoices\n\n**User:** hi\n');
        }
        await res.close();
      case ('GET', '/sessions/s-missing/export'):
        await envelope(res, 404, 'not_found', 'Session not found');
      case ('POST', '/sessions/s1/share'):
        final b = body as Map<String, dynamic>?;
        await json(
          res,
          {
            'id': 'sh-new',
            'token': 'tok-secret',
            'url': '/api/v1/shared/tok-secret',
            'expires_at': '2026-11-09T00:00:00+00:00',
            'views': 0,
            'hours': b?['expires_in_hours'],
          },
          status: 201,
        );
      case ('GET', '/sessions/s1/share'):
        await json(res, {
          'items': [
            {
              'id': 'sh-1',
              'token': null,
              'url': null,
              'expires_at': '2026-11-09T00:00:00+00:00',
              'views': 3,
            },
          ],
        });
      case ('DELETE', '/sessions/s1/share'):
        final one = req.uri.queryParameters['share_id'] != null;
        await json(res, {'ok': true, 'message': 'Revoked ${one ? 1 : 2} link(s)'});

      // ── Devices ──
      case ('POST', '/devices'):
        final b = body as Map<String, dynamic>;
        final token = b['token'] as String;
        await json(
          res,
          {
            'id': 'd1',
            'platform': b['platform'],
            'token_suffix': token.substring(token.length - 6),
            'app_version': b['app_version'],
            'locale': b['locale'],
            'last_seen_at': '2026-11-02T00:00:00+00:00',
            'created_at': '2026-11-02T00:00:00+00:00',
          },
          status: 201,
        );
      case ('GET', '/devices'):
        await json(res, {
          'items': [
            {
              'id': 'd1',
              'platform': 'android',
              'token_suffix': 'abcdef',
              'app_version': '1.0.0',
              'locale': 'en-GB',
              'last_seen_at': null,
              'created_at': '2026-11-02T00:00:00+00:00',
            },
          ],
          'push_enabled': true,
        });
      case ('DELETE', '/devices/fcm-token-abcdef'):
        await json(res, {'ok': true, 'message': 'Device removed'});
      case ('DELETE', '/devices/unknown'):
        await envelope(res, 404, 'not_found', 'Device not found');

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
          {
            'document': document('d-url', collectionId: b['collection_id'] as String?),
            'queued': true,
          },
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
        await json(res, {
          'items': [approval],
        });
      case ('POST', '/sessions/s1/approvals/ap1'):
        if (req.headers.value('accept') != 'text/event-stream') {
          await envelope(res, 406, 'not_acceptable', 'Accept must be text/event-stream');
          return;
        }
        await sse(res, [
          (
            null,
            {
              'type': 'tool_call',
              'data': {'phase': 'end', 'tool': 'web_search', 'call_id': 'call_1', 'output': 'r'},
            }
          ),
          (null, {'type': 'token', 'data': 'Done'}),
          (
            null,
            {
              'type': 'done',
              'data': {'text': 'Done', 'status': 'ok', 'model': 'gpt-4o-mini'},
            }
          ),
          (
            null,
            {
              'type': 'assistant_message',
              'data': {'id': 'a1', 'content': 'Done', 'status': 'ok'},
            }
          ),
        ]);
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
      case ('POST', '/sessions/s1/messages/stream'):
        await sse(res, generationFrames);
      case ('POST', '/sessions/s-quota/messages'):
        await envelope(
          res,
          429,
          'quota_exceeded',
          'Monthly spending budget exhausted',
          details: quotaDetails,
        );
      case ('POST', '/sessions/s-quota/messages/stream'):
        await envelope(
          res,
          429,
          'quota_exceeded',
          'Monthly spending budget exhausted',
          details: quotaDetails,
        );
      case ('POST', '/sessions/s-quota/messages/background'):
        await envelope(
          res,
          429,
          'quota_exceeded',
          'Monthly spending budget exhausted',
          details: quotaDetails,
        );

      case ('POST', '/sessions'):
        final b = body as Map<String, dynamic>;
        await json(
          res,
          {
            'id': 's-new',
            'org_id': 'o1',
            'assistant_id': b['assistant_id'],
            'active_leaf_id': null,
            'title': 'New chat',
            'model': b['model'],
            'meta': {},
            'created_at': '2026-01-01T00:00:00Z',
            'updated_at': '2026-01-01T00:00:00Z',
          },
          status: 201,
        );
      case ('PATCH', '/sessions/s1'):
        final b = body as Map<String, dynamic>;
        await json(res, {
          'id': 's1',
          'org_id': 'o1',
          'assistant_id': b['assistant_id'],
          'active_leaf_id': 'a1',
          'title': 'T',
          'model': b['model'],
          'meta': b['meta'] ?? {},
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        });

      case ('GET', '/sessions/s1/messages/a1/siblings'):
        await json(res, {
          'items': [
            message(
              'a0',
              'assistant',
              'first try',
              parentId: 'u1',
              siblings: {'index': 0, 'count': 2},
            ),
            message(
              'a1',
              'assistant',
              'second try',
              parentId: 'u1',
              siblings: {'index': 1, 'count': 2},
            ),
          ],
          'active_index': 1,
        });
      case ('POST', '/sessions/s1/branch'):
        final b = body as Map<String, dynamic>;
        await json(res, {
          'items': [
            message('u1', 'user', 'q'),
            message(
              b['leaf_message_id'] as String,
              'assistant',
              'first try',
              parentId: 'u1',
              siblings: {'index': 0, 'count': 2},
            ),
          ],
          'next_cursor': null,
        });

      case ('POST', '/sessions/s1/messages/u1/edit'):
        if (req.headers.value('accept') != 'text/event-stream') {
          await envelope(res, 406, 'not_acceptable', 'Accept must be text/event-stream');
          return;
        }
        await sse(res, [
          (
            1,
            {
              'type': 'user_message',
              'data': {
                'id': 'u2',
                'content': body is Map ? body['content'] : '',
                'parent_id': 'a0',
                'generation_id': 'g2',
                'siblings': {'index': 1, 'count': 2},
              },
            }
          ),
          (2, {'type': 'token', 'data': 'Edited reply'}),
          (
            3,
            {
              'type': 'done',
              'data': {'text': 'Edited reply', 'generation_id': 'g2'},
            }
          ),
          (
            4,
            {
              'type': 'assistant_message',
              'data': {
                'id': 'a2',
                'content': 'Edited reply',
                'parent_id': 'u2',
                'generation_id': 'g2',
              },
            }
          ),
        ]);

      case ('POST', '/sessions/s1/generations/g1/stop'):
        await json(res, {'ok': true, 'message': 'Stop requested'});
      case ('GET', '/sessions/s1/generations/active'):
        await json(
          res,
          {'generation_id': 'g1', 'started_at': '2026-01-01T00:00:00Z', 'status': 'running'},
        );
      case ('GET', '/sessions/s2/generations/active'):
        await json(res, null);
      case ('GET', '/sessions/s1/generations/g1/events'):
        final after = int.tryParse(req.uri.queryParameters['after'] ?? '') ?? 0;
        await sse(res, [
          for (final f in generationFrames)
            if (f.$1! > after) f,
        ]);
      case ('GET', '/sessions/s1/generations/g-old/events'):
        await envelope(res, 404, 'not_found', 'Generation expired');
      case ('POST', '/sessions/s1/messages/background'):
        final b = body as Map<String, dynamic>;
        await json(
          res,
          {
            'generation_id': 'g7',
            'user_message': message('u7', 'user', b['content'] as String),
          },
          status: 202,
        );

      case ('POST', '/sessions/s1/messages/a1/feedback'):
        final b = body as Map<String, dynamic>;
        await json(res, {
          'message_id': 'a1',
          'session_id': 's1',
          'user_id': 'u1',
          'rating': b['rating'],
          'comment': b['comment'],
          'created_at': '2026-01-01T00:00:00Z',
        });
      case ('DELETE', '/sessions/s1/messages/a1/feedback'):
        await json(res, {'ok': true});

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
          'memory_enabled': b['memory_enabled'] ?? true,
          'personal_org_id': 'o-personal',
        });

      // ── Organizations ──
      case ('GET', '/orgs'):
        if (req.headers.value('x-org-id') == 'o-stale') {
          await envelope(res, 403, 'forbidden', 'You are not a member of this organization');
          return;
        }
        await json(res, {
          'items': [
            org('o-personal', 'Personal', personal: true),
            org('o1', 'Acme', role: 'admin'),
          ],
        });
      case ('POST', '/orgs'):
        final b = body as Map<String, dynamic>;
        await json(res, org('o-new', b['name'] as String), status: 201);
      case ('GET', '/orgs/o1'):
        await json(res, org('o1', 'Acme', role: 'admin'));
      case ('PATCH', '/orgs/o1'):
        final b = body as Map<String, dynamic>;
        final updated = org('o1', (b['name'] as String?) ?? 'Acme', role: 'admin');
        if (b['settings'] is Map) updated['settings'] = b['settings'];
        await json(res, updated);
      case ('PATCH', '/orgs/o-member'):
        await envelope(res, 403, 'forbidden', 'Admin role required');
      case ('GET', '/orgs/o1/members'):
        await json(res, {
          'items': [
            member('u1', 'owner@acme.com', 'owner'),
            member('u2', 'dev@acme.com', 'member'),
          ],
        });
      case ('POST', '/orgs/o1/members'):
        final b = body as Map<String, dynamic>;
        final email = b['email'] as String;
        if (email.startsWith('nobody')) {
          await envelope(res, 404, 'not_found', 'No user with that email');
          return;
        }
        if (email == 'dev@acme.com') {
          await envelope(res, 409, 'conflict', 'Already a member');
          return;
        }
        await json(res, member('u3', email, b['role'] as String), status: 201);
      case ('PATCH', '/orgs/o1/members/u2'):
        final b = body as Map<String, dynamic>;
        await json(res, member('u2', 'dev@acme.com', b['role'] as String));
      case ('DELETE', '/orgs/o1/members/u2'):
        await json(res, {'ok': true});
      case ('GET', '/orgs/o1/usage'):
        await json(res, {
          'period': {'start': '2026-11-01T00:00:00+00:00', 'end': '2026-12-01T00:00:00+00:00'},
          'group_by': req.uri.queryParameters['group_by'],
          'totals': {'tokens': 5000, 'cost_usd': 1.5, 'messages': 40},
          'groups': [
            {'key': 'owner@acme.com', 'tokens': 3000, 'cost_usd': 1.0, 'messages': 25},
            {'key': 'dev@acme.com', 'tokens': 2000, 'cost_usd': 0.5, 'messages': 15},
          ],
        });

      // ── Usage ──
      case ('GET', '/usage/me'):
        await json(res, {
          'period': {'start': '2026-11-01T00:00:00+00:00', 'end': '2026-12-01T00:00:00+00:00'},
          'user': {'tokens': 12345, 'cost_usd': 0.42, 'messages': 17},
          'org': {
            'id': 'o1',
            'tokens': 99999,
            'cost_usd': 3.1,
            'messages': 120,
            'budget_tokens_per_month': null,
            'budget_usd_per_month': 10.0,
            'remaining_tokens': null,
            'remaining_usd': 6.9,
          },
        });
      case ('GET', '/admin/usage'):
        await json(res, {
          'period': {'start': '2026-11-01T00:00:00+00:00', 'end': '2026-12-01T00:00:00+00:00'},
          'group_by': 'org',
          'totals': {'tokens': 10, 'cost_usd': 0.1, 'messages': 2},
          'groups': [
            {'key': 'Acme', 'tokens': 10, 'cost_usd': 0.1, 'messages': 2},
          ],
        });
      case ('GET', '/admin/feedback'):
        await json(res, {
          'items': [
            {
              'message_id': 'a1',
              'session_id': 's1',
              'user_id': 'u1',
              'rating': -1,
              'comment': 'Wrong total',
              'created_at': '2026-01-01T00:00:00Z',
            },
          ],
          'total': 1,
          'page': 1,
          'page_size': 20,
        });

      // ── Assistants ──
      case ('GET', '/assistants'):
        await json(res, {
          'items': [assistant('as1', isDefault: true), assistant('as2', name: 'Writer')],
          'total': 2,
          'page': 1,
          'page_size': 50,
        });
      case ('POST', '/assistants'):
        final b = body as Map<String, dynamic>;
        final created = assistant('as-new', name: b['name'] as String);
        created['temperature'] = b['temperature'];
        created['model'] = b['model'];
        await json(res, created, status: 201);
      case ('GET', '/assistants/as1'):
        await json(res, assistant('as1', isDefault: true));
      case ('PATCH', '/assistants/as1'):
        final b = body as Map<String, dynamic>;
        await json(
          res,
          assistant(
            'as1',
            name: (b['name'] as String?) ?? 'Support bot',
            isDefault: b['is_default'] == true,
          ),
        );
      case ('DELETE', '/assistants/as1'):
        await json(res, {'ok': true});
      case ('PATCH', '/assistants/as-theirs'):
        await envelope(res, 403, 'forbidden', 'Only the creator or an org admin may edit');

      // ── Memories ──
      case ('GET', '/memories'):
        await json(res, {
          'items': [
            memory('m1', 'Prefers short answers', kind: 'preference', importance: 4),
            memory('m2', 'Works at Acme'),
          ],
          'total': 2,
          'page': 1,
          'page_size': 50,
        });
      case ('POST', '/memories'):
        final b = body as Map<String, dynamic>;
        await json(
          res,
          memory(
            'm-new',
            b['content'] as String,
            kind: b['kind'] as String,
            importance: b['importance'] as int,
          ),
          status: 201,
        );
      case ('PATCH', '/memories/m1'):
        final b = body as Map<String, dynamic>;
        await json(
          res,
          memory(
            'm1',
            (b['content'] as String?) ?? 'Prefers short answers',
            kind: 'preference',
            importance: (b['importance'] as int?) ?? 4,
          ),
        );
      case ('DELETE', '/memories/m1'):
        await json(res, {'ok': true});
      case ('DELETE', '/memories'):
        await json(res, {'ok': true});

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

  test('tools: GET /tools → list with sources; default selection skips approval tools', () async {
    final tools = await ToolsRepository(client).list();
    expect(tools.map((t) => t.name), ['calculator', 'web_search', 'mcp:github:search_issues']);
    expect(tools[1].requiresApproval, isTrue);
    expect(tools[1].source, 'builtin', reason: 'older rows without a source are built-ins');
    expect(tools.last.source, 'mcp:github');
    expect(tools.last.serverName, 'github');
    expect(tools.last.shortName, 'search_issues');
    expect(defaultToolSelection(tools), ['calculator']);
    expect(groupToolsBySource(tools).map((g) => g.label), ['Built-in', 'github']);
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
      idempotencyKey: 'key-blocking',
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
    expect(seen.last.headers['idempotency-key'], 'key-blocking');
    expect(result.userMessage?.id, 'u1');
    expect(result.toolMessages.single.isToolRun, isTrue);
    expect(result.toolMessages.single.toolCalls.single.latencyMs, 3);
    expect(result.assistantMessage.model, 'gpt-4o-mini');
    expect(result.replyRows.map((m) => m.id), ['t1', 'a1']);
  });

  test('sessions: create with assistant, PATCH model / meta / assistant_id', () async {
    final repo = ChatRepository(client);
    final created = await repo.createSession(assistantId: 'as1');
    expect(created.assistantId, 'as1');
    expect(created.orgId, 'o1');
    expect(seen.last.body, {'assistant_id': 'as1'});

    final s = await repo.updateSession('s1', model: 'llama3');
    expect(s.model, 'llama3');
    expect(s.activeLeafId, 'a1');
    expect(seen.last.body, {'model': 'llama3'});
    final scoped = await repo.updateSession(
      's1',
      meta: {
        'collection_ids': ['c1'],
      },
    );
    expect(scoped.collectionIds, ['c1']);
    expect(seen.last.body, {
      'meta': {
        'collection_ids': ['c1'],
      },
    });

    final withAssistant = await repo.updateSession('s1', assistantId: 'as2');
    expect(withAssistant.assistantId, 'as2');
    expect(seen.last.body, {'assistant_id': 'as2'});
    final plain = await repo.updateSession('s1', clearAssistantId: true);
    expect(plain.assistantId, isNull);
    expect(seen.last.body, {'assistant_id': null}, reason: 'null is sent explicitly');
  });

  test('search: POST /search returns highlighted hits', () async {
    final hits = await ChatRepository(client).search('invoice', limit: 5);
    expect(seen.last.body, {'query': 'invoice', 'limit': 5});
    expect(hits.single.sessionId, 's1');
    expect(hits.single.highlight, 'The <mark>invoice</mark> total is 42');
    expect(hits.single.rank, 0.9);
  });

  test('auth: PATCH /auth/me {default_model} and {memory_enabled}', () async {
    final repo = AuthRepository(client);
    final user = await repo.setDefaultModel('llama3');
    expect(user.defaultModel, 'llama3');
    expect(user.personalOrgId, 'o-personal');
    expect(user.memoryEnabled, isTrue);
    expect(seen.last.body, {'default_model': 'llama3'});
    final cleared = await repo.setDefaultModel(null);
    expect(cleared.defaultModel, isNull);
    expect(seen.last.body, {'default_model': null});

    final noMemory = await repo.setMemoryEnabled(false);
    expect(noMemory.memoryEnabled, isFalse);
    expect(seen.last.body, {'memory_enabled': false});
  });

  // ── Phase 3 ───────────────────────────────────────────────────────────

  group('organizations', () {
    test('X-Org-Id is sent on every request while an org is active, and dropped otherwise',
        () async {
      client.activeOrgId = () => 'o1';
      await OrgsRepository(client).list();
      expect(seen.last.headers['x-org-id'], 'o1');
      await ToolsRepository(client).list();
      expect(seen.last.headers['x-org-id'], 'o1', reason: 'every request, not only org routes');

      client.activeOrgId = () => null;
      await ToolsRepository(client).list();
      expect(seen.last.headers.containsKey('x-org-id'), isFalse);
      client.activeOrgId = () => '';
      await ToolsRepository(client).list();
      expect(seen.last.headers.containsKey('x-org-id'), isFalse, reason: 'empty = personal');
    });

    test('a stale org id is refused with 403 forbidden', () async {
      client.activeOrgId = () => 'o-stale';
      try {
        await OrgsRepository(client).list();
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isForbidden, isTrue);
        expect(e.statusCode, 403);
      }
    });

    test('list, create, get, update (name / settings)', () async {
      final repo = OrgsRepository(client);
      final orgs = await repo.list();
      expect(orgs.map((o) => o.id), ['o-personal', 'o1']);
      expect(orgs.first.isPersonal, isTrue);
      expect(orgs.first.role, OrgRole.owner);
      expect(orgs.last.role, OrgRole.admin);
      expect(orgs.last.canManage, isTrue);
      expect(orgs.last.memberCount, 3);
      expect(orgs.last.settings.budgetUsdPerMonth, 25.0);
      expect(orgs.last.settings.budgetTokensPerMonth, isNull);
      expect(orgs.last.settings.allowedModels, ['gpt-4o-mini']);
      expect(orgs.first.settings.allowedModels, isNull);

      final created = await repo.create('Acme Labs');
      expect(created.id, 'o-new');
      expect(created.name, 'Acme Labs');
      expect(seen.last.body, {'name': 'Acme Labs'});

      expect((await repo.get('o1')).name, 'Acme');

      final renamed = await repo.update('o1', name: 'Acme Inc');
      expect(renamed.name, 'Acme Inc');
      expect(seen.last.body, {'name': 'Acme Inc'});

      final budgeted = await repo.update(
        'o1',
        settings: const OrgSettings(budgetUsdPerMonth: 50, allowedModels: ['llama3']),
      );
      expect(seen.last.body, {
        'settings': {
          'budget_tokens_per_month': null,
          'budget_usd_per_month': 50.0,
          'default_model': null,
          'allowed_models': ['llama3'],
        },
      });
      expect(budgeted.settings.budgetUsdPerMonth, 50);
      expect(budgeted.settings.allowedModels, ['llama3']);

      try {
        await repo.update('o-member', name: 'x');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isForbidden, isTrue);
      }
    });

    test('members: list, add (404 / 409), change role, remove', () async {
      final repo = OrgsRepository(client);
      final members = await repo.listMembers('o1');
      expect(members.map((m) => m.email), ['owner@acme.com', 'dev@acme.com']);
      expect(members.first.role, OrgRole.owner);
      expect(members.first.displayName, 'Olivia Owner');
      expect(members.last.displayName, 'dev@acme.com');

      final added = await repo.addMember('o1', email: 'new@acme.com', role: OrgRole.admin);
      expect(added.userId, 'u3');
      expect(added.role, OrgRole.admin);
      expect(seen.last.body, {'email': 'new@acme.com', 'role': 'admin'});

      try {
        await repo.addMember('o1', email: 'nobody@acme.com');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isNotFound, isTrue);
        expect(seen.last.body, {'email': 'nobody@acme.com', 'role': 'member'});
      }
      try {
        await repo.addMember('o1', email: 'dev@acme.com');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isConflict, isTrue);
      }

      final promoted = await repo.updateMemberRole('o1', 'u2', OrgRole.admin);
      expect(promoted.role, OrgRole.admin);
      expect(seen.last.body, {'role': 'admin'});

      await repo.removeMember('o1', 'u2');
      expect(seen.last.method, 'DELETE');
      expect(seen.last.path, '/orgs/o1/members/u2');
    });
  });

  group('usage & quotas', () {
    test('GET /usage/me', () async {
      final summary = await UsageRepository(client).me();
      expect(summary.user.tokens, 12345);
      expect(summary.user.costUsd, 0.42);
      expect(summary.user.messages, 17);
      expect(summary.org.id, 'o1');
      expect(summary.org.usage.costUsd, 3.1);
      expect(summary.org.budgetUsdPerMonth, 10.0);
      expect(summary.org.remainingUsd, 6.9);
      expect(summary.org.budgetTokensPerMonth, isNull);
      expect(summary.org.hasBudget, isTrue);
      expect(summary.org.exhausted, isFalse);
      expect(summary.org.usdFraction, closeTo(0.31, 1e-9));
      expect(summary.org.tokensFraction, isNull);
      expect(summary.period.end.toUtc().month, 12);
    });

    test('org and admin reports send from / to / group_by', () async {
      final repo = UsageRepository(client);
      final report = await repo.orgReport(
        'o1',
        from: DateTime.utc(2026, 11),
        to: DateTime.utc(2026, 12),
        groupBy: UsageGroupBy.user,
      );
      expect(seen.last.query, {
        'from': '2026-11-01T00:00:00.000Z',
        'to': '2026-12-01T00:00:00.000Z',
        'group_by': 'user',
      });
      expect(report.groupBy, UsageGroupBy.user);
      expect(report.totals.tokens, 5000);
      expect(report.groups.map((g) => g.key), ['owner@acme.com', 'dev@acme.com']);
      expect(report.groups.first.usage.costUsd, 1.0);

      final admin = await repo.adminReport(
        from: DateTime.utc(2026, 11),
        to: DateTime.utc(2026, 12),
        groupBy: UsageGroupBy.org,
      );
      expect(seen.last.path, '/admin/usage');
      expect(seen.last.query['group_by'], 'org');
      expect(admin.groupBy, UsageGroupBy.org);
      expect(admin.groups.single.key, 'Acme');
    });

    test('a 429 quota_exceeded maps to ApiException + QuotaExceeded on every send path', () async {
      final repo = ChatRepository(client);
      Future<void> expectQuota(Future<void> Function() call) async {
        try {
          await call();
          fail('expected ApiException');
        } on ApiException catch (e) {
          expect(e.statusCode, 429);
          expect(e.code, 'quota_exceeded');
          expect(e.isQuotaExceeded, isTrue);
          expect(e.isRateLimited, isTrue);
          final q = QuotaExceeded.fromDetails(e.details, message: e.message);
          expect(q.budgetUsd, 10.0);
          expect(q.usedUsd, 10.25);
          expect(q.resetsAt, DateTime.utc(2026, 12));
          expect(q.figures, r'$10.25 of $10.00 spent');
          expect(q.isPast(DateTime.utc(2026, 11, 2)), isFalse);
          expect(q.isPast(DateTime.utc(2026, 12, 2)), isTrue);
        }
      }

      await expectQuota(() => repo.sendBlocking(sessionId: 's-quota', content: 'x'));
      await expectQuota(
        () =>
            repo.streamMessage(sessionId: 's-quota', content: 'x', transport: StreamTransport.sse),
      );
      await expectQuota(() => repo.sendBackground(sessionId: 's-quota', content: 'x'));
    });

    test('admin feedback list is paged', () async {
      final page = await AdminRepository(client).listFeedback(page: 1, pageSize: 20);
      expect(seen.last.query, {'page': '1', 'page_size': '20'});
      expect(page.total, 1);
      expect(page.hasMore, isFalse);
      final f = page.items.single;
      expect(f.messageId, 'a1');
      expect(f.sessionId, 's1');
      expect(f.rating, -1);
      expect(f.isPositive, isFalse);
      expect(f.comment, 'Wrong total');
    });
  });

  group('assistants', () {
    test('list (paged), get, create, update, set default, delete; 403 surfaced', () async {
      final repo = AssistantsRepository(client);
      final all = await repo.listAll();
      expect(all.map((a) => a.id), ['as1', 'as2']);
      expect(all.first.isDefault, isTrue);
      expect(all.first.avatarLabel, '🤖');
      expect(all.first.toolNames, ['calculator']);
      expect(all.first.collectionIds, ['c1']);
      expect(all.first.temperature, 0.3);
      expect(all.first.useTools, isTrue);
      expect(all.first.memoryEnabled, isTrue);
      expect(all.first.createdBy, 'u1');

      expect((await repo.get('as1')).name, 'Support bot');

      final created = await repo.create(
        const AssistantDraft(name: 'Writer', avatar: ' ', model: 'llama3', useTools: false),
      );
      expect(created.id, 'as-new');
      expect(created.name, 'Writer');
      expect(created.temperature, isNull);
      expect(seen.last.body, {
        'name': 'Writer',
        'description': null,
        'avatar': null,
        'system_prompt': null,
        'model': 'llama3',
        'tool_names': [],
        'collection_ids': [],
        'use_rag': true,
        'use_tools': false,
        'temperature': null,
        'memory_enabled': true,
        'is_default': false,
      });

      final updated = await repo.update('as1', all.first.toDraft());
      expect(updated.name, 'Support bot');
      expect((seen.last.body as Map)['temperature'], 0.3);
      expect((seen.last.body as Map)['is_default'], isTrue);

      final defaulted = await repo.setDefault('as1', true);
      expect(defaulted.isDefault, isTrue);
      expect(seen.last.body, {'is_default': true});

      await repo.delete('as1');
      expect(seen.last.method, 'DELETE');

      try {
        await repo.update('as-theirs', const AssistantDraft(name: 'x'));
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isForbidden, isTrue);
      }
    });
  });

  group('feedback', () {
    test('POST upserts the rating with an optional comment; DELETE removes it', () async {
      final repo = ChatRepository(client);
      final up = await repo.setFeedback('s1', 'a1', rating: 1);
      expect(up.isUp, isTrue);
      expect(up.comment, isNull);
      expect(seen.last.body, {'rating': 1}, reason: 'no comment key when empty');

      final down = await repo.setFeedback('s1', 'a1', rating: -1, comment: '  too long ');
      expect(down.isDown, isTrue);
      expect(down.comment, 'too long');
      expect(seen.last.body, {'rating': -1, 'comment': 'too long'});

      await repo.clearFeedback('s1', 'a1');
      expect(seen.last.method, 'DELETE');
      expect(seen.last.path, '/sessions/s1/messages/a1/feedback');
    });
  });

  group('memories', () {
    test('list, create, update, delete, clear all', () async {
      final repo = MemoryRepository(client);
      final all = await repo.listAll();
      expect(all.map((m) => m.id), ['m1', 'm2']);
      expect(all.first.kind, MemoryKind.preference);
      expect(all.first.importance, 4);
      expect(all.first.lastUsedAt, isNotNull);
      expect(all.last.kind, MemoryKind.fact);
      expect(all.last.lastUsedAt, isNull);

      final created = await repo.create(
        content: 'Lives in Lisbon',
        kind: MemoryKind.instruction,
        importance: 5,
      );
      expect(created.id, 'm-new');
      expect(created.kind, MemoryKind.instruction);
      expect(
        seen.last.body,
        {'content': 'Lives in Lisbon', 'kind': 'instruction', 'importance': 5},
      );

      final edited = await repo.update('m1', importance: 2);
      expect(edited.importance, 2);
      expect(seen.last.body, {'importance': 2}, reason: 'only the given fields are sent');

      await repo.delete('m1');
      expect(seen.last, isA<Object>());
      expect(seen.last.method, 'DELETE');
      expect(seen.last.path, '/memories/m1');

      await repo.clearAll();
      expect(seen.last.method, 'DELETE');
      expect(seen.last.path, '/memories');
    });
  });

  group('branching', () {
    test('siblings and branch', () async {
      final repo = ChatRepository(client);
      final siblings = await repo.listSiblings('s1', 'a1');
      expect(siblings.items.map((m) => m.id), ['a0', 'a1']);
      expect(siblings.activeIndex, 1);
      expect(siblings.items.first.siblings?.displayIndex, 1);
      expect(siblings.items.first.parentId, 'u1');

      final history = await repo.branch('s1', leafMessageId: 'a0');
      expect(seen.last.body, {'leaf_message_id': 'a0'});
      expect(history.map((m) => m.id), ['u1', 'a0']);
      expect(history.last.siblings?.count, 2);
    });

    test('edit streams like a turn and carries the Idempotency-Key', () async {
      final turn = await ChatRepository(client).editMessage(
        sessionId: 's1',
        messageId: 'u1',
        content: 'better question',
        idempotencyKey: 'key-edit',
      );
      expect(seen.last.headers['idempotency-key'], 'key-edit');
      expect(seen.last.headers['accept'], 'text/event-stream');
      expect((seen.last.body as Map)['content'], 'better question');
      final events = await turn.events.toList();
      expect(events.map((e) => e.runtimeType), [
        UserMessageEvent,
        TokenEvent,
        DoneEvent,
        AssistantMessageEvent,
      ]);
      final user = events.first as UserMessageEvent;
      expect(user.parentId, 'a0');
      expect(user.generationId, 'g2');
      expect(user.toMessage('s1').siblings?.count, 2);
      expect((events.last as AssistantMessageEvent).toMessage('s1').parentId, 'u2');
      expect(turn.generationId, 'g2');
      expect(turn.lastEventId, '4');
    });
  });

  group('generations', () {
    test('a streamed turn tracks its generation id and the last seq', () async {
      final turn = await ChatRepository(client).streamMessage(
        sessionId: 's1',
        content: 'hi',
        transport: StreamTransport.sse,
        idempotencyKey: 'key-stream',
      );
      expect(seen.last.headers['idempotency-key'], 'key-stream');
      expect(turn.generationId, isNull, reason: 'unknown until the first frame');
      final events = await turn.events.toList();
      expect(events, hasLength(5));
      expect(turn.generationId, 'g1');
      expect(turn.lastEventId, '5');
    });

    test('stopping an SSE turn calls the stop endpoint before closing', () async {
      final repo = ChatRepository(client);
      final turn =
          await repo.streamMessage(sessionId: 's1', content: 'hi', transport: StreamTransport.sse);
      final first = await turn.events.first; // user_message carries the generation id
      expect(first, isA<UserMessageEvent>());
      expect(turn.generationId, 'g1');
      await turn.stop();
      expect(seen.last.method, 'POST');
      expect(seen.last.path, '/sessions/s1/generations/g1/stop');
    });

    test('events replay honours after= and Last-Event-ID', () async {
      final repo = ChatRepository(client);
      final turn = await repo.resumeGeneration('s1', 'g1', after: '2');
      expect(seen.last.method, 'GET');
      expect(seen.last.query, {'after': '2'});
      expect(seen.last.headers['last-event-id'], '2');
      expect(seen.last.headers['accept'], 'text/event-stream');
      expect(turn.generationId, 'g1', reason: 'known up front');
      final events = await turn.events.toList();
      expect(events.map((e) => e.runtimeType), [TokenEvent, DoneEvent, AssistantMessageEvent]);
      expect((events.first as TokenEvent).token, 'lo');
      expect(turn.lastEventId, '5');

      final full = await repo.resumeGeneration('s1', 'g1');
      expect(seen.last.query, isEmpty);
      expect(seen.last.headers.containsKey('last-event-id'), isFalse);
      final all = await full.events.toList();
      expect(all, hasLength(5));
      expect((all.first as UserMessageEvent).generationId, 'g1');

      try {
        await repo.resumeGeneration('s1', 'g-old');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isNotFound, isTrue);
      }
    });

    test('active generation: object or null', () async {
      final repo = ChatRepository(client);
      final active = await repo.activeGeneration('s1');
      expect(active?.generationId, 'g1');
      expect(active?.isRunning, isTrue);
      expect(active?.startedAt?.toUtc().year, 2026);
      expect(await repo.activeGeneration('s2'), isNull);
    });

    test('background send returns 202 with the generation and the user message', () async {
      final accepted = await ChatRepository(client).sendBackground(
        sessionId: 's1',
        content: 'later',
        idempotencyKey: 'key-bg',
      );
      expect(seen.last.headers['idempotency-key'], 'key-bg');
      expect((seen.last.body as Map)['content'], 'later');
      expect(accepted.generationId, 'g7');
      expect(accepted.userMessage?.id, 'u7');
      expect(accepted.userMessage?.content, 'later');
    });

    test('sends without a key carry no Idempotency-Key header', () async {
      await ChatRepository(client).sendBlocking(sessionId: 's1', content: 'x');
      expect(seen.last.headers.containsKey('idempotency-key'), isFalse);
    });
  });

  // ── Phase 4 ───────────────────────────────────────────────────────────

  group('attachments', () {
    test('upload is multipart; the 201 carries the sniffed kind and text excerpt', () async {
      final repo = AttachmentsRepository(client);
      final progress = <double>[];
      final att = await repo.upload(
        sessionId: 's1',
        bytes: Uint8List.fromList(utf8.encode('hello attachment')),
        filename: 'notes.txt',
        onProgress: progress.add,
      );
      expect(seen.last.headers['content-type'], startsWith('multipart/form-data'));
      final files = (seen.last.body as Map)['files'] as Map;
      expect(files['file'], {'filename': 'notes.txt', 'size': 16, 'content': 'hello attachment'});
      expect(att.id, 'a-new');
      expect(att.kind, AttachmentKind.file);
      expect(att.name, 'notes.txt');
      expect(att.sizeBytes, 16);
      expect(att.hasText, isTrue);
      expect(att.textExcerpt, 'hello');
      expect(att.sessionId, 's1');
      expect(att.messageId, isNull);
      expect(att.url, '/api/v1/sessions/s1/attachments/a-new/content');
      expect(progress, isNotEmpty);
      expect(progress.last, 1.0);

      final image = await repo.upload(
        sessionId: 's1',
        bytes: pngBytes,
        filename: 'chart.png',
      );
      expect(image.kind, AttachmentKind.image);
      expect(image.width, 1200);
      expect(image.isRenderableImage, isTrue);
    });

    test('a refused upload surfaces the 422 envelope; empty / oversized never leave', () async {
      final repo = AttachmentsRepository(client);
      try {
        await repo.upload(sessionId: 's1', bytes: Uint8List.fromList([1]), filename: 'x.exe');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 422);
        expect(e.message, 'File type not allowed');
        expect(e.details?['allowed_extensions'], ['pdf', 'txt']);
      }
      final before = seen.length;
      await expectLater(
        repo.upload(sessionId: 's1', bytes: Uint8List(0), filename: 'empty.txt'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 422)),
      );
      expect(seen.length, before, reason: 'checked client-side');
    });

    test('list, get and delete', () async {
      final repo = AttachmentsRepository(client);
      final all = await repo.list('s1');
      expect(all.map((a) => a.id), ['a1', 'a2']);
      expect(all.first.messageId, 'u1');
      expect(all.last.isAudio, isTrue);
      expect(all.last.hasText, isTrue);
      expect((await repo.get('s1', 'a1')).name, 'chart.png');
      await repo.delete('s1', 'a1');
      expect(seen.last.method, 'DELETE');
      expect(seen.last.path, '/sessions/s1/attachments/a1');
    });

    test('content: served bytes come with the bearer; a 307 is followed without it', () async {
      final repo = AttachmentsRepository(client);
      client.activeOrgId = () => 'o1';
      final direct = await repo.fetchContent('/api/v1/sessions/s1/attachments/a1/content');
      expect(direct.mimeType, 'image/png');
      expect(direct.bytes, pngBytes);
      expect(seen.last.headers['authorization'], 'Bearer $access');
      expect(seen.last.headers['x-org-id'], 'o1');

      final redirected = await repo.fetchContent('/api/v1/sessions/s1/attachments/a2/content');
      expect(redirected.mimeType, 'image/png');
      expect(redirected.bytes, pngBytes, reason: 'fetched from the presigned URL');
      expect(seen.last.path, '/api/v1/sessions/s1/attachments/a2/content');

      try {
        await repo.fetchContent('/api/v1/sessions/s1/attachments/missing/content');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isNotFound, isTrue);
        expect(e.message, 'Attachment not found');
      }
    });

    test('resolveUrl maps server paths onto the API origin', () {
      final repo = AttachmentsRepository(client);
      expect(
        repo.resolveUrl('/api/v1/sessions/s1/attachments/a1/content').toString(),
        'http://127.0.0.1:${server.port}/api/v1/sessions/s1/attachments/a1/content',
      );
      expect(
        repo.resolveUrl('https://cdn.example.com/x?sig=1').toString(),
        'https://cdn.example.com/x?sig=1',
      );
      expect(
        AttachmentsRepository.resolveAgainst('https://api.example.com/api/v1', '/api/v1/a')
            .toString(),
        'https://api.example.com/api/v1/a',
      );
      expect(
        AttachmentsRepository.resolveAgainst('https://api.example.com/api/v1', 'rel/x').toString(),
        'https://api.example.com/api/v1/rel/x',
      );
    });

    test('the content loader caches by URL and drops failures', () async {
      final repo = AttachmentsRepository(client);
      final loader = CachingAttachmentContentLoader(Future.value(repo), maxEntries: 2);
      final before = seen.length;
      await loader.load('/api/v1/sessions/s1/attachments/a1/content');
      await loader.load('/api/v1/sessions/s1/attachments/a1/content');
      expect(seen.length, before + 1, reason: 'second load served from memory');
      await expectLater(
        loader.load('/api/v1/sessions/s1/attachments/missing/content'),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        loader.load('/api/v1/sessions/s1/attachments/missing/content'),
        throwsA(isA<ApiException>()),
      );
      expect(seen.length, before + 3, reason: 'a failure is fetched again');
    });
  });

  group('voice', () {
    test('GET /audio/voices → capabilities', () async {
      final caps = await VoiceRepository(client).capabilities();
      expect(caps.provider, 'openai');
      expect(caps.sttAvailable, isTrue);
      expect(caps.ttsAvailable, isTrue);
      expect(caps.any, isTrue);
      expect(caps.defaultVoice, 'alloy');
      expect(caps.defaultFormat, 'mp3');
      expect(caps.voices.map((v) => v.name), ['Alloy', 'Nova']);
      expect(caps.labelFor('nova'), 'Nova');
      expect(caps.labelFor(null), 'Server default');
      expect(caps.labelFor('ghost'), 'ghost');
    });

    test('transcription is multipart with an optional language', () async {
      final t = await VoiceRepository(client).transcribe(
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        filename: 'voice.m4a',
        language: 'en',
      );
      final form = seen.last.body as Map;
      expect((form['files'] as Map)['file']['filename'], 'voice.m4a');
      expect((form['files'] as Map)['file']['size'], 4);
      expect((form['fields'] as Map)['language'], 'en');
      expect(t.text, 'hello from voice.m4a');
      expect(t.language, 'en');
      expect(t.durationSeconds, 1.5);
      expect(t.provider, 'openai');
    });

    test('speech streams audio bytes; an unknown voice is a 422', () async {
      final repo = VoiceRepository(client);
      final audio = await repo.speech(text: 'Hello', voice: 'nova', format: 'mp3');
      expect(seen.last.body, {'text': 'Hello', 'voice': 'nova', 'format': 'mp3'});
      expect(audio.mimeType, 'audio/mpeg');
      expect(audio.bytes, [0xFF, 0xFB, 0x90, 0x00]);
      try {
        await repo.speech(text: 'Boo', voice: 'ghost');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 422);
      }
    });

    test('a voice turn is a multipart 202 with the form fields and the Idempotency-Key', () async {
      final turn = await VoiceRepository(client).sendVoiceTurn(
        sessionId: 's1',
        bytes: Uint8List.fromList(List.filled(10, 1)),
        filename: 'voice.wav',
        useTools: false,
        model: 'gpt-4o-mini',
        voice: 'alloy',
        audioFormat: 'wav',
        idempotencyKey: 'key-voice',
      );
      expect(seen.last.headers['idempotency-key'], 'key-voice');
      final form = seen.last.body as Map;
      expect((form['files'] as Map)['file']['size'], 10);
      expect(form['fields'], {
        'use_rag': 'true',
        'use_tools': 'false',
        'reply_audio': 'true',
        'model': 'gpt-4o-mini',
        'voice': 'alloy',
        'audio_format': 'wav',
      });
      expect(turn.generationId, 'g-voice');
      expect(turn.transcript, 'what is the weather (10 bytes)');
      expect(turn.userMessageId, 'u-voice');
      expect(turn.attachmentId, 'a-voice');

      try {
        await VoiceRepository(client).sendVoiceTurn(
          sessionId: 's-novoice',
          bytes: Uint8List.fromList([1]),
          filename: 'voice.wav',
        );
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 503);
        expect(e.details?['code'], 'voice_unavailable');
      }
    });

    test('sends carry attachment_ids and voice_reply only when set', () async {
      final repo = ChatRepository(client);
      await repo.sendBlocking(
        sessionId: 's1',
        content: 'look',
        attachmentIds: ['a1'],
        voiceReply: const VoiceReply(voice: 'nova', audioFormat: 'wav'),
      );
      final body = seen.last.body as Map;
      expect(body['attachment_ids'], ['a1']);
      expect(body['voice_reply'], isTrue);
      expect(body['voice'], 'nova');
      expect(body['audio_format'], 'wav');

      await repo.sendBlocking(sessionId: 's1', content: 'plain', attachmentIds: const []);
      final plain = seen.last.body as Map;
      expect(plain.containsKey('attachment_ids'), isFalse, reason: 'empty list is omitted');
      expect(plain.containsKey('voice_reply'), isFalse);

      await repo.sendBackground(sessionId: 's1', content: 'bg', attachmentIds: ['a2']);
      expect((seen.last.body as Map)['attachment_ids'], ['a2']);
      await repo.editMessage(
        sessionId: 's1',
        messageId: 'u1',
        content: 'edit',
        attachmentIds: ['a3'],
        voiceReply: const VoiceReply(),
      );
      expect((seen.last.body as Map)['attachment_ids'], ['a3']);
      expect((seen.last.body as Map)['voice_reply'], isTrue);
      expect((seen.last.body as Map).containsKey('voice'), isFalse);
    });
  });

  group('MCP servers', () {
    test('every call names the organization through X-Org-Id', () async {
      final repo = MCPRepository(client);
      final servers = await repo.list('o1');
      expect(seen.last.headers['x-org-id'], 'o1');
      expect(servers.map((s) => s.name), ['github', 'broken']);
      expect(servers.first.transport, MCPTransport.http);
      expect(servers.first.url, 'https://mcp.example.com/github');
      expect(servers.first.headerKeys, ['Authorization']);
      expect(servers.first.endpointLabel, 'https://mcp.example.com/github');
      expect(servers.first.requiresApproval, isTrue);
      expect(servers.last.enabled, isFalse);

      client.activeOrgId = () => 'o-personal';
      await repo.list('o1');
      expect(seen.last.headers['x-org-id'], 'o1', reason: 'explicit org wins over the active one');
      try {
        await repo.list('o-other');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isForbidden, isTrue);
      }
    });

    test('create (201 / 409 / 403), get, update, delete', () async {
      final repo = MCPRepository(client);
      final created = await repo.create(
        'o1',
        const MCPServerDraft(
          name: 'jira',
          transport: MCPTransport.sse,
          url: 'https://mcp.example.com/jira',
          headers: {'Authorization': 'Bearer x'},
          description: 'Jira',
          requiresApproval: false,
        ),
      );
      expect(seen.last.body, {
        'name': 'jira',
        'transport': 'sse',
        'description': 'Jira',
        'url': 'https://mcp.example.com/jira',
        'headers': {'Authorization': 'Bearer x'},
        'enabled': true,
        'requires_approval': false,
      });
      expect(created.id, 'm-new');
      expect(created.name, 'jira');
      expect(created.headerKeys, ['Authorization']);
      expect(created.requiresApproval, isFalse);

      final stdio = const MCPServerDraft(
        name: 'local',
        transport: MCPTransport.stdio,
        command: 'npx',
        args: ['-y', 'server'],
        env: {'TOKEN': 't'},
      ).toJson();
      expect(stdio, {
        'name': 'local',
        'transport': 'stdio',
        'command': 'npx',
        'args': ['-y', 'server'],
        'env': {'TOKEN': 't'},
        'enabled': true,
        'requires_approval': true,
      });

      try {
        await repo.create(
          'o1',
          const MCPServerDraft(name: 'github', transport: MCPTransport.http, url: 'https://x'),
        );
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isConflict, isTrue);
      }
      try {
        await repo.create(
          'o1',
          const MCPServerDraft(name: 'local', transport: MCPTransport.stdio, command: 'npx'),
        );
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isForbidden, isTrue);
      }

      expect((await repo.get('o1', 'm1')).description, 'GitHub tools');

      final disabled = await repo.update('o1', 'm1', enabled: false);
      expect(seen.last.body, {'enabled': false}, reason: 'only the given fields');
      expect(disabled.enabled, isFalse);
      final noApproval = await repo.update('o1', 'm1', requiresApproval: false, description: 'x');
      expect(seen.last.body, {'description': 'x', 'requires_approval': false});
      expect(noApproval.requiresApproval, isFalse);
      expect(noApproval.copyWith(enabled: false).enabled, isFalse);

      await repo.delete('o1', 'm1');
      expect(seen.last.method, 'DELETE');
      expect(seen.last.path, '/mcp/servers/m1');
    });

    test('test connection lists the tools or the error; cached tools endpoint', () async {
      final repo = MCPRepository(client);
      final ok = await repo.test('o1', 'm1');
      expect(seen.last.method, 'POST');
      expect(ok.ok, isTrue);
      expect(ok.latencyMs, 42);
      expect(ok.tools.single.name, 'mcp:github:search_issues');
      expect(ok.tools.single.tool, 'search_issues');
      expect(ok.tools.single.server, 'github');
      expect(ok.tools.single.inputSchema['type'], 'object');
      expect(ok.tools.single.requiresApproval, isTrue);

      final failed = await repo.test('o1', 'm2');
      expect(failed.ok, isFalse);
      expect(failed.error, 'connection refused');
      expect(failed.tools, isEmpty);

      final tools = await repo.tools('o1', 'm1');
      expect(tools.single.description, 'Find issues');
    });

    test('KEY=value parsing for headers and env', () {
      expect(parseKeyValueLines('A=1\n\nB = two words \nbroken\n=nokey\n'), {
        'A': '1',
        'B': 'two words',
      });
      expect(MCPTransport.fromString('sse'), MCPTransport.sse);
      expect(MCPTransport.fromString('weird'), MCPTransport.http);
      expect(MCPTransport.stdio.isRemote, isFalse);
    });
  });

  group('export & share', () {
    test('export downloads bytes with the server\'s filename and type', () async {
      final repo = ShareRepository(client);
      final md = await repo.export('s1');
      expect(seen.last.query, {'format': 'markdown', 'include_tools': 'true'});
      expect(md.filename, 'invoices.md');
      expect(md.mimeType, 'text/markdown');
      expect(utf8.decode(md.bytes), startsWith('# Invoices'));

      final json = await repo.export('s1', format: ExportFormat.json, includeTools: false);
      expect(seen.last.query, {'format': 'json', 'include_tools': 'false'});
      expect(json.filename, 'invoices.json');
      expect(json.mimeType, 'application/json');
      expect(jsonDecode(utf8.decode(json.bytes))['session']['title'], 'Invoices');

      try {
        await repo.export('s-missing');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 404);
      }
    });

    test('filename parsing from Content-Disposition', () {
      expect(ShareRepository.filenameFromDisposition('attachment; filename="chat.md"'), 'chat.md');
      expect(
        ShareRepository.filenameFromDisposition('attachment; filename=chat.json'),
        'chat.json',
      );
      expect(
        ShareRepository.filenameFromDisposition("attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.md"),
        'résumé.md',
      );
      expect(ShareRepository.filenameFromDisposition('inline'), isNull);
      expect(ShareRepository.filenameFromDisposition(null), isNull);
    });

    test('share links: create (token once), list, revoke one / all', () async {
      final repo = ShareRepository(client);
      final created = await repo.createShare('s1', expiresInHours: 48);
      expect(seen.last.body, {'expires_in_hours': 48});
      expect(created.id, 'sh-new');
      expect(created.token, 'tok-secret');
      expect(created.url, '/api/v1/shared/tok-secret');
      expect(
        repo.resolveShareUrl(created.url!).toString(),
        'http://127.0.0.1:${server.port}/api/v1/shared/tok-secret',
      );
      expect(
        repo.resolveShareUrl('https://nexus.example/shared/x').toString(),
        'https://nexus.example/shared/x',
      );
      expect(created.expiresAt.toUtc().day, 9);
      expect(created.views, 0);

      await repo.createShare('s1');
      expect(seen.last.body, isEmpty, reason: 'server default expiry');

      final links = await repo.listShares('s1');
      expect(links.single.id, 'sh-1');
      expect(links.single.token, isNull);
      expect(links.single.url, isNull);
      expect(links.single.views, 3);

      await repo.revokeShares('s1', shareId: 'sh-1');
      expect(seen.last.method, 'DELETE');
      expect(seen.last.query, {'share_id': 'sh-1'});
      await repo.revokeShares('s1');
      expect(seen.last.query, isEmpty);
    });
  });

  group('devices', () {
    test('register (201), list, unregister (200 / 404)', () async {
      final repo = DevicesRepository(client);
      final device = await repo.register(
        platform: 'android',
        token: 'fcm-token-abcdef',
        appVersion: '1.0.0',
        locale: 'en-GB',
      );
      expect(seen.last.body, {
        'platform': 'android',
        'token': 'fcm-token-abcdef',
        'app_version': '1.0.0',
        'locale': 'en-GB',
      });
      expect(device.id, 'd1');
      expect(device.tokenSuffix, 'abcdef');
      expect(device.lastSeenAt, isNotNull);

      final list = await repo.list();
      expect(list.pushEnabled, isTrue);
      expect(list.items.single.platform, 'android');
      expect(list.items.single.locale, 'en-GB');

      await repo.unregister('fcm-token-abcdef');
      expect(seen.last.method, 'DELETE');
      expect(seen.last.path, '/devices/fcm-token-abcdef');
      try {
        await repo.unregister('unknown');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isNotFound, isTrue);
      }
    });
  });
}
