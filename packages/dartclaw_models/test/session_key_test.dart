import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  group('SessionKey', () {
    final keyCases = [
      (name: 'webSession default', actual: SessionKey.webSession(), expected: 'agent:main:web:'),
      (
        name: 'webSession custom agentId',
        actual: SessionKey.webSession(agentId: 'search'),
        expected: 'agent:search:web:',
      ),
      (name: 'dmShared default', actual: SessionKey.dmShared(), expected: 'agent:main:dm:shared'),
      (
        name: 'dmShared custom agentId',
        actual: SessionKey.dmShared(agentId: 'search'),
        expected: 'agent:search:dm:shared',
      ),
      (
        name: 'dmPerContact encodes peerId',
        actual: SessionKey.dmPerContact(peerId: '123@s.whatsapp.net'),
        expected: 'agent:main:dm:contact:123%40s.whatsapp.net',
      ),
      (
        name: 'dmPerChannelContact includes channelType and peerId',
        actual: SessionKey.dmPerChannelContact(channelType: 'whatsapp', peerId: '123@s.whatsapp.net'),
        expected: 'agent:main:dm:whatsapp:123%40s.whatsapp.net',
      ),
      (
        name: 'groupShared includes channelType and groupId',
        actual: SessionKey.groupShared(channelType: 'whatsapp', groupId: 'group@g.us'),
        expected: 'agent:main:group:whatsapp:group%40g.us',
      ),
      (
        name: 'groupPerMember includes channelType, groupId, and peerId',
        actual: SessionKey.groupPerMember(channelType: 'whatsapp', groupId: 'group@g.us', peerId: '123@s.whatsapp.net'),
        expected: 'agent:main:group:whatsapp:group%40g.us:123%40s.whatsapp.net',
      ),
      (
        name: 'cronSession format',
        actual: SessionKey.cronSession(jobId: 'daily-summary'),
        expected: 'agent:main:cron:daily-summary',
      ),
      (
        name: 'cronSession encodes jobId',
        actual: SessionKey.cronSession(jobId: 'job with spaces'),
        expected: 'agent:main:cron:job%20with%20spaces',
      ),
      (
        name: 'taskSession format',
        actual: SessionKey.taskSession(taskId: 'task-123'),
        expected: 'agent:main:task:task-123',
      ),
      (
        name: 'taskSession encodes taskId',
        actual: SessionKey.taskSession(taskId: 'task with spaces'),
        expected: 'agent:main:task:task%20with%20spaces',
      ),
    ];

    for (final testCase in keyCases) {
      test(testCase.name, () {
        expect(testCase.actual, testCase.expected);
      });
    }

    final invalidCases = [
      (name: 'dmPerContact empty peerId', build: () => SessionKey.dmPerContact(peerId: '')),
      (
        name: 'dmPerChannelContact empty peerId',
        build: () => SessionKey.dmPerChannelContact(channelType: 'whatsapp', peerId: ''),
      ),
      (name: 'groupShared empty groupId', build: () => SessionKey.groupShared(channelType: 'whatsapp', groupId: '')),
      (
        name: 'groupPerMember empty groupId',
        build: () => SessionKey.groupPerMember(channelType: 'whatsapp', groupId: '', peerId: '123@s.whatsapp.net'),
      ),
      (
        name: 'groupPerMember empty peerId',
        build: () => SessionKey.groupPerMember(channelType: 'whatsapp', groupId: 'group@g.us', peerId: ''),
      ),
      (name: 'taskSession empty taskId', build: () => SessionKey.taskSession(taskId: '')),
    ];

    for (final testCase in invalidCases) {
      test('${testCase.name} throws ArgumentError', () {
        expect(testCase.build, throwsArgumentError);
      });
    }

    group('parse', () {
      final parseCases = [
        (
          name: 'web session key',
          key: SessionKey(agentId: 'main', scope: 'web').toString(),
          scope: 'web',
          identifiers: '',
        ),
        (
          name: 'dmPerContact key',
          key: SessionKey.dmPerContact(peerId: 'test@example.com'),
          scope: 'dm',
          identifiers: 'contact:test%40example.com',
        ),
        (
          name: 'groupPerMember preserves colons',
          key: SessionKey.groupPerMember(channelType: 'whatsapp', groupId: 'group@g.us', peerId: '123@s.whatsapp.net'),
          scope: 'group',
          identifiers: 'whatsapp:group%40g.us:123%40s.whatsapp.net',
        ),
        (
          name: 'task session key',
          key: SessionKey.taskSession(taskId: 'task-42'),
          scope: 'task',
          identifiers: 'task-42',
        ),
      ];

      for (final testCase in parseCases) {
        test('round-trip for ${testCase.name}', () {
          final parsed = SessionKey.parse(testCase.key);

          expect(parsed.agentId, 'main');
          expect(parsed.scope, testCase.scope);
          expect(parsed.identifiers, testCase.identifiers);
        });
      }

      test('invalid key throws FormatException', () {
        expect(() => SessionKey.parse('invalid'), throwsFormatException);
        expect(() => SessionKey.parse('foo:bar:baz:qux'), throwsFormatException);
      });
    });
  });
}
