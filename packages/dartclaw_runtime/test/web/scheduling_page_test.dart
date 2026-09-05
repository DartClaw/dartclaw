import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show MessageService;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/config/scheduling_jobs_applier.dart';
import 'package:dartclaw_runtime/src/templates/scheduling.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_runtime/src/web/pages/scheduling_page.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory workspace;
  late ScheduleService service;
  late ScheduledJob gitSyncJob;

  setUp(() async {
    workspace = Directory.systemTemp.createTempSync('scheduling_page_');
    final gitSync = WorkspaceGitSync(workspaceDir: workspace.path, commandRunner: RecordingGitRunner().run);
    await gitSync.isGitAvailable();
    gitSyncJob = buildWorkspaceGitSyncJob(gitSync, intervalMinutes: 30).job;
    service = ScheduleService(
      turns: FakeTurnManager(),
      sessions: _NoopSessionService(),
      jobs: [
        buildHeartbeatJob(workspaceDir: workspace.path, intervalMinutes: 30),
        gitSyncJob,
      ],
    )..start();
  });

  tearDown(() {
    service.stop();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  Future<String> render() async {
    final page = SchedulingPage(
      // The booted value says enabled; the live pause state must win.
      runtimeConfigGetter: () => RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true),
      scheduleServiceGetter: () => service,
    );
    final response = await page.handler(
      Request('GET', Uri.parse('http://localhost/scheduling')),
      _context(
        config: const DartclawConfig(
          scheduling: SchedulingConfig(heartbeatEnabled: true, heartbeatIntervalMinutes: 30),
        ),
        schedulingJobs: [
          {'name': workspaceGitSyncJobId, 'schedule': 'every 30 minutes', 'delivery': 'none', 'status': 'active'},
        ],
        systemJobNames: [heartbeatJobId, workspaceGitSyncJobId],
      ),
    );
    expect(response.statusCode, 200);
    return response.readAsString();
  }

  test('the heartbeat card reads the live pause state, not the booted value', () async {
    expect(await render(), contains('>Active</span>'));

    service.pauseJob(heartbeatJobId);

    final paused = await render();
    expect(paused, contains('>Disabled</span>'));
    expect(paused, isNot(contains('>Active</span>')));
  });

  test('the git-sync job renders as a system job row, with no duplicate heartbeat row', () async {
    final html = await render();

    expect(RegExp(r'<h1\b').allMatches(html), hasLength(1));
    expect(html, contains('<span class="system-badge">SYSTEM</span>'));
    expect(html, contains('<span>$workspaceGitSyncJobId</span>'));
    expect(html, isNot(contains('<span>$heartbeatJobId</span>')), reason: 'the card must not gain a jobs-table row');
  });

  group('server-rendered scheduling routes', () {
    late String configPath;
    late ConfigWriter writer;
    late SchedulingPage page;

    setUp(() {
      configPath = '${workspace.path}/dartclaw.yaml';
      File(configPath).writeAsStringSync('''
scheduling:
  jobs:
    - name: digest
      schedule: "0 7 * * *"
      type: prompt
      delivery: webhook
      prompt: Existing prompt
''');
      writer = ConfigWriter(configPath: configPath);
      addTearDown(writer.dispose);
      // Wired the way the composition root wires it, so what the page reports
      // about a job is what the running scheduler holds.
      final applier = SchedulingJobsApplier(
        configPath: configPath,
        jobs: ScheduleMutationService(writer: writer),
        scheduleService: () => service,
        taskService: TaskService(InMemoryTaskRepository()),
      );
      page = SchedulingPage(configWriter: writer, scheduleServiceGetter: () => service, applyJobs: applier.apply);
    });

    Future<({int status, String body, Map<String, String> headers})> send(
      String method,
      String path, {
      Map<String, String>? form,
    }) async {
      final request = Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: form == null ? null : {'content-type': 'application/x-www-form-urlencoded'},
        body: form?.entries
            .map((entry) => '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}')
            .join('&'),
      );
      final response = await page.handler(request, _context(dataDir: workspace.path));
      return (status: response.statusCode, body: await response.readAsString(), headers: response.headers);
    }

    Future<({int status, String body, Map<String, String> headers})> sendRouted(
      String method,
      String path, {
      Map<String, String>? form,
    }) async {
      final registry = PageRegistry()..register(page);
      final handler = webRoutes(
        SessionService(baseDir: workspace.path),
        MessageService(baseDir: workspace.path),
        pageRegistry: registry,
        dataDir: workspace.path,
      ).call;
      final request = Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: form == null ? null : {'content-type': 'application/x-www-form-urlencoded'},
        body: form?.entries
            .map((entry) => '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}')
            .join('&'),
      );
      final response = await handler(request);
      return (status: response.statusCode, body: await response.readAsString(), headers: response.headers);
    }

    String submitAction(String fragment) {
      final match = RegExp(r'hx-post="([^"]+)"').firstMatch(fragment);
      expect(match, isNotNull, reason: 'the returned form fragment must carry its correction route');
      return match!.group(1)!;
    }

    test('S01 create returns the fresh jobs table, closes the form, and writes YAML', () async {
      await writer.updateFields({'scheduling.jobs': <Map<String, dynamic>>[]});
      final response = await send(
        'POST',
        '/scheduling/jobs/create',
        form: {'name': 'digest', 'schedule': '0 7 * * *', 'prompt': 'Run digest', 'delivery': 'announce'},
      );

      expect(response.status, 200);
      expect(response.body, contains('id="job-form" hidden=""'));
      expect(response.body, contains('digest'));
      expect(response.body, contains('hx-swap-oob="true"'));
      // S08: the write is already live, so there is no restart banner to raise
      // and no restart wording in the toast.
      expect(response.body, isNot(contains('id="restart-banner"')));
      final trigger = jsonDecode(response.headers['hx-trigger-after-swap']!) as Map<String, dynamic>;
      expect((trigger['dc:toast'] as Map)['message'], 'Job added');
      expect((await writer.readSchedulingJobs()).map((job) => job['name']), contains('digest'));
      expect(service.hasJob('digest'), isTrue);
    });

    test('S08 a one-time job renders its instant, loads, and reopens without throwing', () async {
      final at = DateTime.now().add(const Duration(hours: 2)).toIso8601String();

      final created = await send(
        'POST',
        '/scheduling/jobs/create',
        form: {'name': 'remind-dentist', 'schedule': '', 'at': at, 'prompt': 'Remind me', 'delivery': 'announce'},
      );

      expect(created.status, 200);
      // The instant, not a cron preview and not the stored map.
      expect(created.body, contains(at));
      expect(created.body, isNot(contains('type: once')));
      expect(service.hasJob('remind-dentist'), isTrue);

      final form = await send('GET', '/scheduling/jobs/remind-dentist/form');
      expect(form.status, 200);
      expect(form.body, contains('value="$at"'));
      expect(form.headers['hx-trigger-after-swap'], isNull, reason: 'the form must open, not fall back to a toast');
    });

    test('S08 a job created through the page is runnable straight away', () async {
      await send(
        'POST',
        '/scheduling/jobs/create',
        form: {'name': 'standup', 'schedule': '0 9 * * *', 'at': '', 'prompt': 'Run standup', 'delivery': 'announce'},
      );

      final run = await send('POST', '/scheduling/jobs/standup/run');

      expect(run.status, 200);
      final trigger = jsonDecode(run.headers['hx-trigger-after-swap']!) as Map<String, dynamic>;
      expect((trigger['dc:toast'] as Map)['type'], 'success');
      expect((trigger['dc:toast'] as Map)['message'], "Job 'standup' started");
    });

    test('S02 edit form is prefilled from config with a server cron description', () async {
      final response = await send('GET', '/scheduling/jobs/digest/form');

      expect(response.body, contains('value="digest" disabled=""'));
      expect(response.body, contains('value="0 7 * * *"'));
      expect(response.body, contains('Existing prompt'));
      expect(response.body, contains('value="webhook" checked=""'));
      expect(response.body, contains('Daily at 7:00 AM'));
    });

    test('S02 structured cron jobs render and edit through production normalization', () async {
      await writer.updateFields({
        'scheduling.jobs': [
          {
            'name': 'structured-prompt',
            'schedule': {'type': 'cron', 'expression': '0 6 * * *'},
            'type': 'prompt',
            'delivery': 'announce',
            'prompt': 'Run structured prompt',
          },
          {
            'id': 'structured-task',
            'schedule': {'type': 'cron', 'expression': '0 8 * * 1'},
            'type': 'task',
            'enabled': false,
            'task': {'title': 'Structured task', 'description': 'Run the structured task'},
          },
        ],
      });

      final listing = await sendRouted('GET', '/scheduling');
      final promptForm = await sendRouted('GET', '/scheduling/jobs/structured-prompt/form');
      final taskForm = await sendRouted('GET', '/scheduling/tasks/structured-task/form');
      final toggled = await sendRouted('POST', '/scheduling/tasks/structured-task/toggle');

      expect(listing.body, contains('structured-prompt'));
      expect(listing.body, contains('Structured task'));
      expect(listing.body, isNot(contains('{type: cron, expression:')));
      expect(promptForm.body, contains('value="0 6 * * *"'));
      expect(promptForm.body, contains('Run structured prompt'));
      expect(taskForm.body, contains('value="0 8 * * 1"'));
      expect(taskForm.body, contains('value="Structured task"'));
      expect(toggled.status, 200);
      final structuredTask = (await writer.readSchedulingJobs()).singleWhere((job) => job['id'] == 'structured-task');
      expect(structuredTask['enabled'], isTrue);
    });

    test('S02 task name alias renders, edits, and toggles through production normalization', () async {
      await writer.updateFields({
        'scheduling.jobs': [
          {
            'name': 'aliased-task',
            'schedule': {'type': 'cron', 'expression': '30 9 * * 2'},
            'type': 'task',
            'enabled': true,
            'task': {'title': 'Aliased task', 'description': 'Use the accepted name alias'},
          },
        ],
      });

      final listing = await sendRouted('GET', '/scheduling');
      final form = await sendRouted('GET', '/scheduling/tasks/aliased-task/form');
      final toggled = await sendRouted('POST', '/scheduling/tasks/aliased-task/toggle');

      expect(listing.body, contains('Aliased task'));
      expect(form.body, contains('value="aliased-task" disabled=""'));
      expect(form.body, contains('value="30 9 * * 2"'));
      expect(toggled.status, 200);
      final aliasedTask = (await writer.readSchedulingJobs()).single;
      expect(aliasedTask['name'], 'aliased-task');
      expect(aliasedTask['enabled'], isFalse);
    });

    test('S03 duplicate and invalid cron refusals preserve controls and write nothing', () async {
      final before = File(configPath).readAsBytesSync();
      final duplicate = await send(
        'POST',
        '/scheduling/jobs/create',
        form: {'name': 'digest', 'schedule': '0 8 * * *', 'prompt': 'Other', 'delivery': 'none'},
      );
      final invalid = await send(
        'POST',
        '/scheduling/jobs/create',
        form: {'name': 'fresh', 'schedule': 'not a cron', 'prompt': 'Other', 'delivery': 'announce'},
      );

      expect(duplicate.status, 200);
      expect(duplicate.body, contains('Job "digest" already exists'));
      expect(duplicate.body, contains('value="digest" aria-invalid="true"'));
      expect(invalid.status, 200);
      expect(invalid.body, contains('Invalid cron expression'));
      expect(invalid.body, contains('value="not a cron" aria-invalid="true"'));
      expect(File(configPath).readAsBytesSync(), before);
    });

    test('S03 refused job edit preserves a special-character identity for correction', () async {
      await writer.updateFields({
        'scheduling.jobs': [
          {
            'name': 'A&B job',
            'schedule': '0 7 * * *',
            'type': 'prompt',
            'delivery': 'none',
            'prompt': 'Existing prompt',
          },
        ],
      });
      final encoded = Uri.encodeComponent('A&B job');
      final opened = await sendRouted('GET', '/scheduling/jobs/$encoded/form');
      final refused = await sendRouted(
        'POST',
        submitAction(opened.body),
        form: {'schedule': 'not a cron', 'prompt': '', 'delivery': 'none'},
      );
      final corrected = await sendRouted(
        'POST',
        submitAction(refused.body),
        form: {'schedule': '0 8 * * *', 'prompt': '', 'delivery': 'none'},
      );

      expect(refused.body, contains('Invalid cron expression'));
      expect(refused.body, contains('value="A&amp;B job" disabled=""'));
      expect(submitAction(refused.body), '/scheduling/jobs/$encoded/update');
      expect(corrected.status, 200);
      final stored = (await writer.readSchedulingJobs()).single;
      expect(stored['name'], 'A&B job');
      expect(stored['schedule'], '0 8 * * *');
    });

    test('S03 refused task edit preserves a special-character identity for correction', () async {
      await writer.updateFields({
        'scheduling.jobs': [
          {
            'id': 'task A&B',
            'schedule': '0 9 * * *',
            'type': 'task',
            'enabled': true,
            'task': {'title': 'Special task', 'description': 'Keep the route identity'},
          },
        ],
      });
      final encoded = Uri.encodeComponent('task A&B');
      final opened = await sendRouted('GET', '/scheduling/tasks/$encoded/form');
      final refused = await sendRouted(
        'POST',
        submitAction(opened.body),
        form: {
          'schedule': 'not a cron',
          'title': 'Special task',
          'description': 'Keep the route identity',
          'acceptanceCriteria': '',
          'enabled': 'on',
        },
      );
      final corrected = await sendRouted(
        'POST',
        submitAction(refused.body),
        form: {
          'schedule': '0 10 * * *',
          'title': 'Special task',
          'description': 'Keep the route identity',
          'acceptanceCriteria': '',
          'enabled': 'on',
        },
      );

      expect(refused.body, contains('Invalid cron expression'));
      expect(refused.body, contains('value="task A&amp;B" disabled=""'));
      expect(submitAction(refused.body), '/scheduling/tasks/$encoded/update');
      expect(corrected.status, 200);
      final stored = (await writer.readSchedulingJobs()).single;
      expect(stored['id'], 'task A&B');
      expect(stored['schedule'], '0 10 * * *');
    });

    test('S01 a blank prompt on edit keeps the stored prompt', () async {
      final response = await send(
        'POST',
        '/scheduling/jobs/digest/update',
        form: {'schedule': '0 8 * * *', 'prompt': '', 'delivery': 'webhook'},
      );

      expect(response.status, 200);
      final digest = (await writer.readSchedulingJobs()).singleWhere((job) => job['name'] == 'digest');
      expect(digest['schedule'], '0 8 * * *');
      expect(digest['prompt'], 'Existing prompt');
    });

    test('S05 no job row claims a restart is needed', () async {
      final fragment = schedulingJobsFragment(
        jobs: [
          {'name': workspaceGitSyncJobId, 'schedule': '0 1 * * *'},
          {'name': 'nightly', 'schedule': '0 2 * * *'},
        ],
        systemJobNames: const [],
      );

      expect(fragment, contains('$workspaceGitSyncJobId</span>'));
      expect(fragment, contains('nightly'));
      expect(fragment, isNot(contains('Restart to run')));
    });

    test('S06 run-now refusal returns the unchanged table and scheduler explanation', () async {
      final response = await send('POST', '/scheduling/jobs/digest/run');

      expect(response.status, 200);
      expect(response.body, contains('digest'));
      final trigger = jsonDecode(response.headers['hx-trigger-after-swap']!) as Map<String, dynamic>;
      final message = (trigger['dc:toast'] as Map)['message'] as String;
      expect(message, contains('not present in the running scheduler'));
      expect(message, isNot(contains('restart')));
    });

    test('S02 and S04 scheduled task edit and delete use stored config and table fragments', () async {
      await writer.updateFields({
        'scheduling.jobs': [
          ...await writer.readSchedulingJobs(),
          {
            'id': 'weekly-report',
            'type': 'task',
            'schedule': '0 9 * * 1',
            'enabled': false,
            'task': {
              'title': 'Weekly report',
              'description': 'Summarise the week',
              'acceptance_criteria': 'Include risks',
            },
          },
        ],
      });

      final pageResponse = await send('GET', '/scheduling');
      expect(pageResponse.body, contains('Weekly report'));
      expect(pageResponse.body, isNot(contains('Restart to run')));

      final form = await send('GET', '/scheduling/tasks/weekly-report/form');
      expect(form.body, contains('value="weekly-report" disabled=""'));
      expect(form.body, contains('value="Weekly report"'));
      expect(form.body, contains('Summarise the week'));
      expect(form.body, contains('Include risks'));
      expect(form.body, isNot(contains('id="task-enabled" name="enabled" checked=""')));

      final deleted = await send('POST', '/scheduling/tasks/weekly-report/delete');
      expect(deleted.status, 200);
      expect(deleted.body, contains('id="scheduling-tasks-table"'));
      expect(deleted.body, isNot(contains('Weekly report')));
      expect((await writer.readSchedulingJobs()).any((job) => job['id'] == 'weekly-report'), isFalse);
    });

    test('mutations are declared as non-GET routes under the owning page', () {
      final mutations = page.declaredRoutes.where((route) => route.method != 'GET');
      expect(mutations.every((route) => route.path.startsWith('/scheduling/')), isTrue);
      expect(mutations, hasLength(8));
    });

    test('unauthenticated requests are refused before any scheduling write', () async {
      final token = 'a' * 64;
      final guarded = const Pipeline()
          .addMiddleware(
            authMiddleware(
              tokenService: TokenService(token: token),
              gatewayToken: token,
            ),
          )
          .addHandler((request) => page.handler(request, _context(dataDir: workspace.path)));
      final before = File(configPath).readAsBytesSync();

      for (final path in const [
        '/scheduling/jobs/create',
        '/scheduling/jobs/digest/update',
        '/scheduling/jobs/digest/delete',
        '/scheduling/jobs/digest/run',
        '/scheduling/tasks/create',
        '/scheduling/tasks/task-id/update',
        '/scheduling/tasks/task-id/delete',
        '/scheduling/tasks/task-id/toggle',
      ]) {
        final response = await guarded(Request('POST', Uri.parse('http://localhost$path')));
        expect(response.statusCode, anyOf(401, 302, 303), reason: path);
      }
      expect(File(configPath).readAsBytesSync(), before);
    });
  });
}

PageContext _context({
  String? dataDir,
  DartclawConfig? config,
  List<Map<String, dynamic>> schedulingJobs = const [],
  List<String> systemJobNames = const [],
}) => PageContext(
  sessions: _NoopSessionService(),
  dataDir: dataDir,
  config: config,
  schedulingJobs: schedulingJobs,
  systemJobNames: systemJobNames,
  sidebarData: () async => (
    main: null,
    dmChannels: <SidebarSession>[],
    groupChannels: <SidebarSession>[],
    activeEntries: <SidebarSession>[],
    archivedEntries: <SidebarSession>[],
    activeTasks: <SidebarActiveTask>[],
    activeWorkflows: <SidebarActiveWorkflow>[],
    showChannels: false,
    tasksEnabled: false,
    activeSessionId: null,
  ),
  restartBannerHtml: () => '',
  buildNavItems: ({required String activePage}) => const <NavItem>[],
);

class _NoopSessionService implements SessionService {
  @override
  Future<Session> getOrCreateByKey(
    String key, {
    SessionType type = SessionType.user,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
  }) async => Session(id: 'session-$key', type: type, createdAt: DateTime.now(), updatedAt: DateTime.now());

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
