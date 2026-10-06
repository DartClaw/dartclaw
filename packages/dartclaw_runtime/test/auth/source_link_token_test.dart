import 'package:dartclaw_runtime/src/auth/hmac_signature.dart';
import 'package:dartclaw_runtime/src/auth/session_token.dart';
import 'package:dartclaw_runtime/src/auth/source_link_token.dart';
import 'package:test/test.dart';

void main() {
  final key = 'a' * 64;

  group('hmac signature', () {
    test('session cookies and source links share one signing construction', () {
      final cookiePayload = createSessionToken(key).split('.');
      final linkPayload = createSourceLinkToken(layer: 'wiki', locator: 'wiki/a.md', key: key).split('.');

      expect(cookiePayload[1], hmacSign(cookiePayload[0], key));
      expect(linkPayload[1], hmacSign(linkPayload[0], key));
    });

    test('verification rejects a signature made under another key', () {
      expect(hmacVerify('data', hmacSign('data', key), key), isTrue);
      expect(hmacVerify('data', hmacSign('data', 'b' * 64), key), isFalse);
    });
  });

  group('source link token', () {
    test('a signed token names its layer and locator', () {
      final token = createSourceLinkToken(layer: 'wiki', locator: 'wiki/team notes.md', key: key);

      expect(validateSourceLinkToken(token, key: key), (layer: 'wiki', locator: 'wiki/team notes.md'));
    });

    test('is URL-safe, so it travels in a query parameter unescaped', () {
      final token = createSourceLinkToken(layer: 'kg', locator: '42', key: key);

      expect(token, matches(RegExp(r'^[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+$')));
    });

    test('refuses an altered signature', () {
      final token = createSourceLinkToken(layer: 'wiki', locator: 'wiki/a.md', key: key);
      final parts = token.split('.');
      final altered = '${parts[0]}.${parts[1].substring(0, parts[1].length - 1)}${parts[1].endsWith('A') ? 'B' : 'A'}';

      expect(validateSourceLinkToken(altered, key: key), isNull);
    });

    test('refuses an altered locator, because the signature covers the payload', () {
      final forged = createSourceLinkToken(layer: 'wiki', locator: 'wiki/secret.md', key: key).split('.').first;
      final genuine = createSourceLinkToken(layer: 'wiki', locator: 'wiki/a.md', key: key).split('.').last;

      expect(validateSourceLinkToken('$forged.$genuine', key: key), isNull);
    });

    test('refuses a token signed under another key, as after a gateway token rotation', () {
      final token = createSourceLinkToken(layer: 'wiki', locator: 'wiki/a.md', key: key);

      expect(validateSourceLinkToken(token, key: 'b' * 64), isNull);
    });

    test('expires at the session cookie age limit', () {
      final issued = DateTime(2026, 1, 1);
      final token = createSourceLinkToken(layer: 'wiki', locator: 'wiki/a.md', key: key, now: issued);

      expect(validateSourceLinkToken(token, key: key, now: issued.add(sessionTtl)), isNotNull);
      expect(
        validateSourceLinkToken(token, key: key, now: issued.add(sessionTtl + const Duration(seconds: 1))),
        isNull,
      );
    });

    test('refuses garbage, an empty signature and an unsigned token when a key is set', () {
      final unsigned = createSourceLinkToken(layer: 'wiki', locator: 'wiki/a.md');

      expect(validateSourceLinkToken('', key: key), isNull);
      expect(validateSourceLinkToken('garbage', key: key), isNull);
      expect(validateSourceLinkToken('.', key: key), isNull);
      expect(validateSourceLinkToken('$unsigned.', key: key), isNull);
      expect(validateSourceLinkToken(unsigned, key: key), isNull);
    });

    test('a session cookie is not a source link', () {
      expect(validateSourceLinkToken(createSessionToken(key), key: key), isNull);
    });

    test('without a key the token carries no signature and opens', () {
      final token = createSourceLinkToken(layer: 'kg', locator: '7');

      expect(token, isNot(contains('.')));
      expect(validateSourceLinkToken(token), (layer: 'kg', locator: '7'));
    });

    test('without a key a signed token is refused rather than read', () {
      final signed = createSourceLinkToken(layer: 'kg', locator: '7', key: key);

      expect(validateSourceLinkToken(signed), isNull);
    });
  });
}
