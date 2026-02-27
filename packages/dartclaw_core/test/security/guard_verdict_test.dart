import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('GuardVerdict', () {
    test('pass() returns isPass=true, not block/warn, message null', () {
      final v = GuardVerdict.pass();
      expect(v.isPass, isTrue);
      expect(v.isWarn, isFalse);
      expect(v.isBlock, isFalse);
      expect(v.message, isNull);
    });

    test('warn(msg) returns isWarn=true, message set', () {
      final v = GuardVerdict.warn('caution');
      expect(v.isWarn, isTrue);
      expect(v.isPass, isFalse);
      expect(v.isBlock, isFalse);
      expect(v.message, 'caution');
    });

    test('block(reason) returns isBlock=true, message set', () {
      final v = GuardVerdict.block('denied');
      expect(v.isBlock, isTrue);
      expect(v.isPass, isFalse);
      expect(v.isWarn, isFalse);
      expect(v.message, 'denied');
    });

    test('sealed class supports exhaustive pattern matching', () {
      final v = GuardVerdict.pass();
      // This compiles only if the sealed class is exhaustive
      final label = switch (v) {
        GuardVerdict(isPass: true) => 'pass',
        GuardVerdict(isWarn: true) => 'warn',
        GuardVerdict(isBlock: true) => 'block',
        _ => 'unknown',
      };
      expect(label, 'pass');
    });

    test('toString representations', () {
      expect(GuardVerdict.pass().toString(), 'GuardVerdict.pass()');
      expect(GuardVerdict.warn('w').toString(), 'GuardVerdict.warn(w)');
      expect(GuardVerdict.block('b').toString(), 'GuardVerdict.block(b)');
    });
  });
}
