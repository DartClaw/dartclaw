import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/api/task_sse_routes.dart';
import 'package:dartclaw_runtime/src/task/task_service.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        SqliteWorkflowRunRepository,
        WorkflowDefinition,
        WorkflowPersistencePorts,
        WorkflowRun,
        WorkflowService,
        WorkflowStep,
        WorkflowTaskType;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

WorkflowDefinition _makeDef({String name = 'spec-and-implement', int steps = 3}) {
  return WorkflowDefinition(
    name: name,
    description: 'test',
    variables: const {},
    steps: List.generate(steps, (i) => WorkflowStep(id: 'step-$i', name: 'Step $i', prompts: ['do step $i'])),
  );
}

void main() {
  late Database taskDb;
  late SqliteBackend taskBackend;
  late Database workflowDb;
  late TaskService tasks;
  late EventBus eventBus;
  late WorkflowService workflows;
  late SqliteWorkflowRunRepository workflowRepo;
  late Directory tempDir;

  setUp(() async {
    taskDb = openTaskDbInMemory();
    taskBackend = SqliteBackend(taskDb);
    await SqliteSchemaGate.prepareTasks(taskBackend, storeName: 'tasks.db');
    workflowDb = sqlite3.openInMemory();
    tempDir = Directory.systemTemp.createTempSync('wf_sse_test_');
    eventBus = EventBus();
    final taskRepository = SqliteTaskRepository(taskBackend);
    final agentExecutionRepository = SqliteAgentExecutionRepository(taskDb, eventBus: eventBus);
    final workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(taskDb);
    final executionTransactor = SqliteExecutionRepositoryTransactor(taskDb);
    tasks = TaskService(
      taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      executionTransactor: executionTransactor,
      eventBus: eventBus,
    );

    workflowRepo = SqliteWorkflowRunRepository(workflowDb);
    final messages = MessageService(baseDir: p.join(tempDir.path, 'sessions'));
    final kv = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    workflows = WorkflowService(
      repository: workflowRepo,
      taskService: tasks,
      messageService: messages,
      persistencePorts: WorkflowPersistencePorts(
        taskRepository: taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
        executionRepositoryTransactor: executionTransactor,
      ),
      eventBus: eventBus,
      kvService: kv,
      dataDir: tempDir.path,
    );
  });

  tearDown(() async {
    await workflows.dispose();
    await tasks.dispose();
    await eventBus.dispose();
    await taskBackend.close();
    workflowDb.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Map<String, dynamic> decodeFramePayload(String frame) {
    final dataLine = frame.trim().split('\n').first;
    expect(dataLine, startsWith('data: '));
    return jsonDecode(dataLine.substring('data: '.length)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> nextFrame(StreamIterator<String> iterator) async {
    final hasFrame = await iterator.moveNext().timeout(const Duration(seconds: 1));
    expect(hasFrame, isTrue);
    return decodeFramePayload(iterator.current);
  }

  Future<Map<String, dynamic>> nextFrameOfType(StreamIterator<String> it, String type) async {
    for (var i = 0; i < 20; i++) {
      final payload = await nextFrame(it);
      if (payload['type'] == type) return payload;
    }
    fail('Did not receive frame with type=$type within 20 frames');
  }

  Future<StreamIterator<String>> connectSse({WorkflowService? wf}) async {
    final handler = taskSseRoutes(tasks, eventBus, workflows: wf).call;
    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    expect(response.statusCode, 200);
    return StreamIterator(response.read().transform(utf8.decoder));
  }

  group('connected payload', () {
    test('omits activeWorkflows when WorkflowService is null', () async {
      final it = await connectSse();
      addTearDown(it.cancel);

      final payload = await nextFrame(it);
      expect(payload['type'], 'connected');
      expect(payload.containsKey('activeWorkflows'), isFalse);
    });

    test('includes activeWorkflows when WorkflowService is provided', () async {
      final it = await connectSse(wf: workflows);
      addTearDown(it.cancel);

      final payload = await nextFrame(it);
      expect(payload['type'], 'connected');
      expect(payload['activeWorkflows'], isA<List<dynamic>>());
    });

    test('activeWorkflows is empty when no runs are active', () async {
      final it = await connectSse(wf: workflows);
      addTearDown(it.cancel);

      final payload = await nextFrame(it);
      expect(payload['activeWorkflows'] as List, isEmpty);
    });

    test('activeWorkflows contains running workflow with step counts', () async {
      final def = _makeDef(steps: 4);
      await workflows.start(def, const {});
      final runs = await workflows.list();
      expect(runs, isNotEmpty);

      final it = await connectSse(wf: workflows);
      addTearDown(it.cancel);

      final payload = await nextFrame(it);
      final activeWorkflows = payload['activeWorkflows'] as List;
      expect(activeWorkflows, hasLength(1));

      final wf = activeWorkflows.first as Map<String, dynamic>;
      expect(wf['definitionName'], 'spec-and-implement');
      expect(wf['status'], 'running');
      expect(wf['totalSteps'], 4);
      expect(wf['completedSteps'], isA<int>());
    });

    test('activeWorkflows counts taskless steps from persisted context data', () async {
      final now = DateTime.parse('2026-03-24T10:00:00Z');
      final definition = WorkflowDefinition(
        name: 'release-ui-smoke',
        description: 'Taskless workflow state projection.',
        steps: const [
          WorkflowStep(id: 'prepare', name: 'Prepare', taskType: WorkflowTaskType.bash, prompts: ['prepare']),
          WorkflowStep(id: 'approve', name: 'Approve', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
          WorkflowStep(id: 'finish', name: 'Finish', taskType: WorkflowTaskType.bash, prompts: ['finish']),
        ],
      );
      await workflowRepo.insert(
        WorkflowRun(
          id: 'run-taskless',
          definitionName: definition.name,
          status: WorkflowRunStatus.running,
          startedAt: now,
          updatedAt: now,
          currentStepIndex: 3,
          definitionJson: definition.toJson(),
          contextJson: const {
            'data': {'prepare.status': 'success', 'approve.approval.status': 'approved', 'finish.status': 'success'},
          },
        ),
      );

      final handler = taskSseRoutes(tasks, eventBus, workflows: workflows).call;
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/sidebar-state')));
      final payload = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final activeWorkflow = (payload['activeWorkflows'] as List<dynamic>).single as Map<String, dynamic>;

      expect(activeWorkflow['completedSteps'], 3);
      expect(activeWorkflow['totalSteps'], 3);
    });

    test('sidebar-state endpoint includes activeWorkflows when workflows are configured', () async {
      final def = _makeDef(steps: 4);
      await workflows.start(def, const {});

      final handler = taskSseRoutes(tasks, eventBus, workflows: workflows).call;
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/sidebar-state')));
      final payload = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

      expect(response.statusCode, 200);
      expect(payload['activeWorkflows'], isA<List<dynamic>>());
      final activeWorkflows = payload['activeWorkflows'] as List<dynamic>;
      expect(activeWorkflows, hasLength(1));
      final wf = activeWorkflows.first as Map<String, dynamic>;
      expect(wf['definitionName'], 'spec-and-implement');
      expect(wf['status'], 'running');
    });
  });

  group('TaskStatusChangedEvent', () {
    test('includes activeWorkflows when WorkflowService is provided', () async {
      final def = _makeDef(steps: 3);
      final run = await workflows.start(def, const {});

      await tasks.create(
        id: 'task-1',
        title: 'Workflow task',
        description: 'desc',
        configJson: const {'needsWorktree': false},
        autoStart: true,
        workflowRunId: run.id,
        stepIndex: 0,
      );
      await tasks.transition('task-1', TaskStatus.running);

      final it = await connectSse(wf: workflows);
      addTearDown(it.cancel);
      await nextFrame(it); // connected

      await tasks.transition('task-1', TaskStatus.review);
      eventBus.fire(
        TaskStatusChangedEvent(
          taskId: 'task-1',
          oldStatus: TaskStatus.running,
          newStatus: TaskStatus.review,
          trigger: 'system',
          timestamp: DateTime.now(),
        ),
      );

      final payload = await nextFrameOfType(it, 'task_status_changed');
      expect(payload['activeWorkflows'], isA<List<dynamic>>());
      final activeWorkflows = payload['activeWorkflows'] as List<dynamic>;
      expect(activeWorkflows, isNotEmpty);
      final wf = activeWorkflows.first as Map<String, dynamic>;
      expect(wf['id'], run.id);
      expect(wf['definitionName'], 'spec-and-implement');
    });
  });

  group('WorkflowRunStatusChangedEvent', () {
    test('triggers workflow_sidebar_update event', () async {
      await workflows.start(_makeDef(), const {});
      final run = (await workflows.list()).first;

      final it = await connectSse(wf: workflows);
      addTearDown(it.cancel);
      await nextFrame(it); // consume connected

      // Fire a workflow status change event directly.
      eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: run.id,
          definitionName: run.definitionName,
          oldStatus: WorkflowRunStatus.running,
          newStatus: WorkflowRunStatus.paused,
          timestamp: DateTime.now(),
        ),
      );

      final payload = await nextFrameOfType(it, 'workflow_sidebar_update');
      expect(payload['activeWorkflows'], isA<List<dynamic>>());
      expect(payload['notification'], isFalse);
    });

    test('notification: true when transitioning to completed', () async {
      await workflows.start(_makeDef(), const {});
      final run = (await workflows.list()).first;

      final it = await connectSse(wf: workflows);
      addTearDown(it.cancel);
      await nextFrame(it); // consume connected

      eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: run.id,
          definitionName: run.definitionName,
          oldStatus: WorkflowRunStatus.running,
          newStatus: WorkflowRunStatus.completed,
          timestamp: DateTime.now(),
        ),
      );

      final payload = await nextFrameOfType(it, 'workflow_sidebar_update');
      expect(payload['notification'], isTrue);
    });

    test('notification: true when transitioning to failed', () async {
      await workflows.start(_makeDef(), const {});
      final run = (await workflows.list()).first;

      final it = await connectSse(wf: workflows);
      addTearDown(it.cancel);
      await nextFrame(it); // consume connected

      eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: run.id,
          definitionName: run.definitionName,
          oldStatus: WorkflowRunStatus.running,
          newStatus: WorkflowRunStatus.failed,
          timestamp: DateTime.now(),
        ),
      );

      final payload = await nextFrameOfType(it, 'workflow_sidebar_update');
      expect(payload['notification'], isTrue);
    });

    test('notification: false for non-terminal transitions', () async {
      await workflows.start(_makeDef(), const {});
      final run = (await workflows.list()).first;

      final it = await connectSse(wf: workflows);
      addTearDown(it.cancel);
      await nextFrame(it); // consume connected

      eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: run.id,
          definitionName: run.definitionName,
          oldStatus: WorkflowRunStatus.running,
          newStatus: WorkflowRunStatus.paused,
          timestamp: DateTime.now(),
        ),
      );

      final payload = await nextFrameOfType(it, 'workflow_sidebar_update');
      expect(payload['notification'], isFalse);
    });
  });

  group('WorkflowStepCompletedEvent', () {
    test('triggers workflow_sidebar_update event', () async {
      await workflows.start(_makeDef(), const {});
      final run = (await workflows.list()).first;

      final it = await connectSse(wf: workflows);
      addTearDown(it.cancel);
      await nextFrame(it); // consume connected

      eventBus.fire(
        WorkflowStepCompletedEvent(
          runId: run.id,
          stepId: 'step-0',
          stepName: 'Step 0',
          stepIndex: 0,
          totalSteps: 3,
          taskId: 'task-001',
          success: true,
          tokenCount: 100,
          timestamp: DateTime.now(),
        ),
      );

      final payload = await nextFrameOfType(it, 'workflow_sidebar_update');
      expect(payload['activeWorkflows'], isA<List<dynamic>>());
      expect(payload['notification'], isFalse);
    });
  });

  group('null WorkflowService graceful degradation', () {
    test('workflow events fire without errors when WorkflowService is null', () async {
      // Connect without workflow service.
      final it = await connectSse();
      addTearDown(it.cancel);
      await nextFrame(it); // consume connected

      // Fire a workflow event — should not cause any output or error.
      eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: 'run-001',
          definitionName: 'test',
          oldStatus: WorkflowRunStatus.running,
          newStatus: WorkflowRunStatus.completed,
          timestamp: DateTime.now(),
        ),
      );

      // Verify no workflow_sidebar_update appears — fire a task event to confirm
      // the SSE stream is still alive and producing output.
      await tasks.create(
        id: 'task-health',
        title: 'Health',
        description: 'desc',
        configJson: const {'needsWorktree': false},
        autoStart: true,
      );
      await tasks.transition('task-health', TaskStatus.running);

      final payload = await nextFrameOfType(it, 'task_status_changed');
      expect(payload['taskId'], 'task-health');

      // create(autoStart: true) and transition() each emit a task event. Drain
      // both projections before teardown closes the task backend.
      final remainingPayload = await nextFrameOfType(it, 'task_status_changed');
      expect(remainingPayload['taskId'], 'task-health');
    });
  });
}
