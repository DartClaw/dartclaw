import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/storage/postgres_backend.dart' show PostgresInterlockConnection;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:logging/logging.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late EventBus eventBus;

  setUp(() {
    root = Directory.systemTemp.createTempSync('storage_startup_cleanup_');
    eventBus = EventBus();
  });

  tearDown(() async {
    if (!eventBus.isDisposed) await eventBus.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  for (final closeFails in [false, true]) {
    test('startup closes the pool before releasing ownership when pool close failure=$closeFails', () async {
      final order = <String>[];
      final startupError = StorageConnectionException(operation: 'schema preparation', guidance: 'fixture failure');
      final pool = _Pool(startupError, order, closeFails: closeFails);
      final backend = PostgresBackend.forTesting(pool: pool, connectionPosture: _posture);
      final owner = _InterlockConnection(order);
      final records = <LogRecord>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(() async {
        await subscription.cancel();
        Logger.root.level = previousLevel;
      });
      final wiring = StorageWiring(
        config: DartclawConfig(
          server: ServerConfig(dataDir: root.path),
          database: const DatabaseConfig(
            backend: DatabaseBackendKind.postgres,
            url: 'postgresql://runtime@db.example.com/app',
          ),
        ),
        eventBus: eventBus,
        taskBackendFactory: (_) async => backend,
        exitFn: (code) => throw _Exit(code),
        personalMemoryEnabled: false,
        serving: true,
        postgresInterlockFactory: () => PostgresInterlock(connectionFactory: (_) async => owner),
      );

      await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)));

      expect(order, ['pool-close', 'interlock-release']);
      expect(
        records,
        contains(
          isA<LogRecord>()
              .having((record) => record.level, 'level', Level.SEVERE)
              .having((record) => record.error, 'error', same(startupError)),
        ),
      );
      final cleanupLogs = records
          .where((record) => record.message == 'Storage cleanup failed after task database startup failure')
          .toList();
      expect(cleanupLogs, closeFails ? hasLength(1) : isEmpty);
      if (cleanupLogs.isNotEmpty) {
        expect(cleanupLogs.single.error, isNull);
        expect(cleanupLogs.single.stackTrace, isNull);
      }
    });
  }
}

final _posture = PostgresConnectionPosture(
  endpoint: pg.Endpoint(host: 'db.example.com', database: 'app'),
  sslMode: pg.SslMode.verifyFull,
  databaseIdentity: 'db.example.com:5432/app/dc_test',
  credentialRef: 'database-main',
);

final class _Pool implements pg.Pool<void> {
  new(this.startupError, this.order, {required this.closeFails});

  final Object startupError;
  final List<String> order;
  final bool closeFails;

  @override
  Future<R> withConnection<R>(
    Future<R> Function(pg.Connection connection) fn, {
    pg.ConnectionSettings? settings,
    void locality,
  }) => fn(_FailingConnection(startupError));

  @override
  Future<void> close({bool force = false}) async {
    order.add('pool-close');
    if (closeFails) throw StateError('pool close failed with secret detail');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FailingConnection implements pg.Connection {
  const new(this.error);

  final Object error;

  @override
  Future<pg.Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
    pg.QueryMode? queryMode,
    Duration? timeout,
  }) async => throw error;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _InterlockConnection implements PostgresInterlockConnection {
  new(this.order);

  final List<String> order;
  final Completer<void> _closed = Completer<void>();
  var _open = true;

  @override
  bool get isOpen => _open;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<bool> tryAcquire(int key) async => true;

  @override
  Future<bool> owns(int key) async => true;

  @override
  Future<int> serverVersion() async => 140000;

  @override
  Future<void> close() async {
    order.add('interlock-release');
    _open = false;
    _closed.complete();
  }
}

final class _Exit implements Exception {
  const new(this.code);

  final int code;
}
