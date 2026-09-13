import 'dart:io';

import 'package:path/path.dart' as p;

import 'sqlite_backend.dart';

const _legacyStoreName = 'tasks.db';
// Derived indexes do not make an inactive store authoritative.
const authoritativeStoreContentTables = <String>['tasks', 'goals', 'workflow_runs', 'kg_facts'];

/// Refuses a legacy-store adoption that cannot complete safely.
final class AuthoritativeStoreAdoptionException implements Exception {
  /// Creates an adoption failure with an operator-facing [message].
  const new(this.message, {this.cause});

  /// Safe filesystem diagnostic and recovery guidance.
  final String message;

  /// Underlying filesystem or database failure, when available.
  final Object? cause;

  @override
  String toString() => message;
}

/// Content classification for one existing authoritative store.
enum AuthoritativeStoreContentState {
  /// None of the authoritative content tables contains a row.
  empty,

  /// At least one authoritative content table contains a row.
  nonEmpty,

  /// The store exists but its content could not be inspected.
  couldNotVerify,
}

/// Read-only result of looking for the authoritative store under either name.
sealed class AuthoritativeStoreProbe {
  const new();
}

/// No authoritative store exists under either supported filename.
final class AuthoritativeStoreAbsent extends AuthoritativeStoreProbe {
  /// Creates an absent result.
  const new();
}

/// Both current and legacy filenames exist, so store identity is ambiguous.
final class AuthoritativeStoreAmbiguous extends AuthoritativeStoreProbe {
  /// Creates an ambiguous result naming both files.
  const new({required this.currentPath, required this.legacyPath});

  /// Path to the current filename.
  final String currentPath;

  /// Path to the legacy filename.
  final String legacyPath;
}

/// One authoritative store exists under [path].
final class AuthoritativeStorePresent extends AuthoritativeStoreProbe {
  /// Creates a present result with its [content] classification.
  const new({required this.path, required this.content, this.error});

  /// Existing current or legacy store path.
  final String path;

  /// Whether authoritative content could be found.
  final AuthoritativeStoreContentState content;

  /// Inspection failure when [content] is [AuthoritativeStoreContentState.couldNotVerify].
  final Object? error;
}

/// Atomically adopts a legacy authoritative store after checkpointing its WAL.
///
/// If both filenames exist, the method refuses with recovery guidance. It also
/// refuses checkpoint or rename failures before the store is opened for use.
/// A refused rename preserves committed data under the legacy name; the completed
/// checkpoint may already have changed its main file and sidecar bytes.
Future<void> adoptLegacyAuthoritativeStore(String dartclawDbPath) async {
  final current = File(dartclawDbPath);
  final legacyPath = p.join(p.dirname(dartclawDbPath), _legacyStoreName);
  final legacy = File(legacyPath);
  final currentExists = current.existsSync();
  final legacyExists = legacy.existsSync();

  if (currentExists && legacyExists) {
    throw AuthoritativeStoreAdoptionException(
      'Authoritative store identity is ambiguous: ${current.path} '
      '(${current.lengthSync()} bytes) and ${legacy.path} '
      '(${legacy.lengthSync()} bytes) both exist. Keep the file holding your '
      'data and remove or archive the other.',
    );
  }
  if (currentExists || !legacyExists) return;

  Object? checkpointFailure;
  SqliteBackend? backend;
  try {
    backend = await SqliteBackend.open(legacy.path);
    final rows = await backend.query('PRAGMA wal_checkpoint(TRUNCATE)');
    final busy = rows.isEmpty ? 0 : rows.first.values.first as int;
    if (busy != 0) {
      checkpointFailure = StateError('The legacy authoritative store is in use by another process.');
    }
  } on Object catch (error) {
    checkpointFailure = error;
  }

  if (backend != null) {
    try {
      await backend.close();
    } on Object catch (error) {
      checkpointFailure ??= error;
    }
  }

  if (checkpointFailure != null) {
    final message = checkpointFailure is StateError && checkpointFailure.message.contains('in use')
        ? '${checkpointFailure.message} Legacy store: ${legacy.path}'
        : 'Could not checkpoint legacy authoritative store at ${legacy.path}: $checkpointFailure';
    throw AuthoritativeStoreAdoptionException(message, cause: checkpointFailure);
  }

  try {
    legacy.renameSync(current.path);
  } on FileSystemException catch (error) {
    if (current.existsSync() && !legacy.existsSync()) return;
    throw AuthoritativeStoreAdoptionException(
      'Could not rename legacy authoritative store ${legacy.path} to ${current.path}: $error',
      cause: error,
    );
  }

  for (final suffix in const ['-wal', '-shm']) {
    final sidecar = File('${legacy.path}$suffix');
    if (sidecar.existsSync()) sidecar.deleteSync();
  }
}

/// Reports an authoritative store under either filename without modifying it.
Future<AuthoritativeStoreProbe> probeAuthoritativeStore(String dartclawDbPath) async {
  final current = File(dartclawDbPath);
  final legacy = File(p.join(p.dirname(dartclawDbPath), _legacyStoreName));
  final currentExists = current.existsSync();
  final legacyExists = legacy.existsSync();

  if (currentExists && legacyExists) {
    return AuthoritativeStoreAmbiguous(currentPath: current.path, legacyPath: legacy.path);
  }
  if (!currentExists && !legacyExists) return const AuthoritativeStoreAbsent();

  final store = currentExists ? current : legacy;
  SqliteBackend? backend;
  Object? failure;
  var content = AuthoritativeStoreContentState.empty;
  try {
    backend = await SqliteBackend.openReadOnly(store.path);
    final tableRows = await backend.query("SELECT name FROM sqlite_master WHERE type = 'table'");
    final tables = tableRows.map((row) => row['name']).whereType<String>().toSet();
    for (final table in authoritativeStoreContentTables) {
      if (!tables.contains(table)) continue;
      if ((await backend.query('SELECT 1 FROM $table LIMIT 1')).isNotEmpty) {
        content = AuthoritativeStoreContentState.nonEmpty;
        break;
      }
    }
  } on Object catch (error) {
    failure = error;
    content = AuthoritativeStoreContentState.couldNotVerify;
  }

  if (backend != null) {
    try {
      await backend.close();
    } on Object catch (error) {
      failure ??= error;
      content = AuthoritativeStoreContentState.couldNotVerify;
    }
  }
  return AuthoritativeStorePresent(path: store.path, content: content, error: failure);
}
