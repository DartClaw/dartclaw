import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  test('general context keeps a null project through state and admitted context JSON', () {
    const general = EffectiveConversationContext(
      projectId: null,
      directory: '/owner/workspace',
      referenceRoot: '/owner/workspace',
      provider: 'claude',
    );
    final state = ConversationState(nextContext: general).admitContext(general);

    expect(general.toJson()['projectId'], isNull);
    final restored = ConversationState.fromJson(state.toJson());
    expect(restored.currentContext?.projectId, isNull);
    expect(restored.nextContext?.projectId, isNull);
    expect(restored.nextContext?.directory, '/owner/workspace');
    expect(restored.nextContext?.referenceRoot, '/owner/workspace');
    expect(restored.nextContext?.toJson(), general.toJson());
  });

  test('explicit project remains distinct from general context after JSON round-trip', () {
    const project = EffectiveConversationContext(
      projectId: 'checkout-a',
      directory: '/projects/checkout-a',
      referenceRoot: '/projects/checkout-a',
      provider: 'codex',
    );

    expect(EffectiveConversationContext.fromJson(project.toJson()).projectId, 'checkout-a');
    expect(project.toJson()['projectId'], isNotNull);
  });
}
