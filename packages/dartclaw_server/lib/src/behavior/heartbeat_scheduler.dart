import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../workspace/workspace_git_sync.dart';

/// Periodically processes HEARTBEAT.md in isolated sessions.
///
/// Each heartbeat cycle reads HEARTBEAT.md from the workspace. Non-empty
/// content is dispatched in a unique isolated session. Workspace sync can run
/// after every cycle, including cycles without a checklist turn.
class HeartbeatScheduler implements Reconfigurable {
  static final _log = Logger('HeartbeatScheduler');

  Duration _interval;
  final String workspaceDir;
  final Future<void> Function(String sessionKey, String message) _dispatch;
  final WorkspaceGitSync? _gitSync;

  Timer? _timer;

  HeartbeatScheduler({
    required Duration interval,
    required this.workspaceDir,
    required Future<void> Function(String sessionKey, String message) dispatch,
    WorkspaceGitSync? gitSync,
  }) : _interval = interval,
       _dispatch = dispatch,
       _gitSync = gitSync;

  Duration get interval => _interval;

  @override
  Set<String> get watchKeys => const {'scheduling.*'};

  @override
  void reconfigure(ConfigDelta delta) {
    final newMinutes = delta.current.scheduling.heartbeatIntervalMinutes;
    final newInterval = Duration(minutes: newMinutes);
    if (newInterval == _interval) return;
    _interval = newInterval;
    _log.info('HeartbeatScheduler interval updated to ${newMinutes}m');
    if (_timer != null) {
      stop();
      start();
    }
  }

  /// Start the periodic heartbeat timer.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => unawaited(_runHeartbeat()));
    _log.info('Heartbeat scheduler started (interval: ${_interval.inMinutes}m)');
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
    try {
      final path = p.join(workspaceDir, 'HEARTBEAT.md');

      String content;
      try {
        content = await File(path).readAsString();
      } on FileSystemException {
        _log.fine('No HEARTBEAT.md found — skipping checklist');
        return;
      } on FormatException catch (e) {
        _log.warning('HEARTBEAT.md has invalid encoding: ${e.message} — skipping checklist');
        return;
      }

      if (content.trim().isEmpty) {
        _log.fine('HEARTBEAT.md is empty — skipping checklist');
        return;
      }

      final sessionKey = 'agent:main:heartbeat:${DateTime.now().toUtc().toIso8601String()}';
      _log.info('Running heartbeat in session $sessionKey');

      try {
        await _dispatch(sessionKey, 'Process this checklist:\n\n$content');
      } catch (e, st) {
        _log.severe('Heartbeat dispatch failed', e, st);
      }
    } finally {
      await _syncWorkspace();
    }
  }

  Future<void> _syncWorkspace() async {
    if (_gitSync != null) {
      try {
        await _gitSync.commitAndPush();
      } catch (e) {
        _log.warning('Workspace git sync failed: $e');
      }
    }
  }
}
