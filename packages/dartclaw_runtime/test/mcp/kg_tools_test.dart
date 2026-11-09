import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/mcp/kg_tools.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

const _steward = McpCallerContext(authorityId: mcpStewardPrincipal, sourceEvent: 'test:kg');

void main() {
  late TemporalKnowledgeGraphService kg;

  setUp(() => kg = InMemoryTemporalKnowledgeGraphService());

  test('S08 kg tools add query timeline invalidate lifecycle', () async {
    final add = KgAddTool(kg: kg);
    final query = KgQueryTool(kg: kg);
    final timeline = KgTimelineTool(kg: kg);
    final invalidate = KgInvalidateTool(kg: kg);

    final addResult = await add.callWithContext({
      'entity': 'GitHub Actions',
      'predicate': 'runner',
      'value': 'ubuntu-latest',
      'valid_from': '2026-05-01T00:00:00Z',
      'source': 'wiki/ci.md',
    }, _steward);
    final addJson = jsonDecode((addResult as dynamic).content as String) as Map<String, dynamic>;
    expect(addJson['status'], 'added');

    final queryResult = await query.call({
      'entity': 'GitHub Actions',
      'predicate': 'runner',
      'as_of': '2026-05-02T00:00:00Z',
    });
    expect(jsonDecode((queryResult as dynamic).content as String), containsPair('status', 'ok'));

    final timelineResult = await timeline.call({'entity': 'GitHub Actions'});
    expect(jsonDecode((timelineResult as dynamic).content as String), containsPair('status', 'ok'));

    final invalidateResult = await invalidate.callWithContext({
      'id': addJson['id'],
      'invalidated_at': '2026-05-03T00:00:00Z',
      'reason': 'runner image changed',
    }, _steward);
    expect(jsonDecode((invalidateResult as dynamic).content as String), containsPair('status', 'invalidated'));
  });

  test('S10 kg query no-result and contradiction are explicit', () async {
    await kg.addFact(
      entity: 'Dart SDK',
      predicate: 'channel',
      value: 'stable',
      validFrom: '2026-05-01T00:00:00Z',
      source: 'wiki/dart.md',
    );

    final noResult = await KgQueryTool(kg: kg).call({'entity': 'Unknown System'});
    expect(jsonDecode((noResult as dynamic).content as String), containsPair('status', 'no_result'));

    final contradiction = await KgContradictionsTool(kg: kg)
        .call({'entity': 'Dart SDK', 'predicate': 'channel', 'value': 'beta'});
    expect(jsonDecode((contradiction as dynamic).content as String), containsPair('status', 'contradiction'));
  });

  test('direct shared reads preserve published content without disclosing private source provenance', () async {
    await kg.addFact(
      entity: 'Boundary',
      predicate: 'status',
      value: 'shared fact remains visible',
      validFrom: '2026-09-22T00:00:00Z',
      source: '/private/agent-a/MEMORY.md',
    );

    final query = await KgQueryTool(kg: kg).call({'entity': 'Boundary'});
    final timeline = await KgTimelineTool(kg: kg).call({'entity': 'Boundary'});
    final encoded = '${(query as ToolResultText).content}\n${(timeline as ToolResultText).content}';

    expect(encoded, contains('shared fact remains visible'));
    expect(encoded, contains('"source":"published"'));
    expect(encoded, isNot(contains('/private/agent-a/MEMORY.md')));
  });

  test('contextual durable writes honor a temporary-conversation refusal before mutation', () async {
    Future<ToolResult?> denyTemporary(McpCallerContext context) async => context.sessionId == 'temporary-session'
        ? const ToolResult.error('Temporary conversations cannot write durable knowledge')
        : null;
    const temporary = McpCallerContext(
      authorityId: 'agent:main',
      sourceEvent: 'test:temporary',
      sessionId: 'temporary-session',
      agentId: 'main',
    );
    final add = KgAddTool(kg: kg, contextualWriteGuard: denyTemporary);
    final addResult = await add.callWithContext({
      'entity': 'Temporary marker',
      'predicate': 'status',
      'value': 'must not persist',
      'valid_from': '2026-09-22T00:00:00Z',
      'source': 'temporary',
    }, temporary);

    expect(addResult, isA<ToolResultError>());
    expect(await kg.query(entity: 'Temporary marker', includeInvalidated: true), isEmpty);

    final id = await kg.addFact(
      entity: 'Existing',
      predicate: 'status',
      value: 'active',
      validFrom: '2026-09-22T00:00:00Z',
      source: 'published',
      owner: systemKgPrincipal,
    );
    final invalidate = KgInvalidateTool(kg: kg, contextualWriteGuard: denyTemporary);
    final invalidateResult = await invalidate.callWithContext({
      'id': id,
      'invalidated_at': '2026-09-22T01:00:00Z',
      'reason': 'temporary attempt',
    }, temporary);

    expect(invalidateResult, isA<ToolResultError>());
    expect((await kg.query(entity: 'Existing', includeInvalidated: true)).single.invalidatedAt, isNull);
  });

  group('F-04 audit logging', () {
    late Directory tempDir;
    late GuardAuditLogger auditLogger;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('kg_audit_test_');
      auditLogger = GuardAuditLogger(dataDir: tempDir.path);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('kg_add emits audit record on successful add', () async {
      final add = KgAddTool(kg: kg, auditLogger: auditLogger);

      final result = await add.callWithContext({
        'entity': 'Audit Test',
        'predicate': 'status',
        'value': 'active',
        'valid_from': '2026-01-01T00:00:00Z',
        'source': 'test',
      }, _steward);
      expect(jsonDecode((result as dynamic).content as String), containsPair('status', 'added'));

      // Flush the fire-and-forget write chain.
      await auditLogger.cleanOldFiles(0);

      final auditFile = File(auditLogger.auditFilePath);
      expect(auditFile.existsSync(), isTrue, reason: 'audit NDJSON file should be created');
      final lines = auditFile.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      expect(lines, isNotEmpty, reason: 'at least one audit entry expected');
      final entry = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(entry['guard'], 'KgWriteGuard');
      expect(entry['hook'], 'mcp_tool_call');
      expect(entry['verdict'], 'pass');
      expect(entry['rawProviderToolName'], 'kg_add');
      expect(entry['server'], 'kg');
      expect(entry['tool'], 'kg_add');
      expect(entry['decision'], 'allow');
    });

    test('S06 kg_add emits denied audit record on contradiction', () async {
      await kg.addFact(
        entity: 'Conflict Entity',
        predicate: 'status',
        value: 'active',
        validFrom: '2026-01-01T00:00:00Z',
        source: 'test',
      );

      final add = KgAddTool(kg: kg, auditLogger: auditLogger);
      final result = await add.callWithContext({
        'entity': 'Conflict Entity',
        'predicate': 'status',
        'value': 'inactive',
        'valid_from': '2026-01-01T00:00:00Z',
        'source': 'test',
      }, _steward);
      expect(jsonDecode((result as dynamic).content as String), containsPair('status', 'contradiction'));

      await auditLogger.cleanOldFiles(0);

      final auditFile = File(auditLogger.auditFilePath);
      expect(auditFile.existsSync(), isTrue);
      final lines = auditFile.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      expect(lines, hasLength(1));
      final entry = jsonDecode(lines.single) as Map<String, dynamic>;
      expect(entry['tool'], 'kg_add');
      expect(entry['decision'], 'deny');
      expect(entry['reason'], 'contradiction');
    });

    test('kg_invalidate emits audit record on successful invalidation', () async {
      final id = await kg.addFact(
        entity: 'Invalidate Test',
        predicate: 'flag',
        value: 'on',
        validFrom: '2026-01-01T00:00:00Z',
        source: 'test',
      );

      final invalidate = KgInvalidateTool(kg: kg, auditLogger: auditLogger);
      final result = await invalidate.callWithContext({
        'id': id,
        'invalidated_at': '2026-06-01T00:00:00Z',
        'reason': 'stale',
      }, _steward);
      expect(jsonDecode((result as dynamic).content as String), containsPair('status', 'invalidated'));

      await auditLogger.cleanOldFiles(0);

      final auditFile = File(auditLogger.auditFilePath);
      expect(auditFile.existsSync(), isTrue, reason: 'audit NDJSON file should be created');
      final lines = auditFile.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      expect(lines, isNotEmpty);
      final entry = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(entry['guard'], 'KgWriteGuard');
      expect(entry['hook'], 'mcp_tool_call');
      expect(entry['verdict'], 'pass');
      expect(entry['rawProviderToolName'], 'kg_invalidate');
      expect(entry['server'], 'kg');
      expect(entry['tool'], 'kg_invalidate');
      expect(entry['decision'], 'allow');
    });

    test('S06 kg_invalidate emits denied audit record on not-found', () async {
      final invalidate = KgInvalidateTool(kg: kg, auditLogger: auditLogger);

      final result = await invalidate.callWithContext({
        'id': 404,
        'invalidated_at': '2026-06-01T00:00:00Z',
        'reason': 'missing',
      }, _steward);
      expect(jsonDecode((result as dynamic).content as String), containsPair('status', 'not_found'));

      await auditLogger.cleanOldFiles(0);

      final entry = jsonDecode(File(auditLogger.auditFilePath).readAsLinesSync().single) as Map<String, dynamic>;
      expect(entry['tool'], 'kg_invalidate');
      expect(entry['decision'], 'deny');
      expect(entry['reason'], 'not_found');
    });

    test('S05 audit failure denies KG write before mutation', () async {
      final parent = Directory.systemTemp.createTempSync('kg_audit_fail_');
      final occupied = File('${parent.path}/not_a_directory')..writeAsStringSync('occupied');
      addTearDown(() {
        if (parent.existsSync()) parent.deleteSync(recursive: true);
      });
      final add = KgAddTool(
        kg: kg,
        auditLogger: GuardAuditLogger(dataDir: occupied.path),
      );

      final result = await add.callWithContext({
        'entity': 'Audit Failure',
        'predicate': 'status',
        'value': 'active',
        'valid_from': '2026-01-01T00:00:00Z',
        'source': 'test',
      }, _steward);

      final json = jsonDecode((result as dynamic).content as String) as Map<String, dynamic>;
      expect(json['status'], 'denied');
      expect(json['decision'], 'deny');
      expect(await kg.query(entity: 'Audit Failure', includeInvalidated: true), isEmpty);
    });

    test('S06 kg_invalidate does not write caller reason text into audit reason', () async {
      final id = await kg.addFact(
        entity: 'Redaction Test',
        predicate: 'status',
        value: 'active',
        validFrom: '2026-01-01T00:00:00Z',
        source: 'test',
      );
      final invalidate = KgInvalidateTool(kg: kg, auditLogger: auditLogger);

      final result = await invalidate.callWithContext({
        'id': id,
        'invalidated_at': '2026-06-01T00:00:00Z',
        'reason': 'token=secret-value',
      }, _steward);
      expect(jsonDecode((result as dynamic).content as String), containsPair('status', 'invalidated'));

      final entry = jsonDecode(File(auditLogger.auditFilePath).readAsLinesSync().single) as Map<String, dynamic>;
      expect(entry['decision'], 'allow');
      expect(entry['reason'], 'fact_invalidated');
      expect(jsonEncode(entry), isNot(contains('secret-value')));
    });
  });

  group('F-04 scope check', () {
    test('kg_invalidate rejects non-existent fact ID', () async {
      final invalidate = KgInvalidateTool(kg: kg);

      final result = await invalidate.callWithContext({
        'id': 999999,
        'invalidated_at': '2026-06-01T00:00:00Z',
        'reason': 'does not exist',
      }, _steward);
      final json = jsonDecode((result as dynamic).content as String) as Map<String, dynamic>;
      expect(json['status'], 'not_found', reason: 'arbitrary IDs must be rejected, not silently accepted');
      expect(json['id'], 999999);
    });

    test('kg_invalidate accepts a valid existing fact ID', () async {
      final id = await kg.addFact(
        entity: 'Scope Test',
        predicate: 'value',
        value: 'v1',
        validFrom: '2026-01-01T00:00:00Z',
        source: 'test',
      );

      final invalidate = KgInvalidateTool(kg: kg);
      final result = await invalidate.callWithContext({
        'id': id,
        'invalidated_at': '2026-06-01T00:00:00Z',
        'reason': 'superseded',
      }, _steward);
      expect(jsonDecode((result as dynamic).content as String), containsPair('status', 'invalidated'));
    });

    test('S06/S08 kg_add records owner and kg_invalidate enforces ownership', () async {
      final add = KgAddTool(kg: kg, principalProvider: () => 'alice');
      final addResult = await add.callWithContext({
        'entity': 'Owned Fact',
        'predicate': 'status',
        'value': 'active',
        'valid_from': '2026-01-01T00:00:00Z',
        'source': 'test',
      }, _steward);
      final id = (jsonDecode((addResult as dynamic).content as String) as Map<String, dynamic>)['id'] as int;
      expect(await kg.ownerForFact(id), 'alice');

      final denied = await KgInvalidateTool(
        kg: kg,
        principalProvider: () => 'bob',
      ).callWithContext({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'not mine'}, _steward);
      expect(jsonDecode((denied as dynamic).content as String), containsPair('status', 'denied'));
      expect((await kg.query(entity: 'Owned Fact', includeInvalidated: true)).single.invalidatedAt, isNull);

      final allowed = await KgInvalidateTool(
        kg: kg,
        principalProvider: () => 'alice',
      ).callWithContext({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'mine'}, _steward);
      expect(jsonDecode((allowed as dynamic).content as String), containsPair('status', 'invalidated'));
    });

    test('S06/S08 legacy null-owner facts require steward principal', () async {
      final id = await kg.addFact(
        entity: 'legacy',
        predicate: 'status',
        value: 'active',
        validFrom: '2026-01-01T00:00:00.000Z',
        source: 'legacy',
      );

      final denied = await KgInvalidateTool(
        kg: kg,
        principalProvider: () => 'alice',
      ).callWithContext({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'not steward'}, _steward);
      expect(jsonDecode((denied as dynamic).content as String), containsPair('status', 'denied'));

      final allowed = await KgInvalidateTool(
        kg: kg,
        principalProvider: () => systemKgPrincipal,
      ).callWithContext({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'steward'}, _steward);
      expect(jsonDecode((allowed as dynamic).content as String), containsPair('status', 'invalidated'));
    });

    test('S04 production default (no principalProvider) attributes KG writes to the steward principal', () async {
      // Production wiring registers KG write tools without a principalProvider —
      // the deliberate S04 steward-only fallback for the single-token inbound /mcp
      // gateway (no per-caller identity). Pin it so the trust model cannot silently
      // change: writes run as the steward principal, a non-steward caller is denied,
      // and the steward default may invalidate.
      final add = KgAddTool(kg: kg);
      final addResult = await add.callWithContext({
        'entity': 'Steward Default Fact',
        'predicate': 'status',
        'value': 'active',
        'valid_from': '2026-01-01T00:00:00Z',
        'source': 'test',
      }, _steward);
      final id = (jsonDecode((addResult as dynamic).content as String) as Map<String, dynamic>)['id'] as int;
      expect(await kg.ownerForFact(id), systemKgPrincipal);

      final denied = await KgInvalidateTool(
        kg: kg,
        principalProvider: () => 'mallory',
      ).callWithContext({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'not steward'}, _steward);
      expect(jsonDecode((denied as dynamic).content as String), containsPair('status', 'denied'));

      final allowed = await KgInvalidateTool(kg: kg)
          .callWithContext({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'steward default'}, _steward);
      expect(jsonDecode((allowed as dynamic).content as String), containsPair('status', 'invalidated'));
    });
  });
}
