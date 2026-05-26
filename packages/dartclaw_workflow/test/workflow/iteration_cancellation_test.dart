// Regression tests for cancellation threading in foreach/map iteration runners.
// Verifies that isCancelled is honoured before each dispatch, preventing
// all-N-pending iterations from being processed when the flag flips early.
@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show TaskStatus, TaskStatusChangedEvent, WorkflowContext, WorkflowStep;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  test('isCancelled after 4 iterations stops dispatch at ≤5 (not all 10)', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(
          id: 'map-step',
          name: 'Map Step',
          prompts: ['Process {{map.item}}'],
          mapOver: 'items',
          maxParallel: 1, // serial dispatch so isCancelled can intercept between items
        ),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    // 10-item collection — without cancellation, all 10 would dispatch.
    final items = List.generate(10, (i) => 'item-$i');
    final context = WorkflowContext()..['items'] = items;

    var dispatchCount = 0;
    var cancelled = false;

    // After 4 tasks are queued, flip the cancelled flag.
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      dispatchCount++;
      if (dispatchCount >= 4) {
        cancelled = true;
      }
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context, isCancelled: () => cancelled);
    await sub.cancel();

    // Cancellation must stop dispatch well before all 10 are processed.
    // Allow ≤5 to account for one in-flight after the flag flips.
    expect(
      dispatchCount,
      lessThanOrEqualTo(5),
      reason: 'Expected cancellation to stop dispatch early, got $dispatchCount',
    );
    expect(dispatchCount, greaterThanOrEqualTo(1), reason: 'At least one iteration should have dispatched');
  });
}
