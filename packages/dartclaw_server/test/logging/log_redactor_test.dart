import 'package:dartclaw_server/src/logging/log_redactor.dart';
import 'package:test/test.dart';

void main() {
  group('LogRedactor', () {
    late LogRedactor redactor;

    setUp(() {
      redactor = LogRedactor();
    });

    test('redacts Anthropic API keys', () {
      const input = 'Using key sk-ant-abc123_XYZ-def456 for auth';
      expect(redactor.redact(input), contains('[REDACTED]'));
      expect(redactor.redact(input), isNot(contains('sk-ant-')));
    });

    test('redacts 64-char hex tokens', () {
      final token = 'a' * 64;
      final input = 'Gateway token: $token';
      expect(redactor.redact(input), contains('[REDACTED]'));
      expect(redactor.redact(input), isNot(contains(token)));
    });

    test('redacts Bearer tokens', () {
      const input = 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig';
      expect(redactor.redact(input), contains('[REDACTED]'));
      expect(redactor.redact(input), isNot(contains('Bearer eyJ')));
    });

    test('does not modify normal text', () {
      const input = 'Normal log message with session=abc123 and turn=def456';
      expect(redactor.redact(input), equals(input));
    });

    test('supports custom patterns', () {
      final custom = LogRedactor(patterns: [r'SECRET_\w+']);
      const input = 'Found SECRET_PASSWORD in config';
      expect(custom.redact(input), contains('[REDACTED]'));
      expect(custom.redact(input), isNot(contains('SECRET_PASSWORD')));
    });

    test('applies multiple patterns in single input', () {
      final token = 'a' * 64;
      final input = 'key=sk-ant-abc123 token=$token header=Bearer xyz.abc.def';
      final result = redactor.redact(input);
      expect(result, isNot(contains('sk-ant-')));
      expect(result, isNot(contains(token)));
      expect(result, isNot(contains('Bearer xyz')));
    });
  });
}
