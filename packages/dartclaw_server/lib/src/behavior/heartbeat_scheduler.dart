import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'memory_consolidator.dart';
import '../workspace/workspace_git_sync.dart';

/// Periodically processes HEARTBEAT.md in isolated sessions.
///
/// Each heartbeat run reads HEARTBEAT.md from the workspace, dispatches its
/// content as a turn in a unique isolated session, then logs the result.
/// Optionally commits workspace changes via [WorkspaceGitSync] after each cycle.
class HeartbeatScheduler {
  static final _log = Logger('HeartbeatScheduler');

  final Duration interval;
  final String workspaceDir;
  final Future<void> Function(String sessionKey, String message) _dispatch;
  final WorkspaceGitSync? _gitSync;
  final int memoryConsolidationThreshold;
  final MemoryConsolidator? _consolidator;

  Timer? _timer;

  HeartbeatScheduler({
    required this.interval,
    required this.workspaceDir,
    required Future<void> Function(String sessionKey, String message) dispatch,
    WorkspaceGitSync? gitSync,
    MemoryConsolidator? consolidator,
    this.memoryConsolidationThreshold = 32 * 1024,
  }) : _dispatch = dispatch,
       _gitSync = gitSync,
       _consolidator = consolidator;

  /// Start the periodic heartbeat timer.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(_runHeartbeat()));
    _log.info('Heartbeat scheduler started (interval: ${interval.inMinutes}m)');
  }

  /// Stop the heartbeat timer.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _log.info('Heartbeat scheduler stopped');
  }

  /// Run a single heartbeat cycle. Useful for testing or manual trigger.
  Future<void> runOnce() => _runHeartbeat();

  Future<void> _runHeartbeat() async {
    final path = p.join(workspaceDir, 'HEARTBEAT.md');

    String content;
    try {
      content = await File(path).readAsString();
    } on FileSystemException {
      _log.fine('No HEARTBEAT.md found — skipping cycle');
      return;
    } on FormatException catch (e) {
      _log.warning('HEARTBEAT.md has invalid encoding: ${e.message} — skipping cycle');
      return;
    }

    if (content.trim().isEmpty) {
      _log.fine('HEARTBEAT.md is empty — skipping cycle');
      return;
    }

    final sessionKey = 'agent:main:heartbeat:${DateTime.now().toUtc().toIso8601String()}';
    _log.info('Running heartbeat in session $sessionKey');

    try {
      await _dispatch(sessionKey, 'Process this checklist:\n\n$content');
    } catch (e, st) {
      _log.severe('Heartbeat dispatch failed', e, st);
    }

    // Memory consolidation: if MEMORY.md exceeds threshold, dispatch cleanup turn
    await (_consolidator ??
            MemoryConsolidator(
              workspaceDir: workspaceDir,
              dispatch: _dispatch,
              threshold: memoryConsolidationThreshold,
            ))
        .runIfNeeded();

    // Commit workspace changes after heartbeat (git failure never fails heartbeat)
    if (_gitSync != null) {
      try {
        await _gitSync.commitAndPush();
      } catch (e) {
        _log.warning('Git sync after heartbeat failed: $e');
      }
    }
  }
}
