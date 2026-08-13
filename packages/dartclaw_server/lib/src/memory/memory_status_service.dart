import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart' show IndexHealthEvidence, IndexHealthState;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../scheduling/cron_parser.dart';
import '../scheduling/schedule_service.dart';
import '../behavior/behavior_file_service.dart';
import 'memory_curation_service.dart';
import 'workspace_file_reader.dart';

final _log = Logger('MemoryStatusService');
final _dailyLogHeader = RegExp(r'^## (?:[01]\d|2[0-3]):[0-5]\d — ');

/// Callback to count search index entries by role.
///
/// Avoids direct `sqlite3` dependency in `dartclaw_server/lib/`.
/// The caller provides a function that queries `SELECT COUNT(*) FROM
/// memory_chunks WHERE role = ?`.
typedef SearchIndexCounter = int Function(String role);

/// Reads current persisted search-index health evidence.
typedef IndexHealthReader = Future<IndexHealthEvidence> Function();

/// Reads one coherent canonical-corpus status snapshot.
typedef MemoryCorpusStatusReader = Future<MemoryCorpusStatusSnapshot> Function();

/// Produces the exact bounded memory block used by a fresh primary turn.
typedef PromptMemoryStatusReader = Future<MemoryPromptProjection> Function();

/// Reads the persisted explicit-curation lifecycle.
typedef MemoryCurationStatusReader = Future<MemoryCurationRecord?> Function();

/// Returns an exact native wiki source count, or null when coverage is incomplete.
typedef WikiSourceCounter = Future<int?> Function();

/// Gathers memory system metrics for the Memory Dashboard API.
///
/// Reads from existing files, services, and config — no new storage.
/// All file reads are fresh (no caching) since memory files change infrequently.
class MemoryStatusService {
  final String workspaceDir;
  final DartclawConfig config;
  final KvService kvService;
  final SearchIndexCounter? searchIndexCounter;
  final IndexHealthReader? indexHealthReader;
  final MemoryCorpusStatusReader? corpusStatusReader;
  final PromptMemoryStatusReader? promptMemoryStatusReader;
  final MemoryCurationStatusReader? curationStatusReader;
  final WikiSourceCounter? wikiSourceCounter;
  final ScheduleService? scheduleService;
  final WorkspaceFileReader _workspaceFiles;

  MemoryStatusService({
    required this.workspaceDir,
    required this.config,
    required this.kvService,
    this.searchIndexCounter,
    this.indexHealthReader,
    this.corpusStatusReader,
    this.promptMemoryStatusReader,
    this.curationStatusReader,
    this.wikiSourceCounter,
    this.scheduleService,
  }) : _workspaceFiles = WorkspaceFileReader(workspaceDir);

  /// Returns the complete memory status response.
  Future<Map<String, dynamic>> getStatus() async {
    final memoryMd = _getMemoryMdStatus();
    final archiveMd = _getArchiveStatus();
    final errorsMd = _getSelfImprovementStatus('errors.md', entryPrefix: '## [', cap: 50);
    final learningsMd = _getSelfImprovementStatus('learnings.md', entryPrefix: '- [', cap: 50);
    final search = await _getSearchStatus();
    final pruner = await _getPrunerStatus(memoryMd);
    final dailyLogs = await _getDailyLogsStatus();
    final collection = await _getCollectionStatus();
    final promptIndex = await _getPromptIndexStatus();
    final index = await _getIndexStatus(search);
    final curation = await _getCurationStatus();

    return {
      'collection': collection,
      'promptIndex': promptIndex,
      'observations': _observationProjection(dailyLogs, collection),
      'index': index,
      'curation': ?curation,
      'memoryMd': memoryMd,
      'archiveMd': archiveMd,
      'errorsMd': errorsMd,
      'learningsMd': learningsMd,
      'search': search,
      'pruner': pruner,
      'dailyLogs': dailyLogs,
      'config': {'memoryMaxBytes': config.memory.maxBytes},
    };
  }

