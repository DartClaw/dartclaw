@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/testing.dart' show FakeProviderAuthPreflight;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../dartclaw_core/test/storage/postgres_live_support.dart';

const _injectedDsn = 'postgresql://runtime:RuntimeInterlockSecretX9@injected.invalid/dartclaw';

void main() {
  test('second serving build refuses before the gate while headless composition remains concurrent', () async {
    await withPostgresBackend((ownerBackend, _) async {
      final key = _uniqueKey();
      final ownerDir = Directory.systemTemp.createTempSync('postgres_interlock_owner_');
      DartclawRuntime? owner;
      try {
        owner = await _buildPostgresRuntime(ownerDir, ownerBackend, interlockKey: key);

        await withPostgresBackend((contenderBackend, contenderNamespace) async {
          final contenderDir = Directory.systemTemp.createTempSync('postgres_interlock_contender_');
          final records = <LogRecord>[];
          final subscription = Logger.root.onRecord.listen(records.add);
          Object? failure;
          try {
            await _buildPostgresRuntime(
              contenderDir,
              contenderBackend,
              interlockKey: key,
              exitFn: (code) => throw _RuntimeExit(code),
            );
            failure = StateError('Expected the second serving build to fail');
          } catch (error) {
            failure = error;
          } finally {
            await subscription.cancel();
          }

          expect(failure, isA<_RuntimeExit>().having((error) => error.code, 'code', 1));
          final observable = records.map((record) => '${record.message}\n${record.error ?? ''}').join('\n');
          expect(observable, contains('Another DartClaw serving instance owns this PostgreSQL database'));
          expect(observable, contains('Stop the other instance or use a separate database'));
          expect(observable, isNot(contains(_injectedDsn)));
          expect(observable, isNot(contains(Uri.parse(_injectedDsn).userInfo)));
          expect(await _schemaTables(ownerBackend, contenderNamespace), isEmpty);
          await expectLater(() => contenderBackend.query('SELECT 1'), throwsStateError);
          if (contenderDir.existsSync()) contenderDir.deleteSync(recursive: true);
        });

        await withPostgresBackend((headlessBackend, _) async {
          final headlessDir = Directory.systemTemp.createTempSync('postgres_interlock_headless_');
          DartclawRuntime? headless;
          try {
            headless = await _buildPostgresRuntime(headlessDir, headlessBackend, interlockKey: key, headless: true);
            expect(headless.server, isNull);
            final task = await headless.taskService.create(
              id: 'headless-concurrent',
              title: 'Concurrent one-shot',
              description: 'Headless composition remains outside the serving interlock.',
            );
            expect((await headless.taskService.get(task.id))?.title, task.title);
          } finally {
            await headless?.shutdown();
            if (headlessDir.existsSync()) headlessDir.deleteSync(recursive: true);
          }
        });

        final ownerTask = await owner.taskService.create(
          id: 'owner-still-serving',
          title: 'Owner remains active',
          description: 'The refused attach did not disturb the owner.',
        );
        expect((await owner.taskService.get(ownerTask.id))?.title, ownerTask.title);
      } finally {
        await owner?.shutdown();
        if (ownerDir.existsSync()) ownerDir.deleteSync(recursive: true);
      }
    });
  });

  test('shutdown keeps ownership until the pool closes and permits immediate reacquisition', () async {
    await withPostgresBackend((ownerBackend, _) async {
      await withPostgresBackend((inspectorBackend, _) async {
        final key = _uniqueKey();
        final ownerDir = Directory.systemTemp.createTempSync('postgres_interlock_shutdown_');
        DartclawRuntime? owner;
        DartclawRuntime? successor;
        try {
          var fatalCalls = 0;
          owner = await _buildPostgresRuntime(
            ownerDir,
            ownerBackend,
            interlockKey: key,
            exitFn: (code) {
              fatalCalls++;
              throw _RuntimeExit(code);
            },
          );

          final transactionEntered = Completer<void>();
          final releaseTransaction = Completer<void>();
          final transaction = ownerBackend.transaction((_) async {
            transactionEntered.complete();
            await releaseTransaction.future;
          });
          await transactionEntered.future;

          var shutdownComplete = false;
          final shutdown = owner.shutdown().then((_) => shutdownComplete = true);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(shutdownComplete, isFalse);
          expect(await _lockHolderCount(inspectorBackend, key), 1);

          releaseTransaction.complete();
          await transaction;
          await shutdown;
          owner = null;
          expect(fatalCalls, 0);
          expect(await _lockHolderCount(inspectorBackend, key), 0);
          await expectLater(() => ownerBackend.query('SELECT 1'), throwsStateError);

          final successorDir = Directory.systemTemp.createTempSync('postgres_interlock_successor_');
          try {
            successor = await _buildPostgresRuntime(successorDir, inspectorBackend, interlockKey: key);
            expect(await _lockHolderCount(inspectorBackend, key), 1);
          } finally {
            await successor?.shutdown();
            successor = null;
            if (successorDir.existsSync()) successorDir.deleteSync(recursive: true);
          }
        } finally {
          await owner?.shutdown();
          await successor?.shutdown();
          if (ownerDir.existsSync()) ownerDir.deleteSync(recursive: true);
        }
      });
    });
  });

  test('terminal interlock loss reaches the fatal path exactly once', () async {
    await withPostgresBackend((backend, _) async {
      final key = _uniqueKey();
      final dataDir = Directory.systemTemp.createTempSync('postgres_interlock_terminal_');
      final records = <LogRecord>[];
      final subscription = Logger.root.onRecord.listen(records.add);
      DartclawRuntime? runtime;
      try {
        final epoch = DateTime.utc(2026, 9, 9);
        var clockReads = 0;
        var fatalCalls = 0;
        final zoneErrors = <Object>[];
        await runZonedGuarded(() async {
          runtime = await _buildPostgresRuntime(
            dataDir,
            backend,
            interlockKey: key,
            exitFn: (code) {
              fatalCalls++;
              throw _RuntimeExit(code);
            },
            interlockFactory: () => PostgresInterlock(
              key: key,
              recoveryBudget: const Duration(seconds: 1),
              clock: () => clockReads++ == 0 ? epoch : epoch.add(const Duration(minutes: 1)),
            ),
          );

          final pid = await _interlockPid(backend, key);
          expect(pid, isNotNull);
          await backend.query('SELECT pg_terminate_backend(?) AS terminated', [pid]);
          await _eventually(() => fatalCalls == 1);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }, (error, _) => zoneErrors.add(error));
        expect(fatalCalls, 1);
        expect(zoneErrors, [isA<_RuntimeExit>().having((error) => error.code, 'code', 1)]);
        expect(
          records.map((record) => record.message.toString()),
          contains(contains('ownership could not be recovered within the allowed budget')),
        );
      } finally {
        try {
          await runtime?.shutdown();
        } on _RuntimeExit {
          // The fatal exit thrown from the unawaited loss callback is observed
          // again when shutdown joins the completed recovery future.
        }
        await subscription.cancel();
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
      }
    });
  });

  test('PostgreSQL selection reports retained local stores without changing their bytes', () async {
    for (final fixture in const [
      (name: 'current', current: true, legacy: false, nonEmpty: true, expected: 'dartclaw.db'),
      (name: 'legacy', current: false, legacy: true, nonEmpty: true, expected: 'tasks.db'),
      (name: 'both', current: true, legacy: true, nonEmpty: true, expected: 'ambiguous'),
      (name: 'empty', current: true, legacy: false, nonEmpty: false, expected: ''),
    ]) {
      await withPostgresBackend((backend, _) async {
        final dataDir = Directory.systemTemp.createTempSync('postgres_switch_${fixture.name}_');
        final currentPath = p.join(dataDir.path, 'dartclaw.db');
        final legacyPath = p.join(dataDir.path, 'tasks.db');
        DartclawRuntime? runtime;
        final records = <LogRecord>[];
        final subscription = Logger.root.onRecord.listen(records.add);
        try {
          if (fixture.current) await _seedLocalStore(currentPath, nonEmpty: fixture.nonEmpty);
          if (fixture.legacy) await _seedLocalStore(legacyPath, nonEmpty: fixture.nonEmpty);
          final before = {
            if (fixture.current) currentPath: File(currentPath).readAsBytesSync(),
            if (fixture.legacy) legacyPath: File(legacyPath).readAsBytesSync(),
          };

          runtime = await _buildPostgresRuntime(dataDir, backend, interlockKey: _uniqueKey());
          final warnings = records.map((record) => record.message.toString()).join('\n');
          if (fixture.expected.isEmpty) {
            expect(warnings, isNot(contains('abandoned by the selected backend')), reason: fixture.name);
          } else {
            expect(warnings, contains('No data was transferred'), reason: fixture.name);
            expect(warnings, contains(fixture.expected), reason: fixture.name);
          }
          for (final entry in before.entries) {
            expect(File(entry.key).readAsBytesSync(), entry.value, reason: fixture.name);
          }
        } finally {
          await runtime?.shutdown();
          await subscription.cancel();
          if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
        }
      });
    }
  });

  test('SQLite selection reports actual inactive PostgreSQL catalog and ownership states', () async {
    await withPostgresBackend((postgresBackend, namespace) async {
      await prepareAuthoritativeStore(postgresBackend, storeName: 'postgres-live-test');
      final dsn = _dsnFromPosture(postgresBackend.connectionPosture);
      final key = _uniqueKey();

      Future<String> runProbe(String name) async {
        final dataDir = Directory.systemTemp.createTempSync('inactive_postgres_${name}_');
        final records = <LogRecord>[];
        final subscription = Logger.root.onRecord.listen(records.add);
        DartclawRuntime? runtime;
        try {
          final config = _sqliteConfig(dataDir, postgresDsn: dsn);
          runtime = await _buildSqliteRuntime(
            config,
            inactivePostgresProbe: () => probeInactivePostgresStore(
              config.database,
              resolveDsn: (database) => resolveDatabaseDsn(database),
              auditLogger: GuardAuditLogger(dataDir: dataDir.path),
              connectionFactory: (posture) => openPostgresTestConnection(posture, namespace: namespace),
              interlockKey: key,
            ),
          );
          return records.map((record) => record.message.toString()).join('\n');
        } finally {
          await runtime?.shutdown();
          await subscription.cancel();
          if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
        }
      }

      final empty = await runProbe('empty');
      expect(empty, isNot(contains('inactive PostgreSQL store')));
      expect(empty, isNot(contains('abandoned by the selected backend')));

      await SqliteTaskRepository(postgresBackend).insert(
        Task(
          id: 'inactive-postgres-row',
          title: 'Retained PostgreSQL task',
          description: 'Must remain in the inactive PostgreSQL store.',
          createdAt: DateTime.utc(2026, 9, 9),
        ),
      );
      final abandoned = await runProbe('abandoned');
      expect(abandoned, contains('abandoned by the selected backend'));
      expect(abandoned, contains('No data was transferred'));

      final held = PostgresInterlock(key: key);
      await held.acquire(backend: postgresBackend, onFatalLoss: (error) => fail(error.message));
      try {
        final inUse = await runProbe('in_use');
        expect(inUse, contains('in use by another DartClaw serving instance'));
        expect(inUse, isNot(contains(dsn)));
        expect(inUse, isNot(contains(Uri.parse(dsn).userInfo)));
      } finally {
        held.beginShutdown();
        await held.release();
      }

      expect(
        (await SqliteTaskRepository(postgresBackend).getById('inactive-postgres-row'))?.title,
        'Retained PostgreSQL task',
      );
    });
  });

  test('SQLite selection classifies inactive PostgreSQL reference failures without unsafe connects', () async {
    await withPostgresBackend((_, namespace) async {
      Future<({String observable, int callbacks, int connections})> runCase(
        String name,
        DatabaseConfig database,
      ) async {
        final dataDir = Directory.systemTemp.createTempSync('inactive_postgres_failure_${name}_');
        final records = <LogRecord>[];
        final subscription = Logger.root.onRecord.listen(records.add);
        var callbacks = 0;
        var connections = 0;
        DartclawRuntime? runtime;
        try {
          final config = _sqliteConfig(dataDir, database: database);
          runtime = await _buildSqliteRuntime(
            config,
            inactivePostgresProbe: () {
              callbacks++;
              return probeInactivePostgresStore(
                config.database,
                resolveDsn: (selected) => resolveDatabaseDsn(selected),
                connectionFactory: (posture) {
                  connections++;
                  return openPostgresTestConnection(posture, namespace: namespace);
                },
              );
            },
          );
          return (
            observable: records.map((record) => record.message.toString()).join('\n'),
            callbacks: callbacks,
            connections: connections,
          );
        } finally {
          await runtime?.shutdown();
          await subscription.cancel();
          if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
        }
      }

      final absent = await runCase('absent', const DatabaseConfig());
      expect(absent.observable, isNot(contains('Could not verify the inactive PostgreSQL store')));
      expect(absent.callbacks, 0);
      expect(absent.connections, 0);

      final unresolved = await runCase('unresolved', const DatabaseConfig(credential: 'missing-postgres-credential'));
      expect(unresolved.observable, contains('unresolved reference'));
      expect(unresolved.callbacks, 1);
      expect(unresolved.connections, 0);

      const refusedDsn = 'postgresql://probe:PostureSecretX8@db.example.com/dartclaw?sslmode=disable';
      final refused = await runCase('posture', const DatabaseConfig(url: refusedDsn));
      expect(refused.observable, contains('posture refused'));
      expect(refused.observable, isNot(contains(refusedDsn)));
      expect(refused.observable, isNot(contains(Uri.parse(refusedDsn).userInfo)));
      expect(refused.callbacks, 1);
      expect(refused.connections, 0);

      final unreachable = await runCase(
        'unreachable',
        const DatabaseConfig(url: 'postgresql://probe:UnreachableSecretX7@127.0.0.1:1/dartclaw?sslmode=disable'),
      );
      expect(unreachable.observable, contains('unreachable'));
      expect(unreachable.callbacks, 1);
      expect(unreachable.connections, 1);
    });
  });

  test('failed post-storage assembly releases ownership for an immediate serving successor', () async {
    await withPostgresBackend((failedBackend, _) async {
      await withPostgresBackend((successorBackend, _) async {
        final key = _uniqueKey();
        final failedDir = Directory.systemTemp.createTempSync('postgres_interlock_failed_assembly_');
        final successorDir = Directory.systemTemp.createTempSync('postgres_interlock_retry_');
        DartclawRuntime? successor;
        try {
          final failingHarnesses = HarnessFactory()
            ..register('claude', (_) => FakeAgentHarness())
            ..register('failing-registry-probe', (_) => throw StateError('registry failed after storage'));
          await expectLater(
            _buildPostgresRuntime(failedDir, failedBackend, interlockKey: key, harnessFactory: failingHarnesses),
            throwsA(isA<StateError>().having((error) => error.message, 'message', 'registry failed after storage')),
          );
          await expectLater(() => failedBackend.query('SELECT 1'), throwsStateError);

          successor = await _buildPostgresRuntime(successorDir, successorBackend, interlockKey: key);
          expect(await _lockHolderCount(successorBackend, key), 1);
        } finally {
          await successor?.shutdown();
          if (failedDir.existsSync()) failedDir.deleteSync(recursive: true);
          if (successorDir.existsSync()) successorDir.deleteSync(recursive: true);
        }
      });
    });
  });
}

