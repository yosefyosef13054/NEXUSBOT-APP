import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../core/router.dart';
import '../auth/auth_models.dart';
import '../auth/auth_providers.dart';
import 'devices_repository.dart';
import 'push_router.dart';
import 'push_service.dart';

/// Keeps the server's device registration in step with the signed-in user:
/// registers the push token after sign-in and removes it at sign-out.
class PushRegistrar {
  PushRegistrar({
    required this.service,
    required this.repository,
    this.appVersion = defaultAppVersion,
    String? locale,
  }) : locale = locale ?? _systemLocale();

  /// `pubspec.yaml` version; reported as `app_version`.
  static const defaultAppVersion = AppInfo.fallbackVersion;

  final PushService service;
  final Future<DevicesRepository> Function() repository;
  final String appVersion;
  final String? locale;

  /// The token currently registered for the signed-in user.
  String? registeredToken;
  String? _userId;

  static String? _systemLocale() {
    try {
      return PlatformDispatcher.instance.locale.toLanguageTag();
    } catch (_) {
      return null;
    }
  }

  /// Called whenever the signed-in user changes. Failures are swallowed:
  /// push is a convenience and must never block the app.
  Future<void> sync(User? user) async {
    if (!service.isAvailable) return;
    if (user == null) {
      await _unregister();
      return;
    }
    if (_userId == user.id && registeredToken != null) return;
    _userId = user.id;
    try {
      final token = await service.getToken();
      if (token == null || token.isEmpty) return;
      final repo = await repository();
      await repo.register(
        platform: service.platform,
        token: token,
        appVersion: appVersion,
        locale: locale,
      );
      registeredToken = token;
    } catch (_) {
      // Retried on the next sign-in.
    }
  }

  Future<void> _unregister() async {
    final token = registeredToken;
    registeredToken = null;
    _userId = null;
    if (token == null) return;
    try {
      final repo = await repository();
      await repo.unregister(token);
    } catch (_) {
      // The server drops stale tokens on its own.
    }
  }
}

/// Wires the push stack once per app: registration follows the signed-in
/// user and tapped notifications navigate through the router. Watched by
/// the root widget; does nothing when the [PushService] is unavailable.
final pushBootstrapProvider = Provider<PushRegistrar>((ref) {
  final service = ref.watch(pushServiceProvider);
  final registrar = PushRegistrar(
    service: service,
    repository: () => ref.read(devicesRepositoryProvider.future),
  );
  if (!service.isAvailable) return registrar;

  ref.listen<AsyncValue<User?>>(
    currentUserProvider,
    (_, next) => unawaited(registrar.sync(next.valueOrNull)),
    fireImmediately: true,
  );
  final router = PushRouter(navigate: (location) => ref.read(routerProvider).go(location));
  final sub = service.payloads.listen(router.handlePushPayload);
  ref.onDispose(sub.cancel);
  return registrar;
});
