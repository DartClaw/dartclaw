import 'package:dartclaw_kernel/dartclaw_kernel.dart';

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
