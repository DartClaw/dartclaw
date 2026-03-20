import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('ScheduledJob.fromConfig unified type', () {
    test('type: prompt explicit', () {
      final job = ScheduledJob.fromConfig({
        'id': 'daily-report',
        'type': 'prompt',
        'schedule': '0 9 * * *',
        'prompt': 'Generate daily report',
        'delivery': 'none',
      });
      expect(job.jobType, equals(ScheduledJobType.prompt));
      expect(job.taskDefinition, isNull);
    });

    test('defaults to prompt when type omitted', () {
      final job = ScheduledJob.fromConfig({
        'id': 'daily-report',
        'schedule': '0 9 * * *',
        'prompt': 'Generate daily report',
        'delivery': 'none',
      });
      expect(job.jobType, equals(ScheduledJobType.prompt));
    });

    test('type: task with task sub-map', () {
      final job = ScheduledJob.fromConfig({
        'id': 'nightly-analysis',
        'type': 'task',
        'schedule': '0 2 * * *',
        'task': {'title': 'Nightly analysis', 'description': 'Run nightly analysis', 'task_type': 'research'},
      });
      expect(job.jobType, equals(ScheduledJobType.task));
      expect(job.taskDefinition, isNotNull);
      expect(job.taskDefinition!.title, equals('Nightly analysis'));
    });

    test('type: task does not require prompt', () {
      // No prompt key — should not throw
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'task-job',
          'type': 'task',
          'schedule': '0 * * * *',
          'task': {'title': 'T', 'description': 'D', 'task_type': 'research'},
        }),
        returnsNormally,
      );
    });

    test('type: prompt still requires prompt', () {
      expect(
        () => ScheduledJob.fromConfig({'id': 'prompt-job', 'type': 'prompt', 'schedule': '0 * * * *'}),
        throwsFormatException,
      );
    });

    test('model and effort parsed for prompt jobs', () {
      final job = ScheduledJob.fromConfig({
        'id': 'job',
        'schedule': '0 * * * *',
        'prompt': 'Do something',
        'delivery': 'none',
        'model': 'claude-haiku-4-5',
        'effort': 'low',
      });
      expect(job.model, equals('claude-haiku-4-5'));
      expect(job.effort, equals('low'));
    });

    test('taskDefinition populated for task jobs', () {
      final warnings = <String>[];
      final job = ScheduledJob.fromConfig({
        'id': 'task-job',
        'type': 'task',
        'schedule': '0 0 * * *',
        'task': {'title': 'My Task', 'description': 'Description', 'task_type': 'coding', 'model': 'claude-sonnet-4-6'},
      }, warnings);
      expect(job.taskDefinition, isNotNull);
      expect(job.taskDefinition!.model, equals('claude-sonnet-4-6'));
      expect(warnings, isEmpty);
    });

    test('taskDefinition has correct type from task_type key', () {
      final job = ScheduledJob.fromConfig({
        'id': 'research-task',
        'type': 'task',
        'schedule': '0 6 * * *',
        'task': {'title': 'Research Task', 'description': 'Do some research', 'task_type': 'research'},
      });
      expect(job.taskDefinition, isNotNull);
      expect(job.taskDefinition!.title, equals('Research Task'));
    });

    test('task job missing task section throws FormatException', () {
      expect(
        () => ScheduledJob.fromConfig({'id': 'broken-task', 'type': 'task', 'schedule': '0 0 * * *'}),
        throwsFormatException,
      );
    });

    test('prompt job model and effort are null when not specified', () {
      final job = ScheduledJob.fromConfig({
        'id': 'plain-job',
        'schedule': '0 * * * *',
        'prompt': 'Do something plain',
        'delivery': 'none',
      });
      expect(job.model, isNull);
      expect(job.effort, isNull);
    });

    test('task job inherits schedule parsed correctly', () {
      final job = ScheduledJob.fromConfig({
        'id': 'cron-task',
        'type': 'task',
        'schedule': '30 8 * * 1',
        'task': {'title': 'Weekly Coding Task', 'description': 'Weekly code review', 'task_type': 'coding'},
      });
      expect(job.scheduleType, equals(ScheduleType.cron));
      expect(job.cronExpression, isNotNull);
      expect(job.jobType, equals(ScheduledJobType.task));
    });
  });
}
