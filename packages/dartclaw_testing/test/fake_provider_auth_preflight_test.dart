import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  test('reports providers as authenticated by default and records probes', () async {
    final preflight = FakeProviderAuthPreflight();

    final result = await preflight.evaluate(provider: 'claude');

    expect(result.authenticated, isTrue);
    expect(result.remediationMessage, isNull);
    expect(preflight.probed, ['claude']);
  });

  test('reports configured providers as unauthenticated with remediation', () async {
    final preflight = FakeProviderAuthPreflight(unauthenticated: {'codex'});

    final result = await preflight.evaluate(provider: 'codex');

    expect(result.authenticated, isFalse);
    expect(result.remediationMessage, contains('codex'));
    expect(preflight.probed, ['codex']);
  });
}
