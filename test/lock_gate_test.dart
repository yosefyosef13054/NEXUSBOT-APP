import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/biometric_auth.dart';
import 'package:nexusbot/core/preferences.dart';
import 'package:nexusbot/core/secure_storage.dart';
import 'package:nexusbot/features/security/lock_gate.dart';
import 'package:nexusbot/l10n/l10n.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fakes.dart';
import 'helpers/test_app.dart';

class FakeAuthenticator implements BiometricAuthenticator {
  FakeAuthenticator({this.available = true, this.passes = true});
  bool available;
  bool passes;
  int prompts = 0;
  String? lastReason;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate({required String reason}) async {
    prompts++;
    lastReason = reason;
    return passes;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAuthenticator auth;
  late DateTime now;

  Future<ProviderContainer> makeContainer({required bool enabled}) async {
    SharedPreferences.setMockInitialValues({'pref.biometricUnlock': enabled});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWith((ref) => PrefsController(prefs)),
        biometricAuthenticatorProvider.overrideWithValue(auth),
        appLockProvider.overrideWith((ref) => AppLockController(ref, clock: () => now)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    auth = FakeAuthenticator();
    now = DateTime(2026, 1, 1, 12);
  });

  test('locked at start only when the setting is on; unlock prompts the device', () async {
    var container = await makeContainer(enabled: false);
    expect(container.read(appLockProvider), isFalse);

    container = await makeContainer(enabled: true);
    expect(container.read(appLockProvider), isTrue);
    auth.passes = false;
    expect(await container.read(appLockProvider.notifier).unlock(reason: 'r'), isFalse);
    expect(container.read(appLockProvider), isTrue);
    auth.passes = true;
    expect(await container.read(appLockProvider.notifier).unlock(reason: 'r'), isTrue);
    expect(container.read(appLockProvider), isFalse);
    expect(auth.prompts, 2);
    expect(auth.lastReason, 'r');
  });

  test('re-locks after enough time in the background, not after a short switch', () async {
    final container = await makeContainer(enabled: true);
    final lock = container.read(appLockProvider.notifier);
    await lock.unlock(reason: 'r');
    lock.onPaused();
    now = now.add(const Duration(seconds: 30));
    lock.onResumed();
    expect(container.read(appLockProvider), isFalse);

    lock.onPaused();
    now = now.add(AppLockController.relockAfter);
    lock.onResumed();
    expect(container.read(appLockProvider), isTrue);
  });

  test('turning the setting off releases the gate, turning it on locks', () async {
    final container = await makeContainer(enabled: true);
    container.listen(appLockProvider, (_, __) {});
    await container.read(prefsProvider.notifier).setBiometricUnlock(false);
    expect(container.read(appLockProvider), isFalse);
    await container.read(prefsProvider.notifier).setBiometricUnlock(true);
    expect(container.read(appLockProvider), isTrue);
  });

  testWidgets('the lock screen covers the app and opens after a successful prompt', (tester) async {
    SharedPreferences.setMockInitialValues({'pref.biometricUnlock': true});
    final prefs = await SharedPreferences.getInstance();
    auth.passes = false;
    await tester.pumpWidget(
      localizedApp(
        scrollable: false,
        overrides: [
          tokenStorageProvider.overrideWithValue(MemoryTokenStorage()),
          prefsProvider.overrideWith((ref) => PrefsController(prefs)),
          biometricAuthenticatorProvider.overrideWithValue(auth),
        ],
        child: const LockGate(child: Text('app body')),
      ),
    );
    await tester.pump();
    await tester.pump();
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.lockTitle), findsOneWidget);
    expect(auth.prompts, 1, reason: 'prompted on appearance');
    expect(find.text(l10n.lockFailed), findsOneWidget);

    auth.passes = true;
    await tester.tap(find.text(l10n.lockUnlock));
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.lockTitle), findsNothing);
    expect(find.text('app body'), findsOneWidget);
  });
}
