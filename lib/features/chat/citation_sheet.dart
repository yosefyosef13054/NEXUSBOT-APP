import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../l10n/l10n.dart';
import '../documents/document_model.dart';
import '../documents/documents_repository.dart';
import 'chat_models.dart';

/// Opens the chunk viewer for a citation.
Future<void> showCitationSheet(BuildContext context, Citation citation) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.tokens.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: NexusRadius.xl),
    ),
    builder: (_) => CitationSheet(citation: citation),
  );
}

/// Bottom sheet showing the cited chunk: document name, page / section,
/// score, the full chunk text (fetched from
/// `GET /documents/{document_id}/chunks/{chunk_id}`) and a shortcut to the
/// Documents screen.
class CitationSheet extends ConsumerStatefulWidget {
  const CitationSheet({super.key, required this.citation});
  final Citation citation;

  @override
  ConsumerState<CitationSheet> createState() => _CitationSheetState();
}

class _CitationSheetState extends ConsumerState<CitationSheet> {
  late Future<DocumentChunk?> _chunk = _fetch();

  Future<DocumentChunk?> _fetch() async {
    final c = widget.citation;
    if (!c.canOpen) return null;
    final repo = await ref.read(documentsRepositoryProvider.future);
    return repo.getChunk(c.documentId, c.chunkId!);
  }

  void _retry() => setState(() => _chunk = _fetch());

  void _openDocuments() {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.go(AppRoutes.documents);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final c = widget.citation;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            NexusSpacing.lg,
            NexusSpacing.md,
            NexusSpacing.lg,
            NexusSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: t.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: NexusSpacing.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.description_outlined, size: 18, color: NexusColors.crimson),
                  const SizedBox(width: NexusSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.documentName,
                          style: TextStyle(
                            color: t.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (c.locationLabel != null)
                          Text(
                            c.locationLabel!,
                            style: TextStyle(color: t.textSecondary, fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: NexusSpacing.sm),
                  _ScoreBadge(score: c.score, match: c.match),
                ],
              ),
              const SizedBox(height: NexusSpacing.md),
              Flexible(
                child: FutureBuilder<DocumentChunk?>(
                  future: _chunk,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: NexusSpacing.lg),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Skeleton(height: 14),
                            SizedBox(height: 8),
                            Skeleton(height: 14),
                            SizedBox(height: 8),
                            Skeleton(width: 220, height: 14),
                          ],
                        ),
                      );
                    }
                    if (snap.hasError) {
                      return _Message(
                        icon: Icons.cloud_off_rounded,
                        text: context.describeError(snap.error!),
                        action: TextButton(onPressed: _retry, child: Text(l10n.commonRetry)),
                        fallback: c.excerpt,
                      );
                    }
                    final chunk = snap.data;
                    final text = chunk?.content ?? c.excerpt;
                    return SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (chunk == null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: NexusSpacing.sm),
                              child: Text(
                                l10n.citationExcerptOnly,
                                style: TextStyle(color: t.textMuted, fontSize: 11.5),
                              ),
                            ),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(NexusSpacing.md),
                            decoration: BoxDecoration(
                              color: t.surfaceHigh,
                              borderRadius: const BorderRadius.all(NexusRadius.md),
                              border: Border.all(color: t.border),
                            ),
                            child: SelectableText(
                              text.isEmpty ? l10n.citationEmptyChunk : text,
                              style: TextStyle(color: t.textPrimary, fontSize: 13.5, height: 1.55),
                            ),
                          ),
                          if (chunk != null) ...[
                            const SizedBox(height: NexusSpacing.sm),
                            Text(
                              [
                                l10n.citationChunkIndex(chunk.chunkIndex),
                                if (chunk.tokens != null) l10n.citationTokens(chunk.tokens!),
                                if (chunk.startIndex != null && chunk.endIndex != null)
                                  l10n.citationChars(chunk.startIndex!, chunk.endIndex!),
                              ].join(' · '),
                              style: TextStyle(color: t.textMuted, fontSize: 11),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: NexusSpacing.lg),
              Row(
                children: [
                  const Spacer(),
                  NexusGhostButton(
                    label: l10n.citationOpenDocuments,
                    icon: Icons.menu_book_rounded,
                    onPressed: _openDocuments,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScoreBadge extends StatelessWidget {
  const _ScoreBadge({required this.score, this.match});
  final double score;
  final String? match;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final pct = (score * 100).toStringAsFixed(0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: NexusColors.crimson.withValues(alpha: 0.12),
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        border: Border.all(color: NexusColors.crimson.withValues(alpha: 0.5)),
      ),
      child: Text(
        match == null ? l10n.citationMatch(pct) : l10n.citationMatchKind(pct, match!),
        style: const TextStyle(
          color: NexusColors.crimson,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    required this.fallback,
    this.action,
  });
  final IconData icon;
  final String text;
  final String fallback;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: NexusColors.crimson),
              const SizedBox(width: NexusSpacing.sm),
              Expanded(
                child: Text(
                  context.l10n.citationLoadFailed(text),
                  style: TextStyle(color: t.textSecondary, fontSize: 12.5),
                ),
              ),
              if (action != null) action!,
            ],
          ),
          if (fallback.isNotEmpty) ...[
            const SizedBox(height: NexusSpacing.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(NexusSpacing.md),
              decoration: BoxDecoration(
                color: t.surfaceHigh,
                borderRadius: const BorderRadius.all(NexusRadius.md),
                border: Border.all(color: t.border),
              ),
              child: SelectableText(
                fallback,
                style: TextStyle(color: t.textPrimary, fontSize: 13.5, height: 1.55),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
