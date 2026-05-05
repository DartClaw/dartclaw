import 'dart:async';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_git_support.dart'
    show restoreCheckoutBeforeWorkflowBranchDeletion;
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart' show AssetResolver;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

HarnessFactory _harnessFactoryFor(AgentHarness Function() builder) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => builder());
  return factory;
}

void _runGit(String workingDirectory, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed in $workingDirectory: ${result.stderr}');
  }
}

void _writeSkill(String skillsRoot, String name) {
  final skillDir = Directory(p.join(skillsRoot, name))..createSync(recursive: true);
  File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync('---\nname: $name\n---\n\n# $name\n');
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

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_cli_workflow_wiring_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('loads built-in skills from source tree without materializing project copies', () async {
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      projects: const ProjectConfig(
        definitions: {
          'alpha': ProjectDefinition(id: 'alpha', remote: 'file:///tmp/alpha.git'),
          'beta': ProjectDefinition(id: 'beta', remote: 'file:///tmp/beta.git'),
        },
      ),
    );

    for (final projectId in ['alpha', 'beta']) {
      Directory(p.join(tempDir.path, 'projects', projectId)).createSync(recursive: true);
    }

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: tempDir.path,
      runAndthenSkillsBootstrap: false,
      environment: {'HOME': p.join(tempDir.path, 'fake-home')},
      harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
    );
    addTearDown(wiring.dispose);

    await wiring.wire();

    expect(wiring.skillRegistry.getByName('dartclaw-discover-project'), isNotNull);

    for (final projectId in ['alpha', 'beta']) {
      final projectSkillDir = p.join(
        tempDir.path,
        'projects',
        projectId,
        '.claude',
        'skills',
        'dartclaw-discover-project',
      );
      expect(Directory(projectSkillDir).existsSync(), isFalse);
    }
  });

  test('excludes custom workflows that reference missing skills', () async {
    final workspaceWorkflowsDir = Directory(p.join(tempDir.path, 'workflows', 'definitions'))
      ..createSync(recursive: true);
    File(p.join(workspaceWorkflowsDir.path, 'invalid.yaml')).writeAsStringSync('''
name: invalid-missing-skill
description: Should be rejected
steps:
  - id: review
    name: Review
    type: analysis
    skill: missing-skill
''');

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
    );

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: tempDir.path,
      runAndthenSkillsBootstrap: false,
      environment: {'HOME': p.join(tempDir.path, 'fake-home')},
      harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
    );
    addTearDown(wiring.dispose);

    await wiring.wire();

    expect(wiring.registry.getByName('invalid-missing-skill'), isNull);
  });

  test('loads per-project workflows from configured localPath directories', () async {
    final projectDir = Directory(p.join(tempDir.path, 'live-project'))..createSync(recursive: true);
    final workflowsDir = Directory(p.join(projectDir.path, 'workflows'))..createSync(recursive: true);
    File(p.join(workflowsDir.path, 'local-only.yaml')).writeAsStringSync('''
name: local-only
description: Loaded from a localPath project
steps:
  - id: check
    name: Check
    type: agent
    prompt: |
      Say OK.
''');

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path)},
      ),
    );

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: tempDir.path,
      runAndthenSkillsBootstrap: false,
      environment: {'HOME': p.join(tempDir.path, 'fake-home')},
      harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
    );
    addTearDown(wiring.dispose);

    await wiring.wire();

    expect(wiring.registry.getByName('local-only'), isNotNull);
  });

  test('workflow start rejects local-path branch mismatch even when BRANCH matches the observed branch', () async {
    final projectDir = Directory(p.join(tempDir.path, 'live-project'))..createSync(recursive: true);
    _runGit(projectDir.path, ['init', '-b', 'main']);
    _runGit(projectDir.path, ['config', 'user.name', 'Test User']);
    _runGit(projectDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('hello\n');
    _runGit(projectDir.path, ['add', 'README.md']);
    _runGit(projectDir.path, ['commit', '-m', 'initial']);
    _runGit(projectDir.path, ['checkout', '-b', 'feature/local']);

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path, branch: 'main')},
      ),
    );

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: tempDir.path,
      runAndthenSkillsBootstrap: false,
      environment: {'HOME': p.join(tempDir.path, 'fake-home')},
      harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
    );
    addTearDown(wiring.dispose);

    await wiring.wire();

    final definition = WorkflowDefinition(
      name: 'branch-guard',
      description: 'Checks local-path branch safety',
      variables: const {
        'PROJECT': WorkflowVariable(required: true, description: 'Target project'),
        'BRANCH': WorkflowVariable(required: false, description: 'Requested branch'),
      },
      steps: const [
        WorkflowStep(id: 'check', name: 'Check', type: 'analysis', prompts: ['Say OK']),
      ],
    );

    await expectLater(
      () => wiring.workflowService.start(definition, const {
        'PROJECT': 'alpha',
        'BRANCH': 'feature/local',
      }, headless: true),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf([contains('feature/local'), contains('expected "main"')]),
        ),
      ),
    );
  });

  test('workflow start infers BRANCH from HEAD for local-path projects when branch is omitted', () async {
    final projectDir = Directory(p.join(tempDir.path, 'live-project'))..createSync(recursive: true);
    _runGit(projectDir.path, ['init', '-b', 'main']);
    _runGit(projectDir.path, ['config', 'user.name', 'Test User']);
    _runGit(projectDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('hello\n');
    _runGit(projectDir.path, ['add', 'README.md']);
    _runGit(projectDir.path, ['commit', '-m', 'initial']);
    _runGit(projectDir.path, ['checkout', '-b', 'feature/local']);

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path, branch: '')},
      ),
    );

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: tempDir.path,
      runAndthenSkillsBootstrap: false,
      environment: {'HOME': p.join(tempDir.path, 'fake-home')},
      harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
    );
    addTearDown(wiring.dispose);

    await wiring.wire();

    final definition = WorkflowDefinition(
      name: 'branch-guard',
      description: 'Checks local-path branch safety',
      variables: const {
        'PROJECT': WorkflowVariable(required: true, description: 'Target project'),
        'BRANCH': WorkflowVariable(required: false, description: 'Requested branch'),
      },
      steps: const [
        WorkflowStep(id: 'check', name: 'Check', type: 'analysis', prompts: ['Say OK']),
      ],
    );

    final run = await wiring.workflowService.start(definition, const {'PROJECT': 'alpha'}, headless: true);
    expect(run.variablesJson['BRANCH'], 'feature/local');
  });

  test('workflow start propagates the configured workflow workspace into created tasks', () async {
    final workflowWorkspaceDir = Directory(p.join(tempDir.path, 'workflow-workspace'))..createSync(recursive: true);
    File(p.join(workflowWorkspaceDir.path, 'AGENTS.md')).writeAsStringSync('CLI workflow workspace rules');

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      workflow: WorkflowConfig(workspaceDir: workflowWorkspaceDir.path),
    );

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: tempDir.path,
      runAndthenSkillsBootstrap: false,
      environment: {'HOME': p.join(tempDir.path, 'fake-home')},
      harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
    );
    addTearDown(wiring.dispose);

    await wiring.wire();

    final definition = WorkflowDefinition(
      name: 'two-prompt-review',
      description: 'Two prompts in one step',
      steps: const [
        WorkflowStep(
          id: 'review',
          name: 'Review',
          type: 'analysis',
          skill: 'dartclaw-review',
          prompts: ['Inspect the change set.', 'Re-check the follow-up output.'],
        ),
      ],
    );

    Task? createdTask;
    final sub = wiring.eventBus
        .on<TaskStatusChangedEvent>()
        .where((event) => event.newStatus == TaskStatus.queued)
        .listen((event) async {
          createdTask = await wiring.taskService.get(event.taskId);
        });

    final run = await wiring.workflowService.start(definition, const {}, headless: true);
    await _waitFor(() => createdTask != null);
    await sub.cancel();

    expect(createdTask?.agentExecution?.workspaceDir, workflowWorkspaceDir.path);
    await wiring.workflowService.cancel(run.id);
  });

  test('injects provider credentials into standalone harness environments', () async {
    final capturedByProvider = <String, List<HarnessFactoryConfig>>{};
    final factory = HarnessFactory()
      ..register('codex', (config) {
        capturedByProvider.putIfAbsent('codex', () => <HarnessFactoryConfig>[]).add(config);
        return FakeAgentHarness();
      })
      ..register('claude', (config) {
        capturedByProvider.putIfAbsent('claude', () => <HarnessFactoryConfig>[]).add(config);
        return FakeAgentHarness();
      });

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'codex'),
      providers: const ProvidersConfig(entries: {'codex': ProviderEntry(executable: 'codex', poolSize: 0)}),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
          'openai': CredentialEntry(apiKey: 'openai-key'),
        },
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
    );

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: tempDir.path,
      runAndthenSkillsBootstrap: false,
      environment: {'HOME': p.join(tempDir.path, 'fake-home')},
      harnessFactory: factory,
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
    );
    addTearDown(wiring.dispose);

    await wiring.wire();
    await wiring.ensureTaskRunnersForProviders({'claude'});

    final codexConfigs = capturedByProvider['codex']!;
    expect(codexConfigs, hasLength(2), reason: 'primary harness + default standalone task runner');
    for (final harnessConfig in codexConfigs) {
      expect(harnessConfig.environment['CODEX_API_KEY'], 'openai-key');
      expect(harnessConfig.environment['OPENAI_API_KEY'], 'openai-key');
    }

    final claudeConfigs = capturedByProvider['claude']!;
    expect(claudeConfigs, hasLength(1));
    expect(claudeConfigs.single.environment['ANTHROPIC_API_KEY'], 'anthropic-key');
  });

  test('defaults standalone harness cwd to the process cwd when runtime cwd is omitted', () async {
    final launchDir = Directory(p.join(tempDir.path, 'launch-repo'))..createSync(recursive: true);
    final captured = <HarnessFactoryConfig>[];
    final factory = HarnessFactory()
      ..register('claude', (config) {
        captured.add(config);
        return FakeAgentHarness();
      });

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
    );

    final savedCwd = Directory.current;
    Directory.current = launchDir;
    CliWorkflowWiring? wiring;
    try {
      wiring = CliWorkflowWiring(
        config: config,
        dataDir: tempDir.path,
        runAndthenSkillsBootstrap: false,
        environment: {'HOME': p.join(tempDir.path, 'fake-home')},
        harnessFactory: factory,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
      );
      await wiring.wire();
    } finally {
      Directory.current = savedCwd;
      if (wiring != null) {
        await wiring.dispose();
      }
    }

    expect(captured.map((config) => config.cwd).toSet(), {launchDir.resolveSymbolicLinksSync()});
  });

  test('uses injected runtime cwd for primary and task-runner harnesses', () async {
    final launchDir = Directory(p.join(tempDir.path, 'launch-repo'))..createSync(recursive: true);
    final runtimeCwd = Directory(p.join(tempDir.path, 'runtime-cwd'))..createSync(recursive: true);
    final capturedByProvider = <String, List<HarnessFactoryConfig>>{};
    final factory = HarnessFactory()
      ..register('codex', (config) {
        capturedByProvider.putIfAbsent('codex', () => <HarnessFactoryConfig>[]).add(config);
        return FakeAgentHarness();
      })
      ..register('claude', (config) {
        capturedByProvider.putIfAbsent('claude', () => <HarnessFactoryConfig>[]).add(config);
        return FakeAgentHarness();
      });

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'codex'),
      providers: const ProvidersConfig(
        entries: {
          'codex': ProviderEntry(executable: 'codex', poolSize: 2),
          'claude': ProviderEntry(executable: 'claude', poolSize: 0),
        },
      ),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
          'openai': CredentialEntry(apiKey: 'openai-key'),
        },
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
    );

    final savedCwd = Directory.current;
    Directory.current = launchDir;
    CliWorkflowWiring? wiring;
    try {
      wiring = CliWorkflowWiring(
        config: config,
        dataDir: tempDir.path,
        runAndthenSkillsBootstrap: false,
        environment: {'HOME': p.join(tempDir.path, 'fake-home')},
        runtimeCwd: runtimeCwd.path,
        harnessFactory: factory,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
      );
      await wiring.wire();
      await wiring.ensureTaskRunnersForProviders({'claude'});
    } finally {
      Directory.current = savedCwd;
      if (wiring != null) {
        await wiring.dispose();
      }
    }

    final captured = [
      ...capturedByProvider['codex'] ?? const <HarnessFactoryConfig>[],
      ...capturedByProvider['claude'] ?? const <HarnessFactoryConfig>[],
    ];
    expect(captured, hasLength(4), reason: 'primary, two default task runners, and one added provider runner');
    expect(captured.map((config) => config.cwd).toSet(), {runtimeCwd.path});
  });

  test('discovers dartclaw workflow skills from native user-tier roots', () async {
    final fakeHome = p.join(tempDir.path, 'native-home');
    final userClaudeSkills = p.join(fakeHome, '.claude', 'skills');
    final userAgentsSkills = p.join(fakeHome, '.agents', 'skills');
    for (final name in const ['dartclaw-prd', 'dartclaw-plan']) {
      _writeSkill(userClaudeSkills, name);
      _writeSkill(userAgentsSkills, name);
    }

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
    );

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: tempDir.path,
      runAndthenSkillsBootstrap: false,
      environment: {'HOME': fakeHome},
      harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
    );
    addTearDown(wiring.dispose);

    await wiring.wire();

    for (final name in const ['dartclaw-prd', 'dartclaw-plan']) {
      final skill = wiring.skillRegistry.getByName(name);
      expect(skill, isNotNull);
      expect(skill!.path, startsWith(fakeHome));
      expect(skill.source, SkillSource.userClaude);
      expect(skill.nativeHarnesses, {'claude', 'codex'});
    }
  });

  test('standalone wiring provisions AndThen skills before registering shipped workflows', () async {
    _seedAndthenSrc(p.join(tempDir.path, 'andthen-src'), sha: 'standalone-head');
    final fakeHome = p.join(tempDir.path, 'provision-home');
    final runner = _FakeProvisionerProcessRunner();
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      andthen: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
    );

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: tempDir.path,
      runtimeCwd: tempDir.path,
      harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      skillProvisionerProcessRunner: runner.run,
      environment: {'HOME': fakeHome},
    );
    addTearDown(wiring.dispose);

    await wiring.wire();

    expect(File(p.join(fakeHome, '.agents', 'skills', 'dartclaw-prd', 'SKILL.md')).existsSync(), isTrue);
    for (final name in _shippedDartclawSkillRefs) {
      expect(wiring.skillRegistry.getByName(name), isNotNull, reason: '$name should resolve after provisioning');
      expect(wiring.skillRegistry.validateRef(name), isNull, reason: '$name validateRef should pass');
    }

    final registeredNames = wiring.registry.listAll().map((workflow) => workflow.name).toSet();
    expect(registeredNames, containsAll(['plan-and-implement', 'spec-and-implement', 'code-review']));
    expect(runner.calls.where((call) => call.executable.endsWith('install-skills.sh')), hasLength(1));
  });

  test('dispose cleans up workflow task worktrees in headless mode', () async {
    final repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);
    final workspaceDir = Directory(p.join(tempDir.path, 'workspace'))..createSync(recursive: true);

    ProcessResult runGit(List<String> args, {String? workingDirectory}) {
      final result = Process.runSync('git', args, workingDirectory: workingDirectory ?? repoDir.path);
      if (result.exitCode != 0) {
        fail('git ${args.join(' ')} failed: ${result.stderr}');
      }
      return result;
    }

    runGit(['init', '-b', 'main']);
    runGit(['config', 'user.name', 'Test User']);
    runGit(['config', 'user.email', 'test@example.com']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# test\n');
    runGit(['add', 'README.md']);
    runGit(['commit', '-m', 'initial']);

    final worktreePath = p.join(workspaceDir.path, '.dartclaw', 'worktrees', 'task-1');
    runGit(['worktree', 'add', worktreePath, '-b', 'dartclaw/task-task-1', 'main']);

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
    );

    final savedCwd = Directory.current;
    Directory.current = repoDir;
    CliWorkflowWiring? wiring;

    try {
      wiring = CliWorkflowWiring(
        config: config,
        dataDir: tempDir.path,
        runAndthenSkillsBootstrap: false,
        environment: {'HOME': p.join(tempDir.path, 'fake-home')},
        harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
      );
      await wiring.wire();
      expect(wiring.worktreeManager, isNotNull);

      final task = await wiring.taskService.create(
        id: 'task-1',
        title: 'Cleanup',
        description: 'Cleanup worktree',
        type: TaskType.coding,
        workflowRunId: 'run-123',
      );
      await wiring.taskService.updateFields(
        task.id,
        worktreeJson: {
          'path': worktreePath,
          'branch': 'dartclaw/task-task-1',
          'createdAt': DateTime.parse('2026-01-01T00:00:00Z').toIso8601String(),
        },
      );

      await wiring.dispose();
      wiring = null;
    } finally {
      Directory.current = savedCwd;
      if (wiring != null) {
        await wiring.dispose();
      }
    }

    expect(Directory(worktreePath).existsSync(), isFalse);
    final branchResult = Process.runSync('git', [
      'branch',
      '--list',
      'dartclaw/task-task-1',
    ], workingDirectory: repoDir.path);
    expect(branchResult.exitCode, 0);
    expect((branchResult.stdout as String).trim(), isEmpty);
  });

  test('workflow cleanup restores checkout before deleting current workflow branch', () async {
    final repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);

    _runGit(repoDir.path, ['init', '-b', 'main']);
    _runGit(repoDir.path, ['config', 'user.name', 'Test User']);
    _runGit(repoDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# test\n');
    _runGit(repoDir.path, ['add', 'README.md']);
    _runGit(repoDir.path, ['commit', '-m', 'initial']);
    _runGit(repoDir.path, ['checkout', '-b', 'feat/0.16.5']);
    _runGit(repoDir.path, ['checkout', '-b', 'dartclaw/workflow/run123/integration']);

    final restoreError = await restoreCheckoutBeforeWorkflowBranchDeletion(
      projectDir: repoDir.path,
      workflowBranches: const {'dartclaw/workflow/run123/integration'},
      restoreRef: 'feat/0.16.5',
    );

    expect(restoreError, isNull);
    final currentBranch = Process.runSync('git', ['branch', '--show-current'], workingDirectory: repoDir.path);
    expect(currentBranch.exitCode, 0);
    expect((currentBranch.stdout as String).trim(), 'feat/0.16.5');
    _runGit(repoDir.path, ['branch', '--delete', '--force', 'dartclaw/workflow/run123/integration']);
  });

  test('workflow cleanup can restore from remote-tracking branch ref', () async {
    final repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);

    _runGit(repoDir.path, ['init', '-b', 'main']);
    _runGit(repoDir.path, ['config', 'user.name', 'Test User']);
    _runGit(repoDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# test\n');
    _runGit(repoDir.path, ['add', 'README.md']);
    _runGit(repoDir.path, ['commit', '-m', 'initial']);
    _runGit(repoDir.path, ['update-ref', 'refs/remotes/origin/main', 'HEAD']);
    _runGit(repoDir.path, ['checkout', '-b', 'dartclaw/workflow/run123/integration']);

    final restoreError = await restoreCheckoutBeforeWorkflowBranchDeletion(
      projectDir: repoDir.path,
      workflowBranches: const {'dartclaw/workflow/run123/integration'},
      restoreRef: 'origin/main',
    );

    expect(restoreError, isNull);
    final currentBranch = Process.runSync('git', ['branch', '--show-current'], workingDirectory: repoDir.path);
    expect(currentBranch.exitCode, 0);
    expect((currentBranch.stdout as String).trim(), isEmpty);
    final head = Process.runSync('git', ['rev-parse', 'HEAD'], workingDirectory: repoDir.path);
    final remoteHead = Process.runSync('git', ['rev-parse', 'origin/main'], workingDirectory: repoDir.path);
    expect(head.exitCode, 0);
    expect(remoteHead.exitCode, 0);
    expect((head.stdout as String).trim(), (remoteHead.stdout as String).trim());
    _runGit(repoDir.path, ['branch', '--delete', '--force', 'dartclaw/workflow/run123/integration']);
  });

  test('workflow cleanup restores remote-tracking ref exactly when local branch is stale', () async {
    final repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);

    _runGit(repoDir.path, ['init', '-b', 'main']);
    _runGit(repoDir.path, ['config', 'user.name', 'Test User']);
    _runGit(repoDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# local main\n');
    _runGit(repoDir.path, ['add', 'README.md']);
    _runGit(repoDir.path, ['commit', '-m', 'local-main']);
    final localMain = Process.runSync('git', ['rev-parse', 'HEAD'], workingDirectory: repoDir.path);
    _runGit(repoDir.path, ['checkout', '--orphan', 'remote-state']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# remote main\n');
    _runGit(repoDir.path, ['add', 'README.md']);
    _runGit(repoDir.path, ['commit', '-m', 'remote-main']);
    _runGit(repoDir.path, ['update-ref', 'refs/remotes/origin/main', 'HEAD']);
    final remoteMain = Process.runSync('git', ['rev-parse', 'HEAD'], workingDirectory: repoDir.path);
    _runGit(repoDir.path, ['checkout', 'main']);
    _runGit(repoDir.path, ['checkout', '-b', 'dartclaw/workflow/run123/integration']);

    final restoreError = await restoreCheckoutBeforeWorkflowBranchDeletion(
      projectDir: repoDir.path,
      workflowBranches: const {'dartclaw/workflow/run123/integration'},
      restoreRef: 'origin/main',
    );

    expect(restoreError, isNull);
    final currentBranch = Process.runSync('git', ['branch', '--show-current'], workingDirectory: repoDir.path);
    final head = Process.runSync('git', ['rev-parse', 'HEAD'], workingDirectory: repoDir.path);
    expect(currentBranch.exitCode, 0);
    expect((currentBranch.stdout as String).trim(), isEmpty);
    expect(head.exitCode, 0);
    expect((head.stdout as String).trim(), (remoteMain.stdout as String).trim());
    expect((head.stdout as String).trim(), isNot((localMain.stdout as String).trim()));
    _runGit(repoDir.path, ['branch', '--delete', '--force', 'dartclaw/workflow/run123/integration']);
    _runGit(repoDir.path, ['branch', '--delete', '--force', 'remote-state']);
  });

  test('workflow cleanup does not switch away from dirty workflow branch', () async {
    final repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);

    _runGit(repoDir.path, ['init', '-b', 'main']);
    _runGit(repoDir.path, ['config', 'user.name', 'Test User']);
    _runGit(repoDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# test\n');
    _runGit(repoDir.path, ['add', 'README.md']);
    _runGit(repoDir.path, ['commit', '-m', 'initial']);
    _runGit(repoDir.path, ['checkout', '-b', 'feat/0.16.5']);
    _runGit(repoDir.path, ['checkout', '-b', 'dartclaw/workflow/run123/integration']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# dirty workflow edit\n');

    final restoreError = await restoreCheckoutBeforeWorkflowBranchDeletion(
      projectDir: repoDir.path,
      workflowBranches: const {'dartclaw/workflow/run123/integration'},
      restoreRef: 'feat/0.16.5',
    );

    expect(restoreError, contains('uncommitted changes'));
    final currentBranch = Process.runSync('git', ['branch', '--show-current'], workingDirectory: repoDir.path);
    expect(currentBranch.exitCode, 0);
    expect((currentBranch.stdout as String).trim(), 'dartclaw/workflow/run123/integration');
    expect(File(p.join(repoDir.path, 'README.md')).readAsStringSync(), '# dirty workflow edit\n');
  });

  test('local project fallback resolves against runtime cwd instead of launch cwd', () async {
    final launchDir = Directory(p.join(tempDir.path, 'launch-repo'))..createSync(recursive: true);
    final runtimeCwd = Directory(p.join(tempDir.path, 'runtime-repo'))..createSync(recursive: true);
    _runGit(runtimeCwd.path, ['init', '-b', 'main']);
    _runGit(runtimeCwd.path, ['config', 'user.name', 'Test User']);
    _runGit(runtimeCwd.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(runtimeCwd.path, 'README.md')).writeAsStringSync('runtime\n');
    _runGit(runtimeCwd.path, ['add', 'README.md']);
    _runGit(runtimeCwd.path, ['commit', '-m', 'initial']);
    _runGit(runtimeCwd.path, ['checkout', '-b', 'runtime-feature']);

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
    );

    final savedCwd = Directory.current;
    Directory.current = launchDir;
    CliWorkflowWiring? wiring;
    try {
      wiring = CliWorkflowWiring(
        config: config,
        dataDir: tempDir.path,
        runAndthenSkillsBootstrap: false,
        environment: {'HOME': p.join(tempDir.path, 'fake-home')},
        runtimeCwd: runtimeCwd.path,
        harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
      );
      await wiring.wire();

      final definition = WorkflowDefinition(
        name: 'local-runtime',
        description: 'Checks local project fallback',
        variables: const {
          'PROJECT': WorkflowVariable(required: false, description: 'Target project'),
          'BRANCH': WorkflowVariable(required: false, description: 'Requested branch'),
        },
        steps: const [
          WorkflowStep(id: 'check', name: 'Check', type: 'analysis', prompts: ['Say OK']),
        ],
      );

      final run = await wiring.workflowService.start(definition, const {
        'PROJECT': '_local',
        'BRANCH': 'runtime-feature',
      }, headless: true);
      expect(run.variablesJson['BRANCH'], 'runtime-feature');
    } finally {
      Directory.current = savedCwd;
      if (wiring != null) {
        await wiring.dispose();
      }
    }
  });

  test('tracked workflow git cleanup for named projects runs in the project checkout', () async {
    final launchDir = Directory(p.join(tempDir.path, 'launch-repo'))..createSync(recursive: true);
    final runtimeCwd = Directory(p.join(tempDir.path, 'runtime-cwd'))..createSync(recursive: true);
    final projectDir = Directory(p.join(tempDir.path, 'project-alpha'))..createSync(recursive: true);
    final workspaceDir = Directory(p.join(tempDir.path, 'workspace'))..createSync(recursive: true);

    _runGit(projectDir.path, ['init', '-b', 'main']);
    _runGit(projectDir.path, ['config', 'user.name', 'Test User']);
    _runGit(projectDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('# project\n');
    _runGit(projectDir.path, ['add', 'README.md']);
    _runGit(projectDir.path, ['commit', '-m', 'initial']);

    final worktreePath = p.join(workspaceDir.path, '.dartclaw', 'worktrees', 'task-1');
    _runGit(projectDir.path, ['worktree', 'add', worktreePath, '-b', 'dartclaw/task-task-1', 'main']);

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path)},
      ),
    );

    final savedCwd = Directory.current;
    Directory.current = launchDir;
    CliWorkflowWiring? wiring;
    try {
      wiring = CliWorkflowWiring(
        config: config,
        dataDir: tempDir.path,
        runAndthenSkillsBootstrap: false,
        environment: {'HOME': p.join(tempDir.path, 'fake-home')},
        runtimeCwd: runtimeCwd.path,
        harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
      );
      await wiring.wire();

      final task = await wiring.taskService.create(
        id: 'task-1',
        title: 'Cleanup',
        description: 'Cleanup worktree',
        type: TaskType.coding,
        projectId: 'alpha',
        workflowRunId: 'run-123',
      );
      await wiring.taskService.updateFields(
        task.id,
        worktreeJson: {
          'path': worktreePath,
          'branch': 'dartclaw/task-task-1',
          'createdAt': DateTime.parse('2026-01-01T00:00:00Z').toIso8601String(),
        },
      );

      await wiring.dispose();
      wiring = null;
    } finally {
      Directory.current = savedCwd;
      if (wiring != null) {
        await wiring.dispose();
      }
    }

    expect(Directory(worktreePath).existsSync(), isFalse);
    final projectBranchResult = Process.runSync('git', [
      'branch',
      '--list',
      'dartclaw/task-task-1',
    ], workingDirectory: projectDir.path);
    expect(projectBranchResult.exitCode, 0);
    expect((projectBranchResult.stdout as String).trim(), isEmpty);
  });

  test('standalone coding tasks use the configured project clone instead of cwd', () async {
    final localRepoDir = Directory(p.join(tempDir.path, 'local-repo'))..createSync(recursive: true);
    final alphaSeedDir = Directory(p.join(tempDir.path, 'alpha-seed'))..createSync(recursive: true);
    final alphaOriginDir = Directory(p.join(tempDir.path, 'alpha-origin.git'))..createSync(recursive: true);
    final alphaRepoDir = Directory(p.join(tempDir.path, 'projects', 'alpha'));

    ProcessResult runGit(String repoDir, List<String> args) {
      final result = Process.runSync('git', args, workingDirectory: repoDir);
      if (result.exitCode != 0) {
        fail('git ${args.join(' ')} failed in $repoDir: ${result.stderr}');
      }
      return result;
    }

    void seedRepo(String repoDir, String readmeTitle) {
      runGit(repoDir, ['init', '-b', 'main']);
      runGit(repoDir, ['config', 'user.name', 'Test User']);
      runGit(repoDir, ['config', 'user.email', 'test@example.com']);
      File(p.join(repoDir, 'README.md')).writeAsStringSync('# $readmeTitle\n');
      runGit(repoDir, ['add', 'README.md']);
      runGit(repoDir, ['commit', '-m', 'initial']);
    }

    seedRepo(localRepoDir.path, 'local');
    seedRepo(alphaSeedDir.path, 'alpha');
    runGit(alphaOriginDir.path, ['init', '--bare']);
    runGit(alphaSeedDir.path, ['remote', 'add', 'origin', alphaOriginDir.path]);
    runGit(alphaSeedDir.path, ['push', '-u', 'origin', 'main']);
    final cloneResult = Process.runSync('git', ['clone', alphaOriginDir.path, alphaRepoDir.path]);
    if (cloneResult.exitCode != 0) {
      fail('git clone ${alphaOriginDir.path} failed: ${cloneResult.stderr}');
    }

    final harnesses = <FakeAgentHarness>[];
    final factory = HarnessFactory()
      ..register('claude', (_) {
        final harness = FakeAgentHarness();
        harnesses.add(harness);
        return harness;
      });

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', remote: alphaOriginDir.uri.toString())},
      ),
    );

    final savedCwd = Directory.current;
    Directory.current = localRepoDir;
    CliWorkflowWiring? wiring;

    try {
      wiring = CliWorkflowWiring(
        config: config,
        dataDir: tempDir.path,
        runAndthenSkillsBootstrap: false,
        environment: {'HOME': p.join(tempDir.path, 'fake-home')},
        harnessFactory: factory,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
      );
      await wiring.wire();

      var taskCompleted = false;
      final taskSub = wiring.eventBus
          .on<TaskStatusChangedEvent>()
          .where((event) => event.taskId == 'project-bound-task' && event.newStatus.terminal)
          .listen((_) {
            taskCompleted = true;
          });
      addTearDown(taskSub.cancel);

      await wiring.taskService.create(
        id: 'project-bound-task',
        title: 'Project bound task',
        description: 'Inspect repo binding',
        type: TaskType.coding,
        projectId: 'alpha',
        autoStart: true,
        configJson: const {'reviewMode': 'auto-accept'},
      );

      Task? updatedTask;
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        updatedTask = await wiring.taskService.get('project-bound-task');
        if (updatedTask?.worktreeJson != null) {
          break;
        }
        if (updatedTask?.status == TaskStatus.failed) {
          fail('Task failed before worktree creation: ${updatedTask?.configJson['failReason'] ?? updatedTask}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      final worktreeDir = updatedTask?.worktreeJson?['path'] as String?;
      expect(worktreeDir, isNotNull, reason: 'coding task should create a git worktree for the configured project');
      expect(File(p.join(worktreeDir!, 'README.md')).readAsStringSync(), '# alpha\n');

      await _waitFor(() => harnesses.any((h) => h.turnCallCount > 0), timeout: const Duration(seconds: 10));
      final worker = harnesses.firstWhere((h) => h.turnCallCount > 0);

      worker.completeSuccess();
      await _waitFor(() => taskCompleted);
    } finally {
      Directory.current = savedCwd;
      if (wiring != null) {
        await wiring.dispose();
      }
    }
  });

  test('honors a local asset root for built-in skill discovery', () async {
    final prefixDir = Directory(p.join(tempDir.path, 'prefix'))..createSync(recursive: true);
    final assetRoot = Directory(p.join(prefixDir.path, 'share', 'dartclaw'))..createSync(recursive: true);
    Directory(p.join(assetRoot.path, 'templates')).createSync(recursive: true);
    Directory(p.join(assetRoot.path, 'static')).createSync(recursive: true);
    final skillDir = Directory(p.join(assetRoot.path, 'skills', 'dartclaw-asset-skill'))..createSync(recursive: true);
    File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync('---\nname: dartclaw-asset-skill\n---\n\n# asset\n');

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
    );

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: tempDir.path,
      runAndthenSkillsBootstrap: false,
      environment: {'HOME': p.join(tempDir.path, 'fake-home')},
      assetResolver: AssetResolver(resolvedExecutable: p.join(prefixDir.path, 'bin', 'dartclaw')),
      harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
    );
    addTearDown(wiring.dispose);

    await wiring.wire();

    final skill = wiring.skillRegistry.getByName('dartclaw-asset-skill');
    expect(skill, isNotNull);
    expect(skill!.source, SkillSource.dartclaw);
  });
}

