import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/breakpoints.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
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

  Future<void> _refresh() async {
    ref.invalidate(collectionListProvider);
    try {
      await ref.read(collectionListProvider.future);
    } catch (_) {
      // Rendered by the error state.
    }
  }

  Future<void> _create() async {
    final result = await showDialog<_CollectionDraft>(
      context: context,
      builder: (_) => const _CollectionDialog(title: 'New collection', confirmLabel: 'Create'),
    );
    if (result == null || !mounted) return;
    try {
      final repo = await ref.read(collectionsRepositoryProvider.future);
      await repo.create(name: result.name, description: result.description);
      ref.invalidate(collectionListProvider);
      _toast('Collection “${result.name}” created');
    } catch (e) {
      _toast(errorText(e));
    }
  }

  Future<void> _edit(Collection c) async {
    final result = await showDialog<_CollectionDraft>(
      context: context,
      builder: (_) => _CollectionDialog(
        title: 'Edit collection',
        confirmLabel: 'Save',
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
      _toast(errorText(e));
    }
  }

  Future<void> _delete(Collection c) async {
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
            ? '“${c.name}” and its documents were deleted'
            : '“${c.name}” deleted — its documents were kept',
      );
    } catch (e) {
      _toast(errorText(e));
    }
  }

  void _openDocuments(Collection c) {
    ref.read(documentCollectionFilterProvider.notifier).state = c.id;
    context.go(AppRoutes.documents);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final collections = ref.watch(collectionListProvider);
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text('Collections', style: TextStyle(color: t.textPrimary)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
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
                title: 'Could not load collections',
                subtitle: errorText(e),
                action: NexusGhostButton(
                  label: 'Retry',
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
                    title: 'Group your documents',
                    subtitle: 'Collections are knowledge bases: put related documents '
                        'together and scope any chat to just the ones it needs.',
                    action: NexusButton(
                      label: 'Create a collection',
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
        label: const Text('New collection', style: TextStyle(fontWeight: FontWeight.w700)),
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
                        '${c.documentCount} document${c.documentCount == 1 ? '' : 's'}',
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
                icon: Icon(Icons.more_horiz_rounded, size: 18, color: t.textMuted),
                onSelected: (v) {
                  if (v == 'open') onOpen();
                  if (v == 'edit') onEdit();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'open', child: Text('Show documents')),
                  PopupMenuItem(value: 'edit', child: Text('Rename / describe')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
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
      setState(() => _error = 'Give the collection a name');
      return;
    }
    Navigator.of(context).pop(
      _CollectionDraft(name: name, description: _description.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(hintText: 'Name', errorText: _error),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: NexusSpacing.md),
          TextField(
            controller: _description,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Description (optional)'),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
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
    final t = context.tokens;
    final c = widget.collection;
    return AlertDialog(
      title: const Text('Delete collection?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '“${c.name}” will be removed. Its ${c.documentCount} document'
            '${c.documentCount == 1 ? '' : 's'} stay in your library unless you '
            'delete them too.',
            style: TextStyle(color: t.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: NexusSpacing.sm),
          CheckboxListTile(
            value: _deleteDocuments,
            onChanged: (v) => setState(() => _deleteDocuments = v ?? false),
            activeColor: NexusColors.crimson,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Also delete the documents', style: TextStyle(fontSize: 13.5)),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_deleteDocuments),
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}
