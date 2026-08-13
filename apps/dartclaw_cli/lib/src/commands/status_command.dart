import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart' show IndexHealthStore;

import 'config_loader.dart';

typedef StatusWriteLine = void Function(String line);

/// Shows DartClaw status: data directory info, session count, worker path.
class StatusCommand extends Command<void> {
  final DartclawConfig? _config;
  final StatusWriteLine _writeLine;

  StatusCommand({DartclawConfig? config, StatusWriteLine? writeLine})
    : _config = config,
      _writeLine = writeLine ?? stdout.writeln;

  @override
  String get name => 'status';

  @override
  String get description => 'Show DartClaw status';

  @override
  Future<void> run() async {
    final config = _config ?? loadCliConfig(configPath: globalResults?['config'] as String?);

    for (final w in config.warnings) {
      _writeLine('WARNING: $w');
    }

    final dataDir = config.server.dataDir;

    if (!Directory(dataDir).existsSync()) {
      _writeLine('No data directory found at $dataDir');
      return;
    }

    final sessions = SessionService(baseDir: config.sessionsDir);
    final sessionList = await sessions.listSessions();

    _writeLine('DartClaw Status');
    _writeLine('  Data dir:  $dataDir');
    _writeLine('  Sessions:  ${sessionList.length}');
    _writeLine('  Harness:   not running (executable: ${config.server.claudeExecutable})');
    await _writeMemoryStatus(config);
  }

  Future<void> _writeMemoryStatus(DartclawConfig config) async {
    MemoryCorpusStatusSnapshot? status;
    try {
      status = MemoryCorpusService.readPersistedStatus(workspaceDir: config.workspaceDir);
    } on Object {
      _writeLine('  Memory:    unknown (persisted evidence could not be read)');
      _writeLine('  Index:     unknown');
      return;
    }
    if (status == null) {
      _writeLine('  Memory:    unknown (no persisted collection status)');
      _writeLine('  Index:     unknown');
      return;
    }
    _writeLine(
      '  Memory:    revision ${status.collectionRevision}; curated=${_count(status.curatedEntryCount)}, '
      'topics=${_count(status.topicCount)}, archive=${_count(status.archiveEntryCount)}, '
      'observations=${_count(status.observationEntryCount)}, learnings=${_count(status.learningEntryCount)}',
    );
    final usage = status.observationUsageBytes;
    final warning = usage == null
        ? 'unknown'
        : usage >= MemoryResourceLimits.observationUsageWarningBytes
        ? 'active'
        : 'none';
    _writeLine('  Observation usage: ${usage == null ? 'unknown' : '$usage bytes (exact)'}; warning=$warning');
    _writeLine(
      '  Observation range: ${status.observationOldest?.toIso8601String() ?? 'unknown'} to '
      '${status.observationNewest?.toIso8601String() ?? 'unknown'}',
    );
    _writeLine(
      '  Migration: ${status.migrationState}; snapshot=${_safe(status.migrationSnapshotPath ?? 'not applicable')}',
    );
    if (status.migrationAction != null) _writeLine('  Migration action: ${_safe(status.migrationAction!)}');
    _writeLine('  Opaque legacy: ${status.opaqueLegacyLocators.length}; ${_locators(status.opaqueLegacyLocators)}');
    try {
      final health = await IndexHealthStore(
        workspaceDir: config.workspaceDir,
      ).read(canonicalRevision: status.collectionRevision, canonicalFingerprint: status.collectionFingerprint);
      _writeLine(
        '  Index:     ${health.state.name}; canonical=${health.canonicalRevision}; '
        'indexed=${health.indexRevision?.toString() ?? 'unknown'}',
      );
      if (health.state.name != 'healthy') {
        if (health.failureStage != null) _writeLine('  Index failure stage: ${_safe(health.failureStage!)}');
        if (health.reason != null) _writeLine('  Index reason: ${_safe(health.reason!)}');
        _writeLine('  Index action: stop DartClaw, then run dartclaw rebuild-index');
      }
    } on Object {
      _writeLine('  Index:     unknown');
      _writeLine('  Index action: stop DartClaw, then run dartclaw rebuild-index');
    }
  }

  static String _count(int? value) => value?.toString() ?? 'unknown';

  static String _locators(List<String> locators) {
    if (locators.isEmpty) return 'none';
    final shown = locators.take(10).map(_safe).join(', ');
    return locators.length <= 10 ? shown : '$shown, … ${locators.length - 10} more';
  }

  static String _safe(String value) {
    final safe = value.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');
    return safe.length <= 500 ? safe : '${safe.substring(0, 497)}...';
  }
}
