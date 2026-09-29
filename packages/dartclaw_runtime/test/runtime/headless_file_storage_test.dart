import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart'
    show DartclawRuntime, HeadlessRuntimeStaging, StandaloneExecutionLeaseException;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinition, WorkflowStep, WorkflowTaskType;
import 'package:dartclaw_workflow/testing.dart' show FakeProviderAuthPreflight;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('standalone persists task and KV state across runtime restarts without PostgreSQL', () async {
    final dataDir = Directory.systemTemp.createTempSync('dartclaw_headless_file_storage_');
    addTearDown(() {
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    });
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 0)}),
      database: const DatabaseConfig(url: 'postgresql://127.0.0.1:1/unavailable'),
      server: ServerConfig(dataDir: dataDir.path),
    );
    final harnessFactory = HarnessFactory()..register('claude', (_) => FakeAgentHarness());

    Future<HeadlessRuntimeStaging> stage() => DartclawRuntime.stageHeadless(
      config,
      dataDir: dataDir.path,
      harnessFactory: harnessFactory,
      stderrLine: (_) {},
      exitFn: (code) => throw StateError('Unexpected exit($code)'),
      runWorkflowSkillsBootstrap: false,
      runtimeCwd: dataDir.path,
      environment: {'HOME': p.join(dataDir.path, 'home')},
      providerAuthPreflight: FakeProviderAuthPreflight(),
    );

    final first = await (await stage()).completeForLifecycle();
    expect(first.sessionService.baseDir, p.join(config.standaloneDir, 'sessions'));
    await first.taskService.create(
      id: 'persisted-task',
      title: 'Persisted task',
      description: 'Survives process restart',
      provider: 'claude',
    );
    await first.kvService.set('standalone-probe', 'stored');
    await first.shutdown();

    expect(File(config.standaloneExecutionPath).existsSync(), isTrue);
    expect(File(config.kvPath).existsSync(), isFalse);
    expect(Directory(config.sessionsDir).existsSync(), isFalse);

    final second = await (await stage()).completeForLifecycle();
    addTearDown(second.shutdown);
    expect((await second.taskService.get('persisted-task'))?.title, 'Persisted task');
    expect(await second.agentExecutionRepository.get('ae-persisted-task'), isNotNull);
    expect(await second.kvService.get('standalone-probe'), 'stored');
  });

  test('lifecycle staging does not start a configured remote project clone', () async {
    final dataDir = Directory.systemTemp.createTempSync('dartclaw_headless_controller_project_');
    addTearDown(() {
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    });
    final config = DartclawConfig(
      server: ServerConfig(dataDir: dataDir.path),
      projects: const ProjectConfig(
        definitions: {'remote': ProjectDefinition(id: 'remote', remote: 'file:///does-not-exist/remote.git')},
      ),
    );
    final staging = await DartclawRuntime.stageHeadless(
      config,
      dataDir: dataDir.path,
      harnessFactory: HarnessFactory(),
      stderrLine: (_) {},
      exitFn: (code) => throw StateError('Unexpected exit($code)'),
      runWorkflowSkillsBootstrap: false,
      runtimeCwd: dataDir.path,
      environment: {'HOME': p.join(dataDir.path, 'home')},
    );
    final controller = await staging.completeForLifecycle();
    expect(Directory(config.projectsClonesDir).existsSync(), isFalse);
    expect(File(p.join(dataDir.path, 'projects.json')).existsSync(), isFalse);
    await controller.shutdown();
  });

  test('standalone workflow execution reloads its completed run from the file store', () async {
    final dataDir = Directory.systemTemp.createTempSync('dartclaw_headless_file_workflow_');
    addTearDown(() {
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    });
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1)}),
      database: const DatabaseConfig(url: 'postgresql://127.0.0.1:1/unavailable'),
      server: ServerConfig(dataDir: dataDir.path),
      workflow: WorkflowConfig(workspaceDir: dataDir.path),
    );
    final worker = FakeAgentHarness();
    final harnessFactory = HarnessFactory()..register('claude', (_) => worker);

    Future<HeadlessRuntimeStaging> stage() => DartclawRuntime.stageHeadless(
      config,
      dataDir: dataDir.path,
      harnessFactory: harnessFactory,
      stderrLine: (_) {},
      exitFn: (code) => throw StateError('Unexpected exit($code)'),
      runWorkflowSkillsBootstrap: false,
      runtimeCwd: dataDir.path,
      environment: {'HOME': p.join(dataDir.path, 'home')},
      providerAuthPreflight: FakeProviderAuthPreflight(),
    );

    final first = await (await stage()).completeForExecution({'claude'});
    expect(Directory(p.join(config.standaloneDir, 'sessions')).existsSync(), isTrue);
    first.taskExecutor!.stopPolling();
    final run = await first.workflowService.start(
      const WorkflowDefinition(
        name: 'persisted-workflow',
        description: 'Records one completed workflow turn',
        steps: [
          WorkflowStep(id: 'run', name: 'Run', taskType: WorkflowTaskType.agent, prompts: ['Reply done.']),
        ],
      ),
      const {},
    );
    final taskCreated = Completer<void>();
    Future<void> pollWhenReady() async {
      while ((await first.taskService.list()).every((task) => task.workflowRunId != run.id)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      taskCreated.complete();
      await first.taskExecutor!.pollOnce();
    }

    unawaited(pollWhenReady());
    await taskCreated.future.timeout(const Duration(seconds: 5));
    await worker.turnInvoked.timeout(const Duration(seconds: 5));
    worker.completeSuccess(const TurnResult(finalText: 'Done.'));
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while ((await first.workflowService.get(run.id))?.status != WorkflowRunStatus.completed &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect((await first.workflowService.get(run.id))?.status, WorkflowRunStatus.completed);
    await first.shutdown();

    final second = await (await stage()).completeForLifecycle();
    addTearDown(second.shutdown);
    expect((await second.workflowService.get(run.id))?.status, WorkflowRunStatus.completed);
    expect(
      (await second.taskService.list()).singleWhere((task) => task.workflowRunId == run.id).status,
      TaskStatus.accepted,
    );
  });

  test('an active standalone workflow observes pause from a separate runtime', () async {
    final dataDir = Directory.systemTemp.createTempSync('dartclaw_headless_file_pause_');
    addTearDown(() {
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    });
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1)}),
      database: const DatabaseConfig(url: 'postgresql://127.0.0.1:1/unavailable'),
      server: ServerConfig(dataDir: dataDir.path),
      workflow: WorkflowConfig(workspaceDir: dataDir.path),
    );
    final worker = FakeAgentHarness();
    final harnessFactory = HarnessFactory()..register('claude', (_) => worker);

    Future<HeadlessRuntimeStaging> stage({HarnessFactory? factory}) => DartclawRuntime.stageHeadless(
      config,
      dataDir: dataDir.path,
      harnessFactory: factory ?? harnessFactory,
      stderrLine: (_) {},
      exitFn: (code) => throw StateError('Unexpected exit($code)'),
      runWorkflowSkillsBootstrap: false,
      runtimeCwd: dataDir.path,
      environment: {'HOME': p.join(dataDir.path, 'home')},
      providerAuthPreflight: FakeProviderAuthPreflight(),
    );

    final owner = await (await stage()).completeForExecution({'claude'});
    owner.taskExecutor!.stopPolling();
    final run = await owner.workflowService.start(
      const WorkflowDefinition(
        name: 'externally-paused-workflow',
        description: 'Pauses before a second step',
        steps: [
          WorkflowStep(id: 'first', name: 'First', taskType: WorkflowTaskType.agent, prompts: ['Wait.']),
          WorkflowStep(id: 'second', name: 'Second', taskType: WorkflowTaskType.agent, prompts: ['Continue.']),
        ],
      ),
      const {},
    );
    final taskDeadline = DateTime.now().add(const Duration(seconds: 5));
    while ((await owner.taskService.list()).every((task) => task.workflowRunId != run.id) &&
        DateTime.now().isBefore(taskDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final poll = owner.taskExecutor!.pollOnce();
    unawaited(poll);
    await worker.turnInvoked.timeout(const Duration(seconds: 5));

    final siblingWorker = FakeAgentHarness();
    final siblingFactory = HarnessFactory()..register('claude', (_) => siblingWorker);
    final siblingStage = await stage(factory: siblingFactory);
    await expectLater(
      siblingStage.completeForExecution({'claude'}),
      throwsA(
        isA<StandaloneExecutionLeaseException>().having(
          (error) => error.message,
          'message',
          contains('already active'),
        ),
      ),
    );
    await siblingStage.dispose();
    expect((await owner.workflowService.get(run.id))?.status, WorkflowRunStatus.running);
    expect(siblingWorker.turnCallCount, 0);

    final observedPause = owner.eventBus
        .on<WorkflowRunStatusChangedEvent>()
        .firstWhere((event) => event.runId == run.id && event.newStatus == WorkflowRunStatus.paused)
        .timeout(const Duration(seconds: 5));
    await owner.kvService.set('turn:legacy', 'preserve while controlled');
    final activeTurnTemp = File(p.join(config.standaloneDir, 'turn_state.json.active.tmp'))
      ..writeAsStringSync('active owner write');
    final controllerStage = await stage().timeout(const Duration(seconds: 5));
    final controller = await controllerStage.completeForLifecycle().timeout(const Duration(seconds: 5));
    await controller.workflowService.pause(run.id).timeout(const Duration(seconds: 5));
    await controller.shutdown().timeout(const Duration(seconds: 5));
    expect(activeTurnTemp.readAsStringSync(), 'active owner write');
    expect(File(p.join(config.standaloneDir, 'kv.json')).readAsStringSync(), contains('turn:legacy'));
    await observedPause;
    worker.completeSuccess(const TurnResult(finalText: 'Done.'));
    await poll.timeout(const Duration(seconds: 5));

    expect((await owner.workflowService.get(run.id))?.status, WorkflowRunStatus.paused);
    expect((await owner.taskService.list()).where((task) => task.workflowRunId == run.id), hasLength(1));
    expect(worker.turnCallCount, 1);
    await owner.shutdown().timeout(const Duration(seconds: 5));

    final later = await (await stage(factory: siblingFactory)).completeForExecution({'claude'});
    later.taskExecutor!.stopPolling();
    expect((await later.workflowService.get(run.id))?.status, WorkflowRunStatus.paused);
    await later.shutdown().timeout(const Duration(seconds: 5));
  });
}
