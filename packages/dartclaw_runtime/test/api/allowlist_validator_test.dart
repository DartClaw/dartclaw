import 'package:dartclaw_runtime/src/api/allowlist_validator.dart';
import 'package:test/test.dart';

void main() {
  group('Signal allowlist entries are judged by the channel predicates', () {
    // TD-142: this validator used to re-derive Signal identity, and diverged in
    // both directions — stricter on UUIDs (lowercase only, so an identifier the
    // channel accepts could not be configured) and looser on phones (anything
    // starting with `+`, so an unusable entry was storable and then never
    // matched a sender).
    test('a mixed-case UUID is accepted, because the channel accepts it', () {
      expect(validateAllowlistEntry('signal', 'A1B2C3D4-E5F6-7890-ABCD-EF1234567890'), isNull);
    });

    test('and is stored in the one spelling an inbound sender resolves to', () {
      expect(
        canonicalAllowlistEntry('signal', 'A1B2C3D4-E5F6-7890-ABCD-EF1234567890'),
        'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
      );
    });

    test('a malformed phone beginning with + is refused', () {
      expect(validateAllowlistEntry('signal', '+abc'), isNotNull);
      expect(validateAllowlistEntry('signal', '+'), isNotNull);
      expect(validateAllowlistEntry('signal', '+0123'), isNotNull, reason: 'E.164 country codes do not start with 0');
    });

    test('a well-formed phone is accepted and stored as given', () {
      expect(validateAllowlistEntry('signal', '+15551234567'), isNull);
      expect(canonicalAllowlistEntry('signal', '+15551234567'), '+15551234567');
    });
  });

  group('other channels are unchanged', () {
    test('WhatsApp entries must be JIDs', () {
      expect(validateAllowlistEntry('whatsapp', '1234567890@s.whatsapp.net'), isNull);
      expect(validateAllowlistEntry('whatsapp', '1234567890'), isNotNull);
    });

    test('Google Chat entries take either supported shape', () {
      expect(validateAllowlistEntry('google_chat', 'users/123'), isNull);
      expect(validateAllowlistEntry('google_chat', 'spaces/AAA/users/123'), isNull);
      expect(validateAllowlistEntry('google_chat', '123'), isNotNull);
    });

    test('an entry is never canonicalized outside Signal', () {
      expect(canonicalAllowlistEntry('whatsapp', 'ABC@s.whatsapp.net'), 'ABC@s.whatsapp.net');
    });

    test('an empty entry and an unknown channel are refused', () {
      expect(validateAllowlistEntry('signal', ''), isNotNull);
      expect(validateAllowlistEntry('telegram', 'x'), isNotNull);
    });
  });
}
