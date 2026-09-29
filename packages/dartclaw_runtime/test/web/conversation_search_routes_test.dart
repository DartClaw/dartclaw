import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/api/conversation_search_command_routes.dart';
import 'package:dartclaw_runtime/src/concurrency/session_mutation_coordinator.dart';
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart';
import 'package:dartclaw_runtime/src/conversation/human_command_catalog.dart';
import 'package:dartclaw_runtime/src/conversation/inbox_service.dart';
import 'package:dartclaw_runtime/src/conversation/product_conversation_search.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide FakeTurnManager, TurnManager;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

import '../api/api_test_helpers.dart';
import '../helpers/search_index_test_support.dart';
import '../session_turn_manager_test_support.dart';

void main() {
  test('owner search returns scoped totals and stable exact-message citations across principals', () async {
    final fixture = await _SearchRouteFixture.create();
    addTearDown(fixture.dispose);

    final response = await fixture.client.expectJsonObject(
      'GET',
      '/api/conversation-search?q=%3Cexact%3E&scope=global&lifecycle=all&request_token=newest',
    );

    expect(response['request_token'], 'newest');
    expect(response['total'], 2);
    final results = (response['results'] as List).cast<Map<String, dynamic>>();
    expect(results.map((hit) => hit['session_id']).toSet(), {fixture.owner.id, fixture.agent.id});
    for (final hit in results) {
      expect(hit['citation'], 'conversation:${hit['session_id']}/message:${hit['message_id']}');
      expect(hit['href'], contains('#message-${hit['message_id']}'));
      expect(hit['snippet'], contains('<exact>'));
      expect(hit['highlight_start'], greaterThanOrEqualTo(0));
    }
  });

  test('current and lifecycle scopes filter before totals', () async {
    final fixture = await _SearchRouteFixture.create();
    addTearDown(fixture.dispose);

    final current = await fixture.client.expectJsonObject(
      'GET',
      '/api/conversation-search?q=exact&scope=current&session_id=${fixture.owner.id}&lifecycle=active',
    );
    expect(current['total'], 1);
    expect(((current['results'] as List).single as Map)['session_id'], fixture.owner.id);

    final archived = await fixture.client.expectJsonObject(
      'GET',
      '/api/conversation-search?q=exact&scope=global&lifecycle=archived',
    );
    expect(archived['total'], 0);
  });

  test('product limit bounds returned candidates without truncating the scoped total', () async {
    final fixture = await _SearchRouteFixture.create();
    addTearDown(fixture.dispose);

    final response = await fixture.client.expectJsonObject(
      'GET',
      '/api/conversation-search?q=exact&scope=global&lifecycle=all&limit=1',
    );

    expect(response['total'], 2);
    expect(response['results'], hasLength(1));
  });

  test('search fails closed when the top-page session becomes ineligible during the bounded query', () async {
    final fixture = await _SearchRouteFixture.create();
    addTearDown(fixture.dispose);
    final raw = await ConversationSearchService(
      index: fixture.index,
      userIds: const {'owner', 'agent:a'},
    ).searchAdministrative('exact', sessionIds: {fixture.owner.id, fixture.agent.id}, limit: 1);
    final topSessionId = raw.hits.single.sessionId;
    fixture.sessions.revalidationMutation = () async {
      await fixture.sessions.updateSessionType(topSessionId, SessionType.archive);
    };

    final outcome = await fixture.product.find(query: 'exact', lifecycle: ConversationSearchLifecycle.active, limit: 1);

    expect(outcome.succeeded, isFalse);
    expect(outcome.failure, 'SEARCH_RESULTS_CHANGED');
    expect(outcome.results, isEmpty);
    expect(outcome.total, 0);
  });

  test('search fails closed when a non-page eligibility revision changes during the bounded query', () async {
    final fixture = await _SearchRouteFixture.create();
    addTearDown(fixture.dispose);
    final raw = await ConversationSearchService(
      index: fixture.index,
      userIds: const {'owner', 'agent:a'},
    ).searchAdministrative('exact', sessionIds: {fixture.owner.id, fixture.agent.id}, limit: 1);
    final nonPageSessionId = {fixture.owner.id, fixture.agent.id}.difference({raw.hits.single.sessionId}).single;
    fixture.sessions.revalidationMutation = () async {
      final state = await fixture.sessions.getConversationState(nonPageSessionId);
      await fixture.sessions.updateConversationState(nonPageSessionId, state.bumpRevision());
    };

    final outcome = await fixture.product.find(query: 'exact', limit: 1);

    expect(outcome.succeeded, isFalse);
    expect(outcome.failure, 'SEARCH_RESULTS_CHANGED');
    expect(outcome.results, isEmpty);
    expect(outcome.total, 0);
  });

  test('selected target is reauthorized and missing targets disclose no derivative', () async {
    final fixture = await _SearchRouteFixture.create();
    addTearDown(fixture.dispose);
    final message = (await fixture.messages.getMessages(fixture.agent.id)).single;
    await fixture.sessions.deleteSession(fixture.agent.id);

    expect(
      await fixture.client.expectJsonErrorCode(
        'GET',
        '/api/conversation-search/target?session_id=${fixture.agent.id}&message_id=${message.id}',
        status: 404,
      ),
      'SEARCH_TARGET_UNAVAILABLE',
    );
  });

  test('process-retained sessions remain outside search and exact-target navigation', () async {
    final fixture = await _SearchRouteFixture.create();
    addTearDown(fixture.dispose);
    final temporary = await fixture.sessions.createSession(retention: ConversationRetention.process);
    final message = await fixture.messages.insertMessage(
      sessionId: temporary.id,
      role: 'user',
      content: 'process-only exact marker',
    );
    await fixture.index.upsert([
      SearchDocument(
        id: message.id,
        chunks: [message.content],
        metadata: {'session_id': temporary.id, 'role': message.role},
        timestamp: message.createdAt,
      ),
    ], userId: 'owner');

    final search = await fixture.client.expectJsonObject(
      'GET',
      '/api/conversation-search?q=process-only&scope=global&lifecycle=all',
    );
    expect(search['total'], 0);
    expect(search['results'], isEmpty);
    expect(
      await fixture.client.expectJsonErrorCode(
        'GET',
        '/api/conversation-search/target?session_id=${temporary.id}&message_id=${message.id}',
        status: 404,
      ),
      'SEARCH_TARGET_UNAVAILABLE',
    );
  });
}

