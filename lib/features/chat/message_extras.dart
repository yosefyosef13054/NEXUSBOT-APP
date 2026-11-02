import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import 'chat_models.dart';

/// "‹ 2/3 ›" under a message that has edit / regeneration siblings. The
/// arrows report `-1` / `+1`; the screen resolves the target through
/// `GET …/siblings` and `POST /sessions/{id}/branch`.
///
/// The arrows are logical: "previous" points to the start side, "next" to
/// the end side, so they mirror under RTL.
class SiblingSwitcher extends StatelessWidget {
  const SiblingSwitcher({
    super.key,
    required this.siblings,
    required this.onSwitch,
    this.busy = false,
    this.enabled = true,
  });

  final SiblingInfo siblings;
  final ValueChanged<int>? onSwitch;

  /// A switch is in flight: show a spinner instead of the counter.
  final bool busy;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final active = enabled && !busy && onSwitch != null;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Arrow(
            icon: rtl ? Icons.chevron_right_rounded : Icons.chevron_left_rounded,
            tooltip: l10n.siblingPrev,
            onTap: active ? () => onSwitch!(-1) : null,
          ),
          if (busy)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: t.textMuted),
            )
          else
            Text(
              '${siblings.displayIndex}/${siblings.count}',
              style: TextStyle(
                color: t.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          _Arrow(
            icon: rtl ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
            tooltip: l10n.siblingNext,
            onTap: active ? () => onSwitch!(1) : null,
          ),
        ],
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(icon, size: 16, color: onTap == null ? t.textMuted : t.textPrimary),
        ),
      ),
    );
  }
}

/// Thumbs up / down for an assistant message. The active rating is filled
/// in; tapping it again is the caller's cue to clear it ([onRate] receives
/// the tapped rating either way, `1` or `-1`).
class FeedbackButtons extends StatelessWidget {
  const FeedbackButtons({
    super.key,
    required this.feedback,
    required this.onRate,
    this.enabled = true,
  });

  final MessageFeedback? feedback;
  final ValueChanged<int>? onRate;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final up = feedback?.isUp == true;
    final down = feedback?.isDown == true;
    final active = enabled && onRate != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _FeedbackIcon(
          icon: up ? Icons.thumb_up_alt_rounded : Icons.thumb_up_alt_outlined,
          tooltip: up ? l10n.feedbackRemoveUp : l10n.feedbackGood,
          color: up ? NexusColors.success : t.textMuted,
          onTap: active ? () => onRate!(1) : null,
        ),
        const SizedBox(width: 2),
        _FeedbackIcon(
          icon: down ? Icons.thumb_down_alt_rounded : Icons.thumb_down_alt_outlined,
          tooltip: down ? l10n.feedbackRemoveDown : l10n.feedbackBad,
          color: down ? NexusColors.danger : t.textMuted,
          onTap: active ? () => onRate!(-1) : null,
        ),
      ],
    );
  }
}

class _FeedbackIcon extends StatelessWidget {
  const _FeedbackIcon({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(NexusRadius.sm),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 14, color: color),
        ),
      ),
    );
  }
}

/// "Used 3 memories" under a reply whose `meta.memories_used` is set; tap
/// opens the memory screen.
class MemoriesCaption extends StatelessWidget {
  const MemoriesCaption({super.key, required this.count, this.onTap});
  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(NexusRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_outlined, size: 12, color: t.textMuted),
            const SizedBox(width: 4),
            Text(
              context.l10n.memoriesUsed(count),
              style: TextStyle(
                color: t.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                decoration: onTap == null ? null : TextDecoration.underline,
                decorationColor: t.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
