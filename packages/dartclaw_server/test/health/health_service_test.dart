import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/health/health_route.dart';
import 'package:dartclaw_server/src/health/health_service.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _FakeHarness implements AgentHarness {
  WorkerState _state = WorkerState.idle;

  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  bool get supportsSessionContinuity => false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => _state;

  void setState(WorkerState s) => _state = s;

  @override
  Stream<BridgeEvent> get events => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async => {};
  @override
  Future<void> cancel() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory tempDir;
  late _FakeHarness harness;
  late String sessionsDir;
  late String tasksDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('health_test_');
    harness = _FakeHarness();
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
