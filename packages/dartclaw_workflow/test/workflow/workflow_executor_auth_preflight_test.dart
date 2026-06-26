import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProviderAuthPreflight, FakeSkillIntrospector;
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  late WorkflowExecutorHarness h;

  setUp(() {
    h = WorkflowExecutorHarness()..setUp();
  });

  tearDown(() => h.tearDown());

  test('S01: unauthenticated referenced provider aborts before step 1 with remediation', () async {
    final definition = const WorkflowDefinition(
      name: 'auth-preflight-logged-out',
      description: 'logged-out provider halts the run',
      steps: [WorkflowStep(id: 'review', name: 'Review', provider: 'claude', skill: 'andthen:review')],
    );
    final introspector = FakeSkillIntrospector({
      'claude': {'andthen:review'},
    });
    final authPreflight = FakeProviderAuthPreflight(unauthenticated: {'claude'});
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      providerAuthPreflight: authPreflight,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(providerExecutables: {'claude': '/bin/claude'}),
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    await executor.execute(run, definition, WorkflowContext());

    final failedRun = await h.repository.getById(run.id);
    expect(failedRun?.status, WorkflowRunStatus.failed);
    expect(failedRun?.errorMessage, contains('claude'));
    expect(failedRun?.errorMessage, contains('not authenticated'));
    // The auth probe runs before any skill introspection spawn.
    expect(introspector.calls, isEmpty);
    expect(await h.taskService.list(), isEmpty);
  });

  test('S02: authenticated referenced providers proceed to skill introspection', () async {
    final definition = const WorkflowDefinition(
      name: 'auth-preflight-authenticated',
      description: 'authenticated providers proceed unchanged',
      steps: [WorkflowStep(id: 'review', name: 'Review', provider: 'codex', skill: 'andthen:review')],
    );
    final introspector = FakeSkillIntrospector({
      'codex': {'andthen-review'},
    });
    final authPreflight = FakeProviderAuthPreflight();
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      providerAuthPreflight: authPreflight,
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
    expect(authPreflight.probed, ['codex']);
    expect(introspector.calls, [(provider: 'codex', executable: '/bin/codex')]);
    expect(capturedTask?.provider, 'codex');
  });

  test('S04: a declared-but-unreferenced provider is never probed', () async {
    final definition = const WorkflowDefinition(
      name: 'auth-preflight-unreferenced',
      description: 'only referenced providers are probed',
      steps: [WorkflowStep(id: 'review', name: 'Review', provider: 'codex', skill: 'andthen:review')],
    );
    final introspector = FakeSkillIntrospector({
      'codex': {'andthen-review'},
    });
    // claude is logged out, but the run only references codex.
    final authPreflight = FakeProviderAuthPreflight(unauthenticated: {'claude'});
    final executor = h.makeExecutor(
      skillIntrospector: introspector,
      providerAuthPreflight: authPreflight,
      skillPreflightConfig: const WorkflowSkillPreflightConfig(
        configuredProviders: {'claude', 'codex'},
        providerExecutables: {'claude': '/bin/claude', 'codex': '/bin/codex'},
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

    final finishedRun = await h.repository.getById(run.id);
    expect(finishedRun?.status, isNot(WorkflowRunStatus.failed));
    expect(authPreflight.probed, ['codex']);
    expect(authPreflight.probed, isNot(contains('claude')));
  });
}
