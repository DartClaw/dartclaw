import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeSkillIntrospector;
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

final class _ThrowingSkillIntrospector implements SkillIntrospector {
  final calls = <({String provider, String? executable})>[];

  @override
  Future<Set<String>> listAvailable({
    required String provider,
    String? executable,
    Map<String, dynamic> providerOptions = const <String, dynamic>{},
  }) async {
    calls.add((provider: provider, executable: executable));
    throw StateError('probe unavailable');
  }
}

void main() {
  late WorkflowExecutorHarness h;

  setUp(() {
    h = WorkflowExecutorHarness()..setUp();
  });

  tearDown(() => h.tearDown());

  test('bad skill ref loads but fails execution preflight before task dispatch', () async {
    final definition = WorkflowDefinitionParser().parse('''
name: preflight
description: preflight test
steps:
  - id: good
    name: Good
    provider: claude
    skill: andthen:review
  - id: bad
    name: Bad
    provider: claude
    skill: andthn:review
''');
    final report = WorkflowDefinitionValidator().validate(definition);
    expect(report.hasErrors, isFalse);

    final introspector = FakeSkillIntrospector({
      'claude': {'andthen:review'},
    });
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(
        providerExecutables: {'claude': '/bin/claude'},
        providerOptions: {
          'claude': {'inherit_user_settings': false},
        },
      ),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      await h.completeTask(event.taskId);
    });
    addTearDown(sub.cancel);

    await executor.execute(run, definition, WorkflowContext());

    final failedRun = await h.repository.getById(run.id);
    expect(failedRun?.status, WorkflowRunStatus.failed);
    expect(failedRun?.errorMessage, contains('Missing skills for provider "claude": andthn:review'));
    expect(failedRun?.errorMessage, contains('Available: 1 skills'));
    expect(await h.taskService.list(), isEmpty);
    expect(introspector.calls, [(provider: 'claude', executable: '/bin/claude')]);
    expect(introspector.providerOptionsByProvider['claude'], {'inherit_user_settings': false});
  });

  test('probes each provider once and de-duplicates refs before reporting missing skills', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-multi-provider',
      description: 'preflight multi-provider test',
      steps: [
        WorkflowStep(id: 'one', name: 'One', provider: 'claude', skill: 'andthen:review'),
        WorkflowStep(id: 'two', name: 'Two', provider: 'claude', skill: 'andthen:review'),
        WorkflowStep(id: 'three', name: 'Three', provider: 'codex', skill: 'dartclaw-validate-workflow'),
      ],
    );
    final introspector = FakeSkillIntrospector({
      'claude': {'andthen:review'},
      'codex': const <String>{},
    });
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(
        providerExecutables: {'claude': 'claude-a', 'codex': 'codex-a'},
      ),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    await executor.execute(run, definition, WorkflowContext());

    expect(introspector.calls, [
      (provider: 'claude', executable: 'claude-a'),
      (provider: 'codex', executable: 'codex-a'),
    ]);
    expect(await h.taskService.list(), isEmpty);
  });

  test('records probe failures as preflight run failures before task dispatch', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-probe-failure',
      description: 'preflight probe failure test',
      steps: [WorkflowStep(id: 'review', name: 'Review', provider: 'claude', skill: 'andthen:review')],
    );
    final introspector = _ThrowingSkillIntrospector();
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(providerExecutables: {'claude': '/bin/claude'}),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    await executor.execute(run, definition, WorkflowContext());

    final failedRun = await h.repository.getById(run.id);
    expect(failedRun?.status, WorkflowRunStatus.failed);
    expect(
      failedRun?.errorMessage,
      contains('Skill introspection failed for provider "claude" using "/bin/claude": Bad state: probe unavailable'),
    );
    expect(await h.taskService.list(), isEmpty);
    expect(introspector.calls, [(provider: 'claude', executable: '/bin/claude')]);
  });

  test('reports unconfigured providers before issuing an introspection probe', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-unconfigured-provider',
      description: 'preflight unconfigured provider test',
      steps: [WorkflowStep(id: 'review', name: 'Review', provider: 'missing-provider', skill: 'andthen:review')],
    );
    final introspector = FakeSkillIntrospector({
      'missing-provider': {'andthen:review'},
    });
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(
        defaultProvider: 'claude',
        configuredProviders: {'claude'},
        providerExecutables: {'claude': '/bin/claude'},
      ),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    await executor.execute(run, definition, WorkflowContext());

    final failedRun = await h.repository.getById(run.id);
    expect(failedRun?.status, WorkflowRunStatus.failed);
    expect(failedRun?.errorMessage, contains('provider "missing-provider" is not configured for runtime preflight'));
    expect(await h.taskService.list(), isEmpty);
    expect(introspector.calls, isEmpty);
  });

  test('uses Codex-visible AndThen skill name after preflight resolves authored ref', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-codex-alias',
      description: 'preflight codex alias test',
      steps: [WorkflowStep(id: 'review', name: 'Review', provider: 'codex', skill: 'andthen:review')],
    );
    final introspector = FakeSkillIntrospector({
      'codex': {'andthen-review'},
    });
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(providerExecutables: {'codex': '/bin/codex'}),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    Task? capturedTask;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      capturedTask = await h.taskService.get(event.taskId);
      await h.completeTask(event.taskId);
    });
    addTearDown(sub.cancel);

    await executor.execute(run, definition, WorkflowContext());

    expect(introspector.calls, [(provider: 'codex', executable: '/bin/codex')]);
    expect(capturedTask?.description, startsWith(r'$andthen-review'));
    expect(capturedTask?.description, isNot(startsWith(r'$andthen:review')));
  });

  test('uses Codex-visible namespace alias for non-AndThen skill refs', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-codex-generic-alias',
      description: 'preflight codex generic alias test',
      steps: [WorkflowStep(id: 'plan', name: 'Plan', provider: 'codex', skill: 'otherframework:plan')],
    );
    final introspector = FakeSkillIntrospector({
      'codex': {'otherframework-plan'},
    });
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(providerExecutables: {'codex': '/bin/codex'}),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    Task? capturedTask;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      capturedTask = await h.taskService.get(event.taskId);
      await h.completeTask(event.taskId);
    });
    addTearDown(sub.cancel);

    await executor.execute(run, definition, WorkflowContext());

    final finishedRun = await h.repository.getById(run.id);
    expect(finishedRun?.status, isNot(WorkflowRunStatus.failed));
    expect(introspector.calls, [(provider: 'codex', executable: '/bin/codex')]);
    expect(capturedTask?.description, startsWith(r'$otherframework-plan'));
    expect(capturedTask?.description, isNot(startsWith(r'$otherframework:plan')));
  });

  test('reports Codex-visible AndThen skill alias when a preflight skill is missing', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-codex-missing-alias',
      description: 'preflight codex missing alias test',
      steps: [WorkflowStep(id: 'implement', name: 'Implement', provider: 'codex', skill: 'andthen:exec-spec')],
    );
    final introspector = FakeSkillIntrospector({'codex': const <String>{}});
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(providerExecutables: {'codex': '/bin/codex'}),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    await executor.execute(run, definition, WorkflowContext());

    final failedRun = await h.repository.getById(run.id);
    expect(failedRun?.status, WorkflowRunStatus.failed);
    expect(failedRun?.errorMessage, contains('andthen:exec-spec (searched as andthen-exec-spec)'));
    expect(await h.taskService.list(), isEmpty);
    expect(introspector.calls, [(provider: 'codex', executable: '/bin/codex')]);
  });

  test('resolves Codex-visible AndThen skill for a custom provider alias declaring family=codex', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-codex-family-alias',
      description: 'preflight codex family alias test',
      steps: [WorkflowStep(id: 'review', name: 'Review', provider: 'my_agent', skill: 'andthen:review')],
    );
    final introspector = FakeSkillIntrospector({
      'my_agent': {'andthen-review'},
    });
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(
        providerExecutables: {'my_agent': '/opt/bin/custom-agent'},
        providerOptions: {
          'my_agent': {'family': 'codex'},
        },
      ),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    Task? capturedTask;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      capturedTask = await h.taskService.get(event.taskId);
      await h.completeTask(event.taskId);
    });
    addTearDown(sub.cancel);

    await executor.execute(run, definition, WorkflowContext());

    // The configured family alias must translate `andthen:review` to the
    // Codex-visible `andthen-review` instead of rejecting the workflow.
    final finishedRun = await h.repository.getById(run.id);
    expect(finishedRun?.status, isNot(WorkflowRunStatus.failed));
    expect(introspector.calls, [(provider: 'my_agent', executable: '/opt/bin/custom-agent')]);
    expect(introspector.providerOptionsByProvider['my_agent'], {'family': 'codex'});
    expect(capturedTask?.description, contains('andthen-review'));
    expect(capturedTask?.description, isNot(contains('andthen:review')));
  });

  test('resolves Codex-visible AndThen skill for a custom provider classified by executable name', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-codex-executable-alias',
      description: 'preflight codex executable alias test',
      steps: [WorkflowStep(id: 'review', name: 'Review', provider: 'my_agent', skill: 'andthen:review')],
    );
    final introspector = FakeSkillIntrospector({
      'my_agent': {'andthen-review'},
    });
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      // No `family` option: the codex family must be inferred from the executable name,
      // matching how the introspector probed — preflight must not reject the workflow.
      skillPreflightConfig: const WorkflowSkillPreflightConfig(providerExecutables: {'my_agent': '/opt/bin/codex-cli'}),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    Task? capturedTask;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      capturedTask = await h.taskService.get(event.taskId);
      await h.completeTask(event.taskId);
    });
    addTearDown(sub.cancel);

    await executor.execute(run, definition, WorkflowContext());

    final finishedRun = await h.repository.getById(run.id);
    expect(finishedRun?.status, isNot(WorkflowRunStatus.failed));
    expect(introspector.calls, [(provider: 'my_agent', executable: '/opt/bin/codex-cli')]);
    expect(capturedTask?.description, contains('andthen-review'));
    expect(capturedTask?.description, isNot(contains('andthen:review')));
  });

  test('uses default provider for Codex-visible skill activation when step omits provider', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-default-provider',
      description: 'preflight default provider test',
      steps: [WorkflowStep(id: 'review', name: 'Review', skill: 'andthen:review')],
    );
    final introspector = FakeSkillIntrospector({
      'codex': {'andthen-review'},
    });
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(
        defaultProvider: 'codex',
        providerExecutables: {'codex': '/bin/codex'},
      ),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    Task? capturedTask;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      capturedTask = await h.taskService.get(event.taskId);
      await h.completeTask(event.taskId);
    });
    addTearDown(sub.cancel);

    await executor.execute(run, definition, WorkflowContext());

    expect(introspector.calls, [(provider: 'codex', executable: '/bin/codex')]);
    expect(capturedTask?.description, startsWith(r'$andthen-review'));
    expect(capturedTask?.provider, 'codex');
  });

  test('uses role-default provider for preflight, activation, and queued task', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-role-default-provider',
      description: 'preflight role default provider test',
      stepDefaults: [StepConfigDefault(match: 'review', provider: '@reviewer')],
      steps: [WorkflowStep(id: 'review', name: 'Review', skill: 'andthen:review')],
    );
    final introspector = FakeSkillIntrospector({
      'codex': {'andthen-review'},
    });
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(
        defaultProvider: 'claude',
        providerExecutables: {'claude': '/bin/claude', 'codex': '/bin/codex'},
      ),
      roleDefaults: const WorkflowRoleDefaults(reviewer: WorkflowRoleDefault(provider: 'codex')),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    Task? capturedTask;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      capturedTask = await h.taskService.get(event.taskId);
      await h.completeTask(event.taskId);
    });
    addTearDown(sub.cancel);

    await executor.execute(run, definition, WorkflowContext());

    expect(introspector.calls, [(provider: 'codex', executable: '/bin/codex')]);
    expect(capturedTask?.description, startsWith(r'$andthen-review'));
    expect(capturedTask?.provider, 'codex');
  });

  test('uses default provider for map iteration task provider', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-map-default-provider',
      description: 'preflight map default provider test',
      steps: [WorkflowStep(id: 'review', name: 'Review', skill: 'andthen:review', mapOver: 'items')],
    );
    final introspector = FakeSkillIntrospector({
      'codex': {'andthen-review'},
    });
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(
        defaultProvider: 'codex',
        providerExecutables: {'codex': '/bin/codex'},
      ),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    Task? capturedTask;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      capturedTask = await h.taskService.get(event.taskId);
      await h.completeTask(event.taskId);
    });
    addTearDown(sub.cancel);

    await executor.execute(
      run,
      definition,
      WorkflowContext(
        data: {
          'items': ['one'],
        },
      ),
    );

    expect(introspector.calls, [(provider: 'codex', executable: '/bin/codex')]);
    expect(capturedTask?.description, startsWith(r'$andthen-review'));
    expect(capturedTask?.provider, 'codex');
  });

  test('preflights continued-session skills against the root provider', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-continue-session-provider',
      description: 'preflight continue session provider test',
      steps: [
        WorkflowStep(id: 'implement', name: 'Implement', provider: 'codex', skill: 'andthen:exec-spec'),
        WorkflowStep(
          id: 'review',
          name: 'Review',
          provider: 'claude',
          skill: 'andthen:quick-review',
          continueSession: 'implement',
        ),
      ],
    );
    final introspector = FakeSkillIntrospector({
      'codex': {'andthen-exec-spec', 'andthen-quick-review'},
    });
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(
        providerExecutables: {'claude': '/bin/claude', 'codex': '/bin/codex'},
      ),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    const rootSessionId = '550e8400-e29b-41d4-a716-446655440111';
    final capturedTasks = <Task>[];
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      final task = await h.taskService.get(event.taskId);
      if (task != null) capturedTasks.add(task);
      if (capturedTasks.length == 1) {
        await h.taskService.updateFields(event.taskId, sessionId: rootSessionId);
      }
      await h.completeTask(event.taskId);
    });
    addTearDown(sub.cancel);

    await executor.execute(run, definition, WorkflowContext());

    expect(introspector.calls, [(provider: 'codex', executable: '/bin/codex')]);
    expect(capturedTasks, hasLength(2));
    expect(capturedTasks.last.description, startsWith(r'$andthen-quick-review'));
    expect(capturedTasks.last.provider, 'codex');
  });

  test('preflights synthetic merge-resolve skill before dispatch', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-merge-resolve',
      description: 'preflight merge resolve test',
      project: 'proj',
      gitStrategy: WorkflowGitStrategy(mergeResolve: MergeResolveConfig(enabled: true)),
      steps: [
        WorkflowStep(id: 'stories', name: 'Stories', mapOver: 'items', maxParallel: 2, foreachSteps: ['implement']),
        WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement {{map.item}}']),
      ],
    );
    final introspector = FakeSkillIntrospector({'codex': const <String>{}});
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(
        defaultProvider: 'codex',
        providerExecutables: {'codex': '/bin/codex'},
      ),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    await executor.execute(
      run,
      definition,
      WorkflowContext(
        data: {
          'items': ['one'],
        },
      ),
    );

    final failedRun = await h.repository.getById(run.id);
    expect(failedRun?.status, WorkflowRunStatus.failed);
    expect(failedRun?.errorMessage, contains('dartclaw-merge-resolve'));
    expect(await h.taskService.list(), isEmpty);
    expect(introspector.calls, [(provider: 'codex', executable: '/bin/codex')]);
  });

  test('coarse synthetic merge-resolve preflight fails before foreach task dispatch', () async {
    final definition = const WorkflowDefinition(
      name: 'preflight-merge-resolve-not-reachable',
      description: 'preflight merge resolve not reachable test',
      gitStrategy: WorkflowGitStrategy(mergeResolve: MergeResolveConfig(enabled: true)),
      steps: [
        WorkflowStep(id: 'stories', name: 'Stories', mapOver: 'items', foreachSteps: ['review']),
        WorkflowStep(id: 'review', name: 'Review', skill: 'andthen:review'),
      ],
    );
    final introspector = FakeSkillIntrospector({
      'codex': {'andthen-review'},
    });
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(
        defaultProvider: 'codex',
        providerExecutables: {'codex': '/bin/codex'},
      ),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    await executor.execute(
      run,
      definition,
      WorkflowContext(
        data: {
          'items': ['one'],
        },
      ),
    );

    final failedRun = await h.repository.getById(run.id);
    expect(failedRun?.status, WorkflowRunStatus.failed);
    expect(failedRun?.errorMessage, contains('dartclaw-merge-resolve'));
    expect(await h.taskService.list(), isEmpty);
    expect(introspector.calls, [(provider: 'codex', executable: '/bin/codex')]);
  });

  for (final provider in ['claude', 'codex']) {
    test('preflights and dispatches DC-native skill for $provider', () async {
      final definition = WorkflowDefinition(
        name: 'preflight-dc-native-$provider',
        description: 'preflight DC-native skill test',
        steps: [
          WorkflowStep(id: 'validate', name: 'Validate', provider: provider, skill: 'dartclaw-validate-workflow'),
        ],
      );
      final introspector = FakeSkillIntrospector({
        provider: {'dartclaw-validate-workflow'},
      });
      final executor = h.makeExecutor(
        skillIntrospector: introspector,
        skillPreflightConfig: WorkflowSkillPreflightConfig(providerExecutables: {provider: '/bin/$provider'}),
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);

      Task? capturedTask;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen(
        (event) async {
          capturedTask = await h.taskService.get(event.taskId);
          await h.completeTask(event.taskId);
        },
      );
      addTearDown(sub.cancel);

      await executor.execute(run, definition, WorkflowContext());

      expect(introspector.calls, [(provider: provider, executable: '/bin/$provider')]);
      if (provider == 'codex') {
        expect(capturedTask?.description, startsWith(r'$dartclaw-validate-workflow'));
      } else {
        expect(capturedTask?.description, startsWith('/dartclaw-validate-workflow'));
      }
      expect(capturedTask?.provider, provider);
    });
  }

  group('checkWorkflowSkillRefs (validate --skills diagnostic)', () {
    const config = WorkflowSkillPreflightConfig(
      defaultProvider: 'claude',
      configuredProviders: {'claude', 'codex'},
      providerExecutables: {'claude': 'claude', 'codex': 'codex'},
    );

    test('unresolvable ref surfaces as a warning naming step id, skill, and provider', () async {
      const definition = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: [WorkflowStep(id: 'review', name: 'Review', provider: 'claude', skill: 'andthen:reveiw')],
      );
      final result = await checkWorkflowSkillRefs(
        definition: definition,
        introspector: FakeSkillIntrospector({
          'claude': {'andthen:review'},
        }),
        skillPreflightConfig: config,
        roleDefaults: const WorkflowRoleDefaults(),
      );

      expect(result.probeNotes, isEmpty);
      expect(result.unresolved, hasLength(1));
      expect(result.unresolved.single.stepId, 'review');
      expect(result.unresolved.single.skill, 'andthen:reveiw');
      expect(result.unresolved.single.provider, 'claude');
    });

    test('a ref resolvable via the codex hyphen alias does not warn (translation reused, not re-derived)', () async {
      const definition = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: [WorkflowStep(id: 'review', name: 'Review', provider: 'codex', skill: 'andthen:review')],
      );
      final result = await checkWorkflowSkillRefs(
        definition: definition,
        introspector: FakeSkillIntrospector({
          'codex': {'andthen-review'},
        }),
        skillPreflightConfig: config,
        roleDefaults: const WorkflowRoleDefaults(),
      );

      expect(result.unresolved, isEmpty);
      expect(result.probeNotes, isEmpty);
    });

    test('probe failure degrades to a note and reports no unresolved refs', () async {
      const definition = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: [WorkflowStep(id: 'review', name: 'Review', provider: 'claude', skill: 'andthen:reveiw')],
      );
      final result = await checkWorkflowSkillRefs(
        definition: definition,
        introspector: _ThrowingSkillIntrospector(),
        skillPreflightConfig: config,
        roleDefaults: const WorkflowRoleDefaults(),
      );

      expect(result.unresolved, isEmpty);
      expect(result.probeNotes, hasLength(1));
      expect(result.probeNotes.single, contains('provider "claude"'));
    });

    test('non-agent and skill-less steps are ignored', () async {
      const definition = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: [
          WorkflowStep(id: 'plain', name: 'Plain', prompts: ['do it']),
          WorkflowStep(id: 'shell', name: 'Shell', taskType: WorkflowTaskType.bash, prompts: ['echo hi']),
        ],
      );
      final result = await checkWorkflowSkillRefs(
        definition: definition,
        introspector: FakeSkillIntrospector(const {}),
        skillPreflightConfig: config,
        roleDefaults: const WorkflowRoleDefaults(),
      );

      expect(result.unresolved, isEmpty);
      expect(result.probeNotes, isEmpty);
    });

    test('synthetic merge-resolve skill ref surfaces when the provider cannot see it', () async {
      const definition = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        project: 'proj',
        gitStrategy: WorkflowGitStrategy(mergeResolve: MergeResolveConfig(enabled: true)),
        steps: [
          WorkflowStep(id: 'stories', name: 'Stories', mapOver: 'items', maxParallel: 2, foreachSteps: ['implement']),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement {{map.item}}']),
        ],
      );
      final result = await checkWorkflowSkillRefs(
        definition: definition,
        introspector: FakeSkillIntrospector({
          'claude': {'andthen:review'},
        }),
        skillPreflightConfig: config,
        roleDefaults: const WorkflowRoleDefaults(),
      );

      expect(result.unresolved, hasLength(1));
      expect(result.unresolved.single.skill, 'dartclaw-merge-resolve');
      expect(result.probeNotes, isEmpty);
    });

    test('synthetic merge-resolve skill ref does not warn when the provider sees it', () async {
      const definition = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        project: 'proj',
        gitStrategy: WorkflowGitStrategy(mergeResolve: MergeResolveConfig(enabled: true)),
        steps: [
          WorkflowStep(id: 'stories', name: 'Stories', mapOver: 'items', maxParallel: 2, foreachSteps: ['implement']),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement {{map.item}}']),
        ],
      );
      final result = await checkWorkflowSkillRefs(
        definition: definition,
        introspector: FakeSkillIntrospector({
          'claude': {'dartclaw-merge-resolve'},
        }),
        skillPreflightConfig: config,
        roleDefaults: const WorkflowRoleDefaults(),
      );

      expect(result.unresolved, isEmpty);
      expect(result.probeNotes, isEmpty);
    });
  });
}
