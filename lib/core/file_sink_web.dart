import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'file_sink.dart';

FileSink createFileSink() => WebDownloadFileSink();

/// Triggers a browser download through a temporary object URL.
class WebDownloadFileSink implements FileSink {
  @override
  Future<void> save({
    required Uint8List bytes,
    required String filename,
    required String mimeType,
  }) async {
    final blob = web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..style.display = 'none';
    web.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    web.URL.revokeObjectURL(url);
  }
}
