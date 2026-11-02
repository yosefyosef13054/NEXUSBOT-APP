import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'file_sink.dart';

FileSink createFileSink() => ShareFileSink();

/// Writes the bytes to the temporary directory and opens the system share
/// sheet (save to Files, AirDrop, mail, …) — iOS, Android, macOS, Windows,
/// Linux.
class ShareFileSink implements FileSink {
  @override
  Future<void> save({
    required Uint8List bytes,
    required String filename,
    required String mimeType,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path, mimeType: mimeType, name: filename)], title: filename),
    );
  }
}
