import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/task/task_creation_service.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_runtime/src/web/pages/tasks_page.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowDefinitionSource, WorkflowStep, WorkflowTaskType, WorkflowVariable;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../../api/task_routes_test_support.dart';
import '../../task/task_review_test_support.dart';
import '../../test_utils.dart';

void main() {
  late TasksPage page;

  setUpAll(() async {
    initTemplates(await resolveTemplatesDir());
  });

  tearDownAll(() {
    resetTemplates();
  });

  setUp(() {
    page = TasksPage();
  });

  group('TasksPage', () {
    test('route is /tasks', () {
      expect(page.route, '/tasks');
    });

    test('title is Tasks', () {
      expect(page.title, 'Tasks');
    });

    test('navGroup is system', () {
      expect(page.navGroup, 'system');
    });

    test('PageRegistry accepts /tasks route', () {
      final registry = PageRegistry();
      registry.register(page);
      expect(registry.resolve('/tasks'), same(page));
    });

    test('declares detail, create, and task action routes', () {
      expect(page.declaredRoutes, const [
        (method: 'GET', path: '/tasks/new'),
        (method: 'GET', path: '/tasks/<id>'),
        (method: 'POST', path: '/tasks/create'),
        (method: 'POST', path: '/tasks/<id>/start'),
        (method: 'POST', path: '/tasks/<id>/cancel'),
        (method: 'POST', path: '/tasks/<id>/review'),
      ]);
    });

    test('S01 start route re-renders the stored task as queued without a second request', () async {
      final tasks = TaskService(InMemoryTaskRepository());
      addTearDown(tasks.dispose);
      await tasks.create(id: 'task-1', title: 'Start me', description: 'Run through markup');

      final response = await page.handler(
        Request('POST', Uri.parse('http://localhost/tasks/task-1/start')),
        _context(tasks: tasks),
      );
      final body = await response.readAsString();

      expect(response.statusCode, 200);
      expect((await tasks.get('task-1'))!.status, TaskStatus.queued);
      expect(body, contains('id="tasks-content"'));
      expect(body, contains('Waiting for an available runner'));
      expect(body, isNot(contains('>Start Task<')));
    });

    test('S02 refused start is a 200 toast over unchanged detail', () async {
      final tasks = TaskService(InMemoryTaskRepository());
      addTearDown(tasks.dispose);
      await tasks.create(id: 'task-1', title: 'Running', description: 'Already running', autoStart: true);
      await tasks.transition('task-1', TaskStatus.running);

      final response = await page.handler(
        Request('POST', Uri.parse('http://localhost/tasks/task-1/start')),
        _context(tasks: tasks),
      );

      expect(response.statusCode, 200);
      expect(response.headers['HX-Trigger-After-Swap'], contains('Cannot transition from running to queued'));
      expect((await tasks.get('task-1'))!.status, TaskStatus.running);
      expect(await response.readAsString(), contains('Running'));
    });

    test('S03 cancel route cleans the worktree and active turn before returning to the filtered list', () async {
      final tasks = TaskService(InMemoryTaskRepository());
      final worktrees = RecordingWorktreeManager();
      final guard = TaskFileGuard();
      final turns = CancelTrackingTurns();
      addTearDown(tasks.dispose);
      await tasks.create(id: 'task-1', title: 'Cancel me', description: 'Clean up first', autoStart: true);
      await tasks.updateFields(
        'task-1',
        sessionId: 'session-1',
        worktreeJson: const {
          'path': '/tmp/task-1',
          'branch': 'dartclaw/task-1',
          'createdAt': '2026-08-25T00:00:00.000Z',
        },
      );
      guard.register('task-1', '/tmp/task-1');
      await tasks.transition('task-1', TaskStatus.running);
      final actions = TaskActionService(
        tasks: tasks,
        reviewService: TaskReviewService(tasks: tasks),
        turns: turns,
        worktreeManager: worktrees,
        taskFileGuard: guard,
      );
      final context = _context(tasks: tasks, actions: actions);
      final detail = await page.handler(
        Request('GET', Uri.parse('http://localhost/tasks/task-1?status=running&include=workflow')),
        context,
      );
      final detailBody = await detail.readAsString();
      final renderedAction = RegExp(r'action="([^"]*/cancel[^"]*)"')
          .firstMatch(detailBody)!
          .group(1)!
          .replaceAll('&amp;', '&');

      final response = await page.handler(Request('POST', Uri.parse('http://localhost$renderedAction')), context);

      expect(response.statusCode, 200);
      expect(response.headers['HX-Location'], '/tasks?status=running&include=workflow');
      expect((await tasks.get('task-1'))!.status, TaskStatus.cancelled);
      expect(worktrees.cleanedTaskIds, ['task-1']);
      expect(guard.hasRegistration('task-1'), isFalse);
      expect(turns.cancelledSessions, ['session-1']);
    });

    test('S04 review actions redirect on accept and keep empty push-back inline', () async {
      final tasks = TaskService(InMemoryTaskRepository());
      addTearDown(tasks.dispose);
      await tasks.create(
        id: 'accept',
        title: 'Accept',
        description: 'Review',
        configJson: const {'needsWorktree': false},
        autoStart: true,
      );
      await tasks.transition('accept', TaskStatus.running);
      await tasks.transition('accept', TaskStatus.review);
      await tasks.create(
        id: 'push-back',
        title: 'Push back',
        description: 'Review',
        configJson: const {'needsWorktree': false},
        autoStart: true,
      );
      await tasks.transition('push-back', TaskStatus.running);
      await tasks.transition('push-back', TaskStatus.review);
      final context = _context(tasks: tasks);

      final list = await page.handler(
        Request('GET', Uri.parse('http://localhost/tasks?status=review&include=workflow')),
        context,
      );
      final listBody = await list.readAsString();
      final renderedDetail = RegExp(r'href="([^"]*/tasks/accept[^"]*)"')
          .firstMatch(listBody)!
          .group(1)!
          .replaceAll('&amp;', '&');
      final detail = await page.handler(Request('GET', Uri.parse('http://localhost$renderedDetail')), context);
      final detailBody = await detail.readAsString();
      final renderedReview = RegExp(r'action="([^"]*/review[^"]*)"')
          .firstMatch(detailBody)!
          .group(1)!
          .replaceAll('&amp;', '&');
      final accepted = await page.handler(
        Request(
          'POST',
          Uri.parse('http://localhost$renderedReview'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: 'action=accept',
        ),
        context,
      );
      expect(accepted.headers['HX-Location'], '/tasks?status=review&include=workflow');
      expect((await tasks.get('accept'))!.status, TaskStatus.accepted);

      final refused = await page.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/tasks/push-back/review'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: 'action=push_back&comment=',
        ),
        context,
      );
      final body = await refused.readAsString();
      expect(refused.statusCode, 200);
      expect(body, contains('comment must not be empty for push_back'));
      expect(body, contains('aria-invalid="true"'));
      expect(body, contains('<details class="pushback-comment" open'));
      expect((await tasks.get('push-back'))!.status, TaskStatus.review);
    });

    test('review route renders the shared invalid and empty action refusals', () async {
      final tasks = TaskService(InMemoryTaskRepository());
      addTearDown(tasks.dispose);
      await tasks.create(
        id: 'task-1',
        title: 'Review',
        description: 'Review',
        configJson: const {'needsWorktree': false},
        autoStart: true,
      );
      await tasks.transition('task-1', TaskStatus.running);
      await tasks.transition('task-1', TaskStatus.review);
      final context = _context(tasks: tasks);

      for (final testCase in [
        (body: 'action=', message: 'action must not be empty'),
        (body: 'action=ship_it', message: 'action must be one of: accept, reject, push_back'),
      ]) {
        final response = await page.handler(
          Request(
            'POST',
            Uri.parse('http://localhost/tasks/task-1/review'),
            headers: {'content-type': 'application/x-www-form-urlencoded'},
            body: testCase.body,
          ),
          context,
        );

        expect(response.statusCode, 200);
        expect(response.headers['HX-Trigger-After-Swap'], contains(testCase.message));
        await response.readAsString();
        expect((await tasks.get('task-1'))!.status, TaskStatus.review);
      }
    });

    test('create dialog is rendered on demand with independent forms', () async {
      final definitions = InMemoryDefinitionSource([
        WorkflowDefinition(
          name: 'spec-and-implement',
          description: 'Feature pipeline',
          variables: const {'FEATURE': WorkflowVariable(description: 'Feature name', required: true)},
          steps: const [
            WorkflowStep(
              id: 'implement',
              name: 'Implement',
              taskType: WorkflowTaskType.approval,
              prompts: ['Build it'],
            ),
          ],
        ),
      ]);
      final response = await page.handler(
        Request('GET', Uri.parse('http://localhost/tasks/new')),
        _context(definitionSource: definitions),
      );
      final body = await response.readAsString();

      expect(response.statusCode, 200);
      expect(body, contains('id="new-task-dialog"'));
      expect(body, contains('id="new-task-panel"'));
      expect(body, contains('hx-post="/tasks/create"'));
      expect(body, contains('role="tab" aria-selected="true"'));
      expect(body, contains('role="tabpanel" aria-labelledby="new-task-tab-single"'));
      expect(body, contains('spec-and-implement'));
      expect(body, contains('hx-post="/api/workflows/run-form"'));
      expect(RegExp(r'<input[^>]*name="var_FEATURE"[^>]*aria-required="true"').hasMatch(body), isTrue);
      expect(RegExp(r'<input[^>]*name="var_FEATURE"[^>]* required').hasMatch(body), isFalse);
      for (final name in const ['title', 'description']) {
        final control = RegExp('<(?:input|textarea)[^>]*name="$name"[^>]*>').firstMatch(body)?.group(0);
        expect(control, isNotNull, reason: name);
        expect(control, contains('aria-required="true"'), reason: name);
        expect(RegExp(r'\srequired(?:\s|=|>)').hasMatch(control!), isFalse, reason: name);
      }
      expect(body, isNot(contains('id="new-task-form"')));
    });

    test('create dialog resolves current project status when it opens', () async {
      final project = Project(
        id: 'acme',
        name: 'Acme',
        remoteUrl: 'git@example.com:acme/repo.git',
        localPath: '/repos/acme',
        defaultBranch: 'main',
        status: ProjectStatus.cloning,
        createdAt: DateTime.parse('2026-08-25T00:00:00Z'),
      );
      final projects = FakeProjectService(
        projects: [project],
        includeLocalProjectInGetAll: false,
        defaultProjectId: project.id,
      );
      final context = _context(projects: projects);
      final listResponse = await page.handler(Request('GET', Uri.parse('http://localhost/tasks')), context);
      await listResponse.readAsString();

      await projects.fetch(project.id);
      final dialogResponse = await page.handler(Request('GET', Uri.parse('http://localhost/tasks/new')), context);
      final dialog = await dialogResponse.readAsString();

      expect(dialog, contains('Acme ✓'));
      expect(RegExp(r'<option[^>]*value="acme"[^>]*disabled').hasMatch(dialog), isFalse);
    });

    test('task form creates through the shared service and redirects with HX-Location', () async {
      final db = openTaskDbInMemory();
      final tasks = TaskService(SqliteTaskRepository(db));
      addTearDown(() async {
        await tasks.dispose();
        db.close();
      });
      final project = Project(
        id: 'acme',
        name: 'Acme',
        remoteUrl: 'git@example.com:acme/repo.git',
        localPath: '/repos/acme',
        status: ProjectStatus.ready,
        createdAt: DateTime.parse('2026-08-25T00:00:00Z'),
      );
      final projects = FakeProjectService(
        projects: [project],
        includeLocalProjectInGetAll: false,
        defaultProjectId: project.id,
      );
      final response = await page.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/tasks/create'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body:
              'title=Ship&description=Server+rendered&goalId=goal-1&projectId=acme&acceptanceCriteria=Done'
              '&model=gpt-5&tokenBudget=123&allowedTools=shell&allowedTools=web_search&reviewMode=mandatory'
              '&needsWorktree=on&autoStart=on',
        ),
        _context(tasks: tasks, projects: projects),
      );

      expect(response.statusCode, 200);
      expect(response.headers['HX-Location'], startsWith('/tasks/'));
      final created = (await tasks.list()).single;
      expect(created.title, 'Ship');
      expect(created.description, 'Server rendered');
      expect(created.goalId, 'goal-1');
      expect(created.projectId, 'acme');
      expect(created.acceptanceCriteria, 'Done');
      expect(created.status, TaskStatus.queued);
      expect(created.model, 'gpt-5');
      expect(created.configJson['tokenBudget'], 123);
      expect(created.configJson['allowedTools'], ['shell', 'web_search']);
      expect(created.configJson['reviewMode'], 'mandatory');
      expect(created.configJson['needsWorktree'], isTrue);
    });

    test('task form refusal stays inline with submitted values and creates nothing', () async {
      final db = openTaskDbInMemory();
      final tasks = TaskService(SqliteTaskRepository(db));
      addTearDown(() async {
        await tasks.dispose();
        db.close();
      });
      final response = await page.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/tasks/create'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: 'title=&description=Keep+this',
        ),
        _context(tasks: tasks),
      );
      final body = await response.readAsString();

      expect(response.statusCode, 200);
      expect(body, contains('title must not be empty'));
      expect(body, contains('aria-invalid="true"'));
      expect(body, contains('Keep this'));
      expect(await tasks.list(), isEmpty);
    });

    test('registered routes preserve refusal input and enforce the bounded form contract', () async {
      final db = openTaskDbInMemory();
      final tasks = TaskService(SqliteTaskRepository(db));
      final tempDir = Directory.systemTemp.createTempSync('tasks_page_registered_routes_');
      addTearDown(() async {
        await tasks.dispose();
        db.close();
        tempDir.deleteSync(recursive: true);
      });
      final registry = PageRegistry()..register(TasksPage());
      final handler = webRoutes(
        _StubSessionService(),
        MessageService(baseDir: tempDir.path),
        pageRegistry: registry,
        taskService: tasks,
        taskCreationService: TaskCreationService(tasks: tasks),
        taskActionService: _actions(tasks),
      ).call;

      final dialog = await handler(Request('GET', Uri.parse('http://localhost/tasks/new')));
      expect(dialog.statusCode, 200);
      expect(await dialog.readAsString(), contains('id="new-task-dialog"'));

      final refused = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/tasks/create'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: 'title=&description=Keep+this',
        ),
      );
      final refusedBody = await refused.readAsString();
      expect(refused.statusCode, 200);
      expect(refusedBody, contains('title must not be empty'));
      expect(refusedBody, contains('aria-invalid="true"'));
      expect(refusedBody, contains('Keep this'));
      expect(await tasks.list(), isEmpty);

      final created = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/tasks/create'),
          headers: {'content-type': 'Application/X-WWW-Form-Urlencoded; charset=UTF-8'},
          body: 'title=Ship&description=Repeated&allowedTools=shell&allowedTools=web_search',
        ),
      );
      expect(created.statusCode, 200);
      expect((await tasks.list()).single.configJson['allowedTools'], ['shell', 'web_search']);

      for (final refusal in [
        (
          request: Request(
            'POST',
            Uri.parse('http://localhost/tasks/create'),
            headers: {'content-type': 'application/x-www-form-urlencoded'},
            body: 'title=%ZZ&description=Malformed',
          ),
          status: 400,
          code: 'INVALID_INPUT',
        ),
        (
          request: Request(
            'POST',
            Uri.parse('http://localhost/tasks/create'),
            headers: {'content-type': 'text/plain'},
            body: 'title=Wrong&description=Type',
          ),
          status: 415,
          code: 'UNSUPPORTED_MEDIA_TYPE',
        ),
        (
          request: Request(
            'POST',
            Uri.parse('http://localhost/tasks/create'),
            headers: {'content-type': 'application/x-www-form-urlencoded-evil'},
            body: 'title=Wrong&description=Prefix',
          ),
          status: 415,
          code: 'UNSUPPORTED_MEDIA_TYPE',
        ),
        (
          request: Request(
            'POST',
            Uri.parse('http://localhost/tasks/create'),
            headers: {'content-type': 'application/x-www-form-urlencoded'},
            body: 'title=${List.filled(256 * 1024, 'x').join()}&description=Too+large',
          ),
          status: 413,
          code: 'REQUEST_TOO_LARGE',
        ),
      ]) {
        final response = await handler(refusal.request);
        expect(response.statusCode, refusal.status);
        final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect((body['error'] as Map<String, dynamic>)['code'], refusal.code);
      }
      expect(await tasks.list(), hasLength(1));
    });

    test('registered create routes are refused by auth before task creation', () async {
      final tasks = TaskService(InMemoryTaskRepository());
      final tempDir = Directory.systemTemp.createTempSync('tasks_page_auth_routes_');
      addTearDown(() async {
        await tasks.dispose();
        tempDir.deleteSync(recursive: true);
      });
      final registry = PageRegistry()..register(TasksPage());
      final web = webRoutes(
        _StubSessionService(),
        MessageService(baseDir: tempDir.path),
        pageRegistry: registry,
        taskService: tasks,
        taskCreationService: TaskCreationService(tasks: tasks),
        taskActionService: _actions(tasks),
      ).call;
      final token = 'a' * 64;
      final guarded = const Pipeline()
          .addMiddleware(
            authMiddleware(
              tokenService: TokenService(token: token),
              gatewayToken: token,
            ),
          )
          .addHandler(web);

      final dialog = await guarded(Request('GET', Uri.parse('http://localhost/tasks/new')));
      final create = await guarded(
        Request(
          'POST',
          Uri.parse('http://localhost/tasks/create'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: 'title=Must+not+land&description=Auth+blocks+this',
        ),
      );
      final start = await guarded(Request('POST', Uri.parse('http://localhost/tasks/missing/start')));
      final cancel = await guarded(Request('POST', Uri.parse('http://localhost/tasks/missing/cancel')));
      final review = await guarded(
        Request(
          'POST',
          Uri.parse('http://localhost/tasks/missing/review'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: 'action=accept',
        ),
      );

      expect(dialog.statusCode, anyOf(401, 302, 303));
      expect(create.statusCode, anyOf(401, 302, 303));
      expect(start.statusCode, anyOf(401, 302, 303));
      expect(cancel.statusCode, anyOf(401, 302, 303));
      expect(review.statusCode, anyOf(401, 302, 303));
      expect(await tasks.list(), isEmpty);
    });

    test('registered action routes are refused by the origin guard before mutation', () async {
      final tasks = TaskService(InMemoryTaskRepository());
      final tempDir = Directory.systemTemp.createTempSync('tasks_page_origin_routes_');
      addTearDown(() async {
        await tasks.dispose();
        tempDir.deleteSync(recursive: true);
      });
      await tasks.create(id: 'task-1', title: 'Guarded', description: 'Must stay draft');
      final registry = PageRegistry()..register(TasksPage());
      final web = webRoutes(
        _StubSessionService(),
        MessageService(baseDir: tempDir.path),
        pageRegistry: registry,
        taskService: tasks,
        taskActionService: _actions(tasks),
      ).call;
      final guarded = const Pipeline()
          .addMiddleware(localAdminMiddleware())
          .addMiddleware(originHostGuardMiddleware())
          .addHandler(web);

      for (final path in const ['start', 'cancel', 'review']) {
        final response = await guarded(
          Request(
            'POST',
            Uri.parse('http://localhost/tasks/task-1/$path'),
            headers: {
              'host': 'localhost',
              'origin': 'https://attacker.example',
              if (path == 'review') 'content-type': 'application/x-www-form-urlencoded',
            },
            body: path == 'review' ? 'action=accept' : null,
          ),
        );
        expect(response.statusCode, 403, reason: path);
      }
      expect((await tasks.get('task-1'))!.status, TaskStatus.draft);
    });

    test('task form refuses profile-bearing input', () async {
      final db = openTaskDbInMemory();
      final tasks = TaskService(SqliteTaskRepository(db));
      addTearDown(() async {
        await tasks.dispose();
        db.close();
      });
      final response = await page.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/tasks/create'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: 'title=Ship&description=No+profile&securityProfile=restricted',
        ),
        _context(tasks: tasks),
      );

      expect(await response.readAsString(), contains('Execution profiles cannot be selected'));
      expect(await tasks.list(), isEmpty);
    });

    test('task form forwards both retired category aliases to the shared refusal authority', () async {
      final db = openTaskDbInMemory();
      final tasks = TaskService(SqliteTaskRepository(db));
      addTearDown(() async {
        await tasks.dispose();
        db.close();
      });

      for (final input in const [
        (field: 'type', value: 'research'),
        (field: 'type', value: 'writing'),
        (field: 'task_type', value: 'coding'),
        (field: 'task_type', value: 'automation'),
      ]) {
        final response = await page.handler(
          Request(
            'POST',
            Uri.parse('http://localhost/tasks/create'),
            headers: {'content-type': 'application/x-www-form-urlencoded'},
            body: 'title=Ship&description=No+category&${input.field}=${input.value}',
          ),
          _context(tasks: tasks),
        );
        final body = await response.readAsString();

        expect(response.statusCode, 200, reason: '${input.field}=${input.value}');
        expect(body, anyOf(contains('Task type'), contains('Task category is retired')), reason: input.value);
        expect(await tasks.list(), isEmpty, reason: '${input.field}=${input.value}');
      }
    });

    test('appears in sidebar nav items', () {
      final registry = PageRegistry()..register(page);
      final navItems = registry.navItems(activePage: 'Tasks');
      expect(navItems, isNotEmpty);
      expect(navItems.first.label, 'Tasks');
      expect(navItems.first.active, isTrue);
    });

    test('PageContext accepts taskService and eventBus fields', () {
      final context = PageContext(
        sessions: _StubSessionService(),
        taskService: null,
        goalService: null,
        eventBus: null,
        sidebarData: () async => _emptySidebarData,
        restartBannerHtml: () => '',
        buildNavItems: ({required String activePage}) => [],
      );

      expect(context.taskService, isNull);
      expect(context.goalService, isNull);
      expect(context.eventBus, isNull);
    });

    test('S05 declared status filter preserves workflow inclusion after task categories retired', () async {
      final tasks = TaskService(InMemoryTaskRepository());
      addTearDown(tasks.dispose);
      await tasks.create(
        id: 'coding-review',
        title: 'Coding review',
        description: 'Worktree task',
        configJson: const {'needsWorktree': true},
        autoStart: true,
      );
      await tasks.transition('coding-review', TaskStatus.running);
      await tasks.transition('coding-review', TaskStatus.review);
      final response = await page.handler(
        Request('GET', Uri.parse('http://localhost/tasks?status=review&include=workflow')),
        _context(tasks: tasks),
      );
      final body = await response.readAsString();

      expect(body, contains('Coding review'));
      expect(body, contains('name="include" value="workflow"'));
      expect(RegExp(r'<option value="review"[^>]*selected').hasMatch(body), isTrue);
      expect(body, contains('hx-get="/tasks"'));
      expect(body, contains('hx-include="closest form"'));
    });

    test('default review list excludes workflow-owned review tasks and exposes toggle', () async {
      final db = openTaskDbInMemory();
      final taskService = TaskService(SqliteTaskRepository(db));
      addTearDown(() async {
        await taskService.dispose();
        db.close();
      });

      await taskService.create(
        id: 'task-review-normal',
        title: 'Normal review task',
        description: 'Review me',
        configJson: const {'needsWorktree': false},
        autoStart: true,
      );
      await taskService.transition('task-review-normal', TaskStatus.running);
      await taskService.transition('task-review-normal', TaskStatus.review);

      await taskService.create(
        id: 'task-review-workflow',
        title: 'Workflow review task',
        description: 'Workflow-owned review artifact',
        autoStart: true,
        workflowRunId: 'run-123',
        configJson: const {
          'needsWorktree': true,
          '_workflowGit': {'worktree': 'per-map-item', 'promotion': 'merge'},
        },
      );
      await taskService.transition('task-review-workflow', TaskStatus.running);
      await taskService.transition('task-review-workflow', TaskStatus.review);

      final context = PageContext(
        sessions: _StubSessionService(),
        taskService: taskService,
        goalService: null,
        eventBus: null,
        sidebarData: () async => _emptySidebarData,
        restartBannerHtml: () => '',
        buildNavItems: ({required String activePage}) => [],
      );

      final response = await page.handler(
        Request('GET', Uri.parse('http://localhost/tasks?status=review&type=research')),
        context,
      );
      final body = await response.readAsString();
      expect(body, contains('Normal review task'));
      expect(body, isNot(contains('Workflow review task')));
      expect(body, contains('Show workflow artifacts'));
      expect(body, isNot(contains('type=research')));

      final includeResponse = await page.handler(
        Request('GET', Uri.parse('http://localhost/tasks?status=review&include=workflow')),
        context,
      );
      final includeBody = await includeResponse.readAsString();
      expect(includeBody, contains('Normal review task'));
      expect(includeBody, contains('Workflow review task'));
      expect(includeBody, contains('Hide workflow artifacts'));
    });
  });
}

