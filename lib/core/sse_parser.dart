import 'dart:async';

/// One dispatched `text/event-stream` frame.
class SseEvent {
  const SseEvent({required this.data, this.event, this.id});

  /// The `data:` payload. Multi-line data is joined with `\n`.
  final String data;

  /// The `event:` field, when the server sent one for this frame.
  final String? event;

  /// The last `id:` seen on the stream (persists across frames, like
  /// `EventSource.lastEventId`).
  final String? id;

  @override
  String toString() => 'SseEvent(event: $event, id: $id, data: $data)';
}

/// Incremental SSE decoder (WHATWG EventSource framing), pure Dart.
///
/// Feed it decoded text in arbitrary chunks — a frame may be split anywhere,
/// even inside a line or a `\r\n` pair — and it returns the events completed
/// by each chunk. `:` comment lines, `retry:` and unknown fields are ignored;
/// `event:` and `id:` ride along on the event; a blank line dispatches.
/// Tolerant of servers that end the stream without a final blank line:
/// [flush] dispatches whatever frame is still pending.
class SseDecoder {
  String _pending = '';
  final List<String> _dataLines = [];
  bool _hasData = false;
  String? _event;
  String? _id;

  /// Consumes [chunk] and returns the events it completed (possibly none).
  List<SseEvent> feed(String chunk) {
    _pending += chunk;
    final out = <SseEvent>[];
    while (true) {
      final end = _findLineEnd(_pending);
      if (end == null) break;
      final line = _pending.substring(0, end.$1);
      _pending = _pending.substring(end.$1 + end.$2);
      final event = _processLine(line);
      if (event != null) out.add(event);
    }
    return out;
  }

  /// Call once at end of stream: processes an unterminated last line and
  /// dispatches a pending frame.
  List<SseEvent> flush() {
    final out = <SseEvent>[];
    if (_pending.isNotEmpty) {
      var line = _pending;
      _pending = '';
      // A held-back trailing CR was a line terminator after all.
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      final event = _processLine(line);
      if (event != null) out.add(event);
    }
    final last = _dispatch();
    if (last != null) out.add(last);
    return out;
  }

  /// `(index, terminatorLength)` of the next `\n`, `\r\n` or `\r`, or null
  /// when no complete line is buffered. A trailing lone `\r` is held back
  /// until we know whether a `\n` follows it in the next chunk.
  (int, int)? _findLineEnd(String s) {
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c == 0x0A) return (i, 1);
      if (c == 0x0D) {
        if (i + 1 >= s.length) return null;
        return s.codeUnitAt(i + 1) == 0x0A ? (i, 2) : (i, 1);
      }
    }
    return null;
  }

  SseEvent? _processLine(String line) {
    if (line.isEmpty) return _dispatch();
    if (line.startsWith(':')) return null;

    final colon = line.indexOf(':');
    final String field;
    String value;
    if (colon == -1) {
      field = line;
      value = '';
    } else {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
    }

    switch (field) {
      case 'data':
        _dataLines.add(value);
        _hasData = true;
      case 'event':
        _event = value;
      case 'id':
        _id = value;
      default:
        // `retry:` and unknown fields are ignored.
        break;
    }
    return null;
  }

  SseEvent? _dispatch() {
    if (!_hasData) {
      // Nothing to dispatch; per spec the event type buffer still resets.
      _event = null;
      return null;
    }
    final event = SseEvent(data: _dataLines.join('\n'), event: _event, id: _id);
    _dataLines.clear();
    _hasData = false;
    _event = null;
    return event;
  }
}

/// Stream adapter over [SseDecoder]: text chunks in, [SseEvent]s out.
///
/// Cancelling a subscription on the bound stream cancels the source
/// subscription, which is what closes the HTTP connection underneath.
class SseTransformer extends StreamTransformerBase<String, SseEvent> {
  const SseTransformer();

  @override
  Stream<SseEvent> bind(Stream<String> stream) {
    final decoder = SseDecoder();
    return StreamTransformer<String, SseEvent>.fromHandlers(
      handleData: (chunk, sink) {
        for (final event in decoder.feed(chunk)) {
          sink.add(event);
        }
      },
      handleDone: (sink) {
        for (final event in decoder.flush()) {
          sink.add(event);
        }
        sink.close();
      },
    ).bind(stream);
  }
}
