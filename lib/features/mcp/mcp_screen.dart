import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/breakpoints.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../shared/home_shell.dart';
import '../auth/auth_providers.dart';
import '../orgs/orgs_repository.dart';
import 'mcp_model.dart';
import 'mcp_repository.dart';

/// `/orgs/:orgId/mcp` — the workspace's MCP (Model Context Protocol) tool
/// servers. Owners and admins add, edit, test and remove servers; everyone
/// else sees a read-only list. `stdio` servers (a command on the API host)
/// are only offered to server administrators.
class MCPServersScreen extends ConsumerStatefulWidget {
  const MCPServersScreen({super.key, required this.orgId});
  final String orgId;

  @override
  ConsumerState<MCPServersScreen> createState() => _MCPServersScreenState();
}

class _MCPServersScreenState extends ConsumerState<MCPServersScreen> {
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _refresh() => ref.invalidate(mcpServersProvider(widget.orgId));

  String _describe(Object e) {
    if (e is ApiException) {
      if (e.isConflict) return 'A server with this name already exists in the workspace.';
      if (e.isForbidden) return e.message;
    }
    return errorText(e);
  }

  Future<void> _add({required bool allowStdio}) async {
    final draft = await showDialog<MCPServerDraft>(
      context: context,
      builder: (_) => MCPServerDialog(allowStdio: allowStdio),
    );
    if (draft == null || !mounted) return;
    try {
      final repo = await ref.read(mcpRepositoryProvider.future);
      final created = await repo.create(widget.orgId, draft);
      _refresh();
      _toast('“${created.name}” added');
    } catch (e) {
      _toast(_describe(e));
    }
  }

  Future<void> _edit(MCPServer server, {required bool allowStdio}) async {
    final draft = await showDialog<MCPServerDraft>(
      context: context,
      builder: (_) => MCPServerDialog(existing: server, allowStdio: allowStdio),
    );
    if (draft == null || !mounted) return;
    try {
      final repo = await ref.read(mcpRepositoryProvider.future);
      await repo.update(
        widget.orgId,
        server.id,
        description: draft.description ?? '',
        url: draft.transport.isRemote ? draft.url : null,
        // Secrets are write-only: an empty field keeps what is stored.
        headers: draft.transport.isRemote && draft.headers.isNotEmpty ? draft.headers : null,
        command: draft.transport.isRemote ? null : draft.command,
        args: draft.transport.isRemote ? null : draft.args,
        env: !draft.transport.isRemote && draft.env.isNotEmpty ? draft.env : null,
        enabled: draft.enabled,
        requiresApproval: draft.requiresApproval,
      );
      _refresh();
    } catch (e) {
      _toast(_describe(e));
    }
  }

  Future<void> _patch(MCPServer server, {bool? enabled, bool? requiresApproval}) async {
    try {
      final repo = await ref.read(mcpRepositoryProvider.future);
      await repo.update(
        widget.orgId,
        server.id,
        enabled: enabled,
        requiresApproval: requiresApproval,
      );
      _refresh();
    } catch (e) {
      _toast(_describe(e));
    }
  }

