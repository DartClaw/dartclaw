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
          // Join the fatal recovery future inside its error zone.
          try {
            await runtime!.shutdown();
          } on _RuntimeExit {
            // The injected exit was already observed by this zone.
          }
          runtime = null;
        }, (error, _) => zoneErrors.add(error));
        expect(fatalCalls, 1);
        expect(zoneErrors.whereType<_RuntimeExit>(), [isA<_RuntimeExit>().having((error) => error.code, 'code', 1)]);
        expect(
          zoneErrors.where((error) => error is! _RuntimeExit),
          everyElement(
            isA<StorageConnectionException>().having(
              (error) => error.message,
              'quarantined background work',
              contains('ownership recovery is pending'),
            ),
          ),
        );
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
  database: const DatabaseConfig(url: _injectedDsn, urlEnvVars: ['DARTCLAW_TEST_POSTGRES_URL'], poolSize: 3),
  server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
);

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
