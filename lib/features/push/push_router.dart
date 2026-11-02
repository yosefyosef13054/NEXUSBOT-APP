import '../../core/router.dart';

/// The data of a tapped notification.
class PushPayload {
  const PushPayload({required this.type, this.sessionId, this.generationId});

  /// Null when [data] is not a notification this app understands.
  static PushPayload? parse(Map<String, dynamic> data) {
    final type = data['type'];
    if (type is! String || type.isEmpty) return null;
    return PushPayload(
      type: type,
      sessionId: _string(data['session_id']),
      generationId: _string(data['generation_id']),
    );
  }

  static String? _string(Object? v) {
    if (v is! String) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  /// `generation_done` — a background / voice turn finished.
  static const generationDone = 'generation_done';

  final String type;
  final String? sessionId;
  final String? generationId;

  bool get isGenerationDone => type == generationDone && sessionId != null;
}

/// Turns notification payloads into navigation: a `generation_done` opens
/// the chat and attaches to the generation (the chat screen reads the
/// `generation` query parameter and calls `ChatController.attachToGeneration`,
/// which falls back to a history reload when the replay is gone).
class PushRouter {
  PushRouter({required this.navigate});

  /// `GoRouter.go` (or a test double).
  final void Function(String location) navigate;

  /// Returns true when the payload was routed somewhere.
  bool handlePushPayload(Map<String, dynamic> data) {
    final location = locationFor(data);
    if (location == null) return false;
    navigate(location);
    return true;
  }

  /// The route for [data], or null when it is not actionable.
  static String? locationFor(Map<String, dynamic> data) {
    final payload = PushPayload.parse(data);
    if (payload == null || !payload.isGenerationDone) return null;
    return AppRoutes.chat(payload.sessionId!, generationId: payload.generationId);
  }
}
