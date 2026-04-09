import 'package:dartclaw_security/dartclaw_security.dart';
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

    test('redacts Stripe test and publishable keys', () {
      expect(redactor.redact('sk_test_longSecretKeyValue12345'), contains('***'));
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

    test('redacts Bearer tokens', () {
      const input = 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig';
      final result = redactor.redact(input);
      expect(result, contains('***'));
      expect(result, isNot(contains('payload.sig')));
    });

    test('fully redacts PEM blocks', () {
      const input =
          'cert:\n-----BEGIN RSA PRIVATE KEY-----\n'
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
  });

  group('MessageRedactor — custom patterns', () {
    test('applies extra patterns alongside built-ins', () {
      final r = MessageRedactor(extraPatterns: [r'CUSTOM_\w+']);
      expect(r.redact('CUSTOM_SECRET_123'), contains('***'));
      expect(r.redact('sk-ant-abc123'), contains('***')); // Built-in still works
    });

    test('invalid extra pattern is skipped without throwing', () {
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
      expect(redactor.redact(once), equals(once));
    });

    test('PEM block idempotency', () {
      const input = '-----BEGIN RSA PRIVATE KEY-----\ndata\n-----END RSA PRIVATE KEY-----';
      final once = redactor.redact(input);
      expect(redactor.redact(once), equals(once));
      expect(once, equals('[REDACTED]'));
    });
  });

  // ---------------------------------------------------------------------------
  // TI13: recompilePatterns()
  // ---------------------------------------------------------------------------

  group('MessageRedactor.recompilePatterns()', () {
    test('new pattern takes effect after recompile', () {
      final r = MessageRedactor();
      const input = 'XYZWIDGET-abc123def456';
      // Before recompile: not matched by any built-in
      expect(r.redact(input), equals(input));

      r.recompilePatterns([r'XYZWIDGET-\S+']);
      expect(r.redact(input), contains('***'));
      expect(r.redact(input), isNot(contains('abc123def456')));
    });

    test('old extra pattern removed after recompile with empty list', () {
      final r = MessageRedactor(extraPatterns: [r'XYZWIDGET-\S+']);
      const input = 'XYZWIDGET-abc123def456';
      expect(r.redact(input), contains('***'));

      r.recompilePatterns([]);
      expect(r.redact(input), equals(input));
    });

    test('built-in patterns still apply after recompile', () {
      final r = MessageRedactor(extraPatterns: [r'MYTOKEN=\S+']);
      r.recompilePatterns([]);

      // Built-in Anthropic key pattern still works
      const input = 'Using sk-ant-abc123_XYZ-def456 for auth';
      expect(r.redact(input), contains('***'));
    });

    test('recompile with invalid pattern skips it without throwing', () {
      final r = MessageRedactor();
      expect(() => r.recompilePatterns([r'(unclosed']), returnsNormally);
      expect(r.redact('normal text'), equals('normal text'));
    });

    test('multiple recompiles: only latest patterns active', () {
      final r = MessageRedactor();
      r.recompilePatterns([r'FIRST=\S+']);
      r.recompilePatterns([r'SECOND=\S+']);

      expect(r.redact('FIRST=secret'), equals('FIRST=secret')); // old pattern gone
      expect(r.redact('SECOND=secret'), contains('***')); // new pattern active
    });
  });
}
