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
import '../collections/collection_model.dart';
import '../collections/collections_repository.dart';
import '../models/model_info.dart';
import '../models/models_repository.dart';
import '../orgs/orgs_repository.dart';
import '../tools/tools_repository.dart';
import 'assistant_model.dart';
import 'assistants_repository.dart';

/// `/assistants/new` and `/assistants/:id` — the assistant form: name,
/// description, avatar emoji, system prompt, model, RAG / tools toggles with
/// their pickers, temperature, memory and default flags.
///
/// Read-only for everyone but the creator and org admins (the server answers
/// 403 `forbidden`; the form is disabled up front when the role is known).
class AssistantEditorScreen extends ConsumerStatefulWidget {
  const AssistantEditorScreen({super.key, this.assistantId});

  /// Null = create.
  final String? assistantId;

  @override
  ConsumerState<AssistantEditorScreen> createState() => _AssistantEditorScreenState();
}

class _AssistantEditorScreenState extends ConsumerState<AssistantEditorScreen> {
  static const _modelDefault = '\u0000default';

  final _name = TextEditingController();
  final _description = TextEditingController();
  final _avatar = TextEditingController();
  final _prompt = TextEditingController();

  String? _model;
  bool _useRag = true;
  bool _useTools = false;
  final Set<String> _tools = {};
  final Set<String> _collections = {};
  bool _customTemperature = false;
  double _temperature = 0.7;
  bool _memoryEnabled = true;
  bool _isDefault = false;

  Assistant? _loaded;
  bool _loading = false;
  bool _saving = false;
  bool _readOnly = false;
  Object? _loadError;
  String? _nameError;

  bool get _isNew => widget.assistantId == null;

