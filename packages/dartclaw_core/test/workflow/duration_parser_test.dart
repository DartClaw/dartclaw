import 'package:dartclaw_core/src/workflow/duration_parser.dart';
import 'package:test/test.dart';

void main() {
  group('parseDuration', () {
    test('"30s" -> Duration(seconds: 30)', () {
      expect(parseDuration('30s'), Duration(seconds: 30));
    });

    test('"5m" -> Duration(minutes: 5)', () {
      expect(parseDuration('5m'), Duration(minutes: 5));
    });

    test('"1h" -> Duration(hours: 1)', () {
      expect(parseDuration('1h'), Duration(hours: 1));
    });

    test('"1h30m" -> Duration(hours: 1, minutes: 30)', () {
      expect(parseDuration('1h30m'), Duration(hours: 1, minutes: 30));
    });

    test('"2h15m30s" -> Duration(hours: 2, minutes: 15, seconds: 30)', () {
      expect(
        parseDuration('2h15m30s'),
        Duration(hours: 2, minutes: 15, seconds: 30),
      );
    });

    test('"90m" -> Duration(minutes: 90)', () {
      expect(parseDuration('90m'), Duration(minutes: 90));
    });

    test('invalid format throws FormatException', () {
      expect(() => parseDuration('invalid'), throwsFormatException);
    });

    test('zero duration throws FormatException', () {
      expect(() => parseDuration('0h'), throwsFormatException);
    });

    test('empty string throws FormatException', () {
      expect(() => parseDuration(''), throwsFormatException);
    });

    test('whitespace-trimmed input is handled', () {
      expect(parseDuration('  5m  '), Duration(minutes: 5));
    });
  });
}
