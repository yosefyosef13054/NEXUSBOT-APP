import '../auth/auth_models.dart';
import '../orgs/org_model.dart';

/// A persona (`AssistantRead`): a named bundle of system prompt, model,
/// tools, knowledge scope and memory setting that a chat can start from.
/// Org-wide; edited by its creator or an org admin.
class Assistant {
  const Assistant({
    required this.id,
    required this.name,
    required this.toolNames,
    required this.collectionIds,
    required this.useRag,
    required this.useTools,
    required this.memoryEnabled,
    required this.isDefault,
    this.orgId,
    this.description,
    this.avatar,
    this.systemPrompt,
    this.model,
    this.temperature,
    this.createdBy,
    this.createdAt,
    this.updatedAt,
  });

  factory Assistant.fromJson(Map<String, dynamic> j) => Assistant(
        id: j['id'] as String,
        orgId: j['org_id'] as String?,
        name: (j['name'] as String?) ?? 'Assistant',
        description: j['description'] as String?,
        avatar: j['avatar'] as String?,
        systemPrompt: j['system_prompt'] as String?,
        model: j['model'] as String?,
        toolNames: (j['tool_names'] as List? ?? const []).map((e) => e.toString()).toList(),
        collectionIds: (j['collection_ids'] as List? ?? const []).map((e) => e.toString()).toList(),
        useRag: j['use_rag'] != false,
        useTools: j['use_tools'] == true,
        temperature: (j['temperature'] as num?)?.toDouble(),
        memoryEnabled: j['memory_enabled'] != false,
        isDefault: j['is_default'] == true,
        createdBy: j['created_by'] as String?,
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
        updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? ''),
      );

  final String id;
  final String? orgId;
  final String name;
  final String? description;

  /// An emoji (or short text) shown as the avatar.
  final String? avatar;
  final String? systemPrompt;

  /// Model id, null = the workspace / server default.
  final String? model;
  final List<String> toolNames;
  final List<String> collectionIds;
  final bool useRag;
  final bool useTools;

  /// Null = the model default.
  final double? temperature;
  final bool memoryEnabled;

  /// Preselected in the new-chat picker; at most one per organization.
  final bool isDefault;
  final String? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// The avatar emoji, or the name's initial.
  String get avatarLabel {
    final a = avatar?.trim() ?? '';
    if (a.isNotEmpty) return a;
    return name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
  }

  /// Creator or org owner / admin — everyone else sees the assistant
  /// read-only (the server answers 403 otherwise).
  bool isEditableBy(User? user, Org? org) {
    if (user == null) return false;
    if (createdBy != null && createdBy == user.id) return true;
    return org?.canManage == true;
  }

  /// The server shape (`AssistantRead`), so a cached assistant round-trips
  /// through [Assistant.fromJson].
  Map<String, dynamic> toJson() => {
        'id': id,
        'org_id': orgId,
        'name': name,
        'description': description,
        'avatar': avatar,
        'system_prompt': systemPrompt,
        'model': model,
        'tool_names': toolNames,
        'collection_ids': collectionIds,
        'use_rag': useRag,
        'use_tools': useTools,
        'temperature': temperature,
        'memory_enabled': memoryEnabled,
        'is_default': isDefault,
        'created_by': createdBy,
        'created_at': createdAt?.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      };

  AssistantDraft toDraft() => AssistantDraft(
        name: name,
        description: description,
        avatar: avatar,
        systemPrompt: systemPrompt,
        model: model,
        toolNames: toolNames,
        collectionIds: collectionIds,
        useRag: useRag,
        useTools: useTools,
        temperature: temperature,
        memoryEnabled: memoryEnabled,
        isDefault: isDefault,
      );
}

/// Body of `POST /assistants` and `PATCH /assistants/{id}`. Every field is
/// sent, so clearing the model or the temperature really stores null.
class AssistantDraft {
  const AssistantDraft({
    required this.name,
    this.description,
    this.avatar,
    this.systemPrompt,
    this.model,
    this.toolNames = const [],
    this.collectionIds = const [],
    this.useRag = true,
    this.useTools = false,
    this.temperature,
    this.memoryEnabled = true,
    this.isDefault = false,
  });

  final String name;
  final String? description;
  final String? avatar;
  final String? systemPrompt;
  final String? model;
  final List<String> toolNames;
  final List<String> collectionIds;
  final bool useRag;
  final bool useTools;
  final double? temperature;
  final bool memoryEnabled;
  final bool isDefault;

  Map<String, Object?> toJson() => {
        'name': name,
        'description': _blankToNull(description),
        'avatar': _blankToNull(avatar),
        'system_prompt': _blankToNull(systemPrompt),
        'model': _blankToNull(model),
        'tool_names': toolNames,
        'collection_ids': collectionIds,
        'use_rag': useRag,
        'use_tools': useTools,
        'temperature': temperature,
        'memory_enabled': memoryEnabled,
        'is_default': isDefault,
      };

  static String? _blankToNull(String? s) {
    final v = s?.trim();
    return v == null || v.isEmpty ? null : v;
  }
}
