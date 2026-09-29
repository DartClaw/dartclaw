import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show EventBus, KvService, Task, WorkflowBudgetWarningEvent;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show WorkflowStepExecutionRepository;

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

/// A workflow task's known usage and whether its full usage was measured.
final class WorkflowTokenUsage {
  final int knownTokens;
  final bool complete;
  final bool readError;

  const new(this.knownTokens, {required this.complete, this.readError = false});
}

/// Reconciles the task's durable receipt with the current session ledger.
Future<WorkflowTokenUsage> readStepTokenCount(
  Task task,
  KvService kvService,
  WorkflowStepExecutionRepository? receiptRepository,
) async {
  Map<String, dynamic>? breakdown;
  try {
    final receipt = receiptRepository == null ? null : await receiptRepository.getByTaskId(task.id);
    breakdown = receipt?.stepTokenBreakdown;
  } on FormatException {
    return const WorkflowTokenUsage(0, complete: false);
  } catch (_) {
    return const WorkflowTokenUsage(0, complete: false, readError: true);
  }
  final input = breakdown?['inputTokensNew'];
  final cacheRead = breakdown?['cacheReadTokens'];
  final output = breakdown?['outputTokens'];
  final knownTokens = input is int && input >= 0 && cacheRead is int && cacheRead >= 0 && output is int && output >= 0
      ? input + cacheRead + output
      : 0;
  final expectedTurnId = breakdown?['turnId'];
  if (task.sessionId == null ||
      expectedTurnId is! String ||
      expectedTurnId.isEmpty ||
      breakdown?['tokenUsageComplete'] != true ||
      task.configJson['_sessionBaselineValid'] == false) {
    return WorkflowTokenUsage(knownTokens, complete: false);
  }
  try {
    final ledger = await readSessionTokenRecord(kvService, task.sessionId!);
    final baseline = task.configJson['_sessionBaselineTokens'];
    if (ledger == null || ledger.turnId != expectedTurnId || (baseline != null && (baseline is! int || baseline < 0))) {
      return WorkflowTokenUsage(knownTokens, complete: false);
    }
    final delta = ledger.totalTokens - (baseline as int? ?? 0);
    if (delta < 0) return WorkflowTokenUsage(knownTokens, complete: false);
    return WorkflowTokenUsage(delta, complete: true);
  } catch (_) {
    return WorkflowTokenUsage(knownTokens, complete: false, readError: true);
  }
}

/// Reads a complete session ledger. A missing or invalid ledger is unavailable.
Future<int?> readSessionTokens(KvService kvService, String sessionId) async {
  final record = await readSessionTokenRecord(kvService, sessionId);
  return record?.totalTokens;
}

Future<({int totalTokens, String turnId})?> readSessionTokenRecord(KvService kvService, String sessionId) async {
  final raw = await kvService.get('session_cost:$sessionId');
  if (raw == null) return null;
  try {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic> ||
        json['token_usage_complete'] != true ||
        json['pending_accounting_turn_id'] != null) {
      return null;
    }
    final total = json['total_tokens'];
    final turnId = json['last_accounted_turn_id'];
    if (total is! int || total < 0 || turnId is! String || turnId.isEmpty) return null;
    return (totalTokens: total, turnId: turnId);
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}
