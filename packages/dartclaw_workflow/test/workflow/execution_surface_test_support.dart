import 'dart:async';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_output_contract.dart';
import 'package:test/test.dart';

import 'component/workflow_git_test_support.dart';
import 'workflow_executor_test_support.dart';

Future<void> waitForExecutionSurfaceStatus(WorkflowExecutorHarness h, WorkflowRunStatus status) async {
  for (var i = 0; i < 300; i++) {
    final run = await h.repository.getById('run-1');
    if (run?.status == status) return;
    if (run?.status == WorkflowRunStatus.failed) fail(run?.errorMessage ?? 'Run failed');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Expected $status, found ${(await h.repository.getById('run-1'))?.toJson()}');
}

WorkflowService executionSurfaceService(WorkflowExecutorHarness h, WorkflowTurnAdapter adapter) => WorkflowService(
  repository: h.repository,
  taskService: h.taskService,
  messageService: h.messageService,
  eventBus: h.eventBus,
  kvService: h.kvService,
  dataDir: h.tempDir.path,
  turnAdapter: adapter,
  persistencePorts: WorkflowPersistencePorts(
    taskRepository: h.taskRepository,
    agentExecutionRepository: h.agentExecutionRepository,
    workflowStepExecutionRepository: h.workflowStepExecutionRepository,
    executionRepositoryTransactor: h.executionRepositoryTransactor,
  ),
);

void executionSurfacePromotionTests({required bool foreach}) {
  for (final policy in ['manual', 'auto']) {
    test('execution-surface hold and execution-surface approval ($policy)', () async {
      final h = WorkflowExecutorHarness();
      await h.setUp();
      addTearDown(h.tearDown);
      final fixture = await WorkflowGitFixture.create();
      addTearDown(fixture.dispose);
      await fixture.createStoryBranch('one', committedFiles: {'.mcp.json': '{}'});
      if (foreach) await fixture.createStoryBranch('two', committedFiles: {'.envrc': 'export X=1'});
      final before = await fixture.branchSha(fixture.integrationBranch);
      final adapter = standardTurnAdapter(
        integrationBranch: fixture.integrationBranch,
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async => promoteWorkflowBranchLocally(
              projectDir: fixture.projectDir,
              runId: runId,
              branch: branch,
              integrationBranch: integrationBranch,
              strategy: strategy,
              approved: workflowBranchIsApproved((await h.repository.getById(runId))!.contextJson, branch),
            ),
      );
      final definition = WorkflowDefinition(
        name: 'surface',
        description: 'Surface proof',
        project: '{{PROJECT}}',
        gitStrategy: const WorkflowGitStrategy(
          integrationBranch: true,
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.perMapItem),
          promotion: 'merge',
        ),
        steps: [
          if (foreach)
            const WorkflowStep(
              id: 'stories',
              name: 'Stories',
              taskType: WorkflowTaskType.foreach,
              mapOver: 'items',
              maxParallel: 1,
              foreachSteps: ['implement'],
            ),
          const WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement']),
        ],
      );
      final context = WorkflowContext(
        variables: {'PROJECT': 'project', 'BRANCH': fixture.integrationBranch},
        data: {
          if (foreach) 'items': ['one', 'two'],
        },
      );
      final run = h
          .makeRun(definition)
          .copyWith(
            contextJson: {'_workflow.approvals': policy, ...context.toJson()},
            variablesJson: context.variables,
          );
      await h.repository.insert(run);
      var tasksCreated = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen(
        (event) async {
          final story = tasksCreated++ == 0 ? 'one' : 'two';
          await h.taskService.updateFields(
            event.taskId,
            worktreeJson: {
              'path': fixture.worktreeFor(story),
              'branch': fixture.storyBranch(story),
              'createdAt': DateTime.now().toIso8601String(),
            },
          );
          await h.completeTaskWithOutcome(event.taskId, outcome: 'succeeded', reason: 'done');
        },
      );
      addTearDown(sub.cancel);
      await h.makeExecutor(turnAdapter: adapter).execute(run, definition, context);
      var held = (await h.repository.getById(run.id))!;
      expect(held.status, WorkflowRunStatus.awaitingApproval);
      expect(held.errorMessage, contains('.mcp.json'));
      expect(await fixture.branchSha(fixture.integrationBranch), before);
      expect(tasksCreated, 1);
      if (foreach) expect(held.executionCursor?.completedSubStepIdsByIndex[0], contains('implement'));
      final service = executionSurfaceService(h, adapter);
      addTearDown(service.dispose);
      for (final resolver in [null, const WorkflowApprovalResolver(source: WorkflowApprovalSource.tool)]) {
        await expectLater(
          service.resume(run.id, resolver: resolver),
          throwsA(
            isA<WorkflowApprovalRefused>().having(
              (error) => error.reason,
              'reason',
              WorkflowApprovalRefusal.personRequired,
            ),
          ),
        );
      }
      expect((await h.repository.getById(run.id))!.status, WorkflowRunStatus.awaitingApproval);
      await service.resume(run.id, resolver: const WorkflowApprovalResolver(source: WorkflowApprovalSource.web));
      await waitForExecutionSurfaceStatus(
        h,
        foreach ? WorkflowRunStatus.awaitingApproval : WorkflowRunStatus.completed,
      );
      held = (await h.repository.getById(run.id))!;
      if (foreach) {
        expect(held.errorMessage, contains('.envrc'));
        expect((held.contextJson['data'] as Map)[workflowApprovedBranchesKey], [fixture.storyBranch('one')]);
        expect(tasksCreated, 2);
        await service.resume(run.id, resolver: const WorkflowApprovalResolver(source: WorkflowApprovalSource.button));
        await waitForExecutionSurfaceStatus(h, WorkflowRunStatus.completed);
      }
      expect(tasksCreated, foreach ? 2 : 1, reason: 'resume must retry promotion without executing settled tasks');
      final tree = await fixture.rawGit(['ls-tree', '-r', '--name-only', fixture.integrationBranch]);
      expect(tree.stdout, contains('.mcp.json'));
      if (foreach) expect(tree.stdout, contains('.envrc'));
    });
  }
}

