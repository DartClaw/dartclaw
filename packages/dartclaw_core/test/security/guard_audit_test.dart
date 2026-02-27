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
}
