part of 'postgres_backend.dart';

/// Opens the dedicated PostgreSQL session used by [PostgresInterlock].
typedef PostgresInterlockConnectionFactory = Future<PostgresInterlockConnection> Function(
  PostgresConnectionPosture posture,
);

/// Test hook run before recovery compatibility validation.
@visibleForTesting
typedef PostgresRecoverySchemaGate = Future<void> Function(PostgresBackend backend);

/// Test seam for the session-pinned interlock connection.
abstract interface class PostgresInterlockConnection {
  /// Whether the driver session is still open.
  bool get isOpen;

  /// Completes when the driver session closes.
  Future<void> get closed;

  /// Attempts to acquire the configured session advisory lock.
  Future<bool> tryAcquire(int key);

  /// Whether this session still owns the configured advisory lock.
  Future<bool> owns(int key);

  /// PostgreSQL's numeric server version.
  Future<int> serverVersion();

  /// Closes the driver session.
  Future<void> close();
}

/// Redaction-safe messages shared by PostgreSQL ownership and store probes.
abstract final class PostgresStorageMessages {
  /// Refuses a second serving instance for the same database.
  static StorageConnectionException ownershipConflict(String identity) => StorageConnectionException(
    operation: 'startup interlock',
    databaseIdentity: identity,
    guidance:
        'Another DartClaw serving instance owns this PostgreSQL database. '
        'Stop the other instance or use a separate database.',
  );

  /// Refuses storage access while ownership is uncertain.
  static StorageConnectionException recoveryPending(String identity) => StorageConnectionException(
    operation: 'interlock recovery',
    databaseIdentity: identity,
    guidance: 'PostgreSQL ownership recovery is pending. Retry after this instance has reacquired and revalidated it.',
  );

  /// Reports a competing holder encountered during recovery.
  static StorageConnectionException competingHolder(String identity) => StorageConnectionException(
    operation: 'interlock recovery',
    databaseIdentity: identity,
    guidance:
        'Another DartClaw serving instance acquired this PostgreSQL database. '
        'Stop the other instance or use a separate database, then restart DartClaw.',
  );

  /// Reports that PostgreSQL could not be reached within the recovery budget.
  static StorageConnectionException recoveryBudgetExhausted(String identity) => StorageConnectionException(
    operation: 'interlock recovery',
    databaseIdentity: identity,
    guidance:
        'PostgreSQL ownership could not be recovered within the allowed budget. '
        'Restore database reachability, then restart DartClaw.',
  );

  /// Reports an unsupported server encountered after reacquisition.
  static StorageConnectionException unsupportedVersion(String identity) => StorageConnectionException(
    operation: 'interlock recovery',
    databaseIdentity: identity,
    guidance: 'The reconnected server is older than PostgreSQL 14. Use PostgreSQL 14 or newer, then restart DartClaw.',
  );

  /// Reports an unexpected compatibility-gate failure without driver detail.
  static StorageConnectionException schemaFailure(String identity) => StorageConnectionException(
    operation: 'interlock recovery',
    databaseIdentity: identity,
    guidance: 'The PostgreSQL schema could not be revalidated. Correct the failed schema gate, then restart DartClaw.',
  );

  /// Notice for data left in an inactive store.
  static String abandoned(String safeIdentity) =>
      'Store $safeIdentity is abandoned by the selected backend. No data was transferred. '
      'Back it up, import it separately if needed, then decommission it.';

  /// Notice for an inactive PostgreSQL store with a current owner.
  static String inUse(String safeIdentity) =>
      'Store $safeIdentity is in use by another DartClaw serving instance. '
      'Stop that instance before inspecting or decommissioning the store.';

  /// Notice for a probe whose safe failure class is [reasonClass].
  static String couldNotVerify(String reasonClass) =>
      'Could not verify the inactive store: $reasonClass. '
      'Check the configured reference and database reachability before decommissioning it.';
}

/// Owns a database-wide PostgreSQL session lock for one serving process.
final class PostgresInterlock {
  /// Fixed production advisory-lock key.
  static const int defaultKey = 0x64617274636c6177;

  static const _recoveryRetryInterval = Duration(seconds: 1);
  static const _connectTimeout = Duration(seconds: 5);

