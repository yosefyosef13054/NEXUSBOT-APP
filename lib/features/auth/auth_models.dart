class User {
  const User({
    required this.id,
    required this.email,
    required this.role,
    this.fullName,
    this.defaultModel,
    this.personalOrgId,
    this.memoryEnabled = true,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        email: json['email'] as String,
        fullName: json['full_name'] as String?,
        role: json['role'] as String? ?? 'user',
        defaultModel: json['default_model'] as String?,
        personalOrgId: json['personal_org_id'] as String?,
        memoryEnabled: json['memory_enabled'] != false,
      );

  final String id;
  final String email;
  final String? fullName;
  final String role;

  /// The account-wide default model (`PATCH /auth/me {default_model}`);
  /// null = the server default.
  final String? defaultModel;

  /// The user's personal workspace — the org every request acts in unless
  /// another one is chosen.
  final String? personalOrgId;

  /// Whether NexusBot may extract and inject long-term memories for this
  /// user (`PATCH /auth/me {memory_enabled}`).
  final bool memoryEnabled;

  /// Server administrator (`role == "admin"`): sees the `/admin/*` reports.
  bool get isServerAdmin => role == 'admin';

  String get displayName => fullName?.isNotEmpty == true ? fullName! : email.split('@').first;
}

class TokenPair {
  const TokenPair({required this.accessToken, required this.refreshToken, required this.expiresIn});

  factory TokenPair.fromJson(Map<String, dynamic> json) => TokenPair(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
        expiresIn: (json['expires_in'] as num).toInt(),
      );

  final String accessToken;
  final String refreshToken;
  final int expiresIn;
}