  Future<Map<String, dynamic>> _getCollectionStatus() async {
    try {
      final snapshot = await corpusStatusReader?.call();
      if (snapshot == null) {
        return {
          'state': 'unknown',
          'revision': null,
          'curatedEntryCount': null,
          'topicCount': null,
          'archiveEntryCount': null,
          'learningEntryCount': null,
          'opaqueLegacyCount': null,
          'migration': const {'state': 'unknown'},
          'reason': 'Canonical collection evidence is unavailable.',
          'action': 'Restart DartClaw and inspect memory preflight output.',
        };
      }
      return {
        'state': 'available',
        'revision': snapshot.collectionRevision,
        'curatedEntryCount': snapshot.curatedEntryCount,
        'topicCount': snapshot.topicCount,
        'archiveEntryCount': snapshot.archiveEntryCount,
        'learningEntryCount': snapshot.learningEntryCount,
        'opaqueLegacyCount': snapshot.opaqueLegacyLocators.length,
        'opaqueLegacyLocators': snapshot.opaqueLegacyLocators,
        'migration': {
          'state': snapshot.migrationState,
          'snapshotPath': snapshot.migrationSnapshotPath,
          'action': snapshot.migrationAction,
        },
      };
    } on Object catch (error) {
      _log.warning('Failed to read canonical collection status: $error');
      return {
        'state': 'unknown',
        'revision': null,
        'curatedEntryCount': null,
        'topicCount': null,
        'archiveEntryCount': null,
        'learningEntryCount': null,
        'opaqueLegacyCount': null,
        'migration': const {'state': 'unknown'},
        'reason': _boundedStatusReason(error),
        'action': 'Restart DartClaw and inspect memory preflight output.',
      };
    }
  }

  Future<Map<String, dynamic>> _getPromptIndexStatus() async {
    try {
      final projection = await promptMemoryStatusReader?.call();
      if (projection == null) {
        return {
          'usedBytes': null,
          'budgetBytes': config.memory.maxBytes,
          'usedLines': null,
          'lineBudget': 150,
          'omittedEntries': null,
          'truncated': null,
          'reason': 'Fresh prompt-index evidence is unavailable.',
        };
      }
      return {
        'usedBytes': projection.usedBytes,
        'budgetBytes': projection.budgetBytes,
        'usedLines': projection.usedLines,
        'lineBudget': projection.lineBudget,
        'omittedEntries': projection.omittedEntries,
        'truncated': projection.truncated,
        'reason': projection.degradedReason,
      };
    } on Object catch (error) {
      return {
        'usedBytes': null,
        'budgetBytes': config.memory.maxBytes,
        'usedLines': null,
        'lineBudget': 150,
        'omittedEntries': null,
        'truncated': null,
        'reason': _boundedStatusReason(error),
      };
    }
  }

  Map<String, dynamic> _observationProjection(Map<String, dynamic> dailyLogs, Map<String, dynamic> collection) {
    final coverage = dailyLogs['coverage'] as String?;
    final unavailable = dailyLogs['failure'] != null && dailyLogs['fileCount'] == 0;
    final lowerBound = unavailable ? null : dailyLogs['totalSizeBytes'] as int?;
    final exact = coverage == 'exact';
    final kind = unavailable
        ? 'unknown'
        : switch (coverage) {
            'exact' => 'exact',
            'lowerBound' => 'lowerBound',
            _ => 'unknown',
          };
    final warning = lowerBound != null && lowerBound >= MemoryResourceLimits.observationUsageWarningBytes
        ? 'active'
        : exact
        ? 'none'
        : 'unknown';
    return {
      'entryCount': collection['state'] == 'available' ? dailyLogs['entryCount'] : null,
      'usageBytes': lowerBound,
      'usageKind': kind,
      'scannedFiles': dailyLogs['fileCount'],
      'omittedFiles': dailyLogs['omittedFiles'],
      'failedFiles': dailyLogs['failedFiles'],
      'oldestRecorded': dailyLogs['oldestRecorded'],
      'newestRecorded': dailyLogs['newestRecorded'],
      'warningAtBytes': MemoryResourceLimits.observationUsageWarningBytes,
      'warning': warning,
      if (dailyLogs['failure'] != null) 'reason': dailyLogs['failure'],
    };
  }

