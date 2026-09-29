@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show WorkspaceService;
import 'package:dartclaw_runtime/src/mcp/citation_packet.dart' show CitationLayer;
import 'package:dartclaw_runtime/src/mcp/context_research_tool.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CallbackEmbeddingProvider, seedCanonicalMemory;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../dartclaw_core/test/storage/postgres_live_support.dart';

void main() {
  test('runtime keeps owner and workspace memory plus conversations isolated in PostgreSQL FTS and pgvector', () async {
    await withPostgresBackend((backend, _) async {
      final root = Directory.systemTemp.createTempSync('workspace_memory_postgres_');
      final agentA = _agent(root, 'a');
      final agentB = _agent(root, 'b');
      final config = _config(root, [agentA, agentB]);
      await _prepare(config);
      final agentADir = agentA.workspace!.directory;
      final agentBDir = agentB.workspace!.directory;
      await seedCanonicalMemory(
        config.workspaceDir,
        topics: const {
          'general': ['owner-postgres-runtime-marker'],
        },
      );
      await seedCanonicalMemory(
        agentADir,
        topics: const {
          'general': ['agent-a-postgres-runtime-marker'],
        },
      );
      await seedCanonicalMemory(
        agentBDir,
        topics: const {
          'general': ['agent-b-postgres-runtime-marker'],
        },
      );
      final sessions = SessionService(baseDir: config.sessionsDir);
      final messages = MessageService(baseDir: config.sessionsDir);
      final ownerSession = await sessions.createSession();
      final agentASession = await sessions.createSession(workspace: agentA.workspace);
      final agentBSession = await sessions.createSession(workspace: agentB.workspace);
      await messages.insertMessage(
        sessionId: ownerSession.id,
        role: 'user',
        content: 'owner-postgres-conversation-marker',
      );
      await messages.insertMessage(
        sessionId: agentASession.id,
        role: 'user',
        content: 'agent-a-postgres-conversation-marker',
      );
      await messages.insertMessage(
        sessionId: agentBSession.id,
        role: 'user',
        content: 'agent-b-postgres-conversation-marker',
      );
      await messages.dispose();
      final wiring = StorageWiring(
        config: config,
        eventBus: EventBus(),
        taskBackendFactory: (_) async => backend,
        embeddingProviderFactory: _vectorEnabled
            ? () => CallbackEmbeddingProvider(
                embedDocuments: (documents) async => [
                  for (var index = 0; index < documents.length; index++) [1.0, index.toDouble()],
                ],
              )
            : null,
        exitFn: (code) => throw StateError('unexpected exit $code'),
      );
      var wired = false;
      try {
        await wiring.wire();
        wired = true;
        final memory = PostgresFtsIndex(backend, table: PostgresFtsTable.memoryChunks, language: 'english');
        final conversation = PostgresFtsIndex(backend, table: PostgresFtsTable.conversationChunks, language: 'english');
        for (final evidence in [
          (
            principal: 'owner',
            memory: 'owner-postgres-runtime-marker',
            conversation: 'owner-postgres-conversation-marker',
          ),
          (
            principal: 'agent:a',
            memory: 'agent-a-postgres-runtime-marker',
            conversation: 'agent-a-postgres-conversation-marker',
          ),
          (
            principal: 'agent:b',
            memory: 'agent-b-postgres-runtime-marker',
            conversation: 'agent-b-postgres-conversation-marker',
          ),
        ]) {
          expect((await memory.search(evidence.memory, userId: evidence.principal)).single.chunk, evidence.memory);
          expect(
            (await conversation.search(evidence.conversation, userId: evidence.principal)).single.chunk,
            evidence.conversation,
          );
          for (final forbidden in {'owner', 'agent:a', 'agent:b'}..remove(evidence.principal)) {
            expect(await memory.search(evidence.memory, userId: forbidden), isEmpty);
            expect(await conversation.search(evidence.conversation, userId: forbidden), isEmpty);
          }
        }

        if (_vectorEnabled) {
          for (final principal in ['owner', 'agent:a', 'agent:b']) {
            expect(
              await PostgresVectorIndex(backend, table: VectorTable.memoryChunks).list(userId: principal),
              isNotEmpty,
            );
            expect(
              await PostgresVectorIndex(backend, table: VectorTable.conversationChunks).list(userId: principal),
              isNotEmpty,
            );
          }
        }

        final contextA = await wiring.memoryContextForCaller(sessionId: agentASession.id, agentId: 'a');
        await contextA.file.appendDailyLog('agent-a-postgres-incremental-marker');
        expect(
          (await memory.search('agent-a-postgres-incremental-marker', userId: 'agent:a')).single.chunk,
          contains('agent-a-postgres-incremental-marker'),
        );
        expect(await memory.search('agent-a-postgres-incremental-marker', userId: 'owner'), isEmpty);
        expect(await memory.search('agent-a-postgres-incremental-marker', userId: 'agent:b'), isEmpty);

        File(p.join(config.workspaceDir, 'wiki', 'shared.md'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('postgres shared wiki evidence');
        await wiring.kg.addFact(
          entity: 'postgres',
          predicate: 'scope',
          value: 'shared graph evidence',
          validFrom: '2026-09-22T00:00:00Z',
          source: 'shared fixture',
        );
        final candidates = <String, List<ContextResearchCandidate>>{};
        var activeCaller = '';
        final research = ContextResearchTool(
          scopeResolver: (caller) async {
            final principal = caller.agentId == 'main' ? 'owner' : 'agent:${caller.agentId}';
            final context = switch (caller.agentId) {
              'main' => wiring.ownerMemoryContext,
              'a' => contextA,
              _ => await wiring.memoryContextForCaller(sessionId: agentBSession.id, agentId: 'b'),
            };
            return ContextResearchScope.private(
              principal: principal,
              memorySearch: wiring.searchBackendFor(principal),
              memoryCorpus: context.corpus,
            );
          },
          wiki: WikiSearchSource(workspaceDir: config.workspaceDir),
          kg: wiring.kg,
          synthesizer: (request) async {
            candidates[activeCaller] = request.candidates;
            return jsonEncode({
              'statements': [
                {
                  'text': request.candidates.first.text,
                  'sourceRefs': [request.candidates.first.sourceRef.toJson()],
                },
              ],
              'sourceList': [request.candidates.first.sourceRef.toJson()],
              'degradedLayers': [],
              'noSourcesFound': false,
            });
          },
        );
        for (final caller in [
          (name: 'owner', authority: 'agent:main', session: ownerSession.id, agent: 'main'),
          (name: 'a', authority: 'agent:a', session: agentASession.id, agent: 'a'),
          (name: 'b', authority: 'agent:b', session: agentBSession.id, agent: 'b'),
        ]) {
          activeCaller = caller.name;
          await research.callWithContext(
            {'query': 'postgres'},
            McpCallerContext(
              authorityId: caller.authority,
              sourceEvent: 'postgres-contract',
              sessionId: caller.session,
              agentId: caller.agent,
            ),
          );
        }
        final privateMarkers = {
          'owner': 'owner-postgres-runtime-marker',
          'a': 'agent-a-postgres-runtime-marker',
          'b': 'agent-b-postgres-runtime-marker',
        };
        for (final caller in privateMarkers.entries) {
          final input = candidates[caller.key]!;
          expect(input.map((candidate) => candidate.text), contains(caller.value));
          for (final peer in privateMarkers.values.where((marker) => marker != caller.value)) {
            expect(input.map((candidate) => candidate.text), isNot(contains(peer)));
          }
          expect(
            input.map((candidate) => candidate.sourceRef.layer).toSet(),
            containsAll([CitationLayer.wiki, CitationLayer.kg]),
          );
        }
        expect(File(p.join(root.path, 'agents', 'a', 'identity.json')).readAsStringSync(), '{"agentId":"a"}\n');
      } finally {
        if (wired) {
          await wiring.messages.dispose();
          await wiring.dispose();
        }
        if (root.existsSync()) root.deleteSync(recursive: true);
      }
    });
  });

  test('one invalid PostgreSQL workspace remains unavailable while healthy principals publish', () async {
    await withPostgresBackend((backend, _) async {
      final root = Directory.systemTemp.createTempSync('workspace_memory_postgres_failure_');
      final agentA = _agent(root, 'a');
      final agentB = _agent(root, 'b');
      final config = _config(root, [agentA, agentB]);
      await _prepare(config);
      final agentADir = agentA.workspace!.directory;
      final invalidDir = agentB.workspace!.directory;
      await seedCanonicalMemory(
        config.workspaceDir,
        topics: const {
          'general': ['healthy-owner-postgres-marker'],
        },
      );
      await seedCanonicalMemory(
        agentADir,
        topics: const {
          'general': ['healthy-agent-postgres-marker'],
        },
      );
      File('$invalidDir/MEMORY.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('## invalid\n- preview dialect\n');
      final wiring = StorageWiring(
        config: config,
        eventBus: EventBus(),
        taskBackendFactory: (_) async => backend,
        exitFn: (code) => throw StateError('unexpected exit $code'),
      );
      var wired = false;
      try {
        await wiring.wire();
        wired = true;
        expect(wiring.memoryContexts.map((context) => context.principal).toSet(), {'owner', 'agent:a'});
        expect(
          (await wiring.memoryIndex.search('healthy-owner-postgres-marker', userId: 'owner')).single.chunk,
          contains('owner'),
        );
        expect(
          (await wiring.memoryIndex.search('healthy-agent-postgres-marker', userId: 'agent:a')).single.chunk,
          contains('agent'),
        );
        expect(await wiring.memoryIndex.search('preview', userId: 'agent:b'), isEmpty);
      } finally {
        if (wired) {
          await wiring.messages.dispose();
          await wiring.dispose();
        }
        if (root.existsSync()) root.deleteSync(recursive: true);
      }
    });
  });

  test('temporary owner and managed-agent markers never enter PostgreSQL projections', () async {
    await withPostgresBackend((backend, _) async {
      final root = Directory.systemTemp.createTempSync('workspace_temporary_postgres_');
      final agentA = _agent(root, 'a');
      final config = _config(root, [agentA]);
      await _prepare(config);
      final sessions = SessionService(baseDir: config.sessionsDir);
      final messages = MessageService(baseDir: config.sessionsDir, retentionForSession: sessions.retentionFor);
      final owner = await sessions.createSession();
      final durableAgent = await sessions.createSession(workspace: agentA.workspace);
      final temporaryOwner = await sessions.createSession(retention: ConversationRetention.process);
      final temporaryAgent = await sessions.createSession(
        retention: ConversationRetention.process,
        workspace: agentA.workspace,
      );
      await messages.insertMessage(sessionId: owner.id, role: 'user', content: 'ordinaryownercontrol');
      await messages.insertMessage(sessionId: durableAgent.id, role: 'user', content: 'ordinaryagentcontrol');
      await messages.insertMessage(sessionId: temporaryOwner.id, role: 'user', content: 'temporaryownerforbidden');
      await messages.insertMessage(sessionId: temporaryAgent.id, role: 'user', content: 'temporaryagentforbidden');
      await messages.dispose();
      final wiring = StorageWiring(
        config: config,
        eventBus: EventBus(),
        taskBackendFactory: (_) async => backend,
        embeddingProviderFactory: _vectorEnabled ? CallbackEmbeddingProvider.new : null,
        exitFn: (code) => throw StateError('unexpected exit $code'),
      );
      var wired = false;
      try {
        await wiring.wire();
        wired = true;
        final conversation = PostgresFtsIndex(backend, table: PostgresFtsTable.conversationChunks, language: 'english');
        expect(await conversation.search('ordinaryownercontrol', userId: 'owner'), isNotEmpty);
        expect(await conversation.search('ordinaryagentcontrol', userId: 'agent:a'), isNotEmpty);
        expect(await conversation.search('temporaryownerforbidden', userId: 'owner'), isEmpty);
        expect(await conversation.search('temporaryagentforbidden', userId: 'agent:a'), isEmpty);
        if (_vectorEnabled) {
          final vectors = PostgresVectorIndex(backend, table: VectorTable.conversationChunks);
          final records = [...await vectors.list(userId: 'owner'), ...await vectors.list(userId: 'agent:a')];
          expect(
            records.map((record) => record.documentId),
            everyElement(isNot(anyOf(temporaryOwner.id, temporaryAgent.id))),
          );
        }
      } finally {
        if (wired) {
          await wiring.messages.dispose();
          await wiring.dispose();
        }
        if (root.existsSync()) root.deleteSync(recursive: true);
      }
    });
  });
}

bool get _vectorEnabled => Platform.environment['DARTCLAW_TEST_SEARCH_BACKEND'] == 'hybrid';

AgentDefinition _agent(Directory root, String id) => AgentDefinition(
  id: id,
  description: id,
  prompt: id,
  workspace: AgentWorkspace.managed(agentId: id, dataDir: root.path, ownerWorkspaceDir: p.join(root.path, 'workspace')),
);

DartclawConfig _config(Directory root, List<AgentDefinition> agents) => DartclawConfig(
  server: ServerConfig(dataDir: root.path),
  database: const DatabaseConfig(),
  search: SearchConfig(backend: _vectorEnabled ? 'hybrid' : 'lexical'),
  agent: AgentConfig(definitions: agents),
);

Future<void> _prepare(DartclawConfig config) =>
    WorkspaceService(dataDir: config.server.dataDir)
        .prepareManagedAgents(config.agent.definitions.map((definition) => definition.workspace!).toList());
