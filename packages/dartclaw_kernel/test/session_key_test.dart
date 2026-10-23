import 'package:dartclaw_kernel/dartclaw_kernel.dart';
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
        name: 'dmShared with a thread',
        actual: SessionKey.dmShared(threadId: '1700000000.000100'),
        expected: 'agent:main:dm:shared:thread:1700000000.000100',
      ),
      (
        name: 'dmPerContact with a thread',
        actual: SessionKey.dmPerContact(peerId: 'U1', threadId: '1700000000.000100'),
        expected: 'agent:main:dm:contact:U1:thread:1700000000.000100',
      ),
      (
        name: 'dmPerChannelContact with a thread',
        actual: SessionKey.dmPerChannelContact(channelType: 'slack', peerId: 'U1', threadId: '1700000000.000100'),
        expected: 'agent:main:dm:slack:U1:thread:1700000000.000100',
      ),
      (
        name: 'groupShared with a thread',
        actual: SessionKey.groupShared(channelType: 'slack', groupId: 'C1', threadId: '1700000000.000100'),
        expected: 'agent:main:group:slack:C1:thread:1700000000.000100',
      ),
      (
        name: 'groupPerMember with a thread',
        actual: SessionKey.groupPerMember(
          channelType: 'slack',
          groupId: 'C1',
          peerId: 'U1',
          threadId: '1700000000.000100',
        ),
        expected: 'agent:main:group:slack:C1:U1:thread:1700000000.000100',
      ),
      (
        name: 'a thread id is encoded like every other component',
        actual: SessionKey.groupShared(channelType: 'slack', groupId: 'C1', threadId: 'a:b/c'),
        expected: 'agent:main:group:slack:C1:thread:a%3Ab%2Fc',
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
      (
        name: 'logicalAgentSession encodes agent and conversation IDs',
        actual: SessionKey.logicalAgentSession(agentId: 'review:security', conversationId: 'turn/123'),
        expected: 'agent:review%3Asecurity:logical:turn%2F123',
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
      (
        name: 'groupShared empty threadId',
        build: () => SessionKey.groupShared(channelType: 'slack', groupId: 'C1', threadId: ''),
      ),
      (name: 'taskSession empty taskId', build: () => SessionKey.taskSession(taskId: '')),
      (
        name: 'logicalAgentSession empty agentId',
        build: () => SessionKey.logicalAgentSession(agentId: '', conversationId: 'id'),
      ),
      (
        name: 'logicalAgentSession empty conversationId',
        build: () => SessionKey.logicalAgentSession(agentId: 'search', conversationId: ''),
      ),
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

    group('channelRoute', () {
      final routeCases = [
        (
          name: 'a per-channel DM key names its channel and peer',
          key: SessionKey.dmPerChannelContact(channelType: 'whatsapp', peerId: '123@s.whatsapp.net'),
          route: (channelType: 'whatsapp', recipientId: '123@s.whatsapp.net', threadId: null),
        ),
        (
          name: 'a Slack DM thread key keeps the peer and returns the thread, which a two-part split refused',
          key: SessionKey.dmPerChannelContact(channelType: 'slack', peerId: 'U1', threadId: '1700000000.000100'),
          route: (channelType: 'slack', recipientId: 'U1', threadId: '1700000000.000100'),
        ),
        (
          name: 'a per-contact DM key spans channels',
          key: SessionKey.dmPerContact(peerId: 'U1', threadId: '1.5'),
          route: (channelType: null, recipientId: 'U1', threadId: '1.5'),
        ),
        (
          name: 'a shared group key names the group',
          key: SessionKey.groupShared(channelType: 'slack', groupId: 'C1', threadId: 'a:b/c'),
          route: (channelType: 'slack', recipientId: 'C1', threadId: 'a:b/c'),
        ),
        (
          name: 'a per-member group key names the group, not the member',
          key: SessionKey.groupPerMember(channelType: 'slack', groupId: 'C1', peerId: 'U1', threadId: '1.5'),
          route: (channelType: 'slack', recipientId: 'C1', threadId: '1.5'),
        ),
        (
          name: 'a per-member group key without a thread',
          key: SessionKey.groupPerMember(channelType: 'whatsapp', groupId: 'group@g.us', peerId: '1@s.whatsapp.net'),
          route: (channelType: 'whatsapp', recipientId: 'group@g.us', threadId: null),
        ),
        (
          name: 'a peer literally named thread is a peer, not a suffix',
          key: SessionKey.dmPerChannelContact(channelType: 'slack', peerId: 'thread'),
          route: (channelType: 'slack', recipientId: 'thread', threadId: null),
        ),
      ];

      for (final testCase in routeCases) {
        test(testCase.name, () {
          expect(SessionKey.parse(testCase.key).channelRoute, testCase.route);
        });
      }

      final unroutable = [
        (name: 'the shared DM key', key: SessionKey.dmShared()),
        (name: 'a shared DM thread key', key: SessionKey.dmShared(threadId: '1.5')),
        (name: 'a web key', key: SessionKey.webSession()),
        (name: 'a task key', key: SessionKey.taskSession(taskId: 't')),
        (name: 'a cron key', key: SessionKey.cronSession(jobId: 'j')),
      ];

      for (final testCase in unroutable) {
        test('${testCase.name} names no channel route', () {
          expect(SessionKey.parse(testCase.key).channelRoute, isNull);
        });
      }
    });
  });
}