void executionSurfacePublishTests() {
  for (final policy in ['manual', 'auto']) {
    for (final remotePush in [false, true]) {
      test(
        'execution-surface publish hold and execution-surface publish approval ($policy, remotePush=$remotePush)',
        () async {
          final h = WorkflowExecutorHarness();
          await h.setUp();
          addTearDown(h.tearDown);
          final fixture = await WorkflowGitFixture.create();
          addTearDown(fixture.dispose);
          final remote = '${fixture.tempRoot.path}/remote.git';
          expect((await fixture.rawGit(['init', '--bare', remote])).exitCode, 0);
          expect((await fixture.rawGit(['remote', 'add', 'origin', remote])).exitCode, 0);
          expect((await fixture.rawGit(['push', 'origin', 'HEAD:main'])).exitCode, 0);
          fixture.writeUncommittedIntegrationFiles({'.mcp.json': '{}'});
          final before = await fixture.branchSha(fixture.integrationBranch);
          var pushes = 0;
          final adapter = standardTurnAdapter(
            integrationBranch: fixture.integrationBranch,
            publishWorkflowBranch: ({required runId, required projectId, required branch, pullRequest}) async {
              final approved = workflowBranchIsApproved((await h.repository.getById(runId))!.contextJson, branch);
              if (!remotePush) {
                return publishWorkflowBranchLocally(
                  projectDir: fixture.projectDir,
                  branch: branch,
                  baseRef: 'origin/main',
                  approved: approved,
                );
              }
              return publishWorkflowBranchWithRemotePush(
                projectDir: fixture.projectDir,
                branch: branch,
                baseRef: 'origin/main',
                approved: approved,
                pushBranch: () async {
                  pushes++;
                  expect((await fixture.rawGit(['push', 'origin', branch])).exitCode, 0);
                  return const PushSuccess();
                },
                fetchRemoteTrackingRef: () =>
                    fixture.rawGit(['fetch', 'origin', 'refs/heads/$branch:refs/remotes/origin/$branch']),
              );
            },
          );
          final definition = WorkflowDefinition(
            name: 'surface-publish',
            description: 'Publish proof',
            gitStrategy: const WorkflowGitStrategy(publish: true),
            steps: const [
              WorkflowStep(id: 'prepare', name: 'Prepare', taskType: WorkflowTaskType.bash, prompts: ['true']),
            ],
          );
          final context = WorkflowContext(variables: {'PROJECT': 'project', 'BRANCH': fixture.integrationBranch});
          final run = h
              .makeRun(definition)
              .copyWith(
                contextJson: {'_workflow.approvals': policy, ...context.toJson()},
                variablesJson: context.variables,
              );
          await h.repository.insert(run);
          await h.makeExecutor(turnAdapter: adapter).execute(run, definition, context);
          final held = (await h.repository.getById(run.id))!;
          expect(held.status, WorkflowRunStatus.awaitingApproval);
          expect(held.errorMessage, contains('.mcp.json'));
          expect(held.contextJson['_approval.pending.stepId'], 'prepare');
          expect(held.currentStepIndex, definition.steps.length);
          expect(await fixture.branchSha(fixture.integrationBranch), before);
          expect(
            (await fixture.rawGit(['ls-remote', 'origin', 'refs/heads/${fixture.integrationBranch}'])).stdout,
            isEmpty,
          );
          expect(pushes, 0);
          final service = executionSurfaceService(h, adapter);
          addTearDown(service.dispose);
          await expectLater(
            service.resume(run.id, resolver: const WorkflowApprovalResolver(source: WorkflowApprovalSource.tool)),
            throwsA(
              isA<WorkflowApprovalRefused>().having(
                (error) => error.reason,
                'reason',
                WorkflowApprovalRefusal.personRequired,
              ),
            ),
          );
          await service.resume(run.id, resolver: const WorkflowApprovalResolver(source: WorkflowApprovalSource.web));
          await waitForExecutionSurfaceStatus(h, WorkflowRunStatus.completed);
          final pushedTree = await fixture.rawGit([
            'ls-tree',
            '-r',
            '--name-only',
            'origin/${fixture.integrationBranch}',
          ]);
          expect(pushedTree.stdout, contains('.mcp.json'));
          expect((await h.repository.getById(run.id))!.contextJson['data'], containsPair('publish.status', 'success'));
          expect(pushes, remotePush ? 1 : 0);
        },
      );
    }
  }
}
