import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/task/task_budget_policy.dart';
import 'package:dartclaw_server/src/task/task_service.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
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

  TaskBudgetPolicy policy({TaskBudgetConfig? budgetConfig, BudgetFailureHandler? failTask}) {
    return TaskBudgetPolicy(
      tasks: tasks,
      kv: kv,
      budgetConfig: budgetConfig,
      eventBus: null,
      dataDir: tempDir.path,
      failTask: failTask ?? (task, {required errorSummary, required retryable}) async {},
    );
  }

  Future<Task> createTask({int? maxTokens}) {
    return tasks.create(
      id: 'task-${maxTokens ?? 'none'}',
      title: 'Budget task',
      description: 'Check budget',
      type: TaskType.custom,
      maxTokens: maxTokens,
    );
  }

  Future<void> seedCost(String sessionId, {required int totalTokens, int turnCount = 1}) {
    return kv.set('session_cost:$sessionId', jsonEncode({'total_tokens': totalTokens, 'turn_count': turnCount}));
  }

  test('checkBudget proceeds when session has no cost snapshot', () async {
    final budgetPolicy = policy();
    final task = await createTask(maxTokens: 100);

    final (verdict, warning) = await budgetPolicy.checkBudget(task, 'session-1');

    expect(verdict, BudgetVerdict.proceed);
    expect(warning, isNull);
  });

  test('checkBudget emits warning before the limit and marks warning fired', () async {
    final budgetPolicy = policy(budgetConfig: const TaskBudgetConfig(warningThreshold: 0.5));
    final task = await createTask(maxTokens: 100);
    await seedCost('session-1', totalTokens: 60);

    final (verdict, warning) = await budgetPolicy.checkBudget(task, 'session-1');

    expect(verdict, BudgetVerdict.proceed);
    expect(warning, contains('60%'));
    expect((await tasks.get(task.id))!.configJson['_tokenBudgetWarningFired'], isTrue);
  });

  test('checkBudget fails exceeded tasks and creates a budget artifact from session cost', () async {
    String? failure;
    final budgetPolicy = policy(
      failTask: (task, {required errorSummary, required retryable}) async {
        failure = '$retryable:$errorSummary';
      },
    );
    final task = await createTask(maxTokens: 100);
    await seedCost('session-1', totalTokens: 120, turnCount: 3);

    final (verdict, warning) = await budgetPolicy.checkBudget(task, 'session-1');

    expect(verdict, BudgetVerdict.exceeded);
    expect(warning, isNull);
    expect(failure, 'false:Budget exceeded: used 120 tokens against a limit of 100 tokens');
    final artifacts = await tasks.listArtifacts(task.id);
    expect(artifacts.single.name, 'budget-exceeded');
    final content = jsonDecode(File(artifacts.single.path).readAsStringSync()) as Map<String, dynamic>;
    expect(content['totalTokens'], 120);
    expect(content['turnCount'], 3);
  });
}
