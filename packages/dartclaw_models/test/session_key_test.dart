import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  group('SessionKey', () {
    group('webSession', () {
      test('format is agent:main:web:', () {
        expect(SessionKey.webSession(), 'agent:main:web:');
      });

      test('custom agentId', () {
        expect(SessionKey.webSession(agentId: 'search'), 'agent:search:web:');
      });
    });

    group('dmShared', () {
      test('format is agent:main:dm:shared', () {
        expect(SessionKey.dmShared(), 'agent:main:dm:shared');
      });

      test('custom agentId', () {
        expect(SessionKey.dmShared(agentId: 'search'), 'agent:search:dm:shared');
      });
    });

    group('dmPerContact', () {
      test('encodes peerId', () {
        final key = SessionKey.dmPerContact(peerId: '123@s.whatsapp.net');
        expect(key, 'agent:main:dm:contact:123%40s.whatsapp.net');
      });

      test('empty peerId throws ArgumentError', () {
        expect(() => SessionKey.dmPerContact(peerId: ''), throwsArgumentError);
      });
    });

    group('dmPerChannelContact', () {
      test('format with channelType and peerId', () {
        final key = SessionKey.dmPerChannelContact(
          channelType: 'whatsapp',
          peerId: '123@s.whatsapp.net',
        );
        expect(key, 'agent:main:dm:whatsapp:123%40s.whatsapp.net');
      });

      test('empty peerId throws ArgumentError', () {
        expect(
          () => SessionKey.dmPerChannelContact(channelType: 'whatsapp', peerId: ''),
          throwsArgumentError,
        );
      });
    });

    group('groupShared', () {
      test('format with channelType and groupId', () {
        final key = SessionKey.groupShared(channelType: 'whatsapp', groupId: 'group@g.us');
        expect(key, 'agent:main:group:whatsapp:group%40g.us');
      });

      test('empty groupId throws ArgumentError', () {
        expect(
          () => SessionKey.groupShared(channelType: 'whatsapp', groupId: ''),
          throwsArgumentError,
        );
      });
    });

    group('groupPerMember', () {
      test('format with channelType, groupId, and peerId', () {
        final key = SessionKey.groupPerMember(
          channelType: 'whatsapp',
          groupId: 'group@g.us',
          peerId: '123@s.whatsapp.net',
        );
        expect(key, 'agent:main:group:whatsapp:group%40g.us:123%40s.whatsapp.net');
      });

      test('empty groupId throws ArgumentError', () {
        expect(
          () => SessionKey.groupPerMember(
            channelType: 'whatsapp',
            groupId: '',
            peerId: '123@s.whatsapp.net',
          ),
          throwsArgumentError,
        );
      });

      test('empty peerId throws ArgumentError', () {
        expect(
          () => SessionKey.groupPerMember(
            channelType: 'whatsapp',
            groupId: 'group@g.us',
            peerId: '',
          ),
          throwsArgumentError,
        );
      });
    });

    group('cronSession', () {
      test('produces correct format', () {
        expect(
          SessionKey.cronSession(jobId: 'daily-summary'),
          'agent:main:cron:daily-summary',
        );
      });

      test('encodes special characters in jobId', () {
        expect(
          SessionKey.cronSession(jobId: 'job with spaces'),
          'agent:main:cron:job%20with%20spaces',
        );
      });
    });

    group('parse', () {
      test('round-trip for web session key', () {
        final key = SessionKey(agentId: 'main', scope: 'web');
        final parsed = SessionKey.parse(key.toString());
        expect(parsed.agentId, 'main');
        expect(parsed.scope, 'web');
        expect(parsed.identifiers, '');
      });

      test('round-trip for dmPerContact key', () {
        final keyStr = SessionKey.dmPerContact(peerId: 'test@example.com');
        final parsed = SessionKey.parse(keyStr);
        expect(parsed.agentId, 'main');
        expect(parsed.scope, 'dm');
        expect(parsed.identifiers, 'contact:test%40example.com');
      });

      test('round-trip for groupPerMember preserves colons', () {
        final keyStr = SessionKey.groupPerMember(
          channelType: 'whatsapp',
          groupId: 'group@g.us',
          peerId: '123@s.whatsapp.net',
        );
        final parsed = SessionKey.parse(keyStr);
        expect(parsed.agentId, 'main');
        expect(parsed.scope, 'group');
        expect(parsed.identifiers, 'whatsapp:group%40g.us:123%40s.whatsapp.net');
      });

      test('invalid key throws FormatException', () {
        expect(() => SessionKey.parse('invalid'), throwsFormatException);
        expect(() => SessionKey.parse('foo:bar:baz:qux'), throwsFormatException);
      });
    });
  });
}
