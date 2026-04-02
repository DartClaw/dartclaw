import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel, InMemoryTaskRepository, TaskOps;
import 'package:test/test.dart';

void main() {
  group('ChannelTaskBridge — task triggers', () {
    late FakeChannel channel;
    late InMemoryTaskRepository repo;
    late TaskOps tasks;

    setUp(() {
      channel = FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
      repo = InMemoryTaskRepository();
      tasks = TaskOps(repo);
    });

    tearDown(() => tasks.dispose());

    ChannelTaskBridge buildBridge({
      TaskCreator? taskCreator,
      Map<ChannelType, TaskTriggerConfig> taskTriggerConfigs = const {
        ChannelType.whatsapp: TaskTriggerConfig(enabled: true),
      },
    }) {
      return ChannelTaskBridge(
        taskCreator: taskCreator ?? tasks.create,
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: taskTriggerConfigs,
      );
    }

    ChannelMessage makeMessage({
      String text = 'task: fix login redirect',
      String senderJid = 'sender@s.whatsapp.net',
      Map<String, String> metadata = const {},
    }) {
      return ChannelMessage(channelType: ChannelType.whatsapp, senderJid: senderJid, text: text, metadata: metadata);
    }

    test('returns false for non-task non-review messages', () async {
      final bridge = buildBridge();
      final sessionKey = 'agent:main:dm:whatsapp:sender';

      final handled = await bridge.tryHandle(
        makeMessage(text: 'just a normal message'),
        channel,
        sessionKey: sessionKey,
      );

      expect(handled, isFalse);
      expect(channel.sentMessages, isEmpty);
      expect(await tasks.list(), isEmpty);
    });

    test('handles task trigger, creates task, sends acknowledgement, returns true', () async {
      final bridge = buildBridge();
      final sessionKey = 'agent:main:dm:whatsapp:sender';

      final handled = await bridge.tryHandle(
        makeMessage(text: 'task: fix login redirect'),
        channel,
        sessionKey: sessionKey,
      );

      final created = (await tasks.list()).single;
      expect(handled, isTrue);
      expect(created.title, 'fix login redirect');
      expect(created.status, TaskStatus.queued);
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.single.$2.text, contains('fix login redirect'));
    });

    test('returns false when trigger config is disabled', () async {
      final bridge = buildBridge(taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: false)});

      final handled = await bridge.tryHandle(makeMessage(text: 'task: fix login redirect'), channel, sessionKey: 'key');

      expect(handled, isFalse);
      expect(await tasks.list(), isEmpty);
    });

    test('@advisor mention fires AdvisorMentionEvent and falls through when nothing else handles it', () async {
      final eventBus = EventBus();
      addTearDown(() async => eventBus.dispose());
      final mentions = <AdvisorMentionEvent>[];
      eventBus.on<AdvisorMentionEvent>().listen(mentions.add);

      final bridge = ChannelTaskBridge(
        eventBus: eventBus,
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: false)},
      );

      final handled = await bridge.tryHandle(
        makeMessage(text: '@advisor please review this'),
        channel,
        sessionKey: 'agent:main:group:whatsapp:group@g.us',
      );

      await Future<void>.delayed(Duration.zero);
      expect(handled, isFalse);
      expect(mentions, hasLength(1));
      expect(mentions.single.messageText, '@advisor please review this');
      expect(mentions.single.channelType, 'whatsapp');
    });
  });

  group('ChannelTaskBridge — project binding', () {
    late FakeChannel channel;
    late InMemoryTaskRepository repo;
    late TaskOps tasks;

    setUp(() {
      channel = FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
      repo = InMemoryTaskRepository();
      tasks = TaskOps(repo);
    });

    tearDown(() => tasks.dispose());

    ChannelMessage makeGroupMessage({String groupJid = 'group@g.us'}) {
      return ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'sender@s.whatsapp.net',
        text: 'task: fix login',
        groupJid: groupJid,
      );
    }

    test('group with project binding passes projectId to task creator', () async {
      final resolver = GroupConfigResolver.fromChannelEntries({
        ChannelType.whatsapp: [GroupEntry(id: 'group@g.us', project: 'my-project')],
      });
      final bridge = ChannelTaskBridge(
        taskCreator: tasks.create,
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
        groupConfigResolverGetter: () => resolver,
      );

      await bridge.tryHandle(makeGroupMessage(), channel, sessionKey: 'agent:main:group:whatsapp:group%40g.us');

      expect(tasks.lastProjectId, 'my-project');
    });

    test('group entry without project passes null projectId', () async {
      final resolver = GroupConfigResolver.fromChannelEntries({
        ChannelType.whatsapp: [GroupEntry(id: 'group@g.us', model: 'haiku')],
      });
      final bridge = ChannelTaskBridge(
        taskCreator: tasks.create,
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
        groupConfigResolverGetter: () => resolver,
      );

      await bridge.tryHandle(makeGroupMessage(), channel, sessionKey: 'agent:main:group:whatsapp:group%40g.us');

      expect(tasks.lastProjectId, isNull);
    });

    test('DM message (no groupJid) passes null projectId', () async {
      final resolver = GroupConfigResolver.fromChannelEntries({
        ChannelType.whatsapp: [GroupEntry(id: 'group@g.us', project: 'my-project')],
      });
      final bridge = ChannelTaskBridge(
        taskCreator: tasks.create,
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
        groupConfigResolverGetter: () => resolver,
      );
      final dmMessage = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'sender@s.whatsapp.net',
        text: 'task: fix login',
      );

      await bridge.tryHandle(dmMessage, channel, sessionKey: 'agent:main:dm:whatsapp:sender%40s.whatsapp.net');

      expect(tasks.lastProjectId, isNull);
    });
  });
}
