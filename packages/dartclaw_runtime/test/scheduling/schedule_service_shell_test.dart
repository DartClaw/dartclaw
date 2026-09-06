import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'schedule_service_fixtures.dart';

/// The child every scenario spawns.
///
/// A temp Dart script run through [Platform.resolvedExecutable] rather than
/// `/bin/sh`, so the suite behaves identically on Linux CI and macOS.
const _childSource = r'''
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  switch (args.first) {
    case 'env':
      stdout.write(jsonEncode(Platform.environment));
    case 'echo':
      stdout.write(args[1]);
    case 'fail':
      stderr.write('boom\n  spread   over\nthree lines');
      exit(3);
    case 'empty':
      break;
    case 'sleep':
      sleep(Duration(seconds: args.length > 1 ? int.parse(args[1]) : 30));
    case 'invalid-utf8':
      stdout.add([0xC3, 0x28]);
    case 'over-cap':
      // One byte past the 16 MiB ceiling, in 1 MiB chunks.
      final chunk = List<int>.filled(1024 * 1024, 0x61);
      for (var i = 0; i < 16; i++) {
        stdout.add(chunk);
      }
      stdout.add([0x61]);
    case 'hold-stdout':
      // Exit at once while a grandchild that inherited our pipes keeps them
      // open — the shape a forking feed command produces.
      stdout.write('partial');
      Process.start(Platform.resolvedExecutable, [Platform.script.toFilePath(), 'sleep', '12'],
          mode: ProcessStartMode.inheritStdio);
  }
}
''';

/// Whether [name] is one the minimal env policy admits from the parent.
bool _allowlisted(String name) => defaultBashStepEnvAllowlist.any(
  (allowed) => allowed.endsWith('*') ? name.startsWith(allowed.substring(0, allowed.length - 1)) : name == allowed,
);

