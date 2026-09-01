import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late TaskService tasks;
  late EventBus eventBus;
  late ContainerTaskFailureSubscriber subscriber;

  setUp(() {
    db = openTaskDbInMemory();
    eventBus = EventBus();
    tasks = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
    subscriber = ContainerTaskFailureSubscriber(tasks: tasks);
    subscriber.subscribe(eventBus);
  });

  tearDown(() async {
    await subscriber.dispose();
    await eventBus.dispose();
    await tasks.dispose();
  });

  Future<void> createTwoRunningTasks() async {
    for (final id in ['task-a', 'task-b']) {
      await tasks.create(
        id: id,
        title: 'Task',
        description: 'container task',
        configJson: const {'needsWorktree': false},
        autoStart: true,
      );
      await tasks.transition(id, TaskStatus.running);
    }
  }

  test('a crash fails the one task whose container died, not its profile siblings', () async {
    await createTwoRunningTasks();

    eventBus.fire(
      ContainerCrashedEvent(
        profileId: 'restricted',
        containerName: 'dartclaw-abc-restricted-1',
        error: 'Container is no longer running',
        timestamp: DateTime.now(),
        taskId: 'task-a',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect((await tasks.get('task-a'))!.status, TaskStatus.failed);
    expect(
      (await tasks.get('task-b'))!.status,
      TaskStatus.running,
      reason: 'its own container is healthy and its turn is still in flight',
    );
  });

  test('a crash re-queues a task with retries left instead of terminally failing it', () async {
    await tasks.create(
      id: 'retryable-task',
      title: 'Task',
      description: 'container task',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      maxRetries: 2,
    );
    await tasks.transition('retryable-task', TaskStatus.running);

    eventBus.fire(
      ContainerCrashedEvent(
        profileId: 'restricted',
        containerName: 'dartclaw-abc-restricted-1',
        error: 'Container is no longer running',
        timestamp: DateTime.now(),
        taskId: 'retryable-task',
      ),
    );
    await pumpEventQueue();

    final task = (await tasks.get('retryable-task'))!;
    // Pre-fix the subscriber transitioned straight to failed, bypassing the
    // retry machinery; routing through markFailedOrRetry re-queues instead.
    expect(task.status, TaskStatus.queued, reason: 'a container crash must consult maxRetries, not fail directly');
    expect(task.retryCount, 1);
  });

  test('a crash of an authority no task owns fails nothing', () async {
    await createTwoRunningTasks();

    // The primary lane's own authority: profile-shaped like the research
    // containers, owned by no task.
    eventBus.fire(
      ContainerCrashedEvent(
        profileId: 'restricted',
        containerName: 'dartclaw-abc-restricted-9',
        error: 'Container is no longer running',
        timestamp: DateTime.now(),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect((await tasks.get('task-a'))!.status, TaskStatus.running);
    expect((await tasks.get('task-b'))!.status, TaskStatus.running);
  });
}
