import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/breakpoints.dart';
import '../../core/env.dart';
import '../../core/preferences.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../shared/home_shell.dart';
import '../auth/auth_providers.dart';
import '../auth/auth_repository.dart';
import '../chat/chat_repository.dart';

const _availableModels = [
  ('gpt-4o-mini', 'GPT-4o mini', 'Fast · cheap · default'),
  ('gpt-4o', 'GPT-4o', 'High quality · slower'),
  ('gpt-4-turbo', 'GPT-4 Turbo', 'Reasoning · long context'),
];

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Account actions ──────────────────────────────────────────────────

  Future<void> _editDisplayName(BuildContext context, WidgetRef ref, String? current) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: 'Display name',
        hint: 'Your name',
        initial: current ?? '',
        confirmLabel: 'Save',
      ),
    );
    if (name == null || !context.mounted) return;
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.updateProfile(fullName: name.trim());
      ref.invalidate(currentUserProvider);
      if (context.mounted) _toast(context, 'Display name updated');
    } catch (e) {
      if (context.mounted) _toast(context, errorText(e));
    }
  }

  Future<void> _changePassword(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<({String current, String next})>(
      context: context,
      builder: (_) => const _ChangePasswordDialog(),
    );
    if (result == null || !context.mounted) return;
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.changePassword(currentPassword: result.current, newPassword: result.next);
      if (context.mounted) {
        _toast(context, 'Password changed. Other devices have been signed out.');
      }
    } catch (e) {
      if (context.mounted) _toast(context, errorText(e));
    }
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final repo = await ref.read(authRepositoryProvider.future);
    await repo.logout();
    ref.invalidate(currentUserProvider);
    if (!context.mounted) return;
    context.go(AppRoutes.login);
  }

  Future<void> _logoutEverywhere(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => const _ConfirmDialog(
        title: 'Sign out everywhere?',
        message: 'Every device signed in to this account will have to sign in again.',
        confirmLabel: 'Sign out everywhere',
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.logoutAll();
      ref.invalidate(currentUserProvider);
      if (!context.mounted) return;
      context.go(AppRoutes.login);
    } catch (e) {
      if (context.mounted) _toast(context, errorText(e));
    }
  }

  Future<void> _clearAllChats(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => const _ConfirmDialog(
        title: 'Delete all chats?',
        message: 'This deletes every chat session for your account. Documents are preserved.',
        confirmLabel: 'Delete all',
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final repo = await ref.read(chatRepositoryProvider.future);
      final sessions = await repo.listSessions();
      for (final s in sessions) {
        await repo.deleteSession(s.id);
      }
      ref.invalidate(sessionListProvider);
      if (context.mounted) _toast(context, 'Deleted ${sessions.length} chats');
    } catch (e) {
      if (context.mounted) _toast(context, errorText(e));
    }
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _TextPromptDialog(
        title: 'Delete account?',
        message: 'Your account, chats and documents will be removed. '
            'This can’t be undone. Enter your password to confirm.',
        hint: 'Password',
        obscure: true,
        confirmLabel: 'Delete account',
        danger: true,
      ),
    );
    if (password == null || password.isEmpty || !context.mounted) return;
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.deleteAccount(password: password);
      ref.invalidate(currentUserProvider);
      if (!context.mounted) return;
      context.go(AppRoutes.login);
    } catch (e) {
      if (context.mounted) _toast(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final user = ref.watch(currentUserProvider);
    final prefs = ref.watch(prefsProvider);
    final prefsCtrl = ref.read(prefsProvider.notifier);
    final displayName = user.value?.fullName;

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text('Settings', style: TextStyle(color: t.textPrimary)),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(NexusSpacing.lg),
            children: [
              // ── Profile card ───────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(NexusSpacing.lg),
                decoration: BoxDecoration(
                  color: t.surfaceHigh,
                  borderRadius: const BorderRadius.all(NexusRadius.lg),
                  border: Border.all(color: t.border),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: const BoxDecoration(
                        gradient: NexusColors.redGradient,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        user.value?.email.substring(0, 1).toUpperCase() ?? '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: NexusSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName?.isNotEmpty == true ? displayName! : 'Signed in',
                            style: TextStyle(
                              color: t.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            user.value?.email ?? '—',
                            style: TextStyle(color: t.textMuted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: NexusSpacing.xl),
              _Section(
                label: 'APPEARANCE',
                children: [
                  _ThemeRow(value: prefs.themeMode, onChanged: prefsCtrl.setThemeMode),
                ],
              ),

              const SizedBox(height: NexusSpacing.xl),
              _Section(
                label: 'CHAT',
                children: [
                  _SwitchTile(
                    icon: Icons.stream_rounded,
                    title: 'Stream responses',
                    subtitle: 'Token-by-token delivery. Off = wait for full reply.',
                    value: prefs.streamingEnabled,
                    onChanged: prefsCtrl.setStreaming,
                  ),
                  const _Divider(),
                  _SwitchTile(
                    icon: Icons.menu_book_rounded,
                    title: 'Use RAG by default',
                    subtitle: 'Ground replies in your uploaded documents.',
                    value: prefs.ragByDefault,
                    onChanged: prefsCtrl.setRag,
                  ),
                  const _Divider(),
                  _SwitchTile(
                    icon: Icons.build_rounded,
                    title: 'Use tools by default',
                    subtitle: 'Let the agent call tools (calculator, search, …) in new chats.',
                    value: prefs.toolsByDefault,
                    onChanged: prefsCtrl.setTools,
                  ),
                  const _Divider(),
                  _ChoiceTile<StreamTransport>(
                    icon: Icons.swap_horiz_rounded,
                    title: 'Stream transport',
                    value: prefs.transport,
                    onChanged: prefsCtrl.setTransport,
                    options: const [
                      ('Server-Sent Events', StreamTransport.sse),
                      ('WebSocket', StreamTransport.websocket),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: NexusSpacing.xl),
              _Section(
                label: 'MODEL',
                children: [
                  for (final m in _availableModels) ...[
                    _ModelTile(
                      id: m.$1,
                      name: m.$2,
                      description: m.$3,
                      selected: prefs.model == m.$1,
                      onTap: () => prefsCtrl.setModel(m.$1),
                    ),
                    if (m != _availableModels.last) const _Divider(),
                  ],
                ],
              ),

              const SizedBox(height: NexusSpacing.xl),
              const _Section(
                label: 'CONNECTION',
                children: [
                  _InfoRow(icon: Icons.cloud_outlined, label: 'API base URL', value: Env.apiBaseUrl),
                ],
              ),

              const SizedBox(height: NexusSpacing.xl),
              _Section(
                label: 'ACCOUNT',
                children: [
                  _ActionTile(
                    icon: Icons.person_outline_rounded,
                    title: 'Display name',
                    subtitle: displayName?.isNotEmpty == true ? displayName! : 'Not set',
                    onTap: () => _editDisplayName(context, ref, displayName),
                  ),
                  const _Divider(),
                  _ActionTile(
                    icon: Icons.password_rounded,
                    title: 'Change password',
                    subtitle: 'Signs out every other device.',
                    onTap: () => _changePassword(context, ref),
                  ),
                  const _Divider(),
                  _ActionTile(
                    icon: Icons.delete_sweep_rounded,
                    title: 'Clear all chats',
                    subtitle: 'Remove every chat session.',
                    onTap: () => _clearAllChats(context, ref),
                    danger: true,
                  ),
                  const _Divider(),
                  _ActionTile(
                    icon: Icons.logout_rounded,
                    title: 'Sign out',
                    subtitle: user.value?.email ?? '',
                    onTap: () => _logout(context, ref),
                    danger: true,
                  ),
                  const _Divider(),
                  _ActionTile(
                    icon: Icons.devices_other_rounded,
                    title: 'Sign out everywhere',
                    subtitle: 'Revoke every signed-in device.',
                    onTap: () => _logoutEverywhere(context, ref),
                    danger: true,
                  ),
                  const _Divider(),
                  _ActionTile(
                    icon: Icons.delete_forever_rounded,
                    title: 'Delete account',
                    subtitle: 'Permanently remove your account and data.',
                    onTap: () => _deleteAccount(context, ref),
                    danger: true,
                  ),
                ],
              ),

              const SizedBox(height: NexusSpacing.xxxl),
              Center(
                child: Text(
                  'NexusBot v1.0.0 · FastAPI · LangChain · Flutter',
                  style: TextStyle(color: t.textMuted, fontSize: 11),
                ),
              ),
              const SizedBox(height: NexusSpacing.xxxl),
            ],
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Dialogs
// ────────────────────────────────────────────────────────────────────────────

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}

/// Single-field prompt. Owns its controller so it is disposed only after the
/// dialog's exit animation (see `_RenameDialog` in the sidebar).
class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.hint,
    required this.confirmLabel,
    this.message,
    this.initial = '',
    this.obscure = false,
    this.danger = false,
  });

  final String title;
  final String? message;
  final String hint;
  final String initial;
  final bool obscure;
  final String confirmLabel;
  final bool danger;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_ctrl.text);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message != null) ...[
            Text(widget.message!, style: TextStyle(color: t.textSecondary, fontSize: 13)),
            const SizedBox(height: NexusSpacing.md),
          ],
          TextField(
            controller: _ctrl,
            autofocus: true,
            obscureText: widget.obscure,
            decoration: InputDecoration(hintText: widget.hint),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            backgroundColor: widget.danger ? NexusColors.crimson : null,
          ),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop((current: _current.text, next: _next.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change password'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _current,
              autofocus: true,
              obscureText: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(hintText: 'Current password'),
              validator: (v) => (v ?? '').isEmpty ? 'Enter your current password' : null,
            ),
            const SizedBox(height: NexusSpacing.md),
            TextFormField(
              controller: _next,
              obscureText: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(hintText: 'New password (min 8 chars)'),
              validator: (v) =>
                  (v ?? '').length < 8 ? 'Password must be at least 8 characters' : null,
            ),
            const SizedBox(height: NexusSpacing.md),
            TextFormField(
              controller: _confirm,
              obscureText: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(hintText: 'Repeat new password'),
              onFieldSubmitted: (_) => _submit(),
              validator: (v) => v != _next.text ? 'Passwords don’t match' : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: const Text('Change password'),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Settings primitives
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
          padding: const EdgeInsets.only(left: 4, bottom: NexusSpacing.sm),
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

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: 4),
      leading: Icon(icon, color: NexusColors.crimson, size: 20),
      title: Text(title, style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle, style: TextStyle(color: t.textMuted, fontSize: 12)),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? NexusColors.crimson : null,
        ),
      ),
      onTap: () => onChanged(!value),
    );
  }
}

