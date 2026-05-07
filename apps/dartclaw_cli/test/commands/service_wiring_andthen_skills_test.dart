import 'dart:io';

import 'package:dartclaw_cli/src/commands/service_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show SkillProvisionException;
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

  test('missing built-in skills source throws SkillProvisionException', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_missing_skills_');
    final configFile = File(p.join(tempDir.path, 'dartclaw.yaml'))..writeAsStringSync('');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final assetRoot = _seedAssetRoot(tempDir, createSkills: false);
    final logService = LogService.fromConfig(format: 'human', level: 'WARNING', redactor: LogRedactor());
    logService.install();
    addTearDown(logService.dispose);

    final config = _baseConfig(tempDir.path);
    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
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
      assetResolver: AssetResolver(homeDir: tempDir.path, version: 'test'),
    );

    expect(assetRoot.existsSync(), isTrue);
    await expectLater(
      wiring.wire(),
      throwsA(isA<SkillProvisionException>().having((e) => e.message, 'message', contains('built-in skills source'))),
    );
  });

  test('ServiceWiring workflow skills bootstrap (positive)', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_positive_skills_');
    final dataDir = tempDir.resolveSymbolicLinksSync();
    final fakeHome = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
    final projectA = Directory(p.join(tempDir.path, 'project-a'))..createSync(recursive: true);
    final projectB = Directory(p.join(tempDir.path, 'project-b'))..createSync(recursive: true);
    final configFile = File(p.join(tempDir.path, 'dartclaw.yaml'))..writeAsStringSync('');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    _seedAssetRoot(tempDir, createSkills: true);
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
      assetResolver: AssetResolver(homeDir: tempDir.path, version: 'test'),
      skillProvisionerEnvironment: {'HOME': fakeHome.path},
    );

    final result = await wiring.wire();
    addTearDown(result.shutdownExtras);

    expect(_unexpectedDataDirSkillEntries(dataDir), isEmpty);
    for (final name in const ['dartclaw-discover-project', 'dartclaw-validate-workflow', 'dartclaw-merge-resolve']) {
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

    // Wiring proof: SkillRegistry built by ServiceWiring.wire()
    // must resolve every AndThen skill the shipped workflow YAMLs reference.
    // Without this, plan-and-implement / spec-and-implement / code-review would
    // be silently excluded from the registry as unresolved skill refs.
    final skillRegistry = result.skillRegistry;
    for (final name in _shippedDartclawSkillRefs) {
      expect(
        skillRegistry.resolveRef(name, 'claude'),
        isNotNull,
        reason: '$name must resolve through provider-native discovery',
      );
      expect(skillRegistry.validateRef(name, provider: 'claude'), isNull, reason: '$name validateRef should pass');
    }
    for (final name in const ['dartclaw-discover-project', 'dartclaw-validate-workflow', 'dartclaw-merge-resolve']) {
      expect(skillRegistry.getByName(name), isNotNull, reason: '$name DC-native skill must resolve');
    }

    // Workflow-registry proof: every shipped
    // built-in workflow must register against the resulting skill registry.
    // Earlier symptom: H1's wiring gap or the validator's role-alias blindness
    // would silently exclude these from `WorkflowRegistry.listAll()`, leaving
    // the workflow routes returning DEFINITION_NOT_FOUND.
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
  'andthen:refactor',
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
  final allowed = {'dartclaw-discover-project', 'dartclaw-validate-workflow', 'dartclaw-merge-resolve'};
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

Directory _seedAssetRoot(Directory tempDir, {required bool createSkills}) {
  final root = Directory(p.join(tempDir.path, '.dartclaw', 'assets', 'vtest'))..createSync(recursive: true);
  Directory(p.join(root.path, 'templates')).createSync(recursive: true);
  Directory(p.join(root.path, 'static')).createSync(recursive: true);
  if (createSkills) {
    for (final name in const ['dartclaw-discover-project', 'dartclaw-validate-workflow', 'dartclaw-merge-resolve']) {
      File(p.join(root.path, 'skills', name, 'SKILL.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# $name\n');
    }
  } else {
    Directory(p.join(root.path, 'skills')).createSync(recursive: true);
  }
  return root;
}

void _seedProviderAndThenSkills(String home) {
  final claudeRoot = p.join(home, '.claude', 'skills');
  for (final name in _shippedDartclawSkillRefs) {
    final dir = Directory(p.join(claudeRoot, name))..createSync(recursive: true);
    File(p.join(dir.path, 'SKILL.md')).writeAsStringSync('---\nname: $name\ndescription: $name\n---\n# $name\n');
  }
}
