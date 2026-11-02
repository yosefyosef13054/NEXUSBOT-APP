import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

/// Device unlock (biometrics, falling back to the device passcode) that gates
/// the token vault when the "Biometric unlock" setting is on. Behind an
/// interface so the lock screen and the setting can be tested without a device.
abstract class BiometricAuthenticator {
  /// Whether this device can authenticate at all (biometrics or passcode).
  Future<bool> isAvailable();

  /// Prompts the user; true when they passed. Never throws.
  Future<bool> authenticate({required String reason});
}

/// [BiometricAuthenticator] on top of `local_auth`. The plugin is created on
/// first use; any platform error counts as "not available" / "not passed".
class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  LocalAuthBiometricAuthenticator({LocalAuthentication Function()? createPlugin})
      : _createPlugin = createPlugin ?? LocalAuthentication.new;

  final LocalAuthentication Function() _createPlugin;
  LocalAuthentication? _plugin;

  LocalAuthentication get _instance => _plugin ??= _createPlugin();

  @override
  Future<bool> isAvailable() async {
    try {
      return await _instance.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate({required String reason}) async {
    try {
      return await _instance.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}

/// Platforms without a local-auth implementation (Linux, web) and tests.
class UnavailableBiometricAuthenticator implements BiometricAuthenticator {
  const UnavailableBiometricAuthenticator();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate({required String reason}) async => false;
}

final biometricAuthenticatorProvider =
    Provider<BiometricAuthenticator>((_) => LocalAuthBiometricAuthenticator());
