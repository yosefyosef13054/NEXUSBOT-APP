import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../l10n/l10n.dart';

/// Strip at the top of the shell while the device has no network: cached
/// chats are shown and new messages wait in the send queue.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, this.queued = 0, this.failed = 0});

  /// Sends waiting for the connection.
  final int queued;

  /// Sends the queue gave up on (need a manual retry).
  final int failed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return Material(
      color: NexusColors.warn.withValues(alpha: 0.14),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: NexusSpacing.lg,
            vertical: NexusSpacing.sm,
          ),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_rounded, size: 16, color: NexusColors.warn),
              const SizedBox(width: NexusSpacing.sm),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: l10n.offlineBannerTitle,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const TextSpan(text: ' · '),
                      TextSpan(text: l10n.offlineBannerBody(queued)),
                      if (failed > 0) ...[
                        const TextSpan(text: ' '),
                        TextSpan(text: l10n.offlineBannerFailed(failed)),
                      ],
                    ],
                  ),
                  style: TextStyle(color: t.textPrimary, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
