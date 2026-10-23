import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService;
import 'package:dartclaw_runtime/src/mcp/context_engine_profile.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:dartclaw_runtime/src/mcp/workflow_run_control_tools.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart'
    show
        InMemoryAgentExecutionRepository,
        InMemoryExecutionRepositoryTransactor,
        InMemoryTaskRepository,
        InMemoryWorkflowStepExecutionRepository;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowPersistencePorts, WorkflowRun, WorkflowService, WorkflowStep, WorkflowTaskType;
import 'package:dartclaw_workflow/testing.dart' show InMemoryWorkflowRunRepository;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../api/workflow_test_support.dart' show testRunControl;
import '../guard_audit_test_support.dart';
import 'mcp_test_support.dart' show resultPayload, toolResult;

Future<Map<String, dynamic>> _rpc(McpProtocolHandler handler, String method, [Map<String, dynamic>? params]) async {
  final raw = await handler.handleRequest(jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': ?params}));
  return jsonDecode(raw!) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> _call(McpProtocolHandler handler, String name, Map<String, dynamic> arguments) =>
    _rpc(handler, 'tools/call', {'name': name, 'arguments': arguments});

Future<Set<String>> _toolNames(McpProtocolHandler handler) async {
  final result = (await _rpc(handler, 'tools/list'))['result'] as Map<String, dynamic>;
  return {for (final tool in (result['tools'] as List).cast<Map<String, dynamic>>()) tool['name'] as String};
}

const _controlTools = {'workflow_resume', 'workflow_cancel', 'workflow_request_changes', 'workflow_status'};

void main() {
  late Directory tempDir;
  late EventBus eventBus;
  late TaskService tasks;
  late InMemoryWorkflowRunRepository repository;
  late WorkflowService workflows;
  late RecordingGuardAuditLogger audit;
  var adminSenders = <String>[];

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_run_control_tools_');
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
  });

  tearDown(() async {
    await workflows.dispose();
    await tasks.dispose();
    await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  McpProtocolHandler newHandler() {
    final control = testRunControl(
      workflows,
      isAdmin: GovernanceConfig(adminSenders: adminSenders).isAdmin,
      auditLogger: audit,
    );
    return McpProtocolHandler()
      ..registerTool(WorkflowResumeTool(control: control))
      ..registerTool(WorkflowCancelTool(control: control))
      ..registerTool(WorkflowRequestChangesTool(control: control))
      ..registerTool(WorkflowStatusTool(workflows: workflows));
  }

  Future<WorkflowRun> insertRun(
    String id, {
    WorkflowRunStatus status = WorkflowRunStatus.awaitingApproval,
    String? errorMessage,
    String message = 'Ship it?',
    int currentStepIndex = 1,
  }) async {
    final definition = WorkflowDefinition(
      name: 'ship-it',
      description: 'Gate then ship',
      steps: const [
        WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
        WorkflowStep(id: 'ship', name: 'Ship', taskType: WorkflowTaskType.approval, prompts: ['Ship?']),
      ],
    );
    final now = DateTime.utc(2026, 10, 6, 12);
    final awaiting = status == WorkflowRunStatus.awaitingApproval;
    final run = WorkflowRun(
      id: id,
      definitionName: definition.name,
      status: status,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: currentStepIndex,
      errorMessage: errorMessage,
      definitionJson: definition.toJson(),
      contextJson: {
        if (awaiting) ...{
          '_approval.pending.stepId': 'gate',
          '_approval.pending.stepIndex': 0,
          'gate.approval.message': message,
          'gate.approval.requested_at': '2026-10-06T12:00:00.000Z',
        },
        'data': <String, dynamic>{},
        'variables': <String, dynamic>{},
      },
    );
    await repository.insert(run);
    return run;
  }

  TurnProvenance turn(ChannelType channel, {String? sender, String recipient = 'C1', String? thread}) =>
      TurnProvenance.channel(
        channelType: channel,
        sessionKey: 'agent:main:group:${channel.name}:$recipient',
        recipientId: recipient,
        threadId: thread,
        senderId: sender,
      );

  group('workflow_cancel', () {
    test('an admin sender cancels with feedback; a non-admin is refused, and each is audited once', () async {
      adminSenders = ['U-A'];
      await insertRun('run-1');
      await insertRun('run-2');
      final slackAdmin = turn(ChannelType.slack, sender: 'U-A', thread: 'C1:1700.1');
      final slackOther = turn(ChannelType.slack, sender: 'U-B', thread: 'C1:1700.1');

      final denied = toolResult(
        await _call(newHandler().forHarness(() => slackOther), 'workflow_cancel', {'run_id': 'run-2'}),
      );
      final ok = toolResult(
        await _call(newHandler().forHarness(() => slackAdmin), 'workflow_cancel', {
          'run_id': 'run-1',
          'feedback': 'the branch is stale',
        }),
      );

      expect(denied['isError'], isTrue);
      expect(resultPayload(denied)['message'], contains('admin senders'));
      expect((await repository.getById('run-2'))!.status, WorkflowRunStatus.awaitingApproval);
      expect(ok['isError'], isNot(true));
      final cancelled = (await repository.getById('run-1'))!;
      expect(cancelled.status, WorkflowRunStatus.cancelled);
      expect(cancelled.contextJson['gate.approval.feedback'], 'the branch is stale');
      expect(cancelled.contextJson['gate.approval.status'], 'rejected');

      expect(audit.entries.map((e) => (e.hook, e.channel, e.peerId, e.tool, e.decision, e.runId)), [
        ('tool', 'slack', 'U-B', 'cancel', 'deny', 'run-2'),
        ('tool', 'slack', 'U-A', 'cancel', 'allow', 'run-1'),
      ]);
    });
  });

  group('workflow_resume', () {
    test('a WhatsApp DM admin and a Signal group admin resume; a non-admin in the group is refused', () async {
      adminSenders = ['+4670000001', '+4670000002'];
      await insertRun('run-wa');
      await insertRun('run-sig');
      await insertRun('run-sig-2');

      final whatsapp = toolResult(
        await _call(
          newHandler().forHarness(() => turn(ChannelType.whatsapp, sender: '+4670000001', recipient: '+4670000001')),
          'workflow_resume',
          {'run_id': 'run-wa'},
        ),
      );
      final signalAdmin = toolResult(
        await _call(
          newHandler().forHarness(() => turn(ChannelType.signal, sender: '+4670000002', recipient: 'group-1')),
          'workflow_resume',
          {'run_id': 'run-sig'},
        ),
      );
      final signalOther = toolResult(
        await _call(
          newHandler().forHarness(() => turn(ChannelType.signal, sender: '+4670000009', recipient: 'group-1')),
          'workflow_resume',
          {'run_id': 'run-sig-2'},
        ),
      );

      expect(whatsapp['isError'], isNot(true));
      expect(signalAdmin['isError'], isNot(true));
      expect(signalOther['isError'], isTrue);
      expect((await repository.getById('run-wa'))!.status, isNot(WorkflowRunStatus.awaitingApproval));
      expect((await repository.getById('run-sig-2'))!.status, WorkflowRunStatus.awaitingApproval);
      expect(audit.entries.map((e) => (e.channel, e.peerId, e.decision)), [
        ('whatsapp', '+4670000001', 'allow'),
        ('signal', '+4670000002', 'allow'),
        ('signal', '+4670000009', 'deny'),
      ]);
    });

    test('an unknown run answers an unknown-run error', () async {
      final result = toolResult(
        await _call(newHandler().forHarness(() => turn(ChannelType.slack, sender: 'U-A')), 'workflow_resume', {
          'run_id': 'nope',
        }),
      );

      expect(result['isError'], isTrue);
      expect(resultPayload(result)['reason'], 'unknown_run');
    });
  });

  group('a task push-back turn', () {
    // Delivered with the task's channel and no sender (`_pushBackFeedbackDelivery`), so the gate decides it by the
    // rule the shared-knowledge write gate applies to a sender-less channel turn, and audits it either way.
    final pushBack = TurnProvenance.channel(channelType: ChannelType.slack, sessionKey: 'agent:main:group:slack:C1');

    test('is refused wherever admin_senders is set and audited, never an unaudited bypass', () async {
      adminSenders = ['U-A'];
      await insertRun('run-1');

      final result = toolResult(
        await _call(newHandler().forHarness(() => pushBack), 'workflow_resume', {'run_id': 'run-1'}),
      );

      expect(result['isError'], isTrue);
      expect((await repository.getById('run-1'))!.status, WorkflowRunStatus.awaitingApproval);
      expect(audit.entries.single.decision, 'deny');
      expect(audit.entries.single.peerId, isNull);
    });

    test('resolves, audited, where admin_senders is empty and every sender is an admin', () async {
      await insertRun('run-1');

      final result = toolResult(
        await _call(newHandler().forHarness(() => pushBack), 'workflow_resume', {'run_id': 'run-1'}),
      );

      expect(result['isError'], isNot(true));
      expect(audit.entries.single.decision, 'allow');
    });
  });

  group('no chat turn, no write', () {
    test('the shared gateway token, a scheduled turn and a web-chat turn change nothing and are each denied', () async {
      await insertRun('run-1');
      final gateway = newHandler();
      final scheduled = newHandler().forHarness(() => const TurnProvenance.cron());
      final webChat = newHandler().forHarness(() => const TurnProvenance.web(sessionKey: 'agent:main:web:abc'));

      final results = [
        toolResult(await _call(gateway, 'workflow_resume', {'run_id': 'run-1'})),
        toolResult(await _call(scheduled, 'workflow_cancel', {'run_id': 'run-1'})),
        toolResult(await _call(webChat, 'workflow_resume', {'run_id': 'run-1'})),
      ];

      for (final result in results) {
        expect(result['isError'], isTrue);
        expect(resultPayload(result)['message'], contains('chat turn'));
      }
      expect((await repository.getById('run-1'))!.status, WorkflowRunStatus.awaitingApproval);
      expect(audit.entries.map((e) => e.decision), ['deny', 'deny', 'deny']);
    });

    test('a sender or channel argument is refused as an unknown argument and nothing runs', () async {
      await insertRun('run-1');
      final handler = newHandler().forHarness(() => turn(ChannelType.slack, sender: 'U-A'));

      for (final field in ['sender', 'channel', 'senderId', 'channelType']) {
        final response = await _call(handler, 'workflow_resume', {'run_id': 'run-1', field: 'forged'});

        expect((response['error'] as Map)['message'], contains('unknown argument "$field"'), reason: field);
      }
      expect(audit.entries, isEmpty);
      expect((await repository.getById('run-1'))!.status, WorkflowRunStatus.awaitingApproval);
    });

    test('a named MCP client discovers none of the control tools', () async {
      final client = newHandler().scopedTo(
        ContextEngineCallerPolicy(principal: mcpClientPrincipal('crm')),
        callerIdentity: const McpCallerIdentity(authorityId: 'mcp-client:crm'),
      );

      expect((await _toolNames(client)).intersection(_controlTools), isEmpty);
      expect(await _toolNames(newHandler()), containsAll(_controlTools));
    });
  });

  group('workflow_status', () {
    test('reports an awaiting run with its pending approval, truncated to 1,000 characters, and no nonce', () async {
      await insertRun('run-1', message: 'x' * 1500);
      final interaction = (await workflows.issueApprovalInteraction('run-1', 'gate'))!;

      final payload = resultPayload(toolResult(await _call(newHandler(), 'workflow_status', {'run_id': 'run-1'})));

      expect(payload['status'], 'awaitingApproval');
      expect(payload['current_step'], 'gate');
      final pending = payload['pending_approval'] as Map<String, dynamic>;
      expect(pending['step'], 'gate');
      expect((pending['message'] as String).length, 1000);
      expect(pending['requested_at'], '2026-10-06T12:00:00.000Z');
      expect(payload['last_error'], isNull);
      final raw = jsonEncode(payload);
      expect(raw, isNot(contains(interaction.nonce)));
      expect(raw, isNot(contains('nonce')));
      expect(raw, isNot(contains('interaction')));
    });

    test('reports a failed run with its error and a completed run with neither approval nor error', () async {
      await insertRun(
        'run-failed',
        status: WorkflowRunStatus.failed,
        errorMessage: 'step ship failed',
        currentStepIndex: 1,
      );
      await insertRun('run-done', status: WorkflowRunStatus.completed, currentStepIndex: 2);

      final failed = resultPayload(toolResult(await _call(newHandler(), 'workflow_status', {'run_id': 'run-failed'})));
      final done = resultPayload(toolResult(await _call(newHandler(), 'workflow_status', {'run_id': 'run-done'})));

      expect(failed['status'], 'failed');
      expect(failed['current_step'], 'ship');
      expect(failed['pending_approval'], isNull);
      expect(failed['last_error'], 'step ship failed');
      expect(done['status'], 'completed');
      expect(done['current_step'], isNull);
      expect(done['last_error'], isNull);
    });

    test(
      'an unknown run answers an unknown-run error, and a non-admin sender gets the same answer an admin does',
      () async {
        adminSenders = ['U-A'];
        await insertRun('run-1');
        final other = newHandler().forHarness(() => turn(ChannelType.slack, sender: 'U-B'));
        final admin = newHandler().forHarness(() => turn(ChannelType.slack, sender: 'U-A'));

        final unknown = toolResult(await _call(other, 'workflow_status', {'run_id': 'nope'}));
        final asOther = resultPayload(toolResult(await _call(other, 'workflow_status', {'run_id': 'run-1'})));
        final asAdmin = resultPayload(toolResult(await _call(admin, 'workflow_status', {'run_id': 'run-1'})));

        expect(unknown['isError'], isTrue);
        expect(resultPayload(unknown)['reason'], 'unknown_run');
        expect(asOther, asAdmin);
        expect(audit.entries, isEmpty);
      },
    );

    test('is classified read and the two resolving tools write', () {
      final control = testRunControl(workflows, auditLogger: audit);

      expect(WorkflowStatusTool(workflows: workflows).access, McpToolAccess.read);
      expect(WorkflowResumeTool(control: control).access, McpToolAccess.write);
      expect(WorkflowCancelTool(control: control).access, McpToolAccess.write);
    });
  });

  group('workflow_request_changes', () {
    late WorkflowService full;
    late TaskService fullTasks;

    setUp(() {
      final taskRepository = InMemoryTaskRepository();
      final agentExecutions = InMemoryAgentExecutionRepository();
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
          workflowStepExecutionRepository: InMemoryWorkflowStepExecutionRepository(),
          executionRepositoryTransactor: transactor,
        ),
        eventBus: eventBus,
        kvService: KvService(filePath: p.join(tempDir.path, 'kv-full.json')),
        dataDir: tempDir.path,
      );
    });

    tearDown(() async {
      await full.dispose();
      await fullTasks.dispose();
    });

    McpProtocolHandler fullHandler() {
      final control = testRunControl(
        full,
        isAdmin: GovernanceConfig(adminSenders: adminSenders).isAdmin,
        auditLogger: audit,
      );
      return McpProtocolHandler()
        ..registerTool(WorkflowRequestChangesTool(control: control))
        ..registerTool(WorkflowStatusTool(workflows: full));
    }

    Future<void> insertGate(String id, {String? revise = 'draft', int revision = 0, int? maxRevisions}) async {
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
      final now = DateTime.utc(2026, 10, 6, 12);
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
            'gate.approval.message': 'Review the draft',
            'gate.approval.requested_at': '2026-10-06T12:00:00.000Z',
            'data': <String, dynamic>{'gate.approval.revision': revision},
            'variables': <String, dynamic>{},
          },
        ),
      );
    }

    test('an admin on Slack, WhatsApp and Signal resolves; a non-admin is refused naming admin senders', () async {
      adminSenders = ['U-A', '+4670000001', '+4670000002'];
      for (final id in ['run-slack', 'run-wa', 'run-sig', 'run-other']) {
        await insertGate(id);
      }
      final calls = <(String, TurnProvenance)>[
        ('run-slack', turn(ChannelType.slack, sender: 'U-A', thread: 'C1:1700.1')),
        ('run-wa', turn(ChannelType.whatsapp, sender: '+4670000001', recipient: '+4670000001')),
        ('run-sig', turn(ChannelType.signal, sender: '+4670000002', recipient: 'group-1')),
        ('run-other', turn(ChannelType.slack, sender: 'U-B')),
      ];

      final results = [
        for (final (runId, provenance) in calls)
          toolResult(
            await _call(fullHandler().forHarness(() => provenance), 'workflow_request_changes', {
              'run_id': runId,
              'feedback': 'split story 3',
            }),
          ),
      ];

      expect(results.take(3).map((r) => r['isError']), everyElement(isNot(true)));
      expect(resultPayload(results.first), {
        'run_id': 'run-slack',
        'outcome': 'changes_requested',
        'status': 'running',
      });
      expect(results.last['isError'], isTrue);
      expect(resultPayload(results.last)['message'], contains('admin senders'));
      expect((await repository.getById('run-other'))!.status, WorkflowRunStatus.awaitingApproval);
      expect(audit.entries.map((e) => (e.hook, e.channel, e.peerId, e.tool, e.decision, e.reason)), [
        ('tool', 'slack', 'U-A', 'requestChanges', 'allow', 'revision 1/3'),
        ('tool', 'whatsapp', '+4670000001', 'requestChanges', 'allow', 'revision 1/3'),
        ('tool', 'signal', '+4670000002', 'requestChanges', 'allow', 'revision 1/3'),
        ('tool', 'slack', 'U-B', 'requestChanges', 'deny', 'sender is not in governance.admin_senders'),
      ]);
      expect(audit.entries.map((e) => e.toJson().toString()).join(), isNot(contains('split story 3')));
    });

    test('a gateway-token call, a scheduled turn and a web-chat turn need a chat turn and are each denied', () async {
      await insertGate('run-1');
      final gateway = fullHandler();
      final scheduled = fullHandler().forHarness(() => const TurnProvenance.cron());
      final webChat = fullHandler().forHarness(() => const TurnProvenance.web(sessionKey: 'agent:main:web:abc'));

      for (final handler in [gateway, scheduled, webChat]) {
        final result = toolResult(
          await _call(handler, 'workflow_request_changes', {'run_id': 'run-1', 'feedback': 'again'}),
        );
        expect(result['isError'], isTrue);
        expect(resultPayload(result)['message'], contains('chat turn'));
      }
      expect((await repository.getById('run-1'))!.status, WorkflowRunStatus.awaitingApproval);
      expect(audit.entries.map((e) => e.decision), ['deny', 'deny', 'deny']);
    });

    test(
      'a forged sender or channel argument is an unknown argument; missing or blank feedback is a schema refusal',
      () async {
        await insertGate('run-1');
        final handler = fullHandler().forHarness(() => turn(ChannelType.slack, sender: 'U-A'));

        for (final field in ['sender', 'channel']) {
          final response = await _call(handler, 'workflow_request_changes', {
            'run_id': 'run-1',
            'feedback': 'x',
            field: 'forged',
          });
          expect((response['error'] as Map)['message'], contains('unknown argument "$field"'), reason: field);
        }
        for (final arguments in [
          {'run_id': 'run-1'},
          {'run_id': 'run-1', 'feedback': '   '},
        ]) {
          final result = toolResult(await _call(handler, 'workflow_request_changes', arguments));
          expect(result['isError'], isTrue, reason: '$arguments');
          expect(
            resultPayload(result)['reason'],
            'invalid_request',
            reason: 'the shared closed-schema pass refuses it first',
          );
        }
        expect(audit.entries, isEmpty);
      },
    );

    test('a gate without revise and a gate at its bound are refused with their own reason, audited', () async {
      await insertGate('run-none', revise: null);
      await insertGate('run-bound', revision: 2, maxRevisions: 2);
      final handler = fullHandler().forHarness(() => turn(ChannelType.slack, sender: 'U-A'));

      final reasons = <String?>[];
      for (final (runId, feedback) in [('run-none', 'x'), ('run-bound', 'x')]) {
        final result = toolResult(
          await _call(handler, 'workflow_request_changes', {'run_id': runId, 'feedback': feedback}),
        );
        expect(result['isError'], isTrue, reason: runId);
        reasons.add(resultPayload(result)['reason'] as String?);
      }

      expect(reasons, ['changes_not_offered', 'limit_reached']);
      expect(audit.entries.map((e) => e.decision), ['deny', 'deny']);
    });

    test(
      'workflow_status adds revision and the bound for a gate that names a revise step, and never a nonce',
      () async {
        await insertGate('run-1', revision: 1);
        await insertGate('run-2', revise: null);
        final interaction = (await full.issueApprovalInteraction('run-1', 'gate'))!;

        final withRevise = resultPayload(
          toolResult(await _call(fullHandler(), 'workflow_status', {'run_id': 'run-1'})),
        );
        final without = resultPayload(toolResult(await _call(fullHandler(), 'workflow_status', {'run_id': 'run-2'})));

        final pending = withRevise['pending_approval'] as Map<String, dynamic>;
        expect([pending['revision'], pending['max_revisions']], [1, 3]);
        expect(jsonEncode(withRevise), isNot(contains(interaction.nonce)));
        final bare = without['pending_approval'] as Map<String, dynamic>;
        expect(bare.keys, isNot(contains('revision')));
        expect(bare.keys, isNot(contains('max_revisions')));
      },
    );

    test('is a write tool, and a named MCP client discovers none of the control tools', () async {
      final control = testRunControl(workflows, auditLogger: audit);
      expect(WorkflowRequestChangesTool(control: control).access, McpToolAccess.write);

      final client = newHandler().scopedTo(
        ContextEngineCallerPolicy(principal: mcpClientPrincipal('crm')),
        callerIdentity: const McpCallerIdentity(authorityId: 'mcp-client:crm'),
      );

      expect((await _toolNames(client)).intersection(_controlTools), isEmpty);
      expect(await _toolNames(newHandler()), contains('workflow_request_changes'));
    });
  });
}
