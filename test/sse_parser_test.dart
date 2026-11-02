import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/sse_parser.dart';

void main() {
  group('SseDecoder', () {
    test('parses a single data frame', () {
      final d = SseDecoder();
      final events = d.feed('data: {"type":"token","data":"Hi"}\n\n');
      expect(events, hasLength(1));
      expect(events.single.data, '{"type":"token","data":"Hi"}');
      expect(events.single.event, isNull);
    });

    test('does not dispatch until the blank line arrives', () {
      final d = SseDecoder();
      expect(d.feed('data: {"a":1}\n'), isEmpty);
      final events = d.feed('\n');
      expect(events.map((e) => e.data), ['{"a":1}']);
    });

    test('reassembles a frame split across arbitrary chunk boundaries', () {
      final d = SseDecoder();
      final chunks = ['da', 'ta: {"type":"to', 'ken","data":"He', 'llo"}\n', '\n'];
      final events = <SseEvent>[];
      for (final c in chunks) {
        events.addAll(d.feed(c));
      }
      expect(events, hasLength(1));
      expect(events.single.data, '{"type":"token","data":"Hello"}');
    });

    test('handles several frames in one chunk', () {
      final d = SseDecoder();
      final events = d.feed('data: a\n\ndata: b\n\ndata: c\n\n');
      expect(events.map((e) => e.data), ['a', 'b', 'c']);
    });

    test('joins multi-line data with newlines', () {
      final d = SseDecoder();
      final events = d.feed('data: line one\ndata: line two\ndata:\n\n');
      expect(events.single.data, 'line one\nline two\n');
    });

    test('ignores comment lines, retry and unknown fields', () {
      final d = SseDecoder();
      expect(d.feed(': keep-alive\n\n'), isEmpty);
      final events = d.feed(': ping\nretry: 3000\nfoo: bar\ndata: x\n: mid\n\n');
      expect(events.single.data, 'x');
    });

    test('carries event and id fields; id persists across frames', () {
      final d = SseDecoder();
      final first = d.feed('event: token\nid: 7\ndata: a\n\n').single;
      expect(first.event, 'token');
      expect(first.id, '7');
      final second = d.feed('data: b\n\n').single;
      expect(second.event, isNull, reason: 'event type resets per frame');
      expect(second.id, '7', reason: 'last event id persists');
    });

    test('strips exactly one leading space after the colon', () {
      final d = SseDecoder();
      expect(d.feed('data:x\n\n').single.data, 'x');
      expect(d.feed('data:  x\n\n').single.data, ' x');
      expect(d.feed('data\n\n').single.data, '', reason: 'field without colon has empty value');
    });

    test('accepts CRLF and CR line endings, even when split across chunks', () {
      final d = SseDecoder();
      expect(d.feed('data: crlf\r\n\r\n').single.data, 'crlf');

      // A lone CR terminates a line too, but a *trailing* CR is held back
      // until the next chunk shows whether a LF follows it.
      expect(d.feed('data: cr\r\r'), isEmpty);
      expect(d.feed('data: next\r\r').single.data, 'cr');
      expect(d.flush().single.data, 'next');

      // CRLF pairs split across chunks.
      expect(d.feed('data: split\r'), isEmpty);
      expect(d.feed('\n\r'), isEmpty);
      expect(d.feed('\n').single.data, 'split');
    });

    test('blank lines without data dispatch nothing', () {
      final d = SseDecoder();
      expect(d.feed('\n\n\n'), isEmpty);
      expect(d.feed('event: only\n\n'), isEmpty);
    });

    test('flush dispatches an unterminated trailing frame', () {
      final d = SseDecoder();
      expect(d.feed('data: tail'), isEmpty);
      expect(d.flush().single.data, 'tail');
      expect(d.flush(), isEmpty);
    });
  });

  group('SseTransformer', () {
    test('turns a chunked text stream into events', () async {
      final chunks = Stream.fromIterable([
        'data: {"type":"token","data":"a"}\n',
        '\ndata: {"type":"token",',
        '"data":"b"}\n\n',
      ]);
      final events = await chunks.transform(const SseTransformer()).toList();
      expect(events.map((e) => jsonDecode(e.data)['data']), ['a', 'b']);
    });

    test('composes with the UTF-8 decoder when bytes split a multi-byte character', () async {
      final bytes = utf8.encode('data: price €5\n\n');
      final euro = bytes.indexOf(0xE2);
      final chunks = Stream.fromIterable(<List<int>>[
        bytes.sublist(0, euro + 1), // first byte of '€' only
        bytes.sublist(euro + 1),
      ]);
      final events = await const SseTransformer().bind(utf8.decoder.bind(chunks)).toList();
      expect(events.single.data, 'price €5');
    });

    test('flushes a trailing frame when the stream ends', () async {
      final events = await Stream.value('data: last').transform(const SseTransformer()).toList();
      expect(events.single.data, 'last');
    });
  });
}
