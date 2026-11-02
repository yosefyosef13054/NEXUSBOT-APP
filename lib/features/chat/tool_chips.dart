import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/pretty_json.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../l10n/labels.dart';
import 'chat_models.dart';

/// Collapsible "Tool: name" chips for a group of tool runs — the live strip
/// above a streaming reply, the final `tool_calls` of an assistant message,
/// or a persisted `role: "tool"` history row. Never a chat bubble.
///
/// Each pill shows a status icon (ok / error / denied) and the latency;
/// tapping one expands its input and output underneath the strip.
class ToolCallChips extends StatefulWidget {
  const ToolCallChips({super.key, required this.calls});
  final List<ToolCall> calls;

  @override
  State<ToolCallChips> createState() => _ToolCallChipsState();
}

class _ToolCallChipsState extends State<ToolCallChips> {
  int? _expanded;

  @override
  Widget build(BuildContext context) {
    final calls = widget.calls;
    final expanded = _expanded != null && _expanded! < calls.length ? _expanded : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: NexusSpacing.xs,
          runSpacing: NexusSpacing.xs,
          children: [
            for (var i = 0; i < calls.length; i++)
              _ToolPill(
                call: calls[i],
                expanded: expanded == i,
                onTap: () => setState(() => _expanded = expanded == i ? null : i),
              ),
          ],
        ),
        if (expanded != null) ...[
          const SizedBox(height: NexusSpacing.xs),
          _ToolDetails(call: calls[expanded]),
        ],
      ],
    );
  }
}

class _ToolPill extends StatelessWidget {
  const _ToolPill({required this.call, required this.expanded, required this.onTap});
  final ToolCall call;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final (icon, color) = toolStatusIcon(call.status, t);
    final latency = call.latencyMs;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: expanded ? NexusColors.crimson.withValues(alpha: 0.12) : t.surfaceHigh,
            borderRadius: const BorderRadius.all(NexusRadius.pill),
            border: Border.all(color: NexusColors.crimson.withValues(alpha: expanded ? 0.9 : 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.build_rounded, size: 12, color: NexusColors.crimson),
              const SizedBox(width: 4),
              Text(
                l10n.toolChip(call.tool),
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(width: 6),
              Icon(icon, size: 12, color: color),
              if (latency != null) ...[
                const SizedBox(width: 4),
                Text(
                  formatLatency(l10n, latency),
                  style: TextStyle(color: t.textMuted, fontSize: 10, fontWeight: FontWeight.w600),
                ),
              ],
              const SizedBox(width: 2),
              Icon(
                expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                size: 14,
                color: t.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolDetails extends StatelessWidget {
  const _ToolDetails({required this.call});
  final ToolCall call;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final input = prettyJson(call.input);
    final output = call.output ?? '';
    final error = call.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(NexusSpacing.md),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.md),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                call.tool,
                style: TextStyle(color: t.textPrimary, fontSize: 12, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: NexusSpacing.sm),
              _StatusLabel(status: call.status),
              if (call.latencyMs != null) ...[
                const Spacer(),
                Text(
                  formatLatency(l10n, call.latencyMs!),
                  style: TextStyle(color: t.textMuted, fontSize: 11),
                ),
              ],
            ],
          ),
          if (input.isNotEmpty) ...[
            const SizedBox(height: NexusSpacing.sm),
            _Section(label: l10n.toolInput, body: input),
          ],
          if (error != null && error.isNotEmpty) ...[
            const SizedBox(height: NexusSpacing.sm),
            _Section(label: l10n.toolError, body: error, danger: true),
          ],
          if (output.isNotEmpty) ...[
            const SizedBox(height: NexusSpacing.sm),
            _Section(label: l10n.toolOutput, body: output),
          ],
          if (input.isEmpty && output.isEmpty && (error == null || error.isEmpty))
            Padding(
              padding: const EdgeInsets.only(top: NexusSpacing.sm),
              child: Text(
                call.status == ToolCallStatus.denied ? l10n.toolDeniedBody : l10n.toolNoIo,
                style: TextStyle(color: t.textMuted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.label, required this.body, this.danger = false});
  final String label;
  final String body;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: danger ? NexusColors.danger : t.textMuted,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(NexusSpacing.sm),
          decoration: BoxDecoration(
            color: t.background,
            borderRadius: const BorderRadius.all(NexusRadius.sm),
            border: Border.all(color: t.borderSubtle),
          ),
          child: SelectableText(
            body,
            // Tool payloads are code / JSON: always laid out left to right.
            textDirection: TextDirection.ltr,
            style: GoogleFonts.jetBrainsMono(color: t.textPrimary, fontSize: 12, height: 1.45),
          ),
        ),
      ],
    );
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.status});
  final ToolCallStatus status;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final (icon, color) = toolStatusIcon(status, t);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(
          status.localized(context.l10n),
          style:
              TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1),
        ),
      ],
    );
  }
}

/// Icon + colour for a tool run outcome.
(IconData, Color) toolStatusIcon(ToolCallStatus status, NexusTokens t) => switch (status) {
      ToolCallStatus.ok => (Icons.check_circle_rounded, NexusColors.success),
      ToolCallStatus.error => (Icons.error_rounded, NexusColors.danger),
      ToolCallStatus.denied => (Icons.block_rounded, NexusColors.warn),
      ToolCallStatus.unknown => (Icons.help_outline_rounded, t.textMuted),
    };

/// `12 ms` / `1.4 s` / `12 s`.
String formatLatency(AppLocalizations l10n, int ms) => ms < 1000
    ? l10n.toolLatencyMs(ms)
    : l10n.toolLatencyS((ms / 1000).toStringAsFixed(ms < 10000 ? 1 : 0));
