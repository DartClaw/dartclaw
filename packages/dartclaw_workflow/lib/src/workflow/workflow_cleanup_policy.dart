import 'package:logging/logging.dart';

import 'workflow_definition.dart';
import 'workflow_run.dart';

bool workflowCleanupEnabledForRun(WorkflowRun run, Logger log) {
  try {
    return WorkflowDefinition.fromJson(run.definitionJson).gitStrategy?.cleanupEnabled ?? true;
  } catch (e, st) {
    log.warning("Workflow '${run.id}': failed to resolve cleanup config; preserving worktrees", e, st);
    return false;
  }
}
