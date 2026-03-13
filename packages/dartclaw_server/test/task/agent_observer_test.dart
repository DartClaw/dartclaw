import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  late HarnessPool pool;
  late EventBus eventBus;
  late AgentObserver observer;

  setUp(() {
    final runners = [_FakeRunner(), _FakeRunner(), _FakeRunner()];
    pool = HarnessPool(runners: runners);
    eventBus = EventBus();
    observer = AgentObserver(pool: pool, eventBus: eventBus);
  });

  tearDown(() {
    observer.dispose();
    eventBus.dispose();
  });

  test('initializes metrics for all runners', () {
    final metrics = observer.metrics;
    expect(metrics, hasLength(3));
    expect(metrics[0].runnerId, 0);
    expect(metrics[0].role, 'primary');
    expect(metrics[0].state, AgentState.idle);
    expect(metrics[1].runnerId, 1);
    expect(metrics[1].role, 'task');
    expect(metrics[2].runnerId, 2);
    expect(metrics[2].role, 'task');
  });

  test('markBusy sets state and task ID', () {
    observer.markBusy(1, taskId: 'task-abc');
    final m = observer.metricsFor(1)!;
    expect(m.state, AgentState.busy);
    expect(m.currentTaskId, 'task-abc');
  });

  test('markIdle clears state and task ID', () {
    observer.markBusy(1, taskId: 'task-abc');
    observer.markIdle(1);
    final m = observer.metricsFor(1)!;
    expect(m.state, AgentState.idle);
    expect(m.currentTaskId, isNull);
    expect(m.currentSessionId, isNull);
  });

  test('recordTurn increments counters', () {
    observer.recordTurn(1, inputTokens: 100, outputTokens: 50, isError: false);
    observer.recordTurn(1, inputTokens: 200, outputTokens: 100, isError: true);
    final m = observer.metricsFor(1)!;
    expect(m.tokensConsumed, 450);
    expect(m.turnsCompleted, 2);
    expect(m.errorCount, 1);
  });

  test('metricsFor returns null for out-of-range index', () {
    expect(observer.metricsFor(-1), isNull);
    expect(observer.metricsFor(99), isNull);
  });

  test('out-of-range markBusy/markIdle/recordTurn are no-ops', () {
    observer.markBusy(-1, taskId: 'x');
    observer.markIdle(99);
    observer.recordTurn(99, inputTokens: 1, outputTokens: 1, isError: false);
    // No crash, metrics unchanged
    expect(observer.metrics.every((m) => m.state == AgentState.idle), isTrue);
  });

  test('poolStatus delegates to HarnessPool', () {
    final status = observer.poolStatus;
    expect(status.size, 3);
    expect(status.maxConcurrentTasks, 2);
    expect(status.activeCount, 0);
    expect(status.availableCount, 2);
  });

  test('fires AgentStateChangedEvent on markBusy', () async {
    final events = <AgentStateChangedEvent>[];
    eventBus.on<AgentStateChangedEvent>().listen(events.add);

    observer.markBusy(1, taskId: 'task-1');

    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events[0].runnerId, 1);
    expect(events[0].state, 'busy');
    expect(events[0].currentTaskId, 'task-1');
  });

  test('fires AgentStateChangedEvent on markIdle', () async {
    final events = <AgentStateChangedEvent>[];
    eventBus.on<AgentStateChangedEvent>().listen(events.add);

    observer.markBusy(2, taskId: 'task-2');
    observer.markIdle(2);

    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(2));
    expect(events[1].state, 'idle');
    expect(events[1].currentTaskId, isNull);
  });

  test('toJson produces correct structure', () {
    observer.markBusy(1, taskId: 'task-x', sessionId: 'session-y');
    observer.recordTurn(1, inputTokens: 500, outputTokens: 300, isError: false);
    final json = observer.metricsFor(1)!.toJson();
    expect(json['runnerId'], 1);
    expect(json['role'], 'task');
    expect(json['state'], 'busy');
    expect(json['currentTaskId'], 'task-x');
    expect(json['currentSessionId'], 'session-y');
    expect(json['tokensConsumed'], 800);
    expect(json['turnsCompleted'], 1);
    expect(json['errorCount'], 0);
  });
}

class _FakeRunner extends TurnRunner {
  _FakeRunner()
    : super(
        harness: _MinimalHarness(),
        messages: _NoOpMessages(),
        behavior: BehaviorFileService(workspaceDir: '/tmp/agent-observer-test'),
        sessions: _NoOpSessions(),
      );
}

class _MinimalHarness implements AgentHarness {
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
