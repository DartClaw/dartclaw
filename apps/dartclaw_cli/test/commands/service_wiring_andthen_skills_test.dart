import 'dart:io';

import 'package:dartclaw_cli/src/commands/service_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
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

void main() {
  setUpAll(() => initTemplates(_templatesDir()));

  test('install_scope: data_dir + outside localPath exits non-zero with documented error', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_andthen_bootstrap_');
    final externalProject = Directory.systemTemp.createTempSync('dartclaw_external_project_');
    final configFile = File(p.join(tempDir.path, 'dartclaw.yaml'))..writeAsStringSync('');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      if (externalProject.existsSync()) externalProject.deleteSync(recursive: true);
    });

    final stderrLines = <String>[];
    int? exitCode;

    final logService = LogService.fromConfig(format: 'human', level: 'WARNING', redactor: LogRedactor());
    logService.install();
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'k')}),
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
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: externalProject.path, branch: '')},
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3001,
      harnessFactory: _harnessFactoryFor(FakeAgentHarness()),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: stderrLines.add,
      exitFn: (code) {
        exitCode = code;
        throw _Exited(code);
      },
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: MessageRedactor(),
    );

    await expectLater(wiring.wire(), throwsA(isA<_Exited>()));
    expect(exitCode, 1);
    final combined = stderrLines.join('\n');
    expect(combined, contains('andthen.install_scope=data_dir'));
    // Validation walks spawn targets in order — the first outside-dataDir target
    // (often the captured CWD when running tests from the repo root) trips the
    // check. The message lists the offending path and both remediations.
    expect(combined, contains('install_scope: user'));
    expect(combined, contains('install_scope: both'));
    await logService.dispose();
  });
}

class _Exited implements Exception {
  final int code;
  _Exited(this.code);
  @override
  String toString() => 'Exited($code)';
}
