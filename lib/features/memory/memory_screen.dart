import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/breakpoints.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../l10n/l10n.dart';
import '../../l10n/labels.dart';
import '../../shared/home_shell.dart';
import '../auth/auth_providers.dart';
import 'memory_model.dart';
import 'memory_repository.dart';

/// `/memory` — "What NexusBot remembers": memories grouped by kind, with
/// add / edit / delete and a confirmed "clear all".
class MemoryScreen extends ConsumerStatefulWidget {
  const MemoryScreen({super.key});

  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends ConsumerState<MemoryScreen> {
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _toastError(Object e) {
    if (mounted) _toast(context.describeError(e));
  }

  Future<void> _refresh() async {
    ref.invalidate(memoryListProvider);
    try {
      await ref.read(memoryListProvider.future);
    } catch (_) {
      // Rendered by the error state.
    }
  }

  Future<void> _add() async {
    final l10n = context.l10n;
    final draft = await showDialog<_MemoryDraft>(
      context: context,
      builder: (_) => _MemoryDialog(title: l10n.memoryRememberTitle, confirmLabel: l10n.commonAdd),
    );
    if (draft == null || !mounted) return;
    try {
      final repo = await ref.read(memoryRepositoryProvider.future);
      await repo.create(content: draft.content, kind: draft.kind, importance: draft.importance);
      ref.invalidate(memoryListProvider);
    } catch (e) {
      _toastError(e);
    }
  }

  Future<void> _edit(Memory m) async {
    final l10n = context.l10n;
    final draft = await showDialog<_MemoryDraft>(
      context: context,
      builder: (_) => _MemoryDialog(
        title: l10n.memoryEditTitle,
        confirmLabel: l10n.commonSave,
        initial: _MemoryDraft(content: m.content, kind: m.kind, importance: m.importance),
      ),
    );
    if (draft == null || !mounted) return;
    try {
      final repo = await ref.read(memoryRepositoryProvider.future);
      await repo.update(
        m.id,
        content: draft.content == m.content ? null : draft.content,
        kind: draft.kind == m.kind ? null : draft.kind,
        importance: draft.importance == m.importance ? null : draft.importance,
      );
      ref.invalidate(memoryListProvider);
    } catch (e) {
      _toastError(e);
    }
  }

  Future<void> _delete(Memory m) async {
    try {
      final repo = await ref.read(memoryRepositoryProvider.future);
      await repo.delete(m.id);
      ref.invalidate(memoryListProvider);
      if (mounted) _toast(context.l10n.memoryForgotten);
    } catch (e) {
      _toastError(e);
    }
  }

  Future<void> _clearAll(int count) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.memoryForgetAllTitle),
        content: Text(l10n.memoryForgetAllBody(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
            child: Text(l10n.memoryForgetAll),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final repo = await ref.read(memoryRepositoryProvider.future);
      await repo.clearAll();
      ref.invalidate(memoryListProvider);
    } catch (e) {
      _toastError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final memories = ref.watch(memoryListProvider);
    final memoryOn = ref.watch(currentUserProvider).valueOrNull?.memoryEnabled ?? true;
    final count = memories.valueOrNull?.length ?? 0;

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text(l10n.memoryTitle, style: TextStyle(color: t.textPrimary)),
        actions: [
          IconButton(
            tooltip: l10n.commonRefresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refresh,
          ),
          if (count > 0)
            IconButton(
              tooltip: l10n.memoryForgetEverything,
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => _clearAll(count),
            ),
        ],
      ),
      body: RefreshIndicator(
        color: NexusColors.crimson,
        backgroundColor: t.surfaceHigh,
        onRefresh: _refresh,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: memories.when(
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
                    title: l10n.memoryLoadFailed,
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
                final groups = {
                  for (final k in MemoryKind.values) k: list.where((m) => m.kind == k).toList(),
                };
                return ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(
                    NexusSpacing.lg,
                    NexusSpacing.md,
                    NexusSpacing.lg,
                    NexusSpacing.xxxl + 60,
                  ),
                  children: [
                    Text(
                      l10n.memoryHeading,
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.memoryIntro,
                      style: TextStyle(color: t.textSecondary, fontSize: 12.5, height: 1.4),
                    ),
                    if (!memoryOn) ...[
                      const SizedBox(height: NexusSpacing.md),
                      _MemoryOffBanner(onSettings: () => context.go(AppRoutes.settings)),
                    ],
                    const SizedBox(height: NexusSpacing.lg),
                    if (list.isEmpty)
                      EmptyState(
                        icon: Icons.psychology_outlined,
                        title: l10n.memoryEmptyTitle,
                        subtitle: memoryOn ? l10n.memoryEmptyOn : l10n.memoryEmptyOff,
                        action: NexusButton(
                          label: l10n.memoryAddOne,
                          icon: Icons.add_rounded,
                          expand: false,
                          onPressed: _add,
                        ),
                      )
                    else
                      for (final entry in groups.entries)
                        if (entry.value.isNotEmpty) ...[
                          _GroupHeader(kind: entry.key, count: entry.value.length),
                          for (final m in entry.value)
                            _MemoryTile(
                              memory: m,
                              onEdit: () => _edit(m),
                              onDelete: () => _delete(m),
                            ),
                          const SizedBox(height: NexusSpacing.md),
                        ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.memoryAdd, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class _MemoryOffBanner extends StatelessWidget {
  const _MemoryOffBanner({required this.onSettings});
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.md, vertical: NexusSpacing.sm),
      decoration: BoxDecoration(
        color: NexusColors.warn.withValues(alpha: 0.12),
        borderRadius: const BorderRadius.all(NexusRadius.md),
        border: Border.all(color: NexusColors.warn.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.memory_rounded, size: 16, color: NexusColors.warn),
          const SizedBox(width: NexusSpacing.sm),
          Expanded(
            child: Text(
              l10n.memoryOffBanner,
              style: TextStyle(color: t.textPrimary, fontSize: 12.5),
            ),
          ),
          TextButton(onPressed: onSettings, child: Text(l10n.commonSettings)),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.kind, required this.count});
  final MemoryKind kind;
  final int count;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 4, bottom: NexusSpacing.sm),
      child: Row(
        children: [
          Icon(kind.icon, size: 14, color: NexusColors.crimson),
          const SizedBox(width: 6),
          Text(
            kind.localized(context.l10n).toUpperCase(),
            style: TextStyle(
              color: t.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(width: NexusSpacing.sm),
          Text('$count', style: TextStyle(color: t.textMuted, fontSize: 11)),
        ],
      ),
    );
  }
}

class _MemoryTile extends StatelessWidget {
  const _MemoryTile({required this.memory, required this.onEdit, required this.onDelete});
  final Memory memory;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final m = memory;
    final used = m.lastUsedAt;
    final locale = Localizations.localeOf(context).toString();
    final date = DateFormat.yMMMd(locale);
    return Container(
      margin: const EdgeInsets.only(bottom: NexusSpacing.sm),
      padding: const EdgeInsets.all(NexusSpacing.md),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.lg),
        border: Border.all(color: t.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.content,
                  style: TextStyle(color: t.textPrimary, fontSize: 13.5, height: 1.4),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    ImportanceDots(importance: m.importance),
                    const SizedBox(width: NexusSpacing.sm),
                    Flexible(
                      child: Text(
                        used == null
                            ? (m.createdAt == null
                                ? l10n.memoryNeverUsed
                                : l10n.memoryAdded(date.format(m.createdAt!.toLocal())))
                            : l10n.memoryUsed(date.format(used.toLocal())),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.textMuted, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: l10n.commonMore,
            icon: Icon(Icons.more_horiz_rounded, size: 18, color: t.textMuted),
            onSelected: (v) {
              if (v == 'edit') onEdit();
              if (v == 'delete') onDelete();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'edit', child: Text(l10n.commonEdit)),
              PopupMenuItem(value: 'delete', child: Text(l10n.memoryForget)),
            ],
          ),
        ],
      ),
    );
  }
}

