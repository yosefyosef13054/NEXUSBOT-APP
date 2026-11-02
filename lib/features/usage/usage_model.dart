import 'package:collection/collection.dart';

/// Tokens / cost / messages over a period — the unit of every usage answer.
class UsageBucket {
  const UsageBucket({this.tokens = 0, this.costUsd = 0, this.messages = 0});

  factory UsageBucket.fromJson(Map<String, dynamic> j) => UsageBucket(
        tokens: (j['tokens'] as num?)?.toInt() ?? 0,
        costUsd: (j['cost_usd'] as num?)?.toDouble() ?? 0,
        messages: (j['messages'] as num?)?.toInt() ?? 0,
      );

  final int tokens;
  final double costUsd;
  final int messages;

  static const zero = UsageBucket();
}

class UsagePeriod {
  const UsagePeriod({required this.start, required this.end});

  factory UsagePeriod.fromJson(Map<String, dynamic> j) => UsagePeriod(
        start: DateTime.tryParse(j['start'] as String? ?? '') ?? DateTime.now(),
        end: DateTime.tryParse(j['end'] as String? ?? '') ?? DateTime.now(),
      );

  final DateTime start;
  final DateTime end;
}

/// The active organization's month-to-date usage against its budgets
/// (`GET /usage/me` → `org`). Remaining values are null without a budget.
class OrgUsage {
  const OrgUsage({
    required this.id,
    required this.usage,
    this.budgetTokensPerMonth,
    this.budgetUsdPerMonth,
    this.remainingTokens,
    this.remainingUsd,
  });

  factory OrgUsage.fromJson(Map<String, dynamic> j) => OrgUsage(
        id: (j['id'] as String?) ?? '',
        usage: UsageBucket.fromJson(j),
        budgetTokensPerMonth: (j['budget_tokens_per_month'] as num?)?.toInt(),
        budgetUsdPerMonth: (j['budget_usd_per_month'] as num?)?.toDouble(),
        remainingTokens: (j['remaining_tokens'] as num?)?.toInt(),
        remainingUsd: (j['remaining_usd'] as num?)?.toDouble(),
      );

  final String id;
  final UsageBucket usage;
  final int? budgetTokensPerMonth;
  final double? budgetUsdPerMonth;
  final int? remainingTokens;
  final double? remainingUsd;

  bool get hasBudget => budgetTokensPerMonth != null || budgetUsdPerMonth != null;

  /// Spent share of the USD budget (0..1), null without one.
  double? get usdFraction {
    final b = budgetUsdPerMonth;
    if (b == null || b <= 0) return null;
    return (usage.costUsd / b).clamp(0, 1).toDouble();
  }

  /// Spent share of the token budget (0..1), null without one.
  double? get tokensFraction {
    final b = budgetTokensPerMonth;
    if (b == null || b <= 0) return null;
    return (usage.tokens / b).clamp(0, 1).toDouble();
  }

  /// Whether any budget is spent — the server then answers every generation
  /// with 429 `quota_exceeded`.
  bool get exhausted {
    final usd = remainingUsd;
    final tokens = remainingTokens;
    if (budgetUsdPerMonth != null && usd != null && usd <= 0) return true;
    if (budgetTokensPerMonth != null && tokens != null && tokens <= 0) return true;
    return false;
  }
}

/// `GET /usage/me`.
class UsageSummary {
  const UsageSummary({required this.period, required this.user, required this.org});

