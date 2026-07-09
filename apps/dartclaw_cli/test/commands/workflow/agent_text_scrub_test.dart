import 'package:dartclaw_cli/src/commands/workflow/agent_text_scrub.dart';
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
}
