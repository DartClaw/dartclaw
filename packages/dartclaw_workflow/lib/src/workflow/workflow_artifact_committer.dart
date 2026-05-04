import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show OutputFormat, ProjectService, Task;
import 'package:dartclaw_models/dartclaw_models.dart'
    show WorkflowDefinition, WorkflowGitArtifactsStrategy, WorkflowNode, WorkflowRun, WorkflowStep;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'step_config_policy.dart' as step_config_policy;
import 'produced_artifact_resolver.dart';
import 'workflow_context.dart';
import 'workflow_git_port.dart';
import 'workflow_run_paths.dart';
import 'workflow_runner_types.dart';
import 'workflow_template_engine.dart';

final _log = Logger('WorkflowArtifactCommitter');

const _artifactCommitAuthorName = 'DartClaw Workflow';
const _artifactCommitAuthorEmail = 'workflow@dartclaw.local';

const _artifactProducingSkills = <String>{
  'dartclaw-prd',
  'dartclaw-plan',
  'dartclaw-spec',
  'dartclaw-review',
  'dartclaw-architecture',
  'dartclaw-remediate-findings',
};

/// Policy inputs needed to commit path artifacts after a successful step.
final class ArtifactCommitPolicy {
  final WorkflowRun run;
  final WorkflowDefinition definition;
  final WorkflowStep step;
  final WorkflowContext context;
  final Task task;
  final ProjectService? projectService;
  final String dataDir;
  final WorkflowTemplateEngine templateEngine;
  final WorkflowGitPort? workflowGitPort;

  const ArtifactCommitPolicy({
    required this.run,
    required this.definition,
    required this.step,
    required this.context,
    required this.task,
    required this.projectService,
    required this.dataDir,
    required this.templateEngine,
    this.workflowGitPort,
  });
}

/// Outcome of an artifact auto-commit attempt.
final class ArtifactCommitResult {
  final List<String> committedPaths;
  final List<String> skippedPaths;
  final String? commitSha;
  final String? failureReason;
  final bool fatal;

  const ArtifactCommitResult._({
    this.committedPaths = const <String>[],
    this.skippedPaths = const <String>[],
    this.commitSha,
    this.failureReason,
    this.fatal = false,
  });

  const ArtifactCommitResult.skipped({List<String> skippedPaths = const <String>[]})
    : this._(skippedPaths: skippedPaths);

  const ArtifactCommitResult.committed({required List<String> committedPaths, required String commitSha})
    : this._(committedPaths: committedPaths, commitSha: commitSha);

  const ArtifactCommitResult.failed({
    required String failureReason,
    List<String> skippedPaths = const <String>[],
    required bool fatal,
  }) : this._(failureReason: failureReason, skippedPaths: skippedPaths, fatal: fatal);

  bool get failed => failureReason != null;
}

/// Commits path artifacts for successful handoffs when the workflow requests it.
Future<ArtifactCommitResult> maybeCommitArtifacts(
  WorkflowNode node,
  StepHandoff handoff,
  ArtifactCommitPolicy policy,
) async {
  if (handoff is! StepHandoffSuccess) return const ArtifactCommitResult.skipped();
  if (!node.stepIds.contains(policy.step.id)) return const ArtifactCommitResult.skipped();
  return maybeCommitStepArtifacts(policy);
}

