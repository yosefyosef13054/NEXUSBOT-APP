import 'package:flutter/widgets.dart';

import '../core/api_exception.dart';
import 'generated/app_localizations.dart';

export 'generated/app_localizations.dart';

/// `context.l10n.someKey` — the generated [AppLocalizations] for the
/// ambient locale (non-nullable: the app always installs the delegates).
extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  /// Localised text for anything thrown by a repository call, see
  /// [localizedErrorText].
  String describeError(Object error) => localizedErrorText(l10n, error);
}

/// The language choice in Settings. [system] follows the device.
enum AppLanguage {
  system(null),
  english('en'),
  hebrew('he'),
  arabic('ar');

  const AppLanguage(this.code);

  /// The persisted value; null = follow the device.
  final String? code;

  Locale? get locale => code == null ? null : Locale(code!);

  static AppLanguage fromCode(String? code) =>
      values.firstWhere((l) => l.code == code, orElse: () => AppLanguage.system);

  /// The language's own name (never translated: a Hebrew speaker looking for
  /// their language in an English UI must still recognise it).
  String get nativeName => switch (this) {
        AppLanguage.system => '',
        AppLanguage.english => 'English',
        AppLanguage.hebrew => 'עברית',
        AppLanguage.arabic => 'العربية',
      };
}

/// The locales the app ships ARB files for; mirrors `l10n.yaml`.
const supportedAppLocales = [Locale('en'), Locale('he'), Locale('ar')];

/// Human-readable, translated text for an error thrown by a repository call
/// (`context.describeError` is the usual entry point).
///
/// Client-side transport failures (`network_error`, `timeout`, `cancelled`,
/// a bare HTTP status) are translated; a server envelope keeps the server's
/// message, with the short request id appended for support.
String localizedErrorText(AppLocalizations l10n, Object error) {
  if (error is! ApiException) return error.toString();
  final ref = error.shortRequestId;
  final String message;
  switch (error.code) {
    case 'network_error':
      message = l10n.errorNetwork;
    case 'timeout':
      message = l10n.errorTimeout;
    case 'cancelled':
      message = l10n.errorCancelled;
    default:
      final status = error.statusCode;
      message = error.code.startsWith('http_') && status != null
          ? l10n.errorRequestFailed(status)
          : error.message;
  }
  return ref == null ? message : l10n.errorWithReference(message, ref);
}
