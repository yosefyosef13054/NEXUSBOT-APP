import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../models/model_info.dart';
import '../models/models_repository.dart';
import 'assistant_model.dart';
import 'assistants_repository.dart';

/// The "New chat" flow: when the workspace has assistants, asks which one to
/// start with (the default preselected); otherwise answers "plain chat"
/// right away. Null when the sheet was dismissed.
Future<AssistantChoice?> pickAssistantForNewChat(BuildContext context, WidgetRef ref) async {
  final assistants = ref.read(assistantListProvider).valueOrNull ?? const <Assistant>[];
  if (assistants.isEmpty) return const AssistantChoice(null);
  final catalog = ref.read(modelCatalogProvider).valueOrNull ?? ModelCatalog.empty;
  return showAssistantPickerSheet(
    context,
    assistants: assistants,
    catalog: catalog,
    selectedId: ref.read(defaultAssistantProvider)?.id,
  );
}

/// Result of [showAssistantPickerSheet]: [assistantId] null = plain chat.
class AssistantChoice {
  const AssistantChoice(this.assistantId);
  final String? assistantId;
}

/// The "New chat" sheet: **Plain chat** plus every assistant of the
/// workspace (the default one preselected). Returns null when dismissed.
Future<AssistantChoice?> showAssistantPickerSheet(
  BuildContext context, {
  required List<Assistant> assistants,
  required ModelCatalog catalog,
  String? selectedId,
}) {
  return showModalBottomSheet<AssistantChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.tokens.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: NexusRadius.xl),
    ),
    builder: (_) => _AssistantPickerSheet(
      assistants: assistants,
      catalog: catalog,
      selectedId: selectedId,
    ),
  );
}

class _AssistantPickerSheet extends StatelessWidget {
  const _AssistantPickerSheet({
    required this.assistants,
    required this.catalog,
    required this.selectedId,
  });

  final List<Assistant> assistants;
  final ModelCatalog catalog;
  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;
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
              Text(
                l10n.assistantPickerTitle,
                style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.assistantPickerSubtitle,
                style: TextStyle(color: t.textSecondary, fontSize: 12.5),
              ),
              const SizedBox(height: NexusSpacing.sm),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    _PickerRow(
                      leading: const AssistantAvatar(assistant: null, size: 36),
                      title: l10n.assistantPlainChat,
                      subtitle: l10n.assistantPlainChatSubtitle,
                      selected: selectedId == null,
                      onTap: () => Navigator.of(context).pop(const AssistantChoice(null)),
                    ),
                    for (final a in assistants)
                      _PickerRow(
                        leading: AssistantAvatar(assistant: a, size: 36),
                        title: a.name,
                        subtitle: [
                          catalog.labelFor(a.model),
                          if (a.description?.isNotEmpty == true) a.description!,
                        ].join(' · '),
                        selected: selectedId == a.id,
                        badge: a.isDefault ? l10n.assistantDefaultBadge : null,
                        onTap: () => Navigator.of(context).pop(AssistantChoice(a.id)),
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

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: NexusSpacing.sm, vertical: 2),
      leading: leading,
      title: Row(
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: t.textPrimary,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
              ),
            ),
          ),
          if (badge != null) ...[
            const SizedBox(width: NexusSpacing.sm),
            DefaultBadge(label: badge!),
          ],
        ],
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: t.textMuted, fontSize: 12),
      ),
      trailing: Icon(
        selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
        size: 18,
        color: selected ? NexusColors.crimson : t.textMuted,
      ),
    );
  }
}

/// Emoji / initial tile for an assistant; a chat-bubble glyph for "no
/// assistant".
class AssistantAvatar extends StatelessWidget {
  const AssistantAvatar({super.key, required this.assistant, this.size = 32});
  final Assistant? assistant;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final a = assistant;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: a == null ? t.surfaceHigher : NexusColors.crimson.withValues(alpha: 0.12),
        borderRadius: const BorderRadius.all(NexusRadius.md),
        border:
            Border.all(color: a == null ? t.border : NexusColors.crimson.withValues(alpha: 0.5)),
      ),
      alignment: Alignment.center,
      child: a == null
          ? Icon(Icons.chat_bubble_outline_rounded, size: size * 0.5, color: t.textSecondary)
          : Text(
              a.avatarLabel,
              style: TextStyle(
                fontSize: size * 0.5,
                color: NexusColors.crimson,
                fontWeight: FontWeight.w800,
              ),
            ),
    );
  }
}

/// Small `DEFAULT` pill (the label defaults to the translated "DEFAULT").
class DefaultBadge extends StatelessWidget {
  const DefaultBadge({super.key, this.label});
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: NexusColors.crimson.withValues(alpha: 0.12),
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        border: Border.all(color: NexusColors.crimson.withValues(alpha: 0.4)),
      ),
      child: Text(
        label ?? context.l10n.assistantDefaultBadge,
        style: const TextStyle(
          color: NexusColors.crimson,
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

/// Chat-header menu: **Plain chat** + the workspace's assistants. Reports
/// the chosen assistant id (null = none).
class AssistantMenuButton extends StatelessWidget {
  const AssistantMenuButton({
    super.key,
    required this.assistants,
    required this.currentId,
    required this.onSelected,
    required this.child,
    this.enabled = true,
  });

  final List<Assistant> assistants;
  final String? currentId;
  final ValueChanged<String?> onSelected;
  final Widget child;
  final bool enabled;

  static const _none = '\u0000none';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: l10n.assistantMenuTooltip,
      onSelected: (v) => onSelected(v == _none ? null : v),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _none,
          child: _MenuRow(
            selected: currentId == null,
            leading: const AssistantAvatar(assistant: null, size: 26),
            title: l10n.assistantPlainChat,
            subtitle: null,
          ),
        ),
        for (final a in assistants)
          PopupMenuItem(
            value: a.id,
            child: _MenuRow(
              selected: currentId == a.id,
              leading: AssistantAvatar(assistant: a, size: 26),
              title: a.name,
              subtitle: a.description,
              color: t.textMuted,
            ),
          ),
      ],
      child: child,
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.selected,
    required this.leading,
    required this.title,
    required this.subtitle,
    this.color,
  });

  final bool selected;
  final Widget leading;
  final String title;
  final String? subtitle;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      children: [
        leading,
        const SizedBox(width: NexusSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color ?? t.textMuted, fontSize: 11),
                ),
            ],
          ),
        ),
        if (selected) ...[
          const SizedBox(width: NexusSpacing.sm),
          const Icon(Icons.check_rounded, size: 16, color: NexusColors.crimson),
        ],
      ],
    );
  }
}