Future<DartclawRuntime> _buildPostgresRuntime(
  Directory dataDir,
  PostgresBackend backend, {
  required int interlockKey,
  bool headless = false,
  ExitFn exitFn = _unexpectedExit,
  PostgresInterlock Function()? interlockFactory,
  HarnessFactory? harnessFactory,
}) async {
  final config = _postgresConfig(dataDir);
  await seedCanonicalMemory(config.workspaceDir);
  final configFile = File(p.join(dataDir.path, 'dartclaw.yaml'))..writeAsStringSync('# live interlock fixture\n');
  return DartclawRuntime.build(
    config,
    dataDir: dataDir.path,
    port: 0,
    harnessFactory: harnessFactory ?? (HarnessFactory()..register('claude', (_) => FakeAgentHarness())),
    taskBackendFactory: (_) async => backend,
    searchBackendFactory: (_) async => throw StateError('PostgreSQL must not open a SQLite search backend'),
    stderrLine: (_) {},
    exitFn: exitFn,
    resolvedConfigPath: configFile.path,
    messageRedactor: MessageRedactor(),
    resolvedAssets: const ResolvedAssets.embedded(),
    headless: headless,
    postgresInterlockFactory: interlockFactory ?? () => PostgresInterlock(key: interlockKey),
    runWorkflowSkillsBootstrap: false,
    providerAuthPreflight: FakeProviderAuthPreflight(),
  );
}

