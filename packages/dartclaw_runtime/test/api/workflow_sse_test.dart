import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryTaskRepository;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowRun, WorkflowService, WorkflowStep, WorkflowTaskType;
import 'package:dartclaw_workflow/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'workflow_test_support.dart';

const _runId = 'run-001';

WorkflowDefinition _makeDefinition() {
  return WorkflowDefinition(
    name: 'implement-story',
    description: 'test',
    variables: const {},
    steps: const [
      WorkflowStep(id: 'research', name: 'Research', prompts: ['research']),
      WorkflowStep(id: 'implement', name: 'Implement', prompts: ['implement']),
    ],
  );
}

WorkflowRun _makeRun({
  WorkflowRunStatus status = WorkflowRunStatus.running,
  int currentStepIndex = 0,
  Map<String, dynamic>? contextJson,
  Map<String, dynamic>? definitionJson,
}) {
  final now = DateTime.parse('2026-03-24T10:00:00Z');
  final def = _makeDefinition();
  return WorkflowRun(
    id: _runId,
    definitionName: def.name,
    status: status,
    contextJson: contextJson ?? const {},
    startedAt: now,
    updatedAt: now,
    variablesJson: const {},
    definitionJson: definitionJson ?? def.toJson(),
    currentStepIndex: currentStepIndex,
  );
}

Task _childTask(String id, {TaskStatus status = TaskStatus.queued, String runId = _runId, String? displayScope}) =>
    Task(
      id: id,
      title: 'Research task',
      description: 'Collect sources',
      status: status,
      createdAt: DateTime.utc(2026, 3, 24, 10),
      workflowRunId: runId,
      stepIndex: 0,
      configJson: {'displayScope': ?displayScope},
    );

WorkflowCliTurnProgressEvent _turnProgress(String taskId, int tokens) => WorkflowCliTurnProgressEvent(
  taskId: taskId,
  sessionId: 'session-001',
  provider: 'codex',
  turnIndex: 2,
  cumulativeTokens: tokens,
  inputTokens: tokens - 400,
  outputTokens: 400,
  cacheReadTokens: 0,
  cacheWriteTokens: 0,
  timestamp: DateTime.now(),
);

class _ControllableTaskRepository extends InMemoryTaskRepository {
  StateError? listError;

  Completer<void>? _listStarted;
  Completer<void>? _releaseList;

  void blockNextList() {
    _listStarted = Completer<void>();
    _releaseList = Completer<void>();
  }

  Future<void> get listStarted => _listStarted!.future;

  void releaseList() => _releaseList!.complete();

  @override
  Future<List<Task>> list({TaskStatus? status}) async {
    if (listError case final error?) throw error;
    final started = _listStarted;
    final release = _releaseList;
    if (started != null && release != null) {
      started.complete();
      await release.future;
      _listStarted = null;
      _releaseList = null;
    }
    return super.list(status: status);
  }
}

class _SubscriptionTrackingEventBus extends EventBus {
  int activeSubscriptions = 0;

  @override
  Stream<T> on<T extends DartclawEvent>() {
    final source = super.on<T>();
    return Stream<T>.multi((controller) {
      final subscription = source.listen(
        controller.addSync,
        onError: controller.addErrorSync,
        onDone: controller.closeSync,
      );
      activeSubscriptions++;
      controller.onCancel = () async {
        activeSubscriptions--;
        await subscription.cancel();
      };
    }, isBroadcast: source.isBroadcast);
  }
}

StreamIterator<String> _readEvents(Response response) {
  expect(response.statusCode, 200);
  final lines = StreamIterator(response.read().transform(utf8.decoder).transform(const LineSplitter()));
  addTearDown(lines.cancel);
  return lines;
}

Future<Map<String, dynamic>> _nextPayload(StreamIterator<String> lines, {String? type}) async {
  final payload = await _readDataFrame(lines).timeout(const Duration(seconds: 1));
  if (type != null) expect(payload['type'], type);
  return payload;
}

