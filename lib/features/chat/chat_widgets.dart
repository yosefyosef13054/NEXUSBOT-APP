import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../attachments/attachment_widgets.dart';
import 'approval_card.dart';
import 'chat_models.dart';
import 'code_block.dart';
import 'message_extras.dart';
import 'tool_chips.dart';

export '../attachments/attachment_widgets.dart' show AttachmentSource;

// ============================================================================
// MessageBubble — wraps the bubble with tool chips above, citations below,
// and a row of message-level actions (copy, regenerate, edit, feedback).
//
// Everything is laid out with logical (start / end) geometry: the user's
// bubbles sit at the end side, the assistant's at the start side, so the
// chat mirrors as a whole under RTL.
// ============================================================================

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.onRegenerate,
    required this.isLastAssistant,
    this.hiddenToolCallIds = const {},
    this.onApprovalDecision,
    this.approvalBusy = false,
    this.onCitationTap,
    this.onEdit,
    this.editing = false,
    this.onSubmitEdit,
    this.onCancelEdit,
    this.onSwitchSibling,
    this.switchingBranch = false,
    this.onFeedback,
    this.onMemoriesTap,
    this.onOpenAttachment,
    this.onOpenArtifact,
    this.onPlayAudio,
    this.playingAudio = false,
    this.onRetrySend,
    this.onCancelSend,
  });

  final ChatMessage message;
  final VoidCallback? onRegenerate;
  final bool isLastAssistant;

  /// Tap on one of a user message's attachments (image viewer / download).
  final ValueChanged<Attachment>? onOpenAttachment;

  /// Download / open one of a reply's artifacts.
  final ValueChanged<Attachment>? onOpenArtifact;

  /// Play (or stop) the spoken version of a reply with `meta.audio`.
  final VoidCallback? onPlayAudio;
  final bool playingAudio;

  /// `call_id`s already rendered as standalone tool rows just above this
  /// bubble (history `role: "tool"` messages) — skipped in the strip so a
  /// run is never shown twice.
  final Set<String> hiddenToolCallIds;

  /// Approve / Deny on the bubble's approval card; null disables the buttons.
  final ValueChanged<ApprovalDecision>? onApprovalDecision;
  final bool approvalBusy;
  final ValueChanged<Citation>? onCitationTap;

  /// Shows **Edit** in a user message's actions; null hides it.
  final VoidCallback? onEdit;

  /// The bubble renders an inline editor instead of its text.
  final bool editing;
  final ValueChanged<String>? onSubmitEdit;
  final VoidCallback? onCancelEdit;

  /// "‹ i/n ›" under a message with siblings; receives `-1` / `+1`.
  final ValueChanged<int>? onSwitchSibling;
  final bool switchingBranch;

  /// Thumbs up / down on a reply (receives `1` / `-1`); null hides them.
  final ValueChanged<int>? onFeedback;

  /// Tap on the "used N memories" caption.
  final VoidCallback? onMemoriesTap;

  /// Retry / cancel of a queued or parked send (user bubbles with
  /// [ChatMessage.isQueued]).
  final VoidCallback? onRetrySend;
  final VoidCallback? onCancelSend;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _showActions = false;
  bool _copied = false;

  bool get _isUser => widget.message.role == MessageRole.user;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.message.content));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final crossAxis = _isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final toolCalls = [
      for (final tc in message.toolCalls)
        if (tc.callId == null || !widget.hiddenToolCallIds.contains(tc.callId)) tc,
    ];
    final approval = message.approval;

    return MouseRegion(
      onEnter: (_) => setState(() => _showActions = true),
      onExit: (_) => setState(() => _showActions = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: () => setState(() => _showActions = !_showActions),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: NexusSpacing.sm),
          child: Column(
            crossAxisAlignment: crossAxis,
            children: [
              if (toolCalls.isNotEmpty) ...[
                ToolCallChips(calls: toolCalls),
                const SizedBox(height: NexusSpacing.xs),
              ],
              Opacity(
                opacity: message.isQueued ? 0.75 : 1,
                child: _BubbleContainer(
                  isUser: _isUser,
                  child: widget.editing
                      ? _InlineEditor(
                          initial: message.content,
                          onSubmit: widget.onSubmitEdit,
                          onCancel: widget.onCancelEdit,
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isUser && message.attachments.isNotEmpty) ...[
                              MessageAttachments(
                                attachments: message.attachments,
                                onOpen: widget.onOpenAttachment,
                              ),
                              if (message.content.isNotEmpty)
                                const SizedBox(height: NexusSpacing.sm),
                            ],
                            if (approval == null || message.content.isNotEmpty)
                              _BubbleContent(message: message),
                            if (approval != null) ...[
                              if (message.content.isNotEmpty)
                                const SizedBox(height: NexusSpacing.md),
                              ApprovalCard(
                                approval: approval,
                                busy: widget.approvalBusy,
                                onDecision: widget.onApprovalDecision,
                              ),
                            ],
                          ],
                        ),
                ),
              ),
              if (message.isQueued) ...[
                const SizedBox(height: NexusSpacing.xs),
                QueuedSendStatus(
                  message: message,
                  onRetry: widget.onRetrySend,
                  onCancel: widget.onCancelSend,
                ),
              ],
              if (message.interrupted && !message.streaming) ...[
                const SizedBox(height: NexusSpacing.xs),
                const _StoppedMarker(),
              ],
              if (!_isUser && message.artifacts.isNotEmpty) ...[
                const SizedBox(height: NexusSpacing.sm),
                for (final a in message.artifacts) ...[
                  ArtifactCard(
                    artifact: a,
                    onOpen: widget.onOpenArtifact == null ? null : () => widget.onOpenArtifact!(a),
                  ),
                  if (a != message.artifacts.last) const SizedBox(height: NexusSpacing.xs),
                ],
              ],
              if (!_isUser && message.audio?.isPlayable == true && widget.onPlayAudio != null) ...[
                const SizedBox(height: NexusSpacing.xs),
                _ListenChip(playing: widget.playingAudio, onTap: widget.onPlayAudio!),
              ],
              if (message.citations.isNotEmpty) ...[
                const SizedBox(height: NexusSpacing.sm),
                CitationsStrip(citations: message.citations, onTap: widget.onCitationTap),
              ],
              if (!_isUser && message.memoriesUsed.isNotEmpty && !message.streaming) ...[
                const SizedBox(height: NexusSpacing.xs),
                MemoriesCaption(count: message.memoriesUsed.length, onTap: widget.onMemoriesTap),
              ],
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 150),
                crossFadeState: (_showActions || widget.isLastAssistant || _hasSiblings) &&
                        !message.streaming &&
                        !widget.editing &&
                        !message.isQueued
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: const SizedBox(height: 4),
                secondChild: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _MessageActionsRow(
                    isUser: _isUser,
                    timestamp: message.createdAt,
                    model: _isUser ? null : message.model,
                    copied: _copied,
                    onCopy: _copy,
                    onRegenerate: !_isUser && widget.isLastAssistant ? widget.onRegenerate : null,
                    onEdit: _isUser && !message.isPendingUser ? widget.onEdit : null,
                    siblings: _hasSiblings ? message.siblings : null,
                    onSwitchSibling: widget.onSwitchSibling,
                    switchingBranch: widget.switchingBranch,
                    feedback: message.feedback,
                    onFeedback: !_isUser && !message.streaming && message.approval == null
                        ? widget.onFeedback
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _hasSiblings => widget.message.siblings?.hasSiblings == true;
}

