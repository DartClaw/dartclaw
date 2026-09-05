import 'dart:async';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'schedule_service_fixtures.dart';

/// S04, S05: every disposition of a one-time fire is terminal.
///
/// A `once` job has exactly one instant, so whatever happens to that fire — it
/// completes, exhausts its retries, is skipped by the running guard, is started
/// on demand, or its instant passes while the job is paused — the job unloads
/// and asks for its `scheduling.jobs` entry to go. `schedule_mutation_test.dart`
/// proves the entry actually goes; this suite proves the service asks.
void main() {
  group('ScheduleService one-time jobs', () {
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

    // An on-demand run of a recurring job is not its scheduled fire, so its
    // timer stands. For a one-time job the on-demand run *is* the fire: there is
    // no second instant, so the job unloads and its timer goes with it.
    test('one-time: an on-demand run is the fire, while a recurring job keeps its timer', () {
      fakeAsync((async) {
        final removed = <String>[];
        final futureOnce = ScheduledJob.fromConfig({
          'id': 'future-once',
          'prompt': 'One-time task',
          'schedule': {'type': 'once', 'at': DateTime.now().add(const Duration(hours: 1)).toIso8601String()},
        });
        final service = ScheduleService(
          turns: turns,
          sessions: sessions,
          jobs: [intervalJob, futureOnce],
          onOneTimeComplete: (id) async => removed.add(id),
        )..start();
        final intervalTimer = async.pendingTimers.firstWhere((timer) => timer.duration == const Duration(minutes: 60));

        expect(service.runJobNow('exec-job'), RunScheduledJobResult.started);
        expect(service.runJobNow('future-once'), RunScheduledJobResult.started);
        async.flushMicrotasks();

        expect(service.hasJob('exec-job'), isTrue);
        expect(async.pendingTimers, [intervalTimer]);
        expect(service.hasJob('future-once'), isFalse);
        expect(removed, ['future-once']);

        // Past the one-time instant: nothing re-armed for it, so it never fires
        // a second time, while the recurring job keeps its cadence.
        async.elapse(const Duration(hours: 2));
        async.flushMicrotasks();
        expect(removed, ['future-once']);
        expect(service.hasJob('future-once'), isFalse);
        expect(service.hasJob('exec-job'), isTrue);
        expect(async.pendingTimers, hasLength(1));
        service.stop();
      });
    });

    // The scheduled instant arriving mid on-demand run used to leave the fire
    // silently lost. The on-demand run is now the terminal fire, so the job is
    // already unloaded when the instant passes — nothing is dropped unannounced.
    test('one-time: the scheduled instant passing during an on-demand run runs nothing twice', () {
      fakeAsync((async) {
        final start = DateTime(2026, 8, 11, 3);
        final removed = <String>[];
        final release = Completer<void>();
        turns.onStartTurn = (_) => release.future;
        final job = ScheduledJob.fromConfig({
          'id': 'once-window',
          'prompt': 'Run once',
          'schedule': {'type': 'once', 'at': start.add(const Duration(minutes: 1)).toIso8601String()},
        });
        final service = ScheduleService(
          turns: turns,
          sessions: sessions,
          jobs: [job],
          now: () => async.getClock(start).now(),
          onOneTimeComplete: (id) async => removed.add(id),
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
        expect(service.hasJob('once-window'), isFalse);
        expect(removed, ['once-window']);
        service.stop();
      });
    });

    // S04, S05: every disposition of a one-time fire is terminal — the job is
    // unloaded and its `scheduling.jobs` entry is asked for, once.
    test('one-time: a completed fire unloads the job and asks for its entry once', () async {
      var now = DateTime(2026, 9, 2, 8);
      final removed = <String>[];
      final timers = <ManualTimer>[];
      final job = ScheduledJob.fromConfig({
        'id': 'remind-dentist',
        'prompt': 'Remind me',
        'schedule': {'type': 'once', 'at': now.add(const Duration(minutes: 10)).toIso8601String()},
      });
      final service = ScheduleService(
        turns: turns,
        sessions: sessions,
        jobs: [job],
        now: () => now,
        timerFactory: (duration, callback) {
          final timer = ManualTimer(duration, callback);
          timers.add(timer);
          return timer;
        },
        onOneTimeComplete: (id) async => removed.add(id),
      )..start();
      addTearDown(service.stop);

      now = now.add(const Duration(minutes: 10));
      timers.single.fire();
      await pumpEventQueue();

      expect(turns.startTurnCallCount, 1);
      expect(service.entries, isEmpty);
      expect(service.hasJob('remind-dentist'), isFalse);
      expect(removed, ['remind-dentist']);
      expect(timers, hasLength(1), reason: 'nothing may re-arm after the one fire');
    });

    test('one-time: a fire whose retries are all exhausted is still terminal', () async {
      turns.returnFailedOutcome = true;
      final removed = <String>[];
      final job = ScheduledJob.fromConfig({
        'id': 'doomed',
        'prompt': 'Fail',
        'schedule': {'type': 'once', 'at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String()},
        'retry': {'attempts': 1, 'delay_seconds': 0},
      });
      final service = ScheduleService(
        turns: turns,
        sessions: sessions,
        jobs: [job],
        onOneTimeComplete: (id) async => removed.add(id),
      )..start();
      addTearDown(service.stop);

      await service.executeJobForTesting(job);
      await pumpEventQueue(times: 20);

      expect(turns.startTurnCallCount, 2);
      expect(service.hasJob('doomed'), isFalse);
      expect(removed, ['doomed']);
    });

    test('one-time: a fire the running-guard skips is terminal too', () async {
      final removed = <String>[];
      final release = Completer<void>();
      turns.onStartTurn = (_) => release.future;
      final job = ScheduledJob.fromConfig({
        'id': 'busy-once',
        'prompt': 'Run once',
        'schedule': {'type': 'once', 'at': DateTime.now().add(const Duration(hours: 1)).toIso8601String()},
      });
      final service = ScheduleService(
        turns: turns,
        sessions: sessions,
        jobs: [job],
        onOneTimeComplete: (id) async => removed.add(id),
      )..start();
      addTearDown(service.stop);

      unawaited(service.executeJobForTesting(job));
      await pumpEventQueue();
      // A second fire while the first is still in flight: the guard skips it,
      // and that skip is the job's last chance to run.
      await service.executeJobForTesting(job);

      expect(service.hasJob('busy-once'), isFalse);
      expect(removed, ['busy-once']);
      release.complete();
      await pumpEventQueue(times: 20);
      expect(turns.startTurnCallCount, 1);
    });

    test('one-time: resuming a paused job whose instant has passed removes it instead of arming it', () {
      fakeAsync((async) {
        final start = DateTime(2026, 9, 2, 8);
        final removed = <String>[];
        final job = ScheduledJob.fromConfig({
          'id': 'slept-through',
          'prompt': 'Remind me',
          'schedule': {'type': 'once', 'at': start.add(const Duration(minutes: 10)).toIso8601String()},
        });
        final service = ScheduleService(
          turns: turns,
          sessions: sessions,
          jobs: [job],
          now: () => async.getClock(start).now(),
          onOneTimeComplete: (id) async => removed.add(id),
        )..start();
        addTearDown(service.stop);

        service.pauseJob('slept-through');
        async.elapse(const Duration(hours: 1));
        service.resumeJob('slept-through');

        expect(service.hasJob('slept-through'), isFalse);
        expect(removed, ['slept-through']);
        expect(async.pendingTimers, isEmpty);
        expect(turns.startTurnCallCount, 0);
      });
    });

    test('one-time: a paused job whose instant passes is missed, not left loaded', () {
      fakeAsync((async) {
        final start = DateTime(2026, 9, 2, 8);
        final removed = <String>[];
        final job = ScheduledJob.fromConfig({
          'id': 'slept-through',
          'prompt': 'Remind me',
          'schedule': {'type': 'once', 'at': start.add(const Duration(minutes: 10)).toIso8601String()},
        });
        final service = ScheduleService(
          turns: turns,
          sessions: sessions,
          jobs: [job],
          now: () => async.getClock(start).now(),
          onOneTimeComplete: (id) async => removed.add(id),
        )..start();
        addTearDown(service.stop);

        service.pauseJob('slept-through');
        // A paused recurring job loses its timer; a paused one-time job keeps it,
        // because the instant it is armed for is the job's only chance to be
        // noticed at all.
        expect(async.pendingTimers, hasLength(1));

        async.elapse(const Duration(minutes: 11));
        async.flushMicrotasks();

        expect(turns.startTurnCallCount, 0, reason: 'a paused job must not run');
        expect(service.hasJob('slept-through'), isFalse);
        expect(service.isJobPaused('slept-through'), isFalse);
        expect(removed, ['slept-through']);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('one-time: an instant that passed before start unloads the job instead of throwing', () {
      fakeAsync((async) {
        final start = DateTime(2026, 9, 2, 8);
        final removed = <String>[];
        // Composed while the instant was still ahead, started after it passed —
        // arming must unload the job without breaking the arming loop.
        final stale = ScheduledJob.fromConfig({
          'id': 'stale-once',
          'prompt': 'Too late',
          'schedule': {'type': 'once', 'at': start.subtract(const Duration(minutes: 1)).toIso8601String()},
        });
        final service = ScheduleService(
          turns: turns,
          sessions: sessions,
          jobs: [stale, intervalJob],
          now: () => async.getClock(start).now(),
          onOneTimeComplete: (id) async => removed.add(id),
        );

        service.start();

        expect(service.hasJob('stale-once'), isFalse);
        expect(removed, ['stale-once']);
        // The sibling after it in the list was still armed — the loop survived.
        expect(service.hasJob('exec-job'), isTrue);
        expect(async.pendingTimers, hasLength(1));
        service.stop();
      });
    });
  });
}
