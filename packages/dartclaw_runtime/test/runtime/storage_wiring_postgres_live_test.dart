@Tags(['integration'])
library;

import 'dart:io';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:test/test.dart';

void main() {
  test('postgres runtime composition owns one prepared backend', () async {
    final configured = Platform.environment['DARTCLAW_TEST_POSTGRES_URL'];
    if (configured == null || configured.isEmpty) {
      throw StateError('DARTCLAW_TEST_POSTGRES_URL is required');
    }
    final uri = Uri.parse(configured);
    final dsn = uri.replace(queryParameters: {...uri.queryParameters, 'sslmode': 'disable'}).toString();
    final namespace = 'dc_runtime_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
    var admin = await PostgresBackend.open(dsn: dsn, poolSize: 1);
    await admin.execute('CREATE SCHEMA "$namespace"');
    await admin.close();
    final dataDir = Directory.systemTemp.createTempSync('postgres_runtime_');
    final configFile = File('${dataDir.path}/dartclaw.yaml')..writeAsStringSync('# test\n');
    PostgresBackend? opened;
    var opens = 0;
    var searchOpens = 0;
    DartclawRuntime? runtime;
    try {
      final config = DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        providers: ProvidersConfig(
          entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
        ),
        server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
        database: DatabaseConfig(backend: DatabaseBackendKind.postgres, url: dsn, poolSize: 3),
      );
      final harnesses = HarnessFactory()..register('claude', (_) => FakeAgentHarness());
      runtime = await DartclawRuntime.build(
        config,
        dataDir: dataDir.path,
        port: 0,
        harnessFactory: harnesses,
        searchBackendFactory: (_) async {
          searchOpens++;
          return SqliteBackend.openInMemory();
        },
        taskBackendFactory: (_) async {
          opens++;
          return opened = await PostgresBackend.open(dsn: dsn, poolSize: 3, namespace: namespace);
        },
        stderrLine: (_) {},
        exitFn: (code) => throw StateError('unexpected exit($code)'),
        resolvedConfigPath: configFile.path,
        messageRedactor: MessageRedactor(),
        resolvedAssets: const ResolvedAssets.embedded(),
        headless: true,
        runWorkflowSkillsBootstrap: false,
      );
      final task = await runtime.taskService.create(id: 'pg-task', title: 'Postgres', description: 'round trip');
      expect((await runtime.taskService.get(task.id))?.title, 'Postgres');
      expect(opens, 1);
      expect(searchOpens, 0);
      expect(File(config.dartclawDbPath).existsSync(), isFalse);
      expect(File(config.searchDbPath).existsSync(), isFalse);

      await runtime.shutdown();
      runtime = null;
      await expectLater(() => opened!.execute('SELECT 1'), throwsStateError);
      await opened!.close();
    } finally {
      await runtime?.shutdown();
      await opened?.close();
      admin = await PostgresBackend.open(dsn: dsn, poolSize: 1);
      await admin.execute('DROP SCHEMA IF EXISTS "$namespace" CASCADE');
      await admin.close();
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    }
  });
}
