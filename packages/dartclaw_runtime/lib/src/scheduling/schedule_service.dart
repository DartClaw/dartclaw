import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import '../api/sse_broadcast.dart';
import 'delivery.dart';
import 'scheduled_job.dart';

final _log = Logger('ScheduleService');

Future<String> _noopChannelDispatch(
  String sessionKey,
  String message, {
  required ChannelType channelType,
  String? senderJid,
  String? senderDisplayName,
  String? groupJid,
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

  new(this.message, {this.cause});

  @override
  String toString() => cause != null
      ? 'ScheduleTurnFailureException: $message (cause: $cause)'
      : 'ScheduleTurnFailureException: $message';
}

/// Result of attempting to start a runnable scheduling entry immediately.
enum RunScheduledJobResult { started, alreadyRunning, notFound }

/// One job [ScheduleService] loaded at construction, as listing surfaces read it.
///
/// [cronExpression] is null for an interval or one-time job — those carry no
/// cron text, and inventing one would misreport when the job fires.
typedef LoadedScheduleEntry = ({String id, String? cronExpression, bool paused});

/// Manages time-based job execution: cron, interval, and one-time schedules.
///
/// Each job runs in an isolated session (via [SessionKey.cronSession]) to avoid
/// polluting user chat. Uses single-shot [Timer] + reschedule pattern
/// to handle variable cron intervals and timer drift.
class ScheduleService {
  final TurnManager _turns;
  final SessionService _sessions;
  final List<ScheduledJob> _jobs;
  final DeliveryService _delivery;
  final String? _workerProviderId;
  final ExecutionPolicy? _workerPolicy;
  final Timer Function(Duration duration, void Function() callback) _timerFactory;
  final DateTime Function() _now;
  final Future<void> Function(String jobId)? _onOneTimeComplete;

  final Map<String, Timer> _timers = {};
  final Set<String> _running = {};
  final Set<String> _paused = {};
  bool _started = false;
  final EventBus? _eventBus;

  new({
    required TurnManager turns,
    required SessionService sessions,
    required List<ScheduledJob> jobs,
    DeliveryService? delivery,
    EventBus? eventBus,
    String? workerProviderId,
    ExecutionPolicy? workerPolicy,
    Timer Function(Duration duration, void Function() callback)? timerFactory,
    DateTime Function()? now,
    Future<void> Function(String jobId)? onOneTimeComplete,
  }) : _turns = turns,
       _sessions = sessions,
       _jobs = _withoutShadowedBuiltIns(jobs),
       _delivery = delivery ?? _defaultDeliveryService(sessions),
       _eventBus = eventBus,
       _workerProviderId = workerProviderId,
       _workerPolicy = workerPolicy,
       _timerFactory = timerFactory ?? Timer.new,
       _now = now ?? DateTime.now,
       _onOneTimeComplete = onOneTimeComplete;

  /// Drops any config-declared job whose id a built-in already owns.
  ///
  /// The same rule [replaceConfigJobs] applies, enforced here too because a
  /// shadowing entry would otherwise take the built-in's place in [_loadedJob]
  /// and leave the built-in's timer un-armed for the life of the process.
  static List<ScheduledJob> _withoutShadowedBuiltIns(List<ScheduledJob> jobs) {
    final builtIns = {
      for (final job in jobs)
        if (!job.isConfigDeclared) job.id,
    };
    final loadable = <ScheduledJob>[];
    for (final job in jobs) {
      if (job.isConfigDeclared && builtIns.contains(job.id)) {
        _log.warning('Job "${job.id}": a built-in already owns this id — the config entry is not loaded');
        continue;
      }
      loadable.add(job);
    }
    return loadable;
  }

  /// Schedule all jobs. Calculates next fire time for each and sets timers.
  void start() {
    if (_started) return;
    _started = true;

    if (_jobs.isEmpty) {
      _log.info('No scheduled jobs configured');
      return;
    }

    _log.info('Starting ${_jobs.length} scheduled job(s)');
    // A copy: arming a one-time job whose instant has already passed unloads it,
    // which mutates _jobs mid-iteration.
    for (final job in [..._jobs]) {
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
  ///
  /// A one-time job keeps its timer: its instant arrives once, and the fire it
  /// arrives for is skipped as paused and then treated as terminal, so the job
  /// unloads and its entry goes instead of outliving the instant as a paused
  /// row nothing will ever run.
  void pauseJob(String id) {
    _paused.add(id);
    final job = _loadedJob(id);
    if (job != null && _armsWhilePaused(job)) return;
    _timers[id]?.cancel();
    _timers.remove(id);
  }

  /// Whether [job] keeps a timer while it is paused.
  ///
  /// A one-time job does. Its instant arrives once, and a job that sleeps
  /// through it while paused must still be noticed and unloaded rather than
  /// left as a paused row nothing will ever run — [_executeJob] skips the fire
  /// and treats it as terminal. Every site that decides whether to arm a paused
  /// job asks here, so the two cannot answer differently.
  static bool _armsWhilePaused(ScheduledJob job) => job.scheduleType == ScheduleType.once;

  /// Resume a paused job. Re-schedules the next fire time if the service
  /// is currently running.
  ///
  /// Idempotent. No-op if the job was not paused.
  void resumeJob(String id) {
    _paused.remove(id);
    if (!_started) return;
    final job = _loadedJob(id);
    if (job != null) _scheduleNext(job);
  }

  /// Whether [id] is currently paused.
  bool isJobPaused(String id) => _paused.contains(id);

  /// Every job this service currently has loaded, with its schedule text and
  /// pause state.
  ///
  /// An entry here is a job that will actually fire. [replaceConfigJobs] keeps
  /// the config-declared half in step with `scheduling.jobs`, so a job written
  /// through the mutation seam appears without a restart, and a spent one-time
  /// job is gone.
  List<LoadedScheduleEntry> get entries => [
    for (final job in _jobs)
      (id: job.id, cronExpression: job.cronExpression?.expression, paused: _paused.contains(job.id)),
  ];

  /// The ids the runtime registered itself, which no `scheduling.jobs` entry
  /// may claim and no live application may replace or unload.
  Set<String> get builtInJobIds => {
    for (final job in _jobs)
      if (!job.isConfigDeclared) job.id,
  };

  /// Applies [jobs] as the complete set of config-declared jobs.
  ///
  /// Built-in jobs are untouched. An id that is new is armed; one whose
  /// definition changed has its timer cancelled and re-armed, keeping its pause
  /// state; one that is gone is unloaded — timer cancelled, pause state dropped,
  /// and an in-flight fire left to finish without re-arming. An id a built-in
  /// already owns is refused, so a hand-edited collision cannot shadow it.
  void replaceConfigJobs(List<ScheduledJob> jobs) {
    final builtIns = builtInJobIds;
    final incoming = <String, ScheduledJob>{
      for (final job in jobs)
        if (!builtIns.contains(job.id)) job.id: job,
    };
    for (final id in jobs.map((job) => job.id).where(builtIns.contains)) {
      _log.warning('Job "$id": a built-in already owns this id — the config entry is not loaded');
    }
    final loaded = <String, ScheduledJob>{
      for (final job in _jobs)
        if (job.isConfigDeclared) job.id: job,
    };

    for (final id in loaded.keys.toList()) {
      if (!incoming.containsKey(id)) _unloadConfigJob(id);
    }
    for (final job in incoming.values) {
      final current = loaded[job.id];
      if (current != null && _sameDefinition(current, job)) continue;
      if (current != null) _unloadConfigJob(job.id, keepPauseState: true);
      _jobs.add(job);
      if (_started && (!_paused.contains(job.id) || _armsWhilePaused(job))) _scheduleNext(job);
    }
  }

  void _unloadConfigJob(String id, {bool keepPauseState = false}) {
    _timers.remove(id)?.cancel();
    _jobs.removeWhere((job) => job.id == id && job.isConfigDeclared);
    if (!keepPauseState) _paused.remove(id);
  }

  /// Whether two definitions of the same id would behave identically.
  ///
  /// Covers every field a `scheduling.jobs` entry can set, so a job the write
  /// did not touch keeps its armed timer and any change at all re-arms.
  static bool _sameDefinition(ScheduledJob a, ScheduledJob b) =>
      a.scheduleType == b.scheduleType &&
      a.cronExpression?.expression == b.cronExpression?.expression &&
      a.intervalMinutes == b.intervalMinutes &&
      a.onceAt == b.onceAt &&
      a.prompt == b.prompt &&
      a.deliveryMode == b.deliveryMode &&
      a.webhookUrl == b.webhookUrl &&
      a.retryAttempts == b.retryAttempts &&
      a.retryDelaySeconds == b.retryDelaySeconds &&
      a.jobType == b.jobType &&
      a.model == b.model &&
      a.effort == b.effort &&
      a.taskDefinition == b.taskDefinition;

  ScheduledJob? _loadedJob(String id) {
    for (final job in _jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  /// Whether a job with [id] is registered.
  ///
  /// Pause, resume and run-now silently no-op for an unregistered id, so a
  /// caller that must refuse instead has to ask first.
  bool hasJob(String id) => _jobs.any((job) => job.id == id);

  /// Starts a runnable prompt job without changing its schedule or pause state.
  RunScheduledJobResult runJobNow(String id) {
    if (!_started) return RunScheduledJobResult.notFound;

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

  Future<void> _executeNow(ScheduledJob job) async {
    _log.info('Job "${job.id}": executing on demand');
    try {
      await _executeWithRetry(job);
    } finally {
      _running.remove(job.id);
      // An on-demand run of a one-time job *is* its fire — there is no second
      // instant to keep it loaded for.
      _completeOneTime(job);
    }
  }

  /// A one-time job has had its fire, whatever the outcome: unload it and drop
  /// its `scheduling.jobs` entry.
  ///
  /// Every disposition arrives here — a completed fire, one whose retries are
  /// exhausted, one the running-guard skipped, an on-demand run, and an instant
  /// that had already passed when the job was armed or resumed — because a
  /// one-time job has exactly one instant and it is now behind us. Leaving the
  /// entry would make the next start warn about a job nothing will ever run.
  void _completeOneTime(ScheduledJob job) {
    if (job.scheduleType != ScheduleType.once || !identical(_loadedJob(job.id), job)) return;
    _timers.remove(job.id)?.cancel();
    if (!job.isConfigDeclared) return;
    _log.info('Job "${job.id}": one-time fire is over — unloading and removing its entry');
    _unloadConfigJob(job.id);
    final removeEntry = _onOneTimeComplete;
    if (removeEntry == null) return;
    unawaited(
      removeEntry(job.id).catchError((Object error, StackTrace stackTrace) {
        _log.severe('Job "${job.id}": removing the spent one-time entry failed', error, stackTrace);
      }),
    );
  }

  void _scheduleNext(ScheduledJob job, {DateTime? completedCronBoundary}) {
    // A job a live application removed or replaced must not re-arm: the
    // in-flight fire that reaches here still holds the object it started with.
    if (!identical(_loadedJob(job.id), job)) return;
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
          _completeOneTime(job);
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
      _completeOneTime(job);
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
        if (result == null) {
          _log.fine('Job "${job.id}": nothing to run this fire — skipping');
          return;
        }
        // Callback jobs report on durable state the operator has to audit later,
        // so their result is logged independently of delivery: `DeliveryMode.none`
        // returns immediately and `announce` reaches nothing when no channel
        // session is open. Prompt-job responses are not logged – they are model
        // output the operator routed deliberately.
        if (job.onExecute != null) _log.info('Job "${job.id}": result\n$result');
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

  Future<String?> _runJobTurn(ScheduledJob job) async {
    // Built-in callback jobs run directly — no agent turn needed.
    if (job.onExecute != null) {
      await _sessions.getOrCreateByKey(SessionKey.cronSession(jobId: job.id), type: SessionType.cron);
      return job.onExecute!();
    }

    // Resolve before the session exists: a skipped fire must leave no cron session behind.
    var prompt = job.prompt;
    if (job.promptResolver != null) {
      final resolved = await job.promptResolver!();
      if (resolved == null) return null;
      prompt = resolved;
    }

    final sessionKey = job.perFireSession
        ? SessionKey.cronSession(jobId: '${job.id}:${DateTime.now().toUtc().toIso8601String()}')
        : SessionKey.cronSession(jobId: job.id);

    // Create isolated session for this cron job
    final session = await _sessions.getOrCreateByKey(
      sessionKey,
      type: SessionType.cron,
      provider: _workerProviderId,
      securityProfile: _workerProviderId == null ? null : _workerPolicy?.containerProfile,
      executionMode: _workerProviderId == null ? null : _workerPolicy?.mode,
    );

    Future<void> Function()? release;
    if (job.composePrompt case final compose?) {
      final composed = await compose(session.id);
      prompt = composed.prompt;
      release = composed.release;
    }

    try {
      final turnId = await _turns.startTurn(
        session.id,
        [
          {'role': 'user', 'content': prompt},
        ],
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
    } finally {
      await release?.call();
    }
  }

  // Exposed for testing only — do not call from production code.
  Future<void> executeJobForTesting(ScheduledJob job) => _executeJob(job);

  // Exposed for wiring tests that need to assert composition-root jobs.
  List<ScheduledJob> get jobsForTesting => List.unmodifiable(_jobs);

  void _reschedule(ScheduledJob job, {DateTime? completedCronBoundary}) {
    if (!identical(_loadedJob(job.id), job)) return;

    // A one-time job never reschedules; its fire was terminal however it ended.
    if (job.scheduleType == ScheduleType.once) {
      _completeOneTime(job);
      return;
    }

    if (!_started || _paused.contains(job.id)) return;
    _scheduleNext(job, completedCronBoundary: completedCronBoundary);
  }
}
