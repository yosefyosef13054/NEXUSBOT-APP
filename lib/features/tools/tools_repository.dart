import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';

/// One entry of `GET /tools`. Tools with [requiresApproval] pause the turn
/// with an `approval_required` event before they run. [source] is `builtin`
/// or `mcp:<server>` for a tool served by one of the workspace's MCP servers
/// (named `mcp:<server>:<tool>`); both kinds go into `tool_names` alike.
class ToolInfo {
  const ToolInfo({
    required this.name,
    this.description = '',
    this.requiresApproval = false,
    this.source = builtinSource,
  });

  factory ToolInfo.fromJson(Map<String, dynamic> j) => ToolInfo(
        name: (j['name'] as String?) ?? '',
        description: (j['description'] as String?) ?? '',
        requiresApproval: j['requires_approval'] == true,
        source: (j['source'] as String?) ?? builtinSource,
      );

  static const builtinSource = 'builtin';
  static const _mcpPrefix = 'mcp:';

  final String name;
  final String description;
  final bool requiresApproval;
  final String source;

  bool get isBuiltin => !source.startsWith(_mcpPrefix);

  /// The MCP server name for `mcp:<server>` sources, null for built-ins.
  String? get serverName => isBuiltin ? null : source.substring(_mcpPrefix.length);

  /// Group heading in the tool picker: `Built-in` or the server name.
  String get sourceLabel => isBuiltin ? 'Built-in' : (serverName ?? source);

  /// The tool's own name without the `mcp:<server>:` prefix.
  String get shortName {
    final server = serverName;
    if (server == null) return name;
    final prefix = '$_mcpPrefix$server:';
    return name.startsWith(prefix) ? name.substring(prefix.length) : name;
  }
}

/// Tools grouped for the picker: built-ins first, then one group per MCP
/// server (alphabetically), each keeping the server's order.
List<ToolGroup> groupToolsBySource(List<ToolInfo> tools) {
  final builtin = <ToolInfo>[];
  final byServer = <String, List<ToolInfo>>{};
  for (final t in tools) {
    if (t.isBuiltin) {
      builtin.add(t);
    } else {
      byServer.putIfAbsent(t.sourceLabel, () => []).add(t);
    }
  }
  final servers = byServer.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [
    if (builtin.isNotEmpty) ToolGroup(label: 'Built-in', tools: builtin, isBuiltin: true),
    for (final s in servers) ToolGroup(label: s, tools: byServer[s]!, isBuiltin: false),
  ];
}

class ToolGroup {
  const ToolGroup({required this.label, required this.tools, required this.isBuiltin});
  final String label;
  final List<ToolInfo> tools;
  final bool isBuiltin;
}

class ToolsRepository {
  ToolsRepository(this._client);
  final ApiClient _client;

  Future<List<ToolInfo>> list() async {
    final res = await _client.request<Map<String, dynamic>>('/tools');
    return (res.data?['items'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => ToolInfo.fromJson(m.cast<String, dynamic>()))
        .where((t) => t.name.isNotEmpty)
        .toList();
  }
}

final toolsRepositoryProvider = FutureProvider<ToolsRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return ToolsRepository(client);
});

/// Loaded once per app session (the tool set is server-wide).
final toolCatalogProvider = FutureProvider<List<ToolInfo>>((ref) async {
  final repo = await ref.watch(toolsRepositoryProvider.future);
  return repo.list();
});

/// The tool picker's default: every tool that runs without asking first.
/// Approval-required tools are opt-in per chat.
List<String> defaultToolSelection(List<ToolInfo> tools) => [
      for (final t in tools)
        if (!t.requiresApproval) t.name,
    ];
