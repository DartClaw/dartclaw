import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:path/path.dart' as p;

import '../config/session_maintenance_config.dart';
import '../storage/session_service.dart';

/// A single action taken or planned during maintenance.
class MaintenanceAction {
  final String sessionId;

  /// 'archive' or 'delete'.
  final String actionType;

  /// 'stale', 'count_cap', 'cron_retention', or 'disk_budget'.
  final String reason;

  /// True if the action was applied (enforce mode), false if only planned (warn mode).
  final bool applied;

  const MaintenanceAction({
    required this.sessionId,
    required this.actionType,
    required this.reason,
    required this.applied,
  });
}

/// Summary of a maintenance run.
class MaintenanceReport {
  final MaintenanceMode mode;
  final int sessionsArchived;
  final int sessionsDeleted;
  final int diskReclaimedBytes;
  final int totalSessions;
  final int totalDiskBytes;
  final List<String> warnings;
  final List<MaintenanceAction> actions;

  const MaintenanceReport({
    required this.mode,
    this.sessionsArchived = 0,
    this.sessionsDeleted = 0,
    this.diskReclaimedBytes = 0,
    this.totalSessions = 0,
    this.totalDiskBytes = 0,
    this.warnings = const [],
    this.actions = const [],
  });

  /// Empty report for a given mode.
  MaintenanceReport.empty(this.mode)
    : sessionsArchived = 0,
      sessionsDeleted = 0,
      diskReclaimedBytes = 0,
      totalSessions = 0,
      totalDiskBytes = 0,
      warnings = const [],
      actions = const [];
}

/// Executes the session maintenance pipeline.
///
/// Pipeline order: prune stale -> count cap -> cron retention -> disk budget.
/// Protected sessions (main, active channel, active cron) are never pruned.
class SessionMaintenanceService {
  final SessionService sessions;
  final SessionMaintenanceConfig config;
  final Set<String> activeChannelKeys;
  final Set<String> activeJobIds;
  final String sessionsDir;

  SessionMaintenanceService({
    required this.sessions,
    required this.config,
    required this.activeChannelKeys,
    required this.activeJobIds,
    required this.sessionsDir,
  });

  /// Runs the full maintenance pipeline.
  ///
  /// [modeOverride] allows CLI to force warn/enforce regardless of config.
  Future<MaintenanceReport> run({MaintenanceMode? modeOverride}) async {
    final mode = modeOverride ?? config.mode;
    final isEnforce = mode == MaintenanceMode.enforce;

    var archived = 0;
    var deleted = 0;
    var diskReclaimed = 0;
    final warnings = <String>[];
    final actions = <MaintenanceAction>[];

    // Stage 1: Prune stale sessions
    final pruneResult = await _pruneStale(isEnforce);
    archived += pruneResult.archived;
    warnings.addAll(pruneResult.warnings);
    actions.addAll(pruneResult.actions);

    // Stage 2: Count cap
    final capResult = await _enforceCountCap(isEnforce);
    archived += capResult.archived;
    warnings.addAll(capResult.warnings);
    actions.addAll(capResult.actions);

    // Stage 3: Cron retention
    final cronResult = await _cleanCronSessions(isEnforce);
    deleted += cronResult.deleted;
    warnings.addAll(cronResult.warnings);
    actions.addAll(cronResult.actions);

    // Stage 4: Disk budget
    final diskResult = await _enforceDiskBudget(isEnforce);
    deleted += diskResult.deleted;
    diskReclaimed += diskResult.reclaimedBytes;
    warnings.addAll(diskResult.warnings);
    actions.addAll(diskResult.actions);

    // Final counts
    final allSessions = await sessions.listSessions();
    final totalDisk = _calculateDiskUsage(sessionsDir);

    return MaintenanceReport(
      mode: mode,
      sessionsArchived: archived,
      sessionsDeleted: deleted,
      diskReclaimedBytes: diskReclaimed,
      totalSessions: allSessions.length,
      totalDiskBytes: totalDisk,
      warnings: warnings,
      actions: actions,
    );
  }

  bool _isProtected(Session s) {
    if (s.type == SessionType.main) return true;
    if (s.type == SessionType.channel) {
      return s.channelKey != null && activeChannelKeys.contains(s.channelKey);
    }
    if (s.type == SessionType.cron) {
      if (s.channelKey == null) return false;
      final jobId = _extractJobId(s.channelKey!);
      return jobId != null && activeJobIds.contains(jobId);
    }
    if (s.type == SessionType.task) return true;
    return false;
  }

  String? _extractJobId(String channelKey) {
    try {
      final key = SessionKey.parse(channelKey);
      if (key.scope == 'cron') {
        return Uri.decodeComponent(key.identifiers);
      }
    } catch (_) {}
    return null;
  }

  Future<_StageResult> _pruneStale(bool isEnforce) async {
    if (config.pruneAfterDays == 0) return _StageResult.empty();

    final cutoff = DateTime.now().subtract(Duration(days: config.pruneAfterDays));
    final allSessions = await sessions.listSessions();
    final actions = <MaintenanceAction>[];
    final warnings = <String>[];
    var archived = 0;

    for (final s in allSessions) {
      if (s.type == SessionType.archive) continue;
      if (s.type == SessionType.task) continue;
      if (_isProtected(s)) continue;
      if (s.updatedAt.isAfter(cutoff)) continue;

      var applied = false;
      if (isEnforce) {
        try {
          await sessions.updateSessionType(s.id, SessionType.archive);
          archived++;
          applied = true;
        } catch (e) {
          warnings.add('Failed to archive session ${s.id}: $e');
        }
      }
      actions.add(MaintenanceAction(sessionId: s.id, actionType: 'archive', reason: 'stale', applied: applied));
    }

    return _StageResult(archived: archived, warnings: warnings, actions: actions);
  }

