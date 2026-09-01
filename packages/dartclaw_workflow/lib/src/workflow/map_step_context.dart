import 'dart:math' show min;

import 'package:logging/logging.dart';

import 'workflow_failure.dart';

/// Runtime state accumulator for a map/fan-out step execution.
///
/// Tracks the collection, concurrency config, in-flight count, result slots
/// (index-ordered), and budget exhaustion state. Local to [WorkflowExecutor]
/// for the duration of a single map step — not persisted.
class MapStepContext {
  static final Logger _log = Logger('MapStepContext');

  /// The resolved JSON array being iterated.
  final List<dynamic> collection;

  /// Maximum concurrent iterations. Null = unlimited.
  final int? maxParallel;

  /// Index-ordered result slots. Pre-sized to [collection.length], initially all null.
  final List<dynamic> results;

  /// Indices of iterations that have settled (success or failure).
  final Set<int> completedIndices = {};

  /// Indices of iterations that failed.
  final Set<int> failedIndices = {};

  /// Indices of iterations that were cancelled.
  final Set<int> cancelledIndices = {};

  /// Indices of iterations that settled blocked (`needsInput`, recoverable).
  ///
  /// Distinct from [failedIndices]: a blocked item stays retryable. Blocked
  /// indices are NOT added to [completedIndices], so the dependency scheduler
  /// never treats a blocked item's dependents as ready and the controller can
  /// re-attempt the item on resume.
  final Set<int> blockedIndices = {};

  /// Current number of in-flight (dispatched but not yet settled) iterations.
  int inFlightCount = 0;

  /// Set to true when the workflow budget is exhausted mid-execution.
  bool budgetExhausted = false;

  /// Set to true when a map/foreach item is interrupted without a settled item
  /// result. Signals the runner to stop dispatching siblings and return `null`
  /// so the executor exits without completing the run.
  bool aborted = false;

  /// Reason for the first abort, surfaced when the controller performs the
  /// deferred run pause after in-flight siblings have drained.
  String? abortReason;

  /// Typed failure per settled failed, blocked or cancelled index.
  ///
  /// Every in-memory decision that used to re-read a slot message (the
  /// aggregate ladder, the dependency hold) reads this instead; the slot's
  /// [kindKey] exists so a resumed run can rebuild the same values.
  final Map<int, WorkflowFailure> failures = {};

  /// Result-slot key marking a blocked item that must force a dependency hold
  /// even under `onFailure: continue` (nested-loop escalation).
  static const String requiresDependencyHoldKey = 'requires_dependency_hold';

  /// Result-slot key carrying the recorded failure's persisted discriminator.
  static const String kindKey = 'kind';

  new({required this.collection, required this.maxParallel}) : results = List<dynamic>.filled(collection.length, null);

  /// Records a successful result at [index].
  void recordResult(int index, dynamic value) {
    results[index] = value;
    completedIndices.add(index);
  }

  /// Records a failure at [index] with an error object.
  void recordFailure(int index, WorkflowFailure failure, String? taskId) {
    results[index] = {'error': true, kindKey: failure.kind, 'message': failure.message, 'task_id': taskId};
    failures[index] = failure;
    failedIndices.add(index);
    completedIndices.add(index);
    _log.warning('Map iteration [$index] failed (task=$taskId): ${failure.message}');
  }

  /// Records a cancelled iteration at [index].
  void recordCancelled(int index, WorkflowIterationCancelled failure) {
    results[index] = {'error': true, kindKey: failure.kind, 'message': failure.message};
    failures[index] = failure;
    cancelledIndices.add(index);
    completedIndices.add(index);
  }

  /// Records a blocked (recoverable) iteration at [index].
  ///
  /// Unlike [recordFailure], the index is left out of [completedIndices] so the
  /// item stays retryable: dependents never become ready off a blocked item and
  /// the controller can re-attempt it on resume.
  ///
  /// [requiresDependencyHold] marks a nested-loop escalation block: the
  /// controller must hold open dependents for human review even under
  /// `onFailure: continue`, whereas an ordinary `needsInput` block is
  /// recorded-and-advanced under that policy.
  void recordBlocked(
    int index,
    WorkflowIterationBlockedHold failure,
    String? taskId, {
    bool requiresDependencyHold = false,
  }) {
    results[index] = {
      'error': true,
      'blocked': true,
      kindKey: failure.kind,
      'message': failure.message,
      'task_id': taskId,
      if (requiresDependencyHold) requiresDependencyHoldKey: true,
    };
    failures[index] = failure;
    blockedIndices.add(index);
  }

  /// Whether any iterations failed.
  bool get hasFailures => failedIndices.isNotEmpty;

  /// Whether any iterations settled blocked (recoverable).
  bool get hasBlocked => blockedIndices.isNotEmpty;

  /// Number of successfully completed iterations.
  int get successCount => completedIndices.length - failedIndices.length - cancelledIndices.length;

  /// Number of cancelled iterations.
  int get cancelledCount => cancelledIndices.length;

  /// Number of iterations that settled blocked (recoverable).
  int get blockedCount => blockedIndices.length;

  /// Effective concurrency for dispatch.
  ///
  /// When [poolAvailable] is known, concurrency is bounded by pool capacity.
  /// When it is null, there is no pool cap available, so we fall back to the
  /// step's configured [maxParallel] semantics.
  int effectiveConcurrency(int? poolAvailable) {
    final cap = maxParallel;

    if (poolAvailable == null) {
      if (cap == null) return collection.length;
      if (cap <= 0) return 1;
      return min(cap, collection.length);
    }

    if (poolAvailable <= 0) return 1; // Always allow at least 1 queued task.
    if (cap == null) return min(poolAvailable, collection.length);
    if (cap <= 0) return 1;
    return min(cap, poolAvailable);
  }

  /// Extracts the `id` field from the item at [index] if present.
  String? itemId(int index) {
    final item = collection[index];
    if (item is Map) {
      final id = item['id'];
      if (id is! String) return null;
      final normalizedId = id.trim();
      return normalizedId.isEmpty ? null : normalizedId;
    }
    return null;
  }
}
