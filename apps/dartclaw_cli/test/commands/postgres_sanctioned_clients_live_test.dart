@Tags(['integration'])
library;

import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/cleanup_command.dart';
import 'package:dartclaw_cli/src/commands/rebuild_index_command.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_status_command.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show SqliteWorkflowRunRepository, WorkflowRun;
import 'package:dartclaw_workflow/testing.dart' show FakeProviderAuthPreflight;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../../packages/dartclaw_core/test/storage/postgres_live_support.dart';

const _injectedDsn = 'postgresql://cli:SanctionedClientSecretX9@injected.invalid/dartclaw';

void main() {
  test('cleanup, workflow status, and rebuild-index remain concurrent with a serving owner', () async {
    await withPostgresBackend((ownerBackend, _) async {
      final ownerDir = Directory.systemTemp.createTempSync('postgres_cli_owner_');
      final key = 1000000 + Random.secure().nextInt(1000000000);
      DartclawRuntime? owner;
      try {
        owner = await _buildOwner(ownerDir, ownerBackend, key);

        await withPostgresBackend((cleanupBackend, _) async {
          final dataDir = Directory.systemTemp.createTempSync('postgres_cleanup_client_');
          try {
            final lines = <String>[];
            var exitCode = -1;
            final config = _config(
              dataDir,
              workflow: const WorkflowConfig(
                runtimeArtifactsRetention: WorkflowRuntimeArtifactsRetentionConfig(pruneAfterDays: 1),
              ),
            );
            final runner = CommandRunner<void>('dartclaw', 'test')
              ..addCommand(
                CleanupCommand(
                  config: config,
                  taskBackendFactory: (_) async => cleanupBackend,
                  writeLine: lines.add,
                  exitFn: (code) => exitCode = code,
                ),
              );

            await runner.run(['cleanup']);

            expect(exitCode, 0);
            expect(lines, contains(contains('Workflow Runtime-Artifacts Retention')));
          } finally {
            if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
          }
        });

        await withPostgresBackend((statusBackend, _) async {
          final dataDir = Directory.systemTemp.createTempSync('postgres_status_client_');
          try {
            await prepareAuthoritativeStore(statusBackend, storeName: 'postgres-live-test');
            final now = DateTime.utc(2026, 9, 9);
            await SqliteWorkflowRunRepository(statusBackend).insert(
              WorkflowRun(
                id: 'concurrent-status-run',
                definitionName: 'live-status',
                status: WorkflowRunStatus.completed,
                startedAt: now,
                updatedAt: now,
                completedAt: now,
                definitionJson: const {'steps': <Object>[]},
              ),
            );
            final lines = <String>[];
            final runner = CommandRunner<void>('dartclaw', 'test')
              ..addCommand(
                WorkflowStatusCommand(
                  standaloneOnly: true,
                  config: _config(dataDir),
                  taskBackendFactory: (_) async => statusBackend,
                  writeLine: lines.add,
                  exitFn: (code) => throw StateError('Unexpected workflow status exit($code)'),
                ),
              );

            await runner.run(['status', 'concurrent-status-run']);

            expect(lines, contains(contains('Workflow Run: concurrent-status-run')));
            expect(lines, contains(contains('Status:      completed')));
          } finally {
            if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
          }
        });

        await withPostgresBackend((rebuildBackend, _) async {
          final dataDir = Directory.systemTemp.createTempSync('postgres_rebuild_client_');
          try {
            final config = _config(dataDir);
            await seedCanonicalMemory(
              config.workspaceDir,
              topics: const {
                'interlock': ['A sanctioned rebuild remains outside serving ownership.'],
              },
            );
            final lines = <String>[];
            var exitCode = 0;
            final runner = CommandRunner<void>('dartclaw', 'test')
              ..addCommand(
                RebuildIndexCommand(
                  config: config,
                  taskBackendFactory: (_) async => rebuildBackend,
                  writeLine: lines.add,
                  exitFn: (code) => exitCode = code,
                ),
              );

            await runner.run(['rebuild-index']);

            expect(exitCode, 0);
            expect(lines, contains(contains('Rebuilt index: 1 entries')));
          } finally {
            if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
          }
        });

        final task = await owner.taskService.create(
          id: 'owner-after-clients',
          title: 'Serving owner remains active',
          description: 'Sanctioned clients did not take or release its lock.',
        );
        expect((await owner.taskService.get(task.id))?.title, task.title);
        expect(await _lockHolderCount(ownerBackend, key), 1);
      } finally {
        await owner?.shutdown();
        if (ownerDir.existsSync()) ownerDir.deleteSync(recursive: true);
      }
    });
  });
}

Future<DartclawRuntime> _buildOwner(Directory dataDir, PostgresBackend backend, int key) async {
  final config = _config(dataDir);
  await seedCanonicalMemory(config.workspaceDir);
  final configFile = File(p.join(dataDir.path, 'dartclaw.yaml'))..writeAsStringSync('# CLI interlock fixture\n');
  return DartclawRuntime.build(
    config,
    dataDir: dataDir.path,
    port: 0,
    harnessFactory: HarnessFactory()..register('claude', (_) => FakeAgentHarness()),
    taskBackendFactory: (_) async => backend,
    searchBackendFactory: (_) async => throw StateError('PostgreSQL must not open a SQLite search backend'),
    stderrLine: (_) {},
    exitFn: (code) => throw StateError('Unexpected serving exit($code)'),
    resolvedConfigPath: configFile.path,
    messageRedactor: MessageRedactor(),
    resolvedAssets: const ResolvedAssets.embedded(),
    postgresInterlockFactory: () => PostgresInterlock(key: key),
    runWorkflowSkillsBootstrap: false,
    providerAuthPreflight: FakeProviderAuthPreflight(),
  );
}

DartclawConfig _config(Directory dataDir, {WorkflowConfig workflow = const WorkflowConfig.defaults()}) =>
    DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      database: const DatabaseConfig(
        backend: DatabaseBackendKind.postgres,
        url: _injectedDsn,
        urlEnvVars: ['DARTCLAW_TEST_POSTGRES_URL'],
        poolSize: 3,
      ),
      workflow: workflow,
      server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
    );

Future<int> _lockHolderCount(PostgresBackend backend, int key) async {
  final rows = await backend.query(
    '''
    SELECT COUNT(*)::integer AS holders
    FROM pg_locks
    WHERE locktype = 'advisory' AND granted
      AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
      AND classid::bigint = ? AND objid::bigint = ? AND objsubid = 1
  ''',
    [key >> 32, key & 0xffffffff],
  );
  return rows.single['holders']! as int;
}
