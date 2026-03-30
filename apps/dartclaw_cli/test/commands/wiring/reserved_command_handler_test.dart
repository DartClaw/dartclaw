import 'package:dartclaw_cli/src/commands/wiring/reserved_command_handler.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide ReservedCommandHandler;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
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
      turnManagerGetter: () => _FakeTurnManager(activeSessionIds: {}),
      taskService: taskService,
      eventBus: eventBus,
      sseBroadcast: _FakeSseBroadcast(),
      pauseController: pauseController,
      sessions: InMemorySessionService(),
      threadBindingStore: threadBindingStore,
    );
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

    test('/unbind without thread binding store returns rejected', () async {
      final result = await handle(makeMessage(text: '/unbind'), threadBindingStore: null);

      expect(result, 'rejected');
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.first.$2.text, contains('not enabled'));
    });
  });
}

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

class _FakeTurnManager implements TurnManager {
  final Set<String> _activeSessionIds;

  _FakeTurnManager({required Set<String> activeSessionIds}) : _activeSessionIds = activeSessionIds;

  @override
  HarnessPool get pool => _FakePool(this);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not implemented in _FakeTurnManager');
}

class _FakePool implements HarnessPool {
  final _FakeTurnManager _manager;
  late final _FakeRunner _runner = _FakeRunner(_manager);

  _FakePool(this._manager);

  @override
  List<TurnRunner> get runners => [_runner];

  @override
  TurnRunner get primary => _runner;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not implemented in _FakePool');
}

class _FakeRunner implements TurnRunner {
  final _FakeTurnManager _manager;

  _FakeRunner(this._manager);

  @override
  Iterable<String> get activeSessionIds => _manager._activeSessionIds;

  @override
  Future<void> cancelTurn(String sessionId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not implemented in _FakeRunner');
}

class _FakeSseBroadcast implements SseBroadcast {
  @override
  void broadcast(String event, Map<String, dynamic> data) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not implemented in _FakeSseBroadcast');
}
