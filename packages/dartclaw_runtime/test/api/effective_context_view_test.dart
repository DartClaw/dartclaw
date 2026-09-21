import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/api/session_routes_support.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 19, 11, 42);

  Session session() => Session(
    id: 'session-1',
    type: SessionType.user,
    retention: ConversationRetention.durable,
    provider: 'claude',
    createdAt: now,
    updatedAt: now,
  );

  Future<Map<String, dynamic>> view(
    ConversationState state, {
    Map<String, EffectiveContextCapabilities> capabilities = const {},
  }) => effectiveContextView(session(), state, null, 'claude', capabilities);

  const claude = EffectiveContextCapabilities(
    model: true,
    effort: true,
    models: ['sonnet', 'opus'],
    efforts: ['low', 'high'],
  );

  // The composer pill is read as a claim about the next turn. A segment nobody
  // has selected has to be absent, because a stand-in reads as a selection.
  test('the composer label omits segments the conversation has not selected', () async {
    final projection = await view(ConversationState());
    expect(projection['composer'], 'claude');
    expect(projection['composer'], isNot(contains('provider model')));
    expect(projection['composer'], isNot(contains('provider effort')));
  });

  test('the composer label states the model and effort once they exist', () async {
    final projection = await view(
      ConversationState().stageContext(
        const EffectiveConversationContext(
          projectId: 'project-1',
          directory: '/tmp',
          referenceRoot: '/tmp',
          provider: 'claude',
          model: 'sonnet-4.6',
          effort: 'high',
        ),
      ),
    );
    expect(projection['composer'], 'claude · sonnet-4.6 · high');
  });

  // The picker is the adapter's own vocabulary plus the provider default. It
  // has to stay able to name a value the adapter does not list, or applying an
  // unrelated change would silently drop a model set from YAML or the API.
  test('the model and effort pickers offer the provider default and the adapter catalogue', () async {
    final projection = await view(ConversationState(), capabilities: const {'claude': claude});
    expect(projection['modelOptions'], [
      {'value': '', 'label': 'Provider default', 'selected': true},
      {'value': 'sonnet', 'label': 'sonnet', 'selected': false},
      {'value': 'opus', 'label': 'opus', 'selected': false},
    ]);
    expect(projection['effortOptions'], [
      {'value': '', 'label': 'Provider default', 'selected': true},
      {'value': 'low', 'label': 'low', 'selected': false},
      {'value': 'high', 'label': 'high', 'selected': false},
    ]);
    expect((projection['providers'] as List).single, containsPair('models', 'sonnet,opus'));
    expect((projection['providers'] as List).single, containsPair('efforts', 'low,high'));
  });

  test('a staged value outside the catalogue is offered as its own option', () async {
    final projection = await view(
      ConversationState().stageContext(
        const EffectiveConversationContext(
          projectId: 'project-1',
          directory: '/tmp',
          referenceRoot: '/tmp',
          provider: 'claude',
          model: 'claude-opus-4-20250514',
          effort: 'high',
        ),
      ),
      capabilities: const {'claude': claude},
    );
    expect(projection['modelOptions'], [
      {'value': '', 'label': 'Provider default', 'selected': false},
      {'value': 'sonnet', 'label': 'sonnet', 'selected': false},
      {'value': 'opus', 'label': 'opus', 'selected': false},
      {'value': 'claude-opus-4-20250514', 'label': 'claude-opus-4-20250514', 'selected': true},
    ]);
    expect(projection['effortOptions'], contains(containsPair('selected', true)));
    // `high` is in the catalogue, so it is not repeated as its own option.
    expect((projection['effortOptions'] as List).where((option) => option['value'] == 'high'), hasLength(1));
  });

  test('a provider with no catalogue still offers the provider default', () async {
    final projection = await view(
      ConversationState(),
      capabilities: const {'claude': EffectiveContextCapabilities(model: true, effort: true)},
    );
    expect(projection['modelOptions'], [
      {'value': '', 'label': 'Provider default', 'selected': true},
    ]);
  });

  test('context usage is a number only when a live measurement supplies both halves', () async {
    final unmeasured = await view(
      ConversationState().recordTelemetry(
        SessionContextTelemetry(
          sessionId: 'session-1',
          source: 'claude',
          observedAt: now,
          availability: ContextMeasurementAvailability.unsupported,
        ),
      ),
    );
    expect(unmeasured['usage'], '');
    expect(unmeasured['usageHidden'], isTrue);

    // Measured, but the provider reported no window — a percentage of an
    // unknown whole is a guess.
    final windowless = await view(
      ConversationState().recordTelemetry(
        SessionContextTelemetry(
          sessionId: 'session-1',
          source: 'claude',
          observedAt: now,
          availability: ContextMeasurementAvailability.measured,
          usedTokens: 36000,
        ),
      ),
    );
    expect(windowless['usage'], '');

    final measured = await view(
      ConversationState().recordTelemetry(
        SessionContextTelemetry(
          sessionId: 'session-1',
          source: 'claude',
          observedAt: now,
          availability: ContextMeasurementAvailability.measured,
          usedTokens: 36000,
          contextWindowTokens: 200000,
        ),
      ),
    );
    expect(measured['usage'], '18%');
    expect(measured['usageHidden'], isNull);
  });

  // The notice warns that provider-native state does not follow a provider
  // change, so it is about the provider the conversation last ran on, not the
  // session's creation provider or the previous selection.
  group('continuity notice', () {
    EffectiveConversationContext context(String provider) => EffectiveConversationContext(
      projectId: 'project-1',
      directory: '/tmp',
      referenceRoot: '/tmp',
      provider: provider,
    );

    test('shows when the next turn runs on another provider than the last one did', () async {
      final projection = await view(ConversationState().admitContext(context('claude')).stageContext(context('codex')));
      expect(projection['continuityHidden'], isNull);
    });

    test('hides when the next turn stays on the last-run provider', () async {
      final projection = await view(ConversationState().admitContext(context('codex')).stageContext(context('codex')));
      expect(projection['continuityHidden'], isTrue);
    });

    test('hides before the first turn, whatever is staged', () async {
      final projection = await view(ConversationState().stageContext(context('codex')));
      expect(projection['continuityHidden'], isTrue);
    });
  });

  test('a stale measurement reports no percentage', () async {
    final stale = await view(
      ConversationState().recordTelemetry(
        SessionContextTelemetry(
          sessionId: 'session-1',
          source: 'claude',
          observedAt: now,
          availability: ContextMeasurementAvailability.stale,
          usedTokens: 36000,
          contextWindowTokens: 200000,
        ),
      ),
    );
    expect(stale['usage'], '');
    expect(stale['usageHidden'], isTrue);
  });
}
