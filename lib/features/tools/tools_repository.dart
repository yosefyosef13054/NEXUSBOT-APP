import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';

/// One entry of `GET /tools`. Tools with [requiresApproval] pause the turn
/// with an `approval_required` event before they run.
class ToolInfo {
  const ToolInfo({
    required this.name,
    this.description = '',
    this.requiresApproval = false,
  });

  factory ToolInfo.fromJson(Map<String, dynamic> j) => ToolInfo(
        name: (j['name'] as String?) ?? '',
        description: (j['description'] as String?) ?? '',
        requiresApproval: j['requires_approval'] == true,
      );

  final String name;
  final String description;
  final bool requiresApproval;
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
List<String> defaultToolSelection(List<ToolInfo> tools) =>
    [for (final t in tools) if (!t.requiresApproval) t.name];
