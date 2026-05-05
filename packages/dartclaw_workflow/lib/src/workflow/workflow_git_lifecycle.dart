import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowDefinition, WorkflowRun;
import 'package:logging/logging.dart';

import 'workflow_context.dart';
import 'workflow_turn_adapter.dart';

final _log = Logger('WorkflowGitLifecycle');

/// Bootstraps workflow-owned git state when configured.
Future<String?> initializeWorkflowGit({
  required WorkflowRun run,
  required WorkflowDefinition definition,
  required WorkflowContext context,
  required WorkflowTurnAdapter? turnAdapter,
  required dynamic repository,
  required Future<void> Function(String runId, WorkflowContext context) persistContext,
  required String? Function(WorkflowRun run, WorkflowContext context) workflowProjectId,
  required bool Function(WorkflowDefinition definition, WorkflowContext context) requiresPerMapItemBootstrap,
}) async {
  final strategy = definition.gitStrategy;
  if (strategy == null || strategy.bootstrap != true) return null;
  final bootstrap = turnAdapter?.bootstrapWorkflowGit;
  if (bootstrap == null) return null;

  final projectId = workflowProjectId(run, context);
  if (projectId == null || projectId.isEmpty) return null;
  final baseRef = (context.variables['BRANCH']?.trim().isNotEmpty ?? false) ? context.variables['BRANCH']!.trim() : '';

  try {
    final result = await bootstrap(
      runId: run.id,
      projectId: projectId,
      baseRef: baseRef,
      perMapItem: requiresPerMapItemBootstrap(definition, context),
    );
    context['_workflow.git.integration_branch'] = result.integrationBranch;
    if (result.note != null && result.note!.isNotEmpty) {
      context['_workflow.git.note'] = result.note!;
    }
    await persistContext(run.id, context);
    final refreshedRun = (await repository.getById(run.id) as WorkflowRun?) ?? run;
    await repository.update(
      refreshedRun.copyWith(
        contextJson: {
          for (final e in refreshedRun.contextJson.entries)
            if (e.key.startsWith('_')) e.key: e.value,
          ...context.toJson(),
        },
        updatedAt: DateTime.now(),
      ),
    );
    return null;
  } catch (e) {
    return 'workflow git bootstrap failed: $e';
  }
}

/// Runs deterministic publish for completed workflow git branches.
Future<String?> runDeterministicPublish({
  required WorkflowRun run,
  required WorkflowDefinition definition,
  required WorkflowContext context,
  required WorkflowTurnAdapter? turnAdapter,
  required dynamic repository,
  required Future<void> Function(String runId, WorkflowContext context) persistContext,
  required String? Function(WorkflowRun run, WorkflowContext context) workflowProjectId,
}) async {
  final publish = turnAdapter?.publishWorkflowBranch;
  if (publish == null) {
    return 'workflow publish is enabled but host publish callback is not configured';
  }

  final projectId = workflowProjectId(run, context);
  if (projectId == null || projectId.isEmpty) {
    return 'workflow publish requires PROJECT to be set';
  }

  final branch = (context['_workflow.git.integration_branch'] as String?)?.trim().isNotEmpty == true
      ? (context['_workflow.git.integration_branch'] as String).trim()
      : ((context.variables['BRANCH']?.trim().isNotEmpty ?? false) ? context.variables['BRANCH']!.trim() : '');
  if (branch.isEmpty) {
    return 'workflow publish could not resolve a branch to publish';
  }

  _log.info("Workflow '${run.id}': publishing branch '$branch' for project '$projectId'");
  try {
    final result = await publish(runId: run.id, projectId: projectId, branch: branch);
    context['publish.status'] = result.status.toJson();
    context['publish.branch'] = result.branch;
    context['publish.remote'] = result.remote;
    context['publish.pr_url'] = result.prUrl;
    if (result.error != null && result.error!.isNotEmpty) {
      context['publish.error'] = result.error!;
    }
    await persistContext(run.id, context);
    final refreshedRun = (await repository.getById(run.id) as WorkflowRun?) ?? run;
    await repository.update(
      refreshedRun.copyWith(
        contextJson: {
          for (final e in refreshedRun.contextJson.entries)
            if (e.key.startsWith('_')) e.key: e.value,
          ...context.toJson(),
        },
        updatedAt: DateTime.now(),
      ),
    );
    if (result.status == WorkflowPublishStatus.failed) {
      _log.warning("Workflow '${run.id}': publish failed for branch '$branch': ${result.error ?? 'unknown error'}");
      return 'publish failed: ${result.error ?? 'unknown error'}';
    }
    _log.info(
      "Workflow '${run.id}': publish succeeded — branch '${result.branch}' pushed to '${result.remote}'"
      '${result.prUrl.isNotEmpty ? ', PR: ${result.prUrl}' : ''}',
    );
    return null;
  } catch (e, st) {
    _log.severe("Workflow '${run.id}': publish threw exception for branch '$branch'", e, st);
    return 'publish failed: $e';
  }
}

/// Cleans up workflow-owned git worktrees through the host adapter.
Future<void> cleanupWorkflowGit({
  required WorkflowRun run,
  required WorkflowTurnAdapter? turnAdapter,
  required bool preserveWorktrees,
}) async {
  final cleanup = turnAdapter?.cleanupWorkflowGit;
  if (cleanup == null) return;
  final projectId = _cleanupProjectId(run);
  if (projectId == null || projectId.isEmpty) return;
  try {
    await cleanup(runId: run.id, projectId: projectId, status: run.status.name, preserveWorktrees: preserveWorktrees);
  } catch (e, st) {
    _log.warning("Workflow '${run.id}' cleanup callback failed: $e", e, st);
  }
}

String? _cleanupProjectId(WorkflowRun run) {
  final fromRun = run.variablesJson['PROJECT']?.trim();
  if (fromRun != null && fromRun.isNotEmpty) return fromRun;

  final variables = run.contextJson['variables'];
  if (variables is Map) {
    final fromContext = variables['PROJECT'];
    if (fromContext is String && fromContext.trim().isNotEmpty) {
      return fromContext.trim();
    }
  }
  return null;
}
