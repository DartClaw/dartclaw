import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../governance/budget_engine.dart';
import 'task_event_recorder.dart';
import 'task_service.dart';

part 'task_budget_policy_failure.dart';
part 'task_failure_kind.dart';

/// Captures cumulative cost telemetry for a single session.
final class SessionCostSnapshot {
  final int totalTokens;
  final int turnCount;

  const new({required this.totalTokens, required this.turnCount});
}

/// Reports a budget-exceeded outcome for a [Task].
typedef BudgetFailureHandler = Future<void> Function(
  Task task, {
  required String errorSummary,
  required TaskFailureKind kind,
  required bool retryable,
});

/// Applies task and goal token-budget policy before task turns execute.
final class TaskBudgetPolicy {
  new({
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

  static const _engine = BudgetEngine();

  /// Fraction of a task's budget at which it is warned, when
  /// `tasks.budget.warning_threshold` is unset.
  static const _defaultWarningThreshold = 0.8;

  /// Evaluates [task]'s token budget for [sessionId] before its next turn.
  ///
  /// Fail-safe open: any failure while reading the budget or its consumption
  /// is logged and reported as [BudgetOutcome.under], so a broken store never
  /// stalls task execution. The wrapper stays here rather than in
  /// [BudgetEngine], which the daily guardrail shares and must not fail open.
  Future<(BudgetOutcome, String?)> checkBudget(Task task, String sessionId, {Goal? goal}) async {
    try {
      final scope = _TaskBudgetScope(policy: this, task: task, sessionId: sessionId, goal: goal);
      final evaluation = await _engine.evaluate(scope);
      switch (evaluation.outcome) {
        case BudgetOutcome.exceeded:
          await failBudgetExceeded(task, evaluation, turnCount: scope.turnCount);
          return (BudgetOutcome.exceeded, null);
        case BudgetOutcome.warning:
          return (BudgetOutcome.warning, evaluation.warningIsNew ? fireBudgetWarning(task, evaluation) : null);
        case BudgetOutcome.under:
          return (BudgetOutcome.under, null);
      }
    } catch (error, stackTrace) {
      _log.warning('Budget check failed for task ${task.id}, proceeding (fail-safe): $error', error, stackTrace);
      return (BudgetOutcome.under, null);
    }
  }

  /// Resolves [task]'s effective token budget through the canonical ladder:
  /// `task.maxTokens` -> `configJson['tokenBudget']` -> `configJson['budget']`
  /// -> `goal.maxTokens` -> `TaskBudgetConfig.defaultMaxTokens`.
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

  String fireBudgetWarning(Task task, BudgetEvaluation evaluation) {
    final consumed = evaluation.tokensUsed;
    final limit = evaluation.limit;
    _eventBus?.fire(
      BudgetWarningEvent(
        taskId: task.id,
        consumedPercent: evaluation.ratio,
        consumed: consumed,
        limit: limit,
        timestamp: DateTime.now(),
      ),
    );
    return 'You have used ${evaluation.percentage}% of your token budget ($consumed of $limit tokens). '
        'Wrap up your current work and provide a summary of progress.';
  }

  Future<void> failBudgetExceeded(Task task, BudgetEvaluation evaluation, {required int turnCount}) async {
    final consumed = evaluation.tokensUsed;
    final limit = evaluation.limit;
    final artifactContent = jsonEncode({
      'consumed': consumed,
      'limit': limit,
      'totalTokens': consumed,
      'turnCount': turnCount,
      'exceededAt': DateTime.now().toIso8601String(),
    });
    await createBudgetArtifact(task, artifactContent);
    _log.warning('Task ${task.id} exceeded token budget ($limit < $consumed tokens); marking failed');
    await _failTask(
      task,
      errorSummary: 'Budget exceeded: used $consumed tokens against a limit of $limit tokens',
      kind: TaskFailureReason.budgetExceeded,
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

// ---------------------------------------------------------------------------
// _TaskBudgetScope
// ---------------------------------------------------------------------------

/// One task's window over its cumulative session cost.
final class _TaskBudgetScope implements BudgetScope {
  new({required TaskBudgetPolicy policy, required Task task, required String sessionId, required Goal? goal})
    : _policy = policy,
      _task = task,
      _sessionId = sessionId,
      _goal = goal;

  final TaskBudgetPolicy _policy;
  final Task _task;
  final String _sessionId;
  final Goal? _goal;

  /// Turns recorded by the reading taken in [readConsumption]; `0` until then.
  /// Only the budget artifact needs it, so it does not belong on the outcome.
  int turnCount = 0;

  @override
  double get warningThreshold => _policy._budgetConfig?.warningThreshold ?? TaskBudgetPolicy._defaultWarningThreshold;

  /// A task that lands past its cap fails terminally, so it must not burn the
  /// warn-once cell a retry would still need.
  @override
  bool get limitConsumesWarning => false;

  @override
  int? get limit => _policy.resolveTokenBudget(_task, goal: _goal);

  @override
  Future<BudgetConsumption?> readConsumption() async {
    final costData = await _policy.readSessionCost(_sessionId);
    if (costData == null) return null;
    turnCount = costData.turnCount;
    return BudgetConsumption(tokensUsed: costData.totalTokens, warningPosted: _policy._budgetWarningFired(_task));
  }

  @override
  Future<void> markWarningPosted() => _policy._markBudgetWarningFired(_task);
}
