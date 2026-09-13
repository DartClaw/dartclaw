import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:dartclaw_workflow/testing.dart' show FakeProviderAuthPreflight;
import 'package:test/test.dart';

void main() {
  late Directory dataDir;
  late DartclawConfig config;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('conversation_wiring_');
    config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
  });

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  test('DartclawRuntime.build reconstructs persisted conversation messages', () async {
    const sessionId = '11111111-1111-4111-8111-111111111111';
    const messageId = '22222222-2222-4222-8222-222222222222';
    const timestamp = '2026-01-01T00:00:00.000Z';
    final sessionDir = Directory('${config.sessionsDir}/$sessionId')..createSync(recursive: true);
    File(
      '${sessionDir.path}/meta.json',
    ).writeAsStringSync(jsonEncode({'id': sessionId, 'type': 'user', 'createdAt': timestamp, 'updatedAt': timestamp}));
    File('${sessionDir.path}/messages.ndjson').writeAsStringSync(
      '${jsonEncode({'id': messageId, 'sessionId': sessionId, 'role': 'assistant', 'content': 'runtimecomposition conversation evidence', 'createdAt': timestamp})}\n',
    );
    final configFile = File('${dataDir.path}/dartclaw.yaml')..writeAsStringSync('# fixture\n');
    final runtimeConfig = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
    );
    final runtime = await DartclawRuntime.build(
      runtimeConfig,
      dataDir: dataDir.path,
      port: 0,
      harnessFactory: HarnessFactory()..register('claude', (_) => FakeAgentHarness()),
      taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
      stderrLine: (_) {},
      exitFn: (code) => throw StateError('unexpected exit $code'),
      resolvedConfigPath: configFile.path,
      messageRedactor: MessageRedactor(),
      resolvedAssets: const ResolvedAssets.embedded(),
      runWorkflowSkillsBootstrap: false,
      providerAuthPreflight: FakeProviderAuthPreflight(),
    );
    await runtime.shutdown();
    final backend = await SqliteBackend.open(config.searchDbPath);
    try {
      final index = SqliteFtsIndex(backend, table: SqliteFtsTable.conversationChunks);
      final hits = await index.search('runtimecomposition', userId: 'owner');
      expect(hits.map((hit) => hit.id), [messageId]);
      expect(hits.single.metadata, {'session_id': sessionId, 'role': 'assistant'});
    } finally {
      await backend.close();
    }
  });

  test('a memory rebuild reprojects conversation rows from authoritative NDJSON', () async {
    final first = await _wire(config);
    final session = await first.sessions.createSession();
    final message = await first.messages.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content: 'reprojected conversation evidence',
    );
    await _waitForHit(first, 'reprojected');
    await _close(first);

    File(IndexHealthStore(workspaceDir: config.workspaceDir).path).deleteSync();
    final second = await _wire(config);
    try {
      final hits = await second.conversationSearch.search('reprojected');
      expect(hits.map((hit) => hit.messageId), [message.id]);
      expect(hits.single.sessionId, session.id);
    } finally {
      await _close(second);
    }
  });

  test('the memory fast path leaves existing conversation rows untouched', () async {
    final first = await _wire(config);
    await first.conversationIndex.upsert([
      SearchDocument(
        id: 'sentinel-conversation-row',
        chunks: const ['fastpathsentinel'],
        metadata: const {'session_id': 'sentinel-session', 'role': 'assistant'},
        timestamp: DateTime.utc(2026, 9, 9),
      ),
    ], userId: 'owner');
    await _close(first);

    final second = await _wire(config);
    try {
      expect(
        (await second.conversationSearch.search('fastpathsentinel')).single.messageId,
        'sentinel-conversation-row',
      );
    } finally {
      await _close(second);
    }
  });

  test('the degraded in-memory fallback still indexes appended messages', () async {
    final wiring = await _wire(
      config,
      searchBackendFactory: (_) async => throw const FileSystemException('injected search-store failure'),
    );
    try {
      final session = await wiring.sessions.createSession();
      final message = await wiring.messages.insertMessage(
        sessionId: session.id,
        role: 'user',
        content: 'fallback conversation evidence',
      );

      final hits = await _waitForHit(wiring, 'fallback');
      expect(hits.single.messageId, message.id);
      expect(wiring.conversationIndex, isNot(same(wiring.memoryIndex)));
    } finally {
      await _close(wiring);
    }
  });
}

Future<StorageWiring> _wire(DartclawConfig config, {DatabaseBackendFactory? searchBackendFactory}) async {
  final wiring = StorageWiring(
    config: config,
    eventBus: EventBus(),
    searchBackendFactory: searchBackendFactory ?? SqliteBackend.open,
    taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
    exitFn: (code) => throw StateError('unexpected exit $code'),
  );
  await wiring.wire();
  return wiring;
}

Future<List<ConversationHit>> _waitForHit(StorageWiring wiring, String query) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final hits = await wiring.conversationSearch.search(query);
    if (hits.isNotEmpty) return hits;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Conversation index did not expose "$query" before the deadline');
}

Future<void> _close(StorageWiring wiring) async {
  await wiring.messages.dispose();
  await wiring.dispose();
}
