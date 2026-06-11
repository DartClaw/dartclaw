import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show CloneStrategy, PrConfig, Project, ProjectStatus;
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_server/src/api/github_webhook.dart';
import 'package:dartclaw_server/src/api/github_webhook_config.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SqliteTaskRepository, WebhookDeliveryStore, openTaskDbInMemory, openWebhookDeliveryStoreInMemory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        InMemoryDefinitionSource,
        WorkflowDefinition,
        WorkflowDefinitionSource,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep,
        WorkflowVariable;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'workflow_test_support.dart';

void main() {
  late Database taskDb;
  late Database workflowDb;
  late TaskService tasks;
  late FakeWorkflowService workflows;
  late Directory tempDir;
  late WorkflowDefinitionSource definitions;

  setUp(() async {
    taskDb = openTaskDbInMemory();
    workflowDb = sqlite3.openInMemory();
    tempDir = Directory.systemTemp.createTempSync('github-webhook-test_');

    final taskRepo = SqliteTaskRepository(taskDb);
    final eventBus = EventBus();
    tasks = TaskService(taskRepo, eventBus: eventBus);
    workflows = FakeWorkflowService(db: workflowDb, taskService: tasks, eventBus: eventBus, dataDir: tempDir.path);
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

    final response = await handler.handle(_signedRequest(payload, 'secret', deliveryId: 'del-1'));

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

    await handler.handle(_signedRequest(payload, 'secret', deliveryId: 'del-first'));
    final response = await handler.handle(_signedRequest(payload, 'secret', deliveryId: 'del-second'));

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

    final response = await handler.handle(
      _signedRequest(_pullRequestPayload(action: 'closed'), 'secret', deliveryId: 'del-closed'),
    );

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

    final response = await handler.handle(
      _signedRequest(_pullRequestPayload(action: 'opened'), 'secret', deliveryId: 'del-label'),
    );

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

    final response = await handler.handle(
      _signedRequest(_pullRequestPayload(action: 'opened'), 'secret', deliveryId: 'del-proj'),
    );

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

    final response = await handler.handle(
      _signedRequest(_pullRequestPayload(action: 'opened'), 'secret', deliveryId: 'del-no-proj'),
    );
    expect(response.statusCode, 400);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    final error = body['error'] as Map<String, dynamic>;
    expect(error['code'], 'PROJECT_RESOLUTION_FAILED');
    expect(workflows.calls, isEmpty);
  });

  group('delivery-ID replay protection', () {
    late WebhookDeliveryStore deliveryStore;

    setUp(() {
      deliveryStore = openWebhookDeliveryStoreInMemory();
    });

    GitHubWebhookHandler makeHandler({WebhookDeliveryStore? store}) {
      return GitHubWebhookHandler(
        config: const GitHubWebhookConfig(
          enabled: true,
          webhookSecret: 'secret',
          triggers: [
            GitHubWorkflowTrigger(event: 'pull_request', actions: ['opened'], labels: [], workflow: 'code-review'),
          ],
        ),
        workflows: workflows,
        definitions: definitions,
        deliveryStore: store,
      );
    }

    test('first delivery starts a workflow', () async {
      final handler = makeHandler(store: deliveryStore);
      final payload = _pullRequestPayload(action: 'opened');

      final response = await handler.handle(_signedRequest(payload, 'secret', deliveryId: 'unique-abc'));

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isTrue);
      expect(body['deduped'], isNot(true));
      expect(workflows.calls, contains('start:code-review'));
    });

    test('replayed delivery ID is rejected even after the run reaches terminal status', () async {
      final handler = makeHandler(store: deliveryStore);
      final payload = _pullRequestPayload(action: 'opened');
      const deliveryId = 'replay-target-xyz';

      // First request — starts a run.
      await handler.handle(_signedRequest(payload, 'secret', deliveryId: deliveryId));

      // Simulate run reaching terminal status.
      final run = workflows.activeRuns.last;
      workflows.activeRuns
        ..remove(run)
        ..add(run.copyWith(status: WorkflowRunStatus.completed));

      // Replay with the same delivery ID.
      final replayResponse = await handler.handle(_signedRequest(payload, 'secret', deliveryId: deliveryId));

      expect(replayResponse.statusCode, 200);
      final body = jsonDecode(await replayResponse.readAsString()) as Map<String, dynamic>;
      expect(body['deduped'], isTrue);
      // Only one run was ever started.
      expect(workflows.calls.where((c) => c == 'start:code-review'), hasLength(1));
    });

    test('different delivery IDs for different PRs each start a workflow', () async {
      final handler = makeHandler(store: deliveryStore);

      final r1 = await handler.handle(
        _signedRequest(_pullRequestPayload(action: 'opened', prNumber: 1), 'secret', deliveryId: 'delivery-1'),
      );
      final r2 = await handler.handle(
        _signedRequest(_pullRequestPayload(action: 'opened', prNumber: 2), 'secret', deliveryId: 'delivery-2'),
      );

      expect(r1.statusCode, 200);
      expect(r2.statusCode, 200);
      expect(workflows.calls.where((c) => c == 'start:code-review'), hasLength(2));
    });

    test('request missing x-github-delivery header is rejected with 400', () async {
      final handler = makeHandler(store: deliveryStore);
      final payload = _pullRequestPayload(action: 'opened');
      final body = jsonEncode(payload);
      final digest = Hmac(sha256, utf8.encode('secret')).convert(utf8.encode(body)).toString();

      final response = await handler.handle(
        Request(
          'POST',
          Uri.parse('http://localhost/webhook/github'),
          headers: {
            'x-github-event': 'pull_request',
            'x-hub-signature-256': 'sha256=$digest',
            // No x-github-delivery header.
          },
          body: body,
        ),
      );

      expect(response.statusCode, 400);
      final respBody = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final error = respBody['error'] as Map<String, dynamic>;
      expect(error['code'], 'MISSING_DELIVERY_ID');
      expect(workflows.calls, isEmpty);
    });

    test('without a delivery store, missing header still rejects', () async {
      // Even without a persistent store, the header is required.
      final handler = makeHandler(store: null);
      final payload = _pullRequestPayload(action: 'opened');
      final body = jsonEncode(payload);
      final digest = Hmac(sha256, utf8.encode('secret')).convert(utf8.encode(body)).toString();

      final response = await handler.handle(
        Request(
          'POST',
          Uri.parse('http://localhost/webhook/github'),
          headers: {'x-github-event': 'pull_request', 'x-hub-signature-256': 'sha256=$digest'},
          body: body,
        ),
      );

      expect(response.statusCode, 400);
    });

    test('redelivery can start after workflow-start failure', () async {
      final handler = makeHandler(store: deliveryStore);
      final payload = _pullRequestPayload(action: 'opened');
      const deliveryId = 'retry-after-start-failure';
      workflows.startError = StateError('workflow start failed');

      await expectLater(
        () => handler.handle(_signedRequest(payload, 'secret', deliveryId: deliveryId)),
        throwsStateError,
      );

      workflows.startError = null;
      final response = await handler.handle(_signedRequest(payload, 'secret', deliveryId: deliveryId));

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isTrue);
      expect(workflows.calls.where((call) => call == 'start:code-review'), hasLength(2));
      expect(workflows.activeRuns, hasLength(1));
    });

    test('accepted run stays deduped after processed-state commit failure and pending reclaim', () async {
      final deliveryDb = sqlite3.openInMemory();
      addTearDown(deliveryDb.close);
      final store = _CommitFailingWebhookDeliveryStore(deliveryDb);
      final handler = makeHandler(store: store);
      final payload = _pullRequestPayload(action: 'opened');
      const deliveryId = 'accepted-commit-failure';

      await expectLater(
        () => handler.handle(_signedRequest(payload, 'secret', deliveryId: deliveryId)),
        throwsStateError,
      );
      final acceptedRun = workflows.activeRuns.single;
      workflows.activeRuns
        ..remove(acceptedRun)
        ..add(acceptedRun.copyWith(status: WorkflowRunStatus.completed));
      deliveryDb.execute(
        "UPDATE webhook_delivery_ids SET updated_at = '1970-01-01T00:00:00.000Z' WHERE delivery_id = ?",
        [deliveryId],
      );

      final replay = await handler.handle(_signedRequest(payload, 'secret', deliveryId: deliveryId));

      expect(replay.statusCode, 200);
      final replayBody = jsonDecode(await replay.readAsString()) as Map<String, dynamic>;
      expect(replayBody['deduped'], isTrue);
      expect(store.commitAttempts, 2);
      expect(workflows.calls.where((call) => call == 'start:code-review'), hasLength(1));
    });

    test('duplicate same-delivery attempts while pending do not start duplicate workflows', () async {
      final handler = makeHandler(store: deliveryStore);
      final payload = _pullRequestPayload(action: 'opened');
      const deliveryId = 'pending-duplicate';
      final startCompleter = Completer<WorkflowRun>();
      workflows.startCompleter = startCompleter;

      final firstResponse = handler.handle(_signedRequest(payload, 'secret', deliveryId: deliveryId));
      await Future<void>.delayed(Duration.zero);

      final duplicateResponse = await handler.handle(_signedRequest(payload, 'secret', deliveryId: deliveryId));
      startCompleter.complete(workflows.startResult!);
      final first = await firstResponse;

      expect(first.statusCode, 200);
      expect(duplicateResponse.statusCode, 200);
      final duplicateBody = jsonDecode(await duplicateResponse.readAsString()) as Map<String, dynamic>;
      expect(duplicateBody['deduped'], isTrue);
      expect(workflows.calls.where((call) => call == 'start:code-review'), hasLength(1));
      expect(workflows.activeRuns, hasLength(1));
    });
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

    final response = await handler.handle(
      _signedRequest(_pullRequestPayload(action: 'opened'), 'secret', deliveryId: 'del-ambig'),
    );
    expect(response.statusCode, 400);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    final error = body['error'] as Map<String, dynamic>;
    expect(error['code'], 'PROJECT_RESOLUTION_FAILED');
    expect(workflows.calls, isEmpty);
  });
}

