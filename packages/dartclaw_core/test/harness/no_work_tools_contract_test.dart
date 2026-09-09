import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  test('an unqualified harness refuses an explicit empty work-tool policy under the configured provider name', () {
    final harness = FakeAgentHarness();

    expect(
      () => AgentHarness.requireNoWorkToolsSupport(harness, provider: 'codex-alias', emptyToolPolicyRequired: true),
      throwsA(
        isA<UnsupportedHarnessCapabilityException>()
            .having((error) => error.provider, 'provider', 'codex-alias')
            .having((error) => error.capability, 'capability', AgentHarness.noWorkToolsCapability),
      ),
    );
    expect(harness.startCalled, isFalse);
  });

  test('Claude declares complete work-tool interception while Codex remains unsupported', () {
    expect(ClaudeCodeHarness(cwd: '/').supportsNoWorkTools, isTrue);
    expect(CodexHarness(cwd: '/').supportsNoWorkTools, isFalse);
  });

  test('a qualified harness accepts the policy and an unrestricted request needs no capability', () {
    final supported = FakeAgentHarness(supportsNoWorkTools: true);
    final unsupported = FakeAgentHarness();

    expect(
      () => AgentHarness.requireNoWorkToolsSupport(supported, provider: 'qualified', emptyToolPolicyRequired: true),
      returnsNormally,
    );
    expect(
      () =>
          AgentHarness.requireNoWorkToolsSupport(unsupported, provider: 'unrestricted', emptyToolPolicyRequired: false),
      returnsNormally,
    );
  });
}
