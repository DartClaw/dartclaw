import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('LoopMechanism', () {
    test('has three values', () {
      expect(LoopMechanism.values, hasLength(3));
      expect(LoopMechanism.values, contains(LoopMechanism.turnChainDepth));
      expect(LoopMechanism.values, contains(LoopMechanism.tokenVelocity));
      expect(LoopMechanism.values, contains(LoopMechanism.toolFingerprint));
    });
  });

  group('LoopDetection', () {
    test('constructs with required fields', () {
      const detection = LoopDetection(
        mechanism: LoopMechanism.turnChainDepth,
        sessionId: 'sess-1',
        message: 'Chain depth exceeded',
      );
      expect(detection.mechanism, LoopMechanism.turnChainDepth);
      expect(detection.sessionId, 'sess-1');
      expect(detection.message, 'Chain depth exceeded');
      expect(detection.detail, isEmpty);
    });

    test('constructs with detail map', () {
      const detection = LoopDetection(
        mechanism: LoopMechanism.tokenVelocity,
        sessionId: 'sess-2',
        message: 'Velocity exceeded',
        detail: {'tokensInWindow': 5000, 'threshold': 4000},
      );
      expect(detection.detail['tokensInWindow'], 5000);
    });

    test('toString includes mechanism and session', () {
      const detection = LoopDetection(
        mechanism: LoopMechanism.toolFingerprint,
        sessionId: 'sess-3',
        message: 'Fingerprint',
      );
      final s = detection.toString();
      expect(s, contains('toolFingerprint'));
      expect(s, contains('sess-3'));
    });
  });

  group('LoopDetectedException', () {
    test('constructs and toString', () {
      const detection = LoopDetection(
        mechanism: LoopMechanism.turnChainDepth,
        sessionId: 'sess-1',
        message: 'depth exceeded',
      );
      const ex = LoopDetectedException('depth exceeded', detection);
      expect(ex.message, 'depth exceeded');
      expect(ex.detection, detection);
      expect(ex.toString(), contains('LoopDetectedException'));
      expect(ex.toString(), contains('depth exceeded'));
    });
  });
}
