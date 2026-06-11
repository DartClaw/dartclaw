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
