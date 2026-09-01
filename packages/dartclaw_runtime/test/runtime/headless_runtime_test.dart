import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskType;

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart'
    show
        DartclawRuntime,
        DartclawRuntimeExecutionStack,
        WorkflowStartPreconditionException,
        bootstrapWorkflowSkills,
        restoreCheckoutBeforeWorkflowBranchDeletion;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show OutputConfig, OutputFormat, WorkflowDefinition, WorkflowStep, WorkflowVariable;
import 'package:dartclaw_workflow/testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'headless_runtime_test_support.dart';

void main() {
  late Directory tempDir;
  late HeadlessRuntimeFixture fixture;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_headless_runtime_test_');
    fixture = HeadlessRuntimeFixture(tempDir);
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

    await fixture.runtime(
      cfg,
      skillIntrospector: FakeSkillIntrospector({
        'claude': {'andthen:review'},
      }),
    );

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

  test('TI01 base-service phase completes registry without starting any harness', () async {
    // Every registered provider's start() throws; the base-service phase must
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

    final staging = await fixture.stage(
      fixture.config(),
      harnessFactory: throwOnStartHarnessFactory(const ['claude', 'codex']),
    );

    expect(staging.workflowRegistry.getByName('ci-demo'), isNotNull);
  });

  test('loads canonical custom workflows without legacy deprecation warning', () async {
    final workflowsDir = Directory(p.join(tempDir.path, 'workflows', 'custom'))..createSync(recursive: true);
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
    final records = <LogRecord>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await sub.cancel();
      Logger.root.level = previousLevel;
    });

    final staging = await fixture.stage(fixture.config());

    expect(staging.workflowRegistry.getByName('my-review'), isNotNull);
    expect(
      records.where((record) => record.level == Level.WARNING && record.message.toLowerCase().contains('deprecated')),
      isEmpty,
    );
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

    final wired = await fixture.runtime(
      fixture.config(),
      skillIntrospector: FakeSkillIntrospector({
        'claude': {'andthen:review'},
      }),
    );

    final definition = wired.workflowRegistry.getByName('invalid-missing-skill');
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

    final run = await wired.workflowService.start(definition!, const {});
    final event = await failed.future.timeout(const Duration(seconds: 5));

    expect(event.runId, run.id);
    final failedRun = await wired.workflowService.get(run.id);
    expect(failedRun?.errorMessage, contains('Missing skills for provider "claude": missing-skill'));
    expect(await wired.taskService.list(), isEmpty);
  });

  test('loads legacy workflow yaml files directly under the data-dir workflows folder and warns', () async {
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
    final records = <LogRecord>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await sub.cancel();
      Logger.root.level = previousLevel;
    });

    final wired = await fixture.runtime(fixture.config());

    expect(wired.workflowRegistry.getByName('my-review'), isNotNull);
    final warnings = records
        .where(
          (record) =>
              record.level == Level.WARNING &&
              record.message.toLowerCase().contains('deprecated') &&
              record.message.contains('workflows/custom'),
        )
        .toList();
    expect(warnings, hasLength(1));
  });

  test('project workflow definition wins over canonical custom definition', () async {
    final customDir = Directory(p.join(tempDir.path, 'workflows', 'custom'))..createSync(recursive: true);
    File(p.join(customDir.path, 'dup.yaml')).writeAsStringSync('''
name: dup
description: Custom workflow
steps:
  - id: custom-step
    name: Custom Step
    prompt: Custom.
''');
    final projectDir = Directory(p.join(tempDir.path, 'live-project'))..createSync(recursive: true);
    final projectWorkflowsDir = Directory(p.join(projectDir.path, 'workflows'))..createSync(recursive: true);
    File(p.join(projectWorkflowsDir.path, 'dup.yaml')).writeAsStringSync('''
name: dup
description: Project workflow
steps:
  - id: project-step
    name: Project Step
    prompt: Project.
''');

    final cfg = fixture.config(
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path)},
      ),
    );
    final staging = await fixture.stage(cfg);

    final definition = staging.workflowRegistry.getByName('dup');
    expect(definition?.description, 'Project workflow');
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

    final wired = await fixture.runtime(
      cfg,
      skillIntrospector: FakeSkillIntrospector({
        'claude': {'andthen:review'},
      }),
    );

    expect(wired.workflowRegistry.getByName('local-only'), isNotNull);
  });

  test('workflow start rejects local-path branch mismatch even when BRANCH matches the observed branch', () async {
    final projectDir = fixture.seedGitRepo('live-project');
    runGitSync(projectDir.path, ['checkout', '-b', 'feature/local']);

    final cfg = fixture.config(
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path, branch: 'main')},
      ),
    );

    final wired = await fixture.runtime(cfg);

    final definition = branchGuardDefinition();

    await expectLater(
      () => wired.workflowService.start(definition, const {'PROJECT': 'alpha', 'BRANCH': 'feature/local'}),
      throwsA(
        isA<WorkflowStartPreconditionException>().having(
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

    final wired = await fixture.runtime(cfg);

    final definition = branchGuardDefinition();

    await expectLater(
      () => wired.workflowService.start(definition, const {'PROJECT': 'alpha', 'BRANCH': '--upload-pack=/tmp/pwn'}),
      throwsFormatException,
    );
  });

  test('workflow start infers BRANCH from HEAD for local-path projects when branch is omitted', () async {
    final projectDir = fixture.seedGitRepo('live-project');
    runGitSync(projectDir.path, ['checkout', '-b', 'feature/local']);

    final cfg = fixture.config(
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path, branch: '')},
      ),
    );

    final wired = await fixture.runtime(cfg);

    final definition = branchGuardDefinition();

    final run = await wired.workflowService.start(definition, const {'PROJECT': 'alpha'});
    expect(run.variablesJson['BRANCH'], 'feature/local');
  });

  test('workflow start propagates the configured workflow workspace into created tasks', () async {
    final workflowWorkspaceDir = Directory(p.join(tempDir.path, 'workflow-workspace'))..createSync(recursive: true);
    File(p.join(workflowWorkspaceDir.path, 'AGENTS.md')).writeAsStringSync('CLI workflow workspace rules');

    final cfg = fixture.config(workflow: WorkflowConfig(workspaceDir: workflowWorkspaceDir.path));

    final wired = await fixture.runtime(
      cfg,
      skillIntrospector: FakeSkillIntrospector({
        'claude': {'andthen:review'},
      }),
    );

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

    final run = await wired.workflowService.start(definition, const {});
    await waitFor(() => createdTask != null);
    await sub.cancel();

    expect(createdTask?.agentExecution?.workspaceDir, workflowWorkspaceDir.path);
    await wired.workflowService.cancel(run.id);
  });

  test('configures independent provider capacities without constructing harnesses', () async {
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

    final wired = await fixture.runtime(cfg, harnessFactory: factory, providers: {'codex', 'claude'});

    expect(capturedByProvider, isEmpty);
    expect(wired.requireExecutions.primary, isNull);
    expect(wired.requireExecutions.snapshot.providers['codex']!.configured, 3);
    expect(wired.requireExecutions.snapshot.providers['claude']!.configured, 1);
    expect(wired.requireExecutions.snapshot.cachedWorkers, 0);
  });

  test('standalone single-provider wiring creates no primary or worker', () async {
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
    );

    final wired = await fixture.runtime(cfg, harnessFactory: factory);

    expect(captured, isEmpty);
    expect(wired.requireExecutions.primary, isNull);
    expect(wired.requireExecutions.snapshot.providers['claude']!.configured, 1);
    expect(wired.requireExecutions.snapshot.availableWorkers, 1);
  });

  test('standalone capacity is scoped to referenced providers', () async {
    final capturedByProvider = <String, List<HarnessFactoryConfig>>{};
    final factory = capturingHarnessFactory(capturedByProvider, ['claude', 'goose']);

    final cfg = fixture.config(
      providers: const ProvidersConfig(entries: {'goose': ProviderEntry(executable: 'goose', poolSize: 1)}),
    );

    final wired = await fixture.runtime(cfg, harnessFactory: factory, providers: {'goose'});

    expect(capturedByProvider, isEmpty);
    expect(wired.requireExecutions.snapshot.providers.keys, {'goose'});
    expect(wired.requireExecutions.snapshot.providers['goose']!.configured, 1);
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

    final staging = await fixture.stage(cfg, harnessFactory: factory);

    await expectLater(
      () => staging.completeForExecution({'goose'}),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Provider "goose"'))),
    );
    expect(capturedByProvider, isEmpty);
  });

  test('standalone built-in provider also requires configured capacity', () async {
    final factory = capturingHarnessFactory(<String, List<HarnessFactoryConfig>>{}, ['claude', 'codex']);
    final cfg = fixture.config(
      providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1)}),
    );
    final staging = await fixture.stage(cfg, harnessFactory: factory);

    await expectLater(
      () => staging.completeForExecution({'codex'}),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Provider "codex"'))),
    );
  });

  test('standalone wiring provisions DC-native skills before registering shipped workflows', () async {
    final fakeHome = p.join(tempDir.path, 'provision-home');
    seedProviderAndThenSkills(fakeHome);
    final runner = FakeProvisionerProcessRunner();

    final wired = await fixture.runtime(
      fixture.config(),
      runtimeCwd: tempDir.path,
      runWorkflowSkillsBootstrap: true,
      skillProvisionerProcessRunner: runner.run,
      environment: {'HOME': fakeHome},
    );

    expect(
      File(p.join(tempDir.path, '.agents', 'skills', 'dartclaw-discover-andthen-spec', 'SKILL.md')).existsSync(),
      isTrue,
    );
    expect(unexpectedDataDirSkillEntries(tempDir.path), isEmpty);
    final registeredNames = wired.workflowRegistry.listAll().map((workflow) => workflow.name).toSet();
    expect(registeredNames, containsAll(['plan-and-implement', 'spec-and-implement', 'code-review']));
    expect(runner.calls.where((call) => call.executable.endsWith('install-skills.sh')), isEmpty);
  });

  test('dispose cleans up workflow task worktrees in headless mode', () async {
    final repoDir = fixture.seedGitRepo('repo', readme: '# test\n');
    final workspaceDir = Directory(p.join(tempDir.path, 'workspace'))..createSync(recursive: true);

    final worktreePath = p.join(workspaceDir.path, '.dartclaw', 'worktrees', 'task-1');
    runGitSync(repoDir.path, ['worktree', 'add', worktreePath, '-b', 'dartclaw/task-task-1', 'main']);

    final config = fixture.config(
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
    );

    await fixture.withWiredCurrentDirectory(
      repoDir,
      config,
      body: (runtime) async {
        expect(runtime.worktreeManager, isNotNull);

        final task = await runtime.taskService.create(
          id: 'task-1',
          title: 'Cleanup',
          description: 'Cleanup worktree',
          configJson: const {'needsWorktree': true},
          workflowRunId: 'run-123',
        );
        await runtime.taskService.updateFields(
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
    runGitSync(repoDir.path, ['checkout', '-b', 'feat/0.16.5']);
    runGitSync(repoDir.path, ['checkout', '-b', 'dartclaw/workflow/run123/integration']);

    final restoreError = await restoreCheckoutBeforeWorkflowBranchDeletion(
      projectDir: repoDir.path,
      workflowBranches: const {'dartclaw/workflow/run123/integration'},
      restoreRef: 'feat/0.16.5',
    );

    expect(restoreError, isNull);
    final currentBranch = Process.runSync('git', ['branch', '--show-current'], workingDirectory: repoDir.path);
    expect(currentBranch.exitCode, 0);
    expect((currentBranch.stdout as String).trim(), 'feat/0.16.5');
    runGitSync(repoDir.path, ['branch', '--delete', '--force', 'dartclaw/workflow/run123/integration']);
  });

  test('workflow cleanup can restore from remote-tracking branch ref', () async {
    final repoDir = fixture.seedGitRepo('repo', readme: '# test\n');
    runGitSync(repoDir.path, ['update-ref', 'refs/remotes/origin/main', 'HEAD']);
    runGitSync(repoDir.path, ['checkout', '-b', 'dartclaw/workflow/run123/integration']);

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
    runGitSync(repoDir.path, ['branch', '--delete', '--force', 'dartclaw/workflow/run123/integration']);
  });

  test('workflow cleanup restores remote-tracking ref exactly when local branch is stale', () async {
    final repoDir = fixture.seedGitRepo('repo', readme: '# local main\n');
    final localMain = Process.runSync('git', ['rev-parse', 'HEAD'], workingDirectory: repoDir.path);
    runGitSync(repoDir.path, ['checkout', '--orphan', 'remote-state']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# remote main\n');
    runGitSync(repoDir.path, ['add', 'README.md']);
    runGitSync(repoDir.path, ['commit', '-m', 'remote-main']);
    runGitSync(repoDir.path, ['update-ref', 'refs/remotes/origin/main', 'HEAD']);
    final remoteMain = Process.runSync('git', ['rev-parse', 'HEAD'], workingDirectory: repoDir.path);
    runGitSync(repoDir.path, ['checkout', 'main']);
    runGitSync(repoDir.path, ['checkout', '-b', 'dartclaw/workflow/run123/integration']);

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
    runGitSync(repoDir.path, ['branch', '--delete', '--force', 'dartclaw/workflow/run123/integration']);
    runGitSync(repoDir.path, ['branch', '--delete', '--force', 'remote-state']);
  });

  test('workflow cleanup does not switch away from dirty workflow branch', () async {
    final repoDir = fixture.seedGitRepo('repo', readme: '# test\n');
    runGitSync(repoDir.path, ['checkout', '-b', 'feat/0.16.5']);
    runGitSync(repoDir.path, ['checkout', '-b', 'dartclaw/workflow/run123/integration']);
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
    runGitSync(runtimeCwd.path, ['checkout', '-b', 'runtime-feature']);

    final config = fixture.config();

    await fixture.withWiredCurrentDirectory(
      launchDir,
      config,
      runtimeCwd: runtimeCwd.path,
      body: (runtime) async {
        final definition = branchGuardDefinition(name: 'local-runtime', projectRequired: false);

        final run = await runtime.workflowService.start(definition, const {
          'PROJECT': '_local',
          'BRANCH': 'runtime-feature',
        });
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
    DartclawRuntime? disposable;
    try {
      final wired = disposable = await fixture.runtime(
        config,
        runtimeCwd: runtimeCwd.path,
        skillIntrospector: FakeSkillIntrospector({
          'claude': {'dartclaw-discover-andthen-plan'},
        }),
        autoDispose: false,
      );

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
      final statusSub = wired.eventBus
          .on<WorkflowRunStatusChangedEvent>()
          .where((event) => runId != null && event.runId == runId && event.newStatus == WorkflowRunStatus.completed)
          .listen((_) {
            if (!completion.isCompleted) {
              completion.complete();
            }
          });
      addTearDown(statusSub.cancel);
      final sub = wired.eventBus
          .on<TaskStatusChangedEvent>()
          .where((event) => event.newStatus == TaskStatus.queued)
          .listen((event) async {
            final session = await wired.sessionService.createSession(type: SessionType.task);
            await wired.taskService.updateFields(event.taskId, sessionId: session.id);
            final execution = await wired.workflowStepExecutionRepository.getByTaskId(event.taskId);
            expect(execution, isNotNull);
            await wired.workflowStepExecutionRepository.update(
              execution!.copyWith(
                structuredOutputJson: jsonEncode({
                  '_envelopeVersion': 1,
                  'outputs': {
                    'prd': 'docs/specs/demo/prd.md',
                    'plan': 'docs/specs/demo/plan.json',
                    'story_specs': {
                      'items': [
                        {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
                      ],
                    },
                  },
                  'step_outcome': {'outcome': 'succeeded', 'reason': ''},
                }),
              ),
            );
            await wired.taskService.transition(event.taskId, TaskStatus.running);
            await wired.taskService.transition(event.taskId, TaskStatus.accepted);
          });
      addTearDown(sub.cancel);
      final run = await wired.workflowService.start(definition, const {});
      runId = run.id;
      final current = await wired.workflowService.get(run.id);
      if (current?.status == WorkflowRunStatus.completed && !completion.isCompleted) {
        completion.complete();
      }

      await completion.future.timeout(const Duration(seconds: 5));
      final completed = await wired.workflowService.get(run.id);
      expect(completed?.status, WorkflowRunStatus.completed);
    } finally {
      await disposable?.shutdown();
      Directory.current = savedCwd;
    }
  });

  test('tracked workflow git cleanup for named projects runs in the project checkout', () async {
    final launchDir = Directory(p.join(tempDir.path, 'launch-repo'))..createSync(recursive: true);
    final runtimeCwd = Directory(p.join(tempDir.path, 'runtime-cwd'))..createSync(recursive: true);
    final projectDir = fixture.seedGitRepo('project-alpha', readme: '# project\n');
    final workspaceDir = Directory(p.join(tempDir.path, 'workspace'))..createSync(recursive: true);

    final worktreePath = p.join(workspaceDir.path, '.dartclaw', 'worktrees', 'task-1');
    runGitSync(projectDir.path, ['worktree', 'add', worktreePath, '-b', 'dartclaw/task-task-1', 'main']);

    final config = fixture.config(
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path)},
      ),
    );

    await fixture.withWiredCurrentDirectory(
      launchDir,
      config,
      runtimeCwd: runtimeCwd.path,
      body: (runtime) async {
        final task = await runtime.taskService.create(
          id: 'task-1',
          title: 'Cleanup',
          description: 'Cleanup worktree',
          configJson: const {'needsWorktree': true},
          projectId: 'alpha',
          workflowRunId: 'run-123',
        );
        await runtime.taskService.updateFields(
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
      body: (runtime) async {
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

        final run = await runtime.workflowService.start(definition, const {'PROJECT': 'alpha', 'BRANCH': 'main'});
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          final updated = await runtime.workflowService.get(run.id);
          if (updated?.status == WorkflowRunStatus.awaitingApproval) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect((await runtime.workflowService.get(run.id))?.status, WorkflowRunStatus.awaitingApproval);

        final activeWorkflowBranch = workflowBranch = 'dartclaw/workflow/${run.id.replaceAll('-', '')}/integration';
        const taskBranch = 'dartclaw/task-wf-active';
        final activeWorktreePath = worktreePath = p.join(workspaceDir.path, '.dartclaw', 'worktrees', 'wf-active');
        runGitSync(projectDir.path, ['branch', activeWorkflowBranch, 'main']);
        runGitSync(projectDir.path, ['worktree', 'add', activeWorktreePath, '-b', taskBranch, activeWorkflowBranch]);

        final task = await runtime.taskService.create(
          id: 'active-task',
          title: 'Active workflow task',
          description: 'Tracks a resumable workflow worktree',
          configJson: const {'needsWorktree': true},
          projectId: 'alpha',
          workflowRunId: run.id,
        );
        await runtime.taskService.updateFields(
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

  test('standalone worker-leased one-shot teardown records in-flight sibling task as cancelled', () async {
    final launchDir = Directory(p.join(tempDir.path, 'launch-repo'))..createSync(recursive: true);
    final runtimeCwd = fixture.seedGitRepo('runtime-cwd', readme: '# runtime\n');
    final heldHarness = FakeAgentHarness();
    final cancelled = Completer<void>();
    final failedRunStatuses = <WorkflowRunStatusChangedEvent>[];
    final taskErrorEvents = <TaskEventCreatedEvent>[];
    final config = fixture.config();
    var disposed = false;

    final savedCwd = Directory.current;
    Directory.current = launchDir;
    DartclawRuntime? disposable;
    try {
      final wired = disposable = await fixture.runtime(
        config,
        runtimeCwd: runtimeCwd.path,
        autoDispose: false,
        harnessFactory: HarnessFactory()..register('claude', (_) => heldHarness),
      );
      final taskStatusSub = wired.eventBus
          .on<TaskStatusChangedEvent>()
          .where((event) => event.taskId == 'sibling-one-shot' && event.newStatus == TaskStatus.cancelled)
          .listen((_) {
            if (!cancelled.isCompleted) {
              cancelled.complete();
            }
          });
      addTearDown(taskStatusSub.cancel);
      final runStatusSub = wired.eventBus.on<WorkflowRunStatusChangedEvent>().listen((event) {
        if (event.newStatus == WorkflowRunStatus.failed) {
          failedRunStatuses.add(event);
        }
      });
      addTearDown(runStatusSub.cancel);
      final taskEventSub = wired.eventBus
          .on<TaskEventCreatedEvent>()
          .where((event) => event.taskId == 'sibling-one-shot' && event.kind == TaskEventKind.taskError.name)
          .listen(taskErrorEvents.add);
      addTearDown(taskEventSub.cancel);

      final definition = WorkflowDefinition(
        name: 'approval-hold-with-sibling',
        description: 'Stops in approval while a sibling one-shot is in flight',
        steps: const [
          WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
        ],
      );
      final run = await wired.workflowService.start(definition, const {});
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        final updated = await wired.workflowService.get(run.id);
        if (updated?.status == WorkflowRunStatus.awaitingApproval) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect((await wired.workflowService.get(run.id))?.status, WorkflowRunStatus.awaitingApproval);

      await wired.taskService.create(
        id: 'sibling-one-shot',
        title: 'Sibling one-shot',
        description: 'Still running when approval-held standalone run tears down.',
        workflowRunId: run.id,
        stepIndex: 1,
        provider: 'claude',
        agentExecutionId: 'ae-sibling-one-shot',
        configJson: const {'reviewMode': 'auto-accept'},
      );
      final workflowStepExecutions = wired.workflowStepExecutionRepository;
      await workflowStepExecutions.create(
        WorkflowStepExecution(
          taskId: 'sibling-one-shot',
          agentExecutionId: 'ae-sibling-one-shot',
          workflowRunId: run.id,
          stepIndex: 1,
          stepId: 'sibling',
          stepType: WorkflowTaskType.agent.toJson(),
        ),
      );
      await wired.taskService.transition('sibling-one-shot', TaskStatus.queued, trigger: 'workflow');
      unawaited(wired.taskExecutor!.pollOnce());
      try {
        await heldHarness.turnInvoked.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        final task = await wired.taskService.get('sibling-one-shot');
        fail('Sibling workflow harness turn did not run; task=${task?.status.name} config=${task?.configJson}');
      }

      final dispose = wired.shutdown();
      await cancelled.future.timeout(const Duration(seconds: 5));
      expect(heldHarness.cancelCalled, isTrue);
      expect((await wired.taskService.get('sibling-one-shot'))?.status, TaskStatus.cancelled);
      await dispose;
      disposed = true;
      expect(taskErrorEvents, isEmpty);
      expect(failedRunStatuses, isEmpty);
    } finally {
      if (!disposed) {
        await disposable?.shutdown();
      }
      Directory.current = savedCwd;
    }
  });
}
