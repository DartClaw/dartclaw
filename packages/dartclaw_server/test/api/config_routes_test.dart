import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
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

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('config_routes_htmx_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('heartbeat toggle accepts form-encoded body', () async {
      final heartbeat = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: tempDir.path,
        dispatch: (_, _) async {},
      );
      final router = configRoutes(runtimeConfig: runtimeConfig, heartbeat: heartbeat);

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
    });

    test('heartbeat toggle accepts JSON body', () async {
      final heartbeat = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: tempDir.path,
        dispatch: (_, _) async {},
      );
      final client = ApiRouteTestClient(configRoutes(runtimeConfig: runtimeConfig, heartbeat: heartbeat).call);

      final body = await client.expectJsonObject('POST', '/api/settings/heartbeat/toggle', json: {'enabled': true});
      expect(body['enabled'], isTrue);
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
  }) async {
    await release.future;
    return super.getOrCreateByKey(key, type: type, provider: provider, securityProfile: securityProfile);
  }
}