  /// Creates an interlock with bounded ownership checks and recovery.
  new({
    this.key = defaultKey,
    this.checkInterval = const Duration(seconds: 60),
    this.recoveryBudget = const Duration(minutes: 10),
    DateTime Function()? clock,
    PostgresInterlockConnectionFactory? connectionFactory,
    PostgresRecoverySchemaGate? schemaGate,
  }) : _clock = clock ?? DateTime.now,
       _connectionFactory = connectionFactory ?? _openConnection,
       _schemaGate = schemaGate {
    if (checkInterval <= Duration.zero) {
      throw ArgumentError.value(checkInterval, 'checkInterval', 'must be positive');
    }
    if (recoveryBudget <= Duration.zero) {
      throw ArgumentError.value(recoveryBudget, 'recoveryBudget', 'must be positive');
    }
  }

  /// Advisory-lock key used by this instance.
  final int key;

  /// Interval between ownership checks.
  final Duration checkInterval;

  /// Maximum time spent trying to recover a lost owner session.
  final Duration recoveryBudget;

  final DateTime Function() _clock;
  final PostgresInterlockConnectionFactory _connectionFactory;
  final PostgresRecoverySchemaGate? _schemaGate;

  PostgresBackend? _backend;
  PostgresInterlockConnection? _connection;
  void Function(StorageException error)? _onFatalLoss;
  Timer? _ownershipTimer;
  Future<void>? _recovery;
  bool _checkingOwnership = false;
  bool _shutdown = false;
  bool _fatalSignalled = false;

  /// Opens the dedicated session and acquires exclusive serving ownership.
  Future<void> acquire({
    required PostgresBackend backend,
    required void Function(StorageException error) onFatalLoss,
  }) async {
    if (_backend != null || _connection != null) {
      throw StateError('PostgreSQL interlock is already acquired');
    }
    if (_shutdown) throw StateError('PostgreSQL interlock is shutting down');

    PostgresInterlockConnection? connection;
    try {
      connection = await _connectionFactory(backend.connectionPosture);
      if (!await connection.tryAcquire(key)) {
        throw PostgresStorageMessages.ownershipConflict(backend.databaseIdentity);
      }
      if (!connection.isOpen) {
        throw PostgresStorageMessages.ownershipConflict(backend.databaseIdentity);
      }
      _backend = backend;
      _onFatalLoss = onFatalLoss;
      _connection = connection;
      _observeClosure(connection);
      _startOwnershipChecks();
    } on StorageException {
      await _closeQuietly(connection);
      rethrow;
    } on Object {
      await _closeQuietly(connection);
      throw StorageConnectionException(
        operation: 'startup interlock',
        databaseIdentity: backend.databaseIdentity,
        guidance: 'PostgreSQL serving ownership could not be acquired. Check database reachability and try again.',
      );
    }
  }

  /// Prevents teardown-related connection closure from starting recovery.
  void beginShutdown() {
    _shutdown = true;
    _ownershipTimer?.cancel();
    _ownershipTimer = null;
  }

  /// Closes the dedicated session after backend shutdown.
  Future<void> release() async {
    beginShutdown();
    await _recovery;
    final connection = _connection;
    _connection = null;
    await connection?.close();
  }

  void _startOwnershipChecks() {
    _ownershipTimer?.cancel();
    _ownershipTimer = Timer.periodic(checkInterval, (_) => unawaited(_checkOwnership()));
  }

  void _observeClosure(PostgresInterlockConnection connection) {
    unawaited(connection.closed.then<void>((_) => _onLost(), onError: (Object _, StackTrace _) => _onLost()));
  }

  Future<void> _checkOwnership() async {
    if (_shutdown || _checkingOwnership || _recovery != null) return;
    final connection = _connection;
    if (connection == null) return;
    _checkingOwnership = true;
    try {
      if (!await connection.owns(key)) _onLost();
    } on Object {
      _onLost();
    } finally {
      _checkingOwnership = false;
    }
  }

  void _onLost() {
    if (_shutdown || _recovery != null) return;
    final backend = _backend;
    if (backend == null) return;

    backend._quarantine(PostgresStorageMessages.recoveryPending(backend.databaseIdentity));
    _ownershipTimer?.cancel();
    _ownershipTimer = null;
    final previous = _connection;
    _connection = null;
    _recovery = _recover(previous, _clock());
  }

