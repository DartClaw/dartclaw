import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show atomicWriteJson;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/config/scheduling_jobs_applier.dart';
import 'package:dartclaw_runtime/src/scheduling/schedule_mutation.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:logging/logging.dart';
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

    test('an applier can remove a missed one-time job reentrantly under the config mutation lock', () async {
      final missedAt = clock.subtract(const Duration(hours: 1)).toIso8601String();
      writeConfig(
        '\n'
        '    - name: missed\n'
        '      schedule:\n'
        '        type: once\n'
        '        at: "$missedAt"\n'
        '      prompt: Missed\n'
        '      delivery: none',
      );

      final result = await mutations
          .createJob({'name': 'digest', 'schedule': '0 6 * * *', 'prompt': 'Run digest', 'delivery': 'none'})
          .timeout(const Duration(seconds: 2));

      expect(result, isA<ScheduleMutationApplied>());
      expect((await mutations.readJobs()).map((job) => job['name']), ['digest']);
      expect(service.hasJob('digest'), isTrue);
      expect(service.hasJob('missed'), isFalse);
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

  group('shell entries are file-only', () {
    const shellBlock = '''
    - id: mail-feed
      type: shell
      schedule: "0 * * * *"
      command:
        - /usr/local/bin/hey
        - mail
      env:
        FEED_TOKEN: feed-secret
      output: mail.json
    - name: digest
      schedule: "0 9 * * *"
      type: prompt
      delivery: none
      prompt: Summarize''';

    setUp(() => writeConfig('\n$shellBlock'));

    void refusesFileOnly(ScheduleMutationResult result, String before) {
      expect(result, isA<ScheduleMutationRefused>());
      final refusal = (result as ScheduleMutationRefused).refusal;
      expect(refusal.status, 400);
      expect(refusal.code, 'INVALID_INPUT');
      expect(refusal.message, contains('Shell jobs are file-only: edit scheduling.jobs in dartclaw.yaml'));
      expect(refusal.message, contains('mail-feed'));
      expect(configText(), before, reason: 'the refused write still changed the file');
    }

    test('refuses every write touching a shell entry', () async {
      final before = configText();

      // Update: any field of the shell entry, whether or not the entry declares it.
      refusesFileOnly(await mutations.updateJob('mail-feed', {'schedule': '*/5 * * * *'}), before);
      refusesFileOnly(await mutations.updateJob('mail-feed', {'output': 'other.json'}), before);
      refusesFileOnly(await mutations.updateJob('mail-feed', {'enabled': false}), before);
      // Delete.
      refusesFileOnly(await mutations.deleteJob('mail-feed'), before);

      // A create cannot reach the shell entry: the id is already taken, and the
      // seam's own conflict check refuses that before any write is composed.
      final create = await mutations.createJob({
        'name': 'mail-feed',
        'schedule': '0 * * * *',
        'type': 'prompt',
        'delivery': 'none',
        'prompt': 'x',
      });
      expect((create as ScheduleMutationRefused).refusal.status, 409);
      expect(configText(), before);
    });

    test('the refusal is decided against a fresh read, not the caller snapshot', () async {
      // A list composed before a hand edit added the shell entry must still be
      // refused: every mutation is a read-modify-write over the whole list.
      final withoutShell = [
        for (final job in await mutations.readJobs())
          if (job['type'] != 'shell') Map<String, dynamic>.from(job),
      ];
      final before = configText();

      await expectLater(mutations.commitAndApply(withoutShell), throwsA(isA<ShellJobWriteRefused>()));
      expect(configText(), before);
    });

    test('duplicate shell ids cannot hide an update or delete of the first entry', () async {
      const duplicateShellBlock = '''
    - id: mail-feed
      type: shell
      schedule: "0 * * * *"
      command:
        - /usr/local/bin/hey
        - first
      output: first.json
    - id: mail-feed
      type: shell
      schedule: "0 * * * *"
      command:
        - /usr/local/bin/hey
        - second
      output: second.json''';
      writeConfig('\n$duplicateShellBlock');
      final before = configText();
      expect((await mutations.readJobs()).map((job) => job['id']), ['mail-feed', 'mail-feed']);

      refusesFileOnly(await mutations.updateJob('mail-feed', {'output': 'changed.json'}), before);
      refusesFileOnly(await mutations.deleteJob('mail-feed'), before);
    });

    test('a prompt write in the same file still succeeds and stays live', () async {
      final created = applied(
        await mutations.createJob({
          'name': 'weekly',
          'schedule': '0 9 * * 1',
          'type': 'prompt',
          'delivery': 'none',
          'prompt': 'Weekly summary',
        }),
      );

      expect(created['name'], 'weekly');
      expect(configText(), contains('weekly'));
      // The shell entry survived the read-modify-write untouched.
      expect(configText(), contains('mail-feed'));
      expect(service.entries.map((entry) => entry.id), contains('weekly'));
      expect(
        applied(await mutations.updateJob('digest', {'prompt': 'Summarize harder'}))['prompt'],
        'Summarize harder',
      );
      expect((await mutations.deleteJob('digest')), isA<ScheduleMutationApplied>());
    });

    test('removeJobs still drops a spent one-time entry beside a shell entry', () async {
      applied(
        await mutations.createJob({
          'name': 'once-off',
          'at': clock.add(const Duration(hours: 1)).toIso8601String(),
          'type': 'prompt',
          'delivery': 'none',
          'prompt': 'Once',
        }),
      );

      await mutations.removeJobs(['once-off']);

      expect(configText(), isNot(contains('once-off')));
      expect(configText(), contains('mail-feed'));
    });
  });
  group('approval mode parks a model-originated upsert', () {
    late PendingScheduleChangeStore store;
    late Set<String> reserved;
    late ScheduleMutationService parking;

    /// A job body the way `schedule_upsert` builds one: validated, `schedule`
    /// already resolved through the seam.
    Map<String, dynamic> body({String id = 'weekly', Object? schedule = '0 9 * * 1'}) => {
      'id': id,
      'schedule': schedule,
      'type': 'prompt',
      'prompt': 'Summarize the week',
      'delivery': 'announce',
    };

    ScheduleMutationService seam({
      required PendingScheduleChangeStore store,
      ScheduleMutationApproval approval = ScheduleMutationApproval.none,
    }) => ScheduleMutationService(
      writer: writer,
      applyJobs: applier.apply,
      reservedJobIds: () => reserved,
      now: () => clock,
      approval: approval,
      pendingChanges: store,
    );

    setUp(() async {
      store = PendingScheduleChangeStore(File(p.join(dataDir, 'pending-schedule-changes.json')));
      await store.load();
      reserved = {...service.builtInJobIds};
      parking = seam(store: store, approval: ScheduleMutationApproval.operator);
    });

    test('S01 under operator an upsert writes nothing and stores one record', () async {
      final before = configText();

      final outcome = await parking.upsertJob(body(), requester: 'mcp-client:ops');

      expect(outcome.result, isA<ScheduleMutationParked>());
      expect(outcome.created, isTrue);
      expect(configText(), before, reason: 'a parked write must leave dartclaw.yaml byte-identical');
      expect(service.hasJob('weekly'), isFalse);
      final change = store.values.single;
      expect(change.changeId, (outcome.result as ScheduleMutationParked).changeId);
      expect(change.jobId, 'weekly');
      expect(change.kind, PendingChangeKind.created);
      expect(change.job, body());
      expect(change.requester, 'mcp-client:ops');
      expect(change.requestedAt, clock.toUtc());
      expect(change.requestedAt.isUtc, isTrue);
    });

    test('a park persistence failure is returned with config, runtime, and memory unchanged', () async {
      final failingStore = PendingScheduleChangeStore(
        File(p.join(dataDir, 'pending-add-failure.json')),
        writeJson: (_, _) async => throw const FileSystemException('injected pending add failure'),
      );
      final before = configText();

      final refusal = refused(
        (await seam(
          store: failingStore,
          approval: ScheduleMutationApproval.operator,
        ).upsertJob(body(), requester: 'mcp-client:ops')).result,
      );

      expect(refusal.code, 'WRITE_FAILED');
      expect(refusal.message, contains('Pending change write failed'));
      expect(configText(), before);
      expect(service.hasJob('weekly'), isFalse);
      expect(failingStore.values, isEmpty);
    });

    test('S01 an upsert over an existing id parks the tool body as a replacement', () async {
      applied(await mutations.createJob({...body(), 'name': 'weekly', 'delivery': 'webhook'}..remove('id')));
      await mutations.updateJob('weekly', {'webhook_url': 'https://example.test/hook'});
      final before = configText();

      final outcome = await parking.upsertJob(body(schedule: '0 18 * * 1'), requester: 'schedule_upsert');

      expect(outcome.created, isFalse);
      expect(configText(), before);
      final change = store.values.single;
      expect(change.kind, PendingChangeKind.replaced);
      // The body as the tool supplied it: the merge over the stored entry
      // happens at commit, so the record is not an authority over keys the
      // model never named.
      expect(change.job, body(schedule: '0 18 * * 1'));
      expect(service.entries.singleWhere((entry) => entry.id == 'weekly').cronExpression, '0 9 * * 1');
    });

    test('S02 approving merges over the entry as it is now, so an operator edit made meanwhile survives', () async {
      applied(await mutations.createJob({...body(), 'name': 'weekly', 'delivery': 'webhook'}..remove('id')));
      final parked =
          (await parking.upsertJob(body(schedule: '0 18 * * 1'), requester: 'schedule_upsert')).result
              as ScheduleMutationParked;
      applied(await mutations.updateJob('weekly', {'enabled': false, 'webhook_url': 'https://example.test/hook'}));

      applied(await seam(store: store).approve(parked.changeId));

      final stored = (await writer.readSchedulingJobs()).single;
      expect(stored['schedule'], '0 18 * * 1');
      expect(stored['enabled'], isFalse);
      expect(stored['webhook_url'], 'https://example.test/hook');
    });

    test('S01 an upsert naming a file-only shell entry is refused, not parked', () async {
      writeConfig(
        '\n'
        '    - id: mail-feed\n'
        '      type: shell\n'
        '      schedule: "0 * * * *"\n'
        '      command:\n'
        '        - /usr/local/bin/hey\n'
        '      output: mail.json',
      );
      final before = configText();

      final refusal = refused((await parking.upsertJob(body(id: 'mail-feed'), requester: 'mcp-client:ops')).result);

      expect(refusal.status, 400);
      expect(refusal.code, 'INVALID_INPUT');
      expect(refusal.message, contains('Shell jobs are file-only'));
      expect(store.values, isEmpty, reason: 'a write that could never commit must not be parked');
      expect(configText(), before);
    });

    test('S02 an applier failure reports that the committed job was not loaded', () async {
      final parked = (await parking.upsertJob(body(), requester: 'mcp-client:ops')).result as ScheduleMutationParked;
      final settling = ScheduleMutationService(
        writer: writer,
        applyJobs: () async => throw StateError('applier down'),
        reservedJobIds: () => reserved,
        now: () => clock,
        pendingChanges: store,
      );

      final refusal = refused(await settling.approve(parked.changeId));

      expect(refusal.code, 'APPLY_FAILED');
      expect(refusal.message, contains('were written but could not be loaded'));
      // The file and the store agree: the job shipped, so nothing is pending
      // for a reject to claim it discarded.
      expect((await writer.readSchedulingJobs()).single['id'], 'weekly');
      expect(store.values, isEmpty);
    });

    test('a pending removal failure restores config and runtime and remains pending after restart', () async {
      var failRemoval = false;
      final storeFile = File(p.join(dataDir, 'pending-removal-failure.json'));
      final failingStore = PendingScheduleChangeStore(
        storeFile,
        writeJson: (target, value) async {
          if (failRemoval) throw const FileSystemException('injected pending removal failure');
          await atomicWriteJson(target, value);
        },
      );
      final parkingWithFailure = seam(store: failingStore, approval: ScheduleMutationApproval.operator);
      final parked =
          (await parkingWithFailure.upsertJob(body(), requester: 'mcp-client:ops')).result as ScheduleMutationParked;
      final before = configText();
      failRemoval = true;

      final refusal = refused(await seam(store: failingStore).approve(parked.changeId));

      expect(refusal.code, 'WRITE_FAILED');
      expect(refusal.message, contains('scheduling.jobs was restored'));
      expect(configText(), before);
      expect(service.hasJob('weekly'), isFalse);
      expect(failingStore.values.single.changeId, parked.changeId);
      final rebooted = PendingScheduleChangeStore(storeFile);
      await rebooted.load();
      expect(rebooted.values.single.changeId, parked.changeId);
      expect(await writer.readSchedulingJobs(), isEmpty);
    });

    test('a direct mutation waits for failed approval rollback, then applies against the restored list', () async {
      var failRemoval = false;
      final removalStarted = Completer<void>();
      final releaseRemoval = Completer<void>();
      final storeFile = File(p.join(dataDir, 'pending-concurrent-rollback.json'));
      final failingStore = PendingScheduleChangeStore(
        storeFile,
        writeJson: (target, value) async {
          if (failRemoval) {
            removalStarted.complete();
            await releaseRemoval.future;
            throw const FileSystemException('injected pending removal failure');
          }
          await atomicWriteJson(target, value);
        },
      );
      final parkingWithFailure = seam(store: failingStore, approval: ScheduleMutationApproval.operator);
      final parked =
          (await parkingWithFailure.upsertJob(body(), requester: 'mcp-client:ops')).result as ScheduleMutationParked;
      failRemoval = true;

      final approval = seam(store: failingStore).approve(parked.changeId);
      await removalStarted.future;
      var directCompleted = false;
      final direct = mutations
          .createJob({'name': 'digest', 'schedule': '0 6 * * *', 'prompt': 'Run digest', 'delivery': 'none'})
          .then((result) {
            directCompleted = true;
            return result;
          });
      await pumpEventQueue();

      expect(directCompleted, isFalse, reason: 'the config mutation must wait until approval compensation finishes');
      releaseRemoval.complete();
      expect(refused(await approval).code, 'WRITE_FAILED');
      expect(await direct, isA<ScheduleMutationApplied>());
      expect((await writer.readSchedulingJobs()).map((job) => job['name'] ?? job['id']), ['digest']);
      expect(service.hasJob('digest'), isTrue);
      expect(service.hasJob('weekly'), isFalse);
      expect(failingStore.values.single.changeId, parked.changeId);
    });

    test('failed approval rollback preserves a direct mutation that completed first', () async {
      final direct = await mutations.createJob({
        'name': 'digest',
        'schedule': '0 6 * * *',
        'prompt': 'Run digest',
        'delivery': 'none',
      });
      expect(direct, isA<ScheduleMutationApplied>());
      var failRemoval = false;
      final storeFile = File(p.join(dataDir, 'pending-after-direct.json'));
      final failingStore = PendingScheduleChangeStore(
        storeFile,
        writeJson: (target, value) async {
          if (failRemoval) throw const FileSystemException('injected pending removal failure');
          await atomicWriteJson(target, value);
        },
      );
      final parkingWithFailure = seam(store: failingStore, approval: ScheduleMutationApproval.operator);
      final parked =
          (await parkingWithFailure.upsertJob(body(), requester: 'mcp-client:ops')).result as ScheduleMutationParked;
      failRemoval = true;

      expect(refused(await seam(store: failingStore).approve(parked.changeId)).code, 'WRITE_FAILED');

      expect((await writer.readSchedulingJobs()).map((job) => job['name'] ?? job['id']), ['digest']);
      expect(service.hasJob('digest'), isTrue);
      expect(service.hasJob('weekly'), isFalse);
      expect(failingStore.values.single.changeId, parked.changeId);
    });

    test('a failed rollback is surfaced and runtime reloads the YAML that remains', () async {
      var failRemoval = false;
      final storeFile = File(p.join(dataDir, 'pending-rollback-failure.json'));
      final failingStore = PendingScheduleChangeStore(
        storeFile,
        writeJson: (target, value) async {
          if (failRemoval) {
            File(configPath).deleteSync();
            throw const FileSystemException('injected pending removal failure');
          }
          await atomicWriteJson(target, value);
        },
      );
      final parkingWithFailure = seam(store: failingStore, approval: ScheduleMutationApproval.operator);
      final parked =
          (await parkingWithFailure.upsertJob(body(), requester: 'mcp-client:ops')).result as ScheduleMutationParked;
      failRemoval = true;

      final refusal = refused(await seam(store: failingStore).approve(parked.changeId));

      expect(refusal.code, 'SETTLEMENT_FAILED');
      expect(refusal.message, allOf(contains('pending removal failed'), contains('config rollback failed')));
      expect(service.hasJob('weekly'), isFalse, reason: 'the recovery reload reflects the now-absent config');
      expect(failingStore.values.single.changeId, parked.changeId);
    });

    test('approve and reject settle exactly once in either ordering', () async {
      for (final approveFirst in const [true, false]) {
        writeConfig(' []');
        service.replaceConfigJobs(const []);
        final removalStarted = Completer<void>();
        final releaseRemoval = Completer<void>();
        var writes = 0;
        final raceFile = File(p.join(dataDir, 'pending-race-$approveFirst.json'));
        final raceStore = PendingScheduleChangeStore(
          raceFile,
          writeJson: (target, value) async {
            writes++;
            if (writes == 2) {
              removalStarted.complete();
              await releaseRemoval.future;
            }
            await atomicWriteJson(target, value);
          },
        );
        final raceParking = seam(store: raceStore, approval: ScheduleMutationApproval.operator);
        final parked =
            (await raceParking.upsertJob(body(), requester: 'mcp-client:ops')).result as ScheduleMutationParked;
        final settling = seam(store: raceStore);

        final first = approveFirst ? settling.approve(parked.changeId) : settling.reject(parked.changeId);
        await removalStarted.future;
        final second = approveFirst ? settling.reject(parked.changeId) : settling.approve(parked.changeId);
        await pumpEventQueue();
        releaseRemoval.complete();
        final results = await Future.wait([first, second]);

        expect(results.whereType<ScheduleMutationApplied>(), hasLength(1));
        expect(results.whereType<ScheduleMutationRefused>().single.refusal.code, 'NOT_FOUND');
        expect(raceStore.values, isEmpty);
        expect(service.hasJob('weekly'), approveFirst);
      }
    });

    test('S02 approve writes the parked body and the running scheduler holds the job', () async {
      final parked = (await parking.upsertJob(body(), requester: 'mcp-client:ops')).result as ScheduleMutationParked;
      final settling = seam(store: store);

      final result = await settling.approve(parked.changeId);

      expect(applied(result)['id'], 'weekly');
      expect((await writer.readSchedulingJobs()).single, body());
      expect(service.hasJob('weekly'), isTrue);
      expect(store.values, isEmpty);
      expect(restartMarkerWritten(), isFalse);
    });

    test('S03 reject drops the change and touches neither the YAML nor the scheduler', () async {
      final before = configText();
      final loadedBefore = service.entries.map((entry) => entry.id).toList();
      final parked = (await parking.upsertJob(body(), requester: 'mcp-client:ops')).result as ScheduleMutationParked;

      final result = await seam(store: store).reject(parked.changeId);

      expect(result, isA<ScheduleMutationApplied>());
      expect(configText(), before);
      expect(service.entries.map((entry) => entry.id), loadedBefore);
      expect(store.values, isEmpty);
    });

    test('S06 a parked one-time instant that has since passed is refused and stays pending', () async {
      final at = clock.add(const Duration(minutes: 10)).toIso8601String();
      final parked =
          (await parking.upsertJob(body(schedule: {'type': 'once', 'at': at}), requester: 'mcp-client:ops')).result
              as ScheduleMutationParked;
      final before = configText();
      clock = clock.add(const Duration(minutes: 20));

      final refusal = refused(await seam(store: store).approve(parked.changeId));

      expect(refusal.status, 400);
      expect(refusal.code, 'INVALID_INPUT');
      // The same sentence resolveSchedule answers with: one future-instant rule.
      expect(refusal.message, '"at" must be later than now: "$at"');
      expect(configText(), before);
      expect(service.hasJob('weekly'), isFalse);
      expect(store.values.single.changeId, parked.changeId);
    });

    test('S06 a parked id that has since become a built-in is refused and stays pending', () async {
      final parked = (await parking.upsertJob(body(), requester: 'mcp-client:ops')).result as ScheduleMutationParked;
      final before = configText();
      reserved.add('weekly');

      final refusal = refused(await seam(store: store).approve(parked.changeId));

      expect(refusal.status, 409);
      expect(refusal.code, 'CONFLICT');
      expect(refusal.message, contains('built-in'));
      expect(configText(), before);
      expect(service.hasJob('weekly'), isFalse);
      expect(store.values.single.changeId, parked.changeId);
    });

    test('S06 a changeId naming no stored change is refused with nothing written', () async {
      final before = configText();
      final settling = seam(store: store);

      final approve = refused(await settling.approve('no-such-change'));
      final reject = refused(await settling.reject('no-such-change'));

      for (final refusal in [approve, reject]) {
        expect(refusal.status, 404);
        expect(refusal.code, 'NOT_FOUND');
        expect(refusal.message, 'Pending change "no-such-change" not found');
      }
      expect(configText(), before);
    });

    test('S07 under none the same upsert commits and applies, and nothing is parked', () async {
      final outcome = await seam(store: store).upsertJob(body(), requester: 'schedule_upsert');

      expect(applied(outcome.result)['id'], 'weekly');
      expect(outcome.created, isTrue);
      expect(service.hasJob('weekly'), isTrue);
      expect((await writer.readSchedulingJobs()).single['prompt'], 'Summarize the week');
      expect(store.values, isEmpty);
    });

    test('S07 a built-in id is refused by upsertJob under either mode with nothing parked', () async {
      final before = configText();

      for (final seamUnderTest in [parking, seam(store: store)]) {
        final refusal = refused((await seamUnderTest.upsertJob(body(id: 'heartbeat'), requester: 'x')).result);
        expect(refusal.status, 409);
        expect(refusal.message, contains('built-in'));
      }
      expect(configText(), before);
      expect(store.values, isEmpty);
    });

    test('SC01 operator mode without a store is a construction error, not a silent commit', () {
      expect(
        () => ScheduleMutationService(writer: writer, approval: ScheduleMutationApproval.operator),
        throwsArgumentError,
      );
    });

    group('a parked change survives a restart', () {
      File storeFile() => File(p.join(dataDir, 'pending-schedule-changes.json'));

      test('a second store over the same file loads the same record and approving through it writes the job', () async {
        final parked = (await parking.upsertJob(body(), requester: 'mcp-client:ops')).result as ScheduleMutationParked;

        final rebooted = PendingScheduleChangeStore(storeFile());
        await rebooted.load();

        final change = rebooted.values.single;
        expect(change.changeId, parked.changeId);
        expect(change.job, body());
        expect(change.requester, 'mcp-client:ops');
        expect(change.requestedAt, clock.toUtc());
        expect(change.kind, PendingChangeKind.created);

        applied(await seam(store: rebooted).approve(parked.changeId));
        expect((await writer.readSchedulingJobs()).single, body());
        expect(service.hasJob('weekly'), isTrue);
        expect(rebooted.values, isEmpty);
        expect(jsonDecode(storeFile().readAsStringSync()), isEmpty);
      });

      List<String> captureWarnings() {
        final warnings = <String>[];
        final subscription = Logger.root.onRecord
            .where((record) => record.loggerName == 'PendingScheduleChangeStore' && record.level >= Level.WARNING)
            .listen((record) => warnings.add(record.message));
        addTearDown(subscription.cancel);
        return warnings;
      }

      Map<String, dynamic> soundEntry() => PendingScheduleChange(
        changeId: 'sound',
        jobId: 'weekly',
        kind: PendingChangeKind.created,
        job: body(),
        requester: 'mcp-client:ops',
        requestedAt: clock.toUtc(),
      ).toJson();

      test('a malformed entry beside a sound one is skipped with a warning naming it', () async {
        storeFile().writeAsStringSync(
          jsonEncode([
            soundEntry(),
            {...soundEntry(), 'changeId': 'unknown-kind', 'kind': 'teleported'},
            {...soundEntry(), 'changeId': 'no-job-id', 'job': body()..remove('id')},
            {...soundEntry(), 'changeId': 'mismatched-id', 'jobId': 'other'},
            {...soundEntry(), 'changeId': 'missing-type', 'job': body()..remove('type')},
            {
              ...soundEntry(),
              'changeId': 'unknown-type',
              'job': {...body(), 'type': 'shell'},
            },
          ]),
        );
        final warnings = captureWarnings();

        final loaded = PendingScheduleChangeStore(storeFile());
        await loaded.load();

        expect(loaded.values.map((change) => change.changeId), ['sound']);
        expect(warnings, hasLength(5));
        expect(
          warnings[0],
          allOf(startsWith('Skipping malformed pending schedule change entry'), contains('unknown-kind')),
        );
        expect(
          warnings[1],
          allOf(startsWith('Skipping malformed pending schedule change entry'), contains('no-job-id')),
        );
        expect(
          warnings.skip(2).join('\n'),
          allOf(contains('mismatched-id'), contains('missing-type'), contains('unknown-type')),
        );
      });

      test('an unreadable file loads empty and warns', () async {
        storeFile().writeAsStringSync('not json at all');
        final warnings = captureWarnings();

        final loaded = PendingScheduleChangeStore(storeFile());
        await loaded.load();

        expect(loaded.values, isEmpty);
        expect(warnings.single, startsWith('Failed to load pending schedule changes — starting empty'));
      });

      test('a file that is not a JSON array loads empty and warns', () async {
        storeFile().writeAsStringSync(jsonEncode(soundEntry()));
        final warnings = captureWarnings();

        final loaded = PendingScheduleChangeStore(storeFile());
        await loaded.load();

        expect(loaded.values, isEmpty);
        expect(warnings.single, 'Pending schedule changes file is not a JSON array — starting empty');
      });
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
