import 'dart:async';
import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
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

Future<void> _resumeReviewedCandidate(WorkflowService service, WorkflowRun held) => service.resume(
  held.id,
  resolver: const WorkflowApprovalResolver(source: WorkflowApprovalSource.web),
  executionSurfaceCandidate: WorkflowExecutionSurfaceHold.read(held.contextJson)!.candidate,
);

Future<WorkflowApprovalExpectation> _approvalButton(WorkflowService service, WorkflowRun held) async {
  final stepId = held.contextJson['_approval.pending.stepId'] as String;
  final interaction = (await service.issueApprovalInteraction(
    held.id,
    stepId,
    executionSurfaceCandidate: WorkflowExecutionSurfaceHold.read(held.contextJson)!.candidate,
  ))!;
  const post = WorkflowApprovalPost(channelType: 'slack', recipientId: 'C1', messageId: '1.0');
  expect(await service.bindApprovalPost(held.id, nonce: interaction.nonce, post: post), isTrue);
  return WorkflowApprovalExpectation(
    stepId: stepId,
    nonce: interaction.nonce,
    channelType: post.channelType,
    messageId: post.messageId,
  );
}

Matcher _refusedWith(WorkflowApprovalRefusal reason) =>
    isA<WorkflowApprovalRefused>().having((error) => error.reason, 'reason', reason);

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
      if (!foreach && policy == 'auto') {
        fixture.writeUncommittedIntegrationFiles({'.vscode/settings.json': '{}'});
      }
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
              approvedCandidate: workflowApprovedCandidate((await h.repository.getById(runId))!.contextJson),
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
          throwsA(_refusedWith(WorkflowApprovalRefusal.personRequired)),
        );
      }
      expect((await h.repository.getById(run.id))!.status, WorkflowRunStatus.awaitingApproval);
      final initialHold = WorkflowExecutionSurfaceHold.read(held.contextJson)!;
      var initialCandidate = initialHold.candidate;
      if (!foreach && policy == 'auto') {
        expect(initialHold.worktreePath, isNotNull);
        expect(initialHold.destinationWorktreePath, isNotNull);
        expect(
          Directory(initialHold.worktreePath!).resolveSymbolicLinksSync(),
          Directory(fixture.worktreeFor('one')).resolveSymbolicLinksSync(),
        );
        expect(
          Directory(initialHold.destinationWorktreePath!).resolveSymbolicLinksSync(),
          Directory(fixture.projectDir).resolveSymbolicLinksSync(),
        );
        expect(held.errorMessage, contains('Destination worktree ${initialHold.destinationWorktreePath}.'));
        expect(held.errorMessage, contains('.vscode/settings.json'));
        // An issued, unconsumed button must not outlive the hold it was issued for.
        final unconsumedButton = await _approvalButton(service, held);
        held = (await h.repository.getById(run.id))!;
        expect(WorkflowApprovalInteraction.of(held)?.nonce, unconsumedButton.nonce);
        // Simulate restart after the task checkpoint landed but before the
        // executor recorded the pending approval.
        final checkpoint = Map<String, dynamic>.of(held.contextJson)
          ..remove(workflowExecutionSurfaceHoldKey)
          ..remove('_approval.pending.stepId')
          ..remove('_approval.pending.stepIndex');
        await h.repository.update(held.copyWith(status: WorkflowRunStatus.running, contextJson: checkpoint));
        await service.recoverIncompleteRuns();
        await waitForExecutionSurfaceStatus(h, WorkflowRunStatus.awaitingApproval);
        held = (await h.repository.getById(run.id))!;
        expect(WorkflowExecutionSurfaceHold.read(held.contextJson)!.candidate, initialCandidate);
        expect(WorkflowApprovalInteraction.of(held), isNull);
        await expectLater(
          service.resume(
            run.id,
            resolver: const WorkflowApprovalResolver(source: WorkflowApprovalSource.button),
            expect: unconsumedButton,
          ),
          throwsA(_refusedWith(WorkflowApprovalRefusal.invalidNonce)),
        );
      }
      if (!foreach && policy == 'manual') {
        final staleButton = await _approvalButton(service, held);
        fixture.writeUncommittedStoryFiles('one', {'.mcp.json': '{"updated":true}'});
        await _resumeReviewedCandidate(service, held);
        await waitForExecutionSurfaceStatus(h, WorkflowRunStatus.awaitingApproval);
        held = (await h.repository.getById(run.id))!;
        final newHold = WorkflowExecutionSurfaceHold.read(held.contextJson)!;
        expect(newHold.paths, ['.mcp.json']);
        expect(newHold.candidate, isNot(initialCandidate));
        expect(workflowApprovedCandidate(held.contextJson), isNull);
        expect(await fixture.branchSha(fixture.integrationBranch), before);
        expect(
          await service.issueApprovalInteraction(
            run.id,
            staleButton.stepId,
            executionSurfaceCandidate: initialCandidate,
          ),
          isNull,
        );
        await expectLater(
          service.resume(
            run.id,
            resolver: const WorkflowApprovalResolver(source: WorkflowApprovalSource.web),
            executionSurfaceCandidate: initialCandidate,
          ),
          throwsA(_refusedWith(WorkflowApprovalRefusal.invalidNonce)),
        );
        await expectLater(
          service.resume(
            run.id,
            resolver: const WorkflowApprovalResolver(source: WorkflowApprovalSource.button),
            expect: staleButton,
          ),
          throwsA(_refusedWith(WorkflowApprovalRefusal.invalidNonce)),
        );
        initialCandidate = newHold.candidate;
      }
      await _resumeReviewedCandidate(service, held);
      await waitForExecutionSurfaceStatus(
        h,
        foreach ? WorkflowRunStatus.awaitingApproval : WorkflowRunStatus.completed,
      );
      held = (await h.repository.getById(run.id))!;
      if (foreach) {
        expect(held.errorMessage, contains('.envrc'));
        final nextHold = WorkflowExecutionSurfaceHold.read(held.contextJson)!;
        expect(nextHold.branch, fixture.storyBranch('two'));
        expect(nextHold.candidate, isNot(initialCandidate));
        expect(workflowApprovedCandidate(held.contextJson), isNull);
        expect(tasksCreated, 2);
        await service.resume(
          run.id,
          resolver: const WorkflowApprovalResolver(source: WorkflowApprovalSource.button),
          expect: await _approvalButton(service, held),
        );
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
              final approvedCandidate = workflowApprovedCandidate((await h.repository.getById(runId))!.contextJson);
              if (!remotePush) {
                return publishWorkflowBranchLocally(
                  projectDir: fixture.projectDir,
                  branch: branch,
                  baseRef: 'origin/main',
                  approvedCandidate: approvedCandidate,
                );
              }
              return publishWorkflowBranchWithRemotePush(
                projectDir: fixture.projectDir,
                branch: branch,
                baseRef: 'origin/main',
                approvedCandidate: approvedCandidate,
                pushBranch: (revision) async {
                  pushes++;
                  expect((await fixture.rawGit(['push', 'origin', '$revision:refs/heads/$branch'])).exitCode, 0);
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
            throwsA(_refusedWith(WorkflowApprovalRefusal.personRequired)),
          );
          await expectLater(
            service.resume(run.id, resolver: const WorkflowApprovalResolver(source: WorkflowApprovalSource.web)),
            throwsA(_refusedWith(WorkflowApprovalRefusal.invalidNonce)),
          );
          await _resumeReviewedCandidate(service, held);
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
