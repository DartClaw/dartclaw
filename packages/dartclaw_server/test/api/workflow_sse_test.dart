import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SqliteTaskRepository, SqliteWorkflowRunRepository, openTaskDbInMemory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show InMemoryDefinitionSource, WorkflowService;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────────

WorkflowDefinition _makeDefinition({String name = 'spec-and-implement'}) {
  return WorkflowDefinition(
    name: name,
    description: 'test',
    variables: const {},
    steps: const [
      WorkflowStep(id: 'research', name: 'Research', prompts: ['research']),
      WorkflowStep(id: 'implement', name: 'Implement', prompts: ['implement']),
    ],
  );
}

WorkflowRun _makeRun({
  String id = 'run-001',
  WorkflowRunStatus status = WorkflowRunStatus.running,
  int currentStepIndex = 0,
  Map<String, dynamic>? definitionJson,
}) {
  final now = DateTime.parse('2026-03-24T10:00:00Z');
  final def = _makeDefinition();
  return WorkflowRun(
    id: id,
    definitionName: def.name,
    status: status,
    startedAt: now,
    updatedAt: now,
    variablesJson: const {},
    definitionJson: definitionJson ?? def.toJson(),
    currentStepIndex: currentStepIndex,
  );
}

/// Reads SSE frames from [response] for up to [timeout] duration.
/// Returns parsed JSON objects for each `data:` line.
Future<List<Map<String, dynamic>>> collectSseFrames(
  Response response, {
  Duration timeout = const Duration(milliseconds: 300),
}) async {
  final frames = <Map<String, dynamic>>[];
  final deadline = DateTime.now().add(timeout);
  final sub = response.read().transform(utf8.decoder).listen((chunk) {
    for (final line in chunk.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('data: ')) {
        try {
          final json = jsonDecode(trimmed.substring(6)) as Map<String, dynamic>;
          frames.add(json);
        } catch (_) {}
      }
    }
  }, cancelOnError: true);
  while (DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(milliseconds: 10));
  }
  await sub.cancel();
  return frames;
}

/// Collects SSE frames while running [action] mid-stream.
/// Opens the response stream, waits [delayBeforeAction], runs [action],
/// waits [delayAfterAction], then cancels and returns collected frames.
Future<List<Map<String, dynamic>>> collectSseFramesWithAction(
  Response response, {
  Duration delayBeforeAction = const Duration(milliseconds: 30),
  Duration delayAfterAction = const Duration(milliseconds: 80),
  required Future<void> Function() action,
}) async {
  final frames = <Map<String, dynamic>>[];
  final sub = response.read().transform(utf8.decoder).listen((chunk) {
    for (final line in chunk.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('data: ')) {
        try {
          final json = jsonDecode(trimmed.substring(6)) as Map<String, dynamic>;
          frames.add(json);
        } catch (_) {}
      }
    }
  }, cancelOnError: true);
  await Future.delayed(delayBeforeAction);
  await action();
  await Future.delayed(delayAfterAction);
  await sub.cancel();
  return frames;
}

class _FakeWorkflowService extends WorkflowService {
  _FakeWorkflowService._super(
    SqliteWorkflowRunRepository repository,
    TaskService taskService,
    MessageService messageService,
    EventBus eventBus,
    KvService kvService,
    String dataDir,
  ) : super(
        repository: repository,
        taskService: taskService,
        messageService: messageService,
        eventBus: eventBus,
        kvService: kvService,
        dataDir: dataDir,
      );

  factory _FakeWorkflowService({
    required Database db,
    required TaskService taskService,
    required EventBus eventBus,
    required String dataDir,
  }) {
    final repo = SqliteWorkflowRunRepository(db);
    final messages = MessageService(baseDir: p.join(dataDir, 'sessions'));
    final kv = KvService(filePath: p.join(dataDir, 'kv.json'));
    return _FakeWorkflowService._super(repo, taskService, messages, eventBus, kv, dataDir);
  }

  WorkflowRun? getResult;

