import 'package:path/path.dart' as p;

final _workflowRunIdPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// Returns the absolute workflow run directory for [runId] under [dataDir].
String workflowRunDir({required String dataDir, required String runId}) {
  _validateWorkflowRunId(runId);
  return p.normalize(p.absolute(dataDir, 'workflows', 'runs', runId));
}

/// Returns the persisted workflow context JSON path for [runId].
String workflowRunContextJson({required String dataDir, required String runId}) =>
    p.join(workflowRunDir(dataDir: dataDir, runId: runId), 'context.json');

/// Returns the absolute runtime-artifacts directory for [runId] under [dataDir].
String workflowRuntimeArtifactsDir({required String dataDir, required String runId}) =>
    p.join(workflowRunDir(dataDir: dataDir, runId: runId), 'runtime-artifacts');

/// Returns the directory for merge-resolve attempt artifacts for [runId].
String workflowMergeResolveAttemptsDir({required String dataDir, required String runId}) =>
    p.join(workflowRuntimeArtifactsDir(dataDir: dataDir, runId: runId), 'merge-resolve');

void _validateWorkflowRunId(String runId) {
  if (!_workflowRunIdPattern.hasMatch(runId)) {
    throw ArgumentError.value(runId, 'runId', 'must contain only letters, digits, underscores, and hyphens');
  }
}
