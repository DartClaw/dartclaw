import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  test('TI01 outcome transport fields default to absent', () {
    final outcome = TurnOutcome(
      turnId: 'turn-1',
      sessionId: 'session-1',
      status: TurnStatus.completed,
      completedAt: DateTime.utc(2026),
    );

    expect(outcome.structuredOutput, isNull);
    expect(outcome.providerSessionId, isNull);
  });

  test('limit breach round-trips', () {
    final outcome = TurnOutcome(
      turnId: 'turn-1',
      sessionId: 'session-1',
      status: TurnStatus.cancelled,
      limitBreach: TurnLimitBreach.turnTimeout,
      completedAt: DateTime.utc(2026),
    );

    final serialized = outcome.limitBreach!.jsonName;

    expect(TurnLimitBreach.fromJson(serialized), TurnLimitBreach.turnTimeout);
  });
}
