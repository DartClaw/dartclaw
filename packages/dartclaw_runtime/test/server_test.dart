import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show RecordingGitRunner;
import 'package:dartclaw_workflow/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' show Request, Response;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:dartclaw_runtime/src/server.dart'
    show ServerCoreDeps, ServerObservabilityDeps, ServerTaskDeps, ServerTurnDeps, ServerWebDeps;
import 'package:dartclaw_runtime/src/server_composition.dart';

import 'api/workflow_test_support.dart';
import 'test_utils.dart';
import 'execution_coordinator_test_support.dart';

// ---------------------------------------------------------------------------
// FakeWorkerService
// ---------------------------------------------------------------------------

class FakeWorkerService implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  Completer<TurnResult>? _turnCompleter;
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
  bool get supportsSessionContinuity => false;

  @override
  bool get supportsPreCompactHook => false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  bool get isRootProcessTerminationConfirmed => true;

  @override
  bool get supportsStructuredOutput => false;

  @override
  bool get supportsProviderSessionResume => false;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {}

  @override
  Future<TurnResult> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    String? agentId,
    Map<String, dynamic>? mcpServers,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
  }) {
    _turnCompleter = Completer<TurnResult>();
    if (!_turnStarted.isCompleted) {
      _turnStarted.complete();
    }
    return _turnCompleter!.future;
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

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

  void completeSuccess() => _turnCompleter?.complete(const TurnResult());
  Future<void> get turnStarted => _turnStarted.future;
  bool get hasTurnStarted => _turnStarted.isCompleted;
  Future<void> closeEvents() => _eventsCtrl.close();
}

