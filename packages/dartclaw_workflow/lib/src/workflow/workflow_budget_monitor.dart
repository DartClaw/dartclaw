import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show EventBus, KvService, Task, WorkflowBudgetWarningEvent;
import 'workflow_definition.dart' show WorkflowDefinition;
import 'workflow_run.dart' show WorkflowRun;
import 'package:logging/logging.dart';

final _log = Logger('WorkflowBudgetMonitor');

/// Returns true if the workflow-level token budget has been exceeded.
///
/// [additionalTokens] widens the basis with tokens that have not yet reached
/// [WorkflowRun.totalTokens] (foreach-scope consumption, in-flight loop body
/// tokens). It is evaluation-only – callers must never persist an inflated run.
bool workflowBudgetExceeded(WorkflowRun run, WorkflowDefinition definition, {int additionalTokens = 0}) {
  if (definition.maxTokens == null) return false;
  return run.totalTokens + additionalTokens >= definition.maxTokens!;
}

/// Sums foreach-scope tokens that have not yet reached [WorkflowRun.totalTokens].
///
/// Covers the persisted per-child iteration counts (`<childId>[<i>].tokenCount`,
/// written as each child settles – settled iterations, sibling in-flight
/// iterations, and the current iteration's earlier children) plus in-flight
/// nested-loop checkpoints (`_loop.<loopId>.foreach.<foreachStepId>[<i>].tokens`).
/// A converged loop clears its checkpoint before its `tokenCount` key is
/// written, so the two sources never overlap. The result is an evaluation-only
/// budget basis: the foreach completion sum remains the single write path into
/// `run.totalTokens`. [excludeKeys] lets a nested loop drop its own checkpoint
/// and prior-attempt count, both superseded by its local accumulator.
int foreachScopeConsumedTokens(
  Map<String, dynamic> contextData, {
  required String foreachStepId,
  required List<String> childStepIds,
  Set<String> excludeKeys = const {},
}) {
  final childTokenCountKeys = [
    for (final childId in childStepIds) RegExp('^${RegExp.escape(childId)}\\[\\d+\\]\\.tokenCount\$'),
  ];
  final loopCheckpointKey = RegExp('^_loop\\..+\\.foreach\\.${RegExp.escape(foreachStepId)}\\[\\d+\\]\\.tokens\$');
  var consumed = 0;
  for (final entry in contextData.entries) {
    final value = entry.value;
    if (value is! int || excludeKeys.contains(entry.key)) continue;
    if (loopCheckpointKey.hasMatch(entry.key) || childTokenCountKeys.any((key) => key.hasMatch(entry.key))) {
      consumed += value;
    }
  }
  return consumed;
}

/// Fires a deduplicated warning when the workflow reaches 80% of its token budget.
///
/// [additionalTokens] widens the comparison basis exactly like
/// [workflowBudgetExceeded]; the persisted run keeps its real [WorkflowRun.totalTokens]
/// (only the dedup flag is written), so the inflated basis never reaches storage.
Future<WorkflowRun> checkWorkflowBudgetWarning({
  required WorkflowRun run,
  required WorkflowDefinition definition,
  required EventBus eventBus,
  required dynamic repository,
  int additionalTokens = 0,
}) async {
  if (definition.maxTokens == null) return run;
  if (run.contextJson['_budget.warningFired'] == true) return run;
  final threshold = (definition.maxTokens! * 0.8).toInt();
  final effectiveTokens = run.totalTokens + additionalTokens;
  if (effectiveTokens < threshold) return run;

  eventBus.fire(
    WorkflowBudgetWarningEvent(
      runId: run.id,
      definitionName: run.definitionName,
      consumedPercent: effectiveTokens / definition.maxTokens!,
      consumed: effectiveTokens,
      limit: definition.maxTokens!,
      timestamp: DateTime.now(),
    ),
  );
  _log.info(
    "Workflow '${run.id}': budget warning — "
    '$effectiveTokens/${definition.maxTokens} tokens '
    '(${(effectiveTokens / definition.maxTokens! * 100).toStringAsFixed(0)}%)',
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
    return 0; // KV read failure or malformed value — return 0 so budget logic isn't blocked.
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
    return 0; // KV read or JSON parse failure — return 0 to avoid blocking callers.
  }
}
