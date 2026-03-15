import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  const parser = ReviewCommandParser();

  group('ReviewCommandParser', () {
    test('parses bare accept and reject commands', () {
      expect(parser.parse('accept'), const TypeMatcher<ReviewCommand>());
      expect(parser.parse('accept')!.action, 'accept');
      expect(parser.parse('accept')!.taskId, isNull);

      expect(parser.parse('reject'), const TypeMatcher<ReviewCommand>());
      expect(parser.parse('reject')!.action, 'reject');
      expect(parser.parse('reject')!.taskId, isNull);
    });

    test('parses commands with task ids', () {
      final accept = parser.parse('accept abc123');
      final reject = parser.parse('reject def456');

      expect(accept?.action, 'accept');
      expect(accept?.taskId, 'abc123');
      expect(reject?.action, 'reject');
      expect(reject?.taskId, 'def456');
    });

    test('normalizes case and surrounding whitespace', () {
      final parsed = parser.parse('  AcCePt   ABC123  ');

      expect(parsed?.action, 'accept');
      expect(parsed?.taskId, 'abc123');
    });

    test('accepts multiple spaces between command and task id', () {
      final parsed = parser.parse('reject   abc123');

      expect(parsed?.action, 'reject');
      expect(parsed?.taskId, 'abc123');
    });

    test('rejects empty input and unknown commands', () {
      expect(parser.parse(''), isNull);
      expect(parser.parse('   '), isNull);
      expect(parser.parse('hello'), isNull);
      expect(parser.parse('approve abc123'), isNull);
    });

    test('rejects part-of-sentence occurrences', () {
      expect(parser.parse('I accept that'), isNull);
      expect(parser.parse('please reject this task'), isNull);
    });

    test('rejects commands with too many parts', () {
      expect(parser.parse('accept abc 123'), isNull);
      expect(parser.parse('reject one two'), isNull);
    });
  });
}
