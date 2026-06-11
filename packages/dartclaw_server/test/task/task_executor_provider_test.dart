import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/src/harness_pool.dart' show HarnessPool;
import 'package:dartclaw_server/src/task/task_runner_pool_coordinator.dart' show TaskRunnerPoolCoordinator;
import 'package:dartclaw_server/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late TaskService tasks;
  late ArtifactCollector collector;
  late TaskExecutor executor;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_task_executor_provider_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = Directory.systemTemp.createTempSync('dartclaw_task_executor_ws_').path;
    Directory(sessionsDir).createSync(recursive: true);

    sessions = _SerialSessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    tasks = TaskService(SqliteTaskRepository(openTaskDbInMemory()));
    collector = ArtifactCollector(
      tasks: tasks,
      messages: messages,
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      workspaceDir: workspaceDir,
    );
  });

  tearDown(() async {
    await executor.stop();
    await tasks.dispose();
    await messages.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    final wsDir = Directory(workspaceDir);
    if (wsDir.existsSync()) wsDir.deleteSync(recursive: true);
  });

  test('task with provider override acquires the matching provider worker', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final claudeTaskWorker = _ProviderWorker(responseText: 'claude complete');
    final codexWorker = _ProviderWorker(responseText: 'codex complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await claudeTaskWorker.dispose();
      await codexWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: primaryWorker, messages: messages, behavior: behavior);
    final taskClaudeRunner = TurnRunner(
      harness: claudeTaskWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
    );
    final taskCodexRunner = TurnRunner(
      harness: codexWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'codex',
    );
    final pool = HarnessPool(runners: [primaryRunner, taskClaudeRunner, taskCodexRunner]);
    final turns = TurnManager.fromPool(pool: pool);
    executor = TaskExecutor(
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
      ),
      runners: TaskExecutorRunners(turns: turns),
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(executor.stop);

    await tasks.create(
      id: 'task-provider-codex',
      title: 'Codex task',
      description: 'Should use the codex pool worker.',
      type: TaskType.coding,
      autoStart: true,
      provider: 'codex',
    );

    final processed = await executor.pollOnce();
    expect(processed, isTrue);
    await _waitForTaskStatus(tasks, 'task-provider-codex', TaskStatus.review);

    expect(codexWorker.turnCalls, 1);
    expect(primaryWorker.turnCalls, 0);
    expect(claudeTaskWorker.turnCalls, 0);
    expect((await tasks.get('task-provider-codex'))!.provider, 'codex');
  });

  test('task with provider override stays queued when only the wrong provider is idle', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final claudeTaskWorker = _ProviderWorker(responseText: 'claude complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await claudeTaskWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: primaryWorker, messages: messages, behavior: behavior);
    final taskClaudeRunner = TurnRunner(
      harness: claudeTaskWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
    );
    final pool = HarnessPool(runners: [primaryRunner, taskClaudeRunner]);
    final turns = TurnManager.fromPool(pool: pool);
    executor = TaskExecutor(
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
      ),
      runners: TaskExecutorRunners(turns: turns),
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(executor.stop);

    await tasks.create(
      id: 'task-provider-miss',
      title: 'Codex task',
      description: 'Should stay queued without a codex worker.',
      type: TaskType.research,
      autoStart: true,
      provider: 'codex',
    );

    final processed = await executor.pollOnce();

    expect(processed, isFalse);
    expect(primaryWorker.turnCalls, 0);
    expect(claudeTaskWorker.turnCalls, 0);
    expect((await tasks.get('task-provider-miss'))!.status, TaskStatus.queued);
  });

  test('unknown provider task stays queued without acquiring configured providers', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final claudeTaskWorker = _ProviderWorker(responseText: 'claude complete');
    final codexWorker = _ProviderWorker(responseText: 'codex complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await claudeTaskWorker.dispose();
      await codexWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    final eventRecorder = TaskEventRecorder(eventService: eventService);
    final primaryRunner = TurnRunner(harness: primaryWorker, messages: messages, behavior: behavior);
    final taskClaudeRunner = TurnRunner(
      harness: claudeTaskWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
    );
    final taskCodexRunner = TurnRunner(
      harness: codexWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'codex',
    );
    final pool = HarnessPool(runners: [primaryRunner, taskClaudeRunner, taskCodexRunner]);
    final turns = TurnManager.fromPool(pool: pool);
    executor = TaskExecutor(
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
        eventRecorder: eventRecorder,
      ),
      runners: TaskExecutorRunners(turns: turns),
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(executor.stop);

    await tasks.create(
      id: 'task-provider-unknown',
      title: 'Goose task',
      description: 'Should not use another provider.',
      type: TaskType.research,
      autoStart: true,
      provider: 'goose',
    );

    final processed = await executor.pollOnce();

    expect(processed, isFalse);
    expect(primaryWorker.turnCalls, 0);
    expect(claudeTaskWorker.turnCalls, 0);
    expect(codexWorker.turnCalls, 0);
    expect((await tasks.get('task-provider-unknown'))!.status, TaskStatus.queued);
    final events = eventService.listForTask('task-provider-unknown', kind: TaskEventKind.taskError);
    expect(events, hasLength(1));
    expect(events.single.details['message'], contains('Provider "goose" is unavailable'));
  });

  test(
    'provider-overridden research task falls back to workspace runner when restricted profile is unavailable',
    () async {
      final primaryWorker = _ProviderWorker(responseText: 'primary complete');
      final codexWorkspaceWorker = _ProviderWorker(responseText: 'codex workspace complete');
      addTearDown(() async {
        await primaryWorker.dispose();
        await codexWorkspaceWorker.dispose();
      });

      final behavior = BehaviorFileService(workspaceDir: workspaceDir);
      final primaryRunner = TurnRunner(harness: primaryWorker, messages: messages, behavior: behavior);
      final taskCodexWorkspaceRunner = TurnRunner(
        harness: codexWorkspaceWorker,
        messages: messages,
        behavior: behavior,
        providerId: 'codex',
      );
      final pool = HarnessPool(runners: [primaryRunner, taskCodexWorkspaceRunner]);
      final turns = TurnManager.fromPool(pool: pool);
      executor = TaskExecutor(
        services: TaskExecutorServices(
          tasks: tasks,
          sessions: sessions,
          messages: messages,
          artifactCollector: collector,
        ),
        runners: TaskExecutorRunners(turns: turns),
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(executor.stop);

      await tasks.create(
        id: 'task-provider-workspace-fallback',
        title: 'Codex research task',
        description: 'Should use the codex workspace worker when restricted is unavailable.',
        type: TaskType.research,
        autoStart: true,
        provider: 'codex',
      );

      final processed = await executor.pollOnce();

      expect(processed, isTrue);
      await _waitForTaskStatus(tasks, 'task-provider-workspace-fallback', TaskStatus.review);
      expect(primaryWorker.turnCalls, 0);
      expect(codexWorkspaceWorker.turnCalls, 1);
      expect((await tasks.get('task-provider-workspace-fallback'))!.status, TaskStatus.review);
    },
  );

  test('task with provider override stays queued when provider exists only in another profile', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final codexRestrictedWorker = _ProviderWorker(responseText: 'codex restricted complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await codexRestrictedWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: primaryWorker, messages: messages, behavior: behavior);
    final taskCodexRestrictedRunner = TurnRunner(
      harness: codexRestrictedWorker,
      messages: messages,
      behavior: behavior,
      profileId: 'restricted',
      providerId: 'codex',
    );
    final pool = HarnessPool(runners: [primaryRunner, taskCodexRestrictedRunner]);
    final turns = TurnManager.fromPool(pool: pool);
    executor = TaskExecutor(
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
      ),
      runners: TaskExecutorRunners(turns: turns),
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(executor.stop);

    await tasks.create(
      id: 'task-provider-profile-miss',
      title: 'Codex workspace task',
      description: 'Should stay queued because the only codex worker lives in restricted.',
      type: TaskType.coding,
      autoStart: true,
      provider: 'codex',
    );

    final processed = await executor.pollOnce();

    expect(processed, isFalse);
    expect(primaryWorker.turnCalls, 0);
    expect(codexRestrictedWorker.turnCalls, 0);
    expect((await tasks.get('task-provider-profile-miss'))!.status, TaskStatus.queued);
  });

  test('tasks without provider override still use the existing pool behavior', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final claudeTaskWorker = _ProviderWorker(responseText: 'claude complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await claudeTaskWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: primaryWorker, messages: messages, behavior: behavior);
    final taskClaudeRunner = TurnRunner(
      harness: claudeTaskWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
    );
    final pool = HarnessPool(runners: [primaryRunner, taskClaudeRunner]);
    final turns = TurnManager.fromPool(pool: pool);
    executor = TaskExecutor(
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
      ),
      runners: TaskExecutorRunners(turns: turns),
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(executor.stop);

    await tasks.create(
      id: 'task-no-provider',
      title: 'Default task',
      description: 'Should still execute normally.',
      type: TaskType.research,
      autoStart: true,
    );

    final processed = await executor.pollOnce();
    expect(processed, isTrue);
    await _waitForTaskStatus(tasks, 'task-no-provider', TaskStatus.review);

    expect(primaryWorker.turnCalls, 0);
    expect(claudeTaskWorker.turnCalls, 1);
    expect((await tasks.get('task-no-provider'))!.status, TaskStatus.review);
  });

  test('multiple provider tasks dispatch to their matching provider workers', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final claudeTaskWorker = _ProviderWorker(responseText: 'claude complete');
    final codexWorker = _ProviderWorker(responseText: 'codex complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await claudeTaskWorker.dispose();
      await codexWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: primaryWorker, messages: messages, behavior: behavior);
    final taskClaudeRunner = TurnRunner(
      harness: claudeTaskWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
    );
    final taskCodexRunner = TurnRunner(
      harness: codexWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'codex',
    );
    final pool = HarnessPool(runners: [primaryRunner, taskClaudeRunner, taskCodexRunner]);
    final turns = TurnManager.fromPool(pool: pool);
    executor = TaskExecutor(
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
      ),
      runners: TaskExecutorRunners(turns: turns),
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(executor.stop);

    await tasks.create(
      id: 'task-claude',
      title: 'Claude task',
      description: 'Should use claude.',
      type: TaskType.coding,
      autoStart: true,
      provider: 'claude',
    );
    await tasks.create(
      id: 'task-codex',
      title: 'Codex task',
      description: 'Should use codex.',
      type: TaskType.coding,
      autoStart: true,
      provider: 'codex',
    );

    final processed = await executor.pollOnce();

    expect(processed, isTrue);
    await _waitForTaskStatus(tasks, 'task-claude', TaskStatus.review);
    await _waitForTaskStatus(tasks, 'task-codex', TaskStatus.review);

    expect(primaryWorker.turnCalls, 0);
    expect(claudeTaskWorker.turnCalls, 1);
    expect(codexWorker.turnCalls, 1);
    expect((await tasks.get('task-claude'))!.provider, 'claude');
    expect((await tasks.get('task-codex'))!.provider, 'codex');
  });

  test('provider-specific wait triggers spawn even when another provider is idle', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final claudeTaskWorker = _ProviderWorker(responseText: 'claude complete');
    final codexWorker = _ProviderWorker(responseText: 'codex complete');
    final secondClaudeWorker = _ProviderWorker(responseText: 'second claude complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await claudeTaskWorker.dispose();
      await codexWorker.dispose();
      await secondClaudeWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final pool = HarnessPool(
      runners: [
        TurnRunner(harness: primaryWorker, messages: messages, behavior: behavior),
        TurnRunner(harness: claudeTaskWorker, messages: messages, behavior: behavior, providerId: 'claude'),
        TurnRunner(harness: codexWorker, messages: messages, behavior: behavior, providerId: 'codex'),
      ],
      maxConcurrentTasks: 3,
    );
    final busyClaude = pool.tryAcquireForProvider('claude');
    expect(busyClaude, isNotNull);
    expect(pool.availableCount, 1, reason: 'codex is idle and must not suppress claude provisioning');

    final spawned = Completer<void>();
    final coordinator = TaskRunnerPoolCoordinator(
      pool: pool,
      onSpawnNeeded: (requestedProviderId) async {
        expect(requestedProviderId, 'claude');
        pool.addRunner(
          TurnRunner(harness: secondClaudeWorker, messages: messages, behavior: behavior, providerId: 'claude'),
        );
        spawned.complete();
        return true;
      },
    );
    final task = Task(
      id: 'task-claude-spawn',
      title: 'Claude spawn',
      description: 'Needs another claude worker.',
      type: TaskType.coding,
      status: TaskStatus.queued,
      provider: 'claude',
      createdAt: DateTime.now(),
    );

    final firstAttempt = coordinator.acquireRunnerForTask(task, 'workspace');
    expect(firstAttempt, isNull);
    await spawned.future.timeout(const Duration(seconds: 1));

    final secondAttempt = coordinator.acquireRunnerForTask(task, 'workspace');
    expect(secondAttempt, isNotNull);
    expect(secondAttempt!.providerId, 'claude');
  });
}