  Future<void> _recover(PostgresInterlockConnection? previous, DateTime started) async {
    await _closeQuietly(previous);
    while (!_shutdown) {
      if (_budgetExpired(started)) {
        _terminal(PostgresStorageMessages.recoveryBudgetExhausted(_backend!.databaseIdentity));
        return;
      }

      PostgresInterlockConnection? candidate;
      try {
        candidate = await _connectionFactory(_backend!.connectionPosture);
        if (_budgetExpired(started)) {
          await _closeQuietly(candidate);
          _terminal(PostgresStorageMessages.recoveryBudgetExhausted(_backend!.databaseIdentity));
          return;
        }
        if (!await candidate.tryAcquire(key)) {
          await _closeQuietly(candidate);
          _terminal(PostgresStorageMessages.competingHolder(_backend!.databaseIdentity));
          return;
        }
      } on Object {
        await _closeQuietly(candidate);
        await _waitForRetry(started);
        continue;
      }

      _observeClosure(candidate);
      final int version;
      try {
        version = await candidate.serverVersion();
      } on Object {
        await _closeQuietly(candidate);
        await _waitForRetry(started);
        continue;
      }
      if (version < 140000) {
        await _closeQuietly(candidate);
        _terminal(PostgresStorageMessages.unsupportedVersion(_backend!.databaseIdentity));
        return;
      }

      try {
        await _schemaGate?.call(_backend!);
        await _backend!._validateRecoverySchema();
      } on SchemaIncompatibleException catch (error) {
        await _closeQuietly(candidate);
        _terminal(error);
        return;
      } on StorageException catch (error) {
        await _closeQuietly(candidate);
        _terminal(error);
        return;
      } on Object {
        await _closeQuietly(candidate);
        _terminal(PostgresStorageMessages.schemaFailure(_backend!.databaseIdentity));
        return;
      }

      if (_budgetExpired(started)) {
        await _closeQuietly(candidate);
        _terminal(PostgresStorageMessages.recoveryBudgetExhausted(_backend!.databaseIdentity));
        return;
      }
      if (!candidate.isOpen) {
        await _closeQuietly(candidate);
        await _waitForRetry(started);
        continue;
      }
      if (_shutdown) {
        await _closeQuietly(candidate);
        return;
      }

      _connection = candidate;
      _startOwnershipChecks();
      _backend!._releaseQuarantine();
      _recovery = null;
      return;
    }
  }

  Future<void> _waitForRetry(DateTime started) async {
    final remaining = recoveryBudget - _clock().difference(started);
    if (remaining <= Duration.zero || _shutdown) return;
    await Future<void>.delayed(remaining < _recoveryRetryInterval ? remaining : _recoveryRetryInterval);
  }

  bool _budgetExpired(DateTime started) => _clock().difference(started) >= recoveryBudget;

  void _terminal(StorageException error) {
    if (_fatalSignalled || _shutdown) return;
    _fatalSignalled = true;
    _onFatalLoss!(error);
  }

  static Future<PostgresInterlockConnection> _openConnection(PostgresConnectionPosture posture) async {
    final connection = await pg.Connection.open(
      posture.endpoint,
      settings: pg.ConnectionSettings(
        // Keep the owner session identifiable in pg_stat_activity as application_name=dartclaw.
        applicationName: 'dartclaw',
        connectTimeout: _connectTimeout,
        sslMode: posture.sslMode,
      ),
    );
    return _DriverInterlockConnection(connection);
  }

  static Future<void> _closeQuietly(PostgresInterlockConnection? connection) async {
    try {
      await connection?.close();
    } on Object {
      // Ownership recovery cannot depend on cleanup of a session the driver already lost.
    }
  }
}

final class _DriverInterlockConnection implements PostgresInterlockConnection {
  const new(this._connection);

  final pg.Connection _connection;

  @override
  bool get isOpen => _connection.isOpen;

  @override
  Future<void> get closed => _connection.closed;

  @override
  Future<bool> tryAcquire(int key) async {
    final result = await _connection.execute(
      pg.Sql(r'SELECT pg_try_advisory_lock($1) AS acquired', types: const [pg.Type.bigInteger]),
      parameters: [key],
    );
    return result.single.toColumnMap()['acquired'] == true;
  }

  @override
  Future<bool> owns(int key) async {
    final result = await _connection.execute(
      pg.Sql(
        r'''
          SELECT EXISTS (
            SELECT 1 FROM pg_locks
            WHERE locktype = 'advisory'
              AND classid = (($1::bigint >> 32) & 4294967295)::oid
              AND objid = ($1::bigint & 4294967295)::oid
              AND objsubid = 1
              AND pid = pg_backend_pid()
              AND granted
          ) AS owned
        ''',
        types: const [pg.Type.bigInteger],
      ),
      parameters: [key],
    );
    return result.single.toColumnMap()['owned'] == true;
  }

  @override
  Future<int> serverVersion() async {
    final result = await _connection.execute("SELECT current_setting('server_version_num')::integer AS version");
    return result.single.toColumnMap()['version'] as int;
  }

  @override
  Future<void> close() => _connection.close();
}
