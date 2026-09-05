import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:fake_async/fake_async.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../delivery_test_support.dart';
import 'schedule_service_fixtures.dart';

void main() {
  group('ScheduledJob.fromConfig', () {
    test('parses cron job', () {
      final job = ScheduledJob.fromConfig({
        'id': 'test-cron',
        'prompt': 'Do something',
        'schedule': {'type': 'cron', 'expression': '0 18 * * *'},
        'delivery': 'none',
      });
      expect(job.id, 'test-cron');
      expect(job.prompt, 'Do something');
      expect(job.scheduleType, ScheduleType.cron);
      expect(job.cronExpression, isNotNull);
      expect(job.deliveryMode, DeliveryMode.none);
    });

    test('parses UI-authored cron job shape', () {
      final job = ScheduledJob.fromConfig({
        'name': 'daily-summary',
        'prompt': 'Do something',
        'schedule': '0 18 * * *',
        'delivery': 'announce',
      });
      expect(job.id, 'daily-summary');
      expect(job.prompt, 'Do something');
      expect(job.scheduleType, ScheduleType.cron);
      expect(job.cronExpression, isNotNull);
      expect(job.deliveryMode, DeliveryMode.announce);
    });

    test('parses interval job', () {
      final job = ScheduledJob.fromConfig({
        'id': 'test-interval',
        'prompt': 'Check emails',
        'schedule': {'type': 'interval', 'minutes': 60},
        'delivery': 'webhook',
        'webhook_url': 'http://localhost:8080/hook',
      });
      expect(job.scheduleType, ScheduleType.interval);
      expect(job.intervalMinutes, 60);
      expect(job.deliveryMode, DeliveryMode.webhook);
      expect(job.webhookUrl, 'http://localhost:8080/hook');
    });

    test('parses one-time job', () {
      final job = ScheduledJob.fromConfig({
        'id': 'test-once',
        'prompt': 'Initialize',
        'schedule': {'type': 'once', 'at': '2026-03-01T09:00:00'},
        'delivery': 'none',
      });
      expect(job.scheduleType, ScheduleType.once);
      expect(job.onceAt, DateTime(2026, 3, 1, 9, 0));
    });

    test('parses retry config', () {
      final job = ScheduledJob.fromConfig({
        'id': 'test-retry',
        'prompt': 'Retry test',
        'schedule': {'type': 'interval', 'minutes': 30},
        'retry': {'attempts': 3, 'delay_seconds': 120},
      });
      expect(job.retryAttempts, 3);
      expect(job.retryDelaySeconds, 120);
    });

    test('defaults retry to 0 attempts', () {
      final job = ScheduledJob.fromConfig({
        'id': 'test-no-retry',
        'prompt': 'No retry',
        'schedule': {'type': 'interval', 'minutes': 10},
      });
      expect(job.retryAttempts, 0);
      expect(job.retryDelaySeconds, 60);
    });

    test('throws on missing id', () {
      expect(
        () => ScheduledJob.fromConfig({
          'prompt': 'test',
          'schedule': {'type': 'cron', 'expression': '* * * * *'},
        }),
        throwsFormatException,
      );
    });

    test('throws on missing prompt', () {
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'test',
          'schedule': {'type': 'cron', 'expression': '* * * * *'},
        }),
        throwsFormatException,
      );
    });

    test('throws on invalid cron expression', () {
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'test',
          'prompt': 'test',
          'schedule': {'type': 'cron', 'expression': 'bad'},
        }),
        throwsFormatException,
      );
    });

    test('throws on missing cron expression', () {
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'test',
          'prompt': 'test',
          'schedule': {'type': 'cron'},
        }),
        throwsFormatException,
      );
    });

    test('throws on invalid interval', () {
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'test',
          'prompt': 'test',
          'schedule': {'type': 'interval', 'minutes': 0},
        }),
        throwsFormatException,
      );
    });

    test('throws on invalid once datetime', () {
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'test',
          'prompt': 'test',
          'schedule': {'type': 'once', 'at': 'not-a-date'},
        }),
        throwsFormatException,
      );
    });

    test('throws on unknown schedule type', () {
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'test',
          'prompt': 'test',
          'schedule': {'type': 'weekly'},
        }),
        throwsFormatException,
      );
    });

    test('unknown delivery mode defaults to none', () {
      final job = ScheduledJob.fromConfig({
        'id': 'test',
        'prompt': 'test',
        'schedule': {'type': 'interval', 'minutes': 10},
        'delivery': 'unknown_mode',
      });
      expect(job.deliveryMode, DeliveryMode.none);
    });

    test('user config cannot populate the runtime-only tool policy', () {
      final job = ScheduledJob.fromConfig({
        'id': 'configured-job',
        'prompt': 'Run',
        'schedule': {'type': 'interval', 'minutes': 10},
        'allowed_tools': ['shell'],
      });

      expect(job.allowedTools, isNull);
    });
  });

  group('ScheduleService execution', () {
    late ConfigurableTurnManager turns;
    late FakeSessionService sessions;
    late ScheduledJob intervalJob;

    setUp(() {
      turns = ConfigurableTurnManager();
      sessions = FakeSessionService();
      intervalJob = ScheduledJob.fromConfig({
        'id': 'exec-job',
        'prompt': 'Run task',
        'schedule': {'type': 'interval', 'minutes': 60},
        'delivery': 'none',
      });
    });

    // A prompt job's response is model output the operator routed deliberately;
    // `delivery_mode: none` has to mean it goes nowhere. A callback job reports
    // on durable state that has to stay auditable after `processed/` purges.
    test('a callback job logs its result and a prompt job does not', () async {
      final records = <String>[];
      final subscription = Logger.root.onRecord.listen((record) => records.add(record.message));
      addTearDown(subscription.cancel);
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);
      service.start();
      addTearDown(service.stop);
      turns.responseText = 'prompt job response detail';

      await service.executeJobForTesting(intervalJob);
      await service.executeJobForTesting(
        ScheduledJob(
          id: 'callback-job',
          scheduleType: ScheduleType.interval,
          intervalMinutes: 60,
          deliveryMode: DeliveryMode.none,
          onExecute: () async => 'callback result detail',
        ),
      );

      expect(records.where((message) => message.contains('callback result detail')), hasLength(1));
      // The prompt job's *result*, not its prompt: the prompt was never at risk
      // of being logged, so asserting on it leaves the guard unpinned.
      expect(records.where((message) => message.contains('prompt job response detail')), isEmpty);
    });

    test('executeJobForTesting runs the job and records execution', () async {
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);
      service.start();
      await service.executeJobForTesting(intervalJob);
      expect(turns.startTurnCallCount, 1);
      service.stop();
    });

    test('prompt job forwards its runtime tool policy unchanged', () async {
      final job = ScheduledJob(
        id: 'policy-job',
        prompt: 'Run safely',
        scheduleType: ScheduleType.interval,
        intervalMinutes: 60,
        allowedTools: const ['file_read', 'memory_apply'],
      );
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);

      await service.executeJobForTesting(job);

      expect(turns.lastAllowedTools, ['file_read', 'memory_apply']);
    });

    // The seam exists so a job can be handed state captured at fire time; a
    // composer that ran once at wiring would hand the second fire a stale
    // snapshot, and a release that only ran on success would leave that state
    // authoritative after a failed turn.
    test('a composing job builds its prompt per fire and releases per fire, failure included', () async {
      var fires = 0;
      final released = <int>[];
      final job = ScheduledJob(
        id: 'composing-job',
        scheduleType: ScheduleType.interval,
        intervalMinutes: 60,
        composePrompt: (sessionId) async {
          final fire = ++fires;
          return (prompt: 'fire $fire for $sessionId', release: () async => released.add(fire));
        },
      );
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);

      await service.executeJobForTesting(job);
      final firstPrompt = turns.lastPrompt;
      turns.returnFailedOutcome = true;
      await service.executeJobForTesting(job);

      final sessionId = 'fake-uuid-for-${SessionKey.cronSession(jobId: 'composing-job')}';
      expect(firstPrompt, 'fire 1 for $sessionId');
      expect(turns.lastPrompt, 'fire 2 for $sessionId');
      expect(released, [1, 2]);
    });

    test('a job without a composer still sends its static prompt', () async {
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);

      await service.executeJobForTesting(intervalJob);

      expect(turns.lastPrompt, 'Run task');
    });

    test('prompt job without a runtime policy forwards null', () async {
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);

      await service.executeJobForTesting(intervalJob);

      expect(turns.lastAllowedTools, isNull);
    });

    test('prompt job pins its cron session to the configured worker identity', () async {
      final service = ScheduleService(
        turns: turns,
        sessions: sessions,
        jobs: [],
        workerProviderId: 'codex',
        workerPolicy: const ExecutionPolicy.container('restricted'),
      );

      await service.executeJobForTesting(intervalJob);

      final session = sessions.keyedSessions[SessionKey.cronSession(jobId: intervalJob.id)];
      expect(session?.type, SessionType.cron);
      expect(session?.provider, 'codex');
      expect(session?.securityProfile, 'restricted');
      expect(session?.executionMode, ExecutionMode.container);
    });

    test('successful agent-backed job delivers assistant response text', () async {
      final delivery = RecordingDeliveryService(sessions: sessions);
      turns.responseText = 'assistant summary';
      final announceJob = ScheduledJob.fromConfig({
        'id': 'announce-job',
        'prompt': 'Summarize the latest updates',
        'schedule': {'type': 'interval', 'minutes': 60},
        'delivery': 'announce',
      });

      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [], delivery: delivery);
      service.start();

      await service.executeJobForTesting(announceJob);

      expect(delivery.calls, hasLength(1));
      expect(delivery.calls.single.mode, DeliveryMode.announce);
      expect(delivery.calls.single.jobId, 'announce-job');
      expect(delivery.calls.single.result, 'assistant summary');
      service.stop();
    });

    test('on-demand run delivers through the configured mode', () async {
      final delivery = RecordingDeliveryService(sessions: sessions);
      turns.responseText = 'manual summary';
      final job = ScheduledJob.fromConfig({
        'id': 'daily-summary',
        'prompt': 'Summarize',
        'schedule': {'type': 'interval', 'minutes': 60},
        'delivery': 'announce',
      });
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [job], delivery: delivery)..start();

      expect(service.runJobNow('daily-summary'), RunScheduledJobResult.started);
      await pumpEventQueue();

      expect(delivery.calls.single, (
        mode: DeliveryMode.announce,
        jobId: 'daily-summary',
        result: 'manual summary',
        webhookUrl: null,
      ));
      final cronSession = sessions.keyedSessions[SessionKey.cronSession(jobId: 'daily-summary')];
      expect(cronSession?.type, SessionType.cron);
      expect(cronSession?.provider, isNull);
      expect(cronSession?.securityProfile, isNull);
      service.stop();
    });

    test('on-demand guard is synchronous and rejects overlap', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      turns.onStartTurn = (_) async {
        started.complete();
        await release.future;
      };
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [intervalJob])..start();

      expect(service.runJobNow('exec-job'), RunScheduledJobResult.started);
      expect(service.runJobNow('exec-job'), RunScheduledJobResult.alreadyRunning);
      await started.future;
      expect(service.runJobNow('exec-job'), RunScheduledJobResult.alreadyRunning);
      expect(turns.startTurnCallCount, 1);

      release.complete();
      await pumpEventQueue();
      service.stop();
    });

    test('paused job runs on demand and remains paused without a timer', () {
      fakeAsync((async) {
        final service = ScheduleService(turns: turns, sessions: sessions, jobs: [intervalJob])..start();
        service.pauseJob('exec-job');

        expect(service.runJobNow('exec-job'), RunScheduledJobResult.started);
        async.flushMicrotasks();

        expect(turns.startTurnCallCount, 1);
        expect(service.isJobPaused('exec-job'), isTrue);
        expect(async.pendingTimers, isEmpty);
        service.stop();
      });
    });

    test('scheduled fire during an on-demand run is skipped and interval cadence continues', () {
      fakeAsync((async) {
        final release = Completer<void>();
        turns.onStartTurn = (_) => release.future;
        final oneMinuteJob = ScheduledJob.fromConfig({
          'id': 'cadence-job',
          'prompt': 'Run task',
          'schedule': {'type': 'interval', 'minutes': 1},
        });
        final service = ScheduleService(turns: turns, sessions: sessions, jobs: [oneMinuteJob])..start();
        final firstTimer = async.pendingTimers.single;

        expect(service.runJobNow('cadence-job'), RunScheduledJobResult.started);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 1));

        expect(turns.startTurnCallCount, 1);
        expect(async.pendingTimers.single, isNot(same(firstTimer)));
        expect(async.pendingTimers.single.isActive, isTrue);

        release.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();
        expect(turns.startTurnCallCount, 2);
        service.stop();
      });
    });

    test('cron timer callback before its boundary does not execute or schedule the same occurrence twice', () async {
      var now = DateTime(2026, 8, 11, 2, 59, 55);
      final timers = <ManualTimer>[];
      final cronJob = ScheduledJob(
        id: 'boundary-job',
        prompt: 'Run once at the boundary',
        scheduleType: ScheduleType.cron,
        cronExpression: CronExpression.parse('0 3 * * *'),
      );
      final service = ScheduleService(
        turns: turns,
        sessions: sessions,
        jobs: [cronJob],
        now: () => now,
        timerFactory: (duration, callback) {
          final timer = ManualTimer(duration, callback);
          timers.add(timer);
          return timer;
        },
      )..start();

      expect(timers.single.duration, const Duration(seconds: 5));
      now = DateTime(2026, 8, 11, 2, 59, 56);
      timers.single.fire();
      await pumpEventQueue();

      expect(turns.startTurnCallCount, 0);
      expect(timers, hasLength(2));
      expect(timers.last.duration, const Duration(seconds: 4));

      now = DateTime(2026, 8, 11, 3);
      timers.last.fire();
      await pumpEventQueue();

      expect(turns.startTurnCallCount, 1);
      service.stop();
    });

    test('one-time timer callback before its boundary is re-armed', () async {
      var now = DateTime(2026, 8, 11, 2, 59, 55);
      final timers = <ManualTimer>[];
      final once = ScheduledJob(
        id: 'once-boundary-job',
        prompt: 'Run at the boundary',
        scheduleType: ScheduleType.once,
        onceAt: DateTime(2026, 8, 11, 3),
      );
      final service = ScheduleService(
        turns: turns,
        sessions: sessions,
        jobs: [once],
        now: () => now,
        timerFactory: (duration, callback) {
          final timer = ManualTimer(duration, callback);
          timers.add(timer);
          return timer;
        },
      )..start();

      expect(timers.single.duration, const Duration(seconds: 5));
      now = DateTime(2026, 8, 11, 2, 59, 56);
      timers.single.fire();
      await pumpEventQueue();

      expect(turns.startTurnCallCount, 0);
      expect(timers, hasLength(2));
      expect(timers.last.duration, const Duration(seconds: 4));

      now = DateTime(2026, 8, 11, 3);
      timers.last.fire();
      await pumpEventQueue();

      expect(turns.startTurnCallCount, 1);
      service.stop();
    });

    test('cron reschedule stays after the completed boundary when the clock moves backward', () async {
      var now = DateTime(2026, 8, 11, 2, 59, 55);
      final release = Completer<void>();
      final timers = <ManualTimer>[];
      turns.onStartTurn = (_) => release.future;
      final cronJob = ScheduledJob(
        id: 'rollback-job',
        prompt: 'Run once per boundary',
        scheduleType: ScheduleType.cron,
        cronExpression: CronExpression.parse('0 3 * * *'),
      );
      final service = ScheduleService(
        turns: turns,
        sessions: sessions,
        jobs: [cronJob],
        now: () => now,
        timerFactory: (duration, callback) {
          final timer = ManualTimer(duration, callback);
          timers.add(timer);
          return timer;
        },
      )..start();

      now = DateTime(2026, 8, 11, 3);
      timers.single.fire();
      await pumpEventQueue();
      expect(turns.startTurnCallCount, 1);

      now = DateTime(2026, 8, 11, 2, 59);
      release.complete();
      await pumpEventQueue();

      expect(timers, hasLength(2));
      expect(timers.last.duration, const Duration(days: 1, minutes: 1));
      service.stop();
    });

    test('callback, unknown, and stopped jobs are not runnable on demand', () {
      final callback = ScheduledJob(
        id: 'auto-task-review',
        scheduleType: ScheduleType.interval,
        intervalMinutes: 60,
        onExecute: () async => 'done',
      );
      final pruner = ScheduledJob(
        id: 'memory-pruner',
        scheduleType: ScheduleType.cron,
        cronExpression: CronExpression.parse('0 3 * * *'),
        onExecute: () async => 'done',
      );
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [intervalJob, callback, pruner]);

      expect(service.runJobNow('exec-job'), RunScheduledJobResult.notFound);
      service.start();
      expect(service.runJobNow('missing'), RunScheduledJobResult.notFound);
      expect(service.runJobNow('auto-task-review'), RunScheduledJobResult.notFound);
      expect(service.runJobNow('memory-pruner'), RunScheduledJobResult.notFound);
      service.stop();
      expect(service.runJobNow('exec-job'), RunScheduledJobResult.notFound);
    });

    test('prompt-type system job is runnable on demand', () async {
      final journal = ScheduledJob(
        id: 'memory-journal',
        prompt: 'Journal today',
        scheduleType: ScheduleType.cron,
        cronExpression: CronExpression.parse('0 22 * * *'),
        deliveryMode: DeliveryMode.none,
      );
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [journal])..start();

      expect(service.runJobNow('memory-journal'), RunScheduledJobResult.started);
      await pumpEventQueue();
      expect(turns.startTurnCallCount, 1);
      service.stop();
    });

    test('on-demand failure retries, alerts, and never delivers', () async {
      final delivery = RecordingDeliveryService(sessions: sessions);
      final eventBus = EventBus();
      final failures = <ScheduledJobFailedEvent>[];
      final subscription = eventBus.on<ScheduledJobFailedEvent>().listen(failures.add);
      turns.returnFailedOutcome = true;
      final failing = ScheduledJob.fromConfig({
        'id': 'flaky-job',
        'prompt': 'Fail',
        'schedule': {'type': 'interval', 'minutes': 60},
        'delivery': 'announce',
        'retry': {'attempts': 1, 'delay_seconds': 0},
      });
      final service = ScheduleService(
        turns: turns,
        sessions: sessions,
        jobs: [failing],
        delivery: delivery,
        eventBus: eventBus,
      )..start();

      expect(service.runJobNow('flaky-job'), RunScheduledJobResult.started);
      await pumpEventQueue(times: 20);

      expect(turns.startTurnCallCount, 2);
      expect(delivery.calls, isEmpty);
      expect(failures.single.jobId, 'flaky-job');
      await subscription.cancel();
      service.stop();
    });

    test('one-time job does not reschedule after execution', () async {
      var now = DateTime(2026, 8, 11, 8);
      final timers = <ManualTimer>[];
      final once = ScheduledJob(
        id: 'once-job',
        prompt: 'One-time task',
        scheduleType: ScheduleType.once,
        onceAt: now.add(const Duration(minutes: 1)),
      );
      final service = ScheduleService(
        turns: turns,
        sessions: sessions,
        jobs: [once],
        now: () => now,
        timerFactory: (duration, callback) {
          final timer = ManualTimer(duration, callback);
          timers.add(timer);
          return timer;
        },
      )..start();

      now = now.add(const Duration(minutes: 1));
      timers.single.fire();
      await pumpEventQueue();

      expect(turns.startTurnCallCount, 1);
      expect(timers, hasLength(1));
      service.stop();
    });

    // S02, S03: a live application is the only way a running scheduler learns
    // about a `scheduling.jobs` write, so add/replace/remove must each be
    // observable here and must never disturb a built-in.
    test('live jobs: an added job is armed and fires on its own schedule', () {
      fakeAsync((async) {
        final start = DateTime(2026, 9, 2, 8);
        final builtIn = builtInJob('heartbeat');
        final service = ScheduleService(
          turns: turns,
          sessions: sessions,
          jobs: [builtIn],
          now: () => async.getClock(start).now(),
        )..start();
        addTearDown(service.stop);

        service.replaceConfigJobs([cronJob('standup', '0 9 * * *')]);

        expect(service.entries.map((entry) => entry.id), containsAll(['heartbeat', 'standup']));
        expect(service.hasJob('standup'), isTrue);

        async.elapse(const Duration(hours: 1, minutes: 1));
        async.flushMicrotasks();

        expect(turns.startTurnCallCount, 1);
      });
    });

    test('live jobs: replacing a job cancels its old timer, keeps its pause state and adds no duplicate', () {
      fakeAsync((async) {
        final start = DateTime(2026, 9, 2, 8);
        final service = ScheduleService(
          turns: turns,
          sessions: sessions,
          jobs: [cronJob('standup', '0 9 * * *')],
          now: () => async.getClock(start).now(),
        )..start();
        addTearDown(service.stop);
        service.pauseJob('standup');
        expect(async.pendingTimers, isEmpty);

        service.replaceConfigJobs([cronJob('standup', '0 18 * * *')]);

        final standup = service.entries.where((entry) => entry.id == 'standup');
        expect(standup, hasLength(1));
        expect(standup.single.cronExpression, '0 18 * * *');
        expect(standup.single.paused, isTrue);
        expect(service.isJobPaused('standup'), isTrue);
        // Paused means no timer at all — neither the old one nor a new one.
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('live jobs: an unchanged job keeps its armed timer while a sibling is added', () {
      fakeAsync((async) {
        final start = DateTime(2026, 9, 2, 8);
        final service = ScheduleService(
          turns: turns,
          sessions: sessions,
          jobs: [cronJob('standup', '0 9 * * *')],
          now: () => async.getClock(start).now(),
        )..start();
        addTearDown(service.stop);
        final armed = async.pendingTimers.single;

        service.replaceConfigJobs([cronJob('standup', '0 9 * * *'), cronJob('digest', '0 6 * * *')]);

        expect(async.pendingTimers, contains(armed));
        expect(async.pendingTimers, hasLength(2));
      });
    });

    test('live jobs: a removed job is unloaded, is not runnable and re-arms nothing', () {
      fakeAsync((async) {
        final start = DateTime(2026, 9, 2, 8);
        final builtIn = builtInJob('heartbeat');
        final service = ScheduleService(
          turns: turns,
          sessions: sessions,
          jobs: [builtIn, cronJob('standup', '0 9 * * *')],
          now: () => async.getClock(start).now(),
        )..start();
        addTearDown(service.stop);
        service.pauseJob('standup');

        service.replaceConfigJobs(const []);

        expect(service.hasJob('standup'), isFalse);
        expect(service.entries.map((entry) => entry.id), ['heartbeat']);
        expect(service.isJobPaused('standup'), isFalse);
        expect(service.runJobNow('standup'), RunScheduledJobResult.notFound);

        async.elapse(const Duration(days: 2));
        async.flushMicrotasks();
        expect(turns.startTurnCallCount, 0);
      });
    });

    test('live jobs: an in-flight fire of a removed job completes and re-arms no timer', () async {
      final release = Completer<void>();
      turns.onStartTurn = (_) => release.future;
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [cronJob('standup', '0 9 * * *')])
        ..start();
      addTearDown(service.stop);

      expect(service.runJobNow('standup'), RunScheduledJobResult.started);
      await pumpEventQueue();
      service.replaceConfigJobs(const []);
      expect(service.hasJob('standup'), isFalse);

      release.complete();
      await pumpEventQueue(times: 20);

      // The fire that was already running finished — it was not cancelled — and
      // left nothing armed behind it.
      expect(turns.startTurnCallCount, 1);
      expect(service.entries, isEmpty);
      expect(service.runJobNow('standup'), RunScheduledJobResult.notFound);
    });

    test('live jobs: built-ins survive every replacement and cannot be shadowed by a config entry', () {
      fakeAsync((async) {
        final builtIn = builtInJob('heartbeat');
        final service = ScheduleService(turns: turns, sessions: sessions, jobs: [builtIn])..start();
        addTearDown(service.stop);

        service.replaceConfigJobs([cronJob('heartbeat', '0 9 * * *'), cronJob('standup', '0 9 * * *')]);

        expect(service.builtInJobIds, {'heartbeat'});
        expect(service.entries.where((entry) => entry.id == 'heartbeat'), hasLength(1));
        // The built-in is an interval job; a shadowing cron entry would report
        // its expression here.
        expect(service.entries.singleWhere((entry) => entry.id == 'heartbeat').cronExpression, isNull);

        service.replaceConfigJobs(const []);
        expect(service.entries.map((entry) => entry.id), ['heartbeat']);
        async.elapse(Duration.zero);
      });
    });

    test('live jobs: a config entry shadowing a built-in id is dropped, and the built-in still fires', () {
      fakeAsync((async) {
        // The wiring puts config-declared jobs ahead of the built-ins, so a
        // colliding entry would otherwise be the one an id resolves to and the
        // built-in would never arm.
        final service = ScheduleService(
          turns: turns,
          sessions: sessions,
          jobs: [cronJob('heartbeat', '0 9 * * *'), builtInJob('heartbeat')],
        )..start();
        addTearDown(service.stop);

        expect(service.builtInJobIds, {'heartbeat'});
        expect(service.entries, hasLength(1));
        expect(service.entries.single.cronExpression, isNull, reason: 'the built-in survived, not the config entry');

        async.elapse(const Duration(minutes: 31));
        async.flushMicrotasks();
        expect(async.pendingTimers, hasLength(1), reason: 'the built-in is armed and re-arms');
      });
    });

    test('live jobs: a paused one-time job that is edited keeps its instant and is still missed', () {
      fakeAsync((async) {
        final start = DateTime(2026, 9, 2, 8);
        final removed = <String>[];
        final at = start.add(const Duration(minutes: 10));
        ScheduledJob once(String prompt) => ScheduledJob.fromConfig({
          'id': 'remind',
          'prompt': prompt,
          'schedule': {'type': 'once', 'at': at.toIso8601String()},
        });
        final service = ScheduleService(
          turns: turns,
          sessions: sessions,
          jobs: [once('Remind me')],
          now: () => async.getClock(start).now(),
          onOneTimeComplete: (id) async => removed.add(id),
        )..start();
        addTearDown(service.stop);
        service.pauseJob('remind');

        // A live edit re-adds the job; pausing is what makes the arming decision
        // interesting, and a one-time job must be armed either way.
        service.replaceConfigJobs([once('Remind me, revised')]);
        expect(async.pendingTimers, hasLength(1));

        async.elapse(const Duration(minutes: 11));
        async.flushMicrotasks();

        expect(turns.startTurnCallCount, 0, reason: 'the job was paused, so it must not run');
        expect(service.hasJob('remind'), isFalse);
        expect(removed, ['remind']);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('live jobs: replacing before start arms nothing until start', () {
      fakeAsync((async) {
        final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);
        addTearDown(service.stop);

        service.replaceConfigJobs([cronJob('standup', '0 9 * * *')]);
        expect(async.pendingTimers, isEmpty);

        service.start();
        expect(async.pendingTimers, hasLength(1));
      });
    });

    test('concurrent skip: second call skips if job is already running', () async {
      final firstCallStarted = Completer<void>();
      final firstCallGate = Completer<void>();

      turns.onStartTurn = (sessionId) async {
        if (!firstCallStarted.isCompleted) {
          firstCallStarted.complete();
          // Block the first execution until gate is opened
          await firstCallGate.future;
        }
      };

      final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);
      service.start();

      // Launch first execution — it will block on the gate
      final first = service.executeJobForTesting(intervalJob);
      // Wait until first execution has started
      await firstCallStarted.future;

      // Second execution should skip (job still running)
      await service.executeJobForTesting(intervalJob);

      // Only one startTurn call so far (second was skipped)
      expect(turns.startTurnCallCount, 1);

      // Unblock the first execution
      firstCallGate.complete();
      await first;

      // Still only one total call
      expect(turns.startTurnCallCount, 1);
      service.stop();
    });

    test('job failure does not prevent subsequent execution', () async {
      turns.shouldFail = true;
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);
      service.start();

      // First execution should fail (but not throw — errors are caught internally)
      await service.executeJobForTesting(intervalJob);
      expect(turns.startTurnCallCount, 1);

      // Second execution should run normally
      turns.shouldFail = false;
      await service.executeJobForTesting(intervalJob);
      expect(turns.startTurnCallCount, 2);

      service.stop();
    });

    test('failed turn outcome throws, triggering retry logic', () async {
      // Return a failed TurnOutcome — _executeWithRetry should throw
      turns.returnFailedOutcome = true;
      final delivery = RecordingDeliveryService(sessions: sessions);
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [], delivery: delivery);
      service.start();

      // With retryAttempts = 0, one attempt is made and failure is logged (no throw to caller)
      await service.executeJobForTesting(intervalJob);
      expect(turns.startTurnCallCount, 1);
      expect(delivery.calls, isEmpty);

      service.stop();
    });

    test('model and effort from job are passed through to startTurn', () async {
      final jobWithOverrides = ScheduledJob.fromConfig({
        'id': 'override-job',
        'prompt': 'Do something with overrides',
        'schedule': {'type': 'interval', 'minutes': 60},
        'delivery': 'none',
        'model': 'claude-haiku-4-5',
        'effort': 'low',
      });

      final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);
      service.start();
      await service.executeJobForTesting(jobWithOverrides);

      expect(turns.startTurnCallCount, 1);
      expect(turns.lastModel, 'claude-haiku-4-5');
      expect(turns.lastEffort, 'low');
      service.stop();
    });
  });

  group('ScheduleService', () {
    test('stop cancels all timers without error', () {
      // We can't easily unit-test timer firing without a TurnManager,
      // but we can verify start/stop lifecycle doesn't throw
      final service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: FakeSessionService(),
        jobs: [
          ScheduledJob.fromConfig({
            'id': 'test-job',
            'prompt': 'Do something',
            'schedule': {'type': 'interval', 'minutes': 60},
          }),
        ],
      );
      service.start();
      service.stop();
    });

    test('start with empty jobs is no-op', () {
      final service = ScheduleService(turns: FakeTurnManager(), sessions: FakeSessionService(), jobs: []);
      service.start();
      service.stop();
    });

    test('double start is idempotent', () {
      final service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: FakeSessionService(),
        jobs: [
          ScheduledJob.fromConfig({
            'id': 'test-job',
            'prompt': 'Do something',
            'schedule': {'type': 'interval', 'minutes': 60},
          }),
        ],
      );
      service.start();
      service.start(); // should not throw or double-schedule
      service.stop();
    });

    test('pauseJob marks job as paused', () {
      final service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: FakeSessionService(),
        jobs: [
          ScheduledJob.fromConfig({
            'id': 'my-job',
            'prompt': 'Do something',
            'schedule': {'type': 'interval', 'minutes': 60},
          }),
        ],
      );
      service.start();
      expect(service.isJobPaused('my-job'), isFalse);
      service.pauseJob('my-job');
      expect(service.isJobPaused('my-job'), isTrue);
      service.stop();
    });

    test('resumeJob clears paused state', () {
      final service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: FakeSessionService(),
        jobs: [
          ScheduledJob.fromConfig({
            'id': 'my-job',
            'prompt': 'Do something',
            'schedule': {'type': 'interval', 'minutes': 60},
          }),
        ],
      );
      service.start();
      service.pauseJob('my-job');
      expect(service.isJobPaused('my-job'), isTrue);
      service.resumeJob('my-job');
      expect(service.isJobPaused('my-job'), isFalse);
      service.stop();
    });

    test('pauseJob/resumeJob are idempotent', () {
      final service = ScheduleService(turns: FakeTurnManager(), sessions: FakeSessionService(), jobs: []);
      // Operations on unknown job IDs should not throw
      expect(() => service.pauseJob('nonexistent'), returnsNormally);
      expect(() => service.resumeJob('nonexistent'), returnsNormally);
      expect(service.isJobPaused('nonexistent'), isFalse);
    });

    test('callback job runs onExecute in a cron session without agent turn', () async {
      final turns = ConfigurableTurnManager();
      final sessions = FakeSessionService();
      var callbackInvoked = false;
      final callbackJob = ScheduledJob(
        id: 'callback-job',
        scheduleType: ScheduleType.interval,
        intervalMinutes: 60,
        onExecute: () async {
          callbackInvoked = true;
          return 'callback result';
        },
      );
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [callbackJob]);
      service.start();
      await service.executeJobForTesting(callbackJob);
      expect(callbackInvoked, isTrue);
      // No agent turn should have been created
      expect(turns.startTurnCallCount, 0);
      expect(sessions.keyedSessions, contains(SessionKey.cronSession(jobId: 'callback-job')));
      service.stop();
    });

    test('callback job supports pause/resume lifecycle', () async {
      final turns = ConfigurableTurnManager();
      var invocations = 0;
      final callbackJob = ScheduledJob(
        id: 'pausable-callback',
        scheduleType: ScheduleType.interval,
        intervalMinutes: 60,
        onExecute: () async {
          invocations++;
          return 'ok';
        },
      );
      final service = ScheduleService(turns: turns, sessions: FakeSessionService(), jobs: [callbackJob]);
      service.start();

      // Pause and attempt execution — should skip
      service.pauseJob('pausable-callback');
      await service.executeJobForTesting(callbackJob);
      expect(invocations, 0);

      // Resume and execute — should run
      service.resumeJob('pausable-callback');
      await service.executeJobForTesting(callbackJob);
      expect(invocations, 1);

      service.stop();
    });

    test('a resolver returning nothing skips the fire without failing it', () async {
      final turns = ConfigurableTurnManager();
      final sessions = FakeSessionService();
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final failures = <ScheduledJobFailedEvent>[];
      final subscription = eventBus.on<ScheduledJobFailedEvent>().listen(failures.add);
      addTearDown(subscription.cancel);
      var resolverCalls = 0;
      final job = ScheduledJob(
        id: 'resolving-job',
        scheduleType: ScheduleType.interval,
        intervalMinutes: 60,
        retryAttempts: 2,
        promptResolver: () async {
          resolverCalls++;
          return null;
        },
      );
      final delivery = RecordingDeliveryService(sessions: sessions);
      final service = ScheduleService(
        turns: turns,
        sessions: sessions,
        jobs: [job],
        delivery: delivery,
        eventBus: eventBus,
      )..start();
      addTearDown(service.stop);

      await service.executeJobForTesting(job);
      await pumpEventQueue();

      expect(resolverCalls, 1, reason: 'a skipped fire consumes no retry attempt');
      expect(turns.startTurnCallCount, 0);
      expect(sessions.keyedSessions, isEmpty, reason: 'a skipped fire leaves no cron session behind');
      expect(delivery.calls, isEmpty);
      expect(failures, isEmpty);
    });

    test('two fires of a resolving per-fire job use two distinct session keys', () async {
      final turns = ConfigurableTurnManager();
      final sessions = FakeSessionService();
      final job = ScheduledJob(
        id: 'per-fire-job',
        scheduleType: ScheduleType.interval,
        intervalMinutes: 60,
        perFireSession: true,
        promptResolver: () async => 'do the thing',
      );
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [job])..start();
      addTearDown(service.stop);

      await service.executeJobForTesting(job);
      await service.executeJobForTesting(job);

      expect(turns.startTurnCallCount, 2);
      expect(sessions.keyedSessions, hasLength(2));
      expect(sessions.keyedSessions.keys.every((key) => key.startsWith('agent:main:cron:per-fire-job')), isTrue);
    });

    test('a resolving job sends the resolved prompt, not the static one', () async {
      final turns = ConfigurableTurnManager();
      final job = ScheduledJob(
        id: 'resolved-prompt-job',
        prompt: 'static prompt',
        scheduleType: ScheduleType.interval,
        intervalMinutes: 60,
        promptResolver: () async => 'resolved prompt',
      );
      final service = ScheduleService(turns: turns, sessions: FakeSessionService(), jobs: [job])..start();
      addTearDown(service.stop);

      await service.executeJobForTesting(job);

      expect(turns.lastMessages?.single['content'], 'resolved prompt');
    });

    test('paused job is skipped during execution', () async {
      final turns = ConfigurableTurnManager();
      final service = ScheduleService(turns: turns, sessions: FakeSessionService(), jobs: []);
      service.start();
      final job = ScheduledJob.fromConfig({
        'id': 'skip-job',
        'prompt': 'Do skipped thing',
        'schedule': {'type': 'interval', 'minutes': 60},
      });
      service.pauseJob('skip-job');
      await service.executeJobForTesting(job);
      expect(turns.startTurnCallCount, 0);
      service.stop();
    });
  });
}
