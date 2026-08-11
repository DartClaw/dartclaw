import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:test/test.dart';

void main() {
  late MessageRedactor redactor;

  setUp(() {
    redactor = MessageRedactor();
  });

  group('MessageRedactor', () {
    test('redacts built-in secret patterns while preserving safe context', () {
      final cases =
          <
            ({
              String input,
              List<String> expectedContains,
              List<String> notContains,
              String? expectedEquals,
              bool startsWithStripeLivePrefix,
            })
          >[
            (
              input: 'key: sk_live_abc123def456ghi789',
              expectedContains: ['***'],
              notContains: ['ghi789'],
              expectedEquals: null,
              startsWithStripeLivePrefix: true,
            ),
            (
              input: 'sk_test_longSecretKeyValue12345',
              expectedContains: ['***'],
              notContains: const [],
              expectedEquals: null,
              startsWithStripeLivePrefix: false,
            ),
            (
              input: 'pk_live_abc123',
              expectedContains: ['***'],
              notContains: const [],
              expectedEquals: null,
              startsWithStripeLivePrefix: false,
            ),
            (
              input: 'pk_test_xyz789',
              expectedContains: ['***'],
              notContains: const [],
              expectedEquals: null,
              startsWithStripeLivePrefix: false,
            ),
            (
              input: 'Using sk-ant-abc123_XYZ-def456 for auth',
              expectedContains: ['***'],
              notContains: ['def456'],
              expectedEquals: null,
              startsWithStripeLivePrefix: false,
            ),
            (
              input: 'AWS key: AKIAIOSFODNN7EXAMPLE',
              expectedContains: ['***'],
              notContains: ['EXAMPLE'],
              expectedEquals: null,
              startsWithStripeLivePrefix: false,
            ),
            (
              input: 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig',
              expectedContains: ['***'],
              notContains: ['payload.sig'],
              expectedEquals: null,
              startsWithStripeLivePrefix: false,
            ),
            (
              input:
                  'cert:\n-----BEGIN RSA PRIVATE KEY-----\n'
                  'MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGcY5unA67hq\n'
                  '-----END RSA PRIVATE KEY-----\ndone',
              expectedContains: ['[REDACTED]', 'cert:\n', '\ndone'],
              notContains: ['MIIEow'],
              expectedEquals: null,
              startsWithStripeLivePrefix: false,
            ),
            (
              input: '-----BEGIN CERTIFICATE-----\ndata\n-----END CERTIFICATE-----',
              expectedContains: const [],
              notContains: const [],
              expectedEquals: '[REDACTED]',
              startsWithStripeLivePrefix: false,
            ),
            (
              input: 'prefix\n-----BEGIN PRIVATE KEY-----\nunterminated-secret',
              expectedContains: ['prefix\n', '[REDACTED]'],
              notContains: ['unterminated-secret'],
              expectedEquals: null,
              startsWithStripeLivePrefix: false,
            ),
          ];

      for (final (:input, :expectedContains, :notContains, :expectedEquals, :startsWithStripeLivePrefix) in cases) {
        final result = redactor.redact(input);
        if (expectedEquals != null) {
          expect(result, equals(expectedEquals), reason: input);
        }
        if (startsWithStripeLivePrefix) {
          expect(result, startsWith('key: sk_live_'), reason: input);
        }
        for (final text in expectedContains) {
          expect(result, contains(text), reason: input);
        }
        for (final text in notContains) {
          expect(result, isNot(contains(text)), reason: input);
        }
      }
    });

    test('uses proportional reveal for custom pattern matches', () {
      final cases = <({MessageRedactor redactor, String input, String expected})>[
        (
          redactor: MessageRedactor(extraPatterns: [r'XXXX']),
          input: 'prefix XXXX suffix',
          expected: 'prefix XX*** suffix',
        ),
        (
          redactor: MessageRedactor(extraPatterns: [r'ABCDEFGHIJKL']),
          input: 'prefix ABCDEFGHIJKL suffix',
          expected: 'prefix ABCDEF*** suffix',
        ),
        (
          redactor: MessageRedactor(extraPatterns: [r'A{20}']),
          input: 'prefix ${'A' * 20} suffix',
          expected: 'prefix ${'A' * 8}*** suffix',
        ),
      ];

      for (final (:redactor, :input, :expected) in cases) {
        expect(redactor.redact(input), expected);
      }
    });

    test('handles custom patterns, safe text, multiple matches, and idempotency', () {
      final custom = MessageRedactor(extraPatterns: [r'CUSTOM_\w+']);
      expect(custom.redact('CUSTOM_SECRET_123'), contains('***'));
      expect(custom.redact('sk-ant-abc123'), contains('***'));
      expect(MessageRedactor(extraPatterns: [r'(unclosed']).redact('normal text'), 'normal text');

      expect(redactor.redact(''), '');
      const normal = 'Normal log message with session=abc123 and turn=def456';
      expect(redactor.redact(normal), normal);

      const multi = 'key=sk-ant-abc123 header=Bearer xyz.abc.def token=sk_live_longkey123';
      final multiResult = redactor.redact(multi);
      expect(multiResult, isNot(contains('abc123')));
      expect(multiResult, isNot(contains('abc.def')));
      expect(multiResult, isNot(contains('longkey123')));

      const stripe = 'key: sk_live_verylongsecretkeyvalue12345';
      final once = redactor.redact(stripe);
      expect(redactor.redact(once), once);

      const pem = '-----BEGIN RSA PRIVATE KEY-----\ndata\n-----END RSA PRIVATE KEY-----';
      final pemOnce = redactor.redact(pem);
      expect(redactor.redact(pemOnce), pemOnce);
      expect(pemOnce, '[REDACTED]');
    });

    test('redacts complete boundary-aware secret assignments', () {
      final cases = <({String input, String expected})>[
        (input: 'password=correct horse battery', expected: 'password=***'),
        (input: 'password: correct horse battery', expected: 'password: ***'),
        (input: 'token: opaque token value', expected: 'token: ***'),
        (input: 'Password: hunter2', expected: 'Password: ***'),
        (input: 'Password: "correct horse battery"', expected: 'Password: ***'),
        (input: 'Token: abc', expected: 'Token: ***'),
        (input: 'Token: abc.def.ghi', expected: 'Token: ***'),
        (input: 'Authorization: Basic dXNlcjpwYXNz', expected: 'Authorization: ***'),
        (
          input: 'Proxy-Authorization: Digest username="agent", realm="runtime", response="opaque"',
          expected: 'Proxy-Authorization: ***',
        ),
        (input: 'Use api_key: inline-value', expected: 'Use api_key: ***'),
        (input: 'My password: hunter2', expected: 'My password: ***'),
        (input: 'Credentials are Token: abc', expected: 'Credentials are Token: ***'),
        (
          input: '{"password": "hunter2", "Token": "abc", "api_key": "inline-value", "max_tokens": 4096}',
          expected: '{"password": "***", "Token": "***", "api_key": "***", "max_tokens": 4096}',
        ),
        (input: 'api_keys: first key second key', expected: 'api_keys: ***'),
        (input: '- access_tokens: alpha beta', expected: '- access_tokens: ***'),
        (input: 'client_secrets = red blue', expected: 'client_secrets = ***'),
        (input: 'database_passwords=one two\nnext field', expected: 'database_passwords=***\nnext field'),
        (input: 'OPENAI_API_KEY=opaque provider key', expected: 'OPENAI_API_KEY=***'),
        (input: 'POSTGRES_PASSWORD=correct horse battery', expected: 'POSTGRES_PASSWORD=***'),
        (input: 'GITHUB_TOKEN=opaque token value', expected: 'GITHUB_TOKEN=***'),
        (input: 'SERVICE_CREDENTIALS=opaque service value', expected: 'SERVICE_CREDENTIALS=***'),
        (input: 'refresh_tokens=opaque refresh value', expected: 'refresh_tokens=***'),
        (input: 'password=secret status=healthy', expected: 'password=*** status=healthy'),
        (
          input: 'password=secret and then restart the service.',
          expected: 'password=*** and then restart the service.',
        ),
        (input: 'password: hunter2, then click Save.', expected: 'password: ***, then click Save.'),
        (input: 'password=secret, status: healthy', expected: 'password=***, status: healthy'),
        (input: 'password: secret, status=healthy', expected: 'password: ***, status=healthy'),
        (input: 'password=secret; status: healthy', expected: 'password=***; status: healthy'),
        (input: 'password: secret status=healthy', expected: 'password: *** status=healthy'),
        (input: 'password=abc]SECRET_SUFFIX', expected: 'password=***'),
        (input: 'password: abc}SECRET_SUFFIX', expected: 'password: ***'),
        (input: 'password=abc. Restart the service.', expected: 'password=***. Restart the service.'),
        (input: 'password=secret, status=healthy', expected: 'password=***, status=healthy'),
        (input: '{password: secret, token: abc}', expected: '{password: ***, token: ***}'),
        (
          input:
              'wrapper: {encryption_key: opaque-encryption-key, JWTSigningKey: opaque-jwt-key, '
              'RSAEncryptionKey: opaque-rsa-key}',
          expected: 'wrapper: {encryption_key: ***, JWTSigningKey: ***, RSAEncryptionKey: ***}',
        ),
        (
          input: '{"access_tokens":["alpha","beta"],"max_tokens":4096}',
          expected: '{"access_tokens":"***","max_tokens":4096}',
        ),
        (
          input: '{\n  "access_tokens": [\n    "alpha",\n    "beta"\n  ],\n  "max_tokens": 4096\n}',
          expected: '{\n  "access_tokens": "***",\n  "max_tokens": 4096\n}',
        ),
        (
          input: '{"credentials":{"token":"abc"},"password_policy":{"required":true}}',
          expected: '{"credentials":"***","password_policy":{"required":true}}',
        ),
        (input: 'aws_secret_access_key=opaque-secret', expected: 'aws_secret_access_key=***'),
      ];

      for (final (:input, :expected) in cases) {
        expect(redactor.redact(input), expected, reason: input);
      }
    });

    test('does not treat prose or unrelated suffixes as secret assignments', () {
      final cases = [
        'Reset your password: use Settings, then sign in again.',
        'The token: field describes a parser concept.',
        'The password: field is required.',
        'Password: correct horse battery.',
        'Password: use Settings, then sign in again.',
        'Password: use hunter2',
        'Token: field describes a parser concept.',
        'Authorization: Basic authentication is enabled.',
        'Authorization: use Settings, then sign in again.',
        'max_tokens=4096',
        'input_tokens=2048',
        'completion_tokens=1024',
        'password_policy=strict',
        'secret_keeper=enabled',
        'has_private_key=true',
        'requires_database_password=false',
        'supports_client_secret=true',
        'is_set_cookie=false',
        '{"max_tokens": 4096, "has_private_key": false, "password_policy": "strict"}',
      ];

      for (final input in cases) {
        expect(redactor.redact(input), input, reason: input);
      }

      const safeJson = '{"max_tokens":[4096],"password_policy":{"required":true}}';
      expect(redactor.redact(safeJson), safeJson);
    });

    test('classifies whole structured credential keys', () {
      for (final key in [
        'POSTGRES_PASSWORD',
        'GITHUB_TOKEN',
        'SERVICE_CREDENTIALS',
        'refreshTokens',
        'OPENAI_API_KEY',
        'AWS_SECRET_ACCESS_KEY',
        'encryption_key',
        'signingKey',
        'JWTSigningKey',
        'RSAEncryptionKey',
      ]) {
        expect(MessageRedactor.isSecretKey(key), isTrue, reason: key);
      }
      for (final key in [
        'max_tokens',
        'completionTokens',
        'hasPrivateKey',
        'requiresDatabasePassword',
        'supportsClientSecret',
        'isSetCookie',
        'access_key',
        'sshKey',
        'hasSigningKey',
        'encryption_key_id',
        'signing_key_algorithm',
      ]) {
        expect(MessageRedactor.isSecretKey(key), isFalse, reason: key);
      }
    });

    test('keeps assignment redaction idempotent', () {
      for (final input in [
        'aws_secret_access_key=opaque-secret',
        '{"access_tokens":["alpha","beta"]}',
        'wrapper: {encryption_key: opaque-encryption-key, JWTSigningKey: opaque-jwt-key, '
            'RSAEncryptionKey: opaque-rsa-key}',
      ]) {
        final redacted = redactor.redact(input);
        expect(redactor.redact(redacted), redacted, reason: input);
      }
    });
  });

  group('MessageRedactor.recompilePatterns()', () {
    test('replaces extra patterns while preserving built-ins and ignoring invalid regexes', () {
      final widget = MessageRedactor();
      const widgetInput = 'XYZWIDGET-abc123def456';
      expect(widget.redact(widgetInput), widgetInput);
      widget.recompilePatterns([r'XYZWIDGET-\S+']);
      expect(widget.redact(widgetInput), contains('***'));
      expect(widget.redact(widgetInput), isNot(contains('abc123def456')));

      final removed = MessageRedactor(extraPatterns: [r'XYZWIDGET-\S+']);
      expect(removed.redact(widgetInput), contains('***'));
      removed.recompilePatterns([]);
      expect(removed.redact(widgetInput), widgetInput);

      final builtIn = MessageRedactor(extraPatterns: [r'MYTOKEN=\S+']);
      builtIn.recompilePatterns([]);
      expect(builtIn.redact('Using sk-ant-abc123_XYZ-def456 for auth'), contains('***'));

      final invalid = MessageRedactor();
      expect(() => invalid.recompilePatterns([r'(unclosed']), returnsNormally);
      expect(invalid.redact('normal text'), 'normal text');

      final latest = MessageRedactor();
      latest.recompilePatterns([r'FIRST=\S+']);
      latest.recompilePatterns([r'SECOND=\S+']);
      expect(latest.redact('FIRST=secret'), 'FIRST=secret');
      expect(latest.redact('SECOND=secret'), contains('***'));
    });
  });
}
