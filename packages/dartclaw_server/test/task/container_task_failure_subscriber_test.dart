import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
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

  test('fails only tasks routed to the crashed profile', () async {
    await tasks.create(
      id: 'coding-task',
      title: 'Coding',
      description: 'workspace task',
      type: TaskType.coding,
      autoStart: true,
    );
    await tasks.transition('coding-task', TaskStatus.running);

    await tasks.create(
      id: 'research-task',
      title: 'Research',
      description: 'restricted task',
      type: TaskType.research,
      autoStart: true,
    );
    await tasks.transition('research-task', TaskStatus.running);

    final events = <TaskStatusChangedEvent>[];
    final subscription = eventBus.on<TaskStatusChangedEvent>().listen(events.add);
    addTearDown(subscription.cancel);

    eventBus.fire(
      ContainerCrashedEvent(
        profileId: 'restricted',
        containerName: 'dartclaw-restricted',
        error: 'Container is no longer running',
        timestamp: DateTime.now(),
      ),
    );

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect((await tasks.get('coding-task'))!.status, TaskStatus.running);
    expect((await tasks.get('research-task'))!.status, TaskStatus.failed);
    expect((await tasks.get('research-task'))!.configJson['errorSummary'], 'Container is no longer running');
    expect(events.map((event) => event.taskId), contains('research-task'));
    expect(events.map((event) => event.taskId), isNot(contains('coding-task')));
  });
}
