import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../guard_audit_test_support.dart';

Future<Map<String, dynamic>> _call(
  McpProtocolHandler handler,
  String name, [
  Map<String, dynamic> arguments = const {},
]) async {
  final raw = await handler.handleRequest(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }),
  );
  return jsonDecode(raw!) as Map<String, dynamic>;
}

Map<String, dynamic> _result(Map<String, dynamic> response) {
  expect(response['error'], isNull, reason: 'a tool refusal must be a JSON-RPC success carrying isError');
  return response['result'] as Map<String, dynamic>;
}

String _text(Map<String, dynamic> result) =>
    ((result['content'] as List).single as Map<String, dynamic>)['text'] as String;

Map<String, dynamic> _payload(Map<String, dynamic> result) => jsonDecode(_text(result)) as Map<String, dynamic>;

void main() {
  late Directory tempDir;
  late String configPath;
  late String dataDir;
  late ConfigWriter writer;
  late ScheduleMutationService mutations;
  late RecordingGuardAuditLogger audit;

  /// Writes `scheduling.jobs` as the given prompt-job rows.
  void writeJobsToYaml(List<({String name, String schedule})> jobs) {
    final rows = jobs
        .map(
          (job) =>
              '  - name: ${job.name}\n'
              '    schedule: "${job.schedule}"\n'
              '    prompt: "run ${job.name}"\n'
              '    delivery: webhook\n'
              '    webhook_url: "https://example.test/${job.name}"\n'
              '    enabled: false',
        )
        .join('\n');
    File(configPath).writeAsStringSync('''
port: 3000
host: localhost
scheduling:
  jobs:${rows.isEmpty ? ' []' : '\n$rows'}
''');
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_schedule_tools_');
    configPath = p.join(tempDir.path, 'dartclaw.yaml');
    dataDir = p.join(tempDir.path, 'data');
    Directory(dataDir).createSync();
    writeJobsToYaml(const []);
    writer = ConfigWriter(configPath: configPath);
    mutations = ScheduleMutationService(writer: writer, dataDir: dataDir);
    audit = RecordingGuardAuditLogger();
  });

  tearDown(() async {
    await writer.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Registers the two real tools on the real dispatch seam.
  ///
  /// Guard evaluation and audit come from [McpProtocolHandler]; nothing in the
  /// tools participates, which is what the negative controls prove.
  McpProtocolHandler handlerWith({GuardChain? chain, GuardAuditLogger? sink, ScheduleService? schedules}) =>
      McpProtocolHandler(guardChain: chain, auditLogger: sink)
        ..registerTool(ScheduleUpsertTool(mutations: mutations))
        ..registerTool(ScheduleListTool(mutations: mutations, schedules: schedules));

  McpProtocolHandler passingHandler({ScheduleService? schedules}) => handlerWith(
    chain: GuardChain(guards: [FakeGuard.pass()]),
    sink: audit,
    schedules: schedules,
  );

  String configText() => File(configPath).readAsStringSync();

  List<(String, String)> auditRows() => [for (final entry in audit.entries) (entry.tool ?? '', entry.decision ?? '')];

  group('S05 schedule_upsert writes through the shared seam and reports the restart requirement', () {
    test('a valid upsert writes the job and its result states that it is not running yet', () async {
      writeJobsToYaml(const [(name: 'digest', schedule: '0 6 * * *')]);
      final handler = passingHandler();

      final payload = _payload(
        _result(
          await _call(handler, 'schedule_upsert', {
            'id': 'weekly',
            'schedule': '0 9 * * 1',
            'type': 'prompt',
            'prompt': 'Summarize the week',
            'delivery': 'announce',
          }),
        ),
      );

      expect(payload['id'], 'weekly');
      expect(payload['created'], isTrue);
      expect(payload['pending_restart'], isTrue);
      // The owner acts on this sentence; a result reading as "scheduled" is a lie.
      expect(payload['note'], contains('does not run until the server restarts'));

      // The sibling it was written beside survives, and the new job is on disk.
      final stored = await mutations.readJobs();
      expect(stored.map((job) => job['id'] ?? job['name']), ['digest', 'weekly']);
      expect(stored.last['schedule'], '0 9 * * 1');
      expect(stored.last['prompt'], 'Summarize the week');
      expect(stored.last['delivery'], 'announce');
      // The sibling it was written beside is untouched, keys and all.
      expect(stored.first['webhook_url'], 'https://example.test/digest');

      // The restart marker the config API records is recorded here too.
      expect(readRestartPending(dataDir)?['fields'], contains('scheduling.jobs'));
      expect(auditRows(), [('schedule_upsert', 'allow')]);
    });

    test('upserting an existing id replaces that job rather than appending a duplicate', () async {
      writeJobsToYaml(const [(name: 'digest', schedule: '0 6 * * *')]);
      final handler = passingHandler();

      final payload = _payload(
        _result(
          await _call(handler, 'schedule_upsert', {
            'id': 'digest',
            'schedule': '30 7 * * *',
            'type': 'prompt',
            'prompt': 'Revised digest',
          }),
        ),
      );

      expect(payload['created'], isFalse);
      final stored = await mutations.readJobs();
      expect(stored, hasLength(1));
      expect(stored.single['schedule'], '30 7 * * *');
      expect(stored.single['prompt'], 'Revised digest');
      // Merged, not replaced: every operator-set key this tool cannot express
      // survives, exactly as it does through PUT /api/scheduling/jobs/<name>.
      expect(stored.single['webhook_url'], 'https://example.test/digest');
      expect(
        stored.single['delivery'],
        'webhook',
        reason: 'an omitted delivery must not be defaulted over a stored one',
      );
      expect(stored.single['enabled'], isFalse);
    });

    test('a type: task job with an unusable task payload is refused with the job route\'s own message', () async {
      final before = configText();

      for (final testCase in <({Object? task, String message})>[
        (task: <String, dynamic>{}, message: '"task.title" is required'),
        (task: {'title': 'T'}, message: '"task.description" is required'),
      ]) {
        final result = _result(
          await _call(passingHandler(), 'schedule_upsert', {
            'id': 'nightly',
            'schedule': '0 2 * * *',
            'type': 'task',
            'task': testCase.task,
          }),
        );
        expect(result['isError'], isTrue, reason: '${testCase.task}');
        expect(_payload(result)['reason'], 'invalid_request');
        // Byte-identical to POST /api/scheduling/jobs: one shape authority.
        expect(_payload(result)['message'], testCase.message);
      }
      expect(configText(), before);
    });

    test('a written task job is loadable by the parser the next boot uses', () async {
      final written = _result(
        await _call(passingHandler(), 'schedule_upsert', {
          'id': 'nightly',
          'schedule': '0 2 * * *',
          'type': 'task',
          'task': {'title': 'Nightly sweep', 'description': 'Sweep the inbox'},
        }),
      );
      expect(written['isError'], isNull, reason: _text(written));

      // A job the tool reports as written must survive `ScheduledJob.fromConfig`,
      // or the success text describes a job the next start silently drops.
      final stored = (await mutations.readJobs()).firstWhere((job) => job['id'] == 'nightly');
      final parsed = ScheduledJob.fromConfig(stored);
      expect(parsed.id, 'nightly');
      expect(parsed.jobType, ScheduledJobType.task);
      expect(parsed.taskDefinition, isNotNull);
    });

    test('retired task categories are refused with declaration guidance', () async {
      for (final testCase in const [
        (value: 'research', otherKey: 'type', otherValue: 'analysis', declaration: 'securityProfile'),
        (value: 'coding', otherKey: 'task_type', otherValue: 'writing', declaration: 'needsWorktree'),
      ]) {
        final result = _result(
          await _call(passingHandler(), 'schedule_upsert', {
            'id': 'legacy-${testCase.value}',
            'schedule': '0 2 * * *',
            'type': 'task',
            'task': {
              'title': 'Legacy task',
              'description': 'Old configuration',
              testCase.otherKey: testCase.otherValue,
              (testCase.otherKey == 'type' ? 'task_type' : 'type'): testCase.value,
            },
          }),
        );

        expect(result['isError'], isTrue);
        expect(_payload(result)['message'], contains(testCase.declaration));
      }
    });

    test('an argument belonging to the other type fails the call rather than being dropped', () async {
      final before = configText();

      for (final testCase in <({Map<String, dynamic> arguments, String message})>[
        (
          arguments: {
            'id': 'nightly',
            'schedule': '0 2 * * *',
            'type': 'task',
            'task': {'title': 'T', 'description': 'D'},
            'delivery': 'announce',
          },
          message: 'delivery is only valid when type is prompt',
        ),
        (
          arguments: {
            'id': 'nightly',
            'schedule': '0 2 * * *',
            'type': 'task',
            'task': {'title': 'T', 'description': 'D'},
            'prompt': 'stray',
          },
          message: 'prompt is only valid when type is prompt',
        ),
        (
          arguments: {
            'id': 'weekly',
            'schedule': '0 9 * * 1',
            'type': 'prompt',
            'prompt': 'Summarize',
            'task': {'title': 'T'},
          },
          message: 'task is only valid when type is task',
        ),
      ]) {
        final result = _result(await _call(passingHandler(), 'schedule_upsert', testCase.arguments));
        expect(result['isError'], isTrue, reason: testCase.message);
        expect(_payload(result)['message'], testCase.message);
      }
      expect(configText(), before);
    });

    test('an invalid cron expression is refused with nothing written', () async {
      writeJobsToYaml(const [(name: 'digest', schedule: '0 6 * * *')]);
      final before = configText();
      final handler = passingHandler();

      final result = _result(
        await _call(handler, 'schedule_upsert', {
          'id': 'weekly',
          'schedule': 'not a cron',
          'type': 'prompt',
          'prompt': 'Summarize the week',
        }),
      );

      expect(result['isError'], isTrue);
      final payload = _payload(result);
      expect(payload['reason'], 'invalid_cron');
      // The same message the HTTP surface answers with — one cron authority.
      expect(payload['message'], 'Invalid cron expression: "not a cron"');
      expect(configText(), before, reason: 'a refused upsert must leave the config byte-identical');
      expect(readRestartPending(dataDir), isNull);
    });

    test('a prompt job written with no prompt is refused with nothing written', () async {
      writeJobsToYaml(const [(name: 'digest', schedule: '0 6 * * *')]);
      final before = configText();
      final handler = passingHandler();

      final result = _result(
        await _call(handler, 'schedule_upsert', {'id': 'weekly', 'schedule': '0 9 * * 1', 'type': 'prompt'}),
      );

      expect(result['isError'], isTrue);
      expect(_payload(result)['reason'], 'invalid_request');
      expect(_payload(result)['message'], 'prompt is required when type is prompt');
      expect(configText(), before);
      expect(readRestartPending(dataDir), isNull);
    });

    test('a task job written with no task payload is refused with nothing written', () async {
      final before = configText();
      final handler = passingHandler();

      final result = _result(
        await _call(handler, 'schedule_upsert', {'id': 'nightly', 'schedule': '0 2 * * *', 'type': 'task'}),
      );

      expect(result['isError'], isTrue);
      expect(_payload(result)['message'], '"task" object is required for type: task');
      expect(configText(), before);
    });
  });

  group('S06 schedule_list joins what is running with what is configured', () {
    test('a loaded job, a config-only job and a built-in are each listed correctly', () async {
      // `digest` is both configured and loaded; `built-in-sweep` is loaded only
      // (the runtime registers it itself); `weekly` was written to config after
      // startup, so the running service never saw it.
      final service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: InMemorySessionService(),
        jobs: [
          ScheduledJob.fromConfig(const {
            'id': 'digest',
            'prompt': 'run digest',
            'schedule': '0 6 * * *',
            'delivery': 'none',
          }),
          ScheduledJob.fromConfig(const {
            'id': 'built-in-sweep',
            'prompt': 'sweep',
            'schedule': '0 3 * * *',
            'delivery': 'none',
          }),
        ],
      );
      addTearDown(service.stop);
      writeJobsToYaml(const [(name: 'digest', schedule: '0 6 * * *'), (name: 'weekly', schedule: '0 9 * * 1')]);

      final payload = _payload(_result(await _call(passingHandler(schedules: service), 'schedule_list')));
      final rows = {for (final row in (payload['jobs'] as List).cast<Map<String, dynamic>>()) row['id'] as String: row};

      expect(rows.keys.toSet(), {'digest', 'weekly', 'built-in-sweep'});

      expect(rows['digest']!['schedule'], '0 6 * * *');
      expect(rows['digest']!['loaded'], isTrue);
      expect(rows['digest']!['editable'], isTrue);
      expect(rows['digest']!.containsKey('note'), isFalse);

      expect(rows['weekly']!['schedule'], '0 9 * * 1');
      expect(rows['weekly']!['loaded'], isFalse);
      expect(rows['weekly']!['editable'], isTrue);
      expect(rows['weekly']!['note'], contains('after the next server restart'));

      // A loaded job with no config entry carries its cron expression from the
      // running service and cannot be edited through schedule_upsert.
      expect(rows['built-in-sweep']!['schedule'], '0 3 * * *');
      expect(rows['built-in-sweep']!['source'], 'built-in');
      expect(rows['built-in-sweep']!['loaded'], isTrue);
      expect(rows['built-in-sweep']!['editable'], isFalse);
    });

    test('a paused loaded job reports as paused', () async {
      final service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: InMemorySessionService(),
        jobs: [
          ScheduledJob.fromConfig(const {
            'id': 'digest',
            'prompt': 'run digest',
            'schedule': '0 6 * * *',
            'delivery': 'none',
          }),
        ],
      )..pauseJob('digest');
      addTearDown(service.stop);
      writeJobsToYaml(const [(name: 'digest', schedule: '0 6 * * *')]);

      final payload = _payload(_result(await _call(passingHandler(schedules: service), 'schedule_list')));
      final row = (payload['jobs'] as List).cast<Map<String, dynamic>>().single;
      expect(row['id'], 'digest');
      expect(row['paused'], isTrue);
    });

    test('with no running scheduler every configured job reports as not loaded', () async {
      writeJobsToYaml(const [(name: 'digest', schedule: '0 6 * * *')]);

      final payload = _payload(_result(await _call(passingHandler(), 'schedule_list')));
      expect(payload['scheduler_running'], isFalse);
      final row = (payload['jobs'] as List).cast<Map<String, dynamic>>().single;
      expect(row['loaded'], isFalse);
      expect(row['note'], contains('after the next server restart'));
    });
  });

  group('the dispatch seam guards and audits both tools', () {
    test('a blocking guard refuses each tool without it running and writes one deny entry each', () async {
      writeJobsToYaml(const [(name: 'digest', schedule: '0 6 * * *')]);
      final before = configText();
      final handler = handlerWith(
        chain: GuardChain(guards: [FakeGuard.block('scheduling tools denied')]),
        sink: audit,
      );

      const upsertArguments = {'id': 'weekly', 'schedule': '0 9 * * 1', 'type': 'prompt', 'prompt': 'Summarize'};
      for (final (tool, arguments) in [
        ('schedule_upsert', upsertArguments),
        ('schedule_list', const <String, dynamic>{}),
      ]) {
        final result = _result(await _call(handler, tool, arguments));
        expect(result['isError'], isTrue, reason: '$tool must be refused');
        expect(_text(result), contains('scheduling tools denied'));
      }

      // The blocked upsert never reached the seam, so nothing was written.
      expect(configText(), before);
      expect(readRestartPending(dataDir), isNull);
      expect(auditRows(), [('schedule_upsert', 'deny'), ('schedule_list', 'deny')]);
    });
  });

  group('the declared argument contract is enforced for both tools', () {
    const cases = <({String tool, Map<String, dynamic> arguments, String message})>[
      (tool: 'schedule_upsert', arguments: {'schedule': '0 9 * * 1', 'type': 'prompt'}, message: 'id is required'),
      (tool: 'schedule_upsert', arguments: {'id': 'weekly', 'type': 'prompt'}, message: 'schedule is required'),
      (tool: 'schedule_upsert', arguments: {'id': 'weekly', 'schedule': '0 9 * * 1'}, message: 'type is required'),
      (
        tool: 'schedule_upsert',
        arguments: {'id': '  ', 'schedule': '0 9 * * 1', 'type': 'prompt'},
        message: 'id must be a non-empty string',
      ),
      (
        tool: 'schedule_upsert',
        arguments: {'id': 'weekly', 'schedule': '0 9 * * 1', 'type': 'reminder'},
        message: 'type must be one of: prompt, task',
      ),
      (
        tool: 'schedule_upsert',
        arguments: {'id': 'weekly', 'schedule': '0 9 * * 1', 'type': 'prompt', 'prompt': 'x', 'delivery': 'sms'},
        message: 'delivery must be one of: announce, webhook, none',
      ),
      (
        tool: 'schedule_upsert',
        arguments: {'id': 'weekly', 'schedule': '0 9 * * 1', 'type': 'task', 'task': 'a title'},
        message: 'task must be an object',
      ),
    ];

    for (final testCase in cases) {
      test('${testCase.tool}: ${testCase.message}', () async {
        writeJobsToYaml(const [(name: 'digest', schedule: '0 6 * * *')]);
        final before = configText();

        final result = _result(await _call(passingHandler(), testCase.tool, testCase.arguments));

        expect(result['isError'], isTrue);
        expect(_payload(result)['reason'], 'invalid_request');
        expect(_payload(result)['message'], testCase.message);
        // Fail-closed means the refused call also left nothing behind.
        expect(configText(), before);
        expect(readRestartPending(dataDir), isNull);
      });
    }
  });

  group('read/write classification', () {
    test('schedule_upsert is write-classified and schedule_list is read-classified', () {
      final handler = passingHandler();
      expect(handler.toolAccess, containsPair('schedule_upsert', McpToolAccess.write));
      expect(handler.toolAccess, containsPair('schedule_list', McpToolAccess.read));
    });

    test('both declare closed schemas naming no host-owned decision', () {
      final tools = <McpTool>[
        ScheduleUpsertTool(mutations: mutations),
        ScheduleListTool(mutations: mutations, schedules: null),
      ];
      const hostOwned = {'security_profile', 'container_profile', 'mount', 'mounts', 'provider', 'principal'};
      for (final tool in tools) {
        expect(tool.inputSchema['additionalProperties'], false, reason: '${tool.name} must declare a closed schema');
        expect(
          (tool.inputSchema['properties'] as Map).keys.toSet().intersection(hostOwned),
          isEmpty,
          reason: tool.name,
        );
      }
    });
  });
}
