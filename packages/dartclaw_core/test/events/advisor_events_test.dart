import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late EventBus bus;
  final now = DateTime.parse('2026-03-25T12:00:00Z');

  setUp(() => bus = EventBus());
  tearDown(() async {
    if (!bus.isDisposed) {
      await bus.dispose();
    }
  });

  test('AdvisorMentionEvent exposes fields and filters through EventBus', () async {
    final events = <AdvisorMentionEvent>[];
    bus.on<AdvisorMentionEvent>().listen(events.add);

    final event = AdvisorMentionEvent(
      senderJid: 'users/123',
      channelType: 'googlechat',
      recipientId: 'spaces/AAA',
      threadId: 'spaces/AAA/threads/BBB',
      messageText: '@advisor take a look',
      sessionKey: 'agent:main:group:googlechat:spaces%2FAAA',
      taskId: 'task-1',
      timestamp: now,
    );
    bus.fire(event);
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));
    expect(events.single.recipientId, 'spaces/AAA');
    expect(events.single.taskId, 'task-1');
    expect(event.toString(), contains('googlechat'));
  });

  test('AdvisorInsightEvent exposes fields and filters through EventBus', () async {
    final events = <AdvisorInsightEvent>[];
    bus.on<AdvisorInsightEvent>().listen(events.add);

    final event = AdvisorInsightEvent(
      status: 'stuck',
      observation: 'The task keeps revisiting the same failing path.',
      suggestion: 'Simplify the scope and retest.',
      triggerType: 'periodic',
      taskIds: const ['task-1', 'task-2'],
      sessionKey: 'agent:main:task:task-1',
      timestamp: now,
    );
    bus.fire(event);
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));
    expect(events.single.taskIds, ['task-1', 'task-2']);
    expect(event.toString(), contains('periodic'));
  });
}
