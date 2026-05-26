import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'task_executor_test_support.dart';

void main() {
  late _FakeBudgetWorker worker;
  late TaskExecutorTestHarness h;
  late GoalService goals;
  late KvService kvService;

  setUp(() async {
    worker = _FakeBudgetWorker();
    h = TaskExecutorTestHarness(worker);
    await h.setUp(tempPrefix: 'dartclaw_budget_test_');
    goals = GoalService(SqliteGoalRepository(sqlite3.openInMemory()));
    kvService = KvService(filePath: p.join(h.tempDir.path, 'kv.json'));
  });

  tearDown(() async {
    await kvService.dispose();
    await h.tearDown(workerDispose: worker.dispose);
  });

  TaskExecutor buildExecutor({TaskBudgetConfig? budgetConfig, EventBus? eventBus}) {
    return TaskExecutor(
      services: TaskExecutorServices(
        tasks: h.tasks,
        goals: goals,
        sessions: h.sessions,
        messages: h.messages,
        artifactCollector: h.collector,
        kvService: kvService,
        eventBus: eventBus,
      ),
      runners: TaskExecutorRunners(turns: h.turns),
      limits: TaskExecutorLimits(budgetConfig: budgetConfig),
      dataDir: h.tempDir.path,
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

      await h.tasks.create(
        id: 'task-no-budget',
        title: 'Unlimited task',
        description: 'No budget set.',
        type: TaskType.custom,
        autoStart: true,
      );

      await executor.pollOnce();

      expect((await h.tasks.get('task-no-budget'))!.status, TaskStatus.review);
    });

    test('task with budget stops when cumulative tokens exceed limit', () async {
      final executor = buildExecutor(budgetConfig: const TaskBudgetConfig(defaultMaxTokens: 1000));
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await h.tasks.create(
        id: 'task-exceeded',
        title: 'Over-budget task',
        description: 'This task exceeded the budget.',
        type: TaskType.custom,
        maxTokens: 1000,
        autoStart: true,
      );

      // Seed session cost data exceeding the budget.
      final session = await h.sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 1500);

      await executor.pollOnce();

      final result = await h.tasks.get('task-exceeded');
      expect(result!.status, TaskStatus.failed);
      expect(result.configJson['errorSummary'], contains('Budget exceeded'));
    });

    test('task with budget creates BudgetArtifact on exceeded', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await h.tasks.create(
        id: 'task-artifact',
        title: 'Artifact test task',
        description: 'Creates budget artifact.',
        type: TaskType.custom,
        maxTokens: 500,
        autoStart: true,
      );

      final session = await h.sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 1000, turnCount: 3);

      await executor.pollOnce();

      final artifacts = await h.tasks.listArtifacts('task-artifact');
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

      final task = await h.tasks.create(
        id: 'task-warning',
        title: 'Warning task',
        description: 'Should fire budget warning.',
        type: TaskType.custom,
        maxTokens: 1000,
        autoStart: true,
      );

      final session = await h.sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      // 85% — above default 80% threshold.
      await seedSessionCost(session.id, totalTokens: 850);

      await executor.pollOnce();

      // Task should still proceed (warning, not failure).
      expect((await h.tasks.get('task-warning'))!.status, TaskStatus.review);
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

      final task = await h.tasks.create(
        id: 'task-dedup',
        title: 'Dedup warning task',
        description: 'Warning fires once.',
        type: TaskType.custom,
        maxTokens: 1000,
        autoStart: true,
      );

      final session = await h.sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 850);

      // Poll twice — warning should only fire once.
      await executor.pollOnce();
      // Re-queue the task for second poll.
      await h.tasks.transition('task-dedup', TaskStatus.queued, trigger: 'test');
      await executor.pollOnce();

      expect(warningEvents, hasLength(1));
    });

    test('no budget enforcement when KV read fails (fail-safe open policy)', () async {
      // Use a KvService that can't be read (bad path).
      final badKv = KvService(filePath: '/nonexistent/path/kv.json');
      addTearDown(badKv.dispose);

      final executor = TaskExecutor(
        services: TaskExecutorServices(
          tasks: h.tasks,
          sessions: h.sessions,
          messages: h.messages,
          artifactCollector: h.collector,
          kvService: badKv,
        ),
        runners: TaskExecutorRunners(turns: h.turns),
        limits: const TaskExecutorLimits(budgetConfig: TaskBudgetConfig(defaultMaxTokens: 1000)),
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      await h.tasks.create(
        id: 'task-failsafe',
        title: 'Fail-safe task',
        description: 'Budget check failure should not block.',
        type: TaskType.custom,
        maxTokens: 1000,
        autoStart: true,
      );

      await executor.pollOnce();

      // Task proceeds normally despite KV read failure.
      expect((await h.tasks.get('task-failsafe'))!.status, TaskStatus.review);
    });

    test('task maxTokens overrides global config default', () async {
      final executor = buildExecutor(budgetConfig: const TaskBudgetConfig(defaultMaxTokens: 5000));
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await h.tasks.create(
        id: 'task-override',
        title: 'Override task',
        description: 'Task maxTokens overrides config default.',
        type: TaskType.custom,
        maxTokens: 500,
        autoStart: true,
      );

      final session = await h.sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      // 700 tokens: exceeds task budget (500) but not config default (5000).
      await seedSessionCost(session.id, totalTokens: 700);

      await executor.pollOnce();

      expect((await h.tasks.get('task-override'))!.status, TaskStatus.failed);
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

      final task = await h.tasks.create(
        id: 'task-goal-budget',
        title: 'Goal budget task',
        description: 'Inherits budget from goal.',
        type: TaskType.custom,
        goalId: 'goal-budget',
        autoStart: true,
      );

      final session = await h.sessions.getOrCreateByKey(
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
      final executor = buildExecutor(budgetConfig: const TaskBudgetConfig(defaultMaxTokens: 1000));
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await h.tasks.create(
        id: 'task-config-default',
        title: 'Config default task',
        description: 'Uses global default budget.',
        type: TaskType.custom,
        autoStart: true,
      );

      final session = await h.sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 1500);

      await executor.pollOnce();

      expect((await h.tasks.get('task-config-default'))!.status, TaskStatus.failed);
    });

    test('warns at threshold against global config default when no task or goal budget', () async {
      // Regression guard for tasks.budget.default_max_tokens — proves the
      // pre-turn warn path fires when session cost approaches the configured
      // default cap even when the task itself declares no explicit budget.
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final warningEvents = <BudgetWarningEvent>[];
      eventBus.on<BudgetWarningEvent>().listen(warningEvents.add);

      final executor = buildExecutor(budgetConfig: const TaskBudgetConfig(defaultMaxTokens: 1000), eventBus: eventBus);
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await h.tasks.create(
        id: 'task-default-warn',
        title: 'Default warn task',
        description: 'Triggers warn path using tasks.budget.default_max_tokens.',
        type: TaskType.custom,
        autoStart: true,
      );

      final session = await h.sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      // 85% of 1000 — above default 80% threshold, still under the cap.
      await seedSessionCost(session.id, totalTokens: 850);

      await executor.pollOnce();

      expect((await h.tasks.get('task-default-warn'))!.status, TaskStatus.review);
      expect(warningEvents, hasLength(1));
      expect(warningEvents[0].taskId, 'task-default-warn');
      expect(warningEvents[0].consumed, 850);
      expect(warningEvents[0].limit, 1000);
      expect(warningEvents[0].consumedPercent, closeTo(0.85, 0.01));

      // Prove the warning system message was injected into the session so the
      // agent sees it on the same turn that was about to blow the default cap.
      final msgs = await h.messages.getMessagesTail(session.id, count: 20);
      final systemMessages = msgs.where((m) => m.role == 'system').toList();
      expect(systemMessages, isNotEmpty);
      expect(
        systemMessages.any((m) => m.content.contains('token budget')),
        isTrue,
        reason: 'Budget warning message must reach the agent for default-budget path',
      );
    });

    test('legacy configJson tokenBudget used for backward compatibility', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await h.tasks.create(
        id: 'task-legacy',
        title: 'Legacy budget task',
        description: 'Uses configJson tokenBudget.',
        type: TaskType.custom,
        configJson: {'tokenBudget': 1000},
        autoStart: true,
      );

      final session = await h.sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 1500);

      await executor.pollOnce();

      expect((await h.tasks.get('task-legacy'))!.status, TaskStatus.failed);
    });

    test('task with no session cost data proceeds (first turn)', () async {
      final executor = buildExecutor(budgetConfig: const TaskBudgetConfig(defaultMaxTokens: 1000));
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      await h.tasks.create(
        id: 'task-first-turn',
        title: 'First turn task',
        description: 'No prior session cost.',
        type: TaskType.custom,
        maxTokens: 1000,
        autoStart: true,
      );

      await executor.pollOnce();

      // No cost data = no enforcement = task proceeds.
      expect((await h.tasks.get('task-first-turn'))!.status, TaskStatus.review);
    });

    test('budget at exactly 100% is treated as exceeded', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await h.tasks.create(
        id: 'task-exact-100',
        title: 'Exact 100% task',
        description: 'Exactly at budget.',
        type: TaskType.custom,
        maxTokens: 1000,
        autoStart: true,
      );

      final session = await h.sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 1000);

      await executor.pollOnce();

      expect((await h.tasks.get('task-exact-100'))!.status, TaskStatus.failed);
    });

    test('zero or negative maxTokens is treated as no budget', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);
      worker.responseText = 'Done.';

      final task = await h.tasks.create(
        id: 'task-zero-budget',
        title: 'Zero budget task',
        description: 'maxTokens=0 treated as no limit.',
        type: TaskType.custom,
        maxTokens: 0,
        autoStart: true,
      );

      final session = await h.sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: task.id),
        type: SessionType.task,
      );
      await seedSessionCost(session.id, totalTokens: 999999);

      await executor.pollOnce();

      // Zero maxTokens = no budget = runs normally.
      expect((await h.tasks.get('task-zero-budget'))!.status, TaskStatus.review);
    });
  });
}

class _FakeBudgetWorker implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

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
