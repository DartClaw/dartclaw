import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:dartclaw_server/src/mcp/kg_tools.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late TemporalKnowledgeGraphService kg;

  setUp(() {
    db = sqlite3.openInMemory();
    kg = TemporalKnowledgeGraphService(db);
  });

  tearDown(() {
    db.close();
  });

  test('S08 kg tools add query timeline invalidate lifecycle', () async {
    final add = KgAddTool(kg: kg);
    final query = KgQueryTool(kg: kg);
    final timeline = KgTimelineTool(kg: kg);
    final invalidate = KgInvalidateTool(kg: kg);

    final addResult = await add.call({
      'entity': 'GitHub Actions',
      'predicate': 'runner',
      'value': 'ubuntu-latest',
      'valid_from': '2026-05-01T00:00:00Z',
      'source': 'wiki/ci.md',
    });
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

    final invalidateResult = await invalidate.call({
      'id': addJson['id'],
      'invalidated_at': '2026-05-03T00:00:00Z',
      'reason': 'runner image changed',
    });
    expect(jsonDecode((invalidateResult as dynamic).content as String), containsPair('status', 'invalidated'));
  });

  test('S10 kg query no-result and contradiction are explicit', () async {
    kg.addFact(
      entity: 'Dart SDK',
      predicate: 'channel',
      value: 'stable',
      validFrom: '2026-05-01T00:00:00Z',
      source: 'wiki/dart.md',
    );

    final noResult = await KgQueryTool(kg: kg).call({'entity': 'Unknown System'});
    expect(jsonDecode((noResult as dynamic).content as String), containsPair('status', 'no_result'));

    final contradiction = await KgContradictionsTool(
      kg: kg,
    ).call({'entity': 'Dart SDK', 'predicate': 'channel', 'value': 'beta'});
    expect(jsonDecode((contradiction as dynamic).content as String), containsPair('status', 'contradiction'));
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

      final result = await add.call({
        'entity': 'Audit Test',
        'predicate': 'status',
        'value': 'active',
        'valid_from': '2026-01-01T00:00:00Z',
        'source': 'test',
      });
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
      kg.addFact(
        entity: 'Conflict Entity',
        predicate: 'status',
        value: 'active',
        validFrom: '2026-01-01T00:00:00Z',
        source: 'test',
      );

      final add = KgAddTool(kg: kg, auditLogger: auditLogger);
      final result = await add.call({
        'entity': 'Conflict Entity',
        'predicate': 'status',
        'value': 'inactive',
        'valid_from': '2026-01-01T00:00:00Z',
        'source': 'test',
      });
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
      final id = kg.addFact(
        entity: 'Invalidate Test',
        predicate: 'flag',
        value: 'on',
        validFrom: '2026-01-01T00:00:00Z',
        source: 'test',
      );

      final invalidate = KgInvalidateTool(kg: kg, auditLogger: auditLogger);
      final result = await invalidate.call({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'stale'});
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

      final result = await invalidate.call({'id': 404, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'missing'});
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

      final result = await add.call({
        'entity': 'Audit Failure',
        'predicate': 'status',
        'value': 'active',
        'valid_from': '2026-01-01T00:00:00Z',
        'source': 'test',
      });

      final json = jsonDecode((result as dynamic).content as String) as Map<String, dynamic>;
      expect(json['status'], 'denied');
      expect(json['decision'], 'deny');
      expect(kg.query(entity: 'Audit Failure', includeInvalidated: true), isEmpty);
    });

    test('S06 kg_add guard denial is audited and prevents mutation', () async {
      final add = KgAddTool(
        kg: kg,
        auditLogger: auditLogger,
        guardEvaluator: (_, _, _) async => GuardVerdict.block('kg writes disabled'),
      );

      final result = await add.call({
        'entity': 'Guarded Add',
        'predicate': 'status',
        'value': 'active',
        'valid_from': '2026-01-01T00:00:00Z',
        'source': 'test',
      });

      final json = jsonDecode((result as dynamic).content as String) as Map<String, dynamic>;
      expect(json['status'], 'denied');
      expect(json['reason'], 'kg writes disabled');
      expect(kg.query(entity: 'Guarded Add', includeInvalidated: true), isEmpty);

      final entry = jsonDecode(File(auditLogger.auditFilePath).readAsLinesSync().single) as Map<String, dynamic>;
      expect(entry['tool'], 'kg_add');
      expect(entry['decision'], 'deny');
      expect(entry['reason'], 'kg writes disabled');
    });

    test('S06 kg_invalidate guard denial is audited and prevents mutation', () async {
      final id = kg.addFact(
        entity: 'Guarded Invalidate',
        predicate: 'status',
        value: 'active',
        validFrom: '2026-01-01T00:00:00Z',
        source: 'test',
      );
      final invalidate = KgInvalidateTool(
        kg: kg,
        auditLogger: auditLogger,
        guardEvaluator: (_, _, _) async => GuardVerdict.block('kg writes disabled'),
      );

      final result = await invalidate.call({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'stale'});

      final json = jsonDecode((result as dynamic).content as String) as Map<String, dynamic>;
      expect(json['status'], 'denied');
      expect(json['reason'], 'kg writes disabled');
      expect(kg.query(entity: 'Guarded Invalidate', includeInvalidated: true).single.invalidatedAt, isNull);

      final entry = jsonDecode(File(auditLogger.auditFilePath).readAsLinesSync().single) as Map<String, dynamic>;
      expect(entry['tool'], 'kg_invalidate');
      expect(entry['decision'], 'deny');
      expect(entry['reason'], 'kg writes disabled');
    });

    test('C-03 kg_add guard exception attempts a deny audit before returning denied result', () async {
      final add = KgAddTool(
        kg: kg,
        auditLogger: auditLogger,
        guardEvaluator: (_, _, _) async => throw StateError('guard offline'),
      );

      final result = await add.call({
        'entity': 'Throwing Guard',
        'predicate': 'status',
        'value': 'active',
        'valid_from': '2026-01-01T00:00:00Z',
        'source': 'test',
      });

      final json = jsonDecode((result as dynamic).content as String) as Map<String, dynamic>;
      expect(json['status'], 'denied');
      expect(json['reason'], contains('guard failure'));
      expect(kg.query(entity: 'Throwing Guard', includeInvalidated: true), isEmpty);

      final entry = jsonDecode(File(auditLogger.auditFilePath).readAsLinesSync().single) as Map<String, dynamic>;
      expect(entry['tool'], 'kg_add');
      expect(entry['decision'], 'deny');
      expect(entry['reason'], contains('guard failure'));
    });

    test('S06 kg_invalidate does not write caller reason text into audit reason', () async {
      final id = kg.addFact(
        entity: 'Redaction Test',
        predicate: 'status',
        value: 'active',
        validFrom: '2026-01-01T00:00:00Z',
        source: 'test',
      );
      final invalidate = KgInvalidateTool(kg: kg, auditLogger: auditLogger);

      final result = await invalidate.call({
        'id': id,
        'invalidated_at': '2026-06-01T00:00:00Z',
        'reason': 'token=secret-value',
      });
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

      final result = await invalidate.call({
        'id': 999999,
        'invalidated_at': '2026-06-01T00:00:00Z',
        'reason': 'does not exist',
      });
      final json = jsonDecode((result as dynamic).content as String) as Map<String, dynamic>;
      expect(json['status'], 'not_found', reason: 'arbitrary IDs must be rejected, not silently accepted');
      expect(json['id'], 999999);
    });

    test('kg_invalidate accepts a valid existing fact ID', () async {
      final id = kg.addFact(
        entity: 'Scope Test',
        predicate: 'value',
        value: 'v1',
        validFrom: '2026-01-01T00:00:00Z',
        source: 'test',
      );

      final invalidate = KgInvalidateTool(kg: kg);
      final result = await invalidate.call({
        'id': id,
        'invalidated_at': '2026-06-01T00:00:00Z',
        'reason': 'superseded',
      });
      expect(jsonDecode((result as dynamic).content as String), containsPair('status', 'invalidated'));
    });

    test('S06/S08 kg_add records owner and kg_invalidate enforces ownership', () async {
      final add = KgAddTool(kg: kg, principalProvider: () => 'alice');
      final addResult = await add.call({
        'entity': 'Owned Fact',
        'predicate': 'status',
        'value': 'active',
        'valid_from': '2026-01-01T00:00:00Z',
        'source': 'test',
      });
      final id = (jsonDecode((addResult as dynamic).content as String) as Map<String, dynamic>)['id'] as int;
      expect(kg.ownerForFact(id), 'alice');

      final denied = await KgInvalidateTool(
        kg: kg,
        principalProvider: () => 'bob',
      ).call({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'not mine'});
      expect(jsonDecode((denied as dynamic).content as String), containsPair('status', 'denied'));
      expect(kg.query(entity: 'Owned Fact', includeInvalidated: true).single.invalidatedAt, isNull);

      final allowed = await KgInvalidateTool(
        kg: kg,
        principalProvider: () => 'alice',
      ).call({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'mine'});
      expect(jsonDecode((allowed as dynamic).content as String), containsPair('status', 'invalidated'));
    });

    test('S06/S08 legacy null-owner facts require steward principal', () async {
      db.execute(
        '''
        INSERT INTO kg_facts(entity, predicate, value, valid_from, source)
        VALUES (?, ?, ?, ?, ?)
        ''',
        ['legacy', 'status', 'active', '2026-01-01T00:00:00.000Z', 'legacy'],
      );
      final id = db.lastInsertRowId;

      final denied = await KgInvalidateTool(
        kg: kg,
        principalProvider: () => 'alice',
      ).call({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'not steward'});
      expect(jsonDecode((denied as dynamic).content as String), containsPair('status', 'denied'));

      final allowed = await KgInvalidateTool(
        kg: kg,
        principalProvider: () => systemKgPrincipal,
      ).call({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'steward'});
      expect(jsonDecode((allowed as dynamic).content as String), containsPair('status', 'invalidated'));
    });

    test('S04 production default (no principalProvider) attributes KG writes to the steward principal', () async {
      // Production wiring registers KG write tools without a principalProvider —
      // the deliberate S04 steward-only fallback for the single-token inbound /mcp
      // gateway (no per-caller identity). Pin it so the trust model cannot silently
      // change: writes run as the steward principal, a non-steward caller is denied,
      // and the steward default may invalidate.
      final add = KgAddTool(kg: kg);
      final addResult = await add.call({
        'entity': 'Steward Default Fact',
        'predicate': 'status',
        'value': 'active',
        'valid_from': '2026-01-01T00:00:00Z',
        'source': 'test',
      });
      final id = (jsonDecode((addResult as dynamic).content as String) as Map<String, dynamic>)['id'] as int;
      expect(kg.ownerForFact(id), systemKgPrincipal);

      final denied = await KgInvalidateTool(
        kg: kg,
        principalProvider: () => 'mallory',
      ).call({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'not steward'});
      expect(jsonDecode((denied as dynamic).content as String), containsPair('status', 'denied'));

      final allowed = await KgInvalidateTool(
        kg: kg,
      ).call({'id': id, 'invalidated_at': '2026-06-01T00:00:00Z', 'reason': 'steward default'});
      expect(jsonDecode((allowed as dynamic).content as String), containsPair('status', 'invalidated'));
    });
  });
}
