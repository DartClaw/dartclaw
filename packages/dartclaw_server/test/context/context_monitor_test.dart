import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('ContextMonitor', () {
    test('shouldFlush is false with no data', () {
      final monitor = ContextMonitor();
      expect(monitor.shouldFlush, isFalse);
    });

    test('shouldFlush is false when under threshold', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextWindow: 200000, contextTokens: 100000);
      expect(monitor.shouldFlush, isFalse);
    });

    test('shouldFlush is true when over threshold', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextWindow: 200000, contextTokens: 185000);
      expect(monitor.shouldFlush, isTrue);
    });

    test('shouldFlush is true at exact threshold', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextWindow: 200000, contextTokens: 180001);
      expect(monitor.shouldFlush, isTrue);
    });

    test('shouldFlush does not re-trigger while flush is pending', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextWindow: 200000, contextTokens: 190000);
      expect(monitor.shouldFlush, isTrue);

      monitor.markFlushStarted();
      expect(monitor.shouldFlush, isFalse);
      expect(monitor.isFlushPending, isTrue);
    });

    test('markFlushCompleted resets pending flag', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextWindow: 200000, contextTokens: 190000);
      monitor.markFlushStarted();
      monitor.markFlushCompleted();

      expect(monitor.isFlushPending, isFalse);
      // Should be able to trigger again
      expect(monitor.shouldFlush, isTrue);
    });

    test('partial updates work (only contextTokens)', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextWindow: 200000);
      expect(monitor.shouldFlush, isFalse); // no token count yet

      monitor.update(contextTokens: 190000);
      expect(monitor.shouldFlush, isTrue);
    });

    test('shouldFlush is false with only contextTokens (no window)', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextTokens: 190000);
      expect(monitor.shouldFlush, isFalse); // no window set
    });
  });
}
