import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/preferences.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../l10n/labels.dart';
import '../auth/auth_providers.dart';
import 'org_model.dart';
import 'orgs_repository.dart';

/// Sidebar header control: the active workspace's name with a menu to switch
/// to another organization, create one, or open the workspace settings.
///
/// Switching stores the choice for the signed-in user; every org-scoped
/// provider watches `activeOrgIdProvider` and reloads, and the app goes back
/// to `/` so no chat of the previous workspace stays open.
class OrgSwitcher extends ConsumerStatefulWidget {
  const OrgSwitcher({super.key, this.onNavigated});

  /// Called after any navigation (closes the drawer on mobile).
  final VoidCallback? onNavigated;

  @override
  ConsumerState<OrgSwitcher> createState() => _OrgSwitcherState();
}

class _OrgSwitcherState extends ConsumerState<OrgSwitcher> {
  static const _create = '\u0000create';
  static const _settings = '\u0000settings';

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _switchTo(Org org) async {
    final user = ref.read(currentUserProvider).valueOrNull;
    if (user == null) return;
    final current = ref.read(activeOrgProvider).valueOrNull;
    if (current?.id == org.id) return;
    await selectActiveOrg(ref.read(prefsProvider.notifier), user: user, org: org);
    if (!mounted) return;
    context.go(AppRoutes.home);
    widget.onNavigated?.call();
  }

  Future<void> _createOrg() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _CreateOrgDialog(),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final repo = await ref.read(orgsRepositoryProvider.future);
      final org = await repo.create(name);
      ref.invalidate(orgListProvider);
      if (!mounted) return;
      await _switchTo(org);
    } catch (e) {
      if (mounted) _toast(context.describeError(e));
    }
  }

  void _openSettings(Org org) {
    context.go(AppRoutes.orgSettings(org.id));
    widget.onNavigated?.call();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final orgs = ref.watch(orgListProvider).valueOrNull ?? const <Org>[];
    final active = ref.watch(activeOrgProvider).valueOrNull;
    final label = active == null
        ? l10n.orgWorkspace
        : active.isPersonal
            ? l10n.orgPersonal
            : active.name;
    final caption = active == null
        ? l10n.commonLoading
        : active.isPersonal
            ? l10n.orgYourWorkspace
            : l10n.orgRoleMembers(active.role.localized(l10n), active.memberCount);

    return PopupMenuButton<String>(
      tooltip: l10n.orgSwitchTooltip,
      onSelected: (v) {
        if (v == _create) {
          _createOrg();
        } else if (v == _settings) {
          if (active != null) _openSettings(active);
        } else {
          final org = orgs.where((o) => o.id == v).firstOrNull;
          if (org != null) _switchTo(org);
        }
      },
      itemBuilder: (_) => [
        for (final org in orgs)
          PopupMenuItem(
            value: org.id,
            child: _OrgRow(org: org, selected: org.id == active?.id),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _create,
          child: Row(
            children: [
              const Icon(Icons.add_rounded, size: 16),
              const SizedBox(width: NexusSpacing.sm),
              Text(l10n.orgCreateOrganization),
            ],
          ),
        ),
        if (active != null && active.canManage)
          PopupMenuItem(
            value: _settings,
            child: Row(
              children: [
                const Icon(Icons.manage_accounts_rounded, size: 16),
                const SizedBox(width: NexusSpacing.sm),
                Text(l10n.orgWorkspaceSettings),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.md, vertical: NexusSpacing.sm),
        decoration: BoxDecoration(
          color: t.surfaceHigh,
          borderRadius: const BorderRadius.all(NexusRadius.md),
          border: Border.all(color: t.border),
        ),
        child: Row(
          children: [
            Icon(
              active?.isPersonal == false ? Icons.business_rounded : Icons.person_rounded,
              size: 16,
              color: NexusColors.crimson,
            ),
            const SizedBox(width: NexusSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.textMuted, fontSize: 10.5),
                  ),
                ],
              ),
            ),
            Icon(Icons.unfold_more_rounded, color: t.textMuted, size: 16),
          ],
        ),
      ),
    );
  }
}

class _OrgRow extends StatelessWidget {
  const _OrgRow({required this.org, required this.selected});
  final Org org;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
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
                org.isPersonal ? l10n.orgPersonal : org.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
              Text(
                org.isPersonal ? l10n.orgYourWorkspace : org.role.localized(l10n),
                style: TextStyle(color: t.textMuted, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Name prompt for `POST /orgs`. Owns its controller so it is disposed only
/// after the dialog's exit animation.
class _CreateOrgDialog extends StatefulWidget {
  const _CreateOrgDialog();

  @override
  State<_CreateOrgDialog> createState() => _CreateOrgDialogState();
}

class _CreateOrgDialogState extends State<_CreateOrgDialog> {
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = context.l10n.orgNameRequired);
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return AlertDialog(
      title: Text(l10n.orgNewOrganizationTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.orgNewOrganizationBody,
            style: TextStyle(color: t.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: NexusSpacing.md),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(hintText: l10n.orgNameHint, errorText: _error),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: Text(l10n.commonCreate),
        ),
      ],
    );
  }
}
