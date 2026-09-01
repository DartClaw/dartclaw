import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnRunner;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'turn_runner_test_support.dart';

void main() {
  late Directory tempDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeAgentHarness worker;
  late Database turnStateDb;
  late TurnStateStore turnState;
  late KvService kvService;

  TurnRunner buildRunner({GuardChain? guardChain, ContextMonitor? contextMonitor}) => TurnRunner(
    turnLimits: const TurnLimitsConfig.defaults(),
    harness: worker,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: workspaceDir),
    sessions: sessions,
    turnState: turnState,
    kv: kvService,
    guardChain: guardChain,
    contextMonitor: contextMonitor,
  );

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_turn_contract_test_');
    final sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);
    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    worker = FakeAgentHarness();
    turnStateDb = sqlite3.openInMemory();
    turnState = TurnStateStore(turnStateDb);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
  });

  tearDown(() async {
    await messages.dispose();
    await worker.dispose();
    await turnState.dispose();
    await kvService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('S01/S03 reservation inputs reach the harness and completed outcome', () async {
    worker = FakeAgentHarness(supportsStructuredOutput: true, supportsProviderSessionResume: true);
    final runner = buildRunner();
    const schema = {
      'type': 'object',
      'properties': {
        'answer': {'type': 'string'},
      },
      'required': ['answer'],
      'additionalProperties': false,
    };
    const payload = {'answer': 'guarded'};
    scheduleTurnCompletion(
      worker,
      responseText: 'guarded',
      result: const TurnResult(structuredOutput: payload, providerSessionId: 'provider-session-x'),
    );
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.reserveTurn(
      session.id,
      outputSchema: schema,
      providerSessionId: 'provider-session-x',
      requestProviderSessionResume: true,
    );
    runner.executeTurn(session.id, turnId, const [
      {'role': 'user', 'content': 'Return structured output'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(worker.lastOutputSchema, same(schema));
    expect(worker.lastProviderSessionId, 'provider-session-x');
    expect(worker.lastRequestProviderSessionResume, isTrue);
    expect(outcome.status, TurnStatus.completed);
    expect(outcome.structuredOutput, same(payload));
    expect(outcome.providerSessionId, 'provider-session-x');
  });

  test('S02 guard-blocked response exposes neither structured output nor provider session', () async {
    worker = FakeAgentHarness(supportsStructuredOutput: true, supportsProviderSessionResume: true);
    const payload = {'answer': 'must not escape'};
    final runner = buildRunner(
      guardChain: GuardChain(
        guards: [
          FakeGuard(
            evaluator: (context) =>
                context.hookPoint == 'beforeAgentSend' && context.messageContent == jsonEncode(payload)
                ? GuardVerdict.block('blocked response')
                : GuardVerdict.pass(),
          ),
        ],
      ),
    );
    const schema = {'type': 'object'};
    scheduleTurnCompletion(
      worker,
      result: const TurnResult(structuredOutput: payload, providerSessionId: 'provider-session-x'),
    );
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.reserveTurn(
      session.id,
      outputSchema: schema,
      providerSessionId: 'provider-session-x',
      requestProviderSessionResume: true,
    );
    runner.executeTurn(session.id, turnId, const [
      {'role': 'user', 'content': 'Return blocked output'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.failed);
    expect(outcome.structuredOutput, isNull);
    expect(outcome.providerSessionId, isNull);
  });

  test('S01 payload-only result passes its structured output through the guard', () async {
    worker = FakeAgentHarness(supportsStructuredOutput: true, supportsProviderSessionResume: true);
    const payload = {'answer': 'guarded'};
    String? guardedContent;
    final runner = buildRunner(
      guardChain: GuardChain(
        guards: [
          FakeGuard(
            evaluator: (context) {
              if (context.hookPoint == 'beforeAgentSend') guardedContent = context.messageContent;
              return GuardVerdict.pass();
            },
          ),
        ],
      ),
    );
    scheduleTurnCompletion(
      worker,
      result: const TurnResult(structuredOutput: payload, providerSessionId: 'provider-session-x'),
    );
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.reserveTurn(session.id, outputSchema: const {'type': 'object'});
    runner.executeTurn(session.id, turnId, const [
      {'role': 'user', 'content': 'Return structured output'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);
    final transcript = await messages.getMessages(session.id);
    final encodedPayload = jsonEncode(payload);

    expect(guardedContent, encodedPayload);
    expect(transcript.single.content, encodedPayload);
    expect(outcome.status, TurnStatus.completed);
    expect(outcome.responseText, encodedPayload);
    expect(outcome.structuredOutput, same(payload));
    expect(outcome.providerSessionId, 'provider-session-x');
  });

  test('S04 provider failure retains the provider session id', () async {
    worker = FakeAgentHarness(supportsProviderSessionResume: true);
    final runner = buildRunner();
    scheduleTurnCompletion(
      worker,
      result: const TurnResult(stopReason: 'error', error: 'provider failure', providerSessionId: 'provider-session-x'),
    );
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.reserveTurn(
      session.id,
      providerSessionId: 'provider-session-x',
      requestProviderSessionResume: true,
    );
    runner.executeTurn(session.id, turnId, const [
      {'role': 'user', 'content': 'Continue'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.failed);
    expect(outcome.errorMessage, 'provider failure');
    expect(outcome.providerSessionId, 'provider-session-x');
    expect(outcome.structuredOutput, isNull);
  });

  test('TI03 provider cancellation retains the provider session id but no payload', () async {
    worker = FakeAgentHarness(supportsProviderSessionResume: true);
    final runner = buildRunner();
    scheduleTurnCompletion(
      worker,
      result: const TurnResult(
        stopReason: 'cancelled',
        providerSessionId: 'provider-session-x',
        structuredOutput: {'answer': 'incomplete'},
      ),
    );
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.reserveTurn(
      session.id,
      providerSessionId: 'provider-session-x',
      requestProviderSessionResume: true,
    );
    runner.executeTurn(session.id, turnId, const [
      {'role': 'user', 'content': 'Continue'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.cancelled);
    expect(outcome.providerSessionId, 'provider-session-x');
    expect(outcome.structuredOutput, isNull);
  });

  test('S05 capability refusal survives the runner catch while other failures stay generic', () async {
    final runner = buildRunner();
    const schema = {'type': 'object'};
    final session = await sessions.getOrCreateMainSession();

    final refusedTurnId = await runner.reserveTurn(session.id, outputSchema: schema);
    runner.executeTurn(session.id, refusedTurnId, const [
      {'role': 'user', 'content': 'Return structured output'},
    ]);
    final refused = await runner.waitForOutcome(session.id, refusedTurnId);
    expect(refused.status, TurnStatus.failed);
    expect(refused.errorMessage, contains('FakeAgentHarness does not support structured output'));

    scheduleTurnCompletion(worker, error: StateError('private provider detail'));
    final genericTurnId = await runner.startTurn(session.id, const [
      {'role': 'user', 'content': 'Fail generically'},
    ]);
    final generic = await runner.waitForOutcome(session.id, genericTurnId);
    final storedAssistant = (await messages.getMessages(session.id)).where((message) => message.role == 'assistant');
    expect(generic.errorMessage, 'Turn execution failed');
    expect(storedAssistant.map((message) => message.content), everyElement('[Turn failed]'));
  });

  test('a turn that outran its provider backstop says so instead of failing generically', () async {
    // The remedy for a timeout is a budget, not a retry, and the two are
    // indistinguishable to an operator when both read "Turn execution failed" —
    // which is what left the 0.25 live gate reconstructing the cause from raw
    // harness logs.
    final runner = buildRunner();
    final session = await sessions.getOrCreateMainSession();

    scheduleTurnCompletion(worker, error: TimeoutException('Claude turn exceeded 0:10:00.000000'));
    final turnId = await runner.startTurn(session.id, const [
      {'role': 'user', 'content': 'Run long'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.failed);
    expect(outcome.errorMessage, 'Claude turn exceeded 0:10:00.000000');
  });

  test('S06 schema-free reservation keeps both outcome fields absent', () async {
    final runner = buildRunner();
    scheduleTurnCompletion(worker, responseText: 'ordinary');
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.startTurn(session.id, const [
      {'role': 'user', 'content': 'Ordinary turn'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(worker.lastOutputSchema, isNull);
    expect(worker.lastProviderSessionId, isNull);
    expect(worker.lastRequestProviderSessionResume, isFalse);
    expect(outcome.structuredOutput, isNull);
    expect(outcome.providerSessionId, isNull);
  });

  test('S06 pre-compaction flush inherits neither provider input', () async {
    worker = FakeAgentHarness(supportsStructuredOutput: true, supportsProviderSessionResume: true);
    final contextMonitor = ContextMonitor(reserveTokens: 20)..update(contextWindow: 100);
    final runner = buildRunner(contextMonitor: contextMonitor);
    const schema = {'type': 'object'};
    Map<String, dynamic>? mainSchema;
    String? mainProviderSessionId;
    bool? mainRequestedResume;
    Map<String, dynamic>? flushSchema;
    String? flushProviderSessionId;
    bool? flushRequestedResume;
    unawaited(() async {
      await worker.turnInvoked;
      mainSchema = worker.lastOutputSchema;
      mainProviderSessionId = worker.lastProviderSessionId;
      mainRequestedResume = worker.lastRequestProviderSessionResume;
      worker.emit(DeltaEvent('structured'));
      worker.completeSuccess(
        const TurnResult(
          structuredOutput: {'answer': 'guarded'},
          providerSessionId: 'provider-session-x',
          inputTokens: 90,
        ),
      );
      await worker.turnInvoked;
      flushSchema = worker.lastOutputSchema;
      flushProviderSessionId = worker.lastProviderSessionId;
      flushRequestedResume = worker.lastRequestProviderSessionResume;
      worker.completeSuccess();
    }());
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.reserveTurn(
      session.id,
      outputSchema: schema,
      providerSessionId: 'provider-session-x',
      requestProviderSessionResume: true,
    );
    runner.executeTurn(session.id, turnId, const [
      {'role': 'user', 'content': 'Return structured output'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(mainSchema, same(schema));
    expect(mainProviderSessionId, 'provider-session-x');
    expect(mainRequestedResume, isTrue);
    expect(flushSchema, isNull);
    expect(flushProviderSessionId, isNull);
    expect(flushRequestedResume, isFalse);
    expect(outcome.structuredOutput, {'answer': 'guarded'});
    expect(outcome.providerSessionId, 'provider-session-x');
  });
}
