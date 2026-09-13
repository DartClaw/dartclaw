import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/storage/postgres_backend.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:fake_async/fake_async.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

void main() {
  test('a competing startup owner refuses safely and closes its session', () async {
    const secret = 'DistinctiveInterlockPasswordX9';
    final backend = _backend(secret: secret);
    final connection = _FakeConnection(acquired: false);
    final interlock = PostgresInterlock(connectionFactory: (_) async => connection);

    await expectLater(
      () => interlock.acquire(backend: backend, onFatalLoss: (_) {}),
      throwsA(
        isA<StorageConnectionException>()
            .having((error) => error.message, 'message', contains('owns this PostgreSQL database'))
            .having((error) => error.message, 'message', contains('Stop the other instance'))
            .having((error) => '$error', 'rendering', isNot(contains(secret)))
            .having((error) => '$error', 'rendering', isNot(contains('runtime_user'))),
      ),
    );

    expect(connection.closeCount, 1);
  });

  test('backend exposes no quarantine bypass controls', () async {
    final backend = _backend();
    final dynamic publicBackend = backend;
    final quarantineError = PostgresStorageMessages.recoveryPending(backend.databaseIdentity);

    expect(() => publicBackend.quarantine(quarantineError), throwsA(isA<NoSuchMethodError>()));
    expect(() => publicBackend.releaseQuarantine(), throwsA(isA<NoSuchMethodError>()));
    expect(() => publicBackend.runInInterlockRecovery(() async {}), throwsA(isA<NoSuchMethodError>()));

    await backend.close();
  });

  test('both loss signals share one recovery and all APIs wait for all three gates', () async {
    final pool = _RecordingPool();
    var recoveryValidationCalls = 0;
    final backend = _backend(
      pool: pool,
      recoverySchemaValidationForTesting: (candidate) async {
        recoveryValidationCalls++;
        await expectLater(() => candidate.query('SELECT 1'), throwsA(_recoveryPending));
      },
    );
    final existingStatement = await backend.prepare('SELECT 1');
    final ownershipStarted = Completer<void>();
    final ownershipResult = Completer<bool>();
    final initial = _FakeConnection(ownershipStarted: ownershipStarted, ownershipResult: ownershipResult);
    final versionStarted = Completer<void>();
    final versionResult = Completer<int>();
    final recovered = _FakeConnection(versionStarted: versionStarted, versionResult: versionResult);
    final schemaStarted = Completer<void>();
    final schemaRelease = Completer<void>();
    var opens = 0;
    var schemaCalls = 0;
    final interlock = PostgresInterlock(
      checkInterval: const Duration(milliseconds: 1),
      connectionFactory: (_) async {
        opens++;
        return opens == 1 ? initial : recovered;
      },
      schemaGate: (candidate) async {
        schemaCalls++;
        await expectLater(() => candidate.query('SELECT 1'), throwsA(_recoveryPending));
        schemaStarted.complete();
        await schemaRelease.future;
      },
    );

    await interlock.acquire(backend: backend, onFatalLoss: (_) => fail('recovery must not be terminal'));
    await ownershipStarted.future.timeout(const Duration(seconds: 1));
    initial.closeFromServer();
    ownershipResult.complete(false);

    await versionStarted.future.timeout(const Duration(seconds: 1));
    expect(opens, 2);
    expect(recovered.acquireCalls, 1);
    expect(schemaCalls, 0);
    await _expectQuarantined(backend, existingStatement);
    expect(pool.dispatchCount, 0);

    versionResult.complete(140000);
    await schemaStarted.future.timeout(const Duration(seconds: 1));
    expect(recovered.versionCalls, 1);
    expect(schemaCalls, 1);
    await _expectQuarantined(backend, existingStatement);
    expect(pool.dispatchCount, 0);

    schemaRelease.complete();
    await _waitUntilUsable(backend);
    final afterRecovery = await backend.prepare('SELECT 1');
    await afterRecovery.close();
    expect(opens, 2);
    expect(recoveryValidationCalls, 1);
    expect(pool.dispatchCount, 0);

    interlock.beginShutdown();
    await backend.close();
    await interlock.release();
  });

  for (final testCase in _terminalCases) {
    test('${testCase.name} is terminal and leaves dispatch quarantined', () async {
      final pool = _RecordingPool();
      final backend = _backend(pool: pool);
      final initial = _FakeConnection();
      final recovered = _FakeConnection(acquired: testCase.acquired, version: testCase.version);
      final fatal = Completer<StorageException>();
      var fatalCount = 0;
      var opens = 0;
      final interlock = PostgresInterlock(
        connectionFactory: (_) async {
          opens++;
          return opens == 1 ? initial : recovered;
        },
        schemaGate: (_) async {
          final error = testCase.schemaError;
          if (error != null) throw error;
        },
      );

      await interlock.acquire(
        backend: backend,
        onFatalLoss: (error) {
          fatalCount++;
          if (!fatal.isCompleted) fatal.complete(error);
        },
      );
      initial.closeFromServer();
      final error = await fatal.future.timeout(const Duration(seconds: 1));

      expect('$error', contains(testCase.expected));
      expect(fatalCount, 1);
      await expectLater(() => backend.query('SELECT 1'), throwsA(_recoveryPending));
      expect(pool.dispatchCount, 0);
      await Future<void>.delayed(Duration.zero);
      expect(fatalCount, 1);

      interlock.beginShutdown();
      await backend.close();
      await interlock.release();
    });
  }

  test('an exhausted recovery budget signals fatal loss exactly once', () {
    fakeAsync((async) {
      final pool = _RecordingPool();
      final backend = _backend(pool: pool);
      final initial = _FakeConnection();
      var opens = 0;
      var fatalCount = 0;
      StorageException? fatalError;
      final origin = DateTime.utc(2026);
      final interlock = PostgresInterlock(
        checkInterval: const Duration(minutes: 1),
        recoveryBudget: const Duration(seconds: 3),
        clock: () => origin.add(async.elapsed),
        connectionFactory: (_) async {
          opens++;
          if (opens == 1) return initial;
          throw StateError('unreachable fixture');
        },
      );

      unawaited(
        interlock.acquire(
          backend: backend,
          onFatalLoss: (error) {
            fatalCount++;
            fatalError = error;
          },
        ),
      );
      async.flushMicrotasks();
      initial.closeFromServer();
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 2, milliseconds: 999));
      expect(fatalCount, 0);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(fatalCount, 1);
      expect('$fatalError', contains('allowed budget'));
      expect(opens, 4);

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(fatalCount, 1);
      expect(pool.dispatchCount, 0);
      interlock.beginShutdown();
      unawaited(backend.close());
      unawaited(interlock.release());
      async.flushMicrotasks();
    });
  });

  test('shutdown before pool close suppresses connection-loss recovery', () async {
    final backend = _backend();
    final connection = _FakeConnection();
    var opens = 0;
    final interlock = PostgresInterlock(
      checkInterval: const Duration(milliseconds: 1),
      connectionFactory: (_) async {
        opens++;
        return connection;
      },
    );

    await interlock.acquire(backend: backend, onFatalLoss: (_) => fail('shutdown must not recover'));
    interlock.beginShutdown();
    connection.closeFromServer();
    await backend.close();
    await interlock.release();
    await Future<void>.delayed(const Duration(milliseconds: 2));

    expect(opens, 1);
  });

  test('recovery validation rejects an empty namespace without writing', () async {
    final backend = _EmptySchemaBackend();

    await expectLater(
      () => PostgresSchemaGate.validateCurrent(backend, databaseIdentity: 'db.example.com:5432/app/dc_test'),
      throwsA(
        isA<SchemaIncompatibleException>()
            .having((error) => error.foundEpoch, 'found epoch', 'absent')
            .having((error) => error.differences, 'differences', contains('missing table tasks')),
      ),
    );

    expect(backend.writeCount, 0);
  });

  test('store-probe messages use safe identities and remediation', () {
    const secret = 'postgresql://runtime_user:DistinctiveSecret@db.example/app';
    for (final message in [
      PostgresStorageMessages.abandoned('db.example:5432/app'),
      PostgresStorageMessages.inUse('db.example:5432/app'),
      PostgresStorageMessages.couldNotVerify('unreachable'),
    ]) {
      expect(message, isNot(contains(secret)));
    }
    expect(
      PostgresStorageMessages.abandoned('local.db'),
      allOf(contains('No data was transferred'), contains('decommission')),
    );
    expect(PostgresStorageMessages.inUse('db'), contains('in use'));
    expect(PostgresStorageMessages.couldNotVerify('unreachable'), contains('Could not verify'));
  });
}