class _ChoiceTile<T> extends StatelessWidget {
  const _ChoiceTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    required this.options,
  });

  final IconData icon;
  final String title;
  final T value;
  final ValueChanged<T> onChanged;
  final List<(String label, T value)> options;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: 4),
      leading: Icon(icon, color: NexusColors.crimson, size: 20),
      title: Text(title, style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w700)),
      trailing: DropdownButton<T>(
        value: value,
        underline: const SizedBox.shrink(),
        items: options.map((o) => DropdownMenuItem(value: o.$2, child: Text(o.$1))).toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.id,
    required this.name,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final String id;
  final String name;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? NexusColors.crimson : t.border,
                    width: 2,
                  ),
                ),
                child: selected
                    ? Center(
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: NexusColors.crimson,
                            shape: BoxShape.circle,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: NexusSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        color: t.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    Text(description, style: TextStyle(color: t.textMuted, fontSize: 12)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: t.surfaceHigher,
                  borderRadius: const BorderRadius.all(NexusRadius.pill),
                ),
                child: Text(
                  id,
                  style: TextStyle(
                    color: t.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: 14),
      child: Row(
        children: [
          Icon(icon, color: NexusColors.crimson, size: 20),
          const SizedBox(width: NexusSpacing.md),
          Expanded(child: Text(label, style: TextStyle(color: t.textSecondary, fontSize: 13))),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = danger ? NexusColors.crimson : t.textPrimary;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: 4),
      leading: Icon(icon, color: color, size: 20),
      title: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, style: TextStyle(color: t.textMuted, fontSize: 12)),
      trailing: Icon(Icons.chevron_right_rounded, color: t.textMuted, size: 20),
      onTap: onTap,
    );
  }
}

class _ThemeRow extends StatelessWidget {
  const _ThemeRow({required this.value, required this.onChanged});
  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    const options = [
      (Icons.brightness_auto_rounded, 'System', ThemeMode.system),
      (Icons.light_mode_rounded, 'Light', ThemeMode.light),
      (Icons.dark_mode_rounded, 'Dark', ThemeMode.dark),
    ];
    return Padding(
      padding: const EdgeInsets.all(NexusSpacing.md),
      child: Row(
        children: options.map((opt) {
          final selected = value == opt.$3;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => onChanged(opt.$3),
                  borderRadius: const BorderRadius.all(NexusRadius.md),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: selected ? NexusColors.crimson.withValues(alpha: 0.12) : t.surfaceHigher,
                      borderRadius: const BorderRadius.all(NexusRadius.md),
                      border: Border.all(
                        color: selected ? NexusColors.crimson : Colors.transparent,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(opt.$1, size: 18, color: selected ? NexusColors.crimson : t.textSecondary),
                        const SizedBox(height: 6),
                        Text(
                          opt.$2,
                          style: TextStyle(
                            color: selected ? t.textPrimary : t.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
