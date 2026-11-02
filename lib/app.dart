import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/preferences.dart';
import 'core/router.dart';
import 'core/sync.dart';
import 'core/theme.dart';
import 'features/push/push_registrar.dart';
import 'features/security/lock_gate.dart';
import 'features/share_intake/share_intake.dart';
import 'l10n/l10n.dart';

class NexusBotApp extends ConsumerWidget {
  const NexusBotApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(prefsProvider.select((p) => p.themeMode));
    final language = ref.watch(prefsProvider.select((p) => p.languageCode));
    // Device registration + notification taps (no-op without a push provider).
    ref.watch(pushBootstrapProvider);
    // Offline → online reconciliation (session list, send queue, open chats).
    ref.watch(syncCoordinatorProvider);
    // "Share to NexusBot" from other apps (no-op off Android / iOS).
    ref.watch(shareIntakeBootstrapProvider);
    return MaterialApp.router(
      onGenerateTitle: (context) => context.l10n.appTitle,
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      darkTheme: buildNexusTheme(dark: true),
      theme: buildNexusTheme(dark: false),
      locale: AppLanguage.fromCode(language).locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
      builder: (context, child) => LockGate(child: child ?? const SizedBox.shrink()),
    );
  }
}
