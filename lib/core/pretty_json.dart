import 'dart:convert';

const _indent = JsonEncoder.withIndent('  ');

/// Human-readable rendering of a tool input / output.
///
/// Maps and lists are pretty-printed as JSON; a string that *contains* JSON
/// is decoded and pretty-printed too; anything else is shown as-is.
String prettyJson(Object? value) {
  if (value == null) return '';
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return _indent.convert(jsonDecode(trimmed));
      } on FormatException {
        return value;
      }
    }
    return value;
  }
  if (value is Map || value is List) {
    try {
      return _indent.convert(value);
    } catch (_) {
      return value.toString();
    }
  }
  return value.toString();
}
