import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService;
import 'package:dartclaw_runtime/src/task/workflow_run_control.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryTaskRepository;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowApprovalInteraction,
        WorkflowApprovalPost,
        WorkflowApprovalResolver,
        WorkflowApprovalSource,
        WorkflowDefinition,
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

  TurnProvenance chatTurn({String? sender = 'U-A', ChannelType channel = ChannelType.slack}) => TurnProvenance.channel(
    channelType: channel,
    sessionKey: 'agent:main:group:${channel.name}:C1',
    recipientId: 'C1',
    senderId: sender,
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

    test('a channel turn with no sender is gated by the same rule as shared knowledge writes', () async {
      await holdRun('run-1');
      await holdRun('run-2');
      final pushBack = TurnProvenance.channel(channelType: ChannelType.slack, sessionKey: 'agent:main:group:slack:C1');

      adminSenders = ['U-A'];
      final refused = await newControl().resumeFromTool('run-1', pushBack);
      adminSenders = [];
      final allowed = await newControl().resumeFromTool('run-2', pushBack);

      expect(refused, isA<RunControlRefused>());
      expect(allowed, isA<RunControlResolved>());
      expect(audit.entries.map((e) => (e.decision, e.reason)), [
        ('deny', 'channel turn carries no sender'),
        ('allow', null),
      ]);
    });
  });
}
