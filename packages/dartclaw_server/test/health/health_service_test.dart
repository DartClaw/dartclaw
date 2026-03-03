import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/health/health_service.dart';
import 'package:test/test.dart';

class _FakeHarness implements AgentHarness {
  WorkerState _state = WorkerState.idle;

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
  }) async =>
      {};
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

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('health_test_');
    harness = _FakeHarness();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('HealthService', () {
    test('returns healthy status when worker is idle', () async {
      final service = HealthService(
        worker: harness,
        searchDbPath: '/nonexistent/search.db',
        sessionsDir: tempDir.path,
        startedAt: DateTime.now().subtract(const Duration(seconds: 60)),
      );

      final status = await service.getStatus();
      expect(status['status'], 'healthy');
      expect(status['uptime_s'], greaterThanOrEqualTo(59));
      expect(status['worker_state'], 'idle');
      expect(status['session_count'], 0);
      expect(status['version'], isNotEmpty);
    });

    test('returns unhealthy when worker is stopped', () async {
      harness.setState(WorkerState.stopped);
      final service = HealthService(
        worker: harness,
        searchDbPath: '/nonexistent/search.db',
        sessionsDir: tempDir.path,
      );

      final status = await service.getStatus();
      expect(status['status'], 'unhealthy');
    });

    test('returns degraded when worker is crashed', () async {
      harness.setState(WorkerState.crashed);
      final service = HealthService(
        worker: harness,
        searchDbPath: '/nonexistent/search.db',
        sessionsDir: tempDir.path,
      );

      final status = await service.getStatus();
      expect(status['status'], 'degraded');
    });

    test('counts session directories', () async {
      Directory('${tempDir.path}/session-1').createSync();
      Directory('${tempDir.path}/session-2').createSync();
      // File should not be counted
      File('${tempDir.path}/not-a-session.json').writeAsStringSync('{}');

      final service = HealthService(
        worker: harness,
        searchDbPath: '/nonexistent/search.db',
        sessionsDir: tempDir.path,
      );

      final status = await service.getStatus();
      expect(status['session_count'], 2);
    });

    test('reports DB file size', () async {
      final dbFile = File('${tempDir.path}/search.db');
      dbFile.writeAsStringSync('x' * 1024);

      final service = HealthService(
        worker: harness,
        searchDbPath: dbFile.path,
        sessionsDir: tempDir.path,
      );

      final status = await service.getStatus();
      expect(status['db_size_bytes'], 1024);
    });

    test('returns 0 for missing DB file', () async {
      final service = HealthService(
        worker: harness,
        searchDbPath: '/nonexistent/search.db',
        sessionsDir: tempDir.path,
      );

      final status = await service.getStatus();
      expect(status['db_size_bytes'], 0);
    });

    test('version is present', () async {
      final service = HealthService(
        worker: harness,
        searchDbPath: '/nonexistent/search.db',
        sessionsDir: tempDir.path,
      );

      final status = await service.getStatus();
      expect(status['version'], isA<String>());
      expect(status['version'], isNotEmpty);
    });
  });
}