/// "Waiting to send…" / "Not sent · reason" under a queued user bubble, with
/// retry and cancel.
class QueuedSendStatus extends StatelessWidget {
  const QueuedSendStatus({super.key, required this.message, this.onRetry, this.onCancel});

  final ChatMessage message;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final failed = message.delivery == MessageDelivery.failed;
    final reason = message.deliveryError;
    final label = failed
        ? (reason == null || reason.isEmpty
            ? l10n.chatQueuedFailed
            : '${l10n.chatQueuedFailed} · $reason')
        : l10n.chatQueuedLabel;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          failed ? Icons.error_outline_rounded : Icons.schedule_rounded,
          size: 12,
          color: failed ? NexusColors.crimson : t.textMuted,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: failed ? NexusColors.crimson : t.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (onRetry != null && failed) ...[
          const SizedBox(width: 4),
          _SmallTextButton(label: l10n.chatRetrySend, onTap: onRetry!),
        ],
        if (onCancel != null) ...[
          const SizedBox(width: 2),
          _SmallTextButton(label: l10n.chatCancelSend, onTap: onCancel!),
        ],
      ],
    );
  }
}

class _SmallTextButton extends StatelessWidget {
  const _SmallTextButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: NexusColors.crimson,
        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
      child: Text(label),
    );
  }
}

