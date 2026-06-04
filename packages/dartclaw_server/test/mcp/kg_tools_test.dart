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
      expect(entry['guard'], 'KgAdd');
      expect(entry['hook'], 'mcp_tool_call');
      expect(entry['verdict'], 'pass');
      expect(entry['rawProviderToolName'], 'kg_add');
    });

    test('kg_add does not emit audit record on contradiction', () async {
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
      // No write should have occurred — contradiction is not an add.
      if (auditFile.existsSync()) {
        final lines = auditFile.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
        expect(lines, isEmpty, reason: 'no audit entry expected for a contradiction rejection');
      }
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
      expect(entry['guard'], 'KgInvalidate');
      expect(entry['hook'], 'mcp_tool_call');
      expect(entry['verdict'], 'pass');
      expect(entry['rawProviderToolName'], 'kg_invalidate');
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
  });
}
