import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/breakpoints.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../l10n/l10n.dart';
import '../../shared/home_shell.dart';
import '../attachments/attachment_picker.dart';
import '../chat/chat_models.dart';
import '../chat/chat_repository.dart';
import '../chat/new_chat.dart';
import 'share_intake.dart';

/// `/share` — "Share to NexusBot": a preview of what arrived and the chat
/// to send it to (a new one, or an existing one). The chosen chat opens
/// with the text in its composer and the files uploaded as attachments.
class ShareIntakeScreen extends ConsumerStatefulWidget {
  const ShareIntakeScreen({super.key});

  @override
  ConsumerState<ShareIntakeScreen> createState() => _ShareIntakeScreenState();
}

class _ShareIntakeScreenState extends ConsumerState<ShareIntakeScreen> {
  bool _busy = false;

  Future<void> _deliver(String sessionId, IncomingShare share) async {
    final files = <PickedAttachment>[];
    for (final f in share.files) {
      try {
        files.add(PickedAttachment(bytes: await File(f.path).readAsBytes(), filename: f.name));
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.shareIntakeAttachFailed(f.name))),
          );
        }
      }
    }
    if (!mounted) return;
    ref.read(composerDraftProvider.notifier).state =
        ComposerDraft(sessionId: sessionId, text: share.text, files: files);
    ref.read(pendingShareProvider.notifier).state = null;
    context.go(AppRoutes.chat(sessionId));
  }

  Future<void> _toNewChat(IncomingShare share) async {
    setState(() => _busy = true);
    try {
      final id = await startNewChat(context, ref, navigate: false);
      if (id == null || !mounted) return;
      await _deliver(id, share);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _cancel() {
    ref.read(pendingShareProvider.notifier).state = null;
    context.go(AppRoutes.home);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final share = ref.watch(pendingShareProvider);
    final sessions = ref.watch(sessionListProvider).valueOrNull ?? const <ChatSession>[];

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text(l10n.shareIntakeTitle, style: TextStyle(color: t.textPrimary)),
        actions: [TextButton(onPressed: _cancel, child: Text(l10n.commonCancel))],
      ),
      body: share == null
          ? EmptyState(
              icon: Icons.ios_share_rounded,
              title: l10n.shareIntakeTitle,
              subtitle: l10n.shareIntakeSubtitle,
            )
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.all(NexusSpacing.lg),
                  children: [
                    _SharePreview(share: share),
                    const SizedBox(height: NexusSpacing.lg),
                    Text(
                      l10n.shareIntakeSubtitle,
                      style: TextStyle(color: t.textSecondary, fontSize: 13),
                    ),
                    const SizedBox(height: NexusSpacing.md),
                    NexusButton(
                      label: l10n.shareIntakeNewChat,
                      icon: Icons.add_rounded,
                      loading: _busy,
                      onPressed: _busy ? null : () => _toNewChat(share),
                    ),
                    const SizedBox(height: NexusSpacing.lg),
                    Text(
                      l10n.shareIntakeExisting.toUpperCase(),
                      style: TextStyle(
                        color: t.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 3,
                      ),
                    ),
                    const SizedBox(height: NexusSpacing.sm),
                    if (sessions.isEmpty)
                      Text(
                        l10n.shareIntakeNoChats,
                        style: TextStyle(color: t.textMuted, fontSize: 12.5),
                      )
                    else
                      for (final s in sessions)
                        ListTile(
                          key: ValueKey('share-target-${s.id}'),
                          contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: 4),
                          leading: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                          title: Text(
                            s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600),
                          ),
                          trailing: Icon(Icons.chevron_right_rounded, color: t.textMuted),
                          onTap: _busy ? null : () => _deliver(s.id, share),
                        ),
                    const SizedBox(height: NexusSpacing.xxxl),
                  ],
                ),
              ),
            ),
    );
  }
}

class _SharePreview extends StatelessWidget {
  const _SharePreview({required this.share});
  final IncomingShare share;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final l10n = context.l10n;
    final text = share.text?.trim() ?? '';
    return Container(
      padding: const EdgeInsets.all(NexusSpacing.md),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.lg),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (text.isNotEmpty)
            Text(
              text,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.textPrimary, fontSize: 13.5, height: 1.4),
            ),
          if (share.files.isNotEmpty) ...[
            if (text.isNotEmpty) const SizedBox(height: NexusSpacing.sm),
            Row(
              children: [
                const Icon(Icons.attach_file_rounded, size: 16, color: NexusColors.crimson),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${l10n.shareIntakeFiles(share.files.length)} · '
                    '${share.files.map((f) => f.name).join(', ')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.textSecondary, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