  Future<void> _delete(MCPServer server) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove server?'),
        content: Text(
          '“${server.name}” and its tools will disappear from every chat and assistant '
          'of this workspace.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final repo = await ref.read(mcpRepositoryProvider.future);
      await repo.delete(widget.orgId, server.id);
      _refresh();
    } catch (e) {
      _toast(_describe(e));
    }
  }

  Future<void> _test(MCPServer server) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.tokens.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: NexusRadius.xl),
      ),
      builder: (_) => MCPTestSheet(orgId: widget.orgId, server: server),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final servers = ref.watch(mcpServersProvider(widget.orgId));
    final org = ref.watch(orgDetailProvider(widget.orgId)).valueOrNull;
    final canManage = org?.canManage ?? false;
    final allowStdio = ref.watch(currentUserProvider).valueOrNull?.isServerAdmin ?? false;

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text(
          org == null ? 'MCP servers' : 'MCP servers · ${org.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.textPrimary),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refresh,
          ),
        ],
      ),
      body: servers.when(
        loading: () => const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: NexusColors.crimson),
          ),
        ),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off_rounded,
          title: 'Could not load the servers',
          subtitle: errorText(e),
          action:
              NexusGhostButton(label: 'Retry', icon: Icons.refresh_rounded, onPressed: _refresh),
        ),
        data: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.extension_rounded,
              title: 'No MCP servers yet',
              subtitle: canManage
                  ? 'Register an HTTP or SSE Model Context Protocol server; its tools then '
                      'appear in the tool picker as mcp:<server>:<tool>.'
                  : 'Only owners and admins can register MCP servers.',
              action: canManage
                  ? NexusGhostButton(
                      label: 'Add server',
                      icon: Icons.add_rounded,
                      onPressed: () => _add(allowStdio: allowStdio),
                    )
                  : null,
            );
          }
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(NexusSpacing.lg),
                children: [
                  Text(
                    'Tools of enabled servers are offered to every chat and assistant of the '
                    'workspace. Servers marked with a shield ask for approval before a tool runs.',
                    style: TextStyle(color: t.textSecondary, fontSize: 12.5, height: 1.4),
                  ),
                  const SizedBox(height: NexusSpacing.md),
                  for (final s in list) ...[
                    MCPServerTile(
                      server: s,
                      canManage: canManage,
                      onToggleEnabled: (v) => _patch(s, enabled: v),
                      onToggleApproval: (v) => _patch(s, requiresApproval: v),
                      onTest: () => _test(s),
                      onEdit: () => _edit(s, allowStdio: allowStdio),
                      onDelete: () => _delete(s),
                    ),
                    const SizedBox(height: NexusSpacing.sm),
                  ],
                  const SizedBox(height: NexusSpacing.xxxl + 40),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => _add(allowStdio: allowStdio),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add server', style: TextStyle(fontWeight: FontWeight.w700)),
            )
          : null,
    );
  }
}

/// One server: transport badge, name, endpoint, enabled / approval switches
/// (admins) and a menu with test / edit / remove.
class MCPServerTile extends StatelessWidget {
  const MCPServerTile({
    super.key,
    required this.server,
    required this.canManage,
    this.onToggleEnabled,
    this.onToggleApproval,
    this.onTest,
    this.onEdit,
    this.onDelete,
  });

