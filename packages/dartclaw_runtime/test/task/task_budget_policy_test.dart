import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:dartclaw_runtime/src/governance/budget_engine.dart';
import 'package:dartclaw_runtime/src/task/task_budget_policy.dart';
import 'package:dartclaw_runtime/src/task/task_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late TaskService tasks;
  late KvService kv;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_task_budget_policy_test_');
    tasks = TaskService(SqliteTaskRepository(openTaskDbInMemory()));
    kv = KvService(filePath: p.join(tempDir.path, 'kv.json'));
  });

  tearDown(() async {
    await tasks.dispose();
    await kv.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  TaskBudgetPolicy policy({TaskBudgetConfig? budgetConfig, BudgetFailureHandler? failTask, KvService? kvOverride}) {
    return TaskBudgetPolicy(
      tasks: tasks,
      kv: kvOverride ?? kv,
      budgetConfig: budgetConfig,
      eventBus: null,
      dataDir: tempDir.path,
      failTask: failTask ?? (task, {required errorSummary, required kind, required retryable}) async {},
    );
  }

  Future<Task> createTask({int? maxTokens, Map<String, dynamic> configJson = const {}, String? id}) {
    return tasks.create(
      id: id ?? 'task-${maxTokens ?? 'none'}',
      title: 'Budget task',
      description: 'Check budget',
      maxTokens: maxTokens,
      configJson: configJson,
    );
  }

  Goal goal({int? maxTokens}) =>
      Goal(id: 'goal-1', title: 'Goal', mission: 'Ship it', createdAt: DateTime(2026), maxTokens: maxTokens);

  Future<void> seedCost(String sessionId, {required int totalTokens, int turnCount = 1}) {
    return kv.set('session_cost:$sessionId', jsonEncode({'total_tokens': totalTokens, 'turn_count': turnCount}));
  }

  test('checkBudget proceeds when session has no cost snapshot', () async {
    final budgetPolicy = policy();
    final task = await createTask(maxTokens: 100);

    final (outcome, warning) = await budgetPolicy.checkBudget(task, 'session-1');

    expect(outcome, BudgetOutcome.under);
    expect(warning, isNull);
  });

  test('checkBudget emits warning before the limit and marks warning fired', () async {
    final budgetPolicy = policy(budgetConfig: const TaskBudgetConfig(warningThreshold: 0.5));
    final task = await createTask(maxTokens: 100);
    await seedCost('session-1', totalTokens: 60);

    final (outcome, warning) = await budgetPolicy.checkBudget(task, 'session-1');

    expect(outcome, BudgetOutcome.warning);
    expect(warning, contains('60%'));
    expect((await tasks.get(task.id))!.configJson['_tokenBudgetWarningFired'], isTrue);
  });

  test('checkBudget fails exceeded tasks and creates a budget artifact from session cost', () async {
    String? failure;
    TaskFailureKind? failureKind;
    final budgetPolicy = policy(
      failTask: (task, {required errorSummary, required kind, required retryable}) async {
        failure = '$retryable:$errorSummary';
        failureKind = kind;
      },
    );
    final task = await createTask(maxTokens: 100);
    await seedCost('session-1', totalTokens: 120, turnCount: 3);

    final (outcome, warning) = await budgetPolicy.checkBudget(task, 'session-1');

    expect(outcome, BudgetOutcome.exceeded);
    expect(warning, isNull);
    expect(failure, 'false:Budget exceeded: used 120 tokens against a limit of 100 tokens');
    expect(failureKind, TaskFailureReason.budgetExceeded);
    final artifacts = await tasks.listArtifacts(task.id);
    expect(artifacts.single.name, 'budget-exceeded');
    final content = jsonDecode(File(artifacts.single.path).readAsStringSync()) as Map<String, dynamic>;
    expect(content['totalTokens'], 120);
    expect(content['turnCount'], 3);
  });

  // ---------------------------------------------------------------------------
  // Resolution ladder — all five rungs, in order
  // ---------------------------------------------------------------------------

  group('resolveTokenBudget ladder', () {
    late TaskBudgetPolicy budgetPolicy;

    setUp(() {
      budgetPolicy = policy(budgetConfig: const TaskBudgetConfig(defaultMaxTokens: 50));
    });

    test('task.maxTokens wins over every later rung', () async {
      final task = await createTask(maxTokens: 100, configJson: {'tokenBudget': 500, 'budget': 700});

      expect(budgetPolicy.resolveTokenBudget(task, goal: goal(maxTokens: 900)), 100);
    });

    test("configJson['tokenBudget'] is next once task.maxTokens is gone", () async {
      final task = await createTask(id: 'ladder-2', configJson: {'tokenBudget': 500, 'budget': 700});

      expect(budgetPolicy.resolveTokenBudget(task, goal: goal(maxTokens: 900)), 500);
    });

    test("configJson['budget'] is next once tokenBudget is gone", () async {
      final task = await createTask(id: 'ladder-3', configJson: {'budget': 700});

      expect(budgetPolicy.resolveTokenBudget(task, goal: goal(maxTokens: 900)), 700);
    });

    test('goal.maxTokens is next once configJson carries no budget', () async {
      final task = await createTask(id: 'ladder-4');

      expect(budgetPolicy.resolveTokenBudget(task, goal: goal(maxTokens: 900)), 900);
    });

    test('tasks.budget.default_max_tokens is the last rung', () async {
      final task = await createTask(id: 'ladder-5');

      expect(budgetPolicy.resolveTokenBudget(task, goal: goal()), 50);
    });

    test('an unbudgeted task under no default resolves to null', () async {
      final task = await createTask(id: 'ladder-6');

      expect(policy().resolveTokenBudget(task, goal: goal()), isNull);
    });

    test('a goal-resolved budget is the one actually enforced pre-turn', () async {
      final task = await createTask(id: 'ladder-enforced');
      await seedCost('session-goal', totalTokens: 950);

      final (outcome, _) = await budgetPolicy.checkBudget(task, 'session-goal', goal: goal(maxTokens: 900));

      expect(outcome, BudgetOutcome.exceeded);
    });
  });

  // ---------------------------------------------------------------------------
  // Error posture — the per-task check fails safe open
  // ---------------------------------------------------------------------------

  test('checkBudget proceeds without warning when the cost store throws', () async {
    final logs = <LogRecord>[];
    final sub = Logger.root.onRecord.listen(logs.add);
    addTearDown(sub.cancel);

    final throwingKv = _ThrowingKvService(filePath: p.join(tempDir.path, 'throwing-kv.json'));
    addTearDown(throwingKv.dispose);
    final budgetPolicy = policy(kvOverride: throwingKv);
    final task = await createTask(maxTokens: 100);

    // The failure the fail-safe suppresses.
    await expectLater(throwingKv.get('session_cost:session-1'), throwsA(isA<StateError>()));

    final (outcome, warning) = await budgetPolicy.checkBudget(task, 'session-1');

    expect(outcome, BudgetOutcome.under);
    expect(warning, isNull);
    expect(logs.any((r) => r.message.contains('proceeding (fail-safe): Bad state: cost store unavailable')), isTrue);
  });

  // ---------------------------------------------------------------------------
  // Warn-once cell — per task, and never consumed by a terminal breach
  // ---------------------------------------------------------------------------

  test('checkBudget warns once per task and stays silent on later turns', () async {
    final budgetPolicy = policy();
    final task = await createTask(maxTokens: 100);

    await seedCost('session-1', totalTokens: 85);
    final (firstOutcome, firstWarning) = await budgetPolicy.checkBudget(task, 'session-1');

    expect(firstOutcome, BudgetOutcome.warning);
    expect(firstWarning, contains('85%'));
    expect((await tasks.get(task.id))!.configJson['_tokenBudgetWarningFired'], isTrue);

    await seedCost('session-1', totalTokens: 90);
    final refreshed = (await tasks.get(task.id))!;
    final (secondOutcome, secondWarning) = await budgetPolicy.checkBudget(refreshed, 'session-1');

    expect(secondOutcome, BudgetOutcome.warning);
    expect(secondWarning, isNull);
  });

  test('a task that goes straight past the limit fails without consuming its warn-once cell', () async {
    var failed = false;
    final budgetPolicy = policy(
      failTask: (task, {required errorSummary, required kind, required retryable}) async {
        failed = true;
      },
    );
    final task = await createTask(maxTokens: 100);
    await seedCost('session-1', totalTokens: 120);

    final (outcome, warning) = await budgetPolicy.checkBudget(task, 'session-1');

    expect(outcome, BudgetOutcome.exceeded);
    expect(warning, isNull);
    expect(failed, isTrue);
    expect((await tasks.get(task.id))!.configJson.containsKey('_tokenBudgetWarningFired'), isFalse);
  });
}

/// A [KvService] whose reads always fail, standing in for an unreadable store.
class _ThrowingKvService extends KvService {
  new({required super.filePath});

  @override
  Future<String?> get(String key) async => throw StateError('cost store unavailable');
}
