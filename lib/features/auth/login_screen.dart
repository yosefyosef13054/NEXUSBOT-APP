import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../l10n/l10n.dart';
import 'auth_providers.dart';
import 'auth_repository.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.login(email: _email.text.trim(), password: _password.text);
      ref.invalidate(currentUserProvider);
      if (mounted) context.go(AppRoutes.home);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = context.describeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      body: EmberBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(NexusSpacing.xl),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Column(
                          children: [
                            const NexusLogo(size: 64),
                            const SizedBox(height: NexusSpacing.lg),
                            const NexusWordmark(fontSize: 28),
                            const SizedBox(height: NexusSpacing.sm),
                            Text(
                              l10n.loginWelcomeBack,
                              style: const TextStyle(
                                color: NexusColors.crimson,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 4,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: NexusSpacing.xxxl),
                      TextFormField(
                        controller: _email,
                        autofillHints: const [AutofillHints.email],
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          hintText: l10n.authEmailHint,
                          prefixIcon: const Icon(Icons.mail_outline, size: 20),
                        ),
                        validator: (v) {
                          final s = (v ?? '').trim();
                          if (s.isEmpty) return l10n.authEmailRequired;
                          if (!s.contains('@')) return l10n.authEmailInvalid;
                          return null;
                        },
                      ),
                      const SizedBox(height: NexusSpacing.md),
                      TextFormField(
                        controller: _password,
                        autofillHints: const [AutofillHints.password],
                        obscureText: _obscure,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          hintText: l10n.authPasswordHint,
                          prefixIcon: const Icon(Icons.lock_outline, size: 20),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                              size: 20,
                            ),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) => (v ?? '').length < 8 ? l10n.authPasswordTooShort : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: NexusSpacing.md),
                        AuthErrorBanner(message: _error!),
                      ],
                      const SizedBox(height: NexusSpacing.xl),
                      NexusButton(
                        label: l10n.loginSignIn,
                        icon: Icons.arrow_forward_rounded,
                        loading: _loading,
                        onPressed: _loading ? null : _submit,
                      ),
                      const SizedBox(height: NexusSpacing.lg),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            l10n.loginNewPrompt,
                            style: TextStyle(color: context.tokens.textSecondary),
                          ),
                          TextButton(
                            onPressed: () => context.go(AppRoutes.register),
                            child: Text(
                              l10n.loginCreateAccount,
                              style: const TextStyle(
                                color: NexusColors.crimson,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: NexusSpacing.sm),
                      const LegalNoticeLink(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "By continuing you agree to the Terms & Privacy Policy" with the link
/// to `/legal`; shared by the login and register screens.
class LegalNoticeLink extends StatelessWidget {
  const LegalNoticeLink({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(l10n.authLegalNotice, style: TextStyle(color: t.textMuted, fontSize: 12)),
        TextButton(
          onPressed: () => context.push(AppRoutes.legal),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            l10n.authLegalLink,
            style: TextStyle(
              color: t.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ],
    );
  }
}

/// Inline error banner of the auth forms.
class AuthErrorBanner extends StatelessWidget {
  const AuthErrorBanner({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0x33EF4444),
        borderRadius: const BorderRadius.all(NexusRadius.md),
        border: Border.all(color: NexusColors.crimson, width: 1),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: NexusColors.crimson, size: 18),
          const SizedBox(width: NexusSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: context.tokens.textPrimary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
