import 'package:dartclaw_server/dartclaw_server.dart' hide HarnessPool, TurnRunner;
import 'package:dartclaw_server/src/harness_pool.dart' show HarnessPool;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../turn_runner_test_support.dart';
import 'api_test_helpers.dart';

void main() {
  late HarnessPool pool;
  late AgentObserver observer;
  late Handler handler;
  late ApiRouteTestClient api;

  setUp(() {
    final runners = [FakeTurnRunner(), FakeTurnRunner()];
    pool = HarnessPool(runners: runners);
    observer = AgentObserver(pool: pool);
    handler = agentRoutes(observer).call;
    api = ApiRouteTestClient(handler);
  });

  tearDown(() {
    observer.dispose();
  });

  test('GET /api/agents returns all runners and pool status', () async {
    observer.markBusy(1, taskId: 'task-1');
    observer.recordTurn(1, inputTokens: 100, outputTokens: 50, isError: false);

    final body = await api.expectJsonObject('GET', '/api/agents');

    final runners = body['runners'] as List;
    expect(runners, hasLength(2));
    expect(runners[0]['runnerId'], 0);
    expect(runners[0]['role'], 'primary');
    expect(runners[0]['state'], 'idle');
    expect(runners[1]['runnerId'], 1);
    expect(runners[1]['role'], 'task');
    expect(runners[1]['state'], 'busy');
    expect(runners[1]['currentTaskId'], 'task-1');
    expect(runners[1]['tokensConsumed'], 150);

    final poolInfo = body['pool'] as Map<String, dynamic>;
    expect(poolInfo['size'], 2);
    expect(poolInfo['maxConcurrentTasks'], 1);
  });

  test('GET /api/agents/<id> returns single runner', () async {
    final body = await api.expectJsonObject('GET', '/api/agents/0');

    expect(body['runnerId'], 0);
    expect(body['role'], 'primary');
  });

  test('GET /api/agents/<id> returns 404 for out-of-range', () async {
    await api.expectResponse('GET', '/api/agents/99', status: 404);
  });

  test('GET /api/agents/<id> returns 400 for non-integer', () async {
    await api.expectResponse('GET', '/api/agents/abc', status: 400);
  });
}
