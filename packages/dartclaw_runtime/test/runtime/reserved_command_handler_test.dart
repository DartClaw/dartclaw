import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/reserved_command_handler.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:test/test.dart';

void main() {
  late FakeChannel channel;
  late TestEventBus eventBus;
  late InMemoryTaskRepository taskRepo;
  late TaskService taskService;
  late PauseController pauseController;

  setUp(() {
    channel = FakeChannel(ownedJids: {'admin@s.whatsapp.net', 'user@s.whatsapp.net'});
    eventBus = TestEventBus();
    taskRepo = InMemoryTaskRepository();
    taskService = TaskService(taskRepo, eventBus: eventBus);
    pauseController = PauseController();
  });

  tearDown(() async {
    await eventBus.dispose();
    await taskService.dispose();
  });

  /// Governance with empty adminSenders (all senders are admins).
  const allAdminsGovernance = GovernanceConfig.defaults();

  ChannelMessage makeMessage({String text = 'hello', String senderJid = 'admin@s.whatsapp.net'}) {
    return ChannelMessage(channelType: ChannelType.whatsapp, senderJid: senderJid, text: text);
  }

  Future<String?> handle(
    ChannelMessage message, {
    GovernanceConfig? governance,
    ThreadBindingStore? threadBindingStore,
  }) {
    return ReservedCommandHandler.handle(
      message,
      channel,
      governance: governance ?? allAdminsGovernance,
      turnManagerGetter: () => FakeTurnManager(),
      taskService: taskService,
      eventBus: eventBus,
      sseBroadcast: SseBroadcast(),
      pauseController: pauseController,
      sessions: InMemorySessionService(),
      threadBindingStore: threadBindingStore,
    );
  }

  Future<ThreadBindingStore> createBindingStore() async {
    final tempDir = await Directory.systemTemp.createTemp('reserved-bind-test-');
    addTearDown(() => tempDir.delete(recursive: true));
    final store = ThreadBindingStore(File('${tempDir.path}/bindings.json'));
    await store.load();
    return store;
  }

  group('ReservedCommandHandler', () {
    test('returns null for non-reserved commands', () async {
      expect(await handle(makeMessage(text: 'hello')), isNull);
      expect(await handle(makeMessage(text: 'Do something')), isNull);
      expect(await handle(makeMessage(text: '/help')), isNull);
      expect(channel.sentMessages, isEmpty);
    });

    group('rejects non-admin senders', () {
      final governance = GovernanceConfig(adminSenders: ['admin@s.whatsapp.net']);

      for (final command in ['/stop', '/pause', '/resume', '/bind task-1', '/unbind']) {
        test('$command rejected for non-admin', () async {
          final result = await handle(
            makeMessage(text: command, senderJid: 'user@s.whatsapp.net'),
            governance: governance,
          );
          expect(result, 'rejected');
          expect(channel.sentMessages, hasLength(1));
          expect(channel.sentMessages.first.$2.text, contains('Only admin senders'));
        });

        tearDown(() => channel.sentMessages.clear());
      }
    });

    test('a command-prefixed word is not a reserved command', () async {
      final governance = GovernanceConfig(adminSenders: ['admin@s.whatsapp.net']);

      for (final text in ['/pausenow', '/resumes', '/stopwatch', '/unbindings']) {
        expect(
          await handle(
            makeMessage(text: text, senderJid: 'user@s.whatsapp.net'),
            governance: governance,
          ),
          isNull,
          reason: text,
        );
      }
      // No admin rejection was sent, so a non-admin cannot make the bot speak
      // ahead of per-sender rate limiting.
      expect(channel.sentMessages, isEmpty);
      expect(pauseController.isPaused, isFalse);
    });

    test('/stop calls EmergencyStopHandler and returns executed', () async {
      final result = await handle(makeMessage(text: '/stop'));

      expect(result, 'executed');
      // No active turns or tasks — should report no activity.
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.first.$2.text, contains('No active tasks or turns to stop'));
    });

    test('/pause pauses the controller and returns executed', () async {
      final result = await handle(makeMessage(text: '/pause'));

      expect(result, 'executed');
      expect(pauseController.isPaused, isTrue);
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.first.$2.text, contains('Agent paused'));
    });

    test('/resume when not paused returns executed with appropriate message', () async {
      final result = await handle(makeMessage(text: '/resume'));

      expect(result, 'executed');
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.first.$2.text, contains('not paused'));
    });

    test('/bind without thread binding store returns rejected', () async {
      final result = await handle(makeMessage(text: '/bind task-1'), threadBindingStore: null);

      expect(result, 'rejected');
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.first.$2.text, contains('not enabled'));
    });

    test('/bind accepts a full task ID and refuses its prefix without a candidate list', () async {
      final fullId = '12345678-aaaa-bbbb-cccc-123456789abc';
      await taskService.create(
        id: fullId,
        title: 'Fix login',
        description: 'Fix login',
        configJson: const {'needsWorktree': false},
        autoStart: true,
      );
      final store = await createBindingStore();

      final fullResult = await handle(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'admin@s.whatsapp.net',
          text: '/bind $fullId',
          metadata: const {'threadName': 'thread-full'},
        ),
        threadBindingStore: store,
      );

      expect(fullResult, 'executed');
      expect(store.lookupByThread('googlechat', 'thread-full')?.taskId, fullId);
      expect(channel.sentMessages.single.$2.text, contains('Bound to task $fullId.'));

      channel.sentMessages.clear();
      final prefix = fullId.substring(0, 8);
      final prefixResult = await handle(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'admin@s.whatsapp.net',
          text: '/bind $prefix',
          metadata: const {'threadName': 'thread-prefix'},
        ),
        threadBindingStore: store,
      );

      expect(prefixResult, 'rejected');
      expect(store.lookupByThread('googlechat', 'thread-prefix'), isNull);
      expect(channel.sentMessages.single.$2.text, 'Task $prefix not found.');
      expect(channel.sentMessages.single.$2.text, isNot(contains('Matches')));
    });

    test('/bind refuses a terminal task with its full ID and creates no binding', () async {
      const terminalId = 'terminal-task-full-id';
      await taskService.create(
        id: terminalId,
        title: terminalId,
        description: terminalId,
        configJson: const {'needsWorktree': false},
        autoStart: true,
      );
      await taskService.transition(terminalId, TaskStatus.cancelled);
      final store = await createBindingStore();

      final terminalResult = await handle(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'admin@s.whatsapp.net',
          text: '/bind $terminalId',
          metadata: const {'threadName': 'thread-terminal'},
        ),
        threadBindingStore: store,
      );

      expect(terminalResult, 'rejected');
      expect(store.lookupByThread('googlechat', 'thread-terminal'), isNull);
      expect(channel.sentMessages.single.$2.text, 'Task $terminalId is cancelled — cannot bind to a completed task.');
    });

    test('/bind preserves an existing binding and /unbind removes it with full-ID replies', () async {
      const boundId = 'already-bound-task-full-id';
      const otherId = 'other-live-task-full-id';
      for (final id in [boundId, otherId]) {
        await taskService.create(
          id: id,
          title: id,
          description: id,
          configJson: const {'needsWorktree': false},
          autoStart: true,
        );
      }
      final store = await createBindingStore();

      final now = DateTime.now();
      await store.create(
        ThreadBinding(
          channelType: 'googlechat',
          threadId: 'thread-bound',
          taskId: boundId,
          sessionKey: SessionKey.taskSession(taskId: boundId),
          createdAt: now,
          lastActivity: now,
        ),
      );

      final differentTaskResult = await handle(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'admin@s.whatsapp.net',
          text: '/bind $otherId',
          metadata: const {'threadName': 'thread-bound'},
        ),
        threadBindingStore: store,
      );

      expect(differentTaskResult, 'rejected');
      expect(store.lookupByThread('googlechat', 'thread-bound')?.taskId, boundId);
      expect(channel.sentMessages.single.$2.text, 'Already bound to task $boundId — /unbind first.');

      channel.sentMessages.clear();
      final sameTaskResult = await handle(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'admin@s.whatsapp.net',
          text: '/bind $boundId',
          metadata: const {'threadName': 'thread-bound'},
        ),
        threadBindingStore: store,
      );

      expect(sameTaskResult, 'executed');
      expect(store.lookupByThread('googlechat', 'thread-bound')?.taskId, boundId);
      expect(channel.sentMessages.single.$2.text, 'Already bound to task $boundId.');

      channel.sentMessages.clear();
      final unbindResult = await handle(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'admin@s.whatsapp.net',
          text: '/unbind',
          metadata: const {'threadName': 'thread-bound'},
        ),
        threadBindingStore: store,
      );

      expect(unbindResult, 'executed');
      expect(store.lookupByThread('googlechat', 'thread-bound'), isNull);
      expect(
        channel.sentMessages.single.$2.text,
        'Unbound from task $boundId. Messages here return to normal routing.',
      );

      channel.sentMessages.clear();
      final noBindingResult = await handle(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'admin@s.whatsapp.net',
          text: '/unbind',
          metadata: const {'threadName': 'thread-bound'},
        ),
        threadBindingStore: store,
      );

      expect(noBindingResult, 'executed');
      expect(channel.sentMessages.single.$2.text, 'No binding found for this thread/group.');
    });

    test('/unbind without thread binding store returns rejected', () async {
      final result = await handle(makeMessage(text: '/unbind'), threadBindingStore: null);

      expect(result, 'rejected');
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.first.$2.text, contains('not enabled'));
    });
  });
}
