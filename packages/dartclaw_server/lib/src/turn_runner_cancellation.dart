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
      globalTimeoutAt: _globalTimeout == null ? null : context.startedAt.add(_globalTimeout),
      canCancel: _canCancel(state, waitReason, runtimeWait: runtimeWait),
    );
  }

  Future<TurnCancelResult> cancelTurnById(
    String sessionId,
    String turnId,
    TurnCancelReason reason, {
    bool enforceCanCancel = true,
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

    if (enforceCanCancel) {
      final snapshot = turnStatus(sessionId);
      if (!snapshot.canCancel) {
        throw const TurnCancelException('TURN_NOT_CANCELLABLE', 'Turn is not cancellable', statusCode: 409);
      }
    }

    _cancellingTurns.add(turnId);
    _emitWaitState(sessionId, TurnWaitState.cancelling);
    _cancelledTurns.add(turnId);
    _externallyCompletedTurns.add(turnId);
    _acceptedCancelCleanupPending.add(turnId);
    await _completeAcceptedCancel(sessionId, turnId);
    final recovery = _restartWorkerAfterAcceptedCancel(turnId);
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
    return const TurnCancelResult(status: TurnWaitState.cancelled, releasedSessionLock: true);
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
      'action': _stallAction.name,
    };

    // Emit progress event for stall — snapshot from per-turn progress state.
    final snapshotFn = _turnProgressSnapshots[sessionId];
    final snapshot = snapshotFn != null ? snapshotFn() : TurnProgressSnapshot(elapsed: Duration.zero, toolCallCount: 0);
    _progressController.add(
      TurnStallProgressEvent(snapshot: snapshot, stallTimeout: stallTimeout, action: _stallAction.name),
    );

    switch (_stallAction) {
      case TurnProgressAction.warn:
        TurnRunner._log.warning('Turn $turnId has stalled for ${stallTimeout.inSeconds}s');
        _sseBroadcast?.broadcast('turn_progress_stall', payload);
      case TurnProgressAction.cancel:
        TurnRunner._log.warning('Cancelling stalled turn $turnId after ${stallTimeout.inSeconds}s');
        _sseBroadcast?.broadcast('turn_progress_stall', payload);
        unawaited(cancelTurnById(sessionId, turnId, TurnCancelReason.automationCancel, enforceCanCancel: false));
      case TurnProgressAction.ignore:
        TurnRunner._log.info('Ignoring stalled turn $turnId after ${stallTimeout.inSeconds}s');
    }
  }

  Future<void> _completeAcceptedCancel(String sessionId, String turnId) async {
    final active = _activeTurns[sessionId];
    if (active == null || active.turnId != turnId) return;
    final completedAt = DateTime.now();
    final outcome = TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: TurnStatus.cancelled,
      completedAt: completedAt,
    );
    _rememberRecentOutcome(outcome, taskId: active.taskId, cachedAt: completedAt);
    final pending = _outcomePending.remove(turnId);
    if (pending != null && !pending.isCompleted) pending.complete(outcome);
    _emitWaitState(sessionId, TurnWaitState.cancelled);
    _acceptedCancelCleanupPending.remove(turnId);
    _activeTurns.remove(sessionId);
    _cancellingTurns.remove(turnId);
    _turnProgressSnapshots.remove(sessionId);
    _runtimeWaits.remove(sessionId)?.dispose();
    _lockManager.release(sessionId);
    _taskToolFilterGuard?.setSessionToolFilter(sessionId, null);
    _taskToolFilterGuard?.setSessionReadOnly(sessionId, false);
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
        globalTimeoutAt: _globalTimeout == null ? null : context.startedAt.add(_globalTimeout),
        timestamp: DateTime.now(),
      ),
    );
  }

  bool _canCancel(TurnWaitState state, TurnWaitReason? reason, {_RuntimeWaitSnapshot? runtimeWait}) {
    if ((reason == TurnWaitReason.toolApproval || runtimeWait?.reason == TurnWaitReason.toolApproval) &&
        runtimeWait?.stuckSince == null) {
      return false;
    }
    return state == TurnWaitState.waiting || state == TurnWaitState.stuck || state == TurnWaitState.cancelling;
  }

  TurnWaitState _activeWaitState(String turnId, SessionLockWaitSnapshot? lockWait, _RuntimeWaitSnapshot? runtimeWait) {
    if (_cancellingTurns.contains(turnId)) return TurnWaitState.cancelling;
    if (lockWait?.stuckSince != null || runtimeWait?.stuckSince != null) return TurnWaitState.stuck;
    if (lockWait?.warningVisibleAt != null || runtimeWait?.warningVisibleAt != null) return TurnWaitState.waiting;
    return TurnWaitState.running;
  }

  _RuntimeWaitSnapshot? _visibleRuntimeWait(String turnId, _RuntimeWaitSnapshot? runtimeWait) {
    if (runtimeWait == null) return null;
    if (runtimeWait.warningVisibleAt != null || runtimeWait.stuckSince != null || _cancellingTurns.contains(turnId)) {
      return runtimeWait;
    }
    return null;
  }

  TurnWaitReason _waitReasonForProviderProgress(String kind) {
    final normalized = kind.toLowerCase().replaceAll('-', '_');
    if (normalized.contains('approval')) return TurnWaitReason.toolApproval;
    if (normalized.contains('unknown') || normalized.contains('unclassified')) return TurnWaitReason.unknown;
    return TurnWaitReason.providerTurn;
  }

  void _rememberRecentOutcome(TurnOutcome outcome, {String? taskId, DateTime? cachedAt}) {
    _recentOutcomes[outcome.turnId] = (outcome: outcome, expiresAt: (cachedAt ?? DateTime.now()).add(_outcomeTtl));
    if (taskId != null) {
      _recentTaskIds[outcome.turnId] = taskId;
    } else {
      _recentTaskIds.remove(outcome.turnId);
    }
  }

  void _evictExpiredOutcomes() {
    final now = DateTime.now();
    _recentOutcomes.removeWhere((_, v) => v.expiresAt.isBefore(now));
    _recentTaskIds.removeWhere((turnId, _) => !_recentOutcomes.containsKey(turnId));
  }
}

