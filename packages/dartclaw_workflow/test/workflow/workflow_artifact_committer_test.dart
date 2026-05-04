@Tags(['component'])
library;

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
        WorkflowGitPort,
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

    test('rejects artifact project ids that would escape the dataDir project path', () async {
      await expectLater(
        () => resolveArtifactCommitProject(
          definition: const WorkflowDefinition(name: 'wf', description: 'test', project: '../etc', steps: []),
          step: const WorkflowStep(id: 's', name: 'S'),
          context: WorkflowContext(),
          strategy: const WorkflowGitArtifactsStrategy(),
          projectService: null,
          dataDir: tempDir.path,
          templateEngine: WorkflowTemplateEngine(),
        ),
        throwsFormatException,
      );
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
                outputs: {'plan': OutputConfig(format: OutputFormat.path)},
              ),
            ],
          ),
          step: const WorkflowStep(
            id: 'plan',
            name: 'Plan',
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

    test('skips runtime review findings during artifact commit resolution', () async {
      final repoDir = Directory(p.join(tempDir.path, 'projects', 'proj'))..createSync(recursive: true);
      final runtimeReport = p.join(
        tempDir.path,
        'workflows',
        'runs',
        'run-1',
        'runtime-artifacts',
        'reviews',
        'plan-review-codex-2026-04-30.md',
      );
      File(runtimeReport)
        ..createSync(recursive: true)
        ..writeAsStringSync('# Review\n');
      final git = FakeGitGateway()..initWorktree(repoDir.path);
      const reviewStep = WorkflowStep(
        id: 'plan-review',
        name: 'Review',
        skill: 'dartclaw-review',
        outputs: {'review_findings': OutputConfig(format: OutputFormat.path)},
      );

      final result = await maybeCommitStepArtifacts(
        ArtifactCommitPolicy(
          run: _run(),
          definition: const WorkflowDefinition(
            name: 'wf',
            description: 'test',
            project: 'proj',
            gitStrategy: WorkflowGitStrategy(artifacts: WorkflowGitArtifactsStrategy(commit: true)),
            steps: [reviewStep],
          ),
          step: reviewStep,
          context: WorkflowContext(data: {'review_findings': runtimeReport}),
          task: Task(
            id: 'task-1',
            title: 'Task',
            description: 'Task',
            // Review-style steps are read-only unless their allowedTools include file_write.
            type: TaskType.research,
            createdAt: DateTime(2026, 1, 1),
          ),
          projectService: null,
          dataDir: tempDir.path,
          templateEngine: WorkflowTemplateEngine(),
          workflowGitPort: git,
        ),
      );

      expect(result.failed, isFalse);
      expect(result.committedPaths, isEmpty);
      expect(result.skippedPaths, isEmpty);
      expect(git.events, isEmpty);
    });

    test('skips artifact commit for discover-project even when reused paths are present', () async {
      final repoDir = Directory(p.join(tempDir.path, 'projects', 'proj'))..createSync(recursive: true);
      final paths = ['docs/specs/reused/plan.md', 'docs/specs/reused/fis/s01.md'];
      for (final path in paths) {
        File(p.join(repoDir.path, path))
          ..createSync(recursive: true)
          ..writeAsStringSync(path);
      }
      final git = FakeGitGateway()..initWorktree(repoDir.path);
      for (final path in paths) {
        git.addUntracked(repoDir.path, path, content: path);
      }

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
                id: 'discover-project',
                name: 'Discover',
                skill: 'dartclaw-discover-project',
                outputs: {
                  'project_index': OutputConfig(format: OutputFormat.json, schema: 'project-index'),
                  'plan': OutputConfig(format: OutputFormat.path),
                  'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story-specs'),
                },
              ),
            ],
          ),
          step: const WorkflowStep(
            id: 'discover-project',
            name: 'Discover',
            skill: 'dartclaw-discover-project',
            outputs: {
              'project_index': OutputConfig(format: OutputFormat.json, schema: 'project-index'),
              'plan': OutputConfig(format: OutputFormat.path),
              'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story-specs'),
            },
          ),
          context: WorkflowContext(
            data: {
              'project_index': {
                'active_plan': 'docs/specs/reused/plan.md',
                'active_story_specs': {
                  'items': [
                    {'id': 'S01', 'title': 'One', 'spec_path': 'docs/specs/reused/fis/s01.md', 'dependencies': []},
                  ],
                },
              },
              'plan': 'docs/specs/reused/plan.md',
              'story_specs': {
                'items': [
                  {'id': 'S01', 'title': 'One', 'spec_path': 'docs/specs/reused/fis/s01.md', 'dependencies': []},
                ],
              },
            },
          ),
          task: Task(
            id: 'task-1',
            title: 'Task',
            description: 'Task',
            type: TaskType.research,
            createdAt: DateTime(2026, 1, 1),
          ),
          projectService: null,
          dataDir: tempDir.path,
          templateEngine: WorkflowTemplateEngine(),
          workflowGitPort: git,
        ),
      );

      expect(result.failed, isFalse);
      expect(result.committedPaths, isEmpty);
      expect(result.skippedPaths, isEmpty);
      for (final path in paths) {
        expect(await git.pathExistsAtRef(repoDir.path, ref: 'HEAD', path: path), isFalse);
      }
    });

    test('allows discover-project artifact commit when per-map-item bootstrap requires it', () async {
      final repoDir = Directory(p.join(tempDir.path, 'projects', 'proj'))..createSync(recursive: true);
      final paths = ['docs/specs/reused/plan.md', 'docs/specs/reused/fis/s01.md'];
      for (final path in paths) {
        File(p.join(repoDir.path, path))
          ..createSync(recursive: true)
          ..writeAsStringSync(path);
      }
      final git = FakeGitGateway()..initWorktree(repoDir.path);
      for (final path in paths) {
        git.addUntracked(repoDir.path, path, content: path);
      }

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
                id: 'discover-project',
                name: 'Discover',
                skill: 'dartclaw-discover-project',
                outputs: {
                  'project_index': OutputConfig(format: OutputFormat.json, schema: 'project-index'),
                  'plan': OutputConfig(format: OutputFormat.path),
                  'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story-specs'),
                },
              ),
              WorkflowStep(id: 'implement', name: 'Implement', mapOver: 'story_specs', maxParallel: 2),
            ],
          ),
          step: const WorkflowStep(
            id: 'discover-project',
            name: 'Discover',
            skill: 'dartclaw-discover-project',
            outputs: {
              'project_index': OutputConfig(format: OutputFormat.json, schema: 'project-index'),
              'plan': OutputConfig(format: OutputFormat.path),
              'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story-specs'),
            },
          ),
          context: WorkflowContext(
            data: {
              'project_index': {
                'active_plan': 'docs/specs/reused/plan.md',
                'active_story_specs': {
                  'items': [
                    {'id': 'S01', 'title': 'One', 'spec_path': 'docs/specs/reused/fis/s01.md', 'dependencies': []},
                  ],
                },
              },
              'plan': 'docs/specs/reused/plan.md',
              'story_specs': {
                'items': [
                  {'id': 'S01', 'title': 'One', 'spec_path': 'docs/specs/reused/fis/s01.md', 'dependencies': []},
                ],
              },
            },
          ),
          task: Task(
            id: 'task-1',
            title: 'Task',
            description: 'Task',
            type: TaskType.research,
            createdAt: DateTime(2026, 1, 1),
          ),
          projectService: null,
          dataDir: tempDir.path,
          templateEngine: WorkflowTemplateEngine(),
          workflowGitPort: git,
        ),
      );

      expect(result.failed, isFalse);
      expect(result.committedPaths, ['docs/specs/reused/fis/s01.md', 'docs/specs/reused/plan.md']);
      for (final path in paths) {
        expect(await git.pathExistsAtRef(repoDir.path, ref: 'HEAD', path: path), isTrue);
      }
    });

    test('later steps do not auto-commit reused story specs from prior context', () async {
      final repoDir = Directory(p.join(tempDir.path, 'projects', 'proj'))..createSync(recursive: true);
      final paths = ['docs/specs/reused/plan.md', 'docs/specs/reused/fis/s01.md'];
      for (final path in paths) {
        File(p.join(repoDir.path, path))
          ..createSync(recursive: true)
          ..writeAsStringSync(path);
      }
      final git = FakeGitGateway()..initWorktree(repoDir.path);
      for (final path in paths) {
        git.addUntracked(repoDir.path, path, content: path);
      }

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
                id: 'implement',
                name: 'Implement',
                outputs: {'story_result': OutputConfig(format: OutputFormat.text)},
              ),
            ],
          ),
          step: const WorkflowStep(
            id: 'implement',
            name: 'Implement',
            outputs: {'story_result': OutputConfig(format: OutputFormat.text)},
          ),
          context: WorkflowContext(
            data: {
              'plan': 'docs/specs/reused/plan.md',
              'story_specs': {
                'items': [
                  {'id': 'S01', 'title': 'One', 'spec_path': 'docs/specs/reused/fis/s01.md', 'dependencies': []},
                ],
              },
              'story_result': 'implemented',
            },
          ),
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

      expect(result.failed, isFalse);
      expect(result.committedPaths, isEmpty);
      for (final path in paths) {
        expect(await git.pathExistsAtRef(repoDir.path, ref: 'HEAD', path: path), isFalse);
      }
    });

    test('commits nested story specs and technical research sibling', () async {
      final repoDir = Directory(p.join(tempDir.path, 'projects', 'proj'))..createSync(recursive: true);
      final paths = [
        'docs/plans/p/plan.md',
        'docs/plans/p/.technical-research.md',
        'docs/plans/p/fis/s01.md',
        'docs/plans/p/fis/s02.md',
      ];
      for (final path in paths) {
        File(p.join(repoDir.path, path))
          ..createSync(recursive: true)
          ..writeAsStringSync(path);
      }
      final git = FakeGitGateway()..initWorktree(repoDir.path);
      for (final path in paths) {
        git.addUntracked(repoDir.path, path, content: path);
      }

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
                outputs: {
                  'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story-specs'),
                  'plan': OutputConfig(format: OutputFormat.path),
                },
              ),
            ],
          ),
          step: const WorkflowStep(
            id: 'plan',
            name: 'Plan',
            outputs: {
              'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story-specs'),
              'plan': OutputConfig(format: OutputFormat.path),
            },
          ),
          context: WorkflowContext(
            data: {
              'plan': 'docs/plans/p/plan.md',
              'story_specs': {
                'items': [
                  {'id': 'S01', 'title': 'One', 'spec_path': 'fis/s01.md'},
                  {'id': 'S02', 'title': 'Two', 'spec_path': 'fis/s02.md'},
                ],
              },
            },
          ),
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

      expect(result.failed, isFalse);
      expect(result.committedPaths, [
        'docs/plans/p/.technical-research.md',
        'docs/plans/p/fis/s01.md',
        'docs/plans/p/fis/s02.md',
        'docs/plans/p/plan.md',
      ]);
      for (final path in paths) {
        expect(await git.pathExistsAtRef(repoDir.path, ref: 'HEAD', path: path), isTrue);
      }
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
                outputs: {'plan': OutputConfig(format: OutputFormat.path)},
              ),
              WorkflowStep(id: 'implement', name: 'Implement', mapOver: 'story_specs', maxParallel: 2),
            ],
          ),
          step: const WorkflowStep(
            id: 'plan',
            name: 'Plan',
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

    group('artifact-commit boundary matrix', () {
      final planStep = const WorkflowStep(
        id: 'plan',
        name: 'Plan',
        outputs: {'plan': OutputConfig(format: OutputFormat.path)},
      );

      ArtifactCommitPolicy makePolicy({
        required Directory repoDir,
        WorkflowGitPort? port,
        String? project,
        Task? task,
      }) {
        return ArtifactCommitPolicy(
          run: _run(),
          definition: WorkflowDefinition(
            name: 'wf',
            description: 'test',
            project: project ?? 'proj',
            gitStrategy: const WorkflowGitStrategy(
              worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
              artifacts: WorkflowGitArtifactsStrategy(commit: true),
            ),
            steps: [planStep],
          ),
          step: planStep,
          context: WorkflowContext(data: {'plan': 'plan.md'}),
          task:
              task ??
              Task(
                id: 'task-1',
                title: 'Task',
                description: 'Task',
                type: TaskType.coding,
                createdAt: DateTime(2026, 1, 1),
              ),
          projectService: null,
          dataDir: tempDir.path,
          templateEngine: WorkflowTemplateEngine(),
          workflowGitPort: port,
        );
      }

      test('no WorkflowGitPort returns failed result', () async {
        final repoDir = Directory(p.join(tempDir.path, 'projects', 'proj'))..createSync(recursive: true);
        File(p.join(repoDir.path, 'plan.md')).writeAsStringSync('plan');

        final result = await maybeCommitStepArtifacts(makePolicy(repoDir: repoDir, port: null));

        expect(result.failed, isTrue);
        expect(result.failureReason, contains('no WorkflowGitPort'));
      });

      test('unresolved project returns failed result', () async {
        final repoDir = Directory(p.join(tempDir.path, 'projects', 'proj'))..createSync(recursive: true);
        File(p.join(repoDir.path, 'plan.md')).writeAsStringSync('plan');
        final git = FakeGitGateway()..initWorktree(repoDir.path);

        final policy = ArtifactCommitPolicy(
          run: _run(),
          definition: const WorkflowDefinition(
            name: 'wf',
            description: 'test',
            // No project at all — cannot resolve.
            gitStrategy: WorkflowGitStrategy(
              worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
              artifacts: WorkflowGitArtifactsStrategy(commit: true),
            ),
            steps: [
              WorkflowStep(
                id: 'plan',
                name: 'Plan',
                outputs: {'plan': OutputConfig(format: OutputFormat.path)},
              ),
            ],
          ),
          step: planStep,
          context: WorkflowContext(data: {'plan': 'plan.md'}),
          task: Task(id: 't', title: 'T', description: 'T', type: TaskType.coding, createdAt: DateTime(2026, 1, 1)),
          projectService: null,
          dataDir: tempDir.path,
          templateEngine: WorkflowTemplateEngine(),
          workflowGitPort: git,
        );

        final result = await maybeCommitStepArtifacts(policy);

        expect(result.failed, isTrue);
        expect(result.failureReason, contains('no project id'));
      });

      test('missing directory returns failed result', () async {
        final repoDir = Directory(p.join(tempDir.path, 'projects', 'proj'));
        // Intentionally NOT creating repoDir — directory does not exist.
        final git = FakeGitGateway()..initWorktree('/nonexistent');

        final result = await maybeCommitStepArtifacts(makePolicy(repoDir: repoDir, port: git));

        expect(result.failed, isTrue);
        expect(result.failureReason, contains('does not exist'));
      });

      test('staged empty + artifact missing at HEAD returns failed result', () async {
        final repoDir = Directory(p.join(tempDir.path, 'projects', 'proj'))..createSync(recursive: true);
        File(p.join(repoDir.path, 'plan.md')).writeAsStringSync('plan');
        // initWorktree with empty files dict — HEAD commit has no files.
        final git = FakeGitGateway()..initWorktree(repoDir.path, files: {});
        // Add plan.md to the working tree but it won't stage (already in modified but not HEAD).
        // To simulate: add untracked, then don't call add before we run the policy.
        // Actually to get staged-empty with missing-at-HEAD: don't add untracked to the git index.
        // The committer calls git.add(), which moves untracked → staged.
        // For staged-empty we need the file to NOT be in staged after add.
        // The FakeGitGateway.add only stages files that are in `modified` or `untracked`.
        // If the file is not there, add() is a no-op → staged stays empty.
        // And pathExistsAtRef(HEAD) returns false if it's not in the HEAD commit.
        // The file is on disk but not tracked in git at all.
        // Don't call addUntracked — file exists on disk but git doesn't know about it.

        final result = await maybeCommitStepArtifacts(makePolicy(repoDir: repoDir, port: git));

        expect(result.failed, isTrue);
        expect(result.failureReason, contains('missing at HEAD'));
      });

      test('staged empty + artifact present at HEAD returns skipped result', () async {
        final repoDir = Directory(p.join(tempDir.path, 'projects', 'proj'))..createSync(recursive: true);
        File(p.join(repoDir.path, 'plan.md')).writeAsStringSync('plan');
        // Commit the file so it IS present at HEAD.
        final git = FakeGitGateway()..initWorktree(repoDir.path, files: {'plan.md': 'plan'});
        // File is in HEAD commit, nothing staged — returns skipped (already committed).

        final result = await maybeCommitStepArtifacts(makePolicy(repoDir: repoDir, port: git));

        expect(result.failed, isFalse);
        expect(result.committedPaths, isEmpty); // already at HEAD — skipped
      });
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
