import 'dart:io';

import 'package:dartclaw_cli/src/commands/service_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
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

  test('ServiceWiring materializes embedded workflow skills', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_positive_skills_');
    final dataDir = tempDir.resolveSymbolicLinksSync();
    final fakeHome = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
    final projectA = Directory(p.join(tempDir.path, 'project-a'))..createSync(recursive: true);
    final projectB = Directory(p.join(tempDir.path, 'project-b'))..createSync(recursive: true);
    final configFile = File(p.join(tempDir.path, 'dartclaw.yaml'))..writeAsStringSync('');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    _seedProviderAndThenSkills(fakeHome.path);
    final logService = LogService.fromConfig(format: 'human', level: 'WARNING', redactor: LogRedactor());
    logService.install();
    addTearDown(logService.dispose);

    final wiring = ServiceWiring(
      config: _baseConfig(dataDir, projectA: projectA.path, projectB: projectB.path),
      dataDir: dataDir,
      port: 3001,
      harnessFactory: _harnessFactoryFor(FakeAgentHarness()),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: MessageRedactor(),
      resolvedAssets: const ResolvedAssets.embedded(),
      skillProvisionerEnvironment: {'HOME': fakeHome.path},
    );

    final result = await wiring.wire();
    addTearDown(result.shutdownExtras);

    expect(_unexpectedDataDirSkillEntries(dataDir), isEmpty);
    for (final name in const [
      'dartclaw-discover-andthen-spec',
      'dartclaw-discover-andthen-plan',
      'dartclaw-validate-workflow',
      'dartclaw-merge-resolve',
    ]) {
      expect(File(p.join(dataDir, '.agents', 'skills', name, 'SKILL.md')).existsSync(), isTrue, reason: name);
      expect(File(p.join(dataDir, '.claude', 'skills', name, 'SKILL.md')).existsSync(), isTrue, reason: name);
      expect(
        Link(p.join(projectA.path, '.agents', 'skills', name)).targetSync(),
        p.join(dataDir, '.agents', 'skills', name),
      );
      expect(
        Link(p.join(projectB.path, '.claude', 'skills', name)).targetSync(),
        p.join(dataDir, '.claude', 'skills', name),
      );
    }
    expect(File(p.join(dataDir, '.dartclaw-native-skills')).existsSync(), isTrue);
    expect(_findDartclawEntries(fakeHome.path), isEmpty);

    // Workflow-registry proof: every shipped built-in workflow must register
    // without filesystem skill-reference validation at load time.
    final workflowRegistry = result.workflowRegistry;
    final registeredNames = workflowRegistry.listAll().map((w) => w.name).toSet();
    for (final builtIn in const ['plan-and-implement', 'spec-and-implement', 'code-review']) {
      expect(
        registeredNames,
        contains(builtIn),
        reason:
            'Built-in workflow "$builtIn" must be registered after wire(); '
            'exclusion implies an unresolved skill ref or validator regression. '
            'Registered: $registeredNames',
      );
    }
  });
}

/// AndThen-owned skills referenced by the shipped workflow definitions.
const _shippedDartclawSkillRefs = <String>[
  'andthen:prd',
  'andthen:spec',
  'andthen:plan',
  'andthen:exec-spec',
  'andthen:architecture',
  'andthen:review',
  'andthen:quick-review',
  'andthen:remediate-findings',
  'andthen:simplify-code',
];

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code)');
}

List<String> _findDartclawEntries(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return const [];
  return [
    for (final entity in dir.listSync(recursive: true, followLinks: false))
      if (p.basename(entity.path).startsWith('dartclaw-')) entity.path,
  ];
}

List<String> _unexpectedDataDirSkillEntries(String dataDir) {
  final allowed = {
    'dartclaw-discover-andthen-spec',
    'dartclaw-discover-andthen-plan',
    'dartclaw-validate-workflow',
    'dartclaw-merge-resolve',
  };
  final roots = [Directory(p.join(dataDir, '.agents', 'skills')), Directory(p.join(dataDir, '.claude', 'skills'))];
  return [
    for (final root in roots)
      if (root.existsSync())
        for (final entity in root.listSync(followLinks: false))
          if (entity is Directory && !allowed.contains(p.basename(entity.path))) entity.path,
  ];
}

DartclawConfig _baseConfig(String dataDir, {String? projectA, String? projectB}) {
  return DartclawConfig(
    agent: const AgentConfig(provider: 'claude'),
    credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'k')}),
    providers: ProvidersConfig(
      entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
    ),
    gateway: const GatewayConfig(authMode: 'none'),
    projects: ProjectConfig(
      definitions: {
        if (projectA != null) 'project-a': ProjectDefinition(id: 'project-a', localPath: projectA, branch: 'main'),
        if (projectB != null) 'project-b': ProjectDefinition(id: 'project-b', localPath: projectB, branch: 'main'),
      },
    ),
    server: ServerConfig(
      dataDir: dataDir,
      staticDir: _staticDir(),
      templatesDir: _templatesDir(),
      claudeExecutable: Platform.resolvedExecutable,
    ),
  );
}

void _seedProviderAndThenSkills(String home) {
  final claudeRoot = p.join(home, '.claude', 'skills');
  for (final name in _shippedDartclawSkillRefs) {
    final dir = Directory(p.join(claudeRoot, name))..createSync(recursive: true);
    File(p.join(dir.path, 'SKILL.md')).writeAsStringSync('---\nname: $name\ndescription: $name\n---\n# $name\n');
  }
}