  @override
  Future<WorkflowRun?> get(String runId) async => getResult;
}

// ──────────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────────

void main() {
  late Database taskDb;
  late Database workflowDb;
  late SqliteTaskRepository taskRepo;
  late EventBus eventBus;
  late TaskService tasks;
  late _FakeWorkflowService workflows;
  late Handler handler;
  late InMemoryDefinitionSource definitions;
  late Directory tempDir;

  setUp(() async {
    taskDb = openTaskDbInMemory();
    workflowDb = sqlite3.openInMemory();
    eventBus = EventBus();
    taskRepo = SqliteTaskRepository(taskDb);
    tasks = TaskService(taskRepo, eventBus: eventBus);
    tempDir = Directory.systemTemp.createTempSync('wf_sse_test_');

    workflows = _FakeWorkflowService(db: workflowDb, taskService: tasks, eventBus: eventBus, dataDir: tempDir.path);
    workflows.getResult = _makeRun();

    definitions = InMemoryDefinitionSource([_makeDefinition()]);
    handler = workflowRoutes(workflows, tasks, definitions, eventBus: eventBus).call;
  });

  tearDown(() async {
    await workflows.dispose();
    await tasks.dispose();
    await eventBus.dispose();
    workflowDb.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('GET /api/workflows/runs/<id>/events', () {
    test('returns 404 for unknown run', () async {
      workflows.getResult = null;
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/unknown/events')));
      expect(response.statusCode, 404);
    });

    test('returns 503 when eventBus not configured', () async {
      final handlerNoEventBus = workflowRoutes(workflows, tasks, definitions).call;
      final response = await handlerNoEventBus(
        Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')),
      );
      expect(response.statusCode, 503);
    });

    test('sends connected payload with run state and steps', () async {
      // Insert a completed task for step 0 directly into the repo.
      await taskRepo.insert(
        Task(
          id: 'task-001',
          title: 'Step 0',
          description: 'desc',
          type: TaskType.research,
          status: TaskStatus.accepted,
          createdAt: DateTime.parse('2026-03-24T10:00:00Z'),
          workflowRunId: 'run-001',
          stepIndex: 0,
        ),
      );

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('text/event-stream'));

      final frames = await collectSseFrames(response);
      expect(frames, isNotEmpty);
      final connected = frames.firstWhere((f) => f['type'] == 'connected');
      expect(connected['run']['id'], 'run-001');
      expect(connected['run']['status'], 'running');
      expect((connected['steps'] as List), hasLength(2));
    });

    test('connected payload has correct number of steps', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));
      final frames = await collectSseFrames(response);
      final connected = frames.firstWhere((f) => f['type'] == 'connected');
      expect((connected['steps'] as List), hasLength(2));
    });

    test('forwards WorkflowRunStatusChangedEvent', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));

      final frames = await collectSseFramesWithAction(
        response,
        action: () async {
          eventBus.fire(
            WorkflowRunStatusChangedEvent(
              runId: 'run-001',
              definitionName: 'spec-and-implement',
              oldStatus: WorkflowRunStatus.running,
              newStatus: WorkflowRunStatus.paused,
              errorMessage: 'Step failed',
              timestamp: DateTime.now(),
            ),
          );
        },
      );
      final statusChanged = frames.where((f) => f['type'] == 'workflow_status_changed').toList();
      expect(statusChanged, isNotEmpty);
      expect(statusChanged.first['newStatus'], 'paused');
      expect(statusChanged.first['errorMessage'], 'Step failed');
    });

    test('does not forward WorkflowRunStatusChangedEvent for different run', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));

      final frames = await collectSseFramesWithAction(
        response,
        action: () async {
          eventBus.fire(
            WorkflowRunStatusChangedEvent(
              runId: 'run-OTHER',
              definitionName: 'other',
              oldStatus: WorkflowRunStatus.running,
              newStatus: WorkflowRunStatus.paused,
              timestamp: DateTime.now(),
            ),
          );
        },
      );
      final statusChanged = frames.where((f) => f['type'] == 'workflow_status_changed').toList();
      expect(statusChanged, isEmpty);
    });

    test('forwards WorkflowStepCompletedEvent', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));

      final frames = await collectSseFramesWithAction(
        response,
        action: () async {
          eventBus.fire(
            WorkflowStepCompletedEvent(
              runId: 'run-001',
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
        },
      );
      final stepCompleted = frames.where((f) => f['type'] == 'workflow_step_completed').toList();
      expect(stepCompleted, isNotEmpty);
      expect(stepCompleted.first['stepId'], 'research');
      expect(stepCompleted.first['success'], true);
      expect(stepCompleted.first['tokenCount'], 1000);
    });

    test('forwards MapIterationCompletedEvent with display scope', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));

      final frames = await collectSseFramesWithAction(
        response,
        action: () async {
          eventBus.fire(
            MapIterationCompletedEvent(
              runId: 'run-001',
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
        },
      );
      final mapIteration = frames.where((f) => f['type'] == 'map_iteration_completed').toList();
      expect(mapIteration, isNotEmpty);
      expect(mapIteration.first['itemId'], 'S02');
      expect(mapIteration.first['displayScope'], 'S02');
      expect(mapIteration.first['success'], false);
    });

    test('forwards TaskStatusChangedEvent for known child tasks', () async {
      // Insert the task into the task repo directly so it's a known child.
      await taskRepo.insert(
        Task(
          id: 'task-001',
          title: 'Step 0',
          description: 'desc',
          type: TaskType.research,
          status: TaskStatus.queued,
          createdAt: DateTime.parse('2026-03-24T10:00:00Z'),
          workflowRunId: 'run-001',
          stepIndex: 0,
        ),
      );

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));

      final frames = await collectSseFramesWithAction(
        response,
        action: () async {
          eventBus.fire(
            TaskStatusChangedEvent(
              taskId: 'task-001',
              oldStatus: TaskStatus.queued,
              newStatus: TaskStatus.running,
              trigger: 'executor',
              timestamp: DateTime.now(),
            ),
          );
        },
      );
      final taskStatus = frames.where((f) => f['type'] == 'task_status_changed').toList();
      expect(taskStatus, isNotEmpty);
      expect(taskStatus.first['taskId'], 'task-001');
      expect(taskStatus.first['newStatus'], 'running');
    });

    test('forwards TaskStatusChangedEvent for workflow child tasks created after subscription', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));

      final frames = await collectSseFramesWithAction(
        response,
        action: () async {
          await taskRepo.insert(
            Task(
              id: 'task-late',
              title: 'Step 0',
              description: 'desc',
              type: TaskType.research,
              status: TaskStatus.queued,
              createdAt: DateTime.parse('2026-03-24T10:00:00Z'),
              workflowRunId: 'run-001',
              stepIndex: 0,
              configJson: const {'displayScope': 'S01'},
            ),
          );
          eventBus.fire(
            TaskStatusChangedEvent(
              taskId: 'task-late',
              oldStatus: TaskStatus.queued,
              newStatus: TaskStatus.running,
              trigger: 'executor',
              timestamp: DateTime.now(),
            ),
          );
        },
      );

      final taskStatus = frames.where((f) => f['type'] == 'task_status_changed').toList();
      expect(taskStatus, isNotEmpty);
      expect(taskStatus.first['taskId'], 'task-late');
      expect(taskStatus.first['stepIndex'], 0);
      expect(taskStatus.first['displayScope'], 'S01');
    });

    test('does NOT forward TaskStatusChangedEvent for unrelated tasks', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));

      final frames = await collectSseFramesWithAction(
        response,
        action: () async {
          eventBus.fire(
            TaskStatusChangedEvent(
              taskId: 'unrelated-task',
              oldStatus: TaskStatus.queued,
              newStatus: TaskStatus.running,
              trigger: 'executor',
              timestamp: DateTime.now(),
            ),
          );
        },
      );
      final taskStatus = frames.where((f) => f['type'] == 'task_status_changed').toList();
      expect(taskStatus, isEmpty);
    });

    test('forwards LoopIterationCompletedEvent', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));

      final frames = await collectSseFramesWithAction(
        response,
        action: () async {
          eventBus.fire(
            LoopIterationCompletedEvent(
              runId: 'run-001',
              loopId: 'review-loop',
              iteration: 2,
              maxIterations: 3,
              gateResult: false,
              timestamp: DateTime.now(),
            ),
          );
        },
      );
      final loopFrames = frames.where((f) => f['type'] == 'loop_iteration_completed').toList();
      expect(loopFrames, isNotEmpty);
      expect(loopFrames.first['loopId'], 'review-loop');
      expect(loopFrames.first['iteration'], 2);
    });

    test('forwards ParallelGroupCompletedEvent', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));

      final frames = await collectSseFramesWithAction(
        response,
        action: () async {
          eventBus.fire(
            ParallelGroupCompletedEvent(
              runId: 'run-001',
              stepIds: ['step-a', 'step-b'],
              successCount: 2,
              failureCount: 0,
              totalTokens: 5000,
              timestamp: DateTime.now(),
            ),
          );
        },
      );
      final parallelFrames = frames.where((f) => f['type'] == 'parallel_group_completed').toList();
      expect(parallelFrames, isNotEmpty);
      expect(parallelFrames.first['stepIds'], ['step-a', 'step-b']);
    });

    test('S03: forwards WorkflowApprovalRequestedEvent', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));

      final now = DateTime.now();
      final frames = await collectSseFramesWithAction(
        response,
        action: () async {
          eventBus.fire(
            WorkflowApprovalRequestedEvent(
              runId: 'run-001',
              stepId: 'gate',
              message: 'Please approve',
              timeoutSeconds: 300,
              timestamp: now,
            ),
          );
        },
      );
      final approvalFrames = frames.where((f) => f['type'] == 'approval_requested').toList();
      expect(approvalFrames, hasLength(1));
      expect(approvalFrames.first['runId'], 'run-001');
      expect(approvalFrames.first['stepId'], 'gate');
      expect(approvalFrames.first['message'], 'Please approve');
      expect(approvalFrames.first['timeoutSeconds'], 300);
    });

    test('S03: forwards WorkflowApprovalResolvedEvent with approved=true', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));

      final frames = await collectSseFramesWithAction(
        response,
        action: () async {
          eventBus.fire(
            WorkflowApprovalResolvedEvent(runId: 'run-001', stepId: 'gate', approved: true, timestamp: DateTime.now()),
          );
        },
      );
      final resolvedFrames = frames.where((f) => f['type'] == 'approval_resolved').toList();
      expect(resolvedFrames, hasLength(1));
      expect(resolvedFrames.first['approved'], isTrue);
      expect(resolvedFrames.first['feedback'], isNull);
    });

    test('S03: forwards WorkflowApprovalResolvedEvent with feedback', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));

      final frames = await collectSseFramesWithAction(
        response,
        action: () async {
          eventBus.fire(
            WorkflowApprovalResolvedEvent(
              runId: 'run-001',
              stepId: 'gate',
              approved: false,
              feedback: 'Not ready',
              timestamp: DateTime.now(),
            ),
          );
        },
      );
      final resolvedFrames = frames.where((f) => f['type'] == 'approval_resolved').toList();
      expect(resolvedFrames, hasLength(1));
      expect(resolvedFrames.first['approved'], isFalse);
      expect(resolvedFrames.first['feedback'], 'Not ready');
    });

    test('S03: approval events for other runs are NOT forwarded', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));

      final frames = await collectSseFramesWithAction(
        response,
        action: () async {
          eventBus.fire(
            WorkflowApprovalRequestedEvent(
              runId: 'other-run',
              stepId: 'gate',
              message: 'Approve?',
              timestamp: DateTime.now(),
            ),
          );
        },
      );
      final approvalFrames = frames.where((f) => f['type'] == 'approval_requested').toList();
      expect(approvalFrames, isEmpty);
    });
  });
}
