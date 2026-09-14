import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/conversation/human_command_catalog.dart';
import 'package:dartclaw_runtime/src/conversation/product_conversation_search.dart';
import 'package:dartclaw_runtime/src/server.dart'
    show ServerCoreDeps, ServerObservabilityDeps, ServerTaskDeps, ServerTurnDeps, ServerWebDeps;
import 'package:dartclaw_runtime/src/server_composition.dart';
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnRunner;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:sqlite3/sqlite3.dart' hide Session;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('usage: conversation_loop_browser_process.dart <data-dir> <port>');
    exitCode = 64;
    return;
  }
  final dataDirectory = arguments.first;
  final port = int.parse(arguments.last);
  final turnState = openTurnStateStore(p.join(dataDirectory, 'turn_state.json'));
  final kv = KvService(filePath: p.join(dataDirectory, 'kv.json'));
  final messages = MessageService(baseDir: dataDirectory);
  final eventBus = EventBus();
  final sessions = SessionService(baseDir: dataDirectory, eventBus: eventBus);
  final projectDirectory = Directory(p.join(dataDirectory, 'fixture-docs'))..createSync(recursive: true);
  File(p.join(projectDirectory.path, 'reference.md')).writeAsStringSync('effective context reference');
  File(p.join(dataDirectory, 'TOOLS.md')).writeAsStringSync('Fixture browser behavior');
  final projectService = FakeProjectService(
    projects: [
      Project(
        id: 'fixture-docs',
        name: 'Fixture Docs',
        remoteUrl: '',
        localPath: projectDirectory.path,
        defaultBranch: 'main',
        status: ProjectStatus.ready,
        createdAt: DateTime.now(),
      ),
    ],
    defaultProjectId: 'fixture-docs',
  );
  final namedAgentSession = await sessions.createSession(
    workspace: AgentWorkspace.pinned(agentId: 'fixture-agent', directory: projectDirectory.path),
  );
  final historyFixture = await _seedHistoryFixture(sessions, messages, dataDirectory);
  final searchFixture = await seedSearchCommandFixture(sessions, messages, namedAgentSession, dataDirectory);
  final channelSession = await _seedExternalSession(
    sessions,
    messages,
    type: SessionType.channel,
    channelKey: 'signal:fixture-owner',
  );
  final cronSession = await _seedExternalSession(sessions, messages, type: SessionType.cron, provider: 'claude');
  final harness = _HistoryBrowserHarness();
  final secondaryHarness = FakeAgentHarness();
  final packageUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/dartclaw_runtime.dart'));
  final packageRoot = p.normalize(p.join(p.dirname(packageUri!.toFilePath()), '..'));
  initTemplates(p.join(packageRoot, 'lib', 'src', 'templates'));

  final runner = TurnRunner(
    turnLimits: const TurnLimitsConfig.defaults(),
    harness: harness,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: dataDirectory),
    sessions: sessions,
    turnState: turnState,
    kv: kv,
    eventBus: eventBus,
  );
  final executions = ExecutionCoordinator(
    providerCapacities: const {'acp': 1},
    primary: runner,
    admitExecution: (request) => runner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
    releaseAdmission: runner.releaseAdmission,
    createWorker: (request) async => TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: secondaryHarness,
      messages: messages,
      behavior: BehaviorFileService(workspaceDir: dataDirectory),
      sessions: sessions,
      turnState: turnState,
      kv: kv,
      eventBus: eventBus,
      providerId: request.providerId,
      executionPolicy: request.policy,
    ),
  );
  final turns = composeServerTurns(
    sessions: sessions,
    messages: messages,
    worker: harness,
    behavior: BehaviorFileService(workspaceDir: dataDirectory),
    kv: kv,
    executions: executions,
    sessionsForTurns: sessions,
  );
  final recoveredSessions = await turns.detectAndCleanOrphanedTurns();
  await turns.reserveTurn(
    channelSession.id,
    isHumanInput: true,
    promptScope: PromptScope.primary,
    origin: (channel: SessionType.channel.name, contact: null, group: false),
  );
  await turns.reserveTurn(
    cronSession.id,
    promptScope: PromptScope.primary,
    origin: (channel: SessionType.cron.name, contact: null, group: false),
  );
  final broadcast = SseBroadcast();
  final searchBackend = SqliteBackend(sqlite3.openInMemory());
  await SqliteSchemaGate.prepareSearch(searchBackend, storeName: 'search.db');
  final conversationIndex = SqliteFtsIndex(searchBackend, table: SqliteFtsTable.conversationChunks);
  await ConversationIndexProjection(
    sessions: sessions,
    messages: messages,
    configuredPrincipals: const {'owner', 'agent:fixture-agent', 'agent:fixture-agent-b', 'agent:fixture-search-owner'},
  ).populate(conversationIndex);
  final harnessFactory = HarnessFactory();
  final nativeSkillInventory = _BrowserNativeSkillInventory();
  final commandCatalog = HumanCommandCatalog(
    harnessFactory: harnessFactory,
    nativeSkills: ({required provider, required workspaceDir}) async =>
        provider == 'claude' ? nativeSkillInventory.entries : const [],
  );
  final server = composeServer(
    core: ServerCoreDeps(
      sessions: sessions,
      messages: messages,
      worker: harness,
      staticDir: p.join(packageRoot, 'lib', 'src', 'static'),
      kvService: kv,
      authEnabled: false,
      effectiveContextCapabilities: const {
        'claude': EffectiveContextCapabilities(model: true, effort: true),
        'acp': EffectiveContextCapabilities.unavailable,
      },
    ),
    turn: ServerTurnDeps(turns: turns, executions: executions),
    tasks: ServerTaskDeps(projectService: projectService),
    observability: ServerObservabilityDeps(sseBroadcast: broadcast, eventBus: eventBus),
    web: ServerWebDeps(
      conversationSearch: ProductConversationSearchService(
        search: ConversationSearchService(
          index: conversationIndex,
          userIds: const {'owner', 'agent:fixture-agent', 'agent:fixture-agent-b', 'agent:fixture-search-owner'},
        ),
        sessions: sessions,
        messages: messages,
      ),
      commandCatalog: commandCatalog,
    ),
  );
  final revokedViewers = File(p.join(dataDirectory, 'revoked-viewers.txt'));
  final handler = _fixtureHarnessControls(
    _fixtureControl(_revocationGuard(server.handler, revokedViewers), harness),
    primary: harness,
    secondary: secondaryHarness,
    sessions: sessions,
    nativeSkillInventory: nativeSkillInventory,
  );
  final httpServer = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, port);
  File(p.join(dataDirectory, 'conversation-browser-ready.json')).writeAsStringSync(
    jsonEncode({
      'port': httpServer.port,
      'recoveredSessions': recoveredSessions,
      'channelSessionId': channelSession.id,
      'cronSessionId': cronSession.id,
      'namedAgentSessionId': namedAgentSession.id,
      'historySessionId': historyFixture.sessionId,
      'historyOldMessageId': historyFixture.oldMessageId,
      'historyApprovalRequestId': historyFixture.approvalRequestId,
      'historyLiveApprovalRequestId': _HistoryBrowserHarness.approvalId,
      'inboxDraftSessionId': historyFixture.draftSessionId,
      'inboxDoneSessionId': historyFixture.doneSessionId,
      'inboxArchivedSessionId': historyFixture.archivedSessionId,
      'inboxLineageSessionId': historyFixture.lineageSessionId,
      'searchOwnerSessionId': searchFixture.ownerSessionId,
      'searchAgentASessionId': namedAgentSession.id,
      'searchAgentBSessionId': searchFixture.agentBSessionId,
      'searchSettledSessionId': searchFixture.settledSessionId,
      'searchArchivedSessionId': searchFixture.archivedSessionId,
      'searchExactMessageId': searchFixture.exactMessageId,
      'searchMarker': 's07-exact-unloaded-marker',
      'searchProjectAlpha': 's07-project-alpha',
      'searchProjectBeta': 's07-project-beta',
    }),
    flush: true,
  );
  await ProcessSignal.sigterm.watch().first;
  await httpServer.close(force: true);
  await executions.dispose();
  await turnState.dispose();
  await kv.dispose();
  await eventBus.dispose();
  await searchBackend.close();
}

