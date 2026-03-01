import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import '../turn_manager.dart';
import 'delivery.dart';
import 'scheduled_job.dart';

final _log = Logger('ScheduleService');

/// Manages time-based job execution: cron, interval, and one-time schedules.
///
/// Each job runs in an isolated session (via [SessionKey.cronSession]) to avoid
/// polluting user chat. Uses single-shot [Timer] + reschedule pattern
/// to handle variable cron intervals and timer drift.
class ScheduleService {
  final TurnManager _turns;
  final SessionService _sessions;
  final List<ScheduledJob> _jobs;

  final Map<String, Timer> _timers = {};
  final Set<String> _running = {};
  bool _started = false;

  ScheduleService({
    required TurnManager turns,
    required SessionService sessions,
    required List<ScheduledJob> jobs,
  }) : _turns = turns,
       _sessions = sessions,
       _jobs = jobs;

  /// Schedule all jobs. Calculates next fire time for each and sets timers.
  void start() {
    if (_started) return;
    _started = true;

    if (_jobs.isEmpty) {
      _log.info('No scheduled jobs configured');
      return;
    }

    _log.info('Starting ${_jobs.length} scheduled job(s)');
    for (final job in _jobs) {
      _scheduleNext(job);
    }
  }

  /// Cancel all timers and stop scheduling.
  void stop() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _running.clear();
    _started = false;
  }

  void _scheduleNext(ScheduledJob job) {
    _timers[job.id]?.cancel();

    final now = DateTime.now();
    Duration? delay;

    switch (job.scheduleType) {
      case ScheduleType.cron:
        final cron = job.cronExpression;
        if (cron == null) {
          _log.severe('Job "${job.id}": cron expression missing');
          return;
        }
        try {
          final next = cron.nextFrom(now);
          delay = next.difference(now);
          _log.info('Job "${job.id}": next fire at $next (${delay.inMinutes}m)');
        } on StateError catch (e) {
          _log.severe('Job "${job.id}": cannot calculate next cron time: $e');
          return;
        }

      case ScheduleType.interval:
        final minutes = job.intervalMinutes;
        if (minutes == null || minutes < 1) {
          _log.severe('Job "${job.id}": invalid interval minutes');
          return;
        }
        delay = Duration(minutes: minutes);
        _log.info('Job "${job.id}": next fire in ${delay.inMinutes}m');

      case ScheduleType.once:
        final at = job.onceAt;
        if (at == null) {
          _log.severe('Job "${job.id}": missing "at" time for one-time schedule');
          return;
        }
        if (at.isBefore(now)) {
          _log.warning('Job "${job.id}": one-time schedule at $at is in the past — skipping');
          return;
        }
        delay = at.difference(now);
        _log.info('Job "${job.id}": one-time fire at $at (${delay.inMinutes}m)');
    }

    _timers[job.id] = Timer(delay, () {
      unawaited(_executeJob(job));
    });
  }

  Future<void> _executeJob(ScheduledJob job) async {
    if (_running.contains(job.id)) {
      _log.warning('Job "${job.id}": still running from previous fire — skipping');
      _reschedule(job);
      return;
    }

    _running.add(job.id);
    _log.info('Job "${job.id}": executing');

    try {
      await _executeWithRetry(job);
    } finally {
      _running.remove(job.id);
      _reschedule(job);
    }
  }

  Future<void> _executeWithRetry(ScheduledJob job) async {
    final maxAttempts = job.retryAttempts + 1;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final result = await _runJobTurn(job);
        await deliverResult(
          mode: job.deliveryMode,
          jobId: job.id,
          result: result,
          webhookUrl: job.webhookUrl,
        );
        _log.info('Job "${job.id}": completed (attempt $attempt/$maxAttempts)');
        return;
      } catch (e) {
        _log.severe('Job "${job.id}": attempt $attempt/$maxAttempts failed: $e');
        if (attempt < maxAttempts) {
          _log.info('Job "${job.id}": retrying in ${job.retryDelaySeconds}s');
          await Future<void>.delayed(Duration(seconds: job.retryDelaySeconds));
        }
      }
    }
  }

  Future<String> _runJobTurn(ScheduledJob job) async {
    // Create isolated session for this cron job
    final sessionKey = SessionKey.cronSession(jobId: job.id);
    final session = await _sessions.getOrCreateByKey(sessionKey, type: SessionType.cron);

    final userMessage = <String, dynamic>{
      'role': 'user',
      'content': job.prompt,
    };

    final turnId = await _turns.startTurn(session.id, [userMessage]);
    final outcome = await _turns.waitForOutcome(session.id, turnId);

    if (outcome.status == TurnStatus.failed) {
      throw Exception('Turn failed: ${outcome.errorMessage ?? "unknown error"}');
    }

    return 'Job "${job.id}" turn completed with status: ${outcome.status.name}';
  }

  // Exposed for testing only — do not call from production code.
  Future<void> executeJobForTesting(ScheduledJob job) => _executeJob(job);

  void _reschedule(ScheduledJob job) {
    if (!_started) return;

    // One-time jobs don't reschedule
    if (job.scheduleType == ScheduleType.once) {
      _log.info('Job "${job.id}": one-time job completed — not rescheduling');
      _timers.remove(job.id);
      return;
    }

    _scheduleNext(job);
  }
}
