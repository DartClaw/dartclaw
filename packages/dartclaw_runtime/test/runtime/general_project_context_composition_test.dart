import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/concurrency/session_mutation_coordinator.dart';
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart';
import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_runtime/src/server_composition.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness, FakeProjectService;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness_wiring_fixture.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

void main() {
  late Directory root;
  late String launchDirectory;
  late DartclawConfig config;
  late EventBus events;
  StorageWiring? storage;
  SecurityWiring? security;
  HarnessWiring? harness;

  setUp(() async {
    launchDirectory = Directory.current.path;
    root = Directory.systemTemp.createTempSync('general_project_composition_');
    config = DartclawConfig(
      server: ServerConfig(dataDir: root.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
      security: const SecurityConfig(contentGuardFailOpen: true),
    );
    events = EventBus();
    Directory(config.workspaceDir).createSync(recursive: true);
    File(p.join(config.workspaceDir, 'SOUL.md')).writeAsStringSync('OWNER_SOUL_MARKER');
    File(p.join(config.workspaceDir, 'AGENTS.md')).writeAsStringSync('OWNER_AGENTS_MARKER');
    Directory(p.join(root.path, '.dartclaw')).createSync();
    File(p.join(root.path, '.dartclaw', 'AGENTS.md')).writeAsStringSync('SERVER_CWD_MARKER');
    Directory.current = root.path;
  });

  tearDown(() async {
    await harness?.executions.dispose();
    await security?.dispose();
    await storage?.dispose();
    Directory.current = launchDirectory;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('primary composed owner turns dispatch general workspace and explicit checkout', () async {
    expect(File(p.join(Directory.current.path, '.dartclaw', 'AGENTS.md')).readAsStringSync(), 'SERVER_CWD_MARKER');
    final checkout = Directory(p.join(root.path, 'checkout'))..createSync();
    File(p.join(checkout.path, 'AGENTS.md')).writeAsStringSync('CHECKOUT_AGENTS_MARKER');
    final project = Project(
      id: 'checkout',
      name: 'Checkout',
      remoteUrl: '',
      localPath: checkout.path,
      defaultBranch: 'main',
      status: ProjectStatus.ready,
      createdAt: DateTime.utc(2026, 9, 14),
    );
    storage = await wireTestStorage(config: config, eventBus: events, exitFn: _unexpectedExit);
    security = await wireTestSecurity(config: config, dataDir: root.path, eventBus: events, exitFn: _unexpectedExit);
    final primary = FakeAgentHarness(promptStrategy: PromptStrategy.append);
    final factory = HarnessFactory()..register('claude', (_) => primary);
    harness = await wireTestHarness(
      config: config,
      dataDir: root.path,
      harnessFactory: factory,
      exitFn: _unexpectedExit,
      storage: storage!,
      security: security!,
      eventBus: events,
      serverRefGetter: () => throw StateError('No logical-agent session in this test'),
    );
    final turns = composeServerTurns(
      sessions: storage!.sessions,
      messages: storage!.messages,
      worker: harness!.primaryHarness,
      behavior: harness!.behavior,
      executions: harness!.executions,
      sessionsForTurns: storage!.sessions,
      config: config,
    );
    final conversation = ConversationService(
      sessions: storage!.sessions,
      messages: storage!.messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      ownerWorkspaceDir: config.workspaceDir,
      projects: FakeProjectService(projects: [project], defaultProjectId: 'checkout'),
    );
    final session = await storage!.sessions.createSession();

    final general = await conversation.snapshot(session.id);
    expect(general.nextContext?.projectId, isNull);
    expect(general.nextContext?.referenceRoot, Directory(config.workspaceDir).resolveSymbolicLinksSync());
    expect(storage!.memoryContextForWorkspace(session.workspace)?.principal, 'owner');
    final first = await conversation.submit(
      sessionId: session.id,
      submissionId: 'general',
      revisionId: 'general-r1',
      message: 'General request',
      attachments: const [],
      references: const [],
    );
    expect(first.submission.admittedContext?.projectId, isNull);
    await primary.turnInvoked;
    expect(primary.lastDirectory, Directory(config.workspaceDir).resolveSymbolicLinksSync());
    expect(primary.lastSystemPrompt, contains('OWNER_SOUL_MARKER'));
    expect(primary.lastSystemPrompt, contains('OWNER_AGENTS_MARKER'));
    expect(primary.lastSystemPrompt, isNot(contains('SERVER_CWD_MARKER')));
    expect(primary.lastSystemPrompt, isNot(contains('CHECKOUT_AGENTS_MARKER')));
    expect(harness!.harnessConfig.appendSystemPrompt, isNot(contains('CHECKOUT_AGENTS_MARKER')));
    primary.completeSuccess();
    await conversation.drain();

    final settled = await conversation.snapshot(session.id);
    final moved = await conversation.updateContext(
      sessionId: session.id,
      expectedRevision: settled.revision,
      projectId: 'checkout',
      directory: checkout.path,
      provider: 'claude',
    );
    expect(moved.nextContext?.projectId, 'checkout');
    expect(primary.resetContinuitySessions, contains(session.id));
    final second = await conversation.submit(
      sessionId: session.id,
      submissionId: 'project',
      revisionId: 'project-r1',
      message: 'Project request',
      attachments: const [],
      references: const [],
    );
    expect(second.submission.admittedContext?.projectId, 'checkout');
    await _waitFor(() => primary.turnCallCount == 2);
    expect(primary.lastDirectory, checkout.resolveSymbolicLinksSync());
    expect(primary.lastSystemPrompt, contains('OWNER_SOUL_MARKER'));
    expect(primary.lastSystemPrompt, isNot(contains('SERVER_CWD_MARKER')));
    primary.completeSuccess();
    await conversation.drain();

    final projectState = await conversation.snapshot(session.id);
    final returned = await conversation.updateContext(
      sessionId: session.id,
      expectedRevision: projectState.revision,
      projectId: null,
      directory: config.workspaceDir,
      provider: 'claude',
    );
    expect(returned.nextContext?.projectId, isNull);
    expect(primary.resetContinuitySessions, [session.id, session.id]);
    await conversation.submit(
      sessionId: session.id,
      submissionId: 'general-again',
      revisionId: 'general-again-r1',
      message: 'Back to General chat',
      attachments: const [],
      references: const [],
    );
    await _waitFor(() => primary.turnCallCount == 3);
    expect(primary.lastDirectory, Directory(config.workspaceDir).resolveSymbolicLinksSync());
    expect(primary.lastSystemPrompt, contains('OWNER_AGENTS_MARKER'));
    expect(primary.lastSystemPrompt, isNot(contains('CHECKOUT_AGENTS_MARKER')));
    primary.completeSuccess();
    await conversation.drain();
  });
}

Future<void> _waitFor(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), isTrue);
}
