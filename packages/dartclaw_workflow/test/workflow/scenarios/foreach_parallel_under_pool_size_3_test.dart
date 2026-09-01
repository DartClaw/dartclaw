import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory, HarnessFactoryConfig;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show DartclawRuntimeExecutionStack;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import '../../fixtures/e2e_fixture.dart';

// scenario-types: foreach, parallel

void main() {
  test('the headless runtime configures three lazy worker leases when pool_size is 3', () async {
    final fixture = await E2EFixture()
        .withProject('fixture-project', remote: 'https://example.invalid/fixture-project.git', credentials: null)
        .withProvider(value: 'claude', workflowModel: 'claude-opus-4')
        .withPoolSize(3)
        .build();
    addTearDown(fixture.dispose);

    final harnessFactory = HarnessFactory()..register('claude', (HarnessFactoryConfig _) => FakeAgentHarness());
    final runtime = await fixture.wire(harnessFactory: harnessFactory);
    addTearDown(runtime.shutdown);

    final capacity = runtime.requireExecutions.snapshot.providers['claude']!;
    expect(capacity.configured, 3);
    expect(capacity.available, 3);
    expect(capacity.cached, 0);
    expect(runtime.requireExecutions.runners, isEmpty);
  });
}
