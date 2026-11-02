import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import 'attachment_model.dart';
import 'attachments_repository.dart';

/// Where the composer's attach menu takes a file from.
enum AttachmentSource { gallery, camera, file }

/// Icon for an attachment's kind / mime type.
IconData attachmentIcon(Attachment a) {
  if (a.isImage) return Icons.image_outlined;
  if (a.isAudio) return Icons.graphic_eq_rounded;
  final mime = a.mimeType;
  if (mime.contains('pdf')) return Icons.picture_as_pdf_outlined;
  if (mime.contains('json') || mime.contains('csv')) return Icons.data_object_rounded;
  if (mime.startsWith('text/') || mime.contains('word') || mime.contains('markdown')) {
    return Icons.description_outlined;
  }
  if (mime.contains('zip') || mime.contains('tar')) return Icons.folder_zip_outlined;
  return Icons.insert_drive_file_outlined;
}

/// Short hint under a file / audio attachment: what the model got from it.
String? attachmentHint(AppLocalizations l10n, Attachment a) {
  if (a.isAudio) return a.hasText ? l10n.attachmentTranscribed : l10n.attachmentAudio;
  if (a.isArtifact) return l10n.attachmentGenerated;
  if (!a.isImage && a.hasText) return l10n.attachmentTextExtracted;
  return null;
}

/// An image fetched with the API client's credentials (bearer, `X-Org-Id`,
/// 307 to presigned storage followed without the bearer) and rendered from
/// memory. Content is cached by URL through [attachmentContentLoaderProvider].
class AuthenticatedImage extends ConsumerStatefulWidget {
  const AuthenticatedImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.semanticLabel,
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final String? semanticLabel;

  @override
  ConsumerState<AuthenticatedImage> createState() => _AuthenticatedImageState();
}

class _AuthenticatedImageState extends ConsumerState<AuthenticatedImage> {
  late Future<AttachmentBytes> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(attachmentContentLoaderProvider).load(widget.url);
  }

  @override
  void didUpdateWidget(AuthenticatedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _future = ref.read(attachmentContentLoaderProvider).load(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: FutureBuilder<AttachmentBytes>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ColoredBox(
              color: t.surfaceHigher,
              child: Center(
                child: Icon(Icons.broken_image_outlined, color: t.textMuted, size: 22),
              ),
            );
          }
          final data = snapshot.data;
          if (data == null) {
            return ColoredBox(
              color: t.surfaceHigher,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: t.textMuted),
                ),
              ),
            );
          }
          return Image.memory(
            data.bytes,
            fit: widget.fit,
            gaplessPlayback: true,
            semanticLabel: widget.semanticLabel,
            errorBuilder: (_, __, ___) => ColoredBox(
              color: t.surfaceHigher,
              child: Center(
                child: Icon(Icons.broken_image_outlined, color: t.textMuted, size: 22),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One upload waiting in the composer: a thumbnail (images) or a kind icon,
/// the name, the size and a remove button.
class PendingAttachmentChip extends StatelessWidget {
  const PendingAttachmentChip({super.key, required this.attachment, this.onRemove});
  final Attachment attachment;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final a = attachment;
    final hint = attachmentHint(l10n, a);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: t.surfaceHigher,
        borderRadius: const BorderRadius.all(NexusRadius.md),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.all(NexusRadius.sm),
            child: a.isRenderableImage
                ? AuthenticatedImage(url: a.url, width: 36, height: 36, semanticLabel: a.name)
                : Container(
                    width: 36,
                    height: 36,
                    color: t.surfaceHigh,
                    child: Icon(attachmentIcon(a), size: 18, color: NexusColors.crimson),
                  ),
          ),
          const SizedBox(width: NexusSpacing.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.textPrimary, fontSize: 12, fontWeight: FontWeight.w700),
                ),
                Text(
                  [a.sizeLabel, if (hint != null) hint].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.textMuted, fontSize: 10.5),
                ),
              ],
            ),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: 2),
            Tooltip(
              message: l10n.attachmentRemove,
              child: InkWell(
                onTap: onRemove,
                borderRadius: const BorderRadius.all(NexusRadius.pill),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close_rounded, size: 14, color: t.textMuted),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The attachments of a user message: images as a tappable grid of
/// thumbnails, files and audio clips as chips with what the model got from
/// them ("Transcribed", "Text extracted").
class MessageAttachments extends StatelessWidget {
  const MessageAttachments({super.key, required this.attachments, this.onOpen});
  final List<Attachment> attachments;
  final ValueChanged<Attachment>? onOpen;

  @override
  Widget build(BuildContext context) {
    final images = attachments.where((a) => a.isRenderableImage).toList();
    final others = attachments.where((a) => !a.isRenderableImage).toList();
    final single = images.length == 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (images.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in images)
                Semantics(
                  label: a.name,
                  image: true,
                  button: onOpen != null,
                  child: InkWell(
                    onTap: onOpen == null ? null : () => onOpen!(a),
                    borderRadius: const BorderRadius.all(NexusRadius.md),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.all(NexusRadius.md),
                      child: AuthenticatedImage(
                        url: a.url,
                        width: single ? _singleWidth(a) : 112,
                        height: single ? _singleHeight(a) : 112,
                        semanticLabel: a.name,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        if (images.isNotEmpty && others.isNotEmpty) const SizedBox(height: 6),
        for (final a in others) ...[
          _FileChip(attachment: a, onTap: onOpen == null ? null : () => onOpen!(a)),
          if (a != others.last) const SizedBox(height: 4),
        ],
      ],
    );
  }

  static double _singleWidth(Attachment a) {
    final w = a.width;
    final h = a.height;
    if (w == null || h == null || w <= 0 || h <= 0) return 240;
    return w >= h ? 260 : (260 * w / h).clamp(120, 260).toDouble();
  }

  static double _singleHeight(Attachment a) {
    final w = a.width;
    final h = a.height;
    if (w == null || h == null || w <= 0 || h <= 0) return 180;
    return w >= h ? (260 * h / w).clamp(100, 260).toDouble() : 260;
  }
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.attachment, this.onTap});
  final Attachment attachment;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final a = attachment;
    final hint = attachmentHint(context.l10n, a);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(NexusRadius.md),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.18),
            borderRadius: const BorderRadius.all(NexusRadius.md),
            border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(attachmentIcon(a), size: 16, color: Colors.white),
              const SizedBox(width: NexusSpacing.sm),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      [a.sizeLabel, if (hint != null) hint].join(' · '),
                      style: const TextStyle(color: Colors.white70, fontSize: 10.5),
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

