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
import '../models/model_info.dart';
import '../models/models_repository.dart';
import '../orgs/orgs_repository.dart';
import '../usage/usage_repository.dart';
import '../usage/usage_widgets.dart';
import '../voice/voice_repository.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Model ────────────────────────────────────────────────────────────

  /// Sets the default model: locally (so new chats send it right away) and
  /// on the account (`PATCH /auth/me {default_model}`) so every device agrees.
  Future<void> _selectModel(BuildContext context, WidgetRef ref, String modelId) async {
    final prefsCtrl = ref.read(prefsProvider.notifier);
    final previous = ref.read(prefsProvider).model;
    await prefsCtrl.setModel(modelId);
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.setDefaultModel(modelId);
      ref.invalidate(currentUserProvider);
    } catch (e) {
      // The account default still wins the resolution — put the local
      // preference back so the list reflects what the server will use.
      await prefsCtrl.setModel(previous);
      if (context.mounted) _toast(context, 'Could not save the default model: ${errorText(e)}');
    }
  }

  Future<void> _refreshModels(WidgetRef ref) async {
    ref.invalidate(modelCatalogProvider);
    ref.invalidate(usageMeProvider);
    try {
      await ref.read(modelCatalogProvider.future);
    } catch (_) {
      // The section shows the error with a retry button.
    }
  }

  // ── Memory ───────────────────────────────────────────────────────────

  /// `PATCH /auth/me {memory_enabled}`.
  Future<void> _setMemoryEnabled(BuildContext context, WidgetRef ref, bool enabled) async {
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.setMemoryEnabled(enabled);
      ref.invalidate(currentUserProvider);
    } catch (e) {
      if (context.mounted) _toast(context, 'Could not update memory: ${errorText(e)}');
    }
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
    final catalog = ref.watch(modelCatalogProvider);
    final defaultModelId = ref.watch(defaultModelIdProvider);
    final usage = ref.watch(usageMeProvider);
    final org = ref.watch(activeOrgProvider).valueOrNull;
    final memoryEnabled = user.value?.memoryEnabled ?? true;
    final isServerAdmin = user.value?.isServerAdmin ?? false;
    final voice = ref.watch(voiceCapabilitiesProvider).valueOrNull;
    // A voice that is no longer offered falls back to the server default.
    final voiceIds = {for (final v in voice?.voices ?? const []) v.id};
    final selectedVoice = voiceIds.contains(prefs.voice) ? prefs.voice! : '';

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text('Settings', style: TextStyle(color: t.textPrimary)),
      ),
      body: RefreshIndicator(
        color: NexusColors.crimson,
        backgroundColor: t.surfaceHigh,
        onRefresh: () => _refreshModels(ref),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
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
                  label: 'WORKSPACE',
                  children: [
                    _InfoRow(
                      icon:
                          org?.isPersonal == false ? Icons.business_rounded : Icons.person_rounded,
                      label: 'Active workspace',
                      value: org == null
                          ? '—'
                          : org.isPersonal
                              ? 'Personal'
                              : '${org.name} · ${org.role.label}',
                    ),
                    if (org != null && org.canManage) ...[
                      const _Divider(),
                      _ActionTile(
                        icon: Icons.manage_accounts_rounded,
                        title: 'Manage workspace',
                        subtitle: 'Name, budgets, allowed models, members.',
                        onTap: () => context.go(AppRoutes.orgSettings(org.id)),
                      ),
                      const _Divider(),
                      _ActionTile(
                        icon: Icons.bar_chart_rounded,
                        title: 'Usage report',
                        subtitle: 'Tokens, cost and messages by member, model or day.',
                        onTap: () => context.go(AppRoutes.orgUsage(org.id)),
                      ),
                    ],
                    const _Divider(),
                    _ActionTile(
                      icon: Icons.smart_toy_outlined,
                      title: 'Assistants',
                      subtitle: 'Personas to start chats with.',
                      onTap: () => context.go(AppRoutes.assistants),
                    ),
                  ],
                ),

                const SizedBox(height: NexusSpacing.xl),
                _Section(
                  label: 'USAGE',
                  children: [
                    usage.when(
                      loading: () => const _ModelsPlaceholder(
                        icon: Icons.hourglass_empty_rounded,
                        text: 'Loading usage…',
                      ),
                      error: (e, _) => _ModelsPlaceholder(
                        icon: Icons.cloud_off_rounded,
                        text: 'Could not load usage: ${errorText(e)}',
                        action: TextButton(
                          onPressed: () => ref.invalidate(usageMeProvider),
                          child: const Text('Retry'),
                        ),
                      ),
                      data: (summary) => UsageSummaryView(summary: summary),
                    ),
                  ],
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
                    _SwitchTile(
                      icon: Icons.psychology_outlined,
                      title: 'Memory',
                      subtitle: 'Remember facts and preferences from chats and use them later.',
                      value: memoryEnabled,
                      onChanged: (v) => _setMemoryEnabled(context, ref, v),
                    ),
                    const _Divider(),
                    _ActionTile(
                      icon: Icons.list_alt_rounded,
                      title: 'What NexusBot remembers',
                      subtitle: 'Review, edit or forget memories.',
                      onTap: () => context.go(AppRoutes.memory),
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

                if (voice != null && voice.ttsAvailable) ...[
                  const SizedBox(height: NexusSpacing.xl),
                  _Section(
                    label: 'VOICE',
                    children: [
                      _SwitchTile(
                        icon: Icons.volume_up_rounded,
                        title: 'Speak replies',
                        subtitle: 'Read every reply aloud as it arrives '
                            '(text-to-speech by ${voice.provider}).',
                        value: prefs.speakReplies,
                        onChanged: prefsCtrl.setSpeakReplies,
                      ),
                      if (voice.voices.isNotEmpty) ...[
                        const _Divider(),
                        _ChoiceTile<String>(
                          icon: Icons.record_voice_over_rounded,
                          title: 'Voice',
                          value: selectedVoice,
                          onChanged: (v) => prefsCtrl.setVoice(v.isEmpty ? null : v),
                          options: [
                            ('Server default', ''),
                            for (final v in voice.voices) (v.name, v.id),
                          ],
                        ),
                      ],
                      if (voice.sttAvailable) ...[
                        const _Divider(),
                        const _InfoRow(
                          icon: Icons.mic_rounded,
                          label: 'Voice input',
                          value: 'Hold the microphone in a chat',
                        ),
                      ],
                    ],
                  ),
                ],

                const SizedBox(height: NexusSpacing.xl),
                _Section(
                  label: 'MODEL',
                  children: [
                    catalog.when(
                      loading: () => const _ModelsPlaceholder(
                        icon: Icons.hourglass_empty_rounded,
                        text: 'Loading models from the server…',
                      ),
                      error: (e, _) => _ModelsPlaceholder(
                        icon: Icons.cloud_off_rounded,
                        text: 'Could not load models: ${errorText(e)}',
                        action: TextButton(
                          onPressed: () => _refreshModels(ref),
                          child: const Text('Retry'),
                        ),
                      ),
                      data: (c) {
                        if (c.isEmpty) {
                          return const _ModelsPlaceholder(
                            icon: Icons.memory_rounded,
                            text: 'No model providers are configured on this server.',
                          );
                        }
                        return Column(
                          children: [
                            for (final m in c.items) ...[
                              _ModelTile(
                                model: m,
                                selected: m.id == defaultModelId,
                                onTap: () => _selectModel(context, ref, m.id),
                              ),
                              if (m != c.items.last) const _Divider(),
                            ],
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                NexusSpacing.lg,
                                NexusSpacing.sm,
                                NexusSpacing.lg,
                                NexusSpacing.md,
                              ),
                              child: Text(
                                'Used for new chats. Each chat can switch models from its '
                                'header, and the composer can override it per message. '
                                'Pull to refresh the list.',
                                style: TextStyle(color: t.textMuted, fontSize: 11.5),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),

                if (isServerAdmin) ...[
                  const SizedBox(height: NexusSpacing.xl),
                  _Section(
                    label: 'ADMINISTRATION',
                    children: [
                      _ActionTile(
                        icon: Icons.insights_rounded,
                        title: 'Server usage',
                        subtitle: 'Every workspace, by organization, user, model or day.',
                        onTap: () => context.go(AppRoutes.adminUsage),
                      ),
                      const _Divider(),
                      _ActionTile(
                        icon: Icons.thumbs_up_down_outlined,
                        title: 'Feedback',
                        subtitle: 'Thumbs up / down left on replies.',
                        onTap: () => context.go(AppRoutes.adminFeedback),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: NexusSpacing.xl),
                const _Section(
                  label: 'CONNECTION',
                  children: [
                    _InfoRow(
                      icon: Icons.cloud_outlined,
                      label: 'API base URL',
                      value: Env.apiBaseUrl,
                    ),
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
    required this.model,
    required this.selected,
    required this.onTap,
  });

  final ModelInfo model;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hints = <String>[
      if (model.contextLabel != null) model.contextLabel!,
      if (model.priceLabel != null) model.priceLabel!,
      if (!model.supportsTools) 'no tools',
      if (model.supportsVision) 'vision',
      ...model.tags,
    ];
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
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            model.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: t.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        const SizedBox(width: NexusSpacing.sm),
                        _ProviderBadge(provider: model.provider),
                      ],
                    ),
                    if (hints.isNotEmpty)
                      Text(
                        hints.join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.textMuted, fontSize: 12),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: NexusSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: t.surfaceHigher,
                  borderRadius: const BorderRadius.all(NexusRadius.pill),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(
                    model.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
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

/// `OPENAI` / `ANTHROPIC` / … pill next to a model name.
class _ProviderBadge extends StatelessWidget {
  const _ProviderBadge({required this.provider});
  final String provider;

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
        provider.toUpperCase(),
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

/// Loading / error / empty row for the MODEL section.
class _ModelsPlaceholder extends StatelessWidget {
  const _ModelsPlaceholder({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: 14),
      child: Row(
        children: [
          Icon(icon, color: NexusColors.crimson, size: 20),
          const SizedBox(width: NexusSpacing.md),
          Expanded(child: Text(text, style: TextStyle(color: t.textSecondary, fontSize: 13))),
          if (action != null) action!,
        ],
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
                      color:
                          selected ? NexusColors.crimson.withValues(alpha: 0.12) : t.surfaceHigher,
                      borderRadius: const BorderRadius.all(NexusRadius.md),
                      border: Border.all(
                        color: selected ? NexusColors.crimson : Colors.transparent,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          opt.$1,
                          size: 18,
                          color: selected ? NexusColors.crimson : t.textSecondary,
                        ),
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
