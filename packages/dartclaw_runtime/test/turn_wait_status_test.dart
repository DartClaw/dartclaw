import 'package:dartclaw_core/dartclaw_core.dart' show TurnLimitBreach, TurnOutcome, TurnStatus;
import 'package:dartclaw_runtime/src/turn_wait_status.dart';
import 'package:test/test.dart';

void main() {
  group('TurnStatusSnapshot.toJson wire names', () {
    test('serializes state and wait_reason with frozen strings', () {
      final json = const TurnStatusSnapshot(
        sessionId: 'session-1',
        state: TurnWaitState.waiting,
        waitReason: TurnWaitReason.providerTurn,
        canCancel: true,
      ).toJson();

      expect(json['state'], 'waiting');
      expect(json['wait_reason'], 'provider_turn');
    });

    test('null waitReason yields wait_reason null', () {
      final json = const TurnStatusSnapshot(
        sessionId: 'session-1',
        state: TurnWaitState.idle,
        canCancel: false,
      ).toJson();

      expect(json['wait_reason'], isNull);
    });

    test('serializes limit breach attribution from terminal outcomes', () {
      for (final testCase in <({TurnLimitBreach? breach, String? wire})>[
        (breach: TurnLimitBreach.stall, wire: 'stall'),
        (breach: TurnLimitBreach.turnTimeout, wire: 'turn_timeout'),
        (breach: null, wire: null),
      ]) {
        final outcome = TurnOutcome(
          turnId: 'turn-1',
          sessionId: 'session-1',
          status: TurnStatus.cancelled,
          limitBreach: testCase.breach,
          completedAt: DateTime.utc(2026),
        );

        final json = TurnStatusSnapshot.fromOutcome(
          sessionId: 'session-1',
          outcome: outcome,
          provider: 'claude',
        ).toJson();

        expect(json['limit_breach'], testCase.wire, reason: '${testCase.breach}');
      }
    });
  });
}
