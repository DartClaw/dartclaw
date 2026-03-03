import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late MessageRedactor redactor;

  setUp(() {
    redactor = MessageRedactor();
  });

  group('MessageRedactor — built-in patterns', () {
    test('redacts Stripe live keys with proportional reveal', () {
      const input = 'key: sk_live_abc123def456ghi789';
      final result = redactor.redact(input);
      expect(result, startsWith('key: sk_live_'));
      expect(result, contains('***'));
      expect(result, isNot(contains('ghi789')));
    });

    test('redacts Stripe test keys', () {
      const input = 'sk_test_longSecretKeyValue12345';
      final result = redactor.redact(input);
      expect(result, contains('***'));
      expect(result, isNot(contains('12345')));
    });

    test('redacts pk_live and pk_test keys', () {
      expect(redactor.redact('pk_live_abc123'), contains('***'));
      expect(redactor.redact('pk_test_xyz789'), contains('***'));
    });

    test('redacts Anthropic API keys', () {
      const input = 'Using sk-ant-abc123_XYZ-def456 for auth';
      final result = redactor.redact(input);
      expect(result, contains('***'));
      expect(result, isNot(contains('def456')));
    });

    test('redacts AWS access key IDs', () {
      const input = 'AWS key: AKIAIOSFODNN7EXAMPLE';
      final result = redactor.redact(input);
      expect(result, contains('***'));
      expect(result, isNot(contains('EXAMPLE')));
    });

    test('redacts AWS secret access keys (case-insensitive)', () {
      const input = 'aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';
      final result = redactor.redact(input);
      expect(result, contains('***'));
      expect(result, isNot(contains('EXAMPLEKEY')));
    });

    test('redacts Bearer tokens', () {
      const input = 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig';
      final result = redactor.redact(input);
      expect(result, contains('***'));
      expect(result, isNot(contains('payload.sig')));
    });

    test('redacts generic secret patterns', () {
      const input = 'api_key: my-super-secret-key-12345';
      final result = redactor.redact(input);
      expect(result, contains('***'));
      expect(result, isNot(contains('12345')));
    });

    test('redacts generic token patterns (case-insensitive)', () {
      const input = 'TOKEN=abcdef123456789';
      final result = redactor.redact(input);
      expect(result, contains('***'));
    });

    test('redacts generic password patterns', () {
      const input = 'password: hunter2secret';
      final result = redactor.redact(input);
      expect(result, contains('***'));
      expect(result, isNot(contains('secret')));
    });

    test('fully redacts PEM blocks', () {
      const input = 'cert:\n-----BEGIN RSA PRIVATE KEY-----\n'
          'MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGcY5unA67hq\n'
          '-----END RSA PRIVATE KEY-----\ndone';
      final result = redactor.redact(input);
      expect(result, contains('[REDACTED]'));
      expect(result, isNot(contains('MIIEow')));
      expect(result, contains('cert:\n'));
      expect(result, contains('\ndone'));
    });

    test('fully redacts PEM certificates', () {
      const input = '-----BEGIN CERTIFICATE-----\ndata\n-----END CERTIFICATE-----';
      final result = redactor.redact(input);
      expect(result, equals('[REDACTED]'));
    });
  });

  group('MessageRedactor — proportional reveal', () {
    test('short match: 4 chars -> 2 preserved', () {
      // Use a custom pattern to test exact proportional reveal behavior.
      final r = MessageRedactor(extraPatterns: [r'XXXX']);
      final result = r.redact('prefix XXXX suffix');
      expect(result, equals('prefix XX*** suffix'));
    });

    test('medium match: 12 chars -> 6 preserved', () {
      final r = MessageRedactor(extraPatterns: [r'ABCDEFGHIJKL']);
      final result = r.redact('prefix ABCDEFGHIJKL suffix');
      expect(result, equals('prefix ABCDEF*** suffix'));
    });

    test('long match: 20 chars -> 8 preserved (capped)', () {
      final r = MessageRedactor(extraPatterns: [r'A{20}']);
      final result = r.redact('prefix ${'A' * 20} suffix');
      expect(result, equals('prefix ${'A' * 8}*** suffix'));
    });

    test('very short match: 1 char -> 0 preserved', () {
      final r = MessageRedactor(extraPatterns: [r'Z']);
      final result = r.redact('prefix Z suffix');
      expect(result, equals('prefix *** suffix'));
    });
  });

  group('MessageRedactor — custom patterns', () {
    test('applies extra patterns alongside built-ins', () {
      final r = MessageRedactor(extraPatterns: [r'CUSTOM_\w+']);
      expect(r.redact('CUSTOM_SECRET_123'), contains('***'));
      // Built-in still works
      expect(r.redact('sk-ant-abc123'), contains('***'));
    });

    test('invalid extra pattern is skipped without throwing', () {
      // Unclosed group — invalid regex
      final r = MessageRedactor(extraPatterns: [r'(unclosed']);
      expect(r.redact('normal text'), equals('normal text'));
    });
  });

  group('MessageRedactor — edge cases', () {
    test('empty string returns empty string', () {
      expect(redactor.redact(''), equals(''));
    });

    test('normal text unchanged', () {
      const input = 'Normal log message with session=abc123 and turn=def456';
      expect(redactor.redact(input), equals(input));
    });

    test('multiple matches in single input all redacted', () {
      const input = 'key=sk-ant-abc123 header=Bearer xyz.abc.def token=sk_live_longkey123';
      final result = redactor.redact(input);
      expect(result, isNot(contains('abc123')));
      expect(result, isNot(contains('abc.def')));
      expect(result, isNot(contains('longkey123')));
    });

    test('idempotency: redact(redact(text)) == redact(text)', () {
      const input = 'key: sk_live_verylongsecretkeyvalue12345';
      final once = redactor.redact(input);
      final twice = redactor.redact(once);
      expect(twice, equals(once));
    });

    test('PEM block idempotency', () {
      const input = '-----BEGIN RSA PRIVATE KEY-----\ndata\n-----END RSA PRIVATE KEY-----';
      final once = redactor.redact(input);
      final twice = redactor.redact(once);
      expect(twice, equals(once));
      expect(once, equals('[REDACTED]'));
    });
  });
}
