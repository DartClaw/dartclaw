import 'dart:async';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database database;
  late EventBus eventBus;
  late TaskService taskService;
  late FakeTurnManager turns;
  late TaskCancellationSubscriber subscriber;

  setUp(() {
    database = sqlite3.openInMemory();
    eventBus = EventBus();
    taskService = TaskService(SqliteTaskRepository(database), eventBus: eventBus);
    turns = FakeTurnManager();
    subscriber = TaskCancellationSubscriber(tasks: taskService, turns: turns);
    subscriber.subscribe(eventBus);
  });

  tearDown(() async {
    await subscriber.dispose();
    await taskService.dispose();
    await eventBus.dispose();
    database.close();
  });

  test('cancels the active turn when a running task is cancelled', () async {
    final created = await taskService.create(
      id: 'task-1',
      title: 'Workflow child',
      description: 'Reproduce workflow cancellation handling',
      type: TaskType.research,
      autoStart: true,
      provider: 'codex',
    );
    final running = await taskService.transition(created.id, TaskStatus.running);
    await taskService.updateFields(running.id, sessionId: 'session-1');

    await taskService.transition(running.id, TaskStatus.cancelled, trigger: 'workflow-cancel');
    await Future<void>.delayed(Duration.zero);

    expect(turns.cancelTurnCallCount, 1);
    expect(turns.cancelledSessionIds, ['session-1']);
  });

  test('does not cancel a turn when a queued task is cancelled before it starts', () async {
    final created = await taskService.create(
      id: 'task-2',
      title: 'Queued task',
      description: 'Never started',
      type: TaskType.research,
      autoStart: true,
      provider: 'codex',
    );

    await taskService.transition(created.id, TaskStatus.cancelled, trigger: 'workflow-cancel');
    await Future<void>.delayed(Duration.zero);

    expect(turns.cancelTurnCallCount, 0);
    expect(turns.cancelledSessionIds, isEmpty);
  });
}
