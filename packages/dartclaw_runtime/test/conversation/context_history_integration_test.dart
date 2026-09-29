import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness, FakeProjectService;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test('queued context survives live tool approval and telemetry settlement', () async {
    final root = Directory.systemTemp.createTempSync('context_history_integration_');
    final dataDirectory = Directory('${root.path}/state')..createSync();
    final projectA = Directory('${root.path}/project-a')..createSync();
    final projectB = Directory('${root.path}/project-b')..createSync();
    File('${projectA.path}/TOOLS.md').writeAsStringSync('Lifecycle integration behavior');

    final sessions = SessionService(baseDir: dataDirectory.path);
    final messages = MessageService(baseDir: dataDirectory.path);
    final harness = _ApprovalHarness();
    final runner = TurnRunner(
      harness: harness,
      messages: messages,
      behavior: BehaviorFileService(workspaceDir: projectA.path, personalMemoryEnabled: false),
      sessions: sessions,
      turnLimits: const TurnLimitsConfig.defaults(),
      providerId: 'claude',
    );
    final coordinator = ExecutionCoordinator(
      providerCapacities: const {},
      primary: runner,
      admitExecution: (request) => runner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: runner.releaseAdmission,
      createWorker: (_) => throw StateError('This fixture uses the configured primary runner'),
    );
    final turns = TurnManager.fromCoordinator(
      coordinator: coordinator,
      turnLimits: const TurnLimitsConfig.defaults(),
      sessions: sessions,
    );
    final projects = FakeProjectService(
      localProject: _project('project-a', 'Project A', projectA.path),
      projects: [_project('project-b', 'Project B', projectB.path)],
      defaultProjectId: 'project-a',
    );
    final handler = localAdminMiddleware()(
      sessionRoutes(
        sessions,
        messages,
        turns,
        harness,
        projectService: projects,
        contextCapabilities: const {'claude': EffectiveContextCapabilities(model: true, effort: true)},
        ownerWorkspaceDir: sessions.baseDir,
      ).call,
    );
    addTearDown(() async {
      await coordinator.dispose();
      await messages.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final session = await sessions.createSession();
    var stateJson = await _jsonRequest(handler, 'GET', '/api/sessions/${session.id}/conversation-state', 200);
    stateJson = await _jsonRequest(
      handler,
      'PATCH',
      '/api/sessions/${session.id}/context',
      200,
      body: {
        'conversation_revision': stateJson['revision'],
        'project_id': 'project-a',
        'directory': projectA.path,
        'provider': 'claude',
        'model': 'opus',
        'effort': 'high',
      },
    );

    final active = await _jsonRequest(
      handler,
      'POST',
      '/api/sessions/${session.id}/send',
      202,
      body: const {
        'submission_id': 'context-a',
        'revision_id': 'context-a-r1',
        'message': 'Run the first turn under context A',
      },
    );
    final activeAttemptId = active['attempt_id'] as String;
    final activeTurnId = active['turn_id'] as String;
    await harness.turnInvoked;
    expect(harness.context?.allowOperatorApproval, isTrue);
    expect(harness.lastDirectory, projectA.resolveSymbolicLinksSync());
    expect(harness.lastModel, 'opus');
    expect(harness.lastEffort, 'high');

    harness.emit(
      ToolUseEvent(
        toolName: 'shell',
        toolId: 'context-tool',
        input: const {'authorization': 'Bearer lifecycle-secret', 'command': 'inspect'},
      ),
    );
    harness.emit(ToolResultEvent(toolId: 'context-tool', output: 'inspection complete', isError: false));
    harness.requestApproval(
      requestId: 'context-approval',
      action: 'Write file',
      input: const {'authorization': 'Bearer approval-secret', 'path': '/workspace/result.txt'},
    );
    await _eventually(() async {
      final state = await sessions.getConversationState(session.id);
      return state.findRecord('context-tool')?.state == ConversationRecordState.succeeded &&
          state.findRecord('context-approval')?.state == ConversationRecordState.pending;
    });

    stateJson = await _jsonRequest(handler, 'GET', '/api/sessions/${session.id}/conversation-state', 200);
    await _jsonRequest(
      handler,
      'PATCH',
      '/api/sessions/${session.id}/context',
      200,
      body: {
        'conversation_revision': stateJson['revision'],
        'project_id': 'project-a',
        'directory': projectA.path,
        'provider': 'claude',
        'model': 'sonnet',
        'effort': 'medium',
      },
    );
    final queued = await _jsonRequest(
      handler,
      'POST',
      '/api/sessions/${session.id}/send',
      202,
      body: const {
        'submission_id': 'context-b',
        'revision_id': 'context-b-r1',
        'message': 'Run the queued turn under context B',
      },
    );
    expect(queued['state'], 'queued');
    expect(queued['queue_id'], isNotNull);

    final whileActive = await sessions.getConversationState(session.id);
    expect(whileActive.currentContext?.projectId, 'project-a');
    expect(whileActive.currentContext?.model, 'opus');
    expect(whileActive.nextContext?.projectId, 'project-a');
    expect(whileActive.nextContext?.model, 'sonnet');
    expect(whileActive.findSubmission('context-a')?.admittedContext?.model, 'opus');
    expect(whileActive.findSubmission('context-b')?.admittedContext?.model, 'sonnet');

    Future<Map<String, dynamic>> approve() => _jsonRequest(
      handler,
      'POST',
      '/api/sessions/${session.id}/approvals/context-approval',
      200,
      body: {'attempt_id': activeAttemptId, 'turn_id': activeTurnId, 'decision': 'approve'},
    );

    final decisions = await Future.wait([approve(), approve()]);
    expect(decisions.map((decision) => decision['state']), everyElement('approved'));
    expect(harness.responseCount, 1);
    expect(harness.lastApproved, isTrue);

    harness.emit(SystemInitEvent(contextWindow: 200000));
    harness.completeSuccess(TurnResult(inputTokens: 37, outputTokens: 5));
    expect((await turns.waitForOutcome(session.id, activeTurnId)).status, TurnStatus.completed);
    await runner.waitForExecutionSettled(session.id, activeTurnId);
    await _eventually(() async => harness.turnCallCount == 2);

    expect(harness.lastDirectory, projectA.resolveSymbolicLinksSync());
    expect(harness.lastModel, 'sonnet');
    expect(harness.lastEffort, 'medium');

    final reloadedSessions = SessionService(baseDir: dataDirectory.path);
    final persisted = await reloadedSessions.getConversationState(session.id);
    final tool = persisted.findRecord('context-tool');
    final approval = persisted.findRecord('context-approval');
    final queuedClaim = persisted.findSubmission('context-b');

    expect(persisted.findSubmission('context-a')?.workState, ConversationWorkState.completed);
    expect(persisted.findSubmission('context-a')?.admittedContext?.model, 'opus');
    expect(queuedClaim?.workState, ConversationWorkState.running);
    expect(queuedClaim?.queueId, queued['queue_id']);
    expect(queuedClaim?.admittedContext?.projectId, 'project-a');
    expect(queuedClaim?.admittedContext?.model, 'sonnet');
    expect(persisted.queue.map((claim) => claim.submissionId), contains('context-b'));
    expect(tool?.state, ConversationRecordState.succeeded);
    expect(tool?.arguments, isNot(contains('lifecycle-secret')));
    expect(tool?.arguments, contains('***'));
    expect(tool?.result, 'inspection complete');
    expect(approval?.state, ConversationRecordState.approved);
    expect(approval?.arguments, isNot(contains('approval-secret')));
    expect(approval?.arguments, contains('***'));
    expect(persisted.telemetry?.source, 'claude');
    expect(persisted.telemetry?.availability, ContextMeasurementAvailability.measured);
    expect(persisted.telemetry?.usedTokens, 37);
    expect(persisted.telemetry?.contextWindowTokens, 200000);

    final queuedTurnId = queuedClaim!.turnId!;
    harness.completeSuccess(TurnResult(inputTokens: 11, outputTokens: 2));
    expect((await turns.waitForOutcome(session.id, queuedTurnId)).status, TurnStatus.completed);
    await runner.waitForExecutionSettled(session.id, queuedTurnId);
  });
}

Project _project(String id, String name, String directory) => Project(
  id: id,
  name: name,
  remoteUrl: '',
  localPath: directory,
  defaultBranch: 'main',
  status: ProjectStatus.ready,
  createdAt: DateTime.utc(2026, 9, 14),
);

Future<Map<String, dynamic>> _jsonRequest(
  Handler handler,
  String method,
  String path,
  int expectedStatus, {
  Map<String, dynamic>? body,
}) async {
  final response = await handler(
    Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: body == null ? const {} : const {'content-type': 'application/json', 'accept': 'application/json'},
      body: body == null ? null : jsonEncode(body),
    ),
  );
  final text = await response.readAsString();
  expect(response.statusCode, expectedStatus, reason: text);
  return jsonDecode(text) as Map<String, dynamic>;
}

