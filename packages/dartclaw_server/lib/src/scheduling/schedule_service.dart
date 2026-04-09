import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';


import '../api/sse_broadcast.dart';
import '../behavior/memory_consolidator.dart';
import '../turn_manager.dart';
import 'delivery.dart';
import 'scheduled_job.dart';

final _log = Logger('ScheduleService');

Future<String> _noopChannelDispatch(String sessionKey, String message, {String? senderJid, String? senderDisplayName}) async => '';

DeliveryService _defaultDeliveryService(SessionService sessions) {
  return DeliveryService(
    channelManager: ChannelManager(
      queue: MessageQueue(dispatcher: _noopChannelDispatch),
      config: const ChannelConfig.defaults(),
    ),
    sseBroadcast: SseBroadcast(),
    sessions: sessions,
  );
}

/// Manages time-based job execution: cron, interval, and one-time schedules.
///
/// Each job runs in an isolated session (via [SessionKey.cronSession]) to avoid
/// polluting user chat. Uses single-shot [Timer] + reschedule pattern
/// to handle variable cron intervals and timer drift.
class ScheduleService implements Reconfigurable {
  final TurnManager _turns;
  final SessionService _sessions;
  final List<ScheduledJob> _jobs;
  final DeliveryService _delivery;
  final MemoryConsolidator? _consolidator;

  final Map<String, Timer> _timers = {};
  final Set<String> _running = {};
  final Set<String> _paused = {};
  bool _started = false;
  final EventBus? _eventBus;

  ScheduleService({
    required TurnManager turns,
    required SessionService sessions,
    required List<ScheduledJob> jobs,
    DeliveryService? delivery,
    MemoryConsolidator? consolidator,
    EventBus? eventBus,
  }) : _turns = turns,
       _sessions = sessions,
       _jobs = jobs,
       _delivery = delivery ?? _defaultDeliveryService(sessions),
       _consolidator = consolidator,
       _eventBus = eventBus;

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

  /// Pause a job by name: cancel its pending timer and prevent future fires.
  ///
  /// Idempotent. If the job is currently executing it will complete but
  /// will not reschedule. Call [resumeJob] to re-enable.
  void pauseJob(String id) {
    _paused.add(id);
    _timers[id]?.cancel();
    _timers.remove(id);
  }

  /// Resume a paused job. Re-schedules the next fire time if the service
  /// is currently running.
  ///
  /// Idempotent. No-op if the job was not paused.
  void resumeJob(String id) {
    _paused.remove(id);
    if (!_started) return;
    for (final job in _jobs) {
      if (job.id == id) {
        _scheduleNext(job);
        break;
      }
    }
  }

  /// Whether [id] is currently paused.
  bool isJobPaused(String id) => _paused.contains(id);

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
    if (_paused.contains(job.id)) {
      _log.info('Job "${job.id}": paused — skipping fire');
      return;
    }
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
    Object? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final result = await _runJobTurn(job);
        await _delivery.deliver(mode: job.deliveryMode, jobId: job.id, result: result, webhookUrl: job.webhookUrl);
        await _consolidator?.runIfNeeded();
        _log.info('Job "${job.id}": completed (attempt $attempt/$maxAttempts)');
        return;
      } catch (e) {
        lastError = e;
        _log.severe('Job "${job.id}": attempt $attempt/$maxAttempts failed: $e');
        if (attempt < maxAttempts) {
          _log.info('Job "${job.id}": retrying in ${job.retryDelaySeconds}s');
          await Future<void>.delayed(Duration(seconds: job.retryDelaySeconds));
        }
      }
    }

    // All attempts exhausted — fire alert event if EventBus is wired.
    _eventBus?.fire(
      ScheduledJobFailedEvent(
        jobId: job.id,
        jobName: job.id,
        error: lastError?.toString() ?? 'unknown error',
        timestamp: DateTime.now(),
      ),
    );
  }

  Future<String> _runJobTurn(ScheduledJob job) async {
    // Built-in callback jobs run directly — no agent turn needed.
    if (job.onExecute != null) {
      return job.onExecute!();
    }

    // Create isolated session for this cron job
    final sessionKey = SessionKey.cronSession(jobId: job.id);
    final session = await _sessions.getOrCreateByKey(sessionKey, type: SessionType.cron);

    final userMessage = <String, dynamic>{'role': 'user', 'content': job.prompt};

    final turnId = await _turns.startTurn(
      session.id,
      [userMessage],
      source: 'cron',
      agentName: 'cron:${job.id}',
      model: job.model,
      effort: job.effort,
    );
    final outcome = await _turns.waitForOutcome(session.id, turnId);

    if (outcome.status == TurnStatus.failed) {
      throw Exception('Turn failed: ${outcome.errorMessage ?? "unknown error"}');
    }

    return outcome.responseText ?? '';
  }

  @override
  Set<String> get watchKeys => const {'scheduling.*'};

  @override
  void reconfigure(ConfigDelta delta) {
    _log.info('ScheduleService: scheduling config changed — job list requires restart to take effect');
  }

  // Exposed for testing only — do not call from production code.
  Future<void> executeJobForTesting(ScheduledJob job) => _executeJob(job);

  void _reschedule(ScheduledJob job) {
    if (!_started || _paused.contains(job.id)) return;

    // One-time jobs don't reschedule
    if (job.scheduleType == ScheduleType.once) {
      _log.info('Job "${job.id}": one-time job completed — not rescheduling');
      _timers.remove(job.id);
      return;
    }

    _scheduleNext(job);
  }
}
