/// One page of a paginated listing — the backend's
/// `{ "items": [...], "total", "page", "page_size" }` envelope.
class PageResult<T> {
  const PageResult({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  factory PageResult.fromJson(
    Map<String, dynamic> j,
    T Function(Map<String, dynamic> item) parse,
  ) {
    final items = (j['items'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => parse(m.cast<String, dynamic>()))
        .toList();
    return PageResult(
      items: items,
      total: (j['total'] as num?)?.toInt() ?? items.length,
      page: (j['page'] as num?)?.toInt() ?? 1,
      pageSize: (j['page_size'] as num?)?.toInt() ?? items.length,
    );
  }

  final List<T> items;
  final int total;
  final int page;
  final int pageSize;

  bool get hasMore => page * pageSize < total;
}
