import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/audit/guard_audit_subscriber.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  group('GuardAuditSubscriber', () {
    test('subscriber receives GuardBlockEvent and calls logVerdict', () async {
      final eventBus = EventBus();
      final logger = GuardAuditLogger();
      final subscriber = GuardAuditSubscriber(logger);
      subscriber.subscribe(eventBus);

      final records = <LogRecord>[];
      Logger('GuardAudit').onRecord.listen(records.add);

      eventBus.fire(
        GuardBlockEvent(
          guardName: 'TestGuard',
          guardCategory: 'test',
          verdict: 'block',
          verdictMessage: 'blocked!',
          hookPoint: 'beforeToolCall',
          rawProviderToolName: 'Bash',
          sessionId: 'sess-1',
          timestamp: DateTime.utc(2026, 1, 1),
        ),
      );

      await Future<void>.delayed(Duration.zero);

      expect(records, hasLength(1));
      expect(records.first.level, Level.SEVERE);
      expect(records.first.message, contains('verdict=block'));
      expect(records.first.message, contains('TestGuard'));

      await subscriber.cancel();
      await eventBus.dispose();
    });

    test('subscriber forwards raw provider tool name into persisted audit entry', () async {
      final tmpDir = Directory.systemTemp.createTempSync('guard_audit_subscriber_');
      addTearDown(() {
        if (tmpDir.existsSync()) {
          tmpDir.deleteSync(recursive: true);
        }
      });

      final eventBus = EventBus();
      final logger = GuardAuditLogger(dataDir: tmpDir.path);
      final subscriber = GuardAuditSubscriber(logger);
      subscriber.subscribe(eventBus);

      final timestamp = DateTime.utc(2026, 1, 2);
      eventBus.fire(
        GuardBlockEvent(
          guardName: 'ToolPolicyGuard',
          guardCategory: 'policy',
          verdict: 'block',
          verdictMessage: 'blocked!',
          hookPoint: 'beforeToolCall',
          rawProviderToolName: 'Bash',
          sessionId: 'sess-2',
          timestamp: timestamp,
        ),
      );

      await Future<void>.delayed(Duration.zero);
      await logger.cleanOldFiles(0);

      final auditFile = File('${tmpDir.path}/audit-${timestamp.toIso8601String().substring(0, 10)}.ndjson');
      final entry = jsonDecode(auditFile.readAsLinesSync().single) as Map<String, dynamic>;
      expect(entry['rawProviderToolName'], 'Bash');

      await subscriber.cancel();
      await eventBus.dispose();
    });

    test('subscriber handles warn verdicts', () async {
      final eventBus = EventBus();
      final logger = GuardAuditLogger();
      final subscriber = GuardAuditSubscriber(logger);
      subscriber.subscribe(eventBus);

      final records = <LogRecord>[];
      Logger('GuardAudit').onRecord.listen(records.add);

      eventBus.fire(
        GuardBlockEvent(
          guardName: 'WarnGuard',
          guardCategory: 'security',
          verdict: 'warn',
          verdictMessage: 'careful',
          hookPoint: 'messageReceived',
          timestamp: DateTime.utc(2026, 1, 1),
        ),
      );

      await Future<void>.delayed(Duration.zero);

      expect(records, hasLength(1));
      expect(records.first.level, Level.WARNING);
      expect(records.first.message, contains('verdict=warn'));

      await subscriber.cancel();
      await eventBus.dispose();
    });
  });
}