  factory UsageSummary.fromJson(Map<String, dynamic> j) => UsageSummary(
        period: UsagePeriod.fromJson((j['period'] as Map?)?.cast<String, dynamic>() ?? const {}),
        user: UsageBucket.fromJson((j['user'] as Map?)?.cast<String, dynamic>() ?? const {}),
        org: OrgUsage.fromJson((j['org'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );

  final UsagePeriod period;
  final UsageBucket user;
  final OrgUsage org;
}

/// `group_by` of the usage reports; `org` only for the server-wide one.
enum UsageGroupBy {
  user,
  model,
  day,
  org;

  static UsageGroupBy fromString(String? s) =>
      UsageGroupBy.values.firstWhereOrNull((g) => g.name == s) ?? UsageGroupBy.user;

  String get label => switch (this) {
        UsageGroupBy.user => 'User',
        UsageGroupBy.model => 'Model',
        UsageGroupBy.day => 'Day',
        UsageGroupBy.org => 'Organization',
      };
}

/// One row of a report: `key` is a user email, a model id, a `YYYY-MM-DD`
/// day or an organization name, depending on `group_by`.
class UsageGroup {
  const UsageGroup({required this.key, required this.usage});

  factory UsageGroup.fromJson(Map<String, dynamic> j) => UsageGroup(
        key: (j['key'] as String?) ?? '',
        usage: UsageBucket.fromJson(j),
      );

  final String key;
  final UsageBucket usage;
}

/// `GET /orgs/{id}/usage` / `GET /admin/usage`.
class UsageReport {
  const UsageReport({
    required this.totals,
    required this.groups,
    this.period,
    this.groupBy = UsageGroupBy.user,
  });

  factory UsageReport.fromJson(Map<String, dynamic> j) => UsageReport(
        period: j['period'] is Map
            ? UsagePeriod.fromJson((j['period'] as Map).cast<String, dynamic>())
            : null,
        groupBy: UsageGroupBy.fromString(j['group_by'] as String?),
        totals: UsageBucket.fromJson((j['totals'] as Map?)?.cast<String, dynamic>() ?? const {}),
        groups: (j['groups'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => UsageGroup.fromJson(m.cast<String, dynamic>()))
            .toList(),
      );

  final UsagePeriod? period;
  final UsageGroupBy groupBy;
  final UsageBucket totals;
  final List<UsageGroup> groups;
}

/// The active organization's budget is spent: HTTP 429 `quota_exceeded`
/// (or an `error` stream frame with that code). Carried by the banner until
/// `/usage/me` says otherwise or [resetsAt] has passed.
class QuotaExceeded {
  const QuotaExceeded({
    required this.message,
    this.resetsAt,
    this.budgetUsd,
    this.usedUsd,
    this.budgetTokens,
    this.usedTokens,
  });

  /// Builds from the error envelope's `details`
  /// (`budget_usd_per_month | budget_tokens_per_month`, `used_usd | used_tokens`, `resets_at`).
  factory QuotaExceeded.fromDetails(Map<String, dynamic>? details, {String? message}) {
    final d = details ?? const <String, dynamic>{};
    return QuotaExceeded(
      message: message ?? 'The monthly budget of this workspace is spent.',
      resetsAt: DateTime.tryParse(d['resets_at'] as String? ?? ''),
      budgetUsd: (d['budget_usd_per_month'] as num?)?.toDouble(),
      usedUsd: (d['used_usd'] as num?)?.toDouble(),
      budgetTokens: (d['budget_tokens_per_month'] as num?)?.toInt(),
      usedTokens: (d['used_tokens'] as num?)?.toInt(),
    );
  }

  final String message;
  final DateTime? resetsAt;
  final double? budgetUsd;
  final double? usedUsd;
  final int? budgetTokens;
  final int? usedTokens;

  /// `$10.00 of $10.00 spent` / `1.2M of 1M tokens used`, or null when the
  /// server sent no figures.
  String? get figures {
    if (budgetUsd != null) {
      return '${formatUsd(usedUsd ?? budgetUsd!)} of ${formatUsd(budgetUsd!)} spent';
    }
    if (budgetTokens != null) {
      return '${formatTokens(usedTokens ?? budgetTokens!)} of ${formatTokens(budgetTokens!)} tokens used';
    }
    return null;
  }

  /// Whether the reset moment is already behind us (then a refresh is due).
  bool isPast(DateTime now) => resetsAt != null && !resetsAt!.isAfter(now);
}

/// `1.2M` / `150k` / `900` — compact token counts.
String formatTokens(int n) {
  if (n >= 1000000) return '${_trim(n / 1000000)}M';
  if (n >= 1000) return '${_trim(n / 1000)}k';
  return '$n';
}

/// `$0.42` / `$3.10` / `$0.0012` — money with sensible precision.
String formatUsd(double v) {
  if (v == 0) return '\$0.00';
  if (v.abs() < 0.01) return '\$${v.toStringAsFixed(4)}';
  return '\$${v.toStringAsFixed(2)}';
}

String _trim(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}
