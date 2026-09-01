part of 'turn_runner.dart';

/// Turn wait-state, early-cancel, and crash-recovery bookkeeping for
/// [TurnRunner].
///
/// Split out from `turn_runner.dart` as a same-library extension so the core
/// execution loop and this status/cancel state machine live in separate files
/// while sharing private state. Behavior is identical to inline methods.
extension TurnRunnerCancellation on TurnRunner {
  TurnStatusSnapshot turnStatus(String sessionId) {
    final context = _activeTurns[sessionId];
    if (context == null) {
      _evictExpiredOutcomes();
      TurnOutcome? latest;
      for (final entry in _recentOutcomes.values) {
        final outcome = entry.outcome;
        if (outcome.sessionId != sessionId) continue;
        if (latest == null || outcome.completedAt.isAfter(latest.completedAt)) {
          latest = outcome;
        }
      }
      return latest == null
          ? TurnStatusSnapshot.idle(sessionId)
          : TurnStatusSnapshot.fromOutcome(
              sessionId: sessionId,
              outcome: latest,
              provider: providerId,
              taskId: _recentTaskIds[latest.turnId],
            );
    }

    final wait = _lockManager.waitSnapshot(sessionId);
    final runtimeWait = _runtimeWaits[sessionId]?.snapshot;
    final visibleRuntimeWait = _visibleRuntimeWait(context.turnId, runtimeWait);
    final state = _activeWaitState(context.turnId, wait, runtimeWait);
    final waitReason = wait != null ? TurnWaitReason.sessionLock : visibleRuntimeWait?.reason;

    return TurnStatusSnapshot(
      sessionId: sessionId,
      turnId: context.turnId,
      provider: providerId,
      taskId: context.taskId,
      state: state,
      waitReason: waitReason,
      waitingSince: wait?.waitingSince ?? visibleRuntimeWait?.waitingSince,
      stuckSince: wait?.stuckSince ?? visibleRuntimeWait?.stuckSince,
      globalTimeoutAt: _effectiveTurnTimeout(context) > Duration.zero
          ? context.startedAt.add(_effectiveTurnTimeout(context))
          : null,
      canCancel: _canCancel(state, waitReason, runtimeWait: runtimeWait),
    );
  }

  Future<TurnCancelResult> cancelTurnById(
    String sessionId,
    String turnId,
    TurnCancelReason reason, {
    bool enforceCanCancel = true,
    TurnLimitBreach? limitBreach,
    Duration? limitBudget,
  }) async {
    final active = _activeTurns[sessionId];
    if (active == null || active.turnId != turnId) {
      final recent = recentOutcome(sessionId, turnId);
      if (recent != null && (recent.status == TurnStatus.completed || recent.status == TurnStatus.cancelled)) {
        return TurnCancelResult(
          status: recent.status == TurnStatus.completed ? TurnWaitState.completed : TurnWaitState.cancelled,
          releasedSessionLock: false,
        );
      }
      if (recent != null) {
        throw const TurnCancelException('TURN_NOT_CANCELLABLE', 'Turn is not cancellable', statusCode: 409);
      }
      throw const TurnCancelException('TURN_NOT_FOUND', 'Turn not found', statusCode: 404);
    }

    if (_cancellingTurns.contains(turnId)) {
      return const TurnCancelResult(status: TurnWaitState.cancelled, releasedSessionLock: false);
    }

    if (_postProviderTurns.contains(turnId)) {
      throw const TurnCancelException('TURN_NOT_CANCELLABLE', 'Turn is not cancellable', statusCode: 409);
    }

    if (enforceCanCancel) {
      final snapshot = turnStatus(sessionId);
      if (!snapshot.canCancel) {
        throw const TurnCancelException('TURN_NOT_CANCELLABLE', 'Turn is not cancellable', statusCode: 409);
      }
    }

    if (limitBreach != null) {
      if (limitBudget == null) throw ArgumentError.notNull('limitBudget');
      _limitBreaches[turnId] = (breach: limitBreach, budget: limitBudget);
    }

    _cancellingTurns.add(turnId);
    _emitWaitState(sessionId, TurnWaitState.cancelling);
    _cancelledTurns.add(turnId);
    _externallyCompletedTurns.add(turnId);
    _acceptedCancelCleanupPending.add(turnId);
    final recoveryCompleter = Completer<void>();
    final recovery = recoveryCompleter.future;
    _acceptedCancelRecovery[sessionId] = recovery;
    unawaited(
      recovery
          .then((_) {
            if (identical(_acceptedCancelRecovery[sessionId], recovery)) {
              _acceptedCancelRecovery.remove(sessionId);
            }
          })
          .catchError((Object _) {}),
    );
    try {
      await _completeAcceptedCancel(sessionId, turnId);
    } catch (e, st) {
      _limitBreaches.remove(turnId);
      recoveryCompleter.completeError(e, st);
      rethrow;
    }
    unawaited(
      _restartWorkerAfterAcceptedCancel(turnId).then(
        (_) => recoveryCompleter.complete(),
        onError: (Object e, StackTrace st) => recoveryCompleter.completeError(e, st),
      ),
    );
    return TurnCancelResult(
      status: TurnWaitState.cancelled,
      releasedSessionLock: !_externallyAdmittedTurns.contains(turnId),
    );
  }

