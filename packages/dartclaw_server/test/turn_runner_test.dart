import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

TurnRunner _buildRunner({
  required AgentHarness harness,
  required MessageService messages,
  required String workspaceDir,
  required SessionService sessions,
  required TurnStateStore turnState,
  required KvService kvService,
  SessionResetService? resetService,
  String providerId = 'claude',
  Duration stallTimeout = Duration.zero,
  TurnProgressAction stallAction = TurnProgressAction.warn,
}) {
  return TurnRunner(
    harness: harness,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: workspaceDir),
    sessions: sessions,
    turnState: turnState,
    kv: kvService,
    resetService: resetService,
    providerId: providerId,
    stallTimeout: stallTimeout,
    stallAction: stallAction,
  );
}

Map<String, dynamic> _turnResult({
  int inputTokens = 0,
  int outputTokens = 0,
  double? totalCostUsd,
  int? cachedInputTokens,
  int? cacheWriteTokens,
}) {
  final result = <String, dynamic>{'input_tokens': inputTokens, 'output_tokens': outputTokens};
  if (totalCostUsd != null) {
    result['total_cost_usd'] = totalCostUsd;
  }
  if (cachedInputTokens != null) {
    result['cache_read_tokens'] = cachedInputTokens;
  }
  if (cacheWriteTokens != null) {
    result['cache_write_tokens'] = cacheWriteTokens;
  }
  return result;
}

void _scheduleTurnCompletion(
  FakeAgentHarness worker, {
  String responseText = '',
  Duration delay = Duration.zero,
  Map<String, dynamic>? result,
  Object? error,
}) {
  unawaited(() async {
    await worker.turnInvoked;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (error != null) {
      worker.completeError(error);
      return;
    }
    if (responseText.isNotEmpty) {
      worker.emit(DeltaEvent(responseText));
    }
    worker.completeSuccess(result ?? _turnResult());
  }());
}

Future<Map<String, dynamic>> _readSessionCost(KvService kvService, String sessionId) async {
  final raw = await kvService.get('session_cost:$sessionId');
  expect(raw, isNotNull);
  return jsonDecode(raw!) as Map<String, dynamic>;
}

class _RecordingSessionResetService extends SessionResetService {
  final List<String> touchedSessions = [];

  _RecordingSessionResetService({required super.sessions, required super.messages});

