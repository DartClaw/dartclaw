import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart'
    show SessionMaintenanceService, MaintenanceReport, MaintenanceAction;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteWorkflowRunRepository, TaskDbFactory, openTaskDb;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show RuntimeArtifactsPruneReport, WorkflowRun, WorkflowRuntimeArtifactsPruner;

import 'config_loader.dart';

typedef CleanupWriteLine = void Function(String line);
typedef CleanupExitFn = void Function(int code);

/// Runs the session maintenance pipeline: prune, cap, retention, disk budget.
class CleanupCommand extends Command<void> {
  final DartclawConfig? _config;
  final CleanupWriteLine _writeLine;
  final CleanupExitFn _exitFn;
  final TaskDbFactory _taskDbFactory;

  CleanupCommand({
    DartclawConfig? config,
    CleanupWriteLine? writeLine,
    CleanupExitFn? exitFn,
    TaskDbFactory? taskDbFactory,
  }) : _config = config,
       _writeLine = writeLine ?? stdout.writeln,
       _exitFn = exitFn ?? exit,
       _taskDbFactory = taskDbFactory ?? openTaskDb {
    argParser.addFlag('dry-run', negatable: false, help: 'Preview changes without applying');
    argParser.addFlag('enforce', negatable: false, help: 'Apply changes regardless of config mode');
  }

  @override
  String get name => 'cleanup';

  @override
  String get description => 'Run maintenance (session prune/cap/retention/disk budget, workflow artifact retention)';

  @override
  Future<void> run() async {
    final dryRun = argResults!['dry-run'] as bool;
    final enforce = argResults!['enforce'] as bool;

    if (dryRun && enforce) {
      throw UsageException('Cannot use --dry-run and --enforce together', usage);
    }

    final config = _config ?? loadCliConfig(configPath: globalResults?['config'] as String?);

    for (final w in config.warnings) {
      _writeLine('WARNING: $w');
    }

    final sessions = SessionService(baseDir: config.sessionsDir);

    // Derive protected channel keys from config
    final hasConfiguredChannels = config.channels.channelConfigs.values.any((c) => c['enabled'] == true);
    final activeChannelKeys = <String>{};
    if (hasConfiguredChannels) {
      final channelSessions = await sessions.listSessions(type: SessionType.channel);
      for (final s in channelSessions) {
        if (s.channelKey != null) activeChannelKeys.add(s.channelKey!);
      }
    }

    // Derive active job IDs from config
    final activeJobIds = config.scheduling.jobs.map((j) => j['name'] as String?).whereType<String>().toSet();

    // Determine mode override
    MaintenanceMode? modeOverride;
    if (dryRun) {
      modeOverride = MaintenanceMode.warn;
    } else if (enforce) {
      modeOverride = MaintenanceMode.enforce;
    }

    final maintenance = SessionMaintenanceService(
      sessions: sessions,
      config: config.sessions.maintenanceConfig,
      activeChannelKeys: activeChannelKeys,
      activeJobIds: activeJobIds,
      sessionsDir: config.sessionsDir,
    );

    final report = await maintenance.run(modeOverride: modeOverride);
    _printReport(report, modeOverride: modeOverride);

    final retentionWarnings = await _runWorkflowArtifactRetention(config, modeOverride: modeOverride);

    _exitFn(report.warnings.isNotEmpty || retentionWarnings ? 1 : 0);
  }

  /// Prunes runtime-artifacts of old completed runs when retention is enabled.
  ///
  /// Returns true when the pass surfaced warnings (drives the exit code). Opens
  /// the tasks DB only when retention is enabled, so a fresh data dir with no
  /// runs stays a no-op.
  Future<bool> _runWorkflowArtifactRetention(DartclawConfig config, {MaintenanceMode? modeOverride}) async {
    final retention = config.workflow.runtimeArtifactsRetention;
    if (retention.pruneAfterDays <= 0) return false;
    if (!File(config.tasksDbPath).existsSync()) return false;

    final db = _taskDbFactory(config.tasksDbPath);
    RuntimeArtifactsPruneReport report;
    try {
      // Schema init runs in the repository constructor, so a corrupt or
      // write-locked tasks.db can throw there too — keep it inside the catch so
      // any DB failure degrades to a skip warning rather than crashing cleanup.
      final List<WorkflowRun> completedRuns;
      try {
        final repository = SqliteWorkflowRunRepository(db);
        completedRuns = (await repository.list()).where((run) => run.status.terminal).toList();
      } catch (e) {
        _writeLine('WARNING: workflow artifact retention skipped (database read failed): $e');
        return true;
      }
      final pruner = WorkflowRuntimeArtifactsPruner(config: retention, dataDir: config.server.dataDir);
      report = pruner.run(completedRuns, modeOverride: modeOverride);
    } finally {
      // Best-effort close: a close error must not mask the original outcome.
      try {
        db.close();
      } catch (_) {}
    }

    _printRetentionReport(report, modeOverride: modeOverride);
    return report.warnings.isNotEmpty;
  }

