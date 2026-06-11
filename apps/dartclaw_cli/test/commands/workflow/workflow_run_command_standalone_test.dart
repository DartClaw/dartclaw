import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_run_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';
import '../../helpers/fake_exit.dart';

HarnessFactory _harnessFactoryFor(AgentHarness Function() builder) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => builder());
  return factory;
}

HarnessFactory _harnessFactoryForProviders(Iterable<String> providers, AgentHarness Function() builder) {
  final factory = HarnessFactory();
  for (final provider in providers) {
    factory.register(provider, (_) => builder());
  }
  return factory;
}

void main() {
  group('WorkflowRunCommand standalone mode', () {
    late Directory tempDir;
    late DartclawConfig config;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dartclaw_workflow_run_standalone_test_');
      config = DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      );

      final workflowsDir = Directory(p.join(config.server.dataDir, 'workflows', 'custom'))..createSync(recursive: true);
      File(p.join(workflowsDir.path, 'ci-demo.yaml')).writeAsStringSync('''
name: ci-demo
description: Demo standalone workflow
steps:
  - id: shell-check
    name: Shell Check
    type: bash
    prompt: |
      printf 'standalone-ok\\n'
''');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('standalone json mode emits structured events and exits 0', () async {
      final output = <String>[];
      final command = WorkflowRunCommand(
        config: config,
        harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stdoutLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
        runAndthenSkillsBootstrap: false,
        skillIntrospector: FakeSkillIntrospector({}),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'ci-demo', '--standalone', '--json']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output.first, contains('"type":"run_started"'));
      expect(output.any((line) => line.contains('"type":"workflow_step_completed"')), isTrue);
      expect(output.last, contains('"type":"workflow_status_changed"'));
      expect(output.last, contains('"newStatus":"completed"'));
    });

    test('standalone run with no config exits with init workflow guidance', () async {
      final output = <String>[];
      final command = WorkflowRunCommand(environment: {'HOME': tempDir.path}, stderrLine: output.add, exitFn: fakeExit);
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'code-review', '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(output.single, contains('No config found at ${p.join(tempDir.path, '.dartclaw', 'dartclaw.yaml')}'));
      expect(output.single, contains('dartclaw init --workflow'));
    });

    test('standalone run aborts early when a referenced credential resolves empty', () async {
      config = DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
        credentials: const CredentialsConfig(entries: {'github-main': CredentialEntry.githubToken(token: '')}),
        projects: const ProjectConfig(
          definitions: {
            'workflow-testing': ProjectDefinition(
              id: 'workflow-testing',
              remote: 'git@github.com:tolo/dartclaw-workflow-testing.git',
              credentials: 'github-main',
            ),
          },
        ),
      );
      final output = <String>[];
      final command = WorkflowRunCommand(
        config: config,
        apiClient: DartclawApiClient(
          baseUri: Uri.parse('http://localhost:3333'),
          transport: FakeApiTransport(sendResponses: [_response(503)]),
        ),
        environment: const {},
        harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stderrLine: output.add,
        exitFn: fakeExit,
        runAndthenSkillsBootstrap: false,
        skillIntrospector: FakeSkillIntrospector({}),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'ci-demo', '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(output, [
        'Credential preflight failed: project "workflow-testing" references credential "github-main" '
            'but env var GITHUB_TOKEN is unset or empty',
      ]);
    });

    test('no-skill-bootstrap rejects source-only skill metadata', () async {
      final workflowsDir = Directory(p.join(config.server.dataDir, 'workflows', 'custom'));
      File(p.join(workflowsDir.path, 'source-only-skill.yaml')).writeAsStringSync('''
name: source-only-skill
description: Workflow that references a built-in skill without native install
steps:
  - id: discover
    name: Discover
    skill: dartclaw-discover-andthen-spec
''');

      final output = <String>[];
      final command = WorkflowRunCommand(
        config: config,
        environment: {'HOME': p.join(tempDir.path, 'empty-home')},
        harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stdoutLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
        skillIntrospector: FakeSkillIntrospector({}),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'source-only-skill', '--standalone', '--no-skill-bootstrap']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(output, [
        '[workflow] Starting: source-only-skill (1 steps)',
        '[workflow] Failed at step 1/1: Missing skills for provider "claude": '
            'dartclaw-discover-andthen-spec. Available: 0 skills.',
      ]);
    });

    test('no-skill-bootstrap rejects skill missing from the effective provider root', () async {
      config = DartclawConfig(
        agent: const AgentConfig(provider: 'codex'),
        providers: const ProvidersConfig(entries: {'codex': ProviderEntry(executable: 'codex', poolSize: 0)}),
        server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      );
      final fakeHome = p.join(tempDir.path, 'claude-only-home');
      _writeSkill(p.join(fakeHome, '.claude', 'skills'), 'dartclaw-discover-andthen-spec');
      final workflowsDir = Directory(p.join(config.server.dataDir, 'workflows', 'custom'))..createSync(recursive: true);
      File(p.join(workflowsDir.path, 'provider-mismatch.yaml')).writeAsStringSync('''
name: provider-mismatch
description: Workflow whose default provider cannot load the referenced skill
steps:
  - id: discover
    name: Discover
    skill: dartclaw-discover-andthen-spec
''');

      final output = <String>[];
      final command = WorkflowRunCommand(
        config: config,
        environment: {'HOME': fakeHome},
        harnessFactory: _harnessFactoryForProviders(['codex', 'claude'], () => FakeAgentHarness()),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stdoutLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
        skillIntrospector: FakeSkillIntrospector({
          'claude': {'dartclaw-discover-andthen-spec'},
          'codex': {},
        }),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'provider-mismatch', '--standalone', '--no-skill-bootstrap']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(output, [
        '[workflow] Starting: provider-mismatch (1 steps)',
        '[workflow] Failed at step 1/1: Missing skills for provider "codex": '
            'dartclaw-discover-andthen-spec. Available: 0 skills.',
      ]);
    });

    test('suppresses --no-skill-bootstrap hint when a different reason was already surfaced', () async {
      // ci-demo fails validation (parallel approval) – not a skill issue.
      // The --no-skill-bootstrap hint would mislead by telling the operator
      // to fix skill provisioning, so it must not print when an exclusion
      // reason has already been shown.
      final workflowsDir = Directory(p.join(config.server.dataDir, 'workflows', 'custom'));
      File(p.join(workflowsDir.path, 'ci-demo.yaml')).writeAsStringSync('''
name: ci-demo
description: Excluded by validation, not by skills.
steps:
  - id: gate
    name: Gate
    type: approval
    parallel: true
''');

      final output = <String>[];
      final command = WorkflowRunCommand(
        config: config,
        environment: {'HOME': p.join(tempDir.path, 'empty-home')},
        harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stderrLine: output.add,
        exitFn: fakeExit,
        skillIntrospector: FakeSkillIntrospector({}),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'ci-demo', '--standalone', '--no-skill-bootstrap']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(output.any((line) => line.contains('was excluded at load time')), isTrue);
      expect(
        output.every((line) => !line.contains('--no-skill-bootstrap was set')),
        isTrue,
        reason: 'Skill-bootstrap hint must not appear when an exclusion reason is already surfaced',
      );
    });

    test('matches a parse-failure exclusion to the requested name by filename basename', () async {
      // YAML fails to parse → exclusion has workflowName == null. The
      // operator types `mybroken` (matching the filename basename); the CLI
      // should surface the parse error rather than printing "Unknown workflow:".
      final workflowsDir = Directory(p.join(config.server.dataDir, 'workflows', 'custom'));
      File(p.join(workflowsDir.path, 'mybroken.yaml')).writeAsStringSync('name: : broken syntax {{{');

      final output = <String>[];
      final command = WorkflowRunCommand(
        config: config,
        harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stderrLine: output.add,
        exitFn: fakeExit,
        runAndthenSkillsBootstrap: false,
        skillIntrospector: FakeSkillIntrospector({}),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'mybroken', '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(output.any((line) => line.contains('"mybroken" was excluded at load time')), isTrue);
      expect(output.any((line) => line.contains('mybroken.yaml')), isTrue);
      expect(output.every((line) => !line.startsWith('Unknown workflow:')), isTrue);
    });

    test('surfaces other-name exclusions even when some workflows did load', () async {
      // ci-demo loads cleanly. A sibling YAML fails to parse – when the
      // operator types a different unknown name, the CLI should still mention
      // the failed sibling so the operator can see partial registry damage.
      final workflowsDir = Directory(p.join(config.server.dataDir, 'workflows', 'custom'));
      File(p.join(workflowsDir.path, 'broken-sibling.yaml')).writeAsStringSync('name: : broken syntax {{{');

      final output = <String>[];
      final command = WorkflowRunCommand(
        config: config,
        harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stderrLine: output.add,
        exitFn: fakeExit,
        runAndthenSkillsBootstrap: false,
        skillIntrospector: FakeSkillIntrospector({}),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'definitely-unknown', '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      final renderedOutput = output.join('\n');
      expect(output.any((line) => line.startsWith('Unknown workflow:')), isTrue, reason: renderedOutput);
      expect(
        output.any((line) => line.startsWith('Available:') && line.contains('ci-demo')),
        isTrue,
        reason: renderedOutput,
      );
      expect(output.any((line) => line.contains('Other workflows excluded')), isTrue, reason: renderedOutput);
      expect(output.any((line) => line.contains('broken-sibling')), isTrue, reason: renderedOutput);
    });

    test('surfaces validation errors when a requested workflow was excluded at load time', () async {
      // Replace the default ci-demo with one that fails validation (approval
      // step marked parallel – caught by validation, not parsing).
      final workflowsDir = Directory(p.join(config.server.dataDir, 'workflows', 'custom'));
      File(p.join(workflowsDir.path, 'ci-demo.yaml')).writeAsStringSync('''
name: ci-demo
description: Excluded by validation.
steps:
  - id: gate
    name: Gate
    type: approval
    parallel: true
''');

      final output = <String>[];
      final command = WorkflowRunCommand(
        config: config,
        harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stderrLine: output.add,
        exitFn: fakeExit,
        runAndthenSkillsBootstrap: false,
        skillIntrospector: FakeSkillIntrospector({}),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'ci-demo', '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(output.any((line) => line.contains('was excluded at load time')), isTrue);
      expect(output.any((line) => line.contains('ci-demo.yaml')), isTrue);
      expect(output.every((line) => !line.startsWith('Unknown workflow:')), isTrue);
    });

    test('standalone run provisions explicit provider runners and CLI configs before starting the workflow', () async {
      config = DartclawConfig(
        agent: const AgentConfig(provider: 'codex'),
        providers: const ProvidersConfig(entries: {'codex': ProviderEntry(executable: 'codex', poolSize: 0)}),
        server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      );
      final workflowsDir = Directory(p.join(config.server.dataDir, 'workflows', 'custom'))..createSync(recursive: true);
      File(p.join(workflowsDir.path, 'agent-demo.yaml')).writeAsStringSync('''
name: agent-demo
description: Demo standalone agent workflow
steps:
  - id: review
    name: Review
    type: analysis
    provider: claude
    prompt: |
      Inspect the repo and say ok.
''');

      final createdHarnesses = <String, List<FakeAgentHarness>>{};
      final factory = HarnessFactory()
        ..register('claude', (_) {
          final harness = FakeAgentHarness();
          createdHarnesses.putIfAbsent('claude', () => <FakeAgentHarness>[]).add(harness);
          return harness;
        })
        ..register('codex', (_) {
          final harness = FakeAgentHarness();
          createdHarnesses.putIfAbsent('codex', () => <FakeAgentHarness>[]).add(harness);
          return harness;
        });
      final wiring = CliWorkflowWiring(
        config: config,
        dataDir: config.server.dataDir,
        runAndthenSkillsBootstrap: false,
        harnessFactory: factory,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
      );
      await wiring.wire();
      addTearDown(wiring.dispose);

      expect(wiring.pool.hasTaskRunnerForProvider('claude'), isFalse);
      expect(wiring.workflowCliRunner.providers.containsKey('claude'), isFalse);

      await wiring.ensureTaskRunnersForProviders({'claude'});

      expect(wiring.pool.hasTaskRunnerForProvider('claude'), isTrue);
      expect(wiring.workflowCliRunner.providers.containsKey('claude'), isTrue);
      expect(createdHarnesses['claude'], isNotEmpty);
    });
  });
}

ApiResponse _response(int statusCode, [Object? body]) {
  return ApiResponse(
    statusCode: statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
    body: Stream.value(utf8.encode(body == null ? '{}' : jsonEncode(body))),
  );
}

void _writeSkill(String root, String name) {
  final dir = Directory(p.join(root, name))..createSync(recursive: true);
  File(p.join(dir.path, 'SKILL.md')).writeAsStringSync('---\nname: $name\n---\n\n# $name\n');
}
