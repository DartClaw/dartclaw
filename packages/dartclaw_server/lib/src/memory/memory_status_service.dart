import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../scheduling/cron_parser.dart';
import '../scheduling/schedule_service.dart';
import 'workspace_file_reader.dart';

final _log = Logger('MemoryStatusService');
final _dailyLogHeader = RegExp(r'^## (?:[01]\d|2[0-3]):[0-5]\d — ');

/// Callback to count search index entries by source.
///
/// Avoids direct `sqlite3` dependency in `dartclaw_server/lib/`.
/// The caller provides a function that queries `SELECT COUNT(*) FROM
/// memory_chunks WHERE source = ?`.
typedef SearchIndexCounter = int Function(String source);

/// Gathers memory system metrics for the Memory Dashboard API.
///
/// Reads from existing files, services, and config — no new storage.
/// All file reads are fresh (no caching) since memory files change infrequently.
class MemoryStatusService {
  final String workspaceDir;
  final DartclawConfig config;
  final KvService kvService;
  final SearchIndexCounter? searchIndexCounter;
  final ScheduleService? scheduleService;
  final WorkspaceFileReader _workspaceFiles;

  MemoryStatusService({
    required this.workspaceDir,
    required this.config,
    required this.kvService,
    this.searchIndexCounter,
    this.scheduleService,
  }) : _workspaceFiles = WorkspaceFileReader(workspaceDir);

  /// Returns the complete memory status response.
  Future<Map<String, dynamic>> getStatus() async {
    final memoryMd = _getMemoryMdStatus();
    final archiveMd = _getArchiveStatus();
    final errorsMd = _getSelfImprovementStatus('errors.md', entryPrefix: '## [', cap: 50);
    final learningsMd = _getSelfImprovementStatus('learnings.md', entryPrefix: '- [', cap: 50);
    final search = _getSearchStatus();
    final pruner = await _getPrunerStatus();
    final dailyLogs = await _getDailyLogsStatus();

    return {
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

  Map<String, dynamic> _getMemoryMdStatus() {
    try {
      final snapshot = _workspaceFiles.read('MEMORY.md');
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
      };
    } catch (e) {
      _log.warning('Failed to read MEMORY.md: $e');
      return _emptyMemoryMdStatus();
    }
  }

  Map<String, dynamic> _emptyMemoryMdStatus() => {
    'sizeBytes': 0,
    'entryCount': 0,
    'oldestEntry': null,
    'newestEntry': null,
    'budgetBytes': config.memory.maxBytes,
    'categories': <Map<String, dynamic>>[],
  };

  Map<String, dynamic> _getArchiveStatus() {
    try {
      final snapshot = _workspaceFiles.read('MEMORY.archive.md');
      if (snapshot == null) return {'sizeBytes': 0, 'entryCount': 0};
      final content = snapshot.content;
      final entries = parseMemoryEntries(content);
      return {'sizeBytes': snapshot.sizeBytes, 'entryCount': entries.length};
    } catch (e) {
      _log.warning('Failed to read MEMORY.archive.md: $e');
      return {'sizeBytes': 0, 'entryCount': 0};
    }
  }

  Map<String, dynamic> _getSelfImprovementStatus(String name, {required String entryPrefix, required int cap}) {
    try {
      final snapshot = _workspaceFiles.read(name);
      if (snapshot == null) return {'entryCount': 0, 'cap': cap, 'sizeBytes': 0};
      final content = snapshot.content;
      final entryCount = content.split('\n').where((line) => line.startsWith(entryPrefix)).length;
      return {'entryCount': entryCount, 'cap': cap, 'sizeBytes': snapshot.sizeBytes};
    } catch (e) {
      _log.warning('Failed to read $name: $e');
      return {'entryCount': 0, 'cap': cap, 'sizeBytes': 0};
    }
  }

  Map<String, dynamic> _getSearchStatus() {
    try {
      final indexEntries = _countSearchEntries('memory_save');
      final indexArchived = _countSearchEntries('archive');
      final dbSizeBytes = _getSearchDbSize();

      return {
        'backend': config.search.backend,
        'depth': config.search.defaultDepth,
        'indexEntries': indexEntries,
        'indexArchived': indexArchived,
        'dbSizeBytes': dbSizeBytes,
        'qmdConfig': config.search.backend == 'qmd'
            ? {'host': config.search.qmdHost, 'port': config.search.qmdPort}
            : null,
      };
    } catch (e) {
      _log.warning('Failed to read search status: $e');
      return {
        'backend': config.search.backend,
        'depth': config.search.defaultDepth,
        'indexEntries': 0,
        'indexArchived': 0,
        'dbSizeBytes': 0,
        'qmdConfig': null,
      };
    }
  }

  int _countSearchEntries(String source) {
    final counter = searchIndexCounter;
    if (counter == null) return 0;
    try {
      return counter(source);
    } catch (e) {
      _log.fine('Search index count failed: $e');
      return 0;
    }
  }

  int _getSearchDbSize() {
    try {
      return File(config.searchDbPath).lengthSync();
    } catch (e) {
      _log.fine('Failed to get search db size: $e');
      return 0;
    }
  }

  Future<Map<String, dynamic>> _getPrunerStatus() async {
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

    // Count undated entries from MEMORY.md status (already computed above,
    // but we keep this self-contained to avoid parameter threading)
    int? undatedCount;
    try {
      final snapshot = _workspaceFiles.read('MEMORY.md');
      if (snapshot != null) {
        final entries = parseMemoryEntries(snapshot.content);
        undatedCount = entries.where((e) => e.timestamp == null).length;
      }
    } catch (e) {
      _log.fine('Failed to count undated MEMORY.md entries: $e');
    }

    return {
      'enabled': enabled,
      'schedule': schedule,
      'archiveAfterDays': config.memory.archiveAfterDays,
      'lastRun': lastRunTimestamp,
      'nextRun': nextRun,
      'status': status,
      'undatedCount': undatedCount ?? 0,
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
      var totalSizeBytes = 0;
      final recentFiles = <WorkspaceFileEntry>[];

      await for (final file in _workspaceFiles.readDirectory('memory', include: datePattern.hasMatch)) {
        fileCount++;
        totalSizeBytes += file.sizeBytes;
        recentFiles.add(file);
        recentFiles.sort((a, b) => b.name.compareTo(a.name));
        if (recentFiles.length > 7) recentFiles.removeLast();
      }

      final recent = <Map<String, dynamic>>[];
      for (final file in recentFiles) {
        var entryCount = 0;
        try {
          entryCount = await _countDailyLogEntries(file.name);
        } catch (e) {
          _log.fine('Failed to read daily log ${file.name}: $e');
        }
        recent.add({'date': p.basenameWithoutExtension(file.name), 'entries': entryCount, 'sizeBytes': file.sizeBytes});
      }
      return {'fileCount': fileCount, 'totalSizeBytes': totalSizeBytes, 'recent': recent};
    } catch (e) {
      _log.warning('Failed to enumerate daily logs: $e');
      return {'fileCount': 0, 'totalSizeBytes': 0, 'recent': <Map<String, dynamic>>[]};
    }
  }

  Future<int> _countDailyLogEntries(String name) async {
    var count = 0;

    final lines = _workspaceFiles
        .streamDirectoryFileBytes('memory', name)
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (_dailyLogHeader.hasMatch(line)) count++;
    }

    return count;
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
