import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.parse('2026-04-19T00:00:00Z');

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
}
