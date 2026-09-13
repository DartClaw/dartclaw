import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

const _dispatchAttemptLimit = 3;
const _dispatchRetryDelay = Duration(milliseconds: 50);
const _defaultPoolWaitCeiling = Duration(seconds: 30);

typedef PostgresDispatchAttempt<T> = Future<T> Function(void Function() markDispatched);

/// Safe projection of an explicit PostgreSQL server response.
final class PostgresServerFailure implements Exception {
  /// Creates a server failure carrying only its SQLSTATE.
  const new(this.sqlState);

  /// PostgreSQL SQLSTATE, when supplied.
  final String? sqlState;
}

/// Applies the PostgreSQL retry and dispatch-boundary contract.
final class PostgresDispatchPolicy {
  /// Creates the production policy for one safe database identity.
  const new(
    this.databaseIdentity, {
    int attemptLimit = _dispatchAttemptLimit,
    Duration retryDelay = _dispatchRetryDelay,
    Duration poolWaitCeiling = _defaultPoolWaitCeiling,
  }) : _attemptLimit = attemptLimit,
       _retryDelay = retryDelay,
       _poolWaitCeiling = poolWaitCeiling;

  /// Safe host, port, and database label.
  final String databaseIdentity;
  final int _attemptLimit;
  final Duration _retryDelay;
  final Duration _poolWaitCeiling;

  /// Maximum wait used by the driver's pool semaphore.
  Duration get poolWaitCeiling => _poolWaitCeiling;

  /// Runs one operation, retrying only failures observed before dispatch.
  Future<T> run<T>(
    String operation,
    PostgresDispatchAttempt<T> attempt, {
    bool timeoutMeansPoolExhausted = true,
    bool Function(Object error)? passThrough,
  }) async {
    for (var number = 1; number <= _attemptLimit; number++) {
      var dispatched = false;
      try {
        return await attempt(() => dispatched = true);
      } on StorageException {
        rethrow;
      } on PostgresServerFailure catch (error) {
        if (!dispatched && number < _attemptLimit) {
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        if (!dispatched) throw _connection(operation);
        throw StorageQueryException(
          operation: operation,
          databaseIdentity: databaseIdentity,
          sqlState: error.sqlState,
          guidance: 'Correct the request before retrying.',
        );
      } on TimeoutException {
        if (!dispatched && timeoutMeansPoolExhausted) {
          throw StoragePoolExhaustedException(
            operation: operation,
            databaseIdentity: databaseIdentity,
            guidance: 'Wait for active database work to finish before retrying.',
          );
        }
        if (!dispatched && number < _attemptLimit) {
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        if (!dispatched) throw _connection(operation);
        throw _unknown(operation);
      } on Object catch (error) {
        if (passThrough?.call(error) ?? false) rethrow;
        if (!dispatched && number < _attemptLimit) {
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        if (!dispatched) throw _connection(operation, error);
        throw _unknown(operation);
      }
    }
    throw _connection(operation);
  }

  StorageConnectionException _connection(String operation, [Object? error]) => StorageConnectionException(
    operation: operation,
    databaseIdentity: databaseIdentity,
    guidance: _tlsFailureGuidance(error) ?? 'Check database availability and configuration before retrying.',
  );

  StorageUnknownOutcomeException _unknown(String operation) => StorageUnknownOutcomeException(
    operation: operation,
    databaseIdentity: databaseIdentity,
    guidance: 'Verify database state before retrying this operation.',
  );
}

String? _tlsFailureGuidance(Object? error) {
  if (error == null) return null;
  final text = error.toString().toLowerCase();
  if (!text.contains('certificate') && !text.contains('handshake')) return null;
  if (text.contains('unknown ca') ||
      text.contains('self signed') ||
      text.contains('unable to get local issuer') ||
      text.contains('unable to verify the first certificate')) {
    return 'The PostgreSQL certificate authority is not trusted. Install a certificate issued by the platform trust store.';
  }
  return 'PostgreSQL TLS certificate verification failed. Check the certificate hostname and validity period.';
}
