/// One entry of `GET /models` — a model whose provider is configured on the
/// server. `provider` is `openai | anthropic | google | azure | ollama | fake`.
class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.provider,
    required this.displayName,
    this.contextWindow,
    this.maxOutputTokens,
    this.supportsTools = true,
    this.supportsVision = false,
    this.supportsStreaming = true,
    this.inputUsdPer1m,
    this.outputUsdPer1m,
    this.tags = const [],
    this.isDefault = false,
  });

  factory ModelInfo.fromJson(Map<String, dynamic> j) {
    final id = (j['id'] as String?) ?? '';
    return ModelInfo(
      id: id,
      provider: (j['provider'] as String?) ?? 'unknown',
      displayName: (j['display_name'] as String?) ?? id,
      contextWindow: (j['context_window'] as num?)?.toInt(),
      maxOutputTokens: (j['max_output_tokens'] as num?)?.toInt(),
      supportsTools: j['supports_tools'] != false,
      supportsVision: j['supports_vision'] == true,
      supportsStreaming: j['supports_streaming'] != false,
      inputUsdPer1m: (j['input_usd_per_1m'] as num?)?.toDouble(),
      outputUsdPer1m: (j['output_usd_per_1m'] as num?)?.toDouble(),
      tags: (j['tags'] as List? ?? const []).map((e) => e.toString()).toList(),
      isDefault: j['is_default'] == true,
    );
  }

  final String id;
  final String provider;
  final String displayName;
  final int? contextWindow;
  final int? maxOutputTokens;
  final bool supportsTools;
  final bool supportsVision;
  final bool supportsStreaming;

  /// Price per one million input / output tokens, in USD (null when the
  /// server does not know it, e.g. a local model).
  final double? inputUsdPer1m;
  final double? outputUsdPer1m;
  final List<String> tags;
  final bool isDefault;

  /// `128k ctx` — compact context-window label, or null when unknown.
  String? get contextLabel {
    final ctx = contextWindow;
    if (ctx == null || ctx <= 0) return null;
    if (ctx >= 1000000) return '${_trim(ctx / 1000000)}M ctx';
    if (ctx >= 1000) return '${_trim(ctx / 1000)}k ctx';
    return '$ctx ctx';
  }

  /// `$0.15 / $0.60 per 1M` (input / output), or null when unpriced.
  String? get priceLabel {
    final i = inputUsdPer1m;
    final o = outputUsdPer1m;
    if (i == null && o == null) return null;
    String fmt(double? v) => v == null ? '—' : '\$${_money(v)}';
    return '${fmt(i)} / ${fmt(o)} per 1M';
  }

  static String _trim(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  static String _money(double v) {
    if (v == 0) return '0';
    if (v < 0.01) return v.toStringAsFixed(4);
    if (v < 1) return v.toStringAsFixed(2);
    return v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
  }
}

/// The `GET /models` response: the server-wide default plus every model the
/// user may pick. Empty when no provider is configured.
class ModelCatalog {
  const ModelCatalog({required this.items, this.defaultModel});

  factory ModelCatalog.fromJson(Map<String, dynamic> j) => ModelCatalog(
        defaultModel: j['default_model'] as String?,
        items: (j['items'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => ModelInfo.fromJson(m.cast<String, dynamic>()))
            .where((m) => m.id.isNotEmpty)
            .toList(),
      );

  static const empty = ModelCatalog(items: []);

  final List<ModelInfo> items;
  final String? defaultModel;

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;

  ModelInfo? byId(String? id) {
    if (id == null) return null;
    for (final m in items) {
      if (m.id == id) return m;
    }
    return null;
  }

  bool contains(String? id) => byId(id) != null;

  /// Display name for [id], falling back to the raw id.
  String labelFor(String? id) => byId(id)?.displayName ?? id ?? 'Default';

  /// The server default, or the entry flagged `is_default`, or the first one.
  String? get resolvedDefault {
    if (contains(defaultModel)) return defaultModel;
    for (final m in items) {
      if (m.isDefault) return m.id;
    }
    return items.isEmpty ? null : items.first.id;
  }
}

/// Picks the model id that acts as the user's default for new chats.
///
/// Order: the account's `default_model` (set through Settings on any
/// device), then the locally preferred one, then the server default — each
/// only when the catalog lists it, so the app never sends a model the
/// server would reject. Null when nothing is known (let the server decide).
String? resolveDefaultModel({
  required ModelCatalog? catalog,
  String? userDefault,
  String? preferred,
}) {
  if (catalog == null || catalog.isEmpty) return null;
  if (catalog.contains(userDefault)) return userDefault;
  if (catalog.contains(preferred)) return preferred;
  return catalog.resolvedDefault;
}
