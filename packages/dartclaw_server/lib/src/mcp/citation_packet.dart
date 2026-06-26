/// Knowledge layer carried by a source reference in a citation packet.
enum CitationLayer {
  /// Synthesized wiki page source.
  wiki('wiki'),

  /// Temporal knowledge graph fact source.
  kg('kg'),

  /// FTS5/QMD memory chunk source.
  memory('memory'),

  /// Knowledge inbox file source.
  inbox('inbox');

  /// Stable JSON wire value.
  final String wireName;

  const CitationLayer(this.wireName);

  /// Parses [value] from the wire shape.
  static CitationLayer fromWire(String value) => switch (value) {
    'wiki' => CitationLayer.wiki,
    'kg' => CitationLayer.kg,
    'memory' => CitationLayer.memory,
    'inbox' => CitationLayer.inbox,
    _ => throw ArgumentError('unknown citation layer "$value"'),
  };
}

/// Resolvable reference to source material for a synthesized statement.
final class SourceRef {
  /// Source layer that owns [locator].
  final CitationLayer layer;

  /// Layer-local locator: wiki path, KG fact id, or memory source id.
  final String locator;

  /// Human-readable label shown to agents or UI renderers.
  final String label;

  /// Creates a source reference.
  const SourceRef({required this.layer, required this.locator, required this.label});

  /// Hydrates a source reference from JSON.
  factory SourceRef.fromJson(Map<String, dynamic> json) => SourceRef(
    layer: CitationLayer.fromWire(json['layer'] as String),
    locator: json['locator'] as String,
    label: json['label'] as String,
  );

  /// Converts this reference to the shared JSON wire shape.
  Map<String, dynamic> toJson() => {'layer': layer.wireName, 'locator': locator, 'label': label};
}

/// Synthesized statement with one or more source references.
final class CitationStatement {
  /// Statement text.
  final String text;

  /// Source references attached to this statement.
  final List<SourceRef> sourceRefs;

  /// Whether no attached reference resolved to live source material.
  final bool unattributed;

  /// Creates a cited statement.
  const CitationStatement({required this.text, required this.sourceRefs, this.unattributed = false});

  /// Hydrates a statement from JSON.
  factory CitationStatement.fromJson(Map<String, dynamic> json) => CitationStatement(
    text: json['text'] as String,
    sourceRefs: ((json['sourceRefs'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(SourceRef.fromJson)
        .toList(),
    unattributed: json['unattributed'] == true,
  );

  /// Converts this statement to the shared JSON wire shape.
  Map<String, dynamic> toJson() => {
    'text': text,
    'sourceRefs': sourceRefs.map((ref) => ref.toJson()).toList(),
    if (unattributed) 'unattributed': true,
  };
}

/// Compact synthesized packet returned by `context_research`.
final class CitationPacket {
  /// Cited statements retained in the packet.
  final List<CitationStatement> statements;

  /// Deduplicated source references used by [statements].
  final List<SourceRef> sourceList;

  /// Retrieval layers that failed during this call.
  final List<String> degradedLayers;

  /// True when retrieval found no matching source material.
  final bool noSourcesFound;

  /// Creates a citation packet.
  const CitationPacket({
    required this.statements,
    required this.sourceList,
    this.degradedLayers = const [],
    this.noSourcesFound = false,
  });

  /// Hydrates a citation packet from JSON.
  factory CitationPacket.fromJson(Map<String, dynamic> json) => CitationPacket(
    statements: ((json['statements'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(CitationStatement.fromJson)
        .toList(),
    sourceList: ((json['sourceList'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(SourceRef.fromJson)
        .toList(),
    degradedLayers: ((json['degradedLayers'] as List?) ?? const []).cast<String>(),
    noSourcesFound: json['noSourcesFound'] == true,
  );

  /// Converts this packet to the shared JSON wire shape.
  Map<String, dynamic> toJson() => {
    'statements': statements.map((statement) => statement.toJson()).toList(),
    'sourceList': sourceList.map((ref) => ref.toJson()).toList(),
    'degradedLayers': degradedLayers,
    'noSourcesFound': noSourcesFound,
  };
}

/// Shared locator resolver consumed by packet assembly and UI renderers.
abstract interface class CitationSourceResolver {
  /// Returns whether [ref] resolves to currently live source material.
  Future<bool> resolves(SourceRef ref);
}

/// Resolver backed by layer-local live locator sets.
final class CitationSourceIndexResolver implements CitationSourceResolver {
  final Set<String> _wikiLocators;
  final Set<String> _memoryLocators;
  final Set<String> _inboxLocators;
  final bool Function(int id) _kgFactExists;

  /// Creates a resolver over known live source locators.
  CitationSourceIndexResolver({
    Iterable<String> wikiLocators = const [],
    Iterable<String> memoryLocators = const [],
    Iterable<String> inboxLocators = const [],
    bool Function(int id)? kgFactExists,
  }) : _wikiLocators = Set.unmodifiable(wikiLocators),
       _memoryLocators = Set.unmodifiable(memoryLocators),
       _inboxLocators = Set.unmodifiable(inboxLocators),
       _kgFactExists = kgFactExists ?? ((_) => false);

  @override
  Future<bool> resolves(SourceRef ref) async {
    return switch (ref.layer) {
      CitationLayer.wiki => _wikiLocators.contains(ref.locator),
      CitationLayer.memory => _memoryLocators.contains(ref.locator),
      CitationLayer.inbox => _inboxLocators.contains(ref.locator),
      CitationLayer.kg => _resolvesKg(ref.locator),
    };
  }

  bool _resolvesKg(String locator) {
    final id = int.tryParse(locator);
    return id != null && _kgFactExists(id);
  }
}
