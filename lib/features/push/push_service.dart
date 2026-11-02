import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/env.dart';

/// The platform side of push notifications: a device token to register with
/// `POST /devices` and the data payloads of tapped notifications.
///
/// [NoopPushService] is the default; `--dart-define=PUSH_PROVIDER=fcm`
/// selects [FcmPushService] (see its notes on wiring Firebase).
abstract class PushService {
  /// Whether this build can receive notifications at all.
  bool get isAvailable;

  /// `ios` | `android` | `web` — what `POST /devices` expects.
  String get platform;

  /// The device token, asking for permission when needed; null when push is
  /// unavailable or the user declined.
  Future<String?> getToken();

  /// Data payloads of notifications the user tapped
  /// (`{type: generation_done, session_id, generation_id}`), including the
  /// one that launched the app.
  Stream<Map<String, dynamic>> get payloads;

  Future<void> dispose();
}

/// `ios` / `android` / `web` for this device.
String currentPushPlatform() {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'ios',
    TargetPlatform.android => 'android',
    _ => 'web',
  };
}

/// No push provider compiled in (desktop builds, or a server without one).
class NoopPushService implements PushService {
  const NoopPushService();

  @override
  bool get isAvailable => false;

  @override
  String get platform => currentPushPlatform();

  @override
  Future<String?> getToken() async => null;

  @override
  Stream<Map<String, dynamic>> get payloads => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

/// Firebase Cloud Messaging — a documented stub, selected with
/// `--dart-define=PUSH_PROVIDER=fcm`.
///
/// The `firebase_messaging` plugin is not linked yet: compiling it needs the
/// per-app Firebase configuration (`android/app/google-services.json`,
/// `ios/Runner/GoogleService-Info.plist`, the `google-services` Gradle plugin
/// and `firebase_options.dart` from `flutterfire configure`), which this
/// repository does not carry. To wire it:
///
/// 1. `flutter pub add firebase_core firebase_messaging` and run
///    `flutterfire configure` (adds the config files and `firebase_options.dart`).
/// 2. In `main()`: `await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`.
/// 3. Replace the bodies below:
///    - [getToken]: `await FirebaseMessaging.instance.requestPermission()`,
///      then `return FirebaseMessaging.instance.getToken()`
///      (`getToken(vapidKey: …)` on the web); forward
///      `FirebaseMessaging.instance.onTokenRefresh` to [PushRegistrar.sync]
///      by re-registering.
///    - [payloads]: add `(await FirebaseMessaging.instance.getInitialMessage())?.data`
///      and every `FirebaseMessaging.onMessageOpenedApp` message's `data`.
/// 4. Point the server at FCM: `PUSH_PROVIDER=webhook` with a bridge that
///    forwards `{devices, notification, data}` to the FCM HTTP v1 API (see
///    the backend README) — `data` must be passed through unchanged so
///    [PushRouter.handlePushPayload] can open the chat.
///
/// Until then the stub reports itself unavailable, so nothing registers.
class FcmPushService implements PushService {
  FcmPushService();

  final _payloads = StreamController<Map<String, dynamic>>.broadcast();

  @override
  bool get isAvailable => false;

  @override
  String get platform => currentPushPlatform();

  @override
  Future<String?> getToken() async => null;

  @override
  Stream<Map<String, dynamic>> get payloads => _payloads.stream;

  @override
  Future<void> dispose() => _payloads.close();
}

final pushServiceProvider = Provider<PushService>((ref) {
  final service = switch (Env.pushProvider) {
    'fcm' => FcmPushService(),
    _ => const NoopPushService(),
  };
  ref.onDispose(service.dispose);
  return service;
});
