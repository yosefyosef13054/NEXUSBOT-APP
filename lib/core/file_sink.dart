import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'file_sink_stub.dart'
    if (dart.library.io) 'file_sink_io.dart'
    if (dart.library.js_interop) 'file_sink_web.dart' as platform;

/// Hands a downloaded file to the platform: the system share sheet on
/// mobile / desktop (`share_plus`), a browser download on the web. Behind an
/// interface so exports can be tested without a platform.
abstract class FileSink {
  Future<void> save({
    required Uint8List bytes,
    required String filename,
    required String mimeType,
  });
}

final fileSinkProvider = Provider<FileSink>((_) => platform.createFileSink());
