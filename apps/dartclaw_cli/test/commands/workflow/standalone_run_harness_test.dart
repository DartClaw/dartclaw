import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'package:dartclaw_cli/src/commands/workflow/cli_progress_printer.dart';
import 'package:dartclaw_cli/src/commands/workflow/live_status_line.dart';
import 'package:dartclaw_cli/src/commands/workflow/standalone_run_harness.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_progress_renderer.dart' show taskProgressKey;

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        EventBus,
        MapIterationCompletedEvent,
        Task,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowApprovalRequestedEvent,
        WorkflowCliTurnProgressEvent,
        WorkflowRunStatusChangedEvent,
        WorkflowStepCompletedEvent;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService;
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryTaskRepository, flushAsync;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowRun, WorkflowService, WorkflowStep;
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
        commandPrefix: 'dartclaw workflow',
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

    test('standalone progress consumes cumulative updates under the task key', () async {
      await insertTask('t1', 0);
      final driveFuture = startDrive();
      await flushAsync(4);

      fireStatus('t1', TaskStatus.queued, TaskStatus.running);
      await flushAsync(4);
      expect(taskProgressKey('t1'), 'task:t1');

      liveOut.clear();
      eventBus.fire(
        WorkflowCliTurnProgressEvent(
          taskId: 't1',
          sessionId: 'session-t1',
          provider: 'claude',
          turnIndex: 1,
          cumulativeTokens: 110,
          inputTokens: 100,
          outputTokens: 10,
          cacheReadTokens: 0,
          cacheWriteTokens: 0,
          timestamp: DateTime(2026, 7, 1, 12),
        ),
      );
      await flushAsync(2);
      expect(liveOut.join(), contains('110 tokens'));

      liveOut.clear();
      eventBus.fire(
        WorkflowCliTurnProgressEvent(
          taskId: 't1',
          sessionId: 'session-t1',
          provider: 'claude',
          turnIndex: 2,
          cumulativeTokens: 330,
          inputTokens: 300,
          outputTokens: 30,
          cacheReadTokens: 0,
          cacheWriteTokens: 0,
          timestamp: DateTime(2026, 7, 1, 12),
        ),
      );
      await flushAsync(2);
      expect(liveOut.join(), contains('330 tokens'));

      await completeRun(driveFuture);
    });
  });

  // TI01 parity pins for the frame types a bash-only command-level run cannot
  // produce (task transitions, map iterations, approvals, outcome/reason).
  // The command-level ordered pins live in workflow_run_command_standalone_test.dart.
  group('driveStandaloneWorkflowRun output parity', () {
    late EventBus eventBus;
    late InMemoryTaskRepository repo;
    late TaskService taskService;
    late _SettleOnlyWorkflowService service;
    late List<String> stdoutLines;

    final definition = WorkflowDefinition(
      name: 'parity',
      description: 'Parity fixture',
      steps: const [
        WorkflowStep(id: 'first', name: 'First', prompts: ['a'], provider: 'claude'),
        WorkflowStep(id: 'mapped', name: 'Mapped', prompts: ['b'], mapOver: 'items'),
      ],
    );

    final run = WorkflowRun(
      id: 'run-1',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime(2026, 7, 1),
      updatedAt: DateTime(2026, 7, 1),
      currentStepIndex: 1,
      definitionJson: definition.toJson(),
      contextJson: const {'data': <String, dynamic>{}, 'variables': <String, dynamic>{}},
    );

    setUp(() async {
      eventBus = EventBus();
      repo = InMemoryTaskRepository();
      taskService = TaskService(repo);
      service = _SettleOnlyWorkflowService();
      stdoutLines = <String>[];
      await repo.insert(
        Task(
          id: 't1',
          title: 'Parity – First',
          description: '',
          status: TaskStatus.running,
          createdAt: DateTime(2026, 7, 1),
          workflowRunId: run.id,
          stepIndex: 0,
          provider: 'codex',
          configJson: const {'displayScope': 'S01'},
        ),
      );
    });

    CliProgressPrinter printerFor({required bool jsonOutput}) => CliProgressPrinter(
      commandPrefix: 'dartclaw workflow',
      totalSteps: definition.steps.length,
      workflowName: definition.name,
      writeLine: stdoutLines.add,
      standalone: true,
      liveStatusLine: LiveStatusLine(write: (_) {}, enabled: false, color: false),
    );

    /// Fires the full progress vocabulary in a fixed order, then settles the
    /// run at an approval pause.
    Future<void> driveFixture({required bool jsonOutput}) async {
      final driveFuture = driveStandaloneWorkflowRun(
        service: service,
        taskService: taskService,
        definition: definition,
        eventBus: eventBus,
        printer: printerFor(jsonOutput: jsonOutput),
        jsonOutput: jsonOutput,
        stdoutLine: stdoutLines.add,
        interrupts: () => const Stream<void>.empty(),
        exitFn: fakeExit,
        trigger: () async => run,
      );
      await flushAsync(4);

      eventBus.fire(
        TaskStatusChangedEvent(
          taskId: 't1',
          oldStatus: TaskStatus.queued,
          newStatus: TaskStatus.running,
          trigger: 'test',
          timestamp: DateTime(2026, 7, 1, 12),
        ),
      );
      await flushAsync(4);
      eventBus.fire(
        TaskStatusChangedEvent(
          taskId: 't1',
          oldStatus: TaskStatus.running,
          newStatus: TaskStatus.review,
          trigger: 'test',
          timestamp: DateTime(2026, 7, 1, 12),
        ),
      );
      // A real gap, so a `jsonOutput` early-return hoisted above the start-time
      // record would zero `durationMs` instead of passing unnoticed.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      eventBus.fire(
        WorkflowStepCompletedEvent(
          runId: run.id,
          stepId: 'first',
          stepName: 'First',
          stepIndex: 0,
          totalSteps: 2,
          taskId: 't1',
          displayScope: 'S01',
          success: false,
          outcome: 'needsInput',
          reason: 'waiting on operator',
          tokenCount: 7,
          timestamp: DateTime(2026, 7, 1, 12),
        ),
      );
      await flushAsync(4);
      eventBus.fire(
        MapIterationCompletedEvent(
          runId: run.id,
          stepId: 'mapped',
          iterationIndex: 0,
          totalIterations: 2,
          itemId: 'S02',
          taskId: 't2',
          success: true,
          outcome: 'succeeded',
          tokenCount: 5,
          timestamp: DateTime(2026, 7, 1, 12),
        ),
      );
      await flushAsync(4);
      eventBus.fire(
        WorkflowApprovalRequestedEvent(
          runId: run.id,
          stepId: 'mapped',
          message: 'approve the plan',
          timeoutSeconds: 60,
          timestamp: DateTime(2026, 7, 1, 12),
        ),
      );
      await flushAsync(4);

      service.settledRun = run.copyWith(
        status: WorkflowRunStatus.awaitingApproval,
        updatedAt: DateTime(2026, 7, 1, 13),
      );
      eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: run.id,
          definitionName: definition.name,
          oldStatus: WorkflowRunStatus.running,
          newStatus: WorkflowRunStatus.awaitingApproval,
          timestamp: DateTime(2026, 7, 1, 13),
        ),
      );
      await driveFuture;
    }

    test('TI01 the --json frame sequence is renderer-authored, in order', () async {
      await driveFixture(jsonOutput: true);

      final frames = stdoutLines.map((line) => jsonDecode(line) as Map<String, dynamic>).toList();
      expect(frames.map((frame) => '${frame['type']} ${frame.keys.join(',')}').toList(), [
        'run_started type,run',
        'task_status_changed type,runId,taskId,stepIndex,stepId,oldStatus,newStatus,displayScope',
        'task_status_changed type,runId,taskId,stepIndex,stepId,oldStatus,newStatus,displayScope',
        'workflow_step_completed '
            'type,runId,stepId,stepIndex,totalSteps,taskId,displayScope,success,outcome,reason,tokenCount,durationMs',
        'map_iteration_completed '
            'type,runId,stepId,stepIndex,iterationIndex,totalIterations,itemId,displayScope,taskId,success,outcome,'
            'tokenCount,durationMs',
        'workflow_approval_requested type,runId,stepId,message,timeoutSeconds',
        'workflow_status_changed type,runId,definitionName,oldStatus,newStatus,errorMessage',
        'workflow_run_digest type,runId,status,steps,nextActions',
      ]);
      expect(frames[1]['newStatus'], 'running');
      expect(frames[1]['stepId'], 'first');
      expect(frames[1]['displayScope'], 'S01');
      expect(frames[2]['newStatus'], 'review');
      expect(frames[3]['reason'], 'waiting on operator');
      expect(frames[3]['durationMs'], greaterThan(0));
      expect(frames[4]['itemId'], 'S02');
      expect(frames[4]['displayScope'], 'S02');
      expect(frames[6]['definitionName'], 'parity');
    });

    test('TI01 text mode renders task title and task provider on the running line', () async {
      await driveFixture(jsonOutput: false);

      expect(stdoutLines, [
        '[workflow] Starting: parity (2 steps)',
        '[step 1/2] first[S01]: Parity – First – running (codex)',
        '[step 1/2] first[S01]: review (auto-accepted)',
        '[step 1/2] first[S01]: blocked (recoverable): waiting on operator',
        // No running transition was seen for this map task, so no duration is fabricated.
        '[step 2/2] mapped[S02]: completed (5 tokens)',
        '[workflow] Awaiting approval at step 1/2 (mapped)',
        '[workflow] Approval request: approve the plan',
        '[workflow] Use `dartclaw workflow resume run-1 --standalone` to approve '
            'or `dartclaw workflow cancel run-1 --standalone` to reject.',
        '[digest] Run run-1 – awaitingApproval',
        '  1. first: running',
        '  2. mapped: not started',
        '[digest] Next:',
        '  dartclaw workflow resume run-1 --standalone',
        '  dartclaw workflow cancel run-1 --standalone',
      ]);
    });
  });
}
