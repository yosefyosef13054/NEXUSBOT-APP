import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import 'usage_model.dart';

/// Settings → USAGE: the user's and the workspace's figures for the period
/// plus a progress bar per configured budget.
class UsageSummaryView extends StatelessWidget {
  const UsageSummaryView({super.key, required this.summary});
  final UsageSummary summary;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final org = summary.org;
    final period = summary.period;
    return Padding(
      padding: const EdgeInsets.all(NexusSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${DateFormat.MMMd().format(period.start.toLocal())} – '
            '${DateFormat.MMMd().format(period.end.toLocal())}',
            style: TextStyle(color: t.textMuted, fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: NexusSpacing.md),
          _BucketRow(label: 'You', bucket: summary.user),
          const SizedBox(height: NexusSpacing.md),
          _BucketRow(label: 'Workspace', bucket: org.usage),
          if (org.budgetUsdPerMonth != null) ...[
            const SizedBox(height: NexusSpacing.lg),
            BudgetBar(
              label: 'Spending budget',
              fraction: org.usdFraction ?? 0,
              valueLabel: '${formatUsd(org.usage.costUsd)} of ${formatUsd(org.budgetUsdPerMonth!)}',
            ),
          ],
          if (org.budgetTokensPerMonth != null) ...[
            const SizedBox(height: NexusSpacing.md),
            BudgetBar(
              label: 'Token budget',
              fraction: org.tokensFraction ?? 0,
              valueLabel:
                  '${formatTokens(org.usage.tokens)} of ${formatTokens(org.budgetTokensPerMonth!)}',
            ),
          ],
          if (!org.hasBudget) ...[
            const SizedBox(height: NexusSpacing.md),
            Text(
              'This workspace has no monthly budget.',
              style: TextStyle(color: t.textMuted, fontSize: 11.5),
            ),
          ],
        ],
      ),
    );
  }
}

class _BucketRow extends StatelessWidget {
  const _BucketRow({required this.label, required this.bucket});
  final String label;
  final UsageBucket bucket;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(child: _Stat(value: formatTokens(bucket.tokens), label: 'tokens')),
        Expanded(child: _Stat(value: formatUsd(bucket.costUsd), label: 'cost')),
        Expanded(child: _Stat(value: '${bucket.messages}', label: 'messages')),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(color: t.textPrimary, fontSize: 14, fontWeight: FontWeight.w800),
        ),
        Text(label, style: TextStyle(color: t.textMuted, fontSize: 10.5)),
      ],
    );
  }
}

/// Label + thin progress bar + "x of y" — turns amber past 80 % and crimson
/// when spent.
class BudgetBar extends StatelessWidget {
  const BudgetBar({
    super.key,
    required this.label,
    required this.fraction,
    required this.valueLabel,
    this.compact = false,
  });

  final String label;
  final double fraction;
  final String valueLabel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = fraction >= 1
        ? NexusColors.danger
        : fraction >= 0.8
            ? NexusColors.warn
            : NexusColors.crimson;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: compact ? t.textMuted : t.textSecondary,
                  fontSize: compact ? 10.5 : 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              valueLabel,
              style: TextStyle(
                color: t.textPrimary,
                fontSize: compact ? 10.5 : 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: fraction.clamp(0, 1).toDouble(),
            minHeight: compact ? 3 : 5,
            backgroundColor: t.surfaceHigher,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// Sidebar footer: one line of usage for the month. Shows the tightest
/// budget as a bar, or the plain figures when there is no budget.
class UsageMeter extends StatelessWidget {
  const UsageMeter({super.key, required this.summary, this.onTap});
  final UsageSummary? summary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = summary;
    final Widget body;
    if (s == null) {
      body = Text('Usage · —', style: TextStyle(color: t.textMuted, fontSize: 10.5));
    } else {
      final org = s.org;
      final usd = org.usdFraction;
      final tokens = org.tokensFraction;
      if (usd != null && (tokens == null || usd >= tokens)) {
        body = BudgetBar(
          label: 'Usage this month',
          fraction: usd,
          valueLabel: '${formatUsd(org.usage.costUsd)} / ${formatUsd(org.budgetUsdPerMonth!)}',
          compact: true,
        );
      } else if (tokens != null) {
        body = BudgetBar(
          label: 'Usage this month',
          fraction: tokens,
          valueLabel:
              '${formatTokens(org.usage.tokens)} / ${formatTokens(org.budgetTokensPerMonth!)} tokens',
          compact: true,
        );
      } else {
        body = Row(
          children: [
            Expanded(
              child: Text(
                'Usage this month',
                style: TextStyle(color: t.textMuted, fontSize: 10.5, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '${formatTokens(s.user.tokens)} tokens · ${formatUsd(s.user.costUsd)}',
              style: TextStyle(color: t.textPrimary, fontSize: 10.5, fontWeight: FontWeight.w700),
            ),
          ],
        );
      }
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            NexusSpacing.lg,
            NexusSpacing.sm,
            NexusSpacing.lg,
            NexusSpacing.sm,
          ),
          child: body,
        ),
      ),
    );
  }
}

