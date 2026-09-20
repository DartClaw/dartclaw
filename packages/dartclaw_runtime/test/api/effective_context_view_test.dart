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

  Future<Map<String, dynamic>> view(ConversationState state) =>
      effectiveContextView(session(), state, null, 'claude', const {});

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
