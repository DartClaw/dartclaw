@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show WorkspaceService;
import 'package:dartclaw_runtime/src/api/memory_routes.dart';
import 'package:dartclaw_runtime/src/auth/request_auth_context.dart';
import 'package:dartclaw_runtime/src/memory/memory_admin_service.dart';
import 'package:dartclaw_runtime/src/memory/memory_status_service.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart'
    show CallbackEmbeddingProvider, InMemoryFullTextIndex, openPreparedTaskBackend, seedCanonicalMemory;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../api/api_test_helpers.dart';

void main() {
  test('composed storage keeps default, A, B, helper, legacy, and removed authority distinct across restart', () async {
    final root = Directory.systemTemp.createTempSync('workspace_memory_isolation_');
    final agentA = _agent(root, 'a');
    final agentB = _agent(root, 'b');
    final helper = _agent(root, 'helper', tools: const {'web_search'});
    final config = _config(root, [agentA, agentB, helper]);
    await _prepare(config);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['owneralpha integration marker'],
      },
    );
    await seedCanonicalMemory(
      agentA.workspace!.directory,
      topics: const {
        'general': ['agentalpha integration marker'],
      },
    );
    await seedCanonicalMemory(
      agentB.workspace!.directory,
      topics: const {
        'general': ['agentbeta integration marker'],
      },
    );
    await seedCanonicalMemory(
      helper.workspace!.directory,
      topics: const {
        'general': ['helpergamma must not index'],
      },
    );
    final removedWorkspace = AgentWorkspace.managed(
      agentId: 'removed',
      dataDir: root.path,
      ownerWorkspaceDir: config.workspaceDir,
    );
    await WorkspaceService(dataDir: root.path).prepareManagedAgents([removedWorkspace]);
    await seedCanonicalMemory(
      removedWorkspace.directory,
      topics: const {
        'general': ['removedgamma workspace marker'],
      },
    );
    final removedBytes = File(p.join(removedWorkspace.directory, 'MEMORY.md')).readAsBytesSync();

    final sessions = SessionService(baseDir: config.sessionsDir);
    final messages = MessageService(baseDir: config.sessionsDir);
    final owner = await sessions.createSession();
    final a = await sessions.createSession(workspace: agentA.workspace);
    final b = await sessions.createSession(workspace: agentB.workspace);
    final helperSession = await sessions.createSession(workspace: helper.workspace);
    final legacy = await sessions.createSession();
    final removed = await sessions.createSession(workspace: removedWorkspace);
    await messages.insertMessage(sessionId: owner.id, role: 'user', content: 'ownerconvunique marker');
    await messages.insertMessage(sessionId: a.id, role: 'user', content: 'agentaconvunique marker');
    await messages.insertMessage(sessionId: b.id, role: 'user', content: 'agentbconvunique marker');
    await messages.insertMessage(sessionId: helperSession.id, role: 'user', content: 'helperconvunique marker');
    await messages.insertMessage(sessionId: legacy.id, role: 'user', content: 'legacyconvunique marker');
    await messages.insertMessage(sessionId: removed.id, role: 'user', content: 'removedconvunique marker');
    const excludedId = '99999999-9999-4999-8999-999999999999';
    final excludedAt = DateTime.utc(2026, 9, 14);
    await messages.insertMessageWithIdentity(
      sessionId: a.id,
      messageId: excludedId,
      role: 'user',
      content: 'retentionineligibleunique marker',
      createdAt: excludedAt,
      notifyObserver: false,
    );
    await sessions.updateConversationState(
      a.id,
      ConversationState().put(
        ConversationSubmissionClaim(
          submissionId: 'excluded-submission',
          revisionId: 'excluded-revision',
          messageId: excludedId,
          queueId: 'excluded-queue',
          payloadDigest: 'sha256:excluded',
          message: 'retentionineligibleunique marker',
          commitState: SubmissionCommitState.committed,
          workState: ConversationWorkState.queued,
          createdAt: excludedAt,
          updatedAt: excludedAt,
        ),
      ),
    );
    await messages.dispose();

    Future<void> verify(StorageWiring wiring) async {
      expect(wiring.memoryContexts.map((context) => context.principal).toSet(), {'owner', 'agent:a', 'agent:b'});
      final memoryEvidence = {'owner': 'owneralpha', 'agent:a': 'agentalpha', 'agent:b': 'agentbeta'};
      for (final evidence in memoryEvidence.entries) {
        expect(
          (await wiring.memoryIndex.search(evidence.value, userId: evidence.key)).single.chunk,
          contains(evidence.value),
        );
        for (final forbidden in memoryEvidence.keys.where((principal) => principal != evidence.key)) {
          expect(await wiring.memoryIndex.search(evidence.value, userId: forbidden), isEmpty);
        }
      }
      expect(
        (await wiring.memoryIndex.search('helpergamma', userId: 'agent:helper')).single.chunk,
        contains('helpergamma'),
      );
      expect(
        (await wiring.memoryIndex.search('removedgamma', userId: 'agent:removed')).single.chunk,
        contains('removedgamma'),
      );
      expect(
        (await wiring.conversationIndex.search('ownerconvunique', userId: 'owner')).single.chunk,
        'ownerconvunique marker',
      );
      expect(
        (await wiring.conversationIndex.search('legacyconvunique', userId: 'owner')).single.chunk,
        'legacyconvunique marker',
      );
      expect(
        (await wiring.conversationIndex.search('agentaconvunique', userId: 'agent:a')).single.chunk,
        'agentaconvunique marker',
      );
      expect(
        (await wiring.conversationIndex.search('agentbconvunique', userId: 'agent:b')).single.chunk,
        'agentbconvunique marker',
      );
      expect(
        (await wiring.conversationIndex.search('helperconvunique', userId: 'agent:helper')).single.chunk,
        'helperconvunique marker',
      );
      expect(
        (await wiring.conversationIndex.search('removedconvunique', userId: 'agent:removed')).single.chunk,
        'removedconvunique marker',
      );
      expect(await wiring.conversationIndex.search('agentaconvunique', userId: 'agent:b'), isEmpty);
      expect(await wiring.conversationIndex.search('retentionineligibleunique', userId: 'agent:a'), isEmpty);

      final contextA = await wiring.memoryContextForCaller(sessionId: a.id, agentId: 'a');
      final contextB = await wiring.memoryContextForCaller(sessionId: b.id, agentId: 'b');
      expect(wiring.memoryContextForWorkspace(agentA.workspace), same(contextA));
      expect(wiring.memoryContextForWorkspace(agentB.workspace), same(contextB));
      await contextA.file.appendDailyLog('agentdailyalpha marker');
      expect(await wiring.memoryIndex.search('agentdailyalpha', userId: 'agent:a'), isNotEmpty);
      expect(await wiring.memoryIndex.search('agentdailyalpha', userId: 'owner'), isEmpty);
      expect(await wiring.memoryIndex.search('agentdailyalpha', userId: 'agent:b'), isEmpty);
      await expectLater(
        wiring.memoryContextForCaller(sessionId: a.id, agentId: 'b'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('does not match'))),
      );
      await expectLater(
        wiring.memoryContextForCaller(sessionId: helperSession.id, agentId: 'helper'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('unavailable'))),
      );
      await expectLater(
        wiring.memoryContextForCaller(sessionId: removed.id, agentId: 'removed'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('unavailable'))),
      );
      expect(await wiring.memoryContextForCaller(sessionId: legacy.id, agentId: null), same(wiring.ownerMemoryContext));
    }

    final first = _wiring(config);
    try {
      await first.wire();
      await verify(first);
    } finally {
      await first.messages.dispose();
      await first.dispose();
    }
    final restarted = _wiring(config);
    try {
      await restarted.wire();
      await verify(restarted);
      expect(File(p.join(removedWorkspace.directory, 'MEMORY.md')).readAsBytesSync(), removedBytes);
    } finally {
      await restarted.messages.dispose();
      await restarted.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });

  test('one failed corpus job does not substitute owner or sibling authority', () async {
    final root = Directory.systemTemp.createTempSync('workspace_memory_failure_');
    final healthy = _agent(root, 'healthy');
    final broken = _agent(root, 'broken');
    final config = _config(root, [healthy, broken]);
    await _prepare(config);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['healthyowneralpha marker'],
      },
    );
    await seedCanonicalMemory(
      healthy.workspace!.directory,
      topics: const {
        'general': ['healthyagentalpha marker'],
      },
    );
    File(p.join(broken.workspace!.directory, 'MEMORY.md')).writeAsStringSync('## invalid\n- preview dialect\n');
    final wiring = _wiring(config);
    try {
      await wiring.wire();
      expect(wiring.memoryContexts.map((context) => context.principal).toSet(), {'owner', 'agent:healthy'});
      expect((await wiring.memoryIndex.search('healthyowneralpha', userId: 'owner')).single.chunk, contains('owner'));
      expect(
        (await wiring.memoryIndex.search('healthyagentalpha', userId: 'agent:healthy')).single.chunk,
        contains('agent'),
      );
      expect(await wiring.memoryIndex.search('preview', userId: 'agent:broken'), isEmpty);
    } finally {
      await wiring.messages.dispose();
      await wiring.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });

  test('unmarked cutover refuses before storage activity and preserves retained bytes', () async {
    final root = Directory.systemTemp.createTempSync('workspace_memory_cutover_');
    final blocked = _agent(root, 'blocked');
    final config = _config(root, [blocked]);
    final home = Directory(p.dirname(blocked.workspace!.directory))..createSync(recursive: true);
    final retained = File(p.join(home.path, 'retained.txt'))..writeAsStringSync('retained bytes');
    var backendOpened = false;
    final wiring = _wiring(config, onBackendOpen: () => backendOpened = true);

    await expectLater(
      wiring.wire(),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('no identity.json'))),
    );

    expect(backendOpened, isFalse);
    expect(retained.readAsStringSync(), 'retained bytes');
    expect(File(p.join(config.workspaceDir, 'MEMORY.md')).existsSync(), isFalse);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('owner administration isolates four corpora through CAS, retained removal, and restart', () async {
    final root = Directory.systemTemp.createTempSync('workspace_memory_admin_');
    final agentA = _agent(root, 'a');
    final agentB = _agent(root, 'b');
    final config = _config(root, [agentA, agentB]);
    final retained = AgentWorkspace.managed(
      agentId: 'removed',
      dataDir: root.path,
      ownerWorkspaceDir: config.workspaceDir,
    );
    await WorkspaceService(dataDir: root.path).prepareManagedAgents([agentA.workspace!, agentB.workspace!, retained]);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['collisiontoken owner-only marker'],
      },
    );
    await seedCanonicalMemory(
      agentA.workspace!.directory,
      topics: const {
        'general': ['collisiontoken agent-a-only marker'],
      },
      archive: {
        'general': [for (var index = 0; index < 21; index++) 'agent-a archived marker $index'],
      },
    );
    await seedCanonicalMemory(
      agentB.workspace!.directory,
      topics: const {
        'general': ['collisiontoken agent-b-only marker'],
      },
    );
    await seedCanonicalMemory(
      retained.directory,
      topics: const {
        'general': ['collisiontoken retained-only marker'],
      },
      observations: const {
        '2026-02-23': ['retained source observation marker'],
      },
    );
    final unmarked = Directory(p.join(root.path, 'agents', 'unmarked', 'workspace'))..createSync(recursive: true);
    await seedCanonicalMemory(
      unmarked.path,
      topics: const {
        'general': ['unmarked private marker'],
      },
    );
    final mismatched = Directory(p.join(root.path, 'agents', 'mismatched', 'workspace'))..createSync(recursive: true);
    File(p.join(p.dirname(agentA.workspace!.directory), 'identity.json'))
        .copySync(p.join(p.dirname(mismatched.path), 'identity.json'));
    await seedCanonicalMemory(
      mismatched.path,
      topics: const {
        'general': ['mismatched private marker'],
      },
    );
    final emptyRemoved = AgentWorkspace.managed(
      agentId: 'empty-removed',
      dataDir: root.path,
      ownerWorkspaceDir: config.workspaceDir,
    );
    await WorkspaceService(dataDir: root.path).prepareManagedAgents([emptyRemoved]);
    if (!Platform.isWindows) {
      Link(p.join(root.path, 'agents', 'alias')).createSync(p.dirname(retained.directory));
    }

    Future<({ApiRouteTestClient ownerOne, ApiRouteTestClient ownerTwo, ApiRouteTestClient denied, KvService kv})>
    clients(StorageWiring wiring) async {
      final kv = KvService(filePath: p.join(root.path, 'admin-kv.json'));
      final routes = memoryRoutes(
        statusService: MemoryStatusService(workspaceDir: config.workspaceDir, config: config, kvService: kv),
        workspaceDir: config.workspaceDir,
        adminService: MemoryAdminService(storage: wiring),
      );
      return (
        ownerOne: ApiRouteTestClient((request) => routes.call(withAdminAuthContext(request))),
        ownerTwo: ApiRouteTestClient((request) => routes.call(withAdminAuthContext(request))),
        denied: ApiRouteTestClient(routes.call),
        kv: kv,
      );
    }

    Future<Map<String, String>> selectors(ApiRouteTestClient owner) async {
      final inventory = await owner.expectJsonObject('GET', '/api/memory/corpora');
      final corpora = (inventory['corpora'] as List).cast<Map<String, dynamic>>();
      expect(corpora.map((item) => item['kind']).toSet(), {'default', 'configured', 'retained'});
      return {for (final item in corpora) item['principal'] as String: item['selector'] as String};
    }

    final first = _wiring(config);
    try {
      await first.wire();
      final api = await clients(first);
      try {
        final selected = await selectors(api.ownerOne);
        expect(selected.keys, {'owner', 'agent:a', 'agent:b', 'agent:removed'});
        final markers = {
          'owner': 'owner-only',
          'agent:a': 'agent-a-only',
          'agent:b': 'agent-b-only',
          'agent:removed': 'retained-only',
        };
        for (final principal in markers.keys) {
          final selector = selected[principal]!;
          final list = await api.ownerOne.expectJsonObject('GET', '/api/memory/entries?corpus=$selector');
          final hits = await api.ownerOne.expectJsonObject(
            'GET',
            '/api/memory/entries?corpus=$selector&q=collisiontoken',
          );
          expect((list['selected'] as Map)['principal'], principal);
          expect((list['health'] as Map)['state'], 'healthy');
          expect(list['collectionRevision'], isA<int>());
          expect((hits['entries'] as List), hasLength(1));
          expect((hits['entries'] as List).single['content'], contains(markers[principal]!));
          expect(hits['sharedKnowledge'], contains('Separate'));
          for (final other in markers.values.where((value) => value != markers[principal])) {
            for (final entry in list['entries'] as List) {
              expect((entry as Map)['content'], isNot(contains(other)));
            }
            for (final entry in hits['entries'] as List) {
              expect((entry as Map)['content'], isNot(contains(other)));
            }
          }
        }
        final listA = await api.ownerOne.expectJsonObject('GET', '/api/memory/entries?corpus=${selected['agent:a']}');
        expect((listA['entries'] as List).map((entry) => entry['state']).toSet(), {'active', 'archived'});
        expect((listA['entries'] as List), hasLength(20));
        expect(listA['hasNext'], isTrue);
        final nextA = await api.ownerOne.expectJsonObject(
          'GET',
          '/api/memory/entries?corpus=${selected['agent:a']}&page=2',
        );
        expect((nextA['entries'] as List), hasLength(2));
        expect(nextA['hasNext'], isFalse);
        final archivedSearch = await api.ownerOne.expectJsonObject(
          'GET',
          '/api/memory/entries?corpus=${selected['agent:a']}&q=archived',
        );
        final archivedNext = await api.ownerOne.expectJsonObject(
          'GET',
          '/api/memory/entries?corpus=${selected['agent:a']}&q=archived&page=2',
        );
        expect((archivedSearch['entries'] as List), hasLength(20));
        expect(archivedSearch['hasNext'], isTrue);
        expect((archivedNext['entries'] as List), hasLength(1));
        expect(archivedNext['hasNext'], isFalse);
        for (final forged in ['agent:a', '../a', 'unknown']) {
          expect(
            await api.ownerOne.expectJsonErrorCode('GET', '/api/memory/entries?corpus=$forged', status: 404),
            'CORPUS_UNAVAILABLE',
          );
        }

        final entryA = (listA['entries'] as List).singleWhere((entry) => entry['state'] == 'active') as Map;
        final idA = entryA['id'] as String;
        final edit = {
          'corpus': selected['agent:a'],
          'expectedCollectionRevision': listA['collectionRevision'],
          'expectedEntryRevision': entryA['entryRevision'],
          'topic': 'general',
          'content': 'collisiontoken agent-a-corrected marker',
          'state': 'active',
        };
        final changed = await api.ownerOne.expectJsonObject('POST', '/api/memory/entries/$idA/revise', json: edit);
        expect(changed['canonicalOutcome'], 'committed');
        expect(changed['indexOutcome'], 'current');
        expect((changed['currentEntry'] as Map)['content'], edit['content']);
        final stale = await api.ownerTwo.expectJsonObject(
          'POST',
          '/api/memory/entries/$idA/revise',
          json: edit,
          status: 409,
        );
        expect(stale['canonicalOutcome'], 'conflict');
        expect((stale['currentEntry'] as Map)['content'], edit['content']);
        expect(
          (await api.ownerOne.expectJsonObject(
            'GET',
            '/api/memory/entries?corpus=${selected['agent:a']}&q=corrected',
          ))['entries'],
          hasLength(1),
        );
        for (final principal in ['owner', 'agent:b', 'agent:removed']) {
          final list = await api.ownerOne.expectJsonObject('GET', '/api/memory/entries?corpus=${selected[principal]}');
          for (final entry in list['entries'] as List) {
            expect((entry as Map)['content'], isNot(contains('agent-a-corrected')));
          }
          expect((list['entries'] as List).single['content'], contains(markers[principal]!));
        }

        final currentA = await api.ownerOne.expectJsonObject(
          'GET',
          '/api/memory/entries/$idA?corpus=${selected['agent:a']}',
        );
        final currentEntry = currentA['entry'] as Map;
        final racing = [
          for (final suffix in ['first', 'second'])
            api.ownerOne.request(
              'POST',
              '/api/memory/entries/$idA/revise',
              json: {
                ...edit,
                'expectedCollectionRevision': currentA['collectionRevision'],
                'expectedEntryRevision': currentEntry['entryRevision'],
                'content': 'collisiontoken agent-a-$suffix winner',
              },
            ),
        ];
        final raced = await Future.wait(racing);
        expect(raced.map((response) => response.statusCode).toList()..sort(), [200, 409]);
        final afterRace = await api.ownerOne.expectJsonObject(
          'GET',
          '/api/memory/entries/$idA?corpus=${selected['agent:a']}',
        );
        expect((afterRace['entry'] as Map)['content'], contains('winner'));
        expect((afterRace['health'] as Map)['state'], 'healthy');

        final retainedList = await api.ownerOne.expectJsonObject(
          'GET',
          '/api/memory/entries?corpus=${selected['agent:removed']}',
        );
        final retainedEntry = (retainedList['entries'] as List).single as Map;
        final retainedId = retainedEntry['id'] as String;
        final remove = {
          'corpus': selected['agent:removed'],
          'expectedCollectionRevision': retainedList['collectionRevision'],
          'expectedEntryRevision': retainedEntry['entryRevision'],
          'reason': 'Owner removed outdated curated entry',
        };
        final removed = await api.ownerOne.expectJsonObject(
          'POST',
          '/api/memory/entries/$retainedId/remove',
          json: remove,
        );
        expect(removed['canonicalOutcome'], 'committed');
        expect(removed['indexOutcome'], 'current');
        expect(removed['currentEntry'], isNull);
        expect(removed['removalDisclosure'], contains('does not erase retained source observations'));
        final repeated = await api.ownerTwo.expectJsonObject(
          'POST',
          '/api/memory/entries/$retainedId/remove',
          json: remove,
          status: 409,
        );
        expect(repeated['canonicalOutcome'], 'conflict');
        final retainedCorpus = await first.adminMemoryContexts
            .singleWhere((context) => context.principal == 'agent:removed')
            .corpus
            .readCorpus();
        expect(retainedCorpus.observations.single.observations.single.content, 'retained source observation marker');
        expect(retainedCorpus.audit?.records, hasLength(1));
        expect(await first.memoryIndex.search('retained-only', userId: 'agent:removed'), isEmpty);

        for (final path in [
          '/api/memory/corpora',
          '/api/memory/entries?corpus=${selected['agent:a']}',
          '/api/memory/entries/$idA?corpus=${selected['agent:a']}',
        ]) {
          expect(await api.denied.expectJsonErrorCode('GET', path, status: 403), 'FORBIDDEN');
        }
        for (final kind in ['revise', 'remove']) {
          expect(
            await api.denied.expectJsonErrorCode('POST', '/api/memory/entries/$idA/$kind', json: edit, status: 403),
            'FORBIDDEN',
          );
        }
        final afterDenied = await api.ownerOne.expectJsonObject(
          'GET',
          '/api/memory/entries/$idA?corpus=${selected['agent:a']}',
        );
        expect(afterDenied['entry'], afterRace['entry']);
      } finally {
        await api.kv.dispose();
      }
    } finally {
      await first.messages.dispose();
      await first.dispose();
    }

    final restarted = _wiring(config);
    try {
      await restarted.wire();
      final api = await clients(restarted);
      try {
        final selected = await selectors(api.ownerOne);
        final a = await api.ownerOne.expectJsonObject('GET', '/api/memory/entries?corpus=${selected['agent:a']}');
        final b = await api.ownerOne.expectJsonObject('GET', '/api/memory/entries?corpus=${selected['agent:b']}');
        final removed = await api.ownerOne.expectJsonObject(
          'GET',
          '/api/memory/entries?corpus=${selected['agent:removed']}',
        );
        expect(
          (a['entries'] as List).singleWhere((entry) => entry['state'] == 'active')['content'],
          contains('winner'),
        );
        expect((b['entries'] as List).single['content'], contains('agent-b-only'));
        expect(removed['state'], 'empty');
        expect((removed['entries'] as List), isEmpty);
        expect((a['health'] as Map)['state'], 'healthy');
        expect((removed['health'] as Map)['state'], 'healthy');
        final retainedCorpus = await restarted.adminMemoryContexts
            .singleWhere((context) => context.principal == 'agent:removed')
            .corpus
            .readCorpus();
        expect(retainedCorpus.observations.single.observations.single.content, 'retained source observation marker');
      } finally {
        await api.kv.dispose();
      }
    } finally {
      await restarted.messages.dispose();
      await restarted.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });
}