Future<Map<String, dynamic>> _readDataFrame(StreamIterator<String> lines) async {
  final data = <String>[];
  while (await lines.moveNext()) {
    final line = lines.current;
    if (line.isEmpty && data.isNotEmpty) {
      final payload = jsonDecode(data.join('\n'));
      if (payload is! Map<String, dynamic>) fail('Expected an SSE JSON object, got $payload');
      return payload;
    }
    if (line == 'data') {
      data.add('');
    } else if (line.startsWith('data:')) {
      final value = line.substring('data:'.length);
      data.add(value.startsWith(' ') ? value.substring(1) : value);
    }
  }
  fail('SSE stream ended before a complete data frame');
}

void main() {
  final eventsUri = Uri.parse('http://localhost/api/workflows/runs/$_runId/events');
  late _ControllableTaskRepository taskRepo;
  late InMemoryWorkflowRunRepository runRepo;
  late _SubscriptionTrackingEventBus eventBus;
  late TaskService tasks;
  late WorkflowService workflows;
  late Handler handler;
  late InMemoryDefinitionSource definitions;
  Future<StreamIterator<String>> connectToRun() async {
    final lines = _readEvents(await handler(Request('GET', eventsUri)));
    final snapshot = await _nextPayload(lines, type: 'connected');
    expect(snapshot['run']['id'], _runId);
    return lines;
  }

  setUp(() async {
    eventBus = _SubscriptionTrackingEventBus();
    taskRepo = _ControllableTaskRepository();
    runRepo = InMemoryWorkflowRunRepository();
    await runRepo.insert(_makeRun());
    tasks = TaskService(taskRepo, eventBus: eventBus);
    final tempDir = Directory.systemTemp.createTempSync('wf_sse_test_');
    final messages = MessageService(baseDir: p.join(tempDir.path, 'sessions'));
    final kv = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    workflows = WorkflowService.lifecycleOnly(
      repository: runRepo,
      taskService: tasks,
      messageService: messages,
      eventBus: eventBus,
      kvService: kv,
      dataDir: tempDir.path,
    );
    addTearDown(() async {
      await workflows.dispose();
      await tasks.dispose();
      await eventBus.dispose();
      await messages.dispose();
      await kv.dispose();
      tempDir.deleteSync(recursive: true);
    });

    definitions = InMemoryDefinitionSource([_makeDefinition()]);
    handler = workflowRoutes(
      workflows,
      tasks,
      definitions,
      runControl: testRunControl(workflows),
      eventBus: eventBus,
    ).call;
  });

  group('GET /api/workflows/runs/<id>/events', () {
    test('returns 404 for unknown run', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/unknown/events')));
      expect(response.statusCode, 404);
    });

    test('returns 503 when eventBus not configured', () async {
      final handlerNoEventBus = workflowRoutes(
        workflows,
        tasks,
        definitions,
        runControl: testRunControl(workflows),
      ).call;
      final response = await handlerNoEventBus(Request('GET', eventsUri));
      expect(response.statusCode, 503);
    });

    test('sends connected payload with run state and steps', () async {
      await taskRepo.insert(_childTask('task-001', status: TaskStatus.accepted));

      final response = await handler(Request('GET', eventsUri));
      expect(response.headers['content-type'], contains('text/event-stream'));
      expect(response.headers['x-accel-buffering'], 'no');
      expect(response.context['shelf.io.buffer_output'], isFalse);

      final connected = await _nextPayload(_readEvents(response), type: 'connected');
      expect(connected['run']['id'], _runId);
      expect(connected['run']['status'], 'running');
      expect(connected['steps'], [
        allOf(containsPair('id', 'research'), containsPair('taskId', 'task-001'), containsPair('status', 'completed')),
        allOf(containsPair('id', 'implement'), containsPair('taskId', null), containsPair('status', 'pending')),
      ]);
    });

    test('connected payload retains a continued execution error as a failed step', () async {
      await runRepo.update(
        _makeRun(
          status: WorkflowRunStatus.completed,
          contextJson: const {
            'data': {'research.status': 'failed', 'research.error': 'shell exited 7'},
          },
        ),
      );
      final response = await handler(Request('GET', eventsUri));
      final connected = await _nextPayload(_readEvents(response), type: 'connected');
      expect(connected['run']['status'], 'completed');
      expect((connected['steps'] as List).first['status'], 'failed');
      expect((connected['steps'] as List).first['reason'], 'shell exited 7');
    });

    test('connected payload identifies a step awaiting approval', () async {
      final definition = WorkflowDefinition(
        name: 'approval-test',
        description: 'test',
        steps: const [
          WorkflowStep(id: 'approve', name: 'Approve', taskType: WorkflowTaskType.approval, prompts: ['approve']),
        ],
      );
      await runRepo.update(
        _makeRun(
          status: WorkflowRunStatus.awaitingApproval,
          contextJson: const {'approve.approval.status': 'pending'},
          definitionJson: definition.toJson(),
        ),
      );

      final response = await handler(Request('GET', eventsUri));
      final connected = await _nextPayload(_readEvents(response), type: 'connected');
      expect((connected['steps'] as List).single['status'], 'awaiting_approval');
    });

    test('snapshot failure cancels subscriptions installed during setup', () async {
      final subscriptionsBeforeRequest = eventBus.activeSubscriptions;
      taskRepo.listError = StateError('task snapshot unavailable');

      await expectLater(
        handler(Request('GET', eventsUri)),
        throwsA(isA<StateError>().having((error) => error.message, 'message', 'task snapshot unavailable')),
      );
      expect(eventBus.activeSubscriptions, subscriptionsBeforeRequest);
    });

    test('does not miss lifecycle transitions while the initial snapshot loads', () async {
      taskRepo.blockNextList();
      final responseFuture = handler(Request('GET', eventsUri));
      await taskRepo.listStarted.timeout(const Duration(seconds: 1));

      eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: _runId,
          definitionName: 'implement-story',
          oldStatus: WorkflowRunStatus.running,
          newStatus: WorkflowRunStatus.awaitingApproval,
          timestamp: DateTime.now(),
        ),
      );
      eventBus.fire(
        WorkflowStepCompletedEvent(
          runId: _runId,
          stepId: 'research',
          stepName: 'Research',
          stepIndex: 0,
          totalSteps: 2,
          taskId: '',
          success: true,
          tokenCount: 1000,
          timestamp: DateTime.now(),
        ),
      );
      await runRepo.update(_makeRun(status: WorkflowRunStatus.awaitingApproval, currentStepIndex: 1));
      taskRepo.releaseList();

      final lines = _readEvents(await responseFuture);
      expect(
        [await _nextPayload(lines), await _nextPayload(lines), await _nextPayload(lines)],
        unorderedEquals([
          allOf(containsPair('type', 'connected'), containsPair('run', containsPair('currentStepIndex', 1))),
          allOf(containsPair('type', 'workflow_status_changed'), containsPair('newStatus', 'awaitingApproval')),
          allOf(containsPair('type', 'workflow_step_completed'), containsPair('stepId', 'research')),
        ]),
      );
    });

    test('forwards WorkflowRunStatusChangedEvent', () async {
      final lines = await connectToRun();

      eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: _runId,
          definitionName: 'implement-story',
          oldStatus: WorkflowRunStatus.running,
          newStatus: WorkflowRunStatus.paused,
          errorMessage: 'Step failed',
          timestamp: DateTime.now(),
        ),
      );
      final statusChanged = await _nextPayload(lines, type: 'workflow_status_changed');
      expect(statusChanged['newStatus'], 'paused');
      expect(statusChanged['errorMessage'], 'Step failed');
    });

    test('a recovered run clears its earlier failure cause from status events', () async {
      await runRepo.update(_makeRun(status: WorkflowRunStatus.failed).copyWith(errorMessage: 'accounting unavailable'));
      final lines = _readEvents(await handler(Request('GET', eventsUri)));
      final snapshot = await _nextPayload(lines, type: 'connected');
      expect(snapshot['run']['errorMessage'], 'accounting unavailable');
      await runRepo.update(_makeRun());
      eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: _runId,
          definitionName: 'implement-story',
          oldStatus: WorkflowRunStatus.failed,
          newStatus: WorkflowRunStatus.running,
          timestamp: DateTime.now(),
        ),
      );
      final statusChanged = await _nextPayload(lines, type: 'workflow_status_changed');
      expect(statusChanged['newStatus'], 'running');
      expect(statusChanged['errorMessage'], isNull);
    });

    test('does not forward WorkflowRunStatusChangedEvent for different run', () async {
      final lines = await connectToRun();

      for (final eventRunId in ['run-other', _runId]) {
        eventBus.fire(
          WorkflowRunStatusChangedEvent(
            runId: eventRunId,
            definitionName: 'implement-story',
            oldStatus: WorkflowRunStatus.running,
            newStatus: WorkflowRunStatus.paused,
            timestamp: DateTime.now(),
          ),
        );
      }
      final statusChanged = await _nextPayload(lines, type: 'workflow_status_changed');
      expect(statusChanged['runId'], _runId);
    });

    test('forwards WorkflowStepCompletedEvent', () async {
      final lines = await connectToRun();

      eventBus.fire(
        WorkflowStepCompletedEvent(
          runId: _runId,
          stepId: 'research',
          stepName: 'Research',
          stepIndex: 0,
          totalSteps: 2,
          taskId: 'task-001',
          success: true,
          tokenCount: 1000,
          timestamp: DateTime.now(),
        ),
      );
      final stepCompleted = await _nextPayload(lines, type: 'workflow_step_completed');
      expect(stepCompleted['stepId'], 'research');
      expect(stepCompleted['success'], true);
      expect(stepCompleted['tokenCount'], 1000);
      expect(stepCompleted['runId'], _runId);
      expect(stepCompleted['taskId'], 'task-001');
      expect(stepCompleted['stepIndex'], 0);
      expect(stepCompleted['totalSteps'], 2);
      expect(stepCompleted, isNot(contains('outcome')));
      expect(stepCompleted, isNot(contains('reason')));
    });

    test('forwards WorkflowStepCompletedEvent outcome and reason when present', () async {
      final lines = await connectToRun();

      eventBus.fire(
        WorkflowStepCompletedEvent(
          runId: _runId,
          stepId: 'research',
          stepName: 'Research',
          stepIndex: 0,
          totalSteps: 2,
          taskId: 'task-001',
          success: false,
          outcome: 'needsInput',
          reason: 'awaiting operator decision',
          tokenCount: 500,
          timestamp: DateTime.now(),
        ),
      );
      final stepCompleted = await _nextPayload(lines, type: 'workflow_step_completed');
      expect(stepCompleted['success'], false);
      expect(stepCompleted['outcome'], 'needsInput');
      expect(stepCompleted['reason'], 'awaiting operator decision');
    });

    test('forwards WorkflowStepCompletedEvent with task display scope enrichment', () async {
      await taskRepo.insert(_childTask('task-scoped', status: TaskStatus.running, displayScope: 'item-d'));
      final lines = await connectToRun();

      eventBus.fire(
        WorkflowStepCompletedEvent(
          runId: _runId,
          stepId: 'research',
          stepName: 'Research',
          stepIndex: 0,
          totalSteps: 2,
          taskId: 'task-scoped',
          success: true,
          tokenCount: 1000,
          timestamp: DateTime.now(),
        ),
      );
      final stepCompleted = await _nextPayload(lines, type: 'workflow_step_completed');
      expect(stepCompleted['displayScope'], 'item-d');
      expect(stepCompleted['tokenCount'], 1000);
    });

    test('forwards MapIterationCompletedEvent with display scope', () async {
      final lines = await connectToRun();

      eventBus.fire(
        MapIterationCompletedEvent(
          runId: _runId,
          stepId: 'story-pipeline',
          iterationIndex: 1,
          totalIterations: 2,
          itemId: 'S02',
          taskId: '',
          success: false,
          tokenCount: 0,
          timestamp: DateTime.now(),
        ),
      );
      final mapIteration = await _nextPayload(lines, type: 'map_iteration_completed');
      expect(mapIteration['itemId'], 'S02');
      expect(mapIteration['displayScope'], 'S02');
      expect(mapIteration['success'], false);
      expect(mapIteration['runId'], _runId);
      expect(mapIteration['stepId'], 'story-pipeline');
      expect(mapIteration['taskId'], '');
      expect(mapIteration['iterationIndex'], 1);
      expect(mapIteration['totalIterations'], 2);
      expect(mapIteration['tokenCount'], 0);
      expect(mapIteration, isNot(contains('outcome')));
      expect(mapIteration, isNot(contains('reason')));
    });

    test('forwards MapIterationCompletedEvent outcome and reason when present', () async {
      final lines = await connectToRun();

      eventBus.fire(
        MapIterationCompletedEvent(
          runId: _runId,
          stepId: 'story-pipeline',
          iterationIndex: 1,
          totalIterations: 2,
          itemId: 'S02',
          taskId: 'task-iter',
          success: false,
          outcome: 'failed',
          reason: 'analyze gate failed',
          tokenCount: 42,
          timestamp: DateTime.now(),
        ),
      );
      final mapIteration = await _nextPayload(lines, type: 'map_iteration_completed');
      expect(mapIteration['outcome'], 'failed');
      expect(mapIteration['reason'], 'analyze gate failed');
    });

    test('forwards MapStepCompletedEvent with blockedCount', () async {
      final lines = await connectToRun();

      eventBus.fire(
        MapStepCompletedEvent(
          runId: _runId,
          stepId: 'story-pipeline',
          stepName: 'Story pipeline',
          totalIterations: 4,
          successCount: 2,
          failureCount: 1,
          cancelledCount: 0,
          blockedCount: 1,
          totalTokens: 1234,
          timestamp: DateTime.now(),
        ),
      );
      final mapStep = await _nextPayload(lines, type: 'map_step_completed');
      expect(mapStep['successCount'], 2);
      expect(mapStep['failureCount'], 1);
      expect(mapStep['cancelledCount'], 0);
      expect(mapStep['blockedCount'], 1);
      expect(mapStep['totalTokens'], 1234);
    });

    test('forwards TaskStatusChangedEvent for known child tasks', () async {
      await taskRepo.insert(_childTask('task-001'));
      final lines = await connectToRun();

      await tasks.transition('task-001', TaskStatus.running);
      final taskStatus = await _nextPayload(lines, type: 'task_status_changed');
      expect(taskStatus['taskId'], 'task-001');
      expect(taskStatus['oldStatus'], 'queued');
      expect(taskStatus['newStatus'], 'running');
    });

    test('forwards TaskStatusChangedEvent for workflow child tasks created after subscription', () async {
      final lines = await connectToRun();

      await taskRepo.insert(_childTask('task-late', displayScope: 'item-b'));
      await tasks.transition('task-late', TaskStatus.running);

      final taskStatus = await _nextPayload(lines, type: 'task_status_changed');
      expect(taskStatus['taskId'], 'task-late');
      expect(taskStatus['stepIndex'], 0);
      expect(taskStatus['displayScope'], 'item-b');
    });

    test('filters task status changes for missing tasks and tasks of other runs', () async {
      await taskRepo.insert(_childTask('task-other', runId: 'run-other'));
      await taskRepo.insert(_childTask('task-001'));
      final lines = await connectToRun();

      eventBus.fire(
        TaskStatusChangedEvent(
          taskId: 'unrelated-task',
          oldStatus: TaskStatus.queued,
          newStatus: TaskStatus.running,
          trigger: 'executor',
          timestamp: DateTime.now(),
        ),
      );
      await tasks.transition('task-other', TaskStatus.running);
      await tasks.transition('task-001', TaskStatus.running);

      final taskStatus = await _nextPayload(lines, type: 'task_status_changed');
      expect(taskStatus['taskId'], 'task-001');
    });

    test('forwards WorkflowCliTurnProgressEvent for a child task of this run', () async {
      await taskRepo.insert(_childTask('task-001', status: TaskStatus.running));
      final lines = await connectToRun();

      eventBus.fire(_turnProgress('task-001', 8400));
      final progress = await _nextPayload(lines, type: 'workflow_cli_turn_progress');
      expect(progress['taskId'], 'task-001');
      expect(progress['cumulativeTokens'], 8400);
    });

    test('filters turn progress for a task of another run', () async {
      await taskRepo.insert(_childTask('task-other', runId: 'run-other', status: TaskStatus.running));
      await taskRepo.insert(_childTask('task-001', status: TaskStatus.running));
      final lines = await connectToRun();

      eventBus.fire(_turnProgress('task-other', 5000));
      eventBus.fire(_turnProgress('task-001', 8400));
      final progress = await _nextPayload(lines, type: 'workflow_cli_turn_progress');
      expect(progress['taskId'], 'task-001');
    });

    test('forwards LoopIterationCompletedEvent', () async {
      final lines = await connectToRun();

      eventBus.fire(
        LoopIterationCompletedEvent(
          runId: _runId,
          loopId: 'review-loop',
          iteration: 2,
          maxIterations: 3,
          gateResult: false,
          timestamp: DateTime.now(),
        ),
      );
      final loopFrames = await _nextPayload(lines, type: 'loop_iteration_completed');
      expect(loopFrames['loopId'], 'review-loop');
      expect(loopFrames['iteration'], 2);
    });

    test('forwards ParallelGroupCompletedEvent', () async {
      final lines = await connectToRun();

      eventBus.fire(
        ParallelGroupCompletedEvent(
          runId: _runId,
          stepIds: ['step-a', 'step-b'],
          successCount: 2,
          failureCount: 0,
          totalTokens: 5000,
          timestamp: DateTime.now(),
        ),
      );
      final parallelFrames = await _nextPayload(lines, type: 'parallel_group_completed');
      expect(parallelFrames['stepIds'], ['step-a', 'step-b']);
    });

    test('sends an approval request and decision once and in order', () async {
      final lines = await connectToRun();

      final now = DateTime.now();
      eventBus.fire(
        WorkflowApprovalRequestedEvent(
          runId: _runId,
          stepId: 'gate',
          message: 'Please approve',
          timeoutSeconds: 300,
          timestamp: now,
        ),
      );
      eventBus.fire(WorkflowApprovalResolvedEvent(runId: _runId, stepId: 'gate', approved: true, timestamp: now));
      eventBus.fire(
        WorkflowApprovalRequestedEvent(runId: _runId, stepId: 'next-gate', message: 'Review again', timestamp: now),
      );

      final approval = await _nextPayload(lines, type: 'approval_requested');
      expect(approval['runId'], _runId);
      expect(approval['stepId'], 'gate');
      expect(approval['message'], 'Please approve');
      expect(approval['timeoutSeconds'], 300);
      final resolution = await _nextPayload(lines, type: 'approval_resolved');
      expect(resolution['stepId'], 'gate');
      expect(resolution['approved'], isTrue);
      expect(resolution['feedback'], isNull);
      final nextApproval = await _nextPayload(lines, type: 'approval_requested');
      expect(nextApproval['stepId'], 'next-gate');
    });

    test('forwards WorkflowApprovalResolvedEvent with feedback', () async {
      final lines = await connectToRun();

      eventBus.fire(
        WorkflowApprovalResolvedEvent(
          runId: _runId,
          stepId: 'gate',
          approved: false,
          feedback: 'Not ready',
          timestamp: DateTime.now(),
        ),
      );
      eventBus.fire(
        WorkflowApprovalResolvedEvent(runId: _runId, stepId: 'next-gate', approved: true, timestamp: DateTime.now()),
      );
      final resolution = await _nextPayload(lines, type: 'approval_resolved');
      expect(resolution['approved'], isFalse);
      expect(resolution['feedback'], 'Not ready');
      final nextResolution = await _nextPayload(lines, type: 'approval_resolved');
      expect(nextResolution['stepId'], 'next-gate');
    });

    test('filters approval requests for other runs', () async {
      final lines = await connectToRun();

      for (final eventRunId in ['other-run', _runId]) {
        eventBus.fire(
          WorkflowApprovalRequestedEvent(
            runId: eventRunId,
            stepId: 'gate',
            message: 'Approve?',
            timestamp: DateTime.now(),
          ),
        );
      }
      final approval = await _nextPayload(lines, type: 'approval_requested');
      expect(approval['runId'], _runId);
    });
  });
}
