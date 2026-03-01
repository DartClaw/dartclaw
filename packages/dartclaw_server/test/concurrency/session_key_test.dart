import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

/// Compatibility tests — verify SessionKey (now in dartclaw_core) is
/// accessible from dartclaw_server via the core re-export.
void main() {
  group('SessionKey (from core)', () {
    test('webSession format is agent:main:main:', () {
      expect(SessionKey.webSession(), 'agent:main:main:');
    });

    test('peerSession encodes peerId', () {
      final key = SessionKey.peerSession(agentId: 'main', peerId: 'wa:1234567890');
      expect(key, 'agent:main:per-peer:wa%3A1234567890');
    });

    test('parse invalid key throws FormatException', () {
      expect(() => SessionKey.parse('invalid'), throwsFormatException);
      expect(() => SessionKey.parse('foo:bar:baz:qux'), throwsFormatException);
    });
  });
}
