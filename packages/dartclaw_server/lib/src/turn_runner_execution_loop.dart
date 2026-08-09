part of 'turn_runner.dart';

extension _TurnRunnerExecutionLoop on TurnRunner {
  Future<void> _runTurnInner({
    required String sessionId,
    required String turnId,
    required List<Map<String, dynamic>> messages,
    String? source,
    bool resume = false,
  }) async {
    final buffer = StringBuffer();
    final stopwatch = Stopwatch()..start();
    final turnPolicy = _activeTurns[sessionId];
    _installTurnPolicy(sessionId, turnId, turnPolicy?.allowedTools, turnPolicy?.readOnly ?? false);
    var progressTextLength = 0;
    final progressMonitor = _stallTimeout > Duration.zero
        ? TurnProgressMonitor(
            stallTimeout: _stallTimeout,
            onStall: (stallTimeout) =>
                _handleTurnStall(sessionId: sessionId, turnId: turnId, stallTimeout: stallTimeout),
            timerFactory: _turnMonitorTimerFactory,
          )
        : null;

    late final TurnToolHookCallbackHandler toolHooks;
    TurnProgressSnapshot buildSnapshot() => TurnProgressSnapshot(
      elapsed: stopwatch.elapsed,
      toolCallCount: toolHooks.toolCallCount,
      lastToolName: toolHooks.lastToolName,
      textLength: progressTextLength,
    );
    toolHooks = TurnToolHookCallbackHandler(
      sessionId: sessionId,
      turnId: turnId,
      governanceEnforcer: _governanceEnforcer,
      resetService: _resetService,
      progressMonitor: progressMonitor,
      loopAction: _loopAction,
      buildSnapshot: buildSnapshot,
      emitProgressEvent: _progressController.add,
      onLoopAbort: (detection) {
        _loopDetectedTurns[turnId] = detection;
        unawaited(cancelTurnById(sessionId, turnId, TurnCancelReason.automationCancel, enforceCanCancel: false));
      },
    );
    _turnProgressSnapshots[sessionId] = buildSnapshot;
    _RuntimeWaitTracker? runtimeWait;

    String? userMessageFull;
    if (messages.isNotEmpty) {
      final last = messages.last;
      if (last['role'] == 'user') {
        userMessageFull = last['content'] as String?;
      }
    }
    final userMessage = userMessageFull != null ? truncate(userMessageFull, 100, suffix: '...') : null;

    final eventSub = _worker.events.listen((event) {
      if (event is DeltaEvent) {
        buffer.write(event.text);
        progressMonitor?.recordProgress();
        runtimeWait?.recordActivity(TurnWaitReason.unknown);
        _resetService?.touchActivity(sessionId);
        progressTextLength += event.text.length;
        _progressController.add(TextDeltaProgressEvent(snapshot: buildSnapshot(), text: event.text));
      } else if (event is ToolUseEvent) {
        runtimeWait?.recordActivity(TurnWaitReason.unknown);
        toolHooks.handleToolUse(event);
      } else if (event is ToolResultEvent) {
        runtimeWait?.recordActivity(TurnWaitReason.unknown);
        toolHooks.handleToolResult(event);
      } else if (event is ToolApprovalWaitEvent) {
        runtimeWait?.recordActivity(TurnWaitReason.toolApproval);
      } else if (event is ToolApprovalResolvedEvent) {
        runtimeWait?.recordActivity(TurnWaitReason.unknown);
      } else if (event is ProviderProgressBridgeEvent) {
        progressMonitor?.recordProgress();
        runtimeWait?.recordActivity(_waitReasonForProviderProgress(event.kind));
        _resetService?.touchActivity(sessionId);
        _progressController.add(ProviderProgressEvent(snapshot: buildSnapshot(), kind: event.kind, text: event.text));
      } else if (event is SystemInitEvent) {
        runtimeWait?.recordActivity(TurnWaitReason.unknown);
        _contextMonitor.update(contextWindow: event.contextWindow);
      } else if (event is CompactionStartingBridgeEvent) {
        _eventBus?.fire(CompactionStartingEvent(sessionId: sessionId, trigger: 'auto', timestamp: DateTime.now()));
      } else if (event is CompactionCompletedBridgeEvent) {
        _eventBus?.fire(CompactionCompletedEvent(sessionId: sessionId, trigger: 'auto', timestamp: DateTime.now()));
      }
    });

    TurnOutcome? outcome;
    Timer? statusTickTimer;
    try {
      try {
        final guardOutcome = await _guardEvaluator.evaluateMessageReceived(
          turnId: turnId,
          sessionId: sessionId,
          source: source,
          userMessageFull: userMessageFull,
        );
        if (guardOutcome != null) {
          outcome = guardOutcome;
          return;
        }

        final systemPrompt = await _buildSystemPrompt(sessionId);
        final turnCtx = _activeTurns[sessionId];
        await _awaitAcceptedCancelRecovery(sessionId);
        if (_externallyCompletedTurns.contains(turnId)) {
          outcome = TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.cancelled,
            completedAt: DateTime.now(),
          );
          return;
        }
        TurnRunner._log.info(
          'Turn start: session=$sessionId, turn=$turnId, '
          'provider=$providerId${userMessage != null ? ', prompt=$userMessage' : ''}',
        );
        statusTickTimer = _statusTickInterval > Duration.zero
            ? Timer.periodic(_statusTickInterval, (_) {
                _progressController.add(StatusTickProgressEvent(snapshot: buildSnapshot()));
              })
            : null;
        progressMonitor?.start();
        runtimeWait = _RuntimeWaitTracker(
          waitWarningAfter: _turnMonitor.waitWarningAfter,
          stuckAfter: _turnMonitor.stuckAfter,
          timerFactory: _turnMonitorTimerFactory,
          now: _turnMonitorNow,
          initialReason: TurnWaitReason.unknown,
          onWaiting: () => _emitWaitState(sessionId, TurnWaitState.waiting),
          onStuck: () => _emitWaitState(sessionId, TurnWaitState.stuck),
        );
        _runtimeWaits[sessionId] = runtimeWait;
        final result = await _worker.turn(
          sessionId: sessionId,
          agentId: turnCtx?.agentName == 'main' ? null : turnCtx?.agentName,
          messages: messages,
          systemPrompt: systemPrompt,
          directory: turnCtx?.directory,
          model: turnCtx?.model,
          effort: turnCtx?.effort,
          maxTurns: turnCtx?.maxTurns,
          resume: resume,
        );
        if (_externallyCompletedTurns.remove(turnId)) {
          outcome = TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.cancelled,
            completedAt: DateTime.now(),
          );
          return;
        }
        final accumulated = buffer.toString();
        toolHooks.finalizePendingToolCalls();
        stopwatch.stop();
        TurnRunner._log.info(
          'Turn complete: session=$sessionId, turn=$turnId, '
          'provider=$providerId, ${stopwatch.elapsedMilliseconds}ms, '
          'tools=${toolHooks.toolCallCount}, text=${accumulated.length} chars',
        );
        final cacheReadTokens = _worker.supportsCachedTokens ? (result['cache_read_tokens'] as int? ?? 0) : 0;
        final cacheWriteTokens = _worker.supportsCachedTokens ? (result['cache_write_tokens'] as int? ?? 0) : 0;

        try {
          await _trackSessionUsage(sessionId, result, providerId);
          await _applySessionMetadata(sessionId, result);
          _contextMonitor.update(contextTokens: result['input_tokens'] as int?);
        } catch (e) {
          TurnRunner._log.warning('Failed to track usage', e);
        }

        final tracker = _usageTracker;
        if (tracker != null) {
          final turnCtx = _activeTurns[sessionId];
          final inputTokens = result['input_tokens'] as int? ?? 0;
          final outputTokens = result['output_tokens'] as int? ?? 0;
          final durationMs = turnCtx != null ? DateTime.now().difference(turnCtx.startedAt).inMilliseconds : 0;
          unawaited(
            tracker
                .record(
                  UsageEvent(
                    timestamp: DateTime.now(),
                    sessionId: sessionId,
                    agentName: turnCtx?.agentName ?? 'main',
                    model: result['model'] as String?,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    durationMs: durationMs,
                  ),
                )
                .catchError((Object e) {
                  TurnRunner._log.fine('Failed to record usage', e);
                }),
          );

          // Post-hoc token velocity check (Mechanism 2).
          try {
            _governanceEnforcer.recordTokensAndCheckVelocity(sessionId, inputTokens + outputTokens);
            // Velocity detection post-hoc: fire warn event even in abort mode
            // (tokens already spent). Next pre-turn check will abort if still over.
          } catch (e) {
            TurnRunner._log.fine('Loop velocity check failed (non-fatal): $e');
          }
        }

        // Check context warning threshold (one-shot per session).
        try {
          if (_contextMonitor.checkThreshold(sessionId: sessionId)) {
            final percent = _contextMonitor.usagePercent ?? 0;
            _sseBroadcast?.broadcast('context_warning', {
              'sessionId': sessionId,
              'usagePercent': percent,
              'message':
                  'Context window $percent% used — consider starting '
                  'a new session or saving context to memory.',
            });
          }
        } catch (e) {
          TurnRunner._log.fine('Failed to emit context warning: $e');
        }

        if (result['stop_reason'] == 'error') {
          final rawProviderError = result['error'];
          final providerError = rawProviderError is String && rawProviderError.trim().isNotEmpty
              ? rawProviderError.trim()
              : 'Provider turn failed';
          final sendOutcome = await _guardEvaluator.evaluateBeforeAgentSend(
            turnId: turnId,
            sessionId: sessionId,
            accumulated: providerError,
          );
          if (sendOutcome != null) {
            outcome = sendOutcome;
            return;
          }
          final redactedProviderError = _redactor?.redact(providerError) ?? providerError;
          await _messages.insertMessage(sessionId: sessionId, role: 'assistant', content: redactedProviderError);
          await _sessions?.touchUpdatedAt(sessionId);
          outcome = TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.failed,
            errorMessage: redactedProviderError,
            inputTokens: result['input_tokens'] as int? ?? 0,
            outputTokens: result['output_tokens'] as int? ?? 0,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            turnDuration: stopwatch.elapsed,
            toolCalls: List.unmodifiable(toolHooks.completedToolCalls),
            completedAt: DateTime.now(),
          );
          return;
        }

