@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        EventBus,
        WorkflowApprovalExpectation,
        WorkflowApprovalInteraction,
        WorkflowApprovalPost,
        WorkflowApprovalRefusal,
        WorkflowApprovalRefused,
        WorkflowApprovalResolvedEvent,
        WorkflowApprovalResolver,
        WorkflowApprovalSource,
        WorkflowRun,
        WorkflowService,
        WorkflowStep,
        WorkflowTaskType;
import 'package:dartclaw_workflow/src/workflow/approval_step_runner.dart'
    show ApprovalStepDependencies, executeApprovalStep;
import 'package:dartclaw_workflow/src/workflow/workflow_context.dart' show WorkflowContext, privateContextEntries;
import 'package:dartclaw_workflow/src/workflow/workflow_template_engine.dart' show WorkflowTemplateEngine;
import 'package:dartclaw_workflow/testing.dart' show InMemoryWorkflowRunRepository;
import 'package:test/test.dart';

import 'workflow_service_test_support.dart';

const _post = WorkflowApprovalPost(channelType: 'slack', recipientId: 'C1', messageId: '1700.01');
const _resolver = WorkflowApprovalResolver(
  source: WorkflowApprovalSource.button,
  senderId: 'U-ADMIN',
  displayName: 'Ada',
);

void main() {
  late WorkflowServiceTestHarness harness;
  late WorkflowService service;
  late List<WorkflowApprovalResolvedEvent> resolvedEvents;

  setUp(() async {
    harness = WorkflowServiceTestHarness();
    await harness.setUp();
    service = harness.lifecycleOnlyService();
    resolvedEvents = [];
    harness.eventBus.on<WorkflowApprovalResolvedEvent>().listen(resolvedEvents.add);
  });

  tearDown(() async {
    await harness.tearDown(currentService: service);
  });

  Future<WorkflowRun> pendingRun(String id, {String stepId = 'gate', WorkflowRunStatus? status}) {
    final definition = harness.makeDefinition(
      steps: [
        WorkflowStep(id: stepId, name: 'Gate', taskType: WorkflowTaskType.approval, prompts: const ['Approve?']),
      ],
    );
    return harness.insertRun(
      id: id,
      definition: definition,
      status: status ?? WorkflowRunStatus.awaitingApproval,
      currentStepIndex: 1,
      contextJson: {
        '_approval.pending.stepId': stepId,
        '_approval.pending.stepIndex': 0,
        '$stepId.approval.status': 'pending',
        'data': <String, dynamic>{},
        'variables': <String, dynamic>{},
      },
      writeContextFile: true,
    );
  }

  Future<WorkflowApprovalInteraction> issuedAndBound(String runId, {String stepId = 'gate'}) async {
    final interaction = (await service.issueApprovalInteraction(runId, stepId))!;
    expect(await service.bindApprovalPost(runId, nonce: interaction.nonce, post: _post), isTrue);
    return interaction;
  }

  WorkflowApprovalExpectation expectation(WorkflowApprovalInteraction interaction, {String? nonce, String? stepId}) =>
      WorkflowApprovalExpectation(
        stepId: stepId ?? interaction.stepId,
        nonce: nonce ?? interaction.nonce,
        channelType: _post.channelType,
        messageId: _post.messageId,
      );

  Future<WorkflowApprovalInteraction?> storedInteraction(String runId) async =>
      WorkflowApprovalInteraction.of((await harness.repository.getById(runId))!);

  Matcher refusedWith(WorkflowApprovalRefusal reason) =>
      isA<WorkflowApprovalRefused>().having((e) => e.reason, 'reason', reason);

  group('approval interaction issue', () {
    test('a pending approval gets a 128-bit hex nonce and a run-context record', () async {
      await pendingRun('run-1');

      final interaction = (await service.issueApprovalInteraction('run-1', 'gate'))!;

      expect(interaction.nonce, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(interaction.stepId, 'gate');
      expect(interaction.post, isNull);
      expect((await storedInteraction('run-1'))?.nonce, interaction.nonce);
    });

    test('every issue draws a fresh nonce and the later one replaces the earlier', () async {
      await pendingRun('run-1');

      final first = (await service.issueApprovalInteraction('run-1', 'gate'))!;
      final second = (await service.issueApprovalInteraction('run-1', 'gate'))!;

      expect(second.nonce, isNot(first.nonce));
      expect((await storedInteraction('run-1'))?.nonce, second.nonce);
      expect(await service.bindApprovalPost('run-1', nonce: first.nonce, post: _post), isFalse);
    });

    test('a run not pending at the asked step, or not held at all, gets none', () async {
      await pendingRun('run-held');
      await pendingRun('run-running', status: WorkflowRunStatus.running);

      expect(await service.issueApprovalInteraction('run-held', 'other-step'), isNull);
      expect(await service.issueApprovalInteraction('run-running', 'gate'), isNull);
      expect(await service.issueApprovalInteraction('no-such-run', 'gate'), isNull);
      expect(await storedInteraction('run-held'), isNull);
    });

    test('an approval the policy auto-resolved leaves nothing pending to issue for', () async {
      await harness.insertRun(
        id: 'run-auto',
        status: WorkflowRunStatus.running,
        contextJson: {
          'gate.approval.status': 'approved',
          '_approval.auto_resolved.gate': {'policy': 'auto'},
          'data': <String, dynamic>{},
          'variables': <String, dynamic>{},
        },
      );

      expect(await service.issueApprovalInteraction('run-auto', 'gate'), isNull);
    });

    test('the record survives a fresh service over the same repository', () async {
      await pendingRun('run-1');
      final interaction = await issuedAndBound('run-1');

      final restarted = harness.lifecycleOnlyService();
      addTearDown(restarted.dispose);

      await restarted.resume('run-1', expect: expectation(interaction), resolver: _resolver);

      expect(resolvedEvents.single.approved, isTrue);
    });

    test('the record survives the context rebuild of a later approval hold', () async {
      final run = await pendingRun('run-1');
      final interaction = await issuedAndBound('run-1');
      final stored = (await harness.repository.getById(run.id))!;
      final held = stored.copyWith(status: WorkflowRunStatus.running);
      await harness.repository.update(held);
      final step = const WorkflowStep(id: 'next', name: 'Next', taskType: WorkflowTaskType.approval, prompts: ['Go?']);

      await executeApprovalStep(
        run: held,
        step: step,
        context: WorkflowContext(),
        stepIndex: 1,
        templateEngine: WorkflowTemplateEngine(),
        dependencies: ApprovalStepDependencies(
          eventBus: EventBus(),
          repository: harness.repository,
          persistContext: (_, _) async {},
          cancelRun: (_, _) async {},
          approvalTimers: <String, Timer>{},
        ),
      );

      expect(privateContextEntries(held.contextJson), contains('_approval.interaction'));
      expect((await storedInteraction('run-1'))?.nonce, interaction.nonce);
    });

    test('binding needs the live nonce and is refused once the approval is resolved', () async {
      await pendingRun('run-1');
      final interaction = (await service.issueApprovalInteraction('run-1', 'gate'))!;

      expect(await service.bindApprovalPost('run-1', nonce: '0' * 32, post: _post), isFalse);
      expect(await service.bindApprovalPost('run-1', nonce: interaction.nonce, post: _post), isTrue);
      expect((await storedInteraction('run-1'))?.post?.messageId, _post.messageId);

      await service.resume('run-1', resolver: _resolver);

      expect(await service.bindApprovalPost('run-1', nonce: interaction.nonce, post: _post), isFalse);
    });
  });

  group('approval interaction resolve', () {
    test('a matching expectation resumes the run once and consumes the record with its resolver', () async {
      await pendingRun('run-1');
      final interaction = await issuedAndBound('run-1');

      final resumed = await service.resume('run-1', expect: expectation(interaction), resolver: _resolver);

      expect(resumed.status, WorkflowRunStatus.running);
      expect(resolvedEvents, hasLength(1));
      final resolution = (await storedInteraction('run-1'))!.resolution!;
      expect(resolution.approved, isTrue);
      expect(resolution.source, WorkflowApprovalSource.button);
      expect(resolution.senderId, 'U-ADMIN');
      expect(resolution.displayName, 'Ada');
    });

    test('a rejecting expectation cancels the run, records the reject and carries no feedback', () async {
      await pendingRun('run-1');
      final interaction = await issuedAndBound('run-1');

      await service.cancel('run-1', expect: expectation(interaction), resolver: _resolver);

      final run = (await harness.repository.getById('run-1'))!;
      expect(run.status, WorkflowRunStatus.cancelled);
      expect(run.contextJson['gate.approval.status'], 'rejected');
      expect(run.contextJson.containsKey('gate.approval.feedback'), isFalse);
      expect(resolvedEvents.single.approved, isFalse);
      expect((await storedInteraction('run-1'))!.resolution!.approved, isFalse);
    });

    test('each refusal reason names itself and leaves the run and record untouched', () async {
      await pendingRun('run-1');
      await pendingRun('run-2');
      final interaction = await issuedAndBound('run-1');
      final otherRunInteraction = await issuedAndBound('run-2');
      final unbound = (await service.issueApprovalInteraction('run-3-missing', 'gate'));
      expect(unbound, isNull);

      final cases = <(String, WorkflowApprovalExpectation)>[
        ('a random nonce', expectation(interaction, nonce: 'f' * 32)),
        ('another run\'s nonce', expectation(interaction, nonce: otherRunInteraction.nonce)),
        ('the nonce with another step', expectation(interaction, stepId: 'other')),
        (
          'the nonce from a different post',
          WorkflowApprovalExpectation(
            stepId: 'gate',
            nonce: interaction.nonce,
            channelType: 'slack',
            messageId: 'another-message',
          ),
        ),
      ];
      for (final (label, expect) in cases) {
        await expectLater(
          service.resume('run-1', expect: expect, resolver: _resolver),
          throwsA(refusedWith(WorkflowApprovalRefusal.invalidNonce)),
          reason: label,
        );
      }

      final run = (await harness.repository.getById('run-1'))!;
      expect(run.status, WorkflowRunStatus.awaitingApproval);
      expect((await storedInteraction('run-1'))!.isResolved, isFalse);
      expect(resolvedEvents, isEmpty);
    });

    test('a post not yet bound cannot resolve, and a bound one can once', () async {
      await pendingRun('run-1');
      final interaction = (await service.issueApprovalInteraction('run-1', 'gate'))!;

      await expectLater(
        service.resume('run-1', expect: expectation(interaction), resolver: _resolver),
        throwsA(refusedWith(WorkflowApprovalRefusal.invalidNonce)),
      );

      await service.bindApprovalPost('run-1', nonce: interaction.nonce, post: _post);
      await service.resume('run-1', expect: expectation(interaction), resolver: _resolver);
    });

    test('a second click after the first is already resolved, never a StateError', () async {
      await pendingRun('run-1');
      final interaction = await issuedAndBound('run-1');
      await service.resume('run-1', expect: expectation(interaction), resolver: _resolver);

      await expectLater(
        service.resume('run-1', expect: expectation(interaction), resolver: _resolver),
        throwsA(refusedWith(WorkflowApprovalRefusal.alreadyResolved)),
      );
      await expectLater(
        service.cancel('run-1', expect: expectation(interaction), resolver: _resolver),
        throwsA(refusedWith(WorkflowApprovalRefusal.alreadyResolved)),
      );
      expect(resolvedEvents, hasLength(1));
    });

    test('a click after a web cancel is already resolved, and a forged one is still invalid', () async {
      await pendingRun('run-1');
      final interaction = await issuedAndBound('run-1');
      await service.cancel(
        'run-1',
        feedback: 'no',
        resolver: const WorkflowApprovalResolver(source: WorkflowApprovalSource.web),
      );

      await expectLater(
        service.resume('run-1', expect: expectation(interaction), resolver: _resolver),
        throwsA(refusedWith(WorkflowApprovalRefusal.alreadyResolved)),
      );
      await expectLater(
        service.resume(
          'run-1',
          expect: expectation(interaction, nonce: 'a' * 32),
          resolver: _resolver,
        ),
        throwsA(refusedWith(WorkflowApprovalRefusal.invalidNonce)),
      );
      expect((await storedInteraction('run-1'))!.resolution!.source, WorkflowApprovalSource.web);
    });

    test('a run that ended unresolved is not pending', () async {
      await pendingRun('run-1');
      final interaction = await issuedAndBound('run-1');
      final held = (await harness.repository.getById('run-1'))!;
      await harness.repository.update(held.copyWith(status: WorkflowRunStatus.cancelled, completedAt: DateTime.now()));

      await expectLater(
        service.resume('run-1', expect: expectation(interaction), resolver: _resolver),
        throwsA(refusedWith(WorkflowApprovalRefusal.notPending)),
      );
    });

    test('a resolver without an expectation records itself and refuses an unresumable run by type', () async {
      await pendingRun('run-1');
      await issuedAndBound('run-1');

      await service.resume('run-1', resolver: _resolver);

      expect((await storedInteraction('run-1'))!.resolution!.senderId, 'U-ADMIN');
      await expectLater(
        service.resume('run-1', resolver: _resolver),
        throwsA(refusedWith(WorkflowApprovalRefusal.alreadyResolved)),
      );
    });

    test('a caller naming neither resolver nor expectation keeps the unattributed behaviour', () async {
      await pendingRun('run-1', status: WorkflowRunStatus.running);
      await pendingRun('run-2');
      await issuedAndBound('run-2');

      await expectLater(service.resume('run-1'), throwsA(isA<StateError>()));
      await service.resume('run-2');

      final resolution = (await storedInteraction('run-2'))!.resolution!;
      expect(resolution.source, isNull);
      expect(resolution.senderId, isNull);
    });

    test('a failing update leaves the nonce live so the same click works once the fault clears', () async {
      await pendingRun('run-1');
      final interaction = await issuedAndBound('run-1');

      (harness.repository as InMemoryWorkflowRunRepository).failNextUpdate = true;
      await expectLater(
        service.resume('run-1', expect: expectation(interaction), resolver: _resolver),
        throwsA(isA<StateError>()),
      );

      expect((await storedInteraction('run-1'))!.isResolved, isFalse);
      expect((await harness.repository.getById('run-1'))!.status, WorkflowRunStatus.awaitingApproval);
      expect(resolvedEvents, isEmpty);

      await service.resume('run-1', expect: expectation(interaction), resolver: _resolver);

      expect(resolvedEvents, hasLength(1));
    });

    test('five resolvers arriving together yield exactly one resolved event and one resume', () async {
      await pendingRun('run-1');
      final interaction = await issuedAndBound('run-1');

      final outcomes = await Future.wait([
        for (var i = 0; i < 2; i++)
          service
              .resume('run-1', expect: expectation(interaction), resolver: _resolver)
              .then<Object>((run) => run, onError: (Object e) => e),
        service.resume('run-1', resolver: _resolver).then<Object>((run) => run, onError: (Object e) => e),
        service.resume('run-1').then<Object>((run) => run, onError: (Object e) => e),
        service
            .cancel('run-1', expect: expectation(interaction), resolver: _resolver)
            .then<Object>((_) => 'cancelled', onError: (Object e) => e),
      ]);

      expect(outcomes.whereType<WorkflowRun>(), hasLength(1));
      expect(resolvedEvents, hasLength(1));
      // Every attributed loser is refused as already resolved; only the caller
      // naming no resolver keeps the StateError the HTTP route maps to 409.
      expect(
        outcomes.whereType<WorkflowApprovalRefused>().map((e) => e.reason),
        everyElement(WorkflowApprovalRefusal.alreadyResolved),
      );
      expect(outcomes.whereType<WorkflowApprovalRefused>(), hasLength(3));
      expect(outcomes.whereType<StateError>(), hasLength(1));
    });
  });
}
