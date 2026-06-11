import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('ToolPermissionDeniedEvent', () {
    test('constructs with required and optional fields', () {
      final ts = DateTime.utc(2026, 4, 9, 10, 0, 0);
      final event = ToolPermissionDeniedEvent(
        toolName: 'Bash',
        sessionId: 'sess-1',
        reason: 'Not allowed by permissions policy',
        timestamp: ts,
      );

      expect(event.toolName, 'Bash');
      expect(event.sessionId, 'sess-1');
      expect(event.reason, 'Not allowed by permissions policy');
      expect(event.timestamp, ts);
    });

    test('optional fields default to null', () {
      final event = ToolPermissionDeniedEvent(toolName: 'Write', timestamp: DateTime.now());

      expect(event.sessionId, isNull);
      expect(event.reason, isNull);
    });
  });
}
