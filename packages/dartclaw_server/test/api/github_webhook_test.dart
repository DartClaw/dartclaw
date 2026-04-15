import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_server/src/api/github_webhook.dart';
import 'package:dartclaw_server/src/api/github_webhook_config.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SqliteTaskRepository, SqliteWorkflowRunRepository, openTaskDbInMemory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show InMemoryDefinitionSource, WorkflowDefinitionSource, WorkflowService;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database taskDb;
  late Database workflowDb;
  late TaskService tasks;
  late _FakeWorkflowService workflows;
  late Directory tempDir;
  late WorkflowDefinitionSource definitions;

  setUp(() async {
    taskDb = openTaskDbInMemory();
    workflowDb = sqlite3.openInMemory();
    tempDir = Directory.systemTemp.createTempSync('github-webhook-test_');

    final taskRepo = SqliteTaskRepository(taskDb);
    final eventBus = EventBus();
    tasks = TaskService(taskRepo, eventBus: eventBus);
    workflows = _FakeWorkflowService(db: workflowDb, taskService: tasks, eventBus: eventBus, dataDir: tempDir.path);
    workflows.startResult = WorkflowRun(
      id: 'run-1',
      definitionName: 'code-review',
      status: WorkflowRunStatus.running,
      startedAt: DateTime.utc(2026, 1, 1, 12),
      updatedAt: DateTime.utc(2026, 1, 1, 12),
      definitionJson: const {},
    );
    definitions = InMemoryDefinitionSource([
      WorkflowDefinition(
        name: 'code-review',
        description: 'Review a pull request',
        variables: const {
          'TARGET': WorkflowVariable(required: true),
          'PR_NUMBER': WorkflowVariable(required: true),
          'BRANCH': WorkflowVariable(required: true),
          'BASE_BRANCH': WorkflowVariable(required: true),
          'REPO': WorkflowVariable(required: true),
        },
        steps: const [
          WorkflowStep(id: 'step-1', name: 'Review', prompts: ['Review']),
        ],
      ),
    ]);
  });

  tearDown(() async {
    await workflows.dispose();
    await tasks.dispose();
    taskDb.close();
    workflowDb.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('valid GitHub signatures start the workflow', () async {
    final handler = GitHubWebhookHandler(
      config: const GitHubWebhookConfig(
        enabled: true,
        webhookSecret: 'secret',
        triggers: [
          GitHubWorkflowTrigger(event: 'pull_request', actions: ['opened'], labels: [], workflow: 'code-review'),
        ],
      ),
      workflows: workflows,
      definitions: definitions,
    );
    final payload = _pullRequestPayload(action: 'opened');

    final response = await handler.handle(_signedRequest(payload, 'secret'));

    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    expect(body['ok'], isTrue);
    expect(workflows.calls, contains('start:code-review'));
  });

  test('invalid signatures are rejected', () async {
    final eventBus = EventBus();
    addTearDown(eventBus.dispose);
    final events = <FailedAuthEvent>[];
    final sub = eventBus.on<FailedAuthEvent>().listen(events.add);
    addTearDown(sub.cancel);

    final handler = GitHubWebhookHandler(
      config: const GitHubWebhookConfig(enabled: true, webhookSecret: 'secret'),
      workflows: workflows,
      definitions: definitions,
      eventBus: eventBus,
    );

    final response = await handler.handle(
      Request(
        'POST',
        Uri.parse('http://localhost/webhook/github'),
        headers: {'x-github-event': 'pull_request', 'x-hub-signature-256': 'sha256=wrong'},
        body: jsonEncode(_pullRequestPayload(action: 'opened')),
      ),
    );

    expect(response.statusCode, 403);
    await Future<void>.delayed(Duration.zero);
    expect(events.single.reason, 'invalid_github_signature');
  });

  test('duplicate pull request events are deduplicated while a run is active', () async {
    final handler = GitHubWebhookHandler(
      config: const GitHubWebhookConfig(
        enabled: true,
        webhookSecret: 'secret',
        triggers: [
          GitHubWorkflowTrigger(event: 'pull_request', actions: ['opened'], labels: [], workflow: 'code-review'),
        ],
      ),
      workflows: workflows,
      definitions: definitions,
    );
    final payload = _pullRequestPayload(action: 'opened');

    await handler.handle(_signedRequest(payload, 'secret'));
    final response = await handler.handle(_signedRequest(payload, 'secret'));

    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    expect(body['deduped'], isTrue);
    expect(workflows.activeRuns, hasLength(1));
  });

  test('unmatched pull request actions are ignored', () async {
    final handler = GitHubWebhookHandler(
      config: const GitHubWebhookConfig(
        enabled: true,
        webhookSecret: 'secret',
        triggers: [
          GitHubWorkflowTrigger(event: 'pull_request', actions: ['opened'], labels: [], workflow: 'code-review'),
        ],
      ),
      workflows: workflows,
      definitions: definitions,
    );

    final response = await handler.handle(_signedRequest(_pullRequestPayload(action: 'closed'), 'secret'));

    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    expect(body['ignored'], isTrue);
    expect(workflows.calls, isEmpty);
  });

  test('label-gated triggers are ignored when labels do not match', () async {
    final handler = GitHubWebhookHandler(
      config: const GitHubWebhookConfig(
        enabled: true,
        webhookSecret: 'secret',
        triggers: [
          GitHubWorkflowTrigger(
            event: 'pull_request',
            actions: ['opened'],
            labels: ['needs-review'],
            workflow: 'code-review',
          ),
        ],
      ),
      workflows: workflows,
      definitions: definitions,
    );

    final response = await handler.handle(_signedRequest(_pullRequestPayload(action: 'opened'), 'secret'));

    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    expect(body['ignored'], isTrue);
    expect(workflows.calls, isEmpty);
  });

  test('webhook review start passes PROJECT context instead of REPO-only context', () async {
    final handler = GitHubWebhookHandler(
      config: const GitHubWebhookConfig(
        enabled: true,
        webhookSecret: 'secret',
        triggers: [
          GitHubWorkflowTrigger(event: 'pull_request', actions: ['opened'], labels: [], workflow: 'code-review'),
        ],
      ),
      workflows: workflows,
      definitions: InMemoryDefinitionSource([
        WorkflowDefinition(
          name: 'code-review',
          description: 'Review a pull request',
          variables: const {
            'TARGET': WorkflowVariable(required: true),
            'PR_NUMBER': WorkflowVariable(required: true),
            'BRANCH': WorkflowVariable(required: true),
            'BASE_BRANCH': WorkflowVariable(required: true),
            'PROJECT': WorkflowVariable(required: true),
          },
          steps: const [
            WorkflowStep(id: 'step-1', name: 'Review', prompts: ['Review']),
          ],
        ),
      ]),
      projects: _StaticProjectService([
        Project(
          id: 'owner-repo',
          name: 'Owner Repo',
          remoteUrl: 'git@github.com:owner/repo.git',
          localPath: '/projects/owner-repo',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      ]),
    );

    final response = await handler.handle(_signedRequest(_pullRequestPayload(action: 'opened'), 'secret'));

    expect(response.statusCode, 200);
    expect(workflows.lastProjectId, isNotEmpty);
    expect(workflows.activeRuns.single.variablesJson['PROJECT'], equals(workflows.lastProjectId));
    expect(workflows.activeRuns.single.variablesJson.containsKey('REPO'), isFalse);
  });

  test('project-backed webhook fails fast when repository slug has no unique project match', () async {
    final handler = GitHubWebhookHandler(
      config: const GitHubWebhookConfig(
        enabled: true,
        webhookSecret: 'secret',
        triggers: [
          GitHubWorkflowTrigger(event: 'pull_request', actions: ['opened'], labels: [], workflow: 'code-review'),
        ],
      ),
      workflows: workflows,
      definitions: InMemoryDefinitionSource([
        WorkflowDefinition(
          name: 'code-review',
          description: 'Review a pull request',
          variables: const {
            'TARGET': WorkflowVariable(required: true),
            'PR_NUMBER': WorkflowVariable(required: true),
            'BRANCH': WorkflowVariable(required: true),
            'BASE_BRANCH': WorkflowVariable(required: true),
            'PROJECT': WorkflowVariable(required: true),
          },
          steps: const [
            WorkflowStep(id: 'step-1', name: 'Review', prompts: ['Review']),
          ],
        ),
      ]),
      projects: _StaticProjectService(const []),
    );

    final response = await handler.handle(_signedRequest(_pullRequestPayload(action: 'opened'), 'secret'));
    expect(response.statusCode, 400);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    final error = body['error'] as Map<String, dynamic>;
    expect(error['code'], 'PROJECT_RESOLUTION_FAILED');
    expect(workflows.calls, isEmpty);
  });

  test('project-backed webhook fails fast on ambiguous slug matches', () async {
    final handler = GitHubWebhookHandler(
      config: const GitHubWebhookConfig(
        enabled: true,
        webhookSecret: 'secret',
        triggers: [
          GitHubWorkflowTrigger(event: 'pull_request', actions: ['opened'], labels: [], workflow: 'code-review'),
        ],
      ),
      workflows: workflows,
      definitions: InMemoryDefinitionSource([
        WorkflowDefinition(
          name: 'code-review',
          description: 'Review a pull request',
          variables: const {
            'TARGET': WorkflowVariable(required: true),
            'PR_NUMBER': WorkflowVariable(required: true),
            'BRANCH': WorkflowVariable(required: true),
            'BASE_BRANCH': WorkflowVariable(required: true),
            'PROJECT': WorkflowVariable(required: true),
          },
          steps: const [
            WorkflowStep(id: 'step-1', name: 'Review', prompts: ['Review']),
          ],
        ),
      ]),
      projects: _StaticProjectService([
        Project(
          id: 'repo-a',
          name: 'Repo A',
          remoteUrl: 'git@github.com:owner/repo.git',
          localPath: '/projects/repo-a',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
        Project(
          id: 'repo-b',
          name: 'Repo B',
          remoteUrl: 'https://github.com/owner/repo.git',
          localPath: '/projects/repo-b',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      ]),
    );

    final response = await handler.handle(_signedRequest(_pullRequestPayload(action: 'opened'), 'secret'));
    expect(response.statusCode, 400);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    final error = body['error'] as Map<String, dynamic>;
    expect(error['code'], 'PROJECT_RESOLUTION_FAILED');
    expect(workflows.calls, isEmpty);
  });
}

class _FakeWorkflowService extends WorkflowService {
  _FakeWorkflowService._super(
    SqliteWorkflowRunRepository repository,
    TaskService taskService,
    MessageService messageService,
    EventBus eventBus,
    KvService kvService,
    String dataDir,
  ) : super(
        repository: repository,
        taskService: taskService,
        messageService: messageService,
        eventBus: eventBus,
        kvService: kvService,
        dataDir: dataDir,
      );

  factory _FakeWorkflowService({
    required Database db,
    required TaskService taskService,
    required EventBus eventBus,
    required String dataDir,
  }) {
    final repo = SqliteWorkflowRunRepository(db);
    final messages = MessageService(baseDir: p.join(dataDir, 'sessions'));
    final kv = KvService(filePath: p.join(dataDir, 'kv.json'));
    return _FakeWorkflowService._super(repo, taskService, messages, eventBus, kv, dataDir);
  }

  final List<String> calls = <String>[];
  WorkflowRun? startResult;
  final List<WorkflowRun> activeRuns = <WorkflowRun>[];
  String? lastProjectId;

  @override
  Future<WorkflowRun> start(
    WorkflowDefinition definition,
    Map<String, String> variables, {
    String? projectId,
    bool headless = false,
  }) async {
    calls.add('start:${definition.name}');
    lastProjectId = projectId;
    final run = startResult!;
    activeRuns.add(run.copyWith(definitionName: definition.name, variablesJson: variables));
    return run;
  }

  @override
  Future<List<WorkflowRun>> list({WorkflowRunStatus? status, String? definitionName}) async {
    return activeRuns.where((run) => definitionName == null || run.definitionName == definitionName).toList();
  }
}

Request _signedRequest(Map<String, dynamic> payload, String secret) {
  final body = jsonEncode(payload);
  final digest = Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(body)).toString();
  return Request(
    'POST',
    Uri.parse('http://localhost/webhook/github'),
    headers: {'x-github-event': 'pull_request', 'x-hub-signature-256': 'sha256=$digest'},
    body: body,
  );
}

Map<String, dynamic> _pullRequestPayload({required String action}) {
  return {
    'action': action,
    'pull_request': {
      'title': 'Add feature',
      'number': 42,
      'head': {'ref': 'feature/test'},
      'base': {'ref': 'main'},
      'labels': const <Map<String, String>>[],
    },
    'repository': {'full_name': 'owner/repo'},
  };
}

class _StaticProjectService implements ProjectService {
  _StaticProjectService(this.projects);

  final List<Project> projects;

  @override
  Future<Project?> get(String id) async {
    for (final project in projects) {
      if (project.id == id) return project;
    }
    return null;
  }

  @override
  Future<List<Project>> getAll() async => projects.toList(growable: false);

  @override
  Future<Project> create({
    required String name,
    required String remoteUrl,
    String defaultBranch = 'main',
    String? credentialsRef,
    CloneStrategy cloneStrategy = CloneStrategy.shallow,
    PrConfig pr = const PrConfig.defaults(),
  }) => throw UnimplementedError();

  @override
  Future<Project> update(
    String id, {
    String? name,
    String? remoteUrl,
    String? defaultBranch,
    String? credentialsRef,
    PrConfig? pr,
  }) => throw UnimplementedError();

  @override
  Future<Project> fetch(String id) => throw UnimplementedError();

  @override
  Future<void> ensureFresh(Project project, {String? ref, bool strict = false}) async {}

  @override
  Future<void> delete(String id) => throw UnimplementedError();

  @override
  Future<Project> getDefaultProject() => throw UnimplementedError();

  @override
  Project getLocalProject() => throw UnimplementedError();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async {}
}