final class _SearchRouteFixture {
  new({
    required this.root,
    required this.index,
    required this.sessions,
    required this.messages,
    required this.owner,
    required this.agent,
    required this.product,
    required this.client,
  });

  final Directory root;
  final FullTextIndex index;
  final _RevalidationSessionService sessions;
  final MessageService messages;
  final Session owner;
  final Session agent;
  final ProductConversationSearchService product;
  final ApiRouteTestClient client;

  static Future<_SearchRouteFixture> create() async {
    final root = Directory.systemTemp.createTempSync('conversation_search_routes_');
    final sessions = _RevalidationSessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path, retentionForSession: sessions.retentionFor);
    final owner = await sessions.createSession();
    await sessions.updateTitle(owner.id, 'Owner conversation');
    final agent = await sessions.createSession(
      workspace: AgentWorkspace.pinned(agentId: 'a', directory: '${root.path}/agent-a'),
    );
    await sessions.updateTitle(agent.id, 'Agent conversation');
    final ownerMessage = await messages.insertMessage(
      sessionId: owner.id,
      role: 'user',
      content: 'owner <exact> marker',
    );
    final agentMessage = await messages.insertMessage(
      sessionId: agent.id,
      role: 'assistant',
      content: 'agent <exact> marker',
    );
    final index = await prepareMemoryIndex();
    SearchDocument document(Message message) => SearchDocument(
      id: message.id,
      chunks: [message.content],
      metadata: {'session_id': message.sessionId, 'role': message.role},
      timestamp: message.createdAt,
    );
    await index.upsert([document(ownerMessage)], userId: 'owner');
    await index.upsert([document(agentMessage)], userId: 'agent:a');

    final worker = FakeAgentHarness();
    final turns = FakeTurnManager(messages, worker);
    final mutations = SessionMutationCoordinator();
    final conversation = ConversationService(
      sessions: sessions,
      ownerWorkspaceDir: sessions.baseDir,
      messages: messages,
      turns: turns,
      mutations: mutations,
    );
    final inbox = ConversationInboxService(sessions: sessions, messages: messages, mutations: mutations);
    final product = ProductConversationSearchService(
      search: ConversationSearchService(index: index, userIds: const {'owner', 'agent:a'}),
      sessions: sessions,
      messages: messages,
    );
    final router = Router();
    registerConversationSearchCommandRoutes(
      router,
      sessions: sessions,
      messages: messages,
      conversation: conversation,
      inbox: inbox,
      turns: turns,
      sessionMutations: mutations,
      search: product,
      catalog: HumanCommandCatalog(harnessFactory: HarnessFactory()),
      contextCapabilities: const {},
      defaultProvider: 'claude',
    );
    final handler = localAdminMiddleware()(router.call);
    return _SearchRouteFixture(
      root: root,
      index: index,
      sessions: sessions,
      messages: messages,
      owner: owner,
      agent: agent,
      product: product,
      client: ApiRouteTestClient(handler),
    );
  }

  Future<void> dispose() async {
    await messages.dispose();
    root.deleteSync(recursive: true);
  }
}

final class _RevalidationSessionService extends SessionService {
  new({required super.baseDir});

  Future<void> Function()? revalidationMutation;
  var _listCalls = 0;

  @override
  Future<List<Session>> listSessions({
    SessionType? type,
    List<SessionType>? types,
    bool includeTaskSessions = false,
  }) async {
    _listCalls += 1;
    if (_listCalls == 2) {
      final mutation = revalidationMutation;
      revalidationMutation = null;
      await mutation?.call();
    }
    return super.listSessions(type: type, types: types, includeTaskSessions: includeTaskSessions);
  }
}
