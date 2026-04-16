import 'dart:async';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
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

  test('materializes built-in skills for every configured project clone', () async {
    final skillsHomeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
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
      skillsHomeDir: skillsHomeDir.path,
      harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
    );
    addTearDown(wiring.dispose);

    await wiring.wire();

    final skillDir = p.join(skillsHomeDir.path, '.claude', 'skills', 'dartclaw-review');
    expect(File(p.join(skillDir, 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(skillDir, '.dartclaw-managed')).existsSync(), isTrue);

    for (final projectId in ['alpha', 'beta']) {
      final projectSkillDir = p.join(tempDir.path, 'projects', projectId, '.claude', 'skills', 'dartclaw-review');
      expect(Directory(projectSkillDir).existsSync(), isFalse);
    }
  });

  test('excludes custom workflows that reference missing skills', () async {
    final workspaceWorkflowsDir = Directory(p.join(tempDir.path, 'workspace', 'workflows'))
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
      skillsHomeDir: p.join(tempDir.path, 'home'),
      harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
    );
    addTearDown(wiring.dispose);

    await wiring.wire();

    expect(wiring.registry.getByName('invalid-missing-skill'), isNull);
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
      skillsHomeDir: p.join(tempDir.path, 'home'),
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

    expect(createdTask?.configJson['_workflowWorkspaceDir'], workflowWorkspaceDir.path);
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
      skillsHomeDir: p.join(tempDir.path, 'home'),
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
        skillsHomeDir: p.join(tempDir.path, 'home'),
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

  test('honors a local asset root for built-in skill discovery and materialization', () async {
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
      skillsHomeDir: p.join(tempDir.path, 'home'),
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
