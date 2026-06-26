import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
import 'package:dartclaw_cli/src/commands/workflow/standalone_lifecycle_support.dart' show requiredWorkflowProviders;
import 'package:dartclaw_cli/src/commands/workflow/workflow_run_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show MergeResolveConfig, WorkflowDefinition, WorkflowGitStrategy, WorkflowStep, WorkflowTaskType;
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

/// A [FakeAgentHarness] whose [start] throws — stands in for a logged-out
/// provider whose real harness would throw a `StateError` from `_verifyAuth`.
/// [start] records the attempt before throwing, so a test can assert it was
/// never reached (the auth preflight aborts first).
class _ThrowOnStartHarness extends FakeAgentHarness {
  @override
  Future<void> start() async {
    await super.start();
    throw StateError('harness start blew up (logged-out provider)');
  }
}

class _AutoCompletingHarness extends FakeAgentHarness {
  @override
  bool get supportsSessionContinuity => true;

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) {
    final result = super.turn(
      sessionId: sessionId,
      messages: messages,
      systemPrompt: systemPrompt,
      mcpServers: mcpServers,
      resume: resume,
      directory: directory,
      model: model,
      effort: effort,
      maxTurns: maxTurns,
    );
    Future<void>.microtask(() {
      emit(DeltaEvent('<step-outcome>{"outcome":"succeeded","reason":"test completed"}</step-outcome>'));
      completeSuccess({'stop_reason': 'completed'});
    });
    return result;
  }
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
        providerAuthPreflight: FakeProviderAuthPreflight(),
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

    test('standalone --inline overrides an integration-branch git strategy to inline (S01)', () async {
      final workflowsDir = Directory(p.join(config.server.dataDir, 'workflows', 'custom'));
      File(p.join(workflowsDir.path, 'ci-demo.yaml')).writeAsStringSync('''
name: ci-demo
description: Demo workflow authored with an integration-branch git strategy
gitStrategy:
  integrationBranch: true
  worktree: shared
steps:
  - id: shell-check
    name: Shell Check
    type: bash
    prompt: |
      printf 'standalone-ok\\n'
''');

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
        providerAuthPreflight: FakeProviderAuthPreflight(),
        skillIntrospector: FakeSkillIntrospector({}),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'ci-demo', '--standalone', '--inline', '--json']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      final gitStrategy = _runStartedGitStrategy(output);
      expect(gitStrategy['integrationBranch'], isFalse);
      expect(gitStrategy['worktree'], equals('inline'));
    });

    test('standalone run without --inline keeps the authored git strategy (S04 regression)', () async {
      final workflowsDir = Directory(p.join(config.server.dataDir, 'workflows', 'custom'));
      File(p.join(workflowsDir.path, 'ci-demo.yaml')).writeAsStringSync('''
name: ci-demo
description: Demo workflow authored with an integration-branch git strategy
gitStrategy:
  integrationBranch: true
  worktree: shared
steps:
  - id: shell-check
    name: Shell Check
    type: bash
    prompt: |
      printf 'standalone-ok\\n'
''');

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
        providerAuthPreflight: FakeProviderAuthPreflight(),
        skillIntrospector: FakeSkillIntrospector({}),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'ci-demo', '--standalone', '--json']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      final gitStrategy = _runStartedGitStrategy(output);
      expect(gitStrategy['integrationBranch'], isTrue);
      expect(gitStrategy['worktree'], equals('shared'));
    });

    test('standalone run with no config exits with init workflow guidance', () async {
      final output = <String>[];
      final command = WorkflowRunCommand(environment: {'HOME': tempDir.path}, stderrLine: output.add, exitFn: fakeExit);
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);
      final savedCwd = Directory.current;

      try {
        Directory.current = tempDir;
        await expectLater(
          () => runner.run(['run', 'code-review', '--standalone']),
          throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
        );
      } finally {
        Directory.current = savedCwd;
      }

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
        providerAuthPreflight: FakeProviderAuthPreflight(),
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
        providerAuthPreflight: FakeProviderAuthPreflight(),
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
        providerAuthPreflight: FakeProviderAuthPreflight(),
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
        providerAuthPreflight: FakeProviderAuthPreflight(),
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
        providerAuthPreflight: FakeProviderAuthPreflight(),
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
        providerAuthPreflight: FakeProviderAuthPreflight(),
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
        providerAuthPreflight: FakeProviderAuthPreflight(),
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

    test('S01 logged-out referenced provider aborts before any harness starts', () async {
      // ci-demo's bash step resolves to the default provider 'claude', which the
      // injected preflight reports unauthenticated. The harness start() throws,
      // so reaching it would surface a StateError instead of the friendly path.
      final created = <_ThrowOnStartHarness>[];
      final factory = HarnessFactory()
        ..register('claude', (_) {
          final harness = _ThrowOnStartHarness();
          created.add(harness);
          return harness;
        });

      final output = <String>[];
      final command = WorkflowRunCommand(
        config: config,
        harnessFactory: factory,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stdoutLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
        runAndthenSkillsBootstrap: false,
        providerAuthPreflight: FakeProviderAuthPreflight(unauthenticated: {'claude'}),
        skillIntrospector: FakeSkillIntrospector({}),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'ci-demo', '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(
        output.any((line) => line.contains('claude') && line.contains('not authenticated')),
        isTrue,
        reason: 'provider-named remediation expected: $output',
      );
      expect(created.every((harness) => !harness.startCalled), isTrue, reason: 'no harness.start() reached');
      expect(output.every((line) => !line.contains('standalone-ok')), isTrue, reason: 'no workflow step ran');
    });

    test('S02 unreferenced logged-out default provider does not block a single-provider run', () async {
      // Default provider claude is unauthenticated and its start() throws, but
      // only the agent-backed step resolves to codex. The unpinned bash
      // scaffold must not cause claude to be probed or started.
      config = DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        providers: const ProvidersConfig(entries: {'codex': ProviderEntry(executable: 'codex', poolSize: 1)}),
        server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      );
      final workflowsDir = Directory(p.join(config.server.dataDir, 'workflows', 'custom'))..createSync(recursive: true);
      File(p.join(workflowsDir.path, 'codex-only.yaml')).writeAsStringSync('''
name: codex-only
description: Bash scaffold plus a codex agent step
steps:
  - id: shell-check
    name: Shell Check
    type: bash
    provider: codex
    prompt: |
      printf 'standalone-ok\\n'
  - id: agent-check
    name: Agent Check
    provider: codex
    prompt: Say OK
''');

      final claudeHarnesses = <_ThrowOnStartHarness>[];
      final factory = HarnessFactory()
        ..register('claude', (_) {
          final harness = _ThrowOnStartHarness();
          claudeHarnesses.add(harness);
          return harness;
        })
        ..register('codex', (_) => _AutoCompletingHarness());
      final preflight = FakeProviderAuthPreflight(unauthenticated: {'claude'});

      final output = <String>[];
      final command = WorkflowRunCommand(
        config: config,
        harnessFactory: factory,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stdoutLine: output.add,
        stderrLine: output.add,
        exitFn: fakeExit,
        runAndthenSkillsBootstrap: false,
        providerAuthPreflight: preflight,
        skillIntrospector: FakeSkillIntrospector({}),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(() => runner.run(['run', 'codex-only', '--standalone']), throwsA(isA<FakeExit>()));

      expect(preflight.probed, contains('codex'));
      expect(preflight.probed, isNot(contains('claude')), reason: 'unreferenced default must not be probed');
      expect(claudeHarnesses.every((harness) => !harness.startCalled), isTrue, reason: 'claude.start() never called');
      expect(
        output.any((line) => line.contains('agent-check') && line.contains('running (codex)')),
        isTrue,
        reason: 'codex agent path reached; output=$output probed=${preflight.probed}',
      );
    });

    test('S02 provider derivation reuses continueSession root provider instead of default provider', () {
      config = DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        providers: const ProvidersConfig(entries: {'codex': ProviderEntry(executable: 'codex', poolSize: 1)}),
        server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      );
      final definition = WorkflowDefinition(
        name: 'codex-continue',
        description: 'Continued codex session with an unpinned continuation step',
        steps: const [
          WorkflowStep(id: 'root', name: 'Root', provider: 'codex', prompts: ['Start']),
          WorkflowStep(id: 'follow-up', name: 'Follow Up', continueSession: '@previous', prompts: ['Continue']),
        ],
      );

      expect(requiredWorkflowProviders(definition, config), {'codex'});
    });

    // Parallel foreach materializes a synthetic merge-resolve step on the workflow
    // default provider, so derivation must include it alongside the declared step
    // providers; serial foreach materializes nothing extra.
    test('C-01 provider derivation includes synthetic merge-resolve default provider', () {
      config = _providerDerivationConfig(tempDir.path);
      expect(requiredWorkflowProviders(_mergeResolveDefinition(maxParallel: 2), config), {'claude', 'codex'});
    });

    test('C-01 provider derivation excludes synthetic merge-resolve provider for serial foreach', () {
      config = _providerDerivationConfig(tempDir.path);
      expect(requiredWorkflowProviders(_mergeResolveDefinition(), config), {'claude'});
    });

    test('S03 authenticated standalone run is behavior-unchanged (no added auth output)', () async {
      // Mirrors the happy-path json-mode test but asserts the auth preflight
      // adds no stdout/stderr noise and the exit code is unchanged.
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
        providerAuthPreflight: FakeProviderAuthPreflight(),
        skillIntrospector: FakeSkillIntrospector({}),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'ci-demo', '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output.any((line) => line.contains('[workflow] Completed')), isTrue, reason: '$output');
      expect(
        output.every((line) => !line.contains('not authenticated')),
        isTrue,
        reason: 'no auth output on happy path',
      );
    });
  });
}

