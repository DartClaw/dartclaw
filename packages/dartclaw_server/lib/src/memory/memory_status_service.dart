import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../scheduling/cron_parser.dart';
import '../scheduling/schedule_service.dart';

final _log = Logger('MemoryStatusService');

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

  MemoryStatusService({
    required this.workspaceDir,
    required this.config,
    required this.kvService,
    this.searchIndexCounter,
    this.scheduleService,
  });

  /// Returns the complete memory status response.
  Future<Map<String, dynamic>> getStatus() async {
    final memoryMd = _getMemoryMdStatus();
    final archiveMd = _getArchiveStatus();
    final errorsMd = _getSelfImprovementStatus(p.join(workspaceDir, 'errors.md'), cap: 50);
    final learningsMd = _getSelfImprovementStatus(p.join(workspaceDir, 'learnings.md'), cap: 50);
    final search = _getSearchStatus();
    final pruner = await _getPrunerStatus();
    final dailyLogs = _getDailyLogsStatus();

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
    final filePath = p.join(workspaceDir, 'MEMORY.md');
    final file = File(filePath);
    if (!file.existsSync()) {
      return {
        'sizeBytes': 0,
        'entryCount': 0,
        'oldestEntry': null,
        'newestEntry': null,
        'budgetBytes': config.memory.maxBytes,
        'categories': <Map<String, dynamic>>[],
      };
    }

    try {
      final content = file.readAsStringSync();
      final sizeBytes = file.lengthSync();
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
        'sizeBytes': sizeBytes,
        'entryCount': entries.length,
        'oldestEntry': oldest?.toIso8601String(),
        'newestEntry': newest?.toIso8601String(),
        'budgetBytes': config.memory.maxBytes,
        'categories': categories,
        'undatedCount': undatedCount,
      };
    } catch (e) {
      _log.warning('Failed to read MEMORY.md: $e');
      return {
        'sizeBytes': 0,
        'entryCount': 0,
        'oldestEntry': null,
        'newestEntry': null,
        'budgetBytes': config.memory.maxBytes,
        'categories': <Map<String, dynamic>>[],
      };
    }
  }

  Map<String, dynamic> _getArchiveStatus() {
    final filePath = p.join(workspaceDir, 'MEMORY.archive.md');
    final file = File(filePath);
    if (!file.existsSync()) {
      return {'sizeBytes': 0, 'entryCount': 0};
    }

    try {
      final content = file.readAsStringSync();
      final sizeBytes = file.lengthSync();
      final entries = parseMemoryEntries(content);
      return {'sizeBytes': sizeBytes, 'entryCount': entries.length};
    } catch (e) {
      _log.warning('Failed to read MEMORY.archive.md: $e');
      return {'sizeBytes': 0, 'entryCount': 0};
    }
  }

  Map<String, dynamic> _getSelfImprovementStatus(String filePath, {required int cap}) {
    final file = File(filePath);
    if (!file.existsSync()) {
      return {'entryCount': 0, 'cap': cap, 'sizeBytes': 0};
    }

    try {
      final content = file.readAsStringSync();
      final sizeBytes = file.lengthSync();
      // Count entries: lines starting with "## [" (errors.md/learnings.md use this format)
      final entryCount = content.split('\n').where((l) => l.startsWith('## [')).length;
      return {'entryCount': entryCount, 'cap': cap, 'sizeBytes': sizeBytes};
    } catch (e) {
      _log.warning('Failed to read $filePath: $e');
      return {'entryCount': 0, 'cap': cap, 'sizeBytes': 0};
    }
  }

  Map<String, dynamic> _getSearchStatus() {
    try {
      final indexEntries = _countSearchEntries('memory');
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
    } catch (_) {
      return 0;
    }
  }

  int _getSearchDbSize() {
    try {
      return File(config.searchDbPath).lengthSync();
    } catch (_) {
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
      } catch (_) {
        // Invalid cron expression
      }
    }

    // Count undated entries from MEMORY.md status (already computed above,
    // but we keep this self-contained to avoid parameter threading)
    int? undatedCount;
    try {
      final memFile = File(p.join(workspaceDir, 'MEMORY.md'));
      if (memFile.existsSync()) {
        final entries = parseMemoryEntries(memFile.readAsStringSync());
        undatedCount = entries.where((e) => e.timestamp == null).length;
      }
    } catch (_) {}

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
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _getDailyLogsStatus() {
    final logDir = Directory(p.join(workspaceDir, 'memory'));
    if (!logDir.existsSync()) {
      return {'fileCount': 0, 'totalSizeBytes': 0, 'recent': <Map<String, dynamic>>[]};
    }

    try {
      final datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}\.md$');
      final logFiles =
          logDir.listSync().whereType<File>().where((f) => datePattern.hasMatch(p.basename(f.path))).toList()
            ..sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));

      var totalSizeBytes = 0;
      final recent = <Map<String, dynamic>>[];

      for (var i = 0; i < logFiles.length; i++) {
        final file = logFiles[i];
        final sizeBytes = file.lengthSync();
        totalSizeBytes += sizeBytes;

        // Include last 7 in recent list
        if (i < 7) {
          final name = p.basenameWithoutExtension(file.path);
          final content = file.readAsStringSync();
          final entries = content.split('\n').where((l) => l.startsWith('- [')).length;
          recent.add({'date': name, 'entries': entries, 'sizeBytes': sizeBytes});
        }
      }

      return {'fileCount': logFiles.length, 'totalSizeBytes': totalSizeBytes, 'recent': recent};
    } catch (e) {
      _log.warning('Failed to enumerate daily logs: $e');
      return {'fileCount': 0, 'totalSizeBytes': 0, 'recent': <Map<String, dynamic>>[]};
    }
  }

  static List<dynamic>? _parseJsonArray(String raw) {
    try {
      final parsed = jsonDecode(raw);
      if (parsed is List) return parsed;
      return null;
    } catch (_) {
      return null;
    }
  }
}
