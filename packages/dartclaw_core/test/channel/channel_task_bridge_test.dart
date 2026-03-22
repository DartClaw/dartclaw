import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel, InMemoryTaskRepository;
import 'package:test/test.dart';

void main() {
  group('ChannelTaskBridge — task triggers', () {
    late FakeChannel channel;
    late InMemoryTaskRepository repo;
    late _TaskOps tasks;

    setUp(() {
      channel = FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
      repo = InMemoryTaskRepository();
      tasks = _TaskOps(repo);
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
      return ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: senderJid,
        text: text,
        metadata: metadata,
      );
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
      final bridge = buildBridge(
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: false)},
      );

      final handled = await bridge.tryHandle(
        makeMessage(text: 'task: fix login redirect'),
        channel,
        sessionKey: 'key',
      );

      expect(handled, isFalse);
      expect(await tasks.list(), isEmpty);
    });

    test('handles empty description trigger — sends error response, returns true', () async {
      final bridge = buildBridge();

      final handled = await bridge.tryHandle(
        makeMessage(
          text: 'task:   ',
          metadata: {sourceMessageIdMetadataKey: 'wamid-empty'},
        ),
        channel,
        sessionKey: 'key',
      );

      expect(handled, isTrue);
      expect(await tasks.list(), isEmpty);
      expect(channel.sentMessages.single.$2.text, 'Could not create task -- description required.');
      expect(channel.sentMessages.single.$2.metadata, containsPair(sourceMessageIdMetadataKey, 'wamid-empty'));
    });

    test('handles task trigger when creator is null — sends service unavailable, returns true', () async {
      final bridge = ChannelTaskBridge(
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
      );

      final handled = await bridge.tryHandle(
        makeMessage(text: 'task: fix login'),
        channel,
        sessionKey: 'key',
      );

      expect(handled, isTrue);
      expect(channel.sentMessages.single.$2.text, 'Could not create task -- service unavailable.');
    });

    test('preserves sourceMessageId in acknowledgement metadata', () async {
      final bridge = buildBridge();

      await bridge.tryHandle(
        makeMessage(
          text: 'task: fix login redirect',
          metadata: {sourceMessageIdMetadataKey: 'wamid-123'},
        ),
        channel,
        sessionKey: 'key',
      );

      final created = (await tasks.list()).single;
      expect(channel.sentMessages.single.$2.metadata, containsPair(sourceMessageIdMetadataKey, 'wamid-123'));
      expect(TaskOrigin.fromConfigJson(created.configJson)?.sourceMessageId, 'wamid-123');
    });

    test('uses resolveRecipientId — spaceName for Google Chat messages', () async {
      final gcChannel = FakeChannel(type: ChannelType.googlechat, ownedJids: {'spaces/AAAA'});
      final bridge = ChannelTaskBridge(
        taskCreator: tasks.create,
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: const {ChannelType.googlechat: TaskTriggerConfig(enabled: true)},
      );

      await bridge.tryHandle(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'users/123',
          text: 'task: investigate outage',
          metadata: const {'spaceName': 'spaces/AAAA'},
        ),
        gcChannel,
        sessionKey: 'key',
      );

      final created = (await tasks.list()).single;
      final origin = TaskOrigin.fromConfigJson(created.configJson)!;
      expect(origin.recipientId, 'spaces/AAAA');
      expect(gcChannel.sentMessages.single.$1, 'spaces/AAAA');
    });

    test('sends service unavailable when task creation throws', () async {
      final bridge = ChannelTaskBridge(
        taskCreator: ({
          required id,
          required title,
          required description,
          required type,
          autoStart = false,
          goalId,
          acceptanceCriteria,
          createdBy,
          configJson = const {},
          now,
          trigger = 'system',
        }) async => throw StateError('boom'),
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
      );

      final handled = await bridge.tryHandle(
        makeMessage(text: 'task: fix login'),
        channel,
        sessionKey: 'key',
      );

      expect(handled, isTrue);
      expect(channel.sentMessages.single.$2.text, 'Could not create task -- service unavailable.');
    });
  });
}

class _TaskOps {
  final InMemoryTaskRepository _repo;

  _TaskOps(this._repo);

  Future<Task> create({
    required String id,
    required String title,
    required String description,
    required TaskType type,
    bool autoStart = false,
    String? goalId,
    String? acceptanceCriteria,
    String? createdBy,
    Map<String, dynamic> configJson = const {},
    DateTime? now,
    String trigger = 'system',
  }) async {
    final timestamp = now ?? DateTime.now();
    var task = Task(
      id: id,
      title: title,
      description: description,
      type: type,
      goalId: goalId,
      acceptanceCriteria: acceptanceCriteria,
      createdBy: createdBy,
      configJson: configJson,
      createdAt: timestamp,
    );
    if (autoStart) {
      task = task.transition(TaskStatus.queued, now: timestamp);
    }
    await _repo.insert(task);
    return task;
  }

  Future<List<Task>> list({TaskStatus? status, TaskType? type}) => _repo.list(status: status, type: type);

  Future<void> dispose() => _repo.dispose();
}
