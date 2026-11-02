import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nexusbot/core/connectivity.dart';
import 'package:nexusbot/core/local_store.dart';
import 'package:nexusbot/core/theme.dart';
import 'package:nexusbot/l10n/l10n.dart';

/// Hosts [child] the way the app does: a [MaterialApp] with the generated
/// localization delegates, the dark theme and — when [textDirection] is
/// given — a forced [Directionality] (RTL layout checks).
///
/// [locale] picks the ARB file (`en` by default); `he` / `ar` are
/// right-to-left locales, so passing one of them without [textDirection]
/// also mirrors the layout.
Widget localizedApp({
  required Widget child,
  Locale locale = const Locale('en'),
  TextDirection? textDirection,
  List<Override> overrides = const [],
  bool scrollable = true,
}) {
  final body = scrollable ? ListView(children: [child]) : child;
  return ProviderScope(
    overrides: [
      localStoreProvider.overrideWithValue(MemoryLocalStore()),
      connectivityServiceProvider.overrideWithValue(ManualConnectivityService()),
      ...overrides,
    ],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildNexusTheme(dark: true),
      home: Scaffold(
        body: textDirection == null
            ? body
            : Directionality(textDirection: textDirection, child: body),
      ),
    ),
  );
}
