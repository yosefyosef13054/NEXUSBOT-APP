import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api_exception.dart';
import '../../core/breakpoints.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../shared/home_shell.dart';
import '../auth/auth_providers.dart';
import '../orgs/orgs_repository.dart';
import 'usage_model.dart';
import 'usage_repository.dart';
import 'usage_widgets.dart';

enum _Range { thisMonth, last30, custom }

/// Usage report with a date range (this month / last 30 days / custom), a
/// `group_by` choice and a bar list per group.
///
/// With [orgId] it is `/orgs/:id/usage` (owner / admin of that org); without
/// it is `/admin/usage` — server administrators only, with the extra
/// "Organization" grouping.
class UsageReportScreen extends ConsumerStatefulWidget {
  const UsageReportScreen({super.key, this.orgId});
  final String? orgId;

  bool get isAdmin => orgId == null;

  @override
  ConsumerState<UsageReportScreen> createState() => _UsageReportScreenState();
}

class _UsageReportScreenState extends ConsumerState<UsageReportScreen> {
  _Range _range = _Range.thisMonth;
  late DateTime _from;
  late DateTime _to;
  UsageGroupBy _groupBy = UsageGroupBy.user;
  UsageMetric _metric = UsageMetric.cost;

  UsageReport? _report;
  Object? _error;
  bool _loading = false;
  int _requestSeq = 0;

