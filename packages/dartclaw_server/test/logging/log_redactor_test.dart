import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/logging/log_redactor.dart';
import 'package:test/test.dart';

void main() {
  group('LogRedactor', () {
    late LogRedactor redactor;

    setUp(() {
      redactor = LogRedactor();
    });

    test('delegates to MessageRedactor — redacts Anthropic API keys', () {
      const input = 'Using key sk-ant-abc123_XYZ-def456 for auth';
      final result = redactor.redact(input);
      expect(result, contains('***'));
      expect(result, isNot(contains('def456')));
    });

    test('redacts Bearer tokens with proportional reveal', () {
      const input = 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig';
      final result = redactor.redact(input);
      expect(result, contains('***'));
      expect(result, isNot(contains('payload.sig')));
    });

    test('does not modify normal text', () {
      const input = 'Normal log message with session=abc123 and turn=def456';
      expect(redactor.redact(input), equals(input));
    });

    test('supports custom patterns via MessageRedactor', () {
      final customRedactor = MessageRedactor(extraPatterns: [r'SECRET_\w+']);
      final custom = LogRedactor(redactor: customRedactor);
      const input = 'Found SECRET_PASSWORD in config';
      final result = custom.redact(input);
      expect(result, contains('***'));
      expect(result, isNot(contains('SECRET_PASSWORD')));
    });

    test('applies multiple patterns in single input', () {
      const input = 'key=sk-ant-abc123def456 header=Bearer xyz.abc.def';
      final result = redactor.redact(input);
      expect(result, isNot(contains('def456')));
      expect(result, isNot(contains('abc.def')));
    });
  });
}