  @override
  void touchActivity(String sessionId) {
    touchedSessions.add(sessionId);
  }
}

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeAgentHarness worker;
  late TurnRunner runner;
  late Database turnStateDb;
  late TurnStateStore turnState;
  late KvService kvService;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_turn_runner_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    worker = FakeAgentHarness();
    turnStateDb = sqlite3.openInMemory();
    turnState = TurnStateStore(turnStateDb);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    runner = _buildRunner(
      harness: worker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
    );
  });

  tearDown(() async {
    await messages.dispose();
    await worker.dispose();
    await turnState.dispose();
    await kvService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('reserves turn and returns turnId', () async {
    final session = await sessions.getOrCreateMain();
    final turnId = await runner.reserveTurn(session.id);

    expect(turnId, isNotEmpty);
    expect(runner.isActive(session.id), isTrue);
    expect(runner.activeTurnId(session.id), turnId);
    expect(runner.activeSessionIds, contains(session.id));

    // Execute the turn to complete it properly (releaseTurn fires an error on
    // the outcome completer which propagates as an unhandled async error).
    _scheduleTurnCompletion(worker, responseText: 'ok');
    runner.executeTurn(session.id, turnId, [
      {'role': 'user', 'content': 'test'},
    ]);
    await runner.waitForOutcome(session.id, turnId);
  });

  test('executes turn and produces TurnOutcome.completed', () async {
    _scheduleTurnCompletion(worker, responseText: 'Hello from runner!');
    final session = await sessions.getOrCreateMain();
    await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Hi');

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Hi'},
    ]);

    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.responseText, 'Hello from runner!');
    expect(runner.isActive(session.id), isFalse);
  });

  test('handles agent failure and produces TurnOutcome.failed', () async {
    _scheduleTurnCompletion(worker, error: StateError('simulated crash'));
    final session = await sessions.getOrCreateMain();

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Will fail'},
    ]);

    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.failed);
    expect(runner.isActive(session.id), isFalse);
  });

  test('cancels active turn', () async {
    final session = await sessions.getOrCreateMain();

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Cancel me'},
    ]);

    await worker.turnInvoked;
    await runner.cancelTurn(session.id);

    final outcome = await runner.waitForOutcome(session.id, turnId);
    expect(outcome.status, TurnStatus.cancelled);
  });

  test('waitForOutcome returns completed outcome', () async {
    _scheduleTurnCompletion(worker, responseText: 'Done');
    final session = await sessions.getOrCreateMain();

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Test'},
    ]);

    final outcome = await runner.waitForOutcome(session.id, turnId);
    expect(outcome.status, TurnStatus.completed);
    expect(outcome.sessionId, session.id);
    expect(outcome.turnId, turnId);
  });

  test('harness getter returns the underlying harness', () {
    expect(runner.harness, same(worker));
  });

  test('releaseTurn removes persisted turn state and fails the pending outcome', () async {
    final session = await sessions.getOrCreateMain();
    final turnId = await runner.reserveTurn(session.id);

    expect((await turnState.getAll())[session.id]?.turnId, equals(turnId));

    final outcomeExpectation = runner
        .waitForOutcome(session.id, turnId)
        .then<void>(
          (_) => fail('Expected released turn to fail the pending outcome'),
          onError: (Object error, StackTrace _) {
            expect(
              error,
              isA<StateError>().having(
                (stateError) => stateError.message,
                'message',
                contains('released without execution'),
              ),
            );
          },
        );
    runner.releaseTurn(session.id, turnId);
    await Future<void>.delayed(Duration.zero);

    expect(runner.isActive(session.id), isFalse);
    expect(await turnState.getAll(), isNot(contains(session.id)));
    await outcomeExpectation;
  });

  test('persists and cleans turn state via store', () async {
    final session = await sessions.getOrCreateMain();
    _scheduleTurnCompletion(worker, responseText: 'Tracked', delay: const Duration(milliseconds: 100));

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Track turn state'},
    ]);

    final activeState = (await turnState.getAll())[session.id];
    expect(activeState, isNotNull);
    expect(activeState?.turnId, equals(turnId));
    expect(activeState?.startedAt, isA<DateTime>());

    final outcome = await runner.waitForOutcome(session.id, turnId);
    expect(outcome.status, TurnStatus.completed);
    expect(await turnState.getAll(), isNot(contains(session.id)));
  });

  test('persists usage even when the harness does not report USD cost', () async {
    final costWorker = FakeAgentHarness(supportsCostReporting: false);
    addTearDown(() async => costWorker.dispose());
    final costRunner = _buildRunner(
      harness: costWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
    );
    final session = await sessions.getOrCreateMain();
    _scheduleTurnCompletion(
      costWorker,
      responseText: 'No cost',
      result: _turnResult(inputTokens: 2, outputTokens: 3, totalCostUsd: 9.99),
    );

    final turnId = await costRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'Skip cost'},
    ]);

    final outcome = await costRunner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    final usageData = await _readSessionCost(kvService, session.id);
    expect(usageData.keys.toSet(), {
      'input_tokens',
      'output_tokens',
      'cache_read_tokens',
      'cache_write_tokens',
      'total_tokens',
      'effective_tokens',
      'estimated_cost_usd',
      'turn_count',
      'provider',
    });
    expect(usageData.containsKey('new_input_tokens'), isFalse);
    expect(usageData['provider'], 'claude');
    expect(usageData['input_tokens'], 2);
    expect(usageData['output_tokens'], 3);
    expect(usageData['total_tokens'], 5);
    expect(usageData['cache_read_tokens'], 0);
    expect(usageData['effective_tokens'], 5);
    expect((usageData['estimated_cost_usd'] as num).toDouble(), 0.0);
    expect(usageData['turn_count'], 1);
  });

  test('turn outcome carries cacheReadTokens when available', () async {
    final cachedWorker = FakeAgentHarness(supportsCachedTokens: true);
    addTearDown(() async => cachedWorker.dispose());
    final cachedRunner = _buildRunner(
      harness: cachedWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
    );
    final session = await sessions.getOrCreateMain();
    _scheduleTurnCompletion(
      cachedWorker,
      responseText: 'Cached',
      result: _turnResult(inputTokens: 1, outputTokens: 1, cachedInputTokens: 7),
    );

    final turnId = await cachedRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'Return cached tokens'},
    ]);

    final outcome = await cachedRunner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.cacheReadTokens, 7);
    // 1 + 1 + (0 * 125 ~/ 100 = 0) + (7 * 10 ~/ 100 = 0) = 2.
    expect(outcome.effectiveTokens, 2);
  });

  test('startTurn forwards maxTurns to the harness', () async {
    final boundedWorker = FakeAgentHarness();
    addTearDown(() async => boundedWorker.dispose());
    final boundedRunner = _buildRunner(
      harness: boundedWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
    );
    final session = await sessions.getOrCreateMain();
    _scheduleTurnCompletion(boundedWorker, responseText: 'bounded');

    final turnId = await boundedRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'Bound this turn'},
    ], maxTurns: 1);

    final outcome = await boundedRunner.waitForOutcome(session.id, turnId);
    expect(outcome.status, TurnStatus.completed);
    expect(boundedWorker.lastMaxTurns, 1);
  });

  test('persists provider and accumulates cached input tokens across turns', () async {
    final codexWorker = FakeAgentHarness(supportsCostReporting: false, supportsCachedTokens: true);
    addTearDown(() async => codexWorker.dispose());
    final codexRunner = _buildRunner(
      harness: codexWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
      providerId: 'codex',
    );
    final session = await sessions.getOrCreateMain();

    _scheduleTurnCompletion(codexWorker, result: _turnResult(inputTokens: 2, outputTokens: 1, cachedInputTokens: 5));
    final firstTurnId = await codexRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'first'},
    ]);
    await codexRunner.waitForOutcome(session.id, firstTurnId);

    _scheduleTurnCompletion(codexWorker, result: _turnResult(inputTokens: 3, outputTokens: 4, cachedInputTokens: 7));
    final secondTurnId = await codexRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'second'},
    ]);
    await codexRunner.waitForOutcome(session.id, secondTurnId);

    final costData = await _readSessionCost(kvService, session.id);
    expect(costData.keys.toSet(), {
      'input_tokens',
      'output_tokens',
      'cache_read_tokens',
      'cache_write_tokens',
      'total_tokens',
      'effective_tokens',
      'estimated_cost_usd',
      'turn_count',
      'provider',
    });
    expect(costData.containsKey('new_input_tokens'), isFalse);
    expect(costData['provider'], 'codex');
    expect(costData['input_tokens'], 5);
    expect(costData['output_tokens'], 5);
    expect(costData['total_tokens'], 10);
    expect(costData['cache_read_tokens'], 12);
    // Turn 1: 2+1+(5*0.1~/1=0) = 3. Turn 2: 3+4+(7*0.1~/1=0) = 7. Accumulated = 10.
    expect(costData['effective_tokens'], 10);
    expect((costData['estimated_cost_usd'] as num).toDouble(), 0.0);
    expect(costData['turn_count'], 2);
  });

  test('effective_tokens accumulates weighted cache-write and cache-read through _trackSessionUsage', () async {
    final cachedWorker = FakeAgentHarness(supportsCachedTokens: true);
    addTearDown(() async => cachedWorker.dispose());
    final cachedRunner = _buildRunner(
      harness: cachedWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
    );
    final session = await sessions.getOrCreateMain();
    // Values chosen so both weights produce non-zero integer contributions.
    _scheduleTurnCompletion(
      cachedWorker,
      result: _turnResult(inputTokens: 100, outputTokens: 50, cachedInputTokens: 1000, cacheWriteTokens: 200),
    );
    final turnId = await cachedRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'Exercise both cache weights'},
    ]);
    await cachedRunner.waitForOutcome(session.id, turnId);

    final costData = await _readSessionCost(kvService, session.id);
    // 100 + 50 + (200 * 125 ~/ 100 = 250) + (1000 * 10 ~/ 100 = 100) = 500
    expect(costData['effective_tokens'], 500);
    expect(costData['cache_read_tokens'], 1000);
    expect(costData['cache_write_tokens'], 200);
  });

  test('preserves the first provider written for a session cost record', () async {
    final codexWorker = FakeAgentHarness(supportsCostReporting: false, supportsCachedTokens: true);
    final claudeWorker = FakeAgentHarness();
    addTearDown(() async => codexWorker.dispose());
    addTearDown(() async => claudeWorker.dispose());
    final codexRunner = _buildRunner(
      harness: codexWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
      providerId: 'codex',
    );
    final claudeRunner = _buildRunner(
      harness: claudeWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
      providerId: 'claude',
    );
    final session = await sessions.getOrCreateMain();

    _scheduleTurnCompletion(
      codexWorker,
      result: _turnResult(inputTokens: 1, outputTokens: 1, totalCostUsd: 0.10, cachedInputTokens: 3),
    );
    final codexTurnId = await codexRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'codex'},
    ]);
    await codexRunner.waitForOutcome(session.id, codexTurnId);

    _scheduleTurnCompletion(claudeWorker, result: _turnResult(inputTokens: 2, outputTokens: 2, totalCostUsd: 0.20));
    final claudeTurnId = await claudeRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'claude'},
    ]);
    await claudeRunner.waitForOutcome(session.id, claudeTurnId);

    final costData = await _readSessionCost(kvService, session.id);
    expect(costData['provider'], 'codex');
    expect(costData['cache_read_tokens'], 3);
    expect(costData['turn_count'], 2);
  });

  test('defaults session cost provider to claude and treats missing cache_read_tokens as zero', () async {
    final session = await sessions.getOrCreateMain();

    _scheduleTurnCompletion(worker, result: _turnResult(inputTokens: 4, outputTokens: 6, totalCostUsd: 0.50));
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'default provider'},
    ]);
    await runner.waitForOutcome(session.id, turnId);

    final costData = await _readSessionCost(kvService, session.id);
    expect(costData['provider'], 'claude');
    expect(costData['cache_read_tokens'], 0);
  });

  test('tool call correlation produces ToolCallRecord with correct fields', () async {
    final session = await sessions.getOrCreateMain();

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(ToolUseEvent(toolName: 'bash', toolId: 'tu_1', input: {'command': 'ls'}));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      worker.emit(ToolResultEvent(toolId: 'tu_1', output: 'file.txt', isError: false));
      worker.completeSuccess(_turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'run tool'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.toolCalls, hasLength(1));
    expect(outcome.toolCalls[0].name, 'bash');
    expect(outcome.toolCalls[0].success, isTrue);
    expect(outcome.toolCalls[0].errorType, isNull);
    expect(outcome.toolCalls[0].durationMs, greaterThanOrEqualTo(0));
  });

  test('incomplete tool call produces ToolCallRecord with success: false and errorType: incomplete', () async {
    final session = await sessions.getOrCreateMain();

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(ToolUseEvent(toolName: 'bash', toolId: 'tu_orphan', input: {'command': 'sleep 999'}));
      // No ToolResultEvent — turn completes before tool returns.
      worker.completeSuccess(_turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'incomplete tool'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.toolCalls, hasLength(1));
    final record = outcome.toolCalls[0];
    expect(record.name, 'bash');
    expect(record.success, isFalse);
    expect(record.errorType, 'incomplete');
  });

  test('turnDuration is set on TurnOutcome', () async {
    final session = await sessions.getOrCreateMain();

    _scheduleTurnCompletion(worker, responseText: 'done', delay: const Duration(milliseconds: 5));

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'duration test'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.turnDuration.inMilliseconds, greaterThanOrEqualTo(0));
  });

  test('progress events reset session activity throughout a running turn', () async {
    final resetService = _RecordingSessionResetService(sessions: sessions, messages: messages);
    final resetAwareRunner = _buildRunner(
      harness: worker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
      resetService: resetService,
    );
    final session = await sessions.getOrCreateMain();

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(DeltaEvent('thinking'));
      worker.emit(ToolUseEvent(toolName: 'bash', toolId: 'tool-1', input: {'command': 'ls'}));
      worker.emit(ToolResultEvent(toolId: 'tool-1', output: 'ok', isError: false));
      worker.completeSuccess(_turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await resetAwareRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'keep the idle timer alive'},
    ]);
    final outcome = await resetAwareRunner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(
      resetService.touchedSessions,
      [session.id, session.id, session.id, session.id],
      reason: 'reserveTurn should touch once and every progress event should refresh activity',
    );
  });

  test('failed tool call produces ToolCallRecord with success: false and errorType: tool_error', () async {
    final session = await sessions.getOrCreateMain();

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(ToolUseEvent(toolName: 'bash', toolId: 'tu_err', input: {'command': 'bad'}));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      worker.emit(ToolResultEvent(toolId: 'tu_err', output: 'permission denied', isError: true));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      worker.completeSuccess(_turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'error tool'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.toolCalls, hasLength(1));
    final record = outcome.toolCalls[0];
    expect(record.name, 'bash');
    expect(record.success, isFalse);
    expect(record.errorType, 'tool_error');
  });

  test('progressEvents emits TextDelta, ToolStarted, ToolCompleted in correct order', () async {
    final session = await sessions.getOrCreateMain();
    final events = <TurnProgressEvent>[];
    final sub = runner.progressEvents.listen(events.add);
    addTearDown(sub.cancel);

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(DeltaEvent('hello'));
      worker.emit(ToolUseEvent(toolName: 'bash', toolId: 'tu_p1', input: {'command': 'ls'}));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      worker.emit(ToolResultEvent(toolId: 'tu_p1', output: 'ok', isError: false));
      worker.completeSuccess(_turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'progress test'},
    ]);
    await runner.waitForOutcome(session.id, turnId);

    expect(events, hasLength(3));
    expect(events[0], isA<TextDeltaProgressEvent>());
    expect((events[0] as TextDeltaProgressEvent).text, 'hello');
    expect(events[1], isA<ToolStartedProgressEvent>());
    expect((events[1] as ToolStartedProgressEvent).toolName, 'bash');
    expect((events[1] as ToolStartedProgressEvent).toolCallCount, 1);
    expect(events[2], isA<ToolCompletedProgressEvent>());
    expect((events[2] as ToolCompletedProgressEvent).toolName, 'bash');
    expect((events[2] as ToolCompletedProgressEvent).isError, isFalse);
  });

  test('progressEvents snapshot has correct textLength and toolCallCount', () async {
    final session = await sessions.getOrCreateMain();
    final events = <TurnProgressEvent>[];
    final sub = runner.progressEvents.listen(events.add);
    addTearDown(sub.cancel);

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(DeltaEvent('abc')); // 3 chars
      worker.emit(DeltaEvent('de')); // +2 = 5 chars
      worker.emit(ToolUseEvent(toolName: 'read', toolId: 'tu_s1', input: {}));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      worker.emit(ToolResultEvent(toolId: 'tu_s1', output: 'ok', isError: false));
      worker.emit(ToolUseEvent(toolName: 'write', toolId: 'tu_s2', input: {}));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      worker.emit(ToolResultEvent(toolId: 'tu_s2', output: 'ok', isError: false));
      worker.completeSuccess(_turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'snapshot test'},
    ]);
    await runner.waitForOutcome(session.id, turnId);

    // 2 deltas + 2 tool starts + 2 tool completes = 6 events
    expect(events, hasLength(6));

    // First delta: textLength=3, toolCallCount=0
    expect(events[0].snapshot.textLength, 3);
    expect(events[0].snapshot.toolCallCount, 0);

    // Second delta: textLength=5, toolCallCount=0
    expect(events[1].snapshot.textLength, 5);
    expect(events[1].snapshot.toolCallCount, 0);

    // First tool started: toolCallCount=1
    expect(events[2].snapshot.toolCallCount, 1);
    expect(events[2].snapshot.textLength, 5);

    // First tool completed: toolCallCount=1
    expect(events[3].snapshot.toolCallCount, 1);

    // Second tool started: toolCallCount=2
    expect(events[4].snapshot.toolCallCount, 2);

    // Second tool completed: toolCallCount=2
    expect(events[5].snapshot.toolCallCount, 2);
    expect(events[5].snapshot.textLength, 5);
  });

  test('progressEvents not emitted for unrelated events (SystemInitEvent)', () async {
    final session = await sessions.getOrCreateMain();
    final events = <TurnProgressEvent>[];
    final sub = runner.progressEvents.listen(events.add);
    addTearDown(sub.cancel);

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(SystemInitEvent(contextWindow: 200000));
      worker.emit(DeltaEvent('only'));
      worker.completeSuccess(_turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'init event test'},
    ]);
    await runner.waitForOutcome(session.id, turnId);

    expect(events, hasLength(1));
    expect(events[0], isA<TextDeltaProgressEvent>());
    expect((events[0] as TextDeltaProgressEvent).text, 'only');
  });

  // ---------------------------------------------------------------------------
  // Stall-timeout wiring — regression for 2026-04-24 E2E issue #9 where the
  // plan-review turn hung silently for 27 minutes while a Codex sub-agent
  // waited on shell verification. The stall monitor is supposed to surface
  // that silence; these tests pin the wiring so a regression flips from a
  // 75-minute E2E failure to a <2-second unit failure.
  // ---------------------------------------------------------------------------
  group('stall timeout', () {
    test('stallAction=cancel produces TurnStatus.cancelled when turn emits no progress', () async {
      final stallRunner = _buildRunner(
        harness: worker,
        messages: messages,
        workspaceDir: workspaceDir,
        sessions: sessions,
        turnState: turnState,
        kvService: kvService,
        stallTimeout: const Duration(milliseconds: 200),
        stallAction: TurnProgressAction.cancel,
      );

      // Never complete the worker turn — it's the hung-sub-agent case.
      // The turn invocation awaits indefinitely; only the stall monitor
      // surfaces the silence.
      final session = await sessions.getOrCreateMain();

      final turnId = await stallRunner.startTurn(session.id, [
        {'role': 'user', 'content': 'stall'},
      ]);

      final outcome = await stallRunner
          .waitForOutcome(session.id, turnId)
          .timeout(const Duration(seconds: 5), onTimeout: () => fail('Stall action=cancel did not cancel the turn'));

      expect(outcome.status, TurnStatus.cancelled);
      expect(stallRunner.isActive(session.id), isFalse);
    });

    test('stallAction=warn lets the turn complete normally once progress resumes', () async {
      final stallRunner = _buildRunner(
        harness: worker,
        messages: messages,
        workspaceDir: workspaceDir,
        sessions: sessions,
        turnState: turnState,
        kvService: kvService,
        stallTimeout: const Duration(milliseconds: 150),
        stallAction: TurnProgressAction.warn,
      );

      unawaited(() async {
        await worker.turnInvoked;
        // Sleep past the stall timeout without emitting events — expect a
        // warning log but no cancellation.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        worker.emit(DeltaEvent('finally some progress'));
        worker.completeSuccess(_turnResult(inputTokens: 1, outputTokens: 1));
      }());

      final session = await sessions.getOrCreateMain();
      final turnId = await stallRunner.startTurn(session.id, [
        {'role': 'user', 'content': 'warn only'},
      ]);

      final outcome = await stallRunner.waitForOutcome(session.id, turnId).timeout(const Duration(seconds: 5));

      expect(outcome.status, TurnStatus.completed);
      expect(outcome.responseText, 'finally some progress');
    });

    test('stallAction=cancel emits TurnStallProgressEvent before cancelling', () async {
      final stallRunner = _buildRunner(
        harness: worker,
        messages: messages,
        workspaceDir: workspaceDir,
        sessions: sessions,
        turnState: turnState,
        kvService: kvService,
        stallTimeout: const Duration(milliseconds: 120),
        stallAction: TurnProgressAction.cancel,
      );

      final stallEvents = <TurnStallProgressEvent>[];
      final sub = stallRunner.progressEvents.listen((event) {
        if (event is TurnStallProgressEvent) stallEvents.add(event);
      });
      addTearDown(sub.cancel);

      final session = await sessions.getOrCreateMain();
      final turnId = await stallRunner.startTurn(session.id, [
        {'role': 'user', 'content': 'stall with event'},
      ]);

      await stallRunner.waitForOutcome(session.id, turnId).timeout(const Duration(seconds: 5));

      expect(stallEvents, isNotEmpty, reason: 'stall monitor must emit TurnStallProgressEvent before cancelling');
      expect(stallEvents.first.action, 'cancel');
      expect(stallEvents.first.stallTimeout.inMilliseconds, greaterThanOrEqualTo(120));
    });
  });
}
