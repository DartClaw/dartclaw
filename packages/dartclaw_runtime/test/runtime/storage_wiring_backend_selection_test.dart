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
