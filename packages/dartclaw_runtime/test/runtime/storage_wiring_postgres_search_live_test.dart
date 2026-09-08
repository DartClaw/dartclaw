@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/testing.dart' show FakeProviderAuthPreflight;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../../../dartclaw_core/test/storage/postgres_live_support.dart';

const _configuredDsn = 'postgresql://runtime:RuntimeSearchSecretX9@injected.invalid/dartclaw';

void main() {
  test('unknown PostgreSQL language aborts before search services are composed', () async {
    await withPostgresBackend((backend, _) async {
      final dataDir = Directory.systemTemp.createTempSync('postgres_runtime_language_');
      final config = _config(dataDir, _configuredDsn, ftsLanguage: 'klingon');
      await seedCanonicalMemory(config.workspaceDir);
      final configFile = File('${dataDir.path}/dartclaw.yaml')..writeAsStringSync('# test\n');
      final records = <LogRecord>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);
      var taskOpens = 0;
      var searchOpens = 0;
      var serverCompositions = 0;
      Object? error;
      DartclawRuntime? runtime;
      try {
        runtime = await DartclawRuntime.build(
          config,
          dataDir: dataDir.path,
          port: 0,
          harnessFactory: _harnessFactory(),
          taskBackendFactory: (_) async {
            taskOpens++;
            return backend;
          },
          searchBackendFactory: (_) async {
            searchOpens++;
            throw StateError('PostgreSQL search must not open a separate backend');
          },
          serverFactory: (server) {
            serverCompositions++;
            return server;
          },
          stderrLine: (_) {},
          exitFn: (code) => throw _RuntimeExit(code),
          resolvedConfigPath: configFile.path,
          messageRedactor: MessageRedactor(),
          resolvedAssets: const ResolvedAssets.embedded(),
          runWorkflowSkillsBootstrap: false,
          providerAuthPreflight: FakeProviderAuthPreflight(),
        );
        error = StateError('Expected runtime startup to fail');
      } catch (caught) {
        error = caught;
      } finally {
        await runtime?.shutdown();
        await subscription.cancel();
        Logger.root.level = previousLevel;
      }

      final observable = [
        '$error',
        for (final record in records) '${record.message}\n${record.error ?? ''}',
      ].join('\n');
      expect(error, isA<_RuntimeExit>().having((value) => value.code, 'code', 1));
      expect(taskOpens, 1);
      expect(searchOpens, 0);
      expect(serverCompositions, 0);
      expect(observable, contains('database.fts_language'));
      expect(observable, contains('klingon'));
      expect(observable, contains('english'));
      expect(observable, contains('swedish'));
      expect(observable, isNot(contains(_configuredDsn)));
      final userInfo = Uri.parse(_configuredDsn).userInfo;
      if (userInfo.isNotEmpty) expect(observable, isNot(contains(userInfo)));
      _expectNoDatabaseFiles(dataDir);
      dataDir.deleteSync(recursive: true);
    });
  });

  test('post-commit memory projection feeds search status and the Knowledge Hub', () async {
    await withPostgresBackend((backend, _) async {
      final dataDir = Directory.systemTemp.createTempSync('postgres_runtime_search_');
      final config = _config(dataDir, _configuredDsn);
      await seedCanonicalMemory(config.workspaceDir);
      final configFile = File('${dataDir.path}/dartclaw.yaml')..writeAsStringSync('# test\n');
      var searchOpens = 0;
      DartclawRuntime? runtime;
      try {
        runtime = await DartclawRuntime.build(
          config,
          dataDir: dataDir.path,
          port: 0,
          harnessFactory: _harnessFactory(),
          taskBackendFactory: (_) async => backend,
          searchBackendFactory: (_) async {
            searchOpens++;
            throw StateError('PostgreSQL search must use the authoritative backend');
          },
          stderrLine: (_) {},
          exitFn: _unexpectedExit,
          resolvedConfigPath: configFile.path,
          messageRedactor: MessageRedactor(),
          resolvedAssets: const ResolvedAssets.embedded(),
          runWorkflowSkillsBootstrap: false,
          providerAuthPreflight: FakeProviderAuthPreflight(),
        );

        const memoryText = 'The celestialdurability protocol survives every restart.';
        final observed = await _callTool(runtime.server!, 'memory_observe', {
          'text': memoryText,
          'role': 'observation',
        });
        expect(observed, containsPair('indexState', 'current'));

        final searched = await _callTool(runtime.server!, 'memory_search', {'query': 'celestialdurability'});
        final results = searched['results'] as List<dynamic>;
        expect(results, hasLength(1));
        expect((results.single as Map<String, dynamic>)['snippet'], contains(memoryText));

        final statusResponse = await runtime.server!.handler(
          Request('GET', Uri.parse('http://localhost/api/memory/status')),
        );
        final status = jsonDecode(await statusResponse.readAsString()) as Map<String, dynamic>;
        final searchStatus = status['search'] as Map<String, dynamic>;
        final indexStatus = status['index'] as Map<String, dynamic>;
        expect(statusResponse.statusCode, 200);
        expect(searchStatus['indexEntries'], 1);
        expect(indexStatus['derivedChunkCount'], 1);

        final knowledgeResponse = await runtime.server!.handler(
          Request('GET', Uri.parse('http://localhost/knowledge?q=celestialdurability&layer=memory')),
        );
        final knowledgeHtml = await knowledgeResponse.readAsString();
        expect(knowledgeResponse.statusCode, 200);
        expect(knowledgeHtml, contains(memoryText));
        expect(knowledgeHtml, contains('layer-badge--memory'));
        expect(searchOpens, 0);
        _expectNoDatabaseFiles(dataDir);
      } finally {
        await runtime?.shutdown();
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
      }
    });
  });

  test('failed PostgreSQL reconciliation keeps the prior persistent index available', () async {
    await withPostgresBackend((backend, _) async {
      final dataDir = Directory.systemTemp.createTempSync('postgres_runtime_reconcile_');
      final config = _config(dataDir, _configuredDsn);
      await seedCanonicalMemory(
        config.workspaceDir,
        topics: const {
          'replacement': ['A replacement corpus row that must not publish after the injected failure.'],
        },
      );
      await prepareAuthoritativeStore(backend, storeName: 'postgres-live-test');
      await validatePostgresFtsLanguage(backend, config.database.ftsLanguage);
      final persistentIndex = PostgresFtsIndex(
        backend,
        table: PostgresFtsTable.memoryChunks,
        language: config.database.ftsLanguage,
      );
      await persistentIndex.upsert([
        SearchDocument(
          id: 'prior-persistent-row',
          chunks: const ['The prior celestialdurability record remains searchable.'],
          metadata: const {'source': 'memory/prior.md', 'role': 'observation', 'provenance': 'runtime-live-fixture'},
          timestamp: DateTime.utc(2026, 9, 9),
        ),
      ], userId: 'owner');
      await backend.execute('''
        CREATE FUNCTION reject_runtime_memory_rebuild() RETURNS trigger
        LANGUAGE plpgsql AS \$function\$
        BEGIN
          RAISE EXCEPTION 'injected memory rebuild failure' USING ERRCODE = 'P0001';
        END
        \$function\$
      ''');
      await backend.execute('''
        CREATE TRIGGER reject_runtime_memory_rebuild
        BEFORE INSERT ON memory_chunks
        FOR EACH ROW EXECUTE FUNCTION reject_runtime_memory_rebuild()
      ''');

      final configFile = File('${dataDir.path}/dartclaw.yaml')..writeAsStringSync('# test\n');
      var searchOpens = 0;
      DartclawRuntime? runtime;
      try {
        runtime = await DartclawRuntime.build(
          config,
          dataDir: dataDir.path,
          port: 0,
          harnessFactory: _harnessFactory(),
          taskBackendFactory: (_) async => backend,
          searchBackendFactory: (_) async {
            searchOpens++;
            throw StateError('PostgreSQL search must use the authoritative backend');
          },
          stderrLine: (_) {},
          exitFn: _unexpectedExit,
          resolvedConfigPath: configFile.path,
          messageRedactor: MessageRedactor(),
          resolvedAssets: const ResolvedAssets.embedded(),
          runWorkflowSkillsBootstrap: false,
          providerAuthPreflight: FakeProviderAuthPreflight(),
        );

        final searched = await _callTool(runtime.server!, 'memory_search', {'query': 'celestialdurability'});
        final results = searched['results'] as List<dynamic>;
        expect(results, hasLength(1));
        expect(
          results.single,
          isA<Map<String, dynamic>>()
              .having((result) => result['locator'], 'locator', 'prior-persistent-row')
              .having((result) => result['snippet'], 'snippet', contains('prior celestialdurability record')),
        );

        final statusResponse = await runtime.server!.handler(
          Request('GET', Uri.parse('http://localhost/api/memory/status')),
        );
        final status = jsonDecode(await statusResponse.readAsString()) as Map<String, dynamic>;
        expect(statusResponse.statusCode, 200);
        expect(status['index'], containsPair('state', 'degraded'));
        expect(searchOpens, 0);
        _expectNoDatabaseFiles(dataDir);
      } finally {
        await runtime?.shutdown();
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
      }
    });
  });
}

