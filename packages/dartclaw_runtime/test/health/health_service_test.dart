import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/health/health_route.dart';
import 'package:dartclaw_runtime/src/health/health_service.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late FakeAgentHarness harness;
  late String sessionsDir;
  late String tasksDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('health_test_');
    harness = FakeAgentHarness(autoTransitionState: false);
    sessionsDir = p.join(tempDir.path, 'sessions');
    tasksDir = p.join(tempDir.path, 'tasks');
    Directory(sessionsDir).createSync(recursive: true);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('HealthService', () {
    test('returns healthy status when worker is idle', () async {
      final service = HealthService(
        worker: harness,
        searchDbPath: '/nonexistent/search.db',
        sessionsDir: sessionsDir,
        startedAt: DateTime.now().subtract(const Duration(seconds: 60)),
      );

      final status = await service.getStatus();
      expect(status['status'], 'healthy');
      expect(status['uptime_s'], greaterThanOrEqualTo(59));
      expect(status['worker_state'], 'idle');
      expect(status['session_count'], 0);
      expect(status['artifact_disk_bytes'], 0);
      expect(status['version'], isNotEmpty);
    });

    test('returns unhealthy when worker is stopped', () async {
      harness.setState(WorkerState.stopped);
      final service = HealthService(worker: harness, searchDbPath: '/nonexistent/search.db', sessionsDir: sessionsDir);

      final status = await service.getStatus();
      expect(status['status'], 'unhealthy');
    });

    test('returns degraded when worker is crashed', () async {
      harness.setState(WorkerState.crashed);
      final service = HealthService(worker: harness, searchDbPath: '/nonexistent/search.db', sessionsDir: sessionsDir);

      final status = await service.getStatus();
      expect(status['status'], 'degraded');
    });

    test('counts session directories', () async {
      Directory('$sessionsDir/session-1').createSync();
      Directory('$sessionsDir/session-2').createSync();
      // File should not be counted
      File('$sessionsDir/not-a-session.json').writeAsStringSync('{}');

      final service = HealthService(worker: harness, searchDbPath: '/nonexistent/search.db', sessionsDir: sessionsDir);

      final status = await service.getStatus();
      expect(status['session_count'], 2);
    });

    test('reports DB file size', () async {
      final dbFile = File('${tempDir.path}/search.db');
      dbFile.writeAsStringSync('x' * 1024);

      final service = HealthService(worker: harness, searchDbPath: dbFile.path, sessionsDir: sessionsDir);

      final status = await service.getStatus();
      expect(status['db_size_bytes'], 1024);
    });

    test('returns 0 for missing DB file', () async {
      final service = HealthService(worker: harness, searchDbPath: '/nonexistent/search.db', sessionsDir: sessionsDir);

      final status = await service.getStatus();
      expect(status['db_size_bytes'], 0);
    });

    test('reports aggregate artifact disk usage', () async {
      final taskOneArtifacts = Directory(p.join(tasksDir, 'task-1', 'artifacts'))..createSync(recursive: true);
      final taskTwoArtifacts = Directory(p.join(tasksDir, 'task-2', 'artifacts', 'nested'))
        ..createSync(recursive: true);
      File(p.join(taskOneArtifacts.path, 'report.txt')).writeAsStringSync('hello');
      File(p.join(taskTwoArtifacts.path, 'data.json')).writeAsStringSync('1234567');
      File(p.join(tasksDir, 'task-1', 'outside.txt')).writeAsStringSync('ignored');

      final service = HealthService(worker: harness, searchDbPath: '/nonexistent/search.db', sessionsDir: sessionsDir);
      final status = await service.getStatus();

      expect(status['artifact_disk_bytes'], 12);
    });

    test('caches artifact disk usage between refreshes', () async {
      final taskArtifacts = Directory(p.join(tasksDir, 'task-1', 'artifacts'))..createSync(recursive: true);
      File(p.join(taskArtifacts.path, 'report.txt')).writeAsStringSync('hello');

      final service = HealthService(worker: harness, searchDbPath: '/nonexistent/search.db', sessionsDir: sessionsDir);

      final firstStatus = await service.getStatus();
      File(p.join(taskArtifacts.path, 'later.txt')).writeAsStringSync('1234567');
      final secondStatus = await service.getStatus();

      expect(firstStatus['artifact_disk_bytes'], 5);
      expect(secondStatus['artifact_disk_bytes'], 5);
    });

    test('version is present', () async {
      final service = HealthService(worker: harness, searchDbPath: '/nonexistent/search.db', sessionsDir: sessionsDir);

      final status = await service.getStatus();
      expect(status['version'], isA<String>());
      expect(status['version'], isNotEmpty);
    });
  });

  group('worker-state health projection', () {
    // Named per value rather than derived, so the table states the intent the
    // switch encodes: only a stopped or unreportable worker is bad news.
    const expected = {
      WorkerState.idle: 'healthy',
      WorkerState.busy: 'healthy',
      WorkerState.crashed: 'degraded',
      WorkerState.stopped: 'unhealthy',
    };

    test('answers for every WorkerState value, and for a worker it cannot read', () {
      expect(expected.keys, unorderedEquals(WorkerState.values));
      expected.forEach((state, status) => expect(healthStatusForWorkerState(state), status, reason: state.name));
      expect(healthStatusForWorkerState(null), 'degraded');
    });

    test('badges every word it produces through one mapping', () {
      expect(healthStatusBadgeVariant('healthy'), 'success');
      expect(healthStatusBadgeVariant('degraded'), 'warning');
      expect(healthStatusBadgeVariant('unhealthy'), 'error');
      // A word from outside the vocabulary is unreadable, not healthy.
      expect(healthStatusBadgeVariant('unavailable'), 'error');
    });
  });

  group('healthHandler', () {
    test('GET /health returns JSON 200 with expected fields', () async {
      final service = HealthService(worker: harness, searchDbPath: '/nonexistent/search.db', sessionsDir: sessionsDir);

      final handler = healthHandler(service);
      final request = Request('GET', Uri.parse('http://localhost/health'));
      final response = await handler(request);

      expect(response.statusCode, 200);
      expect(response.headers['Content-Type'], 'application/json');

      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['status'], 'healthy');
      expect(body['uptime_s'], isA<int>());
      expect(body['worker_state'], 'idle');
      expect(body['session_count'], isA<int>());
      expect(body['db_size_bytes'], isA<int>());
      expect(body['artifact_disk_bytes'], isA<int>());
      expect(body['version'], isA<String>());
    });
  });
}
