import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('turn wait-state wire names', () {
    test('TurnWaitState.name mapping is frozen', () {
      expect(TurnWaitState.values.map((s) => s.name), [
        'idle',
        'running',
        'waiting',
        'stuck',
        'cancelling',
        'cancelled',
        'completed',
        'failed',
      ]);
    });

    test('TurnWaitReason.jsonName mapping is frozen', () {
      expect(TurnWaitReason.values.map((r) => r.jsonName), [
        'session_lock',
        'provider_turn',
        'tool_approval',
        'unknown',
      ]);
    });
  });
}
