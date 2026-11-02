import 'package:collection/collection.dart';

/// A member's role in an organization. Owners and admins manage settings,
/// budgets and members; members use the workspace.
enum OrgRole {
  owner,
  admin,
  member;

  static OrgRole fromString(String? s) =>
      OrgRole.values.firstWhereOrNull((r) => r.name == s) ?? OrgRole.member;

  /// Owners and admins may edit the organization and its members.
  bool get canManage => this != OrgRole.member;

  String get label => switch (this) {
        OrgRole.owner => 'Owner',
        OrgRole.admin => 'Admin',
        OrgRole.member => 'Member',
      };
}

/// Workspace policy (`OrgRead.settings`). Null means unlimited / the server
/// default.
class OrgSettings {
  const OrgSettings({
    this.budgetTokensPerMonth,
    this.budgetUsdPerMonth,
    this.defaultModel,
    this.allowedModels,
  });

  factory OrgSettings.fromJson(Map<String, dynamic> j) => OrgSettings(
        budgetTokensPerMonth: (j['budget_tokens_per_month'] as num?)?.toInt(),
        budgetUsdPerMonth: (j['budget_usd_per_month'] as num?)?.toDouble(),
        defaultModel: j['default_model'] as String?,
        allowedModels: (j['allowed_models'] as List?)?.map((e) => e.toString()).toList(),
      );

  final int? budgetTokensPerMonth;
  final double? budgetUsdPerMonth;
  final String? defaultModel;

  /// Model ids members may use; null = every model the server offers.
  final List<String>? allowedModels;

  /// Full settings body for `PATCH /orgs/{id} {settings}` — every key is sent
  /// so a cleared value really becomes null server-side.
  Map<String, Object?> toJson() => {
        'budget_tokens_per_month': budgetTokensPerMonth,
        'budget_usd_per_month': budgetUsdPerMonth,
        'default_model': defaultModel,
        'allowed_models': allowedModels,
      };

  OrgSettings copyWith({
    int? budgetTokensPerMonth,
    bool clearBudgetTokens = false,
    double? budgetUsdPerMonth,
    bool clearBudgetUsd = false,
    String? defaultModel,
    List<String>? allowedModels,
    bool clearAllowedModels = false,
  }) =>
      OrgSettings(
        budgetTokensPerMonth:
            clearBudgetTokens ? null : (budgetTokensPerMonth ?? this.budgetTokensPerMonth),
        budgetUsdPerMonth: clearBudgetUsd ? null : (budgetUsdPerMonth ?? this.budgetUsdPerMonth),
        defaultModel: defaultModel ?? this.defaultModel,
        allowedModels: clearAllowedModels ? null : (allowedModels ?? this.allowedModels),
      );
}

/// One organization (workspace) the user belongs to — `GET /orgs` items.
class Org {
  const Org({
    required this.id,
    required this.name,
    required this.slug,
    required this.role,
    required this.isPersonal,
    required this.plan,
    required this.memberCount,
    required this.settings,
    this.createdAt,
  });

  factory Org.fromJson(Map<String, dynamic> j) => Org(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Workspace',
        slug: (j['slug'] as String?) ?? '',
        role: OrgRole.fromString(j['role'] as String?),
        isPersonal: j['is_personal'] == true,
        plan: (j['plan'] as String?) ?? 'free',
        memberCount: (j['member_count'] as num?)?.toInt() ?? 1,
        settings: OrgSettings.fromJson(
          (j['settings'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
      );

  final String id;
  final String name;
  final String slug;

  /// The signed-in user's role in this organization.
  final OrgRole role;

  /// The user's own workspace (created at registration; cannot be left).
  final bool isPersonal;
  final String plan;
  final int memberCount;
  final OrgSettings settings;
  final DateTime? createdAt;

  /// Whether the signed-in user may edit settings, budgets and members.
  bool get canManage => role.canManage;

  Org copyWith({String? name, OrgSettings? settings, int? memberCount}) => Org(
        id: id,
        name: name ?? this.name,
        slug: slug,
        role: role,
        isPersonal: isPersonal,
        plan: plan,
        memberCount: memberCount ?? this.memberCount,
        settings: settings ?? this.settings,
        createdAt: createdAt,
      );
}

/// One row of `GET /orgs/{id}/members`.
class OrgMember {
  const OrgMember({
    required this.userId,
    required this.email,
    required this.role,
    this.fullName,
    this.joinedAt,
  });

  factory OrgMember.fromJson(Map<String, dynamic> j) => OrgMember(
        userId: (j['user_id'] as String?) ?? '',
        email: (j['email'] as String?) ?? '',
        fullName: j['full_name'] as String?,
        role: OrgRole.fromString(j['role'] as String?),
        joinedAt: DateTime.tryParse(j['joined_at'] as String? ?? ''),
      );

  final String userId;
  final String email;
  final String? fullName;
  final OrgRole role;
  final DateTime? joinedAt;

  String get displayName => fullName?.isNotEmpty == true ? fullName! : email;
}
