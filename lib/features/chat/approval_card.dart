import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../core/pretty_json.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import 'chat_models.dart';

/// Human-in-the-loop card rendered inside the assistant bubble: the tool
/// calls the agent wants to run (name, description, pretty-printed input)
/// and Approve / Deny. Once the approval is no longer pending the buttons
/// give way to an "expired" / "resolved" label.
class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    super.key,
    required this.approval,
    required this.onDecision,
    this.busy = false,
  });

  final ApprovalRequest approval;

  /// Null disables the buttons (e.g. while another turn is in flight).
  final ValueChanged<ApprovalDecision>? onDecision;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final pending = approval.isPending;
    final expires = approval.expiresAt;
    final locale = Localizations.localeOf(context).toString();
    return Container(
      padding: const EdgeInsets.all(NexusSpacing.md),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: const BorderRadius.all(NexusRadius.md),
        border: Border.all(color: NexusColors.warn.withValues(alpha: pending ? 0.7 : 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_rounded, size: 16, color: NexusColors.warn),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  pending ? l10n.approvalRequired : _staleTitle(l10n, approval.status),
                  style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w800),
                ),
              ),
              if (pending && expires != null)
                Text(
                  l10n.approvalUntil(DateFormat.jm(locale).format(expires.toLocal())),
                  style: TextStyle(color: t.textMuted, fontSize: 11),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            pending ? l10n.approvalPendingBody : l10n.approvalStaleBody,
            style: TextStyle(color: t.textSecondary, fontSize: 12),
          ),
          for (final call in approval.toolCalls) ...[
            const SizedBox(height: NexusSpacing.sm),
            _ApprovalToolTile(call: call),
          ],
          if (pending) ...[
            const SizedBox(height: NexusSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed:
                      busy || onDecision == null ? null : () => onDecision!(ApprovalDecision.deny),
                  icon: const Icon(Icons.block_rounded, size: 16),
                  label: Text(l10n.approvalDeny),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.textPrimary,
                    side: BorderSide(color: t.border),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(NexusRadius.md),
                    ),
                  ),
                ),
                const SizedBox(width: NexusSpacing.sm),
                FilledButton.icon(
                  onPressed: busy || onDecision == null
                      ? null
                      : () => onDecision!(ApprovalDecision.approve),
                  icon: busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.check_rounded, size: 16),
                  label: Text(l10n.approvalApprove),
                  style: FilledButton.styleFrom(
                    backgroundColor: NexusColors.crimson,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(NexusRadius.md),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _staleTitle(AppLocalizations l10n, String status) => switch (status) {
        'expired' => l10n.approvalExpired,
        'approved' => l10n.approvalApproved,
        'denied' => l10n.approvalDenied,
        _ => l10n.approvalResolved,
      };
}

class _ApprovalToolTile extends StatelessWidget {
  const _ApprovalToolTile({required this.call});
  final ApprovalToolCall call;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final input = prettyJson(call.input);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(NexusSpacing.sm),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.sm),
        border: Border.all(color: t.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.build_rounded, size: 12, color: NexusColors.crimson),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  call.tool,
                  style: TextStyle(color: t.textPrimary, fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          if (call.description.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(call.description, style: TextStyle(color: t.textSecondary, fontSize: 11.5)),
          ],
          if (input.isNotEmpty) ...[
            const SizedBox(height: 6),
            SelectableText(
              input,
              textDirection: TextDirection.ltr,
              style: GoogleFonts.jetBrainsMono(color: t.textPrimary, fontSize: 11.5, height: 1.45),
            ),
          ],
        ],
      ),
    );
  }
}