  void _printReport(MaintenanceReport report, {MaintenanceMode? modeOverride}) {
    final modeSource = modeOverride != null
        ? '${report.mode.toYaml()} (--${modeOverride == MaintenanceMode.warn ? 'dry-run' : 'enforce'} override)'
        : '${report.mode.toYaml()} (config)';

    _writeLine('Session Maintenance Report');
    _writeLine('──────────────────────────');
    _writeLine('Mode:             $modeSource');
    _writeLine('Sessions:         ${report.totalSessions} total');
    _writeLine('Disk usage:       ${_formatBytes(report.totalDiskBytes)}');
    _writeLine('');

    if (report.actions.isEmpty) {
      _writeLine('No actions needed.');
    } else {
      _writeLine('Actions:');

      final archived = report.actions.where((a) => a.actionType == 'archive').toList();
      if (archived.isNotEmpty) {
        final reasons = _groupByReason(archived);
        _writeLine('  Archived:       ${archived.length} session${archived.length == 1 ? '' : 's'} ($reasons)');
      }

      final deleted = report.actions.where((a) => a.actionType == 'delete').toList();
      if (deleted.isNotEmpty) {
        final reasons = _groupByReason(deleted);
        _writeLine('  Deleted:        ${deleted.length} session${deleted.length == 1 ? '' : 's'} ($reasons)');
      }

      if (report.diskReclaimedBytes > 0) {
        _writeLine('  Disk reclaimed: ${_formatBytes(report.diskReclaimedBytes)}');
      }
    }

    if (report.warnings.isNotEmpty) {
      _writeLine('');
      _writeLine('Warnings:');
      for (final w in report.warnings) {
        _writeLine('  - $w');
      }
    }
  }

  void _printRetentionReport(RuntimeArtifactsPruneReport report, {MaintenanceMode? modeOverride}) {
    final modeSource = modeOverride != null
        ? '${report.mode.toYaml()} (--${modeOverride == MaintenanceMode.warn ? 'dry-run' : 'enforce'} override)'
        : '${report.mode.toYaml()} (config)';
    final isEnforce = report.mode == MaintenanceMode.enforce;
    final verb = isEnforce ? 'Pruned' : 'Would prune';
    // In enforce mode a failed delete is still recorded as an action (applied:
    // false) and surfaces under Warnings — report only the deletions that
    // actually applied so the count never overstates what was removed.
    final reported = isEnforce ? report.actions.where((a) => a.applied).toList() : report.actions;
    final reclaimed = isEnforce ? reported.fold<int>(0, (sum, a) => sum + a.reclaimedBytes) : report.reclaimedBytes;

    _writeLine('');
    _writeLine('Workflow Runtime-Artifacts Retention');
    _writeLine('────────────────────────────────────');
    _writeLine('Mode:             $modeSource');

    if (reported.isEmpty) {
      _writeLine('No runtime-artifacts to prune.');
    } else {
      _writeLine('$verb:           ${reported.length} run${reported.length == 1 ? '' : 's'}');
      _writeLine('Disk reclaimed:   ${_formatBytes(reclaimed)}');
      for (final action in reported) {
        _writeLine('  - ${action.runId} (${_formatBytes(action.reclaimedBytes)})');
      }
    }

    if (report.warnings.isNotEmpty) {
      _writeLine('');
      _writeLine('Warnings:');
      for (final w in report.warnings) {
        _writeLine('  - $w');
      }
    }
  }

  String _groupByReason(List<MaintenanceAction> actions) {
    final counts = <String, int>{};
    for (final a in actions) {
      counts[a.reason] = (counts[a.reason] ?? 0) + 1;
    }
    return counts.entries.map((e) => '${e.key}: ${e.value}').join(', ');
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
