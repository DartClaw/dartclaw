import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'task_event_recorder.dart';
import 'task_service.dart';

part 'task_budget_policy_failure.dart';

enum BudgetVerdict { proceed, exceeded }

final class SessionCostSnapshot {
  final int totalTokens;
  final int turnCount;

  const SessionCostSnapshot({required this.totalTokens, required this.turnCount});
}

typedef BudgetFailureHandler =
    Future<void> Function(Task task, {required String errorSummary, required bool retryable});

/// Applies task and goal token-budget policy before task turns execute.
final class TaskBudgetPolicy {
  TaskBudgetPolicy({
    required TaskService tasks,
    required KvService? kv,
    required TaskBudgetConfig? budgetConfig,
    required EventBus? eventBus,
    required String? dataDir,
    required BudgetFailureHandler failTask,
    Uuid uuid = const Uuid(),
    Logger? log,
  }) : _tasks = tasks,
       _kv = kv,
       _budgetConfig = budgetConfig,
       _eventBus = eventBus,
       _dataDir = dataDir,
       _failTask = failTask,
       _uuid = uuid,
       _log = log ?? Logger('TaskBudgetPolicy');

  final TaskService _tasks;
  final KvService? _kv;
  final TaskBudgetConfig? _budgetConfig;
  final EventBus? _eventBus;
  final String? _dataDir;
  final BudgetFailureHandler _failTask;
  final Uuid _uuid;
  final Logger _log;

  Future<(BudgetVerdict, String?)> checkBudget(Task task, String sessionId, {Goal? goal}) async {
    try {
      final effectiveBudget = resolveTokenBudget(task, goal: goal);
      if (effectiveBudget == null) return (BudgetVerdict.proceed, null);

      final costData = await readSessionCost(sessionId);
      if (costData == null) return (BudgetVerdict.proceed, null);

      final warningThreshold = _budgetConfig?.warningThreshold ?? 0.8;
      final totalTokens = costData.totalTokens;
      final ratio = totalTokens / effectiveBudget;

      if (ratio >= 1.0) {
        await failBudgetExceeded(task, totalTokens, effectiveBudget, costData);
        return (BudgetVerdict.exceeded, null);
      }

      if (ratio >= warningThreshold && !_budgetWarningFired(task)) {
        final warningMsg = fireBudgetWarning(task, ratio, totalTokens, effectiveBudget);
        await _markBudgetWarningFired(task);
        return (BudgetVerdict.proceed, warningMsg);
      }

      return (BudgetVerdict.proceed, null);
    } catch (error, stackTrace) {
      _log.warning('Budget check failed for task ${task.id}, proceeding (fail-safe): $error', error, stackTrace);
      return (BudgetVerdict.proceed, null);
    }
  }

  int? resolveTokenBudget(Task task, {Goal? goal}) {
    if (task.maxTokens != null && task.maxTokens! > 0) return task.maxTokens;

    final legacy = _legacyTokenBudgetFromConfig(task);
    if (legacy != null) return legacy;

    if (goal?.maxTokens != null && goal!.maxTokens! > 0) return goal.maxTokens;

    return _budgetConfig?.defaultMaxTokens;
  }

  Future<SessionCostSnapshot?> readSessionCost(String sessionId) async {
    final raw = await _kv?.get('session_cost:$sessionId');
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return SessionCostSnapshot(
      totalTokens: (json['total_tokens'] as num?)?.toInt() ?? 0,
      turnCount: (json['turn_count'] as num?)?.toInt() ?? 0,
    );
  }

  String fireBudgetWarning(Task task, double ratio, int consumed, int limit) {
    final percent = (ratio * 100).toStringAsFixed(0);
    _eventBus?.fire(
      BudgetWarningEvent(
        taskId: task.id,
        consumedPercent: ratio,
        consumed: consumed,
        limit: limit,
        timestamp: DateTime.now(),
      ),
    );
    return 'You have used $percent% of your token budget ($consumed of $limit tokens). '
        'Wrap up your current work and provide a summary of progress.';
  }

  Future<void> failBudgetExceeded(Task task, int consumed, int limit, SessionCostSnapshot costData) async {
    final artifactContent = jsonEncode({
      'consumed': consumed,
      'limit': limit,
      'totalTokens': costData.totalTokens,
      'turnCount': costData.turnCount,
      'exceededAt': DateTime.now().toIso8601String(),
    });
    await createBudgetArtifact(task, artifactContent);
    _log.warning('Task ${task.id} exceeded token budget ($limit < $consumed tokens); marking failed');
    await _failTask(
      task,
      errorSummary: 'Budget exceeded: used $consumed tokens against a limit of $limit tokens',
      retryable: false,
    );
  }

  Future<void> createBudgetArtifact(Task task, String content) async {
    try {
      final dataDir = _dataDir;
      String artifactPath;
      if (dataDir != null) {
        final artifactFile = File(p.join(dataDir, 'tasks', task.id, 'artifacts', 'budget-exceeded.json'));
        await artifactFile.parent.create(recursive: true);
        await artifactFile.writeAsString(content);
        artifactPath = artifactFile.path;
      } else {
        artifactPath = content;
      }
      await _tasks.addArtifact(
        id: _uuid.v4(),
        taskId: task.id,
        name: 'budget-exceeded',
        kind: ArtifactKind.data,
        path: artifactPath,
      );
    } catch (error, stackTrace) {
      _log.warning('Failed to create budget artifact for task ${task.id}', error, stackTrace);
    }
  }

  int? _legacyTokenBudgetFromConfig(Task task) {
    final primary = task.configJson['tokenBudget'];
    if (primary is num && primary.toInt() > 0) return primary.toInt();
    final legacy = task.configJson['budget'];
    if (legacy is num && legacy.toInt() > 0) return legacy.toInt();
    return null;
  }

  bool _budgetWarningFired(Task task) => task.configJson['_tokenBudgetWarningFired'] == true;

  Future<Task> _markBudgetWarningFired(Task task) async {
    final next = Map<String, dynamic>.from(task.configJson)..['_tokenBudgetWarningFired'] = true;
    return _tasks.updateFields(task.id, configJson: next);
  }
}
