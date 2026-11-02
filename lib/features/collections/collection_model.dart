/// A knowledge base: a named group of documents that a chat can be scoped
/// to (`session.meta.collection_ids` / per-turn `collection_ids`).
class Collection {
  const Collection({
    required this.id,
    required this.name,
    required this.documentCount,
    required this.createdAt,
    required this.updatedAt,
    this.description,
  });

  factory Collection.fromJson(Map<String, dynamic> j) => Collection(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Untitled',
        description: j['description'] as String?,
        documentCount: (j['document_count'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? '') ?? DateTime.now(),
      );

  final String id;
  final String name;
  final String? description;
  final int documentCount;
  final DateTime createdAt;
  final DateTime updatedAt;
}
