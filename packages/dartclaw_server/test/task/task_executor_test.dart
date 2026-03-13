import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late TaskService tasks;
  late EventBus eventBus;
  late _FakeTaskWorker worker;
  late TurnManager turns;
  late ArtifactCollector collector;
  late TaskExecutor executor;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_task_executor_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    // Workspace must NOT be inside dataDir — ArtifactCollector excludes
    // files within dataDir to prevent collecting internal metadata.
    workspaceDir = Directory.systemTemp.createTempSync('dartclaw_task_ws_').path;
    Directory(sessionsDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    tasks = TaskService(SqliteTaskRepository(sqlite3.openInMemory()));
    eventBus = EventBus();
    worker = _FakeTaskWorker();
    turns = TurnManager(
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
    );
    collector = ArtifactCollector(
      tasks: tasks,
      messages: messages,
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      workspaceDir: workspaceDir,
    );
    executor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      eventBus: eventBus,
      pollInterval: const Duration(milliseconds: 10),
    );
  });

  tearDown(() async {
    await executor.stop();
    await tasks.dispose();
    await messages.dispose();
    await worker.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    final wsDir = Directory(workspaceDir);
    if (wsDir.existsSync()) wsDir.deleteSync(recursive: true);
  });

  test('executes queued tasks into review with task session and artifacts', () async {
    worker.responseText = 'Done.';
    worker.onTurn = (sessionId) {
      File(p.join(workspaceDir, 'output.md')).writeAsStringSync('# Output');
    };

    await tasks.create(
      id: 'task-1',
      title: 'Write summary',
      description: 'Create a markdown summary.',
      type: TaskType.research,
      autoStart: true,
      acceptanceCriteria: 'Produce output.md',
      now: DateTime.parse('2026-03-10T10:00:00Z'),
    );

    final processed = await executor.pollOnce();

    expect(processed, isTrue);
    final updated = await tasks.get('task-1');
    expect(updated!.status, TaskStatus.review);
    expect(updated.sessionId, isNotNull);

    final taskSessions = await sessions.listSessions(type: SessionType.task);
    expect(taskSessions, hasLength(1));
    final taskSession = taskSessions.single;
    expect(taskSession.channelKey, SessionKey.taskSession(taskId: 'task-1'));

    final defaultSessions = await sessions.listSessions();
    expect(defaultSessions.map((session) => session.type), isNot(contains(SessionType.task)));

    final taskMessages = await messages.getMessages(taskSession.id);
    expect(taskMessages.first.role, 'user');
    expect(taskMessages.first.content, contains('## Task: Write summary'));
    expect(taskMessages.first.content, contains('### Acceptance Criteria'));
    expect(taskMessages.last.role, 'assistant');
    expect(taskMessages.last.content, 'Done.');

    final artifacts = await tasks.listArtifacts('task-1');
    expect(artifacts, hasLength(1));
    expect(artifacts.single.name, 'output.md');
    expect(File(artifacts.single.path).readAsStringSync(), '# Output');
  });

  test('reuses the same session and injects push-back feedback on rerun', () async {
    worker.responseText = 'Initial output';
    await tasks.create(
      id: 'task-2',
      title: 'Automation task',
      description: 'Run something twice.',
      type: TaskType.automation,
      autoStart: true,
      now: DateTime.parse('2026-03-10T10:00:00Z'),
    );

    await executor.pollOnce();
    final reviewed = await tasks.get('task-2');
    final firstSessionId = reviewed!.sessionId!;

    final nextConfig = Map<String, dynamic>.from(reviewed.configJson)
      ..['pushBackCount'] = 1
      ..['pushBackComment'] = 'Address the missing detail.';
    await tasks.updateFields('task-2', configJson: nextConfig);
    await tasks.transition('task-2', TaskStatus.queued);

    worker.responseText = 'Updated output';
    await executor.pollOnce();

    final rerun = await tasks.get('task-2');
    expect(rerun!.status, TaskStatus.review);
    expect(rerun.sessionId, firstSessionId);
    expect(rerun.configJson['pushBackCount'], 1);
    expect(rerun.configJson.containsKey('pushBackComment'), isFalse);

    final taskMessages = await messages.getMessages(firstSessionId);
    final pushBackMessage = taskMessages.lastWhere((message) => message.role == 'user');
    expect(pushBackMessage.content, contains('## Push-back Feedback'));
    expect(pushBackMessage.content, contains('Address the missing detail.'));
  });

  test('passes model override through to task execution', () async {
    worker.responseText = 'Done.';
    await tasks.create(
      id: 'task-model',
      title: 'Model override task',
      description: 'Use a different model.',
      type: TaskType.research,
      autoStart: true,
      configJson: const {'model': 'claude-opus-4-1'},
    );

    await executor.pollOnce();

    expect(worker.lastModel, 'claude-opus-4-1');
    expect((await tasks.get('task-model'))!.status, TaskStatus.review);
  });

  test('fails completed tasks that exceed token budget and preserves artifacts', () async {
    worker.responseText = 'Too expensive';
    worker.inputTokens = 90;
    worker.outputTokens = 40;
    worker.onTurn = (sessionId) {
      File(p.join(workspaceDir, 'budget.md')).writeAsStringSync('# Partial output');
    };
    await tasks.create(
      id: 'task-budget',
      title: 'Budget task',
      description: 'Should fail when usage exceeds budget.',
      type: TaskType.research,
      autoStart: true,
      configJson: const {'tokenBudget': 100},
    );

    await executor.pollOnce();

    final failed = await tasks.get('task-budget');
    expect(failed!.status, TaskStatus.failed);
    final artifacts = await tasks.listArtifacts('task-budget');
    expect(artifacts, hasLength(1));
    expect(artifacts.single.name, 'budget.md');
  });

  test('marks queued tasks as failed when the agent turn crashes', () async {
    worker.shouldFail = true;
    await tasks.create(
      id: 'task-3',
      title: 'Failing task',
      description: 'This should fail.',
      type: TaskType.automation,
      autoStart: true,
    );

    await executor.pollOnce();

    final failed = await tasks.get('task-3');
    expect(failed!.status, TaskStatus.failed);
    expect(failed.sessionId, isNotNull);

    final taskSession = (await sessions.listSessions(type: SessionType.task)).single;
    final taskMessages = await messages.getMessages(taskSession.id);
    expect(taskMessages.last.content, contains('[Turn failed]'));
  });

  test('processes queued tasks in FIFO order', () async {
    worker.responseText = 'ok';
    await tasks.create(
      id: 'task-old',
      title: 'Older',
      description: 'first',
      type: TaskType.automation,
      autoStart: true,
      now: DateTime.parse('2026-03-10T10:00:00Z'),
    );
    await tasks.create(
      id: 'task-new',
      title: 'Newer',
      description: 'second',
      type: TaskType.automation,
      autoStart: true,
      now: DateTime.parse('2026-03-10T10:01:00Z'),
    );

    await executor.pollOnce();

    expect((await tasks.get('task-old'))!.status, TaskStatus.review);
    expect((await tasks.get('task-new'))!.status, TaskStatus.queued);
  });

  test('executes tasks via pool-mode when maxConcurrentTasks > 0', () async {
    final poolWorker1 = _FakeTaskWorker();
    final poolWorker2 = _FakeTaskWorker();
    poolWorker1.responseText = 'pool result';
    poolWorker2.responseText = 'pool result 2';
    addTearDown(() async {
      await poolWorker1.dispose();
      await poolWorker2.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: worker, messages: messages, behavior: behavior, sessions: sessions);
    final taskRunner = TurnRunner(harness: poolWorker1, messages: messages, behavior: behavior, sessions: sessions);
    final pool = HarnessPool(runners: [primaryRunner, taskRunner]);
    final poolTurns = TurnManager.fromPool(pool: pool);
    final poolExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: poolTurns,
      artifactCollector: collector,
      eventBus: eventBus,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(poolExecutor.stop);

    await tasks.create(
      id: 'task-pool',
      title: 'Pool task',
      description: 'Should execute via acquired task runner.',
      type: TaskType.automation,
      autoStart: true,
    );

    final processed = await poolExecutor.pollOnce();

    expect(processed, isTrue);
    TaskStatus? status;
    for (var attempt = 0; attempt < 20; attempt++) {
      status = (await tasks.get('task-pool'))!.status;
      if (status == TaskStatus.review) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(status, TaskStatus.review);
    // Task runner was released back to pool.
    expect(pool.availableCount, 1);
    expect(pool.activeCount, 0);
  });

  test('dispatches multiple queued tasks concurrently when multiple runners are idle', () async {
    final poolWorker1Gate = Completer<void>();
    final poolWorker2Gate = Completer<void>();
    final poolWorker1 = _FakeTaskWorker()..beforeComplete = (_) => poolWorker1Gate.future;
    final poolWorker2 = _FakeTaskWorker()..beforeComplete = (_) => poolWorker2Gate.future;
    addTearDown(() async {
      if (!poolWorker1Gate.isCompleted) poolWorker1Gate.complete();
      if (!poolWorker2Gate.isCompleted) poolWorker2Gate.complete();
      await poolWorker1.dispose();
      await poolWorker2.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: worker, messages: messages, behavior: behavior, sessions: sessions);
    final taskRunner1 = TurnRunner(harness: poolWorker1, messages: messages, behavior: behavior, sessions: sessions);
    final taskRunner2 = TurnRunner(harness: poolWorker2, messages: messages, behavior: behavior, sessions: sessions);
    final pool = HarnessPool(runners: [primaryRunner, taskRunner1, taskRunner2]);
    final poolTurns = TurnManager.fromPool(pool: pool);
    final poolExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: poolTurns,
      artifactCollector: collector,
      eventBus: eventBus,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(poolExecutor.stop);

    await tasks.create(
      id: 'task-pool-a',
      title: 'Pool A',
      description: 'Should run in parallel.',
      type: TaskType.research,
      autoStart: true,
    );
    await tasks.create(
      id: 'task-pool-b',
      title: 'Pool B',
      description: 'Should also run in parallel.',
      type: TaskType.research,
      autoStart: true,
    );

    final processed = await poolExecutor.pollOnce();

    expect(processed, isTrue);
    expect((await tasks.get('task-pool-a'))!.status, TaskStatus.running);
    expect((await tasks.get('task-pool-b'))!.status, TaskStatus.running);
    expect(pool.availableCount, 0);
    expect(pool.activeCount, 2);

    poolWorker1.responseText = 'done a';
    poolWorker2.responseText = 'done b';
    poolWorker1Gate.complete();
    poolWorker2Gate.complete();
  });

  test('waits for shared-harness contention instead of failing the task', () async {
    final contentionTurns = _BusyOnceTurnManager(messages, worker);
    final contentionExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: contentionTurns,
      artifactCollector: collector,
      eventBus: eventBus,
      pollInterval: const Duration(milliseconds: 1),
    );
    addTearDown(contentionExecutor.stop);

    await tasks.create(
      id: 'task-busy',
      title: 'Busy task',
      description: 'Should wait for the shared harness.',
      type: TaskType.coding,
      autoStart: true,
    );

    final processed = await contentionExecutor.pollOnce();

    expect(processed, isTrue);
    expect((await tasks.get('task-busy'))!.status, TaskStatus.review);
  });
}

class _FakeTaskWorker implements AgentHarness {
  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();

  String responseText = '';
  String? lastModel;
  int inputTokens = 0;
  int outputTokens = 0;
  bool shouldFail = false;
  void Function(String sessionId)? onTurn;
  Future<void> Function(String sessionId)? beforeComplete;

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
  }) async {
    onTurn?.call(sessionId);
    lastModel = model;
    final waitFor = beforeComplete;
    if (waitFor != null) {
      await waitFor(sessionId);
    }
    if (shouldFail) {
      throw StateError('simulated crash');
    }
    if (responseText.isNotEmpty) {
      _eventsCtrl.add(DeltaEvent(responseText));
    }
    return <String, dynamic>{'input_tokens': inputTokens, 'output_tokens': outputTokens};
  }

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

class _BusyOnceTurnManager extends TurnManager {
  _BusyOnceTurnManager(MessageService messages, AgentHarness worker)
    : super(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/dartclaw-task-executor-test'),
      );

  bool _busyOnce = true;

  @override
  Iterable<String> get activeSessionIds => const <String>[];

  @override
  Future<String> reserveTurn(String sessionId, {String agentName = 'main', String? directory, String? model}) async {
    if (_busyOnce) {
      _busyOnce = false;
      throw BusyTurnException('shared harness busy', isSameSession: false);
    }

    return 'busy-once-turn';
  }

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) {}

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    return TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now());
  }
}