  Future<_StageResult> _enforceCountCap(bool isEnforce) async {
    if (config.maxSessions == 0) return _StageResult.empty();

    final allSessions = await sessions.listSessions();
    final activeSessions = allSessions.where((s) => s.type != SessionType.archive && !_isProtected(s)).toList();

    if (activeSessions.length <= config.maxSessions) return _StageResult.empty();

    // Sort oldest first (updatedAt ascending)
    activeSessions.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));

    final excess = activeSessions.length - config.maxSessions;
    final toArchive = activeSessions.take(excess);
    final actions = <MaintenanceAction>[];
    final warnings = <String>[];
    var archived = 0;

    for (final s in toArchive) {
      var applied = false;
      if (isEnforce) {
        try {
          await sessions.updateSessionType(s.id, SessionType.archive);
          archived++;
          applied = true;
        } catch (e) {
          warnings.add('Failed to archive session ${s.id}: $e');
        }
      }
      actions.add(MaintenanceAction(sessionId: s.id, actionType: 'archive', reason: 'count_cap', applied: applied));
    }

    return _StageResult(archived: archived, warnings: warnings, actions: actions);
  }

  Future<_StageResult> _cleanCronSessions(bool isEnforce) async {
    if (config.cronRetentionHours == 0) return _StageResult.empty();

    final cutoff = DateTime.now().subtract(Duration(hours: config.cronRetentionHours));
    final cronSessions = await sessions.listSessions(type: SessionType.cron);
    final actions = <MaintenanceAction>[];
    final warnings = <String>[];
    var deleted = 0;

    for (final s in cronSessions) {
      if (s.updatedAt.isAfter(cutoff)) continue;

      // Check if orphaned (job no longer configured) or fresh-session job
      final jobId = s.channelKey != null ? _extractJobId(s.channelKey!) : null;
      final isOrphaned = jobId == null || !activeJobIds.contains(jobId);
      if (!isOrphaned) continue;

      var applied = false;
      if (isEnforce) {
        try {
          // Change type to user first to bypass protectedTypes guard
          await sessions.updateSessionType(s.id, SessionType.user);
          await sessions.deleteSession(s.id);
          deleted++;
          applied = true;
        } catch (e) {
          warnings.add('Failed to delete cron session ${s.id}: $e');
        }
      }
      actions.add(MaintenanceAction(sessionId: s.id, actionType: 'delete', reason: 'cron_retention', applied: applied));
    }

    return _StageResult(deleted: deleted, warnings: warnings, actions: actions);
  }

  Future<_DiskResult> _enforceDiskBudget(bool isEnforce) async {
    if (config.maxDiskMb == 0) return _DiskResult.empty();

    final budgetBytes = config.maxDiskMb * 1024 * 1024;
    final threshold = (budgetBytes * 0.8).toInt();
    var currentUsage = _calculateDiskUsage(sessionsDir);

    if (currentUsage <= threshold) return _DiskResult.empty();

    // Get archived sessions sorted oldest first
    final archivedSessions = await sessions.listSessions(type: SessionType.archive);
    archivedSessions.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));

    final actions = <MaintenanceAction>[];
    final warnings = <String>[];
    var deleted = 0;
    var reclaimedBytes = 0;

    for (final s in archivedSessions) {
      if (currentUsage <= threshold) break;

      final sessionDir = Directory(p.join(sessionsDir, s.id));
      final sessionSize = _calculateDiskUsage(sessionDir.path);

      var applied = false;
      if (isEnforce) {
        try {
          await sessions.deleteSession(s.id);
          currentUsage -= sessionSize;
          reclaimedBytes += sessionSize;
          deleted++;
          applied = true;
        } catch (e) {
          warnings.add('Failed to delete archived session ${s.id}: $e');
        }
      } else {
        currentUsage -= sessionSize;
        reclaimedBytes += sessionSize;
      }
      actions.add(MaintenanceAction(sessionId: s.id, actionType: 'delete', reason: 'disk_budget', applied: applied));
    }

    if (currentUsage > threshold) {
      warnings.add('Still over disk budget after deleting all archived sessions');
    }

    return _DiskResult(deleted: deleted, reclaimedBytes: reclaimedBytes, warnings: warnings, actions: actions);
  }

  int _calculateDiskUsage(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return 0;

    var totalBytes = 0;
    try {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          totalBytes += entity.statSync().size;
        }
      }
    } catch (_) {
      // Best effort
    }
    return totalBytes;
  }
}

class _StageResult {
  final int archived;
  final int deleted;
  final List<String> warnings;
  final List<MaintenanceAction> actions;

  _StageResult({this.archived = 0, this.deleted = 0, this.warnings = const [], this.actions = const []});

  factory _StageResult.empty() => _StageResult();
}

class _DiskResult {
  final int deleted;
  final int reclaimedBytes;
  final List<String> warnings;
  final List<MaintenanceAction> actions;

  _DiskResult({this.deleted = 0, this.reclaimedBytes = 0, this.warnings = const [], this.actions = const []});

  factory _DiskResult.empty() => _DiskResult();
}
