import 'dart:async';

import 'package:dartclaw_cli/src/commands/workflow/cli_progress_printer.dart';
import 'package:dartclaw_cli/src/commands/workflow/live_status_line.dart';
import 'package:dartclaw_cli/src/commands/workflow/standalone_run_harness.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show EventBus, Task, TaskStatus, TaskStatusChangedEvent, TaskType, WorkflowRunStatusChangedEvent;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryTaskRepository, flushAsync;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowRun, WorkflowRunStatus, WorkflowService, WorkflowStep;
import 'package:test/test.dart';

import '../../helpers/fake_exit.dart';

/// Gates [getById] on [gate] so a test can hold the harness's running-branch
/// task fetch in flight while later status events land.
class _GateableTaskRepository extends InMemoryTaskRepository {
  Completer<void>? gate;

  @override
  Future<Task?> getById(String id) async {
    final g = gate;
    if (g != null) await g.future;
    return super.getById(id);
  }
}

/// Only [get] is exercised by [driveStandaloneWorkflowRun] in these tests
/// (settle refetch); everything else is unreachable.
class _SettleOnlyWorkflowService implements WorkflowService {
  WorkflowRun? settledRun;

  @override
  Future<WorkflowRun?> get(String runId) async => settledRun;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not used by driveStandaloneWorkflowRun in this test');
}

void main() {
  group('driveStandaloneWorkflowRun live-line settle', () {
    late EventBus eventBus;
    late _GateableTaskRepository repo;
    late TaskService taskService;
    late _SettleOnlyWorkflowService service;
    late List<String> liveOut;
    late List<String> stdoutLines;
    late CliProgressPrinter printer;

    final definition = WorkflowDefinition(
      name: 'parallel-pair',
      description: 'Two-member parallel group',
      steps: const [
        WorkflowStep(id: 'member-a', name: 'Member A', prompts: ['a']),
        WorkflowStep(id: 'member-b', name: 'Member B', prompts: ['b']),
      ],
    );

    final run = WorkflowRun(
      id: 'run-1',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime(2026, 7, 1),
      updatedAt: DateTime(2026, 7, 1),
      currentStepIndex: 0,
      definitionJson: definition.toJson(),
      contextJson: const {'data': <String, dynamic>{}, 'variables': <String, dynamic>{}},
    );

    setUp(() {
      eventBus = EventBus();
      repo = _GateableTaskRepository();
      taskService = TaskService(repo);
      service = _SettleOnlyWorkflowService();
      liveOut = <String>[];
      stdoutLines = <String>[];
      printer = CliProgressPrinter(
        totalSteps: definition.steps.length,
        workflowName: definition.name,
        writeLine: stdoutLines.add,
        standalone: true,
        liveStatusLine: LiveStatusLine(
          write: liveOut.add,
          enabled: true,
          color: false,
          now: () => DateTime(2026, 7, 1, 12),
          columns: () => 200,
        ),
      );
    });

    Future<void> insertTask(String id, int stepIndex) => repo.insert(
      Task(
        id: id,
        title: 'Task $id',
        description: '',
        type: TaskType.coding,
        status: TaskStatus.running,
        createdAt: DateTime(2026, 7, 1),
        workflowRunId: run.id,
        stepIndex: stepIndex,
      ),
    );

    void fireStatus(String taskId, TaskStatus oldStatus, TaskStatus newStatus) {
      eventBus.fire(
        TaskStatusChangedEvent(
          taskId: taskId,
          oldStatus: oldStatus,
          newStatus: newStatus,
          trigger: 'test',
          timestamp: DateTime(2026, 7, 1, 12),
        ),
      );
    }

    Future<WorkflowRun> startDrive() {
      final future = driveStandaloneWorkflowRun(
        service: service,
        taskService: taskService,
        definition: definition,
        eventBus: eventBus,
        printer: printer,
        jsonOutput: false,
        stdoutLine: stdoutLines.add,
        interrupts: () => const Stream<void>.empty(),
        exitFn: fakeExit,
        trigger: () async => run,
      );
      return future;
    }

    Future<void> completeRun(Future<WorkflowRun> driveFuture) async {
      service.settledRun = run.copyWith(status: WorkflowRunStatus.completed, updatedAt: DateTime(2026, 7, 1, 13));
      eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: run.id,
          definitionName: definition.name,
          oldStatus: WorkflowRunStatus.running,
          newStatus: WorkflowRunStatus.completed,
          timestamp: DateTime(2026, 7, 1, 13),
        ),
      );
      await driveFuture;
    }

    test('a terminal task status retires the live entry before the step barrier', () async {
      await insertTask('t1', 0);
      await insertTask('t2', 1);
      final driveFuture = startDrive();
      await flushAsync(4);

      fireStatus('t1', TaskStatus.queued, TaskStatus.running);
      fireStatus('t2', TaskStatus.queued, TaskStatus.running);
      await flushAsync(4);
      expect(liveOut.join(), contains('2 steps running'));

      liveOut.clear();
      fireStatus('t1', TaskStatus.running, TaskStatus.accepted); // settles ~30 min before the group barrier
      await flushAsync(4);
      final afterSettle = liveOut.join();
      expect(afterSettle, isNot(contains('2 steps running')));
      expect(afterSettle, contains('[step 2/2] member-b'));

      await completeRun(driveFuture);
    });

    test('a settle landing while the running-branch task fetch is in flight never resurrects the entry', () async {
      await insertTask('t1', 0);
      final driveFuture = startDrive();
      await flushAsync(4);

      repo.gate = Completer<void>();
      fireStatus('t1', TaskStatus.queued, TaskStatus.running);
      await flushAsync(4); // listener is now parked on the gated task fetch
      fireStatus('t1', TaskStatus.running, TaskStatus.failed); // instant failure beats the fetch
      await flushAsync(4);

      liveOut.clear();
      repo.gate!.complete();
      repo.gate = null;
      await flushAsync(4);
      // The deferred stepRunning must have been suppressed – nothing to show.
      expect(liveOut.join(), isNot(contains('member-a')));

      await completeRun(driveFuture);
    });

    test('a re-queued retry of the same task id shows again after an earlier settle', () async {
      await insertTask('t1', 0);
      final driveFuture = startDrive();
      await flushAsync(4);

      fireStatus('t1', TaskStatus.queued, TaskStatus.running);
      await flushAsync(4);
      fireStatus('t1', TaskStatus.running, TaskStatus.failed);
      await flushAsync(4);

      liveOut.clear();
      fireStatus('t1', TaskStatus.queued, TaskStatus.running); // task-level retry re-queues the same id
      await flushAsync(4);
      expect(liveOut.join(), contains('[step 1/2] member-a'));

      liveOut.clear();
      fireStatus('t1', TaskStatus.running, TaskStatus.accepted);
      await flushAsync(4);
      expect(liveOut.join(), isNot(contains('member-a')));

      await completeRun(driveFuture);
    });
  });
}