Future<Map<String, dynamic>> _callTool(DartclawServer server, String name, Map<String, dynamic> arguments) async {
  final raw = await server.mcpHandler.handleRequest(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }),
  );
  final response = jsonDecode(raw!) as Map<String, dynamic>;
  expect(response['error'], isNull);
  final result = response['result'] as Map<String, dynamic>;
  expect(result['isError'], isNot(true));
  final content = (result['content'] as List<dynamic>).single as Map<String, dynamic>;
  return jsonDecode(content['text'] as String) as Map<String, dynamic>;
}

HarnessFactory _harnessFactory() => HarnessFactory()..register('claude', (_) => FakeAgentHarness());

DartclawConfig _config(Directory dataDir, String dsn, {String ftsLanguage = 'english'}) => DartclawConfig(
  agent: const AgentConfig(provider: 'claude'),
  credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
  providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)}),
  gateway: const GatewayConfig(authMode: 'none'),
  database: DatabaseConfig(
    backend: DatabaseBackendKind.postgres,
    url: dsn,
    urlEnvVars: const ['DARTCLAW_TEST_POSTGRES_URL'],
    poolSize: 3,
    ftsLanguage: ftsLanguage,
  ),
  server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
);

void _expectNoDatabaseFiles(Directory dataDir) {
  final artifacts = dataDir
      .listSync(recursive: true, followLinks: false)
      .where((entity) {
        final name = entity.uri.pathSegments.where((segment) => segment.isNotEmpty).last;
        return name.contains('.db') || name.contains('dartclaw-rebuild') || name.endsWith('.previous');
      })
      .map((entity) => entity.path)
      .toList(growable: false);
  expect(artifacts, isEmpty);
}

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during PostgreSQL runtime search test');
}

final class _RuntimeExit implements Exception {
  const new(this.code);

  final int code;
}