Future<void> _eventually(Future<bool> Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt += 1) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Condition did not become true');
}

final class _ApprovalHarness extends FakeAgentHarness implements HarnessTurnContextSink, HarnessToolApprovalResponder {
  HarnessTurnContext? context;
  String? _pendingRequestId;
  int responseCount = 0;
  bool? lastApproved;

  @override
  void setTurnContext(HarnessTurnContext? context) {
    this.context = context;
  }

  void requestApproval({required String requestId, required String action, required Map<String, dynamic> input}) {
    final active = context;
    if (active == null || !active.allowOperatorApproval) throw StateError('Operator approval is unavailable');
    _pendingRequestId = requestId;
    emit(
      ToolApprovalWaitEvent(
        requestId: requestId,
        toolName: action,
        input: input,
        operatorActionable: true,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      ),
    );
  }

  @override
  bool canResolveToolApproval({required String turnId, required String requestId}) =>
      context?.turnId == turnId && _pendingRequestId == requestId;

  @override
  Future<void> resolveToolApproval({required String turnId, required String requestId, required bool approved}) async {
    if (!canResolveToolApproval(turnId: turnId, requestId: requestId)) throw StateError('Approval is unavailable');
    _pendingRequestId = null;
    responseCount += 1;
    lastApproved = approved;
    emit(ToolApprovalResolvedEvent(requestId: requestId, approved: approved));
  }
}
