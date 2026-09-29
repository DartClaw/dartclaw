import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/concurrency/session_mutation_coordinator.dart';
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart';
import 'package:dartclaw_runtime/src/turn_runner.dart' as runtime_runner;
import 'package:dartclaw_runtime/src/turn_manager.dart' as runtime;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';

void main() {
  late Directory root;
  late SessionService sessions;
  late MessageService messages;
  late FakeTurnManager turns;
  late String sessionId;
  late ConversationAdmission active;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('dartclaw_history_');
    sessions = SessionService(baseDir: root.path);
    messages = MessageService(baseDir: root.path);
    turns = FakeTurnManager(messages, FakeAgentHarness());
    sessionId = (await sessions.createSession()).id;
  });

  tearDown(() async {
    await messages.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('tool records retain redacted partial and terminal history exactly once', () async {
    final conversation = ConversationService(
      sessions: sessions,
      ownerWorkspaceDir: sessions.baseDir,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
    );
    active = await conversation.submit(
      sessionId: sessionId,
      submissionId: 'tool-history',
      revisionId: 'tool-history-r1',
      message: 'Run the tool',
      attachments: const [],
      references: const [],
    );
    final attemptId = active.submission.attemptId!;
    final turnId = active.submission.turnId!;
    await conversation.recordToolTransition(
      sessionId: sessionId,
      attemptId: attemptId,
      turnId: turnId,
      toolId: 'tool-1',
      toolName: 'shell',
      state: ConversationRecordState.running,
      arguments: {'authorization': 'Bearer secret-token', 'command': 'build'},
      result: 'partial output',
    );
    await conversation.recordToolTransition(
      sessionId: sessionId,
      attemptId: attemptId,
      turnId: turnId,
      toolId: 'tool-1',
      toolName: 'shell',
      state: ConversationRecordState.failed,
      result: List.filled(70000, 'x').join(),
      elapsedMs: 31,
    );
    await conversation.recordToolTransition(
      sessionId: sessionId,
      attemptId: attemptId,
      turnId: turnId,
      toolId: 'tool-1',
      toolName: 'shell',
      state: ConversationRecordState.running,
      arguments: const {'command': 'late duplicate'},
    );
    await expectLater(
      conversation.recordToolTransition(
        sessionId: sessionId,
        attemptId: attemptId,
        turnId: turnId,
        toolId: 'tool-1',
        toolName: 'different-tool',
        state: ConversationRecordState.failed,
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'HISTORY_IDENTITY_CONFLICT')),
    );
    await conversation.recordToolTransition(
      sessionId: sessionId,
      attemptId: attemptId,
      turnId: turnId,
      toolId: 'tool-1',
      toolName: 'shell',
      state: ConversationRecordState.failed,
      result: List.filled(70000, 'x').join(),
      elapsedMs: 31,
    );

    final restarted = ConversationService(
      sessions: sessions,
      ownerWorkspaceDir: sessions.baseDir,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
    );
    final record = (await restarted.snapshot(sessionId)).records.single;
    expect(record.id, 'tool-1');
    expect(record.state, ConversationRecordState.failed);
    expect(record.arguments, isNot(contains('late duplicate')));
    expect(record.arguments, isNot(contains('secret-token')));
    expect(record.arguments, contains('***'));
    expect(record.result, endsWith('[Display payload truncated]'));
    expect(record.elapsedMs, 31);
  });

  test('live tool history bounds input serialization before redaction', () async {
    final redactor = _HistoryRedactor();
    final conversation = ConversationService(
      sessions: sessions,
      ownerWorkspaceDir: sessions.baseDir,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      redactor: redactor,
    );
    final admitted = await conversation.submit(
      sessionId: sessionId,
      submissionId: 'bounded-history',
      revisionId: 'bounded-history-r1',
      message: 'Inspect the wide input',
      attachments: const [],
      references: const [],
    );
    await conversation.recordToolTransition(
      sessionId: sessionId,
      attemptId: admitted.submission.attemptId!,
      turnId: admitted.submission.turnId!,
      toolId: 'wide-input',
      toolName: 'inspect',
      state: ConversationRecordState.running,
      arguments: {'authorization': 'Bearer retained-secret', for (var i = 0; i < 512; i++) 'key$i': 'v' * (8 * 1024)},
    );
    expect(redactor.codeUnits, lessThan(256 * 1024));
    final record = (await conversation.snapshot(sessionId)).records.single;
    expect(record.isTruncated, isTrue);
    expect(record.arguments, isNot(contains('retained-secret')));
    expect(record.arguments!.length, lessThan(66 * 1024));
  });

  test('split history windows retain their owning attempt records without export duplicates', () async {
    final conversation = ConversationService(
      sessions: sessions,
      ownerWorkspaceDir: sessions.baseDir,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
    );
    final admitted = await conversation.submit(
      sessionId: sessionId,
      submissionId: 'split-history',
      revisionId: 'split-history-r1',
      message: 'Start a long answer',
      attachments: const [],
      references: const [],
    );
    await conversation.recordToolTransition(
      sessionId: sessionId,
      attemptId: admitted.submission.attemptId!,
      turnId: admitted.submission.turnId!,
      toolId: 'split-tool',
      toolName: 'shell',
      state: ConversationRecordState.succeeded,
      result: 'done',
    );
    final continuations = <Message>[];
    for (var index = 0; index < 201; index += 1) {
      continuations.add(
        await messages.insertMessage(sessionId: sessionId, role: 'assistant', content: 'Continuation $index'),
      );
    }
    var state = await sessions.getConversationState(sessionId);
    state = state.put(
      admitted.submission.copyWith(workState: ConversationWorkState.completed, updatedAt: DateTime.utc(2026, 9, 14)),
    );
    await sessions.updateConversationState(sessionId, state);
    final boundedMessages = _RejectingFullHistoryMessageService(baseDir: root.path);
    addTearDown(boundedMessages.dispose);
    final boundedConversation = ConversationService(
      sessions: sessions,
      ownerWorkspaceDir: sessions.baseDir,
      messages: boundedMessages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
    );

    final tail = await boundedConversation.historyWindow(sessionId, count: 1);
    expect((tail['messages'] as List).single['id'], continuations.last.id);
    expect((tail['records'] as List).single['id'], 'split-tool');
    final before = await boundedConversation.historyWindow(
      sessionId,
      count: 1,
      beforeCursor: continuations.last.cursor,
    );
    expect((before['messages'] as List).single['id'], continuations[199].id);
    expect((before['records'] as List).single['id'], 'split-tool');
    final around = await boundedConversation.historyWindow(sessionId, count: 3, aroundMessageId: continuations[100].id);
    expect((around['records'] as List).single['id'], 'split-tool');

    final exported = await boundedConversation.preparedExport(sessionId, attachmentAvailability: (_) => const {});
    expect((exported['messages'] as List), hasLength(202));
    expect((exported['records'] as List).where((record) => (record as Map)['id'] == 'split-tool'), hasLength(1));
  });

  test('approval state serializes competing decisions across expiry and mismatched identity', () async {
    var responses = 0;
    final conversation = ConversationService(
      sessions: sessions,
      ownerWorkspaceDir: sessions.baseDir,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      clock: () => DateTime.utc(2026, 9, 14, 12),
      approvalResponder: (respondingSessionId, turnId, requestId, approved) async {
        expect(respondingSessionId, sessionId);
        expect(turnId, isNotEmpty);
        expect(requestId, 'request-1');
        expect(approved, isTrue);
        responses += 1;
      },
      approvalValidator: (_, _, _) => true,
    );
    active = await conversation.submit(
      sessionId: sessionId,
      submissionId: 'approval-history',
      revisionId: 'approval-history-r1',
      message: 'Approve the tool',
      attachments: const [],
      references: const [],
    );
    final attemptId = active.submission.attemptId!;
    final turnId = active.submission.turnId!;
    await conversation.recordApprovalRequest(
      sessionId: sessionId,
      attemptId: attemptId,
      turnId: turnId,
      requestId: 'request-1',
      action: 'Write file',
      target: '/workspace/result.txt',
      expiresAt: DateTime.utc(2026, 9, 14, 12, 5),
    );
    final resolved = await Future.wait([
      conversation.resolveApproval(
        sessionId: sessionId,
        attemptId: attemptId,
        turnId: turnId,
        requestId: 'request-1',
        approved: true,
      ),
      conversation.resolveApproval(
        sessionId: sessionId,
        attemptId: attemptId,
        turnId: turnId,
        requestId: 'request-1',
        approved: true,
      ),
    ]);
    expect(responses, 1);
    expect(resolved.map((record) => record.state), everyElement(ConversationRecordState.approved));

    await expectLater(
      conversation.resolveApproval(
        sessionId: sessionId,
        attemptId: 'other-attempt',
        turnId: turnId,
        requestId: 'request-1',
        approved: true,
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'ATTEMPT_MISMATCH')),
    );
    await conversation.recordApprovalRequest(
      sessionId: sessionId,
      attemptId: attemptId,
      turnId: turnId,
      requestId: 'expired-request',
      action: 'Run command',
      target: 'deploy',
      expiresAt: DateTime.utc(2026, 9, 14, 11, 59),
    );
    final expired = await conversation.resolveApproval(
      sessionId: sessionId,
      attemptId: attemptId,
      turnId: turnId,
      requestId: 'expired-request',
      approved: true,
    );
    expect(expired.state, ConversationRecordState.expired);
    expect(responses, 1);
  });

  test('worker created after route wiring persists terminal tool history before settlement', () async {
    final worker = FakeAgentHarness();
    final coordinator = ExecutionCoordinator(
      providerCapacities: const {'codex': 1},
      admitExecution: (_) async {},
      releaseAdmission: (_) {},
      createWorker: (request) async => runtime_runner.TurnRunner(
        turnLimits: const TurnLimitsConfig.defaults(),
        harness: worker,
        messages: messages,
        sessions: sessions,
        behavior: BehaviorFileService(workspaceDir: root.path),
        providerId: request.providerId,
        executionPolicy: request.policy,
      ),
    );
    addTearDown(coordinator.dispose);
    final manager = runtime.TurnManager.fromCoordinator(
      coordinator: coordinator,
      turnLimits: const TurnLimitsConfig.defaults(),
      sessions: sessions,
    );
    sessionRoutes(sessions, messages, manager, worker, ownerWorkspaceDir: sessions.baseDir);
    final lease = (await coordinator.acquire(
      ExecutionRequest(
        surface: ExecutionSurface.workflow,
        providerId: 'codex',
        policy: const ExecutionPolicy.host(),
        sessionId: sessionId,
      ),
    ))!;
    addTearDown(lease.release);
    final turnId = await lease.runner.reserveAdmittedTurn(sessionId);
    final now = DateTime.now().toUtc();
    var state = await sessions.getConversationState(sessionId);
    state = state.put(
      ConversationSubmissionClaim(
        submissionId: 'worker-history',
        revisionId: 'worker-history-r1',
        messageId: '00000000-0000-4000-8000-000000000201',
        attemptId: '00000000-0000-4000-8000-000000000202',
        payloadDigest: 'fixture',
        message: 'worker history',
        commitState: SubmissionCommitState.committed,
        workState: ConversationWorkState.running,
        turnId: turnId,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await sessions.updateConversationState(sessionId, state);
    lease.runner.executeTurn(sessionId, turnId, const [
      {'role': 'user', 'content': 'worker history'},
    ]);
    await worker.turnInvoked;
    worker.emit(ToolUseEvent(toolName: 'worker_tool', toolId: 'worker-tool', input: const {'path': 'safe.txt'}));
    worker.emit(ToolResultEvent(toolId: 'worker-tool', output: 'done', isError: false));
    await pumpEventQueue();
    worker.completeSuccess();
    await lease.runner.waitForOutcome(sessionId, turnId);
    await lease.runner.waitForExecutionSettled(sessionId, turnId);
    final record = (await sessions.getConversationState(sessionId)).findRecord('worker-tool');
    expect(record?.state, ConversationRecordState.succeeded);
    expect(record?.result, 'done');
  });

  test('two viewers resolve the exact runtime approval once across expiry and revoked access', () async {
    final liveWorker = _OperatorApprovalHarness();
    final liveTurns = runtime.TurnManager(
      messages: messages,
      worker: liveWorker,
      behavior: BehaviorFileService(workspaceDir: root.path),
      sessions: sessions,
      turnLimits: const TurnLimitsConfig.defaults(),
    );
    final rawHandler = sessionRoutes(
      sessions,
      messages,
      liveTurns,
      liveWorker,
      ownerWorkspaceDir: sessions.baseDir,
    ).call;
    final handler = localAdminMiddleware()(rawHandler);
    final sendResponse = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/$sessionId/send'),
        headers: const {'content-type': 'application/json', 'accept': 'application/json'},
        body: jsonEncode({
          'message': 'Update the file',
          'submission_id': 'approval-live',
          'revision_id': 'approval-live-r1',
        }),
      ),
    );
    expect(sendResponse.statusCode, 202);
    final admission = jsonDecode(await sendResponse.readAsString()) as Map<String, dynamic>;
    final attemptId = admission['attempt_id'] as String;
    final turnId = admission['turn_id'] as String;
    await liveWorker.turnInvoked;
    expect(liveWorker.context?.allowOperatorApproval, isTrue);

    liveWorker.emit(
      ToolUseEvent(
        toolName: 'shell',
        toolId: 'live-tool',
        input: const {'authorization': 'Bearer runtime-secret', 'command': 'git status'},
      ),
    );
    await _eventually(() async {
      final record = (await sessions.getConversationState(sessionId)).findRecord('live-tool');
      return record?.state == ConversationRecordState.running;
    });
    liveWorker.emit(ToolResultEvent(toolId: 'live-tool', output: 'partial failure', isError: true));
    liveWorker.emit(ToolResultEvent(toolId: 'live-tool', output: 'partial failure', isError: true));
    await _eventually(() async {
      final record = (await sessions.getConversationState(sessionId)).findRecord('live-tool');
      return record?.state == ConversationRecordState.failed;
    });
    final liveTool = (await sessions.getConversationState(sessionId)).findRecord('live-tool')!;
    expect(liveTool.arguments, isNot(contains('runtime-secret')));
    expect(liveTool.result, 'partial failure');
    expect(
      (await sessions.getConversationState(sessionId)).records.where((record) => record.id == 'live-tool'),
      hasLength(1),
    );

    liveWorker.requestApproval(
      requestId: 'request-live',
      action: 'Write file',
      input: const {'path': '/workspace/result.txt'},
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );
    await _eventually(() async {
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions/$sessionId/conversation-state')),
      );
      final snapshot = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      return (snapshot['records'] as List).any((record) => (record as Map<String, dynamic>)['id'] == 'request-live');
    });

    Request decisionRequest() => Request(
      'POST',
      Uri.parse('http://localhost/api/sessions/$sessionId/approvals/request-live'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'attempt_id': attemptId, 'turn_id': turnId, 'decision': 'approve'}),
    );

    final responses = await Future.wait([
      Future<Response>.sync(() => handler(decisionRequest())),
      Future<Response>.sync(() => handler(decisionRequest())),
    ]);
    expect(responses.map((response) => response.statusCode), everyElement(200));
    final decisions = await Future.wait(responses.map((response) async => jsonDecode(await response.readAsString())));
    expect(decisions.map((decision) => decision['state']), everyElement('approved'));
    expect(liveWorker.responseCount, 1);
    expect(liveWorker.lastApproved, isTrue);

    liveWorker.requestApproval(
      requestId: 'request-expired',
      action: 'Run command',
      input: const {'command': 'stale'},
      expiresAt: DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
    );
    await _eventually(() async {
      final state = await sessions.getConversationState(sessionId);
      return state.findRecord('request-expired') != null;
    });
    final expired = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/$sessionId/approvals/request-expired'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'attempt_id': attemptId, 'turn_id': turnId, 'decision': 'approve'}),
      ),
    );
    expect(expired.statusCode, 200);
    expect((jsonDecode(await expired.readAsString()) as Map<String, dynamic>)['state'], 'expired');
    expect(liveWorker.responseCount, 1);

    liveWorker.requestApproval(
      requestId: 'request-revoked',
      action: 'Run command',
      input: const {'command': 'deploy'},
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );
    await _eventually(() async {
      final state = await sessions.getConversationState(sessionId);
      return state.findRecord('request-revoked') != null;
    });
    final unauthorized = await rawHandler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/$sessionId/approvals/request-revoked'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'attempt_id': attemptId, 'turn_id': turnId, 'decision': 'approve'}),
      ),
    );
    expect(unauthorized.statusCode, 403);
    expect(liveWorker.responseCount, 1);

    final mismatch = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/$sessionId/approvals/request-revoked'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'attempt_id': 'wrong-attempt', 'turn_id': turnId, 'decision': 'approve'}),
      ),
    );
    expect(mismatch.statusCode, 409);
    expect(liveWorker.responseCount, 1);

    final reject = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/$sessionId/approvals/request-revoked'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'attempt_id': attemptId, 'turn_id': turnId, 'decision': 'reject'}),
      ),
    );
    expect(reject.statusCode, 200);
    expect(liveWorker.responseCount, 2);
    expect(liveWorker.lastApproved, isFalse);

    liveWorker.completeSuccess();
    await liveTurns.waitForOutcome(sessionId, turnId);
    await liveTurns.executions.runners.single.waitForExecutionSettled(sessionId, turnId);
    await _eventually(() async {
      final claim = (await sessions.getConversationState(sessionId)).findSubmission('approval-live');
      return claim?.workState == ConversationWorkState.completed;
    });
  });

  test('uncertain approval delivery becomes terminal unavailable without replay after restart', () async {
    var responses = 0;
    final uncertain = ConversationService(
      sessions: sessions,
      ownerWorkspaceDir: sessions.baseDir,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      approvalValidator: (_, _, _) => true,
      approvalResponder: (_, _, _, _) async {
        responses += 1;
        throw StateError('wire outcome unknown');
      },
    );
    active = await uncertain.submit(
      sessionId: sessionId,
      submissionId: 'uncertain-approval',
      revisionId: 'uncertain-approval-r1',
      message: 'Approve once',
      attachments: const [],
      references: const [],
    );
    final attemptId = active.submission.attemptId!;
    final turnId = active.submission.turnId!;
    await uncertain.recordApprovalRequest(
      sessionId: sessionId,
      attemptId: attemptId,
      turnId: turnId,
      requestId: 'uncertain-request',
      action: 'Write file',
      target: '/workspace/result.txt',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );
    await expectLater(
      uncertain.resolveApproval(
        sessionId: sessionId,
        attemptId: attemptId,
        turnId: turnId,
        requestId: 'uncertain-request',
        approved: true,
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'APPROVAL_UNAVAILABLE')),
    );
    expect(responses, 1);
    expect(
      (await sessions.getConversationState(sessionId)).findRecord('uncertain-request')?.state,
      ConversationRecordState.unavailable,
    );
    final repeated = await uncertain.resolveApproval(
      sessionId: sessionId,
      attemptId: attemptId,
      turnId: turnId,
      requestId: 'uncertain-request',
      approved: true,
    );
    expect(repeated.state, ConversationRecordState.unavailable);
    expect(responses, 1);

    var persisted = await sessions.getConversationState(sessionId);
    final stranded = persisted
        .findRecord('uncertain-request')!
        .copyWith(state: ConversationRecordState.resolving, result: 'pending write');
    persisted = persisted.putRecord(stranded);
    await sessions.updateConversationState(sessionId, persisted);
    final restarted = ConversationService(
      sessions: sessions,
      ownerWorkspaceDir: sessions.baseDir,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      approvalValidator: (_, _, _) => true,
      approvalResponder: (_, _, _, _) async => responses += 1,
    );
    final recovered = await restarted.snapshot(sessionId);
    expect(recovered.findRecord('uncertain-request')?.state, ConversationRecordState.unavailable);
    expect(recovered.findRecord('uncertain-request')?.result, contains('could not be confirmed'));
    expect(responses, 1);
  });
}

