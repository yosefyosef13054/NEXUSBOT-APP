import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/shared/highlight_text.dart';

void main() {
  group('parseHighlight', () {
    test('splits marked and plain runs', () {
      expect(parseHighlight('The <mark>invoice</mark> total'), const [
        HighlightSegment('The '),
        HighlightSegment('invoice', marked: true),
        HighlightSegment(' total'),
      ]);
    });

    test('handles adjacent, leading and trailing marks', () {
      expect(parseHighlight('<mark>a</mark><mark>b</mark> c <mark>d</mark>'), const [
        HighlightSegment('ab', marked: true),
        HighlightSegment(' c '),
        HighlightSegment('d', marked: true),
      ]);
    });

    test('is case-insensitive and tolerates unbalanced tags', () {
      expect(parseHighlight('x <MARK>y'), const [
        HighlightSegment('x '),
        HighlightSegment('y', marked: true),
      ]);
      expect(parseHighlight('plain</mark>'), const [HighlightSegment('plain')]);
      expect(parseHighlight(''), isEmpty);
    });

    test('leaves other tags as text and strips only mark tags', () {
      expect(parseHighlight('<b>x</b> <mark>y</mark>'), const [
        HighlightSegment('<b>x</b> '),
        HighlightSegment('y', marked: true),
      ]);
      expect(stripHighlight('a <mark>b</mark> c'), 'a b c');
    });
  });
}