final _recoveryPending = isA<StorageConnectionException>().having(
  (error) => error.message,
  'message',
  contains('ownership recovery is pending'),
);

Future<void> _expectQuarantined(PostgresBackend backend, DatabaseStatement statement) async {
  var transactionBodyRan = false;
  final calls = <Future<void> Function()>[
    () async => backend.execute('DELETE FROM tasks'),
    () async => backend.query('SELECT 1'),
    () async => backend.query('INSERT INTO tasks DEFAULT VALUES RETURNING id'),
    () async => backend.prepare('SELECT 1'),
    () async => backend.transaction<void>((_) async => transactionBodyRan = true),
    () async => statement.execute(),
    () async => statement.query(),
  ];
  for (final call in calls) {
    await expectLater(call, throwsA(_recoveryPending));
  }
  expect(transactionBodyRan, isFalse);
}

Future<void> _waitUntilUsable(PostgresBackend backend) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    try {
      final statement = await backend.prepare('SELECT 1');
      await statement.close();
      return;
    } on StorageConnectionException {
      await Future<void>.delayed(Duration.zero);
    }
  }
  fail('backend remained quarantined after recovery gates passed');
}

PostgresBackend _backend({
  String secret = 'fixture-password',
  _RecordingPool? pool,
  Future<void> Function(PostgresBackend backend)? recoverySchemaValidationForTesting,
}) {
  return PostgresBackend.forTesting(
    pool: pool ?? _RecordingPool(),
    recoverySchemaValidationForTesting: recoverySchemaValidationForTesting ?? (_) async {},
    connectionPosture: PostgresConnectionPosture(
      endpoint: pg.Endpoint(
        host: 'db.example.com',
        port: 5432,
        database: 'app',
        username: 'runtime_user',
        password: secret,
      ),
      sslMode: pg.SslMode.verifyFull,
      databaseIdentity: 'db.example.com:5432/app/dc_test',
      credentialRef: 'database-main',
    ),
  );
}