class _MessageActionsRow extends StatelessWidget {
  const _MessageActionsRow({
    required this.isUser,
    required this.timestamp,
    required this.copied,
    required this.onCopy,
    required this.onRegenerate,
    this.model,
    this.onEdit,
    this.siblings,
    this.onSwitchSibling,
    this.switchingBranch = false,
    this.feedback,
    this.onFeedback,
  });

  final bool isUser;
  final DateTime timestamp;
  final bool copied;
  final VoidCallback onCopy;
  final VoidCallback? onRegenerate;

  /// The model that produced the reply — shown as a muted caption.
  final String? model;
  final VoidCallback? onEdit;
  final SiblingInfo? siblings;
  final ValueChanged<int>? onSwitchSibling;
  final bool switchingBranch;
  final MessageFeedback? feedback;
  final ValueChanged<int>? onFeedback;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toString();
    return Row(
      mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (siblings != null) ...[
          SiblingSwitcher(
            siblings: siblings!,
            onSwitch: onSwitchSibling,
            busy: switchingBranch,
          ),
          const SizedBox(width: 8),
        ],
        Text(
          DateFormat.jm(locale).format(timestamp.toLocal()),
          style: TextStyle(color: t.textMuted, fontSize: 11),
        ),
        if (model != null && model!.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Tooltip(
              message: l10n.msgModelTooltip(model!),
              child: Text(
                '· $model',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.textMuted, fontSize: 11),
              ),
            ),
          ),
        ],
        const SizedBox(width: 8),
        _ActionIcon(
          icon: copied ? Icons.check_rounded : Icons.copy_rounded,
          tooltip: copied ? l10n.commonCopied : l10n.commonCopy,
          color: copied ? NexusColors.success : t.textMuted,
          onTap: onCopy,
        ),
        if (onEdit != null) ...[
          const SizedBox(width: 4),
          _ActionIcon(
            icon: Icons.edit_outlined,
            tooltip: l10n.msgEdit,
            color: t.textMuted,
            onTap: onEdit!,
          ),
        ],
        if (onRegenerate != null) ...[
          const SizedBox(width: 4),
          _ActionIcon(
            icon: Icons.refresh_rounded,
            tooltip: l10n.msgRegenerate,
            color: t.textMuted,
            onTap: onRegenerate!,
          ),
        ],
        if (onFeedback != null) ...[
          const SizedBox(width: 4),
          FeedbackButtons(feedback: feedback, onRate: onFeedback),
        ],
      ],
    );
  }
}

/// Replaces a user message's text while it is being edited: a text field
/// plus **Save** (sends the new text as a sibling of the message) and
/// **Cancel**.
class _InlineEditor extends StatefulWidget {
  const _InlineEditor({required this.initial, required this.onSubmit, required this.onCancel});
  final String initial;
  final ValueChanged<String>? onSubmit;
  final VoidCallback? onCancel;

  @override
  State<_InlineEditor> createState() => _InlineEditorState();
}

