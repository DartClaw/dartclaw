import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show seedCanonicalMemory;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('storage_backend_selection_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('resolves URL and named credential references with safe provenance', () {
    final registry = CredentialRegistry(
      credentials: const CredentialsConfig(
        entries: {'database-main': CredentialEntry(apiKey: 'postgresql://user:password@db.example.com/app')},
      ),
    );

    expect(
      resolveDatabaseDsn(
        const DatabaseConfig(
          backend: DatabaseBackendKind.postgres,
          url: 'postgresql://user:password@db.example.com/app',
          urlEnvVars: ['DARTCLAW_DATABASE_URL'],
        ),
        credentials: registry,
      ),
      (dsn: 'postgresql://user:password@db.example.com/app', credentialRef: 'DARTCLAW_DATABASE_URL'),
    );
    expect(
      resolveDatabaseDsn(
        const DatabaseConfig(backend: DatabaseBackendKind.postgres, credential: 'database-main'),
        credentials: registry,
      ),
      (dsn: 'postgresql://user:password@db.example.com/app', credentialRef: 'database-main'),
    );
  });

  test('unavailable references fail by name without exposing credential values', () {
    const secret = 'DistinctiveP4ssword';
    final cases = <({DatabaseConfig database, CredentialRegistry registry, String reference})>[
      (
        database: const DatabaseConfig(
          backend: DatabaseBackendKind.postgres,
          url: '',
          urlEnvVars: ['DARTCLAW_DATABASE_URL'],
        ),
        registry: CredentialRegistry(credentials: const CredentialsConfig.defaults()),
        reference: 'DARTCLAW_DATABASE_URL',
      ),
      (
        database: const DatabaseConfig(backend: DatabaseBackendKind.postgres, credential: 'missing-database'),
        registry: CredentialRegistry(credentials: const CredentialsConfig.defaults()),
        reference: 'missing-database',
      ),
      (
        database: const DatabaseConfig(backend: DatabaseBackendKind.postgres, credential: 'wrong-type'),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(entries: {'wrong-type': CredentialEntry.githubToken(token: secret)}),
        ),
        reference: 'wrong-type',
      ),
      (
        database: const DatabaseConfig(backend: DatabaseBackendKind.postgres, credential: 'empty-database'),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(
            entries: {
              'empty-database': CredentialEntry(apiKey: '', envVars: ['DATABASE_SECRET']),
            },
          ),
        ),
        reference: 'empty-database',
      ),
    ];

    for (final (:database, :registry, :reference) in cases) {
      expect(
        () => resolveDatabaseDsn(database, credentials: registry),
        throwsA(
          isA<StorageConnectionException>()
              .having((error) => '$error', 'message', contains(reference))
              .having((error) => '$error', 'message', isNot(contains(secret))),
        ),
        reason: reference,
      );
    }
  });

  for (final database in [const DatabaseConfig(), const DatabaseConfig(backend: DatabaseBackendKind.sqlite)]) {
    test('sqlite selection keeps canonical paths for $database', () async {
      final config = DartclawConfig(
        server: ServerConfig(dataDir: root.path),
        database: database,
      );
      final paths = <String>[];
      final wiring = StorageWiring(
        config: config,
        eventBus: EventBus(),
        taskBackendFactory: (path) async {
          paths.add(path);
          return SqliteBackend.openInMemory();
        },
        exitFn: (code) => throw _Exit(code),
        personalMemoryEnabled: false,
      );
      await wiring.wire();
      expect(paths, [config.dartclawDbPath]);
      await wiring.dispose();
    });
  }

  test('credential-only postgres refuses before a backend factory can run', () async {
    final config = DartclawConfig(
      server: ServerConfig(dataDir: root.path),
      database: const DatabaseConfig(backend: DatabaseBackendKind.postgres, credential: 'safe-name'),
    );
    final wiring = StorageWiring(
      config: config,
      eventBus: EventBus(),
      exitFn: (code) => throw _Exit(code),
      personalMemoryEnabled: false,
    );
    await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)));
  });

  test('postgres failure does not open or persist SQLite search', () async {
    final config = DartclawConfig(
      server: ServerConfig(dataDir: root.path),
      database: const DatabaseConfig(backend: DatabaseBackendKind.postgres, url: 'postgresql://unused.invalid/example'),
    );
    Directory(config.workspaceDir).createSync(recursive: true);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['selection proof'],
      },
    );
    final legacy = File(p.join(root.path, 'tasks.db'));
    final legacyBackend = await SqliteBackend.open(legacy.path);
    await legacyBackend.execute('CREATE TABLE marker(value TEXT)');
    await legacyBackend.close();
    final legacyBytes = legacy.readAsBytesSync();
    var searchFactoryCalls = 0;
    final wiring = StorageWiring(
      config: config,
      eventBus: EventBus(),
      searchBackendFactory: (_) async {
        searchFactoryCalls++;
        return SqliteBackend.openInMemory();
      },
      taskBackendFactory: (_) async =>
          throw StorageConnectionException(operation: 'connect', guidance: 'Injected startup failure.'),
      exitFn: (code) => throw _Exit(code),
    );
    await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)));
    expect(searchFactoryCalls, 0);
    expect(legacy.existsSync(), isTrue);
    expect(legacy.readAsBytesSync(), legacyBytes);
    expect(File(config.dartclawDbPath).existsSync(), isFalse);
    expect(File(config.searchDbPath).existsSync(), isFalse);
    expect(File(p.join(config.workspaceDir, '.dartclaw', 'index-health.json')).existsSync(), isFalse);
  });
}

final class _Exit implements Exception {
  const new(this.code);
  final int code;
}