  @override
  void initState() {
    super.initState();
    if (!_isNew) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _avatar.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final repo = await ref.read(assistantsRepositoryProvider.future);
      final a = await repo.get(widget.assistantId!);
      if (!mounted) return;
      _apply(a);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _apply(Assistant a) {
    _loaded = a;
    _name.text = a.name;
    _description.text = a.description ?? '';
    _avatar.text = a.avatar ?? '';
    _prompt.text = a.systemPrompt ?? '';
    _model = a.model;
    _useRag = a.useRag;
    _useTools = a.useTools;
    _tools
      ..clear()
      ..addAll(a.toolNames);
    _collections
      ..clear()
      ..addAll(a.collectionIds);
    _customTemperature = a.temperature != null;
    _temperature = a.temperature ?? 0.7;
    _memoryEnabled = a.memoryEnabled;
    _isDefault = a.isDefault;
    final user = ref.read(currentUserProvider).valueOrNull;
    final org = ref.read(activeOrgProvider).valueOrNull;
    _readOnly = !a.isEditableBy(user, org);
    setState(() {});
  }

  AssistantDraft _draft() => AssistantDraft(
        name: _name.text.trim(),
        description: _description.text,
        avatar: _avatar.text,
        systemPrompt: _prompt.text,
        model: _model,
        toolNames: _tools.toList(),
        collectionIds: _collections.toList(),
        useRag: _useRag,
        useTools: _useTools,
        temperature: _customTemperature ? _temperature : null,
        memoryEnabled: _memoryEnabled,
        isDefault: _isDefault,
      );

  Future<void> _save() async {
    final l10n = context.l10n;
    if (_name.text.trim().isEmpty) {
      setState(() => _nameError = l10n.assistantNameRequired);
      return;
    }
    setState(() {
      _saving = true;
      _nameError = null;
    });
    try {
      final repo = await ref.read(assistantsRepositoryProvider.future);
      final draft = _draft();
      final id = widget.assistantId;
      if (id == null) {
        await repo.create(draft);
      } else {
        await repo.update(id, draft);
      }
      ref.invalidate(assistantListProvider);
      if (!mounted) return;
      _toast(id == null ? l10n.assistantCreated(draft.name) : l10n.assistantSaved);
      context.go(AppRoutes.assistants);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isForbidden) {
        setState(() => _readOnly = true);
        _toast(l10n.assistantReadOnlyMessage);
      } else {
        _toast(context.describeError(e));
      }
    } catch (e) {
      if (mounted) _toast(context.describeError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final a = _loaded;
    if (a == null) return;
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
      if (!mounted) return;
      context.go(AppRoutes.assistants);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isForbidden) setState(() => _readOnly = true);
      _toast(e.isForbidden ? l10n.assistantReadOnlyMessage : context.describeError(e));
    } catch (e) {
      if (mounted) _toast(context.describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final catalog = ref.watch(modelCatalogProvider).valueOrNull ?? ModelCatalog.empty;
    final tools = ref.watch(toolCatalogProvider).valueOrNull ?? const <ToolInfo>[];
    final collections = ref.watch(collectionListProvider).valueOrNull ?? const <Collection>[];
    final enabled = !_readOnly && !_saving && !_loading;

    final Widget body;
    if (_loading) {
      body = const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: NexusColors.crimson),
        ),
      );
    } else if (_loadError != null) {
      body = EmptyState(
        icon: Icons.cloud_off_rounded,
        title: l10n.assistantLoadFailed,
        subtitle: context.describeError(_loadError!),
        action: NexusGhostButton(
          label: l10n.commonRetry,
          icon: Icons.refresh_rounded,
          onPressed: _load,
        ),
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.all(NexusSpacing.lg),
        children: [
          if (_readOnly)
            Container(
              margin: const EdgeInsets.only(bottom: NexusSpacing.lg),
              padding: const EdgeInsets.symmetric(
                horizontal: NexusSpacing.md,
                vertical: NexusSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: NexusColors.warn.withValues(alpha: 0.12),
                borderRadius: const BorderRadius.all(NexusRadius.md),
                border: Border.all(color: NexusColors.warn.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline_rounded, size: 16, color: NexusColors.warn),
                  const SizedBox(width: NexusSpacing.sm),
                  Expanded(
                    child: Text(
                      l10n.assistantReadOnlyBanner(l10n.assistantReadOnlyMessage),
                      style: TextStyle(color: t.textPrimary, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          _Card(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 72,
                    child: TextField(
                      controller: _avatar,
                      enabled: enabled,
                      maxLength: 8,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 22),
                      decoration: const InputDecoration(hintText: '🤖', counterText: ''),
                    ),
                  ),
                  const SizedBox(width: NexusSpacing.md),
                  Expanded(
                    child: TextField(
                      controller: _name,
                      enabled: enabled,
                      autofocus: _isNew,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        hintText: l10n.assistantNameHint,
                        errorText: _nameError,
                      ),
                      onChanged: (_) {
                        if (_nameError != null) setState(() => _nameError = null);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: NexusSpacing.md),
              TextField(
                controller: _description,
                enabled: enabled,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(hintText: l10n.assistantDescriptionHint),
              ),
              const SizedBox(height: NexusSpacing.md),
              TextField(
                controller: _prompt,
                enabled: enabled,
                minLines: 4,
                maxLines: 12,
                decoration: InputDecoration(hintText: l10n.assistantPromptHint),
              ),
            ],
          ),
          const SizedBox(height: NexusSpacing.lg),
          _Card(
            title: l10n.sectionModel,
            children: [
              InputDecorator(
                decoration: InputDecoration(labelText: l10n.assistantModelLabel),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    isDense: true,
                    value: catalog.contains(_model) ? _model : _modelDefault,
                    items: [
                      DropdownMenuItem(
                        value: _modelDefault,
                        child: Text(l10n.assistantWorkspaceDefault),
                      ),
                      for (final m in catalog.items)
                        DropdownMenuItem(value: m.id, child: Text(m.displayName)),
                    ],
                    onChanged: enabled
                        ? (v) => setState(() => _model = v == _modelDefault ? null : v)
                        : null,
                  ),
                ),
              ),
              const SizedBox(height: NexusSpacing.sm),
              SwitchListTile(
                value: _customTemperature,
                onChanged: enabled ? (v) => setState(() => _customTemperature = v) : null,
                activeTrackColor: NexusColors.crimson,
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.assistantCustomTemperature, style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  _customTemperature
                      ? _temperature.toStringAsFixed(1)
                      : l10n.assistantTemperatureDefault,
                  style: TextStyle(color: t.textMuted, fontSize: 12),
                ),
              ),
              if (_customTemperature)
                Slider(
                  value: _temperature,
                  min: 0,
                  max: 2,
                  divisions: 20,
                  label: _temperature.toStringAsFixed(1),
                  activeColor: NexusColors.crimson,
                  onChanged: enabled ? (v) => setState(() => _temperature = v) : null,
                ),
            ],
          ),
          const SizedBox(height: NexusSpacing.lg),
          _Card(
            title: l10n.sectionKnowledge,
            children: [
              SwitchListTile(
                value: _useRag,
                onChanged: enabled ? (v) => setState(() => _useRag = v) : null,
                activeTrackColor: NexusColors.crimson,
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.assistantUseDocuments, style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  l10n.assistantUseDocumentsSubtitle,
                  style: TextStyle(color: t.textMuted, fontSize: 12),
                ),
              ),
              if (_useRag && collections.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: NexusSpacing.sm, bottom: 4),
                  child: Text(
                    l10n.assistantCollectionsLabel,
                    style: TextStyle(
                      color: t.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final c in collections)
                  CheckboxListTile(
                    value: _collections.contains(c.id),
                    onChanged: enabled
                        ? (v) => setState(() {
                              if (v == true) {
                                _collections.add(c.id);
                              } else {
                                _collections.remove(c.id);
                              }
                            })
                        : null,
                    activeColor: NexusColors.crimson,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(c.name, style: const TextStyle(fontSize: 13.5)),
                  ),
              ],
            ],
          ),
          const SizedBox(height: NexusSpacing.lg),
          _Card(
            title: l10n.sectionTools,
            children: [
              SwitchListTile(
                value: _useTools,
                onChanged: enabled ? (v) => setState(() => _useTools = v) : null,
                activeTrackColor: NexusColors.crimson,
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.assistantUseTools, style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  l10n.assistantUseToolsSubtitle,
                  style: TextStyle(color: t.textMuted, fontSize: 12),
                ),
              ),
              if (_useTools)
                if (tools.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: NexusSpacing.sm),
                    child: Text(
                      l10n.assistantNoTools,
                      style: TextStyle(color: t.textMuted, fontSize: 12),
                    ),
                  )
                else
                  for (final tool in tools)
                    CheckboxListTile(
                      value: _tools.contains(tool.name),
                      onChanged: enabled
                          ? (v) => setState(() {
                                if (v == true) {
                                  _tools.add(tool.name);
                                } else {
                                  _tools.remove(tool.name);
                                }
                              })
                          : null,
                      activeColor: NexusColors.crimson,
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Row(
                        children: [
                          Flexible(child: Text(tool.name, style: const TextStyle(fontSize: 13.5))),
                          if (tool.requiresApproval) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.shield_rounded, size: 13, color: NexusColors.warn),
                          ],
                        ],
                      ),
                      subtitle: tool.description.isEmpty
                          ? null
                          : Text(
                              tool.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: t.textMuted, fontSize: 11.5),
                            ),
                    ),
            ],
          ),
          const SizedBox(height: NexusSpacing.lg),
          _Card(
            title: l10n.sectionBehaviour,
            children: [
              SwitchListTile(
                value: _memoryEnabled,
                onChanged: enabled ? (v) => setState(() => _memoryEnabled = v) : null,
                activeTrackColor: NexusColors.crimson,
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.assistantUseMemory, style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  l10n.assistantUseMemorySubtitle,
                  style: TextStyle(color: t.textMuted, fontSize: 12),
                ),
              ),
              SwitchListTile(
                value: _isDefault,
                onChanged: enabled ? (v) => setState(() => _isDefault = v) : null,
                activeTrackColor: NexusColors.crimson,
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.assistantDefault, style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  l10n.assistantDefaultSubtitle,
                  style: TextStyle(color: t.textMuted, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: NexusSpacing.xl),
          if (!_readOnly)
            NexusButton(
              label: _isNew ? l10n.assistantCreateButton : l10n.assistantSaveChanges,
              icon: Icons.check_rounded,
              loading: _saving,
              onPressed: enabled ? _save : null,
            ),
          const SizedBox(height: NexusSpacing.xxxl),
        ],
      );
    }

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text(
          _isNew ? l10n.assistantNewTitle : (_loaded?.name ?? l10n.chatAssistantFallback),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => context.go(AppRoutes.assistants),
            child: Text(l10n.commonClose),
          ),
          if (!_isNew && !_readOnly && _loaded != null)
            IconButton(
              tooltip: l10n.assistantDeleteTooltip,
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _saving ? null : _delete,
            ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: body),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children, this.title});
  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, bottom: NexusSpacing.sm),
            child: Text(
              title!,
              style: TextStyle(
                color: t.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 3,
              ),
            ),
          ),
        Container(
          padding: const EdgeInsets.all(NexusSpacing.lg),
          decoration: BoxDecoration(
            color: t.surfaceHigh,
            borderRadius: const BorderRadius.all(NexusRadius.lg),
            border: Border.all(color: t.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ],
    );
  }
}
