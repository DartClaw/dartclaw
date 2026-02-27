import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('SessionKey', () {
    test('webSession format is agent:main:main:', () {
      expect(SessionKey.webSession(), 'agent:main:main:');
    });

    test('webSession with custom agentId', () {
      expect(SessionKey.webSession(agentId: 'search'), 'agent:search:main:');
    });

    test('peerSession URL-encodes identifiers', () {
      final key = SessionKey.peerSession(agentId: 'main', peerId: 'wa:1234567890');
      expect(key, 'agent:main:per-peer:wa%3A1234567890');
    });

    test('parse round-trip for simple key', () {
      final key = SessionKey(agentId: 'main', scope: 'main');
      final parsed = SessionKey.parse(key.toString());
      expect(parsed.agentId, 'main');
      expect(parsed.scope, 'main');
      expect(parsed.identifiers, '');
    });

    test('parse round-trip with special characters', () {
      final key = SessionKey(agentId: 'main', scope: 'per-peer', identifiers: 'wa:123@test');
      final parsed = SessionKey.parse(key.toString());
      expect(parsed.identifiers, 'wa:123@test');
    });

    test('parse invalid key throws FormatException', () {
      expect(() => SessionKey.parse('invalid'), throwsFormatException);
      expect(() => SessionKey.parse('foo:bar:baz:qux'), throwsFormatException);
    });
  });
}
