import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  late EventBus bus;

  setUp(() => bus = EventBus());
  tearDown(() async {
    if (!bus.isDisposed) await bus.dispose();
  });

  final now = DateTime.now();

  GuardBlockEvent guardEvent({String guard = 'InputSanitizer', String verdict = 'block'}) =>
      GuardBlockEvent(
        guardName: guard,
        guardCategory: 'test',
        verdict: verdict,
        hookPoint: 'messageReceived',
        timestamp: now,
      );

  ConfigChangedEvent configEvent() => ConfigChangedEvent(
        changedKeys: ['agent.model'],
        oldValues: {'agent.model': 'old'},
        newValues: {'agent.model': 'new'},
        requiresRestart: false,
        timestamp: now,
      );

  SessionCreatedEvent createdEvent({String id = 's1'}) =>
      SessionCreatedEvent(sessionId: id, sessionType: 'web', timestamp: now);

  SessionEndedEvent endedEvent({String id = 's1'}) =>
      SessionEndedEvent(sessionId: id, sessionType: 'web', timestamp: now);

  SessionErrorEvent errorEvent({String id = 's1', String error = 'fail'}) =>
      SessionErrorEvent(sessionId: id, sessionType: 'web', timestamp: now, error: error);

  group('fire and subscribe', () {
    test('on<T>() receives fired events of matching type', () async {
      final events = <GuardBlockEvent>[];
      bus.on<GuardBlockEvent>().listen(events.add);

      bus.fire(guardEvent());
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first.guardName, 'InputSanitizer');
    });

    test('on<T>() filters out non-matching types', () async {
      final events = <ConfigChangedEvent>[];
      bus.on<ConfigChangedEvent>().listen(events.add);

      bus.fire(guardEvent());
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
    });

    test('on<DartclawEvent>() receives all event types', () async {
      final events = <DartclawEvent>[];
      bus.on<DartclawEvent>().listen(events.add);

      bus.fire(guardEvent());
      bus.fire(configEvent());
      bus.fire(createdEvent());
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(3));
    });

    test('on<SessionLifecycleEvent>() receives all session subtypes', () async {
      final events = <SessionLifecycleEvent>[];
      bus.on<SessionLifecycleEvent>().listen(events.add);

      bus.fire(createdEvent());
      bus.fire(endedEvent());
      bus.fire(errorEvent());
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(3));
      expect(events[0], isA<SessionCreatedEvent>());
      expect(events[1], isA<SessionEndedEvent>());
      expect(events[2], isA<SessionErrorEvent>());
    });

    test('multiple subscribers receive same event', () async {
      final a = <GuardBlockEvent>[];
      final b = <GuardBlockEvent>[];
      bus.on<GuardBlockEvent>().listen(a.add);
      bus.on<GuardBlockEvent>().listen(b.add);

      bus.fire(guardEvent());
      await Future<void>.delayed(Duration.zero);

      expect(a, hasLength(1));
      expect(b, hasLength(1));
    });

    test('events received in order', () async {
      final ids = <String>[];
      bus.on<SessionCreatedEvent>().listen((e) => ids.add(e.sessionId));

      bus.fire(createdEvent(id: 'a'));
      bus.fire(createdEvent(id: 'b'));
      bus.fire(createdEvent(id: 'c'));
      await Future<void>.delayed(Duration.zero);

      expect(ids, ['a', 'b', 'c']);
    });
  });

  group('dispose', () {
    test('fire() after dispose() is a no-op with log warning', () async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);

      await bus.dispose();
      bus.fire(guardEvent());

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(records.where((r) => r.message.contains('fire() called after dispose')), hasLength(1));
    });

    test('on<T>() stream closes after dispose()', () async {
      final done = Completer<void>();
      bus.on<GuardBlockEvent>().listen(null, onDone: done.complete);

      await bus.dispose();

      await expectLater(done.future, completes);
    });

    test('isDisposed returns true after dispose()', () async {
      expect(bus.isDisposed, isFalse);
      await bus.dispose();
      expect(bus.isDisposed, isTrue);
    });
  });

  group('error isolation', () {
    test('subscriber exception does not prevent other subscribers', () async {
      final received = <GuardBlockEvent>[];
      final errors = <Object>[];

      runZonedGuarded(() {
        // First listener throws
        bus.on<GuardBlockEvent>().listen((_) => throw StateError('boom'));
        // Second listener records
        bus.on<GuardBlockEvent>().listen(received.add);

        bus.fire(guardEvent());
      }, (e, _) => errors.add(e));

      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(errors, hasLength(1));
    });

    test('subscriber exception does not crash the bus', () async {
      final errors = <Object>[];

      runZonedGuarded(() {
        bus.on<GuardBlockEvent>().listen((_) => throw StateError('boom'));
        bus.fire(guardEvent());
      }, (e, _) => errors.add(e));

      await Future<void>.delayed(Duration.zero);

      // Bus still works — fire a different event type to a clean listener
      final configs = <ConfigChangedEvent>[];
      bus.on<ConfigChangedEvent>().listen(configs.add);
      bus.fire(configEvent());
      await Future<void>.delayed(Duration.zero);

      expect(configs, hasLength(1));
      expect(errors, hasLength(1));
    });
  });

}
