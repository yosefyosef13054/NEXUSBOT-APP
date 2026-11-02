import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the device has a network path at all, behind an interface so the
/// send queue and the sync layer can be driven by a fake in tests.
///
/// "Online" here means a link exists (Wi-Fi, cellular, ethernet, …), not
/// that the API host answers — transport errors on real requests are still
/// handled by the callers (the send queue retries them with backoff).
abstract class ConnectivityService {
  /// The current state (true when unknown — never block on a doubt).
  Future<bool> checkOnline();

  /// Emits on every change; the first event is the first *change*, not the
  /// current state (see [checkOnline]).
  Stream<bool> get onlineChanges;

  Future<void> dispose();
}

/// [ConnectivityService] on top of `connectivity_plus`. The plugin is created
/// on first use and every failure (no platform implementation in `flutter
/// test`, a browser without the API) resolves to "online".
class ConnectivityPlusService implements ConnectivityService {
  ConnectivityPlusService({Connectivity Function()? createPlugin})
      : _createPlugin = createPlugin ?? Connectivity.new;

  final Connectivity Function() _createPlugin;
  Connectivity? _plugin;
  StreamController<bool>? _changes;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool? _last;

  Connectivity get _instance => _plugin ??= _createPlugin();

  /// A list that holds anything but `none` is a usable link.
  static bool isOnlineResult(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  @override
  Future<bool> checkOnline() async {
    try {
      final result = await _instance.checkConnectivity();
      return _last = isOnlineResult(result);
    } catch (_) {
      return true;
    }
  }

  @override
  Stream<bool> get onlineChanges {
    final existing = _changes;
    if (existing != null) return existing.stream;
    final controller = StreamController<bool>.broadcast();
    _changes = controller;
    try {
      _sub = _instance.onConnectivityChanged.listen(
        (results) {
          final online = isOnlineResult(results);
          if (_last == online) return;
          _last = online;
          if (!controller.isClosed) controller.add(online);
        },
        onError: (Object _) {
          // Platform without the API: stay silent (= assumed online).
        },
      );
    } catch (_) {
      // Same: no events, assumed online.
    }
    return controller.stream;
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _changes?.close();
    _changes = null;
  }
}

/// A scripted [ConnectivityService] (tests, and the web build where the
/// browser's `navigator.onLine` is unreliable enough to ignore).
class ManualConnectivityService implements ConnectivityService {
  ManualConnectivityService({bool online = true}) : _online = online;

  bool _online;
  final _changes = StreamController<bool>.broadcast();

  bool get online => _online;

  /// Flips the state and notifies listeners when it changed.
  void setOnline(bool value) {
    if (_online == value) return;
    _online = value;
    if (!_changes.isClosed) _changes.add(value);
  }

  @override
  Future<bool> checkOnline() async => _online;

  @override
  Stream<bool> get onlineChanges => _changes.stream;

  @override
  Future<void> dispose() => _changes.close();
}

final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  final service = ConnectivityPlusService();
  ref.onDispose(service.dispose);
  return service;
});

/// The current connectivity: the initial check, then every change. Readers
/// treat "not loaded yet" as online (`valueOrNull ?? true`).
final isOnlineProvider = StreamProvider<bool>((ref) async* {
  final service = ref.watch(connectivityServiceProvider);
  yield await service.checkOnline();
  yield* service.onlineChanges;
});

/// Convenience: `true` until the connectivity is known.
final onlineProvider = Provider<bool>((ref) => ref.watch(isOnlineProvider).valueOrNull ?? true);
