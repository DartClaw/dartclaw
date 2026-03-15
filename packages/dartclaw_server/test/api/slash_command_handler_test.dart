import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late EventBus eventBus;
  late TaskService tasks;
  late SessionService sessions;
  late ChannelManager channelManager;
  late SlashCommandHandler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('slash_command_handler_test_');
    eventBus = EventBus();
    tasks = TaskService(SqliteTaskRepository(openTaskDbInMemory()));
    sessions = SessionService(baseDir: tempDir.path, eventBus: eventBus);
    channelManager = ChannelManager(queue: _NoopMessageQueue(), config: const ChannelConfig.defaults());
    handler = SlashCommandHandler(
      taskService: tasks,
      sessionService: sessions,
      eventBus: eventBus,
      channelManager: channelManager,
    );
  });

  tearDown(() async {
    await channelManager.dispose();
    await tasks.dispose();
    await eventBus.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('/new creates a task, stores origin, and fires a slash_command event', () async {
    final events = <TaskStatusChangedEvent>[];
    final sub = eventBus.on<TaskStatusChangedEvent>().listen(events.add);
    addTearDown(sub.cancel);

    final response = await handler.handle(
      const SlashCommand(name: 'new', arguments: 'research: analyze competitor pricing'),
      spaceName: 'spaces/AAAA',
      senderJid: 'users/123',
      spaceType: 'DM',
      sourceMessageId: 'spaces/AAAA/messages/BBBB',
    );

    final created = (await tasks.list()).single;
    final origin = TaskOrigin.fromConfigJson(created.configJson);

    expect(created.title, 'analyze competitor pricing');
    expect(created.description, 'analyze competitor pricing');
    expect(created.type, TaskType.research);
    expect(created.status, TaskStatus.queued);
    expect(origin, isNotNull);
    expect(origin!.channelType, ChannelType.googlechat.name);
    expect(origin.recipientId, 'spaces/AAAA');
    expect(origin.contactId, 'users/123');
    expect(origin.sourceMessageId, 'spaces/AAAA/messages/BBBB');
    expect(
      origin.sessionKey,
      channelManager.deriveSessionKey(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'users/123',
          text: '',
          metadata: const {'spaceName': 'spaces/AAAA'},
        ),
      ),
    );
    expect(events, hasLength(1));
    expect(events.single.oldStatus, TaskStatus.draft);
    expect(events.single.newStatus, TaskStatus.queued);
    expect(events.single.trigger, 'slash_command');

    final card = _singleCard(response);
    expect(card['header'], {'title': 'Task created: analyze competitor pricing', 'subtitle': 'queued'});
  });

  test('/new uses configured defaults and coerces unknown types to custom', () async {
    handler = SlashCommandHandler(
      taskService: tasks,
      sessionService: sessions,
      eventBus: eventBus,
      channelManager: channelManager,
      defaultTaskType: 'writing',
      autoStartTasks: false,
    );

    await handler.handle(
      const SlashCommand(name: 'new', arguments: 'draft release notes'),
      spaceName: 'spaces/AAAA',
      senderJid: 'users/123',
      spaceType: 'DM',
    );
    await handler.handle(
      const SlashCommand(name: 'new', arguments: 'migration_plan: prepare cutover'),
      spaceName: 'spaces/AAAA',
      senderJid: 'users/123',
      spaceType: 'DM',
    );

    final created = await tasks.list();
    expect(created, hasLength(2));
    final defaultTask = created.firstWhere((task) => task.title == 'draft release notes');
    final customTask = created.firstWhere((task) => task.title == 'prepare cutover');
    expect(defaultTask.type, TaskType.writing);
    expect(defaultTask.status, TaskStatus.draft);
    expect(customTask.type, TaskType.custom);
  });

  test('/new without a description returns an error card', () async {
    final response = await handler.handle(
      const SlashCommand(name: 'new', arguments: ''),
      spaceName: 'spaces/AAAA',
      senderJid: 'users/123',
      spaceType: 'DM',
    );

    expect(await tasks.list(), isEmpty);
    final card = _singleCard(response);
    expect(card['header'], {'title': 'Missing Description', 'subtitle': 'Error'});
    expect(_sectionText(response), contains('Usage: /new [&lt;type&gt;:] &lt;description&gt;'));
  });

  test('/reset archives the active keyed session', () async {
    final sessionKey = channelManager.deriveSessionKey(
      ChannelMessage(
        channelType: ChannelType.googlechat,
        senderJid: 'users/123',
        text: '',
        metadata: const {'spaceName': 'spaces/AAAA'},
      ),
    );
    final session = await sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);

    final response = await handler.handle(
      const SlashCommand(name: 'reset', arguments: ''),
      spaceName: 'spaces/AAAA',
      senderJid: 'users/123',
      spaceType: 'DM',
    );

    expect((await sessions.getSession(session.id))!.type, SessionType.archive);
    final card = _singleCard(response);
    expect(card['header'], {'title': 'Session Reset', 'subtitle': 'Confirmation'});
    expect(_sectionText(response), contains('Session archived. Your next message will start a fresh session.'));
  });

  test('/reset returns a confirmation when no active session exists', () async {
    final response = await handler.handle(
      const SlashCommand(name: 'reset', arguments: ''),
      spaceName: 'spaces/AAAA',
      senderJid: 'users/123',
      spaceType: 'DM',
    );

    expect(_sectionText(response), contains('No active session to reset.'));
  });

  test('/status summarizes active tasks and sessions', () async {
    await tasks.create(
      id: 'task-queued',
      title: 'Investigate outage',
      description: 'Investigate outage',
      type: TaskType.analysis,
      autoStart: true,
    );
    await tasks.create(
      id: 'task-done',
      title: 'Publish notes',
      description: 'Publish notes',
      type: TaskType.writing,
      autoStart: false,
    );
    await tasks.transition('task-done', TaskStatus.cancelled);

    final activeSession = await sessions.getOrCreateByKey(
      'agent:main:group:googlechat:spaces%2FAAAA',
      type: SessionType.channel,
    );
    final archivedSession = await sessions.createSession(type: SessionType.channel);
    await sessions.updateSessionType(archivedSession.id, SessionType.archive);

    final response = await handler.handle(
      const SlashCommand(name: 'status', arguments: ''),
      spaceName: 'spaces/AAAA',
      senderJid: 'users/123',
      spaceType: 'ROOM',
    );

    final card = _singleCard(response);
    final sections = (card['sections'] as List).cast<Map<String, dynamic>>();

    expect(card['header'], {'title': 'DartClaw Status', 'subtitle': 'Current overview'});
    expect(sections[0]['header'], 'Active Tasks (1)');
    expect(sections[1]['header'], 'Sessions');
    expect(
      ((sections[0]['widgets'] as List).single as Map<String, dynamic>)['decoratedText'],
      containsPair('text', 'Investigate outage'),
    );
    expect(_sectionText(response), contains('1 active session'));
    expect(await sessions.getSession(activeSession.id), isNotNull);
  });

  test('unknown commands return the available command list', () async {
    final response = await handler.handle(
      const SlashCommand(name: 'foo', arguments: ''),
      spaceName: 'spaces/AAAA',
      senderJid: 'users/123',
      spaceType: 'DM',
    );

    final card = _singleCard(response);
    expect(card['header'], {'title': 'Unknown Command', 'subtitle': 'Error'});
    expect(_sectionText(response), contains('Unknown command. Available: /new, /reset, /status'));
  });
}

Map<String, dynamic> _singleCard(Map<String, dynamic> response) {
  return ((response['cardsV2'] as List).single as Map<String, dynamic>)['card'] as Map<String, dynamic>;
}

String _sectionText(Map<String, dynamic> response) {
  final sections = (_singleCard(response)['sections'] as List).cast<Map<String, dynamic>>();
  return sections
      .expand((section) => (section['widgets'] as List).cast<Map<String, dynamic>>())
      .map((widget) {
        final paragraph = widget['textParagraph'];
        if (paragraph is Map<String, dynamic>) {
          return paragraph['text'] as String? ?? '';
        }
        final decorated = widget['decoratedText'];
        if (decorated is Map<String, dynamic>) {
          return decorated['text'] as String? ?? '';
        }
        return '';
      })
      .join('\n');
}

class _NoopMessageQueue extends MessageQueue {
  _NoopMessageQueue() : super(dispatcher: (sessionKey, message, {senderJid}) async => '');

  @override
  void enqueue(ChannelMessage message, Channel channel, String sessionKey) {}
}
