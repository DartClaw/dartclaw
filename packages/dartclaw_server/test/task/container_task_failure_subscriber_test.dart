import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
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

  /// Two research tasks, each in its own restricted container authority.
  Future<void> createTwoRunningResearchTasks() async {
    for (final id in ['research-task-a', 'research-task-b']) {
      await tasks.create(
        id: id,
        title: 'Research',
        description: 'restricted task',
        type: TaskType.research,
        autoStart: true,
      );
      await tasks.transition(id, TaskStatus.running);
    }
  }

  test('a crash fails the one task whose container died, not its profile siblings', () async {
    final resolvedSubscriber = ContainerTaskFailureSubscriber(
      tasks: tasks,
      policyResolver: ExecutionPolicyResolver(
        config: DartclawConfig.defaults().copyWith(container: const ContainerConfig(enabled: true)),
        availableContainerProfiles: const {'workspace', 'restricted'},
      ),
    );
    addTearDown(resolvedSubscriber.dispose);
    await subscriber.dispose();
    resolvedSubscriber.subscribe(eventBus);
    await createTwoRunningResearchTasks();

    eventBus.fire(
      ContainerCrashedEvent(
        profileId: 'restricted',
        containerName: 'dartclaw-abc-restricted-1',
        error: 'Container is no longer running',
        timestamp: DateTime.now(),
        taskId: 'research-task-a',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect((await tasks.get('research-task-a'))!.status, TaskStatus.failed);
    expect(
      (await tasks.get('research-task-b'))!.status,
      TaskStatus.running,
      reason: 'its own container is healthy and its turn is still in flight',
    );
  });

  test('a crash of an authority no task owns fails nothing', () async {
    final resolvedSubscriber = ContainerTaskFailureSubscriber(
      tasks: tasks,
      policyResolver: ExecutionPolicyResolver(
        config: DartclawConfig.defaults().copyWith(container: const ContainerConfig(enabled: true)),
        availableContainerProfiles: const {'workspace', 'restricted'},
      ),
    );
    addTearDown(resolvedSubscriber.dispose);
    await subscriber.dispose();
    resolvedSubscriber.subscribe(eventBus);
    await createTwoRunningResearchTasks();

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

    expect((await tasks.get('research-task-a'))!.status, TaskStatus.running);
    expect((await tasks.get('research-task-b'))!.status, TaskStatus.running);
  });

  test('without per-authority attribution, tasks routed to the crashed profile still fail', () async {
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

  test('a host-routed task is untouched by a container crash carrying its type default profile', () async {
    // The research task type defaults to the restricted profile, but this
    // deployment routes it to the host, so it was never inside that container.
    final hostSubscriber = ContainerTaskFailureSubscriber(
      tasks: tasks,
      policyResolver: ExecutionPolicyResolver(
        config: DartclawConfig.defaults().copyWith(
          container: const ContainerConfig(enabled: true),
          tasks: const TaskConfig(execution: {TaskType.research: ExecutionMode.host}),
        ),
        availableContainerProfiles: const {'workspace', 'restricted'},
      ),
    );
    addTearDown(hostSubscriber.dispose);
    await subscriber.dispose();
    hostSubscriber.subscribe(eventBus);

    await tasks.create(
      id: 'host-research-task',
      title: 'Research',
      description: 'host-routed research task',
      type: TaskType.research,
      autoStart: true,
    );
    await tasks.transition('host-research-task', TaskStatus.running);

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

    expect((await tasks.get('host-research-task'))!.status, TaskStatus.running);
  });
}
