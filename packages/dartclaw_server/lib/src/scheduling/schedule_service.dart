import 'dart:async';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import '../api/sse_broadcast.dart';
import 'delivery.dart';
import 'scheduled_job.dart';
import 'system_action.dart';

final _log = Logger('ScheduleService');

Future<String> _noopChannelDispatch(
  String sessionKey,
  String message, {
  String? senderJid,
  String? senderDisplayName,
}) async => '';

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

/// Thrown when a scheduled turn fails.
class ScheduleTurnFailureException implements Exception {
  final String message;
  final Object? cause;

  ScheduleTurnFailureException(this.message, {this.cause});

  @override
  String toString() => cause != null
      ? 'ScheduleTurnFailureException: $message (cause: $cause)'
      : 'ScheduleTurnFailureException: $message';
}

/// Result of attempting to start a runnable scheduling entry immediately.
enum RunScheduledJobResult { started, alreadyRunning, notFound }

/// Manages time-based job execution: cron, interval, and one-time schedules.
///
/// Each job runs in an isolated session (via [SessionKey.cronSession]) to avoid
/// polluting user chat. Uses single-shot [Timer] + reschedule pattern
/// to handle variable cron intervals and timer drift.
class ScheduleService implements Reconfigurable {
  final TurnManager _turns;
  final SessionService _sessions;
  final List<ScheduledJob> _jobs;
  final Map<String, SystemAction> _systemActions;
  final DeliveryService _delivery;
  final String? _workerProviderId;
  final ExecutionPolicy? _workerPolicy;
  final Timer Function(Duration duration, void Function() callback) _timerFactory;
  final DateTime Function() _now;

  final Map<String, Timer> _timers = {};
  final Set<String> _running = {};
  final Set<String> _paused = {};
  bool _started = false;
  final EventBus? _eventBus;

  ScheduleService({
    required TurnManager turns,
    required SessionService sessions,
    required List<ScheduledJob> jobs,
    List<SystemAction> systemActions = const [],
    DeliveryService? delivery,
    EventBus? eventBus,
    String? workerProviderId,
    ExecutionPolicy? workerPolicy,
    Timer Function(Duration duration, void Function() callback)? timerFactory,
    DateTime Function()? now,
  }) : _turns = turns,
       _sessions = sessions,
       _jobs = List.unmodifiable(jobs),
       _systemActions = _validatedSystemActions(jobs, systemActions),
       _delivery = delivery ?? _defaultDeliveryService(sessions),
       _eventBus = eventBus,
       _workerProviderId = workerProviderId,
       _workerPolicy = workerPolicy,
       _timerFactory = timerFactory ?? Timer.new,
       _now = now ?? DateTime.now;

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

  /// Starts a configured prompt job without changing its schedule or pause state.
  RunScheduledJobResult runJobNow(String id) {
    if (!_started) return RunScheduledJobResult.notFound;

    final action = _systemActions[id];
    if (action != null) {
      if (action.isBlocked?.call() ?? false) return RunScheduledJobResult.alreadyRunning;
      if (!_running.add(id)) return RunScheduledJobResult.alreadyRunning;
      unawaited(
        _executeSystemAction(action).catchError((Object error, StackTrace stackTrace) {
          _log.severe('System action "$id" failed unexpectedly', error, stackTrace);
        }),
      );
      return RunScheduledJobResult.started;
    }

    ScheduledJob? job;
    for (final candidate in _jobs) {
      if (candidate.id == id && candidate.onExecute == null) {
        job = candidate;
        break;
      }
    }
    if (job == null) return RunScheduledJobResult.notFound;
    if (!_running.add(id)) return RunScheduledJobResult.alreadyRunning;

    unawaited(
      _executeNow(job).catchError((Object error, StackTrace stackTrace) {
        _log.severe('Job "$id": on-demand execution failed unexpectedly', error, stackTrace);
      }),
    );
    return RunScheduledJobResult.started;
  }

  Future<void> _executeSystemAction(SystemAction action) async {
    _log.info('System action "${action.id}": executing on demand');
    await action.run();
    _running.remove(action.id);
  }

  Future<void> _executeNow(ScheduledJob job) async {
    _log.info('Job "${job.id}": executing on demand');
    try {
      await _executeWithRetry(job);
    } finally {
      _running.remove(job.id);
    }
  }

