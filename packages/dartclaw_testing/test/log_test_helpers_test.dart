import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  group('captureRootLogs', () {
    late Level? previousLevel;

    setUp(() {
      previousLevel = Logger.root.level;
    });

    tearDown(() {
      Logger.root.level = previousLevel;
      Logger.root.clearListeners();
    });

    test('captures records emitted while the body runs', () async {
      final logger = Logger('captureRootLogs.captures');

      final records = await captureRootLogs(() async {
        logger.severe('expected failure');
      });

      expect(records, hasLength(1));
      expect(records.single.level, Level.SEVERE);
      expect(records.single.message, 'expected failure');
    });

    test('restores the root logger level after capture', () async {
      Logger.root.level = Level.WARNING;

      await captureRootLogs(() async {}, level: Level.FINE);

      expect(Logger.root.level, Level.WARNING);
    });

    test('is capture-only and preserves pre-existing root listeners', () async {
      final logger = Logger('captureRootLogs.listeners');
      final existingRecords = <LogRecord>[];
      final subscription = Logger.root.onRecord.listen(existingRecords.add);
      addTearDown(subscription.cancel);

      await captureRootLogs(() async {
        logger.warning('during capture');
      });
      logger.warning('after capture');

      expect(existingRecords.map((record) => record.message), ['during capture', 'after capture']);
    });

    test('captures only records at or above the configured level', () async {
      final logger = Logger('captureRootLogs.level');

      final records = await captureRootLogs(() async {
        logger.fine('ignored');
        logger.warning('captured');
      }, level: Level.WARNING);

      expect(records.map((record) => record.message), ['captured']);
    });
  });
}
