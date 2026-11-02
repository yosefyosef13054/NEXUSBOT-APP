import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/breakpoints.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../l10n/l10n.dart';
import '../../l10n/labels.dart';
import '../../shared/home_shell.dart';
import '../auth/auth_providers.dart';
import '../models/model_info.dart';
import '../models/models_repository.dart';
import '../usage/usage_model.dart';
import 'org_model.dart';
import 'orgs_repository.dart';

/// `/orgs/:orgId` — the workspace: name, monthly budgets, allowed models and
/// members. Owners and admins edit; everyone else gets a read-only view.
/// Organization ids never appear on screen — only names.
class OrgSettingsScreen extends ConsumerStatefulWidget {
  const OrgSettingsScreen({super.key, required this.orgId});
  final String orgId;

  @override
  ConsumerState<OrgSettingsScreen> createState() => _OrgSettingsScreenState();
}

class _OrgSettingsScreenState extends ConsumerState<OrgSettingsScreen> {
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _toastError(Object e) {
    if (mounted) _toast(context.describeError(e));
  }

  void _refresh() {
    ref.invalidate(orgDetailProvider(widget.orgId));
    ref.invalidate(orgMembersProvider(widget.orgId));
  }

  Future<void> _patch({String? name, OrgSettings? settings}) async {
    try {
      final repo = await ref.read(orgsRepositoryProvider.future);
      await repo.update(widget.orgId, name: name, settings: settings);
      ref.invalidate(orgDetailProvider(widget.orgId));
      ref.invalidate(orgListProvider);
    } catch (e) {
      _toastError(e);
    }
  }

  Future<void> _rename(Org org) async {
    final l10n = context.l10n;
    final name = await showDialog<String>(
      context: context,
      builder: (_) =>
          _TextDialog(title: l10n.orgRenameTitle, hint: l10n.orgRenameHint, initial: org.name),
    );
    if (name == null || name.isEmpty || name == org.name || !mounted) return;
    await _patch(name: name);
  }

  Future<void> _editBudgets(Org org) async {
    final result = await showDialog<OrgSettings>(
      context: context,
      builder: (_) => _BudgetDialog(settings: org.settings),
    );
    if (result == null || !mounted) return;
    await _patch(settings: result);
  }

  Future<void> _editAllowedModels(Org org, ModelCatalog catalog) async {
    final result = await showDialog<_AllowedModelsResult>(
      context: context,
      builder: (_) => _AllowedModelsDialog(catalog: catalog, allowed: org.settings.allowedModels),
    );
    if (result == null || !mounted) return;
    await _patch(
      settings: org.settings.copyWith(
        allowedModels: result.ids,
        clearAllowedModels: result.ids == null,
      ),
    );
  }

  Future<void> _invite() async {
    final result = await showDialog<_InviteResult>(
      context: context,
      builder: (_) => _InviteDialog(orgId: widget.orgId),
    );
    if (result == null || !mounted) return;
    ref.invalidate(orgMembersProvider(widget.orgId));
    ref.invalidate(orgDetailProvider(widget.orgId));
    ref.invalidate(orgListProvider);
    final l10n = context.l10n;
    _toast(
      l10n.orgMemberAdded(
        result.member.displayName,
        result.member.role.localized(l10n).toLowerCase(),
      ),
    );
  }

  Future<void> _setRole(OrgMember m, OrgRole role) async {
    try {
      final repo = await ref.read(orgsRepositoryProvider.future);
      await repo.updateMemberRole(widget.orgId, m.userId, role);
      ref.invalidate(orgMembersProvider(widget.orgId));
    } catch (e) {
      _toastError(e);
    }
  }

