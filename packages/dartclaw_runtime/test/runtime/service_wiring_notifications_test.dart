import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService;
import 'package:dartclaw_runtime/src/runtime/service_wiring.dart' show sendNotificationToOriginChannel;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:test/test.dart';

/// Loop-detection and budget notices route from the session key, which is the one thing that tells a Slack
/// thread session from the conversation around it.
void main() {
  late InMemorySessionService sessions;
  late TaskService tasks;
  late FakeChannel slack;
  late ChannelManager manager;

  setUp(() {
    sessions = InMemorySessionService();
    tasks = TaskService(InMemoryTaskRepository());
    slack = FakeChannel(type: ChannelType.slack, ownsAllJids: true);
    manager = ChannelManager(queue: RecordingMessageQueue(), config: const ChannelConfig.defaults())
      ..registerChannel(slack);
  });

  tearDown(() => tasks.dispose());

  Future<void> notify(String sessionKey) async {
    final session = await sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);
    await sendNotificationToOriginChannel(
      sessionId: session.id,
      text: 'Loop detected',
      label: 'loop detection',
      sessions: sessions,
      taskService: tasks,
      channelManager: manager,
    );
  }

  test('a Slack DM thread session is answered in its thread, the peer being the recipient', () async {
    await notify(SessionKey.dmPerChannelContact(channelType: 'slack', peerId: 'U1', threadId: '1700000000.000100'));

    final (recipient, response) = slack.sentMessages.single;
    expect(recipient, 'U1');
    expect(response.metadata[threadIdMetadataKey], '1700000000.000100');
  });

  test('a Slack channel thread session is answered in the channel thread, not at the top of the channel', () async {
    await notify(SessionKey.groupShared(channelType: 'slack', groupId: 'C1', threadId: '1700000000.000100'));
    await notify(
      SessionKey.groupPerMember(channelType: 'slack', groupId: 'C2', peerId: 'U1', threadId: '1700000000.000200'),
    );

    expect(slack.sentMessages.map((m) => (m.$1, m.$2.metadata[threadIdMetadataKey])), [
      ('C1', '1700000000.000100'),
      ('C2', '1700000000.000200'),
    ]);
  });

  test('a session without a thread is answered in its conversation with no thread', () async {
    await notify(SessionKey.dmPerChannelContact(channelType: 'slack', peerId: 'U1'));
    await notify(SessionKey.groupShared(channelType: 'slack', groupId: 'C1'));

    expect(slack.sentMessages.map((m) => (m.$1, m.$2.metadata.containsKey(threadIdMetadataKey))), [
      ('U1', false),
      ('C1', false),
    ]);
  });

  test('a session whose key names no channel route sends nothing', () async {
    await notify(SessionKey.dmShared(threadId: '1.5'));
    await notify(SessionKey.dmPerContact(peerId: 'U1'));
    await notify(SessionKey.webSession());

    expect(slack.sentMessages, isEmpty);
  });
}
