import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'api_test_helpers.dart';

void main() {
  late RuntimeConfig runtimeConfig;

  setUp(() {
    runtimeConfig = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: false, gitSyncPushEnabled: true);
  });

  group('GET /api/settings/runtime', () {
    test('returns current runtime state', () async {
      final client = ApiRouteTestClient(
        configRoutes(
          runtimeConfig: runtimeConfig,
          heartbeatIntervalMinutes: 15,
          scheduledJobs: [
            {'name': 'daily-report', 'status': 'active', 'schedule': '0 9 * * *'},
          ],
        ).call,
      );

      final body = await client.expectJsonObject('GET', '/api/settings/runtime');
      expect(body['heartbeat']['enabled'], isTrue);
      expect(body['heartbeat']['intervalMinutes'], 15);
      expect(body['gitSync']['enabled'], isFalse);
      expect(body['gitSync']['pushEnabled'], isTrue);
      expect(body['jobs'], hasLength(1));
      expect((body['jobs'] as List).first['name'], 'daily-report');
    });
  });

  group('POST /api/settings/heartbeat/toggle', () {
    test('returns 404 when heartbeat not configured', () async {
      final client = ApiRouteTestClient(configRoutes(runtimeConfig: runtimeConfig).call);

      await client.expectResponse('POST', '/api/settings/heartbeat/toggle', json: {'enabled': false}, status: 404);
    });

    test('returns 400 for non-JSON body', () async {
      final router = configRoutes(runtimeConfig: runtimeConfig);

      final request = Request(
        'POST',
        Uri.parse('http://localhost/api/settings/heartbeat/toggle'),
        body: 'not json',
        headers: {'content-type': 'text/plain'},
      );
      final response = await router.call(request);

      // Falls through to 404 since heartbeat is null
      expect(response.statusCode, 404);
    });
  });

  group('POST /api/settings/git-sync/toggle', () {
    test('returns 404 when git sync not configured', () async {
      final client = ApiRouteTestClient(configRoutes(runtimeConfig: runtimeConfig).call);

      await client.expectResponse('POST', '/api/settings/git-sync/toggle', json: {'enabled': true}, status: 404);
    });
  });

  group('POST /api/scheduling/jobs/<name>/toggle', () {
    test('returns 404 when schedule service not configured', () async {
      final client = ApiRouteTestClient(
        configRoutes(
          runtimeConfig: runtimeConfig,
          scheduledJobs: [
            {'name': 'test-job', 'status': 'active'},
          ],
        ).call,
      );

      await client.expectResponse(
        'POST',
        '/api/scheduling/jobs/test-job/toggle',
        json: {'status': 'paused'},
        status: 404,
      );
    });

    test('returns 404 NOT_AVAILABLE for unknown job when service unconfigured', () async {
      final client = ApiRouteTestClient(
        configRoutes(
          runtimeConfig: runtimeConfig,
          scheduledJobs: [
            {'name': 'test-job', 'status': 'active'},
          ],
        ).call,
      );

      final body = await client.expectJsonObject(
        'POST',
        '/api/scheduling/jobs/nonexistent/toggle',
        json: {'status': 'paused'},
        status: 404,
      );
      expect((body['error'] as Map)['code'], 'NOT_AVAILABLE');
    });
  });

  group('POST /api/scheduling/jobs/<name>/run', () {
    ScheduledJob job(String id) => ScheduledJob.fromConfig({
      'id': id,
      'prompt': 'Summarize',
      'schedule': {'type': 'interval', 'minutes': 60},
      'delivery': 'none',
    });

    test('starts a live job with 202', () async {
      final service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: _FakeSessionService(),
        jobs: [job('daily-summary')],
      )..start();
      final client = ApiRouteTestClient(configRoutes(runtimeConfig: runtimeConfig, scheduleService: service).call);

      final body = await client.expectJsonObject('POST', '/api/scheduling/jobs/daily-summary/run', status: 202);

      expect(body, {'name': 'daily-summary', 'status': 'started'});
      service.stop();
    });

    test('returns CONFLICT while the job is already running', () async {
      final sessions = _BlockingSessionService();
      final service = ScheduleService(turns: FakeTurnManager(), sessions: sessions, jobs: [job('daily-summary')])
        ..start();
      final client = ApiRouteTestClient(configRoutes(runtimeConfig: runtimeConfig, scheduleService: service).call);

      await client.expectResponse('POST', '/api/scheduling/jobs/daily-summary/run', status: 202);
      final body = await client.expectJsonObject('POST', '/api/scheduling/jobs/daily-summary/run', status: 409);

      expect((body['error'] as Map)['code'], 'CONFLICT');
      sessions.release.complete();
      await pumpEventQueue();
      service.stop();
    });

    test('returns NOT_FOUND with restart guidance for an unknown job', () async {
      final service = ScheduleService(turns: FakeTurnManager(), sessions: _FakeSessionService(), jobs: [])..start();
      final client = ApiRouteTestClient(configRoutes(runtimeConfig: runtimeConfig, scheduleService: service).call);

      final body = await client.expectJsonObject('POST', '/api/scheduling/jobs/nightly-review/run', status: 404);
      final error = body['error'] as Map;
      expect(error['code'], 'NOT_FOUND');
      expect(error['message'], contains('require a restart'));
      expect(error['message'], contains('running scheduler'));
      service.stop();
    });

    test('returns NOT_AVAILABLE when scheduling is not configured', () async {
      final client = ApiRouteTestClient(configRoutes(runtimeConfig: runtimeConfig).call);

      final body = await client.expectJsonObject('POST', '/api/scheduling/jobs/daily-summary/run', status: 404);

      expect((body['error'] as Map)['code'], 'NOT_AVAILABLE');
    });

    test('decodes a URL-encoded job name', () async {
      final service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: _FakeSessionService(),
        jobs: [job('Q&A digest')],
      )..start();
      final client = ApiRouteTestClient(configRoutes(runtimeConfig: runtimeConfig, scheduleService: service).call);

      final body = await client.expectJsonObject('POST', '/api/scheduling/jobs/Q%26A%20digest/run', status: 202);

      expect(body['name'], 'Q&A digest');
      service.stop();
    });

    test('decodes the captured route segment exactly once', () async {
      final service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: _FakeSessionService(),
        jobs: [job('literal%2Fname')],
      )..start();
      final client = ApiRouteTestClient(configRoutes(runtimeConfig: runtimeConfig, scheduleService: service).call);

      final body = await client.expectJsonObject('POST', '/api/scheduling/jobs/literal%252Fname/run', status: 202);

      expect(body['name'], 'literal%2Fname');
      service.stop();
    });
  });

  group('form-encoded body (HTMX default encoding)', () {
    late Directory tempDir;
    late ScheduleService service;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('config_routes_htmx_test_');
      service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: _FakeSessionService(),
        jobs: [buildHeartbeatJob(workspaceDir: tempDir.path, intervalMinutes: 30)],
      )..start();
    });

    tearDown(() {
      service.stop();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('heartbeat toggle accepts form-encoded body', () async {
      final router = configRoutes(runtimeConfig: runtimeConfig, scheduleService: service);

      // HTMX sends form-encoded by default
      final request = Request(
        'POST',
        Uri.parse('http://localhost/api/settings/heartbeat/toggle'),
        body: 'enabled=false',
      );
      final response = await router.call(request);

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['enabled'], isFalse);
      expect(runtimeConfig.heartbeatEnabled, isFalse);
      expect(service.isJobPaused(heartbeatJobId), isTrue);
    });

    test('heartbeat toggle accepts JSON body', () async {
      final client = ApiRouteTestClient(configRoutes(runtimeConfig: runtimeConfig, scheduleService: service).call);

      final body = await client.expectJsonObject('POST', '/api/settings/heartbeat/toggle', json: {'enabled': true});
      expect(body['enabled'], isTrue);
      expect(service.isJobPaused(heartbeatJobId), isFalse);
    });
  });

  group('live toggles reach the folded jobs from either boot state', () {
    late Directory tempDir;
    late ScheduleService service;
    late WorkspaceGitSync gitSync;
    late ScheduledJob gitSyncJob;
    late List<List<String>> gitInvocations;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('config_routes_toggle_test_');
      gitInvocations = [];
      gitSync = WorkspaceGitSync(
        workspaceDir: tempDir.path,
        commandRunner: RecordingGitRunner(
          responder: (call) {
            gitInvocations.add(['git', ...call.arguments]);
            return null;
          },
        ).run,
      );
      await gitSync.isGitAvailable();
      gitInvocations.clear();
      gitSyncJob = buildWorkspaceGitSyncJob(gitSync, intervalMinutes: 30).job;
      service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: _FakeSessionService(),
        jobs: [
          buildHeartbeatJob(workspaceDir: tempDir.path, intervalMinutes: 30),
          gitSyncJob,
        ],
      )..start();
    });

    tearDown(() {
      service.stop();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('a boot-disabled heartbeat is started by the toggle instead of answering 404', () async {
      service.pauseJob(heartbeatJobId);
      runtimeConfig.heartbeatEnabled = false;
      final client = ApiRouteTestClient(configRoutes(runtimeConfig: runtimeConfig, scheduleService: service).call);

      final enabled = await client.expectJsonObject('POST', '/api/settings/heartbeat/toggle', json: {'enabled': true});

      expect(enabled['enabled'], isTrue);
      expect(service.isJobPaused(heartbeatJobId), isFalse);
      final runtime = await client.expectJsonObject('GET', '/api/settings/runtime');
      expect(runtime['heartbeat']['enabled'], isTrue);
    });

    test('a boot-disabled git sync is started by the toggle and stopped again', () async {
      service.pauseJob(workspaceGitSyncJobId);
      runtimeConfig.gitSyncEnabled = false;
      final client = ApiRouteTestClient(
        configRoutes(runtimeConfig: runtimeConfig, scheduleService: service, gitSync: gitSync).call,
      );

      final enabled = await client.expectJsonObject('POST', '/api/settings/git-sync/toggle', json: {'enabled': true});
      expect(enabled['enabled'], isTrue);
      expect(service.isJobPaused(workspaceGitSyncJobId), isFalse);

      final disabled = await client.expectJsonObject('POST', '/api/settings/git-sync/toggle', json: {'enabled': false});
      expect(disabled['enabled'], isFalse);
      expect(service.isJobPaused(workspaceGitSyncJobId), isTrue);
      final runtime = await client.expectJsonObject('GET', '/api/settings/runtime');
      expect(runtime['gitSync']['enabled'], isFalse);
    });

    test('a disabled git-sync job performs no git invocation when its interval elapses', () async {
      service.pauseJob(workspaceGitSyncJobId);

      await service.executeJobForTesting(gitSyncJob);
      expect(gitInvocations, isEmpty);

      service.resumeJob(workspaceGitSyncJobId);
      await service.executeJobForTesting(gitSyncJob);
      expect(gitInvocations.map((invocation) => invocation.take(2).join(' ')), contains('git status'));
    });

    test('push_enabled still hot-applies through the toggle', () async {
      final client = ApiRouteTestClient(
        configRoutes(runtimeConfig: runtimeConfig, scheduleService: service, gitSync: gitSync).call,
      );

      final body = await client.expectJsonObject('POST', '/api/settings/git-sync/toggle', json: {'pushEnabled': false});

      expect(body['pushEnabled'], isFalse);
      expect(gitSync.pushEnabled, isFalse);
    });
  });

  group('capped body reads', () {
    late Directory tempDir;
    late ScheduleService service;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('config_routes_cap_test_');
      service = ScheduleService(
        turns: FakeTurnManager(),
        sessions: _FakeSessionService(),
        jobs: [buildHeartbeatJob(workspaceDir: tempDir.path, intervalMinutes: 30)],
      )..start();
    });

    tearDown(() {
      service.stop();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('every toggle refuses an oversized streamed body without buffering it', () async {
      final router = configRoutes(
        runtimeConfig: runtimeConfig,
        scheduleService: service,
        gitSync: WorkspaceGitSync(
          workspaceDir: tempDir.path,
          commandRunner: RecordingGitRunner(responder: (call) => null).run,
        ),
        scheduledJobs: [
          {'name': 'daily-report', 'status': 'active'},
        ],
      );

      for (final path in const [
        '/api/settings/heartbeat/toggle',
        '/api/settings/git-sync/toggle',
        '/api/scheduling/jobs/daily-report/toggle',
      ]) {
        var chunksRead = 0;
        final chunks = <List<int>>[
          utf8.encode('enabled=false&status=paused&pad='),
          for (var i = 0; i < 4; i++) utf8.encode('x' * (128 * 1024)),
        ];
        final response = await router.call(
          Request(
            'POST',
            Uri.parse('http://localhost$path'),
            // No content-length: the cap has to hold on the streamed read itself.
            body: Stream<List<int>>.fromIterable(chunks).map((chunk) {
              chunksRead++;
              return chunk;
            }),
          ),
        );

        expect(response.statusCode, 413, reason: path);
        expect((jsonDecode(await response.readAsString()) as Map)['error']['code'], 'REQUEST_TOO_LARGE', reason: path);
        expect(chunksRead, lessThan(chunks.length), reason: path);
      }

      expect(runtimeConfig.heartbeatEnabled, isTrue);
      expect(service.isJobPaused(heartbeatJobId), isFalse);
      expect(service.isJobPaused('daily-report'), isFalse);
    });

    test('a body that is not UTF-8 is refused instead of throwing out of the handler', () async {
      final router = configRoutes(runtimeConfig: runtimeConfig, scheduleService: service);

      final response = await router.call(
        Request(
          'POST',
          Uri.parse('http://localhost/api/settings/heartbeat/toggle'),
          body: Stream<List<int>>.fromIterable([
            [0xc3, 0x28],
          ]),
        ),
      );

      expect(response.statusCode, 400);
      final error = (jsonDecode(await response.readAsString()) as Map)['error'] as Map;
      expect(error['code'], 'INVALID_INPUT');
      expect(error['message'], 'request body must be valid UTF-8');
      expect(runtimeConfig.heartbeatEnabled, isTrue);
    });

    test('a malformed or non-object JSON toggle body keeps its published message', () async {
      final client = ApiRouteTestClient(configRoutes(runtimeConfig: runtimeConfig, scheduleService: service).call);

      for (final body in const ['{not json', '[]']) {
        final json = await client.expectJsonObject(
          'POST',
          '/api/settings/heartbeat/toggle',
          body: body,
          headers: const {'content-type': 'application/json'},
          status: 400,
        );

        expect(json['error'], containsPair('message', 'Invalid request body'), reason: body);
      }

      expect(runtimeConfig.heartbeatEnabled, isTrue);
    });

    test('an empty toggle body still decodes to an empty form map', () async {
      final client = ApiRouteTestClient(configRoutes(runtimeConfig: runtimeConfig, scheduleService: service).call);

      final body = await client.expectJsonObject('POST', '/api/settings/heartbeat/toggle', body: '', status: 400);

      expect((body['error'] as Map)['message'], '"enabled" must be a boolean');
      expect(runtimeConfig.heartbeatEnabled, isTrue);
    });
  });

  group('one applier behind the toggle and PATCH /api/config', () {
    late Directory tempDir;
    late String configPath;
    late String dataDir;
    late String originalYaml;

    ({RuntimeConfig runtime, ScheduleService service, WorkspaceGitSync gitSync}) newSurface() {
      final gitSync = WorkspaceGitSync(
        workspaceDir: tempDir.path,
        commandRunner: RecordingGitRunner(responder: (call) => null).run,
      );
      return (
        runtime: RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true),
        service: ScheduleService(
          turns: FakeTurnManager(),
          sessions: _FakeSessionService(),
          jobs: [
            buildHeartbeatJob(workspaceDir: tempDir.path, intervalMinutes: 30),
            buildWorkspaceGitSyncJob(gitSync, intervalMinutes: 30).job,
          ],
        )..start(),
        gitSync: gitSync,
      );
    }

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('config_routes_applier_test_');
      configPath = p.join(tempDir.path, 'dartclaw.yaml');
      dataDir = p.join(tempDir.path, 'data');
      Directory(dataDir).createSync();
      originalYaml =
          'port: 3000\nscheduling:\n  heartbeat:\n    enabled: true\n    interval_minutes: 30\n  jobs: []\n'
          'workspace:\n  git_sync:\n    enabled: true\n    push_enabled: true\n';
      File(configPath).writeAsStringSync(originalYaml);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('both surfaces reach the same runtime state for all three switches, and only the PATCH persists', () async {
      final toggle = newSurface();
      final toggleClient = ApiRouteTestClient(
        configRoutes(runtimeConfig: toggle.runtime, scheduleService: toggle.service, gitSync: toggle.gitSync).call,
      );

      await toggleClient.expectResponse(
        'POST',
        '/api/settings/heartbeat/toggle',
        json: {'enabled': false},
        status: 200,
      );
      await toggleClient.expectResponse(
        'POST',
        '/api/settings/git-sync/toggle',
        json: {'enabled': false, 'pushEnabled': false},
        status: 200,
      );
      final yamlAfterToggle = File(configPath).readAsStringSync();
      toggle.service.stop();

      final patch = newSurface();
      final bus = EventBus();
      ConfigChangeSubscriber(
        runtimeConfig: patch.runtime,
        scheduleService: patch.service,
        gitSync: patch.gitSync,
      ).subscribe(bus);
      final patchHandler = const Pipeline()
          .addMiddleware(localAdminMiddleware())
          .addHandler(
            configApiRoutes(
              config: const DartclawConfig.defaults(),
              writer: ConfigWriter(configPath: configPath),
              validator: const ConfigValidator(),
              runtimeConfig: patch.runtime,
              dataDir: dataDir,
              eventBus: bus,
            ).call,
          );

      await ApiRouteTestClient(patchHandler).expectResponse(
        'PATCH',
        '/api/config',
        json: {
          'scheduling.heartbeat.enabled': false,
          'workspace.git_sync.enabled': false,
          'workspace.git_sync.push_enabled': false,
        },
        status: 200,
      );
      await pumpEventQueue();

      expect(patch.runtime.toJson(), toggle.runtime.toJson());
      expect(patch.service.isJobPaused(heartbeatJobId), toggle.service.isJobPaused(heartbeatJobId));
      expect(patch.service.isJobPaused(workspaceGitSyncJobId), toggle.service.isJobPaused(workspaceGitSyncJobId));
      expect(patch.gitSync.pushEnabled, toggle.gitSync.pushEnabled);

      expect(toggle.runtime.toJson(), {
        'heartbeat': {'enabled': false},
        'gitSync': {'enabled': false, 'pushEnabled': false},
      });
      expect(toggle.service.isJobPaused(heartbeatJobId), isTrue);
      expect(toggle.service.isJobPaused(workspaceGitSyncJobId), isTrue);
      expect(toggle.gitSync.pushEnabled, isFalse);

      // The toggles are ephemeral by contract; only the PATCH writes the config file.
      expect(yamlAfterToggle, originalYaml);
      expect(File(configPath).readAsStringSync(), isNot(originalYaml));
      // Live-tier: even the persistent surface applies them now rather than deferring to a restart.
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), isFalse);
      patch.service.stop();
    });
  });

  group('job pause/resume via ScheduleService', () {
    test('pause/resume toggle updates service state', () async {
      final service = ScheduleService(turns: FakeTurnManager(), sessions: _FakeSessionService(), jobs: []);
      final jobs = <Map<String, dynamic>>[
        {'name': 'daily-report', 'status': 'active', 'schedule': '0 9 * * *'},
      ];
      final client = ApiRouteTestClient(
        configRoutes(runtimeConfig: runtimeConfig, scheduleService: service, scheduledJobs: jobs).call,
      );

      await client.expectResponse(
        'POST',
        '/api/scheduling/jobs/daily-report/toggle',
        json: {'status': 'paused'},
        status: 200,
      );
      expect(service.isJobPaused('daily-report'), isTrue);
      expect(jobs.first['status'], 'paused');

      await client.expectResponse(
        'POST',
        '/api/scheduling/jobs/daily-report/toggle',
        json: {'status': 'active'},
        status: 200,
      );
      expect(service.isJobPaused('daily-report'), isFalse);
      expect(jobs.first['status'], 'active');
    });

    test('job toggle accepts form-encoded body', () async {
      final service = ScheduleService(turns: FakeTurnManager(), sessions: _FakeSessionService(), jobs: []);
      final jobs = <Map<String, dynamic>>[
        {'name': 'nightly-sync', 'status': 'active'},
      ];
      final router = configRoutes(runtimeConfig: runtimeConfig, scheduleService: service, scheduledJobs: jobs);

      final request = Request(
        'POST',
        Uri.parse('http://localhost/api/scheduling/jobs/nightly-sync/toggle'),
        body: 'status=paused',
      );
      final response = await router.call(request);

      expect(response.statusCode, 200);
      expect(service.isJobPaused('nightly-sync'), isTrue);
    });
  });
}

class _FakeSessionService implements SessionService {
  @override
  Future<Session> getOrCreateByKey(
    String key, {
    SessionType type = SessionType.user,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
  }) async {
    return Session(id: 'session-$key', createdAt: DateTime.now(), updatedAt: DateTime.now());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _BlockingSessionService extends _FakeSessionService {
  final release = Completer<void>();

  @override
  Future<Session> getOrCreateByKey(
    String key, {
    SessionType type = SessionType.user,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
  }) async {
    await release.future;
    return super.getOrCreateByKey(key, type: type, provider: provider, securityProfile: securityProfile);
  }
}
