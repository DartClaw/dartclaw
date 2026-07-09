import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show MaintenanceMode, WorkflowRuntimeArtifactsRetentionConfig;
import 'package:logging/logging.dart';

import 'workflow_run.dart' show WorkflowRun;
import 'workflow_run_paths.dart';

final _log = Logger('WorkflowRuntimeArtifactsPruner');

/// A single runtime-artifacts retention action (planned or applied).
class RuntimeArtifactsPruneAction {
  /// Run whose `runtime-artifacts/` directory was pruned (or would be).
  final String runId;

  /// Absolute path of the pruned `runtime-artifacts/` directory.
  final String path;

  /// Bytes reclaimed (or that would be reclaimed in dry-run).
  final int reclaimedBytes;

  /// True when the deletion was applied (enforce mode), false when only planned.
  final bool applied;

  const RuntimeArtifactsPruneAction({
    required this.runId,
    required this.path,
    required this.reclaimedBytes,
    required this.applied,
  });
}

/// Summary of a runtime-artifacts retention pass.
class RuntimeArtifactsPruneReport {
  /// Effective mode the pass ran in.
  final MaintenanceMode mode;

  /// Number of runtime-artifacts directories deleted (enforce mode).
  final int prunedRuns;

  /// Total bytes reclaimed (or planned in dry-run/warn mode).
  final int reclaimedBytes;

  /// Non-fatal warnings (e.g. a delete that failed).
  final List<String> warnings;

  /// Per-run actions taken or planned.
  final List<RuntimeArtifactsPruneAction> actions;

  const RuntimeArtifactsPruneReport({
    required this.mode,
    this.prunedRuns = 0,
    this.reclaimedBytes = 0,
    this.warnings = const [],
    this.actions = const [],
  });
}

/// Prunes the `runtime-artifacts/` subtree of completed runs older than the
/// configured cutoff.
///
/// Only the `runtime-artifacts/` directory under each eligible run is removed;
/// `context.json`, the run directory itself, and DB records are left intact so
/// run history stays queryable. Disabled when [config.pruneAfterDays] is 0.
/// In warn mode (or via [modeOverride] = warn) nothing is deleted — the report
/// records what *would* be pruned. Mirrors the session-maintenance pattern.
class WorkflowRuntimeArtifactsPruner {
  final WorkflowRuntimeArtifactsRetentionConfig config;
  final String dataDir;

  const WorkflowRuntimeArtifactsPruner({required this.config, required this.dataDir});

  /// Runs the retention pass over [completedRuns].
  ///
  /// [completedRuns] should already be filtered to terminal runs; non-terminal
  /// or `completedAt`-less runs are ignored defensively. [modeOverride] forces
  /// warn/enforce regardless of [config.mode].
  RuntimeArtifactsPruneReport run(List<WorkflowRun> completedRuns, {MaintenanceMode? modeOverride}) {
    final mode = modeOverride ?? config.mode;
    if (config.pruneAfterDays <= 0) return RuntimeArtifactsPruneReport(mode: mode);

    final isEnforce = mode == MaintenanceMode.enforce;
    final cutoff = DateTime.now().subtract(Duration(days: config.pruneAfterDays));
    final actions = <RuntimeArtifactsPruneAction>[];
    final warnings = <String>[];
    var prunedRuns = 0;
    var reclaimedBytes = 0;

    for (final run in completedRuns) {
      if (!run.status.terminal) continue;
      final completedAt = run.completedAt;
      if (completedAt == null || !completedAt.isBefore(cutoff)) continue;

      final dirPath = workflowRuntimeArtifactsDir(dataDir: dataDir, runId: run.id);
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;

      final size = _dirSize(dir);
      var applied = false;
      if (isEnforce) {
        try {
          dir.deleteSync(recursive: true);
          prunedRuns++;
          reclaimedBytes += size;
          applied = true;
        } catch (e) {
          warnings.add('Failed to prune runtime-artifacts for run ${run.id}: $e');
        }
      } else {
        reclaimedBytes += size;
      }
      actions.add(RuntimeArtifactsPruneAction(runId: run.id, path: dirPath, reclaimedBytes: size, applied: applied));
    }

    return RuntimeArtifactsPruneReport(
      mode: mode,
      prunedRuns: prunedRuns,
      reclaimedBytes: reclaimedBytes,
      warnings: warnings,
      actions: actions,
    );
  }

  int _dirSize(Directory dir) {
    var total = 0;
    try {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) total += entity.statSync().size;
      }
    } catch (e) {
      _log.fine('Failed to compute size for ${dir.path}: $e');
    }
    return total;
  }
}
