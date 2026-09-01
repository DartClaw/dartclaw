import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/task/step_turn_runner.dart';
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import '../turn_runner_test_support.dart';

const _sessionId = 'step-session';
const _messages = [
  {'role': 'user', 'content': 'run the step'},
];
const _schema = {
  'type': 'object',
  'properties': {
    'merge': {'type': 'string'},
  },
};

typedef _Deps = ({TurnRunner runner, FakeAgentHarness harness, GuardChain chain});

_Deps _buildRunner({bool supportsStructuredOutput = false}) {
  final harness = FakeAgentHarness(
    promptStrategy: PromptStrategy.append,
    supportsStructuredOutput: supportsStructuredOutput,
  );
  final filter = TaskToolFilterGuard();
  final runner = TurnRunner(
    turnLimits: const TurnLimitsConfig.defaults(),
    harness: harness,
    messages: NoOpMessages(),
    behavior: BehaviorFileService(workspaceDir: '/tmp/dartclaw-step-turn-runner-test'),
    sessions: NoOpSessions(),
    taskToolFilterGuard: filter,
  );
  addTearDown(harness.dispose);
  return (runner: runner, harness: harness, chain: GuardChain(guards: [filter]));
}

Future<bool> _allows(GuardChain chain, String toolName) async =>
    (await chain.evaluateBeforeToolCall(toolName, const {}, sessionId: _sessionId)).isPass;

void main() {
  test('a step turn withholds the schema from a harness that cannot enforce it', () async {
    final deps = _buildRunner();
    final turn = StepTurnRunner(deps.runner)
        .runStepTurn(sessionId: _sessionId, messages: _messages, outputSchema: _schema);
    await deps.harness.turnInvoked;
    deps.harness.completeSuccess();

    expect((await turn).status, TurnStatus.completed);
    expect(deps.harness.lastOutputSchema, isNull);
  });

  test('a step turn forwards the schema to a harness that enforces it', () async {
    final deps = _buildRunner(supportsStructuredOutput: true);
    final turn = StepTurnRunner(deps.runner)
        .runStepTurn(sessionId: _sessionId, messages: _messages, outputSchema: _schema);
    await deps.harness.turnInvoked;
    deps.harness.completeSuccess();
    await turn;

    expect(deps.harness.lastOutputSchema, _schema);
  });

  test('a step turn leases the runner policy and returns its outcome unchanged', () async {
    final deps = _buildRunner();
    final turn = StepTurnRunner(deps.runner).runStepTurn(
      sessionId: _sessionId,
      messages: _messages,
      allowedTools: const ['file_read', 'file_write'],
      readOnly: true,
    );
    await deps.harness.turnInvoked;

    expect(await _allows(deps.chain, 'shell'), isFalse);
    expect(await _allows(deps.chain, 'file_read'), isTrue);
    expect(await _allows(deps.chain, 'file_write'), isFalse);

    deps.harness.completeSuccess(turnResult(inputTokens: 11, outputTokens: 7));
    final outcome = await turn;

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.inputTokens, 11);
    expect(outcome.outputTokens, 7);
    expect(await _allows(deps.chain, 'shell'), isTrue);
  });

  test('an external cancellation remains a cancelled outcome', () async {
    final deps = _buildRunner();
    final turn = StepTurnRunner(deps.runner).runStepTurn(sessionId: _sessionId, messages: _messages);
    await deps.harness.turnInvoked;
    await deps.runner.cancelTurn(_sessionId);

    expect((await turn).status, TurnStatus.cancelled);
  });

  test('a provider failure remains a failed outcome', () async {
    final deps = _buildRunner();
    final turn = StepTurnRunner(deps.runner).runStepTurn(sessionId: _sessionId, messages: _messages);
    await deps.harness.turnInvoked;
    deps.harness.completeError(const ProcessOutputLimitException(streamName: 'stdout', maxBytes: 4096));

    final outcome = await turn;
    expect(outcome.status, TurnStatus.failed);
    expect(outcome.errorMessage, allOf(contains('stdout'), contains('4096')));
  });
}
