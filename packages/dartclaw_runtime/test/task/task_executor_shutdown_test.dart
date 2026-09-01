import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

import 'task_executor_test_support.dart';

void main() {
  late FakeTaskWorker worker;
  late _PausingSqliteTaskRepository repository;
  late TaskExecutorTestHarness harness;
  late TaskExecutor executor;

  setUp(() async {
    worker = FakeTaskWorker()..shouldFail = true;
    harness = TaskExecutorTestHarness(worker);
    await harness.setUp(taskRepositoryFactory: (database) => repository = _PausingSqliteTaskRepository(database));
    executor = harness.buildWorkflowExecutor();
  });

  tearDown(() async {
    await harness.tearDown(executor: executor, workerDispose: worker.dispose);
  });

  for (final settledStatus in [TaskStatus.review, TaskStatus.failed]) {
    test('shutdown tolerates a concurrent running-to-${settledStatus.name} settlement', () async {
      final workerStarted = Completer<void>();
      final releaseWorker = Completer<void>();
      worker.beforeComplete = (_) {
        workerStarted.complete();
        return releaseWorker.future;
      };
      final taskId = 'shutdown-settlement-${settledStatus.name}';
      await harness.tasks.create(
        id: taskId,
        title: 'Concurrent shutdown settlement',
        description: 'Settlement must not reject shutdown.',
        autoStart: true,
      );
      repository.pauseNextCancellation();

      await executor.pollOnce();
      await workerStarted.future;
      final cancellation = executor.cancelActive();
      await repository.cancellationPaused;
      await repository.settle(taskId, settledStatus);
      repository.resumeCancellation();

      Object? cancellationError;
      try {
        await cancellation;
      } catch (error) {
        cancellationError = error;
      }
      releaseWorker.complete();
      await executor.drain();

      expect(cancellationError, isNull);
      expect(worker.cancelCallCount, 1);
      expect((await harness.tasks.get(taskId))?.status.terminal, isTrue);
    });
  }

  test('shutdown retries an optimistic cancellation conflict while the task remains running', () async {
    final workerStarted = Completer<void>();
    final releaseWorker = Completer<void>();
    worker.beforeComplete = (_) {
      workerStarted.complete();
      return releaseWorker.future;
    };
    await harness.tasks.create(
      id: 'shutdown-running-retry',
      title: 'Concurrent running update',
      description: 'Cancellation must retry while the task remains running.',
      autoStart: true,
    );
    repository.rejectNextCancellationWhileRunning();

    await executor.pollOnce();
    await workerStarted.future;
    await executor.cancelActive();
    releaseWorker.complete();
    await executor.drain();

    expect(repository.cancellationAttempts, 2);
    expect(worker.cancelCallCount, 1);
    expect((await harness.tasks.get('shutdown-running-retry'))?.status, TaskStatus.cancelled);
  });
}

final class _PausingSqliteTaskRepository extends SqliteTaskRepository {
  new(super.database);

  Completer<void>? _cancellationPaused;
  Completer<void>? _resumeCancellation;
  var _rejectCancellation = false;
  var cancellationAttempts = 0;

  Future<void> get cancellationPaused => _cancellationPaused!.future;

  void pauseNextCancellation() {
    _cancellationPaused = Completer<void>();
    _resumeCancellation = Completer<void>();
  }

  void resumeCancellation() => _resumeCancellation!.complete();

  void rejectNextCancellationWhileRunning() => _rejectCancellation = true;

  Future<void> settle(String taskId, TaskStatus status) async {
    final running = await super.getById(taskId);
    if (running == null) throw StateError('Task not found: $taskId');
    final updated = await super.updateIfStatus(running.transition(status), expectedStatus: TaskStatus.running);
    if (!updated) throw StateError('Task was not running: $taskId');
  }

  @override
  Future<bool> updateIfStatus(Task task, {required TaskStatus expectedStatus}) async {
    if (task.status == TaskStatus.cancelled) {
      cancellationAttempts++;
      if (_rejectCancellation) {
        _rejectCancellation = false;
        return false;
      }
      if (_cancellationPaused != null) {
        _cancellationPaused!.complete();
        await _resumeCancellation!.future;
        _cancellationPaused = null;
        _resumeCancellation = null;
      }
    }
    return super.updateIfStatus(task, expectedStatus: expectedStatus);
  }
}
