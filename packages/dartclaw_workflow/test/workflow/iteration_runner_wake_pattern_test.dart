import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show TaskStatus, TaskStatusChangedEvent, WorkflowContext, WorkflowDefinition, WorkflowRunStatus, WorkflowStep;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  group('S78 H13 iteration runner wake pattern', () {
    late WorkflowExecutorHarness h;

    setUp(() {
      h = WorkflowExecutorHarness();
      h.setUp();
    });

    tearDown(() => h.tearDown());

    test('map runner completes bounded fan-out when iterations settle asynchronously', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'implement',
            name: 'Implement',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'items',
            maxParallel: 4,
            maxItems: 50,
          ),
        ],
      );
      final context = WorkflowContext(data: {'items': List.generate(30, (i) => 'item-$i')});
      final run = h.makeRun(definition);
      await h.repository.insert(run);

      var queuedCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        queuedCount++;
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, WorkflowRunStatus.completed, reason: finalRun?.errorMessage);
      expect(queuedCount, 30);
    });

    test('foreach runner completes bounded fan-out when child iterations settle asynchronously', () async {
      const definition = WorkflowDefinition(
        name: 'foreach-wake-demo',
        description: 'test',
        steps: [
          WorkflowStep(
            id: 'stories',
            name: 'Stories',
            type: 'foreach',
            mapOver: 'items',
            maxParallel: 4,
            maxItems: 50,
            foreachSteps: ['implement'],
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement {{map.item}}']),
        ],
      );
      final context = WorkflowContext(data: {'items': List.generate(30, (i) => 'item-$i')});
      final run = h.makeRun(definition);
      await h.repository.insert(run);

      var queuedCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        queuedCount++;
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, WorkflowRunStatus.completed, reason: finalRun?.errorMessage);
      expect(queuedCount, 30);
    });

    test('foreach and map runners use completer wake instead of Future.any plus 1ms tick', () {
      for (final path in [
        _workflowSourcePath('foreach_iteration_runner.dart'),
        _workflowSourcePath('map_iteration_runner.dart'),
      ]) {
        final source = File(path).readAsStringSync();

        expect(
          source,
          isNot(contains('Future.any(inFlight.values)')),
          reason: '$path must not re-listen to in-flight futures per loop tick',
        );
        expect(
          source,
          isNot(matches(RegExp(r'Future<void>\.delayed\(\s*const Duration\(milliseconds:\s*1\)\s*\)'))),
          reason: '$path must not use a 1ms timer tick after in-flight completion',
        );
        expect(source, contains('Completer<void>'), reason: '$path should use a shared completer wake');
        expect(
          source,
          contains('wakeInFlightLoop'),
          reason: '$path should pump the shared wake from completion handlers',
        );
        expect(source, contains('whenComplete'), reason: '$path should wake when an iteration future settles');
        expect(source, contains('catchError'), reason: '$path should absorb async errors from iteration futures');
      }
    });
  });
}

String _workflowSourcePath(String fileName) {
  const relative = 'lib/src/workflow';
  const packaged = 'packages/dartclaw_workflow/lib/src/workflow';
  for (final candidate in ['$relative/$fileName', '$packaged/$fileName']) {
    if (File(candidate).existsSync()) return candidate;
  }
  return '$relative/$fileName';
}
