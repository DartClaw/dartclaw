import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('constantTimeEquals', () {
    test('returns true for equal strings', () {
      expect(constantTimeEquals('abc123', 'abc123'), isTrue);
      expect(constantTimeEquals('Hej 👋', 'Hej 👋'), isTrue);
    });

    test('returns false for different strings', () {
      expect(constantTimeEquals('abc123', 'abc124'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
      expect(constantTimeEquals('', 'value'), isFalse);
      expect(constantTimeEquals('Hej 👋', 'Hej 😀'), isFalse);
    });

    // Every caller compares a secret. A credential that failed to resolve is
    // empty, and matching it against an equally empty candidate turns a
    // configuration failure into an authenticated caller.
    test('an empty secret never matches, not even another empty one', () {
      expect(constantTimeEquals('', ''), isFalse);
      expect(constantTimeEquals('secret', ''), isFalse);
      expect(constantTimeEquals('', 'secret'), isFalse);
    });
  });
}
