import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  test('public library re-exports core and security types used by test doubles', () {
    final harness = FakeAgentHarness(initialState: WorkerState.idle, promptStrategy: PromptStrategy.append);
    final channel = FakeChannel(type: ChannelType.signal);
    final guard = FakeGuard.block('blocked');
    final repo = InMemoryAgentExecutionRepository();
    final channelManager = FakeChannelManager();
    final classifier = FakeContentClassifier();
    final introspector = FakeSkillIntrospector(const {});
    final authPreflight = FakeProviderAuthPreflight();

    expect(harness.state, WorkerState.idle);
    expect(channel.type, ChannelType.signal);
    expect(guard.evaluate, isNotNull);
    expect(repo, isA<AgentExecutionRepository>());
    expect(channelManager.received, isEmpty);
    expect(classifier.result, 'safe');
    expect(introspector.calls, isEmpty);
    expect(authPreflight.probed, isEmpty);
  });
}
