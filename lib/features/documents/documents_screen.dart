import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/breakpoints.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../shared/home_shell.dart';
import 'document_model.dart';
import 'documents_repository.dart';

class DocumentsScreen extends ConsumerStatefulWidget {
  const DocumentsScreen({super.key});

  @override
  ConsumerState<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends ConsumerState<DocumentsScreen> {
  /// While any document is still ingesting, re-fetch the list on this cadence
  /// so the progress badge moves without a manual refresh.
  static const pollInterval = Duration(seconds: 3);

  String? _uploadingName;
  double _uploadProgress = 0;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _syncPolling(bool needed) {
    if (needed && _poll == null) {
      _poll = Timer.periodic(pollInterval, (_) => ref.invalidate(documentListProvider));
    } else if (!needed && _poll != null) {
      _poll!.cancel();
      _poll = null;
    }
  }

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'docx', 'md', 'txt', 'html', 'csv', 'json'],
    );
    final picked = result?.files.firstOrNull;
    if (picked == null || picked.path == null) return;

    setState(() {
      _uploadingName = picked.name;
      _uploadProgress = 0;
    });
    try {
      final repo = await ref.read(documentsRepositoryProvider.future);
      final result = await repo.upload(
        path: picked.path!,
        filename: picked.name,
        onProgress: (p) {
          if (mounted) setState(() => _uploadProgress = p);
        },
      );
      ref.invalidate(documentListProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.queued
                ? 'Document queued for indexing'
                : '“${result.document.name}” was already uploaded — showing the existing copy',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    } finally {
      if (mounted) setState(() => _uploadingName = null);
    }
  }

  Future<void> _delete(Document d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text('“${d.name}” will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final repo = await ref.read(documentsRepositoryProvider.future);
      await repo.delete(d.id);
      ref.invalidate(documentListProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final docs = ref.watch(documentListProvider);
    _syncPolling(docs.valueOrNull?.any((d) => d.isInFlight) ?? false);
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text('Documents', style: TextStyle(color: t.textPrimary)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => ref.invalidate(documentListProvider),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_uploadingName != null)
            _UploadProgressBar(name: _uploadingName!, progress: _uploadProgress),
          Expanded(
            child: RefreshIndicator(
              color: NexusColors.crimson,
              backgroundColor: t.surfaceHigh,
              onRefresh: () async => ref.invalidate(documentListProvider),
              child: docs.when(
                loading: () => ListView.separated(
                  padding: const EdgeInsets.all(NexusSpacing.lg),
                  itemCount: 5,
                  separatorBuilder: (_, __) => const SizedBox(height: NexusSpacing.sm),
                  itemBuilder: (_, __) => const SkeletonRow(),
                ),
                error: (e, _) => EmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: 'Could not load documents',
                  subtitle: errorText(e),
                ),
                data: (list) {
                  if (list.isEmpty) {
                    return EmptyState(
                      icon: Icons.upload_file_rounded,
                      title: 'Upload knowledge for NexusBot',
                      subtitle:
                          'PDFs, DOCX, MD, TXT, HTML. Each upload is chunked, embedded, and ready for RAG.',
                      action: NexusButton(
                        label: 'Upload your first file',
                        icon: Icons.upload_rounded,
                        expand: false,
                        onPressed: _uploadingName != null ? null : _pickAndUpload,
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                      NexusSpacing.lg,
                      NexusSpacing.md,
                      NexusSpacing.lg,
                      NexusSpacing.xxxl + 60,
                    ),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: NexusSpacing.sm),
                    itemBuilder: (_, i) =>
                        _DocumentTile(doc: list[i], onDelete: () => _delete(list[i])),
                  );
                },
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploadingName != null ? null : _pickAndUpload,
        icon: _uploadingName != null
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.upload_rounded),
        label: const Text('Upload', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class _UploadProgressBar extends StatelessWidget {
  const _UploadProgressBar({required this.name, required this.progress});
  final String name;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        NexusSpacing.lg,
        NexusSpacing.md,
        NexusSpacing.lg,
        NexusSpacing.md,
      ),
      color: t.surfaceHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_upload_rounded, size: 16, color: NexusColors.crimson),
              const SizedBox(width: NexusSpacing.sm),
              Expanded(
                child: Text(
                  'Uploading $name…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '${(progress * 100).round()}%',
                style: const TextStyle(
                  color: NexusColors.crimson,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress == 0 ? null : progress,
              minHeight: 4,
              backgroundColor: t.surfaceHigher,
              color: NexusColors.crimson,
            ),
          ),
        ],
      ),
    );
  }
}

class _DocumentTile extends StatelessWidget {
  const _DocumentTile({required this.doc, required this.onDelete});
  final Document doc;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(NexusSpacing.lg),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.lg),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: t.background,
              borderRadius: const BorderRadius.all(NexusRadius.md),
              border: Border.all(color: t.border),
            ),
            alignment: Alignment.center,
            child: Icon(_iconFor(doc.mimeType), color: NexusColors.crimson, size: 20),
          ),
          const SizedBox(width: NexusSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  doc.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_fmtBytes(doc.sizeBytes)} · ${_shortMime(doc.mimeType)}',
                  style: TextStyle(color: t.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          _StatusBadge(status: doc.status, progress: doc.progress),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            color: t.textMuted,
            tooltip: 'Delete',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  IconData _iconFor(String mime) {
    if (mime.contains('pdf')) return Icons.picture_as_pdf_rounded;
    if (mime.contains('word') || mime.contains('docx')) return Icons.description_rounded;
    if (mime.contains('markdown')) return Icons.notes_rounded;
    if (mime.contains('html')) return Icons.language_rounded;
    if (mime.contains('csv') || mime.contains('json')) return Icons.code_rounded;
    return Icons.description_outlined;
  }

  String _shortMime(String mime) {
    if (mime.contains('pdf')) return 'PDF';
    if (mime.contains('word')) return 'DOCX';
    if (mime.contains('markdown')) return 'Markdown';
    if (mime.contains('html')) return 'HTML';
    if (mime.startsWith('text/')) return 'Text';
    return mime;
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status, this.progress});
  final DocumentStatus status;

  /// Ingest percent (0–100) shown while processing.
  final int? progress;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      DocumentStatus.pending => ('PENDING', context.tokens.textMuted),
      DocumentStatus.processing => (
          progress == null ? 'INDEXING' : 'INDEXING $progress%',
          NexusColors.warn,
        ),
      DocumentStatus.ready => ('READY', NexusColors.success),
      DocumentStatus.failed => ('FAILED', NexusColors.crimson),
      DocumentStatus.unknown => ('?', context.tokens.textMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
