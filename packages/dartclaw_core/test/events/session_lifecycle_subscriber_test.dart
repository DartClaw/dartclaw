import 'package:dartclaw_core/dartclaw_core.dart';
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

  test('logs SessionCreatedEvent at INFO', () async {
    eventBus.fire(SessionCreatedEvent(
      sessionId: 's1',
      sessionType: 'user',
      timestamp: now,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(records, hasLength(1));
    expect(records.first.level, Level.INFO);
    expect(records.first.message, contains('Session created'));
    expect(records.first.message, contains('s1'));
    expect(records.first.message, contains('user'));
  });

  test('logs SessionEndedEvent at INFO', () async {
    eventBus.fire(SessionEndedEvent(
      sessionId: 's2',
      sessionType: 'channel',
      timestamp: now,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(records, hasLength(1));
    expect(records.first.level, Level.INFO);
    expect(records.first.message, contains('Session ended'));
    expect(records.first.message, contains('s2'));
  });

  test('logs SessionErrorEvent at WARNING', () async {
    eventBus.fire(SessionErrorEvent(
      sessionId: 's3',
      sessionType: 'cron',
      timestamp: now,
      error: 'timeout',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(records, hasLength(1));
    expect(records.first.level, Level.WARNING);
    expect(records.first.message, contains('Session error'));
    expect(records.first.message, contains('timeout'));
  });

  test('cancel() stops receiving events', () async {
    await subscriber.cancel();

    eventBus.fire(SessionCreatedEvent(
      sessionId: 's4',
      sessionType: 'user',
      timestamp: now,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(records, isEmpty);
  });
}