void main() {
  late Directory dataDir;
  late String script;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('dartclaw-shell-job-');
    script = p.join(dataDir.path, 'child.dart');
    await File(script).writeAsString(_childSource);
  });

  tearDown(() async {
    if (await dataDir.exists()) await dataDir.delete(recursive: true);
  });

  Map<String, dynamic> entry({
    String id = 'mail-feed',
    required List<String> args,
    Map<String, String> env = const {'FEED_TOKEN': 'feed-secret'},
    String output = 'mail.json',
    int? timeoutSeconds,
    int retryAttempts = 0,
  }) => <String, dynamic>{
    'id': id,
    'type': 'shell',
    'schedule': '0 * * * *',
    'command': [Platform.resolvedExecutable, script, ...args],
    'env': env,
    'output': output,
    'timeout_seconds': ?timeoutSeconds,
    'retry': {'attempts': retryAttempts, 'delay_seconds': 0},
  };

  const credentials = CredentialsConfig(entries: {'feed-secret': CredentialEntry(apiKey: 'sk-feed-live')});

  List<ScheduledJob> compose(List<Map<String, dynamic>> entries) => composeConfigJobs(
    SchedulingConfig(jobs: entries),
    taskService: TaskService(InMemoryTaskRepository()),
    credentials: credentials,
    dataDir: dataDir.path,
  ).jobs;

  ({ScheduleService service, List<ScheduledJobFailedEvent> failures, EventBus bus}) serviceFor(
    List<ScheduledJob> jobs,
  ) {
    final bus = EventBus();
    final failures = <ScheduledJobFailedEvent>[];
    final subscription = bus.on<ScheduledJobFailedEvent>().listen(failures.add);
    addTearDown(() async {
      await subscription.cancel();
      await bus.dispose();
    });
    final service = ScheduleService(
      turns: ConfigurableTurnManager(),
      sessions: FakeSessionService(),
      jobs: jobs,
      eventBus: bus,
      timerFactory: ManualTimer.new,
    );
    addTearDown(service.stop);
    return (service: service, failures: failures, bus: bus);
  }

  File feedFile([String name = 'mail.json']) => File(p.join(dataDir.path, 'feeds', name));

  /// Drives one fire of [id] to settlement — retries included — and returns
  /// only once `ScheduleService` has released the job.
  ///
  /// Through `executeJobForTesting`, not `runJobNow`: the on-demand entry point
  /// answers `started` whenever the job is idle, so polling it to detect
  /// settlement would start a second fire that races every assertion after it.
  /// The returned future completing *is* the proof the job was released — a
  /// fire that never settles fails here on the suite timeout.
  Future<void> runToCompletion(ScheduleService service, String id) =>
      service.executeJobForTesting(service.jobsForTesting.firstWhere((job) => job.id == id));

  group('ScheduleService shell job execution', () {
    test('writes stdout to the feed file with the injected credential visible', () async {
      final logged = <String>[];
      final subscription = Logger.root.onRecord
          .where((record) => record.loggerName == 'ScheduleService')
          .listen((record) => logged.add(record.message));
      addTearDown(subscription.cancel);

      final service = serviceFor(
        compose([
          entry(args: ['env']),
        ]),
      ).service;
      service.start();
      expect(service.runJobNow('mail-feed'), RunScheduledJobResult.started);
      // Settled by the one result line a completed fire logs — never by polling
      // `runJobNow`, which would start a second fire the moment the first ends.
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!logged.any((message) => message.contains('result'))) {
        if (DateTime.now().isAfter(deadline)) fail('the on-demand fire never completed');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final childEnv = (jsonDecode(await feedFile().readAsString()) as Map).cast<String, dynamic>();
      expect(childEnv['FEED_TOKEN'], 'sk-feed-live');

      // The parent's own environment reaches the child only through the minimal
      // allowlist. `__CF*` is excluded because macOS re-adds it to every child
      // whatever environment map the spawn passes — it is the platform's, not
      // this policy's.
      final inherited = childEnv.keys.where(
        (name) => name != 'FEED_TOKEN' && !name.startsWith('__CF') && Platform.environment.containsKey(name),
      );
      expect(inherited, everyElement(predicate<String>(_allowlisted)), reason: 'inherited beyond the allowlist');
      // Non-vacuous: the process running this suite carries names the child
      // must not see, and the assertion above is what keeps them out.
      expect(
        Platform.environment.keys.where((name) => !name.startsWith('__CF') && !_allowlisted(name)),
        isNotEmpty,
        reason: 'this environment cannot prove the strip — no non-allowlisted parent variable to withhold',
      );
      // And the sensitive names in particular: an injected `*_TOKEN` survives
      // only because the overlay runs after the strip, never the parent's.
      final parentSensitive = Platform.environment.keys.where(
        (name) => defaultSensitivePatterns.any((pattern) => pattern is RegExp && pattern.hasMatch(name)),
      );
      expect(childEnv.keys, isNot(anyElement(isIn(parentSensitive))));

      final result = logged.singleWhere((message) => message.contains('result'));
      expect(result, contains('wrote ${await feedFile().length()} bytes to feeds/mail.json (exit 0)'));
      // The summary reports the size and the exit code, never the document.
      expect(result, isNot(contains('sk-feed-live')));
      expect(result, isNot(contains('PATH')));
    });

    test('a failed run leaves the previous feed file intact and alerts', () async {
      await feedFile().parent.create(recursive: true);
      await feedFile().writeAsString('{"from":"the good run"}');

      for (final args in [
        ['fail'],
        ['empty'],
      ]) {
        final composed = serviceFor(compose([entry(args: args, retryAttempts: 1)]));
        composed.service.start();
        await runToCompletion(composed.service, 'mail-feed');

        expect(await feedFile().readAsString(), '{"from":"the good run"}', reason: 'args $args replaced the feed');
        expect(composed.failures, hasLength(1), reason: 'args $args raised no alert');
        expect(composed.failures.single.jobId, 'mail-feed');
        expect(
          composed.failures.single.error,
          contains(args.first == 'fail' ? 'exited 3' : 'exited 0 without writing to stdout'),
        );
        // The stderr tail travels as one line: a command's own output must not
        // be able to forge a second line in an operator-facing report.
        expect(composed.failures.single.error, isNot(contains('\n')));
        if (args.first == 'fail') expect(composed.failures.single.error, contains('boom spread over three lines'));
      }
    });

    test('terminates a command that outruns its timeout and fails the fire', () async {
      final composed = serviceFor(
        compose([
          entry(args: ['sleep'], timeoutSeconds: 1),
        ]),
      );
      composed.service.start();
      await runToCompletion(composed.service, 'mail-feed');

      expect(await feedFile().exists(), isFalse);
      expect(composed.failures, hasLength(1));
      expect(composed.failures.single.error, contains('exceeded its 1s timeout'));
    });

    test('stdout that is not valid UTF-8 fails the fire rather than being repaired', () async {
      final composed = serviceFor(
        compose([
          entry(args: ['invalid-utf8']),
        ]),
      );
      composed.service.start();
      await runToCompletion(composed.service, 'mail-feed');

      expect(await feedFile().exists(), isFalse);
      expect(composed.failures.single.error, contains('not valid UTF-8'));
    });

    test('stdout past the 16 MiB ceiling fails the fire and leaves the previous feed intact', () async {
      // The child arm hardcodes the ceiling; this pins the two together.
      expect(defaultProcessOutputLimitBytes, 16 * 1024 * 1024);
      await feedFile().parent.create(recursive: true);
      await feedFile().writeAsString('{"from":"the good run"}');

      final composed = serviceFor(
        compose([
          entry(args: ['over-cap']),
        ]),
      );
      composed.service.start();
      await runToCompletion(composed.service, 'mail-feed');

      expect(await feedFile().readAsString(), '{"from":"the good run"}');
      expect(composed.failures.single.error, contains('wrote more than $defaultProcessOutputLimitBytes bytes'));
    });

    test('a command whose grandchild holds the output pipe open fails on a bound and does not wedge the job', () async {
      // Two bounds cover this, and which one fires is the platform's business:
      // where `Process.exitCode` waits for the pipes, `timeout_seconds` ends
      // the wait and the kill path's drain grace bounds the rest; where it
      // completes at the command's own exit, the drain grace alone does.
      final composed = serviceFor(
        compose([
          entry(args: ['hold-stdout'], timeoutSeconds: 1),
        ]),
      );
      composed.service.start();
      final started = DateTime.now();
      await runToCompletion(composed.service, 'mail-feed');

      // Well inside the grandchild's 12 s hold, so a bound ended the wait, not
      // the grandchild letting go.
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 10)));
      expect(await feedFile().exists(), isFalse);
      expect(
        composed.failures.single.error,
        anyOf(contains('exceeded its 1s timeout'), contains('left its output open')),
      );
      // `runToCompletion` returning is the release proof: a wedged fire never
      // settles, and this test fails on the bound above instead.
    });

    test('the feed file is owner-only and replaced whole on a later good run', () async {
      final composed = serviceFor(
        compose([
          entry(args: ['echo', '{"v":1}']),
        ]),
      );
      composed.service.start();
      await runToCompletion(composed.service, 'mail-feed');
      expect(await feedFile().readAsString(), '{"v":1}');
      if (!Platform.isWindows) {
        expect((feedFile().statSync().mode & 0x1ff).toRadixString(8), '600');
      }

      final second = serviceFor(
        compose([
          entry(args: ['echo', '{"v":2}']),
        ]),
      );
      second.service.start();
      await runToCompletion(second.service, 'mail-feed');
      expect(await feedFile().readAsString(), '{"v":2}');
    });

    test('a nested output path is created under feeds/', () async {
      final composed = serviceFor(
        compose([
          entry(args: ['echo', 'ok'], output: 'mail/inbox.json'),
        ]),
      );
      composed.service.start();
      await runToCompletion(composed.service, 'mail-feed');

      expect(await feedFile('mail/inbox.json').readAsString(), 'ok');
    });
  });

  group('ScheduleService shell job live application', () {
    test('a changed command re-arms the job and an unchanged list leaves it armed', () {
      final service = serviceFor(
        compose([
          entry(args: ['echo', 'one']),
        ]),
      ).service;
      service.start();
      final armed = service.jobsForTesting.single;

      service.replaceConfigJobs(
        compose([
          entry(args: ['echo', 'one']),
        ]),
      );
      expect(identical(service.jobsForTesting.single, armed), isTrue, reason: 'an untouched entry was re-armed');

      service.replaceConfigJobs(
        compose([
          entry(args: ['echo', 'two']),
        ]),
      );
      expect(identical(service.jobsForTesting.single, armed), isFalse, reason: 'a changed command did not re-arm');

      // Every field of the definition is compared, not just the command.
      for (final change in <Map<String, Object>>[
        {'env': const <String, String>{}},
        {'output': 'other.json'},
        {'timeoutSeconds': 45},
      ]) {
        final current = service.jobsForTesting.single;
        service.replaceConfigJobs(
          compose([
            entry(
              args: const ['echo', 'two'],
              env: (change['env'] as Map<String, String>?) ?? const {'FEED_TOKEN': 'feed-secret'},
              output: change['output'] as String? ?? 'mail.json',
              timeoutSeconds: change['timeoutSeconds'] as int?,
            ),
          ]),
        );
        expect(identical(service.jobsForTesting.single, current), isFalse, reason: 'change $change did not re-arm');
      }
    });

    test('runJobNow starts a shell job but still refuses a built-in callback job', () {
      final service = serviceFor([
        ...compose([
          entry(args: ['echo', 'ok']),
        ]),
        builtInJob('git-sync'),
      ]).service;
      service.start();

      expect(service.runJobNow('mail-feed'), RunScheduledJobResult.started);
      expect(service.runJobNow('git-sync'), RunScheduledJobResult.notFound);
      expect(service.runJobNow('absent'), RunScheduledJobResult.notFound);
    });

    test('an auto-task callback job stays refused on demand', () {
      final autoTask = ScheduledTaskRunner(
        taskService: TaskService(InMemoryTaskRepository()),
        definitions: [
          ScheduledTaskDefinition(
            id: 'nightly',
            cronExpression: '0 2 * * *',
            enabled: true,
            title: 'Nightly',
            description: 'Sweep',
          ),
        ],
      ).buildJobs().single;
      final service = serviceFor([autoTask]).service;
      service.start();

      expect(service.runJobNow(autoTask.id), RunScheduledJobResult.notFound);
    });
  });
}
