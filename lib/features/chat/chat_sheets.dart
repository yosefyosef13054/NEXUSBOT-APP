import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../collections/collection_model.dart';
import '../models/model_info.dart';
import '../tools/tools_repository.dart';

// ============================================================================
// Tool picker
// ============================================================================

/// Result of [showToolPickerSheet]: [names] is the explicit selection, or
/// null to go back to the default (every tool that needs no approval).
class ToolSelection {
  const ToolSelection(this.names);
  final List<String>? names;
}

/// Per-chat tool picker. Approval-required tools carry a shield icon.
/// Returns null when dismissed without confirming.
Future<ToolSelection?> showToolPickerSheet(
  BuildContext context, {
  required List<ToolInfo> tools,
  required List<String> selected,
}) {
  return showModalBottomSheet<ToolSelection>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.tokens.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: NexusRadius.xl),
    ),
    builder: (_) => _ToolPickerSheet(tools: tools, selected: selected),
  );
}

class _ToolPickerSheet extends StatefulWidget {
  const _ToolPickerSheet({required this.tools, required this.selected});
  final List<ToolInfo> tools;
  final List<String> selected;

  @override
  State<_ToolPickerSheet> createState() => _ToolPickerSheetState();
}

class _ToolPickerSheetState extends State<_ToolPickerSheet> {
  late final Set<String> _checked = widget.selected.toSet();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return _SheetScaffold(
      title: 'Tools for this chat',
      subtitle: 'Pick what the agent may use. Tools marked with a shield ask for '
          'your approval before they run.',
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(const ToolSelection(null)),
          child: const Text('Reset to default'),
        ),
        const Spacer(),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(ToolSelection(_checked.toList())),
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: const Text('Apply'),
        ),
      ],
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final tool in widget.tools)
            CheckboxListTile(
              value: _checked.contains(tool.name),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _checked.add(tool.name);
                } else {
                  _checked.remove(tool.name);
                }
              }),
              activeColor: NexusColors.crimson,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: const EdgeInsets.symmetric(horizontal: NexusSpacing.sm),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      tool.name,
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (tool.requiresApproval) ...[
                    const SizedBox(width: 6),
                    const Tooltip(
                      message: 'Asks for your approval before running',
                      child: Icon(Icons.shield_rounded, size: 14, color: NexusColors.warn),
                    ),
                  ],
                ],
              ),
              subtitle: tool.description.isEmpty
                  ? null
                  : Text(tool.description, style: TextStyle(color: t.textMuted, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// Knowledge (collections) picker
// ============================================================================

/// Result of [showCollectionPickerSheet]: [ids] is the chosen collections,
/// or null for "all documents".
class CollectionSelection {
  const CollectionSelection(this.ids);
  final List<String>? ids;
}

/// Picks the collections a chat's retrieval is scoped to. Returns null when
/// dismissed without confirming.
Future<CollectionSelection?> showCollectionPickerSheet(
  BuildContext context, {
  required List<Collection> collections,
  required List<String>? selectedIds,
}) {
  return showModalBottomSheet<CollectionSelection>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.tokens.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: NexusRadius.xl),
    ),
    builder: (_) => _CollectionPickerSheet(collections: collections, selectedIds: selectedIds),
  );
}

class _CollectionPickerSheet extends StatefulWidget {
  const _CollectionPickerSheet({required this.collections, required this.selectedIds});
  final List<Collection> collections;
  final List<String>? selectedIds;

  @override
  State<_CollectionPickerSheet> createState() => _CollectionPickerSheetState();
}