  final MCPServer server;
  final bool canManage;
  final ValueChanged<bool>? onToggleEnabled;
  final ValueChanged<bool>? onToggleApproval;
  final VoidCallback? onTest;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = server;
    final secrets = [
      if (s.headerKeys.isNotEmpty)
        '${s.headerKeys.length} header${s.headerKeys.length == 1 ? '' : 's'}',
      if (s.envKeys.isNotEmpty) '${s.envKeys.length} env var${s.envKeys.length == 1 ? '' : 's'}',
    ];
    return Container(
      padding: const EdgeInsets.all(NexusSpacing.md),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.lg),
        border: Border.all(color: s.enabled ? t.border : t.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.extension_rounded,
                size: 20,
                color: s.enabled ? NexusColors.crimson : t.textMuted,
              ),
              const SizedBox(width: NexusSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: s.enabled ? t.textPrimary : t.textMuted,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        const SizedBox(width: NexusSpacing.sm),
                        _TransportBadge(transport: s.transport),
                        if (s.requiresApproval) ...[
                          const SizedBox(width: 6),
                          const Tooltip(
                            message: 'Tools ask for approval before running',
                            child: Icon(Icons.shield_rounded, size: 14, color: NexusColors.warn),
                          ),
                        ],
                        if (!s.enabled) ...[
                          const SizedBox(width: 6),
                          Text('disabled', style: TextStyle(color: t.textMuted, fontSize: 11)),
                        ],
                      ],
                    ),
                    if (s.endpointLabel.isNotEmpty)
                      Text(
                        s.endpointLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.textMuted, fontSize: 12),
                      ),
                    if (s.description != null && s.description!.trim().isNotEmpty)
                      Text(
                        s.description!.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.textSecondary, fontSize: 12),
                      ),
                    if (secrets.isNotEmpty)
                      Text(
                        '${secrets.join(' · ')} (stored, never shown)',
                        style: TextStyle(color: t.textMuted, fontSize: 11),
                      ),
                  ],
                ),
              ),
              if (canManage)
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz_rounded, size: 18, color: t.textMuted),
                  onSelected: (v) {
                    if (v == 'test') onTest?.call();
                    if (v == 'edit') onEdit?.call();
                    if (v == 'delete') onDelete?.call();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'test', child: Text('Test connection')),
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'delete', child: Text('Remove')),
                  ],
                )
              else if (onTest != null)
                IconButton(
                  tooltip: 'Test connection',
                  icon: Icon(Icons.network_check_rounded, size: 18, color: t.textSecondary),
                  onPressed: onTest,
                ),
            ],
          ),
          if (canManage) ...[
            const SizedBox(height: NexusSpacing.sm),
            Row(
              children: [
                _SwitchLabel(
                  label: 'Enabled',
                  value: s.enabled,
                  onChanged: onToggleEnabled,
                ),
                const SizedBox(width: NexusSpacing.lg),
                _SwitchLabel(
                  label: 'Requires approval',
                  value: s.requiresApproval,
                  onChanged: onToggleApproval,
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: onTest,
                  icon: const Icon(Icons.network_check_rounded, size: 16),
                  label: const Text('Test'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SwitchLabel extends StatelessWidget {
  const _SwitchLabel({required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 28,
          child: FittedBox(
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: NexusColors.crimson,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: t.textSecondary, fontSize: 12)),
      ],
    );
  }
}

class _TransportBadge extends StatelessWidget {
  const _TransportBadge({required this.transport});
  final MCPTransport transport;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: NexusColors.crimson.withValues(alpha: 0.12),
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        border: Border.all(color: NexusColors.crimson.withValues(alpha: 0.4)),
      ),
      child: Text(
        transport.name.toUpperCase(),
        style: const TextStyle(
          color: NexusColors.crimson,
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

/// Add / edit form. Returns an [MCPServerDraft] (the name is fixed when
/// editing). Secrets typed here are sent once; when editing, leaving them
/// empty keeps what the server has.
class MCPServerDialog extends StatefulWidget {
  const MCPServerDialog({super.key, this.existing, this.allowStdio = false});

  final MCPServer? existing;

  /// Offer the `stdio` transport (server administrators only).
  final bool allowStdio;

  @override
  State<MCPServerDialog> createState() => _MCPServerDialogState();
}

class _MCPServerDialogState extends State<MCPServerDialog> {
  static final _namePattern = RegExp(r'^[a-z0-9][a-z0-9_-]*$');

  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.existing?.description ?? '');
  late final TextEditingController _url = TextEditingController(text: widget.existing?.url ?? '');
  final _headers = TextEditingController();
  late final TextEditingController _command =
      TextEditingController(text: widget.existing?.command ?? '');
  late final TextEditingController _args =
      TextEditingController(text: widget.existing?.args.join(' ') ?? '');
  final _env = TextEditingController();
  late MCPTransport _transport = widget.existing?.transport ?? MCPTransport.http;
  late bool _enabled = widget.existing?.enabled ?? true;
  late bool _requiresApproval = widget.existing?.requiresApproval ?? true;
  String? _error;

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _url.dispose();
    _headers.dispose();
    _command.dispose();
    _args.dispose();
    _env.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (_isNew && !_namePattern.hasMatch(name)) {
      setState(() => _error = 'Name: lowercase letters, digits, "-" or "_" (e.g. github)');
      return;
    }
    final url = _url.text.trim();
    final command = _command.text.trim();
    if (_transport.isRemote && !(url.startsWith('http://') || url.startsWith('https://'))) {
      setState(() => _error = 'Enter the server URL (http:// or https://)');
      return;
    }
    if (!_transport.isRemote && command.isEmpty) {
      setState(() => _error = 'Enter the command that starts the server');
      return;
    }
    Navigator.of(context).pop(
      MCPServerDraft(
        name: name,
        transport: _transport,
        description: _description.text.trim(),
        url: _transport.isRemote ? url : null,
        headers: _transport.isRemote ? parseKeyValueLines(_headers.text) : const {},
        command: _transport.isRemote ? null : command,
        args: _transport.isRemote
            ? const []
            : _args.text.trim().split(RegExp(r'\s+')).where((a) => a.isNotEmpty).toList(),
        env: _transport.isRemote ? const {} : parseKeyValueLines(_env.text),
        enabled: _enabled,
        requiresApproval: _requiresApproval,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final transports = [
      MCPTransport.http,
      MCPTransport.sse,
      if (widget.allowStdio || _transport == MCPTransport.stdio) MCPTransport.stdio,
    ];
    final secretHint = _isNew ? '' : ' (leave empty to keep the stored ones)';
    return AlertDialog(
      title: Text(_isNew ? 'Add MCP server' : 'Edit “${widget.existing!.name}”'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_isNew) ...[
                TextField(
                  controller: _name,
                  autofocus: true,
                  autocorrect: false,
                  decoration: const InputDecoration(hintText: 'Name (slug, e.g. github)'),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                ),
                const SizedBox(height: NexusSpacing.md),
              ],
              InputDecorator(
                decoration: const InputDecoration(labelText: 'Transport'),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<MCPTransport>(
                    isExpanded: true,
                    isDense: true,
                    value: _transport,
                    items: [
                      for (final tr in transports)
                        DropdownMenuItem(value: tr, child: Text(tr.label)),
                    ],
                    onChanged: _isNew ? (v) => setState(() => _transport = v ?? _transport) : null,
                  ),
                ),
              ),
              const SizedBox(height: NexusSpacing.md),
              if (_transport.isRemote) ...[
                TextField(
                  controller: _url,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(hintText: 'https://mcp.example.com/sse'),
                ),
                const SizedBox(height: NexusSpacing.md),
                TextField(
                  controller: _headers,
                  autocorrect: false,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: 'Headers, one per line$secretHint\nAuthorization=Bearer …',
                  ),
                ),
              ] else ...[
                TextField(
                  controller: _command,
                  autocorrect: false,
                  decoration: const InputDecoration(hintText: 'Command (e.g. npx)'),
                ),
                const SizedBox(height: NexusSpacing.md),
                TextField(
                  controller: _args,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    hintText:
                        'Arguments (space separated, e.g. -y @modelcontextprotocol/server-github)',
                  ),
                ),
                const SizedBox(height: NexusSpacing.md),
                TextField(
                  controller: _env,
                  autocorrect: false,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: 'Environment, one per line$secretHint\nGITHUB_TOKEN=…',
                  ),
                ),
              ],
              const SizedBox(height: NexusSpacing.md),
              TextField(
                controller: _description,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(hintText: 'Description (optional)'),
              ),
              const SizedBox(height: NexusSpacing.sm),
              SwitchListTile(
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
                activeTrackColor: NexusColors.crimson,
                contentPadding: EdgeInsets.zero,
                title: const Text('Enabled', style: TextStyle(fontSize: 14)),
              ),
              SwitchListTile(
                value: _requiresApproval,
                onChanged: (v) => setState(() => _requiresApproval = v),
                activeTrackColor: NexusColors.crimson,
                contentPadding: EdgeInsets.zero,
                title: const Text('Tools require approval', style: TextStyle(fontSize: 14)),
                subtitle: Text(
                  'Each call pauses the turn until the user approves it.',
                  style: TextStyle(color: t.textMuted, fontSize: 12),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: NexusSpacing.sm),
                Text(_error!, style: const TextStyle(color: NexusColors.danger, fontSize: 12.5)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: Text(_isNew ? 'Add' : 'Save'),
        ),
      ],
    );
  }
}

/// Runs `POST /mcp/servers/{id}/test` and shows the tools (or the error).
class MCPTestSheet extends ConsumerStatefulWidget {
  const MCPTestSheet({super.key, required this.orgId, required this.server});
  final String orgId;
  final MCPServer server;

  @override
  ConsumerState<MCPTestSheet> createState() => _MCPTestSheetState();
}

class _MCPTestSheetState extends ConsumerState<MCPTestSheet> {
  late Future<MCPTestResult> _future = _run();

  Future<MCPTestResult> _run() async {
    final repo = await ref.read(mcpRepositoryProvider.future);
    return repo.test(widget.orgId, widget.server.id);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.all(NexusSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Test “${widget.server.name}”',
                style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: NexusSpacing.sm),
              Flexible(
                child: FutureBuilder<MCPTestResult>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return _TestOutcome.failure(errorText(snapshot.error!));
                    }
                    final result = snapshot.data;
                    if (result == null) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: NexusSpacing.lg),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: NexusColors.crimson,
                              ),
                            ),
                            const SizedBox(width: NexusSpacing.md),
                            Text(
                              'Connecting…',
                              style: TextStyle(color: t.textSecondary, fontSize: 13),
                            ),
                          ],
                        ),
                      );
                    }
                    if (!result.ok) {
                      return _TestOutcome.failure(
                        result.error ?? 'The server did not answer',
                        latencyMs: result.latencyMs,
                      );
                    }
                    return _TestOutcome.success(result);
                  },
                ),
              ),
              const SizedBox(height: NexusSpacing.sm),
              Row(
                children: [
                  TextButton(
                    onPressed: () => setState(() => _future = _run()),
                    child: const Text('Test again'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TestOutcome extends StatelessWidget {
  const _TestOutcome.success(this.result) : error = null;
  _TestOutcome.failure(this.error, {int latencyMs = 0})
      : result = MCPTestResult(ok: false, latencyMs: latencyMs);

  final MCPTestResult result;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (error != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, size: 18, color: NexusColors.danger),
          const SizedBox(width: NexusSpacing.sm),
          Expanded(
            child: Text(
              'Connection failed: $error',
              style: TextStyle(color: t.textPrimary, fontSize: 13),
            ),
          ),
        ],
      );
    }
    final tools = result.tools;
    return ListView(
      shrinkWrap: true,
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle_rounded, size: 18, color: NexusColors.success),
            const SizedBox(width: NexusSpacing.sm),
            Text(
              'Connected in ${result.latencyMs} ms · ${tools.length} tool${tools.length == 1 ? '' : 's'}',
              style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: NexusSpacing.sm),
        if (tools.isEmpty)
          Text(
            'The server exposes no tools.',
            style: TextStyle(color: t.textMuted, fontSize: 12.5),
          ),
        for (final tool in tools)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              tool.requiresApproval ? Icons.shield_rounded : Icons.build_rounded,
              size: 16,
              color: tool.requiresApproval ? NexusColors.warn : NexusColors.crimson,
            ),
            title: Text(
              tool.tool.isEmpty ? tool.name : tool.tool,
              style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w700),
            ),
            subtitle: tool.description.isEmpty
                ? Text(tool.name, style: TextStyle(color: t.textMuted, fontSize: 11))
                : Text(
                    tool.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.textMuted, fontSize: 12),
                  ),
          ),
      ],
    );
  }
}
