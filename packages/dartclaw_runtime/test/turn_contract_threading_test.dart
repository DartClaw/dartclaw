import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_runtime/src/web/session_usage.dart';
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

  TurnRunner buildRunner({
    GuardChain? guardChain,
    ContextMonitor? contextMonitor,
    AgentHarness? harness,
    TaskToolFilterGuard? taskToolFilterGuard,
    String providerId = 'claude',
  }) => TurnRunner(
    turnLimits: const TurnLimitsConfig.defaults(),
    harness: harness ?? worker,
    providerId: providerId,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: workspaceDir),
    sessions: sessions,
    turnState: turnState,
    kv: kvService,
    guardChain: guardChain,
    taskToolFilterGuard: taskToolFilterGuard,
    contextMonitor: contextMonitor,
  );

  /// Runs a schema-bearing turn on [harness] under an empty session allowlist and
  /// asks the installed tool filter how it would rule on Claude's
  /// schema-submission call while that turn still owns the policy.
  Future<GuardVerdict> claudeStructuredOutputVerdict(FakeAgentHarness harness) async {
    final toolFilter = TaskToolFilterGuard(denyEmptyAllowlist: true);
    final runner = buildRunner(harness: harness, taskToolFilterGuard: toolFilter);
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.reserveTurn(
      session.id,
      outputSchema: const {'type': 'object'},
      outputSchemaWhenSupported: true,
      allowedTools: const [],
    );
    runner.executeTurn(session.id, turnId, const [
      {'role': 'user', 'content': 'Return structured output'},
    ]);
    await harness.turnInvoked;
    final verdict = await toolFilter.evaluate(
      GuardContext(
        hookPoint: 'beforeToolCall',
        toolName: 'claude:StructuredOutput',
        rawProviderToolName: 'StructuredOutput',
        sessionId: session.id,
        timestamp: DateTime.now(),
      ),
    );
    harness.completeSuccess(turnResult());
    await runner.waitForOutcome(session.id, turnId);
    return verdict;
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_turn_contract_test_');
    final sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);
    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    worker = FakeAgentHarness();
    turnState = openTurnStateStore(p.join(tempDir.path, 'turn_state.json'));
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
  });

  tearDown(() async {
    await messages.dispose();
    await worker.dispose();
    await turnState.dispose();
    await kvService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('preserves the first provider written for a session cost record', () async {
    final codexWorker = FakeAgentHarness(supportsCostReporting: false, supportsCachedTokens: true);
    final claudeWorker = FakeAgentHarness();
    addTearDown(() async => codexWorker.dispose());
    addTearDown(() async => claudeWorker.dispose());
    final codexRunner = buildRunner(harness: codexWorker, providerId: 'codex');
    final claudeRunner = buildRunner(harness: claudeWorker, providerId: 'claude');
    final session = await sessions.getOrCreateMainSession();

    scheduleTurnCompletion(
      codexWorker,
      result: turnResult(inputTokens: 1, outputTokens: 1, totalCostUsd: 0.10, cachedInputTokens: 3),
    );
    final codexTurnId = await codexRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'codex'},
    ]);
    await codexRunner.waitForOutcome(session.id, codexTurnId);

    scheduleTurnCompletion(claudeWorker, result: turnResult(inputTokens: 2, outputTokens: 2, totalCostUsd: 0.20));
    final claudeTurnId = await claudeRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'claude'},
    ]);
    await claudeRunner.waitForOutcome(session.id, claudeTurnId);

    final costData = await readSessionCost(kvService, session.id);
    expect(costData['provider'], 'codex');
    expect(costData['cache_read_tokens'], 3);
    expect(costData['cost_reported_turn_count'], 1);
    expect(costData['turn_count'], 2);
    expect((await readSessionUsage(kvService, session.id)).estimatedCostUsd, isNull);
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

  test('S05 capability refusal names the harness at reservation while other failures stay generic', () async {
    final runner = buildRunner();
    final session = await sessions.getOrCreateMainSession();

    await expectLater(
      runner.reserveTurn(session.id, outputSchema: const {'type': 'object'}),
      throwsA(
        isA<UnsupportedHarnessCapabilityException>().having(
          (error) => error.toString(),
          'message',
          contains('FakeAgentHarness does not support structured output'),
        ),
      ),
    );

    scheduleTurnCompletion(worker, error: StateError('private provider detail'));
    final genericTurnId = await runner.startTurn(session.id, const [
      {'role': 'user', 'content': 'Fail generically'},
    ]);
    final generic = await runner.waitForOutcome(session.id, genericTurnId);
    final storedAssistant = (await messages.getMessages(session.id)).where((message) => message.role == 'assistant');
    expect(generic.errorMessage, 'Turn execution failed');
    expect(storedAssistant.map((message) => message.content), everyElement('[Turn failed]'));
  });

  test('a host-validated schema is dropped rather than refused when the harness cannot enforce it', () async {
    // The caller (logical agents, workflow steps) validates the result itself,
    // so the fail-closed refusal would cost it a provider it can still use.
    final runner = buildRunner();
    const schema = {'type': 'object'};
    final session = await sessions.getOrCreateMainSession();
    scheduleTurnCompletion(worker, responseText: '{"answer":"host-checked"}');

    final turnId = await runner.reserveTurn(session.id, outputSchema: schema, outputSchemaWhenSupported: true);
    runner.executeTurn(session.id, turnId, const [
      {'role': 'user', 'content': 'Return structured output'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(worker.lastOutputSchema, isNull);
  });

  test('a host-validated schema reaches a harness whose provider constrains the reply', () async {
    // Codex: the schema is applied on the wire but nothing typed comes back,
    // so the caller still reads the reply text it validates host-side.
    worker = FakeAgentHarness(supportsOutputSchemaConstraint: true);
    final runner = buildRunner();
    const schema = {'type': 'object'};
    final session = await sessions.getOrCreateMainSession();
    scheduleTurnCompletion(worker, responseText: '{"answer":"provider-constrained"}');

    final turnId = await runner.reserveTurn(session.id, outputSchema: schema, outputSchemaWhenSupported: true);
    runner.executeTurn(session.id, turnId, const [
      {'role': 'user', 'content': 'Return structured output'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(worker.lastOutputSchema, schema);
    expect(outcome.structuredOutput, isNull);
  });

  test('the structured-output tool exemption follows readback, not the presence of a schema', () async {
    // A constraint-only turn carries a schema too, but the exemption admits
    // Claude's submission protocol, which such a provider never speaks.
    final constraintOnly = FakeAgentHarness(supportsOutputSchemaConstraint: true);
    final readback = FakeAgentHarness(supportsStructuredOutput: true);
    addTearDown(() async => constraintOnly.dispose());
    addTearDown(() async => readback.dispose());

    expect((await claudeStructuredOutputVerdict(constraintOnly)).isBlock, isTrue);
    expect((await claudeStructuredOutputVerdict(readback)).isPass, isTrue);
  });

  test('a caller needing the typed payload is refused on a constraint-only harness', () async {
    // The harness would accept the schema and answer with text, so the caller
    // that needs a typed payload has to be refused here instead.
    worker = FakeAgentHarness(supportsOutputSchemaConstraint: true);
    final runner = buildRunner();
    final session = await sessions.getOrCreateMainSession();

    await expectLater(
      runner.reserveTurn(session.id, outputSchema: const {'type': 'object'}),
      throwsA(
        isA<UnsupportedHarnessCapabilityException>()
            .having((error) => error.provider, 'provider', 'FakeAgentHarness')
            .having((error) => error.capability, 'capability', AgentHarness.structuredOutputCapability),
      ),
    );

    // Admission was released, so an ordinary turn still runs on this session.
    scheduleTurnCompletion(worker, responseText: 'after the refusal');
    final turnId = await runner.startTurn(session.id, const [
      {'role': 'user', 'content': 'Plain turn'},
    ]);
    expect((await runner.waitForOutcome(session.id, turnId)).status, TurnStatus.completed);
  });

  test('a host-validated schema still reaches a harness that enforces it', () async {
    worker = FakeAgentHarness(supportsStructuredOutput: true);
    final runner = buildRunner();
    const schema = {
      'type': 'object',
      'properties': {
        'answer': {'type': 'string'},
      },
    };
    final session = await sessions.getOrCreateMainSession();
    scheduleTurnCompletion(worker, result: const TurnResult(structuredOutput: {'answer': 'provider-enforced'}));

    final turnId = await runner.reserveTurn(session.id, outputSchema: schema, outputSchemaWhenSupported: true);
    runner.executeTurn(session.id, turnId, const [
      {'role': 'user', 'content': 'Return structured output'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(worker.lastOutputSchema, schema);
    expect(outcome.responseText, '{"answer":"provider-enforced"}');
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
