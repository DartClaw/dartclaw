part of 'workflow_executor.dart';

final class _IterationDispatchEngine {
  _IterationDispatchEngine({
    required this.mapCtx,
    required this.depGraph,
    required Iterable<int> pendingIndices,
    required this.completedIds,
    required this.promotedIds,
    required this.promotionAware,
  }) : pending = Queue<int>.from(pendingIndices);

  final MapStepContext mapCtx;
  final DependencyGraph depGraph;
  final Queue<int> pending;
  final Set<String> completedIds;
  final Set<String> promotedIds;
  final bool promotionAware;
  final inFlight = <int, Future<void>>{};
  var _wake = Completer<void>();

  bool get hasInFlight => inFlight.isNotEmpty;

  bool get isDispatchStalled => inFlight.isEmpty && pending.isNotEmpty;

  bool hasWork({bool hasSerializedWork = false}) => pending.isNotEmpty || inFlight.isNotEmpty || hasSerializedWork;

  int concurrencyCap({required int? poolAvailable, bool serialMode = false}) =>
      serialMode ? 1 : mapCtx.effectiveConcurrency(poolAvailable);

  bool canDispatch({required int? poolAvailable, bool serialMode = false}) =>
      inFlight.length < concurrencyCap(poolAvailable: poolAvailable, serialMode: serialMode) && pending.isNotEmpty;

  int? takeNextReadyIndex() {
    int? nextIndex;
    if (depGraph.hasDependencies) {
      final ready = depGraph.getReady(promotionAware ? promotedIds : completedIds);
      for (final idx in pending) {
        if (ready.contains(idx)) {
          nextIndex = idx;
          break;
        }
      }
    } else {
      nextIndex = pending.first;
    }
    if (nextIndex != null) pending.remove(nextIndex);
    return nextIndex;
  }

  void track(int iterIndex, Future<void> iterationFuture, {required void Function(int iterIndex) onSettled}) {
    inFlight[iterIndex] = iterationFuture.whenComplete(() {
      inFlight.remove(iterIndex);
      mapCtx.inFlightCount = inFlight.length;
      onSettled(iterIndex);
      wake();
    });
  }

  /// Cancels every remaining pending iteration with [message] and returns their
  /// indices in cancellation order. The map controller ignores the result; the
  /// foreach controller uses it to emit its per-iteration completion events.
  List<int> cancelPending(String message) {
    final cancelled = <int>[];
    while (pending.isNotEmpty) {
      final index = pending.removeFirst();
      mapCtx.recordCancelled(index, message);
      cancelled.add(index);
    }
    return cancelled;
  }

  Future<void> waitForWake() async {
    if (inFlight.isEmpty) return;
    await _wake.future;
    _wake = Completer<void>();
  }

  void wake() {
    if (!_wake.isCompleted) {
      _wake.complete();
    }
  }
}

/// Resolves a map/foreach controller's collection from its raw context value,
/// applying the single-key-Map auto-unwrap (LLM output normalization: a
/// `{ "stories": [...] }` wrapper unwraps to its inner list).
///
/// Returns the resolved list on success, or an [error] message when the value is
/// missing or is not a list. The error/log strings are byte-identical across
/// both controllers modulo [stepKind] (`"Foreach"` / `"Map"`), which is the only
/// difference between the two hand-copied blocks this replaces.
({List<dynamic>? collection, String? error}) resolveIterationCollection(
  Object? rawCollection, {
  required String stepKind,
  required String stepId,
  required String mapOverKey,
}) {
  if (rawCollection == null) {
    return (collection: null, error: "$stepKind step '$stepId': context key '$mapOverKey' is null or missing");
  }
  final resolved = switch (rawCollection) {
    final List<dynamic> list => list,
    final Map<String, dynamic> map when map.length == 1 && map.values.first is List => () {
      WorkflowExecutor._log.info(
        '$stepKind step \'$stepId\': auto-unwrapped Map key \'${map.keys.first}\' '
        'to List (${(map.values.first as List).length} items)',
      );
      return map.values.first as List<dynamic>;
    }(),
    final Map<Object?, Object?> map when map.length == 1 && map.values.first is List => () {
      final normalized = map.map((key, value) => MapEntry(key.toString(), value));
      WorkflowExecutor._log.info(
        '$stepKind step \'$stepId\': auto-unwrapped Map key \'${normalized.keys.first}\' '
        'to List (${(normalized.values.first as List).length} items)',
      );
      return normalized.values.first as List<dynamic>;
    }(),
    _ => null,
  };
  if (resolved == null) {
    return (
      collection: null,
      error:
          "$stepKind step '$stepId': context key '$mapOverKey' is not a List "
          '(got ${rawCollection.runtimeType})',
    );
  }
  return (collection: resolved, error: null);
}

