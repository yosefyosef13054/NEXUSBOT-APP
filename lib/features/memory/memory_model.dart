import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

/// What kind of thing a memory is.
enum MemoryKind {
  fact,
  preference,
  instruction;

  static MemoryKind fromString(String? s) =>
      MemoryKind.values.firstWhereOrNull((k) => k.name == s) ?? MemoryKind.fact;

  String get label => switch (this) {
        MemoryKind.fact => 'Facts',
        MemoryKind.preference => 'Preferences',
        MemoryKind.instruction => 'Instructions',
      };

  String get singular => switch (this) {
        MemoryKind.fact => 'Fact',
        MemoryKind.preference => 'Preference',
        MemoryKind.instruction => 'Instruction',
      };

  IconData get icon => switch (this) {
        MemoryKind.fact => Icons.lightbulb_outline_rounded,
        MemoryKind.preference => Icons.favorite_outline_rounded,
        MemoryKind.instruction => Icons.rule_rounded,
      };
}

/// One thing NexusBot remembers about the user (`MemoryRead`): extracted
/// after turns or added by hand, injected into later conversations.
class Memory {
  const Memory({
    required this.id,
    required this.content,
    required this.kind,
    required this.importance,
    this.sourceMessageId,
    this.createdAt,
    this.lastUsedAt,
  });

  factory Memory.fromJson(Map<String, dynamic> j) => Memory(
        id: j['id'] as String,
        content: (j['content'] as String?) ?? '',
        kind: MemoryKind.fromString(j['kind'] as String?),
        importance: ((j['importance'] as num?)?.toInt() ?? 3).clamp(1, 5),
        sourceMessageId: j['source_message_id'] as String?,
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
        lastUsedAt: DateTime.tryParse(j['last_used_at'] as String? ?? ''),
      );

  final String id;
  final String content;
  final MemoryKind kind;

  /// 1 (trivia) … 5 (always inject).
  final int importance;

  /// The message the memory was extracted from, if any.
  final String? sourceMessageId;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;
}
