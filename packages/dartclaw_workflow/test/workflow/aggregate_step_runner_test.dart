@Tags(['component'])
library;

import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskType;

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show OutputConfig, OutputFormat, WorkflowContext, WorkflowDefinition, WorkflowRun, WorkflowStep;
import 'package:dartclaw_workflow/src/workflow/aggregate_step_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String runtimeArtifactsDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('aggregate_step_runner_test_');
    runtimeArtifactsDir = p.join(tempDir.path, 'workflows', 'runs', 'run-1', 'runtime-artifacts');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  File writeReport(String name, String contents) {
    final file = File(p.join(tempDir.path, name));
    file.writeAsStringSync(contents);
    return file;
  }

  test('sums review counts and writes a merged report with source headers', () async {
    final planReport = writeReport('plan-review.md', '# Plan\n\nA');
    final architectureReport = writeReport('architecture-review.md', '# Architecture\n\nB');
    final definition = _definition(
      sources: [
        _reviewSourceStep(
          id: 'plan-review',
          reportKey: 'plan-review.review_findings',
          reportPreset: 'review_report_path',
        ),
        _reviewSourceStep(
          id: 'architecture-review',
          reportKey: 'architecture-review.review_findings',
          reportPreset: 'review_report_path',
        ),
      ],
    );
    final aggregate = definition.steps.last;
    final context = WorkflowContext(
      data: {
        'plan-review.findings_count': 3,
        'plan-review.gating_findings_count': 1,
        'architecture-review.findings_count': 2,
        'architecture-review.gating_findings_count': 1,
        'plan-review.review_findings': planReport.path,
        'architecture-review.review_findings': architectureReport.path,
      },
      systemVariables: {'workflow.runtime_artifacts_dir': runtimeArtifactsDir},
    );

    final outcome = await executeAggregateStep(
      run: _run(definition),
      definition: definition,
      step: aggregate,
      context: context,
      dataDir: tempDir.path,
    );

    final mergedPath = outcome.outputs['review_findings'] as String;
    expect(outcome.success, isTrue);
    expect(outcome.outputs['findings_count'], 5);
    expect(outcome.outputs['gating_findings_count'], 2);
    expect(outcome.outputs['review-aggregate.status'], 'success');
    expect(outcome.outputs['review-aggregate.tokenCount'], 0);
    expect(mergedPath, p.join(runtimeArtifactsDir, 'reviews', 'aggregated-review-aggregate.md'));
    expect(File(mergedPath).readAsStringSync(), contains('# plan-review\n\n# Plan\n\nA'));
    expect(File(mergedPath).readAsStringSync(), contains('# architecture-review\n\n# Architecture\n\nB'));
  });

  test('treats missing counts as zero and emits placeholders for missing reports', () async {
    final planReport = writeReport('plan-review.md', 'Plan report');
    final definition = _definition(
      sources: [
        _reviewSourceStep(
          id: 'plan-review',
          reportKey: 'plan-review.review_findings',
          reportPreset: 'review_report_path',
        ),
        _reviewSourceStep(id: 'skipped-review', reportKey: 'skipped_findings', reportPreset: 'review_report_path'),
        _reviewSourceStep(id: 'bad-count-review', reportKey: 'bad_count_findings', reportPreset: 'review_report_path'),
      ],
      aggregateReviews: const ['plan-review', 'skipped-review', 'bad-count-review'],
    );
    final context = WorkflowContext(
      data: {
        'plan-review.findings_count': 3,
        'plan-review.gating_findings_count': 1,
        'bad-count-review.findings_count': 'not an integer',
        'bad-count-review.gating_findings_count': 2.5,
        'plan-review.review_findings': planReport.path,
      },
      systemVariables: {'workflow.runtime_artifacts_dir': runtimeArtifactsDir},
    );

    final outcome = await executeAggregateStep(
      run: _run(definition),
      definition: definition,
      step: definition.steps.last,
      context: context,
      dataDir: tempDir.path,
    );

    final merged = File(outcome.outputs['review_findings'] as String).readAsStringSync();
    expect(outcome.outputs['findings_count'], 3);
    expect(outcome.outputs['gating_findings_count'], 1);
    expect(merged, contains('# skipped-review\n\n_no report produced by skipped-review_'));
    expect(merged, contains('# bad-count-review\n\n_no report produced by bad-count-review_'));
  });

  test('ignores nested context maps that happen to carry a colliding count key', () async {
    final planReport = writeReport('plan-review.md', 'Plan report');
    final definition = _definition(
      sources: [
        _reviewSourceStep(
          id: 'plan-review',
          reportKey: 'plan-review.review_findings',
          reportPreset: 'review_report_path',
        ),
      ],
      aggregateReviews: const ['plan-review'],
    );
    final context = WorkflowContext(
      data: {
        // Direct count keys for plan-review are absent; the report path is present
        // (partial-output source). An unrelated context value happens to carry a
        // nested map with the same count key names — the spec requires a direct
        // lookup so this must NOT contribute to the sum.
        'unrelated-step.output': {'plan-review.findings_count': 7, 'plan-review.gating_findings_count': 4},
        'plan-review.review_findings': planReport.path,
      },
      systemVariables: {'workflow.runtime_artifacts_dir': runtimeArtifactsDir},
    );

    final outcome = await executeAggregateStep(
      run: _run(definition),
      definition: definition,
      step: definition.steps.last,
      context: context,
      dataDir: tempDir.path,
    );

    expect(outcome.outputs['findings_count'], 0);
    expect(outcome.outputs['gating_findings_count'], 0);
  });

  test('resolves workspace-relative report paths against the active workspace root', () async {
    final workspace = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    final report = File(p.join(workspace.path, 'reports', 'architecture-review.md'));
    report.parent.createSync(recursive: true);
    report.writeAsStringSync('Workspace-relative architecture report');
    final definition = _definition(
      sources: [
        _reviewSourceStep(
          id: 'architecture-review',
          reportKey: 'architecture-review.review_findings',
          reportPreset: 'review_report_path',
        ),
      ],
      aggregateReviews: const ['architecture-review'],
    );
    final context = WorkflowContext(
      data: {
        'architecture-review.findings_count': 1,
        'architecture-review.gating_findings_count': 1,
        'architecture-review.review_findings': p.join('reports', 'architecture-review.md'),
      },
      systemVariables: {'workflow.runtime_artifacts_dir': runtimeArtifactsDir},
    );

    final outcome = await executeAggregateStep(
      run: _run(definition),
      definition: definition,
      step: definition.steps.last,
      context: context,
      dataDir: tempDir.path,
      activeWorkspaceRoot: workspace.path,
    );

    final merged = File(outcome.outputs['review_findings'] as String).readAsStringSync();
    expect(merged, contains('# architecture-review\n\nWorkspace-relative architecture report'));
  });

  test('re-execution overwrites the deterministic merged report path', () async {
    final report = writeReport('plan-review.md', 'First');
    final definition = _definition(
      sources: [
        _reviewSourceStep(
          id: 'plan-review',
          reportKey: 'plan-review.review_findings',
          reportPreset: 'review_report_path',
        ),
      ],
      aggregateReviews: const ['plan-review'],
    );
    final context = WorkflowContext(
      data: {
        'plan-review.findings_count': 1,
        'plan-review.gating_findings_count': 1,
        'plan-review.review_findings': report.path,
      },
      systemVariables: {'workflow.runtime_artifacts_dir': runtimeArtifactsDir},
    );

    final first = await executeAggregateStep(
      run: _run(definition),
      definition: definition,
      step: definition.steps.last,
      context: context,
      dataDir: tempDir.path,
    );
    report.writeAsStringSync('Second');
    final second = await executeAggregateStep(
      run: _run(definition),
      definition: definition,
      step: definition.steps.last,
      context: context,
      dataDir: tempDir.path,
    );

    expect(second.outputs['review_findings'], first.outputs['review_findings']);
    expect(File(second.outputs['review_findings'] as String).readAsStringSync(), contains('Second'));
    expect(File(second.outputs['review_findings'] as String).readAsStringSync(), isNot(contains('First')));
  });
}

