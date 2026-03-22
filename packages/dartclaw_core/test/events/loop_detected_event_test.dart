import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('LoopDetectedEvent', () {
    test('constructs with required fields', () {
      final ts = DateTime(2026, 3, 15, 12, 0);
      final event = LoopDetectedEvent(
        sessionId: 'sess-1',
        mechanism: 'turnChainDepth',
        message: 'Chain depth exceeded',
        action: 'abort',
        timestamp: ts,
      );
      expect(event.sessionId, 'sess-1');
      expect(event.mechanism, 'turnChainDepth');
      expect(event.message, 'Chain depth exceeded');
      expect(event.action, 'abort');
      expect(event.detail, isEmpty);
      expect(event.timestamp, ts);
    });

    test('constructs with detail', () {
      final event = LoopDetectedEvent(
        sessionId: 'sess-1',
        mechanism: 'tokenVelocity',
        message: 'Velocity exceeded',
        action: 'warn',
        detail: {'tokensInWindow': 5000},
        timestamp: DateTime.now(),
      );
      expect(event.detail['tokensInWindow'], 5000);
    });

    test('toString includes session, mechanism, action', () {
      final event = LoopDetectedEvent(
        sessionId: 'sess-42',
        mechanism: 'toolFingerprint',
        message: 'Tool repeated',
        action: 'abort',
        timestamp: DateTime.now(),
      );
      final s = event.toString();
      expect(s, contains('sess-42'));
      expect(s, contains('toolFingerprint'));
      expect(s, contains('abort'));
    });

    test('is a DartclawEvent', () {
      final event = LoopDetectedEvent(
        sessionId: 's',
        mechanism: 'm',
        message: 'msg',
        action: 'warn',
        timestamp: DateTime.now(),
      );
      expect(event, isA<DartclawEvent>());
    });
  });
}
