import 'package:dio/dio.dart' show Options;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import 'mcp_model.dart';

/// `/mcp/servers` — the MCP servers of one organization.
///
/// The endpoints act on the *active* organization (`X-Org-Id`); every call
/// here names the organization explicitly so the `/orgs/:id/mcp` screen
/// manages the workspace it was opened for, whichever one is active.
class MCPRepository {
  MCPRepository(this._client);
  final ApiClient _client;

  static Options _org(String orgId) => Options(headers: {ApiClient.orgHeader: orgId});

  Future<List<MCPServer>> list(String orgId) async {
    final res = await _client.request<Map<String, dynamic>>('/mcp/servers', options: _org(orgId));
    return (res.data?['items'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => MCPServer.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// → 201. 403 `forbidden` for non-admins (and for `stdio` without
  /// server-admin rights), 409 `conflict` on a duplicate name, 422 when the
  /// transport lacks its URL / command.
  Future<MCPServer> create(String orgId, MCPServerDraft draft) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/mcp/servers',
      method: 'POST',
      data: draft.toJson(),
      options: _org(orgId),
    );
    return MCPServer.fromJson(res.data!);
  }

  Future<MCPServer> get(String orgId, String serverId) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/mcp/servers/$serverId',
      options: _org(orgId),
    );
    return MCPServer.fromJson(res.data!);
  }

  /// `PATCH /mcp/servers/{id}` — only the given fields are sent (the server
  /// rejects unknown keys with 422).
  Future<MCPServer> update(
    String orgId,
    String serverId, {
    String? description,
    String? url,
    Map<String, String>? headers,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    bool? enabled,
    bool? requiresApproval,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/mcp/servers/$serverId',
      method: 'PATCH',
      data: {
        if (description != null) 'description': description,
        if (url != null) 'url': url,
        if (headers != null) 'headers': headers,
        if (command != null) 'command': command,
        if (args != null) 'args': args,
        if (env != null) 'env': env,
        if (enabled != null) 'enabled': enabled,
        if (requiresApproval != null) 'requires_approval': requiresApproval,
      },
      options: _org(orgId),
    );
    return MCPServer.fromJson(res.data!);
  }

  Future<void> delete(String orgId, String serverId) async {
    await _client.request<dynamic>(
      '/mcp/servers/$serverId',
      method: 'DELETE',
      options: _org(orgId),
    );
  }

  /// Connects to the server and lists its tools (also refreshes the cache).
  Future<MCPTestResult> test(String orgId, String serverId) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/mcp/servers/$serverId/test',
      method: 'POST',
      options: _org(orgId).copyWith(receiveTimeout: const Duration(minutes: 2)),
    );
    return MCPTestResult.fromJson(res.data ?? const {});
  }

  /// The cached tool list of a server.
  Future<List<MCPTool>> tools(String orgId, String serverId) async {
    final res = await _client.request<dynamic>(
      '/mcp/servers/$serverId/tools',
      options: _org(orgId),
    );
    final body = res.data;
    final raw = body is List ? body : (body is Map ? body['items'] : null);
    return (raw as List? ?? const [])
        .whereType<Map>()
        .map((m) => MCPTool.fromJson(m.cast<String, dynamic>()))
        .toList();
  }
}

final mcpRepositoryProvider = FutureProvider<MCPRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return MCPRepository(client);
});

/// The servers of one organization (by id).
final mcpServersProvider =
    FutureProvider.autoDispose.family<List<MCPServer>, String>((ref, orgId) async {
  final repo = await ref.watch(mcpRepositoryProvider.future);
  return repo.list(orgId);
});
