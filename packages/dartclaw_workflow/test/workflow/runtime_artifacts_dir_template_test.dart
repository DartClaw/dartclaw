@Tags(['component'])
library;

import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowContext, WorkflowDefinition, WorkflowStep;
import 'package:dartclaw_workflow/src/workflow/workflow_run_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  test('workflow.runtime_artifacts_dir renders to the per-run data-dir path before task launch', () async {
    final definition = WorkflowDefinition(
      name: 'runtime-artifacts',
      description: 'Runtime artifacts workflow',
      steps: const [
        WorkflowStep(
          id: 'review',
          name: 'Review',
          prompts: ['--output-dir {{workflow.runtime_artifacts_dir}}/reviews'],
        ),
      ],
    );

    final task = await h.executeAndCaptureSingleTask(
      definition: definition,
      context: WorkflowContext(),
      runId: 'run-X',
    );
    final runtimeArtifactsDir = p.join(h.tempDir.path, 'workflows', 'runs', 'run-X', 'runtime-artifacts');

    expect(task.description, contains('--output-dir $runtimeArtifactsDir/reviews'));
    expect(Directory(runtimeArtifactsDir).existsSync(), isTrue);
    expect(Directory(p.join(runtimeArtifactsDir, 'reviews')).existsSync(), isTrue);
  });

  test('workflow.runtime_artifacts_dir renders absolute when data dir is relative', () async {
    final relativeDataDir = '.dartclaw-dev-test-${DateTime.now().microsecondsSinceEpoch}';
    try {
      h.executor = h.makeExecutor(dataDir: relativeDataDir);
      final definition = WorkflowDefinition(
        name: 'runtime-artifacts',
        description: 'Runtime artifacts workflow',
        steps: const [
          WorkflowStep(
            id: 'review',
            name: 'Review',
            prompts: ['--output-dir {{workflow.runtime_artifacts_dir}}/reviews'],
          ),
        ],
      );

      final task = await h.executeAndCaptureSingleTask(
        definition: definition,
        context: WorkflowContext(),
        runId: 'run-relative',
      );
      final runtimeArtifactsDir = p.normalize(
        p.absolute(relativeDataDir, 'workflows', 'runs', 'run-relative', 'runtime-artifacts'),
      );

      expect(p.isRelative(relativeDataDir), isTrue);
      expect(p.basename(relativeDataDir), startsWith('.dartclaw-dev'));
      expect(p.isAbsolute(runtimeArtifactsDir), isTrue);
      expect(task.description, contains('--output-dir $runtimeArtifactsDir/reviews'));
      expect(task.description, isNot(contains('--output-dir $relativeDataDir/')));
      expect(Directory(p.join(runtimeArtifactsDir, 'reviews')).existsSync(), isTrue);
    } finally {
      final dataDir = Directory(relativeDataDir);
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    }
  });

  test('workflow.runtime_artifacts_dir remains quoted when data dir contains spaces', () async {
    final spacedDataDir = Directory(p.join(h.tempDir.path, 'DartClaw Data'))..createSync();
    h.executor = h.makeExecutor(dataDir: spacedDataDir.path);
    final definition = WorkflowDefinition(
      name: 'runtime-artifacts',
      description: 'Runtime artifacts workflow',
      steps: const [
        WorkflowStep(
          id: 'review',
          name: 'Review',
          prompts: ['--output-dir "{{workflow.runtime_artifacts_dir}}/reviews"'],
        ),
      ],
    );

    final task = await h.executeAndCaptureSingleTask(
      definition: definition,
      context: WorkflowContext(),
      runId: 'run-spaced',
    );
    final runtimeArtifactsDir = p.join(spacedDataDir.path, 'workflows', 'runs', 'run-spaced', 'runtime-artifacts');

    expect(task.description, contains('--output-dir "$runtimeArtifactsDir/reviews"'));
    expect(Directory(p.join(runtimeArtifactsDir, 'reviews')).existsSync(), isTrue);
  });

  test('workflow runs get isolated runtime artifact directories', () async {
    final definition = WorkflowDefinition(
      name: 'runtime-artifacts',
      description: 'Runtime artifacts workflow',
      steps: const [
        WorkflowStep(
          id: 'review',
          name: 'Review',
          prompts: ['--output-dir {{workflow.runtime_artifacts_dir}}/reviews'],
        ),
      ],
    );

    final tasks = [
      await h.executeAndCaptureSingleTask(definition: definition, context: WorkflowContext(), runId: 'run-A'),
      await h.executeAndCaptureSingleTask(definition: definition, context: WorkflowContext(), runId: 'run-B'),
    ];

    final runADir = p.join(h.tempDir.path, 'workflows', 'runs', 'run-A', 'runtime-artifacts');
    final runBDir = p.join(h.tempDir.path, 'workflows', 'runs', 'run-B', 'runtime-artifacts');
    expect(tasks.map((task) => task.description), contains(contains('--output-dir $runADir/reviews')));
    expect(tasks.map((task) => task.description), contains(contains('--output-dir $runBDir/reviews')));
    expect(runADir, isNot(runBDir));
    expect(Directory(p.join(runADir, 'reviews')).existsSync(), isTrue);
    expect(Directory(p.join(runBDir, 'reviews')).existsSync(), isTrue);
  });

  test('workflow.runtime_artifacts_dir renders inside foreach child prompts', () async {
    final definition = WorkflowDefinition(
      name: 'runtime-artifacts-foreach',
      description: 'Runtime artifacts workflow',
      steps: const [
        WorkflowStep(
          id: 'review-each',
          name: 'Review Each',
          type: 'foreach',
          mapOver: 'items',
          foreachSteps: ['review-child'],
        ),
        WorkflowStep(
          id: 'review-child',
          name: 'Review Child',
          prompts: ['Review {{map.item}} --output-dir {{workflow.runtime_artifacts_dir}}/reviews'],
        ),
      ],
    );

    final task = await h.executeAndCaptureSingleTask(
      definition: definition,
      context: WorkflowContext(
        data: {
          'items': ['alpha'],
        },
      ),
      runId: 'run-foreach',
    );
    final runtimeArtifactsDir = p.join(h.tempDir.path, 'workflows', 'runs', 'run-foreach', 'runtime-artifacts');

    expect(task.description, contains('Review alpha --output-dir $runtimeArtifactsDir/reviews'));
    expect(Directory(p.join(runtimeArtifactsDir, 'reviews')).existsSync(), isTrue);
  });

  test('workflow run paths reject run ids that escape the run namespace', () {
    expect(
      () => workflowRuntimeArtifactsDir(dataDir: h.tempDir.path, runId: '../outside'),
      throwsA(isA<ArgumentError>().having((error) => error.name, 'name', 'runId')),
    );
  });
}
