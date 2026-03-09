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
  });
}