WorkflowDefinition _definition({
  required List<WorkflowStep> sources,
  List<String> aggregateReviews = const ['plan-review', 'architecture-review'],
}) => WorkflowDefinition(
  name: 'aggregate-workflow',
  description: 'Workflow with aggregate review step',
  steps: [
    ...sources,
    WorkflowStep(
      id: 'review-aggregate',
      name: 'Review Aggregate',
      type: WorkflowTaskType.aggregateReviews,
      aggregateReviews: aggregateReviews,
      outputs: const {
        'review_findings': OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
        'findings_count': OutputConfig(format: OutputFormat.json, schema: 'findings_count'),
        'gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count'),
      },
    ),
  ],
);

WorkflowStep _reviewSourceStep({required String id, required String reportKey, required String reportPreset}) =>
    WorkflowStep(
      id: id,
      name: id,
      prompts: const ['p'],
      outputs: {
        reportKey: OutputConfig(format: OutputFormat.path, schema: reportPreset),
        '$id.findings_count': const OutputConfig(format: OutputFormat.json, schema: 'findings_count'),
        '$id.gating_findings_count': const OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count'),
      },
    );

WorkflowRun _run(WorkflowDefinition definition) {
  final now = DateTime(2026);
  return WorkflowRun(
    id: 'run-1',
    definitionName: definition.name,
    startedAt: now,
    updatedAt: now,
    definitionJson: definition.toJson(),
  );
}
