import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';


/// Manages session reset policies: daily timer + per-session idle timeout.
///
/// On reset, keyed sessions (main/channel/cron) are converted to archive type
/// and a fresh session is created with the same key. User sessions have their
/// messages cleared in place. The daily timer fires at a configurable hour
/// (default 4 AM). Idle timeout is opt-in (default 0 = disabled).
class SessionResetService implements Reconfigurable {
  static final _log = Logger('SessionResetService');

  final SessionService _sessions;
  final MessageService _messages;
  int _resetHour;
  int _idleTimeoutMinutes;

  Timer? _dailyTimer;
  final Map<String, Timer> _idleTimers = {};

  SessionResetService({
    required SessionService sessions,
    required MessageService messages,
    int resetHour = 4,
    int idleTimeoutMinutes = 0,
  }) : _sessions = sessions,
       _messages = messages,
       _resetHour = resetHour,
       _idleTimeoutMinutes = idleTimeoutMinutes;

  @override
  Set<String> get watchKeys => const {'sessions.*'};

  @override
  void reconfigure(ConfigDelta delta) {
    final newHour = delta.current.sessions.resetHour;
    final newIdle = delta.current.sessions.idleTimeoutMinutes;
    final hourChanged = newHour != _resetHour;
    _resetHour = newHour;
    _idleTimeoutMinutes = newIdle;
    _log.info('SessionResetService reconfigured (resetHour: $_resetHour, idleTimeoutMinutes: $_idleTimeoutMinutes)');
    if (hourChanged && _dailyTimer != null) {
      _dailyTimer!.cancel();
      _scheduleDailyTimer();
    }
  }

  /// Starts the daily reset timer.
  void start() {
    _scheduleDailyTimer();
  }

  /// Records activity on [sessionId], resetting the idle timer.
  void touchActivity(String sessionId) {
    _idleTimers[sessionId]?.cancel();
    if (_idleTimeoutMinutes <= 0) return;
    _idleTimers[sessionId] = Timer(Duration(minutes: _idleTimeoutMinutes), () => unawaited(_onIdleTimeout(sessionId)));
  }

  /// Resets a session. For keyed sessions (main/channel/cron), the old session
  /// becomes an archive and a fresh session is created with the same key.
  /// For user sessions, messages are cleared in place.
  Future<void> resetSession(String sessionId) async {
    _log.info('Resetting session $sessionId');
    final session = await _sessions.getSession(sessionId);
    if (session == null) return;

    if (session.channelKey != null && _resettableTypes.contains(session.type)) {
      // Keyed session: convert to archive, create fresh replacement
      final msgs = await _messages.getMessages(sessionId);
      if (msgs.isNotEmpty) {
        final archiveTitle = session.title ?? 'Session ${session.createdAt.toIso8601String().substring(0, 10)}';
        await _sessions.updateSessionType(sessionId, SessionType.archive);
        await _sessions.updateTitle(sessionId, archiveTitle);
      } else {
        // No messages — mark as archive so key index treats as stale
        await _sessions.updateSessionType(sessionId, SessionType.archive);
      }
      // Create fresh session with same key+type
      await _sessions.getOrCreateByKey(session.channelKey!, type: session.type);
    } else {
      // User/unkeyed session: clear messages in place
      await _messages.clearMessages(sessionId);
    }

    _idleTimers.remove(sessionId)?.cancel();
  }

  /// Cancels all timers.
  void dispose() {
    _dailyTimer?.cancel();
    for (final timer in _idleTimers.values) {
      timer.cancel();
    }
    _idleTimers.clear();
  }

  void _scheduleDailyTimer() {
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day, _resetHour);
    if (next.isBefore(now) || next.isAtSameMomentAs(now)) {
      next = next.add(const Duration(days: 1));
    }
    final delay = next.difference(now);
    _dailyTimer = Timer(delay, () {
      unawaited(_onDailyReset());
      _scheduleDailyTimer(); // reschedule for next day
    });
    _log.info('Daily reset scheduled for $next (in ${delay.inMinutes} minutes)');
  }

  /// Types subject to automatic reset (daily + idle) and key-based reset
  /// (archive old, create fresh).
  static const _resettableTypes = {SessionType.main, SessionType.channel, SessionType.cron};

  Future<void> _onDailyReset() async {
    _log.info('Daily reset triggered');
    final allSessions = await _sessions.listSessions();
    for (final session in allSessions) {
      if (!_resettableTypes.contains(session.type)) continue;
      try {
        await resetSession(session.id);
      } catch (e) {
        _log.warning('Failed to reset session ${session.id}: $e');
      }
    }
  }

  Future<void> _onIdleTimeout(String sessionId) async {
    _log.info('Idle timeout for session $sessionId');
    try {
      final session = await _sessions.getSession(sessionId);
      if (session == null || !_resettableTypes.contains(session.type)) {
        _idleTimers.remove(sessionId);
        return;
      }
      await resetSession(sessionId);
    } catch (e) {
      _log.warning('Failed to reset idle session $sessionId: $e');
    } finally {
      _idleTimers.remove(sessionId);
    }
  }
}
