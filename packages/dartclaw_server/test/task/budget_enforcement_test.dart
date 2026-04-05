import 'dart:async';
import 'dart:convert';
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
  late GoalService goals;
  late _FakeBudgetWorker worker;
  late TurnManager turns;
  late ArtifactCollector collector;
  late KvService kvService;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_budget_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = Directory.systemTemp.createTempSync('dartclaw_budget_ws_').path;
    Directory(sessionsDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    tasks = TaskService(SqliteTaskRepository(sqlite3.openInMemory()));
    goals = GoalService(SqliteGoalRepository(sqlite3.openInMemory()));
    worker = _FakeBudgetWorker();
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
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
  });

  tearDown(() async {
    await tasks.dispose();
    await messages.dispose();
    await worker.dispose();
    await kvService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    final wsDir = Directory(workspaceDir);
    if (wsDir.existsSync()) wsDir.deleteSync(recursive: true);
  });

  TaskExecutor buildExecutor({
    TaskBudgetConfig? budgetConfig,
    EventBus? eventBus,
  }) {
    return TaskExecutor(
      tasks: tasks,
      goals: goals,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      kvService: kvService,
      budgetConfig: budgetConfig,
      eventBus: eventBus,
      dataDir: tempDir.path,
      pollInterval: const Duration(milliseconds: 10),
    );
  }

  Future<void> seedSessionCost(String sessionId, {required int totalTokens, int turnCount = 1}) async {
    await kvService.set(
      'session_cost:$sessionId',
      jsonEncode({
        'input_tokens': totalTokens ~/ 2,
        'output_tokens': totalTokens ~/ 2,
        'total_tokens': totalTokens,
        'turn_count': turnCount,
        'estimated_cost_usd': 0.0,
      }),
    );
  }

  group('Pre-turn budget enforcement', () {
    test('task with no budget executes normally', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      await tasks.create(
        id: 'task-no-budget',
        title: 'Unlimited task',
        description: 'No budget set.',
        type: TaskType.custom,
        autoStart: true,
      );

      await executor.pollOnce();

      expect((await tasks.get('task-no-budget'))!.status, TaskStatus.review);
    });

    test('task with budget stops when cumulative tokens exceed limit', () async {
      final executor = buildExecutor(
        budgetConfig: const TaskBudgetConfig(defaultMaxTokens: 1000),
      );
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await tasks.create(
        id: 'task-exceeded',
        title: 'Over-budget task',
        description: 'This task exceeded the budget.',
        type: TaskType.custom,
        maxTokens: 1000,
        autoStart: true,
      );

      // Seed session cost data exceeding the budget.
      final session = await sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 1500);

      await executor.pollOnce();

      final result = await tasks.get('task-exceeded');
      expect(result!.status, TaskStatus.failed);
      expect(result.configJson['errorSummary'], contains('Budget exceeded'));
    });

    test('task with budget creates BudgetArtifact on exceeded', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await tasks.create(
        id: 'task-artifact',
        title: 'Artifact test task',
        description: 'Creates budget artifact.',
        type: TaskType.custom,
        maxTokens: 500,
        autoStart: true,
      );

      final session = await sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 1000, turnCount: 3);

      await executor.pollOnce();

      final artifacts = await tasks.listArtifacts('task-artifact');
      expect(artifacts, hasLength(1));
      expect(artifacts[0].name, 'budget-exceeded');
      expect(artifacts[0].kind, ArtifactKind.data);
      // Artifact path must be a real file readable by API/web (not inline JSON).
      final artifactFile = File(artifacts[0].path);
      expect(artifactFile.existsSync(), isTrue);
      final content = jsonDecode(artifactFile.readAsStringSync()) as Map<String, dynamic>;
      expect(content['consumed'], 1000);
      expect(content['limit'], 500);
      expect(content['turnCount'], 3);
    });

    test('fires BudgetWarningEvent at warning threshold', () async {
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final warningEvents = <BudgetWarningEvent>[];
      eventBus.on<BudgetWarningEvent>().listen(warningEvents.add);

      final executor = buildExecutor(eventBus: eventBus);
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await tasks.create(
        id: 'task-warning',
        title: 'Warning task',
        description: 'Should fire budget warning.',
        type: TaskType.custom,
        maxTokens: 1000,
        autoStart: true,
      );

      final session = await sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      // 85% — above default 80% threshold.
      await seedSessionCost(session.id, totalTokens: 850);

      await executor.pollOnce();

      // Task should still proceed (warning, not failure).
      expect((await tasks.get('task-warning'))!.status, TaskStatus.review);
      expect(warningEvents, hasLength(1));
      expect(warningEvents[0].taskId, 'task-warning');
      expect(warningEvents[0].consumed, 850);
      expect(warningEvents[0].limit, 1000);
      expect(warningEvents[0].consumedPercent, closeTo(0.85, 0.01));
    });

    test('warning fires only once (deduplication)', () async {
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final warningEvents = <BudgetWarningEvent>[];
      eventBus.on<BudgetWarningEvent>().listen(warningEvents.add);

      final executor = buildExecutor(eventBus: eventBus);
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await tasks.create(
        id: 'task-dedup',
        title: 'Dedup warning task',
        description: 'Warning fires once.',
        type: TaskType.custom,
        maxTokens: 1000,
        autoStart: true,
      );

      final session = await sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 850);

      // Poll twice — warning should only fire once.
      await executor.pollOnce();
      // Re-queue the task for second poll.
      await tasks.transition('task-dedup', TaskStatus.queued, trigger: 'test');
      await executor.pollOnce();

      expect(warningEvents, hasLength(1));
    });

    test('no budget enforcement when KV read fails (fail-safe open policy)', () async {
      // Use a KvService that can't be read (bad path).
      final badKv = KvService(filePath: '/nonexistent/path/kv.json');
      addTearDown(badKv.dispose);

      final executor = TaskExecutor(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        turns: turns,
        artifactCollector: collector,
        kvService: badKv,
        budgetConfig: const TaskBudgetConfig(defaultMaxTokens: 1000),
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      await tasks.create(
        id: 'task-failsafe',
        title: 'Fail-safe task',
        description: 'Budget check failure should not block.',
        type: TaskType.custom,
        maxTokens: 1000,
        autoStart: true,
      );

      await executor.pollOnce();

      // Task proceeds normally despite KV read failure.
      expect((await tasks.get('task-failsafe'))!.status, TaskStatus.review);
    });

    test('task maxTokens overrides global config default', () async {
      final executor = buildExecutor(
        budgetConfig: const TaskBudgetConfig(defaultMaxTokens: 5000),
      );
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await tasks.create(
        id: 'task-override',
        title: 'Override task',
        description: 'Task maxTokens overrides config default.',
        type: TaskType.custom,
        maxTokens: 500,
        autoStart: true,
      );

      final session = await sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      // 700 tokens: exceeds task budget (500) but not config default (5000).
      await seedSessionCost(session.id, totalTokens: 700);

      await executor.pollOnce();

      expect((await tasks.get('task-override'))!.status, TaskStatus.failed);
    });

    test('goal maxTokens used when task has no budget', () async {
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final warningEvents = <BudgetWarningEvent>[];
      eventBus.on<BudgetWarningEvent>().listen(warningEvents.add);

      final executor = buildExecutor(eventBus: eventBus);
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      // Goal with budget set.
      await goals.create(id: 'goal-budget', title: 'Budget goal', mission: 'Test', maxTokens: 750);

      final task = await tasks.create(
        id: 'task-goal-budget',
        title: 'Goal budget task',
        description: 'Inherits budget from goal.',
        type: TaskType.custom,
        goalId: 'goal-budget',
        autoStart: true,
      );

      final session = await sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      // 640 tokens = ~85% of 750 — above 80% threshold.
      await seedSessionCost(session.id, totalTokens: 640);

      await executor.pollOnce();

      expect(warningEvents, hasLength(1));
      expect(warningEvents[0].limit, 750);
    });

    test('global config default used when no task or goal budget', () async {
      final executor = buildExecutor(
        budgetConfig: const TaskBudgetConfig(defaultMaxTokens: 1000),
      );
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await tasks.create(
        id: 'task-config-default',
        title: 'Config default task',
        description: 'Uses global default budget.',
        type: TaskType.custom,
        autoStart: true,
      );

      final session = await sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 1500);

      await executor.pollOnce();

      expect((await tasks.get('task-config-default'))!.status, TaskStatus.failed);
    });

    test('legacy configJson tokenBudget used for backward compatibility', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await tasks.create(
        id: 'task-legacy',
        title: 'Legacy budget task',
        description: 'Uses configJson tokenBudget.',
        type: TaskType.custom,
        configJson: {'tokenBudget': 1000},
        autoStart: true,
      );

      final session = await sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 1500);

      await executor.pollOnce();

      expect((await tasks.get('task-legacy'))!.status, TaskStatus.failed);
    });

    test('task with no session cost data proceeds (first turn)', () async {
      final executor = buildExecutor(
        budgetConfig: const TaskBudgetConfig(defaultMaxTokens: 1000),
      );
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      await tasks.create(
        id: 'task-first-turn',
        title: 'First turn task',
        description: 'No prior session cost.',
        type: TaskType.custom,
        maxTokens: 1000,
        autoStart: true,
      );

      await executor.pollOnce();

      // No cost data = no enforcement = task proceeds.
      expect((await tasks.get('task-first-turn'))!.status, TaskStatus.review);
    });

    test('budget at exactly 100% is treated as exceeded', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await tasks.create(
        id: 'task-exact-100',
        title: 'Exact 100% task',
        description: 'Exactly at budget.',
        type: TaskType.custom,
        maxTokens: 1000,
        autoStart: true,
      );

      final session = await sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 1000);

      await executor.pollOnce();

      expect((await tasks.get('task-exact-100'))!.status, TaskStatus.failed);
    });

    test('zero or negative maxTokens is treated as no budget', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await tasks.create(
        id: 'task-zero-budget',
        title: 'Zero budget task',
        description: 'maxTokens=0 treated as no limit.',
        type: TaskType.custom,
        maxTokens: 0,
        autoStart: true,
      );

      final session = await sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 999999);

      await executor.pollOnce();

      // Zero maxTokens = no budget = runs normally.
      expect((await tasks.get('task-zero-budget'))!.status, TaskStatus.review);
    });
  });
}

class _FakeBudgetWorker implements AgentHarness {
  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();

  String responseText = '';

  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

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
    if (responseText.isNotEmpty) {
      _eventsCtrl.add(DeltaEvent(responseText));
    }
    return const <String, dynamic>{'input_tokens': 10, 'output_tokens': 10};
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
