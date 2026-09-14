@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CallbackEmbeddingProvider, seedCanonicalMemory;
import 'package:test/test.dart';

import '../../../dartclaw_core/test/storage/postgres_live_support.dart';

void main() {
  test('runtime keeps owner and workspace memory plus conversations isolated in PostgreSQL FTS and pgvector', () async {
    await withPostgresBackend((backend, _) async {
      final root = Directory.systemTemp.createTempSync('workspace_memory_postgres_');
      final agentADir = '${root.path}/agent-a';
      final agentBDir = '${root.path}/agent-b';
      final config = _config(root, [_agent('a', agentADir), _agent('b', agentBDir)]);
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
      final agentASession = await sessions.createSession(workspace: _agent('a', agentADir).workspace);
      final agentBSession = await sessions.createSession(workspace: _agent('b', agentBDir).workspace);
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
        searchBackendFactory: (_) async => throw StateError('PostgreSQL must use the authoritative backend'),
        taskBackendFactory: (_) async => backend,
        embeddingProviderFactory: () => CallbackEmbeddingProvider(
          embedDocuments: (documents) async => [
            for (var index = 0; index < documents.length; index++) [1.0, index.toDouble()],
          ],
        ),
        exitFn: (code) => throw StateError('unexpected exit $code'),
      );
      try {
        await wiring.wire();
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

        final contextA = await wiring.memoryContextForCaller(sessionId: agentASession.id, agentId: 'a');
        await contextA.file.appendDailyLog('agent-a-postgres-incremental-marker');
        expect(
          (await memory.search('agent-a-postgres-incremental-marker', userId: 'agent:a')).single.chunk,
          contains('agent-a-postgres-incremental-marker'),
        );
        expect(await memory.search('agent-a-postgres-incremental-marker', userId: 'owner'), isEmpty);
        expect(await memory.search('agent-a-postgres-incremental-marker', userId: 'agent:b'), isEmpty);
      } finally {
        await wiring.messages.dispose();
        await wiring.dispose();
        if (root.existsSync()) root.deleteSync(recursive: true);
      }
    });
  });

  test('one invalid PostgreSQL workspace remains unavailable while healthy principals publish', () async {
    await withPostgresBackend((backend, _) async {
      final root = Directory.systemTemp.createTempSync('workspace_memory_postgres_failure_');
      final agentADir = '${root.path}/agent-a';
      final invalidDir = '${root.path}/agent-b';
      final config = _config(root, [_agent('a', agentADir), _agent('b', invalidDir)]);
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
      try {
        await wiring.wire();
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
        await wiring.messages.dispose();
        await wiring.dispose();
        if (root.existsSync()) root.deleteSync(recursive: true);
      }
    });
  });
}

AgentDefinition _agent(String id, String directory) => AgentDefinition(
  id: id,
  description: id,
  prompt: id,
  workspace: AgentWorkspace.pinned(agentId: id, directory: directory),
);

DartclawConfig _config(Directory root, List<AgentDefinition> agents) => DartclawConfig(
  server: ServerConfig(dataDir: root.path),
  database: const DatabaseConfig(backend: DatabaseBackendKind.postgres),
  search: const SearchConfig(backend: 'hybrid'),
  agent: AgentConfig(definitions: agents),
);