class _TestDashboardPage extends DashboardPage {
  new({this.routePath = '/custom-dashboard'});

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

RunnerObserver _buildRunnerObserver(FakeWorkerService worker, MessageService messages) {
  final runner = TurnRunner(
    turnLimits: const TurnLimitsConfig.defaults(),
    harness: worker,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
  );
  return RunnerObserver(executions: coordinatorForRunners([runner]));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

late String _staticDirPath;

void main() {
  setUpAll(() async {
    initTemplates(await resolveTemplatesDir());
    _staticDirPath = await resolveStaticDir();
  });
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeWorkerService worker;
  late DartclawServer server;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_runtime_test_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    worker = FakeWorkerService();
    server = composeServer(
      core: ServerCoreDeps(sessions: sessions, messages: messages, worker: worker, staticDir: _staticDirPath),
      turn: ServerTurnDeps(
        turns: composeServerTurns(
          sessions: sessions,
          messages: messages,
          worker: worker,
          behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
        ),
      ),
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('unknown routes retain a styled 404 response', () async {
    final response = await server.handler(Request('GET', Uri.parse('http://localhost/nonexistent-page')));
    final body = await response.readAsString();

    expect(response.statusCode, 404);
    expect(response.headers['content-type'], startsWith('text/html'));
    expect(body, contains('Page Not Found'));
    expect(body, contains('class="error-code t-display text-overlay"'));
    expect(body, isNot(contains('class="error-code t-display text-gradient"')));
    expect(body, contains('href="/"'));
  });

  test('workflow-enabled server sends slash-prefixed text through the normal turn path', () async {
    final sessionDataDir = p.join(tempDir.path, 'slash-data');
    final localSessions = SessionService(baseDir: sessionDataDir);
    final localMessages = MessageService(baseDir: sessionDataDir);
    final localWorker = FakeWorkerService();
    final eventBus = EventBus();
    final taskDb = openTaskDbInMemory();
    final workflowDb = sqlite3.openInMemory();
    final tasks = TaskService(SqliteTaskRepository(taskDb), eventBus: eventBus);
    final workflows = FakeWorkflowService(
      db: workflowDb,
      taskService: tasks,
      eventBus: eventBus,
      dataDir: tempDir.path,
    );
    final localServer = composeServer(
      core: ServerCoreDeps(
        sessions: localSessions,
        messages: localMessages,
        worker: localWorker,
        staticDir: _staticDirPath,
      ),
      turn: ServerTurnDeps(
        turns: composeServerTurns(
          sessions: localSessions,
          messages: localMessages,
          worker: localWorker,
          behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
        ),
      ),
      web: ServerWebDeps(workflowService: workflows, workflowDefinitionSource: InMemoryDefinitionSource(const [])),
    );
    addTearDown(() async {
      await localServer.shutdown();
      await workflows.dispose();
      await tasks.dispose();
      await eventBus.dispose();
      taskDb.close();
      workflowDb.close();
    });
    final session = await localSessions.createSession();

    final response = await localServer.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/${session.id}/send'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'message': '/workflow list'}),
      ),
    );

    final responseBody = await response.readAsString();
    expect(response.statusCode, 200, reason: responseBody);
    await localWorker.turnStarted.timeout(const Duration(seconds: 2));
    expect((await localMessages.getMessages(session.id)).single.content, '/workflow list');
    expect(workflows.startCalls, 0);
    localWorker.completeSuccess();
    await localServer.turns.waitForCompletion(session.id);
  });

  group('MCP route exposure', () {
    DartclawServer buildServer({required String host, required bool authEnabled, String? gatewayToken}) =>
        composeServer(
          core: ServerCoreDeps(
            sessions: sessions,
            messages: messages,
            worker: worker,
            staticDir: _staticDirPath,
            authEnabled: authEnabled,
            gatewayToken: gatewayToken,
            config: DartclawConfig(
              server: ServerConfig(host: host, dataDir: tempDir.path),
            ),
          ),
          turn: ServerTurnDeps(
            turns: composeServerTurns(
              sessions: sessions,
              messages: messages,
              worker: worker,
              behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
              config: DartclawConfig(
                server: ServerConfig(host: host, dataDir: tempDir.path),
              ),
            ),
          ),
        );

    Request initializeRequest({String? token}) => Request(
      'POST',
      Uri.parse('http://localhost/mcp'),
      body: jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1}),
      headers: {
        'host': 'localhost',
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      },
    );

    test('authentication-disabled loopback server mounts the standard MCP endpoint', () async {
      server = buildServer(host: 'localhost', authEnabled: false);

      final response = await server.handler(initializeRequest());

      expect(response.statusCode, 200);
    });

    test('authentication-enabled MCP route still requires its bearer', () async {
      server = buildServer(host: '0.0.0.0', authEnabled: true, gatewayToken: 'test-token');

      final response = await server.handler(initializeRequest());

      expect(response.statusCode, 401);
    });

    test('authentication-disabled non-loopback server rejects unsafe MCP requests', () async {
      server = buildServer(host: '0.0.0.0', authEnabled: false);

      final response = await server.handler(initializeRequest());

      expect(response.statusCode, 403);
    });
  });

  test('authentication-disabled run-now rejects cross-origin browser requests', () async {
    final turns = composeServerTurns(
      sessions: sessions,
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
    );
    final schedule = ScheduleService(
      turns: turns,
      sessions: sessions,
      jobs: [
        ScheduledJob(
          id: 'memory-journal',
          prompt: 'Journal memory',
          scheduleType: ScheduleType.cron,
          cronExpression: CronExpression.parse('0 22 * * *'),
        ),
      ],
    )..start();
    addTearDown(schedule.stop);
    server = composeServer(
      core: ServerCoreDeps(
        sessions: sessions,
        messages: messages,
        worker: worker,
        staticDir: _staticDirPath,
        runtimeConfig: RuntimeConfig(heartbeatEnabled: false, gitSyncEnabled: false),
        authEnabled: false,
      ),
      turn: ServerTurnDeps(turns: turns),
      observability: ServerObservabilityDeps(scheduleService: schedule),
    );

    final response = await server.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/scheduling/jobs/memory-journal/run'),
        headers: {'host': 'localhost', 'origin': 'https://attacker.example'},
      ),
    );

    expect(response.statusCode, 403);
    expect(worker.hasTurnStarted, isFalse);
  });

  group('core dataDir wiring', () {
    test('config API writes restart state under core dataDir, not config.server.dataDir', () async {
      final coreDataDir = Directory(p.join(tempDir.path, 'core-data'))..createSync();
      final configDataDir = Directory(p.join(tempDir.path, 'config-data'))..createSync();
      final configPath = p.join(tempDir.path, 'dartclaw.yaml');
      File(configPath).writeAsStringSync('port: 3000\nhost: localhost\n');
      final config = DartclawConfig(server: ServerConfig(dataDir: configDataDir.path));
      final localSessions = SessionService(baseDir: p.join(tempDir.path, 'config-api-sessions'));
      final localMessages = MessageService(baseDir: p.join(tempDir.path, 'config-api-messages'));
      final localWorker = FakeWorkerService();
      final turns = composeServerTurns(
        sessions: localSessions,
        messages: localMessages,
        worker: localWorker,
        behavior: BehaviorFileService(workspaceDir: p.join(tempDir.path, 'config-api-workspace')),
        config: config,
      );
      final writer = ConfigWriter(configPath: configPath);
      final sse = SseBroadcast();
      final localServer = composeServer(
        core: ServerCoreDeps(
          sessions: localSessions,
          messages: localMessages,
          worker: localWorker,
          dataDir: coreDataDir.path,
          staticDir: _staticDirPath,
          authEnabled: false,
          config: config,
          configWriter: writer,
          runtimeConfig: RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true),
          restartService: RestartService(turns: turns, exit: (_) {}),
        ),
        turn: ServerTurnDeps(turns: turns),
        observability: ServerObservabilityDeps(sseBroadcast: sse),
      );
      addTearDown(localServer.shutdown);

      final response = await localServer.handler(
        Request(
          'PATCH',
          Uri.parse('http://localhost/api/config'),
          headers: {'content-type': 'application/json', 'host': 'localhost'},
          body: jsonEncode({'port': 3001}),
        ),
      );

      expect(response.statusCode, equals(200));
      expect(File(p.join(coreDataDir.path, 'restart.pending')).existsSync(), isTrue);
      expect(File(p.join(configDataDir.path, 'restart.pending')).existsSync(), isFalse);
    });

    test('GitHub delivery store opens under core dataDir, not config.server.dataDir', () async {
      final coreDataDir = Directory(p.join(tempDir.path, 'core-data'))..createSync();
      final configDataDir = Directory(p.join(tempDir.path, 'config-data'))..createSync();
      final config = DartclawConfig(
        server: ServerConfig(dataDir: configDataDir.path),
        extensions: const {'github': GitHubWebhookConfig(enabled: true, webhookSecret: 'secret')},
      );
      final localSessions = SessionService(baseDir: p.join(tempDir.path, 'github-sessions'));
      final localMessages = MessageService(baseDir: p.join(tempDir.path, 'github-messages'));
      final localWorker = FakeWorkerService();
      final turns = composeServerTurns(
        sessions: localSessions,
        messages: localMessages,
        worker: localWorker,
        behavior: BehaviorFileService(workspaceDir: p.join(tempDir.path, 'github-workspace')),
        config: config,
      );
      final taskDb = openTaskDbInMemory();
      final workflowDb = sqlite3.openInMemory();
      final workflowEvents = EventBus();
      final workflowTasks = TaskService(SqliteTaskRepository(taskDb), eventBus: workflowEvents);
      final workflows = FakeWorkflowService(
        db: workflowDb,
        taskService: workflowTasks,
        eventBus: workflowEvents,
        dataDir: coreDataDir.path,
      );
      final localServer = composeServer(
        core: ServerCoreDeps(
          sessions: localSessions,
          messages: localMessages,
          worker: localWorker,
          dataDir: coreDataDir.path,
          staticDir: _staticDirPath,
          authEnabled: false,
          config: config,
        ),
        turn: ServerTurnDeps(turns: turns),
        web: ServerWebDeps(workflowService: workflows, workflowDefinitionSource: InMemoryDefinitionSource(const [])),
      );
      addTearDown(() async {
        await localServer.shutdown();
        await workflows.dispose();
        await workflowTasks.dispose();
        await workflowEvents.dispose();
        taskDb.close();
        workflowDb.close();
      });

      final response = await localServer.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/webhook/github'),
          headers: {
            'content-type': 'application/json',
            'x-github-event': 'pull_request',
            'x-github-delivery': 'delivery-1',
            'x-hub-signature-256': 'sha256=wrong',
            'host': 'localhost',
          },
          body: '{}',
        ),
      );

      expect(response.statusCode, equals(403));
      expect(File(p.join(coreDataDir.path, 'webhook_deliveries.db')).existsSync(), isTrue);
      expect(File(p.join(configDataDir.path, 'webhook_deliveries.db')).existsSync(), isFalse);
    });
  });

  group('shutdown', () {
    test('cancels active turn then stops worker', () async {
      final session = await sessions.createSession();
      final sessionId = session.id;

      final handler = server.handler;

      // Start a turn and keep it active while shutdown runs.
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

      final sendFuture = handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/$sessionId/send'),
          body: '{"message": "hi"}',
          headers: {'content-type': 'application/json'},
        ),
      );
      await worker.turnStarted;
      worker.completeSuccess();
      await server.turns.waitForCompletion(sessionId);
      await sendFuture;
      // Drain trailing teardown microtasks so the active-turn set is fully
      // released before shutdown inspects it; otherwise shutdown can observe a
      // not-yet-released turn and cancel it (a timing flake seen on CI).
      await pumpEventQueue();

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
    late RunnerObserver runnerObserver;
    late String configDataDir;

    setUp(() {
      taskDb = openTaskDbInMemory();
      configDataDir = p.join(tempDir.path, 'config-data');
      taskService = TaskService(SqliteTaskRepository(taskDb));
      eventBus = EventBus();
      worktreeManager = WorktreeManager(
        dataDir: tempDir.path,
        projectDir: tempDir.path,
        processRunner: RecordingGitRunner().run,
      );
      taskFileGuard = TaskFileGuard();
      final gitGateway = FakeGitGateway()..initWorktree(tempDir.path);
      mergeExecutor = MergeExecutor(projectDir: tempDir.path, gitPort: gitGateway);
      runnerObserver = _buildRunnerObserver(worker, messages);
      server = composeServer(
        core: ServerCoreDeps(
          sessions: sessions,
          messages: messages,
          worker: worker,
          dataDir: tempDir.path,
          staticDir: _staticDirPath,
          gatewayToken: 'test-token',
          tokenService: TokenService(token: 'test-token'),
          config: DartclawConfig(server: ServerConfig(dataDir: configDataDir)),
        ),
        turn: ServerTurnDeps(
          turns: composeServerTurns(
            sessions: sessions,
            messages: messages,
            worker: worker,
            behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
            eventBus: eventBus,
          ),
        ),
        tasks: ServerTaskDeps(
          taskService: taskService,
          worktreeManager: worktreeManager,
          taskFileGuard: taskFileGuard,
          runnerObserver: runnerObserver,
          mergeExecutor: mergeExecutor,
          eventBus: eventBus,
        ),
        observability: ServerObservabilityDeps(eventBus: eventBus),
      );
    });

    tearDown(() async {
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
          body: jsonEncode({
            'title': 'Task from server',
            'description': 'Describe the work',
            'configJson': {'needsWorktree': false},
          }),
          headers: {'content-type': 'application/json', 'authorization': 'Bearer test-token'},
        ),
      );

      expect(response.statusCode, equals(201));
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['status'], 'draft');
    });

    test('task artifact usage reads the core dataDir instead of config.server.dataDir', () async {
      final create = await server.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/tasks'),
          body: jsonEncode({'title': 'Artifact task', 'description': 'Prove the task route dependency'}),
          headers: {'content-type': 'application/json', 'authorization': 'Bearer test-token'},
        ),
      );
      final created = jsonDecode(await create.readAsString()) as Map<String, dynamic>;
      final taskId = created['id'] as String;
      final coreArtifacts = Directory(p.join(tempDir.path, 'tasks', taskId, 'artifacts'))..createSync(recursive: true);
      File(p.join(coreArtifacts.path, 'core.txt')).writeAsStringSync('123456');
      final configArtifacts = Directory(p.join(configDataDir, 'tasks', taskId, 'artifacts'))
        ..createSync(recursive: true);
      File(p.join(configArtifacts.path, 'config.txt')).writeAsStringSync('wrong-size');

      final response = await server.handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/tasks/$taskId'),
          headers: {'authorization': 'Bearer test-token'},
        ),
      );
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

      expect(response.statusCode, equals(200));
      expect(body['artifactDiskBytes'], equals(6));
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

      final s = composeServer(
        core: ServerCoreDeps(sessions: sessions, messages: messages, worker: worker, staticDir: _staticDirPath),
        turn: ServerTurnDeps(
          turns: composeServerTurns(
            sessions: sessions,
            messages: messages,
            worker: worker,
            behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
            eventBus: eventBus,
          ),
        ),
        tasks: ServerTaskDeps(taskService: taskService, eventBus: eventBus),
        observability: ServerObservabilityDeps(eventBus: eventBus),
      );

      expect(
        () => s.handler(Request('GET', Uri.parse('http://localhost/'))),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('worktreeManager'))),
      );
    });

    test('throws when configWriter is enabled without restart dependencies', () async {
      final configWriter = ConfigWriter(configPath: p.join(tempDir.path, 'dartclaw.yaml'));
      addTearDown(configWriter.dispose);

      final s = composeServer(
        core: ServerCoreDeps(
          sessions: sessions,
          messages: messages,
          worker: worker,
          staticDir: _staticDirPath,
          configWriter: configWriter,
        ),
        turn: ServerTurnDeps(
          turns: composeServerTurns(
            sessions: sessions,
            messages: messages,
            worker: worker,
            behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
          ),
        ),
      );

      expect(
        () => s.handler(Request('GET', Uri.parse('http://localhost/'))),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('restartService'))),
      );
    });

    test('throws when configWriter has restartService but not sseBroadcast', () async {
      final configWriter = ConfigWriter(configPath: p.join(tempDir.path, 'dartclaw.yaml'));
      addTearDown(configWriter.dispose);

      final turns = composeServerTurns(
        sessions: sessions,
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
      );
      final s = composeServer(
        core: ServerCoreDeps(
          sessions: sessions,
          messages: messages,
          worker: worker,
          staticDir: _staticDirPath,
          configWriter: configWriter,
          restartService: RestartService(turns: turns, exit: (_) {}),
        ),
        turn: ServerTurnDeps(turns: turns),
      );

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

      final turns = composeServerTurns(
        sessions: sessions,
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
      );
      final s = composeServer(
        core: ServerCoreDeps(
          sessions: sessions,
          messages: messages,
          worker: worker,
          staticDir: _staticDirPath,
          configWriter: configWriter,
          restartService: RestartService(turns: turns, exit: (_) {}),
        ),
        turn: ServerTurnDeps(turns: turns),
        observability: ServerObservabilityDeps(sseBroadcast: sseBroadcast),
      );

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
      server = composeServer(
        core: ServerCoreDeps(
          sessions: sessions,
          messages: messages,
          worker: worker,
          staticDir: _staticDirPath,
          gatewayToken: 'test-token',
          tokenService: TokenService(token: 'test-token'),
        ),
        turn: ServerTurnDeps(
          turns: composeServerTurns(
            sessions: sessions,
            messages: messages,
            worker: worker,
            behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
          ),
        ),
        tasks: ServerTaskDeps(goalService: goalService),
      );
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
