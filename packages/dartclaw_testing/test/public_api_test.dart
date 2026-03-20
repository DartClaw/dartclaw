import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  test('public library re-exports core and security types used by test doubles', () {
    final harness = FakeAgentHarness(initialState: WorkerState.idle, promptStrategy: PromptStrategy.append);
    final channel = FakeChannel(type: ChannelType.signal);
    final guard = FakeGuard.block('blocked');

    expect(harness.state, WorkerState.idle);
    expect(channel.type, ChannelType.signal);
    expect(guard.evaluate, isNotNull);
  });
}