  Future<Map<String, dynamic>> _getIndexStatus(Map<String, dynamic> search) async {
    int? wikiSourceCount;
    try {
      wikiSourceCount = await wikiSourceCounter?.call();
    } on Object catch (error) {
      _log.fine('Wiki source count failed: $error');
    }
    final live = search['indexEntries'] as int?;
    final archived = search['indexArchived'] as int?;
    final current = search['health'] == IndexHealthState.healthy.name;
    return {
      'state': search['health'],
      'canonicalRevision': search['canonicalRevision'],
      'indexedRevision': search['indexRevision'],
      'derivedChunkCount': !current || live == null || archived == null ? null : live + archived,
      'wikiSourceCount': wikiSourceCount,
      'lastReconciliationAt': search['lastValidatedAt'],
      'failureStage': search['failureStage'],
      'reason': search['reason'],
      'action': search['action'],
    };
  }

  Future<Map<String, dynamic>?> _getCurationStatus() async {
    try {
      final reader = curationStatusReader;
      final record = reader == null ? await readMemoryCurationRecord(kvService) : await reader();
      if (record == null) return null;
      return {
        'state': record.state.name,
        'runId': record.runId,
        'startedAt': record.startedAt.toUtc().toIso8601String(),
        if (record.completedAt != null) 'completedAt': record.completedAt!.toUtc().toIso8601String(),
        if (record.lastSuccessAt != null) 'lastSuccessAt': record.lastSuccessAt!.toUtc().toIso8601String(),
        if (record.snapshotRevision != null) 'snapshotRevision': record.snapshotRevision,
        if (record.currentRevision != null) 'currentRevision': record.currentRevision,
        if (record.committedRevision != null) 'committedRevision': record.committedRevision,
        'changedIds': record.changedIds,
        'noOpIds': record.noOpIds,
        'operationReasons': record.operationReasons,
        if (record.failureReason != null) 'failureReason': record.failureReason,
        if (record.indeterminateCommit) 'indeterminateCommit': true,
        'action': switch (record.state) {
          MemoryCurationState.running => 'Wait for the current curation run to finish.',
          MemoryCurationState.succeeded => null,
          MemoryCurationState.conflicted => 'Run memory curation again against the current collection revision.',
          MemoryCurationState.failed when record.indeterminateCommit =>
            'Inspect the current revision, restart DartClaw to settle evidence, then rerun explicitly.',
          MemoryCurationState.failed => 'Review the failure reason, then run memory curation again.',
        },
      };
    } on Object catch (error) {
      return {
        'state': 'unknown',
        'reason': _boundedStatusReason(error),
        'action': 'Preserve the curation record and restart DartClaw before running curation again.',
      };
    }
  }

  static String _boundedStatusReason(Object error) {
    final value = '$error'.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return value.length <= 500 ? value : '${value.substring(0, 497)}...';
  }

  Map<String, dynamic> _getMemoryMdStatus() {
    try {
      final snapshot = _workspaceFiles.read('MEMORY.md', role: MemoryRole.indexDocument);
      if (snapshot == null) return _emptyMemoryMdStatus();
      final content = snapshot.content;
      final entries = parseMemoryEntries(content);

      // Category breakdown
      final categoryMap = <String, int>{};
      for (final entry in entries) {
        categoryMap[entry.category] = (categoryMap[entry.category] ?? 0) + 1;
      }
      final categories = categoryMap.entries.map((e) => {'name': e.key, 'count': e.value}).toList();

      // Oldest/newest timestamps (ignoring undated entries)
      DateTime? oldest;
      DateTime? newest;
      var undatedCount = 0;
      for (final entry in entries) {
        if (entry.timestamp == null) {
          undatedCount++;
          continue;
        }
        if (oldest == null || entry.timestamp!.isBefore(oldest)) {
          oldest = entry.timestamp;
        }
        if (newest == null || entry.timestamp!.isAfter(newest)) {
          newest = entry.timestamp;
        }
      }

      return {
        'sizeBytes': snapshot.sizeBytes,
        'entryCount': entries.length,
        'oldestEntry': oldest?.toIso8601String(),
        'newestEntry': newest?.toIso8601String(),
        'budgetBytes': config.memory.maxBytes,
        'categories': categories,
        'undatedCount': undatedCount,
        'coverage': 'exact',
      };
    } catch (e) {
      _log.warning('Failed to read MEMORY.md: $e');
      return {
        ..._emptyMemoryMdStatus(),
        if (e is MemoryResourceLimitException) 'sizeBytes': e.observedBytes,
        'coverage': 'lowerBound',
        'failure': '$e',
      };
    }
  }