class _CollectionPickerSheetState extends State<_CollectionPickerSheet> {
  late bool _all = widget.selectedIds == null;
  late final Set<String> _checked = (widget.selectedIds ?? const []).toSet();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return _SheetScaffold(
      title: 'Knowledge for this chat',
      subtitle: 'Answers are grounded in the selected collections. The choice is saved '
          'as this chat\'s default.',
      actions: [
        const Spacer(),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            CollectionSelection(_all ? null : _checked.toList()),
          ),
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: const Text('Apply'),
        ),
      ],
      child: ListView(
        shrinkWrap: true,
        children: [
          SwitchListTile(
            value: _all,
            onChanged: (v) => setState(() => _all = v),
            activeTrackColor: NexusColors.crimson,
            contentPadding: const EdgeInsets.symmetric(horizontal: NexusSpacing.sm),
            title: Text(
              'All documents',
              style: TextStyle(color: t.textPrimary, fontSize: 14, fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              'Search everything you uploaded.',
              style: TextStyle(color: t.textMuted, fontSize: 12),
            ),
          ),
          Divider(color: t.borderSubtle, height: 1),
          for (final c in widget.collections)
            CheckboxListTile(
              value: !_all && _checked.contains(c.id),
              onChanged: _all
                  ? null
                  : (v) => setState(() {
                        if (v == true) {
                          _checked.add(c.id);
                        } else {
                          _checked.remove(c.id);
                        }
                      }),
              activeColor: NexusColors.crimson,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: const EdgeInsets.symmetric(horizontal: NexusSpacing.sm),
              title: Text(
                c.name,
                style: TextStyle(
                  color: _all ? t.textMuted : t.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Text(
                [
                  '${c.documentCount} document${c.documentCount == 1 ? '' : 's'}',
                  if (c.description != null && c.description!.isNotEmpty) c.description!,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.textMuted, fontSize: 12),
              ),
            ),
          if (widget.collections.isEmpty)
            Padding(
              padding: const EdgeInsets.all(NexusSpacing.lg),
              child: Text(
                'No collections yet — create one from the Collections screen.',
                style: TextStyle(color: t.textMuted, fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// Model picker (header menu + composer chip)
// ============================================================================

/// A popup menu over the model catalog. [currentId] is highlighted; the
/// optional [defaultEntry] row (e.g. "Session default") reports null.
class ModelMenuButton extends StatelessWidget {
  const ModelMenuButton({
    super.key,
    required this.catalog,
    required this.currentId,
    required this.onSelected,
    required this.child,
    this.defaultEntry,
    this.tooltip,
    this.enabled = true,
  });

  final ModelCatalog catalog;
  final String? currentId;
  final ValueChanged<String?> onSelected;
  final Widget child;
  final String? defaultEntry;
  final String? tooltip;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: tooltip ?? 'Choose model',
      onSelected: (v) => onSelected(v == _defaultValue ? null : v),
      itemBuilder: (_) => [
        if (defaultEntry != null)
          PopupMenuItem(
            value: _defaultValue,
            child: _ModelRow(
              title: defaultEntry!,
              subtitle: null,
              selected: currentId == null,
            ),
          ),
        for (final m in catalog.items)
          PopupMenuItem(
            value: m.id,
            child: _ModelRow(
              title: m.displayName,
              subtitle: [
                m.provider,
                if (m.contextLabel != null) m.contextLabel!,
                if (m.priceLabel != null) m.priceLabel!,
              ].join(' · '),
              selected: currentId == m.id,
              color: t.textMuted,
            ),
          ),
      ],
      child: child,
    );
  }

  static const _defaultValue = '\u0000default';
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.title,
    required this.subtitle,
    required this.selected,
    this.color,
  });
  final String title;
  final String? subtitle;
  final bool selected;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      children: [
        Icon(
          selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
          size: 16,
          color: selected ? NexusColors.crimson : t.textMuted,
        ),
        const SizedBox(width: NexusSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(subtitle!, style: TextStyle(color: color ?? t.textMuted, fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// Shared sheet chrome
// ============================================================================

class _SheetScaffold extends StatelessWidget {
  const _SheetScaffold({
    required this.title,
    required this.subtitle,
    required this.actions,
    required this.child,
  });
  final String title;
  final String subtitle;
  final List<Widget> actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
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
            NexusSpacing.md,
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
                title,
                style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(subtitle, style: TextStyle(color: t.textSecondary, fontSize: 12.5)),
              const SizedBox(height: NexusSpacing.sm),
              Flexible(child: child),
              const SizedBox(height: NexusSpacing.sm),
              Row(children: actions),
            ],
          ),
        ),
      ),
    );
  }
}
