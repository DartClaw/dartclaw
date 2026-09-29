import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnRunner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'turn_runner_test_support.dart';

void main() {
  late Directory tempDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeAgentHarness worker;
  late TurnStateStore turnState;
  late KvService kvService;
  late TurnRunner runner;

  TurnRunner buildRunner() => TurnRunner(
    turnLimits: const TurnLimitsConfig.defaults(),
    harness: worker,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: workspaceDir),
    sessions: sessions,
    turnState: turnState,
    kv: kvService,
  );

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_turn_accounting_test_');
    final sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);
    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    worker = FakeAgentHarness();
    turnState = openTurnStateStore(p.join(tempDir.path, 'turn_state.json'));
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    runner = buildRunner();
  });

  tearDown(() async {
    await messages.dispose();
    await worker.dispose();
    await turnState.dispose();
    await kvService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('normalizes cumulative Claude snapshots before charging delegated work', () async {
    final session = await sessions.getOrCreateMainSession();
    TurnResult snapshot(int output, double cost, int rootOutput) => TurnResult(
      outputTokens: rootOutput,
      claudeUsageSnapshot: ClaudeUsageSnapshot(
        nativeSessionId: 'claude-native-1',
        models: {'root-and-delegates': ClaudeModelUsage(input: 2, output: output, cacheRead: 3, cacheWrite: 4)},
        totalCostUsd: cost,
      ),
    );

    scheduleTurnCompletion(worker, result: snapshot(41, 0.0760910, 10));
    final firstId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'First'},
    ]);
    final first = await runner.waitForOutcome(session.id, firstId);
    expect(first.outputTokens, 41);
    expect(first.tokenUsageComplete, isTrue);

    scheduleTurnCompletion(worker, result: snapshot(81, 0.0808288, 7));
    final secondId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Second'},
    ]);
    final second = await runner.waitForOutcome(session.id, secondId);
    expect(second.outputTokens, 40);
    expect(second.tokenUsageComplete, isTrue);
    final ledger = await readSessionCost(kvService, session.id);
    expect(ledger['output_tokens'], 81);
    expect(ledger['estimated_cost_usd'], closeTo(0.0808288, 0.000000001));
  });

  test('charges a delegate model first seen on a later native snapshot', () async {
    final session = await sessions.getOrCreateMainSession();
    TurnResult snapshot(Map<String, int> outputs, int rootOutput, double cost) => TurnResult(
      outputTokens: rootOutput,
      claudeUsageSnapshot: ClaudeUsageSnapshot(
        nativeSessionId: 'native-1',
        models: {
          for (final entry in outputs.entries)
            entry.key: ClaudeModelUsage(input: 0, output: entry.value, cacheRead: 0, cacheWrite: 0),
        },
        totalCostUsd: cost,
      ),
    );
    Future<TurnOutcome> run(TurnResult result) async {
      scheduleTurnCompletion(worker, result: result);
      final id = await runner.startTurn(session.id, [
        {'role': 'user', 'content': 'Measure'},
      ]);
      return runner.waitForOutcome(session.id, id);
    }

    await run(snapshot({'root': 100}, 100, 0.10));
    final second = await run(snapshot({'root': 120, 'delegate': 50}, 20, 0.17));
    expect(second.outputTokens, 70);
    expect(second.tokenUsageComplete, isTrue);
    final ledger = await readSessionCost(kvService, session.id);
    expect(ledger['output_tokens'], 170);
    expect(ledger['total_tokens'], 170);
    expect(ledger['estimated_cost_usd'], closeTo(0.17, 0.000000001));
    expect(ledger['token_usage_complete'], isTrue);
  });

  test('refuses provider dispatch when the pending accounting marker cannot persist', () async {
    final path = kvService.filePath;
    await kvService.dispose();
    kvService = _FailingAccountingKv(filePath: path);
    final failingKv = kvService as _FailingAccountingKv;
    runner = buildRunner();
    final session = await sessions.getOrCreateMainSession();
    const prior = '{"output_tokens":100,"total_tokens":100,"token_usage_complete":true,"last_accounted_turn_id":"T1"}';
    await kvService.set('session_cost:${session.id}', prior);
    failingKv.failWriteNumber = 2;
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Do work'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);
    expect(outcome.status, TurnStatus.failed);
    expect(outcome.errorMessage, contains('Accounting persistence failed before provider dispatch'));
    expect(worker.turnCallCount, 0);
    expect(await kvService.get('session_cost:${session.id}'), prior);
  });

  test('resumed legacy ledger uses a lower bound before a recoverable snapshot delta', () async {
    await worker.dispose();
    worker = FakeAgentHarness(supportsProviderSessionResume: true);
    runner = buildRunner();
    final session = await sessions.getOrCreateMainSession();
    await kvService.set(
      'session_cost:${session.id}',
      jsonEncode({'output_tokens': 408, 'total_tokens': 408, 'turn_count': 1}),
    );
    TurnResult snapshot(int output, int rootOutput, double cost) => TurnResult(
      outputTokens: rootOutput,
      claudeUsageSnapshot: ClaudeUsageSnapshot(
        nativeSessionId: 'native-1',
        models: {'model': ClaudeModelUsage(input: 0, output: output, cacheRead: 0, cacheWrite: 0)},
        totalCostUsd: cost,
      ),
    );
    Future<TurnOutcome> run(TurnResult result) async {
      scheduleTurnCompletion(worker, result: result);
      final id = await runner.reserveTurn(session.id, providerSessionId: 'native-1');
      runner.executeTurn(session.id, id, [
        {'role': 'user', 'content': 'Resume'},
      ]);
      return runner.waitForOutcome(session.id, id);
    }

    final first = await run(snapshot(537, 129, 0.0619837));
    expect(first.outputTokens, 129);
    expect(first.tokenUsageComplete, isFalse);
    final next = await run(snapshot(775, 238, 0.1106287));
    expect(next.outputTokens, 238);
    expect(next.tokenUsageComplete, isTrue);
    final ledger = await readSessionCost(kvService, session.id);
    expect(ledger['output_tokens'], 775);
    expect(ledger['token_usage_complete'], isFalse);
    expect(ledger['estimated_cost_usd'], closeTo(0.048645, 0.000000001));
    expect(ledger['cost_reported_turn_count'], 1);
  });

  test('decreasing or disappearing model counters cannot produce a full delta', () async {
    final session = await sessions.getOrCreateMainSession();
    TurnResult snapshot(Map<String, int> outputs, int rootOutput) => TurnResult(
      outputTokens: rootOutput,
      claudeUsageSnapshot: ClaudeUsageSnapshot(
        nativeSessionId: 'native-1',
        models: {
          for (final entry in outputs.entries)
            entry.key: ClaudeModelUsage(input: 0, output: entry.value, cacheRead: 0, cacheWrite: 0),
        },
        totalCostUsd: outputs.values.fold<int>(0, (sum, value) => sum + value) / 1000,
      ),
    );
    Future<TurnOutcome> run(TurnResult result) async {
      scheduleTurnCompletion(worker, result: result);
      final id = await runner.startTurn(session.id, [
        {'role': 'user', 'content': 'Measure'},
      ]);
      return runner.waitForOutcome(session.id, id);
    }

    expect((await run(snapshot({'root': 100, 'delegate': 20}, 100))).outputTokens, 120);
    final disappeared = await run(snapshot({'root': 130}, 30));
    expect(disappeared.outputTokens, 30);
    expect(disappeared.tokenUsageComplete, isFalse);
    final decreased = await run(snapshot({'root': 110}, 10));
    expect(decreased.outputTokens, 10);
    expect(decreased.tokenUsageComplete, isFalse);
    final recovered = await run(snapshot({'root': 120}, 10));
    expect(recovered.outputTokens, 10);
    expect(recovered.tokenUsageComplete, isTrue);
    expect((await readSessionCost(kvService, session.id))['token_usage_complete'], isFalse);
  });

  test('unusable cumulative cost does not make valid token deltas incomplete', () async {
    final session = await sessions.getOrCreateMainSession();
    TurnResult snapshot(int output, double cost) => TurnResult(
      outputTokens: output,
      claudeUsageSnapshot: ClaudeUsageSnapshot(
        nativeSessionId: 'native-1',
        models: {'model': ClaudeModelUsage(input: 0, output: output, cacheRead: 0, cacheWrite: 0)},
        totalCostUsd: cost,
      ),
    );
    Future<TurnOutcome> run(TurnResult result) async {
      scheduleTurnCompletion(worker, result: result);
      final id = await runner.startTurn(session.id, [
        {'role': 'user', 'content': 'Measure'},
      ]);
      return runner.waitForOutcome(session.id, id);
    }

    await run(snapshot(100, 0.1));
    final second = await run(snapshot(120, 0.09));
    expect(second.outputTokens, 20);
    expect(second.tokenUsageComplete, isTrue);
    final ledger = await readSessionCost(kvService, session.id);
    expect(ledger['output_tokens'], 120);
    expect(ledger['estimated_cost_usd'], 0.1);
    expect(ledger['cost_reported_turn_count'], 1);
    expect(ledger['token_usage_complete'], isTrue);
  });

  test('missing snapshot cannot make a later cumulative result look like a fresh turn', () async {
    final session = await sessions.getOrCreateMainSession();
    Future<TurnOutcome> run(TurnResult result) async {
      scheduleTurnCompletion(worker, result: result);
      final id = await runner.startTurn(session.id, [
        {'role': 'user', 'content': 'Measure'},
      ]);
      return runner.waitForOutcome(session.id, id);
    }

    await run(const TurnResult(outputTokens: 20));
    final next = await run(
      const TurnResult(
        outputTokens: 25,
        claudeUsageSnapshot: ClaudeUsageSnapshot(
          nativeSessionId: 'native-1',
          models: {'model': ClaudeModelUsage(input: 0, output: 170, cacheRead: 0, cacheWrite: 0)},
          totalCostUsd: 0.17,
        ),
      ),
    );
    expect(next.outputTokens, 25);
    expect(next.tokenUsageComplete, isFalse);
    expect((await readSessionCost(kvService, session.id))['output_tokens'], 45);
  });

  test('defaults session cost provider to claude and treats missing cache_read_tokens as zero', () async {
    final session = await sessions.getOrCreateMainSession();

    scheduleTurnCompletion(worker, result: turnResult(inputTokens: 4, outputTokens: 6, totalCostUsd: 0.50));
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'default provider'},
    ]);
    await runner.waitForOutcome(session.id, turnId);

    final costData = await readSessionCost(kvService, session.id);
    expect(costData['provider'], 'claude');
    expect(costData['cache_read_tokens'], 0);
  });
}

final class _FailingAccountingKv extends KvService {
  new({required super.filePath});

  int writeCount = 0;
  int? failWriteNumber;

  @override
  Future<void> set(String key, String value) {
    if (key.startsWith('session_cost:')) {
      writeCount++;
      if (writeCount == failWriteNumber) throw StateError('injected pending write failure');
    }
    return super.set(key, value);
  }
}
