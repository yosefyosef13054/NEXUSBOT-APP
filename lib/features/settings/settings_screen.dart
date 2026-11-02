import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_info.dart';
import '../../core/biometric_auth.dart';
import '../../core/breakpoints.dart';
import '../../core/env.dart';
import '../../core/preferences.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../l10n/labels.dart';
import '../../shared/home_shell.dart';
import '../auth/auth_providers.dart';
import '../auth/auth_repository.dart';
import '../chat/chat_cache.dart';
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
      if (context.mounted) {
        _toast(context, context.l10n.settingsSaveModelFailed(context.describeError(e)));
      }
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
      if (context.mounted) {
        _toast(context, context.l10n.settingsMemoryUpdateFailed(context.describeError(e)));
      }
    }
  }

  // ── Security ─────────────────────────────────────────────────────────

  Future<void> _setBiometric(BuildContext context, WidgetRef ref, bool enabled) async {
    if (enabled) {
      final available = await ref.read(biometricAuthenticatorProvider).isAvailable();
      if (!available) {
        if (context.mounted) _toast(context, context.l10n.settingsBiometricUnavailable);
        return;
      }
    }
    await ref.read(prefsProvider.notifier).setBiometricUnlock(enabled);
  }

  Future<void> _clearCache(BuildContext context, WidgetRef ref) async {
    await ref.read(chatCacheProvider).clear();
    if (context.mounted) _toast(context, context.l10n.settingsCacheCleared);
  }

  // ── Account actions ──────────────────────────────────────────────────

  Future<void> _editDisplayName(BuildContext context, WidgetRef ref, String? current) async {
    final l10n = context.l10n;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: l10n.settingsDisplayName,
        hint: l10n.settingsYourName,
        initial: current ?? '',
        confirmLabel: l10n.commonSave,
      ),
    );
    if (name == null || !context.mounted) return;
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.updateProfile(fullName: name.trim());
      ref.invalidate(currentUserProvider);
      if (context.mounted) _toast(context, l10n.settingsDisplayNameUpdated);
    } catch (e) {
      if (context.mounted) _toast(context, context.describeError(e));
    }
  }

  Future<void> _changePassword(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final result = await showDialog<({String current, String next})>(
      context: context,
      builder: (_) => const _ChangePasswordDialog(),
    );
    if (result == null || !context.mounted) return;
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.changePassword(currentPassword: result.current, newPassword: result.next);
      if (context.mounted) _toast(context, l10n.settingsPasswordChanged);
    } catch (e) {
      if (context.mounted) _toast(context, context.describeError(e));
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
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ConfirmDialog(
        title: l10n.settingsSignOutEverywhereTitle,
        message: l10n.settingsSignOutEverywhereBody,
        confirmLabel: l10n.settingsSignOutEverywhere,
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
      if (context.mounted) _toast(context, context.describeError(e));
    }
  }

  Future<void> _clearAllChats(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ConfirmDialog(
        title: l10n.settingsDeleteAllChatsTitle,
        message: l10n.settingsDeleteAllChatsBody,
        confirmLabel: l10n.settingsDeleteAll,
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
      if (context.mounted) _toast(context, l10n.settingsDeletedChats(sessions.length));
    } catch (e) {
      if (context.mounted) _toast(context, context.describeError(e));
    }
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: l10n.settingsDeleteAccountTitle,
        message: l10n.settingsDeleteAccountBody,
        hint: l10n.authPasswordHint,
        obscure: true,
        confirmLabel: l10n.settingsDeleteAccount,
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
      if (context.mounted) _toast(context, context.describeError(e));
    }
  }

  void _showLicenses(BuildContext context, AppInfo info) {
    showLicensePage(
      context: context,
      applicationName: info.appName,
      applicationVersion: info.versionLabel,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
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
    final appInfo = ref.watch(appInfoProvider).valueOrNull ?? AppInfo.fallback;
    // A voice that is no longer offered falls back to the server default.
    final voiceIds = {for (final v in voice?.voices ?? const []) v.id};
    final selectedVoice = voiceIds.contains(prefs.voice) ? prefs.voice! : '';
    final language = AppLanguage.fromCode(prefs.languageCode);

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text(l10n.settingsTitle, style: TextStyle(color: t.textPrimary)),
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
                              displayName?.isNotEmpty == true
                                  ? displayName!
                                  : l10n.settingsSignedIn,
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
                  label: l10n.sectionWorkspace,
                  children: [
                    _InfoRow(
                      icon:
                          org?.isPersonal == false ? Icons.business_rounded : Icons.person_rounded,
                      label: l10n.settingsActiveWorkspace,
                      value: org == null
                          ? '—'
                          : org.isPersonal
                              ? l10n.orgPersonal
                              : l10n.settingsOrgRole(org.name, org.role.localized(l10n)),
                    ),
                    if (org != null && org.canManage) ...[
                      const _Divider(),
                      _ActionTile(
                        icon: Icons.manage_accounts_rounded,
                        title: l10n.settingsManageWorkspace,
                        subtitle: l10n.settingsManageWorkspaceSubtitle,
                        onTap: () => context.go(AppRoutes.orgSettings(org.id)),
                      ),
                      const _Divider(),
                      _ActionTile(
                        icon: Icons.bar_chart_rounded,
                        title: l10n.orgUsageReport,
                        subtitle: l10n.settingsUsageReportSubtitle,
                        onTap: () => context.go(AppRoutes.orgUsage(org.id)),
                      ),
                    ],
                    const _Divider(),
                    _ActionTile(
                      icon: Icons.smart_toy_outlined,
                      title: l10n.sidebarAssistants,
                      subtitle: l10n.settingsAssistantsSubtitle,
                      onTap: () => context.go(AppRoutes.assistants),
                    ),
                  ],
                ),

                const SizedBox(height: NexusSpacing.xl),
                _Section(
                  label: l10n.sectionUsage,
                  children: [
                    usage.when(
                      loading: () => _ModelsPlaceholder(
                        icon: Icons.hourglass_empty_rounded,
                        text: l10n.settingsLoadingUsage,
                      ),
                      error: (e, _) => _ModelsPlaceholder(
                        icon: Icons.cloud_off_rounded,
                        text: l10n.settingsUsageFailed(context.describeError(e)),
                        action: TextButton(
                          onPressed: () => ref.invalidate(usageMeProvider),
                          child: Text(l10n.commonRetry),
                        ),
                      ),
                      data: (summary) => UsageSummaryView(summary: summary),
                    ),
                  ],
                ),

                const SizedBox(height: NexusSpacing.xl),
                _Section(
                  label: l10n.sectionAppearance,
                  children: [
                    _ThemeRow(value: prefs.themeMode, onChanged: prefsCtrl.setThemeMode),
                    const _Divider(),
                    _ChoiceTile<AppLanguage>(
                      icon: Icons.translate_rounded,
                      title: l10n.settingsLanguage,
                      value: language,
                      onChanged: (v) => prefsCtrl.setLanguage(v.code),
                      options: [
                        (l10n.settingsLanguageSystem, AppLanguage.system),
                        for (final lang in AppLanguage.values)
                          if (lang != AppLanguage.system) (lang.nativeName, lang),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: NexusSpacing.xl),
                _Section(
                  label: l10n.sectionChat,
                  children: [
                    _SwitchTile(
                      icon: Icons.stream_rounded,
                      title: l10n.settingsStream,
                      subtitle: l10n.settingsStreamSubtitle,
                      value: prefs.streamingEnabled,
                      onChanged: prefsCtrl.setStreaming,
                    ),
                    const _Divider(),
                    _SwitchTile(
                      icon: Icons.menu_book_rounded,
                      title: l10n.settingsRag,
                      subtitle: l10n.settingsRagSubtitle,
                      value: prefs.ragByDefault,
                      onChanged: prefsCtrl.setRag,
                    ),
                    const _Divider(),
                    _SwitchTile(
                      icon: Icons.build_rounded,
                      title: l10n.settingsTools,
                      subtitle: l10n.settingsToolsSubtitle,
                      value: prefs.toolsByDefault,
                      onChanged: prefsCtrl.setTools,
                    ),
                    const _Divider(),
                    _SwitchTile(
                      icon: Icons.psychology_outlined,
                      title: l10n.settingsMemory,
                      subtitle: l10n.settingsMemorySubtitle,
                      value: memoryEnabled,
                      onChanged: (v) => _setMemoryEnabled(context, ref, v),
                    ),
                    const _Divider(),
                    _ActionTile(
                      icon: Icons.list_alt_rounded,
                      title: l10n.settingsWhatRemembers,
                      subtitle: l10n.settingsWhatRemembersSubtitle,
                      onTap: () => context.go(AppRoutes.memory),
                    ),
                    const _Divider(),
                    _ChoiceTile<StreamTransport>(
                      icon: Icons.swap_horiz_rounded,
                      title: l10n.settingsTransport,
                      value: prefs.transport,
                      onChanged: prefsCtrl.setTransport,
                      options: [
                        (l10n.settingsTransportSse, StreamTransport.sse),
                        (l10n.settingsTransportWs, StreamTransport.websocket),
                      ],
                    ),
                  ],
                ),

                if (voice != null && voice.ttsAvailable) ...[
                  const SizedBox(height: NexusSpacing.xl),
                  _Section(
                    label: l10n.sectionVoice,
                    children: [
                      _SwitchTile(
                        icon: Icons.volume_up_rounded,
                        title: l10n.settingsSpeakReplies,
                        subtitle: l10n.settingsSpeakRepliesSubtitle(voice.provider),
                        value: prefs.speakReplies,
                        onChanged: prefsCtrl.setSpeakReplies,
                      ),
                      if (voice.voices.isNotEmpty) ...[
                        const _Divider(),
                        _ChoiceTile<String>(
                          icon: Icons.record_voice_over_rounded,
                          title: l10n.settingsVoice,
                          value: selectedVoice,
                          onChanged: (v) => prefsCtrl.setVoice(v.isEmpty ? null : v),
                          options: [
                            (l10n.voiceServerDefault, ''),
                            for (final v in voice.voices) (v.name, v.id),
                          ],
                        ),
                      ],
                      if (voice.sttAvailable) ...[
                        const _Divider(),
                        _InfoRow(
                          icon: Icons.mic_rounded,
                          label: l10n.settingsVoiceInput,
                          value: l10n.settingsVoiceInputValue,
                        ),
                      ],
                    ],
                  ),
                ],

                const SizedBox(height: NexusSpacing.xl),
                _Section(
                  label: l10n.sectionModel,
                  children: [
                    catalog.when(
                      loading: () => _ModelsPlaceholder(
                        icon: Icons.hourglass_empty_rounded,
                        text: l10n.settingsLoadingModels,
                      ),
                      error: (e, _) => _ModelsPlaceholder(
                        icon: Icons.cloud_off_rounded,
                        text: l10n.settingsModelsFailed(context.describeError(e)),
                        action: TextButton(
                          onPressed: () => _refreshModels(ref),
                          child: Text(l10n.commonRetry),
                        ),
                      ),
                      data: (c) {
                        if (c.isEmpty) {
                          return _ModelsPlaceholder(
                            icon: Icons.memory_rounded,
                            text: l10n.settingsNoProviders,
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
                                l10n.settingsModelNote,
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
                    label: l10n.sectionAdministration,
                    children: [
                      _ActionTile(
                        icon: Icons.insights_rounded,
                        title: l10n.settingsServerUsage,
                        subtitle: l10n.settingsServerUsageSubtitle,
                        onTap: () => context.go(AppRoutes.adminUsage),
                      ),
                      const _Divider(),
                      _ActionTile(
                        icon: Icons.thumbs_up_down_outlined,
                        title: l10n.settingsFeedback,
                        subtitle: l10n.settingsFeedbackSubtitle,
                        onTap: () => context.go(AppRoutes.adminFeedback),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: NexusSpacing.xl),
                _Section(
                  label: l10n.sectionSecurity,
                  children: [
                    _SwitchTile(
                      icon: Icons.fingerprint_rounded,
                      title: l10n.settingsBiometric,
                      subtitle: l10n.settingsBiometricSubtitle,
                      value: prefs.biometricUnlock,
                      onChanged: (v) => _setBiometric(context, ref, v),
                    ),
                  ],
                ),

                const SizedBox(height: NexusSpacing.xl),
                _Section(
                  label: l10n.sectionOffline,
                  children: [
                    _ActionTile(
                      icon: Icons.cloud_off_rounded,
                      title: l10n.settingsClearCache,
                      subtitle: l10n.settingsClearCacheSubtitle,
                      onTap: () => _clearCache(context, ref),
                    ),
                  ],
                ),

                const SizedBox(height: NexusSpacing.xl),
                _Section(
                  label: l10n.sectionConnection,
                  children: [
                    _InfoRow(
                      icon: Icons.cloud_outlined,
                      label: l10n.settingsApiBaseUrl,
                      value: Env.apiBaseUrl,
                    ),
                  ],
                ),

                const SizedBox(height: NexusSpacing.xl),
                _Section(
                  label: l10n.sectionAccount,
                  children: [
                    _ActionTile(
                      icon: Icons.person_outline_rounded,
                      title: l10n.settingsDisplayName,
                      subtitle:
                          displayName?.isNotEmpty == true ? displayName! : l10n.settingsNotSet,
                      onTap: () => _editDisplayName(context, ref, displayName),
                    ),
                    const _Divider(),
                    _ActionTile(
                      icon: Icons.password_rounded,
                      title: l10n.settingsChangePassword,
                      subtitle: l10n.settingsChangePasswordSubtitle,
                      onTap: () => _changePassword(context, ref),
                    ),
                    const _Divider(),
                    _ActionTile(
                      icon: Icons.delete_sweep_rounded,
                      title: l10n.settingsClearAllChats,
                      subtitle: l10n.settingsClearAllChatsSubtitle,
                      onTap: () => _clearAllChats(context, ref),
                      danger: true,
                    ),
                    const _Divider(),
                    _ActionTile(
                      icon: Icons.logout_rounded,
                      title: l10n.settingsSignOut,
                      subtitle: user.value?.email ?? '',
                      onTap: () => _logout(context, ref),
                      danger: true,
                    ),
                    const _Divider(),
                    _ActionTile(
                      icon: Icons.devices_other_rounded,
                      title: l10n.settingsSignOutEverywhere,
                      subtitle: l10n.settingsSignOutEverywhereSubtitle,
                      onTap: () => _logoutEverywhere(context, ref),
                      danger: true,
                    ),
                    const _Divider(),
                    _ActionTile(
                      icon: Icons.delete_forever_rounded,
                      title: l10n.settingsDeleteAccount,
                      subtitle: l10n.settingsDeleteAccountSubtitle,
                      onTap: () => _deleteAccount(context, ref),
                      danger: true,
                    ),
                  ],
                ),

                const SizedBox(height: NexusSpacing.xl),
                _Section(
                  label: l10n.sectionAbout,
                  children: [
                    _InfoRow(
                      icon: Icons.info_outline_rounded,
                      label: l10n.settingsVersion,
                      value: appInfo.versionLabel,
                    ),
                    const _Divider(),
                    _ActionTile(
                      icon: Icons.policy_outlined,
                      title: l10n.settingsLegal,
                      subtitle: l10n.settingsLegalSubtitle,
                      onTap: () => context.push(AppRoutes.legal),
                    ),
                    const _Divider(),
                    _ActionTile(
                      icon: Icons.code_rounded,
                      title: l10n.settingsLicenses,
                      subtitle: l10n.settingsLicensesSubtitle,
                      onTap: () => _showLicenses(context, appInfo),
                    ),
                  ],
                ),

                const SizedBox(height: NexusSpacing.xxxl),
                Center(
                  child: Text(
                    l10n.settingsFooter(appInfo.version),
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
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n.commonCancel),
        ),
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
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonCancel),
        ),
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
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.settingsChangePassword),
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
              decoration: InputDecoration(hintText: l10n.settingsCurrentPassword),
              validator: (v) => (v ?? '').isEmpty ? l10n.settingsCurrentPasswordRequired : null,
            ),
            const SizedBox(height: NexusSpacing.md),
            TextFormField(
              controller: _next,
              obscureText: true,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(hintText: l10n.settingsNewPasswordHint),
              validator: (v) => (v ?? '').length < 8 ? l10n.authPasswordTooShort : null,
            ),
            const SizedBox(height: NexusSpacing.md),
            TextFormField(
              controller: _confirm,
              obscureText: true,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(hintText: l10n.settingsRepeatPassword),
              onFieldSubmitted: (_) => _submit(),
              validator: (v) => v != _next.text ? l10n.settingsPasswordsMismatch : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: Text(l10n.settingsChangePassword),
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
    final l10n = context.l10n;
    final t = context.tokens;
    final hints = <String>[
      if (model.contextLabel != null) model.contextLabel!,
      if (model.priceLabel != null) model.priceLabel!,
      if (!model.supportsTools) l10n.modelNoTools,
      if (model.supportsVision) l10n.modelVision,
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
    final l10n = context.l10n;
    final t = context.tokens;
    final options = [
      (Icons.brightness_auto_rounded, l10n.themeSystem, ThemeMode.system),
      (Icons.light_mode_rounded, l10n.themeLight, ThemeMode.light),
      (Icons.dark_mode_rounded, l10n.themeDark, ThemeMode.dark),
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
