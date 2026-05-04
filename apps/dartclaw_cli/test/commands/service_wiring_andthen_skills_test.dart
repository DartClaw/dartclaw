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

  test('ServiceWiring andthen skills bootstrap (positive)', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_positive_skills_');
    final dataDir = tempDir.resolveSymbolicLinksSync();
    final fakeHome = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
    final configFile = File(p.join(tempDir.path, 'dartclaw.yaml'))..writeAsStringSync('');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    _seedAssetRoot(tempDir, createSkills: true);
    _seedAndthenSrc(dataDir);
    final runner = _FakeProcessRunner();
    final logService = LogService.fromConfig(format: 'human', level: 'WARNING', redactor: LogRedactor());
    logService.install();
    addTearDown(logService.dispose);

    final wiring = ServiceWiring(
      config: _baseConfig(dataDir),
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
      skillProvisionerProcessRunner: runner.run,
    );

    final result = await wiring.wire();
    addTearDown(result.shutdownExtras);

    expect(File(p.join(fakeHome.path, '.agents', 'skills', 'dartclaw-prd', 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(fakeHome.path, '.claude', 'skills', 'dartclaw-prd', 'SKILL.md')).existsSync(), isTrue);
    for (final name in const ['dartclaw-discover-project', 'dartclaw-validate-workflow', 'dartclaw-merge-resolve']) {
      expect(File(p.join(fakeHome.path, '.agents', 'skills', name, 'SKILL.md')).existsSync(), isTrue, reason: name);
      expect(File(p.join(fakeHome.path, '.claude', 'skills', name, 'SKILL.md')).existsSync(), isTrue, reason: name);
    }
    expect(File(p.join(fakeHome.path, '.agents', 'skills', '.dartclaw-andthen-sha')).readAsStringSync(), 'fake-head');
    expect(Directory(p.join(dataDir, '.agents', 'skills')).existsSync(), isFalse);
    expect(Directory(p.join(dataDir, '.claude', 'skills')).existsSync(), isFalse);

    // Wiring proof: SkillRegistry built by ServiceWiring.wire()
    // must resolve every dartclaw-* skill the shipped workflow YAMLs reference.
    // Without this, plan-and-implement / spec-and-implement / code-review would
    // be silently excluded from the registry as unresolved skill refs.
    final skillRegistry = result.skillRegistry;
    for (final name in _shippedDartclawSkillRefs) {
      expect(
        skillRegistry.getByName(name),
        isNotNull,
        reason: '$name must resolve through the registry after native user-tier provisioning',
      );
      expect(skillRegistry.validateRef(name), isNull, reason: '$name validateRef should pass');
    }
    expect(skillRegistry.getByName('dartclaw-prd'), isNotNull);
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

/// AndThen-derived `dartclaw-*` skills referenced by the shipped workflow
/// definitions (`plan-and-implement.yaml`, `spec-and-implement.yaml`,
/// `code-review.yaml`). Kept in sync with
/// `rg "skill: dartclaw-" packages/dartclaw_workflow/lib/src/workflow/definitions/`
/// minus the DC-native `dartclaw-discover-project`. Add to this list when a
/// shipped YAML adds a new `skill: dartclaw-*` ref.
const _shippedDartclawSkillRefs = <String>[
  'dartclaw-prd',
  'dartclaw-spec',
  'dartclaw-plan',
  'dartclaw-exec-spec',
  'dartclaw-architecture',
  'dartclaw-review',
  'dartclaw-quick-review',
  'dartclaw-remediate-findings',
  'dartclaw-refactor',
];

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code)');
}

DartclawConfig _baseConfig(String dataDir) {
  return DartclawConfig(
    agent: const AgentConfig(provider: 'claude'),
    credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'k')}),
    providers: ProvidersConfig(
      entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
    ),
    gateway: const GatewayConfig(authMode: 'none'),
    andthen: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
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

void _seedAndthenSrc(String dataDir) {
  final src = Directory(p.join(dataDir, 'andthen-src'))..createSync(recursive: true);
  Directory(p.join(src.path, '.git')).createSync(recursive: true);
  File(p.join(src.path, 'scripts', 'install-skills.sh')).createSync(recursive: true);
}

class _FakeProcessRunner {
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    if (executable == 'git' && arguments.contains('rev-parse')) {
      return ProcessResult(0, 0, 'fake-head\n', '');
    }
    if (executable.endsWith('install-skills.sh')) {
      String? skillsDir;
      String? claudeSkillsDir;
      String? claudeAgentsDir;
      final userDefaults = arguments.contains('--claude-user');
      for (var i = 0; i < arguments.length - 1; i++) {
        switch (arguments[i]) {
          case '--skills-dir':
            skillsDir = arguments[i + 1];
          case '--claude-skills-dir':
            claudeSkillsDir = arguments[i + 1];
          case '--claude-agents-dir':
            claudeAgentsDir = arguments[i + 1];
        }
      }
      if (userDefaults) {
        final home = environment?['HOME'];
        if (home == null || home.isEmpty) {
          throw StateError('fake installer requires HOME for --claude-user');
        }
        skillsDir ??= p.join(home, '.agents', 'skills');
        claudeSkillsDir ??= p.join(home, '.claude', 'skills');
        claudeAgentsDir ??= p.join(home, '.claude', 'agents');
      }
      for (final dir in [skillsDir, claudeSkillsDir, claudeAgentsDir].whereType<String>()) {
        Directory(dir).createSync(recursive: true);
      }
      for (final dir in [skillsDir, claudeSkillsDir].whereType<String>()) {
        for (final name in _fakeInstalledSkills) {
          File(p.join(dir, name, 'SKILL.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync('---\nname: $name\ndescription: $name (fake)\n---\n# $name\n');
        }
      }
      return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(0, 0, '', '');
  }
}

/// Skills the fake installer stages. Identical to [_shippedDartclawSkillRefs]
/// (which already contains the canary `dartclaw-prd`), so the workflow-registry
/// assertion in the positive bootstrap test catches a future YAML adding a
/// `skill: dartclaw-<X>` that no one updated [_shippedDartclawSkillRefs] for —
/// the missing skill won't get staged and the assertion will fail.
const _fakeInstalledSkills = _shippedDartclawSkillRefs;
