import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('scrubAgentReportedText', () {
    test('strips the 8-bit C1 CSI introducer (U+009B) so terminals cannot interpret it', () {
      expect(scrubAgentReportedText('red\u{9B}31malert'), equals('red31malert'));
    });

    test('strips the full C1 range (U+0080–U+009F)', () {
      expect(scrubAgentReportedText('a\u{80}b\u{9D}c\u{9F}d'), equals('abcd'));
    });

    test('truncates over-long input at 300 characters with a trailing ellipsis', () {
      final scrubbed = scrubAgentReportedText('x' * 350);
      expect(scrubbed.length, equals(301));
      expect(scrubbed, equals('${'x' * 300}…'));
    });

    test('leaves input at exactly the cap untouched', () {
      expect(scrubAgentReportedText('y' * 300), equals('y' * 300));
    });
  });

  group('scrubAgentReportedBlock', () {
    test('keeps line feeds and tabs, so Markdown layout survives', () {
      expect(scrubAgentReportedBlock('| a |\tb |\n| - | - |'), equals('| a |\tb |\n| - | - |'));
    });

    test('turns CRLF into LF and strips a lone CR', () {
      expect(scrubAgentReportedBlock('one\r\ntwo\rthree'), equals('one\ntwothree'));
    });

    test('strips ANSI CSI sequences', () {
      expect(scrubAgentReportedBlock('\x1B[31mred\x1B[0m'), equals('red'));
    });

    test('strips C0, DEL and the full C1 range', () {
      expect(scrubAgentReportedBlock('a\x00b\x07c\x7Fd\u{80}e\u{9B}f\u{9F}g'), equals('abcdefg'));
    });

    test('neither trims nor bounds the value', () {
      final long = '  ${'z' * 400}  ';
      expect(scrubAgentReportedBlock(long), equals(long));
    });
  });
}
