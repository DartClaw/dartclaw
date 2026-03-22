import 'package:dartclaw_core/src/channel/review_command_parser.dart';
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

  group('ReviewCommandParser — push back', () {
    test('parses bare push back with feedback', () {
      final cmd = parser.parse('push back: please add tests');

      expect(cmd?.action, 'push_back');
      expect(cmd?.taskId, isNull);
      expect(cmd?.comment, 'please add tests');
    });

    test('parses push back with task id', () {
      final cmd = parser.parse('push back abc123: please add tests');

      expect(cmd?.action, 'push_back');
      expect(cmd?.taskId, 'abc123');
      expect(cmd?.comment, 'please add tests');
    });

    test('normalizes case in push back prefix', () {
      final cmd = parser.parse('PUSH BACK: do it again');

      expect(cmd?.action, 'push_back');
      expect(cmd?.comment, 'do it again');
    });

    test('preserves feedback text verbatim (including colons)', () {
      final cmd = parser.parse('push back: fix the auth: use token not password');

      expect(cmd?.action, 'push_back');
      expect(cmd?.comment, 'fix the auth: use token not password');
    });

    test('trims leading/trailing whitespace from feedback', () {
      final cmd = parser.parse('push back:   lots of spaces   ');

      expect(cmd?.comment, 'lots of spaces');
    });

    test('returns null for bare push back with no colon', () {
      expect(parser.parse('push back'), isNull);
      expect(parser.parse('push back abc123'), isNull);
    });

    test('returns null for push back with empty feedback', () {
      expect(parser.parse('push back:'), isNull);
      expect(parser.parse('push back:   '), isNull);
      expect(parser.parse('push back abc123:'), isNull);
    });

    test('returns null for push back with multi-word id', () {
      expect(parser.parse('push back abc 123: do it again'), isNull);
    });

    test('normalizes task id to lower case', () {
      final cmd = parser.parse('push back ABC123: redo this');

      expect(cmd?.taskId, 'abc123');
    });
  });
}