class _InlineEditorState extends State<_InlineEditor> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text.trim();
    if (text.isEmpty || text == widget.initial.trim()) {
      widget.onCancel?.call();
      return;
    }
    widget.onSubmit?.call(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 8,
          style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.45),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: const Color(0x26000000),
            hintText: l10n.editorHint,
            hintStyle: const TextStyle(color: Colors.white70),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            enabledBorder: const OutlineInputBorder(
              borderRadius: BorderRadius.all(NexusRadius.sm),
              borderSide: BorderSide(color: Colors.white38),
            ),
            focusedBorder: const OutlineInputBorder(
              borderRadius: BorderRadius.all(NexusRadius.sm),
              borderSide: BorderSide(color: Colors.white),
            ),
          ),
        ),
        const SizedBox(height: NexusSpacing.sm),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: widget.onCancel,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: Text(l10n.commonCancel),
            ),
            const SizedBox(width: NexusSpacing.xs),
            FilledButton.icon(
              onPressed: _submit,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: NexusColors.crimsonDeep,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.send_rounded, size: 14),
              label: Text(l10n.editorSaveSend),
            ),
          ],
        ),
      ],
    );
  }
}

/// "Play reply" / "Stop" pill under a reply that has a spoken version.
class _ListenChip extends StatelessWidget {
  const _ListenChip({required this.playing, required this.onTap});
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: playing ? NexusColors.crimson.withValues(alpha: 0.12) : t.surfaceHigh,
            borderRadius: const BorderRadius.all(NexusRadius.pill),
            border: Border.all(color: playing ? NexusColors.crimson : t.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                playing ? Icons.stop_rounded : Icons.volume_up_rounded,
                size: 14,
                color: NexusColors.crimson,
              ),
              const SizedBox(width: 4),
              Text(
                playing ? l10n.listenStop : l10n.listenPlay,
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small "stopped" marker for a reply whose generation was interrupted
/// (the bubble holds the partial text the server persisted).
class _StoppedMarker extends StatelessWidget {
  const _StoppedMarker();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.stop_circle_outlined, size: 12, color: t.textMuted),
        const SizedBox(width: 4),
        Text(
          context.l10n.stoppedLabel,
          style: TextStyle(
            color: t.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

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

// ============================================================================
// Bubble container + content
// ============================================================================

class _BubbleContainer extends StatelessWidget {
  const _BubbleContainer({required this.isUser, required this.child});
  final bool isUser;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.82;
    // The small "tail" corner faces the edge the bubble sits on (end for
    // the user, start for the assistant), in either text direction.
    final radius = isUser
        ? const BorderRadiusDirectional.only(
            topStart: NexusRadius.lg,
            topEnd: NexusRadius.lg,
            bottomStart: NexusRadius.lg,
            bottomEnd: NexusRadius.sm,
          )
        : const BorderRadiusDirectional.only(
            topStart: NexusRadius.lg,
            topEnd: NexusRadius.lg,
            bottomEnd: NexusRadius.lg,
            bottomStart: NexusRadius.sm,
          );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth.clamp(280, 720)),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: isUser ? NexusColors.redGradient : null,
          color: isUser ? null : t.surfaceHigh,
          borderRadius: radius,
          border: isUser ? null : Border.all(color: t.border),
          boxShadow: isUser
              ? const [
                  BoxShadow(
                    color: NexusColors.crimsonGlow,
                    blurRadius: 18,
                    spreadRadius: -6,
                    offset: Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NexusSpacing.lg,
            vertical: NexusSpacing.md,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _BubbleContent extends StatelessWidget {
  const _BubbleContent({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final isUser = message.role == MessageRole.user;

    if (message.streaming && message.content.isEmpty) {
      return const TypingDots();
    }

    if (isUser) {
      return SelectableText(
        message.isVoicePlaceholder ? context.l10n.chatVoiceMessagePlaceholder : message.content,
        style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.45),
      );
    }

    if (message.content.isEmpty && message.approval != null) {
      return const SizedBox.shrink();
    }

    return MarkdownBody(
      data: message.content.isEmpty ? '…' : message.content,
      selectable: true,
      builders: {'code': _CodeElementBuilder()},
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(color: t.textPrimary, fontSize: 15, height: 1.55),
        strong: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w700),
        code: GoogleFonts.jetBrainsMono(
          backgroundColor: t.surfaceHigher,
          color: NexusColors.crimson,
          fontSize: 13,
        ),
        codeblockPadding: EdgeInsets.zero,
        codeblockDecoration: const BoxDecoration(),
        blockquoteDecoration: const BoxDecoration(
          border: BorderDirectional(start: BorderSide(color: NexusColors.crimson, width: 3)),
        ),
        blockquotePadding:
            const EdgeInsetsDirectional.only(start: 12).resolve(Directionality.of(context)),
        h1: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w800),
        h2: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w800),
        listBullet: const TextStyle(color: NexusColors.crimson),
        a: const TextStyle(color: NexusColors.crimson, decoration: TextDecoration.underline),
      ),
    );
  }
}

/// Replaces fenced code blocks rendered by `flutter_markdown` with our
/// own `CodeBlock` widget (copy button + language pill).
class _CodeElementBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final isFenced = element.attributes['class']?.startsWith('language-') ?? false;
    if (!isFenced) return null;
    final lang = (element.attributes['class'] ?? '').replaceFirst('language-', '');
    return CodeBlock(code: element.textContent, language: lang);
  }
}

