import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

TurnProgressSnapshot _snap({
  Duration elapsed = const Duration(seconds: 5),
  int toolCallCount = 2,
  String? lastToolName = 'bash',
  int accumulatedTokens = 100,
  int textLength = 50,
}) => TurnProgressSnapshot(
  elapsed: elapsed,
  toolCallCount: toolCallCount,
  lastToolName: lastToolName,
  accumulatedTokens: accumulatedTokens,
  textLength: textLength,
);

void main() {
  final snap = _snap();

  group('ToolStartedProgressEvent', () {
    test('constructs with required fields', () {
      final e = ToolStartedProgressEvent(snapshot: snap, toolName: 'bash', toolCallCount: 3);
      expect(e.toolName, 'bash');
      expect(e.toolCallCount, 3);
      expect(e.snapshot, same(snap));
    });

    test('equality and hashCode', () {
      final a = ToolStartedProgressEvent(snapshot: snap, toolName: 'bash', toolCallCount: 1);
      final b = ToolStartedProgressEvent(snapshot: _snap(), toolName: 'bash', toolCallCount: 1);
      final c = ToolStartedProgressEvent(snapshot: snap, toolName: 'read', toolCallCount: 1);

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('toString', () {
      final s = ToolStartedProgressEvent(snapshot: snap, toolName: 'edit', toolCallCount: 7).toString();
      expect(s, contains('edit'));
      expect(s, contains('7'));
    });
  });

  group('ToolCompletedProgressEvent', () {
    test('constructs with required fields', () {
      final e = ToolCompletedProgressEvent(snapshot: snap, toolName: 'bash', isError: true);
      expect(e.toolName, 'bash');
      expect(e.isError, isTrue);
      expect(e.snapshot, same(snap));
    });

    test('equality and hashCode', () {
      final a = ToolCompletedProgressEvent(snapshot: snap, toolName: 'bash', isError: false);
      final b = ToolCompletedProgressEvent(snapshot: _snap(), toolName: 'bash', isError: false);
      final c = ToolCompletedProgressEvent(snapshot: snap, toolName: 'bash', isError: true);

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('toString', () {
      final s = ToolCompletedProgressEvent(snapshot: snap, toolName: 'read', isError: true).toString();
      expect(s, contains('read'));
      expect(s, contains('true'));
    });
  });

  group('TextDeltaProgressEvent', () {
    test('constructs with required fields', () {
      final e = TextDeltaProgressEvent(snapshot: snap, text: 'hello');
      expect(e.text, 'hello');
      expect(e.snapshot, same(snap));
    });

    test('equality and hashCode', () {
      final a = TextDeltaProgressEvent(snapshot: snap, text: 'abc');
      final b = TextDeltaProgressEvent(snapshot: _snap(), text: 'abc');
      final c = TextDeltaProgressEvent(snapshot: snap, text: 'xyz');

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('toString', () {
      final s = TextDeltaProgressEvent(snapshot: snap, text: 'chunk').toString();
      expect(s, contains('chunk'));
    });
  });

  group('StatusTickProgressEvent', () {
    test('constructs with snapshot', () {
      final e = StatusTickProgressEvent(snapshot: snap);
      expect(e.snapshot, same(snap));
    });

    test('toString', () {
      expect(StatusTickProgressEvent(snapshot: snap).toString(), contains('StatusTickProgressEvent'));
    });
  });

  group('TurnStallProgressEvent', () {
    test('constructs with required fields', () {
      final e = TurnStallProgressEvent(snapshot: snap, stallTimeout: const Duration(seconds: 30), action: 'warn');
      expect(e.stallTimeout, const Duration(seconds: 30));
      expect(e.action, 'warn');
      expect(e.snapshot, same(snap));
    });

    test('equality and hashCode', () {
      final a = TurnStallProgressEvent(snapshot: snap, stallTimeout: const Duration(seconds: 30), action: 'warn');
      final b = TurnStallProgressEvent(snapshot: _snap(), stallTimeout: const Duration(seconds: 30), action: 'warn');
      final c = TurnStallProgressEvent(snapshot: snap, stallTimeout: const Duration(seconds: 30), action: 'abort');

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('toString', () {
      final s = TurnStallProgressEvent(
        snapshot: snap,
        stallTimeout: const Duration(seconds: 60),
        action: 'abort',
      ).toString();
      expect(s, contains('0:01:00'));
      expect(s, contains('abort'));
    });
  });

  group('exhaustive pattern matching', () {
    test('switch covers all subtypes', () {
      final events = <TurnProgressEvent>[
        ToolStartedProgressEvent(snapshot: snap, toolName: 'bash', toolCallCount: 1),
        ToolCompletedProgressEvent(snapshot: snap, toolName: 'bash', isError: false),
        TextDeltaProgressEvent(snapshot: snap, text: 'hi'),
        StatusTickProgressEvent(snapshot: snap),
        TurnStallProgressEvent(snapshot: snap, stallTimeout: const Duration(seconds: 10), action: 'warn'),
      ];

      final labels = events.map(
        (e) => switch (e) {
          ToolStartedProgressEvent() => 'started',
          ToolCompletedProgressEvent() => 'completed',
          TextDeltaProgressEvent() => 'delta',
          StatusTickProgressEvent() => 'tick',
          TurnStallProgressEvent() => 'stall',
        },
      );

      expect(labels, ['started', 'completed', 'delta', 'tick', 'stall']);
    });
  });
}