Future<void> _eventually(Future<bool> Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Condition did not become true');
}

final class _RejectingFullHistoryMessageService extends MessageService {
  new({required super.baseDir});

  @override
  Future<List<Message>> getMessages(String sessionId) => throw StateError('History paging used the unbounded reader');
}

final class _OperatorApprovalHarness extends FakeAgentHarness
    implements HarnessTurnContextSink, HarnessToolApprovalResponder {
  HarnessTurnContext? context;
  String? _pendingRequestId;
  int responseCount = 0;
  bool? lastApproved;

  @override
  void setTurnContext(HarnessTurnContext? context) {
    this.context = context;
  }

  void requestApproval({
    required String requestId,
    required String action,
    required Map<String, dynamic> input,
    required DateTime expiresAt,
  }) {
    final active = context;
    if (active == null || !active.allowOperatorApproval) throw StateError('Operator approval is unavailable');
    _pendingRequestId = requestId;
    emit(
      ToolApprovalWaitEvent(
        requestId: requestId,
        toolName: action,
        input: input,
        operatorActionable: true,
        expiresAt: expiresAt,
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

final class _HistoryRedactor extends MessageRedactor {
  var codeUnits = 0;

  @override
  String redact(String input, {List<String> sensitiveValues = const []}) {
    codeUnits += input.length;
    return super.redact(input, sensitiveValues: sensitiveValues);
  }
}