// ============================================================================
// Typing dots
// ============================================================================

class TypingDots extends StatefulWidget {
  const TypingDots({super.key});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 18,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = (_c.value + i * 0.2) % 1.0;
            final scale = 0.6 + (t < 0.5 ? t * 2 : (1 - t) * 2) * 0.4;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: NexusColors.crimson,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

// ============================================================================
// Citations strip
// ============================================================================

class CitationsStrip extends StatelessWidget {
  const CitationsStrip({super.key, required this.citations, this.onTap});
  final List<Citation> citations;
  final ValueChanged<Citation>? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: citations.length,
        separatorBuilder: (_, __) => const SizedBox(width: NexusSpacing.sm),
        itemBuilder: (_, i) {
          final c = citations[i];
          final location = c.locationLabel;
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap == null ? null : () => onTap!(c),
              borderRadius: const BorderRadius.all(NexusRadius.md),
              child: Container(
                width: 240,
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
                        const Icon(
                          Icons.description_outlined,
                          size: 14,
                          color: NexusColors.crimson,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            c.documentName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: t.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        Text(
                          '${(c.score * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                            color: NexusColors.crimson,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    if (location != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        location,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.textMuted,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Expanded(
                      child: Text(
                        c.excerpt,
                        maxLines: location == null ? 3 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.textSecondary, fontSize: 11, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================================
// Composer
// ============================================================================

class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.onSend,
    required this.sending,
    required this.useRag,
    required this.useTools,
    required this.onToggleRag,
    required this.onToggleTools,
    required this.onStop,
    this.controller,
    this.focusNode,
    this.enterSends = false,
    this.stopping = false,
    this.enabled = true,
    this.disabledHint,
    this.onSendBackground,
    this.toolsSummary,
    this.onPickTools,
    this.knowledgeLabel,
    this.onPickKnowledge,
    this.modelChip,
    this.attachments = const [],
    this.uploading = 0,
    this.onAttach,
    this.onRemoveAttachment,
    this.canAttachImages = true,
    this.imageAttachHint,
    this.voiceButton,
    this.speakReplies,
    this.onToggleSpeak,
  });

  final void Function(String) onSend;
  final bool sending;

  /// The text field's controller / focus node; the screen passes its own to
  /// pre-fill a draft (share intake) or move the focus. Owned by the
  /// composer when null.
  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// Desktop: Enter sends, Shift + Enter inserts a newline. Off (the
  /// default), Enter inserts a newline like a phone keyboard.
  final bool enterSends;

  /// Uploads waiting to go out with the next message.
  final List<Attachment> attachments;

  /// Uploads in flight (a spinner chip is shown while > 0).
  final int uploading;

  /// Opens the picker for the chosen source; null hides the attach button.
  final ValueChanged<AttachmentSource>? onAttach;
  final ValueChanged<Attachment>? onRemoveAttachment;

  /// False when the effective model cannot read images: the photo entries
  /// of the attach menu are disabled and [imageAttachHint] explains why.
  final bool canAttachImages;
  final String? imageAttachHint;

  /// Push-to-talk button (built by the screen when the server has
  /// speech-to-text); null hides it.
  final Widget? voiceButton;

  /// "Speak" chip state; null hides the chip (no text-to-speech).
  final bool? speakReplies;
  final ValueChanged<bool>? onToggleSpeak;

  /// False while sending is not allowed (the workspace budget is spent):
  /// the field and the send button are disabled and [disabledHint] shown.
  final bool enabled;
  final String? disabledHint;

  /// "Send in background" in the overflow menu: the server produces the
  /// reply even if the app goes away. Null hides the menu.
  final void Function(String)? onSendBackground;

  /// Stop was requested; waiting for the server to finalise the reply.
  final bool stopping;
  final bool useRag;
  final bool useTools;
  final ValueChanged<bool> onToggleRag;
  final ValueChanged<bool> onToggleTools;
  final VoidCallback onStop;

  /// `3/5` — how many of the server's tools are enabled for this chat.
  final String? toolsSummary;

  /// Opens the per-chat tool picker; null hides the button.
  final VoidCallback? onPickTools;

  /// Label of the "Knowledge" chip (the chat's collection scope); null
  /// hides the chip.
  final String? knowledgeLabel;
  final VoidCallback? onPickKnowledge;

  /// Per-turn model override chip (built by the screen from the catalog);
  /// null when the server lists no models.
  final Widget? modelChip;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  TextEditingController? _ownController;
  FocusNode? _ownFocus;

  TextEditingController get _controller =>
      widget.controller ?? (_ownController ??= TextEditingController());
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void dispose() {
    _ownController?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.sending || !widget.enabled) return;
    widget.onSend(text);
    _controller.clear();
    _focus.requestFocus();
  }

  void _sendBackground() {
    final text = _controller.text.trim();
    final handler = widget.onSendBackground;
    if (text.isEmpty || widget.sending || !widget.enabled || handler == null) return;
    handler(text);
    _controller.clear();
    _focus.requestFocus();
  }

  /// Enter sends on desktop; Shift + Enter falls through to the field (a
  /// newline).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.enterSends || event is KeyUpEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    _send();
    return KeyEventResult.handled;
  }

  /// The camera entry only makes sense on a phone / tablet.
  static bool get _hasCamera =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  String _hint(AppLocalizations l10n) {
    if (!widget.enabled) return widget.disabledHint ?? l10n.composerPaused;
    if (widget.attachments.isNotEmpty) return l10n.composerHintAttachment;
    return l10n.composerHint;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final toolsLabel = widget.useTools && widget.toolsSummary != null
        ? l10n.composerToolsCount(widget.toolsSummary!)
        : l10n.composerTools;
    final hasAttachments = widget.attachments.isNotEmpty || widget.uploading > 0;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: t.background,
          border: Border(top: BorderSide(color: t.border)),
        ),
        padding: const EdgeInsets.fromLTRB(
          NexusSpacing.md,
          NexusSpacing.sm,
          NexusSpacing.md,
          NexusSpacing.md,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ComposerChip(
                            label: l10n.composerRag,
                            active: widget.useRag,
                            icon: Icons.menu_book_rounded,
                            onTap: () => widget.onToggleRag(!widget.useRag),
                          ),
                          const SizedBox(width: NexusSpacing.sm),
                          ComposerChip(
                            label: toolsLabel,
                            active: widget.useTools,
                            icon: Icons.build_rounded,
                            onTap: () => widget.onToggleTools(!widget.useTools),
                            trailing: widget.useTools && widget.onPickTools != null
                                ? Icons.tune_rounded
                                : null,
                            onTrailingTap: widget.onPickTools,
                          ),
                          if (widget.knowledgeLabel != null) ...[
                            const SizedBox(width: NexusSpacing.sm),
                            ComposerChip(
                              label: widget.knowledgeLabel!,
                              active: widget.useRag,
                              icon: Icons.collections_bookmark_rounded,
                              onTap: widget.onPickKnowledge,
                            ),
                          ],
                          if (widget.speakReplies != null) ...[
                            const SizedBox(width: NexusSpacing.sm),
                            ComposerChip(
                              label: l10n.composerSpeak,
                              active: widget.speakReplies!,
                              icon: Icons.volume_up_rounded,
                              onTap: widget.onToggleSpeak == null
                                  ? null
                                  : () => widget.onToggleSpeak!(!widget.speakReplies!),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (widget.modelChip != null) ...[
                    const SizedBox(width: NexusSpacing.sm),
                    widget.modelChip!,
                  ],
                ],
              ),
              const SizedBox(height: NexusSpacing.sm),
              Container(
                decoration: BoxDecoration(
                  color: t.surfaceHigh,
                  borderRadius: const BorderRadius.all(NexusRadius.lg),
                  border: Border.all(color: t.border),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: NexusSpacing.md,
                  vertical: NexusSpacing.xs,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (hasAttachments)
                      Padding(
                        padding: const EdgeInsets.only(top: NexusSpacing.sm),
                        child: Wrap(
                          spacing: NexusSpacing.sm,
                          runSpacing: NexusSpacing.sm,
                          children: [
                            for (final a in widget.attachments)
                              PendingAttachmentChip(
                                key: ValueKey('pending-${a.id}'),
                                attachment: a,
                                onRemove: widget.onRemoveAttachment == null || widget.sending
                                    ? null
                                    : () => widget.onRemoveAttachment!(a),
                              ),
                            if (widget.uploading > 0) const _UploadingChip(),
                          ],
                        ),
                      ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (widget.onAttach != null)
                          _AttachMenuButton(
                            enabled: widget.enabled && !widget.sending,
                            canAttachImages: widget.canAttachImages,
                            imageAttachHint: widget.imageAttachHint,
                            showCamera: _hasCamera,
                            onSelected: widget.onAttach!,
                          ),
                        Expanded(
                          child: Focus(
                            onKeyEvent: _onKey,
                            child: TextField(
                              controller: _controller,
                              focusNode: _focus,
                              enabled: widget.enabled,
                              minLines: 1,
                              maxLines: 6,
                              textInputAction: TextInputAction.newline,
                              decoration: InputDecoration(
                                hintText: _hint(l10n),
                                border: InputBorder.none,
                                filled: false,
                                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                        ),
                        if (widget.voiceButton != null) ...[
                          const SizedBox(width: 4),
                          widget.voiceButton!,
                        ],
                        if (widget.onSendBackground != null) ...[
                          const SizedBox(width: 2),
                          PopupMenuButton<String>(
                            tooltip: l10n.commonMore,
                            enabled: widget.enabled && !widget.sending,
                            icon: Icon(Icons.more_vert_rounded, size: 18, color: t.textMuted),
                            onSelected: (v) {
                              if (v == 'background') _sendBackground();
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'background',
                                child: Row(
                                  children: [
                                    const Icon(Icons.cloud_sync_outlined, size: 16),
                                    const SizedBox(width: NexusSpacing.sm),
                                    Text(l10n.composerSendBackground),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(width: 4),
                        _SendOrStop(
                          sending: widget.sending,
                          stopping: widget.stopping,
                          enabled: widget.enabled,
                          onSend: _send,
                          onStop: widget.onStop,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paper-clip menu: photo library / camera (disabled with a hint when the
/// model cannot see images) and files.
class _AttachMenuButton extends StatelessWidget {
  const _AttachMenuButton({
    required this.enabled,
    required this.canAttachImages,
    required this.imageAttachHint,
    required this.showCamera,
    required this.onSelected,
  });

  final bool enabled;
  final bool canAttachImages;
  final String? imageAttachHint;
  final bool showCamera;
  final ValueChanged<AttachmentSource> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final hint = imageAttachHint ?? l10n.attachModelNoImages;
    return PopupMenuButton<AttachmentSource>(
      tooltip: l10n.attachTooltip,
      enabled: enabled,
      icon: Icon(
        Icons.attach_file_rounded,
        size: 20,
        color: enabled ? t.textSecondary : t.textMuted,
      ),
      onSelected: onSelected,
      itemBuilder: (_) => [
        PopupMenuItem(
          value: AttachmentSource.gallery,
          enabled: canAttachImages,
          child: _AttachMenuRow(
            icon: Icons.photo_library_outlined,
            label: l10n.attachPhotoLibrary,
            subtitle: canAttachImages ? null : hint,
          ),
        ),
        if (showCamera)
          PopupMenuItem(
            value: AttachmentSource.camera,
            enabled: canAttachImages,
            child: _AttachMenuRow(
              icon: Icons.photo_camera_outlined,
              label: l10n.attachTakePhoto,
              subtitle: canAttachImages ? null : hint,
            ),
          ),
        PopupMenuItem(
          value: AttachmentSource.file,
          child: _AttachMenuRow(
            icon: Icons.upload_file_outlined,
            label: l10n.attachFile,
            subtitle: l10n.attachFileSubtitle,
          ),
        ),
      ],
    );
  }
}

class _AttachMenuRow extends StatelessWidget {
  const _AttachMenuRow({required this.icon, required this.label, this.subtitle});
  final IconData icon;
  final String label;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: NexusSpacing.sm),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label),
              if (subtitle != null)
                Text(subtitle!, style: TextStyle(color: t.textMuted, fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}

class _UploadingChip extends StatelessWidget {
  const _UploadingChip();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: t.surfaceHigher,
        borderRadius: const BorderRadius.all(NexusRadius.md),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: t.textMuted),
          ),
          const SizedBox(width: NexusSpacing.sm),
          Text(context.l10n.composerUploading, style: TextStyle(color: t.textMuted, fontSize: 12)),
        ],
      ),
    );
  }
}

/// Pill used in the composer's option row (RAG / Tools / Knowledge / model).
class ComposerChip extends StatelessWidget {
  const ComposerChip({
    super.key,
    required this.label,
    required this.active,
    required this.icon,
    this.onTap,
    this.trailing,
    this.onTrailingTap,
  });

  final String label;
  final bool active;
  final IconData icon;
  final VoidCallback? onTap;

  /// Secondary icon at the end of the pill (e.g. "tune" to open a picker).
  final IconData? trailing;
  final VoidCallback? onTrailingTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final body = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: active ? NexusColors.crimson.withValues(alpha: 0.15) : t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        border: Border.all(color: active ? NexusColors.crimson : t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: active ? NexusColors.crimson : t.textSecondary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: active ? t.textPrimary : t.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 6),
            InkWell(
              onTap: onTrailingTap,
              borderRadius: const BorderRadius.all(NexusRadius.pill),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(trailing, size: 14, color: active ? NexusColors.crimson : t.textMuted),
              ),
            ),
          ],
        ],
      ),
    );
    return Material(
      color: Colors.transparent,
      child: onTap == null
          ? body
          : InkWell(
              borderRadius: const BorderRadius.all(NexusRadius.pill),
              onTap: onTap,
              child: body,
            ),
    );
  }
}

class _SendOrStop extends StatelessWidget {
  const _SendOrStop({
    required this.sending,
    required this.stopping,
    required this.onSend,
    required this.onStop,
    this.enabled = true,
  });

  final bool sending;
  final bool stopping;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final VoidCallback? onTap;
    if (stopping || (!enabled && !sending)) {
      onTap = null;
    } else if (sending) {
      onTap = onStop;
    } else {
      onTap = onSend;
    }
    return Tooltip(
      message: sending ? l10n.composerStopTooltip : l10n.composerSendTooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            gradient: sending || !enabled ? null : NexusColors.redGradient,
            color: sending || !enabled ? t.surfaceHigher : null,
            borderRadius: const BorderRadius.all(NexusRadius.md),
            boxShadow: sending || !enabled
                ? null
                : const [
                    BoxShadow(
                      color: NexusColors.crimsonGlow,
                      blurRadius: 16,
                      spreadRadius: -4,
                      offset: Offset(0, 4),
                    ),
                  ],
          ),
          child: stopping
              ? Center(
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(t.textMuted),
                    ),
                  ),
                )
              : Icon(
                  sending ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                  color: sending
                      ? t.textPrimary
                      : enabled
                          ? Colors.white
                          : t.textMuted,
                  size: 18,
                ),
        ),
      ),
    );
  }
}
