import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('SessionKey', () {
    test('webSession format is agent:main:main:', () {
      expect(SessionKey.webSession(), 'agent:main:main:');
    });

    test('webSession with custom agentId', () {
      expect(SessionKey.webSession(agentId: 'search'), 'agent:search:main:');
    });

    test('peerSession encodes peerId', () {
      final key = SessionKey.peerSession(agentId: 'main', peerId: '123@s.whatsapp.net');
      expect(key, 'agent:main:per-peer:123%40s.whatsapp.net');
    });

    test('channelPeerSession produces correct format', () {
      final key = SessionKey.channelPeerSession(
        channelType: 'whatsapp',
        channelId: 'group@g.us',
        peerId: '123@s.whatsapp.net',
      );
      expect(key, 'agent:main:per-channel-peer:whatsapp:group%40g.us:123%40s.whatsapp.net');
    });

    test('channelPeerSession with custom agentId', () {
      final key = SessionKey.channelPeerSession(
        agentId: 'custom',
        channelType: 'whatsapp',
        channelId: 'group@g.us',
        peerId: '123@s.whatsapp.net',
      );
      expect(key, startsWith('agent:custom:per-channel-peer:'));
    });

    test('accountChannelPeerSession includes account scope', () {
      final key = SessionKey.accountChannelPeerSession(
        accountId: 'acct1',
        channelType: 'whatsapp',
        channelId: 'group@g.us',
        peerId: '123@s.whatsapp.net',
      );
      expect(key, startsWith('agent:main:per-account-channel-peer:'));
      expect(key, contains('acct1'));
    });

    test('cronSession produces correct format', () {
      expect(
        SessionKey.cronSession(jobId: 'daily-summary'),
        'agent:main:cron:daily-summary',
      );
    });

    test('cronSession encodes special characters in jobId', () {
      expect(
        SessionKey.cronSession(jobId: 'job with spaces'),
        'agent:main:cron:job%20with%20spaces',
      );
    });

    test('parse round-trip for simple key', () {
      final key = SessionKey(agentId: 'main', scope: 'main');
      final parsed = SessionKey.parse(key.toString());
      expect(parsed.agentId, 'main');
      expect(parsed.scope, 'main');
      expect(parsed.identifiers, '');
    });

    test('parse round-trip for peerSession key', () {
      final keyStr = SessionKey.peerSession(agentId: 'main', peerId: 'test@example.com');
      final parsed = SessionKey.parse(keyStr);
      expect(parsed.agentId, 'main');
      expect(parsed.scope, 'per-peer');
      // identifiers is stored pre-encoded
      expect(parsed.identifiers, 'test%40example.com');
    });

    test('parse round-trip for channelPeerSession preserves colons', () {
      final keyStr = SessionKey.channelPeerSession(
        channelType: 'whatsapp',
        channelId: 'group@g.us',
        peerId: '123@s.whatsapp.net',
      );
      final parsed = SessionKey.parse(keyStr);
      expect(parsed.agentId, 'main');
      expect(parsed.scope, 'per-channel-peer');
      // identifiers contains encoded components separated by colons
      expect(parsed.identifiers, 'whatsapp:group%40g.us:123%40s.whatsapp.net');
    });

    test('parse invalid key throws FormatException', () {
      expect(() => SessionKey.parse('invalid'), throwsFormatException);
      expect(() => SessionKey.parse('foo:bar:baz:qux'), throwsFormatException);
    });
  });
}
