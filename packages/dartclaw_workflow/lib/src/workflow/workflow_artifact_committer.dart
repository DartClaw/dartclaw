import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show OutputFormat, ProjectService, Task;
import 'package:dartclaw_models/dartclaw_models.dart'
    show WorkflowDefinition, WorkflowGitArtifactsStrategy, WorkflowNode, WorkflowRun, WorkflowStep;
import 'package:dartclaw_security/dartclaw_security.dart' show ProcessEnvironmentPlan, SafeProcess;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'workflow_context.dart';
import 'workflow_runner_types.dart';
import 'workflow_template_engine.dart';

final _log = Logger('WorkflowArtifactCommitter');

const _artifactCommitAuthorName = 'DartClaw Workflow';
const _artifactCommitAuthorEmail = 'workflow@dartclaw.local';

const _artifactProducingSkills = <String>{
  'dartclaw-prd',
  'dartclaw-plan',
  'dartclaw-spec',
  'dartclaw-remediate-findings',
};

final class _EmptyProcessEnvironmentPlan implements ProcessEnvironmentPlan {
  @override
  final Map<String, String> environment;

  const _EmptyProcessEnvironmentPlan() : environment = const <String, String>{};
}

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

  const ArtifactCommitPolicy({
    required this.run,
    required this.definition,
    required this.step,
    required this.context,
    required this.task,
    required this.projectService,
    required this.dataDir,
    required this.templateEngine,
  });
}

/// Commits path artifacts for successful handoffs when the workflow requests it.
Future<void> maybeCommitArtifacts(WorkflowNode node, StepHandoff handoff, ArtifactCommitPolicy policy) async {
  if (handoff is! StepHandoffSuccess) return;
  if (!node.stepIds.contains(policy.step.id)) return;
  await maybeCommitStepArtifacts(policy);
}

/// Commits any path outputs produced by [policy.step].
Future<void> maybeCommitStepArtifacts(ArtifactCommitPolicy policy) async {
  final definition = policy.definition;
  final step = policy.step;
  final artifacts = definition.gitStrategy?.artifacts;
  final hasProducer = workflowHasArtifactProducer(definition);
  final shouldCommit = artifacts?.commit ?? hasProducer;
  if (!shouldCommit) return;
  if (artifacts == null && !hasProducer) return;

  final outputs = step.outputs;
  if (outputs == null) return;
  final producedPaths = <String>[];
  for (final outKey in step.contextOutputs) {
    final cfg = outputs[outKey];
    if (cfg == null || cfg.format != OutputFormat.path) continue;
    final value = policy.context[outKey]?.toString().trim() ?? '';
    if (value.isEmpty || value == 'null') continue;
    producedPaths.add(value);
  }
  if (producedPaths.isEmpty) return;

  final resolved = await resolveArtifactCommitProject(
    definition: definition,
    step: step,
    context: policy.context,
    strategy: artifacts ?? const WorkflowGitArtifactsStrategy(),
    projectService: policy.projectService,
    dataDir: policy.dataDir,
    templateEngine: policy.templateEngine,
  );
  if (resolved == null) {
    _log.warning(
      "artifact-commit: step '${step.id}' produced paths but no project id "
      'could be resolved (checked gitStrategy.artifacts.project, step.project, '
      'and the {{PROJECT}} workflow variable)',
    );
    return;
  }
  final worktreeDir = (policy.task.worktreeJson?['path'] as String?)?.trim();
  final effectiveWorktreeDir = switch (worktreeDir) {
    final String dir when dir.isNotEmpty && Directory(dir).existsSync() => dir,
    _ => null,
  };
  final projectDir = effectiveWorktreeDir ?? resolved.dir;

  if (!Directory(projectDir).existsSync()) {
    _log.warning(
      "artifact-commit: step '${step.id}' resolved project '${resolved.projectId}' "
      "but directory '$projectDir' does not exist — skipping commit",
    );
    return;
  }

  final messageTemplate = artifacts?.commitMessage ?? 'chore(workflow): artifacts for run {{runId}}';
  final resolvedMessage = policy.templateEngine
      .resolve(messageTemplate.replaceAll('{{runId}}', policy.run.id), policy.context)
      .trim();
  final commitMessage = resolvedMessage.isEmpty
      ? 'chore(workflow): artifacts for run ${policy.run.id}'
      : resolvedMessage;

  try {
    final addResult = await SafeProcess.git(
      ['add', '--', ...producedPaths],
      plan: const _EmptyProcessEnvironmentPlan(),
      workingDirectory: projectDir,
      noSystemConfig: true,
    );
    if (addResult.exitCode != 0) {
      _log.warning("artifact-commit: git add failed in '$projectDir': ${addResult.stderr}");
      return;
    }
    final stagedResult = await SafeProcess.git(
      ['diff', '--cached', '--name-only'],
      plan: const _EmptyProcessEnvironmentPlan(),
      workingDirectory: projectDir,
      noSystemConfig: true,
    );
    final staged = (stagedResult.stdout as String).trim();
    if (staged.isEmpty) {
      _log.info("artifact-commit: no staged changes in '$projectDir' after step '${step.id}' — skipping commit");
      return;
    }
    final commitResult = await SafeProcess.git(
      [
        '-c',
        'user.name=$_artifactCommitAuthorName',
        '-c',
        'user.email=$_artifactCommitAuthorEmail',
        'commit',
        '-m',
        commitMessage,
      ],
      plan: const _EmptyProcessEnvironmentPlan(),
      workingDirectory: projectDir,
      noSystemConfig: true,
    );
    if (commitResult.exitCode != 0) {
      _log.warning("artifact-commit: git commit failed in '$projectDir': ${commitResult.stderr}");
      return;
    }
    _log.info(
      "artifact-commit: committed ${producedPaths.length} file(s) in '$projectDir' "
      "after step '${step.id}' with message '$commitMessage'",
    );
  } catch (e) {
    _log.warning("artifact-commit: unexpected error for step '${step.id}' in '$projectDir': $e");
  }
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
      _resolveProjectTemplate(strategy.project, context, templateEngine) ??
      _resolveProjectTemplate(step.project, context, templateEngine) ??
      _resolveProjectTemplate(definition.project, context, templateEngine);
  if (projectId == null) return null;
  final project = await projectService?.get(projectId);
  final localPath = project?.localPath.trim();
  final dir = (localPath != null && localPath.isNotEmpty) ? localPath : p.join(dataDir, 'projects', projectId);
  return ResolvedArtifactProject(projectId: projectId, dir: dir, exists: Directory(dir).existsSync());
}

String? _resolveProjectTemplate(String? template, WorkflowContext context, WorkflowTemplateEngine templateEngine) {
  if (template == null) return null;
  final resolved = templateEngine.resolve(template, context).trim();
  return resolved.isEmpty ? null : resolved;
}

/// Resolved artifact-commit target project.
final class ResolvedArtifactProject {
  final String projectId;
  final String dir;
  final bool exists;

  const ResolvedArtifactProject({required this.projectId, required this.dir, required this.exists});
}