AgentDefinition _agent(
  Directory root,
  String id, {
  Set<String> tools = const {'memory_apply', 'memory_observe', 'memory_search', 'memory_read', 'context_research'},
}) => AgentDefinition(
  id: id,
  description: id,
  prompt: id,
  allowedTools: tools,
  workspace: AgentWorkspace.managed(agentId: id, dataDir: root.path, ownerWorkspaceDir: p.join(root.path, 'workspace')),
);

DartclawConfig _config(Directory root, List<AgentDefinition> agents) => DartclawConfig(
  server: ServerConfig(dataDir: root.path),
  search: const SearchConfig(backend: 'hybrid'),
  agent: AgentConfig(definitions: agents),
);

Future<void> _prepare(DartclawConfig config) =>
    WorkspaceService(dataDir: config.server.dataDir)
        .prepareManagedAgents(config.agent.definitions.map((definition) => definition.workspace!).toList());

StorageWiring _wiring(DartclawConfig config, {void Function()? onBackendOpen}) {
  final indices = <PostgresFtsTable, InMemoryFullTextIndex>{};
  return StorageWiring(
    config: config,
    eventBus: EventBus(),
    taskBackendFactory: (_) async {
      onBackendOpen?.call();
      return openPreparedTaskBackend();
    },
    taskBackendIsPrepared: true,
    searchIndexFactory: (_, table, {required withinTransaction}) =>
        indices.putIfAbsent(table, InMemoryFullTextIndex.new),
    embeddingProviderFactory: () => CallbackEmbeddingProvider(
      embedDocuments: (documents) async => [
        for (var index = 0; index < documents.length; index++) [1.0, index.toDouble()],
      ],
    ),
    exitFn: (code) => throw StateError('unexpected exit $code'),
  );
}
