import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'package:dartclaw_runtime/src/scheduling/scheduled_job.dart';
import 'package:dartclaw_runtime/src/scheduling/scheduled_task_runner.dart';
import 'package:dartclaw_runtime/src/task/task_service.dart';

ScheduledTaskDefinition _makeDef({
  String id = 'test-schedule',
  String cron = '0 9 * * 1',
  bool enabled = true,
  String title = 'Test Task',
  String description = 'Test description',
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
      final def = _makeDef(title: 'Specific Title', description: 'Specific Description', acceptanceCriteria: 'AC here');
      final runner = ScheduledTaskRunner(taskService: taskService, definitions: [def]);
      final jobs = runner.buildJobs();
      await jobs.first.onExecute!();

      final task = (await taskService.list()).first;
      expect(task.title, 'Specific Title');
      expect(task.description, 'Specific Description');
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
      test('model is captured on AgentExecution while effort/tokenBudget stay in configJson', () async {
        final def = _makeDef(id: 'override-sched', model: 'claude-haiku-4-5', effort: 'low', tokenBudget: 50000);
        final runner = ScheduledTaskRunner(taskService: taskService, definitions: [def]);
        final jobs = runner.buildJobs();
        await jobs.first.onExecute!();

        final task = (await taskService.list()).first;
        expect(task.configJson['scheduleId'], 'override-sched');
        // Per S34, `model` is canonical on AgentExecution and no longer persisted
        // in Task.configJson; it surfaces via the task.model accessor instead.
        expect(task.model, 'claude-haiku-4-5');
        expect(task.configJson.containsKey('model'), isFalse);
        expect(task.configJson['effort'], 'low');
        expect(task.configJson['tokenBudget'], 50000);
      });

      test('a legacy automation config registers the same jobs as its scheduling.jobs form', () {
        // The removed key's mechanical rewrite is the upgrade map, so an
        // un-migrated deployment must keep the schedule it has today.
        DartclawConfig load(String yaml) => DartclawConfig.load(
          configPath: 'dartclaw.yaml',
          fileReader: (path) => path == 'dartclaw.yaml' ? yaml : null,
          env: const {'HOME': '/home/user'},
        );

        final legacy = load('''
automation:
  scheduled_tasks:
    - id: nightly
      schedule: "0 9 * * 1"
      task:
        title: Nightly
        description: Nightly sweep
        type: analysis
''');
        final modern = load('''
scheduling:
  jobs:
    - id: nightly
      type: task
      schedule: "0 9 * * 1"
      task:
        title: Nightly
        description: Nightly sweep
        type: analysis
''');

        List<String> jobIds(DartclawConfig config) => ScheduledTaskRunner(
          taskService: taskService,
          definitions: config.scheduling.taskDefinitions,
        ).buildJobs().map((job) => job.id).toList();

        expect(legacy.scheduling.taskDefinitions, modern.scheduling.taskDefinitions);
        expect(jobIds(legacy), jobIds(modern));
        expect(jobIds(legacy), ['auto-task-nightly']);
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

  group('composeConfigJobs shell credential resolution', () {
    late InMemoryTaskRepository repo;
    late TaskService taskService;

    setUp(() {
      repo = InMemoryTaskRepository();
      taskService = TaskService(repo);
    });

    Map<String, dynamic> shellEntry(String id, Map<String, String> env) => <String, dynamic>{
      'id': id,
      'type': 'shell',
      'schedule': '0 * * * *',
      'command': ['/usr/local/bin/hey', 'mail'],
      'env': env,
      'output': '$id.json',
    };

    test('skips a shell job whose credential reference is unpresentable', () {
      final warnings = <String>[];
      final subscription = Logger.root.onRecord
          .where((record) => record.level >= Level.WARNING)
          .listen((record) => warnings.add(record.message));
      addTearDown(subscription.cancel);

      final composed = composeConfigJobs(
        SchedulingConfig(
          jobs: [
            shellEntry('unknown-ref', {'FEED_TOKEN': 'absent'}),
            shellEntry('wrong-type', {'FEED_TOKEN': 'gh'}),
            shellEntry('empty-value', {'FEED_TOKEN': 'blank'}),
            shellEntry('good', {'FEED_TOKEN': 'feed-secret'}),
          ],
        ),
        taskService: taskService,
        credentials: const CredentialsConfig(
          entries: {
            'gh': CredentialEntry.githubToken(token: 'ghp_live'),
            'blank': CredentialEntry(apiKey: ''),
            'feed-secret': CredentialEntry(apiKey: 'sk-live'),
          },
        ),
        dataDir: '/tmp/dartclaw-data',
      );

      // The sibling valid entry is what proves one bad reference drops its own
      // entry rather than the whole list.
      expect(composed.jobs.map((job) => job.id), ['good']);
      expect(composed.jobs.single.jobType, ScheduledJobType.shell);
      expect(composed.jobs.single.onExecute, isNotNull);
      expect(warnings, hasLength(3));
      expect(warnings[0], allOf(contains('"unknown-ref"'), contains('is not a configured credentials entry')));
      expect(warnings[1], allOf(contains('"wrong-type"'), contains('is not an api_key credential')));
      expect(warnings[2], allOf(contains('"empty-value"'), contains('resolves to an empty value')));
      expect(warnings.every((warning) => !warning.contains('sk-live') && !warning.contains('ghp_live')), isTrue);
    });

    test('a shell entry with enabled: false is not loaded and is not reported missed', () {
      final composed = composeConfigJobs(
        SchedulingConfig(jobs: [shellEntry('paused', const {})..['enabled'] = false]),
        taskService: taskService,
        credentials: const CredentialsConfig(),
        dataDir: '/tmp/dartclaw-data',
      );

      expect(composed.jobs, isEmpty);
      expect(composed.missedOnceIds, isEmpty);
    });

    test('a one-time shell entry is refused at parse, so it never reaches the self-removal path', () {
      final composed = composeConfigJobs(
        SchedulingConfig(
          jobs: [
            shellEntry('once-off', const {})..['schedule'] = {'type': 'once', 'at': '2099-01-01T00:00:00'},
            shellEntry('recurring', const {}),
          ],
        ),
        taskService: taskService,
        credentials: const CredentialsConfig(),
        dataDir: '/tmp/dartclaw-data',
      );

      // Refused as malformed, never as a *missed* one-time entry: `missedOnceIds`
      // is what `SchedulingJobsApplier` hands to `removeJobs`, and a shell entry
      // must never reach that write.
      expect(composed.jobs.map((job) => job.id), ['recurring']);
      expect(composed.missedOnceIds, isEmpty);
    });

    test('a shell entry needing no credential loads with its parsed definition', () {
      final composed = composeConfigJobs(
        SchedulingConfig(jobs: [shellEntry('plain', const {})]),
        taskService: taskService,
        credentials: const CredentialsConfig(),
        dataDir: '/tmp/dartclaw-data',
      );

      expect(composed.jobs.single.shellDefinition?.output, 'plain.json');
      expect(composed.jobs.single.onExecute, isNotNull);
    });
  });
}
