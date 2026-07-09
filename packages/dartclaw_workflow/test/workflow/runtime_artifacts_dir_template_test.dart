@Tags(['component'])
library;

import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskType;

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowContext, WorkflowDefinition, WorkflowStep, WorkflowTaskConfig;
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

    // The template stays supported for custom workflows: it resolves in place,
    // with no prompt mutation. The step artifacts env rides alongside.
    expect(task.description, contains('--output-dir $runtimeArtifactsDir/reviews'));
    expect(WorkflowTaskConfig.readStepArtifactsEnv(task), {
      stepArtifactsDirEnvVar: p.join(runtimeArtifactsDir, 'steps', 'review'),
    });
    expect(Directory(runtimeArtifactsDir).existsSync(), isTrue);
    expect(Directory(p.join(runtimeArtifactsDir, 'reviews')).existsSync(), isTrue);
  });

  test('step artifacts env renders absolute when data dir is relative', () async {
    final relativeDataDir = '.dartclaw-dev-test-${DateTime.now().microsecondsSinceEpoch}';
    try {
      h.executor = h.makeExecutor(dataDir: relativeDataDir);
      final definition = WorkflowDefinition(
        name: 'runtime-artifacts',
        description: 'Runtime artifacts workflow',
        steps: const [
          WorkflowStep(id: 'review', name: 'Review', prompts: ['--output-dir "\$DARTCLAW_STEP_ARTIFACTS_DIR"']),
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
      expect(task.description, contains('--output-dir "\$DARTCLAW_STEP_ARTIFACTS_DIR"'));
      // The env value is the resolved absolute path, not the relative data dir.
      final envValue = WorkflowTaskConfig.readStepArtifactsEnv(task)![stepArtifactsDirEnvVar];
      expect(envValue, p.join(runtimeArtifactsDir, 'steps', 'review'));
      expect(p.isAbsolute(envValue!), isTrue);
      expect(envValue, isNot(startsWith(relativeDataDir)));
    } finally {
      final dataDir = Directory(relativeDataDir);
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    }
  });

  test('workflow runs get isolated per-run step artifacts dirs on identical prompts', () async {
    final definition = WorkflowDefinition(
      name: 'runtime-artifacts',
      description: 'Runtime artifacts workflow',
      steps: const [
        WorkflowStep(id: 'review', name: 'Review', prompts: ['--output-dir "\$DARTCLAW_STEP_ARTIFACTS_DIR"']),
      ],
    );

    final tasks = [
      await h.executeAndCaptureSingleTask(definition: definition, context: WorkflowContext(), runId: 'run-A'),
      await h.executeAndCaptureSingleTask(definition: definition, context: WorkflowContext(), runId: 'run-B'),
    ];

    final runADir = p.join(h.tempDir.path, 'workflows', 'runs', 'run-A', 'runtime-artifacts');
    final runBDir = p.join(h.tempDir.path, 'workflows', 'runs', 'run-B', 'runtime-artifacts');
    // Descriptions are identical; per-run isolation lives in each task's
    // host-computed env value, not in the prompt text.
    for (final task in tasks) {
      expect(task.description, contains('--output-dir "\$DARTCLAW_STEP_ARTIFACTS_DIR"'));
    }
    final envValues = tasks.map((task) => WorkflowTaskConfig.readStepArtifactsEnv(task)![stepArtifactsDirEnvVar]);
    expect(envValues, containsAll([p.join(runADir, 'steps', 'review'), p.join(runBDir, 'steps', 'review')]));
    expect(runADir, isNot(runBDir));
  });

  test('framed operator data carrying an --output-dir flag is inert — no prompt mutation, host env wins', () async {
    // Regression for the hoist-era failure mode: operator-controlled data in
    // the prompt (auto-framed variables) must never influence the step
    // artifacts env or be rewritten.
    const hostile = '--output-dir /tmp/attacker-controlled';
    final definition = WorkflowDefinition(
      name: 'runtime-artifacts',
      description: 'Runtime artifacts workflow',
      steps: const [
        WorkflowStep(id: 'plan', name: 'Plan', prompts: ['Consider this operator input: $hostile']),
      ],
    );

    final task = await h.executeAndCaptureSingleTask(
      definition: definition,
      context: WorkflowContext(),
      runId: 'run-framed',
    );

    expect(task.description, contains(hostile));
    expect(
      WorkflowTaskConfig.readStepArtifactsEnv(task)![stepArtifactsDirEnvVar],
      p.join(h.tempDir.path, 'workflows', 'runs', 'run-framed', 'runtime-artifacts', 'steps', 'plan'),
    );
  });

  test('step artifacts env is exported for foreach child tasks', () async {
    final definition = WorkflowDefinition(
      name: 'runtime-artifacts-foreach',
      description: 'Runtime artifacts workflow',
      steps: const [
        WorkflowStep(
          id: 'review-each',
          name: 'Review Each',
          taskType: WorkflowTaskType.foreach,
          mapOver: 'items',
          foreachSteps: ['review-child'],
        ),
        WorkflowStep(
          id: 'review-child',
          name: 'Review Child',
          prompts: ['Review {{map.item}} --output-dir "\$DARTCLAW_STEP_ARTIFACTS_DIR"'],
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

    expect(task.description, contains('Review alpha --output-dir "\$DARTCLAW_STEP_ARTIFACTS_DIR"'));
    // Foreach children carry _mapIterationIndex, so each iteration gets its
    // own disjoint step artifacts dir.
    expect(WorkflowTaskConfig.readStepArtifactsEnv(task), {
      stepArtifactsDirEnvVar: p.join(runtimeArtifactsDir, 'steps', 'review-child-0'),
    });
  });

  test('workflow run paths reject run ids that escape the run namespace', () {
    expect(
      () => workflowRuntimeArtifactsDir(dataDir: h.tempDir.path, runId: '../outside'),
      throwsA(isA<ArgumentError>().having((error) => error.name, 'name', 'runId')),
    );
  });
}