Future<
  ({
    String ownerSessionId,
    String agentBSessionId,
    String settledSessionId,
    String archivedSessionId,
    String exactMessageId,
  })
>
seedSearchCommandFixture(SessionService sessions, MessageService messages, Session agentA, String dataDirectory) async {
  const projectAlpha = 's07-project-alpha';
  const projectBeta = 's07-project-beta';
  EffectiveConversationContext context(String projectId) => EffectiveConversationContext(
    projectId: projectId,
    directory: dataDirectory,
    referenceRoot: dataDirectory,
    provider: 'claude',
  );

  await sessions.updateConversationState(
    agentA.id,
    (await sessions.getConversationState(agentA.id)).stageContext(context(projectAlpha)),
  );
  await sessions.updateTitle(agentA.id, 'Search agent A');
  await messages.insertMessage(sessionId: agentA.id, role: 'assistant', content: 's07-agent-a-marker s07-scope-marker');
  final agentB = await sessions.createSession(
    provider: 'claude',
    workspace: AgentWorkspace.pinned(agentId: 'fixture-agent-b', directory: p.join(dataDirectory, 'agent-b')),
  );
  await sessions.updateConversationState(
    agentB.id,
    (await sessions.getConversationState(agentB.id)).stageContext(context(projectBeta)),
  );
  await sessions.updateTitle(agentB.id, 'Search agent B');
  await messages.insertMessage(sessionId: agentB.id, role: 'assistant', content: 's07-agent-b-marker');

  final owner = await sessions.createSession(
    provider: 'claude',
    workspace: AgentWorkspace.pinned(agentId: 'fixture-search-owner', directory: p.join(dataDirectory, 'search-owner')),
  );
  await sessions.updateConversationState(
    owner.id,
    (await sessions.getConversationState(owner.id)).stageContext(context(projectAlpha)),
  );
  await sessions.updateTitle(owner.id, 'Unloaded exact match');
  for (var index = 0; index < 180; index++) {
    final exact = index == 7 || index == 91 || index == 175;
    await messages.insertMessage(
      sessionId: owner.id,
      role: index.isEven ? 'user' : 'assistant',
      content: exact
          ? 'unsafe <img src=x onerror=globalThis.__s07Injected=true> s07-exact-unloaded-marker result $index'
          : index == 179
          ? 's07-scope-marker active owner result'
          : 'search filler $index',
    );
  }
  final exactMessage = (await messages.getMessages(owner.id))
      .firstWhere((message) => message.content.endsWith('result 7'));

  final settled = await sessions.createSession(provider: 'claude');
  await sessions.updateConversationState(
    settled.id,
    (await sessions.getConversationState(settled.id)).stageContext(context(projectAlpha)),
  );
  await sessions.updateTitle(settled.id, 'Settled search result');
  await messages.insertMessage(
    sessionId: settled.id,
    role: 'assistant',
    content: 's07-settled-marker s07-scope-marker',
  );
  final settledState = await sessions.getConversationState(settled.id);
  await sessions.updateInboxMetadata(
    id: settled.id,
    expectedConversationRevision: settledState.revision,
    settledAt: DateTime.utc(2026, 9, 14),
  );

  final archived = await sessions.createSession(type: SessionType.archive, provider: 'claude');
  await sessions.updateConversationState(
    archived.id,
    (await sessions.getConversationState(archived.id)).stageContext(context(projectBeta)),
  );
  await sessions.updateTitle(archived.id, 'Archived search result');
  await messages.insertMessage(
    sessionId: archived.id,
    role: 'assistant',
    content: 's07-archived-marker s07-scope-marker',
  );
  return (
    ownerSessionId: owner.id,
    agentBSessionId: agentB.id,
    settledSessionId: settled.id,
    archivedSessionId: archived.id,
    exactMessageId: exactMessage.id,
  );
}

