// WorkflowExecutor publish recovery: publish failure preservation, publish
// boundary matrix (missing callback/vars/branch, failure, exception), and
// awaitingApproval hold preserves worktree and context evidence.
@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_models/dartclaw_models.dart' show SessionType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowApprovalRequestedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowGitException,
        WorkflowGitPublishResult,
        WorkflowGitPublishStrategy,
        WorkflowGitStrategy,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome,
        WorkflowVariable,
        WorkflowWorktreeBinding,
        SessionService;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  group('publish failure preserves inspectable recovery state', () {
    // RESTART-IDEMPOTENCY / FR3-AC2: publish failure must not destroy worktree/branch/artifact
    // evidence. The run transitions to failed (not completed), so _cleanupWorkflowGit is not
    // invoked — the run, its context, and any bound worktrees remain readable for recovery.

    test('publish failure transitions run to failed without cleanup of worktree evidence', () async {
      final cleanupCalls = <({bool preserveWorktrees})>[];
      final publishExecutor = h.makeExecutor(
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('turn-1'),
          executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
          waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
          publishWorkflowBranch: ({required runId, required projectId, required branch}) async =>
              throw const WorkflowGitException('push failed: remote rejected'),
          cleanupWorkflowGit:
              ({required runId, required projectId, required status, required preserveWorktrees}) async {
                cleanupCalls.add((preserveWorktrees: preserveWorktrees));
              },
        ),
      );

      final definition = WorkflowDefinition(
        name: 'publish-fail',
        description: 'Publish failure preservation test',
        gitStrategy: const WorkflowGitStrategy(publish: WorkflowGitPublishStrategy(enabled: true)),
        steps: const [],
        variables: {'PROJECT': const WorkflowVariable(required: false)},
      );

      final run = WorkflowRun(
        id: 'publish-fail-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'},
        definitionJson: definition.toJson(),
        workflowWorktree: const WorkflowWorktreeBinding(
          key: 'publish-fail-run',
          path: '/tmp/worktrees/wf-publish-fail',
          branch: 'dartclaw/workflow/publish-fail/integration',
          workflowRunId: 'publish-fail-run',
        ),
      );
      await h.repository.insert(run);

      await publishExecutor.execute(
        run,
        definition,
        WorkflowContext(variables: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'}),
      );

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('push failed'));
      expect(cleanupCalls, isEmpty, reason: 'worktree/artifact evidence must not be cleaned up on publish failure');
    });

    test('publish failure run retains its run id, error message, and inspectable context', () async {
      final publishExecutor = h.makeExecutor(
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('turn-1'),
          executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
          waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
          publishWorkflowBranch: ({required runId, required projectId, required branch}) async =>
              throw const WorkflowGitException('network unreachable'),
        ),
      );

      final definition = WorkflowDefinition(
        name: 'publish-fail-context',
        description: 'Publish failure context preservation',
        gitStrategy: const WorkflowGitStrategy(publish: WorkflowGitPublishStrategy(enabled: true)),
        steps: const [],
        variables: {'PROJECT': const WorkflowVariable(required: false)},
      );

      final run = WorkflowRun(
        id: 'publish-fail-ctx-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'},
        definitionJson: definition.toJson(),
        contextJson: const {
          'prior-step.status': 'accepted',
          'step.prior-step.outcome': 'succeeded',
          'data': <String, dynamic>{'prior-step.status': 'accepted', 'step.prior-step.outcome': 'succeeded'},
          'variables': <String, dynamic>{},
        },
      );
      await h.repository.insert(run);

      await publishExecutor.execute(
        run,
        definition,
        WorkflowContext(variables: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'}),
      );

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.id, equals('publish-fail-ctx-run'));
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('network unreachable'));
    });
  });

  group('publish boundary matrix', () {
    WorkflowDefinition makePublishDef({String? id}) => WorkflowDefinition(
      name: id ?? 'publish-boundary',
      description: 'Publish boundary test',
      gitStrategy: const WorkflowGitStrategy(publish: WorkflowGitPublishStrategy(enabled: true)),
      steps: const [],
      variables: {'PROJECT': const WorkflowVariable(required: false)},
    );

    Future<WorkflowRun?> runPublish({
      required WorkflowTurnAdapter adapter,
      required Map<String, String> variables,
      String? defId,
    }) async {
      final def = makePublishDef(id: defId);
      final id = 'pb-${defId ?? 'run'}-${DateTime.now().microsecondsSinceEpoch}';
      final run = WorkflowRun(
        id: id,
        definitionName: def.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: variables,
        definitionJson: def.toJson(),
      );
      await h.repository.insert(run);
      final publishExecutor = h.makeExecutor(turnAdapter: adapter);
      await publishExecutor.execute(run, def, WorkflowContext(variables: variables));
      return h.repository.getById(id);
    }

    final baseAdapter = WorkflowTurnAdapter(
      reserveTurn: (_) => Future.value('turn-1'),
      executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
      waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
    );

    test('missing publishWorkflowBranch callback marks run failed', () async {
      final finalRun = await runPublish(
        adapter: baseAdapter,
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'},
        defId: 'no-callback',
      );
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('publish callback'));
    });

    test('missing PROJECT marks run failed', () async {
      final finalRun = await runPublish(
        adapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('t'),
          executeTurn: (_, _, _, {required source, required resume}) {},
          waitForOutcome: (_, _) async => const WorkflowTurnOutcome(status: 'completed'),
          publishWorkflowBranch: ({required runId, required projectId, required branch}) async =>
              WorkflowGitPublishResult(status: 'success', branch: branch, remote: 'origin', prUrl: ''),
        ),
        variables: const {'BRANCH': 'feature/test'},
        defId: 'no-project',
      );
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('PROJECT'));
    });

    test('missing BRANCH marks run failed', () async {
      final finalRun = await runPublish(
        adapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('t'),
          executeTurn: (_, _, _, {required source, required resume}) {},
          waitForOutcome: (_, _) async => const WorkflowTurnOutcome(status: 'completed'),
          publishWorkflowBranch: ({required runId, required projectId, required branch}) async =>
              WorkflowGitPublishResult(status: 'success', branch: branch, remote: 'origin', prUrl: ''),
        ),
        variables: const {'PROJECT': 'my-project'},
        defId: 'no-branch',
      );
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('branch'));
    });

    test('callback returning status=failed marks run failed', () async {
      final finalRun = await runPublish(
        adapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('t'),
          executeTurn: (_, _, _, {required source, required resume}) {},
          waitForOutcome: (_, _) async => const WorkflowTurnOutcome(status: 'completed'),
          publishWorkflowBranch: ({required runId, required projectId, required branch}) async =>
              WorkflowGitPublishResult(
                status: 'failed',
                branch: branch,
                remote: 'origin',
                prUrl: '',
                error: 'remote rejected',
              ),
        ),
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'},
        defId: 'status-failed',
      );
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('remote rejected'));
    });

    test('callback throwing exception marks run failed', () async {
      final finalRun = await runPublish(
        adapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('t'),
          executeTurn: (_, _, _, {required source, required resume}) {},
          waitForOutcome: (_, _) async => const WorkflowTurnOutcome(status: 'completed'),
          publishWorkflowBranch: ({required runId, required projectId, required branch}) async =>
              throw const WorkflowGitException('network unreachable'),
        ),
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'},
        defId: 'callback-throws',
      );
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('network unreachable'));
    });
  });

  group('awaitingApproval hold preserves worktree/context evidence', () {
    // APPROVAL-HOLD / FR3-AC5: the approval hold transition does not call
    // _cleanupWorkflowGit, so worktree bindings and context are preserved.

    test('needsInput hold transitions to awaitingApproval without losing prior-step context', () async {
      final approvalRequests = <WorkflowApprovalRequestedEvent>[];
      final evSub = h.eventBus.on<WorkflowApprovalRequestedEvent>().listen(approvalRequests.add);
      final localSessionService = SessionService(baseDir: h.sessionsDir);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        if (task == null) return;
        final session = await localSessionService.createSession(type: SessionType.task);
        await h.taskService.updateFields(task.id, sessionId: session.id);
        await h.messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content:
              'Blocked pending human decision.\n'
              '<step-outcome>{"outcome":"needsInput","reason":"human decision required"}</step-outcome>',
        );
        await h.completeTask(e.taskId);
      });

      final definition = WorkflowDefinition(
        name: 'hold-preservation',
        description: 'Hold preservation test',
        steps: const [
          WorkflowStep(id: 'review-gate', name: 'Review Gate', prompts: ['Review and approve']),
        ],
      );

      final preContext = WorkflowContext(data: {'prior-impl.status': 'accepted', 'prior-impl.tokenCount': 100});

      final run = WorkflowRun(
        id: 'hold-preservation-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        definitionJson: definition.toJson(),
        contextJson: preContext.toJson(),
      );
      await h.repository.insert(run);

      await h.executor.execute(run, definition, preContext);

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await evSub.cancel();

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.awaitingApproval));
      expect(approvalRequests, hasLength(1));
      expect(approvalRequests.first.stepId, equals('review-gate'));
      final data = finalRun?.contextJson['data'] as Map?;
      expect(data?['prior-impl.status'], equals('accepted'));
      expect(data?['prior-impl.tokenCount'], equals(100));
    });
  });
}
