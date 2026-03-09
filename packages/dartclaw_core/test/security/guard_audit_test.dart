import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

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

    test('logPostToolUse logs success at INFO', () {
      logger.logPostToolUse(
        toolName: 'Bash',
        success: true,
        response: {'output': 'ok'},
      );
      expect(records, hasLength(1));
      expect(records.first.level, Level.INFO);
      expect(records.first.message, contains('tool=Bash'));
      expect(records.first.message, contains('success=true'));
    });

    test('logPostToolUse logs failure at WARNING with error', () {
      logger.logPostToolUse(
        toolName: 'Read',
        success: false,
        response: {'error': 'not found'},
      );
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

    test('file created on first write, not at construction', () {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final file = File('${tmpDir.path}/audit.ndjson');
      expect(file.existsSync(), isFalse);

      logger.logVerdict(
        verdict: GuardVerdict.pass(),
        guardName: 'testGuard',
        guardCategory: 'test',
        hookPoint: 'beforeToolCall',
        timestamp: DateTime(2024, 1, 1),
      );

      // Fire-and-forget: need to wait for async write.
      expect(
        Future.delayed(const Duration(milliseconds: 200), () => file.existsSync()),
        completion(isTrue),
      );
    });

    test('logVerdict appends NDJSON line to audit.ndjson', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);

      logger.logVerdict(
        verdict: GuardVerdict.block('injection detected'),
        guardName: 'InputSanitizer',
        guardCategory: 'security',
        hookPoint: 'messageReceived',
        timestamp: DateTime.utc(2026, 3, 4, 10, 15, 30),
        sessionId: 'abc-123',
        channel: 'whatsapp',
        peerId: '+1234567890',
      );

      // Wait for fire-and-forget write.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final file = File('${tmpDir.path}/audit.ndjson');
      expect(file.existsSync(), isTrue);

      final lines = file.readAsLinesSync().where((l) => l.isNotEmpty).toList();
      expect(lines, hasLength(1));

      final entry = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(entry['timestamp'], '2026-03-04T10:15:30.000Z');
      expect(entry['guard'], 'InputSanitizer');
      expect(entry['hook'], 'messageReceived');
      expect(entry['verdict'], 'block');
      expect(entry['reason'], 'injection detected');
      expect(entry['sessionId'], 'abc-123');
      expect(entry['channel'], 'whatsapp');
      expect(entry['peerId'], '+1234567890');
    });

    test('entry schema matches PRD — all fields present', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);

      logger.logVerdict(
        verdict: GuardVerdict.warn('suspicious'),
        guardName: 'ContentGuard',
        guardCategory: 'content',
        hookPoint: 'beforeAgentSend',
        timestamp: DateTime.utc(2026, 1, 1),
        sessionId: 'sess-1',
        channel: 'web',
        peerId: 'user-42',
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final line = File('${tmpDir.path}/audit.ndjson').readAsLinesSync().first;
      final entry = jsonDecode(line) as Map<String, dynamic>;

      expect(entry.containsKey('timestamp'), isTrue);
      expect(entry.containsKey('guard'), isTrue);
      expect(entry.containsKey('hook'), isTrue);
      expect(entry.containsKey('verdict'), isTrue);
      expect(entry.containsKey('reason'), isTrue);
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

      await Future<void>.delayed(const Duration(milliseconds: 100));

      // No file should exist in tmpDir (logger has no dataDir).
      expect(Directory.systemTemp.listSync().where(
        (e) => e.path.endsWith('audit.ndjson'),
      ), isEmpty);
    });

    test('pass verdict writes reason as null (omitted from JSON)', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);

      logger.logVerdict(
        verdict: GuardVerdict.pass(),
        guardName: 'g',
        guardCategory: 'c',
        hookPoint: 'beforeToolCall',
        timestamp: DateTime.utc(2026, 1, 1),
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final line = File('${tmpDir.path}/audit.ndjson').readAsLinesSync().first;
      final entry = jsonDecode(line) as Map<String, dynamic>;
      expect(entry.containsKey('reason'), isFalse);
    });

    test('session context fields included when provided', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);

      logger.logVerdict(
        verdict: GuardVerdict.pass(),
        guardName: 'g',
        guardCategory: 'c',
        hookPoint: 'messageReceived',
        timestamp: DateTime.utc(2026, 1, 1),
        sessionId: 'my-session',
        channel: 'signal',
        peerId: '+9876',
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final line = File('${tmpDir.path}/audit.ndjson').readAsLinesSync().first;
      final entry = jsonDecode(line) as Map<String, dynamic>;
      expect(entry['sessionId'], 'my-session');
      expect(entry['channel'], 'signal');
      expect(entry['peerId'], '+9876');
    });

    test('multiple verdicts append multiple lines', () async {
      final logger = GuardAuditLogger(dataDir: tmpDir.path);

      for (var i = 0; i < 5; i++) {
        logger.logVerdict(
          verdict: GuardVerdict.pass(),
          guardName: 'g$i',
          guardCategory: 'test',
          hookPoint: 'beforeToolCall',
          timestamp: DateTime.utc(2026, 1, 1),
        );
      }

      // Fire-and-forget writes are sequential per-entry — wait for all.
      await Future<void>.delayed(const Duration(milliseconds: 2000));

      final lines = File('${tmpDir.path}/audit.ndjson')
          .readAsLinesSync()
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines, hasLength(5));
    });
  });

  group('GuardAuditLogger rotation', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('guard_audit_rotation_');
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    test('rotation triggered after maxEntries exceeded', () async {
      final maxEntries = 20;
      final logger = GuardAuditLogger(
        dataDir: tmpDir.path,
        maxEntries: maxEntries,
        rotationCheckInterval: 5,
      );

      // Write more than maxEntries.
      for (var i = 0; i < maxEntries + 10; i++) {
        logger.logVerdict(
          verdict: GuardVerdict.pass(),
          guardName: 'g',
          guardCategory: 'test',
          hookPoint: 'beforeToolCall',
          timestamp: DateTime.utc(2026, 1, 1),
        );
      }

      // Wait for all fire-and-forget writes + rotation to complete.
      await Future<void>.delayed(const Duration(milliseconds: 1000));

      final lines = File('${tmpDir.path}/audit.ndjson')
          .readAsLinesSync()
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines.length, lessThanOrEqualTo(maxEntries));
    });

    test('rotation keeps newest entries, drops oldest', () async {
      final maxEntries = 10;
      final logger = GuardAuditLogger(
        dataDir: tmpDir.path,
        maxEntries: maxEntries,
        rotationCheckInterval: 5,
      );

      // Write numbered entries.
      for (var i = 0; i < maxEntries + 10; i++) {
        logger.logVerdict(
          verdict: GuardVerdict.pass(),
          guardName: 'guard-$i',
          guardCategory: 'test',
          hookPoint: 'beforeToolCall',
          timestamp: DateTime.utc(2026, 1, 1),
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 1000));

      final lines = File('${tmpDir.path}/audit.ndjson')
          .readAsLinesSync()
          .where((l) => l.isNotEmpty)
          .toList();

      // The last entry should contain the highest guard number.
      final lastEntry = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(lastEntry['guard'], contains('guard-'));

      // First entry should NOT be guard-0 (it was dropped).
      final firstEntry = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(firstEntry['guard'], isNot('guard-0'));
    });

    test('no .tmp file left after rotation', () async {
      final logger = GuardAuditLogger(
        dataDir: tmpDir.path,
        maxEntries: 5,
        rotationCheckInterval: 3,
      );

      for (var i = 0; i < 20; i++) {
        logger.logVerdict(
          verdict: GuardVerdict.pass(),
          guardName: 'g',
          guardCategory: 'test',
          hookPoint: 'beforeToolCall',
          timestamp: DateTime.utc(2026, 1, 1),
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 1000));

      final tmpFile = File('${tmpDir.path}/audit.ndjson.tmp');
      expect(tmpFile.existsSync(), isFalse);
    });

    test('rotation check amortized to every N writes', () async {
      // With rotationCheckInterval=100 and only 10 writes, rotation should
      // NOT be checked even if file has more entries than maxEntries.
      final logger = GuardAuditLogger(
        dataDir: tmpDir.path,
        maxEntries: 5,
        rotationCheckInterval: 100,
      );

      // Pre-populate file with more than maxEntries.
      final file = File('${tmpDir.path}/audit.ndjson');
      final prePopulated = StringBuffer();
      for (var i = 0; i < 20; i++) {
        prePopulated.writeln(jsonEncode({'guard': 'old-$i', 'verdict': 'pass'}));
      }
      file.writeAsStringSync(prePopulated.toString());

      // Write only 10 more (less than rotationCheckInterval of 100).
      for (var i = 0; i < 10; i++) {
        logger.logVerdict(
          verdict: GuardVerdict.pass(),
          guardName: 'new-$i',
          guardCategory: 'test',
          hookPoint: 'beforeToolCall',
          timestamp: DateTime.utc(2026, 1, 1),
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 2000));

      // File should still have all 30 lines (20 pre-populated + 10 new).
      final lines = file.readAsLinesSync().where((l) => l.isNotEmpty).toList();
      expect(lines.length, 30);
    });
  });

  group('GuardContext session fields', () {
    test('GuardContext accepts sessionId and peerId', () {
      final ctx = GuardContext(
        hookPoint: 'messageReceived',
        sessionId: 'sess-abc',
        peerId: '+1234',
        source: 'whatsapp',
        timestamp: DateTime.now(),
      );
      expect(ctx.sessionId, 'sess-abc');
      expect(ctx.peerId, '+1234');
    });

    test('GuardContext sessionId and peerId default to null', () {
      final ctx = GuardContext(
        hookPoint: 'beforeToolCall',
        timestamp: DateTime.now(),
      );
      expect(ctx.sessionId, isNull);
      expect(ctx.peerId, isNull);
    });

    test('evaluateMessageReceived passes session context to audit', () async {
      final capturedEntries = <({String? sessionId, String? channel, String? peerId})>[];

      final auditLogger = _CapturingAuditLogger(capturedEntries);
      final chain = GuardChain(
        guards: [
          _PassGuard(),
        ],
        auditLogger: auditLogger,
      );

      await chain.evaluateMessageReceived(
        'hello',
        source: 'whatsapp',
        sessionId: 'sess-1',
        peerId: '+999',
      );

      expect(capturedEntries, hasLength(1));
      expect(capturedEntries.first.sessionId, 'sess-1');
      expect(capturedEntries.first.channel, 'whatsapp');
      expect(capturedEntries.first.peerId, '+999');
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
      final entry = AuditEntry(
        timestamp: DateTime.utc(2026, 1, 1),
        guard: 'g',
        hook: 'h',
        verdict: 'pass',
      );
      final json = entry.toJson();
      expect(json.containsKey('reason'), isFalse);
      expect(json.containsKey('sessionId'), isFalse);
      expect(json.containsKey('channel'), isFalse);
      expect(json.containsKey('peerId'), isFalse);
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

class _CapturingAuditLogger extends GuardAuditLogger {
  final List<({String? sessionId, String? channel, String? peerId})> entries;

  _CapturingAuditLogger(this.entries);

  @override
  void logVerdict({
    required GuardVerdict verdict,
    required String guardName,
    required String guardCategory,
    required String hookPoint,
    required DateTime timestamp,
    String? sessionId,
    String? channel,
    String? peerId,
  }) {
    entries.add((sessionId: sessionId, channel: channel, peerId: peerId));
  }
}

class _PassGuard extends Guard {
  @override
  String get name => 'pass';
  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async => GuardVerdict.pass();
}
