import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';

/// Collects runtime health metrics: uptime, worker state, session count, DB size.
class HealthService {
  static const _version = '0.2.0';
  static const _cacheTtl = Duration(seconds: 60);

  final AgentHarness _worker;
  final String _searchDbPath;
  final String _sessionsDir;
  final DateTime _startedAt;

  int _cachedSessionCount = 0;
  int _cachedDbSizeBytes = 0;
  DateTime _cacheExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  HealthService({
    required AgentHarness worker,
    required String searchDbPath,
    required String sessionsDir,
    DateTime? startedAt,
  }) : _worker = worker,
       _searchDbPath = searchDbPath,
       _sessionsDir = sessionsDir,
       _startedAt = startedAt ?? DateTime.now();

  Map<String, dynamic> getStatus() {
    _refreshCacheIfNeeded();

    final status = switch (_worker.state) {
      WorkerState.stopped => 'unhealthy',
      WorkerState.crashed => 'degraded',
      _ => 'healthy',
    };

    return {
      'status': status,
      'uptime_s': DateTime.now().difference(_startedAt).inSeconds,
      'worker_state': _worker.state.name,
      'session_count': _cachedSessionCount,
      'db_size_bytes': _cachedDbSizeBytes,
      'version': _version,
    };
  }

  void _refreshCacheIfNeeded() {
    final now = DateTime.now();
    if (now.isBefore(_cacheExpiry)) return;

    _cachedSessionCount = _countSessions();
    _cachedDbSizeBytes = _dbSize();
    _cacheExpiry = now.add(_cacheTtl);
  }

  int _countSessions() {
    try {
      return Directory(_sessionsDir)
          .listSync()
          .whereType<Directory>()
          .length;
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
}
