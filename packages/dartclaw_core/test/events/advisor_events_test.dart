import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.parse('2026-03-25T12:00:00Z');

  test('AdvisorMentionEvent exposes fields', () {
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
    expect(event.recipientId, 'spaces/AAA');
    expect(event.taskId, 'task-1');
  });

  test('AdvisorInsightEvent exposes fields', () {
    final event = AdvisorInsightEvent(
      status: 'stuck',
      observation: 'The task keeps revisiting the same failing path.',
      suggestion: 'Simplify the scope and retest.',
      triggerType: 'periodic',
      taskIds: const ['task-1', 'task-2'],
      sessionKey: 'agent:main:task:task-1',
      timestamp: now,
    );
    expect(event.taskIds, ['task-1', 'task-2']);
    expect(event.triggerType, 'periodic');
  });
}
