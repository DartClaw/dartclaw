import 'package:dartclaw_server/src/turn_wait_status.dart';
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
  });
}
