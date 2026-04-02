import 'package:dartclaw_core/src/config/duration_parser.dart';
import 'package:test/test.dart';

void main() {
  group('tryParseDuration', () {
    test('passes through Duration values', () {
      expect(tryParseDuration(const Duration(seconds: 42)), const Duration(seconds: 42));
    });

    test('treats int as seconds', () {
      expect(tryParseDuration(30), const Duration(seconds: 30));
      expect(tryParseDuration(0), Duration.zero);
    });

    test('parses seconds suffix', () {
      expect(tryParseDuration('45s'), const Duration(seconds: 45));
    });

    test('parses minutes suffix', () {
      expect(tryParseDuration('5m'), const Duration(minutes: 5));
    });

    test('parses hours suffix', () {
      expect(tryParseDuration('2h'), const Duration(hours: 2));
    });

    test('parses bare numeric string as seconds', () {
      expect(tryParseDuration('60'), const Duration(seconds: 60));
    });

    test('returns null for empty string', () {
      expect(tryParseDuration(''), isNull);
      expect(tryParseDuration('  '), isNull);
    });

    test('returns null for non-numeric string', () {
      expect(tryParseDuration('abc'), isNull);
      expect(tryParseDuration('5x'), isNull);
    });

    test('returns null for null and unsupported types', () {
      expect(tryParseDuration(null), isNull);
      expect(tryParseDuration(3.14), isNull);
      expect(tryParseDuration(true), isNull);
    });

    test('is case-insensitive', () {
      expect(tryParseDuration('5S'), const Duration(seconds: 5));
      expect(tryParseDuration('2M'), const Duration(minutes: 2));
      expect(tryParseDuration('1H'), const Duration(hours: 1));
    });

    test('trims whitespace', () {
      expect(tryParseDuration('  30s  '), const Duration(seconds: 30));
    });
  });
}
