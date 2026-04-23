import 'dart:io';

import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGitGateway;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OutputConfig,
        OutputFormat,
        Task,
        TaskType,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowGitArtifactsStrategy,
        WorkflowGitStrategy,
        WorkflowGitWorktreeStrategy,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep;
import 'package:dartclaw_workflow/src/workflow/workflow_artifact_committer.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_template_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('workflow_artifact_committer', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('workflow_artifact_committer_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('detects path-output and skill artifact producers', () {
      expect(
        workflowHasArtifactProducer(
          const WorkflowDefinition(
            name: 'wf',
            description: 'test',
            steps: [
              WorkflowStep(
                id: 'plan',
                name: 'Plan',
                outputs: {'plan': OutputConfig(format: OutputFormat.path)},
              ),
            ],
          ),
        ),
        isTrue,
      );
      expect(
        workflowHasArtifactProducer(
          const WorkflowDefinition(
            name: 'wf',
            description: 'test',
            steps: [WorkflowStep(id: 'prd', name: 'PRD', skill: 'dartclaw-prd')],
          ),
        ),
        isTrue,
      );
    });

    test('resolves artifact project to dataDir project path', () async {
      final resolved = await resolveArtifactCommitProject(
        definition: const WorkflowDefinition(name: 'wf', description: 'test', project: 'proj', steps: []),
        step: const WorkflowStep(id: 's', name: 'S'),
        context: WorkflowContext(),
        strategy: const WorkflowGitArtifactsStrategy(),
        projectService: null,
        dataDir: tempDir.path,
        templateEngine: WorkflowTemplateEngine(),
      );

      expect(resolved?.projectId, equals('proj'));
      expect(resolved?.dir, equals(p.join(tempDir.path, 'projects', 'proj')));
    });

    test('commits path output when artifact commit is enabled', () async {
      final repoDir = Directory(p.join(tempDir.path, 'projects', 'proj'))..createSync(recursive: true);
      File(p.join(repoDir.path, 'plan.md')).writeAsStringSync('plan');
      final git = FakeGitGateway()..initWorktree(repoDir.path);
      git.addUntracked(repoDir.path, 'plan.md', content: 'plan');

      final result = await maybeCommitStepArtifacts(
        ArtifactCommitPolicy(
          run: _run(),
          definition: const WorkflowDefinition(
            name: 'wf',
            description: 'test',
            project: 'proj',
            gitStrategy: WorkflowGitStrategy(artifacts: WorkflowGitArtifactsStrategy(commit: true)),
            steps: [
              WorkflowStep(
                id: 'plan',
                name: 'Plan',
                contextOutputs: ['plan'],
                outputs: {'plan': OutputConfig(format: OutputFormat.path)},
              ),
            ],
          ),
          step: const WorkflowStep(
            id: 'plan',
            name: 'Plan',
            contextOutputs: ['plan'],
            outputs: {'plan': OutputConfig(format: OutputFormat.path)},
          ),
          context: WorkflowContext(data: {'plan': 'plan.md'}),
          task: Task(
            id: 'task-1',
            title: 'Task',
            description: 'Task',
            type: TaskType.coding,
            createdAt: DateTime(2026, 1, 1),
          ),
          projectService: null,
          dataDir: tempDir.path,
          templateEngine: WorkflowTemplateEngine(),
          workflowGitPort: git,
        ),
      );

      expect(result.committedPaths, ['plan.md']);
      expect(result.failed, isFalse);
      expect(await git.pathExistsAtRef(repoDir.path, ref: 'HEAD', path: 'plan.md'), isTrue);
    });

    test('returns fatal failure for load-bearing per-map-item artifact add failure', () async {
      final repoDir = Directory(p.join(tempDir.path, 'projects', 'proj'))..createSync(recursive: true);
      File(p.join(repoDir.path, 'plan.md')).writeAsStringSync('plan');
      final git = FakeGitGateway()
        ..initWorktree(repoDir.path)
        ..addUntracked(repoDir.path, 'plan.md', content: 'plan')
        ..failNextAdd('add failed');

      final result = await maybeCommitStepArtifacts(
        ArtifactCommitPolicy(
          run: _run(),
          definition: const WorkflowDefinition(
            name: 'wf',
            description: 'test',
            project: 'proj',
            gitStrategy: WorkflowGitStrategy(
              worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
              artifacts: WorkflowGitArtifactsStrategy(commit: true),
            ),
            steps: [
              WorkflowStep(
                id: 'plan',
                name: 'Plan',
                contextOutputs: ['plan'],
                outputs: {'plan': OutputConfig(format: OutputFormat.path)},
              ),
              WorkflowStep(id: 'implement', name: 'Implement', mapOver: 'story_specs', maxParallel: 2),
            ],
          ),
          step: const WorkflowStep(
            id: 'plan',
            name: 'Plan',
            contextOutputs: ['plan'],
            outputs: {'plan': OutputConfig(format: OutputFormat.path)},
          ),
          context: WorkflowContext(data: {'plan': 'plan.md'}),
          task: Task(
            id: 'task-1',
            title: 'Task',
            description: 'Task',
            type: TaskType.coding,
            createdAt: DateTime(2026, 1, 1),
          ),
          projectService: null,
          dataDir: tempDir.path,
          templateEngine: WorkflowTemplateEngine(),
          workflowGitPort: git,
        ),
      );

      expect(result.failed, isTrue);
      expect(result.fatal, isTrue);
      expect(result.failureReason, contains('add failed'));
    });
  });
}

WorkflowRun _run() {
  final now = DateTime(2026, 1, 1);
  return WorkflowRun(
    id: 'run-1',
    definitionName: 'wf',
    status: WorkflowRunStatus.running,
    startedAt: now,
    updatedAt: now,
  );
}
