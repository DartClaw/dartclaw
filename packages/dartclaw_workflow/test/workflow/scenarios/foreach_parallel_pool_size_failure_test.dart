import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory, HarnessFactoryConfig;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import '../../fixtures/e2e_fixture.dart';

// failure twin of: foreach_parallel_under_pool_size_3_test.dart
// scenario-types: foreach, parallel

void main() {
  test('pool_size 1 constrains availableCount to 1 (regression: always-pool-of-3 bug)', () async {
    final fixture = await E2EFixture()
        .withProject(
          'fixture-project',
          remote: 'https://example.invalid/fixture-project.git',
          credentials: null,
        )
        .withProvider(value: 'claude', workflowModel: 'claude-opus-4')
        .withPoolSize(1)
        .build();
    addTearDown(fixture.dispose);

    final harnessFactory = HarnessFactory()..register('claude', (HarnessFactoryConfig _) => FakeAgentHarness());
    final wiring = await fixture.wire(harnessFactory: harnessFactory);
    addTearDown(wiring.dispose);

    // If always-pool-of-3 bug were present, availableCount would be 3.
    // A correctly configured pool_size=1 must report availableCount=1.
    expect(wiring.pool.availableCount, 1);
    expect(wiring.pool.availableCount, isNot(3));
  });
}