  Future<void> _remove(OrgMember m, {required bool self}) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(self ? l10n.orgLeaveTitle : l10n.orgRemoveMemberTitle),
        content: Text(self ? l10n.orgLeaveBody : l10n.orgRemoveMemberBody(m.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
            child: Text(self ? l10n.orgLeave : l10n.commonRemove),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final repo = await ref.read(orgsRepositoryProvider.future);
      await repo.removeMember(widget.orgId, m.userId);
      ref.invalidate(orgListProvider);
      if (!mounted) return;
      if (self) {
        // The list reload resets the active workspace to the personal one.
        context.go(AppRoutes.home);
        return;
      }
      ref.invalidate(orgMembersProvider(widget.orgId));
      ref.invalidate(orgDetailProvider(widget.orgId));
    } catch (e) {
      _toastError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final org = ref.watch(orgDetailProvider(widget.orgId));
    final members = ref.watch(orgMembersProvider(widget.orgId));
    final catalog = ref.watch(modelCatalogProvider).valueOrNull ?? ModelCatalog.empty;
    final me = ref.watch(currentUserProvider).valueOrNull;

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text(
          org.valueOrNull?.isPersonal == true
              ? l10n.orgPersonalWorkspace
              : (org.valueOrNull?.name ?? l10n.orgWorkspace),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.textPrimary),
        ),
        actions: [
          IconButton(
            tooltip: l10n.commonRefresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refresh,
          ),
        ],
      ),
      body: org.when(
        loading: () => const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: NexusColors.crimson),
          ),
        ),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off_rounded,
          title: l10n.orgLoadFailed,
          subtitle: context.describeError(e),
          action: NexusGhostButton(
            label: l10n.commonRetry,
            icon: Icons.refresh_rounded,
            onPressed: _refresh,
          ),
        ),
        data: (o) {
          final canManage = o.canManage;
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(NexusSpacing.lg),
                children: [
                  _HeaderCard(org: o, onRename: canManage ? () => _rename(o) : null),
                  const SizedBox(height: NexusSpacing.xl),
                  _Section(
                    label: l10n.sectionBudget,
                    children: [
                      _ValueTile(
                        icon: Icons.payments_outlined,
                        title: l10n.orgSpendingPerMonth,
                        value: o.settings.budgetUsdPerMonth == null
                            ? l10n.orgNoLimit
                            : formatUsd(o.settings.budgetUsdPerMonth!),
                        onTap: canManage ? () => _editBudgets(o) : null,
                      ),
                      const _Divider(),
                      _ValueTile(
                        icon: Icons.token_outlined,
                        title: l10n.orgTokensPerMonth,
                        value: o.settings.budgetTokensPerMonth == null
                            ? l10n.orgNoLimit
                            : formatTokens(o.settings.budgetTokensPerMonth!),
                        onTap: canManage ? () => _editBudgets(o) : null,
                      ),
                      if (canManage) ...[
                        const _Divider(),
                        _ValueTile(
                          icon: Icons.bar_chart_rounded,
                          title: l10n.orgUsageReport,
                          value: l10n.orgUsageReportValue,
                          onTap: () => context.go(AppRoutes.orgUsage(o.id)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: NexusSpacing.xl),
                  _Section(
                    label: l10n.sectionModels,
                    children: [
                      _ValueTile(
                        icon: Icons.memory_rounded,
                        title: l10n.orgAllowedModels,
                        value: _allowedLabel(l10n, o.settings.allowedModels, catalog),
                        onTap: canManage && catalog.isNotEmpty
                            ? () => _editAllowedModels(o, catalog)
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: NexusSpacing.xl),
                  _Section(
                    label: l10n.sectionTools,
                    children: [
                      _ValueTile(
                        icon: Icons.extension_rounded,
                        title: l10n.orgMcpServers,
                        value: canManage ? l10n.orgMcpValueAdmin : l10n.orgMcpValueMember,
                        onTap: canManage ? () => context.go(AppRoutes.orgMcp(o.id)) : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: NexusSpacing.xl),
                  _MembersSection(
                    members: members,
                    org: o,
                    meId: me?.id,
                    onInvite: canManage ? _invite : null,
                    onSetRole: canManage ? _setRole : null,
                    onRemove: _remove,
                    onRetry: () => ref.invalidate(orgMembersProvider(widget.orgId)),
                  ),
                  const SizedBox(height: NexusSpacing.xxxl + 40),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: org.valueOrNull?.canManage == true
          ? FloatingActionButton.extended(
              onPressed: _invite,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: Text(l10n.orgInvite, style: const TextStyle(fontWeight: FontWeight.w700)),
            )
          : null,
    );
  }

  static String _allowedLabel(AppLocalizations l10n, List<String>? allowed, ModelCatalog catalog) {
    if (allowed == null) return l10n.orgAllModels;
    if (allowed.isEmpty) return l10n.commonNone;
    if (allowed.length <= 2) return allowed.map(catalog.labelFor).join(', ');
    return l10n.orgModelsCount(allowed.length);
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.org, required this.onRename});
  final Org org;
  final VoidCallback? onRename;

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
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              gradient: NexusColors.redGradient,
              borderRadius: BorderRadius.all(NexusRadius.md),
            ),
            alignment: Alignment.center,
            child: Icon(
              org.isPersonal ? Icons.person_rounded : Icons.business_rounded,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: NexusSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  org.isPersonal ? l10n.orgPersonalWorkspace : org.name,
                  style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.orgPlanLine(
                    org.plan.toUpperCase(),
                    org.memberCount,
                    org.role.localized(l10n).toLowerCase(),
                  ),
                  style: TextStyle(color: t.textMuted, fontSize: 12.5),
                ),
              ],
            ),
          ),
          if (onRename != null && !org.isPersonal)
            IconButton(
              tooltip: l10n.orgRenameTooltip,
              icon: Icon(Icons.edit_outlined, size: 18, color: t.textSecondary),
              onPressed: onRename,
            ),
        ],
      ),
    );
  }
}

