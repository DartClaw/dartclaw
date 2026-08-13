import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import '../delivery_test_support.dart';

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
    late _ConfigurableTurnManager turns;
    late _FakeSessionService sessions;
    late ScheduledJob intervalJob;

    setUp(() {
      turns = _ConfigurableTurnManager();
      sessions = _FakeSessionService();
      intervalJob = ScheduledJob.fromConfig({
        'id': 'exec-job',
        'prompt': 'Run task',
        'schedule': {'type': 'interval', 'minutes': 60},
        'delivery': 'none',
      });
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

      final session = sessions._keyedSessions[SessionKey.cronSession(jobId: intervalJob.id)];
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
      final cronSession = sessions._keyedSessions[SessionKey.cronSession(jobId: 'daily-summary')];
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

    test('on-demand run leaves interval and once timers unchanged', () {
      fakeAsync((async) {
        final futureOnce = ScheduledJob(
          id: 'future-once',
          prompt: 'One-time task',
          scheduleType: ScheduleType.once,
          onceAt: DateTime.now().add(const Duration(hours: 1)),
        );
        final service = ScheduleService(turns: turns, sessions: sessions, jobs: [intervalJob, futureOnce])..start();
        final originalTimers = async.pendingTimers.toList();

        expect(service.runJobNow('exec-job'), RunScheduledJobResult.started);
        expect(service.runJobNow('future-once'), RunScheduledJobResult.started);
        async.flushMicrotasks();

        expect(async.pendingTimers, originalTimers);
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
      final timers = <_ManualTimer>[];
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
          final timer = _ManualTimer(duration, callback);
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
      final timers = <_ManualTimer>[];
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
          final timer = _ManualTimer(duration, callback);
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
      final timers = <_ManualTimer>[];
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
          final timer = _ManualTimer(duration, callback);
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

    test('a once fire skipped during an on-demand run is lost', () {
      fakeAsync((async) {
        final start = DateTime(2026, 8, 11, 3);
        final release = Completer<void>();
        turns.onStartTurn = (_) => release.future;
        final job = ScheduledJob(
          id: 'once-window',
          prompt: 'Run once',
          scheduleType: ScheduleType.once,
          onceAt: start.add(const Duration(minutes: 1)),
        );
        final service = ScheduleService(
          turns: turns,
          sessions: sessions,
          jobs: [job],
          now: () => async.getClock(start).now(),
        )..start();

        expect(service.runJobNow('once-window'), RunScheduledJobResult.started);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 1));

        expect(turns.startTurnCallCount, 1);
        expect(async.pendingTimers, isEmpty);

        release.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(hours: 1));
        expect(turns.startTurnCallCount, 1);
        service.stop();
      });
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
      final timers = <_ManualTimer>[];
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
          final timer = _ManualTimer(duration, callback);
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
    test('system action shares run overlap but receives no timer, retry, delivery, or session', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var calls = 0;
      var timers = 0;
      final turns = _ConfigurableTurnManager();
      final sessions = _FakeSessionService();
      final service = ScheduleService(
        turns: turns,
        sessions: sessions,
        jobs: const [],
        systemActions: [
          SystemAction(
            id: memoryCurationActionId,
            description: 'Curate memory',
            run: () async {
              calls++;
              started.complete();
              await release.future;
            },
          ),
        ],
        timerFactory: (duration, callback) {
          timers++;
          return _ManualTimer(duration, callback);
        },
      )..start();

      expect(service.entries.single.kind, SchedulingEntryKind.systemAction);
      expect(service.entries.single.mutable, isFalse);
      expect(service.runJobNow(memoryCurationActionId), RunScheduledJobResult.started);
      await started.future;
      expect(service.runJobNow(memoryCurationActionId), RunScheduledJobResult.alreadyRunning);
      expect(calls, 1);
      expect(timers, 0);
      expect(turns.startTurnCallCount, 0);
      release.complete();
      await pumpEventQueue();
      service.stop();
    });

    test('configured job collision with a system action fails before start', () {
      final job = ScheduledJob.fromConfig({
        'id': memoryCurationActionId,
        'prompt': 'shadow action',
        'schedule': {'type': 'interval', 'minutes': 60},
      });

      expect(
        () => ScheduleService(
          turns: FakeTurnManager(),
          sessions: _FakeSessionService(),
          jobs: [job],
          systemActions: [SystemAction(id: memoryCurationActionId, description: 'Curate memory', run: () async {})],
        ),
        throwsA(isA<ReservedSystemActionIdException>()),
      );
    });

    test('stop cancels all timers without error', () {
      // We can't easily unit-test timer firing without a TurnManager,
      // but we can verify start/stop lifecycle doesn't throw
      final service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: _FakeSessionService(),
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
      final service = ScheduleService(turns: FakeTurnManager(), sessions: _FakeSessionService(), jobs: []);
      service.start();
      service.stop();
    });

    test('double start is idempotent', () {
      final service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: _FakeSessionService(),
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
        sessions: _FakeSessionService(),
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
        sessions: _FakeSessionService(),
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
      final service = ScheduleService(turns: FakeTurnManager(), sessions: _FakeSessionService(), jobs: []);
      // Operations on unknown job IDs should not throw
      expect(() => service.pauseJob('nonexistent'), returnsNormally);
      expect(() => service.resumeJob('nonexistent'), returnsNormally);
      expect(service.isJobPaused('nonexistent'), isFalse);
    });

    test('callback job runs onExecute in a cron session without agent turn', () async {
      final turns = _ConfigurableTurnManager();
      final sessions = _FakeSessionService();
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
      expect(sessions._keyedSessions, contains(SessionKey.cronSession(jobId: 'callback-job')));
      service.stop();
    });

    test('callback job supports pause/resume lifecycle', () async {
      final turns = _ConfigurableTurnManager();
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
      final service = ScheduleService(turns: turns, sessions: _FakeSessionService(), jobs: [callbackJob]);
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

    test('paused job is skipped during execution', () async {
      final turns = _ConfigurableTurnManager();
      final service = ScheduleService(turns: turns, sessions: _FakeSessionService(), jobs: []);
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

/// Configurable fake for execution tests.
class _ConfigurableTurnManager implements TurnManager {
  int startTurnCallCount = 0;
  bool shouldFail = false;
  bool returnFailedOutcome = false;
  String responseText = 'simulated assistant output';

  /// Captured model/effort from the most recent startTurn call.
  String? lastModel;
  String? lastEffort;
  List<String>? lastAllowedTools;

  /// Optional hook called inside startTurn — use to block execution for concurrency tests.
  Future<void> Function(String sessionId)? onStartTurn;

  final Map<String, Completer<TurnOutcome>> _pending = {};

  @override
  Future<String> startTurn(
    String sessionId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    String? model,
    String? effort,
    String? systemPromptOverride,
    int? maxTurns,
    String? taskId,
    bool isHumanInput = false,
    List<String>? allowedTools,
    bool readOnly = false,
    PromptScope? promptScope,
  }) async {
    startTurnCallCount++;
    lastModel = model;
    lastEffort = effort;
    lastAllowedTools = allowedTools;
    final turnId = 'fake-turn-$startTurnCallCount';

    if (shouldFail) {
      throw Exception('Simulated startTurn failure');
    }

    if (onStartTurn != null) {
      await onStartTurn!(sessionId);
    }

    final completer = Completer<TurnOutcome>();
    _pending[turnId] = completer;

    final status = returnFailedOutcome ? TurnStatus.failed : TurnStatus.completed;
    final outcome = TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: status,
      errorMessage: returnFailedOutcome ? 'simulated failure' : null,
      responseText: returnFailedOutcome ? null : responseText,
      completedAt: DateTime.now(),
    );
    completer.complete(outcome);

    return turnId;
  }

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    final c = _pending[turnId];
    if (c == null) throw ArgumentError('Unknown turnId: $turnId');
    return c.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeSessionService implements SessionService {
  final Map<String, Session> _keyedSessions = {};

  @override
  Future<Session> getOrCreateByKey(
    String key, {
    SessionType type = SessionType.user,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
  }) async {
    return _keyedSessions.putIfAbsent(
      key,
      () => Session(
        id: 'fake-uuid-for-$key',
        type: type,
        provider: provider,
        securityProfile: securityProfile,
        executionMode: executionMode,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ManualTimer implements Timer {
  final Duration duration;
  final void Function() _callback;
  var _isActive = true;

  new(this.duration, this._callback);

  void fire() {
    if (!_isActive) return;
    _isActive = false;
    _callback();
  }

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _isActive ? 0 : 1;

  @override
  void cancel() {
    _isActive = false;
  }
}
