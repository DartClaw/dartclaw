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

/// Environment variable name carrying the host-created per-step artifacts
/// directory, exported into every workflow task's spawn environment.
///
/// An agent references `"$DARTCLAW_STEP_ARTIFACTS_DIR"` in shell invocations
/// instead of retyping a UUID-bearing absolute path (transcription-proofing),
/// and the host captures review artifacts deterministically from the same dir.
const String stepArtifactsDirEnvVar = 'DARTCLAW_STEP_ARTIFACTS_DIR';

/// Returns the host-owned artifacts directory for one workflow step.
///
/// Lives at `<runtime-artifacts>/steps/<stepId>`, with a `-<mapIterationIndex>`
/// suffix when the step runs as a parallel map iteration so concurrent
/// iterations get disjoint dirs. Both the task factory (write side) and the
/// context extractor (read side) must derive the path through this function.
String workflowStepArtifactsDir({
  required String dataDir,
  required String runId,
  required String stepId,
  int? mapIterationIndex,
}) {
  final slug = stepId.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
  final dirName = mapIterationIndex == null ? slug : '$slug-$mapIterationIndex';
  return p.join(workflowRuntimeArtifactsDir(dataDir: dataDir, runId: runId), 'steps', dirName);
}

void _validateWorkflowRunId(String runId) {
  if (!_workflowRunIdPattern.hasMatch(runId)) {
    throw ArgumentError.value(runId, 'runId', 'must contain only letters, digits, underscores, and hyphens');
  }
}
