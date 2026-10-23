import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService;
import 'package:dartclaw_runtime/src/task/workflow_run_control.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart'
    show
        InMemoryAgentExecutionRepository,
        InMemoryExecutionRepositoryTransactor,
        InMemoryTaskRepository,
        InMemoryWorkflowStepExecutionRepository;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowApprovalInteraction,
        WorkflowApprovalPost,
        WorkflowApprovalResolver,
        WorkflowApprovalSource,
        WorkflowDefinition,
        WorkflowPersistencePorts,
        WorkflowRun,
        WorkflowService,
        WorkflowStep,
        WorkflowTaskType;
import 'package:dartclaw_workflow/testing.dart' show InMemoryWorkflowRunRepository;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../guard_audit_test_support.dart';

const _slackMessage = '1700.01';

void main() {
  late Directory tempDir;
  late EventBus eventBus;
  late TaskService tasks;
  late InMemoryWorkflowRunRepository repository;
  late WorkflowService workflows;
  late RecordingGuardAuditLogger audit;
  late List<WorkflowApprovalResolvedEvent> resolved;
  late List<LogRecord> logs;
  late StreamSubscription<LogRecord> logSubscription;
  var adminSenders = <String>[];

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_run_control_');
    eventBus = EventBus();
    tasks = TaskService(InMemoryTaskRepository(), eventBus: eventBus);
    repository = InMemoryWorkflowRunRepository();
    workflows = WorkflowService.lifecycleOnly(
      repository: repository,
      taskService: tasks,
      messageService: MessageService(baseDir: p.join(tempDir.path, 'sessions')),
      eventBus: eventBus,
      kvService: KvService(filePath: p.join(tempDir.path, 'kv.json')),
      dataDir: tempDir.path,
    );
    audit = RecordingGuardAuditLogger();
    adminSenders = [];
    resolved = [];
    eventBus.on<WorkflowApprovalResolvedEvent>().listen(resolved.add);
    logs = [];
    Logger.root.level = Level.ALL;
    logSubscription = Logger.root.onRecord.listen(logs.add);
  });

  tearDown(() async {
    await logSubscription.cancel();
    await workflows.dispose();
    await tasks.dispose();
    await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  WorkflowRunControl newControl() => WorkflowRunControl(
    workflows: workflows,
    isAdmin: GovernanceConfig(adminSenders: adminSenders).isAdmin,
    auditLogger: audit,
  );

  /// A run waiting at [stepId] whose post carries a freshly issued, bound interaction.
  Future<WorkflowApprovalInteraction> holdRun(String id, {String stepId = 'gate'}) async {
    final definition = WorkflowDefinition(
      name: 'approval-run',
      description: 'One approval gate',
      steps: [
        WorkflowStep(id: stepId, name: 'Gate', taskType: WorkflowTaskType.approval, prompts: const ['Approve?']),
      ],
    );
    final now = DateTime.now();
    await repository.insert(
      WorkflowRun(
        id: id,
        definitionName: definition.name,
        status: WorkflowRunStatus.awaitingApproval,
        startedAt: now,
        updatedAt: now,
        currentStepIndex: 1,
        definitionJson: definition.toJson(),
        contextJson: {
          '_approval.pending.stepId': stepId,
          '_approval.pending.stepIndex': 0,
          '$stepId.approval.status': 'pending',
          'data': <String, dynamic>{},
          'variables': <String, dynamic>{},
        },
      ),
    );
    final interaction = (await workflows.issueApprovalInteraction(id, stepId))!;
    await workflows.bindApprovalPost(
      id,
      nonce: interaction.nonce,
      post: const WorkflowApprovalPost(channelType: 'slack', recipientId: 'C1', messageId: _slackMessage),
    );
    return interaction;
  }

  ChannelRunApprovalRequest click(
    WorkflowApprovalInteraction interaction, {
    String runId = 'run-1',
    String sender = 'U-A',
    String? displayName = 'Ada',
    ChannelRunApprovalAction action = ChannelRunApprovalAction.approve,
    String? nonce,
    String? stepId,
    String messageId = _slackMessage,
  }) => ChannelRunApprovalRequest(
    action: action,
    runId: runId,
    stepId: stepId ?? interaction.stepId,
    nonce: nonce ?? interaction.nonce,
    senderId: sender,
    senderDisplayName: displayName,
    channelType: 'slack',
    postMessageId: messageId,
  );

  Future<WorkflowApprovalInteraction?> stored(String runId) async =>
      WorkflowApprovalInteraction.of((await repository.getById(runId))!);

  TurnProvenance chatTurn({String? sender = 'U-A', ChannelType channel = ChannelType.slack, bool delegated = false}) =>
      TurnProvenance.channel(
        channelType: channel,
        sessionKey: 'agent:main:group:${channel.name}:C1',
        recipientId: 'C1',
        senderId: sender,
        delegated: delegated,
      );

  group('buttons', () {
    test('an admin approves once and a second click is refused as already resolved', () async {
      final interaction = await holdRun('run-1');
      adminSenders = ['U-A'];

      final first = await newControl().handleApproval(click(interaction));
      final second = await newControl().handleApproval(click(interaction));

      expect(first, isA<ChannelRunApprovalResolved>());
      expect(second, isA<ChannelRunApprovalRefused>().having((r) => r.reason, 'reason', isNot(null)));
      expect((second as ChannelRunApprovalRefused).reason, ChannelRunApprovalRefusal.alreadyResolved);
      expect(resolved.single.approved, isTrue);

      expect(audit.entries, hasLength(2));
      final allow = audit.entries.first;
      expect(
        (
          allow.guard,
          allow.hook,
          allow.verdict,
          allow.decision,
          allow.channel,
          allow.peerId,
          allow.principal,
          allow.tool,
          allow.runId,
          allow.stepId,
        ),
        ('RunApprovalGate', 'button', 'pass', 'allow', 'slack', 'U-A', 'U-A', 'resume', 'run-1', 'gate'),
      );
      expect(audit.entries.last.decision, 'deny');
      expect(audit.entries.last.runId, 'run-1');
    });

    test('a reject click cancels the run with the step rejected, no feedback, and one cancel entry', () async {
      final interaction = await holdRun('run-1');

      final result = await newControl().handleApproval(click(interaction, action: ChannelRunApprovalAction.reject));

      expect(result, isA<ChannelRunApprovalResolved>());
      final run = (await repository.getById('run-1'))!;
      expect(run.status, WorkflowRunStatus.cancelled);
      expect(run.contextJson['gate.approval.status'], 'rejected');
      expect(run.contextJson.containsKey('gate.approval.feedback'), isFalse);
      expect(audit.entries.single.tool, 'cancel');
      expect(audit.entries.single.decision, 'allow');
    });

    test(
      'a non-admin is refused privately, the run is untouched, and one deny entry names sender, run, step',
      () async {
        final interaction = await holdRun('run-1');
        adminSenders = ['U-A'];

        final result = await newControl().handleApproval(click(interaction, sender: 'U-B', displayName: 'Bob'));

        expect(
          result,
          isA<ChannelRunApprovalRefused>()
              .having((r) => r.reason, 'reason', ChannelRunApprovalRefusal.notAdmin)
              .having((r) => r.message, 'message', 'Only admin senders can resolve approvals'),
        );
        expect((await repository.getById('run-1'))!.status, WorkflowRunStatus.awaitingApproval);
        expect((await stored('run-1'))!.isResolved, isFalse);
        final entry = audit.entries.single;
        expect(
          (entry.verdict, entry.decision, entry.peerId, entry.runId, entry.stepId),
          ('block', 'deny', 'U-B', 'run-1', 'gate'),
        );
      },
    );

    test('with no admin senders configured the same click resolves, as for every other admin gate', () async {
      final interaction = await holdRun('run-1');
      adminSenders = [];

      final result = await newControl().handleApproval(click(interaction, sender: 'U-B'));

      expect(result, isA<ChannelRunApprovalResolved>());
    });

    test(
      'a random, foreign, misstepped, misplaced or settled click is refused, audited, and changes nothing',
      () async {
        final interaction = await holdRun('run-1');
        final other = await holdRun('run-2');
        final control = newControl();

        final refusals = <(String, ChannelRunApprovalRequest)>[
          ('random nonce', click(interaction, nonce: 'e' * 32)),
          ('another run\'s nonce', click(interaction, nonce: other.nonce)),
          ('another step', click(interaction, stepId: 'step-y')),
          ('another post', click(interaction, messageId: '9999.99')),
          ('unknown run', click(interaction, runId: 'no-such-run')),
        ];
        for (final (label, request) in refusals) {
          final result = await control.handleApproval(request);
          expect(
            result,
            isA<ChannelRunApprovalRefused>().having((r) => r.reason, 'reason', ChannelRunApprovalRefusal.invalid),
            reason: label,
          );
        }
        expect(audit.entries.map((e) => e.decision), everyElement('deny'));
        expect(audit.entries, hasLength(refusals.length));
        expect((await repository.getById('run-1'))!.status, WorkflowRunStatus.awaitingApproval);

        // The real button still works, and once resolved elsewhere the same nonce is "already resolved".
        await workflows.resume('run-2', resolver: const WorkflowApprovalResolver(source: WorkflowApprovalSource.web));
        final late = await control.handleApproval(click(other, runId: 'run-2'));
        expect(
          late,
          isA<ChannelRunApprovalRefused>().having((r) => r.reason, 'reason', ChannelRunApprovalRefusal.alreadyResolved),
        );
        expect(await control.handleApproval(click(interaction)), isA<ChannelRunApprovalResolved>());
      },
    );

    test('a failed resolution is answered privately, audited as an error, and leaves the same button usable', () async {
      final interaction = await holdRun('run-1');
      final control = newControl();

      repository.failNextUpdate = true;
      final failed = await control.handleApproval(click(interaction));
      final retried = await control.handleApproval(click(interaction));

      expect(failed, isA<ChannelRunApprovalFailed>());
      expect(retried, isA<ChannelRunApprovalResolved>());
      expect(audit.entries.map((e) => e.decision), ['error', 'allow']);
      expect(audit.entries.first.verdict, 'block');
      expect(resolved, hasLength(1));
    });
  });

  group('simultaneous resolutions', () {
    test('two clicks, an HTTP resume and a tool call in one turn yield one resolution', () async {
      final interaction = await holdRun('run-1');
      final control = newControl();

      final results = await Future.wait<Object>([
        control.handleApproval(click(interaction)),
        control.handleApproval(click(interaction, sender: 'U-C')),
        control.resumeFromWeb('run-1'),
        control.resumeFromTool('run-1', chatTurn()),
      ]);

      expect(
        results.whereType<ChannelRunApprovalResolved>().length + results.whereType<RunControlResolved>().length,
        1,
      );
      expect(resolved, hasLength(1));
      expect(audit.entries.where((e) => e.decision == 'allow'), hasLength(1));
      expect(audit.entries, hasLength(4));
      final webLoser = results.whereType<RunControlRefused>().toList();
      for (final loser in webLoser) {
        expect(loser.reason, isIn([RunControlRefusal.alreadyResolved, RunControlRefusal.notPending]));
      }
    });
  });

  group('web entries', () {
    test('are audited as web resolutions, never admin-gated, and carry no channel or nonce', () async {
      final first = await holdRun('run-1');
      final second = await holdRun('run-2');
      adminSenders = ['U-A'];
      final control = newControl();

      final resume = await control.resumeFromWeb('run-1');
      final cancel = await control.cancelFromWeb('run-2', feedback: 'stale branch');
      final notWaiting = await control.resumeFromWeb('run-1');

      expect(resume, isA<RunControlResolved>().having((r) => r.run?.status, 'status', WorkflowRunStatus.running));
      expect(cancel, isA<RunControlResolved>());
      expect(
        notWaiting,
        isA<RunControlRefused>().having((r) => r.message, 'message', contains('Cannot resume workflow in')),
      );

      expect(audit.entries.map((e) => (e.hook, e.decision, e.tool, e.runId)), [
        ('web', 'allow', 'resume', 'run-1'),
        ('web', 'allow', 'cancel', 'run-2'),
        ('web', 'deny', 'resume', 'run-1'),
      ]);
      expect(audit.entries.map((e) => e.channel), everyElement(isNull));
      expect(audit.entries.map((e) => e.principal), everyElement('owner'));
      expect(audit.entries.last.reason, 'alreadyResolved');
      expect((await stored('run-2'))!.resolution?.source, WorkflowApprovalSource.web);
      expect((await repository.getById('run-2'))!.contextJson['gate.approval.feedback'], 'stale branch');

      final everything = [
        ...audit.entries.map((e) => jsonEncode(e.toJson())),
        ...logs.map((r) => r.message),
      ].join('\n');
      expect(everything, isNot(contains(first.nonce)));
      expect(everything, isNot(contains(second.nonce)));
    });

    test('a cancel that loses its update fails, as the cancel route always answered it with a 500', () async {
      await holdRun('run-1');
      final control = newControl();

      repository.failNextUpdate = true;
      final result = await control.cancelFromWeb('run-1');

      expect(result, isA<RunControlFailed>());
      expect(audit.entries.single.decision, 'error');
      expect(resolved, isEmpty);
    });

    test('an unknown run is not found and still audited', () async {
      final result = await newControl().cancelFromWeb('no-such-run');

      expect(result, isA<RunControlNotFound>());
      expect(audit.entries.single.decision, 'deny');
    });
  });

  group('tool entries', () {
    test('an admin sender cancels with feedback and is audited as tool, channel and sender', () async {
      await holdRun('run-1');
      adminSenders = ['U-A'];

      final result = await newControl().cancelFromTool('run-1', chatTurn(), feedback: 'the branch is stale');

      expect(result, isA<RunControlResolved>());
      final run = (await repository.getById('run-1'))!;
      expect(run.status, WorkflowRunStatus.cancelled);
      expect(run.contextJson['gate.approval.feedback'], 'the branch is stale');
      final entry = audit.entries.single;
      expect(
        (entry.hook, entry.channel, entry.peerId, entry.tool, entry.decision),
        ('tool', 'slack', 'U-A', 'cancel', 'allow'),
      );
    });

    test('a non-admin sender is refused naming admin senders, the run is unchanged, one deny entry', () async {
      await holdRun('run-1');
      adminSenders = ['U-A'];

      final result = await newControl().cancelFromTool('run-1', chatTurn(sender: 'U-B'));

      expect(result, isA<RunControlRefused>().having((r) => r.message, 'message', contains('admin senders')));
      expect((await repository.getById('run-1'))!.status, WorkflowRunStatus.awaitingApproval);
      expect(audit.entries.single.decision, 'deny');
      expect(audit.entries.single.peerId, 'U-B');
    });

    test('no turn, a scheduled turn and a web-chat turn need a chat turn, each with one deny entry', () async {
      await holdRun('run-1');
      final control = newControl();

      final results = [
        await control.resumeFromTool('run-1', null),
        await control.resumeFromTool('run-1', const TurnProvenance.cron()),
        await control.cancelFromTool('run-1', const TurnProvenance.web(sessionKey: 'agent:main:web:abc')),
      ];

      expect(
        results,
        everyElement(isA<RunControlRefused>().having((r) => r.reason, 'reason', RunControlRefusal.needsChatTurn)),
      );
      expect(audit.entries.map((e) => e.decision), everyElement('deny'));
      expect(audit.entries, hasLength(3));
      expect((await repository.getById('run-1'))!.status, WorkflowRunStatus.awaitingApproval);
    });

    test('a delegated turn needs a chat turn even for an admin requester, and the refusal is audited', () async {
      adminSenders = ['U-A'];
      await holdRun('run-1');
      final control = newControl();

      final results = [
        await control.resumeFromTool('run-1', chatTurn(delegated: true)),
        await control.cancelFromTool('run-1', chatTurn(delegated: true)),
      ];
      final live = await control.resumeFromTool('run-1', chatTurn());

      expect(
        results,
        everyElement(isA<RunControlRefused>().having((r) => r.reason, 'reason', RunControlRefusal.needsChatTurn)),
      );
      expect(live, isA<RunControlResolved>());
      expect(audit.entries.map((e) => (e.guard, e.hook, e.decision, e.tool, e.channel, e.peerId, e.reason)), [
        ('RunApprovalGate', 'tool', 'deny', 'resume', 'slack', 'U-A', 'Run control needs a chat turn'),
        ('RunApprovalGate', 'tool', 'deny', 'cancel', 'slack', 'U-A', 'Run control needs a chat turn'),
        ('RunApprovalGate', 'tool', 'allow', 'resume', 'slack', 'U-A', null),
      ]);
    });

    test('a delegated push-back turn with no sender is refused even where every sender is an admin', () async {
      await holdRun('run-1');
      final pushBack = TurnProvenance.channel(
        channelType: ChannelType.slack,
        sessionKey: 'agent:main:group:slack:C1',
        delegated: true,
      );

      final refused = await newControl().resumeFromTool('run-1', pushBack);

      expect((refused as RunControlRefused).reason, RunControlRefusal.needsChatTurn);
      expect((await repository.getById('run-1'))!.status, WorkflowRunStatus.awaitingApproval);
    });
  });

  group('request changes', () {
    late WorkflowService full;
    late TaskService fullTasks;
    var runs = 0;

    setUp(() {
      final taskRepository = InMemoryTaskRepository();
      final agentExecutions = InMemoryAgentExecutionRepository();
      final stepExecutions = InMemoryWorkflowStepExecutionRepository();
      const transactor = InMemoryExecutionRepositoryTransactor();
      fullTasks = TaskService(
        taskRepository,
        agentExecutionRepository: agentExecutions,
        executionTransactor: transactor,
        eventBus: eventBus,
      );
      full = WorkflowService(
        repository: repository,
        taskService: fullTasks,
        messageService: MessageService(baseDir: p.join(tempDir.path, 'sessions')),
        persistencePorts: WorkflowPersistencePorts(
          taskRepository: taskRepository,
          agentExecutionRepository: agentExecutions,
          workflowStepExecutionRepository: stepExecutions,
          executionRepositoryTransactor: transactor,
        ),
        eventBus: eventBus,
        kvService: KvService(filePath: p.join(tempDir.path, 'kv-full.json')),
        dataDir: tempDir.path,
      );
      runs = 0;
    });

    tearDown(() async {
      await full.dispose();
      await fullTasks.dispose();
    });

    WorkflowRunControl fullControl() => WorkflowRunControl(
      workflows: full,
      isAdmin: GovernanceConfig(adminSenders: adminSenders).isAdmin,
      auditLogger: audit,
    );

    /// A run waiting at a gate that revises `draft` after [revision] rounds, with its post bound.
    Future<WorkflowApprovalInteraction> holdAtGate({
      String id = 'run-1',
      int revision = 0,
      int? maxRevisions,
      String? revise = 'draft',
    }) async {
      runs++;
      final definition = WorkflowDefinition(
        name: 'revisable',
        description: 'A gate that revises its draft',
        steps: [
          const WorkflowStep(id: 'draft', name: 'Draft', prompts: ['Draft']),
          WorkflowStep(
            id: 'gate',
            name: 'Gate',
            taskType: WorkflowTaskType.approval,
            prompts: const ['Review'],
            revise: revise,
            maxRevisions: maxRevisions,
          ),
        ],
      );
      final now = DateTime.now();
      await repository.insert(
        WorkflowRun(
          id: id,
          definitionName: definition.name,
          status: WorkflowRunStatus.awaitingApproval,
          startedAt: now,
          updatedAt: now,
          currentStepIndex: 2,
          definitionJson: definition.toJson(),
          contextJson: {
            '_approval.pending.stepId': 'gate',
            '_approval.pending.stepIndex': 1,
            'gate.approval.status': 'pending',
            'data': <String, dynamic>{'gate.approval.revision': revision},
            'variables': <String, dynamic>{},
          },
        ),
      );
      final interaction = (await full.issueApprovalInteraction(id, 'gate'))!;
      await full.bindApprovalPost(
        id,
        nonce: interaction.nonce,
        post: const WorkflowApprovalPost(channelType: 'slack', recipientId: 'C1', messageId: _slackMessage),
      );
      return interaction;
    }

    ChannelRunApprovalRequest submit(WorkflowApprovalInteraction interaction, {String? feedback = 'split story 3'}) =>
        ChannelRunApprovalRequest(
          action: ChannelRunApprovalAction.requestChanges,
          runId: 'run-1',
          stepId: interaction.stepId,
          nonce: interaction.nonce,
          senderId: 'U-A',
          senderDisplayName: 'Ada',
          channelType: 'slack',
          postMessageId: _slackMessage,
          feedback: feedback,
        );

    ChannelRunApprovalRequest check(WorkflowApprovalInteraction interaction, {String sender = 'U-A'}) =>
        ChannelRunApprovalRequest(
          action: ChannelRunApprovalAction.checkRequestChanges,
          runId: 'run-1',
          stepId: interaction.stepId,
          nonce: interaction.nonce,
          senderId: sender,
          channelType: 'slack',
          postMessageId: _slackMessage,
        );

    test('a check by an admin passes silently; a non-admin, a gate without revise and the bound are refused', () async {
      adminSenders = ['U-A'];
      final open = await holdAtGate();

      expect(await fullControl().handleApproval(check(open)), isA<ChannelRunApprovalPermitted>());
      expect(audit.entries, isEmpty, reason: 'a check that passes resolved nothing, so it writes no entry');

      final nonAdmin = await fullControl().handleApproval(check(open, sender: 'U-B'));
      expect((nonAdmin as ChannelRunApprovalRefused).reason, ChannelRunApprovalRefusal.notAdmin);

      await repository.delete('run-1');
      final none = await holdAtGate(id: 'run-1', revise: null);
      final noRevise = await fullControl().handleApproval(check(none));
      expect((noRevise as ChannelRunApprovalRefused).reason, ChannelRunApprovalRefusal.changesNotOffered);

      await repository.delete('run-1');
      final atBound = await holdAtGate(revision: 2, maxRevisions: 2);
      final limit = await fullControl().handleApproval(check(atBound));
      expect((limit as ChannelRunApprovalRefused).reason, ChannelRunApprovalRefusal.limitReached);

      expect(audit.entries.map((e) => (e.decision, e.tool)), [
        ('deny', 'checkRequestChanges'),
        ('deny', 'checkRequestChanges'),
        ('deny', 'checkRequestChanges'),
      ]);
      expect((await repository.getById('run-1'))!.status, WorkflowRunStatus.awaitingApproval);
    });

    test('a submission resolves once, audited with the round and never the feedback or the nonce', () async {
      adminSenders = ['U-A'];
      final interaction = await holdAtGate(revision: 1);

      final result = await fullControl().handleApproval(submit(interaction, feedback: 'split story 3, then ship'));

      expect(result, isA<ChannelRunApprovalResolved>());
      final entry = audit.entries.single;
      expect(
        (entry.hook, entry.decision, entry.tool, entry.reason, entry.channel, entry.peerId, entry.runId, entry.stepId),
        ('button', 'allow', 'requestChanges', 'revision 2/3', 'slack', 'U-A', 'run-1', 'gate'),
      );
      final serialized = entry.toJson().toString();
      expect(serialized, isNot(contains('split story 3')));
      expect(serialized, isNot(contains(interaction.nonce)));
      expect(logs.map((r) => '${r.message} ${r.error}').join('\n'), isNot(contains('split story 3')));
      expect(logs.map((r) => '${r.message} ${r.error}').join('\n'), isNot(contains(interaction.nonce)));
      expect(resolved.single.changesRequested, isTrue);
      expect((resolved.single.revision, resolved.single.maxRevisions), (2, 3));
    });

    test('blank feedback is refused with one deny entry and leaves the same nonce able to approve', () async {
      adminSenders = ['U-A'];
      final interaction = await holdAtGate();

      final blank = await fullControl().handleApproval(submit(interaction, feedback: '  \n '));
      final missing = await fullControl().handleApproval(submit(interaction, feedback: null));

      for (final refused in [blank, missing]) {
        expect((refused as ChannelRunApprovalRefused).reason, ChannelRunApprovalRefusal.feedbackRequired);
      }
      expect(audit.entries.map((e) => (e.decision, e.reason)), [
        ('deny', 'feedbackRequired'),
        ('deny', 'feedbackRequired'),
      ]);
      expect(resolved, isEmpty);

      final approve = await fullControl().handleApproval(click(interaction));
      expect(approve, isA<ChannelRunApprovalResolved>(), reason: 'no refusal consumed the nonce');
    });

    test('a submission from the post of an earlier round is invalid and the new post still resolves', () async {
      adminSenders = ['U-A'];
      final first = await holdAtGate();
      final second = (await full.issueApprovalInteraction('run-1', 'gate'))!;
      await full.bindApprovalPost(
        'run-1',
        nonce: second.nonce,
        post: const WorkflowApprovalPost(channelType: 'slack', recipientId: 'C1', messageId: '1700.02'),
      );

      final stale = await fullControl().handleApproval(submit(first));
      final live = await fullControl().handleApproval(
        ChannelRunApprovalRequest(
          action: ChannelRunApprovalAction.requestChanges,
          runId: 'run-1',
          stepId: 'gate',
          nonce: second.nonce,
          senderId: 'U-A',
          channelType: 'slack',
          postMessageId: '1700.02',
          feedback: 'again',
        ),
      );

      expect((stale as ChannelRunApprovalRefused).reason, ChannelRunApprovalRefusal.invalid);
      expect(live, isA<ChannelRunApprovalResolved>());
    });

    test('two submissions, an approve and an HTTP resume in one turn resolve exactly once', () async {
      adminSenders = ['U-A'];
      final interaction = await holdAtGate();
      final control = fullControl();

      final results = await Future.wait<Object>([
        control.handleApproval(submit(interaction)),
        control.handleApproval(submit(interaction, feedback: 'other')),
        control.handleApproval(click(interaction)),
        control.resumeFromWeb('run-1'),
      ]);

      expect(resolved, hasLength(1));
      expect(audit.entries.where((e) => e.decision == 'allow'), hasLength(1));
      expect(
        results.whereType<ChannelRunApprovalRefused>().map((r) => r.reason),
        everyElement(ChannelRunApprovalRefusal.alreadyResolved),
      );
      expect(
        results.whereType<RunControlRefused>().map((r) => r.reason),
        everyElement(RunControlRefusal.alreadyResolved),
      );
    });

    test('the tool follows the admin and chat-turn rules and is audited like the buttons', () async {
      adminSenders = ['U-A'];
      await holdAtGate();
      final control = fullControl();

      final nonAdmin = await control.requestChangesFromTool('run-1', chatTurn(sender: 'U-B'), feedback: 'x');
      final webChat = await control.requestChangesFromTool(
        'run-1',
        const TurnProvenance.web(sessionKey: 'agent:main:web:abc'),
        feedback: 'x',
      );
      final admin = await control.requestChangesFromTool('run-1', chatTurn(), feedback: 'split story 3');

      expect((nonAdmin as RunControlRefused).reason, RunControlRefusal.notAdmin);
      expect((webChat as RunControlRefused).reason, RunControlRefusal.needsChatTurn);
      expect(admin, isA<RunControlResolved>());
      expect(audit.entries.map((e) => (e.hook, e.decision, e.tool, e.reason)), [
        ('tool', 'deny', 'requestChanges', 'sender is not in governance.admin_senders'),
        ('tool', 'deny', 'requestChanges', 'Run control needs a chat turn'),
        ('tool', 'allow', 'requestChanges', 'revision 1/3'),
      ]);
    });

    test('the web entry is audited with source web and no admin check, refusals included', () async {
      adminSenders = ['U-A'];
      await holdAtGate(revision: 3);

      final atBound = await fullControl().requestChangesFromWeb('run-1', feedback: 'again');
      final unknown = await fullControl().requestChangesFromWeb('nope', feedback: 'again');
      await repository.delete('run-1');
      await holdAtGate();
      final blank = await fullControl().requestChangesFromWeb('run-1', feedback: ' ');
      final ok = await fullControl().requestChangesFromWeb('run-1', feedback: 'split story 3');

      expect((atBound as RunControlRefused).reason, RunControlRefusal.limitReached);
      expect(unknown, isA<RunControlNotFound>());
      expect((blank as RunControlRefused).reason, RunControlRefusal.feedbackRequired);
      expect(ok, isA<RunControlResolved>());
      expect(audit.entries.map((e) => (e.hook, e.decision, e.principal)), [
        ('web', 'deny', 'owner'),
        ('web', 'deny', 'owner'),
        ('web', 'deny', 'owner'),
        ('web', 'allow', 'owner'),
      ]);
      expect(runs, 2);
    });
  });
}