DartclawConfig _postgresConfig(Directory dataDir) => DartclawConfig(
  agent: const AgentConfig(provider: 'claude'),
  credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
  providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)}),
  gateway: const GatewayConfig(authMode: 'none'),
  database: const DatabaseConfig(
    backend: DatabaseBackendKind.postgres,
    url: _injectedDsn,
    urlEnvVars: ['DARTCLAW_TEST_POSTGRES_URL'],
    poolSize: 3,
  ),
  server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
);

Future<DartclawRuntime> _buildSqliteRuntime(
  DartclawConfig config, {
  required Future<InactivePostgresStoreProbe> Function() inactivePostgresProbe,
}) async {
  final configFile = File(p.join(config.server.dataDir, 'dartclaw.yaml'))
    ..writeAsStringSync('# inactive PostgreSQL probe fixture\n');
  return DartclawRuntime.build(
    config,
    dataDir: config.server.dataDir,
    port: 0,
    harnessFactory: HarnessFactory()..register('claude', (_) => FakeAgentHarness()),
    taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
    searchBackendFactory: (_) async => SqliteBackend.openInMemory(),
    stderrLine: (_) {},
    exitFn: _unexpectedExit,
    resolvedConfigPath: configFile.path,
    messageRedactor: MessageRedactor(),
    resolvedAssets: const ResolvedAssets.embedded(),
    inactivePostgresProbe: inactivePostgresProbe,
    runWorkflowSkillsBootstrap: false,
    providerAuthPreflight: FakeProviderAuthPreflight(),
  );
}

