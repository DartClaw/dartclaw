import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/api/task_sse_routes.dart';
import 'package:dartclaw_server/src/task/task_service.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowService;
import 'package:dartclaw_storage/dartclaw_storage.dart';
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
  late Database workflowDb;
  late TaskService tasks;
  late EventBus eventBus;
  late WorkflowService workflows;
  late Directory tempDir;

  setUp(() {
    taskDb = openTaskDbInMemory();
    workflowDb = sqlite3.openInMemory();
    tempDir = Directory.systemTemp.createTempSync('wf_sse_test_');
    eventBus = EventBus();
    tasks = TaskService(SqliteTaskRepository(taskDb), eventBus: eventBus);

    final workflowRepo = SqliteWorkflowRunRepository(workflowDb);
    final messages = MessageService(baseDir: p.join(tempDir.path, 'sessions'));
    final kv = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    workflows = WorkflowService(
      repository: workflowRepo,
      taskService: tasks,
      messageService: messages,
      eventBus: eventBus,
      kvService: kv,
      dataDir: tempDir.path,
    );
  });

  tearDown(() async {
    await workflows.dispose();
    await tasks.dispose();
    await eventBus.dispose();
    taskDb.close();
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
        type: TaskType.coding,
        autoStart: true,
      );
      await tasks.transition('task-health', TaskStatus.running);

      final payload = await nextFrameOfType(it, 'task_status_changed');
      expect(payload['taskId'], 'task-health');
    });
  });
}