class _ProviderWorker implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  final Completer<void> _turnStarted = Completer<void>();

  _ProviderWorker({required this.responseText});

  String responseText;
  int turnCalls = 0;

  Future<void> get turnStarted => _turnStarted.future;

  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  bool get supportsSessionContinuity => false;

  @override
  bool get supportsPreCompactHook => false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async {
    turnCalls += 1;
    if (!_turnStarted.isCompleted) {
      _turnStarted.complete();
    }
    if (responseText.isNotEmpty) {
      _eventsCtrl.add(DeltaEvent(responseText));
    }
    return const {'input_tokens': 0, 'output_tokens': 0};
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) {
      await _eventsCtrl.close();
    }
  }
}

Future<void> _waitForTaskStatus(TaskService tasks, String taskId, TaskStatus status) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    final task = await tasks.get(taskId);
    if (task?.status == status) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Task $taskId did not reach status $status');
}

class _SerialSessionService extends SessionService {
  _SerialSessionService({required super.baseDir});

  Future<void> _pending = Future<void>.value();

  @override
  Future<Session> getOrCreateByKey(String key, {SessionType type = SessionType.user, String? provider}) async {
    Session? session;
    Object? error;
    StackTrace? stackTrace;

    _pending = _pending.then((_) async {
      try {
        session = await super.getOrCreateByKey(key, type: type, provider: provider);
      } catch (e, st) {
        error = e;
        stackTrace = st;
      }
    });

    await _pending;
    if (error != null) {
      Error.throwWithStackTrace(error!, stackTrace!);
    }
    return session!;
  }
}
