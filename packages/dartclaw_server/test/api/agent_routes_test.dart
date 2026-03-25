import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late HarnessPool pool;
  late AgentObserver observer;
  late Handler handler;

  setUp(() {
    final runners = [_FakeRunner(), _FakeRunner()];
    pool = HarnessPool(runners: runners);
    observer = AgentObserver(pool: pool);
    handler = agentRoutes(observer).call;
  });

  tearDown(() {
    observer.dispose();
  });

  test('GET /api/agents returns all runners and pool status', () async {
    observer.markBusy(1, taskId: 'task-1');
    observer.recordTurn(1, inputTokens: 100, outputTokens: 50, isError: false);

    final request = Request('GET', Uri.parse('http://localhost/api/agents'));
    final response = await handler(request);

    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
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
    final request = Request('GET', Uri.parse('http://localhost/api/agents/0'));
    final response = await handler(request);

    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    expect(body['runnerId'], 0);
    expect(body['role'], 'primary');
  });

  test('GET /api/agents/<id> returns 404 for out-of-range', () async {
    final request = Request('GET', Uri.parse('http://localhost/api/agents/99'));
    final response = await handler(request);

    expect(response.statusCode, 404);
  });

  test('GET /api/agents/<id> returns 400 for non-integer', () async {
    final request = Request('GET', Uri.parse('http://localhost/api/agents/abc'));
    final response = await handler(request);

    expect(response.statusCode, 400);
  });
}

class _FakeRunner extends TurnRunner {
  _FakeRunner()
    : super(
        harness: _MinimalHarness(),
        messages: _NoOpMessages(),
        behavior: BehaviorFileService(workspaceDir: '/tmp/agent-routes-test'),
        sessions: _NoOpSessions(),
      );
}

class _MinimalHarness implements AgentHarness {
  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;
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

class _NoOpMessages implements MessageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoOpSessions implements SessionService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