final _emptySidebarData = (
  main: null,
  dmChannels: <SidebarSession>[],
  groupChannels: <SidebarSession>[],
  activeEntries: <SidebarSession>[],
  archivedEntries: <SidebarSession>[],
  activeTasks: <SidebarActiveTask>[],
  activeWorkflows: <SidebarActiveWorkflow>[],
  showChannels: true,
  tasksEnabled: false,
  activeSessionId: null,
);

class _StubSessionService implements SessionService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

PageContext _context({
  TaskService? tasks,
  ProjectService? projects,
  WorkflowDefinitionSource? definitionSource,
  TaskActionService? actions,
}) => PageContext(
  sessions: _StubSessionService(),
  taskService: tasks,
  taskCreationService: tasks == null ? null : TaskCreationService(tasks: tasks, projects: projects),
  taskActionService: actions ?? (tasks == null ? null : _actions(tasks, projects: projects)),
  projectService: projects,
  definitionSource: definitionSource,
  sidebarData: () async => _emptySidebarData,
  restartBannerHtml: () => '',
  buildNavItems: ({required String activePage}) => [],
);

TaskActionService _actions(TaskService tasks, {ProjectService? projects}) => TaskActionService(
  tasks: tasks,
  reviewService: TaskReviewService(tasks: tasks, projectService: projects),
  projectService: projects,
);
