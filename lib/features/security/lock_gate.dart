import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/biometric_auth.dart';
import '../../core/preferences.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../l10n/l10n.dart';
import '../auth/auth_providers.dart';
import '../auth/auth_repository.dart';

/// Whether the app is behind the lock screen. Locked at cold start when the
/// "Biometric unlock" setting is on, and again after the app spent
/// [AppLockController.relockAfter] in the background.
class AppLockController extends StateNotifier<bool> {
  AppLockController(this._ref, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now,
        super(_ref.read(prefsProvider).biometricUnlock) {
    // Preferences load a frame after start: lock as soon as the stored
    // setting says so, unlock when the user turns it off.
    _ref.listen<bool>(prefsProvider.select((p) => p.biometricUnlock), (previous, next) {
      if (next && previous != true) {
        state = true;
      } else if (!next) {
        state = false;
      }
    });
  }

  /// Time in the background after which the next resume locks again.
  static const relockAfter = Duration(minutes: 2);

  final Ref _ref;
  final DateTime Function() _clock;
  DateTime? _pausedAt;
  bool _authenticating = false;

  bool get enabled => _ref.read(prefsProvider).biometricUnlock;

  /// The app went to the background.
  void onPaused() => _pausedAt = _clock();

  /// The app is back; locks when it was away long enough.
  void onResumed() {
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (!enabled || pausedAt == null) return;
    if (_clock().difference(pausedAt) >= relockAfter) state = true;
  }

  /// Prompts the device unlock; true when it passed (the gate opens).
  Future<bool> unlock({required String reason}) async {
    if (!state) return true;
    if (_authenticating) return false;
    _authenticating = true;
    try {
      final ok = await _ref.read(biometricAuthenticatorProvider).authenticate(reason: reason);
      if (ok && mounted) state = false;
      return ok;
    } finally {
      _authenticating = false;
    }
  }

  /// Clears the gate without authenticating (used after a sign-out).
  void release() => state = false;
}

final appLockProvider =
    StateNotifierProvider<AppLockController, bool>((ref) => AppLockController(ref));

/// Wraps the router: shows the [LockScreen] over everything while locked and
/// relays the app lifecycle to [AppLockController].
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final lock = ref.read(appLockProvider.notifier);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        lock.onPaused();
      case AppLifecycleState.resumed:
        lock.onResumed();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = ref.watch(appLockProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (locked) const LockScreen(),
      ],
    );
  }
}

/// Full-screen lock: prompts the device unlock as soon as it appears, with a
/// button to try again and a way out (sign out) for a device that cannot
/// authenticate any more.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (!mounted || _busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final ok = await ref.read(appLockProvider.notifier).unlock(reason: context.l10n.lockReason);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !ok;
    });
  }

  Future<void> _signOut() async {
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.logout();
    } catch (_) {
      // Tokens are cleared locally either way.
    }
    ref.invalidate(currentUserProvider);
    ref.read(appLockProvider.notifier).release();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return Material(
      color: t.background,
      child: EmberBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: const EdgeInsets.all(NexusSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const NexusLogo(size: 72),
                    const SizedBox(height: NexusSpacing.lg),
                    Text(
                      l10n.lockTitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: NexusSpacing.sm),
                    Text(
                      l10n.lockBody,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: t.textSecondary, fontSize: 13.5, height: 1.4),
                    ),
                    if (_failed) ...[
                      const SizedBox(height: NexusSpacing.md),
                      Text(
                        l10n.lockFailed,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: NexusColors.crimson, fontSize: 12.5),
                      ),
                    ],
                    const SizedBox(height: NexusSpacing.xl),
                    NexusButton(
                      label: l10n.lockUnlock,
                      icon: Icons.fingerprint_rounded,
                      loading: _busy,
                      onPressed: _busy ? null : _unlock,
                    ),
                    const SizedBox(height: NexusSpacing.md),
                    TextButton(onPressed: _busy ? null : _signOut, child: Text(l10n.lockSignOut)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
