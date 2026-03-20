// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;

import '../observability/usage_tracker.dart';
import '../version.dart';

/// Collects runtime health metrics: uptime, worker state, session count, DB size.
class HealthService {
  static const _cacheTtl = Duration(seconds: 60);

  final AgentHarness _worker;
  final String _searchDbPath;
  final String _sessionsDir;
  final String _tasksDir;
  final UsageTracker? _usageTracker;
  final DateTime _startedAt;

  int _cachedSessionCount = 0;
  int _cachedDbSizeBytes = 0;
  int _cachedArtifactDiskBytes = 0;
  DateTime _cacheExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  HealthService({
    required AgentHarness worker,
    required String searchDbPath,
    required String sessionsDir,
    String? tasksDir,
    UsageTracker? usageTracker,
    DateTime? startedAt,
  }) : _worker = worker,
       _searchDbPath = searchDbPath,
       _sessionsDir = sessionsDir,
       _tasksDir = tasksDir ?? p.join(p.dirname(sessionsDir), 'tasks'),
       _usageTracker = usageTracker,
       _startedAt = startedAt ?? DateTime.now();

  Future<Map<String, dynamic>> getStatus() async {
    _refreshCacheIfNeeded();

    final status = switch (_worker.state) {
      WorkerState.stopped => 'unhealthy',
      WorkerState.crashed => 'degraded',
      _ => 'healthy',
    };

    final result = <String, dynamic>{
      'status': status,
      'uptime_s': DateTime.now().difference(_startedAt).inSeconds,
      'worker_state': _worker.state.name,
      'session_count': _cachedSessionCount,
      'db_size_bytes': _cachedDbSizeBytes,
      'artifact_disk_bytes': _cachedArtifactDiskBytes,
      'version': dartclawVersion,
    };

    final tracker = _usageTracker;
    if (tracker != null) {
      try {
        final daily = await tracker.dailySummary();
        if (daily != null) result['daily_usage'] = daily;
      } catch (_) {
        // Omit daily_usage if unavailable
      }
    }

    return result;
  }

  void _refreshCacheIfNeeded() {
    final now = DateTime.now();
    if (now.isBefore(_cacheExpiry)) return;

    _cachedSessionCount = _countSessions();
    _cachedDbSizeBytes = _dbSize();
    _cachedArtifactDiskBytes = _artifactDiskBytes();
    _cacheExpiry = now.add(_cacheTtl);
  }

  int _countSessions() {
    try {
      return Directory(_sessionsDir).listSync().whereType<Directory>().length;
    } catch (_) {
      return 0;
    }
  }

  int _dbSize() {
    try {
      return File(_searchDbPath).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  int _artifactDiskBytes() {
    try {
      final tasksDir = Directory(_tasksDir);
      if (!tasksDir.existsSync()) return 0;

      var total = 0;
      for (final entity in tasksDir.listSync(followLinks: false)) {
        if (entity is! Directory) continue;

        final artifactsDir = Directory(p.join(entity.path, 'artifacts'));
        if (!artifactsDir.existsSync()) continue;

        for (final artifactEntity in artifactsDir.listSync(recursive: true, followLinks: false)) {
          if (artifactEntity is File) {
            total += artifactEntity.statSync().size;
          }
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}