/// `●●●○○` importance indicator.
class ImportanceDots extends StatelessWidget {
  const ImportanceDots({super.key, required this.importance});
  final int importance;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: context.l10n.memoryImportanceTooltip(importance),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 5; i++)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsetsDirectional.only(end: 2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i <= importance ? NexusColors.crimson : t.surfaceHigher,
              ),
            ),
        ],
      ),
    );
  }
}

class _MemoryDraft {
  const _MemoryDraft({required this.content, required this.kind, required this.importance});
  final String content;
  final MemoryKind kind;
  final int importance;
}

/// Content + kind + importance prompt shared by add and edit.
class _MemoryDialog extends StatefulWidget {
  const _MemoryDialog({required this.title, required this.confirmLabel, this.initial});
  final String title;
  final String confirmLabel;
  final _MemoryDraft? initial;

  @override
  State<_MemoryDialog> createState() => _MemoryDialogState();
}

class _MemoryDialogState extends State<_MemoryDialog> {
  late final TextEditingController _content =
      TextEditingController(text: widget.initial?.content ?? '');
  late MemoryKind _kind = widget.initial?.kind ?? MemoryKind.fact;
  late double _importance = (widget.initial?.importance ?? 3).toDouble();
  String? _error;

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  void _submit() {
    final content = _content.text.trim();
    if (content.isEmpty) {
      setState(() => _error = context.l10n.memoryContentRequired);
      return;
    }
    Navigator.of(context).pop(
      _MemoryDraft(content: content, kind: _kind, importance: _importance.round()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _content,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(hintText: l10n.memoryContentHint, errorText: _error),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: NexusSpacing.md),
            InputDecorator(
              decoration: InputDecoration(labelText: l10n.memoryKind),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<MemoryKind>(
                  isExpanded: true,
                  isDense: true,
                  value: _kind,
                  items: [
                    for (final k in MemoryKind.values)
                      DropdownMenuItem(value: k, child: Text(k.localizedSingular(l10n))),
                  ],
                  onChanged: (v) => setState(() => _kind = v ?? MemoryKind.fact),
                ),
              ),
            ),
            const SizedBox(height: NexusSpacing.md),
            Row(
              children: [
                Text(l10n.memoryImportance, style: TextStyle(color: t.textSecondary, fontSize: 13)),
                const Spacer(),
                ImportanceDots(importance: _importance.round()),
              ],
            ),
            Slider(
              value: _importance,
              min: 1,
              max: 5,
              divisions: 4,
              label: '${_importance.round()}',
              activeColor: NexusColors.crimson,
              onChanged: (v) => setState(() => _importance = v),
            ),
          ],
        ),
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
