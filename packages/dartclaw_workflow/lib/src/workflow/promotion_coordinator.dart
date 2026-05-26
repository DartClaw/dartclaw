import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show EventBus, MapIterationCompletedEvent;
import 'workflow_definition.dart' show WorkflowStep;
import 'workflow_run.dart' show WorkflowRun;

import 'map_step_context.dart';
import 'workflow_turn_adapter.dart';

/// Outcome of a single iteration promotion attempt.
sealed class PromotionOutcome {
  const PromotionOutcome();
}

/// Promotion succeeded.
final class PromotionSuccess extends PromotionOutcome {
  final String commitSha;
  const PromotionSuccess(this.commitSha);
}

/// Promotion encountered a conflict.
final class PromotionConflict extends PromotionOutcome {
  final List<String> conflictingFiles;
  final String details;
  final String failureMessage;
  const PromotionConflict({required this.conflictingFiles, required this.details, required this.failureMessage});
}

/// Promotion encountered a hard error.
final class PromotionError extends PromotionOutcome {
  final String failureMessage;
  const PromotionError(this.failureMessage);
}

/// The promote callback is not configured on the turn adapter.
final class PromotionNotConfigured extends PromotionOutcome {
  const PromotionNotConfigured();
}

/// The iteration has no project binding.
final class PromotionNoProjectBinding extends PromotionOutcome {
  const PromotionNoProjectBinding();
}

/// The task worktree branch is unavailable.
final class PromotionNoBranch extends PromotionOutcome {
  const PromotionNoBranch();
}

/// The integration branch is not initialized.
final class PromotionNoIntegrationBranch extends PromotionOutcome {
  const PromotionNoIntegrationBranch();
}

/// Serialize-remaining sentinel: the outer loop must drain siblings before
/// re-dispatching this iteration (only possible from foreach, not map).
final class PromotionSerializeRemaining extends PromotionOutcome {
  const PromotionSerializeRemaining();
}

/// Fires an [MapIterationCompletedEvent] for a failed iteration.
void fireIterationFailureEvent(
  EventBus eventBus, {
  required WorkflowRun run,
  required WorkflowStep step,
  required int iterIndex,
  required MapStepContext mapCtx,
  required String taskId,
  required int tokenCount,
}) {
  eventBus.fire(
    MapIterationCompletedEvent(
      runId: run.id,
      stepId: step.id,
      iterationIndex: iterIndex,
      totalIterations: mapCtx.collection.length,
      itemId: mapCtx.itemId(iterIndex),
      taskId: taskId,
      success: false,
      tokenCount: tokenCount,
      timestamp: DateTime.now(),
    ),
  );
}

/// Records failure + decrements in-flight + fires event.
///
/// Call sites no longer need to repeat the three-step sequence inline.
Future<void> recordIterationFailureAndDecrement(
  EventBus eventBus, {
  required MapStepContext mapCtx,
  required int iterIndex,
  required String failureMessage,
  required String? taskId,
  required WorkflowRun run,
  required WorkflowStep step,
  required int iterTokens,
  required Future<void> Function() persistProgress,
}) async {
  mapCtx.recordFailure(iterIndex, failureMessage, taskId);
  await persistProgress();
  mapCtx.inFlightCount--;
  fireIterationFailureEvent(
    eventBus,
    run: run,
    step: step,
    iterIndex: iterIndex,
    mapCtx: mapCtx,
    taskId: taskId ?? '',
    tokenCount: iterTokens,
  );
}

/// Calls the promotion callback and returns a typed [PromotionOutcome].
///
/// Does NOT mutate [mapCtx] or call [persistProgress] — callers handle outcomes.
Future<PromotionOutcome> callPromote({
  required Future<WorkflowGitPromotionResult> Function({
    required String runId,
    required String projectId,
    required String branch,
    required String integrationBranch,
    required String strategy,
    String? storyId,
  })
  promote,
  required String runId,
  required String projectId,
  required String branch,
  required String integrationBranch,
  required String strategy,
  required String? storyId,
  required List<String> conflictingFiles,
  required String conflictDetails,
  required bool mergeResolveEnabled,
}) async {
  final result = await promote(
    runId: runId,
    projectId: projectId,
    branch: branch,
    integrationBranch: integrationBranch,
    strategy: strategy,
    storyId: storyId,
  );
  return switch (result) {
    WorkflowGitPromotionSuccess(:final commitSha) => PromotionSuccess(commitSha),
    WorkflowGitPromotionConflict(:final conflictingFiles, :final details) => PromotionConflict(
      conflictingFiles: conflictingFiles,
      details: details,
      failureMessage:
          'promotion-conflict: ${conflictingFiles.isEmpty ? 'merge conflict' : conflictingFiles.join(', ')}',
    ),
    WorkflowGitPromotionError(:final message) => PromotionError('promotion failed: $message'),
    WorkflowGitPromotionSerializeRemaining() => const PromotionSerializeRemaining(),
  };
}
