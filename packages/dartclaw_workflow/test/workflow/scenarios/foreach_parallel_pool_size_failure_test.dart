import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory, HarnessFactoryConfig;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show DartclawRuntimeExecutionStack;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import '../../fixtures/e2e_fixture.dart';

// failure twin of: foreach_parallel_under_pool_size_3_test.dart
// scenario-types: foreach, parallel

void main() {
  test('pool_size 1 configures one worker lease without eager harness creation', () async {
    final fixture = await E2EFixture()
        .withProject('fixture-project', remote: 'https://example.invalid/fixture-project.git', credentials: null)
        .withProvider(value: 'claude', workflowModel: 'claude-opus-4')
        .withPoolSize(1)
        .build();
    addTearDown(fixture.dispose);

    final harnessFactory = HarnessFactory()..register('claude', (HarnessFactoryConfig _) => FakeAgentHarness());
    final runtime = await fixture.wire(harnessFactory: harnessFactory);
    addTearDown(runtime.shutdown);

    final capacity = runtime.requireExecutions.snapshot.providers['claude']!;
    expect(capacity.configured, 1);
    expect(capacity.active, 0);
    expect(capacity.cached, 0);
    expect(runtime.requireExecutions.runners, isEmpty);
  });
}
