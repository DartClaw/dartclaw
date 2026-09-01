part of 'workflow_executor.dart';

final class _IterationDispatchEngine {
  new({
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

  /// Cancels every remaining pending iteration with [failure] and returns their
  /// indices in cancellation order, which the foreach controller uses to emit
  /// its per-iteration completion events.
  List<int> cancelPending(WorkflowIterationCancelled failure) {
    final cancelled = <int>[];
    while (pending.isNotEmpty) {
      final index = pending.removeFirst();
      mapCtx.recordCancelled(index, failure);
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

/// Rehydrates [mapCtx] from a persisted [cursor].
///
/// Returns a [WorkflowLegacyIterationStateFailure] instead of restoring when a
/// failed slot carries no discriminator this release recognises: such a slot
/// may be a promotion conflict, and restoring it as an ordinary failure would
/// silently make its dependents permanently undispatchable. Nothing is mutated
/// on that path, so the persisted cursor still describes where the run stopped.
WorkflowLegacyIterationStateFailure? restoreIterationProgress(
  MapStepContext mapCtx,
  Set<String> completedIds,
  WorkflowExecutionCursor? cursor, {
  required String stepId,
  required WorkflowExecutionCursorNodeType nodeType,
  required int collectionLength,
  bool markFailedAndCancelledItemsReady = true,
}) {
  if (cursor == null || cursor.nodeType != nodeType) return null;

  final safeResultSlots = _sizedResultSlots(cursor.resultSlots, collectionLength);
  final failed = cursor.failedIndices.toSet();
  final cancelled = cursor.cancelledIndices.toSet();
  final scan = _restoredFailedSlots(
    cursor,
    safeResultSlots,
    failed: failed,
    cancelled: cancelled,
    collectionLength: collectionLength,
  );
  final legacyIndex = scan.legacyIndex;
  if (legacyIndex != null) return _legacyIterationStateFailure(stepId, legacyIndex);
  final restoredFailures = scan.failures;

  for (final index in cursor.completedIndices) {
    if (index < 0 || index >= collectionLength) continue;
    final slotValue = safeResultSlots[index];
    final isFailed = failed.contains(index);
    final isCancelled = cancelled.contains(index);
    if (isCancelled) {
      mapCtx.recordCancelled(index, WorkflowIterationCancelled(_restoredIterationCancellationMessage(slotValue)));
    } else if (_restoresAsFailure(index, failed: failed, cancelled: cancelled, collectionLength: collectionLength)) {
      final restoredFailure = restoredFailures[index]!;
      if (restoredFailure is WorkflowPromotionConflictFailure) {
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
  return null;
}

/// Rebuilds the typed failure of every failed slot the cursor carries.
///
/// A non-null `legacyIndex` names the first slot whose discriminator this
/// release does not recognise; the caller fails the resume rather than
/// restoring it, and nothing has been mutated by then.
({Map<int, WorkflowFailure> failures, int? legacyIndex}) _restoredFailedSlots(
  WorkflowExecutionCursor cursor,
  List<dynamic> safeResultSlots, {
  required Set<int> failed,
  required Set<int> cancelled,
  required int collectionLength,
}) {
  final failures = <int, WorkflowFailure>{};
  for (final index in cursor.completedIndices) {
    if (!_restoresAsFailure(index, failed: failed, cancelled: cancelled, collectionLength: collectionLength)) continue;
    final restored = _restoredIterationFailure(safeResultSlots[index]);
    if (restored == null) return (failures: failures, legacyIndex: index);
    failures[index] = restored;
  }
  return (failures: failures, legacyIndex: null);
}

/// The one index filter the pre-scan and the restore loop share.
///
/// Cancellation wins over failure, as it does everywhere else in the engine.
/// Written once because the restore loop consumes the pre-scan's map under a
/// non-null assertion: two filters that drifted apart would crash mid-restore,
/// after earlier indices had already been recorded.
bool _restoresAsFailure(
  int index, {
  required Set<int> failed,
  required Set<int> cancelled,
  required int collectionLength,
}) => index >= 0 && index < collectionLength && failed.contains(index) && !cancelled.contains(index);

List<dynamic> _sizedResultSlots(List<dynamic> resultSlots, int collectionLength) {
  final sized = resultSlots.isEmpty ? List<dynamic>.filled(collectionLength, null) : List<dynamic>.from(resultSlots);
  if (sized.length < collectionLength) {
    sized.addAll(List<dynamic>.filled(collectionLength - sized.length, null));
  } else if (sized.length > collectionLength) {
    sized.removeRange(collectionLength, sized.length);
  }
  return sized;
}

WorkflowLegacyIterationStateFailure _legacyIterationStateFailure(String stepId, int index) =>
    WorkflowLegacyIterationStateFailure(
      "Foreach step '$stepId' cannot resume: iteration $index was recorded by a release with a different "
      'workflow failure vocabulary, so its promotion-conflict recovery path cannot be reconstructed. '
      'Start a fresh run.',
    );

WorkflowFailure? _restoredIterationFailure(dynamic slotValue) {
  if (slotValue is! Map) return null;
  final message = slotValue['message'];
  return workflowFailureFromPersisted(
    slotValue[MapStepContext.kindKey],
    message is String ? message : 'Failed before restart',
  );
}

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
  const new({
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
