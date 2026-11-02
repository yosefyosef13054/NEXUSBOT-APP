import 'dart:typed_data';

import 'file_sink.dart';

FileSink createFileSink() => const UnsupportedFileSink();

/// Platforms without `dart:io` or a browser (never reached in practice).
class UnsupportedFileSink implements FileSink {
  const UnsupportedFileSink();

  @override
  Future<void> save({
    required Uint8List bytes,
    required String filename,
    required String mimeType,
  }) async {
    throw UnsupportedError('Saving files is not supported on this platform');
  }
}
