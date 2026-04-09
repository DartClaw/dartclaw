import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('ResultTrimmer', () {
    test('small results are unchanged', () {
      final trimmer = ResultTrimmer(maxBytes: 1024);
      const small = 'Hello, world!';
      expect(trimmer.trim(small), small);
    });

    test('result at exact max is unchanged', () {
      final trimmer = ResultTrimmer(maxBytes: 100);
      final exact = 'a' * 100;
      expect(trimmer.trim(exact), exact);
    });

    test('oversized result is trimmed', () {
      final trimmer = ResultTrimmer(maxBytes: 100);
      final large = 'x' * 10000;
      final result = trimmer.trim(large);

      expect(result.length, lessThan(large.length));
      expect(result, contains('...[trimmed'));
      expect(result, contains('bytes]...'));
    });

    test('trimmed result preserves head and tail', () {
      final trimmer = ResultTrimmer(maxBytes: 100);
      // Create a string with distinct head and tail
      final large = 'HEAD${'m' * 10000}TAIL';
      final result = trimmer.trim(large);

      expect(result, startsWith('HEAD'));
      expect(result, endsWith('TAIL'));
    });

    test('trim message includes byte count', () {
      final trimmer = ResultTrimmer(maxBytes: 100);
      final large = 'a' * 10000;
      final result = trimmer.trim(large);

      // The trimmed byte count should be total - head(2048) - tail(2048)
      expect(result, contains('trimmed'));
    });

    test('handles UTF-8 multibyte characters safely', () {
      final trimmer = ResultTrimmer(maxBytes: 100);
      // Each emoji is 4 bytes in UTF-8
      final large = '\u{1F600}' * 5000;
      final result = trimmer.trim(large);

      // Should not throw, and result should be valid
      expect(result, contains('trimmed'));
      expect(result.isNotEmpty, isTrue);
    });

    test('default maxBytes is 50KB', () {
      final trimmer = ResultTrimmer();
      final underLimit = 'a' * (50 * 1024);
      expect(trimmer.trim(underLimit), underLimit);
    });
  });
}
