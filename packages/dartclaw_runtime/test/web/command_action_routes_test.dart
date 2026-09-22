import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
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
import '../session_turn_manager_test_support.dart';
import '../helpers/search_index_test_support.dart';

void main() {
  test('stale, malformed, unavailable, and unconfirmed actions have no side effect', () async {
    final fixture = await _ActionFixture.create();
    addTearDown(fixture.dispose);
    final before = (await fixture.sessions.listSessions()).length;

    expect(
      await fixture.client.expectJsonErrorCode(
        'POST',
        '/api/command-actions',
        json: {'command_id': 'built-in:new', 'identity_token': 'stale'},
        status: 409,
      ),
      'STALE_COMMAND_CONTEXT',
    );
    expect(
      await fixture.client.expectJsonErrorCode('POST', '/api/command-actions', json: const {}, status: 400),
      'INVALID_COMMAND_ACTION',
    );
    final catalog = await fixture.client.expectJsonObject('GET', '/api/command-catalog?surface=global');
    expect(
      await fixture.client.expectJsonErrorCode(
        'POST',
        '/api/command-actions',
        json: {'command_id': 'built-in:reset', 'identity_token': catalog['identity_token']},
        status: 409,
      ),
      'COMMAND_DISABLED',
    );
    expect((await fixture.sessions.listSessions()).length, before);
  });

  test('new and native skill selections use typed dispatch results', () async {
    final fixture = await _ActionFixture.create(nativeSkills: true);
    addTearDown(fixture.dispose);
    final sessionless = await fixture.client.expectJsonObject('GET', '/api/command-catalog?surface=global');
    final created = await fixture.client.expectJsonObject(
      'POST',
      '/api/command-actions',
      json: {'command_id': 'built-in:new', 'identity_token': sessionless['identity_token']},
      status: 201,
    );
    expect(created['action'], 'navigate');
    expect(created['href'], startsWith('/sessions/'));

    final session = await fixture.sessions.createSession(provider: 'claude');
    final sessionCatalog = await fixture.client.expectJsonObject(
      'GET',
      '/api/command-catalog?surface=global&session_id=${session.id}',
    );
    final skill = await fixture.client.expectJsonObject(
      'POST',
      '/api/command-actions',
      json: {
        'command_id': 'skill:review',
        'identity_token': sessionCatalog['identity_token'],
        'session_id': session.id,
      },
    );
    expect(skill, {'action': 'send_provider', 'message': '/review'});

    fixture.nativeInventory.clear();
    expect(
      await fixture.client.expectJsonErrorCode(
        'POST',
        '/api/command-actions',
        json: {
          'command_id': 'skill:review',
          'identity_token': sessionCatalog['identity_token'],
          'session_id': session.id,
        },
        status: 409,
      ),
      'STALE_COMMAND_CONTEXT',
    );
    final refreshed = await fixture.client.expectJsonObject(
      'GET',
      '/api/command-catalog?surface=global&session_id=${session.id}',
    );
    expect(refreshed['identity_token'], isNot(sessionCatalog['identity_token']));
    expect((refreshed['entries'] as List).where((entry) => (entry as Map)['id'] == 'skill:review'), isEmpty);
  });
}

final class _ActionFixture {
  new(this.root, this.sessions, this.messages, this.client, this.nativeInventory);

  final Directory root;
  final SessionService sessions;
  final MessageService messages;
  final ApiRouteTestClient client;
  final List<NativeSkillCatalogItem> nativeInventory;

  static Future<_ActionFixture> create({bool nativeSkills = false}) async {
    final root = Directory.systemTemp.createTempSync('command_action_routes_');
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path);
    final index = await prepareMemoryIndex();
    final worker = FakeAgentHarness();
    final turns = FakeTurnManager(messages, worker);
    final mutations = SessionMutationCoordinator();
    final conversation = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: mutations,
    );
    final inbox = ConversationInboxService(sessions: sessions, messages: messages, mutations: mutations);
    final nativeInventory = <NativeSkillCatalogItem>[
      if (nativeSkills) const NativeSkillCatalogItem(name: 'review', description: 'Review this change'),
    ];
    final catalog = HumanCommandCatalog(
      harnessFactory: HarnessFactory(),
      nativeSkills: nativeSkills
          ? ({required provider, required workspaceDir}) async => nativeInventory.toList(growable: false)
          : null,
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
      search: ProductConversationSearchService(
        search: ConversationSearchService(index: index),
        sessions: sessions,
        messages: messages,
      ),
      catalog: catalog,
      contextCapabilities: const {},
      defaultProvider: 'claude',
    );
    return _ActionFixture(
      root,
      sessions,
      messages,
      ApiRouteTestClient(localAdminMiddleware()(router.call)),
      nativeInventory,
    );
  }

  Future<void> dispose() async {
    await messages.dispose();
    root.deleteSync(recursive: true);
  }
}
