import 'dart:async';

import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/config/scheduling_jobs_applier.dart';
import 'package:dartclaw_runtime/src/scheduling/schedule_mutation.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The mutation seam wired the way the composition root wires it: a real
/// `ConfigWriter` over a temp YAML, a real running `ScheduleService` holding one
/// built-in, and the real applier between them. Nothing here fakes the load, so
/// a test that sees a job in `entries` saw the seam put it there.
void main() {
  late Directory tempDir;
  late String configPath;
  late String dataDir;
  late ConfigWriter writer;
  late ScheduleService service;
  late ScheduleMutationService mutations;
  late SchedulingJobsApplier applier;
  late List<_ManualTimer> timers;
  late FakeTurnManager turns;
  late DateTime clock;

  void writeConfig(String jobsBlock) {
    File(configPath).writeAsStringSync('''
port: 3000
host: localhost
scheduling:
  jobs:$jobsBlock
''');
  }

  ScheduledJob builtInHeartbeat() => ScheduledJob(
    id: 'heartbeat',
    scheduleType: ScheduleType.interval,
    intervalMinutes: 30,
    onExecute: () async => 'beat',
  );

  setUp(() {
    clock = DateTime(2026, 9, 2, 12);
    tempDir = Directory.systemTemp.createTempSync('dartclaw_schedule_mutation_');
    configPath = p.join(tempDir.path, 'dartclaw.yaml');
    dataDir = p.join(tempDir.path, 'data');
    Directory(dataDir).createSync();
    writeConfig(' []');
    writer = ConfigWriter(configPath: configPath);
    timers = [];
    final jobsStore = ScheduleMutationService(writer: writer);
    turns = FakeTurnManager(
      onWaitForOutcome: (sessionId, turnId) async => TurnOutcome(
        turnId: turnId,
        sessionId: sessionId,
        status: TurnStatus.completed,
        responseText: 'done',
        completedAt: clock,
      ),
    );
    service = ScheduleService(
      turns: turns,
      sessions: InMemorySessionService(),
      jobs: [builtInHeartbeat()],
      now: () => clock,
      timerFactory: (duration, callback) {
        final timer = _ManualTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
      onOneTimeComplete: (id) => jobsStore.removeJobs([id]),
    )..start();
    applier = SchedulingJobsApplier(
      configPath: configPath,
      jobs: jobsStore,
      scheduleService: () => service,
      taskService: TaskService(InMemoryTaskRepository()),
      now: () => clock,
    );
    mutations = ScheduleMutationService(
      writer: writer,
      applyJobs: applier.apply,
      reservedJobIds: () => service.builtInJobIds,
      now: () => clock,
    );
  });

  tearDown(() async {
    service.stop();
    await writer.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String configText() => File(configPath).readAsStringSync();
  bool restartMarkerWritten() => File(p.join(dataDir, 'restart.pending')).existsSync();
  Map<String, dynamic> applied(ScheduleMutationResult result) {
    expect(
      result,
      isA<ScheduleMutationApplied>(),
      reason: result is ScheduleMutationRefused ? result.refusal.message : '',
    );
    return (result as ScheduleMutationApplied).value!;
  }

  ScheduleMutationRefusal refused(ScheduleMutationResult result) {
    expect(result, isA<ScheduleMutationRefused>());
    return (result as ScheduleMutationRefused).refusal;
  }

  group('S01 a write is loaded before the seam answers', () {
    test('a created job is in the running scheduler by the time createJob returns', () async {
      final result = await mutations.createJob({
        'name': 'standup',
        'schedule': '0 9 * * 1',
        'prompt': 'Run standup',
        'delivery': 'announce',
      });

      expect(applied(result)['name'], 'standup');
      // The assertion is the whole point: nothing has been awaited since the
      // seam returned, so the load happened inside the write.
      expect(service.hasJob('standup'), isTrue);
      expect(service.entries.singleWhere((entry) => entry.id == 'standup').cronExpression, '0 9 * * 1');
      expect(restartMarkerWritten(), isFalse);
    });

    test('an updated job is replaced in the running scheduler and keeps its pause state', () async {
      await mutations.createJob({
        'name': 'standup',
        'schedule': '0 9 * * 1',
        'prompt': 'Run standup',
        'delivery': 'none',
      });
      service.pauseJob('standup');

      await mutations.updateJob('standup', {'schedule': '0 18 * * 1'});

      final entry = service.entries.singleWhere((entry) => entry.id == 'standup');
      expect(entry.cronExpression, '0 18 * * 1');
      expect(entry.paused, isTrue);
      expect(restartMarkerWritten(), isFalse);
    });

    test('a deleted job is unloaded by the time deleteJob returns', () async {
      await mutations.createJob({
        'name': 'standup',
        'schedule': '0 9 * * 1',
        'prompt': 'Run standup',
        'delivery': 'none',
      });
      expect(service.hasJob('standup'), isTrue);

      await mutations.deleteJob('standup');

      expect(service.hasJob('standup'), isFalse);
      expect(service.runJobNow('standup'), RunScheduledJobResult.notFound);
      expect(restartMarkerWritten(), isFalse);
    });

    test('a task-scoped write reaches the applier too', () async {
      await mutations.createTask({
        'id': 'weekly-report',
        'schedule': '0 9 * * 1',
        'title': 'Weekly report',
        'description': 'Summarise the week',
      });

      expect(service.hasJob(ScheduledTaskRunner.jobIdForDefinition('weekly-report')), isTrue);
      expect(restartMarkerWritten(), isFalse);
    });

    test('a built-in is never disturbed by a config write', () async {
      await mutations.createJob({
        'name': 'standup',
        'schedule': '0 9 * * 1',
        'prompt': 'Run standup',
        'delivery': 'none',
      });
      await mutations.deleteJob('standup');

      expect(service.builtInJobIds, {'heartbeat'});
      expect(service.hasJob('heartbeat'), isTrue);
    });
  });

  group('S04 a one-time job is written as a once schedule and loaded', () {
    test('an at instant is stored verbatim under a once schedule and armed', () async {
      final at = clock.add(const Duration(minutes: 10)).toIso8601String();

      final result = await mutations.createJob({
        'name': 'remind-dentist',
        'at': at,
        'prompt': 'Remind me about the dentist',
        'delivery': 'announce',
      });

      expect(applied(result)['schedule'], {'type': 'once', 'at': at});
      final stored = (await mutations.readJobs()).single;
      expect(stored['schedule'], {'type': 'once', 'at': at});
      expect(service.hasJob('remind-dentist'), isTrue);
      // A one-time job carries no cron text; inventing one would misreport when
      // it fires.
      expect(service.entries.singleWhere((entry) => entry.id == 'remind-dentist').cronExpression, isNull);
    });

    test('an update can move a cron job to a one-time instant and back', () async {
      await mutations.createJob({
        'name': 'standup',
        'schedule': '0 9 * * 1',
        'prompt': 'Run standup',
        'delivery': 'none',
      });
      final at = clock.add(const Duration(hours: 2)).toIso8601String();

      await mutations.updateJob('standup', {'at': at});
      expect((await mutations.readJobs()).single['schedule'], {'type': 'once', 'at': at});
      expect(service.entries.singleWhere((entry) => entry.id == 'standup').cronExpression, isNull);

      await mutations.updateJob('standup', {'schedule': '0 9 * * 1'});
      expect((await mutations.readJobs()).single['schedule'], '0 9 * * 1');
      expect(service.entries.singleWhere((entry) => entry.id == 'standup').cronExpression, '0 9 * * 1');
    });
  });

  group('S06 an unhonourable schedule is refused with nothing written', () {
    const past = '2026-09-02T11:59:00.000';
    const future = '2026-09-02T15:00:00.000';
    final cases = <({String name, Map<String, dynamic> extra, String field, String message})>[
      (name: 'an at in the past', extra: {'at': past}, field: 'at', message: '"at" must be later than now: "$past"'),
      (
        name: 'an at that is not an instant',
        extra: {'at': 'tomorrow morning'},
        field: 'at',
        message: 'Invalid "at" instant: "tomorrow morning"',
      ),
      (
        name: 'both schedule and at',
        extra: {'schedule': '0 9 * * 1', 'at': future},
        field: 'at',
        message: 'Pass exactly one of "schedule" and "at", not both',
      ),
      (
        name: 'neither schedule nor at',
        extra: <String, dynamic>{},
        field: 'schedule',
        message: 'One of "schedule" (cron expression) and "at" (one-time instant) is required',
      ),
    ];

    for (final testCase in cases) {
      test('createJob with ${testCase.name} is refused, the YAML is byte-identical', () async {
        final before = configText();
        final loadedBefore = service.entries.map((entry) => entry.id).toList();

        final refusal = refused(
          await mutations.createJob({
            'name': 'remind-dentist',
            'prompt': 'Remind me',
            'delivery': 'none',
            ...testCase.extra,
          }),
        );

        expect(refusal.status, 400);
        expect(refusal.code, 'INVALID_INPUT');
        expect(refusal.field, testCase.field);
        expect(refusal.message, testCase.message);
        expect(configText(), before);
        expect(service.entries.map((entry) => entry.id), loadedBefore);
        expect(restartMarkerWritten(), isFalse);
      });
    }

    test('an invalid cron is still refused with the one cron message', () async {
      final before = configText();

      final refusal = refused(
        await mutations.createJob({
          'name': 'standup',
          'schedule': 'not a cron',
          'prompt': 'Run standup',
          'delivery': 'none',
        }),
      );

      expect(refusal.message, 'Invalid cron expression: "not a cron"');
      expect(configText(), before);
    });
  });

  group('S07 an id a built-in owns is refused', () {
    test('createJob naming a loaded built-in is a conflict and writes nothing', () async {
      final before = configText();

      final refusal = refused(
        await mutations.createJob({
          'name': 'heartbeat',
          'schedule': '0 9 * * 1',
          'prompt': 'Impostor',
          'delivery': 'none',
        }),
      );

      expect(refusal.status, 409);
      expect(refusal.code, 'CONFLICT');
      expect(refusal.message, contains('heartbeat'));
      expect(refusal.message, contains('built-in'));
      expect(configText(), before);
      // The built-in is still the entry under that id, interval and all.
      expect(service.builtInJobIds, {'heartbeat'});
      expect(service.entries.singleWhere((entry) => entry.id == 'heartbeat').cronExpression, isNull);
    });

    test('createTask naming a loaded built-in is a conflict too', () async {
      final refusal = refused(
        await mutations.createTask({
          'id': 'heartbeat',
          'schedule': '0 9 * * 1',
          'title': 'Impostor',
          'description': 'Impostor',
        }),
      );

      expect(refusal.status, 409);
      expect(refusal.message, contains('built-in'));
    });
  });

  group('removeJobs persists an unload the runtime already performed', () {
    test('named entries go and the rest are untouched', () async {
      await mutations.createJob({
        'name': 'standup',
        'schedule': '0 9 * * 1',
        'prompt': 'Run standup',
        'delivery': 'none',
      });
      await mutations.createJob({
        'name': 'digest',
        'schedule': '0 6 * * *',
        'prompt': 'Run digest',
        'delivery': 'none',
      });

      await mutations.removeJobs(const ['standup']);

      expect((await mutations.readJobs()).map((job) => job['name']), ['digest']);
    });

    test('an id that names nothing writes nothing', () async {
      final before = configText();

      await mutations.removeJobs(const ['absent']);

      expect(configText(), before);
    });
  });

  group('S04, S09 a one-time job leaves nothing behind', () {
    test('one-time: a fired job is gone from the scheduler and from scheduling.jobs', () async {
      final at = clock.add(const Duration(minutes: 10));
      await mutations.createJob({
        'name': 'remind-dentist',
        'at': at.toIso8601String(),
        'prompt': 'Remind me about the dentist',
        'delivery': 'announce',
      });
      expect(service.hasJob('remind-dentist'), isTrue);
      final armed = timers.singleWhere((timer) => timer.duration == const Duration(minutes: 10));

      clock = at;
      armed.fire();
      // The removal is the runtime telling the seam to persist an unload it has
      // already performed, so the YAML write settles after the fire returns.
      await _until(() async => (await mutations.readJobs()).isEmpty);

      expect(turns.startTurnCallCount, 1, reason: 'the one-time job must actually have fired');
      expect(service.hasJob('remind-dentist'), isFalse);
      expect(service.entries.map((entry) => entry.id), ['heartbeat']);
      expect(await mutations.readJobs(), isEmpty);
    });

    test('one-time: an instant that passed while the server was down is removed at the next apply', () async {
      final at = clock.subtract(const Duration(hours: 3));
      writeConfig(
        '\n'
        '  - name: remind-dentist\n'
        '    schedule:\n'
        '      type: once\n'
        '      at: "${at.toIso8601String()}"\n'
        '    prompt: Remind me\n'
        '    delivery: none\n'
        '  - name: digest\n'
        '    schedule: "0 6 * * *"\n'
        '    prompt: Run digest\n'
        '    delivery: none',
      );

      await applier.apply();

      expect(service.hasJob('remind-dentist'), isFalse);
      expect(service.hasJob('digest'), isTrue);
      expect((await mutations.readJobs()).map((job) => job['name']), ['digest']);
    });
  });
}

class _ManualTimer implements Timer {
  new(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  var _isActive = true;

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
  void cancel() => _isActive = false;
}

/// Pumps the event queue until [condition] holds, so a test can wait on the
/// config write the runtime kicked off without pinning a turn count to it.
Future<void> _until(Future<bool> Function() condition, {int attempts = 100}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (await condition()) return;
    await pumpEventQueue();
  }
  fail('condition never held after $attempts pumps');
}
