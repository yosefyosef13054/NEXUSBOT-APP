import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/breakpoints.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../l10n/l10n.dart';
import '../../l10n/labels.dart';
import '../../shared/home_shell.dart';
import '../collections/collection_model.dart';
import '../collections/collections_repository.dart';
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

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _toastError(Object e) {
    if (mounted) _toast(context.describeError(e));
  }

  List<Collection> get _collections => ref.read(collectionListProvider).valueOrNull ?? const [];

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'docx', 'md', 'txt', 'html', 'csv', 'json'],
    );
    final picked = result?.files.firstOrNull;
    if (picked == null || picked.path == null || !mounted) return;
    final l10n = context.l10n;

    // Optional collection choice (pre-selects the active filter).
    var collectionId = ref.read(documentCollectionFilterProvider);
    final collections = _collections;
    if (collections.isNotEmpty) {
      final choice = await showDialog<_CollectionChoice>(
        context: context,
        builder: (_) => _CollectionChoiceDialog(
          title: l10n.documentsUploadTitle(picked.name),
          confirmLabel: l10n.documentsUpload,
          collections: collections,
          initial: collectionId,
        ),
      );
      if (choice == null || !mounted) return;
      collectionId = choice.collectionId;
    }

    setState(() {
      _uploadingName = picked.name;
      _uploadProgress = 0;
    });
    try {
      final repo = await ref.read(documentsRepositoryProvider.future);
      final uploaded = await repo.upload(
        path: picked.path!,
        filename: picked.name,
        collectionId: collectionId,
        onProgress: (p) {
          if (mounted) setState(() => _uploadProgress = p);
        },
      );
      _afterIngest(uploaded);
    } catch (e) {
      _toastError(e);
    } finally {
      if (mounted) setState(() => _uploadingName = null);
    }
  }

  Future<void> _addFromUrl() async {
    final uploaded = await showDialog<UploadResult>(
      context: context,
      builder: (_) => _AddFromUrlDialog(
        collections: _collections,
        initialCollectionId: ref.read(documentCollectionFilterProvider),
      ),
    );
    if (uploaded == null || !mounted) return;
    _afterIngest(uploaded);
  }

  void _afterIngest(UploadResult result) {
    ref.invalidate(documentListProvider);
    ref.invalidate(collectionListProvider);
    if (!mounted) return;
    final l10n = context.l10n;
    _toast(
      result.queued ? l10n.documentQueued : l10n.documentDuplicate(result.document.name),
    );
  }

  Future<void> _move(Document d) async {
    final l10n = context.l10n;
    final collections = _collections;
    final choice = await showDialog<_CollectionChoice>(
      context: context,
      builder: (_) => _CollectionChoiceDialog(
        title: l10n.documentsMoveTitle(d.name),
        confirmLabel: l10n.documentsMove,
        collections: collections,
        initial: d.collectionId,
      ),
    );
    if (choice == null || !mounted) return;
    try {
      final repo = await ref.read(documentsRepositoryProvider.future);
      await repo.moveToCollection(d.id, choice.collectionId);
      ref.invalidate(documentListProvider);
      ref.invalidate(collectionListProvider);
    } catch (e) {
      _toastError(e);
    }
  }

  Future<void> _delete(Document d) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.documentDeleteTitle),
        content: Text(l10n.documentDeleteBody(d.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final repo = await ref.read(documentsRepositoryProvider.future);
      await repo.delete(d.id);
      ref.invalidate(documentListProvider);
      ref.invalidate(collectionListProvider);
    } catch (e) {
      _toastError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final docs = ref.watch(documentListProvider);
    final collections = ref.watch(collectionListProvider).valueOrNull ?? const <Collection>[];
    final filter = ref.watch(documentCollectionFilterProvider);
    final collectionNames = {for (final c in collections) c.id: c.name};
    _syncPolling(docs.valueOrNull?.any((d) => d.isInFlight) ?? false);
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text(l10n.documentsTitle, style: TextStyle(color: t.textPrimary)),
        actions: [
          IconButton(
            tooltip: l10n.documentsAddFromUrl,
            icon: const Icon(Icons.add_link_rounded),
            onPressed: _uploadingName != null ? null : _addFromUrl,
          ),
          IconButton(
            tooltip: l10n.commonRefresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              ref.invalidate(documentListProvider);
              ref.invalidate(collectionListProvider);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_uploadingName != null)
            _UploadProgressBar(name: _uploadingName!, progress: _uploadProgress),
          if (collections.isNotEmpty)
            _CollectionFilterBar(
              collections: collections,
              selected: filter,
              onSelected: (id) => ref.read(documentCollectionFilterProvider.notifier).state = id,
            ),
          Expanded(
            child: RefreshIndicator(
              color: NexusColors.crimson,
              backgroundColor: t.surfaceHigh,
              onRefresh: () async {
                ref.invalidate(documentListProvider);
                ref.invalidate(collectionListProvider);
              },
              child: docs.when(
                loading: () => ListView.separated(
                  padding: const EdgeInsets.all(NexusSpacing.lg),
                  itemCount: 5,
                  separatorBuilder: (_, __) => const SizedBox(height: NexusSpacing.sm),
                  itemBuilder: (_, __) => const SkeletonRow(),
                ),
                error: (e, _) => EmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: l10n.documentsLoadFailed,
                  subtitle: context.describeError(e),
                ),
                data: (list) {
                  if (list.isEmpty) {
                    return EmptyState(
                      icon: Icons.upload_file_rounded,
                      title: filter == null
                          ? l10n.documentsEmptyTitle
                          : l10n.documentsEmptyInCollection(
                              collectionNames[filter] ?? l10n.documentsThisCollection,
                            ),
                      subtitle: filter == null
                          ? l10n.documentsEmptyBody
                          : l10n.documentsEmptyCollectionBody,
                      action: NexusButton(
                        label: l10n.documentsUploadFile,
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
                    itemBuilder: (_, i) => _DocumentTile(
                      doc: list[i],
                      collectionName: collectionNames[list[i].collectionId],
                      canMove: collections.isNotEmpty || list[i].collectionId != null,
                      onMove: () => _move(list[i]),
                      onDelete: () => _delete(list[i]),
                    ),
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
        label: Text(l10n.documentsUpload, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

/// Horizontal "All · collection · collection" filter chips.
class _CollectionFilterBar extends StatelessWidget {
  const _CollectionFilterBar({
    required this.collections,
    required this.selected,
    required this.onSelected,
  });

  final List<Collection> collections;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget chip(String label, String? id, {int? count}) {
      final active = selected == id;
      return Padding(
        padding: const EdgeInsetsDirectional.only(end: NexusSpacing.sm),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: const BorderRadius.all(NexusRadius.pill),
            onTap: () => onSelected(id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: active ? NexusColors.crimson.withValues(alpha: 0.15) : t.surfaceHigh,
                borderRadius: const BorderRadius.all(NexusRadius.pill),
                border: Border.all(color: active ? NexusColors.crimson : t.border),
              ),
              child: Text(
                count == null ? label : '$label · $count',
                style: TextStyle(
                  color: active ? t.textPrimary : t.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: 6),
        children: [
          chip(context.l10n.commonAll, null),
          for (final c in collections) chip(c.name, c.id, count: c.documentCount),
        ],
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
      padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: NexusSpacing.md),
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
                  context.l10n.documentsUploading(name),
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
  const _DocumentTile({
    required this.doc,
    required this.onDelete,
    required this.onMove,
    required this.canMove,
    this.collectionName,
  });
  final Document doc;
  final VoidCallback onDelete;
  final VoidCallback onMove;
  final bool canMove;
  final String? collectionName;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
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
                  [
                    _fmtBytes(doc.sizeBytes),
                    _shortMime(doc.mimeType),
                    if (doc.sourceHost != null) l10n.documentFrom(doc.sourceHost!),
                    if (collectionName != null) collectionName!,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          _StatusBadge(status: doc.status, progress: doc.progress),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_horiz_rounded, size: 18, color: t.textMuted),
            tooltip: l10n.commonMore,
            onSelected: (v) {
              if (v == 'move') onMove();
              if (v == 'delete') onDelete();
            },
            itemBuilder: (_) => [
              if (canMove) PopupMenuItem(value: 'move', child: Text(l10n.documentMoveToCollection)),
              PopupMenuItem(value: 'delete', child: Text(l10n.commonDelete)),
            ],
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
    if (mime.startsWith('text/')) return 'TXT';
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
    final color = switch (status) {
      DocumentStatus.pending => context.tokens.textMuted,
      DocumentStatus.processing => NexusColors.warn,
      DocumentStatus.ready => NexusColors.success,
      DocumentStatus.failed => NexusColors.crimson,
      DocumentStatus.unknown => context.tokens.textMuted,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        status.localized(context.l10n, progress: progress),
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

// ────────────────────────────────────────────────────────────────────────────
// Dialogs
// ────────────────────────────────────────────────────────────────────────────

/// Result of [_CollectionChoiceDialog]: [collectionId] null = no collection.
class _CollectionChoice {
  const _CollectionChoice(this.collectionId);
  final String? collectionId;
}

/// Dropdown of the user's collections (plus "No collection").
class _CollectionChoiceDialog extends StatefulWidget {
  const _CollectionChoiceDialog({
    required this.title,
    required this.confirmLabel,
    required this.collections,
    this.initial,
  });

  final String title;
  final String confirmLabel;
  final List<Collection> collections;
  final String? initial;

  @override
  State<_CollectionChoiceDialog> createState() => _CollectionChoiceDialogState();
}

class _CollectionChoiceDialogState extends State<_CollectionChoiceDialog> {
  late String? _selected =
      widget.collections.any((c) => c.id == widget.initial) ? widget.initial : null;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: _CollectionDropdown(
        collections: widget.collections,
        value: _selected,
        onChanged: (v) => setState(() => _selected = v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_CollectionChoice(_selected)),
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _CollectionDropdown extends StatelessWidget {
  const _CollectionDropdown({
    required this.collections,
    required this.value,
    required this.onChanged,
  });

  final List<Collection> collections;
  final String? value;
  final ValueChanged<String?> onChanged;

  static const _none = '\u0000none';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return InputDecorator(
      decoration: InputDecoration(labelText: l10n.documentsCollectionLabel),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          isDense: true,
          value: value ?? _none,
          items: [
            DropdownMenuItem(value: _none, child: Text(l10n.documentsNoCollection)),
            for (final c in collections) DropdownMenuItem(value: c.id, child: Text(c.name)),
          ],
          onChanged: (v) => onChanged(v == _none ? null : v),
        ),
      ),
    );
  }
}

/// `POST /documents/from-url`. Performs the request itself so a 422 (bad,
/// unreachable or private URL) can be shown inline and corrected.
class _AddFromUrlDialog extends ConsumerStatefulWidget {
  const _AddFromUrlDialog({required this.collections, this.initialCollectionId});
  final List<Collection> collections;
  final String? initialCollectionId;

  @override
  ConsumerState<_AddFromUrlDialog> createState() => _AddFromUrlDialogState();
}

class _AddFromUrlDialogState extends ConsumerState<_AddFromUrlDialog> {
  final _url = TextEditingController();
  late String? _collectionId = widget.collections.any((c) => c.id == widget.initialCollectionId)
      ? widget.initialCollectionId
      : null;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _url.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !(uri.isScheme('http') || uri.isScheme('https'))) {
      setState(() => _error = context.l10n.documentsUrlInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(documentsRepositoryProvider.future);
      final result = await repo.addFromUrl(url: url, collectionId: _collectionId);
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on ApiException catch (e) {
      if (!mounted) return;
      // 422: unreachable / unsupported / private URL — the message says which.
      setState(() => _error = e.statusCode == 422 ? e.message : context.describeError(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = context.describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return AlertDialog(
      title: Text(l10n.documentsAddFromUrl),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.documentsAddFromUrlBody,
            style: TextStyle(color: t.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: NexusSpacing.md),
          TextField(
            controller: _url,
            autofocus: true,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            autocorrect: false,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              hintText: 'https://example.com/article',
              prefixIcon: const Icon(Icons.link_rounded, size: 20),
              errorText: _error,
              errorMaxLines: 3,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
          ),
          if (widget.collections.isNotEmpty) ...[
            const SizedBox(height: NexusSpacing.md),
            _CollectionDropdown(
              collections: widget.collections,
              value: _collectionId,
              onChanged: (v) => setState(() => _collectionId = v),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          icon: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.download_rounded, size: 16),
          label: Text(_busy ? l10n.documentsFetching : l10n.commonAdd),
        ),
      ],
    );
  }
}
