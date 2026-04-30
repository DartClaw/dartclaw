// Behavioral approval step execution: needsInput hold, awaitingApproval
// transitions, approval-step lifecycle (zero tasks, timeout auto-cancel,
// prompt template resolution).
@Tags(['component'])
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:dartclaw_models/dartclaw_models.dart' show SessionType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OnFailurePolicy,
        SessionService,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowApprovalRequestedEvent,
        WorkflowContext,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep,
        WorkflowTemplateEngine;
import 'package:dartclaw_workflow/src/workflow/approval_step_runner.dart'
    show ApprovalStepDependencies, executeApprovalStep;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  group('needsInput hold transitions to awaitingApproval', () {
    test('needsInput outcome advances currentStepIndex past held step and fires approval event', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      final approvalEvents = <WorkflowApprovalRequestedEvent>[];
      final evSub = h.eventBus.on<WorkflowApprovalRequestedEvent>().listen(approvalEvents.add);

      final sessionService = SessionService(baseDir: h.sessionsDir);
      int taskCount = 0;

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        final task = await h.taskService.get(e.taskId);
        if (task == null) return;
        final session = await sessionService.createSession(type: SessionType.task);
        await h.taskService.updateFields(task.id, sessionId: session.id);
        await h.messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content:
              'Blocked pending human decision.\n'
              '<step-outcome>{"outcome":"needsInput","reason":"ambiguous requirements"}</step-outcome>',
        );
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, context);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await evSub.cancel();

      expect(taskCount, equals(1));

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.awaitingApproval));
      expect(finalRun?.currentStepIndex, equals(1));
      expect(finalRun?.contextJson['_approval.pending.stepId'], equals('step1'));
      expect(finalRun?.contextJson['_approval.pending.stepIndex'], equals(0));
      expect(finalRun?.errorMessage, equals('ambiguous requirements'));

      expect(approvalEvents, hasLength(1));
      expect(approvalEvents.first.stepId, equals('step1'));
      expect(approvalEvents.first.message, equals('ambiguous requirements'));
    });

    test('onFailure: pause after failed outcome routes through the same awaitingApproval hold', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], onFailure: OnFailurePolicy.pause),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      final approvalEvents = <WorkflowApprovalRequestedEvent>[];
      final evSub = h.eventBus.on<WorkflowApprovalRequestedEvent>().listen(approvalEvents.add);
      final sessionService = SessionService(baseDir: h.sessionsDir);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        if (task == null) return;
        final session = await sessionService.createSession(type: SessionType.task);
        await h.taskService.updateFields(task.id, sessionId: session.id);
        await h.messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content: '<step-outcome>{"outcome":"failed","reason":"guarded"}</step-outcome>',
        );
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, context);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await evSub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.awaitingApproval));
      expect(finalRun?.currentStepIndex, equals(1));
      expect(approvalEvents, hasLength(1));
      expect(approvalEvents.first.stepId, equals('step1'));
    });
  });

  group('approval step execution', () {
    test('approval step pauses with zero task creation and zero token increment', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'gate', name: 'Review Gate', type: 'approval', prompts: ['Please review']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      final approvalEvents = <WorkflowApprovalRequestedEvent>[];
      final eventSub = h.eventBus.on<WorkflowApprovalRequestedEvent>().listen(approvalEvents.add);

      await h.executor.execute(run, definition, context);
      await Future<void>.delayed(Duration.zero);
      await eventSub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.awaitingApproval));
      expect(finalRun?.totalTokens, equals(0));
      final allTasks = await h.taskService.list();
      expect(allTasks.where((t) => t.workflowRunId == 'run-1'), isEmpty);

      expect(context['gate.approval.status'], equals('pending'));
      expect(context['gate.approval.message'], equals('Please review'));
      expect(context['gate.approval.requested_at'], isNotNull);
      expect(context['gate.tokenCount'], equals(0));

      expect(approvalEvents, hasLength(1));
      expect(approvalEvents.first.stepId, equals('gate'));
      expect(approvalEvents.first.message, equals('Please review'));
    });

    test('approval step without timeoutSeconds waits indefinitely (no auto-cancel)', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'gate', name: 'Gate', type: 'approval', prompts: ['Approve?']),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await h.executor.execute(run, definition, context);

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.awaitingApproval));
      expect(context['gate.approval.timeout_deadline'], isNull);
    });

    test('approval step with timeoutSeconds auto-cancels after timeout', () {
      final step = const WorkflowStep(
        id: 'gate',
        name: 'Gate',
        type: 'approval',
        prompts: ['Approve?'],
        timeoutSeconds: 1,
      );
      final definition = h.makeDefinition(steps: [step]);
      final run = h.makeRun(definition);
      final context = WorkflowContext();
      final timers = <String, Timer>{};

      WorkflowRunStatus? cancelledStatus;
      String? cancelReason;
      WorkflowRun? pausedRun;

      fakeAsync((async) {
        unawaited(h.repository.insert(run));
        async.flushMicrotasks();

        unawaited(
          executeApprovalStep(
            run: run,
            step: step,
            context: context,
            stepIndex: 0,
            templateEngine: WorkflowTemplateEngine(),
            dependencies: ApprovalStepDependencies(
              eventBus: h.eventBus,
              repository: h.repository,
              persistContext: (_, _) async {},
              cancelRun: (updatedRun, _) async {
                final cancelled = updatedRun.copyWith(status: WorkflowRunStatus.cancelled);
                await h.repository.update(cancelled);
              },
              approvalTimers: timers,
            ),
          ),
        );
        async.flushMicrotasks();

        unawaited(h.repository.getById('run-1').then((r) => pausedRun = r));
        async.flushMicrotasks();

        // Advance virtual time past the 1-second timeout.
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        unawaited(
          h.repository.getById('run-1').then((r) {
            cancelledStatus = r?.status;
            cancelReason = r?.contextJson['gate.approval.cancel_reason'] as String?;
          }),
        );
        async.flushMicrotasks();
      });

      expect(pausedRun?.status, equals(WorkflowRunStatus.awaitingApproval));
      expect(pausedRun?.contextJson['gate.approval.timeout_deadline'], isNotNull);
      expect(cancelledStatus, equals(WorkflowRunStatus.cancelled));
      expect(cancelReason, equals('timeout'));
    });

    test('approval step resolves prompt template from context', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'gate',
            name: 'Gate',
            type: 'approval',
            prompts: ['Review result: {{context.prior_output}}'],
          ),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();
      context['prior_output'] = 'all tests pass';

      await h.executor.execute(run, definition, context);

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.contextJson['gate.approval.message'], equals('Review result: all tests pass'));
    });
  });
}
