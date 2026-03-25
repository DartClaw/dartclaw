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
  String providerId = 'claude',
}) {
  return TurnRunner(
    harness: harness,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: workspaceDir),
    sessions: sessions,
    turnState: turnState,
    kv: kvService,
    providerId: providerId,
  );
}

Map<String, dynamic> _turnResult({
  int inputTokens = 0,
  int outputTokens = 0,
  double? totalCostUsd,
  int? cachedInputTokens,
}) {
  final result = <String, dynamic>{'input_tokens': inputTokens, 'output_tokens': outputTokens};
  if (totalCostUsd != null) {
    result['total_cost_usd'] = totalCostUsd;
  }
  if (cachedInputTokens != null) {
    result['cache_read_tokens'] = cachedInputTokens;
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
    expect(usageData['provider'], 'claude');
    expect(usageData['input_tokens'], 2);
    expect(usageData['output_tokens'], 3);
    expect(usageData['total_tokens'], 5);
    expect(usageData['cache_read_tokens'], 0);
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
    expect(costData['provider'], 'codex');
    expect(costData['input_tokens'], 5);
    expect(costData['output_tokens'], 5);
    expect(costData['total_tokens'], 10);
    expect(costData['cache_read_tokens'], 12);
    expect((costData['estimated_cost_usd'] as num).toDouble(), 0.0);
    expect(costData['turn_count'], 2);
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
}
