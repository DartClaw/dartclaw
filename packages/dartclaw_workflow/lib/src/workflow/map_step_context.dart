import 'dart:math' show min;

import 'package:logging/logging.dart';

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

  /// Maximum allowed collection size (validated before construction).
  final int maxItems;

  /// Index-ordered result slots. Pre-sized to [collection.length], initially all null.
  final List<dynamic> results;

  /// Indices of iterations that have settled (success or failure).
  final Set<int> completedIndices = {};

  /// Indices of iterations that failed.
  final Set<int> failedIndices = {};

  /// Indices of iterations that were cancelled.
  final Set<int> cancelledIndices = {};

  /// Current number of in-flight (dispatched but not yet settled) iterations.
  int inFlightCount = 0;

  /// Set to true when the workflow budget is exhausted mid-execution.
  bool budgetExhausted = false;

  MapStepContext({required this.collection, required this.maxParallel, required this.maxItems})
    : results = List<dynamic>.filled(collection.length, null);

  /// Records a successful result at [index].
  void recordResult(int index, dynamic value) {
    results[index] = value;
    completedIndices.add(index);
  }

  /// Records a failure at [index] with an error object.
  void recordFailure(int index, String message, String? taskId) {
    results[index] = {'error': true, 'message': message, 'task_id': taskId};
    failedIndices.add(index);
    completedIndices.add(index);
    _log.warning('Map iteration [$index] failed (task=$taskId): $message');
  }

  /// Records a cancelled iteration at [index].
  void recordCancelled(int index, String message) {
    results[index] = {'error': true, 'message': message};
    cancelledIndices.add(index);
    completedIndices.add(index);
  }

  /// Whether any iterations failed.
  bool get hasFailures => failedIndices.isNotEmpty;

  /// Number of successfully completed iterations.
  int get successCount => completedIndices.length - failedIndices.length - cancelledIndices.length;

  /// Number of cancelled iterations.
  int get cancelledCount => cancelledIndices.length;

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
