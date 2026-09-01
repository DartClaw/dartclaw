import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/web/pages/projects_page.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../../helpers/factories.dart';
import '../../task/task_review_test_support.dart';
import '../../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late KvService kvService;
  late SessionService sessions;
  late MessageService messages;
  late FakeProjectService projects;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_projects_page_test_');
    kvService = KvService(filePath: '${tempDir.path}/kv.json');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    projects = FakeProjectService(includeLocalProjectInGetAll: false);
  });

  tearDown(() async {
    await kvService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Handler handlerWith({TaskService? tasks, WorktreeManager? worktreeManager, TaskFileGuard? taskFileGuard}) {
    final registry = PageRegistry()..register(ProjectsPage());
    return webRoutes(
      sessions,
      messages,
      kvService: kvService,
      pageRegistry: registry,
      projectService: projects,
      projectMutations: ProjectMutationService(
        projects: projects,
        tasks: tasks,
        worktreeManager: worktreeManager,
        taskFileGuard: taskFileGuard,
      ),
    ).call;
  }

  Future<({int status, String body, Map<String, String> headers})> send(
    Handler handler,
    String method,
    String path, {
    Map<String, String>? form,
  }) async {
    final request = form == null
        ? Request(method, Uri.parse('http://localhost$path'))
        : Request(
            method,
            Uri.parse('http://localhost$path'),
            headers: {'content-type': 'application/x-www-form-urlencoded'},
            body: form.entries
                .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
                .join('&'),
          );
    final response = await handler(request);
    return (status: response.statusCode, body: await response.readAsString(), headers: response.headers);
  }

  Map<String, dynamic> toastFrom(Map<String, String> headers) {
    final trigger = headers['hx-trigger-after-swap'];
    expect(trigger, isNotNull, reason: 'a row action reports its outcome as a toast');
    return (jsonDecode(trigger!) as Map<String, dynamic>)['dc:toast'] as Map<String, dynamic>;
  }

  group('page routes', () {
    test('the page GET still renders the full projects page', () async {
      final res = await send(handlerWith(), 'GET', '/projects');

      expect(res.status, 200);
      expect(res.body, contains('<!DOCTYPE html>'));
      expect(res.body, contains('id="projects-content"'));
      expect(RegExp(r'<h1\b').allMatches(res.body), hasLength(1));
    });

    test('the add dialog is served empty from the page\'s own route', () async {
      final res = await send(handlerWith(), 'GET', '/projects/dialog');

      expect(res.status, 200);
      expect(res.body, contains('id="add-project-dialog"'));
      expect(res.body, contains('hx-post="/projects/create"'));
    });

    test('the edit dialog arrives filled in from the stored project', () async {
      projects.seed(
        makeProject(
          id: 'acme',
          name: 'acme',
          remoteUrl: 'https://github.com/acme/app.git',
          defaultBranch: 'develop',
          credentialsRef: 'github-main',
          pr: const PrConfig(strategy: PrStrategy.githubPr, draft: false, labels: ['agent', 'automated']),
        ),
      );

      final res = await send(handlerWith(), 'GET', '/projects/acme/dialog');

      expect(res.status, 200);
      expect(res.body, contains('hx-post="/projects/acme/update"'));
      expect(res.body, contains('value="develop"'));
      expect(res.body, contains('value="github-main"'));
      expect(res.body, contains('value="agent, automated"'));
      expect(res.body, contains('<option value="githubPr" selected="">'));
    });

    test('an edit dialog for an unknown project answers an empty host and a toast', () async {
      final res = await send(handlerWith(), 'GET', '/projects/nope/dialog');

      expect(res.status, 200);
      expect(res.body, isNot(contains('<dialog')));
      expect(toastFrom(res.headers)['type'], 'error');
    });
  });

  group('create', () {
    test('a valid create answers a closed dialog, the list carrying the new card, and a toast', () async {
      final res = await send(
        handlerWith(),
        'POST',
        '/projects/create',
        form: {'remoteUrl': 'https://github.com/acme/app.git', 'name': 'app', 'defaultBranch': 'main'},
      );

      expect(res.status, 200);
      expect(res.body, contains('id="project-dialog-host"'));
      expect(res.body, isNot(contains('<dialog')), reason: 'the dialog leaving the document is the close');
      expect(res.body, contains('hx-swap-oob="true"'), reason: 'the list rides along out of band');
      expect(res.body, contains('data-project-id="app"'));
      expect(toastFrom(res.headers), {'type': 'success', 'message': 'Project added'});

      expect((await projects.getAll()).map((p) => p.id), contains('app'));
      expect(projects.createCalls.single.remoteUrl, 'https://github.com/acme/app.git');
    });

    test('a blank optional control is unset, not an empty value', () async {
      await send(
        handlerWith(),
        'POST',
        '/projects/create',
        form: {'remoteUrl': 'https://github.com/acme/app.git', 'name': 'app', 'defaultBranch': '', 'labels': ''},
      );

      final recorded = projects.createCalls.single;
      expect(recorded.credentialsRef, isNull);
      expect(recorded.defaultBranch, 'main', reason: 'a blank branch falls back to the create default');
      expect(recorded.pr.labels, isEmpty);
    });

    test('an unchecked draft checkbox is false, not unchanged', () async {
      await send(
        handlerWith(),
        'POST',
        '/projects/create',
        form: {
          'remoteUrl': 'https://github.com/acme/app.git',
          'name': 'app',
          'prStrategy': 'githubPr',
          'labels': 'agent, automated',
        },
      );

      final recorded = projects.createCalls.single;
      expect(recorded.pr.draft, isFalse);
      expect(recorded.pr.strategy, PrStrategy.githubPr);
      expect(recorded.pr.labels, ['agent', 'automated']);
    });

    test('a refused create comes back in the dialog with the entry intact and nothing written', () async {
      projects.seed(makeProject(id: 'app', name: 'app'));

      final res = await send(
        handlerWith(),
        'POST',
        '/projects/create',
        form: {'remoteUrl': 'https://github.com/acme/app.git', 'name': 'app'},
      );

      expect(res.status, 200, reason: 'HTMX drops a 4xx body, so a domain refusal is never 4xx');
      expect(res.body, contains('id="add-project-dialog"'), reason: 'the dialog is still open');
      expect(res.body, contains('value="https://github.com/acme/app.git"'));
      expect(res.body, contains('value="app"'));
      expect(res.body, contains('already exists'));
      expect(res.body, contains('aria-invalid="true"'));
      expect(res.headers, isNot(contains('hx-trigger-after-swap')));
      expect(projects.createCalls, hasLength(1), reason: 'the create was attempted and refused');
      expect((await projects.getAll()).where((p) => p.id == 'app'), hasLength(1));
    });

    test('a request body over the route cap is refused before the mutation authority', () async {
      final res = await send(
        handlerWith(),
        'POST',
        '/projects/create',
        form: {'remoteUrl': 'https://github.com/acme/app.git', 'name': 'x' * 32 * 1024},
      );

      expect(res.status, 413);
      expect(projects.createCalls, isEmpty);
    });
  });

  group('update', () {
    test('a change refused for active tasks reports the JSON tier\'s message and writes nothing', () async {
      projects.seed(makeProject(id: 'acme', name: 'acme', remoteUrl: 'https://github.com/acme/app.git'));
      final db = openTaskDbInMemory();
      final eventBus = EventBus();
      final tasks = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
      await tasks.create(
        id: 'running-task',
        title: 'Running',
        description: 'For acme',
        configJson: const {'needsWorktree': false},
        projectId: 'acme',
        autoStart: true,
      );
      await tasks.transition('running-task', TaskStatus.running);

      final res = await send(
        handlerWith(tasks: tasks),
        'POST',
        '/projects/acme/update',
        form: {'remoteUrl': 'https://github.com/acme/other.git', 'name': 'acme'},
      );

      expect(res.status, 200);
      expect(res.body, contains('id="add-project-dialog"'));
      expect(res.body, contains('Cannot change remote coordinates while active tasks exist for this project'));
      expect(projects.updateCalls, isEmpty, reason: 'nothing was written');
      expect((await projects.get('acme'))!.remoteUrl, 'https://github.com/acme/app.git');

      await eventBus.dispose();
      await tasks.dispose();
    });

    test('a config-defined project is refused with CONFIG_DEFINED\'s message', () async {
      projects.seed(makeProject(id: 'cfg', name: 'cfg', configDefined: true));

      final res = await send(handlerWith(), 'POST', '/projects/cfg/update', form: {'name': 'renamed'});

      expect(res.status, 200);
      expect(res.body, contains('Config-defined projects cannot be modified via API'));
      expect(projects.updateCalls, isEmpty);
    });

    test('a valid edit closes the dialog and re-renders the list', () async {
      projects.seed(makeProject(id: 'acme', name: 'acme', remoteUrl: 'https://github.com/acme/app.git'));

      final res = await send(
        handlerWith(),
        'POST',
        '/projects/acme/update',
        form: {'remoteUrl': 'https://github.com/acme/app.git', 'name': 'acme', 'defaultBranch': 'develop'},
      );

      expect(res.status, 200);
      expect(res.body, isNot(contains('<dialog')));
      expect(res.body, contains('hx-swap-oob="true"'));
      expect(toastFrom(res.headers)['message'], 'Project updated');
      expect(projects.updateCalls.single.defaultBranch, 'develop');
    });
  });

  group('row actions', () {
    test('remove cascades exactly as the JSON delete does and re-renders the list without it', () async {
      projects.seed(makeProject(id: 'doomed', name: 'doomed'));
      projects.seed(makeProject(id: 'keeper', name: 'keeper'));
      final db = openTaskDbInMemory();
      final eventBus = EventBus();
      final tasks = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
      await tasks.create(
        id: 'q-task',
        title: 'Queued',
        description: 'For doomed',
        configJson: const {'needsWorktree': false},
        projectId: 'doomed',
        autoStart: true,
      );

      final worktrees = RecordingWorktreeManager();
      final res = await send(
        handlerWith(tasks: tasks, worktreeManager: worktrees, taskFileGuard: RecordingTaskFileGuard()),
        'POST',
        '/projects/doomed/delete',
      );

      expect(res.status, 200);
      expect(res.body, isNot(contains('data-project-id="doomed"')));
      expect(res.body, contains('data-project-id="keeper"'));
      expect(res.body, isNot(contains('hx-swap-oob')), reason: 'the list is the primary target here');
      expect(toastFrom(res.headers), {'type': 'success', 'message': 'Project removed'});

      final task = await tasks.get('q-task');
      expect(task!.status, TaskStatus.failed);
      expect(task.configJson['errorSummary'], contains('Project "doomed" was deleted'));
      expect(worktrees.cleanedTaskIds, ['q-task'], reason: 'the cascade cleans the worktree, as the JSON delete does');
      expect(worktrees.cleanedProjectIds, ['doomed']);

      await eventBus.dispose();
      await tasks.dispose();
    });

    test('a refused row action leaves the list unchanged and reports an error toast', () async {
      projects.seed(makeProject(id: 'cfg', name: 'cfg', configDefined: true));

      final res = await send(handlerWith(), 'POST', '/projects/cfg/delete');

      expect(res.status, 200);
      expect(res.body, contains('data-project-id="cfg"'));
      expect(toastFrom(res.headers), {'type': 'error', 'message': 'Config-defined projects cannot be deleted via API'});
      expect(projects.deleteCalls, isEmpty);
    });

    test('fetch reports the refusal on a project with no remote', () async {
      projects.seed(makeProject(id: 'cloning', name: 'cloning', status: ProjectStatus.cloning));

      final res = await send(handlerWith(), 'POST', '/projects/cloning/fetch');

      expect(res.status, 200);
      expect(toastFrom(res.headers)['message'], 'Cannot fetch while clone is in progress');
      expect(projects.fetchCalls, isEmpty);
    });

    test('a successful fetch reports success', () async {
      projects.seed(makeProject(id: 'acme', name: 'acme'));

      final res = await send(handlerWith(), 'POST', '/projects/acme/fetch');

      expect(toastFrom(res.headers), {'type': 'success', 'message': 'Project fetched'});
      expect(projects.fetchCalls, ['acme']);
    });
  });

  group('one authority, two tiers', () {
    test('an active-task refusal is decided once and reported in each tier\'s own encoding', () async {
      projects.seed(makeProject(id: 'acme', name: 'acme', remoteUrl: 'https://github.com/acme/app.git'));
      final db = openTaskDbInMemory();
      final eventBus = EventBus();
      final tasks = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
      await tasks.create(
        id: 'running-task',
        title: 'Running',
        description: 'For acme',
        configJson: const {'needsWorktree': false},
        projectId: 'acme',
        autoStart: true,
      );
      await tasks.transition('running-task', TaskStatus.running);

      final shared = ProjectMutationService(projects: projects, tasks: tasks);
      final registry = PageRegistry()..register(ProjectsPage());
      final web = webRoutes(
        sessions,
        messages,
        kvService: kvService,
        pageRegistry: registry,
        projectService: projects,
        projectMutations: shared,
      ).call;
      final json = projectRoutes(projects, mutations: shared).call;

      final jsonResponse = await json(
        Request(
          'PATCH',
          Uri.parse('http://localhost/api/projects/acme'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'remoteUrl': 'https://github.com/acme/other.git'}),
        ),
      );
      final jsonBody = jsonDecode(await jsonResponse.readAsString()) as Map<String, dynamic>;
      final webResponse = await send(
        web,
        'POST',
        '/projects/acme/update',
        form: {'remoteUrl': 'https://github.com/acme/other.git', 'name': 'acme'},
      );

      expect(jsonResponse.statusCode, 409);
      expect((jsonBody['error'] as Map)['code'], 'ACTIVE_TASKS');
      expect(webResponse.status, 200);
      expect(webResponse.body, contains((jsonBody['error'] as Map)['message'] as String));
      expect((await projects.get('acme'))!.remoteUrl, 'https://github.com/acme/app.git');
      expect(projects.updateCalls, isEmpty);

      await eventBus.dispose();
      await tasks.dispose();
    });

    test('a config-defined project is untouched from either tier', () async {
      projects.seed(makeProject(id: 'cfg', name: 'cfg', configDefined: true));
      final shared = ProjectMutationService(projects: projects);
      final registry = PageRegistry()..register(ProjectsPage());
      final web = webRoutes(
        sessions,
        messages,
        kvService: kvService,
        pageRegistry: registry,
        projectService: projects,
        projectMutations: shared,
      ).call;
      final json = projectRoutes(projects, mutations: shared).call;

      final jsonResponse = await json(
        Request(
          'PATCH',
          Uri.parse('http://localhost/api/projects/cfg'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'name': 'renamed'}),
        ),
      );
      final jsonBody = jsonDecode(await jsonResponse.readAsString()) as Map<String, dynamic>;
      final webResponse = await send(web, 'POST', '/projects/cfg/update', form: {'name': 'renamed'});
      final listing = await send(web, 'GET', '/projects');

      expect(jsonResponse.statusCode, 403);
      expect((jsonBody['error'] as Map)['code'], 'CONFIG_DEFINED');
      expect(webResponse.body, contains((jsonBody['error'] as Map)['message'] as String));
      expect(listing.body, isNot(contains('/projects/cfg/dialog')), reason: 'the card offers no Edit control');
      expect(listing.body, isNot(contains('/projects/cfg/delete')), reason: 'the card offers no Remove control');
      expect(projects.updateCalls, isEmpty);
    });
  });

  group('mutating routes inherit the shared pipeline', () {
    test('every declared mutating route is non-GET under the page\'s own path', () {
      final declared = ProjectsPage().declaredRoutes;

      expect(declared.every((route) => route.path.startsWith('/projects')), isTrue);
      expect(
        declared.where((route) => route.method != 'GET').map((route) => route.path),
        containsAll(['/projects/create', '/projects/<id>/update', '/projects/<id>/delete', '/projects/<id>/fetch']),
      );
    });

    test('an unauthenticated request is refused before the mutation authority is reached', () async {
      final gatewayToken = 'a' * 64;
      final tokenService = TokenService(token: gatewayToken);
      final guarded = const Pipeline()
          .addMiddleware(authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken))
          .addHandler(handlerWith());

      for (final path in const [
        '/projects/create',
        '/projects/acme/update',
        '/projects/acme/delete',
        '/projects/acme/fetch',
      ]) {
        final response = await guarded(Request('POST', Uri.parse('http://localhost$path')));
        expect(response.statusCode, anyOf(401, 302, 303), reason: path);
      }

      expect(projects.createCalls, isEmpty);
      expect(projects.updateCalls, isEmpty);
      expect(projects.deleteCalls, isEmpty);
      expect(projects.fetchCalls, isEmpty);
    });
  });
}
