import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import 'package:dartclaw_server/src/scheduling/scheduled_task_runner.dart';

ScheduledTaskDefinition _makeDef({
  String id = 'test-schedule',
  String cron = '0 9 * * 1',
  bool enabled = true,
  String title = 'Test Task',
  String description = 'Test description',
  TaskType type = TaskType.research,
  String? acceptanceCriteria,
  bool autoStart = true,
  String? model,
  String? effort,
  int? tokenBudget,
}) => ScheduledTaskDefinition(
  id: id,
  cronExpression: cron,
  enabled: enabled,
  title: title,
  description: description,
  type: type,
  acceptanceCriteria: acceptanceCriteria,
  autoStart: autoStart,
  model: model,
  effort: effort,
  tokenBudget: tokenBudget,
);

void main() {
  group('ScheduledTaskRunner', () {
    late InMemoryTaskRepository repo;
    late TaskService taskService;

    setUp(() {
      repo = InMemoryTaskRepository();
      taskService = TaskService(repo);
    });

    test('buildJobs returns one job per enabled definition', () {
      final runner = ScheduledTaskRunner(
        taskService: taskService,
        definitions: [
          _makeDef(id: 'a', enabled: true),
          _makeDef(id: 'b', enabled: false),
          _makeDef(id: 'c', enabled: true),
        ],
      );

      final jobs = runner.buildJobs();
      expect(jobs.length, 2);
      expect(jobs.map((j) => j.id).toList(), ['auto-task-a', 'auto-task-c']);
    });

    test('disabled definitions produce no jobs', () {
      final runner = ScheduledTaskRunner(taskService: taskService, definitions: [_makeDef(enabled: false)]);
      expect(runner.buildJobs(), isEmpty);
    });

    test('invalid cron expression skips definition', () {
      final runner = ScheduledTaskRunner(
        taskService: taskService,
        definitions: [_makeDef(cron: 'invalid')],
      );
      expect(runner.buildJobs(), isEmpty);
    });

    test('creates task when cron fires and no open task exists', () async {
      final def = _makeDef(
        id: 'weekly',
        title: 'Weekly Report',
        description: 'Generate report',
        type: TaskType.research,
        acceptanceCriteria: 'Must include commits',
      );
      final runner = ScheduledTaskRunner(taskService: taskService, definitions: [def]);
      final jobs = runner.buildJobs();
      expect(jobs.length, 1);

      // Execute the job
      final result = await jobs.first.onExecute!();
      expect(result, contains('Created task'));
      expect(result, contains('weekly'));

      // Verify task was created
      final tasks = await taskService.list();
      expect(tasks.length, 1);
      expect(tasks.first.title, 'Weekly Report');
      expect(tasks.first.description, 'Generate report');
      expect(tasks.first.type, TaskType.research);
      expect(tasks.first.acceptanceCriteria, 'Must include commits');
      expect(tasks.first.configJson['scheduleId'], 'weekly');
    });

    test('task created with autoStart: true has queued status', () async {
      final runner = ScheduledTaskRunner(taskService: taskService, definitions: [_makeDef(autoStart: true)]);
      final jobs = runner.buildJobs();
      await jobs.first.onExecute!();

      final tasks = await taskService.list();
      expect(tasks.first.status, TaskStatus.queued);
    });

    test('task created with autoStart: false has draft status', () async {
      final runner = ScheduledTaskRunner(taskService: taskService, definitions: [_makeDef(autoStart: false)]);
      final jobs = runner.buildJobs();
      await jobs.first.onExecute!();

      final tasks = await taskService.list();
      expect(tasks.first.status, TaskStatus.draft);
    });

    test('skips task creation when open task with same scheduleId exists', () async {
      // Pre-create an open task for this schedule
      await taskService.create(
        id: 'existing-task',
        title: 'Existing',
        description: 'Existing task',
        type: TaskType.research,
        configJson: {'scheduleId': 'test-schedule'},
      );

      final runner = ScheduledTaskRunner(
        taskService: taskService,
        definitions: [_makeDef(id: 'test-schedule')],
      );
      final jobs = runner.buildJobs();
      final result = await jobs.first.onExecute!();

      expect(result, contains('Skipped'));
      expect(result, contains('existing-task'));

      // Should still only have 1 task
      final tasks = await taskService.list();
      expect(tasks.length, 1);
    });

    test('creates task after previous task reaches terminal status', () async {
      // Create a previously completed review task
      final existing = await taskService.create(
        id: 'old-task',
        title: 'Old',
        description: 'Old task',
        type: TaskType.research,
        autoStart: true,
        configJson: {'scheduleId': 'test-schedule'},
      );
      // Transition to terminal status
      await taskService.transition(existing.id, TaskStatus.running);
      await taskService.transition(existing.id, TaskStatus.review);
      await taskService.transition(existing.id, TaskStatus.accepted);

      final runner = ScheduledTaskRunner(
        taskService: taskService,
        definitions: [_makeDef(id: 'test-schedule')],
      );
      final jobs = runner.buildJobs();
      final result = await jobs.first.onExecute!();

      expect(result, contains('Created task'));

      // Should have 2 tasks now
      final tasks = await taskService.list();
      expect(tasks.length, 2);
    });

    test('task configJson contains scheduleId', () async {
      final runner = ScheduledTaskRunner(
        taskService: taskService,
        definitions: [_makeDef(id: 'my-schedule')],
      );
      final jobs = runner.buildJobs();
      await jobs.first.onExecute!();

      final tasks = await taskService.list();
      expect(tasks.first.configJson, containsPair('scheduleId', 'my-schedule'));
    });

    test('task created with correct template fields', () async {
      final def = _makeDef(
        title: 'Specific Title',
        description: 'Specific Description',
        type: TaskType.analysis,
        acceptanceCriteria: 'AC here',
      );
      final runner = ScheduledTaskRunner(taskService: taskService, definitions: [def]);
      final jobs = runner.buildJobs();
      await jobs.first.onExecute!();

      final task = (await taskService.list()).first;
      expect(task.title, 'Specific Title');
      expect(task.description, 'Specific Description');
      expect(task.type, TaskType.analysis);
      expect(task.acceptanceCriteria, 'AC here');
    });

    test('generated task ID contains schedule ID', () async {
      final runner = ScheduledTaskRunner(
        taskService: taskService,
        definitions: [_makeDef(id: 'my-sched')],
      );
      final jobs = runner.buildJobs();
      await jobs.first.onExecute!();

      final task = (await taskService.list()).first;
      expect(task.id, startsWith('sched-my-sched-'));
    });

    group('configJson override merging', () {
      test('configJson contains model/effort/tokenBudget when set', () async {
        final def = _makeDef(
          id: 'override-sched',
          model: 'claude-haiku-4-5',
          effort: 'low',
          tokenBudget: 50000,
        );
        final runner = ScheduledTaskRunner(taskService: taskService, definitions: [def]);
        final jobs = runner.buildJobs();
        await jobs.first.onExecute!();

        final task = (await taskService.list()).first;
        expect(task.configJson['scheduleId'], 'override-sched');
        expect(task.configJson['model'], 'claude-haiku-4-5');
        expect(task.configJson['effort'], 'low');
        expect(task.configJson['tokenBudget'], 50000);
      });

      test('configJson omits model/effort/tokenBudget when not set', () async {
        final def = _makeDef(id: 'minimal-sched');
        final runner = ScheduledTaskRunner(taskService: taskService, definitions: [def]);
        final jobs = runner.buildJobs();
        await jobs.first.onExecute!();

        final task = (await taskService.list()).first;
        expect(task.configJson, containsPair('scheduleId', 'minimal-sched'));
        expect(task.configJson.containsKey('model'), isFalse);
        expect(task.configJson.containsKey('effort'), isFalse);
        expect(task.configJson.containsKey('tokenBudget'), isFalse);
      });
    });
  });
}