  Map<String, dynamic> _emptyMemoryMdStatus() => {
    'sizeBytes': 0,
    'entryCount': 0,
    'oldestEntry': null,
    'newestEntry': null,
    'budgetBytes': config.memory.maxBytes,
    'categories': <Map<String, dynamic>>[],
    'coverage': 'exact',
  };

  Map<String, dynamic> _getArchiveStatus() {
    try {
      final snapshot = _workspaceFiles.read('MEMORY.archive.md', role: MemoryRole.archive);
      if (snapshot == null) return {'sizeBytes': 0, 'entryCount': 0, 'coverage': 'exact'};
      final content = snapshot.content;
      final entries = parseMemoryEntries(content);
      return {'sizeBytes': snapshot.sizeBytes, 'entryCount': entries.length, 'coverage': 'exact'};
    } catch (e) {
      _log.warning('Failed to read MEMORY.archive.md: $e');
      return {
        'sizeBytes': e is MemoryResourceLimitException ? e.observedBytes : 0,
        'entryCount': 0,
        'coverage': 'lowerBound',
        'failure': '$e',
      };
    }
  }

  Map<String, dynamic> _getSelfImprovementStatus(String name, {required String entryPrefix, required int cap}) {
    try {
      final role = name == 'learnings.md' ? MemoryRole.learning : null;
      final snapshot = _workspaceFiles.read(name, role: role);
      if (snapshot == null) return {'entryCount': 0, 'cap': cap, 'sizeBytes': 0, 'coverage': 'exact'};
      final content = snapshot.content;
      final entryCount = content.split('\n').where((line) => line.startsWith(entryPrefix)).length;
      return {'entryCount': entryCount, 'cap': cap, 'sizeBytes': snapshot.sizeBytes, 'coverage': 'exact'};
    } catch (e) {
      _log.warning('Failed to read $name: $e');
      return {
        'entryCount': 0,
        'cap': cap,
        'sizeBytes': e is MemoryResourceLimitException ? e.observedBytes : 0,
        'coverage': 'lowerBound',
        'failure': '$e',
      };
    }
  }

  Future<Map<String, dynamic>> _getSearchStatus() async {
    IndexHealthEvidence? evidence;
    Object? evidenceFailure;
    try {
      evidence = await indexHealthReader?.call();
    } on Object catch (error) {
      evidenceFailure = error;
    }
    final state = evidence?.state ?? IndexHealthState.unknown;
    final counts = ['topic', 'observation', 'learning'].map(_countSearchEntries).toList(growable: false);
    final indexEntries = counts.any((count) => count == null)
        ? null
        : counts.whereType<int>().fold<int>(0, (sum, count) => sum + count);
    final indexArchived = _countSearchEntries('archive');
    final dbSizeBytes = _getSearchDbSize();

    return {
      'backend': config.search.backend,
      'depth': config.search.defaultDepth,
      'health': state.name,
      'canonicalRevision': evidence?.canonicalRevision,
      'canonicalFingerprint': evidence?.canonicalFingerprint,
      'indexRevision': evidence?.indexRevision,
      'indexFingerprint': evidence?.indexFingerprint,
      'lastValidatedAt': evidence?.validatedAt?.toIso8601String(),
      'failureStage': evidence?.failureStage ?? (evidenceFailure == null ? null : 'evidence'),
      'reason': evidence == null
          ? (evidenceFailure == null ? 'Index health evidence is unavailable.' : '$evidenceFailure')
          : evidence.reason,
      'action': evidence == null ? 'Stop DartClaw, then run dartclaw rebuild-index.' : evidence.action,
      'indexEntries': indexEntries,
      'indexArchived': indexArchived,
      'dbSizeBytes': dbSizeBytes,
      'qmdConfig': config.search.backend == 'qmd'
          ? {'host': config.search.qmdHost, 'port': config.search.qmdPort}
          : null,
    };
  }

