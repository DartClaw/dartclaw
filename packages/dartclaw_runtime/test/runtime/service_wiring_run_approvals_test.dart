import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService, workflowRoutes;
import 'package:dartclaw_runtime/src/task/workflow_run_control.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryTaskRepository;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowApprovalInteraction,
        WorkflowApprovalPost,
        WorkflowApprovalSource,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowService,
        WorkflowStep,
        WorkflowTaskType;
import 'package:dartclaw_workflow/testing.dart' show InMemoryDefinitionSource, InMemoryWorkflowRunRepository;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../guard_audit_test_support.dart';

/// The run-approval authority as the composition root builds it: one control over the one workflow service,
/// serving the HTTP routes, the chat buttons and the tools.
void main() {
  late Directory tempDir;
  late EventBus eventBus;
  late TaskService tasks;
  late InMemoryWorkflowRunRepository repository;
  late RecordingGuardAuditLogger audit;
  late WorkflowService workflows;

  WorkflowService newService() => WorkflowService.lifecycleOnly(
    repository: repository,
    taskService: tasks,
    messageService: MessageService(baseDir: p.join(tempDir.path, 'sessions')),
    eventBus: eventBus,
    kvService: KvService(filePath: p.join(tempDir.path, 'kv.json')),
    dataDir: tempDir.path,
  );

  WorkflowRunControl newControl(WorkflowService service, {List<String> adminSenders = const []}) => WorkflowRunControl(
    workflows: service,
    isAdmin: GovernanceConfig(adminSenders: adminSenders).isAdmin,
    auditLogger: audit,
  );

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_run_approvals_wiring_');
    eventBus = EventBus();
    tasks = TaskService(InMemoryTaskRepository(), eventBus: eventBus);
    repository = InMemoryWorkflowRunRepository();
    audit = RecordingGuardAuditLogger();
    workflows = newService();
  });

  tearDown(() async {
    await workflows.dispose();
    await tasks.dispose();
    await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> hold(String id) async {
    final definition = WorkflowDefinition(
      name: 'approval-run',
      description: 'One approval gate',
      steps: const [
        WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
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
          '_approval.pending.stepId': 'gate',
          '_approval.pending.stepIndex': 0,
          'data': <String, dynamic>{},
          'variables': <String, dynamic>{},
        },
      ),
    );
  }

  group('HTTP resume and cancel through the wired control', () {
    Future<Response> post(WorkflowRunControl control, String path, {Object? body}) {
      final handler = workflowRoutes(workflows, tasks, InMemoryDefinitionSource(const []), runControl: control).call;
      return Future.value(
        handler(
          Request(
            'POST',
            Uri.parse('http://localhost$path'),
            headers: body == null ? const {} : {'content-type': 'application/json'},
            body: body == null ? null : jsonEncode(body),
          ),
        ),
      );
    }

    test(
      'are audited as web resolutions for a caller outside admin_senders, with statuses and bodies as before',
      () async {
        await hold('run-resume');
        await hold('run-cancel');
        final control = newControl(workflows, adminSenders: ['U-A']);

        final resumed = await post(control, '/api/workflows/runs/run-resume/resume');
        final cancelled = await post(
          control,
          '/api/workflows/runs/run-cancel/cancel',
          body: {'feedback': 'stale branch'},
        );
        final notWaiting = await post(control, '/api/workflows/runs/run-resume/resume');
        final missing = await post(control, '/api/workflows/runs/no-such-run/resume');

        expect(resumed.statusCode, 200);
        expect((jsonDecode(await resumed.readAsString()) as Map)['id'], 'run-resume');
        expect(cancelled.statusCode, 204);
        expect(notWaiting.statusCode, 409);
        final error = (jsonDecode(await notWaiting.readAsString()) as Map)['error'] as Map;
        expect(error['code'], 'INVALID_TRANSITION');
        expect(error['message'], contains('Cannot resume workflow in'));
        expect(missing.statusCode, 404);

        expect(audit.entries.map((e) => (e.hook, e.decision, e.tool, e.runId, e.channel, e.principal)), [
          ('web', 'allow', 'resume', 'run-resume', null, 'owner'),
          ('web', 'allow', 'cancel', 'run-cancel', null, 'owner'),
          ('web', 'deny', 'resume', 'run-resume', null, 'owner'),
          ('web', 'deny', 'resume', 'no-such-run', null, 'owner'),
        ]);
        expect((await repository.getById('run-cancel'))!.contextJson['gate.approval.feedback'], 'stale branch');
      },
    );

    test('a cancel of a settled run keeps its 409 and says why', () async {
      await hold('run-1');
      final control = newControl(workflows);
      await post(control, '/api/workflows/runs/run-1/cancel');

      final again = await post(control, '/api/workflows/runs/run-1/cancel');

      expect(again.statusCode, 409);
      expect(await again.readAsString(), contains('terminal state: cancelled'));
    });
  });

  test('a restart with the run still waiting leaves the same button live, and a new control resolves it', () async {
    await hold('run-1');
    final interaction = (await workflows.issueApprovalInteraction('run-1', 'gate'))!;
    await workflows.bindApprovalPost(
      'run-1',
      nonce: interaction.nonce,
      post: const WorkflowApprovalPost(
        channelType: 'googlechat',
        recipientId: 'spaces/AAA',
        messageId: 'spaces/AAA/messages/1',
      ),
    );
    await workflows.dispose();

    final restarted = newService();
    addTearDown(restarted.dispose);
    final result = await newControl(restarted).handleApproval(
      ChannelRunApprovalRequest(
        action: ChannelRunApprovalAction.approve,
        runId: 'run-1',
        stepId: 'gate',
        nonce: interaction.nonce,
        senderId: 'users/1',
        senderDisplayName: 'Ada',
        channelType: 'googlechat',
        postMessageId: 'spaces/AAA/messages/1',
      ),
    );

    expect(result, isA<ChannelRunApprovalResolved>());
    final resolution = WorkflowApprovalInteraction.of((await repository.getById('run-1'))!)!.resolution!;
    expect(resolution.source, WorkflowApprovalSource.button);
    expect(resolution.senderId, 'users/1');
  });
}
