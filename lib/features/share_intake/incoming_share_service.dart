import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// A file another app shared with NexusBot (already copied to a temporary
/// location by the platform).
class SharedFileRef {
  const SharedFileRef({required this.path, required this.name, this.mimeType});

  final String path;
  final String name;
  final String? mimeType;
}

/// What arrived through "Share to NexusBot": text / a URL and / or files.
class IncomingShare {
  const IncomingShare({this.text, this.files = const []});

  final String? text;
  final List<SharedFileRef> files;

  bool get isEmpty => (text == null || text!.trim().isEmpty) && files.isEmpty;

  /// Builds from the plugin's items: text and URLs are joined into [text],
  /// everything else is a file.
  static IncomingShare fromMedia(List<SharedMediaFile> items) {
    final texts = <String>[];
    final files = <SharedFileRef>[];
    for (final item in items) {
      switch (item.type) {
        case SharedMediaType.text:
        case SharedMediaType.url:
          if (item.path.trim().isNotEmpty) texts.add(item.path.trim());
        case SharedMediaType.image:
        case SharedMediaType.video:
        case SharedMediaType.file:
          files.add(
            SharedFileRef(path: item.path, name: _basename(item.path), mimeType: item.mimeType),
          );
      }
      final message = item.message?.trim();
      if (message != null && message.isNotEmpty && !texts.contains(message)) texts.add(message);
    }
    return IncomingShare(text: texts.isEmpty ? null : texts.join('\n'), files: files);
  }

  static String _basename(String path) {
    final clean = path.split('?').first;
    final i = clean.lastIndexOf(RegExp(r'[/\\]'));
    final name = i < 0 ? clean : clean.substring(i + 1);
    return name.isEmpty ? 'shared' : name;
  }
}

/// Shares arriving from other apps, behind an interface so the intake flow
/// can be tested without a device.
abstract class IncomingShareService {
  /// The share that launched the app (consumed once), if any.
  Future<IncomingShare?> initialShare();

  /// Shares received while the app is running.
  Stream<IncomingShare> get shares;

  Future<void> dispose();
}

/// [IncomingShareService] on top of `receive_sharing_intent` (Android, iOS).
/// Every platform failure resolves to "nothing shared".
class ReceiveSharingIntentService implements IncomingShareService {
  ReceiveSharingIntentService({ReceiveSharingIntent? plugin}) : _plugin = plugin;

  final ReceiveSharingIntent? _plugin;
  ReceiveSharingIntent get _instance => _plugin ?? ReceiveSharingIntent.instance;
  StreamController<IncomingShare>? _shares;
  StreamSubscription<List<SharedMediaFile>>? _sub;

  @override
  Future<IncomingShare?> initialShare() async {
    try {
      final items = await _instance.getInitialMedia();
      await _instance.reset();
      final share = IncomingShare.fromMedia(items);
      return share.isEmpty ? null : share;
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<IncomingShare> get shares {
    final existing = _shares;
    if (existing != null) return existing.stream;
    final controller = StreamController<IncomingShare>.broadcast();
    _shares = controller;
    try {
      _sub = _instance.getMediaStream().listen(
        (items) {
          final share = IncomingShare.fromMedia(items);
          if (!share.isEmpty && !controller.isClosed) controller.add(share);
        },
        onError: (Object _) {},
      );
    } catch (_) {
      // No platform implementation: nothing ever arrives.
    }
    return controller.stream;
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _shares?.close();
  }
}

/// Desktop, web and tests: nothing is ever shared in.
class NoopIncomingShareService implements IncomingShareService {
  const NoopIncomingShareService();

  @override
  Future<IncomingShare?> initialShare() async => null;

  @override
  Stream<IncomingShare> get shares => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

/// Only Android and iOS deliver share intents / extensions.
bool get supportsIncomingShares =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

final incomingShareServiceProvider = Provider<IncomingShareService>((ref) {
  final service = supportsIncomingShares
      ? ReceiveSharingIntentService() as IncomingShareService
      : const NoopIncomingShareService();
  ref.onDispose(service.dispose);
  return service;
});
