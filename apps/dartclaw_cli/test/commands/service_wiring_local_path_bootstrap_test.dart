import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/service_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

String _staticDir() {
  const fromPkg = 'packages/dartclaw_server/lib/src/static';
  if (Directory(fromPkg).existsSync()) return fromPkg;
  return p.join('..', '..', 'packages', 'dartclaw_server', 'lib', 'src', 'static');
}

String _templatesDir() {
  const fromWorkspace = 'packages/dartclaw_server/lib/src/templates';
  if (Directory(fromWorkspace).existsSync()) return fromWorkspace;
  return p.join('..', '..', 'packages', 'dartclaw_server', 'lib', 'src', 'templates');
}

HarnessFactory _harnessFactoryFor(AgentHarness harness) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => harness);
  return factory;
}

void _runGit(String workingDirectory, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed in $workingDirectory: ${result.stderr}');
  }
}

Future<void> _waitFor(bool Function() predicate, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during service wiring test');
}

Future<void> _disposeWiringResult(WiringResult result, LogService logService) async {
  await result.server.shutdown();
  await result.shutdownExtras();
  result.heartbeat?.stop();
  result.scheduleService?.stop();
  result.resetService.dispose();
  await result.kvService.dispose();
  await result.selfImprovement.dispose();
  await result.taskService.dispose();
  await result.eventBus.dispose();
  await result.qmdManager?.stop();
  result.searchDb.close();
  await logService.dispose();
}

void main() {
  late Directory tempDir;
  late File configFile;
  late FakeAgentHarness worker;
  late MessageRedactor messageRedactor;
  late LogService logService;

  setUpAll(() => initTemplates(_templatesDir()));

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_service_wiring_local_path_');
    configFile = File(p.join(tempDir.path, 'dartclaw.yaml'))..writeAsStringSync('# test config\n');
    worker = FakeAgentHarness();
    messageRedactor = MessageRedactor();
    logService = LogService.fromConfig(
      format: 'human',
      level: 'INFO',
      redactor: LogRedactor(redactor: messageRedactor),
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('workflow API bootstraps local-path projects from the current HEAD without origin/', () async {
    final projectDir = Directory(p.join(tempDir.path, 'live-project'))..createSync(recursive: true);
    final workflowsDir = Directory(p.join(projectDir.path, 'workflows'))..createSync(recursive: true);
    File(p.join(workflowsDir.path, 'bootstrap-localpath.yaml')).writeAsStringSync('''
name: bootstrap-localpath
description: Pause immediately after bootstrap.
variables:
  PROJECT:
    required: true
    description: Target project
  BRANCH:
    required: false
    description: Base ref used for bootstrap
    default: ""
project: "{{PROJECT}}"
gitStrategy:
  bootstrap: true
  worktree: shared
steps:
  - id: gate
    name: Gate
    type: approval
    prompt: Approve bootstrap.
''');

    _runGit(projectDir.path, ['init', '-b', 'main']);
    _runGit(projectDir.path, ['config', 'user.name', 'Workflow Test']);
    _runGit(projectDir.path, ['config', 'user.email', 'workflow@test.local']);
    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('base\n');
    _runGit(projectDir.path, ['add', 'README.md', 'workflows/bootstrap-localpath.yaml']);
    _runGit(projectDir.path, ['commit', '-m', 'initial']);
    _runGit(projectDir.path, ['checkout', '-b', 'feature/local']);
    File(p.join(projectDir.path, 'local.txt')).writeAsStringSync('unpushed local commit\n');
    _runGit(projectDir.path, ['add', 'local.txt']);
    _runGit(projectDir.path, ['commit', '-m', 'local change']);

    final headCommit =
        (Process.runSync('git', ['rev-parse', 'HEAD'], workingDirectory: projectDir.path).stdout as String).trim();

    final skillsHomeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path, branch: '')},
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      skillsHomeDir: skillsHomeDir.path,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    final response = await result.server.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'definition': 'bootstrap-localpath',
          'variables': {'PROJECT': 'alpha'},
        }),
      ),
    );

    final responseBody = await response.readAsString();
    expect(response.statusCode, 201, reason: responseBody);

    final runJson = jsonDecode(responseBody) as Map<String, dynamic>;
    expect(runJson['id'], isA<String>());

    await _waitFor(() {
      final result = Process.runSync('git', [
        'branch',
        '--format=%(refname:short)',
        '--list',
        'dartclaw/workflow/*',
      ], workingDirectory: projectDir.path);
      final stdout = result.stdout as String;
      return result.exitCode == 0 && stdout.trim().isNotEmpty;
    });

    final branchList = Process.runSync('git', [
      'branch',
      '--format=%(refname:short) %(objectname)',
      '--list',
      'dartclaw/workflow/*',
    ], workingDirectory: projectDir.path);
    expect(branchList.exitCode, 0, reason: branchList.stderr.toString());
    final refs = (branchList.stdout as String)
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    expect(refs, hasLength(1), reason: 'unexpected workflow refs: ${branchList.stdout}');

    final parts = refs.single.split(' ');
    expect(parts.first, startsWith('dartclaw/workflow/'));
    expect(parts.last, headCommit);
  });
}
