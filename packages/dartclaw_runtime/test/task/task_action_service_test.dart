import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/task/task_budget_policy.dart' show lastFailureKindKey;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late TaskService tasks;
  late TaskActionService actions;

  setUp(() {
    db = openTaskDbInMemory();
    tasks = TaskService(SqliteTaskRepository(db));
    actions = TaskActionService(
      tasks: tasks,
      reviewService: TaskReviewService(tasks: tasks),
    );
  });

  tearDown(() async {
    await tasks.dispose();
  });

  Future<void> failAfterRetries(String id) async {
    await tasks.create(
      id: id,
      title: 'Retried task',
      description: 'Failed after exhausting its retries.',
      autoStart: true,
      maxRetries: 3,
    );
    await tasks.updateFields(
      id,
      retryCount: 2,
      configJson: const {
        'lastError': 'harness exited with code 1',
        'errorSummary': 'Budget exceeded: used 120000 tokens against a limit of 100000 tokens',
        lastFailureKindKey: 'failure:TurnFailure',
      },
    );
    await tasks.transition(id, TaskStatus.failed);
  }

  group('start', () {
    test('restarting a failed task queues it as a fresh attempt', () async {
      await failAfterRetries('task-restart');

      final result = await actions.start('task-restart');

      expect(result, isA<TaskActionSuccess>());
      final restarted = (await tasks.get('task-restart'))!;
      expect(restarted.status, TaskStatus.queued);
      // A stale retry budget or failure kind would make the restart's first
      // failure look like a repeat of the previous run and stop the retries.
      expect(restarted.retryCount, 0);
      expect(restarted.configJson.containsKey(lastFailureKindKey), isFalse);
      expect(restarted.configJson.containsKey('lastError'), isFalse);
      // The detail surface and the failure notification read `errorSummary`, so
      // an inherited one narrates the previous run's failure over a live attempt.
      expect(restarted.configJson.containsKey('errorSummary'), isFalse);
    });

    test('starting a draft task leaves its config untouched', () async {
      await tasks.create(
        id: 'task-draft',
        title: 'Draft task',
        description: 'Never ran.',
        configJson: const {'needsWorktree': true},
      );

      expect(await actions.start('task-draft'), isA<TaskActionSuccess>());
      final started = (await tasks.get('task-draft'))!;
      expect(started.status, TaskStatus.queued);
      expect(started.configJson['needsWorktree'], isTrue);
    });
  });
}