final class _EmptySchemaBackend implements DatabaseBackend {
  int writeCount = 0;

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) async {
    writeCount++;
    return 0;
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) async => const [];

  @override
  Future<DatabaseStatement> prepare(String sql) => throw UnsupportedError('not used by schema validation');

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) async {
    writeCount++;
    return body(this);
  }

  @override
  Future<void> close() async {}
}

final class _RecordingPool implements pg.Pool<void> {
  int dispatchCount = 0;

  @override
  Future<void> close({bool force = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    dispatchCount++;
    return super.noSuchMethod(invocation);
  }
}

final class _FakeConnection implements PostgresInterlockConnection {
  new({
    this.acquired = true,
    this.version = 140000,
    this.ownershipStarted,
    this.ownershipResult,
    this.versionStarted,
    this.versionResult,
  });

  final bool acquired;
  final int version;
  final Completer<void>? ownershipStarted;
  final Completer<bool>? ownershipResult;
  final Completer<void>? versionStarted;
  final Completer<int>? versionResult;
  final Completer<void> _closed = Completer<void>();

  int acquireCalls = 0;
  int versionCalls = 0;
  int closeCount = 0;
  bool _open = true;

  @override
  bool get isOpen => _open;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<bool> tryAcquire(int key) async {
    acquireCalls++;
    return acquired;
  }

  @override
  Future<bool> owns(int key) async {
    if (ownershipStarted != null && !ownershipStarted!.isCompleted) {
      ownershipStarted!.complete();
    }
    final result = ownershipResult;
    return result == null ? true : result.future;
  }

  @override
  Future<int> serverVersion() async {
    versionCalls++;
    if (versionStarted != null && !versionStarted!.isCompleted) {
      versionStarted!.complete();
    }
    final result = versionResult;
    return result == null ? version : result.future;
  }

  void closeFromServer() {
    if (!_open) return;
    _open = false;
    _closed.complete();
  }

  @override
  Future<void> close() async {
    closeCount++;
    closeFromServer();
  }
}

final _terminalCases = <({String name, bool acquired, int version, StorageException? schemaError, String expected})>[
  (
    name: 'a competing recovery holder',
    acquired: false,
    version: 140000,
    schemaError: null,
    expected: 'Another DartClaw serving instance acquired',
  ),
  (
    name: 'an unsupported recovery server',
    acquired: true,
    version: 130000,
    schemaError: null,
    expected: 'older than PostgreSQL 14',
  ),
  (
    name: 'an incompatible recovery schema',
    acquired: true,
    version: 140000,
    schemaError: SchemaIncompatibleException(
      storeName: 'db.example.com:5432/app/dc_test',
      foundEpoch: '2',
      differences: const ['unsupported schema epoch 2'],
      action: 'Restore a compatible database, then restart DartClaw.',
    ),
    expected: 'incompatible',
  ),
];