  Future<void> _restartWorkerAfterAcceptedCancel(String turnId) async {
    try {
      await _worker.cancel();
      await _worker.stop();
      await _worker.start();
    } catch (e, st) {
      TurnRunner._log.warning('Failed to restart worker after accepted cancel for turn $turnId', e, st);
      rethrow;
    }
  }

  Future<void> _awaitAcceptedCancelRecovery(String sessionId) async {
    final recovery = _acceptedCancelRecovery[sessionId];
    if (recovery == null) return;
    try {
      await recovery;
    } catch (e) {
      throw StateError('Worker recovery failed after accepted turn cancel for session $sessionId: $e');
    }
  }

  @visibleForTesting
  bool hasAcceptedCancelRecovery(String sessionId) => _acceptedCancelRecovery.containsKey(sessionId);

  /// Scans [TurnStateStore] for orphaned turns from a previous crash.
  Future<List<String>> detectAndCleanOrphanedTurns() async {
    final turnState = _turnState;
    if (turnState == null) return [];

    try {
      final orphans = await turnState.getAll();
      if (orphans.isEmpty) return [];

      final sessionIds = <String>[];
      for (final entry in orphans.entries) {
        final sessionId = entry.key;
        sessionIds.add(sessionId);

        final turnId = entry.value.turnId;
        final startedAt = entry.value.startedAt.toIso8601String();
        TurnRunner._log.warning('Orphaned turn detected: session=$sessionId, turn=$turnId, started=$startedAt');
        await turnState.delete(sessionId);
      }

      _recoveredSessions.addAll(sessionIds);
      TurnRunner._log.info('Cleaned up ${sessionIds.length} orphaned turn(s)');
      return sessionIds;
    } catch (e) {
      TurnRunner._log.warning('Failed to detect orphaned turns', e);
      return [];
    }
  }

  /// Returns true (once) if this session recovered from a crash.
  bool consumeRecoveryNotice(String sessionId) {
    return _recoveredSessions.remove(sessionId);
  }

