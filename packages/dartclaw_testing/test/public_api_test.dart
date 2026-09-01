import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  test('public library exposes shared doubles for core and kernel boundaries', () {
    final harness = FakeAgentHarness(initialState: WorkerState.idle, promptStrategy: PromptStrategy.append);
    final channel = FakeChannel(type: ChannelType.signal);
    final guard = FakeGuard.block('blocked');
    final jwtVerifier = FakeGoogleJwtVerifier();
    final channelManager = FakeChannelManager();
    final classifier = FakeContentClassifier();
    final tasks = InMemoryTaskRepository();
    final workflowSteps = InMemoryWorkflowStepExecutionRepository();

    expect(harness.state, WorkerState.idle);
    expect(channel.type, ChannelType.signal);
    expect(guard.evaluate, isNotNull);
    expect(jwtVerifier.shouldVerify, isTrue);
    expect(channelManager.received, isEmpty);
    expect(classifier.result, 'safe');
    expect(tasks, isA<TaskRepository>());
    expect(workflowSteps, isA<WorkflowStepExecutionRepository>());
  });
}
