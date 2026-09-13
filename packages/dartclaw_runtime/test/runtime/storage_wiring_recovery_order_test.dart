import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner, TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show BehaviorFileService;
import 'package:dartclaw_runtime/src/turn_runner.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnRunner, TurnManager;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late List<LogRecord> logs;
  late StreamSubscription<LogRecord> subscription;
  late Level previous;
  final started = DateTime.utc(2026, 9, 1, 12);
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('recovery_order_');
    logs = [];
    previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    subscription = Logger.root.onRecord.listen(logs.add);
    await openTurnStateStore('${directory.path}/turn_state.json').set('orphan-session', 'orphan-turn', started);
  });
  tearDown(() async {
    await subscription.cancel();
    Logger.root.level = previous;
    directory.deleteSync(recursive: true);
  });

  for (final postgres in [false, true]) {
    test('${postgres ? 'unreachable PostgreSQL' : 'incompatible SQLite'} preserves pre-gate orphan evidence', () async {
      final before = File('${directory.path}/turn_state.json').readAsBytesSync();
      var opens = 0;
      final config = DartclawConfig(
        server: ServerConfig(dataDir: directory.path),
        database: DatabaseConfig(backend: postgres ? DatabaseBackendKind.postgres : DatabaseBackendKind.sqlite),
      );
      final wiring = StorageWiring(
        config: config,
        eventBus: EventBus(),
        serving: true,
        personalMemoryEnabled: false,
        exitFn: (code) => throw _Exit(code),
        taskBackendFactory: (_) async {
          opens++;
          expect(_orphanWarnings(logs), hasLength(1));
          expect(_orphanWarnings(logs).single.message, contains(started.toIso8601String()));
          if (postgres) throw StorageConnectionException(operation: 'connect', guidance: 'unreachable fixture');
          final backend = SqliteBackend.openInMemory();
          await backend.execute('CREATE TABLE tasks (wrong_column TEXT)');
          return backend;
        },
      );
      await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((e) => e.code, 'code', 1)));
      expect(opens, 1);
      expect(File('${directory.path}/turn_state.json').readAsBytesSync(), before);
      expect(_orphanWarnings(logs), hasLength(1));
      expect(logs.any((record) => record.message.contains('Cleaned up')), isFalse);
    });
  }

  test('a successful gate leaves acknowledgement to the runner and emits one notice', () async {
    final wiring = StorageWiring(
      config: DartclawConfig(server: ServerConfig(dataDir: directory.path)),
      eventBus: EventBus(),
      serving: true,
      personalMemoryEnabled: false,
      exitFn: (code) => throw _Exit(code),
      taskBackendFactory: (_) async {
        expect(_orphanWarnings(logs), hasLength(1));
        return SqliteBackend.openInMemory();
      },
    );
    await wiring.wire();
    try {
      expect((await wiring.turnStateStore.getAll()).keys, ['orphan-session']);
      final runner = TurnRunner(
        turnLimits: const TurnLimitsConfig.defaults(),
        harness: FakeAgentHarness(),
        messages: wiring.messages,
        behavior: BehaviorFileService(workspaceDir: directory.path),
        turnState: wiring.turnStateStore,
      );
      expect(runner.consumeRecoveryNotice('orphan-session'), isFalse);
      expect(await runner.detectAndCleanOrphanedTurns(), ['orphan-session']);
      expect(await wiring.turnStateStore.getAll(), isEmpty);
      expect(runner.consumeRecoveryNotice('orphan-session'), isTrue);
      expect(runner.consumeRecoveryNotice('orphan-session'), isFalse);
      expect(_orphanWarnings(logs), hasLength(1));
      expect(logs.where((record) => record.message.contains('Cleaned up')), hasLength(1));
    } finally {
      await wiring.dispose();
    }
  });

  test('SQLite without a PostgreSQL reference does not invoke the inactive-store probe', () async {
    var probeCalls = 0;
    final wiring = StorageWiring(
      config: DartclawConfig(server: ServerConfig(dataDir: directory.path)),
      eventBus: EventBus(),
      serving: true,
      personalMemoryEnabled: false,
      inactivePostgresProbe: () async {
        probeCalls++;
        return const InactivePostgresStoreProbe(InactivePostgresStoreState.empty);
      },
      exitFn: (code) => throw _Exit(code),
      taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
    );

    await wiring.wire();
    try {
      expect(probeCalls, 0);
    } finally {
      await wiring.dispose();
    }
  });

  test('a scan read failure warns and still reaches the active-store gate', () async {
    var opens = 0;
    final wiring = StorageWiring(
      config: DartclawConfig(server: ServerConfig(dataDir: directory.path)),
      eventBus: EventBus(),
      serving: true,
      personalMemoryEnabled: false,
      exitFn: (code) => throw _Exit(code),
      taskBackendFactory: (_) async {
        opens++;
        return SqliteBackend.openInMemory();
      },
    );
    final outerZone = Zone.current;
    await IOOverrides.runZoned(
      () => wiring.wire(),
      createFile: (path) {
        final file = outerZone.run(() => File(path));
        return path == '${directory.path}/turn_state.json' ? _FailsOnScan(file) : file;
      },
    );
    try {
      expect(opens, 1);
      expect(logs.where((record) => record.message.contains('Could not scan orphaned turns')), hasLength(1));
    } finally {
      await wiring.dispose();
    }
  });

  test('headless storage opens state without scanning or acknowledging orphans', () async {
    final wiring = StorageWiring(
      config: DartclawConfig(server: ServerConfig(dataDir: directory.path)),
      eventBus: EventBus(),
      personalMemoryEnabled: false,
      exitFn: (code) => throw _Exit(code),
      taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
    );
    await wiring.wire();
    try {
      expect(_orphanWarnings(logs), isEmpty);
      expect((await wiring.turnStateStore.getAll()).keys, ['orphan-session']);
    } finally {
      await wiring.dispose();
    }
  });
}

List<LogRecord> _orphanWarnings(List<LogRecord> logs) =>
    logs.where((record) => record.message.contains('Orphaned turn detected:')).toList();

final class _Exit implements Exception {
  const new(this.code);
  final int code;
}

final class _FailsOnScan implements File {
  new(this.file);
  final File file;
  var reads = 0;
  @override
  String get path => file.path;
  @override
  Directory get parent => file.parent;
  @override
  bool existsSync() => file.existsSync();
  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    if (++reads > 1) throw const FileSystemException('injected second read failure');
    return file.readAsStringSync(encoding: encoding);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(invocation.memberName.toString());
}