void _seedAndthenSrc(String srcDir, {required String sha}) {
  Directory(srcDir).createSync(recursive: true);
  Directory(p.join(srcDir, '.git')).createSync(recursive: true);
  final scriptDir = Directory(p.join(srcDir, 'scripts'))..createSync(recursive: true);
  File(p.join(scriptDir.path, 'install-skills.sh')).writeAsStringSync('#!/bin/sh\nexit 0\n');
  File(p.join(srcDir, '.git', 'HEAD_SHA')).writeAsStringSync(sha);
}

class _FakeProvisionerProcessRunner {
  final List<({String executable, List<String> arguments, String? workingDirectory})> calls = [];

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add((executable: executable, arguments: arguments, workingDirectory: workingDirectory));

    if (executable == 'git' && arguments.contains('rev-parse')) {
      final cIndex = arguments.indexOf('-C');
      final srcDir = cIndex >= 0 && cIndex + 1 < arguments.length ? arguments[cIndex + 1] : null;
      final shaFile = srcDir == null ? null : File(p.join(srcDir, '.git', 'HEAD_SHA'));
      return ProcessResult(0, 0, '${shaFile?.readAsStringSync().trim() ?? 'standalone-head'}\n', '');
    }
    if (executable == 'git') {
      return ProcessResult(0, 0, '', '');
    }
    if (executable.endsWith('install-skills.sh')) {
      String? skillsDir;
      String? claudeSkillsDir;
      String? claudeAgentsDir;
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
      if (arguments.contains('--claude-user')) {
        final home = environment?['HOME'];
        if (home == null || home.isEmpty) {
          return ProcessResult(0, 2, '', 'HOME is required for --claude-user');
        }
        skillsDir ??= p.join(home, '.agents', 'skills');
        claudeSkillsDir ??= p.join(home, '.claude', 'skills');
        claudeAgentsDir ??= p.join(home, '.claude', 'agents');
      }
      for (final dir in [skillsDir, claudeSkillsDir, claudeAgentsDir].whereType<String>()) {
        Directory(dir).createSync(recursive: true);
      }
      for (final dir in [skillsDir, claudeSkillsDir].whereType<String>()) {
        for (final name in _shippedDartclawSkillRefs) {
          File(p.join(dir, name, 'SKILL.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync('---\nname: $name\ndescription: fake $name\n---\n# $name\n');
        }
      }
      return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(0, 0, '', '');
  }
}

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