/// Extracts the effective workflow `gitStrategy` from the standalone JSON
/// `run_started` event. The event carries the run's `definitionJson`, which
/// reflects any inline override applied inside `WorkflowService.start`.
Map<String, dynamic> _runStartedGitStrategy(List<String> output) {
  final started = output
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .firstWhere((event) => event['type'] == 'run_started');
  final run = started['run'] as Map<String, dynamic>;
  final definitionJson = run['definitionJson'] as Map<String, dynamic>;
  return definitionJson['gitStrategy'] as Map<String, dynamic>;
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

DartclawConfig _providerDerivationConfig(String dataDir) => DartclawConfig(
  agent: const AgentConfig(provider: 'codex'),
  providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1)}),
  server: ServerConfig(dataDir: dataDir, claudeExecutable: Platform.resolvedExecutable),
);

/// Foreach workflow whose merge-resolve materializes a synthetic step on the
/// default provider when [maxParallel] > 1 (parallel) and not when it is null
/// (serial) — the distinction `requiredWorkflowProviders` must honor (C-01).
WorkflowDefinition _mergeResolveDefinition({Object? maxParallel}) => WorkflowDefinition(
  name: 'merge-resolve-provider-derivation',
  description: 'Synthetic merge resolve provider derivation',
  project: 'demo',
  gitStrategy: const WorkflowGitStrategy(mergeResolve: MergeResolveConfig(enabled: true)),
  steps: [
    WorkflowStep(
      id: 'stories',
      name: 'Stories',
      taskType: WorkflowTaskType.foreach,
      mapOver: 'stories',
      foreachSteps: const ['implement'],
      maxParallel: maxParallel,
    ),
    const WorkflowStep(id: 'implement', name: 'Implement', provider: 'claude', prompts: ['Build']),
  ],
);
