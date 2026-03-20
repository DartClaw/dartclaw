import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/behavior/behavior_file_service.dart';
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
  late DartclawServer server;
  late Handler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_dashboard_routes_test_');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(workspaceDir).createSync(recursive: true);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);

    server = DartclawServer(
      sessions: sessions,
      messages: messages,
      worker: FakeAgentHarness(),
      staticDir: _staticDir(),
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      appDisplay: AppDisplayParams(dataDir: tempDir.path),
      workspaceDisplay: WorkspaceDisplayParams(path: workspaceDir),
      schedulingDisplay: SchedulingDisplayParams(
        jobs: [
          {'name': 'daily-summary', 'schedule': '0 8 * * *', 'delivery': 'announce', 'status': 'active'},
        ],
      ),
    );

    server.setRuntimeServices(
      runtimeConfig: RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: false),
      memoryStatusService: MemoryStatusService(
        workspaceDir: workspaceDir,
        config: DartclawConfig(server: ServerConfig(dataDir: tempDir.path)),
        kvService: kvService,
      ),
    );
    handler = server.handler;
  });

  tearDown(() async {
    await server.shutdown();
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
}