DartclawConfig _sqliteConfig(Directory dataDir, {String? postgresDsn, DatabaseConfig? database}) => DartclawConfig(
  agent: const AgentConfig(provider: 'claude'),
  credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
  providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)}),
  gateway: const GatewayConfig(authMode: 'none'),
  database:
      database ??
      DatabaseConfig(
        backend: DatabaseBackendKind.sqlite,
        url: postgresDsn,
        urlEnvVars: const ['DARTCLAW_TEST_POSTGRES_URL'],
      ),
  server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
);

String _dsnFromPosture(PostgresConnectionPosture posture) {
  final endpoint = posture.endpoint;
  final username = endpoint.username == null ? '' : Uri.encodeComponent(endpoint.username!);
  final password = endpoint.password == null ? '' : ':${Uri.encodeComponent(endpoint.password!)}';
  return Uri(
    scheme: 'postgresql',
    userInfo: '$username$password',
    host: endpoint.host,
    port: endpoint.port,
    path: '/${endpoint.database}',
    queryParameters: const {'sslmode': 'disable'},
  ).toString();
}

Future<void> _seedLocalStore(String path, {required bool nonEmpty}) async {
  final backend = await SqliteBackend.open(path);
  try {
    await prepareAuthoritativeStore(backend, storeName: p.basename(path));
    if (nonEmpty) {
      await SqliteTaskRepository(backend).insert(
        Task(
          id: 'retained-${p.basename(path)}',
          title: 'Retained local task',
          description: 'Must not transfer to PostgreSQL.',
          createdAt: DateTime.utc(2026, 9, 9),
        ),
      );
    }
  } finally {
    await backend.close();
  }
}

Future<List<Map<String, Object?>>> _schemaTables(PostgresBackend backend, String namespace) => backend.query(
  'SELECT table_name FROM information_schema.tables WHERE table_schema = ? ORDER BY table_name',
  [namespace],
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

Future<int?> _interlockPid(PostgresBackend backend, int key) async {
  final rows = await backend.query(
    '''
    SELECT pid
    FROM pg_locks
    WHERE locktype = 'advisory' AND granted
      AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
      AND classid::bigint = ? AND objid::bigint = ? AND objsubid = 1
  ''',
    [key >> 32, key & 0xffffffff],
  );
  return rows.isEmpty ? null : rows.single['pid']! as int;
}

Future<void> _eventually(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition did not become true before the live-test deadline.');
}

int _uniqueKey() => 1000000 + Random.secure().nextInt(1000000000);

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code) during PostgreSQL interlock test');

final class _RuntimeExit implements Exception {
  const new(this.code);

  final int code;
}
