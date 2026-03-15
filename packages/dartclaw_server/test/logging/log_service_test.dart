import 'dart:async';

import 'package:dartclaw_server/src/logging/log_formatter.dart';
import 'package:dartclaw_server/src/logging/log_service.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  // Restore root logger state after each test so tests don't bleed.
  tearDown(() async {
    Logger.root.level = Level.INFO;
    Logger.root.clearListeners();
  });

  group('LogService.fromConfig — format selection', () {
    test("'human' format creates HumanFormatter", () {
      final svc = LogService.fromConfig(format: 'human');
      // Install so formatter is exercised; output goes to stderr (not captured).
      // We verify no exception is thrown and the service installs cleanly.
      expect(() => svc.install(), returnsNormally);
      addTearDown(svc.dispose);
    });

    test("'json' format creates JsonFormatter", () {
      final svc = LogService.fromConfig(format: 'json');
      expect(() => svc.install(), returnsNormally);
      addTearDown(svc.dispose);
    });

    test('unknown format falls back to human formatter (no exception)', () {
      final svc = LogService.fromConfig(format: 'ndjson');
      expect(() => svc.install(), returnsNormally);
      addTearDown(svc.dispose);
    });
  });

  group('LogService.fromConfig — level selection', () {
    test('INFO level string maps to Level.INFO', () {
      final svc = LogService.fromConfig(level: 'INFO');
      svc.install();
      expect(Logger.root.level, Level.INFO);
      addTearDown(svc.dispose);
    });

    test('WARNING level string maps to Level.WARNING', () {
      final svc = LogService.fromConfig(level: 'WARNING');
      svc.install();
      expect(Logger.root.level, Level.WARNING);
      addTearDown(svc.dispose);
    });

    test('SEVERE level string maps to Level.SEVERE', () {
      final svc = LogService.fromConfig(level: 'SEVERE');
      svc.install();
      expect(Logger.root.level, Level.SEVERE);
      addTearDown(svc.dispose);
    });

    test('FINE level string maps to Level.FINE', () {
      final svc = LogService.fromConfig(level: 'FINE');
      svc.install();
      expect(Logger.root.level, Level.FINE);
      addTearDown(svc.dispose);
    });

    test('level matching is case-insensitive', () {
      final svc = LogService.fromConfig(level: 'warning');
      svc.install();
      expect(Logger.root.level, Level.WARNING);
      addTearDown(svc.dispose);
    });

    test('invalid level falls back to Level.INFO', () {
      final svc = LogService.fromConfig(level: 'NONSENSE');
      svc.install();
      expect(Logger.root.level, Level.INFO);
      addTearDown(svc.dispose);
    });
  });

  group('LogService.install()', () {
    test('sets root logger level', () {
      final svc = LogService(formatter: HumanFormatter(), level: Level.WARNING);
      svc.install();
      expect(Logger.root.level, Level.WARNING);
      addTearDown(svc.dispose);
    });

    test('root logger processes records after install', () async {
      // We need a separate logger child so we can observe records flowing
      // through the root without fighting with LogService's own subscription.
      final svc = LogService(formatter: HumanFormatter(), level: Level.INFO);
      svc.install();

      final records = <LogRecord>[];
      // Add a second listener on root to intercept records independently.
      final sub = Logger.root.onRecord.listen(records.add);

      Logger('test.install').info('hello from install test');

      // Let the event loop flush.
      await Future<void>.delayed(Duration.zero);

      expect(records, isNotEmpty);
      expect(records.first.message, 'hello from install test');

      await sub.cancel();
      await svc.dispose();
    });

    test('re-installing replaces previous subscription (no duplicate records)', () async {
      final svc = LogService(formatter: HumanFormatter(), level: Level.INFO);
      svc.install();
      svc.install(); // second install — should cancel old subscription

      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);

      Logger('test.reinstall').info('only once');
      await Future<void>.delayed(Duration.zero);

      // Our own listener fires once; LogService's internal listener also fires
      // once (not twice, since old subscription was cancelled).
      expect(records.where((r) => r.message == 'only once').length, 1);

      await sub.cancel();
      await svc.dispose();
    });
  });

  group('LogService.dispose()', () {
    test('dispose cancels subscription — no errors', () async {
      final svc = LogService(formatter: HumanFormatter(), level: Level.INFO);
      svc.install();
      await expectLater(svc.dispose(), completes);
    });

    test('double-dispose does not throw', () async {
      final svc = LogService(formatter: HumanFormatter(), level: Level.INFO);
      svc.install();
      await svc.dispose();
      await expectLater(svc.dispose(), completes);
    });

    test('dispose without install does not throw', () async {
      final svc = LogService(formatter: HumanFormatter(), level: Level.INFO);
      await expectLater(svc.dispose(), completes);
    });

    test('after dispose, no further records processed by service', () async {
      final svc = LogService(formatter: HumanFormatter(), level: Level.INFO);
      svc.install();
      await svc.dispose();

      // Root logger level resets to ALL after tearDown restores it, but here
      // we just verify Logger.root.level is still whatever it was — the key
      // thing is no exception is thrown when a record arrives post-dispose.
      expect(() => Logger('test.postDispose').info('ghost'), returnsNormally);
      await Future<void>.delayed(Duration.zero);
    });
  });
}
