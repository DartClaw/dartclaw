import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' show Request, Response;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

// ---------------------------------------------------------------------------
// FakeWorkerService
// ---------------------------------------------------------------------------

class FakeWorkerService implements AgentHarness {
  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  Completer<Map<String, dynamic>>? _turnCompleter;
  final Completer<void> _turnStarted = Completer<void>();
  bool cancelCalled = false;
  bool stopCalled = false;
  bool disposeCalled = false;

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
    int? maxTurns,
  }) {
    _turnCompleter = Completer<Map<String, dynamic>>();
    if (!_turnStarted.isCompleted) {
      _turnStarted.complete();
    }
    return _turnCompleter!.future;
  }

  @override
  Future<void> cancel() async {
    cancelCalled = true;
    _turnCompleter?.completeError(StateError('Cancelled'));
  }

  @override
  Future<void> stop() async {
    stopCalled = true;
  }

  @override
  Future<void> dispose() async {
    disposeCalled = true;
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }

  void completeSuccess() => _turnCompleter?.complete({'ok': true});
  Future<void> get turnStarted => _turnStarted.future;
  Future<void> closeEvents() => _eventsCtrl.close();
}

class _TestDashboardPage extends DashboardPage {
  _TestDashboardPage({this.routePath = '/custom-dashboard'});

  final String routePath;

  @override
  String get route => routePath;

  @override
  String get title => 'Custom';

  @override
  String get navGroup => 'extension';

  @override
  Future<Response> handler(Request request, PageContext context) async {
    return Response.ok('custom dashboard');
  }
}

Future<ProcessResult> _successfulProcessResult(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  return ProcessResult(1, 0, '', '');
}