  void _scheduleNext(ScheduledJob job, {DateTime? completedCronBoundary}) {
    _timers[job.id]?.cancel();

    final now = _now();
    late final DateTime fireAt;
    late final Duration delay;

    switch (job.scheduleType) {
      case ScheduleType.cron:
        final cron = job.cronExpression;
        if (cron == null) {
          _log.severe('Job "${job.id}": cron expression missing');
          return;
        }
        try {
          final reference = completedCronBoundary != null && completedCronBoundary.isAfter(now)
              ? completedCronBoundary
              : now;
          final next = cron.nextFrom(reference);
          fireAt = next;
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
        fireAt = now.add(delay);
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
        fireAt = at;
        delay = at.difference(now);
        _log.info('Job "${job.id}": one-time fire at $at (${delay.inMinutes}m)');
    }

    _armTimer(job, fireAt, delay, guardBoundary: job.scheduleType != ScheduleType.interval);
  }

  void _armTimer(ScheduledJob job, DateTime fireAt, Duration delay, {required bool guardBoundary}) {
    _timers[job.id] = _timerFactory(delay.isNegative ? Duration.zero : delay, () {
      final remaining = fireAt.difference(_now());
      if (guardBoundary && remaining > Duration.zero) {
        _armTimer(job, fireAt, remaining, guardBoundary: true);
        return;
      }
      unawaited(_executeJob(job, scheduledFor: guardBoundary ? fireAt : null));
    });
  }

  Future<void> _executeJob(ScheduledJob job, {DateTime? scheduledFor}) async {
    if (_paused.contains(job.id)) {
      _log.info('Job "${job.id}": paused — skipping fire');
      return;
    }
    if (_running.contains(job.id)) {
      _log.warning('Job "${job.id}": still running from previous fire — skipping');
      _reschedule(job, completedCronBoundary: scheduledFor);
      return;
    }

    _running.add(job.id);
    _log.info('Job "${job.id}": executing');

    try {
      await _executeWithRetry(job);
    } finally {
      _running.remove(job.id);
      _reschedule(job, completedCronBoundary: scheduledFor);
    }
  }

  Future<void> _executeWithRetry(ScheduledJob job) async {
    final maxAttempts = job.retryAttempts + 1;
    Object? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final result = await _runJobTurn(job);
        await _delivery.deliver(mode: job.deliveryMode, jobId: job.id, result: result, webhookUrl: job.webhookUrl);
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
    final sessionKey = SessionKey.cronSession(jobId: job.id);

    // Built-in callback jobs run directly — no agent turn needed.
    if (job.onExecute != null) {
      await _sessions.getOrCreateByKey(sessionKey, type: SessionType.cron);
      return job.onExecute!();
    }

    // Create isolated session for this cron job
    final session = await _sessions.getOrCreateByKey(
      sessionKey,
      type: SessionType.cron,
      provider: _workerProviderId,
      securityProfile: _workerProviderId == null ? null : _workerPolicy?.containerProfile,
      executionMode: _workerProviderId == null ? null : _workerPolicy?.mode,
    );

    final userMessage = <String, dynamic>{'role': 'user', 'content': job.prompt};

    final turnId = await _turns.startTurn(
      session.id,
      [userMessage],
      source: 'cron',
      agentName: 'cron:${job.id}',
      model: job.model,
      effort: job.effort,
      allowedTools: job.allowedTools,
      promptScope: PromptScope.task,
    );
    final outcome = await _turns.waitForOutcome(session.id, turnId);

    if (outcome.status == TurnStatus.failed) {
      throw ScheduleTurnFailureException('Turn failed: ${outcome.errorMessage ?? "unknown error"}');
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

  // Exposed for wiring tests that need to assert composition-root jobs.
  List<ScheduledJob> get jobsForTesting => List.unmodifiable(_jobs);

  /// Collision-free read model consumed by scheduling presentation surfaces.
  List<SchedulingEntry> get entries => List.unmodifiable([
    for (final job in _jobs)
      SchedulingEntry(id: job.id, kind: SchedulingEntryKind.job, runnable: job.onExecute == null, mutable: true),
    for (final action in _systemActions.values)
      SchedulingEntry(id: action.id, kind: SchedulingEntryKind.systemAction, runnable: true, mutable: false),
  ]);

  void _reschedule(ScheduledJob job, {DateTime? completedCronBoundary}) {
    if (!_started || _paused.contains(job.id)) return;

    // One-time jobs don't reschedule
    if (job.scheduleType == ScheduleType.once) {
      _log.info('Job "${job.id}": one-time job completed — not rescheduling');
      _timers.remove(job.id);
      return;
    }

    _scheduleNext(job, completedCronBoundary: completedCronBoundary);
  }
}

Map<String, SystemAction> _validatedSystemActions(List<ScheduledJob> jobs, List<SystemAction> actions) {
  final byId = <String, SystemAction>{};
  for (final action in actions) {
    if (action.id.trim().isEmpty) throw ArgumentError.value(action.id, 'systemActions', 'ID must not be blank');
    if (byId.containsKey(action.id)) {
      throw ArgumentError.value(action.id, 'systemActions', 'duplicate system-action ID');
    }
    byId[action.id] = action;
  }
  validateReservedSystemActionIds(jobs.map((job) => job.id), byId.keys);
  return Map.unmodifiable(byId);
}
