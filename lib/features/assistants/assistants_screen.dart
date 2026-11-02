import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/breakpoints.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../l10n/l10n.dart';
import '../../shared/home_shell.dart';
import '../auth/auth_providers.dart';
import '../models/model_info.dart';
import '../models/models_repository.dart';
import '../orgs/orgs_repository.dart';
import 'assistant_model.dart';
import 'assistant_picker.dart';
import 'assistants_repository.dart';

/// `/assistants` — the workspace's personas: avatar, name, model and the
/// default badge; tap to edit, menu to make default / delete.
class AssistantsScreen extends ConsumerStatefulWidget {
  const AssistantsScreen({super.key});

  @override
  ConsumerState<AssistantsScreen> createState() => _AssistantsScreenState();
}

class _AssistantsScreenState extends ConsumerState<AssistantsScreen> {
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _toastError(Object e) {
    if (!mounted) return;
    if (e is ApiException && e.isForbidden) {
      _toast(context.l10n.assistantReadOnlyMessage);
    } else {
      _toast(context.describeError(e));
    }
  }

  Future<void> _refresh() async {
    ref.invalidate(assistantListProvider);
    try {
      await ref.read(assistantListProvider.future);
    } catch (_) {
      // Rendered by the error state.
    }
  }

  Future<void> _setDefault(Assistant a, bool isDefault) async {
    try {
      final repo = await ref.read(assistantsRepositoryProvider.future);
      await repo.setDefault(a.id, isDefault);
      ref.invalidate(assistantListProvider);
    } catch (e) {
      _toastError(e);
    }
  }

  Future<void> _delete(Assistant a) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.assistantDeleteTitle),
        content: Text(l10n.assistantDeleteBody(a.name)),
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
    if (ok != true || !mounted) return;
    try {
      final repo = await ref.read(assistantsRepositoryProvider.future);
      await repo.delete(a.id);
      ref.invalidate(assistantListProvider);
      _toast(l10n.assistantDeleted(a.name));
    } catch (e) {
      _toastError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final assistants = ref.watch(assistantListProvider);
    final catalog = ref.watch(modelCatalogProvider).valueOrNull ?? ModelCatalog.empty;
    final user = ref.watch(currentUserProvider).valueOrNull;
    final org = ref.watch(activeOrgProvider).valueOrNull;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text(l10n.assistantsTitle, style: TextStyle(color: t.textPrimary)),
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
        child: assistants.when(
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
                title: l10n.assistantsLoadFailed,
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
                    icon: Icons.smart_toy_outlined,
                    title: l10n.assistantsCreateTitle,
                    subtitle: l10n.assistantsCreateBody,
                    action: NexusButton(
                      label: l10n.assistantsNew,
                      icon: Icons.add_rounded,
                      expand: false,
                      onPressed: () => context.go(AppRoutes.assistantNew),
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
                  itemBuilder: (_, i) {
                    final a = list[i];
                    return _AssistantTile(
                      assistant: a,
                      modelLabel: catalog.labelFor(a.model),
                      editable: a.isEditableBy(user, org),
                      onOpen: () => context.go(AppRoutes.assistant(a.id)),
                      onSetDefault: () => _setDefault(a, !a.isDefault),
                      onDelete: () => _delete(a),
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(AppRoutes.assistantNew),
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.assistantsNew, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class _AssistantTile extends StatelessWidget {
  const _AssistantTile({
    required this.assistant,
    required this.modelLabel,
    required this.editable,
    required this.onOpen,
    required this.onSetDefault,
    required this.onDelete,
  });

  final Assistant assistant;
  final String modelLabel;
  final bool editable;
  final VoidCallback onOpen;
  final VoidCallback onSetDefault;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final a = assistant;
    final hints = <String>[
      modelLabel,
      if (a.useRag) l10n.assistantHintRag,
      if (a.useTools) l10n.assistantHintTools(a.toolNames.length),
      if (a.memoryEnabled) l10n.assistantHintMemory,
      if (!editable) l10n.assistantHintReadOnly,
    ];
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
              AssistantAvatar(assistant: a, size: 42),
              const SizedBox(width: NexusSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            a.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: t.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (a.isDefault) ...[
                          const SizedBox(width: NexusSpacing.sm),
                          const DefaultBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        hints.join(' · '),
                        if (a.description?.trim().isNotEmpty == true) a.description!.trim(),
                      ].join('\n'),
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
                  if (v == 'default') onSetDefault();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'open',
                    child: Text(editable ? l10n.commonEdit : l10n.commonView),
                  ),
                  if (editable)
                    PopupMenuItem(
                      value: 'default',
                      child: Text(
                        a.isDefault ? l10n.assistantRemoveDefault : l10n.assistantMakeDefault,
                      ),
                    ),
                  if (editable) PopupMenuItem(value: 'delete', child: Text(l10n.commonDelete)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
