import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService;
import 'package:dartclaw_runtime/src/mcp/context_engine_profile.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:dartclaw_runtime/src/mcp/workflow_run_control_tools.dart';
import 'package:dartclaw_runtime/src/task/workflow_run_control.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryTaskRepository;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowRun, WorkflowService, WorkflowStep, WorkflowTaskType;
import 'package:dartclaw_workflow/testing.dart' show InMemoryWorkflowRunRepository;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../guard_audit_test_support.dart';

Future<Map<String, dynamic>> _rpc(McpProtocolHandler handler, String method, [Map<String, dynamic>? params]) async {
  final raw = await handler.handleRequest(jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': ?params}));
  return jsonDecode(raw!) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> _call(McpProtocolHandler handler, String name, Map<String, dynamic> arguments) =>
    _rpc(handler, 'tools/call', {'name': name, 'arguments': arguments});

Map<String, dynamic> _result(Map<String, dynamic> response) {
  expect(response['error'], isNull, reason: 'a tool refusal must be a JSON-RPC success carrying isError');
  return response['result'] as Map<String, dynamic>;
}

String _text(Map<String, dynamic> result) =>
    ((result['content'] as List).single as Map<String, dynamic>)['text'] as String;

Map<String, dynamic> _payload(Map<String, dynamic> result) => jsonDecode(_text(result)) as Map<String, dynamic>;

Future<Set<String>> _toolNames(McpProtocolHandler handler) async {
  final result = (await _rpc(handler, 'tools/list'))['result'] as Map<String, dynamic>;
  return {for (final tool in (result['tools'] as List).cast<Map<String, dynamic>>()) tool['name'] as String};
}

const _controlTools = {'workflow_resume', 'workflow_cancel', 'workflow_status'};

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
    final control = WorkflowRunControl(
      workflows: workflows,
      isAdmin: GovernanceConfig(adminSenders: adminSenders).isAdmin,
      auditLogger: audit,
    );
    return McpProtocolHandler()
      ..registerTool(WorkflowResumeTool(control: control))
      ..registerTool(WorkflowCancelTool(control: control))
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

      final denied = _result(
        await _call(newHandler().forHarness(() => slackOther), 'workflow_cancel', {'run_id': 'run-2'}),
      );
      final ok = _result(
        await _call(newHandler().forHarness(() => slackAdmin), 'workflow_cancel', {
          'run_id': 'run-1',
          'feedback': 'the branch is stale',
        }),
      );

      expect(denied['isError'], isTrue);
      expect(_payload(denied)['message'], contains('admin senders'));
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

      final whatsapp = _result(
        await _call(
          newHandler().forHarness(() => turn(ChannelType.whatsapp, sender: '+4670000001', recipient: '+4670000001')),
          'workflow_resume',
          {'run_id': 'run-wa'},
        ),
      );
      final signalAdmin = _result(
        await _call(
          newHandler().forHarness(() => turn(ChannelType.signal, sender: '+4670000002', recipient: 'group-1')),
          'workflow_resume',
          {'run_id': 'run-sig'},
        ),
      );
      final signalOther = _result(
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
      final result = _result(
        await _call(newHandler().forHarness(() => turn(ChannelType.slack, sender: 'U-A')), 'workflow_resume', {
          'run_id': 'nope',
        }),
      );

      expect(result['isError'], isTrue);
      expect(_payload(result)['reason'], 'unknown_run');
    });
  });

  group('a task push-back turn', () {
    // Delivered with the task's channel and no sender (`_pushBackFeedbackDelivery`), so the gate decides it by the
    // rule the shared-knowledge write gate applies to a sender-less channel turn, and audits it either way.
    final pushBack = TurnProvenance.channel(channelType: ChannelType.slack, sessionKey: 'agent:main:group:slack:C1');

    test('is refused wherever admin_senders is set and audited, never an unaudited bypass', () async {
      adminSenders = ['U-A'];
      await insertRun('run-1');

      final result = _result(
        await _call(newHandler().forHarness(() => pushBack), 'workflow_resume', {'run_id': 'run-1'}),
      );

      expect(result['isError'], isTrue);
      expect((await repository.getById('run-1'))!.status, WorkflowRunStatus.awaitingApproval);
      expect(audit.entries.single.decision, 'deny');
      expect(audit.entries.single.peerId, isNull);
    });

    test('resolves, audited, where admin_senders is empty and every sender is an admin', () async {
      await insertRun('run-1');

      final result = _result(
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
        _result(await _call(gateway, 'workflow_resume', {'run_id': 'run-1'})),
        _result(await _call(scheduled, 'workflow_cancel', {'run_id': 'run-1'})),
        _result(await _call(webChat, 'workflow_resume', {'run_id': 'run-1'})),
      ];

      for (final result in results) {
        expect(result['isError'], isTrue);
        expect(_payload(result)['message'], contains('chat turn'));
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

    test('a named MCP client discovers none of the three', () async {
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

      final payload = _payload(_result(await _call(newHandler(), 'workflow_status', {'run_id': 'run-1'})));

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

      final failed = _payload(_result(await _call(newHandler(), 'workflow_status', {'run_id': 'run-failed'})));
      final done = _payload(_result(await _call(newHandler(), 'workflow_status', {'run_id': 'run-done'})));

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

        final unknown = _result(await _call(other, 'workflow_status', {'run_id': 'nope'}));
        final asOther = _payload(_result(await _call(other, 'workflow_status', {'run_id': 'run-1'})));
        final asAdmin = _payload(_result(await _call(admin, 'workflow_status', {'run_id': 'run-1'})));

        expect(unknown['isError'], isTrue);
        expect(_payload(unknown)['reason'], 'unknown_run');
        expect(asOther, asAdmin);
        expect(audit.entries, isEmpty);
      },
    );

    test('is classified read and the two resolving tools write', () {
      final control = WorkflowRunControl(workflows: workflows, isAdmin: (_) => true, auditLogger: audit);

      expect(WorkflowStatusTool(workflows: workflows).access, McpToolAccess.read);
      expect(WorkflowResumeTool(control: control).access, McpToolAccess.write);
      expect(WorkflowCancelTool(control: control).access, McpToolAccess.write);
    });
  });
}