  void _handleTurnStall({required String sessionId, required String turnId, required Duration stallTimeout}) {
    final payload = {
      'sessionId': sessionId,
      'turnId': turnId,
      'silentForSeconds': stallTimeout.inSeconds,
      'action': _turnLimits.stallAction.name,
    };

    // Emit progress event for stall — snapshot from per-turn progress state.
    final snapshotFn = _turnProgressSnapshots[sessionId];
    final snapshot = snapshotFn != null ? snapshotFn() : TurnProgressSnapshot(elapsed: Duration.zero, toolCallCount: 0);
    _progressController.add(
      TurnStallProgressEvent(snapshot: snapshot, stallTimeout: stallTimeout, action: _turnLimits.stallAction.name),
    );

    switch (_turnLimits.stallAction) {
      case TurnProgressAction.warn:
        TurnRunner._log.warning('Turn $turnId has stalled for ${stallTimeout.inSeconds}s');
        _sseBroadcast?.broadcast('turn_progress_stall', payload);
      case TurnProgressAction.cancel:
        TurnRunner._log.warning('Cancelling stalled turn $turnId after ${stallTimeout.inSeconds}s');
        _sseBroadcast?.broadcast('turn_progress_stall', payload);
        unawaited(
          _cancelForLimit(sessionId: sessionId, turnId: turnId, breach: TurnLimitBreach.stall, budget: stallTimeout),
        );
      case TurnProgressAction.ignore:
        TurnRunner._log.info('Ignoring stalled turn $turnId after ${stallTimeout.inSeconds}s');
    }
  }

  void _handleTurnTimeout({required String sessionId, required String turnId, required Duration turnTimeout}) {
    TurnRunner._log.warning('Cancelling turn $turnId after its ${turnTimeout.inSeconds}s wall-clock budget');
    unawaited(
      _cancelForLimit(sessionId: sessionId, turnId: turnId, breach: TurnLimitBreach.turnTimeout, budget: turnTimeout),
    );
  }

  Future<void> _cancelForLimit({
    required String sessionId,
    required String turnId,
    required TurnLimitBreach breach,
    required Duration budget,
  }) async {
    try {
      await cancelTurnById(
        sessionId,
        turnId,
        TurnCancelReason.automationCancel,
        enforceCanCancel: false,
        limitBreach: breach,
        limitBudget: budget,
      );
    } on TurnCancelException catch (error) {
      if (error.code != 'TURN_NOT_CANCELLABLE' && error.code != 'TURN_NOT_FOUND') rethrow;
    }
  }

