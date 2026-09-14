@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show SkillIntrospector;
import 'package:dartclaw_workflow/testing.dart' show FakeProviderAuthPreflight;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../api/api_test_helpers.dart';
import '_fixtures/conversation_loop_browser_process.dart' show seedSearchCommandFixture;

void main() {
  const gatewayToken = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test('production runtime wires scoped search, refreshed skills, typed actions, and exact navigation', () async {
    final root = Directory.systemTemp.createTempSync('conversation_search_commands_production_');
    final configFile = File(p.join(root.path, 'dartclaw.yaml'))..writeAsStringSync('# fixture\n');
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'fixture-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(token: gatewayToken),
      server: ServerConfig(dataDir: root.path, claudeExecutable: Platform.resolvedExecutable),
    );
    final seeded = await _seedProductionState(config, root);
    final introspector = _MutableSkillIntrospector({'dartclaw-review'});
    final worker = _NativeFakeHarness();
    final harnessFactory = HarnessFactory()
      ..register('claude', (factoryConfig) => factoryConfig.cwd == '/' ? _NativeFakeHarness() : worker);
    final runtime = await DartclawRuntime.build(
      config,
      dataDir: root.path,
      port: 0,
      harnessFactory: harnessFactory,
      taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
      stderrLine: (_) {},
      exitFn: (code) => throw StateError('unexpected exit $code'),
      resolvedConfigPath: configFile.path,
      messageRedactor: MessageRedactor(),
      resolvedAssets: const ResolvedAssets.embedded(),
      runWorkflowSkillsBootstrap: false,
      skillIntrospector: introspector,
      providerAuthPreflight: FakeProviderAuthPreflight(),
    );
    addTearDown(() async {
      await runtime.shutdown();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final unauthenticated = ApiRouteTestClient(runtime.server!.handler);
    expect((await unauthenticated.request('GET', '/api/command-catalog?surface=global')).statusCode, 401);
    final client = ApiRouteTestClient(
      (request) => runtime.server!.handler(
        request.change(headers: {...request.headers, 'authorization': 'Bearer $gatewayToken'}),
      ),
    );

    final agentB = await client.expectJsonObject(
      'GET',
      '/api/conversation-search?q=s07-agent-b-marker&scope=global&lifecycle=all',
    );
    expect(agentB['total'], 1);
    expect(((agentB['results'] as List).single as Map)['session_id'], seeded.agentBSessionId);
    final project = await client.expectJsonObject(
      'GET',
      '/api/conversation-search?q=s07-exact-unloaded-marker&scope=global&lifecycle=active'
          '&project_id=fixture-project',
    );
    expect(project['total'], 1);
    expect(((project['results'] as List).single as Map)['session_id'], seeded.ownerSessionId);
    final settled = await client.expectJsonObject(
      'GET',
      '/api/conversation-search?q=s07-settled-marker&scope=global&lifecycle=settled',
    );
    expect(settled['total'], 1);
    final archived = await client.expectJsonObject(
      'GET',
      '/api/conversation-search?q=s07-archived-marker&scope=global&lifecycle=archived',
    );
    expect(archived['total'], 1);

    final target = await client.expectJsonObject(
      'GET',
      '/api/conversation-search/target?session_id=${seeded.ownerSessionId}'
          '&message_id=${seeded.exactMessageId}',
    );
    expect(target['href'], contains('message=${seeded.exactMessageId}'));
    final exactPage = await client.request('GET', (target['href'] as String).split('#').first);
    expect(exactPage.statusCode, 200);
    final exactHtml = await exactPage.readAsString();
    expect(exactHtml, contains('s07-exact-unloaded-marker'));
    expect(exactHtml, contains('message-${seeded.exactMessageId}'));

    final ownerCatalog = await _catalog(client, seeded.ownerSessionId);
    expect(
      (ownerCatalog['entries'] as List).map((entry) => (entry as Map)['id']),
      containsAll({
        'built-in:new',
        'built-in:reset',
        'built-in:stop',
        'built-in:status',
        'built-in:fork',
        'built-in:settle',
        'built-in:model',
        'built-in:effort',
        'built-in:help',
        'skill:dartclaw-review',
      }),
    );
    expect(
      await _action(client, ownerCatalog, 'built-in:status', seeded.ownerSessionId),
      containsPair('action', 'status'),
    );
    expect(await _action(client, ownerCatalog, 'built-in:model', seeded.ownerSessionId), {
      'action': 'open_context',
      'field': 'model',
    });
    expect(await _action(client, ownerCatalog, 'built-in:effort', seeded.ownerSessionId), {
      'action': 'open_context',
      'field': 'effort',
    });
    expect(await _action(client, ownerCatalog, 'built-in:help', seeded.ownerSessionId), {'action': 'show_help'});
    expect(await _action(client, ownerCatalog, 'skill:dartclaw-review', seeded.ownerSessionId), {
      'action': 'send_provider',
      'message': '/dartclaw-review',
    });

    introspector.available.clear();
    expect(
      await client.expectJsonErrorCode(
        'POST',
        '/api/command-actions',
        json: {
          'command_id': 'skill:dartclaw-review',
          'identity_token': ownerCatalog['identity_token'],
          'session_id': seeded.ownerSessionId,
        },
        status: 409,
      ),
      'STALE_COMMAND_CONTEXT',
    );
    final withoutSkill = await _catalog(client, seeded.ownerSessionId);
    expect(withoutSkill['identity_token'], isNot(ownerCatalog['identity_token']));
    expect(
      (withoutSkill['entries'] as List).where((entry) => (entry as Map)['id'] == 'skill:dartclaw-review'),
      isEmpty,
    );
    expect(introspector.calls, greaterThanOrEqualTo(3));

    final forkCatalog = await _catalog(client, seeded.ownerSessionId);
    final forked = await _action(
      client,
      forkCatalog,
      'built-in:fork',
      seeded.ownerSessionId,
      extra: {'source_message_id': seeded.exactMessageId, 'mutation_id': 'production-fixture-fork'},
    );
    expect(forked['href'], startsWith('/sessions/'));

    final settleCatalog = await _catalog(client, seeded.settleActionSessionId);
    expect(
      await _action(client, settleCatalog, 'built-in:settle', seeded.settleActionSessionId),
      containsPair('action', 'navigate'),
    );
    expect((await runtime.sessionService.getSession(seeded.settleActionSessionId))!.settledAt, isNotNull);

    final resetCatalog = await _catalog(client, seeded.resetActionSessionId);
    expect(
      await _action(
        client,
        resetCatalog,
        'built-in:reset',
        seeded.resetActionSessionId,
        extra: const {'confirmed': true},
      ),
      containsPair('action', 'navigate'),
    );
    expect(await runtime.sessionService.getSession(seeded.resetActionSessionId), isNotNull);
    expect(await runtime.messageService.getMessages(seeded.resetActionSessionId), isEmpty);

    final sessionlessCatalog = await client.expectJsonObject('GET', '/api/command-catalog?surface=global');
    final created = await client.expectJsonObject(
      'POST',
      '/api/command-actions',
      json: {'command_id': 'built-in:new', 'identity_token': sessionlessCatalog['identity_token']},
      status: 201,
    );
    expect(created['href'], startsWith('/sessions/'));

    final stopSession = await runtime.sessionService.createSession(provider: 'claude');
    final accepted = await client.request(
      'POST',
      '/api/sessions/${stopSession.id}/send',
      body: 'message=hold+this+turn',
      headers: const {'content-type': 'application/x-www-form-urlencoded', 'accept': 'application/json'},
    );
    expect(accepted.statusCode, 202);
    await worker.turnInvoked;
    final stopCatalog = await _catalog(client, stopSession.id);
    expect(await _action(client, stopCatalog, 'built-in:stop', stopSession.id), containsPair('action', 'refresh'));
    expect(worker.cancelCalled, isTrue);

    await runtime.sessionService.deleteSession(seeded.agentBSessionId);
    expect(
      await client.expectJsonErrorCode(
        'GET',
        '/api/conversation-search/target?session_id=${seeded.agentBSessionId}&message_id=missing',
        status: 404,
      ),
      'SEARCH_TARGET_UNAVAILABLE',
    );

    const unknown = '/unowned  exact bytes';
    final send = await client.request(
      'POST',
      '/api/sessions/${seeded.ownerSessionId}/send',
      body: 'message=%2Funowned++exact+bytes',
      headers: const {'content-type': 'application/x-www-form-urlencoded', 'accept': 'application/json'},
    );
    expect(send.statusCode, 202);
    expect((await runtime.messageService.getMessages(seeded.ownerSessionId)).last.content, unknown);
    await worker.turnInvoked;
    worker.completeSuccess();
  });
}

Future<
  ({
    String ownerSessionId,
    String agentBSessionId,
    String settledSessionId,
    String archivedSessionId,
    String exactMessageId,
    String settleActionSessionId,
    String resetActionSessionId,
  })
>
_seedProductionState(DartclawConfig config, Directory root) async {
  final sessions = SessionService(baseDir: config.sessionsDir);
  final messages = MessageService(baseDir: config.sessionsDir);
  final agentA = await sessions.createSession(
    provider: 'claude',
    workspace: AgentWorkspace.pinned(agentId: 'fixture-agent', directory: p.join(root.path, 'agent-a')),
  );
  final search = await seedSearchCommandFixture(sessions, messages, agentA, root.path);
  final ownerState = await sessions.getConversationState(search.ownerSessionId);
  await sessions.updateConversationState(
    search.ownerSessionId,
    ownerState.stageContext(
      EffectiveConversationContext(
        projectId: 'fixture-project',
        directory: root.path,
        referenceRoot: root.path,
        provider: 'claude',
      ),
    ),
  );
  final settleAction = await sessions.createSession(provider: 'claude');
  await messages.insertMessage(sessionId: settleAction.id, role: 'assistant', content: 'settle action fixture');
  final resetAction = await sessions.createSession(provider: 'claude');
  await messages.insertMessage(sessionId: resetAction.id, role: 'assistant', content: 'reset action fixture');
  await messages.dispose();

  final skill = File(p.join(root.path, '.claude', 'skills', 'dartclaw-review', 'SKILL.md'));
  skill.parent.createSync(recursive: true);
  skill.writeAsStringSync('---\ndescription: Review the current change\n---\n');
  return (
    ownerSessionId: search.ownerSessionId,
    agentBSessionId: search.agentBSessionId,
    settledSessionId: search.settledSessionId,
    archivedSessionId: search.archivedSessionId,
    exactMessageId: search.exactMessageId,
    settleActionSessionId: settleAction.id,
    resetActionSessionId: resetAction.id,
  );
}

Future<Map<String, dynamic>> _catalog(ApiRouteTestClient client, String sessionId) =>
    client.expectJsonObject('GET', '/api/command-catalog?surface=global&session_id=$sessionId');

Future<Map<String, dynamic>> _action(
  ApiRouteTestClient client,
  Map<String, dynamic> catalog,
  String commandId,
  String sessionId, {
  Map<String, dynamic> extra = const {},
}) => client.expectJsonObject(
  'POST',
  '/api/command-actions',
  json: {'command_id': commandId, 'identity_token': catalog['identity_token'], 'session_id': sessionId, ...extra},
);

final class _MutableSkillIntrospector implements SkillIntrospector {
  new(Set<String> available) : available = {...available};

  final Set<String> available;
  int calls = 0;

  @override
  Future<Set<String>> listAvailable({
    required String provider,
    String? executable,
    Map<String, dynamic> providerOptions = const <String, dynamic>{},
  }) async {
    calls++;
    return {...available};
  }
}

final class _NativeFakeHarness extends FakeAgentHarness
    implements EffectiveContextCapabilityProvider, NativeSkillCapabilityProvider {
  @override
  EffectiveContextCapabilities get effectiveContextCapabilities =>
      const EffectiveContextCapabilities(model: true, effort: true);

  @override
  bool get supportsNativeSkillInvocation => true;
}
