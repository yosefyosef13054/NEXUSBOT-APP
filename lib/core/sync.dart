import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/chat/chat_repository.dart';
import '../features/chat/send_queue.dart';
import '../features/usage/usage_repository.dart';
import 'connectivity.dart';

/// Bumped on every offline → online transition. Chat controllers listen to it
/// and re-attach to an in-flight generation / refresh their history.
final reconnectTickProvider = StateProvider<int>((_) => 0);

/// Reconciles state when the device comes back online: the session list and
/// the usage meter are refreshed, the send queue replays what it holds and
/// every open chat is told to resync.
class SyncCoordinator {
  SyncCoordinator(this._ref) {
    _ref.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) {
      if (previous?.valueOrNull == false && next.valueOrNull == true) onReconnect();
    });
  }

  final Ref _ref;
  int reconnects = 0;

  void onReconnect() {
    reconnects++;
    if (_ref.exists(sessionListProvider)) _ref.invalidate(sessionListProvider);
    if (_ref.exists(usageMeProvider)) _ref.invalidate(usageMeProvider);
    _ref.read(reconnectTickProvider.notifier).state++;
    unawaited(_ref.read(sendQueueProvider.notifier).drain());
  }
}

/// Watched by the root widget so the coordinator lives as long as the app.
final syncCoordinatorProvider = Provider<SyncCoordinator>((ref) => SyncCoordinator(ref));