  Future<void> _completeAcceptedCancel(String sessionId, String turnId) async {
    final active = _activeTurns[sessionId];
    if (active == null || active.turnId != turnId) return;
    final completedAt = DateTime.now();
    final limit = _limitBreaches.remove(turnId);
    final toolHooks = _turnToolHooks[turnId];
    toolHooks?.finalizePendingToolCalls(endedAt: completedAt);
    final outcome = TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: TurnStatus.cancelled,
      errorMessage: limit == null ? null : _limitBreachMessage(limit.breach, limit.budget),
      limitBreach: limit?.breach,
      toolCalls: List.unmodifiable(toolHooks?.completedToolCalls ?? const <ToolCallRecord>[]),
      toolCallCount: toolHooks?.toolCallCount,
      failedToolCallCount: toolHooks?.failedToolCallCount,
      completedAt: completedAt,
    );
    _rememberRecentOutcome(outcome, taskId: active.taskId, cachedAt: completedAt);
    final pending = _outcomePending.remove(turnId);
    if (pending != null && !pending.isCompleted) pending.complete(outcome);
    _emitWaitState(sessionId, TurnWaitState.cancelled);
    _activeTurns.remove(sessionId);
    _cancellingTurns.remove(turnId);
    _turnProgressSnapshots.remove(sessionId);
    _runtimeWaits.remove(sessionId)?.dispose();
    if (!_externallyAdmittedTurns.contains(turnId)) _lockManager.release(sessionId);
    _clearTurnPolicy(sessionId, turnId);
    final turnState = _turnState;
    if (turnState != null) {
      unawaited(
        turnState.delete(sessionId).catchError((Object e, StackTrace st) {
          TurnRunner._log.warning('Failed to clean up turn state after cancel', e, st);
        }),
      );
    }
  }

  void _emitWaitState(String sessionId, TurnWaitState state) {
    final context = _activeTurns[sessionId];
    if (context == null) return;
    final wait = _lockManager.waitSnapshot(sessionId);
    final runtimeWait = _runtimeWaits[sessionId]?.snapshot;
    final waitReason = wait != null ? TurnWaitReason.sessionLock : runtimeWait?.reason ?? TurnWaitReason.unknown;
    _eventBus?.fire(
      TurnWaitStateChangedEvent(
        sessionId: sessionId,
        turnId: context.turnId,
        taskId: context.taskId,
        state: state,
        waitReason: waitReason,
        canCancel: _canCancel(state, waitReason, runtimeWait: runtimeWait),
        waitingSince: wait?.waitingSince ?? runtimeWait?.waitingSince,
        stuckSince: wait?.stuckSince ?? runtimeWait?.stuckSince,
        globalTimeoutAt: _effectiveTurnTimeout(context) > Duration.zero
            ? context.startedAt.add(_effectiveTurnTimeout(context))
            : null,
        timestamp: DateTime.now(),
      ),
    );
  }

  bool _canCancel(TurnWaitState state, TurnWaitReason? reason, {TurnLivenessSnapshot? runtimeWait}) {
    if ((reason == TurnWaitReason.toolApproval || runtimeWait?.reason == TurnWaitReason.toolApproval) &&
        runtimeWait?.stuckSince == null) {
      return false;
    }
    return state == TurnWaitState.waiting || state == TurnWaitState.stuck || state == TurnWaitState.cancelling;
  }

  TurnWaitState _activeWaitState(String turnId, SessionLockWaitSnapshot? lockWait, TurnLivenessSnapshot? runtimeWait) {
    if (_cancellingTurns.contains(turnId)) return TurnWaitState.cancelling;
    if (lockWait?.stuckSince != null || runtimeWait?.stuckSince != null) return TurnWaitState.stuck;
    if (lockWait?.warningVisibleAt != null || runtimeWait?.warningVisibleAt != null) return TurnWaitState.waiting;
    return TurnWaitState.running;
  }

  TurnLivenessSnapshot? _visibleRuntimeWait(String turnId, TurnLivenessSnapshot? runtimeWait) {
    if (runtimeWait == null) return null;
    if (runtimeWait.warningVisibleAt != null || runtimeWait.stuckSince != null || _cancellingTurns.contains(turnId)) {
      return runtimeWait;
    }
    return null;
  }

  Duration _effectiveTurnTimeout(TurnContext context) => context.turnTimeout ?? _turnLimits.turnTimeout;

  void _rememberRecentOutcome(TurnOutcome outcome, {String? taskId, DateTime? cachedAt}) {
    final firstSettlement = !_recentOutcomes.containsKey(outcome.turnId);
    _recentOutcomes[outcome.turnId] = (outcome: outcome, expiresAt: (cachedAt ?? DateTime.now()).add(_outcomeTtl));
    if (taskId != null) {
      _recentTaskIds[outcome.turnId] = taskId;
    } else {
      _recentTaskIds.remove(outcome.turnId);
    }
    if (firstSettlement) _outcomeObserver?.call(outcome);
  }

  void _evictExpiredOutcomes() {
    final now = DateTime.now();
    _recentOutcomes.removeWhere((_, v) => v.expiresAt.isBefore(now));
    _recentTaskIds.removeWhere((turnId, _) => !_recentOutcomes.containsKey(turnId));
    _executionSettledPending.removeWhere(
      (turnId, pending) => pending.completer.isCompleted && !_recentOutcomes.containsKey(turnId),
    );
  }
}

String _limitBreachMessage(TurnLimitBreach breach, Duration budget) => switch (breach) {
  TurnLimitBreach.stall => 'Turn stalled after ${budget.inSeconds}s without provider progress',
  TurnLimitBreach.turnTimeout => 'Turn exceeded its ${budget.inSeconds}s wall-clock budget',
};
