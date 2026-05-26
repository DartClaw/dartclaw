import 'package:dartclaw_core/dartclaw_core.dart' show truncate;
import 'package:test/test.dart';

void main() {
  group('truncate (char-count)', () {
    test('returns string unchanged when length is within maxLength', () {
      expect(truncate('hello', 10), 'hello');
    });

    test('returns string unchanged when length equals maxLength', () {
      expect(truncate('hello', 5), 'hello');
    });

    test('truncates with default ellipsis suffix', () {
      expect(truncate('hello world', 8), 'hello w…');
    });

    test('truncates with custom ASCII suffix', () {
      expect(truncate('hello world', 8, suffix: '...'), 'hello...');
    });

    test('handles empty string', () {
      expect(truncate('', 5), '');
    });

    test('handles multi-byte UTF-8 characters correctly by code unit', () {
      // 'héllo' — 'é' is one Dart code unit (U+00E9), length == 5
      expect(truncate('héllo', 4), 'hél…');
    });

    test('empty suffix yields exact substring at maxLength', () {
      expect(truncate('hello world', 5, suffix: ''), 'hello');
    });

    test('suffix longer than maxLength clamps prefix to empty string', () {
      expect(truncate('hello', 2, suffix: '...'), '...');
    });
  });
}
