part of 'workflow_executor.dart';

extension WorkflowExecutorNodeHelpers on WorkflowExecutor {
  // ── Parallel group + graph node helpers ────────────────────────────────────

  int _nodeIndexForStepIndex(List<WorkflowNode> nodes, Map<String, int> stepIndexById, int stepIndex) {
    if (nodes.isEmpty) return 0;
    for (var index = 0; index < nodes.length; index++) {
      final referencedIndexes = _referencedStepIdsForNode(
        nodes[index],
      ).map((stepId) => stepIndexById[stepId]).nonNulls.toList(growable: false);
      if (referencedIndexes.contains(stepIndex)) {
        return index;
      }
      final firstStepIndex = referencedIndexes.isEmpty
          ? 0
          : referencedIndexes.reduce((left, right) => left < right ? left : right);
      if (firstStepIndex >= stepIndex) {
        return index;
      }
    }
    return nodes.length;
  }

  int _nodeIndexForCursor(List<WorkflowNode> nodes, Map<String, int> stepIndexById, WorkflowExecutionCursor cursor) =>
      _nodeIndexForStepIndex(nodes, stepIndexById, cursor.stepIndex);

  WorkflowExecutionCursor? _legacyResumeCursor(
    WorkflowDefinition definition, {
    int? startFromLoopIndex,
    int? startFromLoopIteration,
    String? startFromLoopStepId,
  }) {
    if (startFromLoopIndex == null || startFromLoopIndex < 0 || startFromLoopIndex >= definition.loops.length) {
      return null;
    }
    final loop = definition.loops[startFromLoopIndex];
    final firstStepId = startFromLoopStepId ?? loop.steps.firstOrNull;
    final stepIndex = firstStepId == null ? 0 : definition.steps.indexWhere((step) => step.id == firstStepId);
    return WorkflowExecutionCursor.loop(
      loopId: loop.id,
      stepIndex: stepIndex >= 0 ? stepIndex : 0,
      iteration: startFromLoopIteration ?? 1,
      stepId: startFromLoopStepId,
    );
  }

  int _firstStepIndexForNode(WorkflowNode node, Map<String, int> stepIndexById) {
    final indexes = _referencedStepIdsForNode(
      node,
    ).map((stepId) => stepIndexById[stepId]).nonNulls.toList(growable: false);
    if (indexes.isEmpty) return 0;
    return indexes.reduce((left, right) => left < right ? left : right);
  }

  Iterable<String> _referencedStepIdsForNode(WorkflowNode node) sync* {
    switch (node) {
      case ActionNode(stepId: final stepId):
        yield stepId;
      case MapNode(stepId: final stepId):
        yield stepId;
      case ParallelGroupNode(stepIds: final stepIds):
        yield* stepIds;
      case LoopNode(stepIds: final stepIds, finallyStepId: final finallyStepId):
        yield* stepIds;
        if (finallyStepId != null) {
          yield finallyStepId;
        }
      case ForeachNode(stepId: final stepId, childStepIds: final childStepIds):
        yield stepId;
        yield* childStepIds;
    }
  }

  // ── Step promotion (non-foreach) ────────────────────────────────────────────

  Future<String?> _promoteWorkflowTask({
    required WorkflowRun run,
    required WorkflowStep step,
    required Task task,
    required WorkflowContext context,
    required Map<String, dynamic> outputs,
    required String? projectId,
    required String promotionStrategy,
  }) async {
    if (task.type != TaskType.coding || promotionStrategy == 'none') {
      return null;
    }

    final promote = _turnAdapter?.promoteWorkflowBranch;
    if (promote == null) {
      outputs['${step.id}.promotion'] = 'failed';
      return 'promotion failed: host promotion callback is not configured';
    }

    final promotionProjectId = projectId?.trim();
    if (promotionProjectId == null || promotionProjectId.isEmpty) {
      outputs['${step.id}.promotion'] = 'failed';
      return 'promotion failed: step has no project binding';
    }

    if (task.worktreeJson == null) {
      // No worktree was bound to this task — nothing to promote.
      return null;
    }
    final branch = (task.worktreeJson?['branch'] as String?)?.trim();
    if (branch == null || branch.isEmpty) {
      outputs['${step.id}.promotion'] = 'failed';
      return 'promotion failed: task worktree branch is unavailable';
    }

    final integrationBranch = (context['_workflow.git.integration_branch'] as String?)?.trim();
    if (integrationBranch == null || integrationBranch.isEmpty) {
      outputs['${step.id}.promotion'] = 'failed';
      return 'promotion failed: integration branch is not initialized';
    }

    final promotionResult = await promote(
      runId: run.id,
      projectId: promotionProjectId,
      branch: branch,
      integrationBranch: integrationBranch,
      strategy: promotionStrategy,
    );

    switch (promotionResult) {
      case WorkflowGitPromotionSuccess(:final commitSha):
        outputs['${step.id}.promotion'] = 'success';
        outputs['${step.id}.promotion_sha'] = commitSha;
        return null;
      case WorkflowGitPromotionConflict(:final conflictingFiles, :final details):
        outputs['${step.id}.promotion'] = 'conflict';
        outputs['${step.id}.promotion_details'] = details;
        final summary = conflictingFiles.isEmpty ? 'merge conflict' : conflictingFiles.join(', ');
        return 'promotion-conflict: $summary';
      case WorkflowGitPromotionError(:final message):
        outputs['${step.id}.promotion'] = 'failed';
        return 'promotion failed: $message';
      case WorkflowGitPromotionSerializeRemaining():
        // Used for non-foreach promotion; serialize-remaining is unreachable here.
        outputs['${step.id}.promotion'] = 'failed';
        return 'promotion failed: unexpected serialize-remaining sentinel';
    }
  }
}
