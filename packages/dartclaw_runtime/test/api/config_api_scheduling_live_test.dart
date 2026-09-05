import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/config/scheduling_jobs_applier.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

import 'api_test_helpers.dart';

void main() {
  late Directory tempDir;
  late String configPath;
  late String dataDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('config_api_scheduling_live_test_');
    configPath = p.join(tempDir.path, 'dartclaw.yaml');
    dataDir = p.join(tempDir.path, 'data');
    Directory(dataDir).createSync();
    File(configPath).writeAsStringSync('''
port: 3000
host: localhost
scheduling:
  jobs: []
''');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  ApiRouteTestClient api(Router router) => ApiRouteTestClient(router.call);

  // S02, S03, S08: the routes are adapters over the mutation seam, and the seam
  // loads what it wrote. Wired here the way the composition root wires it, so
  // the assertions are about the running scheduler and not about a stub.
  group('the jobs API is live', () {
    late ScheduleService service;
    late Router router;

    setUp(() {
      final writer = ConfigWriter(configPath: configPath);
      addTearDown(writer.dispose);
      service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: InMemorySessionService(),
        jobs: [
          ScheduledJob(
            id: 'heartbeat',
            scheduleType: ScheduleType.interval,
            intervalMinutes: 30,
            onExecute: () async => 'beat',
          ),
        ],
      )..start();
      addTearDown(service.stop);
      final applier = SchedulingJobsApplier(
        configPath: configPath,
        jobs: ScheduleMutationService(writer: writer),
        scheduleService: () => service,
        taskService: TaskService(InMemoryTaskRepository()),
      );
      router = configApiRoutes(
        config: const DartclawConfig.defaults(),
        writer: writer,
        validator: const ConfigValidator(),
        runtimeConfig: RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: false, gitSyncPushEnabled: false),
        dataDir: dataDir,
        applyJobs: applier.apply,
        reservedJobIds: () => service.builtInJobIds,
      );
    });

    Future<void> createStandup() async {
      await api(router).expectJsonObject(
        'POST',
        '/api/scheduling/jobs',
        json: {'name': 'standup', 'schedule': '0 9 * * *', 'prompt': 'Run standup', 'delivery': 'announce'},
        status: 201,
      );
    }

    test('S02 a PUT replaces the loaded job in place and keeps its pause state', () async {
      await createStandup();
      expect(service.hasJob('standup'), isTrue);
      service.pauseJob('standup');

      await api(router).expectJsonObject('PUT', '/api/scheduling/jobs/standup', json: {'schedule': '0 18 * * *'});

      final entries = service.entries.where((entry) => entry.id == 'standup');
      expect(entries, hasLength(1), reason: 'a replacement must not leave a second entry under the id');
      expect(entries.single.cronExpression, '0 18 * * *');
      expect(entries.single.paused, isTrue);
    });

    test('S03 a DELETE unloads the job and run-now then answers not found', () async {
      await createStandup();

      await api(router).expectJsonObject('DELETE', '/api/scheduling/jobs/standup');

      expect(service.hasJob('standup'), isFalse);
      expect(service.runJobNow('standup'), RunScheduledJobResult.notFound);
    });

    test('S08 a created job is runnable immediately, and a built-in id is refused', () async {
      await createStandup();

      expect(service.runJobNow('standup'), RunScheduledJobResult.started);

      await api(router).expectResponse(
        'POST',
        '/api/scheduling/jobs',
        json: {'name': 'heartbeat', 'schedule': '0 9 * * *', 'prompt': 'Impostor', 'delivery': 'none'},
        status: 409,
      );
      expect(service.builtInJobIds, {'heartbeat'});
    });

    test('S06 an at in the past is refused as INVALID_INPUT with nothing loaded', () async {
      final json = await api(router).expectJsonObject(
        'POST',
        '/api/scheduling/jobs',
        json: {'name': 'remind', 'at': '2020-01-01T00:00:00', 'prompt': 'Remind me', 'delivery': 'none'},
        status: 400,
      );

      expect(json['error']['code'], 'INVALID_INPUT');
      expect(json['error']['message'], contains('"at" must be later than now'));
      expect(service.hasJob('remind'), isFalse);
    });
  });
}