        if (accumulated.isNotEmpty) {
          final sendOutcome = await _guardEvaluator.evaluateBeforeAgentSend(
            turnId: turnId,
            sessionId: sessionId,
            accumulated: accumulated,
          );
          if (sendOutcome != null) {
            outcome = sendOutcome;
            return;
          }
        }

        if (result['stop_reason'] == 'cancelled') {
          outcome = TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.cancelled,
            inputTokens: result['input_tokens'] as int? ?? 0,
            outputTokens: result['output_tokens'] as int? ?? 0,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            turnDuration: stopwatch.elapsed,
            toolCalls: List.unmodifiable(toolHooks.completedToolCalls),
            completedAt: DateTime.now(),
          );
          return;
        }

        final redacted = _redactor?.redact(accumulated) ?? accumulated;
        final trimmed = _explorationSummarizer.summarizeOrTrim(
          redacted,
          fileHint: _lastToolFileHint(toolHooks.toolEvents),
        );
        await _messages.insertMessage(sessionId: sessionId, role: 'assistant', content: trimmed);
        await _sessions?.touchUpdatedAt(sessionId);
        outcome = TurnOutcome(
          turnId: turnId,
          sessionId: sessionId,
          status: TurnStatus.completed,
          responseText: trimmed,
          inputTokens: result['input_tokens'] as int? ?? 0,
          outputTokens: result['output_tokens'] as int? ?? 0,
          cacheReadTokens: cacheReadTokens,
          cacheWriteTokens: cacheWriteTokens,
          turnDuration: stopwatch.elapsed,
          toolCalls: List.unmodifiable(toolHooks.completedToolCalls),
          completedAt: DateTime.now(),
        );

        try {
          await _appendDailyLog(
            sessionId: sessionId,
            userMessage: userMessage,
            toolEvents: toolHooks.toolEvents,
            result: redacted,
          );
        } catch (e) {
          TurnRunner._log.warning('Failed to write daily log', e);
        }

        if (_contextMonitor.shouldFlushForCompactionSignal(compactionSignalAvailable: _worker.supportsPreCompactHook)) {
          try {
            await _runFlushTurn(sessionId);
          } catch (e) {
            TurnRunner._log.warning('Pre-compaction flush failed (lossy compaction possible)', e);
          }
        }
      } catch (e, st) {
        final wasCancelled = _cancelledTurns.remove(turnId);
        _cancellingTurns.remove(turnId);
        final acceptedCancel =
            _acceptedCancelCleanupPending.contains(turnId) || _externallyCompletedTurns.contains(turnId);
        final loopDetection = _loopDetectedTurns.remove(turnId);
        if (wasCancelled) {
          TurnRunner._log.info('Turn $turnId cancelled');
        } else {
          TurnRunner._log.warning('Turn $turnId failed', e, st);
        }
        if (!acceptedCancel) {
          try {
            var partial = buffer.toString();
            if (partial.isNotEmpty && _redactor != null) {
              partial = _redactor.redact(partial);
            }
            // Post loop detection message if this was a loop-cancelled turn.
            final loopMsg = loopDetection != null ? '[Loop detected: ${loopDetection.message}]' : null;
            await _messages.insertMessage(
              sessionId: sessionId,
              role: 'assistant',
              content:
                  loopMsg ?? (partial.isNotEmpty ? partial : (wasCancelled ? '[Turn cancelled]' : '[Turn failed]')),
            );
          } catch (e) {
            TurnRunner._log.warning('Failed to persist partial message after turn failure: $e');
          }
        }
        outcome = TurnOutcome(
          turnId: turnId,
          sessionId: sessionId,
          status: wasCancelled ? TurnStatus.cancelled : TurnStatus.failed,
          errorMessage: wasCancelled ? null : 'Turn execution failed',
          completedAt: DateTime.now(),
          loopDetection: loopDetection,
        );
        if (!acceptedCancel) {
          unawaited(
            _selfImprovement?.appendError(
              errorType: wasCancelled ? 'TURN_CANCELLED' : 'TURN_FAILURE',
              sessionId: sessionId,
              context: '$e',
            ),
          );
        }
      }
    } finally {
      _clearTurnPolicy(sessionId, turnId);
      statusTickTimer?.cancel();
      progressMonitor?.stop();
      await eventSub.cancel();
      final activeStillThisTurn = _activeTurns[sessionId]?.turnId == turnId;
      final cancelCleanupPending = _acceptedCancelCleanupPending.contains(turnId);
      if (activeStillThisTurn) {
        _turnProgressSnapshots.remove(sessionId);
        _runtimeWaits.remove(sessionId)?.dispose();
      }
      final recentTaskId = activeStillThisTurn ? _activeTurns[sessionId]?.taskId : _recentTaskIds[turnId];
      final resolved =
          outcome ??
          TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.failed,
            errorMessage: 'Unexpected internal error',
            completedAt: DateTime.now(),
          );
      if (!cancelCleanupPending) {
        _rememberRecentOutcome(resolved, taskId: recentTaskId);
        _outcomePending.remove(turnId)?.complete(resolved);
      }
      if (activeStillThisTurn && !cancelCleanupPending) {
        switch (resolved.status) {
          case TurnStatus.completed:
            _emitWaitState(sessionId, TurnWaitState.completed);
          case TurnStatus.failed:
            _emitWaitState(sessionId, TurnWaitState.failed);
          case TurnStatus.cancelled:
            _emitWaitState(sessionId, TurnWaitState.cancelled);
        }
      }
      // All reads of this set (711, 748, catch at 897) run before finally, so an
      // unconditional remove here only closes the leak on throw/early-return paths.
      _externallyCompletedTurns.remove(turnId);
      if (!cancelCleanupPending) _cancellingTurns.remove(turnId);
      if (activeStillThisTurn && !cancelCleanupPending) {
        _activeTurns.remove(sessionId);
        if (!_externallyAdmittedTurns.contains(turnId)) _lockManager.release(sessionId);
      }
      _governanceEnforcer.cleanupTurn(turnId);

      final turnState = _turnState;
      if (turnState != null && activeStillThisTurn && !cancelCleanupPending) {
        unawaited(
          turnState.delete(sessionId).catchError((Object e, StackTrace st) {
            TurnRunner._log.warning('Failed to clean up turn state', e, st);
          }),
        );
      }
    }
  }
}
