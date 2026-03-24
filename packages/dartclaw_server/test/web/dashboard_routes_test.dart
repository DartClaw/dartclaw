import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

String _staticDir() {
  const fromPkg = 'lib/src/static';
  if (Directory(fromPkg).existsSync()) return fromPkg;
  return p.join('packages', 'dartclaw_server', fromPkg);
}

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late String workspaceDir;
  late KvService kvService;
  late SessionService sessions;
  late MessageService messages;
  late TaskService taskService;
  late WorktreeManager worktreeManager;
  late TaskFileGuard taskFileGuard;
  late MergeExecutor mergeExecutor;
  late AgentObserver agentObserver;
  late DartclawServer server;
  late Handler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_dashboard_routes_test_');
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
      processRunner: _successfulProcessResult,
    );
    taskFileGuard = TaskFileGuard();
    mergeExecutor = MergeExecutor(projectDir: tempDir.path, processRunner: _successfulProcessResult);
    agentObserver = AgentObserver(
      pool: HarnessPool(
        runners: [TurnRunner(harness: worker, messages: messages, behavior: behavior)],
      ),
    );

    server =
        (DartclawServerBuilder()
              ..sessions = sessions
              ..messages = messages
              ..worker = worker
              ..staticDir = _staticDir()
              ..behavior = behavior
              ..appDisplay = AppDisplayParams(dataDir: tempDir.path)
              ..workspaceDisplay = WorkspaceDisplayParams(path: workspaceDir)
              ..schedulingDisplay = SchedulingDisplayParams(
                jobs: [
                  {'name': 'daily-summary', 'schedule': '0 8 * * *', 'delivery': 'announce', 'status': 'active'},
                ],
              )
              ..runtimeConfig = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: false)
              ..config = DartclawConfig(
                server: ServerConfig(dataDir: tempDir.path),
                container: const ContainerConfig(enabled: true),
              )
              ..memoryStatusService = MemoryStatusService(
                workspaceDir: workspaceDir,
                config: DartclawConfig(server: ServerConfig(dataDir: tempDir.path)),
                kvService: kvService,
              )
              ..taskService = taskService
              ..worktreeManager = worktreeManager
              ..taskFileGuard = taskFileGuard
              ..mergeExecutor = mergeExecutor
              ..agentObserver = agentObserver)
            .build();
    handler = server.handler;
  });

  tearDown(() async {
    await server.shutdown();
    agentObserver.dispose();
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

  test('dev config hides non-settings dashboard routes even when services are wired', () async {
    final fixture = _buildConfiguredServer(DartclawConfig.load(configPath: _exampleConfigPath('dev.yaml')));
    addTearDown(() => _disposeFixture(fixture));

    final settings = await fixture.handler(Request('GET', Uri.parse('http://localhost/settings')));
    final settingsBody = await settings.readAsString();
    expect(settings.statusCode, equals(200));
    expect(settingsBody, contains('href="/settings" hx-get="/settings"'));
    expect(settingsBody, isNot(contains('href="/health-dashboard" hx-get="/health-dashboard"')));
    expect(settingsBody, isNot(contains('href="/memory" hx-get="/memory"')));
    expect(settingsBody, isNot(contains('href="/scheduling" hx-get="/scheduling"')));
    expect(settingsBody, isNot(contains('href="/tasks" hx-get="/tasks"')));
    expect(settingsBody, isNot(contains('class="sidebar-section-label">Channels')));
    expect(settingsBody, isNot(contains('No active channels')));

    expect(
      (await fixture.handler(Request('GET', Uri.parse('http://localhost/health-dashboard')))).statusCode,
      equals(404),
    );
    expect((await fixture.handler(Request('GET', Uri.parse('http://localhost/memory')))).statusCode, equals(404));
    expect((await fixture.handler(Request('GET', Uri.parse('http://localhost/scheduling')))).statusCode, equals(404));
    expect((await fixture.handler(Request('GET', Uri.parse('http://localhost/tasks')))).statusCode, equals(404));
  });

  test('personal-assistant config keeps only settings and scheduling even when services are wired', () async {
    final fixture = _buildConfiguredServer(
      DartclawConfig.load(configPath: _exampleConfigPath('personal-assistant.yaml')),
    );
    addTearDown(() => _disposeFixture(fixture));

    final settings = await fixture.handler(Request('GET', Uri.parse('http://localhost/settings')));
    final settingsBody = await settings.readAsString();
    expect(settings.statusCode, equals(200));
    expect(settingsBody, contains('href="/settings" hx-get="/settings"'));
    expect(settingsBody, contains('href="/scheduling" hx-get="/scheduling"'));
    expect(settingsBody, isNot(contains('href="/health-dashboard" hx-get="/health-dashboard"')));
    expect(settingsBody, isNot(contains('href="/memory" hx-get="/memory"')));
    expect(settingsBody, isNot(contains('href="/tasks" hx-get="/tasks"')));
    expect(settingsBody, isNot(contains('class="sidebar-section-label">Channels')));
    expect(settingsBody, isNot(contains('No active channels')));

    expect(
      (await fixture.handler(Request('GET', Uri.parse('http://localhost/health-dashboard')))).statusCode,
      equals(404),
    );
    expect((await fixture.handler(Request('GET', Uri.parse('http://localhost/memory')))).statusCode, equals(404));
    expect((await fixture.handler(Request('GET', Uri.parse('http://localhost/tasks')))).statusCode, equals(404));
    expect((await fixture.handler(Request('GET', Uri.parse('http://localhost/scheduling')))).statusCode, equals(200));
  });
}

Future<ProcessResult> _successfulProcessResult(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  return ProcessResult(0, 0, '', '');
}

String _exampleConfigPath(String fileName) {
  final direct = p.join('examples', fileName);
  if (File(direct).existsSync()) return direct;
  return p.join('..', '..', '..', 'examples', fileName);
}

typedef _ConfiguredServerFixture = ({
  AgentObserver agentObserver,
  Handler handler,
  KvService kvService,
  DartclawServer server,
  TaskService taskService,
  Directory tempDir,
});

_ConfiguredServerFixture _buildConfiguredServer(DartclawConfig config) {
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
    processRunner: _successfulProcessResult,
  );
  final taskFileGuard = TaskFileGuard();
  final mergeExecutor = MergeExecutor(projectDir: tempDir.path, processRunner: _successfulProcessResult);
  final agentObserver = AgentObserver(
    pool: HarnessPool(
      runners: [TurnRunner(harness: worker, messages: messages, behavior: behavior)],
    ),
  );
  final healthService = HealthService(
    worker: worker,
    searchDbPath: p.join(tempDir.path, 'search.db'),
    sessionsDir: p.join(tempDir.path, 'sessions'),
    tasksDir: p.join(tempDir.path, 'tasks'),
  );

  final server =
      (DartclawServerBuilder()
            ..sessions = sessions
            ..messages = messages
            ..worker = worker
            ..staticDir = _staticDir()
            ..behavior = behavior
            ..appDisplay = AppDisplayParams(dataDir: tempDir.path)
            ..workspaceDisplay = WorkspaceDisplayParams(path: workspaceDir)
            ..heartbeatDisplay = HeartbeatDisplayParams(
              enabled: config.scheduling.heartbeatEnabled,
              intervalMinutes: config.scheduling.heartbeatIntervalMinutes,
            )
            ..schedulingDisplay = SchedulingDisplayParams(
              jobs: config.scheduling.jobs,
              scheduledTasks: config.scheduling.taskDefinitions,
            )
            ..runtimeConfig = RuntimeConfig(
              heartbeatEnabled: config.scheduling.heartbeatEnabled,
              gitSyncEnabled: config.workspace.gitSyncEnabled,
            )
            ..config = config
            ..healthService = healthService
            ..memoryStatusService = MemoryStatusService(
              workspaceDir: workspaceDir,
              config: config,
              kvService: kvService,
            )
            ..taskService = taskService
            ..worktreeManager = worktreeManager
            ..taskFileGuard = taskFileGuard
            ..mergeExecutor = mergeExecutor
            ..agentObserver = agentObserver)
          .build();

  return (
    agentObserver: agentObserver,
    handler: server.handler,
    kvService: kvService,
    server: server,
    taskService: taskService,
    tempDir: tempDir,
  );
}

Future<void> _disposeFixture(_ConfiguredServerFixture fixture) async {
  await fixture.server.shutdown();
  fixture.agentObserver.dispose();
  await fixture.taskService.dispose();
  await fixture.kvService.dispose();
  if (fixture.tempDir.existsSync()) {
    fixture.tempDir.deleteSync(recursive: true);
  }
}
