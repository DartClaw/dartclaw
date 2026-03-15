// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/maintenance/session_maintenance_service.dart';

import 'config_loader.dart';

typedef CleanupWriteLine = void Function(String line);
typedef CleanupExitFn = void Function(int code);

/// Runs the session maintenance pipeline: prune, cap, retention, disk budget.
class CleanupCommand extends Command<void> {
  final DartclawConfig? _config;
  final CleanupWriteLine _writeLine;
  final CleanupExitFn _exitFn;

  CleanupCommand({DartclawConfig? config, CleanupWriteLine? writeLine, CleanupExitFn? exitFn})
    : _config = config,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('dry-run', negatable: false, help: 'Preview changes without applying');
    argParser.addFlag('enforce', negatable: false, help: 'Apply changes regardless of config mode');
  }

  @override
  String get name => 'cleanup';

  @override
  String get description => 'Run session maintenance (prune, cap, retention, disk budget)';

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
    final hasConfiguredChannels = config.channelConfig.channelConfigs.values.any((c) => c['enabled'] == true);
    final activeChannelKeys = <String>{};
    if (hasConfiguredChannels) {
      final channelSessions = await sessions.listSessions(type: SessionType.channel);
      for (final s in channelSessions) {
        if (s.channelKey != null) activeChannelKeys.add(s.channelKey!);
      }
    }

    // Derive active job IDs from config
    final activeJobIds = config.schedulingJobs.map((j) => j['name'] as String?).whereType<String>().toSet();

    // Determine mode override
    MaintenanceMode? modeOverride;
    if (dryRun) {
      modeOverride = MaintenanceMode.warn;
    } else if (enforce) {
      modeOverride = MaintenanceMode.enforce;
    }

    final maintenance = SessionMaintenanceService(
      sessions: sessions,
      config: config.sessionMaintenanceConfig,
      activeChannelKeys: activeChannelKeys,
      activeJobIds: activeJobIds,
      sessionsDir: config.sessionsDir,
    );

    final report = await maintenance.run(modeOverride: modeOverride);
    _printReport(report, modeOverride: modeOverride);

    _exitFn(report.warnings.isNotEmpty ? 1 : 0);
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