class _MembersSection extends StatelessWidget {
  const _MembersSection({
    required this.members,
    required this.org,
    required this.meId,
    required this.onInvite,
    required this.onSetRole,
    required this.onRemove,
    required this.onRetry,
  });

  final AsyncValue<List<OrgMember>> members;
  final Org org;
  final String? meId;
  final VoidCallback? onInvite;
  final void Function(OrgMember, OrgRole)? onSetRole;
  final void Function(OrgMember, {required bool self}) onRemove;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return _Section(
      label: l10n.sectionMembers,
      children: [
        members.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(NexusSpacing.lg),
            child: Skeleton(height: 16),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(NexusSpacing.lg),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.describeError(e),
                    style: TextStyle(color: t.textSecondary, fontSize: 13),
                  ),
                ),
                TextButton(onPressed: onRetry, child: Text(l10n.commonRetry)),
              ],
            ),
          ),
          data: (list) => Column(
            children: [
              for (final m in list) ...[
                _MemberTile(
                  member: m,
                  isMe: m.userId == meId,
                  canManage: onSetRole != null,
                  // The owner can never be removed; a member may leave unless
                  // it is their personal workspace.
                  onSetRole:
                      onSetRole == null || m.role == OrgRole.owner ? null : (r) => onSetRole!(m, r),
                  onRemove: m.role == OrgRole.owner || org.isPersonal
                      ? null
                      : (m.userId == meId || onSetRole != null)
                          ? () => onRemove(m, self: m.userId == meId)
                          : null,
                ),
                if (m != list.last) const _Divider(),
              ],
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(NexusSpacing.lg),
                  child:
                      Text(l10n.orgNoMembers, style: TextStyle(color: t.textMuted, fontSize: 13)),
                ),
              if (onInvite == null)
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(
                    NexusSpacing.lg,
                    NexusSpacing.sm,
                    NexusSpacing.lg,
                    NexusSpacing.md,
                  ),
                  child: Text(
                    l10n.orgInviteOnlyAdmins,
                    style: TextStyle(color: t.textMuted, fontSize: 11.5),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.isMe,
    required this.canManage,
    required this.onSetRole,
    required this.onRemove,
  });

  final OrgMember member;
  final bool isMe;
  final bool canManage;
  final ValueChanged<OrgRole>? onSetRole;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final m = member;
    final hasMenu = onSetRole != null || onRemove != null;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: 2),
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: NexusColors.crimson.withValues(alpha: 0.15),
        child: Text(
          m.email.isEmpty ? '?' : m.email.substring(0, 1).toUpperCase(),
          style: const TextStyle(color: NexusColors.crimson, fontWeight: FontWeight.w800),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              m.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w700, fontSize: 14),
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: 6),
            Text(l10n.orgYou, style: TextStyle(color: t.textMuted, fontSize: 12)),
          ],
          const SizedBox(width: NexusSpacing.sm),
          RoleChip(role: m.role),
        ],
      ),
      subtitle: m.fullName?.isNotEmpty == true
          ? Text(m.email, style: TextStyle(color: t.textMuted, fontSize: 12))
          : null,
      trailing: hasMenu
          ? PopupMenuButton<String>(
              tooltip: l10n.commonMore,
              icon: Icon(Icons.more_horiz_rounded, size: 18, color: t.textMuted),
              onSelected: (v) {
                if (v == 'admin') onSetRole?.call(OrgRole.admin);
                if (v == 'member') onSetRole?.call(OrgRole.member);
                if (v == 'remove') onRemove?.call();
              },
              itemBuilder: (_) => [
                if (onSetRole != null && m.role != OrgRole.admin)
                  PopupMenuItem(value: 'admin', child: Text(l10n.orgMakeAdmin)),
                if (onSetRole != null && m.role != OrgRole.member)
                  PopupMenuItem(value: 'member', child: Text(l10n.orgMakeMember)),
                if (onRemove != null)
                  PopupMenuItem(
                    value: 'remove',
                    child: Text(isMe ? l10n.orgLeaveWorkspace : l10n.commonRemove),
                  ),
              ],
            )
          : null,
    );
  }
}

