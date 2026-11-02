import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../auth/auth_providers.dart';
import '../orgs/orgs_repository.dart';
import 'usage_model.dart';

class UsageRepository {
  UsageRepository(this._client);
  final ApiClient _client;

  /// `GET /usage/me` — the user's and the active organization's usage for
  /// the current period, with budgets and what is left of them.
  Future<UsageSummary> me() async {
    final res = await _client.request<Map<String, dynamic>>('/usage/me');
    return UsageSummary.fromJson(res.data ?? const {});
  }

  /// `GET /orgs/{id}/usage?from&to&group_by` (owner / admin).
  Future<UsageReport> orgReport(
    String orgId, {
    required DateTime from,
    required DateTime to,
    required UsageGroupBy groupBy,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/orgs/$orgId/usage',
      query: _reportQuery(from, to, groupBy),
    );
    return UsageReport.fromJson(res.data ?? const {});
  }

  /// `GET /admin/usage?from&to&group_by` (server administrators; may also
  /// group by `org`).
  Future<UsageReport> adminReport({
    required DateTime from,
    required DateTime to,
    required UsageGroupBy groupBy,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/admin/usage',
      query: _reportQuery(from, to, groupBy),
    );
    return UsageReport.fromJson(res.data ?? const {});
  }

  static Map<String, dynamic> _reportQuery(DateTime from, DateTime to, UsageGroupBy groupBy) => {
        'from': from.toUtc().toIso8601String(),
        'to': to.toUtc().toIso8601String(),
        'group_by': groupBy.name,
      };
}

final usageRepositoryProvider = FutureProvider<UsageRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return UsageRepository(client);
});

/// `GET /usage/me`, reloaded when the user or the active organization
/// changes and invalidated by the chat after every completed turn (so the
/// sidebar meter keeps up).
final usageMeProvider = FutureProvider<UsageSummary>((ref) async {
  ref.watch(currentUserProvider.select((u) => u.valueOrNull?.id));
  ref.watch(activeOrgIdProvider);
  final repo = await ref.watch(usageRepositoryProvider.future);
  return repo.me();
});

/// App-wide "budget spent" state. Set by the chat whenever a turn is refused
/// with `quota_exceeded`; every composer is disabled while it is set.
/// [refresh] re-checks `/usage/me` and clears it once the budget allows
/// turns again. Reset when the active organization changes.
class QuotaController extends StateNotifier<QuotaExceeded?> {
  QuotaController(this._ref) : super(null);
  final Ref _ref;

  bool _refreshing = false;
  bool get refreshing => _refreshing;

  void set(QuotaExceeded quota) => state = quota;
  void clear() => state = null;

  /// Re-fetches `/usage/me` (through [usageMeProvider], so the meter and
  /// Settings see the fresh figures too). Returns true when the quota is no
  /// longer exceeded.
  Future<bool> refresh() async {
    if (_refreshing) return state == null;
    _refreshing = true;
    try {
      // Invalidating a provider nobody has read yet would build it twice.
      if (_ref.exists(usageMeProvider)) _ref.invalidate(usageMeProvider);
      final summary = await _ref.read(usageMeProvider.future);
      if (!mounted) return false;
      final current = state;
      if (!summary.org.exhausted || (current != null && current.isPast(DateTime.now()))) {
        state = null;
        return true;
      }
      return false;
    } finally {
      _refreshing = false;
    }
  }
}

final quotaStateProvider = StateNotifierProvider<QuotaController, QuotaExceeded?>((ref) {
  // A different workspace has its own budget.
  ref.watch(activeOrgIdProvider);
  return QuotaController(ref);
});
