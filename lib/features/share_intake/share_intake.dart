import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router.dart';
import '../attachments/attachment_picker.dart';
import 'incoming_share_service.dart';

export 'incoming_share_service.dart';

/// What the chat screen should put in its composer when it opens: the
/// shared text and the shared files (read into memory, uploaded as
/// attachments). Consumed once by the chat of [sessionId].
class ComposerDraft {
  const ComposerDraft({required this.sessionId, this.text, this.files = const []});

  final String sessionId;
  final String? text;
  final List<PickedAttachment> files;
}

/// A share waiting for the user to pick a chat (the intake screen).
final pendingShareProvider = StateProvider<IncomingShare?>((_) => null);

/// The draft the next chat screen with that session id consumes.
final composerDraftProvider = StateProvider<ComposerDraft?>((_) => null);

/// Turns incoming shares into navigation: the share is parked in
/// [pendingShareProvider] and the intake screen opens. Pure so it can be
/// tested without a router.
class ShareIntakeRouter {
  ShareIntakeRouter({required this.navigate, required this.park});

  final void Function(String location) navigate;
  final void Function(IncomingShare share) park;

  /// Returns true when the share was taken in.
  bool handle(IncomingShare share) {
    if (share.isEmpty) return false;
    park(share);
    navigate(AppRoutes.shareIntake);
    return true;
  }
}

/// Wires the share stack once per app. Watched by the root widget; does
/// nothing where shares cannot arrive.
final shareIntakeBootstrapProvider = Provider<ShareIntakeRouter>((ref) {
  final service = ref.watch(incomingShareServiceProvider);
  final router = ShareIntakeRouter(
    navigate: (location) => ref.read(routerProvider).go(location),
    park: (share) => ref.read(pendingShareProvider.notifier).state = share,
  );
  unawaited(
    service.initialShare().then((share) {
      if (share != null) router.handle(share);
    }),
  );
  final sub = service.shares.listen(router.handle);
  ref.onDispose(sub.cancel);
  return router;
});
