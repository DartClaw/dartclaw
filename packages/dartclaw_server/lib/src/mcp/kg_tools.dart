import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';

typedef KgPrincipalProvider = String Function();
typedef KgGuardEvaluator = Future<GuardVerdict> Function(String tool, Map<String, dynamic> args, String principal);

const systemKgPrincipal = 'system';

/// MCP tool for adding source-linked temporal facts.
class KgAddTool implements McpTool {
  final TemporalKnowledgeGraphService kg;
  final GuardAuditLogger? auditLogger;
  final KgPrincipalProvider principalProvider;
  final KgGuardEvaluator? guardEvaluator;

  KgAddTool({required this.kg, this.auditLogger, KgPrincipalProvider? principalProvider, this.guardEvaluator})
    : principalProvider = principalProvider ?? _systemPrincipal;

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
    final principal = principalProvider();
    final guardFailure = await _guardFailureResult(
      guardEvaluator,
      auditLogger: auditLogger,
      tool: 'kg_add',
      args: args,
      principal: principal,
    );
    if (guardFailure != null) return guardFailure;
    final contradictions = kg.contradictions(
      entity: _string(args, 'entity'),
      predicate: _string(args, 'predicate'),
      value: _string(args, 'value'),
    );
    if (contradictions.isNotEmpty) {
      final failure = await _auditFailureResult(
        auditLogger,
        tool: 'kg_add',
        principal: principal,
        decision: 'deny',
        reason: 'contradiction',
      );
      if (failure != null) return failure;
      return _jsonText({'status': 'contradiction', 'contradictions': _contradictionsJson(contradictions)});
    }
    final entity = _string(args, 'entity');
    final predicate = _string(args, 'predicate');
    final failure = await _auditFailureResult(
      auditLogger,
      tool: 'kg_add',
      principal: principal,
      decision: 'allow',
      reason: 'entity=$entity predicate=$predicate',
    );
    if (failure != null) return failure;
    final id = kg.addFact(
      entity: entity,
      predicate: predicate,
      value: _string(args, 'value'),
      validFrom: _string(args, 'valid_from'),
      validTo: args['valid_to'] as String?,
      source: _string(args, 'source'),
      owner: principal,
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
  final KgPrincipalProvider principalProvider;
  final String stewardPrincipal;
  final KgGuardEvaluator? guardEvaluator;

  KgInvalidateTool({
    required this.kg,
    this.auditLogger,
    KgPrincipalProvider? principalProvider,
    this.stewardPrincipal = systemKgPrincipal,
    this.guardEvaluator,
  }) : principalProvider = principalProvider ?? _systemPrincipal;

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
    final principal = principalProvider();
    final id = (args['id'] as num).toInt();
    final reason = _string(args, 'reason');
    final guardFailure = await _guardFailureResult(
      guardEvaluator,
      auditLogger: auditLogger,
      tool: 'kg_invalidate',
      args: args,
      principal: principal,
    );
    if (guardFailure != null) return guardFailure;
    if (!kg.factExists(id)) {
      final failure = await _auditFailureResult(
        auditLogger,
        tool: 'kg_invalidate',
        principal: principal,
        decision: 'deny',
        reason: 'not_found',
      );
      if (failure != null) return failure;
      return _jsonText({'status': 'not_found', 'id': id});
    }
    final owner = kg.ownerForFact(id);
    if (owner == null && !_samePrincipal(principal, stewardPrincipal)) {
      final failure = await _auditFailureResult(
        auditLogger,
        tool: 'kg_invalidate',
        principal: principal,
        decision: 'deny',
        reason: 'legacy/system-owned fact requires steward principal',
      );
      if (failure != null) return failure;
      return _jsonText({'status': 'denied', 'id': id, 'reason': 'legacy/system-owned fact requires steward principal'});
    }
    if (owner != null && !_samePrincipal(owner, principal)) {
      final failure = await _auditFailureResult(
        auditLogger,
        tool: 'kg_invalidate',
        principal: principal,
        decision: 'deny',
        reason: 'principal does not own fact',
      );
      if (failure != null) return failure;
      return _jsonText({'status': 'denied', 'id': id, 'reason': 'principal does not own fact'});
    }
    final failure = await _auditFailureResult(
      auditLogger,
      tool: 'kg_invalidate',
      principal: principal,
      decision: 'allow',
      reason: 'fact_invalidated',
    );
    if (failure != null) return failure;
    final updated = kg.invalidate(id: id, invalidatedAt: _string(args, 'invalidated_at'), reason: reason);
    if (!updated) return _jsonText({'status': 'not_found', 'id': id});
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

String _systemPrincipal() => systemKgPrincipal;

bool _samePrincipal(String left, String right) => left.trim() == right.trim();

Future<ToolResult?> _guardFailureResult(
  KgGuardEvaluator? guardEvaluator, {
  required GuardAuditLogger? auditLogger,
  required String tool,
  required Map<String, dynamic> args,
  required String principal,
}) async {
  final evaluator = guardEvaluator;
  if (evaluator == null) return null;
  try {
    final verdict = await evaluator(tool, args, principal);
    if (!verdict.isBlock) return null;
    final reason = verdict.message ?? 'KG write denied';
    final failure = await _auditFailureResult(
      auditLogger,
      tool: tool,
      principal: principal,
      decision: 'deny',
      reason: reason,
    );
    if (failure != null) return failure;
    return _jsonText({'status': 'denied', 'decision': 'deny', 'reason': reason});
  } catch (error) {
    final failure = await _auditFailureResult(
      auditLogger,
      tool: tool,
      principal: principal,
      decision: 'deny',
      reason: 'guard failure: $error',
    );
    if (failure != null) return failure;
    return _jsonText(_auditFailurePayload('guard failure: $error'));
  }
}

Future<void> _auditKgDecision(
  GuardAuditLogger? auditLogger, {
  required String tool,
  required String principal,
  required String decision,
  String? reason,
}) async {
  if (auditLogger == null) return;
  await auditLogger.writeEntry(
    AuditEntry(
      timestamp: DateTime.now(),
      guard: 'KgWriteGuard',
      hook: 'mcp_tool_call',
      verdict: decision == 'allow' ? 'pass' : 'block',
      reason: reason,
      rawProviderToolName: tool,
      sessionId: principal,
      server: 'kg',
      tool: tool,
      decision: decision,
      principal: principal,
    ),
  );
}

Future<ToolResult?> _auditFailureResult(
  GuardAuditLogger? auditLogger, {
  required String tool,
  required String principal,
  required String decision,
  String? reason,
}) async {
  try {
    await _auditKgDecision(auditLogger, tool: tool, principal: principal, decision: decision, reason: reason);
    return null;
  } catch (error) {
    return _jsonText(_auditFailurePayload('audit failure: $error'));
  }
}

Map<String, Object?> _auditFailurePayload(String reason) => {'status': 'denied', 'decision': 'deny', 'reason': reason};
