import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late EventBus bus;
  final now = DateTime.parse('2026-04-19T00:00:00Z');

  setUp(() => bus = EventBus());

  tearDown(() async {
    if (!bus.isDisposed) {
      await bus.dispose();
    }
  });

  AgentExecutionStatusChangedEvent statusEvent({
    String agentExecutionId = 'ae-1',
    String oldStatus = 'queued',
    String newStatus = 'running',
    String trigger = 'system',
  }) {
    return AgentExecutionStatusChangedEvent(
      agentExecutionId: agentExecutionId,
      oldStatus: oldStatus,
      newStatus: newStatus,
      trigger: trigger,
      timestamp: now,
    );
  }

  test('construction works through the sealed base type', () {
    final AgentExecutionEvent event = statusEvent();

    expect(event.agentExecutionId, 'ae-1');
    expect(event.timestamp, now);
    expect(event, isA<AgentExecutionStatusChangedEvent>());
  });

  test('on<AgentExecutionEvent>() receives status change events', () async {
    final events = <AgentExecutionEvent>[];
    bus.on<AgentExecutionEvent>().listen(events.add);

    bus.fire(statusEvent(newStatus: 'completed'));
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));
    expect((events.single as AgentExecutionStatusChangedEvent).newStatus, 'completed');
  });

  test('toString includes id and statuses', () {
    final event = statusEvent(agentExecutionId: 'ae-42', oldStatus: 'running', newStatus: 'failed');

    expect(event.toString(), contains('ae-42'));
    expect(event.toString(), contains('running'));
    expect(event.toString(), contains('failed'));
  });
}
