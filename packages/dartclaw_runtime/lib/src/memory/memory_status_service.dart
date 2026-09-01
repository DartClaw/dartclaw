import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../scheduling/cron_parser.dart';
import '../scheduling/schedule_service.dart';
import '../behavior/behavior_file_service.dart';
import 'workspace_file_reader.dart';

final _log = Logger('MemoryStatusService');
final _dailyLogHeader = RegExp(r'^## (?:[01]\d|2[0-3]):[0-5]\d — ');

/// Callback to count search index entries by role.
///
/// Avoids direct `sqlite3` dependency in `dartclaw_runtime/lib/`.
/// The caller provides a function that queries `SELECT COUNT(*) FROM
/// memory_chunks WHERE role = ?`.
typedef SearchIndexCounter = int Function(String role);

/// Reads current persisted search-index health evidence.
typedef IndexHealthReader = Future<IndexHealthEvidence> Function();

/// Reads one coherent canonical-corpus status snapshot.
typedef MemoryCorpusStatusReader = Future<MemoryCorpusStatusSnapshot> Function();

/// Produces the exact bounded memory block used by a fresh primary turn.
typedef PromptMemoryStatusReader = Future<MemoryPromptProjection> Function();

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
  final WikiSourceCounter? wikiSourceCounter;
  final ScheduleService? scheduleService;
  final WorkspaceFileReader _workspaceFiles;

  new({
    required this.workspaceDir,
    required this.config,
    required this.kvService,
    this.searchIndexCounter,
    this.indexHealthReader,
    this.corpusStatusReader,
    this.promptMemoryStatusReader,
    this.wikiSourceCounter,
    this.scheduleService,
  }) : _workspaceFiles = WorkspaceFileReader(workspaceDir);

  /// Returns the complete memory status response.
  Future<Map<String, dynamic>> getStatus() async {
    final memoryMd = _getMemoryMdStatus();
    final archiveMd = _getArchiveStatus();
    final errorsMd = _getSelfImprovementStatus('errors.md', role: MemoryRole.error, entryPrefix: '## [', cap: 50);
    final learningsMd = _getSelfImprovementStatus(
      'learnings.md',
      role: MemoryRole.learning,
      entryPrefix: '- [',
      cap: 50,
    );
    final search = await _getSearchStatus();
    final pruner = await _getPrunerStatus(memoryMd);
    final dailyLogs = await _getDailyLogsStatus();
    final collection = await _getCollectionStatus();
    final promptIndex = await _getPromptIndexStatus();
    final index = await _getIndexStatus(search);

    return {
      'collection': collection,
      'promptIndex': promptIndex,
      'observations': _observationProjection(dailyLogs, collection),
      'index': index,
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
          'errorEntryCount': null,
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
        'errorEntryCount': snapshot.errorEntryCount,
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
        'errorEntryCount': null,
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

  static String _boundedStatusReason(Object error) {
    final value = '$error'.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return value.length <= 500 ? value : '${value.substring(0, 497)}...';
  }

  Map<String, dynamic> _getMemoryMdStatus() {
    try {
      final snapshot = _workspaceFiles.read('MEMORY.md', role: MemoryRole.indexDocument);
      if (snapshot == null) return _emptyMemoryMdStatus();
      final content = snapshot.content;
      if (content.startsWith(canonicalMemoryHeader)) return _canonicalMemoryMdStatus(content, snapshot.sizeBytes);
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

  /// Reads a canonical index document; the legacy line parser matches none of
  /// its records and would report an empty, `exact` status.
  Map<String, dynamic> _canonicalMemoryMdStatus(String content, int sizeBytes) {
    final document = const MemoryMarkdownCodec().parse(content);
    if (document is! MemoryIndexDocument) throw const FormatException('Expected index document');
    final entries = document.entries;
    final categoryMap = <String, int>{};
    for (final entry in entries) {
      categoryMap[entry.topic] = (categoryMap[entry.topic] ?? 0) + 1;
    }
    final updated = entries.map((entry) => entry.updated).toList()..sort();
    return {
      'sizeBytes': sizeBytes,
      'entryCount': entries.length,
      'oldestEntry': updated.isEmpty ? null : updated.first.toIso8601String(),
      'newestEntry': updated.isEmpty ? null : updated.last.toIso8601String(),
      'budgetBytes': config.memory.maxBytes,
      'categories': categoryMap.entries.map((e) => {'name': e.key, 'count': e.value}).toList(),
      'undatedCount': 0,
      'coverage': 'exact',
    };
  }

  int _canonicalRecordCount(String content, MemoryRole role) {
    final document = const MemoryMarkdownCodec().parse(content);
    return switch (document) {
      MemoryErrorDocument() when role == MemoryRole.error => document.entries.length,
      MemoryLearningDocument() when role == MemoryRole.learning => document.entries.length,
      _ => throw FormatException('Expected ${role.wireName} document'),
    };
  }

  int _canonicalArchiveEntryCount(String content) {
    final document = const MemoryMarkdownCodec().parse(content);
    if (document is! MemoryArchiveDocument) throw const FormatException('Expected archive document');
    return document.entries.length;
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
      final entryCount = content.startsWith(canonicalMemoryHeader)
          ? _canonicalArchiveEntryCount(content)
          : parseMemoryEntries(content).length;
      return {'sizeBytes': snapshot.sizeBytes, 'entryCount': entryCount, 'coverage': 'exact'};
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

  /// Counts entries in `errors.md` or `learnings.md`.
  ///
  /// Both are canonical corpus documents on a current workspace, whose records
  /// carry none of the legacy line prefixes; counting prefixes alone reports an
  /// `exact` zero. [entryPrefix] stays for pre-canonical files only.
  Map<String, dynamic> _getSelfImprovementStatus(
    String name, {
    required MemoryRole role,
    required String entryPrefix,
    required int cap,
  }) {
    try {
      final snapshot = _workspaceFiles.read(name, role: role);
      if (snapshot == null) return {'entryCount': 0, 'cap': cap, 'sizeBytes': 0, 'coverage': 'exact'};
      final content = snapshot.content;
      final entryCount = content.startsWith(canonicalMemoryHeader)
          ? _canonicalRecordCount(content, role)
          : content.split('\n').where((line) => line.startsWith(entryPrefix)).length;
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
