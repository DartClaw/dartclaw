import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/health/health_route.dart';
import 'package:dartclaw_server/src/health/health_service.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _FakeHarness implements AgentHarness {
  @override
  WorkerState get state => WorkerState.idle;
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

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('health_route_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('GET /health returns JSON 200 with expected fields', () async {
    final service = HealthService(
      worker: _FakeHarness(),
      searchDbPath: '/nonexistent/search.db',
      sessionsDir: tempDir.path,
    );

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
    expect(body['version'], isA<String>());
  });
}