/// A file a tool produced, shown under the reply: inline preview for images,
/// name, size and mime type, and a download / open button.
class ArtifactCard extends StatelessWidget {
  const ArtifactCard({super.key, required this.artifact, this.onOpen, this.onPreviewTap});
  final Attachment artifact;

  /// Download / open (hands the bytes to the platform).
  final VoidCallback? onOpen;

  /// Tap on the inline image preview (full-screen viewer).
  final VoidCallback? onPreviewTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final a = artifact;
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.md),
        border: Border.all(color: t.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (a.isRenderableImage)
            InkWell(
              onTap: onPreviewTap ?? onOpen,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: AuthenticatedImage(url: a.url, fit: BoxFit.contain, semanticLabel: a.name),
              ),
            ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              NexusSpacing.md,
              NexusSpacing.sm,
              4,
              NexusSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(attachmentIcon(a), size: 18, color: NexusColors.crimson),
                const SizedBox(width: NexusSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        [a.sizeLabel, a.mimeType, if (a.description != null) a.description!]
                            .join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.textMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                if (onOpen != null)
                  IconButton(
                    tooltip: context.l10n.attachmentDownload,
                    icon: Icon(Icons.download_rounded, size: 18, color: t.textSecondary),
                    onPressed: onOpen,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen image viewer (pinch to zoom) for an attachment or artifact.
Future<void> showAttachmentViewer(
  BuildContext context,
  Attachment attachment, {
  VoidCallback? onDownload,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => AttachmentViewerScreen(attachment: attachment, onDownload: onDownload),
    ),
  );
}

class AttachmentViewerScreen extends StatelessWidget {
  const AttachmentViewerScreen({super.key, required this.attachment, this.onDownload});
  final Attachment attachment;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          attachment.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        actions: [
          if (onDownload != null)
            IconButton(
              tooltip: context.l10n.attachmentDownload,
              icon: const Icon(Icons.download_rounded),
              onPressed: onDownload,
            ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: AuthenticatedImage(
            url: attachment.url,
            fit: BoxFit.contain,
            semanticLabel: attachment.name,
          ),
        ),
      ),
    );
  }
}
