import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

String _auditFilePathForDate(Directory dir, DateTime timestamp) =>
    '${dir.path}/audit-${timestamp.toIso8601String().substring(0, 10)}.ndjson';

Future<void> _flushAuditLogger(GuardAuditLogger logger) async {
  await logger.cleanOldFiles(0);
}

List<Map<String, dynamic>> _readAuditEntries(File file) {
  return file
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .map((line) => Map<String, dynamic>.from(jsonDecode(line) as Map))
      .toList();
}

DateTime _dateOnly(DateTime value) => DateTime(value.year, value.month, value.day);

void main() {
  group('GuardAuditLogger', () {
    late GuardAuditLogger logger;
    late List<LogRecord> records;

    setUp(() {
      logger = GuardAuditLogger();
      records = [];
      Logger('GuardAudit').onRecord.listen(records.add);
    });

    test('pass verdict logs at INFO level', () {
      logger.logVerdict(
        verdict: GuardVerdict.pass(),
        guardName: 'testGuard',
        guardCategory: 'test',
        hookPoint: 'beforeToolCall',
        timestamp: DateTime(2024, 1, 1),
      );
      expect(records, hasLength(1));
      expect(records.first.level, Level.INFO);
      expect(records.first.message, contains('[testGuard]'));
      expect(records.first.message, contains('verdict=pass'));
    });

    test('warn verdict logs at WARNING level', () {
      logger.logVerdict(
        verdict: GuardVerdict.warn('be careful'),
        guardName: 'warnGuard',
        guardCategory: 'security',
        hookPoint: 'messageReceived',
        timestamp: DateTime(2024, 1, 1),
      );
      expect(records, hasLength(1));
      expect(records.first.level, Level.WARNING);
      expect(records.first.message, contains('verdict=warn'));
      expect(records.first.message, contains('msg=be careful'));
    });

    test('block verdict logs at SEVERE level', () {
      logger.logVerdict(
        verdict: GuardVerdict.block('denied'),
        guardName: 'blockGuard',
        guardCategory: 'security',
        hookPoint: 'beforeAgentSend',
        timestamp: DateTime(2024, 1, 1),
      );
      expect(records, hasLength(1));
      expect(records.first.level, Level.SEVERE);
      expect(records.first.message, contains('verdict=block'));
      expect(records.first.message, contains('msg=denied'));
    });

    test('logVerdict accepts raw provider tool name', () {
      logger.logVerdict(
        verdict: GuardVerdict.block('denied'),
        guardName: 'blockGuard',
        guardCategory: 'security',
        hookPoint: 'beforeToolCall',
        timestamp: DateTime(2024, 1, 1),
        rawProviderToolName: 'Bash',
      );
      expect(records, hasLength(1));
      expect(records.first.message, contains('verdict=block'));
    });

    test('logPostToolUse logs success at INFO', () {
      logger.logPostToolUse(toolName: 'Bash', success: true, response: {'output': 'ok'});
      expect(records, hasLength(1));
      expect(records.first.level, Level.INFO);
      expect(records.first.message, contains('tool=Bash'));
      expect(records.first.message, contains('success=true'));
    });

    test('logPostToolUse logs failure at WARNING with error', () {
      logger.logPostToolUse(toolName: 'Read', success: false, response: {'error': 'not found'});
      expect(records, hasLength(1));
      expect(records.first.level, Level.WARNING);
      expect(records.first.message, contains('error=not found'));
    });
  });

  group('GuardAuditLogger file sink', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('guard_audit_test_');
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    test('file created on first write, not at construction', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final timestamp = DateTime.utc(2024, 1, 1);
      final file = File(_auditFilePathForDate(tmpDir, timestamp));
      expect(file.existsSync(), isFalse);

      logger.logVerdict(
        verdict: GuardVerdict.pass(),
        guardName: 'testGuard',
        guardCategory: 'test',
        hookPoint: 'beforeToolCall',
        timestamp: timestamp,
      );

      await _flushAuditLogger(logger);

      expect(file.existsSync(), isTrue);
    });

    test('logVerdict appends NDJSON line to the matching date-partitioned file', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final timestamp = DateTime.utc(2026, 3, 4, 10, 15, 30);

      logger.logVerdict(
        verdict: GuardVerdict.block('injection detected'),
        guardName: 'InputSanitizer',
        guardCategory: 'security',
        hookPoint: 'messageReceived',
        timestamp: timestamp,
        rawProviderToolName: 'Bash',
        sessionId: 'abc-123',
        channel: 'whatsapp',
        peerId: '+1234567890',
      );

      await _flushAuditLogger(logger);

      final file = File(_auditFilePathForDate(tmpDir, timestamp));
      expect(file.existsSync(), isTrue);

      final entries = _readAuditEntries(file);
      expect(entries, hasLength(1));

      final entry = entries.first;
      expect(entry['timestamp'], '2026-03-04T10:15:30.000Z');
      expect(entry['guard'], 'InputSanitizer');
      expect(entry['hook'], 'messageReceived');
      expect(entry['verdict'], 'block');
      expect(entry['reason'], 'injection detected');
      expect(entry['rawProviderToolName'], 'Bash');
      expect(entry['sessionId'], 'abc-123');
      expect(entry['channel'], 'whatsapp');
      expect(entry['peerId'], '+1234567890');
    });

    test('entry schema matches PRD — all fields present', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final timestamp = DateTime.utc(2026, 1, 1);

      logger.logVerdict(
        verdict: GuardVerdict.warn('suspicious'),
        guardName: 'ContentGuard',
        guardCategory: 'content',
        hookPoint: 'beforeAgentSend',
        timestamp: timestamp,
        rawProviderToolName: 'WebFetch',
        sessionId: 'sess-1',
        channel: 'web',
        peerId: 'user-42',
      );

      await _flushAuditLogger(logger);

      final file = File(_auditFilePathForDate(tmpDir, timestamp));
      final entry = _readAuditEntries(file).first;

      expect(entry.containsKey('timestamp'), isTrue);
      expect(entry.containsKey('guard'), isTrue);
      expect(entry.containsKey('hook'), isTrue);
      expect(entry.containsKey('verdict'), isTrue);
      expect(entry.containsKey('reason'), isTrue);
      expect(entry.containsKey('rawProviderToolName'), isTrue);
      expect(entry.containsKey('sessionId'), isTrue);
      expect(entry.containsKey('channel'), isTrue);
      expect(entry.containsKey('peerId'), isTrue);
    });

    test('null dataDir skips file write', () async {
      final logger = GuardAuditLogger();

      logger.logVerdict(
        verdict: GuardVerdict.pass(),
        guardName: 'g',
        guardCategory: 'c',
        hookPoint: 'beforeToolCall',
        timestamp: DateTime.now(),
      );

      expect(await logger.cleanOldFiles(7), 0);
    });

    test('pass verdict writes reason as null (omitted from JSON)', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final timestamp = DateTime.utc(2026, 1, 1);

      logger.logVerdict(
        verdict: GuardVerdict.pass(),
        guardName: 'g',
        guardCategory: 'c',
        hookPoint: 'beforeToolCall',
        timestamp: timestamp,
      );

      await _flushAuditLogger(logger);

      final file = File(_auditFilePathForDate(tmpDir, timestamp));
      final entry = _readAuditEntries(file).first;
      expect(entry.containsKey('reason'), isFalse);
    });

    test('session context fields included when provided', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final timestamp = DateTime.utc(2026, 1, 1);

      logger.logVerdict(
        verdict: GuardVerdict.pass(),
        guardName: 'g',
        guardCategory: 'c',
        hookPoint: 'messageReceived',
        timestamp: timestamp,
        sessionId: 'my-session',
        channel: 'signal',
        peerId: '+9876',
      );

      await _flushAuditLogger(logger);

      final file = File(_auditFilePathForDate(tmpDir, timestamp));
      final entry = _readAuditEntries(file).first;
      expect(entry['sessionId'], 'my-session');
      expect(entry['channel'], 'signal');
      expect(entry['peerId'], '+9876');
    });

    test('multiple verdicts append multiple lines', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final timestamp = DateTime.utc(2026, 1, 1);

      for (var i = 0; i < 5; i++) {
        logger.logVerdict(
          verdict: GuardVerdict.pass(),
          guardName: 'g$i',
          guardCategory: 'test',
          hookPoint: 'beforeToolCall',
          timestamp: timestamp,
        );
      }

      await _flushAuditLogger(logger);

      final file = File(_auditFilePathForDate(tmpDir, timestamp));
      expect(_readAuditEntries(file), hasLength(5));
    });
  });

  group('GuardAuditLogger date partitioning and retention', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('guard_audit_partition_');
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    test('entries on different dates go to separate files', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final firstDate = DateTime.utc(2026, 1, 1, 23, 59);
      final secondDate = DateTime.utc(2026, 1, 2, 0, 1);

      logger.logVerdict(
        verdict: GuardVerdict.pass(),
        guardName: 'first',
        guardCategory: 'test',
        hookPoint: 'beforeToolCall',
        timestamp: firstDate,
      );
      logger.logVerdict(
        verdict: GuardVerdict.pass(),
        guardName: 'second',
        guardCategory: 'test',
        hookPoint: 'beforeToolCall',
        timestamp: secondDate,
      );

      await _flushAuditLogger(logger);

      final firstFile = File(_auditFilePathForDate(tmpDir, firstDate));
      final secondFile = File(_auditFilePathForDate(tmpDir, secondDate));

      expect(_readAuditEntries(firstFile).single['guard'], 'first');
      expect(_readAuditEntries(secondFile).single['guard'], 'second');
    });

    test('cleanOldFiles deletes files older than the retention threshold', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final today = _dateOnly(DateTime.now());
      final expiredFile = File(_auditFilePathForDate(tmpDir, today.subtract(const Duration(days: 7))));
      final retainedFile = File(_auditFilePathForDate(tmpDir, today.subtract(const Duration(days: 6))));

      expiredFile.writeAsStringSync('{"guard":"expired"}\n');
      retainedFile.writeAsStringSync('{"guard":"retained"}\n');

      final deletedCount = await logger.cleanOldFiles(7);

      expect(deletedCount, 1);
      expect(expiredFile.existsSync(), isFalse);
      expect(retainedFile.existsSync(), isTrue);
    });

    test('cleanOldFiles keeps files within the retention threshold', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final today = _dateOnly(DateTime.now());
      final todayFile = File(_auditFilePathForDate(tmpDir, today));
      final retainedFile = File(_auditFilePathForDate(tmpDir, today.subtract(const Duration(days: 2))));

      todayFile.writeAsStringSync('{"guard":"today"}\n');
      retainedFile.writeAsStringSync('{"guard":"recent"}\n');

      final deletedCount = await logger.cleanOldFiles(3);

      expect(deletedCount, 0);
      expect(todayFile.existsSync(), isTrue);
      expect(retainedFile.existsSync(), isTrue);
    });

    test('cleanOldFiles ignores non-matching filenames', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final today = _dateOnly(DateTime.now());
      final expiredFile = File(_auditFilePathForDate(tmpDir, today.subtract(const Duration(days: 10))));
      final legacyFile = File('${tmpDir.path}/audit.ndjson');
      final malformedDateFile = File('${tmpDir.path}/audit-2026-13-40.ndjson');
      final unrelatedFile = File('${tmpDir.path}/notes.ndjson');

      expiredFile.writeAsStringSync('{"guard":"expired"}\n');
      legacyFile.writeAsStringSync('{"guard":"legacy"}\n');
      malformedDateFile.writeAsStringSync('{"guard":"bad-date"}\n');
      unrelatedFile.writeAsStringSync('{"guard":"other"}\n');

      final deletedCount = await logger.cleanOldFiles(7);

      expect(deletedCount, 1);
      expect(expiredFile.existsSync(), isFalse);
      expect(legacyFile.existsSync(), isTrue);
      expect(malformedDateFile.existsSync(), isTrue);
      expect(unrelatedFile.existsSync(), isTrue);
    });

    test('migration redistributes legacy audit.ndjson by entry date and deletes the old file', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final firstDate = DateTime.utc(2026, 3, 4, 10, 0);
      final secondDate = DateTime.utc(2026, 3, 5, 11, 30);
      final newDate = DateTime.utc(2026, 3, 4, 12, 45);
      final legacyFile = File('${tmpDir.path}/audit.ndjson');

      final legacyEntries = [
        AuditEntry(timestamp: firstDate, guard: 'legacy-a', hook: 'messageReceived', verdict: 'warn'),
        AuditEntry(timestamp: secondDate, guard: 'legacy-b', hook: 'beforeToolCall', verdict: 'block'),
      ];
      legacyFile.writeAsStringSync('${legacyEntries.map((entry) => jsonEncode(entry.toJson())).join('\n')}\n');

      logger.logVerdict(
        verdict: GuardVerdict.pass(),
        guardName: 'new-entry',
        guardCategory: 'test',
        hookPoint: 'beforeToolCall',
        timestamp: newDate,
      );

      await _flushAuditLogger(logger);

      final firstPartition = File(_auditFilePathForDate(tmpDir, firstDate));
      final secondPartition = File(_auditFilePathForDate(tmpDir, secondDate));

      expect(legacyFile.existsSync(), isFalse);
      expect(_readAuditEntries(firstPartition).map((entry) => entry['guard']).toList(), ['legacy-a', 'new-entry']);
      expect(_readAuditEntries(secondPartition).single['guard'], 'legacy-b');
    });

    test('migration is skipped when no legacy file exists', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final timestamp = DateTime.utc(2026, 4, 1, 9, 0);

      logger.logVerdict(
        verdict: GuardVerdict.pass(),
        guardName: 'entry-1',
        guardCategory: 'test',
        hookPoint: 'beforeToolCall',
        timestamp: timestamp,
      );
      logger.logVerdict(
        verdict: GuardVerdict.pass(),
        guardName: 'entry-2',
        guardCategory: 'test',
        hookPoint: 'beforeToolCall',
        timestamp: timestamp,
      );

      await _flushAuditLogger(logger);

      final file = File(_auditFilePathForDate(tmpDir, timestamp));
      expect(_readAuditEntries(file).map((entry) => entry['guard']).toList(), ['entry-1', 'entry-2']);
      expect(File('${tmpDir.path}/audit.ndjson').existsSync(), isFalse);
    });
  });

  group('GuardContext session fields', () {
    test('GuardContext accepts sessionId and peerId', () {
      final context = GuardContext(
        hookPoint: 'messageReceived',
        sessionId: 'sess-abc',
        peerId: '+1234',
        source: 'whatsapp',
        timestamp: DateTime.now(),
      );
      expect(context.sessionId, 'sess-abc');
      expect(context.peerId, '+1234');
    });

    test('GuardContext sessionId and peerId default to null', () {
      final context = GuardContext(hookPoint: 'beforeToolCall', timestamp: DateTime.now());
      expect(context.sessionId, isNull);
      expect(context.peerId, isNull);
    });

    test('evaluateMessageReceived passes session context via verdict callback', () async {
      GuardContext? capturedContext;
      final chain = GuardChain(
        guards: [_WarnGuard()],
        onVerdict: (_, _, _, _, context) {
          capturedContext = context;
        },
      );

      await chain.evaluateMessageReceived('hello', source: 'whatsapp', sessionId: 'sess-1', peerId: '+999');

      expect(capturedContext, isNotNull);
      expect(capturedContext!.sessionId, 'sess-1');
      expect(capturedContext!.source, 'whatsapp');
      expect(capturedContext!.peerId, '+999');
    });
  });

  group('AuditEntry', () {
    test('toJson includes all fields when set', () {
      final entry = AuditEntry(
        timestamp: DateTime.utc(2026, 3, 4, 10, 0, 0),
        guard: 'InputSanitizer',
        hook: 'messageReceived',
        verdict: 'block',
        reason: 'injection',
        sessionId: 'sess-1',
        channel: 'whatsapp',
        peerId: '+1234',
      );
      final json = entry.toJson();
      expect(json['timestamp'], '2026-03-04T10:00:00.000Z');
      expect(json['guard'], 'InputSanitizer');
      expect(json['hook'], 'messageReceived');
      expect(json['verdict'], 'block');
      expect(json['reason'], 'injection');
      expect(json['sessionId'], 'sess-1');
      expect(json['channel'], 'whatsapp');
      expect(json['peerId'], '+1234');
    });

    test('toJson omits null optional fields', () {
      final entry = AuditEntry(timestamp: DateTime.utc(2026, 1, 1), guard: 'g', hook: 'h', verdict: 'pass');
      final json = entry.toJson();
      expect(json.containsKey('reason'), isFalse);
      expect(json.containsKey('sessionId'), isFalse);
      expect(json.containsKey('channel'), isFalse);
      expect(json.containsKey('peerId'), isFalse);
    });
  });
}

class _WarnGuard extends Guard {
  @override
  String get name => 'warn';

  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async => GuardVerdict.warn('test warning');
}
