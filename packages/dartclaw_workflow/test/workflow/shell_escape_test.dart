import 'package:dartclaw_workflow/dartclaw_workflow.dart' show shellEscape;
import 'package:test/test.dart';

void main() {
  group('shellEscape', () {
    test('wraps plain value in single quotes', () {
      expect(shellEscape('hello'), equals("'hello'"));
    });

    test('escapes internal single quotes', () {
      expect(shellEscape("it's"), equals("'it'\\''s'"));
    });

    test('handles semicolons (injection prevention)', () {
      final escaped = shellEscape('; rm -rf /');
      // Whole value is wrapped — semicolons cannot break out.
      expect(escaped, startsWith("'"));
      expect(escaped, endsWith("'"));
      // Semicolon is inside the quotes, not active shell syntax.
      expect(escaped, equals("'; rm -rf /'"));
    });

    test('handles backticks', () {
      final escaped = shellEscape('`id`');
      expect(escaped, equals("'`id`'"));
    });

    test('handles dollar signs and command substitution', () {
      expect(shellEscape(r'$(cat /etc/passwd)'), equals(r"'$(cat /etc/passwd)'"));
    });

    test('handles spaces', () {
      expect(shellEscape('hello world'), equals("'hello world'"));
    });

    test('handles double quotes', () {
      expect(shellEscape('say "hello"'), equals("'say \"hello\"'"));
    });

    test('handles newlines', () {
      expect(shellEscape('line1\nline2'), equals("'line1\nline2'"));
    });

    test('handles glob characters', () {
      expect(shellEscape('*.dart'), equals("'*.dart'"));
    });

    test('handles empty string', () {
      expect(shellEscape(''), equals("''"));
    });

    test('multiple single quotes are all escaped', () {
      expect(shellEscape("a'b'c"), equals("'a'\\''b'\\''c'"));
    });

    test('injection pattern: semicolons and command chaining', () {
      // Value that would normally inject: value; malicious_cmd
      final cmd = 'echo ${shellEscape("user; rm -rf /")} | wc';
      // The escaped value makes the semicolon inert inside single quotes.
      expect(cmd, contains("'user; rm -rf /'"));
    });
  });
}
