import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory, HarnessFactoryConfig;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import '../../fixtures/e2e_fixture.dart';

// scenario-types: foreach, parallel

void main() {
  test('CliWorkflowWiring eagerly spawns three task runners when pool_size is 3', () async {
    final fixture = await E2EFixture()
        .withProject(
          'fixture-project',
          remote: 'https://example.invalid/fixture-project.git',
          credentials: null,
        )
        .withProvider(value: 'claude', workflowModel: 'claude-opus-4')
        .withPoolSize(3)
        .build();
    addTearDown(fixture.dispose);

    final harnessFactory = HarnessFactory()..register('claude', (HarnessFactoryConfig _) => FakeAgentHarness());
    final wiring = await fixture.wire(harnessFactory: harnessFactory);
    addTearDown(wiring.dispose);

    expect(wiring.pool.runners.skip(1), hasLength(3));
    expect(wiring.pool.availableCount, 3);
  });
}
