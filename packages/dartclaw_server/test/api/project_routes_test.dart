import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show ProjectAuthStatus, ProjectConfig;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService, projectRoutes;
import 'package:dartclaw_server/src/project/project_auth_support.dart' show ProjectAuthException;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteTaskRepository, openTaskDbInMemory;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/factories.dart';
import 'api_test_helpers.dart';

void main() {
  late FakeProjectService projects;
  late ApiRouteTestClient client;

  setUp(() {
    projects = FakeProjectService();
    client = ApiRouteTestClient(projectRoutes(projects).call);
  });

  // ------------------------------------------------------------------
  // POST /api/projects
  // ------------------------------------------------------------------

  group('POST /api/projects', () {
    test('valid body creates project with cloning status', () async {
      final body = await client.expectJsonObject(
        'POST',
        '/api/projects',
        json: {'name': 'My App', 'remoteUrl': 'https://github.com/acme/myapp.git'},
        status: 201,
      );

      expect(body['id'], 'my-app');
      expect(body['name'], 'My App');
      expect(body['status'], 'cloning');
      expect(body['remoteUrl'], 'https://github.com/acme/myapp.git');
    });

    test('minimal body defaults to shallow clone and branchOnly PR', () async {
      final body = await client.expectJsonObject(
        'POST',
        '/api/projects',
        json: {'name': 'Minimal', 'remoteUrl': 'https://github.com/x/y.git'},
        status: 201,
      );

      expect(body['cloneStrategy'], 'shallow');
      expect(body['pr']['strategy'], 'branchOnly');
    });

    test('body with custom PR config is preserved', () async {
      final body = await client.expectJsonObject(
        'POST',
        '/api/projects',
        json: {
          'name': 'PR App',
          'remoteUrl': 'https://github.com/x/y.git',
          'pr': {'strategy': 'githubPr', 'draft': true},
        },
        status: 201,
      );

      expect(body['pr']['strategy'], 'githubPr');
      expect(body['pr']['draft'], true);
    });

    test('missing name returns 400', () async {
      expect(
        await client.expectJsonErrorCode(
          'POST',
          '/api/projects',
          json: {'remoteUrl': 'https://github.com/x/y.git'},
          status: 400,
        ),
        'INVALID_INPUT',
      );
    });

    test('missing remoteUrl returns 400', () async {
      expect(
        await client.expectJsonErrorCode('POST', '/api/projects', json: {'name': 'Oops'}, status: 400),
        'MISSING_INPUT',
      );
    });

    test('localPath only returns 201 when API localPath is enabled', () async {
      final localPathClient = ApiRouteTestClient(
        projectRoutes(projects, projectConfig: const ProjectConfig(allowApiLocalPath: true)).call,
      );

      final body = await localPathClient.expectJsonObject(
        'POST',
        '/api/projects',
        json: {'name': 'Local App', 'localPath': '/tmp/live-checkout'},
        status: 201,
      );

      expect(body['remoteUrl'], '');
      expect(body['localPath'], '/tmp/live-checkout');
      expect(body['status'], 'ready');
    });

    test('localPath only returns 403 when API localPath is disabled', () async {
      expect(
        await client.expectJsonErrorCode(
          'POST',
          '/api/projects',
          json: {'name': 'Local App', 'localPath': '/tmp/live-checkout'},
          status: 403,
        ),
        'LOCAL_PATH_DISABLED',
      );
    });

    test('both remoteUrl and localPath returns 400 XOR error', () async {
      final localPathClient = ApiRouteTestClient(
        projectRoutes(projects, projectConfig: const ProjectConfig(allowApiLocalPath: true)).call,
      );

      expect(
        await localPathClient.expectJsonErrorCode(
          'POST',
          '/api/projects',
          json: {'name': 'Confused App', 'remoteUrl': 'https://github.com/x/y.git', 'localPath': '/tmp/live-checkout'},
          status: 400,
        ),
        'XOR_INPUT',
      );
    });

    test('invalid localPath is rejected against the allowlist', () async {
      final localPathClient = ApiRouteTestClient(
        projectRoutes(
          projects,
          projectConfig: const ProjectConfig(allowApiLocalPath: true, localPathAllowlist: ['/Users/allowed']),
        ).call,
      );

      expect(
        await localPathClient.expectJsonErrorCode(
          'POST',
          '/api/projects',
          json: {'name': 'Local App', 'localPath': '/tmp/live-checkout'},
          status: 400,
        ),
        'INVALID_LOCAL_PATH',
      );
    });

    test('allowlist rejects ancestor symlink escapes even outside container mode', () async {
      final tempDir = Directory.systemTemp.createTempSync('project_routes_allowlist_symlink_test_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final allowedRoot = Directory(p.join(tempDir.path, 'allowed'))..createSync(recursive: true);
      final outsideRoot = Directory(p.join(tempDir.path, 'outside'))..createSync(recursive: true);
      final escapeLink = p.join(allowedRoot.path, 'link-out');
      Link(escapeLink).createSync(outsideRoot.path);
      final escapedPath = p.join(escapeLink, 'repo');

      final localPathClient = ApiRouteTestClient(
        projectRoutes(
          projects,
          projectConfig: ProjectConfig(allowApiLocalPath: true, localPathAllowlist: [allowedRoot.path]),
        ).call,
      );

      expect(
        await localPathClient.expectJsonErrorCode(
          'POST',
          '/api/projects',
          json: {'name': 'Escaped App', 'localPath': escapedPath},
          status: 400,
        ),
        'INVALID_LOCAL_PATH',
      );
    });

    test('container mode rejects API localPath projects outside mounted roots', () async {
      final localPathClient = ApiRouteTestClient(
        projectRoutes(
          projects,
          projectConfig: const ProjectConfig(allowApiLocalPath: true),
          containerEnabled: true,
          containerMountRoots: const ['/srv/workspace', '/srv/projects'],
        ).call,
      );

      expect(
        await localPathClient.expectJsonErrorCode(
          'POST',
          '/api/projects',
          json: {'name': 'Local App', 'localPath': '/tmp/live-checkout'},
          status: 400,
        ),
        'LOCAL_PATH_NOT_MOUNTABLE',
      );
    });

    test('container mode accepts API localPath projects inside mounted roots', () async {
      final localPathClient = ApiRouteTestClient(
        projectRoutes(
          projects,
          projectConfig: const ProjectConfig(allowApiLocalPath: true),
          containerEnabled: true,
          containerMountRoots: const ['/srv/workspace', '/srv/projects'],
        ).call,
      );

      final body = await localPathClient.expectJsonObject(
        'POST',
        '/api/projects',
        json: {'name': 'Local App', 'localPath': '/srv/projects/live-checkout'},
        status: 201,
      );

      expect(body['localPath'], '/srv/projects/live-checkout');
    });

    test('container mode rejects symlinked localPath that resolves outside mounted roots', () async {
      final tempDir = Directory.systemTemp.createTempSync('project_routes_symlink_test_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final mountedRoot = Directory(p.join(tempDir.path, 'mounted'))..createSync(recursive: true);
      final outsideRoot = Directory(p.join(tempDir.path, 'outside'))..createSync(recursive: true);
      Directory(p.join(outsideRoot.path, '.git')).createSync(recursive: true);
      final symlinkPath = p.join(mountedRoot.path, 'linked-checkout');
      Link(symlinkPath).createSync(outsideRoot.path);

      final localPathClient = ApiRouteTestClient(
        projectRoutes(
          projects,
          projectConfig: const ProjectConfig(allowApiLocalPath: true),
          containerEnabled: true,
          containerMountRoots: [mountedRoot.path],
        ).call,
      );

      expect(
        await localPathClient.expectJsonErrorCode(
          'POST',
          '/api/projects',
          json: {'name': 'Linked App', 'localPath': symlinkPath},
          status: 400,
        ),
        'LOCAL_PATH_NOT_MOUNTABLE',
      );
    });

    test('container mode rejects new descendants under ancestor symlink escapes', () async {
      final tempDir = Directory.systemTemp.createTempSync('project_routes_symlink_ancestor_test_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final mountedRoot = Directory(p.join(tempDir.path, 'mounted'))..createSync(recursive: true);
      final outsideRoot = Directory(p.join(tempDir.path, 'outside'))..createSync(recursive: true);
      final escapeLink = p.join(mountedRoot.path, 'escape');
      Link(escapeLink).createSync(outsideRoot.path);
      final localPath = p.join(escapeLink, 'new-checkout');

      final localPathClient = ApiRouteTestClient(
        projectRoutes(
          projects,
          projectConfig: const ProjectConfig(allowApiLocalPath: true),
          containerEnabled: true,
          containerMountRoots: [mountedRoot.path],
        ).call,
      );

      expect(
        await localPathClient.expectJsonErrorCode(
          'POST',
          '/api/projects',
          json: {'name': 'Escaped App', 'localPath': localPath},
          status: 400,
        ),
        'LOCAL_PATH_NOT_MOUNTABLE',
      );
    });

    test('container mode accepts new descendants under symlinked mounted roots', () async {
      final tempDir = Directory.systemTemp.createTempSync('project_routes_symlink_root_test_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final realRoot = Directory(p.join(tempDir.path, 'real-root'))..createSync(recursive: true);
      final aliasRoot = p.join(tempDir.path, 'alias-root');
      Link(aliasRoot).createSync(realRoot.path);
      final localPath = p.join(aliasRoot, 'new-checkout');

      final localPathClient = ApiRouteTestClient(
        projectRoutes(
          projects,
          projectConfig: const ProjectConfig(allowApiLocalPath: true),
          containerEnabled: true,
          containerMountRoots: [aliasRoot],
        ).call,
      );

      final body = await localPathClient.expectJsonObject(
        'POST',
        '/api/projects',
        json: {'name': 'Aliased App', 'localPath': localPath},
        status: 201,
      );

      expect(body['localPath'], localPath);
    });

    test('duplicate ID returns 409', () async {
      projects.seed(makeProject(id: 'my-app'));
      expect(
        await client.expectJsonErrorCode(
          'POST',
          '/api/projects',
          json: {'name': 'My App', 'remoteUrl': 'https://github.com/x/y.git'},
          status: 409,
        ),
        'PROJECT_ID_CONFLICT',
      );
    });

    test('project auth failures return 422 with auth details', () async {
      final authFailingProjects = FakeProjectService(
        onCreate:
            ({
              required name,
              remoteUrl,
              localPath,
              defaultBranch = 'main',
              credentialsRef,
              cloneStrategy = CloneStrategy.shallow,
              pr = const PrConfig.defaults(),
            }) async {
              throw const ProjectAuthException(
                ProjectAuthStatus(
                  repository: 'acme/private-repo',
                  credentialsRef: 'github-main',
                  credentialType: 'githubToken',
                  compatible: false,
                  errorCode: 'github_auth_failed',
                  errorMessage: 'GitHub token "github-main" cannot access acme/private-repo.',
                ),
              );
            },
      );
      final authClient = ApiRouteTestClient(projectRoutes(authFailingProjects).call);

      final body = await authClient.expectJsonObject(
        'POST',
        '/api/projects',
        json: {
          'name': 'Private App',
          'remoteUrl': 'https://github.com/acme/private-repo.git',
          'credentialsRef': 'github-main',
        },
        status: 422,
      );

      expect((body['error'] as Map<String, dynamic>)['code'], 'github_auth_failed');
      expect(
        ((body['error'] as Map<String, dynamic>)['details'] as Map<String, dynamic>)['auth']['repository'],
        'acme/private-repo',
      );
    });
  });

  // ------------------------------------------------------------------
  // GET /api/projects
  // ------------------------------------------------------------------

  group('GET /api/projects', () {
    test('empty registry returns list with _local only', () async {
      final list = await client.expectJsonList('GET', '/api/projects');
      expect(list, hasLength(1));
      expect((list.first as Map)['id'], '_local');
    });

    test('with projects returns all including _local', () async {
      projects.seed(makeProject(id: 'proj-a'));
      projects.seed(makeProject(id: 'proj-b'));
      final list = await client.expectJsonList('GET', '/api/projects');
      expect(list, hasLength(3)); // _local + 2
      final ids = list.map((p) => (p as Map)['id']).toList();
      expect(ids, containsAll(['_local', 'proj-a', 'proj-b']));
    });
  });

  // ------------------------------------------------------------------
  // GET /api/projects/<id>
  // ------------------------------------------------------------------

  group('GET /api/projects/<id>', () {
    test('existing project returns 200 with all fields', () async {
      projects.seed(makeProject(id: 'my-proj'));
      final body = await client.expectJsonObject('GET', '/api/projects/my-proj');
      expect(body['id'], 'my-proj');
    });

    test('unknown ID returns 404', () async {
      expect(await client.expectJsonErrorCode('GET', '/api/projects/no-such', status: 404), 'PROJECT_NOT_FOUND');
    });

    test('_local project returns 200', () async {
      final body = await client.expectJsonObject('GET', '/api/projects/_local');
      expect(body['id'], '_local');
    });
  });

  // ------------------------------------------------------------------
  // PATCH /api/projects/<id>
  // ------------------------------------------------------------------

  group('PATCH /api/projects/<id>', () {
    test('update name on runtime project returns 200', () async {
      projects.seed(makeProject(id: 'my-proj'));
      final body = await client.expectJsonObject('PATCH', '/api/projects/my-proj', json: {'name': 'New Name'});
      expect(body['name'], 'New Name');
    });

    test('update on config-defined project returns 403', () async {
      projects.seed(makeProject(id: 'cfg-proj', configDefined: true));
      expect(
        await client.expectJsonErrorCode('PATCH', '/api/projects/cfg-proj', json: {'name': 'Nope'}, status: 403),
        'CONFIG_DEFINED',
      );
    });

    test('update on _local returns 404', () async {
      await client.expectResponse('PATCH', '/api/projects/_local', json: {'name': 'Nope'}, status: 404);
    });

    test('change remoteUrl with no active tasks starts a fresh clone', () async {
      projects.seed(makeProject(id: 'my-proj'));
      final body = await client.expectJsonObject(
        'PATCH',
        '/api/projects/my-proj',
        json: {'remoteUrl': 'https://github.com/new/repo.git'},
      );
      expect(body['remoteUrl'], 'https://github.com/new/repo.git');
      expect(body['status'], 'cloning');
    });

    test('update PR config returns 200 with updated fields', () async {
      projects.seed(makeProject(id: 'my-proj'));
      final body = await client.expectJsonObject(
        'PATCH',
        '/api/projects/my-proj',
        json: {
          'pr': {'strategy': 'githubPr', 'draft': true},
        },
      );
      expect(body['pr']['strategy'], 'githubPr');
    });

    test('empty body is a no-op returning 200', () async {
      projects.seed(makeProject(id: 'my-proj'));
      await client.expectResponse('PATCH', '/api/projects/my-proj', json: {}, status: 200);
    });

    test('change remoteUrl with active tasks returns 409', () async {
      projects.seed(makeProject(id: 'my-proj'));
      final db = openTaskDbInMemory();
      final eventBus = EventBus();
      final taskService = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
      await _seedRunningTask(taskService, 'running-task', 'my-proj');
      final clientWithTasks = ApiRouteTestClient(projectRoutes(projects, tasks: taskService).call);

      final response = await clientWithTasks.request(
        'PATCH',
        '/api/projects/my-proj',
        json: {'remoteUrl': 'https://github.com/new/repo.git'},
      );
      await eventBus.dispose();
      await taskService.dispose();
      expect(response.statusCode, 409);
      expect(await errorCode(response), 'ACTIVE_TASKS');
    });

    test('change defaultBranch with active tasks returns 409', () async {
      projects.seed(makeProject(id: 'my-proj'));
      final db = openTaskDbInMemory();
      final eventBus = EventBus();
      final taskService = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
      await _seedRunningTask(taskService, 'branch-task', 'my-proj');
      final clientWithTasks = ApiRouteTestClient(projectRoutes(projects, tasks: taskService).call);

      final response = await clientWithTasks.request('PATCH', '/api/projects/my-proj', json: {'defaultBranch': 'dev'});
      await eventBus.dispose();
      await taskService.dispose();
      expect(response.statusCode, 409);
      expect(await errorCode(response), 'ACTIVE_TASKS');
    });

    test('change remoteUrl while clone is in progress returns 409', () async {
      projects.seed(makeProject(id: 'my-proj', status: ProjectStatus.cloning));

      expect(
        await client.expectJsonErrorCode(
          'PATCH',
          '/api/projects/my-proj',
          json: {'remoteUrl': 'https://github.com/new/repo.git'},
          status: 409,
        ),
        'CLONE_IN_PROGRESS',
      );
    });
  });

  // ------------------------------------------------------------------
  // DELETE /api/projects/<id>
  // ------------------------------------------------------------------

  group('DELETE /api/projects/<id>', () {
    test('delete runtime project with no tasks returns 200', () async {
      projects.seed(makeProject(id: 'del-proj'));
      final body = await client.expectJsonObject('DELETE', '/api/projects/del-proj');
      expect(body['deleted'], 'del-proj');
      // Confirm project is gone
      expect(await projects.get('del-proj'), isNull);
    });

    test('delete config-defined project returns 403', () async {
      projects.seed(makeProject(id: 'cfg-proj', configDefined: true));
      expect(await client.expectJsonErrorCode('DELETE', '/api/projects/cfg-proj', status: 403), 'CONFIG_DEFINED');
    });

    test('delete _local returns 404', () async {
      await client.expectResponse('DELETE', '/api/projects/_local', status: 404);
    });

    test('delete unknown project returns 404', () async {
      await client.expectResponse('DELETE', '/api/projects/no-such', status: 404);
    });

    test('delete with running task cancels task and deletes project', () async {
      projects.seed(makeProject(id: 'run-proj'));
      final db = openTaskDbInMemory();
      final eventBus = EventBus();
      final taskService = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
      await _seedRunningTask(taskService, 'run-task', 'run-proj');
      final clientWithTasks = ApiRouteTestClient(projectRoutes(projects, tasks: taskService).call);

      await clientWithTasks.expectResponse('DELETE', '/api/projects/run-proj', status: 200);

      final task = await taskService.get('run-task');
      expect(task!.status, TaskStatus.cancelled);
      expect(await projects.get('run-proj'), isNull);

      await eventBus.dispose();
      await taskService.dispose();
    });

    test('delete with queued task fails task and deletes project', () async {
      projects.seed(makeProject(id: 'q-proj'));
      final db = openTaskDbInMemory();
      final eventBus = EventBus();
      final taskService = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
      await _seedQueuedTask(taskService, 'q-task', 'q-proj');
      final clientWithTasks = ApiRouteTestClient(projectRoutes(projects, tasks: taskService).call);

      await clientWithTasks.expectResponse('DELETE', '/api/projects/q-proj', status: 200);

      final task = await taskService.get('q-task');
      expect(task!.status, TaskStatus.failed);
      expect(task.configJson['errorSummary'], contains('Project "q-proj" was deleted'));

      await eventBus.dispose();
      await taskService.dispose();
    });

    test('delete with review task fails task and deletes project', () async {
      projects.seed(makeProject(id: 'rev-proj'));
      final db = openTaskDbInMemory();
      final eventBus = EventBus();
      final taskService = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
      await _seedReviewTask(taskService, 'rev-task', 'rev-proj');
      final clientWithTasks = ApiRouteTestClient(projectRoutes(projects, tasks: taskService).call);

      await clientWithTasks.expectResponse('DELETE', '/api/projects/rev-proj', status: 200);

      final task = await taskService.get('rev-task');
      expect(task!.status, TaskStatus.failed);
      expect(task.configJson['errorSummary'], contains('Project "rev-proj" was deleted'));
      expect(await projects.get('rev-proj'), isNull);

      await eventBus.dispose();
      await taskService.dispose();
    });
  });

  // ------------------------------------------------------------------
  // POST /api/projects/<id>/fetch
  // ------------------------------------------------------------------

  group('POST /api/projects/<id>/fetch', () {
    test('fetch ready project returns 200 with updated project', () async {
      projects.seed(makeProject(id: 'fetch-proj'));
      final body = await client.expectJsonObject('POST', '/api/projects/fetch-proj/fetch');
      expect(body['id'], 'fetch-proj');
      expect(body['status'], 'ready');
      expect(body['lastFetchAt'], isNotNull);
    });

    test('fetch unknown project returns 404', () async {
      expect(await client.expectJsonErrorCode('POST', '/api/projects/no-such/fetch', status: 404), 'PROJECT_NOT_FOUND');
    });

    test('fetch project in cloning state returns 400', () async {
      projects.seed(makeProject(id: 'cloning-proj', status: ProjectStatus.cloning));
      expect(
        await client.expectJsonErrorCode('POST', '/api/projects/cloning-proj/fetch', status: 400),
        'CLONE_IN_PROGRESS',
      );
    });

    test('fetch _local project returns 400 (no remote)', () async {
      expect(await client.expectJsonErrorCode('POST', '/api/projects/_local/fetch', status: 400), 'LOCAL_PROJECT');
    });
  });

  // ------------------------------------------------------------------
  // GET /api/projects/<id>/status
  // ------------------------------------------------------------------

  group('GET /api/projects/<id>/status', () {
    test('ready project returns status + lastFetchAt', () async {
      final p = Project(
        id: 'status-proj',
        name: 'Status',
        remoteUrl: 'https://x.com/r.git',
        localPath: '/tmp',
        defaultBranch: 'main',
        status: ProjectStatus.ready,
        lastFetchAt: DateTime.parse('2026-01-01T10:00:00Z'),
        createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
      );
      projects.seed(p);
      final body = await client.expectJsonObject('GET', '/api/projects/status-proj/status');
      expect(body['status'], 'ready');
      expect(body['lastFetchAt'], '2026-01-01T10:00:00.000Z');
      expect(body['errorMessage'], isNull);
    });

    test('error project returns status + errorMessage', () async {
      final p = Project(
        id: 'err-proj',
        name: 'Error',
        remoteUrl: 'https://x.com/r.git',
        localPath: '/tmp',
        defaultBranch: 'main',
        status: ProjectStatus.error,
        errorMessage: 'Clone failed',
        createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
      );
      projects.seed(p);
      final body = await client.expectJsonObject('GET', '/api/projects/err-proj/status');
      expect(body['status'], 'error');
      expect(body['errorMessage'], 'Clone failed');
    });

    test('status includes auth metadata when present', () async {
      final p = Project(
        id: 'auth-proj',
        name: 'Auth',
        remoteUrl: 'https://github.com/acme/private-repo.git',
        localPath: '/tmp',
        defaultBranch: 'main',
        status: ProjectStatus.error,
        auth: const ProjectAuthStatus(
          repository: 'acme/private-repo',
          credentialsRef: 'github-main',
          credentialType: 'githubToken',
          compatible: false,
          errorCode: 'github_auth_failed',
          errorMessage: 'denied',
        ),
        createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
      );
      projects.seed(p);
      final body = await client.expectJsonObject('GET', '/api/projects/auth-proj/status');
      expect((body['auth'] as Map<String, dynamic>)['repository'], 'acme/private-repo');
      expect((body['auth'] as Map<String, dynamic>)['compatible'], isFalse);
    });

    test('unknown project returns 404', () async {
      expect(await client.expectJsonErrorCode('GET', '/api/projects/no-such/status', status: 404), 'PROJECT_NOT_FOUND');
    });
  });
}

// ---------------------------------------------------------------------------
// Task seeding helpers
// ---------------------------------------------------------------------------

Future<void> _seedRunningTask(TaskService tasks, String id, String projectId) async {
  await tasks.create(
    id: id,
    title: 'Running $id',
    description: 'For project $projectId',
    type: TaskType.coding,
    projectId: projectId,
    autoStart: true,
  );
  await tasks.transition(id, TaskStatus.running);
}

Future<void> _seedQueuedTask(TaskService tasks, String id, String projectId) async {
  await tasks.create(
    id: id,
    title: 'Queued $id',
    description: 'For project $projectId',
    type: TaskType.coding,
    projectId: projectId,
    autoStart: true,
  );
}

Future<void> _seedReviewTask(TaskService tasks, String id, String projectId) async {
  await tasks.create(
    id: id,
    title: 'Review $id',
    description: 'For project $projectId',
    type: TaskType.coding,
    projectId: projectId,
    autoStart: true,
  );
  await tasks.transition(id, TaskStatus.running);
  await tasks.transition(id, TaskStatus.review);
}
