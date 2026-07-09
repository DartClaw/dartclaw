import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart'
    show MaintenanceMode, WorkflowRunStatus, WorkflowRuntimeArtifactsRetentionConfig;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRun, WorkflowRuntimeArtifactsPruner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String dataDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_rt_artifacts_pruner_');
    dataDir = tempDir.path;
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  WorkflowRun completedRun(
    String id, {
    required DateTime completedAt,
    WorkflowRunStatus status = WorkflowRunStatus.completed,
  }) {
    return WorkflowRun(
      id: id,
      definitionName: 'spec-and-implement',
      status: status,
      startedAt: completedAt.subtract(const Duration(hours: 1)),
      updatedAt: completedAt,
      completedAt: completedAt,
    );
  }

  /// Populates `<dataDir>/workflows/runs/<id>/runtime-artifacts/` (and a sibling
  /// `context.json`) and returns the runtime-artifacts dir.
  Directory seedRun(String id) {
    final runDir = Directory(p.join(dataDir, 'workflows', 'runs', id))..createSync(recursive: true);
    File(p.join(runDir.path, 'context.json')).writeAsStringSync('{}');
    final artifactsDir = Directory(p.join(runDir.path, 'runtime-artifacts', 'reviews'))..createSync(recursive: true);
    File(p.join(artifactsDir.path, 'report.md')).writeAsStringSync('# review\n');
    return Directory(p.join(runDir.path, 'runtime-artifacts'));
  }

  test('enforce mode prunes an old completed run and keeps context.json', () {
    final artifacts = seedRun('run-old');
    final run = completedRun('run-old', completedAt: DateTime.now().subtract(const Duration(days: 10)));
    final pruner = WorkflowRuntimeArtifactsPruner(
      config: const WorkflowRuntimeArtifactsRetentionConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 7),
      dataDir: dataDir,
    );

    final report = pruner.run([run]);

    expect(artifacts.existsSync(), isFalse);
    expect(File(p.join(dataDir, 'workflows', 'runs', 'run-old', 'context.json')).existsSync(), isTrue);
    expect(report.prunedRuns, 1);
    expect(report.actions.single.runId, 'run-old');
    expect(report.actions.single.applied, isTrue);
    expect(report.reclaimedBytes, greaterThan(0));
  });

  test('a completed run newer than the cutoff is left intact', () {
    final artifacts = seedRun('run-fresh');
    final run = completedRun('run-fresh', completedAt: DateTime.now().subtract(const Duration(days: 2)));
    final pruner = WorkflowRuntimeArtifactsPruner(
      config: const WorkflowRuntimeArtifactsRetentionConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 7),
      dataDir: dataDir,
    );

    final report = pruner.run([run]);

    expect(artifacts.existsSync(), isTrue);
    expect(report.prunedRuns, 0);
    expect(report.actions, isEmpty);
  });

  test('disabled retention (pruneAfterDays 0) deletes nothing', () {
    final artifacts = seedRun('run-old');
    final run = completedRun('run-old', completedAt: DateTime.now().subtract(const Duration(days: 10)));
    final pruner = WorkflowRuntimeArtifactsPruner(
      config: const WorkflowRuntimeArtifactsRetentionConfig(mode: MaintenanceMode.enforce),
      dataDir: dataDir,
    );

    final report = pruner.run([run]);

    expect(artifacts.existsSync(), isTrue);
    expect(report.prunedRuns, 0);
    expect(report.actions, isEmpty);
  });

  test('warn mode reports candidates without deleting', () {
    final artifacts = seedRun('run-old');
    final run = completedRun('run-old', completedAt: DateTime.now().subtract(const Duration(days: 10)));
    final pruner = WorkflowRuntimeArtifactsPruner(
      config: const WorkflowRuntimeArtifactsRetentionConfig(mode: MaintenanceMode.warn, pruneAfterDays: 7),
      dataDir: dataDir,
    );

    final report = pruner.run([run]);

    expect(artifacts.existsSync(), isTrue);
    expect(report.prunedRuns, 0);
    expect(report.actions.single.applied, isFalse);
    expect(report.reclaimedBytes, greaterThan(0));
  });

  test('modeOverride forces warn even when config says enforce', () {
    final artifacts = seedRun('run-old');
    final run = completedRun('run-old', completedAt: DateTime.now().subtract(const Duration(days: 10)));
    final pruner = WorkflowRuntimeArtifactsPruner(
      config: const WorkflowRuntimeArtifactsRetentionConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 7),
      dataDir: dataDir,
    );

    final report = pruner.run([run], modeOverride: MaintenanceMode.warn);

    expect(artifacts.existsSync(), isTrue);
    expect(report.mode, MaintenanceMode.warn);
    expect(report.prunedRuns, 0);
  });

  test('non-terminal runs are ignored', () {
    final artifacts = seedRun('run-running');
    final run = WorkflowRun(
      id: 'run-running',
      definitionName: 'spec-and-implement',
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now().subtract(const Duration(days: 10)),
      updatedAt: DateTime.now().subtract(const Duration(days: 10)),
    );
    final pruner = WorkflowRuntimeArtifactsPruner(
      config: const WorkflowRuntimeArtifactsRetentionConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 7),
      dataDir: dataDir,
    );

    final report = pruner.run([run]);

    expect(artifacts.existsSync(), isTrue);
    expect(report.prunedRuns, 0);
  });

  test('failed and cancelled completed runs are eligible', () {
    seedRun('run-failed');
    seedRun('run-cancelled');
    final old = DateTime.now().subtract(const Duration(days: 10));
    final runs = [
      completedRun('run-failed', completedAt: old, status: WorkflowRunStatus.failed),
      completedRun('run-cancelled', completedAt: old, status: WorkflowRunStatus.cancelled),
    ];
    final pruner = WorkflowRuntimeArtifactsPruner(
      config: const WorkflowRuntimeArtifactsRetentionConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 7),
      dataDir: dataDir,
    );

    final report = pruner.run(runs);

    expect(report.prunedRuns, 2);
    expect(Directory(p.join(dataDir, 'workflows', 'runs', 'run-failed', 'runtime-artifacts')).existsSync(), isFalse);
    expect(Directory(p.join(dataDir, 'workflows', 'runs', 'run-cancelled', 'runtime-artifacts')).existsSync(), isFalse);
  });
}
