import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../l10n/l10n.dart';
import '../assistants/assistant_picker.dart';
import '../models/models_repository.dart';
import 'chat_repository.dart';

/// The "New chat" flow shared by the sidebar, the landing page, the
/// keyboard shortcut and the share intake: pick an assistant (when the
/// workspace has any), create the session and open it.
///
/// Returns the new session id, or null when the user dismissed the picker
/// or the creation failed (the error is shown as a snackbar).
Future<String?> startNewChat(
  BuildContext context,
  WidgetRef ref, {
  bool navigate = true,
  String? assistantId,
  bool askAssistant = true,
}) async {
  String? chosenAssistant = assistantId;
  if (askAssistant) {
    final choice = await pickAssistantForNewChat(context, ref);
    if (choice == null || !context.mounted) return null;
    chosenAssistant = choice.assistantId;
  }
  try {
    final repo = await ref.read(chatRepositoryProvider.future);
    // Only a model the server lists is sent; null lets the server resolve
    // the user's / its own default — or the assistant's model.
    final session = await repo.createSession(
      model: chosenAssistant == null ? ref.read(defaultModelIdProvider) : null,
      assistantId: chosenAssistant,
    );
    ref.invalidate(sessionListProvider);
    if (!context.mounted) return session.id;
    if (navigate) context.go(AppRoutes.chat(session.id));
    return session.id;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.describeError(e))));
    }
    return null;
  }
}