/// Commits any path outputs produced by [policy.step].
Future<ArtifactCommitResult> maybeCommitStepArtifacts(ArtifactCommitPolicy policy) async {
  final definition = policy.definition;
  final step = policy.step;
  if ((step.id == 'discover-project' || step.skill == 'dartclaw-discover-project') &&
      !step_config_policy.requiresPerMapItemBootstrap(
        definition,
        policy.context,
        templateEngine: policy.templateEngine,
      )) {
    return const ArtifactCommitResult.skipped();
  }
  final artifacts = definition.gitStrategy?.artifacts;
  final hasProducer = workflowHasArtifactProducer(definition);
  final shouldCommit = artifacts?.commit ?? hasProducer;
  if (!shouldCommit) return const ArtifactCommitResult.skipped();
  if (artifacts == null && !hasProducer) return const ArtifactCommitResult.skipped();

  final resolver = const ProducedArtifactResolver();
  final outputValues = <String, Object?>{
    for (final key in step.outputKeys)
      if (policy.context.data.containsKey(key)) key: policy.context.data[key],
  };
  if (policy.context.data.containsKey('project_index')) {
    outputValues['project_index'] = policy.context.data['project_index'];
  }
  final planDir = _planDirFromOutputs(outputValues);
  final runtimeArtifactsRoot = _runtimeArtifactsRoot(policy);
  final preliminaryArtifacts = resolver.resolve(
    step: step,
    outputs: outputValues,
    planDir: planDir,
    runtimeArtifactsRoot: runtimeArtifactsRoot,
  );
  if (preliminaryArtifacts.requiredPaths.isEmpty) {
    return const ArtifactCommitResult.skipped();
  }

  final failureIsFatal = artifactCommitFailureIsFatal(policy);
  final git = policy.workflowGitPort;
  if (git == null) {
    final reason = "artifact-commit: no WorkflowGitPort configured for step '${step.id}'";
    _log.warning(reason);
    return ArtifactCommitResult.failed(
      failureReason: reason,
      skippedPaths: preliminaryArtifacts.requiredPaths,
      fatal: failureIsFatal,
    );
  }

  final ResolvedArtifactProject? resolved;
  try {
    resolved = await resolveArtifactCommitProject(
      definition: definition,
      step: step,
      context: policy.context,
      strategy: artifacts ?? const WorkflowGitArtifactsStrategy(),
      projectService: policy.projectService,
      dataDir: policy.dataDir,
      templateEngine: policy.templateEngine,
    );
  } on FormatException catch (e) {
    final reason = "artifact-commit: invalid project id for step '${step.id}': ${e.message}";
    _log.warning(reason);
    return ArtifactCommitResult.failed(
      failureReason: reason,
      skippedPaths: preliminaryArtifacts.requiredPaths,
      fatal: failureIsFatal,
    );
  }
  if (resolved == null) {
    _log.warning(
      "artifact-commit: step '${step.id}' produced paths but no project id "
      'could be resolved (checked gitStrategy.artifacts.project and '
      'the workflow-level project binding)',
    );
    return ArtifactCommitResult.failed(
      failureReason: "artifact-commit: no project id resolved for step '${step.id}'",
      skippedPaths: preliminaryArtifacts.requiredPaths,
      fatal: failureIsFatal,
    );
  }
  final worktreeDir = (policy.task.worktreeJson?['path'] as String?)?.trim();
  final effectiveWorktreeDir = switch (worktreeDir) {
    final String dir when dir.isNotEmpty && Directory(dir).existsSync() && _isGitWorktree(dir) => dir,
    _ => null,
  };
  final projectDir = effectiveWorktreeDir ?? resolved.dir;

  if (!Directory(projectDir).existsSync()) {
    _log.warning(
      "artifact-commit: step '${step.id}' resolved project '${resolved.projectId}' "
      "but directory '$projectDir' does not exist — skipping commit",
    );
    return ArtifactCommitResult.failed(
      failureReason: "artifact-commit: directory '$projectDir' does not exist",
      skippedPaths: preliminaryArtifacts.requiredPaths,
      fatal: failureIsFatal,
    );
  }

  final List<String> producedPaths;
  try {
    final producedArtifacts = resolver.resolve(
      step: step,
      outputs: outputValues,
      planDir: planDir,
      projectRoot: projectDir,
      runtimeArtifactsRoot: runtimeArtifactsRoot,
    );
    producedPaths = producedArtifacts.requiredPaths;
  } on FormatException catch (e) {
    final reason = "artifact-commit: unsafe produced artifact path for step '${step.id}': ${e.message}";
    _log.warning(reason);
    return ArtifactCommitResult.failed(
      failureReason: reason,
      skippedPaths: preliminaryArtifacts.requiredPaths,
      fatal: failureIsFatal,
    );
  }
  if (producedPaths.isEmpty) return const ArtifactCommitResult.skipped();

  final messageTemplate = artifacts?.commitMessage ?? 'chore(workflow): artifacts for run {{runId}}';
  final resolvedMessage = policy.templateEngine
      .resolve(messageTemplate.replaceAll('{{runId}}', policy.run.id), policy.context)
      .trim();
  final commitMessage = resolvedMessage.isEmpty
      ? 'chore(workflow): artifacts for run ${policy.run.id}'
      : resolvedMessage;

  try {
    await git.add(projectDir, producedPaths);
    final staged = await git.diffNameOnly(projectDir, cached: true);
    if (staged.isEmpty) {
      final missingAtHead = await _pathsMissingAtHead(git, projectDir, producedPaths);
      if (missingAtHead.isNotEmpty) {
        final reason = "artifact-commit: required artifacts missing at HEAD for step '${step.id}': $missingAtHead";
        _log.warning(reason);
        return ArtifactCommitResult.failed(failureReason: reason, skippedPaths: missingAtHead, fatal: failureIsFatal);
      }
      _log.info("artifact-commit: no staged changes in '$projectDir' after step '${step.id}' — skipping commit");
      return ArtifactCommitResult.skipped(skippedPaths: producedPaths);
    }
    final commit = await git.commit(
      projectDir,
      message: commitMessage,
      authorName: _artifactCommitAuthorName,
      authorEmail: _artifactCommitAuthorEmail,
    );
    _log.info(
      "artifact-commit: committed ${staged.length} file(s) in '$projectDir' "
      "after step '${step.id}' with message '$commitMessage'",
    );
    final missingAtHead = await _pathsMissingAtHead(git, projectDir, producedPaths);
    if (missingAtHead.isNotEmpty) {
      final reason = "artifact-commit: required artifacts missing at HEAD for step '${step.id}': $missingAtHead";
      _log.warning(reason);
      return ArtifactCommitResult.failed(failureReason: reason, skippedPaths: missingAtHead, fatal: failureIsFatal);
    }
    return ArtifactCommitResult.committed(committedPaths: staged, commitSha: commit.sha);
  } on WorkflowGitException catch (e) {
    final reason = "artifact-commit: ${e.message} in '$projectDir'";
    _log.warning('$reason: ${e.stderr.isNotEmpty ? e.stderr : e.stdout}');
    return ArtifactCommitResult.failed(failureReason: reason, skippedPaths: producedPaths, fatal: failureIsFatal);
  } catch (e) {
    final reason = "artifact-commit: unexpected error for step '${step.id}' in '$projectDir': $e";
    _log.warning(reason);
    return ArtifactCommitResult.failed(failureReason: reason, skippedPaths: producedPaths, fatal: failureIsFatal);
  }
}

