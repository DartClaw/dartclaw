import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;

/// Named fault points in one canonical index reconciliation.
enum IndexReconcileTransition {
  /// The rebuild destination is ready.
  siblingCreated,

  /// Canonical rows were populated.
  populated,

  /// Index integrity and row parity were validated.
  validated,

  /// The rebuild destination is about to close.
  beforeClose,

  /// The rebuild destination closed.
  closed,

  /// Atomic publication is about to run.
  beforeSwap,

  /// Publication completed.
  swapped,
}

/// Observes or injects one reconciliation transition.
typedef IndexReconcileHook = Future<void> Function(IndexReconcileTransition transition);

/// Replaces the target with a closed sibling database.
typedef IndexFileReplace = void Function(File sibling, String targetPath);

/// Opens one full-text index and its owning database backend.
typedef IndexStoreOpener = Future<(FullTextIndex, DatabaseBackend)> Function(String path);

/// Creates an index over a supplied transaction or live backend.
typedef TransactionalIndexFactory = FullTextIndex Function(DatabaseBackend backend);

/// Populates and validates one rebuild destination.
typedef IndexPopulateAndValidate<T> = Future<T> Function(FullTextIndex index, Future<void> Function() populated);

/// Publishes a validated canonical index through backend-specific mechanics.
abstract interface class IndexRebuildTarget {
  /// Whether a live target is available for fast-path validation.
  Future<bool> isPresent();

  /// Runs [body] against the current live index.
  Future<T> validateLive<T>(Future<T> Function(FullTextIndex index) body);

  /// Rebuilds and publishes one validated replacement.
  Future<T> rebuild<T>({
    required IndexPopulateAndValidate<T> populateAndValidate,
    required IndexReconcileHook transition,
  });
}

/// Publishes an SQLite index by replacing it with a closed sibling file.
final class SiblingFileRebuildTarget implements IndexRebuildTarget {
  /// Creates a sibling-file publication target.
  const new({required this.targetPath, required IndexStoreOpener opener, required IndexFileReplace replaceFile})
    : _opener = opener,
      _replaceFile = replaceFile;

  /// Published database path.
  final String targetPath;
  final IndexStoreOpener _opener;
  final IndexFileReplace _replaceFile;

  @override
  Future<bool> isPresent() async =>
      FileSystemEntity.typeSync(targetPath, followLinks: false) == FileSystemEntityType.file;

  @override
  Future<T> validateLive<T>(Future<T> Function(FullTextIndex index) body) async {
    final (index, backend) = await _opener(targetPath);
    try {
      return await body(index);
    } finally {
      await backend.close();
    }
  }

  @override
  Future<T> rebuild<T>({
    required IndexPopulateAndValidate<T> populateAndValidate,
    required IndexReconcileHook transition,
  }) async {
    final target = File(targetPath);
    target.parent.createSync(recursive: true);
    final sibling = File(
      p.join(
        target.parent.path,
        '.${p.basename(target.path)}.dartclaw-rebuild-$pid-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    final backup = File('${sibling.path}.previous');
    var swapped = false;
    DatabaseBackend? backend;
    try {
      final opened = await _opener(sibling.path);
      final index = opened.$1;
      backend = opened.$2;
      await transition(IndexReconcileTransition.siblingCreated);
      final result = await populateAndValidate(index, () => transition(IndexReconcileTransition.populated));
      await transition(IndexReconcileTransition.validated);
      await transition(IndexReconcileTransition.beforeClose);
      await backend.close();
      backend = null;
      await transition(IndexReconcileTransition.closed);
      await transition(IndexReconcileTransition.beforeSwap);
      if (FileSystemEntity.typeSync(target.path, followLinks: false) == FileSystemEntityType.file) {
        target.copySync(backup.path);
      }
      swapped = true;
      _replaceFile(sibling, target.path);
      await transition(IndexReconcileTransition.swapped);
      if (backup.existsSync()) backup.deleteSync();
      return result;
    } catch (error, stackTrace) {
      try {
        await backend?.close();
      } catch (_) {}
      if (swapped) {
        try {
          if (backup.existsSync()) {
            if (target.existsSync()) target.deleteSync();
            backup.renameSync(target.path);
          } else if (target.existsSync()) {
            target.deleteSync();
          }
        } catch (rollbackError) {
          Error.throwWithStackTrace(
            StateError('Index reconciliation failed: $error; target rollback failed: $rollbackError'),
            stackTrace,
          );
        }
      }
      try {
        if (sibling.existsSync()) sibling.deleteSync();
      } catch (_) {}
      try {
        if (backup.existsSync()) backup.deleteSync();
      } catch (_) {}
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

/// Publishes a rebuilt index by committing one database transaction.
final class TransactionalRebuildTarget implements IndexRebuildTarget {
  /// Creates a transactional publication target.
  const new(this._backend, {required TransactionalIndexFactory indexFactory}) : _indexFactory = indexFactory;

  final DatabaseBackend _backend;
  final TransactionalIndexFactory _indexFactory;

  @override
  Future<bool> isPresent() async => true;

  @override
  Future<T> validateLive<T>(Future<T> Function(FullTextIndex index) body) => body(_indexFactory(_backend));

  @override
  Future<T> rebuild<T>({
    required IndexPopulateAndValidate<T> populateAndValidate,
    required IndexReconcileHook transition,
  }) async {
    final result = await _backend.transaction((tx) async {
      final index = _indexFactory(tx);
      await transition(IndexReconcileTransition.siblingCreated);
      final result = await populateAndValidate(index, () => transition(IndexReconcileTransition.populated));
      await transition(IndexReconcileTransition.validated);
      await transition(IndexReconcileTransition.beforeClose);
      await transition(IndexReconcileTransition.closed);
      await transition(IndexReconcileTransition.beforeSwap);
      return result;
    });
    await transition(IndexReconcileTransition.swapped);
    return result;
  }
}
