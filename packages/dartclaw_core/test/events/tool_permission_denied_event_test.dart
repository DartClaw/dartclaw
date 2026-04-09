import 'dart:async';

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
      final event = ToolPermissionDeniedEvent(
        toolName: 'Write',
        timestamp: DateTime.now(),
      );

      expect(event.sessionId, isNull);
      expect(event.reason, isNull);
    });

    test('toString includes toolName and reason', () {
      final event = ToolPermissionDeniedEvent(
        toolName: 'Edit',
        reason: 'blocked',
        timestamp: DateTime.now(),
      );

      expect(event.toString(), contains('Edit'));
      expect(event.toString(), contains('blocked'));
    });

    test('EventBus delivers ToolPermissionDeniedEvent to typed listener', () async {
      final bus = EventBus();
      addTearDown(bus.dispose);

      final received = <ToolPermissionDeniedEvent>[];
      final sub = bus.on<ToolPermissionDeniedEvent>().listen(received.add);
      addTearDown(sub.cancel);

      final ts = DateTime.utc(2026, 4, 9, 12, 0, 0);
      bus.fire(ToolPermissionDeniedEvent(toolName: 'Bash', reason: 'denied', timestamp: ts));

      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.first.toolName, 'Bash');
      expect(received.first.reason, 'denied');
      expect(received.first.timestamp, ts);
    });

    test('EventBus does not deliver to unrelated event listener', () async {
      final bus = EventBus();
      addTearDown(bus.dispose);

      final guardEvents = <GuardBlockEvent>[];
      final sub = bus.on<GuardBlockEvent>().listen(guardEvents.add);
      addTearDown(sub.cancel);

      bus.fire(
        ToolPermissionDeniedEvent(toolName: 'Read', timestamp: DateTime.now()),
      );

      await Future<void>.delayed(Duration.zero);

      expect(guardEvents, isEmpty);
    });
  });
}
