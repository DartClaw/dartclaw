import 'package:dartclaw_core/dartclaw_core.dart'
    show
        EventBus,
        LoopIterationCompletedEvent,
        ParallelGroupCompletedEvent,
        WorkflowLifecycleEvent,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowStepCompletedEvent;
import 'package:test/test.dart';

void main() {
  group('WorkflowRunStatusChangedEvent', () {
    test('constructs with required fields', () {
      final event = WorkflowRunStatusChangedEvent(
        runId: 'run-1',
        definitionName: 'my-workflow',
        oldStatus: WorkflowRunStatus.running,
        newStatus: WorkflowRunStatus.completed,
        timestamp: DateTime(2026, 4, 1),
      );

      expect(event.runId, equals('run-1'));
      expect(event.definitionName, equals('my-workflow'));
      expect(event.oldStatus, equals(WorkflowRunStatus.running));
      expect(event.newStatus, equals(WorkflowRunStatus.completed));
      expect(event.errorMessage, isNull);
    });

    test('constructs with optional errorMessage', () {
      final event = WorkflowRunStatusChangedEvent(
        runId: 'run-2',
        definitionName: 'workflow',
        oldStatus: WorkflowRunStatus.running,
        newStatus: WorkflowRunStatus.paused,
        errorMessage: 'Step failed: step1',
        timestamp: DateTime.now(),
      );

      expect(event.errorMessage, equals('Step failed: step1'));
    });

    test('toString includes run ID and status transition', () {
      final event = WorkflowRunStatusChangedEvent(
        runId: 'run-abc',
        definitionName: 'workflow',
        oldStatus: WorkflowRunStatus.pending,
        newStatus: WorkflowRunStatus.running,
        timestamp: DateTime.now(),
      );

      final str = event.toString();
      expect(str, contains('run-abc'));
      expect(str, contains('pending'));
      expect(str, contains('running'));
    });

    test('is a WorkflowLifecycleEvent', () {
      final event = WorkflowRunStatusChangedEvent(
        runId: 'run-1',
        definitionName: 'workflow',
        oldStatus: WorkflowRunStatus.running,
        newStatus: WorkflowRunStatus.completed,
        timestamp: DateTime.now(),
      );

      expect(event, isA<WorkflowLifecycleEvent>());
    });
  });

  group('WorkflowStepCompletedEvent', () {
    test('constructs with required fields', () {
      final event = WorkflowStepCompletedEvent(
        runId: 'run-1',
        stepId: 'step1',
        stepName: 'Research Step',
        stepIndex: 0,
        totalSteps: 3,
        taskId: 'task-abc',
        displayScope: 'S01',
        success: true,
        tokenCount: 12500,
        timestamp: DateTime(2026, 4, 1),
      );

      expect(event.runId, equals('run-1'));
      expect(event.stepId, equals('step1'));
      expect(event.stepName, equals('Research Step'));
      expect(event.stepIndex, equals(0));
      expect(event.totalSteps, equals(3));
      expect(event.taskId, equals('task-abc'));
      expect(event.displayScope, equals('S01'));
      expect(event.success, isTrue);
      expect(event.tokenCount, equals(12500));
    });

    test('is a WorkflowLifecycleEvent', () {
      final event = WorkflowStepCompletedEvent(
        runId: 'run-1',
        stepId: 'step1',
        stepName: 'Step 1',
        stepIndex: 0,
        totalSteps: 2,
        taskId: 'task-1',
        success: false,
        tokenCount: 0,
        timestamp: DateTime.now(),
      );

      expect(event, isA<WorkflowLifecycleEvent>());
    });

    test('toString includes run ID, step ID, and success flag', () {
      final event = WorkflowStepCompletedEvent(
        runId: 'run-xyz',
        stepId: 'analyze',
        stepName: 'Analyze',
        stepIndex: 1,
        totalSteps: 5,
        taskId: 'task-99',
        success: true,
        tokenCount: 5000,
        timestamp: DateTime.now(),
      );

      final str = event.toString();
      expect(str, contains('run-xyz'));
      expect(str, contains('analyze'));
      expect(str, contains('true'));
    });
  });

  group('EventBus filtering', () {
    late EventBus eventBus;

    setUp(() {
      eventBus = EventBus();
    });

    tearDown(() async {
      await eventBus.dispose();
    });

    test('can filter WorkflowRunStatusChangedEvent by type', () async {
      final received = <WorkflowRunStatusChangedEvent>[];
      final sub = eventBus.on<WorkflowRunStatusChangedEvent>().listen(received.add);

      eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: 'run-1',
          definitionName: 'workflow',
          oldStatus: WorkflowRunStatus.pending,
          newStatus: WorkflowRunStatus.running,
          timestamp: DateTime.now(),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(received.length, equals(1));
      expect(received.first.runId, equals('run-1'));
    });

    test('can filter WorkflowStepCompletedEvent by type', () async {
      final received = <WorkflowStepCompletedEvent>[];
      final sub = eventBus.on<WorkflowStepCompletedEvent>().listen(received.add);

      eventBus.fire(
        WorkflowStepCompletedEvent(
          runId: 'run-1',
          stepId: 'step1',
          stepName: 'Step 1',
          stepIndex: 0,
          totalSteps: 3,
          taskId: 'task-1',
          success: true,
          tokenCount: 100,
          timestamp: DateTime.now(),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(received.length, equals(1));
    });

    test('WorkflowLifecycleEvent matches both subtypes', () async {
      final received = <WorkflowLifecycleEvent>[];
      final sub = eventBus.on<WorkflowLifecycleEvent>().listen(received.add);

      eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: 'run-1',
          definitionName: 'workflow',
          oldStatus: WorkflowRunStatus.running,
          newStatus: WorkflowRunStatus.completed,
          timestamp: DateTime.now(),
        ),
      );
      eventBus.fire(
        WorkflowStepCompletedEvent(
          runId: 'run-1',
          stepId: 'step1',
          stepName: 'Step 1',
          stepIndex: 0,
          totalSteps: 1,
          taskId: 'task-1',
          success: true,
          tokenCount: 500,
          timestamp: DateTime.now(),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(received.length, equals(2));
    });
  });

  group('ParallelGroupCompletedEvent', () {
    test('constructs with required fields', () {
      final event = ParallelGroupCompletedEvent(
        runId: 'run-1',
        stepIds: ['step1', 'step2', 'step3'],
        successCount: 2,
        failureCount: 1,
        totalTokens: 5000,
        timestamp: DateTime(2026, 4, 1),
      );

      expect(event.runId, equals('run-1'));
      expect(event.stepIds, equals(['step1', 'step2', 'step3']));
      expect(event.successCount, equals(2));
      expect(event.failureCount, equals(1));
      expect(event.totalTokens, equals(5000));
    });

    test('is a WorkflowLifecycleEvent', () {
      final event = ParallelGroupCompletedEvent(
        runId: 'run-1',
        stepIds: ['step1'],
        successCount: 1,
        failureCount: 0,
        totalTokens: 100,
        timestamp: DateTime.now(),
      );
      expect(event, isA<WorkflowLifecycleEvent>());
    });

    test('toString includes run ID and counts', () {
      final event = ParallelGroupCompletedEvent(
        runId: 'run-xyz',
        stepIds: ['a', 'b'],
        successCount: 2,
        failureCount: 0,
        totalTokens: 200,
        timestamp: DateTime.now(),
      );
      final str = event.toString();
      expect(str, contains('run-xyz'));
      expect(str, contains('2'));
    });

    test('can filter via EventBus.on<ParallelGroupCompletedEvent>()', () async {
      final bus = EventBus();
      final received = <ParallelGroupCompletedEvent>[];
      final sub = bus.on<ParallelGroupCompletedEvent>().listen(received.add);

      bus.fire(
        ParallelGroupCompletedEvent(
          runId: 'run-1',
          stepIds: ['s1', 's2'],
          successCount: 2,
          failureCount: 0,
          totalTokens: 1000,
          timestamp: DateTime.now(),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await bus.dispose();

      expect(received.length, equals(1));
    });
  });

  group('LoopIterationCompletedEvent', () {
    test('constructs with required fields', () {
      final event = LoopIterationCompletedEvent(
        runId: 'run-1',
        loopId: 'review-loop',
        iteration: 2,
        maxIterations: 5,
        gateResult: false,
        timestamp: DateTime(2026, 4, 1),
      );

      expect(event.runId, equals('run-1'));
      expect(event.loopId, equals('review-loop'));
      expect(event.iteration, equals(2));
      expect(event.maxIterations, equals(5));
      expect(event.gateResult, isFalse);
    });

    test('is a WorkflowLifecycleEvent', () {
      final event = LoopIterationCompletedEvent(
        runId: 'run-1',
        loopId: 'loop1',
        iteration: 1,
        maxIterations: 3,
        gateResult: true,
        timestamp: DateTime.now(),
      );
      expect(event, isA<WorkflowLifecycleEvent>());
    });

    test('toString includes loop ID and gate result', () {
      final event = LoopIterationCompletedEvent(
        runId: 'run-abc',
        loopId: 'fix-loop',
        iteration: 3,
        maxIterations: 5,
        gateResult: true,
        timestamp: DateTime.now(),
      );
      final str = event.toString();
      expect(str, contains('run-abc'));
      expect(str, contains('fix-loop'));
      expect(str, contains('true'));
    });

    test('can filter via EventBus.on<LoopIterationCompletedEvent>()', () async {
      final bus = EventBus();
      final received = <LoopIterationCompletedEvent>[];
      final sub = bus.on<LoopIterationCompletedEvent>().listen(received.add);

      bus.fire(
        LoopIterationCompletedEvent(
          runId: 'run-1',
          loopId: 'loop1',
          iteration: 1,
          maxIterations: 3,
          gateResult: false,
          timestamp: DateTime.now(),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await bus.dispose();

      expect(received.length, equals(1));
    });

    test('WorkflowLifecycleEvent matches all workflow event subtypes', () async {
      final bus = EventBus();
      final received = <WorkflowLifecycleEvent>[];
      final sub = bus.on<WorkflowLifecycleEvent>().listen(received.add);

      bus.fire(
        ParallelGroupCompletedEvent(
          runId: 'run-1',
          stepIds: ['s1'],
          successCount: 1,
          failureCount: 0,
          totalTokens: 0,
          timestamp: DateTime.now(),
        ),
      );
      bus.fire(
        LoopIterationCompletedEvent(
          runId: 'run-1',
          loopId: 'l1',
          iteration: 1,
          maxIterations: 2,
          gateResult: true,
          timestamp: DateTime.now(),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await bus.dispose();

      expect(received.length, equals(2));
    });
  });
}
