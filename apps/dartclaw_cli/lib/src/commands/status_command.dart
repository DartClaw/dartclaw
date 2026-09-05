import 'dart:async';
import 'dart:io';

import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show WriteLine, dartclawVersion, formatUptime;

import 'cli_global_options.dart';
import 'connected_command_support.dart';
import 'config_loader.dart';

/// Reports server health and persisted local session, memory and index evidence.
class StatusCommand extends ConnectedCommand {
  new({super.config, super.apiClient, super.writeLine, super.exitFn, super.stderrLine});

  WriteLine get _writeLine => writeLine;

  @override
  String get name => 'status';

  @override
  String get description => 'Show DartClaw status';

  @override
  Future<void> run() async {
    final config = injectedConfig ?? loadCliConfig(configPath: globalResults?['config'] as String?);

    for (final w in config.warnings) {
      _writeLine('WARNING: $w');
    }

    final apiClient =
        injectedApiClient ??
        apiClientFromConfig(
          config: config,
          serverOverride: serverOverride(globalResults),
          tokenOverride: globalOptionString(globalResults, 'token'),
        );
    _writeLine('DartClaw Status');
    final origin = apiClient.baseUri.origin;
    try {
      final health = await readServerHealth(apiClient);
      final uptime = health['uptime_s'] as int;
      final version = health['version'];
      final workerState = health['worker_state'];
      if (workerState is! String) {
        throw DartclawApiException('Invalid health response from /health.', code: 'INVALID_RESPONSE');
      }
      final mismatch = version == dartclawVersion ? '' : '; CLI is v$dartclawVersion';
      _writeLine('  Server:    running at $origin (v$version, up ${formatUptime(uptime)}$mismatch)');
      _writeLine('  Harness:   $workerState');
    } on DartclawApiException catch (error) {
      _writeLine(
        error.statusCode == null && error.code == 'CONNECTION_REFUSED'
            ? '  Server:    not running at $origin'
            : '  Server:    unreachable at $origin: ${error.message}',
      );
    } on TimeoutException {
      _writeLine('  Server:    unreachable at $origin: health request timed out');
    } on HttpException catch (error) {
      _writeLine('  Server:    unreachable at $origin: ${error.message}');
    } on FormatException catch (error) {
      _writeLine('  Server:    unreachable at $origin: ${error.message}');
    }

    final dataDir = config.server.dataDir;

    if (!Directory(dataDir).existsSync()) {
      _writeLine('No data directory found at $dataDir');
      return;
    }

    final sessions = SessionService(baseDir: config.sessionsDir);
    final sessionList = await sessions.listSessions();

    _writeLine('  Data dir:  $dataDir');
    _writeLine('  Sessions:  ${sessionList.length}');
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
      final health = await IndexHealthStore(workspaceDir: config.workspaceDir)
          .read(canonicalRevision: status.collectionRevision, canonicalFingerprint: status.collectionFingerprint);
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
