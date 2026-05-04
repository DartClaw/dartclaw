import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show EventBus, KvService, Task, WorkflowBudgetWarningEvent, WorkflowDefinition, WorkflowRun;
import 'package:logging/logging.dart';

final _log = Logger('WorkflowBudgetMonitor');

/// Returns true if the workflow-level token budget has been exceeded.
bool workflowBudgetExceeded(WorkflowRun run, WorkflowDefinition definition) {
  if (definition.maxTokens == null) return false;
  return run.totalTokens >= definition.maxTokens!;
}

/// Fires a deduplicated warning when the workflow reaches 80% of its token budget.
Future<WorkflowRun> checkWorkflowBudgetWarning({
  required WorkflowRun run,
  required WorkflowDefinition definition,
  required EventBus eventBus,
  required dynamic repository,
}) async {
  if (definition.maxTokens == null) return run;
  if (run.contextJson['_budget.warningFired'] == true) return run;
  final threshold = (definition.maxTokens! * 0.8).toInt();
  if (run.totalTokens < threshold) return run;

  eventBus.fire(
    WorkflowBudgetWarningEvent(
      runId: run.id,
      definitionName: run.definitionName,
      consumedPercent: run.totalTokens / definition.maxTokens!,
      consumed: run.totalTokens,
      limit: definition.maxTokens!,
      timestamp: DateTime.now(),
    ),
  );
  _log.info(
    "Workflow '${run.id}': budget warning — "
    '${run.totalTokens}/${definition.maxTokens} tokens '
    '(${(run.totalTokens / definition.maxTokens! * 100).toStringAsFixed(0)}%)',
  );

  final updated = run.copyWith(
    contextJson: {...run.contextJson, '_budget.warningFired': true},
    updatedAt: DateTime.now(),
  );
  await repository.update(updated);
  return updated;
}

/// Reads the step's cumulative token count from session KV or task metadata.
Future<int> readStepTokenCount(Task task, KvService kvService) async {
  if (task.sessionId == null) return 0;
  try {
    final total = await readSessionTokens(kvService, task.sessionId!);
    final baseline = (task.configJson['_sessionBaselineTokens'] as num?)?.toInt() ?? 0;
    return (total - baseline).clamp(0, double.maxFinite).toInt();
  } catch (_) {
    return 0;
  }
}

/// Reads the raw cumulative token total for [sessionId] from KV store.
Future<int> readSessionTokens(KvService kvService, String sessionId) async {
  try {
    final raw = await kvService.get('session_cost:$sessionId');
    if (raw == null) return 0;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return (json['total_tokens'] as num?)?.toInt() ?? 0;
  } catch (_) {
    return 0;
  }
}