class _CommitFailingWebhookDeliveryStore extends WebhookDeliveryStore {
  _CommitFailingWebhookDeliveryStore(super.db);

  var commitAttempts = 0;

  @override
  void commitProcessed(String deliveryId) {
    commitAttempts += 1;
    throw StateError('processed-state commit failed');
  }
}

Request _signedRequest(Map<String, dynamic> payload, String secret, {String? deliveryId}) {
  final body = jsonEncode(payload);
  final digest = Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(body)).toString();
  return Request(
    'POST',
    Uri.parse('http://localhost/webhook/github'),
    headers: {
      'x-github-event': 'pull_request',
      'x-hub-signature-256': 'sha256=$digest',
      // ignore: use_null_aware_elements
      if (deliveryId != null) 'x-github-delivery': deliveryId,
    },
    body: body,
  );
}

Map<String, dynamic> _pullRequestPayload({required String action, int prNumber = 42}) {
  return {
    'action': action,
    'pull_request': {
      'title': 'Add feature',
      'number': prNumber,
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
    String? remoteUrl,
    String? localPath,
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
  Future<String> resolveWorkflowBaseRef(Project project, {String? requestedBranch}) async {
    final requested = requestedBranch?.trim();
    if (requested != null && requested.isNotEmpty) {
      return requested;
    }
    final configured = project.defaultBranch.trim();
    return configured.isNotEmpty ? configured : 'main';
  }

  @override
  Future<void> delete(String id) => throw UnimplementedError();

  @override
  Future<Project> get defaultProject => throw UnimplementedError();

  @override
  Project get localProject => throw UnimplementedError();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async {}
}