void restoreIterationProgress(
  MapStepContext mapCtx,
  Set<String> completedIds,
  WorkflowExecutionCursor? cursor, {
  required WorkflowExecutionCursorNodeType nodeType,
  required int collectionLength,
  bool markFailedAndCancelledItemsReady = true,
}) {
  if (cursor == null || cursor.nodeType != nodeType) return;

  final safeResultSlots = cursor.resultSlots.isEmpty
      ? List<dynamic>.filled(collectionLength, null)
      : List<dynamic>.from(cursor.resultSlots);
  if (safeResultSlots.length < collectionLength) {
    safeResultSlots.addAll(List<dynamic>.filled(collectionLength - safeResultSlots.length, null));
  } else if (safeResultSlots.length > collectionLength) {
    safeResultSlots.removeRange(collectionLength, safeResultSlots.length);
  }

  final failed = cursor.failedIndices.toSet();
  final cancelled = cursor.cancelledIndices.toSet();
  for (final index in cursor.completedIndices) {
    if (index < 0 || index >= collectionLength) continue;
    final slotValue = safeResultSlots[index];
    final isFailed = failed.contains(index);
    final isCancelled = cancelled.contains(index);
    if (isCancelled) {
      mapCtx.recordCancelled(index, _restoredIterationCancellationMessage(slotValue));
    } else if (isFailed) {
      final restoredFailure = _restoredIterationFailureMessage(slotValue);
      if (restoredFailure.startsWith('promotion-conflict')) {
        continue;
      }
      mapCtx.recordFailure(index, restoredFailure, _restoredIterationTaskId(slotValue));
    } else {
      mapCtx.recordResult(index, slotValue);
    }
    final itemId = mapCtx.itemId(index);
    final dependencyReady = markFailedAndCancelledItemsReady || (!isFailed && !isCancelled);
    if (itemId != null && dependencyReady) {
      completedIds.add(itemId);
    }
  }
}

String _restoredIterationFailureMessage(dynamic slotValue) =>
    slotValue is Map && slotValue['message'] is String ? slotValue['message'] as String : 'Failed before restart';

String _restoredIterationCancellationMessage(dynamic slotValue) =>
    slotValue is Map && slotValue['message'] is String ? slotValue['message'] as String : 'Cancelled before restart';

String? _restoredIterationTaskId(dynamic slotValue) =>
    slotValue is Map && slotValue['task_id'] is String ? slotValue['task_id'] as String : null;

enum _SerializeRemainingPhase {
  enacting,
  drained;

  static _SerializeRemainingPhase? parse(Object? value) => switch (value) {
    'enacting' => enacting,
    'drained' => drained,
    _ => null,
  };
}

final class _SerializeRemainingState {
  const _SerializeRemainingState({
    required this.stepId,
    required this.phase,
    required this.iterIndex,
    required this.failedAttemptNumber,
    required this.eventEmitted,
    this.settleDeadlineIso,
  });

  static const contextKey = '_merge_resolve.serializeRemaining';

  final String stepId;
  final _SerializeRemainingPhase phase;
  final int iterIndex;
  final int failedAttemptNumber;
  final bool eventEmitted;
  final String? settleDeadlineIso;

  static _SerializeRemainingState? read(WorkflowContext context, {String? stepId}) {
    final raw = context[contextKey];
    if (raw is Map) {
      final rawStepId = raw['stepId'];
      if (rawStepId is! String || (stepId != null && rawStepId != stepId)) return null;
      final phase = _SerializeRemainingPhase.parse(raw['phase']);
      final iterIndex = raw['iterIndex'];
      final failedAttemptNumber = raw['failedAttemptNumber'];
      final eventEmitted = raw['eventEmitted'];
      if (phase == null || iterIndex is! int || failedAttemptNumber is! int) return null;
      return _SerializeRemainingState(
        stepId: rawStepId,
        phase: phase,
        iterIndex: iterIndex,
        failedAttemptNumber: failedAttemptNumber,
        eventEmitted: eventEmitted == true,
        settleDeadlineIso: raw['settleDeadlineIso'] is String ? raw['settleDeadlineIso'] as String : null,
      );
    }
    return null;
  }

  _SerializeRemainingState copyWith({
    _SerializeRemainingPhase? phase,
    int? iterIndex,
    int? failedAttemptNumber,
    bool? eventEmitted,
    String? settleDeadlineIso,
  }) => _SerializeRemainingState(
    stepId: stepId,
    phase: phase ?? this.phase,
    iterIndex: iterIndex ?? this.iterIndex,
    failedAttemptNumber: failedAttemptNumber ?? this.failedAttemptNumber,
    eventEmitted: eventEmitted ?? this.eventEmitted,
    settleDeadlineIso: settleDeadlineIso ?? this.settleDeadlineIso,
  );

  void writeTo(WorkflowContext context) {
    context[contextKey] = {
      'stepId': stepId,
      'phase': phase.name,
      'iterIndex': iterIndex,
      'failedAttemptNumber': failedAttemptNumber,
      'eventEmitted': eventEmitted,
      if (settleDeadlineIso != null) 'settleDeadlineIso': settleDeadlineIso,
    };
  }
}

String _newSerializeRemainingSettleDeadlineIso(Duration timeout) => DateTime.now().add(timeout).toIso8601String();

Duration _remainingSerializeRemainingSettleTimeout(_SerializeRemainingState state, Duration timeout) {
  final deadlineIso = state.settleDeadlineIso;
  if (deadlineIso == null) return timeout;
  final deadline = DateTime.tryParse(deadlineIso);
  if (deadline == null) return timeout;
  final remaining = deadline.difference(DateTime.now());
  return remaining.isNegative ? Duration.zero : remaining;
}