Handler _fixtureHarnessControls(
  Handler inner, {
  required FakeAgentHarness primary,
  required FakeAgentHarness secondary,
  required SessionService sessions,
  required _BrowserNativeSkillInventory nativeSkillInventory,
}) {
  return (request) async {
    final segments = request.url.pathSegments;
    if (request.method == 'POST' &&
        segments.length == 3 &&
        segments[0] == '__fixture' &&
        segments[1] == 'native-skills' &&
        (segments[2] == 'enable' || segments[2] == 'disable')) {
      final sessionId = request.url.queryParameters['session_id'];
      if (sessionId == null || await sessions.getSession(sessionId) == null) {
        return Response.notFound('session missing');
      }
      nativeSkillInventory.enabled = segments[2] == 'enable';
      await sessions.updateConversationState(
        sessionId,
        (await sessions.getConversationState(sessionId)).bumpRevision(),
      );
      return Response.ok(
        jsonEncode({'enabled': nativeSkillInventory.enabled}),
        headers: const {'content-type': 'application/json'},
      );
    }
    if (request.method == 'POST' &&
        segments.length == 4 &&
        segments[0] == '__fixture' &&
        segments[1] == 'harness' &&
        segments[3] == 'complete') {
      final harness = segments[2] == 'primary' ? primary : secondary;
      harness.emit(SystemInitEvent(contextWindow: 200000));
      harness.completeSuccess(TurnResult(inputTokens: 0, outputTokens: 3));
      return Response.ok('{}', headers: {'content-type': 'application/json'});
    }
    if (request.method == 'GET' && segments.length == 2 && segments[0] == '__fixture' && segments[1] == 'harnesses') {
      return Response.ok(
        jsonEncode({
          'primary': {
            'turns': primary.turnCallCount,
            'sessionId': primary.lastSessionId,
            'directory': primary.lastDirectory,
            'model': primary.lastModel,
            'effort': primary.lastEffort,
          },
          'secondary': {
            'turns': secondary.turnCallCount,
            'sessionId': secondary.lastSessionId,
            'directory': secondary.lastDirectory,
            'model': secondary.lastModel,
            'effort': secondary.lastEffort,
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }
    return inner(request);
  };
}

final class _BrowserNativeSkillInventory {
  bool enabled = true;

  List<NativeSkillCatalogItem> get entries => enabled
      ? const [
          NativeSkillCatalogItem(name: 'review', description: 'Review the current change'),
          NativeSkillCatalogItem(name: 'help', description: 'Fixture collision skill'),
        ]
      : const [];
}

Future<
  ({
    String sessionId,
    String oldMessageId,
    String approvalRequestId,
    String draftSessionId,
    String doneSessionId,
    String archivedSessionId,
    String lineageSessionId,
  })
>
_seedHistoryFixture(SessionService sessions, MessageService messages, String dataDirectory) async {
  final identityFile = File(p.join(dataDirectory, 'history-fixture.json'));
  if (identityFile.existsSync()) {
    final json = jsonDecode(await identityFile.readAsString()) as Map<String, dynamic>;
    final sessionId = json['sessionId'] as String;
    if (await sessions.getSession(sessionId) != null) {
      return (
        sessionId: sessionId,
        oldMessageId: json['oldMessageId'] as String,
        approvalRequestId: json['approvalRequestId'] as String,
        draftSessionId: json['draftSessionId'] as String? ?? sessionId,
        doneSessionId: json['doneSessionId'] as String? ?? sessionId,
        archivedSessionId: json['archivedSessionId'] as String? ?? sessionId,
        lineageSessionId: json['lineageSessionId'] as String? ?? sessionId,
      );
    }
  }

  final now = DateTime.utc(2026, 9, 14, 12);
  final source = await sessions.createSession(provider: 'fixture');
  late Message oldMessage;
  for (var index = 0; index < 1998; index++) {
    final message = await messages.insertMessage(
      sessionId: source.id,
      role: index.isEven ? 'user' : 'assistant',
      content: 'Retained history message ${index + 1}',
    );
    if (index == 19) oldMessage = message;
  }
  final prompt = await messages.insertMessage(
    sessionId: source.id,
    role: 'user',
    content: 'Run the retained fixture tool',
    metadata: jsonEncode({
      'attachments': [
        {'id': '00000000-0000-4000-8000-000000000301', 'filename': 'fixture.txt', 'mediaType': 'text/plain'},
      ],
      'references': [
        {'type': 'session', 'id': source.id, 'label': 'Fixture conversation'},
      ],
    }),
  );
  const attachmentId = '00000000-0000-4000-8000-000000000301';
  final attachmentBytes = utf8.encode('retained fixture attachment');
  final attachmentDirectory = Directory(p.join(dataDirectory, source.id, 'attachments'))..createSync(recursive: true);
  await File(p.join(attachmentDirectory.path, '$attachmentId.data')).writeAsBytes(attachmentBytes);
  await File(p.join(attachmentDirectory.path, '$attachmentId.json')).writeAsString(
    jsonEncode({
      'id': attachmentId,
      'filename': 'fixture.txt',
      'mediaType': 'text/plain',
      'size': attachmentBytes.length,
      'digest': 'sha256:${sha256.convert(attachmentBytes)}',
      'state': 'ready',
    }),
  );
  await messages.insertMessage(
    sessionId: source.id,
    role: 'assistant',
    content: 'Partial output retained before failure.',
  );
  final claim = ConversationSubmissionClaim(
    submissionId: 'history-fixture-submission',
    revisionId: 'history-fixture-revision',
    messageId: prompt.id,
    attemptId: 'history-fixture-attempt',
    payloadDigest: 'history-fixture-digest',
    message: prompt.content,
    references: [
      {'type': 'session', 'id': source.id, 'label': 'Fixture conversation'},
    ],
    attachments: [
      ConversationAttachmentManifest(
        id: attachmentId,
        filename: 'fixture.txt',
        mediaType: 'text/plain',
        size: attachmentBytes.length,
        digest: 'sha256:${sha256.convert(attachmentBytes)}',
      ),
    ],
    commitState: SubmissionCommitState.committed,
    workState: ConversationWorkState.failed,
    turnId: 'history-fixture-turn',
    detail: 'fixture provider failed',
    createdAt: now,
    updatedAt: now,
  );
  const approvalId = 'history-fixture-approval';
  var state = ConversationState(
    submissions: [claim],
    records: [
      ConversationDisplayRecord(
        id: 'history-fixture-tool',
        attemptId: 'history-fixture-attempt',
        turnId: 'history-fixture-turn',
        kind: ConversationRecordKind.tool,
        state: ConversationRecordState.failed,
        label: 'shell',
        arguments: '{"authorization":"***","command":"fixture"}',
        result: 'partial fixture result\n[Display payload truncated]',
        isTruncated: true,
        elapsedMs: 1250,
        createdAt: now,
        updatedAt: now,
      ),
      ConversationDisplayRecord(
        id: approvalId,
        attemptId: 'history-fixture-attempt',
        turnId: 'history-fixture-turn',
        kind: ConversationRecordKind.approval,
        state: ConversationRecordState.pending,
        label: 'Write fixture file',
        arguments: '/workspace/fixture.txt',
        expiresAt: DateTime.utc(2099),
        createdAt: now,
        updatedAt: now,
      ),
    ],
  );
  final destination = await sessions.createSession(provider: 'fixture');
  final destinationMessage = await messages.insertMessage(
    sessionId: destination.id,
    role: 'user',
    content: 'Linked fixture branch',
  );
  state = state.putBranch(
    ConversationBranchLink(
      mutationId: 'history-fixture-branch',
      kind: ConversationBranchKind.fork,
      sourceSessionId: source.id,
      sourceMessageId: prompt.id,
      sourceAttemptId: claim.attemptId,
      destinationSessionId: destination.id,
      destinationMessageId: destinationMessage.id,
      createdAt: now,
    ),
  );
  await sessions.updateConversationState(source.id, state);

  final inboxSessions = <Session>[];
  for (var index = 0; index < 202; index++) {
    inboxSessions.add(await sessions.createSession(provider: 'fixture'));
  }
  final unread = inboxSessions[0];
  await sessions.updateTitle(unread.id, 'Unread build notes');
  await messages.insertMessage(sessionId: unread.id, role: 'assistant', content: 'Unread fixture result');

  final done = inboxSessions[1];
  await sessions.updateTitle(done.id, 'Completed release notes');
  await _seedCompletedConversation(sessions, messages, done.id, now);

  final settledDraft = inboxSessions[2];
  await sessions.updateTitle(settledDraft.id, 'Draft settled on another device');
  final settledRevision = await _seedCompletedConversation(sessions, messages, settledDraft.id, now);
  await sessions.updateInboxMetadata(
    id: settledDraft.id,
    expectedConversationRevision: settledRevision,
    settledAt: now,
  );
  for (final extraSettled in inboxSessions.skip(5).take(3)) {
    final revision = await _seedCompletedConversation(sessions, messages, extraSettled.id, now);
    await sessions.updateInboxMetadata(id: extraSettled.id, expectedConversationRevision: revision, settledAt: now);
  }

  final archived = inboxSessions[3];
  await sessions.updateTitle(archived.id, 'Archived incident review');
  await sessions.updateSessionType(archived.id, SessionType.archive);
  await sessions.updateTitle(
    inboxSessions[4].id,
    'A deliberately long conversation title that proves the flat inbox truncates safely without hiding its state',
  );

  final identity = {
    'sessionId': source.id,
    'oldMessageId': oldMessage.id,
    'approvalRequestId': approvalId,
    'draftSessionId': settledDraft.id,
    'doneSessionId': done.id,
    'archivedSessionId': archived.id,
    'lineageSessionId': destination.id,
  };
  await identityFile.writeAsString(jsonEncode(identity), flush: true);
  return (
    sessionId: source.id,
    oldMessageId: oldMessage.id,
    approvalRequestId: approvalId,
    draftSessionId: settledDraft.id,
    doneSessionId: done.id,
    archivedSessionId: archived.id,
    lineageSessionId: destination.id,
  );
}

Future<int> _seedCompletedConversation(
  SessionService sessions,
  MessageService messages,
  String sessionId,
  DateTime now,
) async {
  final message = await messages.insertMessage(
    sessionId: sessionId,
    role: 'assistant',
    content: 'Completed fixture result',
  );
  final submissionId = 'inbox-completed-$sessionId';
  final completed = (await sessions.getConversationState(sessionId)).put(
    ConversationSubmissionClaim(
      submissionId: submissionId,
      revisionId: 'revision-$submissionId',
      messageId: message.id,
      attemptId: 'attempt-$submissionId',
      payloadDigest: 'fixture',
      message: message.content,
      commitState: SubmissionCommitState.committed,
      workState: ConversationWorkState.completed,
      turnId: 'turn-$submissionId',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await sessions.updateConversationState(sessionId, completed);
  final read = await sessions.updateInboxMetadata(
    id: sessionId,
    expectedConversationRevision: completed.revision,
    readMessageCursor: message.cursor,
    attentionReadEventId: 'submission:$submissionId',
  );
  return read.state.revision;
}

Future<Session> _seedExternalSession(
  SessionService sessions,
  MessageService messages, {
  required SessionType type,
  String? channelKey,
  String? provider,
}) async {
  final existing = (await sessions.listSessions(type: type)).firstOrNull;
  if (existing != null) return existing;
  final session = await sessions.createSession(type: type, channelKey: channelKey, provider: provider);
  await messages.insertMessage(sessionId: session.id, role: 'user', content: '${type.name} fixture activity');
  return session;
}

Handler _revocationGuard(Handler inner, File revokedViewers) {
  return (request) {
    final viewer = request.headers['x-conversation-viewer'];
    if (viewer != null && revokedViewers.existsSync()) {
      final revoked = revokedViewers.readAsLinesSync().map((line) => line.trim()).toSet();
      if (revoked.contains(viewer)) return Response.forbidden('Viewer authorization revoked');
    }
    return inner(request);
  };
}

Handler _fixtureControl(Handler inner, _HistoryBrowserHarness harness) {
  return (request) {
    if (request.url.path == 'fixture/history-state') {
      return Response.ok(
        jsonEncode({'approvalResponses': harness.approvalResponses, 'lastApproved': harness.lastApproved}),
        headers: const {'content-type': 'application/json'},
      );
    }
    return inner(request);
  };
}

final class _HistoryBrowserHarness extends FakeAgentHarness
    implements HarnessTurnContextSink, HarnessToolApprovalResponder {
  static const approvalId = 'history-live-approval';
  HarnessTurnContext? _context;
  String? _pendingRequestId;
  int approvalResponses = 0;
  bool? lastApproved;

  @override
  void setTurnContext(HarnessTurnContext? context) => _context = context;

  @override
  Future<TurnResult> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    String? agentId,
    Map<String, dynamic>? mcpServers,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
  }) {
    final pending = super.turn(
      sessionId: sessionId,
      messages: messages,
      systemPrompt: systemPrompt,
      agentId: agentId,
      mcpServers: mcpServers,
      providerSessionId: providerSessionId,
      requestProviderSessionResume: requestProviderSessionResume,
      directory: directory,
      model: model,
      effort: effort,
      maxTurns: maxTurns,
      outputSchema: outputSchema,
    );
    final prompt = messages.lastOrNull?['content'];
    if (prompt == 'Live history approval proof') {
      Future<void>.microtask(() {
        final context = _context;
        if (context == null || !context.allowOperatorApproval) throw StateError('Live history approval is unavailable');
        emit(ToolUseEvent(toolName: 'fixture_tool', toolId: 'history-live-tool', input: const {'path': 'fixture.txt'}));
        emit(ToolResultEvent(toolId: 'history-live-tool', output: 'live fixture result', isError: false));
        _pendingRequestId = approvalId;
        emit(
          ToolApprovalWaitEvent(
            requestId: approvalId,
            toolName: 'Write fixture file',
            input: const {'path': '/workspace/fixture.txt'},
            operatorActionable: true,
            expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
          ),
        );
      });
    }
    return pending;
  }

  @override
  bool canResolveToolApproval({required String turnId, required String requestId}) =>
      _context?.turnId == turnId && _pendingRequestId == requestId;

  @override
  Future<void> resolveToolApproval({required String turnId, required String requestId, required bool approved}) async {
    if (!canResolveToolApproval(turnId: turnId, requestId: requestId)) throw StateError('Approval is unavailable');
    _pendingRequestId = null;
    approvalResponses += 1;
    lastApproved = approved;
    emit(ToolApprovalResolvedEvent(requestId: requestId, approved: approved));
    completeSuccess();
  }
}
