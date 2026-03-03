import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late RuntimeConfig runtimeConfig;

  setUp(() {
    runtimeConfig = RuntimeConfig(
      heartbeatEnabled: true,
      gitSyncEnabled: false,
      gitSyncPushEnabled: true,
    );
  });

  group('GET /api/settings/runtime', () {
    test('returns current runtime state', () async {
      final router = configRoutes(
        runtimeConfig: runtimeConfig,
        heartbeatIntervalMinutes: 15,
        scheduledJobs: [
          {'name': 'daily-report', 'status': 'active', 'schedule': '0 9 * * *'},
        ],
      );

      final request = Request('GET', Uri.parse('http://localhost/api/settings/runtime'));
      final response = await router.call(request);

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
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
      final router = configRoutes(runtimeConfig: runtimeConfig);

      final request = Request(
        'POST',
        Uri.parse('http://localhost/api/settings/heartbeat/toggle'),
        body: jsonEncode({'enabled': false}),
        headers: {'content-type': 'application/json'},
      );
      final response = await router.call(request);

      expect(response.statusCode, 404);
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
      final router = configRoutes(runtimeConfig: runtimeConfig);

      final request = Request(
        'POST',
        Uri.parse('http://localhost/api/settings/git-sync/toggle'),
        body: jsonEncode({'enabled': true}),
        headers: {'content-type': 'application/json'},
      );
      final response = await router.call(request);

      expect(response.statusCode, 404);
    });
  });

  group('POST /api/scheduling/jobs/<name>/toggle', () {
    test('returns 404 when schedule service not configured', () async {
      final router = configRoutes(
        runtimeConfig: runtimeConfig,
        scheduledJobs: [
          {'name': 'test-job', 'status': 'active'},
        ],
      );

      final request = Request(
        'POST',
        Uri.parse('http://localhost/api/scheduling/jobs/test-job/toggle'),
        body: jsonEncode({'status': 'paused'}),
        headers: {'content-type': 'application/json'},
      );
      final response = await router.call(request);

      expect(response.statusCode, 404);
    });

    test('returns 404 NOT_AVAILABLE for unknown job when service unconfigured', () async {
      final router = configRoutes(
        runtimeConfig: runtimeConfig,
        scheduledJobs: [
          {'name': 'test-job', 'status': 'active'},
        ],
      );

      final request = Request(
        'POST',
        Uri.parse('http://localhost/api/scheduling/jobs/nonexistent/toggle'),
        body: jsonEncode({'status': 'paused'}),
        headers: {'content-type': 'application/json'},
      );
      final response = await router.call(request);

      expect(response.statusCode, 404);
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect((body['error'] as Map)['code'], 'NOT_AVAILABLE');
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
      final router = configRoutes(
        runtimeConfig: runtimeConfig,
        heartbeat: heartbeat,
      );

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
      final router = configRoutes(
        runtimeConfig: runtimeConfig,
        heartbeat: heartbeat,
      );

      final request = Request(
        'POST',
        Uri.parse('http://localhost/api/settings/heartbeat/toggle'),
        body: jsonEncode({'enabled': true}),
        headers: {'content-type': 'application/json'},
      );
      final response = await router.call(request);

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['enabled'], isTrue);
    });
  });

  group('job pause/resume via ScheduleService', () {
    test('pause/resume toggle updates service state', () async {
      final service = ScheduleService(
        turns: _FakeTurnManager(),
        sessions: _FakeSessionService(),
        jobs: [],
      );
      final jobs = <Map<String, dynamic>>[
        {'name': 'daily-report', 'status': 'active', 'schedule': '0 9 * * *'},
      ];
      final router = configRoutes(
        runtimeConfig: runtimeConfig,
        scheduleService: service,
        scheduledJobs: jobs,
      );

      final pauseRequest = Request(
        'POST',
        Uri.parse('http://localhost/api/scheduling/jobs/daily-report/toggle'),
        body: jsonEncode({'status': 'paused'}),
        headers: {'content-type': 'application/json'},
      );
      final pauseResponse = await router.call(pauseRequest);

      expect(pauseResponse.statusCode, 200);
      expect(service.isJobPaused('daily-report'), isTrue);
      expect(jobs.first['status'], 'paused');

      final resumeRequest = Request(
        'POST',
        Uri.parse('http://localhost/api/scheduling/jobs/daily-report/toggle'),
        body: jsonEncode({'status': 'active'}),
        headers: {'content-type': 'application/json'},
      );
      final resumeResponse = await router.call(resumeRequest);

      expect(resumeResponse.statusCode, 200);
      expect(service.isJobPaused('daily-report'), isFalse);
      expect(jobs.first['status'], 'active');
    });

    test('job toggle accepts form-encoded body', () async {
      final service = ScheduleService(
        turns: _FakeTurnManager(),
        sessions: _FakeSessionService(),
        jobs: [],
      );
      final jobs = <Map<String, dynamic>>[
        {'name': 'nightly-sync', 'status': 'active'},
      ];
      final router = configRoutes(
        runtimeConfig: runtimeConfig,
        scheduleService: service,
        scheduledJobs: jobs,
      );

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

class _FakeTurnManager implements TurnManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeSessionService implements SessionService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
