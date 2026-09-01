import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnRunner;
import 'package:dartclaw_workflow/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:dartclaw_runtime/src/server.dart'
    show ServerCoreDeps, ServerObservabilityDeps, ServerTaskDeps, ServerTurnDeps, ServerWebDeps;
import 'package:dartclaw_runtime/src/server_composition.dart';

import '../test_utils.dart';
import '../execution_coordinator_test_support.dart';

late String _resolvedStaticDir;

void main() {
  setUpAll(() async {
    initTemplates(await resolveTemplatesDir());
    _resolvedStaticDir = await resolveStaticDir();
  });
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late String configDataDir;
  late String workspaceDir;
  late KvService kvService;
  late SessionService sessions;
  late MessageService messages;
  late TaskService taskService;
  late WorktreeManager worktreeManager;
  late TaskFileGuard taskFileGuard;
  late MergeExecutor mergeExecutor;
  late RunnerObserver runnerObserver;
  late DartclawServer server;
  late Handler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_dashboard_routes_test_');
    configDataDir = p.join(tempDir.path, 'config-data');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(workspaceDir).createSync(recursive: true);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    final worker = FakeAgentHarness();
    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    taskService = TaskService(InMemoryTaskRepository());
    worktreeManager = WorktreeManager(
      dataDir: tempDir.path,
      projectDir: tempDir.path,
      processRunner: RecordingGitRunner().run,
    );
    taskFileGuard = TaskFileGuard();
    final gitGateway = FakeGitGateway()..initWorktree(tempDir.path);
    mergeExecutor = MergeExecutor(projectDir: tempDir.path, gitPort: gitGateway);
    runnerObserver = RunnerObserver(
      executions: coordinatorForRunners([
        TurnRunner(
          turnLimits: const TurnLimitsConfig.defaults(),
          harness: worker,
          messages: messages,
          behavior: behavior,
        ),
      ]),
    );

    server = composeServer(
      core: ServerCoreDeps(
        sessions: sessions,
        messages: messages,
        worker: worker,
        dataDir: tempDir.path,
        staticDir: _resolvedStaticDir,
        runtimeConfig: RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: false),
        config: DartclawConfig(
          server: ServerConfig(dataDir: configDataDir),
          container: const ContainerConfig(enabled: true),
        ),
      ),
      turn: ServerTurnDeps(
        turns: composeServerTurns(
          sessions: sessions,
          messages: messages,
          worker: worker,
          behavior: behavior,
          config: DartclawConfig(
            server: ServerConfig(dataDir: configDataDir),
            container: const ContainerConfig(enabled: true),
          ),
        ),
      ),
      tasks: ServerTaskDeps(
        taskService: taskService,
        worktreeManager: worktreeManager,
        taskFileGuard: taskFileGuard,
        runnerObserver: runnerObserver,
        mergeExecutor: mergeExecutor,
      ),
      observability: ServerObservabilityDeps(
        memoryStatusService: MemoryStatusService(
          workspaceDir: workspaceDir,
          config: DartclawConfig(server: ServerConfig(dataDir: configDataDir)),
          kvService: kvService,
        ),
      ),
      web: ServerWebDeps(
        schedulingJobs: [
          {'name': 'daily-summary', 'schedule': '0 8 * * *', 'delivery': 'announce', 'status': 'active'},
        ],
      ),
    );
    handler = server.handler;
  });

  tearDown(() async {
    await server.shutdown();
    await taskService.dispose();
    await kvService.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('built-in dashboard routes', () {
    final cases = <({String route, String title})>[
      (route: '/health-dashboard', title: 'Health'),
      (route: '/settings', title: 'Settings'),
      (route: '/memory', title: 'Memory'),
      (route: '/scheduling', title: 'Scheduling'),
      (route: '/tasks', title: 'Tasks'),
    ];

    for (final testCase in cases) {
      test('${testCase.route} returns 200 and renders dashboard nav state', () async {
        final response = await handler(Request('GET', Uri.parse('http://localhost${testCase.route}')));
        final body = await response.readAsString();

        expect(response.statusCode, equals(200));
        for (final item in cases) {
          expect(body, contains('>${item.title}<'));
          expect(body, contains('href="${item.route}"'));
        }
        expect(body, contains('aria-current="page"'));
        expect(body, contains('href="${testCase.route}"'));
        expect(body, contains('>${testCase.title}<'));
      });
    }
  });

  test('/health-dashboard shows aggregate task artifact disk usage', () async {
    final artifactsDir = Directory(p.join(tempDir.path, 'tasks', 'task-1', 'artifacts'))..createSync(recursive: true);
    File(p.join(artifactsDir.path, 'report.txt')).writeAsStringSync('hello');

    final response = await handler(Request('GET', Uri.parse('http://localhost/health-dashboard')));
    final body = await response.readAsString();

    expect(response.statusCode, equals(200));
    expect(body, contains('Task Artifacts'));
    expect(body, contains('5 B'));
  });

  test('health audit reads the core dataDir instead of config.server.dataDir', () async {
    File(p.join(tempDir.path, 'audit.ndjson')).writeAsStringSync(
      '${jsonEncode({'timestamp': '2026-08-24T12:00:00.000Z', 'guard': 'file', 'hook': 'preToolUse', 'verdict': 'block', 'reason': 'core-data-dir-entry'})}\n',
    );
    Directory(configDataDir).createSync(recursive: true);
    File(p.join(configDataDir, 'audit.ndjson')).writeAsStringSync(
      '${jsonEncode({'timestamp': '2026-08-24T12:00:00.000Z', 'guard': 'file', 'hook': 'preToolUse', 'verdict': 'block', 'reason': 'config-data-dir-entry'})}\n',
    );

    final response = await handler(Request('GET', Uri.parse('http://localhost/health-dashboard/audit')));
    final body = await response.readAsString();

    expect(response.statusCode, equals(200));
    expect(body, contains('core-data-dir-entry'));
    expect(body, isNot(contains('config-data-dir-entry')));
  });

  test('config-present server still renders all service-backed dashboard nav items', () async {
    final response = await handler(Request('GET', Uri.parse('http://localhost/settings')));
    final body = await response.readAsString();

    expect(response.statusCode, equals(200));
    expect(body, contains('>Health<'));
    expect(body, contains('>Settings<'));
    expect(body, contains('>Memory<'));
    expect(body, contains('>Scheduling<'));
    expect(body, contains('>Tasks<'));
  });

  test('dev config keeps the core Health dashboard available without HealthService', () async {
    final fixture = _buildConfiguredServer(
      DartclawConfig.load(configPath: await resolveWorkspacePath('examples', 'dev.yaml')),
      includeHealthService: false,
    );
    addTearDown(() => _disposeFixture(fixture));

    final settings = await fixture.handler(Request('GET', Uri.parse('http://localhost/settings')));
    final settingsBody = await settings.readAsString();
    expect(settings.statusCode, equals(200));
    expect(settingsBody, contains('href="/health-dashboard" hx-get="/health-dashboard"'));
    expect(settingsBody, contains('href="/settings" hx-get="/settings"'));
    expect(settingsBody, isNot(contains('href="/memory" hx-get="/memory"')));
    expect(settingsBody, isNot(contains('href="/scheduling" hx-get="/scheduling"')));
    expect(settingsBody, isNot(contains('href="/tasks" hx-get="/tasks"')));
    expect(settingsBody, isNot(contains('class="sidebar-section-label">Channels')));
    expect(settingsBody, isNot(contains('No active channels')));

    expect(
      (await fixture.handler(Request('GET', Uri.parse('http://localhost/health-dashboard')))).statusCode,
      equals(200),
    );
    expect((await fixture.handler(Request('GET', Uri.parse('http://localhost/memory')))).statusCode, equals(404));
    expect((await fixture.handler(Request('GET', Uri.parse('http://localhost/scheduling')))).statusCode, equals(404));
    expect((await fixture.handler(Request('GET', Uri.parse('http://localhost/tasks')))).statusCode, equals(404));
  });

  test('personal-assistant config keeps the core Health dashboard and scheduling', () async {
    final fixture = _buildConfiguredServer(
      DartclawConfig.load(configPath: await resolveWorkspacePath('examples', 'personal-assistant.yaml')),
    );
    addTearDown(() => _disposeFixture(fixture));

    final settings = await fixture.handler(Request('GET', Uri.parse('http://localhost/settings')));
    final settingsBody = await settings.readAsString();
    expect(settings.statusCode, equals(200));
    expect(settingsBody, contains('href="/health-dashboard" hx-get="/health-dashboard"'));
    expect(settingsBody, contains('href="/settings" hx-get="/settings"'));
    expect(settingsBody, contains('href="/scheduling" hx-get="/scheduling"'));
    expect(settingsBody, isNot(contains('href="/memory" hx-get="/memory"')));
    expect(settingsBody, isNot(contains('href="/tasks" hx-get="/tasks"')));
    expect(settingsBody, isNot(contains('class="sidebar-section-label">Channels')));
    expect(settingsBody, isNot(contains('No active channels')));

    expect(
      (await fixture.handler(Request('GET', Uri.parse('http://localhost/health-dashboard')))).statusCode,
      equals(200),
    );
    expect((await fixture.handler(Request('GET', Uri.parse('http://localhost/memory')))).statusCode, equals(404));
    expect((await fixture.handler(Request('GET', Uri.parse('http://localhost/tasks')))).statusCode, equals(404));
    expect((await fixture.handler(Request('GET', Uri.parse('http://localhost/scheduling')))).statusCode, equals(200));
  });

  test('scheduling reads config definitions and composed system jobs from PageContext', () async {
    final fixture = _buildConfiguredServer(
      const DartclawConfig(
        scheduling: SchedulingConfig(
          heartbeatEnabled: true,
          heartbeatIntervalMinutes: 15,
          jobs: [
            {
              'name': 'daily-summary',
              'schedule': '0 8 * * *',
              'delivery': 'announce',
              'prompt': 'Prepare the daily summary',
            },
          ],
          taskDefinitions: [
            ScheduledTaskDefinition(
              id: 'morning-review',
              cronExpression: '0 9 * * *',
              title: 'Morning review',
              description: 'Review the morning queue',
            ),
            ScheduledTaskDefinition(
              id: 'weekly-maintenance',
              cronExpression: '0 10 * * 1',
              title: 'Weekly maintenance',
              description: 'Maintain the workspace',
            ),
          ],
        ),
      ),
      schedulingJobs: const [
        {'name': 'daily-summary', 'schedule': '0 8 * * *', 'delivery': 'announce', 'status': 'active'},
        {'name': 'heartbeat', 'schedule': 'every 15 minutes', 'delivery': 'none', 'status': 'active'},
        {'name': 'credential-health', 'schedule': '0 * * * *', 'delivery': 'none', 'status': 'active'},
      ],
      systemJobNames: const ['heartbeat', 'credential-health'],
    );
    addTearDown(() => _disposeFixture(fixture));

    final response = await fixture.handler(Request('GET', Uri.parse('http://localhost/scheduling')));
    final body = await response.readAsString();

    expect(response.statusCode, equals(200));
    expect(body, contains('href="/scheduling" hx-get="/scheduling"'));
    expect(body, contains('>15<'));
    expect(body, contains('daily-summary'));
    expect(body, contains('heartbeat'));
    expect(body, contains('credential-health'));
    expect(body, contains('Morning review'));
    expect(body, contains('Weekly maintenance'));
    expect(RegExp(r'<span class="system-badge">SYSTEM</span>').allMatches(body), hasLength(2));
  });
}

typedef _ConfiguredServerFixture = ({
  RunnerObserver runnerObserver,
  Handler handler,
  KvService kvService,
  DartclawServer server,
  TaskService taskService,
  Directory tempDir,
});

_ConfiguredServerFixture _buildConfiguredServer(
  DartclawConfig config, {
  bool includeHealthService = true,
  List<Map<String, dynamic>>? schedulingJobs,
  List<String> systemJobNames = const [],
}) {
  final tempDir = Directory.systemTemp.createTempSync('dartclaw_dashboard_config_routes_test_');
  final workspaceDir = p.join(tempDir.path, 'workspace');
  Directory(workspaceDir).createSync(recursive: true);

  final kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
  final sessions = SessionService(baseDir: tempDir.path);
  final messages = MessageService(baseDir: tempDir.path);
  final worker = FakeAgentHarness();
  final behavior = BehaviorFileService(workspaceDir: workspaceDir);
  final taskService = TaskService(InMemoryTaskRepository());
  final worktreeManager = WorktreeManager(
    dataDir: tempDir.path,
    projectDir: tempDir.path,
    processRunner: RecordingGitRunner().run,
  );
  final taskFileGuard = TaskFileGuard();
  final gitGateway = FakeGitGateway()..initWorktree(tempDir.path);
  final mergeExecutor = MergeExecutor(projectDir: tempDir.path, gitPort: gitGateway);
  final runnerObserver = RunnerObserver(
    executions: coordinatorForRunners([
      TurnRunner(
        turnLimits: const TurnLimitsConfig.defaults(),
        harness: worker,
        messages: messages,
        behavior: behavior,
      ),
    ]),
  );
  final healthService = includeHealthService
      ? HealthService(
          worker: worker,
          searchDbPath: p.join(tempDir.path, 'search.db'),
          sessionsDir: p.join(tempDir.path, 'sessions'),
          tasksDir: p.join(tempDir.path, 'tasks'),
        )
      : null;

  final server = composeServer(
    core: ServerCoreDeps(
      sessions: sessions,
      messages: messages,
      worker: worker,
      dataDir: tempDir.path,
      staticDir: _resolvedStaticDir,
      runtimeConfig: RuntimeConfig(
        heartbeatEnabled: config.scheduling.heartbeatEnabled,
        gitSyncEnabled: config.workspace.gitSyncEnabled,
      ),
      config: config,
      healthService: healthService,
    ),
    turn: ServerTurnDeps(
      turns: composeServerTurns(
        sessions: sessions,
        messages: messages,
        worker: worker,
        behavior: behavior,
        config: config,
      ),
    ),
    tasks: ServerTaskDeps(
      taskService: taskService,
      worktreeManager: worktreeManager,
      taskFileGuard: taskFileGuard,
      runnerObserver: runnerObserver,
      mergeExecutor: mergeExecutor,
    ),
    observability: ServerObservabilityDeps(
      memoryStatusService: MemoryStatusService(workspaceDir: workspaceDir, config: config, kvService: kvService),
    ),
    web: ServerWebDeps(schedulingJobs: schedulingJobs ?? config.scheduling.jobs, systemJobNames: systemJobNames),
  );

  return (
    runnerObserver: runnerObserver,
    handler: server.handler,
    kvService: kvService,
    server: server,
    taskService: taskService,
    tempDir: tempDir,
  );
}

Future<void> _disposeFixture(_ConfiguredServerFixture fixture) async {
  await fixture.server.shutdown();
  await fixture.taskService.dispose();
  await fixture.kvService.dispose();
  if (fixture.tempDir.existsSync()) {
    fixture.tempDir.deleteSync(recursive: true);
  }
}
