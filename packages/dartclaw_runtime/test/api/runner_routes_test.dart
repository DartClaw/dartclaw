import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../execution_coordinator_test_support.dart';
import '../turn_runner_test_support.dart';
import 'api_test_helpers.dart';

void main() {
  late ExecutionCoordinator executions;
  late RunnerObserver observer;
  late Handler handler;
  late ApiRouteTestClient api;

  setUp(() async {
    final runners = [FakeTurnRunner(), FakeTurnRunner()];
    executions = coordinatorForRunners(runners);
    observer = RunnerObserver(executions: executions);
    final worker = await executions.acquire(
      ExecutionRequest(
        surface: ExecutionSurface.task,
        providerId: 'claude',
        policy: const ExecutionPolicy.host(),
        sessionId: 'worker',
      ),
    );
    await worker!.release();
    await pumpEventQueue();
    handler = runnerRoutes(observer).call;
    api = ApiRouteTestClient(handler);
  });

  tearDown(() async {
    await observer.dispose();
    await executions.dispose();
  });

  test('GET /api/runners returns all runners and capacity status', () async {
    final lease = await executions.acquire(
      ExecutionRequest(
        surface: ExecutionSurface.task,
        providerId: 'claude',
        policy: const ExecutionPolicy.host(),
        sessionId: 'worker',
        taskId: 'task-1',
      ),
    );
    addTearDown(lease!.release);
    await pumpEventQueue();

    final body = await api.expectJsonObject('GET', '/api/runners');

    expect(body, await _runnerApiListFixture());
    final runners = body['runners'] as List;
    expect(runners, hasLength(2));
    expect(runners[0]['runnerId'], 0);
    expect(runners[0]['role'], 'primary');
    expect(runners[0]['state'], 'idle');
    expect(runners[1]['runnerId'], 1);
    expect(runners[1]['role'], 'worker');
    expect(runners[1]['state'], 'busy');
    expect(runners[1]['currentTaskId'], 'task-1');
    expect(runners[1]['tokensConsumed'], 0);
    for (final runner in runners) {
      expect(runner['executionMode'], 'host', reason: 'diagnostics report the real execution mode');
      expect(runner['containerProfile'], isNull, reason: 'host execution carries no container profile');
    }

    final capacity = body['capacity'] as Map<String, dynamic>;
    expect(capacity['runnerCount'], 2);
    expect(capacity['configured'], 1);
  });

  test('GET /api/runners/<id> returns single runner', () async {
    final body = await api.expectJsonObject('GET', '/api/runners/0');

    expect(body['runnerId'], 0);
    expect(body['role'], 'primary');
  });

  test('GET /api/runners/<id> returns 404 for out-of-range', () async {
    await api.expectResponse('GET', '/api/runners/99', status: 404);
  });

  test('GET /api/runners/<id> returns 400 for non-integer', () async {
    await api.expectResponse('GET', '/api/runners/abc', status: 400);
  });
}

Future<Map<String, dynamic>> _runnerApiListFixture() async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_testing/fixtures/runner_api_list.json'));
  if (uri == null) throw StateError('Runner API fixture is unavailable.');
  return jsonDecode(await File.fromUri(uri).readAsString()) as Map<String, dynamic>;
}
