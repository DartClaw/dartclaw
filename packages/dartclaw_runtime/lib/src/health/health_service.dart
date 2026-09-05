import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart' show PubSubHealthReporter;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../observability/usage_tracker.dart';
import '../version.dart';

/// The one projection of [WorkerState] onto a health string, for the health
/// endpoint and the web status page alike.
///
/// Every value is named: a wildcard arm would report a future state as healthy
/// with nothing to notice it, and this projection is what an operator's probe
/// reads. A new [WorkerState] must fail to compile here until it is classified.
String healthStatusForWorkerState(WorkerState? state) => switch (state) {
  WorkerState.stopped => 'unhealthy',
  WorkerState.crashed || null => 'degraded',
  WorkerState.idle || WorkerState.busy => 'healthy',
};

const _badgeVariants = {'healthy': 'success', 'degraded': 'warning', 'unhealthy': 'error'};

/// The badge variant every surface renders a [healthStatusForWorkerState] word
/// as. A word outside that vocabulary takes the error variant, since a status
/// no consumer here produced is not evidence of health.
String healthStatusBadgeVariant(String status) => _badgeVariants[status] ?? 'error';

/// Collects runtime health metrics: uptime, worker state, session count, DB size.
class HealthService {
  static final _log = Logger('HealthService');
  static const _cacheTtl = Duration(seconds: 60);

  final AgentHarness _worker;
  final String _searchDbPath;
  final String _sessionsDir;
  final String _tasksDir;
  final UsageTracker? _usageTracker;
  PubSubHealthReporter? _pubsubReporter;
  final DateTime _startedAt;

  int _cachedSessionCount = 0;
  int _cachedDbSizeBytes = 0;
  int _cachedArtifactDiskBytes = 0;
  DateTime _cacheExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  new({
    required AgentHarness worker,
    required String searchDbPath,
    required String sessionsDir,
    String? tasksDir,
    UsageTracker? usageTracker,
    PubSubHealthReporter? pubsubReporter,
    DateTime? startedAt,
  }) : _worker = worker,
       _searchDbPath = searchDbPath,
       _sessionsDir = sessionsDir,
       _tasksDir = tasksDir ?? p.join(p.dirname(sessionsDir), 'tasks'),
       _usageTracker = usageTracker,
       _pubsubReporter = pubsubReporter,
       _startedAt = startedAt ?? DateTime.now();

  /// Sets the Pub/Sub health reporter (late injection for wiring order).
  set pubsubReporter(PubSubHealthReporter? reporter) => _pubsubReporter = reporter;

  /// Returns the current Pub/Sub health status, or null if not configured.
  Map<String, dynamic>? get pubsubHealth => _pubsubReporter?.status;

  Future<Map<String, dynamic>> getStatus() async {
    _refreshCacheIfNeeded();

    final status = healthStatusForWorkerState(_worker.state);

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
      } catch (e) {
        _log.fine('Daily usage summary unavailable: $e');
      }
    }

    final pubsubReporter = _pubsubReporter;
    if (pubsubReporter != null) {
      result['pubsub'] = pubsubReporter.status;
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
    } catch (e) {
      _log.fine('Failed to count sessions: $e');
      return 0;
    }
  }

  int _dbSize() {
    try {
      return File(_searchDbPath).lengthSync();
    } catch (e) {
      _log.fine('Failed to get db size: $e');
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
    } catch (e) {
      _log.fine('Failed to compute artifact disk bytes: $e');
      return 0;
    }
  }
}
