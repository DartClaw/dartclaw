import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';

Future<void> main() async {
  final harness = FakeAgentHarness();
  final eventBus = TestEventBus();

  final turnFuture = harness.turn(
    sessionId: 'session-1',
    messages: const [
      {'role': 'user', 'content': 'Summarize today'},
    ],
    systemPrompt: 'You are a test harness.',
  );

  harness.completeSuccess(const {'ok': true, 'message': 'done'});
  final turnResult = await turnFuture;

  final eventFuture = eventBus.expectEvent<TaskStatusChangedEvent>();
  eventBus.fire(
    TaskStatusChangedEvent(
      taskId: 'task-1',
      oldStatus: TaskStatus.queued,
      newStatus: TaskStatus.running,
      trigger: 'example',
      timestamp: DateTime.now(),
    ),
  );
  final event = await eventFuture;

  print('Harness turn result: $turnResult');
  print('Observed task event: ${event.taskId} -> ${event.newStatus.name}');
}
