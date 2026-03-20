import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/events/session_lifecycle_subscriber.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  late EventBus eventBus;
  late SessionLifecycleSubscriber subscriber;
  late List<LogRecord> records;

  setUp(() {
    eventBus = EventBus();
    subscriber = SessionLifecycleSubscriber();
    subscriber.subscribe(eventBus);
    records = [];
    Logger('SessionLifecycle').onRecord.listen(records.add);
  });

  tearDown(() async {
    await subscriber.cancel();
    await eventBus.dispose();
  });

  final now = DateTime.now();

  test('logs lifecycle events at the correct level', () async {
    eventBus.fire(SessionCreatedEvent(sessionId: 's1', sessionType: 'user', timestamp: now));
    eventBus.fire(SessionEndedEvent(sessionId: 's2', sessionType: 'channel', timestamp: now));
    eventBus.fire(SessionErrorEvent(sessionId: 's3', sessionType: 'cron', timestamp: now, error: 'timeout'));

    await Future<void>.delayed(Duration.zero);

    expect(records, hasLength(3));
    expect(records[0].level, Level.INFO);
    expect(records[0].message, contains('Session created'));
    expect(records[0].message, contains('s1'));
    expect(records[1].level, Level.INFO);
    expect(records[1].message, contains('Session ended'));
    expect(records[2].level, Level.WARNING);
    expect(records[2].message, contains('Session error'));
    expect(records[2].message, contains('timeout'));
  });

  test('cancel() stops receiving events', () async {
    await subscriber.cancel();

    eventBus.fire(SessionCreatedEvent(sessionId: 's4', sessionType: 'user', timestamp: now));
    await Future<void>.delayed(Duration.zero);

    expect(records, isEmpty);
  });
}