String _runtimeArtifactsRoot(ArtifactCommitPolicy policy) =>
    workflowRuntimeArtifactsDir(dataDir: policy.dataDir, runId: policy.run.id);

String _planDirFromOutputs(Map<String, Object?> outputs) {
  final explicitPlanPath = (outputs['plan'] as String?)?.trim();
  final projectIndex = switch (outputs['project_index']) {
    final Map<dynamic, dynamic> map => map,
    _ => null,
  };
  final planPath = explicitPlanPath == null || explicitPlanPath.isEmpty
      ? (projectIndex?['active_plan'] as String?)?.trim()
      : explicitPlanPath;
  return planPath == null || planPath.isEmpty ? '' : p.dirname(planPath);
}

Future<List<String>> _pathsMissingAtHead(WorkflowGitPort git, String projectDir, List<String> paths) async {
  final missing = <String>[];
  for (final path in paths) {
    if (!await git.pathExistsAtRef(projectDir, ref: 'HEAD', path: path)) {
      missing.add(path);
    }
  }
  return missing;
}

/// Returns true when a commit failure prevents downstream per-map-item worktrees
/// from inheriting artifacts through the workflow branch.
bool artifactCommitFailureIsFatal(ArtifactCommitPolicy policy) {
  if (policy.definition.gitStrategy?.artifacts?.commit != true) return false;
  return step_config_policy.requiresPerMapItemBootstrap(
    policy.definition,
    policy.context,
    templateEngine: policy.templateEngine,
  );
}

/// True when a workflow contains at least one artifact-producing step.
bool workflowHasArtifactProducer(WorkflowDefinition definition) {
  for (final step in definition.steps) {
    if (step.skill != null && _artifactProducingSkills.contains(step.skill)) return true;
    final outputs = step.outputs;
    if (outputs == null) continue;
    for (final cfg in outputs.values) {
      if (cfg.format == OutputFormat.path) return true;
    }
  }
  return false;
}

/// Resolves the project working tree used for artifact commits.
Future<ResolvedArtifactProject?> resolveArtifactCommitProject({
  required WorkflowDefinition definition,
  required WorkflowStep step,
  required WorkflowContext context,
  required WorkflowGitArtifactsStrategy strategy,
  required ProjectService? projectService,
  required String dataDir,
  required WorkflowTemplateEngine templateEngine,
}) async {
  final projectId =
      _resolveArtifactProjectTemplate(strategy.project, context, templateEngine) ??
      _resolveArtifactProjectTemplate(definition.project, context, templateEngine);
  if (projectId == null) return null;
  if (!_validProjectId.hasMatch(projectId)) {
    throw FormatException('project id "$projectId" must match [A-Za-z0-9._-]+');
  }
  final project = await projectService?.get(projectId);
  final localPath = project?.localPath.trim();
  final dir = (localPath != null && localPath.isNotEmpty) ? localPath : p.join(dataDir, 'projects', projectId);
  return ResolvedArtifactProject(projectId: projectId, dir: dir, exists: Directory(dir).existsSync());
}

final _validProjectId = RegExp(r'^[A-Za-z0-9._-]+$');

String? _resolveArtifactProjectTemplate(
  String? template,
  WorkflowContext context,
  WorkflowTemplateEngine templateEngine,
) {
  if (template == null) return null;
  final resolved = templateEngine.resolve(template, context).trim();
  return resolved.isEmpty ? null : resolved;
}

bool _isGitWorktree(String dir) {
  return Directory(p.join(dir, '.git')).existsSync() || File(p.join(dir, '.git')).existsSync();
}

/// Resolved artifact-commit target project.
final class ResolvedArtifactProject {
  final String projectId;
  final String dir;
  final bool exists;

  const ResolvedArtifactProject({required this.projectId, required this.dir, required this.exists});
}
