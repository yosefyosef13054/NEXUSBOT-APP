import 'package:collection/collection.dart';

/// How the API host reaches an MCP server.
enum MCPTransport {
  http,
  sse,
  stdio;

  static MCPTransport fromString(String? s) =>
      MCPTransport.values.firstWhereOrNull((t) => t.name == s) ?? MCPTransport.http;

  String get label => switch (this) {
        MCPTransport.http => 'HTTP',
        MCPTransport.sse => 'SSE',
        MCPTransport.stdio => 'stdio (command on the API host)',
      };

  /// `http` / `sse` need a URL; `stdio` needs a command.
  bool get isRemote => this != MCPTransport.stdio;
}

/// One registered server (`MCPServerRead`). Secrets never come back: only
/// the names of the configured `env` / `headers` keys.
class MCPServer {
  const MCPServer({
    required this.id,
    required this.orgId,
    required this.name,
    required this.transport,
    required this.enabled,
    required this.requiresApproval,
    this.description,
    this.command,
    this.args = const [],
    this.envKeys = const [],
    this.url,
    this.headerKeys = const [],
    this.createdBy,
    this.createdAt,
    this.updatedAt,
  });

  factory MCPServer.fromJson(Map<String, dynamic> j) => MCPServer(
        id: (j['id'] as String?) ?? '',
        orgId: (j['org_id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        description: j['description'] as String?,
        transport: MCPTransport.fromString(j['transport'] as String?),
        command: j['command'] as String?,
        args: (j['args'] as List? ?? const []).map((e) => e.toString()).toList(),
        envKeys: (j['env_keys'] as List? ?? const []).map((e) => e.toString()).toList(),
        url: j['url'] as String?,
        headerKeys: (j['header_keys'] as List? ?? const []).map((e) => e.toString()).toList(),
        enabled: j['enabled'] != false,
        requiresApproval: j['requires_approval'] != false,
        createdBy: j['created_by'] as String?,
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
        updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? ''),
      );

  final String id;
  final String orgId;
  final String name;
  final String? description;
  final MCPTransport transport;
  final String? command;
  final List<String> args;
  final List<String> envKeys;
  final String? url;
  final List<String> headerKeys;
  final bool enabled;
  final bool requiresApproval;
  final String? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// `https://…` or `cmd arg1 arg2` — where the server lives.
  String get endpointLabel =>
      transport.isRemote ? (url ?? '') : [if (command != null) command!, ...args].join(' ');

  MCPServer copyWith({bool? enabled, bool? requiresApproval}) => MCPServer(
        id: id,
        orgId: orgId,
        name: name,
        description: description,
        transport: transport,
        command: command,
        args: args,
        envKeys: envKeys,
        url: url,
        headerKeys: headerKeys,
        enabled: enabled ?? this.enabled,
        requiresApproval: requiresApproval ?? this.requiresApproval,
        createdBy: createdBy,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

/// A tool an MCP server exposes (`MCPToolRead`): [name] is the full
/// `mcp:<server>:<tool>` used in `tool_names`.
class MCPTool {
  const MCPTool({
    required this.name,
    required this.server,
    required this.tool,
    this.description = '',
    this.inputSchema = const {},
    this.requiresApproval = true,
  });

  factory MCPTool.fromJson(Map<String, dynamic> j) => MCPTool(
        name: (j['name'] as String?) ?? '',
        server: (j['server'] as String?) ?? '',
        tool: (j['tool'] as String?) ?? '',
        description: (j['description'] as String?) ?? '',
        inputSchema: (j['input_schema'] as Map?)?.cast<String, dynamic>() ?? const {},
        requiresApproval: j['requires_approval'] != false,
      );

  final String name;
  final String server;
  final String tool;
  final String description;
  final Map<String, dynamic> inputSchema;
  final bool requiresApproval;
}

/// `POST /mcp/servers/{id}/test`.
class MCPTestResult {
  const MCPTestResult({
    required this.ok,
    this.tools = const [],
    this.error,
    this.latencyMs = 0,
  });

  factory MCPTestResult.fromJson(Map<String, dynamic> j) => MCPTestResult(
        ok: j['ok'] == true,
        tools: (j['tools'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => MCPTool.fromJson(m.cast<String, dynamic>()))
            .toList(),
        error: j['error'] as String?,
        latencyMs: (j['latency_ms'] as num?)?.toInt() ?? 0,
      );

  final bool ok;
  final List<MCPTool> tools;
  final String? error;
  final int latencyMs;
}

/// What `POST /mcp/servers` takes. Secrets (`headers`, `env`) are sent once
/// and never read back.
class MCPServerDraft {
  const MCPServerDraft({
    required this.name,
    required this.transport,
    this.description,
    this.url,
    this.headers = const {},
    this.command,
    this.args = const [],
    this.env = const {},
    this.enabled = true,
    this.requiresApproval = true,
  });

  final String name;
  final MCPTransport transport;
  final String? description;
  final String? url;
  final Map<String, String> headers;
  final String? command;
  final List<String> args;
  final Map<String, String> env;
  final bool enabled;
  final bool requiresApproval;

  Map<String, Object?> toJson() => {
        'name': name,
        'transport': transport.name,
        if (description != null && description!.isNotEmpty) 'description': description,
        if (transport.isRemote) 'url': url,
        if (transport.isRemote && headers.isNotEmpty) 'headers': headers,
        if (!transport.isRemote) 'command': command,
        if (!transport.isRemote && args.isNotEmpty) 'args': args,
        if (!transport.isRemote && env.isNotEmpty) 'env': env,
        'enabled': enabled,
        'requires_approval': requiresApproval,
      };
}

/// Parses `KEY=value` lines (headers / env) into a map; blank lines and
/// lines without `=` are skipped.
Map<String, String> parseKeyValueLines(String text) {
  final out = <String, String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim();
    if (key.isEmpty) continue;
    out[key] = line.substring(eq + 1).trim();
  }
  return out;
}
