import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('FakeAgentHarness', () {
    test('records turn inputs and completes successfully', () async {
      final harness = FakeAgentHarness(supportsProviderSessionResume: true);
      final turnFuture = harness.turn(
        sessionId: 'session-1',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        systemPrompt: 'system prompt',
        mcpServers: const {
          'calendar': {'command': 'fake'},
        },
        providerSessionId: 'provider-session-1',
        requestProviderSessionResume: true,
        directory: '/tmp/workspace',
        model: 'sonnet',
      );

      await harness.turnInvoked;
      harness.completeSuccess(const TurnResult(stopReason: 'completed', inputTokens: 7, outputTokens: 3));

      final result = await turnFuture;
      expect(result.stopReason, 'completed');
      expect(result.inputTokens, 7);
      expect(result.outputTokens, 3);
      expect(harness.turnCallCount, 1);
      expect(harness.lastSessionId, 'session-1');
      expect(harness.lastMessages, const [
        {'role': 'user', 'content': 'hello'},
      ]);
      expect(harness.lastSystemPrompt, 'system prompt');
      expect(harness.lastMcpServers, const {
        'calendar': {'command': 'fake'},
      });
      expect(harness.lastProviderSessionId, 'provider-session-1');
      expect(harness.lastRequestProviderSessionResume, isTrue);
      expect(harness.lastDirectory, '/tmp/workspace');
      expect(harness.lastModel, 'sonnet');
      expect(harness.state, WorkerState.idle);
    });

    test('cancel marks flag and fails the pending turn', () async {
      final harness = FakeAgentHarness();
      final turnFuture = harness.turn(sessionId: 'session-1', messages: const [], systemPrompt: 'system prompt');

      await harness.turnInvoked;
      final errorExpectation = expectLater(turnFuture, throwsA(isA<StateError>()));
      await harness.cancel();

      expect(harness.cancelCalled, isTrue);
      expect(harness.state, WorkerState.idle);
      await errorExpectation;
    });

    test('refuses provider-session resume inputs when capability is false', () async {
      final harness = FakeAgentHarness();

      for (final input in [
        (providerSessionId: 'provider-1', requestProviderSessionResume: false),
        (providerSessionId: null, requestProviderSessionResume: true),
      ]) {
        await expectLater(
          harness.turn(
            sessionId: 'session-1',
            messages: const [],
            systemPrompt: '',
            providerSessionId: input.providerSessionId,
            requestProviderSessionResume: input.requestProviderSessionResume,
          ),
          throwsA(
            isA<UnsupportedHarnessCapabilityException>()
                .having((error) => error.provider, 'provider', 'FakeAgentHarness')
                .having((error) => error.capability, 'capability', AgentHarness.providerSessionResumeCapability),
          ),
        );
      }
    });

    test('supports emitted bridge events and lifecycle flags', () async {
      final harness = FakeAgentHarness(promptStrategy: PromptStrategy.append, initialState: WorkerState.stopped);
      final eventsFuture = expectLater(harness.events, emitsInOrder(<Object>[DeltaEvent('hello'), emitsDone]));

      await harness.start();
      expect(harness.startCalled, isTrue);
      expect(harness.promptStrategy, PromptStrategy.append);
      expect(harness.state, WorkerState.idle);

      harness.emit(DeltaEvent('hello'));
      await harness.dispose();

      expect(harness.disposeCalled, isTrue);
      expect(harness.state, WorkerState.stopped);
      await eventsFuture;
    });

    test('stop marks the harness stopped', () async {
      final harness = FakeAgentHarness(initialState: WorkerState.busy);

      await harness.stop();

      expect(harness.stopCalled, isTrue);
      expect(harness.state, WorkerState.stopped);
    });
  });
}
