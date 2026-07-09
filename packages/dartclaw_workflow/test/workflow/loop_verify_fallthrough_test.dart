// Executor-driven coverage for remediation-loop exhaustion falling through to
// the deterministic verify gate (Story 10). These synthetic workflows mirror the
// inline maintainer workflows' control flow — remediation-loop → verify-all →
// verify-fix-loop → verify-recheck — using agent steps with injected
// `<workflow-context>` outputs so the gate-flipping logic is observable without a
// real bash verify gate.
@Tags(['component'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_models/dartclaw_models.dart' show SessionType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OutputConfig,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowLoop,
        WorkflowRunStatus,
        WorkflowStep,
        WorkflowStepCompletedEvent,
        stepStatusFromTask;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart' show WorkflowExecutorHarness;

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  // A workflow shaped like the inline maintainer workflows: a remediation-loop
  // that never converges, followed by the deterministic verify gate.
  WorkflowDefinition fallthroughDefinition({required String remediationPolicy}) => WorkflowDefinition(
    name: 'fallthrough',
    description: 'Remediation loop exhaustion falls through to the verify gate',
    steps: const [
      WorkflowStep(
        id: 'seed',
        name: 'Seed',
        prompts: ['PROMPT_SEED'],
        outputs: {'gating_findings_count': OutputConfig()},
      ),
      WorkflowStep(
        id: 'remediate',
        name: 'Remediate',
        prompts: ['PROMPT_REMEDIATE'],
        entryGate: 'gating_findings_count > 0',
        outputs: {'gating_findings_count': OutputConfig()},
      ),
      WorkflowStep(
        id: 'verify-all',
        name: 'Verify All',
        prompts: ['PROMPT_VERIFY_ALL'],
        outputs: {'verify-all.result': OutputConfig()},
      ),
      WorkflowStep(id: 'fix-verification', name: 'Fix Verification', prompts: ['PROMPT_FIX']),
      WorkflowStep(
        id: 'verify-recheck',
        name: 'Verify Recheck',
        prompts: ['PROMPT_VERIFY_RECHECK'],
        outputs: {'verify-recheck.result': OutputConfig()},
      ),
    ],
    loops: [
      WorkflowLoop(
        id: 'remediation-loop',
        steps: const ['remediate'],
        maxIterations: 2,
        entryGate: 'gating_findings_count > 0',
        exitGate: 'gating_findings_count == 0',
        onMaxIterations: remediationPolicy,
      ),
      const WorkflowLoop(
        id: 'verify-fix-loop',
        steps: ['fix-verification', 'verify-recheck'],
        maxIterations: 2,
        entryGate: 'verify-all.result == fail',
        exitGate: 'verify-recheck.result == pass',
      ),
    ],
  );

  /// Drives queued tasks to completion, injecting per-step `<workflow-context>`
  /// outputs. When [recheckPasses] is false, `verify-recheck.result` always
  /// reports `fail`, so the verify-fix-loop exhausts at its default fail policy.
  StreamSubscription<TaskStatusChangedEvent> driveWith({required bool recheckPasses, String verifyAllResult = 'fail'}) {
    return h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      final desc = task?.description ?? '';
      Map<String, dynamic>? outputs;
      if (desc.contains('PROMPT_SEED') || desc.contains('PROMPT_REMEDIATE')) {
        // Keep a gating finding open so the remediation loop never converges.
        outputs = {'gating_findings_count': 1};
      } else if (desc.contains('PROMPT_VERIFY_ALL')) {
        outputs = {'verify-all.result': verifyAllResult};
      } else if (desc.contains('PROMPT_VERIFY_RECHECK')) {
        outputs = {'verify-recheck.result': recheckPasses ? 'pass' : 'fail'};
      }

      if (outputs != null) {
        final session = await h.sessionService.createSession(type: SessionType.task);
        await h.taskService.updateFields(e.taskId, sessionId: session.id);
        await h.messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content: '<workflow-context>${jsonEncode(outputs)}</workflow-context>',
        );
      }
      await h.completeTask(e.taskId);
    });
  }

  test('exhaustion with continue flows through verify-all → verify-fix-loop to completed (TI07)', () async {
    final definition = fallthroughDefinition(remediationPolicy: WorkflowLoop.onMaxIterationsContinue);
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    final completedStepIds = <String>[];
    final stepSub = h.eventBus.on<WorkflowStepCompletedEvent>().listen((e) => completedStepIds.add(e.stepId));
    final taskSub = driveWith(recheckPasses: true);

    await h.executor.execute(run, definition, WorkflowContext());
    await taskSub.cancel();
    await stepSub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    // Execution reached the verify gate after the remediation loop exhausted.
    expect(completedStepIds, contains('verify-all'));
    expect(completedStepIds, contains('verify-recheck'));
  });

  test('a verify-fix-loop that never enters marks its body steps skipped with the gate reason', () async {
    // verify-all reports pass, so the verify-fix-loop's entryGate
    // (`verify-all.result == fail`) is false and the loop never enters. Its body
    // steps must read as skipped (with the gate as the reason) via the shared
    // status mapper — not linger at the default "pending" that reads as
    // unfinished to the digest/UI.
    final definition = fallthroughDefinition(remediationPolicy: WorkflowLoop.onMaxIterationsContinue);
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    final taskSub = driveWith(recheckPasses: true, verifyAllResult: 'pass');
    await h.executor.execute(run, definition, WorkflowContext());
    await taskSub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));

    final fixIndex = definition.steps.indexWhere((s) => s.id == 'fix-verification');
    final recheckIndex = definition.steps.indexWhere((s) => s.id == 'verify-recheck');
    expect(stepStatusFromTask(finalRun!, fixIndex, null, stepId: 'fix-verification'), equals('skipped'));
    expect(stepStatusFromTask(finalRun, recheckIndex, null, stepId: 'verify-recheck'), equals('skipped'));

    final contextData = (finalRun.contextJson['data'] as Map).cast<String, dynamic>();
    expect(contextData['step.fix-verification.outcome.reason'], equals('verify-all.result == fail'));
    expect(contextData['step.verify-recheck.outcome.reason'], equals('verify-all.result == fail'));
  });

  test('switching the remediation policy back to fail halts before verify-all (TI07 control)', () async {
    final definition = fallthroughDefinition(remediationPolicy: WorkflowLoop.onMaxIterationsFail);
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    final completedStepIds = <String>[];
    final stepSub = h.eventBus.on<WorkflowStepCompletedEvent>().listen((e) => completedStepIds.add(e.stepId));
    final taskSub = driveWith(recheckPasses: true);

    await h.executor.execute(run, definition, WorkflowContext());
    await taskSub.cancel();
    await stepSub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(completedStepIds, isNot(contains('verify-all')));
  });

  test('a non-mechanical residual fails the run from verify-fix-loop exhaustion (TI08)', () async {
    final definition = fallthroughDefinition(remediationPolicy: WorkflowLoop.onMaxIterationsContinue);
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    final completedStepIds = <String>[];
    final stepSub = h.eventBus.on<WorkflowStepCompletedEvent>().listen((e) => completedStepIds.add(e.stepId));
    // verify-recheck never reports pass: verify-fix-loop exhausts at its default
    // fail policy, so the run fails from the verify gate, not the remediation loop.
    final taskSub = driveWith(recheckPasses: false);

    await h.executor.execute(run, definition, WorkflowContext());
    await taskSub.cancel();
    await stepSub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    // The verify gate did run (so the failure is the gate, not a silent halt).
    expect(completedStepIds, contains('verify-all'));
    expect(finalRun?.errorMessage, contains('verify-fix-loop'));
  });
}