  @override
  void initState() {
    super.initState();
    _applyRange(_Range.thisMonth);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _applyRange(_Range r) {
    final now = DateTime.now();
    switch (r) {
      case _Range.thisMonth:
        _from = DateTime(now.year, now.month);
        _to = DateTime(now.year, now.month + 1);
      case _Range.last30:
        _to = DateTime(now.year, now.month, now.day + 1);
        _from = _to.subtract(const Duration(days: 30));
      case _Range.custom:
        break;
    }
    _range = r;
  }

  Future<void> _pickCustom() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _from = DateTime(picked.start.year, picked.start.month, picked.start.day);
      _to = DateTime(picked.end.year, picked.end.month, picked.end.day + 1);
      _range = _Range.custom;
    });
    await _load();
  }

  Future<void> _load() async {
    final seq = ++_requestSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = await ref.read(usageRepositoryProvider.future);
      final orgId = widget.orgId;
      final report = orgId == null
          ? await repo.adminReport(from: _from, to: _to, groupBy: _groupBy)
          : await repo.orgReport(orgId, from: _from, to: _to, groupBy: _groupBy);
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final user = ref.watch(currentUserProvider).valueOrNull;
    final org = widget.orgId == null
        ? null
        : ref.watch(orgListProvider).valueOrNull?.where((o) => o.id == widget.orgId).firstOrNull;
    final title = widget.isAdmin
        ? 'Server usage'
        : org == null
            ? 'Usage report'
            : (org.isPersonal ? 'Personal usage' : '${org.name} · usage');
    final groupings = [
      UsageGroupBy.user,
      UsageGroupBy.model,
      UsageGroupBy.day,
      if (widget.isAdmin) UsageGroupBy.org,
    ];

    final Widget body;
    if (widget.isAdmin && user != null && !user.isServerAdmin) {
      body = const EmptyState(
        icon: Icons.lock_outline_rounded,
        title: 'Administrators only',
        subtitle: 'This report is available to server administrators.',
      );
    } else {
      final report = _report;
      body = ListView(
        padding: const EdgeInsets.all(NexusSpacing.lg),
        children: [
          Wrap(
            spacing: NexusSpacing.sm,
            runSpacing: NexusSpacing.sm,
            children: [
              _Chip(
                label: 'This month',
                active: _range == _Range.thisMonth,
                onTap: () {
                  setState(() => _applyRange(_Range.thisMonth));
                  _load();
                },
              ),
              _Chip(
                label: 'Last 30 days',
                active: _range == _Range.last30,
                onTap: () {
                  setState(() => _applyRange(_Range.last30));
                  _load();
                },
              ),
              _Chip(
                label: _range == _Range.custom
                    ? '${DateFormat.yMMMd().format(_from)} – '
                        '${DateFormat.yMMMd().format(_to.subtract(const Duration(days: 1)))}'
                    : 'Custom…',
                active: _range == _Range.custom,
                icon: Icons.date_range_rounded,
                onTap: _pickCustom,
              ),
            ],
          ),
          const SizedBox(height: NexusSpacing.md),
          Row(
            children: [
              Text(
                'GROUP BY',
                style: TextStyle(
                  color: t.textMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(width: NexusSpacing.sm),
              Expanded(
                child: Wrap(
                  spacing: NexusSpacing.xs,
                  runSpacing: NexusSpacing.xs,
                  children: [
                    for (final g in groupings)
                      _Chip(
                        label: g.label,
                        active: _groupBy == g,
                        onTap: () {
                          setState(() => _groupBy = g);
                          _load();
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: NexusSpacing.lg),
          if (report != null) ...[
            _TotalsCard(totals: report.totals),
            const SizedBox(height: NexusSpacing.lg),
          ],
          Container(
            decoration: BoxDecoration(
              color: t.surfaceHigh,
              borderRadius: const BorderRadius.all(NexusRadius.lg),
              border: Border.all(color: t.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NexusSpacing.lg,
                    NexusSpacing.md,
                    NexusSpacing.md,
                    0,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'By ${_groupBy.label.toLowerCase()}',
                          style: TextStyle(
                            color: t.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      for (final m in UsageMetric.values)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: _Chip(
                            label: m.label,
                            active: _metric == m,
                            onTap: () => setState(() => _metric = m),
                            dense: true,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: NexusSpacing.sm),
                if (_loading && report == null)
                  const Padding(
                    padding: EdgeInsets.all(NexusSpacing.lg),
                    child: Column(
                      children: [
                        Skeleton(height: 14),
                        SizedBox(height: 10),
                        Skeleton(height: 14),
                        SizedBox(height: 10),
                        Skeleton(width: 200, height: 14),
                      ],
                    ),
                  )
                else if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(NexusSpacing.lg),
                    child: Row(
                      children: [
                        const Icon(Icons.cloud_off_rounded, size: 16, color: NexusColors.crimson),
                        const SizedBox(width: NexusSpacing.sm),
                        Expanded(
                          child: Text(
                            errorText(_error!),
                            style: TextStyle(color: t.textSecondary, fontSize: 13),
                          ),
                        ),
                        TextButton(onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
                  )
                else if (report != null)
                  Opacity(
                    opacity: _loading ? 0.5 : 1,
                    child: UsageBarList(groups: report.groups, metric: _metric),
                  ),
                const SizedBox(height: NexusSpacing.sm),
              ],
            ),
          ),
          const SizedBox(height: NexusSpacing.xxxl),
        ],
      );
    }

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.textPrimary),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: body),
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.totals});
  final UsageBucket totals;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget stat(String value, String label) => Expanded(
          child: Column(
            children: [
              Text(
                value,
                style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w900),
              ),
              Text(label, style: TextStyle(color: t.textMuted, fontSize: 11)),
            ],
          ),
        );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: NexusSpacing.lg),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.lg),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: [
          stat(formatUsd(totals.costUsd), 'cost'),
          stat(formatTokens(totals.tokens), 'tokens'),
          stat('${totals.messages}', 'messages'),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.active,
    required this.onTap,
    this.icon,
    this.dense = false,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 12, vertical: dense ? 4 : 7),
          decoration: BoxDecoration(
            color: active ? NexusColors.crimson.withValues(alpha: 0.15) : t.surfaceHigh,
            borderRadius: const BorderRadius.all(NexusRadius.pill),
            border: Border.all(color: active ? NexusColors.crimson : t.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: active ? NexusColors.crimson : t.textSecondary),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: active ? t.textPrimary : t.textSecondary,
                  fontSize: dense ? 11 : 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
