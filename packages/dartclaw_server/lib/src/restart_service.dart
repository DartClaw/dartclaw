import 'dart:async';

import 'package:logging/logging.dart';

import 'turn_manager.dart';

/// Encapsulates the graceful restart lifecycle.
///
/// Drain active turns, broadcast SSE event, write marker, exit.
/// Isolated from HTTP routing for testability.
class RestartService {
  static final _log = Logger('RestartService');

  final TurnManager _turns;
  final Duration drainDeadline;
  final void Function(int code) _exit;
  final void Function(String event, Map<String, dynamic> data)? _broadcastSse;
  final void Function(String dataDir, List<String> fields)? _writeRestartPending;
  final String? _dataDir;

  bool _restarting = false;

  RestartService({
    required TurnManager turns,
    this.drainDeadline = const Duration(seconds: 30),
    required void Function(int code) exit,
    void Function(String event, Map<String, dynamic> data)? broadcastSse,
    void Function(String dataDir, List<String> fields)? writeRestartPending,
    String? dataDir,
  }) : _turns = turns,
       _exit = exit,
       _broadcastSse = broadcastSse,
       _writeRestartPending = writeRestartPending,
       _dataDir = dataDir;

  bool get isRestarting => _restarting;

  /// Initiates graceful restart.
  ///
  /// 1. Sets restarting flag (rejects new turns)
  /// 2. Broadcasts SSE `server_restart` to connected clients
  /// 3. Waits up to [drainDeadline] for active turns to complete naturally;
  ///    force-cancels any remaining turns only after the deadline
  /// 4. Writes `restart.pending` marker with [pendingFields]
  /// 5. Calls exit(0)
  ///
  /// Returns a Future that completes when drain finishes (before exit).
  /// Throws [StateError] if already restarting.
  Future<void> restart({List<String> pendingFields = const []}) async {
    if (_restarting) throw StateError('Restart already in progress');
    _restarting = true;

    _log.info('Graceful restart initiated');

    // Broadcast SSE event to all connected clients.
    _broadcastSse?.call('server_restart', {
      'message': 'Server is restarting...',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'drainDeadlineSeconds': drainDeadline.inSeconds,
    });

    // Drain active turns: wait for natural completion first, force-cancel only
    // remaining turns after the deadline.
    final activeIds = _turns.activeSessionIds.toList();
    if (activeIds.isNotEmpty) {
      _log.info('Draining ${activeIds.length} active turn(s)...');
      try {
        await Future.wait(
          activeIds.map((id) => _turns.waitForCompletion(id, timeout: drainDeadline)),
        ).timeout(drainDeadline);
        _log.info('All turns drained successfully');
      } on TimeoutException {
        _log.warning('Drain deadline exceeded — force-canceling remaining turns');
        for (final sessionId in _turns.activeSessionIds) {
          await _turns.cancelTurn(sessionId);
        }
      }
    }

    // Write restart.pending marker.
    final dd = _dataDir;
    if (dd != null) {
      _writeRestartPending?.call(dd, pendingFields);
    }

    _log.info('Exiting for service manager restart');
    _exit(0);
  }
}
