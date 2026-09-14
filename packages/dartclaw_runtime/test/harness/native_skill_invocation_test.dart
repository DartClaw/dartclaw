import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  test('native skill invocation capability and spelling are adapter-owned', () {
    final factory = HarnessFactory();

    expect(factory.supportsNativeSkillInvocationFor('claude'), isTrue);
    expect(factory.skillActivationLineFor('claude', 'review'), '/review');
    expect(factory.supportsNativeSkillInvocationFor('codex'), isTrue);
    expect(factory.skillActivationLineFor('codex', 'review'), r'$review');
    expect(factory.supportsNativeSkillInvocationFor('missing'), isFalse);
  });
}
