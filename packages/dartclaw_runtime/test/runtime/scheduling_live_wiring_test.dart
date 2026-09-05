import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// The live-scheduling seam through the real composition root.
///
/// Every other suite hand-builds the `ScheduleService`, the applier and the
/// mutation seam, so none of them notices if the composition root stops
/// threading them together. This one boots `DartclawRuntime` and drives the
/// public HTTP surface, which is the only place that wiring is load-bearing.
late String _staticDirPath;
late String _templatesDirPath;

Future<String> _resolvePackageDir(String packageRelativeAnchor) async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/$packageRelativeAnchor'));
  if (uri == null || !uri.isScheme('file')) {
    throw StateError('Could not resolve dartclaw_runtime $packageRelativeAnchor via package URI');
  }
  return p.dirname(uri.toFilePath());
}

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code) during wiring');

void main() {
  late Directory tempDir;
  late File configFile;
  late LogService logService;
  late MessageRedactor messageRedactor;

  setUpAll(() async {
    _staticDirPath = await _resolvePackageDir('src/static/app.js');
    _templatesDirPath = await _resolvePackageDir('src/templates/audit_table.dart');
    initTemplates(_templatesDirPath);
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_scheduling_live_wiring_');
    configFile = File(p.join(tempDir.path, 'dartclaw.yaml'));
    messageRedactor = MessageRedactor();
    logService = LogService.fromConfig(
      format: 'human',
      level: 'INFO',
      redactor: LogRedactor(redactor: messageRedactor),
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<DartclawRuntime> boot(List<Map<String, dynamic>> jobs) async {
    // The file and the in-memory config must agree: boot composes from the
    // object, and the applier re-reads the file.
    final rows = jobs
        .map(
          (job) =>
              '  - name: ${job['name']}\n'
              '    schedule:\n'
              '      type: once\n'
              '      at: "${(job['schedule'] as Map)['at']}"\n'
              '    prompt: "${job['prompt']}"\n'
              '    delivery: none',
        )
        .join('\n');
    configFile.writeAsStringSync('''
port: 3000
host: localhost
scheduling:
  jobs:${rows.isEmpty ? ' []' : '\n$rows'}
''');
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable)}),
      gateway: const GatewayConfig(authMode: 'none'),
      scheduling: SchedulingConfig(jobs: jobs),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDirPath,
        templatesDir: _templatesDirPath,
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );
    Directory(config.workspaceDir).createSync(recursive: true);
    final runtime = await DartclawRuntime.build(
      config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: HarnessFactory()..register('claude', (_) => FakeAgentHarness()),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      messageRedactor: messageRedactor,
      resolvedAssets: ResolvedAssets.fromSourceTree(
        templatesDir: config.server.templatesDir,
        staticDir: config.server.staticDir,
        source: AssetSource.sourceTreeDefault,
      ),
      runWorkflowSkillsBootstrap: false,
      environment: {'HOME': tempDir.path},
    );
    addTearDown(() async {
      await runtime.server!.shutdown();
      await runtime.shutdownExtras();
      runtime.scheduleService?.stop();
      runtime.requireResetService.dispose();
      await runtime.kvService.dispose();
      await runtime.requireSelfImprovement.dispose();
      await runtime.taskService.dispose();
      await runtime.eventBus.dispose();
      await runtime.qmdManager?.stop();
      runtime.searchDb.close();
      await logService.dispose();
    });
    return runtime;
  }

  /// `scheduling.jobs` as the one reader every surface uses sees it.
  Future<List<String?>> configuredJobNames() async {
    final writer = ConfigWriter(configPath: configFile.path);
    try {
      final jobs = await ScheduleMutationService(writer: writer).readJobs();
      return [for (final job in jobs) (job['id'] ?? job['name']) as String?];
    } finally {
      await writer.dispose();
    }
  }

  test('S09 a one-time entry whose instant has passed is removed at boot, not left to warn', () async {
    final runtime = await boot([
      {
        'name': 'remind-dentist',
        'schedule': {'type': 'once', 'at': DateTime.now().subtract(const Duration(hours: 3)).toIso8601String()},
        'prompt': 'Remind me',
      },
      {
        'name': 'remind-later',
        'schedule': {'type': 'once', 'at': DateTime.now().add(const Duration(hours: 3)).toIso8601String()},
        'prompt': 'Remind me later',
      },
    ]);

    expect(runtime.scheduleService, isNotNull, reason: 'the service is constructed unconditionally');
    expect(runtime.scheduleService!.hasJob('remind-dentist'), isFalse);
    // The sibling proves the prune is surgical rather than a wiped list.
    expect(runtime.scheduleService!.hasJob('remind-later'), isTrue);
    expect(await configuredJobNames(), ['remind-later']);
  });

  test('S01 a job written through the jobs API is loaded by the time the response returns', () async {
    final runtime = await boot(const []);

    final response = await runtime.server!.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/scheduling/jobs'),
        headers: {'host': 'localhost', 'content-type': 'application/json'},
        body: jsonEncode({'name': 'standup', 'schedule': '0 9 * * 1', 'prompt': 'Run standup', 'delivery': 'announce'}),
      ),
    );

    expect(response.statusCode, 201, reason: await response.readAsString());
    // Nothing was awaited between the response and this line: the composition
    // root threaded the applier all the way to the route, or this is false.
    expect(runtime.scheduleService!.hasJob('standup'), isTrue);
    expect(await configuredJobNames(), contains('standup'));
    expect(File(p.join(tempDir.path, 'restart.pending')).existsSync(), isFalse);
  });

  test('S07 the jobs API refuses an id a loaded built-in owns', () async {
    final runtime = await boot(const []);
    final builtIn = runtime.scheduleService!.builtInJobIds.first;

    final response = await runtime.server!.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/scheduling/jobs'),
        headers: {'host': 'localhost', 'content-type': 'application/json'},
        body: jsonEncode({'name': builtIn, 'schedule': '0 9 * * 1', 'prompt': 'Impostor', 'delivery': 'none'}),
      ),
    );

    expect(response.statusCode, 409, reason: await response.readAsString());
    expect(await configuredJobNames(), isEmpty);
  });

  // The three seam construction sites take three independent hand-offs of the
  // one shared applier. The jobs API is covered above; these cover the other two,
  // so deleting either hand-off fails a test instead of silently returning that
  // surface to write-without-load.
  test('S01 a job saved through the scheduling page is loaded by the time the page responds', () async {
    final runtime = await boot(const []);

    final response = await runtime.server!.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/scheduling/jobs/create'),
        headers: {'host': 'localhost', 'content-type': 'application/x-www-form-urlencoded'},
        body: 'name=page-job&schedule=0+9+*+*+1&at=&prompt=Run+it&delivery=announce',
      ),
    );

    expect(response.statusCode, 200, reason: await response.readAsString());
    expect(runtime.scheduleService!.hasJob('page-job'), isTrue);
    expect(await configuredJobNames(), contains('page-job'));
  });

  test('S01 a job written through schedule_upsert is loaded by the time the tool answers', () async {
    final runtime = await boot(const []);

    final raw = await runtime.server!.mcpHandler.handleRequest(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'schedule_upsert',
          'arguments': {'id': 'tool-job', 'schedule': '0 9 * * 1', 'type': 'prompt', 'prompt': 'Run it'},
        },
      }),
    );

    final result = (jsonDecode(raw!) as Map<String, dynamic>)['result'] as Map<String, dynamic>;
    expect(result['isError'], isNull, reason: raw);
    final payload = jsonDecode(
      ((result['content'] as List).single as Map<String, dynamic>)['text'] as String,
    ) as Map<String, dynamic>;
    expect(payload['loaded'], isTrue);
    expect(runtime.scheduleService!.hasJob('tool-job'), isTrue);
  });
}
