import 'package:flutter/material.dart';

/// A run of text from a search `highlight`; [marked] runs were wrapped in
/// `<mark>…</mark>` by the server.
class HighlightSegment {
  const HighlightSegment(this.text, {this.marked = false});
  final String text;
  final bool marked;

  @override
  bool operator ==(Object other) =>
      other is HighlightSegment && other.text == text && other.marked == marked;

  @override
  int get hashCode => Object.hash(text, marked);

  @override
  String toString() => marked ? '<mark>$text</mark>' : text;
}

final _markTag = RegExp(r'</?mark\s*>', caseSensitive: false);

/// Splits a `<mark>`-annotated snippet into plain / marked runs. Any other
/// tag is left as literal text (the server only emits `<mark>`); unbalanced
/// tags are tolerated.
List<HighlightSegment> parseHighlight(String snippet) {
  final out = <HighlightSegment>[];
  var marked = false;
  var last = 0;
  void push(String text, bool isMarked) {
    if (text.isEmpty) return;
    if (out.isNotEmpty && out.last.marked == isMarked) {
      out[out.length - 1] = HighlightSegment(out.last.text + text, marked: isMarked);
    } else {
      out.add(HighlightSegment(text, marked: isMarked));
    }
  }

  for (final m in _markTag.allMatches(snippet)) {
    push(snippet.substring(last, m.start), marked);
    marked = !m.group(0)!.startsWith('</');
    last = m.end;
  }
  push(snippet.substring(last), marked);
  return out;
}

/// Plain text of a highlight with the tags stripped.
String stripHighlight(String snippet) => snippet.replaceAll(_markTag, '');

/// Renders a `<mark>`-annotated snippet with the matches in bold.
class HighlightedText extends StatelessWidget {
  const HighlightedText(
    this.snippet, {
    super.key,
    this.style,
    this.markStyle,
    this.maxLines,
    this.overflow = TextOverflow.ellipsis,
  });

  final String snippet;
  final TextStyle? style;

  /// Style merged onto the marked runs (defaults to bold + primary text).
  final TextStyle? markStyle;
  final int? maxLines;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final mark = base.merge(
      markStyle ??
          TextStyle(
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
    );
    return Text.rich(
      TextSpan(
        children: [
          for (final seg in parseHighlight(snippet))
            TextSpan(text: seg.text, style: seg.marked ? mark : null),
        ],
      ),
      style: base,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
