import 'package:test/test.dart';
import 'package:dartclaw_server/src/templates/helpers.dart';

void main() {
  group('htmlEscape', () {
    test('escapes <', () {
      expect(htmlEscape('<'), equals('&lt;'));
    });

    test('escapes >', () {
      expect(htmlEscape('>'), equals('&gt;'));
    });

    test('escapes &', () {
      expect(htmlEscape('&'), equals('&amp;'));
    });

    test('escapes "', () {
      expect(htmlEscape('"'), equals('&quot;'));
    });

    test("escapes '", () {
      expect(htmlEscape("'"), equals('&#39;'));
    });

    test('escapes /', () {
      expect(htmlEscape('/'), equals('&#47;'));
    });

    test('leaves safe text unchanged', () {
      expect(htmlEscape('hello world'), equals('hello world'));
    });

    test('handles empty string', () {
      expect(htmlEscape(''), equals(''));
    });

    test('handles unicode', () {
      expect(htmlEscape('こんにちは'), equals('こんにちは'));
    });

    test('XSS: script tag', () {
      expect(htmlEscape('<script>alert(1)</script>'), isNot(contains('<script>')));
    });

    test('XSS: event attribute', () {
      expect(htmlEscape('" onload="alert(1)'), isNot(contains('"')));
    });

    test('XSS: multi-char sequence', () {
      final input = '<img src=x onerror=alert(1)>';
      final output = htmlEscape(input);
      expect(output, isNot(contains('<img')));
      expect(output, contains('&lt;img'));
    });

    test('handles multiple special chars in one string', () {
      expect(
        htmlEscape('<a href="/foo?a=1&b=2">link</a>'),
        equals('&lt;a href=&quot;&#47;foo?a=1&amp;b=2&quot;&gt;link&lt;&#47;a&gt;'),
      );
    });

    test('handles newlines', () {
      expect(htmlEscape('line1\nline2'), equals('line1\nline2'));
    });
  });
}
