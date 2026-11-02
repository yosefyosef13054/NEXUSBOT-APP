import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/api_exception.dart';
import 'package:nexusbot/l10n/l10n.dart';

/// Keys of an ARB file (translation entries only, no `@` metadata).
Map<String, String> arbEntries(String path) {
  final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in json.entries)
      if (!e.key.startsWith('@')) e.key: e.value as String,
  };
}

/// `{name}` / `{name, plural, …}` placeholders of an ICU message, in order
/// of first appearance (inner plural cases reuse the same names).
Set<String> placeholdersOf(String message) {
  final out = <String>{};
  for (final m in RegExp(r'\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*[,}]').allMatches(message)) {
    out.add(m.group(1)!);
  }
  return out;
}

void main() {
  const locales = ['en', 'he', 'ar'];

  test('every ARB locale has exactly the English keys', () {
    final en = arbEntries('lib/l10n/app_en.arb');
    expect(en, isNotEmpty);
    for (final locale in locales.skip(1)) {
      final other = arbEntries('lib/l10n/app_$locale.arb');
      final missing = en.keys.where((k) => !other.containsKey(k)).toList();
      final extra = other.keys.where((k) => !en.containsKey(k)).toList();
      expect(missing, isEmpty, reason: '$locale lacks keys');
      expect(extra, isEmpty, reason: '$locale has keys unknown to en');
    }
  });

  test('every translation keeps the English placeholders and is non-empty', () {
    final en = arbEntries('lib/l10n/app_en.arb');
    for (final locale in locales.skip(1)) {
      final other = arbEntries('lib/l10n/app_$locale.arb');
      for (final entry in en.entries) {
        final translated = other[entry.key]!;
        expect(translated.trim(), isNotEmpty, reason: '$locale.${entry.key} is empty');
        expect(
          placeholdersOf(translated),
          placeholdersOf(entry.value),
          reason: '$locale.${entry.key} placeholders differ',
        );
      }
    }
  });

  test('the generated class serves the three locales and they differ', () {
    expect(AppLocalizations.supportedLocales, containsAll(supportedAppLocales));
    final en = lookupAppLocalizations(const Locale('en'));
    final he = lookupAppLocalizations(const Locale('he'));
    final ar = lookupAppLocalizations(const Locale('ar'));
    expect(en.commonCancel, 'Cancel');
    expect(he.commonCancel, isNot(en.commonCancel));
    expect(ar.commonCancel, isNot(en.commonCancel));
    expect(he.memoriesUsed(1), isNot(he.memoriesUsed(3)), reason: 'plural forms');
    expect(ar.shareViews(2), isNotEmpty);
  });

  test('AppLanguage maps codes both ways', () {
    expect(AppLanguage.fromCode(null), AppLanguage.system);
    expect(AppLanguage.fromCode('he'), AppLanguage.hebrew);
    expect(AppLanguage.fromCode('xx'), AppLanguage.system);
    expect(AppLanguage.arabic.locale, const Locale('ar'));
    expect(AppLanguage.system.locale, isNull);
    expect(AppLanguage.hebrew.nativeName, 'עברית');
  });

  test('localizedErrorText translates transport failures and keeps server text', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(
      localizedErrorText(l10n, ApiException(code: 'network_error', message: 'socket')),
      l10n.errorNetwork,
    );
    expect(
      localizedErrorText(l10n, ApiException(code: 'timeout', message: 't')),
      l10n.errorTimeout,
    );
    expect(
      localizedErrorText(l10n, ApiException(code: 'http_502', message: 'x', statusCode: 502)),
      'Request failed (502)',
    );
    expect(
      localizedErrorText(
        l10n,
        ApiException(
          code: 'validation_error',
          message: 'Type not allowed',
          requestId: 'abcdef1234',
        ),
      ),
      'Type not allowed (ref abcdef12)',
    );
    expect(localizedErrorText(l10n, StateError('boom')), contains('boom'));
    final he = lookupAppLocalizations(const Locale('he'));
    expect(
      localizedErrorText(he, ApiException(code: 'network_error', message: 'socket')),
      he.errorNetwork,
    );
  });
}
