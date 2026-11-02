import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/breakpoints.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../l10n/l10n.dart';
import '../../shared/home_shell.dart';
import '../documents/documents_repository.dart';
import 'collection_model.dart';
import 'collections_repository.dart';

/// `/collections` — the user's knowledge bases: create, rename, delete
/// (optionally with their documents), and jump to the filtered document list.
class CollectionsScreen extends ConsumerStatefulWidget {
  const CollectionsScreen({super.key});

  @override
  ConsumerState<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends ConsumerState<CollectionsScreen> {
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _toastError(Object e) {
    if (mounted) _toast(context.describeError(e));
  }

  Future<void> _refresh() async {
    ref.invalidate(collectionListProvider);
    try {
      await ref.read(collectionListProvider.future);
    } catch (_) {
      // Rendered by the error state.
    }
  }

  Future<void> _create() async {
    final l10n = context.l10n;
    final result = await showDialog<_CollectionDraft>(
      context: context,
      builder: (_) =>
          _CollectionDialog(title: l10n.collectionsNew, confirmLabel: l10n.commonCreate),
    );
    if (result == null || !mounted) return;
    try {
      final repo = await ref.read(collectionsRepositoryProvider.future);
      await repo.create(name: result.name, description: result.description);
      ref.invalidate(collectionListProvider);
      _toast(l10n.collectionCreated(result.name));
    } catch (e) {
      _toastError(e);
    }
  }

  Future<void> _edit(Collection c) async {
    final l10n = context.l10n;
    final result = await showDialog<_CollectionDraft>(
      context: context,
      builder: (_) => _CollectionDialog(
        title: l10n.collectionEdit,
        confirmLabel: l10n.commonSave,
        initialName: c.name,
        initialDescription: c.description ?? '',
      ),
    );
    if (result == null || !mounted) return;
    try {
      final repo = await ref.read(collectionsRepositoryProvider.future);
      await repo.update(c.id, name: result.name, description: result.description ?? '');
      ref.invalidate(collectionListProvider);
    } catch (e) {
      _toastError(e);
    }
  }

  Future<void> _delete(Collection c) async {
    final l10n = context.l10n;
    final deleteDocuments = await showDialog<bool>(
      context: context,
      builder: (_) => _DeleteCollectionDialog(collection: c),
    );
    if (deleteDocuments == null || !mounted) return;
    try {
      final repo = await ref.read(collectionsRepositoryProvider.future);
      await repo.delete(c.id, deleteDocuments: deleteDocuments);
      ref.invalidate(collectionListProvider);
      ref.invalidate(documentListProvider);
      if (ref.read(documentCollectionFilterProvider) == c.id) {
        ref.read(documentCollectionFilterProvider.notifier).state = null;
      }
      _toast(
        deleteDocuments
            ? l10n.collectionDeletedWithDocs(c.name)
            : l10n.collectionDeletedKept(c.name),
      );
    } catch (e) {
      _toastError(e);
    }
  }

  void _openDocuments(Collection c) {
    ref.read(documentCollectionFilterProvider.notifier).state = c.id;
    context.go(AppRoutes.documents);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final collections = ref.watch(collectionListProvider);
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text(l10n.collectionsTitle, style: TextStyle(color: t.textPrimary)),
        actions: [
          IconButton(
            tooltip: l10n.commonRefresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        color: NexusColors.crimson,
        backgroundColor: t.surfaceHigh,
        onRefresh: _refresh,
        child: collections.when(
          loading: () => ListView.separated(
            padding: const EdgeInsets.all(NexusSpacing.lg),
            itemCount: 4,
            separatorBuilder: (_, __) => const SizedBox(height: NexusSpacing.sm),
            itemBuilder: (_, __) => const SkeletonRow(),
          ),
          error: (e, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              EmptyState(
                icon: Icons.cloud_off_rounded,
                title: l10n.collectionsLoadFailed,
                subtitle: context.describeError(e),
                action: NexusGhostButton(
                  label: l10n.commonRetry,
                  icon: Icons.refresh_rounded,
                  onPressed: _refresh,
                ),
              ),
            ],
          ),
          data: (list) {
            if (list.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  EmptyState(
                    icon: Icons.collections_bookmark_rounded,
                    title: l10n.collectionsEmptyTitle,
                    subtitle: l10n.collectionsEmptyBody,
                    action: NexusButton(
                      label: l10n.collectionsCreateOne,
                      icon: Icons.add_rounded,
                      expand: false,
                      onPressed: _create,
                    ),
                  ),
                ],
              );
            }
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 880),
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(
                    NexusSpacing.lg,
                    NexusSpacing.md,
                    NexusSpacing.lg,
                    NexusSpacing.xxxl + 60,
                  ),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: NexusSpacing.sm),
                  itemBuilder: (_, i) => _CollectionTile(
                    collection: list[i],
                    onOpen: () => _openDocuments(list[i]),
                    onEdit: () => _edit(list[i]),
                    onDelete: () => _delete(list[i]),
                  ),
                ),
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.collectionsNew, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class _CollectionTile extends StatelessWidget {
  const _CollectionTile({
    required this.collection,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final Collection collection;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final c = collection;
    final description = c.description?.trim() ?? '';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        borderRadius: const BorderRadius.all(NexusRadius.lg),
        child: Container(
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
                child: const Icon(
                  Icons.collections_bookmark_rounded,
                  color: NexusColors.crimson,
                  size: 20,
                ),
              ),
              const SizedBox(width: NexusSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.name,
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
                        l10n.collectionDocCount(c.documentCount),
                        if (description.isNotEmpty) description,
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.textMuted, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: l10n.commonMore,
                icon: Icon(Icons.more_horiz_rounded, size: 18, color: t.textMuted),
                onSelected: (v) {
                  if (v == 'open') onOpen();
                  if (v == 'edit') onEdit();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'open', child: Text(l10n.collectionShowDocuments)),
                  PopupMenuItem(value: 'edit', child: Text(l10n.collectionRenameDescribe)),
                  PopupMenuItem(value: 'delete', child: Text(l10n.commonDelete)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CollectionDraft {
  const _CollectionDraft({required this.name, this.description});
  final String name;
  final String? description;
}

/// Name + description prompt used for both create and edit. Owns its
/// controllers so they outlive the dialog's exit animation.
class _CollectionDialog extends StatefulWidget {
  const _CollectionDialog({
    required this.title,
    required this.confirmLabel,
    this.initialName = '',
    this.initialDescription = '',
  });

  final String title;
  final String confirmLabel;
  final String initialName;
  final String initialDescription;

  @override
  State<_CollectionDialog> createState() => _CollectionDialogState();
}

class _CollectionDialogState extends State<_CollectionDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.initialName);
  late final TextEditingController _description =
      TextEditingController(text: widget.initialDescription);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = context.l10n.collectionNameRequired);
      return;
    }
    Navigator.of(context).pop(
      _CollectionDraft(name: name, description: _description.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(hintText: l10n.collectionNameHint, errorText: _error),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: NexusSpacing.md),
          TextField(
            controller: _description,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(hintText: l10n.collectionDescriptionHint),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Confirms deletion; pops `true` to also delete the documents, `false` to
/// keep (unassign) them, null to cancel.
class _DeleteCollectionDialog extends StatefulWidget {
  const _DeleteCollectionDialog({required this.collection});
  final Collection collection;

  @override
  State<_DeleteCollectionDialog> createState() => _DeleteCollectionDialogState();
}

class _DeleteCollectionDialogState extends State<_DeleteCollectionDialog> {
  bool _deleteDocuments = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final c = widget.collection;
    return AlertDialog(
      title: Text(l10n.collectionDeleteTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.collectionDeleteBody(c.name, c.documentCount),
            style: TextStyle(color: t.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: NexusSpacing.sm),
          CheckboxListTile(
            value: _deleteDocuments,
            onChanged: (v) => setState(() => _deleteDocuments = v ?? false),
            activeColor: NexusColors.crimson,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(l10n.collectionAlsoDeleteDocs, style: const TextStyle(fontSize: 13.5)),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_deleteDocuments),
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: Text(l10n.commonDelete),
        ),
      ],
    );
  }
}
