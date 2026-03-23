import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' show Request;
import 'package:test/test.dart';

import 'test_utils.dart';

class _FakeWorkerService implements AgentHarness {
  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();

  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
  }) async {
    return {'ok': true};
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _eventsCtrl.close();
  }
}

class _TestGuard extends Guard {
  @override
  final String name;

  @override
  final String category = 'test';

  final FutureOr<GuardVerdict> Function(GuardContext context) evaluator;

  _TestGuard({required this.name, required this.evaluator});

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async => evaluator(context);
}

class _FakeChannel extends Channel {
  @override
  final String name;

  @override
  final ChannelType type = ChannelType.whatsapp;
  bool connected = false;

  _FakeChannel({this.name = 'fake-channel'});

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<void> disconnect() async => connected = false;

  @override
  bool ownsJid(String jid) => false;

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {}
}

String _staticDir() {
  const fromPkg = 'lib/src/static';
  if (Directory(fromPkg).existsSync()) return fromPkg;
  return p.join('packages', 'dartclaw_server', fromPkg);
}

Future<void> _pumpEventQueue() => Future<void>.delayed(Duration.zero);

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late _FakeWorkerService worker;

  DartclawServer buildServer({GuardChain? guardChain, ChannelManager? channelManager, EventBus? eventBus}) {
    return (DartclawServerBuilder()
          ..sessions = sessions
          ..messages = messages
          ..worker = worker
          ..staticDir = _staticDir()
          ..behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test')
          ..guardChain = guardChain
          ..channelManager = channelManager
          ..eventBus = eventBus)
        .build();
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_extension_points_test_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    worker = _FakeWorkerService();
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('registerGuard', () {
    test('appends guards before the first request and added guards participate', () async {
      final evaluationOrder = <String>[];
      final guardChain = GuardChain(
        guards: [
          _TestGuard(
            name: 'initial',
            evaluator: (context) {
              evaluationOrder.add('initial');
              return GuardVerdict.pass();
            },
          ),
        ],
      );
      final server = buildServer(guardChain: guardChain);
      addTearDown(server.shutdown);

      final _ = server.handler;
      server.registerGuard(
        _TestGuard(
          name: 'added',
          evaluator: (context) {
            evaluationOrder.add('added');
            return GuardVerdict.block('added guard blocked');
          },
        ),
      );

      final verdict = await guardChain.evaluateBeforeToolCall('shell', {});

      expect(verdict.isBlock, isTrue);
      expect(verdict.message, 'added guard blocked');
      expect(evaluationOrder, equals(['initial', 'added']));
    });

    test('throws after the first served request', () async {
      final server = buildServer(guardChain: GuardChain(guards: []));
      addTearDown(server.shutdown);

      final handler = server.handler;
      await handler(Request('GET', Uri.parse('http://localhost/')));

      expect(
        () => server.registerGuard(_TestGuard(name: 'late', evaluator: (context) => GuardVerdict.pass())),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when no guard chain is configured', () {
      final server = buildServer();
      addTearDown(server.shutdown);

      expect(
        () => server.registerGuard(_TestGuard(name: 'missing-chain', evaluator: (context) => GuardVerdict.pass())),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('registerChannel', () {
    test('registers channels before the first request without auto-connecting', () {
      final channelManager = ChannelManager(
        queue: MessageQueue(
          dispatcher: (sessionKey, message, {String? senderJid, String? senderDisplayName}) async => 'ok',
        ),
        config: const ChannelConfig.defaults(),
      );
      final server = buildServer(channelManager: channelManager);
      addTearDown(server.shutdown);

      final channel = _FakeChannel();
      final _ = server.handler;
      server.registerChannel(channel);

      expect(channelManager.channels, contains(same(channel)));
      expect(channel.connected, isFalse);
    });

    test('throws after the first served request', () async {
      final channelManager = ChannelManager(
        queue: MessageQueue(
          dispatcher: (sessionKey, message, {String? senderJid, String? senderDisplayName}) async => 'ok',
        ),
        config: const ChannelConfig.defaults(),
      );
      final server = buildServer(channelManager: channelManager);
      addTearDown(server.shutdown);

      final handler = server.handler;
      await handler(Request('GET', Uri.parse('http://localhost/')));

      expect(() => server.registerChannel(_FakeChannel(name: 'late')), throwsA(isA<StateError>()));
    });

    test('throws when no channel manager is configured', () {
      final server = buildServer();
      addTearDown(server.shutdown);

      expect(() => server.registerChannel(_FakeChannel()), throwsA(isA<StateError>()));
    });
  });

  group('onEvent', () {
    test('subscribes with a constructor-provided event bus and returns a cancelable subscription', () async {
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final server = buildServer(eventBus: eventBus);
      addTearDown(server.shutdown);

      final received = <TaskStatusChangedEvent>[];
      final _ = server.handler;
      final subscription = server.onEvent<TaskStatusChangedEvent>(received.add);
      addTearDown(subscription.cancel);

      eventBus.fire(
        FailedAuthEvent(source: 'web', path: '/login', reason: 'bad token', limited: false, timestamp: DateTime.now()),
      );
      eventBus.fire(
        TaskStatusChangedEvent(
          taskId: 'task-1',
          oldStatus: TaskStatus.draft,
          newStatus: TaskStatus.running,
          trigger: 'test',
          timestamp: DateTime.now(),
        ),
      );
      await _pumpEventQueue();

      expect(received.map((event) => event.taskId), equals(['task-1']));

      await subscription.cancel();
      eventBus.fire(
        TaskStatusChangedEvent(
          taskId: 'task-2',
          oldStatus: TaskStatus.running,
          newStatus: TaskStatus.accepted,
          trigger: 'test',
          timestamp: DateTime.now(),
        ),
      );
      await _pumpEventQueue();

      expect(received.map((event) => event.taskId), equals(['task-1']));
    });

    test('throws after the first served request', () async {
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final server = buildServer(eventBus: eventBus);
      addTearDown(server.shutdown);

      final handler = server.handler;
      await handler(Request('GET', Uri.parse('http://localhost/')));

      expect(() => server.onEvent<FailedAuthEvent>((event) {}), throwsA(isA<StateError>()));
    });

    test('throws when no event bus is configured', () {
      final server = buildServer();
      addTearDown(server.shutdown);

      expect(() => server.onEvent<FailedAuthEvent>((event) {}), throwsA(isA<StateError>()));
    });
  });
}
