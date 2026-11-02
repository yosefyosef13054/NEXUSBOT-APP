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
import 'login_screen.dart' show AuthErrorBanner, LegalNoticeLink;

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
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
      await repo.register(
        email: _email.text.trim(),
        password: _password.text,
        fullName: _name.text.trim(),
      );
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
      appBar: AppBar(
        leading: IconButton(
          tooltip: l10n.authBack,
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go(AppRoutes.login),
        ),
      ),
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
                            const NexusLogo(size: 56),
                            const SizedBox(height: NexusSpacing.lg),
                            const NexusWordmark(fontSize: 24),
                            const SizedBox(height: NexusSpacing.sm),
                            Text(
                              l10n.registerCreateAccount,
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
                      const SizedBox(height: NexusSpacing.xxl),
                      TextFormField(
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          hintText: l10n.registerFullNameHint,
                          prefixIcon: const Icon(Icons.person_outline, size: 20),
                        ),
                      ),
                      const SizedBox(height: NexusSpacing.md),
                      TextFormField(
                        controller: _email,
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
                        obscureText: true,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          hintText: l10n.registerPasswordHint,
                          prefixIcon: const Icon(Icons.lock_outline, size: 20),
                        ),
                        validator: (v) => (v ?? '').length < 8 ? l10n.authPasswordTooShort : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: NexusSpacing.md),
                        AuthErrorBanner(message: _error!),
                      ],
                      const SizedBox(height: NexusSpacing.xl),
                      NexusButton(
                        label: l10n.registerSubmit,
                        icon: Icons.bolt_rounded,
                        loading: _loading,
                        onPressed: _loading ? null : _submit,
                      ),
                      const SizedBox(height: NexusSpacing.lg),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            l10n.registerHavePrompt,
                            style: TextStyle(color: context.tokens.textSecondary),
                          ),
                          TextButton(
                            onPressed: () => context.go(AppRoutes.login),
                            child: Text(
                              l10n.registerSignIn,
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
