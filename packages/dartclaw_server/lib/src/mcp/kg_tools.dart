import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';

/// MCP tool for adding source-linked temporal facts.
class KgAddTool implements McpTool {
  final TemporalKnowledgeGraphService kg;
  final GuardAuditLogger? auditLogger;

  KgAddTool({required this.kg, this.auditLogger});

  @override
  String get name => 'kg_add';

  @override
  String get description => 'Add a source-linked temporal fact to the knowledge graph.';

  @override
  Map<String, dynamic> get inputSchema => _schema(
    {
      'entity': {'type': 'string'},
      'predicate': {'type': 'string'},
      'value': {'type': 'string'},
      'valid_from': {'type': 'string'},
      'valid_to': {'type': 'string'},
      'source': {'type': 'string'},
    },
    ['entity', 'predicate', 'value', 'valid_from', 'source'],
  );

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final contradictions = kg.contradictions(
      entity: _string(args, 'entity'),
      predicate: _string(args, 'predicate'),
      value: _string(args, 'value'),
    );
    if (contradictions.isNotEmpty) {
      return _jsonText({'status': 'contradiction', 'contradictions': _contradictionsJson(contradictions)});
    }
    final entity = _string(args, 'entity');
    final predicate = _string(args, 'predicate');
    final id = kg.addFact(
      entity: entity,
      predicate: predicate,
      value: _string(args, 'value'),
      validFrom: _string(args, 'valid_from'),
      validTo: args['valid_to'] as String?,
      source: _string(args, 'source'),
    );
    auditLogger?.logVerdict(
      verdict: GuardVerdict.pass(),
      guardName: 'KgAdd',
      guardCategory: 'mcp_write',
      hookPoint: 'mcp_tool_call',
      timestamp: DateTime.now().toUtc(),
      rawProviderToolName: 'kg_add',
      sessionId: 'entity=$entity predicate=$predicate id=$id',
    );
    return _jsonText({'status': 'added', 'id': id});
  }
}

/// MCP tool for querying valid facts.
class KgQueryTool implements McpTool {
  final TemporalKnowledgeGraphService kg;

  KgQueryTool({required this.kg});

  @override
  String get name => 'kg_query';

  @override
  String get description => 'Query temporal knowledge graph facts by entity, predicate, and optional as_of timestamp.';

  @override
  Map<String, dynamic> get inputSchema => _schema(
    {
      'entity': {'type': 'string'},
      'predicate': {'type': 'string'},
      'as_of': {'type': 'string'},
      'include_invalidated': {'type': 'boolean'},
    },
    ['entity'],
  );

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final facts = kg.query(
      entity: _string(args, 'entity'),
      predicate: args['predicate'] as String?,
      asOf: args['as_of'] as String?,
      includeInvalidated: args['include_invalidated'] == true,
    );
    if (facts.isEmpty) return _jsonText({'status': 'no_result', 'facts': []});
    return _jsonText({'status': 'ok', 'facts': _factsJson(facts)});
  }
}

/// MCP tool for returning a fact timeline.
class KgTimelineTool implements McpTool {
  final TemporalKnowledgeGraphService kg;

  KgTimelineTool({required this.kg});

  @override
  String get name => 'kg_timeline';

  @override
  String get description => 'Return the full temporal fact timeline for an entity.';

  @override
  Map<String, dynamic> get inputSchema => _schema(
    {
      'entity': {'type': 'string'},
      'predicate': {'type': 'string'},
    },
    ['entity'],
  );

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final facts = kg.timeline(entity: _string(args, 'entity'), predicate: args['predicate'] as String?);
    if (facts.isEmpty) return _jsonText({'status': 'no_result', 'facts': []});
    return _jsonText({'status': 'ok', 'facts': _factsJson(facts)});
  }
}

/// MCP tool for invalidating a fact while preserving history.
class KgInvalidateTool implements McpTool {
  final TemporalKnowledgeGraphService kg;
  final GuardAuditLogger? auditLogger;

  KgInvalidateTool({required this.kg, this.auditLogger});

  @override
  String get name => 'kg_invalidate';

  @override
  String get description => 'Invalidate a temporal fact without deleting its history.';

  @override
  Map<String, dynamic> get inputSchema => _schema(
    {
      'id': {'type': 'number'},
      'invalidated_at': {'type': 'string'},
      'reason': {'type': 'string'},
    },
    ['id', 'invalidated_at', 'reason'],
  );

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final id = (args['id'] as num).toInt();
    final reason = _string(args, 'reason');
    final updated = kg.invalidate(id: id, invalidatedAt: _string(args, 'invalidated_at'), reason: reason);
    if (!updated) {
      // Fact does not exist — reject rather than silently accepting an arbitrary ID.
      return _jsonText({'status': 'not_found', 'id': id});
    }
    auditLogger?.logVerdict(
      verdict: GuardVerdict.pass(),
      guardName: 'KgInvalidate',
      guardCategory: 'mcp_write',
      hookPoint: 'mcp_tool_call',
      timestamp: DateTime.now().toUtc(),
      rawProviderToolName: 'kg_invalidate',
      sessionId: 'id=$id reason=$reason',
    );
    return _jsonText({'status': 'invalidated'});
  }
}

/// MCP tool for cheap contradiction pre-screening.
class KgContradictionsTool implements McpTool {
  final TemporalKnowledgeGraphService kg;

  KgContradictionsTool({required this.kg});

  @override
  String get name => 'kg_contradictions';

  @override
  String get description => 'Find open facts that would contradict an incoming fact.';

  @override
  Map<String, dynamic> get inputSchema => _schema(
    {
      'entity': {'type': 'string'},
      'predicate': {'type': 'string'},
      'value': {'type': 'string'},
    },
    ['entity', 'predicate', 'value'],
  );

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final contradictions = kg.contradictions(
      entity: _string(args, 'entity'),
      predicate: _string(args, 'predicate'),
      value: _string(args, 'value'),
    );
    final status = contradictions.isEmpty ? 'ok' : 'contradiction';
    return _jsonText({'status': status, 'contradictions': _contradictionsJson(contradictions)});
  }
}

ToolResult _jsonText(Map<String, Object?> payload) => ToolResult.text(jsonEncode(payload));

List<Map<String, Object?>> _factsJson(List<KnowledgeFact> facts) => facts.map((fact) => fact.toJson()).toList();

List<Map<String, Object?>> _contradictionsJson(List<KnowledgeContradiction> contradictions) =>
    contradictions.map((contradiction) => contradiction.toJson()).toList();

Map<String, dynamic> _schema(Map<String, dynamic> properties, List<String> required) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};

String _string(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is! String || value.trim().isEmpty) {
    throw ArgumentError('$key must be a non-empty string');
  }
  return value;
}