  int? _countSearchEntries(String role) {
    final counter = searchIndexCounter;
    if (counter == null) return null;
    try {
      return counter(role);
    } catch (e) {
      _log.fine('Search index count failed: $e');
      return null;
    }
  }

  int? _getSearchDbSize() {
    try {
      final file = File(config.searchDbPath);
      if (!file.existsSync()) return null;
      return file.lengthSync();
    } catch (e) {
      _log.fine('Failed to get search db size: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>> _getPrunerStatus(Map<String, dynamic> memoryMd) async {
    final enabled = config.memory.pruningEnabled;
    final schedule = config.memory.pruningSchedule;

    // Read prune history from KV
    List<dynamic> history = [];
    String? lastRunTimestamp;
    try {
      final raw = await kvService.get('prune_history');
      if (raw != null) {
        final parsed = _parseJsonArray(raw);
        if (parsed != null) {
          history = parsed;
          if (history.isNotEmpty) {
            lastRunTimestamp = (history.last as Map<String, dynamic>)['timestamp'] as String?;
          }
        }
      }
    } catch (e) {
      _log.warning('Failed to read prune history: $e');
    }

    // Derive status
    final status = _derivePrunerStatus(
      pruningEnabled: enabled,
      lastRunTimestamp: lastRunTimestamp,
      pruningSchedule: schedule,
    );

    // Calculate next run
    String? nextRun;
    if (enabled) {
      try {
        final cron = CronExpression.parse(schedule);
        nextRun = cron.nextFrom(DateTime.now()).toIso8601String();
      } catch (e) {
        _log.fine('Invalid cron expression "$schedule": $e');
      }
    }

    return {
      'enabled': enabled,
      'schedule': schedule,
      'archiveAfterDays': config.memory.archiveAfterDays,
      'lastRun': lastRunTimestamp,
      'nextRun': nextRun,
      'status': status,
      'undatedCount': memoryMd['undatedCount'] as int? ?? 0,
      'history': history,
    };
  }

  String _derivePrunerStatus({
    required bool pruningEnabled,
    required String? lastRunTimestamp,
    required String pruningSchedule,
  }) {
    if (!pruningEnabled) return 'disabled';
    if (scheduleService?.isJobPaused('memory-pruner') ?? false) return 'paused';

    if (lastRunTimestamp != null) {
      final lastRun = DateTime.tryParse(lastRunTimestamp);
      if (lastRun != null) {
        final intervalEstimate = _estimateCronInterval(pruningSchedule);
        if (intervalEstimate != null) {
          final overdueCutoff = lastRun.add(intervalEstimate * 2);
          if (DateTime.now().isAfter(overdueCutoff)) return 'overdue';
        }
      }
    }

    return 'active';
  }

  /// Estimates the interval of a cron expression by computing the gap between
  /// two consecutive fires.
  Duration? _estimateCronInterval(String schedule) {
    try {
      final cron = CronExpression.parse(schedule);
      final now = DateTime.now();
      final first = cron.nextFrom(now);
      final second = cron.nextFrom(first);
      return second.difference(first);
    } catch (e) {
      _log.fine('Failed to estimate cron interval: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>> _getDailyLogsStatus() async {
    try {
      final datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}\.md$');
      var fileCount = 0;
      var totalEntries = 0;
      var totalSizeBytes = 0;
      var omittedFiles = 0;
      var failedFiles = 0;
      final omittedLocators = <String>[];
      final failedLocators = <String>[];
      var bodyBytes = 0;
      DateTime? oldestRecorded;
      DateTime? newestRecorded;
      final files = <WorkspaceFileEntry>[];

      final scan = await _workspaceFiles.readDirectoryBounded(
        'memory',
        limit: MemoryResourceLimits.recursiveFiles,
        include: datePattern.hasMatch,
      );
      files.addAll(scan.entries);
      omittedFiles = scan.omittedCount;
      if (scan.firstOmitted != null) omittedLocators.add('memory/${scan.firstOmitted}');
      if (!scan.complete) omittedLocators.add('memory');
      fileCount = files.length;
      totalSizeBytes = files.fold(0, (total, file) => total + file.sizeBytes);

      final recent = <Map<String, dynamic>>[];
      final recentNames = files.reversed.take(7).map((file) => file.name).toSet();
      for (var index = 0; index < files.length; index++) {
        final file = files[index];
        var entryCount = 0;
        try {
          final remainingBytes = MemoryResourceLimits.recursiveBodyBytes - bodyBytes;
          if (file.sizeBytes > remainingBytes) {
            omittedFiles += files.length - index;
            omittedLocators.addAll(files.skip(index).map((item) => 'memory/${item.name}'));
            break;
          }
          bodyBytes += file.sizeBytes;
          final facts = await _readDailyLogFacts(file.name, maxBytes: remainingBytes);
          entryCount = facts.entryCount;
          if (facts.oldest case final oldest?) {
            if (oldestRecorded == null || oldest.isBefore(oldestRecorded)) oldestRecorded = oldest;
          }
          if (facts.newest case final newest?) {
            if (newestRecorded == null || newest.isAfter(newestRecorded)) newestRecorded = newest;
          }
        } catch (e) {
          failedFiles++;
          failedLocators.add('memory/${file.name}');
          _log.fine('Failed to read daily log ${file.name}: $e');
        }
        totalEntries += entryCount;
        if (recentNames.contains(file.name)) {
          recent.add({
            'date': p.basenameWithoutExtension(file.name),
            'entries': entryCount,
            'sizeBytes': file.sizeBytes,
          });
        }
      }
      recent.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
      return {
        'fileCount': fileCount,
        'entryCount': totalEntries,
        'totalSizeBytes': totalSizeBytes,
        'coverage': scan.complete && omittedFiles == 0 && failedFiles == 0 ? 'exact' : 'lowerBound',
        'omittedFiles': omittedFiles,
        'failedFiles': failedFiles,
        'omittedLocators': omittedLocators,
        'failedLocators': failedLocators,
        'usageWarning': totalSizeBytes >= MemoryResourceLimits.observationUsageWarningBytes,
        'oldestRecorded': oldestRecorded?.toIso8601String(),
        'newestRecorded': newestRecorded?.toIso8601String(),
        'recent': recent,
      };
    } catch (e) {
      _log.warning('Failed to enumerate daily logs: $e');
      return {
        'fileCount': 0,
        'entryCount': null,
        'totalSizeBytes': 0,
        'coverage': 'lowerBound',
        'omittedFiles': 0,
        'failedFiles': 1,
        'omittedLocators': const <String>[],
        'failedLocators': const ['memory'],
        'usageWarning': false,
        'oldestRecorded': null,
        'newestRecorded': null,
        'recent': <Map<String, dynamic>>[],
        'failure': _boundedStatusReason(e),
      };
    }
  }

  Future<({int entryCount, DateTime? oldest, DateTime? newest})> _readDailyLogFacts(
    String name, {
    required int maxBytes,
  }) async {
    final content = await _workspaceFiles
        .streamDirectoryFileBytes('memory', name, maxBytes: maxBytes)
        .transform(utf8.decoder)
        .join();
    if (content.startsWith('# DartClaw Canonical Memory')) {
      final document = const MemoryMarkdownCodec().parse(content);
      if (document is! MemoryObservationDocument) throw const FormatException('Expected observation document');
      final observations = document.observations;
      return (
        entryCount: observations.length,
        oldest: observations.isEmpty ? null : observations.first.recorded,
        newest: observations.isEmpty ? null : observations.last.recorded,
      );
    }
    final count = const LineSplitter().convert(content).where(_dailyLogHeader.hasMatch).length;
    final date = DateTime.tryParse('${p.basenameWithoutExtension(name)}T00:00:00Z');
    return (entryCount: count, oldest: date, newest: date);
  }

  static List<dynamic>? _parseJsonArray(String raw) {
    try {
      final parsed = jsonDecode(raw);
      if (parsed is List) return parsed;
      return null;
    } catch (e) {
      _log.fine('Failed to parse prune history JSON: $e');
      return null;
    }
  }
}