AgentObserver _buildAgentObserver(FakeWorkerService worker, MessageService messages) {
  final runner = TurnRunner(
    harness: worker,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
  );
  return AgentObserver(pool: HarnessPool(runners: [runner]));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Resolves static dir whether tests run from project root or package root.
String _staticDir() {
  final fromPkg = 'lib/src/static';
  if (Directory(fromPkg).existsSync()) return fromPkg;
  return p.join('packages', 'dartclaw_server', fromPkg);
}

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeWorkerService worker;
  late DartclawServer server;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_server_test_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    worker = FakeWorkerService();
    server =
        (DartclawServerBuilder()
              ..sessions = sessions
              ..messages = messages
              ..worker = worker
              ..staticDir = _staticDir()
              ..behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'))
            .build();
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('shutdown', () {
    test('cancels active turn then stops worker', () async {
      final session = await sessions.createSession();
      final sessionId = session.id;

      final handler = server.handler;

      // Fire POST /api/sessions/<id>/send to start a turn. Don't await — the
      // handler blocks until the turn completes, but we need to call shutdown
      // while it's still running.
      unawaited(
        Future(() async {
          await handler(
            Request(
              'POST',
              Uri.parse('http://localhost/api/sessions/$sessionId/send'),
              body: '{"message": "hello"}',
              headers: {'content-type': 'application/json'},
            ),
          );
        }),
      );

      await worker.turnStarted;

      await server.shutdown();

      expect(worker.cancelCalled, isTrue, reason: 'shutdown should cancel active turns');
      expect(worker.disposeCalled, isTrue, reason: 'shutdown should dispose the worker');
    });

    test('stops worker when no turns are active', () async {
      await server.shutdown();

      expect(worker.cancelCalled, isFalse, reason: 'no active turns to cancel');
      expect(worker.disposeCalled, isTrue, reason: 'worker.dispose() always called');
    });

    test('does not cancel after turn already completed', () async {
      final session = await sessions.createSession();
      final sessionId = session.id;

      final handler = server.handler;

      // Start a turn and let it complete before shutdown.
      unawaited(
        Future(() async {
          await handler(
            Request(
              'POST',
              Uri.parse('http://localhost/api/sessions/$sessionId/send'),
              body: '{"message": "hi"}',
              headers: {'content-type': 'application/json'},
            ),
          );
        }),
      );
      await worker.turnStarted;
      worker.completeSuccess();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Turn completed — no active sessions now.
      await server.shutdown();

      expect(worker.cancelCalled, isFalse, reason: 'no active turn to cancel after completion');
      expect(worker.disposeCalled, isTrue, reason: 'worker.dispose() always called');
    });
  });

  group('registerDashboardPage', () {
    test('serves registered page routes and adds them to sidebar nav', () async {
      server.registerDashboardPage(_TestDashboardPage());
      final session = await sessions.createSession();
      final handler = server.handler;

      final pageRes = await handler(Request('GET', Uri.parse('http://localhost/custom-dashboard')));
      final pageBody = await pageRes.readAsString();
      expect(pageRes.statusCode, equals(200));
      expect(pageBody, contains('custom dashboard'));

      final sessionRes = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}')));
      final sessionBody = await sessionRes.readAsString();
      expect(sessionRes.statusCode, equals(200));
      expect(sessionBody, contains('/custom-dashboard'));
      expect(sessionBody, contains('Custom'));
      expect(sessionBody, contains('Extensions'));
    });

    test('still allows registration after the handler is built but before first request', () async {
      final _ = server.handler;
      server.registerDashboardPage(_TestDashboardPage(routePath: '/late-dashboard'));

      final response = await server.handler(Request('GET', Uri.parse('http://localhost/late-dashboard')));

      expect(response.statusCode, equals(200));
      expect(await response.readAsString(), contains('custom dashboard'));
    });

    test('throws after the server starts serving requests', () async {
      final handler = server.handler;
      await handler(Request('GET', Uri.parse('http://localhost/')));

      expect(
        () => server.registerDashboardPage(_TestDashboardPage(routePath: '/late-dashboard')),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('task route wiring', () {
    late Database taskDb;
    late TaskService taskService;
    late EventBus eventBus;
    late WorktreeManager worktreeManager;
    late TaskFileGuard taskFileGuard;
    late MergeExecutor mergeExecutor;
    late AgentObserver agentObserver;

    setUp(() {
      taskDb = openTaskDbInMemory();
      taskService = TaskService(SqliteTaskRepository(taskDb));
      eventBus = EventBus();
      worktreeManager = WorktreeManager(
        dataDir: tempDir.path,
        projectDir: tempDir.path,
        processRunner: _successfulProcessResult,
      );
      taskFileGuard = TaskFileGuard();
      mergeExecutor = MergeExecutor(projectDir: tempDir.path, processRunner: _successfulProcessResult);
      agentObserver = _buildAgentObserver(worker, messages);
      server =
          (DartclawServerBuilder()
                ..sessions = sessions
                ..messages = messages
                ..worker = worker
                ..staticDir = _staticDir()
                ..behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test')
                ..tokenService = TokenService(token: 'test-token')
                ..gatewayToken = 'test-token'
                ..taskService = taskService
                ..eventBus = eventBus
                ..worktreeManager = worktreeManager
                ..taskFileGuard = taskFileGuard
                ..mergeExecutor = mergeExecutor
                ..agentObserver = agentObserver)
              .build();
    });

    tearDown(() async {
      agentObserver.dispose();
      await eventBus.dispose();
      await taskService.dispose();
    });

    test('task routes are mounted behind auth middleware', () async {
      final response = await server.handler(Request('GET', Uri.parse('http://localhost/api/tasks')));

      expect(response.statusCode, equals(401));
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], 'Unauthorized');
    });

    test('authorized requests can reach mounted task routes', () async {
      final response = await server.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/tasks'),
          body: jsonEncode({'title': 'Task from server', 'description': 'Describe the work', 'type': 'coding'}),
          headers: {'content-type': 'application/json', 'authorization': 'Bearer test-token'},
        ),
      );

      expect(response.statusCode, equals(201));
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['status'], 'draft');
    });

    test('authorized requests can reach mounted task SSE route', () async {
      final response = await server.handler(
        Request('GET', Uri.parse('http://localhost/api/tasks/events'), headers: {'authorization': 'Bearer test-token'}),
      );

      expect(response.statusCode, equals(200));
      expect(response.headers['content-type'], equals('text/event-stream'));
    });
  });

  group('runtime service validation', () {
    test('throws when taskService is enabled without required task runtime services', () async {
      final taskDb = openTaskDbInMemory();
      final taskService = TaskService(SqliteTaskRepository(taskDb));
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      addTearDown(taskService.dispose);

      final s =
          (DartclawServerBuilder()
                ..sessions = sessions
                ..messages = messages
                ..worker = worker
                ..staticDir = _staticDir()
                ..behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test')
                ..taskService = taskService
                ..eventBus = eventBus)
              .build();

      expect(
        () => s.handler(Request('GET', Uri.parse('http://localhost/'))),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('worktreeManager'))),
      );
    });

    test('throws when configWriter is enabled without restart dependencies', () async {
      final configWriter = ConfigWriter(configPath: p.join(tempDir.path, 'dartclaw.yaml'));
      addTearDown(configWriter.dispose);

      final s =
          (DartclawServerBuilder()
                ..sessions = sessions
                ..messages = messages
                ..worker = worker
                ..staticDir = _staticDir()
                ..behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test')
                ..configWriter = configWriter)
              .build();

      expect(
        () => s.handler(Request('GET', Uri.parse('http://localhost/'))),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('restartService'))),
      );
    });

    test('throws when configWriter has restartService but not sseBroadcast', () async {
      final configWriter = ConfigWriter(configPath: p.join(tempDir.path, 'dartclaw.yaml'));
      addTearDown(configWriter.dispose);

      final builder = DartclawServerBuilder()
        ..sessions = sessions
        ..messages = messages
        ..worker = worker
        ..staticDir = _staticDir()
        ..behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test')
        ..configWriter = configWriter;
      builder.restartService = RestartService(turns: builder.buildTurns(), exit: (_) {});

      final s = builder.build();

      expect(
        () => s.handler(Request('GET', Uri.parse('http://localhost/'))),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('sseBroadcast'))),
      );
    });

    test('builds successfully when configWriter has all required dependencies', () async {
      final configWriter = ConfigWriter(configPath: p.join(tempDir.path, 'dartclaw.yaml'));
      addTearDown(configWriter.dispose);
      final sseBroadcast = SseBroadcast();
      addTearDown(sseBroadcast.dispose);

      final builder = DartclawServerBuilder()
        ..sessions = sessions
        ..messages = messages
        ..worker = worker
        ..staticDir = _staticDir()
        ..behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test')
        ..configWriter = configWriter
        ..sseBroadcast = sseBroadcast;
      builder.restartService = RestartService(turns: builder.buildTurns(), exit: (_) {});

      final s = builder.build();

      // Handler builds without StateError — validates all config dependencies are met.
      final response = await s.handler(Request('GET', Uri.parse('http://localhost/')));
      expect(response.statusCode, isNot(equals(500)));
    });
  });

  group('goal route wiring', () {
    late Database taskDb;
    late GoalService goalService;
    late SqliteTaskRepository taskRepository;

    setUp(() {
      taskDb = openTaskDbInMemory();
      taskRepository = SqliteTaskRepository(taskDb);
      goalService = GoalService(SqliteGoalRepository(taskDb));
      server =
          (DartclawServerBuilder()
                ..sessions = sessions
                ..messages = messages
                ..worker = worker
                ..staticDir = _staticDir()
                ..behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test')
                ..tokenService = TokenService(token: 'test-token')
                ..gatewayToken = 'test-token'
                ..goalService = goalService)
              .build();
    });

    tearDown(() async {
      await goalService.dispose();
      await taskRepository.dispose();
    });

    test('goal routes are mounted behind auth middleware', () async {
      final response = await server.handler(Request('GET', Uri.parse('http://localhost/api/goals')));

      expect(response.statusCode, equals(401));
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], 'Unauthorized');
    });

    test('authorized requests can reach mounted goal routes', () async {
      final response = await server.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/goals'),
          body: jsonEncode({'title': 'Goal from server', 'mission': 'Deliver the release safely.'}),
          headers: {'content-type': 'application/json', 'authorization': 'Bearer test-token'},
        ),
      );

      expect(response.statusCode, equals(201));
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['title'], 'Goal from server');
    });
  });
}