class _RuntimeWaitTracker {
  final Duration waitWarningAfter;
  final Duration stuckAfter;
  final SessionLockTimerFactory timerFactory;
  final SessionLockNow now;
  final void Function() onWaiting;
  final void Function() onStuck;

  Timer? _waitingTimer;
  Timer? _stuckTimer;
  _RuntimeWaitSnapshot _snapshot;

  _RuntimeWaitTracker({
    required this.waitWarningAfter,
    required this.stuckAfter,
    required this.timerFactory,
    required this.now,
    required TurnWaitReason initialReason,
    required this.onWaiting,
    required this.onStuck,
  }) : _snapshot = _RuntimeWaitSnapshot(waitingSince: now(), reason: initialReason) {
    _schedule();
  }

  _RuntimeWaitSnapshot get snapshot => _snapshot;

  void recordActivity(TurnWaitReason reason) {
    _waitingTimer?.cancel();
    _stuckTimer?.cancel();
    _snapshot = _RuntimeWaitSnapshot(waitingSince: now(), reason: reason);
    _schedule();
  }

  void dispose() {
    _waitingTimer?.cancel();
    _stuckTimer?.cancel();
  }

  void _schedule() {
    if (waitWarningAfter > Duration.zero) {
      _waitingTimer = timerFactory(waitWarningAfter, () {
        _snapshot = _snapshot.copyWith(warningVisibleAt: now());
        onWaiting();
      });
    } else {
      _snapshot = _snapshot.copyWith(warningVisibleAt: _snapshot.waitingSince);
    }

    if (stuckAfter > Duration.zero) {
      _stuckTimer = timerFactory(stuckAfter, () {
        _snapshot = _snapshot.copyWith(stuckSince: now());
        onStuck();
      });
    }
  }
}

class _RuntimeWaitSnapshot {
  final DateTime waitingSince;
  final DateTime? warningVisibleAt;
  final DateTime? stuckSince;
  final TurnWaitReason reason;

  const _RuntimeWaitSnapshot({
    required this.waitingSince,
    required this.reason,
    this.warningVisibleAt,
    this.stuckSince,
  });

  _RuntimeWaitSnapshot copyWith({DateTime? warningVisibleAt, DateTime? stuckSince}) {
    return _RuntimeWaitSnapshot(
      waitingSince: waitingSince,
      reason: reason,
      warningVisibleAt: warningVisibleAt ?? this.warningVisibleAt,
      stuckSince: stuckSince ?? this.stuckSince,
    );
  }
}