/// Persistent "budget spent" banner shown above the composer. **Refresh**
/// re-checks `/usage/me`.
class QuotaBanner extends StatelessWidget {
  const QuotaBanner({
    super.key,
    required this.quota,
    required this.onRefresh,
    this.refreshing = false,
  });

  final QuotaExceeded quota;
  final VoidCallback onRefresh;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final resets = quota.resetsAt;
    final figures = quota.figures;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: NexusSpacing.md),
      decoration: BoxDecoration(
        color: NexusColors.warn.withValues(alpha: 0.12),
        border: Border(
          top: BorderSide(color: NexusColors.warn.withValues(alpha: 0.6)),
          bottom: BorderSide(color: NexusColors.warn.withValues(alpha: 0.6)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.hourglass_bottom_rounded, size: 18, color: NexusColors.warn),
          const SizedBox(width: NexusSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Monthly budget spent',
                  style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (figures != null) figures,
                    if (resets != null)
                      'Resets ${DateFormat.yMMMd().add_jm().format(resets.toLocal())}',
                    if (figures == null && resets == null) quota.message,
                  ].join(' · '),
                  style: TextStyle(color: t.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: NexusSpacing.sm),
          TextButton.icon(
            onPressed: refreshing ? null : onRefresh,
            icon: refreshing
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: NexusColors.warn),
                  )
                : const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Refresh'),
            style: TextButton.styleFrom(foregroundColor: NexusColors.warn),
          ),
        ],
      ),
    );
  }
}

/// Which figure a report's bars show.
enum UsageMetric {
  cost,
  tokens,
  messages;

  String get label => switch (this) {
        UsageMetric.cost => 'Cost',
        UsageMetric.tokens => 'Tokens',
        UsageMetric.messages => 'Messages',
      };

  double of(UsageBucket b) => switch (this) {
        UsageMetric.cost => b.costUsd,
        UsageMetric.tokens => b.tokens.toDouble(),
        UsageMetric.messages => b.messages.toDouble(),
      };

  String format(UsageBucket b) => switch (this) {
        UsageMetric.cost => formatUsd(b.costUsd),
        UsageMetric.tokens => formatTokens(b.tokens),
        UsageMetric.messages => '${b.messages}',
      };
}

/// A simple horizontal bar list (no chart library): one row per group,
/// bars scaled to the largest value.
class UsageBarList extends StatelessWidget {
  const UsageBarList({super.key, required this.groups, required this.metric});
  final List<UsageGroup> groups;
  final UsageMetric metric;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(NexusSpacing.lg),
        child: Text('No usage in this range.', style: TextStyle(color: t.textMuted, fontSize: 13)),
      );
    }
    final max = groups.map((g) => metric.of(g.usage)).fold<double>(0, (a, b) => a > b ? a : b);
    final sorted = List<UsageGroup>.of(groups)
      ..sort((a, b) => metric.of(b.usage).compareTo(metric.of(a.usage)));
    return Column(
      children: [
        for (final g in sorted)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        g.key.isEmpty ? '—' : g.key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.textPrimary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: NexusSpacing.sm),
                    Text(
                      metric.format(g.usage),
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: max <= 0 ? 0 : (metric.of(g.usage) / max).clamp(0, 1).toDouble(),
                    minHeight: 6,
                    backgroundColor: t.surfaceHigher,
                    color: NexusColors.crimson,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${formatTokens(g.usage.tokens)} tokens · ${formatUsd(g.usage.costUsd)} · '
                  '${g.usage.messages} message${g.usage.messages == 1 ? '' : 's'}',
                  style: TextStyle(color: t.textMuted, fontSize: 10.5),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
