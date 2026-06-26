import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskType;

import 'package:dartclaw_cli/src/commands/workflow/andthen_skill_bootstrap.dart' show bootstrapWorkflowSkills;
import 'package:dartclaw_cli/src/commands/workflow/workflow_git_support.dart'
    show restoreCheckoutBeforeWorkflowBranchDeletion;
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show OutputConfig, OutputFormat, WorkflowDefinition, WorkflowStep, WorkflowVariable;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'cli_workflow_wiring_test_support.dart';

void main() {
  late Directory tempDir;
  late CliWorkflowWiringFixture fixture;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_cli_workflow_wiring_test_');
    fixture = CliWorkflowWiringFixture(tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('loads built-in skills from source tree without materializing project copies', () async {
    final cfg = fixture.config(
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

    final wired = fixture.wiring(
      cfg,
      skillIntrospector: FakeSkillIntrospector({
        'claude': {'andthen:review'},
      }),
    );

    await wired.wire();

    for (final projectId in ['alpha', 'beta']) {
      final projectSkillDir = p.join(
        tempDir.path,
        'projects',
        projectId,
        '.claude',
        'skills',
        'dartclaw-discover-andthen-spec',
      );
      expect(Directory(projectSkillDir).existsSync(), isFalse);
    }
  });

  test('skill bootstrap does not create remote project clone directories before initialization', () async {
    seedAndthenSrc(p.join(tempDir.path, 'andthen-src'), sha: 'bootstrap-head');
    final builtInSkillsSource = seedDcNativeSkillsSource(p.join(tempDir.path, 'built-in-skills'));
    final cfg = fixture.config(
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', remote: 'file:///tmp/alpha.git')},
      ),
    );

    await bootstrapWorkflowSkills(
      config: cfg,
      dataDir: tempDir.path,
      builtInSkillsSourceDir: builtInSkillsSource.path,
      processRunner: FakeProvisionerProcessRunner().run,
      environment: {'HOME': p.join(tempDir.path, 'fake-home')},
    );

    final cloneDir = Directory(p.join(tempDir.path, 'projects', 'alpha'));
    expect(cloneDir.existsSync(), isFalse);
  });

  test('TI01 pre-harness phase completes registry without starting any harness', () async {
    // Every registered provider's start() throws; the pre-harness phase must
    // load the registry without reaching any harness.start().
    final workflowsDir = Directory(p.join(tempDir.path, 'workflows', 'custom'))..createSync(recursive: true);
    File(p.join(workflowsDir.path, 'ci-demo.yaml')).writeAsStringSync('''
name: ci-demo
description: Demo standalone workflow
steps:
  - id: shell-check
    name: Shell Check
    type: bash
    prompt: |
      printf 'ok\\n'
''');

    final wired = fixture.wiring(
      fixture.config(),
      harnessFactory: throwOnStartHarnessFactory(const ['claude', 'codex']),
    );

    await wired.wirePreHarness();

    expect(wired.registry.getByName('ci-demo'), isNotNull);
  });

  test('loads custom workflows with missing skills and fails at runtime preflight', () async {
    final workspaceWorkflowsDir = Directory(p.join(tempDir.path, 'workflows', 'custom'))..createSync(recursive: true);
    File(p.join(workspaceWorkflowsDir.path, 'invalid.yaml')).writeAsStringSync('''
name: invalid-missing-skill
description: Should load but fail at runtime preflight
steps:
  - id: review
    name: Review
    skill: missing-skill
''');

    final wired = fixture.wiring(
      fixture.config(),
      skillIntrospector: FakeSkillIntrospector({
        'claude': {'andthen:review'},
      }),
    );

    await wired.wire();

    final definition = wired.registry.getByName('invalid-missing-skill');
    expect(definition, isNotNull);

    final failed = Completer<WorkflowRunStatusChangedEvent>();
    final sub = wired.eventBus
        .on<WorkflowRunStatusChangedEvent>()
        .where((event) => event.newStatus == WorkflowRunStatus.failed)
        .listen((event) {
          if (!failed.isCompleted) {
            failed.complete(event);
          }
        });
    addTearDown(sub.cancel);

    final run = await wired.workflowService.start(definition!, const {}, headless: true);
    final event = await failed.future.timeout(const Duration(seconds: 5));

    expect(event.runId, run.id);
    final failedRun = await wired.workflowService.get(run.id);
    expect(failedRun?.errorMessage, contains('Missing skills for provider "claude": missing-skill'));
    expect(await wired.taskService.list(), isEmpty);
  });

  test('loads workflow yaml files directly under the data-dir workflows folder', () async {
    final workflowsDir = Directory(p.join(tempDir.path, 'workflows'))..createSync(recursive: true);
    File(p.join(workflowsDir.path, 'my-review.yaml')).writeAsStringSync('''
name: my-review
description: Local review workflow
steps:
  - id: shell-check
    name: Shell Check
    type: bash
    prompt: |
      printf 'ok\\n'
''');

    final wired = fixture.wiring(fixture.config());

    await wired.wire();

    expect(wired.registry.getByName('my-review'), isNotNull);
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

    final cfg = fixture.config(
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path)},
      ),
    );

    final wired = fixture.wiring(
      cfg,
      skillIntrospector: FakeSkillIntrospector({
        'claude': {'andthen:review'},
      }),
    );

    await wired.wire();

    expect(wired.registry.getByName('local-only'), isNotNull);
  });

  test('workflow start rejects local-path branch mismatch even when BRANCH matches the observed branch', () async {
    final projectDir = fixture.seedGitRepo('live-project');
    runGit(projectDir.path, ['checkout', '-b', 'feature/local']);

    final cfg = fixture.config(
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path, branch: 'main')},
      ),
    );

    final wired = fixture.wiring(cfg);

    await wired.wire();

    final definition = branchGuardDefinition();

    await expectLater(
      () => wired.workflowService.start(definition, const {
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

  test('workflow start rejects option-shaped BRANCH before git ref lookup', () async {
    final projectDir = fixture.seedGitRepo('local-project');

    final cfg = fixture.config(
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path, branch: 'main')},
      ),
    );

    final wired = fixture.wiring(cfg);
    await wired.wire();

    final definition = branchGuardDefinition();

    await expectLater(
      () => wired.workflowService.start(definition, const {
        'PROJECT': 'alpha',
        'BRANCH': '--upload-pack=/tmp/pwn',
      }, headless: true),
      throwsFormatException,
    );
  });

  test('workflow start infers BRANCH from HEAD for local-path projects when branch is omitted', () async {
    final projectDir = fixture.seedGitRepo('live-project');
    runGit(projectDir.path, ['checkout', '-b', 'feature/local']);

    final cfg = fixture.config(
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path, branch: '')},
      ),
    );

    final wired = fixture.wiring(cfg);

    await wired.wire();

    final definition = branchGuardDefinition();

    final run = await wired.workflowService.start(definition, const {'PROJECT': 'alpha'}, headless: true);
    expect(run.variablesJson['BRANCH'], 'feature/local');
  });

  test('workflow start propagates the configured workflow workspace into created tasks', () async {
    final workflowWorkspaceDir = Directory(p.join(tempDir.path, 'workflow-workspace'))..createSync(recursive: true);
    File(p.join(workflowWorkspaceDir.path, 'AGENTS.md')).writeAsStringSync('CLI workflow workspace rules');

    final cfg = fixture.config(workflow: WorkflowConfig(workspaceDir: workflowWorkspaceDir.path));

    final wired = fixture.wiring(
      cfg,
      skillIntrospector: FakeSkillIntrospector({
        'claude': {'andthen:review'},
      }),
    );

    await wired.wire();

    final definition = WorkflowDefinition(
      name: 'two-prompt-review',
      description: 'Two prompts in one step',
      steps: const [
        WorkflowStep(
          id: 'review',
          name: 'Review',
          taskType: WorkflowTaskType.agent,
          skill: 'andthen:review',
          prompts: ['Inspect the change set.', 'Re-check the follow-up output.'],
        ),
      ],
    );

    Task? createdTask;
    final sub = wired.eventBus
        .on<TaskStatusChangedEvent>()
        .where((event) => event.newStatus == TaskStatus.queued)
        .listen((event) async {
          createdTask = await wired.taskService.get(event.taskId);
        });

    final run = await wired.workflowService.start(definition, const {}, headless: true);
    await waitFor(() => createdTask != null);
    await sub.cancel();

    expect(createdTask?.agentExecution?.workspaceDir, workflowWorkspaceDir.path);
    await wired.workflowService.cancel(run.id);
  });

  test('injects provider credentials into standalone harness environments', () async {
    final capturedByProvider = <String, List<HarnessFactoryConfig>>{};
    final factory = capturingHarnessFactory(capturedByProvider, ['codex', 'claude']);

    final cfg = fixture.config(
      agent: const AgentConfig(provider: 'codex'),
      providers: const ProvidersConfig(
        entries: {
          'codex': ProviderEntry(executable: 'codex', poolSize: 0),
          'claude': ProviderEntry(executable: 'claude', poolSize: 1),
        },
      ),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
          'openai': CredentialEntry(apiKey: 'openai-key'),
        },
      ),
    );

    final wired = fixture.wiring(cfg, harnessFactory: factory);

    await wired.wire();
    await wired.ensureTaskRunnersForProviders({'claude'});

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

  test('reserves a pool slot for each non-default provider when default pool_size saturates the floor', () async {
    // Regression: with codex (default, pool_size: 3) + claude (pool_size: 1)
    // the eager spawn previously filled the 3-slot minimum capacity, then the
    // first ensureTaskRunnersForProviders({'claude'}) threw `Pool already at
    // capacity (3/3)` because no slot was reserved for the non-default
    // provider that workflow steps pin (e.g. plan-and-implement-inline's
    // plan-review-council pins provider: claude).
    final capturedByProvider = <String, List<HarnessFactoryConfig>>{};
    final factory = capturingHarnessFactory(capturedByProvider, ['codex', 'claude']);

    final cfg = fixture.config(
      agent: const AgentConfig(provider: 'codex'),
      providers: const ProvidersConfig(
        entries: {
          'codex': ProviderEntry(executable: 'codex', poolSize: 3),
          'claude': ProviderEntry(executable: 'claude', poolSize: 1),
        },
      ),
    );

    final wired = fixture.wiring(cfg, harnessFactory: factory);

    await wired.wire();
    await wired.ensureTaskRunnersForProviders({'codex', 'claude'});

    // Pool now holds the primary codex harness + 3 codex task runners + the
    // on-demand claude runner. addRunner must not have thrown.
    expect(capturedByProvider['codex'], hasLength(4), reason: 'primary harness + 3 eager codex task runners');
    expect(capturedByProvider['claude'], hasLength(1), reason: 'on-demand claude task runner');
    expect(wired.pool.hasTaskRunnerForProvider('claude'), isTrue);
  });

  test('standalone single-provider pool_size one creates exactly one task runner', () async {
    final captured = <HarnessFactoryConfig>[];
    final factory = HarnessFactory()
      ..register('claude', (config) {
        if (config.cwd != '/') captured.add(config);
        return FakeAgentHarness();
      });

    final cfg = fixture.config(
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    final wired = fixture.wiring(cfg, harnessFactory: factory);

    await wired.wire();

    expect(captured, hasLength(2), reason: 'primary harness plus one task runner');
    expect(wired.pool.maxConcurrentTasks, 1);
    expect(wired.pool.availableCount, 1);
    expect(wired.pool.taskRunnerCountForProvider('claude'), 1);
  });

  test('standalone non-empty provider config missing default still reserves default capacity', () async {
    final capturedByProvider = <String, List<HarnessFactoryConfig>>{};
    final factory = capturingHarnessFactory(capturedByProvider, ['claude', 'goose']);

    final cfg = fixture.config(
      providers: const ProvidersConfig(entries: {'goose': ProviderEntry(executable: 'goose', poolSize: 1)}),
    );

    final wired = fixture.wiring(cfg, harnessFactory: factory);

    await wired.wire();
    await wired.ensureTaskRunnersForProviders({'goose'});

    expect(wired.pool.maxConcurrentTasks, 2);
    expect(capturedByProvider['claude'], hasLength(2), reason: 'primary harness plus default task runner');
    expect(capturedByProvider['goose'], hasLength(1));
  });

  test('standalone configured fake provider gets its own pool without ACP subprocess behavior', () async {
    final capturedByProvider = <String, List<HarnessFactoryConfig>>{};
    final factory = capturingHarnessFactory(capturedByProvider, ['claude', 'goose']);

    final cfg = fixture.config(
      providers: const ProvidersConfig(
        entries: {
          'claude': ProviderEntry(executable: 'claude', poolSize: 1),
          'goose': ProviderEntry(executable: 'goose', poolSize: 1),
        },
      ),
    );

    final wired = fixture.wiring(cfg, harnessFactory: factory);

    await wired.wire();
    await wired.ensureTaskRunnersForProviders({'goose'});

    expect(capturedByProvider['claude'], hasLength(2), reason: 'primary harness plus one claude task runner');
    expect(capturedByProvider['goose'], hasLength(1));
    final gooseRunner = wired.pool.tryAcquireForProvider('goose');
    expect(gooseRunner, isNotNull);
    expect(gooseRunner!.providerId, 'goose');
    expect(wired.pool.tryAcquireForProvider('claude')!.providerId, 'claude');
  });

  test('standalone unknown provider fails without default-provider fallback', () async {
    final capturedByProvider = <String, int>{};
    final factory = HarnessFactory()
      ..register('claude', (config) {
        if (config.cwd != '/') {
          capturedByProvider.update('claude', (count) => count + 1, ifAbsent: () => 1);
        }
        return FakeAgentHarness();
      });

    final cfg = fixture.config(
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
    );

    final wired = fixture.wiring(cfg, harnessFactory: factory);

    await wired.wire();

    await expectLater(
      () => wired.ensureTaskRunnersForProviders({'goose'}),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Provider "goose"'))),
    );
    expect(capturedByProvider['claude'], 2, reason: 'primary harness plus one configured claude task runner only');
    expect(wired.pool.hasTaskRunnerForProvider('goose'), isFalse);
  });

  test('defaults standalone harness cwd to the process cwd when runtime cwd is omitted', () async {
    final launchDir = Directory(p.join(tempDir.path, 'launch-repo'))..createSync(recursive: true);
    final captured = <HarnessFactoryConfig>[];
    final factory = HarnessFactory()
      ..register('claude', (config) {
        if (config.cwd != '/') captured.add(config);
        return FakeAgentHarness();
      });

    final cfg = fixture.config();

    await fixture.withWiredCurrentDirectory(launchDir, cfg, harnessFactory: factory, body: (_) async {});

    expect(captured.map((config) => config.cwd).toSet(), {launchDir.resolveSymbolicLinksSync()});
  });

  test('uses injected runtime cwd for primary and task-runner harnesses', () async {
    final launchDir = Directory(p.join(tempDir.path, 'launch-repo'))..createSync(recursive: true);
    final runtimeCwd = Directory(p.join(tempDir.path, 'runtime-cwd'))..createSync(recursive: true);
    final capturedByProvider = <String, List<HarnessFactoryConfig>>{};
    final factory = HarnessFactory()
      ..register('codex', (config) {
        if (config.cwd != '/') capturedByProvider.putIfAbsent('codex', () => <HarnessFactoryConfig>[]).add(config);
        return FakeAgentHarness();
      })
      ..register('claude', (config) {
        if (config.cwd != '/') capturedByProvider.putIfAbsent('claude', () => <HarnessFactoryConfig>[]).add(config);
        return FakeAgentHarness();
      });

    final cfg = fixture.config(
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
    );

    await fixture.withWiredCurrentDirectory(
      launchDir,
      cfg,
      runtimeCwd: runtimeCwd.path,
      harnessFactory: factory,
      body: (wired) => wired.ensureTaskRunnersForProviders({'claude'}),
    );

    final captured = [
      ...capturedByProvider['codex'] ?? const <HarnessFactoryConfig>[],
      ...capturedByProvider['claude'] ?? const <HarnessFactoryConfig>[],
    ];
    expect(captured, hasLength(4), reason: 'primary, two default task runners, and one added provider runner');
    expect(captured.map((config) => config.cwd).toSet(), {runtimeCwd.path});
  });

  test('standalone wiring provisions DC-native skills before registering shipped workflows', () async {
    final fakeHome = p.join(tempDir.path, 'provision-home');
    seedProviderAndThenSkills(fakeHome);
    final runner = FakeProvisionerProcessRunner();

    final wired = fixture.wiring(
      fixture.config(),
      runtimeCwd: tempDir.path,
      runAndthenSkillsBootstrap: true,
      skillProvisionerProcessRunner: runner.run,
      environment: {'HOME': fakeHome},
    );

    await wired.wire();

    expect(
      File(p.join(tempDir.path, '.agents', 'skills', 'dartclaw-discover-andthen-spec', 'SKILL.md')).existsSync(),
      isTrue,
    );
    expect(unexpectedDataDirSkillEntries(tempDir.path), isEmpty);
    final registeredNames = wired.registry.listAll().map((workflow) => workflow.name).toSet();
    expect(registeredNames, containsAll(['plan-and-implement', 'spec-and-implement', 'code-review']));
    expect(runner.calls.where((call) => call.executable.endsWith('install-skills.sh')), isEmpty);
  });

  test('dispose cleans up workflow task worktrees in headless mode', () async {
    final repoDir = fixture.seedGitRepo('repo', readme: '# test\n');
    final workspaceDir = Directory(p.join(tempDir.path, 'workspace'))..createSync(recursive: true);

    final worktreePath = p.join(workspaceDir.path, '.dartclaw', 'worktrees', 'task-1');
    runGit(repoDir.path, ['worktree', 'add', worktreePath, '-b', 'dartclaw/task-task-1', 'main']);

    final config = fixture.config(
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
    );

    await fixture.withWiredCurrentDirectory(
      repoDir,
      config,
      body: (wiring) async {
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
      },
    );

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
    final repoDir = fixture.seedGitRepo('repo', readme: '# test\n');
    runGit(repoDir.path, ['checkout', '-b', 'feat/0.16.5']);
    runGit(repoDir.path, ['checkout', '-b', 'dartclaw/workflow/run123/integration']);

    final restoreError = await restoreCheckoutBeforeWorkflowBranchDeletion(
      projectDir: repoDir.path,
      workflowBranches: const {'dartclaw/workflow/run123/integration'},
      restoreRef: 'feat/0.16.5',
    );

    expect(restoreError, isNull);
    final currentBranch = Process.runSync('git', ['branch', '--show-current'], workingDirectory: repoDir.path);
    expect(currentBranch.exitCode, 0);
    expect((currentBranch.stdout as String).trim(), 'feat/0.16.5');
    runGit(repoDir.path, ['branch', '--delete', '--force', 'dartclaw/workflow/run123/integration']);
  });

  test('workflow cleanup can restore from remote-tracking branch ref', () async {
    final repoDir = fixture.seedGitRepo('repo', readme: '# test\n');
    runGit(repoDir.path, ['update-ref', 'refs/remotes/origin/main', 'HEAD']);
    runGit(repoDir.path, ['checkout', '-b', 'dartclaw/workflow/run123/integration']);

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
    runGit(repoDir.path, ['branch', '--delete', '--force', 'dartclaw/workflow/run123/integration']);
  });

  test('workflow cleanup restores remote-tracking ref exactly when local branch is stale', () async {
    final repoDir = fixture.seedGitRepo('repo', readme: '# local main\n');
    final localMain = Process.runSync('git', ['rev-parse', 'HEAD'], workingDirectory: repoDir.path);
    runGit(repoDir.path, ['checkout', '--orphan', 'remote-state']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# remote main\n');
    runGit(repoDir.path, ['add', 'README.md']);
    runGit(repoDir.path, ['commit', '-m', 'remote-main']);
    runGit(repoDir.path, ['update-ref', 'refs/remotes/origin/main', 'HEAD']);
    final remoteMain = Process.runSync('git', ['rev-parse', 'HEAD'], workingDirectory: repoDir.path);
    runGit(repoDir.path, ['checkout', 'main']);
    runGit(repoDir.path, ['checkout', '-b', 'dartclaw/workflow/run123/integration']);

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
    runGit(repoDir.path, ['branch', '--delete', '--force', 'dartclaw/workflow/run123/integration']);
    runGit(repoDir.path, ['branch', '--delete', '--force', 'remote-state']);
  });

  test('workflow cleanup does not switch away from dirty workflow branch', () async {
    final repoDir = fixture.seedGitRepo('repo', readme: '# test\n');
    runGit(repoDir.path, ['checkout', '-b', 'feat/0.16.5']);
    runGit(repoDir.path, ['checkout', '-b', 'dartclaw/workflow/run123/integration']);
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
    final runtimeCwd = fixture.seedGitRepo('runtime-repo', readme: 'runtime\n');
    runGit(runtimeCwd.path, ['checkout', '-b', 'runtime-feature']);

    final config = fixture.config();

    await fixture.withWiredCurrentDirectory(
      launchDir,
      config,
      runtimeCwd: runtimeCwd.path,
      body: (wiring) async {
        final definition = branchGuardDefinition(name: 'local-runtime', projectRequired: false);

        final run = await wiring.workflowService.start(definition, const {
          'PROJECT': '_local',
          'BRANCH': 'runtime-feature',
        }, headless: true);
        expect(run.variablesJson['BRANCH'], 'runtime-feature');
      },
    );
  });

  test('standalone workflow output validation uses runtime cwd as default workspace root', () async {
    final launchDir = Directory(p.join(tempDir.path, 'launch-repo'))..createSync(recursive: true);
    final runtimeCwd = fixture.seedGitRepo('runtime-output-root', readme: 'runtime\n');
    File(p.join(runtimeCwd.path, 'docs/specs/demo/prd.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync('# PRD\n');
    File(p.join(runtimeCwd.path, 'docs/specs/demo/plan.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'stories': [
            {'id': 'S01', 'status': 'spec-ready', 'fis': 'docs/specs/demo/fis/s01.md'},
          ],
        }),
      );
    File(p.join(runtimeCwd.path, 'docs/specs/demo/fis/s01.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync('# FIS\n');

    final config = fixture.config();

    final savedCwd = Directory.current;
    Directory.current = launchDir;
    final wiring = fixture.wiring(
      config,
      runtimeCwd: runtimeCwd.path,
      skillIntrospector: FakeSkillIntrospector({
        'claude': {'dartclaw-discover-andthen-plan'},
      }),
      autoDispose: false,
    );
    try {
      await wiring.wire();

      final definition = WorkflowDefinition(
        name: 'runtime-output-root',
        description: 'Validates output paths against runtime cwd',
        steps: const [
          WorkflowStep(
            id: 'discover-plan-state',
            name: 'Discover Plan State',
            skill: 'dartclaw-discover-andthen-plan',
            prompts: ['discover'],
            outputs: {
              'prd': OutputConfig(),
              'plan': OutputConfig(),
              'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story_specs'),
            },
          ),
        ],
      );
      final completion = Completer<void>();
      String? runId;
      final statusSub = wiring.eventBus
          .on<WorkflowRunStatusChangedEvent>()
          .where((event) => runId != null && event.runId == runId && event.newStatus == WorkflowRunStatus.completed)
          .listen((_) {
            if (!completion.isCompleted) {
              completion.complete();
            }
          });
      addTearDown(statusSub.cancel);
      final sub = wiring.eventBus
          .on<TaskStatusChangedEvent>()
          .where((event) => event.newStatus == TaskStatus.queued)
          .listen((event) async {
            final session = await wiring.sessionService.createSession(type: SessionType.task);
            await wiring.taskService.updateFields(event.taskId, sessionId: session.id);
            await wiring.messageService.insertMessage(
              sessionId: session.id,
              role: 'assistant',
              content:
                  '<workflow-context>${jsonEncode({
                    'prd': 'docs/specs/demo/prd.md',
                    'plan': 'docs/specs/demo/plan.json',
                    'story_specs': {
                      'items': [
                        {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
                      ],
                    },
                  })}</workflow-context>',
            );
            await wiring.taskService.transition(event.taskId, TaskStatus.running);
            await wiring.taskService.transition(event.taskId, TaskStatus.accepted);
          });
      addTearDown(sub.cancel);
      final run = await wiring.workflowService.start(definition, const {}, headless: true);
      runId = run.id;
      final current = await wiring.workflowService.get(run.id);
      if (current?.status == WorkflowRunStatus.completed && !completion.isCompleted) {
        completion.complete();
      }

      await completion.future.timeout(const Duration(seconds: 5));
      final completed = await wiring.workflowService.get(run.id);
      expect(completed?.status, WorkflowRunStatus.completed);
    } finally {
      await wiring.dispose();
      Directory.current = savedCwd;
    }
  });

  test('tracked workflow git cleanup for named projects runs in the project checkout', () async {
    final launchDir = Directory(p.join(tempDir.path, 'launch-repo'))..createSync(recursive: true);
    final runtimeCwd = Directory(p.join(tempDir.path, 'runtime-cwd'))..createSync(recursive: true);
    final projectDir = fixture.seedGitRepo('project-alpha', readme: '# project\n');
    final workspaceDir = Directory(p.join(tempDir.path, 'workspace'))..createSync(recursive: true);

    final worktreePath = p.join(workspaceDir.path, '.dartclaw', 'worktrees', 'task-1');
    runGit(projectDir.path, ['worktree', 'add', worktreePath, '-b', 'dartclaw/task-task-1', 'main']);

    final config = fixture.config(
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path)},
      ),
    );

    await fixture.withWiredCurrentDirectory(
      launchDir,
      config,
      runtimeCwd: runtimeCwd.path,
      body: (wiring) async {
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
      },
    );

    expect(Directory(worktreePath).existsSync(), isFalse);
    final projectBranchResult = Process.runSync('git', [
      'branch',
      '--list',
      'dartclaw/task-task-1',
    ], workingDirectory: projectDir.path);
    expect(projectBranchResult.exitCode, 0);
    expect((projectBranchResult.stdout as String).trim(), isEmpty);
  });

  test('tracked workflow git cleanup preserves non-terminal runs for resume', () async {
    final launchDir = Directory(p.join(tempDir.path, 'launch-repo'))..createSync(recursive: true);
    final runtimeCwd = Directory(p.join(tempDir.path, 'runtime-cwd'))..createSync(recursive: true);
    final projectDir = fixture.seedGitRepo('project-alpha', readme: '# project\n');
    final workspaceDir = Directory(p.join(tempDir.path, 'workspace'))..createSync(recursive: true);

    final config = fixture.config(
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path)},
      ),
    );

    String? worktreePath;
    String? workflowBranch;
    await fixture.withWiredCurrentDirectory(
      launchDir,
      config,
      runtimeCwd: runtimeCwd.path,
      body: (wiring) async {
        final definition = WorkflowDefinition(
          name: 'approval-hold',
          description: 'Stops in a non-terminal approval state',
          variables: const {
            'PROJECT': WorkflowVariable(required: true, description: 'Target project'),
            'BRANCH': WorkflowVariable(required: true, description: 'Requested branch'),
          },
          steps: const [
            WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
          ],
        );

        final run = await wiring.workflowService.start(definition, const {
          'PROJECT': 'alpha',
          'BRANCH': 'main',
        }, headless: true);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          final updated = await wiring.workflowService.get(run.id);
          if (updated?.status == WorkflowRunStatus.awaitingApproval) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect((await wiring.workflowService.get(run.id))?.status, WorkflowRunStatus.awaitingApproval);

        final activeWorkflowBranch = workflowBranch = 'dartclaw/workflow/${run.id.replaceAll('-', '')}/integration';
        const taskBranch = 'dartclaw/task-wf-active';
        final activeWorktreePath = worktreePath = p.join(workspaceDir.path, '.dartclaw', 'worktrees', 'wf-active');
        runGit(projectDir.path, ['branch', activeWorkflowBranch, 'main']);
        runGit(projectDir.path, ['worktree', 'add', activeWorktreePath, '-b', taskBranch, activeWorkflowBranch]);

        final task = await wiring.taskService.create(
          id: 'active-task',
          title: 'Active workflow task',
          description: 'Tracks a resumable workflow worktree',
          type: TaskType.coding,
          projectId: 'alpha',
          workflowRunId: run.id,
        );
        await wiring.taskService.updateFields(
          task.id,
          worktreeJson: {
            'path': activeWorktreePath,
            'branch': taskBranch,
            'createdAt': DateTime.parse('2026-01-01T00:00:00Z').toIso8601String(),
          },
        );
      },
    );

    expect(Directory(worktreePath!).existsSync(), isTrue);
    final workflowBranchResult = Process.runSync('git', [
      'branch',
      '--list',
      workflowBranch!,
    ], workingDirectory: projectDir.path);
    expect(workflowBranchResult.exitCode, 0);
    expect((workflowBranchResult.stdout as String).trim(), workflowBranch);
  });

  test('standalone coding tasks use the configured project clone instead of cwd', () async {
    final localRepoDir = fixture.seedGitRepo('local-repo', readme: '# local\n');
    final alphaSeedDir = fixture.seedGitRepo('alpha-seed', readme: '# alpha\n');
    final alphaOriginDir = Directory(p.join(tempDir.path, 'alpha-origin.git'))..createSync(recursive: true);
    final alphaRepoDir = Directory(p.join(tempDir.path, 'projects', 'alpha'));

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

    final config = fixture.config(
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', remote: alphaOriginDir.uri.toString())},
      ),
    );

    await fixture.withWiredCurrentDirectory(
      localRepoDir,
      config,
      harnessFactory: factory,
      body: (wiring) async {
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
        expect(worktreeDir, startsWith(p.join(localRepoDir.resolveSymbolicLinksSync(), '.dartclaw', 'worktrees')));
        expect(File(p.join(worktreeDir!, 'README.md')).readAsStringSync(), '# alpha\n');

        await waitFor(() => harnesses.any((h) => h.turnCallCount > 0), timeout: const Duration(seconds: 10));
        final worker = harnesses.firstWhere((h) => h.turnCallCount > 0);

        worker.completeSuccess();
        await waitFor(() => taskCompleted);
      },
    );
  });
}