/// `OWNER` / `ADMIN` / `MEMBER` pill.
class RoleChip extends StatelessWidget {
  const RoleChip({super.key, required this.role});
  final OrgRole role;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = switch (role) {
      OrgRole.owner => NexusColors.crimson,
      OrgRole.admin => NexusColors.warn,
      OrgRole.member => t.textMuted,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        role.localized(context.l10n).toUpperCase(),
        style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Dialogs
// ────────────────────────────────────────────────────────────────────────────

class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.title, required this.hint, this.initial = ''});
  final String title;
  final String hint;
  final String initial;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_ctrl.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}

/// Monthly budgets; an empty field means "no limit" (sent as null).
class _BudgetDialog extends StatefulWidget {
  const _BudgetDialog({required this.settings});
  final OrgSettings settings;

  @override
  State<_BudgetDialog> createState() => _BudgetDialogState();
}

class _BudgetDialogState extends State<_BudgetDialog> {
  late final TextEditingController _usd = TextEditingController(
    text: widget.settings.budgetUsdPerMonth?.toString() ?? '',
  );
  late final TextEditingController _tokens = TextEditingController(
    text: widget.settings.budgetTokensPerMonth?.toString() ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _usd.dispose();
    _tokens.dispose();
    super.dispose();
  }

  void _submit() {
    final usdText = _usd.text.trim();
    final tokensText = _tokens.text.trim();
    final usd = usdText.isEmpty ? null : double.tryParse(usdText);
    final tokens = tokensText.isEmpty ? null : int.tryParse(tokensText);
    if ((usdText.isNotEmpty && (usd == null || usd < 0)) ||
        (tokensText.isNotEmpty && (tokens == null || tokens < 0))) {
      setState(() => _error = context.l10n.orgBudgetInvalid);
      return;
    }
    Navigator.of(context).pop(
      widget.settings.copyWith(
        budgetUsdPerMonth: usd,
        clearBudgetUsd: usd == null,
        budgetTokensPerMonth: tokens,
        clearBudgetTokens: tokens == null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return AlertDialog(
      title: Text(l10n.orgMonthlyBudget),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.orgBudgetBody, style: TextStyle(color: t.textSecondary, fontSize: 13)),
          const SizedBox(height: NexusSpacing.md),
          TextField(
            controller: _usd,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(hintText: l10n.orgSpendingUsdHint, prefixText: '\$ '),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: NexusSpacing.md),
          TextField(
            controller: _tokens,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              hintText: l10n.orgTokensHint,
              errorText: _error,
              errorMaxLines: 2,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}

class _AllowedModelsResult {
  const _AllowedModelsResult(this.ids);

  /// Null = every model.
  final List<String>? ids;
}

class _AllowedModelsDialog extends StatefulWidget {
  const _AllowedModelsDialog({required this.catalog, required this.allowed});
  final ModelCatalog catalog;
  final List<String>? allowed;

  @override
  State<_AllowedModelsDialog> createState() => _AllowedModelsDialogState();
}

class _AllowedModelsDialogState extends State<_AllowedModelsDialog> {
  late bool _all = widget.allowed == null;
  late final Set<String> _checked = (widget.allowed ?? const []).toSet();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return AlertDialog(
      title: Text(l10n.orgAllowedModels),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            SwitchListTile(
              value: _all,
              onChanged: (v) => setState(() => _all = v),
              activeTrackColor: NexusColors.crimson,
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.orgAllModels, style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                l10n.orgAllModelsSubtitle,
                style: TextStyle(color: t.textMuted, fontSize: 12),
              ),
            ),
            Divider(color: t.borderSubtle, height: 1),
            for (final m in widget.catalog.items)
              CheckboxListTile(
                value: !_all && _checked.contains(m.id),
                onChanged: _all
                    ? null
                    : (v) => setState(() {
                          if (v == true) {
                            _checked.add(m.id);
                          } else {
                            _checked.remove(m.id);
                          }
                        }),
                activeColor: NexusColors.crimson,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: Text(m.displayName, style: const TextStyle(fontSize: 14)),
                subtitle: Text(m.provider, style: TextStyle(color: t.textMuted, fontSize: 12)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _AllowedModelsResult(_all ? null : _checked.toList()),
          ),
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}

class _InviteResult {
  const _InviteResult(this.member);
  final OrgMember member;
}

/// Invite by email (`POST /orgs/{id}/members`). Performs the request itself
/// so 404 ("no such user") and 409 ("already a member") show inline.
class _InviteDialog extends ConsumerStatefulWidget {
  const _InviteDialog({required this.orgId});
  final String orgId;

  @override
  ConsumerState<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends ConsumerState<_InviteDialog> {
  final _email = TextEditingController();
  OrgRole _role = OrgRole.member;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = l10n.orgInviteEmailRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(orgsRepositoryProvider.future);
      final member = await repo.addMember(widget.orgId, email: email, role: _role);
      if (!mounted) return;
      Navigator.of(context).pop(_InviteResult(member));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.isNotFound
            ? l10n.orgInviteNotFound
            : e.isConflict
                ? l10n.orgInviteConflict
                : context.describeError(e);
      });
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
      title: Text(l10n.orgInviteTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.orgInviteBody, style: TextStyle(color: t.textSecondary, fontSize: 13)),
          const SizedBox(height: NexusSpacing.md),
          TextField(
            controller: _email,
            autofocus: true,
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: l10n.orgInviteEmailHint,
              prefixIcon: const Icon(Icons.mail_outline_rounded, size: 20),
              errorText: _error,
              errorMaxLines: 3,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: NexusSpacing.md),
          InputDecorator(
            decoration: InputDecoration(labelText: l10n.orgRole),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<OrgRole>(
                isExpanded: true,
                isDense: true,
                value: _role,
                items: [
                  DropdownMenuItem(value: OrgRole.member, child: Text(l10n.roleMember)),
                  DropdownMenuItem(value: OrgRole.admin, child: Text(l10n.roleAdmin)),
                ],
                onChanged: _busy ? null : (v) => setState(() => _role = v ?? OrgRole.member),
              ),
            ),
          ),
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
              : const Icon(Icons.person_add_alt_1_rounded, size: 16),
          label: Text(_busy ? l10n.orgInviting : l10n.orgInvite),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Primitives (mirror the Settings screen's look)
// ────────────────────────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  const _Section({required this.label, required this.children});
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 4, bottom: NexusSpacing.sm),
          child: Text(
            label,
            style: TextStyle(
              color: t.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 3,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: t.surfaceHigh,
            borderRadius: const BorderRadius.all(NexusRadius.lg),
            border: Border.all(color: t.border),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) {
    return Divider(color: context.tokens.borderSubtle, height: 1, indent: 56);
  }
}

class _ValueTile extends StatelessWidget {
  const _ValueTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;

  /// Null renders the row read-only (no chevron).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: 2),
      leading: Icon(icon, color: NexusColors.crimson, size: 20),
      title: Text(title, style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w700)),
      subtitle: Text(value, style: TextStyle(color: t.textMuted, fontSize: 12)),
      trailing: onTap == null ? null : Icon(Icons.chevron_right_rounded, color: t.textMuted),
      onTap: onTap,
    );
  }
}
