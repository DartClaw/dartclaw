import 'dart:async';

import 'package:dartclaw_cli/src/commands/service_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowPublishStatus;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

class _FakeRemotePushService extends RemotePushService {
  final PushResult result;
  int callCount = 0;

  _FakeRemotePushService(this.result);

  @override
  Future<PushResult> push({required Project project, required String branch}) async {
    callCount++;
    return result;
  }
}

class _FakePrCreator extends PrCreator {
  final PrCreationResult result;
  final List<({Project project, Task task, String branch})> calls = [];

  _FakePrCreator(this.result);

  @override
  Future<PrCreationResult> create({required Project project, required Task task, required String branch}) async {
    calls.add((project: project, task: task, branch: branch));
    return result;
  }
}

void main() {
  late Database db;
  late EventBus eventBus;
  late TaskService taskService;

  setUp(() {
    db = openTaskDbInMemory();
    eventBus = EventBus();
    taskService = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
  });

  tearDown(() async {
    await eventBus.dispose();
    await taskService.dispose();
    db.close();
  });

  Project makeProject({PrConfig pr = const PrConfig.defaults()}) => Project(
    id: 'workflow-testing',
    name: 'workflow-testing',
    remoteUrl: 'git@github.com:acme/workflow-testing.git',
    localPath: '/tmp/workflow-testing',
    defaultBranch: 'main',
    credentialsRef: 'github-main',
    status: ProjectStatus.ready,
    pr: pr,
    createdAt: DateTime.parse('2026-04-15T10:00:00Z'),
  );

  Future<void> putWorkflowTask(String id, String runId, DateTime createdAt) {
    return taskService.create(
      id: id,
      title: 'Workflow task $id',
      description: 'Publish something.',
      type: TaskType.coding,
      workflowRunId: runId,
      autoStart: false,
      now: createdAt,
    );
  }

  group('publishWorkflowBranchWithProjectAuth', () {
    test('successfully creates a PR and persists the PR URL on the latest workflow task', () async {
      await putWorkflowTask('task-1', 'run-123', DateTime.parse('2026-04-15T10:01:00Z'));
      await putWorkflowTask('task-2', 'run-123', DateTime.parse('2026-04-15T10:02:00Z'));

      final projectService = FakeProjectService(
        projects: [makeProject(pr: const PrConfig(strategy: PrStrategy.githubPr))],
        includeLocalProjectInGetAll: false,
        defaultProjectId: 'workflow-testing',
      );
      final pushService = _FakeRemotePushService(const PushSuccess());
      final prCreator = _FakePrCreator(const PrCreated('https://github.com/acme/workflow-testing/pull/42'));

      final result = await publishWorkflowBranchWithProjectAuth(
        runId: 'run-123',
        projectId: 'workflow-testing',
        branch: 'dartclaw/workflow/run123',
        projectService: projectService,
        taskService: taskService,
        remotePushService: pushService,
        prCreator: prCreator,
      );

      expect(result.status, WorkflowPublishStatus.success);
      expect(result.branch, 'dartclaw/workflow/run123');
      expect(result.prUrl, 'https://github.com/acme/workflow-testing/pull/42');
      expect(pushService.callCount, 1);
      expect(prCreator.calls, hasLength(1));
      expect(prCreator.calls.single.task.id, 'task-2');
      final artifacts = await taskService.listArtifacts('task-2');
      expect(artifacts, hasLength(2));
      final branchArtifact = artifacts.singleWhere((artifact) => artifact.kind == ArtifactKind.branch);
      final prArtifact = artifacts.singleWhere((artifact) => artifact.kind == ArtifactKind.pr);
      expect(branchArtifact.name, 'Workflow Branch');
      expect(branchArtifact.path, 'dartclaw/workflow/run123');
      expect(prArtifact.name, 'Workflow Pull Request');
      expect(prArtifact.path, 'https://github.com/acme/workflow-testing/pull/42');
      expect(await pushedWorkflowBranches(taskService, [await taskService.get('task-2') as Task]), {
        'dartclaw/workflow/run123',
      });
    });

    test('manual PR fallback returns manual status and persists only the branch artifact', () async {
      await putWorkflowTask('task-1', 'run-123', DateTime.parse('2026-04-15T10:01:00Z'));

      final projectService = FakeProjectService(
        projects: [makeProject(pr: const PrConfig(strategy: PrStrategy.githubPr))],
        includeLocalProjectInGetAll: false,
        defaultProjectId: 'workflow-testing',
      );
      final pushService = _FakeRemotePushService(const PushSuccess());
      final prCreator = _FakePrCreator(const PrGhNotFound('Create the PR manually.'));

      final result = await publishWorkflowBranchWithProjectAuth(
        runId: 'run-123',
        projectId: 'workflow-testing',
        branch: 'dartclaw/workflow/run123',
        projectService: projectService,
        taskService: taskService,
        remotePushService: pushService,
        prCreator: prCreator,
      );

      expect(result.status, WorkflowPublishStatus.manual);
      expect(result.prUrl, isEmpty);
      final artifacts = await taskService.listArtifacts('task-1');
      expect(artifacts, hasLength(1));
      expect(artifacts.single.kind, ArtifactKind.branch);
      expect(artifacts.single.path, 'dartclaw/workflow/run123');
    });

    test('push auth failure returns failed status and does not create publish artifacts', () async {
      await putWorkflowTask('task-1', 'run-123', DateTime.parse('2026-04-15T10:01:00Z'));

      final projectService = FakeProjectService(
        projects: [makeProject(pr: const PrConfig(strategy: PrStrategy.githubPr))],
        includeLocalProjectInGetAll: false,
        defaultProjectId: 'workflow-testing',
      );
      final pushService = _FakeRemotePushService(const PushAuthFailure('Authentication denied.'));
      final prCreator = _FakePrCreator(const PrCreated('https://github.com/acme/workflow-testing/pull/42'));

      final result = await publishWorkflowBranchWithProjectAuth(
        runId: 'run-123',
        projectId: 'workflow-testing',
        branch: 'dartclaw/workflow/run123',
        projectService: projectService,
        taskService: taskService,
        remotePushService: pushService,
        prCreator: prCreator,
      );

      expect(result.status, WorkflowPublishStatus.failed);
      expect(result.error, 'Authentication failed: Authentication denied.');
      expect(prCreator.calls, isEmpty);
      expect(await taskService.listArtifacts('task-1'), isEmpty);
    });

    test('PR creation failure returns failed status and persists only the branch artifact', () async {
      await putWorkflowTask('task-1', 'run-123', DateTime.parse('2026-04-15T10:01:00Z'));

      final projectService = FakeProjectService(
        projects: [makeProject(pr: const PrConfig(strategy: PrStrategy.githubPr))],
        includeLocalProjectInGetAll: false,
        defaultProjectId: 'workflow-testing',
      );
      final pushService = _FakeRemotePushService(const PushSuccess());
      final prCreator = _FakePrCreator(
        const PrCreationFailed(
          error: 'GitHub PR creation failed (HTTP 422)',
          details: 'A pull request already exists for this branch.',
        ),
      );

      final result = await publishWorkflowBranchWithProjectAuth(
        runId: 'run-123',
        projectId: 'workflow-testing',
        branch: 'dartclaw/workflow/run123',
        projectService: projectService,
        taskService: taskService,
        remotePushService: pushService,
        prCreator: prCreator,
      );

      expect(result.status, WorkflowPublishStatus.failed);
      expect(result.prUrl, isEmpty);
      expect(result.error, contains('GitHub PR creation failed (HTTP 422)'));
      final artifacts = await taskService.listArtifacts('task-1');
      expect(artifacts, hasLength(1));
      expect(artifacts.single.kind, ArtifactKind.branch);
      expect(artifacts.single.path, 'dartclaw/workflow/run123');
    });
  });
}
